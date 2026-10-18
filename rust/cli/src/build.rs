// `vrx build`: validate the manifest, then compile. Validation is the
// gate the whole system leans on — a manifest that parses on the host
// but not in the SDK would be a fifth IPC shape by the back door:
// - the manifest parses and all keys are known
// - intents sent by name in code are declared in the `emits` list (G022;
//   vrxhost also refuses an undeclared one at the socket)
// - nothing in the applet's source blocks its event loop or a frame
//   (the responsiveness scan, the same code as the repo's gate)
// - the runtime's own gates pass: Rust fmt, clippy -D warnings and tests;
//   Flutter analyze and tests
// - its layout holds on every display vrx drives: a required layout test
//   (test/layout_test.dart through vrx_check, or tests/layout.rs through
//   vrx::layout) runs with the tests, so text that overlaps, is cut, or
//   breaks inside a word fails the build (AGENTS.md rule 11)

use std::path::PathBuf;
use std::process::ExitCode;

use vrx_protocol::Manifest;

pub fn run(args: &[String]) -> ExitCode {
    let dir = args
        .iter()
        .position(|a| a == "--in")
        .and_then(|i| args.get(i + 1))
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."))
        });
    let manifest_path = dir.join("manifest.toml");
    let Ok(text) = std::fs::read_to_string(&manifest_path) else {
        eprintln!("vrx build: no manifest.toml in {}", dir.display());
        return ExitCode::from(66);
    };
    let manifest: Manifest = match text.parse() {
        Ok(manifest) => manifest,
        Err(err) => {
            eprintln!("vrx build: manifest invalid: {err}");
            return ExitCode::from(65);
        }
    };
    println!(
        "manifest ok: {} v{} ({})",
        manifest.applet.id,
        manifest.applet.version,
        if manifest.applet.runtime == vrx_protocol::manifest::Runtime::Rust {
            "rust"
        } else {
            "flutter/native"
        }
    );

    let manifest_dir = dir;

    // the responsiveness scan: nothing that blocks the event loop or a
    // frame (plan 0008 D19); one implementation with the repo's gate
    let found =
        vrx_protocol::scan::scan(&vrx_protocol::scan::applet_roots(&manifest_dir));
    for v in &found {
        let shown = v
            .path
            .strip_prefix(&manifest_dir)
            .unwrap_or(&v.path)
            .display();
        eprintln!(
            "{shown}:{}: `{}`: {}{}",
            v.line,
            v.needle,
            v.why,
            v.remedy()
        );
    }
    if !found.is_empty() {
        eprintln!("vrx build: the responsiveness scan failed");
        return ExitCode::from(65);
    }
    println!("scan ok");

    // G022: every intent the code sends by name is in emits (pushes are
    // checked against the whole registry by the repo's gate)
    let undeclared = vrx_protocol::scan::sent_violations(&manifest_dir, &manifest, None);
    for f in &undeclared {
        eprintln!("{f}");
    }
    if !undeclared.is_empty() {
        eprintln!("vrx build: an intent is sent that the manifest does not emit");
        return ExitCode::from(65);
    }

    // the runtime's gates, then the compile; each step must pass. The
    // layout test is required: every screen on every display vrx drives
    // (AGENTS.md rule 11)
    let flutter = manifest.applet.runtime == vrx_protocol::manifest::Runtime::Flutter;
    // a service has no screen, so nothing to lay out (the repo gate reads
    // the same kind; review 2026-10-17, KRN-07)
    let service = manifest.applet.kind == vrx_protocol::manifest::Kind::Service;
    let layout = if flutter {
        manifest_dir.join("test").join("layout_test.dart")
    } else {
        manifest_dir.join("tests").join("layout.rs")
    };
    if !service && !layout.is_file() {
        eprintln!(
            "vrx build: {} has no {}: every screen must be checked on every display \
             (AGENTS.md rule 11)",
            manifest.applet.id,
            layout
                .strip_prefix(&manifest_dir)
                .unwrap_or(&layout)
                .display()
        );
        return ExitCode::from(65);
    }
    let steps: &[(&str, &[&str])] = if flutter {
        &[
            ("flutter", &["analyze", "--fatal-infos"]),
            ("flutter", &["test"]),
            // the Dart kernel and assets: every compile error, on any host;
            // the device's AOT build (libapp.so) is the image recipe's
            ("flutter", &["build", "bundle"]),
        ]
    } else {
        &[
            ("cargo", &["fmt", "--check"]),
            (
                "cargo",
                &["clippy", "--all-targets", "--", "-D", "warnings"],
            ),
            ("cargo", &["test"]),
            ("cargo", &["build", "--release"]),
        ]
    };
    for (program, args) in steps {
        println!("{program} {}", args.join(" "));
        let status = delegate(program, args, &manifest_dir);
        if status != ExitCode::SUCCESS {
            return status;
        }
    }
    ExitCode::SUCCESS
}

#[allow(clippy::print_stderr)]
fn delegate(program: &str, args: &[&str], dir: &std::path::Path) -> ExitCode {
    let status = std::process::Command::new(program)
        .args(args)
        .current_dir(dir)
        .status();
    match status {
        Ok(status) if status.success() => ExitCode::SUCCESS,
        Ok(status) => {
            eprintln!("vrx build: {program} {} failed: {status}", args.join(" "));
            ExitCode::FAILURE
        }
        Err(err) => {
            eprintln!("vrx build: cannot run {program}: {err}");
            ExitCode::from(127)
        }
    }
}
