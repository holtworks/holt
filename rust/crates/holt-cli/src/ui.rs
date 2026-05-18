use pulldown_cmark::{Alignment, CodeBlockKind, Event, HeadingLevel, Options, Parser, Tag, TagEnd};
use ratatui::{
    style::{Color, Modifier, Style},
    text::{Line as RatLine, Span as RatSpan},
};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use syntect::{
    easy::HighlightLines,
    highlighting::{Color as SyntectColor, Style as SyntectStyle, Theme, ThemeSet},
    parsing::SyntaxSet,
};

const MAX_RENDERED_MERMAID_LINES: usize = 24;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Tone {
    Accent,
    Assistant,
    Border,
    Code,
    Dim,
    DiffAdd,
    DiffDelete,
    DiffHunk,
    Error,
    Plain,
    System,
    User,
    Warning,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RenderSpan {
    pub text: String,
    pub tone: Tone,
    pub foreground: Option<Color>,
    pub modifier: Modifier,
}

impl RenderSpan {
    pub fn new(text: impl Into<String>, tone: Tone) -> Self {
        Self {
            text: text.into(),
            tone,
            foreground: None,
            modifier: Modifier::empty(),
        }
    }

    pub fn colored(text: impl Into<String>, tone: Tone, foreground: Color) -> Self {
        Self {
            text: text.into(),
            tone,
            foreground: Some(foreground),
            modifier: Modifier::empty(),
        }
    }

    pub fn color(&self) -> Color {
        self.foreground.unwrap_or_else(|| color(self.tone))
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RenderLine {
    pub text: String,
    pub tone: Tone,
    pub spans: Vec<RenderSpan>,
}

impl RenderLine {
    pub fn new(text: impl Into<String>, tone: Tone) -> Self {
        Self {
            text: text.into(),
            tone,
            spans: Vec::new(),
        }
    }

    pub fn styled(spans: Vec<RenderSpan>) -> Self {
        let text = spans
            .iter()
            .map(|span| span.text.as_str())
            .collect::<Vec<_>>()
            .join("");
        let tone = spans.first().map(|span| span.tone).unwrap_or(Tone::Plain);

        Self { text, tone, spans }
    }

    pub fn prefixed(&self, prefix: impl Into<String>, prefix_tone: Tone) -> Self {
        let prefix = prefix.into();

        if self.spans.is_empty() {
            return RenderLine::new(format!("{prefix}{}", self.text), self.tone);
        }

        let mut spans = vec![RenderSpan::new(prefix, prefix_tone)];
        spans.extend(self.spans.clone());
        RenderLine::styled(spans)
    }

    pub fn flattened_with_tone(&self, tone: Tone) -> Self {
        RenderLine::new(self.text.clone(), tone)
    }
}

pub fn color(tone: Tone) -> Color {
    match tone {
        Tone::Accent => Color::Rgb(64, 210, 255),
        Tone::Assistant => Color::White,
        Tone::Border => Color::DarkGray,
        Tone::Code => Color::Gray,
        Tone::Dim => Color::DarkGray,
        Tone::DiffAdd => Color::Green,
        Tone::DiffDelete => Color::Red,
        Tone::DiffHunk => Color::Rgb(64, 210, 255),
        Tone::Error => Color::Red,
        Tone::Plain => Color::Gray,
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

#[cfg(test)]
pub fn markdown_lines(content: &str, width: usize) -> Vec<RenderLine> {
    markdown_lines_with_cwd(content, width, None)
}

pub fn markdown_lines_with_cwd(content: &str, width: usize, cwd: Option<&Path>) -> Vec<RenderLine> {
    MarkdownRenderer::new(width, cwd).render(content)
}

pub fn ratatui_lines(lines: &[RenderLine], width: u16) -> Vec<RatLine<'static>> {
    lines.iter().map(|line| ratatui_line(line, width)).collect()
}

pub fn ratatui_line(line: &RenderLine, width: u16) -> RatLine<'static> {
    if line.spans.is_empty() {
        return ratatui_plain_line(line.text.clone(), line.tone, width);
    }

    RatLine::from(
        truncate_spans(&line.spans, width as usize)
            .into_iter()
            .map(|span| {
                let color = span.color();
                RatSpan::styled(
                    span.text,
                    Style::default().fg(color).add_modifier(span.modifier),
                )
            })
            .collect::<Vec<_>>(),
    )
}

pub fn ratatui_plain_line(text: impl Into<String>, tone: Tone, width: u16) -> RatLine<'static> {
    RatLine::from(RatSpan::styled(
        truncate(&text.into(), width as usize),
        Style::default().fg(color(tone)),
    ))
}

fn truncate_spans(spans: &[RenderSpan], max_width: usize) -> Vec<RenderSpan> {
    if max_width == 0 {
        return Vec::new();
    }

    let total_width = spans
        .iter()
        .map(|span| span.text.chars().count())
        .sum::<usize>();
    let mut remaining = max_width;
    let mut output = Vec::new();

    for span in spans {
        if remaining == 0 {
            break;
        }

        let span_width = span.text.chars().count();
        if span_width <= remaining {
            output.push(span.clone());
            remaining -= span_width;
        } else {
            let mut truncated = span.clone();
            truncated.text = span.text.chars().take(remaining).collect::<String>();
            output.push(truncated);
            remaining = 0;
        }
    }

    if total_width > max_width {
        if let Some(last) = output.last_mut() {
            last.text.pop();
            last.text.push('…');
        }
    }

    output
}

struct MarkdownRenderer {
    body_width: usize,
    cwd: Option<PathBuf>,
    lines: Vec<RenderLine>,
    active_text: Option<TextBlock>,
    text_spans: Vec<RenderSpan>,
    modifier_stack: Vec<Modifier>,
    code_block: Option<CodeBlock>,
    table: Option<TableBuilder>,
    list_stack: Vec<ListState>,
    link_stack: Vec<LinkContext>,
    image_stack: Vec<String>,
    item_depth: usize,
    pending_item_prefix: Option<String>,
    quote_depth: usize,
    footnote_prefix: Option<String>,
    local_link_target_just_rendered: bool,
    pending_local_link_soft_break: bool,
}

#[derive(Clone, Copy)]
enum TextBlock {
    Paragraph,
    Heading(HeadingLevel),
}

struct CodeBlock {
    language: String,
    source: String,
}

struct ListState {
    next: Option<u64>,
}

struct LinkContext {
    dest_url: String,
    label: String,
    local_target_display: Option<String>,
}

struct TableBuilder {
    alignments: Vec<Alignment>,
    rows: Vec<Vec<String>>,
    current_row: Option<Vec<String>>,
    current_cell: Option<String>,
    in_head: bool,
    header_rows: usize,
}

impl MarkdownRenderer {
    fn new(width: usize, cwd: Option<&Path>) -> Self {
        Self {
            body_width: width.saturating_sub(4).max(8),
            cwd: cwd.map(Path::to_path_buf),
            lines: Vec::new(),
            active_text: None,
            text_spans: Vec::new(),
            modifier_stack: Vec::new(),
            code_block: None,
            table: None,
            list_stack: Vec::new(),
            link_stack: Vec::new(),
            image_stack: Vec::new(),
            item_depth: 0,
            pending_item_prefix: None,
            quote_depth: 0,
            footnote_prefix: None,
            local_link_target_just_rendered: false,
            pending_local_link_soft_break: false,
        }
    }

    fn render(mut self, content: &str) -> Vec<RenderLine> {
        let mut options = Options::empty();
        options.insert(Options::ENABLE_TABLES);
        options.insert(Options::ENABLE_TASKLISTS);
        options.insert(Options::ENABLE_STRIKETHROUGH);
        options.insert(Options::ENABLE_FOOTNOTES);
        options.insert(Options::ENABLE_GFM);

        let normalized = normalize_nested_fences(content.trim());

        for event in Parser::new_ext(&normalized, options) {
            self.handle_event(event);
        }

        self.flush_text();

        if self.lines.is_empty() {
            self.lines.push(RenderLine::new("", Tone::Plain));
        }

        self.lines
    }

    fn handle_event(&mut self, event: Event<'_>) {
        match event {
            Event::Start(tag) => self.start_tag(tag),
            Event::End(tag) => self.end_tag(tag),
            Event::Text(text) => self.append_text(&text),
            Event::Code(code) => self.append_inline_code(&code),
            Event::Html(html) | Event::InlineHtml(html) => self.append_text(&html),
            Event::InlineMath(math) => self.append_text(&format!("${math}$")),
            Event::DisplayMath(math) => {
                self.flush_text();
                for line in math.lines() {
                    self.push_wrapped("$ ", line, "$", Tone::Assistant);
                }
            }
            Event::FootnoteReference(label) => self.append_text(&format!("[^{label}]")),
            Event::SoftBreak => self.soft_break(),
            Event::HardBreak => self.flush_text(),
            Event::Rule => {
                self.flush_text();
                self.lines.push(RenderLine::new(
                    "─".repeat(self.body_width.min(48)),
                    Tone::Border,
                ));
            }
            Event::TaskListMarker(done) => self.append_task_marker(done),
        }
    }

    fn start_tag(&mut self, tag: Tag<'_>) {
        match tag {
            Tag::Paragraph => self.active_text = Some(TextBlock::Paragraph),
            Tag::Heading { level, .. } => self.active_text = Some(TextBlock::Heading(level)),
            Tag::BlockQuote(_) => self.quote_depth += 1,
            Tag::FootnoteDefinition(label) => {
                self.flush_text();
                self.footnote_prefix = Some(format!("[^{label}]: "));
            }
            Tag::CodeBlock(kind) => {
                self.flush_text();
                self.code_block = Some(CodeBlock {
                    language: code_block_language(kind),
                    source: String::new(),
                });
            }
            Tag::List(start) => self.list_stack.push(ListState { next: start }),
            Tag::Item => self.start_item(),
            Tag::Table(alignments) => {
                self.flush_text();
                self.table = Some(TableBuilder::new(alignments));
            }
            Tag::TableHead => {
                if let Some(table) = self.table.as_mut() {
                    table.in_head = true;
                    table.current_row = Some(Vec::new());
                }
            }
            Tag::TableRow => {
                if let Some(table) = self.table.as_mut() {
                    table.current_row = Some(Vec::new());
                }
            }
            Tag::TableCell => {
                if let Some(table) = self.table.as_mut() {
                    table.current_cell = Some(String::new());
                }
            }
            Tag::Emphasis => {
                self.modifier_stack.push(Modifier::ITALIC);
            }
            Tag::Strong => {
                self.modifier_stack.push(Modifier::BOLD);
            }
            Tag::Strikethrough => {
                self.modifier_stack.push(Modifier::CROSSED_OUT);
            }
            Tag::Link { dest_url, .. } => {
                let dest_url = dest_url.to_string();
                self.link_stack.push(LinkContext {
                    local_target_display: local_link_target_display(&dest_url, self.cwd.as_deref()),
                    dest_url,
                    label: String::new(),
                })
            }
            Tag::Image { dest_url, .. } => self.image_stack.push(dest_url.to_string()),
            _ => {}
        }
    }

    fn end_tag(&mut self, tag: TagEnd) {
        match tag {
            TagEnd::Paragraph | TagEnd::Heading(_) => self.flush_text(),
            TagEnd::BlockQuote(_) => {
                self.flush_text();
                self.quote_depth = self.quote_depth.saturating_sub(1);
            }
            TagEnd::FootnoteDefinition => {
                self.flush_text();
                self.footnote_prefix = None;
            }
            TagEnd::CodeBlock => self.flush_code_block(),
            TagEnd::List(_) => {
                self.flush_text();
                self.list_stack.pop();
            }
            TagEnd::Item => {
                self.flush_text();
                self.item_depth = self.item_depth.saturating_sub(1);
                self.pending_item_prefix = None;
            }
            TagEnd::TableCell => {
                if let Some(table) = self.table.as_mut() {
                    table.finish_cell();
                }
            }
            TagEnd::TableRow => {
                if let Some(table) = self.table.as_mut() {
                    table.finish_row();
                }
            }
            TagEnd::TableHead => {
                if let Some(table) = self.table.as_mut() {
                    table.finish_row();
                    table.in_head = false;
                    table.header_rows = table.rows.len();
                }
            }
            TagEnd::Table => self.flush_table(),
            TagEnd::Emphasis => {
                self.modifier_stack.pop();
            }
            TagEnd::Strong => {
                self.modifier_stack.pop();
            }
            TagEnd::Strikethrough => {
                self.modifier_stack.pop();
            }
            TagEnd::Link => {
                if let Some(link) = self.link_stack.pop() {
                    if let Some(target) = link.local_target_display {
                        self.append_text(&target);
                        self.local_link_target_just_rendered = true;
                    } else if link.label.trim().is_empty() && !link.dest_url.is_empty() {
                        self.append_text(&link.dest_url);
                    } else if should_render_link_destination(&link) {
                        self.append_text(&format!(" ({})", link.dest_url));
                    }
                }
            }
            TagEnd::Image => {
                if let Some(dest_url) = self.image_stack.pop() {
                    if !dest_url.is_empty() {
                        self.append_text(&format!(" [image: {dest_url}]"));
                    }
                }
            }
            _ => {}
        }
    }

    fn append_text(&mut self, value: &str) {
        if let Some(link) = self.link_stack.last_mut() {
            link.label.push_str(value);
            if link.local_target_display.is_some() {
                return;
            }
        }

        if self.pending_local_link_soft_break {
            let add_space = !value.trim_start().starts_with(':');
            self.pending_local_link_soft_break = false;
            if add_space {
                self.append_text(" ");
            }
        }
        self.local_link_target_just_rendered = false;

        if let Some(code_block) = self.code_block.as_mut() {
            code_block.source.push_str(value);
            return;
        }

        if let Some(table) = self.table.as_mut() {
            table.append_cell_text(value);
            return;
        }

        if self.active_text.is_none() {
            self.active_text = Some(TextBlock::Paragraph);
        }

        self.push_text_span(value, Tone::Plain);
    }

    fn append_inline_code(&mut self, value: &str) {
        if let Some(link) = self.link_stack.last_mut() {
            link.label.push_str(value);
            if link.local_target_display.is_some() {
                return;
            }
        }

        if let Some(code_block) = self.code_block.as_mut() {
            code_block.source.push_str(value);
            return;
        }

        if let Some(table) = self.table.as_mut() {
            table.append_cell_text(value);
            return;
        }

        if self.active_text.is_none() {
            self.active_text = Some(TextBlock::Paragraph);
        }

        self.push_text_span(value, Tone::Code);
    }

    fn push_text_span(&mut self, value: &str, tone: Tone) {
        if value.is_empty() {
            return;
        }

        let mut modifier = self.current_modifier();
        if self
            .link_stack
            .last()
            .is_some_and(|link| link.local_target_display.is_none())
        {
            modifier.insert(Modifier::UNDERLINED);
        }

        push_span_text(&mut self.text_spans, value, tone, None, modifier);
    }

    fn current_modifier(&self) -> Modifier {
        let mut modifier = Modifier::empty();
        for item in &self.modifier_stack {
            modifier.insert(*item);
        }
        modifier
    }

    fn soft_break(&mut self) {
        if self.local_link_target_just_rendered {
            self.local_link_target_just_rendered = false;
            self.pending_local_link_soft_break = true;
        } else {
            self.append_text(" ");
        }
    }

    fn append_task_marker(&mut self, done: bool) {
        let marker = if done { "☑ " } else { "☐ " };

        if let Some(prefix) = self.pending_item_prefix.as_mut() {
            prefix.push_str(marker);
        } else {
            self.append_text(marker);
        }
    }

    fn start_item(&mut self) {
        self.item_depth += 1;

        let indent = "  ".repeat(self.item_depth.saturating_sub(1));
        let marker = match self
            .list_stack
            .last_mut()
            .and_then(|state| state.next.as_mut())
        {
            Some(next) => {
                let marker = format!("{next}. ");
                *next += 1;
                marker
            }
            None => "• ".to_string(),
        };

        self.pending_item_prefix = Some(format!("{indent}{marker}"));
    }

    fn flush_text(&mut self) {
        let Some(block) = self.active_text.take() else {
            return;
        };

        let body = trim_spans(&self.text_spans);
        if body.is_empty() {
            self.text_spans.clear();
            return;
        }

        let item_prefix = self.pending_item_prefix.clone();
        let footnote_prefix = self.footnote_prefix.clone();
        let quote_prefix = quote_prefix(self.quote_depth);
        let base_prefix = format!(
            "{}{}",
            quote_prefix,
            footnote_prefix.clone().unwrap_or_default()
        );
        let (prefix, tone) = match block {
            TextBlock::Heading(level) => (heading_prefix(level).to_string(), Tone::Accent),
            TextBlock::Paragraph => (
                item_prefix
                    .as_ref()
                    .map(|item_prefix| format!("{base_prefix}{item_prefix}"))
                    .unwrap_or_else(|| base_prefix.clone()),
                if self.quote_depth == 0 {
                    Tone::Assistant
                } else {
                    Tone::Dim
                },
            ),
        };

        let continuation_prefix = if let Some(item_prefix) = item_prefix.as_ref() {
            format!("{}{}", base_prefix, " ".repeat(item_prefix.chars().count()))
        } else if let Some(footnote_prefix) = footnote_prefix.as_ref() {
            format!(
                "{}{}",
                quote_prefix,
                " ".repeat(footnote_prefix.chars().count())
            )
        } else {
            prefix.clone()
        };

        self.push_wrapped_spans_with_continuation(&prefix, &continuation_prefix, &body, "", tone);
        self.pending_item_prefix = None;
        self.text_spans.clear();
    }

    fn flush_code_block(&mut self) {
        let Some(code_block) = self.code_block.take() else {
            return;
        };

        if is_mermaid_lang(&code_block.language) {
            self.lines.extend(render_mermaid_diagram(
                code_block.source.trim(),
                self.body_width,
            ));
        } else {
            self.lines.extend(render_code_block(
                &code_block.language,
                &code_block.source,
                self.body_width,
            ));
        }
    }

    fn flush_table(&mut self) {
        let Some(table) = self.table.take() else {
            return;
        };

        self.lines.extend(render_table(table, self.body_width));
    }

    fn push_wrapped(&mut self, prefix: &str, body: &str, suffix: &str, tone: Tone) {
        self.push_wrapped_with_continuation(prefix, prefix, body, suffix, tone);
    }

    fn push_wrapped_with_continuation(
        &mut self,
        first_prefix: &str,
        continuation_prefix: &str,
        body: &str,
        suffix: &str,
        tone: Tone,
    ) {
        let prefix_width = first_prefix.chars().count();
        let suffix_width = suffix.chars().count();
        let available = self
            .body_width
            .saturating_sub(prefix_width + suffix_width)
            .max(1);

        for (index, wrapped) in wrap(body, available).into_iter().enumerate() {
            let prefix = if index == 0 {
                first_prefix
            } else {
                continuation_prefix
            };
            self.lines
                .push(RenderLine::new(format!("{prefix}{wrapped}{suffix}"), tone));
        }
    }

    fn push_wrapped_spans_with_continuation(
        &mut self,
        first_prefix: &str,
        continuation_prefix: &str,
        body: &[RenderSpan],
        suffix: &str,
        tone: Tone,
    ) {
        let prefix_width = first_prefix.chars().count();
        let suffix_width = suffix.chars().count();
        let available = self
            .body_width
            .saturating_sub(prefix_width + suffix_width)
            .max(1);
        let body = spans_with_base_tone(body, tone);

        for (index, wrapped) in wrap_styled_spans(&body, available, tone)
            .into_iter()
            .enumerate()
        {
            let prefix = if index == 0 {
                first_prefix
            } else {
                continuation_prefix
            };
            let mut spans = vec![RenderSpan::new(prefix, tone)];
            spans.extend(wrapped);
            if !suffix.is_empty() {
                spans.push(RenderSpan::new(suffix, tone));
            }
            self.lines.push(RenderLine::styled(spans));
        }
    }
}

impl TableBuilder {
    fn new(alignments: Vec<Alignment>) -> Self {
        Self {
            alignments,
            rows: Vec::new(),
            current_row: None,
            current_cell: None,
            in_head: false,
            header_rows: 0,
        }
    }

    fn append_cell_text(&mut self, value: &str) {
        if let Some(cell) = self.current_cell.as_mut() {
            cell.push_str(value);
        }
    }

    fn finish_cell(&mut self) {
        if let (Some(row), Some(cell)) = (self.current_row.as_mut(), self.current_cell.take()) {
            row.push(cell.trim().to_string());
        }
    }

    fn finish_row(&mut self) {
        if let Some(row) = self.current_row.take() {
            self.rows.push(row);
            if self.in_head {
                self.header_rows = self.rows.len();
            }
        }
    }
}

fn code_block_language(kind: CodeBlockKind<'_>) -> String {
    match kind {
        CodeBlockKind::Fenced(info) => info
            .split([',', ' ', '\t'])
            .next()
            .unwrap_or_default()
            .to_string(),
        CodeBlockKind::Indented => String::new(),
    }
}

#[derive(Clone, Debug)]
struct FenceLine {
    ch: char,
    len: usize,
    has_info: bool,
    indent: usize,
}

fn normalize_nested_fences(markdown: &str) -> String {
    let lines = markdown.split_inclusive('\n').collect::<Vec<_>>();
    if lines.is_empty() {
        return String::new();
    }

    let fence_lines = lines
        .iter()
        .map(|line| parse_fence_line(line))
        .collect::<Vec<_>>();
    let mut rewrites = HashMap::new();
    let mut index = 0;

    while index < lines.len() {
        let Some(opener) = fence_lines[index].as_ref() else {
            index += 1;
            continue;
        };

        let mut max_inner_len = 0;
        let mut nested_depth = 0usize;
        let mut closer_index = None;

        for cursor in index + 1..lines.len() {
            let Some(candidate) = fence_lines[cursor].as_ref() else {
                continue;
            };
            if candidate.ch != opener.ch || candidate.len < opener.len {
                continue;
            }

            if candidate.has_info {
                nested_depth += 1;
                max_inner_len = max_inner_len.max(candidate.len);
                continue;
            }

            if nested_depth > 0 {
                nested_depth -= 1;
                max_inner_len = max_inner_len.max(candidate.len);
            } else {
                closer_index = Some(cursor);
                break;
            }
        }

        let Some(closer_index) = closer_index else {
            index += 1;
            continue;
        };

        if max_inner_len >= opener.len {
            let replacement_len = max_inner_len + 1;
            rewrites.insert(index, replacement_len);
            rewrites.insert(closer_index, replacement_len);
        }

        index = closer_index + 1;
    }

    if rewrites.is_empty() {
        return markdown.to_string();
    }

    let mut output = String::with_capacity(markdown.len() + rewrites.len());
    for (index, line) in lines.iter().enumerate() {
        if let Some(replacement_len) = rewrites.get(&index) {
            output.push_str(&rewrite_fence_line(line, *replacement_len));
        } else {
            output.push_str(line);
        }
    }

    output
}

fn parse_fence_line(line: &str) -> Option<FenceLine> {
    let body = line_body_without_ending(line);
    let indent = body.chars().take_while(|ch| *ch == ' ').count();
    if indent > 3 {
        return None;
    }

    let rest = &body[indent..];
    let ch = rest.chars().next()?;
    if ch != '`' && ch != '~' {
        return None;
    }

    let len = rest
        .chars()
        .take_while(|candidate| *candidate == ch)
        .count();
    if len < 3 {
        return None;
    }

    let after = &rest[len..];
    if ch == '`' && after.contains('`') {
        return None;
    }

    Some(FenceLine {
        ch,
        len,
        has_info: !after.trim().is_empty(),
        indent,
    })
}

fn line_body_without_ending(line: &str) -> &str {
    let body = line.strip_suffix('\n').unwrap_or(line);
    body.strip_suffix('\r').unwrap_or(body)
}

fn rewrite_fence_line(line: &str, len: usize) -> String {
    let (body, ending) = if let Some(body) = line.strip_suffix("\r\n") {
        (body, "\r\n")
    } else if let Some(body) = line.strip_suffix('\n') {
        (body, "\n")
    } else {
        (line, "")
    };

    let Some(fence) = parse_fence_line(line) else {
        return line.to_string();
    };
    let run_start = fence.indent;
    let run_end = run_start + fence.len;

    format!(
        "{}{}{}{}",
        &body[..run_start],
        fence.ch.to_string().repeat(len),
        &body[run_end..],
        ending
    )
}

fn heading_prefix(level: HeadingLevel) -> &'static str {
    match level {
        HeadingLevel::H1 => "# ",
        HeadingLevel::H2 => "## ",
        HeadingLevel::H3 => "### ",
        HeadingLevel::H4 => "#### ",
        HeadingLevel::H5 => "##### ",
        HeadingLevel::H6 => "###### ",
    }
}

fn quote_prefix(depth: usize) -> String {
    "› ".repeat(depth)
}

fn should_render_link_destination(link: &LinkContext) -> bool {
    let label = link.label.trim();
    let dest_url = link.dest_url.trim();

    !dest_url.is_empty() && label != dest_url && !is_local_path_like_link(dest_url)
}

fn local_link_target_display(dest_url: &str, cwd: Option<&Path>) -> Option<String> {
    if !is_local_path_like_link(dest_url) {
        return None;
    }

    let (path, suffix) = parse_local_link_target(dest_url)?;
    let mut display = display_local_link_path(&path, cwd);
    if let Some(suffix) = suffix {
        display.push_str(&suffix);
    }
    Some(display)
}

fn is_local_path_like_link(dest_url: &str) -> bool {
    dest_url.starts_with("file://")
        || dest_url.starts_with('/')
        || dest_url.starts_with("~/")
        || dest_url.starts_with("./")
        || dest_url.starts_with("../")
        || dest_url.starts_with("\\\\")
        || matches!(
            dest_url.as_bytes(),
            [drive, b':', separator, ..]
                if drive.is_ascii_alphabetic() && matches!(separator, b'/' | b'\\')
        )
}

fn parse_local_link_target(dest_url: &str) -> Option<(String, Option<String>)> {
    if let Some(file_url) = dest_url.strip_prefix("file://") {
        let (path, fragment) = split_hash_fragment(file_url);
        let path = file_url_path_text(path)?;
        let suffix = fragment.and_then(normalize_hash_location_fragment);
        return Some((percent_decode(&path), suffix));
    }

    let (mut path, fragment) = split_hash_fragment(dest_url);
    let mut suffix = fragment.and_then(normalize_hash_location_fragment);
    if suffix.is_none() {
        if let Some(location_suffix) = extract_colon_location_suffix(path) {
            path = &path[..path.len() - location_suffix.len()];
            suffix = Some(location_suffix);
        }
    }

    Some((percent_decode(path), suffix))
}

fn split_hash_fragment(value: &str) -> (&str, Option<&str>) {
    value
        .rsplit_once('#')
        .map(|(path, fragment)| (path, Some(fragment)))
        .unwrap_or((value, None))
}

fn file_url_path_text(value: &str) -> Option<String> {
    let path = if let Some(rest) = value.strip_prefix("localhost/") {
        format!("/{rest}")
    } else if value.starts_with('/') {
        value.to_string()
    } else {
        format!("//{value}")
    };

    (!path.is_empty()).then_some(path)
}

fn normalize_hash_location_fragment(fragment: &str) -> Option<String> {
    let (start, end) = fragment
        .split_once("-L")
        .map(|(start, end)| (start, Some(end)))
        .unwrap_or((fragment, None));
    let (line, column) = parse_hash_line_col(start)?;
    let mut suffix = format!(":{line}");
    if let Some(column) = column {
        suffix.push_str(&format!(":{column}"));
    }

    if let Some(end) = end {
        let (line, column) = parse_hash_line_col(end)?;
        suffix.push('-');
        suffix.push_str(&line.to_string());
        if let Some(column) = column {
            suffix.push_str(&format!(":{column}"));
        }
    }

    Some(suffix)
}

fn parse_hash_line_col(value: &str) -> Option<(usize, Option<usize>)> {
    let value = value.strip_prefix('L')?;
    let (line, column) = value
        .split_once('C')
        .map(|(line, column)| (line, Some(column)))
        .unwrap_or((value, None));
    let line = line.parse::<usize>().ok()?;
    let column = column.map(str::parse).transpose().ok()?;
    Some((line, column))
}

fn extract_colon_location_suffix(path: &str) -> Option<String> {
    path.char_indices()
        .filter(|(_, ch)| *ch == ':')
        .find_map(|(index, _)| {
            let suffix = &path[index..];
            valid_colon_location_suffix(suffix).then(|| suffix.to_string())
        })
}

fn valid_colon_location_suffix(suffix: &str) -> bool {
    let Some(rest) = suffix.strip_prefix(':') else {
        return false;
    };
    let (start, end) = rest
        .split_once(['-', '–'])
        .map(|(start, end)| (start, Some(end)))
        .unwrap_or((rest, None));

    valid_line_col(start) && end.map(valid_line_col).unwrap_or(true)
}

fn valid_line_col(value: &str) -> bool {
    let (line, column) = value
        .split_once(':')
        .map(|(line, column)| (line, Some(column)))
        .unwrap_or((value, None));

    !line.is_empty()
        && line.chars().all(|ch| ch.is_ascii_digit())
        && column
            .map(|column| !column.is_empty() && column.chars().all(|ch| ch.is_ascii_digit()))
            .unwrap_or(true)
}

fn normalize_local_path_text(path: &str) -> String {
    if let Some(rest) = path.strip_prefix("\\\\") {
        format!("//{}", rest.replace('\\', "/").trim_start_matches('/'))
    } else {
        path.replace('\\', "/")
    }
}

fn display_local_link_path(path: &str, cwd: Option<&Path>) -> String {
    let path = normalize_local_path_text(path);
    if !is_absolute_local_path(&path) {
        return path;
    }

    if let Some(cwd) = cwd {
        let cwd = normalize_local_path_text(&cwd.to_string_lossy());
        if let Some(relative) = strip_local_path_prefix(&path, &cwd) {
            return relative.to_string();
        }
    }

    path
}

fn is_absolute_local_path(path: &str) -> bool {
    path.starts_with('/')
        || path.starts_with("//")
        || matches!(
            path.as_bytes(),
            [drive, b':', b'/', ..] if drive.is_ascii_alphabetic()
        )
}

fn strip_local_path_prefix<'a>(path: &'a str, cwd: &str) -> Option<&'a str> {
    let path = trim_trailing_local_path_separator(path);
    let cwd = trim_trailing_local_path_separator(cwd);
    if path == cwd {
        return None;
    }

    if cwd == "/" || cwd == "//" {
        return path.strip_prefix('/');
    }

    path.strip_prefix(cwd)
        .and_then(|rest| rest.strip_prefix('/'))
}

