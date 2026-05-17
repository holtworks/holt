use crate::{backend, terminal, ui};
use anyhow::{Context, Result};
use crossterm::{
    cursor::{Hide, MoveTo, Show},
    event::{self, Event, KeyCode, KeyEvent, KeyModifiers},
    queue,
    style::{Print, ResetColor, SetForegroundColor},
    terminal::{Clear, ClearType},
};
use serde_json::Value;
use std::{
    fs,
    io::{self, Write},
    path::{Path, PathBuf},
    sync::mpsc::{self, Receiver},
    thread,
    time::{Duration, Instant},
};
use ui::{RenderLine, Tone};

const COMMANDS: &[CommandSpec] = &[
    CommandSpec {
        name: "/help",
        description: "show commands",
    },
    CommandSpec {
        name: "/status",
        description: "show workspace status",
    },
    CommandSpec {
        name: "/doctor",
        description: "check setup and provider",
    },
    CommandSpec {
        name: "/model",
        description: "show provider details",
    },
    CommandSpec {
        name: "/runs",
        description: "show recent runs",
    },
    CommandSpec {
        name: "/logs",
        description: "show latest run events",
    },
    CommandSpec {
        name: "/resume",
        description: "rerun latest or selected run",
    },
    CommandSpec {
        name: "/history",
        description: "show prompts from this chat",
    },
    CommandSpec {
        name: "/clear",
        description: "clear the transcript",
    },
    CommandSpec {
        name: "/exit",
        description: "quit",
    },
];

struct CommandSpec {
    name: &'static str,
    description: &'static str,
}

#[derive(Clone, Debug)]
pub struct ChatArgs {
    runtime_flags: Vec<String>,
    prompt: Option<String>,
    workspace: Option<String>,
    pub plain: bool,
    pub force_tui: bool,
    pub yes: bool,
}

