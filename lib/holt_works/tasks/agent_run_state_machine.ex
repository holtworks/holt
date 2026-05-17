defmodule HoltWorks.Tasks.AgentRunStateMachine do
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

  def terminal?(state), do: normalize_state(state) in @terminal_states

  def transition(current_state, next_state) do
    current = normalize_nullable_state(current_state)
    next = normalize_state(next_state)

    if next in Map.get(@allowed_transitions, current, []) do
      {:ok, next}
    else
      {:error, {:invalid_agent_run_transition, current, next}}
    end
  end

  def complete(attrs) when is_map(attrs) do
    status = value(attrs, "status")
    verification_gate = value(attrs, "verification_gate") || %{}
    decision = value(attrs, "continuation_decision") || value(attrs, "decision") || %{}

    cond do
      status == "canceled" ->
        "canceled"

      decision_action(decision) == "continue" ->
        "needs_continuation"

      decision_action(decision) == "suppress" ->
        "blocked"

      status in ["failed", "blocked"] ->
        "blocked"

      verification_status(verification_gate) in ["submitted", "not_required"] ->
        "completed"

      verification_status(verification_gate) == "blocked" ->
        "blocked"

      verification_status(verification_gate) == "required" ->
        "awaiting_verification"

      decision_action(decision) == "stop" ->
        "completed"

      status == "success" ->
        "awaiting_verification"

      true ->
        "completed"
    end
  end

  def complete(_attrs), do: "completed"

  def normalize_state(state) when state in @states, do: state
  def normalize_state(_state), do: "queued"

  defp normalize_nullable_state(nil), do: nil
  defp normalize_nullable_state(state), do: normalize_state(state)

  defp verification_status(gate) when is_map(gate), do: value(gate, "status")
  defp verification_status(_gate), do: nil

  defp decision_action(%{"action" => action}), do: action
  defp decision_action(%{action: action}), do: action
  defp decision_action(:ignore), do: "ignore"
  defp decision_action({:continue, _data}), do: "continue"
  defp decision_action({:suppress, _data}), do: "suppress"
  defp decision_action({:stop, _data}), do: "stop"
  defp decision_action(_decision), do: nil

  defp value(map, key) when is_map(map) do
    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, atom_key(key)) -> Map.get(map, atom_key(key))
      true -> nil
    end
  end

  defp value(_map, _key), do: nil

  defp atom_key("status"), do: :status
  defp atom_key("verification_gate"), do: :verification_gate
  defp atom_key("continuation_decision"), do: :continuation_decision
  defp atom_key("decision"), do: :decision
  defp atom_key(_key), do: :unknown
end
