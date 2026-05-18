use std::fmt;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum SlashCommand {
    Help,
    Keymap,
    Permissions {
        mode: Option<PermissionMode>,
    },
    Status,
    Doctor,
    Model,
    Goal {
        prompt: Option<String>,
    },
    Build,
    Diff {
        view: DiffView,
    },
    Runs,
    Logs {
        run_ref: Option<String>,
        view: LogView,
    },
    Resume {
        run_ref: Option<String>,
    },
    Fork {
        run_ref: Option<String>,
    },
    History,
    Clear,
    Exit,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PermissionMode {
    Review,
    Auto,
    Deny,
}

impl PermissionMode {
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "review" => Some(Self::Review),
            "auto" => Some(Self::Auto),
            "deny" => Some(Self::Deny),
            _ => None,
        }
    }

    pub fn as_flag_value(self) -> &'static str {
        match self {
            Self::Review => "review",
            Self::Auto => "auto",
            Self::Deny => "deny",
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Self::Review => "review writes",
            Self::Auto => "auto-approve",
            Self::Deny => "deny writes",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DiffView {
    Full,
    Summary,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LogView {
    Activity,
    Transcript,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct SlashCommandSpec {
    pub command: SlashCommandKind,
    pub name: &'static str,
    pub usage: &'static str,
    pub description: &'static str,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SlashCommandKind {
    Help,
    Keymap,
    Permissions,
    Status,
    Doctor,
    Model,
    Goal,
    Build,
    Diff,
    Runs,
    Logs,
    Resume,
    Fork,
    History,
    Clear,
    Exit,
}

pub const SLASH_COMMANDS: &[SlashCommandSpec] = &[
    SlashCommandSpec {
        command: SlashCommandKind::Help,
        name: "/help",
        usage: "/help",
        description: "show commands",
    },
    SlashCommandSpec {
        command: SlashCommandKind::Keymap,
        name: "/keymap",
        usage: "/keymap",
        description: "show keyboard shortcuts",
    },
    SlashCommandSpec {
        command: SlashCommandKind::Permissions,
        name: "/permissions",
        usage: "/permissions [review|auto|deny]",
        description: "show or change file and command permissions",
    },
    SlashCommandSpec {
        command: SlashCommandKind::Status,
        name: "/status",
        usage: "/status",
        description: "show workspace status",
    },
    SlashCommandSpec {
        command: SlashCommandKind::Doctor,
        name: "/doctor",
        usage: "/doctor",
        description: "check setup and provider",
    },
    SlashCommandSpec {
        command: SlashCommandKind::Model,
        name: "/model",
        usage: "/model",
        description: "show provider details",
    },
    SlashCommandSpec {
        command: SlashCommandKind::Goal,
        name: "/goal",
        usage: "/goal [task]",
        description: "switch to goal mode or start a goal",
    },
    SlashCommandSpec {
        command: SlashCommandKind::Build,
        name: "/build",
        usage: "/build",
        description: "switch to build mode",
    },
    SlashCommandSpec {
        command: SlashCommandKind::Diff,
        name: "/diff",
        usage: "/diff [full|summary]",
        description: "show workspace changes",
    },
    SlashCommandSpec {
        command: SlashCommandKind::Runs,
        name: "/runs",
        usage: "/runs",
        description: "show recent runs",
    },
    SlashCommandSpec {
        command: SlashCommandKind::Logs,
        name: "/logs",
        usage: "/logs [run_id] [activity|transcript]",
        description: "show latest or selected run events",
    },
    SlashCommandSpec {
        command: SlashCommandKind::Resume,
        name: "/resume",
        usage: "/resume [run_id]",
        description: "rerun latest or selected run",
    },
    SlashCommandSpec {
        command: SlashCommandKind::Fork,
        name: "/fork",
        usage: "/fork [run_id]",
        description: "fork latest or selected run",
    },
    SlashCommandSpec {
        command: SlashCommandKind::History,
        name: "/history",
        usage: "/history",
        description: "show recent project prompts",
    },
    SlashCommandSpec {
        command: SlashCommandKind::Clear,
        name: "/clear",
        usage: "/clear",
        description: "clear the transcript",
    },
    SlashCommandSpec {
        command: SlashCommandKind::Exit,
        name: "/exit",
        usage: "/exit",
        description: "quit",
    },
];

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct KeyBindingSpec {
    pub key: &'static str,
    pub scope: &'static str,
    pub description: &'static str,
}

pub const KEY_BINDINGS: &[KeyBindingSpec] = &[
    KeyBindingSpec {
        key: "Enter",
        scope: "composer",
        description: "send the current message",
    },
    KeyBindingSpec {
        key: "Shift+Enter",
        scope: "tui composer",
        description: "insert a newline",
    },
    KeyBindingSpec {
        key: "Ctrl+J",
        scope: "tui composer",
        description: "insert a newline",
    },
    KeyBindingSpec {
        key: "Tab",
        scope: "composer",
        description: "toggle build/goal mode when empty, or accept a slash command suggestion",
    },
    KeyBindingSpec {
        key: "Up / Down",
        scope: "composer",
        description: "cycle project prompt history",
    },
    KeyBindingSpec {
        key: "Ctrl+R",
        scope: "composer",
        description: "search project prompt history",
    },
    KeyBindingSpec {
        key: "Left / Right",
        scope: "composer",
        description: "move the input cursor",
    },
    KeyBindingSpec {
        key: "Home / End",
        scope: "composer",
        description: "jump to the start or end of input",
    },
    KeyBindingSpec {
        key: "Ctrl+A / Ctrl+E",
        scope: "composer",
        description: "jump to the start or end of input",
    },
    KeyBindingSpec {
        key: "Ctrl+U",
        scope: "composer",
        description: "delete before the cursor",
    },
    KeyBindingSpec {
        key: "Ctrl+K",
        scope: "composer",
        description: "delete after the cursor",
    },
    KeyBindingSpec {
        key: "Ctrl+W",
        scope: "composer",
        description: "delete the word before the cursor",
    },
    KeyBindingSpec {
        key: "Esc",
        scope: "tui",
        description: "clear input or close the runs picker",
    },
    KeyBindingSpec {
        key: "Ctrl+L",
        scope: "tui",
        description: "clear the transcript",
    },
    KeyBindingSpec {
        key: "Ctrl+D",
        scope: "global",
        description: "exit when the input is empty",
    },
    KeyBindingSpec {
        key: "Ctrl+C",
        scope: "global",
        description: "interrupt the running turn or quit the CLI",
    },
    KeyBindingSpec {
        key: "Y / N",
        scope: "approval",
        description: "approve or deny a pending action",
    },
    KeyBindingSpec {
        key: "Esc",
        scope: "tui approval",
        description: "deny a pending action",
    },
    KeyBindingSpec {
        key: "1-9",
        scope: "question",
        description: "choose a numbered option",
    },
    KeyBindingSpec {
        key: "PageUp / PageDown",
        scope: "tui",
        description: "scroll transcript or pending details",
    },
    KeyBindingSpec {
        key: "[ / ]",
        scope: "tui transcript",
        description: "jump to previous or next transcript block when input is empty",
    },
    KeyBindingSpec {
        key: "{ / }",
        scope: "tui transcript",
        description: "jump to previous or next diff block when input is empty",
    },
    KeyBindingSpec {
        key: "Ctrl+O",
        scope: "tui transcript",
        description: "collapse or expand the current transcript block",
    },
    KeyBindingSpec {
        key: "PageUp / PageDown",
        scope: "runs picker",
        description: "move selection by a page",
    },
    KeyBindingSpec {
        key: "Home / End",
        scope: "runs picker",
        description: "jump to first or last run",
    },
    KeyBindingSpec {
        key: "L",
        scope: "runs picker",
        description: "open logs for the selected run",
    },
    KeyBindingSpec {
        key: "F",
        scope: "runs picker",
        description: "fork the selected run",
    },
];

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum SlashCommandError {
    Unknown(String),
    UnexpectedArguments {
        command: &'static str,
    },
    InvalidArgument {
        command: &'static str,
        argument: String,
    },
}

impl fmt::Display for SlashCommandError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Unknown(command) => write!(f, "unknown command: {command}"),
            Self::UnexpectedArguments { command } => {
                write!(f, "{command} does not accept those arguments")
            }
            Self::InvalidArgument { command, argument } => {
                write!(f, "{command} does not accept `{argument}`")
            }
        }
    }
}

