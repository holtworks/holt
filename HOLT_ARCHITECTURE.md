# Holt Architecture

Holt has two explicit boundaries:

- The customer-facing binary owns terminal interaction, commands, and streamed
  presentation.
- The Elixir backend owns supervised runs, action execution, durable event
  logs, approvals, task state, memory, and provider adapters.

The product surface should stay customer-first: users run `holt`, see progress,
approve risky work, and get an answer. Internal runtime terms are not exposed in
normal CLI copy.

## Runtime Flow

```text
holt
  -> native bridge request
  -> Holt.Runtime / Holt.Runtime.RunServer
  -> Holt.Actions.Registry
  -> Holt.Actions.ProviderAdapter, only when a model provider needs function calls
  -> Holt.Actions.Executor
  -> Holt.ActionVisibility
  -> action.* event stream
  -> terminal renderer
```

## Elixir Boundaries

- `Holt.Runtime.RunServer`: supervised process wrapper for one run.
- `Holt.Runtime.Session`: supervised live session with streaming and user
  response checkpoints.
- `Holt.Runtime.RunStore`: repository for run state, event JSONL, and
  transcripts.
- `Holt.Runtime.AgentEventStore`: repository for agent session event JSONL.
- `Holt.Actions.Registry`: action discovery and catalog lookup.
- `Holt.Actions.Executor`: runtime-facing action execution API.
- `Holt.Actions.ProviderAdapter`: provider protocol conversion. OpenAI-style
  `tool_calls` and action result messages are contained here.
- `Holt.ActionVisibility`: product-facing labels, summaries, risk display, and
  approval display for action events.
- `Holt.Bridge.NativeCommand`: request decoding and service dispatch.
- `Holt.Bridge.NativePresenter`: CLI/log/event output rendering.

## Event Contract

Runtime activity uses action events:

- `action.started`
- `action.approval_requested`
- `action.approval_resolved`
- `action.completed`
- `action.failed`

Agent session events use `action_invocation` and `action_result`. Provider
protocol names such as `tool_calls`, `tool_choice`, and provider result messages
remain isolated to model-provider boundaries.

## Verification

The expected local gates are:

```sh
mix precommit
cargo test --manifest-path rust/Cargo.toml
```
