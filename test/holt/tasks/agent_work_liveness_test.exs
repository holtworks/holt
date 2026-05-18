defmodule Holt.Tasks.AgentWorkLivenessTest do
  use ExUnit.Case, async: true

  alias Holt.Tasks.AgentWorkLiveness

  @now ~U[2026-05-17 12:00:00Z]

  test "marks running work active from canonical last_activity_at" do
    work =
      AgentWorkLiveness.enrich(
        %{"status" => "running", "last_activity_at" => "2026-05-17T11:59:30Z"},
        @now
      )

    assert work["liveness"]["schema_version"] == "agent_work_liveness/v1"
    assert work["liveness"]["status"] == "active"
    assert work["liveness"]["quiet_seconds"] == 30
    assert work["liveness"]["needs_attention"] == false
  end

  test "marks quiet and stalled work by canonical last_activity_at" do
    quiet =
      AgentWorkLiveness.enrich(
        %{"status" => "running", "last_activity_at" => "2026-05-17T11:58:30Z"},
        @now
      )

    stalled =
      AgentWorkLiveness.enrich(
        %{"status" => "running", "last_activity_at" => "2026-05-17T11:54:00Z"},
        @now
      )

    assert quiet["liveness"]["status"] == "quiet"
    assert quiet["liveness"]["needs_attention"] == true
    assert stalled["liveness"]["status"] == "stalled"
    assert stalled["liveness"]["needs_attention"] == true
  end

  test "does not infer activity from legacy timestamp fields" do
    work =
      AgentWorkLiveness.enrich(
        %{
          "status" => "running",
          "started_at" => "2026-05-17T11:50:00Z",
          "queued_at" => "2026-05-17T11:45:00Z",
          "completed_at" => "2026-05-17T11:40:00Z"
        },
        @now
      )

    assert work["liveness"]["status"] == "active"
    assert work["liveness"]["last_activity_at"] == nil
    assert work["liveness"]["quiet_seconds"] == nil
  end

  test "invalid canonical timestamps do not become liveness data" do
    work =
      AgentWorkLiveness.enrich(
        %{"status" => "running", "last_activity_at" => "not-a-date"},
        @now
      )

    assert work["liveness"]["status"] == "active"
    assert work["liveness"]["last_activity_at"] == nil
    assert work["liveness"]["quiet_seconds"] == nil
  end

  test "atom keyed fields do not drive liveness" do
    work =
      AgentWorkLiveness.enrich(
        %{status: "running", last_activity_at: "2026-05-17T11:54:00Z"},
        @now
      )

    assert work["liveness"]["status"] == "inactive"
    assert work["liveness"]["last_activity_at"] == nil
    assert work["liveness"]["quiet_seconds"] == nil
  end
end
