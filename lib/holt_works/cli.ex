defmodule HoltWorks.CLI do
  @moduledoc """
  Command-line interface for the HoltWorks executable.
  """

  def main(args) when is_list(args) do
    case args do
      [] ->
        help()

      ["help"] ->
        help()

      ["--help"] ->
        help()

      ["-h"] ->
        help()

      ["version"] ->
        IO.puts("HoltWorks #{HoltWorks.version()}")
        0

      ["--version"] ->
        IO.puts(HoltWorks.version())
        0

      ["doctor"] ->
        doctor()

      ["onboard"] ->
        onboard()

      [unknown | _rest] ->
        IO.puts(:stderr, "Unknown command: #{unknown}")
        IO.puts(:stderr, "Run `holtworks help` for usage.")
        64
    end
  end

  def main(_args) do
    IO.puts(:stderr, "Invalid arguments")
    64
  end

  defp help do
    IO.write("""
    HoltWorks #{HoltWorks.version()}

    Usage:
      holtworks help       Show this help
      holtworks version    Print the installed version
      holtworks doctor     Check the local runtime
      holtworks onboard    Start first-run setup

    """)

    0
  end

  defp doctor do
    IO.puts("HoltWorks runtime: ok")
    IO.puts("Elixir app: #{HoltWorks.version()}")
    IO.puts("Standalone binary: #{standalone?()}")
    0
  end

  defp onboard do
    IO.puts("HoltWorks onboarding is ready.")
    IO.puts("Next: configure model providers, device permissions, and workspace access.")
    0
  end

  defp standalone? do
    Code.ensure_loaded?(Burrito.Util) and Burrito.Util.running_standalone?()
  end
end
