defmodule Holt.Tasks.EvidenceLedger do
  @moduledoc """
  Typed evidence ledger for closed-loop local task actions.

  The ledger captures contracts, predictions, observations, calibrations,
  approvals, repairs, action results, and event metadata linked to one runtime
  envelope.
  """

  alias Holt.Clock

  @schema_version "holt_evidence_ledger/v1"

  def build(attrs \\ %{})

  def build(attrs) when is_map(attrs) do
    case input(attrs) do
      {:ok, input} -> build_canonical(input)
      {:error, reason} -> rejected_ledger(attrs, reason)
    end
  end

  def build(_attrs), do: rejected_ledger(%{}, "invalid_attrs")

  defp input(attrs) do
    with :ok <- canonical_attrs(attrs),
         :ok <- unsupported_arguments(attrs),
         {:ok, envelope} <- runtime_envelope(attrs),
         {:ok, event} <- optional_map_value(attrs, "event", "invalid_event"),
         {:ok, approval_request} <-
           optional_map(attrs, "approval_request", "invalid_approval_request"),
         {:ok, artifact_ref} <- optional_text(attrs, "artifact_ref", "invalid_artifact_ref"),
         {:ok, task_id} <- optional_text(attrs, "task_id", "invalid_task_id"),
         {:ok, task_ref} <- optional_text(attrs, "task_ref", "invalid_task_ref"),
         {:ok, action} <- optional_text(attrs, "action", "invalid_action"),
         {:ok, action_call_id} <- optional_text(attrs, "action_call_id", "invalid_action_call_id"),
         {:ok, result_status} <- optional_text(attrs, "result_status", "invalid_result_status"),
         {:ok, result_preview} <- optional_text(attrs, "result_preview", "invalid_result_preview") do
      {:ok,
       %{
         envelope: envelope,
         event: event,
         approval_request: approval_request,
         artifact_ref: artifact_ref,
         task_id: task_id,
         task_ref: task_ref,
         action_result:
           action_result(%{
             "action" => action,
             "action_call_id" => action_call_id,
             "status" => result_status,
             "preview" => result_preview
           })
       }}
    end
  end

  defp build_canonical(input) do
    envelope = input.envelope
    artifact_ref = input.artifact_ref

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
      |> add_entry("approval_request", "approval", input.approval_request, envelope, artifact_ref)
      |> add_entry("action_result", "artifact", input.action_result, envelope, artifact_ref)
      |> add_entry("event_metadata", "event", input.event["metadata"], envelope, artifact_ref)
      |> Enum.reverse()

    %{
      "schema_version" => @schema_version,
      "ledger_id" =>
        stable_id("evidence_ledger", [
          envelope["envelope_id"],
          artifact_ref,
          Enum.map(entries, & &1["evidence_id"])
        ]),
      "source_envelope_id" => envelope["envelope_id"],
      "source_action" => envelope["action"],
      "source_action_call_id" => envelope["action_call_id"],
      "task_id" => input.task_id,
      "task_ref" => input.task_ref,
      "artifact_ref" => artifact_ref,
      "entries" => entries,
      "coverage" => coverage(entries),
      "created_at" => Clock.iso_now()
    }
    |> compact()
  end

  defp rejected_ledger(attrs, reason) do
    %{
      "schema_version" => @schema_version,
      "ledger_id" =>
        output_text(
          attrs,
          "ledger_id",
          stable_id("evidence_ledger", [reason, attrs])
        ),
      "status" => "rejected",
      "reason" => reason,
      "created_at" => Clock.iso_now()
    }
  end

  defp runtime_envelope(attrs) do
    case Map.fetch(attrs, "action_runtime_envelope") do
      {:ok, envelope} when is_map(envelope) ->
        with :ok <- validate_runtime_envelope(envelope) do
          {:ok, envelope}
        end

      {:ok, _envelope} ->
        {:error, "invalid_action_runtime_envelope"}

      :error ->
        {:error, "missing_action_runtime_envelope"}
    end
  end

  defp validate_runtime_envelope(envelope) do
    with {:ok, _envelope_id} <-
           required_text(envelope, "envelope_id", "invalid_action_runtime_envelope"),
         :ok <- optional_text_field(envelope, "action", "invalid_action_runtime_envelope"),
         :ok <- optional_text_field(envelope, "action_call_id", "invalid_action_runtime_envelope"),
         :ok <- optional_map_field(envelope, "action_contract", "invalid_action_runtime_envelope"),
         :ok <- optional_map_field(envelope, "state_snapshot", "invalid_action_runtime_envelope"),
         :ok <-
           optional_map_field(
             envelope,
             "execution_observation",
             "invalid_action_runtime_envelope"
           ) do
      :ok
    end
  end

  defp add_entry(entries, _entry_kind, _evidence_type, value, _envelope, _artifact_ref)
       when value in [nil, "", [], %{}],
       do: entries

  defp add_entry(entries, entry_kind, evidence_type, payload, envelope, artifact_ref) do
    normalized = normalize_payload(payload)

    entry =
      %{
        "schema_version" => "holt_evidence_entry/v1",
        "evidence_id" =>
          stable_id("evidence", [
            envelope["envelope_id"],
            entry_kind,
            stable_id("payload", [normalized])
          ]),
        "entry_kind" => entry_kind,
        "evidence_type" => evidence_type,
        "source_envelope_id" => envelope["envelope_id"],
        "source_action" => envelope["action"],
        "source_action_call_id" => envelope["action_call_id"],
        "artifact_ref" => artifact_ref,
        "payload" => normalized,
        "recorded_at" => Clock.iso_now()
      }
      |> compact()

    [entry | entries]
  end

  defp action_result(fields), do: compact(fields)

  defp normalize_payload(value) when is_map(value), do: value
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

  defp canonical_attrs(attrs) do
    case canonical_value?(attrs) do
      true -> :ok
      false -> {:error, "invalid_attrs"}
    end
  end

  defp canonical_value?(value) when is_map(value) do
    Enum.all?(value, fn
      {key, nested} when is_binary(key) -> canonical_value?(nested)
      _entry -> false
    end)
  end

  defp canonical_value?(values) when is_list(values), do: Enum.all?(values, &canonical_value?/1)
  defp canonical_value?(_value), do: true

  defp unsupported_arguments(attrs) do
    cond do
      Map.has_key?(attrs, "envelope") -> {:error, "unsupported_argument:envelope"}
      Map.has_key?(attrs, "status") -> {:error, "unsupported_argument:status"}
      true -> :ok
    end
  end

  defp optional_map_value(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _value} -> {:error, reason}
      :error -> {:ok, %{}}
    end
  end

  defp optional_map(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _value} -> {:error, reason}
      :error -> {:ok, nil}
    end
  end

  defp optional_map_field(map, key, reason) do
    case optional_map(map, key, reason) do
      {:ok, _value} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp required_text(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, reason}
          text -> {:ok, text}
        end

      {:ok, _value} ->
        {:error, reason}

      :error ->
        {:error, reason}
    end
  end

  defp optional_text_field(map, key, reason) do
    case optional_text(map, key, reason) do
      {:ok, _value} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp optional_text(map, key, reason) do
    case Map.fetch(map, key) do
      :error ->
        {:ok, nil}

      {:ok, value} when is_binary(value) ->
        {:ok, trim_empty(value)}

      {:ok, _value} ->
        {:error, reason}
    end
  end

  defp output_text(map, key, default) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) -> text_default(trim_empty(value), default)
      _missing -> default
    end
  end

  defp output_text(_map, _key, default), do: default

  defp text_default(nil, default), do: default
  defp text_default(value, _default), do: value

  defp trim_empty(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end

  defp stable_id(prefix, parts) do
    digest =
      :crypto.hash(:sha256, :erlang.term_to_binary(parts))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 24)

    "#{prefix}_#{digest}"
  end
end
