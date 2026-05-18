defmodule Holt.Tasks.ActionContractTest do
  use ExUnit.Case, async: true

  alias Holt.Tasks.{
    ActionContract,
    ActionPreflight,
    ActionRouter,
    ActionSession,
    CapabilityContract,
    CapabilityRegistry,
    PlanContract,
    PlanGate,
    VerifierCalibration
  }

  test "action contracts read action as the only action field" do
    assert ActionContract.build(%{"action" => "get_task"})["action"] == "get_task"
    assert ActionContract.build(%{"action_name" => "get_task"})["action"] == "unknown"
    assert ActionContract.build(%{"name" => "get_task"})["action"] == "unknown"

    assert ActionContract.build(%{action: "get_task"}) == {:error, :invalid_action_contract}

    assert ActionContract.build(%{
             "action" => "get_task",
             "arguments" => %{task_ref: "HW-1"}
           }) == {:error, :invalid_action_contract}

    assert ActionContract.build(%{"action" => "get_task", "arguments" => "HW-1"}) ==
             {:error, {:invalid_action_contract_field, "arguments"}}
  end

  test "action routes reject old action aliases" do
    session = %{"direct_actions" => ["get_task"], "meta_actions" => []}

    assert %{"status" => "accepted"} =
             ActionRouter.route(%{"action" => "get_task", "action_session" => session})

    assert %{"status" => "rejected", "reason" => "action_required"} =
             ActionRouter.route(%{"action_name" => "get_task", "action_session" => session})

    assert %{"status" => "rejected", "reason" => "invalid_attrs"} =
             ActionRouter.route(%{action: "get_task", action_session: session})

    assert %{"status" => "rejected", "reason" => "unsupported_argument:session"} =
             ActionRouter.route(%{"action" => "get_task", "session" => session})
  end

  test "action routes require canonical argument and session contracts" do
    session = ActionSession.build(%{"disabled_actions" => ["write"]})

    assert %{"status" => "rejected", "reason" => "invalid_arguments"} =
             ActionRouter.route(%{
               "action" => "get_task",
               "arguments" => "HW-1",
               "action_session" => session
             })

    assert %{"status" => "rejected", "reason" => "invalid_action"} =
             ActionRouter.route(%{"action" => :get_task, "action_session" => session})

    assert %{"status" => "rejected", "reason" => "invalid_action_session"} =
             ActionRouter.route(%{"action" => "get_task", "action_session" => "session-1"})

    assert ActionRouter.allowed?("get_task", session) == true
    assert ActionRouter.allowed?(:get_task, session) == false
    assert ActionRouter.allowed?("write", session) == false
  end

  test "workspace durable contracts declare the workspace target" do
    session = ActionSession.build(%{"workspace" => "/tmp/holt-workspace"})

    assert %{"target_refs" => %{"workspace" => "/tmp/holt-workspace"}} =
             ActionContract.build(%{"action" => "run", "action_session" => session})

    refute Map.has_key?(
             ActionContract.build(%{"action" => "get_task", "action_session" => session}),
             "target_refs"
           )
  end

  test "capability contracts read action as the only action field" do
    assert CapabilityContract.build(%{"action" => "get_task"})["required_actions"] == ["get_task"]

    refute Map.has_key?(
             CapabilityContract.build(%{"action_name" => "get_task"}),
             "required_actions"
           )
  end

  test "capability registry does not recover action from attrs" do
    assert %{"action" => "unknown", "registered" => false} =
             CapabilityRegistry.lookup(nil, %{"action_name" => "get_task"})
  end

  test "plan gate and preflight require canonical action_route field" do
    plan_contract = %{
      "plan_id" => "plan-1",
      "status" => "active",
      "allowed_actions" => ["get_task"],
      "allowed_effect_scopes" => ["read_only"],
      "plan_steps" => [
        %{
          "step_id" => "step-1",
          "allowed_actions" => ["get_task"],
          "effect_scope" => "read_only"
        }
      ]
    }

    action_contract = %{
      "contract_id" => "contract-1",
      "action" => "get_task",
      "effect_scope" => "read_only",
      "target_refs" => %{}
    }

    action_route = %{"status" => "accepted", "action_contract" => action_contract}

    assert %{"action" => "approved"} =
             plan_gate =
             PlanGate.evaluate(%{
               "action_route" => action_route,
               "action_contract" => action_contract,
               "plan_contract" => plan_contract
             })

    assert %{"action" => "rejected", "reason" => "unsupported_argument:route"} =
             PlanGate.evaluate(%{
               "route" => action_route,
               "action_contract" => action_contract,
               "plan_contract" => plan_contract
             })

    assert %{"result" => "passed"} =
             ActionPreflight.evaluate(%{
               "action_route" => action_route,
               "action_contract" => action_contract,
               "plan_contract" => plan_contract,
               "plan_gate" => plan_gate
             })

    assert %{
             "result" => "blocked",
             "blocked_checks" => ["action_route_accepted"],
             "checks" => [%{"reason" => "unsupported_argument:route"}]
           } =
             ActionPreflight.evaluate(%{
               "route" => action_route,
               "action_contract" => action_contract,
               "plan_contract" => plan_contract,
               "plan_gate" => plan_gate
             })

    assert %{
             "result" => "blocked",
             "blocked_checks" => ["action_route_accepted"],
             "checks" => [%{"reason" => "invalid_attrs"}]
           } =
             ActionPreflight.evaluate(%{
               action_route: action_route,
               action_contract: action_contract,
               plan_contract: plan_contract,
               plan_gate: plan_gate
             })
  end

  test "plan contracts require explicit task and action session contracts" do
    assert %{
             "schema_version" => "holt_plan_contract/v1",
             "status" => "rejected",
             "reason" => "unsupported_argument:session"
           } =
             PlanContract.build(%{
               "session" => %{
                 "task_id" => "legacy-task",
                 "task_ref" => "HW-LEGACY",
                 "graph_id" => "legacy-graph"
               }
             })

    assert %{
             "status" => "rejected",
             "reason" => "unsupported_argument:task_graph_id"
           } = PlanContract.build(%{"task_graph_id" => "legacy-graph"})

    assert %{
             "status" => "rejected",
             "reason" => "missing_action_session"
           } = PlanContract.build(%{"task" => %{"id" => "task-1", "ref" => "HW-01"}})

    canonical_contract =
      PlanContract.build(%{
        "task" => %{"id" => "task-1", "ref" => "HW-01"},
        "action_session" => %{
          "session_id" => "session-1",
          "task_id" => "task-1",
          "task_ref" => "HW-01",
          "graph_id" => "graph-1",
          "direct_actions" => ["get_task"],
          "meta_actions" => []
        }
      })

    assert canonical_contract["task_id"] == "task-1"
    assert canonical_contract["task_ref"] == "HW-01"
    assert canonical_contract["graph_id"] == "graph-1"
    assert canonical_contract["allowed_actions"] == ["get_task"]
  end

  test "action sessions use graph_id as the only graph field" do
    legacy_session = ActionSession.build(%{"task_graph_id" => "legacy-graph"})

    refute legacy_session["graph_id"] == "legacy-graph"
    refute get_in(legacy_session, ["workbench", "graph_id"]) == "legacy-graph"

    canonical_session = ActionSession.build(%{"graph_id" => "graph-1"})

    assert canonical_session["graph_id"] == "graph-1"
    assert get_in(canonical_session, ["workbench", "graph_id"]) == "graph-1"
  end

  test "verifier calibration rejects legacy verdict input" do
    calibration =
      VerifierCalibration.build(%{
        "verdict" => %{
          "completion_decision" => "auto_finish_allowed",
          "verification_status" => "passed",
          "can_finish" => true
        }
      })

    assert calibration["status"] == "rejected"
    assert calibration["reason"] == "unsupported_argument:verdict"
    refute Map.has_key?(calibration, "verdict")
  end

  test "verifier calibration uses canonical top-level verifier fields" do
    assignment = %{
      "assignment_id" => "assign-1",
      "work_product_ref" => "HW-1",
      "selected_verifier" => %{"agent_id" => "fallback-agent"}
    }

    canonical =
      VerifierCalibration.build(%{
        "verifier_assignment" => assignment,
        "verifier_agent_id" => "agent_verify",
        "verifier_route_id" => "route-1",
        "verifier_child_contract_id" => "child-1",
        "verifier_action_call_id" => "call-1",
        "evaluation" => %{
          "completion_decision" => "auto_finish_allowed",
          "verification_status" => "passed",
          "can_finish" => true,
          "required_reviewers" => ["reviewer-1"],
          "verifier_route_id" => "nested-route",
          "verifier_child_contract_id" => "nested-child",
          "verifier_action_call_id" => "nested-call"
        }
      })

    assert canonical["verifier_agent_id"] == "agent_verify"
    assert canonical["verifier_route_id"] == "route-1"
    assert canonical["verifier_child_contract_id"] == "child-1"
    assert canonical["verifier_action_call_id"] == "call-1"
    assert canonical["verdict"] == "approved"
    assert canonical["required_reviewers"] == ["reviewer-1"]
    refute canonical["verifier_agent_id"] == "fallback-agent"

    nested_only =
      VerifierCalibration.build(%{
        "verifier_assignment" => assignment,
        "evaluation" => %{
          "completion_decision" => "auto_finish_allowed",
          "verification_status" => "passed",
          "can_finish" => true,
          "verifier_route_id" => "nested-route",
          "verifier_child_contract_id" => "nested-child",
          "verifier_action_call_id" => "nested-call"
        }
      })

    refute Map.has_key?(nested_only, "verifier_agent_id")
    refute Map.has_key?(nested_only, "verifier_route_id")
    refute Map.has_key?(nested_only, "verifier_child_contract_id")
    refute Map.has_key?(nested_only, "verifier_action_call_id")
  end
end
