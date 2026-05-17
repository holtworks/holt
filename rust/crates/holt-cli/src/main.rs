mod backend;
mod inline;
mod terminal;
mod tui;
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
        "doctor" | "onboard" | "run" | "resume" | "status" | "logs" | "llm"
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

    if let Some(args) = session.one_shot_chat_run_args() {
        return inline::run_once(args);
    }

    if session.plain {
        return inline::run(session);
    }

    if session.force_tui && !terminal::interactive() {
        eprintln!("holt: --fullscreen requires an interactive terminal");
        return Ok(1);
    }

    if session.force_tui {
        return tui::run(session);
    }

    inline::run(session)
}

fn print_help() {
    println!(
        "Holt {VERSION}

Usage:
  holt                                    Start an interactive session
  holt \"task\"                             Ask Holt once
  holt --yes \"task\"                       Let Holt work without stopping for routine approvals
  holt --workspace path                   Start in a specific workspace
  holt --fullscreen                       Use a focused full-screen session
  holt --plain                            Use a simple line-by-line session
  holt help                               Show this help
  holt version                            Print the installed version
  holt doctor [--json]                    Check local setup
  holt onboard [--yes]                    Set up Holt in this workspace
  holt run [--yes] \"task\"                 Run a task and exit
  holt resume [--yes] [run_id]            Resume prior work
  holt status [--json]                    Show workspace status
  holt logs [--json]                      Show recent activity

Plain text after `holt` is treated as your request. Use slash commands inside
the interactive session for status, recent runs, logs, and help.
"
    );
}

#[cfg(test)]
mod tests {
    use super::{backend_command, retired_command};

    #[test]
    fn known_product_commands_are_routed_to_command_handler() {
        assert!(backend_command("run"));
        assert!(backend_command("doctor"));
        assert!(backend_command("llm"));
        assert!(!backend_command("review"));
    }

    #[test]
    fn retired_internal_commands_are_not_routed_to_backend() {
        assert!(retired_command("tasks"));
        assert!(retired_command("actions"));
        assert!(!backend_command("tasks"));
    }
}
