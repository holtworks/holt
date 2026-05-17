defmodule Holt.TextMatch do
  @moduledoc """
  Token-based text matching for local search and skill relevance.
  """

  @trim_chars " \t\n\r.,;:!?()[]{}<>\"'`|/\\"

  def tokens(text) do
    text
    |> to_string()
    |> String.downcase()
    |> String.split()
    |> Enum.map(&String.trim(&1, @trim_chars))
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  def matches?(text, query) do
    query_tokens = tokens(query)

    MapSet.size(query_tokens) > 0 and MapSet.subset?(query_tokens, tokens(text))
  end

  def phrase_in_tokens?(phrase, candidate_tokens) do
    phrase_tokens = tokens(phrase)

    MapSet.size(phrase_tokens) > 0 and MapSet.subset?(phrase_tokens, candidate_tokens)
  end

  def overlap_count(text, candidate_tokens) do
    text
    |> tokens()
    |> MapSet.intersection(candidate_tokens)
    |> MapSet.size()
  end
end
