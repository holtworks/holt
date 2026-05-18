defmodule Holt.WebSearchTest do
  use ExUnit.Case

  alias Holt.WebSearch

  test "search args are canonical and provider payloads use declared fields" do
    assert WebSearch.search_web(%{query: "holt"}, web_search: fn _args, _opts -> "never" end) ==
             {:error, :invalid_search_arguments}

    web_search = fn %{"query" => "holt", "max_results" => 3}, _opts ->
      %{
        "answer" => "Holt docs are available.",
        "results" => [
          %{
            "title" => "Docs",
            "url" => "https://holtworks.ai/docs",
            "content" => "Documentation"
          }
        ],
        "items" => [
          %{"title" => "Ignored", "url" => "https://example.com", "content" => "Ignored"}
        ]
      }
    end

    assert {:ok, result} =
             WebSearch.search_web(%{"query" => "holt", "max_results" => 3},
               web_search: web_search
             )

    assert result["answer"] == "Holt docs are available."
    assert result["source_urls"] == ["https://holtworks.ai/docs"]
    assert result["text"] =~ "Docs"
    refute result["text"] =~ "Ignored"
  end
end
