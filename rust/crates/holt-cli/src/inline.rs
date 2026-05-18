use crate::{
    backend,
    commands::{self, SlashCommand, KEY_BINDINGS, SLASH_COMMANDS},
    history, keymap, terminal,
    tui::{ChatArgs, InteractionMode},
    turn::{ActivityControl, QuestionOption, RenderAction, TurnState},
    ui,
};
use anyhow::{Context, Result};
use crossterm::{
    cursor::MoveToColumn,
    event::{self, Event, KeyCode, KeyEvent, KeyModifiers},
    execute, queue,
    style::{Color as CrosstermColor, Print, ResetColor, SetForegroundColor},
    terminal::{disable_raw_mode, enable_raw_mode, Clear, ClearType},
};
use holt_protocol::ChatMessage;
use ratatui::style::Color as RatColor;
use serde_json::Value;
use std::{
    io::{self, IsTerminal, Write},
    path::{Path, PathBuf},
    sync::mpsc,
    thread,
    time::{Duration, Instant},
};
use ui::Tone;

pub fn run(session: ChatArgs) -> Result<i32> {
    let mut app = InlineApp::new(session);
    app.run()
}

pub(crate) fn run_once(args: Vec<String>, workspace: PathBuf) -> Result<i32> {
    Ok(run_streamed_turn(args, false, workspace)?.code)
}

struct InlineApp {
    session: ChatArgs,
    history: Vec<String>,
    chat_messages: Vec<ChatMessage>,
}

impl InlineApp {
    fn new(session: ChatArgs) -> Self {
        let workspace = session.workspace_root();
        let history = history::load_prompt_history(&workspace);

        Self {
            session,
            history,
            chat_messages: Vec::new(),
        }
    }

    fn run(&mut self) -> Result<i32> {
        self.print_intro()?;

        loop {
            let input = match read_prompt("› ", &self.history)? {
                PromptResult::Line(input) => input,
                PromptResult::Eof => {
                    println!();
                    return Ok(0);
                }
                PromptResult::Interrupt => {
                    println!();
                    return Ok(130);
                }
            };

            let input = input.trim().to_string();

            if input.is_empty() {
                continue;
            }

            if input == "/exit" {
                return Ok(0);
            }

            if input.starts_with('/') {
                let code = self.handle_command(&input)?;
                if code != 0 {
                    return Ok(code);
                }
                continue;
            }

            let chat_messages = self.recent_chat_messages();
            let _ =
                history::remember_prompt(&mut self.history, &self.session.workspace_root(), &input);
            self.chat_messages.push(ChatMessage::user(input.clone()));
            let outcome = run_streamed_turn(
                self.session.turn_run_args(&input, &chat_messages),
                true,
                self.session.workspace_root(),
            )?;
            let code = outcome.code;

            if code == 0 {
                if let Some(answer) = outcome.answer {
                    self.chat_messages.push(ChatMessage::assistant(answer));
                }
            }

            if code != 0 {
                print_tone(Tone::Error, &format!("Holt finished with code {code}"))?;
                println!();
            }
        }
    }

    fn handle_command(&mut self, input: &str) -> Result<i32> {
        let command = match commands::parse(input) {
            Ok(Some(command)) => command,
            Ok(None) => return Ok(0),
            Err(error) => {
                print_tone(Tone::Error, &error.to_string())?;
                print_tone(Tone::Dim, "run /help for available commands")?;
                return Ok(0);
            }
        };

        match command {
            SlashCommand::Help => {
                print_help()?;
                Ok(0)
            }
            SlashCommand::Keymap => {
                print_keymap(&self.session.workspace_root())?;
                Ok(0)
            }
            SlashCommand::Permissions { mode } => {
                if let Some(mode) = mode {
                    self.session.set_permission_mode(mode);
                }

                print_tone(
                    Tone::Plain,
                    &format!("Permissions: {}", self.session.permission_mode_label()),
                )?;
                Ok(0)
            }
            SlashCommand::Clear => {
                execute!(io::stdout(), Clear(ClearType::All), MoveToColumn(0))?;
                self.print_intro()?;
                Ok(0)
            }
            SlashCommand::History => {
                self.print_history()?;
                Ok(0)
            }
            SlashCommand::Runs => {
                self.run_backend_command("runs", self.session.command_args("runs"))
            }
            SlashCommand::Status => {
                self.run_backend_command("status", self.session.command_args("status"))
            }
            SlashCommand::Doctor => {
                self.run_backend_command("doctor", self.session.command_args("doctor"))
            }
            SlashCommand::Model => {
                self.run_backend_command("model", self.session.command_args("model"))
            }
            SlashCommand::Goal { prompt } => {
                self.session.set_interaction_mode(InteractionMode::Goal);
                self.print_mode()?;
                if let Some(prompt) = prompt.filter(|value| !value.trim().is_empty()) {
                    self.run_prompt(prompt.trim())
                } else {
                    Ok(0)
                }
            }
            SlashCommand::Build => {
                self.session.set_interaction_mode(InteractionMode::Build);
                self.print_mode()?;
                Ok(0)
            }
            SlashCommand::Diff { view } => {
                self.run_backend_command("diff", self.session.diff_args(view))
            }
            SlashCommand::Logs { run_ref, view } => {
                self.run_backend_command("logs", self.session.logs_args(run_ref.as_deref(), view))
            }
            SlashCommand::Resume { run_ref } => {
                let run_ref = run_ref.as_deref().unwrap_or("latest");
                Ok(run_streamed_turn(
                    self.session.resume_args(run_ref),
                    true,
                    self.session.workspace_root(),
                )?
                .code)
            }
            SlashCommand::Fork { run_ref } => {
                let run_ref = run_ref.as_deref().unwrap_or("latest");
                Ok(run_streamed_turn(
                    self.session.fork_args(run_ref),
                    true,
                    self.session.workspace_root(),
                )?
                .code)
            }
            SlashCommand::Exit => Ok(0),
        }
    }

    fn run_backend_command(&self, label: &str, args: Vec<String>) -> Result<i32> {
        let output = run_with_spinner(label, args)?;
        let code = output.code;
        self.print_backend_output(output)?;
        Ok(code)
    }

    fn print_intro(&self) -> Result<()> {
        let workspace = self.session.workspace_root();
        let mode = self.session.permission_mode_label();

        print_tone(Tone::Accent, "Holt")?;
        print_tone(
            Tone::Dim,
            &format!(
                "workspace {} · {} mode · {mode}",
                workspace.display(),
                self.session.interaction_mode_label()
            ),
        )?;
        print_tone(Tone::Dim, "type /help for commands · /exit to quit")?;
        println!();
        Ok(())
    }

    fn print_mode(&self) -> Result<()> {
        print_tone(
            Tone::Plain,
            &format!("Mode: {}", self.session.interaction_mode_label()),
        )
    }

