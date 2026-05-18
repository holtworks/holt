defmodule Holt.Models do
  @moduledoc """
  Model provider adapter boundary.
  """

  alias Holt.Config

  def default_provider(home) do
    providers = Config.load_providers(home)
    provider_id = provider_config_value(providers, "default_provider", "local")
    provider(home, provider_id)
  end

  def provider(home, provider_id) do
    providers = Config.load_providers(home)

    case get_in(providers, ["providers", provider_id]) do
      provider when is_map(provider) -> Map.put(provider, "id", provider_id)
      _missing -> %{"id" => provider_id, "type" => "unknown"}
    end
  end

  def validate(%{"type" => "local"}), do: :ok

  def validate(%{"type" => "openai", "api_key_env" => env}) do
    if System.get_env(env) in [nil, ""] do
      {:error, {:missing_env, env}}
    else
      :ok
    end
  end

  def validate(%{"type" => "openrouter", "api_key_env" => env}) do
    if System.get_env(env) in [nil, ""] do
      {:error, {:missing_env, env}}
    else
      :ok
    end
  end

  def validate(%{"type" => "ollama", "base_url" => url}) do
    case Req.get(url_with_path(url, "api/tags"), receive_timeout: 2_000) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status}} -> {:error, {:ollama_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  def validate(provider), do: {:error, {:unknown_provider, provider["type"]}}

  def list_models(%{"type" => "local"}), do: {:ok, ["local-planner"]}

  def list_models(%{"type" => "openai"} = provider) do
    {:ok, [provider_model(provider, "gpt-5.2")]}
  end

  def list_models(%{"type" => "openrouter"} = provider) do
    {:ok, [provider_model(provider, "moonshotai/kimi-k2.6")]}
  end

  def list_models(%{"type" => "ollama", "base_url" => url}) do
    with {:ok, response} <- Req.get(url_with_path(url, "api/tags")),
         true <- response.status in 200..299 do
      names =
        response.body
        |> Map.get("models", [])
        |> Enum.map(&Map.get(&1, "name"))
        |> Enum.reject(&is_nil/1)

      {:ok, names}
    else
      _ -> {:ok, []}
    end
  end

  def list_models(_provider), do: {:ok, []}

  def smoke_messages(prompt \\ "Say Holt LLM smoke test ok.") do
    [
      %{
        "role" => "system",
        "content" => "You are testing Holt model connectivity. Reply in one short sentence."
      },
      %{"role" => "user", "content" => prompt}
    ]
  end

  def chat(provider, messages, opts \\ [])

  def chat(provider, messages, opts) when is_list(opts) do
    case opts[:model_chat] do
      chat when is_function(chat, 3) -> chat.(provider, messages, opts)
      _missing -> do_chat(provider, messages, opts)
    end
  end

  defp do_chat(%{"type" => "local"} = provider, messages, _opts) do
    latest_user =
      messages
      |> Enum.reverse()
      |> Enum.find(fn message -> Map.get(message, "role") == "user" end)
      |> case do
        nil -> "No user message supplied."
        message -> Map.get(message, "content", "")
      end

    {:ok,
     %{
       "provider" => provider_id(provider, "local"),
       "model" => provider_model(provider, "local-planner"),
       "content" => "Local planner received: #{latest_user}"
     }}
  end

  defp do_chat(%{"type" => "openai", "api_key_env" => env} = provider, messages, opts) do
    case System.get_env(env) do
      api_key when is_binary(api_key) and api_key != "" ->
        body = chat_body(provider_model(provider, "gpt-5.2"), messages, opts)

        "https://api.openai.com/v1/chat/completions"
        |> Req.post(auth: {:bearer, api_key}, json: body, receive_timeout: 60_000)
        |> normalize_provider_response(provider, "openai")

      _missing ->
        {:error, {:missing_env, env}}
    end
  end

  defp do_chat(%{"type" => "openrouter", "api_key_env" => env} = provider, messages, opts) do
    case System.get_env(env) do
      api_key when is_binary(api_key) and api_key != "" ->
        body = openrouter_body(provider, messages, opts)
        headers = openrouter_headers(provider)

        provider
        |> openrouter_chat_url()
        |> post_json(headers, body, opts, api_key)
        |> normalize_provider_response(provider, "openrouter")

      _missing ->
        {:error, {:missing_env, env}}
    end
  end

  defp do_chat(%{"type" => "ollama", "base_url" => url} = provider, messages, opts) do
    url
    |> url_with_path("api/chat")
    |> Req.post(
      json: chat_body(provider_model(provider, "llama3.1"), messages, opts),
      receive_timeout: 60_000
    )
    |> normalize_provider_response(provider, "ollama")
  end

  defp do_chat(provider, _messages, _opts), do: {:error, {:unknown_provider, provider["type"]}}

  defp openrouter_body(provider, messages, opts) do
    model = provider_model(provider, "moonshotai/kimi-k2.6")

    model
    |> chat_body(messages, opts)
    |> Map.put(:max_tokens, provider_number(provider, "max_tokens", 1_200))
    |> Map.put(:temperature, provider_number(provider, "temperature", 0.2))
    |> maybe_put(:reasoning, openrouter_reasoning(provider))
  end

  defp openrouter_reasoning(%{"reasoning" => false}), do: nil
  defp openrouter_reasoning(%{"reasoning" => %{} = reasoning}), do: reasoning
  defp openrouter_reasoning(_provider), do: %{"enabled" => true, "exclude" => false}

  defp chat_body(model, messages, opts) do
    %{
      model: model,
      messages: provider_messages(messages),
      stream: false
    }
    |> maybe_put(:tools, opts[:actions])
    |> maybe_put(:tool_choice, opts[:tool_choice])
  end

  defp provider_messages(messages) when is_list(messages) do
    Enum.map(messages, &provider_message/1)
  end

  defp provider_message(%{"role" => "action"} = message) do
    message
    |> Map.put("role", "tool")
    |> Map.take(["role", "tool_call_id", "content"])
  end

  defp provider_message(message), do: message

  defp normalize_chat_message(provider, provider_type, message, body) do
    %{
      "provider" => provider_id(provider, provider_type),
      "model" => provider_model(provider, provider_default_model(provider_type)),
      "content" => message_content(message),
      "tool_calls" => normalize_tool_calls(Map.get(message, "tool_calls", [])),
      "finish_reason" => get_in(body, ["choices", Access.at(0), "finish_reason"])
    }
    |> maybe_put("reasoning", reasoning_text(message))
    |> maybe_put("reasoning_details", normalize_reasoning_details(message["reasoning_details"]))
    |> reject_empty()
  end

  defp reasoning_text(%{"reasoning" => reasoning}) when is_binary(reasoning), do: reasoning
  defp reasoning_text(_message), do: nil

  defp normalize_reasoning_details(details) when is_list(details) do
    Enum.filter(details, &is_map/1)
  end

  defp normalize_reasoning_details(_details), do: []

  defp normalize_provider_response({:error, reason}, _provider, _provider_type),
    do: {:error, reason}

  defp normalize_provider_response({:ok, %{status: status, body: body}}, provider, provider_type)
       when status in 200..299 do
    message =
      case provider_type do
        "ollama" -> body["message"]
        _provider -> get_in(body, ["choices", Access.at(0), "message"])
      end

    if is_map(message) do
      {:ok, normalize_chat_message(provider, provider_type, message, body)}
    else
      {:error, {:unexpected_provider_response, provider_type, response_error_message(body)}}
    end
  end

  defp normalize_provider_response({:ok, %{status: status, body: body}}, _provider, provider_type) do
    {:error, {:provider_request_failed, provider_type, status, response_error_message(body)}}
  end

  defp response_error_message(%{"error" => %{"message" => message}}) when is_binary(message),
    do: message

  defp response_error_message(%{"message" => message}) when is_binary(message), do: message
  defp response_error_message(%{"error" => error}) when is_binary(error), do: error
  defp response_error_message(body) when is_binary(body), do: String.slice(body, 0, 500)

  defp response_error_message(body) do
    body
    |> Jason.encode!()
    |> String.slice(0, 500)
  rescue
    _reason -> inspect(body)
  end

  defp normalize_tool_calls(tool_calls) when is_list(tool_calls) do
    Enum.map(tool_calls, fn
      %{"function" => %{} = function} = call ->
        %{
          "id" => call["id"],
          "type" => tool_call_type(call),
          "function" => %{
            "name" => function["name"],
            "arguments" => tool_call_arguments(function)
          }
        }
        |> reject_empty()

      call when is_map(call) ->
        call

      value ->
        %{"raw" => inspect(value)}
    end)
  end

  defp normalize_tool_calls(_tool_calls), do: []

  defp openrouter_headers(provider) do
    [
      {"HTTP-Referer", provider_config_value(provider, "http_referer", "https://holtworks.ai")},
      {"X-Title", provider_config_value(provider, "app_title", "Holt")}
    ]
  end

  defp openrouter_chat_url(provider) do
    provider
    |> Map.get("base_url", "https://openrouter.ai/api/v1")
    |> url_with_path("chat/completions")
  end

  defp url_with_path(base_url, suffix) do
    uri = URI.parse(base_url)
    path = "/" <> Enum.join(path_segments(uri.path) ++ path_segments(suffix), "/")

    uri
    |> Map.put(:path, path)
    |> URI.to_string()
  end

  defp path_segments(nil), do: []

  defp path_segments(path) do
    path
    |> :binary.split("/", [:global])
    |> Enum.reject(&(&1 in ["", "/"]))
  end

  defp post_json(url, headers, body, opts, api_key) do
    case opts[:post_json] do
      post when is_function(post, 4) ->
        post.(url, headers, body, api_key)

      _ ->
        Req.post(url,
          auth: {:bearer, api_key},
          headers: headers,
          json: body,
          receive_timeout: 60_000
        )
    end
  end

  defp provider_id(provider, default) do
    provider_config_value(provider, "id", default)
  end

  defp provider_model(provider, default) do
    provider_config_value(provider, "model", default)
  end

  defp provider_default_model("openai"), do: "gpt-5.2"
  defp provider_default_model("openrouter"), do: "moonshotai/kimi-k2.6"
  defp provider_default_model("ollama"), do: "llama3.1"
  defp provider_default_model(_provider_type), do: "local-planner"

  defp provider_config_value(provider, key, default) do
    case Map.get(provider, key) do
      value when value in [nil, ""] -> default
      value -> value
    end
  end

  defp provider_number(provider, key, default) do
    case Map.get(provider, key) do
      value when is_number(value) -> value
      _missing -> default
    end
  end

  defp message_content(message) do
    provider_config_value(message, "content", "")
  end

  defp tool_call_type(call) do
    provider_config_value(call, "type", "function")
  end

  defp tool_call_arguments(function) do
    provider_config_value(function, "arguments", "{}")
  end

  defp maybe_put(map, _key, value) when value in [nil, "", []], do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp reject_empty(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end
end
