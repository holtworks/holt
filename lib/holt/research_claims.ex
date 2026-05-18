defmodule Holt.ResearchClaims do
  @moduledoc """
  File-backed structured research claim ledger.

  Research claims are explicit metadata records. Holt stores raw web action
  text as evidence preview only; durable workflow decisions must use the
  structured claim fields.
  """

  alias Holt.{Clock, JSON, Paths}

  @schema_version "holt_research_claim/v1"
  @max_preview_chars 1_500
  @source_types ~w(
    api_reference
    blog
    changelog
    forum
    issue_tracker
    official_docs
    pricing_policy
    release_notes
    security_advisory
    vendor_status
    web_page
    web_search
    unclassified
  )

  def source_types, do: @source_types

  def validate_recording_request(params) do
    case record_intent(params) do
      {:error, reason} -> {:error, reason}
      _intent -> :ok
    end
  end

  def maybe_record(action, params, opts, search_result) do
    case record_intent(params) do
      :record ->
        record(action, params, opts, search_result)

      :skip ->
        {:ok, %{"research_claim_saved" => false}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def record("search_web", params, opts, search_result) when is_map(params) do
    with :ok <- canonical_attrs(params),
         {:ok, result} <- normalize_result(search_result),
         :ok <- canonical_attrs(result) do
      claim = build_from_search_result(params, result, opts)
      root = Paths.workspace_root(opts)
      JSON.append_jsonl(Paths.research_claims_path(root), claim)
      {:ok, %{"research_claim_saved" => true, "research_claim" => claim}}
    end
  end

  def record(_action, _params, _opts, _result), do: {:error, :unsupported_research_claim_source}

  def list(opts \\ []) do
    root = Paths.workspace_root(opts)

    root
    |> Paths.research_claims_path()
    |> JSON.read_jsonl()
    |> filter_claims(opts)
  end

  def build_from_search_result(params, search_result, opts \\ []) when is_map(params) do
    {:ok, result} = normalize_result(search_result)
    source_urls = source_urls(params, result)

    %{
      "schema_version" => @schema_version,
      "id" => Clock.id("research_claim"),
      "source" => %{
        "action" => "search_web",
        "query" => string_value(params, "query"),
        "urls" => source_urls
      },
      "source_type" => source_type(params),
      "claim" => string_value(params, "claim"),
      "claim_origin" => "agent_supplied",
      "version_applies" => string_value(params, "version_applies"),
      "confidence" => confidence(params),
      "evidence" => evidence(result),
      "recheck_after" => string_value(params, "recheck_after"),
      "task_ref" => task_ref(params, opts),
      "repair_run_id" => string_value(params, "repair_run_id"),
      "created_at" => Clock.iso_now()
    }
    |> reject_empty()
  end

  defp record_intent(params) when is_map(params) do
    with :ok <- canonical_attrs(params) do
      case Map.fetch(params, "save_research_claim") do
        {:ok, true} -> required_recording_params(params)
        {:ok, false} -> :skip
        {:ok, _value} -> {:error, invalid_param("save_research_claim", "must be true or false")}
        :error -> :skip
      end
    end
  end

  defp record_intent(_params), do: :skip

  defp normalize_result(result) when is_map(result), do: {:ok, result}
  defp normalize_result(result) when is_binary(result), do: {:ok, %{"text" => result}}
  defp normalize_result(_result), do: {:ok, %{"text" => ""}}

  defp required_recording_params(params) do
    with {:ok, _claim} <- required_text(params, "claim"),
         {:ok, _source_type} <- required_source_type(params),
         {:ok, _version} <- required_text(params, "version_applies"),
         :ok <- required_confidence(params),
         :ok <- valid_source_urls(params) do
      :record
    end
  end

  defp required_source_type(params) do
    case required_text(params, "source_type") do
      {:ok, value} ->
        if value in @source_types do
          {:ok, value}
        else
          {:error, invalid_param("source_type", "must be a known source type")}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp required_confidence(params) do
    case Map.fetch(params, "confidence") do
      {:ok, value} when is_number(value) and value >= 0.0 and value <= 1.0 ->
        :ok

      {:ok, _value} ->
        {:error, invalid_param("confidence", "must be a number between 0 and 1")}

      :error ->
        {:error, invalid_param("confidence", "is required when save_research_claim is true")}
    end
  end

  defp valid_source_urls(params) do
    case Map.fetch(params, "source_urls") do
      {:ok, urls} when is_list(urls) ->
        if Enum.all?(urls, &is_binary/1) do
          :ok
        else
          {:error, invalid_param("source_urls", "must contain only strings")}
        end

      {:ok, _value} ->
        {:error, invalid_param("source_urls", "must be a list of strings")}

      :error ->
        :ok
    end
  end

  defp source_urls(params, result) do
    explicit =
      params
      |> Map.get("source_urls", [])
      |> List.wrap()
      |> Enum.filter(&is_binary/1)

    result_urls =
      result
      |> Map.get("source_urls", [])
      |> List.wrap()
      |> Enum.filter(&is_binary/1)

    result_urls_from_rows =
      result
      |> Map.get("results", [])
      |> List.wrap()
      |> Enum.flat_map(fn
        %{"url" => url} when is_binary(url) -> [url]
        _row -> []
      end)

    (explicit ++ result_urls ++ result_urls_from_rows)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp source_type(params), do: string_value(params, "source_type")

  defp confidence(params) do
    case params["confidence"] do
      number when is_number(number) ->
        number

      _value ->
        nil
    end
  end

  defp evidence(result) do
    text = result_text(result)

    %{
      "action_output_preview" => text |> String.slice(0, @max_preview_chars) |> String.trim(),
      "action_output_bytes" => byte_size(text),
      "result_count" => result |> Map.get("results", []) |> List.wrap() |> length()
    }
  end

  defp filter_claims(claims, opts) do
    claims
    |> filter_exact("task_ref", opts[:task_ref])
    |> filter_exact("source_type", opts[:source_type])
  end

  defp filter_exact(claims, _field, value) when value in [nil, ""], do: claims

  defp filter_exact(claims, field, value) do
    Enum.filter(claims, &(&1[field] == value))
  end

  defp string_value(map, key) do
    case map[key] do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _value ->
        nil
    end
  end

  defp required_text(map, key) do
    case string_value(map, key) do
      nil -> {:error, invalid_param(key, "is required when save_research_claim is true")}
      value -> {:ok, value}
    end
  end

  defp task_ref(params, opts) do
    case string_value(params, "task_ref") do
      nil -> opts[:task_ref]
      value -> value
    end
  end

  defp result_text(result) do
    case Map.fetch(result, "text") do
      {:ok, text} when is_binary(text) -> text
      _value -> ""
    end
  end

  defp canonical_attrs(attrs) do
    if canonical_value?(attrs) do
      :ok
    else
      {:error, invalid_param("params", "must use canonical string keys")}
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

  defp invalid_param(field, message) do
    %{
      "code" => "invalid_params",
      "field" => field,
      "message" => "#{field} #{message}"
    }
  end

  defp reject_empty(map) when is_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new(fn
      {key, value} when is_map(value) -> {key, reject_empty(value)}
      pair -> pair
    end)
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end
end