pub fn parse(input: &str) -> Result<Option<SlashCommand>, SlashCommandError> {
    let input = input.trim();

    if !input.starts_with('/') {
        return Ok(None);
    }

    let mut parts = input.splitn(2, char::is_whitespace);
    let name = parts.next().unwrap_or_default();
    let rest = parts
        .next()
        .map(str::trim)
        .filter(|value| !value.is_empty());

    match name {
        "/help" => no_args(rest, "/help", SlashCommand::Help),
        "/keymap" => no_args(rest, "/keymap", SlashCommand::Keymap),
        "/permissions" => permissions_command(rest),
        "/status" => no_args(rest, "/status", SlashCommand::Status),
        "/doctor" => no_args(rest, "/doctor", SlashCommand::Doctor),
        "/model" => no_args(rest, "/model", SlashCommand::Model),
        "/goal" => prompt_command(rest, |prompt| SlashCommand::Goal { prompt }),
        "/build" => no_args(rest, "/build", SlashCommand::Build),
        "/diff" => diff_command(rest),
        "/runs" => no_args(rest, "/runs", SlashCommand::Runs),
        "/logs" => logs_command(rest),
        "/history" => no_args(rest, "/history", SlashCommand::History),
        "/clear" => no_args(rest, "/clear", SlashCommand::Clear),
        "/exit" => no_args(rest, "/exit", SlashCommand::Exit),
        "/resume" => run_ref_command(rest, "/resume", |run_ref| SlashCommand::Resume { run_ref }),
        "/fork" => run_ref_command(rest, "/fork", |run_ref| SlashCommand::Fork { run_ref }),
        _ => Err(SlashCommandError::Unknown(name.to_string())),
    }
}

