use console::{Action, Console};
use vrx::prelude::*;

/// The console's screens on every display vrx drives: empty, and full of
/// lines as long as a log line gets (AGENTS.md rule 11).
#[test]
fn every_screen_fits_every_display() {
    let mut harness = StoreHarness::new(Console::new());
    assert_clean_layout(&Console::screen_of(harness.view()));
    for i in 0..30 {
        harness.dispatch(Action::Line(format!("line {i}: the board said something")));
    }
    assert_clean_layout(&Console::screen_of(harness.view()));
}
