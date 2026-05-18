defmodule Holt.Runtime.RunStore do
  @moduledoc """
  File-backed repository for run state, events, and transcripts.
  """

  alias Holt.{Clock, JSON}

  def write_run(run_dir, run) when is_binary(run_dir) and is_map(run) do
    JSON.write(run_path(run_dir), run)
  end

  def read_run(run_dir) when is_binary(run_dir), do: JSON.read(run_path(run_dir))

  def append_event(run_dir, type, data \\ %{}) when is_binary(run_dir) and is_binary(type) do
    event =
      data
      |> Map.put("type", type)
      |> Map.put_new("at", Clock.iso_now())

    JSON.append_jsonl(events_path(run_dir), event)
    event
  end

  def events(run_dir) when is_binary(run_dir), do: JSON.read_jsonl(events_path(run_dir))

  def append_transcript(run_dir, role, content) when is_binary(run_dir) do
    JSON.append_jsonl(transcript_events_path(run_dir), %{
      "schema_version" => "holt_run_transcript_entry/v1",
      "role" => role,
      "content" => content,
      "at" => Clock.iso_now()
    })

    File.write!(
      transcript_path(run_dir),
      ["\n\n## ", role, "\n\n", content, "\n"],
      [:append]
    )
  end

  def transcript_entries(run_dir) when is_binary(run_dir),
    do: JSON.read_jsonl(transcript_events_path(run_dir))

  def run_path(run_dir), do: Path.join(run_dir, "run.json")
  def events_path(run_dir), do: Path.join(run_dir, "events.jsonl")
  def transcript_events_path(run_dir), do: Path.join(run_dir, "transcript.jsonl")
  def transcript_path(run_dir), do: Path.join(run_dir, "transcript.md")
end
