//! Minimal telemetry sink for native Holt runtime events.

use holt_protocol::AgentEvent;
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct TraceEvent {
    pub sequence: usize,
    pub event: AgentEvent,
}

#[derive(Default)]
pub struct InMemoryTelemetry {
    events: Vec<TraceEvent>,
}

impl InMemoryTelemetry {
    pub fn record(&mut self, event: AgentEvent) {
        self.events.push(TraceEvent {
            sequence: self.events.len() + 1,
            event,
        });
    }

    pub fn events(&self) -> &[TraceEvent] {
        &self.events
    }
}

#[cfg(test)]
mod tests {
    use super::InMemoryTelemetry;
    use holt_protocol::{AgentEvent, AgentEventKind};

    #[test]
    fn telemetry_assigns_monotonic_sequence_numbers() {
        let mut telemetry = InMemoryTelemetry::default();
        telemetry.record(AgentEvent::new(AgentEventKind::SessionStarted, "start"));
        telemetry.record(AgentEvent::new(AgentEventKind::TurnCompleted, "done"));

        assert_eq!(telemetry.events()[1].sequence, 2);
    }
}
