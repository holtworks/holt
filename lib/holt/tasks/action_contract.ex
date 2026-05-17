defmodule Holt.Tasks.ActionContract do
  @moduledoc """
  Structured contract for one task-scoped tool action.

  The contract is durable policy input for routers, plan gates, and preflight
  checks. It describes the effect class, target references, recovery posture,
  and idempotency key without executing the tool.
  """

  alias Holt.{Clock, Tools}
  alias Holt.Tasks.TaskToolSession

  @schema_version "holtworks_action_contract/v1"

  @task_durable_tools ~w(
    create_task update_task set_priority set_estimate
    add_comment delete_comment add_label remove_label add_link remove_link
    save_task_spec save_teammate_memory route_verification_review
    create_task_graph advance_task_graph complete_task_graph_node save_memory
    remember_about_user forget_about_user remember_for_project save_plan save_research
    action_approval_request resolve_action_approval_request action_evidence_ledger
    record_task_memory_artifact task_memory_context context_budget continuation_packet
    verifier_calibration
  )
  @agent_orchestration_tools ~w(
    start_agent_work continue_agent_work watchdog_agent_runs plan_verifier_route
    verifier_dispatch
  )
  @session_ephemeral_tools ~w(todo_read todo_write)
  @read_only_tools ~w(
    list_tasks get_task list_task_specs get_task_spec read_task_memory_artifact
    load_teammate_runtime get_evidence_contract list_task_graphs get_task_graph
    search_memory search_tools get_tool_schema ask_user
    list_user_memories search_user_memory recall_project_memory read_project_memory
    manage_connection
    action_contract plan_contract plan_gate action_preflight
    consequence_gate action_runtime_envelope complete_action_runtime_envelope
    capability_registry capability_contract capability_route generic_plan
    work_graph work_graph_gate work_graph_budget work_graph_schedule
    agent_dispatch_plan team_orchestration child_agent_contract
    verification_contract verifier_assignment
  )
  @workspace_durable_tools ~w(write_file append_file run_command)
  @workspace_read_tools ~w(list_files read_file search_files)
  @network_tools ~w(fetch_url search_web)
  @meta_tools ~w(execute_tool multi_execute_tool use_workbench)
  @known_effect_scopes ~w(
    read_only session_ephemeral task_durable agent_orchestration workspace_durable external_side_effect routed
  )

  def build(attrs \\ %{})

  def build(attrs) when is_map(attrs) do
    attrs = string_keys(attrs)
    tool_name = optional_text(attrs, "tool_name", optional_text(attrs, "name", "unknown"))
    arguments = normalize_map(value(attrs, "arguments"))
    session = task_tool_session(attrs)
    effect_scope = effect_scope(tool_name)
    risk_level = risk_level(tool_name, effect_scope)
    target_refs = target_refs(arguments, session)
    preview = arguments_preview(arguments)

    %{
      "schema_version" => @schema_version,
      "contract_id" => optional_text(attrs, "contract_id", Clock.id("action_contract")),
      "tool_name" => tool_name,
      "tool_call_id" => optional_text(attrs, "tool_call_id"),
      "effect_scope" => effect_scope,
      "risk_level" => risk_level,
      "target_domain" => target_domain(tool_name, effect_scope),
      "target_refs" => target_refs,
      "arguments_preview" => preview,
      "recovery" => recovery_contract(effect_scope, risk_level),
      "idempotency_key" => idempotency_key(tool_name, target_refs, preview),
      "created_at" => optional_text(attrs, "created_at", Clock.iso_now())
    }
    |> reject_empty()
  end

  def build(_attrs), do: build(%{})

  def effect_scope(tool_name) when tool_name in @read_only_tools, do: "read_only"
  def effect_scope(tool_name) when tool_name in @workspace_read_tools, do: "read_only"
  def effect_scope(tool_name) when tool_name in @session_ephemeral_tools, do: "session_ephemeral"
  def effect_scope(tool_name) when tool_name in @task_durable_tools, do: "task_durable"

  def effect_scope(tool_name) when tool_name in @agent_orchestration_tools,
    do: "agent_orchestration"

  def effect_scope(tool_name) when tool_name in @workspace_durable_tools, do: "workspace_durable"
  def effect_scope(tool_name) when tool_name in @network_tools, do: "external_side_effect"
  def effect_scope(tool_name) when tool_name in @meta_tools, do: "routed"

  def effect_scope(tool_name) do
    case Tools.get(tool_name) do
      %{"risk" => "read"} -> "read_only"
      %{"risk" => "write"} -> "workspace_durable"
      %{"risk" => "execute"} -> "workspace_durable"
      %{"risk" => "network"} -> "external_side_effect"
      _tool -> "unknown"
    end
  end

  def known_effect_scope?(scope), do: scope in @known_effect_scopes

  def mutating_effect_scope?(scope) do
    scope in ["task_durable", "agent_orchestration", "workspace_durable", "external_side_effect"]
  end

  def requires_approval?(%{"effect_scope" => scope, "risk_level" => risk}) do
    scope in ["workspace_durable", "external_side_effect"] or risk in ["high", "critical"]
  end

  def requires_approval?(_contract), do: false

  defp task_tool_session(attrs) do
    case value(attrs, "task_tool_session") || value(attrs, "session") do
      session when is_map(session) -> TaskToolSession.build(session)
      _missing -> TaskToolSession.build(attrs)
    end
  end

  defp risk_level(tool_name, _effect_scope) do
    case Tools.get(tool_name) do
      %{"risk" => "read"} -> "low"
      %{"risk" => "write"} -> "medium"
      %{"risk" => "execute"} -> "high"
      %{"risk" => "network"} -> "high"
      _tool -> fallback_risk(effect_scope(tool_name))
    end
  end

  defp fallback_risk("read_only"), do: "low"
  defp fallback_risk("session_ephemeral"), do: "low"
  defp fallback_risk("task_durable"), do: "medium"
  defp fallback_risk("agent_orchestration"), do: "medium"
  defp fallback_risk("workspace_durable"), do: "high"
  defp fallback_risk("external_side_effect"), do: "high"
  defp fallback_risk("routed"), do: "medium"
  defp fallback_risk(_scope), do: "unknown"

  defp target_domain(tool_name, effect_scope) do
    cond do
      tool_name == "manage_connection" ->
        "connected_accounts"

      tool_name == "use_workbench" ->
        "workbench"

      tool_name in @task_durable_tools or tool_name in @read_only_tools ->
        "task"

      effect_scope == "session_ephemeral" ->
        "session_state"

      effect_scope == "agent_orchestration" ->
        "agent_work"

      effect_scope == "workspace_durable" or tool_name in @workspace_read_tools ->
        "workspace"

      effect_scope == "external_side_effect" ->
        "external_network"

      effect_scope == "routed" ->
        "task_tool_router"

      true ->
        "unknown"
    end
  end

  defp target_refs(arguments, session) do
    %{
      "task_id" => value(arguments, "task_id") || value(arguments, "ref") || session["task_id"],
      "task_ref" =>
        value(arguments, "task_ref") || value(arguments, "ref") || session["task_ref"],
      "task_collection" => task_collection_ref(arguments),
      "graph_id" => value(arguments, "graph_id") || session["graph_id"],
      "path" => value(arguments, "path")
    }
    |> reject_empty()
  end

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
      "toolkit",
      "tool_name",
      "status",
      "title",
      "priority",
      "estimate"
    ])
    |> reject_empty()
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
    |> reject_empty()
  end

  defp recovery_reversibility("task_durable"), do: "reversible_with_compensating_update"
  defp recovery_reversibility("session_ephemeral"), do: "overwrite_session_state"
  defp recovery_reversibility("agent_orchestration"), do: "cancel_or_mark_blocked"
  defp recovery_reversibility("workspace_durable"), do: "partially_reversible"
  defp recovery_reversibility("external_side_effect"), do: "possibly_irreversible"
  defp recovery_reversibility("routed"), do: "delegated_to_nested_contract"
  defp recovery_reversibility(_scope), do: "unknown"

  defp idempotency_key(tool_name, target_refs, preview) do
    source =
      [
        tool_name,
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

  defp normalize_map(value) when is_map(value), do: string_keys(value)
  defp normalize_map(_value), do: %{}

  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp value(_map, _key), do: nil

  defp optional_text(attrs, key, default \\ nil)

  defp optional_text(attrs, key, default) when is_map(attrs) do
    case Map.get(attrs, key, default) do
      nil ->
        default

      value ->
        text = value |> to_string() |> String.trim()
        if text == "", do: default, else: text
    end
  end

  defp optional_text(_attrs, _key, default), do: default

  defp string_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), normalize_value(value)}
      {key, value} -> {to_string(key), normalize_value(value)}
    end)
  end

  defp string_keys(_value), do: %{}

  defp normalize_value(value) when is_map(value), do: string_keys(value)
  defp normalize_value(value) when is_list(value), do: Enum.map(value, &normalize_value/1)
  defp normalize_value(value), do: value

  defp reject_empty(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end
end
