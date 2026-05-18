defmodule Holt.Tasks.AgentRunLog do
  @moduledoc """
  Facade for the durable task-agent run ledger.
  """

  alias Holt.Paths
  alias Holt.Tasks.AgentRuns

  def list(opts \\ []), do: AgentRuns.list(opts)

  def events(opts \\ []) do
    opts
    |> Paths.workspace_root()
    |> AgentRuns.event_log()
  end

  def event_log(run_or_id, opts \\ []) do
    opts
    |> Paths.workspace_root()
    |> AgentRuns.list_events(run_or_id)
  end

  def by_agent(agent_id, opts \\ []) do
    opts
    |> Paths.workspace_root()
    |> AgentRuns.list_by_agent(agent_id, opts)
  end

  def events_by_agent(agent_id, filters \\ %{}, opts \\ []) when is_map(filters) do
    root = Paths.workspace_root(opts)
    AgentRuns.search_events_by_agent(root, agent_id, filters)
  end

  def replay(agent_id, run_or_id, opts \\ []) do
    opts
    |> Paths.workspace_root()
    |> AgentRuns.replay_by_agent(agent_id, run_or_id)
  end

  def task_inspector(task_ref_or_id, opts \\ []) do
    opts
    |> Paths.workspace_root()
    |> AgentRuns.task_inspector(task_ref_or_id, opts)
  end

  def record_event(run_or_id, attrs, opts \\ [])

  def record_event(run_or_id, attrs, opts) when is_map(attrs) do
    root = Paths.workspace_root(opts)

    with :ok <- canonical_attrs(attrs) do
      AgentRuns.record_event_once(
        root,
        run_or_id,
        event_kind(attrs),
        event_message(attrs),
        event_metadata(attrs)
      )
    end
  end

  def record_event(_run_or_id, _attrs, _opts), do: {:error, :invalid_agent_run_event}

  def record_continuation_packet(run_or_id, attrs, opts \\ []) when is_map(attrs) do
    opts
    |> Paths.workspace_root()
    |> AgentRuns.record_continuation_packet(run_or_id, attrs)
  end

  def record_narration(run_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    opts
    |> Paths.workspace_root()
    |> AgentRuns.record_agent_narration(run_or_id, attrs)
  end

  def record_plan_contract(run_or_id, attrs, opts \\ []) when is_map(attrs) do
    opts
    |> Paths.workspace_root()
    |> AgentRuns.record_plan_contract(run_or_id, attrs)
  end

  def record_child_contract(run_or_id, attrs, opts \\ []) when is_map(attrs) do
    opts
    |> Paths.workspace_root()
    |> AgentRuns.record_child_agent_contract(run_or_id, attrs)
  end

  def record_child_completion(run_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    opts
    |> Paths.workspace_root()
    |> AgentRuns.record_child_agent_completion(run_or_id, attrs)
  end

  def record_action_event(run_or_id, attrs, opts \\ [])

  def record_action_event(run_or_id, attrs, opts) when is_map(attrs) do
    with :ok <- canonical_attrs(attrs),
         {:ok, action} <- required_text(attrs, "action"),
         {:ok, call_id} <- required_text(attrs, "action_call_id"),
         {:ok, result} <- required_map(attrs, "result") do
      opts
      |> Paths.workspace_root()
      |> AgentRuns.record_action_event(run_or_id, action, call_id, result, attrs)
    end
  end

  def record_action_event(_run_or_id, _attrs, _opts), do: {:error, :invalid_action_event}

  def record_objective_evaluation(run_or_id, attrs, opts \\ [])

  def record_objective_evaluation(run_or_id, attrs, opts) when is_map(attrs) do
    with :ok <- canonical_attrs(attrs),
         {:ok, route} <- required_map(attrs, "route") do
      opts
      |> Paths.workspace_root()
      |> AgentRuns.record_objective_evaluation(run_or_id, route, attrs)
    end
  end

  def record_objective_evaluation(_run_or_id, _attrs, _opts),
    do: {:error, :invalid_objective_evaluation}

  defp event_kind(attrs) do
    case Map.get(attrs, "kind") do
      value when value in [nil, ""] -> "agent_run.event"
      kind -> kind
    end
  end

  defp event_message(attrs) do
    case Map.get(attrs, "message") do
      value when value in [nil, ""] -> "Agent run event recorded."
      message -> message
    end
  end

  defp event_metadata(attrs) do
    case Map.get(attrs, "metadata") do
      metadata when is_map(metadata) -> metadata
      _missing -> %{}
    end
  end

  defp required_text(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:missing_required, key}}
          text -> {:ok, text}
        end

      _missing ->
        {:error, {:missing_required, key}}
    end
  end

  defp required_map(attrs, key) do
    case Map.get(attrs, key) do
      value when is_map(value) -> {:ok, value}
      _missing -> {:error, {:missing_required, key}}
    end
  end

  defp canonical_attrs(attrs) do
    case canonical_value?(attrs) do
      true -> :ok
      false -> {:error, :invalid_attrs}
    end
  end

  defp canonical_value?(value) when is_map(value) do
    Enum.all?(value, fn
      {key, nested} when is_binary(key) -> canonical_value?(nested)
      _entry -> false
    end)
  end

  defp canonical_value?(values) when is_list(values), do: Enum.all?(values, &canonical_value?/1)
  defp canonical_value?(_value), do: true
end
