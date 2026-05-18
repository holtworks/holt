use crate::{
    backend,
    commands::{self, SlashCommand, KEY_BINDINGS, SLASH_COMMANDS},
    history, keymap, terminal,
    tui_frame::{
        self, ComposerContent, ComposerHistorySearchStatus, ComposerMode, ComposerSuggestion,
        ComposerView, FrameView, HeaderView, PagerView, PendingComposerStatus, RunPickerDetailView,
        RunPickerRowView, RunPickerView, TranscriptNavigationLabels, UserPromptOptionView,
        UserPromptView,
    },
    turn::{
        ActivityControl, FileEditStatus, FileEditSummary, QuestionOption, RenderAction, TurnState,
    },
    ui,
};
use anyhow::{Context, Result};
use crossterm::event::{self, Event, KeyCode, KeyEvent, KeyModifiers};
use holt_protocol::ChatMessage;
use ratatui::{backend::CrosstermBackend, Terminal as RatatuiTerminal, TerminalOptions, Viewport};
use serde_json::Value;
use std::{
    borrow::Cow,
    cell::RefCell,
    io,
    path::PathBuf,
    sync::mpsc::{self, Receiver, Sender},
    thread,
    time::{Duration, Instant},
};
use ui::{RenderLine, RenderSpan, Tone};

type UiTerminal = RatatuiTerminal<CrosstermBackend<io::Stdout>>;

#[derive(Clone, Debug)]
pub struct ChatArgs {
    runtime_flags: Vec<String>,
    prompt: Option<String>,
    workspace: Option<String>,
    interaction_mode: InteractionMode,
    permission_mode: commands::PermissionMode,
    permission_mode_explicit: bool,
    parse_error: Option<String>,
    pub yes: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum InteractionMode {
    Build,
    Goal,
}

impl ChatArgs {
    pub fn parse(args: Vec<String>) -> Self {
        let mut runtime_flags = Vec::new();
        let mut prompt_parts = Vec::new();
        let mut workspace = None;
        let mut parse_error = None;
        let mut yes = false;
        let mut permission_mode = commands::PermissionMode::Review;
        let mut permission_mode_explicit = false;
        let mut index = 0;

        while index < args.len() {
            let arg = &args[index];

            match arg.as_str() {
                "--plain" => {
                    parse_error = Some(
                        "unsupported flag --plain: Holt uses the terminal session by default"
                            .to_string(),
                    );
                    index += 1;
                }
                "--tui" | "--fullscreen" => {
                    parse_error = Some(format!(
                        "unsupported flag {arg}: Holt uses the terminal session by default"
                    ));
                    index += 1;
                }
                "--yes" | "-y" => {
                    yes = true;
                    permission_mode = commands::PermissionMode::Auto;
                    permission_mode_explicit = true;
                    runtime_flags.push(arg.clone());
                    index += 1;
                }
                "--api-key-stdin" => {
                    runtime_flags.push(arg.clone());
                    index += 1;
                }
                "--home" | "--workspace" | "--provider" | "--model" | "--mode"
                | "--runtime-contract" | "--base-url" | "--api-key-env" | "--env-file"
                | "--chat-messages" | "--permission-mode" => {
                    runtime_flags.push(arg.clone());

                    if let Some(value) = args.get(index + 1) {
                        if arg == "--workspace" {
                            workspace = Some(value.clone());
                        }
                        if arg == "--permission-mode" {
                            permission_mode_explicit = true;
                            if let Some(mode) = commands::PermissionMode::parse(value) {
                                permission_mode = mode;
                                yes = mode == commands::PermissionMode::Auto;
                            }
                        }
                        runtime_flags.push(value.clone());
                        index += 2;
                    } else {
                        index += 1;
                    }
                }
                value if value.starts_with('-') => {
                    runtime_flags.push(arg.clone());
                    index += 1;
                }
                _ => {
                    prompt_parts.extend(args[index..].iter().cloned());
                    break;
                }
            }
        }

        let prompt = if prompt_parts.is_empty() {
            None
        } else {
            Some(prompt_parts.join(" "))
        };

        Self {
            runtime_flags,
            prompt,
            workspace,
            interaction_mode: InteractionMode::Build,
            permission_mode,
            permission_mode_explicit,
            parse_error,
            yes,
        }
    }

    #[cfg(test)]
    fn has_prompt(&self) -> bool {
        self.prompt.is_some()
    }

    pub(crate) fn permission_mode_label(&self) -> &'static str {
        self.permission_mode.label()
    }

    pub(crate) fn parse_error(&self) -> Option<&str> {
        self.parse_error.as_deref()
    }

    pub(crate) fn interaction_mode_label(&self) -> &'static str {
        match self.interaction_mode {
            InteractionMode::Build => "build",
            InteractionMode::Goal => "goal",
        }
    }

    pub(crate) fn set_interaction_mode(&mut self, mode: InteractionMode) {
        self.interaction_mode = mode;
    }

    pub(crate) fn toggle_interaction_mode(&mut self) {
        self.interaction_mode = match self.interaction_mode {
            InteractionMode::Build => InteractionMode::Goal,
            InteractionMode::Goal => InteractionMode::Build,
        };
    }

    pub(crate) fn set_permission_mode(&mut self, mode: commands::PermissionMode) {
        self.permission_mode = mode;
        self.permission_mode_explicit = true;
        self.yes = mode == commands::PermissionMode::Auto;
        remove_permission_flags(&mut self.runtime_flags);
        self.runtime_flags.push("--permission-mode".to_string());
        self.runtime_flags.push(mode.as_flag_value().to_string());
    }

    pub(crate) fn one_shot_chat_run_args(&self) -> Option<Vec<String>> {
        self.prompt
            .as_ref()
            .map(|prompt| self.chat_run_args(prompt, &[]))
    }

    pub(crate) fn command_args(&self, command: &str) -> Vec<String> {
        let mut args = vec![command.to_string()];
        args.extend(self.runtime_flags.clone());
        args
    }

    pub(crate) fn logs_args(&self, run_ref: Option<&str>, view: commands::LogView) -> Vec<String> {
        let mut args = self.command_args("logs");

        if matches!(view, commands::LogView::Transcript) {
            args.push("--view".to_string());
            args.push("transcript".to_string());
        }

        if let Some(run_ref) = run_ref.filter(|value| !value.is_empty()) {
            args.push(run_ref.to_string());
        }

        args
    }

    pub(crate) fn diff_args(&self, view: commands::DiffView) -> Vec<String> {
        let mut args = self.command_args("diff");

        match view {
            commands::DiffView::Full => {}
            commands::DiffView::Summary => {
                args.push("--view".to_string());
                args.push("summary".to_string());
            }
        }

        args
    }

    pub(crate) fn runs_json_args(&self) -> Vec<String> {
        let mut args = self.command_args("runs");
        args.push("--json".to_string());
        args
    }

    #[cfg(test)]
    fn run_args(&self, prompt: &str) -> Vec<String> {
        let mut args = vec!["run".to_string()];
        args.extend(self.runtime_flags.clone());

        self.push_forced_auto_permission(&mut args, true);

        args.push(prompt.to_string());
        args
    }

    pub(crate) fn chat_run_args(&self, prompt: &str, chat_messages: &[ChatMessage]) -> Vec<String> {
        self.chat_run_args_with_approval(prompt, chat_messages, true)
    }

    pub(crate) fn turn_run_args(&self, prompt: &str, chat_messages: &[ChatMessage]) -> Vec<String> {
        match self.interaction_mode {
            InteractionMode::Build => self.chat_run_args_with_approval(prompt, chat_messages, true),
            InteractionMode::Goal => self.goal_run_args_with_approval(prompt, chat_messages, true),
        }
    }

    #[cfg(test)]
    pub(crate) fn interactive_chat_run_args(
        &self,
        prompt: &str,
        chat_messages: &[ChatMessage],
    ) -> Vec<String> {
        self.chat_run_args_with_approval(prompt, chat_messages, false)
    }

    pub(crate) fn interactive_turn_run_args(
        &self,
        prompt: &str,
        chat_messages: &[ChatMessage],
    ) -> Vec<String> {
        match self.interaction_mode {
            InteractionMode::Build => {
                self.chat_run_args_with_approval(prompt, chat_messages, false)
            }
            InteractionMode::Goal => self.goal_run_args_with_approval(prompt, chat_messages, false),
        }
    }

    fn chat_run_args_with_approval(
        &self,
        prompt: &str,
        chat_messages: &[ChatMessage],
        force_auto_approve: bool,
    ) -> Vec<String> {
        let mut args = vec!["run".to_string()];
        args.extend(self.runtime_flags_without_mode());

        self.push_forced_auto_permission(&mut args, force_auto_approve);

        args.push("--mode".to_string());
        args.push("chat".to_string());

        if !chat_messages.is_empty() {
            args.push("--chat-messages".to_string());
            args.push(serde_json::to_string(chat_messages).expect("chat messages encode"));
        }

        args.push(prompt.to_string());
        args
    }

    fn goal_run_args_with_approval(
        &self,
        prompt: &str,
        chat_messages: &[ChatMessage],
        force_auto_approve: bool,
    ) -> Vec<String> {
        let mut args = vec!["run".to_string()];
        args.extend(self.runtime_flags_without_mode());

        self.push_forced_auto_permission(&mut args, force_auto_approve);

        args.push("--runtime-contract".to_string());
        args.push("goal".to_string());

        if !chat_messages.is_empty() {
            args.push("--chat-messages".to_string());
            args.push(serde_json::to_string(chat_messages).expect("chat messages encode"));
        }

        args.push(prompt.to_string());
        args
    }

    fn runtime_flags_without_mode(&self) -> Vec<String> {
        let mut filtered = Vec::new();
        let mut index = 0;

        while index < self.runtime_flags.len() {
            if matches!(
                self.runtime_flags[index].as_str(),
                "--mode" | "--runtime-contract"
            ) {
                index += 2;
            } else {
                filtered.push(self.runtime_flags[index].clone());
                index += 1;
            }
        }

        filtered
    }

    pub(crate) fn resume_args(&self, run_ref: &str) -> Vec<String> {
        self.resume_args_with_approval(run_ref, true)
    }

    pub(crate) fn interactive_resume_args(&self, run_ref: &str) -> Vec<String> {
        self.resume_args_with_approval(run_ref, false)
    }

    pub(crate) fn fork_args(&self, run_ref: &str) -> Vec<String> {
        self.fork_args_with_approval(run_ref, true)
    }

    pub(crate) fn interactive_fork_args(&self, run_ref: &str) -> Vec<String> {
        self.fork_args_with_approval(run_ref, false)
    }

    fn resume_args_with_approval(&self, run_ref: &str, force_auto_approve: bool) -> Vec<String> {
        let mut args = vec!["resume".to_string()];
        args.extend(self.runtime_flags.clone());

        self.push_forced_auto_permission(&mut args, force_auto_approve);

        args.push(run_ref.to_string());
        args
    }

    fn fork_args_with_approval(&self, run_ref: &str, force_auto_approve: bool) -> Vec<String> {
        let mut args = vec!["fork".to_string()];
        args.extend(self.runtime_flags.clone());

        self.push_forced_auto_permission(&mut args, force_auto_approve);

        args.push(run_ref.to_string());
        args
    }

    fn push_forced_auto_permission(&self, args: &mut Vec<String>, force_auto_approve: bool) {
        if force_auto_approve
            && self.permission_mode == commands::PermissionMode::Review
            && !self.permission_mode_explicit
        {
            args.push("--permission-mode".to_string());
            args.push("auto".to_string());
        }
    }

    pub(crate) fn workspace_root(&self) -> PathBuf {
        if let Some(workspace) = &self.workspace {
            return PathBuf::from(workspace);
        }

        if let Ok(workspace) = std::env::var("HOLTWORKS_WORKSPACE") {
            if !workspace.is_empty() {
                return PathBuf::from(workspace);
            }
        }

        std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."))
    }
}

fn remove_permission_flags(flags: &mut Vec<String>) {
    let mut filtered = Vec::with_capacity(flags.len());
    let mut index = 0;

    while index < flags.len() {
        match flags[index].as_str() {
            "--yes" | "-y" => {
                index += 1;
            }
            "--permission-mode" => {
                index += 2;
            }
            _ => {
                filtered.push(flags[index].clone());
                index += 1;
            }
        }
    }

    *flags = filtered;
}

pub fn run(session: ChatArgs) -> Result<i32> {
    let _guard = terminal::enter_inline_tui()?;
    let viewport_height = inline_viewport_height(terminal::terminal_size().1);
    let backend = CrosstermBackend::new(io::stdout());
    let mut terminal = UiTerminal::with_options(
        backend,
        TerminalOptions {
            viewport: Viewport::Inline(viewport_height),
        },
    )
    .context("failed to create inline Ratatui terminal")?;
    let mut state = State::with_persistent_history(session);
    let mut dirty = true;

    loop {
        if dirty {
            render(&mut terminal, &state)?;
            dirty = false;
        }

        if let Some(result) = poll_pending(&mut state) {
            finish_pending(&mut state, result);
            dirty = true;
            continue;
        }

        if event::poll(Duration::from_millis(70)).context("failed to poll terminal events")? {
            match event::read().context("failed to read terminal event")? {
                Event::Key(key) => {
                    if handle_key(&mut state, key) {
                        break;
                    }
                    dirty = true;
                }
                Event::Resize(width, height) => {
                    preserve_resize_scroll(&mut state, width.max(60), height.max(18));
                    dirty = true;
                }
                _ => {}
            }
        } else if state.pending.is_some() {
            state.frame = state.frame.wrapping_add(1);
            dirty = true;
        }
    }

    Ok(state.exit_code)
}

fn inline_viewport_height(terminal_height: u16) -> u16 {
    terminal_height.max(1)
}

struct State {
    session: ChatArgs,
    cells: Vec<Cell>,
    input: String,
    input_cursor: usize,
    history: Vec<String>,
    chat_messages: Vec<ChatMessage>,
    history_cursor: Option<usize>,
    history_search: Option<HistorySearch>,
    history_draft: String,
    slash_selection: usize,
    scroll: usize,
    transcript_focus_cell: Option<usize>,
    keymap: keymap::Keymap,
    frame: usize,
    pending: Option<Pending>,
    streaming_answer_cell: Option<usize>,
    streaming_activity_cell: Option<usize>,
    pending_answer_content: String,
    run_picker: Option<RunPicker>,
    pager: Option<Pager>,
    approval_prompt: Option<ApprovalPrompt>,
    user_prompt: Option<UserPrompt>,
    exit_code: i32,
}

impl State {
    #[cfg(test)]
    fn new(session: ChatArgs) -> Self {
        Self::new_with_history(session, Vec::new())
    }

    fn with_persistent_history(session: ChatArgs) -> Self {
        let workspace = session.workspace_root();
        let history = history::load_prompt_history(&workspace);
        Self::new_with_history(session, history)
    }

    fn new_with_history(session: ChatArgs, history: Vec<String>) -> Self {
        let workspace = session.workspace_root();
        let permission = session.permission_mode_label();
        let interaction_mode = session.interaction_mode_label();
        let (keymap, keymap_error) = match keymap::load(&workspace) {
            Ok(keymap) => (keymap, None),
            Err(error) => (keymap::Keymap::default(), Some(error)),
        };

        let mut cells = vec![Cell::new(
            Role::System,
            format!(
                "Holt ready.\nWorkspace: {}\nMode: {interaction_mode} · {permission}\nType a task or /help.",
                workspace.display()
            ),
        )];

        if let Some(error) = keymap_error {
            cells.push(Cell::new(
                Role::Error,
                format!("Keymap config error: {error}"),
            ));
        }

        Self {
            session,
            cells,
            input: String::new(),
            input_cursor: 0,
            history,
            chat_messages: Vec::new(),
            history_cursor: None,
            history_search: None,
            history_draft: String::new(),
            slash_selection: 0,
            scroll: 0,
            transcript_focus_cell: None,
            keymap,
            frame: 0,
            pending: None,
            streaming_answer_cell: None,
            streaming_activity_cell: None,
            pending_answer_content: String::new(),
            run_picker: None,
            pager: None,
            approval_prompt: None,
            user_prompt: None,
            exit_code: 0,
        }
    }

    fn add_cell(&mut self, role: Role, content: impl Into<String>) {
        self.cells.push(Cell::new(role, content));
        self.scroll = 0;
        self.transcript_focus_cell = None;
    }

    fn add_file_edit_cell(&mut self, summary: FileEditSummary) {
        self.cells.push(Cell::file_edit(summary));
        self.scroll = 0;
        self.transcript_focus_cell = None;
    }

    fn add_answer_delta(&mut self, content: &str) {
        self.streaming_activity_cell = None;

        match self.streaming_answer_cell {
            Some(index)
                if matches!(
                    self.cells.get(index).map(|cell| cell.role),
                    Some(Role::Assistant)
                ) =>
            {
                self.cells[index].push_content(content);
            }
            _ => {
                self.cells.push(Cell::new(Role::Assistant, content));
                self.streaming_answer_cell = Some(self.cells.len() - 1);
            }
        }

        self.scroll = 0;
        self.transcript_focus_cell = None;
    }

    fn add_activity_line(&mut self, role: Role, content: String, terminal: bool) {
        match self.streaming_activity_cell {
            Some(index)
                if matches!(
                    self.cells.get(index).map(|cell| cell.role),
                    Some(Role::System | Role::Error)
                ) =>
            {
                self.cells[index] = Cell::new(role, content);
            }
            _ => {
                self.cells.push(Cell::new(role, content));
                self.streaming_activity_cell = Some(self.cells.len() - 1);
            }
        }

        if terminal {
            self.streaming_activity_cell = None;
        }

        self.scroll = 0;
        self.transcript_focus_cell = None;
    }

    fn recent_chat_messages(&self) -> Vec<ChatMessage> {
        self.chat_messages
            .iter()
            .rev()
            .take(8)
            .cloned()
            .collect::<Vec<_>>()
            .into_iter()
            .rev()
            .collect()
    }
}

struct Pending {
    label: String,
    started: Instant,
    rx: Receiver<PendingMessage>,
    input: Option<Sender<backend::StreamInput>>,
    record_chat_response: bool,
}

