use anyhow::{Context, Result};
use crossterm::{
    cursor::{Hide, Show},
    execute,
    terminal::{
        disable_raw_mode, enable_raw_mode, size, Clear, ClearType, EnterAlternateScreen,
        LeaveAlternateScreen,
    },
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

pub fn enter_alt_screen() -> Result<TerminalGuard> {
    enable_raw_mode().context("failed to enable raw terminal mode")?;
    execute!(
        io::stdout(),
        EnterAlternateScreen,
        Clear(ClearType::All),
        Hide
    )
    .context("failed to enter alternate screen")?;

    Ok(TerminalGuard {
        raw_mode: true,
        alt_screen: true,
    })
}

pub struct TerminalGuard {
    raw_mode: bool,
    alt_screen: bool,
}

impl Drop for TerminalGuard {
    fn drop(&mut self) {
        let mut stdout = io::stdout();

        if self.alt_screen {
            let _ = execute!(stdout, Show, LeaveAlternateScreen);
            let _ = stdout.flush();
        }

        if self.raw_mode {
            let _ = disable_raw_mode();
        }
    }
}
