defmodule Holt.Tasks.AgentRunFailureClassifierTest do
  use ExUnit.Case, async: true

  alias Holt.Tasks.AgentRunFailureClassifier

  test "classifies completed runs" do
    assert %{
             "schema_version" => "holt_run_failure_classification/v1",
             "status" => "completed",
             "failure_class" => nil,
             "blocker_code" => nil,
             "retryable" => false,
             "reason" => nil
           } = AgentRunFailureClassifier.classify(%{"status" => "completed"})
  end

  test "uses explicit blocked failure fields" do
    classification =
      AgentRunFailureClassifier.classify(%{
        "status" => "blocked",
        "failure_class" => "policy_block",
        "blocker_code" => "approval_required",
        "blocked_reason" => "Needs approval"
      })

    assert classification["status"] == "blocked"
    assert classification["failure_class"] == "policy_block"
    assert classification["blocker_code"] == "approval_required"
    assert classification["retryable"] == false
    assert classification["reason"] == "Needs approval"
  end

  test "uses explicit failed failure fields" do
    classification =
      AgentRunFailureClassifier.classify(%{
        "status" => "failed",
        "failure_class" => "runtime_failure",
        "blocker_code" => "command_failed",
        "failure_reason" => "exit 1"
      })

    assert classification["status"] == "failed"
    assert classification["failure_class"] == "runtime_failure"
    assert classification["blocker_code"] == "command_failed"
    assert classification["retryable"] == true
    assert classification["reason"] == "exit 1"
  end

  test "ignores atom-shaped failure fields" do
    classification =
      AgentRunFailureClassifier.classify(%{
        "status" => "blocked",
        failure_class: "policy_block",
        blocker_code: "approval_required",
        blocked_reason: "Needs approval"
      })

    assert classification["failure_class"] == "blocked"
    assert classification["blocker_code"] == "external_blocker"
    assert classification["reason"] == "nil"
  end
end
