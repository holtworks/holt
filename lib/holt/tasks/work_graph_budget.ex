defmodule Holt.Tasks.WorkGraphBudget do
  @moduledoc """
  Group-level token and concurrency budget for task work graphs.

  This belongs to the orchestration boundary, not to one agent chat. Individual
  agent runs receive slices while verification and repair reserves stay
  available to the group.
  """

  alias Holt.Tasks.RuntimeContracts

  @schema_version "holtworks_work_graph_budget/v1"
  @default_total_tokens 64_000
  @default_max_concurrent_agents 4

  def build(attrs \\ %{})

  def build(attrs) when is_map(attrs) do
    attrs = RuntimeContracts.string_keys(attrs)
    task = RuntimeContracts.normalize_map(RuntimeContracts.value(attrs, "task"))
    total_tokens = total_tokens(attrs)
    candidate_count = count(RuntimeContracts.value(attrs, "candidate_agents") || attrs["agents"])
    max_concurrent = max_concurrent_agents(attrs, candidate_count)
    active_slice_count = max(1, min(max_concurrent, max(candidate_count, 1)))
    reserves = reserves(total_tokens)
    execution_pool = max(total_tokens - Enum.sum(Map.values(reserves)), 0)

    %{
      "schema_version" => @schema_version,
      "budget_id" =>
        RuntimeContracts.stable_id("work_graph_budget", [
          RuntimeContracts.text(attrs, "task_id", task["id"]),
          RuntimeContracts.text(attrs, "work_graph_id", RuntimeContracts.text(attrs, "graph_id")),
          total_tokens,
          candidate_count,
          max_concurrent
        ]),
      "owner_scope" => "task_work_graph",
      "task_id" => RuntimeContracts.text(attrs, "task_id", task["id"]),
      "task_ref" => RuntimeContracts.text(attrs, "task_ref", task["ref"]),
      "work_graph_id" => RuntimeContracts.text(attrs, "work_graph_id", attrs["graph_id"]),
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
    |> RuntimeContracts.reject_empty()
  end

  def build(_attrs), do: build(%{})

  defp total_tokens(attrs) do
    first_positive_integer(
      [
        RuntimeContracts.value(attrs, "max_total_tokens"),
        RuntimeContracts.value(attrs, "group_token_budget"),
        RuntimeContracts.value(attrs, "token_budget")
      ],
      @default_total_tokens
    )
  end

  defp max_concurrent_agents(attrs, candidate_count) do
    explicit =
      first_positive_integer(
        [
          RuntimeContracts.value(attrs, "max_concurrent_agents"),
          RuntimeContracts.value(attrs, "max_agents_per_event"),
          RuntimeContracts.value(attrs, "max_agents")
        ],
        nil
      )

    cond do
      is_integer(explicit) -> explicit
      candidate_count <= 0 -> 1
      true -> min(candidate_count, @default_max_concurrent_agents)
    end
  end

  defp reserves(total_tokens) do
    %{
      "dispatch_reserve_tokens" => percent(total_tokens, 3),
      "planning_reserve_tokens" => percent(total_tokens, 10),
      "verification_reserve_tokens" => percent(total_tokens, 20),
      "repair_reserve_tokens" => percent(total_tokens, 15)
    }
  end

  defp percent(value, percent), do: div(value * percent, 100)

  defp count(value) when is_list(value), do: length(value)
  defp count(nil), do: 0
  defp count(_value), do: 1

  defp first_positive_integer(values, fallback) do
    Enum.find_value(values, fallback, &positive_integer/1)
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: value

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} when int > 0 -> int
      _other -> nil
    end
  end

  defp positive_integer(_value), do: nil
end
