use anyhow::{Context, Result};
use crossterm::{
    cursor::{Hide, Show},
    execute,
    terminal::{disable_raw_mode, enable_raw_mode, size},
};
use std::io::{self, IsTerminal, Write};

pub fn interactive() -> bool {
    if std::env::var("CI").is_ok() {
        return false;
    }

    io::stdin().is_terminal() && io::stdout().is_terminal()
}

pub fn terminal_size() -> (u16, u16) {
    size().unwrap_or((100, 32))
}

#[allow(dead_code)]
pub fn enter_inline_tui() -> Result<TerminalGuard> {
    enable_raw_mode().context("failed to enable raw terminal mode")?;
    if let Err(err) = execute!(io::stdout(), Hide) {
        let _ = disable_raw_mode();
        return Err(err).context("failed to prepare inline terminal UI");
    }

    Ok(TerminalGuard {
        raw_mode: true,
        cursor_hidden: true,
    })
}

#[allow(dead_code)]
pub struct TerminalGuard {
    raw_mode: bool,
    cursor_hidden: bool,
}

impl Drop for TerminalGuard {
    fn drop(&mut self) {
        let mut stdout = io::stdout();

        if self.cursor_hidden {
            let _ = execute!(stdout, Show);
            let _ = stdout.flush();
        }

        if self.raw_mode {
            let _ = disable_raw_mode();
        }
    }
}
