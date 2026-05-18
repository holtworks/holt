defmodule Holt.Tasks.RunDebuggerTest do
  use ExUnit.Case, async: true

  alias Holt.Tasks.RunDebugger

  describe "build/1" do
    test "summarizes canonical run events" do
      debugger =
        RunDebugger.build(%{
          "run" => %{"id" => "run-1", "agent_run_id" => "agent-run-1"},
          "events" => [
            event(%{
              "approval_request" => %{"status" => "pending"},
              "repair_orchestration" => %{"repair_required" => true},
              "prediction_error" => %{"matched" => false, "severity" => "medium"}
            })
          ]
        })

      assert debugger["schema_version"] == "holt_run_debugger/v1"
      assert debugger["run_id"] == "run-1"
      assert debugger["event_count"] == 1
      assert debugger["action_envelope_count"] == 1
      assert debugger["repair_required_count"] == 1
      assert debugger["prediction_mismatch_count"] == 1

      assert [%{"kind" => "action.completed", "inserted_at" => "2026-05-17T00:00:00Z"}] =
               debugger["timeline"]
    end

    test "ignores legacy event aliases and string booleans" do
      debugger =
        RunDebugger.build(%{
          "run" => %{"run_id" => "runtime-run-1"},
          "events" => [
            %{
              "type" => "action.completed",
              "at" => "2026-05-17T00:00:00Z",
              "data" => %{
                "action_runtime_envelope" => %{
                  "repair_orchestration" => %{"repair_required" => "true"},
                  "prediction_error" => %{"matched" => "true"}
                }
              }
            },
            event(%{
              "repair_orchestration" => %{"repair_required" => "true"},
              "prediction_error" => %{"matched" => "true"}
            })
          ]
        })

      refute Map.has_key?(debugger, "run_id")
      assert debugger["event_count"] == 2
      assert debugger["action_envelope_count"] == 1
      assert debugger["repair_required_count"] == 0
      assert debugger["prediction_mismatch_count"] == 1
    end

    test "rejects atom-keyed attrs" do
      assert RunDebugger.build(%{events: []}) == %{
               "schema_version" => "holt_run_debugger/v1",
               "status" => "rejected",
               "reason" => "invalid_attrs"
             }
    end

    test "rejects invalid event list entries" do
      assert RunDebugger.build(%{"events" => ["action.completed"]}) == %{
               "schema_version" => "holt_run_debugger/v1",
               "status" => "rejected",
               "reason" => "invalid_field:events"
             }
    end

    test "rejects atom-keyed event payloads" do
      assert RunDebugger.build(%{"events" => [%{kind: "action.completed"}]}) == %{
               "schema_version" => "holt_run_debugger/v1",
               "status" => "rejected",
               "reason" => "invalid_field:events"
             }
    end

    test "rejects non-map attrs" do
      assert RunDebugger.build([]) == %{
               "schema_version" => "holt_run_debugger/v1",
               "status" => "rejected",
               "reason" => "invalid_attrs"
             }
    end
  end

  defp event(envelope_overrides) do
    %{
      "kind" => "action.completed",
      "inserted_at" => "2026-05-17T00:00:00Z",
      "metadata" => %{
        "action_runtime_envelope" =>
          Map.merge(
            %{
              "envelope_id" => "env-1",
              "action" => "write",
              "action_call_id" => "call-1"
            },
            envelope_overrides
          )
      }
    }
  end
end
