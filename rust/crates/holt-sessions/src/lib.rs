//! In-memory session model used by the native runtime and TUI.

use holt_protocol::ChatMessage;
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct SessionState {
    pub id: String,
    pub turns: Vec<ChatMessage>,
}

impl SessionState {
    pub fn new(id: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            turns: Vec::new(),
        }
    }

    pub fn push(&mut self, message: ChatMessage) {
        self.turns.push(message);
    }

    pub fn recent_chat_messages(&self, limit: usize) -> Vec<ChatMessage> {
        self.turns
            .iter()
            .rev()
            .take(limit)
            .cloned()
            .collect::<Vec<_>>()
            .into_iter()
            .rev()
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::SessionState;
    use holt_protocol::ChatMessage;

    #[test]
    fn session_returns_recent_chat_messages_in_order() {
        let mut session = SessionState::new("session-1");
        session.push(ChatMessage::user("first"));
        session.push(ChatMessage::assistant("first response"));
        session.push(ChatMessage::user("second"));

        let messages = session.recent_chat_messages(2);
        assert_eq!(messages[0].content, "first response");
        assert_eq!(messages[1].content, "second");
    }
}
