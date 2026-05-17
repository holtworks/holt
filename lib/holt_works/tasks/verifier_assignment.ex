defmodule HoltWorks.Tasks.VerifierAssignment do
  @moduledoc """
  Generic verifier assignment contract.

  The assignment engine chooses who should verify a work product before the
  parent task can integrate it. It enforces verifier independence: workers
  should not grade their own work.
  """

  alias HoltWorks.Clock

  alias HoltWorks.Tasks.{
    CapabilityContract,
    CapabilityIndex,
    CapabilityRouter,
    RuntimeContracts
  }

  @schema_version "holtworks_verifier_assignment/v1"
  @independence_policy "different_agent_or_human"

  def assign(attrs \\ %{})

  def assign(attrs) when is_map(attrs) do
    attrs = RuntimeContracts.string_keys(attrs)
    work_graph = RuntimeContracts.normalize_map(attrs["work_graph"])

    work_graph_gate =
      RuntimeContracts.normalize_map(attrs["work_graph_gate"] || work_graph["completion_gate"])

    evidence_contract = RuntimeContracts.normalize_map(attrs["evidence_contract"])
    capability_contract = capability_contract(attrs, evidence_contract)
    actor_agent_ids = actor_agent_ids(attrs, work_graph)
    allow_ephemeral? = RuntimeContracts.value(attrs, "allow_ephemeral_verifier") != false
    verifier_quality = verifier_quality_map(attrs["verifier_quality"])

    candidates =
      attrs
      |> RuntimeContracts.value("available_agents")
      |> CapabilityIndex.profiles()
      |> Enum.filter(&(RuntimeContracts.value(&1, "status") == "active"))
      |> Enum.map(&candidate_summary(&1, capability_contract, actor_agent_ids, verifier_quality))
      |> Enum.sort_by(
        fn candidate ->
          {if(RuntimeContracts.truthy?(candidate["eligible"]), do: 1, else: 0),
           candidate["score"] || 0}
        end,
        :desc
      )

    eligible_profiles =
      candidates
      |> Enum.filter(&RuntimeContracts.truthy?(&1["eligible"]))
      |> Enum.map(& &1["profile"])
      |> Enum.reject(&is_nil/1)

    capability_route =
      cond do
        eligible_profiles != [] ->
          CapabilityRouter.route(%{
            "capability_contract" => capability_contract,
            "available_agents" => Enum.take(eligible_profiles, 1)
          })

        allow_ephemeral? ->
          CapabilityRouter.route(%{
            "capability_contract" => capability_contract,
            "available_agents" => []
          })

        true ->
          nil
      end

    selected_verifier = selected_verifier(capability_route, candidates, allow_ephemeral?)
    result = assignment_result(selected_verifier, capability_route, allow_ephemeral?)

    %{
      "schema_version" => @schema_version,
      "assignment_id" =>
        RuntimeContracts.stable_id("verifier_assignment", [
          work_product_ref(work_graph, attrs),
          capability_contract["contract_id"],
          actor_agent_ids,
          selected_verifier
        ]),
      "work_product_ref" => work_product_ref(work_graph, attrs),
      "assignment_result" => result,
      "reason" => assignment_reason(result, selected_verifier, candidates, allow_ephemeral?),
      "independence_policy" => @independence_policy,
      "actor_agent_ids" => actor_agent_ids,
      "required_capabilities" => capability_contract["required_capabilities"] || [],
      "required_tools" => capability_contract["required_tools"] || [],
      "eligible_verifiers" => Enum.map(candidates, &Map.drop(&1, ["profile"])),
      "selected_verifier" => selected_verifier,
      "quality_policy" => "score_adjustment_from_verifier_calibration",
      "capability_contract" => capability_contract,
      "capability_route" => capability_route,
      "work_graph_gate_status" => work_graph_gate["status"],
      "created_at" => Clock.iso_now()
    }
    |> RuntimeContracts.reject_empty()
  end

  def assign(_attrs), do: assign(%{})

  defp capability_contract(attrs, evidence_contract) do
    case RuntimeContracts.value(attrs, "capability_contract") do
      contract when is_map(contract) and map_size(contract) > 0 ->
        RuntimeContracts.string_keys(contract)

      _missing ->
        CapabilityContract.build(%{
          "role" => "verifier",
          "effect_scope" => "read_only",
          "evidence_contract" => evidence_contract,
          "allowed_tools" => verifier_allowed_tools(evidence_contract),
          "required_tools" => ["route_verification_review"],
          "input_artifact_kinds" => ~w(handoff verification_report),
          "expected_output_artifact_kinds" => ["verification_report"]
        })
    end
  end

  defp candidate_summary(profile, contract, actor_agent_ids, verifier_quality) do
    required_capabilities =
      RuntimeContracts.normalize_string_list(contract["required_capabilities"])

    required_tools = RuntimeContracts.normalize_string_list(contract["required_tools"])
    effect_scope = contract["effect_scope"]

    expected_artifacts =
      RuntimeContracts.normalize_string_list(contract["expected_output_artifact_kinds"])

    independent? = independent?(profile, actor_agent_ids)

    missing_capabilities =
      Enum.reject(required_capabilities, &CapabilityIndex.capability_available?(profile, &1))

    missing_tools = Enum.reject(required_tools, &CapabilityIndex.tool_available?(profile, &1))

    effect_scope_match? =
      effect_scope in [nil, "", "unknown"] or
        effect_scope in RuntimeContracts.normalize_string_list(profile["effect_scopes"])

    artifact_matches =
      expected_artifacts
      |> Enum.count(&(&1 in RuntimeContracts.normalize_string_list(profile["artifact_kinds"])))

    quality = verifier_quality_for_profile(profile, verifier_quality)
    quality_adjustment = quality_score_adjustment(quality)

    score =
      (length(required_capabilities) - length(missing_capabilities)) * 10 +
        (length(required_tools) - length(missing_tools)) * 6 +
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
        independent? and missing_capabilities == [] and missing_tools == [] and
          effect_scope_match?,
      "independence_status" => if(independent?, do: "independent", else: "same_actor"),
      "missing_capabilities" => missing_capabilities,
      "missing_tools" => missing_tools,
      "effect_scope_match" => effect_scope_match?,
      "artifact_match_count" => artifact_matches,
      "verifier_quality" => quality,
      "quality_score_adjustment" => quality_adjustment,
      "profile" => profile
    }
    |> RuntimeContracts.reject_empty()
  end

  defp selected_verifier(nil, _candidates, _allow_ephemeral?), do: nil

  defp selected_verifier(capability_route, candidates, allow_ephemeral?) do
    case RuntimeContracts.value(capability_route, "execution_mode") do
      "persisted_agent" ->
        target_agent_id = capability_route["target_agent_id"]
        selected_candidate = Enum.find(candidates, &(&1["agent_id"] == target_agent_id))

        %{
          "execution_mode" => "persisted_agent",
          "agent_id" => target_agent_id,
          "agent_ref" => capability_route["target_agent_ref"],
          "handle" => capability_route["target_agent_handle"],
          "name" => capability_route["target_agent_name"],
          "score" => capability_route["score"],
          "independence_status" =>
            RuntimeContracts.value(selected_candidate || %{}, "independence_status")
        }
        |> RuntimeContracts.reject_empty()

      "ephemeral_sub_agent" ->
        if allow_ephemeral? do
          %{
            "execution_mode" => "ephemeral_sub_agent",
            "agent_id" => "work_graph_verifier",
            "name" => "Ephemeral verifier",
            "independence_status" => "ephemeral_independent",
            "score" => capability_route["score"] || 0
          }
        end

      _other ->
        nil
    end
  end

  defp assignment_result(selected_verifier, _capability_route, _allow_ephemeral?)
       when is_map(selected_verifier),
       do: "assigned"

  defp assignment_result(_selected_verifier, _capability_route, false),
    do: "human_review_required"

  defp assignment_result(_selected_verifier, _capability_route, _allow_ephemeral?), do: "blocked"

  defp assignment_reason("assigned", selected_verifier, _candidates, _allow_ephemeral?) do
    "verifier_assigned:" <> to_string(selected_verifier["execution_mode"])
  end

  defp assignment_reason("human_review_required", _selected_verifier, candidates, false) do
    if candidates == [] do
      "no_candidate_verifiers_available"
    else
      "no_independent_capable_verifier"
    end
  end

  defp assignment_reason(_result, _selected_verifier, _candidates, _allow_ephemeral?),
    do: "verifier_assignment_failed_closed"

  defp independent?(profile, actor_agent_ids) do
    candidate_ids =
      [
        profile["agent_id"],
        profile["agent_ref"],
        profile["handle"]
      ]
      |> RuntimeContracts.normalize_string_list()

    MapSet.disjoint?(MapSet.new(candidate_ids), MapSet.new(actor_agent_ids))
  end

  defp verifier_quality_for_profile(profile, verifier_quality) do
    [
      profile["agent_id"],
      profile["agent_ref"],
      profile["handle"]
    ]
    |> RuntimeContracts.normalize_string_list()
    |> Enum.find_value(%{}, &Map.get(verifier_quality, &1))
  end

  defp quality_score_adjustment(quality) when is_map(quality) and map_size(quality) > 0 do
    accuracy = RuntimeContracts.number(RuntimeContracts.value(quality, "accuracy"), 0.5)
    missed = RuntimeContracts.integer(RuntimeContracts.value(quality, "missed_failure_count"))
    false_blocks = RuntimeContracts.integer(RuntimeContracts.value(quality, "false_block_count"))
    matched = RuntimeContracts.integer(RuntimeContracts.value(quality, "matched_count"))

    base = round((accuracy - 0.5) * 20)
    positive = min(matched, 5)
    penalty = min(missed * 8 + false_blocks * 4, 30)

    base + positive - penalty
  end

  defp quality_score_adjustment(_quality), do: 0

  defp verifier_quality_map(value) when is_list(value) do
    value
    |> Enum.filter(&is_map/1)
    |> Enum.reduce(%{}, fn quality, acc ->
      quality = RuntimeContracts.string_keys(quality)

      [
        quality["verifier_agent_id"],
        quality["agent_id"],
        quality["agent_ref"],
        quality["handle"]
      ]
      |> RuntimeContracts.normalize_string_list()
      |> Enum.reduce(acc, fn key, inner -> Map.put(inner, key, quality) end)
    end)
  end

  defp verifier_quality_map(value) when is_map(value) do
    value = RuntimeContracts.string_keys(value)

    if Map.has_key?(value, "verifier_agent_id") do
      verifier_quality_map([value])
    else
      value
    end
  end

  defp verifier_quality_map(_value), do: %{}

  defp actor_agent_ids(attrs, work_graph) do
    explicit = RuntimeContracts.normalize_string_list(attrs["actor_agent_ids"])

    graph_actors =
      work_graph
      |> RuntimeContracts.value("nodes")
      |> List.wrap()
      |> Enum.filter(fn node ->
        RuntimeContracts.value(node, "kind") == "child_agent" and
          RuntimeContracts.value(node, "role") != "verifier"
      end)
      |> Enum.flat_map(fn node ->
        [
          RuntimeContracts.value(node, "target_agent_id"),
          RuntimeContracts.value(node, "agent_id"),
          RuntimeContracts.value(node, "child_ref"),
          RuntimeContracts.value(node, "parent_agent_id")
        ]
      end)

    run_actor =
      attrs
      |> RuntimeContracts.value("run")
      |> RuntimeContracts.normalize_map()
      |> RuntimeContracts.value("agent_id")

    (explicit ++ graph_actors ++ [run_actor, work_graph["agent_id"]])
    |> RuntimeContracts.normalize_string_list()
  end

  defp work_product_ref(work_graph, attrs) do
    [
      attrs["work_product_ref"],
      work_graph["graph_id"],
      work_graph["id"],
      attrs["artifact_ref"],
      attrs["tool_call_id"]
    ]
    |> RuntimeContracts.normalize_string_list()
    |> List.first()
  end

  defp verifier_allowed_tools(evidence_contract) do
    base =
      ~w(get_task list_task_specs get_task_spec read_task_memory_artifact load_teammate_runtime route_verification_review)

    contract_tools =
      RuntimeContracts.normalize_string_list(evidence_contract["allowed_verifier_tools"])

    (base ++ contract_tools)
    |> Enum.uniq()
  end
end
