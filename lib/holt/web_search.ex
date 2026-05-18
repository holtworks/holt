defmodule Holt.WebSearch do
  @moduledoc """
  Web search adapter for the local Holt runtime.

  Tests and embedded callers can pass `:web_search` in opts to avoid network
  access. The default provider uses Tavily when `TAVILY_API_KEY` is available.
  """

  @max_result_bytes 8_000

  def search_web(args, opts \\ [])

  def search_web(args, opts) when is_map(args) do
    with :ok <- canonical_args(args),
         {:ok, query} <- required_text(args, "query") do
      cond do
        is_function(opts[:web_search], 2) ->
          opts[:web_search].(args, opts) |> normalize_result(query)

        is_function(opts[:web_search], 1) ->
          opts[:web_search].(args) |> normalize_result(query)

        true ->
          tavily_search(query, args, opts)
      end
    end
  end

  def search_web(_args, _opts), do: {:error, :invalid_search_arguments}

  defp tavily_search(query, args, opts) do
    Holt.Env.load(opts)

    case System.get_env("TAVILY_API_KEY") do
      key when is_binary(key) and key != "" ->
        body = %{
          api_key: key,
          query: query,
          search_depth: "basic",
          include_answer: true,
          max_results: max_results(args)
        }

        case Req.post("https://api.tavily.com/search", json: body, receive_timeout: 20_000) do
          {:ok, %{status: status, body: body}} when status in 200..299 ->
            {:ok, normalize_search_payload(query, body)}

          {:ok, %{status: status}} ->
            {:error, {:web_search_status, status}}

          {:error, reason} ->
            {:error, reason}
        end

      _missing ->
        {:error, :web_search_not_configured}
    end
  end

  defp normalize_result({:ok, result}, query), do: {:ok, normalize_search_payload(query, result)}
  defp normalize_result({:error, reason}, _query), do: {:error, reason}
  defp normalize_result(result, query), do: {:ok, normalize_search_payload(query, result)}

  defp normalize_search_payload(query, text) when is_binary(text) do
    %{
      "query" => query,
      "answer" => nil,
      "results" => [],
      "source_urls" => [],
      "text" => truncate(text)
    }
  end

  defp normalize_search_payload(query, payload) when is_map(payload) do
    answer = string_value(payload, "answer")
    results = normalize_results(Map.get(payload, "results", []))
    source_urls = source_urls(results, payload)
    text = result_text(payload, query, answer, results)

    %{
      "query" => query,
      "answer" => answer,
      "results" => results,
      "source_urls" => source_urls,
      "text" => truncate(text)
    }
    |> reject_empty()
  end

  defp normalize_search_payload(query, _payload) do
    normalize_search_payload(query, "")
  end

  defp normalize_results(results) when is_list(results) do
    results
    |> Enum.map(&normalize_result_row/1)
    |> Enum.reject(&(&1 == %{}))
  end

  defp normalize_results(_results), do: []

  defp normalize_result_row(result) when is_map(result) do
    %{
      "title" => string_value(result, "title"),
      "url" => string_value(result, "url"),
      "content" => string_value(result, "content"),
      "score" => result["score"]
    }
    |> reject_empty()
  end

  defp normalize_result_row(_result), do: %{}

  defp source_urls(results, payload) do
    explicit =
      payload
      |> Map.get("source_urls", [])
      |> List.wrap()
      |> Enum.filter(&is_binary/1)

    result_urls =
      results
      |> Enum.map(& &1["url"])
      |> Enum.filter(&is_binary/1)

    (explicit ++ result_urls)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp format_results(query, answer, results) do
    answer_section =
      case answer do
        nil -> ""
        "" -> ""
        text -> "**Answer:** #{text}\n\n"
      end

    result_sections =
      results
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {result, index} ->
        [
          "### #{index}. #{result_title(result)}",
          result_content(result),
          "Source: #{result_url(result)}"
        ]
        |> Enum.join("\n")
      end)

    "## Search Results for \"#{query}\"\n\n#{answer_section}#{result_sections}"
  end

  defp truncate(text) when byte_size(text) <= @max_result_bytes, do: text

  defp truncate(text) do
    text
    |> binary_part(0, @max_result_bytes)
    |> String.slice(0..-2//1)
    |> Kernel.<>("\n\n[Results truncated]")
  end

  defp max_results(args) do
    case args["max_results"] do
      value when value in 1..10 -> value
      _value -> 5
    end
  end

  defp result_text(payload, query, answer, results) do
    case string_value(payload, "text") do
      nil -> format_results(query, answer, results)
      text -> text
    end
  end

  defp result_title(%{"title" => title}) when is_binary(title) and title != "",
    do: title

  defp result_title(_result), do: "Untitled result"

  defp result_content(%{"content" => content}) when is_binary(content), do: content
  defp result_content(_result), do: ""

  defp result_url(%{"url" => url}) when is_binary(url) and url != "", do: url
  defp result_url(_result), do: "unknown"

  defp required_text(map, key) do
    case string_value(map, key) do
      nil -> {:error, :query_required}
      value -> {:ok, value}
    end
  end

  defp canonical_args(args) do
    if canonical_value?(args) do
      :ok
    else
      {:error, :invalid_search_arguments}
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

  defp string_value(map, key) do
    case map[key] do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _value ->
        nil
    end
  end

  defp reject_empty(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end
end
