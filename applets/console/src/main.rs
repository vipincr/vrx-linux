use console::Console;
use vrx::applet_main;

fn main() -> std::process::ExitCode {
    applet_main(Console::new())
}
