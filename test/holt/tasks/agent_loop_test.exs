defmodule Holt.Tasks.AgentLoopTest do
  use ExUnit.Case, async: true

  alias Holt.Tasks.AgentLoop

  test "builds loop projection from canonical nested fields" do
    loop =
      AgentLoop.contract(%{
        "task" => %{"id" => "task-1", "ref" => "HW-1", "title" => "Ship"},
        "agent" => %{"agent_id" => "agent-1", "agent_ref" => "A-1"},
        "policy" => %{"max_continuation_depth" => 2, "max_wall_clock_seconds" => 60},
        "decision" => %{"action" => "continue", "depth" => 1},
        "continuation_count" => 1,
        "lifecycle_state" => "running",
        "status" => "running",
        "loop_started_at" => "2026-05-17T12:00:00Z",
        "now" => "2026-05-17T12:00:30Z"
      })

    assert loop["schema_version"] == "holt_agent_loop/v1"
    assert loop["id"] == "task_agent_loop:task-1:agent-1"
    assert loop["task_id"] == "task-1"
    assert loop["task_ref"] == "HW-1"
    assert loop["agent_id"] == "agent-1"
    assert loop["agent_ref"] == "A-1"
    assert loop["iteration"] == 2
    assert loop["continuation_depth"] == 1
    assert loop["next_continuation_depth"] == 1
    assert loop["max_iterations"] == 3
    assert loop["elapsed_seconds"] == 30
    assert loop["expires_at"] == "2026-05-17T12:01:00Z"
  end

  test "does not use legacy task and agent aliases" do
    loop =
      AgentLoop.contract(%{
        "task" => %{"_id" => "legacy-task", "task_ref" => "legacy-ref"},
        "agent" => %{"id" => "legacy-agent", "ref" => "legacy-ref"},
        "task_id" => "top-task",
        "agent_id" => "top-agent",
        "continuation_count" => 0,
        "policy" => %{},
        "decision" => %{"action" => "continue"}
      })

    assert loop["id"] == "task_agent_loop:task:agent"
    refute Map.has_key?(loop, "task_id")
    refute Map.has_key?(loop, "task_ref")
    refute Map.has_key?(loop, "agent_id")
    refute Map.has_key?(loop, "agent_ref")
    assert loop["iteration"] == 1
    assert loop["continuation_depth"] == 0
    refute Map.has_key?(loop, "next_continuation_depth")
    refute Map.has_key?(loop, "max_iterations")
  end

  test "rejects atom-keyed attrs" do
    assert AgentLoop.contract(%{task: %{"id" => "task-1"}}) == %{
             "schema_version" => "holt_agent_loop/v1",
             "status" => "rejected",
             "reason" => "invalid_attrs"
           }
  end

  test "rejects atom-keyed nested maps" do
    assert AgentLoop.contract(%{
             "task" => %{id: "task-1", ref: "HW-1"},
             "agent" => %{agent_id: "agent-1", agent_ref: "A-1"},
             "decision" => %{action: "continue", depth: 1},
             "policy" => %{max_continuation_depth: 2},
             "continuation_count" => 1
           }) == %{
             "schema_version" => "holt_agent_loop/v1",
             "status" => "rejected",
             "reason" => "invalid_field:task"
           }
  end

  test "rejects string numeric fields" do
    assert AgentLoop.contract(%{
             "continuation_count" => "4",
             "policy" => %{"max_continuation_depth" => "8"},
             "decision" => %{"action" => "continue", "depth" => "5"}
           }) == %{
             "schema_version" => "holt_agent_loop/v1",
             "status" => "rejected",
             "reason" => "invalid_field:policy"
           }
  end

  test "rejects non-map attrs" do
    assert AgentLoop.contract([]) == %{
             "schema_version" => "holt_agent_loop/v1",
             "status" => "rejected",
             "reason" => "invalid_attrs"
           }
  end
end
