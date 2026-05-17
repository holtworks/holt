defmodule HoltWorks.Tasks.OutputSanitizer do
  @moduledoc false

  @content_keys ~w(content text summary result final message output)
  @failure_keys ~w(error_message error reason)
  @internal_payload_keys ~w(
    command prompt messages mcp_server credential role_system_prompt agent_message system_prompt
  )
  @max_reason_length 500
  @internal_payload_message "Local model returned an internal runner payload instead of a user-facing final response."
  @empty_result_message "Local model completed without a user-facing final response."

  def format_local_model_result(result) when is_map(result) do
    result = stringify_keys(result)

    cond do
      content = public_content(result) ->
        redact_internal_payload_text(content)

      internal_payload?(result) ->
        internal_payload_summary(result)

      true ->
        @empty_result_message
    end
  end

  def format_local_model_result(result) when is_binary(result) do
    result
    |> sanitize_text()
    |> redact_internal_payload_text()
  end

  def format_local_model_result(result) do
    result
    |> inspect()
    |> sanitize_text()
    |> redact_internal_payload_text()
  end

  def redact_internal_payload_text(text) when is_binary(text) do
    clean = sanitize_text(text)

    case Jason.decode(String.trim(clean)) do
      {:ok, decoded} ->
        decoded = normalize_value(decoded)

        if internal_payload?(decoded) do
          internal_payload_summary(decoded)
        else
          clean
        end

      _error ->
        clean
    end
  end

  def redact_internal_payload_text(value), do: format_local_model_result(value)

  defp public_content(map) when is_map(map) do
    Enum.find_value(@content_keys, fn key ->
      map
      |> Map.get(key)
      |> public_content_value()
    end)
  end

  defp public_content(_value), do: nil

  defp public_content_value(value) when is_binary(value) do
    text = String.trim(value)
    if text == "", do: nil, else: value
  end

  defp public_content_value(value) when is_map(value), do: public_content(value)
  defp public_content_value(_value), do: nil

  defp internal_payload_summary(value) do
    case failure_reason(value) do
      nil -> @internal_payload_message
      reason -> "Local model failed: #{reason}"
    end
  end

  defp failure_reason(map) when is_map(map) do
    Enum.find_value(@failure_keys, fn key ->
      case Map.get(map, key) do
        value when is_binary(value) ->
          value
          |> sanitize_text()
          |> String.trim()
          |> case do
            "" -> nil
            reason -> String.slice(reason, 0, @max_reason_length)
          end

        _value ->
          nil
      end
    end)
  end

  defp failure_reason(_value), do: nil

  defp internal_payload?(value), do: internal_payload?(value, 0)

  defp internal_payload?(_value, depth) when depth > 4, do: false

  defp internal_payload?(map, depth) when is_map(map) do
    has_any_key?(map, @internal_payload_keys) or
      Enum.any?(Map.values(map), &internal_payload?(&1, depth + 1))
  end

  defp internal_payload?(list, depth) when is_list(list) do
    Enum.any?(list, &internal_payload?(&1, depth + 1))
  end

  defp internal_payload?(_value, _depth), do: false

  defp has_any_key?(map, keys) do
    Enum.any?(keys, &Map.has_key?(map, &1))
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), normalize_value(value)} end)
  end

  defp stringify_keys(_value), do: %{}

  defp normalize_value(value) when is_map(value), do: stringify_keys(value)
  defp normalize_value(value) when is_list(value), do: Enum.map(value, &normalize_value/1)
  defp normalize_value(value), do: value

  defp sanitize_text(text) when is_binary(text) do
    if String.valid?(text), do: text, else: inspect(text)
  end
end
