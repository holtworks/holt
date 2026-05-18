defmodule Holt.Tasks.ActionContract do
  @moduledoc """
  Structured contract for one task-scoped action.

  The contract is durable policy input for routers, plan gates, and preflight
  checks. It describes the effect class, target references, recovery posture,
  and idempotency key without executing the action.
  """

  alias Holt.{Clock, LocalActions}
  alias Holt.Tasks.ActionSession

  @schema_version "holt_action_contract/v1"

  @task_durable_actions ~w(
    create_task update_task set_priority set_estimate
    add_comment delete_comment add_label remove_label add_link remove_link
    save_task_spec save_teammate_memory route_verification_review
    create_task_graph advance_task_graph complete_task_graph_node remember
    remember_about_user forget_about_user remember_for_project save_plan save_research
    action_approval_request resolve_action_approval_request action_evidence_ledger
    record_task_memory_artifact task_memory_context context_budget continuation_packet
    verifier_calibration
  )
  @agent_orchestration_actions ~w(
    start_agent_work continue_agent_work delegate_to_agent invoke_agent
    watchdog_agent_runs schedule_mob_colleague_flow plan_verifier_route verifier_dispatch
  )
  @session_ephemeral_actions ~w(todo_read todo_write)
  @read_only_actions ~w(
    list_tasks get_task list_task_specs get_task_spec read_task_memory_artifact
    load_teammate_runtime get_evidence_contract list_task_graphs get_task_graph
    recall search_actions get_action_schema ask
    list_user_memories search_user_memory recall_project_memory read_project_memory
    manage_connection
    action_contract plan_contract plan_gate action_preflight
    consequence_gate action_runtime_envelope complete_action_runtime_envelope
    capability_registry capability_contract capability_route generic_plan
    work_graph work_graph_gate work_graph_budget work_graph_schedule
    agent_dispatch_plan team_orchestration child_agent_contract
    verification_contract verifier_assignment
  )
  @workspace_durable_actions ~w(write append run)
  @workspace_read_actions ~w(list read search)
  @network_actions ~w(fetch search_web)
  @meta_actions ~w(execute_action multi_execute_action use_workbench)
  @known_effect_scopes ~w(
    read_only session_ephemeral task_durable agent_orchestration workspace_durable external_side_effect routed
  )

  def build(attrs \\ %{})

  def build(attrs) when is_map(attrs) do
    with :ok <- canonical_attrs(attrs),
         {:ok, action} <- action_name(attrs),
         {:ok, arguments} <- optional_map(attrs, "arguments"),
         {:ok, session} <- action_session(attrs),
         {:ok, contract_id} <- optional_text(attrs, "contract_id"),
         {:ok, action_call_id} <- optional_text(attrs, "action_call_id"),
         {:ok, created_at} <- optional_text(attrs, "created_at") do
      effect_scope = effect_scope(action)
      risk_level = risk_level(action, effect_scope)
      target_refs = target_refs(action, effect_scope, arguments, session)
      preview = arguments_preview(arguments)

      %{
        "schema_version" => @schema_version,
        "contract_id" => text_default(contract_id, Clock.id("action_contract")),
        "action" => action,
        "action_call_id" => action_call_id,
        "effect_scope" => effect_scope,
        "risk_level" => risk_level,
        "target_domain" => target_domain(action, effect_scope),
        "target_refs" => target_refs,
        "arguments_preview" => preview,
        "recovery" => recovery_contract(effect_scope, risk_level),
        "idempotency_key" => idempotency_key(action, target_refs, preview),
        "created_at" => text_default(created_at, Clock.iso_now())
      }
      |> compact()
    end
  end

  def build(_attrs), do: {:error, :invalid_action_contract}

  def effect_scope(action_name) when action_name in @read_only_actions, do: "read_only"
  def effect_scope(action_name) when action_name in @workspace_read_actions, do: "read_only"

  def effect_scope(action_name) when action_name in @session_ephemeral_actions,
    do: "session_ephemeral"

  def effect_scope(action_name) when action_name in @task_durable_actions, do: "task_durable"

  def effect_scope(action_name) when action_name in @agent_orchestration_actions,
    do: "agent_orchestration"

  def effect_scope(action_name) when action_name in @workspace_durable_actions,
    do: "workspace_durable"

  def effect_scope(action_name) when action_name in @network_actions, do: "external_side_effect"
  def effect_scope(action_name) when action_name in @meta_actions, do: "routed"

  def effect_scope(action_name) do
    case LocalActions.get(action_name) do
      %{"risk" => "read"} -> "read_only"
      %{"risk" => "write"} -> "workspace_durable"
      %{"risk" => "execute"} -> "workspace_durable"
      %{"risk" => "network"} -> "external_side_effect"
      _action -> "unknown"
    end
  end

  def known_effect_scope?(scope), do: scope in @known_effect_scopes

  def mutating_effect_scope?(scope) do
    scope in ["task_durable", "agent_orchestration", "workspace_durable", "external_side_effect"]
  end

  def requires_approval?(%{"effect_scope" => scope, "risk_level" => risk}) do
    cond do
      scope in ["workspace_durable", "external_side_effect"] -> true
      risk in ["high", "critical"] -> true
      true -> false
    end
  end

  def requires_approval?(_contract), do: false

  defp action_name(attrs) do
    case Map.fetch(attrs, "action") do
      :error ->
        {:ok, "unknown"}

      {:ok, value} when is_binary(value) ->
        value = String.trim(value)

        case value do
          "" -> {:ok, "unknown"}
          action -> {:ok, action}
        end

      {:ok, _value} ->
        {:error, {:invalid_action_contract_field, "action"}}
    end
  end

  defp action_session(attrs) do
    case Map.fetch(attrs, "action_session") do
      {:ok, session} when is_map(session) -> {:ok, ActionSession.build(session)}
      {:ok, _session} -> {:error, {:invalid_action_contract_field, "action_session"}}
      :error -> {:ok, ActionSession.build(attrs)}
    end
  end

  defp optional_text(map, key) do
    case Map.fetch(map, key) do
      :error ->
        {:ok, nil}

      {:ok, value} when is_binary(value) ->
        value = String.trim(value)

        case value do
          "" -> {:ok, nil}
          trimmed -> {:ok, trimmed}
        end

      {:ok, _value} ->
        {:error, {:invalid_action_contract_field, key}}
    end
  end

  defp optional_map(map, key) do
    case Map.fetch(map, key) do
      :error -> {:ok, %{}}
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_action_contract_field, key}}
    end
  end

  defp text_default(nil, default), do: default
  defp text_default(value, _default), do: value

  defp canonical_attrs(attrs) do
    if canonical_value?(attrs) do
      :ok
    else
      {:error, :invalid_action_contract}
    end
  end

  defp canonical_value?(value) when is_map(value) do
    Enum.all?(value, fn
      {key, nested} when is_binary(key) -> canonical_value?(nested)
      {_key, _nested} -> false
    end)
  end

  defp canonical_value?(values) when is_list(values), do: Enum.all?(values, &canonical_value?/1)
  defp canonical_value?(_value), do: true

  defp risk_level(action_name, effect_scope) do
    case LocalActions.get(action_name) do
      %{"risk" => "read"} -> "low"
      %{"risk" => "write"} -> "medium"
      %{"risk" => "execute"} -> "high"
      %{"risk" => "network"} -> "high"
      _action -> risk_for_scope(effect_scope)
    end
  end

  defp risk_for_scope("read_only"), do: "low"
  defp risk_for_scope("session_ephemeral"), do: "low"
  defp risk_for_scope("task_durable"), do: "medium"
  defp risk_for_scope("agent_orchestration"), do: "medium"
  defp risk_for_scope("workspace_durable"), do: "high"
  defp risk_for_scope("external_side_effect"), do: "high"
  defp risk_for_scope("routed"), do: "medium"
  defp risk_for_scope(_scope), do: "unknown"

  defp target_domain(action_name, effect_scope) do
    cond do
      action_name == "manage_connection" ->
        "connected_accounts"

      action_name == "use_workbench" ->
        "workbench"

      task_action?(action_name) ->
        "task"

      effect_scope == "session_ephemeral" ->
        "session_state"

      effect_scope == "agent_orchestration" ->
        "agent_work"

      workspace_action?(action_name, effect_scope) ->
        "workspace"

      effect_scope == "external_side_effect" ->
        "external_network"

      effect_scope == "routed" ->
        "action_router"

      true ->
        "unknown"
    end
  end

  defp target_refs(action_name, effect_scope, arguments, session) do
    refs = %{
      "task_id" => task_id_ref(arguments, session),
      "task_ref" => task_ref(arguments, session),
      "task_collection" => task_collection_ref(arguments),
      "graph_id" => graph_ref(arguments, session),
      "path" => arguments["path"]
    }

    case workspace_action?(action_name, effect_scope) do
      true -> Map.put(refs, "workspace", workspace_ref(arguments, session))
      false -> refs
    end
    |> compact()
  end

  defp task_action?(action_name) do
    cond do
      action_name in @task_durable_actions -> true
      action_name in @read_only_actions -> true
      true -> false
    end
  end

  defp workspace_action?(action_name, effect_scope) do
    cond do
      effect_scope == "workspace_durable" -> true
      action_name in @workspace_read_actions -> true
      true -> false
    end
  end

  defp task_id_ref(arguments, session) do
    case arguments["task_id"] do
      value when value in [nil, ""] -> session["task_id"]
      task_id -> task_id
    end
  end

  defp task_ref(arguments, session) do
    case arguments["task_ref"] do
      value when value in [nil, ""] -> session["task_ref"]
      task_ref -> task_ref
    end
  end

  defp graph_ref(arguments, session) do
    case arguments["graph_id"] do
      value when value in [nil, ""] -> session["graph_id"]
      graph_id -> graph_id
    end
  end

  defp workspace_ref(arguments, session) do
    case arguments["workspace"] do
      value when value in [nil, ""] -> session_workspace(session)
      workspace -> workspace
    end
  end

  defp session_workspace(%{"workbench" => %{"workspace" => workspace}})
       when is_binary(workspace) and workspace != "" do
    workspace
  end

  defp session_workspace(%{"workspace" => workspace})
       when is_binary(workspace) and workspace != "",
       do: workspace

  defp session_workspace(_session), do: nil

  defp task_collection_ref(%{"title" => title}) when is_binary(title) and title != "",
    do: "workspace_tasks"

  defp task_collection_ref(_arguments), do: nil

  defp arguments_preview(arguments) do
    arguments
    |> Map.take([
      "ref",
      "task_id",
      "task_ref",
      "graph_id",
      "node_key",
      "path",
      "kind",
      "action",
      "action_group",
      "status",
      "title",
      "priority",
      "estimate"
    ])
    |> compact()
  end

  defp recovery_contract("read_only", _risk_level) do
    %{"reversibility" => "none_required", "requires_observation" => false}
  end

  defp recovery_contract("session_ephemeral", _risk_level) do
    %{"reversibility" => "overwrite_session_state", "requires_observation" => false}
  end

  defp recovery_contract(effect_scope, risk_level) do
    %{
      "reversibility" => recovery_reversibility(effect_scope),
      "requires_observation" => effect_scope not in ["read_only", "routed"],
      "risk_level" => risk_level
    }
    |> compact()
  end

  defp recovery_reversibility("task_durable"), do: "reversible_with_compensating_update"
  defp recovery_reversibility("session_ephemeral"), do: "overwrite_session_state"
  defp recovery_reversibility("agent_orchestration"), do: "cancel_or_mark_blocked"
  defp recovery_reversibility("workspace_durable"), do: "partially_reversible"
  defp recovery_reversibility("external_side_effect"), do: "possibly_irreversible"
  defp recovery_reversibility("routed"), do: "delegated_to_nested_contract"
  defp recovery_reversibility(_scope), do: "unknown"

  defp idempotency_key(action_name, target_refs, preview) do
    source =
      [
        action_name,
        stable_pairs(target_refs),
        stable_pairs(preview)
      ]
      |> List.flatten()
      |> Enum.join("|")

    digest =
      :crypto.hash(:sha256, source)
      |> Base.encode16(case: :lower)

    "action:" <> binary_part(digest, 0, 24)
  end

  defp stable_pairs(map) when is_map(map) do
    map
    |> Map.keys()
    |> Enum.sort()
    |> Enum.map(fn key -> "#{key}=#{stable_value(Map.get(map, key))}" end)
  end

  defp stable_pairs(_value), do: []

  defp stable_value(value) when is_map(value), do: stable_pairs(value) |> Enum.join(",")

  defp stable_value(value) when is_list(value),
    do: value |> Enum.map(&stable_value/1) |> Enum.join(",")

  defp stable_value(value), do: to_string(value)

  defp compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end
end
