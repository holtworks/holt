defmodule HoltWorks.Runtime.Runs do
  @moduledoc """
  Durable run folders and append-only event logs.
  """

  alias HoltWorks.{Clock, JSON, Paths}

  def start(objective, opts \\ []) do
    root = Paths.workspace_root(opts)
    run_id = Clock.id("run")
    slug = run_slug(objective)
    run_dir = Path.join(Paths.runs_dir(root), slug)
    artifacts_dir = Path.join(run_dir, "artifacts")
    now = Clock.iso_now()

    File.mkdir_p!(artifacts_dir)

    run =
      %{
        "schema_version" => "holtworks_run/v1",
        "id" => run_id,
        "status" => "created",
        "objective" => objective,
        "agent" => opts[:agent] || "default",
        "model" => opts[:model] || "local:local-planner",
        "started_at" => now,
        "completed_at" => nil,
        "workspace" => root,
        "safety_mode" => opts[:safety_mode] || "approval_required",
        "run_dir" => run_dir,
        "resumed_from" => opts[:resumed_from]
      }
      |> reject_empty()

    JSON.write(run_path(run_dir), run)
    append_event(run_dir, "run.created", %{"objective" => objective, "status" => "created"})
    transition(run_dir, "queued")

    {:ok, Map.put(run, "status", "queued")}
  end

  def transition(run_dir, status, attrs \\ %{}) do
    run = load_run!(run_dir)
    current = Map.get(run, "status")

    with {:ok, next} <- HoltWorks.Runtime.StateMachine.transition(current, status) do
      updated =
        run
        |> Map.put("status", next)
        |> maybe_complete(next)
        |> Map.merge(attrs)

      JSON.write(run_path(run_dir), updated)
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

  def load_run!(run_dir), do: JSON.read(run_path(run_dir))

  def append_event(run_dir, type, data \\ %{}) do
    event =
      data
      |> Map.put("type", type)
      |> Map.put_new("at", Clock.iso_now())

    JSON.append_jsonl(events_path(run_dir), event)
    event
  end

  def append_transcript(run_dir, role, content) do
    File.write!(
      transcript_path(run_dir),
      ["\n\n## ", role, "\n\n", content, "\n"],
      [:append]
    )
  end

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
    |> Enum.find(fn run -> run["id"] == id or Path.basename(run["run_dir"]) == id end)
  end

  def list(root) do
    root
    |> Paths.runs_dir()
    |> list_run_dirs()
    |> Enum.sort(:desc)
    |> Enum.map(&load_run!/1)
  end

  def events(run_dir), do: JSON.read_jsonl(events_path(run_dir))

  def run_path(run_dir), do: Path.join(run_dir, "run.json")
  def events_path(run_dir), do: Path.join(run_dir, "events.jsonl")
  def transcript_path(run_dir), do: Path.join(run_dir, "transcript.md")

  defp maybe_complete(run, status)
       when status in ["completed", "blocked", "failed", "canceled"] do
    Map.put(run, "completed_at", Clock.iso_now())
  end

  defp maybe_complete(run, _status), do: run

  defp run_slug(objective) do
    words =
      objective
      |> to_string()
      |> String.downcase()
      |> slugify()
      |> String.trim("-")
      |> String.slice(0, 48)

    "#{Clock.timestamp_slug()}-#{if words == "", do: "run", else: words}"
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
