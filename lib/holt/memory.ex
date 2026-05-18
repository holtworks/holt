defmodule Holt.Memory do
  @moduledoc """
  File-backed local memory.
  """

  alias Holt.{Clock, JSON, Paths, TextMatch}

  @user_categories ~w(preference fact context goal)
  @project_categories ~w(design content structure general)
  @project_kinds ~w(note plan research)

  def user_categories, do: @user_categories
  def project_categories, do: @project_categories
  def project_kinds, do: @project_kinds

  def save(kind, text, opts \\ []) do
    root = Paths.workspace_root(opts)
    File.mkdir_p!(Paths.workspace_memory_dir(root))

    entry =
      %{
        "schema_version" => "holt_memory/v1",
        "id" => Clock.id("mem"),
        "kind" => to_string(kind),
        "text" => to_string(text),
        "source_run_id" => opts[:source_run_id],
        "created_at" => Clock.iso_now()
      }
      |> reject_empty()

    JSON.append_jsonl(facts_path(root), entry)
    {:ok, entry}
  end

  def search(query, opts \\ []) do
    root = Paths.workspace_root(opts)

    root
    |> facts_path()
    |> JSON.read_jsonl()
    |> Enum.filter(fn entry ->
      TextMatch.matches?(entry_text(entry, "text"), query)
    end)
  end

  def all(opts \\ []) do
    opts
    |> Paths.workspace_root()
    |> facts_path()
    |> JSON.read_jsonl()
  end

  def remember_user(attrs, opts \\ [])

  def remember_user(attrs, opts) when is_map(attrs) do
    with :ok <- canonical_attrs(attrs),
         {:ok, summary} <- required_text(attrs, "summary"),
         {:ok, category} <- required_enum(attrs, "category", @user_categories),
         {:ok, user_id} <- optional_text(attrs, "user_id") do
      entry =
        %{
          "schema_version" => "holt_user_memory/v1",
          "id" => Clock.id("user_mem"),
          "scope" => "user",
          "user_id" => scoped_id(user_id, "local_user"),
          "category" => category,
          "summary" => summary,
          "created_at" => Clock.iso_now()
        }
        |> reject_empty()

      opts
      |> Paths.workspace_root()
      |> user_memory_path()
      |> JSON.append_jsonl(entry)

      {:ok, entry}
    end
  end

  def remember_user(_attrs, _opts), do: {:error, :invalid_user_memory}

  def list_user(attrs \\ %{}, opts \\ []) when is_map(attrs) do
    with :ok <- canonical_attrs(attrs),
         {:ok, category} <- optional_enum(attrs, "category", @user_categories),
         {:ok, user_id} <- optional_text(attrs, "user_id") do
      scoped_user_id = scoped_id(user_id, "local_user")

      opts
      |> Paths.workspace_root()
      |> user_memory_path()
      |> JSON.read_jsonl()
      |> Enum.filter(&(&1["user_id"] == scoped_user_id))
      |> filter_exact("category", category)
    end
  end

  def search_user(attrs, opts \\ []) when is_map(attrs) do
    with :ok <- canonical_attrs(attrs),
         {:ok, query} <- required_text(attrs, "query") do
      case list_user(attrs, opts) do
        memories when is_list(memories) ->
          Enum.filter(memories, &TextMatch.matches?(entry_text(&1, "summary"), query))

        {:error, _reason} = error ->
          error
      end
    end
  end

  def forget_user(attrs, opts \\ []) when is_map(attrs) do
    with :ok <- canonical_attrs(attrs),
         {:ok, substring} <- required_text(attrs, "substring"),
         {:ok, user_id} <- optional_text(attrs, "user_id") do
      root = Paths.workspace_root(opts)
      path = user_memory_path(root)
      scoped_user_id = scoped_id(user_id, "local_user")
      memories = JSON.read_jsonl(path)

      {forgotten, kept} =
        Enum.split_with(memories, fn entry ->
          entry["user_id"] == scoped_user_id and
            TextMatch.matches?(entry_text(entry, "summary"), substring)
        end)

      rewrite_jsonl(path, kept)
      {:ok, %{"forgotten_count" => length(forgotten), "forgotten" => forgotten}}
    end
  end

  def remember_project(attrs, opts \\ [])

  def remember_project(attrs, opts) when is_map(attrs) do
    with :ok <- canonical_attrs(attrs),
         {:ok, summary} <- required_text(attrs, "summary"),
         {:ok, category} <- required_enum(attrs, "category", @project_categories) do
      save_project_entry(
        %{
          "kind" => "note",
          "category" => category,
          "title" => title_from_summary(summary),
          "summary" => summary,
          "body" => summary
        },
        attrs,
        opts
      )
    end
  end

  def remember_project(_attrs, _opts), do: {:error, :invalid_project_memory}

  def save_project_plan(attrs, opts \\ []), do: save_project_long_form("plan", attrs, opts)

  def save_project_research(attrs, opts \\ []),
    do: save_project_long_form("research", attrs, opts)

  def recall_project(attrs \\ %{}, opts \\ []) when is_map(attrs) do
    with :ok <- canonical_attrs(attrs),
         {:ok, kind} <- optional_enum(attrs, "kind", @project_kinds),
         {:ok, limit} <- optional_limit(attrs, "limit", 10, 30),
         {:ok, project_id} <- optional_text(attrs, "project_id"),
         {:ok, query} <- optional_text(attrs, "query") do
      scoped_project_id = scoped_id(project_id, "local_project")

      opts
      |> Paths.workspace_root()
      |> project_memory_path()
      |> JSON.read_jsonl()
      |> Enum.filter(&(&1["project_id"] == scoped_project_id))
      |> filter_exact("kind", kind)
      |> filter_query(query)
      |> Enum.take(limit)
      |> Enum.map(&project_memory_summary/1)
    end
  end

  def read_project(attrs, opts \\ []) when is_map(attrs) do
    with :ok <- canonical_attrs(attrs),
         {:ok, id} <- required_text(attrs, "id"),
         {:ok, project_id} <- optional_text(attrs, "project_id") do
      scoped_project_id = scoped_id(project_id, "local_project")

      opts
      |> Paths.workspace_root()
      |> project_memory_path()
      |> JSON.read_jsonl()
      |> Enum.find(&(&1["id"] == id and &1["project_id"] == scoped_project_id))
      |> case do
        nil -> {:error, :project_memory_not_found}
        entry -> {:ok, entry}
      end
    end
  end

  def facts_path(root) do
    root
    |> Paths.workspace_memory_dir()
    |> Path.join("facts.jsonl")
  end

  def user_memory_path(root) do
    root
    |> Paths.workspace_memory_dir()
    |> Path.join("user.jsonl")
  end

  def project_memory_path(root) do
    root
    |> Paths.workspace_memory_dir()
    |> Path.join("project.jsonl")
  end

  defp save_project_long_form(kind, attrs, opts) when is_map(attrs) do
    with :ok <- canonical_attrs(attrs),
         {:ok, title} <- required_text(attrs, "title"),
         {:ok, body} <- required_text(attrs, "body"),
         {:ok, category} <- required_enum(attrs, "category", @project_categories),
         {:ok, sources} <- optional_string_list(attrs, "sources") do
      save_project_entry(
        %{
          "kind" => kind,
          "category" => category,
          "title" => title,
          "summary" => String.slice(body, 0, 240),
          "body" => body,
          "sources" => sources
        },
        attrs,
        opts
      )
    end
  end

  defp save_project_long_form(_kind, _attrs, _opts), do: {:error, :invalid_project_memory}

  defp save_project_entry(entry_attrs, attrs, opts) do
    with {:ok, project_id} <- optional_text(attrs, "project_id") do
      entry =
        entry_attrs
        |> Map.merge(%{
          "schema_version" => "holt_project_memory/v1",
          "id" => Clock.id("project_mem"),
          "scope" => "project",
          "project_id" => scoped_id(project_id, "local_project"),
          "created_at" => Clock.iso_now()
        })
        |> reject_empty()

      opts
      |> Paths.workspace_root()
      |> project_memory_path()
      |> JSON.append_jsonl(entry)

      {:ok, entry}
    end
  end

  defp project_memory_summary(entry) do
    entry
    |> Map.take([
      "id",
      "kind",
      "category",
      "title",
      "summary",
      "project_id",
      "sources",
      "created_at"
    ])
    |> Map.put("snippet", String.slice(entry_text(entry, "body"), 0, 300))
    |> reject_empty()
  end

  defp filter_query(entries, query) when query in [nil, ""], do: entries

  defp filter_query(entries, query) do
    Enum.filter(entries, fn entry ->
      Enum.any?(["title", "summary", "body"], fn field ->
        TextMatch.matches?(entry_text(entry, field), query)
      end)
    end)
  end

  defp filter_exact(entries, _field, value) when value in [nil, ""], do: entries
  defp filter_exact(entries, field, value), do: Enum.filter(entries, &(&1[field] == value))

  defp rewrite_jsonl(path, entries) do
    File.mkdir_p!(Path.dirname(path))

    body =
      entries
      |> Enum.map(&Jason.encode_to_iodata!/1)
      |> Enum.intersperse("\n")

    File.write!(path, [body, if(entries == [], do: "", else: "\n")])
    :ok
  end

  defp scoped_id(value, default) do
    case value do
      nil -> default
      scoped_value -> scoped_value
    end
  end

  defp required_text(attrs, key) do
    case optional_text(attrs, key) do
      {:ok, nil} -> {:error, "#{key}_required"}
      {:ok, value} -> {:ok, value}
      {:error, _reason} = error -> error
    end
  end

  defp required_enum(attrs, key, allowed) do
    with {:ok, value} <- required_text(attrs, key) do
      validate_enum(value, key, allowed)
    end
  end

  defp optional_enum(attrs, key, allowed) do
    case optional_text(attrs, key) do
      {:ok, nil} -> {:ok, nil}
      {:ok, value} -> validate_enum(value, key, allowed)
      {:error, _reason} = error -> error
    end
  end

  defp validate_enum(value, key, allowed) do
    if value in allowed do
      {:ok, value}
    else
      {:error, "#{key}_invalid"}
    end
  end

  defp optional_text(attrs, key) do
    case Map.fetch(attrs, key) do
      :error ->
        {:ok, nil}

      {:ok, value} when is_binary(value) ->
        value = String.trim(value)

        case value do
          "" -> {:ok, nil}
          trimmed -> {:ok, trimmed}
        end

      {:ok, _value} ->
        {:error, "#{key}_invalid"}
    end
  end

  defp entry_text(entry, key) do
    case entry[key] do
      value when is_binary(value) ->
        value

      _value ->
        ""
    end
  end

  defp optional_string_list(attrs, key) do
    case Map.fetch(attrs, key) do
      :error ->
        {:ok, []}

      {:ok, values} when is_list(values) ->
        strings =
          values
          |> Enum.filter(&is_binary/1)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.uniq()

        if length(strings) == length(values) do
          {:ok, strings}
        else
          {:error, "#{key}_invalid"}
        end

      {:ok, _value} ->
        {:error, "#{key}_invalid"}
    end
  end

  defp title_from_summary(summary), do: String.slice(summary, 0, 80)

  defp optional_limit(attrs, key, default, max) do
    case Map.fetch(attrs, key) do
      :error -> {:ok, default}
      {:ok, value} when is_integer(value) -> {:ok, value |> max(1) |> min(max)}
      {:ok, _value} -> {:error, "#{key}_invalid"}
    end
  end

  defp canonical_attrs(attrs) do
    if canonical_map?(attrs) do
      :ok
    else
      {:error, :invalid_memory_attrs}
    end
  end

  defp canonical_map?(attrs) do
    Enum.all?(attrs, fn {key, value} ->
      is_binary(key) and canonical_value?(value)
    end)
  end

  defp canonical_value?(value) when is_map(value), do: canonical_map?(value)
  defp canonical_value?(values) when is_list(values), do: Enum.all?(values, &canonical_value?/1)
  defp canonical_value?(_value), do: true

  defp reject_empty(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end
end
