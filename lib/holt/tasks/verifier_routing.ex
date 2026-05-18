defmodule Holt.Tasks.VerifierRouting do
  @moduledoc """
  Deterministic verifier route planning for local task graphs.

  The route is a bounded contract for a verifier agent. It does not execute the
  verifier by itself; callers can pass the returned `start_agent_work_params`
  into the existing agent-work API.
  """

  alias Holt.Clock

  @schema_version "holt_verifier_routing/v1"
  @default_verifier_actions ~w(
    get_task list_task_specs get_task_spec read_task_memory_artifact
    load_teammate_runtime route_verification_review
  )
  @obsolete_plan_keys ~w(graph)

  def plan(attrs \\ %{})

  def plan(attrs) when is_map(attrs) do
    case input(attrs) do
      {:ok, input} -> build_plan(input)
      {:error, reason} -> rejected_route(reason)
    end
  end

  def plan(_attrs), do: rejected_route("invalid_attrs")

  defp input(attrs) do
    with :ok <- canonical_attrs(attrs),
         :ok <- reject_obsolete_keys(attrs),
         {:ok, task} <- required_map(attrs, "task", "invalid_task"),
         {:ok, graph} <- required_map(attrs, "task_graph", "invalid_task_graph"),
         {:ok, gate} <- optional_map(attrs, "task_graph_gate", "invalid_task_graph_gate"),
         {:ok, evidence_contract} <- evidence_contract_field(attrs),
         {:ok, available_agents} <- available_agents_field(attrs),
         {:ok, blockers} <- blocker_list(gate) do
      {:ok,
       %{
         task: task,
         graph: graph,
         gate: gate,
         blockers: blockers,
         evidence_contract: evidence_contract,
         available_agents: available_agents
       }}
    end
  end

  defp build_plan(input) do
    verifier = select_verifier(input.available_agents)
    status = route_status(input.gate)
    route_id = Clock.id("verifier_route")

    %{
      "schema_version" => @schema_version,
      "route_id" => route_id,
      "status" => status,
      "trigger_blockers" => Enum.map(input.blockers, & &1["code"]),
      "task_id" => input.task["id"],
      "task_ref" => input.task["ref"],
      "graph_id" => input.graph["id"],
      "graph_status" => input.graph["status"],
      "work_role" => "verifier",
      "target_agent_id" => verifier["id"],
      "target_agent_ref" => verifier["agent_ref"],
      "target_agent_handle" => verifier["agent_handle"],
      "allowed_actions" => verifier_allowed_actions(input.evidence_contract),
      "evidence_contract" => input.evidence_contract,
      "child_agent_contract" =>
        child_agent_contract(
          route_id,
          input.task,
          input.graph,
          input.gate,
          verifier,
          input.evidence_contract
        ),
      "start_agent_work_params" =>
        start_agent_work_params(
          route_id,
          input.task,
          input.graph,
          verifier,
          input.evidence_contract
        ),
      "created_at" => Clock.iso_now()
    }
    |> compact()
  end

  defp rejected_route(reason) do
    %{
      "schema_version" => @schema_version,
      "status" => "rejected",
      "reason" => reason,
      "created_at" => Clock.iso_now()
    }
  end

  defp route_status(%{"can_finish" => true}), do: "not_required"
  defp route_status(_gate), do: "requested"

  defp child_agent_contract(route_id, task, graph, gate, verifier, evidence_contract) do
    %{
      "schema_version" => "holt_child_agent_contract/v1",
      "contract_id" => Clock.id("child_contract"),
      "route_id" => route_id,
      "parent" => %{
        "task_id" => task["id"],
        "task_ref" => task["ref"],
        "graph_id" => graph["id"]
      },
      "child" => %{
        "target_agent_id" => verifier["id"],
        "target_agent_ref" => verifier["agent_ref"],
        "work_role" => "verifier"
      },
      "job_contract" => %{
        "expected_output_artifacts" => ["verification_report"],
        "gate_action" => "route_verification_review",
        "evidence_contract" => evidence_contract
      },
      "authority_boundary" => %{
        "effect_scope" => "read_only",
        "may_delegate_further" => false,
        "may_mark_parent_done" => false
      },
      "blocking_gate" => gate
    }
    |> compact()
  end

  defp start_agent_work_params(route_id, task, graph, verifier, evidence_contract) do
    %{
      "task_id" => task["ref"],
      "graph_id" => graph["id"],
      "node_key" => "verify",
      "agent_ids" => [verifier["id"]],
      "source" => "task_graph_verifier_route",
      "message" => verifier_message(route_id, task, graph, evidence_contract)
    }
    |> compact()
  end

  defp verifier_message(route_id, task, graph, evidence_contract) do
    required_groups =
      evidence_contract
      |> Map.get("required_check_groups", [])
      |> Enum.map(fn group ->
        "#{group["group_id"]}: #{Enum.join(group["any_of"], ", ")}"
      end)
      |> case do
        [] -> "none"
        rows -> Enum.join(rows, "; ")
      end

    """
    Verify task #{task["ref"]} before integration.

    Verifier route: #{route_id}
    Graph: #{graph["id"]}
    Required check groups: #{required_groups}

    Inspect task artifacts and worker handoff evidence. Submit route_verification_review with structured checks, changed_files, evidence, and surface statuses. Do not mark the parent task done directly.
    """
    |> String.trim()
  end

  defp verifier_allowed_actions(evidence_contract) do
    actions = Map.get(evidence_contract, "allowed_verifier_actions", [])

    (@default_verifier_actions ++ actions)
    |> Enum.uniq()
  end

  defp select_verifier([]), do: default_verifier()

  defp select_verifier(agents) do
    case Enum.find(agents, &verifier_agent?/1) do
      nil -> default_verifier()
      verifier -> verifier
    end
  end

  defp verifier_agent?(%{"work_role" => "verifier"}), do: true
  defp verifier_agent?(%{"work_roles" => roles}) when is_list(roles), do: "verifier" in roles
  defp verifier_agent?(_agent), do: false

  defp default_verifier do
    %{"id" => "default_verifier", "kind" => "agent", "display_name" => "Default Verifier"}
  end

  defp reject_obsolete_keys(attrs) do
    attrs
    |> Map.keys()
    |> Enum.find(&(&1 in @obsolete_plan_keys))
    |> obsolete_key_result()
  end

  defp obsolete_key_result(nil), do: :ok
  defp obsolete_key_result(key), do: {:error, "obsolete_key:" <> key}

  defp required_map(attrs, key, reason) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _value} -> {:error, reason}
      :error -> {:error, reason}
    end
  end

  defp optional_map(attrs, key, reason) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _value} -> {:error, reason}
      :error -> {:ok, %{}}
    end
  end

  defp evidence_contract_field(attrs) do
    with {:ok, evidence_contract} <-
           optional_map(attrs, "evidence_contract", "invalid_evidence_contract"),
         {:ok, actions} <-
           optional_string_list(
             evidence_contract,
             "allowed_verifier_actions",
             "invalid_evidence_contract"
           ),
         {:ok, groups} <- required_check_groups(evidence_contract) do
      {:ok,
       evidence_contract
       |> Map.put("allowed_verifier_actions", actions)
       |> Map.put("required_check_groups", groups)
       |> compact()}
    end
  end

  defp required_check_groups(evidence_contract) do
    case Map.fetch(evidence_contract, "required_check_groups") do
      {:ok, groups} when is_list(groups) -> check_groups(groups)
      {:ok, _groups} -> {:error, "invalid_evidence_contract"}
      :error -> {:ok, []}
    end
  end

  defp check_groups(groups) do
    groups
    |> Enum.reduce_while({:ok, []}, fn
      group, {:ok, acc} when is_map(group) ->
        case check_group(group) do
          {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
          error -> {:halt, error}
        end

      _group, {:ok, _acc} ->
        {:halt, {:error, "invalid_evidence_contract"}}
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp check_group(group) do
    with {:ok, group_id} <- required_text(group, "group_id", "invalid_evidence_contract"),
         {:ok, any_of} <- required_string_list(group, "any_of", "invalid_evidence_contract") do
      {:ok, %{"group_id" => group_id, "any_of" => any_of}}
    end
  end

  defp available_agents_field(attrs) do
    case Map.fetch(attrs, "available_agents") do
      {:ok, value} when is_list(value) -> available_agents(value)
      {:ok, _value} -> {:error, "invalid_available_agents"}
      :error -> {:ok, []}
    end
  end

  defp available_agents(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn
      agent, {:ok, acc} when is_map(agent) ->
        case agent_profile(agent) do
          {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
          error -> {:halt, error}
        end

      _agent, {:ok, _acc} ->
        {:halt, {:error, "invalid_available_agents"}}
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp agent_profile(agent) do
    with {:ok, id} <- required_text(agent, "id", "invalid_available_agents"),
         {:ok, kind} <- optional_agent_kind(agent),
         {:ok, agent} <- optional_text_field(agent, "agent_ref", "invalid_available_agents"),
         {:ok, agent} <- optional_text_field(agent, "agent_handle", "invalid_available_agents"),
         {:ok, agent} <- optional_text_field(agent, "work_role", "invalid_available_agents"),
         {:ok, agent} <-
           optional_string_list_field(agent, "work_roles", "invalid_available_agents") do
      {:ok,
       agent
       |> Map.put("id", id)
       |> maybe_put("kind", kind)
       |> compact()}
    end
  end

  defp optional_agent_kind(agent) do
    case Map.fetch(agent, "kind") do
      {:ok, "agent"} -> {:ok, "agent"}
      {:ok, _kind} -> {:error, "invalid_available_agents"}
      :error -> {:ok, nil}
    end
  end

  defp blocker_list(gate) do
    case Map.fetch(gate, "blockers") do
      {:ok, blockers} when is_list(blockers) -> blockers(blockers)
      {:ok, _blockers} -> {:error, "invalid_task_graph_gate"}
      :error -> {:ok, []}
    end
  end

  defp blockers(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn
      blocker, {:ok, acc} when is_map(blocker) ->
        case required_text(blocker, "code", "invalid_task_graph_gate") do
          {:ok, code} -> {:cont, {:ok, [Map.put(blocker, "code", code) | acc]}}
          error -> {:halt, error}
        end

      _blocker, {:ok, _acc} ->
        {:halt, {:error, "invalid_task_graph_gate"}}
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp optional_text_field(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, reason}
          text -> {:ok, Map.put(map, key, text)}
        end

      {:ok, _value} ->
        {:error, reason}

      :error ->
        {:ok, map}
    end
  end

  defp optional_string_list_field(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, values} ->
        case string_list(values, reason) do
          {:ok, normalized} -> {:ok, Map.put(map, key, normalized)}
          error -> error
        end

      :error ->
        {:ok, map}
    end
  end

  defp optional_string_list(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, values} -> string_list(values, reason)
      :error -> {:ok, []}
    end
  end

  defp required_string_list(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, values} -> string_list(values, reason)
      :error -> {:error, reason}
    end
  end

  defp string_list(values, reason) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn
      value, {:ok, acc} when is_binary(value) ->
        case String.trim(value) do
          "" -> {:halt, {:error, reason}}
          text -> {:cont, {:ok, [text | acc]}}
        end

      _value, {:ok, _acc} ->
        {:halt, {:error, reason}}
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp string_list(_values, reason), do: {:error, reason}

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

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

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

  defp compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end
end
