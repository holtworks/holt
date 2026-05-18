use crate::commands::KeyBindingSpec;
use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use serde_json::Value;
use std::{
    fs,
    io::ErrorKind,
    path::{Path, PathBuf},
};

const KEYMAP_SCHEMA_VERSION: &str = "holt_cli_keymap/v1";
const TRANSCRIPT_SCOPE: &str = "tui transcript";

const ACTION_PREVIOUS_BLOCK: &str = "transcript.previous_block";
const ACTION_NEXT_BLOCK: &str = "transcript.next_block";
const ACTION_PREVIOUS_DIFF: &str = "transcript.previous_diff";
const ACTION_NEXT_DIFF: &str = "transcript.next_diff";
const ACTION_TOGGLE_BLOCK: &str = "transcript.toggle_block";
const ACTION_OPEN_PAGER: &str = "transcript.open_pager";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum TranscriptKeyAction {
    PreviousBlock,
    NextBlock,
    PreviousDiff,
    NextDiff,
    ToggleBlock,
    OpenPager,
}

impl TranscriptKeyAction {
    fn from_id(action_id: &str) -> Result<Self, String> {
        match action_id {
            ACTION_PREVIOUS_BLOCK => Ok(Self::PreviousBlock),
            ACTION_NEXT_BLOCK => Ok(Self::NextBlock),
            ACTION_PREVIOUS_DIFF => Ok(Self::PreviousDiff),
            ACTION_NEXT_DIFF => Ok(Self::NextDiff),
            ACTION_TOGGLE_BLOCK => Ok(Self::ToggleBlock),
            ACTION_OPEN_PAGER => Ok(Self::OpenPager),
            _ => Err(format!("unsupported keymap action: {action_id}")),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum KeyChord {
    Char(char),
    Ctrl(char),
}

impl KeyChord {
    fn parse(input: &str) -> Result<Self, String> {
        if input.trim() != input {
            return Err(format!("unsupported key {input}"));
        }

        if let Some(key) = input.strip_prefix("Ctrl+") {
            let mut chars = key.chars();
            let Some(ch) = chars.next() else {
                return Err(format!("unsupported key {input}"));
            };

            if chars.next().is_none() && ch.is_ascii_alphabetic() {
                return Ok(Self::Ctrl(ch.to_ascii_lowercase()));
            }

            return Err(format!("unsupported key {input}"));
        }

        let mut chars = input.chars();
        let Some(ch) = chars.next() else {
            return Err(format!("unsupported key {input}"));
        };

        if chars.next().is_none() && !ch.is_whitespace() && !ch.is_control() && !input.contains('+')
        {
            return Ok(Self::Char(ch));
        }

        Err(format!("unsupported key {input}"))
    }

    fn display(self) -> String {
        match self {
            Self::Char(ch) => ch.to_string(),
            Self::Ctrl(ch) => format!("Ctrl+{}", ch.to_ascii_uppercase()),
        }
    }

    fn matches(self, key: KeyEvent) -> bool {
        match self {
            Self::Char(expected) => {
                !key.modifiers.contains(KeyModifiers::CONTROL)
                    && !key.modifiers.contains(KeyModifiers::ALT)
                    && matches!(key.code, KeyCode::Char(actual) if actual == expected)
            }
            Self::Ctrl(expected) => {
                key.modifiers.contains(KeyModifiers::CONTROL)
                    && !key.modifiers.contains(KeyModifiers::ALT)
                    && matches!(
                        key.code,
                        KeyCode::Char(actual) if actual.to_ascii_lowercase() == expected
                    )
            }
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct Keymap {
    transcript_previous_block: KeyChord,
    transcript_next_block: KeyChord,
    transcript_previous_diff: KeyChord,
    transcript_next_diff: KeyChord,
    transcript_toggle_block: KeyChord,
    transcript_open_pager: KeyChord,
}

impl Default for Keymap {
    fn default() -> Self {
        Self {
            transcript_previous_block: KeyChord::Char('['),
            transcript_next_block: KeyChord::Char(']'),
            transcript_previous_diff: KeyChord::Char('{'),
            transcript_next_diff: KeyChord::Char('}'),
            transcript_toggle_block: KeyChord::Ctrl('o'),
            transcript_open_pager: KeyChord::Char('v'),
        }
    }
}

impl Keymap {
    pub(crate) fn transcript_action(&self, key: KeyEvent) -> Option<TranscriptKeyAction> {
        self.transcript_bindings()
            .into_iter()
            .find(|binding| binding.key.matches(key))
            .map(|binding| binding.action)
    }

    pub(crate) fn transcript_block_label(&self) -> String {
        format!(
            "{} / {}",
            self.transcript_previous_block.display(),
            self.transcript_next_block.display()
        )
    }

    pub(crate) fn transcript_diff_label(&self) -> String {
        format!(
            "{} / {}",
            self.transcript_previous_diff.display(),
            self.transcript_next_diff.display()
        )
    }

    pub(crate) fn transcript_toggle_label(&self) -> String {
        self.transcript_toggle_block.display()
    }

    pub(crate) fn transcript_pager_label(&self) -> String {
        self.transcript_open_pager.display()
    }

    fn set(&mut self, action: TranscriptKeyAction, key: KeyChord) {
        match action {
            TranscriptKeyAction::PreviousBlock => self.transcript_previous_block = key,
            TranscriptKeyAction::NextBlock => self.transcript_next_block = key,
            TranscriptKeyAction::PreviousDiff => self.transcript_previous_diff = key,
            TranscriptKeyAction::NextDiff => self.transcript_next_diff = key,
            TranscriptKeyAction::ToggleBlock => self.transcript_toggle_block = key,
            TranscriptKeyAction::OpenPager => self.transcript_open_pager = key,
        }
    }

    fn transcript_bindings(&self) -> [ResolvedTranscriptBinding; 6] {
        [
            ResolvedTranscriptBinding {
                action: TranscriptKeyAction::PreviousBlock,
                action_id: ACTION_PREVIOUS_BLOCK,
                key: self.transcript_previous_block,
                description: "jump to the previous transcript block when input is empty",
            },
            ResolvedTranscriptBinding {
                action: TranscriptKeyAction::NextBlock,
                action_id: ACTION_NEXT_BLOCK,
                key: self.transcript_next_block,
                description: "jump to the next transcript block when input is empty",
            },
            ResolvedTranscriptBinding {
                action: TranscriptKeyAction::PreviousDiff,
                action_id: ACTION_PREVIOUS_DIFF,
                key: self.transcript_previous_diff,
                description: "jump to the previous diff block when input is empty",
            },
            ResolvedTranscriptBinding {
                action: TranscriptKeyAction::NextDiff,
                action_id: ACTION_NEXT_DIFF,
                key: self.transcript_next_diff,
                description: "jump to the next diff block when input is empty",
            },
            ResolvedTranscriptBinding {
                action: TranscriptKeyAction::ToggleBlock,
                action_id: ACTION_TOGGLE_BLOCK,
                key: self.transcript_toggle_block,
                description: "collapse or expand the current transcript block",
            },
            ResolvedTranscriptBinding {
                action: TranscriptKeyAction::OpenPager,
                action_id: ACTION_OPEN_PAGER,
                key: self.transcript_open_pager,
                description: "open the current transcript block in a pager",
            },
        ]
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct ResolvedTranscriptBinding {
    action: TranscriptKeyAction,
    action_id: &'static str,
    key: KeyChord,
    description: &'static str,
}

pub(crate) fn config_path(workspace: &Path) -> PathBuf {
    workspace.join(".holtworks").join("cli_keymap.json")
}

pub(crate) fn load(workspace: &Path) -> Result<Keymap, String> {
    let path = config_path(workspace);
    let text = match fs::read_to_string(&path) {
        Ok(text) => text,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(Keymap::default()),
        Err(error) => return Err(format!("could not read {}: {error}", path.display())),
    };

    parse_config(&text).map_err(|error| format!("{}: {error}", path.display()))
}

fn parse_config(text: &str) -> Result<Keymap, String> {
    let value =
        serde_json::from_str::<Value>(text).map_err(|error| format!("invalid JSON: {error}"))?;
    let object = value
        .as_object()
        .ok_or_else(|| "keymap config must be a JSON object".to_string())?;

    for field in object.keys() {
        if field != "schema_version" && field != "bindings" {
            return Err(format!("unsupported keymap field: {field}"));
        }
    }

    let schema_version = object
        .get("schema_version")
        .and_then(Value::as_str)
        .ok_or_else(|| "keymap config missing schema_version".to_string())?;

    if schema_version != KEYMAP_SCHEMA_VERSION {
        return Err(format!("unsupported schema_version: {schema_version}"));
    }

    let bindings = object
        .get("bindings")
        .and_then(Value::as_object)
        .ok_or_else(|| "keymap config missing bindings".to_string())?;

    let mut keymap = Keymap::default();

    for (action_id, key_value) in bindings {
        let action = TranscriptKeyAction::from_id(action_id)?;
        let key_text = key_value
            .as_str()
            .ok_or_else(|| format!("keymap binding for {action_id} must be a string"))?;
        let key = KeyChord::parse(key_text).map_err(|error| format!("{error} for {action_id}"))?;
        keymap.set(action, key);
    }

    validate_unique(&keymap)?;
    Ok(keymap)
}

fn validate_unique(keymap: &Keymap) -> Result<(), String> {
    let bindings = keymap.transcript_bindings();

    for (index, left) in bindings.iter().enumerate() {
        for right in bindings.iter().skip(index + 1) {
            if left.key == right.key {
                return Err(format!(
                    "duplicate key {} for {} and {}",
                    left.key.display(),
                    left.action_id,
                    right.action_id
                ));
            }
        }
    }

    Ok(())
}

pub(crate) fn formatted_rows(static_bindings: &[KeyBindingSpec], keymap: &Keymap) -> Vec<String> {
    let mut rows = Vec::new();
    let mut inserted_transcript_rows = false;

    for binding in static_bindings {
        if binding.scope == TRANSCRIPT_SCOPE {
            if !inserted_transcript_rows {
                rows.extend(format_transcript_rows(keymap));
                inserted_transcript_rows = true;
            }
            continue;
        }

        rows.push(format!(
            "{:<18} {:<22} {}",
            binding.key, binding.scope, binding.description
        ));
    }

    if !inserted_transcript_rows {
        rows.extend(format_transcript_rows(keymap));
    }

    rows
}

fn format_transcript_rows(keymap: &Keymap) -> Vec<String> {
    keymap
        .transcript_bindings()
        .into_iter()
        .map(|binding| {
            format!(
                "{:<18} {:<22} {}",
                binding.key.display(),
                TRANSCRIPT_SCOPE,
                binding.description
            )
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::{parse_config, Keymap, TranscriptKeyAction};
    use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

    #[test]
    fn parses_partial_transcript_overrides() {
        let keymap = parse_config(
            r#"{
                "schema_version": "holt_cli_keymap/v1",
                "bindings": {
                    "transcript.previous_diff": "Ctrl+P",
                    "transcript.next_diff": "Ctrl+N"
                }
            }"#,
        )
        .expect("keymap");

        assert_eq!(
            keymap.transcript_action(KeyEvent::new(KeyCode::Char('p'), KeyModifiers::CONTROL)),
            Some(TranscriptKeyAction::PreviousDiff)
        );
        assert_eq!(
            keymap.transcript_action(KeyEvent::new(KeyCode::Char('}'), KeyModifiers::SHIFT)),
            None
        );
        assert_eq!(
            keymap.transcript_action(KeyEvent::new(KeyCode::Char(']'), KeyModifiers::NONE)),
            Some(TranscriptKeyAction::NextBlock)
        );
    }

    #[test]
    fn rejects_unknown_actions() {
        let error = parse_config(
            r#"{
                "schema_version": "holt_cli_keymap/v1",
                "bindings": {
                    "transcript.last_diff": "Ctrl+L"
                }
            }"#,
        )
        .expect_err("unknown action");

        assert_eq!(error, "unsupported keymap action: transcript.last_diff");
    }

    #[test]
    fn rejects_unsupported_keys() {
        let error = parse_config(
            r#"{
                "schema_version": "holt_cli_keymap/v1",
                "bindings": {
                    "transcript.previous_diff": "Alt+P"
                }
            }"#,
        )
        .expect_err("unsupported key");

        assert_eq!(error, "unsupported key Alt+P for transcript.previous_diff");
    }

    #[test]
    fn rejects_duplicate_final_bindings() {
        let error = parse_config(
            r#"{
                "schema_version": "holt_cli_keymap/v1",
                "bindings": {
                    "transcript.previous_diff": "Ctrl+P",
                    "transcript.next_diff": "Ctrl+P"
                }
            }"#,
        )
        .expect_err("duplicate key");

        assert_eq!(
            error,
            "duplicate key Ctrl+P for transcript.previous_diff and transcript.next_diff"
        );
    }

    #[test]
    fn default_transcript_keymap_matches_existing_shortcuts() {
        let keymap = Keymap::default();

        assert_eq!(
            keymap.transcript_action(KeyEvent::new(KeyCode::Char('{'), KeyModifiers::SHIFT)),
            Some(TranscriptKeyAction::PreviousDiff)
        );
        assert_eq!(
            keymap.transcript_action(KeyEvent::new(KeyCode::Char('o'), KeyModifiers::CONTROL)),
            Some(TranscriptKeyAction::ToggleBlock)
        );
        assert_eq!(
            keymap.transcript_action(KeyEvent::new(KeyCode::Char('v'), KeyModifiers::NONE)),
            Some(TranscriptKeyAction::OpenPager)
        );
    }
}