enum PendingMessage {
    Action(RenderAction),
    Finished(Result<backend::BackendOutput, String>, bool),
    RunList(Result<Vec<RunSummary>, String>),
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct RunSummary {
    id: String,
    status: String,
    objective: String,
    artifact: Option<String>,
    answer_preview: Option<String>,
}

struct RunPicker {
    runs: Vec<RunSummary>,
    selected: usize,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct Pager {
    cell: usize,
    scroll: usize,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct ApprovalPrompt {
    action: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct UserPrompt {
    question: String,
    description: Option<String>,
    options: Vec<UserPromptOption>,
    selected: usize,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct HistorySearch {
    query: String,
    cursor: Option<usize>,
    status: HistorySearchStatus,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum HistorySearchStatus {
    Found,
    NotFound,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum HistoryNavigationDirection {
    Older,
    Newer,
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum HistoryNavigationOutcome {
    NoHistory,
    NotBrowsing,
    Recalled { index: usize, prompt: String },
    RestoredDraft { draft: String },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ComposerInputRoute {
    Approval,
    UserPrompt,
    RunPicker,
    Message,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct UserPromptOption {
    label: String,
    value: String,
    description: Option<String>,
}

struct Cell {
    role: Role,
    body: CellBody,
    collapsed: bool,
    render_cache: RefCell<Option<CellRenderCache>>,
}

enum CellBody {
    Markdown { source: String },
    FileEdit { summary: FileEditSummary },
}

impl Cell {
    fn new(role: Role, content: impl Into<String>) -> Self {
        Self {
            role,
            body: CellBody::Markdown {
                source: content.into(),
            },
            collapsed: false,
            render_cache: RefCell::new(None),
        }
    }

    fn file_edit(summary: FileEditSummary) -> Self {
        Self {
            role: Role::System,
            body: CellBody::FileEdit { summary },
            collapsed: false,
            render_cache: RefCell::new(None),
        }
    }

    fn markdown_source(&self) -> Cow<'_, str> {
        match &self.body {
            CellBody::Markdown { source } => Cow::Borrowed(source),
            CellBody::FileEdit { summary, .. } => Cow::Owned(summary.markdown()),
        }
    }

    fn push_content(&mut self, content: &str) {
        match &mut self.body {
            CellBody::Markdown { source } => source.push_str(content),
            CellBody::FileEdit { summary } => {
                let mut source = summary.markdown();
                source.push_str(content);
                self.body = CellBody::Markdown { source };
            }
        }
        self.invalidate_render_cache();
    }

    fn toggle_collapsed(&mut self) {
        self.collapsed = !self.collapsed;
        self.invalidate_render_cache();
    }

    fn invalidate_render_cache(&self) {
        self.render_cache.borrow_mut().take();
    }

    fn rendered_body_line_count(&self, body_width: usize, workspace: &PathBuf) -> usize {
        self.ensure_render_cache(body_width, workspace);

        self.render_cache
            .borrow()
            .as_ref()
            .map(|cache| cache.lines.len())
            .unwrap_or_default()
    }

    fn push_rendered_body_range(
        &self,
        body_width: usize,
        workspace: &PathBuf,
        start: usize,
        end: usize,
        output: &mut Vec<RenderLine>,
    ) {
        self.ensure_render_cache(body_width, workspace);

        let cache = self.render_cache.borrow();
        if let Some(cache) = cache.as_ref() {
            let start = start.min(cache.lines.len());
            let end = end.min(cache.lines.len());
            if start < end {
                output.extend(cache.lines[start..end].iter().cloned());
            }
        }
    }

    fn ensure_render_cache(&self, body_width: usize, workspace: &PathBuf) {
        let cache_valid = self.render_cache.borrow().as_ref().is_some_and(|cache| {
            cache.body_width == body_width && cache.collapsed == self.collapsed
        });

        if cache_valid {
            return;
        }

        let lines = render_cell_body_lines(self, body_width, workspace);
        *self.render_cache.borrow_mut() = Some(CellRenderCache {
            body_width,
            collapsed: self.collapsed,
            lines,
        });
    }
}

struct CellRenderCache {
    body_width: usize,
    collapsed: bool,
    lines: Vec<RenderLine>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum TranscriptAnchorKind {
    Block,
    Diff,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum TranscriptJumpDirection {
    Previous,
    Next,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Role {
    Assistant,
    Error,
    System,
    User,
}

fn render(terminal: &mut UiTerminal, state: &State) -> Result<()> {
    terminal
        .draw(|frame| {
            let area = frame.area();
            let view = frame_view(state, area.width, area.height);
            tui_frame::draw_frame(frame, &view);
        })
        .context("failed to draw Ratatui frame")?;
    Ok(())
}

fn frame_view(state: &State, width: u16, height: u16) -> FrameView {
    let composer = Composer::new(state, width, height);
    let body_height = transcript_body_height(height, composer.height);
    let body_lines = transcript_visible_lines(state, width as usize, body_height, state.scroll);
    let workspace = state.session.workspace_root();

    FrameView {
        header: HeaderView {
            workspace: workspace.display().to_string(),
            interaction_mode: state.session.interaction_mode_label(),
            permission_mode: state.session.permission_mode_label(),
        },
        transcript: ui::ratatui_lines(&body_lines, width),
        transcript_height: body_height as u16,
        composer: ComposerView {
            mode: composer.mode,
            content: composer.content,
            rule: composer.rule,
            input_lines: composer.input_lines,
            suggestions: composer.suggestions,
            height: composer.height,
            cursor_x: composer.cursor_x,
            cursor_y: composer.cursor_y,
        },
        pager: pager_view(state, width, height),
    }
}

fn pager_view(state: &State, width: u16, _height: u16) -> Option<PagerView> {
    let pager = state.pager.as_ref()?;
    let cell = state.cells.get(pager.cell)?;
    let workspace = state.session.workspace_root();
    let body_width = width.saturating_sub(8).max(16) as usize;
    let mut lines = Vec::new();
    lines.push(transcript_cell_header(cell));
    lines.extend(render_cell_body_lines_with_collapse(
        cell, body_width, &workspace, false,
    ));
    lines.push(RenderLine::new("╰─", Tone::Border));

    let (label, _) = transcript_cell_label(cell);
    let title = format!(
        "pager · {label} · block {}/{}",
        pager.cell + 1,
        state.cells.len()
    );
    let footer = "Esc/q close · Up/Down scroll · PgUp/PgDn page · Home/End edge".to_string();

    Some(PagerView {
        title,
        lines: ui::ratatui_lines(&lines, width.saturating_sub(8).max(16)),
        scroll: pager.scroll,
        footer,
    })
}

fn transcript_lines(state: &State, width: usize) -> Vec<RenderLine> {
    let total_lines = transcript_total_line_count(state, width);
    transcript_line_range(state, width, 0, total_lines)
}

fn transcript_visible_lines(
    state: &State,
    width: usize,
    body_height: usize,
    scroll: usize,
) -> Vec<RenderLine> {
    let total_lines = transcript_total_line_count(state, width);
    let end = total_lines.saturating_sub(scroll);
    let start = end.saturating_sub(body_height);

    transcript_line_range(state, width, start, end)
}

fn transcript_total_line_count(state: &State, width: usize) -> usize {
    let body_width = width.saturating_sub(6).max(16);
    let workspace = state.session.workspace_root();

    state
        .cells
        .iter()
        .map(|cell| 1 + cell.rendered_body_line_count(body_width, &workspace) + 2)
        .sum()
}

fn transcript_line_range(state: &State, width: usize, start: usize, end: usize) -> Vec<RenderLine> {
    if start >= end {
        return Vec::new();
    }

    let mut lines = Vec::new();
    let body_width = width.saturating_sub(6).max(16);
    let workspace = state.session.workspace_root();
    let mut cursor = 0usize;

    for cell in &state.cells {
        let body_len = cell.rendered_body_line_count(body_width, &workspace);
        let cell_len = 1 + body_len + 2;
        let cell_start = cursor;
        let cell_end = cell_start + cell_len;
        cursor = cell_end;

        if cell_end <= start || cell_start >= end {
            continue;
        }

        let local_start = start.saturating_sub(cell_start).min(cell_len);
        let local_end = end.saturating_sub(cell_start).min(cell_len);

        if local_start == 0 && local_end > 0 {
            lines.push(transcript_cell_header(cell));
        }

        let body_start = local_start.saturating_sub(1).min(body_len);
        let body_end = local_end.saturating_sub(1).min(body_len);
        cell.push_rendered_body_range(body_width, &workspace, body_start, body_end, &mut lines);

        let footer_index = 1 + body_len;
        if local_start <= footer_index && footer_index < local_end {
            lines.push(RenderLine::new("╰─", Tone::Border));
        }

        let blank_index = footer_index + 1;
        if local_start <= blank_index && blank_index < local_end {
            lines.push(RenderLine::new("", Tone::Plain));
        }
    }

    lines
}

fn transcript_cell_header(cell: &Cell) -> RenderLine {
    let (label, tone) = transcript_cell_label(cell);

    RenderLine::new(format!("╭─ {label}"), tone)
}

fn transcript_cell_label(cell: &Cell) -> (&'static str, Tone) {
    match cell.role {
        Role::Assistant => ("holt", Tone::Accent),
        Role::Error => ("error", Tone::Error),
        Role::System => ("system", Tone::System),
        Role::User => ("you", Tone::User),
    }
}

fn render_cell_body_lines(cell: &Cell, body_width: usize, workspace: &PathBuf) -> Vec<RenderLine> {
    render_cell_body_lines_with_collapse(cell, body_width, workspace, cell.collapsed)
}

fn render_cell_body_lines_with_collapse(
    cell: &Cell,
    body_width: usize,
    workspace: &PathBuf,
    collapsed: bool,
) -> Vec<RenderLine> {
    if collapsed {
        return vec![RenderLine::new(
            format!("│ {}", collapsed_cell_summary(cell, body_width)),
            Tone::Dim,
        )];
    }

    match &cell.body {
        CellBody::FileEdit { summary } => {
            render_file_edit_body_lines(summary, body_width, workspace)
        }
        CellBody::Markdown { .. } => {
            let source = cell.markdown_source();
            ui::markdown_lines_with_cwd(source.as_ref(), body_width, Some(workspace))
                .into_iter()
                .map(|line| {
                    if matches!(cell.role, Role::Error) {
                        line.flattened_with_tone(Tone::Error)
                            .prefixed("│ ", Tone::Error)
                    } else {
                        line.prefixed("│ ", line.tone)
                    }
                })
                .collect()
        }
    }
}

fn render_file_edit_body_lines(
    summary: &FileEditSummary,
    body_width: usize,
    workspace: &PathBuf,
) -> Vec<RenderLine> {
    let mut lines = vec![file_edit_summary_line(summary).prefixed("│ ", Tone::System)];

    if let Some(detail) = summary.detail_markdown() {
        lines.extend(
            ui::markdown_lines_with_cwd(&detail, body_width, Some(workspace))
                .into_iter()
                .map(|line| line.prefixed("│ ", line.tone)),
        );
    }

    lines
}

fn file_edit_summary_line(summary: &FileEditSummary) -> RenderLine {
    let mut spans = vec![RenderSpan::new("• ", Tone::Dim)];
    spans.push(bold_span(
        match summary.status {
            FileEditStatus::Edited => "Edited",
            FileEditStatus::Unchanged => "Unchanged",
        },
        match summary.status {
            FileEditStatus::Edited => Tone::System,
            FileEditStatus::Unchanged => Tone::Dim,
        },
    ));
    spans.push(RenderSpan::new(" ", Tone::Plain));
    spans.push(RenderSpan::new(summary.path.clone(), Tone::Plain));

    if let (Some(additions), Some(deletions)) = (summary.additions, summary.deletions) {
        spans.push(RenderSpan::new(" (", Tone::Dim));
        spans.push(RenderSpan::new(format!("+{additions}"), Tone::DiffAdd));
        spans.push(RenderSpan::new(" ", Tone::Dim));
        spans.push(RenderSpan::new(format!("-{deletions}"), Tone::DiffDelete));
        spans.push(RenderSpan::new(")", Tone::Dim));
    }

    RenderLine::styled(spans)
}

fn bold_span(text: impl Into<String>, tone: Tone) -> RenderSpan {
    let mut span = RenderSpan::new(text, tone);
    span.modifier = ratatui::style::Modifier::BOLD;
    span
}

fn collapsed_cell_summary(cell: &Cell, width: usize) -> String {
    let source = cell.markdown_source();
    let preview = source
        .lines()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .unwrap_or("empty block");
    let raw_lines = source.lines().count().max(1);
    let summary = format!("collapsed · {raw_lines} lines · {preview}");
    ui::truncate(&summary, width)
}

fn handle_key(state: &mut State, key: KeyEvent) -> bool {
    if key.code == KeyCode::Char('c')
        && key.modifiers.contains(KeyModifiers::CONTROL)
        && cancel_pending(state)
    {
        return false;
    }

    match (key.code, key.modifiers) {
        (KeyCode::Char('c'), KeyModifiers::CONTROL) => {
            state.exit_code = 130;
            true
        }
        (KeyCode::Char('d'), KeyModifiers::CONTROL) if state.input.is_empty() => true,
        (KeyCode::Char('d'), KeyModifiers::CONTROL) => false,
        (KeyCode::Char('l'), KeyModifiers::CONTROL) => {
            state.cells.clear();
            state.transcript_focus_cell = None;
            state.run_picker = None;
            state.pager = None;
            state.approval_prompt = None;
            state.user_prompt = None;
            false
        }
        _ if state.pager.is_some() && handle_pager_key(state, key) => false,
        _ if handle_composer_route_key(state, key, composer_input_route(state)) => false,
        (KeyCode::Char('a'), modifiers) if modifiers.contains(KeyModifiers::CONTROL) => {
            move_input_home(state);
            false
        }
        (KeyCode::Char('e'), modifiers) if modifiers.contains(KeyModifiers::CONTROL) => {
            move_input_end(state);
            false
        }
        (KeyCode::Char('r'), modifiers)
            if modifiers.contains(KeyModifiers::CONTROL)
                && composer_input_route(state) == ComposerInputRoute::Message =>
        {
            search_history(state);
            false
        }
        _ if transcript_key_context_available(state)
            && state.keymap.transcript_action(key).is_some() =>
        {
            let action = state
                .keymap
                .transcript_action(key)
                .expect("transcript action");
            apply_transcript_key_action(state, action);
            false
        }
        (KeyCode::Char('u'), modifiers) if modifiers.contains(KeyModifiers::CONTROL) => {
            kill_input_before_cursor(state);
            reset_history_navigation(state);
            false
        }
        (KeyCode::Char('k'), modifiers) if modifiers.contains(KeyModifiers::CONTROL) => {
            kill_input_after_cursor(state);
            reset_history_navigation(state);
            false
        }
        (KeyCode::Char('w'), modifiers) if modifiers.contains(KeyModifiers::CONTROL) => {
            delete_input_word_before_cursor(state);
            reset_history_navigation(state);
            false
        }
        (KeyCode::Esc, _) => {
            clear_input(state);
            reset_history_navigation(state);
            false
        }
        (KeyCode::Enter, KeyModifiers::SHIFT) => {
            insert_input_char(state, '\n');
            reset_history_navigation(state);
            false
        }
        (KeyCode::Char('j'), KeyModifiers::CONTROL) => {
            insert_input_char(state, '\n');
            reset_history_navigation(state);
            false
        }
        (KeyCode::Enter, _) => {
            if state.input.trim().is_empty() && resume_selected_run(state) {
                return false;
            }

            submit(state)
        }
        (KeyCode::Tab, _)
            if state.pending.is_none()
                && state.input.is_empty()
                && composer_input_route(state) == ComposerInputRoute::Message =>
        {
            toggle_interaction_mode(state);
            false
        }
        (KeyCode::Tab, _) if composer_input_route(state) == ComposerInputRoute::Message => {
            if complete_slash_input(state) {
                reset_history_navigation(state);
            }
            false
        }
        (KeyCode::Backspace, _) => {
            backspace_input(state);
            reset_history_navigation(state);
            false
        }
        (KeyCode::Delete, _) => {
            delete_input(state);
            reset_history_navigation(state);
            false
        }
        (KeyCode::Left, _) => {
            move_input_left(state);
            false
        }
        (KeyCode::Right, _) => {
            move_input_right(state);
            false
        }
        (KeyCode::Home, _) => {
            move_input_home(state);
            false
        }
        (KeyCode::End, _) => {
            move_input_end(state);
            false
        }
        (KeyCode::PageUp, _) => {
            state.scroll = state.scroll.saturating_add(8);
            state.transcript_focus_cell = None;
            false
        }
        (KeyCode::PageDown, _) => {
            state.scroll = state.scroll.saturating_sub(8);
            state.transcript_focus_cell = None;
            false
        }
        (KeyCode::Up, _) if move_slash_selection(state, -1) => false,
        (KeyCode::Down, _) if move_slash_selection(state, 1) => false,
        (KeyCode::Up, _) => {
            let _ = navigate_history(state, HistoryNavigationDirection::Older);
            false
        }
        (KeyCode::Down, _) => {
            let _ = navigate_history(state, HistoryNavigationDirection::Newer);
            false
        }
        (KeyCode::Char(ch), modifiers)
            if !modifiers.contains(KeyModifiers::CONTROL)
                && !modifiers.contains(KeyModifiers::ALT) =>
        {
            insert_input_char(state, ch);
            reset_history_navigation(state);
            false
        }
        _ => false,
    }
}

fn composer_input_route(state: &State) -> ComposerInputRoute {
    if state.approval_prompt.is_some() {
        return ComposerInputRoute::Approval;
    }

    if state.user_prompt.is_some() {
        return ComposerInputRoute::UserPrompt;
    }

    if state.run_picker.is_some() {
        return ComposerInputRoute::RunPicker;
    }

    ComposerInputRoute::Message
}

fn handle_composer_route_key(state: &mut State, key: KeyEvent, route: ComposerInputRoute) -> bool {
    match route {
        ComposerInputRoute::Approval => handle_approval_route_key(state, key),
        ComposerInputRoute::UserPrompt => handle_user_prompt_route_key(state, key),
        ComposerInputRoute::RunPicker => handle_run_picker_route_key(state, key),
        ComposerInputRoute::Message => false,
    }
}

fn handle_approval_route_key(state: &mut State, key: KeyEvent) -> bool {
    match (key.code, key.modifiers) {
        (KeyCode::Char('y') | KeyCode::Char('Y'), modifiers) if plain_key_modifiers(modifiers) => {
            answer_approval(state, true);
            true
        }
        (KeyCode::Char('n') | KeyCode::Char('N'), modifiers) if plain_key_modifiers(modifiers) => {
            answer_approval(state, false);
            true
        }
        (KeyCode::Esc, _) => {
            answer_approval(state, false);
            true
        }
        (KeyCode::PageUp, _) => {
            scroll_transcript(state, 8);
            true
        }
        (KeyCode::PageDown, _) => {
            scroll_transcript(state, -8);
            true
        }
        _ => true,
    }
}

fn handle_user_prompt_route_key(state: &mut State, key: KeyEvent) -> bool {
    match (key.code, key.modifiers) {
        (KeyCode::Char('a'), modifiers)
            if user_prompt_accepts_text(state) && modifiers.contains(KeyModifiers::CONTROL) =>
        {
            move_input_home(state);
            true
        }
        (KeyCode::Char('e'), modifiers)
            if user_prompt_accepts_text(state) && modifiers.contains(KeyModifiers::CONTROL) =>
        {
            move_input_end(state);
            true
        }
        (KeyCode::Char('u'), modifiers)
            if user_prompt_accepts_text(state) && modifiers.contains(KeyModifiers::CONTROL) =>
        {
            kill_input_before_cursor(state);
            reset_history_navigation(state);
            true
        }
        (KeyCode::Char('k'), modifiers)
            if user_prompt_accepts_text(state) && modifiers.contains(KeyModifiers::CONTROL) =>
        {
            kill_input_after_cursor(state);
            reset_history_navigation(state);
            true
        }
        (KeyCode::Char('w'), modifiers)
            if user_prompt_accepts_text(state) && modifiers.contains(KeyModifiers::CONTROL) =>
        {
            delete_input_word_before_cursor(state);
            reset_history_navigation(state);
            true
        }
        (KeyCode::Up, _) => {
            move_user_prompt(state, -1);
            true
        }
        (KeyCode::Down, _) => {
            move_user_prompt(state, 1);
            true
        }
        (KeyCode::Enter, _) => {
            answer_user_prompt(state);
            true
        }
        (KeyCode::Backspace, _) if user_prompt_accepts_text(state) => {
            backspace_input(state);
            reset_history_navigation(state);
            true
        }
        (KeyCode::Delete, _) if user_prompt_accepts_text(state) => {
            delete_input(state);
            reset_history_navigation(state);
            true
        }
        (KeyCode::Left, _) if user_prompt_accepts_text(state) => {
            move_input_left(state);
            true
        }
        (KeyCode::Right, _) if user_prompt_accepts_text(state) => {
            move_input_right(state);
            true
        }
        (KeyCode::Home, _) if user_prompt_accepts_text(state) => {
            move_input_home(state);
            true
        }
        (KeyCode::End, _) if user_prompt_accepts_text(state) => {
            move_input_end(state);
            true
        }
        (KeyCode::Char(ch), modifiers) if plain_key_modifiers(modifiers) => {
            handle_user_prompt_char(state, ch);
            true
        }
        (KeyCode::PageUp, _) => {
            scroll_transcript(state, 8);
            true
        }
        (KeyCode::PageDown, _) => {
            scroll_transcript(state, -8);
            true
        }
        _ => true,
    }
}

fn handle_run_picker_route_key(state: &mut State, key: KeyEvent) -> bool {
    match (key.code, key.modifiers) {
        (KeyCode::Esc, _) => {
            state.run_picker = None;
            reset_history_navigation(state);
            true
        }
        (KeyCode::Enter, _) => {
            let _ = resume_selected_run(state);
            true
        }
        (KeyCode::Home, _) => {
            select_run_picker(state, 0);
            true
        }
        (KeyCode::End, _) => {
            select_last_run_picker_item(state);
            true
        }
        (KeyCode::PageUp, _) => {
            move_run_picker(state, -5);
            true
        }
        (KeyCode::PageDown, _) => {
            move_run_picker(state, 5);
            true
        }
        (KeyCode::Up, _) => {
            move_run_picker(state, -1);
            true
        }
        (KeyCode::Down, _) => {
            move_run_picker(state, 1);
            true
        }
        (KeyCode::Char('l') | KeyCode::Char('L'), modifiers) if plain_key_modifiers(modifiers) => {
            let _ = show_selected_run_logs(state);
            true
        }
        (KeyCode::Char('f') | KeyCode::Char('F'), modifiers) if plain_key_modifiers(modifiers) => {
            let _ = fork_selected_run(state);
            true
        }
        _ => true,
    }
}

fn handle_pager_key(state: &mut State, key: KeyEvent) -> bool {
    match (key.code, key.modifiers) {
        (KeyCode::Esc, _) => {
            state.pager = None;
            true
        }
        (KeyCode::Char('q') | KeyCode::Char('Q'), modifiers) if plain_key_modifiers(modifiers) => {
            state.pager = None;
            true
        }
        (KeyCode::Home, _) => {
            if let Some(pager) = state.pager.as_mut() {
                pager.scroll = 0;
            }
            true
        }
        (KeyCode::End, _) => {
            let (width, _height) = terminal::terminal_size();
            let max_scroll = pager_line_count(state, width.max(60)).saturating_sub(1);
            if let Some(pager) = state.pager.as_mut() {
                pager.scroll = max_scroll;
            }
            true
        }
        (KeyCode::PageUp, _) => {
            scroll_pager(state, -8);
            true
        }
        (KeyCode::PageDown, _) => {
            scroll_pager(state, 8);
            true
        }
        (KeyCode::Up, _) => {
            scroll_pager(state, -1);
            true
        }
        (KeyCode::Down, _) => {
            scroll_pager(state, 1);
            true
        }
        _ => true,
    }
}

fn scroll_pager(state: &mut State, rows: isize) {
    if let Some(pager) = state.pager.as_mut() {
        if rows >= 0 {
            pager.scroll = pager.scroll.saturating_add(rows as usize);
        } else {
            pager.scroll = pager.scroll.saturating_sub(rows.unsigned_abs());
        }
    }
}

fn plain_key_modifiers(modifiers: KeyModifiers) -> bool {
    !modifiers.contains(KeyModifiers::CONTROL) && !modifiers.contains(KeyModifiers::ALT)
}

fn scroll_transcript(state: &mut State, rows: isize) {
    if rows >= 0 {
        state.scroll = state.scroll.saturating_add(rows as usize);
    } else {
        state.scroll = state.scroll.saturating_sub(rows.unsigned_abs());
    }
    state.transcript_focus_cell = None;
}

fn preserve_resize_scroll(state: &mut State, width: u16, height: u16) {
    if state.scroll == 0 {
        return;
    }

    let composer_height = Composer::new(state, width, height).height;
    let body_height = transcript_body_height(height, composer_height);
    let lines = transcript_lines(state, width as usize);

    if let Some(cell_index) = state
        .transcript_focus_cell
        .filter(|index| *index < state.cells.len())
    {
        let anchors = transcript_anchor_indices(&lines, TranscriptAnchorKind::Block);
        if let Some(anchor) = anchors.get(cell_index).copied() {
            state.scroll = scroll_for_anchor(lines.len(), anchor, body_height);
            return;
        }
    }

    state.scroll = state.scroll.min(lines.len().saturating_sub(body_height));
}

fn transcript_body_height(terminal_height: u16, composer_height: u16) -> usize {
    let top = 4;

    terminal_height
        .saturating_sub(top)
        .saturating_sub(composer_height)
        .saturating_sub(1) as usize
}

fn transcript_key_context_available(state: &State) -> bool {
    state.input.is_empty() && composer_input_route(state) == ComposerInputRoute::Message
}

fn apply_transcript_key_action(state: &mut State, action: keymap::TranscriptKeyAction) {
    match action {
        keymap::TranscriptKeyAction::PreviousBlock => jump_transcript_anchor(
            state,
            TranscriptAnchorKind::Block,
            TranscriptJumpDirection::Previous,
        ),
        keymap::TranscriptKeyAction::NextBlock => jump_transcript_anchor(
            state,
            TranscriptAnchorKind::Block,
            TranscriptJumpDirection::Next,
        ),
        keymap::TranscriptKeyAction::PreviousDiff => jump_transcript_anchor(
            state,
            TranscriptAnchorKind::Diff,
            TranscriptJumpDirection::Previous,
        ),
        keymap::TranscriptKeyAction::NextDiff => jump_transcript_anchor(
            state,
            TranscriptAnchorKind::Diff,
            TranscriptJumpDirection::Next,
        ),
        keymap::TranscriptKeyAction::ToggleBlock => toggle_current_transcript_block(state),
        keymap::TranscriptKeyAction::OpenPager => open_current_transcript_block_pager(state),
    }
}

fn open_current_transcript_block_pager(state: &mut State) {
    let (width, height) = terminal::terminal_size();
    open_current_transcript_block_pager_with_view(state, width.max(60), height.max(18));
}

fn open_current_transcript_block_pager_with_view(state: &mut State, width: u16, height: u16) {
    let Some(cell_index) = current_visible_cell_index(state, width, height) else {
        return;
    };

    if state.cells.get(cell_index).is_none() {
        return;
    }

    state.pager = Some(Pager {
        cell: cell_index,
        scroll: 0,
    });
    state.transcript_focus_cell = Some(cell_index);
}

fn pager_line_count(state: &State, width: u16) -> usize {
    let Some(pager) = &state.pager else {
        return 0;
    };

    let Some(cell) = state.cells.get(pager.cell) else {
        return 0;
    };

    let workspace = state.session.workspace_root();
    let body_width = width.saturating_sub(8).max(16) as usize;
    2 + render_cell_body_lines_with_collapse(cell, body_width, &workspace, false).len()
}

fn toggle_current_transcript_block(state: &mut State) {
    let (width, height) = terminal::terminal_size();
    toggle_current_transcript_block_with_view(state, width.max(60), height.max(18));
}

fn toggle_current_transcript_block_with_view(state: &mut State, width: u16, height: u16) {
    let Some(cell_index) = current_visible_cell_index(state, width, height) else {
        return;
    };

    let Some(cell) = state.cells.get_mut(cell_index) else {
        return;
    };

    cell.toggle_collapsed();
    state.transcript_focus_cell = Some(cell_index);

    let composer_height = Composer::new(state, width, height).height;
    let body_height = transcript_body_height(height, composer_height);
    let lines = transcript_lines(state, width as usize);
    let anchors = transcript_anchor_indices(&lines, TranscriptAnchorKind::Block);

    if let Some(anchor) = anchors.get(cell_index).copied() {
        state.scroll = scroll_for_anchor(lines.len(), anchor, body_height);
    }
}

fn current_visible_cell_index(state: &State, width: u16, height: u16) -> Option<usize> {
    if let Some(cell_index) = state
        .transcript_focus_cell
        .filter(|index| *index < state.cells.len())
    {
        return Some(cell_index);
    }

    let composer_height = Composer::new(state, width, height).height;
    let body_height = transcript_body_height(height, composer_height);
    let lines = transcript_lines(state, width as usize);
    let anchors = transcript_anchor_indices(&lines, TranscriptAnchorKind::Block);

    if anchors.is_empty() {
        return None;
    }

    let start = visible_window_start(lines.len(), state.scroll, body_height);

    anchors
        .iter()
        .enumerate()
        .rev()
        .find(|(_cell, anchor)| **anchor <= start)
        .map(|(cell, _anchor)| cell)
        .or_else(|| {
            anchors
                .iter()
                .enumerate()
                .find(|(_cell, anchor)| **anchor >= start)
                .map(|(cell, _anchor)| cell)
        })
}

fn jump_transcript_anchor(
    state: &mut State,
    kind: TranscriptAnchorKind,
    direction: TranscriptJumpDirection,
) {
    let (width, height) = terminal::terminal_size();
    jump_transcript_anchor_with_view(state, kind, direction, width.max(60), height.max(18));
}

fn jump_transcript_anchor_with_view(
    state: &mut State,
    kind: TranscriptAnchorKind,
    direction: TranscriptJumpDirection,
    width: u16,
    height: u16,
) {
    let composer_height = Composer::new(state, width, height).height;
    let body_height = transcript_body_height(height, composer_height);
    let lines = transcript_lines(state, width as usize);
    let anchors = transcript_anchor_indices(&lines, kind);

    let Some(target) =
        select_transcript_anchor(&anchors, lines.len(), state.scroll, body_height, direction)
    else {
        return;
    };

    state.scroll = scroll_for_anchor(lines.len(), target, body_height);
    state.transcript_focus_cell = cell_index_for_line_anchor(&lines, target);
}

fn cell_index_for_line_anchor(lines: &[RenderLine], target: usize) -> Option<usize> {
    transcript_anchor_indices(lines, TranscriptAnchorKind::Block)
        .iter()
        .enumerate()
        .rev()
        .find(|(_cell, anchor)| **anchor <= target)
        .map(|(cell, _anchor)| cell)
}

fn select_transcript_anchor(
    anchors: &[usize],
    total_lines: usize,
    scroll: usize,
    body_height: usize,
    direction: TranscriptJumpDirection,
) -> Option<usize> {
    if anchors.is_empty() || total_lines == 0 || body_height == 0 {
        return None;
    }

    let end = total_lines.saturating_sub(scroll).min(total_lines);
    let start = end.saturating_sub(body_height);

    match direction {
        TranscriptJumpDirection::Previous => {
            let reference = if scroll == 0 { end } else { start };
            anchors
                .iter()
                .rev()
                .copied()
                .find(|index| *index < reference)
        }
        TranscriptJumpDirection::Next => {
            let reference = if scroll == 0 {
                end
            } else {
                start.saturating_add(1)
            };
            anchors.iter().copied().find(|index| *index >= reference)
        }
    }
}

fn scroll_for_anchor(total_lines: usize, target: usize, body_height: usize) -> usize {
    let end = target.saturating_add(body_height).min(total_lines);
    total_lines.saturating_sub(end)
}

fn visible_window_start(total_lines: usize, scroll: usize, body_height: usize) -> usize {
    let end = total_lines.saturating_sub(scroll).min(total_lines);
    end.saturating_sub(body_height)
}

fn transcript_anchor_indices(lines: &[RenderLine], kind: TranscriptAnchorKind) -> Vec<usize> {
    match kind {
        TranscriptAnchorKind::Block => lines
            .iter()
            .enumerate()
            .filter_map(|(index, line)| line.text.starts_with("╭─ ").then_some(index))
            .collect(),
        TranscriptAnchorKind::Diff => diff_anchor_indices(lines),
    }
}

fn diff_anchor_indices(lines: &[RenderLine]) -> Vec<usize> {
    let mut anchors = Vec::new();
    let mut block_start = None;
    let mut block_has_diff = false;

    for (index, line) in lines.iter().enumerate() {
        if line.text.starts_with("│ ╭─ ") && line.tone == Tone::Border {
            block_start = Some(index);
            block_has_diff = line.text.starts_with("│ ╭─ diff")
                || line.text.starts_with("│ ╭─ patch")
                || line.text.starts_with("│ ╭─ udiff")
                || line.text.starts_with("│ ╭─ gitdiff");
            continue;
        }

        if block_start.is_some()
            && matches!(line.tone, Tone::DiffAdd | Tone::DiffDelete | Tone::DiffHunk)
        {
            block_has_diff = true;
        }

        if block_start.is_some() && line.text == "│ ╰─" && line.tone == Tone::Border {
            if block_has_diff {
                if let Some(start) = block_start {
                    anchors.push(start);
                }
            }

            block_start = None;
            block_has_diff = false;
        }
    }

    if block_has_diff {
        if let Some(start) = block_start {
            anchors.push(start);
        }
    }

    anchors
}

fn cancel_pending(state: &mut State) -> bool {
    let Some(input) = state
        .pending
        .as_ref()
        .and_then(|pending| pending.input.as_ref())
        .cloned()
    else {
        return false;
    };

    match input.send(backend::StreamInput::Cancel) {
        Ok(()) => {
            if let Some(pending) = state.pending.as_mut() {
                pending.label = "interrupting".to_string();
            }
            state.approval_prompt = None;
            state.user_prompt = None;
            state.add_cell(Role::System, "Interrupt requested.");
            true
        }
        Err(_) => {
            state.add_cell(
                Role::Error,
                "Unable to interrupt Holt; backend input is closed.",
            );
            true
        }
    }
}

fn submit(state: &mut State) -> bool {
    let input = state.input.trim().to_string();
    clear_input(state);
    reset_history_navigation(state);
    state.run_picker = None;

    if state.user_prompt.is_some() {
        set_input(state, input);
        answer_user_prompt(state);
        return false;
    }

    if input.is_empty() {
        return false;
    }

    if state.pending.is_some() {
        state.add_cell(
            Role::System,
            "A command is already running. Wait for it to finish.",
        );
        return false;
    }

    match commands::parse(&input) {
        Ok(Some(SlashCommand::Exit)) => return true,
        Ok(Some(SlashCommand::Help)) => show_help(state),
        Ok(Some(SlashCommand::Keymap)) => show_keymap(state),
        Ok(Some(SlashCommand::Permissions { mode })) => show_or_set_permissions(state, mode),
        Ok(Some(SlashCommand::Clear)) => {
            state.cells.clear();
            state.run_picker = None;
            state.user_prompt = None;
        }
        Ok(Some(SlashCommand::History)) => show_history(state),
        Ok(Some(SlashCommand::Status)) => {
            start_backend(state, "status", state.session.command_args("status"))
        }
        Ok(Some(SlashCommand::Doctor)) => {
            start_backend(state, "doctor", state.session.command_args("doctor"))
        }
        Ok(Some(SlashCommand::Model)) => {
            start_backend(state, "model", state.session.command_args("model"))
        }
        Ok(Some(SlashCommand::Goal { prompt })) => {
            set_interaction_mode(state, InteractionMode::Goal);
            if let Some(prompt) = prompt.filter(|value| !value.trim().is_empty()) {
                submit_prompt(state, prompt.trim());
            }
        }
        Ok(Some(SlashCommand::Build)) => set_interaction_mode(state, InteractionMode::Build),
        Ok(Some(SlashCommand::Diff { view })) => {
            start_backend(state, "diff", state.session.diff_args(view))
        }
        Ok(Some(SlashCommand::Logs { run_ref, view })) => start_backend(
            state,
            "logs",
            state.session.logs_args(run_ref.as_deref(), view),
        ),
        Ok(Some(SlashCommand::Runs)) => show_runs(state),
        Ok(Some(SlashCommand::Resume { run_ref })) => {
            let run_ref = run_ref.as_deref().unwrap_or("latest");
            let args = state.session.interactive_resume_args(run_ref);
            start_streamed_turn(state, "resume", args, false);
        }
        Ok(Some(SlashCommand::Fork { run_ref })) => {
            let run_ref = run_ref.as_deref().unwrap_or("latest");
            let args = state.session.interactive_fork_args(run_ref);
            start_streamed_turn(state, "fork", args, false);
        }
        Ok(None) => {
            submit_prompt(state, input.as_str());
        }
        Err(error) => {
            state.add_cell(
                Role::Error,
                format!("{error}\nRun /help for available commands."),
            );
        }
    }

    false
}

fn set_interaction_mode(state: &mut State, mode: InteractionMode) {
    state.session.set_interaction_mode(mode);
    state.add_cell(
        Role::System,
        format!("Mode: {}", state.session.interaction_mode_label()),
    );
}

fn toggle_interaction_mode(state: &mut State) {
    state.session.toggle_interaction_mode();
    state.add_cell(
        Role::System,
        format!("Mode: {}", state.session.interaction_mode_label()),
    );
}

fn submit_prompt(state: &mut State, prompt: &str) {
    state.add_cell(Role::User, prompt.to_string());
    let chat_messages = state.recent_chat_messages();
    let _ = history::remember_prompt(&mut state.history, &state.session.workspace_root(), prompt);
    state.chat_messages.push(ChatMessage::user(prompt));
    let args = state
        .session
        .interactive_turn_run_args(prompt, &chat_messages);
    let label = match state.session.interaction_mode {
        InteractionMode::Build => "working",
        InteractionMode::Goal => "goal",
    };
    start_streamed_turn(state, label, args, true);
}

fn complete_slash_input(state: &mut State) -> bool {
    if let Some(command) = selected_slash_command(state) {
        if slash_prefix_text(&state.input).is_some_and(|text| text != command.name) {
            set_input(
                state,
                slash_completion_for_input(&state.input, command.name),
            );
            return true;
        }
    }

    let Some(completed) = commands::complete(&state.input) else {
        return false;
    };

    set_input(state, completed);
    true
}

fn move_slash_selection(state: &mut State, delta: isize) -> bool {
    if composer_input_route(state) != ComposerInputRoute::Message {
        return false;
    }

    let count = visible_slash_suggestion_specs(&state.input).len();
    if count == 0 {
        state.slash_selection = 0;
        return false;
    }

    if delta < 0 {
        state.slash_selection = if state.slash_selection == 0 {
            count - 1
        } else {
            state.slash_selection.saturating_sub(1)
        };
    } else if delta > 0 {
        state.slash_selection = (state.slash_selection + 1) % count;
    }

    true
}

fn selected_slash_command(state: &State) -> Option<&'static commands::SlashCommandSpec> {
    let matches = visible_slash_suggestion_specs(&state.input);
    if matches.is_empty() {
        return None;
    }

    matches
        .get(state.slash_selection.min(matches.len() - 1))
        .copied()
}

fn slash_completion_for_input(input: &str, command_name: &str) -> String {
    let leading = input.len() - input.trim_start().len();
    let prefix = &input[..leading];
    format!("{prefix}{command_name}")
}

fn slash_prefix_text(input: &str) -> Option<&str> {
    let trimmed = input.trim_start();
    if !trimmed.starts_with('/') || trimmed.contains(char::is_whitespace) {
        return None;
    }

    Some(trimmed)
}

fn set_input(state: &mut State, input: String) {
    state.input = input;
    state.input_cursor = input_len(&state.input);
    state.slash_selection = 0;
}

fn clear_input(state: &mut State) {
    state.input.clear();
    state.input_cursor = 0;
}

fn reset_history_navigation(state: &mut State) {
    state.history_cursor = None;
    state.history_search = None;
    state.history_draft.clear();
}

fn insert_input_char(state: &mut State, ch: char) {
    let index = byte_index(&state.input, state.input_cursor);
    state.input.insert(index, ch);
    state.input_cursor += 1;
}

fn backspace_input(state: &mut State) {
    if state.input_cursor == 0 {
        return;
    }

    let start = byte_index(&state.input, state.input_cursor - 1);
    let end = byte_index(&state.input, state.input_cursor);
    state.input.replace_range(start..end, "");
    state.input_cursor -= 1;
}

fn delete_input(state: &mut State) {
    if state.input_cursor >= input_len(&state.input) {
        return;
    }

    let start = byte_index(&state.input, state.input_cursor);
    let end = byte_index(&state.input, state.input_cursor + 1);
    state.input.replace_range(start..end, "");
}

fn kill_input_before_cursor(state: &mut State) {
    let end = byte_index(&state.input, state.input_cursor);
    state.input.replace_range(0..end, "");
    state.input_cursor = 0;
}

fn kill_input_after_cursor(state: &mut State) {
    let start = byte_index(&state.input, state.input_cursor);
    state.input.truncate(start);
}

fn delete_input_word_before_cursor(state: &mut State) {
    if state.input_cursor == 0 {
        return;
    }

    let chars = state.input.chars().collect::<Vec<_>>();
    let mut start = state.input_cursor;

    while start > 0 && chars[start - 1].is_whitespace() {
        start -= 1;
    }

    while start > 0 && !chars[start - 1].is_whitespace() {
        start -= 1;
    }

    let byte_start = byte_index(&state.input, start);
    let byte_end = byte_index(&state.input, state.input_cursor);
    state.input.replace_range(byte_start..byte_end, "");
    state.input_cursor = start;
}

fn move_input_left(state: &mut State) {
    state.input_cursor = state.input_cursor.saturating_sub(1);
}

fn move_input_right(state: &mut State) {
    state.input_cursor = (state.input_cursor + 1).min(input_len(&state.input));
}

fn move_input_home(state: &mut State) {
    state.input_cursor = 0;
}

fn move_input_end(state: &mut State) {
    state.input_cursor = input_len(&state.input);
}

fn input_len(input: &str) -> usize {
    input.chars().count()
}

fn byte_index(text: &str, char_index: usize) -> usize {
    text.char_indices()
        .nth(char_index)
        .map(|(index, _)| index)
        .unwrap_or_else(|| text.len())
}

fn show_help(state: &mut State) {
    let rows = SLASH_COMMANDS
        .iter()
        .map(|command| format!("{:<18} {}", command.usage, command.description))
        .collect::<Vec<_>>()
        .join("\n");

    state.add_cell(
        Role::Assistant,
        format!("{rows}\n\nPlain text starts a request. Tab on an empty composer toggles build/goal mode. Shift+Enter or Ctrl-J inserts a newline."),
    );
}

fn show_keymap(state: &mut State) {
    let rows = keymap::formatted_rows(KEY_BINDINGS, &state.keymap).join("\n");

    state.add_cell(Role::Assistant, rows);
}

fn show_or_set_permissions(state: &mut State, mode: Option<commands::PermissionMode>) {
    if let Some(mode) = mode {
        state.session.set_permission_mode(mode);
    }

    state.add_cell(
        Role::Assistant,
        format!("Permissions: {}", state.session.permission_mode_label()),
    );
}

fn show_history(state: &mut State) {
    if state.history.is_empty() {
        state.add_cell(Role::Assistant, "No project prompt history yet.");
        return;
    }

    let rows =
        history::recent_prompt_rows(&state.history, history::HISTORY_DISPLAY_LIMIT).join("\n");
    state.add_cell(Role::Assistant, rows);
}

fn show_runs(state: &mut State) {
    start_run_list(state);
}

fn open_user_prompt(
    state: &mut State,
    question: String,
    description: Option<String>,
    options: Vec<QuestionOption>,
) {
    let options = options
        .into_iter()
        .map(|option| UserPromptOption {
            label: option.label,
            value: option.value,
            description: option.description,
        })
        .collect::<Vec<_>>();
    state.streaming_activity_cell = None;
    state.approval_prompt = None;
    state.user_prompt = Some(UserPrompt {
        question,
        description,
        options,
        selected: 0,
    });
}

fn move_user_prompt(state: &mut State, delta: isize) {
    let Some(prompt) = state.user_prompt.as_mut() else {
        return;
    };

    if prompt.options.is_empty() {
        return;
    }

    let last = prompt.options.len() - 1;
    prompt.selected = if delta < 0 {
        prompt.selected.saturating_sub(1)
    } else {
        (prompt.selected + 1).min(last)
    };
}

fn answer_user_prompt(state: &mut State) {
    let Some(prompt) = state.user_prompt.take() else {
        return;
    };

    let answer = if let Some(option) = prompt.options.get(prompt.selected) {
        option.value.clone()
    } else {
        state.input.trim().to_string()
    };

    if answer.is_empty() {
        state.user_prompt = Some(prompt);
        return;
    }

    let Some(pending) = state.pending.as_ref() else {
        state.add_cell(Role::Error, "Holt is no longer waiting for input.");
        clear_input(state);
        return;
    };

    let Some(input) = pending.input.as_ref() else {
        state.add_cell(Role::Error, "This command cannot receive user input.");
        clear_input(state);
        return;
    };

    match input.send(backend::StreamInput::Line(format!("{answer}\n"))) {
        Ok(()) => {
            state.add_cell(Role::User, answer);
            clear_input(state);
        }
        Err(_) => {
            state.add_cell(Role::Error, "Holt is no longer accepting user input.");
            clear_input(state);
        }
    }
}

fn handle_user_prompt_char(state: &mut State, ch: char) {
    if let Some(index) = user_prompt_digit_index(state, ch) {
        if let Some(prompt) = state.user_prompt.as_mut() {
            prompt.selected = index;
        }
        answer_user_prompt(state);
    } else if user_prompt_accepts_text(state) {
        insert_input_char(state, ch);
        reset_history_navigation(state);
    }
}

fn user_prompt_digit_index(state: &State, ch: char) -> Option<usize> {
    let digit = ch.to_digit(10)? as usize;
    if digit == 0 {
        return None;
    }

    let index = digit - 1;
    let prompt = state.user_prompt.as_ref()?;

    if index < prompt.options.len() {
        Some(index)
    } else {
        None
    }
}

fn user_prompt_accepts_text(state: &State) -> bool {
    state
        .user_prompt
        .as_ref()
        .is_some_and(|prompt| prompt.options.is_empty())
}

fn open_run_picker(state: &mut State, runs: Vec<RunSummary>) {
    state.run_picker = Some(RunPicker { runs, selected: 0 });
}

fn move_run_picker(state: &mut State, delta: isize) {
    let Some(picker) = state.run_picker.as_mut() else {
        return;
    };

    if picker.runs.is_empty() {
        return;
    }

    let last = picker.runs.len() - 1;
    let step = delta.unsigned_abs();
    picker.selected = if delta < 0 {
        picker.selected.saturating_sub(step)
    } else {
        picker.selected.saturating_add(step).min(last)
    };
}

fn select_run_picker(state: &mut State, selected: usize) {
    let Some(picker) = state.run_picker.as_mut() else {
        return;
    };

    if picker.runs.is_empty() {
        return;
    }

    picker.selected = selected.min(picker.runs.len() - 1);
}

fn select_last_run_picker_item(state: &mut State) {
    let Some(last) = state
        .run_picker
        .as_ref()
        .and_then(|picker| picker.runs.len().checked_sub(1))
    else {
        return;
    };

    select_run_picker(state, last);
}

fn resume_selected_run(state: &mut State) -> bool {
    if state.pending.is_some() {
        return false;
    }

    let Some(picker) = state.run_picker.take() else {
        return false;
    };

    let Some(run) = picker.runs.get(picker.selected).cloned() else {
        return false;
    };

    let run_id = run.id.clone();
    state.add_cell(Role::User, resume_context_content(&run));
    let args = state.session.interactive_resume_args(&run_id);
    start_streamed_turn(state, "resume", args, false);
    true
}

fn fork_selected_run(state: &mut State) -> bool {
    let Some(picker) = state.run_picker.take() else {
        return false;
    };

    let Some(run) = picker.runs.get(picker.selected).cloned() else {
        return false;
    };

    let run_id = run.id.clone();
    state.add_cell(Role::User, fork_context_content(&run));
    let args = state.session.interactive_fork_args(&run_id);
    start_streamed_turn(state, "fork", args, false);
    true
}

fn show_selected_run_logs(state: &mut State) -> bool {
    if state.pending.is_some() {
        return false;
    }

    let Some(picker) = state.run_picker.take() else {
        return false;
    };

    let Some(run) = picker.runs.get(picker.selected) else {
        return false;
    };

    let run_id = run.id.clone();
    state.add_cell(Role::User, format!("/logs {run_id}"));
    start_backend(
        state,
        "logs",
        state
            .session
            .logs_args(Some(&run_id), commands::LogView::Activity),
    );
    true
}

fn answer_approval(state: &mut State, approve: bool) {
    let Some(prompt) = state.approval_prompt.take() else {
        return;
    };

    let Some(pending) = state.pending.as_ref() else {
        state.add_cell(Role::Error, "Holt is no longer waiting for approval.");
        return;
    };

    let Some(input) = pending.input.as_ref() else {
        state.add_cell(Role::Error, "This command cannot receive approval input.");
        return;
    };

    let line = if approve { "y\n" } else { "n\n" };

    match input.send(backend::StreamInput::Line(line.to_string())) {
        Ok(()) => {
            let decision = if approve { "approved" } else { "denied" };
            state.add_activity_line(
                Role::System,
                format!("Approval sent: {decision} · {}", prompt.action),
                true,
            );
        }
        Err(_) => {
            state.add_cell(Role::Error, "Holt is no longer accepting approval input.");
        }
    }
}

fn one_line(value: &str) -> String {
    value.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn preview_line(value: &str, max_chars: usize) -> String {
    ui::truncate(&one_line(value), max_chars)
}

fn resume_context_content(run: &RunSummary) -> String {
    let mut lines = vec![
        format!("/resume {}", run.id),
        String::new(),
        "Resuming run".to_string(),
        format!("- Status: {}", run.status),
        format!("- Objective: {}", preview_line(&run.objective, 180)),
    ];

    if let Some(artifact) = run.artifact.as_ref().filter(|value| !value.is_empty()) {
        lines.push(format!("- Artifact: {artifact}"));
    }

    match run
        .answer_preview
        .as_ref()
        .filter(|value| !value.is_empty())
    {
        Some(answer) => lines.push(format!("- Latest answer: {answer}")),
        None => lines.push("- Latest answer: none recorded yet".to_string()),
    }

    lines.join("\n")
}

fn fork_context_content(run: &RunSummary) -> String {
    let mut lines = vec![
        format!("/fork {}", run.id),
        String::new(),
        "Forking run into a new branch.".to_string(),
        format!("- Status: {}", run.status),
        format!("- Objective: {}", run.objective),
    ];

    if let Some(artifact) = &run.artifact {
        lines.push(format!("- Artifact: {artifact}"));
    }

    match run
        .answer_preview
        .as_ref()
        .filter(|value| !value.is_empty())
    {
        Some(answer) => lines.push(format!("- Latest answer: {answer}")),
        None => lines.push("- Latest answer: none recorded yet".to_string()),
    }

    lines.join("\n")
}

fn run_summaries_from_output(output: backend::BackendOutput) -> Result<Vec<RunSummary>, String> {
    if output.code != 0 {
        return Err(backend_error(output));
    }

    let value = serde_json::from_str::<Value>(output.stdout.trim())
        .map_err(|error| format!("failed to decode runs response: {error}"))?;

    if value.get("schema_version").and_then(Value::as_str) != Some("holt_run_list/v1") {
        return Err("unexpected runs response schema".to_string());
    }

    let runs = value
        .get("runs")
        .and_then(Value::as_array)
        .ok_or_else(|| "runs response missing runs".to_string())?;

    runs.iter().map(run_summary_from_value).collect()
}

fn run_summary_from_value(value: &Value) -> Result<RunSummary, String> {
    Ok(RunSummary {
        id: required_string(value, "id")?,
        status: required_string(value, "status")?,
        objective: required_string(value, "objective")?,
        artifact: optional_string(value, "artifact"),
        answer_preview: optional_string(value, "latest_answer")
            .map(|answer| preview_line(&answer, 160)),
    })
}

fn required_string(value: &Value, key: &str) -> Result<String, String> {
    value
        .get(key)
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
        .ok_or_else(|| format!("runs response item missing {key}"))
}

fn optional_string(value: &Value, key: &str) -> Option<String> {
    value
        .get(key)
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
}

fn backend_error(output: backend::BackendOutput) -> String {
    let stderr = output.stderr.trim();
    let stdout = output.stdout.trim();

    if !stderr.is_empty() {
        format!("Holt finished with code {}.\n\n{stderr}", output.code)
    } else if !stdout.is_empty() {
        format!("Holt finished with code {}.\n\n{stdout}", output.code)
    } else {
        format!("Holt finished with code {}.", output.code)
    }
}

fn start_run_list(state: &mut State) {
    let (tx, rx) = mpsc::channel();
    let args = state.session.runs_json_args();

    thread::spawn(move || {
        let result = backend::capture(&args)
            .map_err(|error| error.to_string())
            .and_then(run_summaries_from_output);
        let _ = tx.send(PendingMessage::RunList(result));
    });

    state.pending = Some(Pending {
        label: "runs".to_string(),
        started: Instant::now(),
        rx,
        input: None,
        record_chat_response: false,
    });
    state.frame = 0;
    state.streaming_answer_cell = None;
    state.streaming_activity_cell = None;
    state.pending_answer_content.clear();
    state.run_picker = None;
    state.approval_prompt = None;
    state.user_prompt = None;
}

fn start_backend(state: &mut State, label: &str, args: Vec<String>) {
    let (tx, rx) = mpsc::channel();
    let label = label.to_string();

    thread::spawn(move || {
        let result = backend::capture(&args).map_err(|error| error.to_string());
        let _ = tx.send(PendingMessage::Finished(result, false));
    });

    state.pending = Some(Pending {
        label,
        started: Instant::now(),
        rx,
        input: None,
        record_chat_response: false,
    });
    state.frame = 0;
    state.streaming_answer_cell = None;
    state.streaming_activity_cell = None;
    state.pending_answer_content.clear();
    state.run_picker = None;
    state.approval_prompt = None;
    state.user_prompt = None;
}

fn start_streamed_turn(
    state: &mut State,
    label: &str,
    args: Vec<String>,
    record_chat_response: bool,
) {
    let (tx, rx) = mpsc::channel();
    let (input_tx, input_rx) = mpsc::channel();
    let label = label.to_string();

    thread::spawn(move || {
        let mut turn = TurnState::new();
        let output = backend::stream_jsonl_with_input(
            &args,
            |line| {
                handle_stream_line(&tx, &mut turn, line);
                Ok(())
            },
            input_rx,
        )
        .map_err(|error| error.to_string());

        let _ = tx.send(PendingMessage::Finished(output, record_chat_response));
    });

    state.pending = Some(Pending {
        label,
        started: Instant::now(),
        rx,
        input: Some(input_tx),
        record_chat_response,
    });
    state.frame = 0;
    state.streaming_answer_cell = None;
    state.streaming_activity_cell = None;
    state.pending_answer_content.clear();
    state.run_picker = None;
    state.approval_prompt = None;
    state.user_prompt = None;
}

fn handle_stream_line(
    tx: &mpsc::Sender<PendingMessage>,
    turn: &mut TurnState,
    line: backend::StreamLine,
) {
    match line {
        backend::StreamLine::Stdout(line) => handle_stream_stdout(tx, turn, line),
        backend::StreamLine::Stderr(line) => {
            if !line.trim().is_empty() {
                let _ = tx.send(PendingMessage::Action(RenderAction::Line {
                    tone: Tone::Error,
                    text: line,
                }));
            }
        }
    }
}

fn handle_stream_stdout(tx: &mpsc::Sender<PendingMessage>, turn: &mut TurnState, line: String) {
    if line.trim().is_empty() {
        return;
    }

    match serde_json::from_str::<Value>(&line) {
        Ok(event) => {
            for action in turn.apply_event(&event) {
                let _ = tx.send(PendingMessage::Action(action));
            }
        }
        Err(_) => {
            let _ = tx.send(PendingMessage::Action(RenderAction::Line {
                tone: Tone::Dim,
                text: line,
            }));
        }
    }
}

fn poll_pending(state: &mut State) -> Option<PendingMessage> {
    let pending = state.pending.as_ref()?;
    let record_chat_response = pending.record_chat_response;

    match pending.rx.try_recv() {
        Ok(message) => match message {
            PendingMessage::Action(_) => Some(message),
            PendingMessage::Finished(_, _) | PendingMessage::RunList(_) => {
                state.pending = None;
                Some(message)
            }
        },
        Err(mpsc::TryRecvError::Empty) => None,
        Err(mpsc::TryRecvError::Disconnected) => {
            state.pending = None;
            Some(PendingMessage::Finished(
                Err("Holt disconnected".to_string()),
                record_chat_response,
            ))
        }
    }
}

fn finish_pending(state: &mut State, message: PendingMessage) {
    match message {
        PendingMessage::Action(action) => {
            apply_render_action(state, action);
        }
        PendingMessage::Finished(result, record_chat_response) => {
            let had_streaming_answer = state.streaming_answer_cell.take().is_some();
            let assistant_answer = state.pending_answer_content.trim().to_string();
            let successful = matches!(&result, Ok(output) if output.code == 0);
            state.streaming_activity_cell = None;
            state.approval_prompt = None;
            state.user_prompt = None;
            finish_pending_output(state, result, had_streaming_answer);
            if record_chat_response && successful && !assistant_answer.is_empty() {
                state
                    .chat_messages
                    .push(ChatMessage::assistant(assistant_answer));
            }
            state.pending_answer_content.clear();
        }
        PendingMessage::RunList(result) => {
            state.streaming_activity_cell = None;
            state.approval_prompt = None;
            state.user_prompt = None;

            match result {
                Ok(runs) if runs.is_empty() => {
                    state.run_picker = None;
                    state.add_cell(Role::Assistant, "No runs yet.");
                }
                Ok(runs) => open_run_picker(state, runs),
                Err(error) => state.add_cell(Role::Error, format!("Could not read runs: {error}")),
            }
        }
    }
}

fn apply_render_action(state: &mut State, action: RenderAction) {
    match action {
        RenderAction::Line { tone, text } => {
            let role = if tone == Tone::Error {
                Role::Error
            } else {
                Role::System
            };
            state.streaming_activity_cell = None;
            state.add_cell(role, text);
        }
        RenderAction::Activity {
            tone,
            text,
            detail,
            terminal,
            control,
        } => {
            if tui_transient_activity(terminal, detail.as_deref(), control.as_ref()) {
                if let Some(pending) = state.pending.as_mut() {
                    pending.label = activity_spinner_label(&text).to_string();
                }
                state.streaming_activity_cell = None;
                return;
            }

            match control {
                Some(ActivityControl::Approval { action }) => {
                    state.approval_prompt = Some(ApprovalPrompt { action });
                    state.user_prompt = None;
                }
                Some(ActivityControl::UserInput {
                    question,
                    description,
                    options,
                }) => {
                    open_user_prompt(state, question, description, options);
                    return;
                }
                None if terminal => {
                    state.approval_prompt = None;
                    state.user_prompt = None;
                }
                None => {}
            }

            let role = if tone == Tone::Error {
                Role::Error
            } else {
                Role::System
            };
            state.add_activity_line(role, activity_content(&text, detail.as_deref()), terminal);
        }
        RenderAction::FileEdit { summary } => {
            state.streaming_activity_cell = None;
            state.approval_prompt = None;
            state.user_prompt = None;
            state.add_file_edit_cell(summary);
        }
        RenderAction::Answer { content } => {
            state.pending_answer_content.push_str(&content);
            state.add_answer_delta(&content);
        }
        RenderAction::Footer { text } => {
            state.streaming_activity_cell = None;
            state.add_cell(Role::System, text);
        }
    }
}

fn tui_transient_activity(
    terminal: bool,
    detail: Option<&str>,
    control: Option<&ActivityControl>,
) -> bool {
    !terminal && detail.map(str::trim).unwrap_or("").is_empty() && control.is_none()
}

fn activity_spinner_label(text: &str) -> &str {
    text.strip_prefix("◐ ")
        .or_else(|| text.strip_prefix("✓ "))
        .or_else(|| text.strip_prefix("× "))
        .or_else(|| text.strip_prefix("• "))
        .or_else(|| text.strip_prefix("! "))
        .or_else(|| text.strip_prefix("? "))
        .unwrap_or(text)
}

fn activity_content(text: &str, detail: Option<&str>) -> String {
    match detail {
        Some(detail) if !detail.trim().is_empty() => format!("{text}\n{detail}"),
        _ => text.to_string(),
    }
}

fn finish_pending_output(
    state: &mut State,
    result: Result<backend::BackendOutput, String>,
    had_streaming_answer: bool,
) {
    match result {
        Ok(output) if output.code == 0 => {
            let text = output.stdout.trim();

            if had_streaming_answer {
                if !output.stderr.trim().is_empty() {
                    state.add_cell(Role::System, output.stderr.trim().to_string());
                }
            } else if text.is_empty() {
                state.add_cell(Role::Assistant, "Done.");
            } else {
                state.add_cell(Role::Assistant, text.to_string());

                if !output.stderr.trim().is_empty() {
                    state.add_cell(Role::System, output.stderr.trim().to_string());
                }
            }
        }
        Ok(output) => {
            let mut text = format!("Holt finished with code {}.", output.code);

            if !output.stderr.trim().is_empty() {
                text.push_str("\n\n");
                text.push_str(output.stderr.trim());
            }

            if !output.stdout.trim().is_empty() {
                text.push_str("\n\n");
                text.push_str(output.stdout.trim());
            }

            state.add_cell(Role::Error, text);
        }
        Err(error) => state.add_cell(Role::Error, error),
    }
}

fn navigate_history(
    state: &mut State,
    direction: HistoryNavigationDirection,
) -> HistoryNavigationOutcome {
    if state.history.is_empty() {
        return HistoryNavigationOutcome::NoHistory;
    }

    if state.history_cursor.is_none() && direction == HistoryNavigationDirection::Newer {
        return HistoryNavigationOutcome::NotBrowsing;
    }

    if state.history_cursor.is_none() && direction == HistoryNavigationDirection::Older {
        state.history_draft = state.input.clone();
    }

    let current = state.history_cursor.unwrap_or(state.history.len());
    let next = match direction {
        HistoryNavigationDirection::Older => {
            if current == 0 {
                state.history.len() - 1
            } else {
                current - 1
            }
        }
        HistoryNavigationDirection::Newer => (current + 1).min(state.history.len()),
    };

    let outcome = if next >= state.history.len() {
        let draft = state.history_draft.clone();
        set_input(state, draft.clone());
        state.history_draft.clear();
        state.history_cursor = None;
        HistoryNavigationOutcome::RestoredDraft { draft }
    } else {
        let prompt = state.history[next].clone();
        set_input(state, prompt.clone());
        state.history_cursor = Some(next);
        HistoryNavigationOutcome::Recalled {
            index: next,
            prompt,
        }
    };
    state.history_search = None;
    outcome
}

fn search_history(state: &mut State) {
    let query = state
        .history_search
        .as_ref()
        .map(|search| search.query.clone())
        .unwrap_or_else(|| state.input.clone());
    let before = state
        .history_search
        .as_ref()
        .and_then(|search| search.cursor);

    let Some(index) = history::previous_prompt_match(&state.history, &query, before) else {
        state.history_search = Some(HistorySearch {
            query,
            cursor: before,
            status: HistorySearchStatus::NotFound,
        });
        return;
    };

    set_input(state, state.history[index].clone());
    state.history_cursor = None;
    state.history_search = Some(HistorySearch {
        query,
        cursor: Some(index),
        status: HistorySearchStatus::Found,
    });
}

struct Composer {
    mode: ComposerMode,
    content: ComposerContent,
    rule: String,
    input_lines: Vec<String>,
    suggestions: Vec<ComposerSuggestion>,
    height: u16,
    cursor_x: u16,
    cursor_y: u16,
}

impl Composer {
    fn new(state: &State, width: u16, terminal_height: u16) -> Self {
        let input_width = width.saturating_sub(6).max(8) as usize;
        let mode = composer_mode(state);
        let accepts_text_input = mode.accepts_text_input();
        let input_view = visible_input_view(&state.input, input_width, 6, state.input_cursor);
        let input_lines = if accepts_text_input {
            input_view.lines
        } else {
            Vec::new()
        };
        let suggestions = if matches!(mode, ComposerMode::Message { .. }) {
            slash_suggestions(&state.input, state.slash_selection)
        } else {
            Vec::new()
        };
        let content = composer_content(state);
        let title = mode.title();
        let reserved = 3 + input_lines.len() + content.line_count() + suggestions.len();
        let height = reserved.clamp(4, 16) as u16;
        let rule_width = width
            .saturating_sub(4)
            .saturating_sub(title.chars().count() as u16) as usize;
        let rule = "─".repeat(rule_width);
        let composer_top = terminal_height.max(18).saturating_sub(height);
        let (cursor_x, cursor_y) = if accepts_text_input {
            (
                (4 + input_view.cursor_col).min(width.saturating_sub(1) as usize) as u16,
                composer_top + 1 + input_view.cursor_row as u16,
            )
        } else {
            (0, composer_top)
        };

        Self {
            mode,
            content,
            rule,
            input_lines,
            suggestions,
            height,
            cursor_x,
            cursor_y,
        }
    }
}

fn composer_mode(state: &State) -> ComposerMode {
    if let Some(prompt) = &state.user_prompt {
        return ComposerMode::Question {
            has_options: !prompt.options.is_empty(),
        };
    }

    if let Some(prompt) = &state.approval_prompt {
        return ComposerMode::Approval {
            action: prompt.action.clone(),
            pending: state
                .pending
                .as_ref()
                .map(|pending| pending_composer_status(state, pending)),
        };
    }

    if state.run_picker.is_some() {
        return ComposerMode::RunPicker;
    }

    if let Some(search) = &state.history_search {
        return ComposerMode::HistorySearch {
            query: search.query.clone(),
            status: match search.status {
                HistorySearchStatus::Found => ComposerHistorySearchStatus::Found,
                HistorySearchStatus::NotFound => ComposerHistorySearchStatus::NotFound,
            },
            navigation: transcript_navigation_labels(state),
        };
    }

    if let Some(pending) = &state.pending {
        return ComposerMode::Pending {
            label: pending.label.clone(),
            frame: state.frame,
            elapsed_millis: pending.started.elapsed().as_millis(),
            navigation: transcript_navigation_labels(state),
        };
    }

    ComposerMode::Message {
        interaction_mode: state.session.interaction_mode_label(),
        permission_mode: state.session.permission_mode_label(),
        navigation: transcript_navigation_labels(state),
    }
}

fn composer_content(state: &State) -> ComposerContent {
    if let Some(prompt) = &state.user_prompt {
        return ComposerContent::UserPrompt(user_prompt_view(prompt));
    }

    if let Some(picker) = &state.run_picker {
        return ComposerContent::RunPicker(run_picker_view(picker));
    }

    ComposerContent::None
}

fn user_prompt_view(prompt: &UserPrompt) -> UserPromptView {
    UserPromptView {
        question: prompt.question.clone(),
        description: prompt.description.clone(),
        options: prompt
            .options
            .iter()
            .map(|option| UserPromptOptionView {
                label: option.label.clone(),
                description: option.description.clone(),
            })
            .collect(),
        selected: prompt.selected,
    }
}

fn run_picker_view(picker: &RunPicker) -> RunPickerView {
    const MAX_VISIBLE_RUN_ROWS: usize = 5;

    let start = if picker.runs.len() <= MAX_VISIBLE_RUN_ROWS {
        0
    } else {
        picker
            .selected
            .saturating_sub(MAX_VISIBLE_RUN_ROWS / 2)
            .min(picker.runs.len().saturating_sub(MAX_VISIBLE_RUN_ROWS))
    };

    let rows = picker
        .runs
        .iter()
        .enumerate()
        .skip(start)
        .take(MAX_VISIBLE_RUN_ROWS)
        .map(|(index, run)| RunPickerRowView {
            selected: index == picker.selected,
            id: run.id.clone(),
            status: run.status.clone(),
            objective: preview_line(&run.objective, 64),
        })
        .collect::<Vec<_>>();

    let detail = picker
        .runs
        .get(picker.selected)
        .map(|run| RunPickerDetailView {
            status: run.status.clone(),
            objective: preview_line(&run.objective, 120),
            artifact: run.artifact.clone().filter(|value| !value.is_empty()),
            answer: run.answer_preview.clone().filter(|value| !value.is_empty()),
        });

    RunPickerView { rows, detail }
}

fn pending_composer_status(state: &State, pending: &Pending) -> PendingComposerStatus {
    PendingComposerStatus {
        label: pending.label.clone(),
        frame: state.frame,
        elapsed_millis: pending.started.elapsed().as_millis(),
    }
}

fn transcript_navigation_labels(state: &State) -> TranscriptNavigationLabels {
    TranscriptNavigationLabels {
        block: state.keymap.transcript_block_label(),
        diff: state.keymap.transcript_diff_label(),
        toggle: state.keymap.transcript_toggle_label(),
        pager: state.keymap.transcript_pager_label(),
    }
}

#[cfg(test)]
fn composer_title(state: &State) -> String {
    composer_mode(state).title()
}

#[cfg(test)]
fn composer_footer(state: &State) -> String {
    composer_mode(state).footer()
}

fn slash_suggestions(input: &str, selected: usize) -> Vec<ComposerSuggestion> {
    let show_no_match = slash_prefix_text(input).is_some_and(|trimmed| trimmed != "/");
    let specs = visible_slash_suggestion_specs(input);
    let selected = selected.min(specs.len().saturating_sub(1));
    let matches = specs
        .into_iter()
        .take(5)
        .enumerate()
        .map(|(index, command)| ComposerSuggestion {
            selected: index == selected,
            usage: command.usage.to_string(),
            description: command.description.to_string(),
        })
        .collect::<Vec<_>>();

    if matches.is_empty() && show_no_match {
        vec![ComposerSuggestion {
            selected: false,
            usage: "no match".to_string(),
            description: "no matching command".to_string(),
        }]
    } else {
        matches
    }
}

fn slash_suggestion_specs(input: &str) -> Vec<&'static commands::SlashCommandSpec> {
    let Some(trimmed) = slash_prefix_text(input) else {
        return Vec::new();
    };

    commands::matching_specs(trimmed)
}

fn visible_slash_suggestion_specs(input: &str) -> Vec<&'static commands::SlashCommandSpec> {
    slash_suggestion_specs(input).into_iter().take(5).collect()
}

fn visual_input_lines(input: &str, width: usize) -> Vec<String> {
    let mut lines = Vec::new();

    for raw in input.split('\n') {
        if raw.is_empty() {
            lines.push(String::new());
            continue;
        }

        let mut chunk = String::new();
        for ch in raw.chars() {
            if chunk.chars().count() >= width {
                lines.push(chunk);
                chunk = String::new();
            }
            chunk.push(ch);
        }

        lines.push(chunk);
    }

    if lines.is_empty() {
        lines.push(String::new());
    }

    lines
}

#[cfg(test)]
fn visible_input_lines(input: &str, width: usize, max_lines: usize) -> Vec<String> {
    visible_input_view(input, width, max_lines, input_len(input)).lines
}

struct InputView {
    lines: Vec<String>,
    cursor_row: usize,
    cursor_col: usize,
}

fn visible_input_view(input: &str, width: usize, max_lines: usize, cursor: usize) -> InputView {
    let lines = visual_input_lines(input, width);
    let (cursor_row, cursor_col) =
        input_cursor_position(input, width, cursor.min(input_len(input)));
    let max_lines = max_lines.max(1);

    if lines.len() > max_lines {
        let start = cursor_row
            .saturating_add(1)
            .saturating_sub(max_lines)
            .min(lines.len() - max_lines);
        let mut visible = lines[start..start + max_lines].to_vec();
        let visible_cursor_row = cursor_row.saturating_sub(start).min(visible.len() - 1);
        let mut visible_cursor_col = cursor_col;

        if start > 0 {
            if let Some(first) = visible.first_mut() {
                *first = format!("…{first}");
            }

            if visible_cursor_row == 0 {
                visible_cursor_col += 1;
            }
        }

        return InputView {
            lines: visible,
            cursor_row: visible_cursor_row,
            cursor_col: visible_cursor_col,
        };
    }

    InputView {
        lines,
        cursor_row,
        cursor_col,
    }
}

fn input_cursor_position(input: &str, width: usize, cursor: usize) -> (usize, usize) {
    let width = width.max(1);
    let mut row = 0usize;
    let mut col = 0usize;

    for ch in input.chars().take(cursor) {
        if ch == '\n' {
            row += 1;
            col = 0;
        } else {
            if col >= width {
                row += 1;
                col = 0;
            }
            col += 1;
        }
    }

    (row, col)
}

#[cfg(test)]
mod tests {
    use super::{
        activity_content, answer_approval, answer_user_prompt, apply_render_action,
        composer_content, composer_footer, composer_input_route, composer_mode, composer_title,
        finish_pending, frame_view, handle_key, inline_viewport_height,
        jump_transcript_anchor_with_view, move_run_picker, move_user_prompt, navigate_history,
        open_current_transcript_block_pager_with_view, open_run_picker, open_user_prompt,
        preserve_resize_scroll, resume_context_content, scroll_for_anchor, set_input, show_keymap,
        show_or_set_permissions, transcript_anchor_indices, transcript_body_height,
        transcript_lines, transcript_visible_lines, visible_window_start, ApprovalPrompt, CellBody,
        ChatArgs, Composer, ComposerInputRoute, HistoryNavigationDirection,
        HistoryNavigationOutcome, InteractionMode, Pending, PendingMessage, Role, RunSummary,
        State, TranscriptAnchorKind, TranscriptJumpDirection,
    };
    use crate::{
        backend::{BackendOutput, StreamInput},
        commands, history,
        tui_frame::{self, ratatui_render_line, ComposerContent, ComposerMode},
        turn::{ActivityControl, FileEditStatus, FileEditSummary, QuestionOption, RenderAction},
        ui::{RenderLine, RenderSpan, Tone},
    };
    use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
    use holt_protocol::ChatMessage;
    use ratatui::{
        backend::TestBackend,
        buffer::Buffer,
        layout::Position as BufferPosition,
        style::{Color as RatColor, Modifier},
        Terminal as TestTerminal,
    };
    use std::{
        fs,
        path::PathBuf,
        sync::{
            atomic::{AtomicUsize, Ordering},
            mpsc,
        },
        time::{Instant, SystemTime, UNIX_EPOCH},
    };

    static TEMP_WORKSPACE_COUNTER: AtomicUsize = AtomicUsize::new(0);

    #[test]
    fn tui_inline_viewport_uses_visible_terminal_height() {
        assert_eq!(inline_viewport_height(0), 1);
        assert_eq!(inline_viewport_height(12), 12);
        assert_eq!(inline_viewport_height(24), 24);
        assert_eq!(inline_viewport_height(40), 40);
    }

    #[test]
    fn parses_runtime_flags_and_prompt() {
        let args = ChatArgs::parse(vec![
            "--home".into(),
            "/tmp/home".into(),
            "--workspace".into(),
            "/tmp/work".into(),
            "--yes".into(),
            "hello".into(),
            "world".into(),
        ]);

        assert!(args.yes);
        assert!(args.has_prompt());
        assert_eq!(args.workspace.as_deref(), Some("/tmp/work"));
        assert_eq!(
            args.run_args("hello"),
            vec![
                "run",
                "--home",
                "/tmp/home",
                "--workspace",
                "/tmp/work",
                "--yes",
                "hello"
            ]
        );
    }

    #[test]
    fn tui_run_args_adds_auto_permission_for_non_interactive_backend_capture() {
        let args = ChatArgs::parse(vec!["--workspace".into(), "/tmp/work".into()]);

        assert_eq!(
            args.run_args("inspect"),
            vec![
                "run",
                "--workspace",
                "/tmp/work",
                "--permission-mode",
                "auto",
                "inspect"
            ]
        );
    }

    #[test]
    fn explicit_deny_permission_is_preserved_for_non_interactive_backend_capture() {
        let args = ChatArgs::parse(vec![
            "--workspace".into(),
            "/tmp/work".into(),
            "--permission-mode".into(),
            "deny".into(),
        ]);

        assert_eq!(args.permission_mode_label(), "deny writes");
        assert_eq!(
            args.chat_run_args("inspect", &[]),
            vec![
                "run",
                "--workspace",
                "/tmp/work",
                "--permission-mode",
                "deny",
                "--mode",
                "chat",
                "inspect"
            ]
        );
    }

    #[test]
    fn chat_run_args_use_chat_mode_runner() {
        let args = ChatArgs::parse(vec![
            "--workspace".into(),
            "/tmp/work".into(),
            "--runtime-contract".into(),
            "goal".into(),
        ]);

        assert_eq!(
            args.chat_run_args("hello", &[]),
            vec![
                "run",
                "--workspace",
                "/tmp/work",
                "--permission-mode",
                "auto",
                "--mode",
                "chat",
                "hello"
            ]
        );
    }

    #[test]
    fn interactive_chat_run_args_do_not_force_yes_without_yes_flag() {
        let args = ChatArgs::parse(vec![
            "--workspace".into(),
            "/tmp/work".into(),
            "--runtime-contract".into(),
            "goal".into(),
        ]);

        assert_eq!(
            args.interactive_chat_run_args("hello", &[]),
            vec!["run", "--workspace", "/tmp/work", "--mode", "chat", "hello"]
        );
    }

    #[test]
    fn interactive_chat_run_args_preserve_yes_when_requested() {
        let args = ChatArgs::parse(vec!["--yes".into()]);

        assert_eq!(
            args.interactive_chat_run_args("hello", &[]),
            vec!["run", "--yes", "--mode", "chat", "hello"]
        );
    }

    #[test]
    fn goal_mode_turn_args_use_goal_runtime_contract_without_artifact_mode() {
        let mut args = ChatArgs::parse(vec![
            "--workspace".into(),
            "/tmp/work".into(),
            "--mode".into(),
            "chat".into(),
        ]);
        args.set_interaction_mode(InteractionMode::Goal);

        assert_eq!(
            args.interactive_turn_run_args("set goal", &[]),
            vec![
                "run",
                "--workspace",
                "/tmp/work",
                "--runtime-contract",
                "goal",
                "set goal"
            ]
        );
        assert_eq!(
            args.turn_run_args("set goal", &[]),
            vec![
                "run",
                "--workspace",
                "/tmp/work",
                "--permission-mode",
                "auto",
                "--runtime-contract",
                "goal",
                "set goal"
            ]
        );
    }

    #[test]
    fn build_mode_turn_args_use_chat_contract() {
        let args = ChatArgs::parse(vec!["--workspace".into(), "/tmp/work".into()]);

        assert_eq!(
            args.interactive_turn_run_args("build it", &[]),
            vec![
                "run",
                "--workspace",
                "/tmp/work",
                "--mode",
                "chat",
                "build it"
            ]
        );
    }

    #[test]
    fn permission_mode_toggle_updates_runtime_flags() {
        let mut args = ChatArgs::parse(vec!["--workspace".into(), "/tmp/work".into()]);

        assert_eq!(args.permission_mode_label(), "review writes");
        assert_eq!(
            args.interactive_chat_run_args("hello", &[]),
            vec!["run", "--workspace", "/tmp/work", "--mode", "chat", "hello"]
        );

        args.set_permission_mode(commands::PermissionMode::Auto);
        assert_eq!(args.permission_mode_label(), "auto-approve");
        assert_eq!(
            args.interactive_chat_run_args("hello", &[]),
            vec![
                "run",
                "--workspace",
                "/tmp/work",
                "--permission-mode",
                "auto",
                "--mode",
                "chat",
                "hello"
            ]
        );

        args.set_permission_mode(commands::PermissionMode::Deny);
        assert_eq!(args.permission_mode_label(), "deny writes");
        assert_eq!(
            args.interactive_chat_run_args("hello", &[]),
            vec![
                "run",
                "--workspace",
                "/tmp/work",
                "--permission-mode",
                "deny",
                "--mode",
                "chat",
                "hello"
            ]
        );
    }

    #[test]
    fn interactive_resume_args_do_not_force_yes_without_yes_flag() {
        let args = ChatArgs::parse(vec!["--workspace".into(), "/tmp/work".into()]);

        assert_eq!(
            args.interactive_resume_args("run_1"),
            vec!["resume", "--workspace", "/tmp/work", "run_1"]
        );
    }

    #[test]
    fn interactive_fork_args_do_not_force_yes_without_yes_flag() {
        let args = ChatArgs::parse(vec!["--workspace".into(), "/tmp/work".into()]);

        assert_eq!(
            args.interactive_fork_args("run_1"),
            vec!["fork", "--workspace", "/tmp/work", "run_1"]
        );
        assert_eq!(
            args.fork_args("run_1"),
            vec![
                "fork",
                "--workspace",
                "/tmp/work",
                "--permission-mode",
                "auto",
                "run_1"
            ]
        );
    }

    #[test]
    fn logs_args_accept_optional_run_ref() {
        let args = ChatArgs::parse(vec!["--workspace".into(), "/tmp/work".into()]);

        assert_eq!(
            args.logs_args(None, commands::LogView::Activity),
            vec!["logs", "--workspace", "/tmp/work"]
        );
        assert_eq!(
            args.logs_args(Some("run_1"), commands::LogView::Activity),
            vec!["logs", "--workspace", "/tmp/work", "run_1"]
        );
        assert_eq!(
            args.logs_args(Some("run_1"), commands::LogView::Transcript),
            vec![
                "logs",
                "--workspace",
                "/tmp/work",
                "--view",
                "transcript",
                "run_1"
            ]
        );
    }

    #[test]
    fn diff_args_accept_summary_view() {
        let args = ChatArgs::parse(vec!["--workspace".into(), "/tmp/work".into()]);

        assert_eq!(
            args.diff_args(commands::DiffView::Full),
            vec!["diff", "--workspace", "/tmp/work"]
        );
        assert_eq!(
            args.diff_args(commands::DiffView::Summary),
            vec!["diff", "--workspace", "/tmp/work", "--view", "summary"]
        );
    }

    #[test]
    fn runs_json_args_use_backend_json_contract() {
        let args = ChatArgs::parse(vec!["--workspace".into(), "/tmp/work".into()]);

        assert_eq!(
            args.runs_json_args(),
            vec!["runs", "--workspace", "/tmp/work", "--json"]
        );
    }

    #[test]
    fn run_list_output_parses_canonical_backend_response() {
        let runs = super::run_summaries_from_output(BackendOutput {
            code: 0,
            stdout: r#"{
                "schema_version": "holt_run_list/v1",
                "runs": [
                    {
                        "id": "run_1",
                        "status": "completed",
                        "objective": "inspect workspace",
                        "artifact": "NEXT_STEPS.md",
                        "latest_answer": "Final\nanswer"
                    }
                ]
            }"#
            .to_string(),
            stderr: String::new(),
        })
        .expect("runs");

        assert_eq!(runs.len(), 1);
        assert_eq!(runs[0].id, "run_1");
        assert_eq!(runs[0].status, "completed");
        assert_eq!(runs[0].objective, "inspect workspace");
        assert_eq!(runs[0].artifact.as_deref(), Some("NEXT_STEPS.md"));
        assert_eq!(runs[0].answer_preview.as_deref(), Some("Final answer"));
    }

    #[test]
    fn chat_run_args_include_prior_chat_messages() {
        let args = ChatArgs::parse(vec!["--yes".into()]);
        let messages = vec![
            ChatMessage::user("ask me a real question and give me options"),
            ChatMessage::assistant("1. Code structure and organization"),
        ];

        assert_eq!(
            args.chat_run_args("1", &messages),
            vec![
                "run",
                "--yes",
                "--mode",
                "chat",
                "--chat-messages",
                r#"[{"role":"user","content":"ask me a real question and give me options"},{"role":"assistant","content":"1. Code structure and organization"}]"#,
                "1"
            ]
        );
    }

    #[test]
    fn one_shot_chat_prompt_uses_chat_mode_runner() {
        let args = ChatArgs::parse(vec!["--yes".into(), "hello".into()]);

        assert_eq!(
            args.one_shot_chat_run_args(),
            Some(vec![
                "run".to_string(),
                "--yes".to_string(),
                "--mode".to_string(),
                "chat".to_string(),
                "hello".to_string()
            ])
        );
    }

    #[test]
    fn slash_suggestions_match_command_prefix() {
        let suggestions = super::slash_suggestions("/he", 0);

        assert!(suggestions.iter().any(|item| item.usage == "/help"));
        assert!(!suggestions.iter().any(|item| item.usage == "/status"));
        assert!(suggestions
            .iter()
            .any(|item| item.usage == "/help" && item.selected));

        let goal_suggestions = super::slash_suggestions("/go", 0);
        assert!(goal_suggestions
            .iter()
            .any(|item| item.usage == "/goal [task]"));
    }

    #[test]
    fn slash_suggestions_are_keyboard_selectable() {
        let mut state = State::new(ChatArgs::parse(vec![]));
        set_input(&mut state, "/".to_string());

        assert!(!handle_key(
            &mut state,
            KeyEvent::new(KeyCode::Down, KeyModifiers::NONE)
        ));
        assert_eq!(state.slash_selection, 1);

        let composer = Composer::new(&state, 96, 24);
        assert!(composer
            .suggestions
            .iter()
            .any(|item| item.usage == "/keymap" && item.selected));

        assert!(!handle_key(
            &mut state,
            KeyEvent::new(KeyCode::Tab, KeyModifiers::NONE)
        ));
        assert_eq!(state.input, "/keymap");
    }

    #[test]
    fn composer_footer_shows_build_goal_mode_toggle() {
        let mut state = State::new(ChatArgs::parse(vec![]));

        assert!(composer_footer(&state).contains("build mode"));
        assert!(composer_footer(&state).contains("Tab mode"));

        state.session.set_interaction_mode(InteractionMode::Goal);

        assert!(composer_footer(&state).contains("goal mode"));
    }

    #[test]
    fn composer_mode_exposes_structured_bottom_pane_state() {
        let mut state = State::new(ChatArgs::parse(vec![]));

        match composer_mode(&state) {
            ComposerMode::Message {
                interaction_mode,
                permission_mode,
                navigation,
            } => {
                assert_eq!(interaction_mode, "build");
                assert_eq!(permission_mode, "review writes");
                assert_eq!(navigation.toggle, "Ctrl+O");
            }
            other => panic!("unexpected composer mode: {other:?}"),
        }

        state.approval_prompt = Some(ApprovalPrompt {
            action: "write".to_string(),
        });

        assert!(matches!(
            composer_mode(&state),
            ComposerMode::Approval { action, pending: None } if action == "write"
        ));
        assert_eq!(composer_title(&state), "approval");
        assert!(composer_footer(&state).contains("Approval required for write"));
    }

    #[test]
    fn pending_composer_title_animates_loading_state() {
        let mut state = State::new(ChatArgs::parse(vec![]));
        let (_pending_tx, pending_rx) = mpsc::channel::<PendingMessage>();

        state.pending = Some(Pending {
            label: "Reading workspace".to_string(),
            started: Instant::now(),
            rx: pending_rx,
            input: None,
            record_chat_response: false,
        });
        state.frame = 0;
        let first = composer_title(&state);

        state.frame = 1;
        let second = composer_title(&state);

        assert!(first.contains("Reading workspace"));
        assert!(second.contains("Reading workspace"));
        assert_ne!(first, second);
    }

    #[test]
    fn composer_input_route_owns_selector_keys_before_message_editing() {
        let mut state = State::new(ChatArgs::parse(vec![]));
        set_input(&mut state, "draft".to_string());
        state.input_cursor = 5;
        state.approval_prompt = Some(ApprovalPrompt {
            action: "write".to_string(),
        });

        assert_eq!(composer_input_route(&state), ComposerInputRoute::Approval);
        assert!(!handle_key(
            &mut state,
            KeyEvent::new(KeyCode::Char('a'), KeyModifiers::CONTROL)
        ));
        assert_eq!(state.input_cursor, 5);
    }

    #[test]
    fn run_picker_route_ignores_plain_typing() {
        let mut state = State::new(ChatArgs::parse(vec![]));
        open_run_picker(
            &mut state,
            vec![RunSummary {
                id: "run_1".to_string(),
                status: "completed".to_string(),
                objective: "inspect workspace".to_string(),
                artifact: None,
                answer_preview: None,
            }],
        );

        assert_eq!(composer_input_route(&state), ComposerInputRoute::RunPicker);
        assert!(!handle_key(
            &mut state,
            KeyEvent::new(KeyCode::Char('x'), KeyModifiers::NONE)
        ));
        assert_eq!(state.input, "");
        assert!(state.run_picker.is_some());
    }

    #[test]
    fn tab_on_empty_composer_toggles_interaction_mode() {
        let mut state = State::new(ChatArgs::parse(vec![]));

        assert_eq!(state.session.interaction_mode_label(), "build");
        assert!(!handle_key(
            &mut state,
            KeyEvent::new(KeyCode::Tab, KeyModifiers::NONE)
        ));
        assert_eq!(state.session.interaction_mode_label(), "goal");
        assert!(state
            .cells
            .last()
            .expect("mode cell")
            .markdown_source()
            .contains("Mode: goal"));
    }

    #[test]
    fn keymap_command_renders_shortcut_reference() {
        let mut state = State::new(ChatArgs::parse(vec![]));

        show_keymap(&mut state);

        assert_eq!(state.cells.len(), 2);
        let content = state.cells[1].markdown_source();
        assert!(content.contains("Up / Down"));
        assert!(content.contains("cycle project prompt history"));
        assert!(content.contains("Ctrl+R"));
        assert!(content.contains("search project prompt history"));
        assert!(content.contains("Ctrl+O"));
        assert!(content.contains("collapse or expand"));
        assert!(content.contains("Y / N"));
        assert!(content.contains("tui approval"));
        assert!(content.contains("approve or deny"));
    }

    #[test]
    fn configured_keymap_overrides_transcript_shortcuts_and_keymap_output() {
        let workspace = temp_workspace();
        write_keymap_config(
            &workspace,
            r#"{
                "schema_version": "holt_cli_keymap/v1",
                "bindings": {
                    "transcript.previous_block": "Ctrl+B",
                    "transcript.next_block": "Ctrl+F",
                    "transcript.previous_diff": "Ctrl+P",
                    "transcript.next_diff": "Ctrl+N",
                    "transcript.toggle_block": "Ctrl+G",
                    "transcript.open_pager": "Ctrl+V"
                }
            }"#,
        );
        let mut state = State::new(ChatArgs::parse(vec![
            "--workspace".to_string(),
            workspace.display().to_string(),
        ]));
        state.add_cell(Role::Assistant, transcript_with_two_diffs_and_tail());

        assert!(composer_footer(&state).contains("Ctrl+B / Ctrl+F blocks"));
        assert!(composer_footer(&state).contains("Ctrl+P / Ctrl+N diffs"));
        assert!(composer_footer(&state).contains("Ctrl+G fold"));
        assert!(composer_footer(&state).contains("Ctrl+V pager"));

        assert!(!handle_key(
            &mut state,
            KeyEvent::new(KeyCode::Char('p'), KeyModifiers::CONTROL)
        ));
        assert!(state.scroll > 0);
        assert!(state.transcript_focus_cell.is_some());

        assert!(!handle_key(
            &mut state,
            KeyEvent::new(KeyCode::Char('v'), KeyModifiers::CONTROL)
        ));
        assert!(state.pager.is_some());
        assert!(!handle_key(
            &mut state,
            KeyEvent::new(KeyCode::Esc, KeyModifiers::NONE)
        ));
        assert!(state.pager.is_none());

        assert!(!handle_key(
            &mut state,
            KeyEvent::new(KeyCode::Char('{'), KeyModifiers::SHIFT)
        ));
        assert_eq!(state.input, "{");

        show_keymap(&mut state);
        let content = state.cells.last().expect("keymap cell").markdown_source();
        assert!(content.contains("Ctrl+B"));
        assert!(content.contains("Ctrl+F"));
        assert!(content.contains("Ctrl+P"));
        assert!(content.contains("Ctrl+N"));
        assert!(content.contains("Ctrl+G"));
        assert!(content.contains("Ctrl+V"));

        let _ = fs::remove_dir_all(workspace);
    }

    #[test]
    fn invalid_keymap_config_reports_explicit_error_and_uses_defaults() {
        let workspace = temp_workspace();
        write_keymap_config(
            &workspace,
            r#"{
                "schema_version": "holt_cli_keymap/v1",
                "bindings": {
                    "transcript.previous_diff": "Alt+P"
                }
            }"#,
        );
        let state = State::new(ChatArgs::parse(vec![
            "--workspace".to_string(),
            workspace.display().to_string(),
        ]));

        let error = state
            .cells
            .iter()
            .find(|cell| matches!(cell.role, Role::Error))
            .expect("keymap error");
        assert!(error.markdown_source().contains("Keymap config error"));
        assert!(error
            .markdown_source()
            .contains("unsupported key Alt+P for transcript.previous_diff"));
        assert!(composer_footer(&state).contains("[ / ] blocks"));
        assert!(composer_footer(&state).contains("{ / } diffs"));
        assert!(composer_footer(&state).contains("Ctrl+O fold"));
        assert!(composer_footer(&state).contains("v pager"));

        let _ = fs::remove_dir_all(workspace);
    }

    #[test]
    fn permissions_command_updates_session_policy_cell_and_footer() {
        let mut state = State::new(ChatArgs::parse(vec![]));

        show_or_set_permissions(&mut state, Some(commands::PermissionMode::Auto));
        assert!(state.session.yes);
        assert!(state
            .cells
            .last()
            .expect("permissions cell")
            .markdown_source()
            .contains("Permissions: auto-approve"));
        assert!(composer_footer(&state).contains("auto-approve"));

        show_or_set_permissions(&mut state, Some(commands::PermissionMode::Deny));
        assert!(!state.session.yes);
        assert!(state
            .cells
            .last()
            .expect("permissions cell")
            .markdown_source()
            .contains("Permissions: deny writes"));
        assert!(composer_footer(&state).contains("deny writes"));
    }

    #[test]
    fn tab_accepts_selected_slash_command_suggestion() {
        let mut state = State::new(ChatArgs::parse(vec![]));
        set_input(&mut state, "/he".to_string());

        assert!(!handle_key(
            &mut state,
            KeyEvent::new(KeyCode::Tab, KeyModifiers::NONE)
        ));

        assert_eq!(state.input, "/help");
        assert_eq!(state.input_cursor, 5);

        set_input(&mut state, "/r".to_string());
        assert!(!handle_key(
            &mut state,
            KeyEvent::new(KeyCode::Tab, KeyModifiers::NONE)
        ));
        assert_eq!(state.input, "/runs");
        assert_eq!(state.input_cursor, 5);
    }

    #[test]
    fn tui_input_edits_at_cursor() {
        let mut state = State::new(ChatArgs::parse(vec![]));

        for ch in ['h', 'e', 'l', 'o'] {
            assert!(!handle_key(
                &mut state,
                KeyEvent::new(KeyCode::Char(ch), KeyModifiers::NONE)
            ));
        }

        assert_eq!(state.input, "helo");
        assert_eq!(state.input_cursor, 4);

        assert!(!handle_key(
            &mut state,
            KeyEvent::new(KeyCode::Left, KeyModifiers::NONE)
        ));
        assert_eq!(state.input_cursor, 3);

        assert!(!handle_key(
            &mut state,
            KeyEvent::new(KeyCode::Char('l'), KeyModifiers::NONE)
        ));
        assert_eq!(state.input, "hello");
        assert_eq!(state.input_cursor, 4);

        assert!(!handle_key(
            &mut state,
            KeyEvent::new(KeyCode::Backspace, KeyModifiers::NONE)
        ));
        assert_eq!(state.input, "helo");
        assert_eq!(state.input_cursor, 3);

        assert!(!handle_key(
            &mut state,
            KeyEvent::new(KeyCode::Delete, KeyModifiers::NONE)
        ));
        assert_eq!(state.input, "hel");
        assert_eq!(state.input_cursor, 3);

        assert!(!handle_key(
            &mut state,
            KeyEvent::new(KeyCode::Home, KeyModifiers::NONE)
        ));
        assert_eq!(state.input_cursor, 0);

        assert!(!handle_key(
            &mut state,
            KeyEvent::new(KeyCode::End, KeyModifiers::NONE)
        ));
        assert_eq!(state.input_cursor, 3);
    }

    #[test]
    fn tui_ctrl_d_exits_only_when_input_is_empty() {
        let mut state = State::new(ChatArgs::parse(vec![]));

        set_input(&mut state, "draft".to_string());
        assert!(!handle_key(
            &mut state,
            KeyEvent::new(KeyCode::Char('d'), KeyModifiers::CONTROL)
        ));
        assert_eq!(state.input, "draft");

        set_input(&mut state, String::new());
        assert!(handle_key(
            &mut state,
            KeyEvent::new(KeyCode::Char('d'), KeyModifiers::CONTROL)
        ));
    }

    #[test]
    fn tui_input_supports_readline_shortcuts() {
        let mut state = State::new(ChatArgs::parse(vec![]));
        set_input(&mut state, "hello world again".to_string());
        state.input_cursor = 11;

        assert!(!handle_key(
            &mut state,
            KeyEvent::new(KeyCode::Char('a'), KeyModifiers::CONTROL)
        ));
        assert_eq!(state.input_cursor, 0);

        assert!(!handle_key(
            &mut state,
            KeyEvent::new(KeyCode::Char('e'), KeyModifiers::CONTROL)
        ));
        assert_eq!(state.input_cursor, 17);

        assert!(!handle_key(
            &mut state,
            KeyEvent::new(KeyCode::Char('w'), KeyModifiers::CONTROL)
        ));
        assert_eq!(state.input, "hello world ");
        assert_eq!(state.input_cursor, 12);

        assert!(!handle_key(
            &mut state,
            KeyEvent::new(KeyCode::Char('u'), KeyModifiers::CONTROL)
        ));
        assert_eq!(state.input, "");
        assert_eq!(state.input_cursor, 0);

        set_input(&mut state, "hello world again".to_string());
        state.input_cursor = 5;
        assert!(!handle_key(
            &mut state,
            KeyEvent::new(KeyCode::Char('k'), KeyModifiers::CONTROL)
        ));
        assert_eq!(state.input, "hello");
        assert_eq!(state.input_cursor, 5);
    }

    #[test]
    fn tui_ctrl_r_searches_history_with_current_input() {
        let mut state = State::new(ChatArgs::parse(vec![]));
        state.history = vec![
            "edit docs".to_string(),
            "run tests".to_string(),
            "show diff".to_string(),
            "edit diff renderer".to_string(),
        ];
        set_input(&mut state, "diff".to_string());

        assert!(!handle_key(
            &mut state,
            KeyEvent::new(KeyCode::Char('r'), KeyModifiers::CONTROL)
        ));
        assert_eq!(state.input, "edit diff renderer");
        assert_eq!(state.input_cursor, 18);

        assert!(!handle_key(
            &mut state,
            KeyEvent::new(KeyCode::Char('r'), KeyModifiers::CONTROL)
        ));
        assert_eq!(state.input, "show diff");
        assert_eq!(state.input_cursor, 9);

        assert!(!handle_key(
            &mut state,
            KeyEvent::new(KeyCode::Char('!'), KeyModifiers::NONE)
        ));
        assert_eq!(state.history_search, None);
    }

    #[test]
    fn tui_ctrl_r_reports_no_matching_history_in_footer() {
        let mut state = State::new(ChatArgs::parse(vec![]));
        state.history = vec!["edit docs".to_string(), "run tests".to_string()];
        set_input(&mut state, "diff".to_string());

        assert!(!handle_key(
            &mut state,
            KeyEvent::new(KeyCode::Char('r'), KeyModifiers::CONTROL)
        ));

        assert_eq!(state.input, "diff");
        assert_eq!(composer_title(&state), "history");
        assert!(composer_footer(&state).contains("no match for diff"));
    }

    #[test]
    fn tui_history_restores_draft_after_down_past_latest_entry() {
        let mut state = State::new(ChatArgs::parse(vec![]));
        state.history = vec!["first prompt".to_string(), "second prompt".to_string()];
        set_input(&mut state, "draft prompt".to_string());

        assert!(!handle_key(
            &mut state,
            KeyEvent::new(KeyCode::Up, KeyModifiers::NONE)
        ));
        assert_eq!(state.input, "second prompt");
        assert_eq!(state.input_cursor, 13);

        assert!(!handle_key(
            &mut state,
            KeyEvent::new(KeyCode::Up, KeyModifiers::NONE)
        ));
        assert_eq!(state.input, "first prompt");

        assert!(!handle_key(
            &mut state,
            KeyEvent::new(KeyCode::Down, KeyModifiers::NONE)
        ));
        assert_eq!(state.input, "second prompt");

        assert!(!handle_key(
            &mut state,
            KeyEvent::new(KeyCode::Down, KeyModifiers::NONE)
        ));
        assert_eq!(state.input, "draft prompt");
        assert_eq!(state.input_cursor, 12);
        assert_eq!(state.history_cursor, None);
    }

    #[test]
    fn tui_history_up_wraps_from_oldest_to_latest_prompt() {
        let mut state = State::new(ChatArgs::parse(vec![]));
        state.history = vec![
            "first prompt".to_string(),
            "second prompt".to_string(),
            "third prompt".to_string(),
        ];

        assert!(!handle_key(
            &mut state,
            KeyEvent::new(KeyCode::Up, KeyModifiers::NONE)
        ));
        assert_eq!(state.input, "third prompt");

        assert!(!handle_key(
            &mut state,
            KeyEvent::new(KeyCode::Up, KeyModifiers::NONE)
        ));
        assert_eq!(state.input, "second prompt");

        assert!(!handle_key(
            &mut state,
            KeyEvent::new(KeyCode::Up, KeyModifiers::NONE)
        ));
        assert_eq!(state.input, "first prompt");

        assert!(!handle_key(
            &mut state,
            KeyEvent::new(KeyCode::Up, KeyModifiers::NONE)
        ));
        assert_eq!(state.input, "third prompt");
    }

    #[test]
    fn tui_history_navigation_reports_structured_outcomes() {
        let mut state = State::new(ChatArgs::parse(vec![]));
        state.history = vec!["first prompt".to_string(), "second prompt".to_string()];
        set_input(&mut state, "draft".to_string());

        assert_eq!(
            navigate_history(&mut state, HistoryNavigationDirection::Older),
            HistoryNavigationOutcome::Recalled {
                index: 1,
                prompt: "second prompt".to_string(),
            }
        );
        assert_eq!(state.input, "second prompt");

        assert_eq!(
            navigate_history(&mut state, HistoryNavigationDirection::Newer),
            HistoryNavigationOutcome::RestoredDraft {
                draft: "draft".to_string(),
            }
        );
        assert_eq!(state.input, "draft");

        assert_eq!(
            navigate_history(&mut state, HistoryNavigationDirection::Newer),
            HistoryNavigationOutcome::NotBrowsing
        );
    }

    #[test]
    fn tui_history_navigation_resets_after_editing_recalled_prompt() {
        let mut state = State::new(ChatArgs::parse(vec![]));
        state.history = vec!["old prompt".to_string()];
        set_input(&mut state, "draft".to_string());

        assert!(!handle_key(
            &mut state,
            KeyEvent::new(KeyCode::Up, KeyModifiers::NONE)
        ));
        assert_eq!(state.input, "old prompt");

        assert!(!handle_key(
            &mut state,
            KeyEvent::new(KeyCode::Char('!'), KeyModifiers::NONE)
        ));
        assert_eq!(state.input, "old prompt!");
        assert_eq!(state.history_cursor, None);

        assert!(!handle_key(
            &mut state,
            KeyEvent::new(KeyCode::Down, KeyModifiers::NONE)
        ));
        assert_eq!(state.input, "old prompt!");
    }

    #[test]
    fn composer_cursor_tracks_input_cursor() {
        let mut state = State::new(ChatArgs::parse(vec![]));
        set_input(&mut state, "hello".to_string());
        state.input_cursor = 2;

        let composer = Composer::new(&state, 80, 24);

        assert_eq!(composer.cursor_x, 6);
        assert_eq!(composer.cursor_y, 24 - composer.height + 1);
    }

    #[test]
    fn ratatui_render_line_preserves_diff_span_styles() {
        let rendered = ratatui_render_line(
            &RenderLine::styled(vec![
                RenderSpan::new("++", Tone::DiffAdd),
                RenderSpan::new("--", Tone::DiffDelete),
            ]),
            3,
        );

        assert_eq!(rendered.spans.len(), 2);
        assert_eq!(rendered.spans[0].content.as_ref(), "++");
        assert_eq!(rendered.spans[0].style.fg, Some(RatColor::Green));
        assert_eq!(rendered.spans[1].content.as_ref(), "…");
        assert_eq!(rendered.spans[1].style.fg, Some(RatColor::Red));
    }

    #[test]
    fn ratatui_frame_renders_header_transcript_and_composer() {
        let backend = TestBackend::new(80, 24);
        let mut terminal = TestTerminal::new(backend).expect("terminal");
        let mut state = State::new(ChatArgs::parse(vec![]));
        state.add_cell(
            Role::Assistant,
            r#"Edited rust/crates/holt-cli/src/ui.rs (+5 -3)

```diff
diff --git a/rust/crates/holt-cli/src/ui.rs b/rust/crates/holt-cli/src/ui.rs
@@ -1,2 +1,2 @@
-old value
+new value
```
"#,
        );

        terminal
            .draw(|frame| {
                let area = frame.area();
                let view = frame_view(&state, area.width, area.height);
                tui_frame::draw_frame(frame, &view);
            })
            .expect("draw frame");

        let text = buffer_text(terminal.backend().buffer());
        assert!(text.contains("Holt"));
        assert!(text.contains("Edited rust/crates/holt-cli/src/ui.rs (+5 -3)"));
        assert!(text.contains("new value"));
        assert!(text.contains("old value"));
        assert!(text.contains("message"));
    }

    #[test]
    fn ratatui_frame_renders_selected_slash_suggestion() {
        let backend = TestBackend::new(96, 24);
        let mut terminal = TestTerminal::new(backend).expect("terminal");
        let mut state = State::new(ChatArgs::parse(vec![]));
        set_input(&mut state, "/".to_string());
        assert!(!handle_key(
            &mut state,
            KeyEvent::new(KeyCode::Down, KeyModifiers::NONE)
        ));

        terminal
            .draw(|frame| {
                let area = frame.area();
                let view = frame_view(&state, area.width, area.height);
                tui_frame::draw_frame(frame, &view);
            })
            .expect("draw frame");

        let text = buffer_text(terminal.backend().buffer());
        assert!(text.contains("▶ /keymap"));
        assert!(text.contains("show keyboard shortcuts"));
    }

    #[test]
    fn ratatui_frame_renders_pending_loading_animation() {
        let backend = TestBackend::new(96, 24);
        let mut terminal = TestTerminal::new(backend).expect("terminal");
        let mut state = State::new(ChatArgs::parse(vec![]));
        let (_pending_tx, pending_rx) = mpsc::channel::<PendingMessage>();

        state.pending = Some(Pending {
            label: "Reading workspace".to_string(),
            started: Instant::now(),
            rx: pending_rx,
            input: None,
            record_chat_response: false,
        });
        state.frame = 2;

        terminal
            .draw(|frame| {
                let area = frame.area();
                let view = frame_view(&state, area.width, area.height);
                tui_frame::draw_frame(frame, &view);
            })
            .expect("draw frame");

        let text = buffer_text(terminal.backend().buffer());
        assert!(text.contains("Reading workspace"));
        assert!(text.contains("Ctrl-C interrupt"));
    }

    #[test]
    fn file_edit_render_action_uses_typed_transcript_cell() {
        let mut state = State::new(ChatArgs::parse(vec![]));

        apply_render_action(
            &mut state,
            RenderAction::FileEdit {
                summary: FileEditSummary {
                    path: "rust/crates/holt-cli/src/ui.rs".to_string(),
                    additions: Some(5),
                    deletions: Some(3),
                    unified_diff: Some(
                        "--- a/rust/crates/holt-cli/src/ui.rs\n+++ b/rust/crates/holt-cli/src/ui.rs\n@@ -1,1 +1,1 @@\n-old\n+new"
                            .to_string(),
                    ),
                    diff_redacted: false,
                    status: FileEditStatus::Edited,
                },
            },
        );

        let cell = state.cells.last().expect("file edit cell");
        assert!(matches!(cell.body, CellBody::FileEdit { .. }));
        assert_eq!(cell.role, Role::System);
        assert!(cell
            .markdown_source()
            .contains("• Edited rust/crates/holt-cli/src/ui.rs (+5 -3)"));
        let lines = transcript_lines(&state, 100);
        let summary_line = lines
            .iter()
            .find(|line| line.text.contains("Edited rust/crates/holt-cli/src/ui.rs"))
            .expect("file edit summary line");
        assert!(summary_line
            .spans
            .iter()
            .any(|span| span.text == "Edited" && span.modifier.contains(Modifier::BOLD)));
        assert!(summary_line
            .spans
            .iter()
            .any(|span| span.text == "+5" && span.tone == Tone::DiffAdd));
        assert!(summary_line
            .spans
            .iter()
            .any(|span| span.text == "-3" && span.tone == Tone::DiffDelete));
        assert!(lines.iter().any(|line| line.text.contains("new")));
    }

    fn buffer_text(buffer: &Buffer) -> String {
        let mut output = String::new();
        for y in 0..buffer.area.height {
            for x in 0..buffer.area.width {
                if let Some(cell) = buffer.cell(BufferPosition::new(x, y)) {
                    output.push_str(cell.symbol());
                }
            }
            output.push('\n');
        }
        output
    }

    fn rat_lines_text(lines: &[ratatui::text::Line<'static>]) -> String {
        let mut output = String::new();
        for line in lines {
            for span in &line.spans {
                output.push_str(span.content.as_ref());
            }
            output.push('\n');
        }
        output
    }

    #[test]
    fn successful_chat_turn_records_assistant_message_for_followups() {
        let mut state = State::new(ChatArgs::parse(vec!["--yes".into()]));

        apply_render_action(
            &mut state,
            RenderAction::Answer {
                content: "1. Code structure and organization".to_string(),
            },
        );
        finish_pending(
            &mut state,
            PendingMessage::Finished(
                Ok(BackendOutput {
                    code: 0,
                    stdout: String::new(),
                    stderr: String::new(),
                }),
                true,
            ),
        );

        assert_eq!(
            state.chat_messages,
            vec![ChatMessage::assistant("1. Code structure and organization")]
        );
    }

    #[test]
    fn tui_state_loads_workspace_prompt_history() {
        let workspace = temp_workspace();
        history::append_prompt(&workspace, "persisted tui prompt").unwrap();

        let state = State::with_persistent_history(ChatArgs::parse(vec![
            "--workspace".to_string(),
            workspace.display().to_string(),
        ]));

        assert_eq!(state.history, vec!["persisted tui prompt".to_string()]);

        let _ = fs::remove_dir_all(workspace);
    }

    #[test]
    fn tui_transcript_shortens_local_file_links_to_workspace() {
        let workspace = temp_workspace();
        let linked_file = workspace.join("src/ui.rs");
        let mut state = State::new(ChatArgs::parse(vec![
            "--workspace".to_string(),
            workspace.display().to_string(),
        ]));
        state.add_cell(
            Role::Assistant,
            format!("See [renderer]({}:12).", linked_file.display()),
        );

        let lines = transcript_lines(&state, 120)
            .into_iter()
            .map(|line| line.text)
            .collect::<Vec<_>>();

        assert!(lines.iter().any(|line| line == "│ See src/ui.rs:12."));
        assert!(!lines
            .iter()
            .any(|line| line.contains("See ") && line.contains(&workspace.display().to_string())));

        let _ = fs::remove_dir_all(workspace);
    }

    #[test]
    fn tui_transcript_anchor_indices_include_cells_and_diff_blocks() {
        let mut state = State::new(ChatArgs::parse(vec![]));
        state.add_cell(
            Role::Assistant,
            r#"Edited src/main.rs

```diff
diff --git a/src/main.rs b/src/main.rs
@@ -1,1 +1,1 @@
-old
+new
```
"#,
        );

        let lines = transcript_lines(&state, 100);
        let block_anchors = transcript_anchor_indices(&lines, TranscriptAnchorKind::Block);
        let diff_anchors = transcript_anchor_indices(&lines, TranscriptAnchorKind::Diff);

        assert_eq!(block_anchors.len(), 2);
        assert_eq!(diff_anchors.len(), 1);
        assert!(lines[diff_anchors[0]].text.starts_with("│ ╭─ diff"));
    }

    #[test]
    fn tui_transcript_jump_moves_between_diff_blocks() {
        let mut state = State::new(ChatArgs::parse(vec![]));
        state.add_cell(Role::Assistant, transcript_with_two_diffs_and_tail());
        let width = 100;
        let height = 18;

        let lines = transcript_lines(&state, width as usize);
        let diff_anchors = transcript_anchor_indices(&lines, TranscriptAnchorKind::Diff);
        assert_eq!(diff_anchors.len(), 2);

        jump_transcript_anchor_with_view(
            &mut state,
            TranscriptAnchorKind::Diff,
            TranscriptJumpDirection::Previous,
            width,
            height,
        );

        let body_height =
            transcript_body_height(height, Composer::new(&state, width, height).height);
        assert_eq!(
            visible_window_start(lines.len(), state.scroll, body_height),
            diff_anchors[1]
        );

        jump_transcript_anchor_with_view(
            &mut state,
            TranscriptAnchorKind::Diff,
            TranscriptJumpDirection::Previous,
            width,
            height,
        );

        assert_eq!(
            visible_window_start(lines.len(), state.scroll, body_height),
            diff_anchors[0]
        );

        jump_transcript_anchor_with_view(
            &mut state,
            TranscriptAnchorKind::Diff,
            TranscriptJumpDirection::Next,
            width,
            height,
        );

        assert_eq!(
            visible_window_start(lines.len(), state.scroll, body_height),
            diff_anchors[1]
        );
    }

    #[test]
    fn resize_preserves_focused_transcript_cell_anchor() {
        let mut state = State::new(ChatArgs::parse(vec![]));
        state.add_cell(Role::Assistant, transcript_with_two_diffs_and_tail());
        let old_width = 100;
        let old_height = 18;

        jump_transcript_anchor_with_view(
            &mut state,
            TranscriptAnchorKind::Diff,
            TranscriptJumpDirection::Previous,
            old_width,
            old_height,
        );

        let focused = state.transcript_focus_cell.expect("focused cell");
        let new_width = 72;
        let new_height = 22;
        preserve_resize_scroll(&mut state, new_width, new_height);

        let lines = transcript_lines(&state, new_width as usize);
        let block_anchors = transcript_anchor_indices(&lines, TranscriptAnchorKind::Block);
        let body_height = transcript_body_height(
            new_height,
            Composer::new(&state, new_width, new_height).height,
        );
        assert_eq!(state.transcript_focus_cell, Some(focused));
        assert_eq!(
            state.scroll,
            scroll_for_anchor(lines.len(), block_anchors[focused], body_height)
        );
    }

    #[test]
    fn resize_keeps_bottom_scroll_at_bottom() {
        let mut state = State::new(ChatArgs::parse(vec![]));
        state.add_cell(Role::Assistant, transcript_with_two_diffs_and_tail());

        preserve_resize_scroll(&mut state, 72, 20);

        assert_eq!(state.scroll, 0);
        assert_eq!(state.transcript_focus_cell, None);
    }

    #[test]
    fn tui_transcript_jump_keys_do_not_steal_typed_brackets() {
        let mut state = State::new(ChatArgs::parse(vec![]));
        set_input(&mut state, "draft".to_string());

        assert!(!handle_key(
            &mut state,
            KeyEvent::new(KeyCode::Char(']'), KeyModifiers::NONE)
        ));

        assert_eq!(state.input, "draft]");
    }

    #[test]
    fn tui_ctrl_o_collapses_and_expands_current_transcript_block() {
        let mut state = State::new(ChatArgs::parse(vec![]));
        state.add_cell(Role::Assistant, transcript_with_two_diffs_and_tail());

        assert!(!handle_key(
            &mut state,
            KeyEvent::new(KeyCode::Char('o'), KeyModifiers::CONTROL)
        ));

        assert!(state.cells[1].collapsed);
        let collapsed_lines = transcript_lines(&state, 100)
            .into_iter()
            .map(|line| line.text)
            .collect::<Vec<_>>();
        assert!(collapsed_lines
            .iter()
            .any(|line| line.contains("collapsed ·")));
        assert!(!collapsed_lines
            .iter()
            .any(|line| line.contains("tail line 39")));

        assert!(!handle_key(
            &mut state,
            KeyEvent::new(KeyCode::Char('o'), KeyModifiers::CONTROL)
        ));

        assert!(!state.cells[1].collapsed);
        let expanded_lines = transcript_lines(&state, 100)
            .into_iter()
            .map(|line| line.text)
            .collect::<Vec<_>>();
        assert!(expanded_lines
            .iter()
            .any(|line| line.contains("tail line 39")));
    }

    #[test]
    fn tui_ctrl_o_requires_empty_composer() {
        let mut state = State::new(ChatArgs::parse(vec![]));
        state.add_cell(Role::Assistant, transcript_with_two_diffs_and_tail());
        set_input(&mut state, "draft".to_string());

        assert!(!handle_key(
            &mut state,
            KeyEvent::new(KeyCode::Char('o'), KeyModifiers::CONTROL)
        ));

        assert_eq!(state.input, "draft");
        assert!(!state.cells[1].collapsed);
    }

    #[test]
    fn tui_v_opens_current_transcript_block_in_pager() {
        let mut state = State::new(ChatArgs::parse(vec![]));
        state.add_cell(Role::Assistant, transcript_with_two_diffs_and_tail());
        state.transcript_focus_cell = Some(1);
        state.cells[1].collapsed = true;

        assert!(!handle_key(
            &mut state,
            KeyEvent::new(KeyCode::Char('v'), KeyModifiers::NONE)
        ));

        let pager = state.pager.as_ref().expect("pager");
        assert_eq!(pager.cell, 1);
        assert_eq!(state.transcript_focus_cell, Some(1));

        let view = frame_view(&state, 100, 24);
        let pager_view = view.pager.expect("pager view");
        let rendered = rat_lines_text(&pager_view.lines);
        assert!(rendered.contains("tail line 39"));
        assert!(!rendered.contains("collapsed ·"));
    }

    #[test]
    fn pager_overlay_consumes_text_and_esc_closes() {
        let mut state = State::new(ChatArgs::parse(vec![]));
        state.add_cell(Role::Assistant, transcript_with_two_diffs_and_tail());
        open_current_transcript_block_pager_with_view(&mut state, 100, 24);
        assert!(state.pager.is_some());

        assert!(!handle_key(
            &mut state,
            KeyEvent::new(KeyCode::Char('x'), KeyModifiers::NONE)
        ));
        assert_eq!(state.input, "");
        assert!(state.pager.is_some());

        assert!(!handle_key(
            &mut state,
            KeyEvent::new(KeyCode::PageDown, KeyModifiers::NONE)
        ));
        assert!(state.pager.as_ref().expect("pager").scroll > 0);

        assert!(!handle_key(
            &mut state,
            KeyEvent::new(KeyCode::Esc, KeyModifiers::NONE)
        ));
        assert!(state.pager.is_none());
    }

    #[test]
    fn ratatui_frame_renders_pager_overlay() {
        let backend = TestBackend::new(100, 28);
        let mut terminal = TestTerminal::new(backend).expect("terminal");
        let mut state = State::new(ChatArgs::parse(vec![]));
        state.add_cell(Role::Assistant, transcript_with_two_diffs_and_tail());
        state.transcript_focus_cell = Some(1);
        open_current_transcript_block_pager_with_view(&mut state, 100, 28);
        state.pager.as_mut().expect("pager").scroll = 80;

        terminal
            .draw(|frame| {
                let area = frame.area();
                let view = frame_view(&state, area.width, area.height);
                tui_frame::draw_frame(frame, &view);
            })
            .expect("draw frame");

        let text = buffer_text(terminal.backend().buffer());
        assert!(text.contains("pager"));
        assert!(text.contains("tail line 39"));
        assert!(text.contains("Esc/q close"));
    }

    #[test]
    fn tui_transcript_caches_cell_rendering_and_invalidates_on_streaming_delta() {
        let mut state = State::new(ChatArgs::parse(vec![]));

        state.add_answer_delta("first line");
        let _ = transcript_lines(&state, 80);
        assert!(state.cells[1].render_cache.borrow().is_some());

        state.add_answer_delta("\nsecond line");
        assert!(state.cells[1].render_cache.borrow().is_none());

        let rendered = transcript_lines(&state, 80)
            .into_iter()
            .map(|line| line.text)
            .collect::<Vec<_>>();

        assert!(state.cells[1].render_cache.borrow().is_some());
        assert!(rendered.iter().any(|line| line.contains("second line")));
    }

    #[test]
    fn tui_transcript_visible_lines_match_full_window_without_cloning_all_lines() {
        let mut state = State::new(ChatArgs::parse(vec![]));
        state.add_cell(Role::Assistant, transcript_with_two_diffs_and_tail());

        let full = transcript_lines(&state, 100);
        let body_height = 7;
        let scroll = 9;
        let end = full.len().saturating_sub(scroll);
        let start = end.saturating_sub(body_height);
        let expected = full[start..end].to_vec();

        assert_eq!(
            transcript_visible_lines(&state, 100, body_height, scroll),
            expected
        );
        assert_eq!(
            transcript_visible_lines(&state, 100, body_height, scroll).len(),
            body_height
        );
    }

    #[test]
    fn streaming_activity_updates_current_cell_until_terminal_event() {
        let mut state = State::new(ChatArgs::parse(vec!["--yes".into()]));
        let initial_cells = state.cells.len();

        apply_render_action(
            &mut state,
            RenderAction::Activity {
                tone: Tone::Warning,
                text: "◐ Reading workspace".to_string(),
                detail: Some("input: path: src".to_string()),
                terminal: false,
                control: None,
            },
        );

        assert_eq!(state.cells.len(), initial_cells + 1);
        assert_eq!(state.cells[initial_cells].role, Role::System);
        assert_eq!(
            state.cells[initial_cells].markdown_source(),
            "◐ Reading workspace\ninput: path: src"
        );

        apply_render_action(
            &mut state,
            RenderAction::Activity {
                tone: Tone::Dim,
                text: "✓ Read workspace · files: 3".to_string(),
                detail: Some("output: files: 3".to_string()),
                terminal: true,
                control: None,
            },
        );

        assert_eq!(state.cells.len(), initial_cells + 1);
        assert_eq!(
            state.cells[initial_cells].markdown_source(),
            "✓ Read workspace · files: 3\noutput: files: 3"
        );
        assert_eq!(state.streaming_activity_cell, None);

        apply_render_action(
            &mut state,
            RenderAction::Activity {
                tone: Tone::Warning,
                text: "◐ Searching memory".to_string(),
                detail: None,
                terminal: false,
                control: None,
            },
        );

        assert_eq!(state.cells.len(), initial_cells + 1);
        assert_eq!(state.streaming_activity_cell, None);
    }

    #[test]
    fn transient_activity_updates_pending_spinner_label_without_chat_cell() {
        let mut state = State::new(ChatArgs::parse(vec![]));
        let (_pending_tx, pending_rx) = mpsc::channel::<PendingMessage>();
        let (input_tx, _input_rx) = mpsc::channel();
        let initial_cells = state.cells.len();

        state.pending = Some(Pending {
            label: "working".to_string(),
            started: Instant::now(),
            rx: pending_rx,
            input: Some(input_tx),
            record_chat_response: false,
        });

        apply_render_action(
            &mut state,
            RenderAction::Activity {
                tone: Tone::Warning,
                text: "◐ Reading workspace".to_string(),
                detail: None,
                terminal: false,
                control: None,
            },
        );

        assert_eq!(state.cells.len(), initial_cells);
        assert_eq!(
            state.pending.as_ref().map(|pending| pending.label.as_str()),
            Some("Reading workspace")
        );
    }

    #[test]
    fn activity_content_includes_optional_detail() {
        assert_eq!(
            activity_content("◐ Running command", Some("input: command: mix test")),
            "◐ Running command\ninput: command: mix test"
        );
        assert_eq!(activity_content("plain text", None), "plain text");
    }

    #[test]
    fn approval_activity_sets_footer_prompt_from_structured_control() {
        let mut state = State::new(ChatArgs::parse(vec![]));

        apply_render_action(
            &mut state,
            RenderAction::Activity {
                tone: Tone::Warning,
                text: "! Approval required: Writing file README.md".to_string(),
                detail: None,
                terminal: false,
                control: Some(ActivityControl::Approval {
                    action: "write".to_string(),
                }),
            },
        );

        assert_eq!(
            state.approval_prompt,
            Some(ApprovalPrompt {
                action: "write".to_string()
            })
        );
        assert!(composer_footer(&state).contains("Y approve"));
        assert!(composer_footer(&state).contains("N/Esc deny"));
    }

    #[test]
    fn answer_approval_sends_line_to_pending_input() {
        let mut state = State::new(ChatArgs::parse(vec![]));
        let (_pending_tx, pending_rx) = mpsc::channel::<PendingMessage>();
        let (input_tx, input_rx) = mpsc::channel();

        state.pending = Some(Pending {
            label: "working".to_string(),
            started: Instant::now(),
            rx: pending_rx,
            input: Some(input_tx),
            record_chat_response: false,
        });
        state.approval_prompt = Some(ApprovalPrompt {
            action: "write".to_string(),
        });

        answer_approval(&mut state, true);

        assert_eq!(
            input_rx.try_recv(),
            Ok(StreamInput::Line("y\n".to_string()))
        );
        assert_eq!(state.approval_prompt, None);
    }

    #[test]
    fn esc_denies_pending_approval() {
        let mut state = State::new(ChatArgs::parse(vec![]));
        let (_pending_tx, pending_rx) = mpsc::channel::<PendingMessage>();
        let (input_tx, input_rx) = mpsc::channel();

        state.pending = Some(Pending {
            label: "working".to_string(),
            started: Instant::now(),
            rx: pending_rx,
            input: Some(input_tx),
            record_chat_response: false,
        });
        state.approval_prompt = Some(ApprovalPrompt {
            action: "write".to_string(),
        });

        assert!(!handle_key(
            &mut state,
            KeyEvent::new(KeyCode::Esc, KeyModifiers::NONE)
        ));
        assert_eq!(
            input_rx.try_recv(),
            Ok(StreamInput::Line("n\n".to_string()))
        );
        assert_eq!(state.approval_prompt, None);
        assert!(state
            .cells
            .iter()
            .any(|cell| cell.markdown_source().contains("Approval sent: denied")));
    }

    #[test]
    fn ctrl_c_interrupts_pending_stream_before_quitting() {
        let mut state = State::new(ChatArgs::parse(vec![]));
        let (_pending_tx, pending_rx) = mpsc::channel::<PendingMessage>();
        let (input_tx, input_rx) = mpsc::channel();

        state.pending = Some(Pending {
            label: "working".to_string(),
            started: Instant::now(),
            rx: pending_rx,
            input: Some(input_tx),
            record_chat_response: false,
        });
        state.approval_prompt = Some(ApprovalPrompt {
            action: "write".to_string(),
        });

        assert!(!handle_key(
            &mut state,
            KeyEvent::new(KeyCode::Char('c'), KeyModifiers::CONTROL)
        ));
        assert_eq!(input_rx.try_recv(), Ok(StreamInput::Cancel));
        assert_eq!(state.exit_code, 0);
        assert_eq!(state.approval_prompt, None);
        assert_eq!(
            state.pending.as_ref().map(|pending| pending.label.as_str()),
            Some("interrupting")
        );
        assert!(composer_footer(&state).contains("Ctrl-C interrupt"));
        assert!(state
            .cells
            .iter()
            .any(|cell| cell.markdown_source().as_ref() == "Interrupt requested."));
    }

    #[test]
    fn ctrl_c_quits_when_no_stream_can_be_interrupted() {
        let mut state = State::new(ChatArgs::parse(vec![]));

        assert!(handle_key(
            &mut state,
            KeyEvent::new(KeyCode::Char('c'), KeyModifiers::CONTROL)
        ));
        assert_eq!(state.exit_code, 130);
    }

    #[test]
    fn user_prompt_option_selection_sends_selected_value() {
        let mut state = State::new(ChatArgs::parse(vec![]));
        let (_pending_tx, pending_rx) = mpsc::channel::<PendingMessage>();
        let (input_tx, input_rx) = mpsc::channel();

        state.pending = Some(Pending {
            label: "working".to_string(),
            started: Instant::now(),
            rx: pending_rx,
            input: Some(input_tx),
            record_chat_response: false,
        });

        apply_render_action(
            &mut state,
            RenderAction::Activity {
                tone: Tone::Warning,
                text: "? Choose a path".to_string(),
                detail: None,
                terminal: false,
                control: Some(ActivityControl::UserInput {
                    question: "Choose a path".to_string(),
                    description: Some("Pick one.".to_string()),
                    options: vec![
                        QuestionOption {
                            label: "Plan".to_string(),
                            value: "plan".to_string(),
                            description: None,
                        },
                        QuestionOption {
                            label: "Build".to_string(),
                            value: "build".to_string(),
                            description: Some("Start implementation".to_string()),
                        },
                    ],
                }),
            },
        );

        assert!(composer_footer(&state).contains("Up/Down select"));
        move_user_prompt(&mut state, 1);
        let prompt = state.user_prompt.as_ref().expect("prompt");
        assert_eq!(prompt.selected, 1);
        let ComposerContent::UserPrompt(view) = composer_content(&state) else {
            panic!("expected user prompt composer content");
        };
        assert_eq!(view.selected, 1);
        assert_eq!(view.options[1].label, "Build");
        assert_eq!(
            view.options[1].description.as_deref(),
            Some("Start implementation")
        );
        assert!(Composer::new(&state, 80, 24).input_lines.is_empty());

        answer_user_prompt(&mut state);

        assert_eq!(
            input_rx.try_recv(),
            Ok(StreamInput::Line("build\n".to_string()))
        );
        assert_eq!(state.user_prompt, None);
        assert!(state
            .cells
            .iter()
            .any(|cell| cell.role == Role::User && cell.markdown_source().as_ref() == "build"));
    }

    #[test]
    fn user_prompt_text_answer_sends_typed_value() {
        let mut state = State::new(ChatArgs::parse(vec![]));
        let (_pending_tx, pending_rx) = mpsc::channel::<PendingMessage>();
        let (input_tx, input_rx) = mpsc::channel();

        state.pending = Some(Pending {
            label: "working".to_string(),
            started: Instant::now(),
            rx: pending_rx,
            input: Some(input_tx),
            record_chat_response: false,
        });

        open_user_prompt(&mut state, "What name?".to_string(), None, Vec::new());
        state.input = "Holt".to_string();

        assert_eq!(
            Composer::new(&state, 80, 24).input_lines,
            vec!["Holt".to_string()]
        );

        answer_user_prompt(&mut state);

        assert_eq!(
            input_rx.try_recv(),
            Ok(StreamInput::Line("Holt\n".to_string()))
        );
    }

    #[test]
    fn text_user_prompt_route_keeps_input_editing_keys() {
        let mut state = State::new(ChatArgs::parse(vec![]));
        open_user_prompt(&mut state, "What name?".to_string(), None, Vec::new());
        set_input(&mut state, "HoltWorks".to_string());

        assert_eq!(composer_input_route(&state), ComposerInputRoute::UserPrompt);
        assert!(!handle_key(
            &mut state,
            KeyEvent::new(KeyCode::Char('a'), KeyModifiers::CONTROL)
        ));
        assert_eq!(state.input_cursor, 0);
        assert!(!handle_key(
            &mut state,
            KeyEvent::new(KeyCode::Delete, KeyModifiers::NONE)
        ));
        assert_eq!(state.input, "oltWorks");
    }

    #[test]
    fn run_picker_marks_selection_and_moves_between_runs() {
        let runs = vec![
            RunSummary {
                id: "run_1".to_string(),
                status: "completed".to_string(),
                objective: "first run".to_string(),
                artifact: Some("NEXT_STEPS.md".to_string()),
                answer_preview: Some("first final answer".to_string()),
            },
            RunSummary {
                id: "run_2".to_string(),
                status: "blocked".to_string(),
                objective: "second\nrun".to_string(),
                artifact: None,
                answer_preview: None,
            },
        ];
        let mut state = State::new(ChatArgs::parse(vec!["--yes".into()]));

        open_run_picker(&mut state, runs);

        let picker = state.run_picker.as_ref().expect("picker");
        assert_eq!(picker.selected, 0);
        let ComposerContent::RunPicker(view) = composer_content(&state) else {
            panic!("expected run picker composer content");
        };
        assert!(view
            .rows
            .iter()
            .any(|row| row.selected && row.id == "run_1"));
        let detail = view.detail.expect("selected detail");
        assert_eq!(detail.artifact.as_deref(), Some("NEXT_STEPS.md"));
        assert_eq!(detail.answer.as_deref(), Some("first final answer"));
        assert!(composer_footer(&state).contains("Enter resume"));
        assert!(composer_footer(&state).contains("F fork"));
        assert!(composer_footer(&state).contains("L logs"));

        move_run_picker(&mut state, 1);

        let picker = state.run_picker.as_ref().expect("picker");
        assert_eq!(picker.selected, 1);
        let ComposerContent::RunPicker(view) = composer_content(&state) else {
            panic!("expected run picker composer content");
        };
        assert!(view
            .rows
            .iter()
            .any(|row| row.selected && row.id == "run_2"));
        let detail = view.detail.expect("selected detail");
        assert_eq!(detail.objective, "second run");
        assert_eq!(detail.answer, None);
    }

    #[test]
    fn resume_context_content_includes_selected_run_details() {
        let content = resume_context_content(&RunSummary {
            id: "run_42".to_string(),
            status: "completed".to_string(),
            objective: "finish the very specific implementation".to_string(),
            artifact: Some("NEXT_STEPS.md".to_string()),
            answer_preview: Some("All checks passed.".to_string()),
        });

        assert!(content.contains("/resume run_42"));
        assert!(content.contains("Resuming run"));
        assert!(content.contains("- Status: completed"));
        assert!(content.contains("- Objective: finish the very specific implementation"));
        assert!(content.contains("- Artifact: NEXT_STEPS.md"));
        assert!(content.contains("- Latest answer: All checks passed."));

        let no_answer = resume_context_content(&RunSummary {
            id: "run_43".to_string(),
            status: "blocked".to_string(),
            objective: "continue without an answer".to_string(),
            artifact: None,
            answer_preview: None,
        });

        assert!(no_answer.contains("- Latest answer: none recorded yet"));
    }

    #[test]
    fn run_picker_supports_page_and_edge_navigation() {
        let runs = (1..=8)
            .map(|index| RunSummary {
                id: format!("run_{index}"),
                status: "completed".to_string(),
                objective: format!("run {index}"),
                artifact: None,
                answer_preview: None,
            })
            .collect::<Vec<_>>();
        let mut state = State::new(ChatArgs::parse(vec!["--yes".into()]));

        open_run_picker(&mut state, runs);

        assert!(!handle_key(
            &mut state,
            KeyEvent::new(KeyCode::PageDown, KeyModifiers::NONE)
        ));
        let picker = state.run_picker.as_ref().expect("picker");
        assert_eq!(picker.selected, 5);
        assert_selected_run_picker_row(&state, "run_6");

        assert!(!handle_key(
            &mut state,
            KeyEvent::new(KeyCode::End, KeyModifiers::NONE)
        ));
        let picker = state.run_picker.as_ref().expect("picker");
        assert_eq!(picker.selected, 7);
        assert_selected_run_picker_row(&state, "run_8");

        assert!(!handle_key(
            &mut state,
            KeyEvent::new(KeyCode::PageUp, KeyModifiers::NONE)
        ));
        let picker = state.run_picker.as_ref().expect("picker");
        assert_eq!(picker.selected, 2);
        assert_selected_run_picker_row(&state, "run_3");

        assert!(!handle_key(
            &mut state,
            KeyEvent::new(KeyCode::Home, KeyModifiers::NONE)
        ));
        let picker = state.run_picker.as_ref().expect("picker");
        assert_eq!(picker.selected, 0);
        assert_selected_run_picker_row(&state, "run_1");
    }

    #[test]
    fn run_picker_composer_view_includes_keyboard_help_and_detail() {
        let mut state = State::new(ChatArgs::parse(vec![]));
        open_run_picker(
            &mut state,
            vec![RunSummary {
                id: "run_1".to_string(),
                status: "completed".to_string(),
                objective: "inspect workspace".to_string(),
                artifact: None,
                answer_preview: Some("final answer preview".to_string()),
            }],
        );

        assert!(composer_footer(&state).contains("Enter resume"));
        assert!(composer_footer(&state).contains("PgUp/PgDn jump"));
        assert!(composer_footer(&state).contains("Home/End edge"));
        assert!(composer_footer(&state).contains("F fork"));
        assert!(composer_footer(&state).contains("L logs"));
        assert!(Composer::new(&state, 80, 24).input_lines.is_empty());

        let ComposerContent::RunPicker(view) = composer_content(&state) else {
            panic!("expected run picker composer content");
        };
        assert!(view
            .rows
            .iter()
            .any(|row| row.selected && row.id == "run_1"));
        assert_eq!(
            view.detail.and_then(|detail| detail.answer),
            Some("final answer preview".to_string())
        );
    }

    #[test]
    fn run_list_pending_opens_picker() {
        let mut state = State::new(ChatArgs::parse(vec!["--yes".into()]));

        finish_pending(
            &mut state,
            PendingMessage::RunList(Ok(vec![RunSummary {
                id: "run_1".to_string(),
                status: "completed".to_string(),
                objective: "inspect workspace".to_string(),
                artifact: None,
                answer_preview: Some("answer preview".to_string()),
            }])),
        );

        let picker = state.run_picker.as_ref().expect("picker");
        assert_eq!(picker.selected, 0);
        let ComposerContent::RunPicker(view) = composer_content(&state) else {
            panic!("expected run picker composer content");
        };
        assert!(view
            .rows
            .iter()
            .any(|row| row.selected && row.id == "run_1"));
        assert_eq!(
            view.detail.and_then(|detail| detail.answer),
            Some("answer preview".to_string())
        );
    }

    fn assert_selected_run_picker_row(state: &State, run_id: &str) {
        let ComposerContent::RunPicker(view) = composer_content(state) else {
            panic!("expected run picker composer content");
        };
        assert!(
            view.rows.iter().any(|row| row.selected && row.id == run_id),
            "expected selected row {run_id}, got {:?}",
            view.rows
        );
    }

    fn transcript_with_two_diffs_and_tail() -> String {
        let mut content = r#"First edit

```diff
diff --git a/src/one.rs b/src/one.rs
@@ -1,1 +1,1 @@
-one
+uno
```

Second edit

```diff
diff --git a/src/two.rs b/src/two.rs
@@ -1,1 +1,1 @@
-two
+dos
```

"#
        .to_string();

        for index in 0..40 {
            content.push_str(&format!("tail line {index}\n\n"));
        }

        content
    }

    fn temp_workspace() -> PathBuf {
        let millis = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_millis();
        let counter = TEMP_WORKSPACE_COUNTER.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "holt-cli-tui-history-test-{}-{millis}-{counter}",
            std::process::id(),
        ));
        fs::create_dir_all(&path).unwrap();
        path
    }

    fn write_keymap_config(workspace: &PathBuf, content: &str) {
        let config_dir = workspace.join(".holtworks");
        fs::create_dir_all(&config_dir).unwrap();
        fs::write(config_dir.join("cli_keymap.json"), content).unwrap();
    }

    #[test]
    fn visual_input_preserves_explicit_newlines() {
        assert_eq!(
            super::visual_input_lines("hello\nworld", 20),
            vec!["hello", "world"]
        );
    }

    #[test]
    fn visible_input_keeps_tail_when_input_is_tall() {
        assert_eq!(
            super::visible_input_lines("one\ntwo\nthree", 20, 2),
            vec!["…two", "three"]
        );
    }
}
