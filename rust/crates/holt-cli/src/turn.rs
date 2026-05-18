use crate::ui::Tone;
use serde_json::Value;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ActivityControl {
    Approval {
        action: String,
    },
    UserInput {
        question: String,
        description: Option<String>,
        options: Vec<QuestionOption>,
    },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct QuestionOption {
    pub label: String,
    pub value: String,
    pub description: Option<String>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum FileEditStatus {
    Edited,
    Unchanged,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FileEditSummary {
    pub path: String,
    pub additions: Option<i64>,
    pub deletions: Option<i64>,
    pub unified_diff: Option<String>,
    pub diff_redacted: bool,
    pub status: FileEditStatus,
}

impl FileEditSummary {
    pub fn summary_text(&self) -> String {
        match self.status {
            FileEditStatus::Unchanged => format!("• Unchanged {}", self.path),
            FileEditStatus::Edited => {
                let counts = match (self.additions, self.deletions) {
                    (Some(additions), Some(deletions)) => {
                        format!(" (+{additions} -{deletions})")
                    }
                    _ => String::new(),
                };
                format!("• Edited {}{counts}", self.path)
            }
        }
    }

    pub fn detail_markdown(&self) -> Option<String> {
        self.unified_diff
            .as_deref()
            .filter(|diff| !diff.trim().is_empty())
            .map(|diff| format!("```diff\n{}\n```", diff.trim_end()))
            .or_else(|| {
                self.diff_redacted
                    .then(|| "Diff redacted for a sensitive file.".to_string())
            })
    }

    pub fn markdown(&self) -> String {
        match self.detail_markdown() {
            Some(detail) => format!("{}\n{}", self.summary_text(), detail),
            None => self.summary_text(),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum RenderAction {
    Line {
        tone: Tone,
        text: String,
    },
    Activity {
        tone: Tone,
        text: String,
        detail: Option<String>,
        terminal: bool,
        control: Option<ActivityControl>,
    },
    FileEdit {
        summary: FileEditSummary,
    },
    Answer {
        content: String,
    },
    Footer {
        text: String,
    },
}

#[derive(Clone, Debug, Default)]
pub struct TurnState {
    last_activity: Option<String>,
    answer_started: bool,
    completion_seen: bool,
}

impl TurnState {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn completion_seen(&self) -> bool {
        self.completion_seen
    }

    pub fn apply_event(&mut self, event: &Value) -> Vec<RenderAction> {
        let event_type = event.get("type").and_then(Value::as_str).unwrap_or("");

        match event_type {
            "turn.started" => Vec::new(),
            value if value.starts_with("progress.") => self.progress(value, event),
            "action.started" => self.running_action(event),
            "action.approval_requested" => self.approval_requested(event),
            "action.approval_resolved" => self.approval(event),
            "action.completed" => self.completed_action(event),
            "action.failed" => self.failed_action(event),
            "child_agent.completed" => self.child_agent_completed(event),
            "model.thinking" => self.model_thinking(event),
            "awaiting_user" => self.awaiting_user(event),
            "answer.delta" | "stream_chunk" => self.answer_delta(event),
            "turn.completed" => Vec::new(),
            "run.result" => self.run_result(event),
            "turn.failed" | "run.failed" => self.failure(event),
            _ => Vec::new(),
        }
    }

    fn progress(&mut self, event_type: &str, event: &Value) -> Vec<RenderAction> {
        if event_type == "progress.waiting-for-input" {
            return Vec::new();
        }

        if event_type == "progress.failed" {
            return Vec::new();
        }

        let Some(message) = event.get("message").and_then(Value::as_str) else {
            return Vec::new();
        };

        if event_type == "progress.completed" && self.answer_started {
            return Vec::new();
        }

        self.activity(
            message,
            if event_type == "progress.completed" {
                Tone::Dim
            } else {
                Tone::Warning
            },
            if event_type == "progress.completed" {
                "✓"
            } else {
                "◐"
            },
            None,
            event_type == "progress.completed",
            None,
        )
    }

    fn running_action(&mut self, event: &Value) -> Vec<RenderAction> {
        self.activity(&label(event), Tone::Warning, "◐", None, false, None)
    }

    fn approval_requested(&mut self, event: &Value) -> Vec<RenderAction> {
        self.activity(
            &format!("Approval required: {}", approval_subject(event)),
            Tone::Warning,
            "!",
            approval_detail(event),
            false,
            approval_control(event),
        )
    }

    fn approval(&mut self, event: &Value) -> Vec<RenderAction> {
        let status = event.get("status").and_then(Value::as_str).unwrap_or("");
        let tone = if status == "denied" {
            Tone::Error
        } else {
            Tone::Dim
        };

        self.activity(&label(event), tone, "•", None, true, None)
    }

    fn completed_action(&mut self, event: &Value) -> Vec<RenderAction> {
        if let Some(summary) = edit_summary(event) {
            let key = summary.markdown();

            if self.last_activity.as_deref() == Some(&key) {
                return Vec::new();
            }

            self.last_activity = Some(key);
            return vec![RenderAction::FileEdit { summary }];
        }

        if compact_visibility(event) {
            return Vec::new();
        }

        let line = join_parts(&[
            Some(label(event)),
            compact_summary(event.get("output_summary")),
        ]);
        self.activity(&line, Tone::Dim, "✓", None, true, None)
    }

    fn failed_action(&mut self, event: &Value) -> Vec<RenderAction> {
        let reason = event
            .get("error_summary")
            .and_then(|summary| summary.get("message"))
            .and_then(Value::as_str)
            .map(str::to_string);
        let line = join_parts(&[Some(label(event)), reason]);
        self.activity(
            &line,
            Tone::Error,
            "×",
            activity_detail(event, true),
            true,
            None,
        )
    }

    fn child_agent_completed(&mut self, event: &Value) -> Vec<RenderAction> {
        let status = event
            .get("status")
            .and_then(Value::as_str)
            .unwrap_or("completed");
        let subject = event
            .get("child_agent_id")
            .and_then(Value::as_str)
            .filter(|value| !value.trim().is_empty())
            .map(|agent_id| format!("Child agent {agent_id}"))
            .unwrap_or_else(|| "Child agent".to_string());
        let successful = matches!(status, "completed" | "success" | "ok" | "ok_final");

        self.activity(
            &format!("{subject} {status}"),
            if successful { Tone::Dim } else { Tone::Error },
            if successful { "✓" } else { "×" },
            None,
            true,
            None,
        )
    }

    fn awaiting_user(&mut self, event: &Value) -> Vec<RenderAction> {
        let Some(question) = event.get("question").and_then(Value::as_str) else {
            return vec![RenderAction::Line {
                tone: Tone::Error,
                text: "awaiting_user event missing question".to_string(),
            }];
        };
        let question = question.trim();
        if question.is_empty() {
            return vec![RenderAction::Line {
                tone: Tone::Error,
                text: "awaiting_user event missing question".to_string(),
            }];
        }
        let question = question.to_string();
        let description = event
            .get("description")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_string);
        let options = question_options(event);
        let prompt = question.clone();

        self.activity(
            &prompt,
            Tone::Warning,
            "?",
            None,
            false,
            Some(ActivityControl::UserInput {
                question,
                description,
                options,
            }),
        )
    }

    fn model_thinking(&mut self, event: &Value) -> Vec<RenderAction> {
        let content = event
            .get("content")
            .and_then(Value::as_str)
            .map(str::trim)
            .unwrap_or("");

        if content.is_empty() {
            return Vec::new();
        }

        self.activity(
            "Thinking",
            Tone::Dim,
            "◇",
            Some(content.to_string()),
            true,
            None,
        )
    }

    fn answer_delta(&mut self, event: &Value) -> Vec<RenderAction> {
        let content = event
            .get("content")
            .or_else(|| event.get("delta"))
            .and_then(Value::as_str)
            .unwrap_or("");

        if content.is_empty() || (content.trim().is_empty() && !self.answer_started) {
            return Vec::new();
        }

        self.answer_started = true;

        vec![RenderAction::Answer {
            content: content.to_string(),
        }]
    }

    fn run_result(&mut self, event: &Value) -> Vec<RenderAction> {
        if self.completion_seen {
            return Vec::new();
        }

        self.completion_seen = true;
        let mut actions = Vec::new();

        if !self.answer_started {
            if let Some(output) = event.get("output").and_then(Value::as_str) {
                let output = output.trim();

                if !output.is_empty() {
                    self.answer_started = true;
                    actions.push(RenderAction::Answer {
                        content: output.to_string(),
                    });
                }
            }
        }

        if let Some(footer) = footer(event) {
            actions.push(RenderAction::Footer { text: footer });
        }

        actions
    }

    fn failure(&mut self, event: &Value) -> Vec<RenderAction> {
        if self.completion_seen {
            return Vec::new();
        }

        self.completion_seen = true;
        let reason = event
            .get("reason")
            .and_then(Value::as_str)
            .unwrap_or("unknown error");

        vec![RenderAction::Line {
            tone: Tone::Error,
            text: format!("× Holt could not complete the request: {reason}"),
        }]
    }

    fn activity(
        &mut self,
        text: &str,
        tone: Tone,
        marker: &str,
        detail: Option<String>,
        terminal: bool,
        control: Option<ActivityControl>,
    ) -> Vec<RenderAction> {
        let text = text.trim();

        let key = join_parts(&[Some(text.to_string()), detail.clone()]);

        if text.is_empty() || self.last_activity.as_deref() == Some(&key) {
            return Vec::new();
        }

        self.last_activity = Some(key);

        vec![RenderAction::Activity {
            tone,
            text: format!("{marker} {text}"),
            detail,
            terminal,
            control,
        }]
    }
}

fn compact_visibility(event: &Value) -> bool {
    matches!(
        event.get("visibility").and_then(Value::as_str),
        Some("compact")
    )
}

fn footer(event: &Value) -> Option<String> {
    let run_id = event.get("run_id").and_then(Value::as_str)?;
    let status = event
        .get("status")
        .and_then(Value::as_str)
        .unwrap_or("completed");
    let mut footer = format!("{run_id} · {status}");

    if let Some(path) = event
        .get("artifact")
        .and_then(|artifact| artifact.get("path"))
        .and_then(Value::as_str)
    {
        footer.push_str(&format!(" · artifact {path}"));
    }

    Some(footer)
}

fn label(event: &Value) -> String {
    event
        .get("label")
        .and_then(Value::as_str)
        .or_else(|| event.get("active_label").and_then(Value::as_str))
        .or_else(|| event.get("action").and_then(Value::as_str))
        .unwrap_or("Working")
        .to_string()
}

fn approval_subject(event: &Value) -> String {
    event
        .get("approval_subject")
        .and_then(Value::as_str)
        .filter(|subject| !subject.trim().is_empty())
        .unwrap_or("action")
        .to_string()
}

fn approval_control(event: &Value) -> Option<ActivityControl> {
    let action = event.get("action").and_then(Value::as_str)?.trim();

    if action.is_empty() {
        return None;
    }

    Some(ActivityControl::Approval {
        action: action.to_string(),
    })
}

fn question_options(event: &Value) -> Vec<QuestionOption> {
    event
        .get("options")
        .and_then(Value::as_array)
        .map(|options| {
            options
                .iter()
                .filter_map(question_option)
                .collect::<Vec<_>>()
        })
        .unwrap_or_default()
}

fn question_option(value: &Value) -> Option<QuestionOption> {
    let label = value.get("label")?.as_str()?.trim();
    let option_value = value.get("value")?.as_str()?.trim();

    if label.is_empty() || option_value.is_empty() {
        return None;
    }

    let description = value
        .get("description")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string);

    Some(QuestionOption {
        label: label.to_string(),
        value: option_value.to_string(),
        description,
    })
}

fn compact_summary(summary: Option<&Value>) -> Option<String> {
    let object = summary?.as_object()?;

    if object.is_empty() {
        return None;
    }

    let mut parts = Vec::new();

    for key in [
        "files",
        "matches",
        "bytes",
        "path",
        "additions",
        "deletions",
        "exit_code",
        "output_bytes",
        "content_bytes",
        "status",
    ] {
        if let Some(value) = object.get(key) {
            parts.push(format!("{}: {}", key.replace('_', " "), scalar(value)));
        }
    }

    if parts.is_empty() {
        for (key, value) in object {
            if key == "unified_diff" {
                continue;
            }
            parts.push(format!("{}: {}", key.replace('_', " "), scalar(value)));
        }
    }

    Some(parts.join(" · "))
}

fn edit_summary(event: &Value) -> Option<FileEditSummary> {
    let summary = event.get("output_summary")?;
    let path = summary
        .get("path")
        .and_then(Value::as_str)
        .filter(|path| !path.trim().is_empty())?;

    if summary.get("status").and_then(Value::as_str) == Some("unchanged") {
        return Some(FileEditSummary {
            path: path.to_string(),
            additions: None,
            deletions: None,
            unified_diff: None,
            diff_redacted: false,
            status: FileEditStatus::Unchanged,
        });
    }

    let additions = summary.get("additions").and_then(Value::as_i64);
    let deletions = summary.get("deletions").and_then(Value::as_i64);

    let diff_redacted = summary
        .get("diff_redacted")
        .and_then(Value::as_bool)
        .unwrap_or(false);

    if additions.is_none()
        && deletions.is_none()
        && summary.get("unified_diff").is_none()
        && !diff_redacted
    {
        return None;
    }

    let unified_diff = summary
        .get("unified_diff")
        .and_then(Value::as_str)
        .filter(|diff| !diff.trim().is_empty())
        .map(str::to_string);

    Some(FileEditSummary {
        path: path.to_string(),
        additions,
        deletions,
        unified_diff,
        diff_redacted,
        status: FileEditStatus::Edited,
    })
}

fn approval_detail(event: &Value) -> Option<String> {
    let mut sections = Vec::new();

    if let Some(detail) = activity_detail(event, false) {
        sections.push(detail);
    }

    if let Some(preview) = change_preview_detail(event.get("change_preview")) {
        sections.push(preview);
    }

    if sections.is_empty() {
        None
    } else {
        Some(sections.join("\n"))
    }
}

fn change_preview_detail(preview: Option<&Value>) -> Option<String> {
    let preview = preview?;
    let mut sections = Vec::new();

    let path = preview
        .get("path")
        .and_then(Value::as_str)
        .filter(|path| !path.trim().is_empty());
    let additions = preview.get("additions").and_then(Value::as_i64);
    let deletions = preview.get("deletions").and_then(Value::as_i64);
    let unchanged = preview.get("status").and_then(Value::as_str) == Some("unchanged");

    if let (Some(path), Some(additions), Some(deletions)) = (path, additions, deletions) {
        sections.push(format!("proposed: {path} (+{additions} -{deletions})"));
    } else if let Some(path) = path {
        if unchanged {
            sections.push(format!("proposed: {path} unchanged"));
        }
    }

    if let Some(diff) = preview
        .get("unified_diff")
        .and_then(Value::as_str)
        .filter(|diff| !diff.trim().is_empty())
    {
        sections.push(format!("```diff\n{}\n```", diff.trim_end()));
    } else if preview
        .get("diff_redacted")
        .and_then(Value::as_bool)
        .unwrap_or(false)
    {
        sections.push("Diff redacted for a sensitive file.".to_string());
    }

    if sections.is_empty() {
        None
    } else {
        Some(sections.join("\n"))
    }
}

fn activity_detail(event: &Value, include_output: bool) -> Option<String> {
    let mut rows = Vec::new();

    if let Some(status) = event.get("status").and_then(Value::as_str) {
        if status != "running" && status != "completed" {
            rows.push(format!("status: {status}"));
        }
    }

    if let Some(input) = compact_summary(event.get("input_summary")) {
        rows.push(format!("input: {input}"));
    }

    if include_output {
        if let Some(output) = compact_summary(event.get("output_summary")) {
            rows.push(format!("output: {output}"));
        }
    }

    if let Some(risk) = event.get("risk").and_then(Value::as_str) {
        if risk != "read" {
            rows.push(format!("risk: {risk}"));
        }
    }

    if rows.is_empty() {
        None
    } else {
        Some(rows.join("\n"))
    }
}

fn scalar(value: &Value) -> String {
    match value {
        Value::String(text) => text.clone(),
        Value::Number(number) => number.to_string(),
        Value::Bool(value) => value.to_string(),
        _ => value.to_string(),
    }
}

fn join_parts(parts: &[Option<String>]) -> String {
    parts
        .iter()
        .filter_map(|part| part.as_ref())
        .filter(|part| !part.is_empty())
        .cloned()
        .collect::<Vec<_>>()
        .join(" · ")
}

#[cfg(test)]
mod tests {
    use super::{
        ActivityControl, FileEditStatus, FileEditSummary, QuestionOption, RenderAction, TurnState,
    };
    use crate::ui::Tone;
    use serde_json::json;

    #[test]
    fn dedupes_repeated_activity() {
        let mut state = TurnState::new();
        let event = json!({"type": "progress.thinking", "message": "Thinking through the request"});

        assert_eq!(
            state.apply_event(&event),
            vec![RenderAction::Activity {
                tone: Tone::Warning,
                text: "◐ Thinking through the request".to_string(),
                detail: None,
                terminal: false,
                control: None,
            }]
        );
        assert!(state.apply_event(&event).is_empty());
    }

    #[test]
    fn streams_answer_delta_and_keeps_result_to_footer() {
        let mut state = TurnState::new();

        assert_eq!(
            state.apply_event(&json!({"type": "answer.delta", "content": "Hello"})),
            vec![RenderAction::Answer {
                content: "Hello".to_string()
            }]
        );

        assert_eq!(
            state.apply_event(&json!({
                "type": "run.result",
                "run_id": "run_123",
                "status": "completed",
                "output": "Hello"
            })),
            vec![RenderAction::Footer {
                text: "run_123 · completed".to_string()
            }]
        );
    }

    #[test]
    fn answer_delta_preserves_markdown_newlines() {
        let mut state = TurnState::new();

        assert_eq!(
            state.apply_event(&json!({"type": "answer.delta", "content": "```rust"})),
            vec![RenderAction::Answer {
                content: "```rust".to_string()
            }]
        );
        assert_eq!(
            state.apply_event(&json!({"type": "answer.delta", "content": "\n"})),
            vec![RenderAction::Answer {
                content: "\n".to_string()
            }]
        );
    }

    #[test]
    fn final_result_renders_answer_when_no_delta_arrived() {
        let mut state = TurnState::new();

        assert_eq!(
            state.apply_event(&json!({
                "type": "run.result",
                "run_id": "run_123",
                "status": "completed",
                "output": "Hello"
            })),
            vec![
                RenderAction::Answer {
                    content: "Hello".to_string()
                },
                RenderAction::Footer {
                    text: "run_123 · completed".to_string()
                }
            ]
        );
    }

    #[test]
    fn started_action_renders_concise_progress_without_summaries() {
        let mut state = TurnState::new();

        assert_eq!(
            state.apply_event(&json!({
                "type": "action.started",
                "action": "list",
                "label": "Reading workspace",
                "visibility": "compact",
                "input_summary": {"path": "src/lib.rs"}
            })),
            vec![RenderAction::Activity {
                tone: Tone::Warning,
                text: "◐ Reading workspace".to_string(),
                detail: None,
                terminal: false,
                control: None,
            }]
        );
    }

    #[test]
    fn ask_action_spinner_uses_elixir_label_before_the_structured_prompt() {
        let mut state = TurnState::new();

        assert_eq!(
            state.apply_event(&json!({
                "type": "action.started",
                "action": "ask",
                "label": "Waiting for your input"
            })),
            vec![RenderAction::Activity {
                tone: Tone::Warning,
                text: "◐ Waiting for your input".to_string(),
                detail: None,
                terminal: false,
                control: None,
            }]
        );
    }

    #[test]
    fn failed_progress_is_hidden_until_the_terminal_error_event() {
        let mut state = TurnState::new();

        assert!(state
            .apply_event(&json!({
                "type": "progress.failed",
                "stage": "failed",
                "message": "Holt could not complete the request"
            }))
            .is_empty());
    }

    #[test]
    fn compact_completed_action_stays_out_of_the_chat_transcript() {
        let mut state = TurnState::new();

        assert!(state
            .apply_event(&json!({
                "type": "action.completed",
                "label": "Read workspace",
                "visibility": "compact",
                "input_summary": {"path": "src/lib.rs"},
                "output_summary": {"files": 80, "ignored": true}
            }))
            .is_empty());
    }

    #[test]
    fn expanded_completed_action_keeps_one_line_summary_without_detail_dump() {
        let mut state = TurnState::new();

        assert_eq!(
            state.apply_event(&json!({
                "type": "action.completed",
                "label": "Ran command",
                "visibility": "expanded",
                "input_summary": {"command": "mix test"},
                "output_summary": {"exit_code": 0, "output_bytes": 120}
            })),
            vec![RenderAction::Activity {
                tone: Tone::Dim,
                text: "✓ Ran command · exit code: 0 · output bytes: 120".to_string(),
                detail: None,
                terminal: true,
                control: None,
            }]
        );
    }

    #[test]
    fn child_agent_completion_notifies_current_ui_turn() {
        let mut state = TurnState::new();

        assert_eq!(
            state.apply_event(&json!({
                "type": "child_agent.completed",
                "agent_run_id": "agent-run-parent",
                "child_agent_id": "agent-reviewer",
                "child_agent_work_id": "agent-work-child",
                "child_run_id": "run-child",
                "status": "completed"
            })),
            vec![RenderAction::Activity {
                tone: Tone::Dim,
                text: "✓ Child agent agent-reviewer completed".to_string(),
                detail: None,
                terminal: true,
                control: None,
            }]
        );
    }

    #[test]
    fn model_thinking_renders_as_persistent_activity_detail() {
        let mut state = TurnState::new();

        assert_eq!(
            state.apply_event(&json!({
                "type": "model.thinking",
                "block_type": "thinking",
                "content": "Inspect context first.\nThen decide next action."
            })),
            vec![RenderAction::Activity {
                tone: Tone::Dim,
                text: "◇ Thinking".to_string(),
                detail: Some("Inspect context first.\nThen decide next action.".to_string()),
                terminal: true,
                control: None,
            }]
        );
    }

    #[test]
    fn completed_edit_action_renders_codex_style_summary_and_diff() {
        let mut state = TurnState::new();

        assert_eq!(
            state.apply_event(&json!({
                "type": "action.completed",
                "label": "Updated `src/ui.rs`",
                "output_summary": {
                    "path": "src/ui.rs",
                    "additions": 5,
                    "deletions": 3,
                    "unified_diff": "--- a/src/ui.rs\n+++ b/src/ui.rs\n@@ -1,1 +1,1 @@\n-old\n+new"
                }
            })),
            vec![RenderAction::FileEdit {
                summary: FileEditSummary {
                    path: "src/ui.rs".to_string(),
                    additions: Some(5),
                    deletions: Some(3),
                    unified_diff: Some(
                        "--- a/src/ui.rs\n+++ b/src/ui.rs\n@@ -1,1 +1,1 @@\n-old\n+new".to_string()
                    ),
                    diff_redacted: false,
                    status: FileEditStatus::Edited,
                },
            }]
        );
    }

    #[test]
    fn completed_unchanged_edit_action_renders_compact_summary() {
        let mut state = TurnState::new();

        assert_eq!(
            state.apply_event(&json!({
                "type": "action.completed",
                "label": "Unchanged `src/ui.rs`",
                "output_summary": {
                    "path": "src/ui.rs",
                    "bytes": 120,
                    "status": "unchanged"
                }
            })),
            vec![RenderAction::FileEdit {
                summary: FileEditSummary {
                    path: "src/ui.rs".to_string(),
                    additions: None,
                    deletions: None,
                    unified_diff: None,
                    diff_redacted: false,
                    status: FileEditStatus::Unchanged,
                },
            }]
        );
    }

    #[test]
    fn approval_request_renders_as_explicit_gate_with_risk_detail() {
        let mut state = TurnState::new();

        assert_eq!(
            state.apply_event(&json!({
                "type": "action.approval_requested",
                "action": "write",
                "label": "Writing file README.md",
                "approval_subject": "Writing file README.md",
                "status": "awaiting_approval",
                "risk": "write",
                "input_summary": {"path": "README.md", "content_bytes": 120},
                "change_preview": {
                    "path": "README.md",
                    "additions": 1,
                    "deletions": 1,
                    "unified_diff": "--- a/README.md\n+++ b/README.md\n@@ -1,1 +1,1 @@\n-old\n+new"
                }
            })),
            vec![RenderAction::Activity {
                tone: Tone::Warning,
                text: "! Approval required: Writing file README.md".to_string(),
                detail: Some(
                    "status: awaiting_approval\ninput: path: README.md · content bytes: 120\nrisk: write\nproposed: README.md (+1 -1)\n```diff\n--- a/README.md\n+++ b/README.md\n@@ -1,1 +1,1 @@\n-old\n+new\n```"
                        .to_string()
                ),
                terminal: false,
                control: Some(ActivityControl::Approval {
                    action: "write".to_string()
                }),
            }]
        );
    }

    #[test]
    fn approval_request_renders_unchanged_change_preview() {
        let mut state = TurnState::new();

        assert_eq!(
            state.apply_event(&json!({
                "type": "action.approval_requested",
                "action": "write",
                "approval_subject": "Writing file README.md",
                "status": "awaiting_approval",
                "risk": "write",
                "input_summary": {"path": "README.md", "content_bytes": 120},
                "change_preview": {
                    "path": "README.md",
                    "status": "unchanged"
                }
            })),
            vec![RenderAction::Activity {
                tone: Tone::Warning,
                text: "! Approval required: Writing file README.md".to_string(),
                detail: Some(
                    "status: awaiting_approval\ninput: path: README.md · content bytes: 120\nrisk: write\nproposed: README.md unchanged"
                        .to_string()
                ),
                terminal: false,
                control: Some(ActivityControl::Approval {
                    action: "write".to_string()
                }),
            }]
        );
    }

    #[test]
    fn awaiting_user_renders_structured_option_control() {
        let mut state = TurnState::new();

        assert_eq!(
            state.apply_event(&json!({
                "type": "awaiting_user",
                "question": "Choose a path",
                "description": "Pick the next task direction.",
                "options": [
                    {"label": "Plan", "value": "plan", "description": "Write a plan"},
                    {"label": "Build", "value": "build"}
                ]
            })),
            vec![RenderAction::Activity {
                tone: Tone::Warning,
                text: "? Choose a path".to_string(),
                detail: None,
                terminal: false,
                control: Some(ActivityControl::UserInput {
                    question: "Choose a path".to_string(),
                    description: Some("Pick the next task direction.".to_string()),
                    options: vec![
                        QuestionOption {
                            label: "Plan".to_string(),
                            value: "plan".to_string(),
                            description: Some("Write a plan".to_string()),
                        },
                        QuestionOption {
                            label: "Build".to_string(),
                            value: "build".to_string(),
                            description: None,
                        },
                    ],
                }),
            }]
        );
    }
}
