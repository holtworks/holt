//! TUI-facing presentation helpers for protocol events.

use holt_protocol::{AgentEvent, AgentEventKind};

pub fn render_event_line(event: &AgentEvent) -> String {
    let label = match event.kind {
        AgentEventKind::SessionStarted => "session",
        AgentEventKind::ContextBuilt => "context",
        AgentEventKind::ModelStarted => "model",
        AgentEventKind::ModelCompleted => "model",
        AgentEventKind::ToolStarted => "tool",
        AgentEventKind::ToolCompleted => "tool",
        AgentEventKind::ApprovalRequested => "approval",
        AgentEventKind::TurnCompleted => "done",
        AgentEventKind::Error => "error",
    };

    format!("{label}: {}", event.message)
}

#[cfg(test)]
mod tests {
    use super::render_event_line;
    use holt_protocol::{AgentEvent, AgentEventKind};

    #[test]
    fn renders_protocol_events_for_ui() {
        let line = render_event_line(&AgentEvent::new(AgentEventKind::ContextBuilt, "12 files"));
        assert_eq!(line, "context: 12 files");
    }
}
