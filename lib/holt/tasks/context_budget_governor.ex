defmodule Holt.Tasks.ContextBudgetGovernor do
  @moduledoc """
  Provider-neutral context budget planning for long-running task agents.

  The governor estimates whether the next model request can be sent as-is,
  should snapshot soon, or must compact before retrying. It does not decide task
  lifecycle state; callers use the structured `action` and `budget_state`
  fields as policy input.
  """

  alias Holt.Clock

  @schema_version "holt_context_budget_governor/v1"
  @default_context_window 128_000
  @default_output_reserve 8_192
  @default_action_reserve 24_000
  @soft_ratio 0.75
  @critical_ratio 0.9

  def plan(attrs \\ %{})

  def plan(attrs) when is_map(attrs) do
    with :ok <- canonical_attrs(attrs),
         {:ok, provider_profile} <- map_field(attrs, "provider_profile"),
         {:ok, messages} <- list_field(attrs, "messages"),
         {:ok, actions} <- list_field(attrs, "actions"),
         {:ok, provider} <- optional_text_field(provider_profile, "provider"),
         {:ok, model} <- optional_text_field(provider_profile, "model"),
         {:ok, context_window} <- context_window(provider_profile),
         {:ok, output_reserve} <- output_reserve(attrs, context_window),
         {:ok, action_reserve} <- action_reserve(attrs, context_window),
         {:ok, hard_limit} <- hard_limit(attrs, context_window, output_reserve),
         {:ok, soft_limit} <- soft_limit(attrs, context_window),
         {:ok, critical_limit} <- critical_limit(attrs, context_window),
         {:ok, input_tokens} <- input_tokens(attrs, messages, actions) do
      available_tokens = max(hard_limit - input_tokens - action_reserve, 0)

      %{
        "schema_version" => @schema_version,
        "provider" => provider,
        "model" => model,
        "context_window" => context_window,
        "hard_limit_tokens" => hard_limit,
        "soft_limit_tokens" => soft_limit,
        "critical_limit_tokens" => critical_limit,
        "output_reserve_tokens" => output_reserve,
        "action_reserve_tokens" => action_reserve,
        "estimated_input_tokens" => input_tokens,
        "available_tokens" => available_tokens,
        "budget_state" => budget_state(input_tokens, soft_limit, critical_limit, hard_limit),
        "action" => action(input_tokens, soft_limit, critical_limit, hard_limit),
        "compression" =>
          compression_contract(input_tokens, soft_limit, critical_limit, hard_limit),
        "provider_features" => provider_features(provider),
        "updated_at" => Clock.iso_now()
      }
      |> reject_empty()
    else
      {:error, reason} -> rejected_plan(reason)
    end
  end

  def plan(_attrs), do: rejected_plan("invalid_attrs")

  def estimate_messages_tokens(messages) when is_list(messages) do
    messages
    |> encode_size()
    |> estimate_tokens_from_bytes()
  end

  def estimate_messages_tokens(_messages), do: 0

  def estimate_actions_tokens(actions) when is_list(actions) do
    actions
    |> encode_size()
    |> estimate_tokens_from_bytes()
  end

  def estimate_actions_tokens(_actions), do: 0

  def compact_messages(messages, plan) when is_list(messages) and is_map(plan) do
    case value(plan, "action") do
      "send" -> messages
      _action -> compact_messages_to_budget(messages, plan)
    end
  end

  def compact_messages(messages, _plan), do: messages

  def overflow_error(status, body) do
    %{
      "schema_version" => "holt_context_overflow_error/v1",
      "failure_class" => "context_budget_exceeded",
      "blocker_code" => "compression_required",
      "retryable" => true,
      "http_status" => status,
      "provider_message" => provider_message(body),
      "raw_error_preview" => body |> to_text() |> String.slice(0, 1_000)
    }
    |> reject_empty()
  end

  defp rejected_plan(reason) do
    %{
      "schema_version" => @schema_version,
      "status" => "rejected",
      "reason" => reason
    }
  end

  defp context_window(provider_profile) do
    optional_positive_integer(provider_profile, "context_window", @default_context_window)
  end

  defp output_reserve(attrs, context_window) do
    optional_positive_integer(
      attrs,
      "output_reserve_tokens",
      min(@default_output_reserve, max(div(context_window, 20), 1_024))
    )
  end

  defp action_reserve(attrs, context_window) do
    optional_positive_integer(
      attrs,
      "action_reserve_tokens",
      min(@default_action_reserve, max(div(context_window, 10), 2_048))
    )
  end

  defp hard_limit(attrs, context_window, output_reserve) do
    optional_positive_integer(
      attrs,
      "hard_limit_tokens",
      max(context_window - output_reserve, 1_024)
    )
  end

  defp soft_limit(attrs, context_window) do
    optional_positive_integer(attrs, "soft_limit_tokens", floor(context_window * @soft_ratio))
  end

  defp critical_limit(attrs, context_window) do
    optional_positive_integer(
      attrs,
      "critical_limit_tokens",
      floor(context_window * @critical_ratio)
    )
  end

  defp input_tokens(attrs, messages, actions) do
    case optional_nonnegative_integer(attrs, "estimated_input_tokens") do
      {:ok, value} -> {:ok, value}
      :missing -> {:ok, estimate_messages_tokens(messages) + estimate_actions_tokens(actions)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp compact_messages_to_budget([system | rest], plan) do
    target_tokens =
      case positive_integer_field(plan, "soft_limit_tokens") do
        {:ok, value} ->
          value

        :error ->
          case positive_integer_field(plan, "hard_limit_tokens") do
            {:ok, value} -> value
            :error -> @default_context_window
          end
      end

    recent_count = 8
    {old_messages, recent_messages} = Enum.split(rest, max(length(rest) - recent_count, 0))

    compacted_old =
      old_messages
      |> Enum.map(&compact_message/1)
      |> collapse_compacted_tail(target_tokens, system, recent_messages)

    compacted = [system | compacted_old ++ recent_messages]

    if estimate_messages_tokens(compacted) > target_tokens do
      [system | Enum.map(rest, &compact_message/1)]
    else
      compacted
    end
  end

  defp compact_messages_to_budget(messages, _plan), do: messages

  defp collapse_compacted_tail(messages, target_tokens, system, recent_messages) do
    projected = [system | messages ++ recent_messages]

    if estimate_messages_tokens(projected) <= target_tokens do
      messages
    else
      [
        %{
          "role" => "system",
          "content" =>
            "Older turn details were compacted by the context budget governor. " <>
              "Use task memory artifact refs or task actions to dereference exact evidence."
        }
      ]
    end
  end

  defp compact_message(%{"role" => "action", "content" => content} = message)
       when is_binary(content) do
    Map.put(message, "content", bounded_text(content, 1_200))
  end

  defp compact_message(%{"role" => "assistant", "action_calls" => action_calls} = message)
       when is_list(action_calls) do
    Map.put(message, "action_calls", Enum.map(action_calls, &compact_action_call/1))
  end

  defp compact_message(message), do: message

  defp compact_action_call(action_call) when is_map(action_call) do
    case value(action_call, "function") do
      function when is_map(function) ->
        compact_function_arguments(action_call, function)

      _value ->
        action_call
    end
  end

  defp compact_action_call(action_call), do: action_call

  defp compact_function_arguments(action_call, function) do
    arguments = value(function, "arguments")

    if is_binary(arguments) and byte_size(arguments) > 1_200 do
      name = action_name(function)

      put_in_action_arguments(
        action_call,
        ~s({"_compacted":"#{name} arguments stored in artifacts"})
      )
    else
      action_call
    end
  end

  defp put_in_action_arguments(%{"function" => function} = action_call, replacement)
       when is_map(function) do
    Map.put(action_call, "function", Map.put(function, "arguments", replacement))
  end

  defp put_in_action_arguments(action_call, _replacement), do: action_call

  defp bounded_text(text, max_chars) do
    if String.length(text) <= max_chars do
      text
    else
      prefix = String.slice(text, 0, max_chars)
      suffix = String.slice(text, -400, 400)

      prefix <>
        "\n...[context_budget_compacted #{byte_size(text)} bytes; middle omitted]...\n" <> suffix
    end
  end

  defp compression_contract(input_tokens, soft_limit, critical_limit, hard_limit) do
    %{
      "trigger_threshold_tokens" => soft_limit,
      "critical_threshold_tokens" => critical_limit,
      "hard_limit_tokens" => hard_limit,
      "lossiness" => if(input_tokens >= critical_limit, do: "bounded_lossy", else: "none"),
      "durable_truth" => "file_backed_task_memory",
      "requires_artifact_refs" => true,
      "retry_blocker_code" => "compression_required"
    }
  end

  defp provider_features(provider) do
    %{
      "openai_server_compaction" => provider == "openai",
      "anthropic_context_management" => provider == "anthropic",
      "action_result_clearing" => provider in ["anthropic", "openai"],
      "provider_neutral_compaction" => true
    }
  end

  defp budget_state(input_tokens, soft_limit, critical_limit, hard_limit) do
    cond do
      input_tokens >= hard_limit -> "overflow"
      input_tokens >= critical_limit -> "critical"
      input_tokens >= soft_limit -> "soft_limit"
      true -> "within_budget"
    end
  end

  defp action(input_tokens, soft_limit, critical_limit, hard_limit) do
    cond do
      input_tokens >= hard_limit -> "reject_and_compact"
      input_tokens >= critical_limit -> "compact_before_send"
      input_tokens >= soft_limit -> "snapshot_soon"
      true -> "send"
    end
  end

  defp provider_message(body) when is_map(body) do
    case get_in(body, ["error", "message"]) do
      message when is_binary(message) -> message
      _value -> to_text(body)
    end
  end

  defp provider_message(body), do: to_text(body)

  defp estimate_tokens_from_bytes(bytes), do: div(bytes + 3, 4)

  defp encode_size(value) do
    value
    |> Jason.encode!()
    |> byte_size()
  rescue
    _reason -> 0
  end

  defp positive_integer_field(map, key) do
    case fetch_field(map, key) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _value -> :error
    end
  end

  defp optional_positive_integer(map, key, default) do
    case Map.fetch(map, key) do
      {:ok, value} when is_integer(value) and value > 0 -> {:ok, value}
      {:ok, _value} -> {:error, "invalid_field:#{key}"}
      :error -> {:ok, default}
    end
  end

  defp optional_nonnegative_integer(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_integer(value) and value >= 0 -> {:ok, value}
      {:ok, _value} -> {:error, "invalid_field:#{key}"}
      :error -> :missing
    end
  end

  defp to_text(value) when is_binary(value), do: value

  defp to_text(value) do
    case Jason.encode(value) do
      {:ok, text} -> text
      _error -> inspect(value)
    end
  end

  defp list_field(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_list(value) -> {:ok, value}
      {:ok, _value} -> {:error, "invalid_field:#{key}"}
      :error -> {:ok, []}
    end
  end

  defp map_field(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_map(value) -> canonical_nested_map(key, value)
      {:ok, _value} -> {:error, "invalid_field:#{key}"}
      :error -> {:ok, %{}}
    end
  end

  defp optional_text_field(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> text_field(map_with_field(key, value), key)
      :error -> {:ok, nil}
    end
  end

  defp text_field(map, key) do
    case fetch_field(map, key) do
      value when is_binary(value) ->
        value
        |> String.trim()
        |> case do
          "" -> {:error, "invalid_field:#{key}"}
          text -> {:ok, text}
        end

      _value ->
        {:error, "invalid_field:#{key}"}
    end
  end

  defp canonical_nested_map(key, map) do
    case canonical_attrs(map) do
      :ok -> {:ok, map}
      {:error, _reason} -> {:error, "invalid_field:#{key}"}
    end
  end

  defp canonical_attrs(attrs) do
    if Enum.all?(attrs, fn {key, _value} -> is_binary(key) end) do
      :ok
    else
      {:error, "invalid_attrs"}
    end
  end

  defp action_name(function) do
    case compact_text(function, "name") do
      nil -> "action"
      name -> name
    end
  end

  defp compact_text(map, key) do
    case fetch_field(map, key) do
      value when is_binary(value) ->
        value
        |> String.trim()
        |> case do
          "" -> nil
          text -> text
        end

      _value ->
        nil
    end
  end

  defp value(map, key), do: fetch_field(map, key)

  defp fetch_field(map, key) when is_map(map) and is_binary(key), do: Map.get(map, key)
  defp fetch_field(_map, _key), do: nil

  defp map_with_field(key, value), do: %{key => value}

  defp reject_empty(map) do
    map
    |> Enum.reject(fn {_key, value} -> empty?(value) end)
    |> Map.new()
  end

  defp empty?(nil), do: true
  defp empty?(""), do: true
  defp empty?([]), do: true
  defp empty?(map) when is_map(map), do: map_size(map) == 0
  defp empty?(_value), do: false
end
