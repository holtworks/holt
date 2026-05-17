defmodule HoltWorks.Tasks.ProviderRegistry do
  @moduledoc """
  Runtime-facing provider profile contract for local HoltWorks agents.
  """

  alias HoltWorks.Tasks.RuntimeContracts

  @schema_version "holtworks_provider_profile/v1"

  def profile(model_id, attrs \\ %{})

  def profile(model_id, attrs) when is_binary(model_id) and is_map(attrs) do
    attrs = RuntimeContracts.string_keys(attrs)
    provider = RuntimeContracts.text(attrs, "provider") || provider_from_model(model_id)

    %{
      "schema_version" => @schema_version,
      "model_id" => model_id,
      "model" => model_id,
      "provider" => provider,
      "runtime_kind" => runtime_kind(provider),
      "context_window" => context_window(attrs, provider),
      "default_output_reserve_tokens" => output_reserve(model_id, attrs),
      "supports_tool_calls" => supports_tool_calls?(provider),
      "supports_streaming" => supports_streaming?(provider),
      "requires_api_key" => requires_api_key?(provider),
      "requires_desktop_session" => false,
      "route" => route(provider, model_id, attrs)
    }
    |> RuntimeContracts.reject_empty()
  end

  def profile(_model_id, attrs) when is_map(attrs) do
    attrs = RuntimeContracts.string_keys(attrs)
    profile(RuntimeContracts.text(attrs, "model", "local-planner"), attrs)
  end

  def profile(_model_id, _attrs), do: profile("local-planner", %{})

  defp provider_from_model("local-planner"), do: "local"
  defp provider_from_model("llama3.1"), do: "ollama"
  defp provider_from_model("openai/" <> _model), do: "openrouter"
  defp provider_from_model("ollama/" <> _model), do: "ollama"
  defp provider_from_model("gpt-" <> _model), do: "openai"
  defp provider_from_model(_model_id), do: "openrouter"

  defp runtime_kind("local"), do: "local_planner"
  defp runtime_kind("ollama"), do: "local_http"
  defp runtime_kind("openai"), do: "hosted_llm"
  defp runtime_kind("openrouter"), do: "hosted_llm"
  defp runtime_kind(_provider), do: "hosted_llm"

  defp context_window(attrs, provider) do
    case RuntimeContracts.integer(RuntimeContracts.value(attrs, "context_window")) do
      int when int > 0 -> int
      _int -> default_context_window(provider)
    end
  end

  defp default_context_window("local"), do: 32_000
  defp default_context_window("ollama"), do: 32_000
  defp default_context_window(_provider), do: 128_000

  defp output_reserve(_model_id, attrs) do
    case RuntimeContracts.integer(RuntimeContracts.value(attrs, "output_reserve_tokens")) do
      int when int > 0 -> int
      _int -> 8_192
    end
  end

  defp supports_tool_calls?("local"), do: false
  defp supports_tool_calls?(_provider), do: true

  defp supports_streaming?("local"), do: false
  defp supports_streaming?(_provider), do: true

  defp requires_api_key?("openai"), do: true
  defp requires_api_key?("openrouter"), do: true
  defp requires_api_key?(_provider), do: false

  defp route("local", _model_id, _attrs), do: %{"adapter" => "local"}

  defp route("ollama", _model_id, attrs) do
    %{"adapter" => "ollama", "base_url" => RuntimeContracts.text(attrs, "base_url")}
    |> RuntimeContracts.reject_empty()
  end

  defp route("openai", _model_id, attrs) do
    %{"adapter" => "openai", "api_key_env" => RuntimeContracts.text(attrs, "api_key_env")}
    |> RuntimeContracts.reject_empty()
  end

  defp route("openrouter", _model_id, attrs) do
    %{"adapter" => "openrouter", "api_key_env" => RuntimeContracts.text(attrs, "api_key_env")}
    |> RuntimeContracts.reject_empty()
  end

  defp route(provider, _model_id, _attrs), do: %{"adapter" => provider}
end
