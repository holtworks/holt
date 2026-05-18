//! Built-in action registry and local action executor for the native runtime.

use anyhow::{anyhow, Context, Result};
use holt_protocol::{EffectRisk, ActionCall, ActionResult, ActionSpec, ActionStatus};
use holt_workspace::WorkspaceScanner;
use std::fs;
use std::path::{Path, PathBuf};

pub fn builtin_actions() -> Vec<ActionSpec> {
    vec![
        ActionSpec {
            name: "list".to_string(),
            description: "List workspace files.".to_string(),
            risk: EffectRisk::Read,
            approval_required: false,
        },
        ActionSpec {
            name: "read".to_string(),
            description: "Read a UTF-8 workspace file.".to_string(),
            risk: EffectRisk::Read,
            approval_required: false,
        },
        ActionSpec {
            name: "search".to_string(),
            description: "Search UTF-8 workspace files.".to_string(),
            risk: EffectRisk::Read,
            approval_required: false,
        },
    ]
}

pub struct LocalActionExecutor {
    workspace: PathBuf,
}

impl LocalActionExecutor {
    pub fn new(workspace: impl Into<PathBuf>) -> Self {
        Self {
            workspace: workspace.into(),
        }
    }

    pub fn execute(&self, call: &ActionCall) -> ActionResult {
        match self.execute_inner(call) {
            Ok(content) => ActionResult {
                call_id: call.id.clone(),
                status: ActionStatus::Ok,
                content,
            },
            Err(error) => ActionResult {
                call_id: call.id.clone(),
                status: ActionStatus::Error,
                content: error.to_string(),
            },
        }
    }

    fn execute_inner(&self, call: &ActionCall) -> Result<String> {
        match call.name.as_str() {
            "list" => {
                let snapshot = WorkspaceScanner::default().scan(&self.workspace)?;
                Ok(snapshot
                    .files
                    .into_iter()
                    .map(|file| file.path)
                    .collect::<Vec<_>>()
                    .join("\n"))
            }
            "read" => {
                let args: serde_json::Value = serde_json::from_str(&call.args_json)?;
                let path = args
                    .get("path")
                    .and_then(|value| value.as_str())
                    .ok_or_else(|| anyhow!("missing path"))?;
                fs::read_to_string(self.safe_path(path)?).context("read file")
            }
            "search" => {
                let args: serde_json::Value = serde_json::from_str(&call.args_json)?;
                let query = args
                    .get("query")
                    .and_then(|value| value.as_str())
                    .ok_or_else(|| anyhow!("missing query"))?;
                self.search(query)
            }
            other => Err(anyhow!("unknown action {other}")),
        }
    }

    fn safe_path(&self, path: &str) -> Result<PathBuf> {
        let target = self.workspace.join(path);
        let normalized = normalize_path(&target)?;
        let root = normalize_path(&self.workspace)?;

        if normalized.starts_with(&root) {
            Ok(normalized)
        } else {
            Err(anyhow!("path escapes workspace"))
        }
    }

    fn search(&self, query: &str) -> Result<String> {
        let snapshot = WorkspaceScanner::default().scan(&self.workspace)?;
        let mut matches = Vec::new();

        for file in snapshot.files.into_iter().take(300) {
            let path = self.safe_path(&file.path)?;
            let Ok(content) = fs::read_to_string(path) else {
                continue;
            };

            for (line_index, line) in content.lines().enumerate() {
                if line.contains(query) {
                    matches.push(format!("{}:{}: {}", file.path, line_index + 1, line));
                }
            }
        }

        Ok(matches.join("\n"))
    }
}

fn normalize_path(path: &Path) -> Result<PathBuf> {
    if path.exists() {
        Ok(path.canonicalize()?)
    } else {
        let parent = path
            .parent()
            .ok_or_else(|| anyhow!("path has no parent"))?
            .canonicalize()?;
        Ok(parent.join(path.file_name().unwrap_or_default()))
    }
}

#[cfg(test)]
mod tests {
    use super::LocalActionExecutor;
    use holt_protocol::{ActionCall, ActionStatus};
    use std::fs;

    #[test]
    fn read_blocks_workspace_escape() {
        let root = std::env::temp_dir().join(format!("holt-actions-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).unwrap();
        fs::write(root.join("README.md"), "# Demo").unwrap();

        let executor = LocalActionExecutor::new(&root);
        let result = executor.execute(&ActionCall {
            id: "call-1".to_string(),
            name: "read".to_string(),
            args_json: r#"{"path":"../outside"}"#.to_string(),
        });

        assert_eq!(result.status, ActionStatus::Error);
        assert!(result.content.contains("escapes workspace"));

        let _ = fs::remove_dir_all(&root);
    }
}
