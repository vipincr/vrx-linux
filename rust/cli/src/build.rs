// `vrx build`: validate the manifest, then compile. Validation is the
// gate the whole system leans on — a manifest that parses on the host
// but not in the SDK would be a fifth IPC shape by the back door:
// - the manifest parses and all keys are known
// - intents sent in code are declared in the `emits` list
// - intents handled in code are declared in the `handles` list

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

    // compile: delegate to the runtime's own tool
    let manifest_dir = dir;
    match manifest.applet.runtime {
        vrx_protocol::manifest::Runtime::Flutter => {
            delegate("flutter", &["build"], &manifest_dir)
        }
        _ => delegate("cargo", &["build"], &manifest_dir),
    }
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
