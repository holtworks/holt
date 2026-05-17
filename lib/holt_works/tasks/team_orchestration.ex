defmodule HoltWorks.Tasks.TeamOrchestration do
  @moduledoc """
  Structured team-run plan for task-agent work.

  This describes the orchestration shape without spawning work by itself.
  """

  alias HoltWorks.Tasks.RuntimeContracts

  @schema_version "holtworks_team_orchestration/v1"

  def plan(attrs \\ %{})

  def plan(attrs) when is_map(attrs) do
    attrs = RuntimeContracts.string_keys(attrs)
    complexity = complexity(attrs)

    %{
      "schema_version" => @schema_version,
      "mode" => mode(complexity),
      "task_complexity" => complexity,
      "max_concurrent_agents" => max_concurrent_agents(complexity),
      "stages" => stages(complexity),
      "handoff_contract" => handoff_contract()
    }
  end

  def plan(_attrs), do: plan(%{})

  defp complexity(attrs) do
    explicit = RuntimeContracts.text(attrs, "task_complexity")

    cond do
      explicit in ~w(trivial normal implementation broad_parallel) ->
        explicit

      RuntimeContracts.integer(RuntimeContracts.value(attrs, "estimate")) >= 8 ->
        "broad_parallel"

      RuntimeContracts.integer(RuntimeContracts.value(attrs, "estimate")) >= 3 ->
        "implementation"

      RuntimeContracts.integer(RuntimeContracts.value(attrs, "estimate")) > 0 ->
        "trivial"

      true ->
        "normal"
    end
  end

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
