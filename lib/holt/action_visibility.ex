defmodule Holt.ActionVisibility do
  @moduledoc """
  Product-facing metadata and summaries for visible Holt action activity.
  """

  alias Holt.Actions.Registry
  alias Holt.{FileDiff, LocalActions}

  @workspace_read ~w(list read search)
  @workspace_write ~w(write append create_page write_to_document set_page_title)
  @command ~w(run run_code run_skill_script)
  @web ~w(fetch search_web)
  @memory ~w(remember recall remember_about_user forget_about_user list_user_memories search_user_memory remember_for_project save_plan save_research recall_project_memory read_project_memory)
  @agent ~w(delegate_to_agent invoke_agent list_agents create_agent update_agent suspend_agent resume_agent delete_agent)
  @user ~w(ask)
  @workspace @workspace_read ++ @workspace_write
  @compact @workspace_read ++ @memory

  def metadata(name, opts \\ []) do
    name = action_name(name)
    local_action = local_action(name)
    action = registered_action(name, opts, local_action)
    risk = action_risk(action)

    %{
      "action" => name,
      "label" => label(name),
      "active_label" => active_label(name),
      "category" => category(name),
      "risk" => risk,
      "approval_required" => action["requires_approval"] == true,
      "visibility" => visibility(name, risk)
    }
  end

  def started(name, args, action_call_id, opts \\ []) do
    meta = name |> metadata(opts) |> maybe_secret_risk(name, args)

    meta
    |> Map.merge(%{
      "action_call_id" => action_call_id,
      "status" => "running",
      "label" => started_label(meta, args),
      "input_summary" => input_summary(name, args)
    })
    |> reject_empty()
  end

  def approval_requested(name, args, action_call_id, opts \\ []) do
    meta = name |> metadata(opts) |> maybe_secret_risk(name, args)
    subject = started_label(meta, args)

    meta
    |> Map.merge(%{
      "action_call_id" => action_call_id,
      "status" => "awaiting_approval",
      "label" => subject,
      "approval_subject" => subject,
      "input_summary" => input_summary(name, args),
      "change_preview" => FileDiff.preview(name, args, opts)
    })
    |> reject_empty()
  end

  def approval_resolved(name, args, action_call_id, decision, opts \\ []) do
    meta = name |> metadata(opts) |> maybe_secret_risk(name, args)
    decision = decision_value(decision)

    meta
    |> Map.merge(%{
      "action_call_id" => action_call_id,
      "status" => decision,
      "label" => approval_label(decision, meta),
      "input_summary" => input_summary(name, args)
    })
    |> reject_empty()
  end

  def completed(name, args, result, action_call_id, opts \\ []) do
    meta = name |> metadata(opts) |> maybe_secret_risk(name, args)

    meta
    |> Map.merge(%{
      "action_call_id" => action_call_id,
      "status" => "completed",
      "label" => completed_label(meta, result),
      "input_summary" => input_summary(name, args),
      "output_summary" => output_summary(name, result)
    })
    |> reject_empty()
  end

  def failed(name, args, reason, action_call_id, opts \\ []) do
    meta = name |> metadata(opts) |> maybe_secret_risk(name, args)

    meta
    |> Map.merge(%{
      "action_call_id" => action_call_id,
      "status" => "failed",
      "label" => "#{meta["label"]} failed",
      "input_summary" => input_summary(name, args),
      "error_summary" => reason_summary(reason)
    })
    |> reject_empty()
  end

  def approval_expected?(name, args, opts \\ []) do
    meta = name |> metadata(opts) |> maybe_secret_risk(name, args)
    meta["approval_required"] == true and opts[:approval] != :always_approve
  end

  def render(%{"type" => "action.started", "label" => label}) do
    "Action: #{label}"
  end

  def render(%{"type" => "action.approval_requested", "approval_subject" => subject}) do
    "Action approval required: #{subject}"
  end

  def render(%{"type" => "action.approval_resolved", "status" => "approved", "label" => label}) do
    "Action: #{label}"
  end

  def render(%{"type" => "action.approval_resolved", "status" => "denied", "label" => label}) do
    "Action: #{label}"
  end

  def render(%{
        "type" => "action.completed",
        "output_summary" => %{
          "path" => path,
          "additions" => additions,
          "deletions" => deletions
        }
      }) do
    "Action: Edited #{path} (+#{additions} -#{deletions})"
  end

  def render(%{"type" => "action.completed", "label" => label} = event) do
    summary =
      event
      |> Map.get("output_summary", %{})
      |> compact_summary()

    ["Action: #{label}", summary]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  def render(%{"type" => "action.failed", "label" => label} = event) do
    reason = get_in(event, ["error_summary", "message"])

    ["Action: #{label}", reason]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  def render(_event), do: nil

  defp risk_from_action(%{"risk_level" => "high"}), do: "execute"
  defp risk_from_action(%{"risk_level" => "medium"}), do: "write"
  defp risk_from_action(%{"risk_level" => "low"}), do: "read"
  defp risk_from_action(_action), do: "read"

  defp action_name(name) when is_binary(name) and name != "", do: name
  defp action_name(_name), do: "unknown_action"

  defp local_action(name) do
    case LocalActions.get(name) do
      nil -> %{}
      action -> action
    end
  end

  defp registered_action(name, opts, local_action) do
    case Registry.get(name, opts) do
      nil -> local_action
      action -> action
    end
  end

  defp action_risk(%{"risk" => risk}) when is_binary(risk) and risk != "", do: risk
  defp action_risk(action), do: risk_from_action(action)

  defp decision_value(decision) when is_binary(decision) and decision != "", do: decision
  defp decision_value(_decision), do: "unknown"

  defp category(name) when name in @workspace, do: "workspace"
  defp category(name) when name in @command, do: "command"
  defp category(name) when name in @web, do: "web"
  defp category(name) when name in @memory, do: "memory"
  defp category(name) when name in @agent, do: "agent"
  defp category(name) when name in @user, do: "user"
  defp category(_name), do: "workflow"

  defp visibility(name, _risk) when name in @compact, do: "compact"
  defp visibility(_name, "read"), do: "compact"
  defp visibility(_name, _risk), do: "expanded"

  defp maybe_secret_risk(meta, "read", %{"path" => path}) do
    if secret_path?(path) do
      meta
      |> Map.put("risk", "secret")
      |> Map.put("approval_required", true)
      |> Map.put("visibility", "expanded")
    else
      meta
    end
  end

  defp maybe_secret_risk(meta, _name, _args), do: meta

  defp label("list"), do: "Read workspace"
  defp label("read"), do: "Read file"
  defp label("search"), do: "Search files"
  defp label("recall"), do: "Search memory"
  defp label("write"), do: "Write file"
  defp label("append"), do: "Update file"
  defp label("run"), do: "Run command"
  defp label("fetch"), do: "Fetch URL"
  defp label("search_web"), do: "Search web"
  defp label("ask"), do: "Ask user"
  defp label("remember"), do: "Save memory"
  defp label("delegate_to_agent"), do: "Delegate work"
  defp label(name), do: name |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp active_label("list"), do: "Reading workspace"
  defp active_label("read"), do: "Reading file"
  defp active_label("search"), do: "Searching files"
  defp active_label("recall"), do: "Searching memory"
  defp active_label("write"), do: "Writing file"
  defp active_label("append"), do: "Updating file"
  defp active_label("run"), do: "Running command"
  defp active_label("fetch"), do: "Fetching URL"
  defp active_label("search_web"), do: "Searching web"
  defp active_label("ask"), do: "Waiting for your input"
  defp active_label("remember"), do: "Saving memory"
  defp active_label("delegate_to_agent"), do: "Delegating work"
  defp active_label(name), do: "Using #{label(name)}"

  defp started_label(%{"action" => "read", "active_label" => active_label}, args) do
    case args["path"] do
      path when path in [nil, ""] -> active_label
      path -> "#{active_label} #{display_path(path)}"
    end
  end

  defp started_label(%{"action" => action, "active_label" => active_label}, args)
       when action in ["write", "append"] do
    case args["path"] do
      path when path in [nil, ""] -> active_label
      path -> "#{active_label} #{display_path(path)}"
    end
  end

  defp started_label(%{"action" => "search", "active_label" => active_label}, args) do
    "#{active_label} #{display_query(args["query"])}"
  end

  defp started_label(%{"action" => "run", "active_label" => active_label}, args) do
    "#{active_label}: #{display_command(args["command"])}"
  end

  defp started_label(%{"action" => "fetch", "active_label" => active_label}, args) do
    "#{active_label}: #{display_url(args["url"])}"
  end

  defp started_label(%{"active_label" => active_label}, _args), do: active_label

  defp completed_label(%{"action" => "read"}, result) do
    "Read #{display_path(result["path"])}"
  end

  defp completed_label(%{"action" => action}, %{"status" => "unchanged"} = result)
       when action in ["write", "append"] do
    "Unchanged #{display_path(result["path"])}"
  end

  defp completed_label(%{"action" => action}, result) when action in ["write", "append"] do
    "Updated #{display_path(result["path"])}"
  end

  defp completed_label(%{"action" => "list"}, _result), do: "Read workspace"
  defp completed_label(%{"action" => "search"}, _result), do: "Searched files"
  defp completed_label(%{"action" => "recall"}, _result), do: "Searched memory"
  defp completed_label(%{"action" => "run"}, _result), do: "Ran command"
  defp completed_label(%{"label" => label}, _result), do: "#{label} completed"

  defp approval_label("approved", meta), do: "Approved #{meta["label"]}"
  defp approval_label("denied", meta), do: "Denied #{meta["label"]}"
  defp approval_label(decision, meta), do: "#{meta["label"]} approval #{decision}"

  defp input_summary(name, args) do
    args = map_args(args)

    %{}
    |> maybe_put("path", path_value(args["path"]))
    |> maybe_put("query", short(args["query"], 120))
    |> maybe_put("command", command_value(name, args["command"]))
    |> maybe_put("url", short(args["url"], 160))
    |> maybe_put("content_bytes", content_bytes(args["content"]))
    |> maybe_put("reason", short(args["reason"], 180))
  end

  defp output_summary(name, %{"result" => %{} = result}), do: output_summary(name, result)

  defp output_summary("list", %{"files" => files}), do: %{"files" => length(files)}

  defp output_summary("read", %{"content" => content}) do
    %{"bytes" => text_bytes(content)}
  end

  defp output_summary(name, %{"matches" => matches})
       when name in ["search", "recall"] do
    %{"matches" => length(matches)}
  end

  defp output_summary(name, %{"path" => path, "bytes" => bytes} = result)
       when name in ["write", "append"] do
    %{
      "path" => path_value(path),
      "bytes" => bytes,
      "additions" => Map.get(result, "additions"),
      "deletions" => Map.get(result, "deletions"),
      "unified_diff" => Map.get(result, "unified_diff"),
      "diff_redacted" => Map.get(result, "diff_redacted"),
      "status" => Map.get(result, "status")
    }
    |> reject_empty()
  end

  defp output_summary("run", %{"exit_code" => exit_code, "output" => output}) do
    %{"exit_code" => exit_code, "output_bytes" => text_bytes(output)}
  end

  defp output_summary(_name, %{"status" => status}), do: %{"status" => status}
  defp output_summary(_name, _result), do: %{}

  defp reason_summary(reason) do
    %{"message" => reason |> inspect() |> short(200)}
  end

  defp compact_summary(summary) when map_size(summary) == 0, do: nil

  defp compact_summary(summary) do
    summary
    |> Enum.map(fn {key, value} -> "#{String.replace(to_string(key), "_", " ")}: #{value}" end)
    |> Enum.join(" · ")
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp map_args(args) when is_map(args), do: args
  defp map_args(_args), do: %{}

  defp content_bytes(nil), do: nil
  defp content_bytes(content), do: byte_size(to_string(content))

  defp text_bytes(value) when is_binary(value), do: byte_size(value)
  defp text_bytes(nil), do: 0
  defp text_bytes(value), do: value |> to_string() |> byte_size()

  defp command_value("run", command), do: short(command, 180)
  defp command_value(_name, _command), do: nil

  defp path_value(nil), do: nil
  defp path_value(path), do: path |> to_string() |> short(180)

  defp secret_path?(path) do
    components =
      path
      |> to_string()
      |> String.downcase()
      |> Path.split()

    basename = List.last(components)

    cond do
      basename in secret_file_names() -> true
      Enum.any?(components, &(&1 in secret_directories())) -> true
      Path.extname(basename) in secret_extensions() -> true
      true -> false
    end
  end

  defp secret_file_names do
    [
      ".env",
      ".env.local",
      ".envrc",
      "id_rsa",
      "id_ed25519",
      "credentials",
      "credentials.json",
      "secrets.json",
      "token",
      "token.json"
    ]
  end

  defp secret_directories, do: [".ssh", ".gnupg", ".aws", ".config"]
  defp secret_extensions, do: [".pem", ".key", ".p12", ".pfx"]

  defp display_path(nil), do: "a file"

  defp display_path(path) do
    case path |> to_string() |> String.trim() do
      "" -> "a file"
      value -> "`#{value}`"
    end
  end

  defp display_query(nil), do: ""
  defp display_query(query), do: ~s("#{short(query, 80)}")

  defp display_command(nil), do: "command"
  defp display_command(command), do: "`#{short(command, 100)}`"

  defp display_url(nil), do: "URL"
  defp display_url(url), do: short(url, 100)

  defp short(nil, _limit), do: nil

  defp short(value, limit) do
    value = to_string(value)

    if String.length(value) > limit do
      String.slice(value, 0, limit) <> "..."
    else
      value
    end
  end

  defp reject_empty(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end
end