fn trim_trailing_local_path_separator(path: &str) -> &str {
    if path == "/" || path == "//" {
        return path;
    }
    if matches!(path.as_bytes(), [drive, b':', b'/'] if drive.is_ascii_alphabetic()) {
        return path;
    }
    path.trim_end_matches('/')
}

fn percent_decode(value: &str) -> String {
    let bytes = value.as_bytes();
    let mut output = String::with_capacity(value.len());
    let mut index = 0;

    while index < bytes.len() {
        if bytes[index] == b'%' && index + 2 < bytes.len() {
            if let Some(decoded) = decode_hex_byte(bytes[index + 1], bytes[index + 2]) {
                output.push(decoded as char);
                index += 3;
                continue;
            }
        }

        output.push(bytes[index] as char);
        index += 1;
    }

    output
}

fn decode_hex_byte(high: u8, low: u8) -> Option<u8> {
    Some((hex_value(high)? << 4) | hex_value(low)?)
}

fn hex_value(value: u8) -> Option<u8> {
    match value {
        b'0'..=b'9' => Some(value - b'0'),
        b'a'..=b'f' => Some(value - b'a' + 10),
        b'A'..=b'F' => Some(value - b'A' + 10),
        _ => None,
    }
}

fn is_mermaid_lang(lang: &str) -> bool {
    lang.eq_ignore_ascii_case("mermaid")
}

