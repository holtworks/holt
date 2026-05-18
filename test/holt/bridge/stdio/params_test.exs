defmodule Holt.Bridge.Stdio.ParamsTest do
  use ExUnit.Case, async: true

  alias Holt.Bridge.Stdio.Params

  test "required reads the exact string key" do
    assert Params.required(%{"ref" => "HW-1"}, "ref") == {:ok, "HW-1"}
    assert Params.required(%{ref: "HW-1"}, "ref") == {:error, {:missing_required, "ref"}}
  end

  test "task references use ref only" do
    assert Params.task_ref(%{"ref" => "HW-1"}) == {:ok, "HW-1"}
    assert Params.task_ref(%{"task_id" => "HW-1"}) == {:error, {:missing_required, "ref"}}
    assert Params.task_ref(%{"id" => "HW-1"}) == {:error, {:missing_required, "ref"}}
  end

  test "agent references use agent_id only" do
    assert Params.agent_id(%{"agent_id" => "agent-1"}) == {:ok, "agent-1"}
    assert Params.agent_id(%{"id" => "agent-1"}) == {:error, {:missing_required, "agent_id"}}
    assert Params.agent_id(%{"handle" => "agent-1"}) == {:error, {:missing_required, "agent_id"}}
  end

  test "required_map rejects non-map payloads" do
    assert Params.required_map(%{"process" => %{"pid" => 1}}, "process") ==
             {:ok, %{"pid" => 1}}

    assert Params.required_map(%{"process" => "pid-1"}, "process") ==
             {:error, {:missing_required, "process"}}
  end

  test "chat messages require canonical structured role content maps" do
    assert Params.chat_messages(%{
             "chat_messages" => [%{"role" => "user", "content" => "hello"}]
           }) == {:ok, [%{"role" => "user", "content" => "hello"}]}

    assert Params.chat_messages(%{"chat_messages" => [%{role: "user", content: "hello"}]}) ==
             {:error,
              {:invalid_param, "chat_messages",
               "expected a list of maps with string role and content fields"}}
  end

  test "obsolete chat context is explicitly rejected" do
    assert Params.reject_obsolete(
             %{"chat_context" => "user: hello"},
             "chat_context",
             "chat_messages"
           ) ==
             {:error, {:obsolete_param, "chat_context", "chat_messages"}}
  end
end
