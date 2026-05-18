defmodule Holt.Tasks.VerifierAssignment do
  @moduledoc """
  Generic verifier assignment contract.

  The assignment engine chooses who should verify a work product before the
  parent task can integrate it. It enforces verifier independence: workers
  should not grade their own work.
  """

  alias Holt.Clock

  alias Holt.Tasks.{
    CapabilityContract,
    CapabilityIndex,
    CapabilityRouter
  }

  @schema_version "holt_verifier_assignment/v1"
  @independence_policy "different_agent_or_human"
  @base_verifier_actions ~w(
    get_task list_task_specs get_task_spec read_task_memory_artifact
    load_teammate_runtime route_verification_review
  )
  @capability_list_fields ~w(
    required_capabilities
    required_actions
    allowed_actions
    input_artifact_kinds
    expected_output_artifact_kinds
  )
  @agent_list_fields ~w(capabilities actions effect_scopes artifact_kinds)

  def assign(attrs \\ %{})

  def assign(attrs) when is_map(attrs) do
    case input(attrs) do
      {:ok, input} -> build_assignment(input)
      {:error, reason} -> rejected_assignment(reason)
    end
  end

  def assign(_attrs), do: rejected_assignment("invalid_attrs")

  defp input(attrs) do
    with :ok <- canonical_attrs(attrs),
         {:ok, work_graph} <- work_graph_field(attrs),
         {:ok, work_graph_gate} <- work_graph_gate_field(attrs),
         {:ok, evidence_contract} <- evidence_contract_field(attrs),
         {:ok, capability_contract} <- capability_contract_field(attrs, evidence_contract),
         {:ok, available_agents} <- available_agents_field(attrs),
         {:ok, allow_ephemeral?} <- allow_ephemeral_field(attrs),
         {:ok, verifier_quality} <- verifier_quality_field(attrs),
         {:ok, actor_agent_ids} <- actor_agent_ids_field(attrs, work_graph),
         {:ok, work_product_ref} <- work_product_ref_field(attrs, work_graph) do
      {:ok,
       %{
         work_graph: work_graph,
         work_graph_gate: work_graph_gate,
         evidence_contract: evidence_contract,
         capability_contract: capability_contract,
         available_agents: available_agents,
         allow_ephemeral?: allow_ephemeral?,
         verifier_quality: verifier_quality,
         actor_agent_ids: actor_agent_ids,
         work_product_ref: work_product_ref
       }}
    end
  end

  defp build_assignment(input) do
    candidates =
      input.available_agents
      |> CapabilityIndex.profiles()
      |> Enum.filter(&(Map.get(&1, "status") == "active"))
      |> Enum.map(
        &candidate_summary(
          &1,
          input.capability_contract,
          input.actor_agent_ids,
          input.verifier_quality
        )
      )
      |> Enum.sort_by(
        fn candidate -> {eligible_rank(candidate), candidate_score(candidate)} end,
        :desc
      )

    eligible_profiles =
      candidates
      |> Enum.filter(&eligible?/1)
      |> Enum.map(& &1["profile"])
      |> Enum.reject(&is_nil/1)

    capability_route = capability_route(eligible_profiles, input)
    selected_verifier = selected_verifier(capability_route, candidates, input.allow_ephemeral?)
    result = assignment_result(selected_verifier, input.allow_ephemeral?)

    %{
      "schema_version" => @schema_version,
      "assignment_id" =>
        stable_id("verifier_assignment", [
          input.work_product_ref,
          input.capability_contract["contract_id"],
          input.actor_agent_ids,
          selected_verifier
        ]),
      "work_product_ref" => input.work_product_ref,
      "assignment_result" => result,
      "reason" =>
        assignment_reason(result, selected_verifier, candidates, input.allow_ephemeral?),
      "independence_policy" => @independence_policy,
      "actor_agent_ids" => input.actor_agent_ids,
      "required_capabilities" => Map.get(input.capability_contract, "required_capabilities", []),
      "required_actions" => Map.get(input.capability_contract, "required_actions", []),
      "eligible_verifiers" => Enum.map(candidates, &Map.drop(&1, ["profile"])),
      "selected_verifier" => selected_verifier,
      "quality_policy" => "score_adjustment_from_verifier_calibration",
      "capability_contract" => input.capability_contract,
      "capability_route" => capability_route,
      "work_graph_gate_status" => input.work_graph_gate["status"],
      "created_at" => Clock.iso_now()
    }
    |> compact()
  end

  defp rejected_assignment(reason) do
    %{
      "schema_version" => @schema_version,
      "assignment_result" => "rejected",
      "reason" => reason,
      "created_at" => Clock.iso_now()
    }
  end

  defp capability_route(eligible_profiles, input) do
    cond do
      eligible_profiles != [] ->
        CapabilityRouter.route(%{
          "capability_contract" => input.capability_contract,
          "available_agents" => Enum.take(eligible_profiles, 1)
        })

      input.allow_ephemeral? ->
        CapabilityRouter.route(%{
          "capability_contract" => input.capability_contract,
          "available_agents" => []
        })

      true ->
        nil
    end
  end

  defp candidate_summary(profile, contract, actor_agent_ids, verifier_quality) do
    required_capabilities = Map.get(contract, "required_capabilities", [])
    required_actions = Map.get(contract, "required_actions", [])
    effect_scope = contract["effect_scope"]
    expected_artifacts = Map.get(contract, "expected_output_artifact_kinds", [])
    independent? = independent?(profile, actor_agent_ids)

    missing_capabilities =
      Enum.reject(required_capabilities, &CapabilityIndex.capability_available?(profile, &1))

    missing_actions =
      Enum.reject(required_actions, &CapabilityIndex.action_available?(profile, &1))

    effect_scope_match? = effect_scope_match?(effect_scope, profile)

    artifact_matches =
      expected_artifacts
      |> Enum.count(&(&1 in Map.get(profile, "artifact_kinds", [])))

    quality = verifier_quality_for_profile(profile, verifier_quality)
    quality_adjustment = quality_score_adjustment(quality)

    score =
      (length(required_capabilities) - length(missing_capabilities)) * 10 +
        (length(required_actions) - length(missing_actions)) * 6 +
        artifact_matches * 3 +
        if(effect_scope_match?, do: 4, else: 0) +
        if(independent?, do: 12, else: -100) +
        quality_adjustment

    %{
      "agent_id" => profile["agent_id"],
      "agent_ref" => profile["agent_ref"],
      "handle" => profile["handle"],
      "name" => profile["name"],
      "score" => score,
      "eligible" =>
        independent? and missing_capabilities == [] and missing_actions == [] and
          effect_scope_match?,
      "independence_status" => if(independent?, do: "independent", else: "same_actor"),
      "missing_capabilities" => missing_capabilities,
      "missing_actions" => missing_actions,
      "effect_scope_match" => effect_scope_match?,
      "artifact_match_count" => artifact_matches,
      "verifier_quality" => quality,
      "quality_score_adjustment" => quality_adjustment,
      "profile" => profile
    }
    |> compact()
  end

  defp selected_verifier(nil, _candidates, _allow_ephemeral?), do: nil

  defp selected_verifier(%{"execution_mode" => "persisted_agent"} = route, candidates, _allow?) do
    target_agent_id = route["target_agent_id"]
    selected_candidate = Enum.find(candidates, &(&1["agent_id"] == target_agent_id))

    %{
      "execution_mode" => "persisted_agent",
      "agent_id" => target_agent_id,
      "agent_ref" => route["target_agent_ref"],
      "handle" => route["target_agent_handle"],
      "name" => route["target_agent_name"],
      "score" => route["score"],
      "independence_status" => selected_independence_status(selected_candidate)
    }
    |> compact()
  end

  defp selected_verifier(%{"execution_mode" => "ephemeral_sub_agent"} = route, _candidates, true) do
    %{
      "execution_mode" => "ephemeral_sub_agent",
      "agent_id" => "work_graph_verifier",
      "name" => "Ephemeral verifier",
      "independence_status" => "ephemeral_independent",
      "score" => Map.get(route, "score", 0)
    }
  end

  defp selected_verifier(_route, _candidates, _allow_ephemeral?), do: nil

  defp assignment_result(selected_verifier, _allow_ephemeral?) when is_map(selected_verifier),
    do: "assigned"

  defp assignment_result(_selected_verifier, false), do: "human_review_required"
  defp assignment_result(_selected_verifier, _allow_ephemeral?), do: "blocked"

  defp assignment_reason("assigned", selected_verifier, _candidates, _allow_ephemeral?) do
    "verifier_assigned:" <> selected_verifier["execution_mode"]
  end

  defp assignment_reason("human_review_required", _selected_verifier, [], false),
    do: "no_candidate_verifiers_available"

  defp assignment_reason("human_review_required", _selected_verifier, _candidates, false),
    do: "no_independent_capable_verifier"

  defp assignment_reason(_result, _selected_verifier, _candidates, _allow_ephemeral?),
    do: "verifier_assignment_failed_closed"

  defp independent?(profile, actor_agent_ids) do
    candidate_ids =
      [profile["agent_id"], profile["agent_ref"], profile["handle"]]
      |> present_strings()

    MapSet.disjoint?(MapSet.new(candidate_ids), MapSet.new(actor_agent_ids))
  end

  defp verifier_quality_for_profile(profile, verifier_quality) do
    [profile["agent_id"], profile["agent_ref"], profile["handle"]]
    |> present_strings()
    |> Enum.find_value(%{}, &Map.get(verifier_quality, &1))
  end

  defp quality_score_adjustment(quality) when is_map(quality) and map_size(quality) > 0 do
    accuracy = Map.get(quality, "accuracy", 0.5)
    missed = Map.get(quality, "missed_failure_count", 0)
    false_blocks = Map.get(quality, "false_block_count", 0)
    matched = Map.get(quality, "matched_count", 0)

    base = round((accuracy - 0.5) * 20)
    positive = min(matched, 5)
    penalty = min(missed * 8 + false_blocks * 4, 30)

    base + positive - penalty
  end

  defp quality_score_adjustment(_quality), do: 0

  defp work_graph_field(attrs) do
    with {:ok, work_graph} <- required_map(attrs, "work_graph", "invalid_work_graph"),
         {:ok, work_graph} <- optional_text_field(work_graph, "id", "invalid_work_graph"),
         {:ok, work_graph} <- optional_text_field(work_graph, "graph_id", "invalid_work_graph"),
         {:ok, work_graph} <- optional_text_field(work_graph, "agent_id", "invalid_work_graph"),
         {:ok, nodes} <- work_graph_nodes(work_graph),
         :ok <- work_graph_identity(work_graph) do
      {:ok, Map.put(work_graph, "nodes", nodes) |> compact()}
    end
  end

  defp work_graph_identity(%{"id" => id}) when is_binary(id) and id != "", do: :ok
  defp work_graph_identity(%{"graph_id" => id}) when is_binary(id) and id != "", do: :ok
  defp work_graph_identity(_work_graph), do: {:error, "invalid_work_graph"}

  defp work_graph_gate_field(attrs) do
    with {:ok, gate} <- optional_map(attrs, "work_graph_gate", "invalid_work_graph_gate"),
         {:ok, gate} <- optional_text_field(gate, "status", "invalid_work_graph_gate"),
         {:ok, gate} <- optional_boolean_field(gate, "can_finish", "invalid_work_graph_gate") do
      {:ok, gate}
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
           ) do
      {:ok,
       evidence_contract
       |> Map.put("allowed_verifier_actions", actions)
       |> compact()}
    end
  end

  defp capability_contract_field(attrs, evidence_contract) do
    case Map.fetch(attrs, "capability_contract") do
      {:ok, contract} when is_map(contract) and contract != %{} ->
        validate_capability_contract(contract)

      {:ok, contract} when is_map(contract) ->
        default_capability_contract(evidence_contract)

      {:ok, _contract} ->
        {:error, "invalid_capability_contract"}

      :error ->
        default_capability_contract(evidence_contract)
    end
  end

  defp default_capability_contract(evidence_contract) do
    contract =
      CapabilityContract.build(%{
        "role" => "verifier",
        "effect_scope" => "read_only",
        "evidence_contract" => evidence_contract,
        "allowed_actions" => verifier_allowed_actions(evidence_contract),
        "required_actions" => ["route_verification_review"],
        "input_artifact_kinds" => ~w(handoff verification_report),
        "expected_output_artifact_kinds" => ["verification_report"]
      })

    case contract do
      %{"status" => "rejected"} -> {:error, "invalid_capability_contract"}
      value -> validate_capability_contract(value)
    end
  end

  defp validate_capability_contract(contract) do
    with :ok <- validate_optional_text(contract, "effect_scope", "invalid_capability_contract"),
         :ok <-
           validate_string_list_fields(
             contract,
             @capability_list_fields,
             "invalid_capability_contract"
           ) do
      {:ok, contract}
    end
  end

  defp available_agents_field(attrs) do
    case Map.fetch(attrs, "available_agents") do
      {:ok, agents} when is_list(agents) -> available_agents(agents)
      {:ok, _agents} -> {:error, "invalid_available_agents"}
      :error -> {:ok, []}
    end
  end

  defp available_agents(agents) do
    agents
    |> Enum.reduce_while({:ok, []}, fn
      agent, {:ok, acc} when is_map(agent) ->
        case validate_agent(agent) do
          {:ok, value} -> {:cont, {:ok, [value | acc]}}
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

  defp validate_agent(agent) do
    with :ok <- validate_optional_text(agent, "agent_id", "invalid_available_agents"),
         :ok <- validate_optional_text(agent, "id", "invalid_available_agents"),
         :ok <- validate_optional_text(agent, "agent_ref", "invalid_available_agents"),
         :ok <- validate_optional_text(agent, "agent_handle", "invalid_available_agents"),
         :ok <- validate_optional_text(agent, "display_name", "invalid_available_agents"),
         :ok <- validate_optional_text(agent, "work_role", "invalid_available_agents"),
         :ok <- validate_optional_text(agent, "status", "invalid_available_agents"),
         :ok <- validate_string_list_fields(agent, @agent_list_fields, "invalid_available_agents"),
         {:ok, agent_id} <- agent_id(agent) do
      {:ok, Map.put(agent, "agent_id", agent_id)}
    end
  end

  defp agent_id(%{"agent_id" => agent_id}) when is_binary(agent_id) and agent_id != "",
    do: {:ok, agent_id}

  defp agent_id(%{"id" => id}) when is_binary(id) and id != "",
    do: {:ok, id}

  defp agent_id(_agent), do: {:error, "invalid_available_agents"}

  defp allow_ephemeral_field(attrs) do
    case Map.fetch(attrs, "allow_ephemeral_verifier") do
      {:ok, value} when is_boolean(value) -> {:ok, value}
      {:ok, _value} -> {:error, "invalid_allow_ephemeral_verifier"}
      :error -> {:ok, true}
    end
  end

  defp verifier_quality_field(attrs) do
    case Map.fetch(attrs, "verifier_quality") do
      {:ok, values} when is_list(values) -> verifier_quality_list(values)
      {:ok, value} when is_map(value) -> verifier_quality_map(value)
      {:ok, _value} -> {:error, "invalid_verifier_quality"}
      :error -> {:ok, %{}}
    end
  end

  defp verifier_quality_list(values) do
    values
    |> Enum.reduce_while({:ok, %{}}, fn
      quality, {:ok, acc} when is_map(quality) ->
        case quality_record(quality) do
          {:ok, record} -> {:cont, {:ok, index_quality(record, acc)}}
          error -> {:halt, error}
        end

      _quality, {:ok, _acc} ->
        {:halt, {:error, "invalid_verifier_quality"}}
    end)
  end

  defp verifier_quality_map(%{"verifier_agent_id" => _id} = value) do
    verifier_quality_list([value])
  end

  defp verifier_quality_map(value) do
    value
    |> Enum.reduce_while({:ok, %{}}, fn
      {key, quality}, {:ok, acc} when is_binary(key) and is_map(quality) ->
        quality = Map.put_new(quality, "verifier_agent_id", key)

        case quality_record(quality) do
          {:ok, record} -> {:cont, {:ok, index_quality(record, acc)}}
          error -> {:halt, error}
        end

      _entry, {:ok, _acc} ->
        {:halt, {:error, "invalid_verifier_quality"}}
    end)
  end

  defp quality_record(quality) do
    with {:ok, quality} <-
           optional_text_field(quality, "verifier_agent_id", "invalid_verifier_quality"),
         {:ok, quality} <- optional_text_field(quality, "agent_id", "invalid_verifier_quality"),
         {:ok, quality} <- optional_text_field(quality, "agent_ref", "invalid_verifier_quality"),
         {:ok, quality} <- optional_text_field(quality, "handle", "invalid_verifier_quality"),
         {:ok, quality} <- optional_number_field(quality, "accuracy", "invalid_verifier_quality"),
         {:ok, quality} <-
           optional_integer_field(quality, "missed_failure_count", "invalid_verifier_quality"),
         {:ok, quality} <-
           optional_integer_field(quality, "false_block_count", "invalid_verifier_quality"),
         {:ok, quality} <-
           optional_integer_field(quality, "matched_count", "invalid_verifier_quality") do
      {:ok, quality}
    end
  end

  defp index_quality(quality, acc) do
    [
      quality["verifier_agent_id"],
      quality["agent_id"],
      quality["agent_ref"],
      quality["handle"]
    ]
    |> present_strings()
    |> Enum.reduce(acc, fn key, inner -> Map.put(inner, key, quality) end)
  end

  defp actor_agent_ids_field(attrs, work_graph) do
    with {:ok, explicit} <-
           optional_string_list(attrs, "actor_agent_ids", "invalid_actor_agent_ids"),
         {:ok, run} <- optional_map(attrs, "run", "invalid_run"),
         {:ok, run} <- optional_text_field(run, "agent_id", "invalid_run") do
      graph_actors =
        work_graph
        |> Map.get("nodes", [])
        |> Enum.filter(&worker_node?/1)
        |> Enum.flat_map(&node_actor_ids/1)

      {:ok,
       present_strings(explicit ++ graph_actors ++ [run["agent_id"], work_graph["agent_id"]])}
    end
  end

  defp worker_node?(%{"kind" => "child_agent", "role" => "verifier"}), do: false
  defp worker_node?(%{"kind" => "child_agent"}), do: true
  defp worker_node?(_node), do: false

  defp node_actor_ids(node) do
    [
      node["target_agent_id"],
      node["agent_id"],
      node["child_ref"],
      node["parent_agent_id"]
    ]
  end

  defp work_product_ref_field(attrs, work_graph) do
    [
      Map.get(attrs, "work_product_ref"),
      work_graph["graph_id"],
      work_graph["id"],
      Map.get(attrs, "artifact_ref"),
      Map.get(attrs, "action_call_id")
    ]
    |> present_strings()
    |> case do
      [ref | _rest] -> {:ok, ref}
      [] -> {:error, "invalid_work_product_ref"}
    end
  end

  defp verifier_allowed_actions(evidence_contract) do
    (@base_verifier_actions ++ Map.get(evidence_contract, "allowed_verifier_actions", []))
    |> Enum.uniq()
  end

  defp work_graph_nodes(work_graph) do
    case Map.fetch(work_graph, "nodes") do
      {:ok, nodes} when is_list(nodes) -> nodes(nodes)
      {:ok, _nodes} -> {:error, "invalid_work_graph"}
      :error -> {:ok, []}
    end
  end

  defp nodes(nodes) do
    nodes
    |> Enum.reduce_while({:ok, []}, fn
      node, {:ok, acc} when is_map(node) ->
        case validate_node(node) do
          {:ok, value} -> {:cont, {:ok, [value | acc]}}
          error -> {:halt, error}
        end

      _node, {:ok, _acc} ->
        {:halt, {:error, "invalid_work_graph"}}
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp validate_node(node) do
    with :ok <- validate_optional_text(node, "kind", "invalid_work_graph"),
         :ok <- validate_optional_text(node, "role", "invalid_work_graph"),
         :ok <- validate_optional_text(node, "target_agent_id", "invalid_work_graph"),
         :ok <- validate_optional_text(node, "agent_id", "invalid_work_graph"),
         :ok <- validate_optional_text(node, "child_ref", "invalid_work_graph"),
         :ok <- validate_optional_text(node, "parent_agent_id", "invalid_work_graph") do
      {:ok, node}
    end
  end

  defp candidate_score(candidate), do: Map.get(candidate, "score", 0)

  defp eligible?(%{"eligible" => true}), do: true
  defp eligible?(_candidate), do: false

  defp eligible_rank(candidate) do
    if eligible?(candidate), do: 1, else: 0
  end

  defp selected_independence_status(%{"independence_status" => status}), do: status
  defp selected_independence_status(_candidate), do: nil

  defp effect_scope_match?(effect_scope, _profile) when effect_scope in [nil, "", "unknown"],
    do: true

  defp effect_scope_match?(effect_scope, profile),
    do: effect_scope in Map.get(profile, "effect_scopes", [])

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

  defp optional_boolean_field(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, value} when is_boolean(value) -> {:ok, Map.put(map, key, value)}
      {:ok, _value} -> {:error, reason}
      :error -> {:ok, map}
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

  defp optional_number_field(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, value} when is_integer(value) -> {:ok, Map.put(map, key, value * 1.0)}
      {:ok, value} when is_float(value) -> {:ok, map}
      {:ok, _value} -> {:error, reason}
      :error -> {:ok, map}
    end
  end

  defp optional_integer_field(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, value} when is_integer(value) and value >= 0 -> {:ok, map}
      {:ok, _value} -> {:error, reason}
      :error -> {:ok, map}
    end
  end

  defp optional_string_list(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, value} -> string_list(value, reason)
      :error -> {:ok, []}
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
      {:ok, normalized} -> {:ok, Enum.uniq(Enum.reverse(normalized))}
      error -> error
    end
  end

  defp string_list(_values, reason), do: {:error, reason}

  defp validate_string_list_fields(map, fields, reason) do
    case Enum.find(fields, &(not optional_string_list_field?(map, &1))) do
      nil -> :ok
      _field -> {:error, reason}
    end
  end

  defp optional_string_list_field?(map, key) do
    case Map.fetch(map, key) do
      {:ok, values} -> valid_string_list?(values)
      :error -> true
    end
  end

  defp valid_string_list?(values) when is_list(values) do
    Enum.all?(values, &(is_binary(&1) and String.trim(&1) != ""))
  end

  defp valid_string_list?(_values), do: false

  defp validate_optional_text(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) ->
        if String.trim(value) == "", do: {:error, reason}, else: :ok

      {:ok, _value} ->
        {:error, reason}

      :error ->
        :ok
    end
  end

  defp present_strings(values) do
    values
    |> Enum.reduce([], fn
      value, acc when is_binary(value) ->
        case String.trim(value) do
          "" -> acc
          text -> acc ++ [text]
        end

      _value, acc ->
        acc
    end)
    |> Enum.uniq()
  end

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
end
