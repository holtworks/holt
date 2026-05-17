defmodule HoltWorks.Runtime.EventRecorder do
  @moduledoc """
  Typed helpers for writing HoltWorks agent session events.
  """

  alias HoltWorks.Runtime.AgentEvents

  def session_started(session_id, opts) do
    AgentEvents.append(
      session_id,
      "session_start",
      %{
        "objective" => opts[:objective],
        "model" => opts[:model],
        "provider" => opts[:provider]
      }
      |> reject_empty(),
      event_opts(session_id, opts,
        sequence: 0,
        span_id: AgentEvents.session_span_id(session_id),
        status: "running"
      )
    )
  end

  def session_ended(session_id, status, opts) do
    AgentEvents.append(
      session_id,
      "session_end",
      %{"status" => status} |> reject_empty(),
      event_opts(session_id, opts,
        span_id: AgentEvents.session_span_id(session_id),
        status: status,
        ended_at: opts[:ended_at] || HoltWorks.Clock.iso_now()
      )
    )
  end

  def user_message(session_id, content, opts) do
    content = to_string(content || "")
    turn = opts[:turn] || 0

    AgentEvents.append(
      session_id,
      "user_message",
      %{
        "content_length" => String.length(content),
        "content_preview" => String.slice(content, 0, 200)
      },
      event_opts(session_id, opts,
        span_id: opts[:span_id] || AgentEvents.message_span_id(turn),
        parent_span_id: opts[:parent_span_id] || AgentEvents.turn_span_id(turn),
        turn_id: turn,
        status: "completed"
      )
    )
  end

  def stream_chunk(session_id, content, opts) do
    content = to_string(content || "")
    turn = opts[:turn] || 0

    AgentEvents.append(
      session_id,
      "stream_chunk",
      %{
        "content_length" => String.length(content),
        "content_preview" => String.slice(content, 0, 500),
        "chunk_index" => opts[:chunk_index]
      }
      |> reject_empty(),
      event_opts(session_id, opts,
        span_id: opts[:span_id] || AgentEvents.message_span_id(turn),
        parent_span_id: opts[:parent_span_id] || AgentEvents.turn_span_id(turn),
        turn_id: turn,
        status: "completed"
      )
    )
  end

  def awaiting_user(session_id, question, opts) do
    question = to_string(question || "")
    turn = opts[:turn] || 0

    AgentEvents.append(
      session_id,
      "awaiting_user",
      %{
        "question_length" => String.length(question),
        "question_preview" => String.slice(question, 0, 500),
        "tool_call_id" => opts[:tool_call_id]
      }
      |> reject_empty(),
      event_opts(session_id, opts,
        span_id: opts[:span_id] || AgentEvents.tool_span_id(opts[:tool_call_id]),
        parent_span_id: opts[:parent_span_id] || AgentEvents.turn_span_id(turn),
        turn_id: turn,
        tool_call_id: opts[:tool_call_id],
        status: "awaiting_user"
      )
    )
  end

  def user_response(session_id, answer, opts) do
    answer = to_string(answer || "")
    turn = opts[:turn] || 0

    AgentEvents.append(
      session_id,
      "user_response",
      %{
        "answer_length" => String.length(answer),
        "answer_preview" => String.slice(answer, 0, 500),
        "tool_call_id" => opts[:tool_call_id]
      }
      |> reject_empty(),
      event_opts(session_id, opts,
        span_id: opts[:span_id] || AgentEvents.tool_span_id(opts[:tool_call_id]),
        parent_span_id: opts[:parent_span_id] || AgentEvents.turn_span_id(turn),
        turn_id: turn,
        tool_call_id: opts[:tool_call_id],
        status: "completed"
      )
    )
  end

  def llm_request(session_id, opts) do
    turn = opts[:turn] || 0

    AgentEvents.append(
      session_id,
      "llm_request",
      %{
        "model" => opts[:model],
        "provider" => opts[:provider],
        "message_count" => opts[:message_count],
        "tool_count" => opts[:tool_count],
        "turn" => turn
      }
      |> reject_empty(),
      event_opts(session_id, opts,
        span_id: opts[:span_id] || AgentEvents.llm_span_id(turn),
        parent_span_id: opts[:parent_span_id] || AgentEvents.turn_span_id(turn),
        turn_id: turn,
        status: "running",
        metadata: %{"model" => opts[:model], "provider" => opts[:provider]} |> reject_empty()
      )
    )
  end

  def llm_response(session_id, opts) do
    turn = opts[:turn] || 0

    AgentEvents.append(
      session_id,
      "llm_response",
      %{
        "model" => opts[:model],
        "provider" => opts[:provider],
        "content_length" => opts[:content_length],
        "tool_calls_count" => opts[:tool_calls_count] || 0,
        "finish_reason" => opts[:finish_reason]
      }
      |> reject_empty(),
      event_opts(session_id, opts,
        span_id: opts[:span_id] || AgentEvents.llm_span_id(turn),
        parent_span_id: opts[:parent_span_id] || AgentEvents.turn_span_id(turn),
        turn_id: turn,
        status: "completed",
        metadata:
          %{
            "model" => opts[:model],
            "provider" => opts[:provider],
            "latency_ms" => opts[:latency_ms]
          }
          |> reject_empty()
      )
    )
  end

  def tool_invocation(session_id, tool_name, arguments, opts) do
    turn = opts[:turn] || 0
    tool_call_id = opts[:tool_call_id]

    AgentEvents.append(
      session_id,
      "tool_invocation",
      %{
        "tool_name" => tool_name,
        "arguments" => sanitize_arguments(arguments),
        "tool_call_id" => tool_call_id
      }
      |> reject_empty(),
      event_opts(session_id, opts,
        span_id: opts[:span_id] || AgentEvents.tool_span_id(tool_call_id),
        parent_span_id: opts[:parent_span_id] || AgentEvents.turn_span_id(turn),
        turn_id: turn,
        tool_call_id: tool_call_id,
        status: "running"
      )
    )
  end

  def tool_result(session_id, tool_name, result, opts) do
    turn = opts[:turn] || 0
    tool_call_id = opts[:tool_call_id]
    status = result_status(result)

    AgentEvents.append(
      session_id,
      "tool_result",
      %{
        "tool_name" => tool_name,
        "status" => status,
        "result_preview" => result_preview(result),
        "tool_call_id" => tool_call_id
      }
      |> reject_empty(),
      event_opts(session_id, opts,
        span_id: opts[:span_id] || AgentEvents.tool_span_id(tool_call_id),
        parent_span_id: opts[:parent_span_id] || AgentEvents.turn_span_id(turn),
        turn_id: turn,
        tool_call_id: tool_call_id,
        status: status,
        metadata: %{"latency_ms" => opts[:latency_ms]} |> reject_empty()
      )
    )
  end

  def error(session_id, error_type, detail, opts) do
    AgentEvents.append(
      session_id,
      "error",
      %{
        "error_type" => error_type,
        "detail" => detail |> inspect() |> String.slice(0, 500)
      },
      event_opts(session_id, opts, status: "error")
    )
  end

  defp event_opts(session_id, opts, overrides) do
    base = [
      workspace: opts[:workspace],
      run_id: opts[:run_id],
      run_dir: opts[:run_dir],
      agent_id: opts[:agent_id] || opts[:agent],
      trace_id: opts[:trace_id] || AgentEvents.default_trace_id(session_id),
      metadata: opts[:metadata] || %{}
    ]

    Keyword.merge(base, overrides)
  end

  defp sanitize_arguments(arguments) when is_map(arguments) do
    arguments
    |> Enum.map(fn
      {key, value} when key in ["content", :content, "text", :text, "body", :body] ->
        {to_string(key) <> "_preview", value |> to_string() |> String.slice(0, 160)}

      {key, value} ->
        {to_string(key), sanitize_value(value)}
    end)
    |> Map.new()
  end

  defp sanitize_arguments(_arguments), do: %{}

  defp sanitize_value(value) when is_map(value), do: sanitize_arguments(value)

  defp sanitize_value(value) when is_list(value) do
    value
    |> Enum.take(20)
    |> Enum.map(&sanitize_value/1)
  end

  defp sanitize_value(value) when is_binary(value), do: String.slice(value, 0, 500)
  defp sanitize_value(value), do: value

  defp result_status(%{"status" => status}) when is_binary(status) and status != "", do: status
  defp result_status(%{status: status}) when is_binary(status) and status != "", do: status
  defp result_status({:error, _reason}), do: "error"
  defp result_status(_result), do: "completed"

  defp result_preview(result) when is_binary(result), do: String.slice(result, 0, 500)

  defp result_preview(result) when is_map(result) do
    result
    |> Map.take(["status", "tool_name", "reason", "path", "bytes", "result"])
    |> case do
      empty when empty == %{} -> inspect(result, limit: 20)
      preview -> Jason.encode!(preview)
    end
    |> String.slice(0, 500)
  end

  defp result_preview(result), do: result |> inspect(limit: 20) |> String.slice(0, 500)

  defp reject_empty(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end
end
