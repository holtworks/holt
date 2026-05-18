defmodule Holt.Tasks.CapabilityContract do
  @moduledoc """
  Generic capability contract for routing local task-agent work.

  The contract describes required capabilities, actions, effect scope, artifacts,
  and risk without depending on task prose.
  """

  alias Holt.Clock

  alias Holt.Tasks.{
    ActionContract,
    CapabilityRegistry
  }

  @schema_version "holt_capability_contract/v1"
  @roles ~w(worker verifier researcher critic planner operator)
  @effect_scopes ~w(
    read_only
    session_ephemeral
    task_durable
    agent_orchestration
    workspace_durable
    external_side_effect
    routed
    unknown
  )
  @attr_list_fields ~w(
    allowed_actions
    required_actions
    input_artifact_kinds
    expected_output_artifact_kinds
    risk_flags
    required_capabilities
    verification_capabilities
  )
  @evidence_list_fields ~w(risk_flags required_artifact_kinds)
  @evidence_boolean_fields ~w(
    changed_files_required
    command_evidence_required
    ui_walkthrough_required
    api_verification_required
  )

  def build(attrs \\ %{})

  def build(attrs) when is_map(attrs) do
    with :ok <- canonical_attrs(attrs),
         :ok <- validate_string_list_fields(attrs, @attr_list_fields),
         {:ok, role} <- role(attrs),
         {:ok, action_name} <- optional_text(attrs, "action"),
         {:ok, plan_contract} <- map_field(attrs, "plan_contract"),
         :ok <- validate_plan_contract(plan_contract),
         {:ok, evidence_contract} <- map_field(attrs, "evidence_contract"),
         :ok <- validate_evidence_contract(evidence_contract),
         {:ok, capability} <- capability_entry(attrs, action_name),
         :ok <- validate_capability_entry(capability),
         allowed_actions = allowed_actions(attrs, plan_contract),
         required_actions = required_actions(attrs, action_name, allowed_actions),
         input_artifacts = input_artifacts(attrs),
         expected_outputs = expected_outputs(attrs, evidence_contract, role),
         {:ok, effect_scope} <- effect_scope(attrs, plan_contract, capability, action_name),
         risk_flags = risk_flags(attrs, evidence_contract, capability) do
      required_capabilities =
        [
          string_list_field(attrs, "required_capabilities"),
          role_capabilities(role),
          evidence_capabilities(role, evidence_contract),
          action_capabilities(required_actions),
          artifact_capabilities(input_artifacts, expected_outputs),
          effect_scope_capabilities(effect_scope)
        ]
        |> List.flatten()
        |> string_list_unique()

      verification_capabilities =
        [
          string_list_field(attrs, "verification_capabilities"),
          evidence_capabilities("verifier", evidence_contract)
        ]
        |> List.flatten()
        |> string_list_unique()

      %{
        "schema_version" => @schema_version,
        "contract_id" =>
          stable_id("capability_contract", [
            role,
            required_capabilities,
            required_actions,
            input_artifacts,
            expected_outputs,
            effect_scope,
            risk_flags
          ]),
        "role" => role,
        "target_role" => role,
        "action" => action_name,
        "effect_scope" => effect_scope,
        "required_capabilities" => required_capabilities,
        "verification_capabilities" => verification_capabilities,
        "required_actions" => required_actions,
        "allowed_actions" => allowed_actions,
        "input_artifact_kinds" => input_artifacts,
        "expected_output_artifact_kinds" => expected_outputs,
        "risk_flags" => risk_flags,
        "capability_registry_entry" => capability,
        "evidence_contract" => evidence_contract,
        "created_at" => Clock.iso_now()
      }
      |> reject_empty()
    else
      {:error, reason} -> rejected_contract(reason)
    end
  end

  def build(_attrs), do: rejected_contract("invalid_attrs")

  defp rejected_contract(reason) do
    %{
      "schema_version" => @schema_version,
      "status" => "rejected",
      "reason" => reason
    }
  end

  defp capability_entry(_attrs, nil), do: {:ok, %{}}

  defp capability_entry(attrs, action_name) do
    case Map.fetch(attrs, "capability_registry_entry") do
      {:ok, entry} when is_map(entry) ->
        canonical_nested_map("capability_registry_entry", entry)

      {:ok, _value} ->
        {:error, "invalid_field:capability_registry_entry"}

      :error ->
        case CapabilityRegistry.lookup(action_name, attrs) do
          %{"status" => "rejected", "reason" => reason} -> {:error, reason}
          entry -> {:ok, entry}
        end
    end
  end

  defp allowed_actions(attrs, plan_contract) do
    case string_list_field(attrs, "allowed_actions") do
      [] -> string_list_field(plan_contract, "allowed_actions")
      actions -> actions
    end
  end

  defp required_actions(attrs, action_name, allowed_actions) do
    explicit = string_list_field(attrs, "required_actions")

    cond do
      explicit != [] -> explicit
      action_name not in [nil, ""] -> [action_name]
      true -> allowed_actions
    end
  end

  defp input_artifacts(attrs) do
    string_list_field(attrs, "input_artifact_kinds")
  end

  defp expected_outputs(attrs, evidence_contract, "verifier") do
    case string_list_field(attrs, "expected_output_artifact_kinds") do
      [] ->
        case string_list_field(evidence_contract, "required_artifact_kinds") do
          [] -> ["verification_report"]
          artifacts -> artifacts
        end

      artifacts ->
        artifacts
    end
  end

  defp expected_outputs(attrs, _evidence_contract, role) do
    case string_list_field(attrs, "expected_output_artifact_kinds") do
      [] -> role_output_artifacts(role)
      artifacts -> artifacts
    end
  end

  defp effect_scope(attrs, plan_contract, capability, action_name) do
    with {:ok, explicit} <- optional_text(attrs, "effect_scope") do
      cond do
        explicit not in [nil, ""] ->
          explicit

        Map.get(capability, "effect_scope") not in [nil, ""] ->
          Map.get(capability, "effect_scope")

        action_name not in [nil, ""] ->
          ActionContract.effect_scope(action_name)

        true ->
          plan_contract
          |> string_list_field("allowed_effect_scopes")
          |> List.first()
      end
      |> default_effect_scope()
      |> effect_scope_value()
    end
  end

  defp default_effect_scope(nil), do: "read_only"
  defp default_effect_scope(""), do: "read_only"
  defp default_effect_scope(effect_scope), do: effect_scope

  defp effect_scope_value(effect_scope) when effect_scope in @effect_scopes,
    do: {:ok, effect_scope}

  defp effect_scope_value(_effect_scope), do: {:error, "invalid_field:effect_scope"}

  defp risk_flags(attrs, evidence_contract, capability) do
    [
      string_list_field(attrs, "risk_flags"),
      string_list_field(evidence_contract, "risk_flags"),
      string_list_field(capability, "risk_flags")
    ]
    |> List.flatten()
    |> string_list_unique()
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

  defp evidence_capabilities(role, contract) do
    if empty_contract?(contract) do
      []
    else
      base =
        if role == "verifier" do
          ~w(evaluate_evidence_contract submit_structured_verdict)
        else
          []
        end

      groups =
        contract
        |> Map.get("required_check_groups")
        |> list_value()
        |> Enum.flat_map(fn group ->
          group
          |> map_value()
          |> string_list_field("any_of")
        end)
        |> Enum.map(&"check_type:#{&1}")

      flags =
        []
        |> maybe_add_capability(
          Map.get(contract, "changed_files_required") == true,
          "inspect_changed_files"
        )
        |> maybe_add_capability(
          Map.get(contract, "command_evidence_required") == true,
          "review_command_evidence"
        )
        |> maybe_add_capability(
          Map.get(contract, "ui_walkthrough_required") == true,
          "verify_ui_surface"
        )
        |> maybe_add_capability(
          Map.get(contract, "api_verification_required") == true,
          "verify_api_surface"
        )

      base ++ groups ++ flags
    end
  end

  defp empty_contract?(contract) do
    cond do
      not is_map(contract) -> true
      contract == %{} -> true
      true -> false
    end
  end

  defp maybe_add_capability(list, false, _capability), do: list
  defp maybe_add_capability(list, true, capability), do: [capability | list]

  defp action_capabilities(actions), do: Enum.map(actions, &"action:#{&1}")

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

  defp role(attrs) do
    case optional_text(attrs, "role", "worker") do
      {:ok, role} when role in @roles -> {:ok, role}
      {:ok, _role} -> {:error, "invalid_field:role"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp map_field(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_map(value) -> canonical_nested_map(key, value)
      {:ok, _value} -> {:error, "invalid_field:#{key}"}
      :error -> {:ok, %{}}
    end
  end

  defp map_value(value) when is_map(value), do: value
  defp map_value(_value), do: %{}

  defp string_list_field(map, key) do
    case Map.get(map, key) do
      value when is_list(value) -> string_list_unique(value)
      _value -> []
    end
  end

  defp list_value(value) when is_list(value), do: value
  defp list_value(_value), do: []

  defp optional_text(map, key, default \\ nil) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, "invalid_field:#{key}"}
          text -> {:ok, text}
        end

      {:ok, _value} ->
        {:error, "invalid_field:#{key}"}

      :error ->
        {:ok, default}
    end
  end

  defp validate_plan_contract(plan_contract) do
    validate_string_list_fields(plan_contract, ~w(allowed_actions allowed_effect_scopes))
  end

  defp validate_evidence_contract(evidence_contract) do
    with :ok <- validate_string_list_fields(evidence_contract, @evidence_list_fields),
         :ok <- validate_boolean_fields(evidence_contract, @evidence_boolean_fields) do
      validate_required_check_groups(evidence_contract)
    end
  end

  defp validate_capability_entry(capability) do
    with :ok <- validate_text_fields(capability, ~w(effect_scope target_domain risk_level)),
         :ok <- validate_string_list_fields(capability, ~w(risk_flags)),
         :ok <- validate_optional_map_field(capability, "target_refs") do
      :ok
    end
  end

  defp validate_text_fields(map, keys) do
    case Enum.find(keys, &(not valid_optional_text_field?(map, &1))) do
      nil -> :ok
      key -> {:error, "invalid_field:#{key}"}
    end
  end

  defp valid_optional_text_field?(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) -> String.trim(value) != ""
      {:ok, _value} -> false
      :error -> true
    end
  end

  defp validate_string_list_fields(map, keys) do
    case Enum.find(keys, &(not valid_optional_string_list?(map, &1))) do
      nil -> :ok
      key -> {:error, "invalid_field:#{key}"}
    end
  end

  defp valid_optional_string_list?(map, key) do
    case Map.fetch(map, key) do
      {:ok, values} when is_list(values) ->
        Enum.all?(values, &(is_binary(&1) and String.trim(&1) != ""))

      {:ok, _value} ->
        false

      :error ->
        true
    end
  end

  defp validate_boolean_fields(map, keys) do
    case Enum.find(keys, &(not valid_optional_boolean?(map, &1))) do
      nil -> :ok
      key -> {:error, "invalid_field:#{key}"}
    end
  end

  defp valid_optional_boolean?(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_boolean(value) -> true
      {:ok, _value} -> false
      :error -> true
    end
  end

  defp validate_required_check_groups(%{"required_check_groups" => groups})
       when is_list(groups) do
    if Enum.all?(groups, &valid_check_group?/1) do
      :ok
    else
      {:error, "invalid_field:required_check_groups"}
    end
  end

  defp validate_required_check_groups(%{"required_check_groups" => _groups}),
    do: {:error, "invalid_field:required_check_groups"}

  defp validate_required_check_groups(_evidence_contract), do: :ok

  defp valid_check_group?(group) when is_map(group) do
    canonical_value?(group) and valid_optional_string_list?(group, "any_of")
  end

  defp valid_check_group?(_group), do: false

  defp validate_optional_map_field(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_map(value) ->
        case canonical_nested_map(key, value) do
          {:ok, _value} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:ok, _value} ->
        {:error, "invalid_field:#{key}"}

      :error ->
        :ok
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

  defp string_list_unique(values) do
    values
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp reject_empty(map) do
    map
    |> Enum.reject(fn {_key, value} -> empty?(value) end)
    |> Map.new()
  end

  defp empty?(nil), do: true
  defp empty?(""), do: true
  defp empty?([]), do: true
  defp empty?(map) when is_map(map), do: map_size(map) == 0
  defp empty?(_value), do: false

  defp stable_id(prefix, parts) do
    digest =
      :crypto.hash(:sha256, :erlang.term_to_binary(parts))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 24)

    "#{prefix}_#{digest}"
  end
end
