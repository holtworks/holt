defmodule Holt.Actions.ProviderAdapter do
  @moduledoc """
  Provider-protocol adapter for action calls.

  Holt runtime events and execution records use action vocabulary. OpenAI-style
  providers still require action-call message keys, so this module keeps those
  names at the provider boundary.
  """

  def openai_action_definitions(actions) when is_list(actions) do
    Enum.map(actions, &openai_action/1)
  end

  def openai_action_definitions(_actions), do: []

  def openai_action(action) when is_map(action) do
    %{
      type: "function",
      function: %{
        name: action["name"],
        description: description(action),
        parameters: action_schema(action)
      }
    }
  end

  def normalize_calls(calls) when is_list(calls) do
    calls
    |> Enum.filter(&canonical_value?/1)
    |> Enum.filter(&(action_name(&1) not in [nil, ""]))
  end

  def normalize_calls(_calls), do: []

  def action_name(call) when is_map(call), do: get_in(call, ["function", "name"])
  def action_name(_call), do: nil

  def call_id(call) when is_map(call), do: call["id"]
  def call_id(_call), do: nil

  def arguments(call) when is_map(call) do
    call
    |> get_in(["function", "arguments"])
    |> decode_arguments()
  end

  def arguments(_call), do: %{}

  def assistant_message(content, calls, response) do
    %{
      "role" => "assistant",
      "content" => content,
      "tool_calls" => calls
    }
    |> maybe_put("reasoning", response["reasoning"])
    |> maybe_put("reasoning_details", response["reasoning_details"])
    |> reject_empty()
  end

  def result_message(call, execution) do
    %{
      "role" => "action",
      "tool_call_id" => call_id(call),
      "name" => action_name(call),
      "content" => Jason.encode!(execution)
    }
    |> reject_empty()
  end

  def call_event(call) do
    %{
      "id" => call_id(call),
      "action" => action_name(call),
      "arguments_preview" => call |> arguments() |> redact_arguments()
    }
    |> reject_empty()
  end

  def decode_arguments(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> canonical_arguments(decoded)
      _other -> %{}
    end
  end

  def decode_arguments(value) when is_map(value), do: canonical_arguments(value)
  def decode_arguments(_value), do: %{}

  defp action_schema(%{"input_schema" => schema}) when is_map(schema), do: schema
  defp action_schema(_action), do: empty_object_schema()

  defp canonical_arguments(args) do
    if canonical_value?(args) do
      args
    else
      %{}
    end
  end

  defp canonical_value?(value) when is_map(value) do
    Enum.all?(value, fn
      {key, nested} when is_binary(key) -> canonical_value?(nested)
      {_key, _nested} -> false
    end)
  end

  defp canonical_value?(value) when is_list(value), do: Enum.all?(value, &canonical_value?/1)
  defp canonical_value?(_value), do: true

  defp description(action) do
    [
      action["description"],
      "effect_scope=#{action["effect_scope"]}",
      "requires_approval=#{action["requires_approval"] == true}"
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  defp empty_object_schema, do: %{"type" => "object", "properties" => %{}}

  defp redact_arguments(args) when is_map(args) do
    args
    |> Enum.map(fn
      {"content", content} -> {"content_preview", content |> to_string() |> String.slice(0, 120)}
      {"text", text} -> {"text_preview", text |> to_string() |> String.slice(0, 120)}
      pair -> pair
    end)
    |> Map.new()
  end

  defp redact_arguments(_args), do: %{}

  defp reject_empty(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end

  defp maybe_put(map, _key, value) when value in [nil, "", [], %{}], do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
