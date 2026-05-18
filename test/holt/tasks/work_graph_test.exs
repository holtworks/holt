defmodule Holt.Tasks.WorkGraphTest do
  use ExUnit.Case, async: true

  alias Holt.Tasks.WorkGraph

  describe "build/1" do
    test "builds from canonical task graph nodes" do
      graph =
        WorkGraph.build(%{
          "task" => %{"id" => "task-1", "ref" => "HW-1", "status" => "open"},
          "task_graph" => %{
            "id" => "task-graph-1",
            "nodes" => [
              %{
                "id" => "node-plan",
                "node_key" => "plan",
                "kind" => "plan",
                "status" => "done",
                "position" => 0
              }
            ]
          },
          "verification_gate" => %{"status" => "approved", "can_finish" => true}
        })

      assert graph["schema_version"] == "holt_work_graph/v1"
      assert graph["task_graph_id"] == "task-graph-1"
      assert [%{"node_id" => "node-plan", "phase" => "plan", "order" => 0}] = graph["nodes"]
      assert graph["completion_gate"]["status"] == "approved"
    end

    test "rejects obsolete build aliases" do
      assert %{
               "schema_version" => "holt_work_graph/v1",
               "status" => "rejected",
               "reason" => "obsolete_key:graph"
             } = WorkGraph.build(%{"graph" => %{"id" => "task-graph-1"}})

      assert %{
               "status" => "rejected",
               "reason" => "obsolete_key:child_contracts"
             } = WorkGraph.build(%{"child_contracts" => []})
    end

    test "does not normalize atom-keyed task graph nodes" do
      graph =
        WorkGraph.build(%{
          "task" => %{"id" => "task-1", "ref" => "HW-1"},
          "task_graph" => %{
            "id" => "task-graph-1",
            "nodes" => [%{id: "node-plan", node_key: "plan", kind: "plan", status: "done"}]
          }
        })

      assert graph["status"] == "empty"
      refute Map.has_key?(graph, "nodes")
      assert graph["completion_gate"]["status"] == "blocked"
    end

    test "requires literal verifier_required in child contracts" do
      graph =
        WorkGraph.build(%{
          "task" => %{"id" => "task-1", "ref" => "HW-1"},
          "child_agent_contracts" => [
            %{
              "child_contract_id" => "child-contract-1",
              "child" => %{"child_ref" => "reviewer", "work_role" => "worker"},
              "verification_contract" => %{"verifier_required" => "true"}
            }
          ]
        })

      assert [
               %{
                 "node_id" => "child:child-contract-1",
                 "requires_verifier" => false
               }
               | _rest
             ] = graph["nodes"]
    end

    test "uses canonical agent run ids without runtime id fallback" do
      graph =
        WorkGraph.build(%{
          "task" => %{"id" => "task-1", "ref" => "HW-1"},
          "agent_runs" => [
            %{
              "id" => "agent-run-1",
              "run_id" => "runtime-run-1",
              "lifecycle_state" => "completed",
              "agent_id" => "agent-a",
              "work_role" => "worker"
            },
            %{
              "run_id" => "runtime-run-only",
              "lifecycle_state" => "completed",
              "agent_id" => "agent-b"
            }
          ]
        })

      assert %{
               "node_id" => "agent_run:agent-run-1",
               "agent_run_id" => "agent-run-1",
               "run_id" => "runtime-run-1",
               "status" => "completed"
             } = Enum.find(graph["nodes"], &(&1["kind"] == "child_agent"))

      refute Enum.any?(graph["nodes"], &(&1["node_id"] == "agent_run:runtime-run-only"))
    end

    test "rejects non-map build attrs" do
      assert %{
               "schema_version" => "holt_work_graph/v1",
               "status" => "rejected",
               "reason" => "invalid_attrs"
             } = WorkGraph.build([])
    end
  end

  describe "completion_gate/1" do
    test "approves canonical work graph with satisfied verification gate" do
      gate =
        WorkGraph.completion_gate(%{
          "work_graph" => graph(%{"status" => "completed"}),
          "verification_gate" => %{"status" => "approved", "satisfied" => true}
        })

      assert gate["schema_version"] == "holt_work_graph_completion_gate/v1"
      assert gate["status"] == "approved"
      assert gate["can_finish"] == true
      assert gate["node_count"] == 1
      assert gate["verification_satisfied"] == true
    end

    test "requires literal boolean verification gate fields" do
      gate =
        WorkGraph.completion_gate(%{
          "work_graph" =>
            graph(%{"status" => "completed"}, %{
              "child_contract_count" => 1,
              "verifier_contract_count" => 1
            }),
          "verification_gate" => %{
            "required" => true,
            "satisfied" => "true",
            "can_finish" => "true"
          }
        })

      assert gate["status"] == "blocked"
      assert gate["verification_satisfied"] == false

      assert [%{"code" => "route_verification_review_not_satisfied"}] =
               gate["blockers"]
    end

    test "requires literal prediction error acceptance" do
      gate =
        WorkGraph.completion_gate(%{
          "work_graph" =>
            graph(%{"status" => "completed"}, %{
              "severe_prediction_error_count" => 1
            }),
          "verification_gate" => %{
            "status" => "approved",
            "prediction_error_acceptance" => "accepted",
            "latest_evaluation" => %{"prediction_errors_accepted" => "true"}
          }
        })

      assert gate["status"] == "approved"

      blocked =
        WorkGraph.completion_gate(%{
          "work_graph" =>
            graph(%{"status" => "completed"}, %{
              "severe_prediction_error_count" => 1
            }),
          "verification_gate" => %{
            "status" => "approved",
            "latest_evaluation" => %{"prediction_errors_accepted" => "true"}
          }
        })

      assert blocked["status"] == "blocked"
      assert [%{"code" => "severe_prediction_errors_unaccepted"}] = blocked["blockers"]
    end

    test "rejects obsolete graph alias" do
      assert %{
               "schema_version" => "holt_work_graph_completion_gate/v1",
               "status" => "rejected",
               "reason" => "obsolete_key:graph",
               "can_finish" => false
             } = WorkGraph.completion_gate(%{"graph" => graph(%{"status" => "completed"})})
    end

    test "rejects non-map attrs" do
      assert %{
               "schema_version" => "holt_work_graph_completion_gate/v1",
               "status" => "rejected",
               "reason" => "invalid_attrs",
               "can_finish" => false
             } = WorkGraph.completion_gate([])
    end
  end

  defp graph(node, metrics \\ %{}) do
    %{
      "graph_id" => "graph-1",
      "nodes" => [
        Map.merge(
          %{
            "node_id" => "work",
            "kind" => "child_agent",
            "phase" => "work",
            "required" => true
          },
          node
        )
      ],
      "metrics" =>
        Map.merge(
          %{
            "node_count" => 1,
            "worker_contract_count" => 0,
            "verifier_contract_count" => 0,
            "completed_child_contract_count" => 1,
            "severe_prediction_error_count" => 0
          },
          metrics
        )
    }
  end
end