fn render_mermaid_diagram(source: &str, width: usize) -> Vec<RenderLine> {
    let mut output = vec![RenderLine::new("╭─ mermaid diagram", Tone::Border)];

    match mermaid_text::render_with_width(source, Some(width)) {
        Ok(rendered) => {
            let rendered = rendered.trim_end();
            if rendered.is_empty() {
                output.push(RenderLine::new("│ empty diagram", Tone::Dim));
            } else {
                let lines = rendered.lines().collect::<Vec<_>>();
                let truncated = lines.len() > MAX_RENDERED_MERMAID_LINES;

                for line in lines.iter().take(MAX_RENDERED_MERMAID_LINES) {
                    output.push(RenderLine::new(
                        truncate(&format!("│ {line}"), width + 2),
                        Tone::Assistant,
                    ));
                }

                if truncated {
                    output.push(RenderLine::new(
                        truncate(
                            &format!(
                                "│ … diagram truncated: showing {} of {} rendered lines",
                                MAX_RENDERED_MERMAID_LINES,
                                lines.len()
                            ),
                            width + 2,
                        ),
                        Tone::Dim,
                    ));
                }
            }
        }
        Err(error) => output.push(RenderLine::new(
            truncate(&format!("│ Mermaid render error: {error}"), width + 2),
            Tone::Error,
        )),
    }

    output.push(RenderLine::new("╰─", Tone::Border));
    output
}

