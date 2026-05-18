defmodule Holt.Tasks.WorkGraphSchedulerTest do
  use ExUnit.Case, async: true

  alias Holt.Tasks.WorkGraphScheduler

  describe "schedule/1" do
    test "schedules canonical work graph nodes by dependency state" do
      schedule =
        WorkGraphScheduler.schedule(%{
          "work_graph" => graph(),
          "verification_gate" => %{"status" => "blocked", "can_finish" => false}
        })

      assert schedule["schema_version"] == "holt_work_graph_schedule/v1"
      assert schedule["graph_id"] == "graph-1"
      assert schedule["status"] == "ready"
      assert schedule["verification_hold"] == true
      assert [%{"node_id" => "plan", "schedule_status" => "ready"}] = schedule["ready_nodes"]
      assert Enum.map(schedule["waiting_nodes"], & &1["node_id"]) == ["work", "finish"]
    end

    test "holds integration nodes when the canonical completion gate is blocked" do
      schedule =
        WorkGraphScheduler.schedule(%{
          "work_graph" => graph(),
          "completed_node_ids" => ["plan", "work"],
          "verification_gate" => %{"status" => "blocked", "can_finish" => false}
        })

      assert schedule["status"] == "waiting"
      assert schedule["verification_hold"] == true

      assert [%{"node_id" => "finish", "schedule_reason" => "waiting_for_verification"}] =
               schedule["waiting_nodes"]
    end

    test "uses policy decision action as the approval hold contract" do
      held =
        WorkGraphScheduler.schedule(%{
          "work_graph" => single_work_node_graph(),
          "policy_decision" => %{"action" => "approval_required", "requires_approval" => true}
        })

      assert held["policy_hold"] == true
      assert [%{"schedule_reason" => "waiting_for_human_approval"}] = held["waiting_nodes"]

      not_held =
        WorkGraphScheduler.schedule(%{
          "work_graph" => single_work_node_graph(),
          "policy_decision" => %{"requires_approval" => true}
        })

      assert not_held["policy_hold"] == false
      assert [%{"node_id" => "work", "schedule_status" => "ready"}] = not_held["ready_nodes"]
    end

    test "requires literal repair booleans" do
      held =
        WorkGraphScheduler.schedule(%{
          "work_graph" => single_work_node_graph(),
          "repair_orchestration" => %{
            "repair_required" => true,
            "resume_gate" => %{"can_resume" => false}
          }
        })

      assert held["repair_hold"] == true

      assert [%{"schedule_reason" => "repair_resume_gate_not_satisfied"}] =
               held["blocked_nodes"]

      not_held =
        WorkGraphScheduler.schedule(%{
          "work_graph" => single_work_node_graph(),
          "repair_orchestration" => %{
            "repair_required" => "true",
            "resume_gate" => %{"can_resume" => "false"}
          }
        })

      assert %{
               "status" => "rejected",
               "reason" => "invalid_repair_orchestration"
             } = not_held
    end

    test "rejects obsolete graph aliases" do
      assert %{
               "schema_version" => "holt_work_graph_schedule/v1",
               "status" => "rejected",
               "reason" => "obsolete_key:graph"
             } = WorkGraphScheduler.schedule(%{"graph" => graph()})

      assert %{
               "status" => "rejected",
               "reason" => "obsolete_key:task_graph"
             } = WorkGraphScheduler.schedule(%{"task_graph" => graph()})
    end

    test "rejects atom-keyed nodes" do
      assert %{
               "status" => "rejected",
               "reason" => "invalid_attrs"
             } =
               WorkGraphScheduler.schedule(%{
                 "work_graph" => %{
                   "graph_id" => "graph-1",
                   "nodes" => [%{node_id: "work", phase: "work", status: "pending"}]
                 }
               })
    end

    test "rejects unsupported and malformed scheduler inputs" do
      assert %{
               "status" => "rejected",
               "reason" => "missing_work_graph"
             } = WorkGraphScheduler.schedule(%{})

      assert %{
               "status" => "rejected",
               "reason" => "unsupported_argument:graph_id"
             } = WorkGraphScheduler.schedule(%{"work_graph" => graph(), "graph_id" => "graph-1"})

      assert %{
               "status" => "rejected",
               "reason" => "invalid_completed_node_ids"
             } =
               WorkGraphScheduler.schedule(%{
                 "work_graph" => graph(),
                 "completed_node_ids" => ["plan", 1]
               })

      assert %{
               "status" => "rejected",
               "reason" => "invalid_node_statuses"
             } =
               WorkGraphScheduler.schedule(%{
                 "work_graph" => graph(),
                 "node_statuses" => %{"plan" => true}
               })
    end

    test "rejects non-map attrs" do
      assert %{
               "schema_version" => "holt_work_graph_schedule/v1",
               "status" => "rejected",
               "reason" => "invalid_attrs"
             } = WorkGraphScheduler.schedule([])
    end
  end

  defp graph do
    %{
      "graph_id" => "graph-1",
      "nodes" => [
        %{"node_id" => "plan", "node_key" => "plan", "phase" => "plan", "status" => "pending"},
        %{"node_id" => "work", "node_key" => "work", "phase" => "work", "status" => "pending"},
        %{
          "node_id" => "finish",
          "node_key" => "finish",
          "phase" => "integration",
          "status" => "pending"
        }
      ],
      "edges" => [
        %{"from" => "plan", "to" => "work"},
        %{"from" => "work", "to" => "finish"}
      ]
    }
  end

  defp single_work_node_graph do
    %{
      "graph_id" => "graph-2",
      "nodes" => [
        %{"node_id" => "work", "node_key" => "work", "phase" => "work", "status" => "pending"}
      ]
    }
  end
end
