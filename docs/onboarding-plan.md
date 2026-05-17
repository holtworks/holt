# HoltWorks Onboarding Plan

## Objective

Create a first-run setup experience for HoltWorks that feels as polished as
OpenClaw while fitting a corporate agent runtime: fast install, explicit trust
choices, low-friction setup for individual users, and scriptable rollout for IT.

This document defines the target experience and implementation sequence. The
current CLI implements the V0 bootstrap path with local config, workspace files,
gateway status, provider defaults, and a first runnable task. The richer
interactive/admin flows below remain the product target.

## What We Are Borrowing From OpenClaw

OpenClaw's onboarding works because it treats setup as a guided product moment,
not just a config command. The useful patterns are:

- Two setup paths: an interactive wizard for humans and non-interactive flags for automation.
- Flow choices: quickstart for safe defaults, manual for control, import for migration.
- A security note before enabling local agent capabilities.
- Existing config detection with keep, modify, and reset choices.
- Local versus remote runtime setup.
- Secrets can be stored directly or as references to environment/secret providers.
- Daemon/service install is part of setup, not a separate scavenger hunt.
- Health checks run before the wizard claims success.
- The final step gets the user to a first useful session, not just "done".

HoltWorks should copy these mechanics, not the exact OpenClaw domain model.

## Product Positioning

HoltWorks is corporate-first. The onboarding must assume:

- The device may be managed by IT.
- The user may not know which model provider or gateway to use.
- Security teams need auditability, controlled permissions, and repeatable rollout.
- Some installs are human-driven, while others are MDM, CI, or golden-image installs.
- The best first-run outcome is "connected to the company runtime and ready for a first task."

## Primary Personas

1. Individual employee
   - Wants one command, a short guided setup, and a working agent.
   - Should not need to understand internal infrastructure.

2. IT or platform admin
   - Wants a scriptable install, policy file, checksum verification, logs, and exit codes.
   - Needs to preconfigure identity, gateway URL, permission policy, and update channel.

3. Security reviewer
   - Wants explicit trust boundaries, least-privilege defaults, secret handling, and audit output.
   - Needs to know what the agent can access before it runs.

## Target User Journey

### 1. Install

The current release flow already supports native archives and checksum-verified
install scripts. The installer should grow these behaviors:

- Print what will be installed and where.
- Verify SHA-256 checksums before extraction.
- Detect PATH issues and show the exact shell/profile fix.
- Run `holtworks doctor --install-check` after install.
- If a TTY is available, offer to run `holtworks onboard`.
- For corporate deployment, support:
  - `--company-url`
  - `--setup-token`
  - `--install-dir`
  - `--no-onboard`
  - `--json`
  - `--dry-run`

### 2. Welcome And Trust Notice

The first interactive screen should say what HoltWorks is about to configure:

- Local workspace and files
- Company identity or setup token
- Model/gateway access
- Optional background service
- Optional device permissions
- Optional shell/browser/filesystem capabilities

The user must explicitly accept the trust boundary before the wizard writes
credentials or starts background services.

### 3. Detect Existing State

Before prompting, inspect:

- Existing HoltWorks config
- Existing credentials or secret refs
- Existing workspace
- Installed binary version
- Running daemon/service
- Reachable corporate gateway

If config exists, offer:

- Keep current values
- Review and update
- Reset config only
- Full reset: config, credentials, sessions, workspace

Never silently overwrite a working setup.

### 4. Choose Setup Flow

Default command:

```sh
holtworks onboard
```

Flow choices:

- Quickstart: corporate defaults, shortest path, recommended for most users.
- Manual: choose gateway, workspace, permissions, secrets, and daemon settings.
- Import: migrate from OpenClaw, Hermes, or another supported local agent state.
- Admin package: apply a signed policy/config bundle from IT.

CLI shape:

```sh
holtworks onboard --flow quickstart
holtworks onboard --flow manual
holtworks onboard --flow import --import-from openclaw
holtworks onboard --policy ./holtworks-policy.json
```

### 5. Identity And Gateway

