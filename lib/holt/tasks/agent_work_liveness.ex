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
    status = text_field(entry, "status")
    last_activity_at = timestamp(entry, "last_activity_at")
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

  defp quiet_seconds(nil, _now), do: nil

  defp quiet_seconds(%DateTime{} = last_activity_at, %DateTime{} = now) do
    DateTime.diff(now, last_activity_at, :second)
    |> max(0)
  end

  defp timestamp(map, key) do
    map
    |> Map.get(key)
    |> parse_datetime()
  end

  defp text_field(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) -> String.trim(value)
      _value -> nil
    end
  end

  defp parse_datetime(%DateTime{} = datetime), do: datetime

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _error -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
end
