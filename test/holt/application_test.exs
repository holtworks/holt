defmodule Holt.ApplicationTest do
  use ExUnit.Case, async: true

  test "boot process owns provider registry state" do
    assert Process.whereis(Holt.Boot)
    assert :ets.info(:holt_action_providers, :owner) == Process.whereis(Holt.Boot)
    assert Enum.any?(Holt.Actions.ProviderRegistry.all(), &(&1["id"] == "workspace"))
  end
end
