defmodule Holt.Tasks.WorkGraphBudgetTest do
  use ExUnit.Case, async: true

  alias Holt.Tasks.WorkGraphBudget

  test "work graph budget uses canonical budget and candidate fields" do
    budget =
      WorkGraphBudget.build(%{
        "task" => %{"id" => "task-1", "ref" => "HW-1"},
        "work_graph_id" => "graph-1",
        "max_total_tokens" => 80_000,
        "max_concurrent_agents" => 2,
        "candidate_agents" => [
          %{"agent_id" => "agent-1"},
          %{"agent_id" => "agent-2"},
          %{"agent_id" => "agent-3"}
        ]
      })

    assert budget["task_id"] == "task-1"
    assert budget["task_ref"] == "HW-1"
    assert budget["work_graph_id"] == "graph-1"
    assert budget["max_total_tokens"] == 80_000
    assert budget["max_concurrent_agents"] == 2
    assert budget["candidate_agent_count"] == 3
  end

  test "work graph budget applies explicit policy defaults when fields are absent" do
    budget =
      WorkGraphBudget.build(%{
        "candidate_agents" => [
          %{"agent_id" => "agent-1"},
          %{"agent_id" => "agent-2"},
          %{"agent_id" => "agent-3"},
          %{"agent_id" => "agent-4"},
          %{"agent_id" => "agent-5"}
        ]
      })

    assert budget["max_total_tokens"] == 64_000
    assert budget["max_concurrent_agents"] == 4
    assert budget["candidate_agent_count"] == 5
  end

  test "work graph budget rejects legacy budget and candidate aliases" do
    assert %{
             "status" => "rejected",
             "reason" => "unsupported_argument:group_token_budget"
           } = WorkGraphBudget.build(%{"group_token_budget" => 80_000})

    assert %{
             "status" => "rejected",
             "reason" => "unsupported_argument:agents"
           } = WorkGraphBudget.build(%{"agents" => [%{"agent_id" => "legacy-agent"}]})

    assert %{
             "status" => "rejected",
             "reason" => "unsupported_argument:task_id"
           } = WorkGraphBudget.build(%{"task_id" => "task-1"})
  end

  test "rejects atom keys string token counts and non-list candidates" do
    assert %{
             "status" => "rejected",
             "reason" => "invalid_attrs"
           } =
             WorkGraphBudget.build(%{
               :task => %{"id" => "task-1", "ref" => "HW-1"}
             })

    assert %{
             "status" => "rejected",
             "reason" => "invalid_max_total_tokens"
           } = WorkGraphBudget.build(%{"max_total_tokens" => "80000"})

    assert %{
             "status" => "rejected",
             "reason" => "invalid_max_concurrent_agents"
           } = WorkGraphBudget.build(%{"max_concurrent_agents" => "2"})

    assert %{
             "status" => "rejected",
             "reason" => "invalid_candidate_agents"
           } = WorkGraphBudget.build(%{"candidate_agents" => %{"agent_id" => "not-a-list"}})
  end

  test "rejects non-map attrs" do
    assert WorkGraphBudget.build([]) == %{
             "schema_version" => "holt_work_graph_budget/v1",
             "status" => "rejected",
             "reason" => "invalid_attrs"
           }
  end
end
