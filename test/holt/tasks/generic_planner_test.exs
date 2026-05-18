defmodule Holt.Tasks.GenericPlannerTest do
  use ExUnit.Case, async: true

  alias Holt.Tasks.GenericPlanner

  test "builds a canonical five-phase graph" do
    assert %{
             "schema_version" => "holt_generic_work_graph/v1",
             "task_id" => "task-1",
             "task_ref" => "HW-1",
             "plan_contract_id" => "plan-1",
             "node_types" => ["research", "propose", "act", "verify", "repair"],
             "nodes" => nodes
           } =
             GenericPlanner.build(%{
               "task" => %{"id" => "task-1", "ref" => "HW-1"},
               "plan_contract" => %{"plan_id" => "plan-1"},
               "workflow_constraints" => %{
                 "workflow" => "local_agent",
                 "directory" => "/workspace",
                 "test_commands" => ["mix test"]
               },
               "evidence_contract" => %{"contract_id" => "evidence-1"}
             })

    assert Enum.map(nodes, & &1["phase"]) == ~w(research propose act verify repair)
    assert node(nodes, "research")["status"] == "scheduled"
    assert node(nodes, "research")["constraints"]["workflow"] == "local_agent"
    assert node(nodes, "act")["constraints"]["directory"] == "/workspace"
    assert node(nodes, "verify")["constraints"]["test_commands"] == ["mix test"]

    assert node(nodes, "verify")["constraints"]["evidence_contract"] == %{
             "contract_id" => "evidence-1"
           }
  end

  test "filters actions from the canonical plan contract only" do
    plan =
      GenericPlanner.build(%{
        "allowed_actions" => ["write"],
        "plan_contract" => %{
          "plan_id" => "plan-1",
          "allowed_actions" => ["get_task", "route_verification_review"]
        }
      })

    nodes = plan["nodes"]

    assert node(nodes, "research")["allowed_actions"] == ["get_task"]
    assert node(nodes, "verify")["allowed_actions"] == ["get_task", "route_verification_review"]
    refute Map.has_key?(node(nodes, "act"), "allowed_actions")
  end

  test "does not use top-level allowed actions without a plan contract" do
    plan = GenericPlanner.build(%{"allowed_actions" => ["get_task"]})

    assert "write" in node(plan["nodes"], "act")["allowed_actions"]
    assert "get_task" in node(plan["nodes"], "research")["allowed_actions"]
  end

  test "rejects atom-keyed top-level attrs" do
    assert %{
             "schema_version" => "holt_generic_work_graph/v1",
             "status" => "rejected",
             "reason" => "invalid_attrs"
           } = GenericPlanner.build(%{task: %{"id" => "task-1"}})
  end

  test "rejects atom-keyed nested plan contracts" do
    assert %{
             "status" => "rejected",
             "reason" => "invalid_plan_contract"
           } = GenericPlanner.build(%{"plan_contract" => %{plan_id: "plan-1"}})
  end

  test "rejects invalid plan contract action lists" do
    assert %{
             "status" => "rejected",
             "reason" => "invalid_plan_contract"
           } =
             GenericPlanner.build(%{
               "plan_contract" => %{
                 "plan_id" => "plan-1",
                 "allowed_actions" => ["get_task", ""]
               }
             })
  end

  defp node(nodes, phase), do: Enum.find(nodes, &(&1["phase"] == phase))
end
