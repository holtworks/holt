defmodule Holt.Tasks.AgentRunStateMachineTest do
  use ExUnit.Case, async: true

  alias Holt.Tasks.AgentRunStateMachine

  test "transition rejects unknown states explicitly" do
    assert AgentRunStateMachine.transition(nil, "queued") == {:ok, "queued"}
    assert AgentRunStateMachine.transition("running", "completed") == {:ok, "completed"}

    assert AgentRunStateMachine.transition("unknown", "queued") ==
             {:error, {:invalid_agent_run_state, "unknown"}}

    assert AgentRunStateMachine.transition("running", "unknown") ==
             {:error, {:invalid_agent_run_state, "unknown"}}
  end

  test "terminal state checks are literal" do
    assert AgentRunStateMachine.terminal?("completed")
    refute AgentRunStateMachine.terminal?("unknown")
    refute AgentRunStateMachine.terminal?(:completed)
  end

  test "complete uses canonical continuation_decision" do
    assert AgentRunStateMachine.complete(%{
             "status" => "success",
             "continuation_decision" => %{"action" => "continue"}
           }) == "needs_continuation"

    assert AgentRunStateMachine.complete(%{
             "status" => "success",
             "continuation_decision" => %{"action" => "suppress"}
           }) == "blocked"
  end

  test "complete ignores legacy decision aliases" do
    assert AgentRunStateMachine.complete(%{
             "status" => "success",
             "decision" => %{"action" => "continue"}
           }) == "awaiting_verification"

    assert AgentRunStateMachine.complete(%{
             "status" => "success",
             "continuation_decision" => %{action: "continue"}
           }) == "awaiting_verification"

    assert AgentRunStateMachine.complete(%{
             "status" => "success",
             "continuation_decision" => {:continue, %{}}
           }) == "awaiting_verification"

    assert AgentRunStateMachine.complete(%{
             status: "failed",
             verification_gate: %{"status" => "blocked"}
           }) == "completed"
  end
end
