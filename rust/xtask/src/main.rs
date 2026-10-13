// The gate (octiva discipline, plan 0007 part K).
//
// `cargo xtask gate` runs, in order, all blocking:
//   1. cargo fmt --check
//   2. cargo clippy --workspace --all-targets -- -D warnings
//   3. cargo test --workspace
//   4. cargo deny check bans licenses sources
// A change is not done until the gate is green. The gate is a build
// tool: it reports to stdout and spawns cargo; the applet print and
// spawn lints do not apply here.

#![allow(clippy::print_stdout, clippy::print_stderr)]

mod crates_inc;

use std::process::{Command, ExitCode, Stdio};

fn main() -> ExitCode {
    let mut args = std::env::args().skip(1);
    let task = args.next().unwrap_or_default();
    let args: Vec<String> = args.collect();
    match task.as_str() {
        "gate" => gate(),
        "crates-inc" => crates_inc::run(&args),
        _ => {
            eprintln!("usage: cargo xtask gate | crates-inc");
            ExitCode::from(64)
        }
    }
}

fn gate() -> ExitCode {
    let steps: [(&str, Vec<&str>); 3] = [
        ("cargo", vec!["fmt", "--check"]),
        (
            "cargo",
            vec![
                "clippy",
                "--workspace",
                "--all-targets",
                "--",
                "-D",
                "warnings",
            ],
        ),
        ("cargo", vec!["test", "--workspace"]),
    ];
    for (program, args) in steps {
        println!("gate: {program} {}", args.join(" "));
        let ok = Command::new(program)
            .args(&args)
            .status()
            .map(|s| s.success())
            .unwrap_or(false);
        if !ok {
            eprintln!("gate: FAILED at {program} {}", args.join(" "));
            return ExitCode::FAILURE;
        }
    }

    // the layer's crates manifest must match Cargo.lock, or the Yocto
    // build fails offline (--frozen) far from the change that caused it
    println!("gate: crates manifest matches Cargo.lock");
    match crates_inc::is_current() {
        Ok(true) => {}
        Ok(false) => {
            eprintln!("gate: FAILED — layer/recipes-core/vrx-workspace-crates.inc is stale: run `cargo xtask crates-inc`");
            return ExitCode::FAILURE;
        }
        Err(err) => {
            eprintln!("gate: FAILED reading the crates manifest: {err}");
            return ExitCode::FAILURE;
        }
    }

    // cargo-deny is a gate step when the binary is available; the gate
    // refuses to silently pass without it.
    match Command::new("cargo")
        .args(["deny", "--version"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
    {
        Ok(status) if status.success() => {
            println!("gate: cargo deny check bans licenses sources");
            let ok = Command::new("cargo")
                .args(["deny", "check", "bans", "licenses", "sources"])
                .status()
                .map(|s| s.success())
                .unwrap_or(false);
            if !ok {
                eprintln!("gate: FAILED at cargo deny");
                return ExitCode::FAILURE;
            }
        }
        _ => {
            eprintln!(
                "gate: FAILED — cargo-deny is not installed (cargo install cargo-deny)"
            );
            return ExitCode::FAILURE;
        }
    }

    println!("gate: green");
    ExitCode::SUCCESS
}
