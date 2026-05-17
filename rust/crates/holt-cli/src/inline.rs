use crate::{
    backend, terminal,
    tui::ChatArgs,
    turn::{RenderAction, TurnState},
    ui,
};
use anyhow::{Context, Result};
use crossterm::{
    cursor::MoveToColumn,
    execute, queue,
    style::{Print, ResetColor, SetForegroundColor},
    terminal::{Clear, ClearType},
};
use serde_json::Value;
use std::{
    fs,
    io::{self, IsTerminal, Write},
    path::Path,
    sync::mpsc,
    thread,
    time::{Duration, Instant},
};
use ui::Tone;

const COMMANDS: &[(&str, &str)] = &[
    ("/help", "show commands"),
    ("/status", "show workspace status"),
    ("/doctor", "check setup and provider"),
    ("/model", "show provider details"),
    ("/runs", "show recent runs"),
    ("/logs", "show latest run events"),
    ("/resume [run_id]", "rerun latest or selected run"),
    ("/history", "show prompts from this chat"),
    ("/clear", "clear terminal output"),
    ("/exit", "quit"),
];

pub fn run(session: ChatArgs) -> Result<i32> {
    let mut app = InlineApp::new(session);
    app.run()
}

pub(crate) fn run_once(args: Vec<String>) -> Result<i32> {
    run_streamed_turn(args)
}

struct InlineApp {
    session: ChatArgs,
    history: Vec<String>,
}

impl InlineApp {
    fn new(session: ChatArgs) -> Self {
        Self {
            session,
            history: Vec::new(),
        }
    }

    fn run(&mut self) -> Result<i32> {
        self.print_intro()?;

        loop {
            let Some(input) = read_prompt("› ")? else {
                println!();
                return Ok(0);
            };

            let input = input.trim().to_string();

            if input.is_empty() {
                continue;
            }

            if input == "/exit" || input == "/quit" {
                return Ok(0);
            }

            if input.starts_with('/') {
                let code = self.handle_command(&input)?;
                if code != 0 {
                    return Ok(code);
                }
                continue;
            }

            let chat_context = self.chat_context();
            self.history.push(input.clone());
            let code =
                run_streamed_turn(self.session.chat_run_args(&input, chat_context.as_deref()))?;

            if code != 0 {
                print_tone(Tone::Error, &format!("Holt finished with code {code}"))?;
                println!();
            }
        }
    }

    fn handle_command(&mut self, input: &str) -> Result<i32> {
        match input {
            "/help" => {
                print_help()?;
                Ok(0)
            }
            "/clear" => {
                execute!(io::stdout(), Clear(ClearType::All), MoveToColumn(0))?;
                self.print_intro()?;
                Ok(0)
            }
            "/history" => {
                self.print_history()?;
                Ok(0)
            }
            "/runs" => {
                self.print_runs()?;
                Ok(0)
            }
            "/status" => self.run_command("status", self.session.command_args("status")),
            "/doctor" => self.run_command("doctor", self.session.command_args("doctor")),
            "/model" => self.run_command("model", self.session.command_args("doctor")),
            "/logs" => self.run_command("logs", self.session.command_args("logs")),
            command if command.starts_with("/resume") => {
                let run_ref = command
                    .strip_prefix("/resume")
                    .map(str::trim)
                    .filter(|value| !value.is_empty())
                    .unwrap_or("latest");
                let code = run_streamed_turn(self.session.resume_args(run_ref))?;
                Ok(code)
            }
            command => {
                print_tone(Tone::Error, &format!("unknown command: {command}"))?;
                print_tone(Tone::Dim, "run /help for available commands")?;
                Ok(0)
            }
        }
    }

    fn run_command(&self, label: &str, args: Vec<String>) -> Result<i32> {
        let output = run_with_spinner(label, args)?;
        let code = output.code;
        self.print_backend_output(output)?;
        Ok(code)
    }

    fn print_intro(&self) -> Result<()> {
        let workspace = self.session.workspace_root();
        let mode = if self.session.yes {
            "auto-approve"
        } else {
            "review writes"
        };

        print_tone(Tone::Accent, "Holt")?;
        print_tone(
            Tone::Dim,
            &format!("workspace {} · {mode}", workspace.display()),
        )?;
        print_tone(Tone::Dim, "type /help for commands · /exit to quit")?;
        println!();
        Ok(())
    }

    fn print_backend_output(&self, output: backend::BackendOutput) -> Result<()> {
        if output.code == 0 {
            if !output.stdout.trim().is_empty() {
                print_markdown(output.stdout.trim())?;
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
                print_markdown(output.stdout.trim())?;
            }
        }

        println!();
        Ok(())
    }