pub fn matching_specs(input: &str) -> Vec<&'static SlashCommandSpec> {
    let trimmed = input.trim_start();

    if !trimmed.starts_with('/') || trimmed.contains(char::is_whitespace) {
        return Vec::new();
    }

    SLASH_COMMANDS
        .iter()
        .filter(|command| command.name.starts_with(trimmed))
        .collect()
}

pub fn complete(input: &str) -> Option<String> {
    let leading = input.len() - input.trim_start().len();
    let prefix = &input[..leading];
    let trimmed = input.trim_start();

    if !trimmed.starts_with('/') || trimmed.contains(char::is_whitespace) {
        return None;
    }

    let matches = matching_specs(trimmed);

    match matches.as_slice() {
        [command] if command.name != trimmed => Some(format!("{prefix}{}", command.name)),
        _ => None,
    }
}

fn permissions_command(rest: Option<&str>) -> Result<Option<SlashCommand>, SlashCommandError> {
    let mode = match rest {
        None => None,
        Some(value) if value.split_whitespace().count() == 1 => {
            let Some(mode) = PermissionMode::parse(value) else {
                return Err(SlashCommandError::InvalidArgument {
                    command: "/permissions",
                    argument: value.to_string(),
                });
            };

            Some(mode)
        }
        Some(_) => {
            return Err(SlashCommandError::UnexpectedArguments {
                command: "/permissions",
            })
        }
    };

    Ok(Some(SlashCommand::Permissions { mode }))
}

fn diff_command(rest: Option<&str>) -> Result<Option<SlashCommand>, SlashCommandError> {
    let view = match rest {
        None => DiffView::Full,
        Some("full") => DiffView::Full,
        Some("summary") => DiffView::Summary,
        Some(value) if value.split_whitespace().count() == 1 => {
            return Err(SlashCommandError::InvalidArgument {
                command: "/diff",
                argument: value.to_string(),
            })
        }
        Some(_) => return Err(SlashCommandError::UnexpectedArguments { command: "/diff" }),
    };

    Ok(Some(SlashCommand::Diff { view }))
}

fn logs_command(rest: Option<&str>) -> Result<Option<SlashCommand>, SlashCommandError> {
    let parts = rest
        .map(|value| value.split_whitespace().collect::<Vec<_>>())
        .unwrap_or_default();

    let (run_ref, view) = match parts.as_slice() {
        [] => (None, LogView::Activity),
        [view] if log_view(*view).is_some() => (None, log_view(*view).unwrap()),
        [run_ref] => (Some((*run_ref).to_string()), LogView::Activity),
        [run_ref, view] => {
            let Some(view) = log_view(view) else {
                return Err(SlashCommandError::InvalidArgument {
                    command: "/logs",
                    argument: (*view).to_string(),
                });
            };
            (Some((*run_ref).to_string()), view)
        }
        _ => return Err(SlashCommandError::UnexpectedArguments { command: "/logs" }),
    };

    Ok(Some(SlashCommand::Logs { run_ref, view }))
}

fn log_view(value: &str) -> Option<LogView> {
    match value {
        "activity" => Some(LogView::Activity),
        "transcript" => Some(LogView::Transcript),
        _ => None,
    }
}

