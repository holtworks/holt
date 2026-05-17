defmodule HoltWorks.Tasks.AgentRunPolicy do
  @moduledoc """
  Builds structured continuation policy from task/work metadata.
  """

  alias HoltWorks.Tasks.AgentTaskClassifier

  def for_task(task, work, opts \\ []) do
    classification = AgentTaskClassifier.classify(task)
    explicit = normalize_policy(work["policy"] || task["agent_policy"] || %{})

    auto_continue = truthy?(Map.get(explicit, "auto_continue", false))
    continuation_allowed = truthy?(Map.get(explicit, "continuation_allowed", auto_continue))
    retry_on_failure = truthy?(Map.get(explicit, "retry_on_failure", false))

    max_depth =
      explicit
      |> Map.get("max_continuation_depth")
      |> positive_integer(default_depth(classification["task_complexity"]))

    %{
      "schema_version" => "holtworks_agent_run_policy/v1",
      "task_classification" => classification,
      "auto_continue" => auto_continue,
      "continuation_allowed" =>
        continuation_allowed and truthy?(classification["continuation_allowed"]),
      "retry_on_failure" => retry_on_failure,
      "max_continuation_depth" => max_depth,
      "source" => Map.get(explicit, "source", opts[:source] || "task_policy")
    }
  end

  def normalize_policy(policy) when is_map(policy) do
    Map.new(policy, fn {key, value} -> {to_string(key), value} end)
  end

  def normalize_policy(_policy), do: %{}

  defp default_depth("broad_parallel"), do: 4
  defp default_depth("implementation"), do: 3
  defp default_depth("standard"), do: 2
  defp default_depth(_complexity), do: 1

  defp positive_integer(value, _default) when is_integer(value) and value >= 0, do: value

  defp positive_integer(value, default) do
    case Integer.parse(to_string(value)) do
      {number, ""} when number >= 0 -> number
      _other -> default
    end
  end

  defp truthy?(value), do: value in [true, "true", "1", 1]
end