fn render_code_block(language: &str, source: &str, width: usize) -> Vec<RenderLine> {
    if is_diff_lang(language) || looks_like_unified_diff(source) {
        return render_diff_block(language, source, width);
    }

    let mut output = vec![RenderLine::new(
        truncate(&code_block_label(language), width + 2),
        Tone::Border,
    )];

    let mut highlighter = CodeHighlighter::new(language);

    for line in source.trim_end().lines() {
        output.extend(render_highlighted_code_line(&mut highlighter, line, width));
    }

    output.push(RenderLine::new("╰─", Tone::Border));
    output
}

fn render_highlighted_code_line(
    highlighter: &mut CodeHighlighter<'static>,
    line: &str,
    width: usize,
) -> Vec<RenderLine> {
    let prefix = "│ ";
    let available = width
        .saturating_add(2)
        .saturating_sub(prefix.chars().count())
        .max(1);
    let highlighted = highlighter.highlight_line(line);

    wrap_spans_preserving(&highlighted, available)
        .into_iter()
        .map(|spans| {
            let mut line_spans = vec![RenderSpan::new(prefix, Tone::Border)];
            line_spans.extend(spans);
            RenderLine::styled(line_spans)
        })
        .collect()
}

struct SyntaxAssets {
    syntax_set: SyntaxSet,
    theme: Theme,
}

struct CodeHighlighter<'a> {
    assets: &'a SyntaxAssets,
    highlighter: HighlightLines<'a>,
}

impl CodeHighlighter<'static> {
    fn new(language: &str) -> Self {
        let assets = syntax_assets();
        let syntax = find_code_syntax(language, &assets.syntax_set);
        let highlighter = HighlightLines::new(syntax, &assets.theme);

        Self {
            assets,
            highlighter,
        }
    }

    fn highlight_line(&mut self, line: &str) -> Vec<RenderSpan> {
        let ranges = self
            .highlighter
            .highlight_line(line, &self.assets.syntax_set)
            .expect("syntect code highlighting failed");
        let mut spans = ranges
            .into_iter()
            .filter(|(_, text)| !text.is_empty())
            .map(|(style, text)| {
                RenderSpan::colored(text.to_string(), Tone::Code, syntect_color(style))
            })
            .collect::<Vec<_>>();

        if spans.is_empty() {
            spans.push(RenderSpan::new(String::new(), Tone::Code));
        }

        spans
    }
}

fn syntax_assets() -> &'static SyntaxAssets {
    static ASSETS: OnceLock<SyntaxAssets> = OnceLock::new();

    ASSETS.get_or_init(|| {
        let syntax_set = SyntaxSet::load_defaults_newlines();
        let theme = ThemeSet::load_defaults()
            .themes
            .remove("base16-ocean.dark")
            .expect("syntect default theme base16-ocean.dark is required");

        SyntaxAssets { syntax_set, theme }
    })
}

fn find_code_syntax<'a>(
    language: &str,
    syntax_set: &'a SyntaxSet,
) -> &'a syntect::parsing::SyntaxReference {
    let token = language
        .split_whitespace()
        .next()
        .unwrap_or_default()
        .trim()
        .trim_start_matches('.')
        .to_ascii_lowercase();

    if token.is_empty() {
        return syntax_set.find_syntax_plain_text();
    }

    syntax_set
        .find_syntax_by_token(&token)
        .or_else(|| syntax_set.find_syntax_by_name(&token))
        .unwrap_or_else(|| syntax_set.find_syntax_plain_text())
}

fn syntect_color(style: SyntectStyle) -> Color {
    let SyntectColor { r, g, b, .. } = style.foreground;
    Color::Rgb(r, g, b)
}

fn wrap_spans_preserving(spans: &[RenderSpan], max_width: usize) -> Vec<Vec<RenderSpan>> {
    if max_width == 0 {
        return vec![Vec::new()];
    }

    let mut lines = Vec::new();
    let mut current = Vec::new();
    let mut width = 0;

    for span in spans {
        for ch in span.text.chars() {
            if width == max_width {
                lines.push(current);
                current = Vec::new();
                width = 0;
            }

            push_span_char(&mut current, ch, span.tone, span.foreground, span.modifier);
            width += 1;
        }
    }

    if current.is_empty() {
        vec![vec![RenderSpan::new(String::new(), Tone::Code)]]
    } else {
        lines.push(current);
        lines
    }
}

fn wrap_styled_spans(
    spans: &[RenderSpan],
    max_width: usize,
    space_tone: Tone,
) -> Vec<Vec<RenderSpan>> {
    if max_width == 0 {
        return vec![Vec::new()];
    }

    let words = styled_words(spans);
    let mut lines = Vec::new();
    let mut current = Vec::new();
    let mut current_width = 0usize;

    for word in words {
        let word_width = span_text_width(&word);
        if word_width > max_width {
            if !current.is_empty() {
                lines.push(current);
                current = Vec::new();
                current_width = 0;
            }

            let chunks = split_styled_word(&word, max_width);
            for chunk in chunks.iter().take(chunks.len().saturating_sub(1)) {
                lines.push(chunk.clone());
            }
            if let Some(last) = chunks.last() {
                current_width = span_text_width(last);
                current = last.clone();
            }
            continue;
        }

        let extra = usize::from(!current.is_empty());
        if current_width + word_width + extra > max_width && !current.is_empty() {
            lines.push(current);
            current = Vec::new();
            current_width = 0;
        }

        if !current.is_empty() {
            let (separator_tone, separator_foreground, separator_modifier) = current
                .last()
                .zip(word.first())
                .filter(|(left, right)| same_span_style(left, right))
                .map(|(left, _right)| (left.tone, left.foreground, left.modifier))
                .unwrap_or((space_tone, None, Modifier::empty()));
            push_span_text(
                &mut current,
                " ",
                separator_tone,
                separator_foreground,
                separator_modifier,
            );
            current_width += 1;
        }
        extend_spans(&mut current, &word);
        current_width += word_width;
    }

    if current.is_empty() {
        vec![vec![RenderSpan::new(String::new(), space_tone)]]
    } else {
        lines.push(current);
        lines
    }
}

fn styled_words(spans: &[RenderSpan]) -> Vec<Vec<RenderSpan>> {
    let mut words = Vec::new();
    let mut current = Vec::new();

    for span in spans {
        for ch in span.text.chars() {
            if ch.is_whitespace() {
                if !current.is_empty() {
                    words.push(current);
                    current = Vec::new();
                }
            } else {
                push_span_char(&mut current, ch, span.tone, span.foreground, span.modifier);
            }
        }
    }

    if !current.is_empty() {
        words.push(current);
    }

    words
}

fn split_styled_word(word: &[RenderSpan], max_width: usize) -> Vec<Vec<RenderSpan>> {
    let mut chunks = Vec::new();
    let mut current = Vec::new();
    let mut width = 0usize;

    for span in word {
        for ch in span.text.chars() {
            if width == max_width {
                chunks.push(current);
                current = Vec::new();
                width = 0;
            }
            push_span_char(&mut current, ch, span.tone, span.foreground, span.modifier);
            width += 1;
        }
    }

    if !current.is_empty() {
        chunks.push(current);
    }

    chunks
}

fn span_text_width(spans: &[RenderSpan]) -> usize {
    spans
        .iter()
        .map(|span| span.text.chars().count())
        .sum::<usize>()
}

