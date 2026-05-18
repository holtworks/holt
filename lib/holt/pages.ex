defmodule Holt.Pages do
  @moduledoc """
  File-backed local page and document records for agent-facing page actions.
  """

  alias Holt.{Clock, JSON, Paths}

  @page_schema_version "holt_page/v1"
  @document_event_schema_version "holt_document_event/v1"
  @page_types ~w(document)
  @document_actions ~w(insert_below replace_selection replace_all)

  def page_types, do: @page_types
  def document_actions, do: @document_actions

  def pages_path(root), do: Paths.workspace_file(root, "pages.json")
  def state_path(root), do: Paths.workspace_file(root, "page_state.json")
  def document_events_path(root), do: Paths.workspace_file(root, "document_events.jsonl")
  def documents_dir(root), do: Paths.workspace_file(root, "documents")

  def ensure_store(root) do
    Paths.ensure_workspace(root)
    File.mkdir_p!(documents_dir(root))
    unless File.exists?(pages_path(root)), do: JSON.write(pages_path(root), [])
    unless File.exists?(state_path(root)), do: JSON.write(state_path(root), %{})
    :ok
  end

  def list(opts \\ []) do
    root = Paths.workspace_root(opts)
    ensure_store(root)

    root
    |> pages_path()
    |> JSON.read([])
    |> Enum.filter(&is_map/1)
    |> Enum.map(&normalize_page/1)
  end

  def get(page_id, opts \\ [])

  def get(page_id, opts) when is_binary(page_id) and page_id != "" do
    opts
    |> list()
    |> Enum.find(&(&1["id"] == page_id))
    |> case do
      nil -> {:error, :page_not_found}
      page -> {:ok, page}
    end
  end

  def get(_page_id, _opts), do: {:error, :page_id_required}

  def create(attrs, opts \\ [])

  def create(attrs, opts) when is_map(attrs) do
    root = Paths.workspace_root(opts)
    ensure_store(root)

    with :ok <- canonical_attrs(attrs),
         {:ok, page_type} <- enum_value(attrs, "page_type", @page_types),
         {:ok, title} <- required_text(attrs, "title"),
         {:ok, content} <- optional_body(attrs, "content", "") do
      now = Clock.iso_now()
      page_id = Clock.id("page")
      relative_path = Path.join([".holtworks", "documents", page_id <> ".md"])
      absolute_path = Path.join(root, relative_path)

      page =
        %{
          "schema_version" => @page_schema_version,
          "id" => page_id,
          "page_id" => page_id,
          "page_type" => page_type,
          "title" => title,
          "project_id" => optional_text(attrs, "project_id"),
          "document_path" => relative_path,
          "content_bytes" => byte_size(content),
          "created_at" => now,
          "updated_at" => now
        }
        |> compact()

      File.mkdir_p!(Path.dirname(absolute_path))
      File.write!(absolute_path, content)
      store(root, upsert(list(workspace: root), page))
      set_active_page(root, page)

      {:ok, %{"page" => page, "text" => "Created #{page_type} page \"#{title}\"."}}
    end
  end

  def create(_attrs, _opts), do: {:error, :invalid_page_attrs}

  def set_title(attrs, opts \\ [])

  def set_title(attrs, opts) when is_map(attrs) do
    root = Paths.workspace_root(opts)
    ensure_store(root)

    with :ok <- canonical_attrs(attrs),
         {:ok, id} <- required_text(attrs, "page_id"),
         {:ok, title} <- required_text(attrs, "title") do
      update_page(root, id, fn page ->
        page
        |> Map.put("title", title)
        |> Map.put("updated_at", Clock.iso_now())
      end)
      |> case do
        {:ok, page} ->
          set_active_page(root, page)
          {:ok, %{"page" => page, "text" => "Title set to \"#{title}\"."}}

        error ->
          error
      end
    end
  end

  def set_title(_attrs, _opts), do: {:error, :invalid_page_title}

  def write_document(attrs, opts \\ [])

  def write_document(attrs, opts) when is_map(attrs) do
    root = Paths.workspace_root(opts)
    ensure_store(root)

    with :ok <- canonical_attrs(attrs),
         {:ok, page_id} <- required_text(attrs, "page_id"),
         {:ok, action} <- enum_value(attrs, "action", @document_actions),
         {:ok, content} <- required_body(attrs, "content"),
         {:ok, page} <- get(page_id, opts),
         {:ok, result} <- write_document_content(root, page, action, content, attrs) do
      {:ok, result}
    end
  end

  def write_document(_attrs, _opts), do: {:error, :invalid_document_write}

  defp write_document_content(root, page, action, content, attrs) do
    path = Path.join(root, page["document_path"])
    File.mkdir_p!(Path.dirname(path))
    existing = read_text(path)
    {next_content, edit_status} = edited_content(existing, action, content, attrs)
    File.write!(path, next_content)

    with {:ok, updated_page} <-
           update_page(root, page["id"], fn current ->
             current
             |> Map.put("content_bytes", byte_size(next_content))
             |> Map.put("updated_at", Clock.iso_now())
           end) do
      event =
        %{
          "schema_version" => @document_event_schema_version,
          "id" => Clock.id("document_event"),
          "page_id" => page["id"],
          "action" => action,
          "edit_status" => edit_status,
          "content_bytes" => byte_size(content),
          "document_bytes" => byte_size(next_content),
          "at" => Clock.iso_now()
        }

      JSON.append_jsonl(document_events_path(root), event)
      set_active_page(root, updated_page)

      {:ok,
       %{
         "page" => updated_page,
         "document_event" => event,
         "text" => "Document #{action} completed for \"#{updated_page["title"]}\"."
       }}
    end
  end

  defp edited_content(_existing, "replace_all", content, _attrs), do: {content, "replaced_all"}

  defp edited_content(existing, "insert_below", content, _attrs) do
    separator = if existing == "", do: "", else: "\n\n"
    {existing <> separator <> content, "inserted_below"}
  end

  defp edited_content(existing, "replace_selection", content, attrs) do
    selected = optional_text(attrs, "selected_text")

    cond do
      selected in [nil, ""] ->
        {content, "selection_missing_replaced_all"}

      String.contains?(existing, selected) ->
        {String.replace(existing, selected, content, global: false), "selection_replaced"}

      true ->
        separator = if existing == "", do: "", else: "\n\n"
        {existing <> separator <> content, "selection_not_found_inserted_below"}
    end
  end

  defp set_active_page(root, page) do
    JSON.write(state_path(root), %{
      "active_page_id" => page["id"],
      "page_type" => page["page_type"],
      "title" => page["title"],
      "updated_at" => Clock.iso_now()
    })
  end

  defp update_page(root, page_id, fun) do
    pages = list(workspace: root)

    case Enum.find(pages, &(&1["id"] == page_id)) do
      nil ->
        {:error, :page_not_found}

      page ->
        updated = page |> fun.() |> normalize_page()

        pages =
          Enum.map(pages, fn current ->
            if current["id"] == page_id, do: updated, else: current
          end)

        store(root, pages)
        {:ok, updated}
    end
  end

  defp store(root, pages), do: JSON.write(pages_path(root), pages)

  defp upsert(pages, page) do
    if Enum.any?(pages, &(&1["id"] == page["id"])) do
      Enum.map(pages, fn current -> if current["id"] == page["id"], do: page, else: current end)
    else
      pages ++ [page]
    end
  end

  defp read_text(path) do
    case File.read(path) do
      {:ok, body} -> body
      _error -> ""
    end
  end

  defp normalize_page(page) do
    page
    |> Map.put_new("schema_version", @page_schema_version)
    |> compact()
  end

  defp enum_value(attrs, key, allowed) do
    case required_text(attrs, key) do
      {:ok, value} ->
        if value in allowed do
          {:ok, value}
        else
          {:error, {:invalid_enum, key, allowed}}
        end

      error ->
        error
    end
  end

  defp required_text(attrs, key) do
    case optional_text(attrs, key) do
      nil -> {:error, {:missing_required, key}}
      text -> {:ok, text}
    end
  end

  defp optional_text(attrs, key) when is_map(attrs) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_binary(value) ->
        value
        |> String.trim()
        |> case do
          "" -> nil
          text -> text
        end

      {:ok, nil} ->
        nil

      {:ok, _value} ->
        nil

      :error ->
        nil
    end
  end

  defp optional_text(_attrs, _key), do: nil

  defp optional_body(attrs, key, default) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, nil} -> {:ok, default}
      {:ok, _value} -> {:error, {:invalid_text, key}}
      :error -> {:ok, default}
    end
  end

  defp required_body(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_text, key}}
      :error -> {:error, {:missing_required, key}}
    end
  end

  defp canonical_attrs(attrs) do
    if canonical_value?(attrs) do
      :ok
    else
      {:error, :invalid_page_attrs}
    end
  end

  defp canonical_value?(value) when is_map(value) do
    Enum.all?(value, fn
      {key, nested} when is_binary(key) -> canonical_value?(nested)
      {_key, _nested} -> false
    end)
  end

  defp canonical_value?(value) when is_list(value), do: Enum.all?(value, &canonical_value?/1)
  defp canonical_value?(_value), do: true

  defp compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end
end
