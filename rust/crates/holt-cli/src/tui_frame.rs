#[cfg(test)]
use crate::ui::RenderLine;
use crate::ui::{self, Tone};
use ratatui::{
    layout::{Position, Rect},
    style::Style,
    text::Line as RatLine,
    widgets::{Block, Borders, Clear, Paragraph},
    Frame,
};

const TRANSCRIPT_TOP: u16 = 4;

pub(crate) struct FrameView {
    pub header: HeaderView,
    pub transcript: Vec<RatLine<'static>>,
    pub composer: ComposerView,
    pub transcript_height: u16,
    pub pager: Option<PagerView>,
}

pub(crate) struct HeaderView {
    pub workspace: String,
    pub interaction_mode: &'static str,
    pub permission_mode: &'static str,
}

pub(crate) struct ComposerView {
    pub mode: ComposerMode,
    pub content: ComposerContent,
    pub rule: String,
    pub input_lines: Vec<String>,
    pub suggestions: Vec<ComposerSuggestion>,
    pub height: u16,
    pub cursor_x: u16,
    pub cursor_y: u16,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct PagerView {
    pub title: String,
    pub lines: Vec<RatLine<'static>>,
    pub scroll: usize,
    pub footer: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) enum ComposerContent {
    None,
    UserPrompt(UserPromptView),
    RunPicker(RunPickerView),
}

impl ComposerContent {
    pub(crate) fn line_count(&self) -> usize {
        match self {
            Self::None => 0,
            Self::UserPrompt(prompt) => prompt.line_count(),
            Self::RunPicker(picker) => picker.line_count(),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct UserPromptView {
    pub question: String,
    pub description: Option<String>,
    pub options: Vec<UserPromptOptionView>,
    pub selected: usize,
}

impl UserPromptView {
    fn line_count(&self) -> usize {
        1 + usize::from(self.description.is_some()) + 1 + self.options.len()
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct UserPromptOptionView {
    pub label: String,
    pub description: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct RunPickerView {
    pub rows: Vec<RunPickerRowView>,
    pub detail: Option<RunPickerDetailView>,
}

impl RunPickerView {
    fn line_count(&self) -> usize {
        1 + self.rows.len()
            + self
                .detail
                .as_ref()
                .map_or(0, RunPickerDetailView::line_count)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct RunPickerRowView {
    pub selected: bool,
    pub id: String,
    pub status: String,
    pub objective: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct RunPickerDetailView {
    pub status: String,
    pub objective: String,
    pub artifact: Option<String>,
    pub answer: Option<String>,
}

impl RunPickerDetailView {
    fn line_count(&self) -> usize {
        3 + usize::from(self.artifact.is_some()) + 1
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct ComposerSuggestion {
    pub selected: bool,
    pub usage: String,
    pub description: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum ComposerHistorySearchStatus {
    Found,
    NotFound,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) enum ComposerMode {
    Message {
        interaction_mode: &'static str,
        permission_mode: &'static str,
        navigation: TranscriptNavigationLabels,
    },
    Pending {
        label: String,
        frame: usize,
        elapsed_millis: u128,
        navigation: TranscriptNavigationLabels,
    },
    HistorySearch {
        query: String,
        status: ComposerHistorySearchStatus,
        navigation: TranscriptNavigationLabels,
    },
    Question {
        has_options: bool,
    },
    Approval {
        action: String,
        pending: Option<PendingComposerStatus>,
    },
    RunPicker,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct PendingComposerStatus {
    pub label: String,
    pub frame: usize,
    pub elapsed_millis: u128,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct TranscriptNavigationLabels {
    pub block: String,
    pub diff: String,
    pub toggle: String,
    pub pager: String,
}

impl ComposerMode {
    pub(crate) fn title(&self) -> String {
        match self {
            Self::Message { .. } => "message".to_string(),
            Self::Pending {
                label,
                frame,
                elapsed_millis,
                ..
            } => pending_title(label, *frame, *elapsed_millis),
            Self::HistorySearch { .. } => "history".to_string(),
            Self::Question { .. } => "question".to_string(),
            Self::Approval {
                pending: Some(status),
                ..
            } => pending_title(&status.label, status.frame, status.elapsed_millis),
            Self::Approval { pending: None, .. } => "approval".to_string(),
            Self::RunPicker => "runs".to_string(),
        }
    }

    pub(crate) fn title_tone(&self) -> Tone {
        match self {
            Self::Pending { .. }
            | Self::Approval {
                pending: Some(_), ..
            }
            | Self::HistorySearch {
                status: ComposerHistorySearchStatus::NotFound,
                ..
            } => Tone::Warning,
            _ => Tone::Accent,
        }
    }

    pub(crate) fn footer(&self) -> String {
        match self {
            Self::Question { has_options: false } => {
                "│ Type answer · Enter send · Ctrl-C quit".to_string()
            }
            Self::Question { has_options: true } => {
                "│ Up/Down select · Enter send · 1-9 choose · Ctrl-C quit".to_string()
            }
            Self::Approval { action, .. } => {
                format!("│ Approval required for {action} · Y approve · N/Esc deny")
            }
            Self::RunPicker => {
                "│ Up/Down select · PgUp/PgDn jump · Home/End edge · Enter resume · F fork · L logs · Esc close"
                    .to_string()
            }
            Self::HistorySearch {
                query,
                status: ComposerHistorySearchStatus::Found,
                navigation,
            } => format!(
                "│ Ctrl-R older match · query: {} · PgUp/PgDn scroll · {} blocks · {} diffs · {} fold · {} pager",
                query, navigation.block, navigation.diff, navigation.toggle, navigation.pager
            ),
            Self::HistorySearch {
                query,
                status: ComposerHistorySearchStatus::NotFound,
                navigation,
            } => format!(
                "│ history: no match for {} · edit to reset · {} blocks · {} diffs · {} fold · {} pager",
                query, navigation.block, navigation.diff, navigation.toggle, navigation.pager
            ),
            Self::Pending { navigation, .. } => format!(
                "│ Ctrl-C interrupt · PgUp/PgDn scroll · {} blocks · {} diffs · {} fold · {} pager",
                navigation.block, navigation.diff, navigation.toggle, navigation.pager
            ),
            Self::Message {
                interaction_mode,
                permission_mode,
                navigation,
            } => format!(
                "│ {} mode · {} · Enter send · Tab mode · Ctrl-R history · PgUp/PgDn scroll · {} blocks · {} diffs · {} fold · {} pager",
                interaction_mode, permission_mode, navigation.block, navigation.diff, navigation.toggle, navigation.pager
            ),
        }
    }

    pub(crate) fn accepts_text_input(&self) -> bool {
        matches!(
            self,
            Self::Message { .. }
                | Self::HistorySearch { .. }
                | Self::Question { has_options: false }
        )
    }
}

pub(crate) fn draw_frame(frame: &mut Frame<'_>, view: &FrameView) {
    let area = frame.area();
    if area.width == 0 || area.height == 0 {
        return;
    }

    draw_header(frame, &view.header, area);
    draw_transcript(frame, view, area);
    draw_composer(frame, &view.composer, area);
    if let Some(pager) = &view.pager {
        draw_pager(frame, pager, area);
    } else {
        frame.set_cursor_position(Position::new(
            area.x + view.composer.cursor_x.min(area.width.saturating_sub(1)),
            area.y + view.composer.cursor_y.min(area.height.saturating_sub(1)),
        ));
    }
}

fn draw_header(frame: &mut Frame<'_>, header: &HeaderView, area: Rect) {
    if area.height == 0 {
        return;
    }

    let width = area.width;
    let lines = vec![
        ui::ratatui_plain_line(
            format!("╭─ Holt {}", "─".repeat(width.saturating_sub(8) as usize)),
            Tone::Accent,
            width,
        ),
        ui::ratatui_plain_line(
            format!(
                "│ {} · {} · {} · {}",
                "workspace",
                header.interaction_mode,
                header.permission_mode,
                ui::truncate(&header.workspace, width.saturating_sub(36) as usize)
            ),
            Tone::Plain,
            width,
        ),
        ui::ratatui_plain_line(
            format!("╰{}", "─".repeat(width.saturating_sub(1) as usize)),
            Tone::Border,
            width,
        ),
    ];

    frame.render_widget(
        Paragraph::new(lines),
        Rect::new(area.x, area.y, width, area.height.min(3)),
    );
}

fn draw_transcript(frame: &mut Frame<'_>, view: &FrameView, area: Rect) {
    let body_area = Rect::new(
        area.x,
        area.y.saturating_add(TRANSCRIPT_TOP),
        area.width,
        view.transcript_height
            .min(area.height.saturating_sub(TRANSCRIPT_TOP)),
    );
    if body_area.height > 0 {
        frame.render_widget(Paragraph::new(view.transcript.clone()), body_area);
    }
}

fn draw_composer(frame: &mut Frame<'_>, composer: &ComposerView, area: Rect) {
    if area.height == 0 {
        return;
    }

    let width = area.width;
    let height = area.height;
    let top = height.saturating_sub(composer.height);
    let draw_height = composer.height.min(height.saturating_sub(top));
    if draw_height == 0 {
        return;
    }

    let mut lines = Vec::new();
    let title = composer.mode.title();
    lines.push(ui::ratatui_plain_line(
        format!("╭─ {} {}", title, composer.rule),
        composer.mode.title_tone(),
        width,
    ));
    for (index, line) in composer.input_lines.iter().enumerate() {
        let prefix = if index == 0 { "│ > " } else { "│   " };
        lines.push(ui::ratatui_plain_line(
            format!("{prefix}{line}"),
            Tone::User,
            width,
        ));
    }

    draw_composer_content(&mut lines, &composer.content, width);

    for suggestion in &composer.suggestions {
        let marker = if suggestion.selected { "▶" } else { " " };
        let tone = if suggestion.selected {
            Tone::Accent
        } else {
            Tone::Dim
        };
        lines.push(ui::ratatui_plain_line(
            format!(
                "│ {marker} {:<14} {}",
                suggestion.usage, suggestion.description
            ),
            tone,
            width,
        ));
    }

    lines.push(ui::ratatui_plain_line(
        composer.mode.footer(),
        Tone::Dim,
        width,
    ));
    lines.push(ui::ratatui_plain_line(
        format!("╰{}", "─".repeat(width.saturating_sub(1) as usize)),
        Tone::Border,
        width,
    ));

    frame.render_widget(
        Paragraph::new(lines),
        Rect::new(area.x, area.y + top, width, draw_height),
    );
}

fn draw_composer_content(lines: &mut Vec<RatLine<'static>>, content: &ComposerContent, width: u16) {
    match content {
        ComposerContent::None => {}
        ComposerContent::UserPrompt(prompt) => draw_user_prompt(lines, prompt, width),
        ComposerContent::RunPicker(picker) => draw_run_picker(lines, picker, width),
    }
}

fn draw_pager(frame: &mut Frame<'_>, pager: &PagerView, area: Rect) {
    if area.width < 12 || area.height < 6 {
        return;
    }

    let horizontal_margin = if area.width > 100 {
        (area.width - 96) / 2
    } else {
        2
    };
    let vertical_margin = if area.height > 28 { 2 } else { 1 };
    let overlay = Rect::new(
        area.x + horizontal_margin,
        area.y + vertical_margin,
        area.width
            .saturating_sub(horizontal_margin.saturating_mul(2)),
        area.height
            .saturating_sub(vertical_margin.saturating_mul(2)),
    );
    if overlay.width < 10 || overlay.height < 5 {
        return;
    }

    frame.render_widget(Clear, overlay);
    frame.render_widget(
        Block::default()
            .borders(Borders::ALL)
            .title(ui::truncate(
                &pager.title,
                overlay.width.saturating_sub(4) as usize,
            ))
            .border_style(Style::default().fg(ui::color(Tone::Border))),
        overlay,
    );

    let inner = Rect::new(
        overlay.x + 1,
        overlay.y + 1,
        overlay.width.saturating_sub(2),
        overlay.height.saturating_sub(2),
    );
    if inner.height == 0 || inner.width == 0 {
        return;
    }

    let footer_height = 1.min(inner.height);
    let body_height = inner.height.saturating_sub(footer_height);
    let max_scroll = pager.lines.len().saturating_sub(body_height as usize);
    let start = pager.scroll.min(max_scroll);
    let visible = pager
        .lines
        .iter()
        .skip(start)
        .take(body_height as usize)
        .cloned()
        .collect::<Vec<_>>();

    frame.render_widget(
        Paragraph::new(visible),
        Rect::new(inner.x, inner.y, inner.width, body_height),
    );
    frame.render_widget(
        Paragraph::new(vec![ui::ratatui_plain_line(
            pager.footer.clone(),
            Tone::Dim,
            inner.width,
        )]),
        Rect::new(inner.x, inner.y + body_height, inner.width, footer_height),
    );
}

fn draw_user_prompt(lines: &mut Vec<RatLine<'static>>, prompt: &UserPromptView, width: u16) {
    lines.push(ui::ratatui_plain_line(
        format!("│ ? {}", prompt.question),
        Tone::Warning,
        width,
    ));

    if let Some(description) = prompt
        .description
        .as_ref()
        .filter(|description| !description.trim().is_empty())
    {
        lines.push(ui::ratatui_plain_line(
            format!("│   {description}"),
            Tone::Dim,
            width,
        ));
    }

    if prompt.options.is_empty() {
        lines.push(ui::ratatui_plain_line(
            "│   Type your answer and press Enter.",
            Tone::Dim,
            width,
        ));
        return;
    }

    lines.push(ui::ratatui_plain_line(
        "│   Use Up/Down, Enter, or number keys.",
        Tone::Dim,
        width,
    ));

    for (index, option) in prompt.options.iter().enumerate() {
        let marker = if index == prompt.selected { "▶" } else { " " };
        let description = option
            .description
            .as_ref()
            .filter(|description| !description.trim().is_empty())
            .map(|description| format!(" - {description}"))
            .unwrap_or_default();
        let tone = if index == prompt.selected {
            Tone::Accent
        } else {
            Tone::Plain
        };
        lines.push(ui::ratatui_plain_line(
            format!("│ {marker} {}. {}{}", index + 1, option.label, description),
            tone,
            width,
        ));
    }
}

fn draw_run_picker(lines: &mut Vec<RatLine<'static>>, picker: &RunPickerView, width: u16) {
    lines.push(ui::ratatui_plain_line("│ Recent runs", Tone::Accent, width));

    for row in &picker.rows {
        let marker = if row.selected { "▶" } else { " " };
        let tone = if row.selected {
            Tone::Accent
        } else {
            Tone::Plain
        };
        lines.push(ui::ratatui_plain_line(
            format!(
                "│ {marker} {:<24} {:<12} {}",
                row.id, row.status, row.objective
            ),
            tone,
            width,
        ));
    }

    if let Some(detail) = &picker.detail {
        lines.push(ui::ratatui_plain_line(
            format!("│ Selected · {}", detail.status),
            Tone::Dim,
            width,
        ));
        lines.push(ui::ratatui_plain_line(
            format!("│   {}", detail.objective),
            Tone::Dim,
            width,
        ));
        if let Some(artifact) = &detail.artifact {
            lines.push(ui::ratatui_plain_line(
                format!("│   Artifact: {artifact}"),
                Tone::Dim,
                width,
            ));
        }
        let answer = detail.answer.as_deref().unwrap_or("none recorded yet");
        lines.push(ui::ratatui_plain_line(
            format!("│   Answer: {answer}"),
            Tone::Dim,
            width,
        ));
    }
}

#[cfg(test)]
pub(crate) fn ratatui_render_line(line: &RenderLine, width: u16) -> RatLine<'static> {
    ui::ratatui_line(line, width)
}

fn pending_title(label: &str, frame: usize, elapsed_millis: u128) -> String {
    format!(
        "{} {} {} {:.1}s",
        ui::spinner(frame),
        ui::ripple(frame, 18),
        label,
        elapsed_millis as f32 / 1000.0
    )
}
