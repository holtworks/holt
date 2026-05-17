defmodule HoltWorks.Tasks.WorkGraph do
  @moduledoc """
  Derived task-agent work graph for one task boundary.

  The graph can be built from HoltWorks task graphs, agent work records, agent
  run events, child-agent contracts, verification gates, and prediction errors.
  It gives the runtime a small DAG that can be scheduled and used as a
  completion gate.
  """

  alias HoltWorks.Clock
  alias HoltWorks.Tasks.RuntimeContracts

  @schema_version "holtworks_work_graph/v1"
  @gate_schema_version "holtworks_work_graph_completion_gate/v1"
  @complete_statuses ~w(completed done skipped passed approved verified satisfied)
  @blocked_statuses ~w(blocked failed rejected)
  @severe_prediction_error_levels ~w(medium high critical)

  def build(attrs \\ %{})

  def build(attrs) when is_map(attrs) do
    attrs = RuntimeContracts.string_keys(attrs)
    task = RuntimeContracts.normalize_map(attrs["task"])
    task_graph = RuntimeContracts.normalize_map(attrs["task_graph"] || attrs["graph"])

    verification_gate =
      RuntimeContracts.normalize_map(attrs["verification_gate"] || task_graph["mission_control"])

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
          RuntimeContracts.stable_id("work_graph", [
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
      |> RuntimeContracts.reject_empty()

    Map.put(
      graph,
      "completion_gate",
      completion_gate(%{"work_graph" => graph, "verification_gate" => verification_gate})
    )
  end

  def build(_attrs), do: build(%{})

  def completion_gate(attrs \\ %{})

  def completion_gate(attrs) when is_map(attrs) do
    attrs = RuntimeContracts.string_keys(attrs)
    graph = RuntimeContracts.normalize_map(attrs["work_graph"] || attrs["graph"])

    verification_gate =
      RuntimeContracts.normalize_map(attrs["verification_gate"] || graph["mission_control"])

    metrics = RuntimeContracts.normalize_map(graph["metrics"])
    nodes = normalize_list(graph["nodes"])
    blockers = completion_blockers(graph, nodes, verification_gate, metrics)

    %{
      "schema_version" => @gate_schema_version,
      "status" => if(blockers == [], do: "approved", else: "blocked"),
      "can_finish" => blockers == [],
      "enforced" => enforceable_graph?(graph),
      "blockers" => blockers,
      "node_count" => metrics["node_count"] || length(nodes),
      "worker_contract_count" => metrics["worker_contract_count"] || 0,
      "verifier_contract_count" => metrics["verifier_contract_count"] || 0,
      "completed_child_contract_count" => metrics["completed_child_contract_count"] || 0,
      "severe_prediction_error_count" => metrics["severe_prediction_error_count"] || 0,
      "verification_gate_status" => verification_gate["status"],
      "verification_satisfied" => verification_satisfied?(verification_gate),
      "evaluated_at" => Clock.iso_now()
    }
    |> RuntimeContracts.reject_empty()
  end

  def completion_gate(_attrs), do: completion_gate(%{})

  defp task_graph_nodes(task_graph) do
    task_graph
    |> RuntimeContracts.value("nodes")
    |> normalize_list()
    |> Enum.map(fn node ->
      node_id = node["id"] || node["node_id"] || node["node_key"]

      %{
        "node_id" => node_id,
        "id" => node_id,
        "node_key" => node["node_key"],
        "task_graph_node_id" => node["id"],
        "kind" => node["kind"] || node["node_type"] || "work",
        "phase" => node["phase"] || node["kind"] || node["node_type"],
        "role" => node["role"] || role_for_kind(node["kind"]),
        "status" => normalize_status(node["status"]),
        "source_status" => node["status"],
        "label" => node["label"],
        "position" => node["position"],
        "order" => node["order"] || node["position"],
        "depends_on" => RuntimeContracts.normalize_string_list(node["depends_on"]),
        "required" => node["required"] != false,
        "agent_id" => node["agent_id"],
        "agent_work_id" => node["agent_work_id"],
        "agent_run_id" => node["agent_run_id"],
        "run_id" => node["run_id"],
        "verification_gate" => RuntimeContracts.normalize_map(node["verification_gate"]),
        "completed_at" => node["completed_at"]
      }
      |> RuntimeContracts.reject_empty()
    end)
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
    plan = RuntimeContracts.normalize_map(attrs["plan_contract"])

    if plan == %{} do
      nil
    else
      %{
        "node_id" => "plan:#{plan["plan_id"]}",
        "kind" => "plan",
        "phase" => "plan",
        "status" => normalize_status(plan["status"] || "active"),
        "role" => "planner",
        "plan_id" => plan["plan_id"],
        "label" => "Active plan contract",
        "order" => 0
      }
      |> RuntimeContracts.reject_empty()
    end
  end

  defp child_node(contract, child_completions) do
    child = RuntimeContracts.normalize_map(contract["child"])
    parent = RuntimeContracts.normalize_map(contract["parent"])
    verification_contract = RuntimeContracts.normalize_map(contract["verification_contract"])
    contract_id = contract["child_contract_id"] || contract["contract_id"]
    tool_call_id = contract["tool_call_id"]

    completion =
      Map.get(child_completions.by_contract_id, contract_id) ||
        Map.get(child_completions.by_tool_call_id, tool_call_id)

    role = child["work_role"] || contract["work_role"] || "worker"

    %{
      "node_id" => "child:#{contract_id || tool_call_id}",
      "kind" => "child_agent",
      "phase" => if(role == "verifier", do: "verify", else: "work"),
      "status" => if(completion, do: "completed", else: "running"),
      "role" => role,
      "child_contract_id" => contract_id,
      "tool_call_id" => tool_call_id,
      "child_ref" => child["child_ref"],
      "target_agent_id" => child["target_agent_id"],
      "target_skill" => child["target_skill"],
      "parent_agent_id" => parent["agent_id"],
      "requires_verifier" => RuntimeContracts.truthy?(verification_contract["verifier_required"]),
      "child_session_id" => RuntimeContracts.value(completion || %{}, "child_session_id"),
      "completed_at" => RuntimeContracts.value(completion || %{}, "inserted_at"),
      "label" => "#{role}: #{child["child_ref"] || child["target_agent_id"] || "child"}"
    }
    |> RuntimeContracts.reject_empty()
  end

  defp verifier_node(gate) do
    cond do
      gate == %{} ->
        nil

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
    |> RuntimeContracts.reject_empty()
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
    |> RuntimeContracts.reject_empty()
  end

  defp agent_work_nodes(task, agent_runs, verification_gate) do
    work_nodes =
      agent_runs
      |> Enum.map(fn run ->
        %{
          "node_id" => "agent_run:#{run["id"] || run["run_id"]}",
          "kind" => "child_agent",
          "phase" => "work",
          "status" => normalize_status(run["lifecycle_state"] || run["status"]),
          "role" => run["work_role"] || "worker",
          "agent_id" => run["agent_id"],
          "agent_run_id" => run["id"],
          "run_id" => run["run_id"],
          "label" => "agent: #{run["agent_id"] || "default"}",
          "order" => 1
        }
        |> RuntimeContracts.reject_empty()
      end)

    [
      work_nodes,
      verifier_node(verification_gate),
      integration_node(task)
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

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
      |> Enum.reject(fn {key, value} -> key in [nil, ""] or value in [nil, ""] end)
      |> Map.new()

    task_graph_edges
    |> normalize_list()
    |> Enum.map(fn edge ->
      %{
        "from" => Map.get(node_refs, edge["from"], edge["from"]),
        "to" => Map.get(node_refs, edge["to"], edge["to"]),
        "type" => edge["type"] || "depends_on"
      }
      |> RuntimeContracts.reject_empty()
    end)
    |> Enum.reject(&(&1["from"] in [nil, ""] or &1["to"] in [nil, ""]))
    |> Enum.uniq()
  end

  defp graph_edges(nodes, _task_graph_edges) do
    node_refs =
      nodes
      |> Enum.flat_map(fn node ->
        [{node["node_id"], node["node_id"]}, {node["node_key"], node["node_id"]}]
      end)
      |> Enum.reject(fn {key, value} -> key in [nil, ""] or value in [nil, ""] end)
      |> Map.new()

    explicit =
      Enum.flat_map(nodes, fn node ->
        node
        |> RuntimeContracts.value("depends_on")
        |> RuntimeContracts.normalize_string_list()
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

  defp inferred_edges(nodes) do
    plan = Enum.find(nodes, &(&1["kind"] == "plan"))
    child_nodes = Enum.filter(nodes, &(&1["kind"] == "child_agent"))
    worker_nodes = Enum.filter(child_nodes, &(&1["role"] != "verifier"))

    verifier_nodes =
      Enum.filter(nodes, &(&1["kind"] == "verification" or &1["role"] == "verifier"))

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
    |> RuntimeContracts.reject_empty()
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
      (metrics["worker_contract_count"] || 0) > 0 and
        (metrics["verifier_contract_count"] || 0) == 0,
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
      (metrics["severe_prediction_error_count"] || 0) > 0 and
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
      (metrics["incomplete_child_contract_count"] || 0) > 0 -> "running"
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

  defp enforceable_graph?(graph) do
    nodes = RuntimeContracts.value(graph, "nodes") || []
    is_list(nodes) and nodes != []
  end

  defp completed?(node), do: node["status"] in @complete_statuses
  defp blocked?(node), do: node["status"] in @blocked_statuses
  defp required?(node), do: node["required"] != false

  defp incomplete_non_integration_node?(node),
    do: node["kind"] != "integration" and not completed?(node)

  defp verification_satisfied?(gate) when is_map(gate) do
    RuntimeContracts.truthy?(gate["satisfied"]) or RuntimeContracts.truthy?(gate["can_finish"]) or
      gate["status"] in ["passed", "approved", "not_required"]
  end

  defp verification_satisfied?(_gate), do: false

  defp route_verification_required?(gate, metrics) do
    RuntimeContracts.truthy?(RuntimeContracts.value(gate, "required")) or
      is_binary(RuntimeContracts.value(gate, "status")) or
      (metrics["child_contract_count"] || 0) > 0 or
      (metrics["severe_prediction_error_count"] || 0) > 0 or
      (metrics["verifier_contract_count"] || 0) > 0
  end

  defp prediction_errors_accepted?(gate) when is_map(gate) do
    latest = RuntimeContracts.normalize_map(gate["latest_evaluation"])

    RuntimeContracts.truthy?(latest["prediction_errors_accepted"]) or
      latest["prediction_error_acceptance"] == "accepted" or
      gate["prediction_error_acceptance"] == "accepted"
  end

  defp prediction_errors_accepted?(_gate), do: false

  defp child_contracts(attrs, events) do
    explicit = normalize_list(attrs["child_agent_contracts"] || attrs["child_contracts"])

    from_events =
      events
      |> Enum.flat_map(fn event ->
        metadata = RuntimeContracts.normalize_map(event["metadata"])

        case metadata["child_agent_contract"] do
          contract when is_map(contract) -> [RuntimeContracts.string_keys(contract)]
          _missing -> []
        end
      end)

    (explicit ++ from_events)
    |> Enum.reduce(%{}, fn contract, acc ->
      key = contract["child_contract_id"] || contract["contract_id"] || contract["tool_call_id"]

      if key in [nil, ""] do
        acc
      else
        Map.put_new(acc, key, RuntimeContracts.string_keys(contract))
      end
    end)
    |> Map.values()
  end

  defp child_completions(events, agent_runs) do
    completed_from_events =
      events
      |> Enum.filter(
        &(&1["kind"] == "child_agent.completed" or &1["type"] == "child_agent.completed")
      )
      |> Enum.map(fn event ->
        metadata = RuntimeContracts.normalize_map(event["metadata"])

        %{
          "child_contract_id" => metadata["child_contract_id"],
          "tool_call_id" => metadata["tool_call_id"],
          "child_session_id" => metadata["child_session_id"],
          "inserted_at" => event["inserted_at"] || event["created_at"]
        }
        |> RuntimeContracts.reject_empty()
      end)

    completed_from_runs =
      agent_runs
      |> Enum.filter(&completed_run?/1)
      |> Enum.map(fn run ->
        %{
          "child_contract_id" => run["child_contract_id"],
          "tool_call_id" => run["tool_call_id"],
          "child_session_id" => run["run_id"] || run["id"],
          "inserted_at" => run["completed_at"] || run["updated_at"]
        }
        |> RuntimeContracts.reject_empty()
      end)

    completed = completed_from_events ++ completed_from_runs

    %{
      by_contract_id:
        completed
        |> Enum.reject(&(&1["child_contract_id"] in [nil, ""]))
        |> Map.new(&{&1["child_contract_id"], &1}),
      by_tool_call_id:
        completed
        |> Enum.reject(&(&1["tool_call_id"] in [nil, ""]))
        |> Map.new(&{&1["tool_call_id"], &1})
    }
  end

  defp severe_prediction_errors(attrs, events) do
    explicit = normalize_list(attrs["prediction_errors"])

    from_events =
      events
      |> Enum.flat_map(fn event ->
        metadata = RuntimeContracts.normalize_map(event["metadata"])

        case metadata["prediction_error"] do
          error when is_map(error) -> [RuntimeContracts.string_keys(error)]
          _missing -> []
        end
      end)

    (explicit ++ from_events)
    |> Enum.reject(&RuntimeContracts.truthy?(&1["matched"]))
    |> Enum.filter(&(&1["severity"] in @severe_prediction_error_levels))
  end

  defp completed_run?(run) do
    run["status"] in ["completed", "done"] or
      run["lifecycle_state"] in ["completed", "awaiting_verification"]
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
    events
    |> normalize_list()
    |> Enum.map(&RuntimeContracts.string_keys/1)
  end

  defp normalize_list(value) when is_list(value) do
    value
    |> Enum.filter(&is_map/1)
    |> Enum.map(&RuntimeContracts.string_keys/1)
  end

  defp normalize_list(_value), do: []
end
