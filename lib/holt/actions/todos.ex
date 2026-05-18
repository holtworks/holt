defmodule Holt.Actions.Todos do
  @moduledoc """
  Session-local todo actions.

  Todos are action-session state, not durable task records. This module owns the
  small schema and validation rules for reading and replacing that state.
  """

  @schema_version "holt_todo_state/v1"
  @statuses ~w(pending in_progress completed)

  def read(args) when is_map(args) do
    args
    |> read_source()
    |> normalize_read_todos()
    |> state("read")
  end

  def read(_args), do: state([], "read")

  def write(args) when is_map(args) do
    action_args = action_args(args)

    case Map.get(action_args, "todos") do
      nil -> {:error, "todos is required."}
      todos when is_list(todos) -> write_todos(todos)
      _value -> {:error, "todos must be an array."}
    end
  end

  def write(_args), do: {:error, "todos must be an array."}

  defp write_todos(todos) do
    todos
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case normalize_write_todo(item) do
        {:ok, todo} -> {:cont, {:ok, [todo | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, state(Enum.reverse(reversed), "updated")}
      {:error, reason} -> {:error, reason}
    end
  end

  defp state(todos, action) do
    %{
      "schema_version" => @schema_version,
      "action" => action,
      "status" => if(action == "read", do: "read", else: "updated"),
      "count" => length(todos),
      "text" => format(todos),
      "todos" => todos
    }
  end

  defp read_source(args) do
    action_args = action_args(args)

    cond do
      is_list(Map.get(action_args, "todos")) ->
        Map.get(action_args, "todos")

      is_list(get_in(args, ["action_session", "todos"])) ->
        get_in(args, ["action_session", "todos"])

      is_list(get_in(args, ["session", "todos"])) ->
        get_in(args, ["session", "todos"])

      true ->
        []
    end
  end

  defp normalize_read_todos(value) when is_list(value) do
    value
    |> Enum.map(&normalize_read_todo/1)
    |> Enum.reject(&(&1 == %{}))
  end

  defp normalize_read_todos(_value), do: []

  defp normalize_read_todo(value) when is_map(value) do
    todo = string_keyed_map(value)
    content = text(todo, "content")

    if content in [nil, ""] do
      %{}
    else
      active_form =
        text(
          todo,
          "activeForm",
          text(todo, "active_form", content)
        )

      %{
        "content" => content,
        "status" => todo_status(text(todo, "status", "pending")),
        "activeForm" => active_form,
        "active_form" => active_form
      }
      |> reject_empty()
    end
  end

  defp normalize_read_todo(value) do
    content = value |> to_string() |> String.trim()

    if content == "" do
      %{}
    else
      %{
        "content" => content,
        "status" => "pending",
        "activeForm" => content,
        "active_form" => content
      }
    end
  end

  defp normalize_write_todo(value) when is_map(value) do
    todo = string_keyed_map(value)
    content = text(todo, "content")
    status = text(todo, "status", "pending")

    active_form =
      text(
        todo,
        "activeForm",
        text(todo, "active_form", content)
      )

    cond do
      content in [nil, ""] ->
        {:error, "Each todo needs a non-empty `content` string."}

      status not in @statuses ->
        {:error, "Invalid todo status #{inspect(status)}."}

      true ->
        {:ok,
         %{
           "content" => content,
           "status" => status,
           "activeForm" => active_form,
           "active_form" => active_form
         }}
    end
  end

  defp normalize_write_todo(_value), do: {:error, "Each todo must be an object."}

  defp format([]), do: "(no todos)"

  defp format(todos) do
    Enum.map_join(todos, "\n", fn todo ->
      "- #{status_marker(todo["status"])} #{todo["content"]}"
    end)
  end

  defp status_marker("completed"), do: "[x]"
  defp status_marker("in_progress"), do: "[~]"
  defp status_marker(_status), do: "[ ]"

  defp todo_status(status) when status in @statuses, do: status
  defp todo_status(_status), do: "pending"

  defp action_args(args) do
    case Map.get(args, "arguments") do
      value when is_map(value) ->
        string_keyed_map(value)

      _value ->
        Map.drop(args, [
          "action_session",
          "session",
          "session_id",
          "agent_id",
          "agent_ref",
          "agent_handle",
          "agent_name",
          "run_id",
          "agent_run_id",
          "policy_profile",
          "enabled_action_groups",
          "disabled_action_groups",
          "disabled_actions",
          "direct_actions",
          "preload_actions",
          "connected_accounts",
          "workbench",
          "source"
        ])
    end
  end

  defp string_keyed_map(map) when is_map(map) do
    if Enum.all?(Map.keys(map), &is_binary/1), do: map, else: %{}
  end

  defp text(map, key, default \\ nil) do
    case Map.get(map, key) do
      nil ->
        default

      value when is_binary(value) ->
        value
        |> String.trim()
        |> case do
          "" -> default
          text -> text
        end

      _value ->
        default
    end
  end

  defp reject_empty(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end
end
