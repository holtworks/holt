# HoltWorks

HoltWorks is an Elixir-based local agent runtime packaged as a single executable with
[Burrito](https://hex.pm/packages/burrito). The release setup is designed for the
OpenClaw-style install flow: users install a native binary with one command and do
not need Elixir or Erlang on their device.

## Core Runtime

The V0 core is local-first and does not require a Phoenix API, billing system, or
cloud machine fleet. It includes:

- CLI commands for onboarding, running tasks, status, logs, approvals, skills,
  memory, and a JSON-lines stdio bridge.
- `~/.holtworks` global config and provider files.
- `.holtworks` workspace bootstrap with `HOLT.md`, `AGENTS.md`, `TOOLS.md`,
  skills, memory, runs, artifacts, approvals, and tasks.
- Durable run folders with `run.json`, `events.jsonl`, `transcript.md`, and run
  artifacts.
- File-backed live agent sessions with stream chunks, `awaiting_user` resume,
  model/tool spans, summaries, and session-tree projections.
- Workspace-local task records with comments, specs, agent-work links, and
  structured verification reports.
- Structured lifecycle states: created, queued, running, awaiting approval,
  awaiting user, completed, blocked, failed, and canceled.
- Tool registry with file, shell, network, memory, agent profile, delegation,
  page/document, repair-run, and user-question tools.
- Web search with explicit structured research-claim recording.
- Scoped user and project memory tools for durable preferences, project notes,
  plans, and research.
- Approval gate for write, execute, network, and secret-read risks.
- Markdown skill discovery and task relevance selection.
- Agent-callable skill tools for listing, loading, saving, updating, and running
  skill-owned scripts.
- Agent-callable profile tools for listing, creating, updating, suspending,
  resuming, deleting, card lookup, skill lookup, and structured invocation
  contracts.
- Agent-callable local page and document tools for structured user questions,
  ephemeral child-agent delegation, document page creation, title updates, and
  document writes.
- Agent-callable repair-run tools for diagnosis, structured artifacts,
  prediction reconciliation, strategy selection, approval gates, implementation
  gates, verification checks, and completion.
- File-backed memory.
- Local model provider boundary with local, OpenAI, OpenRouter, and Ollama
  adapters.
- Model tool-call loop that exposes HoltWorks action definitions to providers
  through a transport-neutral provider catalog and executes structured tool
  calls through the local action router.
- In-process local gateway with no public listener.

## Install

After the first GitHub release is published, users can install HoltWorks with:

```sh
curl -fsSL https://raw.githubusercontent.com/holtworks/holtworks/main/scripts/install.sh | sh
```

Windows users can install with PowerShell:

```powershell
iwr -useb https://raw.githubusercontent.com/holtworks/holtworks/main/scripts/install.ps1 | iex
```

The generated installer selects the correct asset for the user's OS and CPU,
verifies the SHA-256 checksum, and installs `holtworks` into `~/.local/bin` by
default.

The `holtworks/holtworks` repository is private right now. For a public
OpenClaw-style one-line install, make the repository or release assets public
before publishing the first release. For private corporate distribution, mirror
the generated installer and release assets behind the company's authenticated
download host.

## Development

```sh
mix deps.get
mix test
mix run -e 'HoltWorks.CLI.main(["doctor"])'
```

Useful local commands:

```sh
mix run -e 'HoltWorks.CLI.main(["onboard", "--yes"])'
mix run -e 'HoltWorks.CLI.main(["run", "--yes", "inspect this folder and create a short implementation plan"])'
mix run -e 'HoltWorks.CLI.main(["status", "--json"])'
mix run -e 'HoltWorks.CLI.main(["logs"])'
mix run -e 'HoltWorks.CLI.main(["tasks", "create", "Inspect this repo"])'
mix run -e 'HoltWorks.CLI.main(["tasks", "run", "--yes", "HW-01"])'
mix run -e 'HoltWorks.CLI.main(["tasks", "verify", "HW-01", "--check", "tests:passed"])'
mix run -e 'HoltWorks.CLI.main(["skills", "list"])'
mix run -e 'HoltWorks.CLI.main(["memory", "search", "gateway"])'
mix run -e 'HoltWorks.CLI.main(["llm", "test", "local"])'
```

For an installed binary, use the same commands without `mix run -e`.

## Local Task Flow

The Inktrail task concepts are ported as a local-first flow instead of a
Phoenix-backed system. Task state lives under `.holtworks/tasks`:

```text
.holtworks/tasks/
  tasks.json
  counter.json
  specs.json
  agent_runs.json
  agent_run_events.jsonl
  task_graphs.json
  task_graph_events.jsonl
  verifier_calibrations.json
  task_memory_artifacts.json
  task_memory_artifact_chunks.json
  task_memory_context_packets.json
  human_approval_requests.json
  evidence_ledgers.json
  specs/<task_id>/<spec_id>.md
```

Agent profiles live at the workspace root:

```text
.holtworks/
  agents.json
  pages.json
  page_state.json
  document_events.jsonl
  documents/<page_id>.md
  repair_runs.json
  repair_run_events.jsonl
  research_claims.jsonl
  memory/user.jsonl
  memory/project.jsonl
  skills/<skill>.md
  skills/<skill>/scripts/<script>
  sessions/
  agent_events/
```

Tasks use structured lifecycle fields: `backlog`, `todo`, `in_progress`,
`waiting`, `done`, and `canceled`. Agent work links a task to a durable run and
moves the task to `waiting` for verification. Verification decisions are driven
by explicit check statuses, not prose.

```sh
holtworks tasks create --priority high "Inspect this repo"
holtworks tasks label add HW-01 "backend" --color "#2563eb"
holtworks tasks link add HW-01 HW-02 --type depends_on
holtworks tasks run --yes HW-01 --message "Create a concise implementation plan"
holtworks tasks run --yes HW-01 --agent support-agent --max-agents-per-event 1
holtworks agents create support-agent --name "Support Agent" --handle support --role worker --skill triage
holtworks agents list
holtworks agents cards
holtworks tasks run --yes HW-01 --auto-continue --max-continuation-depth 2
holtworks tasks continue --yes HW-01 --message "Continue from the prior run"
holtworks tasks spec HW-01 --kind decision --title "Runtime cut" --content "Stay local-first."
holtworks tasks specs list HW-01
holtworks tasks specs get spec_id --task HW-01
holtworks tasks graph create HW-01 --type workflow
holtworks tasks graph complete task_graph_id plan --summary "Plan ready"
holtworks tasks graph show task_graph_id
holtworks tasks evidence-contract HW-01
holtworks tasks verifier contract HW-01 --graph-id task_graph_id
holtworks tasks verifier assign HW-01 --graph-id task_graph_id
holtworks tasks verifier route HW-01 --graph-id task_graph_id
holtworks tasks verifier dispatch HW-01 --graph-id task_graph_id
holtworks tasks verifier calibrate HW-01 --verifier-agent-id agent_verify --completion-decision auto_finish_allowed --verification-status passed --can-finish
holtworks tasks work-graph HW-01 --graph-id task_graph_id
holtworks tasks work-graph-gate HW-01 --graph-id task_graph_id
holtworks tasks work-graph-budget HW-01 --group-token-budget 64000
holtworks tasks work-graph-schedule HW-01 --graph-id task_graph_id
holtworks tasks dispatch-plan HW-01 --max-agents-per-event 2
holtworks tasks team-plan HW-01 --task-complexity implementation
holtworks tasks child-contract HW-01 start_agent_work --role worker
holtworks tasks tool-session HW-01 --disabled-tool write_file
holtworks tasks tool route HW-01 run_command
holtworks tasks tool execute HW-01 add_comment --content "checked by action layer"
holtworks tasks tool execute HW-01 set_priority --priority high
holtworks tasks tool execute HW-01 todo_write --content "Verify task action parity"
holtworks tasks tool execute HW-01 manage_connection
holtworks tasks tool execute HW-01 use_workbench --tool read_file --path README.md
holtworks actions run create_task "Follow up with verifier"
holtworks actions list
holtworks tasks action-contract HW-01 get_task
holtworks tasks plan-contract HW-01
holtworks tasks plan-gate HW-01 get_task
holtworks tasks preflight HW-01 get_task
holtworks tasks consequence-gate HW-01 get_task
holtworks tasks action-envelope HW-01 get_task
holtworks tasks approval-request HW-01 run_command --allow-workspace-durable
holtworks tasks approval-resolve approval_request_id --decision approved
holtworks tasks evidence-ledger HW-01 get_task --result-status ok
holtworks tasks memory-artifact HW-01 --kind handoff --content "Exact evidence"
holtworks tasks memory-context HW-01
holtworks tasks context-budget HW-01 --estimated-input-tokens 4000
holtworks tasks continuation-packet HW-01
holtworks tasks capability-registry get_task
holtworks tasks capability-contract HW-01 get_task
holtworks tasks capability-route HW-01 get_task
holtworks tasks generic-plan HW-01
holtworks tasks runtime doctor
holtworks tasks runtime tools --tool get_task
holtworks tasks runtime provider gpt-5.2
holtworks tasks runtime safety --task-complexity implementation
holtworks tasks runtime context-budget --model gpt-5.2 --estimated-input-tokens 4000
holtworks tasks runtime recovery update_task --effect-scope task_durable
holtworks tasks runtime debug
holtworks tasks runtime learn
holtworks tasks runtime sanitize --content "{\"command\":\"run\",\"error\":\"failed\"}"
holtworks tasks process started agent_run_id --managed-process-id proc1
holtworks tasks process terminal agent_run_id --status exited --exit-code 0
holtworks tasks runs events agent_run_id
holtworks tasks runs replay default agent_run_id
holtworks tasks runs tool-event agent_run_id update_task --result-status ok
holtworks tasks verify HW-01 --check tests:passed --summary "Ready to close."
holtworks tasks watchdog --yes --stale-after-seconds 300
holtworks tasks show HW-01
```

The local task layer mirrors the useful non-Phoenix Inktrail task actions:
create, list, get, update, comments, comment deletion, labels, typed links,
story-point estimates, task specs/artifacts, task-run handoff, and structured
verification routing. Task reads enrich `agent_work` with liveness metadata and
a lightweight `agent_run` summary from the local ledger. Verification reports
store explicit checks, risk flags, changed files, evidence, routing decisions,
and a task comment with the attached verification artifact.

Agents are first-class local profiles in `agents.json` with lifecycle state,
roles, skills, model/provider hints, and `holtworks_agent_card/v1` cards.
Assigned agents are structured task assignees with `kind: agent`; task reads
enrich those assignees from the profile registry. When a task has assigned
agents, `start_agent_work` selects active idle assigned agents, writes a
`holtworks_agent_dispatch/v1` dispatch plan, applies `max_agents_per_event`
anti-stampede suppression, assigns a `holtworks_work_graph_budget/v1` group
budget, isolates worker/verifier contexts, and records each selected agent as
its own `agent_work` and `agent_run` entry. Suspended or archived agents are not
dispatched, and local-only tasks without assignees still run through the built-in
`default` agent for CLI ergonomics.

The orchestration layer can now be inspected without starting work:
`holtworks_work_graph/v1` derives an event/task-graph DAG,
`holtworks_work_graph_completion_gate/v1` blocks finish decisions on incomplete
nodes, missing verification, and severe unaccepted prediction errors, and
`holtworks_work_graph_schedule/v1` separates ready, waiting, blocked, and
parallel node groups. `holtworks_team_orchestration/v1` describes the team
shape for trivial, implementation, normal, and broad-parallel tasks, while
`holtworks_child_agent_contract/v1` makes delegated child-agent authority,
outputs, and verifier requirements explicit before the child starts.

Task graphs add the local work-graph gate used by the agent runtime. A graph
stores durable nodes for planning, work, verification, and integration, advances
dependency-free nodes to `scheduled`, and blocks final completion until required
non-integration nodes are done and a structured verification route passes.
Agent work can bind to a graph with `graph_id` and `node_key`; completed runs
mark that node done and schedule the verifier node. Verification routing records
a `holtworks_task_graph_verification_gate/v1` gate on the graph and exposes the
current `mission_control` gate in CLI, stdio, and task API responses.

Verification is governed by `holtworks_evidence_contract/v1` and
`holtworks_verification_gateway/v1`. Workflow, validation, or outcome contract
spec metadata can define required check groups, changed-file evidence, command
evidence, and UI/API/GraphQL proof requirements. `route_verification_review`
evaluates those structured requirements before allowing `auto_finish`. When a
graph needs independent review, `tasks verifier route` or `plan_verifier_route`
creates a bounded read-only verifier contract with `route_verification_review`
as the required gate tool and records it on the task graph.
The standalone verifier operations expose the same contract without requiring
Phoenix runtime services: `holtworks_verification_contract/v1` declares the gate
and pass policy, `holtworks_verifier_assignment/v1` chooses an independent
assigned verifier or an ephemeral route, `holtworks_verifier_dispatch/v1`
returns the bounded `start_agent_work` packet for the verifier, and
`holtworks_verifier_calibration/v1` stores later outcome quality signals in
`verifier_calibrations.json` so future assignments can prefer better verifiers.

Tool access is scoped through `holtworks_task_tool_session/v1` and
`holtworks_task_tool_route/v1`. A task tool session lists enabled toolkits,
direct tools, disabled tools, meta-tools, and a local workbench boundary. The
router returns a structured route plus `holtworks_action_contract/v1` metadata
such as effect scope, risk level, target refs, recovery posture, and whether
approval is required. `holtworks_action_definition/v1` and
`holtworks_action_execution/v1` add the executable provider layer: callers can
list local actions, load a tool schema, and execute task tools through the
router before dispatch. The router meta-tools only nest read-only or
session-ephemeral actions; mutating actions must be called directly so policy,
prediction, recovery, and verification metadata attach to the real action.
Workspace tools still use the existing approval policy for write, execute,
network, and secret-read risks.

Plan execution is guarded by `holtworks_plan_contract/v1`,
`holtworks_plan_gate/v1`, and `holtworks_action_preflight/v1`. The default plan
allows read-only task context, task-durable updates, agent orchestration, and
routed meta-tools while keeping workspace-durable and network effects out of the
active plan unless explicitly enabled. Preflight checks combine route status,
effect classification, active plan permission, target references, recovery
metadata, idempotency, and approval requirements before execution.

Action execution is wrapped by `holtworks_action_runtime_envelope/v1`, which
binds `holtworks_consequence_gate/v1`, `holtworks_policy_decision/v1`,
`holtworks_consequence_prediction/v1`, `holtworks_world_state_snapshot/v1`,
`holtworks_state_transition_prediction/v1`, `holtworks_state_invariant_check/v1`,
`holtworks_execution_observation/v1`, `holtworks_prediction_error/v1`,
`holtworks_state_reconciliation/v1`, `holtworks_outcome_calibration/v1`, and
`holtworks_repair_orchestration/v1` into one propose, gate, observe, reconcile,
calibrate, and repair-or-continue lifecycle.
Approval-gated actions can create `holtworks_human_approval_request/v1` records
and `holtworks_human_approval_resolution/v1` decisions under the local task
store. `holtworks_evidence_ledger/v1` records typed evidence entries for
contracts, gates, predictions, observations, calibrations, repairs, approvals,
tool results, and event metadata so runtime outcomes remain auditable.

Repair workflows can also be tracked directly in `holtworks_repair_run/v1`
records. The local ledger stores goal contracts, hypotheses, research claims,
predictions, observations, prediction scores, strategy decisions, architecture
plans, blast-radius reports, original-issue checks, impact checks, related-issue
sweeps, approvals, and final reports. Repair completion is gated by explicit
check statuses and structured waivers rather than prose.

Long-running work uses file-backed task memory. `holtworks_task_memory_artifact/v1`
stores exact evidence in chunked local records, while
`holtworks_task_memory_context_packet/v1` compiles recent task specs, comments,
artifacts, approval requests, and evidence ledgers into a compact packet with
artifact refs. `holtworks_context_budget_governor/v1` estimates model-window
pressure and returns structured actions such as `send`, `snapshot_soon`,
`compact_before_send`, or `reject_and_compact`. Manual and automatic
continuations can use `holtworks_continuation_packet/v1`, which carries the
previous task/run/work ids, context packet id, budget state, and required loop
for loading memory, dereferencing artifacts, doing the next verifiable step, and
submitting verification.

Capability routing is modeled through `holtworks_capability_registry_entry/v1`,
`holtworks_capability_contract/v1`, and `holtworks_capability_route/v1`. The
registry describes tool capabilities, risk, state read/write models, approval
policy, and rollback posture. Contracts turn a task objective into required
capabilities, tools, artifact kinds, and effect scope, and the route chooses an
eligible assigned agent or an ephemeral sub-agent route. `holtworks_generic_work_graph/v1`
adds a domain-neutral research, propose, act, verify, and repair plan over the
same allowed tool surface.

The `HoltWorks.AgentRuntime` facade exposes the local runtime contracts as one
surface for clients that expect an Inktrail-style runtime boundary.
`holtworks_tool_availability/v1` reports tool availability from structured
runtime fields, `holtworks_provider_profile/v1` describes model/runtime context,
`holtworks_safety_policy/v1` declares execution safety rules, and
`holtworks_context_budget/v1` wraps provider profile, policy, governor, and
file-backed compression metadata.

Automatic continuation is opt-in and policy-driven. `--auto-continue` records a
structured continuation decision after each run, starts same-task continuations
until `max_continuation_depth` is reached, and records suppression reasons such
as `max_continuation_depth_reached` or structured blockers like
`approval_denied`. Run classification and continuation decisions are stored in
`agent_runs.json` and `agent_run_events.jsonl`.

The watchdog scanner checks persisted agent-run state for stale queued/running
work, retryable blocked work, and runs marked as needing continuation. It
records `holtworks_agent_run_watchdog_snapshot/v1` observations, writes
`holtworks_agent_run_watchdog_recovery/v1` packets before recovery, marks the
stale work as `recovery_queued`, and starts a guarded continuation with
`source: task_agent_watchdog_recovery`. Legitimate verification waits and
non-retryable blockers are observed without creating duplicate work.

Runtime parity also includes standalone recovery, debugging, sanitization, and
learning contracts. `holtworks_recovery_contract/v1` declares reversibility,
rollback, and forward-recovery requirements per effect scope.
`holtworks_run_debugger/v1` summarizes envelopes, pending approvals, repair
holds, and prediction mismatches from run events.
`holtworks_meta_learning_snapshot/v1` proposes reviewable policy updates from
measured calibration, repair, verifier, and lesson outcomes. The local model
output sanitizer keeps internal runner payloads out of user-facing responses.
Agent-run lifecycle transitions are centralized in a typed state machine, and
each run now carries a `holtworks_agent_loop/v1` projection for continuous
task-agent work. Process wake records `process.started`, `process.exited`, and
`process.missing` events, then writes a `holtworks_agent_process_wake/v1` packet
when an awaited process reaches a terminal state so the same task can continue
from structured process evidence.

Agent-run history also records Inktrail-style structured events for narration,
plan contracts, child-agent contracts/completions, tool outcomes, continuation
packets, and objective evaluations. Events are persisted to
`agent_run_events.jsonl` with idempotency keys, and `holtworks_agent_run_replay/v1`
returns the selected run, lineage, and exact event stream for an agent.

The stdio bridge exposes both Holt paths such as `tasks/create` and Inktrail
MCP-style aliases such as `create_task`, `get_task`, `save_task_spec`,
`start_agent_work`, `route_verification_review`, `load_teammate_runtime`, and
`read_task_memory_artifact`. Agent aliases include `create_agent`,
`list_agents`, `get_agent`, `update_agent`, `suspend_agent`, `resume_agent`,
`delete_agent`, `invoke_agent`, `list_agent_cards`, `get_agent_card`, and
`list_agent_skills`. Core UI/document aliases include `ask_user_question`,
`delegate_to_agent`, `set_page_title`, `create_page`, and `write_to_document`
plus `core/ask_user_question`, `core/delegate_to_agent`,
`core/set_page_title`, `pages/create`, and `documents/write`. Repair aliases include `start_repair_run`,
`get_repair_run`, `record_repair_run_artifact`, `reconcile_repair_prediction`,
`score_repair_predictions`, `choose_repair_strategy`,
`draft_repair_architecture_plan`, `draft_repair_blast_radius`,
`draft_repair_original_issue_check`, `execute_repair_original_issue_check`,
`execute_repair_impact_check`, `draft_repair_related_issue_sweep`,
`begin_repair_implementation`, `approve_repair_gate`, and
`complete_repair_run`. Graph aliases include `create_task_graph`,
`list_task_graphs`, `get_task_graph`, `advance_task_graph`, and
`complete_task_graph_node`. Verification aliases include
`get_evidence_contract`, `plan_verifier_route`, `verification_contract`,
`verifier_assignment`, `assign_verifier`, `verifier_dispatch`,
`dispatch_verifier`, and `verifier_calibration`. Orchestration aliases include
`work_graph`, `work_graph_gate`, `work_graph_budget`, `work_graph_schedule`,
`schedule_work_graph`, `agent_dispatch_plan`, `team_orchestration`, and
`child_agent_contract`. Tool-session aliases include `task_tool_session`,
`get_task_tool_session`, `route_task_tool`, and `task_tool_route`. Plan and
preflight aliases include `action_contract`, `plan_contract`, `plan_gate`,
`action_preflight`, `consequence_gate`,
`action_runtime_envelope`, `complete_action_runtime_envelope`,
`action_approval_request`, `resolve_action_approval_request`,
`action_evidence_ledger`, `record_task_memory_artifact`,
`task_memory_context`, `get_task_memory_context`, `context_budget`,
`continuation_packet`,
`capability_registry`, `capability_contract`, `capability_route`,
`route_capability`, and `generic_plan`. Runtime aliases include
`runtime_doctor`, `tool_availability`, `provider_profile`, `safety_policy`,
`runtime_context_budget`, `recovery_contract`, `run_debugger`,
`meta_learning_snapshot`, `format_local_model_result`,
`record_process_started`, `notify_process_terminal`, `record_agent_run_event`,
`record_tool_event`, `record_agent_narration`, `record_plan_contract`,
`record_child_agent_contract`, `record_child_agent_completion`,
`record_objective_evaluation`, `record_continuation_packet`,
`list_agent_run_events`, `search_agent_run_events`, and `agent_run_replay`.
The `start_agent_work`
alias accepts a single `task_id`,
shared `task_ids`, or per-ticket `tasks` with task-specific messages and agent
selection. The `watchdog_agent_runs` alias runs the same watchdog scan for
MCP-style clients. Task continuations append a new `agent_work` record, create a
new ledger entry with `source: task_agent_continuation`, and create a new run
with `resumed_from` pointing at the previous task run.

## OpenRouter LLM Smoke Test

Set an OpenRouter API key in the shell, then onboard HoltWorks with the
OpenRouter provider:

```sh
export OPENROUTER_API_KEY="..."
mix run -e 'HoltWorks.CLI.main(["onboard", "--yes", "--provider", "openrouter", "--model", "openai/gpt-4o-mini"])'
mix run -e 'HoltWorks.CLI.main(["llm", "test", "openrouter", "--model", "openai/gpt-4o-mini"])'
mix run -e 'HoltWorks.CLI.main(["run", "--yes", "inspect this folder and create a short implementation plan"])'
```

Instead of exporting the key, you can put it in a workspace `.env` file or pass
`--env-file /path/to/.env`. HoltWorks loads that file for `doctor`, `onboard`,
`llm test`, and `run`, without writing the key into `providers.json`.

The runtime sends chat completion requests to
`https://openrouter.ai/api/v1/chat/completions`, includes available HoltWorks
actions as function tools, records `model.requested`, `model.completed`,
`model.tool_calls`, and `tool.*` events, then writes the final Markdown plan to
`NEXT_STEPS.md` after approval.

## Build A Native Binary

Burrito wraps the OTP release into a standalone executable:

```sh
MIX_ENV=prod mix release
```

Local Burrito builds require `zig` and `xz` in `PATH`. The GitHub Actions
release workflow installs Zig automatically.

Per-target binaries are written to `burrito_out/`.

## Release

Tinfoil owns the GitHub release workflow and installer scripts. Regenerate them
after changing the release config:

```sh
mix tinfoil.generate
```

Publish a release by pushing a version tag:

```sh
git tag v0.1.0
git push --tags
```

GitHub Actions will build Burrito artifacts for macOS, Linux, and Windows, upload
checksums, and publish installer scripts for the one-line install flow.
