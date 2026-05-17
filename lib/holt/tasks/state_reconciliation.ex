defmodule Holt.Tasks.StateReconciliation do
  @moduledoc """
  Reconciles predicted state transitions with observed changes.
  """

  alias Holt.Clock
  alias Holt.Tasks.RuntimeContracts

  @schema_version "holtworks_state_reconciliation/v1"

  def reconcile(attrs \\ %{})

  def reconcile(attrs) when is_map(attrs) do
    attrs = RuntimeContracts.string_keys(attrs)

    transition =
      RuntimeContracts.normalize_map(RuntimeContracts.value(attrs, "state_transition_prediction"))

    observation = RuntimeContracts.normalize_map(RuntimeContracts.value(attrs, "observation"))
    expected = normalize_changes(transition["expected_changes"])
    observed = observed_changes(attrs, observation, transition)
    missing = missing_changes(expected, observed)
    unexpected = unexpected_changes(expected, observed)
    matched? = matched?(observation, expected, missing, unexpected)

    %{
      "schema_version" => @schema_version,
      "reconciliation_id" =>
        RuntimeContracts.stable_id("state_reconciliation", [
          transition["transition_id"],
          observation["observation_id"],
          missing,
          unexpected
        ]),
      "state_transition_id" => transition["transition_id"],
      "observation_id" => observation["observation_id"],
      "tool_name" => transition["tool_name"] || observation["tool_name"],
      "effect_scope" => transition["effect_scope"],
      "target_domain" => transition["target_domain"],
      "matched" => matched?,
      "state_delta_accuracy" => state_delta_accuracy(expected, missing),
      "expected_change_count" => length(expected),
      "observed_change_count" => length(observed),
      "matched_changes" => matched_changes(expected, observed),
      "missing_changes" => missing,
      "unexpected_changes" => unexpected,
      "actual_state_delta" => actual_state_delta(observation, observed),
      "repair_directive" => repair_directive(observation, matched?, missing, unexpected),
      "reconciled_at" => Clock.iso_now()
    }
    |> RuntimeContracts.reject_empty()
  end

  def reconcile(_attrs), do: reconcile(%{})

  defp observed_changes(attrs, observation, transition) do
    explicit =
      RuntimeContracts.value(attrs, "observed_changes") ||
        observation["observed_state_changes"] ||
        RuntimeContracts.value(observation["actual_delta"] || %{}, "state_changes")

    case normalize_changes(explicit) do
      [] -> synthesize_changes(observation, transition)
      changes -> changes
    end
  end

  defp synthesize_changes(observation, transition) do
    if observation["status"] in ["ok", "ok_final", "await_process"] do
      normalize_changes(transition["expected_changes"])
    else
      []
    end
  end

  defp missing_changes(expected, observed) do
    observed_keys = MapSet.new(Enum.map(observed, &state_key/1))

    expected
    |> Enum.filter(&(&1["verification_required"] == true or &1["durable"] != false))
    |> Enum.reject(&(state_key(&1) in observed_keys))
  end

  defp unexpected_changes(expected, observed) do
    expected_keys = MapSet.new(Enum.map(expected, &state_key/1))
    Enum.reject(observed, &(state_key(&1) in expected_keys))
  end

  defp matched?(observation, expected, missing, unexpected) do
    cond do
      observation["status"] in ["error", "unknown"] and expected != [] -> false
      missing != [] -> false
      unexpected != [] -> false
      true -> true
    end
  end

  defp state_delta_accuracy([], []), do: 1.0
  defp state_delta_accuracy([], _missing), do: 0.0

  defp state_delta_accuracy(expected, missing) do
    matched = max(length(expected) - length(missing), 0)
    Float.round(matched / length(expected), 2)
  end

  defp matched_changes(expected, observed) do
    observed_keys = MapSet.new(Enum.map(observed, &state_key/1))
    Enum.filter(expected, &(state_key(&1) in observed_keys))
  end

  defp actual_state_delta(observation, observed) do
    %{
      "status" => observation["status"],
      "observed_changes" => observed,
      "result_preview" => observation["result_preview"]
    }
    |> RuntimeContracts.reject_empty()
  end

  defp repair_directive(%{"status" => "await_process"}, true, _missing, _unexpected) do
    "wait_for_async_state_observation"
  end

  defp repair_directive(_observation, true, _missing, _unexpected), do: "continue"

  defp repair_directive(%{"status" => "error"}, false, _missing, _unexpected) do
    "enter_repair_phase_with_observed_error"
  end

  defp repair_directive(_observation, false, missing, _unexpected) when missing != [] do
    "enter_repair_phase_with_missing_state_delta"
  end

  defp repair_directive(_observation, false, _missing, unexpected) when unexpected != [] do
    "verify_unexpected_state_delta_before_continuing"
  end

  defp repair_directive(_observation, false, _missing, _unexpected) do
    "enter_repair_phase_with_actual_state_delta"
  end

  defp normalize_changes(value) when is_list(value) do
    value
    |> Enum.filter(&is_map/1)
    |> Enum.map(&RuntimeContracts.string_keys/1)
    |> Enum.reject(&(&1 == %{}))
  end

  defp normalize_changes(_value), do: []

  defp state_key(change) do
    change["state_key"] || change["change_id"] ||
      [change["state_namespace"], change["target_ref"], change["code"]]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(":")
  end
end
