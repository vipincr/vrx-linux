// `vrx install`: copy a built applet directory into /apps (or --root's
// apps). The manifest must validate before anything is copied: the
// registry refuses at boot anyway, and installing something unbootable
// is a failure better caught now, named.

use std::path::{Path, PathBuf};
use std::process::ExitCode;

use vrx_protocol::Manifest;

pub fn run(args: &[String]) -> ExitCode {
    let Some(src) = args.iter().find(|a| !a.starts_with("--")) else {
        eprintln!("vrx install: an applet directory is required");
        return ExitCode::from(64);
    };
    let root = args
        .iter()
        .position(|a| a == "--root")
        .and_then(|i| args.get(i + 1))
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/"));
    let src = PathBuf::from(src);

    let manifest_path = src.join("manifest.toml");
    let Ok(text) = std::fs::read_to_string(&manifest_path) else {
        eprintln!("vrx install: no manifest.toml in {}", src.display());
        return ExitCode::from(66);
    };
    let manifest: Manifest = match text.parse() {
        Ok(manifest) => manifest,
        Err(err) => {
            eprintln!("vrx install: manifest invalid: {err}");
            return ExitCode::from(65);
        }
    };

    let dest = root.join("apps").join(&manifest.applet.id);
    if dest.exists() {
        eprintln!(
            "vrx install: refusing to overwrite {} (uninstall first)",
            dest.display()
        );
        return ExitCode::from(73);
    }
    if let Err(err) = copy_dir(&src, &dest) {
        eprintln!("vrx install: {err}");
        return ExitCode::FAILURE;
    }
    println!("installed {} at {}", manifest.applet.id, dest.display());
    ExitCode::SUCCESS
}

fn copy_dir(src: &Path, dest: &Path) -> std::io::Result<()> {
    std::fs::create_dir_all(dest)?;
    for entry in std::fs::read_dir(src)? {
        let entry = entry?;
        let from = entry.path();
        let to = dest.join(entry.file_name());
        if from.is_dir() {
            // build artifacts and dependency caches never install
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if matches!(name.as_ref(), "target" | ".dart_tool" | "build" | ".git") {
                continue;
            }
            copy_dir(&from, &to)?;
        } else {
            std::fs::copy(&from, &to)?;
        }
    }
    Ok(())
}
