defmodule Holt.Bridge.Stdio.RuntimeInfoTest do
  use ExUnit.Case, async: true

  alias Holt.Bridge.Stdio.RuntimeInfo

  test "provider profile requires model_id" do
    assert RuntimeInfo.provider_profile(%{"model" => "local-planner"}) == %{
             "ok" => false,
             "error" => "{:missing_required, \"model_id\"}"
           }
  end

  test "provider profile requires provider" do
    assert RuntimeInfo.provider_profile(%{"model_id" => "local-planner"}) == %{
             "ok" => false,
             "error" => "{:missing_required, \"provider\"}"
           }
  end

  test "provider profile accepts model_id and provider" do
    assert %{"ok" => true, "result" => result} =
             RuntimeInfo.provider_profile(%{"model_id" => "local-planner", "provider" => "local"})

    assert result["model_id"] == "local-planner"
    assert result["provider"] == "local"
  end

  test "local model formatting requires result" do
    assert RuntimeInfo.format_local_model_result(%{"content" => "hello"}) == %{
             "ok" => false,
             "error" => "{:missing_required, \"result\"}"
           }
  end

  test "local model formatting accepts result" do
    assert RuntimeInfo.format_local_model_result(%{"result" => %{"content" => "hello"}}) == %{
             "ok" => true,
             "result" => %{"content" => "hello"}
           }
  end
end
