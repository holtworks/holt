defmodule Holt.Tasks.ExecutionObservation do
  @moduledoc """
  Structured observation captured after a task action returns.
  """

  alias Holt.Clock

  @schema_version "holt_execution_observation/v1"

  def from_result(attrs \\ %{})

  def from_result(attrs) when is_map(attrs) do
    case input(attrs) do
      {:ok, input} -> from_canonical(input)
      {:error, reason} -> rejected_observation(attrs, reason)
    end
  end

  def from_result(_attrs), do: rejected_observation(%{}, "invalid_attrs")

  def result_status({:ok, _result}), do: "ok"
  def result_status({:ok_final, _result}), do: "ok_final"
  def result_status({:await_process, _result}), do: "await_process"
  def result_status({:await_user, _result}), do: "await_user"
  def result_status({:await_approval, _result}), do: "await_approval"
  def result_status({:error, _reason}), do: "error"
  def result_status(%{"status" => status}) when is_binary(status), do: status
  def result_status(status) when is_binary(status), do: status
  def result_status(_result), do: "unknown"

  defp input(attrs) do
    with :ok <- canonical_attrs(attrs),
         :ok <- unsupported_arguments(attrs),
         {:ok, contract} <- action_contract(attrs),
         {:ok, prediction} <- prediction(attrs),
         {:ok, transition} <- state_transition(attrs),
         {:ok, result} <- optional_result(attrs),
         {:ok, status} <- status(attrs, result),
         {:ok, latency_ms} <-
           optional_nonnegative_integer(attrs, "latency_ms", "invalid_latency_ms"),
         {:ok, observed_changes} <- optional_change_list(attrs, "observed_state_changes"),
         {:ok, after_snapshot} <-
           optional_map_value(attrs, "after_state_snapshot", "invalid_after_state_snapshot") do
      {:ok,
       %{
         action_contract: contract,
         prediction: prediction,
         state_transition_prediction: transition,
         result: result,
         status: status,
         latency_ms: latency_ms,
         observed_state_changes: observed_changes,
         after_state_snapshot: after_snapshot
       }}
    end
  end

  defp from_canonical(input) do
    contract = input.action_contract
    prediction = input.prediction
    transition = input.state_transition_prediction
    status = input.status
    changes = observed_state_changes(input.observed_state_changes, transition, status)

    %{
      "schema_version" => @schema_version,
      "observation_id" =>
        stable_id("observation", [
          contract["contract_id"],
          prediction["prediction_id"],
          status
        ]),
      "contract_id" => contract["contract_id"],
      "prediction_id" => prediction["prediction_id"],
      "action" => contract["action"],
      "status" => status,
      "latency_ms" => input.latency_ms,
      "actual_delta" => actual_delta(contract, status, changes),
      "observed_state_changes" => changes,
      "state_transition_id" => transition["transition_id"],
      "after_state_snapshot" => input.after_state_snapshot,
      "result_preview" => result_preview(input.result),
      "observed_at" => Clock.iso_now()
    }
    |> compact()
  end

  defp rejected_observation(attrs, reason) do
    %{
      "schema_version" => @schema_version,
      "observation_id" =>
        output_text(
          attrs,
          "observation_id",
          stable_id("observation", [reason, attrs])
        ),
      "status" => "rejected",
      "reason" => reason,
      "observed_at" => Clock.iso_now()
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
         :ok <- optional_text_field(contract, "effect_scope", "invalid_action_contract") do
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
    with {:ok, _prediction_id} <- required_text(prediction, "prediction_id", "invalid_prediction") do
      :ok
    end
  end

  defp state_transition(attrs) do
    case Map.fetch(attrs, "state_transition_prediction") do
      {:ok, transition} when is_map(transition) ->
        with :ok <- validate_state_transition(transition) do
          {:ok, transition}
        end

      {:ok, _transition} ->
        {:error, "invalid_state_transition_prediction"}

      :error ->
        {:error, "missing_state_transition_prediction"}
    end
  end

  defp validate_state_transition(transition) do
    with {:ok, _transition_id} <-
           required_text(transition, "transition_id", "invalid_state_transition_prediction"),
         :ok <-
           optional_change_list_field(
             transition,
             "expected_changes",
             "invalid_state_transition_prediction"
           ) do
      :ok
    end
  end

  defp optional_result(attrs) do
    case Map.fetch(attrs, "result") do
      {:ok, result} -> {:ok, result}
      :error -> {:ok, nil}
    end
  end

  defp status(attrs, result) do
    case Map.fetch(attrs, "result_status") do
      {:ok, value} when is_binary(value) ->
        status_from_binary(value)

      {:ok, _value} ->
        {:error, "invalid_result_status"}

      :error ->
        status_from_result(result)
    end
  end

  defp status_from_result(nil), do: {:error, "missing_result_status"}

  defp status_from_result(result) do
    case result_status(result) do
      "unknown" -> {:error, "invalid_result_status"}
      status -> {:ok, status}
    end
  end

  defp status_from_binary(value) do
    case String.trim(value) do
      "" -> {:error, "invalid_result_status"}
      status -> {:ok, status}
    end
  end

  defp actual_delta(contract, status, changes) do
    %{
      "scope" => contract["effect_scope"],
      "summary" => "action_returned_" <> status,
      "state_changes" => changes
    }
    |> compact()
  end

  defp observed_state_changes([], transition, status), do: synthesize_changes(transition, status)
  defp observed_state_changes(changes, _transition, _status), do: changes

  defp synthesize_changes(transition, status)
       when status in ["ok", "ok_final", "await_process"] do
    transition
    |> list_value("expected_changes")
    |> Enum.map(&Map.put(&1, "observation_status", "observed"))
  end

  defp synthesize_changes(_transition, _status), do: []

  defp result_preview({:ok, result}), do: preview(result)
  defp result_preview({:ok_final, result}), do: preview(result)
  defp result_preview({:await_process, result}), do: preview(result)
  defp result_preview({:error, reason}), do: preview(reason)

  defp result_preview(%{"preview" => preview}) when is_binary(preview),
    do: String.slice(preview, 0, 500)

  defp result_preview(nil), do: nil
  defp result_preview(result), do: preview(result)

  defp preview(value) when is_binary(value), do: String.slice(value, 0, 500)
  defp preview(value) when is_map(value), do: value |> Map.keys() |> Enum.take(20) |> inspect()
  defp preview(value), do: inspect(value) |> String.slice(0, 500)

  defp list_value(map, key) do
    case Map.fetch(map, key) do
      {:ok, values} when is_list(values) -> values
      _missing -> []
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

  defp unsupported_arguments(attrs) do
    cond do
      Map.has_key?(attrs, "contract") -> {:error, "unsupported_argument:contract"}
      Map.has_key?(attrs, "status") -> {:error, "unsupported_argument:status"}
      Map.has_key?(attrs, "state_changes") -> {:error, "unsupported_argument:state_changes"}
      true -> :ok
    end
  end

  defp optional_map_value(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _value} -> {:error, reason}
      :error -> {:ok, nil}
    end
  end

  defp optional_change_list(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, values} when is_list(values) ->
        validate_change_list(values, "invalid_" <> key)

      {:ok, _values} ->
        {:error, "invalid_" <> key}

      :error ->
        {:ok, []}
    end
  end

  defp optional_change_list_field(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, values} when is_list(values) ->
        case validate_change_list(values, reason) do
          {:ok, _values} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:ok, _values} ->
        {:error, reason}

      :error ->
        :ok
    end
  end

  defp validate_change_list(values, reason) do
    case Enum.all?(values, &valid_change?/1) do
      true -> {:ok, values}
      false -> {:error, reason}
    end
  end

  defp valid_change?(change) when is_map(change), do: canonical_value?(change)
  defp valid_change?(_change), do: false

  defp optional_nonnegative_integer(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, value} when is_integer(value) and value >= 0 -> {:ok, value}
      {:ok, _value} -> {:error, reason}
      :error -> {:ok, nil}
    end
  end

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

  defp output_text(map, key, default) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) ->
        case String.trim(value) do
          "" -> default
          text -> text
        end

      _missing ->
        default
    end
  end

  defp output_text(_map, _key, default), do: default

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
