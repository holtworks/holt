defmodule Holt.Tasks.AgentDispatchTest do
  use ExUnit.Case, async: true

  alias Holt.Tasks.AgentDispatch

  test "dispatch reads candidates limits and budget from canonical fields" do
    dispatch =
      AgentDispatch.plan(%{
        "task" => %{"id" => "task-1", "ref" => "HW-1"},
        "event" => %{"event_kind" => "start_agent_work", "source" => "test"},
        "candidate_agents" => [
          %{"agent_id" => "agent-1", "display_name" => "Agent One"},
          %{"agent_id" => "agent-2", "display_name" => "Agent Two"}
        ],
        "max_agents_per_event" => 1,
        "group_token_budget" => 80_000
      })

    assert dispatch["task_id"] == "task-1"
    assert dispatch["task_ref"] == "HW-1"
    assert dispatch["selected_agent_ids"] == ["agent-1"]
    assert dispatch["suppressed_count"] == 1
    assert dispatch["group_token_budget"] == 80_000
    assert dispatch["group_budget"]["max_total_tokens"] == 80_000
  end

  test "dispatch suppresses active and overflow candidates with explicit reasons" do
    dispatch =
      AgentDispatch.plan(%{
        "candidate_agents" => [
          %{"agent_id" => "agent-1"},
          %{"agent_id" => "agent-2"},
          %{"agent_id" => "agent-3"}
        ],
        "active_agent_ids" => ["agent-2"],
        "max_agents_per_event" => 1
      })

    assert dispatch["selected_agent_ids"] == ["agent-1"]

    assert [
             %{"agent_id" => "agent-2", "reason" => "agent_work_already_active"},
             %{"agent_id" => "agent-3", "reason" => "dispatch_cap_reached"}
           ] = dispatch["suppressed_agents"]
  end

  test "dispatch rejects legacy aliases instead of ignoring them" do
    assert %{
             "status" => "rejected",
             "reason" => "unsupported_argument:agents"
           } = AgentDispatch.plan(%{"agents" => [%{"agent_id" => "legacy-agent"}]})

    assert %{
             "status" => "rejected",
             "reason" => "unsupported_argument:max_agents"
           } = AgentDispatch.plan(%{"max_agents" => 1})

    assert %{
             "status" => "rejected",
             "reason" => "unsupported_argument:task_id"
           } = AgentDispatch.plan(%{"task_id" => "task-1"})
  end

  test "dispatch rejects invalid candidates and non-canonical attrs" do
    assert %{
             "status" => "rejected",
             "reason" => "invalid_candidate_agents"
           } =
             AgentDispatch.plan(%{
               "candidate_agents" => [
                 %{"id" => "legacy-id", "display_name" => "Legacy"}
               ]
             })

    assert %{
             "status" => "rejected",
             "reason" => "invalid_attrs"
           } = AgentDispatch.plan(%{candidate_agents: [%{"agent_id" => "agent-1"}]})
  end

  test "dispatch rejects string limits and invalid active ids" do
    assert %{
             "status" => "rejected",
             "reason" => "invalid_max_agents_per_event"
           } =
             AgentDispatch.plan(%{
               "candidate_agents" => [%{"agent_id" => "agent-1"}],
               "max_agents_per_event" => "1"
             })

    assert %{
             "status" => "rejected",
             "reason" => "invalid_group_token_budget"
           } =
             AgentDispatch.plan(%{
               "candidate_agents" => [%{"agent_id" => "agent-1"}],
               "group_token_budget" => "80000"
             })

    assert %{
             "status" => "rejected",
             "reason" => "invalid_active_agent_ids"
           } =
             AgentDispatch.plan(%{
               "candidate_agents" => [%{"agent_id" => "agent-1"}],
               "active_agent_ids" => ["agent-1", 2]
             })
  end

  test "selected agent ids returns only explicit string ids" do
    assert AgentDispatch.selected_agent_ids(%{"selected_agent_ids" => ["agent-1", "", 2]}) == [
             "agent-1"
           ]

    assert AgentDispatch.selected_agent_ids(%{selected_agent_ids: ["agent-1"]}) == []
  end
end
