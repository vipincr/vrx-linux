// `vrx pack`: an applet as it installs, made into the package vrxhost
// installs (plan 0011 D16): a systemd system extension image, <id>.raw,
// erofs, holding exactly usr/lib/vrx/apps/<id>/ and its
// extension-release file. The input is the applet's folder as it will
// be on the device (manifest.toml, and its `app` or its Flutter AOT
// bundle at <flutter version>/release). The manifest is checked as an
// installed applet's before anything is written: no roles, no system
// grants, no fs paths, no sys. emits, handler priorities 0-499.
//
//   vrx pack <applet dir> [--out <dir>]
//
// Copy the image to /var/lib/vrx/offers on the device (or the apps/
// folder of its USB drive); the launcher asks before installing it.

use std::path::{Path, PathBuf};
use std::process::ExitCode;

use vrx_protocol::sysext::{release_path, release_text, APPS_DIR};
use vrx_protocol::{Manifest, Registry, RegistryEntry};

pub fn run(args: &[String]) -> ExitCode {
    let Some(src) = args.iter().find(|a| !a.starts_with("--")) else {
        eprintln!("vrx pack: an applet directory is required");
        return ExitCode::from(64);
    };
    let out_dir = args
        .iter()
        .position(|a| a == "--out")
        .and_then(|i| args.get(i + 1))
        .map_or_else(|| PathBuf::from("."), PathBuf::from);
    let src = PathBuf::from(src);
    let manifest: Manifest = match std::fs::read_to_string(src.join("manifest.toml"))
        .map_err(|e| e.to_string())
        .and_then(|t| t.parse::<Manifest>().map_err(|e| e.to_string()))
    {
        Ok(m) => m,
        Err(err) => {
            eprintln!("vrx pack: {}/manifest.toml: {err}", src.display());
            return ExitCode::from(65);
        }
    };
    let id = manifest.applet.id.clone();
    let as_installed = Registry::new().admit(RegistryEntry {
        manifest: manifest.clone(),
        path: PathBuf::from(format!("/{APPS_DIR}/{id}")),
        builtin: false,
    });
    if let Err(err) = as_installed {
        eprintln!("vrx pack: {err}");
        return ExitCode::from(65);
    }
    let stage =
        std::env::temp_dir().join(format!("vrx-pack-{id}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&stage);
    let staged = (|| -> std::io::Result<()> {
        copy_dir(&src, &stage.join(APPS_DIR).join(&id))?;
        let release = stage.join(release_path(&id));
        if let Some(parent) = release.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(release, release_text())
    })();
    if let Err(err) = staged {
        eprintln!("vrx pack: staging: {err}");
        let _ = std::fs::remove_dir_all(&stage);
        return ExitCode::FAILURE;
    }
    let image = out_dir.join(format!("{id}.raw"));
    let _ = std::fs::remove_file(&image);
    let made = std::process::Command::new("mkfs.erofs")
        .arg("--all-root")
        .arg(&image)
        .arg(&stage)
        .status();
    let _ = std::fs::remove_dir_all(&stage);
    match made {
        Ok(status) if status.success() => {
            println!(
                "packed {id} {} at {}",
                manifest.applet.version,
                image.display()
            );
            ExitCode::SUCCESS
        }
        Ok(status) => {
            eprintln!("vrx pack: mkfs.erofs failed: {status}");
            ExitCode::FAILURE
        }
        Err(err) => {
            eprintln!("vrx pack: cannot run mkfs.erofs (erofs-utils): {err}");
            ExitCode::from(127)
        }
    }
}

fn copy_dir(src: &Path, dest: &Path) -> std::io::Result<()> {
    std::fs::create_dir_all(dest)?;
    for entry in std::fs::read_dir(src)? {
        let entry = entry?;
        let from = entry.path();
        let to = dest.join(entry.file_name());
        if from.is_dir() {
            // build artifacts and dependency caches never ship
            let name = entry.file_name();
            if matches!(
                name.to_string_lossy().as_ref(),
                "target" | ".dart_tool" | "build" | ".git"
            ) {
                continue;
            }
            copy_dir(&from, &to)?;
        } else {
            std::fs::copy(&from, &to)?;
        }
    }
    Ok(())
}
