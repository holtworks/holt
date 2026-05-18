defmodule Holt.Tasks.AgentLoop do
  @moduledoc """
  Product-level projection for one task-agent objective loop.
  """

  alias Holt.Clock

  @schema_version "holt_agent_loop/v1"
  @mode "continuous_until_verified"

  def contract(attrs \\ %{})

  def contract(attrs) when is_map(attrs) do
    with :ok <- canonical_attrs(attrs),
         {:ok, task} <- map_field(attrs, "task"),
         :ok <- validate_task(task),
         {:ok, agent} <- map_field(attrs, "agent"),
         :ok <- validate_agent(agent),
         {:ok, policy} <- map_field(attrs, "policy"),
         :ok <- validate_policy(policy),
         {:ok, decision} <- map_field(attrs, "decision"),
         :ok <- validate_decision(decision),
         {:ok, continuation_count} <- optional_nonnegative_integer(attrs, "continuation_count", 0),
         {:ok, lifecycle_state} <- optional_text(attrs, "lifecycle_state"),
         {:ok, executor_status} <- optional_text(attrs, "status"),
         {:ok, started_at} <- optional_text(attrs, "loop_started_at"),
         {:ok, now} <- optional_text(attrs, "now", Clock.iso_now()),
         {:ok, source} <- optional_text(attrs, "source") do
      max_wall_clock_seconds = Map.get(policy, "max_wall_clock_seconds", 0)
      agent_id = Map.get(agent, "agent_id")

      %{
        "schema_version" => @schema_version,
        "id" => loop_id(task, agent_id),
        "mode" => @mode,
        "status" => loop_status(executor_status, lifecycle_state, decision),
        "task_id" => Map.get(task, "id"),
        "task_ref" => Map.get(task, "ref"),
        "agent_id" => agent_id,
        "agent_ref" => Map.get(agent, "agent_ref"),
        "iteration" => continuation_count + 1,
        "continuation_depth" => continuation_count,
        "next_continuation_depth" => Map.get(decision, "depth"),
        "max_iterations" => max_iterations(policy),
        "started_at" => started_at,
        "last_iteration_at" => now,
        "elapsed_seconds" => elapsed_seconds(started_at, now),
        "max_wall_clock_seconds" => positive_or_nil(max_wall_clock_seconds),
        "expires_at" => expires_at(started_at, max_wall_clock_seconds),
        "verification_contract" => Map.get(policy, "verification_contract"),
        "retry_policy" => retry_policy(),
        "objective_prompt_snapshot" => objective_snapshot(task),
        "source" => source
      }
      |> reject_empty()
    else
      {:error, reason} -> rejected_loop(reason)
    end
  end

  def contract(_attrs), do: rejected_loop("invalid_attrs")

  defp rejected_loop(reason) do
    %{
      "schema_version" => @schema_version,
      "status" => "rejected",
      "reason" => reason
    }
  end

  def loop_id(task, agent_id) when is_map(task) do
    "task_agent_loop:#{loop_task_id(task)}:#{loop_agent_id(agent_id)}"
  end

  def loop_id(_task, agent_id), do: "task_agent_loop:task:#{loop_agent_id(agent_id)}"

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
    |> reject_empty()
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
    case Map.get(policy, "max_continuation_depth") do
      count when is_integer(count) and count > 0 -> count + 1
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

  defp loop_task_id(%{"id" => id}) when is_binary(id) and id != "", do: id
  defp loop_task_id(_task), do: "task"

  defp loop_agent_id(agent_id) when is_binary(agent_id) and agent_id != "", do: agent_id
  defp loop_agent_id(_agent_id), do: "agent"

  defp truncate(nil, _limit), do: nil

  defp truncate(text, limit) when is_binary(text) do
    text
    |> String.trim()
    |> String.slice(0, limit)
  end

  defp map_field(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_map(value) -> canonical_nested_map(key, value)
      {:ok, _value} -> {:error, "invalid_field:#{key}"}
      :error -> {:ok, %{}}
    end
  end

  defp optional_text(attrs, key, default \\ nil) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> text_value(key, value)
      :error -> {:ok, default}
    end
  end

  defp text_value(key, value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, "invalid_field:#{key}"}
      text -> {:ok, text}
    end
  end

  defp text_value(key, _value), do: {:error, "invalid_field:#{key}"}

  defp optional_nonnegative_integer(attrs, key, default) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_integer(value) and value >= 0 -> {:ok, value}
      {:ok, _value} -> {:error, "invalid_field:#{key}"}
      :error -> {:ok, default}
    end
  end

  defp validate_task(task) do
    validate_text_fields(task, "task", ["id", "ref", "title", "description"])
  end

  defp validate_agent(agent) do
    validate_text_fields(agent, "agent", ["agent_id", "agent_ref"])
  end

  defp validate_policy(policy) do
    with :ok <-
           validate_nonnegative_integer_fields(policy, "policy", [
             "max_continuation_depth",
             "max_wall_clock_seconds"
           ]) do
      validate_map_fields(policy, "policy", ["verification_contract"])
    end
  end

  defp validate_decision(decision) do
    with :ok <- validate_text_fields(decision, "decision", ["action"]) do
      validate_nonnegative_integer_fields(decision, "decision", ["depth"])
    end
  end

  defp validate_text_fields(map, field, keys) do
    if Enum.all?(keys, &valid_optional_text?(map, &1)) do
      :ok
    else
      {:error, "invalid_field:#{field}"}
    end
  end

  defp valid_optional_text?(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) -> String.trim(value) != ""
      {:ok, _value} -> false
      :error -> true
    end
  end

  defp validate_nonnegative_integer_fields(map, field, keys) do
    if Enum.all?(keys, &valid_optional_nonnegative_integer?(map, &1)) do
      :ok
    else
      {:error, "invalid_field:#{field}"}
    end
  end

  defp valid_optional_nonnegative_integer?(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_integer(value) and value >= 0 -> true
      {:ok, _value} -> false
      :error -> true
    end
  end

  defp validate_map_fields(map, field, keys) do
    if Enum.all?(keys, &valid_optional_map?(map, &1)) do
      :ok
    else
      {:error, "invalid_field:#{field}"}
    end
  end

  defp valid_optional_map?(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_map(value) -> canonical_value?(value)
      {:ok, _value} -> false
      :error -> true
    end
  end

  defp canonical_attrs(attrs) do
    if Enum.all?(attrs, fn {key, _value} -> is_binary(key) end) do
      :ok
    else
      {:error, "invalid_attrs"}
    end
  end

  defp canonical_nested_map(key, map) do
    if canonical_value?(map) do
      {:ok, map}
    else
      {:error, "invalid_field:#{key}"}
    end
  end

  defp canonical_value?(value) when is_map(value) do
    Enum.all?(value, fn
      {key, nested} when is_binary(key) -> canonical_value?(nested)
      _entry -> false
    end)
  end

  defp canonical_value?(value) when is_list(value), do: Enum.all?(value, &canonical_value?/1)
  defp canonical_value?(_value), do: true

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
