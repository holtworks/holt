defmodule Holt.Tasks.VerifierRoutingTest do
  use ExUnit.Case, async: true

  alias Holt.Tasks.VerifierRouting

  describe "plan/1" do
    test "plans a verifier route from canonical task graph inputs" do
      route =
        VerifierRouting.plan(%{
          "task" => %{"id" => "task-1", "ref" => "HW-1"},
          "task_graph" => %{"id" => "graph-1", "status" => "blocked"},
          "task_graph_gate" => %{
            "status" => "blocked",
            "can_finish" => false,
            "blockers" => [%{"code" => "required_node_incomplete"}]
          },
          "evidence_contract" => %{
            "required_check_groups" => [
              %{"group_id" => "regression", "any_of" => ["regression_check"]}
            ],
            "allowed_verifier_actions" => ["custom_review"]
          },
          "available_agents" => [
            %{"id" => "worker-1", "kind" => "agent", "work_role" => "worker"},
            %{"id" => "verifier-1", "kind" => "agent", "work_role" => "verifier"}
          ]
        })

      assert route["schema_version"] == "holt_verifier_routing/v1"
      assert route["status"] == "requested"
      assert route["trigger_blockers"] == ["required_node_incomplete"]
      assert route["target_agent_id"] == "verifier-1"
      assert route["start_agent_work_params"]["task_id"] == "HW-1"
      assert route["start_agent_work_params"]["graph_id"] == "graph-1"
      assert "custom_review" in route["allowed_actions"]
    end

    test "rejects obsolete graph alias and ignores mission-control fallback" do
      assert %{
               "schema_version" => "holt_verifier_routing/v1",
               "status" => "rejected",
               "reason" => "obsolete_key:graph"
             } = VerifierRouting.plan(%{"graph" => %{"id" => "graph-1"}})

      route =
        VerifierRouting.plan(%{
          "task" => %{"id" => "task-1", "ref" => "HW-1"},
          "task_graph" => %{
            "id" => "graph-1",
            "mission_control" => %{"can_finish" => true}
          }
        })

      assert route["status"] == "requested"
      refute route["status"] == "not_required"
    end

    test "rejects atom-keyed agents" do
      route =
        VerifierRouting.plan(%{
          "task" => %{"id" => "task-1", "ref" => "HW-1"},
          "task_graph" => %{"id" => "graph-1"},
          "task_graph_gate" => %{"can_finish" => false},
          "available_agents" => [
            %{id: "atom-verifier", kind: "agent", work_role: "verifier"},
            %{"id" => "worker-1", "kind" => "agent", "work_role" => "worker"}
          ]
        })

      assert %{
               "status" => "rejected",
               "reason" => "invalid_attrs"
             } = route
    end

    test "rejects malformed available agents" do
      route =
        VerifierRouting.plan(%{
          "task" => %{"id" => "task-1", "ref" => "HW-1"},
          "task_graph" => %{"id" => "graph-1"},
          "task_graph_gate" => %{"can_finish" => false},
          "available_agents" => [
            %{"id" => "verifier-1", "kind" => "person", "work_role" => "verifier"}
          ]
        })

      assert %{
               "status" => "rejected",
               "reason" => "invalid_available_agents"
             } = route
    end

    test "rejects malformed evidence contracts" do
      route =
        VerifierRouting.plan(%{
          "task" => %{"id" => "task-1", "ref" => "HW-1"},
          "task_graph" => %{"id" => "graph-1"},
          "evidence_contract" => %{
            "required_check_groups" => [
              %{"group_id" => "regression", "any_of" => [:regression_check]}
            ]
          }
        })

      assert %{
               "status" => "rejected",
               "reason" => "invalid_evidence_contract"
             } = route
    end
  end
end
