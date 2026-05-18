defmodule Holt.Tasks.AgentRunFailureClassifier do
  @moduledoc """
  Converts run state into structured failure and retry information.
  """

  def classify(run, reason \\ nil)

  def classify(run, reason) when is_map(run) do
    case run["status"] do
      "completed" ->
        %{
          "schema_version" => "holt_run_failure_classification/v1",
          "status" => "completed",
          "failure_class" => nil,
          "blocker_code" => nil,
          "retryable" => false,
          "reason" => nil
        }

      "blocked" ->
        %{
          "schema_version" => "holt_run_failure_classification/v1",
          "status" => "blocked",
          "failure_class" => text(run, "failure_class", "blocked"),
          "blocker_code" => text(run, "blocker_code", "external_blocker"),
          "retryable" => false,
          "reason" => text(run, "blocked_reason", inspect(reason))
        }

      "canceled" ->
        %{
          "schema_version" => "holt_run_failure_classification/v1",
          "status" => "canceled",
          "failure_class" => "canceled",
          "blocker_code" => "canceled",
          "retryable" => false,
          "reason" => text(run, "failure_reason", inspect(reason))
        }

      "failed" ->
        %{
          "schema_version" => "holt_run_failure_classification/v1",
          "status" => "failed",
          "failure_class" => text(run, "failure_class", "runtime_failure"),
          "blocker_code" => run["blocker_code"],
          "retryable" => true,
          "reason" => text(run, "failure_reason", inspect(reason))
        }

      status ->
        %{
          "schema_version" => "holt_run_failure_classification/v1",
          "status" => status(status),
          "failure_class" => "unknown",
          "blocker_code" => "unknown",
          "retryable" => false,
          "reason" => inspect(reason)
        }
    end
  end

  def classify(_run, reason) do
    %{
      "schema_version" => "holt_run_failure_classification/v1",
      "status" => "error",
      "failure_class" => "runtime_exception",
      "blocker_code" => nil,
      "retryable" => true,
      "reason" => inspect(reason)
    }
  end

  defp text(map, key, default) do
    case map[key] do
      value when is_binary(value) and value != "" -> value
      _missing -> default
    end
  end

  defp status(value) when is_binary(value) and value != "", do: value
  defp status(_value), do: "unknown"
end
