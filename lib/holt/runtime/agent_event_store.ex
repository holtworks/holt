defmodule Holt.Runtime.AgentEventStore do
  @moduledoc """
  File-backed repository for agent session event streams.
  """

  alias Holt.{JSON, Paths}

  def append(root, session_id, event)
      when is_binary(root) and is_binary(session_id) and is_map(event) do
    File.mkdir_p!(Paths.agent_events_dir(root))
    JSON.append_jsonl(session_path(root, session_id), event)
  end

  def list(root, session_id) when is_binary(root) and is_binary(session_id) do
    root
    |> session_path(session_id)
    |> JSON.read_jsonl()
  end

  def session_path(root, session_id) do
    Path.join(Paths.agent_events_dir(root), "#{session_file_id(session_id)}.jsonl")
  end

  def session_file_id(session_id) do
    digest =
      :crypto.hash(:sha256, session_id)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 32)

    "session-#{digest}"
  end
end
