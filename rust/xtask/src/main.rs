// The gate (octiva discipline, plan 0007 part K).
//
// `cargo xtask gate` runs, in order, all blocking:
//   1. cargo fmt --check
//   2. cargo clippy --workspace --all-targets -- -D warnings
//   3. cargo test --workspace
//   4. the crates manifest, the responsiveness scan, the image's fonts
//   5. per Flutter package: pub get, analyze, test (layout checks too)
//   6. cargo deny check bans licenses sources
// A change is not done until the gate is green. The gate is a build
// tool: it reports to stdout and spawns cargo; the applet print and
// spawn lints do not apply here.

#![allow(clippy::print_stdout, clippy::print_stderr)]

mod crates_inc;
mod fonts;

use std::process::{Command, ExitCode, Stdio};

fn main() -> ExitCode {
    let mut args = std::env::args().skip(1);
    let task = args.next().unwrap_or_default();
    let args: Vec<String> = args.collect();
    match task.as_str() {
        "gate" => gate(),
        "crates-inc" => crates_inc::run(&args),
        "fonts" => match fonts::ensure() {
            Ok(()) => {
                println!("fonts: in {}", fonts::dir().display());
                ExitCode::SUCCESS
            }
            Err(err) => {
                eprintln!("fonts: {err}");
                ExitCode::FAILURE
            }
        },
        _ => {
            eprintln!("usage: cargo xtask gate | crates-inc | fonts");
            ExitCode::from(64)
        }
    }
}

/// The Rust applets under applets/ (standalone crates, outside the
/// workspace): fmt, clippy -D warnings and their tests, which include the
/// layout check every applet carries (tests/layout.rs, AGENTS.md rule 11),
/// the same steps `vrx build` runs before it compiles one.
fn rust_applets_gate(repo: &std::path::Path) -> bool {
    let Ok(entries) = std::fs::read_dir(repo.join("applets")) else {
        return true;
    };
    let mut crates: Vec<_> = entries
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.join("Cargo.toml").is_file())
        .collect();
    crates.sort();
    for dir in crates {
        let shown = dir.strip_prefix(repo).unwrap_or(&dir).display().to_string();
        if !dir.join("tests").join("layout.rs").is_file() {
            eprintln!(
                "gate: FAILED — {shown} has no tests/layout.rs (AGENTS.md rule 11)"
            );
            return false;
        }
        let steps: [&[&str]; 3] = [
            &["fmt", "--check"],
            &["clippy", "--all-targets", "--", "-D", "warnings"],
            &["test"],
        ];
        for args in steps {
            println!("gate: cargo {} ({shown})", args.join(" "));
            let ok = Command::new("cargo")
                .args(args)
                .current_dir(&dir)
                .status()
                .map(|s| s.success())
                .unwrap_or(false);
            if !ok {
                eprintln!("gate: FAILED at cargo {} in {shown}", args.join(" "));
                return false;
            }
        }
    }
    true
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
    // the trees whose code runs inside applets: the Flutter SDK, the Rust
    // SDK and every applet
    let mut roots = vec![repo.join("flutter/vrx_kit/lib"), repo.join("rust/sdk/src")];
    if let Ok(entries) = std::fs::read_dir(repo.join("applets")) {
        for entry in entries.flatten() {
            roots.extend(vrx_protocol::scan::applet_roots(&entry.path()));
        }
    }
    let found = vrx_protocol::scan::scan(&roots);
    for v in &found {
        let shown = v.path.strip_prefix(&repo).unwrap_or(&v.path).display();
        eprintln!(
            "{shown}:{}: `{}`: {} (or mark the line `vrx-allow: <reason>`)",
            v.line, v.needle, v.why
        );
    }
    if !found.is_empty() {
        eprintln!("gate: FAILED at the responsiveness scan");
        return ExitCode::FAILURE;
    }
    // the layout tests measure text in the image's fonts (vrx_check)
    println!("gate: the image's fonts for the layout check");
    if let Err(err) = fonts::ensure() {
        eprintln!("gate: FAILED fetching the fonts: {err}");
        return ExitCode::FAILURE;
    }
    if !flutter_gate(&repo) {
        return ExitCode::FAILURE;
    }
    if !rust_applets_gate(&repo) {
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