Quickstart should prefer company-owned setup:

- User enters or pastes a setup token.
- HoltWorks exchanges it for organization, gateway, policy, and allowed providers.
- If SSO/device-code auth exists, open the browser or print a device code.
- If offline or remote-only, save a pending state and explain the next command.

Manual setup should allow:

- Company gateway URL
- Local-only mode
- Remote gateway URL
- Token auth
- SecretRef/env-backed credentials

Non-interactive setup must require explicit risk acknowledgement:

```sh
holtworks onboard --non-interactive \
  --accept-risk \
  --company-url https://holt.example.com \
  --setup-token "$HOLTWORKS_SETUP_TOKEN" \
  --workspace "$HOME/HoltWorks" \
  --install-daemon
```

### 6. Workspace

Default workspace:

```text
~/HoltWorks
```

Wizard responsibilities:

- Create the workspace if missing.
- Create starter files only when policy allows.
- Explain what is stored locally.
- Offer "use current directory" for developer workflows.
- Warn before using synced folders or sensitive directories.

Initial workspace files:

- `AGENTS.md` or `HOLTWORKS.md` for agent instructions
- `POLICY.md` for local policy summary
- `README.md` for the user's workspace
- `sessions/` for local transcripts if enabled

### 7. Permissions

Permissions should be framed as capabilities, not technical toggles:

- Filesystem: which roots can the agent read/write?
- Shell: allowed commands, denied commands, approval policy.
- Browser/network: allowed domains and proxy requirements.
- Notifications: optional local reminders/status.
- Screen or automation permissions: only for desktop app/node integrations later.

Corporate default:

- Start in least-privilege mode.
- Ask for broader permissions only when a workflow needs them.
- Persist permission decisions as structured policy, not prose.

### 8. Background Service

Offer service install as a normal onboarding step:

- macOS: LaunchAgent
- Linux: systemd user service when available
- Windows: Scheduled Task or startup fallback

Quickstart default: install service if policy permits.

Manual mode: ask before install and show exact service name/path.

If service install fails, onboarding should still finish config setup and give
one clear repair command:

```sh
holtworks doctor --fix-service
```

### 9. Health Check

Onboarding is not complete until `doctor` can verify the configured path.

Minimum health checks:

- Binary version
- Config parse
- Workspace exists and is writable
- Credential or SecretRef resolves
- Gateway reachable, if configured
- Service installed/running, if selected
- Policy loaded
- Update channel known

Commands:

```sh
holtworks doctor
holtworks doctor --json
holtworks doctor --fix
```

### 10. First Useful Moment

The last screen should not be "setup complete"; it should offer a first action:

- Start a first terminal session.
- Open the dashboard, if/when HoltWorks has one.
- Run a tiny company-approved sample task.
- Show the user's workspace path.
- Show the support/debug bundle command.

Example final prompt:

```text
HoltWorks is ready.

Workspace: ~/HoltWorks
Gateway: reachable
Policy: Acme Engineering Standard

Start:
  holtworks chat

Need help:
  holtworks doctor --bundle
```

## Command Surface

MVP commands:

```sh
holtworks onboard
holtworks onboard --flow quickstart|manual|import
holtworks onboard --non-interactive --accept-risk ...
holtworks doctor
holtworks doctor --json
holtworks doctor --fix
holtworks status
holtworks config get <path>
holtworks config set <path> <value>
holtworks reset --scope config|credentials|full
```

Later commands:

```sh
holtworks chat
holtworks service install|start|stop|restart|status|uninstall
holtworks policy explain
holtworks support bundle
holtworks update
```

## Config And State

Suggested paths:

```text
~/.holtworks/config.json
~/.holtworks/credentials/
~/.holtworks/logs/
~/.holtworks/sessions/
~/HoltWorks/
```

Use structured fields for durable decisions:

- setup status
- flow
- organization ID
- gateway URL
- auth mode
- credential refs
- workspace path
- service status
- permission profile
- policy version
- last successful health check

Do not infer product behavior from user-facing text.

## Non-Interactive Contract

