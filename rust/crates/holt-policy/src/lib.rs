//! Runtime policy decisions for tools and agent actions.

use holt_protocol::{ApprovalMode, EffectRisk, ToolSpec};
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct PolicyDecision {
    pub allowed: bool,
    pub approval_required: bool,
    pub reason_code: String,
}

pub fn decide_tool(tool: &ToolSpec, approval_mode: &ApprovalMode) -> PolicyDecision {
    match (approval_mode, &tool.risk) {
        (
            ApprovalMode::DenyWrites,
            EffectRisk::Write | EffectRisk::Execute | EffectRisk::Network,
        ) => PolicyDecision {
            allowed: false,
            approval_required: false,
            reason_code: "policy_denied_side_effect".to_string(),
        },
        (ApprovalMode::AutoApprove, _) => PolicyDecision {
            allowed: true,
            approval_required: false,
            reason_code: "auto_approved".to_string(),
        },
        (_, EffectRisk::Read) => PolicyDecision {
            allowed: true,
            approval_required: false,
            reason_code: "read_only".to_string(),
        },
        _ => PolicyDecision {
            allowed: true,
            approval_required: tool.approval_required,
            reason_code: "approval_required".to_string(),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::decide_tool;
    use holt_protocol::{ApprovalMode, EffectRisk, ToolSpec};

    #[test]
    fn denies_write_tools_in_deny_writes_mode() {
        let tool = ToolSpec {
            name: "write_file".to_string(),
            description: "write".to_string(),
            risk: EffectRisk::Write,
            approval_required: true,
        };

        let decision = decide_tool(&tool, &ApprovalMode::DenyWrites);
        assert!(!decision.allowed);
        assert_eq!(decision.reason_code, "policy_denied_side_effect");
    }
}
