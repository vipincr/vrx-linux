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

/// Where the Flutter engine every applet shares lives (meta-flutter's
/// flutter-engine, one per version), relative to /.
const SHARED_ENGINE: &str = "usr/share/flutter/";

/// What a symlink in the applet's folder becomes in the image. A built
/// bundle links the shared engine and ICU data relatively, valid only
/// from where the build put it (a built-in's
/// `/system/defaults/<id>/<version>/release` climbs six levels to /); in
/// an installed applet's folder the same link would point at
/// /usr/usr/share. So a link into the shared engine becomes absolute,
/// which resolves wherever systemd-sysext merges the image. Any other
/// link must stay inside the applet's folder (`depth` is how deep the
/// link sits below it).
fn link_target(target: &Path, depth: usize) -> Result<PathBuf, String> {
    let text = target.to_string_lossy();
    if let Some(at) = text.find(SHARED_ENGINE) {
        return Ok(PathBuf::from(format!("/{}", &text[at..])));
    }
    if target.is_absolute() {
        return Err(format!("points outside the applet ({text})"));
    }
    let mut level = depth as isize;
    for part in target.components() {
        match part {
            std::path::Component::ParentDir => level -= 1,
            std::path::Component::Normal(_) => level += 1,
            _ => {}
        }
        if level < 0 {
            return Err(format!("points outside the applet ({text})"));
        }
    }
    Ok(target.to_path_buf())
}

fn copy_dir(src: &Path, dest: &Path) -> std::io::Result<()> {
    copy_tree(src, dest, 0)
}

fn copy_tree(src: &Path, dest: &Path, depth: usize) -> std::io::Result<()> {
    std::fs::create_dir_all(dest)?;
    for entry in std::fs::read_dir(src)? {
        let entry = entry?;
        let from = entry.path();
        let to = dest.join(entry.file_name());
        let kind = entry.file_type()?;
        if kind.is_symlink() {
            // kept a link (the engine is not copied into every applet)
            let target = std::fs::read_link(&from)?;
            let target = link_target(&target, depth).map_err(|why| {
                std::io::Error::other(format!("{}: {why}", from.display()))
            })?;
            #[cfg(unix)]
            std::os::unix::fs::symlink(&target, &to)?;
        } else if kind.is_dir() {
            // build artifacts and dependency caches never ship
            let name = entry.file_name();
            if matches!(
                name.to_string_lossy().as_ref(),
                "target" | ".dart_tool" | "build" | ".git"
            ) {
                continue;
            }
            copy_tree(&from, &to, depth + 1)?;
        } else {
            std::fs::copy(&from, &to)?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_link_into_the_shared_engine_becomes_absolute_and_others_stay_inside() {
        // as a built-in's bundle links it, from <version>/release/lib
        assert_eq!(
            link_target(
                Path::new("../../../../../../usr/share/flutter/3.47.5/release/lib/libflutter_engine.so"),
                3
            ),
            Ok(PathBuf::from("/usr/share/flutter/3.47.5/release/lib/libflutter_engine.so"))
        );
        assert_eq!(
            link_target(
                Path::new("/usr/share/flutter/3.47.5/release/data/icudtl.dat"),
                3
            ),
            Ok(PathBuf::from(
                "/usr/share/flutter/3.47.5/release/data/icudtl.dat"
            ))
        );
        assert_eq!(
            link_target(Path::new("../data/x"), 3),
            Ok(PathBuf::from("../data/x"))
        );
        assert!(link_target(Path::new("/etc/shadow"), 3).is_err());
        assert!(link_target(Path::new("../../../../x"), 3).is_err());
        assert!(link_target(Path::new("../x"), 0).is_err());
    }

    #[test]
    fn packing_keeps_links_and_rewrites_the_engines() {
        let root =
            std::env::temp_dir().join(format!("vrx-pack-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let src = root.join("src");
        let lib = src.join("3.47.5/release/lib");
        std::fs::create_dir_all(&lib).unwrap();
        std::fs::write(lib.join("libapp.so"), "elf").unwrap();
        std::os::unix::fs::symlink(
            "../../../../../../usr/share/flutter/3.47.5/release/lib/libflutter_engine.so",
            lib.join("libflutter_engine.so"),
        )
        .unwrap();
        let dest = root.join("dest");
        copy_dir(&src, &dest).unwrap();
        let out = dest.join("3.47.5/release/lib");
        assert_eq!(
            std::fs::read_to_string(out.join("libapp.so")).unwrap(),
            "elf"
        );
        assert_eq!(
            std::fs::read_link(out.join("libflutter_engine.so")).unwrap(),
            PathBuf::from("/usr/share/flutter/3.47.5/release/lib/libflutter_engine.so")
        );
        std::os::unix::fs::symlink("/etc/shadow", lib.join("bad")).unwrap();
        assert!(copy_dir(&src, &root.join("dest2")).is_err());
        let _ = std::fs::remove_dir_all(&root);
    }
}
