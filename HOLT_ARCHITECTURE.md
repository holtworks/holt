# Holt Architecture

Holt is migrating to a Rust-first agent runtime. The Rust binary owns the
customer-facing command surface. Elixir remains as a structured backend for
runtime services that have not moved behind typed Rust crates yet.

## Crate Boundaries

- `holt-cli`: command dispatch, native `holt` binary, and structured backend
  adapter calls.
- `holt-tui`: terminal presentation over typed protocol events.
- `holt-core`: agent turn orchestration and final-output contract.
- `holt-protocol`: `TurnRequest`, `AgentEvent`, tool calls, approvals, and
  response envelopes shared across all surfaces.
- `holt-workspace`: repository scanning and generic context packing.
- `holt-tools`: built-in tool registry and local tool execution.
- `holt-policy`: approval and side-effect decisions.
- `holt-sessions`: conversation state and recent chat context.
- `holt-models`: model provider boundary.
- `holt-telemetry`: trace and usage event sinks.

## Data Flow

```text
holt-cli / holt-tui
  -> holt-protocol::TurnRequest
  -> holt-core::AgentEngine
  -> holt-workspace::WorkspaceScanner
  -> holt-tools::LocalToolExecutor
  -> holt-policy::PolicyDecision
  -> holt-models::ModelProvider
  -> holt-protocol::AgentEvent stream
  -> holt-tui renderer
```

## Migration Rule

New runtime behavior belongs in Rust crates first. The Elixir `Holt.*`
modules are compatibility surfaces until their behavior has a typed Rust owner.
The removed Elixir terminal modules should not be reintroduced; Rust should
call Elixir through explicit bridge requests until the remaining behavior has a
native Rust owner.
