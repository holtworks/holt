defmodule HoltWorks.Tasks.TaskGraphs do
  @moduledoc """
  File-backed autonomous task work graphs.

  A task graph is the local HoltWorks equivalent of Inktrail's durable work
  graph nodes: plan/work/verification/integration steps with structured state
  and an explicit completion gate.
  """

  alias HoltWorks.{Clock, JSON, Paths}

  @schema_version "holtworks_task_graph/v1"
  @gate_schema_version "holtworks_task_graph_gate/v1"
  @verification_gate_schema_version "holtworks_task_graph_verification_gate/v1"
  @node_statuses ~w(pending scheduled queued running done blocked failed skipped waiting_verification)
  @terminal_statuses ~w(done skipped)
  @blocked_statuses ~w(blocked failed)

  def ensure_store(root) do
    Paths.ensure_workspace(root)
    File.mkdir_p!(Paths.tasks_dir(root))
    unless File.exists?(path(root)), do: JSON.write(path(root), [])
    :ok
  end

  def path(root), do: Path.join(Paths.tasks_dir(root), "task_graphs.json")
  def events_path(root), do: Path.join(Paths.tasks_dir(root), "task_graph_events.jsonl")

  def list(opts \\ []) do
    root = Paths.workspace_root(opts)
    ensure_store(root)

    root
    |> load_graphs()
    |> Enum.map(&refresh_graph/1)
    |> Enum.sort_by(&(&1["created_at"] || ""))
  end

  def list_for_task(root, task_id) do
    root
    |> load_graphs()
    |> Enum.filter(&(&1["task_id"] == task_id))
    |> Enum.map(&refresh_graph/1)
    |> Enum.sort_by(&(&1["created_at"] || ""))
  end

  def get(root, graph_id) do
    ensure_store(root)

    case Enum.find(load_graphs(root), &(&1["id"] == to_string(graph_id))) do
      nil -> {:error, :task_graph_not_found}
      graph -> {:ok, refresh_graph(graph)}
    end
  end

  def create(root, task, attrs) when is_map(task) and is_map(attrs) do
    ensure_store(root)
    attrs = string_keys(attrs)
    now = Clock.iso_now()
    graph_id = optional_text(attrs, "id", Clock.id("task_graph"))
    graph_type = optional_text(attrs, "graph_type", optional_text(attrs, "type", "workflow"))
    nodes = normalize_nodes(Map.get(attrs, "nodes"), task, graph_id, graph_type, now)

    graph =
      %{
        "schema_version" => @schema_version,
        "id" => graph_id,
        "task_id" => task["id"],
        "task_ref" => task["ref"],
        "title" => optional_text(attrs, "title", "#{task["ref"]} work graph"),
        "graph_type" => graph_type,
        "source" => optional_text(attrs, "source", "task_graph_create"),
        "nodes" => nodes,
        "metadata" => normalize_metadata(Map.get(attrs, "metadata", %{})),
        "created_at" => now,
        "updated_at" => now
      }
      |> reject_empty()
      |> refresh_graph()

    graph
    |> add_graph(root)
    |> case do
      :ok ->
        append_event(root, graph, "task_graph.created", %{
          "node_count" => length(graph["nodes"] || []),
          "graph_type" => graph["graph_type"]
        })

        {:ok, graph}
    end
  end

  def advance(root, graph_id, attrs \\ %{}) do
    attrs = string_keys(attrs)

    update_graph(root, graph_id, fn graph ->
      now = Clock.iso_now()

      graph
      |> Map.update("nodes", [], &advance_nodes(&1, now))
      |> Map.put("updated_at", now)
      |> maybe_put_graph_metadata(attrs)
      |> refresh_graph()
    end)
    |> tap_update_event(root, "task_graph.advanced", %{})
  end

  def mark_node_running(root, graph_id, node_ref, attrs \\ %{}) do
    attrs = string_keys(attrs)

    update_node(root, graph_id, node_ref, fn node ->
      now = Clock.iso_now()

      node
      |> Map.merge(%{
        "status" => "running",
        "started_at" => node["started_at"] || now,
        "updated_at" => now,
        "agent_id" => optional_text(attrs, "agent_id", node["agent_id"]),
        "agent_work_id" => optional_text(attrs, "agent_work_id", node["agent_work_id"]),
        "agent_run_id" => optional_text(attrs, "agent_run_id", node["agent_run_id"]),
        "run_id" => optional_text(attrs, "run_id", node["run_id"])
      })
      |> maybe_put_node_output_attrs(attrs)
      |> reject_empty()
    end)
    |> tap_update_event(root, "task_graph.node_running", %{"node_ref" => to_string(node_ref)})
  end

  def complete_node(root, graph_id, node_ref, attrs \\ %{}) do
    attrs = string_keys(attrs)

    update_node(root, graph_id, node_ref, fn node ->
      now = Clock.iso_now()

      node
      |> Map.merge(%{
        "status" => node_completion_status(node, attrs),
        "completed_at" => now,
        "updated_at" => now,
        "agent_id" => optional_text(attrs, "agent_id", node["agent_id"]),
        "agent_work_id" => optional_text(attrs, "agent_work_id", node["agent_work_id"]),
        "agent_run_id" => optional_text(attrs, "agent_run_id", node["agent_run_id"]),
        "run_id" => optional_text(attrs, "run_id", node["run_id"])
      })
      |> maybe_put_node_output_attrs(attrs)
      |> maybe_put_node_verification_gate(attrs)
      |> reject_empty()
    end)
    |> tap_update_event(root, "task_graph.node_completed", %{"node_ref" => to_string(node_ref)})
  end

  def block_node(root, graph_id, node_ref, attrs \\ %{}) do
    attrs = string_keys(attrs)

    update_node(root, graph_id, node_ref, fn node ->
      now = Clock.iso_now()

      node
      |> Map.merge(%{
        "status" => "blocked",
        "blocker" => normalize_blocker(attrs),
        "agent_id" => optional_text(attrs, "agent_id", node["agent_id"]),
        "agent_work_id" => optional_text(attrs, "agent_work_id", node["agent_work_id"]),
        "agent_run_id" => optional_text(attrs, "agent_run_id", node["agent_run_id"]),
        "run_id" => optional_text(attrs, "run_id", node["run_id"]),
        "updated_at" => now
      })
      |> maybe_put_node_output_attrs(attrs)
      |> reject_empty()
    end)
    |> tap_update_event(root, "task_graph.node_blocked", %{"node_ref" => to_string(node_ref)})
  end

  def record_verification(root, task, report, spec, attrs) do
    ensure_store(root)
    attrs = string_keys(attrs || %{})

    with {:ok, graph} <- graph_for_verification(root, task, attrs),
         {:ok, node_ref} <- verification_node_ref(graph, attrs) do
      gate = verification_gate(report, spec)

      update_node(root, graph["id"], node_ref, fn node ->
        now = Clock.iso_now()

        node
        |> Map.merge(%{
          "status" => if(gate["can_finish"], do: "done", else: "blocked"),
          "output" => report["summary"],
          "output_spec_id" => spec["id"],
          "verification_report_id" => report["id"],
          "verification_gate" => gate,
          "completed_at" => if(gate["can_finish"], do: now, else: node["completed_at"]),
          "updated_at" => now
        })
        |> reject_empty()
      end)
      |> case do
        {:ok, updated} ->
          graph_with_gate =
            updated
            |> Map.put("verification_gate", gate)
            |> Map.put("updated_at", Clock.iso_now())
            |> refresh_graph()

          replace_graph(root, graph_with_gate)

          append_event(root, graph_with_gate, "task_graph.verification_recorded", %{
            "report_id" => report["id"],
            "spec_id" => spec["id"],
            "can_finish" => gate["can_finish"],
            "status" => gate["status"]
          })

          {:ok, graph_with_gate}

        error ->
          error
      end
    else
      {:error, :task_graph_not_found} -> {:ok, nil}
      {:error, :verification_node_not_found} -> {:ok, nil}
      error -> error
    end
  end

  def record_verifier_route(root, graph_id, route) do
    route = string_keys(route || %{})

    update_graph(root, graph_id, fn graph ->
      now = Clock.iso_now()

      graph
      |> Map.put("verifier_route", route)
      |> Map.put("updated_at", now)
      |> Map.update("nodes", [], fn nodes ->
        Enum.map(nodes, fn node ->
          if node["kind"] == "verification" do
            node
            |> Map.put("verifier_route", route)
            |> Map.put("updated_at", now)
          else
            node
          end
        end)
      end)
      |> refresh_graph()
    end)
    |> case do
      {:ok, graph} ->
        append_event(root, graph, "task_graph.verifier_route_planned", %{
          "route_id" => route["route_id"],
          "status" => route["status"],
          "target_agent_id" => route["target_agent_id"]
        })

        {:ok, graph}

      error ->
        error
    end
  end

  def event_log(root), do: JSON.read_jsonl(events_path(root))

  def mission_control(graph) when is_map(graph) do
    nodes = graph["nodes"] || []
    verification_gate = graph["verification_gate"] || latest_node_verification_gate(nodes)
    blockers = completion_blockers(graph, nodes, verification_gate)
    required_nodes = Enum.filter(nodes, &required_node?/1)
    non_integration = Enum.reject(required_nodes, &(&1["kind"] == "integration"))
    non_integration_done? = Enum.all?(non_integration, &terminal_node?/1)

    %{
      "schema_version" => @gate_schema_version,
      "status" => if(blockers == [], do: "approved", else: "blocked"),
      "can_finish" => blockers == [] and non_integration_done?,
      "blockers" => blockers,
      "node_count" => length(nodes),
      "required_node_count" => length(required_nodes),
      "done_node_count" => Enum.count(nodes, &terminal_node?/1),
      "running_node_count" => Enum.count(nodes, &(&1["status"] == "running")),
      "blocked_node_count" => Enum.count(nodes, &blocked_node?/1),
      "verification_required" => verification_required?(graph, nodes, verification_gate),
      "verification_satisfied" => verification_satisfied?(verification_gate),
      "verification_gate_status" => value(verification_gate, :status),
      "evaluated_at" => Clock.iso_now()
    }
    |> reject_empty()
  end

  def mission_control(_graph), do: mission_control(%{"nodes" => []})

  defp load_graphs(root), do: JSON.read(path(root), [])

  defp add_graph(graph, root) do
    root
    |> load_graphs()
    |> Kernel.++([graph])
    |> store_graphs(root)
  end

  defp replace_graph(root, graph) do
    root
    |> load_graphs()
    |> Enum.map(fn current ->
      if current["id"] == graph["id"], do: graph, else: current
    end)
    |> store_graphs(root)
  end

  defp store_graphs(graphs, root) do
    ensure_store(root)
    JSON.write(path(root), graphs)
    :ok
  end

  defp update_graph(root, graph_id, fun) do
    ensure_store(root)
    graphs = load_graphs(root)

    case Enum.find(graphs, &(&1["id"] == to_string(graph_id))) do
      nil ->
        {:error, :task_graph_not_found}

      graph ->
        updated =
          graph
          |> fun.()
          |> refresh_graph()

        graphs
        |> Enum.map(fn current ->
          if current["id"] == graph["id"], do: updated, else: current
        end)
        |> store_graphs(root)

        {:ok, updated}
    end
  end

  defp update_node(root, graph_id, node_ref, fun) do
    update_graph(root, graph_id, fn graph ->
      now = Clock.iso_now()
      nodes = graph["nodes"] || []

      case Enum.find(nodes, &node_matches?(&1, node_ref)) do
        nil ->
          graph

        _node ->
          updated_nodes =
            nodes
            |> Enum.map(fn node ->
              if node_matches?(node, node_ref), do: fun.(node), else: node
            end)
            |> advance_nodes(now)

          graph
          |> Map.put("nodes", updated_nodes)
          |> Map.put("updated_at", now)
      end
    end)
    |> case do
      {:ok, graph} ->
        if Enum.any?(graph["nodes"] || [], &node_matches?(&1, node_ref)) do
          {:ok, graph}
        else
          {:error, :task_graph_node_not_found}
        end

      error ->
        error
    end
  end

  defp tap_update_event({:ok, graph} = result, root, event_type, metadata) do
    append_event(root, graph, event_type, metadata)
    result
  end

  defp tap_update_event(result, _root, _event_type, _metadata), do: result

  defp graph_for_verification(root, task, attrs) do
    case optional_text(attrs, "graph_id", optional_text(attrs, "task_graph_id")) do
      value when value in [nil, ""] ->
        root
        |> list_for_task(task["id"])
        |> Enum.reverse()
        |> Enum.find(&verification_required_graph?/1)
        |> case do
          nil -> {:error, :task_graph_not_found}
          graph -> {:ok, graph}
        end

      graph_id ->
        get(root, graph_id)
    end
  end

  defp verification_node_ref(graph, attrs) do
    explicit =
      optional_text(attrs, "node_id") ||
        optional_text(attrs, "node_key") ||
        optional_text(attrs, "task_graph_node_id") ||
        optional_text(attrs, "task_graph_node_key")

    cond do
      explicit not in [nil, ""] ->
        {:ok, explicit}

      true ->
        graph
        |> Map.get("nodes", [])
        |> Enum.filter(&(&1["kind"] == "verification"))
        |> Enum.sort_by(& &1["position"])
        |> Enum.find(fn node -> not terminal_node?(node) end)
        |> case do
          nil ->
            graph
            |> Map.get("nodes", [])
            |> Enum.filter(&(&1["kind"] == "verification"))
            |> Enum.sort_by(& &1["position"])
            |> List.first()
            |> case do
              nil -> {:error, :verification_node_not_found}
              node -> {:ok, node["id"]}
            end

          node ->
            {:ok, node["id"]}
        end
    end
  end

  defp verification_required_graph?(graph) do
    Enum.any?(graph["nodes"] || [], &(&1["kind"] == "verification"))
  end

  defp normalize_nodes(nil, task, graph_id, graph_type, now) do
    graph_type
    |> default_templates(task)
    |> normalize_nodes(task, graph_id, graph_type, now)
  end

  defp normalize_nodes([], task, graph_id, graph_type, now) do
    normalize_nodes(nil, task, graph_id, graph_type, now)
  end

  defp normalize_nodes(nodes, _task, graph_id, _graph_type, now) when is_list(nodes) do
    nodes
    |> Enum.filter(&is_map/1)
    |> Enum.with_index()
    |> Enum.map(fn {node, position} ->
      normalize_node(node, graph_id, position, now)
    end)
    |> initialize_node_statuses()
  end

  defp normalize_nodes(_nodes, task, graph_id, graph_type, now) do
    normalize_nodes(nil, task, graph_id, graph_type, now)
  end

  defp default_templates("deep_concept", task) do
    [
      %{
        "node_key" => "frame",
        "kind" => "plan",
        "label" => "Frame concept",
        "instructions" => "Restate the request, constraints, and decision criteria."
      },
      %{
        "node_key" => "evidence",
        "kind" => "research",
        "label" => "Evidence review",
        "depends_on" => ["frame"],
        "instructions" => "Collect evidence for and against the concept."
      },
      %{
        "node_key" => "customer",
        "kind" => "critique",
        "label" => "Customer critique",
        "depends_on" => ["frame"],
        "instructions" => "Test the concept against concrete customer urgency."
      },
      %{
        "node_key" => "technical",
        "kind" => "critique",
        "label" => "Technical critique",
        "depends_on" => ["frame"],
        "instructions" => "Identify implementation risk and integration constraints."
      },
      %{
        "node_key" => "decision",
        "kind" => "synthesis",
        "label" => "Decision synthesis",
        "depends_on" => ["evidence", "customer", "technical"],
        "instructions" => "Synthesize the critiques into a recommended decision."
      },
      %{
        "node_key" => "verify",
        "kind" => "verification",
        "label" => "Verify synthesis",
        "depends_on" => ["decision"],
        "instructions" => "Verify the synthesis is evidence-backed and internally consistent."
      },
      %{
        "node_key" => "integrate",
        "kind" => "integration",
        "label" => "Integrate decision",
        "depends_on" => ["verify"],
        "instructions" => "Apply or hand off the verified decision."
      }
    ]
    |> Enum.map(&Map.put_new(&1, "metadata", %{"task_ref" => task["ref"]}))
  end

  defp default_templates(_graph_type, task) do
    [
      %{
        "node_key" => "plan",
        "kind" => "plan",
        "label" => "Plan work",
        "instructions" => "Define the work contract, acceptance criteria, and handoff."
      },
      %{
        "node_key" => "work",
        "kind" => "work",
        "label" => "Execute work",
        "depends_on" => ["plan"],
        "instructions" => "Complete the task within the stated contract."
      },
      %{
        "node_key" => "verify",
        "kind" => "verification",
        "label" => "Verify work",
        "depends_on" => ["work"],
        "instructions" => "Route a structured verification report before final integration."
      },
      %{
        "node_key" => "integrate",
        "kind" => "integration",
        "label" => "Integrate result",
        "depends_on" => ["verify"],
        "instructions" => "Finish or hand off the task after verification passes."
      }
    ]
    |> Enum.map(&Map.put_new(&1, "metadata", %{"task_ref" => task["ref"]}))
  end

  defp normalize_node(node, graph_id, position, now) do
    node = string_keys(node)
    node_id = optional_text(node, "id", Clock.id("graph_node"))
    node_key = optional_text(node, "node_key", optional_text(node, "key", "node_#{position + 1}"))

    %{
      "id" => node_id,
      "graph_id" => graph_id,
      "node_key" => node_key,
      "kind" => optional_text(node, "kind", "work"),
      "label" => optional_text(node, "label", node_key),
      "persona" => optional_text(node, "persona"),
      "instructions" => optional_text(node, "instructions", ""),
      "depends_on" => normalize_string_list(Map.get(node, "depends_on", [])),
      "position" => normalize_integer(Map.get(node, "position"), position),
      "status" => normalize_status(Map.get(node, "status")),
      "attempts" => normalize_integer(Map.get(node, "attempts"), 0),
      "max_attempts" => normalize_integer(Map.get(node, "max_attempts"), 3),
      "required" => normalize_required(Map.get(node, "required", true)),
      "agent_id" => optional_text(node, "agent_id"),
      "agent_work_id" => optional_text(node, "agent_work_id"),
      "agent_run_id" => optional_text(node, "agent_run_id"),
      "run_id" => optional_text(node, "run_id"),
      "output" => Map.get(node, "output"),
      "output_spec_id" => optional_text(node, "output_spec_id"),
      "verification_report_id" => optional_text(node, "verification_report_id"),
      "verification_gate" => normalize_map(Map.get(node, "verification_gate")),
      "metadata" => normalize_metadata(Map.get(node, "metadata", %{})),
      "created_at" => optional_text(node, "created_at", now),
      "updated_at" => optional_text(node, "updated_at", now),
      "started_at" => optional_text(node, "started_at"),
      "completed_at" => optional_text(node, "completed_at")
    }
    |> reject_empty()
  end

  defp initialize_node_statuses(nodes) do
    nodes
    |> Enum.map(fn node ->
      if node["status"] in [nil, ""] do
        status =
          if normalize_string_list(node["depends_on"]) == [], do: "scheduled", else: "pending"

        Map.put(node, "status", status)
      else
        node
      end
    end)
    |> advance_nodes(Clock.iso_now())
  end

  defp advance_nodes(nodes, now) do
    done_refs = done_node_refs(nodes)

    Enum.map(nodes, fn node ->
      cond do
        node["status"] == "pending" and dependencies_done?(node, done_refs) ->
          node
          |> Map.put("status", "scheduled")
          |> Map.put("next_run_at", node["next_run_at"] || now)
          |> Map.put("updated_at", now)

        true ->
          node
      end
    end)
  end

  defp done_node_refs(nodes) do
    nodes
    |> Enum.filter(&terminal_node?/1)
    |> Enum.flat_map(fn node -> [node["id"], node["node_key"]] end)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> MapSet.new()
  end

  defp dependencies_done?(node, done_refs) do
    node
    |> Map.get("depends_on", [])
    |> normalize_string_list()
    |> Enum.all?(&MapSet.member?(done_refs, &1))
  end

  defp refresh_graph(graph) do
    graph = Map.put(graph, "edges", edges(graph["nodes"] || []))
    gate = mission_control(graph)

    graph
    |> Map.put("mission_control", gate)
    |> Map.put("status", graph_status(graph["nodes"] || [], gate))
  end

  defp graph_status([], _gate), do: "empty"

  defp graph_status(nodes, gate) do
    cond do
      Enum.any?(nodes, &blocked_node?/1) -> "blocked"
      Enum.all?(nodes, &terminal_node?/1) -> "completed"
      gate["can_finish"] == true -> "ready_to_integrate"
      Enum.any?(nodes, &(&1["status"] == "running")) -> "running"
      Enum.any?(nodes, &(&1["status"] == "scheduled")) -> "scheduled"
      true -> "active"
    end
  end

  defp edges(nodes) do
    node_refs =
      nodes
      |> Enum.flat_map(fn node -> [{node["id"], node["id"]}, {node["node_key"], node["id"]}] end)
      |> Enum.reject(fn {key, value} -> key in [nil, ""] or value in [nil, ""] end)
      |> Map.new()

    nodes
    |> Enum.flat_map(fn node ->
      node
      |> Map.get("depends_on", [])
      |> normalize_string_list()
      |> Enum.flat_map(fn dependency ->
        case Map.get(node_refs, dependency) do
          nil ->
            []

          from_id ->
            [
              %{
                "from" => from_id,
                "to" => node["id"],
                "type" => edge_type(node["kind"])
              }
            ]
        end
      end)
    end)
    |> Enum.uniq()
  end

  defp edge_type("verification"), do: "requires_verification"
  defp edge_type("integration"), do: "feeds_integration"
  defp edge_type(_kind), do: "depends_on"

  defp completion_blockers(graph, nodes, verification_gate) do
    required_nodes = Enum.filter(nodes, &required_node?/1)

    []
    |> maybe_block(
      nodes == [],
      "work_graph_empty",
      "No task graph nodes are available."
    )
    |> maybe_block(
      Enum.any?(required_nodes, &blocked_node?/1),
      "node_blocked",
      "At least one required task graph node is blocked or failed."
    )
    |> maybe_block(
      Enum.any?(required_nodes, &incomplete_non_integration_node?/1),
      "required_node_incomplete",
      "Required non-integration graph nodes are not complete."
    )
    |> maybe_block(
      verification_required?(graph, nodes, verification_gate) and
        not verification_satisfied?(verification_gate),
      "verification_gate_not_satisfied",
      "A structured verification route has not passed for this work graph."
    )
    |> Enum.reverse()
  end

  defp maybe_block(blockers, false, _code, _message), do: blockers

  defp maybe_block(blockers, true, code, message) do
    [%{"code" => code, "message" => message} | blockers]
  end

  defp incomplete_non_integration_node?(node) do
    node["kind"] != "integration" and not terminal_node?(node)
  end

  defp required_node?(node), do: node["required"] != false
  defp terminal_node?(node), do: node["status"] in @terminal_statuses
  defp blocked_node?(node), do: node["status"] in @blocked_statuses

  defp verification_required?(graph, nodes, gate) do
    truthy?(value(graph, :verification_required)) or truthy?(value(gate, :required)) or
      Enum.any?(nodes, &(&1["kind"] == "verification"))
  end

  defp verification_satisfied?(gate) when is_map(gate) do
    truthy?(value(gate, :satisfied)) or truthy?(value(gate, :can_finish)) or
      value(gate, :status) in ["passed", "not_required"]
  end

  defp verification_satisfied?(_gate), do: false

  defp latest_node_verification_gate(nodes) do
    nodes
    |> Enum.filter(&is_map(&1["verification_gate"]))
    |> Enum.sort_by(&(&1["updated_at"] || ""))
    |> List.last()
    |> case do
      nil -> %{}
      node -> node["verification_gate"]
    end
  end

  defp verification_gate(report, spec) do
    route = normalize_map(report["route"])
    can_finish = truthy?(route["can_finish"])

    %{
      "schema_version" => @verification_gate_schema_version,
      "status" => if(can_finish, do: "passed", else: "needs_review"),
      "satisfied" => can_finish,
      "can_finish" => can_finish,
      "required" => true,
      "report_id" => report["id"],
      "spec_id" => spec["id"],
      "decision" => report["decision"],
      "route" => route,
      "evaluated_at" => Clock.iso_now()
    }
    |> reject_empty()
  end

  defp node_completion_status(_node, attrs) do
    requested = normalize_status(Map.get(attrs, "status"))

    cond do
      requested in ["done", "skipped", "blocked", "failed"] ->
        requested

      true ->
        "done"
    end
  end

  defp maybe_put_node_output_attrs(node, attrs) do
    node
    |> maybe_put_non_empty("output", Map.get(attrs, "output", Map.get(attrs, "summary")))
    |> maybe_put_non_empty("output_spec_id", optional_text(attrs, "output_spec_id"))
    |> maybe_put_non_empty(
      "verification_report_id",
      optional_text(attrs, "verification_report_id")
    )
    |> maybe_put_non_empty("metadata", maybe_merge_metadata(node["metadata"], attrs["metadata"]))
  end

  defp maybe_put_node_verification_gate(node, attrs) do
    gate = normalize_map(Map.get(attrs, "verification_gate"))

    if gate == %{} do
      node
    else
      Map.put(node, "verification_gate", gate)
    end
  end

  defp maybe_put_graph_metadata(graph, attrs) do
    metadata = normalize_metadata(Map.get(attrs, "metadata", %{}))

    if metadata == %{} do
      graph
    else
      Map.update(graph, "metadata", metadata, &Map.merge(&1 || %{}, metadata))
    end
  end

  defp maybe_merge_metadata(existing, nil), do: existing || %{}

  defp maybe_merge_metadata(existing, metadata),
    do: Map.merge(existing || %{}, normalize_metadata(metadata))

  defp normalize_blocker(attrs) do
    %{
      "code" => optional_text(attrs, "code", optional_text(attrs, "reason", "node_blocked")),
      "message" => optional_text(attrs, "message", optional_text(attrs, "summary")),
      "created_at" => Clock.iso_now()
    }
    |> reject_empty()
  end

  defp append_event(root, graph, type, metadata) do
    JSON.append_jsonl(events_path(root), %{
      "id" => Clock.id("task_graph_event"),
      "type" => type,
      "graph_id" => graph["id"],
      "task_id" => graph["task_id"],
      "task_ref" => graph["task_ref"],
      "metadata" => metadata || %{},
      "created_at" => Clock.iso_now()
    })
  end

  defp node_matches?(node, ref) do
    value = to_string(ref)
    node["id"] == value or node["node_key"] == value
  end

  defp normalize_status(nil), do: nil
  defp normalize_status(value) when value in @node_statuses, do: value

  defp normalize_status(value),
    do: if(to_string(value) in @node_statuses, do: to_string(value), else: nil)

  defp normalize_required(false), do: false
  defp normalize_required("false"), do: false
  defp normalize_required(0), do: false
  defp normalize_required(_value), do: true

  defp normalize_integer(value, _default) when is_integer(value), do: value

  defp normalize_integer(value, default) do
    case Integer.parse(to_string(value)) do
      {number, ""} -> number
      _ -> default
    end
  end

  defp normalize_string_list(nil), do: []

  defp normalize_string_list(value) when is_list(value) do
    value
    |> Enum.flat_map(&normalize_string_list/1)
    |> Enum.uniq()
  end

  defp normalize_string_list(value) do
    text = value |> to_string() |> String.trim()

    if text == "" do
      []
    else
      text
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
    end
  end

  defp normalize_metadata(%{} = metadata), do: string_keys(metadata)
  defp normalize_metadata(_metadata), do: %{}

  defp normalize_map(value) when is_map(value), do: string_keys(value)
  defp normalize_map(_value), do: %{}

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

  defp value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp value(_map, _key), do: nil

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(1), do: true
  defp truthy?(_value), do: false

  defp maybe_put_non_empty(map, _key, value) when value in [nil, "", [], %{}], do: map
  defp maybe_put_non_empty(map, key, value), do: Map.put(map, key, value)

  defp reject_empty(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end
end
