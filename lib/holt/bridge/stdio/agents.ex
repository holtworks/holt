defmodule Holt.Bridge.Stdio.Agents do
  @moduledoc """
  Agent profile stdio requests.
  """

  alias Holt.Bridge.Stdio.{Params, Response}
  alias Holt.Tasks

  def list(params, opts) do
    status = Map.get(params, "status")

    result =
      opts
      |> Tasks.agents()
      |> filter_status(status)

    Response.ok(result)
  end

  def list(opts), do: Response.ok(Tasks.agents(opts))

  def create(params, opts) do
    case Tasks.create_agent(params, opts) do
      {:ok, agent} -> Response.ok(agent)
      {:error, reason} -> Response.error(reason)
    end
  end

  def show(params, opts) do
    with {:ok, agent_id} <- Params.agent_id(params),
         {:ok, agent} <- Tasks.get_agent(agent_id, opts) do
      Response.ok(agent)
    else
      {:error, reason} -> Response.error(reason)
    end
  end

  def update(params, opts) do
    with {:ok, agent_id} <- Params.agent_id(params),
         {:ok, agent} <- Tasks.update_agent(agent_id, Map.delete(params, "agent_id"), opts) do
      Response.ok(agent)
    else
      {:error, reason} -> Response.error(reason)
    end
  end

  def suspend(params, opts), do: lifecycle(params, opts, &Tasks.suspend_agent/3)

  def resume(params, opts), do: lifecycle(params, opts, &Tasks.resume_agent/3)

  def archive(params, opts), do: lifecycle(params, opts, &Tasks.archive_agent/3)

  def delete(params, opts),
    do: Response.action(Tasks.execute_action("delete_agent", params, opts))

  def invoke(params, opts),
    do: Response.action(Tasks.execute_action("invoke_agent", params, opts))

  def card(params, opts) do
    with {:ok, agent_id} <- Params.agent_id(params),
         {:ok, card} <- Tasks.agent_card(agent_id, opts) do
      Response.ok(card)
    else
      {:error, reason} -> Response.error(reason)
    end
  end

  def cards(params, opts) do
    Response.ok(Tasks.agent_cards(Keyword.merge(opts, status: params["status"])))
  end

  def skills(params, opts) do
    with {:ok, agent_id} <- Params.agent_id(params),
         {:ok, skills} <- Tasks.agent_skills(agent_id, opts) do
      Response.ok(skills)
    else
      {:error, reason} -> Response.error(reason)
    end
  end

  defp lifecycle(params, opts, fun) when is_map(params) do
    with {:ok, agent_id} <- Params.agent_id(params),
         {:ok, agent} <- fun.(agent_id, params, opts) do
      Response.ok(agent)
    else
      {:error, reason} -> Response.error(reason)
    end
  end

  defp filter_status(items, nil), do: items
  defp filter_status(items, ""), do: items
  defp filter_status(items, "all"), do: items
  defp filter_status(items, status), do: Enum.filter(items, &(&1["status"] == status))
end
