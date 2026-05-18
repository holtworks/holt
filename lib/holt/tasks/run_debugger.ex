defmodule Holt.Tasks.RunDebugger do
  @moduledoc """
  Replay-oriented debugger summary for local agent runs.

  It compresses run events into action envelopes, prediction mismatches, repair
  holds, approval waits, and suggested debug actions.
  """

  alias Holt.Clock

  @schema_version "holt_run_debugger/v1"

  def build(attrs \\ %{})

  def build(attrs) when is_map(attrs) do
    with :ok <- canonical_attrs(attrs),
         {:ok, run} <- input_map_field(attrs, "run"),
         {:ok, events} <- events_field(attrs) do
      envelopes = Enum.flat_map(events, &event_envelopes/1)
      approvals = Enum.flat_map(envelopes, &approval_requests/1)
      repairs = Enum.flat_map(envelopes, &repair_orchestrations/1)
      prediction_errors = Enum.flat_map(envelopes, &prediction_errors/1)

      %{
        "schema_version" => @schema_version,
        "debugger_id" =>
          stable_id("run_debugger", [
            run["id"],
            Enum.map(events, &event_kind/1)
          ]),
        "run_id" => run["id"],
        "agent_run_id" => run["agent_run_id"],
        "event_count" => length(events),
        "action_envelope_count" => length(envelopes),
        "approval_wait_count" => Enum.count(approvals, &(&1["status"] == "pending")),
        "repair_required_count" => Enum.count(repairs, &repair_required?/1),
        "prediction_mismatch_count" => Enum.count(prediction_errors, &(not matched?(&1))),
        "timeline" => Enum.map(events, &debug_event/1),
        "open_threads" => open_threads(approvals, repairs, prediction_errors),
        "next_debug_actions" => next_debug_actions(approvals, repairs, prediction_errors),
        "generated_at" => Clock.iso_now()
      }
      |> reject_empty()
    else
      {:error, reason} -> rejected_debugger(reason)
    end
  end

  def build(_attrs), do: rejected_debugger("invalid_attrs")

  defp rejected_debugger(reason) do
    %{
      "schema_version" => @schema_version,
      "status" => "rejected",
      "reason" => reason
    }
  end

  defp debug_event(event) do
    metadata = map_field(event, "metadata")
    envelope = map_field(metadata, "action_runtime_envelope")
    repair = map_field(envelope, "repair_orchestration")
    approval = map_field(envelope, "approval_request")
    prediction_error = map_field(envelope, "prediction_error")

    %{
      "kind" => event_kind(event),
      "inserted_at" => event["inserted_at"],
      "action" => envelope["action"],
      "action_call_id" => envelope["action_call_id"],
      "envelope_id" => envelope["envelope_id"],
      "runtime_status" => envelope["runtime_status"],
      "execution_decision" => envelope["execution_decision"],
      "prediction_matched" => prediction_error["matched"],
      "prediction_error_severity" => prediction_error["severity"],
      "repair_status" => repair["status"],
      "repair_mode" => repair["mode"],
      "approval_status" => approval["status"]
    }
    |> reject_empty()
  end

  defp open_threads(approvals, repairs, prediction_errors) do
    []
    |> maybe_thread(
      Enum.any?(approvals, &(&1["status"] == "pending")),
      "approval_wait",
      "pending_human_approval"
    )
    |> maybe_thread(
      Enum.any?(repairs, &repair_required?/1),
      "repair",
      "repair_required_before_resume"
    )
    |> maybe_thread(
      Enum.any?(prediction_errors, &(not matched?(&1))),
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
      if(Enum.any?(repairs, &repair_required?/1),
        do: "inspect_repair_orchestration"
      ),
      if(Enum.any?(prediction_errors, &(not matched?(&1))),
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
    metadata = map_field(event, "metadata")

    case metadata["action_runtime_envelope"] do
      envelope when is_map(envelope) and map_size(envelope) > 0 ->
        non_empty_map_list(envelope)

      _missing ->
        []
    end
  end

  defp approval_requests(envelope) do
    case envelope["approval_request"] do
      approval when is_map(approval) and map_size(approval) > 0 ->
        non_empty_map_list(approval)

      _missing ->
        []
    end
  end

  defp repair_orchestrations(envelope) do
    case envelope["repair_orchestration"] do
      repair when is_map(repair) and map_size(repair) > 0 ->
        non_empty_map_list(repair)

      _missing ->
        []
    end
  end

  defp prediction_errors(envelope) do
    case envelope["prediction_error"] do
      error when is_map(error) and map_size(error) > 0 ->
        non_empty_map_list(error)

      _missing ->
        []
    end
  end

  defp events_field(attrs) do
    case Map.fetch(attrs, "events") do
      {:ok, events} when is_list(events) -> canonical_events(events)
      {:ok, _value} -> {:error, "invalid_field:events"}
      :error -> {:ok, []}
    end
  end

  defp event_kind(event), do: event["kind"]

  defp matched?(%{"matched" => true}), do: true
  defp matched?(_error), do: false

  defp repair_required?(%{"repair_required" => true}), do: true
  defp repair_required?(_repair), do: false

  defp map_field(map, key) do
    case Map.get(map, key) do
      value when is_map(value) -> value
      _value -> %{}
    end
  end

  defp input_map_field(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_map(value) -> canonical_nested_map(key, value)
      {:ok, _value} -> {:error, "invalid_field:#{key}"}
      :error -> {:ok, %{}}
    end
  end

  defp canonical_events(events) do
    Enum.reduce_while(events, {:ok, []}, fn
      event, {:ok, acc} when is_map(event) ->
        if canonical_value?(event) do
          {:cont, {:ok, [event | acc]}}
        else
          {:halt, {:error, "invalid_field:events"}}
        end

      _event, {:ok, _acc} ->
        {:halt, {:error, "invalid_field:events"}}
    end)
    |> case do
      {:ok, events} -> {:ok, Enum.reverse(events)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp non_empty_map_list(value) do
    case value do
      map when is_map(map) and map_size(map) > 0 -> [map]
      _value -> []
    end
  end

  defp canonical_attrs(attrs) do
    if Enum.all?(attrs, fn {key, _value} -> is_binary(key) end) do
      :ok
    else
      {:error, "invalid_attrs"}
    end
  end

  defp canonical_nested_map(key, map) do
    if canonical_value?(map) do
      {:ok, map}
    else
      {:error, "invalid_field:#{key}"}
    end
  end

  defp canonical_value?(value) when is_map(value) do
    Enum.all?(value, fn
      {key, nested} when is_binary(key) -> canonical_value?(nested)
      _entry -> false
    end)
  end

  defp canonical_value?(value) when is_list(value), do: Enum.all?(value, &canonical_value?/1)
  defp canonical_value?(_value), do: true

  defp reject_empty(map) do
    map
    |> Enum.reject(fn {_key, value} -> empty?(value) end)
    |> Map.new()
  end

  defp empty?(nil), do: true
  defp empty?(""), do: true
  defp empty?([]), do: true
  defp empty?(map) when is_map(map), do: map_size(map) == 0
  defp empty?(_value), do: false

  defp stable_id(prefix, parts) do
    digest =
      :crypto.hash(:sha256, :erlang.term_to_binary(parts))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 24)

    "#{prefix}_#{digest}"
  end
end
