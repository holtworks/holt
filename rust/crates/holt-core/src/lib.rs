//! Native Holt agent engine.

use anyhow::Result;
use holt_protocol::{AgentEvent, AgentEventKind, AgentResponse, ChatMessage, TurnRequest};
use holt_workspace::{FileKind, WorkspaceScanner, WorkspaceSnapshot};

pub struct AgentEngine {
    scanner: WorkspaceScanner,
}

impl Default for AgentEngine {
    fn default() -> Self {
        Self {
            scanner: WorkspaceScanner::default(),
        }
    }
}

impl AgentEngine {
    pub fn run_turn(&self, request: TurnRequest) -> Result<AgentResponse> {
        let mut events = vec![AgentEvent::new(
            AgentEventKind::SessionStarted,
            "turn started",
        )];

        let snapshot = self.scanner.scan(&request.workspace)?;
        events.push(AgentEvent::new(
            AgentEventKind::ContextBuilt,
            format!("{} files indexed", snapshot.files.len()),
        ));

        let output = if workspace_overview_intent(&request) {
            workspace_overview(&snapshot)
        } else {
            direct_reply(&request)
        };

        events.push(AgentEvent::new(
            AgentEventKind::TurnCompleted,
            "turn completed",
        ));

        Ok(AgentResponse { output, events })
    }
}

pub fn architecture_summary() -> &'static str {
    "Holt native architecture\n\
     - holt-cli: command dispatch and structured backend calls\n\
     - holt-tui: terminal rendering over typed events\n\
     - holt-core: agent loop and turn orchestration\n\
     - holt-protocol: requests, events, actions, approvals\n\
     - holt-workspace: repo scan and context packing\n\
     - holt-actions: action registry and execution\n\
     - holt-policy: approvals and side-effect decisions\n\
     - holt-sessions: durable conversation state\n\
     - holt-models: provider clients and streaming\n\
     - holt-telemetry: traces and usage events"
}

fn direct_reply(request: &TurnRequest) -> String {
    format!(
        "Hello. I am Holt. What should we work on after `{}`?",
        request.objective
    )
}

fn workspace_overview(snapshot: &WorkspaceSnapshot) -> String {
    let source_count = snapshot
        .files
        .iter()
        .filter(|file| file.kind == FileKind::Source)
        .count();
    let test_count = snapshot
        .files
        .iter()
        .filter(|file| file.kind == FileKind::Test)
        .count();
    let key_files = snapshot
        .key_files
        .iter()
        .map(|file| format!("- `{}`", file.path))
        .collect::<Vec<_>>()
        .join("\n");

    format!(
        "I scanned this workspace as Holt.\n\nFiles: {} total, {source_count} source, {test_count} test.\n\nAgent instructions read:\n{}",
        snapshot.files.len(),
        if key_files.is_empty() {
            "- none"
        } else {
            key_files.as_str()
        }
    )
}

fn workspace_overview_intent(request: &TurnRequest) -> bool {
    let tokens = intent_tokens(
        request
            .chat_messages
            .iter()
            .chain(std::iter::once(&ChatMessage::user(&request.objective)))
            .map(|message| message.content.as_str()),
    );
    let current_tokens = intent_tokens(std::iter::once(request.objective.as_str()));
    let target = any_token(
        &tokens,
        &["repo", "repository", "project", "codebase", "workspace"],
    );
    let action = any_token(
        &tokens,
        &["read", "inspect", "review", "scan", "understand", "map"],
    );
    let broad = any_token(
        &current_tokens,
        &["entire", "whole", "all", "everything", "full"],
    );

    target && (action || broad)
}

fn intent_tokens<'a>(values: impl Iterator<Item = &'a str>) -> Vec<String> {
    values
        .flat_map(|value| {
            value
                .split(|ch: char| !ch.is_ascii_alphanumeric())
                .map(|token| token.to_ascii_lowercase())
                .collect::<Vec<_>>()
        })
        .filter(|token| !token.is_empty())
        .collect()
}

fn any_token(tokens: &[String], candidates: &[&str]) -> bool {
    tokens
        .iter()
        .any(|token| candidates.iter().any(|candidate| token == candidate))
}

#[cfg(test)]
mod tests {
    use super::{architecture_summary, AgentEngine};
    use holt_protocol::{ChatMessage, TurnRequest};
    use std::fs;

    #[test]
    fn architecture_summary_lists_native_boundaries() {
        let summary = architecture_summary();
        assert!(summary.contains("holt-core"));
        assert!(summary.contains("holt-protocol"));
        assert!(summary.contains("holt-actions"));
    }

    #[test]
    fn engine_reads_workspace_for_repo_overview_followup() {
        let root = std::env::temp_dir().join(format!("holt-core-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(root.join("src")).unwrap();
        fs::write(root.join("AGENTS.md"), "# Agent rules").unwrap();
        fs::write(root.join("README.md"), "# Demo").unwrap();
        fs::write(root.join("src/main.rs"), "fn main() {}").unwrap();

        let request = TurnRequest::new("the entire project", root.to_string_lossy())
            .with_chat_messages(vec![ChatMessage::user("read this repo")]);
        let response = AgentEngine::default().run_turn(request).unwrap();

        assert!(response.output.contains("I scanned this workspace as Holt"));
        assert!(response.output.contains("Agent instructions read"));
        assert!(response.output.contains("AGENTS.md"));
        assert!(!response.output.contains("README.md"));
        assert!(response
            .events
            .iter()
            .any(|event| event.message.contains("files indexed")));

        let _ = fs::remove_dir_all(&root);
    }
}
