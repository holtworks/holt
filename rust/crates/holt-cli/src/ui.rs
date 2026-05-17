use crossterm::style::Color;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Tone {
    Accent,
    Assistant,
    Border,
    Dim,
    Error,
    Plain,
    System,
    User,
    Warning,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RenderLine {
    pub text: String,
    pub tone: Tone,
}

impl RenderLine {
    pub fn new(text: impl Into<String>, tone: Tone) -> Self {
        Self {
            text: text.into(),
            tone,
        }
    }
}

pub fn color(tone: Tone) -> Color {
    match tone {
        Tone::Accent => Color::Rgb {
            r: 64,
            g: 210,
            b: 255,
        },
        Tone::Assistant => Color::White,
        Tone::Border => Color::DarkGrey,
        Tone::Dim => Color::DarkGrey,
        Tone::Error => Color::Red,
        Tone::Plain => Color::Grey,
        Tone::System => Color::Yellow,
        Tone::User => Color::Green,
        Tone::Warning => Color::Yellow,
    }
}

pub fn truncate(text: &str, max_width: usize) -> String {
    if max_width == 0 {
        return String::new();
    }

    let mut chars = text.chars();
    let mut output = String::new();

    for ch in chars.by_ref().take(max_width) {
        output.push(ch);
    }

    if chars.next().is_some() {
        output.pop();
        output.push('…');
    }

    output
}

pub fn wrap(text: &str, max_width: usize) -> Vec<String> {
    if max_width == 0 {
        return vec![String::new()];
    }

    let mut lines = Vec::new();

    for raw_line in text.lines() {
        let mut line = String::new();

        for word in raw_line.split_whitespace() {
            let extra = if line.is_empty() { 0 } else { 1 };

            if line.chars().count() + word.chars().count() + extra > max_width && !line.is_empty() {
                lines.push(line);
                line = String::new();
            }

            if word.chars().count() > max_width {
                if !line.is_empty() {
                    lines.push(line);
                    line = String::new();
                }

                let mut chunk = String::new();
                for ch in word.chars() {
                    if chunk.chars().count() == max_width {
                        lines.push(chunk);
                        chunk = String::new();
                    }
                    chunk.push(ch);
                }

                if !chunk.is_empty() {
                    line = chunk;
                }
            } else {
                if !line.is_empty() {
                    line.push(' ');
                }
                line.push_str(word);
            }
        }

        lines.push(line);
    }

    if lines.is_empty() {
        lines.push(String::new());
    }

    lines
}

pub fn spinner(frame: usize) -> &'static str {
    const FRAMES: [&str; 10] = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];
    FRAMES[frame % FRAMES.len()]
}

pub fn ripple(frame: usize, width: usize) -> String {
    if width < 3 {
        return spinner(frame).to_string();
    }

    let cycle = width * 2 - 2;
    let position = frame % cycle;
    let center = if position < width {
        position
    } else {
        cycle - position
    };

    (0..width)
        .map(|index| match index.abs_diff(center) {
            0 => 'O',
            1 => 'o',
            2 => '.',
            _ => ' ',
        })
        .collect()
}

pub fn markdown_lines(content: &str, width: usize) -> Vec<RenderLine> {
    let body_width = width.saturating_sub(4).max(8);
    let mut lines = Vec::new();
    let mut in_code = false;
    let mut code_lang = String::new();

    for raw_line in content.trim().lines() {
        let line = raw_line.trim_end();

        if let Some(rest) = line.strip_prefix("```") {
            if in_code {
                lines.push(RenderLine::new("╰─", Tone::Border));
                in_code = false;
                code_lang.clear();
            } else {
                code_lang = rest.trim().to_string();
                let label = if code_lang.is_empty() {
                    "╭─ code".to_string()
                } else {
                    format!("╭─ {code_lang}")
                };
                lines.push(RenderLine::new(label, Tone::Border));
                in_code = true;
            }
            continue;
        }

        if in_code {
            let prefixed = format!("│ {line}");
            lines.push(RenderLine::new(
                truncate(&prefixed, body_width + 2),
                Tone::Plain,
            ));
            continue;
        }

        if line.trim().is_empty() {
            lines.push(RenderLine::new("", Tone::Plain));
            continue;
        }

        let trimmed = line.trim_start();
        let (prefix, body, tone) = if trimmed.starts_with('#') {
            let body = trimmed.trim_start_matches('#').trim().to_uppercase();
            ("", body, Tone::Accent)
        } else if let Some(body) = trimmed.strip_prefix("- ") {
            ("• ", body.trim().to_string(), Tone::Assistant)
        } else if let Some(body) = trimmed.strip_prefix("* ") {
            ("• ", body.trim().to_string(), Tone::Assistant)
        } else if let Some(body) = trimmed.strip_prefix("> ") {
            ("› ", body.trim().to_string(), Tone::Dim)
        } else {
            ("", trimmed.to_string(), Tone::Assistant)
        };

        for wrapped in wrap(&body, body_width.saturating_sub(prefix.chars().count())) {
            lines.push(RenderLine::new(format!("{prefix}{wrapped}"), tone));
        }
    }

    if in_code {
        lines.push(RenderLine::new("╰─", Tone::Border));
    }

    if lines.is_empty() {
        lines.push(RenderLine::new("", Tone::Plain));
    }

    lines
}

#[cfg(test)]
mod tests {
    use super::{ripple, wrap};

    #[test]
    fn wraps_long_lines() {
        assert_eq!(wrap("one two three", 7), vec!["one two", "three"]);
    }

    #[test]
    fn truncate_preserves_exact_width_text() {
        assert_eq!(super::truncate("abcd", 4), "abcd");
        assert_eq!(super::truncate("abcde", 4), "abc…");
    }

    #[test]
    fn ripple_keeps_stable_width() {
        assert_eq!(ripple(0, 8).chars().count(), 8);
        assert_eq!(ripple(5, 8).chars().count(), 8);
    }
}
