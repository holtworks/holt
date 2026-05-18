use anyhow::{Context, Result};
use serde_json::{json, Value};
use std::{
    fs::{self, OpenOptions},
    io::Write,
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

const HISTORY_SCHEMA_VERSION: &str = "holt_cli_history_entry/v1";
const HISTORY_LIMIT: usize = 200;
pub(crate) const HISTORY_DISPLAY_LIMIT: usize = 20;

pub(crate) fn load_prompt_history(workspace: &Path) -> Vec<String> {
    read_prompt_history(workspace).unwrap_or_default()
}

pub(crate) fn remember_prompt(
    history: &mut Vec<String>,
    workspace: &Path,
    prompt: &str,
) -> Result<()> {
    let prompt = prompt.trim();

    if prompt.is_empty() || history.last().is_some_and(|last| last == prompt) {
        return Ok(());
    }

    history.push(prompt.to_string());
    if !workspace_history_exists(workspace) {
        return Ok(());
    }

    append_prompt(workspace, prompt)
}

pub(crate) fn append_prompt(workspace: &Path, prompt: &str) -> Result<()> {
    let prompt = prompt.trim();

    if prompt.is_empty() {
        return Ok(());
    }

    if read_prompt_history(workspace)
        .unwrap_or_default()
        .last()
        .is_some_and(|last| last == prompt)
    {
        return Ok(());
    }

    let path = history_path(workspace);
    let Some(parent) = path.parent() else {
        return Ok(());
    };

    fs::create_dir_all(parent)
        .with_context(|| format!("failed to create history directory {}", parent.display()))?;

    let entry = json!({
        "schema_version": HISTORY_SCHEMA_VERSION,
        "kind": "user_prompt",
        "prompt": prompt,
        "created_at_unix_ms": now_unix_ms(),
    });

    let mut file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
        .with_context(|| format!("failed to open history file {}", path.display()))?;

    serde_json::to_writer(&mut file, &entry)
        .with_context(|| format!("failed to encode history entry {}", path.display()))?;
    file.write_all(b"\n")
        .with_context(|| format!("failed to write history entry {}", path.display()))?;

    Ok(())
}

pub(crate) fn recent_prompt_rows(history: &[String], limit: usize) -> Vec<String> {
    let total = history.len();

    history
        .iter()
        .enumerate()
        .rev()
        .take(limit)
        .map(|(index, prompt)| format!("{:>3}. {prompt}", index + 1))
        .collect::<Vec<_>>()
        .into_iter()
        .take(total)
        .collect()
}

pub(crate) fn previous_prompt_match(
    history: &[String],
    query: &str,
    before: Option<usize>,
) -> Option<usize> {
    if history.is_empty() {
        return None;
    }

    let query = query.trim().to_lowercase();
    let mut index = before.unwrap_or(history.len()).min(history.len());

    for _ in 0..history.len() {
        if index == 0 {
            index = history.len();
        }
        index -= 1;

        if query.is_empty() || history[index].to_lowercase().contains(&query) {
            return Some(index);
        }
    }

    None
}

fn read_prompt_history(workspace: &Path) -> Result<Vec<String>> {
    let path = history_path(workspace);
    let content = match fs::read_to_string(&path) {
        Ok(content) => content,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => {
            return Err(error).with_context(|| format!("failed to read {}", path.display()))
        }
    };

    let mut prompts = content
        .lines()
        .filter_map(prompt_from_line)
        .collect::<Vec<_>>();

    if prompts.len() > HISTORY_LIMIT {
        prompts = prompts.split_off(prompts.len() - HISTORY_LIMIT);
    }

    Ok(prompts)
}

fn prompt_from_line(line: &str) -> Option<String> {
    let value: Value = serde_json::from_str(line).ok()?;

    if value.get("schema_version")?.as_str()? != HISTORY_SCHEMA_VERSION {
        return None;
    }

    if value.get("kind")?.as_str()? != "user_prompt" {
        return None;
    }

    value
        .get("prompt")?
        .as_str()
        .map(str::trim)
        .filter(|prompt| !prompt.is_empty())
        .map(str::to_string)
}

fn history_path(workspace: &Path) -> PathBuf {
    workspace.join(".holtworks").join("cli_history.jsonl")
}

fn workspace_history_exists(workspace: &Path) -> bool {
    history_path(workspace)
        .parent()
        .is_some_and(|parent| parent.is_dir())
}

fn now_unix_ms() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis())
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::{
        append_prompt, history_path, load_prompt_history, previous_prompt_match,
        recent_prompt_rows, remember_prompt, HISTORY_LIMIT,
    };
    use serde_json::Value;
    use std::{
        fs,
        path::PathBuf,
        sync::atomic::{AtomicUsize, Ordering},
        time::{SystemTime, UNIX_EPOCH},
    };

    static TEMP_COUNTER: AtomicUsize = AtomicUsize::new(0);

    #[test]
    fn persists_prompt_history_as_structured_jsonl() {
        let workspace = temp_workspace();

        append_prompt(&workspace, "first prompt").unwrap();
        append_prompt(&workspace, "second prompt").unwrap();
        append_prompt(&workspace, "   ").unwrap();

        assert_eq!(
            load_prompt_history(&workspace),
            vec!["first prompt".to_string(), "second prompt".to_string()]
        );

        let content = fs::read_to_string(history_path(&workspace)).unwrap();
        let first: Value = serde_json::from_str(content.lines().next().unwrap()).unwrap();

        assert_eq!(
            first["schema_version"].as_str(),
            Some("holt_cli_history_entry/v1")
        );
        assert_eq!(first["kind"].as_str(), Some("user_prompt"));
        assert_eq!(first["prompt"].as_str(), Some("first prompt"));
        assert!(first["created_at_unix_ms"].as_u64().is_some());

        let _ = fs::remove_dir_all(workspace);
    }

    #[test]
    fn skips_consecutive_duplicate_prompt_history_entries() {
        let workspace = temp_workspace();

        append_prompt(&workspace, "repeat prompt").unwrap();
        append_prompt(&workspace, "repeat prompt").unwrap();
        append_prompt(&workspace, "other prompt").unwrap();
        append_prompt(&workspace, "repeat prompt").unwrap();

        assert_eq!(
            load_prompt_history(&workspace),
            vec![
                "repeat prompt".to_string(),
                "other prompt".to_string(),
                "repeat prompt".to_string()
            ]
        );

        let _ = fs::remove_dir_all(workspace);
    }

    #[test]
    fn remember_prompt_updates_memory_and_disk_once() {
        let workspace = temp_workspace();
        fs::create_dir_all(history_path(&workspace).parent().unwrap()).unwrap();
        let mut history = Vec::new();

        remember_prompt(&mut history, &workspace, "draft prompt").unwrap();
        remember_prompt(&mut history, &workspace, "draft prompt").unwrap();

        assert_eq!(history, vec!["draft prompt".to_string()]);
        assert_eq!(load_prompt_history(&workspace), history);

        let _ = fs::remove_dir_all(workspace);
    }

    #[test]
    fn remember_prompt_does_not_create_workspace_history() {
        let workspace = temp_workspace();
        let mut history = Vec::new();

        remember_prompt(&mut history, &workspace, "casual chat").unwrap();

        assert_eq!(history, vec!["casual chat".to_string()]);
        assert!(!history_path(&workspace).exists());
        assert!(!workspace.join(".holtworks").exists());

        let _ = fs::remove_dir_all(workspace);
    }

    #[test]
    fn loads_only_recent_canonical_prompt_entries() {
        let workspace = temp_workspace();
        let path = history_path(&workspace);
        fs::create_dir_all(path.parent().unwrap()).unwrap();

        let mut rows = vec![
            r#"{"schema_version":"old_history/v1","kind":"user_prompt","prompt":"legacy"}"#.to_string(),
            r#"{"schema_version":"holt_cli_history_entry/v1","kind":"system","prompt":"not a prompt"}"#.to_string(),
            "not json".to_string(),
        ];

        for index in 0..(HISTORY_LIMIT + 3) {
            rows.push(format!(
                r#"{{"schema_version":"holt_cli_history_entry/v1","kind":"user_prompt","prompt":"prompt {index}","created_at_unix_ms":1}}"#
            ));
        }

        fs::write(&path, rows.join("\n")).unwrap();

        let prompts = load_prompt_history(&workspace);
        assert_eq!(prompts.len(), HISTORY_LIMIT);
        assert_eq!(prompts.first().map(String::as_str), Some("prompt 3"));
        let expected_last = format!("prompt {}", HISTORY_LIMIT + 2);
        assert_eq!(
            prompts.last().map(String::as_str),
            Some(expected_last.as_str())
        );

        let _ = fs::remove_dir_all(workspace);
    }

    #[test]
    fn formats_recent_prompt_rows_newest_first_with_original_numbers() {
        let history = vec![
            "first".to_string(),
            "second".to_string(),
            "third".to_string(),
        ];

        assert_eq!(
            recent_prompt_rows(&history, 2),
            vec!["  3. third".to_string(), "  2. second".to_string()]
        );
    }

    #[test]
    fn finds_previous_prompt_match_with_wraparound() {
        let history = vec![
            "edit README".to_string(),
            "run tests".to_string(),
            "show diff".to_string(),
            "edit diff renderer".to_string(),
        ];

        assert_eq!(previous_prompt_match(&history, "DIFF", None), Some(3));
        assert_eq!(previous_prompt_match(&history, "DIFF", Some(3)), Some(2));
        assert_eq!(previous_prompt_match(&history, "DIFF", Some(2)), Some(3));
        assert_eq!(previous_prompt_match(&history, "missing", None), None);
    }

    fn temp_workspace() -> PathBuf {
        let millis = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_millis();
        let counter = TEMP_COUNTER.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "holt-cli-history-test-{}-{millis}-{counter}",
            std::process::id()
        ));
        fs::create_dir_all(&path).unwrap();
        path
    }
}
