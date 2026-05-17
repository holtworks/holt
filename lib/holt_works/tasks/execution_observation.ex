defmodule HoltWorks.Tasks.ExecutionObservation do
  @moduledoc """
  Structured observation captured after a tool action returns.
  """

  alias HoltWorks.Clock
  alias HoltWorks.Tasks.RuntimeContracts

  @schema_version "holtworks_execution_observation/v1"

  def from_result(attrs \\ %{})

  def from_result(attrs) when is_map(attrs) do
    attrs = RuntimeContracts.string_keys(attrs)

    contract =
      RuntimeContracts.normalize_map(
        RuntimeContracts.value(attrs, "contract") ||
          RuntimeContracts.value(attrs, "action_contract")
      )

    prediction = RuntimeContracts.normalize_map(RuntimeContracts.value(attrs, "prediction"))

    transition =
      RuntimeContracts.normalize_map(RuntimeContracts.value(attrs, "state_transition_prediction"))

    result = RuntimeContracts.value(attrs, "result")

    status =
      result_status(
        RuntimeContracts.value(attrs, "status") || RuntimeContracts.value(attrs, "result_status") ||
          result
      )

    changes = observed_state_changes(attrs, transition, status)

    %{
      "schema_version" => @schema_version,
      "observation_id" =>
        RuntimeContracts.stable_id("observation", [
          contract["contract_id"],
          prediction["prediction_id"],
          status
        ]),
      "contract_id" => contract["contract_id"],
      "prediction_id" => prediction["prediction_id"],
      "tool_name" => contract["tool_name"],
      "status" => status,
      "latency_ms" => RuntimeContracts.value(attrs, "latency_ms"),
      "actual_delta" => actual_delta(contract, status, changes),
      "observed_state_changes" => changes,
      "state_transition_id" => transition["transition_id"],
      "after_state_snapshot" => RuntimeContracts.value(attrs, "after_state_snapshot"),
      "result_preview" => result_preview(result),
      "observed_at" => Clock.iso_now()
    }
    |> RuntimeContracts.reject_empty()
  end

  def from_result(_attrs), do: from_result(%{})

  def result_status({:ok, _result}), do: "ok"
  def result_status({:ok_final, _result}), do: "ok_final"
  def result_status({:await_process, _result}), do: "await_process"
  def result_status({:await_user, _result}), do: "await_user"
  def result_status({:await_approval, _result}), do: "await_approval"
  def result_status({:error, _reason}), do: "error"
  def result_status(%{"status" => status}) when is_binary(status), do: status

  def result_status(status)
      when status in ["ok", "ok_final", "await_process", "await_user", "await_approval", "error"],
      do: status

  def result_status(_result), do: "unknown"

  defp actual_delta(contract, status, changes) do
    %{
      "scope" => contract["effect_scope"],
      "summary" => "tool_returned_" <> status,
      "state_changes" => changes
    }
    |> RuntimeContracts.reject_empty()
  end

  defp observed_state_changes(attrs, transition, status) do
    explicit =
      RuntimeContracts.value(attrs, "observed_state_changes") ||
        RuntimeContracts.value(attrs, "state_changes")

    case normalize_changes(explicit) do
      [] -> synthesize_changes(transition, status)
      changes -> changes
    end
  end

  defp synthesize_changes(transition, status)
       when status in ["ok", "ok_final", "await_process"] do
    transition
    |> Map.get("expected_changes", [])
    |> normalize_changes()
    |> Enum.map(&Map.put(&1, "observation_status", "observed"))
  end

  defp synthesize_changes(_transition, _status), do: []

  defp normalize_changes(value) when is_list(value) do
    value
    |> Enum.filter(&is_map/1)
    |> Enum.map(&RuntimeContracts.string_keys/1)
    |> Enum.reject(&(&1 == %{}))
  end

  defp normalize_changes(_value), do: []

  defp result_preview({:ok, result}), do: preview(result)
  defp result_preview({:ok_final, result}), do: preview(result)
  defp result_preview({:await_process, result}), do: preview(result)
  defp result_preview({:error, reason}), do: preview(reason)

  defp result_preview(%{"preview" => preview}) when is_binary(preview),
    do: String.slice(preview, 0, 500)

  defp result_preview(result), do: preview(result)

  defp preview(value) when is_binary(value), do: String.slice(value, 0, 500)
  defp preview(value) when is_map(value), do: value |> Map.keys() |> Enum.take(20) |> inspect()
  defp preview(value), do: inspect(value) |> String.slice(0, 500)
end
