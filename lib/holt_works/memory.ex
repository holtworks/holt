defmodule HoltWorks.Memory do
  @moduledoc """
  File-backed local memory.
  """

  alias HoltWorks.{Clock, JSON, Paths, TextMatch}
  alias HoltWorks.Tasks.RuntimeContracts

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
        "schema_version" => "holtworks_memory/v1",
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
      TextMatch.matches?(Map.get(entry, "text", ""), query)
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
    attrs = RuntimeContracts.string_keys(attrs)

    with {:ok, summary} <- required_text(attrs, "summary"),
         {:ok, category} <- enum_value(attrs, "category", @user_categories, "fact") do
      entry =
        %{
          "schema_version" => "holtworks_user_memory/v1",
          "id" => Clock.id("user_mem"),
          "scope" => "user",
          "user_id" => scoped_id(attrs, opts, "user_id", :user_id, "local_user"),
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
    attrs = RuntimeContracts.string_keys(attrs)
    user_id = scoped_id(attrs, opts, "user_id", :user_id, "local_user")
    category = optional_enum(attrs, "category", @user_categories)

    opts
    |> Paths.workspace_root()
    |> user_memory_path()
    |> JSON.read_jsonl()
    |> Enum.filter(&(&1["user_id"] == user_id))
    |> filter_exact("category", category)
  end

  def search_user(attrs, opts \\ []) when is_map(attrs) do
    attrs = RuntimeContracts.string_keys(attrs)
    query = text(attrs, "query")

    attrs
    |> list_user(opts)
    |> Enum.filter(&TextMatch.matches?(&1["summary"] || "", query || ""))
  end

  def forget_user(attrs, opts \\ []) when is_map(attrs) do
    attrs = RuntimeContracts.string_keys(attrs)

    with {:ok, substring} <- required_text(attrs, "substring") do
      root = Paths.workspace_root(opts)
      path = user_memory_path(root)
      user_id = scoped_id(attrs, opts, "user_id", :user_id, "local_user")
      memories = JSON.read_jsonl(path)

      {forgotten, kept} =
        Enum.split_with(memories, fn entry ->
          entry["user_id"] == user_id and TextMatch.matches?(entry["summary"] || "", substring)
        end)

      rewrite_jsonl(path, kept)
      {:ok, %{"forgotten_count" => length(forgotten), "forgotten" => forgotten}}
    end
  end

  def remember_project(attrs, opts \\ [])

  def remember_project(attrs, opts) when is_map(attrs) do
    attrs = RuntimeContracts.string_keys(attrs)

    with {:ok, summary} <- required_text(attrs, "summary"),
         {:ok, category} <- enum_value(attrs, "category", @project_categories, "general") do
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
    attrs = RuntimeContracts.string_keys(attrs)
    project_id = scoped_id(attrs, opts, "project_id", :project_id, "local_project")
    query = text(attrs, "query")
    kind = optional_enum(attrs, "kind", @project_kinds)
    limit = clamp_limit(attrs["limit"], 10, 30)

    opts
    |> Paths.workspace_root()
    |> project_memory_path()
    |> JSON.read_jsonl()
    |> Enum.filter(&(&1["project_id"] == project_id))
    |> filter_exact("kind", kind)
    |> filter_query(query)
    |> Enum.take(limit)
    |> Enum.map(&project_memory_summary/1)
  end

  def read_project(attrs, opts \\ []) when is_map(attrs) do
    attrs = RuntimeContracts.string_keys(attrs)

    with {:ok, id} <- required_text(attrs, "id") do
      project_id = scoped_id(attrs, opts, "project_id", :project_id, "local_project")

      opts
      |> Paths.workspace_root()
      |> project_memory_path()
      |> JSON.read_jsonl()
      |> Enum.find(&(&1["id"] == id and &1["project_id"] == project_id))
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
    attrs = RuntimeContracts.string_keys(attrs)

    with {:ok, title} <- required_text(attrs, "title"),
         {:ok, body} <- required_text(attrs, "body"),
         {:ok, category} <- enum_value(attrs, "category", @project_categories, "general") do
      save_project_entry(
        %{
          "kind" => kind,
          "category" => category,
          "title" => title,
          "summary" => String.slice(body, 0, 240),
          "body" => body,
          "sources" => string_list(attrs, "sources")
        },
        attrs,
        opts
      )
    end
  end

  defp save_project_long_form(_kind, _attrs, _opts), do: {:error, :invalid_project_memory}

  defp save_project_entry(entry_attrs, attrs, opts) do
    entry =
      entry_attrs
      |> Map.merge(%{
        "schema_version" => "holtworks_project_memory/v1",
        "id" => Clock.id("project_mem"),
        "scope" => "project",
        "project_id" => scoped_id(attrs, opts, "project_id", :project_id, "local_project"),
        "created_at" => Clock.iso_now()
      })
      |> reject_empty()

    opts
    |> Paths.workspace_root()
    |> project_memory_path()
    |> JSON.append_jsonl(entry)

    {:ok, entry}
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
    |> Map.put("snippet", String.slice(entry["body"] || entry["summary"] || "", 0, 300))
    |> reject_empty()
  end

  defp filter_query(entries, query) when query in [nil, ""], do: entries

  defp filter_query(entries, query) do
    Enum.filter(entries, fn entry ->
      TextMatch.matches?(entry["title"] || "", query) or
        TextMatch.matches?(entry["summary"] || "", query) or
        TextMatch.matches?(entry["body"] || "", query)
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

  defp scoped_id(attrs, opts, string_key, atom_key, default) do
    text(attrs, string_key) || opts[atom_key] || default
  end

  defp required_text(attrs, key) do
    case text(attrs, key) do
      nil -> {:error, "#{key}_required"}
      value -> {:ok, value}
    end
  end

  defp enum_value(attrs, key, allowed, default) do
    value = text(attrs, key) || default

    if value in allowed do
      {:ok, value}
    else
      {:error, "#{key}_invalid"}
    end
  end

  defp optional_enum(attrs, key, allowed) do
    case text(attrs, key) do
      nil -> nil
      value -> if(value in allowed, do: value)
    end
  end

  defp text(attrs, key) do
    case attrs[key] do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _value ->
        nil
    end
  end

  defp string_list(attrs, key) do
    attrs
    |> Map.get(key, [])
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp title_from_summary(summary), do: String.slice(summary, 0, 80)

  defp clamp_limit(value, _default, max) when is_integer(value), do: value |> max(1) |> min(max)

  defp clamp_limit(value, default, max) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> clamp_limit(integer, default, max)
      _other -> default
    end
  end

  defp clamp_limit(_value, default, _max), do: default

  defp reject_empty(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end
end
