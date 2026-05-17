defmodule HoltWorks.Tasks.AgentDispatch do
  @moduledoc """
  Structured dispatch layer for multi-agent task coordination.

  The dispatch plan decides which agents are eligible for a task event, assigns
  a group-level budget, isolates worker and verifier contexts, shards verifier
  responsibilities, and records anti-stampede controls.
  """

  alias HoltWorks.{Clock}
  alias HoltWorks.Tasks.{RuntimeContracts, WorkGraphBudget}

  @schema_version "holtworks_agent_dispatch/v1"
  @default_max_agents_per_event 4
  @default_cooldown_seconds 60
  @default_forced_decision_turns 6

  def plan(attrs \\ %{})

  def plan(attrs) when is_map(attrs) do
    attrs = RuntimeContracts.string_keys(attrs)
    task = RuntimeContracts.normalize_map(attrs["task"])
    task_id = RuntimeContracts.text(attrs, "task_id", task["id"])
    candidates = normalize_candidates(attrs["candidate_agents"] || attrs["agents"])
    active_ids = MapSet.new(RuntimeContracts.normalize_string_list(attrs["active_agent_ids"]))
    max_agents = max_agents_per_event(attrs)
    {selected, suppressed} = select_candidates(candidates, active_ids, max_agents)
    event = normalize_event(attrs)

    group_budget =
      WorkGraphBudget.build(%{
        "task" => task,
        "task_id" => task_id,
        "task_ref" => RuntimeContracts.text(attrs, "task_ref", task["ref"]),
        "work_graph_id" => RuntimeContracts.value(attrs, "work_graph_id"),
        "candidate_agents" => candidates,
        "max_concurrent_agents" => max_agents,
        "token_budget" => attrs["group_token_budget"] || attrs["token_budget"]
      })

    %{
      "schema_version" => @schema_version,
      "dispatch_id" =>
        RuntimeContracts.stable_id("dispatch", [
          task_id,
          event["event_kind"],
          event["request_id"],
          Enum.map(candidates, & &1["agent_id"]),
          max_agents
        ]),
      "task_id" => task_id,
      "task_ref" => RuntimeContracts.text(attrs, "task_ref", task["ref"]),
      "event" => event,
      "event_kind" => event["event_kind"],
      "source" => event["source"],
      "request_id" => event["request_id"],
      "decision" => legacy_decision(selected),
      "dispatch_decision" => dispatch_decision(selected, suppressed),
      "candidate_agents" => Enum.map(candidates, &candidate_for_legacy/1),
      "selected_agents" => selected,
      "selected_agent_ids" => Enum.map(selected, & &1["agent_id"]),
      "suppressed_agents" => suppressed,
      "candidate_count" => length(candidates),
      "selected_count" => length(selected),
      "suppressed_count" => length(suppressed),
      "active_agent_ids" => RuntimeContracts.normalize_string_list(attrs["active_agent_ids"]),
      "max_agents_per_event" => max_agents,
      "group_token_budget" => attrs["group_token_budget"] || attrs["token_budget"],
      "group_budget" => group_budget,
      "role_isolation" => role_isolation(selected, group_budget),
      "verifier_shards" => verifier_shards(attrs),
      "anti_stampede" => anti_stampede(attrs, max_agents, active_ids, candidates, selected),
      "handoff_contract" => handoff_contract(),
      "created_at" => Clock.iso_now()
    }
    |> RuntimeContracts.reject_empty()
  end

  def plan(_attrs), do: plan(%{})

  def selected_agent_ids(dispatch_plan) when is_map(dispatch_plan) do
    dispatch_plan
    |> RuntimeContracts.value("selected_agent_ids")
    |> RuntimeContracts.normalize_string_list()
  end

  def selected_agent_ids(_dispatch_plan), do: []

  defp normalize_event(attrs) do
    explicit = RuntimeContracts.normalize_map(attrs["event"])

    %{
      "event_kind" =>
        RuntimeContracts.text(
          explicit,
          "event_kind",
          RuntimeContracts.text(attrs, "event_kind", "start_agent_work")
        ),
      "source" =>
        RuntimeContracts.text(explicit, "source", RuntimeContracts.text(attrs, "source")),
      "request_id" =>
        RuntimeContracts.text(explicit, "request_id", RuntimeContracts.text(attrs, "request_id")),
      "created_at" => Clock.iso_now()
    }
    |> RuntimeContracts.reject_empty()
  end

  defp normalize_candidates(candidates) when is_list(candidates) do
    candidates
    |> Enum.map(&candidate_summary/1)
    |> Enum.reject(&(not present?(&1["agent_id"])))
    |> dedupe_candidates()
  end

  defp normalize_candidates(_candidates), do: []

  defp candidate_summary(candidate) when is_map(candidate) do
    candidate = RuntimeContracts.string_keys(candidate)
    agent_id = first_present([candidate["agent_id"], candidate["id"], candidate["agent_ref"]])

    %{
      "id" => agent_id,
      "agent_id" => agent_id,
      "agent_ref" => candidate["agent_ref"] || candidate["ref"],
      "agent_handle" => candidate["agent_handle"] || candidate["handle"],
      "agent_name" => candidate["agent_name"] || candidate["display_name"] || candidate["name"],
      "display_name" =>
        candidate["display_name"] || candidate["agent_name"] || candidate["name"] || agent_id,
      "kind" => candidate["kind"] || "agent",
      "work_role" => candidate["work_role"] || "worker",
      "work_roles" => candidate["work_roles"],
      "status" => candidate["status"],
      "lifecycle_state" => candidate["lifecycle_state"],
      "skills" => candidate["skills"],
      "model" => candidate["model"],
      "provider" => candidate["provider"],
      "agent_card" => candidate["agent_card"],
      "eligibility" => "candidate"
    }
    |> RuntimeContracts.reject_empty()
  end

  defp candidate_summary(candidate) when is_binary(candidate) do
    %{
      "id" => candidate,
      "agent_id" => candidate,
      "display_name" => candidate,
      "kind" => "agent",
      "work_role" => "worker",
      "eligibility" => "candidate"
    }
  end

  defp candidate_summary(_candidate), do: %{}

  defp dedupe_candidates(candidates) do
    candidates
    |> Enum.reduce({MapSet.new(), []}, fn candidate, {seen, acc} ->
      agent_id = candidate["agent_id"]

      if MapSet.member?(seen, agent_id) do
        {seen, acc}
      else
        {MapSet.put(seen, agent_id), acc ++ [candidate]}
      end
    end)
    |> elem(1)
  end

  defp select_candidates(candidates, active_ids, max_agents) do
    {active, idle} =
      Enum.split_with(candidates, fn candidate ->
        MapSet.member?(active_ids, candidate["agent_id"])
      end)

    {selected, overflow} = Enum.split(idle, max_agents)

    selected =
      Enum.map(selected, fn candidate ->
        candidate
        |> Map.put("dispatch_status", "selected")
        |> Map.put("context_partition", "worker:#{candidate["agent_id"]}")
      end)

    suppressed_active = Enum.map(active, &suppress_candidate(&1, "agent_work_already_active"))
    suppressed_overflow = Enum.map(overflow, &suppress_candidate(&1, "dispatch_cap_reached"))

    {selected, suppressed_active ++ suppressed_overflow}
  end

  defp suppress_candidate(candidate, reason) do
    %{
      "agent_id" => candidate["agent_id"],
      "agent_name" => candidate["agent_name"] || candidate["display_name"],
      "agent_ref" => candidate["agent_ref"],
      "agent_handle" => candidate["agent_handle"],
      "work_role" => candidate["work_role"],
      "dispatch_status" => "suppressed",
      "suppression_reason" => reason,
      "reason" => reason
    }
    |> RuntimeContracts.reject_empty()
  end

  defp legacy_decision([]), do: "suppressed"
  defp legacy_decision(_selected), do: "selected"

  defp dispatch_decision([], _suppressed), do: "suppress"
  defp dispatch_decision(_selected, []), do: "dispatch"
  defp dispatch_decision(_selected, _suppressed), do: "partial_dispatch"

  defp role_isolation(selected, group_budget) do
    %{
      "shared_chat" => false,
      "worker_contexts" =>
        Enum.map(selected, fn agent ->
          %{
            "agent_id" => agent["agent_id"],
            "context_partition" => agent["context_partition"],
            "can_mutate" => true,
            "can_verify_own_work" => false
          }
        end),
      "verifier_context" => %{
        "can_mutate" => false,
        "receives_worker_scratchpad" => false,
        "receives_artifact_refs" => true,
        "required_independence" => "not_selected_worker"
      },
      "judge_context" => %{
        "can_mutate" => false,
        "receives_verifier_outputs" => true,
        "receives_worker_scratchpad" => false
      },
      "context_budget_id" => group_budget["budget_id"]
    }
    |> RuntimeContracts.reject_empty()
  end

  defp verifier_shards(attrs) do
    base = [
      shard(
        "evidence",
        "artifact_and_claim_evidence",
        ~w(get_task list_task_specs get_task_spec read_task_memory_artifact)
      ),
      shard("policy", "policy_and_permission_compliance", ~w(get_task load_teammate_runtime)),
      shard(
        "outcome",
        "objective_completion_and_user_visible_outcome",
        ~w(get_task list_task_specs get_task_spec)
      )
    ]

    if runtime_verification_required?(attrs) do
      base ++
        [
          shard(
            "integration",
            "runtime_or_external_system_state",
            ~w(get_task list_task_specs get_task_spec read_task_memory_artifact)
          )
        ]
    else
      base
    end
  end

  defp shard(shard_id, jurisdiction, tools) do
    %{
      "shard_id" => shard_id,
      "jurisdiction" => jurisdiction,
      "isolated_context" => true,
      "read_only" => true,
      "allowed_tools" => tools,
      "required_output" => "pass_fail_with_evidence_refs"
    }
  end

  defp runtime_verification_required?(attrs) do
    RuntimeContracts.value(attrs, "machine_db_id") not in [nil, ""] or
      RuntimeContracts.normalize_string_list(attrs["enabled_toolkits"]) != []
  end

  defp anti_stampede(attrs, max_agents, active_ids, candidates, selected) do
    %{
      "max_agents_per_event" => max_agents,
      "cooldown_seconds" =>
        positive_integer(attrs["cooldown_seconds"], @default_cooldown_seconds),
      "forced_decision_after_turns" =>
        positive_integer(attrs["forced_decision_after_turns"], @default_forced_decision_turns),
      "dedupe_key" =>
        RuntimeContracts.stable_id("dispatch_dedupe", [
          attrs["task_id"],
          attrs["event_kind"],
          Enum.map(candidates, & &1["agent_id"])
        ]),
      "active_agent_count" => MapSet.size(active_ids),
      "selected_agent_count" => length(selected),
      "candidate_agent_count" => length(candidates),
      "loop_policy" => %{
        "defer_to_human_when_no_selected_agents" => true,
        "suppress_agents_already_active" => true,
        "overflow_reason_code" => "dispatch_cap_reached"
      }
    }
  end

  defp handoff_contract do
    %{
      "artifact_kind" => "handoff",
      "required_fields" => [
        "objective",
        "actions_taken",
        "evidence_refs",
        "verification_status",
        "known_risks",
        "next_step"
      ],
      "handoff_scope" => "task_agent_run"
    }
  end

  defp max_agents_per_event(attrs) do
    positive_integer(
      attrs["max_agents_per_event"] || attrs["max_agents"],
      @default_max_agents_per_event
    )
  end

  defp positive_integer(value, _fallback) when is_integer(value) and value > 0, do: value

  defp positive_integer(value, fallback) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} when int > 0 -> int
      _other -> fallback
    end
  end

  defp positive_integer(_value, fallback), do: fallback

  defp candidate_for_legacy(candidate) do
    %{
      "id" => candidate["agent_id"],
      "agent_id" => candidate["agent_id"],
      "agent_ref" => candidate["agent_ref"],
      "agent_handle" => candidate["agent_handle"],
      "display_name" => candidate["display_name"] || candidate["agent_name"],
      "kind" => candidate["kind"],
      "work_role" => candidate["work_role"],
      "status" => candidate["status"],
      "lifecycle_state" => candidate["lifecycle_state"],
      "skills" => candidate["skills"],
      "agent_card" => candidate["agent_card"]
    }
    |> RuntimeContracts.reject_empty()
  end

  defp first_present(values) do
    values
    |> Enum.map(&normalize_text/1)
    |> Enum.find(& &1)
  end

  defp present?(value), do: normalize_text(value) not in [nil, ""]

  defp normalize_text(nil), do: nil

  defp normalize_text(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      text -> text
    end
  end
end
