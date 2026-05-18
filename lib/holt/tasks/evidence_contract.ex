defmodule Holt.Tasks.EvidenceContract do
  @moduledoc """
  Structured proof contract for local task verification.

  The contract keeps verification decisions on explicit check types, artifact
  requirements, surface statuses, changed-file evidence, and command evidence.
  """

  alias Holt.Clock

  @schema_version "holt_evidence_contract/v1"
  @evaluation_schema_version "holt_evidence_contract_evaluation/v1"
  @obsolete_evaluation_keys ~w(contract)

  @base_contract %{
    "profile" => "generic",
    "required_check_groups" => [],
    "required_artifact_kinds" => ["verification_report"],
    "changed_files_required" => false,
    "command_evidence_required" => false,
    "ui_walkthrough_required" => false,
    "api_verification_required" => false,
    "graphql_verification_required" => false,
    "allowed_verifier_actions" => []
  }

  def check_types do
    ~w(
      acceptance_criterion api_check artifact_review behavior_check browser_check
      command_check data_check evidence_review external_system_check graphql_check
      human_review integration_check manual_review policy_check regression_check
      risk_review security_review visual_check
    )
  end

  def build(attrs \\ %{})

  def build(attrs) when is_map(attrs) do
    with :ok <- canonical_attrs(attrs) do
      attrs = string_keyed_map(attrs)
      workflow_contract = map_field(attrs, "workflow_contract")
      verification_contract = map_field(attrs, "verification_contract")

      evidence_contract =
        Map.merge(
          map_field(workflow_contract, "evidence_contract"),
          map_field(verification_contract, "evidence_contract")
        )
        |> Map.merge(map_field(attrs, "evidence_contract"))

      @base_contract
      |> Map.merge(contract_overrides(workflow_contract))
      |> Map.merge(contract_overrides(verification_contract))
      |> Map.merge(contract_overrides(evidence_contract))
      |> Map.merge(%{
        "schema_version" => @schema_version,
        "profile" => "generic",
        "source" => contract_source(attrs)
      })
      |> normalize_contract()
      |> reject_empty()
    else
      {:error, reason} -> rejected_contract(reason)
    end
  end

  def build(_attrs), do: rejected_contract("invalid_attrs")

  def build_for_task(task, specs, attrs \\ %{}) do
    attrs = string_keyed_map(attrs)

    spec_contract =
      specs
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Enum.map(&contract_from_spec/1)
      |> Enum.reduce(%{}, &deep_merge(&2, &1))

    task_contract =
      task
      |> string_keyed_map()
      |> Map.get("agent_policy")
      |> string_keyed_map()
      |> Map.get("evidence_contract")
      |> string_keyed_map()

    build(%{
      "source" => "holt_task_contract",
      "evidence_contract" =>
        %{}
        |> deep_merge(task_contract)
        |> deep_merge(spec_contract)
        |> deep_merge(map_field(attrs, "evidence_contract")),
      "workflow_contract" => map_field(attrs, "workflow_contract"),
      "verification_contract" => map_field(attrs, "verification_contract")
    })
  end

  def evaluate(attrs \\ %{})

  def evaluate(attrs) when is_map(attrs) do
    with :ok <- canonical_attrs(attrs) do
      attrs = string_keyed_map(attrs)

      case obsolete_key(attrs, @obsolete_evaluation_keys) do
        nil -> evaluate_contract(attrs)
        key -> rejected_evaluation("obsolete_key:#{key}")
      end
    else
      {:error, reason} -> rejected_evaluation(reason)
    end
  end

  def evaluate(_attrs), do: rejected_evaluation("invalid_attrs")

  defp evaluate_contract(attrs) do
    contract = map_field(attrs, "evidence_contract")
    checks = normalize_checks(Map.get(attrs, "checks"))
    supplied_check_types = supplied_check_types(checks)
    passed_check_types = passed_check_types(checks)
    groups = normalize_check_groups(Map.get(contract, "required_check_groups"))
    changed_files = normalize_string_list(Map.get(attrs, "changed_files"))
    evidence = normalize_string_list(Map.get(attrs, "evidence"))

    gaps =
      groups
      |> Enum.reject(&check_group_satisfied?(&1, passed_check_types))
      |> Enum.map(&missing_group_gap/1)
      |> maybe_gap(
        required?(contract, "changed_files_required") and changed_files == [],
        "changed_files_required",
        "Changed files are required by the evidence contract."
      )
      |> maybe_gap(
        required?(contract, "command_evidence_required") and not command_evidence?(checks),
        "command_evidence_required",
        "At least one passed check must include command evidence."
      )
      |> maybe_gap(
        required?(contract, "ui_walkthrough_required") and
          surface_verified?(attrs, "ui_walkthrough_status") == false,
        "ui_walkthrough_required",
        "UI walkthrough evidence must be verified."
      )
      |> maybe_gap(
        required?(contract, "api_verification_required") and
          surface_verified?(attrs, "api_verification_status") == false,
        "api_verification_required",
        "API verification evidence must be verified."
      )
      |> maybe_gap(
        required?(contract, "graphql_verification_required") and
          surface_verified?(attrs, "graphql_verification_status") == false,
        "graphql_verification_required",
        "GraphQL verification evidence must be verified."
      )

    %{
      "schema_version" => @evaluation_schema_version,
      "profile" => contract_profile(contract),
      "satisfied" => gaps == [],
      "missing_requirements" => gaps,
      "required_check_groups" => groups,
      "supplied_check_types" => supplied_check_types,
      "passed_check_types" => passed_check_types,
      "changed_files_count" => length(changed_files),
      "evidence_count" => length(evidence),
      "evaluated_at" => Clock.iso_now()
    }
    |> reject_empty()
  end

  defp contract_from_spec(spec) do
    metadata = map_field(spec, "metadata")
    content = json_map(Map.get(spec, "content"))

    %{}
    |> deep_merge(map_field(metadata, "evidence_contract"))
    |> deep_merge(map_field(content, "evidence_contract"))
    |> deep_merge(
      content
      |> Map.get("verification_contract")
      |> string_keyed_map()
      |> Map.get("evidence_contract")
      |> string_keyed_map()
    )
  end

  defp contract_overrides(source) when is_map(source) do
    source
    |> Map.take([
      "required_check_groups",
      "required_artifact_kinds",
      "changed_files_required",
      "command_evidence_required",
      "ui_walkthrough_required",
      "api_verification_required",
      "graphql_verification_required",
      "allowed_verifier_actions",
      "risk_flags"
    ])
    |> reject_empty()
  end

  defp contract_overrides(_source), do: %{}

  defp normalize_contract(contract) do
    contract
    |> Map.update("required_check_groups", [], &normalize_check_groups/1)
    |> Map.update("required_artifact_kinds", [], &normalize_string_list/1)
    |> Map.update("allowed_verifier_actions", [], &normalize_string_list/1)
    |> Map.update("risk_flags", [], &normalize_string_list/1)
  end

  defp normalize_check_groups(groups) when is_list(groups) do
    groups
    |> Enum.map(&normalize_check_group/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_check_groups(_groups), do: []

  defp normalize_check_group(group) when is_map(group) do
    group = string_keyed_map(group)
    any_of = normalize_string_list(Map.get(group, "any_of"))

    if any_of == [] do
      nil
    else
      %{
        "group_id" => check_group_id(group, any_of),
        "any_of" => any_of
      }
    end
  end

  defp normalize_check_group(_value), do: nil

  defp normalize_checks(checks) when is_list(checks) do
    checks
    |> Enum.filter(&is_map/1)
    |> Enum.map(&string_keyed_map/1)
    |> Enum.reject(&(&1 == %{}))
  end

  defp normalize_checks(_checks), do: []

  defp supplied_check_types(checks) do
    checks
    |> Enum.map(&check_type/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp passed_check_types(checks) do
    checks
    |> Enum.filter(
      &(normalize_check_status(Map.get(&1, "status"), Map.get(&1, "passed")) == "passed")
    )
    |> supplied_check_types()
  end

  defp check_type(check) do
    check
    |> Map.get("check_type")
    |> normalize_string()
  end

  defp check_group_satisfied?(group, passed_check_types) do
    group
    |> Map.get("any_of")
    |> List.wrap()
    |> Enum.any?(&(&1 in passed_check_types))
  end

  defp missing_group_gap(group) do
    %{
      "code" => "missing_check_group",
      "group_id" => Map.get(group, "group_id"),
      "message" => "Missing passed check for #{Map.get(group, "group_id")}.",
      "any_of" => check_group_options(group)
    }
    |> reject_empty()
  end

  defp maybe_gap(gaps, false, _code, _message), do: gaps

  defp maybe_gap(gaps, true, code, message) do
    gaps ++ [%{"code" => code, "message" => message}]
  end

  defp command_evidence?(checks) do
    Enum.any?(checks, fn check ->
      normalize_check_status(Map.get(check, "status"), Map.get(check, "passed")) == "passed" and
        normalize_string(Map.get(check, "command")) not in [nil, ""]
    end)
  end

  defp normalize_check_status(_status, true), do: "passed"
  defp normalize_check_status(status, _passed), do: normalize_string(status)

  defp surface_verified?(attrs, key), do: normalize_string(Map.get(attrs, key)) == "verified"

  defp json_map(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> string_keyed_map(decoded)
      _result -> %{}
    end
  end

  defp json_map(_value), do: %{}

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      if is_map(left_value) and is_map(right_value) do
        deep_merge(left_value, right_value)
      else
        right_value
      end
    end)
  end

  defp deep_merge(left, _right) when is_map(left), do: left
  defp deep_merge(_left, right) when is_map(right), do: right
  defp deep_merge(_left, _right), do: %{}

  defp normalize_string_list(nil), do: []

  defp normalize_string_list(value) when is_list(value) do
    value
    |> Enum.flat_map(&normalize_string_list/1)
    |> Enum.uniq()
  end

  defp normalize_string_list(value) do
    case normalize_string(value) do
      nil ->
        []

      text ->
        text
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
    end
  end

  defp normalize_string(nil), do: nil

  defp normalize_string(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp required?(contract, key), do: Map.get(contract, key) == true

  defp check_group_id(group, any_of) do
    case normalize_string(Map.get(group, "group_id")) do
      nil -> Enum.join(any_of, "_or_")
      group_id -> group_id
    end
  end

  defp check_group_options(group) do
    case Map.get(group, "any_of") do
      options when is_list(options) -> options
      _options -> []
    end
  end

  defp contract_source(%{"source" => source}) when is_binary(source) and source != "",
    do: source

  defp contract_source(_attrs), do: "holt_task_workflow_contract"

  defp contract_profile(%{"profile" => profile}) when is_binary(profile) and profile != "",
    do: profile

  defp contract_profile(_contract), do: "generic"

  defp map_field(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_map(value) -> string_keyed_map(value)
      _value -> %{}
    end
  end

  defp map_field(_map, _key), do: %{}

  defp string_keyed_map(map) when is_map(map) do
    if Enum.all?(Map.keys(map), &is_binary/1) do
      Map.new(map, fn {key, value} -> {key, normalize_value(value)} end)
    else
      %{}
    end
  end

  defp string_keyed_map(_value), do: %{}

  defp normalize_value(value) when is_map(value), do: string_keyed_map(value)
  defp normalize_value(value) when is_list(value), do: Enum.map(value, &normalize_value/1)
  defp normalize_value(value), do: value

  defp obsolete_key(attrs, keys) do
    Enum.find(keys, &Map.has_key?(attrs, &1))
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

  defp rejected_contract(reason) do
    %{
      "schema_version" => @schema_version,
      "status" => "rejected",
      "reason" => reason,
      "generated_at" => Clock.iso_now()
    }
  end

  defp rejected_evaluation(reason) do
    %{
      "schema_version" => @evaluation_schema_version,
      "status" => "rejected",
      "reason" => reason,
      "satisfied" => false,
      "evaluated_at" => Clock.iso_now()
    }
  end

  defp reject_empty(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end
end