fn no_args(
    rest: Option<&str>,
    command: &'static str,
    parsed: SlashCommand,
) -> Result<Option<SlashCommand>, SlashCommandError> {
    if rest.is_some() {
        return Err(SlashCommandError::UnexpectedArguments { command });
    }

    Ok(Some(parsed))
}

fn prompt_command(
    rest: Option<&str>,
    build: impl FnOnce(Option<String>) -> SlashCommand,
) -> Result<Option<SlashCommand>, SlashCommandError> {
    Ok(Some(build(rest.map(str::to_string))))
}

fn run_ref_command(
    rest: Option<&str>,
    command: &'static str,
    build: impl FnOnce(Option<String>) -> SlashCommand,
) -> Result<Option<SlashCommand>, SlashCommandError> {
    match rest {
        None => Ok(Some(build(None))),
        Some(value) if value.split_whitespace().count() == 1 => {
            Ok(Some(build(Some(value.to_string()))))
        }
        Some(_) => Err(SlashCommandError::UnexpectedArguments { command }),
    }
}

#[cfg(test)]
mod tests {
    use super::{
        complete, parse, DiffView, LogView, PermissionMode, SlashCommand, SlashCommandError,
        KEY_BINDINGS, SLASH_COMMANDS,
    };

    #[test]
    fn command_table_has_exit_and_help() {
        let names = SLASH_COMMANDS
            .iter()
            .map(|command| command.name)
            .collect::<Vec<_>>();

        assert!(names.contains(&"/help"));
        assert!(names.contains(&"/keymap"));
        assert!(names.contains(&"/permissions"));
        assert!(names.contains(&"/goal"));
        assert!(names.contains(&"/build"));
        assert!(names.contains(&"/diff"));
        assert!(names.contains(&"/fork"));
        assert!(names.contains(&"/exit"));
    }

    #[test]
    fn parses_keymap_without_arguments() {
        assert_eq!(parse("/keymap").expect("parse"), Some(SlashCommand::Keymap));
    }

    #[test]
    fn parses_permission_mode_commands() {
        assert_eq!(
            parse("/permissions").expect("parse"),
            Some(SlashCommand::Permissions { mode: None })
        );
        assert_eq!(
            parse("/permissions review").expect("parse"),
            Some(SlashCommand::Permissions {
                mode: Some(PermissionMode::Review)
            })
        );
        assert_eq!(
            parse("/permissions auto").expect("parse"),
            Some(SlashCommand::Permissions {
                mode: Some(PermissionMode::Auto)
            })
        );
        assert_eq!(
            parse("/permissions deny").expect("parse"),
            Some(SlashCommand::Permissions {
                mode: Some(PermissionMode::Deny)
            })
        );
        assert_eq!(
            parse("/permissions ask").expect_err("invalid"),
            SlashCommandError::InvalidArgument {
                command: "/permissions",
                argument: "ask".to_string()
            }
        );
        assert_eq!(
            parse("/approval").expect_err("obsolete"),
            SlashCommandError::Unknown("/approval".to_string())
        );
    }

    #[test]
    fn parses_goal_and_build_mode_commands() {
        assert_eq!(
            parse("/goal").expect("parse"),
            Some(SlashCommand::Goal { prompt: None })
        );
        assert_eq!(
            parse("/goal refactor the parser").expect("parse"),
            Some(SlashCommand::Goal {
                prompt: Some("refactor the parser".to_string())
            })
        );
        assert_eq!(parse("/build").expect("parse"), Some(SlashCommand::Build));
        assert_eq!(
            parse("/build now").expect_err("invalid"),
            SlashCommandError::UnexpectedArguments { command: "/build" }
        );
    }

    #[test]
    fn parses_diff_view_commands() {
        assert_eq!(
            parse("/diff").expect("parse"),
            Some(SlashCommand::Diff {
                view: DiffView::Full
            })
        );
        assert_eq!(
            parse("/diff full").expect("parse"),
            Some(SlashCommand::Diff {
                view: DiffView::Full
            })
        );
        assert_eq!(
            parse("/diff summary").expect("parse"),
            Some(SlashCommand::Diff {
                view: DiffView::Summary
            })
        );
        assert_eq!(
            parse("/diff compact").expect_err("invalid"),
            SlashCommandError::InvalidArgument {
                command: "/diff",
                argument: "compact".to_string()
            }
        );
    }

