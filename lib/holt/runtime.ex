defmodule Holt.Runtime do
  @moduledoc """
  Local agent loop for Holt.
  """

  alias Holt.Runtime.{ChatMessages, Context, EventRecorder, Runs}
  alias Holt.Actions.{Executor, ProviderAdapter, Registry}
  alias Holt.Tasks.OutputSanitizer
  alias Holt.Tasks.ActionSession

  alias Holt.{
    Clock,
    Config,
    Memory,
    Models,
    Paths,
    LocalActions,
    ActionVisibility,
    Workspace
  }

  def run(objective, opts \\ []) when is_binary(objective) do
    with :ok <- validate_runtime_opts(opts) do
      home = Paths.home(opts)
      root = Paths.workspace_root(opts)
      Holt.Env.load(opts)
      Config.bootstrap(home: home)
      workspace_initialized? = Workspace.initialized?(root)
      {:ok, pre_task_plan} = pre_task_plan(opts, workspace_initialized?)
      maybe_init_workspace(root, pre_task_plan)
      provider = runtime_provider(home, opts)
      model = provider_runtime_model(provider)

      run_opts =
        opts
        |> Keyword.merge(model: model)
        |> maybe_put_resumed_from()
        |> maybe_put_forked_from()
        |> Keyword.put(:pre_task_plan, pre_task_plan)
        |> Keyword.put(:workspace_discovery, pre_task_plan["workspace_discovery"])

      with {:ok, run} <- start_run(objective, run_opts, pre_task_plan),
           run_dir <- run["run_dir"],
           {:ok, _run} <- Runs.transition(run_dir, "running") do
        runtime_opts =
          opts
          |> agent_event_runtime_opts(run, provider, root, pre_task_plan)
          |> put_pre_task_plan_opts(pre_task_plan)

        session_id = runtime_opts[:agent_event_session_id]

        maybe_record_session_started(
          session_id,
          agent_event_opts(runtime_opts,
            objective: objective,
            model: model,
            provider: provider_id(provider)
          )
        )

        progress(run_dir, runtime_opts, :started, "Starting request")
        result = execute_local_loop(objective, provider, run_dir, runtime_opts)
        record_session_result(session_id, result, runtime_opts)
        result
      end
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

  def fork(run_ref \\ "latest", opts \\ []) do
    root = Paths.workspace_root(opts)

    case Runs.find(root, run_ref) do
      nil ->
        {:error, :run_not_found}

      run ->
        objective = fork_objective(opts, run)

        opts
        |> Keyword.delete(:objective)
        |> Keyword.put(:forked_from, run["id"])
        |> then(&run(objective, &1))
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

  defp validate_runtime_opts(opts) do
    cond do
      Keyword.has_key?(opts, :chat_context) ->
        {:error, {:obsolete_opt, :chat_context, :chat_messages}}

      true ->
        with :ok <- validate_runtime_contract(opts),
             :ok <- validate_workspace_persistence(opts),
             :ok <- validate_workspace_intent(opts),
             :ok <- validate_workspace_persistence_contract(opts) do
          opts
          |> Keyword.get(:chat_messages, [])
          |> ChatMessages.normalize()
          |> case do
            {:ok, _messages} -> :ok
            {:error, reason} -> {:error, reason}
          end
        end
    end
  end

  defp validate_runtime_contract(opts) do
    contract = Keyword.get(opts, :runtime_contract)
    mode = Keyword.get(opts, :mode)

    cond do
      contract in [nil, ""] ->
        :ok

      mode not in [nil, ""] ->
        {:error, {:conflicting_runtime_contract, "runtime_contract", "mode"}}

      contract in ["chat_turn", :chat_turn, "goal", :goal] ->
        :ok

      true ->
        {:error, {:unsupported_runtime_contract, contract}}
    end
  end

  defp validate_workspace_persistence(opts) do
    case Keyword.get(opts, :workspace_persistence) do
      nil -> :ok
      "workspace" -> :ok
      "ephemeral" -> :ok
      value -> {:error, {:unsupported_workspace_persistence, value}}
    end
  end

  defp validate_workspace_intent(opts) do
    case Keyword.get(opts, :workspace_intent) do
      nil -> :ok
      "none" -> :ok
      "explore_project" -> :ok
      value -> {:error, {:unsupported_workspace_intent, value}}
    end
  end

  defp validate_workspace_persistence_contract(opts) do
    case {Keyword.get(opts, :workspace_persistence), runtime_contract(opts), run_lineage(opts)} do
      {"ephemeral", :plan_artifact, _lineage} ->
        {:error,
         {:conflicting_workspace_persistence, "workspace_persistence", "runtime_contract"}}

      {"ephemeral", :goal, _lineage} ->
        {:error,
         {:conflicting_workspace_persistence, "workspace_persistence", "runtime_contract"}}

      {"ephemeral", _contract, "resumed_from"} ->
        {:error, {:conflicting_workspace_persistence, "workspace_persistence", "resumed_from"}}

      {"ephemeral", _contract, "forked_from"} ->
        {:error, {:conflicting_workspace_persistence, "workspace_persistence", "forked_from"}}

      _allowed ->
        :ok
    end
  end

  defp runtime_contract(opts) do
    case explicit_runtime_contract(Keyword.get(opts, :runtime_contract)) do
      {:ok, contract} -> contract
      :none -> mode_runtime_contract(Keyword.get(opts, :mode))
    end
  end

  defp explicit_runtime_contract(nil), do: :none
  defp explicit_runtime_contract(""), do: :none
  defp explicit_runtime_contract("chat_turn"), do: {:ok, :chat_turn}
  defp explicit_runtime_contract(:chat_turn), do: {:ok, :chat_turn}
  defp explicit_runtime_contract("goal"), do: {:ok, :goal}
  defp explicit_runtime_contract(:goal), do: {:ok, :goal}

  defp mode_runtime_contract("chat"), do: :chat_turn
  defp mode_runtime_contract(:chat), do: :chat_turn
  defp mode_runtime_contract(_mode), do: :plan_artifact

  defp chat_turn_contract?(opts), do: runtime_contract(opts) == :chat_turn
  defp goal_contract?(opts), do: runtime_contract(opts) == :goal

  defp pre_task_plan(opts, workspace_initialized?) do
    contract = runtime_contract(opts)
    intent = workspace_intent(opts)
    {persistence, reason} = workspace_persistence_decision(opts, contract)
    discovery = workspace_discovery_decision(persistence, intent, workspace_initialized?)

    {:ok,
     %{
       "schema_version" => "holt_pre_task_plan/v1",
       "runtime_contract" => Atom.to_string(contract),
       "workspace_persistence" => persistence,
       "workspace_discovery" => discovery,
       "workspace_intent" => intent,
       "reason" => reason
     }}
  end

  defp workspace_intent(opts) do
    case Keyword.get(opts, :workspace_intent) do
      intent when is_binary(intent) and intent != "" -> intent
      _missing -> "none"
    end
  end

  defp workspace_persistence_decision(opts, contract) do
    case Keyword.get(opts, :workspace_persistence) do
      "workspace" ->
        {"workspace", "explicit_workspace_persistence"}

      "ephemeral" ->
        {"ephemeral", "explicit_workspace_persistence"}

      nil ->
        default_workspace_persistence_decision(contract, run_lineage(opts))
    end
  end

  defp default_workspace_persistence_decision(:plan_artifact, _lineage),
    do: {"workspace", "runtime_contract_requires_workspace"}

  defp default_workspace_persistence_decision(:goal, _lineage),
    do: {"workspace", "runtime_contract_requires_workspace"}

  defp default_workspace_persistence_decision(:chat_turn, "resumed_from"),
    do: {"workspace", "run_lineage_requires_workspace"}

  defp default_workspace_persistence_decision(:chat_turn, "forked_from"),
    do: {"workspace", "run_lineage_requires_workspace"}

  defp default_workspace_persistence_decision(:chat_turn, "none"),
    do: {"ephemeral", "chat_turn_without_workspace_write"}

  defp workspace_discovery_decision(_persistence, "explore_project", _workspace_initialized?),
    do: "project_context"

  defp workspace_discovery_decision("workspace", "none", true), do: "project_context"

  defp workspace_discovery_decision(_persistence, "none", _workspace_initialized?),
    do: "agent_instructions_only"

  defp run_lineage(opts) do
    case {Keyword.get(opts, :resumed_from), Keyword.get(opts, :forked_from)} do
      {resumed_from, _forked_from} when resumed_from not in [nil, ""] -> "resumed_from"
      {_resumed_from, forked_from} when forked_from not in [nil, ""] -> "forked_from"
      _lineage -> "none"
    end
  end

  defp maybe_init_workspace(root, %{"workspace_persistence" => "workspace"}),
    do: Workspace.init(root)

  defp maybe_init_workspace(_root, %{"workspace_persistence" => "ephemeral"}), do: :ok

  defp start_run(objective, opts, %{"workspace_persistence" => "workspace"}),
    do: Runs.start(objective, opts)

  defp start_run(objective, opts, %{"workspace_persistence" => "ephemeral"}),
    do: Runs.start_ephemeral(objective, opts)

  defp runtime_provider(home, opts) do
    provider =
      case Keyword.get(opts, :provider) do
        provider_id when is_binary(provider_id) and provider_id != "" ->
          Models.provider(home, provider_id)

        _default ->
          Models.default_provider(home)
      end

    provider
    |> maybe_put_provider_opt("model", Keyword.get(opts, :model))
    |> maybe_put_provider_opt("base_url", Keyword.get(opts, :base_url))
    |> maybe_put_provider_opt("api_key_env", Keyword.get(opts, :api_key_env))
  end

  defp maybe_put_provider_opt(provider, _key, value) when value in [nil, ""], do: provider
  defp maybe_put_provider_opt(provider, key, value), do: Map.put(provider, key, value)

  defp provider_id(%{"id" => id}) when is_binary(id) and id != "", do: id

  defp provider_id(provider) do
    raise ArgumentError, "runtime provider requires a non-empty id: #{inspect(provider)}"
  end

  defp provider_type(%{"type" => type}) when is_binary(type) and type != "", do: type

  defp provider_type(provider) do
    raise ArgumentError, "runtime provider requires a non-empty type: #{inspect(provider)}"
  end

  defp provider_model(%{"model" => model}) when is_binary(model) and model != "", do: model

  defp provider_model(%{"type" => "unknown"} = provider), do: provider_id(provider)

  defp provider_model(provider) do
    raise ArgumentError, "runtime provider requires a non-empty model: #{inspect(provider)}"
  end

  defp provider_runtime_model(provider),
    do: "#{provider_type(provider)}:#{provider_model(provider)}"

  defp execute_local_loop(objective, provider, run_dir, opts) do
    discovery_mode? = directory_discovery_mode?(opts)

    reading_message =
      if discovery_mode?, do: "Reading agent instructions", else: "Reading project context"

    progress(run_dir, opts, :reading, reading_message)
    context = Context.build(objective, opts)
    Runs.append_event(run_dir, "context.built", context_event(context))
    Runs.append_transcript(run_dir, "user", objective)
    record_user_message(opts, objective, 0)

    with {:ok, files_result} <- discovery_files_result(run_dir, opts),
         {:ok, memory_result} <- discovery_memory_result(objective, run_dir, opts),
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

  defp discovery_files_result(run_dir, opts) do
    if directory_discovery_mode?(opts) do
      {:ok,
       %{
         "files" => [],
         "discovery_mode" => "agent_instructions_only",
         "agent_instruction_file" => Workspace.agent_instruction_file()
       }}
    else
      execute_action(run_dir, "list", %{"limit" => 80}, opts)
    end
  end

  defp discovery_memory_result(objective, run_dir, opts) do
    if directory_discovery_mode?(opts) do
      {:ok, %{"matches" => [], "discovery_mode" => "agent_instructions_only"}}
    else
      execute_action(run_dir, "recall", %{"query" => objective}, opts)
    end
  end

  defp put_pre_task_plan_opts(opts, pre_task_plan) do
    opts
    |> Keyword.put(:pre_task_plan, pre_task_plan)
    |> Keyword.put(:workspace_persistence, pre_task_plan["workspace_persistence"])
    |> Keyword.put(:workspace_discovery, pre_task_plan["workspace_discovery"])
    |> Keyword.put(:workspace_intent, pre_task_plan["workspace_intent"])
    |> put_workspace_discovery_mode(pre_task_plan)
  end

  defp put_workspace_discovery_mode(opts, %{"workspace_discovery" => "agent_instructions_only"}),
    do: Keyword.put(opts, :directory_discovery_mode, "agent_instructions_only")

  defp put_workspace_discovery_mode(opts, %{"workspace_discovery" => "project_context"}),
    do: Keyword.delete(opts, :directory_discovery_mode)

  defp directory_discovery_mode?(opts),
    do: Keyword.get(opts, :directory_discovery_mode) == "agent_instructions_only"

  defp maybe_enrich_chat_files(objective, run_dir, files_result, opts) do
    intent = chat_intent(objective, opts)

    files_result =
      files_result
      |> Map.put("chat_intent", Atom.to_string(intent))
      |> Map.put("chat_messages", chat_messages(opts))

    if chat_turn_contract?(opts) and intent == :workspace_overview and
         not directory_discovery_mode?(opts) do
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
    case execute_action(run_dir, "read", %{"path" => path}, opts) do
      {:ok, result} ->
        result

      {:error, reason} ->
        %{"path" => path, "error" => inspect(reason)}
    end
  end

  defp overview_file_candidates(files) do
    files
    |> Enum.filter(&(&1 == Workspace.agent_instruction_file()))
    |> Enum.take(1)
  end

  defp persist_output(objective, provider, run_dir, output, opts) do
    case runtime_contract(opts) do
      :chat_turn -> complete_chat_run(provider, run_dir, output, opts)
      :goal -> complete_goal_run(objective, provider, run_dir, output, opts)
      :plan_artifact -> persist_plan(objective, provider, run_dir, output, opts)
    end
  end

  defp complete_chat_run(provider, run_dir, output, opts) do
    Runs.append_transcript(run_dir, "assistant", output)
    emit_stream_chunk(opts, output, turn: 0)
    progress(run_dir, opts, :completed, "Completed")

    {:ok, run} =
      Runs.complete(run_dir, %{
        "provider" => provider_id(provider)
      })

    {:ok, %{run: run, output: output, artifact: nil}}
  end

  defp complete_goal_run(objective, provider, run_dir, output, opts) do
    Runs.append_transcript(run_dir, "assistant", output)
    emit_stream_chunk(opts, output, turn: 0)
    progress(run_dir, opts, :completed, "Completed")

    {:ok, run} =
      Runs.complete(run_dir, %{
        "provider" => provider_id(provider),
        "runtime_contract" => "goal"
      })

    Memory.save(
      "goal",
      objective,
      Keyword.merge(opts, source_run_id: run["id"])
    )

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

    case execute_action(run_dir, "write", write_args, opts) do
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
            "provider" => provider_id(provider)
          })

        {:ok, %{run: run, output: plan, artifact: write_result}}

      {:error, :approval_denied} ->
        progress(run_dir, opts, :blocked, "Waiting for approval")

        {:ok, run} =
          Runs.block(run_dir, "write approval denied", %{
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

  defp execute_action(run_dir, name, args, opts) do
    action_call_id = Clock.id("action_call")

    emit_action_event(
      run_dir,
      opts,
      "action.started",
      ActionVisibility.started(name, args, action_call_id, opts)
    )

    approval_expected? = ActionVisibility.approval_expected?(name, args, opts)

    if approval_expected? do
      emit_action_event(
        run_dir,
        opts,
        "action.approval_requested",
        ActionVisibility.approval_requested(name, args, action_call_id, opts)
      )
    end

    Runs.append_event(run_dir, "action.requested", %{
      "action" => name,
      "args" => redact_args(args)
    })

    record_action_invocation(opts, name, args, action_call_id, 0)

    case LocalActions.execute(name, args, opts) do
      {:ok, result} ->
        if approval_expected? do
          emit_action_event(
            run_dir,
            opts,
            "action.approval_resolved",
            ActionVisibility.approval_resolved(name, args, action_call_id, "approved", opts)
          )
        end

        emit_action_event(
          run_dir,
          opts,
          "action.completed",
          ActionVisibility.completed(name, args, result, action_call_id, opts)
          |> Map.merge(%{"result_status" => "ok", "result" => summarize_result(result)})
        )

        record_action_result(
          opts,
          name,
          %{"status" => "ok", "result" => result},
          action_call_id,
          0
        )

        {:ok, result}

      {:error, reason} ->
        if approval_expected? and reason == :approval_denied do
          emit_action_event(
            run_dir,
            opts,
            "action.approval_resolved",
            ActionVisibility.approval_resolved(name, args, action_call_id, "denied", opts)
          )
        end

        emit_action_event(
          run_dir,
          opts,
          "action.failed",
          ActionVisibility.failed(name, args, reason, action_call_id, opts)
          |> Map.merge(%{"result_status" => "error", "reason" => inspect(reason)})
        )

        record_action_result(
          opts,
          name,
          %{"status" => "error", "reason" => inspect(reason)},
          action_call_id,
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

  defp emit_action_event(run_dir, opts, type, data) do
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

    Provider: #{provider_runtime_model(provider)}

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

  defp local_goal_response(objective, provider, context, files_result, memory_result) do
    file_count = files_result |> Map.get("files", []) |> length()
    memory_count = memory_result |> Map.get("matches", []) |> length()

    skills =
      context.skills
      |> Enum.map(& &1.name)
      |> case do
        [] -> "no workspace skills loaded"
        names -> Enum.join(names, ", ")
      end

    """
    Goal: #{objective}

    Runtime contract: goal
    Provider: #{provider_runtime_model(provider)}
    Context: #{file_count} workspace files, #{memory_count} memory matches, #{skills}.

    Next action: start build mode with the first concrete change for this goal.
    """
    |> String.trim()
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
    if files_result["discovery_mode"] == "agent_instructions_only" do
      """
      Hello. I'm Holt.

      I loaded only #{context.agent_instruction_file} for this new directory. What should we work on next?
      """
      |> String.trim()
    else
      local_general_chat_response_loaded(context, files_result, memory_result)
    end
  end

  defp local_general_chat_response_loaded(context, files_result, memory_result) do
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
    if files_result["discovery_mode"] == "agent_instructions_only" do
      """
      I loaded only #{context.agent_instruction_file} for this new directory.

      I have not read the workspace files yet. Tell me the file, area, or task you want inspected next.
      """
      |> String.trim()
    else
      local_workspace_overview_response_loaded(context, files_result, memory_result)
    end
  end

  defp local_workspace_overview_response_loaded(context, files_result, memory_result) do
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
      |> nonempty_rows("- no agent instruction file was readable")

    skills = skill_summary(context)

    memories =
      memory_result
      |> Map.get("matches", [])
      |> length()

    """
    I scanned the workspace map and read #{length(overview_files)} agent instruction files.

    Project shape: #{project_kind}. Holt can see #{length(files)} files, #{memories} memory matches, and #{skills}.

    Main areas:
    #{Enum.join(directories, "\n")}

    Agent instructions read:
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

      chat_turn_contract?(opts) ->
        {:ok, local_chat_response(objective, provider, context, files_result, memory_result)}

      goal_contract?(opts) ->
        {:ok, local_goal_response(objective, provider, context, files_result, memory_result)}

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
    actions = ProviderAdapter.openai_action_definitions(actions)

    do_model_action_loop(provider, run_dir, opts, messages, actions, 1)
  end

  defp do_model_action_loop(provider, run_dir, opts, messages, actions, turn) do
    progress(run_dir, opts, :thinking, "Thinking through the request", %{"turn" => turn})

    Runs.append_event(run_dir, "model.requested", %{
      "provider" => provider_id(provider),
      "model" => provider["model"],
      "turn" => turn,
      "action_count" => length(actions)
    })

    record_llm_request(opts, provider, messages, actions, turn)

    model_opts =
      opts
      |> Keyword.put(:actions, actions)
      |> Keyword.put(:tool_choice, "auto")

    case Models.chat(provider, messages, model_opts) do
      {:ok, response} ->
        tool_calls = ProviderAdapter.normalize_calls(response["tool_calls"])
        content = Map.get(response, "content", "")
        content = OutputSanitizer.format_local_model_result(content)
        thinking = model_thinking_text(response)

        emit_model_thinking_event(run_dir, opts, response, thinking, turn)

        Runs.append_event(run_dir, "model.completed", %{
          "provider" => response["provider"],
          "model" => response["model"],
          "turn" => turn,
          "content_preview" => String.slice(content, 0, 180),
          "tool_call_count" => length(tool_calls),
          "finish_reason" => response["finish_reason"]
        })
        |> ignore_empty_event_fields()

        record_llm_response(opts, response, content, tool_calls, thinking, turn)

        if tool_calls == [] do
          {:ok, maybe_ensure_plan_heading(content, opts)}
        else
          Runs.append_event(run_dir, "model.tool_calls", %{
            "turn" => turn,
            "calls" => Enum.map(tool_calls, &ProviderAdapter.call_event/1)
          })

          with {:ok, action_messages} <-
                 execute_provider_action_calls(run_dir, tool_calls, opts, turn) do
            next_messages =
              messages ++
                [ProviderAdapter.assistant_message(content, tool_calls, response)] ++
                action_messages

            do_model_action_loop(
              provider,
              run_dir,
              opts,
              next_messages,
              actions,
              turn + 1
            )
          end
        end

      {:error, reason} ->
        progress(run_dir, opts, :failed, "Holt could not complete the model request")

        Runs.append_event(run_dir, "model.failed", %{
          "provider" => provider_id(provider),
          "model" => provider["model"],
          "turn" => turn,
          "reason" => inspect(reason)
        })

        record_error(opts, "model_failed", reason)
        {:error, reason}
    end
  end

  defp emit_model_thinking_event(_run_dir, _opts, _response, nil, _turn), do: :ok

  defp emit_model_thinking_event(run_dir, opts, response, thinking, turn) do
    event =
      Runs.append_event(run_dir, "model.thinking", %{
        "provider" => response["provider"],
        "model" => response["model"],
        "turn" => turn,
        "block_type" => "thinking",
        "content" => thinking,
        "content_length" => String.length(thinking)
      })

    emit_runtime_event(opts, event)
    :ok
  end

  defp model_thinking_text(%{"reasoning" => reasoning}) when is_binary(reasoning) do
    reasoning
    |> String.trim()
    |> non_empty_thinking()
  end

  defp model_thinking_text(%{"reasoning_details" => details}) when is_list(details) do
    details
    |> Enum.flat_map(&thinking_detail_text/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
    |> non_empty_thinking()
  end

  defp model_thinking_text(_response), do: nil

  defp thinking_detail_text(%{"type" => "reasoning.text", "text" => text}) when is_binary(text),
    do: [text]

  defp thinking_detail_text(%{"type" => "reasoning.summary", "summary" => summary})
       when is_binary(summary),
       do: [summary]

  defp thinking_detail_text(_detail), do: []

  defp non_empty_thinking(""), do: nil
  defp non_empty_thinking(thinking), do: thinking

  defp model_actions(opts) do
    session = action_session(opts)
    task_scoped? = task_ref(session) not in [nil, ""]

    opts =
      opts
      |> Keyword.put(:action_session, session)

    %{"action_session" => session}
    |> Registry.catalog(opts)
    |> Enum.filter(fn action ->
      accepted_action_route?(action) and action_available_for_task_scope?(action, task_scoped?)
    end)
  end

  defp accepted_action_route?(action),
    do: get_in(action, ["availability", "route_status"]) == "accepted"

  defp action_available_for_task_scope?(%{"requires_task_ref" => true}, true), do: true
  defp action_available_for_task_scope?(%{"requires_task_ref" => true}, false), do: false
  defp action_available_for_task_scope?(_action, _task_scoped?), do: true

  defp execute_provider_action_calls(run_dir, tool_calls, opts, turn) do
    tool_calls
    |> Enum.reduce_while({:ok, []}, fn call, {:ok, messages} ->
      case execute_action_action_call(run_dir, call, opts, turn) do
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

  defp execute_action_action_call(run_dir, call, opts, turn) do
    action_name = ProviderAdapter.action_name(call)
    action_call_id = ProviderAdapter.call_id(call)
    args = ProviderAdapter.arguments(call)
    args = maybe_put_default_task_ref(args, opts)

    emit_action_event(
      run_dir,
      opts,
      "action.started",
      ActionVisibility.started(action_name, args, action_call_id, opts)
    )

    if directory_discovery_action_blocked?(action_name, args, opts) do
      execution = %{
        "status" => "error",
        "action" => action_name,
        "reason" => "directory_discovery_allows_only_agent_instructions"
      }

      emit_action_event(
        run_dir,
        opts,
        "action.failed",
        ActionVisibility.failed(action_name, args, execution["reason"], action_call_id, opts)
        |> Map.merge(%{"result_status" => "error", "reason" => execution["reason"]})
      )

      record_action_result(opts, action_name, execution, action_call_id, turn)
      {:ok, ProviderAdapter.result_message(call, execution)}
    else
      execute_allowed_action_action_call(run_dir, call, action_name, args, opts, turn)
    end
  end

  defp execute_allowed_action_action_call(run_dir, call, action_name, args, opts, turn) do
    action_call_id = ProviderAdapter.call_id(call)

    approval_expected? = ActionVisibility.approval_expected?(action_name, args, opts)

    if approval_expected? do
      emit_action_event(
        run_dir,
        opts,
        "action.approval_requested",
        ActionVisibility.approval_requested(action_name, args, action_call_id, opts)
      )
    end

    Runs.append_event(run_dir, "action.requested", %{
      "action" => action_name,
      "action_call_id" => action_call_id,
      "args" => redact_args(args)
    })

    record_action_invocation(opts, action_name, args, action_call_id, turn)

    if await_user_action?(action_name) and is_function(opts[:await_user_callback], 2) do
      execute_await_user_action_call(run_dir, call, action_name, args, opts, turn)
    else
      execute_regular_action_action_call(
        run_dir,
        call,
        action_name,
        args,
        opts,
        turn,
        approval_expected?
      )
    end
  end

  defp directory_discovery_action_blocked?("search", _args, opts),
    do: directory_discovery_mode?(opts)

  defp directory_discovery_action_blocked?("read", args, opts) do
    directory_discovery_mode?(opts) and args["path"] != Workspace.agent_instruction_file()
  end

  defp directory_discovery_action_blocked?(_action_name, _args, _opts), do: false

  defp execute_regular_action_action_call(
         run_dir,
         call,
         action_name,
         args,
         opts,
         turn,
         approval_expected?
       ) do
    case Executor.run(action_name, args, opts) do
      {:ok, execution} ->
        if approval_expected? do
          emit_action_event(
            run_dir,
            opts,
            "action.approval_resolved",
            ActionVisibility.approval_resolved(action_name, args, call["id"], "approved", opts)
          )
        end

        emit_action_event(
          run_dir,
          opts,
          "action.completed",
          ActionVisibility.completed(action_name, args, execution, call["id"], opts)
          |> Map.merge(%{
            "result_status" => "ok",
            "result" => summarize_action_execution(execution)
          })
        )

        record_action_result(opts, action_name, execution, call["id"], turn)
        {:ok, ProviderAdapter.result_message(call, execution)}

      {:error, %{} = execution} ->
        if approval_expected? and execution["reason"] == "approval_denied" do
          emit_action_event(
            run_dir,
            opts,
            "action.approval_resolved",
            ActionVisibility.approval_resolved(action_name, args, call["id"], "denied", opts)
          )
        end

        emit_action_event(
          run_dir,
          opts,
          "action.failed",
          ActionVisibility.failed(
            action_name,
            args,
            Map.get(execution, "reason"),
            call["id"],
            opts
          )
          |> Map.merge(%{
            "result_status" => Map.get(execution, "status", "error"),
            "reason" => Map.get(execution, "reason"),
            "result" => summarize_action_execution(execution)
          })
        )

        record_action_result(opts, action_name, execution, call["id"], turn)

        if execution["reason"] == "approval_denied" do
          {:error, :approval_denied}
        else
          {:ok, ProviderAdapter.result_message(call, execution)}
        end

      {:error, :approval_denied} ->
        if approval_expected? do
          emit_action_event(
            run_dir,
            opts,
            "action.approval_resolved",
            ActionVisibility.approval_resolved(action_name, args, call["id"], "denied", opts)
          )
        end

        progress(run_dir, opts, :blocked, "Waiting for approval")

        emit_action_event(
          run_dir,
          opts,
          "action.failed",
          ActionVisibility.failed(action_name, args, :approval_denied, call["id"], opts)
          |> Map.merge(%{"result_status" => "error", "reason" => "approval_denied"})
        )

        record_action_result(
          opts,
          action_name,
          %{"status" => "error", "action" => action_name, "reason" => "approval_denied"},
          call["id"],
          turn
        )

        {:error, :approval_denied}

      {:error, reason} ->
        execution = %{
          "status" => "error",
          "action" => action_name,
          "reason" => inspect(reason)
        }

        emit_action_event(
          run_dir,
          opts,
          "action.failed",
          ActionVisibility.failed(action_name, args, reason, call["id"], opts)
          |> Map.merge(%{"result_status" => "error", "reason" => inspect(reason)})
        )

        record_action_result(opts, action_name, execution, call["id"], turn)
        {:ok, ProviderAdapter.result_message(call, execution)}
    end
  end

  defp execute_await_user_action_call(run_dir, call, action_name, args, opts, turn) do
    action_call_id = call["id"]

    with {:ok, question} <- user_question(args),
         {:ok, description} <- user_question_description(args),
         {:ok, options} <- user_question_options(args["options"]) do
      do_execute_await_user_action_call(
        run_dir,
        call,
        action_name,
        args,
        opts,
        turn,
        action_call_id,
        question,
        description,
        options
      )
    else
      {:error, reason} ->
        execution = %{
          "status" => "error",
          "action" => action_name,
          "reason" => inspect(reason)
        }

        emit_action_event(
          run_dir,
          opts,
          "action.failed",
          ActionVisibility.failed(action_name, args, reason, action_call_id, opts)
          |> Map.merge(%{"result_status" => "error", "reason" => inspect(reason)})
        )

        record_action_result(opts, action_name, execution, action_call_id, turn)
        {:ok, ProviderAdapter.result_message(call, execution)}
    end
  end

  defp do_execute_await_user_action_call(
         run_dir,
         call,
         action_name,
         args,
         opts,
         turn,
         action_call_id,
         question,
         description,
         options
       ) do
    progress(run_dir, opts, :waiting_for_input, "Waiting for your input", %{
      "action" => action_name
    })

    transition_run(run_dir, "awaiting_user")
    record_awaiting_user(opts, question, action_call_id, turn)

    metadata =
      %{
        "action_call_id" => action_call_id,
        "turn" => turn,
        "description" => description,
        "options" => options,
        "await_timeout_ms" => opts[:await_timeout_ms]
      }
      |> reject_empty()

    case opts[:await_user_callback].(question, metadata) do
      {:ok, answer} ->
        transition_run(run_dir, "running")
        record_user_response(opts, answer, action_call_id, turn)

        execution =
          %{
            "status" => "completed",
            "action" => action_name,
            "question" => question,
            "options" => options,
            "result" => %{"answer" => answer_text(answer)},
            "continuation_policy" => ask_continuation_policy()
          }
          |> reject_empty()

        emit_action_event(
          run_dir,
          opts,
          "action.completed",
          ActionVisibility.completed(action_name, args, execution, action_call_id, opts)
          |> Map.merge(%{
            "result_status" => "ok",
            "result" => summarize_action_execution(execution)
          })
        )

        record_action_result(opts, action_name, execution, action_call_id, turn)
        {:ok, ProviderAdapter.result_message(call, execution)}

      {:error, reason} ->
        transition_run(run_dir, "running")
        record_error(opts, "await_user_failed", reason)

        emit_action_event(
          run_dir,
          opts,
          "action.failed",
          ActionVisibility.failed(action_name, args, reason, action_call_id, opts)
          |> Map.merge(%{"result_status" => "error", "reason" => inspect(reason)})
        )

        {:error, reason}

      answer ->
        transition_run(run_dir, "running")
        record_user_response(opts, answer, action_call_id, turn)

        execution = %{
          "status" => "completed",
          "action" => action_name,
          "result" => %{"answer" => answer_text(answer)}
        }

        emit_action_event(
          run_dir,
          opts,
          "action.completed",
          ActionVisibility.completed(action_name, args, execution, action_call_id, opts)
          |> Map.merge(%{
            "result_status" => "ok",
            "result" => summarize_action_execution(execution)
          })
        )

        record_action_result(opts, action_name, execution, action_call_id, turn)
        {:ok, ProviderAdapter.result_message(call, execution)}
    end
  end

  defp await_user_action?("ask"), do: true
  defp await_user_action?(_action_name), do: false

  defp answer_text(nil), do: ""
  defp answer_text(answer), do: to_string(answer)

  defp user_question(args) do
    case canonical_text(args["question"]) do
      nil -> {:error, {:missing_required, "question"}}
      question -> {:ok, question}
    end
  end

  defp user_question_description(args) do
    case Map.fetch(args, "description") do
      {:ok, value} when value not in [nil, ""] ->
        case canonical_text(value) do
          nil -> {:error, {:invalid_field, "description"}}
          description -> {:ok, description}
        end

      _missing_or_empty ->
        {:ok, nil}
    end
  end

  defp user_question_options(nil), do: {:ok, []}

  defp user_question_options(options) when is_list(options) do
    options
    |> Enum.reduce_while({:ok, []}, fn option, {:ok, options} ->
      case user_question_option(option) do
        {:ok, option} -> {:cont, {:ok, options ++ [option]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp user_question_options(_options), do: {:error, {:invalid_field, "options"}}

  defp user_question_option(%{} = option) do
    with {:ok, label} <- required_option_text(option, "label"),
         {:ok, value} <- required_option_text(option, "value"),
         {:ok, description} <- optional_option_text(option, "description") do
      {:ok,
       %{
         "label" => label,
         "value" => value,
         "description" => description
       }
       |> reject_empty()}
    end
  end

  defp user_question_option(_option), do: {:error, {:invalid_field, "options[]"}}

  defp required_option_text(option, key) do
    case canonical_text(option[key]) do
      nil -> {:error, {:missing_required, "options[].#{key}"}}
      text -> {:ok, text}
    end
  end

  defp optional_option_text(option, key) do
    case Map.fetch(option, key) do
      {:ok, value} when value not in [nil, ""] ->
        case canonical_text(value) do
          nil -> {:error, {:invalid_field, "options[].#{key}"}}
          text -> {:ok, text}
        end

      _missing_or_empty ->
        {:ok, nil}
    end
  end

  defp canonical_text(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp canonical_text(_value), do: nil

  defp transition_run(run_dir, status) do
    case Runs.transition(run_dir, status) do
      {:ok, _run} -> :ok
      {:error, _reason} -> :ok
    end
  end

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

  defp action_session(opts) do
    attrs =
      case opts[:action_session] do
        session when is_map(session) -> session
        _missing -> %{}
      end

    attrs =
      attrs
      |> Map.put("task", runtime_session_task(opts))
      |> maybe_put_missing("workspace", Paths.workspace_root(opts))

    ActionSession.build(attrs)
  end

  defp runtime_session_task(opts) do
    %{
      "id" => opts[:task_id],
      "ref" => opts[:task_ref]
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  defp task_ref_from_opts(opts) do
    opts[:task_ref]
  end

  defp task_ref(map) when is_map(map) do
    Map.get(map, "ref")
  end

  defp task_ref(_value), do: nil

  defp maybe_put_missing(map, _key, value) when value in [nil, ""], do: map

  defp maybe_put_missing(map, key, value) do
    case Map.get(map, key) do
      current when current in [nil, ""] -> Map.put(map, key, value)
      _current -> map
    end
  end

  defp summarize_action_execution(execution) when is_map(execution) do
    execution
    |> Map.take(["status", "action", "reason", "result", "route"])
    |> summarize_result()
  end

  defp ask_continuation_policy do
    %{
      "assistant_content_may_request_user_input" => false,
      "follow_up_user_input_action" => "ask",
      "requires_action_for_more_user_input" => true
    }
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

    chat_messages = chat_messages(opts)
    overview_files = overview_files_section(files_result)

    discovery_policy =
      if directory_discovery_mode?(opts) do
        "This is new-directory discovery. Read no workspace file except AGENTS.md; do not call read or search for any other path unless the user explicitly names that file in a later request."
      else
        "Automatic repo overview may use the file list and AGENTS.md only. Do not auto-read README, source, test, or config files for directory discovery."
      end

    system =
      case runtime_contract(opts) do
        :chat_turn ->
          """
          You are Holt, a local project agent running inside a terminal.
          Work through a plan internally, use available actions when fresh workspace, task, memory, or network state is needed, and return the final user-facing output.
          Assistant content is terminal output. When you need the user to choose between options or answer a clarification question, call the ask action with canonical question/options fields instead of writing the question, numbered choices, or clarification request in assistant prose.
          For generic example requests, choose a reasonable default and produce the example instead of asking the user to pick a subtype.
          Do not call file, page, or device persistence actions unless the user explicitly asks to save, create, modify, or persist something outside the chat. If the request can be answered in chat, return it inline as Markdown.
          Do not return NEXT_STEPS, implementation-plan boilerplate, run summaries, or artifact reports unless the user explicitly asks for a plan.
          If the user greets you, respond naturally and ask how you can help.
          If the user asks to read, inspect, understand, or summarize the repo/project/codebase/workspace during discovery, explain that only AGENTS.md was loaded and ask for the next specific file, area, or task.
          #{discovery_policy}
          Only claim action results that are present in the supplied context or action messages.
          """

        :goal ->
          """
          You are Holt, a local project agent running inside a terminal.
          Runtime contract: goal.
          Convert the user's request into a concise working goal with clear success criteria and the next concrete action.
          Assistant content is terminal output. When you need the user to choose between options or answer a clarification question, call the ask action with canonical question/options fields instead of writing the question, numbered choices, or clarification request in assistant prose.
          Do not write NEXT_STEPS.md or any planning artifact. Do not call file, page, or device persistence actions unless the user explicitly asks to save or modify a file.
          #{discovery_policy}
          Only claim action results that are present in the supplied context or action messages.
          """

        :plan_artifact ->
          """
          You are Holt, a local project agent.
          Use available actions when fresh workspace, task, memory, or network state is needed.
          Assistant content is terminal output. When you need the user to choose between options or answer a clarification question, call the ask action with canonical question/options fields instead of writing the question, numbered choices, or clarification request in assistant prose.
          For generic example requests, choose a reasonable default and produce the example instead of asking the user to pick a subtype.
          Do not call file, page, or device persistence actions unless the user explicitly asks to save, create, modify, or persist something outside the chat. If the request can be answered in chat, return it inline as Markdown.
          Return concise Markdown that starts with "# NEXT STEPS".
          Include: objective, workspace snapshot, skills used, relevant memory, and recommended next tasks.
          #{discovery_policy}
          Only claim action results that are present in the supplied context or action messages.
          """
      end

    [
      %{
        "role" => "system",
        "content" => system
      }
    ] ++
      chat_messages ++
      [
        %{
          "role" => "user",
          "content" => """
          Current request:
          #{objective}

          Workspace context:
          #{Context.prompt_section(context)}

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
    case runtime_contract(opts) do
      :plan_artifact -> ensure_plan_heading(content)
      :chat_turn -> String.trim(to_string(content))
      :goal -> String.trim(to_string(content))
    end
  end

  defp chat_messages(opts) do
    opts
    |> Keyword.get(:chat_messages, [])
    |> ChatMessages.normalize()
    |> case do
      {:ok, messages} -> Enum.take(messages, -8)
      {:error, _reason} -> []
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

  defp chat_intent(_objective, opts) do
    case workspace_intent(opts) do
      "explore_project" -> :workspace_overview
      "none" -> :general
    end
  end

  defp context_event(context) do
    %{
      "workspace" => context.workspace,
      "agent_instruction_file" => context.agent_instruction_file,
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

  defp agent_event_runtime_opts(opts, run, provider, root, pre_task_plan) do
    opts
    |> Keyword.put(:workspace, root)
    |> Keyword.put(:run_id, run["id"])
    |> Keyword.put(:run_dir, run["run_dir"])
    |> maybe_put_agent_event_session_id(run, pre_task_plan)
    |> Keyword.put(:trace_id, "trace:#{run["id"]}")
    |> Keyword.put_new(:agent_id, run_agent_id(run))
    |> Keyword.put(:provider, provider_id(provider))
  end

  defp maybe_put_agent_event_session_id(opts, run, %{"workspace_persistence" => "workspace"}) do
    Keyword.put(opts, :agent_event_session_id, workspace_session_id(opts, run))
  end

  defp maybe_put_agent_event_session_id(opts, _run, %{"workspace_persistence" => "ephemeral"}) do
    Keyword.delete(opts, :agent_event_session_id)
  end

  defp workspace_session_id(opts, run) do
    case Keyword.get(opts, :agent_event_session_id) do
      session_id when is_binary(session_id) and session_id != "" -> session_id
      _missing -> run["id"]
    end
  end

  defp run_agent_id(%{"agent_id" => agent_id}) when is_binary(agent_id) and agent_id != "",
    do: agent_id

  defp run_agent_id(_run), do: "default"

  defp completed_run_status(%{"status" => status}) when is_binary(status) and status != "",
    do: status

  defp completed_run_status(_run), do: "completed"

  defp failed_run_status(%{"status" => status}) when is_binary(status) and status != "",
    do: status

  defp failed_run_status(_run), do: "failed"

  defp maybe_record_session_started(nil, _opts), do: :ok

  defp maybe_record_session_started(session_id, opts) when is_binary(session_id) do
    EventRecorder.session_started(session_id, opts)
  end

  defp record_session_result(nil, _result, _opts), do: :ok

  defp record_session_result(session_id, result, opts) do
    case result do
      {:ok, %{run: %{} = run}} ->
        EventRecorder.session_ended(
          session_id,
          completed_run_status(run),
          agent_event_opts(opts)
        )

      {:error, %{run: %{} = run, reason: reason}} ->
        EventRecorder.error(session_id, "runtime_failed", reason, agent_event_opts(opts))
        EventRecorder.session_ended(session_id, failed_run_status(run), agent_event_opts(opts))

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

  defp record_llm_request(opts, provider, messages, actions, turn) do
    with session_id when is_binary(session_id) <- agent_event_session_id(opts) do
      EventRecorder.llm_request(
        session_id,
        agent_event_opts(opts,
          provider: provider_id(provider),
          model: provider["model"],
          message_count: length(messages),
          action_count: length(actions),
          turn: turn
        )
      )
    end
  end

  defp record_llm_response(opts, response, content, tool_calls, thinking, turn) do
    with session_id when is_binary(session_id) <- agent_event_session_id(opts) do
      EventRecorder.llm_response(
        session_id,
        agent_event_opts(opts,
          provider: response["provider"],
          model: response["model"],
          content_length: text_length(content),
          thinking_length: thinking_length(thinking),
          tool_calls_count: length(tool_calls),
          finish_reason: response["finish_reason"],
          turn: turn
        )
      )
    end
  end

  defp thinking_length(thinking) when is_binary(thinking), do: String.length(thinking)
  defp thinking_length(_thinking), do: nil

  defp text_length(value) when is_binary(value), do: String.length(value)
  defp text_length(nil), do: 0
  defp text_length(value), do: value |> to_string() |> String.length()

  defp record_action_invocation(opts, action_name, args, action_call_id, turn) do
    with session_id when is_binary(session_id) <- agent_event_session_id(opts) do
      EventRecorder.action_invocation(
        session_id,
        action_name,
        args,
        agent_event_opts(opts, action_call_id: action_call_id, turn: turn)
      )
    end
  end

  defp record_action_result(opts, action_name, result, action_call_id, turn) do
    with session_id when is_binary(session_id) <- agent_event_session_id(opts) do
      EventRecorder.action_result(
        session_id,
        action_name,
        result,
        agent_event_opts(opts, action_call_id: action_call_id, turn: turn)
      )
    end
  end

  defp record_awaiting_user(opts, question, action_call_id, turn) do
    with session_id when is_binary(session_id) <- agent_event_session_id(opts) do
      EventRecorder.awaiting_user(
        session_id,
        question,
        agent_event_opts(opts, action_call_id: action_call_id, turn: turn)
      )
    end
  end

  defp record_user_response(opts, answer, action_call_id, turn) do
    with session_id when is_binary(session_id) <- agent_event_session_id(opts) do
      EventRecorder.user_response(
        session_id,
        answer,
        agent_event_opts(opts, action_call_id: action_call_id, turn: turn)
      )
    end
  end

  defp record_error(opts, error_type, reason) do
    with session_id when is_binary(session_id) <- agent_event_session_id(opts) do
      EventRecorder.error(session_id, error_type, reason, agent_event_opts(opts))
    end
  end

  defp emit_stream_chunk(opts, content, extra) do
    content = stream_content(content)

    if content != "" do
      with session_id when is_binary(session_id) <- agent_event_session_id(opts) do
        EventRecorder.stream_chunk(session_id, content, agent_event_opts(opts, extra))
      end

      emit_runtime_event(opts, %{"type" => "stream_chunk", "content" => content})
    end

    :ok
  end

  defp stream_content(nil), do: ""
  defp stream_content(content), do: to_string(content)

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
      agent_id: opts[:agent_id],
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

  defp fork_objective(opts, run) do
    case Keyword.get(opts, :objective) do
      objective when is_binary(objective) ->
        objective = String.trim(objective)
        if objective == "", do: run["objective"], else: objective

      _ ->
        run["objective"]
    end
  end

  defp maybe_put_forked_from(opts) do
    case opts[:forked_from] do
      nil -> opts
      id -> Keyword.put(opts, :forked_from, id)
    end
  end
end
