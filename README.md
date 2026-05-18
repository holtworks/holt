<p align="center">
  <img src="assets/holt-beaver.png" alt="Holt beaver mascot floating with a log" width="520">
</p>

# Holt

Holt is a project agent for teams. It runs in your terminal, reads your
workspace deliberately, asks before risky changes, and leaves behind a durable
record of what happened.

The mascot is a beaver floating with a log: practical, calm, and always
building something useful without flooding the workspace.

## Why Holt

- **Workspace-aware by default.** Runs, transcripts, approvals, tasks, memory,
  and artifacts stay attached to the workspace where the work happens.
- **Explicit trust boundary.** On first discovery Holt loads only `AGENTS.md`;
  additional files are read through visible actions.
- **Readable agent work.** Progress, model thinking, action calls, diffs, and
  approval gates stream in the CLI as they happen.
- **Approval before risk.** File writes, shell execution, network access, and
  secret reads go through structured policy and approval handling.
- **Built for long-running work.** Goal mode, resumable runs, run forking, task
  graphs, verifier routing, and memory packets keep multi-step work auditable.

## Quick Start

Build the native CLI:

```sh
cargo build --manifest-path rust/Cargo.toml -p holt-cli
```

Check the local setup:

```sh
rust/target/debug/holt doctor
rust/target/debug/holt onboard --yes
```

Ask Holt to work in the current directory:

```sh
rust/target/debug/holt "summarize this project"
rust/target/debug/holt --yes "inspect this folder and suggest the next change"
```

For an installed binary, use the same commands with `holt`.

## Everyday CLI

Start an interactive session:

```sh
holt
```

Run a single request and exit:

```sh
holt "explain the runtime boundary"
holt --yes "make the failing test pass"
```

Use goal mode for longer work:

```sh
holt goal "make the CLI feel as polished as Codex and Claude"
```

Useful commands:

| Command | Purpose |
| --- | --- |
| `holt doctor` | Check local configuration and provider state. |
| `holt model` | Show the active provider and model details. |
| `holt status` | Show workspace and latest-run status. |
| `holt diff` | Show tracked, staged, and untracked workspace changes. |
| `holt runs` | List recent runs. |
| `holt logs [run_id]` | Read a run timeline. |
| `holt logs --view transcript [run_id]` | Replay user and assistant turns. |
| `holt resume [run_id]` | Continue prior work. |
| `holt fork [run_id] [task]` | Branch from prior work into a new run. |
| `holt llm test local` | Smoke-test the local provider adapter. |

Inside the interactive CLI, use slash commands:

| Slash command | Purpose |
| --- | --- |
| `/goal [task]` | Switch to goal mode or start a goal. |
| `/build` | Switch back to build/chat mode. |
| `/permissions [review\|auto\|deny]` | Inspect or change write and command permissions. |
| `/diff [full\|summary]` | Review workspace changes. |
| `/runs` | Open recent run selection. |
| `/logs [run_id] [activity\|transcript]` | Read run activity or transcript. |
| `/resume [run_id]` | Resume a run. |
| `/fork [run_id]` | Fork a run. |
| `/history` | Show recent prompts. |
| `/keymap` | Show keyboard shortcuts. |

## What You See

Holt keeps terminal output compact but inspectable:

```text
Progress: Reading agent instructions
Action: Reading file `AGENTS.md`
Action: Read `AGENTS.md` - bytes: 842
* Edited rust/crates/holt-cli/src/tui.rs (+12 -4)
Progress: Completed
```

Markdown answers render with tables, task lists, local file links, code fences,
Mermaid diagrams, and diff blocks. Completed edits show compact summaries with
inline unified diffs. Approval prompts show the proposed change before you
accept or deny it.

## Where Data Lives

Holt uses explicit local storage:

```text
~/.holtworks/
  config.json
  providers.json
  logs/
  memory/
  skills/

<workspace>/.holtworks/
  AGENTS.md
  ACTIONS.md
  HOLT.md
  approvals/
  artifacts/
  runs/
  sessions/
  tasks/
  memory/
  skills/
```

The Rust CLI owns terminal interaction and presentation. The Elixir backend owns
supervised runs, action execution, event logs, approvals, task state, memory,
and provider adapters. See [HOLT_ARCHITECTURE.md](HOLT_ARCHITECTURE.md) for the
short boundary map.

## Development

Install dependencies and run tests:

```sh
mix deps.get
mix test
cargo test --manifest-path rust/Cargo.toml
```

Expected preflight before landing Elixir changes:

```sh
mix precommit
```

Expected preflight before landing Rust CLI changes:

```sh
cargo test --manifest-path rust/Cargo.toml
```

Build the release binary:

```sh
cargo build --release --manifest-path rust/Cargo.toml -p holt-cli
```

Debug and release binaries are written to:

```text
rust/target/debug/holt
rust/target/release/holt
```

## Provider Smoke Test

OpenRouter example:

```sh
export OPENROUTER_API_KEY="..."
holt onboard --yes --provider openrouter --model moonshotai/kimi-k2.6
holt llm test openrouter --model moonshotai/kimi-k2.6
holt --yes "inspect this folder and recommend the next implementation step"
```

You can also put credentials in a workspace `.env` file and pass
`--env-file /path/to/.env`. Holt loads that file for `doctor`, `onboard`,
`llm test`, and `run` without writing secrets into `providers.json`.

## Release

Publish a release by pushing a version tag:

```sh
git tag v0.1.0
git push --tags
```

GitHub Actions should build Rust artifacts for macOS, Linux, and Windows,
upload checksums, and publish installer scripts for the one-line install flow.

## More Docs

- [Holt Architecture](HOLT_ARCHITECTURE.md)
