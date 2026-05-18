defmodule Holt.Actions.ProviderRegistry do
  @moduledoc """
  Structured provider metadata for Holt action catalogs.

  The registry describes action providers independently from transport-specific
  schemas. Action visibility and prompt sections are driven by explicit provider
  ids, disabled ids, and definition metadata.
  """

  @table :holt_action_providers

  @built_in_providers [
    %{
      "id" => "workspace",
      "name" => "Workspace",
      "description" => "Local workspace file, shell, network, memory, and user-input actions.",
      "prompt_section" =>
        "Workspace actions operate on the configured local workspace and must respect approval policy."
    },
    %{
      "id" => "tasks",
      "name" => "Tasks",
      "description" =>
        "Task records, comments, specs, memory artifacts, and verification actions.",
      "prompt_section" =>
        "Task actions require an explicit task reference unless the action is globally scoped."
    },
    %{
      "id" => "agent_orchestration",
      "name" => "Agent orchestration",
      "description" =>
        "Agent dispatch, child-agent contracts, team orchestration, and continuation actions.",
      "prompt_section" =>
        "Agent orchestration actions must persist structured handoff and verification metadata."
    },
    %{
      "id" => "router",
      "name" => "Router",
      "description" => "Meta-actions that route, inspect, or execute other task-scoped actions.",
      "prompt_section" =>
        "Router actions expose action metadata and execute safe routed actions through explicit schemas."
    },
    %{
      "id" => "action_session",
      "name" => "Task action session",
      "description" => "Session-scoped connected-account and workbench context actions.",
      "prompt_section" =>
        "Task action session providers expose only the actions declared for the current session."
    }
  ]

  def init do
    ensure_table()
    Enum.each(@built_in_providers, &register/1)
    :ok
  end

  def register(provider) when is_map(provider) do
    ensure_table()

    case normalize_provider(provider) do
      {:ok, normalized_provider} ->
        :ets.insert(@table, {normalized_provider["id"], normalized_provider})
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  def register(_provider), do: {:error, :invalid_provider}

  def unregister(provider_id) when is_binary(provider_id) and provider_id != "" do
    ensure_table()
    :ets.delete(@table, provider_id)
    :ok
  end

  def unregister(_provider_id), do: {:error, :invalid_provider_id}

  def all do
    ensure_table()

    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_id, provider} -> provider end)
    |> Enum.sort_by(& &1["id"])
  end

  def get(provider_id) when is_binary(provider_id) and provider_id != "" do
    ensure_table()

    case :ets.lookup(@table, provider_id) do
      [{_id, provider}] -> {:ok, provider}
      [] -> {:error, :not_found}
    end
  end

  def get(_provider_id), do: {:error, :invalid_provider_id}

  def for_context(context \\ %{}, opts \\ []) do
    with {:ok, context} <- canonical_context(context),
         {:ok, explicit} <- provider_filter(context, opts),
         {:ok, excluded} <- provider_exclusions(context, opts) do
      all()
      |> Enum.filter(fn provider ->
        id = provider["id"]

        provider_selected?(explicit, id) and not MapSet.member?(excluded, id)
      end)
    end
  end

  def provider_allowed?(provider_id, context \\ %{}, opts \\ []) do
    case for_context(context, opts) do
      providers when is_list(providers) and is_binary(provider_id) ->
        Enum.any?(providers, &(&1["id"] == provider_id))

      _result ->
        false
    end
  end

  def metadata(definitions, context \\ %{}, opts \\ [])

  def metadata(definitions, context, opts) when is_list(definitions) do
    with {:ok, context} <- canonical_context(context),
         providers when is_list(providers) <- for_context(context, opts) do
      provider_map = Map.new(providers, &{&1["id"], &1})

      definitions
      |> Enum.filter(&canonical_definition?/1)
      |> Enum.group_by(& &1["provider"])
      |> Enum.flat_map(fn {provider_id, rows} ->
        case Map.fetch(provider_map, provider_id) do
          {:ok, provider} -> [provider_metadata(provider, rows)]
          :error -> []
        end
      end)
      |> Enum.sort_by(& &1["name"])
    end
  end

  def metadata(_definitions, _context, _opts), do: []

  def prompt_sections(context \\ %{}, opts \\ []) do
    case for_context(context, opts) do
      providers when is_list(providers) ->
        providers
        |> Enum.map(fn provider ->
          %{
            "provider_id" => provider["id"],
            "title" => provider["name"],
            "content" => provider["prompt_section"]
          }
        end)
        |> Enum.reject(&(&1["content"] in [nil, ""]))

      {:error, _reason} = error ->
        error
    end
  end

  def provider_name(provider_id) do
    case get(provider_id) do
      {:ok, provider} -> provider["name"]
      {:error, _reason} -> nil
    end
  end

  def provider_description(provider_id) do
    case get(provider_id) do
      {:ok, provider} -> provider["description"]
      {:error, _reason} -> nil
    end
  end

  defp provider_filter(context, opts) do
    case Map.fetch(context, "providers") do
      {:ok, _value} ->
        {:error, {:obsolete_provider_context_key, "providers", "action_provider_ids"}}

      :error ->
        provider_set(context, opts, "action_provider_ids", :action_provider_ids)
    end
  end

  defp provider_exclusions(context, opts) do
    provider_set(context, opts, "excluded_action_providers", :excluded_action_providers)
  end

  defp provider_set(context, opts, key, option_key) do
    case Map.fetch(context, key) do
      {:ok, values} -> string_set(values, key)
      :error -> option_set(opts, option_key, key)
    end
  end

  defp option_set(opts, option_key, key) do
    case Keyword.fetch(opts, option_key) do
      {:ok, values} -> string_set(values, key)
      :error -> {:ok, MapSet.new()}
    end
  end

  defp normalize_provider(provider) do
    with :ok <- canonical_provider(provider),
         {:ok, id} <- required_text(provider, "id"),
         {:ok, name} <- required_text(provider, "name"),
         {:ok, description} <- required_text(provider, "description"),
         {:ok, prompt_section} <- optional_text(provider, "prompt_section") do
      provider =
        %{
          "id" => id,
          "name" => name,
          "description" => description,
          "prompt_section" => prompt_section
        }
        |> reject_empty()

      {:ok, provider}
    end
  end

  defp canonical_provider(provider) do
    if canonical_value?(provider) do
      :ok
    else
      {:error, :invalid_provider}
    end
  end

  defp canonical_context(context) when is_map(context) do
    if canonical_value?(context) do
      {:ok, context}
    else
      {:error, :invalid_provider_context}
    end
  end

  defp canonical_context(_context), do: {:error, :invalid_provider_context}

  defp canonical_definition?(definition) when is_map(definition) do
    canonical_value?(definition) and binary_present?(definition["provider"]) and
      binary_present?(definition["name"])
  end

  defp canonical_definition?(_definition), do: false

  defp provider_selected?(explicit, id) do
    if MapSet.size(explicit) == 0 do
      true
    else
      MapSet.member?(explicit, id)
    end
  end

  defp provider_metadata(provider, rows) do
    provider
    |> Map.take(["id", "name", "description"])
    |> Map.put("schema_version", "holt_action_provider/v1")
    |> Map.put("action_count", length(rows))
    |> Map.put("actions", rows |> Enum.map(& &1["name"]) |> Enum.sort())
  end

  defp string_set(values, key) when is_list(values) do
    if Enum.all?(values, &binary_present?/1) do
      {:ok, MapSet.new(values)}
    else
      {:error, {:invalid_provider_context_field, key}}
    end
  end

  defp string_set(_values, key), do: {:error, {:invalid_provider_context_field, key}}

  defp required_text(map, key) do
    case optional_text(map, key) do
      {:ok, nil} -> {:error, {:missing_required, key}}
      {:ok, value} -> {:ok, value}
      {:error, _reason} = error -> error
    end
  end

  defp optional_text(map, key) do
    case Map.fetch(map, key) do
      :error ->
        {:ok, nil}

      {:ok, value} when is_binary(value) ->
        value = String.trim(value)

        case value do
          "" -> {:ok, nil}
          trimmed -> {:ok, trimmed}
        end

      {:ok, _value} ->
        {:error, {:invalid_provider_field, key}}
    end
  end

  defp binary_present?(value) when is_binary(value), do: String.trim(value) != ""
  defp binary_present?(_value), do: false

  defp canonical_value?(value) when is_map(value) do
    Enum.all?(value, fn
      {key, nested} when is_binary(key) -> canonical_value?(nested)
      {_key, _nested} -> false
    end)
  end

  defp canonical_value?(values) when is_list(values), do: Enum.all?(values, &canonical_value?/1)
  defp canonical_value?(_value), do: true

  defp reject_empty(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
      _table -> @table
    end
  end
end
