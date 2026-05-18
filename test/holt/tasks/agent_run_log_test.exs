defmodule Holt.Tasks.AgentRunLogTest do
  use ExUnit.Case

  alias Holt.{Config, Workspace}
  alias Holt.Tasks
  alias Holt.Tasks.AgentRuns

  test "records action events from canonical fields" do
    %{workspace: workspace, run: run} = run_fixture()

    assert {:ok, _updated_run, event} =
             Tasks.record_agent_run_action_event(
               run["id"],
               %{
                 "action" => "read",
                 "action_call_id" => "call-1",
                 "result" => %{"status" => "ok", "content" => "done"}
               },
               workspace: workspace
             )

    assert event["kind"] == "action.completed"
    assert event["metadata"]["action"] == "read"
    assert event["metadata"]["action_call_id"] == "call-1"
    assert event["metadata"]["status"] == "ok"
  end

  test "rejects action event aliases" do
    %{workspace: workspace, run: run} = run_fixture()

    assert Tasks.record_agent_run_action_event(
             run["id"],
             %{
               "action_name" => "read",
               "action_call_id" => "call-1",
               "result" => %{"status" => "ok"}
             },
             workspace: workspace
           ) == {:error, {:missing_required, "action"}}

    assert Tasks.record_agent_run_action_event(
             run["id"],
             %{"action" => "read", "call_id" => "call-1", "result" => %{"status" => "ok"}},
             workspace: workspace
           ) == {:error, {:missing_required, "action_call_id"}}

    assert Tasks.record_agent_run_action_event(
             run["id"],
             %{"action" => "read", "action_call_id" => "call-1", "result_status" => "ok"},
             workspace: workspace
           ) == {:error, {:missing_required, "result"}}

    assert Tasks.record_agent_run_action_event(
             run["id"],
             %{action: "read", action_call_id: "call-1", result: %{"status" => "ok"}},
             workspace: workspace
           ) == {:error, :invalid_attrs}

    assert Tasks.record_agent_run_action_event(
             run["id"],
             %{"action" => "read", "action_call_id" => "call-1", "result" => %{status: "ok"}},
             workspace: workspace
           ) == {:error, :invalid_attrs}
  end

  test "narration requires canonical body" do
    %{workspace: workspace, run: run} = run_fixture()

    assert {:ok, _updated_run, event} =
             Tasks.record_agent_run_narration(
               run["id"],
               %{"body" => "Thinking through the task."},
               workspace: workspace
             )

    assert event["metadata"]["body_preview"] == "Thinking through the task."

    assert Tasks.record_agent_run_narration(
             run["id"],
             %{"content" => "old field"},
             workspace: workspace
           ) == {:error, {:missing_required, "body"}}
  end

  test "child completion requires canonical identifiers and explicit status" do
    %{workspace: workspace, run: run} = run_fixture()

    assert {:ok, _updated_run, event} =
             Tasks.record_agent_run_child_completion(
               run["id"],
               %{
                 "child_agent_id" => "agent-child",
                 "child_run_id" => "child-run-1",
                 "status" => "completed",
                 "message" => "Child completed."
               },
               workspace: workspace
             )

    assert event["kind"] == "child_agent.completed"
    assert event["metadata"]["child_agent_id"] == "agent-child"
    assert event["metadata"]["child_run_id"] == "child-run-1"
    assert event["metadata"]["status"] == "completed"

    assert Tasks.record_agent_run_child_completion(
             run["id"],
             %{
               "agent_id" => "agent-child",
               "child_run_id" => "child-run-1",
               "status" => "completed",
               "message" => "Child completed."
             },
             workspace: workspace
           ) ==
             {:error, {:obsolete_child_completion_key, "agent_id", "child_agent_id"}}

    assert Tasks.record_agent_run_child_completion(
             run["id"],
             %{
               "child_agent_id" => "agent-child",
               "run_id" => "child-run-1",
               "status" => "completed",
               "message" => "Child completed."
             },
             workspace: workspace
           ) ==
             {:error, {:obsolete_child_completion_key, "run_id", "child_run_id"}}

    assert Tasks.record_agent_run_child_completion(
             run["id"],
             %{
               "child_agent_id" => "agent-child",
               "child_run_id" => "child-run-1",
               "message" => "Child completed."
             },
             workspace: workspace
           ) == {:error, {:missing_required, "status"}}
  end

  test "continuation packet event requires a canonical packet" do
    %{workspace: workspace, run: run} = run_fixture()

    assert {:ok, _updated_run, event} =
             Tasks.record_agent_run_continuation_packet(
               run["id"],
               continuation_packet(run["id"]),
               workspace: workspace
             )

    assert event["kind"] == "agent_run.continuation_packet"
    assert event["metadata"]["packet"]["packet_id"] == "packet-1"

    assert Tasks.record_agent_run_continuation_packet(
             run["id"],
             %{
               schema_version: "holt_continuation_packet/v1",
               packet_id: "packet-1",
               previous_agent_run_id: run["id"],
               continuation_depth: 1,
               source: "test"
             },
             workspace: workspace
           ) == {:error, :invalid_continuation_packet}

    assert Tasks.record_agent_run_continuation_packet(
             run["id"],
             Map.delete(continuation_packet(run["id"]), "packet_id"),
             workspace: workspace
           ) == {:error, {:missing_required, "packet_id"}}

    assert Tasks.record_agent_run_continuation_packet(
             run["id"],
             Map.put(continuation_packet(run["id"]), "continuation_depth", "1"),
             workspace: workspace
           ) == {:error, {:invalid_integer, "continuation_depth"}}
  end

  test "objective evaluation requires canonical route status and message" do
    %{workspace: workspace, run: run} = run_fixture()

    assert {:ok, _updated_run, event} =
             Tasks.record_agent_run_objective_evaluation(
               run["id"],
               %{
                 "route" => %{"route_id" => "route-1", "can_finish" => true},
                 "verification_status" => "passed",
                 "message" => "Objective passed."
               },
               workspace: workspace
             )

    assert event["kind"] == "objective.evaluated"
    assert event["metadata"]["verification_status"] == "passed"
    assert event["message"] == "Objective passed."

    assert Tasks.record_agent_run_objective_evaluation(
             run["id"],
             %{
               route: %{"route_id" => "route-1", "can_finish" => true},
               verification_status: "passed",
               message: "Objective passed."
             },
             workspace: workspace
           ) == {:error, :invalid_attrs}

    assert Tasks.record_agent_run_objective_evaluation(
             run["id"],
             %{
               "route" => %{"route_id" => "route-1", "verification_status" => "passed"},
               "message" => "Objective passed."
             },
             workspace: workspace
           ) == {:error, {:missing_required, "verification_status"}}

    assert Tasks.record_agent_run_objective_evaluation(
             run["id"],
             %{
               "route" => %{"route_id" => "route-1", can_finish: true},
               "verification_status" => "passed",
               "message" => "Objective passed."
             },
             workspace: workspace
           ) == {:error, :invalid_attrs}
  end

  defp run_fixture do
    %{home: home, workspace: workspace} = tmp_env()
    Config.bootstrap(home: home)
    Workspace.init(workspace)

    assert {:ok, task} =
             Tasks.create(%{"title" => "Agent run log contract"}, workspace: workspace)

    assert {:ok, run} =
             AgentRuns.record_queued(workspace, task, %{
               "id" => "work-1",
               "agent_id" => "agent-1",
               "message" => "Queued for log tests."
             })

    %{workspace: workspace, run: run}
  end

  defp continuation_packet(agent_run_id) do
    %{
      "schema_version" => "holt_continuation_packet/v1",
      "packet_id" => "packet-1",
      "previous_agent_run_id" => agent_run_id,
      "continuation_depth" => 1,
      "source" => "test"
    }
  end

  defp tmp_env do
    base = Path.join(System.tmp_dir!(), "holtworks-test-#{System.unique_integer([:positive])}")
    home = Path.join(base, "home")
    workspace = Path.join(base, "workspace")
    File.mkdir_p!(workspace)

    on_exit(fn -> File.rm_rf!(base) end)

    %{home: home, workspace: workspace}
  end
end