Non-interactive onboarding should:

- Fail fast if required inputs are missing.
- Require `--accept-risk`.
- Emit machine-readable JSON with `--json`.
- Avoid prompts.
- Never write plaintext secrets unless explicitly requested.
- Return stable exit codes.
- Support dry-run planning.

Example:

```sh
holtworks onboard --non-interactive \
  --accept-risk \
  --company-url https://holt.example.com \
  --setup-token-ref-env HOLTWORKS_SETUP_TOKEN \
  --workspace /Users/alice/HoltWorks \
  --install-daemon \
  --json
```

## Installer Contract

The existing Tinfoil-generated installer is a solid base. The corporate version
should add:

- `--onboard` to run onboarding after install.
- `--no-onboard` to suppress onboarding.
- `--dry-run` to preview.
- `--json` for MDM logs.
- `--company-url` and `--setup-token` passthrough to onboarding.
- Authenticated/private release support or a company-hosted mirror.

## MVP Scope

### Phase 1: Honest Local Onboarding

Goal: make `holtworks onboard` useful without needing the full corporate backend.

Deliverables:

- Config path and schema.
- Interactive quickstart.
- Existing config detection.
- Workspace creation.
- Local policy profile.
- `doctor` checks config/workspace/binary.
- Tests with temp HOME.

### Phase 2: Corporate Setup Token

Goal: make one command connect a user to company defaults.

Deliverables:

- `--company-url`
- `--setup-token` and `--setup-token-ref-env`
- Gateway URL persistence.
- Policy fetch/apply placeholder.
- SecretRef support.
- Non-interactive mode.

### Phase 3: Service And Health

Goal: make HoltWorks stay running and self-diagnose.

Deliverables:

- macOS LaunchAgent.
- Linux systemd user service.
- Windows Scheduled Task.
- `service status`.
- `doctor --fix-service`.
- Health check waits during onboarding.

### Phase 4: Enterprise Rollout

Goal: make IT deployment boring.

Deliverables:

- JSON installer output.
- Dry-run plans.
- Stable exit codes.
- Support bundle.
- Policy bundle import.
- Upgrade/rollback behavior.
- Documentation for MDM/Jamf/Intune-style deployment.

## UX Acceptance Criteria

- A new user can install, onboard, and run the first command in under five minutes.
- A managed employee can complete setup without knowing provider keys or gateway internals.
- An admin can deploy without prompts.
- The wizard can be rerun safely.
- Existing config is summarized before modification.
- Every failure gives one next command, not a wall of stack trace.
- Secrets are masked everywhere.
- `doctor --json` is usable by support and automation.
- The release installer and onboarding use the same terminology.

## Test Strategy

Unit tests:

- Config read/write/merge.
- Existing config summarization.
- Reset scope behavior.
- SecretRef validation.
- Gateway URL and token validators.
- Permission profile serialization.
- Exit code mapping.

Integration tests:

- Interactive wizard with scripted prompt adapter.
- Non-interactive setup in temp HOME.
- Re-run over existing config.
- Invalid config repair path.
- Installer `--onboard` passthrough.

Release checks:

- Download published archive.
- Verify checksum.
- Run `holtworks doctor`.
- Run non-interactive onboarding with a temp HOME.

Manual UX checks:

- Clean macOS machine.
- Clean Linux VM/container.
- Clean Windows VM.
- Corporate proxy/VPN environment.
- No TTY/MDM install.

## Open Questions

- Is the corporate control plane real now, or should Phase 2 use a local mock setup-token endpoint?
- Should the default config format be JSON for machine tooling or TOML for human editing?
- What is the first actual "agent ready" command: `chat`, `dashboard`, `run`, or something else?
- Which permissions are in the MVP versus deferred to desktop nodes?
- Do we want OpenClaw/Hermes import in MVP, or after the local config model is stable?

## Recommended Next Step

Build Phase 1 first: config schema, `holtworks onboard --flow quickstart`,
workspace creation, and `holtworks doctor`. Keep provider/gateway calls mocked
or config-only until the corporate backend contract is known.
