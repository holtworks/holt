defmodule Holt.Tasks.AgentDispatch do
  @moduledoc """
  Structured dispatch layer for multi-agent task coordination.

  The dispatch plan decides which agents are eligible for a task event, assigns
  a group-level budget, isolates worker and verifier contexts, shards verifier
  responsibilities, and records anti-stampede controls.
  """

  alias Holt.Clock
  alias Holt.Tasks.WorkGraphBudget

  @schema_version "holt_agent_dispatch/v1"
  @default_max_agents_per_event 4
  @default_cooldown_seconds 60
  @default_forced_decision_turns 6
  @unsupported_keys ~w(agents max_agents token_budget task_id task_ref event_kind source request_id)

  def plan(attrs \\ %{})

  def plan(attrs) when is_map(attrs) do
    case input(attrs) do
      {:ok, input} -> build(input)
      {:error, reason} -> rejected(reason)
    end
  end

  def plan(_attrs), do: rejected("invalid_attrs")

  def selected_agent_ids(%{"selected_agent_ids" => ids}) when is_list(ids) do
    Enum.filter(ids, &nonempty_binary?/1)
  end

  def selected_agent_ids(_dispatch_plan), do: []

  defp input(attrs) do
    with :ok <- canonical_attrs(attrs),
         :ok <- unsupported_arguments(attrs),
         {:ok, task} <- optional_task(attrs),
         {:ok, event} <- optional_event(attrs),
         {:ok, candidates} <- candidate_agents(attrs),
         {:ok, active_ids} <- active_agent_ids(attrs),
         {:ok, max_agents} <- max_agents(attrs),
         {:ok, group_budget} <- group_token_budget(attrs),
         {:ok, work_graph_id} <- optional_text(attrs, "work_graph_id", "invalid_work_graph_id"),
         {:ok, runtime} <- runtime_context(attrs),
         {:ok, cooldown} <- positive_integer(attrs, "cooldown_seconds", @default_cooldown_seconds),
         {:ok, forced_turns} <-
           positive_integer(
             attrs,
             "forced_decision_after_turns",
             @default_forced_decision_turns
           ) do
      {:ok,
       %{
         task: task,
         event: event,
         candidates: candidates,
         active_agent_ids: active_ids,
         max_agents_per_event: max_agents,
         group_token_budget: group_budget,
         work_graph_id: work_graph_id,
         runtime: runtime,
         cooldown_seconds: cooldown,
         forced_decision_after_turns: forced_turns
       }}
    end
  end

  defp build(input) do
    task = input.task
    event = input.event
    candidates = dedupe_candidates(input.candidates)
    active_ids = MapSet.new(input.active_agent_ids)
    max_agents = input.max_agents_per_event
    {selected, suppressed} = select_candidates(candidates, active_ids, max_agents)

    group_budget =
      %{
        "task" => task,
        "candidate_agents" => candidates,
        "max_concurrent_agents" => max_agents
      }
      |> put_optional("work_graph_id", input.work_graph_id)
      |> put_optional("max_total_tokens", input.group_token_budget)
      |> WorkGraphBudget.build()

    %{
      "schema_version" => @schema_version,
      "dispatch_id" =>
        stable_id("dispatch", [
          task["id"],
          event["event_kind"],
          event["request_id"],
          Enum.map(candidates, & &1["agent_id"]),
          max_agents
        ]),
      "task_id" => task["id"],
      "task_ref" => task["ref"],
      "event" => event,
      "event_kind" => event["event_kind"],
      "source" => event["source"],
      "request_id" => event["request_id"],
      "decision" => dispatch_decision(selected),
      "dispatch_decision" => dispatch_decision(selected, suppressed),
      "candidate_agents" => Enum.map(candidates, &candidate_view/1),
      "selected_agents" => selected,
      "selected_agent_ids" => Enum.map(selected, & &1["agent_id"]),
      "suppressed_agents" => suppressed,
      "candidate_count" => length(candidates),
      "selected_count" => length(selected),
      "suppressed_count" => length(suppressed),
      "active_agent_ids" => input.active_agent_ids,
      "max_agents_per_event" => max_agents,
      "group_token_budget" => input.group_token_budget,
      "group_budget" => group_budget,
      "role_isolation" => role_isolation(selected, group_budget),
      "verifier_shards" => verifier_shards(input.runtime),
      "anti_stampede" =>
        anti_stampede(
          task,
          event,
          max_agents,
          input.cooldown_seconds,
          input.forced_decision_after_turns,
          active_ids,
          candidates,
          selected
        ),
      "handoff_contract" => handoff_contract(),
      "created_at" => Clock.iso_now()
    }
    |> compact()
  end

  defp rejected(reason) do
    %{
      "schema_version" => @schema_version,
      "status" => "rejected",
      "reason" => reason,
      "created_at" => Clock.iso_now()
    }
  end

  defp optional_task(attrs) do
    case Map.fetch(attrs, "task") do
      {:ok, task} when is_map(task) ->
        with :ok <- validate_task(task) do
          {:ok, task}
        end

      {:ok, _task} ->
        {:error, "invalid_task"}

      :error ->
        {:ok, %{}}
    end
  end

  defp validate_task(task) do
    with :ok <- optional_text_field(task, "id", "invalid_task"),
         :ok <- optional_text_field(task, "ref", "invalid_task") do
      :ok
    end
  end

  defp optional_event(attrs) do
    case Map.fetch(attrs, "event") do
      {:ok, event} when is_map(event) ->
        validate_event(event)

      {:ok, _event} ->
        {:error, "invalid_event"}

      :error ->
        {:ok, %{"event_kind" => "start_agent_work", "created_at" => Clock.iso_now()}}
    end
  end

  defp validate_event(event) do
    with {:ok, kind} <- optional_text(event, "event_kind", "invalid_event"),
         {:ok, source} <- optional_text(event, "source", "invalid_event"),
         {:ok, request_id} <- optional_text(event, "request_id", "invalid_event"),
         :ok <- optional_text_field(event, "created_at", "invalid_event") do
      {:ok,
       %{
         "event_kind" => event_kind(kind),
         "source" => source,
         "request_id" => request_id,
         "created_at" => event_time(event)
       }
       |> compact()}
    end
  end

  defp event_kind(nil), do: "start_agent_work"
  defp event_kind(kind), do: kind

  defp event_time(%{"created_at" => created_at}), do: created_at
  defp event_time(_event), do: Clock.iso_now()

  defp candidate_agents(attrs) do
    case Map.fetch(attrs, "candidate_agents") do
      {:ok, candidates} when is_list(candidates) ->
        validate_candidates(candidates)

      {:ok, _candidates} ->
        {:error, "invalid_candidate_agents"}

      :error ->
        {:ok, []}
    end
  end

  defp validate_candidates(candidates) do
    Enum.reduce_while(candidates, {:ok, []}, fn candidate, {:ok, acc} ->
      case candidate(candidate) do
        {:ok, candidate} -> {:cont, {:ok, acc ++ [candidate]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp candidate(candidate) when is_map(candidate) do
    with {:ok, agent_id} <- required_text(candidate, "agent_id", "invalid_candidate_agents"),
         {:ok, agent_ref} <- optional_text(candidate, "agent_ref", "invalid_candidate_agents"),
         {:ok, agent_handle} <-
           optional_text(candidate, "agent_handle", "invalid_candidate_agents"),
         {:ok, agent_name} <- optional_text(candidate, "agent_name", "invalid_candidate_agents"),
         {:ok, display_name} <-
           optional_text(candidate, "display_name", "invalid_candidate_agents"),
         {:ok, kind} <- optional_text(candidate, "kind", "invalid_candidate_agents"),
         {:ok, work_role} <- optional_text(candidate, "work_role", "invalid_candidate_agents"),
         {:ok, status} <- optional_text(candidate, "status", "invalid_candidate_agents"),
         {:ok, lifecycle} <-
           optional_text(candidate, "lifecycle_state", "invalid_candidate_agents"),
         :ok <- optional_string_list(candidate, "work_roles", "invalid_candidate_agents"),
         :ok <- optional_list(candidate, "skills", "invalid_candidate_agents"),
         :ok <- optional_map_field(candidate, "agent_card", "invalid_candidate_agents"),
         {:ok, model} <- optional_text(candidate, "model", "invalid_candidate_agents"),
         {:ok, provider} <- optional_text(candidate, "provider", "invalid_candidate_agents") do
      {:ok,
       %{
         "id" => agent_id,
         "agent_id" => agent_id,
         "agent_ref" => agent_ref,
         "agent_handle" => agent_handle,
         "agent_name" => agent_name,
         "display_name" => display_name,
         "kind" => kind,
         "work_role" => work_role,
         "work_roles" => candidate["work_roles"],
         "status" => status,
         "lifecycle_state" => lifecycle,
         "skills" => candidate["skills"],
         "model" => model,
         "provider" => provider,
         "agent_card" => candidate["agent_card"],
         "eligibility" => "candidate"
       }
       |> default_candidate_fields()
       |> compact()}
    end
  end

  defp candidate(_candidate), do: {:error, "invalid_candidate_agents"}

  defp default_candidate_fields(candidate) do
    candidate
    |> put_default("display_name", candidate["agent_id"])
    |> put_default("kind", "agent")
    |> put_default("work_role", "worker")
  end

  defp dedupe_candidates(candidates) do
    candidates
    |> Enum.reduce({MapSet.new(), []}, fn candidate, {seen, acc} ->
      agent_id = candidate["agent_id"]

      case MapSet.member?(seen, agent_id) do
        true -> {seen, acc}
        false -> {MapSet.put(seen, agent_id), acc ++ [candidate]}
      end
    end)
    |> elem(1)
  end

  defp active_agent_ids(attrs) do
    case Map.fetch(attrs, "active_agent_ids") do
      {:ok, ids} when is_list(ids) ->
        case Enum.all?(ids, &nonempty_binary?/1) do
          true -> {:ok, ids}
          false -> {:error, "invalid_active_agent_ids"}
        end

      {:ok, _ids} ->
        {:error, "invalid_active_agent_ids"}

      :error ->
        {:ok, []}
    end
  end

  defp max_agents(attrs) do
    positive_integer(attrs, "max_agents_per_event", @default_max_agents_per_event)
  end

  defp group_token_budget(attrs) do
    case Map.fetch(attrs, "group_token_budget") do
      {:ok, value} when is_integer(value) and value > 0 -> {:ok, value}
      {:ok, _value} -> {:error, "invalid_group_token_budget"}
      :error -> {:ok, nil}
    end
  end

  defp runtime_context(attrs) do
    with {:ok, machine_db_id} <- optional_text(attrs, "machine_db_id", "invalid_machine_db_id"),
         {:ok, groups} <- optional_string_list_value(attrs, "enabled_action_groups") do
      {:ok, %{"machine_db_id" => machine_db_id, "enabled_action_groups" => groups} |> compact()}
    end
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
      "agent_name" => candidate["agent_name"],
      "display_name" => candidate["display_name"],
      "agent_ref" => candidate["agent_ref"],
      "agent_handle" => candidate["agent_handle"],
      "work_role" => candidate["work_role"],
      "dispatch_status" => "suppressed",
      "suppression_reason" => reason,
      "reason" => reason
    }
    |> compact()
  end

  defp dispatch_decision([]), do: "suppressed"
  defp dispatch_decision(_selected), do: "selected"

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
    |> compact()
  end

  defp verifier_shards(runtime) do
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

    case runtime_verification_required?(runtime) do
      true ->
        base ++
          [
            shard(
              "integration",
              "runtime_or_external_system_state",
              ~w(get_task list_task_specs get_task_spec read_task_memory_artifact)
            )
          ]

      false ->
        base
    end
  end

  defp shard(shard_id, jurisdiction, actions) do
    %{
      "shard_id" => shard_id,
      "jurisdiction" => jurisdiction,
      "isolated_context" => true,
      "read_only" => true,
      "allowed_actions" => actions,
      "required_output" => "pass_fail_with_evidence_refs"
    }
  end

  defp runtime_verification_required?(%{"machine_db_id" => machine_db_id})
       when is_binary(machine_db_id),
       do: true

  defp runtime_verification_required?(%{"enabled_action_groups" => groups}) when groups != [],
    do: true

  defp runtime_verification_required?(_runtime), do: false

  defp anti_stampede(
         task,
         event,
         max_agents,
         cooldown,
         forced_turns,
         active_ids,
         candidates,
         selected
       ) do
    %{
      "max_agents_per_event" => max_agents,
      "cooldown_seconds" => cooldown,
      "forced_decision_after_turns" => forced_turns,
      "dedupe_key" =>
        stable_id("dispatch_dedupe", [
          task["id"],
          event["event_kind"],
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

  defp candidate_view(candidate) do
    %{
      "id" => candidate["agent_id"],
      "agent_id" => candidate["agent_id"],
      "agent_ref" => candidate["agent_ref"],
      "agent_handle" => candidate["agent_handle"],
      "display_name" => candidate["display_name"],
      "kind" => candidate["kind"],
      "work_role" => candidate["work_role"],
      "status" => candidate["status"],
      "lifecycle_state" => candidate["lifecycle_state"],
      "skills" => candidate["skills"],
      "agent_card" => candidate["agent_card"]
    }
    |> compact()
  end

  defp positive_integer(attrs, key, default) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_integer(value) and value > 0 -> {:ok, value}
      {:ok, _value} -> {:error, "invalid_" <> key}
      :error -> {:ok, default}
    end
  end

  defp optional_string_list_value(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, values} when is_list(values) ->
        case Enum.all?(values, &nonempty_binary?/1) do
          true -> {:ok, values}
          false -> {:error, "invalid_" <> key}
        end

      {:ok, _values} ->
        {:error, "invalid_" <> key}

      :error ->
        {:ok, []}
    end
  end

  defp required_text(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, reason}
          text -> {:ok, text}
        end

      {:ok, _value} ->
        {:error, reason}

      :error ->
        {:error, reason}
    end
  end

  defp optional_text(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, reason}
          text -> {:ok, text}
        end

      {:ok, _value} ->
        {:error, reason}

      :error ->
        {:ok, nil}
    end
  end

  defp optional_text_field(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, reason}
          _text -> :ok
        end

      {:ok, _value} ->
        {:error, reason}

      :error ->
        :ok
    end
  end

  defp optional_string_list(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, values} when is_list(values) ->
        case Enum.all?(values, &nonempty_binary?/1) do
          true -> :ok
          false -> {:error, reason}
        end

      {:ok, _values} ->
        {:error, reason}

      :error ->
        :ok
    end
  end

  defp optional_list(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, values} when is_list(values) -> :ok
      {:ok, _values} -> {:error, reason}
      :error -> :ok
    end
  end

  defp optional_map_field(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, value} when is_map(value) -> :ok
      {:ok, _value} -> {:error, reason}
      :error -> :ok
    end
  end

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp put_default(map, key, value) do
    case Map.fetch(map, key) do
      {:ok, present} when present not in [nil, ""] -> map
      _missing -> Map.put(map, key, value)
    end
  end

  defp unsupported_arguments(attrs) do
    attrs
    |> Map.keys()
    |> Enum.find(&unsupported_key?/1)
    |> unsupported_key_error()
  end

  defp unsupported_key?(key), do: key in @unsupported_keys

  defp unsupported_key_error(nil), do: :ok
  defp unsupported_key_error(key), do: {:error, "unsupported_argument:" <> key}

  defp canonical_attrs(attrs) do
    case canonical_value?(attrs) do
      true -> :ok
      false -> {:error, "invalid_attrs"}
    end
  end

  defp canonical_value?(value) when is_map(value) do
    Enum.all?(value, fn
      {key, nested} when is_binary(key) -> canonical_value?(nested)
      _entry -> false
    end)
  end

  defp canonical_value?(values) when is_list(values), do: Enum.all?(values, &canonical_value?/1)
  defp canonical_value?(_value), do: true

  defp nonempty_binary?(value) when is_binary(value), do: String.trim(value) != ""
  defp nonempty_binary?(_value), do: false

  defp compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end

  defp stable_id(prefix, parts) do
    digest =
      :crypto.hash(:sha256, :erlang.term_to_binary(parts))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 24)

    "#{prefix}_#{digest}"
  end
end
