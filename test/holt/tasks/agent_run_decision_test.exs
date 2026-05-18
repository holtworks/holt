defmodule Holt.Tasks.AgentRunDecisionTest do
  use ExUnit.Case, async: true

  alias Holt.Tasks.AgentRunDecision

  test "continues completed runs with canonical policy" do
    decision =
      AgentRunDecision.decide(%{
        "run_status" => "completed",
        "continuation_count" => 1,
        "policy" => %{
          "continuation_allowed" => true,
          "auto_continue" => true,
          "max_continuation_depth" => 3
        },
        "classification" => %{"retryable" => false}
      })

    assert decision["schema_version"] == "holt_continuation_decision/v1"
    assert decision["action"] == "continue"
    assert decision["depth"] == 2
  end

  test "ignores string and atom-shaped policy values" do
    assert %{"action" => "stop", "reason" => "continuation_not_allowed"} =
             AgentRunDecision.decide(%{
               "run_status" => "completed",
               "continuation_count" => "1",
               "policy" => %{
                 "continuation_allowed" => "true",
                 "auto_continue" => "true",
                 "max_continuation_depth" => "3"
               }
             })

    assert %{"action" => "stop", "reason" => "continuation_not_allowed"} =
             AgentRunDecision.decide(%{
               "run_status" => "completed",
               "policy" => %{
                 continuation_allowed: true,
                 auto_continue: true,
                 max_continuation_depth: 3
               }
             })
  end

  test "retries failed runs only with canonical retryable classification" do
    retry =
      AgentRunDecision.decide(%{
        "run_status" => "failed",
        "continuation_count" => 0,
        "policy" => %{
          "continuation_allowed" => true,
          "retry_on_failure" => true,
          "max_continuation_depth" => 1
        },
        "classification" => %{"retryable" => true}
      })

    assert retry["action"] == "continue"
    assert retry["reason"] == "retryable_failure"

    suppressed =
      AgentRunDecision.decide(%{
        "run_status" => "failed",
        "continuation_count" => 0,
        "policy" => %{
          "continuation_allowed" => true,
          "retry_on_failure" => true,
          "max_continuation_depth" => 1
        },
        "classification" => %{retryable: true}
      })

    assert suppressed["action"] == "suppress"
  end
end
