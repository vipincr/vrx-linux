// The console kit: how a Rust applet renders as text. A screen is a
// column of rows; each row is a title, body text, a label/value pair,
// or a button with the intent it sends. Rendered as plain lines — a
// console applet is also a pipeline stage (manifest command.enabled),
// so the output is line-oriented by design.

/// One row on a screen.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Row {
    /// The screen's own name.
    Title(String),
    /// Body text.
    Body(String),
    /// A label and its reading.
    KeyValue(String, String),
    /// A control: its label, and the intent a tap sends.
    Button(String, String),
    /// A blank line.
    Blank,
}

/// A screen: rows, top to bottom.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Screen {
    pub rows: Vec<Row>,
}

/// Build a screen from rows.
pub fn screen(rows: Vec<Row>) -> Screen {
    Screen { rows }
}

/// The screen's own name.
pub fn text_title(text: impl Into<String>) -> Row {
    Row::Title(text.into())
}

/// Body text.
pub fn text_body(text: impl Into<String>) -> Row {
    Row::Body(text.into())
}

/// A label and its reading.
pub fn text_row(label: impl Into<String>, value: impl Into<String>) -> Row {
    Row::KeyValue(label.into(), value.into())
}

/// A control: label, and the intent a tap sends.
pub fn button(label: impl Into<String>, intent: impl Into<String>) -> Row {
    Row::Button(label.into(), intent.into())
}

impl Screen {
    /// Render to plain lines. A button renders as `[label] (intent)` —
    /// readable by a person, greppable by a test, honest about the
    /// intent it fires.
    pub fn render(&self) -> String {
        let mut lines = Vec::with_capacity(self.rows.len());
        for row in &self.rows {
            lines.push(match row {
                Row::Title(text) => {
                    format!("{text}\n{}", "-".repeat(text.chars().count()))
                }
                Row::Body(text) => text.clone(),
                Row::KeyValue(label, value) => format!("{label}: {value}"),
                Row::Button(label, intent) => format!("[{label}] ({intent})"),
                Row::Blank => String::new(),
            });
        }
        lines.join("\n")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_plan_reference_screen_renders() {
        let rendered = screen(vec![
            text_title("My applet"),
            text_body("Hello from the vrx console kit"),
            button("Tap me", "myapp.tap"),
        ])
        .render();
        assert_eq!(
            rendered,
            "My applet\n---------\nHello from the vrx console kit\n[Tap me] (myapp.tap)"
        );
    }

    #[test]
    fn key_rows_read_like_readings() {
        let rendered = screen(vec![text_row("Uptime", "12h")]).render();
        assert_eq!(rendered, "Uptime: 12h");
    }
}