    fn run_prompt(&mut self, input: &str) -> Result<i32> {
        let chat_messages = self.recent_chat_messages();
        let _ = history::remember_prompt(&mut self.history, &self.session.workspace_root(), input);
        self.chat_messages.push(ChatMessage::user(input));
        let outcome = run_streamed_turn(
            self.session.turn_run_args(input, &chat_messages),
            true,
            self.session.workspace_root(),
        )?;
        let code = outcome.code;

        if code == 0 {
            if let Some(answer) = outcome.answer {
                self.chat_messages.push(ChatMessage::assistant(answer));
            }
        }

        if code != 0 {
            print_tone(Tone::Error, &format!("Holt finished with code {code}"))?;
            println!();
        }

        Ok(code)
    }

    fn print_backend_output(&self, output: backend::BackendOutput) -> Result<()> {
        if output.code == 0 {
            if !output.stdout.trim().is_empty() {
                print_markdown(output.stdout.trim(), Some(&self.session.workspace_root()))?;
            }

            if !output.stderr.trim().is_empty() {
                print_tone(Tone::Dim, output.stderr.trim())?;
            }
        } else {
            print_tone(
                Tone::Error,
                &format!("Holt finished with code {}", output.code),
            )?;

            if !output.stderr.trim().is_empty() {
                print_tone(Tone::Error, output.stderr.trim())?;
            }

            if !output.stdout.trim().is_empty() {
                print_markdown(output.stdout.trim(), Some(&self.session.workspace_root()))?;
            }
        }

        println!();
        Ok(())
    }

