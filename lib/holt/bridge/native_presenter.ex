defmodule Holt.Bridge.NativePresenter do
  @moduledoc """
  Output rendering helpers for the native Holt command bridge.
  """

  alias Holt.ActionVisibility

  def print_json_event(event) do
    event
    |> normalize_json_event()
    |> Enum.reject(fn {_key, value} -> value in [nil, "", %{}, []] end)
    |> Map.new()
    |> Jason.encode!()
    |> IO.puts()
  end

  def print_runtime_event(%{"type" => "progress." <> _rest, "message" => message})
      when is_binary(message) do
    IO.puts("Progress: #{message}")
  end

  def print_runtime_event(%{"type" => "action." <> _rest} = event) do
    case ActionVisibility.render(event) do
      line when is_binary(line) -> IO.puts(line)
      _ -> :ok
    end
  end

  def print_runtime_event(%{"type" => "model.thinking", "content" => content})
      when is_binary(content) do
    IO.puts("Thinking:\n#{content}")
  end

  def print_runtime_event(%{"type" => "child_agent.completed"} = event) do
    IO.puts(render_child_agent_completion(event))
  end

  def print_runtime_event(_event), do: :ok

  def render_log_event(%{"type" => "progress." <> _rest, "message" => message})
      when is_binary(message) do
    "Progress: #{message}"
  end

  def render_log_event(%{"type" => "action." <> _rest} = event),
    do: ActionVisibility.render(event)

  def render_log_event(%{"type" => "model.thinking", "content" => content})
      when is_binary(content) do
    "Thinking:\n#{content}"
  end

  def render_log_event(%{"type" => "run.transitioned", "to" => status}) when is_binary(status) do
    "Status: #{status}"
  end

  def render_log_event(%{"type" => "child_agent.completed"} = event),
    do: render_child_agent_completion(event)

  def render_log_event(_event), do: nil

  defp render_child_agent_completion(event) do
    agent = child_agent_id(event)
    status = child_agent_status(event)

    [
      "Child agent #{agent} #{status}",
      child_completion_part("child run", event["child_run_id"]),
      child_completion_part("parent run", event["agent_run_id"])
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  defp child_completion_part(_label, value) when value in [nil, ""], do: nil
  defp child_completion_part(label, value), do: "#{label}: #{value}"

  defp child_agent_id(%{"child_agent_id" => agent}) when is_binary(agent) and agent != "",
    do: agent

  defp child_agent_id(_event), do: "child agent"

  defp child_agent_status(%{"status" => status}) when is_binary(status) and status != "",
    do: status

  defp child_agent_status(_event), do: "completed"

  defp normalize_json_event(%{"type" => "stream_chunk", "content" => content} = event) do
    event
    |> Map.put("type", "answer.delta")
    |> Map.put("content", content)
  end

  defp normalize_json_event(event), do: event
end
