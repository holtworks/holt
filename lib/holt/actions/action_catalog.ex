defmodule Holt.Actions.ActionCatalog do
  @moduledoc """
  Transport-neutral catalog rows for Holt executable actions.

  Actions keep owning execution. The catalog owns visibility, provider metadata,
  lookup, and serialization into provider-specific action definitions.
  """

  alias Holt.Actions.ProviderRegistry

  @entry_schema "holt_action_catalog_entry/v1"

  def action_entries(definitions, context \\ %{}, surface \\ "agent", opts \\ [])

  def action_entries(definitions, context, surface, opts) when is_list(definitions) do
    context = canonical_context(context)
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
    context = canonical_context(context)
    surface = normalize_surface(surface)
    provider_id = provider_id(definition)

    %{
      "schema_version" => @entry_schema,
      "name" => definition["name"],
      "description" => description(definition),
      "input_schema" => input_schema(definition),
      "provider_id" => provider_id,
      "provider_name" => ProviderRegistry.provider_name(provider_id),
      "provider_description" => ProviderRegistry.provider_description(provider_id),
      "source" => "action",
      "surface" => surface,
      "category" => definition["action_group"],
      "action_group" => definition["action_group"],
      "effect_scope" => definition["effect_scope"],
      "risk_level" => definition["risk_level"],
      "requires_approval" => definition["requires_approval"] == true,
      "requires_task_ref" => definition["requires_task_ref"] == true,
      "read_only" => read_only?(definition),
      "parallel_safe" => parallel_safe?(definition),
      "availability" => definition["availability"],
      "metadata" => entry_metadata(definition, context)
    }
    |> compact()
  end

  def action_entry(_definition, _context, _surface, _opts), do: nil

  def action_visible?(definition, context \\ %{}, surface \\ "agent", opts \\ [])

  def action_visible?(definition, context, surface, opts) when is_map(definition) do
    context = canonical_context(context)
    surface = normalize_surface(surface)

    definition["name"] not in [nil, ""] and
      surface in ["agent", "mcp"] and
      provider_visible?(definition, context, opts) and
      not action_excluded?(definition, context, opts) and
      availability_visible?(definition, opts)
  end

  def action_visible?(_definition, _context, _surface, _opts), do: false

  def find_entry(entries, action_name) when is_list(entries) and is_binary(action_name) do
    case Enum.find(entries, &(&1["name"] == action_name)) do
      nil -> {:error, :not_found}
      entry -> {:ok, entry}
    end
  end

  def find_entry(_entries, _action_name), do: {:error, :not_found}

  def openai_action_definitions(entries) when is_list(entries),
    do: Enum.map(entries, &openai_action/1)

  def openai_action_definitions(_entries), do: []

  def openai_action(entry) when is_map(entry) do
    %{
      "type" => "function",
      "function" => %{
        "name" => entry["name"],
        "description" => description(entry),
        "parameters" => input_schema(entry)
      }
    }
  end

  def mcp_action_definitions(entries) when is_list(entries) do
    Enum.map(entries, fn entry ->
      %{
        "name" => entry["name"],
        "description" => description(entry),
        "inputSchema" => input_schema(entry)
      }
    end)
  end

  def mcp_action_definitions(_entries), do: []

  def provider_context(context) when is_map(context), do: canonical_context(context)
  def provider_context(_context), do: %{}

  defp provider_visible?(definition, context, opts) do
    definition
    |> provider_id()
    |> ProviderRegistry.provider_allowed?(context, opts)
  end

  defp action_excluded?(definition, context, opts) do
    excluded_actions = excluded_set(context, opts, "excluded_actions")
    excluded_action_groups = excluded_set(context, opts, "excluded_action_groups")

    cond do
      MapSet.member?(excluded_actions, definition["name"]) -> true
      MapSet.member?(excluded_action_groups, definition["action_group"]) -> true
      true -> false
    end
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
  defp option_key("excluded_action_groups"), do: :excluded_action_groups

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
      "task_ref" => context["task_ref"]
    }
    |> compact()
  end

  defp normalize_surface(surface) when is_binary(surface), do: surface
  defp normalize_surface(_surface), do: "agent"

  defp provider_id(%{"provider" => provider}) when is_binary(provider) and provider != "",
    do: provider

  defp provider_id(_definition), do: "unknown"

  defp description(%{"description" => description}) when is_binary(description), do: description
  defp description(_entry), do: ""

  defp input_schema(%{"input_schema" => schema}) when is_map(schema), do: schema
  defp input_schema(%{"arguments_schema" => schema}) when is_map(schema), do: schema
  defp input_schema(_entry), do: empty_object_schema()

  defp canonical_context(context) do
    if canonical_value?(context) do
      context
    else
      %{}
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

  defp empty_object_schema, do: %{"type" => "object", "properties" => %{}}

  defp compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end
end
