defmodule Holt.Bridge.Stdio.Actions do
  @moduledoc """
  Action catalog and execution stdio requests.
  """

  alias Holt.Bridge.Stdio.{Params, Response}
  alias Holt.Tasks

  def definitions(opts), do: Response.ok(Tasks.action_definitions(opts))

  def search(params, opts), do: Response.ok(Tasks.search_actions(params, opts))

  def catalog(params \\ %{}, opts), do: Response.ok(Tasks.action_catalog(params, opts))

  def agent_definitions(params \\ %{}, opts) do
    Response.ok(Tasks.agent_action_definitions(params, opts))
  end

  def provider_metadata(params \\ %{}, opts) do
    params
    |> Tasks.action_provider_metadata(opts)
    |> catalog_response()
  end

  def provider_prompt_sections(params, opts) do
    params
    |> Tasks.action_provider_prompt_sections(opts)
    |> catalog_response()
  end

  def dispatch(params, opts) do
    with {:ok, name} <- Params.required(params, "action") do
      args = Map.get(params, "arguments", %{})
      context = Map.get(params, "context", %{})
      Response.action(Tasks.dispatch_agent_action(name, args, context, opts))
    else
      {:error, reason} -> Response.error(reason)
    end
  end

  def get(params, opts) do
    with {:ok, name} <- Params.required(params, "action") do
      case Tasks.get_action(name, opts) do
        nil -> Response.message("unknown_action")
        action -> Response.ok(action)
      end
    else
      {:error, reason} -> Response.error(reason)
    end
  end

  def execute(params, opts) do
    with {:ok, name} <- Params.required(params, "action") do
      args = Map.get(params, "arguments", %{})
      Response.action(Tasks.execute_action(name, args, opts))
    else
      {:error, reason} -> Response.error(reason)
    end
  end

  def local_ui(method, params, opts) do
    Response.action(Tasks.execute_action(local_ui_action_name(method), params, opts))
  end

  defp local_ui_action_name("core/ask"), do: "ask"
  defp local_ui_action_name("core/delegate_to_agent"), do: "delegate_to_agent"
  defp local_ui_action_name("core/set_page_title"), do: "set_page_title"
  defp local_ui_action_name("pages/create"), do: "create_page"
  defp local_ui_action_name("documents/write"), do: "write_to_document"
  defp local_ui_action_name(method), do: method

  defp catalog_response({:error, reason}), do: Response.error(reason)
  defp catalog_response(result), do: Response.ok(result)
end
