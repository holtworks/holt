//! Typed protocol shared by Holt UI, runtime, tools, and adapters.

use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct TurnRequest {
    pub objective: String,
    pub workspace: String,
    pub chat_context: Vec<ChatMessage>,
    pub approval_mode: ApprovalMode,
}

impl TurnRequest {
    pub fn new(objective: impl Into<String>, workspace: impl Into<String>) -> Self {
        Self {
            objective: objective.into(),
            workspace: workspace.into(),
            chat_context: Vec::new(),
            approval_mode: ApprovalMode::Ask,
        }
    }

    pub fn with_chat_context(mut self, messages: Vec<ChatMessage>) -> Self {
        self.chat_context = messages;
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
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
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
    ToolStarted,
    ToolCompleted,
    ApprovalRequested,
    TurnCompleted,
    Error,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ToolSpec {
    pub name: String,
    pub description: String,
    pub risk: EffectRisk,
    pub approval_required: bool,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ToolCall {
    pub id: String,
    pub name: String,
    pub args_json: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ToolResult {
    pub call_id: String,
    pub status: ToolStatus,
    pub content: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum ToolStatus {
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
    fn turn_request_carries_chat_context_and_policy() {
        let request = TurnRequest::new("read this repo", "/tmp/work")
            .with_chat_context(vec![ChatMessage::user("hello")])
            .with_approval_mode(ApprovalMode::AutoApprove);

        assert_eq!(request.objective, "read this repo");
        assert_eq!(request.chat_context[0].content, "hello");
        assert_eq!(request.approval_mode, ApprovalMode::AutoApprove);
    }
}
