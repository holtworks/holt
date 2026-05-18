defmodule Holt.Bridge.Stdio.RuntimeInfo do
  @moduledoc """
  Runtime metadata and diagnostic stdio requests.
  """

  alias Holt.AgentRuntime
  alias Holt.Bridge.Stdio.{Params, Response}

  def doctor(params \\ %{}), do: Response.ok(AgentRuntime.doctor(params))

  def action_availability(params \\ %{}) do
    Response.ok(AgentRuntime.action_availability(params))
  end

  def provider_profile(params) do
    with {:ok, model_id} <- provider_model_id(params),
         {:ok, provider} <- provider(params) do
      Response.ok(AgentRuntime.provider_profile(model_id, Map.put(params, "provider", provider)))
    else
      {:error, reason} -> Response.error(reason)
    end
  end

  def safety_policy(params \\ %{}), do: Response.ok(AgentRuntime.safety_policy(params))

  def context_budget(params), do: Response.ok(AgentRuntime.context_budget(params))

  def recovery_contract(params \\ %{}), do: Response.ok(AgentRuntime.recovery_contract(params))

  def run_debugger(params \\ %{}), do: Response.ok(AgentRuntime.run_debugger(params))

  def meta_learning_snapshot(params \\ %{}) do
    Response.ok(AgentRuntime.meta_learning_snapshot(params))
  end

  def format_local_model_result(params) do
    with {:ok, result} <- local_model_result(params) do
      Response.ok(%{"content" => AgentRuntime.format_local_model_result(result)})
    else
      {:error, reason} -> Response.error(reason)
    end
  end

  def agent_loop_contract(params), do: Response.ok(AgentRuntime.agent_loop_contract(params))

  def lifecycle_complete(params) do
    Response.ok(%{"lifecycle_state" => AgentRuntime.agent_run_lifecycle_complete(params)})
  end

  defp provider_model_id(params), do: Params.required(params, "model_id")
  defp provider(params), do: Params.required(params, "provider")
  defp local_model_result(params), do: Params.required(params, "result")
end
