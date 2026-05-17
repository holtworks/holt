defmodule Holt.Approvals do
  @moduledoc """
  Human approval records for risky local actions.
  """

  alias Holt.{Clock, JSON, Paths}

  def request(%{} = request, opts \\ []) do
    root = Paths.workspace_root(opts)
    id = Clock.id("appr")

    record =
      request
      |> Map.put("schema_version", "holtworks_approval/v1")
      |> Map.put("id", id)
      |> Map.put("status", "pending")
      |> Map.put("created_at", Clock.iso_now())

    path = approval_path(root, id)
    JSON.write(path, record)

    decision =
      case opts[:approval] do
        :always_approve -> "approved"
        :always_deny -> "denied"
        _ -> prompt(record)
      end

    resolve(root, id, decision)
  end

  def resolve(root, id, decision) when decision in ["approved", "denied"] do
    path = approval_path(root, id)
    record = JSON.read(path)

    updated =
      record
      |> Map.put("status", decision)
      |> Map.put("resolved_at", Clock.iso_now())

    JSON.write(path, updated)
    {:ok, updated}
  end

  def resolve(_root, _id, _decision), do: {:error, :invalid_decision}

  def pending(root) do
    root
    |> Paths.approvals_dir()
    |> approval_files()
    |> Enum.map(&JSON.read/1)
    |> Enum.filter(&(Map.get(&1, "status") == "pending"))
  end

  def approval_path(root, id) do
    root
    |> Paths.approvals_dir()
    |> Path.join("#{id}.json")
  end

  defp prompt(record) do
    IO.puts("")
    IO.puts("Holt wants to use: #{record["tool"]}")
    IO.puts("Risk: #{record["risk"]}")
    IO.puts("Reason: #{record["reason"]}")

    if args = record["args"] do
      IO.puts("Arguments:")
      IO.puts(Jason.encode!(args, pretty: true))
    end

    answer = IO.gets("Approve? [y/N] ")

    case String.trim(to_string(answer)) |> String.downcase() do
      "y" -> "approved"
      "yes" -> "approved"
      _ -> "denied"
    end
  end

  defp approval_files(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&(Path.extname(&1) == ".json"))
        |> Enum.map(&Path.join(dir, &1))

      _ ->
        []
    end
  end
end
