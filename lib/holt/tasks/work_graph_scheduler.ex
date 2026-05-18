defmodule Holt.Tasks.WorkGraphScheduler do
  @moduledoc """
  Generic scheduler for typed task work graphs.

  It decides which graph nodes are ready, waiting, blocked, and complete using
  structured dependency, policy, repair, and verification state.
  """

  alias Holt.Clock

  @schema_version "holt_work_graph_schedule/v1"
  @complete_statuses ~w(completed done skipped passed approved verified satisfied)
  @blocked_statuses ~w(blocked failed rejected)
  @running_statuses ~w(running queued)
  @obsolete_top_level_keys ~w(graph task_graph)

  def schedule(attrs \\ %{})

  def schedule(attrs) when is_map(attrs) do
    case input(attrs) do
      {:ok, input} -> schedule_canonical(input)
      {:error, reason} -> rejected(reason)
    end
  end

  def schedule(_attrs), do: rejected("invalid_attrs")

  defp input(attrs) do
    with :ok <- canonical_attrs(attrs),
         :ok <- obsolete_arguments(attrs),
         :ok <- unsupported_arguments(attrs),
         {:ok, graph} <- work_graph(attrs),
         {:ok, policy_decision} <- optional_policy_decision(attrs),
         {:ok, verification_gate} <- optional_verification_gate(attrs),
         {:ok, repair_orchestration} <- optional_repair_orchestration(attrs),
         {:ok, completed_ids} <- completed_node_ids(attrs),
         {:ok, node_statuses} <- node_statuses(attrs) do
      {:ok,
       %{
         work_graph: graph,
         policy_decision: policy_decision,
         verification_gate: verification_gate,
         repair_orchestration: repair_orchestration,
         completed_node_ids: completed_ids,
         node_statuses: node_statuses
       }}
    end
  end

  defp schedule_canonical(input) do
    graph = input.work_graph
    policy_decision = input.policy_decision
    verification_gate = input.verification_gate
    repair_orchestration = input.repair_orchestration
    repair_hold? = repair_holds_resume?(repair_orchestration)
    approval_hold? = approval_holds_execution?(policy_decision)
    verification_hold? = verification_holds_finish?(verification_gate)

    annotated =
      Enum.map(graph["nodes"], fn node ->
        annotate_node(
          node,
          graph_edges(graph),
          input.completed_node_ids,
          input.node_statuses,
          repair_hold?
        )
      end)

    scheduled =
      Enum.map(annotated, fn node ->
        schedule_node(node, annotated, repair_hold?, approval_hold?, verification_hold?)
      end)

    ready = Enum.filter(scheduled, &schedule_status?(&1, "ready"))
    blocked = Enum.filter(scheduled, &schedule_status?(&1, "blocked"))
    waiting = Enum.filter(scheduled, &schedule_status?(&1, "waiting"))
    complete = Enum.filter(scheduled, &schedule_status?(&1, "completed"))

    %{
      "schema_version" => @schema_version,
      "schedule_id" =>
        stable_id("work_schedule", [
          graph["graph_id"],
          Enum.map(scheduled, &{&1["node_id"], &1["schedule_status"]}),
          policy_decision["decision_id"],
          repair_orchestration["repair_id"]
        ]),
      "graph_id" => graph["graph_id"],
      "status" => overall_status(ready, blocked, waiting, complete, scheduled),
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
    |> compact()
  end

  defp annotate_node(node, edges, completed_ids, node_statuses, repair_hold?) do
    node_id = node["node_id"]
    status = node_status(node, node_id, node_statuses, completed_ids)

    dependencies =
      edges
      |> Enum.reject(&inactive_repair_loop_edge?(&1, repair_hold?))
      |> Enum.filter(&edge_to?(&1, node_id))
      |> Enum.map(& &1["from"])
      |> Enum.concat(depends_on(node))
      |> Enum.uniq()

    node
    |> Map.put("current_status", status)
    |> Map.put("dependencies", dependencies)
  end

  defp inactive_repair_loop_edge?(%{"from" => "repair", "to" => "act"}, false), do: true
  defp inactive_repair_loop_edge?(_edge, _repair_hold?), do: false

  defp edge_to?(edge, node_id), do: edge["to"] == node_id

  defp node_status(node, node_id, node_statuses, completed_ids) do
    case Enum.member?(completed_ids, node_id) do
      true ->
        "completed"

      false ->
        status =
          case Map.fetch(node_statuses, node_id) do
            {:ok, value} -> value
            :error -> node["status"]
          end

        canonical_node_status(status)
    end
  end

  defp canonical_node_status(status) when status in @complete_statuses, do: "completed"
  defp canonical_node_status(status) when status in @blocked_statuses, do: "blocked"
  defp canonical_node_status(status) when status in @running_statuses, do: "running"
  defp canonical_node_status("waiting"), do: "waiting"
  defp canonical_node_status(_status), do: "pending"

  defp schedule_node(node, nodes, repair_hold?, approval_hold?, verification_hold?) do
    unmet = Enum.reject(node["dependencies"], &node_completed?(nodes, &1))
    phase = node["phase"]
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

  defp approval_holds_execution?(%{"action" => "approval_required"}), do: true
  defp approval_holds_execution?(_policy_decision), do: false

  defp repair_holds_resume?(%{
         "repair_required" => true,
         "resume_gate" => %{"can_resume" => false}
       }) do
    true
  end

  defp repair_holds_resume?(_repair_orchestration), do: false

  defp verification_holds_finish?(%{"status" => "blocked", "can_finish" => false}), do: true
  defp verification_holds_finish?(_verification_gate), do: false

  defp overall_status(_ready, blocked, _waiting, _complete, _scheduled) when blocked != [],
    do: "blocked"

  defp overall_status(ready, _blocked, _waiting, _complete, _scheduled) when ready != [],
    do: "ready"

  defp overall_status(_ready, _blocked, waiting, _complete, _scheduled) when waiting != [],
    do: "waiting"

  defp overall_status(_ready, _blocked, _waiting, complete, scheduled)
       when complete != [] and length(complete) == length(scheduled),
       do: "complete"

  defp overall_status(_ready, _blocked, _waiting, _complete, []), do: "empty"
  defp overall_status(_ready, _blocked, _waiting, _complete, _scheduled), do: "waiting"

  defp parallel_groups(ready_nodes) do
    ready_nodes
    |> Enum.group_by(&node_order/1)
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
      next_action(ready != [], "dispatch_ready_nodes"),
      next_action(blocked != [], "resolve_blocked_nodes"),
      next_action(waiting != [], "wait_for_dependencies_or_external_input"),
      next_action(repair_holds_resume?(repair_orchestration), "run_repair_or_escalate"),
      next_action(approval_holds_execution?(policy_decision), "request_human_approval")
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
  end

  defp next_action(true, action), do: action
  defp next_action(false, _action), do: nil

  defp node_summary(node) do
    %{
      "node_id" => node["node_id"],
      "node_key" => node["node_key"],
      "phase" => node["phase"],
      "role" => node["role"],
      "order" => node_order(node),
      "schedule_status" => node["schedule_status"],
      "schedule_reason" => node["schedule_reason"],
      "dependencies" => node["dependencies"],
      "unmet_dependencies" => node["unmet_dependencies"]
    }
    |> compact()
  end

  defp work_graph(attrs) do
    case Map.fetch(attrs, "work_graph") do
      {:ok, graph} when is_map(graph) ->
        with :ok <- validate_graph(graph) do
          {:ok, graph}
        end

      {:ok, _graph} ->
        {:error, "invalid_work_graph"}

      :error ->
        {:error, "missing_work_graph"}
    end
  end

  defp validate_graph(graph) do
    with {:ok, _graph_id} <- required_text(graph, "graph_id", "invalid_work_graph"),
         {:ok, nodes} <- required_list(graph, "nodes", "invalid_work_graph"),
         :ok <- validate_nodes(nodes),
         {:ok, edges} <- optional_edges(graph),
         :ok <- validate_edges(edges) do
      :ok
    end
  end

  defp validate_nodes(nodes) do
    case Enum.all?(nodes, &valid_node?/1) do
      true -> :ok
      false -> {:error, "invalid_work_graph"}
    end
  end

  defp valid_node?(node) when is_map(node) do
    with {:ok, _node_id} <- required_text(node, "node_id", "invalid_work_graph"),
         {:ok, _phase} <- required_text(node, "phase", "invalid_work_graph"),
         :ok <- optional_text_field(node, "node_key", "invalid_work_graph"),
         :ok <- optional_text_field(node, "role", "invalid_work_graph"),
         :ok <- optional_text_field(node, "status", "invalid_work_graph"),
         :ok <- optional_string_list(node, "depends_on", "invalid_work_graph"),
         :ok <- optional_number(node, "order", "invalid_work_graph") do
      true
    else
      _error -> false
    end
  end

  defp valid_node?(_node), do: false

  defp validate_edges(edges) do
    case Enum.all?(edges, &valid_edge?/1) do
      true -> :ok
      false -> {:error, "invalid_work_graph"}
    end
  end

  defp valid_edge?(edge) when is_map(edge) do
    with {:ok, _from} <- required_text(edge, "from", "invalid_work_graph"),
         {:ok, _to} <- required_text(edge, "to", "invalid_work_graph") do
      true
    else
      _error -> false
    end
  end

  defp valid_edge?(_edge), do: false

  defp graph_edges(graph) do
    case Map.fetch(graph, "edges") do
      {:ok, edges} when is_list(edges) -> edges
      {:ok, _edges} -> []
      :error -> []
    end
  end

  defp optional_edges(graph) do
    case Map.fetch(graph, "edges") do
      {:ok, edges} when is_list(edges) -> {:ok, edges}
      {:ok, _edges} -> {:error, "invalid_work_graph"}
      :error -> {:ok, []}
    end
  end

  defp optional_policy_decision(attrs) do
    case Map.fetch(attrs, "policy_decision") do
      {:ok, decision} when is_map(decision) ->
        with :ok <- validate_policy_decision(decision) do
          {:ok, decision}
        end

      {:ok, _decision} ->
        {:error, "invalid_policy_decision"}

      :error ->
        {:ok, %{}}
    end
  end

  defp validate_policy_decision(decision) do
    with :ok <- optional_text_field(decision, "decision_id", "invalid_policy_decision"),
         :ok <- optional_text_field(decision, "action", "invalid_policy_decision"),
         :ok <- optional_boolean(decision, "requires_approval", "invalid_policy_decision") do
      :ok
    end
  end

  defp optional_verification_gate(attrs) do
    case Map.fetch(attrs, "verification_gate") do
      {:ok, gate} when is_map(gate) ->
        with :ok <- validate_verification_gate(gate) do
          {:ok, gate}
        end

      {:ok, _gate} ->
        {:error, "invalid_verification_gate"}

      :error ->
        {:ok, %{}}
    end
  end

  defp validate_verification_gate(gate) do
    with :ok <- optional_text_field(gate, "status", "invalid_verification_gate"),
         :ok <- optional_boolean(gate, "can_finish", "invalid_verification_gate") do
      :ok
    end
  end

  defp optional_repair_orchestration(attrs) do
    case Map.fetch(attrs, "repair_orchestration") do
      {:ok, repair} when is_map(repair) ->
        with :ok <- validate_repair_orchestration(repair) do
          {:ok, repair}
        end

      {:ok, _repair} ->
        {:error, "invalid_repair_orchestration"}

      :error ->
        {:ok, %{}}
    end
  end

  defp validate_repair_orchestration(repair) do
    with :ok <- optional_text_field(repair, "repair_id", "invalid_repair_orchestration"),
         :ok <- optional_boolean(repair, "repair_required", "invalid_repair_orchestration"),
         :ok <- optional_resume_gate(repair) do
      :ok
    end
  end

  defp optional_resume_gate(repair) do
    case Map.fetch(repair, "resume_gate") do
      {:ok, gate} when is_map(gate) ->
        optional_boolean(gate, "can_resume", "invalid_repair_orchestration")

      {:ok, _gate} ->
        {:error, "invalid_repair_orchestration"}

      :error ->
        :ok
    end
  end

  defp completed_node_ids(attrs) do
    case Map.fetch(attrs, "completed_node_ids") do
      {:ok, values} when is_list(values) ->
        case Enum.all?(values, &nonempty_binary?/1) do
          true -> {:ok, values}
          false -> {:error, "invalid_completed_node_ids"}
        end

      {:ok, _values} ->
        {:error, "invalid_completed_node_ids"}

      :error ->
        {:ok, []}
    end
  end

  defp node_statuses(attrs) do
    case Map.fetch(attrs, "node_statuses") do
      {:ok, statuses} when is_map(statuses) ->
        validate_node_statuses(statuses)

      {:ok, _statuses} ->
        {:error, "invalid_node_statuses"}

      :error ->
        {:ok, %{}}
    end
  end

  defp validate_node_statuses(statuses) do
    case Enum.all?(statuses, fn {key, value} -> nonempty_binary?(key) and is_binary(value) end) do
      true -> {:ok, statuses}
      false -> {:error, "invalid_node_statuses"}
    end
  end

  defp schedule_status?(node, status), do: node["schedule_status"] == status

  defp depends_on(node) do
    case Map.fetch(node, "depends_on") do
      {:ok, values} -> values
      :error -> []
    end
  end

  defp node_order(%{"order" => order}) when is_integer(order), do: order
  defp node_order(%{"order" => order}) when is_float(order), do: order
  defp node_order(_node), do: 0

  defp obsolete_arguments(attrs) do
    attrs
    |> Map.keys()
    |> Enum.find(&obsolete_key?/1)
    |> obsolete_key_error()
  end

  defp obsolete_key?(key), do: key in @obsolete_top_level_keys

  defp obsolete_key_error(nil), do: :ok
  defp obsolete_key_error(key), do: {:error, "obsolete_key:" <> key}

  defp unsupported_arguments(attrs) do
    attrs
    |> Map.keys()
    |> Enum.find(&unsupported_key?/1)
    |> unsupported_key_error()
  end

  defp unsupported_key?("work_graph"), do: false
  defp unsupported_key?("policy_decision"), do: false
  defp unsupported_key?("verification_gate"), do: false
  defp unsupported_key?("repair_orchestration"), do: false
  defp unsupported_key?("completed_node_ids"), do: false
  defp unsupported_key?("node_statuses"), do: false
  defp unsupported_key?(_key), do: true

  defp unsupported_key_error(nil), do: :ok
  defp unsupported_key_error(key), do: {:error, "unsupported_argument:" <> key}

  defp canonical_attrs(attrs) do
    case canonical_value?(attrs) do
      true -> :ok
      false -> {:error, "invalid_attrs"}
    end
  end

  defp canonical_value?(value) when is_map(value) do
    Enum.all?(value, fn
      {key, nested} when is_binary(key) -> canonical_value?(nested)
      _entry -> false
    end)
  end

  defp canonical_value?(values) when is_list(values), do: Enum.all?(values, &canonical_value?/1)
  defp canonical_value?(_value), do: true

  defp required_list(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, value} when is_list(value) -> {:ok, value}
      {:ok, _value} -> {:error, reason}
      :error -> {:error, reason}
    end
  end

  defp required_text(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, reason}
          text -> {:ok, text}
        end

      {:ok, _value} ->
        {:error, reason}

      :error ->
        {:error, reason}
    end
  end

  defp optional_text_field(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, reason}
          _text -> :ok
        end

      {:ok, _value} ->
        {:error, reason}

      :error ->
        :ok
    end
  end

  defp optional_string_list(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, values} when is_list(values) ->
        case Enum.all?(values, &nonempty_binary?/1) do
          true -> :ok
          false -> {:error, reason}
        end

      {:ok, _values} ->
        {:error, reason}

      :error ->
        :ok
    end
  end

  defp optional_number(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, value} when is_integer(value) -> :ok
      {:ok, value} when is_float(value) -> :ok
      {:ok, _value} -> {:error, reason}
      :error -> :ok
    end
  end

  defp optional_boolean(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, value} when is_boolean(value) -> :ok
      {:ok, _value} -> {:error, reason}
      :error -> :ok
    end
  end

  defp nonempty_binary?(value) when is_binary(value), do: String.trim(value) != ""
  defp nonempty_binary?(_value), do: false

  defp rejected(reason) do
    %{
      "schema_version" => @schema_version,
      "status" => "rejected",
      "reason" => reason,
      "scheduled_at" => Clock.iso_now()
    }
  end

  defp compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
    |> Map.new()
  end

  defp blank?(value), do: value in [nil, "", [], %{}]

  defp stable_id(prefix, parts) do
    digest =
      :crypto.hash(:sha256, :erlang.term_to_binary(parts))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 24)

    "#{prefix}_#{digest}"
  end
end
