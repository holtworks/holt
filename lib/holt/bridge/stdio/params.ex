defmodule Holt.Bridge.Stdio.Params do
  @moduledoc """
  Parameter extraction for stdio requests.
  """

  def required(params, key) do
    case value(params, key) do
      value when value not in [nil, ""] -> {:ok, value}
      _missing -> {:error, {:missing_required, key}}
    end
  end

  def required_map(params, key) do
    case value(params, key) do
      value when is_map(value) -> {:ok, value}
      _missing -> {:error, {:missing_required, key}}
    end
  end

  def chat_messages(params) do
    case value(params, "chat_messages") do
      value when value in [nil, ""] -> {:ok, []}
      value -> Holt.Runtime.ChatMessages.decode_param(value)
    end
  end

  def reject_obsolete(params, key, replacement) do
    if is_map(params) and Map.has_key?(params, key) do
      {:error, {:obsolete_param, key, replacement}}
    else
      :ok
    end
  end

  def value(params, key) when is_map(params), do: Map.get(params, key)
  def value(_params, _key), do: nil

  def task_ref(params), do: required(params, "ref")

  def target_ref(params), do: required(params, "target_ref")

  def agent_id(params), do: required(params, "agent_id")

  def graph_node_ref(params), do: required(params, "node_ref")

  def drop_ref(params), do: Map.delete(params, "ref")
end
