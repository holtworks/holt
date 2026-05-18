defmodule Holt.Tasks.WorkGraph do
  @moduledoc """
  Derived task-agent work graph for one task boundary.

  The graph can be built from Holt task graphs, agent work records, agent
  run events, child-agent contracts, verification gates, and prediction errors.
  It gives the runtime a small DAG that can be scheduled and used as a
  completion gate.
  """

  alias Holt.Clock

  @schema_version "holt_work_graph/v1"
  @gate_schema_version "holt_work_graph_completion_gate/v1"
  @complete_statuses ~w(completed done skipped passed approved verified satisfied)
  @blocked_statuses ~w(blocked failed rejected)
  @severe_prediction_error_levels ~w(medium high critical)
  @obsolete_build_keys ~w(graph child_contracts)
  @obsolete_completion_gate_keys ~w(graph)

  def build(attrs \\ %{})

  def build(attrs) when is_map(attrs) do
    case obsolete_key(attrs, @obsolete_build_keys) do
      nil -> build_graph(attrs)
      key -> rejected_graph("obsolete_key:#{key}")
    end
  end

  def build(_attrs), do: rejected_graph("invalid_attrs")

  defp build_graph(attrs) do
    task = map_field(attrs, "task")
    task_graph = map_field(attrs, "task_graph")
    verification_gate = map_field(attrs, "verification_gate")

    events = normalize_events(attrs["events"])
    agent_runs = normalize_list(attrs["agent_runs"])
    child_contracts = child_contracts(attrs, events)
    child_completions = child_completions(events, agent_runs)
    prediction_errors = severe_prediction_errors(attrs, events)

    nodes =
      cond do
        task_graph["nodes"] not in [nil, []] ->
          task_graph_nodes(task_graph)

        child_contracts != [] ->
          derived_nodes(task, attrs, child_contracts, child_completions, verification_gate)

        true ->
          agent_work_nodes(task, agent_runs, verification_gate)
      end

    edges = graph_edges(nodes, task_graph["edges"])
    metrics = metrics(nodes, edges, prediction_errors, verification_gate)

    graph =
      %{
        "schema_version" => @schema_version,
        "graph_id" =>
          stable_id("work_graph", [
            task["id"],
            task_graph["id"],
            Enum.map(nodes, & &1["node_id"]),
            verification_gate["status"]
          ]),
        "task_id" => task["id"],
        "task_ref" => task["ref"],
        "task_graph_id" => task_graph["id"],
        "status" => graph_status(nodes, metrics, verification_gate),
        "nodes" => nodes,
        "edges" => edges,
        "metrics" => metrics,
        "source" => graph_source(task_graph, child_contracts, agent_runs),
        "generated_at" => Clock.iso_now()
      }
      |> compact()

    Map.put(
      graph,
      "completion_gate",
      completion_gate(%{"work_graph" => graph, "verification_gate" => verification_gate})
    )
  end

  def completion_gate(attrs \\ %{})

  def completion_gate(attrs) when is_map(attrs) do
    case obsolete_key(attrs, @obsolete_completion_gate_keys) do
      nil -> build_completion_gate(attrs)
      key -> rejected_gate("obsolete_key:#{key}")
    end
  end

  def completion_gate(_attrs), do: rejected_gate("invalid_attrs")

  defp build_completion_gate(attrs) do
    graph = map_field(attrs, "work_graph")
    verification_gate = map_field(attrs, "verification_gate")
    metrics = map_field(graph, "metrics")
    nodes = normalize_list(graph["nodes"])
    blockers = completion_blockers(graph, nodes, verification_gate, metrics)

    %{
      "schema_version" => @gate_schema_version,
      "status" => if(blockers == [], do: "approved", else: "blocked"),
      "can_finish" => blockers == [],
      "enforced" => enforceable_graph?(graph),
      "blockers" => blockers,
      "node_count" => metric_count(metrics, "node_count", length(nodes)),
      "worker_contract_count" => metric_count(metrics, "worker_contract_count"),
      "verifier_contract_count" => metric_count(metrics, "verifier_contract_count"),
      "completed_child_contract_count" => metric_count(metrics, "completed_child_contract_count"),
      "severe_prediction_error_count" => metric_count(metrics, "severe_prediction_error_count"),
      "verification_gate_status" => verification_gate["status"],
      "verification_satisfied" => verification_satisfied?(verification_gate),
      "evaluated_at" => Clock.iso_now()
    }
    |> compact()
  end

  defp task_graph_nodes(task_graph) do
    task_graph
    |> Map.get("nodes")
    |> normalize_list()
    |> Enum.map(fn node ->
      %{
        "node_id" => node["id"],
        "id" => node["id"],
        "node_key" => node["node_key"],
        "task_graph_node_id" => node["id"],
        "kind" => node["kind"],
        "phase" => node["kind"],
        "role" => task_graph_role(node),
        "status" => normalize_status(node["status"]),
        "source_status" => node["status"],
        "label" => node["label"],
        "position" => node["position"],
        "order" => node["position"],
        "depends_on" => string_list_field(node, "depends_on"),
        "required" => node["required"] != false,
        "agent_id" => node["agent_id"],
        "agent_work_id" => node["agent_work_id"],
        "agent_run_id" => node["agent_run_id"],
        "run_id" => node["run_id"],
        "verification_gate" => map_field(node, "verification_gate"),
        "completed_at" => node["completed_at"]
      }
      |> compact()
    end)
    |> Enum.reject(&(&1["node_id"] in [nil, ""]))
  end

  defp derived_nodes(task, attrs, child_contracts, child_completions, verification_gate) do
    [
      plan_node(attrs),
      Enum.map(child_contracts, &child_node(&1, child_completions)),
      verifier_node(verification_gate),
      integration_node(task)
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  defp plan_node(attrs) do
    plan = map_field(attrs, "plan_contract")

    if plan == %{} do
      nil
    else
      %{
        "node_id" => "plan:#{plan["plan_id"]}",
        "kind" => "plan",
        "phase" => "plan",
        "status" => normalize_status(plan_status(plan)),
        "role" => "planner",
        "plan_id" => plan["plan_id"],
        "label" => "Active plan contract",
        "order" => 0
      }
      |> compact()
    end
  end

  defp plan_status(%{"status" => status}) when is_binary(status), do: status
  defp plan_status(_plan), do: "active"

  defp child_node(contract, child_completions) do
    child = map_field(contract, "child")
    parent = map_field(contract, "parent")
    verification_contract = map_field(contract, "verification_contract")
    contract_id = contract["child_contract_id"]

    if contract_id in [nil, ""] do
      nil
    else
      completion = child_completion(child_completions, contract_id)
      role = role(child)

      %{
        "node_id" => "child:#{contract_id}",
        "kind" => "child_agent",
        "phase" => if(role == "verifier", do: "verify", else: "work"),
        "status" => if(completion, do: "completed", else: "running"),
        "role" => role,
        "child_contract_id" => contract_id,
        "action_call_id" => contract["action_call_id"],
        "child_ref" => child["child_ref"],
        "target_agent_id" => child["target_agent_id"],
        "target_skill" => child["target_skill"],
        "parent_agent_id" => parent["agent_id"],
        "requires_verifier" => verification_contract["verifier_required"] == true,
        "child_session_id" => completion_value(completion, "child_session_id"),
        "completed_at" => completion_value(completion, "inserted_at"),
        "label" => child_label(role, child)
      }
      |> compact()
    end
  end

  defp child_completion(child_completions, contract_id) do
    Map.get(child_completions.by_contract_id, contract_id)
  end

  defp role(%{"work_role" => role}) when is_binary(role) and role != "", do: role
  defp role(_child), do: "worker"

  defp task_graph_role(%{"role" => role}) when is_binary(role) and role != "",
    do: role

  defp task_graph_role(%{"kind" => kind}), do: role_for_kind(kind)
  defp task_graph_role(_node), do: "worker"

  defp child_label(role, child) do
    case child["child_ref"] do
      value when is_binary(value) and value != "" -> "#{role}: #{value}"
      _missing -> child_label_for_agent(role, child["target_agent_id"])
    end
  end

  defp child_label_for_agent(role, agent_id) when is_binary(agent_id) and agent_id != "",
    do: "#{role}: #{agent_id}"

  defp child_label_for_agent(role, _agent_id), do: "#{role}: child"

  defp verifier_node(gate) when gate == %{}, do: nil

  defp verifier_node(gate) do
    cond do
      verification_satisfied?(gate) ->
        %{
          "node_id" => "verifier:route_verification_review",
          "kind" => "verification",
          "phase" => "verify",
          "status" => "completed",
          "role" => "verifier",
          "verification_status" => gate["status"],
          "label" => "Route verification review",
          "order" => 2
        }

      true ->
        %{
          "node_id" => "verifier:route_verification_review",
          "kind" => "verification",
          "phase" => "verify",
          "status" => "pending",
          "role" => "verifier",
          "verification_status" => gate["status"],
          "label" => "Route verification review",
          "order" => 2
        }
    end
    |> compact()
  end

  defp integration_node(task) do
    %{
      "node_id" => "integration:parent",
      "kind" => "integration",
      "phase" => "integration",
      "status" => normalize_status(task["status"]),
      "role" => "integrator",
      "label" => "Parent integration decision",
      "order" => 3
    }
    |> compact()
  end

  defp agent_work_nodes(task, agent_runs, verification_gate) do
    work_nodes =
      agent_runs
      |> Enum.map(fn run ->
        %{
          "node_id" => agent_run_node_id(run),
          "kind" => "child_agent",
          "phase" => "work",
          "status" => normalize_status(run["lifecycle_state"]),
          "role" => agent_run_role(run),
          "agent_id" => run["agent_id"],
          "agent_run_id" => run["id"],
          "run_id" => run["run_id"],
          "label" => agent_run_label(run),
          "order" => 1
        }
        |> compact()
      end)
      |> Enum.reject(&(&1["node_id"] in [nil, ""]))

    [
      work_nodes,
      verifier_node(verification_gate),
      integration_node(task)
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  defp agent_run_node_id(%{"id" => id}) when is_binary(id) and id != "",
    do: "agent_run:#{id}"

  defp agent_run_node_id(_run), do: nil

  defp agent_run_role(%{"work_role" => role}) when is_binary(role) and role != "",
    do: role

  defp agent_run_role(_run), do: "worker"

  defp agent_run_label(%{"agent_id" => agent_id}) when is_binary(agent_id) and agent_id != "",
    do: "agent: #{agent_id}"

  defp agent_run_label(_run), do: "agent"

  defp graph_edges(nodes, task_graph_edges)
       when is_list(task_graph_edges) and task_graph_edges != [] do
    node_refs =
      nodes
      |> Enum.flat_map(fn node ->
        [
          {node["task_graph_node_id"], node["node_id"]},
          {node["node_key"], node["node_id"]},
          {node["id"], node["node_id"]},
          {node["node_id"], node["node_id"]}
        ]
      end)
      |> Enum.reject(&invalid_ref_pair?/1)
      |> Map.new()

    task_graph_edges
    |> normalize_list()
    |> Enum.map(fn edge ->
      %{
        "from" => Map.get(node_refs, edge["from"], edge["from"]),
        "to" => Map.get(node_refs, edge["to"], edge["to"]),
        "type" => graph_edge_type(edge)
      }
      |> compact()
    end)
    |> Enum.reject(&invalid_edge?/1)
    |> Enum.uniq()
  end

  defp graph_edges(nodes, _task_graph_edges) do
    node_refs =
      nodes
      |> Enum.flat_map(fn node ->
        [{node["node_id"], node["node_id"]}, {node["node_key"], node["node_id"]}]
      end)
      |> Enum.reject(&invalid_ref_pair?/1)
      |> Map.new()

    explicit =
      Enum.flat_map(nodes, fn node ->
        node
        |> string_list_field("depends_on")
        |> Enum.flat_map(fn dependency ->
          case Map.get(node_refs, dependency) do
            nil -> []
            from_id -> [edge(from_id, node["node_id"], edge_type(node["kind"]))]
          end
        end)
      end)

    if explicit == [] do
      inferred_edges(nodes)
    else
      explicit
    end
  end

  defp invalid_ref_pair?({key, _value}) when key in [nil, ""], do: true
  defp invalid_ref_pair?({_key, value}) when value in [nil, ""], do: true
  defp invalid_ref_pair?(_pair), do: false

  defp graph_edge_type(%{"type" => type}) when is_binary(type) and type != "",
    do: type

  defp graph_edge_type(_edge), do: "depends_on"

  defp invalid_edge?(%{"from" => from}) when from in [nil, ""], do: true
  defp invalid_edge?(%{"to" => to}) when to in [nil, ""], do: true
  defp invalid_edge?(_edge), do: false

  defp inferred_edges(nodes) do
    plan = Enum.find(nodes, &(&1["kind"] == "plan"))
    child_nodes = Enum.filter(nodes, &(&1["kind"] == "child_agent"))
    worker_nodes = Enum.filter(child_nodes, &(&1["role"] != "verifier"))

    verifier_nodes = Enum.filter(nodes, &verifier_node?/1)

    integration = Enum.find(nodes, &(&1["kind"] == "integration"))

    plan_edges =
      if plan do
        Enum.map(child_nodes, &edge(plan["node_id"], &1["node_id"], "authorizes"))
      else
        []
      end

    verification_edges =
      for worker <- worker_nodes,
          verifier <- verifier_nodes,
          verifier["node_id"] != worker["node_id"] do
        edge(worker["node_id"], verifier["node_id"], "requires_verification")
      end

    integration_sources =
      case verifier_nodes do
        [] -> child_nodes
        list -> list
      end

    integration_edges =
      if integration do
        Enum.map(
          integration_sources,
          &edge(&1["node_id"], integration["node_id"], "feeds_integration")
        )
      else
        []
      end

    (plan_edges ++ verification_edges ++ integration_edges)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp edge(nil, _to, _type), do: nil
  defp edge(_from, nil, _type), do: nil
  defp edge(from, to, type), do: %{"from" => from, "to" => to, "type" => type}

  defp edge_type("verification"), do: "requires_verification"
  defp edge_type("integration"), do: "feeds_integration"
  defp edge_type(_kind), do: "depends_on"

  defp verifier_node?(%{"kind" => "verification"}), do: true
  defp verifier_node?(%{"role" => "verifier"}), do: true
  defp verifier_node?(_node), do: false

  defp metrics(nodes, edges, prediction_errors, verification_gate) do
    child_nodes = Enum.filter(nodes, &(&1["kind"] == "child_agent"))
    worker_nodes = Enum.filter(child_nodes, &(&1["role"] != "verifier"))
    verifier_nodes = Enum.filter(child_nodes, &(&1["role"] == "verifier"))
    verification_nodes = Enum.filter(nodes, &(&1["kind"] == "verification"))

    %{
      "node_count" => length(nodes),
      "edge_count" => length(edges),
      "child_contract_count" => length(child_nodes),
      "worker_contract_count" => length(worker_nodes),
      "verifier_contract_count" => length(verifier_nodes) + length(verification_nodes),
      "completed_child_contract_count" => Enum.count(child_nodes, &completed?/1),
      "incomplete_child_contract_count" => Enum.count(child_nodes, &(not completed?(&1))),
      "route_verification_submitted" => verification_gate != %{},
      "route_verification_passed" => verification_satisfied?(verification_gate),
      "severe_prediction_error_count" => length(prediction_errors),
      "severe_prediction_error_ids" => Enum.map(prediction_errors, & &1["prediction_id"])
    }
    |> compact()
  end

  defp completion_blockers(graph, nodes, verification_gate, metrics) do
    []
    |> maybe_block(
      not enforceable_graph?(graph),
      "work_graph_unavailable",
      "No agent work graph could be derived for this task."
    )
    |> maybe_block(
      Enum.any?(nodes, &blocked?/1),
      "work_graph_node_blocked",
      "At least one work graph node is blocked or failed."
    )
    |> maybe_block(
      Enum.any?(Enum.filter(nodes, &required?/1), &incomplete_non_integration_node?/1),
      "required_node_incomplete",
      "Required non-integration work graph nodes are not complete."
    )
    |> maybe_block(
      metric_count(metrics, "worker_contract_count") > 0 and
        metric_count(metrics, "verifier_contract_count") == 0,
      "verifier_contract_missing",
      "Worker child-agent work requires an explicit verifier node or contract."
    )
    |> maybe_block(
      route_verification_required?(verification_gate, metrics) and
        not verification_satisfied?(verification_gate),
      "route_verification_review_not_satisfied",
      "route_verification_review has not produced a passing structured verdict."
    )
    |> maybe_block(
      metric_count(metrics, "severe_prediction_error_count") > 0 and
        not prediction_errors_accepted?(verification_gate),
      "severe_prediction_errors_unaccepted",
      "Medium or higher prediction errors require explicit acceptance or another verification pass."
    )
    |> Enum.reverse()
  end

  defp maybe_block(blockers, false, _code, _message), do: blockers

  defp maybe_block(blockers, true, code, message) do
    [%{"code" => code, "message" => message} | blockers]
  end

  defp graph_status(nodes, metrics, verification_gate) do
    cond do
      nodes == [] -> "empty"
      Enum.any?(nodes, &blocked?/1) -> "blocked"
      metric_count(metrics, "incomplete_child_contract_count") > 0 -> "running"
      verification_satisfied?(verification_gate) -> "verified"
      route_verification_required?(verification_gate, metrics) -> "awaiting_verification"
      Enum.all?(nodes, &completed?/1) -> "completed"
      true -> "active"
    end
  end

  defp graph_source(task_graph, child_contracts, agent_runs) do
    cond do
      task_graph != %{} -> "task_graph"
      child_contracts != [] -> "child_agent_contracts"
      agent_runs != [] -> "agent_runs"
      true -> "empty"
    end
  end

  defp enforceable_graph?(%{} = graph) do
    case Map.get(graph, "nodes") do
      nodes when is_list(nodes) and nodes != [] -> true
      _nodes -> false
    end
  end

  defp enforceable_graph?(_graph), do: false

  defp completed?(node), do: node["status"] in @complete_statuses
  defp blocked?(node), do: node["status"] in @blocked_statuses
  defp required?(node), do: node["required"] != false

  defp incomplete_non_integration_node?(node),
    do: node["kind"] != "integration" and not completed?(node)

  defp verification_satisfied?(gate) when is_map(gate) do
    cond do
      gate["satisfied"] == true -> true
      gate["can_finish"] == true -> true
      gate["status"] in ["passed", "approved", "not_required"] -> true
      true -> false
    end
  end

  defp verification_satisfied?(_gate), do: false

  defp route_verification_required?(gate, metrics) do
    cond do
      verification_required?(gate) -> true
      verification_status?(gate) -> true
      metric_count(metrics, "child_contract_count") > 0 -> true
      metric_count(metrics, "severe_prediction_error_count") > 0 -> true
      metric_count(metrics, "verifier_contract_count") > 0 -> true
      true -> false
    end
  end

  defp prediction_errors_accepted?(gate) when is_map(gate) do
    latest = map_field(gate, "latest_evaluation")

    cond do
      latest["prediction_errors_accepted"] == true -> true
      latest["prediction_error_acceptance"] == "accepted" -> true
      gate["prediction_error_acceptance"] == "accepted" -> true
      true -> false
    end
  end

  defp prediction_errors_accepted?(_gate), do: false

  defp child_contracts(attrs, events) do
    explicit = normalize_list(attrs["child_agent_contracts"])

    from_events =
      events
      |> Enum.flat_map(fn event ->
        metadata = map_field(event, "metadata")

        case map_field(metadata, "child_agent_contract") do
          contract when contract != %{} -> [contract]
          _missing -> []
        end
      end)

    (explicit ++ from_events)
    |> Enum.reduce(%{}, fn contract, acc ->
      key = contract["child_contract_id"]

      if key in [nil, ""] do
        acc
      else
        Map.put_new(acc, key, contract)
      end
    end)
    |> Map.values()
  end

  defp child_completions(events, agent_runs) do
    completed_from_events =
      events
      |> Enum.filter(&(&1["kind"] == "child_agent.completed"))
      |> Enum.map(fn event ->
        metadata = map_field(event, "metadata")

        %{
          "child_contract_id" => metadata["child_contract_id"],
          "child_session_id" => metadata["child_session_id"],
          "inserted_at" => event_inserted_at(event)
        }
        |> compact()
      end)

    completed_from_runs =
      agent_runs
      |> Enum.filter(&completed_run?/1)
      |> Enum.map(fn run ->
        %{
          "child_contract_id" => run["child_contract_id"],
          "child_session_id" => child_session_id(run),
          "inserted_at" => run_completed_at(run)
        }
        |> compact()
      end)

    completed = completed_from_events ++ completed_from_runs

    %{
      by_contract_id:
        completed
        |> Enum.reject(&(&1["child_contract_id"] in [nil, ""]))
        |> Map.new(&{&1["child_contract_id"], &1})
    }
  end

  defp event_inserted_at(%{"inserted_at" => inserted_at}) when is_binary(inserted_at),
    do: inserted_at

  defp event_inserted_at(%{"created_at" => created_at}) when is_binary(created_at),
    do: created_at

  defp event_inserted_at(_event), do: nil

  defp child_session_id(%{"run_id" => run_id}) when is_binary(run_id) and run_id != "",
    do: run_id

  defp child_session_id(%{"id" => id}) when is_binary(id) and id != "", do: id
  defp child_session_id(_run), do: nil

  defp run_completed_at(%{"completed_at" => completed_at}) when is_binary(completed_at),
    do: completed_at

  defp run_completed_at(%{"updated_at" => updated_at}) when is_binary(updated_at), do: updated_at
  defp run_completed_at(_run), do: nil

  defp severe_prediction_errors(attrs, events) do
    explicit = normalize_list(attrs["prediction_errors"])

    from_events =
      events
      |> Enum.flat_map(fn event ->
        metadata = map_field(event, "metadata")

        case map_field(metadata, "prediction_error") do
          error when error != %{} -> [error]
          _missing -> []
        end
      end)

    (explicit ++ from_events)
    |> Enum.reject(&(&1["matched"] == true))
    |> Enum.filter(&(&1["severity"] in @severe_prediction_error_levels))
  end

  defp completed_run?(run) do
    cond do
      run["status"] in ["completed", "done"] -> true
      run["lifecycle_state"] in ["completed", "awaiting_verification"] -> true
      true -> false
    end
  end

  defp normalize_status(status) when status in @complete_statuses, do: "completed"
  defp normalize_status(status) when status in @blocked_statuses, do: "blocked"
  defp normalize_status(status) when status in ["running", "queued", "in_progress"], do: "running"
  defp normalize_status("waiting"), do: "waiting"
  defp normalize_status("todo"), do: "pending"
  defp normalize_status("scheduled"), do: "pending"
  defp normalize_status("pending"), do: "pending"
  defp normalize_status(_status), do: "pending"

  defp role_for_kind("plan"), do: "planner"
  defp role_for_kind("research"), do: "researcher"
  defp role_for_kind("critique"), do: "critic"
  defp role_for_kind("verification"), do: "verifier"
  defp role_for_kind("integration"), do: "integrator"
  defp role_for_kind(_kind), do: "worker"

  defp normalize_events(events) do
    normalize_list(events)
  end

  defp normalize_list(value) when is_list(value) do
    value
    |> Enum.filter(&is_map/1)
    |> Enum.map(&string_keyed_map/1)
    |> Enum.reject(&(&1 == %{}))
  end

  defp normalize_list(_value), do: []

  defp metric_count(metrics, key, default \\ 0) do
    case metrics do
      %{^key => value} when is_integer(value) -> value
      _value -> default
    end
  end

  defp completion_value(%{} = completion, key), do: Map.get(completion, key)
  defp completion_value(_completion, _key), do: nil

  defp verification_required?(%{"required" => true}), do: true
  defp verification_required?(_gate), do: false

  defp verification_status?(%{"status" => status}) when is_binary(status), do: true
  defp verification_status?(_gate), do: false

  defp map_field(%{} = map, key) do
    case Map.get(map, key) do
      value when is_map(value) -> string_keyed_map(value)
      _value -> %{}
    end
  end

  defp map_field(_map, _key), do: %{}

  defp string_list_field(%{} = map, key) do
    case Map.get(map, key) do
      values when is_list(values) -> Enum.filter(values, &(is_binary(&1) and &1 != ""))
      _value -> []
    end
  end

  defp string_list_field(_map, _key), do: []

  defp string_keyed_map(map) do
    if Enum.all?(Map.keys(map), &is_binary/1), do: map, else: %{}
  end

  defp stable_id(prefix, parts) do
    digest =
      :crypto.hash(:sha256, :erlang.term_to_binary(parts))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 24)

    "#{prefix}_#{digest}"
  end

  defp compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end

  defp obsolete_key(attrs, keys) do
    Enum.find(keys, &Map.has_key?(attrs, &1))
  end

  defp rejected_gate(reason) do
    %{
      "schema_version" => @gate_schema_version,
      "status" => "rejected",
      "reason" => reason,
      "can_finish" => false,
      "evaluated_at" => Clock.iso_now()
    }
  end

  defp rejected_graph(reason) do
    %{
      "schema_version" => @schema_version,
      "status" => "rejected",
      "reason" => reason,
      "generated_at" => Clock.iso_now()
    }
  end
end