fn extend_spans(output: &mut Vec<RenderSpan>, spans: &[RenderSpan]) {
    for span in spans {
        push_span_text(
            output,
            &span.text,
            span.tone,
            span.foreground,
            span.modifier,
        );
    }
}

fn same_span_style(left: &RenderSpan, right: &RenderSpan) -> bool {
    left.tone == right.tone
        && left.foreground == right.foreground
        && left.modifier == right.modifier
}

fn spans_with_base_tone(spans: &[RenderSpan], base_tone: Tone) -> Vec<RenderSpan> {
    spans
        .iter()
        .cloned()
        .map(|mut span| {
            if span.tone == Tone::Plain && span.foreground.is_none() {
                span.tone = base_tone;
            }
            span
        })
        .collect()
}

fn trim_spans(spans: &[RenderSpan]) -> Vec<RenderSpan> {
    let mut output = spans.to_vec();

    while output
        .first()
        .is_some_and(|span| span.text.chars().all(char::is_whitespace))
    {
        output.remove(0);
    }
    while output
        .last()
        .is_some_and(|span| span.text.chars().all(char::is_whitespace))
    {
        output.pop();
    }

    if let Some(first) = output.first_mut() {
        first.text = first.text.trim_start().to_string();
    }
    if let Some(last) = output.last_mut() {
        last.text = last.text.trim_end().to_string();
    }

    output.retain(|span| !span.text.is_empty());
    output
}

fn push_span_text(
    spans: &mut Vec<RenderSpan>,
    text: &str,
    tone: Tone,
    foreground: Option<Color>,
    modifier: Modifier,
) {
    if text.is_empty() {
        return;
    }

    if let Some(last) = spans.last_mut() {
        if last.tone == tone && last.foreground == foreground && last.modifier == modifier {
            last.text.push_str(text);
            return;
        }
    }

    spans.push(RenderSpan {
        text: text.to_string(),
        tone,
        foreground,
        modifier,
    });
}

fn push_span_char(
    spans: &mut Vec<RenderSpan>,
    ch: char,
    tone: Tone,
    foreground: Option<Color>,
    modifier: Modifier,
) {
    if let Some(last) = spans.last_mut() {
        if last.tone == tone && last.foreground == foreground && last.modifier == modifier {
            last.text.push(ch);
            return;
        }
    }

    spans.push(RenderSpan {
        text: ch.to_string(),
        tone,
        foreground,
        modifier,
    });
}

