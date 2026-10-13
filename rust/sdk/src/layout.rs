// The console kit's layout check, computed: no rendering, only the
// panel's millimetres and the monospace font's advance. A console screen
// is lines of text; where a person sees one on a panel it is a text grid
// in Liberation Mono at vrx_kit's body size (3.5 mm, 9.9 pt), scaled the
// way vrx_kit scales (the short side over 480 logical px, 1x to 3x),
// inside the 2 mm screen insets. The check: no title, row or button
// wider than the grid's columns (cut), and no word of body text longer
// than a line (it would break inside the word). The displays are
// vrx_check's table, the one both SDKs read.

use serde::Deserialize;

use crate::kit::{Row, Screen};

/// A display a vrx board drives.
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct Display {
    pub name: String,
    /// Pixels.
    pub width: f64,
    pub height: f64,
    /// The panel's width in mm; 0 when its EDID gives none (the runtime
    /// then keeps the pixel ratio at 1.0).
    pub width_mm: f64,
    pub touch: bool,
}

#[derive(Deserialize)]
struct Table {
    displays: Vec<Display>,
}

/// Every display vrx drives (flutter/vrx_check/lib/displays.json).
pub fn displays() -> Vec<Display> {
    let text = include_str!("../../../flutter/vrx_check/lib/displays.json");
    serde_json::from_str::<Table>(text)
        .map(|t| t.displays)
        .unwrap_or_default()
}

/// vrx_kit's density: logical px per mm.
const DP_PER_MM: f64 = 160.0 / 25.4;
/// Body text, 9.9 pt, in mm.
const BODY_MM: f64 = 9.9 * 25.4 / 72.0;
/// Liberation Mono's advance: 1229 of 2048 units per em.
const MONO_ADVANCE: f64 = 1229.0 / 2048.0;
const INSET_MM: f64 = 2.0;

impl Display {
    /// mm per pixel: the panel's, else the runtime's 1.0 ratio.
    fn mm_per_px(&self) -> f64 {
        if self.width_mm > 0.0 {
            self.width_mm / self.width
        } else {
            1.0 / DP_PER_MM
        }
    }

    /// vrx_kit's scale: the short side in logical px over 480, 1x to 3x.
    fn scale(&self) -> f64 {
        let logical = |px: f64| px * self.mm_per_px() * DP_PER_MM;
        (logical(self.width).min(logical(self.height)) / 480.0).clamp(1.0, 3.0)
    }

    /// Characters per line of a console screen on this display.
    pub fn columns(&self) -> usize {
        let usable = self.width * self.mm_per_px() - 2.0 * INSET_MM * self.scale();
        let advance = BODY_MM * self.scale() * MONO_ADVANCE;
        (usable / advance).floor().max(1.0) as usize
    }
}

/// One broken rule.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LayoutIssue {
    pub rule: &'static str,
    pub what: String,
    pub display: String,
}

impl std::fmt::Display for LayoutIssue {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{} on {}: {}", self.rule, self.display, self.what)
    }
}

/// Every rule [screen] breaks on [display].
pub fn check(screen: &Screen, display: &Display) -> Vec<LayoutIssue> {
    let cols = display.columns();
    let mut issues = Vec::new();
    let mut flag = |rule: &'static str, what: String| {
        issues.push(LayoutIssue {
            rule,
            what,
            display: display.name.clone(),
        });
    };
    for row in &screen.rows {
        // the line as the kit renders it, one line for every row but body
        let line = match row {
            Row::Title(t) => t.clone(),
            Row::KeyValue(l, v) => format!("{l}: {v}"),
            Row::Button(l, _) => format!("[{l}]"),
            Row::Body(text) => {
                for word in text.split_whitespace() {
                    if word.chars().count() > cols {
                        flag(
                            "broken",
                            format!("\"{word}\" is longer than a {cols}-column line"),
                        );
                    }
                }
                continue;
            }
            Row::Blank => continue,
        };
        let n = line.chars().count();
        if n > cols {
            flag("cut", format!("\"{line}\" is {n} columns of {cols}"));
        }
    }
    issues
}

/// Check [screen] on every display; panics with every issue, one a line
/// (for an applet's tests/layout.rs).
#[allow(clippy::panic)]
pub fn assert_clean_layout(screen: &Screen) {
    let issues: Vec<String> = displays()
        .iter()
        .flat_map(|d| check(screen, d))
        .map(|i| i.to_string())
        .collect();
    if !issues.is_empty() {
        panic!(
            "{} layout issue(s):\n  {}",
            issues.len(),
            issues.join("\n  ")
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::kit::{button, screen, text_body, text_row, text_title};

    #[test]
    fn the_table_loads_and_the_panel_holds_about_twenty_columns() {
        let all = displays();
        assert!(all.len() >= 5, "{all:?}");
        let panel = all.iter().find(|d| d.name == "disp28a").cloned().unwrap();
        // 43 mm less 4 mm of insets over a 2.1 mm advance
        assert_eq!(panel.columns(), 18);
        let monitor = all.iter().find(|d| d.name == "hdmi1080").cloned().unwrap();
        assert!(monitor.columns() > panel.columns());
    }

    #[test]
    fn long_rows_are_cut_and_long_words_broken() {
        let panel = displays()
            .into_iter()
            .find(|d| d.name == "disp28a")
            .unwrap();
        let ok = screen(vec![
            text_title("Uptime"),
            text_row("load", "0.06"),
            button("Stop", "x.stop"),
        ]);
        assert!(check(&ok, &panel).is_empty());
        let bad = screen(vec![
            text_title("A title far too long for the panel"),
            text_body("supercalifragilisticexpialidocious words"),
            button("Restart every service", "x.restart"),
        ]);
        let rules: Vec<_> = check(&bad, &panel).into_iter().map(|i| i.rule).collect();
        assert_eq!(rules, vec!["cut", "broken", "cut"]);
    }
}
