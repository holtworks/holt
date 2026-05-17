defmodule HoltWorks.ResearchClaims do
  @moduledoc """
  File-backed structured research claim ledger.

  Research claims are explicit metadata records. HoltWorks stores raw web tool
  text as evidence preview only; durable workflow decisions must use the
  structured claim fields.
  """

  alias HoltWorks.{Clock, JSON, Paths}
  alias HoltWorks.Tasks.RuntimeContracts

  @schema_version "holtworks_research_claim/v1"
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

  def maybe_record(tool, params, opts, search_result) do
    case record_intent(params) do
      :record ->
        record(tool, params, opts, search_result)

      :skip ->
        {:ok, %{"research_claim_saved" => false}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def record("search_web", params, opts, search_result) when is_map(params) do
    claim = build_from_search_result(params, search_result, opts)
    root = Paths.workspace_root(opts)
    JSON.append_jsonl(Paths.research_claims_path(root), claim)
    {:ok, %{"research_claim_saved" => true, "research_claim" => claim}}
  end

  def record(_tool, _params, _opts, _result), do: {:error, :unsupported_research_claim_source}

  def list(opts \\ []) do
    root = Paths.workspace_root(opts)

    root
    |> Paths.research_claims_path()
    |> JSON.read_jsonl()
    |> filter_claims(opts)
  end

  def build_from_search_result(params, search_result, opts \\ []) when is_map(params) do
    params = RuntimeContracts.string_keys(params)
    result = normalize_result(search_result)
    source_urls = source_urls(params, result)

    %{
      "schema_version" => @schema_version,
      "id" => Clock.id("research_claim"),
      "source" => %{
        "tool" => "search_web",
        "query" => string_value(params, "query"),
        "urls" => source_urls
      },
      "source_type" => source_type(params, "web_search"),
      "claim" => string_value(params, "claim"),
      "claim_origin" => "agent_supplied",
      "version_applies" => string_value(params, "version_applies") || "unknown",
      "confidence" => confidence(params),
      "evidence" => evidence(result),
      "recheck_after" => string_value(params, "recheck_after"),
      "task_ref" =>
        string_value(params, "task_ref") || string_value(params, "ref") || opts[:task_ref],
      "repair_run_id" => string_value(params, "repair_run_id"),
      "created_at" => Clock.iso_now()
    }
    |> reject_empty()
  end

  defp record_intent(params) when is_map(params) do
    params = RuntimeContracts.string_keys(params)
    save? = Map.get(params, "save_research_claim")
    claim = string_value(params, "claim")

    cond do
      save? == false ->
        :skip

      save? == true and claim in [nil, ""] ->
        {:error,
         %{
           "code" => "invalid_params",
           "field" => "claim",
           "message" => "claim is required when save_research_claim is true"
         }}

      save? == true ->
        :record

      claim not in [nil, ""] ->
        :record

      true ->
        :skip
    end
  end

  defp record_intent(_params), do: :skip

  defp normalize_result(result) when is_map(result), do: RuntimeContracts.string_keys(result)
  defp normalize_result(result) when is_binary(result), do: %{"text" => result}
  defp normalize_result(_result), do: %{"text" => ""}

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

  defp source_type(params, default) do
    value = string_value(params, "source_type") || default

    if value in @source_types do
      value
    else
      "unclassified"
    end
  end

  defp confidence(params) do
    case params["confidence"] do
      number when is_number(number) ->
        number
        |> max(0.0)
        |> min(1.0)

      _value ->
        0.5
    end
  end

  defp evidence(result) do
    text = result["text"] || ""

    %{
      "tool_output_preview" => text |> String.slice(0, @max_preview_chars) |> String.trim(),
      "tool_output_bytes" => byte_size(text),
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
