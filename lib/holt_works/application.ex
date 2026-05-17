defmodule HoltWorks.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      HoltWorks.Gateway,
      {Registry, keys: :unique, name: HoltWorks.Runtime.SessionRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: HoltWorks.Runtime.SessionSupervisor},
      {Task.Supervisor, name: HoltWorks.Runtime.SessionTaskSupervisor},
      HoltWorks.Tasks.ProcessWakeScheduler
    ]

    opts = [strategy: :one_for_one, name: HoltWorks.Supervisor]
    HoltWorks.Actions.ProviderRegistry.init()
    result = Supervisor.start_link(children, opts)

    maybe_run_cli()

    result
  end

  defp maybe_run_cli do
    if standalone?() do
      spawn(fn ->
        exit_code = HoltWorks.CLI.main(Burrito.Util.Args.argv())
        System.halt(exit_code)
      end)
    end
  end

  defp standalone? do
    Code.ensure_loaded?(Burrito.Util) and Burrito.Util.running_standalone?()
  end
end
