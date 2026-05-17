defmodule HoltWorks.Tasks.ContextBudgetGovernor do
  @moduledoc """
  Provider-neutral context budget planning for long-running task agents.

  The governor estimates whether the next model request can be sent as-is,
  should snapshot soon, or must compact before retrying. It does not decide task
  lifecycle state; callers use the structured `action` and `budget_state`
  fields as policy input.
  """

  alias HoltWorks.Clock

  @schema_version "holtworks_context_budget_governor/v1"
  @default_context_window 128_000
  @default_output_reserve 8_192
  @default_tool_reserve 24_000
  @soft_ratio 0.75
  @critical_ratio 0.9

  def plan(attrs \\ %{})

  def plan(attrs) when is_map(attrs) do
    attrs = string_keys(attrs)
    provider_profile = normalize_map(value(attrs, "provider_profile"))
    policy = normalize_map(value(attrs, "policy"))
    messages = normalize_list(value(attrs, "messages"))
    tools = normalize_list(value(attrs, "tools"))

    context_window =
      positive_int(value(provider_profile, "context_window")) ||
        positive_int(value(attrs, "context_window")) ||
        positive_int(value(policy, "max_total_tokens")) ||
        @default_context_window

    output_reserve =
      positive_int(value(attrs, "output_reserve_tokens")) ||
        min(@default_output_reserve, max(div(context_window, 20), 1_024))

    tool_reserve =
      positive_int(value(attrs, "tool_reserve_tokens")) ||
        min(@default_tool_reserve, max(div(context_window, 10), 2_048))

    hard_limit =
      positive_int(value(attrs, "hard_limit_tokens")) ||
        max(context_window - output_reserve, 1_024)

    soft_limit =
      positive_int(value(attrs, "soft_limit_tokens")) ||
        floor(context_window * @soft_ratio)

    critical_limit =
      positive_int(value(attrs, "critical_limit_tokens")) ||
        floor(context_window * @critical_ratio)

    input_tokens =
      nonnegative_int(value(attrs, "estimated_input_tokens")) ||
        estimate_messages_tokens(messages) + estimate_tools_tokens(tools)

    available_tokens = max(hard_limit - input_tokens - tool_reserve, 0)

    %{
      "schema_version" => @schema_version,
      "provider" => value(provider_profile, "provider"),
      "model" => value(provider_profile, "model"),
      "context_window" => context_window,
      "hard_limit_tokens" => hard_limit,
      "soft_limit_tokens" => soft_limit,
      "critical_limit_tokens" => critical_limit,
      "output_reserve_tokens" => output_reserve,
      "tool_reserve_tokens" => tool_reserve,
      "estimated_input_tokens" => input_tokens,
      "available_tokens" => available_tokens,
      "budget_state" => budget_state(input_tokens, soft_limit, critical_limit, hard_limit),
      "action" => action(input_tokens, soft_limit, critical_limit, hard_limit),
      "compression" => compression_contract(input_tokens, soft_limit, critical_limit, hard_limit),
      "provider_features" => provider_features(provider_profile),
      "updated_at" => Clock.iso_now()
    }
    |> reject_empty()
  end

  def plan(_attrs), do: plan(%{})

  def estimate_messages_tokens(messages) when is_list(messages) do
    messages
    |> encode_size()
    |> estimate_tokens_from_bytes()
  end

  def estimate_messages_tokens(_messages), do: 0

  def estimate_tools_tokens(tools) when is_list(tools) do
    tools
    |> encode_size()
    |> estimate_tokens_from_bytes()
  end

  def estimate_tools_tokens(_tools), do: 0

  def compact_messages(messages, plan) when is_list(messages) and is_map(plan) do
    case value(plan, "action") do
      "send" -> messages
      _action -> compact_messages_to_budget(messages, plan)
    end
  end

  def compact_messages(messages, _plan), do: messages

  def overflow_error(status, body) do
    %{
      "schema_version" => "holtworks_context_overflow_error/v1",
      "failure_class" => "context_budget_exceeded",
      "blocker_code" => "compression_required",
      "retryable" => true,
      "http_status" => status,
      "provider_message" => provider_message(body),
      "raw_error_preview" => body |> to_text() |> String.slice(0, 1_000)
    }
    |> reject_empty()
  end

  defp compact_messages_to_budget([system | rest], plan) do
    target_tokens =
      positive_int(value(plan, "soft_limit_tokens")) ||
        positive_int(value(plan, "hard_limit_tokens")) ||
        @default_context_window

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
              "Use task memory artifact refs or task tools to dereference exact evidence."
        }
      ]
    end
  end

  defp compact_message(%{"role" => "tool", "content" => content} = message)
       when is_binary(content) do
    Map.put(message, "content", bounded_text(content, 1_200))
  end

  defp compact_message(%{role: "tool", content: content} = message) when is_binary(content) do
    %{message | content: bounded_text(content, 1_200)}
  end

  defp compact_message(%{"role" => "assistant", "tool_calls" => tool_calls} = message)
       when is_list(tool_calls) do
    Map.put(message, "tool_calls", Enum.map(tool_calls, &compact_tool_call/1))
  end

  defp compact_message(%{role: "assistant", tool_calls: tool_calls} = message)
       when is_list(tool_calls) do
    %{message | tool_calls: Enum.map(tool_calls, &compact_tool_call/1)}
  end

  defp compact_message(message), do: message

  defp compact_tool_call(tool_call) when is_map(tool_call) do
    function = value(tool_call, "function") || %{}
    arguments = value(function, "arguments")

    if is_binary(arguments) and byte_size(arguments) > 1_200 do
      name = value(function, "name") || "tool"
      put_in_tool_arguments(tool_call, ~s({"_compacted":"#{name} arguments stored in artifacts"}))
    else
      tool_call
    end
  end

  defp compact_tool_call(tool_call), do: tool_call

  defp put_in_tool_arguments(%{"function" => function} = tool_call, replacement)
       when is_map(function) do
    Map.put(tool_call, "function", Map.put(function, "arguments", replacement))
  end

  defp put_in_tool_arguments(%{function: function} = tool_call, replacement)
       when is_map(function) do
    %{tool_call | function: Map.put(function, :arguments, replacement)}
  end

  defp put_in_tool_arguments(tool_call, _replacement), do: tool_call

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

  defp provider_features(provider_profile) do
    provider = value(provider_profile, "provider")

    %{
      "openai_server_compaction" => provider == "openai",
      "anthropic_context_management" => provider == "anthropic",
      "tool_result_clearing" => provider in ["anthropic", "openai"],
      "provider_neutral_fallback" => true
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
    get_in(body, ["error", "message"]) || get_in(body, [:error, :message]) || to_text(body)
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

  defp positive_int(value) when is_integer(value) and value > 0, do: value

  defp positive_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _other -> nil
    end
  end

  defp positive_int(_value), do: nil

  defp nonnegative_int(value) when is_integer(value) and value >= 0, do: value

  defp nonnegative_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int >= 0 -> int
      _other -> nil
    end
  end

  defp nonnegative_int(_value), do: nil

  defp to_text(value) when is_binary(value), do: value

  defp to_text(value) do
    case Jason.encode(value) do
      {:ok, text} -> text
      _error -> inspect(value)
    end
  end

  defp normalize_list(value) when is_list(value), do: value
  defp normalize_list(_value), do: []

  defp normalize_map(value) when is_map(value), do: string_keys(value)
  defp normalize_map(_value), do: %{}

  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp value(_map, _key), do: nil

  defp string_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), normalize_value(value)}
      {key, value} -> {to_string(key), normalize_value(value)}
    end)
  end

  defp string_keys(_value), do: %{}

  defp normalize_value(value) when is_map(value), do: string_keys(value)
  defp normalize_value(value) when is_list(value), do: Enum.map(value, &normalize_value/1)
  defp normalize_value(value), do: value

  defp reject_empty(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end
end
