defmodule Holt.Runtime.SessionStore do
  @moduledoc """
  File-backed checkpoints for live Holt agent sessions.

  The checkpoint is intentionally serializable and transport-neutral. Runtime
  processes own live waiters/subscribers, while this store keeps enough state
  for status reads, recovery inspection, and later resumability work.
  """

  alias Holt.{Clock, JSON, Paths}

  @schema_version "holt_agent_session/v1"
  @resumable_statuses ~w(created queued running awaiting_user)

  def upsert(session_id, checkpoint, opts \\ [])

  def upsert(session_id, checkpoint, opts) when is_binary(session_id) and is_map(checkpoint) do
    root = Paths.workspace_root(opts)
    path = session_path(root, session_id)
    existing = JSON.read(path, %{})
    now = Clock.iso_now()

    stored =
      checkpoint
      |> stringify_keys()
      |> Map.put("schema_version", @schema_version)
      |> Map.put("session_id", session_id)
      |> Map.put_new("inserted_at", inserted_at(existing, now))
      |> Map.put("updated_at", now)
      |> reject_empty()

    JSON.write(path, stored)
    {:ok, stored}
  end

  def upsert(_session_id, _checkpoint, _opts), do: {:error, :invalid_session_checkpoint}

  def get(session_id, opts \\ [])

  def get(session_id, opts) when is_binary(session_id) do
    root = Paths.workspace_root(opts)
    path = session_path(root, session_id)

    if File.exists?(path) do
      {:ok, JSON.read(path)}
    else
      {:error, :not_found}
    end
  end

  def get(_session_id, _opts), do: {:error, :invalid_session_id}

  def list(opts \\ []) do
    root = Paths.workspace_root(opts)
    status = opts[:status]

    root
    |> Paths.sessions_dir()
    |> list_session_files()
    |> Enum.map(&JSON.read/1)
    |> Enum.reject(&(&1 == %{}))
    |> filter_status(status)
    |> Enum.sort_by(&updated_at_sort_key/1, :desc)
  end

  def resumable(opts \\ []) do
    statuses = resumable_statuses(opts)
    list(Keyword.put(opts, :status, statuses))
  end

  def delete(session_id, opts \\ [])

  def delete(session_id, opts) when is_binary(session_id) do
    root = Paths.workspace_root(opts)

    case File.rm(session_path(root, session_id)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def delete(_session_id, _opts), do: {:error, :invalid_session_id}

  defp list_session_files(sessions_dir) do
    case File.ls(sessions_dir) do
      {:ok, names} ->
        names
        |> Enum.map(&Path.join(sessions_dir, &1))
        |> Enum.filter(&(Path.extname(&1) == ".json"))

      _ ->
        []
    end
  end

  defp filter_status(sessions, nil), do: sessions
  defp filter_status(sessions, ""), do: sessions

  defp filter_status(sessions, statuses) do
    allowed =
      statuses
      |> List.wrap()
      |> Enum.map(&to_string/1)
      |> MapSet.new()

    Enum.filter(sessions, &MapSet.member?(allowed, &1["status"]))
  end

  defp session_path(root, session_id) do
    Path.join(Paths.sessions_dir(root), "#{session_file_id(session_id)}.json")
  end

  defp session_file_id(session_id) do
    digest =
      :crypto.hash(:sha256, session_id)
      |> Base.url_encode64(padding: false)

    "session-#{digest}"
  end

  defp inserted_at(existing, now) do
    case existing["inserted_at"] do
      value when value in [nil, ""] -> now
      value -> value
    end
  end

  defp updated_at_sort_key(session) do
    case session["updated_at"] do
      value when value in [nil, ""] -> ""
      value -> value
    end
  end

  defp resumable_statuses(opts) do
    case opts[:statuses] do
      value when value in [nil, []] -> @resumable_statuses
      value -> value
    end
  end

  defp stringify_keys(map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), stringify_value(value)} end)
    |> Map.new()
  end

  defp stringify_value(value) when is_map(value), do: stringify_keys(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value

  defp reject_empty(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end
end
