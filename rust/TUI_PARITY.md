# Holt CLI TUI Parity

Reference snapshots:

- OpenAI Codex: `/private/tmp/openai-codex` at `da14dd2`
- claw-code: `/private/tmp/claw-code` at `f8e1bb7`

## Goal 1: Ratatui Foundation

Status: done

Acceptance:

- Interactive `holt` launches the normal terminal prompt/output flow by default; frontend selector flags are rejected with explicit errors.
- Holt never enters the alternate screen or clears the whole terminal for the interactive UI.
- Holt's canonical interactive path is a terminal application, not a persistent screen renderer.
- The Ratatui renderer remains isolated from default routing and covered by buffer tests.
- Diff transcript rendering is covered in both terminal-flow output and Ratatui buffer tests.

Progress:

- CLI routing now treats the terminal-flow app as the canonical interactive frontend and rejects obsolete frontend selector flags with explicit errors.
- The non-default Ratatui renderer runs through `Viewport::Inline` at the visible terminal height, with raw mode and cursor visibility guarded separately from any alternate-screen behavior.

Reference:

- Codex `tui/src/tui.rs`
- Codex `tui/src/render/`
- Codex `tui/src/history_cell/`

## Goal 2: Transcript Cell Model

Status: done

Acceptance:

- Transcript cells become typed render units instead of a single role/content struct.
- File-edit events cross the turn/UI boundary as structured `FileEditSummary` data.
- Assistant markdown cells keep raw markdown source and re-render on resize.
- Patch/edit cells render as Codex-style file-change cells: `• Edited path (+N -M)` plus an inline diff block.

Reference:

- Codex `tui/src/history_cell/messages.rs`
- Codex `tui/src/history_cell/patches.rs`
- Codex `tui/src/chatwidget/transcript.rs`

## Goal 3: Markdown And Diff Renderer

Status: done

Acceptance:

- Markdown rendering emits Ratatui-native lines/spans.
- Markdown span colors use Ratatui colors directly; inline mode performs the only Crossterm conversion.
- Code fences, local file links, tables, nested lists, task lists, Mermaid, and diff fences retain current Holt coverage.
- Diff rendering has Codex-style line numbers, add/delete tones, file summaries, wrapping, and syntax-highlighted code spans.

Progress:

- Transcript `FrameView` now carries Ratatui `Line` values instead of making the draw layer translate markdown spans.
- `ui.rs` owns the `RenderLine` to Ratatui conversion, so markdown/diff colors remain Ratatui-native until inline mode explicitly converts them for Crossterm.
- Inline markdown emphasis, strong text, strikethrough, links, and inline code now survive wrapping as Ratatui span modifiers/tones instead of literal markdown marker text.
- Diff hunk content is syntax-highlighted from the changed file path while preserving Holt's existing line-number gutter and wrapping behavior.
- File edit cells render the Codex-style summary as structured Ratatui spans, with a bold edit verb and separate add/delete tones before the inline diff block.

Reference:

- Codex `tui/src/markdown_render.rs`
- Codex `tui/src/diff_render.rs`
- Codex `tui/src/render/highlight.rs`

## Goal 4: Bottom Pane And Popups

Status: done

Acceptance:

- Composer, slash command popup, history search, permissions prompt, run picker, and user questions are separate bottom-pane views.
- Footer/status text is derived from structured state, not prose matching.
- Key handling routes through view state before mutating app state.
- Pending backend work renders an animated loading state with elapsed time.

Progress:

- Composer rendering is driven by `ComposerMode` variants for message, pending, question, approval, and run picker states.
- Ctrl-R history search has a structured composer mode with found/no-match footer status.
- Slash command suggestions are typed `ComposerSuggestion` rows and formatted by the Ratatui frame layer instead of being preformatted text strings.
- Slash command suggestions are keyboard-selectable with an explicit selected row; Tab accepts the selected command.
- User questions and run selection are structured composer content views instead of temporary markdown transcript cells.
- Text input visibility is explicit by composer mode, so selector panes do not render a blank message prompt.
- Key handling now routes approval, user prompt, and run picker keys through `ComposerInputRoute` before message editing.
- Up/Down prompt recall now returns typed `HistoryNavigationOutcome` values, with coverage for TUI history and literal line-mode arrow escape sequences.
- Pending backend work has an explicit loading animation scope: the run loop advances frames while pending, and the composer title renders a spinner/ripple with elapsed time.

Reference:

- Codex `tui/src/bottom_pane/`
- Codex `tui/src/chatwidget/input_flow.rs`
- Codex `tui/src/chatwidget/permission_popups.rs`

## Goal 5: Pager, Reflow, And Snapshots

Status: done

Acceptance:

- Long transcript/details views can open in a pager overlay.
- Terminal resize reflows source-backed markdown and preserves scroll intent.
- Ratatui buffer or VT100 snapshots cover the primary UI states.

Progress:

- The focused transcript block can open in a Ratatui pager overlay through a keymapped transcript action.
- Pager overlay state is structured (`cell` plus scroll offset), consumes keys while open, and renders expanded source-backed content even when the transcript block is collapsed.
- Terminal resize now preserves bottom-scroll intent and recomputes scroll for the focused transcript cell instead of resetting the transcript to the bottom.
- Focused resize tests cover bottom-at-bottom behavior and focused-cell anchor preservation after reflow.
- Ratatui buffer tests cover transcript/composer rendering, pager overlay rendering, selected slash suggestions, and pending loading animation rendering.

Reference:

- Codex `tui/src/pager_overlay.rs`
- Codex `tui/src/transcript_reflow.rs`
- Codex `tui/src/snapshots/`
