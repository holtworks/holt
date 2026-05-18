defmodule Holt.Tasks.ContextBudget do
  @moduledoc """
  Structured context and compression budget wrapper for task-agent runs.
  """

  alias Holt.Tasks.ContextBudgetGovernor

  @schema_version "holt_context_budget/v1"

  def build(attrs \\ %{})

  def build(attrs) when is_map(attrs) do
    with :ok <- canonical_attrs(attrs),
         {:ok, policy} <- map_field(attrs, "policy"),
         {:ok, provider_profile} <- map_field(attrs, "provider_profile"),
         {:ok, max_total_tokens} <- positive_integer_field(policy, "max_total_tokens"),
         {:ok, max_action_calls} <- positive_integer_field(policy, "max_action_calls"),
         {:ok, max_wall_clock_seconds} <-
           positive_integer_field(policy, "max_wall_clock_seconds"),
         {:ok, provider_context_window} <-
           positive_integer_field(provider_profile, "context_window"),
         {:ok, run_token_budget} <- positive_integer_field(attrs, "run_token_budget") do
      governor = ContextBudgetGovernor.plan(governor_attrs(attrs, policy, provider_profile))

      %{
        "schema_version" => @schema_version,
        "max_total_tokens" => max_total_tokens,
        "max_action_calls" => max_action_calls,
        "max_wall_clock_seconds" => max_wall_clock_seconds,
        "provider_context_window" => provider_context_window,
        "run_token_budget" => run_token_budget,
        "governor" => governor,
        "compression" => compression_contract(policy)
      }
      |> reject_empty()
    else
      {:error, reason} -> rejected_budget(reason)
    end
  end

  def build(_attrs), do: rejected_budget("invalid_attrs")

  defp rejected_budget(reason) do
    %{
      "schema_version" => @schema_version,
      "status" => "rejected",
      "reason" => reason
    }
  end

  defp map_field(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_map(value) -> canonical_nested_map(key, value)
      {:ok, _value} -> {:error, "invalid_field:#{key}"}
      :error -> {:ok, %{}}
    end
  end

  defp positive_integer_field(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_integer(value) and value > 0 -> {:ok, value}
      {:ok, _value} -> {:error, "invalid_field:#{key}"}
      :error -> {:ok, nil}
    end
  end

  defp governor_attrs(attrs, policy, provider_profile) do
    %{}
    |> put_present("policy", policy)
    |> put_present("provider_profile", provider_profile)
    |> put_existing(attrs, "run_token_budget")
    |> put_existing(attrs, "messages")
    |> put_existing(attrs, "actions")
    |> put_existing(attrs, "estimated_input_tokens")
    |> put_existing(attrs, "output_reserve_tokens")
    |> put_existing(attrs, "action_reserve_tokens")
    |> put_existing(attrs, "hard_limit_tokens")
    |> put_existing(attrs, "soft_limit_tokens")
    |> put_existing(attrs, "critical_limit_tokens")
  end

  defp put_present(map, _key, value) when value in [%{}, []], do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp put_existing(target, source, key) do
    if Map.has_key?(source, key) do
      Map.put(target, key, Map.fetch!(source, key))
    else
      target
    end
  end

  defp compression_contract(policy) do
    %{
      "strategy" => "file_backed_task_memory_packet",
      "summary_token_target" => summary_token_target(policy),
      "durable_truth" => "file_backed_task_memory",
      "requires_artifact_refs" => true,
      "preserve_event_kinds" => [
        "agent_run.queued",
        "agent_run.started",
        "agent_run.completed",
        "agent_run.failed",
        "agent_run.decision",
        "agent_run.continuation_packet"
      ]
    }
  end

  defp summary_token_target(policy) do
    max_total =
      case Map.get(policy, "max_total_tokens") do
        int when is_integer(int) and int > 0 -> int
        _value -> 64_000
      end

    cond do
      max_total <= 4_000 -> 600
      max_total <= 64_000 -> 1_200
      true -> 2_400
    end
  end

  defp canonical_nested_map(key, map) do
    case canonical_attrs(map) do
      :ok -> {:ok, map}
      {:error, _reason} -> {:error, "invalid_field:#{key}"}
    end
  end

  defp canonical_attrs(attrs) do
    if Enum.all?(attrs, fn {key, _value} -> is_binary(key) end) do
      :ok
    else
      {:error, "invalid_attrs"}
    end
  end

  defp reject_empty(map) do
    map
    |> Enum.reject(fn {_key, value} -> empty?(value) end)
    |> Map.new()
  end

  defp empty?(nil), do: true
  defp empty?(""), do: true
  defp empty?([]), do: true
  defp empty?(map) when is_map(map), do: map_size(map) == 0
  defp empty?(_value), do: false
end
