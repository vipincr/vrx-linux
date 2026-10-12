// `vrx test`: run the applet's store tests on the host — no board, no
// engine. The same model the applet runs, driven by the harness.

use std::process::ExitCode;

pub fn run(_args: &[String]) -> ExitCode {
    // pubspec.yaml marks a Flutter applet, Cargo.toml a Rust one
    if std::path::Path::new("pubspec.yaml").exists() {
        delegate("flutter", &["test"])
    } else if std::path::Path::new("Cargo.toml").exists() {
        delegate("cargo", &["test"])
    } else {
        eprintln!("vrx test: not an applet directory (no pubspec.yaml or Cargo.toml)");
        ExitCode::from(66)
    }
}

#[allow(clippy::print_stderr)]
fn delegate(program: &str, args: &[&str]) -> ExitCode {
    match std::process::Command::new(program).args(args).status() {
        Ok(status) if status.success() => ExitCode::SUCCESS,
        Ok(status) => {
            eprintln!("vrx test: {program} {} failed: {status}", args.join(" "));
            ExitCode::FAILURE
        }
        Err(err) => {
            eprintln!("vrx test: cannot run {program}: {err}");
            ExitCode::from(127)
        }
    }
}
