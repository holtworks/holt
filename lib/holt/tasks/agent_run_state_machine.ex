defmodule Holt.Tasks.AgentRunStateMachine do
  @moduledoc """
  Typed lifecycle state machine for file-backed task-agent runs.
  """

  @states ~w(queued running awaiting_verification needs_continuation recovery_queued completed blocked failed canceled)
  @terminal_states ~w(completed blocked failed canceled)

  @allowed_transitions %{
    nil =>
      ~w(queued running awaiting_verification needs_continuation recovery_queued completed blocked failed canceled),
    "queued" =>
      ~w(queued running awaiting_verification needs_continuation recovery_queued completed blocked failed canceled),
    "running" =>
      ~w(running awaiting_verification needs_continuation recovery_queued completed blocked failed canceled),
    "awaiting_verification" =>
      ~w(awaiting_verification needs_continuation recovery_queued completed blocked failed canceled),
    "needs_continuation" =>
      ~w(needs_continuation queued running recovery_queued completed blocked failed canceled),
    "recovery_queued" =>
      ~w(recovery_queued queued running needs_continuation completed blocked failed canceled),
    "completed" => ~w(completed),
    "blocked" => ~w(blocked),
    "failed" => ~w(failed),
    "canceled" => ~w(canceled)
  }

  def states, do: @states
  def terminal_states, do: @terminal_states
  def queued, do: "queued"
  def running, do: "running"

  def terminal?(state), do: state in @terminal_states

  def transition(current_state, next_state) do
    with {:ok, current} <- nullable_state(current_state),
         {:ok, next} <- state(next_state) do
      if next in Map.fetch!(@allowed_transitions, current) do
        {:ok, next}
      else
        {:error, {:invalid_agent_run_transition, current, next}}
      end
    end
  end

  def complete(attrs) when is_map(attrs) do
    status = text_field(attrs, "status")
    verification_gate = map_field(attrs, "verification_gate")
    decision = map_field(attrs, "continuation_decision")
    decision_action = text_field(decision, "action")
    gate_status = text_field(verification_gate, "status")

    cond do
      status == "canceled" ->
        "canceled"

      decision_action == "continue" ->
        "needs_continuation"

      decision_action == "suppress" ->
        "blocked"

      status in ["failed", "blocked"] ->
        "blocked"

      gate_status in ["submitted", "not_required"] ->
        "completed"

      gate_status == "blocked" ->
        "blocked"

      gate_status == "required" ->
        "awaiting_verification"

      decision_action == "stop" ->
        "completed"

      status == "success" ->
        "awaiting_verification"

      true ->
        "completed"
    end
  end

  def complete(_attrs), do: "completed"

  defp nullable_state(nil), do: {:ok, nil}
  defp nullable_state(state), do: state(state)

  defp state(state) when state in @states, do: {:ok, state}
  defp state(state), do: {:error, {:invalid_agent_run_state, state}}

  defp map_field(map, key) do
    case Map.get(map, key) do
      value when is_map(value) -> canonical_map(value)
      _value -> %{}
    end
  end

  defp canonical_map(value) when is_map(value) do
    case Enum.all?(value, fn {key, _nested} -> is_binary(key) end) do
      true -> value
      false -> %{}
    end
  end

  defp text_field(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) -> String.trim(value)
      _value -> nil
    end
  end
end
