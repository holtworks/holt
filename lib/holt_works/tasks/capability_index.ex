defmodule HoltWorks.Tasks.CapabilityIndex do
  @moduledoc """
  Normalizes local agent profiles into capability-index records.
  """

  alias HoltWorks.Tasks.{RuntimeContracts, TaskToolSession}

  @schema_version "holtworks_agent_capability_profile/v1"
  @effect_scopes ~w(read_only task_durable agent_orchestration workspace_durable external_side_effect routed)
  @artifact_kinds ~w(handoff verification_report research critique decision workflow_contract node_heartbeat)

  def profiles(value \\ nil)

  def profiles(nil), do: []

  def profiles(value) when is_list(value) do
    value
    |> Enum.flat_map(&profiles/1)
    |> dedupe_profiles()
  end

  def profiles(value) when is_binary(value) do
    value
    |> RuntimeContracts.normalize_string_list()
    |> Enum.map(&profile_from_id/1)
  end

  def profiles(value) when is_map(value) do
    [profile_from_map(RuntimeContracts.string_keys(value))]
  end

  def profiles(_value), do: []

  def capability_available?(profile, capability) do
    capability in RuntimeContracts.normalize_string_list(
      RuntimeContracts.value(profile, "capabilities")
    )
  end

  def tool_available?(profile, tool_name) do
    tool_name in RuntimeContracts.normalize_string_list(RuntimeContracts.value(profile, "tools"))
  end

  defp profile_from_id(id) do
    profile_from_map(%{"agent_id" => id, "name" => id, "work_role" => "worker"})
  end

  defp profile_from_map(attrs) do
    agent_id =
      RuntimeContracts.text(attrs, "agent_id") ||
        RuntimeContracts.text(attrs, "id") ||
        RuntimeContracts.text(attrs, "agent_ref")

    work_role = normalize_role(RuntimeContracts.text(attrs, "work_role", "worker"))
    tools = tools(attrs)
    effect_scopes = effect_scopes(attrs)
    artifact_kinds = artifact_kinds(attrs)

    capabilities =
      [
        RuntimeContracts.normalize_string_list(RuntimeContracts.value(attrs, "capabilities")),
        role_capabilities(work_role),
        Enum.map(tools, &"tool:#{&1}"),
        Enum.map(effect_scopes, &"effect_scope:#{&1}"),
        Enum.map(artifact_kinds, &"read_artifact:#{&1}"),
        Enum.map(artifact_kinds, &"produce_artifact:#{&1}")
      ]
      |> List.flatten()
      |> RuntimeContracts.normalize_string_list()

    %{
      "schema_version" => @schema_version,
      "agent_id" => agent_id,
      "agent_ref" =>
        RuntimeContracts.text(attrs, "agent_ref") || RuntimeContracts.text(attrs, "ref"),
      "handle" =>
        RuntimeContracts.text(attrs, "agent_handle") || RuntimeContracts.text(attrs, "handle"),
      "name" =>
        RuntimeContracts.text(attrs, "display_name") ||
          RuntimeContracts.text(attrs, "agent_name") ||
          RuntimeContracts.text(attrs, "name") ||
          agent_id,
      "status" => RuntimeContracts.text(attrs, "status", "active"),
      "work_role" => work_role,
      "capabilities" => capabilities,
      "tools" => tools,
      "effect_scopes" => effect_scopes,
      "artifact_kinds" => artifact_kinds
    }
    |> RuntimeContracts.reject_empty()
  end

  defp tools(attrs) do
    explicit =
      RuntimeContracts.normalize_string_list(
        RuntimeContracts.value(attrs, "tools") ||
          RuntimeContracts.value(attrs, "allowed_tools") ||
          RuntimeContracts.value(attrs, "direct_tools")
      )

    if explicit == [] do
      TaskToolSession.direct_tool_names() ++ TaskToolSession.meta_tool_names()
    else
      explicit
    end
    |> Enum.uniq()
  end

  defp effect_scopes(attrs) do
    explicit =
      RuntimeContracts.normalize_string_list(RuntimeContracts.value(attrs, "effect_scopes"))

    if explicit == [], do: @effect_scopes, else: explicit
  end

  defp artifact_kinds(attrs) do
    explicit =
      RuntimeContracts.normalize_string_list(RuntimeContracts.value(attrs, "artifact_kinds"))

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

      if agent_id in [nil, ""] or MapSet.member?(seen, agent_id) do
        {seen, acc}
      else
        {MapSet.put(seen, agent_id), acc ++ [profile]}
      end
    end)
    |> elem(1)
  end
end
