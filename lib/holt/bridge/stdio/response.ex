defmodule Holt.Bridge.Stdio.Response do
  @moduledoc """
  JSON response helpers for stdio request handlers.
  """

  def ok(result), do: %{"ok" => true, "result" => result}

  def error(reason), do: %{"ok" => false, "error" => inspect(reason)}

  def message(message), do: %{"ok" => false, "error" => message}

  def action({:ok, result}), do: ok(result)

  def action({:error, %{} = execution}) do
    %{"ok" => false, "error" => execution_error(execution), "result" => execution}
  end

  def action({:error, reason}), do: error(reason)

  defp execution_error(%{"reason" => reason}) when reason not in [nil, ""], do: reason
  defp execution_error(%{"status" => status}) when status not in [nil, ""], do: status
  defp execution_error(_execution), do: "action_failed"
end
