defmodule Holt.Bridge.Stdio.ResponseTest do
  use ExUnit.Case, async: true

  alias Holt.Bridge.Stdio.Response

  test "ok wraps result" do
    assert Response.ok(%{"value" => 1}) == %{"ok" => true, "result" => %{"value" => 1}}
  end

  test "action reports execution reason" do
    assert Response.action({:error, %{"reason" => "blocked", "status" => "error"}}) == %{
             "ok" => false,
             "error" => "blocked",
             "result" => %{"reason" => "blocked", "status" => "error"}
           }
  end

  test "action reports execution status" do
    assert Response.action({:error, %{"status" => "error"}}) == %{
             "ok" => false,
             "error" => "error",
             "result" => %{"status" => "error"}
           }
  end
end
