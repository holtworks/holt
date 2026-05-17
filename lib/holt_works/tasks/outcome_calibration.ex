defmodule HoltWorks.Tasks.OutcomeCalibration do
  @moduledoc """
  Calibration record comparing predicted and observed action outcomes.
  """

  alias HoltWorks.Clock
  alias HoltWorks.Tasks.RuntimeContracts

  @schema_version "holtworks_outcome_calibration/v1"

  def build(attrs \\ %{})

  def build(attrs) when is_map(attrs) do
    attrs = RuntimeContracts.string_keys(attrs)
    prediction = RuntimeContracts.normalize_map(RuntimeContracts.value(attrs, "prediction"))
    observation = RuntimeContracts.normalize_map(RuntimeContracts.value(attrs, "observation"))

    prediction_error =
      RuntimeContracts.normalize_map(RuntimeContracts.value(attrs, "prediction_error"))

    reconciliation =
      RuntimeContracts.normalize_map(RuntimeContracts.value(attrs, "state_reconciliation"))

    contract = RuntimeContracts.normalize_map(RuntimeContracts.value(attrs, "action_contract"))

    matched? =
      RuntimeContracts.truthy?(prediction_error["matched"]) and state_matched?(reconciliation)

    confidence_before = RuntimeContracts.number(prediction["confidence"], 0.35)

    %{
      "schema_version" => @schema_version,
      "calibration_id" =>
        RuntimeContracts.stable_id("calibration", [
          prediction["prediction_id"],
          observation["observation_id"],
          prediction_error["matched"]
        ]),
      "prediction_id" => prediction["prediction_id"],
      "observation_id" => observation["observation_id"],
      "state_reconciliation_id" => reconciliation["reconciliation_id"],
      "contract_id" => contract["contract_id"] || prediction_error["contract_id"],
      "tool_name" => contract["tool_name"] || prediction["tool_name"],
      "effect_scope" => contract["effect_scope"] || prediction["effect_scope"],
      "target_domain" => contract["target_domain"],
      "risk_level" => contract["risk_level"] || prediction["risk_level"],
      "task_pattern_key" => pattern_key(contract, prediction),
      "expected_result_status" => prediction_error["expected_result_status"],
      "actual_result_status" => prediction_error["actual_result_status"],
      "matched" => matched?,
      "state_matched" => reconciliation["matched"],
      "state_delta_accuracy" => reconciliation["state_delta_accuracy"],
      "severity" => prediction_error["severity"],
      "prediction_accuracy" => if(matched?, do: 1.0, else: 0.0),
      "confidence_before" => confidence_before,
      "confidence_after" =>
        confidence_after(confidence_before, matched?, prediction_error["severity"]),
      "lesson" => prediction_error["lesson"] || lesson(contract),
      "recommended_verification" => recommended_verification(prediction_error, contract),
      "recovery_recommendation" => recovery_recommendation(prediction_error, reconciliation),
      "created_at" => Clock.iso_now()
    }
    |> RuntimeContracts.reject_empty()
  end

  def build(_attrs), do: build(%{})

  def pattern_key(contract, prediction \\ %{}) do
    RuntimeContracts.stable_id("pattern", [
      contract["tool_name"] || prediction["tool_name"] || "unknown_tool",
      contract["effect_scope"] || prediction["effect_scope"] || "unknown_scope",
      contract["target_domain"] || "unknown_domain",
      contract["risk_level"] || prediction["risk_level"] || "unknown_risk"
    ])
  end

  defp state_matched?(reconciliation) when map_size(reconciliation) == 0, do: true
  defp state_matched?(reconciliation), do: RuntimeContracts.truthy?(reconciliation["matched"])

  defp confidence_after(confidence, true, _severity),
    do: min(0.99, Float.round(confidence + 0.04, 2))

  defp confidence_after(confidence, false, "critical"),
    do: max(0.1, Float.round(confidence - 0.3, 2))

  defp confidence_after(confidence, false, "high"),
    do: max(0.1, Float.round(confidence - 0.22, 2))

  defp confidence_after(confidence, false, "medium"),
    do: max(0.1, Float.round(confidence - 0.14, 2))

  defp confidence_after(confidence, false, _severity),
    do: max(0.1, Float.round(confidence - 0.08, 2))

  defp lesson(contract) do
    "verify_" <> to_string(contract["effect_scope"] || "effect") <> "_before_continuing"
  end

  defp recommended_verification(%{"matched" => true}, contract) do
    contract
    |> RuntimeContracts.value("verification")
    |> RuntimeContracts.normalize_map()
    |> RuntimeContracts.value("suggested_checks")
    |> RuntimeContracts.normalize_string_list()
  end

  defp recommended_verification(%{"actual_result_status" => "error"}, _contract) do
    ["check_preconditions", "capture_error_evidence", "retry_only_with_revised_plan"]
  end

  defp recommended_verification(_prediction_error, _contract),
    do: ["add_observation_specific_check"]

  defp recovery_recommendation(%{"matched" => true}, reconciliation) do
    case reconciliation["repair_directive"] do
      value when value not in [nil, "", "continue"] -> value
      _value -> "none"
    end
  end

  defp recovery_recommendation(_prediction_error, reconciliation) do
    reconciliation["repair_directive"] || "enter_repair_phase_with_new_prediction"
  end
end