    #[test]
    fn keymap_documents_core_composer_controls() {
        let rows = KEY_BINDINGS
            .iter()
            .map(|binding| (binding.key, binding.scope))
            .collect::<Vec<_>>();

        assert!(rows.contains(&("Up / Down", "composer")));
        assert!(rows.contains(&("Ctrl+R", "composer")));
        assert!(rows.contains(&("Tab", "composer")));
        assert!(rows.contains(&("Y / N", "approval")));
        assert!(rows.contains(&("Esc", "tui approval")));
        assert!(rows.contains(&("PageUp / PageDown", "runs picker")));
        assert!(rows.contains(&("Home / End", "runs picker")));
        assert!(rows.contains(&("L", "runs picker")));
        assert!(rows.contains(&("F", "runs picker")));
    }

    #[test]
    fn parses_resume_with_optional_single_run_ref() {
        assert_eq!(
            parse("/resume").expect("parse"),
            Some(SlashCommand::Resume { run_ref: None })
        );
        assert_eq!(
            parse("/resume latest").expect("parse"),
            Some(SlashCommand::Resume {
                run_ref: Some("latest".to_string())
            })
        );
    }

    #[test]
    fn parses_fork_with_optional_single_run_ref() {
        assert_eq!(
            parse("/fork").expect("parse"),
            Some(SlashCommand::Fork { run_ref: None })
        );
        assert_eq!(
            parse("/fork run_123").expect("parse"),
            Some(SlashCommand::Fork {
                run_ref: Some("run_123".to_string())
            })
        );
        assert_eq!(
            parse("/fork one two").expect_err("args"),
            SlashCommandError::UnexpectedArguments { command: "/fork" }
        );
    }

    #[test]
    fn parses_logs_with_optional_single_run_ref() {
        assert_eq!(
            parse("/logs").expect("parse"),
            Some(SlashCommand::Logs {
                run_ref: None,
                view: LogView::Activity
            })
        );
        assert_eq!(
            parse("/logs run_123").expect("parse"),
            Some(SlashCommand::Logs {
                run_ref: Some("run_123".to_string()),
                view: LogView::Activity
            })
        );
        assert_eq!(
            parse("/logs transcript").expect("parse"),
            Some(SlashCommand::Logs {
                run_ref: None,
                view: LogView::Transcript
            })
        );
        assert_eq!(
            parse("/logs run_123 transcript").expect("parse"),
            Some(SlashCommand::Logs {
                run_ref: Some("run_123".to_string()),
                view: LogView::Transcript
            })
        );
        assert_eq!(
            parse("/logs run_123 compact").expect_err("invalid"),
            SlashCommandError::InvalidArgument {
                command: "/logs",
                argument: "compact".to_string()
            }
        );
    }

    #[test]
    fn rejects_unknown_and_ambiguous_slash_commands() {
        assert_eq!(
            parse("/wat").expect_err("unknown"),
            SlashCommandError::Unknown("/wat".to_string())
        );
        assert_eq!(
            parse("/quit").expect_err("unknown"),
            SlashCommandError::Unknown("/quit".to_string())
        );
        assert_eq!(
            parse("/help now").expect_err("args"),
            SlashCommandError::UnexpectedArguments { command: "/help" }
        );
        assert_eq!(
            parse("/keymap now").expect_err("args"),
            SlashCommandError::UnexpectedArguments { command: "/keymap" }
        );
        assert_eq!(
            parse("/permissions auto now").expect_err("args"),
            SlashCommandError::UnexpectedArguments {
                command: "/permissions"
            }
        );
        assert_eq!(
            parse("/diff full now").expect_err("args"),
            SlashCommandError::UnexpectedArguments { command: "/diff" }
        );
        assert_eq!(
            parse("/resume one two").expect_err("args"),
            SlashCommandError::UnexpectedArguments { command: "/resume" }
        );
        assert_eq!(
            parse("/fork one two").expect_err("args"),
            SlashCommandError::UnexpectedArguments { command: "/fork" }
        );
        assert_eq!(
            parse("/logs one two three").expect_err("args"),
            SlashCommandError::UnexpectedArguments { command: "/logs" }
        );
    }

    #[test]
    fn completes_unique_slash_command_prefixes() {
        assert_eq!(complete("/he"), Some("/help".to_string()));
        assert_eq!(complete("/pe"), Some("/permissions".to_string()));
        assert_eq!(complete("/ke"), Some("/keymap".to_string()));
        assert_eq!(complete("  /he"), Some("  /help".to_string()));
        assert_eq!(complete("/help"), None);
        assert_eq!(complete("/r"), None);
        assert_eq!(complete("/logs run_1"), None);
        assert_eq!(complete("plain"), None);
    }
}
