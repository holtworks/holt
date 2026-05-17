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

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def record_started(payload, context \\ %{}, opts \\ [])

  def record_started(payload, context, opts) when is_map(payload) and is_map(context) do
    handle_started(payload, context, opts)
  end

  def record_started(_payload, _context, _opts), do: {:error, :invalid_process_event}

  def notify_terminal(payload, context \\ %{}, opts \\ [])

  def notify_terminal(payload, context, opts) when is_map(payload) and is_map(context) do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, {:terminal_process_event, payload, context, opts})
    else
      handle_terminal(payload, context, opts)
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
    root =
      opts
      |> Keyword.put(
        :workspace,
        context["workspace"] || context["workspace_root"] || opts[:workspace]
      )
      |> Paths.workspace_root()

    run_id =
      context["agent_run_id"] ||
        context["run_id"] ||
        context["routine_run_id"] ||
        context["work_id"]

    if run_id in [nil, ""] do
      {:error, :missing_agent_run_id}
    else
      {:ok, root, run_id}
    end
  end

  defp terminal_wake_candidate?(payload) do
    terminal_status?(payload["status"]) and notify_on_exit?(payload)
  end

  defp terminal_status?(status), do: status in @terminal_statuses

  defp terminal_event_kind(%{"status" => "missing"}), do: "process.missing"
  defp terminal_event_kind(_payload), do: "process.exited"

  defp notify_on_exit?(payload) do
    case payload["notify_on_exit"] do
      false -> false
      "false" -> false
      _value -> wait_for_exit?(payload)
    end
  end

  defp wait_for_exit?(payload) do
    case payload["wait_for_exit"] do
      false -> false
      "false" -> false
      _value -> true
    end
  end

  def source, do: @source
end
