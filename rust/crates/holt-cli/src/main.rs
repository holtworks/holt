mod backend;
mod commands;
mod history;
mod inline;
mod keymap;
mod terminal;
#[allow(dead_code)]
mod tui;
mod tui_frame;
mod turn;
mod ui;

use anyhow::Result;

const VERSION: &str = env!("CARGO_PKG_VERSION");

fn main() {
    let code = match run(std::env::args().skip(1).collect()) {
        Ok(code) => code,
        Err(error) => {
            eprintln!("holt: {error}");
            1
        }
    };

    std::process::exit(code);
}

fn run(args: Vec<String>) -> Result<i32> {
    match args.first().map(String::as_str) {
        None => chat(Vec::new()),
        Some("help") | Some("--help") | Some("-h") => {
            print_help();
            Ok(0)
        }
        Some("version") => {
            println!("Holt {VERSION}");
            Ok(0)
        }
        Some("--version") => {
            println!("{VERSION}");
            Ok(0)
        }
        Some("chat") => chat(args[1..].to_vec()),
        Some("architecture") => {
            println!("{}", holt_core::architecture_summary());
            Ok(0)
        }
        Some(command) if retired_command(command) => {
            eprintln!(
                "holt: `{command}` is no longer a command. Use `holt \"...\"` to ask Holt to do the work."
            );
            Ok(64)
        }
        Some(command) if backend_command(command) => backend::run_passthrough(&args),
        _ => chat(args),
    }
}

fn backend_command(command: &str) -> bool {
    matches!(
        command,
        "diff"
            | "doctor"
            | "fork"
            | "goal"
            | "model"
            | "onboard"
            | "run"
            | "runs"
            | "resume"
            | "status"
            | "logs"
            | "llm"
    )
}

fn retired_command(command: &str) -> bool {
    matches!(
        command,
        "reply" | "tasks" | "actions" | "agents" | "approve" | "skills" | "memory" | "bridge"
    )
}

fn chat(args: Vec<String>) -> Result<i32> {
    let session = tui::ChatArgs::parse(args);

    if let Some(error) = session.parse_error() {
        eprintln!("holt: {error}");
        return Ok(64);
    }

    if let Some(args) = session.one_shot_chat_run_args() {
        return inline::run_once(args, session.workspace_root());
    }

    match chat_frontend(&session, terminal::interactive()) {
        ChatFrontend::Inline => inline::run(session),
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ChatFrontend {
    Inline,
}

fn chat_frontend(_session: &tui::ChatArgs, _interactive: bool) -> ChatFrontend {
    ChatFrontend::Inline
}

fn print_help() {
    println!(
        "Holt {VERSION}

Usage:
  holt                                    Start an interactive terminal session
  holt \"task\"                             Ask Holt once
  holt --yes \"task\"                       Let Holt work without stopping for routine approvals
  holt --permission-mode review \"task\"     Ask before write or command actions
  holt --permission-mode auto \"task\"       Approve write and command actions automatically
  holt --permission-mode deny \"task\"       Deny write and command actions automatically
  holt --workspace path                   Start in a specific workspace
  holt help                               Show this help
  holt version                            Print the installed version
  holt doctor [--json]                    Check local setup
  holt model [--json]                     Show configured model provider
  holt diff [--json]                      Show workspace changes
  holt onboard [--yes]                    Set up Holt in this workspace
  holt run [--yes] \"task\"                 Run a task and exit
  holt goal [--yes] \"goal\"                Start or update a goal and exit
  holt runs [--json]                      Show recent runs
  holt resume [--yes] [run_id]            Resume prior work
  holt fork [--yes] [run_id] [task]       Fork prior work into a new run
  holt status [--json]                    Show workspace status
  holt logs [--json] [run_id]             Show latest or selected run activity

Plain text after `holt` is treated as your request. Use slash commands inside
the interactive session for build/goal mode, status, recent runs, logs, and help.
"
    );
}

#[cfg(test)]
mod tests {
    use super::{backend_command, chat_frontend, retired_command, ChatFrontend};
    use crate::tui::ChatArgs;

    #[test]
    fn known_product_commands_are_routed_to_command_handler() {
        assert!(backend_command("run"));
        assert!(backend_command("runs"));
        assert!(backend_command("diff"));
        assert!(backend_command("doctor"));
        assert!(backend_command("fork"));
        assert!(backend_command("goal"));
        assert!(backend_command("model"));
        assert!(backend_command("llm"));
        assert!(!backend_command("review"));
    }

    #[test]
    fn retired_internal_commands_are_not_routed_to_backend() {
        assert!(retired_command("tasks"));
        assert!(retired_command("actions"));
        assert!(!backend_command("tasks"));
    }

    #[test]
    fn interactive_chat_defaults_to_terminal_frontend() {
        let session = ChatArgs::parse(vec![]);

        assert_eq!(chat_frontend(&session, true), ChatFrontend::Inline);
        assert_eq!(chat_frontend(&session, false), ChatFrontend::Inline);
    }

    #[test]
    fn frontend_flags_are_rejected() {
        let session = ChatArgs::parse(vec!["--plain".to_string()]);

        assert_eq!(
            session.parse_error(),
            Some("unsupported flag --plain: Holt uses the terminal session by default")
        );

        let session = ChatArgs::parse(vec!["--fullscreen".to_string()]);

        assert_eq!(
            session.parse_error(),
            Some("unsupported flag --fullscreen: Holt uses the terminal session by default")
        );

        let session = ChatArgs::parse(vec!["--tui".to_string()]);

        assert_eq!(
            session.parse_error(),
            Some("unsupported flag --tui: Holt uses the terminal session by default")
        );
    }
}
