defmodule Holt.Actions.Execution do
  @moduledoc """
  Builds the transport-neutral result envelope for local action execution.

  Dispatchers return domain results. This module owns the stable execution
  shape persisted in run history and sent over provider bridges.
  """

  alias Holt.Clock
  alias Holt.Tasks.ActionContract

  @schema_version "holt_action_execution/v1"

  def completed(action, args, route, result) do
    base(action, args, route)
    |> Map.put("status", "ok")
    |> Map.put("result", result)
  end

  def rejected(action, args, route) do
    base(action, args, route)
    |> Map.put("status", "rejected")
    |> Map.put("reason", route["reason"])
  end

  def failed(
        action,
        args,
        route,
        {:missing_required_arguments, missing_arguments, required_arguments, received_arguments}
      ) do
    base(action, args, route)
    |> Map.put("status", "error")
    |> Map.put("reason", "missing_required_arguments")
    |> Map.put("missing_arguments", missing_arguments)
    |> Map.put("required_arguments", required_arguments)
    |> Map.put("received_arguments", received_arguments)
    |> Map.put("retryable", true)
  end

  def failed(action, args, route, reason) do
    base(action, args, route)
    |> Map.put("status", "error")
    |> Map.put("reason", normalize_reason(reason))
  end

  def failed_batch(executions) do
    %{
      "schema_version" => @schema_version,
      "execution_id" => Clock.id("action_execution"),
      "action" => "multi_execute_action",
      "status" => "error",
      "reason" => "batch_stopped",
      "executions" => executions,
      "created_at" => Clock.iso_now()
    }
  end

  defp base(action, args, route) do
    action_contract = route_value(route, "action_contract")

    %{
      "schema_version" => @schema_version,
      "execution_id" => Clock.id("action_execution"),
      "action" => action,
      "action_call_id" => route_value(route, "action_call_id"),
      "route" => route,
      "action_contract" => action_contract,
      "arguments_preview" => arguments_preview(action, args, action_contract),
      "created_at" => Clock.iso_now()
    }
    |> compact()
  end

  defp arguments_preview(_action, _args, %{} = action_contract),
    do: action_contract["arguments_preview"]

  defp arguments_preview(action, args, _action_contract) when is_binary(action) do
    case ActionContract.build(%{"action" => action, "arguments" => action_args(args)}) do
      %{} = action_contract -> action_contract["arguments_preview"]
      {:error, _reason} -> nil
    end
  end

  defp arguments_preview(_action, _args, _action_contract), do: nil

  defp route_value(route, key) when is_map(route), do: Map.get(route, key)
  defp route_value(_route, _key), do: nil

  defp action_args(args) do
    case args do
      %{"arguments" => value} when is_map(value) -> value
      _args -> args
    end
  end

  defp normalize_reason(reason) when is_binary(reason), do: reason
  defp normalize_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp normalize_reason({key, value}), do: "#{normalize_reason(key)}:#{value}"
  defp normalize_reason(reason), do: inspect(reason)

  defp compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end
end
