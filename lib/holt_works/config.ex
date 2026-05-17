defmodule HoltWorks.Config do
  @moduledoc """
  Local configuration stored under `~/.holtworks`.
  """

  alias HoltWorks.{JSON, Paths}

  def bootstrap(opts \\ []) do
    home = Paths.home(opts)
    Paths.ensure_global(home)
    write_missing_config(home)
    write_missing_providers(home)

    %{
      home: home,
      config: load_config(home),
      providers: load_providers(home)
    }
  end

  def load_config(home) do
    JSON.read(Paths.config_path(home), default_config())
  end

  def load_providers(home) do
    JSON.read(Paths.providers_path(home), default_providers())
  end

  def save_config(home, config), do: JSON.write(Paths.config_path(home), config)
  def save_providers(home, providers), do: JSON.write(Paths.providers_path(home), providers)

  def default_config do
    %{
      "schema_version" => "holtworks_config/v1",
      "safety_mode" => "approval_required",
      "default_agent" => "default",
      "gateway" => %{
        "transport" => "in_process",
        "loopback_only" => true,
        "public_listener" => false
      }
    }
  end

  def default_providers do
    %{
      "schema_version" => "holtworks_providers/v1",
      "default_provider" => "local",
      "providers" => %{
        "local" => %{
          "type" => "local",
          "model" => "local-planner"
        },
        "openai" => %{
          "type" => "openai",
          "model" => "gpt-5.2",
          "api_key_env" => "OPENAI_API_KEY"
        },
        "openrouter" => %{
          "type" => "openrouter",
          "model" => "openai/gpt-4o-mini",
          "api_key_env" => "OPENROUTER_API_KEY",
          "base_url" => "https://openrouter.ai/api/v1",
          "http_referer" => "https://holtworks.ai",
          "app_title" => "HoltWorks",
          "max_tokens" => 1_200,
          "temperature" => 0.2
        },
        "ollama" => %{
          "type" => "ollama",
          "model" => "llama3.1",
          "base_url" => "http://127.0.0.1:11434"
        }
      }
    }
  end

  defp write_missing_config(home) do
    path = Paths.config_path(home)
    unless File.exists?(path), do: JSON.write(path, default_config())
  end

  defp write_missing_providers(home) do
    path = Paths.providers_path(home)
    unless File.exists?(path), do: JSON.write(path, default_providers())
  end
end
