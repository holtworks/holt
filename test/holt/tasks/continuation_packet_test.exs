defmodule Holt.Tasks.ContinuationPacketTest do
  use ExUnit.Case, async: true

  alias Holt.Tasks.ContinuationPacket

  test "builds packet from canonical continuation fields" do
    packet =
      ContinuationPacket.build(%{
        "packet_id" => "packet-1",
        "source" => "task_agent_continuation",
        "continuation_depth" => 2,
        "task" => %{"id" => "task-1", "ref" => "HW-1"},
        "agent_work" => %{
          "id" => "work-1",
          "run_id" => "runtime-run-1",
          "agent_id" => "agent-1",
          "agent_ref" => "A-1"
        },
        "agent_run" => %{"id" => "agent-run-1"},
        "context_packet" => %{
          "packet_id" => "context-1",
          "artifact_refs" => ["artifact-1"],
          "context_budget" => %{"action" => "send"},
          "memory_state" => %{"durable_truth" => "available"}
        },
        "resources" => %{"workspace_required" => false},
        "verification_gate" => %{"status" => "submitted", "satisfied" => true}
      })

    assert packet["schema_version"] == "holt_continuation_packet/v1"
    assert packet["packet_id"] == "packet-1"
    assert packet["continuation_depth"] == 2
    assert packet["previous_task_id"] == "task-1"
    assert packet["previous_task_ref"] == "HW-1"
    assert packet["previous_agent_run_id"] == "agent-run-1"
    assert packet["previous_runtime_run_id"] == "runtime-run-1"
    assert packet["previous_agent_work_id"] == "work-1"
    assert packet["agent_id"] == "agent-1"
    assert packet["agent_ref"] == "A-1"
    assert packet["context_packet_id"] == "context-1"
    assert packet["required_loop"]["dereference_artifacts"] == true
    assert packet["required_loop"]["workspace_required"] == false
  end

  test "rejects legacy aliases" do
    assert %{
             "schema_version" => "holt_continuation_packet/v1",
             "status" => "rejected",
             "reason" => "unsupported_argument:depth"
           } =
             ContinuationPacket.build(%{
               "depth" => 5,
               "task" => %{
                 "_id" => "legacy-task",
                 "task_ref" => "legacy-ref",
                 "title" => "Legacy"
               },
               "work" => %{"id" => "legacy-work", "agent_id" => "legacy-agent"},
               "run" => %{"id" => "legacy-run", "run_id" => "legacy-runtime"},
               "agent_id" => "top-agent",
               "agent_ref" => "top-ref"
             })
  end

  test "rejects atom-keyed nested maps" do
    assert %{
             "schema_version" => "holt_continuation_packet/v1",
             "status" => "rejected",
             "reason" => "invalid_task"
           } =
             ContinuationPacket.build(%{
               "continuation_depth" => 3,
               "task" => %{id: "task-1", ref: "HW-1"},
               "agent_work" => %{id: "work-1", agent_id: "agent-1"},
               "agent_run" => %{id: "run-1", run_id: "runtime-1"},
               "resources" => %{workspace_required: false}
             })
  end

  test "rejects string booleans and invalid continuation depth" do
    assert %{
             "status" => "rejected",
             "reason" => "invalid_resources"
           } =
             ContinuationPacket.build(%{
               "resources" => %{"workspace_required" => "false"}
             })

    assert %{
             "status" => "rejected",
             "reason" => "invalid_continuation_depth"
           } = ContinuationPacket.build(%{"continuation_depth" => "2"})
  end

  test "prompt section uses canonical display fields" do
    packet =
      ContinuationPacket.build(%{
        "packet_id" => "packet-1",
        "continuation_depth" => 2,
        "task" => %{"id" => "task-1"},
        "agent_work" => %{"id" => "work-1"},
        "agent_run" => %{"id" => "agent-run-1"},
        "context_packet" => %{"packet_id" => "context-1"}
      })

    section = ContinuationPacket.prompt_section(packet)

    assert section =~ "Packet: packet-1"
    assert section =~ "Previous task: unknown"
    assert section =~ "Previous run: unknown"
    assert section =~ "Continuation depth: 2"
    assert section =~ "Context packet: context-1"
  end
end
