defmodule Holt.Bridge.Stdio.Sessions do
  @moduledoc """
  Agent session and session-event stdio requests.
  """

  alias Holt.Bridge.Stdio.{Params, Response}
  alias Holt.Runtime.{AgentEvents, Session}

  def start(params, opts) do
    with {:ok, objective} <- Params.required(params, "objective"),
         :ok <- Params.reject_obsolete(params, "chat_context", "chat_messages"),
         :ok <- Params.reject_obsolete(params, "agent", "agent_id"),
         {:ok, chat_messages} <- Params.chat_messages(params) do
      case Session.start(objective, start_opts(params, opts, chat_messages)) do
        {:ok, session} -> Response.ok(session)
        {:error, reason} -> Response.error(reason)
      end
    else
      {:error, reason} -> Response.error(reason)
    end
  end

  def status(params, opts) do
    with {:ok, session_id} <- Params.required(params, "session_id") do
      case Session.status(session_id, query_opts(params, opts)) do
        {:ok, session} -> Response.ok(session)
        {:error, reason} -> Response.error(reason)
      end
    else
      {:error, reason} -> Response.error(reason)
    end
  end

  def respond(params, opts) do
    with {:ok, session_id} <- Params.required(params, "session_id"),
         {:ok, answer} <- Params.required(params, "answer") do
      case Session.respond(session_id, answer, query_opts(params, opts)) do
        {:ok, session} -> Response.ok(session)
        {:error, reason} -> Response.error(reason)
      end
    else
      {:error, reason} -> Response.error(reason)
    end
  end

  def list(params, opts), do: Response.ok(Session.list(query_opts(params, opts)))

  def list(opts), do: Response.ok(Session.list(opts))

  def events(params, opts) do
    with {:ok, session_id} <- Params.required(params, "session_id") do
      case AgentEvents.list_by_session(session_id, event_opts(params, opts)) do
        {:ok, events} -> Response.ok(events)
        {:error, reason} -> Response.error(reason)
      end
    else
      {:error, reason} -> Response.error(reason)
    end
  end

  def summary(params, opts) do
    with {:ok, session_id} <- Params.required(params, "session_id") do
      case AgentEvents.get_session_summary(session_id, event_opts(params, opts)) do
        {:ok, summary} -> Response.ok(summary)
        {:error, reason} -> Response.error(reason)
      end
    else
      {:error, reason} -> Response.error(reason)
    end
  end

  def tree(params, opts) do
    with {:ok, session_id} <- Params.required(params, "session_id") do
      case AgentEvents.get_session_tree(session_id, event_opts(params, opts)) do
        {:ok, tree} -> Response.ok(tree)
        {:error, reason} -> Response.error(reason)
      end
    else
      {:error, reason} -> Response.error(reason)
    end
  end

  defp start_opts(params, opts, chat_messages) do
    opts
    |> maybe_put(:agent_id, params["agent_id"])
    |> maybe_put(:mode, params["mode"])
    |> maybe_put(:yes, params["yes"])
    |> maybe_put(:approval_mode, approval_mode(params["approval_mode"]))
    |> maybe_put(:chat_messages, chat_messages)
  end

  defp query_opts(params, opts) do
    opts
    |> maybe_put(:limit, params["limit"])
    |> maybe_put(:include_events, params["include_events"])
  end

  defp event_opts(params, opts) do
    opts
    |> maybe_put(:limit, params["limit"])
    |> maybe_put(:since_sequence, params["since_sequence"])
  end

  defp approval_mode("always_approve"), do: :always_approve
  defp approval_mode("always_deny"), do: :always_deny
  defp approval_mode(value) when value in [nil, ""], do: nil
  defp approval_mode(value), do: value

  defp maybe_put(opts, _key, value) when value in [nil, ""], do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
