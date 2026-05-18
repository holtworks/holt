defmodule Holt.Tasks.AgentTaskClassifierTest do
  use ExUnit.Case, async: true

  alias Holt.Tasks.AgentTaskClassifier

  test "classifies canonical task fields" do
    assert %{
             "schema_version" => "holt_task_classification/v1",
             "task_complexity" => "implementation",
             "continuation_allowed" => true,
             "estimate" => 8,
             "kind" => "task"
           } = AgentTaskClassifier.classify(%{"kind" => "task", "estimate" => 8})

    assert %{
             "task_complexity" => "broad_parallel",
             "continuation_allowed" => true,
             "kind" => "epic"
           } = AgentTaskClassifier.classify(%{"kind" => "epic"})
  end

  test "defaults missing kind explicitly" do
    assert %{"kind" => "task", "continuation_allowed" => false} =
             AgentTaskClassifier.classify(%{})
  end

  test "does not parse string estimates" do
    assert %{"task_complexity" => "small", "estimate" => "8"} =
             AgentTaskClassifier.classify(%{"kind" => "task", "estimate" => "8"})
  end
end
