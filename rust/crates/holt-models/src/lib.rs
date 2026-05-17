//! Model provider boundary for the native Holt runtime.

use anyhow::Result;
use holt_protocol::ChatMessage;

pub trait ModelProvider {
    fn complete(&self, messages: &[ChatMessage]) -> Result<String>;
}

#[derive(Default)]
pub struct LocalModelProvider;

impl ModelProvider for LocalModelProvider {
    fn complete(&self, messages: &[ChatMessage]) -> Result<String> {
        let latest = messages
            .iter()
            .rev()
            .find(|message| matches!(message.role, holt_protocol::ChatRole::User))
            .map(|message| message.content.as_str())
            .unwrap_or("");

        Ok(format!("Local Holt model received: {latest}"))
    }
}

#[cfg(test)]
mod tests {
    use super::{LocalModelProvider, ModelProvider};
    use holt_protocol::ChatMessage;

    #[test]
    fn local_model_uses_latest_user_message() {
        let provider = LocalModelProvider;
        let output = provider.complete(&[ChatMessage::user("hello")]).unwrap();
        assert_eq!(output, "Local Holt model received: hello");
    }
}