    fn print_history(&self) -> Result<()> {
        if self.history.is_empty() {
            print_tone(Tone::Dim, "no project prompt history yet")?;
            return Ok(());
        }

        for row in history::recent_prompt_rows(&self.history, history::HISTORY_DISPLAY_LIMIT) {
            print_tone(Tone::Plain, &row)?;
        }

        Ok(())
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

enum PromptResult {
    Line(String),
    Eof,
    Interrupt,
}

fn read_prompt(prompt: &str, history: &[String]) -> Result<PromptResult> {
    let terminal_state = PromptTerminalState::current();

    if let Some(output) = prompt_interactive_output(terminal_state) {
        read_prompt_interactive(prompt, history, output)
    } else {
        read_prompt_line(prompt, history)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct PromptTerminalState {
    stdin: bool,
    stdout: bool,
    stderr: bool,
    ci: bool,
}

impl PromptTerminalState {
    fn current() -> Self {
        Self {
            stdin: io::stdin().is_terminal(),
            stdout: io::stdout().is_terminal(),
            stderr: io::stderr().is_terminal(),
            ci: std::env::var("CI").is_ok(),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum PromptOutput {
    Stdout,
    Stderr,
}

fn prompt_interactive_output(state: PromptTerminalState) -> Option<PromptOutput> {
    if state.ci || !state.stdin {
        return None;
    }

    if state.stdout {
        Some(PromptOutput::Stdout)
    } else if state.stderr {
        Some(PromptOutput::Stderr)
    } else {
        None
    }
}

fn read_prompt_line(prompt: &str, history: &[String]) -> Result<PromptResult> {
    print_tone_inline(Tone::User, prompt)?;
    io::stdout().flush()?;

    let mut line = String::new();
    let bytes = io::stdin()
        .read_line(&mut line)
        .context("failed to read terminal input")?;

    if bytes == 0 {
        return Ok(PromptResult::Eof);
    }

    while matches!(line.chars().last(), Some('\n' | '\r')) {
        line.pop();
    }

    Ok(PromptResult::Line(apply_line_mode_control_sequences(
        &line, history,
    )))
}

fn read_prompt_interactive(
    prompt: &str,
    history: &[String],
    output: PromptOutput,
) -> Result<PromptResult> {
    let _guard = InlineRawModeGuard::enter()?;
    let mut state = PromptState::default();

    render_prompt_line(prompt, &state, output)?;

    loop {
        match event::read().context("failed to read terminal event")? {
            Event::Key(key) => match handle_prompt_key(&mut state, history, key)? {
                PromptKeyResult::Continue => render_prompt_line(prompt, &state, output)?,
                PromptKeyResult::Submit => {
                    finish_prompt_line(output)?;
                    return Ok(PromptResult::Line(state.input));
                }
                PromptKeyResult::Eof => return Ok(PromptResult::Eof),
                PromptKeyResult::Interrupt => return Ok(PromptResult::Interrupt),
            },
            Event::Resize(_, _) => render_prompt_line(prompt, &state, output)?,
            _ => {}
        }
    }
}

fn handle_prompt_key(
    state: &mut PromptState,
    history: &[String],
    key: KeyEvent,
) -> Result<PromptKeyResult> {
    match (key.code, key.modifiers) {
        (KeyCode::Enter, _) => Ok(PromptKeyResult::Submit),
        (KeyCode::Char('c'), modifiers) if modifiers.contains(KeyModifiers::CONTROL) => {
            Ok(PromptKeyResult::Interrupt)
        }
        (KeyCode::Char('d'), modifiers)
            if modifiers.contains(KeyModifiers::CONTROL) && state.input.is_empty() =>
        {
            Ok(PromptKeyResult::Eof)
        }
        (KeyCode::Char('a'), modifiers) if modifiers.contains(KeyModifiers::CONTROL) => {
            state.move_home();
            Ok(PromptKeyResult::Continue)
        }
        (KeyCode::Char('e'), modifiers) if modifiers.contains(KeyModifiers::CONTROL) => {
            state.move_end();
            Ok(PromptKeyResult::Continue)
        }
        (KeyCode::Char('r'), modifiers) if modifiers.contains(KeyModifiers::CONTROL) => {
            state.search_history(history);
            Ok(PromptKeyResult::Continue)
        }
        (KeyCode::Char('u'), modifiers) if modifiers.contains(KeyModifiers::CONTROL) => {
            state.kill_before_cursor();
            Ok(PromptKeyResult::Continue)
        }
        (KeyCode::Char('k'), modifiers) if modifiers.contains(KeyModifiers::CONTROL) => {
            state.kill_after_cursor();
            Ok(PromptKeyResult::Continue)
        }
        (KeyCode::Char('w'), modifiers) if modifiers.contains(KeyModifiers::CONTROL) => {
            state.delete_word_before_cursor();
            Ok(PromptKeyResult::Continue)
        }
        (KeyCode::Tab, _) => {
            state.complete_slash_command();
            Ok(PromptKeyResult::Continue)
        }
        (KeyCode::Char(ch), modifiers)
            if !modifiers.contains(KeyModifiers::CONTROL)
                && !modifiers.contains(KeyModifiers::ALT) =>
        {
            state.insert(ch);
            Ok(PromptKeyResult::Continue)
        }
        (KeyCode::Backspace, _) => {
            state.backspace();
            Ok(PromptKeyResult::Continue)
        }
        (KeyCode::Delete, _) => {
            state.delete();
            Ok(PromptKeyResult::Continue)
        }
        (KeyCode::Left, _) => {
            state.move_left();
            Ok(PromptKeyResult::Continue)
        }
        (KeyCode::Right, _) => {
            state.move_right();
            Ok(PromptKeyResult::Continue)
        }
        (KeyCode::Home, _) => {
            state.move_home();
            Ok(PromptKeyResult::Continue)
        }
        (KeyCode::End, _) => {
            state.move_end();
            Ok(PromptKeyResult::Continue)
        }
        (KeyCode::Up, _) => {
            state.recall_history(history, -1);
            Ok(PromptKeyResult::Continue)
        }
        (KeyCode::Down, _) => {
            state.recall_history(history, 1);
            Ok(PromptKeyResult::Continue)
        }
        _ => Ok(PromptKeyResult::Continue),
    }
}

enum PromptKeyResult {
    Continue,
    Submit,
    Eof,
    Interrupt,
}

fn apply_line_mode_control_sequences(input: &str, history: &[String]) -> String {
    if !input.contains('\u{1b}') {
        return input.to_string();
    }

    let mut state = PromptState::default();
    let chars = input.chars().collect::<Vec<_>>();
    let mut index = 0;

    while index < chars.len() {
        if chars[index] == '\u{1b}' {
            if let Some(consumed) =
                apply_line_mode_escape_sequence(&mut state, history, &chars[index..])
            {
                index += consumed;
                continue;
            }

            index += 1;
            continue;
        }

        state.insert(chars[index]);
        index += 1;
    }

    state.input
}

fn apply_line_mode_escape_sequence(
    state: &mut PromptState,
    history: &[String],
    chars: &[char],
) -> Option<usize> {
    if chars.len() < 3 {
        return None;
    }

    match (chars[1], chars[2]) {
        ('[', 'A') | ('O', 'A') => state.recall_history(history, -1),
        ('[', 'B') | ('O', 'B') => state.recall_history(history, 1),
        ('[', 'C') | ('O', 'C') => state.move_right(),
        ('[', 'D') | ('O', 'D') => state.move_left(),
        _ => return None,
    }

    Some(3)
}

#[derive(Default)]
struct PromptState {
    input: String,
    cursor: usize,
    history_cursor: Option<usize>,
    history_search: Option<PromptHistorySearch>,
    draft: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct PromptHistorySearch {
    query: String,
    cursor: Option<usize>,
}

impl PromptState {
    fn insert(&mut self, ch: char) {
        let index = byte_index(&self.input, self.cursor);
        self.input.insert(index, ch);
        self.cursor += 1;
        self.reset_history();
    }

    fn backspace(&mut self) {
        if self.cursor == 0 {
            return;
        }

        let start = byte_index(&self.input, self.cursor - 1);
        let end = byte_index(&self.input, self.cursor);
        self.input.replace_range(start..end, "");
        self.cursor -= 1;
        self.reset_history();
    }

    fn delete(&mut self) {
        if self.cursor >= self.input.chars().count() {
            return;
        }

        let start = byte_index(&self.input, self.cursor);
        let end = byte_index(&self.input, self.cursor + 1);
        self.input.replace_range(start..end, "");
        self.reset_history();
    }

    fn kill_before_cursor(&mut self) {
        let end = byte_index(&self.input, self.cursor);
        self.input.replace_range(0..end, "");
        self.cursor = 0;
        self.reset_history();
    }

    fn kill_after_cursor(&mut self) {
        let start = byte_index(&self.input, self.cursor);
        self.input.truncate(start);
        self.reset_history();
    }

    fn delete_word_before_cursor(&mut self) {
        if self.cursor == 0 {
            return;
        }

        let chars = self.input.chars().collect::<Vec<_>>();
        let mut start = self.cursor;

        while start > 0 && chars[start - 1].is_whitespace() {
            start -= 1;
        }

        while start > 0 && !chars[start - 1].is_whitespace() {
            start -= 1;
        }

        let byte_start = byte_index(&self.input, start);
        let byte_end = byte_index(&self.input, self.cursor);
        self.input.replace_range(byte_start..byte_end, "");
        self.cursor = start;
        self.reset_history();
    }

    fn move_left(&mut self) {
        self.cursor = self.cursor.saturating_sub(1);
    }

    fn move_right(&mut self) {
        self.cursor = (self.cursor + 1).min(self.input.chars().count());
    }

    fn move_home(&mut self) {
        self.cursor = 0;
    }

    fn move_end(&mut self) {
        self.cursor = self.input.chars().count();
    }

    fn recall_history(&mut self, history: &[String], delta: isize) {
        if history.is_empty() {
            return;
        }

        if self.history_cursor.is_none() && delta > 0 {
            return;
        }

        if self.history_cursor.is_none() && delta < 0 {
            self.draft = self.input.clone();
        }

        let current = self.history_cursor.unwrap_or(history.len());
        let next = if delta < 0 {
            if current == 0 {
                history.len() - 1
            } else {
                current - 1
            }
        } else {
            (current + 1).min(history.len())
        };

        if next >= history.len() {
            self.input = self.draft.clone();
            self.cursor = self.input.chars().count();
            self.history_cursor = None;
        } else {
            self.input = history[next].clone();
            self.cursor = self.input.chars().count();
            self.history_cursor = Some(next);
        }

        self.history_search = None;
    }

    fn search_history(&mut self, history: &[String]) {
        let query = self
            .history_search
            .as_ref()
            .map(|search| search.query.clone())
            .unwrap_or_else(|| self.input.clone());
        let before = self
            .history_search
            .as_ref()
            .and_then(|search| search.cursor);

        let Some(index) = history::previous_prompt_match(history, &query, before) else {
            return;
        };

        self.input = history[index].clone();
        self.cursor = self.input.chars().count();
        self.history_cursor = None;
        self.history_search = Some(PromptHistorySearch {
            query,
            cursor: Some(index),
        });
    }

    fn complete_slash_command(&mut self) {
        let Some(completed) = commands::complete(&self.input) else {
            return;
        };

        self.input = completed;
        self.cursor = self.input.chars().count();
        self.reset_history();
    }

    fn reset_history(&mut self) {
        self.history_cursor = None;
        self.history_search = None;
        self.draft.clear();
    }
}

fn byte_index(text: &str, char_index: usize) -> usize {
    text.char_indices()
        .nth(char_index)
        .map(|(index, _)| index)
        .unwrap_or_else(|| text.len())
}

fn render_prompt_line(prompt: &str, state: &PromptState, output: PromptOutput) -> Result<()> {
    let (_, width) = terminal_width_and_height();
    let prompt_width = prompt.chars().count();
    let available = (width as usize).saturating_sub(prompt_width).max(1);
    let (visible_input, visible_cursor) =
        visible_prompt_input(&state.input, state.cursor, available);
    let cursor_column = (prompt_width + visible_cursor).min(width.saturating_sub(1) as usize);

    match output {
        PromptOutput::Stdout => {
            let mut stdout = io::stdout();
            render_prompt_line_to(&mut stdout, prompt, &visible_input, cursor_column, true)
        }
        PromptOutput::Stderr => {
            let mut stderr = io::stderr();
            render_prompt_line_to(&mut stderr, prompt, &visible_input, cursor_column, true)
        }
    }
}

fn render_prompt_line_to(
    writer: &mut impl Write,
    prompt: &str,
    visible_input: &str,
    cursor_column: usize,
    allow_color: bool,
) -> Result<()> {
    if allow_color && std::env::var_os("NO_COLOR").is_none() {
        queue!(
            writer,
            MoveToColumn(0),
            Clear(ClearType::CurrentLine),
            SetForegroundColor(ratatui_to_crossterm_color(ui::color(Tone::User))),
            Print(prompt),
            Print(visible_input),
            ResetColor,
            MoveToColumn(cursor_column as u16)
        )?;
    } else {
        queue!(
            writer,
            MoveToColumn(0),
            Clear(ClearType::CurrentLine),
            Print(prompt),
            Print(visible_input),
            MoveToColumn(cursor_column as u16)
        )?;
    }

    writer.flush()?;
    Ok(())
}

fn visible_prompt_input(input: &str, cursor: usize, available: usize) -> (String, usize) {
    let chars = input.chars().collect::<Vec<_>>();

    if chars.len() <= available {
        return (input.to_string(), cursor.min(chars.len()));
    }

    let start = cursor
        .saturating_sub(available.saturating_sub(1))
        .min(chars.len().saturating_sub(available));
    let end = (start + available).min(chars.len());
    let visible = chars[start..end].iter().collect::<String>();
    let visible_cursor = cursor.saturating_sub(start).min(available);

    (visible, visible_cursor)
}

fn finish_prompt_line(output: PromptOutput) -> Result<()> {
    match output {
        PromptOutput::Stdout => {
            let mut stdout = io::stdout();
            finish_prompt_line_to(&mut stdout)
        }
        PromptOutput::Stderr => {
            let mut stderr = io::stderr();
            finish_prompt_line_to(&mut stderr)
        }
    }
}

fn finish_prompt_line_to(writer: &mut impl Write) -> Result<()> {
    queue!(writer, Print("\r\n"))?;
    writer.flush()?;
    Ok(())
}

struct InlineRawModeGuard;

impl InlineRawModeGuard {
    fn enter() -> Result<Self> {
        enable_raw_mode().context("failed to enable raw terminal mode")?;
        Ok(Self)
    }
}

impl Drop for InlineRawModeGuard {
    fn drop(&mut self) {
        let _ = disable_raw_mode();
    }
}

fn run_with_spinner(label: &str, args: Vec<String>) -> Result<backend::BackendOutput> {
    let (tx, rx) = mpsc::channel();

    thread::spawn(move || {
        let result = backend::capture(&args).map_err(|error| error.to_string());
        let _ = tx.send(result);
    });

    let started = Instant::now();
    let mut frame = 0usize;

    loop {
        match rx.recv_timeout(Duration::from_millis(80)) {
            Ok(Ok(output)) => {
                clear_status_line()?;
                return Ok(output);
            }
            Ok(Err(error)) => {
                clear_status_line()?;
                return Err(anyhow::anyhow!(error));
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {
                render_spinner(label, started, frame)?;
                frame = frame.wrapping_add(1);
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                clear_status_line()?;
                return Err(anyhow::anyhow!("Holt disconnected"));
            }
        }
    }
}

struct TurnOutcome {
    code: i32,
    answer: Option<String>,
}

fn run_streamed_turn(
    args: Vec<String>,
    interactive_controls: bool,
    workspace: PathBuf,
) -> Result<TurnOutcome> {
    if interactive_controls {
        let (input_tx, input_rx) = mpsc::channel();
        let mut renderer = StreamRenderer::new(Some(input_tx), workspace);

        let output =
            backend::stream_jsonl_with_input(&args, |line| renderer.handle_line(line), input_rx)?;

        renderer.finish(&output)?;
        return Ok(TurnOutcome {
            code: output.code,
            answer: renderer.answer(),
        });
    }

    let mut renderer = StreamRenderer::new(None, workspace);
    let output = backend::stream_jsonl(&args, |line| renderer.handle_line(line))?;
    renderer.finish(&output)?;
    Ok(TurnOutcome {
        code: output.code,
        answer: renderer.answer(),
    })
}

struct StreamRenderer {
    turn: TurnState,
    workspace: PathBuf,
    fallback_stdout: Vec<String>,
    fallback_stderr: Vec<String>,
    answer: String,
    answer_markdown: MarkdownStreamBuffer,
    answer_output_started: bool,
    input: Option<mpsc::Sender<backend::StreamInput>>,
    transient_status_active: bool,
    transient_status_frame: usize,
}

impl StreamRenderer {
    fn new(input: Option<mpsc::Sender<backend::StreamInput>>, workspace: PathBuf) -> Self {
        Self {
            turn: TurnState::new(),
            workspace,
            fallback_stdout: Vec::new(),
            fallback_stderr: Vec::new(),
            answer: String::new(),
            answer_markdown: MarkdownStreamBuffer::default(),
            answer_output_started: false,
            input,
            transient_status_active: false,
            transient_status_frame: 0,
        }
    }

    fn answer(&self) -> Option<String> {
        let answer = self.answer.trim();

        if answer.is_empty() {
            None
        } else {
            Some(answer.to_string())
        }
    }

    fn handle_line(&mut self, line: backend::StreamLine) -> Result<()> {
        match line {
            backend::StreamLine::Stdout(line) => self.handle_stdout(line),
            backend::StreamLine::Stderr(line) => self.handle_stderr(line),
        }
    }

    fn handle_stdout(&mut self, line: String) -> Result<()> {
        if line.trim().is_empty() {
            return Ok(());
        }

        match serde_json::from_str::<Value>(&line) {
            Ok(event) => self.handle_event(&event),
            Err(_) => {
                self.fallback_stdout.push(line.clone());
                self.clear_transient_status()?;
                print_tone(Tone::Dim, &format!("  {line}"))
            }
        }
    }

    fn handle_stderr(&mut self, line: String) -> Result<()> {
        if line.trim().is_empty() {
            return Ok(());
        }

        self.fallback_stderr.push(line.clone());
        self.clear_transient_status()?;
        print_tone(Tone::Error, &format!("  {line}"))
    }

    fn handle_event(&mut self, event: &Value) -> Result<()> {
        for action in self.turn.apply_event(event) {
            if let RenderAction::Answer { content } = &action {
                self.answer.push_str(content);
            }

            self.render_action(action)?;
        }

        Ok(())
    }

    fn finish(&mut self, output: &backend::BackendOutput) -> Result<()> {
        self.clear_transient_status()?;
        self.flush_answer_markdown()?;

        if output.code != 0 && !self.turn.completion_seen() {
            if !output.stderr.trim().is_empty() && self.fallback_stderr.is_empty() {
                print_tone(Tone::Error, output.stderr.trim())?;
            }

            if !output.stdout.trim().is_empty() && self.fallback_stdout.is_empty() {
                print_markdown(output.stdout.trim(), Some(&self.workspace))?;
            }
        }

        println!();
        Ok(())
    }

    fn render_action(&mut self, action: RenderAction) -> Result<()> {
        match action {
            RenderAction::Line { tone, text } => {
                self.clear_transient_status()?;
                print_tone(tone, &format!("  {text}"))
            }
            RenderAction::Activity {
                tone,
                text,
                detail,
                terminal,
                control,
            } => {
                if inline_transient_activity(terminal, detail.as_deref(), control.as_ref()) {
                    return self.render_transient_status(tone, &text);
                }

                self.clear_transient_status()?;
                print_tone(tone, &format!("  {text}"))?;

                if let Some(detail) = detail {
                    print_markdown(&detail, Some(&self.workspace))?;
                }

                if let Some(control) = control {
                    self.handle_control(control)?;
                }

                Ok(())
            }
            RenderAction::FileEdit { summary } => {
                self.clear_transient_status()?;
                print_tone(Tone::Dim, &format!("  {}", summary.summary_text()))?;

                if let Some(detail) = summary.detail_markdown() {
                    print_markdown(&detail, Some(&self.workspace))?;
                }

                Ok(())
            }
            RenderAction::Answer { content } => self.render_answer_markdown(&content),
            RenderAction::Footer { text } => {
                self.clear_transient_status()?;
                self.flush_answer_markdown()?;
                print_tone(Tone::Dim, &format!("  {text}"))
            }
        }
    }

    fn render_answer_markdown(&mut self, content: &str) -> Result<()> {
        let Some(markdown) = self.answer_markdown.push(content) else {
            return Ok(());
        };

        self.print_answer_markdown(&markdown)
    }

    fn flush_answer_markdown(&mut self) -> Result<()> {
        let Some(markdown) = self.answer_markdown.flush() else {
            return Ok(());
        };

        self.print_answer_markdown(&markdown)
    }

    fn print_answer_markdown(&mut self, markdown: &str) -> Result<()> {
        if markdown.trim().is_empty() {
            return Ok(());
        }

        self.clear_transient_status()?;
        if !self.answer_output_started {
            println!();
            self.answer_output_started = true;
        }
        print_markdown(markdown, Some(&self.workspace))
    }

    fn render_transient_status(&mut self, tone: Tone, text: &str) -> Result<()> {
        if !io::stdout().is_terminal() {
            return Ok(());
        }

        let (_, width) = terminal_width_and_height();
        let label = activity_spinner_label(text);
        let line = format!("{} {label}", ui::spinner(self.transient_status_frame));
        self.transient_status_frame = self.transient_status_frame.wrapping_add(1);

        queue!(
            io::stdout(),
            MoveToColumn(0),
            Clear(ClearType::CurrentLine),
            SetForegroundColor(ratatui_to_crossterm_color(ui::color(tone))),
            Print(ui::truncate(&line, width as usize)),
            ResetColor
        )?;
        io::stdout().flush()?;
        self.transient_status_active = true;
        Ok(())
    }

    fn clear_transient_status(&mut self) -> Result<()> {
        if self.transient_status_active {
            clear_status_line()?;
            self.transient_status_active = false;
        }

        Ok(())
    }

    fn handle_control(&self, control: ActivityControl) -> Result<()> {
        match control {
            ActivityControl::Approval { action } => {
                let approve = read_approval_response(&action)?;
                let line = approval_input_line(approve);
                self.send_input(line)?;

                let decision = if approve { "approved" } else { "denied" };
                print_tone(
                    Tone::Dim,
                    &format!("  Approval sent: {decision} · {action}"),
                )
            }
            ActivityControl::UserInput {
                description,
                options,
                ..
            } => {
                if let Some(description) = description {
                    print_tone(Tone::Dim, &format!("    {description}"))?;
                }

                for (index, option) in options.iter().enumerate() {
                    let detail = option
                        .description
                        .as_ref()
                        .filter(|value| !value.trim().is_empty())
                        .map(|value| format!(" - {value}"))
                        .unwrap_or_default();
                    print_tone(
                        Tone::Plain,
                        &format!("    {}. {}{}", index + 1, option.label, detail),
                    )?;
                }

                let answer = read_user_input_response(&options)?;
                self.send_input(format!("{answer}\n"))?;
                Ok(())
            }
        }
    }

    fn send_input(&self, line: String) -> Result<()> {
        let input = self
            .input
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("This command cannot receive user input."))?;

        input
            .send(backend::StreamInput::Line(line))
            .map_err(|_| anyhow::anyhow!("Holt is no longer accepting user input."))
    }
}

#[derive(Default)]
struct MarkdownStreamBuffer {
    pending: String,
}

impl MarkdownStreamBuffer {
    fn push(&mut self, delta: &str) -> Option<String> {
        self.pending.push_str(delta);
        let boundary = find_stream_safe_boundary(&self.pending)?;
        let ready = self.pending[..boundary].to_string();
        self.pending.drain(..boundary);
        nonempty_markdown(ready)
    }

    fn flush(&mut self) -> Option<String> {
        let pending = std::mem::take(&mut self.pending);
        nonempty_markdown(pending)
    }
}

fn nonempty_markdown(markdown: String) -> Option<String> {
    if markdown.trim().is_empty() {
        None
    } else {
        Some(markdown)
    }
}

fn find_stream_safe_boundary(markdown: &str) -> Option<usize> {
    let mut open_fence: Option<StreamFenceLine> = None;
    let mut nested_fence_depth = 0usize;
    let mut last_boundary = None;
    let mut offset = 0usize;

    for raw_line in markdown.split_inclusive('\n') {
        let start = offset;
        offset += raw_line.len();
        let line = line_body_without_ending(raw_line);

        if let Some(opener) = open_fence {
            if let Some(candidate) = parse_stream_fence_line(line) {
                if candidate.ch == opener.ch && candidate.len >= opener.len {
                    if candidate.has_info {
                        nested_fence_depth += 1;
                        continue;
                    }

                    if nested_fence_depth > 0 {
                        nested_fence_depth -= 1;
                        continue;
                    }

                    open_fence = None;
                    last_boundary = Some(start + raw_line.len());
                }
            }
            continue;
        }

        if let Some(opener) = parse_stream_fence_line(line) {
            open_fence = Some(opener);
            nested_fence_depth = 0;
            continue;
        }

        if line.trim().is_empty() {
            last_boundary = Some(start + raw_line.len());
        }
    }

    last_boundary.filter(|boundary| *boundary <= markdown.len())
}

#[derive(Clone, Copy)]
struct StreamFenceLine {
    ch: char,
    len: usize,
    has_info: bool,
}

fn parse_stream_fence_line(line: &str) -> Option<StreamFenceLine> {
    let indent = line.chars().take_while(|ch| *ch == ' ').count();
    if indent > 3 {
        return None;
    }

    let rest = &line[indent..];
    let ch = rest.chars().next()?;
    if ch != '`' && ch != '~' {
        return None;
    }

    let len = rest
        .chars()
        .take_while(|candidate| *candidate == ch)
        .count();
    if len < 3 {
        return None;
    }

    let after = &rest[len..];
    if ch == '`' && after.contains('`') {
        return None;
    }

    Some(StreamFenceLine {
        ch,
        len,
        has_info: !after.trim().is_empty(),
    })
}

fn line_body_without_ending(line: &str) -> &str {
    let body = line.strip_suffix('\n').unwrap_or(line);
    body.strip_suffix('\r').unwrap_or(body)
}

fn read_approval_response(action: &str) -> Result<bool> {
    loop {
        match read_prompt(&format!("  Approve {action}? [y/n] "), &[])? {
            PromptResult::Line(answer) => {
                if let Some(approve) = parse_approval_answer(&answer) {
                    return Ok(approve);
                }

                print_tone(Tone::Warning, "  Type y to approve or n to deny.")?;
            }
            PromptResult::Eof | PromptResult::Interrupt => return Ok(false),
        }
    }
}

fn read_user_input_response(options: &[QuestionOption]) -> Result<String> {
    loop {
        match read_prompt("  › ", &[])? {
            PromptResult::Line(answer) => {
                if let Some(answer) = resolve_user_input_answer(&answer, options) {
                    return Ok(answer);
                }

                if options.is_empty() {
                    print_tone(Tone::Warning, "  Type an answer before pressing Enter.")?;
                } else {
                    print_tone(Tone::Warning, "  Choose an option number or type a value.")?;
                }
            }
            PromptResult::Eof | PromptResult::Interrupt => return Ok(String::new()),
        }
    }
}

fn parse_approval_answer(answer: &str) -> Option<bool> {
    match answer.trim().to_ascii_lowercase().as_str() {
        "y" | "yes" => Some(true),
        "n" | "no" => Some(false),
        _ => None,
    }
}

fn approval_input_line(approve: bool) -> String {
    if approve {
        "y\n".to_string()
    } else {
        "n\n".to_string()
    }
}

fn resolve_user_input_answer(answer: &str, options: &[QuestionOption]) -> Option<String> {
    let answer = answer.trim();

    if answer.is_empty() {
        return None;
    }

    if let Ok(index) = answer.parse::<usize>() {
        if index > 0 {
            if let Some(option) = options.get(index - 1) {
                return Some(option.value.clone());
            }
        }
    }

    Some(answer.to_string())
}

fn render_spinner(label: &str, started: Instant, frame: usize) -> Result<()> {
    if !io::stdout().is_terminal() {
        return Ok(());
    }

    let (_, width) = terminal_width_and_height();
    let elapsed = started.elapsed().as_secs_f32();
    let text = format!(
        "{} {} {label} {:.1}s",
        ui::spinner(frame),
        ui::ripple(frame, 14),
        elapsed
    );

    queue!(
        io::stdout(),
        MoveToColumn(0),
        Clear(ClearType::CurrentLine),
        SetForegroundColor(ratatui_to_crossterm_color(ui::color(Tone::Warning))),
        Print(ui::truncate(&text, width as usize)),
        ResetColor
    )?;
    io::stdout().flush()?;
    Ok(())
}

fn clear_status_line() -> Result<()> {
    if !io::stdout().is_terminal() {
        return Ok(());
    }

    execute!(io::stdout(), MoveToColumn(0), Clear(ClearType::CurrentLine))?;
    Ok(())
}

fn inline_transient_activity(
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

fn print_help() -> Result<()> {
    for command in SLASH_COMMANDS {
        print_tone(
            Tone::Plain,
            &format!("{:<18} {}", command.usage, command.description),
        )?;
    }

    Ok(())
}

fn print_keymap(workspace: &Path) -> Result<()> {
    let keymap = match keymap::load(workspace) {
        Ok(keymap) => keymap,
        Err(error) => {
            print_tone(Tone::Error, &format!("Keymap config error: {error}"))?;
            keymap::Keymap::default()
        }
    };

    for row in keymap::formatted_rows(KEY_BINDINGS, &keymap) {
        print_tone(Tone::Plain, &row)?;
    }

    Ok(())
}

fn print_markdown(text: &str, cwd: Option<&Path>) -> Result<()> {
    let (_, width) = terminal_width_and_height();

    for line in ui::markdown_lines_with_cwd(text, width as usize, cwd) {
        if line.text.is_empty() {
            println!();
        } else if line.spans.is_empty() {
            print_tone(line.tone, &format!("  {}", line.text))?;
        } else {
            print_tone_inline(line.tone, "  ")?;
            for span in line.spans {
                print_color_inline(span.color(), &span.text)?;
            }
            println!();
        }
    }

    Ok(())
}

fn print_tone(tone: Tone, text: &str) -> Result<()> {
    print_tone_inline(tone, text)?;
    println!();
    Ok(())
}

fn print_tone_inline(tone: Tone, text: &str) -> Result<()> {
    print_color_inline(ui::color(tone), text)
}

fn print_color_inline(color: RatColor, text: &str) -> Result<()> {
    if color_enabled() {
        queue!(
            io::stdout(),
            SetForegroundColor(ratatui_to_crossterm_color(color)),
            Print(text),
            ResetColor
        )?;
    } else {
        queue!(io::stdout(), Print(text))?;
    }

    io::stdout().flush()?;
    Ok(())
}

fn ratatui_to_crossterm_color(color: RatColor) -> CrosstermColor {
    match color {
        RatColor::Reset => CrosstermColor::Reset,
        RatColor::Black => CrosstermColor::Black,
        RatColor::Red | RatColor::LightRed => CrosstermColor::Red,
        RatColor::Green | RatColor::LightGreen => CrosstermColor::Green,
        RatColor::Yellow | RatColor::LightYellow => CrosstermColor::Yellow,
        RatColor::Blue | RatColor::LightBlue => CrosstermColor::Blue,
        RatColor::Magenta | RatColor::LightMagenta => CrosstermColor::Magenta,
        RatColor::Cyan | RatColor::LightCyan => CrosstermColor::Cyan,
        RatColor::Gray => CrosstermColor::Grey,
        RatColor::DarkGray => CrosstermColor::DarkGrey,
        RatColor::White => CrosstermColor::White,
        RatColor::Indexed(value) => CrosstermColor::AnsiValue(value),
        RatColor::Rgb(r, g, b) => CrosstermColor::Rgb { r, g, b },
    }
}

fn color_enabled() -> bool {
    io::stdout().is_terminal() && std::env::var_os("NO_COLOR").is_none()
}

fn terminal_width_and_height() -> (u16, u16) {
    let (width, height) = terminal::terminal_size();
    (height, width.max(60))
}

#[cfg(test)]
mod tests {
    use super::{
        activity_spinner_label, apply_line_mode_control_sequences, approval_input_line,
        handle_prompt_key, inline_transient_activity, parse_approval_answer,
        prompt_interactive_output, resolve_user_input_answer, visible_prompt_input, InlineApp,
        MarkdownStreamBuffer, PromptOutput, PromptState, PromptTerminalState,
    };
    use crate::turn::{ActivityControl, QuestionOption};
    use crate::{history, tui::ChatArgs};
    use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
    use std::{
        fs,
        path::PathBuf,
        time::{SystemTime, UNIX_EPOCH},
    };

    #[test]
    fn prompt_history_up_down_cycles_previous_user_messages() {
        let history = vec![
            "first request".to_string(),
            "second request".to_string(),
            "third request".to_string(),
        ];
        let mut state = PromptState::default();

        state.recall_history(&history, -1);
        assert_eq!(state.input, "third request");

        state.recall_history(&history, -1);
        assert_eq!(state.input, "second request");

        state.recall_history(&history, -1);
        assert_eq!(state.input, "first request");

        state.recall_history(&history, -1);
        assert_eq!(state.input, "third request");

        state.recall_history(&history, 1);
        assert_eq!(state.input, "");

        state.recall_history(&history, 1);
        assert_eq!(state.input, "");

        state.recall_history(&history, 1);
        assert_eq!(state.input, "");
    }

    #[test]
    fn prompt_key_events_drive_history_navigation() {
        let history = vec!["first".to_string(), "second".to_string()];
        let mut state = PromptState::default();

        handle_prompt_key(
            &mut state,
            &history,
            KeyEvent::new(KeyCode::Up, KeyModifiers::NONE),
        )
        .unwrap();
        assert_eq!(state.input, "second");

        handle_prompt_key(
            &mut state,
            &history,
            KeyEvent::new(KeyCode::Up, KeyModifiers::NONE),
        )
        .unwrap();
        assert_eq!(state.input, "first");

        handle_prompt_key(
            &mut state,
            &history,
            KeyEvent::new(KeyCode::Down, KeyModifiers::NONE),
        )
        .unwrap();
        assert_eq!(state.input, "second");
    }

    #[test]
    fn prompt_line_mode_escape_sequences_drive_history_navigation() {
        let history = vec![
            "first request".to_string(),
            "second request".to_string(),
            "third request".to_string(),
        ];

        assert_eq!(
            apply_line_mode_control_sequences("\u{1b}[A\u{1b}[A!", &history),
            "second request!"
        );
        assert_eq!(
            apply_line_mode_control_sequences("\u{1b}[A\u{1b}[Btyped", &history),
            "typed"
        );
        assert_eq!(
            apply_line_mode_control_sequences(
                "\u{1b}[A\u{1b}[A\u{1b}[B\u{1b}[C\u{1b}[A\u{1b}[D\u{1b}[A",
                &history
            ),
            "first request"
        );
    }

    #[test]
    fn prompt_line_mode_escape_sequences_do_not_leak_without_history() {
        assert_eq!(
            apply_line_mode_control_sequences("\u{1b}[Ahello\u{1b}[D!", &[]),
            "hell!o"
        );
    }

    #[test]
    fn prompt_uses_raw_history_reader_when_stderr_is_the_terminal_output() {
        assert_eq!(
            prompt_interactive_output(PromptTerminalState {
                stdin: true,
                stdout: false,
                stderr: true,
                ci: false,
            }),
            Some(PromptOutput::Stderr)
        );
    }

    #[test]
    fn prompt_stays_line_based_without_an_interactive_input_terminal() {
        assert_eq!(
            prompt_interactive_output(PromptTerminalState {
                stdin: false,
                stdout: true,
                stderr: true,
                ci: false,
            }),
            None
        );
        assert_eq!(
            prompt_interactive_output(PromptTerminalState {
                stdin: true,
                stdout: true,
                stderr: true,
                ci: true,
            }),
            None
        );
    }

    #[test]
    fn prompt_ctrl_r_searches_history_with_current_input() {
        let history = vec![
            "edit docs".to_string(),
            "run tests".to_string(),
            "show diff".to_string(),
            "edit diff renderer".to_string(),
        ];
        let mut state = PromptState::default();

        for ch in "diff".chars() {
            state.insert(ch);
        }

        handle_prompt_key(
            &mut state,
            &history,
            KeyEvent::new(KeyCode::Char('r'), KeyModifiers::CONTROL),
        )
        .unwrap();
        assert_eq!(state.input, "edit diff renderer");

        handle_prompt_key(
            &mut state,
            &history,
            KeyEvent::new(KeyCode::Char('r'), KeyModifiers::CONTROL),
        )
        .unwrap();
        assert_eq!(state.input, "show diff");

        state.insert('!');
        assert_eq!(state.history_search, None);
    }

    #[test]
    fn prompt_tab_completes_unique_slash_command_prefix() {
        let history = Vec::new();
        let mut state = PromptState::default();

        state.insert('/');
        state.insert('h');
        state.insert('e');
        handle_prompt_key(
            &mut state,
            &history,
            KeyEvent::new(KeyCode::Tab, KeyModifiers::NONE),
        )
        .unwrap();
        assert_eq!(state.input, "/help");
        assert_eq!(state.cursor, 5);

        state.input = "/r".to_string();
        state.cursor = 2;
        handle_prompt_key(
            &mut state,
            &history,
            KeyEvent::new(KeyCode::Tab, KeyModifiers::NONE),
        )
        .unwrap();
        assert_eq!(state.input, "/r");
    }

    #[test]
    fn inline_app_loads_workspace_prompt_history() {
        let workspace = temp_workspace();
        history::append_prompt(&workspace, "persisted prompt").unwrap();
        let app = InlineApp::new(ChatArgs::parse(vec![
            "--workspace".to_string(),
            workspace.display().to_string(),
        ]));

        assert_eq!(app.history, vec!["persisted prompt".to_string()]);
        let _ = fs::remove_dir_all(workspace);
    }

    #[test]
    fn prompt_history_restores_draft_after_down_past_latest_entry() {
        let history = vec!["old request".to_string()];
        let mut state = PromptState::default();

        for ch in "draft".chars() {
            state.insert(ch);
        }

        state.recall_history(&history, -1);
        assert_eq!(state.input, "old request");

        state.recall_history(&history, 1);
        assert_eq!(state.input, "draft");
        assert_eq!(state.cursor, 5);
    }

    #[test]
    fn prompt_editing_resets_history_navigation() {
        let history = vec!["old request".to_string()];
        let mut state = PromptState::default();

        state.recall_history(&history, -1);
        assert_eq!(state.input, "old request");

        state.insert('!');
        assert_eq!(state.input, "old request!");

        state.recall_history(&history, 1);
        assert_eq!(state.input, "old request!");
    }

    #[test]
    fn prompt_state_edits_at_cursor() {
        let mut state = PromptState::default();

        for ch in "helo".chars() {
            state.insert(ch);
        }

        state.move_left();
        state.insert('l');
        assert_eq!(state.input, "hello");

        state.backspace();
        assert_eq!(state.input, "helo");

        state.move_right();
        state.move_left();
        state.delete();
        assert_eq!(state.input, "hel");
    }

    #[test]
    fn prompt_key_events_support_readline_shortcuts() {
        let history = Vec::new();
        let mut state = PromptState::default();

        for ch in "hello world again".chars() {
            state.insert(ch);
        }
        state.cursor = 11;

        handle_prompt_key(
            &mut state,
            &history,
            KeyEvent::new(KeyCode::Char('a'), KeyModifiers::CONTROL),
        )
        .unwrap();
        assert_eq!(state.cursor, 0);

        handle_prompt_key(
            &mut state,
            &history,
            KeyEvent::new(KeyCode::Char('e'), KeyModifiers::CONTROL),
        )
        .unwrap();
        assert_eq!(state.cursor, 17);

        handle_prompt_key(
            &mut state,
            &history,
            KeyEvent::new(KeyCode::Char('w'), KeyModifiers::CONTROL),
        )
        .unwrap();
        assert_eq!(state.input, "hello world ");
        assert_eq!(state.cursor, 12);

        handle_prompt_key(
            &mut state,
            &history,
            KeyEvent::new(KeyCode::Char('u'), KeyModifiers::CONTROL),
        )
        .unwrap();
        assert_eq!(state.input, "");
        assert_eq!(state.cursor, 0);

        for ch in "hello world again".chars() {
            state.insert(ch);
        }
        state.cursor = 5;
        handle_prompt_key(
            &mut state,
            &history,
            KeyEvent::new(KeyCode::Char('k'), KeyModifiers::CONTROL),
        )
        .unwrap();
        assert_eq!(state.input, "hello");
        assert_eq!(state.cursor, 5);
    }

    #[test]
    fn visible_prompt_input_keeps_cursor_in_view() {
        assert_eq!(
            visible_prompt_input("abcdefghijklmnopqrstuvwxyz", 26, 8),
            ("stuvwxyz".to_string(), 8)
        );
        assert_eq!(
            visible_prompt_input("abcdefghijklmnopqrstuvwxyz", 3, 8),
            ("abcdefgh".to_string(), 3)
        );
    }

    #[test]
    fn inline_approval_answers_use_backend_stdin_contract() {
        assert_eq!(parse_approval_answer("y"), Some(true));
        assert_eq!(parse_approval_answer("YES"), Some(true));
        assert_eq!(parse_approval_answer("n"), Some(false));
        assert_eq!(parse_approval_answer("later"), None);
        assert_eq!(approval_input_line(true), "y\n");
        assert_eq!(approval_input_line(false), "n\n");
    }

    #[test]
    fn inline_user_input_resolves_option_numbers_to_values() {
        let options = vec![
            QuestionOption {
                label: "Build".to_string(),
                value: "build".to_string(),
                description: Some("Run the build".to_string()),
            },
            QuestionOption {
                label: "Skip".to_string(),
                value: "skip".to_string(),
                description: None,
            },
        ];

        assert_eq!(
            resolve_user_input_answer("1", &options),
            Some("build".to_string())
        );
        assert_eq!(
            resolve_user_input_answer("2", &options),
            Some("skip".to_string())
        );
        assert_eq!(
            resolve_user_input_answer("custom answer", &options),
            Some("custom answer".to_string())
        );
        assert_eq!(resolve_user_input_answer("", &options), None);
    }

    #[test]
    fn inline_nonterminal_activity_is_transient_status_only() {
        assert!(inline_transient_activity(false, None, None));
        assert!(inline_transient_activity(false, Some(""), None));
        assert!(!inline_transient_activity(true, None, None));
        assert!(!inline_transient_activity(false, Some("input: path"), None));
        assert!(!inline_transient_activity(
            false,
            None,
            Some(&ActivityControl::Approval {
                action: "write".to_string()
            })
        ));
        assert_eq!(
            activity_spinner_label("◐ Reading workspace"),
            "Reading workspace"
        );
    }

    #[test]
    fn inline_markdown_stream_releases_complete_paragraphs() {
        let mut stream = MarkdownStreamBuffer::default();

        assert_eq!(
            stream.push("First paragraph\n\nSecond"),
            Some("First paragraph\n\n".to_string())
        );
        assert_eq!(stream.flush(), Some("Second".to_string()));
    }

    #[test]
    fn inline_markdown_stream_buffers_open_code_fences() {
        let mut stream = MarkdownStreamBuffer::default();

        assert_eq!(stream.push("```rust\nfn main() {}"), None);
        assert_eq!(
            stream.push("\n```\n"),
            Some("```rust\nfn main() {}\n```\n".to_string())
        );
        assert_eq!(stream.flush(), None);
    }

    #[test]
    fn inline_markdown_stream_preserves_nested_fence_examples() {
        let mut stream = MarkdownStreamBuffer::default();

        assert_eq!(
            stream.push("```markdown\n```rust\nfn nested() {}\n```\n"),
            None
        );
        assert_eq!(
            stream.push("```\n"),
            Some("```markdown\n```rust\nfn nested() {}\n```\n```\n".to_string())
        );
    }

    fn temp_workspace() -> PathBuf {
        let millis = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_millis();
        let path = std::env::temp_dir().join(format!(
            "holt-cli-inline-history-test-{}-{millis}",
            std::process::id()
        ));
        fs::create_dir_all(&path).unwrap();
        path
    }
}
