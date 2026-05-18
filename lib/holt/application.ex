defmodule Holt.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Holt.Boot,
      Holt.Gateway,
      {DynamicSupervisor, strategy: :one_for_one, name: Holt.Runtime.RunSupervisor},
      {Registry, keys: :unique, name: Holt.Runtime.SessionRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: Holt.Runtime.SessionSupervisor},
      {Task.Supervisor, name: Holt.Runtime.SessionTaskSupervisor},
      Holt.Tasks.ProcessWakeScheduler
    ]

    opts = [strategy: :one_for_one, name: Holt.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
