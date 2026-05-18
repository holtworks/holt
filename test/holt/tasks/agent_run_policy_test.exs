defmodule Holt.Tasks.AgentRunPolicyTest do
  use ExUnit.Case, async: true

  alias Holt.Tasks.AgentRunPolicy

  test "builds policy from canonical work policy" do
    policy =
      AgentRunPolicy.for_task(
        %{"kind" => "task", "estimate" => 3},
        %{
          "policy" => %{
            "auto_continue" => true,
            "continuation_allowed" => true,
            "retry_on_failure" => true,
            "max_continuation_depth" => 5,
            "source" => "agent_work_policy"
          }
        }
      )

    assert policy["schema_version"] == "holt_agent_run_policy/v1"
    assert policy["auto_continue"] == true
    assert policy["continuation_allowed"] == true
    assert policy["retry_on_failure"] == true
    assert policy["max_continuation_depth"] == 5
    assert policy["source"] == "agent_work_policy"
  end

  test "does not fall back to task agent_policy" do
    policy =
      AgentRunPolicy.for_task(
        %{
          "kind" => "task",
          "agent_policy" => %{
            "auto_continue" => true,
            "continuation_allowed" => true,
            "max_continuation_depth" => 9
          }
        },
        %{}
      )

    assert policy["auto_continue"] == false
    assert policy["continuation_allowed"] == false
    assert policy["max_continuation_depth"] == 1
  end

  test "does not infer continuation_allowed from auto_continue" do
    policy =
      AgentRunPolicy.for_task(
        %{"kind" => "task"},
        %{"policy" => %{"auto_continue" => true}}
      )

    assert policy["auto_continue"] == true
    assert policy["continuation_allowed"] == false
  end

  test "ignores string and atom-shaped policy values" do
    string_policy =
      AgentRunPolicy.for_task(
        %{"kind" => "task"},
        %{
          "policy" => %{
            "auto_continue" => "true",
            "continuation_allowed" => "true",
            "retry_on_failure" => "true",
            "max_continuation_depth" => "4"
          }
        }
      )

    assert string_policy["auto_continue"] == false
    assert string_policy["continuation_allowed"] == false
    assert string_policy["retry_on_failure"] == false
    assert string_policy["max_continuation_depth"] == 1

    atom_policy =
      AgentRunPolicy.for_task(
        %{"kind" => "task"},
        %{
          "policy" => %{
            auto_continue: true,
            continuation_allowed: true,
            retry_on_failure: true,
            max_continuation_depth: 4
          }
        }
      )

    assert atom_policy["auto_continue"] == false
    assert atom_policy["continuation_allowed"] == false
    assert atom_policy["retry_on_failure"] == false
    assert atom_policy["max_continuation_depth"] == 1
  end
end
