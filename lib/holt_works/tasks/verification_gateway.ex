defmodule HoltWorks.Tasks.VerificationGateway do
  @moduledoc """
  Pure verification gate evaluator for local task runs.

  The gateway combines explicit check statuses, risk flags, and the evidence
  contract evaluation into the route that task and graph orchestration consume.
  """

  alias HoltWorks.Clock
  alias HoltWorks.Tasks.EvidenceContract

  @schema_version "holtworks_verification_gateway/v1"
  @route_schema_version "holtworks_verification_route/v1"
  @attention_statuses ~w(failed blocked needs_review)

  def evaluate(attrs \\ %{})

  def evaluate(attrs) when is_map(attrs) do
    attrs = string_keys(attrs)
    checks = normalize_checks(value(attrs, "checks"))
    risk_flags = normalize_string_list(value(attrs, "risk_flags"))

    contract =
      attrs
      |> value("evidence_contract")
      |> normalize_map()
      |> case do
        empty when empty == %{} -> EvidenceContract.build(%{})
        contract -> contract
      end

    evidence_evaluation =
      EvidenceContract.evaluate(%{
        "evidence_contract" => contract,
        "checks" => checks,
        "changed_files" => value(attrs, "changed_files"),
        "evidence" => value(attrs, "evidence"),
        "ui_walkthrough_status" => value(attrs, "ui_walkthrough_status"),
        "api_verification_status" => value(attrs, "api_verification_status"),
        "graphql_verification_status" => value(attrs, "graphql_verification_status")
      })

    checks_passed? = checks != [] and Enum.all?(checks, &(&1["status"] == "passed"))
    attention_required? = Enum.any?(checks, &(&1["status"] in @attention_statuses))
    evidence_satisfied? = truthy?(value(evidence_evaluation, "satisfied"))

    can_finish? =
      checks_passed? and not attention_required? and risk_flags == [] and evidence_satisfied?

    reason =
      route_reason(can_finish?, attention_required?, risk_flags, evidence_satisfied?, checks)

    route =
      %{
        "schema_version" => @route_schema_version,
        "can_finish" => can_finish?,
        "requires_human_review" => not can_finish?,
        "status" => if(can_finish?, do: "auto_finish", else: "needs_review"),
        "reason" => reason,
        "evidence_contract_satisfied" => evidence_satisfied?,
        "missing_requirements" => value(evidence_evaluation, "missing_requirements") || []
      }
      |> reject_empty()

    verifier = verifier_gate(route, evidence_evaluation, checks)

    %{
      "schema_version" => @schema_version,
      "status" => if(can_finish?, do: "submitted", else: gateway_status(checks, reason)),
      "required" => true,
      "satisfied" => can_finish?,
      "can_finish" => can_finish?,
      "reason" => reason,
      "route" => route,
      "evidence_contract" => contract,
      "evidence_evaluation" => evidence_evaluation,
      "verifier" => verifier,
      "risk_flags" => risk_flags,
      "failed_checks" => checks_with_status(checks, "failed"),
      "blocked_checks" => checks_with_status(checks, "blocked"),
      "unknown_checks" => checks_with_status(checks, "needs_review"),
      "evaluated_at" => Clock.iso_now()
    }
    |> reject_empty()
  end

  def evaluate(_attrs), do: evaluate(%{})

  def satisfied?(gateway) when is_map(gateway), do: truthy?(value(gateway, "satisfied"))
  def satisfied?(_gateway), do: false

  def route(gateway) when is_map(gateway), do: value(gateway, "route") || %{}
  def route(_gateway), do: %{}

  defp gateway_status(_checks, "all_checks_passed"), do: "submitted"
  defp gateway_status([], _reason), do: "required"
  defp gateway_status(_checks, _reason), do: "blocked"

  defp route_reason(true, _attention_required?, _risk_flags, _evidence_satisfied?, _checks) do
    "all_checks_passed"
  end

  defp route_reason(false, true, _risk_flags, _evidence_satisfied?, _checks) do
    "check_requires_attention"
  end

  defp route_reason(false, _attention_required?, [_flag | _rest], _evidence_satisfied?, _checks) do
    "risk_review_required"
  end

  defp route_reason(false, _attention_required?, _risk_flags, false, _checks) do
    "evidence_contract_not_satisfied"
  end

  defp route_reason(false, _attention_required?, _risk_flags, _evidence_satisfied?, _checks) do
    "verification_incomplete"
  end

  defp verifier_gate(route, evidence_evaluation, checks) do
    status =
      cond do
        route["can_finish"] == true ->
          "approved"

        checks == [] ->
          "pending"

        route["reason"] == "risk_review_required" ->
          "human_review_required"

        true ->
          "rejected"
      end

    %{
      "schema_version" => "holtworks_verifier_gate/v1",
      "strategy" => "structured_evidence_contract",
      "independent" => true,
      "status" => status,
      "reason" => verifier_reason(status, route),
      "missing_requirements" => value(evidence_evaluation, "missing_requirements") || [],
      "evaluated_at" => Clock.iso_now()
    }
    |> reject_empty()
  end

  defp verifier_reason("approved", _route), do: "structured_evidence_passed"
  defp verifier_reason("pending", _route), do: "verification_report_missing"
  defp verifier_reason("human_review_required", _route), do: "human_review_required"
  defp verifier_reason("rejected", route), do: route["reason"] || "verification_failed"
  defp verifier_reason(_status, _route), do: "verification_incomplete"

  defp checks_with_status(checks, status) do
    Enum.filter(checks, &(&1["status"] == status))
  end

  defp normalize_checks(checks) when is_list(checks) do
    Enum.map(checks, &string_keys/1)
  end

  defp normalize_checks(_checks), do: []

  defp normalize_string_list(nil), do: []

  defp normalize_string_list(value) when is_list(value) do
    value
    |> Enum.flat_map(&normalize_string_list/1)
    |> Enum.uniq()
  end

  defp normalize_string_list(value) do
    text =
      value
      |> to_string()
      |> String.trim()

    if text == "", do: [], else: [text]
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
