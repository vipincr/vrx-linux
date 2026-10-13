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
mod scan;

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

/// flutter analyze (the vrx lint set, errors fail) and flutter test, in
/// every package with a pubspec: the SDK and tools under flutter/, then
/// the applets. Refuses to pass silently without a flutter binary.
fn flutter_gate(repo: &std::path::Path) -> bool {
    let mut dirs = Vec::new();
    for root in ["flutter", "applets"] {
        if let Ok(entries) = std::fs::read_dir(repo.join(root)) {
            let mut found: Vec<_> = entries
                .flatten()
                .map(|e| e.path())
                .filter(|p| p.join("pubspec.yaml").is_file())
                .collect();
            found.sort();
            dirs.extend(found);
        }
    }
    for dir in dirs {
        // the lockfile must already resolve the package (the Yocto build
        // resolves offline with --enforce-lockfile): a stale lockfile fails
        // here, not in the image build
        let shown = dir.strip_prefix(repo).unwrap_or(&dir).display().to_string();
        println!("gate: flutter pub get --enforce-lockfile ({shown})");
        let resolved = Command::new("flutter")
            .args(["pub", "get", "--enforce-lockfile"])
            .current_dir(&dir)
            .status()
            .map(|s| s.success())
            .unwrap_or(false);
        if !resolved {
            eprintln!("gate: FAILED: {shown}/pubspec.lock does not resolve its pubspec (run flutter pub get there)");
            return false;
        }
        for args in [["analyze", "--no-pub"], ["test", "--no-pub"]] {
            let shown = dir.strip_prefix(repo).unwrap_or(&dir).display().to_string();
            println!("gate: flutter {} ({shown})", args[0]);
            let status = Command::new("flutter")
                .args(args)
                .current_dir(&dir)
                .status();
            match status {
                Ok(s) if s.success() => {}
                Ok(_) => {
                    eprintln!("gate: FAILED at flutter {} in {shown}", args[0]);
                    return false;
                }
                Err(_) => {
                    eprintln!("gate: FAILED: flutter is not installed (the Flutter half of the gate cannot be skipped)");
                    return false;
                }
            }
        }
    }
    true
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

    // the responsiveness scan and the Flutter half (plan 0008 D19)
    let repo = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    println!("gate: responsiveness scan (applet and SDK sources)");
    if !scan::run(&repo) {
        eprintln!("gate: FAILED at the responsiveness scan");
        return ExitCode::FAILURE;
    }
    if !flutter_gate(&repo) {
        return ExitCode::FAILURE;
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
