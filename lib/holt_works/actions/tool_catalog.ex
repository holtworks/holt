defmodule HoltWorks.Actions.ToolCatalog do
  @moduledoc """
  Transport-neutral catalog rows for HoltWorks executable actions.

  Actions keep owning execution. The catalog owns visibility, provider metadata,
  lookup, and serialization into provider-specific tool definitions.
  """

  alias HoltWorks.Actions.ProviderRegistry
  alias HoltWorks.Tasks.RuntimeContracts

  @entry_schema "holtworks_tool_catalog_entry/v1"

  def action_entries(definitions, context \\ %{}, surface \\ "agent", opts \\ [])

  def action_entries(definitions, context, surface, opts) when is_list(definitions) do
    context = RuntimeContracts.string_keys(context || %{})
    surface = normalize_surface(surface)

    definitions
    |> Enum.filter(&action_visible?(&1, context, surface, opts))
    |> Enum.map(&action_entry(&1, context, surface, opts))
    |> Enum.uniq_by(& &1["name"])
    |> Enum.sort_by(&{&1["provider_name"], &1["name"]})
  end

  def action_entries(_definitions, _context, _surface, _opts), do: []

  def action_entry(definition, context \\ %{}, surface \\ "agent", opts \\ [])

  def action_entry(definition, context, surface, _opts) when is_map(definition) do
    context = RuntimeContracts.string_keys(context || %{})
    surface = normalize_surface(surface)
    provider_id = definition["provider"] || "unknown"

    %{
      "schema_version" => @entry_schema,
      "name" => definition["name"],
      "description" => definition["description"] || "",
      "input_schema" => definition["arguments_schema"] || empty_object_schema(),
      "provider_id" => provider_id,
      "provider_name" => ProviderRegistry.provider_name(provider_id),
      "provider_description" => ProviderRegistry.provider_description(provider_id),
      "source" => "action",
      "surface" => surface,
      "action_name" => definition["name"],
      "category" => definition["toolkit"],
      "toolkit" => definition["toolkit"],
      "effect_scope" => definition["effect_scope"],
      "risk_level" => definition["risk_level"],
      "requires_approval" => definition["requires_approval"] == true,
      "requires_task_ref" => definition["requires_task_ref"] == true,
      "read_only" => read_only?(definition),
      "parallel_safe" => parallel_safe?(definition),
      "availability" => definition["availability"],
      "metadata" => entry_metadata(definition, context)
    }
    |> RuntimeContracts.reject_empty()
  end

  def action_entry(_definition, _context, _surface, _opts), do: nil

  def action_visible?(definition, context \\ %{}, surface \\ "agent", opts \\ [])

  def action_visible?(definition, context, surface, opts) when is_map(definition) do
    context = RuntimeContracts.string_keys(context || %{})
    surface = normalize_surface(surface)

    definition["name"] not in [nil, ""] and
      surface in ["agent", "mcp"] and
      provider_visible?(definition, context, opts) and
      not action_excluded?(definition, context, opts) and
      availability_visible?(definition, opts)
  end

  def action_visible?(_definition, _context, _surface, _opts), do: false

  def find_entry(entries, tool_name) when is_list(entries) and is_binary(tool_name) do
    case Enum.find(entries, &(&1["name"] == tool_name)) do
      nil -> {:error, :not_found}
      entry -> {:ok, entry}
    end
  end

  def find_entry(_entries, _tool_name), do: {:error, :not_found}

  def openai_tools(entries) when is_list(entries), do: Enum.map(entries, &openai_tool/1)
  def openai_tools(_entries), do: []

  def openai_tool(entry) when is_map(entry) do
    %{
      "type" => "function",
      "function" => %{
        "name" => entry["name"],
        "description" => entry["description"] || "",
        "parameters" => entry["input_schema"] || empty_object_schema()
      }
    }
  end

  def mcp_tools(entries) when is_list(entries) do
    Enum.map(entries, fn entry ->
      %{
        "name" => entry["name"],
        "description" => entry["description"] || "",
        "inputSchema" => entry["input_schema"] || empty_object_schema()
      }
    end)
  end

  def mcp_tools(_entries), do: []

  def provider_context(context) when is_map(context), do: RuntimeContracts.string_keys(context)
  def provider_context(_context), do: %{}

  defp provider_visible?(definition, context, opts) do
    provider_id = definition["provider"] || "unknown"
    ProviderRegistry.provider_allowed?(provider_id, context, opts)
  end

  defp action_excluded?(definition, context, opts) do
    excluded_actions = excluded_set(context, opts, "excluded_actions")
    excluded_toolkits = excluded_set(context, opts, "excluded_toolkits")

    MapSet.member?(excluded_actions, definition["name"]) or
      MapSet.member?(excluded_toolkits, definition["toolkit"])
  end

  defp availability_visible?(definition, opts) do
    if Keyword.get(opts, :include_unavailable, false) do
      true
    else
      get_in(definition, ["availability", "route_status"]) in [nil, "accepted"]
    end
  end

  defp excluded_set(context, opts, key) do
    context
    |> Map.get(key, Keyword.get(opts, option_key(key), []))
    |> List.wrap()
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.map(&to_string/1)
    |> MapSet.new()
  end

  defp option_key("excluded_actions"), do: :excluded_actions
  defp option_key("excluded_toolkits"), do: :excluded_toolkits

  defp read_only?(%{"effect_scope" => effect_scope}) do
    effect_scope in ["read_only", "session_ephemeral"]
  end

  defp parallel_safe?(%{"effect_scope" => effect_scope}) do
    effect_scope in ["read_only", "session_ephemeral"]
  end

  defp entry_metadata(definition, context) do
    %{
      "requires_task_ref" => definition["requires_task_ref"] == true,
      "declared_in_session" => get_in(definition, ["availability", "declared_in_session"]),
      "task_ref" => context["task_ref"] || context["task_id"] || context["ref"]
    }
    |> RuntimeContracts.reject_empty()
  end

  defp normalize_surface(surface) when is_atom(surface), do: Atom.to_string(surface)
  defp normalize_surface(surface) when is_binary(surface), do: surface
  defp normalize_surface(_surface), do: "agent"

  defp empty_object_schema, do: %{"type" => "object", "properties" => %{}}
end
