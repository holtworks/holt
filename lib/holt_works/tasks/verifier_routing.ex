defmodule HoltWorks.Tasks.VerifierRouting do
  @moduledoc """
  Deterministic verifier route planning for local task graphs.

  The route is a bounded contract for a verifier agent. It does not execute the
  verifier by itself; callers can pass the returned `start_agent_work_params`
  into the existing agent-work API.
  """

  alias HoltWorks.Clock

  @schema_version "holtworks_verifier_routing/v1"
  @default_verifier_tools ~w(
    get_task list_task_specs get_task_spec read_task_memory_artifact
    load_teammate_runtime route_verification_review
  )

  def plan(attrs \\ %{})

  def plan(attrs) when is_map(attrs) do
    attrs = string_keys(attrs)
    task = normalize_map(value(attrs, "task"))
    graph = normalize_map(value(attrs, "task_graph") || value(attrs, "graph"))
    gate = normalize_map(value(attrs, "task_graph_gate") || value(graph, "mission_control"))
    evidence_contract = normalize_map(value(attrs, "evidence_contract"))
    available_agents = normalize_agents(value(attrs, "available_agents"))
    verifier = select_verifier(available_agents)
    blockers = value(gate, "blockers") |> List.wrap() |> Enum.filter(&is_map/1)
    status = route_status(gate, blockers)
    route_id = Clock.id("verifier_route")

    %{
      "schema_version" => @schema_version,
      "route_id" => route_id,
      "status" => status,
      "trigger_blockers" => Enum.map(blockers, &value(&1, "code")),
      "task_id" => value(task, "id"),
      "task_ref" => value(task, "ref"),
      "graph_id" => value(graph, "id"),
      "graph_status" => value(graph, "status"),
      "work_role" => "verifier",
      "target_agent_id" => value(verifier, "id"),
      "target_agent_ref" => value(verifier, "agent_ref"),
      "target_agent_handle" => value(verifier, "agent_handle"),
      "allowed_tools" => verifier_allowed_tools(evidence_contract),
      "evidence_contract" => evidence_contract,
      "child_agent_contract" =>
        child_agent_contract(route_id, task, graph, gate, verifier, evidence_contract),
      "start_agent_work_params" =>
        start_agent_work_params(route_id, task, graph, verifier, evidence_contract),
      "created_at" => Clock.iso_now()
    }
    |> reject_empty()
  end

  def plan(_attrs), do: plan(%{})

  defp route_status(gate, blockers) do
    cond do
      gate["can_finish"] == true -> "not_required"
      blockers == [] -> "requested"
      true -> "requested"
    end
  end

  defp child_agent_contract(route_id, task, graph, gate, verifier, evidence_contract) do
    %{
      "schema_version" => "holtworks_child_agent_contract/v1",
      "contract_id" => Clock.id("child_contract"),
      "route_id" => route_id,
      "parent" => %{
        "task_id" => value(task, "id"),
        "task_ref" => value(task, "ref"),
        "graph_id" => value(graph, "id")
      },
      "child" => %{
        "target_agent_id" => value(verifier, "id"),
        "target_agent_ref" => value(verifier, "agent_ref"),
        "work_role" => "verifier"
      },
      "job_contract" => %{
        "expected_output_artifacts" => ["verification_report"],
        "gate_tool" => "route_verification_review",
        "evidence_contract" => evidence_contract
      },
      "authority_boundary" => %{
        "effect_scope" => "read_only",
        "may_delegate_further" => false,
        "may_mark_parent_done" => false
      },
      "blocking_gate" => gate
    }
    |> reject_empty()
  end

  defp start_agent_work_params(route_id, task, graph, verifier, evidence_contract) do
    %{
      "task_id" => value(task, "ref") || value(task, "id"),
      "graph_id" => value(graph, "id"),
      "node_key" => "verify",
      "agent_ids" => normalize_string_list(value(verifier, "id")),
      "source" => "task_graph_verifier_route",
      "message" => verifier_message(route_id, task, graph, evidence_contract)
    }
    |> reject_empty()
  end

  defp verifier_message(route_id, task, graph, evidence_contract) do
    required_groups =
      evidence_contract
      |> value("required_check_groups")
      |> List.wrap()
      |> Enum.map(fn group ->
        "#{value(group, "group_id")}: #{Enum.join(value(group, "any_of") || [], ", ")}"
      end)
      |> case do
        [] -> "none"
        rows -> Enum.join(rows, "; ")
      end

    """
    Verify task #{value(task, "ref")} before integration.

    Verifier route: #{route_id}
    Graph: #{value(graph, "id")}
    Required check groups: #{required_groups}

    Inspect task artifacts and worker handoff evidence. Submit route_verification_review with structured checks, changed_files, evidence, and surface statuses. Do not mark the parent task done directly.
    """
    |> String.trim()
  end

  defp verifier_allowed_tools(evidence_contract) do
    (@default_verifier_tools ++
       normalize_string_list(value(evidence_contract, "allowed_verifier_tools")))
    |> Enum.uniq()
  end

  defp select_verifier([]) do
    %{"id" => "default_verifier", "kind" => "agent", "display_name" => "Default Verifier"}
  end

  defp select_verifier(agents) do
    Enum.find(agents, &(value(&1, "work_role") == "verifier")) || List.first(agents)
  end

  defp normalize_agents(agents) when is_list(agents) do
    agents
    |> Enum.filter(&is_map/1)
    |> Enum.map(&string_keys/1)
    |> Enum.filter(&(value(&1, "kind") in [nil, "agent"]))
    |> Enum.reject(&(value(&1, "id") in [nil, ""]))
  end

  defp normalize_agents(_agents), do: []

  defp normalize_string_list(nil), do: []

  defp normalize_string_list(value) when is_list(value) do
    value
    |> Enum.flat_map(&normalize_string_list/1)
    |> Enum.uniq()
  end

  defp normalize_string_list(value) do
    text =
      value
      |> to_string()
      |> String.trim()

    if text == "", do: [], else: [text]
  end

  defp normalize_map(value) when is_map(value), do: string_keys(value)
  defp normalize_map(_value), do: %{}

  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp value(_map, _key), do: nil

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
