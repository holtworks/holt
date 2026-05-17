use crate::ui::Tone;
use serde_json::Value;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum RenderAction {
    Line { tone: Tone, text: String },
    Answer { content: String },
    Footer { text: String },
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
            "tool.started" | "tool.approval_requested" => self.running_tool(event),
            "tool.approval_resolved" => self.approval(event),
            "tool.completed" => self.completed_tool(event),
            "tool.failed" => self.failed_tool(event),
            "answer.delta" | "stream_chunk" => self.answer_delta(event),
            "turn.completed" => Vec::new(),
            "run.result" => self.run_result(event),
            "turn.failed" | "run.failed" => self.failure(event),
            _ => Vec::new(),
        }
    }

    fn progress(&mut self, event_type: &str, event: &Value) -> Vec<RenderAction> {
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
        )
    }

    fn running_tool(&mut self, event: &Value) -> Vec<RenderAction> {
        self.activity(&label(event), Tone::Warning, "◐")
    }

    fn approval(&mut self, event: &Value) -> Vec<RenderAction> {
        let status = event.get("status").and_then(Value::as_str).unwrap_or("");
        let tone = if status == "denied" {
            Tone::Error
        } else {
            Tone::Dim
        };

        self.activity(&label(event), tone, "•")
    }

    fn completed_tool(&mut self, event: &Value) -> Vec<RenderAction> {
        let line = join_parts(&[
            Some(label(event)),
            compact_summary(event.get("output_summary")),
        ]);
        self.activity(&line, Tone::Dim, "✓")
    }

    fn failed_tool(&mut self, event: &Value) -> Vec<RenderAction> {
        let reason = event
            .get("error_summary")
            .and_then(|summary| summary.get("message"))
            .and_then(Value::as_str)
            .map(str::to_string);
        let line = join_parts(&[Some(label(event)), reason]);
        self.activity(&line, Tone::Error, "×")
    }

    fn answer_delta(&mut self, event: &Value) -> Vec<RenderAction> {
        let content = event
            .get("content")
            .or_else(|| event.get("delta"))
            .and_then(Value::as_str)
            .unwrap_or("")
            .trim();

        if content.is_empty() {
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

    fn activity(&mut self, text: &str, tone: Tone, marker: &str) -> Vec<RenderAction> {
        let text = text.trim();

        if text.is_empty() || self.last_activity.as_deref() == Some(text) {
            return Vec::new();
        }

        self.last_activity = Some(text.to_string());

        vec![RenderAction::Line {
            tone,
            text: format!("{marker} {text}"),
        }]
    }
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
        .or_else(|| event.get("tool").and_then(Value::as_str))
        .unwrap_or("Working")
        .to_string()
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
        "exit_code",
        "output_bytes",
        "status",
    ] {
        if let Some(value) = object.get(key) {
            parts.push(format!("{}: {}", key.replace('_', " "), scalar(value)));
        }
    }

    if parts.is_empty() {
        for (key, value) in object {
            parts.push(format!("{}: {}", key.replace('_', " "), scalar(value)));
        }
    }

    Some(parts.join(" · "))
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
    use super::{RenderAction, TurnState};
    use crate::ui::Tone;
    use serde_json::json;

    #[test]
    fn dedupes_repeated_activity() {
        let mut state = TurnState::new();
        let event = json!({"type": "progress.thinking", "message": "Thinking"});

        assert_eq!(
            state.apply_event(&event),
            vec![RenderAction::Line {
                tone: Tone::Warning,
                text: "◐ Thinking".to_string()
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
    fn completed_tool_includes_compact_summary() {
        let mut state = TurnState::new();

        assert_eq!(
            state.apply_event(&json!({
                "type": "tool.completed",
                "label": "Read workspace",
                "output_summary": {"files": 80, "ignored": true}
            })),
            vec![RenderAction::Line {
                tone: Tone::Dim,
                text: "✓ Read workspace · files: 80".to_string()
            }]
        );
    }
}
