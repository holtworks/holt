defmodule HoltWorks.Models do
  @moduledoc """
  Model provider adapter boundary.
  """

  alias HoltWorks.Config

  def default_provider(home) do
    providers = Config.load_providers(home)
    provider_id = providers["default_provider"] || "local"
    provider(home, provider_id)
  end

  def provider(home, provider_id) do
    providers = Config.load_providers(home)
    provider = get_in(providers, ["providers", provider_id]) || %{"type" => "local"}
    Map.put(provider, "id", provider_id)
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

  def list_models(%{"type" => "openai", "model" => model}) do
    {:ok, [model || "gpt-5.2"]}
  end

  def list_models(%{"type" => "openrouter", "model" => model}) do
    {:ok, [model || "openai/gpt-4o-mini"]}
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

  def smoke_messages(prompt \\ "Say HoltWorks LLM smoke test ok.") do
    [
      %{
        "role" => "system",
        "content" => "You are testing HoltWorks model connectivity. Reply in one short sentence."
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
       "provider" => provider["id"] || "local",
       "model" => provider["model"] || "local-planner",
       "content" => "Local planner received: #{latest_user}"
     }}
  end

  defp do_chat(%{"type" => "openai", "api_key_env" => env} = provider, messages, opts) do
    with api_key when is_binary(api_key) and api_key != "" <- System.get_env(env),
         body <- chat_body(provider["model"] || "gpt-5.2", messages, opts),
         {:ok, response} <-
           Req.post(
             "https://api.openai.com/v1/chat/completions",
             auth: {:bearer, api_key},
             json: body,
             receive_timeout: 60_000
           ),
         true <- response.status in 200..299,
         message when is_map(message) <-
           get_in(response.body, ["choices", Access.at(0), "message"]) do
      {:ok, normalize_chat_message(provider, "openai", message, response.body)}
    else
      nil -> {:error, {:missing_env, env}}
      false -> {:error, :openai_request_failed}
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  defp do_chat(%{"type" => "openrouter", "api_key_env" => env} = provider, messages, opts) do
    with api_key when is_binary(api_key) and api_key != "" <- System.get_env(env),
         body <- openrouter_body(provider, messages, opts),
         headers <- openrouter_headers(provider),
         {:ok, response} <- post_json(openrouter_chat_url(provider), headers, body, opts, api_key),
         true <- response.status in 200..299,
         message when is_map(message) <-
           get_in(response.body, ["choices", Access.at(0), "message"]) do
      {:ok, normalize_chat_message(provider, "openrouter", message, response.body)}
    else
      nil -> {:error, {:missing_env, env}}
      false -> {:error, :openrouter_request_failed}
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  defp do_chat(%{"type" => "ollama", "base_url" => url} = provider, messages, opts) do
    with {:ok, response} <-
           Req.post(
             url_with_path(url, "api/chat"),
             json: chat_body(provider["model"] || "llama3.1", messages, opts),
             receive_timeout: 60_000
           ),
         true <- response.status in 200..299,
         message when is_map(message) <- Map.get(response.body, "message") do
      {:ok, normalize_chat_message(provider, "ollama", message, response.body)}
    else
      false -> {:error, :ollama_request_failed}
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  defp do_chat(provider, _messages, _opts), do: {:error, {:unknown_provider, provider["type"]}}

  defp openrouter_body(provider, messages, opts) do
    model = provider["model"] || "openai/gpt-4o-mini"

    model
    |> chat_body(messages, opts)
    |> Map.put(:max_tokens, provider["max_tokens"] || 1_200)
    |> Map.put(:temperature, provider["temperature"] || 0.2)
  end

  defp chat_body(model, messages, opts) do
    %{
      model: model,
      messages: messages,
      stream: false
    }
    |> maybe_put(:tools, opts[:tools])
    |> maybe_put(:tool_choice, opts[:tool_choice])
  end

  defp normalize_chat_message(provider, provider_type, message, body) do
    %{
      "provider" => provider["id"] || provider_type,
      "model" => provider["model"],
      "content" => message["content"] || "",
      "tool_calls" => normalize_tool_calls(message["tool_calls"] || []),
      "finish_reason" => get_in(body, ["choices", Access.at(0), "finish_reason"])
    }
    |> reject_empty()
  end

  defp normalize_tool_calls(tool_calls) when is_list(tool_calls) do
    Enum.map(tool_calls, fn
      %{"function" => %{} = function} = call ->
        %{
          "id" => call["id"],
          "type" => call["type"] || "function",
          "function" => %{
            "name" => function["name"],
            "arguments" => function["arguments"] || "{}"
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
      {"HTTP-Referer", provider["http_referer"] || "https://holtworks.ai"},
      {"X-Title", provider["app_title"] || "HoltWorks"}
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

  defp maybe_put(map, _key, value) when value in [nil, "", []], do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp reject_empty(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end
end
