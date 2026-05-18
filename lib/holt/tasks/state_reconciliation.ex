defmodule Holt.Tasks.StateReconciliation do
  @moduledoc """
  Reconciles predicted state transitions with observed changes.
  """

  alias Holt.Clock

  @schema_version "holt_state_reconciliation/v1"

  def reconcile(attrs \\ %{})

  def reconcile(attrs) when is_map(attrs) do
    case input(attrs) do
      {:ok, input} -> reconcile_canonical(input)
      {:error, reason} -> rejected_reconciliation(reason)
    end
  end

  def reconcile(_attrs), do: rejected_reconciliation("invalid_attrs")

  defp input(attrs) do
    with :ok <- canonical_attrs(attrs),
         :ok <- unsupported_arguments(attrs),
         {:ok, transition} <- transition(attrs),
         {:ok, observation} <- observation(attrs) do
      {:ok, %{transition: transition, observation: observation}}
    end
  end

  defp reconcile_canonical(input) do
    transition = input.transition
    observation = input.observation
    expected = transition["expected_changes"]
    observed = observed_changes(observation)
    missing = missing_changes(expected, observed)
    unexpected = unexpected_changes(expected, observed)
    matched? = matched?(observation["status"], expected, missing, unexpected)

    %{
      "schema_version" => @schema_version,
      "reconciliation_id" =>
        stable_id("state_reconciliation", [
          transition["transition_id"],
          observation["observation_id"],
          missing,
          unexpected
        ]),
      "state_transition_id" => transition["transition_id"],
      "observation_id" => observation["observation_id"],
      "action" => transition["action"],
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
      "repair_directive" =>
        repair_directive(observation["status"], matched?, missing, unexpected),
      "reconciled_at" => Clock.iso_now()
    }
    |> compact()
  end

  defp rejected_reconciliation(reason) do
    %{
      "schema_version" => @schema_version,
      "status" => "rejected",
      "reason" => reason,
      "reconciled_at" => Clock.iso_now()
    }
  end

  defp transition(attrs) do
    case Map.fetch(attrs, "state_transition_prediction") do
      {:ok, transition} when is_map(transition) ->
        with :ok <- validate_transition(transition) do
          {:ok, transition}
        end

      {:ok, _transition} ->
        {:error, "invalid_state_transition_prediction"}

      :error ->
        {:error, "missing_state_transition_prediction"}
    end
  end

  defp validate_transition(transition) do
    with {:ok, _transition_id} <-
           required_text(transition, "transition_id", "invalid_state_transition_prediction"),
         {:ok, _action} <-
           required_text(transition, "action", "invalid_state_transition_prediction"),
         {:ok, _effect_scope} <-
           required_text(transition, "effect_scope", "invalid_state_transition_prediction"),
         {:ok, _target_domain} <-
           required_text(transition, "target_domain", "invalid_state_transition_prediction"),
         {:ok, expected_changes} <-
           required_change_list(
             transition,
             "expected_changes",
             "invalid_state_transition_prediction"
           ),
         :ok <- validate_expected_changes(expected_changes) do
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
         :ok <- observation_status(status),
         {:ok, observed_changes} <-
           optional_change_list(observation, "observed_state_changes", "invalid_observation"),
         :ok <- validate_observed_changes(observed_changes),
         :ok <- optional_text_field(observation, "result_preview", "invalid_observation") do
      :ok
    end
  end

  defp unsupported_arguments(attrs) do
    attrs
    |> Map.keys()
    |> Enum.find(&unsupported_key?/1)
    |> unsupported_key_error()
  end

  defp unsupported_key?("state_transition_prediction"), do: false
  defp unsupported_key?("observation"), do: false
  defp unsupported_key?(_key), do: true

  defp unsupported_key_error(nil), do: :ok
  defp unsupported_key_error(key), do: {:error, "unsupported_argument:" <> key}

  defp validate_expected_changes(changes) do
    validate_changes(changes, &expected_change?/1, "invalid_state_transition_prediction")
  end

  defp validate_observed_changes(changes) do
    validate_changes(changes, &observed_change?/1, "invalid_observation")
  end

  defp validate_changes(changes, check, reason) do
    case Enum.all?(changes, check) do
      true -> :ok
      false -> {:error, reason}
    end
  end

  defp expected_change?(change) do
    with {:ok, _state_key} <- required_text(change, "state_key", :invalid_change),
         {:ok, _required?} <- required_boolean(change, "verification_required", :invalid_change),
         :ok <- optional_boolean(change, "durable", :invalid_change) do
      true
    else
      _error -> false
    end
  end

  defp observed_change?(change) do
    with {:ok, _state_key} <- required_text(change, "state_key", :invalid_change),
         :ok <- optional_boolean(change, "durable", :invalid_change) do
      true
    else
      _error -> false
    end
  end

  defp observed_changes(observation) do
    case Map.fetch(observation, "observed_state_changes") do
      {:ok, changes} -> changes
      :error -> []
    end
  end

  defp missing_changes(expected, observed) do
    observed_keys = MapSet.new(Enum.map(observed, &state_key/1))

    expected
    |> Enum.filter(&required_observation?/1)
    |> Enum.reject(&(state_key(&1) in observed_keys))
  end

  defp unexpected_changes(expected, observed) do
    expected_keys = MapSet.new(Enum.map(expected, &state_key/1))
    Enum.reject(observed, &(state_key(&1) in expected_keys))
  end

  defp matched?("error", [], [], []), do: true
  defp matched?("error", _expected, _missing, _unexpected), do: false
  defp matched?("rejected", [], [], []), do: true
  defp matched?("rejected", _expected, _missing, _unexpected), do: false
  defp matched?(_status, _expected, [], []), do: true
  defp matched?(_status, _expected, _missing, _unexpected), do: false

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
    |> compact()
  end

  defp repair_directive("await_process", true, _missing, _unexpected) do
    "wait_for_async_state_observation"
  end

  defp repair_directive(_status, true, _missing, _unexpected), do: "continue"

  defp repair_directive("error", false, _missing, _unexpected) do
    "enter_repair_phase_with_observed_error"
  end

  defp repair_directive(_status, false, missing, _unexpected) when missing != [] do
    "enter_repair_phase_with_missing_state_delta"
  end

  defp repair_directive(_status, false, _missing, unexpected) when unexpected != [] do
    "verify_unexpected_state_delta_before_continuing"
  end

  defp repair_directive(_status, false, _missing, _unexpected) do
    "enter_repair_phase_with_actual_state_delta"
  end

  defp state_key(change), do: change["state_key"]
  defp required_observation?(%{"verification_required" => true}), do: true
  defp required_observation?(_change), do: false

  defp observation_status("ok"), do: :ok
  defp observation_status("ok_final"), do: :ok
  defp observation_status("await_process"), do: :ok
  defp observation_status("await_user"), do: :ok
  defp observation_status("await_approval"), do: :ok
  defp observation_status("error"), do: :ok
  defp observation_status("rejected"), do: :ok
  defp observation_status(_status), do: {:error, "invalid_observation"}

  defp required_change_list(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, values} when is_list(values) -> {:ok, values}
      {:ok, _values} -> {:error, reason}
      :error -> {:error, reason}
    end
  end

  defp optional_change_list(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, values} when is_list(values) -> {:ok, values}
      {:ok, _values} -> {:error, reason}
      :error -> {:ok, []}
    end
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

  defp optional_text_field(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, reason}
          _text -> :ok
        end

      {:ok, _value} ->
        {:error, reason}

      :error ->
        :ok
    end
  end

  defp required_boolean(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, value} when is_boolean(value) -> {:ok, value}
      {:ok, _value} -> {:error, reason}
      :error -> {:error, reason}
    end
  end

  defp optional_boolean(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, value} when is_boolean(value) -> :ok
      {:ok, _value} -> {:error, reason}
      :error -> :ok
    end
  end

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
