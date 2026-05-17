defmodule Holt.Tasks.AgentRuns do
  @moduledoc """
  File-backed task-agent run ledger.

  Task records keep a compact `agent_work` history for local use. This module is
  the durable workflow ledger: it tracks queued/running/completed states,
  continuation lineage, verification state, and run events in a shape close to
  Inktrail's product-facing agent run history.
  """

  alias Holt.{Clock, JSON, Paths}
  alias Holt.Tasks.{AgentLoop, AgentRunStateMachine, RuntimeContracts}

  @schema_version "holtworks_agent_run/v1"

  def ensure_store(root) do
    Paths.ensure_workspace(root)
    File.mkdir_p!(Paths.tasks_dir(root))
    unless File.exists?(path(root)), do: JSON.write(path(root), [])
    :ok
  end

  def path(root), do: Path.join(Paths.tasks_dir(root), "agent_runs.json")
  def events_path(root), do: Path.join(Paths.tasks_dir(root), "agent_run_events.jsonl")

  def list(opts \\ []) do
    opts
    |> Paths.workspace_root()
    |> list_for_root()
  end

  def list_for_task(task_id, opts \\ []) do
    opts
    |> list()
    |> Enum.filter(&(&1["task_id"] == task_id))
  end

  def record_queued(root, task, work) do
    now = Clock.iso_now()

    record =
      base_record(task, work, now)
      |> Map.merge(%{
        "status" => "queued",
        "lifecycle_state" => AgentRunStateMachine.queued(),
        "runtime_status" => "queued",
        "objective_status" => "unknown",
        "queued_at" => now,
        "heartbeat_at" => now,
        "last_event_at" => now,
        "last_effective_work_at" => nil,
        "agent_loop" => agent_loop_contract(task, work, "queued", "queued", now)
      })
      |> reject_empty()

    upsert(root, record)
    append_event(root, record, "agent_run.queued", "Queued local task-agent work.")
    {:ok, record}
  end

  def record_started(root, task, work) do
    now = Clock.iso_now()

    record =
      existing_or_base(root, task, work, now)
      |> Map.merge(%{
        "status" => "running",
        "lifecycle_state" => AgentRunStateMachine.running(),
        "runtime_status" => "running",
        "objective_status" => "in_progress",
        "started_at" => work["started_at"] || now,
        "heartbeat_at" => now,
        "last_event_at" => now,
        "last_effective_work_at" => now,
        "agent_loop" => agent_loop_contract(task, work, "running", "running", now)
      })
      |> reject_empty()

    upsert(root, record)
    append_event(root, record, "agent_run.started", "Started local task-agent work.")
    {:ok, record}
  end

  def record_completed(root, task, work, run, attrs \\ %{}) do
    now = Clock.iso_now()
    status = completion_status(run["status"])
    lifecycle_state = lifecycle_state(status, attrs)
    objective_status = objective_status(lifecycle_state, attrs)

    record =
      existing_or_base(root, task, work, now)
      |> Map.merge(%{
        "status" => status,
        "lifecycle_state" => lifecycle_state,
        "runtime_status" => run["status"],
        "objective_status" => objective_status,
        "task_complexity" => task_complexity(attrs),
        "classification" => Map.get(attrs, "classification", %{}),
        "policy" => Map.get(attrs, "policy", %{}),
        "failure_class" => failure_class(attrs),
        "blocker_code" => blocker_code(attrs),
        "failure_retryable" => failure_retryable(attrs),
        "run_id" => run["id"],
        "run_dir" => run["run_dir"],
        "model" => run["model"],
        "completed_at" => now,
        "heartbeat_at" => now,
        "last_event_at" => now,
        "last_effective_work_at" => now,
        "verification_gate" => Map.get(attrs, "verification_gate", %{}),
        "continuation_decision" => Map.get(attrs, "continuation_decision", %{}),
        "agent_loop" => agent_loop_contract(task, work, lifecycle_state, status, now, attrs),
        "output_summary" => Map.get(attrs, "output_summary"),
        "error_message" => Map.get(attrs, "error_message")
      })
      |> reject_empty()

    upsert(root, record)
    append_event(root, record, event_kind(status), "Completed local task-agent work.")
    maybe_append_decision_event(root, record)
    {:ok, record}
  end

  def record_verification(root, task, report) do
    latest =
      root
      |> list_for_root()
      |> Enum.filter(&(&1["task_id"] == task["id"]))
      |> Enum.reverse()
      |> Enum.find(&(&1["lifecycle_state"] in ["awaiting_verification", "needs_continuation"]))

    if latest do
      record =
        latest
        |> Map.put("verification_gate", report)
        |> Map.put("objective_status", verification_objective_status(report))
        |> Map.put("lifecycle_state", verification_lifecycle_state(report))
        |> Map.put("updated_at", Clock.iso_now())

      upsert(root, record)
      append_event(root, record, "agent_run.verification_routed", "Verification routed.")
      {:ok, record}
    else
      {:ok, nil}
    end
  end

  def event_log(root), do: JSON.read_jsonl(events_path(root))

  def list_events(root, run_or_id) do
    with {:ok, run} <- get(root, run_or_id) do
      {:ok, events_for_run(root, run)}
    end
  end

  def list_by_agent(root, agent_id, opts \\ [])

  def list_by_agent(root, agent_id, opts) when is_binary(agent_id) and agent_id != "" do
    root
    |> list_for_root()
    |> Enum.filter(&agent_matches?(&1, agent_id))
    |> limit_items(option_value(opts, :limit))
  end

  def list_by_agent(_root, _agent_id, _opts), do: []

  def search_events_by_agent(root, agent_id, opts \\ [])

  def search_events_by_agent(root, agent_id, opts)
      when is_binary(agent_id) and agent_id != "" do
    run_ids =
      root
      |> list_by_agent(agent_id)
      |> Enum.map(& &1["id"])

    root
    |> event_log()
    |> Enum.filter(&(&1["agent_run_id"] in run_ids))
    |> filter_event_kind(option_value(opts, :kind) || option_value(opts, :type))
    |> filter_event_run(option_value(opts, :agent_run_id) || option_value(opts, :run_id))
    |> limit_items(option_value(opts, :limit))
  end

  def search_events_by_agent(_root, _agent_id, _opts), do: []

  def replay_by_agent(root, agent_id, run_or_id)
      when is_binary(agent_id) and agent_id != "" do
    with {:ok, run} <- get(root, run_or_id),
         :ok <- ensure_agent_match(run, agent_id),
         {:ok, events} <- list_events(root, run["id"]) do
      {:ok,
       %{
         "schema_version" => "holtworks_agent_run_replay/v1",
         "agent_id" => agent_id,
         "agent_run_id" => run["id"],
         "agent_run" => run,
         "lineage" => run_lineage(root, run),
         "event_count" => length(events),
         "events" => events
       }
       |> reject_empty()}
    end
  end

  def replay_by_agent(_root, _agent_id, _run_or_id), do: {:error, :invalid_agent_id}

  def task_inspector(root, task_ref_or_id, opts \\ [])

  def task_inspector(root, task_ref_or_id, opts)
      when is_binary(task_ref_or_id) and task_ref_or_id != "" do
    runs =
      root
      |> list_for_root()
      |> Enum.filter(&task_matches?(&1, task_ref_or_id))

    run_ids = Enum.map(runs, & &1["id"])

    events =
      root
      |> event_log()
      |> Enum.filter(&(&1["agent_run_id"] in run_ids))
      |> limit_items(option_value(opts, :limit))

    {:ok,
     %{
       "schema_version" => "holtworks_agent_task_inspector/v1",
       "task_ref_or_id" => task_ref_or_id,
       "run_count" => length(runs),
       "event_count" => length(events),
       "agent_runs" => runs,
       "events" => events
     }}
  end

  def task_inspector(_root, _task_ref_or_id, _opts), do: {:error, :invalid_task_ref}

  def record_event_once(root, run_or_id, kind, message, metadata \\ [])

  def record_event_once(root, run_or_id, kind, message, metadata)
      when is_binary(kind) and is_binary(message) do
    with {:ok, run} <- get(root, run_or_id) do
      metadata =
        metadata
        |> normalize_metadata()
        |> Map.put_new("idempotency_key", event_idempotency_key(run, kind, message, metadata))
        |> reject_empty()

      case find_event_by_idempotency_key(root, metadata["idempotency_key"]) do
        nil -> append_structured_event(root, run, kind, message, metadata)
        event -> {:duplicate, run, event}
      end
    end
  end

  def record_event_once(_root, _run_or_id, _kind, _message, _metadata),
    do: {:error, :invalid_agent_run_event}

  def record_continuation_packet(root, run_or_id, packet) when is_map(packet) do
    packet = RuntimeContracts.string_keys(packet)

    metadata =
      %{
        "schema_version" => "holtworks_agent_run_continuation_packet_event/v1",
        "idempotency_key" =>
          packet["idempotency_key"] ||
            RuntimeContracts.stable_id("agent_run_continuation_packet", [
              run_or_id,
              packet["previous_agent_run_id"],
              packet["continuation_depth"],
              packet["source"]
            ]),
        "packet" => packet
      }

    record_event_once(
      root,
      run_or_id,
      "agent_run.continuation_packet",
      "Continuation packet recorded.",
      metadata
    )
  end

  def record_continuation_packet(_root, _run_or_id, _packet),
    do: {:error, :invalid_continuation_packet}

  def record_agent_narration(root, run_or_id, attrs \\ %{})

  def record_agent_narration(root, run_or_id, attrs) when is_map(attrs) do
    attrs = RuntimeContracts.string_keys(attrs)
    body = attrs["body"] || attrs["content"] || attrs["message"]

    metadata =
      attrs
      |> Map.drop(["kind", "type", "message"])
      |> Map.merge(%{
        "schema_version" => "holtworks_agent_run_narration/v1",
        "trusted_for_liveness" => false,
        "body_preview" => preview(body)
      })
      |> Map.put_new(
        "idempotency_key",
        RuntimeContracts.stable_id("agent_run_narration", [
          run_or_id,
          attrs["idempotency_key"],
          body
        ])
      )

    record_event_once(
      root,
      run_or_id,
      "agent.narration",
      attrs["message"] || "Agent narration recorded.",
      metadata
    )
  end

  def record_agent_narration(_root, _run_or_id, _attrs), do: {:error, :invalid_narration}

  def record_plan_contract(root, run_or_id, plan_contract) when is_map(plan_contract) do
    plan_contract = RuntimeContracts.string_keys(plan_contract)

    metadata =
      %{
        "schema_version" => "holtworks_agent_run_plan_contract_event/v1",
        "idempotency_key" =>
          plan_contract["idempotency_key"] ||
            RuntimeContracts.stable_id("agent_run_plan_contract", [
              run_or_id,
              plan_contract["plan_id"],
              plan_contract["schema_version"],
              plan_contract
            ]),
        "plan_contract" => plan_contract
      }

    record_event_once(root, run_or_id, "plan.contract", "Plan contract recorded.", metadata)
  end

  def record_plan_contract(_root, _run_or_id, _plan_contract),
    do: {:error, :invalid_plan_contract}

  def record_child_agent_contract(root, run_or_id, child_contract) when is_map(child_contract) do
    child_contract = RuntimeContracts.string_keys(child_contract)

    metadata =
      %{
        "schema_version" => "holtworks_agent_run_child_contract_event/v1",
        "idempotency_key" =>
          child_contract["idempotency_key"] ||
            RuntimeContracts.stable_id("agent_run_child_contract", [
              run_or_id,
              child_contract["child_agent_id"],
              child_contract["agent_id"],
              child_contract["role"],
              child_contract
            ]),
        "child_agent_contract" => child_contract
      }

    record_event_once(
      root,
      run_or_id,
      "child_agent.contract",
      "Child agent contract recorded.",
      metadata
    )
  end

  def record_child_agent_contract(_root, _run_or_id, _child_contract),
    do: {:error, :invalid_child_agent_contract}

  def record_child_agent_completion(root, run_or_id, attrs \\ %{})

  def record_child_agent_completion(root, run_or_id, attrs) when is_map(attrs) do
    attrs = RuntimeContracts.string_keys(attrs)

    metadata =
      attrs
      |> Map.merge(%{
        "schema_version" => "holtworks_agent_run_child_completion_event/v1",
        "child_agent_id" => attrs["child_agent_id"] || attrs["agent_id"],
        "status" => attrs["status"] || "completed"
      })
      |> Map.put_new(
        "idempotency_key",
        RuntimeContracts.stable_id("agent_run_child_completion", [
          run_or_id,
          attrs["child_agent_id"] || attrs["agent_id"],
          attrs["child_run_id"] || attrs["run_id"],
          attrs["status"]
        ])
      )

    record_event_once(
      root,
      run_or_id,
      "child_agent.completed",
      attrs["message"] || "Child agent completion recorded.",
      metadata
    )
  end

  def record_child_agent_completion(_root, _run_or_id, _attrs),
    do: {:error, :invalid_child_agent_completion}

  def record_tool_event(root, run_or_id, tool_name, tool_call_id, result, attrs \\ %{})

  def record_tool_event(root, run_or_id, tool_name, tool_call_id, result, attrs)
      when is_binary(tool_name) and tool_name != "" do
    attrs = RuntimeContracts.string_keys(attrs)
    result = normalize_event_value(result)
    status = attrs["status"] || attrs["result_status"] || tool_result_status(result)

    metadata =
      attrs
      |> Map.drop(["kind", "type", "message", "tool", "tool_name", "tool_call_id"])
      |> Map.merge(%{
        "schema_version" => "holtworks_agent_run_tool_event/v1",
        "tool_name" => tool_name,
        "tool_call_id" => tool_call_id,
        "status" => status,
        "effective_work" => tool_effective_work?(status, attrs),
        "result_preview" => attrs["result_preview"] || preview(result),
        "result" => result
      })
      |> Map.put_new(
        "idempotency_key",
        RuntimeContracts.stable_id("agent_run_tool_event", [
          run_or_id,
          tool_name,
          tool_call_id,
          status,
          attrs["idempotency_key"]
        ])
      )

    record_event_once(
      root,
      run_or_id,
      "tool.completed",
      attrs["message"] || "Tool event recorded.",
      metadata
    )
  end

  def record_tool_event(_root, _run_or_id, _tool_name, _tool_call_id, _result, _attrs),
    do: {:error, :invalid_tool_event}

  def record_objective_evaluation(root, run_or_id, route, attrs \\ %{})

  def record_objective_evaluation(root, run_or_id, route, attrs) when is_map(route) do
    attrs = RuntimeContracts.string_keys(attrs)
    route = RuntimeContracts.string_keys(route)

    metadata =
      attrs
      |> Map.drop(["kind", "type", "message", "route", "evaluation"])
      |> Map.merge(%{
        "schema_version" => "holtworks_agent_run_objective_event/v1",
        "evaluation" => route,
        "status" => objective_evaluation_status(route, attrs),
        "verification_status" => attrs["verification_status"] || route["verification_status"]
      })
      |> Map.put_new(
        "idempotency_key",
        RuntimeContracts.stable_id("agent_run_objective_evaluation", [
          run_or_id,
          route["route_id"],
          route["decision"],
          route["can_finish"],
          attrs["idempotency_key"]
        ])
      )

    record_event_once(
      root,
      run_or_id,
      "objective.evaluated",
      attrs["message"] || "Objective evaluation recorded.",
      metadata
    )
  end

  def record_objective_evaluation(_root, _run_or_id, _route, _attrs),
    do: {:error, :invalid_objective_evaluation}

  def get(root, run_or_id) when is_binary(run_or_id) and run_or_id != "" do
    root
    |> list_for_root()
    |> Enum.find(fn run ->
      run["id"] == run_or_id or run["run_id"] == run_or_id or run["work_id"] == run_or_id
    end)
    |> case do
      nil -> {:error, :agent_run_not_found}
      run -> {:ok, run}
    end
  end

  def get(_root, _run_or_id), do: {:error, :invalid_agent_run_id}

  def latest_for_task_agent(root, task_id, agent_id) do
    root
    |> list_for_root()
    |> Enum.filter(fn run ->
      run["task_id"] == task_id and run["agent_id"] == agent_id
    end)
    |> List.last()
    |> case do
      nil -> {:error, :not_found}
      run -> {:ok, run}
    end
  end

  def record_process_event(root, run_or_id, kind, payload, opts \\ [])

  def record_process_event(root, run_or_id, kind, payload, opts)
      when is_binary(kind) and is_map(payload) do
    with {:ok, run} <- get(root, run_or_id) do
      idempotency_key =
        Keyword.get(opts, :idempotency_key) || process_event_idempotency_key(kind, payload, run)

      case find_event_by_idempotency_key(root, idempotency_key) do
        nil ->
          metadata =
            %{
              "schema_version" => "holtworks_agent_run_process_event/v1",
              "idempotency_key" => idempotency_key,
              "trigger" => Keyword.get(opts, :trigger),
              "process" => payload
            }
            |> reject_empty()

          now = Clock.iso_now()

          record =
            run
            |> Map.merge(process_activity_update(kind, payload, now))
            |> Map.put("last_event_at", now)
            |> Map.put("updated_at", now)
            |> reject_empty()

          upsert(root, record)
          event = append_event(root, record, kind, process_event_message(kind), metadata)
          {:ok, record, event}

        event ->
          {:duplicate, run, event}
      end
    end
  end

  def record_process_event(_root, _run_or_id, _kind, _payload, _opts),
    do: {:error, :invalid_process_event}

  def watchdog_snapshot(root, run) when is_map(run) do
    events =
      root
      |> event_log()
      |> Enum.filter(&(&1["agent_run_id"] == run["id"]))
      |> Enum.take(-8)

    %{
      "schema_version" => "holtworks_agent_run_watchdog_snapshot/v1",
      "agent_run_id" => run["id"],
      "task_id" => run["task_id"],
      "task_ref" => run["task_ref"],
      "agent_id" => run["agent_id"],
      "work_id" => run["work_id"],
      "status" => run["status"],
      "lifecycle_state" => run["lifecycle_state"],
      "runtime_status" => run["runtime_status"],
      "objective_status" => run["objective_status"],
      "failure_class" => run["failure_class"],
      "blocker_code" => run["blocker_code"],
      "failure_retryable" => run["failure_retryable"],
      "queued_at" => run["queued_at"],
      "started_at" => run["started_at"],
      "completed_at" => run["completed_at"],
      "heartbeat_at" => run["heartbeat_at"],
      "last_event_at" => run["last_event_at"],
      "last_effective_work_at" => run["last_effective_work_at"],
      "watchdog_status" => run["watchdog_status"],
      "next_wake_at" => run["next_wake_at"],
      "verification_gate" => run["verification_gate"],
      "continuation_decision" => run["continuation_decision"],
      "latest_events" => events
    }
    |> reject_empty()
  end

  def record_watchdog_observation(root, run, reason, snapshot, attrs \\ [])
      when is_map(run) and is_binary(reason) and is_map(snapshot) do
    now = Clock.iso_now()

    record =
      run
      |> Map.merge(%{
        "watchdog_status" => reason,
        "watchdog_checked_at" => now,
        "watchdog_snapshot" => snapshot,
        "next_wake_at" => Keyword.get(attrs, :next_wake_at),
        "updated_at" => now
      })
      |> reject_empty()

    upsert(root, record)
    append_event(root, record, "agent_run.watchdog_observed", "Watchdog observation recorded.")
    {:ok, record}
  end

  def mark_watchdog_recovery_queued(root, run, packet, reason, attrs \\ [])
      when is_map(run) and is_map(packet) and is_binary(reason) do
    now = Clock.iso_now()

    record =
      run
      |> Map.merge(%{
        "lifecycle_state" => "recovery_queued",
        "watchdog_status" => "recovery_queued",
        "watchdog_recovery_reason" => reason,
        "watchdog_recovery_packet" => packet,
        "watchdog_recovery_queued_at" => now,
        "next_wake_at" => Keyword.get(attrs, :next_wake_at),
        "updated_at" => now
      })
      |> reject_empty()

    upsert(root, record)

    append_event(
      root,
      record,
      "agent_run.watchdog_recovery_queued",
      "Watchdog recovery queued."
    )

    {:ok, record}
  end

  def mark_watchdog_recovery_failed(root, run, packet, reason)
      when is_map(run) and is_map(packet) do
    now = Clock.iso_now()

    record =
      run
      |> Map.merge(%{
        "watchdog_status" => "recovery_failed",
        "watchdog_recovery_reason" => to_string(reason),
        "watchdog_recovery_packet" => packet,
        "watchdog_checked_at" => now,
        "updated_at" => now
      })
      |> reject_empty()

    upsert(root, record)

    append_event(
      root,
      record,
      "agent_run.watchdog_recovery_failed",
      "Watchdog recovery failed."
    )

    {:ok, record}
  end

  def mark_process_wake_queued(root, run, packet, reason, attrs \\ [])
      when is_map(run) and is_map(packet) and is_binary(reason) do
    now = Clock.iso_now()
    next_state = transition_or_keep(run["lifecycle_state"], "needs_continuation")

    record =
      run
      |> Map.merge(%{
        "lifecycle_state" => next_state,
        "process_wake_status" => "wake_queued",
        "process_wake_reason" => reason,
        "process_wake_packet" => packet,
        "process_wake_queued_at" => now,
        "next_wake_at" => Keyword.get(attrs, :next_wake_at),
        "updated_at" => now
      })
      |> reject_empty()

    upsert(root, record)

    event =
      append_event(
        root,
        record,
        "agent_run.wake_queued",
        "Process wake continuation queued.",
        %{
          "schema_version" => "holtworks_agent_run_process_wake/v1",
          "source" => packet["source"],
          "reason" => reason,
          "process_event_id" => packet["process_event_id"],
          "process" => packet["process"]
        }
        |> reject_empty()
      )

    {:ok, record, event}
  end

  def mark_process_wake_failed(root, run, packet, reason)
      when is_map(run) and is_map(packet) do
    now = Clock.iso_now()

    record =
      run
      |> Map.merge(%{
        "process_wake_status" => "wake_failed",
        "process_wake_reason" => to_string(reason),
        "process_wake_packet" => packet,
        "updated_at" => now
      })
      |> reject_empty()

    upsert(root, record)

    append_event(
      root,
      record,
      "agent_run.wake_failed",
      "Process wake continuation could not be queued.",
      %{
        "schema_version" => "holtworks_agent_run_process_wake/v1",
        "source" => packet["source"],
        "reason" => to_string(reason),
        "process_event_id" => packet["process_event_id"],
        "process" => packet["process"]
      }
      |> reject_empty()
    )

    {:ok, record}
  end

  defp append_structured_event(root, run, kind, message, metadata) do
    now = Clock.iso_now()

    record =
      run
      |> Map.merge(event_activity_update(kind, metadata, now))
      |> Map.put("last_event_at", now)
      |> Map.put("updated_at", now)
      |> reject_empty()

    upsert(root, record)
    event = append_event(root, record, kind, message, metadata)
    {:ok, record, event}
  end

  defp event_activity_update("agent.narration", _metadata, now) do
    %{"last_narration_at" => now}
  end

  defp event_activity_update("tool.completed", metadata, now) do
    update =
      %{
        "last_tool_event_at" => now,
        "last_tool_event" =>
          Map.take(metadata, ["tool_name", "tool_call_id", "status", "effective_work"]),
        "heartbeat_at" => now
      }

    if tool_metadata_effective?(metadata) do
      Map.merge(update, %{
        "last_effective_work_at" => now,
        "last_observed_progress_at" => now,
        "watchdog_status" => nil
      })
    else
      update
    end
  end

  defp event_activity_update("objective.evaluated", metadata, now) do
    update =
      %{
        "objective_status" => objective_status_from_event(metadata),
        "last_objective_evaluated_at" => now,
        "last_observed_progress_at" => now,
        "heartbeat_at" => now
      }

    update
    |> maybe_put("verification_gate", objective_verification_gate(metadata))
  end

  defp event_activity_update("child_agent.completed", metadata, now) do
    update =
      %{
        "last_child_agent_completion_at" => now,
        "last_child_agent_completion" =>
          Map.take(metadata, ["child_agent_id", "child_run_id", "run_id", "status"]),
        "heartbeat_at" => now
      }

    if metadata["status"] in ["completed", "success", "ok", "ok_final"] do
      Map.put(update, "last_effective_work_at", now)
    else
      update
    end
  end

  defp event_activity_update(kind, _metadata, now)
       when kind in ["plan.contract", "child_agent.contract", "agent_run.continuation_packet"] do
    %{"last_observed_progress_at" => now, "heartbeat_at" => now}
  end

  defp event_activity_update(_kind, _metadata, _now), do: %{}

  defp events_for_run(root, run) do
    root
    |> event_log()
    |> Enum.filter(&(&1["agent_run_id"] == run["id"]))
  end

  defp ensure_agent_match(run, agent_id) do
    if agent_matches?(run, agent_id), do: :ok, else: {:error, :agent_run_not_found}
  end

  defp agent_matches?(run, agent_id) do
    run["agent_id"] == agent_id or agent_id in List.wrap(run["agent_ids"])
  end

  defp task_matches?(run, task_ref_or_id) do
    run["task_id"] == task_ref_or_id or run["task_ref"] == task_ref_or_id
  end

  defp filter_event_kind(events, nil), do: events
  defp filter_event_kind(events, ""), do: events

  defp filter_event_kind(events, kind) do
    kinds = RuntimeContracts.normalize_string_list(kind)

    if kinds == [] do
      events
    else
      Enum.filter(events, &(&1["kind"] in kinds or &1["type"] in kinds))
    end
  end

  defp filter_event_run(events, nil), do: events
  defp filter_event_run(events, ""), do: events
  defp filter_event_run(events, run_id), do: Enum.filter(events, &(&1["agent_run_id"] == run_id))

  defp run_lineage(root, run) do
    runs = list_for_root(root)

    previous =
      Enum.find(runs, fn candidate ->
        candidate["id"] == run["previous_agent_run_id"] or
          candidate["run_id"] == run["previous_run_id"] or
          candidate["work_id"] == run["continuation_of"]
      end)

    continuations =
      Enum.filter(runs, fn candidate ->
        candidate["previous_agent_run_id"] == run["id"] or
          candidate["previous_run_id"] == run["run_id"] or
          candidate["continuation_of"] == run["work_id"]
      end)

    %{
      "previous_agent_run" => previous,
      "continuations" => continuations
    }
    |> reject_empty()
  end

  defp event_idempotency_key(run, kind, message, metadata) do
    metadata = normalize_metadata(metadata)

    metadata["idempotency_key"] ||
      RuntimeContracts.stable_id("agent_run_event", [
        run["id"],
        kind,
        message,
        Map.drop(metadata, ["idempotency_key"])
      ])
  end

  defp normalize_metadata(metadata) when is_map(metadata),
    do: RuntimeContracts.string_keys(metadata)

  defp normalize_metadata(_metadata), do: %{}

  defp normalize_event_value(value) when is_map(value), do: RuntimeContracts.string_keys(value)

  defp normalize_event_value(value) when is_list(value),
    do: Enum.map(value, &normalize_event_value/1)

  defp normalize_event_value({status, payload}) when is_atom(status) do
    %{"status" => Atom.to_string(status), "payload" => normalize_event_value(payload)}
  end

  defp normalize_event_value({status, payload}) when is_binary(status) do
    %{"status" => status, "payload" => normalize_event_value(payload)}
  end

  defp normalize_event_value(value), do: value

  defp tool_result_status(%{"status" => status}) when is_binary(status) and status != "",
    do: status

  defp tool_result_status(%{"tuple_status" => status}) when is_binary(status) and status != "",
    do: status

  defp tool_result_status(_result), do: "unknown"

  defp tool_effective_work?(status, attrs) do
    case attrs["effective_work"] do
      true -> true
      false -> false
      _value -> status in ["ok", "ok_final", "await_process", "completed", "success"]
    end
  end

  defp tool_metadata_effective?(metadata), do: metadata["effective_work"] == true

  defp objective_evaluation_status(route, attrs) do
    cond do
      attrs["status"] in ["satisfied", "needs_work", "blocked", "needs_continuation"] ->
        attrs["status"]

      route["decision"] == "done" ->
        "satisfied"

      route["can_finish"] == true ->
        "satisfied"

      route["status"] == "blocked" ->
        "blocked"

      route["can_finish"] == false ->
        "needs_work"

      true ->
        "needs_review"
    end
  end

  defp objective_status_from_event(metadata) do
    case metadata["status"] do
      "satisfied" -> "satisfied"
      "blocked" -> "blocked"
      "needs_continuation" -> "needs_continuation"
      "needs_work" -> "needs_work"
      _status -> "needs_review"
    end
  end

  defp objective_verification_gate(metadata) do
    %{
      "schema_version" => "holtworks_agent_run_objective_gate/v1",
      "status" => metadata["verification_status"] || metadata["status"],
      "evaluation" => metadata["evaluation"]
    }
    |> reject_empty()
  end

  defp preview(nil), do: nil

  defp preview(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.slice(0, 240)
  end

  defp preview(value) do
    case Jason.encode(value) do
      {:ok, encoded} -> preview(encoded)
      {:error, _reason} -> inspect(value, limit: 20, printable_limit: 240)
    end
  end

  defp limit_items(items, value) do
    case positive_integer(value) do
      nil -> items
      limit -> Enum.take(items, -limit)
    end
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(value) when is_integer(value), do: nil

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> number
      _other -> nil
    end
  end

  defp positive_integer(_value), do: nil

  defp option_value(opts, key) when is_list(opts) do
    Keyword.get(opts, key) || keyword_string_value(opts, to_string(key))
  end

  defp option_value(opts, key) when is_map(opts) do
    Map.get(opts, key) || Map.get(opts, to_string(key))
  end

  defp option_value(_opts, _key), do: nil

  defp keyword_string_value(opts, key) do
    Enum.find_value(opts, fn
      {current_key, value} when is_binary(current_key) ->
        if current_key == key, do: value, else: nil

      _entry ->
        nil
    end)
  end

  defp maybe_put(map, _key, value) when value in [nil, "", [], %{}], do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp list_for_root(root) do
    ensure_store(root)
    JSON.read(path(root), [])
  end

  defp base_record(task, work, now) do
    %{
      "schema_version" => @schema_version,
      "id" => work["agent_run_id"] || Clock.id("agent_run"),
      "task_id" => task["id"],
      "task_ref" => task["ref"],
      "task_title" => task["title"],
      "agent_id" => first_agent_id(work),
      "agent_ids" => work["agent_ids"] || [],
      "assignee" => work["assignee"],
      "dispatch_id" => work["dispatch_id"],
      "dispatch_plan" => work["dispatch_plan"],
      "source" => agent_source(work),
      "mode" => work["mode"],
      "work_id" => work["id"],
      "work_kind" => work["kind"],
      "iteration" => work["iteration"],
      "continuation_of" => work["continuation_of"],
      "previous_run_id" => work["resumed_from_run_id"],
      "message" => work["message"],
      "inserted_at" => now,
      "updated_at" => now
    }
  end

  defp existing_or_base(root, task, work, now) do
    list_for_root(root)
    |> Enum.find(&(&1["id"] == work["agent_run_id"]))
    |> case do
      nil -> base_record(task, work, now)
      record -> Map.put(record, "updated_at", now)
    end
  end

  defp first_agent_id(%{"agent_id" => agent_id}) when is_binary(agent_id) and agent_id != "",
    do: agent_id

  defp first_agent_id(work) do
    work
    |> Map.get("agent_ids", [])
    |> List.wrap()
    |> List.first()
  end

  defp agent_source(%{"source" => source}) when is_binary(source) and source != "",
    do: source

  defp agent_source(%{"kind" => "continuation"}), do: "task_agent_continuation"
  defp agent_source(_work), do: "task_agent_request"

  defp completion_status("completed"), do: "success"
  defp completion_status("canceled"), do: "canceled"
  defp completion_status(_status), do: "failed"

  defp lifecycle_state("success", attrs) do
    AgentRunStateMachine.complete(Map.put(attrs, "status", "success"))
  end

  defp lifecycle_state("canceled", attrs),
    do: AgentRunStateMachine.complete(Map.put(attrs, "status", "canceled"))

  defp lifecycle_state(status, attrs),
    do: AgentRunStateMachine.complete(Map.put(attrs, "status", status))

  defp objective_status("awaiting_verification", _attrs), do: "needs_verification"
  defp objective_status("needs_continuation", _attrs), do: "needs_continuation"
  defp objective_status("blocked", _attrs), do: "blocked"
  defp objective_status("canceled", _attrs), do: "canceled"
  defp objective_status(_lifecycle_state, _attrs), do: "unknown"

  defp task_complexity(attrs) do
    attrs
    |> Map.get("policy", %{})
    |> Map.get("task_classification", %{})
    |> Map.get("task_complexity")
  end

  defp failure_class(attrs) do
    attrs
    |> Map.get("classification", %{})
    |> Map.get("failure_class")
  end

  defp blocker_code(attrs) do
    attrs
    |> Map.get("classification", %{})
    |> Map.get("blocker_code")
  end

  defp failure_retryable(attrs) do
    attrs
    |> Map.get("classification", %{})
    |> Map.get("retryable")
  end

  defp verification_objective_status(%{"decision" => "done"}), do: "satisfied"
  defp verification_objective_status(%{"route" => %{"can_finish" => true}}), do: "satisfied"
  defp verification_objective_status(_report), do: "needs_work"

  defp verification_lifecycle_state(%{"decision" => "done"}), do: "completed"
  defp verification_lifecycle_state(%{"route" => %{"can_finish" => true}}), do: "completed"
  defp verification_lifecycle_state(_report), do: "needs_continuation"

  defp event_kind("success"), do: "agent_run.completed"
  defp event_kind(_status), do: "agent_run.failed"

  defp maybe_append_decision_event(
         root,
         %{"continuation_decision" => %{"action" => action}} = record
       )
       when action in ["continue", "suppress"] do
    append_event(
      root,
      record,
      "agent_run.continuation_decision",
      "Task-agent continuation decision recorded."
    )
  end

  defp maybe_append_decision_event(_root, _record), do: :ok

  defp upsert(root, record) do
    records = list_for_root(root)

    records =
      if Enum.any?(records, &(&1["id"] == record["id"])) do
        Enum.map(records, fn current ->
          if current["id"] == record["id"], do: record, else: current
        end)
      else
        records ++ [record]
      end

    JSON.write(path(root), records)
    :ok
  end

  defp agent_loop_contract(task, work, lifecycle_state, status, now, attrs \\ %{}) do
    AgentLoop.contract(%{
      "task" => task,
      "agent" => work,
      "agent_id" => work["agent_id"],
      "policy" => Map.get(attrs, "policy", work["policy"] || %{}),
      "decision" => Map.get(attrs, "continuation_decision", %{}),
      "continuation_count" => max((work["iteration"] || 1) - 1, 0),
      "lifecycle_state" => lifecycle_state,
      "status" => status,
      "loop_started_at" => work["created_at"] || work["started_at"] || now,
      "now" => now,
      "source" => work["source"]
    })
  end

  defp transition_or_keep(current_state, next_state) do
    case AgentRunStateMachine.transition(current_state, next_state) do
      {:ok, state} -> state
      {:error, _reason} -> current_state
    end
  end

  defp find_event_by_idempotency_key(_root, nil), do: nil

  defp find_event_by_idempotency_key(root, idempotency_key) do
    Enum.find(event_log(root), fn event ->
      get_in(event, ["metadata", "idempotency_key"]) == idempotency_key
    end)
  end

  defp process_event_idempotency_key(kind, payload, run) do
    identity =
      payload["managed_process_id"] ||
        payload["status_path"] ||
        payload["sandbox_pid"] ||
        payload["process_id"] ||
        payload_fingerprint(payload)

    ["agent_process_event", run["id"], kind, identity]
    |> Enum.reject(&blank?/1)
    |> Enum.join(":")
  end

  defp payload_fingerprint(payload) do
    payload
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp process_activity_update("process.started", payload, now) do
    %{
      "last_process_started_at" => now,
      "last_process" => payload,
      "heartbeat_at" => now,
      "last_effective_work_at" => now
    }
  end

  defp process_activity_update(kind, payload, now)
       when kind in ["process.exited", "process.missing"] do
    %{
      "last_process_completed_at" => now,
      "last_process" => payload,
      "heartbeat_at" => now,
      "last_effective_work_at" => now
    }
  end

  defp process_activity_update(_kind, payload, now) do
    %{"last_process" => payload, "heartbeat_at" => now}
  end

  defp process_event_message("process.started"), do: "Process started."
  defp process_event_message("process.exited"), do: "Process exited."
  defp process_event_message("process.missing"), do: "Process missing."
  defp process_event_message(_kind), do: "Process event recorded."

  defp append_event(root, record, kind, message, metadata \\ %{}) do
    event =
      %{
        "id" => Clock.id("agent_run_event"),
        "type" => kind,
        "kind" => kind,
        "message" => message,
        "agent_run_id" => record["id"],
        "task_id" => record["task_id"],
        "task_ref" => record["task_ref"],
        "lifecycle_state" => record["lifecycle_state"],
        "status" => record["status"],
        "metadata" => metadata,
        "at" => Clock.iso_now()
      }
      |> reject_empty()

    JSON.append_jsonl(events_path(root), event)
    event
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(nil), do: true
  defp blank?(_value), do: false

  defp reject_empty(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end
end
