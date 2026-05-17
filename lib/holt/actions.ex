defmodule Holt.Actions do
  @moduledoc """
  Executable action registry for local Holt providers.

  This module is the boundary between declared tool metadata and actual local
  execution. Task actions are always routed through the task tool router before
  dispatch, and workspace actions keep using the existing `Holt.Tools`
  approval policy.
  """

  alias Holt.{Clock, Pages, Tools}
  alias Holt.Actions.{ProviderRegistry, ToolCatalog}

  alias Holt.Tasks.{
    ActionContract,
    RuntimeContracts,
    TaskToolRouter,
    TaskToolSession
  }

  @definition_schema "holtworks_action_definition/v1"
  @execution_schema "holtworks_action_execution/v1"
  @tool_schema "holtworks_tool_schema/v1"
  @safe_routed_scopes ~w(read_only session_ephemeral)

  def definitions(opts \\ []) do
    session = option(opts, :task_tool_session) || TaskToolSession.build(%{})

    TaskToolSession.direct_tool_names()
    |> Kernel.++(TaskToolSession.meta_tool_names())
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&definition(&1, session))
  end

  def get(name, opts \\ []) do
    normalized = normalize_tool_name(name)
    Enum.find(definitions(opts), &(&1["name"] == normalized))
  end

  def search(filters \\ %{}, opts \\ []) do
    filters = RuntimeContracts.string_keys(filters)
    names = RuntimeContracts.normalize_string_list(RuntimeContracts.value(filters, "names"))

    providers =
      RuntimeContracts.normalize_string_list(RuntimeContracts.value(filters, "providers"))

    toolkits = RuntimeContracts.normalize_string_list(RuntimeContracts.value(filters, "toolkits"))

    effect_scopes =
      RuntimeContracts.normalize_string_list(RuntimeContracts.value(filters, "effect_scopes"))

    definitions(opts)
    |> filter_exact("name", names)
    |> filter_exact("provider", providers)
    |> filter_exact("toolkit", toolkits)
    |> filter_exact("effect_scope", effect_scopes)
  end

  def agent_tool_catalog(context \\ %{}, opts \\ []) do
    {context, opts} = normalize_catalog_args(context, opts)

    context
    |> catalog_definitions(opts)
    |> ToolCatalog.action_entries(context, "agent", opts)
  end

  def tool_catalog(context \\ %{}, opts \\ []) do
    agent_tool_catalog(context, opts)
  end

  def mcp_tool_catalog(context \\ %{}, opts \\ []) do
    {context, opts} = normalize_catalog_args(context, opts)

    context
    |> catalog_definitions(opts)
    |> ToolCatalog.action_entries(context, "mcp", opts)
  end

  def agent_tool_definitions(context \\ %{}, opts \\ []) do
    context
    |> agent_tool_catalog(opts)
    |> ToolCatalog.openai_tools()
  end

  def mcp_tool_definitions(context \\ %{}, opts \\ []) do
    context
    |> mcp_tool_catalog(opts)
    |> ToolCatalog.mcp_tools()
  end

  def action_providers(context \\ %{}, opts \\ []) do
    {context, opts} = normalize_catalog_args(context, opts)
    ProviderRegistry.for_context(context, opts)
  end

  def action_provider_ids(context \\ %{}, opts \\ []) do
    context
    |> action_providers(opts)
    |> Enum.map(& &1["id"])
    |> Enum.sort()
  end

  def tool_provider_metadata(context \\ %{}, opts \\ []) do
    {context, opts} = normalize_catalog_args(context, opts)

    context
    |> catalog_definitions(opts)
    |> ProviderRegistry.metadata(context, opts)
  end

  def action_provider_prompt_sections(context \\ %{}, opts \\ []) do
    {context, opts} = normalize_catalog_args(context, opts)
    ProviderRegistry.prompt_sections(context, opts)
  end

  def dispatch_agent_tool(tool_name, params, context \\ %{}, opts \\ [])

  def dispatch_agent_tool(tool_name, params, context, opts)
      when is_binary(tool_name) and is_map(params) do
    {context, opts} = normalize_catalog_args(context, opts)

    case ToolCatalog.find_entry(agent_tool_catalog(context, opts), tool_name) do
      {:ok, entry} ->
        params =
          params
          |> RuntimeContracts.string_keys()
          |> maybe_put_context_task_ref(context)

        execute(entry["action_name"], params, opts)

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  def dispatch_agent_tool(_tool_name, _params, _context, _opts), do: {:error, :not_found}

  def execute(name, args \\ %{}, opts \\ [])

  def execute(name, args, opts) when is_map(args) do
    args = RuntimeContracts.string_keys(args)
    tool_name = normalize_tool_name(name)

    cond do
      is_nil(tool_name) ->
        {:error, failed_execution(nil, args, nil, :tool_name_required)}

      repair_tool?(tool_name) ->
        execute_workspace_action(tool_name, args, opts)

      workspace_tool?(tool_name) and task_ref(args) in [nil, ""] ->
        execute_workspace_action(tool_name, args, opts)

      tool_name == "list_tasks" and task_ref(args) in [nil, ""] ->
        route_and_dispatch(nil, tool_name, args, opts)

      tool_name == "create_task" and task_ref(args) in [nil, ""] ->
        route_and_dispatch(nil, tool_name, args, opts)

      tool_name == "watchdog_agent_runs" and task_ref(args) in [nil, ""] ->
        route_and_dispatch(nil, tool_name, args, opts)

      tool_name == "capability_registry" and task_ref(args) in [nil, ""] ->
        route_and_dispatch(nil, tool_name, args, opts)

      tool_name in ["manage_connection", "use_workbench"] and task_ref(args) in [nil, ""] ->
        route_and_dispatch(nil, tool_name, args, opts)

      true ->
        case task_ref(args) do
          nil -> {:error, failed_execution(tool_name, args, nil, :task_ref_required)}
          ref -> execute_task_tool(ref, tool_name, drop_ref_args(args), opts)
        end
    end
  end

  def execute(_name, _args, _opts), do: {:error, :invalid_action_arguments}

  def execute_task_tool(ref_or_id, tool_name, args \\ %{}, opts \\ [])

  def execute_task_tool(ref_or_id, tool_name, args, opts) when is_map(args) do
    args = RuntimeContracts.string_keys(args)
    route_and_dispatch(ref_or_id, normalize_tool_name(tool_name), args, opts)
  end

  def execute_task_tool(_ref_or_id, _tool_name, _args, _opts),
    do: {:error, :invalid_action_arguments}

  def execute_many(ref_or_id, calls, opts \\ [])

  def execute_many(ref_or_id, calls, opts) when is_list(calls) do
    calls
    |> Enum.reduce_while({:ok, []}, fn call, {:ok, executions} ->
      call = RuntimeContracts.string_keys(call)
      tool_name = RuntimeContracts.text(call, "tool_name", RuntimeContracts.text(call, "name"))
      args = RuntimeContracts.normalize_map(RuntimeContracts.value(call, "arguments"))

      case execute_task_tool(ref_or_id, tool_name, args, opts) do
        {:ok, execution} ->
          {:cont, {:ok, [execution | executions]}}

        {:error, %{} = execution} ->
          {:halt, {:error, Enum.reverse([execution | executions])}}

        {:error, reason} ->
          {:halt,
           {:error, Enum.reverse([failed_execution(tool_name, args, nil, reason) | executions])}}
      end
    end)
    |> case do
      {:ok, executions} -> {:ok, Enum.reverse(executions)}
      error -> error
    end
  end

  def execute_many(_ref_or_id, _calls, _opts), do: {:error, :invalid_action_batch}

  defp definition(tool_name, session) do
    effect_scope = ActionContract.effect_scope(tool_name)
    tool = Tools.get(tool_name) || %{}

    %{
      "schema_version" => @definition_schema,
      "name" => tool_name,
      "description" => description(tool_name, tool),
      "provider" => provider(tool_name, effect_scope),
      "toolkit" => toolkit(tool_name, effect_scope),
      "effect_scope" => effect_scope,
      "risk_level" => risk_level(tool, effect_scope),
      "requires_approval" =>
        ActionContract.requires_approval?(%{
          "effect_scope" => effect_scope,
          "risk_level" => risk_level(tool, effect_scope)
        }),
      "requires_task_ref" => requires_task_ref?(tool_name, effect_scope),
      "arguments_schema" => arguments_schema(tool_name),
      "availability" => availability(tool_name, session),
      "source" => "builtin"
    }
    |> RuntimeContracts.reject_empty()
  end

  defp filter_exact(definitions, _field, []), do: definitions

  defp filter_exact(definitions, field, values) do
    allowed = MapSet.new(values)
    Enum.filter(definitions, &MapSet.member?(allowed, Map.get(&1, field)))
  end

  defp availability(tool_name, session) do
    %{
      "route_status" =>
        if(TaskToolRouter.allowed?(tool_name, session), do: "accepted", else: "unavailable"),
      "declared_in_session" =>
        tool_name in (session["direct_tools"] || []) or tool_name in meta_tool_names(session)
    }
  end

  defp meta_tool_names(session) do
    session
    |> Map.get("meta_tools", [])
    |> Enum.map(fn
      %{"name" => name} -> name
      _tool -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp catalog_definitions(context, opts) do
    context = RuntimeContracts.string_keys(context || %{})

    session =
      case RuntimeContracts.value(context, "task_tool_session") || opts[:task_tool_session] do
        session when is_map(session) -> RuntimeContracts.string_keys(session)
        _missing -> TaskToolSession.build(context)
      end

    definitions(Keyword.put(opts, :task_tool_session, session))
  end

  defp normalize_catalog_args(context, opts) when is_list(context) and opts == [] do
    {%{}, context}
  end

  defp normalize_catalog_args(context, opts) do
    {RuntimeContracts.string_keys(context || %{}), opts}
  end

  defp maybe_put_context_task_ref(params, context) do
    context_ref =
      RuntimeContracts.text(context, "ref") ||
        RuntimeContracts.text(context, "task_ref") ||
        RuntimeContracts.text(context, "task_id")

    cond do
      task_ref(params) not in [nil, ""] ->
        params

      context_ref in [nil, ""] ->
        params

      true ->
        Map.put(params, "ref", context_ref)
    end
  end

  defp execute_workspace_action(tool_name, args, opts) do
    route = TaskToolRouter.route(%{"tool_name" => tool_name, "arguments" => args})

    case Tools.execute(tool_name, args, opts) do
      {:ok, result} -> {:ok, completed_execution(tool_name, args, route, result)}
      {:error, reason} -> {:error, failed_execution(tool_name, args, route, reason)}
    end
  end

  defp route_and_dispatch(ref_or_id, tool_name, args, opts) do
    with {:ok, route} <- route_action(ref_or_id, tool_name, args, opts),
         :ok <- ensure_route_accepted(route),
         {:ok, result} <- dispatch(ref_or_id, tool_name, args, opts) do
      {:ok, completed_execution(tool_name, args, route, result)}
    else
      {:rejected, route} ->
        {:error, rejected_execution(tool_name, args, route)}

      {:error, %{} = execution} ->
        {:error, execution}

      {:error, reason} ->
        route =
          case route_action(ref_or_id, tool_name, args, opts) do
            {:ok, route} -> route
            _other -> nil
          end

        {:error, failed_execution(tool_name, args, route, reason)}
    end
  end

  defp route_action(ref_or_id, tool_name, args, opts) do
    attrs =
      args
      |> route_attrs()
      |> Map.put("tool_name", tool_name)
      |> Map.put("arguments", action_arguments(args))
      |> Map.put_new("tool_call_id", Clock.id("tool_call"))

    if ref_or_id in [nil, ""] do
      {:ok, TaskToolRouter.route(attrs)}
    else
      Holt.Tasks.route_task_tool(ref_or_id, attrs, opts)
    end
  end

  defp ensure_route_accepted(%{"status" => "accepted"}), do: :ok
  defp ensure_route_accepted(route), do: {:rejected, route}

  defp dispatch(_ref, "list_tasks", args, opts) do
    {:ok, Holt.Tasks.list(task_list_opts(args, opts))}
  end

  defp dispatch(_ref, "create_task", args, opts),
    do: Holt.Tasks.create(action_arguments(args), opts)

  defp dispatch(ref, "get_task", _args, opts), do: Holt.Tasks.get(ref, opts)

  defp dispatch(ref, "update_task", args, opts),
    do: Holt.Tasks.update(ref, action_arguments(args), opts)

  defp dispatch(ref, "set_priority", args, opts) do
    with {:ok, priority} <- required_any(args, ["priority"]) do
      Holt.Tasks.set_priority(ref, priority, opts)
    end
  end

  defp dispatch(ref, "set_estimate", args, opts) do
    with {:ok, estimate} <- required_any(args, ["estimate"]) do
      Holt.Tasks.set_estimate(ref, estimate, opts)
    end
  end

  defp dispatch(_ref, "todo_read", args, _opts) do
    {:ok, todo_read_state(args)}
  end

  defp dispatch(_ref, "todo_write", args, _opts) do
    with {:ok, todos} <- todo_write_todos(args) do
      {:ok, todo_state(todos, "updated")}
    end
  end

  defp dispatch(ref, "add_comment", args, opts) do
    with {:ok, body} <- required_any(args, ["body", "comment", "text", "content"]) do
      Holt.Tasks.add_comment(ref, body, opts)
    end
  end

  defp dispatch(ref, "delete_comment", args, opts) do
    with {:ok, comment_id} <- required_any(args, ["comment_id", "id"]) do
      Holt.Tasks.delete_comment(ref, comment_id, opts)
    end
  end

  defp dispatch(ref, "add_label", args, opts) do
    label_args =
      args
      |> action_arguments()
      |> maybe_put_from(args, "name", ["name", "label"])

    Holt.Tasks.add_label(ref, label_args, opts)
  end

  defp dispatch(ref, "remove_label", args, opts) do
    with {:ok, name} <- required_any(args, ["name", "label"]) do
      Holt.Tasks.remove_label(ref, name, opts)
    end
  end

  defp dispatch(ref, "add_link", args, opts) do
    with {:ok, target_ref} <-
           required_any(args, ["target_ref", "target_task_id", "target_id", "target"]),
         type = RuntimeContracts.text(args, "type", "relates_to") do
      Holt.Tasks.add_link(ref, target_ref, type, opts)
    end
  end

  defp dispatch(ref, "remove_link", args, opts) do
    with {:ok, link_id} <- required_any(args, ["link_id", "id"]) do
      Holt.Tasks.remove_link(ref, link_id, opts)
    end
  end

  defp dispatch(ref, "list_task_specs", args, opts) do
    Holt.Tasks.list_specs(ref, spec_opts(args, opts))
  end

  defp dispatch(_ref, "get_task_spec", args, opts) do
    with {:ok, spec_id} <- required_any(args, ["spec_id", "id"]) do
      Holt.Tasks.get_spec(spec_id, spec_opts(args, opts))
    end
  end

  defp dispatch(ref, "save_task_spec", args, opts),
    do: Holt.Tasks.save_spec(ref, action_arguments(args), opts)

  defp dispatch(_ref, "read_task_memory_artifact", args, opts) do
    with {:ok, artifact_ref} <- required_any(args, ["artifact_ref", "spec_id", "id"]) do
      Holt.Tasks.read_memory_artifact(artifact_ref, opts)
    end
  end

  defp dispatch(ref, "save_teammate_memory", args, opts),
    do: Holt.Tasks.save_teammate_memory(ref, action_arguments(args), opts)

  defp dispatch(ref, "load_teammate_runtime", args, opts),
    do: Holt.Tasks.load_teammate_runtime(ref, teammate_runtime_opts(args, opts))

  defp dispatch(ref, "record_task_memory_artifact", args, opts),
    do: Holt.Tasks.record_task_memory_artifact(ref, action_arguments(args), opts)

  defp dispatch(ref, "task_memory_context", args, opts),
    do: Holt.Tasks.task_memory_context(ref, action_arguments(args), opts)

  defp dispatch(ref, "context_budget", args, opts),
    do: Holt.Tasks.context_budget(ref, action_arguments(args), opts)

  defp dispatch(ref, "continuation_packet", args, opts),
    do: Holt.Tasks.continuation_packet(ref, action_arguments(args), opts)

  defp dispatch(ref, "verifier_calibration", args, opts),
    do: Holt.Tasks.verifier_calibration(ref, action_arguments(args), opts)

  defp dispatch(ref, "start_agent_work", args, opts),
    do: Holt.Tasks.start_agent_work(ref, action_arguments(args), opts)

  defp dispatch(ref, "continue_agent_work", args, opts),
    do: Holt.Tasks.continue_agent_work(ref, action_arguments(args), opts)

  defp dispatch(_ref, "watchdog_agent_runs", args, opts) do
    {:ok, Holt.Tasks.watchdog_scan(watchdog_opts(args, opts))}
  end

  defp dispatch(ref, "create_task_graph", args, opts),
    do: Holt.Tasks.create_task_graph(ref, action_arguments(args), opts)

  defp dispatch(ref, "list_task_graphs", _args, opts), do: Holt.Tasks.task_graphs(ref, opts)

  defp dispatch(_ref, "get_task_graph", args, opts) do
    with {:ok, graph_id} <- required_any(args, ["graph_id", "task_graph_id", "id"]) do
      Holt.Tasks.get_task_graph(graph_id, opts)
    end
  end

  defp dispatch(_ref, "advance_task_graph", args, opts) do
    with {:ok, graph_id} <- required_any(args, ["graph_id", "task_graph_id", "id"]) do
      Holt.Tasks.advance_task_graph(
        graph_id,
        Map.drop(action_arguments(args), ["graph_id", "task_graph_id", "id"]),
        opts
      )
    end
  end

  defp dispatch(_ref, "complete_task_graph_node", args, opts) do
    with {:ok, graph_id} <- required_any(args, ["graph_id", "task_graph_id", "id"]),
         {:ok, node_ref} <- required_any(args, ["node_ref", "node_id", "node_key"]) do
      Holt.Tasks.complete_task_graph_node(
        graph_id,
        node_ref,
        Map.drop(action_arguments(args), [
          "graph_id",
          "task_graph_id",
          "id",
          "node_ref",
          "node_id",
          "node_key"
        ]),
        opts
      )
    end
  end

  defp dispatch(ref, "work_graph_budget", args, opts),
    do: Holt.Tasks.work_graph_budget(ref, action_arguments(args), opts)

  defp dispatch(ref, "agent_dispatch_plan", args, opts),
    do: Holt.Tasks.agent_dispatch_plan(ref, action_arguments(args), opts)

  defp dispatch(ref, "team_orchestration", args, opts),
    do: Holt.Tasks.team_orchestration(ref, action_arguments(args), opts)

  defp dispatch(ref, "child_agent_contract", args, opts),
    do: Holt.Tasks.child_agent_contract(ref, action_arguments(args), opts)

  defp dispatch(ref, "verifier_dispatch", args, opts),
    do: Holt.Tasks.verifier_dispatch(ref, action_arguments(args), opts)

  defp dispatch(ref, "route_verification_review", args, opts),
    do: Holt.Tasks.route_verification(ref, verification_args(args), opts)

  defp dispatch(ref, "get_evidence_contract", args, opts),
    do: Holt.Tasks.evidence_contract(ref, action_arguments(args), opts)

  defp dispatch(ref, "plan_verifier_route", args, opts),
    do: Holt.Tasks.plan_verifier_route(ref, action_arguments(args), opts)

  defp dispatch(ref, "work_graph", args, opts),
    do: Holt.Tasks.work_graph(ref, action_arguments(args), opts)

  defp dispatch(ref, "work_graph_gate", args, opts),
    do: Holt.Tasks.work_graph_gate(ref, action_arguments(args), opts)

  defp dispatch(ref, "work_graph_schedule", args, opts),
    do: Holt.Tasks.work_graph_schedule(ref, action_arguments(args), opts)

  defp dispatch(ref, "verification_contract", args, opts),
    do: Holt.Tasks.verification_contract(ref, action_arguments(args), opts)

  defp dispatch(ref, "verifier_assignment", args, opts),
    do: Holt.Tasks.verifier_assignment(ref, action_arguments(args), opts)

  defp dispatch(ref, "action_contract", args, opts),
    do: Holt.Tasks.action_contract(ref, action_arguments(args), opts)

  defp dispatch(ref, "plan_contract", args, opts),
    do: Holt.Tasks.plan_contract(ref, action_arguments(args), opts)

  defp dispatch(ref, "plan_gate", args, opts),
    do: Holt.Tasks.plan_gate(ref, action_arguments(args), opts)

  defp dispatch(ref, "action_preflight", args, opts),
    do: Holt.Tasks.action_preflight(ref, action_arguments(args), opts)

  defp dispatch(ref, "consequence_gate", args, opts),
    do: Holt.Tasks.consequence_gate(ref, action_arguments(args), opts)

  defp dispatch(ref, "action_runtime_envelope", args, opts),
    do: Holt.Tasks.action_runtime_envelope(ref, action_arguments(args), opts)

  defp dispatch(_ref, "complete_action_runtime_envelope", args, _opts) do
    with {:ok, envelope} <- required_map(args, "envelope") do
      Holt.Tasks.complete_action_runtime_envelope(
        envelope,
        Map.delete(action_arguments(args), "envelope")
      )
    end
  end

  defp dispatch(_ref, "capability_registry", args, _opts) do
    with {:ok, tool_name} <- required_any(args, ["tool_name", "name", "tool"]) do
      Holt.Tasks.capability_registry(tool_name, action_arguments(args))
    end
  end

  defp dispatch(ref, "capability_contract", args, opts),
    do: Holt.Tasks.capability_contract(ref, action_arguments(args), opts)

  defp dispatch(ref, "capability_route", args, opts),
    do: Holt.Tasks.capability_route(ref, action_arguments(args), opts)

  defp dispatch(ref, "generic_plan", args, opts),
    do: Holt.Tasks.generic_plan(ref, action_arguments(args), opts)

  defp dispatch(ref, "action_approval_request", args, opts),
    do: Holt.Tasks.action_approval_request(ref, action_arguments(args), opts)

  defp dispatch(_ref, "resolve_action_approval_request", args, opts) do
    with {:ok, request_id} <- required_any(args, ["approval_request_id", "request_id", "id"]) do
      Holt.Tasks.resolve_action_approval_request(
        request_id,
        Map.drop(action_arguments(args), ["approval_request_id", "request_id", "id"]),
        opts
      )
    end
  end

  defp dispatch(ref, "action_evidence_ledger", args, opts),
    do: Holt.Tasks.action_evidence_ledger(ref, action_arguments(args), opts)

  defp dispatch(_ref, "search_tools", args, opts) do
    {:ok, %{"actions" => search(action_arguments(args), opts)}}
  end

  defp dispatch(_ref, "get_tool_schema", args, opts) do
    with {:ok, tool_name} <- required_any(args, ["tool_name", "name", "tool"]) do
      case get(tool_name, opts) do
        nil -> {:error, :unknown_tool}
        action -> {:ok, %{"schema_version" => @tool_schema, "action" => action}}
      end
    end
  end

  defp dispatch(_ref, "manage_connection", args, _opts) do
    {:ok, connection_management_state(args)}
  end

  defp dispatch(ref, "use_workbench", args, opts) do
    session = session_from_args(args)
    workbench = RuntimeContracts.normalize_map(session["workbench"])
    action_args = action_arguments(args)

    tool_name =
      RuntimeContracts.text(
        args,
        "tool_name",
        RuntimeContracts.text(
          action_args,
          "tool_name",
          RuntimeContracts.text(action_args, "name")
        )
      )

    tool_args = workbench_tool_args(action_args)

    cond do
      workbench["enabled"] != true ->
        {:error, :workbench_disabled}

      tool_name in [nil, ""] ->
        {:ok, workbench_state(session, "available")}

      true ->
        case execute_safe_nested_tool(ref, tool_name, tool_args, opts) do
          {:ok, execution} ->
            {:ok,
             session
             |> workbench_state("executed")
             |> Map.put("tool_execution", execution)}

          error ->
            error
        end
    end
  end

  defp dispatch(ref, "execute_tool", args, opts) do
    with {:ok, nested_tool} <- required_any(args, ["tool_name", "name", "tool"]) do
      nested_args = RuntimeContracts.normalize_map(RuntimeContracts.value(args, "arguments"))
      execute_safe_nested_tool(ref, nested_tool, nested_args, opts)
    end
  end

  defp dispatch(ref, "multi_execute_tool", args, opts) do
    calls = RuntimeContracts.value(args, "calls") || RuntimeContracts.value(args, "tools")

    with true <- is_list(calls) do
      case execute_safe_nested_many(ref, calls, opts) do
        {:ok, executions} -> {:ok, %{"executions" => executions}}
        {:error, executions} when is_list(executions) -> {:error, failed_batch(executions)}
        {:error, reason} -> {:error, reason}
      end
    else
      _value -> {:error, :invalid_action_batch}
    end
  end

  defp dispatch(_ref, tool_name, args, opts) do
    if workspace_tool?(tool_name) do
      Tools.execute(tool_name, action_arguments(args), opts)
    else
      {:error, :unsupported_action}
    end
  end

  defp execute_safe_nested_many(ref_or_id, calls, opts) when is_list(calls) do
    calls
    |> Enum.reduce_while({:ok, []}, fn call, {:ok, executions} ->
      call = RuntimeContracts.string_keys(call)
      tool_name = RuntimeContracts.text(call, "tool_name", RuntimeContracts.text(call, "name"))
      args = RuntimeContracts.normalize_map(RuntimeContracts.value(call, "arguments"))

      case execute_safe_nested_tool(ref_or_id, tool_name, args, opts) do
        {:ok, execution} ->
          {:cont, {:ok, [execution | executions]}}

        {:error, %{} = execution} ->
          {:halt, {:error, Enum.reverse([execution | executions])}}

        {:error, reason} ->
          {:halt,
           {:error, Enum.reverse([failed_execution(tool_name, args, nil, reason) | executions])}}
      end
    end)
    |> case do
      {:ok, executions} -> {:ok, Enum.reverse(executions)}
      error -> error
    end
  end

  defp execute_safe_nested_many(_ref_or_id, _calls, _opts), do: {:error, :invalid_action_batch}

  defp execute_safe_nested_tool(ref_or_id, tool_name, args, opts) do
    tool_name = normalize_tool_name(tool_name)

    with :ok <- reject_router_recursion(tool_name),
         {:ok, route} <- route_action(ref_or_id, tool_name, args, opts),
         :ok <- ensure_route_accepted(route),
         :ok <- ensure_safe_routed_scope(route) do
      execute_task_tool(ref_or_id, tool_name, args, opts)
    else
      {:rejected, route} -> {:error, rejected_execution(tool_name, args, route)}
      {:error, %{} = execution} -> {:error, execution}
      {:error, reason} -> {:error, failed_execution(tool_name, args, nil, reason)}
    end
  end

  defp reject_router_recursion(tool_name) do
    if tool_name in TaskToolSession.meta_tool_names() do
      {:error, :router_meta_tool_recursion}
    else
      :ok
    end
  end

  defp ensure_safe_routed_scope(route) do
    scope = get_in(route, ["action_contract", "effect_scope"])

    if scope in @safe_routed_scopes do
      :ok
    else
      {:error, {:unsafe_nested_effect_scope, scope || "unknown"}}
    end
  end

  defp completed_execution(tool_name, args, route, result) do
    execution_base(tool_name, args, route)
    |> Map.put("status", "ok")
    |> Map.put("result", result)
  end

  defp rejected_execution(tool_name, args, route) do
    execution_base(tool_name, args, route)
    |> Map.put("status", "rejected")
    |> Map.put("reason", route["reason"])
  end

  defp failed_execution(tool_name, args, route, reason) do
    execution_base(tool_name, args, route)
    |> Map.put("status", "error")
    |> Map.put("reason", normalize_reason(reason))
  end

  defp execution_base(tool_name, args, route) do
    %{
      "schema_version" => @execution_schema,
      "execution_id" => Clock.id("action_execution"),
      "tool_name" => tool_name,
      "tool_call_id" => route_value(route, "tool_call_id"),
      "route" => route,
      "action_contract" => route_value(route, "action_contract"),
      "arguments_preview" =>
        ActionContract.build(%{"tool_name" => tool_name, "arguments" => action_arguments(args)})[
          "arguments_preview"
        ],
      "created_at" => Clock.iso_now()
    }
    |> RuntimeContracts.reject_empty()
  end

  defp failed_batch(executions) do
    %{
      "schema_version" => @execution_schema,
      "execution_id" => Clock.id("action_execution"),
      "tool_name" => "multi_execute_tool",
      "status" => "error",
      "reason" => "batch_stopped",
      "executions" => executions,
      "created_at" => Clock.iso_now()
    }
  end

  defp route_value(route, key) when is_map(route), do: Map.get(route, key)
  defp route_value(_route, _key), do: nil

  defp task_list_opts(args, opts) do
    opts
    |> maybe_put_opt(:status, RuntimeContracts.text(args, "status"))
  end

  defp spec_opts(args, opts) do
    opts
    |> maybe_put_opt(:kind, RuntimeContracts.text(args, "kind"))
    |> maybe_put_opt(:include_content, RuntimeContracts.value(args, "include_content"))
    |> maybe_put_opt(:content_limit, RuntimeContracts.value(args, "content_limit"))
    |> maybe_put_opt(
      :task_ref,
      RuntimeContracts.text(
        args,
        "ref",
        RuntimeContracts.text(args, "task_ref", RuntimeContracts.text(args, "task_id"))
      )
    )
  end

  defp teammate_runtime_opts(args, opts) do
    opts
    |> maybe_put_opt(:content_limit, RuntimeContracts.value(args, "content_limit"))
    |> maybe_put_opt(:comment_limit, RuntimeContracts.value(args, "comment_limit"))
  end

  defp watchdog_opts(args, opts) do
    opts
    |> maybe_put_opt(:limit, RuntimeContracts.value(args, "limit"))
    |> maybe_put_opt(:stale_after_seconds, RuntimeContracts.value(args, "stale_after_seconds"))
    |> maybe_put_opt(
      :recovery_cooldown_seconds,
      RuntimeContracts.value(args, "recovery_cooldown_seconds")
    )
  end

  defp connection_management_state(args) do
    session = session_from_args(args)
    action_args = action_arguments(args)
    action = RuntimeContracts.text(action_args, "action", "list")
    toolkit = RuntimeContracts.text(action_args, "toolkit")
    accounts = RuntimeContracts.normalize_map(session["connected_accounts"])

    %{
      "schema_version" => "holtworks_task_connection_management/v1",
      "tool_session_id" => session["session_id"],
      "action" => action,
      "toolkit" => toolkit,
      "connected_accounts" => filter_connected_accounts(accounts, toolkit),
      "enabled_toolkits" => session["enabled_toolkits"] || [],
      "status" => connection_management_status(action)
    }
    |> RuntimeContracts.reject_empty()
  end

  defp filter_connected_accounts(accounts, nil), do: accounts
  defp filter_connected_accounts(accounts, ""), do: accounts

  defp filter_connected_accounts(accounts, toolkit) do
    case Map.get(accounts, toolkit) do
      nil -> %{}
      account -> %{toolkit => account}
    end
  end

  defp connection_management_status(action) when action in ["list", "inspect"], do: "listed"
  defp connection_management_status("request"), do: "requires_user_initiated_connection_flow"
  defp connection_management_status("repair"), do: "requires_user_initiated_connection_flow"
  defp connection_management_status(_action), do: "unsupported_action"

  defp workbench_state(session, status) do
    %{
      "schema_version" => "holtworks_task_workbench/v1",
      "tool_session_id" => session["session_id"],
      "workbench" => session["workbench"] || %{},
      "status" => status,
      "message" => workbench_message(status)
    }
  end

  defp workbench_message("available"),
    do:
      "Provide tool_name and arguments to route a read-only or session-ephemeral workbench action."

  defp workbench_message("executed"),
    do: "Workbench action executed through the task tool router."

  defp workbench_message(_status), do: nil

  defp workbench_tool_args(action_args) do
    case RuntimeContracts.value(action_args, "arguments") do
      arguments when is_map(arguments) ->
        RuntimeContracts.string_keys(arguments)

      _value ->
        Map.drop(action_args, ["tool_name", "name", "tool"])
    end
  end

  defp session_from_args(args) do
    case RuntimeContracts.value(args, "task_tool_session") ||
           RuntimeContracts.value(args, "session") do
      session when is_map(session) -> TaskToolSession.build(session)
      _missing -> TaskToolSession.build(args)
    end
  end

  defp todo_read_state(args) do
    args
    |> todo_read_source()
    |> normalize_read_todos()
    |> todo_state("read")
  end

  defp todo_state(todos, action) do
    %{
      "schema_version" => "holtworks_todo_state/v1",
      "action" => action,
      "status" => if(action == "read", do: "read", else: "updated"),
      "count" => length(todos),
      "text" => format_todos(todos),
      "todos" => todos
    }
  end

  defp todo_read_source(args) do
    action_args = action_arguments(args)

    cond do
      is_list(RuntimeContracts.value(action_args, "todos")) ->
        RuntimeContracts.value(action_args, "todos")

      is_list(RuntimeContracts.value(action_args, "items")) ->
        RuntimeContracts.value(action_args, "items")

      RuntimeContracts.text(action_args, "content") not in [nil, ""] ->
        [action_args]

      RuntimeContracts.text(action_args, "todo") not in [nil, ""] ->
        [Map.put(action_args, "content", RuntimeContracts.text(action_args, "todo"))]

      is_list(get_in(args, ["task_tool_session", "todos"])) ->
        get_in(args, ["task_tool_session", "todos"])

      is_list(get_in(args, ["session", "todos"])) ->
        get_in(args, ["session", "todos"])

      true ->
        []
    end
  end

  defp todo_write_todos(args) do
    action_args = action_arguments(args)

    case RuntimeContracts.value(action_args, "todos") do
      nil -> {:error, "todos is required."}
      todos when is_list(todos) -> normalize_write_todos(todos)
      _value -> {:error, "todos must be an array."}
    end
  end

  defp normalize_read_todos(value) when is_list(value) do
    value
    |> Enum.map(&normalize_read_todo/1)
    |> Enum.reject(&(&1 == %{}))
  end

  defp normalize_read_todos(_value), do: []

  defp normalize_read_todo(value) when is_map(value) do
    todo = RuntimeContracts.string_keys(value)
    content = RuntimeContracts.text(todo, "content")

    if content in [nil, ""] do
      %{}
    else
      active_form =
        RuntimeContracts.text(
          todo,
          "activeForm",
          RuntimeContracts.text(todo, "active_form", content)
        )

      %{
        "content" => content,
        "status" => todo_status(RuntimeContracts.text(todo, "status", "pending")),
        "activeForm" => active_form,
        "active_form" => active_form
      }
      |> RuntimeContracts.reject_empty()
    end
  end

  defp normalize_read_todo(value) do
    content = value |> to_string() |> String.trim()

    if content == "" do
      %{}
    else
      %{
        "content" => content,
        "status" => "pending",
        "activeForm" => content,
        "active_form" => content
      }
    end
  end

  defp normalize_write_todos(todos) do
    todos
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case normalize_write_todo(item) do
        {:ok, todo} -> {:cont, {:ok, [todo | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_write_todo(value) when is_map(value) do
    todo = RuntimeContracts.string_keys(value)
    content = RuntimeContracts.text(todo, "content")
    status = RuntimeContracts.text(todo, "status", "pending")

    active_form =
      RuntimeContracts.text(
        todo,
        "activeForm",
        RuntimeContracts.text(todo, "active_form", content)
      )

    cond do
      content in [nil, ""] ->
        {:error, "Each todo needs a non-empty `content` string."}

      status not in ["pending", "in_progress", "completed"] ->
        {:error, "Invalid todo status #{inspect(status)}."}

      true ->
        {:ok,
         %{
           "content" => content,
           "status" => status,
           "activeForm" => active_form,
           "active_form" => active_form
         }}
    end
  end

  defp normalize_write_todo(_value), do: {:error, "Each todo must be an object."}

  defp format_todos([]), do: "(no todos)"

  defp format_todos(todos) do
    Enum.map_join(todos, "\n", fn todo ->
      "- #{todo_status_marker(todo["status"])} #{todo["content"]}"
    end)
  end

  defp todo_status_marker("completed"), do: "[x]"
  defp todo_status_marker("in_progress"), do: "[~]"
  defp todo_status_marker(_status), do: "[ ]"

  defp todo_status(status) when status in ["pending", "in_progress", "completed"], do: status
  defp todo_status(_status), do: "pending"

  defp verification_args(args) do
    args
    |> action_arguments()
    |> normalize_checks_argument()
  end

  defp normalize_checks_argument(%{"check" => check} = args) do
    Map.put(args, "checks", List.wrap(check))
  end

  defp normalize_checks_argument(args), do: args

  defp route_attrs(args) do
    Map.take(args, [
      "task_tool_session",
      "session",
      "session_id",
      "agent_id",
      "agent_ref",
      "agent_handle",
      "agent_name",
      "run_id",
      "agent_run_id",
      "graph_id",
      "task_graph_id",
      "policy_profile",
      "enabled_toolkits",
      "disabled_toolkits",
      "disabled_tools",
      "direct_tools",
      "preload_tools",
      "connected_accounts",
      "workbench",
      "todos",
      "source"
    ])
  end

  defp action_arguments(args) do
    case RuntimeContracts.value(args, "arguments") do
      value when is_map(value) ->
        RuntimeContracts.string_keys(value)

      _value ->
        Map.drop(args, [
          "task_tool_session",
          "session",
          "session_id",
          "agent_id",
          "agent_ref",
          "agent_handle",
          "agent_name",
          "run_id",
          "agent_run_id",
          "policy_profile",
          "enabled_toolkits",
          "disabled_toolkits",
          "disabled_tools",
          "direct_tools",
          "preload_tools",
          "connected_accounts",
          "workbench",
          "source"
        ])
    end
  end

  defp maybe_put_from(map, source, target_key, source_keys) do
    if RuntimeContracts.text(map, target_key) do
      map
    else
      case required_any(source, source_keys) do
        {:ok, value} -> Map.put(map, target_key, value)
        {:error, _reason} -> map
      end
    end
  end

  defp required_any(map, keys) do
    keys
    |> Enum.find_value(fn key ->
      case RuntimeContracts.value(map, key) do
        value when is_binary(value) ->
          text = String.trim(value)
          if text == "", do: nil, else: {:ok, text}

        value when is_integer(value) ->
          {:ok, value}

        value when is_float(value) ->
          {:ok, value}

        value when is_map(value) ->
          {:ok, value}

        value when is_list(value) ->
          {:ok, value}

        _value ->
          nil
      end
    end)
    |> case do
      nil -> {:error, {:missing_required, Enum.join(keys, "|")}}
      result -> result
    end
  end

  defp required_map(map, key) do
    case RuntimeContracts.value(map, key) do
      value when is_map(value) -> {:ok, RuntimeContracts.string_keys(value)}
      _value -> {:error, {:missing_required, key}}
    end
  end

  defp normalize_tool_name(nil), do: nil

  defp normalize_tool_name(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp task_ref(args) do
    RuntimeContracts.text(args, "ref") ||
      RuntimeContracts.text(args, "task_ref") ||
      RuntimeContracts.text(args, "task_id")
  end

  defp drop_ref_args(args), do: Map.drop(args, ["ref", "task_ref", "task_id"])

  defp workspace_tool?(tool_name), do: not is_nil(Tools.get(tool_name))

  defp repair_tool?(tool_name) do
    tool_name in ~w(start_repair_run get_repair_run record_repair_run_artifact reconcile_repair_prediction score_repair_predictions choose_repair_strategy draft_repair_architecture_plan draft_repair_blast_radius draft_repair_original_issue_check execute_repair_original_issue_check execute_repair_impact_check draft_repair_related_issue_sweep begin_repair_implementation approve_repair_gate complete_repair_run)
  end

  defp provider(tool_name, effect_scope) do
    cond do
      workspace_tool?(tool_name) -> "workspace"
      effect_scope == "agent_orchestration" -> "agent_orchestration"
      effect_scope == "routed" -> "router"
      effect_scope == "read_only" and tool_name == "manage_connection" -> "task_tool_session"
      true -> "tasks"
    end
  end

  defp toolkit(tool_name, effect_scope) do
    cond do
      workspace_tool?(tool_name) -> "workspace"
      effect_scope == "agent_orchestration" -> "agent_orchestration"
      effect_scope == "routed" -> "meta"
      tool_name == "manage_connection" -> "meta"
      effect_scope == "session_ephemeral" -> "session"
      effect_scope == "read_only" -> "task"
      effect_scope == "task_durable" -> "task"
      true -> "verification"
    end
  end

  defp description(_tool_name, %{"description" => description}), do: description
  defp description("search_tools", _tool), do: "Find available actions for a task session."

  defp description("get_tool_schema", _tool),
    do: "Return structured metadata for one executable action."

  defp description("execute_tool", _tool),
    do: "Execute one read-only or session-ephemeral routed task action."

  defp description("multi_execute_tool", _tool),
    do: "Execute an ordered batch of read-only or session-ephemeral routed task actions."

  defp description("todo_read", _tool), do: "Read the current in-session todo list."
  defp description("todo_write", _tool), do: "Replace the in-session todo list."

  defp description("manage_connection", _tool),
    do: "Inspect connected-account context declared for the task session."

  defp description("use_workbench", _tool),
    do: "Inspect the local workbench or route a safe workbench action."

  defp description(tool_name, _tool),
    do: "Execute #{tool_name} through the local Holt provider."

  defp risk_level(%{"risk" => "read"}, _effect_scope), do: "low"
  defp risk_level(%{"risk" => "write"}, _effect_scope), do: "medium"
  defp risk_level(%{"risk" => "execute"}, _effect_scope), do: "high"
  defp risk_level(%{"risk" => "network"}, _effect_scope), do: "high"
  defp risk_level(_tool, "read_only"), do: "low"
  defp risk_level(_tool, "session_ephemeral"), do: "low"
  defp risk_level(_tool, "task_durable"), do: "medium"
  defp risk_level(_tool, "agent_orchestration"), do: "medium"
  defp risk_level(_tool, "workspace_durable"), do: "high"
  defp risk_level(_tool, "external_side_effect"), do: "high"
  defp risk_level(_tool, "routed"), do: "medium"
  defp risk_level(_tool, _effect_scope), do: "unknown"

  defp requires_task_ref?("list_tasks", _effect_scope), do: false
  defp requires_task_ref?("create_task", _effect_scope), do: false
  defp requires_task_ref?("watchdog_agent_runs", _effect_scope), do: false
  defp requires_task_ref?("capability_registry", _effect_scope), do: false
  defp requires_task_ref?("manage_connection", _effect_scope), do: false
  defp requires_task_ref?("use_workbench", _effect_scope), do: false

  defp requires_task_ref?(tool_name, _effect_scope)
       when tool_name in ~w(list_files read_file search_files write_file append_file run_command fetch_url search_web ask_user ask_user_question delegate_to_agent set_page_title create_page write_to_document save_memory search_memory remember_about_user forget_about_user list_user_memories search_user_memory remember_for_project save_plan save_research recall_project_memory read_project_memory list_skills load_skill save_skill update_skill run_skill_script list_agents create_agent update_agent suspend_agent resume_agent delete_agent list_agent_cards get_agent_card list_agent_skills invoke_agent start_repair_run get_repair_run record_repair_run_artifact reconcile_repair_prediction score_repair_predictions choose_repair_strategy draft_repair_architecture_plan draft_repair_blast_radius draft_repair_original_issue_check execute_repair_original_issue_check execute_repair_impact_check draft_repair_related_issue_sweep begin_repair_implementation approve_repair_gate complete_repair_run),
       do: false

  defp requires_task_ref?(_tool_name, _effect_scope), do: true

  defp arguments_schema(tool_name) do
    %{
      "type" => "object",
      "required" => required_arguments(tool_name),
      "properties" => argument_properties(tool_name)
    }
  end

  defp required_arguments("add_comment"), do: ["body"]
  defp required_arguments("create_task"), do: ["title"]
  defp required_arguments("set_priority"), do: ["priority"]
  defp required_arguments("set_estimate"), do: ["estimate"]
  defp required_arguments("delete_comment"), do: ["comment_id"]
  defp required_arguments("add_label"), do: ["name"]
  defp required_arguments("remove_label"), do: ["name"]
  defp required_arguments("add_link"), do: ["target_ref"]
  defp required_arguments("remove_link"), do: ["link_id"]
  defp required_arguments("get_task_spec"), do: ["spec_id"]
  defp required_arguments("read_task_memory_artifact"), do: ["artifact_ref"]
  defp required_arguments("get_task_graph"), do: ["graph_id"]
  defp required_arguments("advance_task_graph"), do: ["graph_id"]
  defp required_arguments("complete_task_graph_node"), do: ["graph_id", "node_ref"]
  defp required_arguments("capability_registry"), do: ["tool_name"]
  defp required_arguments("get_tool_schema"), do: ["tool_name"]
  defp required_arguments("execute_tool"), do: ["tool_name", "arguments"]
  defp required_arguments("multi_execute_tool"), do: ["calls"]
  defp required_arguments("todo_write"), do: ["todos"]
  defp required_arguments("read_file"), do: ["path"]
  defp required_arguments("write_file"), do: ["path", "content"]
  defp required_arguments("append_file"), do: ["path", "content"]
  defp required_arguments("search_files"), do: ["query"]
  defp required_arguments("run_command"), do: ["command"]
  defp required_arguments("fetch_url"), do: ["url"]
  defp required_arguments("search_web"), do: ["query"]
  defp required_arguments("ask_user_question"), do: ["question"]
  defp required_arguments("delegate_to_agent"), do: ["role", "system_prompt", "instructions"]
  defp required_arguments("set_page_title"), do: ["title"]
  defp required_arguments("create_page"), do: ["page_type", "title"]
  defp required_arguments("write_to_document"), do: ["action", "content"]
  defp required_arguments("remember_about_user"), do: ["summary", "category"]
  defp required_arguments("forget_about_user"), do: ["substring"]
  defp required_arguments("search_user_memory"), do: ["query"]
  defp required_arguments("remember_for_project"), do: ["summary", "category"]
  defp required_arguments("save_plan"), do: ["title", "body"]
  defp required_arguments("save_research"), do: ["title", "body"]
  defp required_arguments("read_project_memory"), do: ["id"]
  defp required_arguments("load_skill"), do: ["slug"]
  defp required_arguments("save_skill"), do: ["name", "description", "body"]
  defp required_arguments("update_skill"), do: ["slug"]
  defp required_arguments("run_skill_script"), do: ["skill_slug", "script_name"]
  defp required_arguments("get_agent_card"), do: ["agent_id"]
  defp required_arguments("list_agent_skills"), do: ["agent_id"]
  defp required_arguments("update_agent"), do: ["agent_id"]
  defp required_arguments("suspend_agent"), do: ["agent_id"]
  defp required_arguments("resume_agent"), do: ["agent_id"]
  defp required_arguments("delete_agent"), do: ["agent_id", "confirm"]

  defp required_arguments("invoke_agent"),
    do: ["agent_id", "instructions", "target_skill", "validation_contract"]

  defp required_arguments("get_repair_run"), do: ["repair_run_id"]

  defp required_arguments("record_repair_run_artifact"),
    do: ["repair_run_id", "artifact_type", "payload"]

  defp required_arguments("reconcile_repair_prediction"),
    do: ["repair_run_id", "prediction_id", "observation_id", "matched"]

  defp required_arguments("score_repair_predictions"), do: ["repair_run_id"]
  defp required_arguments("choose_repair_strategy"), do: ["repair_run_id", "strategy"]
  defp required_arguments("draft_repair_architecture_plan"), do: ["repair_run_id"]
  defp required_arguments("draft_repair_blast_radius"), do: ["repair_run_id"]
  defp required_arguments("draft_repair_original_issue_check"), do: ["repair_run_id"]
  defp required_arguments("execute_repair_original_issue_check"), do: ["repair_run_id"]
  defp required_arguments("execute_repair_impact_check"), do: ["repair_run_id"]
  defp required_arguments("draft_repair_related_issue_sweep"), do: ["repair_run_id"]
  defp required_arguments("begin_repair_implementation"), do: ["repair_run_id"]
  defp required_arguments("approve_repair_gate"), do: ["repair_run_id"]
  defp required_arguments("complete_repair_run"), do: ["repair_run_id"]
  defp required_arguments(_tool_name), do: []

  defp argument_properties("start_repair_run") do
    Map.merge(base_argument_properties(), %{
      "task_id" => %{"type" => "string"},
      "agent_run_id" => %{"type" => "string"},
      "project_id" => %{"type" => "string"},
      "space_id" => %{"type" => "string"},
      "risk_level" => %{"type" => "string", "enum" => Holt.RepairRuns.risk_levels()},
      "goal_contract" => %{"type" => "object"}
    })
  end

  defp argument_properties("get_repair_run") do
    Map.merge(base_argument_properties(), repair_run_identifier_properties())
  end

  defp argument_properties("record_repair_run_artifact") do
    base_argument_properties()
    |> Map.merge(repair_run_identifier_properties())
    |> Map.merge(%{
      "artifact_type" => %{"type" => "string", "enum" => Holt.RepairRuns.artifact_types()},
      "payload" => %{"type" => "object"}
    })
  end

  defp argument_properties("reconcile_repair_prediction") do
    base_argument_properties()
    |> Map.merge(repair_run_identifier_properties())
    |> Map.merge(%{
      "prediction_id" => %{"type" => "string"},
      "observation_id" => %{"type" => "string"},
      "matched" => %{"type" => "boolean"},
      "mismatch_reason_code" => %{"type" => "string"},
      "next_decision" => %{"type" => "string", "enum" => Holt.RepairRuns.decisions()}
    })
  end

  defp argument_properties("score_repair_predictions") do
    base_argument_properties()
    |> Map.merge(repair_run_identifier_properties())
    |> Map.merge(%{
      "record" => %{"type" => "boolean"},
      "notes" => %{"type" => "string"}
    })
  end

  defp argument_properties("choose_repair_strategy") do
    base_argument_properties()
    |> Map.merge(repair_run_identifier_properties())
    |> Map.merge(%{
      "strategy" => %{"type" => "string", "enum" => Holt.RepairRuns.strategies()},
      "risk_level" => %{"type" => "string", "enum" => Holt.RepairRuns.risk_levels()},
      "strategy_waiver" => %{"type" => "object"}
    })
  end

  defp argument_properties(tool_name)
       when tool_name in ~w(draft_repair_architecture_plan draft_repair_blast_radius draft_repair_original_issue_check execute_repair_original_issue_check execute_repair_impact_check draft_repair_related_issue_sweep) do
    base_argument_properties()
    |> Map.merge(repair_run_identifier_properties())
    |> Map.merge(%{
      "record" => %{"type" => "boolean"},
      "payload" => %{"type" => "object"},
      "proof_commands" => array_of(%{"type" => "object"}),
      "manual_check_results" => array_of(%{"type" => "object"}),
      "tool_check_results" => array_of(%{"type" => "object"}),
      "goal_check" => %{"type" => "object"},
      "changed_files" => array_of(%{"type" => "string"}),
      "risk_flags" => array_of(%{"type" => "string"}),
      "affected_domains" => array_of(%{"type" => "string"}),
      "protected_flows" => array_of(%{"type" => "string"}),
      "write_scope" => array_of(%{"type" => "string"}),
      "verification_matrix" => array_of(%{"type" => "object"}),
      "impact_waiver" => %{"type" => "object"},
      "notes" => %{"type" => "string"}
    })
  end

  defp argument_properties("begin_repair_implementation") do
    Map.merge(base_argument_properties(), repair_run_identifier_properties())
  end

  defp argument_properties("approve_repair_gate") do
    base_argument_properties()
    |> Map.merge(repair_run_identifier_properties())
    |> Map.merge(%{
      "reason_code" => %{"type" => "string"},
      "approved_by" => %{"type" => "string"}
    })
  end

  defp argument_properties("complete_repair_run") do
    base_argument_properties()
    |> Map.merge(repair_run_identifier_properties())
    |> Map.merge(%{
      "final_report" => %{"type" => "object"}
    })
  end

  defp argument_properties("list_agents") do
    Map.merge(base_argument_properties(), %{
      "status" => %{"type" => "string", "enum" => ["all"] ++ Holt.Agents.statuses()},
      "status_filter" => %{"type" => "string", "enum" => ["all"] ++ Holt.Agents.statuses()}
    })
  end

  defp argument_properties("create_agent") do
    Map.merge(base_argument_properties(), agent_profile_properties())
  end

  defp argument_properties("update_agent") do
    base_argument_properties()
    |> Map.merge(agent_identifier_properties())
    |> Map.merge(agent_profile_properties())
  end

  defp argument_properties(tool_name) when tool_name in ~w(suspend_agent resume_agent) do
    base_argument_properties()
    |> Map.merge(agent_identifier_properties())
    |> Map.merge(%{
      "reason" => %{"type" => "string"}
    })
  end

  defp argument_properties("delete_agent") do
    base_argument_properties()
    |> Map.merge(agent_identifier_properties())
    |> Map.merge(%{
      "confirm" => %{"type" => "boolean"},
      "reason" => %{"type" => "string"}
    })
  end

  defp argument_properties("list_agent_cards") do
    Map.merge(base_argument_properties(), %{
      "status" => %{"type" => "string", "enum" => ["all"] ++ Holt.Agents.statuses()},
      "status_filter" => %{"type" => "string", "enum" => ["all"] ++ Holt.Agents.statuses()}
    })
  end

  defp argument_properties(tool_name) when tool_name in ~w(get_agent_card list_agent_skills) do
    Map.merge(base_argument_properties(), agent_identifier_properties())
  end

  defp argument_properties("invoke_agent") do
    base_argument_properties()
    |> Map.merge(agent_identifier_properties())
    |> Map.merge(%{
      "instructions" => %{"type" => "string"},
      "target_skill" => %{"type" => "string"},
      "work_role" => %{
        "type" => "string",
        "enum" => ["worker", "verifier", "researcher", "critic", "planner", "operator"]
      },
      "input_artifacts" => %{"type" => "array", "items" => %{"type" => "string"}},
      "expected_output_artifacts" => %{"type" => "array", "items" => %{"type" => "string"}},
      "validation_contract" => %{"type" => "string"},
      "handoff_requirements" => %{"type" => "array", "items" => %{"type" => "string"}},
      "allowed_tools" => %{"type" => "array", "items" => %{"type" => "string"}},
      "max_autonomy" => %{
        "type" => "string",
        "enum" => [
          "draft_only",
          "implementation_with_review",
          "autonomous_review",
          "no_external_side_effects"
        ]
      }
    })
  end

  defp argument_properties("ask_user_question") do
    Map.merge(base_argument_properties(), %{
      "question" => %{"type" => "string"},
      "description" => %{"type" => "string"},
      "options" => %{
        "type" => "array",
        "items" => %{
          "type" => "object",
          "properties" => %{
            "label" => %{"type" => "string"},
            "value" => %{"type" => "string"},
            "description" => %{"type" => "string"}
          }
        }
      }
    })
  end

  defp argument_properties("delegate_to_agent") do
    Map.merge(base_argument_properties(), %{
      "role" => %{"type" => "string"},
      "work_role" => %{
        "type" => "string",
        "enum" => ["worker", "verifier", "researcher", "critic", "planner", "operator"]
      },
      "system_prompt" => %{"type" => "string"},
      "instructions" => %{"type" => "string"},
      "page_id" => %{"type" => "string"},
      "target_agent_id" => %{"type" => "string"},
      "target_skill" => %{"type" => "string"},
      "input_artifacts" => %{"type" => "array", "items" => %{"type" => "string"}},
      "expected_output_artifacts" => %{"type" => "array", "items" => %{"type" => "string"}},
      "validation_contract" => %{"type" => "string"},
      "parent_task_id" => %{"type" => "string"},
      "handoff_requirements" => %{"type" => "array", "items" => %{"type" => "string"}},
      "allowed_tools" => %{"type" => "array", "items" => %{"type" => "string"}},
      "max_autonomy" => %{
        "type" => "string",
        "enum" => [
          "draft_only",
          "implementation_with_review",
          "autonomous_review",
          "no_external_side_effects"
        ]
      }
    })
  end

  defp argument_properties("set_page_title") do
    Map.merge(base_argument_properties(), page_identifier_properties())
    |> Map.merge(%{
      "title" => %{"type" => "string"}
    })
  end

  defp argument_properties("create_page") do
    Map.merge(base_argument_properties(), %{
      "page_type" => %{"type" => "string", "enum" => Pages.page_types()},
      "title" => %{"type" => "string"},
      "content" => %{"type" => "string"},
      "project_id" => %{"type" => "string"}
    })
  end

  defp argument_properties("write_to_document") do
    base_argument_properties()
    |> Map.merge(page_identifier_properties())
    |> Map.merge(%{
      "action" => %{"type" => "string", "enum" => Pages.document_actions()},
      "content" => %{"type" => "string"},
      "selected_text" => %{"type" => "string"}
    })
  end

  defp argument_properties("list_skills") do
    Map.merge(base_argument_properties(), %{
      "query" => %{"type" => "string"}
    })
  end

  defp argument_properties("load_skill") do
    Map.merge(base_argument_properties(), %{
      "slug" => %{"type" => "string"}
    })
  end

  defp argument_properties("save_skill") do
    Map.merge(base_argument_properties(), %{
      "name" => %{"type" => "string"},
      "description" => %{"type" => "string"},
      "body" => %{"type" => "string"},
      "slug" => %{"type" => "string"},
      "scope" => %{"type" => "string", "enum" => ["workspace", "user", "project", "org"]},
      "triggers" => %{"type" => "array", "items" => %{"type" => "string"}},
      "scripts" => %{"type" => "object"}
    })
  end

  defp argument_properties("update_skill") do
    Map.merge(base_argument_properties(), %{
      "slug" => %{"type" => "string"},
      "name" => %{"type" => "string"},
      "description" => %{"type" => "string"},
      "body" => %{"type" => "string"},
      "change_summary" => %{"type" => "string"},
      "triggers" => %{"type" => "array", "items" => %{"type" => "string"}},
      "scripts" => %{"type" => "object"}
    })
  end

  defp argument_properties("run_skill_script") do
    Map.merge(base_argument_properties(), %{
      "skill_slug" => %{"type" => "string"},
      "script_name" => %{"type" => "string"},
      "args" => %{"type" => "array", "items" => %{"type" => "string"}}
    })
  end

  defp argument_properties(tool_name)
       when tool_name in ~w(remember_about_user list_user_memories) do
    Map.merge(base_argument_properties(), %{
      "summary" => %{"type" => "string"},
      "category" => %{"type" => "string", "enum" => Holt.Memory.user_categories()},
      "user_id" => %{"type" => "string"}
    })
  end

  defp argument_properties("forget_about_user") do
    Map.merge(base_argument_properties(), %{
      "substring" => %{"type" => "string"},
      "user_id" => %{"type" => "string"}
    })
  end

  defp argument_properties("search_user_memory") do
    Map.merge(base_argument_properties(), %{
      "query" => %{"type" => "string"},
      "category" => %{"type" => "string", "enum" => Holt.Memory.user_categories()},
      "user_id" => %{"type" => "string"}
    })
  end

  defp argument_properties("remember_for_project") do
    Map.merge(base_argument_properties(), %{
      "summary" => %{"type" => "string"},
      "category" => %{"type" => "string", "enum" => Holt.Memory.project_categories()},
      "project_id" => %{"type" => "string"}
    })
  end

  defp argument_properties(tool_name) when tool_name in ~w(save_plan save_research) do
    Map.merge(base_argument_properties(), %{
      "title" => %{"type" => "string"},
      "body" => %{"type" => "string"},
      "category" => %{"type" => "string", "enum" => Holt.Memory.project_categories()},
      "sources" => %{"type" => "array", "items" => %{"type" => "string"}},
      "project_id" => %{"type" => "string"}
    })
  end

  defp argument_properties("recall_project_memory") do
    Map.merge(base_argument_properties(), %{
      "query" => %{"type" => "string"},
      "kind" => %{"type" => "string", "enum" => Holt.Memory.project_kinds()},
      "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 30},
      "project_id" => %{"type" => "string"}
    })
  end

  defp argument_properties("read_project_memory") do
    Map.merge(base_argument_properties(), %{
      "id" => %{"type" => "string"},
      "project_id" => %{"type" => "string"}
    })
  end

  defp argument_properties("search_web") do
    Map.merge(base_argument_properties(), %{
      "query" => %{"type" => "string"},
      "max_results" => %{"type" => "integer", "minimum" => 1, "maximum" => 10},
      "save_research_claim" => %{"type" => "boolean"},
      "claim" => %{"type" => "string"},
      "source_type" => %{"type" => "string", "enum" => Holt.ResearchClaims.source_types()},
      "version_applies" => %{"type" => "string"},
      "confidence" => %{"type" => "number", "minimum" => 0, "maximum" => 1},
      "source_urls" => %{"type" => "array", "items" => %{"type" => "string"}},
      "recheck_after" => %{"type" => "string"}
    })
  end

  defp argument_properties(_tool_name), do: base_argument_properties()

  defp base_argument_properties do
    %{
      "ref" => %{"type" => "string"},
      "arguments" => %{"type" => "object"},
      "task_tool_session" => %{"type" => "object"},
      "tool_name" => %{"type" => "string"},
      "action" => %{"type" => "string"},
      "toolkit" => %{"type" => "string"},
      "todos" => array_of(%{"type" => "object"})
    }
  end

  defp agent_identifier_properties do
    %{
      "agent_id" => %{"type" => "string"},
      "id" => %{"type" => "string"},
      "agent_ref" => %{"type" => "string"},
      "handle" => %{"type" => "string"}
    }
  end

  defp repair_run_identifier_properties do
    %{
      "repair_run_id" => %{"type" => "string"},
      "id" => %{"type" => "string"}
    }
  end

  defp page_identifier_properties do
    %{
      "page_id" => %{"type" => "string"},
      "id" => %{"type" => "string"}
    }
  end

  defp agent_profile_properties do
    %{
      "id" => %{"type" => "string"},
      "agent_id" => %{"type" => "string"},
      "display_name" => %{"type" => "string"},
      "name" => %{"type" => "string"},
      "description" => %{"type" => "string"},
      "agent_handle" => %{"type" => "string"},
      "handle" => %{"type" => "string"},
      "agent_ref" => %{"type" => "string"},
      "status" => %{"type" => "string", "enum" => Holt.Agents.statuses()},
      "work_roles" => %{
        "type" => "array",
        "items" => %{"type" => "string", "enum" => Holt.Agents.work_roles()}
      },
      "work_role" => %{"type" => "string", "enum" => Holt.Agents.work_roles()},
      "skills" => array_of(%{"type" => "object"}),
      "skill" => %{"type" => "string"},
      "model" => %{"type" => "string"},
      "provider" => %{"type" => "string"},
      "instructions" => %{"type" => "string"},
      "capabilities" => %{"type" => "array", "items" => %{"type" => "string"}},
      "permissions" => %{"type" => "object"},
      "metadata" => %{"type" => "object"}
    }
  end

  defp maybe_put_opt(opts, _key, value) when value in [nil, "", []], do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp array_of(items), do: %{"type" => "array", "items" => items}

  defp option(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp option(_opts, _key), do: nil

  defp normalize_reason(reason) when is_binary(reason), do: reason
  defp normalize_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp normalize_reason({key, value}), do: "#{normalize_reason(key)}:#{value}"
  defp normalize_reason(reason), do: inspect(reason)
end
