defmodule Holt.Tasks.SafetyPolicyTest do
  use ExUnit.Case, async: true

  alias Holt.Tasks.SafetyPolicy

  test "retry policy keeps explicit nonnegative continuation depth" do
    policy =
      SafetyPolicy.build(%{
        "max_attempts" => 3,
        "max_continuation_depth" => 0
      })

    assert policy["retry_policy"]["max_attempts"] == 3
    assert policy["retry_policy"]["max_continuation_depth"] == 0
  end

  test "retry policy rejects invalid numeric fields explicitly" do
    assert SafetyPolicy.build(%{"max_attempts" => 0}) == %{
             "schema_version" => "holt_safety_policy/v1",
             "status" => "rejected",
             "reason" => "invalid_field:max_attempts"
           }

    assert SafetyPolicy.build(%{"max_continuation_depth" => -1}) == %{
             "schema_version" => "holt_safety_policy/v1",
             "status" => "rejected",
             "reason" => "invalid_field:max_continuation_depth"
           }
  end

  test "retry policy rejects string and atom-keyed numeric fields" do
    assert SafetyPolicy.build(%{
             "max_attempts" => "3",
             "max_continuation_depth" => "0"
           }) == %{
             "schema_version" => "holt_safety_policy/v1",
             "status" => "rejected",
             "reason" => "invalid_field:max_attempts"
           }

    assert SafetyPolicy.build(%{
             max_attempts: 3,
             max_continuation_depth: 0
           }) == %{
             "schema_version" => "holt_safety_policy/v1",
             "status" => "rejected",
             "reason" => "invalid_attrs"
           }
  end

  test "rejects invalid task complexity" do
    assert SafetyPolicy.build(%{"task_complexity" => "large"}) == %{
             "schema_version" => "holt_safety_policy/v1",
             "status" => "rejected",
             "reason" => "invalid_field:task_complexity"
           }
  end

  test "rejects non-map attrs" do
    assert SafetyPolicy.build([]) == %{
             "schema_version" => "holt_safety_policy/v1",
             "status" => "rejected",
             "reason" => "invalid_attrs"
           }
  end
end
