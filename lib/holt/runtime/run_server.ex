defmodule Holt.Runtime.RunServer do
  @moduledoc """
  Supervised process boundary for one Holt run.

  `Holt.Runtime.run/2` remains the synchronous core API. This process wraps that
  API so callers that need OTP ownership can start, observe, and await a run.
  """

  use GenServer, restart: :temporary

  alias Holt.Clock

  def start(objective, opts \\ []) when is_binary(objective) do
    child = {__MODULE__, Keyword.merge(opts, objective: objective, caller: self())}
    DynamicSupervisor.start_child(Holt.Runtime.RunSupervisor, child)
  end

  def run(objective, opts \\ []) when is_binary(objective) do
    with {:ok, pid} <- start(objective, opts) do
      await(pid, run_timeout(opts))
    end
  end

  def status(pid) when is_pid(pid), do: GenServer.call(pid, :status)

  def await(pid, timeout \\ :infinity) when is_pid(pid) do
    ref = Process.monitor(pid)

    receive do
      {:holt_run_completed, ^pid, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, ^pid, _reason} ->
        {:error, :run_process_stopped}
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        {:error, :timeout}
    end
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    state = %{
      objective: Keyword.fetch!(opts, :objective),
      opts: Keyword.drop(opts, [:objective, :caller]),
      caller: opts[:caller],
      status: "queued",
      started_at: Clock.iso_now(),
      completed_at: nil,
      result: nil,
      error: nil
    }

    {:ok, state, {:continue, :run}}
  end

  @impl true
  def handle_continue(:run, state) do
    state = %{state | status: "running"}

    result = Holt.Runtime.run(state.objective, state.opts)

    state =
      state
      |> Map.put(:result, result)
      |> Map.put(:status, result_status(result))
      |> Map.put(:error, result_error(result))
      |> Map.put(:completed_at, Clock.iso_now())

    if is_pid(state.caller) do
      send(state.caller, {:holt_run_completed, self(), result})
    end

    {:noreply, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, public_status(state), state}
  end

  defp result_status({:ok, %{run: %{} = run}}), do: completed_run_status(run)
  defp result_status({:error, %{run: %{} = run}}), do: failed_run_status(run)
  defp result_status({:error, _reason}), do: "failed"
  defp result_status(_result), do: "completed"

  defp run_timeout(opts) do
    case opts[:timeout] do
      value when value in [nil, ""] -> :infinity
      value -> value
    end
  end

  defp completed_run_status(run) do
    case run["status"] do
      value when value in [nil, ""] -> "completed"
      value -> value
    end
  end

  defp failed_run_status(run) do
    case run["status"] do
      value when value in [nil, ""] -> "failed"
      value -> value
    end
  end

  defp result_error({:error, %{reason: reason}}), do: inspect(reason)
  defp result_error({:error, reason}), do: inspect(reason)
  defp result_error(_result), do: nil

  defp public_status(state) do
    %{
      status: state.status,
      started_at: state.started_at,
      completed_at: state.completed_at,
      result: state.result,
      error: state.error
    }
  end
end
