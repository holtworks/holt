defmodule Holt.Tasks.ChildAgentContractTest do
  use ExUnit.Case, async: true

  alias Holt.Tasks.ChildAgentContract

  test "build reads child fields from canonical arguments" do
    contract =
      ChildAgentContract.build(%{
        "action" => "invoke_agent",
        "arguments" => %{
          "child_ref" => "agent-1",
          "target_agent_id" => "agent-1",
          "target_skill" => "planning",
          "work_role" => "planner"
        }
      })

    assert contract["action"] == "invoke_agent"
    assert contract["child"]["child_ref"] == "agent-1"
    assert contract["child"]["target_agent_id"] == "agent-1"
    assert contract["child"]["work_role"] == "planner"
  end

  test "build does not recover child fields from top-level aliases" do
    contract =
      ChildAgentContract.build(%{
        "action" => "invoke_agent",
        "agent_id" => "agent-1",
        "target_agent_id" => "agent-1",
        "arguments" => %{"role" => "planner"}
      })

    refute Map.has_key?(contract["child"], "child_ref")
    refute Map.has_key?(contract["child"], "target_agent_id")
    assert contract["child"]["work_role"] == "worker"
  end

  test "build rejects atom keyed contract input" do
    assert ChildAgentContract.build(%{
             action: "invoke_agent",
             arguments: %{"target_agent_id" => "agent-1"}
           }) == {:error, :invalid_child_agent_contract}

    assert ChildAgentContract.build(%{
             "action" => "invoke_agent",
             "arguments" => %{target_agent_id: "agent-1"}
           }) == {:error, :invalid_child_agent_contract}
  end

  test "build rejects invalid field shapes instead of inferring around them" do
    assert ChildAgentContract.build(%{
             "action" => "invoke_agent",
             "arguments" => %{"allowed_actions" => "read"}
           }) == {:error, {:invalid_child_agent_field, "allowed_actions"}}

    assert ChildAgentContract.build(%{
             "action" => "invoke_agent",
             "arguments" => %{"work_role" => "manager", "target_skill" => "task.validate"}
           }) == {:error, {:invalid_child_agent_field, "work_role"}}
  end
end
