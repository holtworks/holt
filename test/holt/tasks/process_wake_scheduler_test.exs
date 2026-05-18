defmodule Holt.Tasks.ProcessWakeSchedulerTest do
  use ExUnit.Case, async: true

  alias Holt.Tasks
  alias Holt.Tasks.ProcessWakeScheduler

  describe "process context" do
    test "requires the canonical agent run identifier" do
      payload = %{"managed_process_id" => "proc_1", "status" => "running"}

      assert {:error, :missing_agent_run_id} =
               ProcessWakeScheduler.record_started(payload, %{})

      assert {:error, :invalid_agent_run_id} =
               ProcessWakeScheduler.record_started(payload, %{"agent_run_id" => 123})

      assert {:error, {:obsolete_process_context_key, "run_id", "agent_run_id"}} =
               ProcessWakeScheduler.record_started(payload, %{
                 "agent_run_id" => "agent_run_1",
                 "run_id" => "runtime_run_1"
               })
    end

    test "rejects workspace fields from process context" do
      payload = %{"managed_process_id" => "proc_1", "status" => "running"}

      assert {:error, {:obsolete_process_context_key, "workspace", "workspace option"}} =
               ProcessWakeScheduler.record_started(payload, %{
                 "agent_run_id" => "agent_run_1",
                 "workspace" => "/tmp/project"
               })

      assert {:error, {:obsolete_process_context_key, "workspace_root", "workspace option"}} =
               ProcessWakeScheduler.record_started(payload, %{
                 "agent_run_id" => "agent_run_1",
                 "workspace_root" => "/tmp/project"
               })
    end
  end

  describe "boundary maps" do
    test "the public task API no longer normalizes atom-keyed process events" do
      assert {:error, :invalid_process_payload} =
               Tasks.record_process_started(%{managed_process_id: "proc_1"}, %{
                 "agent_run_id" => "agent_run_1"
               })

      assert {:error, :invalid_process_context} =
               Tasks.record_process_started(%{"managed_process_id" => "proc_1"}, %{
                 agent_run_id: "agent_run_1"
               })
    end
  end

  describe "terminal wake candidates" do
    test "literal wait and notification flags control whether a wake is considered" do
      context = %{"agent_run_id" => "agent_run_1"}

      ignored_processes = [
        %{"managed_process_id" => "proc_1", "status" => "exited"},
        %{"managed_process_id" => "proc_1", "status" => "exited", "wait_for_exit" => false},
        %{"managed_process_id" => "proc_1", "status" => "exited", "wait_for_exit" => "true"},
        %{
          "managed_process_id" => "proc_1",
          "status" => "exited",
          "wait_for_exit" => true,
          "notify_on_exit" => false
        },
        %{
          "managed_process_id" => "proc_1",
          "status" => "exited",
          "wait_for_exit" => true,
          "notify_on_exit" => "false"
        }
      ]

      for process <- ignored_processes do
        assert {:ok,
                %{
                  "action" => "ignored",
                  "reason" => "not_terminal_or_not_waitable",
                  "process" => ^process
                }} = ProcessWakeScheduler.notify_terminal(process, context)
      end
    end
  end
end
