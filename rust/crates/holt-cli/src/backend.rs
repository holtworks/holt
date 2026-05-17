use anyhow::{anyhow, Context, Result};
use base64::{engine::general_purpose, Engine as _};
use serde_json::{Map, Value};
use std::io::{BufRead, BufReader, Read};
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::sync::mpsc;
use std::thread;

pub struct BackendOutput {
    pub code: i32,
    pub stdout: String,
    pub stderr: String,
}

#[derive(Debug, Clone, Eq, PartialEq)]
pub enum StreamLine {
    Stdout(String),
    Stderr(String),
}

pub fn run_passthrough(args: &[String]) -> Result<i32> {
    let status = command(args, false)?
        .stdin(Stdio::inherit())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .status()
        .context("failed to start Holt")?;

    Ok(status.code().unwrap_or(1))
}

pub fn capture(args: &[String]) -> Result<BackendOutput> {
    let output = command(args, false)?
        .stdin(Stdio::inherit())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .context("failed to run Holt")?;

    Ok(output_to_backend(output))
}

pub fn stream_jsonl<F>(args: &[String], mut on_line: F) -> Result<BackendOutput>
where
    F: FnMut(StreamLine) -> Result<()>,
{
    let mut child = command(args, true)?
        .stdin(Stdio::inherit())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .context("failed to start Holt")?;

    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| anyhow!("failed to capture Holt stdout"))?;
    let stderr = child
        .stderr
        .take()
        .ok_or_else(|| anyhow!("failed to capture Holt stderr"))?;

    let (tx, rx) = mpsc::channel();
    spawn_reader(stdout, tx.clone(), false);
    spawn_reader(stderr, tx, true);

    let mut stdout_lines = Vec::new();
    let mut stderr_lines = Vec::new();

    for line in rx {
        match &line {
            StreamLine::Stdout(text) => stdout_lines.push(text.clone()),
            StreamLine::Stderr(text) => stderr_lines.push(text.clone()),
        }

        on_line(line)?;
    }

    let status = child.wait().context("failed to wait for Holt")?;

    Ok(BackendOutput {
        code: status.code().unwrap_or(1),
        stdout: stdout_lines.join("\n"),
        stderr: stderr_lines.join("\n"),
    })
}

fn spawn_reader<R>(reader: R, tx: mpsc::Sender<StreamLine>, stderr: bool)
where
    R: Read + Send + 'static,
{
    thread::spawn(move || {
        for line in BufReader::new(reader).lines() {
            let Ok(line) = line else {
                break;
            };

            let event = if stderr {
                StreamLine::Stderr(line)
            } else {
                StreamLine::Stdout(line)
            };

            if tx.send(event).is_err() {
                break;
            }
        }
    });
}

fn command(args: &[String], event_stream: bool) -> Result<Command> {
    if let Ok(binary) =
        std::env::var("HOLT_BACKEND_BIN").or_else(|_| std::env::var("HOLTWORKS_ELIXIR_BIN"))
    {
        let mut command = Command::new(binary);
        command.args(args);
        return Ok(command);
    }

    let root = repo_root().ok_or_else(|| {
        anyhow!("could not find mix.exs; run from the Holt repo or set HOLT_BACKEND_BIN")
    })?;

    let mut request = NativeRequest::from_args(args)?;

    if event_stream {
        request.params.insert(
            "event_stream".to_string(),
            Value::String("jsonl".to_string()),
        );
    }

    let expr = native_entrypoint(&request)?;

    let mut command = Command::new("mix");
    command
        .current_dir(root)
        .env("MIX_QUIET", "1")
        .args(["run", "-e", &expr]);
    Ok(command)
}

#[derive(Debug, Clone, Eq, PartialEq)]
struct NativeRequest {
    command: String,
    params: Map<String, Value>,
}

impl NativeRequest {
    fn from_args(args: &[String]) -> Result<Self> {
        let command = args
            .first()
            .ok_or_else(|| anyhow!("missing Holt command"))?
            .as_str();

        match command {
            "doctor" | "onboard" | "status" | "logs" => {
                let (params, rest) = parse_flags(&args[1..], &[])?;

                if !rest.is_empty() {
                    return Err(anyhow!("unexpected arguments for `{command}`"));
                }

                Ok(Self {
                    command: command.to_string(),
                    params,
                })
            }
            "run" => {
                let (mut params, rest) = parse_flags(&args[1..], &[])?;
                params.insert("objective".to_string(), Value::String(rest.join(" ")));

                Ok(Self {
                    command: "run".to_string(),
                    params,
                })
            }
            "resume" => {
                let (mut params, rest) = parse_flags(&args[1..], &[])?;
                params.insert(
                    "run_ref".to_string(),
                    Value::String(
                        rest.first()
                            .cloned()
                            .unwrap_or_else(|| "latest".to_string()),
                    ),
                );

                if rest.len() > 1 {
                    return Err(anyhow!("unexpected arguments for `resume`"));
                }

                Ok(Self {
                    command: "resume".to_string(),
                    params,
                })
            }
            "llm" => llm_request(&args[1..]),
            _ => Err(anyhow!("unsupported Holt command `{command}`")),
        }
    }
}