    fn print_history(&self) -> Result<()> {
        if self.history.is_empty() {
            print_tone(Tone::Dim, "no prompts in this chat yet")?;
            return Ok(());
        }

        for (index, prompt) in self.history.iter().enumerate() {
            print_tone(Tone::Plain, &format!("{:>2}. {prompt}", index + 1))?;
        }

        Ok(())
    }

    fn print_runs(&self) -> Result<()> {
        let rows = read_runs(&self.session.workspace_root())?;

        if rows.is_empty() {
            print_tone(Tone::Dim, "no runs yet")?;
        } else {
            for row in rows {
                print_tone(Tone::Plain, &row)?;
            }
        }

        Ok(())
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

fn read_prompt(prompt: &str) -> Result<Option<String>> {
    print_tone_inline(Tone::User, prompt)?;
    io::stdout().flush()?;

    let mut line = String::new();
    let bytes = io::stdin()
        .read_line(&mut line)
        .context("failed to read terminal input")?;

    if bytes == 0 {
        return Ok(None);
    }

    while matches!(line.chars().last(), Some('\n' | '\r')) {
        line.pop();
    }

    Ok(Some(line))
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

fn run_streamed_turn(args: Vec<String>) -> Result<i32> {
    let mut renderer = StreamRenderer::new();

    let output = backend::stream_jsonl(&args, |line| renderer.handle_line(line))?;

    renderer.finish(&output)?;
    Ok(output.code)
}

struct StreamRenderer {
    turn: TurnState,
    fallback_stdout: Vec<String>,
    fallback_stderr: Vec<String>,
}

impl StreamRenderer {
    fn new() -> Self {
        Self {
            turn: TurnState::new(),
            fallback_stdout: Vec::new(),
            fallback_stderr: Vec::new(),
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
                print_tone(Tone::Dim, &format!("  {line}"))
            }
        }
    }

    fn handle_stderr(&mut self, line: String) -> Result<()> {
        if line.trim().is_empty() {
            return Ok(());
        }

        self.fallback_stderr.push(line.clone());
        print_tone(Tone::Error, &format!("  {line}"))
    }

    fn handle_event(&mut self, event: &Value) -> Result<()> {
        for action in self.turn.apply_event(event) {
            self.render_action(action)?;
        }

        Ok(())
    }

    fn finish(&self, output: &backend::BackendOutput) -> Result<()> {
        if output.code != 0 && !self.turn.completion_seen() {
            if !output.stderr.trim().is_empty() && self.fallback_stderr.is_empty() {
                print_tone(Tone::Error, output.stderr.trim())?;
            }

            if !output.stdout.trim().is_empty() && self.fallback_stdout.is_empty() {
                print_markdown(output.stdout.trim())?;
            }
        }

        println!();
        Ok(())
    }

    fn render_action(&self, action: RenderAction) -> Result<()> {
        match action {
            RenderAction::Line { tone, text } => print_tone(tone, &format!("  {text}")),
            RenderAction::Answer { content } => {
                println!();
                print_markdown(&content)?;
                println!();
                Ok(())
            }
            RenderAction::Footer { text } => print_tone(Tone::Dim, &format!("  {text}")),
        }
    }
}

fn render_spinner(label: &str, started: Instant, frame: usize) -> Result<()> {
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
        SetForegroundColor(ui::color(Tone::Warning)),
        Print(ui::truncate(&text, width as usize)),
        ResetColor
    )?;
    io::stdout().flush()?;
    Ok(())
}

fn clear_status_line() -> Result<()> {
    execute!(io::stdout(), MoveToColumn(0), Clear(ClearType::CurrentLine))?;
    Ok(())
}

fn print_help() -> Result<()> {
    for (command, description) in COMMANDS {
        print_tone(Tone::Plain, &format!("{command:<18} {description}"))?;
    }

    Ok(())
}

fn print_markdown(text: &str) -> Result<()> {
    let (_, width) = terminal_width_and_height();

    for line in ui::markdown_lines(text, width as usize) {
        if line.text.is_empty() {
            println!();
        } else {
            print_tone(line.tone, &format!("  {}", line.text))?;
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
    if color_enabled() {
        queue!(
            io::stdout(),
            SetForegroundColor(ui::color(tone)),
            Print(text),
            ResetColor
        )?;
    } else {
        queue!(io::stdout(), Print(text))?;
    }

    io::stdout().flush()?;
    Ok(())
}

fn color_enabled() -> bool {
    io::stdout().is_terminal() && std::env::var_os("NO_COLOR").is_none()
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

fn terminal_width_and_height() -> (u16, u16) {
    let (width, height) = terminal::terminal_size();
    (height, width.max(60))
}

#[cfg(test)]
mod tests {
    use super::COMMANDS;

    #[test]
    fn command_table_has_exit_and_help() {
        let names = COMMANDS
            .iter()
            .map(|(name, _description)| *name)
            .collect::<Vec<_>>();

        assert!(names.contains(&"/help"));
        assert!(names.contains(&"/exit"));
    }
}
