defmodule Holt.ModelsTest do
  use ExUnit.Case

  alias Holt.{Config, Models}

  @moduletag :tmp_dir

  setup %{tmp_dir: home} do
    Config.save_providers(home, Config.default_providers())
    %{home: home}
  end

  test "unknown provider ids do not fall back to local", %{home: home} do
    provider = Models.provider(home, "missing-provider")

    assert provider == %{"id" => "missing-provider", "type" => "unknown"}
    assert Models.validate(provider) == {:error, {:unknown_provider, "unknown"}}

    assert Models.chat(provider, [%{"role" => "user", "content" => "hello"}]) ==
             {:error, {:unknown_provider, "unknown"}}
  end

  test "default provider reads the configured canonical provider", %{home: home} do
    providers = Config.default_providers() |> Map.put("default_provider", "openrouter")
    Config.save_providers(home, providers)

    assert %{
             "id" => "openrouter",
             "type" => "openrouter",
             "model" => "moonshotai/kimi-k2.6"
           } = Models.default_provider(home)
  end

  test "local chat uses explicit local adapter defaults" do
    assert {:ok,
            %{
              "provider" => "local",
              "model" => "local-planner",
              "content" => "Local planner received: hello"
            }} = Models.chat(%{"type" => "local"}, [%{"role" => "user", "content" => "hello"}])
  end

  test "openrouter adapter applies explicit request defaults" do
    previous = System.get_env("OPENROUTER_API_KEY")
    System.put_env("OPENROUTER_API_KEY", "test-key")
    on_exit(fn -> restore_env("OPENROUTER_API_KEY", previous) end)

    test_pid = self()

    post_json = fn url, headers, body, api_key ->
      send(test_pid, {:request, url, headers, body, api_key})

      {:ok,
       %{
         status: 200,
         body: %{
           "choices" => [
             %{
               "finish_reason" => "stop",
               "message" => %{"content" => "ok"}
             }
           ]
         }
       }}
    end

    assert {:ok,
            %{
              "provider" => "openrouter",
              "model" => "moonshotai/kimi-k2.6",
              "content" => "ok"
            }} =
             Models.chat(
               %{"type" => "openrouter", "api_key_env" => "OPENROUTER_API_KEY"},
               [%{"role" => "user", "content" => "hello"}],
               post_json: post_json
             )

    assert_received {:request, "https://openrouter.ai/api/v1/chat/completions", headers, body,
                     "test-key"}

    assert {"HTTP-Referer", "https://holtworks.ai"} in headers
    assert {"X-Title", "Holt"} in headers
    assert body.model == "moonshotai/kimi-k2.6"
    assert body.max_tokens == 1_200
    assert body.temperature == 0.2
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