fn llm_request(args: &[String]) -> Result<NativeRequest> {
    match args.first().map(String::as_str) {
        Some("test") => {
            let (mut params, rest) = parse_flags(&args[1..], &["prompt"])?;
            params.insert(
                "provider_id".to_string(),
                Value::String(
                    rest.first()
                        .cloned()
                        .unwrap_or_else(|| "openrouter".to_string()),
                ),
            );

            if rest.len() > 1 {
                return Err(anyhow!("unexpected arguments for `llm test`"));
            }

            Ok(NativeRequest {
                command: "llm_test".to_string(),
                params,
            })
        }
        _ => Err(anyhow!("usage: holt llm test [provider]")),
    }
}

fn parse_flags(
    args: &[String],
    extra_string_flags: &[&str],
) -> Result<(Map<String, Value>, Vec<String>)> {
    let mut params = Map::new();
    let mut rest = Vec::new();
    let mut index = 0;

    while index < args.len() {
        let arg = &args[index];

        if arg == "--" {
            rest.extend(args[index + 1..].iter().cloned());
            break;
        }

        if !arg.starts_with('-') {
            rest.extend(args[index..].iter().cloned());
            break;
        }

        match arg.as_str() {
            "--yes" | "-y" => {
                params.insert("yes".to_string(), Value::Bool(true));
                index += 1;
            }
            "--json" => {
                params.insert("json".to_string(), Value::Bool(true));
                index += 1;
            }
            "--api-key-stdin" => {
                params.insert("api_key_stdin".to_string(), Value::Bool(true));
                index += 1;
            }
            "--home" | "--workspace" | "--provider" | "--model" | "--mode" | "--base-url"
            | "--api-key-env" | "--env-file" | "--chat-context" => {
                let value = args
                    .get(index + 1)
                    .ok_or_else(|| anyhow!("{arg} needs a value"))?;
                params.insert(flag_key(arg), Value::String(value.clone()));
                index += 2;
            }
            value => {
                let trimmed = value.trim_start_matches('-').replace('-', "_");

                if extra_string_flags.contains(&trimmed.as_str()) {
                    let flag = args[index].clone();
                    let flag_value = args
                        .get(index + 1)
                        .ok_or_else(|| anyhow!("{flag} needs a value"))?;
                    params.insert(trimmed, Value::String(flag_value.clone()));
                    index += 2;
                } else {
                    return Err(anyhow!("unknown option `{value}`"));
                }
            }
        }
    }

    Ok((params, rest))
}

fn flag_key(flag: &str) -> String {
    flag.trim_start_matches('-').replace('-', "_")
}

fn native_entrypoint(request: &NativeRequest) -> Result<String> {
    let encoded = serde_json::to_string(&serde_json::json!({
        "command": request.command,
        "params": request.params,
    }))
    .context("failed to encode backend request")?;
    let encoded = general_purpose::STANDARD.encode(encoded);

    Ok(format!(
        "System.halt(Holt.Bridge.NativeCommand.main(\"{encoded}\"))"
    ))
}

fn output_to_backend(output: Output) -> BackendOutput {
    BackendOutput {
        code: output.status.code().unwrap_or(1),
        stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
    }
}

fn repo_root() -> Option<PathBuf> {
    let mut current = std::env::current_dir().ok()?;

    loop {
        if looks_like_holt_root(&current) {
            return Some(current);
        }

        if !current.pop() {
            return None;
        }
    }
}

fn looks_like_holt_root(path: &Path) -> bool {
    path.join("mix.exs").is_file() && path.join("lib/holt/bridge/native_command.ex").is_file()
}

#[cfg(test)]
mod tests {
    use super::{native_entrypoint, NativeRequest};

    #[test]
    fn run_request_preserves_prompt_and_flags() {
        let args = vec![
            "run".to_string(),
            "--yes".to_string(),
            "--workspace".to_string(),
            "/tmp/work".to_string(),
            "hello".to_string(),
            "world".to_string(),
        ];
        let request = NativeRequest::from_args(&args).expect("request");

        assert_eq!(request.command, "run");
        assert_eq!(request.params["yes"], true);
        assert_eq!(request.params["workspace"], "/tmp/work");
        assert_eq!(request.params["objective"], "hello world");
    }

    #[test]
    fn native_entrypoint_does_not_embed_prompt_source_or_elixir_cli() {
        let args = vec!["run".to_string(), "#{System.halt(99)}".to_string()];
        let request = NativeRequest::from_args(&args).expect("request");
        let expr = native_entrypoint(&request).expect("entrypoint");

        assert!(!expr.contains("#{System.halt"));
        let removed_entrypoint = ["Holt", "CLI"].join(".");
        assert!(!expr.contains(&removed_entrypoint));
        assert!(expr.contains("Holt.Bridge.NativeCommand.main"));
    }
}
