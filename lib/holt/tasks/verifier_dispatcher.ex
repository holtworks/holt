defmodule Holt.Tasks.VerifierDispatcher do
  @moduledoc """
  Local verifier dispatch contract for task-agent work.

  Holt does not start Phoenix agent sessions here. The dispatcher claims a
  verifier assignment, builds the bounded child-agent job packet, and returns
  `start_agent_work_params` for the existing local task-agent API.
  """

  alias Holt.Clock
  alias Holt.Tasks.ChildAgentContract

  @schema_version "holt_verifier_dispatch/v1"
  @started_schema_version "holt_verifier_dispatch_started/v1"
  @default_lease_ms 35 * 60 * 1_000
  @default_max_attempts 3
  @dispatcher_source "verifier_dispatcher"
  @obsolete_build_keys ~w(assignment route)
  @execution_modes ~w(persisted_agent ephemeral_sub_agent)
  @base_verifier_actions ~w(
    get_task list_task_specs get_task_spec read_task_memory_artifact
    load_teammate_runtime route_verification_review
  )

  def build(attrs \\ %{})

  def build(attrs) when is_map(attrs) do
    case input(attrs) do
      {:ok, input} -> build_dispatch(input)
      {:error, reason} -> rejected_dispatch(reason)
    end
  end

  def build(_attrs), do: rejected_dispatch("invalid_attrs")

  defp input(attrs) do
    with :ok <- canonical_attrs(attrs),
         :ok <- reject_obsolete_keys(attrs),
         {:ok, task} <- required_task(attrs),
         {:ok, work_graph} <- required_work_graph(attrs),
         {:ok, work_graph_gate} <- work_graph_gate_field(attrs),
         {:ok, verification_contract} <- verification_contract_field(attrs),
         {:ok, assignment} <- verifier_assignment_field(attrs),
         {:ok, selected_verifier} <- selected_verifier_field(assignment),
         {:ok, evidence_contract} <- evidence_contract_field(attrs),
         {:ok, route} <- route_field(attrs),
         {:ok, attempt} <- positive_integer(attrs, "attempt", 1, "invalid_attempt"),
         {:ok, max_attempts} <-
           positive_integer(attrs, "max_attempts", @default_max_attempts, "invalid_max_attempts"),
         {:ok, lease_ms} <-
           positive_integer(attrs, "lease_ms", @default_lease_ms, "invalid_lease_ms") do
      {:ok,
       %{
         task: task,
         work_graph: work_graph,
         work_graph_gate: work_graph_gate,
         verification_contract: verification_contract,
         assignment: assignment,
         selected_verifier: selected_verifier,
         evidence_contract: evidence_contract,
         route: route,
         attempt: attempt,
         max_attempts: max_attempts,
         lease_ms: lease_ms
       }}
    end
  end

  defp build_dispatch(input) do
    cond do
      idle_verification?(input.verification_contract, input.work_graph_gate) ->
        idle_dispatch(input)

      is_nil(input.selected_verifier) ->
        blocked_dispatch(input)

      true ->
        claimed_dispatch(input)
    end
  end

  defp rejected_dispatch(reason) do
    %{
      "schema_version" => @schema_version,
      "status" => "rejected",
      "reason" => reason,
      "created_at" => Clock.iso_now()
    }
  end

  defp idle_dispatch(input) do
    %{
      "schema_version" => @schema_version,
      "dispatch_id" =>
        stable_id("verifier_dispatch", [
          input.task["id"],
          input.work_graph["graph_id"],
          input.work_graph_gate["status"],
          "idle"
        ]),
      "status" => "idle",
      "reason" => "verification_not_required",
      "task_id" => input.task["id"],
      "task_ref" => input.task["ref"],
      "work_graph_id" => input.work_graph["graph_id"],
      "work_graph_gate_status" => input.work_graph_gate["status"],
      "created_at" => Clock.iso_now()
    }
    |> compact()
  end

  defp blocked_dispatch(input) do
    %{
      "schema_version" => @schema_version,
      "dispatch_id" =>
        stable_id("verifier_dispatch", [
          input.task["id"],
          input.work_graph["graph_id"],
          input.assignment["assignment_id"],
          "blocked"
        ]),
      "status" => "blocked",
      "reason" => blocked_reason(input.assignment),
      "task_id" => input.task["id"],
      "task_ref" => input.task["ref"],
      "work_graph_id" => input.work_graph["graph_id"],
      "verifier_assignment_id" => input.assignment["assignment_id"],
      "assignment_result" => input.assignment["assignment_result"],
      "created_at" => Clock.iso_now()
    }
    |> compact()
  end

  defp claimed_dispatch(input) do
    now = Clock.now()
    route_id = route_id(input.route, input.assignment)
    child_contract = child_agent_contract(input, route_id)
    lease_expires_at = DateTime.add(now, input.lease_ms, :millisecond)
    child_session_id = child_session_id(input.task, input.work_graph, route_id)
    allowed_actions = allowed_actions(child_contract, input.evidence_contract)
    start_params = start_agent_work_params(input, route_id, child_session_id)

    %{
      "schema_version" => @schema_version,
      "dispatch_id" =>
        stable_id("verifier_dispatch", [
          input.task["id"],
          input.work_graph["graph_id"],
          input.assignment["assignment_id"],
          route_id,
          input.attempt
        ]),
      "status" => "claimed",
      "source" => @dispatcher_source,
      "task_id" => input.task["id"],
      "task_ref" => input.task["ref"],
      "work_graph_id" => input.work_graph["graph_id"],
      "work_graph_gate_status" => input.work_graph_gate["status"],
      "route_id" => route_id,
      "attempt" => input.attempt,
      "max_attempts" => input.max_attempts,
      "claimed_at" => DateTime.to_iso8601(now),
      "lease_expires_at" => DateTime.to_iso8601(lease_expires_at),
      "lease_ms" => input.lease_ms,
      "child_session_id" => child_session_id,
      "target_agent_id" => input.selected_verifier["agent_id"],
      "target_agent_ref" => input.selected_verifier["agent_ref"],
      "target_agent_handle" => input.selected_verifier["handle"],
      "execution_mode" => input.selected_verifier["execution_mode"],
      "verifier_assignment_id" => input.assignment["assignment_id"],
      "assignment_result" => input.assignment["assignment_result"],
      "allowed_actions" => allowed_actions,
      "evidence_contract" => input.evidence_contract,
      "child_agent_contract" => child_contract,
      "start_agent_work_params" => start_params,
      "started_event" =>
        started_event(route_id, input.attempt, child_session_id, child_contract, allowed_actions),
      "permissions" => verifier_permissions(allowed_actions),
      "dispatch_mode" => "manual_start_agent_work",
      "created_at" => Clock.iso_now()
    }
    |> compact()
  end

  defp child_agent_contract(input, _route_id) do
    ChildAgentContract.build(%{
      "action" => "start_agent_work",
      "task" => input.task,
      "evidence_contract" => input.evidence_contract,
      "context" => %{
        "task_id" => input.task["id"],
        "task_ref" => input.task["ref"],
        "agent_id" => input.selected_verifier["agent_id"],
        "run_id" => input.work_graph["graph_id"]
      },
      "arguments" => %{
        "child_ref" => input.selected_verifier["agent_id"],
        "target_agent_id" => input.selected_verifier["agent_id"],
        "work_role" => "verifier",
        "allowed_actions" => allowed_actions(%{}, input.evidence_contract),
        "expected_output_artifacts" => ["verification_report"],
        "validation_contract" =>
          "Submit route_verification_review against the evidence contract.",
        "instructions" =>
          verifier_instructions(input.assignment, input.work_graph, input.evidence_contract)
      }
    })
  end

  defp start_agent_work_params(input, route_id, child_session_id) do
    %{
      "task_id" => input.task["ref"],
      "graph_id" => input.work_graph["task_graph_id"],
      "node_key" => "verify",
      "agent_ids" => verifier_agent_ids(input.selected_verifier),
      "source" => @dispatcher_source,
      "request_id" => route_id,
      "verifier_route_id" => route_id,
      "child_session_id" => child_session_id,
      "message" =>
        verifier_message(input.task, input.work_graph, route_id, input.evidence_contract)
    }
    |> compact()
  end

  defp verifier_agent_ids(%{"execution_mode" => "persisted_agent", "agent_id" => agent_id}),
    do: [agent_id]

  defp verifier_agent_ids(_selected_verifier), do: []

  defp verifier_message(task, work_graph, route_id, evidence_contract) do
    required_groups =
      evidence_contract
      |> Map.get("required_check_groups", [])
      |> Enum.map(fn group ->
        "#{group["group_id"]}: #{Enum.join(group["any_of"], ", ")}"
      end)
      |> case do
        [] -> "none"
        rows -> Enum.join(rows, "; ")
      end

    """
    Verify task #{task["ref"]} before integration.

    Verifier route: #{route_id}
    Work graph: #{work_graph["graph_id"]}
    Required check groups: #{required_groups}

    Inspect task artifacts and worker handoff evidence. Submit route_verification_review with structured checks, changed_files, evidence, and surface statuses. Do not mark the parent task done directly.
    """
    |> String.trim()
  end

  defp verifier_instructions(assignment, work_graph, evidence_contract) do
    """
    Inspect the assigned work graph before integration.

    Assignment: #{assignment["assignment_id"]}
    Work product: #{work_product_ref(assignment, work_graph)}
    Evidence contract: #{Jason.encode!(evidence_contract)}

    Return a structured verification report through route_verification_review.
    """
    |> String.trim()
  end

  defp started_event(route_id, attempt, child_session_id, child_contract, allowed_actions) do
    %{
      "schema_version" => @started_schema_version,
      "status" => "claimed",
      "route_id" => route_id,
      "attempt" => attempt,
      "child_contract_id" => child_contract["child_contract_id"],
      "child_session_id" => child_session_id,
      "allowed_actions" => allowed_actions,
      "source" => @dispatcher_source
    }
    |> compact()
  end

  defp verifier_permissions(actions) do
    %{
      "action_policy" => "allowlist",
      "action_list" => actions,
      "always_allowed" => Enum.uniq(["ask" | actions]),
      "approval_mode" => "auto_approve_read_only",
      "file_write" => "blocked",
      "destructive_command" => "blocked",
      "may_mark_parent_done" => false,
      "may_delegate_further" => false
    }
  end

  defp allowed_actions(child_contract, evidence_contract) do
    contract_actions =
      child_contract
      |> Map.get("job_contract", %{})
      |> Map.get("allowed_actions", [])

    evidence_actions = Map.get(evidence_contract, "allowed_verifier_actions", [])

    (@base_verifier_actions ++ contract_actions ++ evidence_actions)
    |> Enum.uniq()
  end

  defp child_session_id(task, work_graph, route_id) do
    ["verifier", task["ref"], work_graph["graph_id"], route_id]
    |> Enum.join(":")
  end

  defp idle_verification?(%{"required" => false}, _work_graph_gate), do: true
  defp idle_verification?(_verification_contract, %{"can_finish" => true}), do: true
  defp idle_verification?(_verification_contract, _work_graph_gate), do: false

  defp blocked_reason(%{"reason" => reason}) when is_binary(reason) and reason != "",
    do: reason

  defp blocked_reason(_assignment), do: "verifier_assignment_missing"

  defp route_id(%{"route_id" => route_id}, _assignment), do: route_id

  defp route_id(_route, assignment),
    do: stable_id("verifier_route", [assignment["assignment_id"]])

  defp work_product_ref(%{"work_product_ref" => ref}, _work_graph)
       when is_binary(ref) and ref != "",
       do: ref

  defp work_product_ref(_assignment, work_graph), do: work_graph["graph_id"]

  defp required_task(attrs) do
    with {:ok, task} <- required_map(attrs, "task", "invalid_task"),
         {:ok, id} <- required_text(task, "id", "invalid_task"),
         {:ok, ref} <- required_text(task, "ref", "invalid_task") do
      {:ok, task |> Map.put("id", id) |> Map.put("ref", ref)}
    end
  end

  defp required_work_graph(attrs) do
    with {:ok, work_graph} <- required_map(attrs, "work_graph", "invalid_work_graph"),
         {:ok, graph_id} <- required_text(work_graph, "graph_id", "invalid_work_graph"),
         {:ok, work_graph} <-
           optional_text_field(work_graph, "task_graph_id", "invalid_work_graph") do
      {:ok, Map.put(work_graph, "graph_id", graph_id)}
    end
  end

  defp work_graph_gate_field(attrs) do
    with {:ok, gate} <- optional_map(attrs, "work_graph_gate", "invalid_work_graph_gate"),
         {:ok, gate} <- optional_text_field(gate, "status", "invalid_work_graph_gate"),
         {:ok, gate} <- optional_boolean_field(gate, "can_finish", "invalid_work_graph_gate") do
      {:ok, gate}
    end
  end

  defp verification_contract_field(attrs) do
    with {:ok, contract} <-
           optional_map(attrs, "verification_contract", "invalid_verification_contract"),
         {:ok, contract} <-
           optional_boolean_field(contract, "required", "invalid_verification_contract") do
      {:ok, contract}
    end
  end

  defp verifier_assignment_field(attrs) do
    with {:ok, assignment} <-
           optional_map(attrs, "verifier_assignment", "invalid_verifier_assignment"),
         {:ok, assignment} <-
           optional_text_field(assignment, "assignment_id", "invalid_verifier_assignment"),
         {:ok, assignment} <-
           optional_text_field(assignment, "assignment_result", "invalid_verifier_assignment"),
         {:ok, assignment} <-
           optional_text_field(assignment, "work_product_ref", "invalid_verifier_assignment") do
      {:ok, assignment}
    end
  end

  defp selected_verifier_field(assignment) do
    case Map.fetch(assignment, "selected_verifier") do
      {:ok, value} when is_map(value) and value == %{} -> {:ok, nil}
      {:ok, value} when is_map(value) -> selected_verifier(value)
      {:ok, _value} -> {:error, "invalid_verifier_assignment"}
      :error -> {:ok, nil}
    end
  end

  defp selected_verifier(verifier) do
    with {:ok, agent_id} <- required_text(verifier, "agent_id", "invalid_verifier_assignment"),
         {:ok, execution_mode} <-
           required_enum(
             verifier,
             "execution_mode",
             @execution_modes,
             "invalid_verifier_assignment"
           ),
         {:ok, verifier} <-
           optional_text_field(verifier, "agent_ref", "invalid_verifier_assignment"),
         {:ok, verifier} <- optional_text_field(verifier, "handle", "invalid_verifier_assignment"),
         {:ok, verifier} <- optional_text_field(verifier, "name", "invalid_verifier_assignment") do
      {:ok,
       verifier
       |> Map.put("agent_id", agent_id)
       |> Map.put("execution_mode", execution_mode)
       |> compact()}
    end
  end

  defp evidence_contract_field(attrs) do
    with {:ok, evidence_contract} <-
           optional_map(attrs, "evidence_contract", "invalid_evidence_contract"),
         {:ok, actions} <-
           optional_string_list(
             evidence_contract,
             "allowed_verifier_actions",
             "invalid_evidence_contract"
           ),
         {:ok, groups} <- required_check_groups(evidence_contract) do
      {:ok,
       evidence_contract
       |> Map.put("allowed_verifier_actions", actions)
       |> Map.put("required_check_groups", groups)
       |> compact()}
    end
  end

  defp route_field(attrs) do
    with {:ok, route} <- optional_map(attrs, "verifier_route", "invalid_verifier_route"),
         {:ok, route} <- optional_text_field(route, "route_id", "invalid_verifier_route") do
      {:ok, route}
    end
  end

  defp required_check_groups(evidence_contract) do
    case Map.fetch(evidence_contract, "required_check_groups") do
      {:ok, groups} when is_list(groups) -> check_groups(groups)
      {:ok, _groups} -> {:error, "invalid_evidence_contract"}
      :error -> {:ok, []}
    end
  end

  defp check_groups(groups) do
    groups
    |> Enum.reduce_while({:ok, []}, fn
      group, {:ok, acc} when is_map(group) ->
        case check_group(group) do
          {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
          error -> {:halt, error}
        end

      _group, {:ok, _acc} ->
        {:halt, {:error, "invalid_evidence_contract"}}
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp check_group(group) do
    with {:ok, group_id} <- required_text(group, "group_id", "invalid_evidence_contract"),
         {:ok, any_of} <- required_string_list(group, "any_of", "invalid_evidence_contract") do
      {:ok, %{"group_id" => group_id, "any_of" => any_of}}
    end
  end

  defp required_map(attrs, key, reason) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _value} -> {:error, reason}
      :error -> {:error, reason}
    end
  end

  defp optional_map(attrs, key, reason) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _value} -> {:error, reason}
      :error -> {:ok, %{}}
    end
  end

  defp positive_integer(attrs, key, default, reason) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_integer(value) and value > 0 -> {:ok, value}
      {:ok, _value} -> {:error, reason}
      :error -> {:ok, default}
    end
  end

  defp optional_boolean_field(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, value} when is_boolean(value) -> {:ok, Map.put(map, key, value)}
      {:ok, _value} -> {:error, reason}
      :error -> {:ok, map}
    end
  end

  defp optional_text_field(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, reason}
          text -> {:ok, Map.put(map, key, text)}
        end

      {:ok, _value} ->
        {:error, reason}

      :error ->
        {:ok, map}
    end
  end

  defp optional_string_list(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, values} -> string_list(values, reason)
      :error -> {:ok, []}
    end
  end

  defp required_string_list(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, values} -> string_list(values, reason)
      :error -> {:error, reason}
    end
  end

  defp string_list(values, reason) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn
      value, {:ok, acc} when is_binary(value) ->
        case String.trim(value) do
          "" -> {:halt, {:error, reason}}
          text -> {:cont, {:ok, [text | acc]}}
        end

      _value, {:ok, _acc} ->
        {:halt, {:error, reason}}
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp string_list(_values, reason), do: {:error, reason}

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

  defp required_enum(map, key, allowed_values, reason) do
    case required_text(map, key, reason) do
      {:ok, value} ->
        if value in allowed_values, do: {:ok, value}, else: {:error, reason}

      error ->
        error
    end
  end

  defp reject_obsolete_keys(attrs) do
    attrs
    |> Map.keys()
    |> Enum.find(&(&1 in @obsolete_build_keys))
    |> obsolete_key_result()
  end

  defp obsolete_key_result(nil), do: :ok
  defp obsolete_key_result(key), do: {:error, "obsolete_key:" <> key}

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

  defp stable_id(prefix, parts) do
    digest =
      :crypto.hash(:sha256, :erlang.term_to_binary(parts))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 24)

    "#{prefix}_#{digest}"
  end

  defp compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end
end
