defmodule Holt.Tasks.OutcomeCalibration do
  @moduledoc """
  Calibration record comparing predicted and observed action outcomes.
  """

  alias Holt.Clock

  @schema_version "holt_outcome_calibration/v1"

  def build(attrs \\ %{})

  def build(attrs) when is_map(attrs) do
    case input(attrs) do
      {:ok, input} -> build_canonical(input)
      {:error, reason} -> rejected_calibration(reason)
    end
  end

  def build(_attrs), do: rejected_calibration("invalid_attrs")

  def pattern_key(%{
        "action" => action,
        "effect_scope" => effect_scope,
        "target_domain" => target_domain,
        "risk_level" => risk_level
      }) do
    stable_id("pattern", [action, effect_scope, target_domain, risk_level])
  end

  def pattern_key(_contract), do: stable_id("pattern", ["invalid_contract"])

  defp input(attrs) do
    with :ok <- canonical_attrs(attrs),
         {:ok, contract} <- action_contract(attrs),
         {:ok, prediction} <- prediction(attrs),
         {:ok, observation} <- observation(attrs),
         {:ok, prediction_error} <- prediction_error(attrs),
         {:ok, reconciliation} <- state_reconciliation(attrs) do
      {:ok,
       %{
         action_contract: contract,
         prediction: prediction,
         observation: observation,
         prediction_error: prediction_error,
         state_reconciliation: reconciliation
       }}
    end
  end

  defp build_canonical(input) do
    contract = input.action_contract
    prediction = input.prediction
    observation = input.observation
    prediction_error = input.prediction_error
    reconciliation = input.state_reconciliation
    matched? = matched?(prediction_error, reconciliation)
    confidence_before = numeric_confidence(prediction["confidence"])

    %{
      "schema_version" => @schema_version,
      "calibration_id" =>
        stable_id("calibration", [
          prediction["prediction_id"],
          observation["observation_id"],
          prediction_error["matched"],
          reconciliation["matched"]
        ]),
      "prediction_id" => prediction["prediction_id"],
      "observation_id" => observation["observation_id"],
      "state_reconciliation_id" => reconciliation["reconciliation_id"],
      "contract_id" => contract["contract_id"],
      "action" => contract["action"],
      "effect_scope" => contract["effect_scope"],
      "target_domain" => contract["target_domain"],
      "risk_level" => contract["risk_level"],
      "task_pattern_key" => pattern_key(contract),
      "expected_result_status" => prediction_error["expected_result_status"],
      "actual_result_status" => prediction_error["actual_result_status"],
      "matched" => matched?,
      "state_matched" => reconciliation["matched"],
      "state_delta_accuracy" => reconciliation["state_delta_accuracy"],
      "severity" => prediction_error["severity"],
      "prediction_accuracy" => prediction_accuracy(matched?),
      "confidence_before" => confidence_before,
      "confidence_after" =>
        confidence_after(confidence_before, matched?, prediction_error["severity"]),
      "lesson" => prediction_error["lesson"],
      "recommended_verification" => recommended_verification(prediction_error, contract),
      "recovery_recommendation" => recovery_recommendation(prediction_error, reconciliation),
      "created_at" => Clock.iso_now()
    }
    |> compact()
  end

  defp rejected_calibration(reason) do
    %{
      "schema_version" => @schema_version,
      "status" => "rejected",
      "reason" => reason,
      "created_at" => Clock.iso_now()
    }
  end

  defp action_contract(attrs) do
    case Map.fetch(attrs, "action_contract") do
      {:ok, contract} when is_map(contract) ->
        with :ok <- validate_action_contract(contract) do
          {:ok, contract}
        end

      {:ok, _contract} ->
        {:error, "invalid_action_contract"}

      :error ->
        {:error, "missing_action_contract"}
    end
  end

  defp validate_action_contract(contract) do
    with {:ok, _contract_id} <- required_text(contract, "contract_id", "invalid_action_contract"),
         {:ok, _action} <- required_text(contract, "action", "invalid_action_contract"),
         {:ok, _effect_scope} <-
           required_text(contract, "effect_scope", "invalid_action_contract"),
         {:ok, _target_domain} <-
           required_text(contract, "target_domain", "invalid_action_contract"),
         {:ok, _risk_level} <- required_text(contract, "risk_level", "invalid_action_contract"),
         :ok <- optional_verification(contract) do
      :ok
    end
  end

  defp optional_verification(contract) do
    case Map.fetch(contract, "verification") do
      {:ok, verification} when is_map(verification) ->
        optional_string_list(verification, "suggested_checks", "invalid_action_contract")

      {:ok, _verification} ->
        {:error, "invalid_action_contract"}

      :error ->
        :ok
    end
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
         {:ok, confidence} <- required_number(prediction, "confidence", "invalid_prediction"),
         :ok <- confidence_value(confidence) do
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
           required_text(observation, "observation_id", "invalid_observation") do
      :ok
    end
  end

  defp prediction_error(attrs) do
    case Map.fetch(attrs, "prediction_error") do
      {:ok, error} when is_map(error) ->
        with :ok <- validate_prediction_error(error) do
          {:ok, error}
        end

      {:ok, _error} ->
        {:error, "invalid_prediction_error"}

      :error ->
        {:error, "missing_prediction_error"}
    end
  end

  defp validate_prediction_error(error) do
    with {:ok, _matched?} <- required_boolean(error, "matched", "invalid_prediction_error"),
         {:ok, severity} <- required_text(error, "severity", "invalid_prediction_error"),
         :ok <- severity_value(severity),
         {:ok, _expected} <-
           required_text(error, "expected_result_status", "invalid_prediction_error"),
         {:ok, _actual} <-
           required_text(error, "actual_result_status", "invalid_prediction_error"),
         {:ok, _lesson} <- required_text(error, "lesson", "invalid_prediction_error") do
      :ok
    end
  end

  defp state_reconciliation(attrs) do
    case Map.fetch(attrs, "state_reconciliation") do
      {:ok, reconciliation} when is_map(reconciliation) ->
        with :ok <- validate_state_reconciliation(reconciliation) do
          {:ok, reconciliation}
        end

      {:ok, _reconciliation} ->
        {:error, "invalid_state_reconciliation"}

      :error ->
        {:error, "missing_state_reconciliation"}
    end
  end

  defp validate_state_reconciliation(reconciliation) do
    with {:ok, _reconciliation_id} <-
           required_text(reconciliation, "reconciliation_id", "invalid_state_reconciliation"),
         {:ok, _matched?} <-
           required_boolean(reconciliation, "matched", "invalid_state_reconciliation"),
         {:ok, _accuracy} <-
           required_number(reconciliation, "state_delta_accuracy", "invalid_state_reconciliation"),
         {:ok, _directive} <-
           required_text(reconciliation, "repair_directive", "invalid_state_reconciliation") do
      :ok
    end
  end

  defp matched?(%{"matched" => true}, %{"matched" => true}), do: true
  defp matched?(_prediction_error, _reconciliation), do: false

  defp prediction_accuracy(true), do: 1.0
  defp prediction_accuracy(false), do: 0.0

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

  defp recommended_verification(%{"matched" => true}, contract) do
    case get_in(contract, ["verification", "suggested_checks"]) do
      values when is_list(values) -> values
      _missing -> []
    end
  end

  defp recommended_verification(%{"actual_result_status" => "error"}, _contract) do
    ["check_preconditions", "capture_error_evidence", "retry_only_with_revised_plan"]
  end

  defp recommended_verification(_prediction_error, _contract),
    do: ["add_observation_specific_check"]

  defp recovery_recommendation(%{"matched" => true}, %{"repair_directive" => "continue"}),
    do: "none"

  defp recovery_recommendation(%{"matched" => true}, %{"repair_directive" => directive}),
    do: directive

  defp recovery_recommendation(_prediction_error, %{"repair_directive" => "continue"}),
    do: "enter_repair_phase_with_new_prediction"

  defp recovery_recommendation(_prediction_error, %{"repair_directive" => directive}),
    do: directive

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

  defp required_number(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, value} when is_integer(value) -> {:ok, value * 1.0}
      {:ok, value} when is_float(value) -> {:ok, value}
      {:ok, _value} -> {:error, reason}
      :error -> {:error, reason}
    end
  end

  defp required_boolean(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, value} when is_boolean(value) -> {:ok, value}
      {:ok, _value} -> {:error, reason}
      :error -> {:error, reason}
    end
  end

  defp optional_string_list(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, values} when is_list(values) ->
        validate_string_list(values, reason)

      {:ok, _values} ->
        {:error, reason}

      :error ->
        :ok
    end
  end

  defp validate_string_list(values, reason) do
    case Enum.all?(values, &is_binary/1) do
      true -> :ok
      false -> {:error, reason}
    end
  end

  defp confidence_value(value) when value >= 0.0 and value <= 1.0, do: :ok
  defp confidence_value(_value), do: {:error, "invalid_prediction"}

  defp severity_value("none"), do: :ok
  defp severity_value("low"), do: :ok
  defp severity_value("medium"), do: :ok
  defp severity_value("high"), do: :ok
  defp severity_value("critical"), do: :ok
  defp severity_value(_severity), do: {:error, "invalid_prediction_error"}

  defp numeric_confidence(value) when is_integer(value), do: value * 1.0
  defp numeric_confidence(value) when is_float(value), do: value

  defp compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end

  defp stable_id(prefix, parts) do
    digest =
      :crypto.hash(:sha256, :erlang.term_to_binary(parts))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 24)

    "#{prefix}_#{digest}"
  end
end
