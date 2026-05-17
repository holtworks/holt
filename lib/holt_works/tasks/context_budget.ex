defmodule HoltWorks.Tasks.ContextBudget do
  @moduledoc """
  Structured context and compression budget wrapper for task-agent runs.
  """

  alias HoltWorks.Tasks.{ContextBudgetGovernor, RuntimeContracts}

  @schema_version "holtworks_context_budget/v1"

  def build(attrs \\ %{})

  def build(attrs) when is_map(attrs) do
    attrs = RuntimeContracts.string_keys(attrs)
    policy = RuntimeContracts.normalize_map(RuntimeContracts.value(attrs, "policy"))

    provider_profile =
      RuntimeContracts.normalize_map(RuntimeContracts.value(attrs, "provider_profile"))

    governor =
      ContextBudgetGovernor.plan(%{
        "policy" => policy,
        "provider_profile" => provider_profile,
        "run_token_budget" => RuntimeContracts.value(attrs, "run_token_budget"),
        "messages" => RuntimeContracts.value(attrs, "messages") || [],
        "tools" => RuntimeContracts.value(attrs, "tools") || [],
        "estimated_input_tokens" => RuntimeContracts.value(attrs, "estimated_input_tokens"),
        "output_reserve_tokens" => RuntimeContracts.value(attrs, "output_reserve_tokens"),
        "tool_reserve_tokens" => RuntimeContracts.value(attrs, "tool_reserve_tokens")
      })

    %{
      "schema_version" => @schema_version,
      "max_total_tokens" => RuntimeContracts.value(policy, "max_total_tokens"),
      "max_tool_calls" => RuntimeContracts.value(policy, "max_tool_calls"),
      "max_wall_clock_seconds" => RuntimeContracts.value(policy, "max_wall_clock_seconds"),
      "provider_context_window" => RuntimeContracts.value(provider_profile, "context_window"),
      "run_token_budget" => RuntimeContracts.value(attrs, "run_token_budget"),
      "governor" => governor,
      "compression" => compression_contract(policy)
    }
    |> RuntimeContracts.reject_empty()
  end

  def build(_attrs), do: build(%{})

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
      case RuntimeContracts.integer(RuntimeContracts.value(policy, "max_total_tokens")) do
        int when int > 0 -> int
        _int -> 64_000
      end

    cond do
      max_total <= 4_000 -> 600
      max_total <= 64_000 -> 1_200
      true -> 2_400
    end
  end
end
