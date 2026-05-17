defmodule HoltWorks.Tasks.WorkGraphScheduler do
  @moduledoc """
  Generic scheduler for typed task work graphs.

  It decides which graph nodes are ready, waiting, blocked, or complete using
  structured dependency, policy, repair, and verification state.
  """

  alias HoltWorks.{Clock}
  alias HoltWorks.Tasks.RuntimeContracts

  @schema_version "holtworks_work_graph_schedule/v1"
  @complete_statuses ~w(completed done skipped passed approved verified satisfied)
  @blocked_statuses ~w(blocked failed rejected)
  @running_statuses ~w(running queued)

  def schedule(attrs \\ %{})

  def schedule(attrs) when is_map(attrs) do
    attrs = RuntimeContracts.string_keys(attrs)

    graph =
      RuntimeContracts.normalize_map(attrs["work_graph"] || attrs["graph"] || attrs["task_graph"])

    policy_decision = RuntimeContracts.normalize_map(attrs["policy_decision"])

    verification_gate =
      RuntimeContracts.normalize_map(
        attrs["verification_gate"] || graph["completion_gate"] || graph["mission_control"]
      )

    repair_orchestration = RuntimeContracts.normalize_map(attrs["repair_orchestration"])
    completed_ids = RuntimeContracts.normalize_string_list(attrs["completed_node_ids"])
    node_statuses = RuntimeContracts.normalize_map(attrs["node_statuses"])
    nodes = normalize_nodes(graph["nodes"])
    edges = normalize_edges(graph["edges"])
    approval_hold? = approval_holds_execution?(policy_decision)
    repair_hold? = repair_holds_resume?(repair_orchestration)
    verification_hold? = verification_holds_finish?(verification_gate)

    annotated =
      Enum.map(nodes, fn node ->
        annotate_node(node, edges, completed_ids, node_statuses, repair_hold?)
      end)

    scheduled =
      Enum.map(annotated, fn node ->
        schedule_node(node, annotated, repair_hold?, approval_hold?, verification_hold?)
      end)

    ready = Enum.filter(scheduled, &(RuntimeContracts.value(&1, "schedule_status") == "ready"))

    blocked =
      Enum.filter(scheduled, &(RuntimeContracts.value(&1, "schedule_status") == "blocked"))

    waiting =
      Enum.filter(scheduled, &(RuntimeContracts.value(&1, "schedule_status") == "waiting"))

    complete =
      Enum.filter(scheduled, &(RuntimeContracts.value(&1, "schedule_status") == "completed"))

    %{
      "schema_version" => @schema_version,
      "schedule_id" =>
        RuntimeContracts.stable_id("work_schedule", [
          graph_id(graph),
          Enum.map(scheduled, &{&1["node_id"], &1["schedule_status"]}),
          policy_decision["decision_id"],
          repair_orchestration["repair_id"]
        ]),
      "graph_id" => graph_id(graph),
      "status" => schedule_status(ready, blocked, waiting, complete, scheduled),
      "ready_nodes" => Enum.map(ready, &node_summary/1),
      "waiting_nodes" => Enum.map(waiting, &node_summary/1),
      "blocked_nodes" => Enum.map(blocked, &node_summary/1),
      "completed_nodes" => Enum.map(complete, &node_summary/1),
      "parallel_groups" => parallel_groups(ready),
      "next_actions" =>
        next_actions(ready, blocked, waiting, repair_orchestration, policy_decision),
      "policy_hold" => approval_hold?,
      "repair_hold" => repair_hold?,
      "verification_hold" => verification_hold?,
      "scheduled_at" => Clock.iso_now()
    }
    |> RuntimeContracts.reject_empty()
  end

  def schedule(_attrs), do: schedule(%{})

  defp annotate_node(node, edges, completed_ids, node_statuses, repair_hold?) do
    node_id = node_id(node)
    status = node_status(node, node_id, node_statuses, completed_ids)

    dependencies =
      edges
      |> Enum.reject(&inactive_repair_loop_edge?(&1, repair_hold?))
      |> Enum.filter(&(RuntimeContracts.value(&1, "to") == node_id))
      |> Enum.map(&RuntimeContracts.value(&1, "from"))
      |> Enum.concat(RuntimeContracts.normalize_string_list(node["depends_on"]))
      |> Enum.reject(&blank?/1)
      |> Enum.uniq()

    node
    |> Map.put("node_id", node_id)
    |> Map.put("current_status", status)
    |> Map.put("dependencies", dependencies)
  end

  defp inactive_repair_loop_edge?(edge, false) do
    RuntimeContracts.value(edge, "from") == "repair" and
      RuntimeContracts.value(edge, "to") == "act"
  end

  defp inactive_repair_loop_edge?(_edge, _repair_hold?), do: false

  defp node_status(node, node_id, node_statuses, completed_ids) do
    status =
      RuntimeContracts.value(node_statuses, node_id) || RuntimeContracts.value(node, "status")

    cond do
      node_id in completed_ids -> "completed"
      status in @complete_statuses -> "completed"
      status in @blocked_statuses -> "blocked"
      status in @running_statuses -> "running"
      status == "waiting" -> "waiting"
      true -> "pending"
    end
  end

  defp schedule_node(node, nodes, repair_hold?, approval_hold?, verification_hold?) do
    deps = node["dependencies"] || []
    unmet = Enum.reject(deps, &node_completed?(nodes, &1))
    phase = node_phase(node)
    current_status = node["current_status"]

    {schedule_status, reason} =
      cond do
        current_status == "completed" ->
          {"completed", "node_already_completed"}

        current_status == "blocked" ->
          {"blocked", "node_blocked"}

        current_status == "running" ->
          {"waiting", "node_already_running"}

        unmet != [] ->
          {"waiting", "waiting_for_dependencies"}

        approval_hold? and phase in ["act", "work", "external_side_effect"] ->
          {"waiting", "waiting_for_human_approval"}

        repair_hold? and phase in ["act", "work"] ->
          {"blocked", "repair_resume_gate_not_satisfied"}

        verification_hold? and phase in ["integration", "finish"] ->
          {"waiting", "waiting_for_verification"}

        true ->
          {"ready", "dependencies_satisfied"}
      end

    node
    |> Map.put("schedule_status", schedule_status)
    |> Map.put("schedule_reason", reason)
    |> Map.put("unmet_dependencies", unmet)
  end

  defp node_completed?(nodes, node_id) do
    Enum.any?(nodes, fn node ->
      node["node_id"] == node_id and node["current_status"] == "completed"
    end)
  end

  defp approval_holds_execution?(policy_decision) do
    RuntimeContracts.value(policy_decision, "action") == "approval_required" or
      RuntimeContracts.truthy?(RuntimeContracts.value(policy_decision, "requires_approval"))
  end

  defp repair_holds_resume?(repair_orchestration) do
    resume_gate = RuntimeContracts.normalize_map(repair_orchestration["resume_gate"])

    RuntimeContracts.truthy?(repair_orchestration["repair_required"]) and
      not RuntimeContracts.truthy?(resume_gate["can_resume"])
  end

  defp verification_holds_finish?(verification_gate) do
    RuntimeContracts.truthy?(verification_gate["required"]) and
      not (RuntimeContracts.truthy?(verification_gate["satisfied"]) or
             RuntimeContracts.truthy?(verification_gate["can_finish"]))
  end

  defp schedule_status(_ready, blocked, _waiting, _complete, _scheduled) when blocked != [],
    do: "blocked"

  defp schedule_status(ready, _blocked, _waiting, _complete, _scheduled) when ready != [],
    do: "ready"

  defp schedule_status(_ready, _blocked, waiting, _complete, _scheduled) when waiting != [],
    do: "waiting"

  defp schedule_status(_ready, _blocked, _waiting, complete, scheduled)
       when complete != [] and length(complete) == length(scheduled),
       do: "complete"

  defp schedule_status(_ready, _blocked, _waiting, _complete, []), do: "empty"
  defp schedule_status(_ready, _blocked, _waiting, _complete, _scheduled), do: "waiting"

  defp parallel_groups(ready_nodes) do
    ready_nodes
    |> Enum.group_by(&(&1["order"] || &1["position"] || 0))
    |> Enum.sort_by(fn {order, _nodes} -> order end)
    |> Enum.map(fn {order, nodes} ->
      %{
        "group_id" => "parallel_group_#{order}",
        "order" => order,
        "node_ids" => Enum.map(nodes, & &1["node_id"]),
        "can_run_in_parallel" => length(nodes) > 1
      }
    end)
  end

  defp next_actions(ready, blocked, waiting, repair_orchestration, policy_decision) do
    [
      if(ready != [], do: "dispatch_ready_nodes"),
      if(blocked != [], do: "resolve_blocked_nodes"),
      if(waiting != [], do: "wait_for_dependencies_or_external_input"),
      if(repair_holds_resume?(repair_orchestration), do: "run_repair_or_escalate"),
      if(approval_holds_execution?(policy_decision), do: "request_human_approval")
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
  end

  defp node_summary(node) do
    %{
      "node_id" => node["node_id"],
      "node_key" => node["node_key"],
      "phase" => node_phase(node),
      "role" => node["role"],
      "order" => node["order"] || node["position"],
      "schedule_status" => node["schedule_status"],
      "schedule_reason" => node["schedule_reason"],
      "dependencies" => node["dependencies"] || [],
      "unmet_dependencies" => node["unmet_dependencies"] || []
    }
    |> RuntimeContracts.reject_empty()
  end

  defp normalize_nodes(nodes) when is_list(nodes) do
    nodes
    |> Enum.filter(&is_map/1)
    |> Enum.map(&RuntimeContracts.string_keys/1)
  end

  defp normalize_nodes(_nodes), do: []

  defp normalize_edges(edges) when is_list(edges) do
    edges
    |> Enum.filter(&is_map/1)
    |> Enum.map(&RuntimeContracts.string_keys/1)
  end

  defp normalize_edges(_edges), do: []

  defp node_id(node), do: node["node_id"] || node["id"] || node["node_key"] || node["phase"]

  defp node_phase(node), do: node["phase"] || node["node_type"] || node["kind"]

  defp graph_id(graph), do: graph["graph_id"] || graph["id"]

  defp blank?(value), do: value in [nil, "", [], %{}]
end
