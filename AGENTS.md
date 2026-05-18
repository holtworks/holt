# AGENTS.md

## Project Rules

- Do not support legacy runtime contracts. Pick one canonical field, action name,
  event shape, or route shape and update every caller/test to use it.
- Do not add fallback compatibility for old parameter names, old IDs, old
  action names, or old user-facing phrases. Reject obsolete inputs with explicit
  structured errors.
- Do not hide ambiguous contracts behind helpers such as `first_present`,
  `first_value`, `required_any`, chained `||`, or broad `or` checks. Model the
  contract explicitly.
- Runtime behavior must be driven by structured fields, enums, policy records,
  persisted metadata, or owned configuration. Do not drive workflow decisions
  from prose matching or literal user-facing text.
- If a contract changes, update the schema, implementation, bridge callers, and
  tests in the same change. Data migrations may be one-off maintenance code, but
  normal runtime paths must not carry compatibility branches.
- Do not add TypeSpec or callback annotations (`@type`, `@typedoc`, `@typep`,
  `@opaque`, `@spec`, or `@callback`) unless the project rule changes.

## Verification

- Write test names and assertion text as observable product behavior, not
  implementation narration. Name the contract being protected and let ExUnit's
  assertion output show the values.
- Prefer focused ExUnit setup over shared hidden state. Use `setup` or named
  setup functions to return explicit context for each test.
- Use `@tag`/context metadata for per-test inputs when it makes setup explicit;
  do not hide important setup in module globals.
- Use `async: true` only for tests that do not share mutable filesystem,
  process, registry, database, or application state. ExUnit only runs different
  async modules concurrently; tests inside one module still run serially.
- Use `setup_all` only for immutable module-wide context. It runs in a separate
  process from the tests, so do not use it for per-test process ownership or
  mutable state.
- Start OTP processes in tests with `start_supervised!/1` or
  `start_link_supervised!/1` so ExUnit owns cleanup. Do not leave manually
  linked processes behind.
- Do not use `Process.sleep/1` to synchronize tests. Assert messages with
  `assert_receive` or `refute_receive`; assert process shutdowns with monitors
  and `{:DOWN, ...}` messages.
- Debug narrowly with `mix test path/to/file.exs:line` or `mix test --failed`,
  use `mix test --repeat-until-failure N --max-failures 1` to chase flaky tests,
  and use `mix test --stale` for local iteration when dependency tracking is
  enough. Finish Elixir changes with the full project precommit alias.
- Run `mix precommit` after Elixir changes.
- Run `cargo test --manifest-path rust/Cargo.toml` after Rust CLI changes.
