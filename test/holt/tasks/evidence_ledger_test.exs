defmodule Holt.Tasks.EvidenceLedgerTest do
  use ExUnit.Case, async: true

  alias Holt.Tasks.EvidenceLedger

  test "evidence ledgers use canonical runtime envelope and result status fields" do
    ledger =
      EvidenceLedger.build(%{
        "action_runtime_envelope" => envelope(),
        "task_id" => "task-1",
        "task_ref" => "HW-1",
        "action" => "read",
        "action_call_id" => "call-1",
        "result_status" => "ok",
        "result_preview" => "read task"
      })

    assert ledger["source_envelope_id"] == "env-1"
    assert ledger["source_action"] == "read"
    assert ledger["source_action_call_id"] == "call-1"
    assert ledger["task_id"] == "task-1"
    assert ledger["task_ref"] == "HW-1"

    action_result =
      Enum.find(ledger["entries"], &(&1["entry_kind"] == "action_result"))

    assert action_result["payload"]["status"] == "ok"
  end

  test "evidence ledgers reject legacy envelope and status arguments" do
    assert %{"status" => "rejected", "reason" => "unsupported_argument:envelope"} =
             EvidenceLedger.build(%{"envelope" => envelope()})

    assert %{"status" => "rejected", "reason" => "unsupported_argument:status"} =
             EvidenceLedger.build(%{
               "action_runtime_envelope" => envelope(),
               "status" => "ok"
             })
  end

  test "evidence ledgers reject missing or invalid runtime envelopes" do
    assert %{"status" => "rejected", "reason" => "missing_action_runtime_envelope"} =
             EvidenceLedger.build(%{"result_status" => "ok"})

    assert %{"status" => "rejected", "reason" => "invalid_action_runtime_envelope"} =
             EvidenceLedger.build(%{
               "action_runtime_envelope" => Map.delete(envelope(), "envelope_id")
             })
  end

  test "evidence ledgers reject atom-keyed attrs and nested envelopes" do
    assert %{"status" => "rejected", "reason" => "invalid_attrs"} =
             EvidenceLedger.build(%{action_runtime_envelope: envelope()})

    assert %{"status" => "rejected", "reason" => "invalid_attrs"} =
             EvidenceLedger.build(%{
               "action_runtime_envelope" =>
                 Map.put(envelope(), "action_contract", %{contract_id: "contract-1"})
             })
  end

  test "evidence ledgers reject invalid result fields" do
    assert %{"status" => "rejected", "reason" => "invalid_result_status"} =
             EvidenceLedger.build(%{
               "action_runtime_envelope" => envelope(),
               "result_status" => 200
             })
  end

  test "evidence ledgers do not recover task refs from nested envelope refs" do
    ledger =
      EvidenceLedger.build(%{
        "action_runtime_envelope" => envelope(),
        "result_status" => "ok"
      })

    refute Map.has_key?(ledger, "task_id")
    refute Map.has_key?(ledger, "task_ref")
  end

  defp envelope do
    %{
      "envelope_id" => "env-1",
      "action" => "read",
      "action_call_id" => "call-1",
      "action_contract" => %{
        "contract_id" => "contract-1",
        "target_refs" => %{"task_id" => "nested-task", "task_ref" => "HW-NESTED"}
      },
      "state_snapshot" => %{
        "task_state" => %{"task_id" => "snapshot-task", "task_ref" => "HW-SNAPSHOT"}
      },
      "execution_observation" => %{"observation_id" => "obs-1", "status" => "ok"}
    }
  end
end
