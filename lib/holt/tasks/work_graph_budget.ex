defmodule Holt.Tasks.WorkGraphBudget do
  @moduledoc """
  Group-level token and concurrency budget for task work graphs.

  This belongs to the orchestration boundary, not to one agent chat. Individual
  agent runs receive slices while verification and repair reserves stay
  available to the group.
  """

  @schema_version "holt_work_graph_budget/v1"
  @default_total_tokens 64_000
  @default_max_concurrent_agents 4
  @legacy_keys ~w(group_token_budget token_budget max_agents_per_event max_agents agents graph_id task_id task_ref)

  def build(attrs \\ %{})

  def build(attrs) when is_map(attrs) do
    case input(attrs) do
      {:ok, input} -> build_canonical(input)
      {:error, reason} -> rejected_budget(reason)
    end
  end

  def build(_attrs), do: rejected_budget("invalid_attrs")

  defp input(attrs) do
    with :ok <- canonical_attrs(attrs),
         :ok <- unsupported_arguments(attrs),
         {:ok, task} <- optional_task(attrs),
         {:ok, work_graph_id} <- optional_text(attrs, "work_graph_id", "invalid_work_graph_id"),
         {:ok, total_tokens} <- total_tokens(attrs),
         {:ok, candidates} <- candidate_agents(attrs),
         {:ok, max_concurrent} <- max_concurrent_agents(attrs, length(candidates)) do
      {:ok,
       %{
         task: task,
         work_graph_id: work_graph_id,
         total_tokens: total_tokens,
         candidates: candidates,
         max_concurrent_agents: max_concurrent
       }}
    end
  end

  defp build_canonical(input) do
    task = input.task
    total_tokens = input.total_tokens
    candidate_count = length(input.candidates)
    max_concurrent = input.max_concurrent_agents
    active_slice_count = max(1, min(max_concurrent, max(candidate_count, 1)))
    reserves = reserves(total_tokens)
    execution_pool = max(total_tokens - Enum.sum(Map.values(reserves)), 0)

    %{
      "schema_version" => @schema_version,
      "budget_id" =>
        stable_id("work_graph_budget", [
          task["id"],
          input.work_graph_id,
          total_tokens,
          candidate_count,
          max_concurrent
        ]),
      "owner_scope" => "task_work_graph",
      "task_id" => task["id"],
      "task_ref" => task["ref"],
      "work_graph_id" => input.work_graph_id,
      "max_total_tokens" => total_tokens,
      "max_concurrent_agents" => max_concurrent,
      "candidate_agent_count" => candidate_count,
      "allocation" =>
        Map.merge(reserves, %{
          "execution_pool_tokens" => execution_pool,
          "per_active_agent_slice_tokens" => div(execution_pool, active_slice_count)
        }),
      "policy" => %{
        "budget_owner" => "dispatch_layer",
        "agent_budget_mode" => "group_slice",
        "reserve_verification_tokens" => true,
        "reserve_repair_tokens" => true,
        "hard_stop_when_group_budget_exhausted" => true
      }
    }
    |> compact()
  end

  defp rejected_budget(reason) do
    %{
      "schema_version" => @schema_version,
      "status" => "rejected",
      "reason" => reason
    }
  end

  defp optional_task(attrs) do
    case Map.fetch(attrs, "task") do
      {:ok, task} when is_map(task) ->
        with :ok <- validate_task(task) do
          {:ok, task}
        end

      {:ok, _task} ->
        {:error, "invalid_task"}

      :error ->
        {:ok, %{}}
    end
  end

  defp validate_task(task) do
    with :ok <- optional_text_field(task, "id", "invalid_task"),
         :ok <- optional_text_field(task, "ref", "invalid_task") do
      :ok
    end
  end

  defp total_tokens(attrs) do
    case Map.fetch(attrs, "max_total_tokens") do
      {:ok, value} when is_integer(value) and value > 0 -> {:ok, value}
      {:ok, _value} -> {:error, "invalid_max_total_tokens"}
      :error -> {:ok, @default_total_tokens}
    end
  end

  defp candidate_agents(attrs) do
    case Map.fetch(attrs, "candidate_agents") do
      {:ok, candidates} when is_list(candidates) ->
        validate_candidates(candidates)

      {:ok, _candidates} ->
        {:error, "invalid_candidate_agents"}

      :error ->
        {:ok, []}
    end
  end

  defp validate_candidates(candidates) do
    case Enum.all?(candidates, &valid_candidate?/1) do
      true -> {:ok, candidates}
      false -> {:error, "invalid_candidate_agents"}
    end
  end

  defp valid_candidate?(candidate) when is_map(candidate), do: canonical_value?(candidate)
  defp valid_candidate?(_candidate), do: false

  defp max_concurrent_agents(attrs, candidate_count) do
    case Map.fetch(attrs, "max_concurrent_agents") do
      {:ok, value} when is_integer(value) and value > 0 -> {:ok, value}
      {:ok, _value} -> {:error, "invalid_max_concurrent_agents"}
      :error -> {:ok, default_max_concurrent(candidate_count)}
    end
  end

  defp default_max_concurrent(candidate_count) when candidate_count <= 0, do: 1

  defp default_max_concurrent(candidate_count),
    do: min(candidate_count, @default_max_concurrent_agents)

  defp reserves(total_tokens) do
    %{
      "dispatch_reserve_tokens" => percent(total_tokens, 3),
      "planning_reserve_tokens" => percent(total_tokens, 10),
      "verification_reserve_tokens" => percent(total_tokens, 20),
      "repair_reserve_tokens" => percent(total_tokens, 15)
    }
  end

  defp percent(value, percent), do: div(value * percent, 100)

  defp unsupported_arguments(attrs) do
    attrs
    |> Map.keys()
    |> Enum.find(&legacy_key?/1)
    |> legacy_key_error()
  end

  defp legacy_key?(key), do: key in @legacy_keys

  defp legacy_key_error(nil), do: :ok
  defp legacy_key_error(key), do: {:error, "unsupported_argument:" <> key}

  defp canonical_attrs(attrs) do
    case canonical_value?(attrs) do
      true -> :ok
      false -> {:error, "invalid_attrs"}
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

  defp optional_text(attrs, key, reason) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, reason}
          text -> {:ok, text}
        end

      {:ok, _value} ->
        {:error, reason}

      :error ->
        {:ok, nil}
    end
  end

  defp optional_text_field(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, reason}
          _text -> :ok
        end

      {:ok, _value} ->
        {:error, reason}

      :error ->
        :ok
    end
  end

  defp compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end

  defp stable_id(prefix, parts) do
    digest =
      :crypto.hash(:sha256, :erlang.term_to_binary(parts))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 24)

    "#{prefix}_#{digest}"
  end
end
