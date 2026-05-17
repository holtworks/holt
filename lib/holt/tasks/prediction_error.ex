defmodule Holt.Tasks.PredictionError do
  @moduledoc """
  Compares predicted action results with observed execution results.
  """

  alias Holt.Clock
  alias Holt.Tasks.RuntimeContracts

  @schema_version "holtworks_prediction_error/v1"

  def compare(attrs \\ %{})

  def compare(attrs) when is_map(attrs) do
    attrs = RuntimeContracts.string_keys(attrs)
    prediction = RuntimeContracts.normalize_map(RuntimeContracts.value(attrs, "prediction"))
    observation = RuntimeContracts.normalize_map(RuntimeContracts.value(attrs, "observation"))
    expected = prediction["expected_result_status"]
    actual = observation["status"]
    matched? = matched?(expected, actual)

    %{
      "schema_version" => @schema_version,
      "prediction_id" => prediction["prediction_id"],
      "observation_id" => observation["observation_id"],
      "contract_id" => prediction["contract_id"] || observation["contract_id"],
      "matched" => matched?,
      "severity" => severity(matched?, prediction["risk_level"], actual),
      "expected_result_status" => expected,
      "actual_result_status" => actual,
      "missed_effects" => missed_effects(matched?, expected, actual),
      "lesson" => lesson(matched?, actual),
      "recorded_at" => Clock.iso_now()
    }
    |> RuntimeContracts.reject_empty()
  end

  def compare(_attrs), do: compare(%{})

  defp matched?("ok", actual), do: actual in ["ok", "ok_final"]

  defp matched?("ok_or_awaiting_external_completion", actual) do
    actual in ["ok", "ok_final", "await_process"]
  end

  defp matched?("ok_or_nested_result", actual), do: actual in ["ok", "ok_final"]
  defp matched?("blocked_before_execution", actual), do: actual in ["await_approval", "error"]
  defp matched?(_expected, "unknown"), do: false
  defp matched?(_expected, actual), do: actual in ["ok", "ok_final"]

  defp severity(true, _risk, _actual), do: "none"
  defp severity(false, "critical", _actual), do: "critical"
  defp severity(false, "high", _actual), do: "high"
  defp severity(false, "medium", "error"), do: "medium"
  defp severity(false, _risk, _actual), do: "low"

  defp missed_effects(true, _expected, _actual), do: []

  defp missed_effects(false, expected, actual) do
    [
      "expected_result_status=#{expected || "unknown"}",
      "actual_result_status=#{actual || "unknown"}"
    ]
  end

  defp lesson(true, _actual), do: "prediction_matched_observation"
  defp lesson(false, "error"), do: "future_plans_should_model_tool_failure_before_retry"
  defp lesson(false, _actual), do: "future_plans_should_verify_observation_before_continuing"
end
