defmodule HoltWorks.Tasks.AgentLoop do
  @moduledoc """
  Product-level projection for one task-agent objective loop.
  """

  alias HoltWorks.Clock
  alias HoltWorks.Tasks.RuntimeContracts

  @schema_version "holtworks_agent_loop/v1"
  @mode "continuous_until_verified"

  def contract(attrs \\ %{})

  def contract(attrs) when is_map(attrs) do
    attrs = RuntimeContracts.string_keys(attrs)
    task = RuntimeContracts.normalize_map(RuntimeContracts.value(attrs, "task"))
    agent = RuntimeContracts.normalize_map(RuntimeContracts.value(attrs, "agent"))
    policy = RuntimeContracts.normalize_map(RuntimeContracts.value(attrs, "policy"))
    decision = RuntimeContracts.normalize_map(RuntimeContracts.value(attrs, "decision"))

    continuation_count =
      RuntimeContracts.integer(RuntimeContracts.value(attrs, "continuation_count"))

    lifecycle_state = RuntimeContracts.text(attrs, "lifecycle_state")
    executor_status = RuntimeContracts.text(attrs, "status")
    started_at = RuntimeContracts.text(attrs, "loop_started_at")
    now = RuntimeContracts.text(attrs, "now", Clock.iso_now())
    max_wall_clock_seconds = RuntimeContracts.integer(policy["max_wall_clock_seconds"])
    agent_id = agent["agent_id"] || agent["id"] || RuntimeContracts.text(attrs, "agent_id")

    %{
      "schema_version" => @schema_version,
      "id" => loop_id(task, agent_id),
      "mode" => @mode,
      "status" => loop_status(executor_status, lifecycle_state, decision),
      "task_id" => task["id"] || RuntimeContracts.text(attrs, "task_id"),
      "task_ref" => task["ref"] || RuntimeContracts.text(attrs, "task_ref"),
      "agent_id" => agent_id,
      "agent_ref" => agent["agent_ref"] || agent["ref"],
      "iteration" => continuation_count + 1,
      "continuation_depth" => continuation_count,
      "next_continuation_depth" => RuntimeContracts.integer(decision["depth"]),
      "max_iterations" => max_iterations(policy),
      "started_at" => started_at,
      "last_iteration_at" => now,
      "elapsed_seconds" => elapsed_seconds(started_at, now),
      "max_wall_clock_seconds" => positive_or_nil(max_wall_clock_seconds),
      "expires_at" => expires_at(started_at, max_wall_clock_seconds),
      "verification_contract" => policy["verification_contract"],
      "retry_policy" => retry_policy(),
      "objective_prompt_snapshot" => objective_snapshot(task),
      "source" => RuntimeContracts.text(attrs, "source")
    }
    |> RuntimeContracts.reject_empty()
  end

  def contract(_attrs), do: contract(%{})

  def loop_id(task, agent_id) when is_map(task) do
    task_id = task["id"] || "task"
    "task_agent_loop:#{task_id}:#{agent_id || "agent"}"
  end

  def loop_id(_task, agent_id), do: "task_agent_loop:task:#{agent_id || "agent"}"

  defp loop_status("canceled", _lifecycle_state, _decision), do: "canceled"
  defp loop_status(_status, _lifecycle_state, %{"action" => "continue"}), do: "running"
  defp loop_status(_status, "completed", _decision), do: "completed"
  defp loop_status(_status, "blocked", _decision), do: "blocked"
  defp loop_status(_status, "failed", _decision), do: "failed"
  defp loop_status(_status, "canceled", _decision), do: "canceled"
  defp loop_status("failed", _lifecycle_state, _decision), do: "failed"
  defp loop_status(_status, _lifecycle_state, _decision), do: "running"

  defp objective_snapshot(task) when is_map(task) do
    %{
      "task_ref" => task["ref"],
      "title" => truncate(task["title"], 300),
      "description" => truncate(task["description"], 2_000)
    }
    |> RuntimeContracts.reject_empty()
  end

  defp objective_snapshot(_task), do: %{}

  defp retry_policy do
    %{
      "retryable_failures_continue" => true,
      "stop_on_terminal_blocker" => true,
      "completion_signal" => "route_verification_review.can_finish"
    }
  end

  defp max_iterations(policy) when is_map(policy) do
    case RuntimeContracts.integer(policy["max_continuation_depth"]) do
      count when count > 0 -> count + 1
      _count -> nil
    end
  end

  defp max_iterations(_policy), do: nil

  defp elapsed_seconds(started_at, now) when is_binary(started_at) and is_binary(now) do
    with {:ok, started, _offset} <- DateTime.from_iso8601(started_at),
         {:ok, current, _offset} <- DateTime.from_iso8601(now) do
      max(DateTime.diff(current, started, :second), 0)
    else
      _error -> nil
    end
  end

  defp elapsed_seconds(_started_at, _now), do: nil

  defp expires_at(started_at, max_seconds)
       when is_binary(started_at) and is_integer(max_seconds) and max_seconds > 0 do
    case DateTime.from_iso8601(started_at) do
      {:ok, datetime, _offset} ->
        datetime
        |> DateTime.add(max_seconds, :second)
        |> DateTime.to_iso8601()

      _error ->
        nil
    end
  end

  defp expires_at(_started_at, _max_seconds), do: nil

  defp positive_or_nil(value) when is_integer(value) and value > 0, do: value
  defp positive_or_nil(_value), do: nil

  defp truncate(nil, _limit), do: nil

  defp truncate(text, limit) do
    text
    |> to_string()
    |> String.trim()
    |> String.slice(0, limit)
  end
end
