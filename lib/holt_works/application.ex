defmodule HoltWorks.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    maybe_run_cli()

    children = []

    opts = [strategy: :one_for_one, name: HoltWorks.Supervisor]
    Supervisor.start_link(children, opts)
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
