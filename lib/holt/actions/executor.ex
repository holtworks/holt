defmodule Holt.Actions.Executor do
  @moduledoc """
  Action execution boundary.

  The executor owns the runtime-facing API for running actions. Lower-level
  modules may still provide the concrete implementation, but runtime code should
  depend on this boundary rather than on catalog or provider adapters.
  """

  alias Holt.Actions

  def run(name, args \\ %{}, opts \\ []), do: Actions.execute(name, args, opts)

  def run_task(ref_or_id, name, args \\ %{}, opts \\ []) do
    Actions.execute_task_action(ref_or_id, name, args, opts)
  end

  def run_many(ref_or_id, calls, opts \\ []) do
    Actions.execute_many(ref_or_id, calls, opts)
  end

  def dispatch_agent_action(name, params, context \\ %{}, opts \\ []) do
    Actions.dispatch_agent_action(name, params, context, opts)
  end
end
