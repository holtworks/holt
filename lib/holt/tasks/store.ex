defmodule Holt.Tasks.Store do
  @moduledoc """
  Durable workspace storage for Holt tasks and task specs.
  """

  alias Holt.{Agents, JSON, Paths}
  alias Holt.Tasks.{AgentRuns, AgentWorkLiveness, TaskGraphs, TaskMemory}

  def tasks_path(root), do: Path.join(Paths.tasks_dir(root), "tasks.json")
  def counter_path(root), do: Path.join(Paths.tasks_dir(root), "counter.json")
  def specs_index_path(root), do: Path.join(Paths.tasks_dir(root), "specs.json")
  def agents_path(root), do: Agents.path(root)
  def agent_events_path(root), do: Agents.events_path(root)
  def agent_runs_path(root), do: AgentRuns.path(root)
  def agent_run_events_path(root), do: AgentRuns.events_path(root)
  def task_graphs_path(root), do: TaskGraphs.path(root)
  def task_graph_events_path(root), do: TaskGraphs.events_path(root)

  def verifier_calibrations_path(root),
    do: Path.join(Paths.tasks_dir(root), "verifier_calibrations.json")

  def ensure(root) do
    Paths.ensure_workspace(root)
    File.mkdir_p!(Paths.tasks_dir(root))
    File.mkdir_p!(Paths.task_specs_dir(root))
    unless File.exists?(tasks_path(root)), do: JSON.write(tasks_path(root), [])
    unless File.exists?(specs_index_path(root)), do: JSON.write(specs_index_path(root), [])
    Agents.ensure_store(root)
    AgentRuns.ensure_store(root)
    TaskGraphs.ensure_store(root)
    TaskMemory.ensure_store(root)

    unless File.exists?(verifier_calibrations_path(root)),
      do: JSON.write(verifier_calibrations_path(root), [])

    unless File.exists?(counter_path(root)),
      do: JSON.write(counter_path(root), %{"next_number" => 1})

    :ok
  end

  def load_tasks(root), do: JSON.read(tasks_path(root), [])
  def load_specs(root), do: JSON.read(specs_index_path(root), [])

  def store_tasks(tasks, root) do
    ensure(root)
    JSON.write(tasks_path(root), tasks)
    :ok
  end

  def store_specs(specs, root) do
    ensure(root)
    JSON.write(specs_index_path(root), specs)
    :ok
  end

  def next_number(root) do
    counter = JSON.read(counter_path(root), %{"next_number" => 1})
    number = Map.get(counter, "next_number", 1)
    JSON.write(counter_path(root), %{"next_number" => number + 1})
    {:ok, number}
  end

  def task_ref(number), do: "HW-" <> String.pad_leading(Integer.to_string(number), 2, "0")

  def task_ref_matches?(task, ref_or_id) do
    ref = ref_or_id |> to_string() |> String.upcase()

    cond do
      task["id"] == to_string(ref_or_id) -> true
      task["ref"] == ref -> true
      task["number"] == parse_ref_number(ref) -> true
      true -> false
    end
  end

  def update_task(root, ref_or_id, fun) do
    tasks = load_tasks(root)

    case Enum.find(tasks, &task_ref_matches?(&1, ref_or_id)) do
      nil ->
        {:error, :task_not_found}

      task ->
        updated = fun.(task)

        tasks
        |> Enum.map(fn candidate ->
          if candidate["id"] == task["id"], do: updated, else: candidate
        end)
        |> store_tasks(root)

        {:ok, updated}
    end
  end

  def enrich_task(root, task) do
    runs = AgentRuns.list_for_task(task["id"], workspace: root)

    task
    |> Map.update("assignees", [], &Agents.enrich_assignees(root, &1))
    |> Map.update("agent_work", [], fn work_items ->
      Enum.map(work_items, &enrich_agent_work(&1, runs))
    end)
  end

  def enrich_agent_work(work), do: AgentWorkLiveness.enrich(work)

  defp enrich_agent_work(work, runs) do
    run =
      Enum.find(runs, fn candidate ->
        agent_work_run?(candidate, work)
      end)

    work
    |> maybe_put_agent_run_summary(run)
    |> AgentWorkLiveness.enrich()
  end

  defp maybe_put_agent_run_summary(work, nil), do: work

  defp maybe_put_agent_run_summary(work, run) do
    Map.put(work, "agent_run", %{
      "id" => run["id"],
      "status" => run["status"],
      "lifecycle_state" => run["lifecycle_state"],
      "runtime_status" => run["runtime_status"],
      "objective_status" => run["objective_status"],
      "agent_id" => run["agent_id"],
      "dispatch_id" => run["dispatch_id"],
      "source" => run["source"],
      "previous_run_id" => run["previous_run_id"]
    })
  end

  defp agent_work_run?(candidate, work) do
    cond do
      candidate["id"] == work["agent_run_id"] -> true
      candidate["work_id"] == work["id"] -> true
      true -> false
    end
  end

  defp parse_ref_number(ref) do
    case :binary.split(ref, "-", [:global]) do
      ["HW", number] -> parse_integer(number)
      [number] -> parse_integer(number)
      _ -> nil
    end
  end

  defp parse_integer(value) do
    case Integer.parse(to_string(value)) do
      {number, ""} -> number
      _ -> nil
    end
  end
end
