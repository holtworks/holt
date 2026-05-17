defmodule HoltWorks.Tasks.EvidenceLedger do
  @moduledoc """
  Typed evidence ledger for closed-loop local task actions.

  The ledger captures contracts, predictions, observations, calibrations,
  approvals, repairs, tool results, and event metadata linked to one runtime
  envelope.
  """

  alias HoltWorks.Clock
  alias HoltWorks.Tasks.RuntimeContracts

  @schema_version "holtworks_evidence_ledger/v1"

  def build(attrs \\ %{})

  def build(attrs) when is_map(attrs) do
    attrs = RuntimeContracts.string_keys(attrs)

    envelope =
      RuntimeContracts.normalize_map(
        RuntimeContracts.value(attrs, "action_runtime_envelope") ||
          RuntimeContracts.value(attrs, "envelope")
      )

    event = RuntimeContracts.normalize_map(RuntimeContracts.value(attrs, "event"))
    artifact_ref = RuntimeContracts.text(attrs, "artifact_ref")

    entries =
      []
      |> add_entry("plan_contract", "contract", envelope["plan_contract"], envelope, artifact_ref)
      |> add_entry(
        "action_contract",
        "contract",
        envelope["action_contract"],
        envelope,
        artifact_ref
      )
      |> add_entry("plan_gate", "gate", envelope["plan_gate"], envelope, artifact_ref)
      |> add_entry(
        "action_preflight",
        "gate",
        envelope["action_preflight"],
        envelope,
        artifact_ref
      )
      |> add_entry(
        "policy_decision",
        "policy",
        envelope["policy_decision"],
        envelope,
        artifact_ref
      )
      |> add_entry(
        "consequence_gate",
        "gate",
        envelope["consequence_gate"],
        envelope,
        artifact_ref
      )
      |> add_entry("state_snapshot", "state", envelope["state_snapshot"], envelope, artifact_ref)
      |> add_entry("prediction", "prediction", envelope["prediction"], envelope, artifact_ref)
      |> add_entry(
        "state_transition_prediction",
        "prediction",
        envelope["state_transition_prediction"],
        envelope,
        artifact_ref
      )
      |> add_entry(
        "state_invariant_check",
        "gate",
        envelope["state_invariant_check"],
        envelope,
        artifact_ref
      )
      |> add_entry(
        "execution_observation",
        "observation",
        envelope["execution_observation"],
        envelope,
        artifact_ref
      )
      |> add_entry(
        "prediction_error",
        "calibration",
        envelope["prediction_error"],
        envelope,
        artifact_ref
      )
      |> add_entry(
        "state_reconciliation",
        "calibration",
        envelope["state_reconciliation"],
        envelope,
        artifact_ref
      )
      |> add_entry(
        "outcome_calibration",
        "calibration",
        envelope["outcome_calibration"],
        envelope,
        artifact_ref
      )
      |> add_entry(
        "repair_orchestration",
        "repair",
        envelope["repair_orchestration"],
        envelope,
        artifact_ref
      )
      |> add_entry(
        "approval_request",
        "approval",
        RuntimeContracts.value(attrs, "approval_request") || envelope["approval_request"],
        envelope,
        artifact_ref
      )
      |> add_entry("tool_result", "artifact", tool_result(attrs), envelope, artifact_ref)
      |> add_entry("event_metadata", "event", event["metadata"], envelope, artifact_ref)
      |> Enum.reverse()

    %{
      "schema_version" => @schema_version,
      "ledger_id" =>
        RuntimeContracts.stable_id("evidence_ledger", [
          envelope["envelope_id"],
          artifact_ref,
          Enum.map(entries, & &1["evidence_id"])
        ]),
      "source_envelope_id" => envelope["envelope_id"],
      "source_tool_name" => envelope["tool_name"] || RuntimeContracts.text(attrs, "tool_name"),
      "source_tool_call_id" =>
        envelope["tool_call_id"] || RuntimeContracts.text(attrs, "tool_call_id"),
      "task_id" => task_ref(envelope, attrs, "task_id"),
      "task_ref" => task_ref(envelope, attrs, "task_ref"),
      "artifact_ref" => artifact_ref,
      "entries" => entries,
      "coverage" => coverage(entries),
      "created_at" => Clock.iso_now()
    }
    |> RuntimeContracts.reject_empty()
  end

  def build(_attrs), do: build(%{})

  defp add_entry(entries, _entry_kind, _evidence_type, value, _envelope, _artifact_ref)
       when value in [nil, "", [], %{}],
       do: entries

  defp add_entry(entries, entry_kind, evidence_type, payload, envelope, artifact_ref) do
    normalized = normalize_payload(payload)

    entry =
      %{
        "schema_version" => "holtworks_evidence_entry/v1",
        "evidence_id" =>
          RuntimeContracts.stable_id("evidence", [
            envelope["envelope_id"],
            entry_kind,
            RuntimeContracts.stable_id("payload", [normalized])
          ]),
        "entry_kind" => entry_kind,
        "evidence_type" => evidence_type,
        "source_envelope_id" => envelope["envelope_id"],
        "source_tool_name" => envelope["tool_name"],
        "source_tool_call_id" => envelope["tool_call_id"],
        "artifact_ref" => artifact_ref,
        "payload" => normalized,
        "recorded_at" => Clock.iso_now()
      }
      |> RuntimeContracts.reject_empty()

    [entry | entries]
  end

  defp tool_result(attrs) do
    %{
      "tool_name" => RuntimeContracts.text(attrs, "tool_name"),
      "tool_call_id" => RuntimeContracts.text(attrs, "tool_call_id"),
      "status" =>
        RuntimeContracts.value(attrs, "result_status") || RuntimeContracts.value(attrs, "status"),
      "preview" => RuntimeContracts.text(attrs, "result_preview")
    }
    |> RuntimeContracts.reject_empty()
  end

  defp normalize_payload(value) when is_map(value), do: RuntimeContracts.string_keys(value)
  defp normalize_payload(value) when is_list(value), do: %{"items" => value}
  defp normalize_payload(value), do: %{"value" => value}

  defp coverage(entries) do
    %{
      "entry_count" => length(entries),
      "entry_kinds" => entries |> Enum.map(& &1["entry_kind"]) |> Enum.uniq(),
      "evidence_types" => entries |> Enum.map(& &1["evidence_type"]) |> Enum.uniq(),
      "has_prediction" => Enum.any?(entries, &(&1["evidence_type"] == "prediction")),
      "has_observation" => Enum.any?(entries, &(&1["evidence_type"] == "observation")),
      "has_calibration" => Enum.any?(entries, &(&1["evidence_type"] == "calibration")),
      "has_repair" => Enum.any?(entries, &(&1["evidence_type"] == "repair")),
      "has_approval" => Enum.any?(entries, &(&1["evidence_type"] == "approval"))
    }
  end

  defp task_ref(envelope, attrs, key) do
    contract = RuntimeContracts.normalize_map(envelope["action_contract"])
    target_refs = RuntimeContracts.normalize_map(contract["target_refs"])

    RuntimeContracts.value(attrs, key) ||
      RuntimeContracts.value(target_refs, key) ||
      get_in(envelope, ["state_snapshot", "task_state", key])
  end
end
