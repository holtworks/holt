defmodule HoltWorks.Tasks.RunDebugger do
  @moduledoc """
  Replay-oriented debugger summary for local agent runs.

  It compresses run events into action envelopes, prediction mismatches, repair
  holds, approval waits, and suggested debug actions.
  """

  alias HoltWorks.Clock
  alias HoltWorks.Tasks.RuntimeContracts

  @schema_version "holtworks_run_debugger/v1"

  def build(attrs \\ %{})

  def build(attrs) when is_map(attrs) do
    attrs = RuntimeContracts.string_keys(attrs)
    run = RuntimeContracts.normalize_map(RuntimeContracts.value(attrs, "run"))
    events = normalize_events(RuntimeContracts.value(attrs, "events"))
    envelopes = Enum.flat_map(events, &event_envelopes/1)
    approvals = Enum.flat_map(envelopes, &approval_requests/1)
    repairs = Enum.flat_map(envelopes, &repair_orchestrations/1)
    prediction_errors = Enum.flat_map(envelopes, &prediction_errors/1)

    %{
      "schema_version" => @schema_version,
      "debugger_id" =>
        RuntimeContracts.stable_id("run_debugger", [
          run["id"] || run["run_id"],
          Enum.map(events, &event_kind/1)
        ]),
      "run_id" => run["id"] || run["run_id"],
      "agent_run_id" => run["agent_run_id"],
      "event_count" => length(events),
      "action_envelope_count" => length(envelopes),
      "approval_wait_count" => Enum.count(approvals, &(&1["status"] == "pending")),
      "repair_required_count" =>
        Enum.count(repairs, &RuntimeContracts.truthy?(&1["repair_required"])),
      "prediction_mismatch_count" =>
        Enum.count(prediction_errors, &(not RuntimeContracts.truthy?(&1["matched"]))),
      "timeline" => Enum.map(events, &debug_event/1),
      "open_threads" => open_threads(approvals, repairs, prediction_errors),
      "next_debug_actions" => next_debug_actions(approvals, repairs, prediction_errors),
      "generated_at" => Clock.iso_now()
    }
    |> RuntimeContracts.reject_empty()
  end

  def build(_attrs), do: build(%{})

  defp debug_event(event) do
    metadata = RuntimeContracts.normalize_map(event["metadata"] || event["data"])
    envelope = RuntimeContracts.normalize_map(metadata["action_runtime_envelope"])
    repair = RuntimeContracts.normalize_map(envelope["repair_orchestration"])
    approval = RuntimeContracts.normalize_map(envelope["approval_request"])
    prediction_error = RuntimeContracts.normalize_map(envelope["prediction_error"])

    %{
      "kind" => event_kind(event),
      "inserted_at" => event["inserted_at"] || event["at"],
      "tool_name" => metadata["tool_name"] || metadata["tool"] || envelope["tool_name"],
      "tool_call_id" => metadata["tool_call_id"] || envelope["tool_call_id"],
      "envelope_id" => envelope["envelope_id"],
      "runtime_status" => envelope["runtime_status"],
      "execution_decision" => envelope["execution_decision"],
      "prediction_matched" => prediction_error["matched"],
      "prediction_error_severity" => prediction_error["severity"],
      "repair_status" => repair["status"],
      "repair_mode" => repair["mode"],
      "approval_status" => approval["status"]
    }
    |> RuntimeContracts.reject_empty()
  end

  defp open_threads(approvals, repairs, prediction_errors) do
    []
    |> maybe_thread(
      Enum.any?(approvals, &(&1["status"] == "pending")),
      "approval_wait",
      "pending_human_approval"
    )
    |> maybe_thread(
      Enum.any?(repairs, &RuntimeContracts.truthy?(&1["repair_required"])),
      "repair",
      "repair_required_before_resume"
    )
    |> maybe_thread(
      Enum.any?(prediction_errors, &(not RuntimeContracts.truthy?(&1["matched"]))),
      "prediction",
      "prediction_mismatch_needs_calibration"
    )
    |> Enum.reverse()
  end

  defp maybe_thread(threads, false, _kind, _reason), do: threads

  defp maybe_thread(threads, true, kind, reason),
    do: [%{"kind" => kind, "reason" => reason} | threads]

  defp next_debug_actions(approvals, repairs, prediction_errors) do
    [
      if(Enum.any?(approvals, &(&1["status"] == "pending")), do: "resolve_human_approval"),
      if(Enum.any?(repairs, &RuntimeContracts.truthy?(&1["repair_required"])),
        do: "inspect_repair_orchestration"
      ),
      if(Enum.any?(prediction_errors, &(not RuntimeContracts.truthy?(&1["matched"]))),
        do: "inspect_prediction_error"
      ),
      if(approvals == [] and repairs == [] and prediction_errors == [],
        do: "inspect_latest_work_graph"
      )
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end

  defp event_envelopes(event) do
    metadata = RuntimeContracts.normalize_map(event["metadata"] || event["data"])

    case metadata["action_runtime_envelope"] do
      envelope when is_map(envelope) and map_size(envelope) > 0 ->
        [RuntimeContracts.string_keys(envelope)]

      _missing ->
        []
    end
  end

  defp approval_requests(envelope) do
    case envelope["approval_request"] do
      approval when is_map(approval) and map_size(approval) > 0 ->
        [RuntimeContracts.string_keys(approval)]

      _missing ->
        []
    end
  end

  defp repair_orchestrations(envelope) do
    case envelope["repair_orchestration"] do
      repair when is_map(repair) and map_size(repair) > 0 ->
        [RuntimeContracts.string_keys(repair)]

      _missing ->
        []
    end
  end

  defp prediction_errors(envelope) do
    case envelope["prediction_error"] do
      error when is_map(error) and map_size(error) > 0 ->
        [RuntimeContracts.string_keys(error)]

      _missing ->
        []
    end
  end

  defp normalize_events(events) when is_list(events) do
    Enum.map(events, fn
      event when is_map(event) -> RuntimeContracts.string_keys(event)
      _event -> %{}
    end)
  end

  defp normalize_events(_events), do: []

  defp event_kind(event), do: event["kind"] || event["type"]
end
