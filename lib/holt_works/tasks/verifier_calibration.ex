defmodule HoltWorks.Tasks.VerifierCalibration do
  @moduledoc """
  Calibration record for verifier quality.

  Verifier assignment proves independence and capability. Calibration measures
  whether the verifier's verdict matched later structured outcome signals so
  future assignment can prefer stronger verifiers.
  """

  alias HoltWorks.Clock
  alias HoltWorks.Tasks.RuntimeContracts

  @schema_version "holtworks_verifier_calibration/v1"

  def build(attrs \\ %{})

  def build(attrs) when is_map(attrs) do
    attrs = RuntimeContracts.string_keys(attrs)
    assignment = RuntimeContracts.normalize_map(attrs["verifier_assignment"])
    selected_verifier = RuntimeContracts.normalize_map(assignment["selected_verifier"])
    evaluation = RuntimeContracts.normalize_map(attrs["evaluation"] || attrs["verdict"])
    outcome_calibration = RuntimeContracts.normalize_map(attrs["outcome_calibration"])
    work_graph_gate = RuntimeContracts.normalize_map(attrs["work_graph_gate"])
    verifier_agent_id = first_present([attrs["verifier_agent_id"], selected_verifier["agent_id"]])
    verdict = verifier_verdict(evaluation)

    later_outcome =
      later_outcome(attrs, verdict, evaluation, outcome_calibration, work_graph_gate)

    missed_failure_kinds = missed_failure_kinds(attrs, outcome_calibration, work_graph_gate)

    %{
      "schema_version" => @schema_version,
      "calibration_id" =>
        RuntimeContracts.stable_id("verifier_calibration", [
          assignment["assignment_id"],
          verifier_agent_id,
          attrs["verifier_route_id"] || evaluation["verifier_route_id"],
          attrs["verifier_child_contract_id"] || evaluation["verifier_child_contract_id"],
          verdict,
          later_outcome
        ]),
      "verifier_agent_id" => verifier_agent_id,
      "verifier_assignment_id" => assignment["assignment_id"],
      "verifier_route_id" => attrs["verifier_route_id"] || evaluation["verifier_route_id"],
      "verifier_child_contract_id" =>
        attrs["verifier_child_contract_id"] || evaluation["verifier_child_contract_id"],
      "verifier_tool_call_id" =>
        attrs["verifier_tool_call_id"] || evaluation["verifier_tool_call_id"],
      "work_product_ref" => assignment["work_product_ref"],
      "verdict" => verdict,
      "later_outcome" => later_outcome,
      "accuracy_delta" => accuracy_delta(later_outcome),
      "missed_failure_kinds" => missed_failure_kinds,
      "recommended_future_assignment_policy" =>
        recommended_future_assignment_policy(later_outcome, missed_failure_kinds),
      "assignment_result" => assignment["assignment_result"],
      "selected_verifier" => selected_verifier,
      "completion_decision" => evaluation["completion_decision"],
      "verification_status" => evaluation["verification_status"],
      "can_finish" => evaluation["can_finish"],
      "required_reviewers" => evaluation["required_reviewers"] || [],
      "outcome_source" => outcome_source(attrs, outcome_calibration, work_graph_gate),
      "created_at" => Clock.iso_now()
    }
    |> RuntimeContracts.reject_empty()
  end

  def build(_attrs), do: build(%{})

  defp verifier_verdict(evaluation) do
    completion_decision = evaluation["completion_decision"]
    verification_status = evaluation["verification_status"]
    can_finish? = RuntimeContracts.truthy?(evaluation["can_finish"])
    required_reviewers = evaluation["required_reviewers"] || []

    cond do
      completion_decision == "auto_finish_allowed" and verification_status == "passed" and
          can_finish? ->
        "approved"

      completion_decision in ["fix_required", "rejected"] or verification_status == "failed" ->
        "rejected"

      completion_decision == "human_review_required" or required_reviewers != [] ->
        "human_review_required"

      true ->
        "unknown"
    end
  end

  defp later_outcome(attrs, verdict, evaluation, outcome_calibration, work_graph_gate) do
    explicit = RuntimeContracts.text(attrs, "later_outcome")

    cond do
      explicit not in [nil, ""] ->
        explicit

      verdict == "approved" and outcome_calibration["matched"] == false ->
        "missed_failure"

      verdict == "approved" and severe_work_graph_blockers?(work_graph_gate) ->
        "missed_failure"

      verdict in ["rejected", "human_review_required"] and
          RuntimeContracts.truthy?(attrs["later_auto_finish_allowed"]) ->
        "false_block"

      verdict == "human_review_required" ->
        "unresolved"

      verdict in ["approved", "rejected"] and evaluation["completion_decision"] not in [nil, ""] ->
        "matched"

      true ->
        "unresolved"
    end
  end

  defp missed_failure_kinds(attrs, outcome_calibration, work_graph_gate) do
    explicit = RuntimeContracts.normalize_string_list(attrs["missed_failure_kinds"])

    if explicit != [] do
      explicit
    else
      calibration_effects =
        outcome_calibration
        |> RuntimeContracts.value("missed_effects")
        |> RuntimeContracts.normalize_string_list()

      blockers =
        work_graph_gate
        |> RuntimeContracts.value("blockers")
        |> List.wrap()
        |> Enum.map(&RuntimeContracts.value(&1, "code"))
        |> RuntimeContracts.normalize_string_list()

      (calibration_effects ++ blockers)
      |> RuntimeContracts.normalize_string_list()
    end
  end

  defp severe_work_graph_blockers?(work_graph_gate) do
    work_graph_gate
    |> RuntimeContracts.value("blockers")
    |> List.wrap()
    |> Enum.any?(fn blocker ->
      RuntimeContracts.value(blocker, "code") in [
        "severe_prediction_error",
        "route_verification_review_not_satisfied",
        "child_agent_contract_incomplete"
      ]
    end)
  end

  defp accuracy_delta("matched"), do: 0.04
  defp accuracy_delta("missed_failure"), do: -0.18
  defp accuracy_delta("false_block"), do: -0.1
  defp accuracy_delta(_later_outcome), do: 0.0

  defp recommended_future_assignment_policy("matched", _missed_failure_kinds),
    do: "keep_current_verifier_eligible"

  defp recommended_future_assignment_policy("missed_failure", missed_failure_kinds) do
    if missed_failure_kinds == [] do
      "downrank_verifier_until_more_successes"
    else
      "require_second_verifier_for_matching_failure_kinds"
    end
  end

  defp recommended_future_assignment_policy("false_block", _missed_failure_kinds),
    do: "downrank_for_low_risk_or_time_sensitive_work"

  defp recommended_future_assignment_policy(_later_outcome, _missed_failure_kinds),
    do: "keep_baseline_until_outcome_resolved"

  defp outcome_source(attrs, outcome_calibration, work_graph_gate) do
    cond do
      RuntimeContracts.text(attrs, "later_outcome") not in [nil, ""] ->
        "explicit_later_outcome"

      map_size(outcome_calibration) > 0 ->
        "outcome_calibration"

      map_size(work_graph_gate) > 0 ->
        "work_graph_gate"

      true ->
        "objective_evaluation"
    end
  end

  defp first_present(values) do
    values
    |> RuntimeContracts.normalize_string_list()
    |> List.first()
  end
end
