// The hello-world Rust applet (the plan's part-G verification): a
// store, the console kit, and the generated-style entry point. Run:
//
//   cargo run -p vrx --example hello
//   echo '"tap"' | cargo run -p vrx --example hello
//
// proving the SDK end to end on any host, no board.

use serde::{Deserialize, Serialize};
use vrx::{applet_main, prelude::*};

struct Hello {
    taps: i32,
}

#[derive(Serialize, Deserialize)]
enum Action {
    Tap,
}

struct View {
    taps: i32,
}

impl Applet for Hello {
    type State = i32;
    type Action = Action;
    type View = View;

    fn initial() -> i32 {
        0
    }

    fn boot_action() -> Action {
        Action::Tap
    }

    fn reduce(&mut self, state: &i32, action: &Action) -> View {
        let _ = state;
        match action {
            Action::Tap => self.taps += 1,
        }
        View { taps: self.taps }
    }

    fn effects(&mut self, _state: &i32, action: &Action) -> Vec<Effect> {
        match action {
            Action::Tap if self.taps == 2 => Effect::intent(
                "hello.world.twice",
                serde_json::json!({ "taps": self.taps }),
            )
            .into_iter()
            .collect(),
            _ => Vec::new(),
        }
    }

    fn snapshot(&self) -> i32 {
        self.taps
    }

    fn render(view: &View) -> String {
        screen(vec![
            text_title("hello"),
            text_body("the vrx Rust SDK, end to end"),
            text_row("taps", view.taps.to_string()),
            button("Tap", "hello.tap"),
        ])
        .render()
    }
}

fn main() -> std::process::ExitCode {
    applet_main(Hello { taps: 0 })
}
