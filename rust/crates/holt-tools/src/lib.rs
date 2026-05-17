//! Built-in tool registry and local tool executor for the native runtime.

use anyhow::{anyhow, Context, Result};
use holt_protocol::{EffectRisk, ToolCall, ToolResult, ToolSpec, ToolStatus};
use holt_workspace::WorkspaceScanner;
use std::fs;
use std::path::{Path, PathBuf};

pub fn builtin_tools() -> Vec<ToolSpec> {
    vec![
        ToolSpec {
            name: "list_files".to_string(),
            description: "List workspace files.".to_string(),
            risk: EffectRisk::Read,
            approval_required: false,
        },
        ToolSpec {
            name: "read_file".to_string(),
            description: "Read a UTF-8 workspace file.".to_string(),
            risk: EffectRisk::Read,
            approval_required: false,
        },
        ToolSpec {
            name: "search_files".to_string(),
            description: "Search UTF-8 workspace files.".to_string(),
            risk: EffectRisk::Read,
            approval_required: false,
        },
    ]
}

pub struct LocalToolExecutor {
    workspace: PathBuf,
}

impl LocalToolExecutor {
    pub fn new(workspace: impl Into<PathBuf>) -> Self {
        Self {
            workspace: workspace.into(),
        }
    }

    pub fn execute(&self, call: &ToolCall) -> ToolResult {
        match self.execute_inner(call) {
            Ok(content) => ToolResult {
                call_id: call.id.clone(),
                status: ToolStatus::Ok,
                content,
            },
            Err(error) => ToolResult {
                call_id: call.id.clone(),
                status: ToolStatus::Error,
                content: error.to_string(),
            },
        }
    }

    fn execute_inner(&self, call: &ToolCall) -> Result<String> {
        match call.name.as_str() {
            "list_files" => {
                let snapshot = WorkspaceScanner::default().scan(&self.workspace)?;
                Ok(snapshot
                    .files
                    .into_iter()
                    .map(|file| file.path)
                    .collect::<Vec<_>>()
                    .join("\n"))
            }
            "read_file" => {
                let args: serde_json::Value = serde_json::from_str(&call.args_json)?;
                let path = args
                    .get("path")
                    .and_then(|value| value.as_str())
                    .ok_or_else(|| anyhow!("missing path"))?;
                fs::read_to_string(self.safe_path(path)?).context("read file")
            }
            "search_files" => {
                let args: serde_json::Value = serde_json::from_str(&call.args_json)?;
                let query = args
                    .get("query")
                    .and_then(|value| value.as_str())
                    .ok_or_else(|| anyhow!("missing query"))?;
                self.search_files(query)
            }
            other => Err(anyhow!("unknown tool {other}")),
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

    fn search_files(&self, query: &str) -> Result<String> {
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
    use super::LocalToolExecutor;
    use holt_protocol::{ToolCall, ToolStatus};
    use std::fs;

    #[test]
    fn read_file_blocks_workspace_escape() {
        let root = std::env::temp_dir().join(format!("holt-tools-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).unwrap();
        fs::write(root.join("README.md"), "# Demo").unwrap();

        let executor = LocalToolExecutor::new(&root);
        let result = executor.execute(&ToolCall {
            id: "call-1".to_string(),
            name: "read_file".to_string(),
            args_json: r#"{"path":"../outside"}"#.to_string(),
        });

        assert_eq!(result.status, ToolStatus::Error);
        assert!(result.content.contains("escapes workspace"));

        let _ = fs::remove_dir_all(&root);
    }
}
