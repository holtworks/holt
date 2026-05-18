defmodule Holt.RuntimeEventsTest do
  use ExUnit.Case, async: true

  alias Holt.Paths
  alias Holt.Runtime.{AgentEvents, EventRecorder}

  @moduletag :tmp_dir

  setup %{tmp_dir: workspace} do
    Paths.ensure_workspace(workspace)
    %{workspace: workspace}
  end

  test "agent events use only canonical agent_id option", %{workspace: workspace} do
    assert {:ok, event} =
             AgentEvents.append("session-1", "user_message", %{},
               workspace: workspace,
               agent: "legacy"
             )

    refute Map.has_key?(event, "agent_id")

    assert {:ok, event} =
             AgentEvents.append("session-1", "user_message", %{},
               workspace: workspace,
               agent_id: "agent-1"
             )

    assert event["agent_id"] == "agent-1"
  end

  test "session summaries use payload action as the action source", %{workspace: workspace} do
    assert {:ok, _event} =
             AgentEvents.append("session-2", "action_result", %{},
               workspace: workspace,
               action_call_id: "call_read"
             )

    assert {:ok, summary} = AgentEvents.get_session_summary("session-2", workspace: workspace)
    assert summary["actions"] == []

    assert {:ok, _event} =
             AgentEvents.append("session-2", "action_result", %{"action" => "read"},
               workspace: workspace,
               action_call_id: "call_read"
             )

    assert {:ok, summary} = AgentEvents.get_session_summary("session-2", workspace: workspace)
    assert summary["actions"] == ["read"]
  end

  test "event recorder does not recover status from atom-keyed maps", %{workspace: workspace} do
    assert {:ok, event} =
             EventRecorder.action_result("session-3", "read", %{status: "ok"},
               workspace: workspace,
               action_call_id: "call_read"
             )

    assert event["status"] == "completed"
    assert event["payload"]["status"] == "completed"

    assert {:ok, event} =
             EventRecorder.action_result("session-3", "read", %{"status" => "ok"},
               workspace: workspace,
               action_call_id: "call_read"
             )

    assert event["status"] == "ok"
    assert event["payload"]["status"] == "ok"
  end
end
