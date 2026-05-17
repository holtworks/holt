defmodule HoltWorks.Runtime do
  @moduledoc """
  Local agent runtime loop for the V0 HoltWorks core.
  """

  alias HoltWorks.Runtime.{Context, EventRecorder, Runs}
  alias HoltWorks.Tasks.OutputSanitizer
  alias HoltWorks.Tasks.{RuntimeContracts, TaskToolSession}
  alias HoltWorks.{Actions, Clock, Config, Memory, Models, Paths, Tools, Workspace}

  def run(objective, opts \\ []) when is_binary(objective) do
    home = Paths.home(opts)
    root = Paths.workspace_root(opts)
    HoltWorks.Env.load(opts)
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
      "gateway" => HoltWorks.Gateway.status(opts)
    }
  end

  defp execute_local_loop(objective, provider, run_dir, opts) do
    context = Context.build(objective, opts)
    Runs.append_event(run_dir, "context.built", context_event(context))
    Runs.append_transcript(run_dir, "user", objective)
    record_user_message(opts, objective, 0)

    with {:ok, files_result} <- execute_tool(run_dir, "list_files", %{"limit" => 80}, opts),
         {:ok, memory_result} <-
           execute_tool(run_dir, "search_memory", %{"query" => objective}, opts),
         {:ok, plan} <-
           plan_with_model(
             objective,
             provider,
             context,
             files_result,
             memory_result,
             run_dir,
             opts
           ) do
      persist_plan(objective, provider, run_dir, plan, opts)
    else
      {:error, :approval_denied} ->
        {:ok, run} =
          Runs.block(run_dir, "action approval denied", %{
            "failure_class" => "approval_denied",
            "blocker_code" => "approval_denied"
          })

        {:ok, %{run: run, output: nil, artifact: nil}}

      {:error, reason} ->
        {:ok, run} = Runs.fail(run_dir, reason)
        {:error, %{run: run, reason: reason}}
    end
  end

  defp persist_plan(objective, provider, run_dir, plan, opts) do
    Runs.append_transcript(run_dir, "assistant", plan)
    emit_stream_chunk(opts, plan, turn: 0)

    write_args = %{
      "path" => "NEXT_STEPS.md",
      "content" => plan,
      "reason" => "Persist the first Holtworks run artifact."
    }

    case execute_tool(run_dir, "write_file", write_args, opts) do
      {:ok, write_result} ->
        Memory.save(
          "summary",
          "Last Holtworks run created NEXT_STEPS.md for: #{objective}",
          Keyword.merge(opts, source_run_id: Runs.load_run!(run_dir)["id"])
        )

        {:ok, run} =
          Runs.complete(run_dir, %{
            "artifact" => Map.get(write_result, "path"),
            "provider" => provider["id"] || provider["type"]
          })

        {:ok, %{run: run, output: plan, artifact: write_result}}

      {:error, :approval_denied} ->
        {:ok, run} =
          Runs.block(run_dir, "write_file approval denied", %{
            "failure_class" => "approval_denied",
            "blocker_code" => "approval_denied"
          })

        {:ok, %{run: run, output: plan, artifact: nil}}

      {:error, reason} ->
        {:ok, run} = Runs.fail(run_dir, reason)
        {:error, %{run: run, reason: reason}}
    end
  end

  defp execute_tool(run_dir, name, args, opts) do
    tool_call_id = Clock.id("tool_call")
    Runs.append_event(run_dir, "tool.requested", %{"tool" => name, "args" => redact_args(args)})
    record_tool_invocation(opts, name, args, tool_call_id, 0)

    case Tools.execute(name, args, opts) do
      {:ok, result} ->
        Runs.append_event(run_dir, "tool.completed", %{
          "tool" => name,
          "status" => "ok",
          "result" => summarize_result(result)
        })

        record_tool_result(opts, name, %{"status" => "ok", "result" => result}, tool_call_id, 0)
        {:ok, result}

      {:error, reason} ->
        Runs.append_event(run_dir, "tool.failed", %{
          "tool" => name,
          "status" => "error",
          "reason" => inspect(reason)
        })

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
    3. Run `holtworks memory search "<topic>"` before follow-up tasks.
    4. Keep write and shell approvals enabled until the workflow is trusted.
    """
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
    if opts[:model_chat] do
      run_model_action_loop(
        objective,
        provider,
        context,
        files_result,
        memory_result,
        run_dir,
        opts
      )
    else
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
    messages = model_messages(objective, context, files_result, memory_result)
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
          {:ok, ensure_plan_heading(content)}
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
    args = call |> get_in(["function", "arguments"]) |> decode_tool_arguments()
    args = maybe_put_default_task_ref(args, opts)

    Runs.append_event(run_dir, "tool.requested", %{
      "tool" => tool_name,
      "tool_call_id" => call["id"],
      "args" => redact_args(args)
    })

    record_tool_invocation(opts, tool_name, args, call["id"], turn)

    if await_user_tool?(tool_name) and is_function(opts[:await_user_callback], 2) do
      execute_await_user_tool_call(run_dir, call, tool_name, args, opts, turn)
    else
      execute_regular_action_tool_call(run_dir, call, tool_name, args, opts, turn)
    end
  end

  defp execute_regular_action_tool_call(run_dir, call, tool_name, args, opts, turn) do
    case Actions.execute(tool_name, args, opts) do
      {:ok, execution} ->
        Runs.append_event(run_dir, "tool.completed", %{
          "tool" => tool_name,
          "tool_call_id" => call["id"],
          "status" => "ok",
          "result" => summarize_action_execution(execution)
        })

        record_tool_result(opts, tool_name, execution, call["id"], turn)
        {:ok, tool_result_message(call, execution)}

      {:error, %{} = execution} ->
        Runs.append_event(run_dir, "tool.failed", %{
          "tool" => tool_name,
          "tool_call_id" => call["id"],
          "status" => Map.get(execution, "status", "error"),
          "reason" => Map.get(execution, "reason"),
          "result" => summarize_action_execution(execution)
        })

        record_tool_result(opts, tool_name, execution, call["id"], turn)

        if execution["reason"] == "approval_denied" do
          {:error, :approval_denied}
        else
          {:ok, tool_result_message(call, execution)}
        end

      {:error, :approval_denied} ->
        Runs.append_event(run_dir, "tool.failed", %{
          "tool" => tool_name,
          "tool_call_id" => call["id"],
          "status" => "error",
          "reason" => "approval_denied"
        })

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

        Runs.append_event(run_dir, "tool.failed", %{
          "tool" => tool_name,
          "tool_call_id" => call["id"],
          "status" => "error",
          "reason" => inspect(reason)
        })

        record_tool_result(opts, tool_name, execution, call["id"], turn)
        {:ok, tool_result_message(call, execution)}
    end
  end

  defp execute_await_user_tool_call(run_dir, call, tool_name, args, opts, turn) do
    tool_call_id = call["id"]
    question = user_question(args)

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

        Runs.append_event(run_dir, "tool.completed", %{
          "tool" => tool_name,
          "tool_call_id" => tool_call_id,
          "status" => "ok",
          "result" => summarize_action_execution(execution)
        })

        record_tool_result(opts, tool_name, execution, tool_call_id, turn)
        {:ok, tool_result_message(call, execution)}

      {:error, reason} ->
        transition_run(run_dir, "running")
        record_error(opts, "await_user_failed", reason)

        Runs.append_event(run_dir, "tool.failed", %{
          "tool" => tool_name,
          "tool_call_id" => tool_call_id,
          "status" => "error",
          "reason" => inspect(reason)
        })

        {:error, reason}

      answer ->
        transition_run(run_dir, "running")
        record_user_response(opts, answer, tool_call_id, turn)

        execution = %{
          "status" => "completed",
          "tool_name" => tool_name,
          "result" => %{"answer" => to_string(answer || "")}
        }

        Runs.append_event(run_dir, "tool.completed", %{
          "tool" => tool_name,
          "tool_call_id" => tool_call_id,
          "status" => "ok",
          "result" => summarize_action_execution(execution)
        })

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

  defp model_messages(objective, context, files_result, memory_result) do
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

    [
      %{
        "role" => "system",
        "content" => """
        You are HoltWorks, a local-first corporate agent runtime.
        Use available tools when fresh workspace, task, memory, or network state is needed.
        Return concise Markdown that starts with "# NEXT STEPS".
        Include: objective, workspace snapshot, skills used, relevant memory, and recommended next tasks.
        Only claim tool results that are present in the supplied context or tool messages.
        """
      },
      %{
        "role" => "user",
        "content" => """
        Objective:
        #{objective}

        Workspace context:
        #{Context.prompt_section(context)}

        Files:
        #{files}

        Relevant memory:
        #{memories}
        """
      }
    ]
  end

  defp ensure_plan_heading(content) do
    content = String.trim(to_string(content))

    case content do
      <<"# NEXT STEPS", _rest::binary>> -> content
      _ -> "# NEXT STEPS\n\n#{content}"
    end
  end

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
