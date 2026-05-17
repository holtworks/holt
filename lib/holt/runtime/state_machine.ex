defmodule Holt.Runtime.StateMachine do
  @moduledoc """
  Structured agent run lifecycle.
  """

  @states ~w(created queued running awaiting_approval awaiting_user completed blocked failed canceled)

  @allowed %{
    nil => ~w(created queued),
    "created" => ~w(queued canceled),
    "queued" => ~w(running canceled),
    "running" => ~w(awaiting_approval awaiting_user completed blocked failed canceled),
    "awaiting_approval" => ~w(running blocked canceled),
    "awaiting_user" => ~w(running canceled),
    "completed" => ~w(completed),
    "blocked" => ~w(blocked),
    "failed" => ~w(queued failed),
    "canceled" => ~w(canceled)
  }

  def states, do: @states

  def terminal?(state), do: normalize(state) in ~w(completed blocked failed canceled)

  def transition(current, next) do
    current = normalize_nullable(current)
    next = normalize(next)

    if next in Map.get(@allowed, current, []) do
      {:ok, next}
    else
      {:error, {:invalid_transition, current, next}}
    end
  end

  def normalize(state) when state in @states, do: state
  def normalize(_state), do: "created"

  defp normalize_nullable(nil), do: nil
  defp normalize_nullable(state), do: normalize(state)
end
