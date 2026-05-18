defmodule Holt.Tasks.TeamOrchestrationTest do
  use ExUnit.Case, async: true

  alias Holt.Tasks.TeamOrchestration

  test "uses canonical task complexity when present" do
    assert %{
             "schema_version" => "holt_team_orchestration/v1",
             "task_complexity" => "implementation",
             "mode" => "execute_verify_fix",
             "max_concurrent_agents" => 1
           } = TeamOrchestration.plan(%{"task_complexity" => "implementation"})
  end

  test "derives broad parallel mode from integer estimate" do
    assert %{
             "task_complexity" => "broad_parallel",
             "mode" => "planner_executor_verifier_team",
             "max_concurrent_agents" => 4
           } = TeamOrchestration.plan(%{"estimate" => 8})
  end

  test "rejects non-canonical attrs and estimate values" do
    assert %{
             "schema_version" => "holt_team_orchestration/v1",
             "status" => "rejected",
             "reason" => "invalid_attrs"
           } = TeamOrchestration.plan(%{:task_complexity => "broad_parallel", "estimate" => 8})

    assert %{
             "status" => "rejected",
             "reason" => "invalid_estimate"
           } = TeamOrchestration.plan(%{"estimate" => "8"})
  end

  test "rejects invalid explicit complexity" do
    assert %{
             "schema_version" => "holt_team_orchestration/v1",
             "status" => "rejected",
             "reason" => "invalid_task_complexity"
           } = TeamOrchestration.plan(%{"task_complexity" => "large"})
  end

  test "rejects non-map attrs" do
    assert TeamOrchestration.plan([]) == %{
             "schema_version" => "holt_team_orchestration/v1",
             "status" => "rejected",
             "reason" => "invalid_attrs"
           }
  end
end
