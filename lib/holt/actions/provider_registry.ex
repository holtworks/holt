defmodule Holt.Actions.ProviderRegistry do
  @moduledoc """
  Structured provider metadata for Holt action catalogs.

  The registry describes tool providers independently from transport-specific
  schemas. Tool visibility and prompt sections are driven by explicit provider
  ids, disabled ids, and definition metadata.
  """

  alias Holt.Tasks.RuntimeContracts

  @table :holt_action_providers

  @built_in_providers [
    %{
      "id" => "workspace",
      "name" => "Workspace",
      "description" => "Local workspace file, shell, network, memory, and user-input tools.",
      "prompt_section" =>
        "Workspace tools operate on the configured local workspace and must respect approval policy."
    },
    %{
      "id" => "tasks",
      "name" => "Tasks",
      "description" => "Task records, comments, specs, memory artifacts, and verification tools.",
      "prompt_section" =>
        "Task tools require an explicit task reference unless the tool is globally scoped."
    },
    %{
      "id" => "agent_orchestration",
      "name" => "Agent orchestration",
      "description" =>
        "Agent dispatch, child-agent contracts, team orchestration, and continuation tools.",
      "prompt_section" =>
        "Agent orchestration tools must persist structured handoff and verification metadata."
    },
    %{
      "id" => "router",
      "name" => "Router",
      "description" => "Meta-tools that route, inspect, or execute other task-scoped tools.",
      "prompt_section" =>
        "Router tools expose tool metadata and execute safe routed actions through explicit schemas."
    },
    %{
      "id" => "task_tool_session",
      "name" => "Task tool session",
      "description" => "Session-scoped connected-account and workbench context tools.",
      "prompt_section" =>
        "Task tool session providers expose only the tools declared for the current session."
    }
  ]

  def init do
    ensure_table()
    Enum.each(@built_in_providers, &register/1)
    :ok
  end

  def register(provider) when is_map(provider) do
    ensure_table()
    provider = normalize_provider(provider)
    :ets.insert(@table, {provider["id"], provider})
    :ok
  end

  def unregister(provider_id) do
    ensure_table()
    :ets.delete(@table, to_string(provider_id))
    :ok
  end

  def all do
    init()

    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_id, provider} -> provider end)
    |> Enum.sort_by(& &1["id"])
  end

  def get(provider_id) do
    init()

    case :ets.lookup(@table, to_string(provider_id)) do
      [{_id, provider}] -> {:ok, provider}
      [] -> {:error, :not_found}
    end
  end

  def for_context(context \\ %{}, opts \\ []) do
    context = RuntimeContracts.string_keys(context || %{})
    explicit = provider_filter(context, opts)
    excluded = provider_exclusions(context, opts)

    all()
    |> Enum.filter(fn provider ->
      id = provider["id"]

      (MapSet.size(explicit) == 0 or MapSet.member?(explicit, id)) and
        not MapSet.member?(excluded, id)
    end)
  end

  def provider_allowed?(provider_id, context \\ %{}, opts \\ []) do
    provider_id = to_string(provider_id)

    Enum.any?(for_context(context, opts), &(&1["id"] == provider_id))
  end

  def metadata(definitions, context \\ %{}, opts \\ [])

  def metadata(definitions, context, opts) when is_list(definitions) do
    context = RuntimeContracts.string_keys(context || %{})
    provider_map = Map.new(for_context(context, opts), &{&1["id"], &1})

    definitions
    |> Enum.group_by(&(&1["provider"] || "unknown"))
    |> Enum.map(fn {provider_id, rows} ->
      provider = Map.get(provider_map, provider_id, fallback_provider(provider_id))

      provider
      |> Map.take(["id", "name", "description"])
      |> Map.put("schema_version", "holtworks_action_provider/v1")
      |> Map.put("tool_count", length(rows))
      |> Map.put("tools", rows |> Enum.map(& &1["name"]) |> Enum.sort())
    end)
    |> Enum.filter(&provider_allowed?(&1["id"], context, opts))
    |> Enum.sort_by(& &1["name"])
  end

  def metadata(_definitions, _context, _opts), do: []

  def prompt_sections(context \\ %{}, opts \\ []) do
    context
    |> for_context(opts)
    |> Enum.map(fn provider ->
      %{
        "provider_id" => provider["id"],
        "title" => provider["name"],
        "content" => provider["prompt_section"] || provider["description"]
      }
    end)
    |> Enum.reject(&(&1["content"] in [nil, ""]))
  end

  def provider_name(provider_id) do
    case get(provider_id) do
      {:ok, provider} -> provider["name"]
      {:error, :not_found} -> fallback_provider(provider_id)["name"]
    end
  end

  def provider_description(provider_id) do
    case get(provider_id) do
      {:ok, provider} -> provider["description"]
      {:error, :not_found} -> fallback_provider(provider_id)["description"]
    end
  end

  defp provider_filter(context, opts) do
    context
    |> Map.get(
      "action_provider_ids",
      Map.get(context, "providers", Keyword.get(opts, :action_provider_ids, []))
    )
    |> string_set()
  end

  defp provider_exclusions(context, opts) do
    context
    |> Map.get(
      "excluded_action_providers",
      Keyword.get(opts, :excluded_action_providers, [])
    )
    |> string_set()
  end

  defp string_set(values) do
    values
    |> List.wrap()
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.map(&to_string/1)
    |> MapSet.new()
  end

  defp normalize_provider(provider) do
    provider
    |> RuntimeContracts.string_keys()
    |> Map.update("id", nil, &to_string/1)
    |> RuntimeContracts.reject_empty()
  end

  defp fallback_provider(provider_id) do
    id = to_string(provider_id || "unknown")

    %{
      "id" => id,
      "name" => humanize_provider_id(id),
      "description" => "Holt action provider #{id}."
    }
  end

  defp humanize_provider_id(provider_id) do
    provider_id
    |> String.replace("_", " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
      _table -> @table
    end
  end
end
