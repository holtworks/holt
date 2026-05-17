defmodule Holt.Tasks.AgentWorkLiveness do
  @moduledoc """
  Computes UI-safe liveness metadata for local task-agent work.
  """

  @schema_version "agent_work_liveness/v1"
  @quiet_after_seconds 60
  @stalled_after_seconds 300

  def quiet_after_seconds, do: @quiet_after_seconds
  def stalled_after_seconds, do: @stalled_after_seconds

  def enrich(entry, now \\ Holt.Clock.now())

  def enrich(entry, %DateTime{} = now) when is_map(entry) do
    status = value(entry, "status")
    last_activity_at = last_activity_at(entry)
    quiet_seconds = quiet_seconds(last_activity_at, now)
    liveness_status = liveness_status(status, quiet_seconds)

    Map.put(entry, "liveness", %{
      "schema_version" => @schema_version,
      "status" => liveness_status,
      "last_activity_at" => format_datetime(last_activity_at),
      "quiet_seconds" => quiet_seconds,
      "quiet_after_seconds" => @quiet_after_seconds,
      "stalled_after_seconds" => @stalled_after_seconds,
      "needs_attention" => liveness_status in ["quiet", "stalled"]
    })
  end

  def enrich(entry, _now), do: entry

  defp liveness_status("queued", _quiet_seconds), do: "queued"
  defp liveness_status("running", nil), do: "active"

  defp liveness_status("running", quiet_seconds) do
    cond do
      quiet_seconds >= @stalled_after_seconds -> "stalled"
      quiet_seconds >= @quiet_after_seconds -> "quiet"
      true -> "active"
    end
  end

  defp liveness_status(_status, _quiet_seconds), do: "inactive"

  defp last_activity_at(entry) do
    value(entry, "last_heartbeat_at") ||
      value(entry, "completed_at") ||
      value(entry, "started_at") ||
      value(entry, "scheduled_start_at") ||
      value(entry, "queued_at") ||
      value(entry, "created_at")
  end

  defp quiet_seconds(nil, _now), do: nil

  defp quiet_seconds(%DateTime{} = last_activity_at, %DateTime{} = now) do
    DateTime.diff(now, last_activity_at, :second)
    |> max(0)
  end

  defp value(map, key) do
    map
    |> Map.get(key)
    |> parse_datetime()
  end

  defp parse_datetime(%DateTime{} = datetime), do: datetime

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _error -> value
    end
  end

  defp parse_datetime(value), do: value

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp format_datetime(value), do: value
end
