defmodule Holt.FileDiff do
  @moduledoc """
  Structured text-file diff summaries for workspace file changes.
  """

  alias Holt.Paths

  @context_lines 3

  def preview(action, args, opts) when action in ["write", "append"] and is_map(args) do
    with {:ok, path} <- required_path(args["path"]),
         {:ok, content} <- required_content(args["content"]),
         {:ok, target} <- safe_path(path, opts) do
      root = Paths.workspace_root(opts)
      relative_path = Path.relative_to(target, root)
      before = read_existing_text(target)

      after_content =
        case action do
          "append" -> existing_text(before) <> content
          "write" -> content
        end

      %{"path" => relative_path}
      |> Map.merge(summarize(relative_path, before, after_content))
      |> reject_empty()
    else
      _ -> nil
    end
  end

  def preview(_action, _args, _opts), do: nil

  def read_existing_text(path) do
    case File.read(path) do
      {:ok, content} -> content
      {:error, :enoent} -> ""
      {:error, _reason} -> nil
    end
  end

  def summarize(path, before, after_content) do
    cond do
      secret_path?(path) ->
        %{"diff_redacted" => true}

      invalid_text_pair?(before, after_content) ->
        %{"diff_redacted" => true}

      true ->
        diff = unified_diff(path, before, after_content)

        if diff.additions == 0 and diff.deletions == 0 do
          %{"status" => "unchanged"}
        else
          %{
            "additions" => diff.additions,
            "deletions" => diff.deletions,
            "unified_diff" => diff.unified_diff
          }
        end
    end
  end

  defp required_path(value) when is_binary(value) do
    path = String.trim(value)
    if path == "", do: {:error, :missing_path}, else: {:ok, path}
  end

  defp required_path(_value), do: {:error, :missing_path}

  defp required_content(value) when is_binary(value), do: {:ok, value}
  defp required_content(_value), do: {:error, :missing_content}

  defp existing_text(nil), do: ""
  defp existing_text(content) when is_binary(content), do: content
  defp existing_text(_content), do: ""

  defp invalid_text_pair?(before, after_content) do
    cond do
      not is_binary(before) -> true
      not is_binary(after_content) -> true
      not String.valid?(before) -> true
      not String.valid?(after_content) -> true
      true -> false
    end
  end

  defp safe_path(path, opts) do
    root =
      opts
      |> Paths.workspace_root()
      |> Path.expand()

    target = Path.expand(path, root)

    if under_root?(target, root) do
      {:ok, target}
    else
      {:error, :path_outside_workspace}
    end
  end

  defp under_root?(target, root) do
    root
    |> Path.split()
    |> :lists.prefix(Path.split(target))
  end

  defp unified_diff(path, before, after_content) do
    before_lines = diff_lines(before)
    after_lines = diff_lines(after_content)
    parts = List.myers_difference(before_lines, after_lines)
    additions = diff_count(parts, :ins)
    deletions = diff_count(parts, :del)

    hunks =
      parts
      |> diff_ops()
      |> diff_hunks()

    lines =
      if hunks == [] do
        []
      else
        [
          "--- a/#{path}",
          "+++ b/#{path}"
        ] ++ Enum.flat_map(hunks, &hunk_lines/1)
      end

    %{
      additions: additions,
      deletions: deletions,
      unified_diff: Enum.join(lines, "\n")
    }
  end

  defp diff_lines(""), do: []

  defp diff_lines(content) do
    lines = String.split(content, "\n", trim: false)

    case List.last(lines) do
      "" -> Enum.drop(lines, -1)
      _ -> lines
    end
  end

  defp diff_count(parts, key) do
    parts
    |> Keyword.get_values(key)
    |> Enum.map(&length/1)
    |> Enum.sum()
  end

  defp diff_ops(parts) do
    {_old_line, _new_line, ops} =
      Enum.reduce(parts, {1, 1, []}, fn
        {:eq, lines}, {old_line, new_line, ops} ->
          next_ops =
            Enum.with_index(lines)
            |> Enum.map(fn {line, index} ->
              %{
                kind: :context,
                text: line,
                old_line: old_line + index,
                new_line: new_line + index
              }
            end)

          {old_line + length(lines), new_line + length(lines), ops ++ next_ops}

        {:del, lines}, {old_line, new_line, ops} ->
          next_ops =
            Enum.with_index(lines)
            |> Enum.map(fn {line, index} ->
              %{kind: :delete, text: line, old_line: old_line + index, new_line: nil}
            end)

          {old_line + length(lines), new_line, ops ++ next_ops}

        {:ins, lines}, {old_line, new_line, ops} ->
          next_ops =
            Enum.with_index(lines)
            |> Enum.map(fn {line, index} ->
              %{kind: :insert, text: line, old_line: nil, new_line: new_line + index}
            end)

          {old_line, new_line + length(lines), ops ++ next_ops}
      end)

    ops
  end

  defp diff_hunks(ops) do
    changed =
      ops
      |> Enum.with_index()
      |> Enum.filter(fn {op, _index} -> op.kind != :context end)
      |> Enum.map(fn {_op, index} -> index end)

    ranges =
      changed
      |> Enum.map(fn index ->
        {max(index - @context_lines, 0), min(index + @context_lines, length(ops) - 1)}
      end)
      |> merge_ranges()

    Enum.map(ranges, fn {first, last} ->
      ops
      |> Enum.slice(first, last - first + 1)
      |> hunk_from_ops()
    end)
  end

  defp merge_ranges([]), do: []

  defp merge_ranges([range | ranges]) do
    ranges
    |> Enum.reduce([range], fn {start, finish}, [{current_start, current_finish} | rest] ->
      if start <= current_finish + 1 do
        [{current_start, max(current_finish, finish)} | rest]
      else
        [{start, finish}, {current_start, current_finish} | rest]
      end
    end)
    |> Enum.reverse()
  end

  defp hunk_from_ops(ops) do
    old_numbers = ops |> Enum.map(& &1.old_line) |> Enum.reject(&is_nil/1)
    new_numbers = ops |> Enum.map(& &1.new_line) |> Enum.reject(&is_nil/1)

    %{
      old_start: hunk_start(old_numbers, new_numbers),
      old_count: length(old_numbers),
      new_start: hunk_start(new_numbers, old_numbers),
      new_count: length(new_numbers),
      ops: ops
    }
  end

  defp hunk_start([line | _lines], _other_numbers), do: line
  defp hunk_start([], [line | _other_numbers]), do: max(line - 1, 0)
  defp hunk_start([], []), do: 0

  defp hunk_lines(hunk) do
    [
      "@@ -#{hunk.old_start},#{hunk.old_count} +#{hunk.new_start},#{hunk.new_count} @@"
      | Enum.map(hunk.ops, &op_line/1)
    ]
  end

  defp op_line(%{kind: :context, text: text}), do: " #{text}"
  defp op_line(%{kind: :delete, text: text}), do: "-#{text}"
  defp op_line(%{kind: :insert, text: text}), do: "+#{text}"

  defp secret_path?(path) do
    components =
      path
      |> to_string()
      |> String.downcase()
      |> Path.split()

    basename = List.last(components)

    cond do
      basename in secret_file_names() -> true
      Enum.any?(components, &(&1 in secret_directories())) -> true
      Path.extname(basename) in secret_extensions() -> true
      true -> false
    end
  end

  defp secret_file_names do
    [
      ".env",
      ".env.local",
      ".envrc",
      "id_rsa",
      "id_ed25519",
      "credentials",
      "credentials.json",
      "secrets.json",
      "token",
      "token.json"
    ]
  end

  defp secret_directories, do: [".ssh", ".gnupg", ".aws", ".config"]
  defp secret_extensions, do: [".pem", ".key", ".p12", ".pfx"]

  defp reject_empty(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end
end