impl ChatArgs {
    pub fn parse(args: Vec<String>) -> Self {
        let mut runtime_flags = Vec::new();
        let mut prompt_parts = Vec::new();
        let mut workspace = None;
        let mut plain = false;
        let mut force_tui = false;
        let mut yes = false;
        let mut index = 0;

        while index < args.len() {
            let arg = &args[index];

            match arg.as_str() {
                "--plain" => {
                    plain = true;
                    index += 1;
                }
                "--tui" | "--fullscreen" => {
                    force_tui = true;
                    index += 1;
                }
                "--yes" | "-y" => {
                    yes = true;
                    runtime_flags.push(arg.clone());
                    index += 1;
                }
                "--api-key-stdin" => {
                    runtime_flags.push(arg.clone());
                    index += 1;
                }
                "--home" | "--workspace" | "--provider" | "--model" | "--mode" | "--base-url"
                | "--api-key-env" | "--env-file" => {
                    runtime_flags.push(arg.clone());

                    if let Some(value) = args.get(index + 1) {
                        if arg == "--workspace" {
                            workspace = Some(value.clone());
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
            plain,
            force_tui,
            yes,
        }
    }

    #[cfg(test)]
    fn has_prompt(&self) -> bool {
        self.prompt.is_some()
    }

    pub(crate) fn one_shot_chat_run_args(&self) -> Option<Vec<String>> {
        self.prompt
            .as_ref()
            .map(|prompt| self.chat_run_args(prompt, None))
    }

    pub(crate) fn command_args(&self, command: &str) -> Vec<String> {
        let mut args = vec![command.to_string()];
        args.extend(self.runtime_flags.clone());
        args
    }

    #[cfg(test)]
    fn run_args(&self, prompt: &str) -> Vec<String> {
        let mut args = vec!["run".to_string()];
        args.extend(self.runtime_flags.clone());

        if !self.yes {
            args.push("--yes".to_string());
        }

        args.push(prompt.to_string());
        args
    }

    pub(crate) fn chat_run_args(&self, prompt: &str, chat_context: Option<&str>) -> Vec<String> {
        let mut args = vec!["run".to_string()];
        args.extend(self.runtime_flags_without_mode());

        if !self.yes {
            args.push("--yes".to_string());
        }

        args.push("--mode".to_string());
        args.push("chat".to_string());

        if let Some(context) = chat_context.filter(|value| !value.is_empty()) {
            args.push("--chat-context".to_string());
            args.push(context.to_string());
        }

        args.push(prompt.to_string());
        args
    }

    fn runtime_flags_without_mode(&self) -> Vec<String> {
        let mut filtered = Vec::new();
        let mut index = 0;

        while index < self.runtime_flags.len() {
            if self.runtime_flags[index] == "--mode" {
                index += 2;
            } else {
                filtered.push(self.runtime_flags[index].clone());
                index += 1;
            }
        }

        filtered
    }

    pub(crate) fn resume_args(&self, run_ref: &str) -> Vec<String> {
        let mut args = vec!["resume".to_string()];
        args.extend(self.runtime_flags.clone());

        if !self.yes {
            args.push("--yes".to_string());
        }

        args.push(run_ref.to_string());
        args
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

pub fn run(session: ChatArgs) -> Result<i32> {
    let _guard = terminal::enter_alt_screen()?;
    let mut state = State::new(session);
    let mut dirty = true;

    loop {
        if dirty {
            render(&state)?;
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
                Event::Resize(_, _) => {
                    state.scroll = 0;
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

struct State {
    session: ChatArgs,
    cells: Vec<Cell>,
    input: String,
    history: Vec<String>,
    history_cursor: Option<usize>,
    scroll: usize,
    frame: usize,
    pending: Option<Pending>,
    exit_code: i32,
}

impl State {
    fn new(session: ChatArgs) -> Self {
        let workspace = session.workspace_root();
        let approval = if session.yes {
            "auto-approve"
        } else {
            "review changes"
        };

        Self {
            session,
            cells: vec![Cell {
                role: Role::System,
                content: format!(
                    "Holt ready.\nWorkspace: {}\nMode: {approval}\nType a task or /help.",
                    workspace.display()
                ),
            }],
            input: String::new(),
            history: Vec::new(),
            history_cursor: None,
            scroll: 0,
            frame: 0,
            pending: None,
            exit_code: 0,
        }
    }

    fn add_cell(&mut self, role: Role, content: impl Into<String>) {
        self.cells.push(Cell {
            role,
            content: content.into(),
        });
        self.scroll = 0;
    }

    fn chat_context(&self) -> Option<String> {
        if self.history.is_empty() {
            return None;
        }

        Some(
            self.history
                .iter()
                .rev()
                .take(8)
                .collect::<Vec<_>>()
                .into_iter()
                .rev()
                .map(|prompt| format!("user: {prompt}"))
                .collect::<Vec<_>>()
                .join("\n"),
        )
    }
}

struct Pending {
    label: String,
    started: Instant,
    rx: Receiver<Result<backend::BackendOutput, String>>,
}

struct Cell {
    role: Role,
    content: String,
}

#[derive(Clone, Copy)]
enum Role {
    Assistant,
    Error,
    System,
    User,
}

fn render(state: &State) -> Result<()> {
    let (width, height) = terminal::terminal_size();
    let width = width.max(60);
    let height = height.max(18);
    let mut stdout = io::stdout();
    let composer = Composer::new(state, width, height);

    queue!(stdout, Hide, MoveTo(0, 0), Clear(ClearType::All))?;
    draw_header(&mut stdout, state, width)?;

    let top = 4;
    let body_height = height
        .saturating_sub(top)
        .saturating_sub(composer.height)
        .saturating_sub(1) as usize;
    let body_lines = transcript_lines(state, width as usize);
    let end = body_lines.len().saturating_sub(state.scroll);
    let start = end.saturating_sub(body_height);

    for (row, line) in body_lines[start..end].iter().enumerate() {
        write_line(
            &mut stdout,
            0,
            top + row as u16,
            width,
            &line.text,
            line.tone,
        )?;
    }

    draw_composer(&mut stdout, &composer, width, height)?;
    queue!(
        stdout,
        MoveTo(composer.cursor_x, composer.cursor_y),
        Show,
        ResetColor
    )?;
    stdout.flush().context("failed to flush terminal")?;
    Ok(())
}

fn draw_header(stdout: &mut io::Stdout, state: &State, width: u16) -> Result<()> {
    let workspace = state.session.workspace_root();
    let workspace = workspace.display().to_string();
    let permission = if state.session.yes {
        "auto-approve"
    } else {
        "review changes"
    };

    write_line(
        stdout,
        0,
        0,
        width,
        &format!("╭─ Holt {}", "─".repeat(width.saturating_sub(8) as usize)),
        Tone::Accent,
    )?;
    write_line(
        stdout,
        0,
        1,
        width,
        &format!(
            "│ {} · {permission} · {}",
            "workspace",
            ui::truncate(&workspace, width.saturating_sub(28) as usize)
        ),
        Tone::Plain,
    )?;
    write_line(
        stdout,
        0,
        2,
        width,
        &format!("╰{}", "─".repeat(width.saturating_sub(1) as usize)),
        Tone::Border,
    )?;
    Ok(())
}

fn draw_composer(
    stdout: &mut io::Stdout,
    composer: &Composer,
    width: u16,
    height: u16,
) -> Result<()> {
    let top = height.saturating_sub(composer.height);

    write_line(
        stdout,
        0,
        top,
        width,
        &format!("╭─ {} {}", composer.title, composer.rule),
        composer.title_tone,
    )?;

    for (index, line) in composer.input_lines.iter().enumerate() {
        let prefix = if index == 0 { "│ > " } else { "│   " };
        write_line(
            stdout,
            0,
            top + 1 + index as u16,
            width,
            &format!("{prefix}{line}"),
            Tone::User,
        )?;
    }

    let mut row = top + 1 + composer.input_lines.len() as u16;

    for suggestion in &composer.suggestions {
        write_line(stdout, 0, row, width, suggestion, Tone::Dim)?;
        row += 1;
    }

    write_line(stdout, 0, row, width, &composer.footer, Tone::Dim)?;
    row += 1;
    write_line(
        stdout,
        0,
        row,
        width,
        &format!("╰{}", "─".repeat(width.saturating_sub(1) as usize)),
        Tone::Border,
    )?;
    Ok(())
}

fn transcript_lines(state: &State, width: usize) -> Vec<RenderLine> {
    let mut lines = Vec::new();
    let body_width = width.saturating_sub(6).max(16);

    for cell in &state.cells {
        let (label, tone) = match cell.role {
            Role::Assistant => ("holt", Tone::Accent),
            Role::Error => ("error", Tone::Error),
            Role::System => ("system", Tone::System),
            Role::User => ("you", Tone::User),
        };

        lines.push(RenderLine::new(format!("╭─ {label}"), tone));

        for line in ui::markdown_lines(&cell.content, body_width) {
            let line_tone = if matches!(cell.role, Role::Error) {
                Tone::Error
            } else {
                line.tone
            };
            lines.push(RenderLine::new(format!("│ {}", line.text), line_tone));
        }

        lines.push(RenderLine::new("╰─", Tone::Border));
        lines.push(RenderLine::new("", Tone::Plain));
    }

    lines
}

fn write_line(
    stdout: &mut io::Stdout,
    x: u16,
    y: u16,
    width: u16,
    text: &str,
    tone: Tone,
) -> Result<()> {
    let clean = ui::truncate(text, width as usize);
    queue!(
        stdout,
        MoveTo(x, y),
        SetForegroundColor(ui::color(tone)),
        Print(clean),
        ResetColor,
        Clear(ClearType::UntilNewLine)
    )?;
    Ok(())
}

fn handle_key(state: &mut State, key: KeyEvent) -> bool {
    match (key.code, key.modifiers) {
        (KeyCode::Char('c'), KeyModifiers::CONTROL) => {
            state.exit_code = 130;
            true
        }
        (KeyCode::Char('d'), KeyModifiers::CONTROL) => true,
        (KeyCode::Char('l'), KeyModifiers::CONTROL) => {
            state.cells.clear();
            false
        }
        (KeyCode::Esc, _) => {
            state.input.clear();
            state.history_cursor = None;
            false
        }
        (KeyCode::Enter, KeyModifiers::SHIFT) => {
            state.input.push('\n');
            state.history_cursor = None;
            false
        }
        (KeyCode::Char('j'), KeyModifiers::CONTROL) => {
            state.input.push('\n');
            state.history_cursor = None;
            false
        }
        (KeyCode::Enter, _) => submit(state),
        (KeyCode::Backspace, _) => {
            state.input.pop();
            state.history_cursor = None;
            false
        }
        (KeyCode::PageUp, _) => {
            state.scroll = state.scroll.saturating_add(8);
            false
        }
        (KeyCode::PageDown, _) => {
            state.scroll = state.scroll.saturating_sub(8);
            false
        }
        (KeyCode::Up, _) => {
            recall_history(state, -1);
            false
        }
        (KeyCode::Down, _) => {
            recall_history(state, 1);
            false
        }
        (KeyCode::Char(ch), modifiers)
            if !modifiers.contains(KeyModifiers::CONTROL)
                && !modifiers.contains(KeyModifiers::ALT) =>
        {
            state.input.push(ch);
            state.history_cursor = None;
            false
        }
        _ => false,
    }
}

fn submit(state: &mut State) -> bool {
    let input = state.input.trim().to_string();
    state.input.clear();
    state.history_cursor = None;

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

    match input.as_str() {
        "/exit" | "/quit" => return true,
        "/help" => show_help(state),
        "/clear" => state.cells.clear(),
        "/history" => show_history(state),
        "/status" => start_backend(state, "status", state.session.command_args("status")),
        "/doctor" => start_backend(state, "doctor", state.session.command_args("doctor")),
        "/model" => start_backend(state, "doctor", state.session.command_args("doctor")),
        "/logs" => start_backend(state, "logs", state.session.command_args("logs")),
        "/runs" => show_runs(state),
        command if command.starts_with("/resume") => {
            let run_ref = command
                .strip_prefix("/resume")
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .unwrap_or("latest");
            start_backend(state, "resume", state.session.resume_args(run_ref));
        }
        command if command.starts_with('/') => {
            state.add_cell(
                Role::Error,
                format!("Unknown command: {command}\nRun /help for available commands."),
            );
        }
        prompt => {
            state.add_cell(Role::User, prompt.to_string());
            let chat_context = state.chat_context();
            state.history.push(prompt.to_string());
            start_backend(
                state,
                "working",
                state.session.chat_run_args(prompt, chat_context.as_deref()),
            );
        }
    }

    false
}

fn show_help(state: &mut State) {
    let rows = COMMANDS
        .iter()
        .map(|command| format!("{:<18} {}", command.name, command.description))
        .collect::<Vec<_>>()
        .join("\n");

    state.add_cell(
        Role::Assistant,
        format!("{rows}\n\nPlain text starts a request. Shift+Enter or Ctrl-J inserts a newline."),
    );
}

fn show_history(state: &mut State) {
    if state.history.is_empty() {
        state.add_cell(Role::Assistant, "No prompts in this chat yet.");
        return;
    }

    let rows = state
        .history
        .iter()
        .enumerate()
        .map(|(index, prompt)| format!("{}. {}", index + 1, prompt))
        .collect::<Vec<_>>()
        .join("\n");
    state.add_cell(Role::Assistant, rows);
}

fn show_runs(state: &mut State) {
    match read_runs(&state.session.workspace_root()) {
        Ok(runs) if runs.is_empty() => state.add_cell(Role::Assistant, "No runs yet."),
        Ok(runs) => state.add_cell(Role::Assistant, runs.join("\n")),
        Err(error) => state.add_cell(Role::Error, format!("Could not read runs: {error}")),
    }
}

fn read_runs(workspace: &Path) -> Result<Vec<String>> {
    let runs_dir = workspace.join(".holtworks").join("runs");
    let mut entries = match fs::read_dir(&runs_dir) {
        Ok(entries) => entries
            .filter_map(|entry| entry.ok())
            .filter(|entry| entry.file_type().map(|kind| kind.is_dir()).unwrap_or(false))
            .map(|entry| entry.path())
            .collect::<Vec<_>>(),
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(error).context("failed to read runs directory"),
    };

    entries.sort_by(|left, right| right.cmp(left));

    let mut rows = Vec::new();

    for run_dir in entries.into_iter().take(8) {
        if let Some(summary) = read_run_summary(&run_dir)? {
            rows.push(summary);
        }
    }

    Ok(rows)
}

fn read_run_summary(run_dir: &Path) -> Result<Option<String>> {
    let path = run_dir.join("run.json");
    let content = match fs::read_to_string(&path) {
        Ok(content) => content,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => {
            return Err(error).with_context(|| format!("failed to read {}", path.display()))
        }
    };

    let value: Value = serde_json::from_str(&content)
        .with_context(|| format!("failed to decode {}", path.display()))?;
    let id = value.get("id").and_then(Value::as_str).unwrap_or("run");
    let status = value
        .get("status")
        .and_then(Value::as_str)
        .unwrap_or("unknown");
    let objective = value.get("objective").and_then(Value::as_str).unwrap_or("");

    Ok(Some(format!("{id:<24} {status:<12} {objective}")))
}

fn start_backend(state: &mut State, label: &str, args: Vec<String>) {
    let (tx, rx) = mpsc::channel();
    let label = label.to_string();

    thread::spawn(move || {
        let result = backend::capture(&args).map_err(|error| error.to_string());
        let _ = tx.send(result);
    });

    state.pending = Some(Pending {
        label,
        started: Instant::now(),
        rx,
    });
    state.frame = 0;
}

fn poll_pending(state: &mut State) -> Option<Result<backend::BackendOutput, String>> {
    let pending = state.pending.as_ref()?;

    match pending.rx.try_recv() {
        Ok(result) => {
            state.pending = None;
            Some(result)
        }
        Err(mpsc::TryRecvError::Empty) => None,
        Err(mpsc::TryRecvError::Disconnected) => {
            state.pending = None;
            Some(Err("Holt disconnected".to_string()))
        }
    }
}

fn finish_pending(state: &mut State, result: Result<backend::BackendOutput, String>) {
    match result {
        Ok(output) if output.code == 0 => {
            let text = output.stdout.trim();

            if text.is_empty() {
                state.add_cell(Role::Assistant, "Done.");
            } else {
                state.add_cell(Role::Assistant, text.to_string());
            }

            if !output.stderr.trim().is_empty() {
                state.add_cell(Role::System, output.stderr.trim().to_string());
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

fn recall_history(state: &mut State, delta: isize) {
    if state.history.is_empty() {
        return;
    }

    let current = state.history_cursor.unwrap_or(state.history.len());
    let next = if delta < 0 {
        current.saturating_sub(1)
    } else {
        (current + 1).min(state.history.len())
    };

    state.history_cursor = if next >= state.history.len() {
        state.input.clear();
        None
    } else {
        state.input = state.history[next].clone();
        Some(next)
    };
}

struct Composer {
    title: String,
    title_tone: Tone,
    rule: String,
    input_lines: Vec<String>,
    suggestions: Vec<String>,
    footer: String,
    height: u16,
    cursor_x: u16,
    cursor_y: u16,
}

impl Composer {
    fn new(state: &State, width: u16, terminal_height: u16) -> Self {
        let input_width = width.saturating_sub(6).max(8) as usize;
        let input_lines = visible_input_lines(&state.input, input_width, 6);
        let suggestions = slash_suggestions(&state.input, width);
        let title = composer_title(state);
        let title_tone = if state.pending.is_some() {
            Tone::Warning
        } else {
            Tone::Accent
        };
        let footer = composer_footer(state);
        let reserved = 3 + input_lines.len() + suggestions.len();
        let height = reserved.clamp(4, 12) as u16;
        let rule_width = width
            .saturating_sub(4)
            .saturating_sub(title.chars().count() as u16) as usize;
        let rule = "─".repeat(rule_width);
        let cursor_line = input_lines.len().saturating_sub(1);
        let cursor_text_width = input_lines
            .last()
            .map(|line| line.chars().count())
            .unwrap_or_default();
        let cursor_x = (4 + cursor_text_width).min(width.saturating_sub(1) as usize) as u16;
        let composer_top = terminal_height.max(18).saturating_sub(height);
        let cursor_y = composer_top + 1 + cursor_line as u16;

        Self {
            title,
            title_tone,
            rule,
            input_lines,
            suggestions,
            footer,
            height,
            cursor_x,
            cursor_y,
        }
    }
}

fn composer_title(state: &State) -> String {
    match &state.pending {
        Some(pending) => format!(
            "{} {} {} {:.1}s",
            ui::spinner(state.frame),
            ui::ripple(state.frame, 18),
            pending.label,
            pending.started.elapsed().as_secs_f32()
        ),
        None => "message".to_string(),
    }
}

fn composer_footer(state: &State) -> String {
    let mode = if state.session.yes {
        "auto-approve"
    } else {
        "review writes"
    };

    format!("│ {mode} · Enter send · S-Enter newline · Ctrl-L clear · Ctrl-C quit")
}

fn slash_suggestions(input: &str, width: u16) -> Vec<String> {
    let trimmed = input.trim_start();

    if !trimmed.starts_with('/') || trimmed.contains(char::is_whitespace) {
        return Vec::new();
    }

    let matches = COMMANDS
        .iter()
        .filter(|command| command.name.starts_with(trimmed))
        .take(5)
        .map(|command| {
            ui::truncate(
                &format!("│   {:<14} {}", command.name, command.description),
                width as usize,
            )
        })
        .collect::<Vec<_>>();

    if matches.is_empty() && trimmed != "/" {
        vec![ui::truncate("│   no matching command", width as usize)]
    } else {
        matches
    }
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

fn visible_input_lines(input: &str, width: usize, max_lines: usize) -> Vec<String> {
    let mut lines = visual_input_lines(input, width);

    if lines.len() > max_lines {
        let omitted = lines.len() - max_lines;
        lines = lines.split_off(omitted);

        if let Some(first) = lines.first_mut() {
            *first = format!("…{first}");
        }
    }

    lines
}

#[cfg(test)]
mod tests {
    use super::ChatArgs;

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
    fn tui_run_args_adds_yes_for_non_interactive_backend_capture() {
        let args = ChatArgs::parse(vec!["--workspace".into(), "/tmp/work".into()]);

        assert_eq!(
            args.run_args("inspect"),
            vec!["run", "--workspace", "/tmp/work", "--yes", "inspect"]
        );
    }

    #[test]
    fn chat_run_args_use_chat_mode_runner() {
        let args = ChatArgs::parse(vec![
            "--workspace".into(),
            "/tmp/work".into(),
            "--mode".into(),
            "plan".into(),
        ]);

        assert_eq!(
            args.chat_run_args("hello", None),
            vec![
                "run",
                "--workspace",
                "/tmp/work",
                "--yes",
                "--mode",
                "chat",
                "hello"
            ]
        );
    }

    #[test]
    fn chat_run_args_include_prior_chat_context() {
        let args = ChatArgs::parse(vec!["--yes".into()]);

        assert_eq!(
            args.chat_run_args("the entire project", Some("user: read this repo")),
            vec![
                "run",
                "--yes",
                "--mode",
                "chat",
                "--chat-context",
                "user: read this repo",
                "the entire project"
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
        let suggestions = super::slash_suggestions("/he", 100);

        assert!(suggestions.iter().any(|line| line.contains("/help")));
        assert!(!suggestions.iter().any(|line| line.contains("/status")));
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
