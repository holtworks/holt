defmodule HoltWorks.Tasks.AgentTaskClassifier do
  @moduledoc """
  Classifies tasks from structured fields for continuation policy.
  """

  def classify(task) when is_map(task) do
    estimate = task["estimate"]
    kind = task["kind"]

    %{
      "schema_version" => "holtworks_task_classification/v1",
      "task_complexity" => task_complexity(kind, estimate),
      "continuation_allowed" => kind in ["task", "epic"],
      "estimate" => estimate,
      "kind" => kind || "task"
    }
  end

  def classify(_task), do: classify(%{})

  defp task_complexity("epic", _estimate), do: "broad_parallel"

  defp task_complexity(_kind, estimate) when is_integer(estimate) and estimate >= 8,
    do: "implementation"

  defp task_complexity(_kind, estimate) when is_integer(estimate) and estimate >= 3,
    do: "standard"

  defp task_complexity(_kind, _estimate), do: "small"
end
