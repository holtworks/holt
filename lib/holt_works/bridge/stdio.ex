defmodule HoltWorks.Bridge.Stdio do
  @moduledoc """
  Minimal JSON-lines stdio bridge for local clients.
  """

  alias HoltWorks.{AgentRuntime, Memory, Runtime, Skills, Tasks, Tools}
  alias HoltWorks.Runtime.{AgentEvents, Session}

  def serve(opts \\ []) do
    IO.stream(:stdio, :line)
    |> Enum.each(fn line ->
      response =
        line
        |> String.trim()
        |> handle_line(opts)

      IO.puts(Jason.encode!(response))
    end)
  end

  def handle_line("", _opts), do: %{"ok" => false, "error" => "empty_request"}

  def handle_line(line, opts) do
    case Jason.decode(line) do
      {:ok, request} -> handle_request(request, opts)
      {:error, reason} -> %{"ok" => false, "error" => Exception.message(reason)}
    end
  end

  def handle_request(%{"method" => "status"}, opts) do
    %{"ok" => true, "result" => Runtime.status(opts)}
  end

  def handle_request(%{"method" => method, "params" => params}, opts)
      when method in ["agent_sessions/start", "agent_session/start"] do
    with {:ok, objective} <- required_any_param(params, ["objective", "prompt", "message"]) do
      session_opts = session_start_opts(params, opts)

      case Session.start(objective, session_opts) do
        {:ok, session} -> %{"ok" => true, "result" => session}
        {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
      end
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => method, "params" => params}, opts)
      when method in ["agent_sessions/status", "agent_session/status"] do
    with {:ok, session_id} <- required_any_param(params, ["session_id", "id", "run_id"]) do
      case Session.status(session_id, session_query_opts(params, opts)) do
        {:ok, session} -> %{"ok" => true, "result" => session}
        {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
      end
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => method, "params" => params}, opts)
      when method in ["agent_sessions/respond", "agent_session/respond", "agent_sessions/resume"] do
    with {:ok, session_id} <- required_any_param(params, ["session_id", "id", "run_id"]),
         {:ok, answer} <- required_any_param(params, ["answer", "response", "message"]) do
      case Session.respond(session_id, answer, session_query_opts(params, opts)) do
        {:ok, session} -> %{"ok" => true, "result" => session}
        {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
      end
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => method, "params" => params}, opts)
      when method in ["agent_sessions/list", "agent_session/list"] do
    %{"ok" => true, "result" => Session.list(session_query_opts(params, opts))}
  end

  def handle_request(%{"method" => method}, opts)
      when method in ["agent_sessions/list", "agent_session/list"] do
    %{"ok" => true, "result" => Session.list(opts)}
  end

  def handle_request(%{"method" => "tools/list"}, _opts) do
    %{"ok" => true, "result" => Tools.definitions()}
  end

  def handle_request(%{"method" => method, "params" => params}, opts)
      when method in ["agent_events/list", "agent_events"] do
    with {:ok, session_id} <- required_any_param(params, ["session_id", "run_id"]) do
      case AgentEvents.list_by_session(session_id, agent_event_query_opts(params, opts)) do
        {:ok, events} -> %{"ok" => true, "result" => events}
        {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
      end
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "agent_events/summary", "params" => params}, opts) do
    with {:ok, session_id} <- required_any_param(params, ["session_id", "run_id"]) do
      case AgentEvents.get_session_summary(session_id, agent_event_query_opts(params, opts)) do
        {:ok, summary} -> %{"ok" => true, "result" => summary}
        {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
      end
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "agent_events/tree", "params" => params}, opts) do
    with {:ok, session_id} <- required_any_param(params, ["session_id", "run_id"]) do
      case AgentEvents.get_session_tree(session_id, agent_event_query_opts(params, opts)) do
        {:ok, tree} -> %{"ok" => true, "result" => tree}
        {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
      end
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => method, "params" => params}, opts)
      when method in ["actions/list", "list_actions", "search_tools"] do
    %{"ok" => true, "result" => Tasks.search_actions(params, opts)}
  end

  def handle_request(%{"method" => method}, opts)
      when method in ["actions/list", "list_actions", "search_tools"] do
    %{"ok" => true, "result" => Tasks.action_definitions(opts)}
  end

  def handle_request(%{"method" => method, "params" => params}, opts)
      when method in ["actions/catalog", "agent_tools/catalog", "tool_catalog"] do
    %{"ok" => true, "result" => Tasks.action_catalog(params, opts)}
  end

  def handle_request(%{"method" => method}, opts)
      when method in ["actions/catalog", "agent_tools/catalog", "tool_catalog"] do
    %{"ok" => true, "result" => Tasks.action_catalog(%{}, opts)}
  end

  def handle_request(%{"method" => method, "params" => params}, opts)
      when method in ["agent_tools/openai", "actions/openai_tools"] do
    %{"ok" => true, "result" => Tasks.agent_tool_definitions(params, opts)}
  end

  def handle_request(%{"method" => method}, opts)
      when method in ["agent_tools/openai", "actions/openai_tools"] do
    %{"ok" => true, "result" => Tasks.agent_tool_definitions(%{}, opts)}
  end

  def handle_request(%{"method" => method, "params" => params}, opts)
      when method in ["actions/providers", "agent_tools/providers"] do
    %{"ok" => true, "result" => Tasks.action_provider_metadata(params, opts)}
  end

  def handle_request(%{"method" => method}, opts)
      when method in ["actions/providers", "agent_tools/providers"] do
    %{"ok" => true, "result" => Tasks.action_provider_metadata(%{}, opts)}
  end

  def handle_request(%{"method" => method, "params" => params}, opts)
      when method in ["actions/provider_prompt_sections", "agent_tools/provider_prompt_sections"] do
    %{"ok" => true, "result" => Tasks.action_provider_prompt_sections(params, opts)}
  end

  def handle_request(%{"method" => method, "params" => params}, opts)
      when method in ["agent_tools/dispatch", "dispatch_agent_tool"] do
    with {:ok, name} <- required_any_param(params, ["name", "tool_name", "tool", "action"]) do
      args =
        params
        |> Map.get(
          "arguments",
          Map.drop(params, ["name", "tool_name", "tool", "action", "context"])
        )

      context = Map.get(params, "context", params)
      handle_action_result(Tasks.dispatch_agent_tool(name, args, context, opts))
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => method, "params" => params}, opts)
      when method in ["actions/get", "get_action", "get_tool_schema"] do
    with {:ok, name} <- required_any_param(params, ["name", "tool_name", "tool"]) do
      case Tasks.get_action(name, opts) do
        nil -> %{"ok" => false, "error" => "unknown_action"}
        action -> %{"ok" => true, "result" => action}
      end
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => method, "params" => params}, opts)
      when method in ["actions/execute", "execute_action"] do
    with {:ok, name} <- required_any_param(params, ["name", "tool_name", "tool", "action"]) do
      args =
        params
        |> Map.get("arguments", Map.drop(params, ["name", "tool_name", "tool", "action"]))

      handle_action_result(Tasks.execute_action(name, args, opts))
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => method, "params" => params}, opts)
      when method in [
             "ask_user_question",
             "core/ask_user_question",
             "delegate_to_agent",
             "core/delegate_to_agent",
             "set_page_title",
             "core/set_page_title",
             "create_page",
             "pages/create",
             "write_to_document",
             "documents/write"
           ] do
    handle_action_result(Tasks.execute_action(local_ui_tool_name(method), params, opts))
  end

  def handle_request(%{"method" => "agent_runtime/doctor", "params" => params}, _opts) do
    %{"ok" => true, "result" => AgentRuntime.doctor(params)}
  end

  def handle_request(%{"method" => "agent_runtime/doctor"}, _opts) do
    %{"ok" => true, "result" => AgentRuntime.doctor(%{})}
  end

  def handle_request(%{"method" => "agent_runtime/tool_availability", "params" => params}, _opts) do
    %{"ok" => true, "result" => AgentRuntime.tool_availability(params)}
  end

  def handle_request(%{"method" => "agent_runtime/tool_availability"}, _opts) do
    %{"ok" => true, "result" => AgentRuntime.tool_availability(%{})}
  end

  def handle_request(%{"method" => "agent_runtime/provider_profile", "params" => params}, _opts) do
    model_id = Map.get(params, "model_id") || Map.get(params, "model") || "local-planner"
    %{"ok" => true, "result" => AgentRuntime.provider_profile(model_id, params)}
  end

  def handle_request(%{"method" => "agent_runtime/safety_policy", "params" => params}, _opts) do
    %{"ok" => true, "result" => AgentRuntime.safety_policy(params)}
  end

  def handle_request(%{"method" => "agent_runtime/safety_policy"}, _opts) do
    %{"ok" => true, "result" => AgentRuntime.safety_policy(%{})}
  end

  def handle_request(%{"method" => "agent_runtime/context_budget", "params" => params}, _opts) do
    %{"ok" => true, "result" => AgentRuntime.context_budget(params)}
  end

  def handle_request(%{"method" => "agent_runtime/recovery_contract", "params" => params}, _opts) do
    %{"ok" => true, "result" => AgentRuntime.recovery_contract(params)}
  end

  def handle_request(%{"method" => "agent_runtime/recovery_contract"}, _opts) do
    %{"ok" => true, "result" => AgentRuntime.recovery_contract(%{})}
  end

  def handle_request(%{"method" => "agent_runtime/run_debugger", "params" => params}, _opts) do
    %{"ok" => true, "result" => AgentRuntime.run_debugger(params)}
  end

  def handle_request(%{"method" => "agent_runtime/run_debugger"}, _opts) do
    %{"ok" => true, "result" => AgentRuntime.run_debugger(%{})}
  end

  def handle_request(
        %{"method" => "agent_runtime/meta_learning_snapshot", "params" => params},
        _opts
      ) do
    %{"ok" => true, "result" => AgentRuntime.meta_learning_snapshot(params)}
  end

  def handle_request(%{"method" => "agent_runtime/meta_learning_snapshot"}, _opts) do
    %{"ok" => true, "result" => AgentRuntime.meta_learning_snapshot(%{})}
  end

  def handle_request(
        %{"method" => "agent_runtime/format_local_model_result", "params" => params},
        _opts
      ) do
    result = Map.get(params, "result") || Map.get(params, "content") || params
    %{"ok" => true, "result" => %{"content" => AgentRuntime.format_local_model_result(result)}}
  end

  def handle_request(
        %{"method" => "agent_runtime/agent_loop_contract", "params" => params},
        _opts
      ) do
    %{"ok" => true, "result" => AgentRuntime.agent_loop_contract(params)}
  end

  def handle_request(
        %{"method" => "agent_runtime/agent_run_lifecycle_complete", "params" => params},
        _opts
      ) do
    %{
      "ok" => true,
      "result" => %{"lifecycle_state" => AgentRuntime.agent_run_lifecycle_complete(params)}
    }
  end

  def handle_request(
        %{"method" => "agent_runtime/record_process_started", "params" => params},
        opts
      ) do
    handle_process_started(params, opts)
  end

  def handle_request(
        %{"method" => "agent_runtime/notify_process_terminal", "params" => params},
        opts
      ) do
    handle_process_terminal(params, opts)
  end

  def handle_request(%{"method" => "skills/list", "params" => params}, opts) do
    %{"ok" => true, "result" => Skills.search(params, opts)}
  end

  def handle_request(%{"method" => "skills/list"}, opts) do
    skills =
      Enum.map(Skills.list(opts), &Map.take(&1, [:name, :description, :risk, :triggers, :path]))

    %{"ok" => true, "result" => skills}
  end

  def handle_request(%{"method" => "skills/load", "params" => params}, opts) do
    case Skills.load(params, opts) do
      {:ok, skill} -> %{"ok" => true, "result" => skill}
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "skills/save", "params" => params}, opts) do
    handle_action_result(Tasks.execute_action("save_skill", params, opts))
  end

  def handle_request(%{"method" => "skills/update", "params" => params}, opts) do
    handle_action_result(Tasks.execute_action("update_skill", params, opts))
  end

  def handle_request(%{"method" => "skills/run_script", "params" => params}, opts) do
    handle_action_result(Tasks.execute_action("run_skill_script", params, opts))
  end

  def handle_request(%{"method" => method, "params" => params}, opts)
      when method in [
             "repair_runs/start",
             "start_repair_run",
             "repair_runs/get",
             "get_repair_run",
             "repair_runs/record_artifact",
             "record_repair_run_artifact",
             "repair_runs/reconcile_prediction",
             "reconcile_repair_prediction",
             "repair_runs/score_predictions",
             "score_repair_predictions",
             "repair_runs/choose_strategy",
             "choose_repair_strategy",
             "repair_runs/draft_architecture_plan",
             "draft_repair_architecture_plan",
             "repair_runs/draft_blast_radius",
             "draft_repair_blast_radius",
             "repair_runs/draft_original_issue_check",
             "draft_repair_original_issue_check",
             "repair_runs/execute_original_issue_check",
             "execute_repair_original_issue_check",
             "repair_runs/execute_impact_check",
             "execute_repair_impact_check",
             "repair_runs/draft_related_issue_sweep",
             "draft_repair_related_issue_sweep",
             "repair_runs/begin_implementation",
             "begin_repair_implementation",
             "repair_runs/approve_gate",
             "approve_repair_gate",
             "repair_runs/complete",
             "complete_repair_run"
           ] do
    handle_action_result(Tasks.execute_action(repair_tool_name(method), params, opts))
  end

  def handle_request(%{"method" => method, "params" => params}, opts)
      when method in ["agents/list", "list_agents"] do
    status = Map.get(params, "status")

    result =
      opts
      |> Tasks.agents()
      |> filter_status(status)

    %{"ok" => true, "result" => result}
  end

  def handle_request(%{"method" => method}, opts) when method in ["agents/list", "list_agents"] do
    %{"ok" => true, "result" => Tasks.agents(opts)}
  end

  def handle_request(%{"method" => method, "params" => params}, opts)
      when method in ["agents/create", "create_agent"] do
    case Tasks.create_agent(params, opts) do
      {:ok, agent} -> %{"ok" => true, "result" => agent}
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => method, "params" => params}, opts)
      when method in ["agents/show", "get_agent"] do
    with {:ok, agent_id} <- agent_id_param(params),
         {:ok, agent} <- Tasks.get_agent(agent_id, opts) do
      %{"ok" => true, "result" => agent}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => method, "params" => params}, opts)
      when method in ["agents/update", "update_agent"] do
    with {:ok, agent_id} <- agent_id_param(params),
         {:ok, agent} <- Tasks.update_agent(agent_id, Map.drop(params, ["id", "agent_id"]), opts) do
      %{"ok" => true, "result" => agent}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => method, "params" => params}, opts)
      when method in ["agents/suspend", "suspend_agent"] do
    handle_agent_lifecycle(params, opts, &Tasks.suspend_agent/3)
  end

  def handle_request(%{"method" => method, "params" => params}, opts)
      when method in ["agents/resume", "resume_agent"] do
    handle_agent_lifecycle(params, opts, &Tasks.resume_agent/3)
  end

  def handle_request(%{"method" => method, "params" => params}, opts)
      when method in ["agents/archive", "archive_agent"] do
    handle_agent_lifecycle(params, opts, &Tasks.archive_agent/3)
  end

  def handle_request(%{"method" => method, "params" => params}, opts)
      when method in ["agents/delete", "delete_agent"] do
    handle_action_result(Tasks.execute_action("delete_agent", params, opts))
  end

  def handle_request(%{"method" => method, "params" => params}, opts)
      when method in ["agents/invoke", "invoke_agent"] do
    handle_action_result(Tasks.execute_action("invoke_agent", params, opts))
  end

  def handle_request(%{"method" => method, "params" => params}, opts)
      when method in ["agents/card", "get_agent_card"] do
    with {:ok, agent_id} <- agent_id_param(params),
         {:ok, card} <- Tasks.agent_card(agent_id, opts) do
      %{"ok" => true, "result" => card}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => method, "params" => params}, opts)
      when method in ["agents/cards", "list_agent_cards"] do
    %{"ok" => true, "result" => Tasks.agent_cards(Keyword.merge(opts, status: params["status"]))}
  end

  def handle_request(%{"method" => method, "params" => params}, opts)
      when method in ["agents/skills", "list_agent_skills"] do
    with {:ok, agent_id} <- agent_id_param(params),
         {:ok, skills} <- Tasks.agent_skills(agent_id, opts) do
      %{"ok" => true, "result" => skills}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "memory/search", "params" => %{"query" => query}}, opts) do
    %{"ok" => true, "result" => Memory.search(query, opts)}
  end

  def handle_request(%{"method" => "research_claims/list", "params" => params}, opts) do
    claim_opts =
      opts
      |> maybe_put_opt(:task_ref, params["task_ref"] || params["ref"])
      |> maybe_put_opt(:source_type, params["source_type"])

    %{"ok" => true, "result" => Tasks.research_claims(claim_opts)}
  end

  def handle_request(%{"method" => "research_claims/list"}, opts) do
    %{"ok" => true, "result" => Tasks.research_claims(opts)}
  end

  def handle_request(%{"method" => "tasks/list", "params" => params}, opts) do
    task_opts = Keyword.merge(opts, status: Map.get(params, "status"))
    %{"ok" => true, "result" => Tasks.list(task_opts)}
  end

  def handle_request(%{"method" => "tasks/list"}, opts) do
    %{"ok" => true, "result" => Tasks.list(opts)}
  end

  def handle_request(%{"method" => "tasks/create", "params" => params}, opts) do
    case Tasks.create(params, opts) do
      {:ok, task} -> %{"ok" => true, "result" => task}
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "tasks/show", "params" => %{"ref" => ref}}, opts) do
    case Tasks.get(ref, opts) do
      {:ok, task} -> %{"ok" => true, "result" => task}
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "tasks/update", "params" => %{"ref" => ref} = params}, opts) do
    case Tasks.update(ref, Map.delete(params, "ref"), opts) do
      {:ok, task} -> %{"ok" => true, "result" => task}
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "tasks/add_label", "params" => %{"ref" => ref} = params}, opts) do
    case Tasks.add_label(ref, params, opts) do
      {:ok, task} -> %{"ok" => true, "result" => task}
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(
        %{"method" => "tasks/remove_label", "params" => %{"ref" => ref, "name" => name}},
        opts
      ) do
    case Tasks.remove_label(ref, name, opts) do
      {:ok, task} -> %{"ok" => true, "result" => task}
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(
        %{
          "method" => "tasks/add_link",
          "params" => %{"ref" => ref, "target_ref" => target_ref} = params
        },
        opts
      ) do
    case Tasks.add_link(ref, target_ref, Map.get(params, "type", "relates_to"), opts) do
      {:ok, task} -> %{"ok" => true, "result" => task}
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(
        %{"method" => "tasks/remove_link", "params" => %{"ref" => ref, "link_id" => link_id}},
        opts
      ) do
    case Tasks.remove_link(ref, link_id, opts) do
      {:ok, task} -> %{"ok" => true, "result" => task}
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(
        %{
          "method" => "tasks/delete_comment",
          "params" => %{"ref" => ref, "comment_id" => comment_id}
        },
        opts
      ) do
    case Tasks.delete_comment(ref, comment_id, opts) do
      {:ok, task} -> %{"ok" => true, "result" => task}
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "tasks/save_spec", "params" => %{"ref" => ref} = params}, opts) do
    case Tasks.save_spec(ref, params, opts) do
      {:ok, spec} -> %{"ok" => true, "result" => spec}
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(
        %{"method" => "tasks/list_specs", "params" => %{"ref" => ref} = params},
        opts
      ) do
    spec_opts =
      opts
      |> Keyword.put(:kind, Map.get(params, "kind", "all"))
      |> Keyword.put(:include_content, Map.get(params, "include_content", true))
      |> Keyword.put(:content_limit, Map.get(params, "content_limit"))

    case Tasks.list_specs(ref, spec_opts) do
      {:ok, specs} -> %{"ok" => true, "result" => specs}
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(
        %{"method" => "tasks/get_spec", "params" => %{"spec_id" => spec_id} = params},
        opts
      ) do
    spec_opts =
      opts
      |> Keyword.put(:task_ref, Map.get(params, "ref"))
      |> Keyword.put(:content_limit, Map.get(params, "content_limit"))

    case Tasks.get_spec(spec_id, spec_opts) do
      {:ok, spec} -> %{"ok" => true, "result" => spec}
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(
        %{"method" => "tasks/save_teammate_memory", "params" => %{"ref" => ref} = params},
        opts
      ) do
    case Tasks.save_teammate_memory(ref, params, opts) do
      {:ok, spec} -> %{"ok" => true, "result" => spec}
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(
        %{"method" => "tasks/load_teammate_runtime", "params" => %{"ref" => ref} = params},
        opts
      ) do
    runtime_opts =
      opts
      |> Keyword.put(:content_limit, Map.get(params, "content_limit"))
      |> Keyword.put(:comment_limit, Map.get(params, "comment_limit"))

    case Tasks.load_teammate_runtime(ref, runtime_opts) do
      {:ok, text} -> %{"ok" => true, "result" => %{"text" => text}}
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(
        %{
          "method" => "tasks/read_memory_artifact",
          "params" => %{"artifact_ref" => artifact_ref}
        },
        opts
      ) do
    case Tasks.read_memory_artifact(artifact_ref, opts) do
      {:ok, artifact} -> %{"ok" => true, "result" => artifact}
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "tasks/run", "params" => %{"ref" => ref} = params}, opts) do
    case Tasks.start_agent_work(ref, params, opts) do
      {:ok, result} -> %{"ok" => true, "result" => result}
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "tasks/continue", "params" => %{"ref" => ref} = params}, opts) do
    case Tasks.continue_agent_work(ref, params, opts) do
      {:ok, result} -> %{"ok" => true, "result" => result}
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "tasks/verify", "params" => %{"ref" => ref} = params}, opts) do
    case Tasks.route_verification(ref, params, opts) do
      {:ok, result} -> %{"ok" => true, "result" => result}
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(
        %{"method" => "tasks/create_graph", "params" => %{"ref" => ref} = params},
        opts
      ) do
    case Tasks.create_task_graph(ref, Map.delete(params, "ref"), opts) do
      {:ok, graph} -> %{"ok" => true, "result" => graph}
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "tasks/list_graphs", "params" => %{"ref" => ref}}, opts) do
    case Tasks.task_graphs(ref, opts) do
      {:ok, graphs} -> %{"ok" => true, "result" => graphs}
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(
        %{"method" => "tasks/get_graph", "params" => %{"graph_id" => graph_id}},
        opts
      ) do
    case Tasks.get_task_graph(graph_id, opts) do
      {:ok, graph} -> %{"ok" => true, "result" => graph}
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(
        %{"method" => "tasks/advance_graph", "params" => %{"graph_id" => graph_id} = params},
        opts
      ) do
    case Tasks.advance_task_graph(graph_id, Map.delete(params, "graph_id"), opts) do
      {:ok, graph} -> %{"ok" => true, "result" => graph}
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(
        %{"method" => "tasks/work_graph", "params" => %{"ref" => ref} = params},
        opts
      ) do
    case Tasks.work_graph(ref, Map.delete(params, "ref"), opts) do
      {:ok, graph} -> %{"ok" => true, "result" => graph}
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(
        %{"method" => "tasks/work_graph_gate", "params" => %{"ref" => ref} = params},
        opts
      ) do
    case Tasks.work_graph_gate(ref, Map.delete(params, "ref"), opts) do
      {:ok, gate} -> %{"ok" => true, "result" => gate}
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(
        %{"method" => "tasks/work_graph_budget", "params" => %{"ref" => ref} = params},
        opts
      ) do
    case Tasks.work_graph_budget(ref, Map.delete(params, "ref"), opts) do
      {:ok, budget} -> %{"ok" => true, "result" => budget}
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(
        %{"method" => "tasks/work_graph_schedule", "params" => %{"ref" => ref} = params},
        opts
      ) do
    case Tasks.work_graph_schedule(ref, Map.delete(params, "ref"), opts) do
      {:ok, schedule} -> %{"ok" => true, "result" => schedule}
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(
        %{"method" => "tasks/agent_dispatch_plan", "params" => %{"ref" => ref} = params},
        opts
      ) do
    case Tasks.agent_dispatch_plan(ref, Map.delete(params, "ref"), opts) do
      {:ok, plan} -> %{"ok" => true, "result" => plan}
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(
        %{"method" => "tasks/team_orchestration", "params" => %{"ref" => ref} = params},
        opts
      ) do
    case Tasks.team_orchestration(ref, Map.delete(params, "ref"), opts) do
      {:ok, plan} -> %{"ok" => true, "result" => plan}
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(
        %{"method" => "tasks/child_agent_contract", "params" => %{"ref" => ref} = params},
        opts
      ) do
    case Tasks.child_agent_contract(ref, Map.delete(params, "ref"), opts) do
      {:ok, contract} -> %{"ok" => true, "result" => contract}
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(
        %{
          "method" => "tasks/complete_graph_node",
          "params" => %{"graph_id" => graph_id} = params
        },
        opts
      ) do
    with {:ok, node_ref} <- graph_node_ref_param(params),
         {:ok, graph} <-
           Tasks.complete_task_graph_node(
             graph_id,
             node_ref,
             Map.drop(params, ["graph_id", "node_ref", "node_id", "node_key"]),
             opts
           ) do
      %{"ok" => true, "result" => graph}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(
        %{"method" => "tasks/evidence_contract", "params" => %{"ref" => ref} = params},
        opts
      ) do
    case Tasks.evidence_contract(ref, Map.delete(params, "ref"), opts) do
      {:ok, contract} -> %{"ok" => true, "result" => contract}
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(
        %{"method" => "tasks/plan_verifier_route", "params" => %{"ref" => ref} = params},
        opts
      ) do
    case Tasks.plan_verifier_route(ref, Map.delete(params, "ref"), opts) do
      {:ok, result} -> %{"ok" => true, "result" => result}
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(
        %{"method" => "tasks/tool_session", "params" => %{"ref" => ref} = params},
        opts
      ) do
    case Tasks.task_tool_session(ref, Map.delete(params, "ref"), opts) do
      {:ok, session} -> %{"ok" => true, "result" => session}
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(
        %{"method" => "tasks/route_tool", "params" => %{"ref" => ref} = params},
        opts
      ) do
    case Tasks.route_task_tool(ref, Map.delete(params, "ref"), opts) do
      {:ok, route} -> %{"ok" => true, "result" => route}
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => method, "params" => %{"ref" => ref} = params}, opts)
      when method in ["tasks/execute_tool", "execute_tool"] do
    with {:ok, tool_name} <- required_any_param(params, ["tool_name", "name", "tool"]) do
      args =
        params
        |> Map.get(
          "arguments",
          Map.drop(params, ["ref", "task_id", "id", "tool_name", "name", "tool"])
        )

      handle_action_result(Tasks.execute_task_action(ref, tool_name, args, opts))
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => method, "params" => %{"ref" => ref} = params}, opts)
      when method in ["tasks/multi_execute_tool", "multi_execute_tool"] do
    calls = params["calls"] || params["tools"]
    handle_action_result(Tasks.execute_task_actions(ref, calls, opts))
  end

  def handle_request(
        %{"method" => "tasks/action_contract", "params" => %{"ref" => ref} = params},
        opts
      ) do
    case Tasks.action_contract(ref, Map.delete(params, "ref"), opts) do
      {:ok, contract} -> %{"ok" => true, "result" => contract}
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(
        %{"method" => "tasks/plan_contract", "params" => %{"ref" => ref} = params},
        opts
      ) do
    case Tasks.plan_contract(ref, Map.delete(params, "ref"), opts) do
      {:ok, contract} -> %{"ok" => true, "result" => contract}
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(
        %{"method" => "tasks/plan_gate", "params" => %{"ref" => ref} = params},
        opts
      ) do
    case Tasks.plan_gate(ref, Map.delete(params, "ref"), opts) do
      {:ok, gate} -> %{"ok" => true, "result" => gate}
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(
        %{"method" => "tasks/action_preflight", "params" => %{"ref" => ref} = params},
        opts
      ) do
    case Tasks.action_preflight(ref, Map.delete(params, "ref"), opts) do
      {:ok, preflight} -> %{"ok" => true, "result" => preflight}
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(
        %{"method" => "tasks/consequence_gate", "params" => %{"ref" => ref} = params},
        opts
      ) do
    case Tasks.consequence_gate(ref, Map.delete(params, "ref"), opts) do
      {:ok, gate} -> %{"ok" => true, "result" => gate}
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(
        %{"method" => "tasks/action_runtime_envelope", "params" => %{"ref" => ref} = params},
        opts
      ) do
    case Tasks.action_runtime_envelope(ref, Map.delete(params, "ref"), opts) do
      {:ok, envelope} -> %{"ok" => true, "result" => envelope}
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(
        %{"method" => "tasks/complete_action_runtime_envelope", "params" => params},
        _opts
      ) do
    case Tasks.complete_action_runtime_envelope(
           params["envelope"],
           Map.delete(params, "envelope")
         ) do
      {:ok, envelope} -> %{"ok" => true, "result" => envelope}
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(
        %{"method" => "tasks/action_approval_request", "params" => %{"ref" => ref} = params},
        opts
      ) do
    case Tasks.action_approval_request(ref, Map.delete(params, "ref"), opts) do
      {:ok, request} -> %{"ok" => true, "result" => request}
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(
        %{"method" => "tasks/resolve_action_approval_request", "params" => params},
        opts
      ) do
    with {:ok, request_id} <- required_any_param(params, ["approval_request_id", "request_id"]) do
      case Tasks.resolve_action_approval_request(
             request_id,
             Map.drop(params, ["approval_request_id", "request_id"]),
             opts
           ) do
        {:ok, request} -> %{"ok" => true, "result" => request}
        {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
      end
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(
        %{"method" => "tasks/action_evidence_ledger", "params" => %{"ref" => ref} = params},
        opts
      ) do
    case Tasks.action_evidence_ledger(ref, Map.delete(params, "ref"), opts) do
      {:ok, ledger} -> %{"ok" => true, "result" => ledger}
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(
        %{"method" => "tasks/record_memory_artifact", "params" => %{"ref" => ref} = params},
        opts
      ) do
    case Tasks.record_task_memory_artifact(ref, Map.delete(params, "ref"), opts) do
      {:ok, artifact} -> %{"ok" => true, "result" => artifact}
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(
        %{"method" => "tasks/task_memory_context", "params" => %{"ref" => ref} = params},
        opts
      ) do
    case Tasks.task_memory_context(ref, Map.delete(params, "ref"), opts) do
      {:ok, packet} -> %{"ok" => true, "result" => packet}
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(
        %{"method" => "tasks/context_budget", "params" => %{"ref" => ref} = params},
        opts
      ) do
    case Tasks.context_budget(ref, Map.delete(params, "ref"), opts) do
      {:ok, budget} -> %{"ok" => true, "result" => budget}
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(
        %{"method" => "tasks/continuation_packet", "params" => %{"ref" => ref} = params},
        opts
      ) do
    case Tasks.continuation_packet(ref, Map.delete(params, "ref"), opts) do
      {:ok, packet} -> %{"ok" => true, "result" => packet}
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "tasks/capability_registry", "params" => params}, _opts) do
    with {:ok, tool_name} <- required_any_param(params, ["tool_name", "name", "tool"]),
         {:ok, entry} <- Tasks.capability_registry(tool_name, params) do
      %{"ok" => true, "result" => entry}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(
        %{"method" => "tasks/capability_contract", "params" => %{"ref" => ref} = params},
        opts
      ) do
    case Tasks.capability_contract(ref, Map.delete(params, "ref"), opts) do
      {:ok, contract} -> %{"ok" => true, "result" => contract}
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(
        %{"method" => "tasks/capability_route", "params" => %{"ref" => ref} = params},
        opts
      ) do
    case Tasks.capability_route(ref, Map.delete(params, "ref"), opts) do
      {:ok, route} -> %{"ok" => true, "result" => route}
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(
        %{"method" => "tasks/generic_plan", "params" => %{"ref" => ref} = params},
        opts
      ) do
    case Tasks.generic_plan(ref, Map.delete(params, "ref"), opts) do
      {:ok, plan} -> %{"ok" => true, "result" => plan}
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(
        %{"method" => "tasks/verification_contract", "params" => %{"ref" => ref} = params},
        opts
      ) do
    case Tasks.verification_contract(ref, Map.delete(params, "ref"), opts) do
      {:ok, contract} -> %{"ok" => true, "result" => contract}
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(
        %{"method" => "tasks/verifier_assignment", "params" => %{"ref" => ref} = params},
        opts
      ) do
    case Tasks.verifier_assignment(ref, Map.delete(params, "ref"), opts) do
      {:ok, assignment} -> %{"ok" => true, "result" => assignment}
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(
        %{"method" => "tasks/verifier_dispatch", "params" => %{"ref" => ref} = params},
        opts
      ) do
    case Tasks.verifier_dispatch(ref, Map.delete(params, "ref"), opts) do
      {:ok, dispatch} -> %{"ok" => true, "result" => dispatch}
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(
        %{"method" => "tasks/verifier_calibration", "params" => %{"ref" => ref} = params},
        opts
      ) do
    case Tasks.verifier_calibration(ref, Map.delete(params, "ref"), opts) do
      {:ok, calibration} -> %{"ok" => true, "result" => calibration}
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "tasks/watchdog", "params" => params}, opts) do
    %{"ok" => true, "result" => Tasks.watchdog_scan(Keyword.merge(opts, watchdog_opts(params)))}
  end

  def handle_request(%{"method" => "tasks/watchdog"}, opts) do
    %{"ok" => true, "result" => Tasks.watchdog_scan(opts)}
  end

  def handle_request(%{"method" => "tasks/record_process_started", "params" => params}, opts) do
    handle_process_started(params, opts)
  end

  def handle_request(%{"method" => "tasks/notify_process_terminal", "params" => params}, opts) do
    handle_process_terminal(params, opts)
  end

  def handle_request(%{"method" => method, "params" => params}, opts)
      when method in ["tasks/agent_run_events", "list_agent_run_events"] do
    handle_list_agent_run_events(params, opts)
  end

  def handle_request(%{"method" => method, "params" => params}, opts)
      when method in ["tasks/search_agent_run_events", "search_agent_run_events"] do
    handle_search_agent_run_events(params, opts)
  end

  def handle_request(%{"method" => method, "params" => params}, opts)
      when method in ["tasks/agent_run_replay", "agent_run_replay"] do
    handle_agent_run_replay(params, opts)
  end

  def handle_request(%{"method" => method, "params" => params}, opts)
      when method in ["tasks/record_agent_run_event", "record_agent_run_event"] do
    handle_record_agent_run_event(params, opts, "generic")
  end

  def handle_request(%{"method" => method, "params" => params}, opts)
      when method in ["tasks/record_tool_event", "record_tool_event"] do
    handle_record_agent_run_event(params, opts, "tool")
  end

  def handle_request(%{"method" => method, "params" => params}, opts)
      when method in ["tasks/record_agent_narration", "record_agent_narration"] do
    handle_record_agent_run_event(params, opts, "narration")
  end

  def handle_request(%{"method" => method, "params" => params}, opts)
      when method in ["tasks/record_plan_contract", "record_plan_contract"] do
    handle_record_agent_run_event(params, opts, "plan_contract")
  end

  def handle_request(%{"method" => method, "params" => params}, opts)
      when method in ["tasks/record_child_agent_contract", "record_child_agent_contract"] do
    handle_record_agent_run_event(params, opts, "child_contract")
  end

  def handle_request(%{"method" => method, "params" => params}, opts)
      when method in ["tasks/record_child_agent_completion", "record_child_agent_completion"] do
    handle_record_agent_run_event(params, opts, "child_completion")
  end

  def handle_request(%{"method" => method, "params" => params}, opts)
      when method in ["tasks/record_objective_evaluation", "record_objective_evaluation"] do
    handle_record_agent_run_event(params, opts, "objective")
  end

  def handle_request(%{"method" => method, "params" => params}, opts)
      when method in ["tasks/record_continuation_packet", "record_continuation_packet"] do
    handle_record_agent_run_event(params, opts, "continuation_packet")
  end

  def handle_request(%{"method" => "list_tasks", "params" => params}, opts) do
    task_opts = Keyword.merge(opts, status: Map.get(params, "status"))
    %{"ok" => true, "result" => Tasks.list(task_opts)}
  end

  def handle_request(%{"method" => "list_tasks"}, opts) do
    %{"ok" => true, "result" => Tasks.list(opts)}
  end

  def handle_request(%{"method" => "create_task", "params" => params}, opts) do
    case Tasks.create(params, opts) do
      {:ok, task} -> %{"ok" => true, "result" => task}
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "get_task", "params" => params}, opts) do
    with {:ok, ref} <- task_ref_param(params),
         {:ok, task} <- Tasks.get(ref, opts) do
      %{"ok" => true, "result" => task}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "update_task", "params" => params}, opts) do
    with {:ok, ref} <- task_ref_param(params),
         {:ok, task} <- Tasks.update(ref, drop_ref_params(params), opts) do
      %{"ok" => true, "result" => task}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "add_comment", "params" => params}, opts) do
    with {:ok, ref} <- task_ref_param(params),
         {:ok, task} <-
           Tasks.add_comment(ref, params["body"] || params["comment"] || params["text"], opts) do
      %{"ok" => true, "result" => task}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "delete_comment", "params" => params}, opts) do
    with {:ok, ref} <- task_ref_param(params),
         {:ok, comment_id} <- required_param(params, "comment_id"),
         {:ok, task} <- Tasks.delete_comment(ref, comment_id, opts) do
      %{"ok" => true, "result" => task}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "add_label", "params" => params}, opts) do
    with {:ok, ref} <- task_ref_param(params),
         {:ok, task} <- Tasks.add_label(ref, params, opts) do
      %{"ok" => true, "result" => task}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "remove_label", "params" => params}, opts) do
    with {:ok, ref} <- task_ref_param(params),
         {:ok, name} <- required_param(params, "name"),
         {:ok, task} <- Tasks.remove_label(ref, name, opts) do
      %{"ok" => true, "result" => task}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "add_link", "params" => params}, opts) do
    with {:ok, ref} <- task_ref_param(params),
         {:ok, target_ref} <- target_ref_param(params),
         {:ok, task} <-
           Tasks.add_link(ref, target_ref, Map.get(params, "type", "relates_to"), opts) do
      %{"ok" => true, "result" => task}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "remove_link", "params" => params}, opts) do
    with {:ok, ref} <- task_ref_param(params),
         {:ok, link_id} <- required_param(params, "link_id"),
         {:ok, task} <- Tasks.remove_link(ref, link_id, opts) do
      %{"ok" => true, "result" => task}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "set_priority", "params" => params}, opts) do
    with {:ok, ref} <- task_ref_param(params),
         {:ok, task} <- Tasks.set_priority(ref, Map.get(params, "priority"), opts) do
      %{"ok" => true, "result" => task}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "set_estimate", "params" => params}, opts) do
    with {:ok, ref} <- task_ref_param(params),
         {:ok, task} <- Tasks.set_estimate(ref, Map.get(params, "estimate"), opts) do
      %{"ok" => true, "result" => task}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "save_task_spec", "params" => params}, opts) do
    with {:ok, ref} <- task_ref_param(params),
         {:ok, spec} <- Tasks.save_spec(ref, params, opts) do
      %{"ok" => true, "result" => spec}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "list_task_specs", "params" => params}, opts) do
    with {:ok, ref} <- task_ref_param(params) do
      spec_opts =
        opts
        |> Keyword.put(:kind, Map.get(params, "kind", "all"))
        |> Keyword.put(:include_content, Map.get(params, "include_content", true))
        |> Keyword.put(:content_limit, Map.get(params, "content_limit"))

      case Tasks.list_specs(ref, spec_opts) do
        {:ok, specs} -> %{"ok" => true, "result" => specs}
        {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
      end
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "get_task_spec", "params" => params}, opts) do
    with {:ok, spec_id} <- required_param(params, "spec_id") do
      spec_opts =
        opts
        |> Keyword.put(:task_ref, params["ref"] || params["task_id"])
        |> Keyword.put(:content_limit, Map.get(params, "content_limit"))

      case Tasks.get_spec(spec_id, spec_opts) do
        {:ok, spec} -> %{"ok" => true, "result" => spec}
        {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
      end
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "save_teammate_memory", "params" => params}, opts) do
    with {:ok, ref} <- task_ref_param(params),
         {:ok, spec} <- Tasks.save_teammate_memory(ref, params, opts) do
      %{"ok" => true, "result" => spec}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "load_teammate_runtime", "params" => params}, opts) do
    with {:ok, ref} <- task_ref_param(params) do
      runtime_opts =
        opts
        |> Keyword.put(:content_limit, Map.get(params, "content_limit"))
        |> Keyword.put(:comment_limit, Map.get(params, "comment_limit"))

      case Tasks.load_teammate_runtime(ref, runtime_opts) do
        {:ok, text} -> %{"ok" => true, "result" => %{"text" => text}}
        {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
      end
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "read_task_memory_artifact", "params" => params}, opts) do
    with {:ok, artifact_ref} <- required_param(params, "artifact_ref"),
         {:ok, artifact} <- Tasks.read_memory_artifact(artifact_ref, opts) do
      %{"ok" => true, "result" => artifact}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "start_agent_work", "params" => params}, opts) do
    with {:ok, result} <- Tasks.start_agent_work_batch(params, opts) do
      %{"ok" => true, "result" => result}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "continue_agent_work", "params" => params}, opts) do
    with {:ok, ref} <- task_ref_param(params),
         {:ok, result} <- Tasks.continue_agent_work(ref, params, opts) do
      %{"ok" => true, "result" => result}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "route_verification_review", "params" => params}, opts) do
    with {:ok, ref} <- task_ref_param(params),
         {:ok, result} <- Tasks.route_verification(ref, params, opts) do
      %{"ok" => true, "result" => result}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "create_task_graph", "params" => params}, opts) do
    with {:ok, ref} <- task_ref_param(params),
         {:ok, graph} <- Tasks.create_task_graph(ref, drop_ref_params(params), opts) do
      %{"ok" => true, "result" => graph}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "list_task_graphs", "params" => params}, opts) do
    with {:ok, ref} <- task_ref_param(params),
         {:ok, graphs} <- Tasks.task_graphs(ref, opts) do
      %{"ok" => true, "result" => graphs}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "get_task_graph", "params" => params}, opts) do
    with {:ok, graph_id} <- required_param(params, "graph_id"),
         {:ok, graph} <- Tasks.get_task_graph(graph_id, opts) do
      %{"ok" => true, "result" => graph}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "advance_task_graph", "params" => params}, opts) do
    with {:ok, graph_id} <- required_param(params, "graph_id"),
         {:ok, graph} <- Tasks.advance_task_graph(graph_id, Map.delete(params, "graph_id"), opts) do
      %{"ok" => true, "result" => graph}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "complete_task_graph_node", "params" => params}, opts) do
    with {:ok, graph_id} <- required_param(params, "graph_id"),
         {:ok, node_ref} <- graph_node_ref_param(params),
         {:ok, graph} <-
           Tasks.complete_task_graph_node(
             graph_id,
             node_ref,
             Map.drop(params, ["graph_id", "node_ref", "node_id", "node_key"]),
             opts
           ) do
      %{"ok" => true, "result" => graph}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "work_graph", "params" => params}, opts) do
    with {:ok, ref} <- task_ref_param(params),
         {:ok, graph} <- Tasks.work_graph(ref, drop_ref_params(params), opts) do
      %{"ok" => true, "result" => graph}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "work_graph_gate", "params" => params}, opts) do
    with {:ok, ref} <- task_ref_param(params),
         {:ok, gate} <- Tasks.work_graph_gate(ref, drop_ref_params(params), opts) do
      %{"ok" => true, "result" => gate}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "work_graph_budget", "params" => params}, opts) do
    with {:ok, ref} <- task_ref_param(params),
         {:ok, budget} <- Tasks.work_graph_budget(ref, drop_ref_params(params), opts) do
      %{"ok" => true, "result" => budget}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "work_graph_schedule", "params" => params}, opts) do
    with {:ok, ref} <- task_ref_param(params),
         {:ok, schedule} <- Tasks.work_graph_schedule(ref, drop_ref_params(params), opts) do
      %{"ok" => true, "result" => schedule}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "schedule_work_graph", "params" => params}, opts) do
    handle_request(%{"method" => "work_graph_schedule", "params" => params}, opts)
  end

  def handle_request(%{"method" => "agent_dispatch_plan", "params" => params}, opts) do
    with {:ok, ref} <- task_ref_param(params),
         {:ok, plan} <- Tasks.agent_dispatch_plan(ref, drop_ref_params(params), opts) do
      %{"ok" => true, "result" => plan}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "team_orchestration", "params" => params}, opts) do
    with {:ok, ref} <- task_ref_param(params),
         {:ok, plan} <- Tasks.team_orchestration(ref, drop_ref_params(params), opts) do
      %{"ok" => true, "result" => plan}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "child_agent_contract", "params" => params}, opts) do
    with {:ok, ref} <- task_ref_param(params),
         {:ok, contract} <- Tasks.child_agent_contract(ref, drop_ref_params(params), opts) do
      %{"ok" => true, "result" => contract}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "get_evidence_contract", "params" => params}, opts) do
    with {:ok, ref} <- task_ref_param(params),
         {:ok, contract} <- Tasks.evidence_contract(ref, drop_ref_params(params), opts) do
      %{"ok" => true, "result" => contract}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "verification_contract", "params" => params}, opts) do
    with {:ok, ref} <- task_ref_param(params),
         {:ok, contract} <- Tasks.verification_contract(ref, drop_ref_params(params), opts) do
      %{"ok" => true, "result" => contract}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "plan_verifier_route", "params" => params}, opts) do
    with {:ok, ref} <- task_ref_param(params),
         {:ok, result} <- Tasks.plan_verifier_route(ref, drop_ref_params(params), opts) do
      %{"ok" => true, "result" => result}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "verifier_assignment", "params" => params}, opts) do
    with {:ok, ref} <- task_ref_param(params),
         {:ok, assignment} <- Tasks.verifier_assignment(ref, drop_ref_params(params), opts) do
      %{"ok" => true, "result" => assignment}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "assign_verifier", "params" => params}, opts) do
    handle_request(%{"method" => "verifier_assignment", "params" => params}, opts)
  end

  def handle_request(%{"method" => "verifier_dispatch", "params" => params}, opts) do
    with {:ok, ref} <- task_ref_param(params),
         {:ok, dispatch} <- Tasks.verifier_dispatch(ref, drop_ref_params(params), opts) do
      %{"ok" => true, "result" => dispatch}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "dispatch_verifier", "params" => params}, opts) do
    handle_request(%{"method" => "verifier_dispatch", "params" => params}, opts)
  end

  def handle_request(%{"method" => "verifier_calibration", "params" => params}, opts) do
    with {:ok, ref} <- task_ref_param(params),
         {:ok, calibration} <- Tasks.verifier_calibration(ref, drop_ref_params(params), opts) do
      %{"ok" => true, "result" => calibration}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "task_tool_session", "params" => params}, opts) do
    with {:ok, ref} <- task_ref_param(params),
         {:ok, session} <- Tasks.task_tool_session(ref, drop_ref_params(params), opts) do
      %{"ok" => true, "result" => session}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "get_task_tool_session", "params" => params}, opts) do
    handle_request(%{"method" => "task_tool_session", "params" => params}, opts)
  end

  def handle_request(%{"method" => "route_task_tool", "params" => params}, opts) do
    with {:ok, ref} <- task_ref_param(params),
         {:ok, route} <- Tasks.route_task_tool(ref, drop_ref_params(params), opts) do
      %{"ok" => true, "result" => route}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "task_tool_route", "params" => params}, opts) do
    handle_request(%{"method" => "route_task_tool", "params" => params}, opts)
  end

  def handle_request(%{"method" => method, "params" => params}, opts)
      when method in ["tasks/execute_tool", "execute_tool"] do
    with {:ok, ref} <- task_ref_param(params),
         {:ok, tool_name} <- required_any_param(params, ["tool_name", "name", "tool"]) do
      args =
        params
        |> Map.get(
          "arguments",
          Map.drop(params, ["ref", "task_id", "id", "tool_name", "name", "tool"])
        )

      handle_action_result(Tasks.execute_task_action(ref, tool_name, args, opts))
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => method, "params" => params}, opts)
      when method in ["tasks/multi_execute_tool", "multi_execute_tool"] do
    with {:ok, ref} <- task_ref_param(params) do
      calls = params["calls"] || params["tools"]
      handle_action_result(Tasks.execute_task_actions(ref, calls, opts))
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "action_contract", "params" => params}, opts) do
    with {:ok, ref} <- task_ref_param(params),
         {:ok, contract} <- Tasks.action_contract(ref, drop_ref_params(params), opts) do
      %{"ok" => true, "result" => contract}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "plan_contract", "params" => params}, opts) do
    with {:ok, ref} <- task_ref_param(params),
         {:ok, contract} <- Tasks.plan_contract(ref, drop_ref_params(params), opts) do
      %{"ok" => true, "result" => contract}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "plan_gate", "params" => params}, opts) do
    with {:ok, ref} <- task_ref_param(params),
         {:ok, gate} <- Tasks.plan_gate(ref, drop_ref_params(params), opts) do
      %{"ok" => true, "result" => gate}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "action_preflight", "params" => params}, opts) do
    with {:ok, ref} <- task_ref_param(params),
         {:ok, preflight} <- Tasks.action_preflight(ref, drop_ref_params(params), opts) do
      %{"ok" => true, "result" => preflight}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "consequence_gate", "params" => params}, opts) do
    with {:ok, ref} <- task_ref_param(params),
         {:ok, gate} <- Tasks.consequence_gate(ref, drop_ref_params(params), opts) do
      %{"ok" => true, "result" => gate}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "action_runtime_envelope", "params" => params}, opts) do
    with {:ok, ref} <- task_ref_param(params),
         {:ok, envelope} <- Tasks.action_runtime_envelope(ref, drop_ref_params(params), opts) do
      %{"ok" => true, "result" => envelope}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "complete_action_runtime_envelope", "params" => params}, _opts) do
    case Tasks.complete_action_runtime_envelope(
           params["envelope"],
           Map.delete(params, "envelope")
         ) do
      {:ok, envelope} -> %{"ok" => true, "result" => envelope}
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "action_approval_request", "params" => params}, opts) do
    with {:ok, ref} <- task_ref_param(params),
         {:ok, request} <- Tasks.action_approval_request(ref, drop_ref_params(params), opts) do
      %{"ok" => true, "result" => request}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "resolve_action_approval_request", "params" => params}, opts) do
    with {:ok, request_id} <- required_any_param(params, ["approval_request_id", "request_id"]),
         {:ok, request} <-
           Tasks.resolve_action_approval_request(
             request_id,
             Map.drop(params, ["approval_request_id", "request_id"]),
             opts
           ) do
      %{"ok" => true, "result" => request}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "action_evidence_ledger", "params" => params}, opts) do
    with {:ok, ref} <- task_ref_param(params),
         {:ok, ledger} <- Tasks.action_evidence_ledger(ref, drop_ref_params(params), opts) do
      %{"ok" => true, "result" => ledger}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "record_task_memory_artifact", "params" => params}, opts) do
    with {:ok, ref} <- task_ref_param(params),
         {:ok, artifact} <- Tasks.record_task_memory_artifact(ref, drop_ref_params(params), opts) do
      %{"ok" => true, "result" => artifact}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "task_memory_context", "params" => params}, opts) do
    with {:ok, ref} <- task_ref_param(params),
         {:ok, packet} <- Tasks.task_memory_context(ref, drop_ref_params(params), opts) do
      %{"ok" => true, "result" => packet}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "get_task_memory_context", "params" => params}, opts) do
    handle_request(%{"method" => "task_memory_context", "params" => params}, opts)
  end

  def handle_request(%{"method" => "context_budget", "params" => params}, opts) do
    with {:ok, ref} <- task_ref_param(params),
         {:ok, budget} <- Tasks.context_budget(ref, drop_ref_params(params), opts) do
      %{"ok" => true, "result" => budget}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "continuation_packet", "params" => params}, opts) do
    with {:ok, ref} <- task_ref_param(params),
         {:ok, packet} <- Tasks.continuation_packet(ref, drop_ref_params(params), opts) do
      %{"ok" => true, "result" => packet}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "capability_registry", "params" => params}, opts) do
    handle_request(%{"method" => "tasks/capability_registry", "params" => params}, opts)
  end

  def handle_request(%{"method" => "capability_contract", "params" => params}, opts) do
    with {:ok, ref} <- task_ref_param(params),
         {:ok, contract} <- Tasks.capability_contract(ref, drop_ref_params(params), opts) do
      %{"ok" => true, "result" => contract}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "capability_route", "params" => params}, opts) do
    with {:ok, ref} <- task_ref_param(params),
         {:ok, route} <- Tasks.capability_route(ref, drop_ref_params(params), opts) do
      %{"ok" => true, "result" => route}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "route_capability", "params" => params}, opts) do
    handle_request(%{"method" => "capability_route", "params" => params}, opts)
  end

  def handle_request(%{"method" => "generic_plan", "params" => params}, opts) do
    with {:ok, ref} <- task_ref_param(params),
         {:ok, plan} <- Tasks.generic_plan(ref, drop_ref_params(params), opts) do
      %{"ok" => true, "result" => plan}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(%{"method" => "watchdog_agent_runs", "params" => params}, opts) do
    %{"ok" => true, "result" => Tasks.watchdog_scan(Keyword.merge(opts, watchdog_opts(params)))}
  end

  def handle_request(%{"method" => "watchdog_agent_runs"}, opts) do
    %{"ok" => true, "result" => Tasks.watchdog_scan(opts)}
  end

  def handle_request(%{"method" => "record_process_started", "params" => params}, opts) do
    handle_process_started(params, opts)
  end

  def handle_request(%{"method" => "process_started", "params" => params}, opts) do
    handle_process_started(params, opts)
  end

  def handle_request(%{"method" => "notify_process_terminal", "params" => params}, opts) do
    handle_process_terminal(params, opts)
  end

  def handle_request(%{"method" => "process_terminal", "params" => params}, opts) do
    handle_process_terminal(params, opts)
  end

  def handle_request(%{"method" => "runtime_doctor", "params" => params}, _opts) do
    %{"ok" => true, "result" => AgentRuntime.doctor(params)}
  end

  def handle_request(%{"method" => "runtime_doctor"}, _opts) do
    %{"ok" => true, "result" => AgentRuntime.doctor(%{})}
  end

  def handle_request(%{"method" => "tool_availability", "params" => params}, _opts) do
    %{"ok" => true, "result" => AgentRuntime.tool_availability(params)}
  end

  def handle_request(%{"method" => "provider_profile", "params" => params}, _opts) do
    model_id = Map.get(params, "model_id") || Map.get(params, "model") || "local-planner"
    %{"ok" => true, "result" => AgentRuntime.provider_profile(model_id, params)}
  end

  def handle_request(%{"method" => "safety_policy", "params" => params}, _opts) do
    %{"ok" => true, "result" => AgentRuntime.safety_policy(params)}
  end

  def handle_request(%{"method" => "runtime_context_budget", "params" => params}, _opts) do
    %{"ok" => true, "result" => AgentRuntime.context_budget(params)}
  end

  def handle_request(%{"method" => "recovery_contract", "params" => params}, _opts) do
    %{"ok" => true, "result" => AgentRuntime.recovery_contract(params)}
  end

  def handle_request(%{"method" => "run_debugger", "params" => params}, _opts) do
    %{"ok" => true, "result" => AgentRuntime.run_debugger(params)}
  end

  def handle_request(%{"method" => "meta_learning_snapshot", "params" => params}, _opts) do
    %{"ok" => true, "result" => AgentRuntime.meta_learning_snapshot(params)}
  end

  def handle_request(%{"method" => "format_local_model_result", "params" => params}, _opts) do
    result = Map.get(params, "result") || Map.get(params, "content") || params
    %{"ok" => true, "result" => %{"content" => AgentRuntime.format_local_model_result(result)}}
  end

  def handle_request(%{"method" => "run", "params" => %{"objective" => objective}}, opts) do
    case Runtime.run(objective, opts) do
      {:ok, result} -> %{"ok" => true, "result" => result}
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  def handle_request(_request, _opts), do: %{"ok" => false, "error" => "unknown_method"}

  defp task_ref_param(params) do
    required_any_param(params, ["ref", "task_id", "id"])
  end

  defp target_ref_param(params) do
    required_any_param(params, ["target_ref", "target_task_id", "target_id"])
  end

  defp agent_id_param(params) do
    required_any_param(params, ["agent_id", "id"])
  end

  defp graph_node_ref_param(params) do
    required_any_param(params, ["node_ref", "node_id", "node_key"])
  end

  defp required_any_param(params, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(params, key) do
        value when is_binary(value) and value != "" -> {:ok, value}
        _value -> nil
      end
    end) || {:error, {:missing_required, Enum.join(keys, "|")}}
  end

  defp required_param(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      value when is_integer(value) -> {:ok, value}
      _value -> {:error, {:missing_required, key}}
    end
  end

  defp drop_ref_params(params) do
    Map.drop(params, ["ref", "task_id", "id"])
  end

  defp watchdog_opts(params) do
    []
    |> maybe_put_opt(:limit, params["limit"])
    |> maybe_put_opt(:stale_after_seconds, params["stale_after_seconds"])
    |> maybe_put_opt(:recovery_cooldown_seconds, params["recovery_cooldown_seconds"])
  end

  defp handle_agent_lifecycle(params, opts, fun) when is_map(params) do
    with {:ok, agent_id} <- agent_id_param(params),
         {:ok, agent} <- fun.(agent_id, Map.drop(params, ["id", "agent_id"]), opts) do
      %{"ok" => true, "result" => agent}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  defp handle_agent_lifecycle(_params, _opts, _fun),
    do: %{"ok" => false, "error" => "invalid_params"}

  defp handle_action_result({:ok, result}), do: %{"ok" => true, "result" => result}

  defp handle_action_result({:error, %{} = execution}) do
    %{"ok" => false, "error" => execution["reason"] || execution["status"], "result" => execution}
  end

  defp handle_action_result({:error, reason}), do: %{"ok" => false, "error" => inspect(reason)}

  defp filter_status(items, nil), do: items
  defp filter_status(items, ""), do: items
  defp filter_status(items, "all"), do: items
  defp filter_status(items, status), do: Enum.filter(items, &(&1["status"] == status))

  defp handle_list_agent_run_events(params, opts) when is_map(params) do
    with {:ok, run_id} <- agent_run_id_param(params),
         {:ok, events} <- Tasks.agent_run_event_log(run_id, opts) do
      %{"ok" => true, "result" => events}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  defp handle_list_agent_run_events(_params, _opts),
    do: %{"ok" => false, "error" => "invalid_params"}

  defp handle_search_agent_run_events(params, opts) when is_map(params) do
    with {:ok, agent_id} <- required_param(params, "agent_id") do
      %{"ok" => true, "result" => Tasks.agent_run_events_by_agent(agent_id, params, opts)}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  defp handle_search_agent_run_events(_params, _opts),
    do: %{"ok" => false, "error" => "invalid_params"}

  defp handle_agent_run_replay(params, opts) when is_map(params) do
    with {:ok, agent_id} <- required_param(params, "agent_id"),
         {:ok, run_id} <- agent_run_id_param(params),
         {:ok, replay} <- Tasks.agent_run_replay(agent_id, run_id, opts) do
      %{"ok" => true, "result" => replay}
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  defp handle_agent_run_replay(_params, _opts), do: %{"ok" => false, "error" => "invalid_params"}

  defp handle_record_agent_run_event(params, opts, event_type) when is_map(params) do
    with {:ok, run_id} <- agent_run_id_param(params) do
      params = Map.drop(params, ["agent_run_id", "run_id", "id"])

      event_type
      |> record_agent_run_event(run_id, params, opts)
      |> agent_run_event_response()
    else
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  defp handle_record_agent_run_event(_params, _opts, _event_type),
    do: %{"ok" => false, "error" => "invalid_params"}

  defp record_agent_run_event("generic", run_id, params, opts),
    do: Tasks.record_agent_run_event(run_id, params, opts)

  defp record_agent_run_event("tool", run_id, params, opts),
    do: Tasks.record_agent_run_tool_event(run_id, params, opts)

  defp record_agent_run_event("narration", run_id, params, opts),
    do: Tasks.record_agent_run_narration(run_id, params, opts)

  defp record_agent_run_event("plan_contract", run_id, params, opts),
    do: Tasks.record_agent_run_plan_contract(run_id, params["plan_contract"] || params, opts)

  defp record_agent_run_event("child_contract", run_id, params, opts),
    do:
      Tasks.record_agent_run_child_contract(
        run_id,
        params["child_agent_contract"] || params,
        opts
      )

  defp record_agent_run_event("child_completion", run_id, params, opts),
    do: Tasks.record_agent_run_child_completion(run_id, params, opts)

  defp record_agent_run_event("objective", run_id, params, opts),
    do: Tasks.record_agent_run_objective_evaluation(run_id, params, opts)

  defp record_agent_run_event("continuation_packet", run_id, params, opts),
    do: Tasks.record_agent_run_continuation_packet(run_id, params["packet"] || params, opts)

  defp agent_run_event_response({:ok, run, event}) do
    %{
      "ok" => true,
      "result" => %{"action" => "event_recorded", "agent_run" => run, "event" => event}
    }
  end

  defp agent_run_event_response({:duplicate, run, event}) do
    %{
      "ok" => true,
      "result" => %{"action" => "duplicate_event", "agent_run" => run, "event" => event}
    }
  end

  defp agent_run_event_response({:error, reason}) do
    %{"ok" => false, "error" => inspect(reason)}
  end

  defp agent_run_id_param(params) do
    required_any_param(params, ["agent_run_id", "run_id", "id"])
  end

  defp handle_process_started(params, opts) when is_map(params) do
    case Tasks.record_process_started(
           process_payload(params, "running"),
           process_context(params),
           opts
         ) do
      {:ok, result} -> %{"ok" => true, "result" => result}
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  defp handle_process_started(_params, _opts), do: %{"ok" => false, "error" => "invalid_params"}

  defp handle_process_terminal(params, opts) when is_map(params) do
    case Tasks.notify_process_terminal(
           process_payload(params, "exited"),
           process_context(params),
           opts
         ) do
      {:ok, result} -> %{"ok" => true, "result" => result}
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  defp handle_process_terminal(_params, _opts), do: %{"ok" => false, "error" => "invalid_params"}

  defp process_payload(params, default_status) do
    payload = params["process"] || params["payload"] || %{}

    payload
    |> Map.put_new("status", params["status"] || default_status)
    |> maybe_put("managed_process_id", params["managed_process_id"])
    |> maybe_put("process_id", params["process_id"])
    |> maybe_put("sandbox_pid", params["sandbox_pid"])
    |> maybe_put("status_path", params["status_path"])
    |> maybe_put("exit_code", params["exit_code"])
    |> maybe_put("wait_for_exit", params["wait_for_exit"])
    |> maybe_put("notify_on_exit", params["notify_on_exit"])
  end

  defp process_context(params) do
    context = params["context"] || %{}

    context
    |> maybe_put("agent_run_id", params["agent_run_id"] || params["run_id"])
    |> maybe_put("run_id", params["run_id"])
    |> maybe_put("routine_run_id", params["routine_run_id"])
    |> maybe_put("work_id", params["work_id"])
    |> maybe_put("workspace", params["workspace"])
  end

  defp session_start_opts(params, opts) do
    params
    |> session_query_opts(opts)
    |> maybe_put_opt(:session_id, params["session_id"] || params["id"])
    |> maybe_put_opt(:agent_id, params["agent_id"] || params["agent"])
    |> maybe_put_opt(:task_id, params["task_id"])
    |> maybe_put_opt(:task_ref, params["task_ref"] || params["ref"])
    |> maybe_put_opt(:approval, approval_mode(params["approval"]))
    |> maybe_put_opt(:await_timeout_ms, params["await_timeout_ms"])
  end

  defp session_query_opts(params, opts) do
    opts
    |> maybe_put_opt(:workspace, params["workspace"])
    |> maybe_put_opt(:home, params["home"])
    |> maybe_put_opt(:status, params["status"])
  end

  defp approval_mode("always_approve"), do: :always_approve
  defp approval_mode("always_deny"), do: :always_deny
  defp approval_mode(value) when value in [nil, ""], do: nil
  defp approval_mode(value), do: value

  defp agent_event_query_opts(params, opts) do
    opts
    |> maybe_put_opt(:limit, params["limit"])
    |> maybe_put_opt(:event_type, params["event_type"])
    |> maybe_put_opt(:workspace, params["workspace"])
  end

  defp repair_tool_name("repair_runs/start"), do: "start_repair_run"
  defp repair_tool_name("repair_runs/get"), do: "get_repair_run"
  defp repair_tool_name("repair_runs/record_artifact"), do: "record_repair_run_artifact"
  defp repair_tool_name("repair_runs/reconcile_prediction"), do: "reconcile_repair_prediction"
  defp repair_tool_name("repair_runs/score_predictions"), do: "score_repair_predictions"
  defp repair_tool_name("repair_runs/choose_strategy"), do: "choose_repair_strategy"

  defp repair_tool_name("repair_runs/draft_architecture_plan"),
    do: "draft_repair_architecture_plan"

  defp repair_tool_name("repair_runs/draft_blast_radius"), do: "draft_repair_blast_radius"

  defp repair_tool_name("repair_runs/draft_original_issue_check"),
    do: "draft_repair_original_issue_check"

  defp repair_tool_name("repair_runs/execute_original_issue_check"),
    do: "execute_repair_original_issue_check"

  defp repair_tool_name("repair_runs/execute_impact_check"), do: "execute_repair_impact_check"

  defp repair_tool_name("repair_runs/draft_related_issue_sweep"),
    do: "draft_repair_related_issue_sweep"

  defp repair_tool_name("repair_runs/begin_implementation"), do: "begin_repair_implementation"
  defp repair_tool_name("repair_runs/approve_gate"), do: "approve_repair_gate"
  defp repair_tool_name("repair_runs/complete"), do: "complete_repair_run"
  defp repair_tool_name(method), do: method

  defp local_ui_tool_name("core/ask_user_question"), do: "ask_user_question"
  defp local_ui_tool_name("core/delegate_to_agent"), do: "delegate_to_agent"
  defp local_ui_tool_name("core/set_page_title"), do: "set_page_title"
  defp local_ui_tool_name("pages/create"), do: "create_page"
  defp local_ui_tool_name("documents/write"), do: "write_to_document"
  defp local_ui_tool_name(method), do: method

  defp maybe_put(map, _key, value) when value in [nil, "", []], do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_opt(opts, _key, value) when value in [nil, ""], do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
