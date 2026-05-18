defmodule Holt.Tasks.PredictionError do
  @moduledoc """
  Compares predicted action results with observed execution results.
  """

  alias Holt.Clock

  @schema_version "holt_prediction_error/v1"

  def compare(attrs \\ %{})

  def compare(attrs) when is_map(attrs) do
    case input(attrs) do
      {:ok, input} -> compare_canonical(input)
      {:error, reason} -> rejected_error(reason)
    end
  end

  def compare(_attrs), do: rejected_error("invalid_attrs")

  defp input(attrs) do
    with :ok <- canonical_attrs(attrs),
         {:ok, prediction} <- prediction(attrs),
         {:ok, observation} <- observation(attrs) do
      {:ok, %{prediction: prediction, observation: observation}}
    end
  end

  defp compare_canonical(input) do
    prediction = input.prediction
    observation = input.observation
    expected = prediction["expected_result_status"]
    actual = observation["status"]
    matched? = matched?(expected, actual)

    %{
      "schema_version" => @schema_version,
      "prediction_id" => prediction["prediction_id"],
      "observation_id" => observation["observation_id"],
      "contract_id" => prediction["contract_id"],
      "matched" => matched?,
      "severity" => severity(matched?, prediction["risk_level"], actual),
      "expected_result_status" => expected,
      "actual_result_status" => actual,
      "missed_effects" => missed_effects(matched?, expected, actual),
      "lesson" => lesson(matched?, actual),
      "recorded_at" => Clock.iso_now()
    }
    |> compact()
  end

  defp rejected_error(reason) do
    %{
      "schema_version" => @schema_version,
      "status" => "rejected",
      "reason" => reason,
      "recorded_at" => Clock.iso_now()
    }
  end

  defp prediction(attrs) do
    case Map.fetch(attrs, "prediction") do
      {:ok, prediction} when is_map(prediction) ->
        with :ok <- validate_prediction(prediction) do
          {:ok, prediction}
        end

      {:ok, _prediction} ->
        {:error, "invalid_prediction"}

      :error ->
        {:error, "missing_prediction"}
    end
  end

  defp validate_prediction(prediction) do
    with {:ok, _prediction_id} <- required_text(prediction, "prediction_id", "invalid_prediction"),
         {:ok, _contract_id} <- required_text(prediction, "contract_id", "invalid_prediction"),
         {:ok, expected} <-
           required_text(prediction, "expected_result_status", "invalid_prediction"),
         :ok <- expected_status(expected),
         {:ok, risk} <- required_text(prediction, "risk_level", "invalid_prediction"),
         :ok <- risk_level(risk) do
      :ok
    end
  end

  defp observation(attrs) do
    case Map.fetch(attrs, "observation") do
      {:ok, observation} when is_map(observation) ->
        with :ok <- validate_observation(observation) do
          {:ok, observation}
        end

      {:ok, _observation} ->
        {:error, "invalid_observation"}

      :error ->
        {:error, "missing_observation"}
    end
  end

  defp validate_observation(observation) do
    with {:ok, _observation_id} <-
           required_text(observation, "observation_id", "invalid_observation"),
         {:ok, status} <- required_text(observation, "status", "invalid_observation"),
         :ok <- observation_status(status) do
      :ok
    end
  end

  defp expected_status("ok"), do: :ok
  defp expected_status("ok_or_awaiting_external_completion"), do: :ok
  defp expected_status("ok_or_nested_result"), do: :ok
  defp expected_status("blocked_before_execution"), do: :ok
  defp expected_status(_status), do: {:error, "invalid_prediction"}

  defp observation_status("ok"), do: :ok
  defp observation_status("ok_final"), do: :ok
  defp observation_status("await_process"), do: :ok
  defp observation_status("await_user"), do: :ok
  defp observation_status("await_approval"), do: :ok
  defp observation_status("error"), do: :ok
  defp observation_status("rejected"), do: :ok
  defp observation_status(_status), do: {:error, "invalid_observation"}

  defp risk_level("low"), do: :ok
  defp risk_level("medium"), do: :ok
  defp risk_level("high"), do: :ok
  defp risk_level("critical"), do: :ok
  defp risk_level(_risk), do: {:error, "invalid_prediction"}

  defp matched?("ok", "ok"), do: true
  defp matched?("ok", "ok_final"), do: true
  defp matched?("ok", _actual), do: false
  defp matched?("ok_or_awaiting_external_completion", "ok"), do: true
  defp matched?("ok_or_awaiting_external_completion", "ok_final"), do: true
  defp matched?("ok_or_awaiting_external_completion", "await_process"), do: true
  defp matched?("ok_or_awaiting_external_completion", _actual), do: false
  defp matched?("ok_or_nested_result", "ok"), do: true
  defp matched?("ok_or_nested_result", "ok_final"), do: true
  defp matched?("ok_or_nested_result", _actual), do: false
  defp matched?("blocked_before_execution", "await_approval"), do: true
  defp matched?("blocked_before_execution", "error"), do: true
  defp matched?("blocked_before_execution", _actual), do: false

  defp severity(true, _risk, _actual), do: "none"
  defp severity(false, "critical", _actual), do: "critical"
  defp severity(false, "high", _actual), do: "high"
  defp severity(false, "medium", "error"), do: "medium"
  defp severity(false, _risk, _actual), do: "low"

  defp missed_effects(true, _expected, _actual), do: []

  defp missed_effects(false, expected, actual) do
    [
      "expected_result_status=#{expected}",
      "actual_result_status=#{actual}"
    ]
  end

  defp lesson(true, _actual), do: "prediction_matched_observation"
  defp lesson(false, "error"), do: "future_plans_should_model_action_failure_before_retry"
  defp lesson(false, _actual), do: "future_plans_should_verify_observation_before_continuing"

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

  defp required_text(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, reason}
          text -> {:ok, text}
        end

      {:ok, _value} ->
        {:error, reason}

      :error ->
        {:error, reason}
    end
  end

  defp compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end
end
