defmodule Holt.ToolVisibility do
  @moduledoc """
  Product-facing metadata and summaries for visible Holt tool activity.
  """

  alias Holt.{Actions, Tools}

  @workspace_read ~w(list_files read_file search_files)
  @workspace_write ~w(write_file append_file create_page write_to_document set_page_title)
  @command ~w(run_command run_code run_skill_script)
  @web ~w(fetch_url search_web)
  @memory ~w(save_memory search_memory remember_about_user forget_about_user list_user_memories search_user_memory remember_for_project save_plan save_research recall_project_memory read_project_memory)
  @agent ~w(delegate_to_agent invoke_agent list_agents create_agent update_agent suspend_agent resume_agent delete_agent)
  @user ~w(ask_user ask_user_question)

  def metadata(name, opts \\ []) do
    name = to_string(name || "unknown_tool")
    tool = Tools.get(name) || %{}
    action = Actions.get(name, opts) || %{}

    risk = tool["risk"] || risk_from_action(action)
    requires_approval = tool["requires_approval"] == true or action["requires_approval"] == true

    %{
      "tool" => name,
      "label" => label(name),
      "active_label" => active_label(name),
      "category" => category(name),
      "risk" => risk || "read",
      "approval_required" => requires_approval,
      "visibility" => visibility(name, risk)
    }
  end

  def started(name, args, tool_call_id, opts \\ []) do
    meta = name |> metadata(opts) |> maybe_secret_risk(name, args)

    meta
    |> Map.merge(%{
      "tool_call_id" => tool_call_id,
      "status" => "running",
      "label" => started_label(meta, args),
      "input_summary" => input_summary(name, args)
    })
    |> reject_empty()
  end

  def approval_requested(name, args, tool_call_id, opts \\ []) do
    meta = name |> metadata(opts) |> maybe_secret_risk(name, args)

    meta
    |> Map.merge(%{
      "tool_call_id" => tool_call_id,
      "status" => "awaiting_approval",
      "label" => "Waiting for approval: #{started_label(meta, args)}",
      "input_summary" => input_summary(name, args)
    })
    |> reject_empty()
  end

  def approval_resolved(name, args, tool_call_id, decision, opts \\ []) do
    meta = name |> metadata(opts) |> maybe_secret_risk(name, args)
    decision = to_string(decision || "unknown")

    meta
    |> Map.merge(%{
      "tool_call_id" => tool_call_id,
      "status" => decision,
      "label" => approval_label(decision, meta),
      "input_summary" => input_summary(name, args)
    })
    |> reject_empty()
  end

  def completed(name, args, result, tool_call_id, opts \\ []) do
    meta = name |> metadata(opts) |> maybe_secret_risk(name, args)

    meta
    |> Map.merge(%{
      "tool_call_id" => tool_call_id,
      "status" => "completed",
      "label" => completed_label(meta, result),
      "input_summary" => input_summary(name, args),
      "output_summary" => output_summary(name, result)
    })
    |> reject_empty()
  end

  def failed(name, args, reason, tool_call_id, opts \\ []) do
    meta = name |> metadata(opts) |> maybe_secret_risk(name, args)

    meta
    |> Map.merge(%{
      "tool_call_id" => tool_call_id,
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

  def render(%{"type" => "tool.started", "label" => label}) do
    "Tool: #{label}"
  end

  def render(%{"type" => "tool.approval_requested", "label" => label}) do
    "Tool: #{label}"
  end

  def render(%{"type" => "tool.approval_resolved", "status" => "approved", "label" => label}) do
    "Tool: #{label}"
  end

  def render(%{"type" => "tool.approval_resolved", "status" => "denied", "label" => label}) do
    "Tool: #{label}"
  end

  def render(%{"type" => "tool.completed", "label" => label} = event) do
    summary =
      event
      |> Map.get("output_summary", %{})
      |> compact_summary()

    ["Tool: #{label}", summary]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  def render(%{"type" => "tool.failed", "label" => label} = event) do
    reason = get_in(event, ["error_summary", "message"])

    ["Tool: #{label}", reason]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  def render(_event), do: nil

  defp risk_from_action(%{"risk_level" => "high"}), do: "execute"
  defp risk_from_action(%{"risk_level" => "medium"}), do: "write"
  defp risk_from_action(%{"risk_level" => "low"}), do: "read"
  defp risk_from_action(_action), do: "read"

  defp category(name) when name in @workspace_read or name in @workspace_write, do: "workspace"
  defp category(name) when name in @command, do: "command"
  defp category(name) when name in @web, do: "web"
  defp category(name) when name in @memory, do: "memory"
  defp category(name) when name in @agent, do: "agent"
  defp category(name) when name in @user, do: "user"
  defp category(_name), do: "workflow"

  defp visibility(name, _risk) when name in @workspace_read or name in @memory, do: "compact"
  defp visibility(_name, "read"), do: "compact"
  defp visibility(_name, _risk), do: "expanded"

  defp maybe_secret_risk(meta, "read_file", %{"path" => path}) do
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

  defp label("list_files"), do: "Read workspace"
  defp label("read_file"), do: "Read file"
  defp label("search_files"), do: "Search files"
  defp label("search_memory"), do: "Search memory"
  defp label("write_file"), do: "Write file"
  defp label("append_file"), do: "Update file"
  defp label("run_command"), do: "Run command"
  defp label("fetch_url"), do: "Fetch URL"
  defp label("search_web"), do: "Search web"
  defp label("ask_user"), do: "Ask user"
  defp label("ask_user_question"), do: "Ask user"
  defp label("save_memory"), do: "Save memory"
  defp label("delegate_to_agent"), do: "Delegate work"
  defp label(name), do: name |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp active_label("list_files"), do: "Reading workspace"
  defp active_label("read_file"), do: "Reading file"
  defp active_label("search_files"), do: "Searching files"
  defp active_label("search_memory"), do: "Searching memory"
  defp active_label("write_file"), do: "Writing file"
  defp active_label("append_file"), do: "Updating file"
  defp active_label("run_command"), do: "Running command"
  defp active_label("fetch_url"), do: "Fetching URL"
  defp active_label("search_web"), do: "Searching web"
  defp active_label("ask_user"), do: "Waiting for your input"
  defp active_label("ask_user_question"), do: "Waiting for your input"
  defp active_label("save_memory"), do: "Saving memory"
  defp active_label("delegate_to_agent"), do: "Delegating work"
  defp active_label(name), do: "Using #{label(name)}"

  defp started_label(%{"tool" => "read_file", "active_label" => active_label}, args) do
    "#{active_label} #{display_path(args["path"])}"
  end

  defp started_label(%{"tool" => tool, "active_label" => active_label}, args)
       when tool in ["write_file", "append_file"] do
    "#{active_label} #{display_path(args["path"])}"
  end

  defp started_label(%{"tool" => "search_files", "active_label" => active_label}, args) do
    "#{active_label} #{display_query(args["query"])}"
  end

  defp started_label(%{"tool" => "run_command", "active_label" => active_label}, args) do
    "#{active_label}: #{display_command(args["command"])}"
  end

  defp started_label(%{"tool" => "fetch_url", "active_label" => active_label}, args) do
    "#{active_label}: #{display_url(args["url"])}"
  end

  defp started_label(%{"active_label" => active_label}, _args), do: active_label

  defp completed_label(%{"tool" => "read_file"}, result) do
    "Read #{display_path(result["path"])}"
  end

  defp completed_label(%{"tool" => tool}, result) when tool in ["write_file", "append_file"] do
    "Updated #{display_path(result["path"])}"
  end

  defp completed_label(%{"tool" => "list_files"}, _result), do: "Read workspace"
  defp completed_label(%{"tool" => "search_files"}, _result), do: "Searched files"
  defp completed_label(%{"tool" => "search_memory"}, _result), do: "Searched memory"
  defp completed_label(%{"tool" => "run_command"}, _result), do: "Ran command"
  defp completed_label(%{"label" => label}, _result), do: "#{label} completed"

  defp approval_label("approved", meta), do: "Approved #{meta["label"]}"
  defp approval_label("denied", meta), do: "Denied #{meta["label"]}"
  defp approval_label(decision, meta), do: "#{meta["label"]} approval #{decision}"

  defp input_summary(name, args) do
    args = args || %{}

    %{}
    |> maybe_put("path", path_value(args["path"]))
    |> maybe_put("query", short(args["query"], 120))
    |> maybe_put("command", command_value(name, args["command"]))
    |> maybe_put("url", short(args["url"], 160))
    |> maybe_put("content_bytes", content_bytes(args["content"]))
    |> maybe_put("reason", short(args["reason"], 180))
  end

  defp output_summary("list_files", %{"files" => files}), do: %{"files" => length(files)}

  defp output_summary("read_file", %{"content" => content}) do
    %{"bytes" => byte_size(to_string(content || ""))}
  end

  defp output_summary(name, %{"matches" => matches})
       when name in ["search_files", "search_memory"] do
    %{"matches" => length(matches)}
  end

  defp output_summary(name, %{"path" => path, "bytes" => bytes})
       when name in ["write_file", "append_file"] do
    %{"path" => path_value(path), "bytes" => bytes}
  end

  defp output_summary("run_command", %{"exit_code" => exit_code, "output" => output}) do
    %{"exit_code" => exit_code, "output_bytes" => byte_size(to_string(output || ""))}
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

  defp content_bytes(nil), do: nil
  defp content_bytes(content), do: byte_size(to_string(content))

  defp command_value("run_command", command), do: short(command, 180)
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

    basename in secret_file_names() or
      Enum.any?(components, &(&1 in secret_directories())) or
      Path.extname(basename) in secret_extensions()
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
