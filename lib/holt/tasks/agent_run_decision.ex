defmodule Holt.Tasks.AgentRunDecision do
  @moduledoc """
  Decides whether a task-agent run should auto-continue.
  """

  def decide(attrs) when is_map(attrs) do
    run_status = attrs["run_status"]
    policy = canonical_map(attrs["policy"])
    classification = canonical_map(attrs["classification"])
    continuation_count = positive_integer(attrs["continuation_count"], 0)
    max_depth = positive_integer(policy["max_continuation_depth"], 0)

    cond do
      not literal_true?(policy["continuation_allowed"]) ->
        stop("continuation_not_allowed")

      run_status == "completed" and not literal_true?(policy["auto_continue"]) ->
        stop("continuation_not_requested")

      run_status == "completed" and continuation_count >= max_depth ->
        suppress("max_continuation_depth_reached", classification)

      run_status == "completed" ->
        continue(continuation_count + 1, "auto_continue_enabled")

      run_status == "failed" and literal_true?(classification["retryable"]) and
        literal_true?(policy["retry_on_failure"]) and continuation_count < max_depth ->
        continue(continuation_count + 1, "retryable_failure")

      true ->
        suppress("run_not_continuable", classification)
    end
  end

  def decide(_attrs), do: stop("invalid_decision_attrs")

  defp continue(depth, reason) do
    %{
      "schema_version" => "holt_continuation_decision/v1",
      "action" => "continue",
      "reason" => reason,
      "depth" => depth
    }
  end

  defp stop(reason) do
    %{
      "schema_version" => "holt_continuation_decision/v1",
      "action" => "stop",
      "reason" => reason
    }
  end

  defp suppress(reason, classification) do
    %{
      "schema_version" => "holt_continuation_decision/v1",
      "action" => "suppress",
      "reason" => reason,
      "failure_class" => classification["failure_class"],
      "blocker_code" => classification["blocker_code"]
    }
  end

  defp positive_integer(value, _default) when is_integer(value) and value >= 0, do: value
  defp positive_integer(_value, default), do: default

  defp literal_true?(true), do: true
  defp literal_true?(_value), do: false

  defp canonical_map(value) when is_map(value), do: value
  defp canonical_map(_value), do: %{}
end
