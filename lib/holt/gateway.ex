defmodule Holt.Gateway do
  @moduledoc """
  In-process local gateway. V0 intentionally exposes no public listener.
  """

  use GenServer

  alias Holt.{Clock, JSON, Paths}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def status(opts \\ []) do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, {:status, opts})
    else
      file_status(opts)
    end
  end

  def open_session(objective, opts \\ []) do
    GenServer.call(__MODULE__, {:open_session, objective, opts})
  end

  def close_session(id) do
    GenServer.call(__MODULE__, {:close_session, id})
  end

  @impl true
  def init(opts) do
    state = %{
      "schema_version" => "holtworks_gateway/v1",
      "status" => "running",
      "transport" => "in_process",
      "bind" => "none",
      "loopback_only" => true,
      "public_listener" => false,
      "started_at" => Clock.iso_now(),
      "sessions" => %{}
    }

    persist_status(state, opts)
    {:ok, state}
  end

  @impl true
  def handle_call({:status, opts}, _from, state) do
    persist_status(state, opts)
    {:reply, Map.put(state, "session_count", map_size(state["sessions"])), state}
  end

  def handle_call({:open_session, objective, opts}, _from, state) do
    id = Clock.id("sess")

    session = %{
      "id" => id,
      "objective" => objective,
      "workspace" => Paths.workspace_root(opts),
      "created_at" => Clock.iso_now()
    }

    state = put_in(state, ["sessions", id], session)
    persist_status(state, opts)
    {:reply, {:ok, session}, state}
  end

  def handle_call({:close_session, id}, _from, state) do
    state = update_in(state, ["sessions"], &Map.delete(&1, id))
    persist_status(state, [])
    {:reply, :ok, state}
  end

  defp persist_status(state, opts) do
    home = Paths.home(opts)
    Paths.ensure_global(home)
    JSON.write(Paths.gateway_status_path(home), Map.drop(state, ["sessions"]))
  end

  defp file_status(opts) do
    home = Paths.home(opts)

    home
    |> Paths.gateway_status_path()
    |> JSON.read(%{
      "schema_version" => "holtworks_gateway/v1",
      "status" => "stopped",
      "transport" => "in_process",
      "bind" => "none",
      "loopback_only" => true,
      "public_listener" => false
    })
  end
end
