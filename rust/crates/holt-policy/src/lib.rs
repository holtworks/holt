//! Runtime policy decisions for actions and agent actions.

use holt_protocol::{ApprovalMode, EffectRisk, ActionSpec};
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct PolicyDecision {
    pub allowed: bool,
    pub approval_required: bool,
    pub reason_code: String,
}

pub fn decide_action(action: &ActionSpec, approval_mode: &ApprovalMode) -> PolicyDecision {
    match (approval_mode, &action.risk) {
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
            approval_required: action.approval_required,
            reason_code: "approval_required".to_string(),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::decide_action;
    use holt_protocol::{ApprovalMode, EffectRisk, ActionSpec};

    #[test]
    fn denies_write_actions_in_deny_writes_mode() {
        let action = ActionSpec {
            name: "write".to_string(),
            description: "write".to_string(),
            risk: EffectRisk::Write,
            approval_required: true,
        };

        let decision = decide_action(&action, &ApprovalMode::DenyWrites);
        assert!(!decision.allowed);
        assert_eq!(decision.reason_code, "policy_denied_side_effect");
    }
}
