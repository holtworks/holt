defmodule Holt.Runtime.ChatMessages do
  @moduledoc """
  Canonical chat transcript contract for runtime requests.
  """

  @roles ~w(user assistant)
  @invalid_error {:invalid_param, "chat_messages",
                  "expected a list of maps with string role and content fields"}

  def decode_param(value) when value in [nil, ""], do: {:ok, []}

  def decode_param(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> normalize(decoded)
      {:error, _reason} -> {:error, @invalid_error}
    end
  end

  def decode_param(value), do: normalize(value)

  def normalize(nil), do: {:ok, []}

  def normalize(messages) when is_list(messages) do
    messages
    |> Enum.reduce_while({:ok, []}, fn message, {:ok, acc} ->
      case normalize_one(message) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  def normalize(_messages), do: {:error, @invalid_error}

  def contents(messages) do
    messages
    |> Enum.map(& &1["content"])
    |> Enum.reject(&(&1 in [nil, ""]))
  end

  defp normalize_one(%{"role" => role, "content" => content} = message)
       when role in @roles and is_binary(content) do
    if Map.keys(message) |> Enum.sort() == ["content", "role"] do
      {:ok, %{"role" => role, "content" => content}}
    else
      {:error, @invalid_error}
    end
  end

  defp normalize_one(_message), do: {:error, @invalid_error}
end
