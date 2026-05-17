defmodule Holt.Runtime do
  @moduledoc """
  Local agent loop for Holt.
  """

  alias Holt.Runtime.{Context, EventRecorder, Runs}
  alias Holt.Tasks.OutputSanitizer
  alias Holt.Tasks.{RuntimeContracts, TaskToolSession}

  alias Holt.{
    Actions,
    Clock,
    Config,
    Memory,
    Models,
    Paths,
    Tools,
    ToolVisibility,
    Workspace
  }

  def run(objective, opts \\ []) when is_binary(objective) do
    home = Paths.home(opts)
    root = Paths.workspace_root(opts)
    Holt.Env.load(opts)
    Config.bootstrap(home: home)
    Workspace.init(root)
    provider = Models.default_provider(home)
    model = "#{provider["type"]}:#{provider["model"] || provider["id"]}"

    run_opts =
      opts
      |> Keyword.merge(model: model)
      |> maybe_put_resumed_from()

    with {:ok, run} <- Runs.start(objective, run_opts),
         run_dir <- run["run_dir"],
         {:ok, _run} <- Runs.transition(run_dir, "running") do
      runtime_opts = agent_event_runtime_opts(opts, run, provider, root)
      session_id = runtime_opts[:agent_event_session_id]

      EventRecorder.session_started(
        session_id,
        agent_event_opts(runtime_opts,
          objective: objective,
          model: model,
          provider: provider["id"] || provider["type"]
        )
      )

      progress(run_dir, runtime_opts, :started, "Starting request")
      result = execute_local_loop(objective, provider, run_dir, runtime_opts)
      record_session_result(session_id, result, runtime_opts)
      result
    end
  rescue
    reason ->
      {:error, reason}
  end

  def resume(run_ref \\ "latest", opts \\ []) do
    root = Paths.workspace_root(opts)

    case Runs.find(root, run_ref) do
      nil ->
        {:error, :run_not_found}

      run ->
        run["objective"]
        |> run(Keyword.put(opts, :resumed_from, run["id"]))
    end
  end

  def status(opts \\ []) do
    root = Paths.workspace_root(opts)
    latest = Runs.latest(root)

    %{
      "workspace" => root,
      "workspace_initialized" => Workspace.initialized?(root),
      "latest_run" => latest,
      "gateway" => Holt.Gateway.status(opts)
    }
  end

  defp execute_local_loop(objective, provider, run_dir, opts) do
    progress(run_dir, opts, :reading, "Reading project context")
    context = Context.build(objective, opts)
    Runs.append_event(run_dir, "context.built", context_event(context))
    Runs.append_transcript(run_dir, "user", objective)
    record_user_message(opts, objective, 0)

    with {:ok, files_result} <- execute_tool(run_dir, "list_files", %{"limit" => 80}, opts),
         {:ok, memory_result} <-
           execute_tool(run_dir, "search_memory", %{"query" => objective}, opts),
         {:ok, files_result} <- maybe_enrich_chat_files(objective, run_dir, files_result, opts),
         {:ok, output} <-
           progress_then(run_dir, opts, :thinking, "Thinking through the request", fn ->
             plan_with_model(
               objective,
               provider,
               context,
               files_result,
               memory_result,
               run_dir,
               opts
             )
           end) do
      persist_output(objective, provider, run_dir, output, opts)
    else
      {:error, :approval_denied} ->
        progress(run_dir, opts, :blocked, "Waiting for approval")

        {:ok, run} =
          Runs.block(run_dir, "action approval denied", %{
            "failure_class" => "approval_denied",
            "blocker_code" => "approval_denied"
          })

        {:ok, %{run: run, output: nil, artifact: nil}}

      {:error, reason} ->
        progress(run_dir, opts, :failed, "Holt could not complete the request")
        {:ok, run} = Runs.fail(run_dir, reason)
        {:error, %{run: run, reason: reason}}
    end
  end

  defp maybe_enrich_chat_files(objective, run_dir, files_result, opts) do
    intent = chat_intent(objective, opts)

    files_result =
      files_result
      |> Map.put("chat_intent", Atom.to_string(intent))
      |> Map.put("chat_context", opts[:chat_context])

    if chat_mode?(opts) and intent == :workspace_overview do
      overview_files =
        files_result
        |> Map.get("files", [])
        |> overview_file_candidates()
        |> Enum.map(&read_overview_file(run_dir, &1, opts))

      {:ok, Map.put(files_result, "overview_files", overview_files)}
    else
      {:ok, files_result}
    end
  end

  defp read_overview_file(run_dir, path, opts) do
    case execute_tool(run_dir, "read_file", %{"path" => path}, opts) do
      {:ok, result} ->
        result

      {:error, reason} ->
        %{"path" => path, "error" => inspect(reason)}
    end
  end

  defp overview_file_candidates(files) do
    root_docs_and_configs =
      files
      |> Enum.filter(&root_doc_or_config?/1)
      |> Enum.sort_by(&root_file_rank/1)
      |> Enum.take(6)

    representative_sources =
      files
      |> Enum.filter(&source_file?/1)
      |> one_per_top_level_area()
      |> Enum.take(6)

    representative_tests =
      files
      |> Enum.filter(&test_file?/1)
      |> one_per_top_level_area()
      |> Enum.take(3)

    (root_docs_and_configs ++ representative_sources ++ representative_tests)
    |> Enum.uniq()
    |> Enum.take(8)
  end

  defp root_doc_or_config?(path) do
    Path.dirname(path) == "." and text_extension?(Path.extname(path))
  end

  defp source_file?(path), do: source_extension?(Path.extname(path)) and not test_file?(path)

  defp test_file?(path) do
    path
    |> Path.split()
    |> Enum.any?(&(&1 in ["test", "tests", "spec", "specs", "__tests__"]))
  end

  defp root_file_rank(path) do
    name = path |> Path.basename() |> String.downcase()

    cond do
      String.starts_with?(name, "readme") -> 0
      Path.extname(name) == ".md" -> 1
      true -> 2
    end
  end

  defp one_per_top_level_area(files) do
    files
    |> Enum.group_by(&top_level_area/1)
    |> Enum.map(fn {_area, area_files} -> Enum.min_by(area_files, &file_depth/1) end)
    |> Enum.sort_by(&file_depth/1)
  end

  defp top_level_area(path) do
    path
    |> Path.split()
    |> case do
      [single] -> single
      [area | _rest] -> area
      [] -> "."
    end
  end

  defp file_depth(path), do: path |> Path.split() |> length()

  defp text_extension?(extension) do
    extension in [".md", ".txt", ".json", ".toml", ".yaml", ".yml", ".xml", ".env", ".ini"]
  end

  defp source_extension?(extension) do
    extension in [
      ".ex",
      ".exs",
      ".rs",
      ".ts",
      ".tsx",
      ".js",
      ".jsx",
      ".py",
      ".go",
      ".rb",
      ".java",
      ".kt",
      ".swift",
      ".c",
      ".h",
      ".cpp",
      ".hpp",
      ".cs"
    ]
  end

  defp persist_output(objective, provider, run_dir, output, opts) do
    if chat_mode?(opts) do
      complete_chat_run(provider, run_dir, output, opts)
    else
      persist_plan(objective, provider, run_dir, output, opts)
    end
  end

  defp complete_chat_run(provider, run_dir, output, opts) do
    Runs.append_transcript(run_dir, "assistant", output)
    emit_stream_chunk(opts, output, turn: 0)
    progress(run_dir, opts, :completed, "Completed")

    {:ok, run} =
      Runs.complete(run_dir, %{
        "provider" => provider["id"] || provider["type"]
      })

    {:ok, %{run: run, output: output, artifact: nil}}
  end

  defp persist_plan(objective, provider, run_dir, plan, opts) do
    Runs.append_transcript(run_dir, "assistant", plan)
    emit_stream_chunk(opts, plan, turn: 0)

    write_args = %{
      "path" => "NEXT_STEPS.md",
      "content" => plan,
      "reason" => "Persist the first Holt run artifact."
    }

    case execute_tool(run_dir, "write_file", write_args, opts) do
      {:ok, write_result} ->
        Memory.save(
          "summary",
          "Last Holt run created NEXT_STEPS.md for: #{objective}",
          Keyword.merge(opts, source_run_id: Runs.load_run!(run_dir)["id"])
        )

        progress(run_dir, opts, :completed, "Completed")

        {:ok, run} =
          Runs.complete(run_dir, %{
            "artifact" => Map.get(write_result, "path"),
            "provider" => provider["id"] || provider["type"]
          })

        {:ok, %{run: run, output: plan, artifact: write_result}}

      {:error, :approval_denied} ->
        progress(run_dir, opts, :blocked, "Waiting for approval")

        {:ok, run} =
          Runs.block(run_dir, "write_file approval denied", %{
            "failure_class" => "approval_denied",
            "blocker_code" => "approval_denied"
          })

        {:ok, %{run: run, output: plan, artifact: nil}}

      {:error, reason} ->
        progress(run_dir, opts, :failed, "Holt could not save the result")
        {:ok, run} = Runs.fail(run_dir, reason)
        {:error, %{run: run, reason: reason}}
    end
  end

  defp execute_tool(run_dir, name, args, opts) do
    tool_call_id = Clock.id("tool_call")

    emit_tool_event(
      run_dir,
      opts,
      "tool.started",
      ToolVisibility.started(name, args, tool_call_id, opts)
    )

    approval_expected? = ToolVisibility.approval_expected?(name, args, opts)

    if approval_expected? do
      emit_tool_event(
        run_dir,
        opts,
        "tool.approval_requested",
        ToolVisibility.approval_requested(name, args, tool_call_id, opts)
      )
    end

    Runs.append_event(run_dir, "tool.requested", %{"tool" => name, "args" => redact_args(args)})
    record_tool_invocation(opts, name, args, tool_call_id, 0)

    case Tools.execute(name, args, opts) do
      {:ok, result} ->
        if approval_expected? do
          emit_tool_event(
            run_dir,
            opts,
            "tool.approval_resolved",
            ToolVisibility.approval_resolved(name, args, tool_call_id, "approved", opts)
          )
        end

        emit_tool_event(
          run_dir,
          opts,
          "tool.completed",
          ToolVisibility.completed(name, args, result, tool_call_id, opts)
          |> Map.merge(%{"result_status" => "ok", "result" => summarize_result(result)})
        )

        record_tool_result(opts, name, %{"status" => "ok", "result" => result}, tool_call_id, 0)
        {:ok, result}

      {:error, reason} ->
        if approval_expected? and reason == :approval_denied do
          emit_tool_event(
            run_dir,
            opts,
            "tool.approval_resolved",
            ToolVisibility.approval_resolved(name, args, tool_call_id, "denied", opts)
          )
        end

        emit_tool_event(
          run_dir,
          opts,
          "tool.failed",
          ToolVisibility.failed(name, args, reason, tool_call_id, opts)
          |> Map.merge(%{"result_status" => "error", "reason" => inspect(reason)})
        )

        record_tool_result(
          opts,
          name,
          %{"status" => "error", "reason" => inspect(reason)},
          tool_call_id,
          0
        )

        {:error, reason}
    end
  end

  defp progress_then(run_dir, opts, stage, message, fun) when is_function(fun, 0) do
    progress(run_dir, opts, stage, message)
    fun.()
  end

  defp progress(run_dir, opts, stage, message, attrs \\ %{}) do
    stage = stage |> to_string() |> String.replace("_", "-")

    event =
      attrs
      |> Map.merge(%{"stage" => stage, "message" => message})
      |> reject_empty()
      |> then(&Runs.append_event(run_dir, "progress." <> stage, &1))

    emit_runtime_event(opts, event)
    :ok
  end

  defp emit_tool_event(run_dir, opts, type, data) do
    event = Runs.append_event(run_dir, type, data)
    emit_runtime_event(opts, event)
    event
  end

  defp local_plan(objective, provider, context, files_result, memory_result) do
    files =
      files_result
      |> Map.get("files", [])
      |> Enum.take(30)
      |> Enum.map(&("- " <> &1))
      |> Enum.join("\n")

    skills =
      context.skills
      |> Enum.map(&("- " <> &1.name))
      |> case do
        [] -> "- none selected"
        rows -> Enum.join(rows, "\n")
      end

    memories =
      memory_result
      |> Map.get("matches", [])
      |> Enum.take(5)
      |> Enum.map(&("- " <> Map.get(&1, "text", "")))
      |> case do
        [] -> "- none"
        rows -> Enum.join(rows, "\n")
      end

    """
    # NEXT STEPS

    Objective: #{objective}

    Provider: #{provider["type"]}:#{provider["model"] || "local-planner"}

    ## Workspace Snapshot

    #{files}

    ## Skills Used

    #{skills}

    ## Relevant Memory

    #{memories}

    ## Recommended Next Tasks

    1. Confirm the desired first workflow for this workspace.
    2. Add or refine skills in `.holtworks/skills` for recurring work.
    3. Run `holt memory search "<topic>"` before follow-up tasks.
    4. Keep write and shell approvals enabled until the workflow is trusted.
    """
  end

  defp local_chat_response(_objective, provider, context, files_result, memory_result) do
    case Map.get(files_result, "chat_intent") do
      "workspace_overview" ->
        local_workspace_overview_response(provider, context, files_result, memory_result)

      _intent ->
        local_general_chat_response(provider, context, files_result, memory_result)
    end
  end

  defp local_general_chat_response(_provider, context, files_result, memory_result) do
    file_count =
      files_result
      |> Map.get("files", [])
      |> length()

    memory_count =
      memory_result
      |> Map.get("matches", [])
      |> length()

    skills =
      context.skills
      |> Enum.map(& &1.name)
      |> case do
        [] -> "no workspace skills loaded"
        names -> Enum.join(names, ", ")
      end

    """
    Hello. I'm Holt.

    I loaded #{file_count} workspace files, #{memory_count} memory matches, and #{skills}. What should we work on next?
    """
    |> String.trim()
  end

  defp local_workspace_overview_response(_provider, context, files_result, memory_result) do
    files = Map.get(files_result, "files", [])
    overview_files = Map.get(files_result, "overview_files", [])

    project_kind = project_kind(files)

    directories =
      files
      |> Enum.map(&top_level_dir/1)
      |> Enum.reject(&(&1 in [nil, "."]))
      |> Enum.frequencies()
      |> Enum.sort_by(fn {_dir, count} -> -count end)
      |> Enum.take(6)
      |> Enum.map(fn {dir, count} -> "- `#{dir}/` #{count} files" end)
      |> nonempty_rows("- no nested directories in the current file list")

    key_files =
      overview_files
      |> Enum.map(&overview_file_row/1)
      |> nonempty_rows("- no key files were readable")

    skills = skill_summary(context)

    memories =
      memory_result
      |> Map.get("matches", [])
      |> length()

    """
    I scanned the workspace map and read #{length(overview_files)} key files.

    Project shape: #{project_kind}. Holt can see #{length(files)} files, #{memories} memory matches, and #{skills}.

    Main areas:
    #{Enum.join(directories, "\n")}

    Key files read:
    #{Enum.join(key_files, "\n")}

    Good next drill-downs: main workflows, setup, data flow, tests, or release packaging.
    """
    |> String.trim()
  end

  defp overview_file_row(%{"path" => path, "content" => content}) do
    preview =
      content
      |> to_string()
      |> String.split("\n")
      |> Enum.reject(&(String.trim(&1) == ""))
      |> Enum.take(2)
      |> Enum.join(" ")
      |> String.slice(0, 120)

    "- `#{path}` #{preview}"
  end

  defp overview_file_row(%{"path" => path, "error" => error}) do
    "- `#{path}` could not be read: #{error}"
  end

  defp project_kind(files) do
    languages =
      files
      |> Enum.flat_map(&language_for_extension(Path.extname(&1)))
      |> Enum.uniq()
      |> Enum.take(4)

    case languages do
      [] -> "workspace"
      [language] -> "#{language} workspace"
      languages -> Enum.join(languages, " + ") <> " workspace"
    end
  end

  defp language_for_extension(".ex"), do: ["Elixir"]
  defp language_for_extension(".exs"), do: ["Elixir"]
  defp language_for_extension(".rs"), do: ["Rust"]
  defp language_for_extension(".ts"), do: ["TypeScript"]
  defp language_for_extension(".tsx"), do: ["TypeScript"]
  defp language_for_extension(".js"), do: ["JavaScript"]
  defp language_for_extension(".jsx"), do: ["JavaScript"]
  defp language_for_extension(".py"), do: ["Python"]
  defp language_for_extension(".go"), do: ["Go"]
  defp language_for_extension(".rb"), do: ["Ruby"]
  defp language_for_extension(".java"), do: ["Java"]
  defp language_for_extension(".kt"), do: ["Kotlin"]
  defp language_for_extension(".swift"), do: ["Swift"]
  defp language_for_extension(".c"), do: ["C/C++"]
  defp language_for_extension(".h"), do: ["C/C++"]
  defp language_for_extension(".cpp"), do: ["C/C++"]
  defp language_for_extension(".hpp"), do: ["C/C++"]
  defp language_for_extension(".cs"), do: ["C#"]
  defp language_for_extension(_extension), do: []

  defp top_level_dir(path) do
    case Path.split(path) do
      [file] -> if Path.extname(file) == "", do: file, else: "."
      [dir | _rest] -> dir
      [] -> nil
    end
  end

  defp nonempty_rows([], fallback), do: [fallback]
  defp nonempty_rows(rows, _fallback), do: rows

  defp skill_summary(context) do
    context.skills
    |> Enum.map(& &1.name)
    |> case do
      [] -> "no workspace skills loaded"
      names -> "skills: " <> Enum.join(names, ", ")
    end
  end

  defp plan_with_model(
         objective,
         %{"type" => "local"} = provider,
         context,
         files_result,
         memory_result,
         run_dir,
         opts
       ) do
    cond do
      opts[:model_chat] ->
        run_model_action_loop(
          objective,
          provider,
          context,
          files_result,
          memory_result,
          run_dir,
          opts
        )

      chat_mode?(opts) ->
        {:ok, local_chat_response(objective, provider, context, files_result, memory_result)}

      true ->
        {:ok, local_plan(objective, provider, context, files_result, memory_result)}
    end
  end

  defp plan_with_model(objective, provider, context, files_result, memory_result, run_dir, opts) do
    run_model_action_loop(
      objective,
      provider,
      context,
      files_result,
      memory_result,
      run_dir,
      opts
    )
  end

  defp run_model_action_loop(
         objective,
         provider,
         context,
         files_result,
         memory_result,
         run_dir,
         opts
       ) do
    messages = model_messages(objective, context, files_result, memory_result, opts)
    actions = model_actions(opts)
    tools = Enum.map(actions, &model_tool_definition/1)
    max_turns = max_tool_turns(provider, opts)

    do_model_action_loop(provider, run_dir, opts, messages, tools, max_turns, 1)
  end

  defp do_model_action_loop(_provider, _run_dir, _opts, _messages, _tools, max_turns, turn)
       when turn > max_turns do
    {:error, {:tool_turn_limit_exceeded, max_turns}}
  end

  defp do_model_action_loop(provider, run_dir, opts, messages, tools, max_turns, turn) do
    progress(run_dir, opts, :thinking, "Thinking through the request", %{"turn" => turn})

    Runs.append_event(run_dir, "model.requested", %{
      "provider" => provider["id"] || provider["type"],
      "model" => provider["model"],
      "turn" => turn,
      "tool_count" => length(tools)
    })

    record_llm_request(opts, provider, messages, tools, turn)

    model_opts =
      opts
      |> Keyword.put(:tools, tools)
      |> Keyword.put(:tool_choice, "auto")

    case Models.chat(provider, messages, model_opts) do
      {:ok, response} ->
        tool_calls = normalize_tool_calls(response["tool_calls"])
        content = Map.get(response, "content", "")
        content = OutputSanitizer.format_local_model_result(content)

        Runs.append_event(run_dir, "model.completed", %{
          "provider" => response["provider"],
          "model" => response["model"],
          "turn" => turn,
          "content_preview" => String.slice(content, 0, 180),
          "tool_call_count" => length(tool_calls),
          "finish_reason" => response["finish_reason"]
        })
        |> ignore_empty_event_fields()

        record_llm_response(opts, response, content, tool_calls, turn)

        if tool_calls == [] do
          {:ok, maybe_ensure_plan_heading(content, opts)}
        else
          Runs.append_event(run_dir, "model.tool_calls", %{
            "turn" => turn,
            "calls" => Enum.map(tool_calls, &tool_call_event/1)
          })

          with {:ok, tool_messages} <- execute_tool_calls(run_dir, tool_calls, opts, turn) do
            next_messages =
              messages ++
                [assistant_tool_call_message(content, tool_calls)] ++
                tool_messages

            do_model_action_loop(
              provider,
              run_dir,
              opts,
              next_messages,
              tools,
              max_turns,
              turn + 1
            )
          end
        end

      {:error, reason} ->
        progress(run_dir, opts, :failed, "Holt could not complete the model request")

        Runs.append_event(run_dir, "model.failed", %{
          "provider" => provider["id"] || provider["type"],
          "model" => provider["model"],
          "turn" => turn,
          "reason" => inspect(reason)
        })

        record_error(opts, "model_failed", reason)
        {:error, reason}
    end
  end

  defp model_actions(opts) do
    session = task_tool_session(opts)
    task_scoped? = task_ref(session) not in [nil, ""]

    opts =
      opts
      |> Keyword.put(:task_tool_session, session)

    %{"task_tool_session" => session}
    |> Actions.agent_tool_catalog(opts)
    |> Enum.filter(fn action ->
      get_in(action, ["availability", "route_status"]) == "accepted" and
        (action["requires_task_ref"] != true or task_scoped?)
    end)
  end

  defp model_tool_definition(action) do
    %{
      type: "function",
      function: %{
        name: action["name"],
        description: tool_description(action),
        parameters: action["input_schema"] || action["arguments_schema"] || empty_object_schema()
      }
    }
  end

  defp tool_description(action) do
    [
      action["description"],
      "effect_scope=#{action["effect_scope"]}",
      "requires_approval=#{action["requires_approval"] == true}"
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  defp empty_object_schema do
    %{"type" => "object", "properties" => %{}}
  end

  defp execute_tool_calls(run_dir, tool_calls, opts, turn) do
    tool_calls
    |> Enum.reduce_while({:ok, []}, fn call, {:ok, messages} ->
      case execute_action_tool_call(run_dir, call, opts, turn) do
        {:ok, message} ->
          {:cont, {:ok, [message | messages]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, messages} -> {:ok, Enum.reverse(messages)}
      error -> error
    end
  end

  defp execute_action_tool_call(run_dir, call, opts, turn) do
    tool_name = get_in(call, ["function", "name"])
    tool_call_id = call["id"]
    args = call |> get_in(["function", "arguments"]) |> decode_tool_arguments()
    args = maybe_put_default_task_ref(args, opts)

    emit_tool_event(
      run_dir,
      opts,
      "tool.started",
      ToolVisibility.started(tool_name, args, tool_call_id, opts)
    )

    approval_expected? = ToolVisibility.approval_expected?(tool_name, args, opts)

    if approval_expected? do
      emit_tool_event(
        run_dir,
        opts,
        "tool.approval_requested",
        ToolVisibility.approval_requested(tool_name, args, tool_call_id, opts)
      )
    end

    Runs.append_event(run_dir, "tool.requested", %{
      "tool" => tool_name,
      "tool_call_id" => tool_call_id,
      "args" => redact_args(args)
    })

    record_tool_invocation(opts, tool_name, args, tool_call_id, turn)

    if await_user_tool?(tool_name) and is_function(opts[:await_user_callback], 2) do
      execute_await_user_tool_call(run_dir, call, tool_name, args, opts, turn)
    else
      execute_regular_action_tool_call(
        run_dir,
        call,
        tool_name,
        args,
        opts,
        turn,
        approval_expected?
      )
    end
  end

  defp execute_regular_action_tool_call(
         run_dir,
         call,
         tool_name,
         args,
         opts,
         turn,
         approval_expected?
       ) do
    case Actions.execute(tool_name, args, opts) do
      {:ok, execution} ->
        if approval_expected? do
          emit_tool_event(
            run_dir,
            opts,
            "tool.approval_resolved",
            ToolVisibility.approval_resolved(tool_name, args, call["id"], "approved", opts)
          )
        end

        emit_tool_event(
          run_dir,
          opts,
          "tool.completed",
          ToolVisibility.completed(tool_name, args, execution, call["id"], opts)
          |> Map.merge(%{
            "result_status" => "ok",
            "result" => summarize_action_execution(execution)
          })
        )

        record_tool_result(opts, tool_name, execution, call["id"], turn)
        {:ok, tool_result_message(call, execution)}

      {:error, %{} = execution} ->
        if approval_expected? and execution["reason"] == "approval_denied" do
          emit_tool_event(
            run_dir,
            opts,
            "tool.approval_resolved",
            ToolVisibility.approval_resolved(tool_name, args, call["id"], "denied", opts)
          )
        end

        emit_tool_event(
          run_dir,
          opts,
          "tool.failed",
          ToolVisibility.failed(tool_name, args, Map.get(execution, "reason"), call["id"], opts)
          |> Map.merge(%{
            "result_status" => Map.get(execution, "status", "error"),
            "reason" => Map.get(execution, "reason"),
            "result" => summarize_action_execution(execution)
          })
        )

        record_tool_result(opts, tool_name, execution, call["id"], turn)

        if execution["reason"] == "approval_denied" do
          {:error, :approval_denied}
        else
          {:ok, tool_result_message(call, execution)}
        end

      {:error, :approval_denied} ->
        if approval_expected? do
          emit_tool_event(
            run_dir,
            opts,
            "tool.approval_resolved",
            ToolVisibility.approval_resolved(tool_name, args, call["id"], "denied", opts)
          )
        end

        progress(run_dir, opts, :blocked, "Waiting for approval")

        emit_tool_event(
          run_dir,
          opts,
          "tool.failed",
          ToolVisibility.failed(tool_name, args, :approval_denied, call["id"], opts)
          |> Map.merge(%{"result_status" => "error", "reason" => "approval_denied"})
        )

        record_tool_result(
          opts,
          tool_name,
          %{"status" => "error", "tool_name" => tool_name, "reason" => "approval_denied"},
          call["id"],
          turn
        )

        {:error, :approval_denied}

      {:error, reason} ->
        execution = %{
          "status" => "error",
          "tool_name" => tool_name,
          "reason" => inspect(reason)
        }

        emit_tool_event(
          run_dir,
          opts,
          "tool.failed",
          ToolVisibility.failed(tool_name, args, reason, call["id"], opts)
          |> Map.merge(%{"result_status" => "error", "reason" => inspect(reason)})
        )

        record_tool_result(opts, tool_name, execution, call["id"], turn)
        {:ok, tool_result_message(call, execution)}
    end
  end

  defp execute_await_user_tool_call(run_dir, call, tool_name, args, opts, turn) do
    tool_call_id = call["id"]
    question = user_question(args)

    progress(run_dir, opts, :waiting_for_input, "Waiting for your input", %{"tool" => tool_name})
    transition_run(run_dir, "awaiting_user")
    record_awaiting_user(opts, question, tool_call_id, turn)

    metadata =
      %{
        "tool_call_id" => tool_call_id,
        "turn" => turn,
        "await_timeout_ms" => opts[:await_timeout_ms]
      }
      |> reject_empty()

    case opts[:await_user_callback].(question, metadata) do
      {:ok, answer} ->
        transition_run(run_dir, "running")
        record_user_response(opts, answer, tool_call_id, turn)

        execution = %{
          "status" => "completed",
          "tool_name" => tool_name,
          "result" => %{"answer" => to_string(answer || "")}
        }

        emit_tool_event(
          run_dir,
          opts,
          "tool.completed",
          ToolVisibility.completed(tool_name, args, execution, tool_call_id, opts)
          |> Map.merge(%{
            "result_status" => "ok",
            "result" => summarize_action_execution(execution)
          })
        )

        record_tool_result(opts, tool_name, execution, tool_call_id, turn)
        {:ok, tool_result_message(call, execution)}

      {:error, reason} ->
        transition_run(run_dir, "running")
        record_error(opts, "await_user_failed", reason)

        emit_tool_event(
          run_dir,
          opts,
          "tool.failed",
          ToolVisibility.failed(tool_name, args, reason, tool_call_id, opts)
          |> Map.merge(%{"result_status" => "error", "reason" => inspect(reason)})
        )

        {:error, reason}

      answer ->
        transition_run(run_dir, "running")
        record_user_response(opts, answer, tool_call_id, turn)

        execution = %{
          "status" => "completed",
          "tool_name" => tool_name,
          "result" => %{"answer" => to_string(answer || "")}
        }

        emit_tool_event(
          run_dir,
          opts,
          "tool.completed",
          ToolVisibility.completed(tool_name, args, execution, tool_call_id, opts)
          |> Map.merge(%{
            "result_status" => "ok",
            "result" => summarize_action_execution(execution)
          })
        )

        record_tool_result(opts, tool_name, execution, tool_call_id, turn)
        {:ok, tool_result_message(call, execution)}
    end
  end

  defp await_user_tool?(tool_name), do: tool_name in ["ask_user", "ask_user_question"]

  defp user_question(args) do
    args["question"] ||
      args["prompt"] ||
      args["message"] ||
      "The agent needs user input to continue."
  end

  defp transition_run(run_dir, status) do
    case Runs.transition(run_dir, status) do
      {:ok, _run} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp normalize_tool_calls(tool_calls) when is_list(tool_calls) do
    tool_calls
    |> Enum.map(&RuntimeContracts.string_keys/1)
    |> Enum.filter(&(get_in(&1, ["function", "name"]) not in [nil, ""]))
  end

  defp normalize_tool_calls(_tool_calls), do: []

  defp assistant_tool_call_message(content, tool_calls) do
    %{
      "role" => "assistant",
      "content" => content,
      "tool_calls" => tool_calls
    }
  end

  defp tool_result_message(call, execution) do
    %{
      "role" => "tool",
      "tool_call_id" => call["id"],
      "name" => get_in(call, ["function", "name"]),
      "content" => Jason.encode!(execution)
    }
    |> reject_empty()
  end

  defp tool_call_event(call) do
    %{
      "id" => call["id"],
      "tool" => get_in(call, ["function", "name"]),
      "arguments_preview" =>
        call
        |> get_in(["function", "arguments"])
        |> decode_tool_arguments()
        |> redact_args()
    }
    |> reject_empty()
  end

  defp decode_tool_arguments(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> RuntimeContracts.string_keys(decoded)
      _other -> %{}
    end
  end

  defp decode_tool_arguments(value) when is_map(value), do: RuntimeContracts.string_keys(value)
  defp decode_tool_arguments(_value), do: %{}

  defp maybe_put_default_task_ref(args, opts) do
    cond do
      task_ref(args) not in [nil, ""] ->
        args

      task_ref_from_opts(opts) in [nil, ""] ->
        args

      true ->
        Map.put(args, "ref", task_ref_from_opts(opts))
    end
  end

  defp task_tool_session(opts) do
    attrs =
      case opts[:task_tool_session] do
        session when is_map(session) -> session
        _missing -> %{}
      end

    attrs
    |> RuntimeContracts.string_keys()
    |> maybe_put_missing("task_id", opts[:task_id])
    |> maybe_put_missing("task_ref", opts[:task_ref])
    |> maybe_put_missing("workspace", Paths.workspace_root(opts))
    |> TaskToolSession.build()
  end

  defp task_ref_from_opts(opts) do
    opts[:task_ref] || opts[:task_id]
  end

  defp task_ref(map) when is_map(map) do
    RuntimeContracts.value(map, "ref") ||
      RuntimeContracts.value(map, "task_ref") ||
      RuntimeContracts.value(map, "task_id")
  end

  defp task_ref(_value), do: nil

  defp maybe_put_missing(map, _key, value) when value in [nil, ""], do: map

  defp maybe_put_missing(map, key, value) do
    case Map.get(map, key) do
      current when current in [nil, ""] -> Map.put(map, key, value)
      _current -> map
    end
  end

  defp max_tool_turns(provider, opts) do
    (opts[:max_tool_turns] || provider["max_tool_turns"] || 8)
    |> normalize_positive_integer(8)
  end

  defp normalize_positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp normalize_positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _other -> default
    end
  end

  defp normalize_positive_integer(_value, default), do: default

  defp summarize_action_execution(execution) when is_map(execution) do
    execution
    |> Map.take(["status", "tool_name", "reason", "result", "route"])
    |> summarize_result()
  end

  defp ignore_empty_event_fields(event), do: event

  defp model_messages(objective, context, files_result, memory_result, opts) do
    files =
      files_result
      |> Map.get("files", [])
      |> Enum.take(40)
      |> Enum.join("\n")

    memories =
      memory_result
      |> Map.get("matches", [])
      |> Enum.take(8)
      |> Enum.map(&Map.get(&1, "text", ""))
      |> Enum.join("\n")

    chat_context = chat_context_section(opts)
    overview_files = overview_files_section(files_result)

    system =
      if chat_mode?(opts) do
        """
        You are Holt, a local project agent running inside a terminal.
        Work through a plan internally, use available tools when fresh workspace, task, memory, or network state is needed, and return the final user-facing output.
        Do not return NEXT_STEPS, implementation-plan boilerplate, run summaries, or artifact reports unless the user explicitly asks for a plan.
        If the user greets you, respond naturally and ask how you can help.
        If the user asks to read, inspect, understand, or summarize the repo/project/codebase/workspace, provide a concrete repository map from the supplied file list and key file excerpts instead of asking which file to start with.
        Only claim tool results that are present in the supplied context or tool messages.
        """
      else
        """
        You are Holt, a local project agent.
        Use available tools when fresh workspace, task, memory, or network state is needed.
        Return concise Markdown that starts with "# NEXT STEPS".
        Include: objective, workspace snapshot, skills used, relevant memory, and recommended next tasks.
        Only claim tool results that are present in the supplied context or tool messages.
        """
      end

    [
      %{
        "role" => "system",
        "content" => system
      },
      %{
        "role" => "user",
        "content" => """
        Objective:
        #{objective}

        Workspace context:
        #{Context.prompt_section(context)}

        Prior chat context:
        #{chat_context}

        Files:
        #{files}

        Key file excerpts:
        #{overview_files}

        Relevant memory:
        #{memories}
        """
      }
    ]
  end

  defp maybe_ensure_plan_heading(content, opts) do
    if chat_mode?(opts) do
      String.trim(to_string(content))
    else
      ensure_plan_heading(content)
    end
  end

  defp chat_context_section(opts) do
    opts
    |> Keyword.get(:chat_context)
    |> case do
      value when value in [nil, ""] -> "none"
      value -> String.slice(to_string(value), 0, 4_000)
    end
  end

  defp overview_files_section(files_result) do
    files_result
    |> Map.get("overview_files", [])
    |> Enum.map(fn
      %{"path" => path, "content" => content} ->
        excerpt =
          content
          |> to_string()
          |> String.slice(0, 1_200)

        """
        ## #{path}
        #{excerpt}
        """

      %{"path" => path, "error" => error} ->
        """
        ## #{path}
        Read failed: #{error}
        """
    end)
    |> case do
      [] -> "none"
      sections -> Enum.join(sections, "\n")
    end
  end

  defp ensure_plan_heading(content) do
    content = String.trim(to_string(content))

    case content do
      <<"# NEXT STEPS", _rest::binary>> -> content
      _ -> "# NEXT STEPS\n\n#{content}"
    end
  end

  defp chat_mode?(opts), do: opts[:mode] in ["chat", :chat]

  defp chat_intent(objective, opts) do
    all_tokens = chat_tokens([opts[:chat_context], objective])
    objective_tokens = chat_tokens([objective])

    workspace_target? =
      any_token?(all_tokens, ~w(repo repository project codebase workspace folder directory))

    overview_action? =
      any_token?(all_tokens, ~w(read inspect review scan understand summarize map analyze))

    broad_scope? = any_token?(objective_tokens, ~w(entire whole all everything full))

    if workspace_target? and (overview_action? or broad_scope?) do
      :workspace_overview
    else
      :general
    end
  end

  defp chat_tokens(values) do
    values
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.flat_map(fn value ->
      value
      |> to_string()
      |> String.downcase()
      |> String.split([" ", "\n", "\t", "\r", ".", ",", "?", "!", ":", ";", "(", ")", "[", "]"])
    end)
    |> Enum.reject(&(&1 == ""))
  end

  defp any_token?(tokens, candidates), do: Enum.any?(tokens, &(&1 in candidates))

  defp context_event(context) do
    %{
      "workspace" => context.workspace,
      "skills" => Enum.map(context.skills, & &1.name),
      "memory_count" => length(context.memories)
    }
  end

  defp redact_args(args) do
    args
    |> Enum.map(fn
      {"content", content} -> {"content_preview", content |> to_string() |> String.slice(0, 120)}
      {"text", text} -> {"text_preview", text |> to_string() |> String.slice(0, 120)}
      pair -> pair
    end)
    |> Map.new()
  end

  defp summarize_result(result) when is_map(result) do
    result
    |> Enum.map(fn
      {"content", content} -> {"content_preview", content |> to_string() |> String.slice(0, 120)}
      {"body", body} -> {"body_preview", body |> to_string() |> String.slice(0, 120)}
      {"files", files} when is_list(files) -> {"file_count", length(files)}
      pair -> pair
    end)
    |> Map.new()
  end

  defp summarize_result(result), do: result

  defp agent_event_runtime_opts(opts, run, provider, root) do
    opts
    |> Keyword.put(:workspace, root)
    |> Keyword.put(:run_id, run["id"])
    |> Keyword.put(:run_dir, run["run_dir"])
    |> Keyword.put(:agent_event_session_id, opts[:agent_event_session_id] || run["id"])
    |> Keyword.put(:trace_id, "trace:#{run["id"]}")
    |> Keyword.put_new(:agent_id, run["agent"] || "default")
    |> Keyword.put(:provider, provider["id"] || provider["type"])
  end

  defp record_session_result(session_id, result, opts) do
    case result do
      {:ok, %{run: %{} = run}} ->
        EventRecorder.session_ended(
          session_id,
          run["status"] || "completed",
          agent_event_opts(opts)
        )

      {:error, %{run: %{} = run, reason: reason}} ->
        EventRecorder.error(session_id, "runtime_failed", reason, agent_event_opts(opts))
        EventRecorder.session_ended(session_id, run["status"] || "failed", agent_event_opts(opts))

      {:error, reason} ->
        EventRecorder.error(session_id, "runtime_failed", reason, agent_event_opts(opts))
        EventRecorder.session_ended(session_id, "failed", agent_event_opts(opts))

      _other ->
        EventRecorder.session_ended(session_id, "completed", agent_event_opts(opts))
    end
  end

  defp record_user_message(opts, content, turn) do
    with session_id when is_binary(session_id) <- agent_event_session_id(opts) do
      EventRecorder.user_message(session_id, content, agent_event_opts(opts, turn: turn))
    end
  end

  defp record_llm_request(opts, provider, messages, tools, turn) do
    with session_id when is_binary(session_id) <- agent_event_session_id(opts) do
      EventRecorder.llm_request(
        session_id,
        agent_event_opts(opts,
          provider: provider["id"] || provider["type"],
          model: provider["model"],
          message_count: length(messages),
          tool_count: length(tools),
          turn: turn
        )
      )
    end
  end

  defp record_llm_response(opts, response, content, tool_calls, turn) do
    with session_id when is_binary(session_id) <- agent_event_session_id(opts) do
      EventRecorder.llm_response(
        session_id,
        agent_event_opts(opts,
          provider: response["provider"],
          model: response["model"],
          content_length: String.length(content || ""),
          tool_calls_count: length(tool_calls),
          finish_reason: response["finish_reason"],
          turn: turn
        )
      )
    end
  end

  defp record_tool_invocation(opts, tool_name, args, tool_call_id, turn) do
    with session_id when is_binary(session_id) <- agent_event_session_id(opts) do
      EventRecorder.tool_invocation(
        session_id,
        tool_name,
        args,
        agent_event_opts(opts, tool_call_id: tool_call_id, turn: turn)
      )
    end
  end

  defp record_tool_result(opts, tool_name, result, tool_call_id, turn) do
    with session_id when is_binary(session_id) <- agent_event_session_id(opts) do
      EventRecorder.tool_result(
        session_id,
        tool_name,
        result,
        agent_event_opts(opts, tool_call_id: tool_call_id, turn: turn)
      )
    end
  end

  defp record_awaiting_user(opts, question, tool_call_id, turn) do
    with session_id when is_binary(session_id) <- agent_event_session_id(opts) do
      EventRecorder.awaiting_user(
        session_id,
        question,
        agent_event_opts(opts, tool_call_id: tool_call_id, turn: turn)
      )
    end
  end

  defp record_user_response(opts, answer, tool_call_id, turn) do
    with session_id when is_binary(session_id) <- agent_event_session_id(opts) do
      EventRecorder.user_response(
        session_id,
        answer,
        agent_event_opts(opts, tool_call_id: tool_call_id, turn: turn)
      )
    end
  end

  defp record_error(opts, error_type, reason) do
    with session_id when is_binary(session_id) <- agent_event_session_id(opts) do
      EventRecorder.error(session_id, error_type, reason, agent_event_opts(opts))
    end
  end

  defp emit_stream_chunk(opts, content, extra) do
    content = to_string(content || "")

    if content != "" do
      with session_id when is_binary(session_id) <- agent_event_session_id(opts) do
        EventRecorder.stream_chunk(session_id, content, agent_event_opts(opts, extra))
      end

      emit_runtime_event(opts, %{"type" => "stream_chunk", "content" => content})
    end

    :ok
  end

  defp emit_runtime_event(opts, event) do
    case opts[:runtime_event_callback] do
      callback when is_function(callback, 1) -> callback.(event)
      _missing -> :ok
    end
  end

  defp agent_event_session_id(opts), do: opts[:agent_event_session_id]

  defp agent_event_opts(opts, extra \\ []) do
    [
      workspace: Paths.workspace_root(opts),
      run_id: opts[:run_id],
      run_dir: opts[:run_dir],
      trace_id: opts[:trace_id],
      agent_id: opts[:agent_id] || opts[:agent],
      provider: opts[:provider]
    ]
    |> Keyword.merge(extra)
  end

  defp reject_empty(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end

  defp maybe_put_resumed_from(opts) do
    case opts[:resumed_from] do
      nil -> opts
      id -> Keyword.put(opts, :resumed_from, id)
    end
  end
end
