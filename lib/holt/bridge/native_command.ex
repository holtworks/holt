defmodule Holt.Bridge.NativeCommand do
  @moduledoc """
  Structured command boundary for the native Holt binary.

  The Rust binary owns terminal command parsing and presentation. This module is
  a small backend adapter that receives already-structured requests and invokes
  Holt runtime services.
  """

  alias Holt.Runtime.Runs

  alias Holt.{
    Config,
    Models,
    Paths,
    Runtime,
    ToolVisibility,
    Workspace
  }

  def main(encoded_request) when is_binary(encoded_request) do
    encoded_request
    |> decode_request()
    |> run()
  end

  def run(%{"command" => "doctor", "params" => params}) do
    opts = command_opts(params)
    Holt.Env.load(opts)
    home = Paths.home(opts)
    root = Paths.workspace_root(opts)
    Config.bootstrap(home: home)
    provider = Models.default_provider(home)

    checks = %{
      "version" => Holt.version(),
      "home" => home,
      "home_exists" => File.dir?(home),
      "workspace" => root,
      "workspace_initialized" => Workspace.initialized?(root),
      "provider" => provider,
      "provider_valid" => inspect(Models.validate(provider)),
      "gateway" => Holt.Gateway.status(home: home)
    }

    if json?(params) do
      IO.puts(Jason.encode!(checks, pretty: true))
    else
      IO.puts("Holt: ok")
      IO.puts("Version: #{checks["version"]}")
      IO.puts("Home: #{checks["home"]}")
      IO.puts("Workspace: #{checks["workspace"]}")
      IO.puts("Workspace initialized: #{checks["workspace_initialized"]}")
      IO.puts("Provider: #{provider["id"] || provider["type"]}")
      IO.puts("Local service: #{checks["gateway"]["status"]}")
    end

    0
  end

  def run(%{"command" => "onboard", "params" => params}) do
    opts = command_opts(params)
    Holt.Env.load(opts)
    home = Paths.home(opts)
    root = Paths.workspace_root(opts)
    bootstrap = Config.bootstrap(home: home)

    providers =
      bootstrap.providers
      |> maybe_update_provider(opts)

    Config.save_providers(home, providers)
    workspace = Workspace.init(root)

    IO.puts("Holt is ready.")
    IO.puts("Home: #{home}")
    IO.puts("Workspace: #{workspace.dir}")
    IO.puts("Created: #{format_created(workspace.created)}")
    IO.puts("Provider: #{providers["default_provider"]}")
    IO.puts("Provider check: #{inspect(Models.validate(Models.default_provider(home)))}")
    IO.puts("Local service: #{Holt.Gateway.status(home: home)["status"]}")
    IO.puts("")
    IO.puts("Next:")
    IO.puts("  holt \"inspect this folder and create a short implementation plan\"")
    0
  end

  def run(%{"command" => "run", "params" => %{"objective" => objective} = params})
      when is_binary(objective) do
    objective = String.trim(objective)

    if objective == "" do
      IO.puts(:stderr, "Usage: holt run [--yes] \"task\"")
      64
    else
      opts = runtime_opts(params)
      maybe_read_key_from_stdin(opts)
      maybe_print_turn_started(params, objective)

      case Runtime.run(objective, opts) do
        {:ok, %{run: run, output: output, artifact: artifact}} ->
          print_run_result(params, run, output, artifact)
          0

        {:error, %{run: run, reason: reason}} ->
          print_run_failure(params, run, reason)
          1

        {:error, reason} ->
          print_run_failure(params, nil, reason)
          1
      end
    end
  end

  def run(%{"command" => "resume", "params" => params}) do
    opts = runtime_opts(params)
    run_ref = non_empty_string(params["run_ref"]) || "latest"
    maybe_read_key_from_stdin(opts)
    maybe_print_turn_started(params, "resume #{run_ref}")

    case Runtime.resume(run_ref, opts) do
      {:ok, %{run: run, output: output, artifact: artifact}} ->
        print_run_result(params, run, output, artifact)
        0

      {:error, :run_not_found} ->
        print_run_failure(params, nil, :run_not_found)
        1

      {:error, reason} ->
        print_run_failure(params, nil, reason)
        1
    end
  end

  def run(%{"command" => "status", "params" => params}) do
    opts = command_opts(params)
    status = Runtime.status(opts)

    if json?(params) do
      IO.puts(Jason.encode!(status, pretty: true))
    else
      IO.puts("Workspace: #{status["workspace"] || status.workspace}")

      IO.puts(
        "Workspace initialized: #{status["workspace_initialized"] || status.workspace_initialized}"
      )

      IO.puts(
        "Local service: #{get_in(status, ["gateway", "status"]) || get_in(status, [:gateway, "status"])}"
      )

      latest = status["latest_run"] || status.latest_run

      if latest do
        IO.puts("Latest run: #{latest["id"]} #{latest["status"]}")
      else
        IO.puts("Latest run: none")
      end
    end

    0
  end

  def run(%{"command" => "logs", "params" => params}) do
    opts = command_opts(params)
    root = Paths.workspace_root(opts)

    case Runs.latest(root) do
      nil ->
        IO.puts("No runs found.")

      %{"run_dir" => run_dir} ->
        events = Runs.events(run_dir)

        if json?(params) do
          Enum.each(events, &IO.puts(Jason.encode!(&1)))
        else
          events
          |> Enum.map(&render_log_event/1)
          |> Enum.reject(&(&1 in [nil, ""]))
          |> case do
            [] -> IO.puts("No visible activity found.")
            lines -> Enum.each(lines, &IO.puts/1)
          end
        end
    end

    0
  end

  def run(%{"command" => "llm_test", "params" => params}) do
    opts = command_opts(params)
    Holt.Env.load(opts)
    home = Paths.home(opts)
    Config.bootstrap(home: home)
    provider_id = non_empty_string(params["provider_id"]) || "openrouter"

    provider =
      home
      |> Models.provider(provider_id)
      |> maybe_override_model(opts)
      |> maybe_shrink_smoke_response()

    maybe_read_key_from_stdin(opts, provider)

    case Models.validate(provider) do
      :ok ->
        run_llm_smoke(provider, opts)

      {:error, {:missing_env, env}} ->
        IO.puts(
          :stderr,
          "Missing #{env}. Export it before running the #{provider_id} smoke test."
        )

        78

      {:error, reason} ->
        IO.puts(:stderr, "Provider check failed: #{inspect(reason)}")
        1
    end
  end

  def run(_request) do
    IO.puts(:stderr, "Unsupported Holt command.")
    64
  end

  defp decode_request(encoded_request) do
    encoded_request
    |> Base.decode64!()
    |> Jason.decode!()
  end

  defp runtime_opts(params) do
    params
    |> command_opts()
    |> with_approval(params)
    |> with_runtime_progress(params)
  end

  defp command_opts(params) when is_map(params) do
    []
    |> maybe_put_opt(:home, params["home"])
    |> maybe_put_opt(:workspace, params["workspace"])
    |> maybe_put_opt(:provider, params["provider"])
    |> maybe_put_opt(:model, params["model"])
    |> maybe_put_opt(:base_url, params["base_url"])
    |> maybe_put_opt(:api_key_env, params["api_key_env"])
    |> maybe_put_opt(:env_file, params["env_file"])
    |> maybe_put_opt(:mode, params["mode"])
    |> maybe_put_opt(:chat_context, params["chat_context"])
    |> maybe_put_opt(:prompt, params["prompt"])
    |> maybe_put_opt(:api_key_stdin, truthy?(params["api_key_stdin"]))
  end

  defp with_approval(opts, params) do
    if truthy?(params["yes"]) do
      Keyword.put(opts, :approval, :always_approve)
    else
      opts
    end
  end

  defp with_runtime_progress(opts, params) do
    cond do
      json?(params) ->
        opts

      stream_jsonl?(params) ->
        Keyword.put(opts, :runtime_event_callback, &print_json_event/1)

      true ->
        Keyword.put(opts, :runtime_event_callback, &print_runtime_event/1)
    end
  end

  defp print_run_result(params, run, output, artifact) do
    if stream_jsonl?(params) do
      print_json_event(%{
        "type" => "turn.completed",
        "run_id" => run["id"],
        "status" => run["status"],
        "resumed_from" => run["resumed_from"],
        "artifact" => artifact_summary(artifact)
      })

      print_json_event(%{
        "type" => "run.result",
        "run_id" => run["id"],
        "status" => run["status"],
        "resumed_from" => run["resumed_from"],
        "artifact" => artifact_summary(artifact),
        "output" => output
      })
    else
      IO.puts(output)
      IO.puts("")
      IO.puts("Run: #{run["id"]}")

      if run["resumed_from"] do
        IO.puts("Resumed from: #{run["resumed_from"]}")
      end

      IO.puts("Status: #{run["status"]}")
      if artifact, do: IO.puts("Artifact: #{artifact["path"]}")
    end
  end

  defp print_run_failure(params, run, reason) do
    if stream_jsonl?(params) do
      print_json_event(%{
        "type" => "turn.failed",
        "run_id" => run && run["id"],
        "status" => run && run["status"],
        "reason" => inspect(reason)
      })

      print_json_event(%{
        "type" => "run.failed",
        "run_id" => run && run["id"],
        "status" => run && run["status"],
        "reason" => inspect(reason)
      })
    else
      label =
        case reason do
          :run_not_found -> "No matching run found."
          _ -> "Run failed: #{inspect(reason)}"
        end

      IO.puts(:stderr, label)
      if run, do: IO.puts(:stderr, "Run: #{run["id"]}")
    end
  end

  defp maybe_print_turn_started(params, objective) do
    if stream_jsonl?(params) do
      print_json_event(%{
        "type" => "turn.started",
        "objective" => objective
      })
    end
  end

  defp artifact_summary(nil), do: nil

  defp artifact_summary(artifact) do
    %{
      "path" => artifact["path"],
      "type" => artifact["type"]
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  defp print_json_event(event) do
    event
    |> normalize_json_event()
    |> Enum.reject(fn {_key, value} -> value in [nil, "", %{}, []] end)
    |> Map.new()
    |> Jason.encode!()
    |> IO.puts()
  end

  defp normalize_json_event(%{"type" => "stream_chunk", "content" => content} = event) do
    event
    |> Map.put("type", "answer.delta")
    |> Map.put("content", content)
  end

  defp normalize_json_event(event), do: event

  defp print_runtime_event(%{"type" => "progress." <> _rest, "message" => message})
       when is_binary(message) do
    IO.puts("Progress: #{message}")
  end

  defp print_runtime_event(%{"type" => "tool." <> _rest} = event) do
    case ToolVisibility.render(event) do
      line when is_binary(line) -> IO.puts(line)
      _ -> :ok
    end
  end

  defp print_runtime_event(_event), do: :ok

  defp render_log_event(%{"type" => "progress." <> _rest, "message" => message})
       when is_binary(message) do
    "Progress: #{message}"
  end

  defp render_log_event(%{"type" => "tool." <> _rest} = event), do: ToolVisibility.render(event)

  defp render_log_event(%{"type" => "run.transitioned", "to" => status}) when is_binary(status) do
    "Status: #{status}"
  end

  defp render_log_event(_event), do: nil

  defp maybe_update_provider(providers, opts) do
    provider = opts[:provider]

    if provider in [nil, ""] do
      providers
    else
      provider_config =
        case provider do
          "openai" ->
            %{
              "type" => "openai",
              "model" => opts[:model] || "gpt-5.2",
              "api_key_env" => opts[:api_key_env] || "OPENAI_API_KEY"
            }

          "openrouter" ->
            %{
              "type" => "openrouter",
              "model" => opts[:model] || "openai/gpt-4o-mini",
              "api_key_env" => opts[:api_key_env] || "OPENROUTER_API_KEY",
              "base_url" => opts[:base_url] || "https://openrouter.ai/api/v1",
              "http_referer" => "https://holt.ai",
              "app_title" => "Holt",
              "max_tokens" => 1_200,
              "temperature" => 0.2
            }

          "ollama" ->
            %{
              "type" => "ollama",
              "model" => opts[:model] || "llama3.1",
              "base_url" => opts[:base_url] || "http://127.0.0.1:11434"
            }

          _ ->
            %{"type" => "local", "model" => "local-planner"}
        end

      providers
      |> put_in(["providers", provider], provider_config)
      |> Map.put("default_provider", provider)
    end
  end

  defp format_created([]), do: "none; existing files kept"
  defp format_created(created), do: Enum.join(created, ", ")

  defp maybe_override_model(provider, opts) do
    case opts[:model] do
      nil -> provider
      model -> Map.put(provider, "model", model)
    end
  end

  defp maybe_shrink_smoke_response(%{"type" => type} = provider)
       when type in ["openrouter", "openai", "ollama"] do
    Map.put(provider, "max_tokens", 64)
  end

  defp maybe_shrink_smoke_response(provider), do: provider

  defp run_llm_smoke(provider, opts) do
    prompt = opts[:prompt] || "Reply exactly: Holt LLM smoke test ok."

    case Models.chat(provider, Models.smoke_messages(prompt), opts) do
      {:ok, response} ->
        IO.puts("Provider: #{response["provider"]}")
        IO.puts("Model: #{response["model"]}")
        IO.puts("")
        IO.puts(String.trim(response["content"]))
        0

      {:error, reason} ->
        IO.puts(:stderr, "LLM smoke test failed: #{inspect(reason)}")
        1
    end
  end

  defp maybe_read_key_from_stdin(opts, provider \\ nil) do
    if opts[:api_key_stdin] do
      provider = provider || default_provider(opts)
      env = Map.get(provider, "api_key_env")

      if is_binary(env) and env != "" and System.get_env(env) in [nil, ""] do
        case Holt.Env.read_key_from_stdin(env) do
          :ok ->
            :ok

          {:error, reason} ->
            IO.puts(:stderr, "Could not read #{env} from stdin: #{inspect(reason)}")
        end
      end
    end

    :ok
  end

  defp default_provider(opts) do
    home = Paths.home(opts)
    Config.bootstrap(home: home)
    Models.default_provider(home)
  end

  defp maybe_put_opt(opts, _key, value) when value in [nil, "", []], do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp json?(params), do: truthy?(params["json"])

  defp stream_jsonl?(params), do: params["event_stream"] == "jsonl"

  defp truthy?(value), do: value in [true, "true", "1", 1]

  defp non_empty_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp non_empty_string(_value), do: nil
end
