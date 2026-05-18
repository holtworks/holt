defmodule Holt.Tasks.CapabilityIndex do
  @moduledoc """
  Normalizes local agent profiles into capability-index records.
  """

  alias Holt.Tasks.ActionSession

  @schema_version "holt_agent_capability_profile/v1"
  @effect_scopes ~w(read_only task_durable agent_orchestration workspace_durable external_side_effect routed)
  @artifact_kinds ~w(handoff verification_report research critique decision workflow_contract node_heartbeat)

  def profiles(value \\ nil)

  def profiles(nil), do: []

  def profiles(value) when is_list(value) do
    value
    |> Enum.flat_map(&profiles/1)
    |> dedupe_profiles()
  end

  def profiles(value) when is_binary(value), do: []

  def profiles(value) when is_map(value) do
    if canonical_value?(value) do
      value
      |> profile_from_map()
      |> profile_list()
    else
      []
    end
  end

  def profiles(_value), do: []

  def capability_available?(profile, capability) do
    capability in string_list(value(profile, "capabilities"))
  end

  def action_available?(profile, action_name) do
    action_name in string_list(value(profile, "actions"))
  end

  defp profile_from_map(attrs) do
    agent_id = text(attrs, "agent_id")
    work_role = normalize_role(text(attrs, "work_role", "worker"))
    actions = actions(attrs)
    effect_scopes = effect_scopes(attrs)
    artifact_kinds = artifact_kinds(attrs)

    capabilities =
      [
        string_list(value(attrs, "capabilities")),
        role_capabilities(work_role),
        Enum.map(actions, &"action:#{&1}"),
        Enum.map(effect_scopes, &"effect_scope:#{&1}"),
        Enum.map(artifact_kinds, &"read_artifact:#{&1}"),
        Enum.map(artifact_kinds, &"produce_artifact:#{&1}")
      ]
      |> List.flatten()
      |> string_list()

    %{
      "schema_version" => @schema_version,
      "agent_id" => agent_id,
      "agent_ref" => text(attrs, "agent_ref"),
      "handle" => text(attrs, "agent_handle"),
      "name" => text(attrs, "display_name"),
      "status" => text(attrs, "status", "active"),
      "work_role" => work_role,
      "capabilities" => capabilities,
      "actions" => actions,
      "effect_scopes" => effect_scopes,
      "artifact_kinds" => artifact_kinds
    }
    |> reject_empty()
  end

  defp profile_list(%{"agent_id" => agent_id} = profile) when agent_id not in [nil, ""],
    do: [profile]

  defp profile_list(_profile), do: []

  defp actions(attrs) do
    explicit = string_list(value(attrs, "actions"))

    if explicit == [] do
      ActionSession.direct_action_names() ++ ActionSession.meta_action_names()
    else
      explicit
    end
    |> Enum.uniq()
  end

  defp effect_scopes(attrs) do
    explicit = string_list(value(attrs, "effect_scopes"))

    if explicit == [], do: @effect_scopes, else: explicit
  end

  defp artifact_kinds(attrs) do
    explicit = string_list(value(attrs, "artifact_kinds"))

    if explicit == [], do: @artifact_kinds, else: explicit
  end

  defp normalize_role(role) when role in ~w(worker verifier researcher critic planner operator),
    do: role

  defp normalize_role(_role), do: "worker"

  defp role_capabilities("verifier"),
    do: ~w(inspect_task inspect_artifacts evaluate_evidence_contract submit_structured_verdict)

  defp role_capabilities("researcher"), do: ~w(gather_context inspect_artifacts produce_research)

  defp role_capabilities("critic"),
    do: ~w(inspect_artifacts identify_failure_modes produce_critique)

  defp role_capabilities("planner"),
    do: ~w(model_plan_steps predict_consequences define_handoff)

  defp role_capabilities("operator"),
    do: ~w(execute_task_objective observe_effects produce_handoff)

  defp role_capabilities(_role), do: ~w(execute_task_objective produce_handoff)

  defp dedupe_profiles(profiles) do
    profiles
    |> Enum.reduce({MapSet.new(), []}, fn profile, {seen, acc} ->
      agent_id = profile["agent_id"]

      cond do
        agent_id in [nil, ""] -> {seen, acc}
        MapSet.member?(seen, agent_id) -> {seen, acc}
        true -> {MapSet.put(seen, agent_id), acc ++ [profile]}
      end
    end)
    |> elem(1)
  end

  defp value(map, key) when is_map(map), do: Map.get(map, key)
  defp value(_map, _key), do: nil

  defp text(map, key, default \\ nil)

  defp text(map, key, default) when is_map(map) do
    case Map.get(map, key) do
      value when is_binary(value) ->
        value
        |> String.trim()
        |> case do
          "" -> default
          text -> text
        end

      _value ->
        default
    end
  end

  defp text(_map, _key, default), do: default

  defp string_list(nil), do: []

  defp string_list(value) when is_list(value) do
    value
    |> Enum.flat_map(&string_list/1)
    |> Enum.uniq()
  end

  defp string_list(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: [], else: [value]
  end

  defp string_list(_value), do: []

  defp canonical_value?(value) when is_map(value) do
    Enum.all?(value, fn
      {key, nested} when is_binary(key) -> canonical_value?(nested)
      {_key, _nested} -> false
    end)
  end

  defp canonical_value?(value) when is_list(value), do: Enum.all?(value, &canonical_value?/1)
  defp canonical_value?(_value), do: true

  defp reject_empty(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end
end