fn render_diff_block(language: &str, source: &str, width: usize) -> Vec<RenderLine> {
    let mut output = vec![RenderLine::new(
        truncate(&code_block_label(language), width + 2),
        Tone::Border,
    )];
    output.extend(render_diff_file_overview(source, width));
    let gutter_width = diff_gutter_width(source);
    let mut old_line = None;
    let mut new_line = None;
    let mut old_header_language = None;
    let mut current_language = None;

    for line in source.trim_end().lines() {
        if let Some((old_start, new_start)) = parse_hunk_header(line) {
            old_line = Some(old_start);
            new_line = Some(new_start);
            output.extend(
                prefixed_wrapped_lines("│     ", line, width)
                    .into_iter()
                    .map(|line| RenderLine::new(line, Tone::DiffHunk)),
            );
            continue;
        }

        if line.starts_with("diff --git ") || line.starts_with("index ") {
            if let Some((_old_path, new_path)) = parse_diff_git_line(line) {
                current_language = diff_path_language(&new_path);
            }
            output.extend(
                prefixed_wrapped_lines("│     ", line, width)
                    .into_iter()
                    .map(|line| RenderLine::new(line, Tone::Dim)),
            );
            continue;
        }

        if line.starts_with("--- ") {
            old_header_language = line.strip_prefix("--- ").and_then(diff_path_language);
            output.extend(
                prefixed_wrapped_lines("│     ", line, width)
                    .into_iter()
                    .map(|line| RenderLine::new(line, Tone::DiffDelete)),
            );
            continue;
        }

        if line.starts_with("+++ ") {
            current_language = line
                .strip_prefix("+++ ")
                .and_then(diff_path_language)
                .or_else(|| old_header_language.clone());
            output.extend(
                prefixed_wrapped_lines("│     ", line, width)
                    .into_iter()
                    .map(|line| RenderLine::new(line, Tone::DiffAdd)),
            );
            continue;
        }

        if let Some(content) = line.strip_prefix('+') {
            output.extend(render_diff_lines(
                None,
                new_line,
                '+',
                content,
                gutter_width,
                width,
                Tone::DiffAdd,
                current_language.as_deref(),
            ));
            new_line = new_line.map(|line| line + 1);
            continue;
        }

        if let Some(content) = line.strip_prefix('-') {
            output.extend(render_diff_lines(
                old_line,
                None,
                '-',
                content,
                gutter_width,
                width,
                Tone::DiffDelete,
                current_language.as_deref(),
            ));
            old_line = old_line.map(|line| line + 1);
            continue;
        }

        if let Some(content) = line.strip_prefix(' ') {
            output.extend(render_diff_lines(
                old_line,
                new_line,
                ' ',
                content,
                gutter_width,
                width,
                Tone::Code,
                current_language.as_deref(),
            ));
            old_line = old_line.map(|line| line + 1);
            new_line = new_line.map(|line| line + 1);
            continue;
        }

        output.extend(
            prefixed_wrapped_lines("│     ", line, width)
                .into_iter()
                .map(|line| RenderLine::new(line, Tone::Dim)),
        );
    }

    output.push(RenderLine::new("╰─", Tone::Border));
    output
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct DiffFileSummary {
    status: DiffFileStatus,
    old_path: String,
    new_path: String,
    additions: usize,
    deletions: usize,
}

impl DiffFileSummary {
    fn display_path(&self) -> String {
        match self.status {
            DiffFileStatus::Renamed => format!("{} -> {}", self.old_path, self.new_path),
            DiffFileStatus::Added => self.new_path.clone(),
            DiffFileStatus::Deleted => self.old_path.clone(),
            DiffFileStatus::Edited => self.new_path.clone(),
        }
    }

    fn label(&self) -> &'static str {
        match self.status {
            DiffFileStatus::Added => "added",
            DiffFileStatus::Deleted => "deleted",
            DiffFileStatus::Edited => "edited",
            DiffFileStatus::Renamed => "renamed",
        }
    }

    fn tone(&self) -> Tone {
        match self.status {
            DiffFileStatus::Added => Tone::DiffAdd,
            DiffFileStatus::Deleted => Tone::DiffDelete,
            DiffFileStatus::Edited => Tone::Code,
            DiffFileStatus::Renamed => Tone::DiffHunk,
        }
    }

    fn display_line(&self) -> String {
        format!(
            "{:<7} {} (+{} -{})",
            self.label(),
            self.display_path(),
            self.additions,
            self.deletions
        )
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum DiffFileStatus {
    Added,
    Deleted,
    Edited,
    Renamed,
}

#[derive(Clone, Debug)]
struct PartialDiffFileSummary {
    old_path: String,
    new_path: String,
    old_header_path: Option<String>,
    new_header_path: Option<String>,
    rename_from: Option<String>,
    rename_to: Option<String>,
    new_file: bool,
    deleted_file: bool,
    additions: usize,
    deletions: usize,
}

impl PartialDiffFileSummary {
    fn new(old_path: String, new_path: String) -> Self {
        Self {
            old_path,
            new_path,
            old_header_path: None,
            new_header_path: None,
            rename_from: None,
            rename_to: None,
            new_file: false,
            deleted_file: false,
            additions: 0,
            deletions: 0,
        }
    }

    fn finish(self) -> DiffFileSummary {
        let old_path = self
            .rename_from
            .or_else(|| self.old_header_path.clone())
            .filter(|path| path != "/dev/null")
            .unwrap_or(self.old_path);
        let new_path = self
            .rename_to
            .or_else(|| self.new_header_path.clone())
            .filter(|path| path != "/dev/null")
            .unwrap_or(self.new_path);
        let old_header_is_null = self.old_header_path.as_deref() == Some("/dev/null");
        let new_header_is_null = self.new_header_path.as_deref() == Some("/dev/null");
        let status = if self.new_file || old_header_is_null {
            DiffFileStatus::Added
        } else if self.deleted_file || new_header_is_null {
            DiffFileStatus::Deleted
        } else if old_path != new_path {
            DiffFileStatus::Renamed
        } else {
            DiffFileStatus::Edited
        };

        DiffFileSummary {
            status,
            old_path,
            new_path,
            additions: self.additions,
            deletions: self.deletions,
        }
    }
}

fn render_diff_file_overview(source: &str, width: usize) -> Vec<RenderLine> {
    let summaries = diff_file_summaries(source);

    if summaries.is_empty() {
        return Vec::new();
    }

    let total_additions = summaries
        .iter()
        .map(|summary| summary.additions)
        .sum::<usize>();
    let total_deletions = summaries
        .iter()
        .map(|summary| summary.deletions)
        .sum::<usize>();
    let files_label = if summaries.len() == 1 {
        "file"
    } else {
        "files"
    };
    let mut output = prefixed_wrapped_lines(
        "│   ",
        &format!(
            "{} {files_label} changed (+{} -{})",
            summaries.len(),
            total_additions,
            total_deletions
        ),
        width,
    )
    .into_iter()
    .map(|line| RenderLine::new(line, Tone::Dim))
    .collect::<Vec<_>>();

    for summary in summaries {
        output.extend(
            prefixed_wrapped_lines("│   ", &summary.display_line(), width)
                .into_iter()
                .map(|line| RenderLine::new(line, summary.tone())),
        );
    }

    output.push(RenderLine::new("│", Tone::Border));
    output
}

fn diff_file_summaries(source: &str) -> Vec<DiffFileSummary> {
    let mut summaries = Vec::new();
    let mut current = None;

    for line in source.trim_end().lines() {
        if let Some((old_path, new_path)) = parse_diff_git_line(line) {
            if let Some(summary) = current.take() {
                summaries.push(PartialDiffFileSummary::finish(summary));
            }
            current = Some(PartialDiffFileSummary::new(old_path, new_path));
            continue;
        }

        let Some(summary) = current.as_mut() else {
            continue;
        };

        if line.starts_with("new file mode ") {
            summary.new_file = true;
        } else if line.starts_with("deleted file mode ") {
            summary.deleted_file = true;
        } else if let Some(path) = line.strip_prefix("rename from ") {
            summary.rename_from = Some(path.to_string());
        } else if let Some(path) = line.strip_prefix("rename to ") {
            summary.rename_to = Some(path.to_string());
        } else if let Some(path) = line.strip_prefix("--- ") {
            summary.old_header_path = Some(normalize_diff_path(path));
        } else if let Some(path) = line.strip_prefix("+++ ") {
            summary.new_header_path = Some(normalize_diff_path(path));
        } else if line.starts_with('+') {
            summary.additions += 1;
        } else if line.starts_with('-') {
            summary.deletions += 1;
        }
    }

    if let Some(summary) = current {
        summaries.push(summary.finish());
    }

    summaries
}

fn parse_diff_git_line(line: &str) -> Option<(String, String)> {
    let value = line.strip_prefix("diff --git ")?;
    let (old_path, new_path) = value.split_once(" b/")?;
    Some((normalize_diff_path(old_path), normalize_diff_path(new_path)))
}

fn normalize_diff_path(path: &str) -> String {
    path.strip_prefix("a/")
        .or_else(|| path.strip_prefix("b/"))
        .unwrap_or(path)
        .to_string()
}

fn diff_path_language(path: &str) -> Option<String> {
    let path = normalize_diff_path(path);
    if path == "/dev/null" {
        return None;
    }

    let path = Path::new(&path);
    path.extension()
        .and_then(|extension| extension.to_str())
        .or_else(|| path.file_name().and_then(|name| name.to_str()))
        .map(str::trim)
        .filter(|token| !token.is_empty())
        .map(str::to_string)
}

fn code_block_label(language: &str) -> String {
    if language.is_empty() {
        "╭─ code".to_string()
    } else {
        format!("╭─ {language}")
    }
}

fn is_diff_lang(language: &str) -> bool {
    matches!(
        language.to_ascii_lowercase().as_str(),
        "diff" | "patch" | "udiff" | "gitdiff"
    )
}

fn looks_like_unified_diff(source: &str) -> bool {
    source.lines().any(|line| line.starts_with("@@ "))
        && source
            .lines()
            .any(|line| line.starts_with('+') || line.starts_with('-'))
}

fn parse_hunk_header(line: &str) -> Option<(usize, usize)> {
    if !line.starts_with("@@ ") {
        return None;
    }

    let mut old_start = None;
    let mut new_start = None;

    for part in line.split_whitespace() {
        if let Some(value) = part.strip_prefix('-') {
            old_start = parse_hunk_start(value);
        } else if let Some(value) = part.strip_prefix('+') {
            new_start = parse_hunk_start(value);
        }
    }

    Some((old_start?, new_start?))
}

fn parse_hunk_start(value: &str) -> Option<usize> {
    value
        .split(',')
        .next()
        .filter(|start| !start.is_empty())
        .and_then(|start| start.parse::<usize>().ok())
}

fn diff_gutter_width(source: &str) -> usize {
    let mut old_line = None;
    let mut new_line = None;
    let mut max_line = 0;

    for line in source.trim_end().lines() {
        if let Some((old_start, new_start)) = parse_hunk_header(line) {
            old_line = Some(old_start);
            new_line = Some(new_start);
            max_line = max_line.max(old_start).max(new_start);
            continue;
        }

        if line.starts_with("diff --git ")
            || line.starts_with("index ")
            || line.starts_with("--- ")
            || line.starts_with("+++ ")
        {
            continue;
        }

        if line.starts_with('+') {
            if let Some(line) = new_line {
                max_line = max_line.max(line);
                new_line = Some(line + 1);
            }
            continue;
        }

        if line.starts_with('-') {
            if let Some(line) = old_line {
                max_line = max_line.max(line);
                old_line = Some(line + 1);
            }
            continue;
        }

        if line.starts_with(' ') {
            if let Some(line) = old_line {
                max_line = max_line.max(line);
                old_line = Some(line + 1);
            }
            if let Some(line) = new_line {
                max_line = max_line.max(line);
                new_line = Some(line + 1);
            }
        }
    }

    decimal_width(max_line).max(4)
}

fn decimal_width(mut value: usize) -> usize {
    let mut width = 1;
    while value >= 10 {
        value /= 10;
        width += 1;
    }
    width
}

fn render_diff_lines(
    old_line: Option<usize>,
    new_line: Option<usize>,
    sign: char,
    content: &str,
    gutter_width: usize,
    width: usize,
    tone: Tone,
    language: Option<&str>,
) -> Vec<RenderLine> {
    diff_line_parts(old_line, new_line, sign, content, gutter_width, width)
        .into_iter()
        .map(|(prefix, wrapped)| {
            let mut spans = vec![RenderSpan::new(prefix, tone)];
            spans.extend(highlight_diff_content(&wrapped, tone, language));
            RenderLine::styled(spans)
        })
        .collect()
}

fn diff_line_parts(
    old_line: Option<usize>,
    new_line: Option<usize>,
    sign: char,
    content: &str,
    gutter_width: usize,
    width: usize,
) -> Vec<(String, String)> {
    let old = old_line
        .map(|line| format!("{line:>gutter_width$}"))
        .unwrap_or_else(|| " ".repeat(gutter_width));
    let new = new_line
        .map(|line| format!("{line:>gutter_width$}"))
        .unwrap_or_else(|| " ".repeat(gutter_width));
    let first_prefix = format!("│ {old} {new} {sign} ");
    let continuation_prefix = format!(
        "│ {} {}   ",
        " ".repeat(gutter_width),
        " ".repeat(gutter_width)
    );
    let available = width
        .saturating_add(2)
        .saturating_sub(first_prefix.chars().count())
        .max(1);

    wrap_diff_content(content, available)
        .into_iter()
        .enumerate()
        .map(|(index, wrapped)| {
            let prefix = if index == 0 {
                first_prefix.as_str()
            } else {
                continuation_prefix.as_str()
            };
            (prefix.to_string(), wrapped)
        })
        .collect()
}

fn highlight_diff_content(
    content: &str,
    fallback_tone: Tone,
    language: Option<&str>,
) -> Vec<RenderSpan> {
    let Some(language) = language.filter(|language| !language.trim().is_empty()) else {
        return vec![RenderSpan::new(content.to_string(), fallback_tone)];
    };

    let mut highlighter = CodeHighlighter::new(language);
    highlighter
        .highlight_line(content)
        .into_iter()
        .map(|mut span| {
            span.tone = fallback_tone;
            span
        })
        .collect()
}

fn wrap_diff_content(content: &str, max_width: usize) -> Vec<String> {
    let indent_len = content.chars().take_while(|ch| ch.is_whitespace()).count();

    if indent_len == 0 {
        return wrap(content, max_width);
    }

    let indent = content.chars().take(indent_len).collect::<String>();
    let body = content.chars().skip(indent_len).collect::<String>();
    if body.is_empty() {
        return vec![indent];
    }

    let body_width = max_width.saturating_sub(indent_len).max(1);
    wrap(&body, body_width)
        .into_iter()
        .map(|line| format!("{indent}{line}"))
        .collect()
}

fn prefixed_wrapped_lines(prefix: &str, content: &str, width: usize) -> Vec<String> {
    let available = width
        .saturating_add(2)
        .saturating_sub(prefix.chars().count())
        .max(1);

    wrap(content, available)
        .into_iter()
        .map(|wrapped| truncate(&format!("{prefix}{wrapped}"), width + 2))
        .collect()
}

fn render_table(table: TableBuilder, width: usize) -> Vec<RenderLine> {
    if table.rows.is_empty() {
        return Vec::new();
    }

    let columns = table.rows.iter().map(Vec::len).max().unwrap_or(0);
    if columns == 0 {
        return Vec::new();
    }

    let cell_budget = width.saturating_sub((columns * 3) + 1).max(columns * 3) / columns;
    let widths: Vec<usize> = (0..columns)
        .map(|index| {
            table
                .rows
                .iter()
                .filter_map(|row| row.get(index))
                .map(|cell| cell.chars().count())
                .max()
                .unwrap_or(3)
                .clamp(3, cell_budget.max(3))
        })
        .collect();

    let header_rows = table.header_rows.max(1).min(table.rows.len());
    let mut output = Vec::new();

    output.push(RenderLine::new(
        table_border('┌', '┬', '┐', &widths),
        Tone::Border,
    ));

    for (row_index, row) in table.rows.iter().enumerate() {
        let tone = if row_index < header_rows {
            Tone::Accent
        } else {
            Tone::Assistant
        };

        for line in table_row_lines(row, &table.alignments, &widths) {
            output.push(RenderLine::new(line, tone));
        }

        if row_index + 1 == header_rows {
            output.push(RenderLine::new(
                table_border('├', '┼', '┤', &widths),
                Tone::Border,
            ));
        }
    }

    output.push(RenderLine::new(
        table_border('└', '┴', '┘', &widths),
        Tone::Border,
    ));
    output
}

fn table_border(left: char, join: char, right: char, widths: &[usize]) -> String {
    let mut line = String::new();
    line.push(left);
    for (index, width) in widths.iter().enumerate() {
        if index > 0 {
            line.push(join);
        }
        line.push_str(&"─".repeat(*width + 2));
    }
    line.push(right);
    line
}

fn table_row_lines(row: &[String], alignments: &[Alignment], widths: &[usize]) -> Vec<String> {
    let wrapped_cells = widths
        .iter()
        .enumerate()
        .map(|(index, width)| {
            let value = row.get(index).map(String::as_str).unwrap_or_default();
            wrap(value, *width)
        })
        .collect::<Vec<_>>();
    let row_height = wrapped_cells.iter().map(Vec::len).max().unwrap_or(1).max(1);

    (0..row_height)
        .map(|line_index| table_row_line_with_cells(&wrapped_cells, alignments, widths, line_index))
        .collect()
}

fn table_row_line_with_cells(
    cells: &[Vec<String>],
    alignments: &[Alignment],
    widths: &[usize],
    line_index: usize,
) -> String {
    let mut line = String::from("│");
    for (index, width) in widths.iter().enumerate() {
        let value = cells
            .get(index)
            .and_then(|cell| cell.get(line_index))
            .map(String::as_str)
            .unwrap_or_default();
        let alignment = alignments.get(index).copied().unwrap_or(Alignment::None);
        line.push(' ');
        line.push_str(&pad_cell(&truncate(value, *width), *width, alignment));
        line.push(' ');
        line.push('│');
    }
    line
}

fn pad_cell(value: &str, width: usize, alignment: Alignment) -> String {
    let value_width = value.chars().count();
    if value_width >= width {
        return value.to_string();
    }

    let padding = width - value_width;
    match alignment {
        Alignment::Right => format!("{}{value}", " ".repeat(padding)),
        Alignment::Center => {
            let left = padding / 2;
            let right = padding - left;
            format!("{}{value}{}", " ".repeat(left), " ".repeat(right))
        }
        Alignment::Left | Alignment::None => format!("{value}{}", " ".repeat(padding)),
    }
}

#[cfg(test)]
mod tests {
    use super::{markdown_lines, markdown_lines_with_cwd, ripple, wrap, Tone};
    use ratatui::style::Modifier;
    use std::path::Path;

    fn rendered_text(markdown: &str) -> String {
        markdown_lines(markdown, 96)
            .into_iter()
            .map(|line| line.text)
            .collect::<Vec<_>>()
            .join("\n")
    }

    fn rendered_text_for_cwd(markdown: &str, cwd: &Path) -> String {
        markdown_lines_with_cwd(markdown, 96, Some(cwd))
            .into_iter()
            .map(|line| line.text)
            .collect::<Vec<_>>()
            .join("\n")
    }

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

    #[test]
    fn ripple_advances_loading_animation() {
        assert_ne!(ripple(0, 8), ripple(1, 8));
        assert_ne!(ripple(1, 8), ripple(2, 8));
    }

    #[test]
    fn markdown_renders_mermaid_with_dependency() {
        let output = rendered_text(
            r#"
```mermaid
graph LR; A[Start] --> B[Done]
```
"#,
        );

        assert!(output.contains("╭─ mermaid diagram"));
        assert!(output.contains("Start"));
        assert!(output.contains("Done"));
        assert!(!output.contains("A[Start] --> B[Done]"));
        assert!(!output.contains("Mermaid render error"));
    }

    #[test]
    fn markdown_renders_sequence_diagram_with_dependency() {
        let output = rendered_text(
            r#"
```mermaid
sequenceDiagram
    Alice->>Bob: Ping
```
"#,
        );

        assert!(output.contains("Alice"));
        assert!(output.contains("Bob"));
        assert!(output.contains("Ping"));
        assert!(!output.contains("Alice->>Bob"));
        assert!(!output.contains("Mermaid render error"));
    }

    #[test]
    fn markdown_truncates_tall_mermaid_diagrams() {
        let mut source = String::from("flowchart TD\n");

        for index in 0..48 {
            source.push_str(&format!(
                "    A{index}[Step {index}] --> A{}[Step {}]\n",
                index + 1,
                index + 1
            ));
        }

        let output = super::render_mermaid_diagram(&source, 80);
        let text = output
            .iter()
            .map(|line| line.text.as_str())
            .collect::<Vec<_>>()
            .join("\n");

        assert!(output.len() <= super::MAX_RENDERED_MERMAID_LINES + 3);
        assert!(text.contains("diagram truncated"), "{text}");
    }

    #[test]
    fn markdown_renders_tables() {
        let output = rendered_text(
            r#"
| Name | State |
| --- | --- |
| Holt | ready |
"#,
        );

        assert!(output.contains("┌"));
        assert!(output.contains("Name"), "{output}");
        assert!(output.contains("Holt"));
        assert!(output.contains("ready"));
    }

    #[test]
    fn markdown_wraps_table_cell_content() {
        let lines = markdown_lines(
            r#"
| Name | Detail |
| --- | --- |
| Holt | wraps long table cells cleanly |
"#,
            34,
        );
        let text = lines
            .iter()
            .map(|line| line.text.as_str())
            .collect::<Vec<_>>();

        assert!(text.iter().any(|line| *line == "│ Holt │ wraps long  │"));
        assert!(text.iter().any(|line| *line == "│      │ table cells │"));
        assert!(text.iter().any(|line| *line == "│      │ cleanly     │"));
    }

    #[test]
    fn markdown_renders_task_lists() {
        let output = rendered_text("- [x] Done\n- [ ] Waiting");

        assert!(output.contains("☑ Done"));
        assert!(output.contains("☐ Waiting"));
    }

    #[test]
    fn markdown_wraps_list_items_with_continuation_indent() {
        let lines = markdown_lines("- one two three four five six seven", 30);
        let text = lines
            .iter()
            .map(|line| line.text.as_str())
            .collect::<Vec<_>>();

        assert_eq!(text[0], "• one two three four five");
        assert_eq!(text[1], "  six seven");
        assert!(!text[1].starts_with("• "));
    }

    #[test]
    fn markdown_renders_blockquoted_lists_with_quote_prefix() {
        let lines = markdown_lines("> - one two three four five six", 28);
        let text = lines
            .iter()
            .map(|line| line.text.as_str())
            .collect::<Vec<_>>();

        assert_eq!(text[0], "› • one two three four");
        assert_eq!(text[1], "›   five six");
        assert!(lines.iter().all(|line| line.tone == Tone::Dim));
    }

    #[test]
    fn markdown_preserves_strikethrough_semantics() {
        let lines = markdown_lines("Keep ~~removed~~ text", 96);

        assert_eq!(lines[0].text, "Keep removed text");
        assert!(lines[0].spans.iter().any(|span| {
            span.text == "removed" && span.modifier.contains(Modifier::CROSSED_OUT)
        }));
    }

    #[test]
    fn markdown_preserves_emphasis_semantics() {
        let lines = markdown_lines("Use **bold** and _italic_ text", 96);

        assert_eq!(lines[0].text, "Use bold and italic text");
        assert!(lines[0]
            .spans
            .iter()
            .any(|span| span.text == "bold" && span.modifier.contains(Modifier::BOLD)));
        assert!(lines[0]
            .spans
            .iter()
            .any(|span| span.text == "italic" && span.modifier.contains(Modifier::ITALIC)));
    }

    #[test]
    fn markdown_styles_inline_code_without_literal_backticks() {
        let lines = markdown_lines("Run `cargo test` now", 96);

        assert_eq!(lines[0].text, "Run cargo test now");
        assert!(lines[0]
            .spans
            .iter()
            .any(|span| span.text == "cargo test" && span.tone == Tone::Code));
    }

    #[test]
    fn markdown_avoids_duplicate_link_destinations() {
        let output = rendered_text(
            "[https://example.com](https://example.com) and [docs](https://example.com/docs)",
        );

        assert!(output.contains("https://example.com and docs (https://example.com/docs)"));
        assert!(!output.contains("https://example.com (https://example.com)"));
    }

    #[test]
    fn markdown_renders_local_file_links_from_targets() {
        let output = rendered_text(
            "See [renderer](file:///Users/example/HoltWorks/rust/crates/holt-cli/src/ui.rs#L74C3).",
        );

        assert!(
            output.contains("See /Users/example/HoltWorks/rust/crates/holt-cli/src/ui.rs:74:3."),
            "{output}"
        );
        assert!(!output.contains("renderer"), "{output}");
        assert!(!output.contains("file://"), "{output}");
    }

    #[test]
    fn markdown_renders_relative_file_links_without_url_suffix() {
        let output = rendered_text("Open [the file](./rust/crates/holt-cli/src/ui.rs:12).");

        assert!(
            output.contains("Open ./rust/crates/holt-cli/src/ui.rs:12."),
            "{output}"
        );
        assert!(
            !output.contains("(./rust/crates/holt-cli/src/ui.rs:12)"),
            "{output}"
        );
    }

    #[test]
    fn markdown_shortens_absolute_file_links_under_cwd() {
        let output = rendered_text_for_cwd(
            "See [renderer](/Users/example/HoltWorks/rust/crates/holt-cli/src/ui.rs:74).",
            Path::new("/Users/example/HoltWorks"),
        );

        assert!(
            output.contains("See rust/crates/holt-cli/src/ui.rs:74."),
            "{output}"
        );
        assert!(!output.contains("/Users/example/HoltWorks"), "{output}");
    }

    #[test]
    fn markdown_keeps_local_file_link_colon_descriptions_tight() {
        let lines = markdown_lines_with_cwd(
            "- [binary](/Users/example/HoltWorks/README.md:93)\n  : core is the runtime.",
            96,
            Some(Path::new("/Users/example/HoltWorks")),
        );
        let text = lines
            .iter()
            .map(|line| line.text.as_str())
            .collect::<Vec<_>>();

        assert_eq!(text[0], "• README.md:93: core is the runtime.");
        assert!(!text[0].contains("README.md:93 :"));
    }

    #[test]
    fn markdown_renders_footnote_definitions() {
        let lines = markdown_lines("Claim[^1]\n\n[^1]: Source note with details", 32);
        let text = lines
            .iter()
            .map(|line| line.text.as_str())
            .collect::<Vec<_>>();

        assert_eq!(text[0], "Claim[^1]");
        assert_eq!(text[1], "[^1]: Source note with");
        assert_eq!(text[2], "      details");
    }

    #[test]
    fn markdown_extracts_language_from_fence_metadata() {
        let output = rendered_text(
            r#"```rust,no_run title=demo
fn main() {}
```"#,
        );

        assert!(output.contains("╭─ rust"), "{output}");
        assert!(!output.contains("╭─ rust,no_run"), "{output}");
    }

    #[test]
    fn markdown_preserves_nested_fence_examples() {
        let lines = markdown_lines(
            r#"```markdown
```rust
fn nested() {}
```
```"#,
            96,
        );
        let text = lines
            .iter()
            .map(|line| line.text.as_str())
            .collect::<Vec<_>>();

        assert_eq!(text[0], "╭─ markdown");
        assert!(text.contains(&"│ ```rust"));
        assert!(text.contains(&"│ fn nested() {}"));
        assert!(text.contains(&"│ ```"));
        assert_eq!(text.last(), Some(&"╰─"));
    }

    #[test]
    fn markdown_wraps_code_blocks_without_losing_content() {
        let lines = markdown_lines(
            r#"```rust
let value = alpha_beta_gamma_delta_epsilon;
```"#,
            28,
        );
        let text = lines
            .iter()
            .map(|line| line.text.as_str())
            .collect::<Vec<_>>();

        assert_eq!(text[0], "╭─ rust");
        assert!(text
            .iter()
            .any(|line| *line == "│ let value = alpha_beta_g"));
        assert!(text.iter().any(|line| *line == "│ amma_delta_epsilon;"));
        assert!(!text.iter().any(|line| line.contains('…')), "{text:#?}");
    }

    #[test]
    fn markdown_renders_diff_fences_with_change_tones_and_line_numbers() {
        let lines = markdown_lines(
            r#"```diff
diff --git a/src/lib.rs b/src/lib.rs
@@ -10,2 +10,2 @@
-old value
+new value
 context
```"#,
            96,
        );

        assert!(lines
            .iter()
            .any(|line| line.text == "╭─ diff" && line.tone == Tone::Border));
        assert!(lines
            .iter()
            .any(|line| line.text.contains("@@ -10,2 +10,2 @@") && line.tone == Tone::DiffHunk));
        assert!(
            lines
                .iter()
                .any(|line| line.text.contains("10      - old value")
                    && line.tone == Tone::DiffDelete)
        );
        assert!(lines
            .iter()
            .any(|line| line.text.contains("     10 + new value") && line.tone == Tone::DiffAdd));
        assert!(lines
            .iter()
            .any(|line| line.text.contains("11   11   context") && line.tone == Tone::Code));
    }

    #[test]
    fn markdown_syntax_highlights_diff_hunk_content_from_file_path() {
        let lines = markdown_lines(
            r#"```diff
diff --git a/src/lib.rs b/src/lib.rs
--- a/src/lib.rs
+++ b/src/lib.rs
@@ -1,1 +1,1 @@
-fn old_name() { println!("old"); }
+fn new_name() { println!("new"); }
```"#,
            120,
        );

        let added = lines
            .iter()
            .find(|line| line.text.contains("fn new_name"))
            .expect("added Rust line");

        assert_eq!(added.tone, Tone::DiffAdd);
        assert!(!added.spans.is_empty());
        assert!(added.spans.iter().any(|span| span.foreground.is_some()));
    }

    #[test]
    fn markdown_renders_diff_file_overview_before_hunks() {
        let lines = markdown_lines(
            r#"```diff
diff --git a/src/lib.rs b/src/lib.rs
@@ -1,1 +1,1 @@
-old
+new
diff --git a/src/new.rs b/src/new.rs
new file mode 100644
--- /dev/null
+++ b/src/new.rs
@@ -0,0 +1,1 @@
+created
diff --git a/src/old.rs b/src/old.rs
deleted file mode 100644
--- a/src/old.rs
+++ /dev/null
@@ -1,1 +0,0 @@
-removed
diff --git a/src/name.rs b/src/renamed.rs
similarity index 100%
rename from src/name.rs
rename to src/renamed.rs
```"#,
            100,
        );
        let text = lines
            .iter()
            .map(|line| line.text.as_str())
            .collect::<Vec<_>>();
        let debug = lines
            .iter()
            .map(|line| format!("{:?}: {}", line.tone, line.text))
            .collect::<Vec<_>>();

        assert!(
            text.iter()
                .position(|line| *line == "│   4 files changed (+2 -2)")
                .expect("overview")
                < text
                    .iter()
                    .position(|line| line.contains("@@ -1,1 +1,1 @@"))
                    .expect("first hunk")
        );
        assert!(
            lines.iter().any(
                |line| line.text == "│   edited src/lib.rs (+1 -1)" && line.tone == Tone::Code
            ),
            "{debug:#?}"
        );
        assert!(
            lines
                .iter()
                .any(|line| line.text == "│   added src/new.rs (+1 -0)"
                    && line.tone == Tone::DiffAdd),
            "{debug:#?}"
        );
        assert!(
            lines
                .iter()
                .any(|line| line.text == "│   deleted src/old.rs (+0 -1)"
                    && line.tone == Tone::DiffDelete),
            "{debug:#?}"
        );
        assert!(
            lines.iter().any(|line| line.text
                == "│   renamed src/name.rs -> src/renamed.rs (+0 -0)"
                && line.tone == Tone::DiffHunk),
            "{debug:#?}"
        );
    }

    #[test]
    fn markdown_preserves_diff_line_indentation() {
        let lines = markdown_lines(
            r#"```diff
@@ -1,1 +1,1 @@
-    let old_value = call();
+    let new_value = call();
```"#,
            80,
        );
        let text = lines
            .iter()
            .map(|line| line.text.as_str())
            .collect::<Vec<_>>();

        assert!(text
            .iter()
            .any(|line| *line == "│    1      -     let old_value = call();"));
        assert!(text
            .iter()
            .any(|line| *line == "│         1 +     let new_value = call();"));
    }

    #[test]
    fn markdown_wraps_long_diff_lines_under_gutter() {
        let lines = markdown_lines(
            r#"```diff
@@ -1,1 +1,1 @@
-old value with several words here
+new value with several words here
```"#,
            36,
        );
        let text = lines
            .iter()
            .map(|line| line.text.as_str())
            .collect::<Vec<_>>();

        assert!(text
            .iter()
            .any(|line| *line == "│    1      - old value with"));
        assert!(text
            .iter()
            .any(|line| *line == "│             several words here"));
        assert!(text
            .iter()
            .any(|line| *line == "│         1 + new value with"));
        assert!(text
            .iter()
            .any(|line| *line == "│             several words here"));
        assert!(lines
            .iter()
            .any(|line| line.tone == Tone::DiffDelete
                && line.text == "│             several words here"));
        assert!(lines
            .iter()
            .any(|line| line.tone == Tone::DiffAdd
                && line.text == "│             several words here"));
    }

    #[test]
    fn markdown_expands_diff_gutter_for_large_line_numbers() {
        let lines = markdown_lines(
            r#"```diff
@@ -10000,1 +10000,1 @@
-old value with several words here
+new value with several words here
```"#,
            36,
        );
        let text = lines
            .iter()
            .map(|line| line.text.clone())
            .collect::<Vec<_>>();
        let delete_first = format!("│ {:>5} {:>5} - old value with", 10000, "");
        let add_first = format!("│ {:>5} {:>5} + new value with", "", 10000);
        let continuation_content = "several words here";

        assert!(text.iter().any(|line| line == &delete_first), "{text:#?}");
        assert!(text.iter().any(|line| line == &add_first), "{text:#?}");
        let delete_prefix_width = delete_first
            .strip_suffix("old value with")
            .unwrap()
            .chars()
            .count();
        let add_prefix_width = add_first
            .strip_suffix("new value with")
            .unwrap()
            .chars()
            .count();
        let delete_continuation = lines
            .iter()
            .find(|line| line.tone == Tone::DiffDelete && line.text.ends_with(continuation_content))
            .unwrap_or_else(|| panic!("{text:#?}"));
        let add_continuation = lines
            .iter()
            .find(|line| line.tone == Tone::DiffAdd && line.text.ends_with(continuation_content))
            .unwrap_or_else(|| panic!("{text:#?}"));

        assert_eq!(
            delete_continuation
                .text
                .strip_suffix(continuation_content)
                .unwrap()
                .chars()
                .count(),
            delete_prefix_width
        );
        assert_eq!(
            add_continuation
                .text
                .strip_suffix(continuation_content)
                .unwrap()
                .chars()
                .count(),
            add_prefix_width
        );
    }

    #[test]
    fn markdown_wraps_long_diff_metadata_lines() {
        let lines = markdown_lines(
            r#"```diff
diff --git a/rust/crates/holt-cli/src/very_long_file_name.rs b/rust/crates/holt-cli/src/very_long_file_name.rs
index 1234567..abcdef0 100644
--- a/rust/crates/holt-cli/src/very_long_file_name.rs
+++ b/rust/crates/holt-cli/src/very_long_file_name.rs
@@ -1,1 +1,1 @@ fn very_long_context_name_for_wrapping()
```"#,
            42,
        );
        let text = lines
            .iter()
            .map(|line| line.text.as_str())
            .collect::<Vec<_>>();

        assert!(text.iter().any(|line| *line == "│     diff --git"));
        assert!(text
            .iter()
            .any(|line| line.starts_with("│     a/rust/crates/holt-cli/src/very")));
        assert!(text
            .iter()
            .any(|line| line.starts_with("│     b/rust/crates/holt-cli/src/very")));
        assert!(text.iter().any(|line| *line == "│     ng_file_name.rs"));
        assert!(text.iter().any(|line| *line == "│     @@ -1,1 +1,1 @@ fn"));
        assert!(text
            .iter()
            .any(|line| *line == "│     very_long_context_name_for_wrappin"));
        assert!(text.iter().any(|line| *line == "│     g()"));
        assert!(lines
            .iter()
            .any(|line| line.tone == Tone::DiffDelete && line.text == "│     ---"));
        assert!(lines
            .iter()
            .any(|line| line.tone == Tone::DiffAdd && line.text == "│     +++"));
    }

    #[test]
    fn markdown_syntax_highlights_regular_code_fences() {
        let lines = markdown_lines(
            r#"
```rust
fn main() {
    let name = "Holt";
    // explain the example
}
```
"#,
            100,
        );

        let fn_line = lines
            .iter()
            .find(|line| line.text.contains("fn main"))
            .expect("expected highlighted fn line");
        let keyword_span = fn_line
            .spans
            .iter()
            .find(|span| span.text == "fn")
            .expect("expected syntax span for Rust keyword");
        assert!(keyword_span.foreground.is_some());

        let string_line = lines
            .iter()
            .find(|line| line.text.contains("\"Holt\""))
            .expect("expected highlighted string line");
        let string_span = string_line
            .spans
            .iter()
            .find(|span| span.text.contains("Holt"))
            .expect("expected syntax span for Rust string");
        assert!(string_span.foreground.is_some());

        let comment_line = lines
            .iter()
            .find(|line| line.text.contains("explain the example"))
            .expect("expected highlighted comment line");
        let comment_span = comment_line
            .spans
            .iter()
            .find(|span| span.text.contains("explain the example"))
            .expect("expected syntax span for Rust comment");
        assert!(comment_span.foreground.is_some());
        assert_ne!(string_span.foreground, comment_span.foreground);
    }
}
