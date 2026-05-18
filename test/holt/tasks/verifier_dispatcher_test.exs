defmodule Holt.Tasks.VerifierDispatcherTest do
  use ExUnit.Case, async: true

  alias Holt.Tasks.VerifierDispatcher

  describe "build/1" do
    test "claims a verifier dispatch from canonical inputs" do
      dispatch =
        VerifierDispatcher.build(%{
          "task" => %{"id" => "task-1", "ref" => "HW-1"},
          "work_graph" => %{"graph_id" => "work-graph-1", "task_graph_id" => "task-graph-1"},
          "work_graph_gate" => %{"status" => "blocked", "can_finish" => false},
          "verification_contract" => %{"required" => true},
          "verifier_assignment" => %{
            "assignment_id" => "assignment-1",
            "assignment_result" => "assigned",
            "work_product_ref" => "work-graph-1",
            "selected_verifier" => %{
              "agent_id" => "agent-verify",
              "execution_mode" => "persisted_agent"
            }
          },
          "evidence_contract" => %{
            "allowed_verifier_actions" => ["get_task"],
            "required_check_groups" => [
              %{"group_id" => "regression", "any_of" => ["regression_check"]}
            ]
          },
          "verifier_route" => %{"route_id" => "route-1"},
          "attempt" => 2,
          "max_attempts" => 4,
          "lease_ms" => 1_000
        })

      assert dispatch["schema_version"] == "holt_verifier_dispatch/v1"
      assert dispatch["status"] == "claimed"
      assert dispatch["route_id"] == "route-1"
      assert dispatch["attempt"] == 2
      assert dispatch["max_attempts"] == 4
      assert dispatch["lease_ms"] == 1_000
      assert dispatch["child_session_id"] == "verifier:HW-1:work-graph-1:route-1"
      assert dispatch["start_agent_work_params"]["task_id"] == "HW-1"
      assert dispatch["start_agent_work_params"]["graph_id"] == "task-graph-1"
      assert dispatch["start_agent_work_params"]["agent_ids"] == ["agent-verify"]
      assert dispatch["started_event"]["child_contract_id"]
    end

    test "rejects obsolete dispatcher aliases" do
      assert %{
               "schema_version" => "holt_verifier_dispatch/v1",
               "status" => "rejected",
               "reason" => "obsolete_key:assignment"
             } = VerifierDispatcher.build(%{"assignment" => %{}})

      assert %{
               "status" => "rejected",
               "reason" => "obsolete_key:route"
             } = VerifierDispatcher.build(%{"route" => %{}})
    end

    test "does not read completion gate from the work graph" do
      dispatch =
        VerifierDispatcher.build(%{
          "task" => %{"id" => "task-1", "ref" => "HW-1"},
          "work_graph" => %{
            "graph_id" => "work-graph-1",
            "completion_gate" => %{"status" => "approved", "can_finish" => true}
          },
          "verification_contract" => %{"required" => true}
        })

      assert dispatch["status"] == "blocked"
      assert dispatch["reason"] == "verifier_assignment_missing"
      refute Map.has_key?(dispatch, "work_graph_gate_status")
    end

    test "rejects string numeric controls" do
      dispatch =
        VerifierDispatcher.build(%{
          "task" => %{"id" => "task-1", "ref" => "HW-1"},
          "work_graph" => %{"graph_id" => "work-graph-1", "task_graph_id" => "task-graph-1"},
          "work_graph_gate" => %{"status" => "blocked"},
          "verification_contract" => %{"required" => true},
          "verifier_assignment" => %{
            "assignment_id" => "assignment-1",
            "assignment_result" => "assigned",
            "selected_verifier" => %{
              "agent_id" => "agent-verify",
              "execution_mode" => "persisted_agent"
            }
          },
          "attempt" => "2",
          "max_attempts" => "4",
          "lease_ms" => "1000"
        })

      assert %{
               "status" => "rejected",
               "reason" => "invalid_attempt"
             } = dispatch
    end

    test "rejects atom-keyed selected verifier payloads" do
      dispatch =
        VerifierDispatcher.build(%{
          "task" => %{"id" => "task-1", "ref" => "HW-1"},
          "work_graph" => %{"graph_id" => "work-graph-1", "task_graph_id" => "task-graph-1"},
          "work_graph_gate" => %{"status" => "blocked"},
          "verification_contract" => %{"required" => true},
          "verifier_assignment" => %{
            "assignment_id" => "assignment-1",
            "assignment_result" => "assigned",
            "selected_verifier" => %{
              agent_id: "agent-verify",
              execution_mode: "persisted_agent"
            }
          }
        })

      assert %{
               "status" => "rejected",
               "reason" => "invalid_attrs"
             } = dispatch
    end
  end
end
