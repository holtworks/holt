defmodule Holt.Tasks.CapabilityRouter do
  @moduledoc """
  Routes a capability contract to an eligible local agent profile.
  """

  alias Holt.Clock
  alias Holt.Tasks.{CapabilityContract, CapabilityIndex}

  @schema_version "holt_capability_route/v1"
  @contract_list_fields ~w(
    required_capabilities
    required_actions
    expected_output_artifact_kinds
  )
  @agent_list_fields ~w(capabilities actions effect_scopes artifact_kinds)

  def route(attrs \\ %{})

  def route(attrs) when is_map(attrs) do
    with :ok <- canonical_attrs(attrs),
         {:ok, available_agents} <- available_agents_field(attrs),
         {:ok, contract} <- capability_contract(attrs),
         :ok <- validate_contract(contract) do
      route_contract(available_agents, contract)
    else
      {:error, reason} -> rejected(reason)
    end
  end

  def route(_attrs), do: rejected("invalid_attrs")

  defp route_contract(available_agents, contract) do
    profiles =
      available_agents
      |> CapabilityIndex.profiles()
      |> Enum.filter(&(Map.get(&1, "status") == "active"))

    scored =
      profiles
      |> Enum.map(&score_profile(&1, contract))
      |> Enum.sort_by(
        fn score ->
          {eligible_rank(score), Map.get(score, "score", 0)}
        end,
        :desc
      )

    selected = Enum.find(scored, &(&1["eligible"] == true))

    if selected do
      selected_route(contract, selected, scored)
    else
      ephemeral_route(contract, scored)
    end
  end

  defp eligible_rank(score) do
    if Map.get(score, "eligible") == true, do: 1, else: 0
  end

  defp score_profile(profile, contract) do
    required_capabilities = string_list_field(contract, "required_capabilities")
    required_actions = string_list_field(contract, "required_actions")
    effect_scope = contract["effect_scope"]
    expected_artifacts = string_list_field(contract, "expected_output_artifact_kinds")

    missing_capabilities =
      Enum.reject(required_capabilities, &CapabilityIndex.capability_available?(profile, &1))

    missing_actions =
      Enum.reject(required_actions, &CapabilityIndex.action_available?(profile, &1))

    effect_scope_match? = effect_scope_match?(effect_scope, profile)

    artifact_matches =
      expected_artifacts
      |> Enum.count(&(&1 in string_list_field(profile, "artifact_kinds")))

    score =
      (length(required_capabilities) - length(missing_capabilities)) * 10 +
        (length(required_actions) - length(missing_actions)) * 6 +
        artifact_matches * 3 +
        if(effect_scope_match?, do: 4, else: 0)

    %{
      "agent" => profile,
      "score" => score,
      "eligible" => missing_capabilities == [] and missing_actions == [] and effect_scope_match?,
      "missing_capabilities" => missing_capabilities,
      "missing_actions" => missing_actions,
      "effect_scope_match" => effect_scope_match?
    }
    |> reject_empty()
  end

  defp selected_route(contract, scored, all_scores) do
    profile = map_field(scored, "agent")

    %{
      "schema_version" => @schema_version,
      "route_id" => route_id(contract, profile),
      "status" => "routed",
      "execution_mode" => "persisted_agent",
      "target_role" => Map.get(contract, "target_role"),
      "target_agent_id" => profile["agent_id"],
      "target_agent_ref" => profile["agent_ref"],
      "target_agent_handle" => profile["handle"],
      "target_agent_name" => profile["name"],
      "score" => scored["score"],
      "capability_contract" => contract,
      "required_capabilities" => Map.get(contract, "required_capabilities", []),
      "required_actions" => Map.get(contract, "required_actions", []),
      "candidate_count" => length(all_scores),
      "candidate_scores" => Enum.map(all_scores, &candidate_score_summary/1),
      "created_at" => Clock.iso_now()
    }
    |> reject_empty()
  end

  defp ephemeral_route(contract, scored) do
    best = best_score(scored)

    %{
      "schema_version" => @schema_version,
      "route_id" => route_id(contract, %{"agent_id" => "ephemeral"}),
      "status" => "ephemeral",
      "execution_mode" => "ephemeral_sub_agent",
      "target_role" => Map.get(contract, "target_role"),
      "score" => Map.get(best, "score", 0),
      "capability_contract" => contract,
      "required_capabilities" => Map.get(contract, "required_capabilities", []),
      "required_actions" => Map.get(contract, "required_actions", []),
      "missing_capabilities" => Map.get(best, "missing_capabilities", []),
      "missing_actions" => Map.get(best, "missing_actions", []),
      "candidate_count" => length(scored),
      "candidate_scores" => Enum.map(scored, &candidate_score_summary/1),
      "created_at" => Clock.iso_now()
    }
    |> reject_empty()
  end

  defp best_score([score | _rest]), do: score
  defp best_score([]), do: %{}

  defp effect_scope_match?(effect_scope, _profile) when effect_scope in [nil, "", "unknown"],
    do: true

  defp effect_scope_match?(effect_scope, profile) do
    effect_scope in string_list_field(profile, "effect_scopes")
  end

  defp candidate_score_summary(score) do
    agent = map_field(score, "agent")

    %{
      "agent_id" => agent["agent_id"],
      "agent_ref" => agent["agent_ref"],
      "handle" => agent["handle"],
      "name" => agent["name"],
      "work_role" => agent["work_role"],
      "score" => score["score"],
      "eligible" => score["eligible"],
      "missing_capabilities" => Map.get(score, "missing_capabilities", []),
      "missing_actions" => Map.get(score, "missing_actions", []),
      "effect_scope_match" => score["effect_scope_match"]
    }
    |> reject_empty()
  end

  defp route_id(contract, profile) do
    stable_id("capability_route", [
      contract["contract_id"],
      profile["agent_id"]
    ])
  end

  defp capability_contract(attrs) do
    case Map.fetch(attrs, "capability_contract") do
      {:ok, contract} when is_map(contract) ->
        case canonical_nested_map("capability_contract", contract) do
          {:ok, value} when value != %{} -> {:ok, value}
          {:ok, _empty} -> {:error, "invalid_capability_contract"}
          {:error, _reason} -> {:error, "invalid_capability_contract"}
        end

      {:ok, _value} ->
        {:error, "invalid_capability_contract"}

      :error ->
        case CapabilityContract.build(attrs) do
          %{"status" => "rejected"} -> {:error, "invalid_capability_contract"}
          contract -> {:ok, contract}
        end
    end
  end

  defp validate_contract(%{"status" => "rejected"}), do: {:error, "invalid_capability_contract"}

  defp validate_contract(contract) do
    case Enum.find(@contract_list_fields, &invalid_string_list_field?(contract, &1)) do
      "required_capabilities" -> {:error, "invalid_required_capabilities"}
      "required_actions" -> {:error, "invalid_required_actions"}
      "expected_output_artifact_kinds" -> {:error, "invalid_expected_output_artifact_kinds"}
      nil -> :ok
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
    Enum.reduce_while(values, {:ok, []}, fn
      profile, {:ok, acc} when is_map(profile) ->
        with {:ok, profile} <- canonical_nested_map("available_agents", profile),
             :ok <- validate_agent_profile(profile) do
          {:cont, {:ok, [profile | acc]}}
        else
          {:error, _reason} -> {:halt, {:error, "invalid_available_agents"}}
        end

      _profile, {:ok, _acc} ->
        {:halt, {:error, "invalid_available_agents"}}
    end)
    |> case do
      {:ok, profiles} -> {:ok, Enum.reverse(profiles)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_agent_profile(profile) do
    with :ok <-
           validate_string_fields(profile, ~w(agent_id agent_ref handle name work_role status)),
         :ok <- validate_string_list_fields(profile, @agent_list_fields) do
      :ok
    end
  end

  defp string_list_field(map, key) do
    case Map.get(map, key) do
      values when is_list(values) -> values
      _value -> []
    end
  end

  defp map_field(map, key) do
    case Map.get(map, key) do
      contract when is_map(contract) and map_size(contract) > 0 ->
        case canonical_nested_map(key, contract) do
          {:ok, value} -> value
          {:error, _reason} -> %{}
        end

      _value ->
        %{}
    end
  end

  defp invalid_string_list_field?(map, key) do
    Map.has_key?(map, key) and not valid_string_list?(Map.get(map, key))
  end

  defp validate_string_list_fields(map, keys) do
    case Enum.find(keys, &(not valid_optional_string_list?(map, &1))) do
      nil -> :ok
      _key -> {:error, "invalid_available_agents"}
    end
  end

  defp valid_optional_string_list?(map, key) do
    case Map.fetch(map, key) do
      {:ok, values} -> valid_string_list?(values)
      :error -> true
    end
  end

  defp valid_string_list?(values) when is_list(values) do
    Enum.all?(values, &(is_binary(&1) and String.trim(&1) != ""))
  end

  defp valid_string_list?(_values), do: false

  defp validate_string_fields(map, keys) do
    case Enum.find(keys, &(not valid_optional_string?(map, &1))) do
      nil -> :ok
      _key -> {:error, "invalid_available_agents"}
    end
  end

  defp valid_optional_string?(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) -> String.trim(value) != ""
      {:ok, _value} -> false
      :error -> true
    end
  end

  defp canonical_attrs(attrs) do
    if Enum.all?(attrs, fn {key, _value} -> is_binary(key) end) do
      :ok
    else
      {:error, "invalid_attrs"}
    end
  end

  defp canonical_nested_map(key, map) do
    if canonical_value?(map) do
      {:ok, map}
    else
      {:error, "invalid_field:#{key}"}
    end
  end

  defp canonical_value?(value) when is_map(value) do
    Enum.all?(value, fn
      {key, nested} when is_binary(key) -> canonical_value?(nested)
      _entry -> false
    end)
  end

  defp canonical_value?(value) when is_list(value), do: Enum.all?(value, &canonical_value?/1)
  defp canonical_value?(_value), do: true

  defp reject_empty(map) do
    map
    |> Enum.reject(fn {_key, value} -> empty?(value) end)
    |> Map.new()
  end

  defp stable_id(prefix, parts) do
    digest =
      :crypto.hash(:sha256, :erlang.term_to_binary(parts))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 24)

    "#{prefix}_#{digest}"
  end

  defp empty?(nil), do: true
  defp empty?(""), do: true
  defp empty?([]), do: true
  defp empty?(map) when is_map(map), do: map_size(map) == 0
  defp empty?(_value), do: false

  defp rejected(reason) do
    %{
      "schema_version" => @schema_version,
      "status" => "rejected",
      "reason" => reason,
      "created_at" => Clock.iso_now()
    }
  end
end
