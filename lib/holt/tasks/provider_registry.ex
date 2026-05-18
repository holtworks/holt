defmodule Holt.Tasks.ProviderRegistry do
  @moduledoc """
  Runtime-facing provider profile contract for local Holt agents.
  """

  @schema_version "holt_provider_profile/v1"

  def profile(model_id, attrs \\ %{})

  def profile(model_id, attrs) when is_binary(model_id) and is_map(attrs) do
    with :ok <- valid_model_id(model_id),
         :ok <- canonical_attrs(attrs),
         {:ok, provider} <- required_text(attrs, "provider"),
         {:ok, context_window} <- context_window(attrs, provider),
         {:ok, output_reserve} <- output_reserve(attrs),
         {:ok, route} <- route(provider, attrs) do
      profile_canonical(model_id, provider, context_window, output_reserve, route)
    else
      {:error, reason} -> rejected_profile(%{"model_id" => model_id}, reason)
    end
  end

  def profile(model_id, _attrs) when is_binary(model_id) do
    case valid_model_id(model_id) do
      :ok -> rejected_profile(%{"model_id" => model_id}, "invalid_attrs")
      {:error, reason} -> rejected_profile(%{}, reason)
    end
  end

  def profile(_model_id, attrs) when is_map(attrs),
    do: rejected_profile(attrs, "invalid_model_id")

  def profile(_model_id, _attrs), do: rejected_profile(%{}, "invalid_model_id")

  defp profile_canonical(model_id, provider, context_window, output_reserve, route) do
    %{
      "schema_version" => @schema_version,
      "model_id" => model_id,
      "model" => model_id,
      "provider" => provider,
      "runtime_kind" => runtime_kind(provider),
      "context_window" => context_window,
      "default_output_reserve_tokens" => output_reserve,
      "supports_action_calls" => supports_action_calls?(provider),
      "supports_streaming" => supports_streaming?(provider),
      "requires_api_key" => requires_api_key?(provider),
      "requires_desktop_session" => false,
      "route" => route
    }
    |> reject_empty()
  end

  defp runtime_kind("local"), do: "local_planner"
  defp runtime_kind("ollama"), do: "local_http"
  defp runtime_kind("openai"), do: "hosted_llm"
  defp runtime_kind("openrouter"), do: "hosted_llm"
  defp runtime_kind(_provider), do: "hosted_llm"

  defp context_window(attrs, provider) do
    positive_integer(attrs, "context_window", default_context_window(provider))
  end

  defp default_context_window("local"), do: 32_000
  defp default_context_window("ollama"), do: 32_000
  defp default_context_window(_provider), do: 128_000

  defp output_reserve(attrs) do
    positive_integer(attrs, "output_reserve_tokens", 8_192)
  end

  defp supports_action_calls?("local"), do: false
  defp supports_action_calls?(_provider), do: true

  defp supports_streaming?("local"), do: false
  defp supports_streaming?(_provider), do: true

  defp requires_api_key?("openai"), do: true
  defp requires_api_key?("openrouter"), do: true
  defp requires_api_key?(_provider), do: false

  defp route("local", _attrs), do: {:ok, %{"adapter" => "local"}}

  defp route("ollama", attrs) do
    with {:ok, base_url} <- optional_text(attrs, "base_url") do
      {:ok, reject_empty(%{"adapter" => "ollama", "base_url" => base_url})}
    end
  end

  defp route("openai", attrs) do
    with {:ok, api_key_env} <- optional_text(attrs, "api_key_env") do
      {:ok, reject_empty(%{"adapter" => "openai", "api_key_env" => api_key_env})}
    end
  end

  defp route("openrouter", attrs) do
    with {:ok, api_key_env} <- optional_text(attrs, "api_key_env"),
         {:ok, base_url} <- optional_text(attrs, "base_url") do
      {:ok,
       reject_empty(%{
         "adapter" => "openrouter",
         "api_key_env" => api_key_env,
         "base_url" => base_url
       })}
    end
  end

  defp route(provider, _attrs), do: {:ok, %{"adapter" => provider}}

  defp rejected_profile(attrs, reason) do
    %{
      "schema_version" => @schema_version,
      "status" => "rejected",
      "reason" => reason
    }
    |> put_rejected_model_id(attrs)
    |> reject_empty()
  end

  defp valid_model_id(model_id) do
    case text_value(model_id) do
      {:ok, ^model_id} -> :ok
      {:ok, _text} -> {:error, "invalid_model_id"}
      :error -> {:error, "invalid_model_id"}
    end
  end

  defp canonical_attrs(attrs) do
    if Enum.all?(attrs, fn {key, _value} -> is_binary(key) end) do
      :ok
    else
      {:error, "invalid_attrs"}
    end
  end

  defp required_text(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> field_text(key, value)
      :error -> {:error, "missing_required:#{key}"}
    end
  end

  defp optional_text(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> field_text(key, value)
      :error -> {:ok, nil}
    end
  end

  defp field_text(key, value) do
    case text_value(value) do
      {:ok, text} -> {:ok, text}
      :error -> {:error, "invalid_field:#{key}"}
    end
  end

  defp text_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> :error
      text -> {:ok, text}
    end
  end

  defp text_value(_value), do: :error

  defp positive_integer(attrs, key, default) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> positive_integer_value(key, value)
      :error -> {:ok, default}
    end
  end

  defp positive_integer_value(_key, value) when is_integer(value) and value > 0,
    do: {:ok, value}

  defp positive_integer_value(key, _value), do: {:error, "invalid_field:#{key}"}

  defp put_rejected_model_id(profile, %{"model_id" => model_id}) when is_binary(model_id) do
    case text_value(model_id) do
      {:ok, text} -> Map.put(profile, "model_id", text)
      :error -> profile
    end
  end

  defp put_rejected_model_id(profile, _attrs), do: profile

  defp reject_empty(map) do
    map
    |> Enum.reject(fn {_key, value} -> empty?(value) end)
    |> Map.new()
  end

  defp empty?(nil), do: true
  defp empty?(""), do: true
  defp empty?([]), do: true
  defp empty?(map) when is_map(map), do: map_size(map) == 0
  defp empty?(_value), do: false
end
