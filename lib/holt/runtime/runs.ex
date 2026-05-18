defmodule Holt.Runtime.Runs do
  @moduledoc """
  Durable run folders and append-only event logs.
  """

  alias Holt.{Clock, Paths}
  alias Holt.Runtime.RunStore

  def start(objective, opts \\ []) do
    root = Paths.workspace_root(opts)
    start_in_dir(objective, opts, root, Paths.runs_dir(root), "workspace")
  end

  def start_ephemeral(objective, opts \\ []) do
    root = Paths.workspace_root(opts)
    runs_dir = ephemeral_runs_dir(opts)

    start_in_dir(objective, opts, root, runs_dir, "ephemeral")
  end

  defp start_in_dir(objective, opts, root, runs_dir, workspace_persistence) do
    run_id = Clock.id("run")
    slug = run_slug(objective, run_id)
    run_dir = Path.join(runs_dir, slug)
    artifacts_dir = Path.join(run_dir, "artifacts")
    now = Clock.iso_now()

    File.mkdir_p!(artifacts_dir)

    run =
      %{
        "schema_version" => "holt_run/v1",
        "id" => run_id,
        "status" => "created",
        "objective" => objective,
        "agent_id" => run_agent_id(opts),
        "model" => run_model(opts),
        "started_at" => now,
        "completed_at" => nil,
        "workspace" => root,
        "safety_mode" => run_safety_mode(opts),
        "permission_mode" => run_permission_mode(opts),
        "run_dir" => run_dir,
        "workspace_persistence" => workspace_persistence,
        "workspace_discovery" => opts[:workspace_discovery],
        "pre_task_plan" => opts[:pre_task_plan],
        "resumed_from" => opts[:resumed_from],
        "forked_from" => opts[:forked_from]
      }
      |> reject_empty()

    RunStore.write_run(run_dir, run)

    append_event(
      run_dir,
      "run.created",
      %{
        "objective" => objective,
        "status" => "created",
        "permission_mode" => run["permission_mode"],
        "workspace_persistence" => run["workspace_persistence"],
        "workspace_discovery" => run["workspace_discovery"],
        "resumed_from" => run["resumed_from"],
        "forked_from" => run["forked_from"]
      }
      |> reject_empty()
    )

    transition(run_dir, "queued")

    {:ok, Map.put(run, "status", "queued")}
  end

  def transition(run_dir, status, attrs \\ %{}) do
    run = load_run!(run_dir)
    current = Map.get(run, "status")

    with {:ok, next} <- Holt.Runtime.StateMachine.transition(current, status) do
      updated =
        run
        |> Map.put("status", next)
        |> maybe_complete(next)
        |> Map.merge(attrs)

      RunStore.write_run(run_dir, updated)
      append_event(run_dir, "run.transitioned", %{"from" => current, "to" => next})
      {:ok, updated}
    end
  end

  def complete(run_dir, attrs \\ %{}) do
    transition(run_dir, "completed", attrs)
  end

  def block(run_dir, reason, attrs \\ %{}) do
    transition(run_dir, "blocked", Map.merge(%{"blocked_reason" => reason}, attrs))
  end

  def fail(run_dir, reason, attrs \\ %{}) do
    transition(run_dir, "failed", Map.merge(%{"failure_reason" => inspect(reason)}, attrs))
  end

  def load_run!(run_dir), do: RunStore.read_run(run_dir)

  def append_event(run_dir, type, data \\ %{}), do: RunStore.append_event(run_dir, type, data)

  def append_transcript(run_dir, role, content),
    do: RunStore.append_transcript(run_dir, role, content)

  def latest(root) do
    runs_dir = Paths.runs_dir(root)

    runs_dir
    |> list_run_dirs()
    |> Enum.sort(:desc)
    |> List.first()
    |> case do
      nil -> nil
      run_dir -> load_run!(run_dir)
    end
  end

  def find(root, nil), do: latest(root)
  def find(root, "latest"), do: latest(root)

  def find(root, id) do
    root
    |> list()
    |> Enum.find(&run_matches_ref?(&1, id))
  end

  def list(root) do
    root
    |> Paths.runs_dir()
    |> list_run_dirs()
    |> Enum.sort(:desc)
    |> Enum.map(&load_run!/1)
  end

  def events(run_dir), do: RunStore.events(run_dir)
  def transcript_entries(run_dir), do: RunStore.transcript_entries(run_dir)

  def run_path(run_dir), do: RunStore.run_path(run_dir)
  def events_path(run_dir), do: RunStore.events_path(run_dir)
  def transcript_events_path(run_dir), do: RunStore.transcript_events_path(run_dir)
  def transcript_path(run_dir), do: RunStore.transcript_path(run_dir)

  defp maybe_complete(run, status)
       when status in ["completed", "blocked", "failed", "canceled"] do
    Map.put(run, "completed_at", Clock.iso_now())
  end

  defp maybe_complete(run, _status), do: run

  defp ephemeral_runs_dir(opts) do
    case opts[:ephemeral_runs_dir] do
      value when value in [nil, ""] -> Path.join(System.tmp_dir!(), "holtworks-runs")
      value -> value
    end
  end

  defp run_agent_id(opts), do: run_option(opts, :agent_id, "default")
  defp run_model(opts), do: run_option(opts, :model, "local:local-planner")
  defp run_safety_mode(opts), do: run_option(opts, :safety_mode, "approval_required")
  defp run_permission_mode(opts), do: run_option(opts, :permission_mode, "review")

  defp run_option(opts, key, default) do
    case opts[key] do
      value when value in [nil, ""] -> default
      value -> value
    end
  end

  defp run_matches_ref?(run, id) do
    Enum.any?([run["id"] == id, Path.basename(run["run_dir"]) == id], & &1)
  end

  defp run_slug(objective, run_id) do
    words =
      objective
      |> to_string()
      |> String.downcase()
      |> slugify()
      |> String.trim("-")
      |> String.slice(0, 48)

    run_ref =
      run_id
      |> String.downcase()
      |> String.replace("_", "-")

    "#{Clock.timestamp_slug()}-#{run_ref}-#{if words == "", do: "run", else: words}"
  end

  defp slugify(text) do
    text
    |> String.to_charlist()
    |> Enum.map(&slug_char/1)
    |> collapse_slug_chars([])
    |> Enum.reverse()
    |> to_string()
  end

  defp slug_char(char) when char in ?a..?z, do: char
  defp slug_char(char) when char in ?0..?9, do: char
  defp slug_char(_char), do: ?-

  defp collapse_slug_chars([], acc), do: acc
  defp collapse_slug_chars([?- | rest], []), do: collapse_slug_chars(rest, [])
  defp collapse_slug_chars([?- | rest], [?- | _tail] = acc), do: collapse_slug_chars(rest, acc)
  defp collapse_slug_chars([char | rest], acc), do: collapse_slug_chars(rest, [char | acc])

  defp reject_empty(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end

  defp list_run_dirs(runs_dir) do
    case File.ls(runs_dir) do
      {:ok, names} ->
        names
        |> Enum.map(&Path.join(runs_dir, &1))
        |> Enum.filter(&File.dir?/1)

      _ ->
        []
    end
  end
end
