defmodule Holt.Tasks.AgentRunPolicy do
  @moduledoc """
  Builds structured continuation policy from task/work metadata.
  """

  alias Holt.Tasks.AgentTaskClassifier

  def for_task(task, work, opts \\ []) do
    classification = AgentTaskClassifier.classify(task)
    explicit = policy_map(work["policy"])

    auto_continue = literal_true?(Map.get(explicit, "auto_continue", false))
    continuation_allowed = literal_true?(Map.get(explicit, "continuation_allowed", false))
    retry_on_failure = literal_true?(Map.get(explicit, "retry_on_failure", false))

    max_depth =
      explicit
      |> Map.get("max_continuation_depth")
      |> positive_integer(default_depth(classification["task_complexity"]))

    %{
      "schema_version" => "holt_agent_run_policy/v1",
      "task_classification" => classification,
      "auto_continue" => auto_continue,
      "continuation_allowed" =>
        continuation_allowed and literal_true?(classification["continuation_allowed"]),
      "retry_on_failure" => retry_on_failure,
      "max_continuation_depth" => max_depth,
      "source" => source(explicit, opts)
    }
  end

  defp default_depth("broad_parallel"), do: 4
  defp default_depth("implementation"), do: 3
  defp default_depth("standard"), do: 2
  defp default_depth(_complexity), do: 1

  defp positive_integer(value, _default) when is_integer(value) and value >= 0, do: value
  defp positive_integer(_value, default), do: default

  defp literal_true?(true), do: true
  defp literal_true?(_value), do: false

  defp policy_map(value) when is_map(value), do: value
  defp policy_map(_value), do: %{}

  defp source(explicit, opts) do
    case Map.get(explicit, "source") do
      source when is_binary(source) and source != "" ->
        source

      _missing ->
        Keyword.get(opts, :source, "task_policy")
    end
  end
end
