defmodule Holt.Tasks.ProcessWakeScheduler do
  @moduledoc """
  Records observed process lifecycle events and prepares same-task wake packets.
  """

  use GenServer

  alias Holt.Paths
  alias Holt.Tasks
  alias Holt.Tasks.AgentRuns

  @source "task_agent_process_wake"
  @terminal_statuses ~w(exited missing)
  @obsolete_context_keys %{
    "workspace" => "workspace option",
    "workspace_root" => "workspace option",
    "run_id" => "agent_run_id",
    "routine_run_id" => "agent_run_id",
    "work_id" => "agent_run_id"
  }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def record_started(payload, context \\ %{}, opts \\ [])

  def record_started(payload, context, opts) when is_map(payload) and is_map(context) do
    with :ok <- string_keyed_payload(payload),
         :ok <- valid_context(context) do
      handle_started(payload, context, opts)
    end
  end

  def record_started(_payload, _context, _opts), do: {:error, :invalid_process_event}

  def notify_terminal(payload, context \\ %{}, opts \\ [])

  def notify_terminal(payload, context, opts) when is_map(payload) and is_map(context) do
    with :ok <- string_keyed_payload(payload),
         :ok <- valid_context(context) do
      if Process.whereis(__MODULE__) do
        GenServer.call(__MODULE__, {:terminal_process_event, payload, context, opts})
      else
        handle_terminal(payload, context, opts)
      end
    end
  end

  def notify_terminal(_payload, _context, _opts), do: {:error, :invalid_process_event}

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call({:terminal_process_event, payload, context, opts}, _from, state) do
    {:reply, handle_terminal(payload, context, opts), state}
  end

  defp handle_started(payload, context, opts) do
    with {:ok, root, run_id} <- process_context(context, opts),
         {:ok, run, event} <-
           AgentRuns.record_process_event(root, run_id, "process.started", payload,
             trigger: "process_started"
           ) do
      {:ok,
       %{
         "action" => "process_recorded",
         "event_kind" => "process.started",
         "agent_run_id" => run["id"],
         "event_id" => event["id"]
       }}
    else
      {:duplicate, run, event} ->
        {:ok,
         %{
           "action" => "duplicate_process_event",
           "event_kind" => "process.started",
           "agent_run_id" => run["id"],
           "event_id" => event["id"]
         }}

      error ->
        error
    end
  end

  defp handle_terminal(payload, context, opts) do
    if terminal_wake_candidate?(payload) do
      kind = terminal_event_kind(payload)

      with {:ok, root, run_id} <- process_context(context, opts),
           {:ok, run, event} <-
             AgentRuns.record_process_event(root, run_id, kind, payload, trigger: "process_exit"),
           {:ok, result} <- Tasks.queue_process_wake_continuation(root, run, event, payload, opts) do
        {:ok, result}
      else
        {:duplicate, run, event} ->
          {:ok,
           %{
             "action" => "duplicate_process_event",
             "event_kind" => kind,
             "agent_run_id" => run["id"],
             "event_id" => event["id"]
           }}

        error ->
          error
      end
    else
      {:ok,
       %{
         "action" => "ignored",
         "reason" => "not_terminal_or_not_waitable",
         "process" => payload
       }}
    end
  end

  defp process_context(context, opts) do
    with :ok <- reject_obsolete_context(context),
         {:ok, run_id} <- agent_run_id(context) do
      {:ok, Paths.workspace_root(opts), run_id}
    end
  end

  defp terminal_wake_candidate?(payload) do
    terminal_status?(payload["status"]) and wait_for_exit?(payload) and notify_on_exit?(payload)
  end

  defp terminal_status?(status), do: status in @terminal_statuses

  defp terminal_event_kind(%{"status" => "missing"}), do: "process.missing"
  defp terminal_event_kind(_payload), do: "process.exited"

  defp notify_on_exit?(%{"notify_on_exit" => false}), do: false
  defp notify_on_exit?(%{"notify_on_exit" => true}), do: true
  defp notify_on_exit?(payload), do: Map.has_key?(payload, "notify_on_exit") == false

  defp wait_for_exit?(%{"wait_for_exit" => true}), do: true
  defp wait_for_exit?(_payload), do: false

  defp agent_run_id(%{"agent_run_id" => run_id}) when is_binary(run_id) and run_id != "",
    do: {:ok, run_id}

  defp agent_run_id(%{"agent_run_id" => _run_id}), do: {:error, :invalid_agent_run_id}
  defp agent_run_id(_context), do: {:error, :missing_agent_run_id}

  defp reject_obsolete_context(context) do
    Enum.reduce_while(@obsolete_context_keys, :ok, fn {key, replacement}, :ok ->
      if Map.has_key?(context, key) do
        {:halt, {:error, {:obsolete_process_context_key, key, replacement}}}
      else
        {:cont, :ok}
      end
    end)
  end

  defp string_keyed_payload(payload), do: string_keyed_map(payload, :invalid_process_payload)
  defp string_keyed_context(context), do: string_keyed_map(context, :invalid_process_context)

  defp valid_context(context) do
    with :ok <- string_keyed_context(context),
         :ok <- reject_obsolete_context(context),
         {:ok, _run_id} <- agent_run_id(context) do
      :ok
    end
  end

  defp string_keyed_map(map, reason) do
    case Enum.find(Map.keys(map), fn key -> is_binary(key) == false end) do
      nil -> :ok
      _key -> {:error, reason}
    end
  end

  def source, do: @source
end
