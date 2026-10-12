//! terminal: a vrx Rust applet. The screen is a bounded ring of lines;
//! every input line is an action that appends and scrolls. Run:
//!
//!   cargo run -p terminal --bin terminal
//!   echo '"hello"' | cargo run -p terminal --bin terminal
//!
//! The same binary is a console applet (vrxhost supervises it) and a
//! shell pipeline stage (manifest command.enabled) — the applet-as-ELF
//! promise, proven on any host.

use serde::{Deserialize, Serialize};
use vrx::{applet_main, prelude::*};

/// The ring depth: the terminal keeps the last N lines.
const RING: usize = 24;

struct Terminal {
    lines: Vec<String>,
}

#[derive(Serialize, Deserialize)]
enum Action {
    Init,
    Line(String),
    Clear,
}

struct View {
    lines: Vec<String>,
}

impl Applet for Terminal {
    type State = Vec<String>;
    type Action = Action;
    type View = View;

    fn initial() -> Vec<String> {
        Vec::new()
    }

    fn boot_action() -> Action {
        Action::Init
    }

    fn reduce(&mut self, _state: &Vec<String>, action: &Action) -> View {
        match action {
            Action::Init => self.lines.clear(),
            Action::Line(line) => {
                self.lines.push(line.clone());
                let overflow = self.lines.len().saturating_sub(RING);
                if overflow > 0 {
                    self.lines.drain(0..overflow);
                }
            }
            Action::Clear => self.lines.clear(),
        }
        View {
            lines: self.lines.clone(),
        }
    }

    fn snapshot(&self) -> Vec<String> {
        self.lines.clone()
    }

    fn render(view: &View) -> String {
        let mut rows = vec![text_title("terminal"), text_row(
            "lines",
            format!("{}/{}", view.lines.len(), RING),
        )];
        rows.push(vrx::kit::Row::Blank);
        for line in &view.lines {
            rows.push(text_body(line.clone()));
        }
        if view.lines.is_empty() {
            rows.push(text_body("(no input — pipe lines as JSON strings)"));
        }
        screen(rows).render()
    }
}

fn main() -> std::process::ExitCode {
    applet_main(Terminal { lines: Vec::new() })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lines_append_and_the_ring_bounds_the_screen() {
        let mut harness = vrx::store::StoreHarness::new(Terminal { lines: Vec::new() });
        for i in 0..(RING + 5) {
            harness.dispatch(Action::Line(format!("line {i}")));
        }
        let view = harness.view();
        assert_eq!(view.lines.len(), RING);
        assert_eq!(view.lines.first().map(String::as_str), Some("line 5"));
        assert_eq!(
            view.lines.last().map(String::as_str),
            Some(format!("line {}", RING + 4).as_str())
        );
    }

    #[test]
    fn clear_empties_the_screen() {
        let mut harness = vrx::store::StoreHarness::new(Terminal { lines: Vec::new() });
        harness.dispatch(Action::Line("x".into()));
        harness.dispatch(Action::Clear);
        assert!(harness.view().lines.is_empty());
    }

    #[test]
    fn the_render_names_its_depth() {
        let view = View {
            lines: vec!["hello".to_owned()],
        };
        let rendered = Terminal::render(&view);
        assert!(rendered.contains("lines: 1/24"));
        assert!(rendered.contains("hello"));
    }
}
