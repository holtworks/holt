defmodule Holt.Bridge.NativeCommand do
  @moduledoc """
  Structured command boundary for the native Holt binary.

  The Rust binary owns terminal command parsing and presentation. This module is
  a small backend adapter that receives already-structured requests and invokes
  Holt runtime services.
  """

  alias Holt.Runtime.{ChatMessages, Runs}
  alias Holt.Bridge.NativePresenter

  alias Holt.{
    Config,
    Models,
    Paths,
    Runtime,
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
      IO.puts("Provider: #{provider_id(provider)}")
      IO.puts("Local service: #{checks["gateway"]["status"]}")
    end

    0
  end

  def run(%{"command" => "model", "params" => params}) do
    opts = command_opts(params)
    Holt.Env.load(opts)
    home = Paths.home(opts)
    Config.bootstrap(home: home)
    provider = configured_provider(home, opts)
    validation = Models.validate(provider)

    status = %{
      "schema_version" => "holt_model_status/v1",
      "provider" => provider_id(provider),
      "type" => provider["type"],
      "model" => provider["model"],
      "api_key_env" => provider["api_key_env"],
      "base_url" => provider["base_url"],
      "valid" => validation == :ok,
      "validation" => format_validation(validation)
    }

    if json?(params) do
      IO.puts(Jason.encode!(reject_empty(status), pretty: true))
    else
      IO.puts("Provider: #{status["provider"]}")
      IO.puts("Type: #{status["type"]}")
      IO.puts("Model: #{model_label(status)}")

      if status["api_key_env"] do
        IO.puts("API key env: #{status["api_key_env"]}")
      end

      if status["base_url"] do
        IO.puts("Base URL: #{status["base_url"]}")
      end

      IO.puts("Validation: #{status["validation"]}")
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
    run_objective_command("run", objective, params)
  end

  def run(%{"command" => "goal", "params" => %{"objective" => objective} = params})
      when is_binary(objective) do
    params = Map.put(params, "runtime_contract", "goal")
    run_objective_command("goal", objective, params)
  end

  def run(%{"command" => "resume", "params" => params}) do
    run_ref = requested_run_ref(params)

    case runtime_opts(params) do
      {:ok, opts} ->
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

      {:error, reason} ->
        print_run_failure(params, nil, reason)
        64
    end
  end

  def run(%{"command" => "fork", "params" => params}) do
    run_ref = requested_run_ref(params)
    objective = non_empty_string(params["objective"])

    case runtime_opts(params) do
      {:ok, opts} ->
        opts = maybe_put_opt(opts, :objective, objective)

        maybe_read_key_from_stdin(opts)
        maybe_print_turn_started(params, fork_started_label(run_ref, objective))

        case Runtime.fork(run_ref, opts) do
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

      {:error, reason} ->
        print_run_failure(params, nil, reason)
        64
    end
  end

  def run(%{"command" => "status", "params" => params}) do
    opts = command_opts(params)
    status = Runtime.status(opts)

    if json?(params) do
      IO.puts(Jason.encode!(status, pretty: true))
    else
      IO.puts("Workspace: #{status["workspace"]}")

      IO.puts("Workspace initialized: #{status["workspace_initialized"]}")

      IO.puts("Local service: #{get_in(status, ["gateway", "status"])}")

      latest = status["latest_run"]

      if latest do
        IO.puts("Latest run: #{latest["id"]} #{latest["status"]}")
      else
        IO.puts("Latest run: none")
      end
    end

    0
  end

  def run(%{"command" => "diff", "params" => params}) do
    opts = command_opts(params)
    root = Paths.workspace_root(opts)

    with {:ok, view} <- diff_view(params),
         {:ok, diff} <- workspace_diff(root) do
      sections = diff_file_sections(diff)
      files = Enum.map(sections, &diff_file_summary/1)

      if json?(params) do
        IO.puts(
          Jason.encode!(
            %{
              "schema_version" => "holt_workspace_diff/v1",
              "workspace" => root,
              "view" => view,
              "files" => files,
              "diff" => diff_payload(view, diff)
            }
            |> reject_empty()
          )
        )
      else
        print_workspace_diff(sections, view)
      end

      0
    else
      {:error, {:unsupported_diff_view, view}} ->
        print_diff_error(params, "unsupported_diff_view", "unsupported diff view: #{view}")
        64

      {:error, reason} ->
        print_diff_error(params, "diff_unavailable", to_string(reason))
        1
    end
  end

  def run(%{"command" => "runs", "params" => params}) do
    opts = command_opts(params)
    root = Paths.workspace_root(opts)
    runs = Enum.map(Runs.list(root), &run_list_summary/1)

    if json?(params) do
      IO.puts(
        Jason.encode!(%{
          "schema_version" => "holt_run_list/v1",
          "runs" => runs
        })
      )
    else
      case runs do
        [] ->
          IO.puts("No runs found.")

        runs ->
          IO.puts("Recent runs")
          Enum.each(runs, &print_run_list_row/1)
      end
    end

    0
  end

  def run(%{"command" => "logs", "params" => params}) do
    opts = command_opts(params)
    root = Paths.workspace_root(opts)
    run_ref = requested_run_ref(params)

    with {:ok, view} <- log_view(params),
         %{"run_dir" => run_dir} = run <- Runs.find(root, run_ref) do
      events = Runs.events(run_dir)
      transcript_entries = Runs.transcript_entries(run_dir)

      if json?(params) do
        print_run_log_json(run, events, transcript_entries, view)
      else
        print_run_log(run, events, transcript_entries, view)
      end

      0
    else
      nil ->
        print_log_error(params, "run_not_found", "Run not found: #{run_ref}", run_ref)
        1

      {:error, {:unsupported_log_view, view}} ->
        print_log_error(params, "unsupported_log_view", "unsupported log view: #{view}", run_ref)
        64
    end
  end

  def run(%{"command" => "llm_test", "params" => params}) do
    opts = command_opts(params)
    Holt.Env.load(opts)
    home = Paths.home(opts)
    Config.bootstrap(home: home)
    provider_id = requested_provider_id(params)

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

  defp run_objective_command(command, objective, params) do
    objective = String.trim(objective)

    if objective == "" do
      IO.puts(:stderr, "Usage: holt #{command} [--yes] \"task\"")
      64
    else
      case runtime_opts(params) do
        {:ok, opts} ->
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

        {:error, reason} ->
          print_run_failure(params, nil, reason)
          64
      end
    end
  end

  defp print_diff_error(params, error, reason) do
    if json?(params) do
      IO.puts(
        Jason.encode!(%{
          "schema_version" => "holt_workspace_diff_error/v1",
          "error" => error,
          "reason" => reason
        })
      )
    else
      case error do
        "unsupported_diff_view" -> IO.puts("Unsupported diff view.")
        "diff_unavailable" -> IO.puts("No git diff available.")
      end

      IO.puts("")
      IO.puts(reason)
    end
  end

  defp diff_view(%{"view" => view}) when view in ["full", "summary"], do: {:ok, view}
  defp diff_view(%{"view" => view}), do: {:error, {:unsupported_diff_view, view}}
  defp diff_view(_params), do: {:ok, "full"}

  defp diff_payload("full", diff), do: diff
  defp diff_payload("summary", _diff), do: nil

  defp decode_request(encoded_request) do
    encoded_request
    |> Base.decode64!()
    |> Jason.decode!()
  end

  defp runtime_opts(params) do
    with :ok <- reject_obsolete_runtime_params(params),
         :ok <- validate_workspace_planning_params(params),
         {:ok, permission_mode} <- permission_mode(params),
         {:ok, chat_messages} <- ChatMessages.decode_param(params["chat_messages"]) do
      opts =
        params
        |> command_opts()
        |> with_permission_mode(permission_mode)
        |> with_runtime_progress(params)
        |> with_await_user_input(params)
        |> maybe_put_opt(:chat_messages, chat_messages)

      {:ok, opts}
    end
  end

  defp validate_workspace_planning_params(params) do
    with :ok <- validate_workspace_persistence_param(params["workspace_persistence"]) do
      validate_workspace_intent_param(params["workspace_intent"])
    end
  end

  defp validate_workspace_persistence_param(nil), do: :ok
  defp validate_workspace_persistence_param("workspace"), do: :ok
  defp validate_workspace_persistence_param("ephemeral"), do: :ok

  defp validate_workspace_persistence_param(value),
    do: {:error, {:unsupported_workspace_persistence, value}}

  defp validate_workspace_intent_param(nil), do: :ok
  defp validate_workspace_intent_param("none"), do: :ok
  defp validate_workspace_intent_param("explore_project"), do: :ok

  defp validate_workspace_intent_param(value),
    do: {:error, {:unsupported_workspace_intent, value}}

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
    |> maybe_put_opt(:runtime_contract, params["runtime_contract"])
    |> maybe_put_opt(:workspace_persistence, params["workspace_persistence"])
    |> maybe_put_opt(:workspace_intent, params["workspace_intent"])
    |> maybe_put_opt(:permission_mode, params["permission_mode"])
    |> maybe_put_opt(:prompt, params["prompt"])
    |> maybe_put_opt(:api_key_stdin, truthy?(params["api_key_stdin"]))
  end

  defp reject_obsolete_runtime_params(params) do
    if Map.has_key?(params, "chat_context") do
      {:error, {:obsolete_param, "chat_context", "chat_messages"}}
    else
      :ok
    end
  end

  defp permission_mode(params) do
    explicit = permission_mode_param(params)
    yes? = truthy?(params["yes"])

    case {explicit, yes?} do
      {{:error, reason}, _yes?} -> {:error, reason}
      {nil, true} -> {:ok, "auto"}
      {nil, false} -> {:ok, "review"}
      {"auto", _yes?} -> {:ok, "auto"}
      {"review", false} -> {:ok, "review"}
      {"deny", false} -> {:ok, "deny"}
      {mode, true} -> {:error, {:conflicting_permission_flags, "permission_mode", mode, "yes"}}
      {mode, false} -> {:error, {:unsupported_permission_mode, mode}}
    end
  end

  defp permission_mode_param(params) do
    case Map.fetch(params, "permission_mode") do
      :error ->
        nil

      {:ok, value} when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      {:ok, value} ->
        {:error, {:invalid_permission_mode, value}}
    end
  end

  defp with_permission_mode(opts, "auto") do
    opts
    |> Keyword.put(:permission_mode, "auto")
    |> Keyword.put(:approval, :always_approve)
  end

  defp with_permission_mode(opts, "deny") do
    opts
    |> Keyword.put(:permission_mode, "deny")
    |> Keyword.put(:approval, :always_deny)
  end

  defp with_permission_mode(opts, "review"), do: Keyword.put(opts, :permission_mode, "review")

  defp with_runtime_progress(opts, params) do
    cond do
      json?(params) ->
        opts

      stream_jsonl?(params) ->
        Keyword.put(opts, :runtime_event_callback, &NativePresenter.print_json_event/1)

      true ->
        Keyword.put(opts, :runtime_event_callback, &NativePresenter.print_runtime_event/1)
    end
  end

  defp with_await_user_input(opts, params) do
    if json?(params) do
      opts
    else
      Keyword.put(opts, :await_user_callback, fn question, metadata ->
        await_user_input(params, question, metadata)
      end)
    end
  end

  defp await_user_input(params, question, metadata) do
    if stream_jsonl?(params) do
      NativePresenter.print_json_event(
        %{
          "type" => "awaiting_user",
          "question" => question,
          "description" => metadata["description"],
          "options" => metadata["options"],
          "action_call_id" => metadata["action_call_id"],
          "turn" => metadata["turn"]
        }
        |> reject_empty()
      )
    else
      IO.puts("")
      IO.puts(question)
      print_question_description(metadata["description"])
      print_question_options(metadata["options"])
      IO.write("› ")
    end

    case IO.gets("") do
      nil -> {:error, :input_closed}
      answer -> {:ok, trim_answer(answer)}
    end
  end

  defp print_question_description(description)
       when is_binary(description) and description != "" do
    IO.puts(description)
  end

  defp print_question_description(_description), do: :ok

  defp print_question_options(options) when is_list(options) do
    options
    |> Enum.with_index(1)
    |> Enum.each(fn {option, index} ->
      label = option["label"]
      description = option["description"]
      suffix = if is_binary(description) and description != "", do: " - #{description}", else: ""
      IO.puts("  #{index}. #{label}#{suffix}")
    end)
  end

  defp print_question_options(_options), do: :ok

  defp workspace_diff(root) do
    with :ok <- ensure_git_workspace(root),
         {:ok, tracked_diff} <- tracked_workspace_diff(root),
         {:ok, untracked_diff} <- untracked_workspace_diff(root) do
      {:ok, join_diffs([tracked_diff, untracked_diff])}
    end
  rescue
    error in ErlangError -> {:error, Exception.message(error)}
  end

  defp ensure_git_workspace(root) do
    case System.cmd("git", ["rev-parse", "--is-inside-work-tree"],
           cd: root,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        if String.trim(output) == "true" do
          :ok
        else
          {:error, String.trim(output)}
        end

      {output, _code} ->
        {:error, String.trim(output)}
    end
  end

  defp tracked_workspace_diff(root) do
    case git_diff(root, ["diff", "--no-ext-diff", "--find-renames", "HEAD", "--", "."]) do
      {:ok, diff} ->
        {:ok, diff}

      {:error, _reason} ->
        with {:ok, cached} <-
               git_diff(root, ["diff", "--cached", "--no-ext-diff", "--find-renames", "--", "."]),
             {:ok, unstaged} <-
               git_diff(root, ["diff", "--no-ext-diff", "--find-renames", "--", "."]) do
          {:ok, join_diffs([cached, unstaged])}
        end
    end
  end

  defp untracked_workspace_diff(root) do
    with {:ok, files} <-
           git_stdout(root, ["ls-files", "--others", "--exclude-standard", "--", "."]) do
      files
      |> String.split("\n", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.reduce_while({:ok, []}, fn path, {:ok, diffs} ->
        case git_diff(root, ["diff", "--no-ext-diff", "--no-index", "--", "/dev/null", path]) do
          {:ok, diff} -> {:cont, {:ok, [diff | diffs]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, diffs} -> {:ok, diffs |> Enum.reverse() |> join_diffs()}
        error -> error
      end
    end
  end

  defp git_stdout(root, args) do
    case System.cmd("git", args, cd: root, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, _code} -> {:error, String.trim(output)}
    end
  end

  defp git_diff(root, args) do
    case System.cmd("git", args, cd: root, stderr_to_stdout: true) do
      {output, code} when code in [0, 1] -> {:ok, output}
      {output, _code} -> {:error, String.trim(output)}
    end
  end

  defp join_diffs(diffs) when is_list(diffs) do
    diffs
    |> Enum.map(&String.trim_trailing/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
    |> maybe_trailing_newline()
  end

  defp maybe_trailing_newline(""), do: ""
  defp maybe_trailing_newline(diff), do: diff <> "\n"

  defp print_workspace_diff([], _view), do: IO.puts("No workspace changes.")

  defp print_workspace_diff(sections, view) do
    IO.puts("Workspace changes")
    IO.puts("")

    Enum.each(sections, fn file ->
      IO.puts(
        "• #{file["label"]} #{diff_section_display_path(file)} (+#{file["additions"]} -#{file["deletions"]})"
      )
    end)

    if view == "full" do
      IO.puts("")

      Enum.each(sections, fn section ->
        IO.puts(
          "### #{section["label"]} #{diff_section_display_path(section)} (+#{section["additions"]} -#{section["deletions"]})"
        )

        IO.puts("")
        IO.puts("```diff")
        IO.write(String.trim_trailing(section["diff"]))
        IO.puts("")
        IO.puts("```")
        IO.puts("")
      end)
    end
  end

  defp diff_file_sections(""), do: []

  defp diff_file_sections(diff) do
    diff
    |> String.split("\ndiff --git ", trim: true)
    |> Enum.map(&normalize_diff_section/1)
    |> Enum.map(&diff_file_section/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_diff_section("diff --git " <> _rest = section), do: section
  defp normalize_diff_section(section), do: "diff --git " <> section

  defp diff_file_section(section) do
    lines = String.split(section, "\n", trim: false)
    path = diff_section_path(lines)
    previous_path = diff_previous_path(lines)

    if path do
      %{
        "path" => path,
        "previous_path" => previous_path,
        "label" => diff_section_label(lines),
        "additions" => Enum.count(lines, &addition_line?/1),
        "deletions" => Enum.count(lines, &deletion_line?/1),
        "diff" => String.trim_trailing(section)
      }
      |> reject_empty()
    end
  end

  defp diff_file_summary(section) do
    Map.take(section, ["path", "previous_path", "label", "additions", "deletions"])
  end

  defp diff_section_display_path(%{
         "label" => "Renamed",
         "previous_path" => previous,
         "path" => path
       })
       when is_binary(previous) and is_binary(path) do
    "#{previous} -> #{path}"
  end

  defp diff_section_display_path(%{"path" => path}), do: path

  defp diff_section_path(lines) do
    [
      fn -> Enum.find_value(lines, &diff_path_from_marker(&1, "+++ b/")) end,
      fn -> diff_current_path(lines) end,
      fn -> Enum.find_value(lines, &diff_path_from_marker(&1, "--- a/")) end,
      fn -> diff_path_from_header(List.first(lines)) end
    ]
    |> Enum.find_value(fn path_source -> path_source.() end)
  end

  defp diff_current_path(lines),
    do: Enum.find_value(lines, &diff_path_from_marker(&1, "rename to "))

  defp diff_previous_path(lines),
    do: Enum.find_value(lines, &diff_path_from_marker(&1, "rename from "))

  defp diff_path_from_marker(line, marker) do
    if String.starts_with?(line, marker) do
      String.replace_prefix(line, marker, "")
    end
  end

  defp diff_path_from_header("diff --git " <> rest) do
    rest
    |> String.split()
    |> Enum.at(1)
    |> strip_diff_prefix("b/")
  end

  defp diff_path_from_header(_line), do: nil

  defp strip_diff_prefix(nil, _prefix), do: nil

  defp strip_diff_prefix(value, prefix) do
    if String.starts_with?(value, prefix) do
      String.replace_prefix(value, prefix, "")
    else
      value
    end
  end

  defp diff_section_label(lines) do
    cond do
      Enum.any?(lines, &(&1 == "--- /dev/null")) -> "Added"
      Enum.any?(lines, &(&1 == "+++ /dev/null")) -> "Deleted"
      Enum.any?(lines, &String.starts_with?(&1, "rename to ")) -> "Renamed"
      true -> "Edited"
    end
  end

  defp addition_line?("+++" <> _rest), do: false
  defp addition_line?("+" <> _rest), do: true
  defp addition_line?(_line), do: false

  defp deletion_line?("---" <> _rest), do: false
  defp deletion_line?("-" <> _rest), do: true
  defp deletion_line?(_line), do: false

  defp trim_answer(answer) when is_binary(answer) do
    answer
    |> String.trim_trailing("\n")
    |> String.trim_trailing("\r")
  end

  defp print_run_result(params, run, output, artifact) do
    if stream_jsonl?(params) do
      NativePresenter.print_json_event(%{
        "type" => "turn.completed",
        "run_id" => run["id"],
        "status" => run["status"],
        "permission_mode" => run["permission_mode"],
        "workspace_persistence" => run["workspace_persistence"],
        "workspace_discovery" => run["workspace_discovery"],
        "resumed_from" => run["resumed_from"],
        "forked_from" => run["forked_from"],
        "artifact" => artifact_summary(artifact)
      })

      NativePresenter.print_json_event(%{
        "type" => "run.result",
        "run_id" => run["id"],
        "status" => run["status"],
        "permission_mode" => run["permission_mode"],
        "workspace_persistence" => run["workspace_persistence"],
        "workspace_discovery" => run["workspace_discovery"],
        "resumed_from" => run["resumed_from"],
        "forked_from" => run["forked_from"],
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

      if run["forked_from"] do
        IO.puts("Forked from: #{run["forked_from"]}")
      end

      if run["permission_mode"] do
        IO.puts("Permissions: #{run["permission_mode"]}")
      end

      if run["workspace_persistence"] do
        IO.puts("Workspace persistence: #{run["workspace_persistence"]}")
      end

      IO.puts("Status: #{run["status"]}")
      if artifact, do: IO.puts("Artifact: #{artifact["path"]}")
    end
  end

  defp print_run_failure(params, run, reason) do
    if stream_jsonl?(params) do
      NativePresenter.print_json_event(%{
        "type" => "turn.failed",
        "run_id" => run && run["id"],
        "status" => run && run["status"],
        "reason" => inspect(reason)
      })

      NativePresenter.print_json_event(%{
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

  defp fork_started_label(run_ref, nil), do: "fork #{run_ref}"
  defp fork_started_label(run_ref, objective), do: "fork #{run_ref}: #{objective}"

  defp print_log_error(params, error, reason, run_ref) do
    if json?(params) do
      IO.puts(
        Jason.encode!(%{
          "schema_version" => "holt_run_log_error/v1",
          "error" => error,
          "run_ref" => run_ref,
          "reason" => reason
        })
      )
    else
      IO.puts(reason)
    end
  end

  defp log_view(%{"view" => view}) when view in ["activity", "transcript"], do: {:ok, view}
  defp log_view(%{"view" => view}), do: {:error, {:unsupported_log_view, view}}
  defp log_view(_params), do: {:ok, "activity"}

  defp print_run_log(run, events, transcript_entries, view) do
    print_run_log_header(run)

    case view do
      "activity" -> print_run_activity(events, transcript_entries)
      "transcript" -> print_transcript(transcript_entries)
    end
  end

  defp print_run_log_header(run) do
    IO.puts("Run: #{run["id"]} #{run["status"]}")
    IO.puts("Objective: #{run["objective"]}")

    if run["artifact"] do
      IO.puts("Artifact: #{run["artifact"]}")
    end

    if run["permission_mode"] do
      IO.puts("Permissions: #{run["permission_mode"]}")
    end

    IO.puts("")
  end

  defp print_run_activity(events, transcript_entries) do
    events
    |> Enum.map(&NativePresenter.render_log_event/1)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> case do
      [] -> IO.puts("No visible activity found.")
      lines -> Enum.each(lines, &IO.puts/1)
    end

    print_approval_audit(events)
    print_latest_assistant_answer(transcript_entries)
  end

  defp print_transcript([]), do: IO.puts("No transcript recorded.")

  defp print_transcript(transcript_entries) do
    IO.puts("Transcript:")

    Enum.each(transcript_entries, fn entry ->
      IO.puts("")
      IO.puts("## #{entry["role"]}")
      IO.puts("")
      IO.puts(entry["content"])
    end)
  end

  defp print_run_log_json(run, events, transcript_entries, view) do
    IO.puts(
      Jason.encode!(%{
        "schema_version" => "holt_run_log/v1",
        "view" => view,
        "run" => run_log_run_summary(run),
        "events" => events,
        "transcript" => transcript_entries,
        "approvals" => approval_audit(events),
        "latest_answer" => latest_assistant_answer(transcript_entries),
        "artifact" => run["artifact"]
      })
    )
  end

  defp run_list_summary(%{"run_dir" => run_dir} = run) do
    %{
      "id" => run["id"],
      "status" => run["status"],
      "objective" => run["objective"],
      "started_at" => run["started_at"],
      "completed_at" => run["completed_at"],
      "resumed_from" => run["resumed_from"],
      "forked_from" => run["forked_from"],
      "runtime_contract" => run["runtime_contract"],
      "workspace_persistence" => run["workspace_persistence"],
      "workspace_discovery" => run["workspace_discovery"],
      "permission_mode" => run["permission_mode"],
      "artifact" => run["artifact"],
      "latest_answer" => latest_assistant_answer(Runs.transcript_entries(run_dir))
    }
    |> reject_empty()
  end

  defp print_run_list_row(run) do
    IO.puts("#{run["id"]} #{run["status"]} #{run["objective"]}")

    if run["artifact"] do
      IO.puts("  artifact: #{run["artifact"]}")
    end

    if run["runtime_contract"] do
      IO.puts("  contract: #{run["runtime_contract"]}")
    end

    if run["permission_mode"] do
      IO.puts("  permissions: #{run["permission_mode"]}")
    end

    if run["workspace_persistence"] do
      IO.puts("  workspace persistence: #{run["workspace_persistence"]}")
    end

    if run["forked_from"] do
      IO.puts("  forked from: #{run["forked_from"]}")
    end

    if run["latest_answer"] do
      IO.puts("  answer: #{one_line(run["latest_answer"])}")
    end
  end

  defp run_log_run_summary(run) do
    run
    |> Map.take([
      "id",
      "status",
      "objective",
      "agent",
      "model",
      "provider",
      "runtime_contract",
      "workspace_persistence",
      "workspace_discovery",
      "pre_task_plan",
      "started_at",
      "completed_at",
      "resumed_from",
      "forked_from",
      "safety_mode",
      "permission_mode",
      "artifact"
    ])
    |> reject_empty()
  end

  defp print_approval_audit(events) do
    case approval_audit(events) do
      [] ->
        :ok

      approvals ->
        IO.puts("")
        IO.puts("Approvals:")
        Enum.each(approvals, &IO.puts("• " <> approval_audit_row(&1)))
    end
  end

  defp approval_audit(events) when is_list(events) do
    requests = Enum.filter(events, &(&1["type"] == "action.approval_requested"))
    resolutions = Enum.filter(events, &(&1["type"] == "action.approval_resolved"))
    requests_by_id = Map.new(requests, &{&1["action_call_id"], &1})
    resolved_ids = MapSet.new(resolutions, & &1["action_call_id"])

    resolved =
      Enum.map(resolutions, fn resolution ->
        approval_audit_entry(resolution, requests_by_id[resolution["action_call_id"]])
      end)

    unresolved =
      requests
      |> Enum.reject(&MapSet.member?(resolved_ids, &1["action_call_id"]))
      |> Enum.map(&approval_audit_entry(&1, &1))

    resolved ++ unresolved
  end

  defp approval_audit_entry(event, request) do
    is_resolution = event["type"] == "action.approval_resolved"

    %{
      "action_call_id" => event["action_call_id"],
      "action" => event["action"],
      "status" => event["status"],
      "label" => event["label"],
      "risk" => event["risk"],
      "requested_at" => approval_request_time(request),
      "resolved_at" => if(is_resolution, do: event["at"]),
      "input_summary" => event["input_summary"]
    }
    |> reject_empty()
  end

  defp approval_request_time(%{"at" => at}), do: at
  defp approval_request_time(_request), do: nil

  defp approval_audit_row(approval) do
    [
      approval["status"],
      approval_label(approval),
      approval_part("action", approval["action"]),
      approval_part("risk", approval["risk"]),
      input_summary_text(approval["input_summary"])
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  defp approval_part(_label, value) when value in [nil, ""], do: nil
  defp approval_part(label, value), do: "#{label}: #{value}"

  defp approval_label(%{"label" => label}) when is_binary(label) and label != "", do: label
  defp approval_label(%{"action" => action}) when is_binary(action) and action != "", do: action
  defp approval_label(_approval), do: nil

  defp input_summary_text(summary) when is_map(summary) do
    summary
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} -> "#{human_key(key)}: #{summary_value(value)}" end)
    |> Enum.join(" · ")
  end

  defp input_summary_text(_summary), do: nil

  defp summary_value(value) when is_binary(value), do: value
  defp summary_value(value) when is_number(value), do: to_string(value)
  defp summary_value(value) when is_boolean(value), do: to_string(value)
  defp summary_value(value), do: Jason.encode!(value)

  defp human_key(key), do: key |> to_string() |> String.replace("_", " ")

  defp print_latest_assistant_answer(transcript_entries) when is_list(transcript_entries) do
    case latest_assistant_answer(transcript_entries) do
      content when is_binary(content) ->
        IO.puts("")
        IO.puts("Answer:")
        IO.puts(content)

      nil ->
        :ok
    end
  end

  defp latest_assistant_answer(transcript_entries) when is_list(transcript_entries) do
    transcript_entries
    |> Enum.reverse()
    |> Enum.find_value(fn entry ->
      if entry["role"] == "assistant" do
        non_empty_string(entry["content"])
      end
    end)
  end

  defp one_line(value) when is_binary(value) do
    value
    |> String.split(~r/\s+/, trim: true)
    |> Enum.join(" ")
  end

  defp maybe_print_turn_started(params, objective) do
    if stream_jsonl?(params) do
      NativePresenter.print_json_event(%{
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
              "model" => provider_config_value(opts, :model, "gpt-5.2"),
              "api_key_env" => provider_config_value(opts, :api_key_env, "OPENAI_API_KEY")
            }

          "openrouter" ->
            %{
              "type" => "openrouter",
              "model" => provider_config_value(opts, :model, "moonshotai/kimi-k2.6"),
              "api_key_env" => provider_config_value(opts, :api_key_env, "OPENROUTER_API_KEY"),
              "base_url" =>
                provider_config_value(opts, :base_url, "https://openrouter.ai/api/v1"),
              "http_referer" => "https://holt.ai",
              "app_title" => "Holt",
              "max_tokens" => 1_200,
              "temperature" => 0.2
            }

          "ollama" ->
            %{
              "type" => "ollama",
              "model" => provider_config_value(opts, :model, "llama3.1"),
              "base_url" => provider_config_value(opts, :base_url, "http://127.0.0.1:11434")
            }

          "local" ->
            %{"type" => "local", "model" => "local-planner"}

          _ ->
            %{"type" => "unknown", "model" => provider}
        end

      providers
      |> put_in(["providers", provider], provider_config)
      |> Map.put("default_provider", provider)
    end
  end

  defp format_created([]), do: "none; existing files kept"
  defp format_created(created), do: Enum.join(created, ", ")

  defp requested_run_ref(params) do
    case non_empty_string(params["run_ref"]) do
      nil -> "latest"
      run_ref -> run_ref
    end
  end

  defp requested_provider_id(params) do
    case non_empty_string(params["provider_id"]) do
      nil -> "openrouter"
      provider_id -> provider_id
    end
  end

  defp provider_id(%{"id" => id}) when is_binary(id) and id != "", do: id

  defp provider_id(provider) do
    raise ArgumentError, "native command provider requires a non-empty id: #{inspect(provider)}"
  end

  defp model_label(%{"model" => model}) when is_binary(model) and model != "", do: model
  defp model_label(_status), do: "not configured"

  defp provider_config_value(opts, key, default) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> value
      _missing -> default
    end
  end

  defp maybe_override_model(provider, opts) do
    case non_empty_string(opts[:model]) do
      nil -> provider
      model -> Map.put(provider, "model", model)
    end
  end

  defp configured_provider(home, opts) do
    provider =
      case opts[:provider] do
        provider_id when is_binary(provider_id) and provider_id != "" ->
          Models.provider(home, provider_id)

        _default ->
          Models.default_provider(home)
      end

    maybe_override_model(provider, opts)
  end

  defp format_validation(:ok), do: "ok"
  defp format_validation({:error, reason}), do: "error: #{inspect(reason)}"
  defp format_validation(reason), do: inspect(reason)

  defp reject_empty(map) when is_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", []] end)
    |> Map.new()
  end

  defp maybe_shrink_smoke_response(%{"type" => type} = provider)
       when type in ["openrouter", "openai", "ollama"] do
    Map.put(provider, "max_tokens", 64)
  end

  defp maybe_shrink_smoke_response(provider), do: provider

  defp run_llm_smoke(provider, opts) do
    prompt = smoke_prompt(opts)

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

  defp smoke_prompt(opts) do
    case non_empty_string(opts[:prompt]) do
      nil -> "Reply exactly: Holt LLM smoke test ok."
      prompt -> prompt
    end
  end

  defp maybe_read_key_from_stdin(opts, provider \\ nil) do
    if opts[:api_key_stdin] do
      provider = provider_for_key_read(opts, provider)
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

  defp provider_for_key_read(opts, nil), do: default_provider(opts)
  defp provider_for_key_read(_opts, provider), do: provider

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
