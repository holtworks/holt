defmodule Holt.Tasks.CapabilityRouter do
  @moduledoc """
  Routes a capability contract to an eligible local agent profile.
  """

  alias Holt.Clock
  alias Holt.Tasks.{CapabilityContract, CapabilityIndex, RuntimeContracts}

  @schema_version "holtworks_capability_route/v1"

  def route(attrs \\ %{})

  def route(attrs) when is_map(attrs) do
    attrs = RuntimeContracts.string_keys(attrs)

    contract =
      case RuntimeContracts.value(attrs, "capability_contract") do
        contract when is_map(contract) and map_size(contract) > 0 ->
          RuntimeContracts.string_keys(contract)

        _missing ->
          CapabilityContract.build(attrs)
      end

    profiles =
      attrs
      |> RuntimeContracts.value("available_agents")
      |> CapabilityIndex.profiles()
      |> Enum.filter(&(RuntimeContracts.value(&1, "status") == "active"))

    scored =
      profiles
      |> Enum.map(&score_profile(&1, contract))
      |> Enum.sort_by(
        fn score ->
          {if(RuntimeContracts.truthy?(score["eligible"]), do: 1, else: 0), score["score"] || 0}
        end,
        :desc
      )

    selected = Enum.find(scored, &RuntimeContracts.truthy?(&1["eligible"]))

    if selected do
      selected_route(contract, selected, scored)
    else
      ephemeral_route(contract, scored)
    end
  end

  def route(_attrs), do: route(%{})

  defp score_profile(profile, contract) do
    required_capabilities =
      RuntimeContracts.normalize_string_list(contract["required_capabilities"])

    required_tools = RuntimeContracts.normalize_string_list(contract["required_tools"])
    effect_scope = contract["effect_scope"]

    expected_artifacts =
      RuntimeContracts.normalize_string_list(contract["expected_output_artifact_kinds"])

    missing_capabilities =
      Enum.reject(required_capabilities, &CapabilityIndex.capability_available?(profile, &1))

    missing_tools = Enum.reject(required_tools, &CapabilityIndex.tool_available?(profile, &1))

    effect_scope_match? =
      effect_scope in [nil, "", "unknown"] or
        effect_scope in RuntimeContracts.normalize_string_list(profile["effect_scopes"])

    artifact_matches =
      expected_artifacts
      |> Enum.count(&(&1 in RuntimeContracts.normalize_string_list(profile["artifact_kinds"])))

    score =
      (length(required_capabilities) - length(missing_capabilities)) * 10 +
        (length(required_tools) - length(missing_tools)) * 6 +
        artifact_matches * 3 +
        if(effect_scope_match?, do: 4, else: 0)

    %{
      "agent" => profile,
      "score" => score,
      "eligible" => missing_capabilities == [] and missing_tools == [] and effect_scope_match?,
      "missing_capabilities" => missing_capabilities,
      "missing_tools" => missing_tools,
      "effect_scope_match" => effect_scope_match?
    }
    |> RuntimeContracts.reject_empty()
  end

  defp selected_route(contract, scored, all_scores) do
    profile = scored["agent"] || %{}

    %{
      "schema_version" => @schema_version,
      "route_id" => route_id(contract, profile),
      "status" => "routed",
      "execution_mode" => "persisted_agent",
      "target_role" => contract["target_role"] || contract["role"],
      "target_agent_id" => profile["agent_id"],
      "target_agent_ref" => profile["agent_ref"],
      "target_agent_handle" => profile["handle"],
      "target_agent_name" => profile["name"],
      "score" => scored["score"],
      "capability_contract" => contract,
      "required_capabilities" => contract["required_capabilities"] || [],
      "required_tools" => contract["required_tools"] || [],
      "candidate_count" => length(all_scores),
      "candidate_scores" => Enum.map(all_scores, &candidate_score_summary/1),
      "created_at" => Clock.iso_now()
    }
    |> RuntimeContracts.reject_empty()
  end

  defp ephemeral_route(contract, scored) do
    best = List.first(scored) || %{}

    %{
      "schema_version" => @schema_version,
      "route_id" => route_id(contract, %{"agent_id" => "ephemeral"}),
      "status" => "ephemeral",
      "execution_mode" => "ephemeral_sub_agent",
      "target_role" => contract["target_role"] || contract["role"],
      "score" => best["score"] || 0,
      "capability_contract" => contract,
      "required_capabilities" => contract["required_capabilities"] || [],
      "required_tools" => contract["required_tools"] || [],
      "missing_capabilities" => best["missing_capabilities"] || [],
      "missing_tools" => best["missing_tools"] || [],
      "candidate_count" => length(scored),
      "candidate_scores" => Enum.map(scored, &candidate_score_summary/1),
      "created_at" => Clock.iso_now()
    }
    |> RuntimeContracts.reject_empty()
  end

  defp candidate_score_summary(score) do
    agent = score["agent"] || %{}

    %{
      "agent_id" => agent["agent_id"],
      "agent_ref" => agent["agent_ref"],
      "handle" => agent["handle"],
      "name" => agent["name"],
      "work_role" => agent["work_role"],
      "score" => score["score"],
      "eligible" => score["eligible"],
      "missing_capabilities" => score["missing_capabilities"] || [],
      "missing_tools" => score["missing_tools"] || [],
      "effect_scope_match" => score["effect_scope_match"]
    }
    |> RuntimeContracts.reject_empty()
  end

  defp route_id(contract, profile) do
    RuntimeContracts.stable_id("capability_route", [
      contract["contract_id"],
      profile["agent_id"]
    ])
  end
end
