defmodule HoltWorksTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  test "greets the world" do
    assert HoltWorks.version() == "0.1.0"
  end

  test "cli help succeeds" do
    output =
      capture_io(fn ->
        assert HoltWorks.CLI.main(["help"]) == 0
      end)

    assert output =~ "Usage:"
  end

  test "unknown cli command returns usage error" do
    output =
      capture_io(:stderr, fn ->
        assert HoltWorks.CLI.main(["nope"]) == 64
      end)

    assert output =~ "Unknown command: nope"
  end
end
