defmodule Holt.Tasks.EvidenceContract do
  @moduledoc """
  Structured proof contract for local task verification.

  The contract keeps verification decisions on explicit check types, artifact
  requirements, surface statuses, changed-file evidence, and command evidence.
  """

  alias Holt.Clock

  @schema_version "holtworks_evidence_contract/v1"
  @evaluation_schema_version "holtworks_evidence_contract_evaluation/v1"

  @base_contract %{
    "profile" => "generic",
    "required_check_groups" => [],
    "required_artifact_kinds" => ["verification_report"],
    "changed_files_required" => false,
    "command_evidence_required" => false,
    "ui_walkthrough_required" => false,
    "api_verification_required" => false,
    "graphql_verification_required" => false,
    "allowed_verifier_tools" => []
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
    attrs = string_keys(attrs)
    workflow_contract = normalize_map(value(attrs, "workflow_contract"))
    verification_contract = normalize_map(value(attrs, "verification_contract"))

    evidence_contract =
      Map.merge(
        normalize_map(value(workflow_contract, "evidence_contract")),
        normalize_map(value(verification_contract, "evidence_contract"))
      )
      |> Map.merge(normalize_map(value(attrs, "evidence_contract")))

    @base_contract
    |> Map.merge(contract_overrides(workflow_contract))
    |> Map.merge(contract_overrides(verification_contract))
    |> Map.merge(contract_overrides(evidence_contract))
    |> Map.merge(%{
      "schema_version" => @schema_version,
      "profile" => "generic",
      "source" => value(attrs, "source") || "holtworks_task_workflow_contract"
    })
    |> normalize_contract()
    |> reject_empty()
  end

  def build(_attrs), do: build(%{})

  def build_for_task(task, specs, attrs \\ %{}) do
    attrs = string_keys(attrs || %{})

    spec_contract =
      specs
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Enum.map(&contract_from_spec/1)
      |> Enum.reduce(%{}, &deep_merge(&2, &1))

    task_contract =
      task
      |> normalize_map()
      |> value("agent_policy")
      |> normalize_map()
      |> value("evidence_contract")
      |> normalize_map()

    build(%{
      "source" => "holtworks_task_contract",
      "evidence_contract" =>
        %{}
        |> deep_merge(task_contract)
        |> deep_merge(spec_contract)
        |> deep_merge(normalize_map(value(attrs, "evidence_contract"))),
      "workflow_contract" => normalize_map(value(attrs, "workflow_contract")),
      "verification_contract" => normalize_map(value(attrs, "verification_contract"))
    })
  end

  def evaluate(attrs \\ %{})

  def evaluate(attrs) when is_map(attrs) do
    attrs = string_keys(attrs)
    contract = normalize_map(value(attrs, "contract") || value(attrs, "evidence_contract"))
    checks = normalize_checks(value(attrs, "checks"))
    supplied_check_types = supplied_check_types(checks)
    passed_check_types = passed_check_types(checks)
    groups = normalize_check_groups(value(contract, "required_check_groups"))
    changed_files = normalize_string_list(value(attrs, "changed_files"))
    evidence = normalize_string_list(value(attrs, "evidence"))

    gaps =
      groups
      |> Enum.reject(&check_group_satisfied?(&1, passed_check_types))
      |> Enum.map(&missing_group_gap/1)
      |> maybe_gap(
        truthy?(value(contract, "changed_files_required")) and changed_files == [],
        "changed_files_required",
        "Changed files are required by the evidence contract."
      )
      |> maybe_gap(
        truthy?(value(contract, "command_evidence_required")) and not command_evidence?(checks),
        "command_evidence_required",
        "At least one passed check must include command evidence."
      )
      |> maybe_gap(
        truthy?(value(contract, "ui_walkthrough_required")) and
          normalize_surface_status(value(attrs, "ui_walkthrough_status")) != "verified",
        "ui_walkthrough_required",
        "UI walkthrough evidence must be verified."
      )
      |> maybe_gap(
        truthy?(value(contract, "api_verification_required")) and
          normalize_surface_status(value(attrs, "api_verification_status")) != "verified",
        "api_verification_required",
        "API verification evidence must be verified."
      )
      |> maybe_gap(
        truthy?(value(contract, "graphql_verification_required")) and
          normalize_surface_status(value(attrs, "graphql_verification_status")) != "verified",
        "graphql_verification_required",
        "GraphQL verification evidence must be verified."
      )

    %{
      "schema_version" => @evaluation_schema_version,
      "profile" => value(contract, "profile") || "generic",
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

  def evaluate(_attrs), do: evaluate(%{})

  defp contract_from_spec(spec) do
    metadata = normalize_map(value(spec, "metadata"))
    content = json_map(value(spec, "content"))

    %{}
    |> deep_merge(normalize_map(value(metadata, "evidence_contract")))
    |> deep_merge(normalize_map(value(content, "evidence_contract")))
    |> deep_merge(
      content
      |> value("verification_contract")
      |> normalize_map()
      |> value("evidence_contract")
      |> normalize_map()
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
      "allowed_verifier_tools",
      "risk_flags"
    ])
    |> reject_empty()
  end

  defp contract_overrides(_source), do: %{}

  defp normalize_contract(contract) do
    contract
    |> Map.update("required_check_groups", [], &normalize_check_groups/1)
    |> Map.update("required_artifact_kinds", [], &normalize_string_list/1)
    |> Map.update("allowed_verifier_tools", [], &normalize_string_list/1)
    |> Map.update("risk_flags", [], &normalize_string_list/1)
  end

  defp normalize_check_groups(groups) when is_list(groups) do
    groups
    |> Enum.map(&normalize_check_group/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_check_groups(_groups), do: []

  defp normalize_check_group(group) when is_map(group) do
    group = string_keys(group)
    any_of = normalize_string_list(value(group, "any_of"))

    if any_of == [] do
      nil
    else
      %{
        "group_id" => normalize_string(value(group, "group_id")) || Enum.join(any_of, "_or_"),
        "any_of" => any_of
      }
    end
  end

  defp normalize_check_group(value) do
    case normalize_string(value) do
      nil -> nil
      check_type -> %{"group_id" => check_type, "any_of" => [check_type]}
    end
  end

  defp normalize_checks(checks) when is_list(checks) do
    checks
    |> Enum.filter(&is_map/1)
    |> Enum.map(&string_keys/1)
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
      &(normalize_check_status(value(&1, "status"), value(&1, "passed")) == "passed")
    )
    |> supplied_check_types()
  end

  defp check_type(check) do
    check
    |> first_value(["check_type", "type", "name"])
    |> normalize_string()
  end

  defp check_group_satisfied?(group, passed_check_types) do
    group
    |> value("any_of")
    |> List.wrap()
    |> Enum.any?(&(&1 in passed_check_types))
  end

  defp missing_group_gap(group) do
    %{
      "code" => "missing_check_group",
      "group_id" => value(group, "group_id"),
      "message" => "Missing passed check for #{value(group, "group_id")}.",
      "any_of" => value(group, "any_of") || []
    }
    |> reject_empty()
  end

  defp maybe_gap(gaps, false, _code, _message), do: gaps

  defp maybe_gap(gaps, true, code, message) do
    gaps ++ [%{"code" => code, "message" => message}]
  end

  defp command_evidence?(checks) do
    Enum.any?(checks, fn check ->
      normalize_check_status(value(check, "status"), value(check, "passed")) == "passed" and
        normalize_string(value(check, "command")) not in [nil, ""]
    end)
  end

  defp normalize_check_status(_status, true), do: "passed"
  defp normalize_check_status(status, _passed), do: normalize_string(status)

  defp normalize_surface_status(nil), do: "not_applicable"
  defp normalize_surface_status(value), do: normalize_string(value) || "not_applicable"

  defp json_map(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> string_keys(decoded)
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

  defp first_value(map, keys) do
    Enum.find_value(keys, &value(map, &1))
  end

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

  defp normalize_map(value) when is_map(value), do: string_keys(value)
  defp normalize_map(_value), do: %{}

  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp value(_map, _key), do: nil

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(1), do: true
  defp truthy?(_value), do: false

  defp string_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), normalize_value(value)}
      {key, value} -> {to_string(key), normalize_value(value)}
    end)
  end

  defp string_keys(_value), do: %{}

  defp normalize_value(value) when is_map(value), do: string_keys(value)
  defp normalize_value(value) when is_list(value), do: Enum.map(value, &normalize_value/1)
  defp normalize_value(value), do: value

  defp reject_empty(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end
end
