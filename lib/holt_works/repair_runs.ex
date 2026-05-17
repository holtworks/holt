defmodule HoltWorks.RepairRuns do
  @moduledoc """
  File-backed structured repair-run ledger.

  Repair runs are local workflow records for diagnosis, prediction,
  architecture planning, blast-radius checks, implementation gates, and final
  verification. Durable decisions are driven by explicit statuses, booleans,
  enums, and artifact fields.
  """

  alias HoltWorks.{Clock, JSON, Paths}
  alias HoltWorks.Tasks.RuntimeContracts

  @schema_version "holtworks_repair_run/v1"
  @event_schema_version "holtworks_repair_run_event/v1"
  @artifact_schema_version "holtworks_repair_artifact/v1"
  @score_schema_version "holtworks_repair_prediction_score/v1"
  @risk_levels ~w(low medium high critical)
  @strategies ~w(local_patch multi_file_repair architecture_refactor replacement human_gate)
  @artifact_types ~w(
    goal_contract hypothesis research_claim prediction observation architecture_plan
    blast_radius verification original_issue_check impact_check related_issue final_report
  )
  @decisions ~w(continue zoom_out strategy_decision pivot refactor ask_human finish)
  @check_statuses ~w(passed failed pending blocked skipped)

  def risk_levels, do: @risk_levels
  def strategies, do: @strategies
  def artifact_types, do: @artifact_types
  def decisions, do: @decisions
  def check_statuses, do: @check_statuses

  def path(root), do: Paths.workspace_file(root, "repair_runs.json")
  def events_path(root), do: Paths.workspace_file(root, "repair_run_events.jsonl")

  def ensure_store(root) do
    Paths.ensure_workspace(root)
    unless File.exists?(path(root)), do: JSON.write(path(root), [])
    :ok
  end

  def list(opts \\ []) do
    root = Paths.workspace_root(opts)
    ensure_store(root)

    root
    |> path()
    |> JSON.read([])
    |> Enum.filter(&is_map/1)
    |> Enum.map(&normalize_run/1)
  end

  def get(run_id, opts \\ [])

  def get(run_id, opts) when is_binary(run_id) and run_id != "" do
    root = Paths.workspace_root(opts)

    [workspace: root]
    |> list()
    |> Enum.find(&(&1["id"] == run_id))
    |> case do
      nil -> {:error, :repair_run_not_found}
      run -> {:ok, run}
    end
  end

  def get(_run_id, _opts), do: {:error, :repair_run_id_required}

  def start(attrs, opts \\ [])

  def start(attrs, opts) when is_map(attrs) do
    root = Paths.workspace_root(opts)
    ensure_store(root)
    attrs = RuntimeContracts.string_keys(attrs)

    with {:ok, risk_level} <- enum_value(attrs, "risk_level", @risk_levels, "low") do
      now = Clock.iso_now()

      run =
        %{
          "schema_version" => @schema_version,
          "id" => Clock.id("repair_run"),
          "task_id" => RuntimeContracts.text(attrs, "task_id"),
          "agent_run_id" => RuntimeContracts.text(attrs, "agent_run_id"),
          "project_id" => RuntimeContracts.text(attrs, "project_id"),
          "space_id" => RuntimeContracts.text(attrs, "space_id"),
          "status" => "active",
          "phase" => "intake",
          "strategy" => nil,
          "risk_level" => risk_level,
          "approval_status" => approval_status(risk_level),
          "goal_contract" => RuntimeContracts.normalize_map(attrs["goal_contract"]),
          "hypotheses" => [],
          "predictions" => [],
          "prediction_scores" => [],
          "reconciliations" => [],
          "observations" => [],
          "research_claims" => [],
          "architecture_plan" => nil,
          "blast_radius_report" => nil,
          "verification_runs" => [],
          "original_issue_checks" => [],
          "impact_checks" => [],
          "related_issues" => [],
          "final_report" => nil,
          "events" => [],
          "inserted_at" => now,
          "updated_at" => now
        }
        |> RuntimeContracts.reject_empty()
        |> append_run_event("repair_run.started", %{"risk_level" => risk_level}, now)

      store(root, upsert(list(workspace: root), run))
      append_event(root, run, "repair_run.started", %{"risk_level" => risk_level})
      {:ok, payload(run, "started")}
    end
  end

  def start(_attrs, _opts), do: {:error, :invalid_repair_run_attrs}

  def record_artifact(attrs, opts \\ [])

  def record_artifact(attrs, opts) when is_map(attrs) do
    attrs = RuntimeContracts.string_keys(attrs)

    with {:ok, repair_run_id} <- required_text(attrs, "repair_run_id"),
         {:ok, run} <- get(repair_run_id, opts),
         {:ok, artifact_type} <- enum_value(attrs, "artifact_type", @artifact_types, nil),
         {:ok, artifact} <-
           artifact(artifact_type, RuntimeContracts.normalize_map(attrs["payload"])),
         {:ok, updated} <- update_run(run["id"], opts, &put_artifact(&1, artifact_type, artifact)) do
      {:ok, payload(updated, "recorded #{artifact_type}")}
    end
  end

  def record_artifact(_attrs, _opts), do: {:error, :invalid_repair_artifact}

  def choose_strategy(attrs, opts \\ [])

  def choose_strategy(attrs, opts) when is_map(attrs) do
    attrs = RuntimeContracts.string_keys(attrs)

    with {:ok, repair_run_id} <- required_text(attrs, "repair_run_id"),
         {:ok, run} <- get(repair_run_id, opts),
         {:ok, strategy} <- enum_value(attrs, "strategy", @strategies, nil),
         {:ok, risk_level} <- enum_value(attrs, "risk_level", @risk_levels, run["risk_level"]) do
      update_run(run["id"], opts, fn current ->
        current
        |> Map.put("strategy", strategy)
        |> Map.put("risk_level", risk_level)
        |> Map.put("strategy_waiver", RuntimeContracts.normalize_map(attrs["strategy_waiver"]))
        |> Map.put("approval_status", approval_status(risk_level, current["approval_status"]))
        |> Map.put("phase", strategy_phase(strategy))
        |> evented("repair_run.strategy_chosen", %{
          "strategy" => strategy,
          "risk_level" => risk_level
        })
      end)
      |> wrap_payload("selected strategy")
    end
  end

  def choose_strategy(_attrs, _opts), do: {:error, :invalid_repair_strategy}

  def approve_gate(attrs, opts \\ [])

  def approve_gate(attrs, opts) when is_map(attrs) do
    attrs = RuntimeContracts.string_keys(attrs)

    with {:ok, repair_run_id} <- required_text(attrs, "repair_run_id"),
         {:ok, run} <- get(repair_run_id, opts) do
      update_run(run["id"], opts, fn current ->
        current
        |> Map.put("approval_status", "approved")
        |> Map.put("approval", %{
          "approved_at" => Clock.iso_now(),
          "reason_code" => RuntimeContracts.text(attrs, "reason_code", "explicit_approval"),
          "approved_by" => RuntimeContracts.text(attrs, "approved_by")
        })
        |> evented("repair_run.approved", %{
          "reason_code" => RuntimeContracts.text(attrs, "reason_code")
        })
      end)
      |> wrap_payload("approved")
    end
  end

  def approve_gate(_attrs, _opts), do: {:error, :invalid_repair_approval}

  def begin_implementation(attrs, opts \\ [])

  def begin_implementation(attrs, opts) when is_map(attrs) do
    attrs = RuntimeContracts.string_keys(attrs)

    with {:ok, repair_run_id} <- required_text(attrs, "repair_run_id"),
         {:ok, run} <- get(repair_run_id, opts),
         :ok <- implementation_gate(run) do
      update_run(run["id"], opts, fn current ->
        current
        |> Map.put("phase", "implementation")
        |> Map.put("implementation_started_at", Clock.iso_now())
        |> evented("repair_run.implementation_started", %{})
      end)
      |> wrap_payload("entered implementation")
    end
  end

  def begin_implementation(_attrs, _opts), do: {:error, :invalid_repair_implementation}

  def reconcile_prediction(attrs, opts \\ [])

  def reconcile_prediction(attrs, opts) when is_map(attrs) do
    attrs = RuntimeContracts.string_keys(attrs)

    with {:ok, repair_run_id} <- required_text(attrs, "repair_run_id"),
         {:ok, run} <- get(repair_run_id, opts),
         {:ok, prediction_id} <- required_text(attrs, "prediction_id"),
         {:ok, observation_id} <- required_text(attrs, "observation_id"),
         {:ok, matched} <- required_boolean(attrs, "matched"),
         {:ok, next_decision} <-
           enum_value(attrs, "next_decision", @decisions, "strategy_decision") do
      reconciliation =
        %{
          "id" => Clock.id("repair_reconciliation"),
          "prediction_id" => prediction_id,
          "observation_id" => observation_id,
          "matched" => matched,
          "mismatch_reason_code" => RuntimeContracts.text(attrs, "mismatch_reason_code"),
          "next_decision" => next_decision,
          "created_at" => Clock.iso_now()
        }
        |> RuntimeContracts.reject_empty()

      update_run(run["id"], opts, fn current ->
        current
        |> append_list("reconciliations", reconciliation)
        |> Map.put("phase", phase_for_decision(next_decision))
        |> evented("repair_run.prediction_reconciled", %{
          "prediction_id" => prediction_id,
          "observation_id" => observation_id,
          "matched" => matched,
          "next_decision" => next_decision
        })
      end)
      |> wrap_payload("reconciled prediction")
    end
  end

  def reconcile_prediction(_attrs, _opts), do: {:error, :invalid_prediction_reconciliation}

  def score_predictions(attrs, opts \\ [])

  def score_predictions(attrs, opts) when is_map(attrs) do
    attrs = RuntimeContracts.string_keys(attrs)

    with {:ok, repair_run_id} <- required_text(attrs, "repair_run_id"),
         {:ok, run} <- get(repair_run_id, opts) do
      score = prediction_score(run, attrs)

      if record?(attrs) do
        update_run(run["id"], opts, fn current ->
          current
          |> append_list("prediction_scores", score)
          |> evented("repair_run.predictions_scored", %{
            "prediction_score_id" => score["id"],
            "recommendation" => score["recommendation"]
          })
        end)
        |> case do
          {:ok, updated} ->
            {:ok,
             payload(updated, "recorded repair prediction score")
             |> Map.put("prediction_score", score)}

          error ->
            error
        end
      else
        {:ok, payload(run, "scored repair predictions") |> Map.put("prediction_score", score)}
      end
    end
  end

  def score_predictions(_attrs, _opts), do: {:error, :invalid_prediction_score}

  def draft_architecture_plan(attrs, opts \\ []) when is_map(attrs) do
    draft_and_maybe_record(attrs, opts, "architecture_plan", &architecture_plan/2)
  end

  def draft_blast_radius(attrs, opts \\ []) when is_map(attrs) do
    draft_and_maybe_record(attrs, opts, "blast_radius", &blast_radius/2)
  end

  def draft_original_issue_check(attrs, opts \\ []) when is_map(attrs) do
    draft_and_maybe_record(attrs, opts, "original_issue_check", &original_issue_check_draft/2)
  end

  def draft_related_issue_sweep(attrs, opts \\ []) when is_map(attrs) do
    draft_and_maybe_record(attrs, opts, "related_issue", &related_issue_sweep/2)
  end

  def execute_original_issue_check(attrs, opts \\ []) when is_map(attrs) do
    execute_check(attrs, opts, "original_issue_check", &original_issue_execution/2)
  end

  def execute_impact_check(attrs, opts \\ []) when is_map(attrs) do
    execute_check(attrs, opts, "impact_check", &impact_check_execution/2)
  end

  def complete(attrs, opts \\ [])

  def complete(attrs, opts) when is_map(attrs) do
    attrs = RuntimeContracts.string_keys(attrs)

    with {:ok, repair_run_id} <- required_text(attrs, "repair_run_id"),
         {:ok, run} <- get(repair_run_id, opts),
         :ok <- completion_gate(run, RuntimeContracts.normalize_map(attrs["final_report"])) do
      update_run(run["id"], opts, fn current ->
        current
        |> Map.put("status", "completed")
        |> Map.put("phase", "complete")
        |> Map.put("final_report", final_report(attrs, current))
        |> Map.put("completed_at", Clock.iso_now())
        |> evented("repair_run.completed", %{})
      end)
      |> wrap_payload("completed")
    end
  end

  def complete(_attrs, _opts), do: {:error, :invalid_repair_completion}

  defp draft_and_maybe_record(attrs, opts, artifact_type, builder) do
    attrs = RuntimeContracts.string_keys(attrs)

    with {:ok, repair_run_id} <- required_text(attrs, "repair_run_id"),
         {:ok, run} <- get(repair_run_id, opts),
         draft <- builder.(run, attrs) do
      if record?(attrs) do
        update_run(run["id"], opts, &put_artifact(&1, artifact_type, draft))
        |> case do
          {:ok, updated} ->
            {:ok,
             payload(updated, "drafted and recorded #{artifact_type}")
             |> Map.put(draft_key(artifact_type), draft)}

          error ->
            error
        end
      else
        {:ok,
         payload(run, "drafted #{artifact_type}") |> Map.put(draft_key(artifact_type), draft)}
      end
    end
  end

  defp execute_check(attrs, opts, artifact_type, builder) do
    attrs = RuntimeContracts.string_keys(attrs)

    with {:ok, repair_run_id} <- required_text(attrs, "repair_run_id"),
         {:ok, run} <- get(repair_run_id, opts),
         check <- builder.(run, attrs) do
      if record?(attrs) do
        update_run(run["id"], opts, &put_artifact(&1, artifact_type, check))
        |> case do
          {:ok, updated} ->
            {:ok,
             payload(updated, "executed #{artifact_type}")
             |> Map.put(execution_key(artifact_type), check)}

          error ->
            error
        end
      else
        {:ok,
         payload(run, "executed #{artifact_type}") |> Map.put(execution_key(artifact_type), check)}
      end
    end
  end

  defp architecture_plan(run, attrs) do
    %{
      "schema_version" => "holtworks_repair_architecture_plan/v1",
      "id" => Clock.id("repair_architecture_plan"),
      "repair_run_id" => run["id"],
      "status" => "draft",
      "problem_statement" =>
        RuntimeContracts.text(attrs, "problem_statement") ||
          RuntimeContracts.text(run["goal_contract"] || %{}, "original_issue"),
      "target_architecture" => RuntimeContracts.text(attrs, "target_architecture"),
      "write_scope" => RuntimeContracts.normalize_string_list(attrs["write_scope"]),
      "protected_flows" => RuntimeContracts.normalize_string_list(attrs["protected_flows"]),
      "non_goals" => RuntimeContracts.normalize_string_list(attrs["non_goals"]),
      "replacement_candidates" => normalize_map_list(attrs["replacement_candidates"]),
      "migration_steps" => normalize_list(attrs["migration_steps"]),
      "state_and_data_changes" => normalize_map_list(attrs["state_and_data_changes"]),
      "rollback_plan" => RuntimeContracts.normalize_map(attrs["rollback_plan"]),
      "rollback_steps" => normalize_list(attrs["rollback_steps"]),
      "verification_matrix" => normalize_map_list(attrs["verification_matrix"]),
      "external_facts_required" => RuntimeContracts.truthy?(attrs["external_facts_required"]),
      "confidence" => RuntimeContracts.number(attrs["confidence"], nil),
      "notes" => RuntimeContracts.text(attrs, "notes"),
      "created_at" => Clock.iso_now()
    }
    |> RuntimeContracts.reject_empty()
  end

  defp blast_radius(run, attrs) do
    %{
      "schema_version" => "holtworks_repair_blast_radius/v1",
      "id" => Clock.id("repair_blast_radius"),
      "repair_run_id" => run["id"],
      "status" => "draft",
      "changed_files" => RuntimeContracts.normalize_string_list(attrs["changed_files"]),
      "risk_flags" => RuntimeContracts.normalize_string_list(attrs["risk_flags"]),
      "affected_domains" => RuntimeContracts.normalize_string_list(attrs["affected_domains"]),
      "protected_flows" => RuntimeContracts.normalize_string_list(attrs["protected_flows"]),
      "write_scope" => RuntimeContracts.normalize_string_list(attrs["write_scope"]),
      "verification_matrix" => normalize_map_list(attrs["verification_matrix"]),
      "rollback_notes" => RuntimeContracts.normalize_string_list(attrs["rollback_notes"]),
      "notes" => RuntimeContracts.text(attrs, "notes"),
      "created_at" => Clock.iso_now()
    }
    |> RuntimeContracts.reject_empty()
  end

  defp original_issue_check_draft(run, attrs) do
    %{
      "schema_version" => "holtworks_repair_original_issue_check_draft/v1",
      "id" => Clock.id("repair_original_issue_check_draft"),
      "repair_run_id" => run["id"],
      "status" => "pending",
      "proof_commands" => normalize_list(attrs["proof_commands"]),
      "manual_check_results" => normalize_map_list(attrs["manual_check_results"]),
      "tool_check_results" => normalize_map_list(attrs["tool_check_results"]),
      "goal_check" => RuntimeContracts.normalize_map(attrs["goal_check"]),
      "notes" => RuntimeContracts.text(attrs, "notes"),
      "created_at" => Clock.iso_now()
    }
    |> RuntimeContracts.reject_empty()
  end

  defp original_issue_execution(run, attrs) do
    goal_check = RuntimeContracts.normalize_map(attrs["goal_check"])
    status = explicit_check_status(goal_check, "original_issue_fixed")

    %{
      "schema_version" => "holtworks_repair_original_issue_check/v1",
      "id" => Clock.id("repair_original_issue_check"),
      "repair_run_id" => run["id"],
      "status" => status,
      "proof_draft_id" => RuntimeContracts.text(attrs, "proof_draft_id"),
      "manual_check_results" => normalize_map_list(attrs["manual_check_results"]),
      "tool_check_results" => normalize_map_list(attrs["tool_check_results"]),
      "goal_check" => goal_check,
      "evidence_refs" => RuntimeContracts.normalize_string_list(goal_check["evidence_refs"]),
      "created_at" => Clock.iso_now()
    }
    |> RuntimeContracts.reject_empty()
  end

  defp impact_check_execution(run, attrs) do
    status = impact_status(attrs)

    %{
      "schema_version" => "holtworks_repair_impact_check/v1",
      "id" => Clock.id("repair_impact_check"),
      "repair_run_id" => run["id"],
      "status" => status,
      "protected_flow_results" => normalize_map_list(attrs["protected_flow_results"]),
      "affected_domain_results" => normalize_map_list(attrs["affected_domain_results"]),
      "manual_check_results" => normalize_map_list(attrs["manual_check_results"]),
      "tool_check_results" => normalize_map_list(attrs["tool_check_results"]),
      "unexpected_change_candidates" => normalize_map_list(attrs["unexpected_change_candidates"]),
      "impact_waiver" => RuntimeContracts.normalize_map(attrs["impact_waiver"]),
      "created_at" => Clock.iso_now()
    }
    |> RuntimeContracts.reject_empty()
  end

  defp related_issue_sweep(run, attrs) do
    %{
      "schema_version" => "holtworks_repair_related_issue_sweep/v1",
      "id" => Clock.id("repair_related_issue"),
      "repair_run_id" => run["id"],
      "status" => related_issue_status(attrs),
      "candidate_related_issues" => normalize_map_list(attrs["candidate_related_issues"]),
      "unrelated_root_cause_candidates" =>
        normalize_map_list(attrs["unrelated_root_cause_candidates"]),
      "shared_dependency_risks" => normalize_map_list(attrs["shared_dependency_risks"]),
      "state_or_queue_risks" => normalize_map_list(attrs["state_or_queue_risks"]),
      "permission_or_billing_risks" => normalize_map_list(attrs["permission_or_billing_risks"]),
      "stale_assumption_checks" => normalize_map_list(attrs["stale_assumption_checks"]),
      "recommended_diagnostics" => normalize_map_list(attrs["recommended_diagnostics"]),
      "fix_now" => normalize_map_list(attrs["fix_now"]),
      "track_later" => normalize_map_list(attrs["track_later"]),
      "risk_flags" => RuntimeContracts.normalize_string_list(attrs["risk_flags"]),
      "severity" => enum_text(attrs, "severity", ~w(low medium high critical unknown), "unknown"),
      "should_fix_now" => RuntimeContracts.truthy?(attrs["should_fix_now"]),
      "notes" => RuntimeContracts.text(attrs, "notes"),
      "created_at" => Clock.iso_now()
    }
    |> RuntimeContracts.reject_empty()
  end

  defp put_artifact(run, "goal_contract", artifact),
    do:
      run
      |> Map.put("goal_contract", artifact["payload"])
      |> artifact_event("goal_contract", artifact)

  defp put_artifact(run, "hypothesis", artifact),
    do: run |> append_list("hypotheses", artifact) |> artifact_event("hypothesis", artifact)

  defp put_artifact(run, "research_claim", artifact),
    do:
      run
      |> append_list("research_claims", artifact)
      |> artifact_event("research_claim", artifact)

  defp put_artifact(run, "prediction", artifact),
    do: run |> append_list("predictions", artifact) |> artifact_event("prediction", artifact)

  defp put_artifact(run, "observation", artifact),
    do: run |> append_list("observations", artifact) |> artifact_event("observation", artifact)

  defp put_artifact(run, "architecture_plan", artifact),
    do:
      run
      |> Map.put("architecture_plan", artifact)
      |> Map.put("phase", "architecture")
      |> artifact_event("architecture_plan", artifact)

  defp put_artifact(run, "blast_radius", artifact),
    do:
      run
      |> Map.put("blast_radius_report", artifact)
      |> Map.put("phase", "blast_radius")
      |> artifact_event("blast_radius", artifact)

  defp put_artifact(run, "verification", artifact),
    do:
      run
      |> append_list("verification_runs", artifact)
      |> artifact_event("verification", artifact)

  defp put_artifact(run, "original_issue_check", artifact),
    do:
      run
      |> append_list("original_issue_checks", artifact)
      |> artifact_event("original_issue_check", artifact)

  defp put_artifact(run, "impact_check", artifact),
    do: run |> append_list("impact_checks", artifact) |> artifact_event("impact_check", artifact)

  defp put_artifact(run, "related_issue", artifact),
    do:
      run |> append_list("related_issues", artifact) |> artifact_event("related_issue", artifact)

  defp put_artifact(run, "final_report", artifact),
    do:
      run
      |> Map.put("final_report", artifact["payload"] || artifact)
      |> artifact_event("final_report", artifact)

  defp artifact(type, payload) do
    {:ok,
     %{
       "schema_version" => @artifact_schema_version,
       "id" => RuntimeContracts.text(payload, "id", Clock.id("repair_artifact")),
       "artifact_type" => type,
       "status" => RuntimeContracts.text(payload, "status"),
       "payload" => payload,
       "created_at" => Clock.iso_now()
     }
     |> RuntimeContracts.reject_empty()}
  end

  defp prediction_score(run, attrs) do
    reconciliations = run["reconciliations"] || []
    matched = Enum.count(reconciliations, &(&1["matched"] == true))
    total = length(reconciliations)
    convergence = if total == 0, do: 0.0, else: matched / total

    %{
      "schema_version" => @score_schema_version,
      "id" => Clock.id("repair_prediction_score"),
      "prediction_count" => length(run["predictions"] || []),
      "reconciliation_count" => total,
      "matched_count" => matched,
      "mismatch_count" => max(total - matched, 0),
      "convergence" => convergence,
      "recommendation" => prediction_recommendation(total, convergence),
      "notes" => RuntimeContracts.text(attrs, "notes"),
      "created_at" => Clock.iso_now()
    }
    |> RuntimeContracts.reject_empty()
  end

  defp prediction_recommendation(0, _convergence), do: "record_predictions"
  defp prediction_recommendation(_total, convergence) when convergence >= 1.0, do: "finish"
  defp prediction_recommendation(_total, convergence) when convergence >= 0.67, do: "continue"
  defp prediction_recommendation(_total, convergence) when convergence <= 0.33, do: "zoom_out"
  defp prediction_recommendation(_total, _convergence), do: "strategy_decision"

  defp implementation_gate(%{"risk_level" => risk, "approval_status" => status})
       when risk in ["high", "critical"] and status != "approved",
       do: {:error, :repair_gate_approval_required}

  defp implementation_gate(%{"strategy" => strategy, "architecture_plan" => plan})
       when strategy in ["architecture_refactor", "replacement"] and not is_map(plan),
       do: {:error, :repair_architecture_plan_required}

  defp implementation_gate(%{"strategy" => strategy, "blast_radius_report" => report})
       when strategy in ["multi_file_repair", "architecture_refactor", "replacement"] and
              not is_map(report),
       do: {:error, :repair_blast_radius_required}

  defp implementation_gate(_run), do: :ok

  defp completion_gate(run, final_report) do
    cond do
      not passed_or_waived?(run["original_issue_checks"], final_report["original_issue_waiver"]) ->
        {:error, :repair_original_issue_check_required}

      not passed_or_waived?(run["impact_checks"], final_report["impact_waiver"]) ->
        {:error, :repair_impact_check_required}

      not passed_or_waived?(run["related_issues"], final_report["related_issue_waiver"]) ->
        {:error, :repair_related_issue_sweep_required}

      not prediction_score_satisfied?(run, final_report) ->
        {:error, :repair_prediction_score_required}

      true ->
        :ok
    end
  end

  defp prediction_score_satisfied?(run, final_report) do
    waiver = RuntimeContracts.normalize_map(final_report["prediction_score_waiver"])

    case List.last(run["prediction_scores"] || []) do
      %{"recommendation" => recommendation} when recommendation in ["finish", "continue"] -> true
      _score -> RuntimeContracts.truthy?(waiver["waived"])
    end
  end

  defp passed_or_waived?(checks, waiver) do
    Enum.any?(checks || [], &(&1["status"] == "passed")) or
      RuntimeContracts.truthy?(RuntimeContracts.normalize_map(waiver)["waived"])
  end

  defp final_report(attrs, run) do
    attrs["final_report"]
    |> RuntimeContracts.normalize_map()
    |> Map.put_new("completed_repair_run_id", run["id"])
    |> Map.put_new("created_at", Clock.iso_now())
  end

  defp update_run(run_id, opts, fun) do
    root = Paths.workspace_root(opts)

    with {:ok, run} <- get(run_id, opts) do
      updated =
        run
        |> fun.()
        |> Map.put("updated_at", Clock.iso_now())
        |> normalize_run()

      store(root, upsert(list(workspace: root), updated))

      latest_event = List.last(updated["events"] || [])

      if latest_event,
        do: append_event(root, updated, latest_event["kind"], latest_event["metadata"] || %{})

      {:ok, updated}
    end
  end

  defp upsert(runs, run) do
    if Enum.any?(runs, &(&1["id"] == run["id"])) do
      Enum.map(runs, fn current -> if current["id"] == run["id"], do: run, else: current end)
    else
      runs ++ [run]
    end
  end

  defp store(root, runs), do: JSON.write(path(root), runs)

  defp normalize_run(run) do
    run
    |> RuntimeContracts.string_keys()
    |> Map.put_new("schema_version", @schema_version)
    |> Map.put_new("status", "active")
    |> Map.put_new("phase", "intake")
    |> Map.put_new("risk_level", "low")
    |> Map.put_new("approval_status", "not_required")
    |> Map.update("events", [], &normalize_list/1)
    |> Map.update("hypotheses", [], &normalize_list/1)
    |> Map.update("predictions", [], &normalize_list/1)
    |> Map.update("prediction_scores", [], &normalize_list/1)
    |> Map.update("reconciliations", [], &normalize_list/1)
    |> Map.update("observations", [], &normalize_list/1)
    |> Map.update("research_claims", [], &normalize_list/1)
    |> Map.update("verification_runs", [], &normalize_list/1)
    |> Map.update("original_issue_checks", [], &normalize_list/1)
    |> Map.update("impact_checks", [], &normalize_list/1)
    |> Map.update("related_issues", [], &normalize_list/1)
    |> RuntimeContracts.reject_empty()
  end

  defp append_event(root, run, kind, metadata) do
    JSON.append_jsonl(events_path(root), %{
      "schema_version" => @event_schema_version,
      "id" => Clock.id("repair_event"),
      "repair_run_id" => run["id"],
      "kind" => kind,
      "metadata" => RuntimeContracts.normalize_map(metadata),
      "at" => Clock.iso_now()
    })
  end

  defp append_run_event(run, kind, metadata, now \\ Clock.iso_now()) do
    event = %{
      "id" => Clock.id("repair_run_event"),
      "kind" => kind,
      "metadata" => RuntimeContracts.normalize_map(metadata),
      "at" => now
    }

    Map.update(run, "events", [event], &(&1 ++ [event]))
  end

  defp evented(run, kind, metadata), do: append_run_event(run, kind, metadata)

  defp artifact_event(run, artifact_type, artifact) do
    evented(run, "repair_run.artifact_recorded", %{
      "artifact_type" => artifact_type,
      "artifact_id" => artifact["id"]
    })
  end

  defp append_list(map, key, value), do: Map.update(map, key, [value], &(&1 ++ [value]))

  defp payload(run, action) do
    %{
      "repair_run" => run,
      "text" =>
        "Repair run #{run["id"]} #{action}. Phase=#{run["phase"]}, status=#{run["status"]}, strategy=#{run["strategy"] || "unset"}."
    }
  end

  defp wrap_payload({:ok, run}, action), do: {:ok, payload(run, action)}
  defp wrap_payload(error, _action), do: error

  defp approval_status("high"), do: "required"
  defp approval_status("critical"), do: "required"
  defp approval_status(_risk), do: "not_required"

  defp approval_status(risk, "approved") when risk in ["high", "critical"], do: "approved"
  defp approval_status(risk, _current), do: approval_status(risk)

  defp strategy_phase("human_gate"), do: "approval"
  defp strategy_phase("architecture_refactor"), do: "architecture"
  defp strategy_phase("replacement"), do: "architecture"
  defp strategy_phase(_strategy), do: "strategy"

  defp phase_for_decision("finish"), do: "verification"
  defp phase_for_decision("zoom_out"), do: "related_issue_sweep"
  defp phase_for_decision("refactor"), do: "architecture"
  defp phase_for_decision("ask_human"), do: "approval"
  defp phase_for_decision(_decision), do: "strategy"

  defp explicit_check_status(map, key) do
    cond do
      Map.has_key?(map, "status") and map["status"] in @check_statuses -> map["status"]
      RuntimeContracts.truthy?(map[key]) -> "passed"
      Map.has_key?(map, key) -> "failed"
      true -> "pending"
    end
  end

  defp impact_status(attrs) do
    waiver = RuntimeContracts.normalize_map(attrs["impact_waiver"])
    unexpected = normalize_map_list(attrs["unexpected_change_candidates"])
    protected = normalize_map_list(attrs["protected_flow_results"])
    affected = normalize_map_list(attrs["affected_domain_results"])

    cond do
      RuntimeContracts.truthy?(waiver["waived"]) ->
        "passed"

      Enum.any?(
        unexpected,
        &(&1["status"] == "failed" or RuntimeContracts.truthy?(&1["should_fix_now"]))
      ) ->
        "failed"

      Enum.any?(protected ++ affected, &(&1["status"] == "failed")) ->
        "failed"

      Enum.any?(protected ++ affected, &(&1["status"] == "pending")) ->
        "pending"

      protected ++ affected != [] ->
        "passed"

      true ->
        "pending"
    end
  end

  defp related_issue_status(attrs) do
    cond do
      RuntimeContracts.truthy?(attrs["should_fix_now"]) -> "failed"
      normalize_map_list(attrs["fix_now"]) != [] -> "failed"
      true -> "passed"
    end
  end

  defp record?(%{"record" => false}), do: false
  defp record?(%{"record" => "false"}), do: false
  defp record?(%{"record" => 0}), do: false
  defp record?(_attrs), do: true

  defp enum_text(attrs, key, allowed, default) do
    value = RuntimeContracts.text(attrs, key, default)
    if value in allowed, do: value, else: default
  end

  defp enum_value(attrs, key, allowed, default) do
    value = RuntimeContracts.text(attrs, key, default)

    cond do
      value in [nil, ""] -> {:error, {:required, key}}
      value in allowed -> {:ok, value}
      true -> {:error, {:invalid_enum, key, allowed}}
    end
  end

  defp required_text(attrs, key) do
    case RuntimeContracts.text(attrs, key) do
      nil -> {:error, {:required, key}}
      text -> {:ok, text}
    end
  end

  defp required_boolean(attrs, key) do
    if Map.has_key?(attrs, key) do
      {:ok, RuntimeContracts.truthy?(attrs[key])}
    else
      {:error, {:required, key}}
    end
  end

  defp normalize_map_list(value) when is_list(value) do
    value
    |> Enum.map(&RuntimeContracts.normalize_map/1)
    |> Enum.reject(&(&1 == %{}))
  end

  defp normalize_map_list(_value), do: []

  defp normalize_list(value) when is_list(value),
    do: Enum.map(value, &RuntimeContracts.normalize_value/1)

  defp normalize_list(nil), do: []
  defp normalize_list(value), do: [RuntimeContracts.normalize_value(value)]

  defp draft_key("architecture_plan"), do: "architecture_plan_draft"
  defp draft_key("blast_radius"), do: "blast_radius_draft"
  defp draft_key("original_issue_check"), do: "original_issue_check_draft"
  defp draft_key("related_issue"), do: "related_issue_sweep_draft"
  defp draft_key(type), do: type <> "_draft"

  defp execution_key("original_issue_check"), do: "original_issue_check_execution"
  defp execution_key("impact_check"), do: "impact_check_execution"
  defp execution_key(type), do: type <> "_execution"
end
