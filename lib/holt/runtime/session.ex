defmodule Holt.Runtime.Session do
  @moduledoc """
  Supervised live session wrapper around `Holt.Runtime.run/2`.

  Sessions provide the Inktrail-style runtime surface Holt needs: subscribers
  receive stream events, `ask` actions pause in `awaiting_user`, and status is
  checkpointed to disk through `SessionStore`.
  """

  use GenServer, restart: :temporary

  alias Holt.{Clock, Paths, Runtime, Workspace}
  alias Holt.Runtime.SessionStore

  @default_await_timeout_ms 600_000

  def start(objective) when is_binary(objective), do: start(objective, [])

  def start(opts) when is_list(opts) do
    case Keyword.get(opts, :objective) do
      objective when is_binary(objective) -> start(objective, opts)
      _missing -> {:error, :objective_required}
    end
  end

  def start(objective, opts) when is_binary(objective) do
    session_id = session_id(opts)

    opts =
      opts
      |> Keyword.put(:objective, objective)
      |> Keyword.put(:session_id, session_id)
      |> Keyword.put_new(:caller_pid, self())

    child = {__MODULE__, opts}

    case DynamicSupervisor.start_child(Holt.Runtime.SessionSupervisor, child) do
      {:ok, _pid} ->
        status(session_id, opts)

      {:error, {:already_started, pid}} ->
        {:ok, GenServer.call(pid, :status)}

      error ->
        error
    end
  end

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: via(session_id))
  end

  def subscribe(session_id, subscriber \\ self())
      when is_binary(session_id) and is_pid(subscriber) do
    case lookup(session_id) do
      {:ok, pid} -> GenServer.call(pid, {:subscribe, subscriber})
      {:error, reason} -> {:error, reason}
    end
  end

  def status(session_id, opts \\ []) when is_binary(session_id) do
    case lookup(session_id) do
      {:ok, pid} -> {:ok, GenServer.call(pid, :status)}
      {:error, :session_not_found} -> SessionStore.get(session_id, opts)
    end
  end

  def respond(session_id, answer, _opts \\ []) when is_binary(session_id) do
    case lookup(session_id) do
      {:ok, pid} -> GenServer.call(pid, {:respond, answer})
      {:error, reason} -> {:error, reason}
    end
  end

  def resume(session_id, answer, opts \\ []) do
    respond(session_id, answer, opts)
  end

  def list(opts \\ []), do: SessionStore.list(opts)
  def resumable(opts \\ []), do: SessionStore.resumable(opts)

  def via(session_id), do: {:via, Registry, {Holt.Runtime.SessionRegistry, session_id}}

  defp session_id(opts) do
    case opts[:session_id] do
      value when value in [nil, ""] -> Clock.id("session")
      value -> value
    end
  end

  @impl true
  def init(opts) do
    objective = Keyword.fetch!(opts, :objective)
    session_id = Keyword.fetch!(opts, :session_id)
    workspace = Paths.workspace_root(opts)
    Workspace.init(workspace)

    state = %{
      session_id: session_id,
      objective: objective,
      opts: opts,
      status: "queued",
      run: nil,
      result: nil,
      error: nil,
      started_at: Clock.iso_now(),
      completed_at: nil,
      task_ref: nil,
      task_pid: nil,
      awaiting: nil,
      subscribers: %{},
      accumulated_content: ""
    }

    state =
      opts
      |> Keyword.get(:caller_pid)
      |> put_subscriber(state)
      |> checkpoint!()

    Process.send_after(self(), :run_session, 0)
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, checkpoint(state), state}
  end

  def handle_call({:subscribe, subscriber}, _from, state) do
    state = put_subscriber(subscriber, state) |> checkpoint!()
    {:reply, {:ok, checkpoint(state)}, state}
  end

  def handle_call({:respond, _answer}, _from, %{awaiting: nil} = state) do
    {:reply, {:error, :not_awaiting_user}, state}
  end

  def handle_call({:respond, answer}, _from, state) do
    awaiting = state.awaiting
    answer = event_text(answer)
    send(awaiting.waiter, {:holt_user_response, awaiting.ref, answer})

    state =
      state
      |> Map.put(:status, "running")
      |> Map.put(:awaiting, nil)
      |> checkpoint!()

    broadcast(state, %{
      "type" => "user_response",
      "answer" => answer,
      "action_call_id" => awaiting.action_call_id
    })

    {:reply, {:ok, checkpoint(state)}, state}
  end

  @impl true
  def handle_info(:run_session, state) do
    owner = self()
    session_id = state.session_id

    runtime_opts =
      state.opts
      |> Keyword.put(:agent_event_session_id, session_id)
      |> Keyword.put(:runtime_event_callback, fn event ->
        send(owner, {:runtime_event, event})
      end)
      |> Keyword.put(:await_user_callback, fn question, metadata ->
        await_user(owner, question, metadata)
      end)

    task =
      Task.Supervisor.async_nolink(Holt.Runtime.SessionTaskSupervisor, fn ->
        Runtime.run(state.objective, runtime_opts)
      end)

    state =
      state
      |> Map.put(:status, "running")
      |> Map.put(:task_ref, task.ref)
      |> Map.put(:task_pid, task.pid)
      |> checkpoint!()

    broadcast(state, %{"type" => "session_started"})
    {:noreply, state}
  end

  def handle_info({:runtime_event, %{} = event}, state) do
    state =
      case event["type"] do
        "stream_chunk" ->
          content = event_text(event["content"])
          Map.update!(state, :accumulated_content, &(&1 <> content))

        _other ->
          state
      end

    state = checkpoint!(state)
    broadcast(state, event)
    {:noreply, state}
  end

  def handle_info({:await_user, waiter, ref, question, metadata}, state) do
    awaiting = %{
      ref: ref,
      waiter: waiter,
      question: event_text(question),
      description: metadata["description"],
      options: question_options(metadata),
      action_call_id: metadata["action_call_id"],
      turn: metadata["turn"],
      started_at: Clock.iso_now()
    }

    state =
      state
      |> Map.put(:status, "awaiting_user")
      |> Map.put(:awaiting, awaiting)
      |> checkpoint!()

    broadcast(state, %{
      "type" => "awaiting_user",
      "question" => awaiting.question,
      "description" => awaiting.description,
      "options" => awaiting.options,
      "action_call_id" => awaiting.action_call_id,
      "turn" => awaiting.turn
    })

    {:noreply, state}
  end

  def handle_info({ref, result}, %{task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    {status, run, error} = result_status(result)

    state =
      state
      |> Map.put(:status, status)
      |> Map.put(:run, run)
      |> Map.put(:result, result_summary(result))
      |> Map.put(:error, error)
      |> Map.put(:task_ref, nil)
      |> Map.put(:task_pid, nil)
      |> Map.put(:completed_at, Clock.iso_now())
      |> checkpoint!()

    if status == "completed" do
      broadcast(state, %{"type" => "stream_done", "content" => state.accumulated_content})
    else
      broadcast(state, %{"type" => "stream_error", "reason" => stream_error_reason(error, status)})
    end

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task_ref: ref} = state) do
    state =
      state
      |> Map.put(:status, "failed")
      |> Map.put(:error, inspect(reason))
      |> Map.put(:task_ref, nil)
      |> Map.put(:task_pid, nil)
      |> Map.put(:completed_at, Clock.iso_now())
      |> checkpoint!()

    broadcast(state, %{"type" => "stream_error", "reason" => inspect(reason)})
    {:noreply, state}
  end

  def handle_info({:DOWN, monitor_ref, :process, subscriber, _reason}, state) do
    subscribers =
      state.subscribers
      |> Enum.reject(fn {pid, ref} -> pid == subscriber and ref == monitor_ref end)
      |> Map.new()

    {:noreply, %{state | subscribers: subscribers}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp lookup(session_id) do
    case Registry.lookup(Holt.Runtime.SessionRegistry, session_id) do
      [{pid, _meta}] -> {:ok, pid}
      [] -> {:error, :session_not_found}
    end
  end

  defp await_user(owner, question, metadata) do
    ref = make_ref()
    send(owner, {:await_user, self(), ref, question, metadata_map(metadata)})

    receive do
      {:holt_user_response, ^ref, answer} -> {:ok, answer}
    after
      await_timeout_ms(metadata) -> {:error, :await_user_timeout}
    end
  end

  defp await_timeout_ms(metadata) do
    metadata
    |> Map.get("await_timeout_ms", @default_await_timeout_ms)
    |> normalize_timeout(@default_await_timeout_ms)
  end

  defp normalize_timeout(value, _default) when is_integer(value) and value > 0, do: value

  defp normalize_timeout(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _other -> default
    end
  end

  defp normalize_timeout(_value, default), do: default

  defp event_text(nil), do: ""
  defp event_text(value), do: to_string(value)

  defp question_options(metadata) do
    case metadata["options"] do
      options when is_list(options) -> options
      _missing -> []
    end
  end

  defp stream_error_reason(error, status) do
    case error do
      value when value in [nil, ""] -> status
      value -> value
    end
  end

  defp metadata_map(metadata) when is_map(metadata), do: stringify_keys(metadata)
  defp metadata_map(_metadata), do: %{}

  defp put_subscriber(nil, state), do: state
  defp put_subscriber(pid, state) when not is_pid(pid), do: state

  defp put_subscriber(pid, state) do
    if Map.has_key?(state.subscribers, pid) do
      state
    else
      ref = Process.monitor(pid)
      %{state | subscribers: Map.put(state.subscribers, pid, ref)}
    end
  end

  defp checkpoint!(state) do
    {:ok, _checkpoint} =
      SessionStore.upsert(state.session_id, checkpoint(state), workspace: workspace(state))

    state
  end

  defp checkpoint(state) do
    %{
      "session_id" => state.session_id,
      "status" => state.status,
      "objective" => state.objective,
      "workspace" => workspace(state),
      "home" => state.opts[:home],
      "agent_id" => checkpoint_agent_id(state.opts),
      "run_id" => get_in(run_map(state), ["id"]),
      "run_dir" => get_in(run_map(state), ["run_dir"]),
      "started_at" => state.started_at,
      "completed_at" => state.completed_at,
      "awaiting_user" => awaiting_checkpoint(state.awaiting),
      "accumulated_content_length" => String.length(state.accumulated_content),
      "result" => state.result,
      "error" => state.error
    }
    |> reject_empty()
  end

  defp workspace(state), do: Paths.workspace_root(state.opts)

  defp checkpoint_agent_id(opts) do
    case opts[:agent_id] do
      value when value in [nil, ""] -> "default"
      value -> value
    end
  end

  defp run_map(%{run: run}) when is_map(run), do: run
  defp run_map(_state), do: %{}

  defp awaiting_checkpoint(nil), do: nil

  defp awaiting_checkpoint(awaiting) do
    %{
      "question" => awaiting.question,
      "description" => awaiting.description,
      "options" => awaiting.options,
      "action_call_id" => awaiting.action_call_id,
      "turn" => awaiting.turn,
      "started_at" => awaiting.started_at
    }
    |> reject_empty()
  end

  defp broadcast(state, event) do
    Enum.each(Map.keys(state.subscribers), fn subscriber ->
      send_raw_event(subscriber, event)
      send(subscriber, {:holt_session_event, state.session_id, event})
    end)

    :ok
  end

  defp send_raw_event(pid, %{"type" => "stream_chunk", "content" => content}) do
    send(pid, {:stream_chunk, content})
  end

  defp send_raw_event(pid, %{"type" => "stream_done", "content" => content}) do
    send(pid, {:stream_done, content})
  end

  defp send_raw_event(pid, %{"type" => "stream_error", "reason" => reason}) do
    send(pid, {:stream_error, reason})
  end

  defp send_raw_event(pid, %{"type" => "awaiting_user", "question" => question}) do
    send(pid, {:awaiting_user, question})
  end

  defp send_raw_event(pid, %{"type" => "user_response", "answer" => answer}) do
    send(pid, {:user_response, answer})
  end

  defp send_raw_event(_pid, _event), do: :ok

  defp result_status({:ok, %{run: %{} = run}} = _result) do
    {completed_run_status(run), run, nil}
  end

  defp result_status({:error, %{run: %{} = run, reason: reason}}) do
    {failed_run_status(run), run, inspect(reason)}
  end

  defp result_status({:error, reason}), do: {"failed", nil, inspect(reason)}
  defp result_status(_result), do: {"completed", nil, nil}

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

  defp result_summary({:ok, %{run: %{} = run, output: output, artifact: artifact}}) do
    %{
      "run_id" => run["id"],
      "status" => run["status"],
      "output_length" => output_length(output),
      "artifact" => artifact
    }
    |> reject_empty()
  end

  defp result_summary({:ok, %{run: %{} = run}}) do
    %{"run_id" => run["id"], "status" => run["status"]} |> reject_empty()
  end

  defp result_summary(_result), do: nil

  defp output_length(output) when is_binary(output), do: String.length(output)
  defp output_length(_output), do: nil

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
