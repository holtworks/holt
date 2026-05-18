//! Typed protocol shared by Holt UI, runtime, actions, and adapters.

use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct TurnRequest {
    pub objective: String,
    pub workspace: String,
    pub chat_messages: Vec<ChatMessage>,
    pub approval_mode: ApprovalMode,
}

impl TurnRequest {
    pub fn new(objective: impl Into<String>, workspace: impl Into<String>) -> Self {
        Self {
            objective: objective.into(),
            workspace: workspace.into(),
            chat_messages: Vec::new(),
            approval_mode: ApprovalMode::Ask,
        }
    }

    pub fn with_chat_messages(mut self, messages: Vec<ChatMessage>) -> Self {
        self.chat_messages = messages;
        self
    }

    pub fn with_approval_mode(mut self, approval_mode: ApprovalMode) -> Self {
        self.approval_mode = approval_mode;
        self
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ChatMessage {
    pub role: ChatRole,
    pub content: String,
}

impl ChatMessage {
    pub fn user(content: impl Into<String>) -> Self {
        Self {
            role: ChatRole::User,
            content: content.into(),
        }
    }

    pub fn assistant(content: impl Into<String>) -> Self {
        Self {
            role: ChatRole::Assistant,
            content: content.into(),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ChatRole {
    User,
    Assistant,
    System,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum ApprovalMode {
    Ask,
    AutoApprove,
    DenyWrites,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct AgentResponse {
    pub output: String,
    pub events: Vec<AgentEvent>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct AgentEvent {
    pub kind: AgentEventKind,
    pub message: String,
}

impl AgentEvent {
    pub fn new(kind: AgentEventKind, message: impl Into<String>) -> Self {
        Self {
            kind,
            message: message.into(),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum AgentEventKind {
    SessionStarted,
    ContextBuilt,
    ModelStarted,
    ModelCompleted,
    ActionStarted,
    ActionCompleted,
    ApprovalRequested,
    TurnCompleted,
    Error,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ActionSpec {
    pub name: String,
    pub description: String,
    pub risk: EffectRisk,
    pub approval_required: bool,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ActionCall {
    pub id: String,
    pub name: String,
    pub args_json: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ActionResult {
    pub call_id: String,
    pub status: ActionStatus,
    pub content: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum ActionStatus {
    Ok,
    Error,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum EffectRisk {
    Read,
    Write,
    Execute,
    Network,
}

#[cfg(test)]
mod tests {
    use super::{ApprovalMode, ChatMessage, TurnRequest};

    #[test]
    fn turn_request_carries_chat_messages_and_policy() {
        let request = TurnRequest::new("read this repo", "/tmp/work")
            .with_chat_messages(vec![ChatMessage::user("hello")])
            .with_approval_mode(ApprovalMode::AutoApprove);

        assert_eq!(request.objective, "read this repo");
        assert_eq!(request.chat_messages[0].content, "hello");
        assert_eq!(request.approval_mode, ApprovalMode::AutoApprove);
    }

    #[test]
    fn chat_role_serializes_to_provider_role_names() {
        let json = serde_json::to_string(&ChatMessage::assistant("pick one")).unwrap();
        assert_eq!(json, r#"{"role":"assistant","content":"pick one"}"#);
    }
}
