//! Workspace scanning and context packing for the native Holt runtime.

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct WorkspaceSnapshot {
    pub root: PathBuf,
    pub files: Vec<WorkspaceFile>,
    pub key_files: Vec<KeyFile>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct WorkspaceFile {
    pub path: String,
    pub kind: FileKind,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct KeyFile {
    pub path: String,
    pub excerpt: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum FileKind {
    Doc,
    Config,
    Source,
    Test,
    Other,
}

pub struct WorkspaceScanner {
    limit: usize,
}

impl Default for WorkspaceScanner {
    fn default() -> Self {
        Self { limit: 500 }
    }
}

impl WorkspaceScanner {
    pub fn with_limit(limit: usize) -> Self {
        Self { limit }
    }

    pub fn scan(&self, root: impl AsRef<Path>) -> Result<WorkspaceSnapshot> {
        let root = root.as_ref().to_path_buf();
        let mut paths = Vec::new();
        walk(&root, &root, self.limit, &mut paths)?;
        paths.sort();

        let files = paths
            .iter()
            .map(|path| WorkspaceFile {
                path: path.clone(),
                kind: classify(path),
            })
            .collect::<Vec<_>>();

        let key_files = select_key_files(&paths)
            .into_iter()
            .filter_map(|path| read_key_file(&root, &path).ok())
            .collect::<Vec<_>>();

        Ok(WorkspaceSnapshot {
            root,
            files,
            key_files,
        })
    }
}

fn walk(root: &Path, current: &Path, limit: usize, paths: &mut Vec<String>) -> Result<()> {
    if paths.len() >= limit {
        return Ok(());
    }

    let entries = fs::read_dir(current).with_context(|| format!("read {}", current.display()))?;

    for entry in entries {
        if paths.len() >= limit {
            break;
        }

        let entry = entry?;
        let path = entry.path();
        let file_name = entry.file_name();
        let file_name = file_name.to_string_lossy();

        if ignored_entry(&file_name) {
            continue;
        }

        if path.is_dir() {
            walk(root, &path, limit, paths)?;
        } else if path.is_file() {
            paths.push(
                path.strip_prefix(root)?
                    .to_string_lossy()
                    .replace('\\', "/"),
            );
        }
    }

    Ok(())
}

fn ignored_entry(name: &str) -> bool {
    matches!(
        name,
        ".git"
            | ".hg"
            | ".svn"
            | ".holt"
            | ".holtworks"
            | "target"
            | "_build"
            | "deps"
            | "node_modules"
            | ".DS_Store"
    )
}

fn select_key_files(files: &[String]) -> Vec<String> {
    let mut selected = files
        .iter()
        .filter(|path| root_doc_or_config(path))
        .cloned()
        .collect::<Vec<_>>();
    selected.sort_by_key(|path| root_rank(path));

    let mut by_area =
        representative_by_area(files, |path| matches!(classify(path), FileKind::Source));
    let mut tests = representative_by_area(files, |path| matches!(classify(path), FileKind::Test));

    selected.truncate(5);
    by_area.truncate(5);
    tests.truncate(2);

    selected.extend(by_area);
    selected.extend(tests);
    selected.sort();
    selected.dedup();
    selected.truncate(8);
    selected
}

fn representative_by_area<F>(files: &[String], predicate: F) -> Vec<String>
where
    F: Fn(&str) -> bool,
{
    let mut selected = Vec::new();
    let mut seen = Vec::<String>::new();

    for file in files.iter().filter(|path| predicate(path)) {
        let area = top_level_area(file);
        if !seen.iter().any(|value| value == &area) {
            seen.push(area);
            selected.push(file.clone());
        }
    }

    selected.sort_by_key(|path| path.split('/').count());
    selected
}

fn read_key_file(root: &Path, path: &str) -> Result<KeyFile> {
    let content = fs::read_to_string(root.join(path))?;
    Ok(KeyFile {
        path: path.to_string(),
        excerpt: content.chars().take(1_200).collect(),
    })
}

fn classify(path: &str) -> FileKind {
    if test_path(path) {
        FileKind::Test
    } else if root_doc_or_config(path) && markdown_path(path) {
        FileKind::Doc
    } else if root_doc_or_config(path) {
        FileKind::Config
    } else if source_path(path) {
        FileKind::Source
    } else {
        FileKind::Other
    }
}

fn root_doc_or_config(path: &str) -> bool {
    !path.contains('/') && (markdown_path(path) || config_extension(extension(path)))
}

fn markdown_path(path: &str) -> bool {
    extension(path) == "md" || extension(path) == "txt"
}

fn test_path(path: &str) -> bool {
    path.split('/')
        .any(|part| matches!(part, "test" | "tests" | "spec" | "specs" | "__tests__"))
}

fn source_path(path: &str) -> bool {
    matches!(
        extension(path).as_str(),
        "ex" | "exs"
            | "rs"
            | "ts"
            | "tsx"
            | "js"
            | "jsx"
            | "py"
            | "go"
            | "rb"
            | "java"
            | "kt"
            | "swift"
            | "c"
            | "h"
            | "cpp"
            | "hpp"
            | "cs"
    )
}

fn config_extension(extension: String) -> bool {
    matches!(
        extension.as_str(),
        "json" | "toml" | "yaml" | "yml" | "xml" | "ini" | "env"
    )
}

fn extension(path: &str) -> String {
    Path::new(path)
        .extension()
        .map(|value| value.to_string_lossy().to_lowercase())
        .unwrap_or_default()
}

fn root_rank(path: &str) -> u8 {
    let name = path.to_lowercase();
    if name.starts_with("readme") {
        0
    } else if markdown_path(path) {
        1
    } else {
        2
    }
}

fn top_level_area(path: &str) -> String {
    path.split('/').next().unwrap_or(".").to_string()
}

#[cfg(test)]
mod tests {
    use super::{select_key_files, FileKind, WorkspaceScanner};
    use std::fs;

    #[test]
    fn scanner_selects_generic_key_files_without_project_specific_paths() {
        let root = std::env::temp_dir().join(format!("holt-workspace-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(root.join("src")).unwrap();
        fs::create_dir_all(root.join("tests")).unwrap();
        fs::create_dir_all(root.join(".holtworks/runs")).unwrap();
        fs::write(root.join("README.md"), "# Demo").unwrap();
        fs::write(root.join("Cargo.toml"), "[package]").unwrap();
        fs::write(root.join("src/main.rs"), "fn main() {}").unwrap();
        fs::write(root.join("tests/main.rs"), "#[test] fn works() {}").unwrap();
        fs::write(root.join(".holtworks/runs/run.json"), "{}").unwrap();

        let snapshot = WorkspaceScanner::default().scan(&root).unwrap();
        let names = snapshot
            .key_files
            .iter()
            .map(|file| file.path.as_str())
            .collect::<Vec<_>>();

        assert!(names.contains(&"README.md"));
        assert!(names.contains(&"src/main.rs"));
        assert!(snapshot
            .files
            .iter()
            .any(|file| file.kind == FileKind::Test));
        assert!(!snapshot
            .files
            .iter()
            .any(|file| file.path.starts_with(".holtworks/")));

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn key_selection_is_generic() {
        let files = vec![
            "README.md".to_string(),
            "app/root.py".to_string(),
            "tests/root_test.py".to_string(),
        ];

        assert_eq!(select_key_files(&files)[0], "README.md");
    }
}
