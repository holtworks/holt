defmodule Holt.Actions do
  @moduledoc """
  Executable action registry for local Holt providers.

  This module is the boundary between declared action metadata and actual local
  execution. Task actions are always routed through the task action router before
  dispatch, and workspace actions keep using the existing `Holt.LocalActions`
  approval policy.
  """

  alias Holt.{Clock, Pages, LocalActions}
  alias Holt.Actions.{ProviderRegistry, ActionCatalog, Execution, Todos}

  alias Holt.Tasks.{
    ActionContract,
    ActionRouter,
    ActionSession
  }

  @definition_schema "holt_action_definition/v1"
  @action_schema "holt_action_schema/v1"
  @safe_routed_scopes ~w(read_only session_ephemeral)

  def definitions(opts \\ []) do
    session =
      case option(opts, :action_session) do
        nil -> ActionSession.build(%{})
        value -> value
      end

    ActionSession.direct_action_names()
    |> Kernel.++(ActionSession.meta_action_names())
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&definition(&1, session))
  end

  def get(name, opts \\ []) do
    normalized = normalize_action_name(name)
    Enum.find(definitions(opts), &(&1["name"] == normalized))
  end

  def search(filters \\ %{}, opts \\ []) do
    if canonical_map?(filters) do
      definitions(opts)
      |> filter_exact("name", string_list(Map.get(filters, "names")))
      |> filter_exact("provider", string_list(Map.get(filters, "providers")))
      |> filter_exact("action_group", string_list(Map.get(filters, "action_groups")))
      |> filter_exact("effect_scope", string_list(Map.get(filters, "effect_scopes")))
    else
      []
    end
  end

  def agent_action_catalog(context \\ %{}, opts \\ []) do
    {context, opts} = normalize_catalog_args(context, opts)

    context
    |> catalog_definitions(opts)
    |> ActionCatalog.action_entries(context, "agent", opts)
  end

  def action_catalog(context \\ %{}, opts \\ []) do
    agent_action_catalog(context, opts)
  end

  def provider_action_catalog(context \\ %{}, opts \\ []) do
    {context, opts} = normalize_catalog_args(context, opts)

    context
    |> catalog_definitions(opts)
    |> ActionCatalog.action_entries(context, "mcp", opts)
  end

  def agent_action_definitions(context \\ %{}, opts \\ []) do
    context
    |> agent_action_catalog(opts)
    |> ActionCatalog.openai_action_definitions()
  end

  def provider_action_definitions(context \\ %{}, opts \\ []) do
    context
    |> provider_action_catalog(opts)
    |> ActionCatalog.mcp_action_definitions()
  end

  def action_providers(context \\ %{}, opts \\ []) do
    ProviderRegistry.for_context(context, opts)
  end

  def action_provider_ids(context \\ %{}, opts \\ []) do
    case action_providers(context, opts) do
      providers when is_list(providers) ->
        providers
        |> Enum.map(& &1["id"])
        |> Enum.sort()

      {:error, _reason} = error ->
        error
    end
  end

  def action_provider_metadata(context \\ %{}, opts \\ []) do
    context_for_definitions =
      case context do
        %{} -> context
        _context -> %{}
      end

    context_for_definitions
    |> catalog_definitions(opts)
    |> ProviderRegistry.metadata(context, opts)
  end

  def action_provider_prompt_sections(context \\ %{}, opts \\ []) do
    ProviderRegistry.prompt_sections(context, opts)
  end

  def dispatch_agent_action(action_name, params, context \\ %{}, opts \\ [])

  def dispatch_agent_action(action_name, params, context, opts)
      when is_binary(action_name) and is_map(params) do
    {context, opts} = normalize_catalog_args(context, opts)

    with :ok <- ensure_canonical_map(params),
         {:ok, entry} <-
           ActionCatalog.find_entry(agent_action_catalog(context, opts), action_name) do
      params = maybe_put_context_task_ref(params, context)

      execute(entry["name"], params, opts)
    else
      {:error, :not_found} ->
        {:error, :not_found}

      {:error, :invalid_action_arguments} ->
        {:error, :invalid_action_arguments}
    end
  end

  def dispatch_agent_action(_action_name, _params, _context, _opts), do: {:error, :not_found}

  def execute(name, args \\ %{}, opts \\ [])

  def execute(name, args, opts) when is_map(args) do
    case ensure_canonical_map(args) do
      :ok ->
        action_name = normalize_action_name(name)

        cond do
          is_nil(action_name) ->
            {:error, failed_execution(nil, args, nil, :action_required)}

          repair_action?(action_name) ->
            execute_workspace_action(action_name, args, opts)

          workspace_only_action?(action_name) ->
            with :ok <- reject_workspace_task_scope_args(args) do
              execute_workspace_action(action_name, args, opts)
            else
              {:error, reason} -> {:error, failed_execution(action_name, args, nil, reason)}
            end

          workspace_action?(action_name) and blank?(task_ref(args)) ->
            execute_workspace_action(action_name, args, opts)

          action_name == "list_tasks" and blank?(task_ref(args)) ->
            route_and_dispatch(nil, action_name, args, opts)

          action_name == "create_task" and blank?(task_ref(args)) ->
            route_and_dispatch(nil, action_name, args, opts)

          action_name == "watchdog_agent_runs" and blank?(task_ref(args)) ->
            route_and_dispatch(nil, action_name, args, opts)

          action_name == "capability_registry" and blank?(task_ref(args)) ->
            route_and_dispatch(nil, action_name, args, opts)

          action_name in ["manage_connection", "use_workbench"] and blank?(task_ref(args)) ->
            route_and_dispatch(nil, action_name, args, opts)

          true ->
            case task_ref(args) do
              nil -> {:error, failed_execution(action_name, args, nil, :task_ref_required)}
              ref -> execute_task_action(ref, action_name, drop_ref_args(args), opts)
            end
        end

      {:error, :invalid_action_arguments} ->
        {:error, :invalid_action_arguments}
    end
  end

  def execute(_name, _args, _opts), do: {:error, :invalid_action_arguments}

  def execute_task_action(ref_or_id, action_name, args \\ %{}, opts \\ [])

  def execute_task_action(ref_or_id, action_name, args, opts) when is_map(args) do
    case ensure_canonical_map(args) do
      :ok -> route_and_dispatch(ref_or_id, normalize_action_name(action_name), args, opts)
      {:error, :invalid_action_arguments} -> {:error, :invalid_action_arguments}
    end
  end

  def execute_task_action(_ref_or_id, _action_name, _args, _opts),
    do: {:error, :invalid_action_arguments}

  def execute_many(ref_or_id, calls, opts \\ [])

  def execute_many(ref_or_id, calls, opts) when is_list(calls) do
    calls
    |> Enum.reduce_while({:ok, []}, fn call, {:ok, executions} ->
      action_call = action_call(call)

      case required_value(action_call, "action") do
        {:ok, action_name} ->
          case action_call_arguments(action_call) do
            {:ok, args} ->
              case execute_task_action(ref_or_id, action_name, args, opts) do
                {:ok, execution} ->
                  {:cont, {:ok, [execution | executions]}}

                {:error, %{} = execution} ->
                  {:halt, {:error, Enum.reverse([execution | executions])}}

                {:error, reason} ->
                  {:halt,
                   {:error,
                    Enum.reverse([failed_execution(action_name, args, nil, reason) | executions])}}
              end

            {:error, reason} ->
              {:halt,
               {:error,
                Enum.reverse([failed_execution(action_name, %{}, nil, reason) | executions])}}
          end

        {:error, reason} ->
          reason =
            case reason do
              {:missing_required, "action"} ->
                {:missing_required_arguments, ["action"], ["action"], received_arguments(call)}

              other ->
                other
            end

          {:halt, {:error, Enum.reverse([failed_execution(nil, call, nil, reason) | executions])}}
      end
    end)
    |> case do
      {:ok, executions} -> {:ok, Enum.reverse(executions)}
      error -> error
    end
  end

  def execute_many(_ref_or_id, _calls, _opts), do: {:error, :invalid_action_batch}

  defp definition(action_name, session) do
    effect_scope = ActionContract.effect_scope(action_name)

    action =
      case LocalActions.get(action_name) do
        nil -> %{}
        value -> value
      end

    %{
      "schema_version" => @definition_schema,
      "name" => action_name,
      "description" => description(action_name, action),
      "provider" => provider(action_name, effect_scope),
      "action_group" => action_group(action_name, effect_scope),
      "effect_scope" => effect_scope,
      "risk_level" => risk_level(action, effect_scope),
      "requires_approval" =>
        ActionContract.requires_approval?(%{
          "effect_scope" => effect_scope,
          "risk_level" => risk_level(action, effect_scope)
        }),
      "requires_task_ref" => requires_task_ref?(action_name, effect_scope),
      "arguments_schema" => arguments_schema(action_name),
      "availability" => availability(action_name, session),
      "source" => "builtin"
    }
    |> compact()
  end

  defp filter_exact(definitions, _field, []), do: definitions

  defp filter_exact(definitions, field, values) do
    allowed = MapSet.new(values)
    Enum.filter(definitions, &MapSet.member?(allowed, Map.get(&1, field)))
  end

  defp availability(action_name, session) do
    declared_direct? =
      action_name in Map.get(session, "direct_actions", [])

    declared_meta? =
      action_name in meta_action_names(session)

    %{
      "route_status" =>
        if(ActionRouter.allowed?(action_name, session), do: "accepted", else: "unavailable"),
      "declared_in_session" => if(declared_direct?, do: true, else: declared_meta?)
    }
  end

  defp meta_action_names(session) do
    session
    |> Map.get("meta_actions", [])
    |> Enum.map(fn
      %{"name" => name} -> name
      _action -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp catalog_definitions(context, opts) do
    context = catalog_context(context)

    session =
      case catalog_session_source(context, opts) do
        session when is_map(session) -> session
        _missing -> ActionSession.build(context)
      end

    definitions(Keyword.put(opts, :action_session, session))
  end

  defp normalize_catalog_args(context, opts) when is_list(context) and opts == [] do
    {%{}, context}
  end

  defp normalize_catalog_args(context, opts) do
    {catalog_context(context), opts}
  end

  defp maybe_put_context_task_ref(params, context) do
    context_ref = text(context, "task_ref")

    cond do
      present_text?(params, "ref") ->
        params

      blank?(context_ref) ->
        params

      true ->
        Map.put(params, "ref", context_ref)
    end
  end

  defp execute_workspace_action(action_name, args, opts) do
    with :ok <- ensure_required_arguments(action_name, args) do
      route = ActionRouter.route(%{"action" => action_name, "arguments" => args})

      case LocalActions.execute(action_name, args, opts) do
        {:ok, result} -> {:ok, completed_execution(action_name, args, route, result)}
        {:error, reason} -> {:error, failed_execution(action_name, args, route, reason)}
      end
    else
      {:error, reason} -> {:error, failed_execution(action_name, args, nil, reason)}
    end
  end

  defp route_and_dispatch(ref_or_id, action_name, args, opts) do
    with :ok <- reject_legacy_context_keys(args),
         :ok <- ensure_required_arguments(action_name, args),
         {:ok, route} <- route_action(ref_or_id, action_name, args, opts),
         :ok <- ensure_route_accepted(route),
         {:ok, result} <- dispatch(ref_or_id, action_name, args, opts) do
      {:ok, completed_execution(action_name, args, route, result)}
    else
      {:rejected, route} ->
        {:error, rejected_execution(action_name, args, route)}

      {:error, %{} = execution} ->
        {:error, execution}

      {:error, {:missing_required_arguments, _missing, _required, _received} = reason} ->
        {:error, failed_execution(action_name, args, nil, reason)}

      {:error, reason} ->
        route =
          case route_action(ref_or_id, action_name, args, opts) do
            {:ok, route} -> route
            _other -> nil
          end

        {:error, failed_execution(action_name, args, route, reason)}
    end
  end

  defp route_action(ref_or_id, action_name, args, opts) do
    attrs =
      args
      |> route_attrs()
      |> Map.put("action", action_name)
      |> Map.put("arguments", action_arguments(args))
      |> Map.put_new("action_call_id", Clock.id("action_call"))

    if ref_or_id in [nil, ""] do
      {:ok, ActionRouter.route(attrs)}
    else
      Holt.Tasks.route_action(ref_or_id, attrs, opts)
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
    with {:ok, priority} <- args |> action_arguments() |> required_value("priority") do
      Holt.Tasks.set_priority(ref, priority, opts)
    end
  end

  defp dispatch(ref, "set_estimate", args, opts) do
    with {:ok, estimate} <- args |> action_arguments() |> required_value("estimate") do
      Holt.Tasks.set_estimate(ref, estimate, opts)
    end
  end

  defp dispatch(_ref, "todo_read", args, _opts) do
    {:ok, Todos.read(args)}
  end

  defp dispatch(_ref, "todo_write", args, _opts) do
    Todos.write(args)
  end

  defp dispatch(ref, "add_comment", args, opts) do
    with {:ok, body} <- args |> action_arguments() |> required_value("body") do
      Holt.Tasks.add_comment(ref, body, opts)
    end
  end

  defp dispatch(ref, "delete_comment", args, opts) do
    with {:ok, comment_id} <- args |> action_arguments() |> required_value("comment_id") do
      Holt.Tasks.delete_comment(ref, comment_id, opts)
    end
  end

  defp dispatch(ref, "add_label", args, opts) do
    label_args = action_arguments(args)

    with {:ok, _name} <- required_value(label_args, "name") do
      Holt.Tasks.add_label(ref, label_args, opts)
    end
  end

  defp dispatch(ref, "remove_label", args, opts) do
    with {:ok, name} <- args |> action_arguments() |> required_value("name") do
      Holt.Tasks.remove_label(ref, name, opts)
    end
  end

  defp dispatch(ref, "add_link", args, opts) do
    link_args = action_arguments(args)

    with {:ok, target_ref} <- required_value(link_args, "target_ref"),
         type = text(link_args, "type", "relates_to") do
      Holt.Tasks.add_link(ref, target_ref, type, opts)
    end
  end

  defp dispatch(ref, "remove_link", args, opts) do
    with {:ok, link_id} <- args |> action_arguments() |> required_value("link_id") do
      Holt.Tasks.remove_link(ref, link_id, opts)
    end
  end

  defp dispatch(ref, "list_task_specs", args, opts) do
    Holt.Tasks.list_specs(ref, spec_opts(args, opts))
  end

  defp dispatch(_ref, "get_task_spec", args, opts) do
    with {:ok, spec_id} <- args |> action_arguments() |> required_value("spec_id") do
      Holt.Tasks.get_spec(spec_id, spec_opts(args, opts))
    end
  end

  defp dispatch(ref, "save_task_spec", args, opts),
    do: Holt.Tasks.save_spec(ref, action_arguments(args), opts)

  defp dispatch(_ref, "read_task_memory_artifact", args, opts) do
    with {:ok, artifact_ref} <- args |> action_arguments() |> required_value("artifact_ref") do
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

  defp dispatch(ref, "delegate_to_agent", args, opts),
    do: Holt.Tasks.delegate_to_agent(ref, action_arguments(args), opts)

  defp dispatch(ref, "invoke_agent", args, opts),
    do: Holt.Tasks.invoke_agent(ref, action_arguments(args, keep_agent_id: true), opts)

  defp dispatch(ref, "continue_agent_work", args, opts),
    do: Holt.Tasks.continue_agent_work(ref, action_arguments(args), opts)

  defp dispatch(ref, "schedule_mob_colleague_flow", args, opts),
    do: Holt.Tasks.schedule_mob_colleague_flow(ref, action_arguments(args), opts)

  defp dispatch(_ref, "watchdog_agent_runs", args, opts) do
    {:ok, Holt.Tasks.watchdog_scan(watchdog_opts(args, opts))}
  end

  defp dispatch(ref, "create_task_graph", args, opts),
    do: Holt.Tasks.create_task_graph(ref, action_arguments(args), opts)

  defp dispatch(ref, "list_task_graphs", _args, opts), do: Holt.Tasks.task_graphs(ref, opts)

  defp dispatch(_ref, "get_task_graph", args, opts) do
    with {:ok, graph_id} <- args |> action_arguments() |> required_value("graph_id") do
      Holt.Tasks.get_task_graph(graph_id, opts)
    end
  end

  defp dispatch(_ref, "advance_task_graph", args, opts) do
    graph_args = action_arguments(args)

    with {:ok, graph_id} <- required_value(graph_args, "graph_id") do
      Holt.Tasks.advance_task_graph(
        graph_id,
        Map.delete(graph_args, "graph_id"),
        opts
      )
    end
  end

  defp dispatch(_ref, "complete_task_graph_node", args, opts) do
    graph_args = action_arguments(args)

    with {:ok, graph_id} <- required_value(graph_args, "graph_id"),
         {:ok, node_ref} <- required_value(graph_args, "node_ref") do
      Holt.Tasks.complete_task_graph_node(
        graph_id,
        node_ref,
        Map.drop(graph_args, ["graph_id", "node_ref"]),
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
    with {:ok, action_name} <- required_value(args, "action") do
      Holt.Tasks.capability_registry(action_name, action_arguments(args))
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
    approval_args = action_arguments(args)

    with {:ok, request_id} <- required_value(approval_args, "approval_request_id") do
      Holt.Tasks.resolve_action_approval_request(
        request_id,
        Map.delete(approval_args, "approval_request_id"),
        opts
      )
    end
  end

  defp dispatch(ref, "action_evidence_ledger", args, opts),
    do: Holt.Tasks.action_evidence_ledger(ref, action_arguments(args), opts)

  defp dispatch(_ref, "search_actions", args, opts) do
    {:ok, %{"actions" => search(action_arguments(args), opts)}}
  end

  defp dispatch(_ref, "get_action_schema", args, opts) do
    with {:ok, action_name} <- required_value(args, "action") do
      case get(action_name, opts) do
        nil -> {:error, :unknown_action}
        action -> {:ok, %{"schema_version" => @action_schema, "action" => action}}
      end
    end
  end

  defp dispatch(_ref, "manage_connection", args, _opts) do
    {:ok, connection_management_state(args)}
  end

  defp dispatch(ref, "use_workbench", args, opts) do
    session = session_from_args(args)
    workbench = map_value(Map.get(session, "workbench"))
    action_args = action_arguments(args)

    with :ok <- reject_legacy_action_keys(args),
         {:ok, nested_args} <- workbench_action_args(action_args),
         :ok <- ensure_workbench_enabled(workbench) do
      case text(args, "action") do
        nil ->
          {:ok, workbench_state(session, "available")}

        "" ->
          {:ok, workbench_state(session, "available")}

        action_name ->
          case execute_safe_nested_action(ref, action_name, nested_args, opts) do
            {:ok, execution} ->
              {:ok,
               session
               |> workbench_state("executed")
               |> Map.put("action_execution", execution)}

            error ->
              error
          end
      end
    end
  end

  defp dispatch(ref, "execute_action", args, opts) do
    with {:ok, nested_action} <- required_value(args, "action"),
         {:ok, nested_args} <- required_map(args, "arguments") do
      execute_safe_nested_action(ref, nested_action, nested_args, opts)
    end
  end

  defp dispatch(ref, "multi_execute_action", args, opts) do
    with {:ok, calls} <- required_value(args, "calls"),
         true <- is_list(calls) do
      case execute_safe_nested_many_actions(ref, calls, opts) do
        {:ok, executions} -> {:ok, %{"executions" => executions}}
        {:error, executions} when is_list(executions) -> {:error, failed_batch(executions)}
        {:error, reason} -> {:error, reason}
      end
    else
      _value -> {:error, :invalid_action_batch}
    end
  end

  defp dispatch(_ref, action_name, args, opts) do
    if workspace_action?(action_name) do
      LocalActions.execute(action_name, action_arguments(args), opts)
    else
      {:error, :unsupported_action}
    end
  end

  defp execute_safe_nested_many_actions(ref_or_id, calls, opts) when is_list(calls) do
    calls
    |> Enum.reduce_while({:ok, []}, fn call, {:ok, executions} ->
      action_call = action_call(call)

      case required_value(action_call, "action") do
        {:ok, action_name} ->
          case action_call_arguments(action_call) do
            {:ok, args} ->
              case execute_safe_nested_action(ref_or_id, action_name, args, opts) do
                {:ok, execution} ->
                  {:cont, {:ok, [execution | executions]}}

                {:error, %{} = execution} ->
                  {:halt, {:error, Enum.reverse([execution | executions])}}

                {:error, reason} ->
                  {:halt,
                   {:error,
                    Enum.reverse([failed_execution(action_name, args, nil, reason) | executions])}}
              end

            {:error, reason} ->
              {:halt,
               {:error,
                Enum.reverse([failed_execution(action_name, %{}, nil, reason) | executions])}}
          end

        {:error, reason} ->
          reason =
            case reason do
              {:missing_required, "action"} ->
                {:missing_required_arguments, ["action"], ["action"], received_arguments(call)}

              other ->
                other
            end

          {:halt, {:error, Enum.reverse([failed_execution(nil, call, nil, reason) | executions])}}
      end
    end)
    |> case do
      {:ok, executions} -> {:ok, Enum.reverse(executions)}
      error -> error
    end
  end

  defp execute_safe_nested_many_actions(_ref_or_id, _calls, _opts),
    do: {:error, :invalid_action_batch}

  defp execute_safe_nested_action(ref_or_id, action_name, args, opts) do
    action_name = normalize_action_name(action_name)

    with :ok <- reject_router_recursion(action_name),
         {:ok, route} <- route_action(ref_or_id, action_name, args, opts),
         :ok <- ensure_route_accepted(route),
         :ok <- ensure_safe_routed_scope(route) do
      execute_task_action(ref_or_id, action_name, args, opts)
    else
      {:rejected, route} -> {:error, rejected_execution(action_name, args, route)}
      {:error, %{} = execution} -> {:error, execution}
      {:error, reason} -> {:error, failed_execution(action_name, args, nil, reason)}
    end
  end

  defp reject_router_recursion(action_name) do
    if action_name in ActionSession.meta_action_names() do
      {:error, :router_meta_action_recursion}
    else
      :ok
    end
  end

  defp ensure_safe_routed_scope(route) do
    scope = get_in(route, ["action_contract", "effect_scope"])

    if scope in @safe_routed_scopes do
      :ok
    else
      {:error, {:unsafe_nested_effect_scope, scope_name(scope)}}
    end
  end

  defp completed_execution(action_name, args, route, result) do
    Execution.completed(action_name, args, route, result)
  end

  defp rejected_execution(action_name, args, route) do
    Execution.rejected(action_name, args, route)
  end

  defp failed_execution(action_name, args, route, reason) do
    Execution.failed(action_name, args, route, reason)
  end

  defp failed_batch(executions) do
    Execution.failed_batch(executions)
  end

  defp task_list_opts(args, opts) do
    opts
    |> maybe_put_opt(:status, text(args, "status"))
  end

  defp spec_opts(args, opts) do
    opts
    |> maybe_put_opt(:kind, text(args, "kind"))
    |> maybe_put_opt(:include_content, Map.get(args, "include_content"))
    |> maybe_put_opt(:content_limit, Map.get(args, "content_limit"))
    |> maybe_put_opt(:task_ref, text(args, "ref"))
  end

  defp teammate_runtime_opts(args, opts) do
    opts
    |> maybe_put_opt(:content_limit, Map.get(args, "content_limit"))
    |> maybe_put_opt(:comment_limit, Map.get(args, "comment_limit"))
  end

  defp watchdog_opts(args, opts) do
    opts
    |> maybe_put_opt(:limit, Map.get(args, "limit"))
    |> maybe_put_opt(:stale_after_seconds, Map.get(args, "stale_after_seconds"))
    |> maybe_put_opt(
      :recovery_cooldown_seconds,
      Map.get(args, "recovery_cooldown_seconds")
    )
  end

  defp connection_management_state(args) do
    session = session_from_args(args)
    action_args = action_arguments(args)
    action = text(action_args, "action", "list")
    action_group = text(action_args, "action_group")
    accounts = map_value(Map.get(session, "connected_accounts"))

    %{
      "schema_version" => "holt_task_connection_management/v1",
      "action_session_id" => session["session_id"],
      "action" => action,
      "action_group" => action_group,
      "connected_accounts" => filter_connected_accounts(accounts, action_group),
      "enabled_action_groups" => string_list(Map.get(session, "enabled_action_groups")),
      "status" => connection_management_status(action)
    }
    |> compact()
  end

  defp filter_connected_accounts(accounts, nil), do: accounts
  defp filter_connected_accounts(accounts, ""), do: accounts

  defp filter_connected_accounts(accounts, action_group) do
    case Map.get(accounts, action_group) do
      nil -> %{}
      account -> %{action_group => account}
    end
  end

  defp ensure_workbench_enabled(%{"enabled" => true}), do: :ok
  defp ensure_workbench_enabled(_workbench), do: {:error, :workbench_disabled}

  defp reject_legacy_action_keys(%{"action_name" => _value}),
    do: {:error, {:unsupported_argument, "action_name"}}

  defp reject_legacy_action_keys(%{"name" => _value}),
    do: {:error, {:unsupported_argument, "name"}}

  defp reject_legacy_action_keys(_args), do: :ok

  defp connection_management_status(action) when action in ["list", "inspect"], do: "listed"
  defp connection_management_status("request"), do: "requires_user_initiated_connection_flow"
  defp connection_management_status("repair"), do: "requires_user_initiated_connection_flow"
  defp connection_management_status(_action), do: "unsupported_action"

  defp workbench_state(session, status) do
    %{
      "schema_version" => "holt_task_workbench/v1",
      "action_session_id" => session["session_id"],
      "workbench" => map_value(Map.get(session, "workbench")),
      "status" => status,
      "message" => workbench_message(status)
    }
  end

  defp workbench_message("available"),
    do: "Provide action and arguments to route a read-only or session-ephemeral workbench action."

  defp workbench_message("executed"),
    do: "Workbench action executed through the task action router."

  defp workbench_message(_status), do: nil

  defp workbench_action_args(action_args) do
    case Map.fetch(action_args, "arguments") do
      {:ok, arguments} when is_map(arguments) ->
        if canonical_map?(arguments) do
          {:ok, arguments}
        else
          {:error, :invalid_action_arguments}
        end

      {:ok, _value} ->
        {:error, :invalid_action_arguments}

      :error ->
        {:ok, Map.drop(action_args, ["action"])}
    end
  end

  defp session_from_args(args) do
    case Map.get(args, "action_session") do
      session when is_map(session) -> ActionSession.build(session)
      _missing -> ActionSession.build(args)
    end
  end

  defp reject_legacy_context_keys(%{"session" => _value}),
    do: {:error, {:unsupported_argument, "session"}}

  defp reject_legacy_context_keys(%{"task_graph_id" => _value}),
    do: {:error, {:unsupported_argument, "task_graph_id"}}

  defp reject_legacy_context_keys(_args), do: :ok

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
      "action_session",
      "session_id",
      "agent_id",
      "agent_ref",
      "agent_handle",
      "agent_name",
      "run_id",
      "agent_run_id",
      "graph_id",
      "policy_profile",
      "enabled_action_groups",
      "disabled_action_groups",
      "disabled_actions",
      "direct_actions",
      "preload_actions",
      "connected_accounts",
      "workbench",
      "todos",
      "source"
    ])
  end

  defp action_arguments(args, opts \\ []) do
    case Map.get(args, "arguments") do
      value when is_map(value) ->
        value

      _value ->
        context_keys =
          [
            "action_session",
            "session_id",
            "agent_ref",
            "agent_handle",
            "agent_name",
            "run_id",
            "agent_run_id",
            "policy_profile",
            "enabled_action_groups",
            "disabled_action_groups",
            "disabled_actions",
            "direct_actions",
            "preload_actions",
            "connected_accounts",
            "workbench",
            "source"
          ]

        context_keys =
          if Keyword.get(opts, :keep_agent_id, false) do
            context_keys
          else
            ["agent_id" | context_keys]
          end

        Map.drop(args, context_keys)
    end
  end

  defp required_value(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) ->
        text = String.trim(value)
        if text == "", do: {:error, {:missing_required, key}}, else: {:ok, text}

      value when is_integer(value) ->
        {:ok, value}

      value when is_float(value) ->
        {:ok, value}

      value when is_map(value) ->
        {:ok, value}

      value when is_list(value) ->
        {:ok, value}

      _value ->
        {:error, {:missing_required, key}}
    end
  end

  defp required_map(map, key) do
    case Map.get(map, key) do
      value when is_map(value) -> {:ok, value}
      _value -> {:error, {:missing_required, key}}
    end
  end

  defp ensure_required_arguments(action_name, args) do
    required = required_arguments(action_name)

    missing =
      required
      |> Enum.reject(&argument_present?(args, &1))

    if missing == [] do
      :ok
    else
      {:error, {:missing_required_arguments, missing, required, received_arguments(args)}}
    end
  end

  defp argument_present?(args, key) when is_map(args) do
    Map.has_key?(args, key) and not is_nil(Map.get(args, key))
  end

  defp argument_present?(_args, _key), do: false

  defp received_arguments(args) when is_map(args), do: Map.keys(args) |> Enum.sort()
  defp received_arguments(_args), do: []

  defp normalize_action_name(nil), do: nil

  defp normalize_action_name(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp task_ref(args) do
    text(args, "ref")
  end

  defp drop_ref_args(args), do: Map.drop(args, ["ref"])

  defp workspace_action?(action_name), do: not is_nil(LocalActions.get(action_name))

  defp workspace_only_action?(action_name) do
    workspace_action?(action_name) and action_name not in ~w(delegate_to_agent invoke_agent)
  end

  defp reject_workspace_task_scope_args(args) do
    cond do
      Map.has_key?(args, "ref") -> {:error, {:unsupported_argument, "ref"}}
      Map.has_key?(args, "task_ref") -> {:error, {:unsupported_argument, "task_ref"}}
      Map.has_key?(args, "task_id") -> {:error, {:unsupported_argument, "task_id"}}
      true -> :ok
    end
  end

  defp repair_action?(action_name) do
    action_name in ~w(start_repair_run get_repair_run record_repair_run_artifact reconcile_repair_prediction score_repair_predictions choose_repair_strategy draft_repair_architecture_plan draft_repair_blast_radius draft_repair_original_issue_check execute_repair_original_issue_check execute_repair_impact_check draft_repair_related_issue_sweep begin_repair_implementation approve_repair_gate complete_repair_run)
  end

  defp provider(action_name, effect_scope) do
    cond do
      effect_scope == "agent_orchestration" -> "agent_orchestration"
      workspace_action?(action_name) -> "workspace"
      effect_scope == "routed" -> "router"
      effect_scope == "read_only" and action_name == "manage_connection" -> "action_session"
      true -> "tasks"
    end
  end

  defp action_group(action_name, effect_scope) do
    cond do
      effect_scope == "agent_orchestration" -> "agent_orchestration"
      workspace_action?(action_name) -> "workspace"
      effect_scope == "routed" -> "meta"
      action_name == "manage_connection" -> "meta"
      effect_scope == "session_ephemeral" -> "session"
      effect_scope == "read_only" -> "task"
      effect_scope == "task_durable" -> "task"
      true -> "verification"
    end
  end

  defp description(_action_name, %{"description" => description}), do: description
  defp description("search_actions", _action), do: "Find available actions for a task session."

  defp description("get_action_schema", _action),
    do: "Return structured metadata for one executable action."

  defp description("execute_action", _action),
    do: "Execute one read-only or session-ephemeral routed task action."

  defp description("multi_execute_action", _action),
    do: "Execute an ordered batch of read-only or session-ephemeral routed task actions."

  defp description("todo_read", _action), do: "Read the current in-session todo list."
  defp description("todo_write", _action), do: "Replace the in-session todo list."

  defp description("manage_connection", _action),
    do: "Inspect connected-account context declared for the task session."

  defp description("use_workbench", _action),
    do: "Inspect the local workbench or route a safe workbench action."

  defp description("schedule_mob_colleague_flow", _action) do
    "Create a specialist mob colleague that observes a task live through comments and reviews the completed groundwork."
  end

  defp description(action_name, _action),
    do: "Execute #{action_name} through the local Holt provider."

  defp risk_level(%{"risk" => "read"}, _effect_scope), do: "low"
  defp risk_level(%{"risk" => "write"}, _effect_scope), do: "medium"
  defp risk_level(%{"risk" => "execute"}, _effect_scope), do: "high"
  defp risk_level(%{"risk" => "network"}, _effect_scope), do: "high"
  defp risk_level(_action, "read_only"), do: "low"
  defp risk_level(_action, "session_ephemeral"), do: "low"
  defp risk_level(_action, "task_durable"), do: "medium"
  defp risk_level(_action, "agent_orchestration"), do: "medium"
  defp risk_level(_action, "workspace_durable"), do: "high"
  defp risk_level(_action, "external_side_effect"), do: "high"
  defp risk_level(_action, "routed"), do: "medium"
  defp risk_level(_action, _effect_scope), do: "unknown"

  defp requires_task_ref?("list_tasks", _effect_scope), do: false
  defp requires_task_ref?("create_task", _effect_scope), do: false
  defp requires_task_ref?("watchdog_agent_runs", _effect_scope), do: false
  defp requires_task_ref?("capability_registry", _effect_scope), do: false
  defp requires_task_ref?("manage_connection", _effect_scope), do: false
  defp requires_task_ref?("use_workbench", _effect_scope), do: false

  defp requires_task_ref?(action_name, _effect_scope)
       when action_name in ~w(list read search write append run fetch search_web ask ask delegate_to_agent set_page_title create_page write_to_document remember recall remember_about_user forget_about_user list_user_memories search_user_memory remember_for_project save_plan save_research recall_project_memory read_project_memory list_skills load_skill save_skill update_skill run_skill_script list_agents create_agent update_agent suspend_agent resume_agent delete_agent list_agent_cards get_agent_card list_agent_skills invoke_agent start_repair_run get_repair_run record_repair_run_artifact reconcile_repair_prediction score_repair_predictions choose_repair_strategy draft_repair_architecture_plan draft_repair_blast_radius draft_repair_original_issue_check execute_repair_original_issue_check execute_repair_impact_check draft_repair_related_issue_sweep begin_repair_implementation approve_repair_gate complete_repair_run),
       do: false

  defp requires_task_ref?(_action_name, _effect_scope), do: true

  defp arguments_schema(action_name) do
    %{
      "type" => "object",
      "required" => required_arguments(action_name),
      "properties" => argument_properties(action_name)
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
  defp required_arguments("capability_registry"), do: ["action"]
  defp required_arguments("get_action_schema"), do: ["action"]
  defp required_arguments("execute_action"), do: ["action", "arguments"]
  defp required_arguments("multi_execute_action"), do: ["calls"]
  defp required_arguments("todo_write"), do: ["todos"]
  defp required_arguments("read"), do: ["path"]
  defp required_arguments("write"), do: ["path", "content"]
  defp required_arguments("append"), do: ["path", "content"]
  defp required_arguments("search"), do: ["query"]
  defp required_arguments("run"), do: ["command"]
  defp required_arguments("fetch"), do: ["url"]
  defp required_arguments("search_web"), do: ["query"]
  defp required_arguments("ask"), do: ["question"]
  defp required_arguments("delegate_to_agent"), do: ["role", "system_prompt", "instructions"]

  defp required_arguments("schedule_mob_colleague_flow"),
    do: [
      "groundwork_agent_id",
      "colleague_agent",
      "setup_task",
      "observation_task",
      "observation_message",
      "review_task",
      "review_message",
      "collaboration_comments"
    ]

  defp required_arguments("set_page_title"), do: ["page_id", "title"]
  defp required_arguments("create_page"), do: ["page_type", "title"]
  defp required_arguments("write_to_document"), do: ["page_id", "action", "content"]
  defp required_arguments("remember_about_user"), do: ["summary", "category"]
  defp required_arguments("forget_about_user"), do: ["substring"]
  defp required_arguments("search_user_memory"), do: ["query"]
  defp required_arguments("remember_for_project"), do: ["summary", "category"]
  defp required_arguments("save_plan"), do: ["title", "body", "category"]
  defp required_arguments("save_research"), do: ["title", "body", "category"]
  defp required_arguments("read_project_memory"), do: ["id"]
  defp required_arguments("load_skill"), do: ["slug"]
  defp required_arguments("save_skill"), do: ["name", "description", "body"]
  defp required_arguments("update_skill"), do: ["slug"]
  defp required_arguments("run_skill_script"), do: ["skill_slug", "script_name"]
  defp required_arguments("get_agent_card"), do: ["agent_id"]
  defp required_arguments("list_agent_skills"), do: ["agent_id"]

  defp required_arguments("create_agent"),
    do: ["agent_id", "display_name", "instructions", "skills"]

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
  defp required_arguments(_action_name), do: []

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

  defp argument_properties(action_name)
       when action_name in ~w(draft_repair_architecture_plan draft_repair_blast_radius draft_repair_original_issue_check execute_repair_original_issue_check execute_repair_impact_check draft_repair_related_issue_sweep) do
    base_argument_properties()
    |> Map.merge(repair_run_identifier_properties())
    |> Map.merge(%{
      "record" => %{"type" => "boolean"},
      "payload" => %{"type" => "object"},
      "proof_commands" => array_of(%{"type" => "object"}),
      "manual_check_results" => array_of(%{"type" => "object"}),
      "action_check_results" => array_of(%{"type" => "object"}),
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
      "status" => %{"type" => "string", "enum" => ["all"] ++ Holt.Agents.statuses()}
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

  defp argument_properties(action_name) when action_name in ~w(suspend_agent resume_agent) do
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
      "status" => %{"type" => "string", "enum" => ["all"] ++ Holt.Agents.statuses()}
    })
  end

  defp argument_properties(action_name)
       when action_name in ~w(get_agent_card list_agent_skills) do
    Map.merge(base_argument_properties(), agent_identifier_properties())
  end

  defp argument_properties("invoke_agent") do
    base_argument_properties()
    |> Map.merge(agent_identifier_properties())
    |> Map.merge(%{
      "instructions" => %{"type" => "string"},
      "task_title" => %{"type" => "string"},
      "target_skill" => %{"type" => "string"},
      "work_role" => %{
        "type" => "string",
        "enum" => ["worker", "verifier", "researcher", "critic", "planner", "operator"]
      },
      "input_artifacts" => %{"type" => "array", "items" => %{"type" => "string"}},
      "expected_output_artifacts" => %{"type" => "array", "items" => %{"type" => "string"}},
      "validation_contract" => %{"type" => "string"},
      "handoff_requirements" => %{"type" => "array", "items" => %{"type" => "string"}},
      "allowed_actions" => %{"type" => "array", "items" => %{"type" => "string"}},
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

  defp argument_properties("ask") do
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

  defp argument_properties("list") do
    Map.merge(workspace_argument_properties(), %{
      "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 500}
    })
  end

  defp argument_properties("read") do
    Map.merge(workspace_argument_properties(), %{
      "path" => %{"type" => "string"}
    })
  end

  defp argument_properties(action_name) when action_name in ~w(write append) do
    Map.merge(workspace_argument_properties(), %{
      "path" => %{"type" => "string"},
      "content" => %{"type" => "string"}
    })
  end

  defp argument_properties("search") do
    Map.merge(workspace_argument_properties(), %{
      "query" => %{"type" => "string"}
    })
  end

  defp argument_properties("run") do
    Map.merge(workspace_argument_properties(), %{
      "command" => %{"type" => "string"}
    })
  end

  defp argument_properties("fetch") do
    Map.merge(workspace_argument_properties(), %{
      "url" => %{"type" => "string"}
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
      "task_title" => %{"type" => "string"},
      "page_id" => %{"type" => "string"},
      "target_agent_id" => %{"type" => "string"},
      "target_skill" => %{"type" => "string"},
      "input_artifacts" => %{"type" => "array", "items" => %{"type" => "string"}},
      "expected_output_artifacts" => %{"type" => "array", "items" => %{"type" => "string"}},
      "validation_contract" => %{"type" => "string"},
      "parent_task_id" => %{"type" => "string"},
      "handoff_requirements" => %{"type" => "array", "items" => %{"type" => "string"}},
      "allowed_actions" => %{"type" => "array", "items" => %{"type" => "string"}},
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

  defp argument_properties("schedule_mob_colleague_flow") do
    Map.merge(base_argument_properties(), %{
      "groundwork_agent_id" => %{"type" => "string"},
      "colleague_agent" => %{
        "type" => "object",
        "required" => ["agent_id", "display_name", "instructions", "skills"],
        "properties" => %{
          "agent_id" => %{"type" => "string"},
          "display_name" => %{"type" => "string"},
          "description" => %{"type" => "string"},
          "agent_handle" => %{"type" => "string"},
          "agent_ref" => %{"type" => "string"},
          "status" => %{"type" => "string", "enum" => Holt.Agents.statuses()},
          "work_roles" => array_of(%{"type" => "string", "enum" => Holt.Agents.work_roles()}),
          "default_work_role" => %{"type" => "string", "enum" => Holt.Agents.work_roles()},
          "skills" =>
            array_of(%{
              "type" => "object",
              "required" => ["id", "name"],
              "properties" => %{
                "id" => %{"type" => "string"},
                "name" => %{"type" => "string"},
                "description" => %{"type" => "string"},
                "action_names" => array_of(%{"type" => "string"})
              }
            }),
          "model" => %{"type" => "string"},
          "provider" => %{"type" => "string"},
          "instructions" => %{"type" => "string"},
          "capabilities" => array_of(%{"type" => "string"}),
          "permissions" => %{"type" => "object"},
          "metadata" => %{"type" => "object"}
        }
      },
      "setup_task" => mob_colleague_task_template_schema(),
      "observation_task" => mob_colleague_task_template_schema(),
      "observation_message" => %{"type" => "string"},
      "review_task" => mob_colleague_task_template_schema(),
      "review_message" => %{"type" => "string"},
      "documentation_sources" => array_of(%{"type" => "string"}),
      "collaboration_comments" =>
        array_of(%{
          "type" => "object",
          "required" => ["body"],
          "properties" => %{
            "body" => %{"type" => "string"},
            "phase" => %{"type" => "string", "enum" => ["groundwork", "review"]},
            "priority" => %{"type" => "string"},
            "topic" => %{"type" => "string"}
          }
        })
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

  defp argument_properties(action_name)
       when action_name in ~w(remember_about_user list_user_memories) do
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

  defp argument_properties(action_name) when action_name in ~w(save_plan save_research) do
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

  defp argument_properties(_action_name), do: base_argument_properties()

  defp base_argument_properties do
    %{
      "ref" => %{"type" => "string"},
      "arguments" => %{"type" => "object"},
      "action_session" => %{"type" => "object"},
      "action" => %{"type" => "string"},
      "action_group" => %{"type" => "string"},
      "todos" => array_of(%{"type" => "object"})
    }
  end

  defp workspace_argument_properties do
    %{
      "reason" => %{"type" => "string"}
    }
  end

  defp mob_colleague_task_template_schema do
    %{
      "type" => "object",
      "required" => ["title", "description"],
      "properties" => %{
        "title" => %{"type" => "string"},
        "description" => %{"type" => "string"},
        "priority" => %{"type" => "string", "enum" => Holt.Tasks.priorities()},
        "labels" => array_of(%{"type" => "object"}),
        "agent_policy" => %{"type" => "object"}
      }
    }
  end

  defp agent_identifier_properties do
    %{
      "agent_id" => %{"type" => "string"}
    }
  end

  defp repair_run_identifier_properties do
    %{
      "repair_run_id" => %{"type" => "string"}
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
      "agent_id" => %{"type" => "string"},
      "display_name" => %{"type" => "string"},
      "description" => %{"type" => "string"},
      "agent_handle" => %{"type" => "string"},
      "agent_ref" => %{"type" => "string"},
      "status" => %{"type" => "string", "enum" => Holt.Agents.statuses()},
      "work_roles" => %{
        "type" => "array",
        "items" => %{"type" => "string", "enum" => Holt.Agents.work_roles()}
      },
      "skills" => array_of(%{"type" => "object"}),
      "model" => %{"type" => "string"},
      "provider" => %{"type" => "string"},
      "instructions" => %{"type" => "string"},
      "capabilities" => %{"type" => "array", "items" => %{"type" => "string"}},
      "permissions" => %{"type" => "object"},
      "metadata" => %{"type" => "object"}
    }
  end

  defp action_call(call) when is_map(call) do
    if canonical_map?(call), do: call, else: %{}
  end

  defp action_call(_call), do: %{}

  defp action_call_arguments(%{"arguments" => arguments}) when is_map(arguments),
    do: {:ok, arguments}

  defp action_call_arguments(%{"arguments" => _arguments}),
    do: {:error, :invalid_action_arguments}

  defp action_call_arguments(_call), do: {:ok, %{}}

  defp catalog_context(context) when is_map(context) do
    if canonical_map?(context), do: context, else: %{}
  end

  defp catalog_context(_context), do: %{}

  defp catalog_session_source(context, opts) do
    case Map.fetch(context, "action_session") do
      {:ok, session} -> session
      :error -> option(opts, :action_session)
    end
  end

  defp ensure_canonical_map(map) do
    if canonical_map?(map), do: :ok, else: {:error, :invalid_action_arguments}
  end

  defp canonical_map?(map) when is_map(map) do
    Enum.all?(map, fn {key, value} -> is_binary(key) and canonical_value?(value) end)
  end

  defp canonical_map?(_value), do: false

  defp canonical_value?(value) when is_map(value), do: canonical_map?(value)
  defp canonical_value?(value) when is_list(value), do: Enum.all?(value, &canonical_value?/1)
  defp canonical_value?(_value), do: true

  defp text(map, key, default \\ nil)

  defp text(map, key, default) when is_map(map) do
    case Map.get(map, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> default
          trimmed -> trimmed
        end

      _value ->
        default
    end
  end

  defp text(_map, _key, default), do: default

  defp present_text?(map, key) do
    case text(map, key) do
      nil -> false
      _value -> true
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false

  defp string_list(nil), do: []

  defp string_list(value) when is_binary(value) do
    case String.trim(value) do
      "" -> []
      trimmed -> [trimmed]
    end
  end

  defp string_list(value) when is_list(value) do
    value
    |> Enum.flat_map(&string_list/1)
    |> Enum.uniq()
  end

  defp string_list(_value), do: []

  defp map_value(value) when is_map(value) do
    if canonical_map?(value), do: value, else: %{}
  end

  defp map_value(_value), do: %{}

  defp compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end

  defp scope_name(value) when is_binary(value), do: value
  defp scope_name(_value), do: "unknown"

  defp maybe_put_opt(opts, _key, value) when value in [nil, "", []], do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp array_of(items), do: %{"type" => "array", "items" => items}

  defp option(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp option(opts, key) when is_map(opts), do: Map.get(opts, key)
  defp option(_opts, _key), do: nil
end
