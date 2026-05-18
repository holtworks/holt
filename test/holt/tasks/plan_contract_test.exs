defmodule Holt.Tasks.PlanContractTest do
  use ExUnit.Case, async: true

  alias Holt.Tasks.PlanContract

  test "builds from explicit task and action session contracts" do
    plan =
      PlanContract.build(%{
        "task" => task(),
        "action_session" => session(),
        "allow_workspace_durable" => true,
        "allowed_actions" => ["get_task", "run"],
        "plan_steps" => [
          %{
            "step_id" => "workspace-step",
            "effect_scope" => "workspace_durable",
            "allowed_actions" => ["run"]
          }
        ]
      })

    assert %{
             "schema_version" => "holt_plan_contract/v1",
             "task_id" => "task-1",
             "task_ref" => "HW-1",
             "graph_id" => "graph-1",
             "action_session_id" => "session-1",
             "allowed_actions" => ["get_task", "run"],
             "plan_steps" => [
               %{
                 "step_id" => "workspace-step",
                 "effect_scope" => "workspace_durable",
                 "allowed_actions" => ["run"]
               }
             ]
           } = plan
  end

  test "requires explicit task and action session" do
    assert %{
             "status" => "rejected",
             "reason" => "missing_task"
           } = PlanContract.build(%{"action_session" => session()})

    assert %{
             "status" => "rejected",
             "reason" => "missing_action_session"
           } = PlanContract.build(%{"task" => task()})
  end

  test "rejects legacy aliases and atom-keyed nested data" do
    assert %{
             "status" => "rejected",
             "reason" => "unsupported_argument:graph_id"
           } =
             PlanContract.build(%{
               "task" => task(),
               "action_session" => session(),
               "graph_id" => "legacy-graph"
             })

    assert %{
             "status" => "rejected",
             "reason" => "invalid_attrs"
           } =
             PlanContract.build(%{
               "task" => %{id: "task-1", ref: "HW-1"},
               "action_session" => session()
             })
  end

  test "rejects invalid explicit fields" do
    assert %{
             "status" => "rejected",
             "reason" => "invalid_allowed_actions"
           } =
             PlanContract.build(%{
               "task" => task(),
               "action_session" => session(),
               "allowed_actions" => "get_task"
             })

    assert %{
             "status" => "rejected",
             "reason" => "invalid_allow_workspace_durable"
           } =
             PlanContract.build(%{
               "task" => task(),
               "action_session" => session(),
               "allow_workspace_durable" => "true"
             })

    assert %{
             "status" => "rejected",
             "reason" => "invalid_plan_steps"
           } =
             PlanContract.build(%{
               "task" => task(),
               "action_session" => session(),
               "plan_steps" => [%{"step_id" => "step-1"}]
             })
  end

  test "rejects non-map attrs" do
    assert %{
             "schema_version" => "holt_plan_contract/v1",
             "status" => "rejected",
             "reason" => "invalid_attrs"
           } = PlanContract.build([])
  end

  defp task do
    %{"id" => "task-1", "ref" => "HW-1"}
  end

  defp session do
    %{
      "session_id" => "session-1",
      "graph_id" => "graph-1",
      "policy_profile" => "standard",
      "direct_actions" => ["get_task", "run"],
      "meta_actions" => []
    }
  end
end
