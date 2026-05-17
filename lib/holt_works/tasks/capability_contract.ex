defmodule HoltWorks.Tasks.CapabilityContract do
  @moduledoc """
  Generic capability contract for routing local task-agent work.

  The contract describes required capabilities, tools, effect scope, artifacts,
  and risk without depending on task prose.
  """

  alias HoltWorks.Clock

  alias HoltWorks.Tasks.{
    ActionContract,
    CapabilityRegistry,
    RuntimeContracts
  }

  @schema_version "holtworks_capability_contract/v1"

  def build(attrs \\ %{})

  def build(attrs) when is_map(attrs) do
    attrs = RuntimeContracts.string_keys(attrs)

    role =
      normalize_role(
        RuntimeContracts.text(attrs, "role", RuntimeContracts.text(attrs, "work_role", "worker"))
      )

    tool_name = RuntimeContracts.text(attrs, "tool_name", RuntimeContracts.text(attrs, "name"))
    plan_contract = RuntimeContracts.normalize_map(RuntimeContracts.value(attrs, "plan_contract"))

    evidence_contract =
      RuntimeContracts.normalize_map(RuntimeContracts.value(attrs, "evidence_contract"))

    capability = capability_entry(tool_name, attrs)
    allowed_tools = allowed_tools(attrs, plan_contract)
    required_tools = required_tools(attrs, tool_name, allowed_tools)
    input_artifacts = input_artifacts(attrs)
    expected_outputs = expected_outputs(attrs, evidence_contract, role)
    effect_scope = effect_scope(attrs, plan_contract, capability, tool_name)
    risk_flags = risk_flags(attrs, evidence_contract, capability)

    required_capabilities =
      [
        RuntimeContracts.normalize_string_list(
          RuntimeContracts.value(attrs, "required_capabilities")
        ),
        role_capabilities(role),
        evidence_capabilities(role, evidence_contract),
        tool_capabilities(required_tools),
        artifact_capabilities(input_artifacts, expected_outputs),
        effect_scope_capabilities(effect_scope)
      ]
      |> List.flatten()
      |> RuntimeContracts.normalize_string_list()

    verification_capabilities =
      [
        RuntimeContracts.normalize_string_list(
          RuntimeContracts.value(attrs, "verification_capabilities")
        ),
        evidence_capabilities("verifier", evidence_contract)
      ]
      |> List.flatten()
      |> RuntimeContracts.normalize_string_list()

    %{
      "schema_version" => @schema_version,
      "contract_id" =>
        RuntimeContracts.stable_id("capability_contract", [
          role,
          required_capabilities,
          required_tools,
          input_artifacts,
          expected_outputs,
          effect_scope,
          risk_flags
        ]),
      "role" => role,
      "target_role" => role,
      "tool_name" => tool_name,
      "effect_scope" => effect_scope,
      "required_capabilities" => required_capabilities,
      "verification_capabilities" => verification_capabilities,
      "required_tools" => required_tools,
      "allowed_tools" => allowed_tools,
      "input_artifact_kinds" => input_artifacts,
      "expected_output_artifact_kinds" => expected_outputs,
      "risk_flags" => risk_flags,
      "capability_registry_entry" => capability,
      "evidence_contract" => evidence_contract,
      "created_at" => Clock.iso_now()
    }
    |> RuntimeContracts.reject_empty()
  end

  def build(_attrs), do: build(%{})

  defp capability_entry(nil, _attrs), do: %{}

  defp capability_entry(tool_name, attrs) do
    case RuntimeContracts.value(attrs, "capability_registry_entry") do
      entry when is_map(entry) -> RuntimeContracts.string_keys(entry)
      _missing -> CapabilityRegistry.lookup(tool_name, attrs)
    end
  end

  defp allowed_tools(attrs, plan_contract) do
    first_nonempty([
      RuntimeContracts.normalize_string_list(RuntimeContracts.value(attrs, "allowed_tools")),
      RuntimeContracts.normalize_string_list(
        RuntimeContracts.value(plan_contract, "allowed_tools")
      )
    ])
  end

  defp required_tools(attrs, tool_name, allowed_tools) do
    explicit =
      RuntimeContracts.normalize_string_list(RuntimeContracts.value(attrs, "required_tools"))

    cond do
      explicit != [] -> explicit
      tool_name not in [nil, ""] -> [tool_name]
      true -> allowed_tools
    end
  end

  defp input_artifacts(attrs) do
    first_nonempty([
      RuntimeContracts.normalize_string_list(
        RuntimeContracts.value(attrs, "input_artifact_kinds")
      ),
      RuntimeContracts.normalize_string_list(RuntimeContracts.value(attrs, "input_artifacts"))
    ])
  end

  defp expected_outputs(attrs, evidence_contract, "verifier") do
    first_nonempty([
      RuntimeContracts.normalize_string_list(
        RuntimeContracts.value(attrs, "expected_output_artifact_kinds")
      ),
      RuntimeContracts.normalize_string_list(
        RuntimeContracts.value(attrs, "expected_output_artifacts")
      ),
      RuntimeContracts.normalize_string_list(
        RuntimeContracts.value(evidence_contract, "required_artifact_kinds")
      ),
      ["verification_report"]
    ])
  end

  defp expected_outputs(attrs, _evidence_contract, role) do
    first_nonempty([
      RuntimeContracts.normalize_string_list(
        RuntimeContracts.value(attrs, "expected_output_artifact_kinds")
      ),
      RuntimeContracts.normalize_string_list(
        RuntimeContracts.value(attrs, "expected_output_artifacts")
      ),
      role_output_artifacts(role)
    ])
  end

  defp effect_scope(attrs, plan_contract, capability, tool_name) do
    explicit = RuntimeContracts.text(attrs, "effect_scope")

    cond do
      explicit not in [nil, ""] ->
        explicit

      RuntimeContracts.value(capability, "effect_scope") not in [nil, ""] ->
        RuntimeContracts.value(capability, "effect_scope")

      tool_name not in [nil, ""] ->
        ActionContract.effect_scope(tool_name)

      true ->
        plan_contract
        |> RuntimeContracts.value("allowed_effect_scopes")
        |> RuntimeContracts.normalize_string_list()
        |> List.first()
    end || "read_only"
  end

  defp risk_flags(attrs, evidence_contract, capability) do
    [
      RuntimeContracts.normalize_string_list(RuntimeContracts.value(attrs, "risk_flags")),
      RuntimeContracts.normalize_string_list(
        RuntimeContracts.value(evidence_contract, "risk_flags")
      ),
      RuntimeContracts.normalize_string_list(RuntimeContracts.value(capability, "risk_flags"))
    ]
    |> List.flatten()
    |> RuntimeContracts.normalize_string_list()
  end

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

  defp evidence_capabilities(_role, contract) when not is_map(contract) or contract == %{}, do: []

  defp evidence_capabilities(role, contract) do
    base =
      if role == "verifier" do
        ~w(evaluate_evidence_contract submit_structured_verdict)
      else
        []
      end

    groups =
      contract
      |> RuntimeContracts.value("required_check_groups")
      |> List.wrap()
      |> Enum.flat_map(fn group ->
        group
        |> RuntimeContracts.normalize_map()
        |> RuntimeContracts.value("any_of")
        |> RuntimeContracts.normalize_string_list()
      end)
      |> Enum.map(&"check_type:#{&1}")

    flags =
      []
      |> maybe_add_capability(
        RuntimeContracts.truthy?(RuntimeContracts.value(contract, "changed_files_required")),
        "inspect_changed_files"
      )
      |> maybe_add_capability(
        RuntimeContracts.truthy?(RuntimeContracts.value(contract, "command_evidence_required")),
        "review_command_evidence"
      )
      |> maybe_add_capability(
        RuntimeContracts.truthy?(RuntimeContracts.value(contract, "ui_walkthrough_required")),
        "verify_ui_surface"
      )
      |> maybe_add_capability(
        RuntimeContracts.truthy?(RuntimeContracts.value(contract, "api_verification_required")),
        "verify_api_surface"
      )

    base ++ groups ++ flags
  end

  defp maybe_add_capability(list, false, _capability), do: list
  defp maybe_add_capability(list, true, capability), do: [capability | list]

  defp tool_capabilities(tools), do: Enum.map(tools, &"tool:#{&1}")

  defp artifact_capabilities(input_artifacts, expected_outputs) do
    Enum.map(input_artifacts, &"read_artifact:#{&1}") ++
      Enum.map(expected_outputs, &"produce_artifact:#{&1}")
  end

  defp effect_scope_capabilities(nil), do: []
  defp effect_scope_capabilities("unknown"), do: []
  defp effect_scope_capabilities(scope), do: ["effect_scope:#{scope}"]

  defp role_output_artifacts("researcher"), do: ["research"]
  defp role_output_artifacts("critic"), do: ["critique"]
  defp role_output_artifacts("planner"), do: ["handoff"]
  defp role_output_artifacts(_role), do: ["handoff"]

  defp normalize_role(role) when role in ~w(worker verifier researcher critic planner operator),
    do: role

  defp normalize_role(_role), do: "worker"

  defp first_nonempty(lists) do
    Enum.find(lists, [], fn list -> is_list(list) and list != [] end)
  end
end
