defmodule Holt.Tasks.TeamOrchestration do
  @moduledoc """
  Structured team-run plan for task-agent work.

  This describes the orchestration shape without spawning work by itself.
  """

  @schema_version "holt_team_orchestration/v1"
  @complexities ~w(trivial normal implementation broad_parallel)

  def plan(attrs \\ %{})

  def plan(attrs) when is_map(attrs) do
    case input(attrs) do
      {:ok, input} -> build_plan(input)
      {:error, reason} -> rejected_plan(reason)
    end
  end

  def plan(_attrs), do: rejected_plan("invalid_attrs")

  defp input(attrs) do
    with :ok <- canonical_attrs(attrs),
         {:ok, complexity} <- optional_complexity(attrs),
         {:ok, estimate} <- optional_estimate(attrs) do
      {:ok, %{complexity: complexity(complexity, estimate)}}
    end
  end

  defp build_plan(input) do
    complexity = input.complexity

    %{
      "schema_version" => @schema_version,
      "mode" => mode(complexity),
      "task_complexity" => complexity,
      "max_concurrent_agents" => max_concurrent_agents(complexity),
      "stages" => stages(complexity),
      "handoff_contract" => handoff_contract()
    }
  end

  defp rejected_plan(reason) do
    %{
      "schema_version" => @schema_version,
      "status" => "rejected",
      "reason" => reason
    }
  end

  defp complexity(nil, estimate), do: complexity_from_estimate(estimate)
  defp complexity(complexity, _estimate), do: complexity

  defp optional_complexity(attrs) do
    case Map.fetch(attrs, "task_complexity") do
      {:ok, value} when is_binary(value) ->
        case String.trim(value) do
          complexity when complexity in @complexities -> {:ok, complexity}
          _invalid -> {:error, "invalid_task_complexity"}
        end

      {:ok, _value} ->
        {:error, "invalid_task_complexity"}

      :error ->
        {:ok, nil}
    end
  end

  defp optional_estimate(attrs) do
    case Map.fetch(attrs, "estimate") do
      {:ok, value} when is_integer(value) and value > 0 -> {:ok, value}
      {:ok, _value} -> {:error, "invalid_estimate"}
      :error -> {:ok, nil}
    end
  end

  defp complexity_from_estimate(estimate) when is_integer(estimate) and estimate >= 8,
    do: "broad_parallel"

  defp complexity_from_estimate(estimate) when is_integer(estimate) and estimate >= 3,
    do: "implementation"

  defp complexity_from_estimate(estimate) when is_integer(estimate) and estimate > 0,
    do: "trivial"

  defp complexity_from_estimate(nil), do: "normal"

  defp mode("trivial"), do: "single_executor"
  defp mode("implementation"), do: "execute_verify_fix"
  defp mode("broad_parallel"), do: "planner_executor_verifier_team"
  defp mode(_complexity), do: "single_executor_with_verification"

  defp max_concurrent_agents("broad_parallel"), do: 4
  defp max_concurrent_agents(_complexity), do: 1

  defp stages("trivial"), do: [stage("execute", "executor", false)]

  defp stages("implementation") do
    [
      stage("execute", "executor", false),
      stage("verify", "verifier", true),
      stage("fix", "fixer", false)
    ]
  end

  defp stages("broad_parallel") do
    [
      stage("plan", "planner", true),
      stage("execute", "executor", false),
      stage("verify", "verifier", true),
      stage("fix", "fixer", false)
    ]
  end

  defp stages(_complexity) do
    [
      stage("execute", "executor", false),
      stage("verify", "verifier", true)
    ]
  end

  defp stage(name, role, required?) do
    %{"name" => name, "role" => role, "required" => required?}
  end

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

  defp handoff_contract do
    %{
      "artifact_kind" => "handoff",
      "required_fields" => [
        "objective",
        "scope",
        "changed_files",
        "commands_run",
        "verification",
        "blockers",
        "next_step"
      ]
    }
  end
end
