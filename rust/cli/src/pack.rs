// `vrx pack`: an applet as it installs, made into the package vrxhost
// installs (plan 0011 D16): a systemd system extension image, <id>.raw,
// holding exactly usr/lib/vrx/apps/<id>/ and its extension-release file.
// The input is the applet's folder as it will be on the device
// (manifest.toml, and its `app` or its Flutter AOT bundle at <flutter
// version>/release). The manifest is checked as an installed applet's
// before anything is written: no roles, no system grants, no fs paths,
// no sys. emits, handler priorities 0-499.
//
// Signed (plan 0013 D3), the image is systemd's Discoverable Disk Image,
// written by `systemd-repart --make-ddi=sysext`: an erofs root, its
// dm-verity hash tree and a PKCS#7 signature of the root hash. The
// device's kernel verifies that signature against the certificate it was
// built with; a release image merges nothing else. Unsigned (`--unsigned`)
// it is a bare erofs image, which only a debug image (VRX_DEBUG = "1")
// accepts.
//
//   vrx pack <applet dir> [--out <dir>] [--arch arm64|x86-64]
//            (--key <key.pem> --cert <cert.pem> | --unsigned)
//
// The key and certificate may also come from VRX_SIGNING_KEY and
// VRX_SIGNING_CERT. A debug build tree's development pair is
// conf/vrx-dev-keys/install.{key,crt} in its build directory (yocto's
// setup-build.sh makes it once per tree). systemd-repart and mkfs.erofs
// run on the host when it has them (Linux, as root for root-owned files),
// otherwise in a Debian container through podman or docker.
//
// Copy the image to /var/lib/vrx/offers on the device (or the apps/
// folder of its USB drive); the launcher asks before installing it.

use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};

use vrx_protocol::sysext::{release_path, release_text, APPS_DIR};
use vrx_protocol::{Manifest, Registry, RegistryEntry};

/// How the image is written.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Signing {
    /// A signed Discoverable Disk Image (systemd-repart).
    Signed { key: PathBuf, cert: PathBuf },
    /// A bare erofs image, for debug images only.
    Unsigned,
}

/// What `vrx pack` was asked.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Options {
    src: PathBuf,
    out_dir: PathBuf,
    arch: String,
    signing: Signing,
}

/// The architectures systemd-repart names a root partition for, among
/// the ones vrx builds: the board's, never the packing host's.
const ARCHES: [&str; 2] = ["arm64", "x86-64"];

fn parse(
    args: &[String],
    env: &dyn Fn(&str) -> Option<String>,
) -> Result<Options, String> {
    let value = |flag: &str| -> Option<String> {
        args.iter()
            .position(|a| a == flag)
            .and_then(|i| args.get(i + 1))
            .cloned()
    };
    let flags_with_value = ["--out", "--arch", "--key", "--cert"];
    let mut src = None;
    let mut skip = false;
    for a in args {
        if skip {
            skip = false;
            continue;
        }
        if flags_with_value.contains(&a.as_str()) {
            skip = true;
            continue;
        }
        if !a.starts_with("--") && src.is_none() {
            src = Some(PathBuf::from(a));
        }
    }
    let src = src.ok_or("an applet directory is required")?;
    let arch = value("--arch").unwrap_or_else(|| "arm64".to_owned());
    if !ARCHES.contains(&arch.as_str()) {
        return Err(format!("--arch {arch}: one of {}", ARCHES.join(", ")));
    }
    let key = value("--key").or_else(|| env("VRX_SIGNING_KEY"));
    let cert = value("--cert").or_else(|| env("VRX_SIGNING_CERT"));
    let unsigned = args.iter().any(|a| a == "--unsigned");
    let signing = match (key, cert, unsigned) {
        (_, _, true) => Signing::Unsigned,
        (Some(key), Some(cert), false) => Signing::Signed {
            key: PathBuf::from(key),
            cert: PathBuf::from(cert),
        },
        (Some(_), None, false) | (None, Some(_), false) => {
            return Err("a signed image needs both --key and --cert".to_owned())
        }
        (None, None, false) => {
            return Err("sign the image with --key <key.pem> --cert <cert.pem> \
                        (or VRX_SIGNING_KEY and VRX_SIGNING_CERT), or pass --unsigned \
                        for a debug image"
                .to_owned())
        }
    };
    Ok(Options {
        src,
        out_dir: value("--out").map_or_else(|| PathBuf::from("."), PathBuf::from),
        arch,
        signing,
    })
}

pub fn run(args: &[String]) -> ExitCode {
    let opts = match parse(args, &|k| std::env::var(k).ok()) {
        Ok(o) => o,
        Err(err) => {
            eprintln!("vrx pack: {err}");
            return ExitCode::from(64);
        }
    };
    let src = &opts.src;
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
    if let Signing::Signed { key, cert } = &opts.signing {
        for f in [key, cert] {
            if !f.is_file() {
                eprintln!("vrx pack: {}: no such file", f.display());
                return ExitCode::from(66);
            }
        }
    }
    let stage =
        std::env::temp_dir().join(format!("vrx-pack-{id}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&stage);
    let staged = (|| -> std::io::Result<()> {
        copy_dir(src, &stage.join(APPS_DIR).join(&id))?;
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
    if let Err(err) = std::fs::create_dir_all(&opts.out_dir) {
        eprintln!("vrx pack: {}: {err}", opts.out_dir.display());
        let _ = std::fs::remove_dir_all(&stage);
        return ExitCode::FAILURE;
    }
    let image = opts.out_dir.join(format!("{id}.raw"));
    let _ = std::fs::remove_file(&image);
    let made = make_image(&opts, &stage, &image);
    let _ = std::fs::remove_dir_all(&stage);
    match made {
        Ok(()) => {
            let how = match opts.signing {
                Signing::Signed { .. } => "signed",
                Signing::Unsigned => {
                    "unsigned: a debug image accepts it, a release image refuses it"
                }
            };
            println!(
                "packed {id} {} at {} ({how})",
                manifest.applet.version,
                image.display()
            );
            ExitCode::SUCCESS
        }
        Err(err) => {
            eprintln!("vrx pack: {err}");
            ExitCode::FAILURE
        }
    }
}

/// The container image that packs on a host without systemd-repart:
/// Debian's systemd-repart (it dlopens libcryptsetup for verity) and
/// erofs-utils.
const PACK_IMAGE: &str = "vrx-pack:1";
const PACK_DOCKERFILE: &str = "FROM debian:trixie\n\
RUN apt-get update && apt-get install -y --no-install-recommends \
systemd-repart erofs-utils libcryptsetup12 && rm -rf /var/lib/apt/lists/*\n";

/// The command line that writes the image, as run where the tools are:
/// `root` is the staged tree, `out` the image, `key`/`cert` the pair.
fn image_command(
    signing: &Signing,
    arch: &str,
    root: &str,
    out: &str,
    keys: Option<(&str, &str)>,
) -> Vec<String> {
    match (signing, keys) {
        (Signing::Signed { .. }, Some((key, cert))) => vec![
            "systemd-repart".into(),
            "--make-ddi=sysext".into(),
            format!("--copy-source={root}"),
            format!("--private-key={key}"),
            format!("--certificate={cert}"),
            format!("--architecture={arch}"),
            "--offline=yes".into(),
            out.into(),
        ],
        _ => vec![
            "mkfs.erofs".into(),
            "--all-root".into(),
            out.into(),
            root.into(),
        ],
    }
}

fn on_path(tool: &str) -> bool {
    std::env::var_os("PATH").is_some_and(|paths| {
        std::env::split_paths(&paths).any(|d| d.join(tool).is_file())
    })
}

/// Write the image: with the host's tools when it has them, otherwise in
/// the packing container.
fn make_image(opts: &Options, stage: &Path, image: &Path) -> Result<(), String> {
    let tool = match opts.signing {
        Signing::Signed { .. } => "systemd-repart",
        Signing::Unsigned => "mkfs.erofs",
    };
    if on_path(tool) {
        let keys = match &opts.signing {
            Signing::Signed { key, cert } => Some((
                key.to_string_lossy().into_owned(),
                cert.to_string_lossy().into_owned(),
            )),
            Signing::Unsigned => None,
        };
        let argv = image_command(
            &opts.signing,
            &opts.arch,
            &stage.to_string_lossy(),
            &image.to_string_lossy(),
            keys.as_ref().map(|(k, c)| (k.as_str(), c.as_str())),
        );
        return run_status(Command::new(&argv[0]).args(&argv[1..]), tool);
    }
    let engine = ["podman", "docker"]
        .into_iter()
        .find(|e| on_path(e))
        .ok_or_else(|| {
            format!("{tool} is not installed and neither podman nor docker is, to run it in a container")
        })?;
    let have = Command::new(engine)
        .args(["image", "inspect", PACK_IMAGE])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .is_ok_and(|s| s.success());
    if !have {
        eprintln!("vrx pack: building the {PACK_IMAGE} container image (once)");
        let mut build = Command::new(engine)
            .args(["build", "-t", PACK_IMAGE, "-"])
            .stdin(std::process::Stdio::piped())
            .spawn()
            .map_err(|e| format!("{engine} build: {e}"))?;
        if let Some(mut stdin) = build.stdin.take() {
            use std::io::Write as _;
            stdin
                .write_all(PACK_DOCKERFILE.as_bytes())
                .map_err(|e| format!("{engine} build: {e}"))?;
        }
        let status = build.wait().map_err(|e| format!("{engine} build: {e}"))?;
        if !status.success() {
            return Err(format!("{engine} build {PACK_IMAGE}: {status}"));
        }
    }
    let out_dir = image
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_else(|| PathBuf::from("."));
    let out_dir = out_dir.canonicalize().unwrap_or(out_dir);
    let file = image
        .file_name()
        .map(|f| f.to_string_lossy().into_owned())
        .unwrap_or_default();
    let mut cmd = Command::new(engine);
    cmd.args(["run", "--rm"])
        .arg("-v")
        .arg(format!("{}:/stage:ro", stage.display()))
        .arg("-v")
        .arg(format!("{}:/out", out_dir.display()));
    let keys = match &opts.signing {
        Signing::Signed { key, cert } => {
            let key = key
                .canonicalize()
                .map_err(|e| format!("{}: {e}", key.display()))?;
            let cert = cert
                .canonicalize()
                .map_err(|e| format!("{}: {e}", cert.display()))?;
            cmd.arg("-v")
                .arg(format!("{}:/keys/install.key:ro", key.display()))
                .arg("-v")
                .arg(format!("{}:/keys/install.crt:ro", cert.display()));
            Some(("/keys/install.key", "/keys/install.crt"))
        }
        Signing::Unsigned => None,
    };
    // the tree is copied inside the container and owned by root there:
    // systemd-repart keeps the files' owners (it runs mkfs.erofs without
    // --all-root), and a bind mount carries the host user's
    let argv = image_command(
        &opts.signing,
        &opts.arch,
        "/tmp/root",
        &format!("/out/{file}"),
        keys,
    );
    let script = format!(
        "cp -a /stage /tmp/root && chown -R 0:0 /tmp/root && {}",
        argv.join(" ")
    );
    cmd.args([PACK_IMAGE, "sh", "-c", &script]);
    run_status(&mut cmd, tool)
}

fn run_status(cmd: &mut Command, tool: &str) -> Result<(), String> {
    match cmd.status() {
        Ok(status) if status.success() => Ok(()),
        Ok(status) => Err(format!("{tool} failed: {status}")),
        Err(err) => Err(format!("cannot run {tool}: {err}")),
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
            // build artifacts and dependency caches never ship — at the
            // applet's OWN root only (review 2026-10-17, CON-06: a data
            // directory named build any deeper was silently dropped from
            // every image)
            if depth == 0 {
                let name = entry.file_name();
                if matches!(
                    name.to_string_lossy().as_ref(),
                    "target" | ".dart_tool" | "build" | ".git"
                ) {
                    continue;
                }
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

    fn args(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| (*s).to_owned()).collect()
    }

    /// Plan 0013 D3: an image is signed unless the developer says
    /// --unsigned, and a signed one needs both halves of the pair.
    #[test]
    fn packing_signs_unless_told_otherwise() {
        let none = |_: &str| None;
        assert!(parse(&args(&["app"]), &none).is_err());
        assert!(parse(&args(&["app", "--key", "k.pem"]), &none).is_err());
        let signed =
            parse(&args(&["app", "--key", "k.pem", "--cert", "c.pem"]), &none).unwrap();
        assert_eq!(
            signed.signing,
            Signing::Signed {
                key: "k.pem".into(),
                cert: "c.pem".into()
            }
        );
        assert_eq!(signed.src, PathBuf::from("app"));
        assert_eq!(signed.arch, "arm64");
        let unsigned = parse(&args(&["--unsigned", "app", "--out", "o"]), &none).unwrap();
        assert_eq!(unsigned.signing, Signing::Unsigned);
        assert_eq!(unsigned.out_dir, PathBuf::from("o"));
        let env = |k: &str| match k {
            "VRX_SIGNING_KEY" => Some("/e/k".to_owned()),
            "VRX_SIGNING_CERT" => Some("/e/c".to_owned()),
            _ => None,
        };
        assert!(matches!(
            parse(&args(&["app"]), &env).unwrap().signing,
            Signing::Signed { .. }
        ));
        assert!(
            parse(&args(&["app", "--unsigned", "--arch", "riscv64"]), &none).is_err()
        );
        assert_eq!(
            parse(&args(&["--arch", "x86-64", "--unsigned", "app"]), &none)
                .unwrap()
                .src,
            PathBuf::from("app")
        );
    }

    #[test]
    fn a_signed_image_is_a_ddi_for_the_boards_architecture() {
        let signed = Signing::Signed {
            key: "k".into(),
            cert: "c".into(),
        };
        let argv = image_command(
            &signed,
            "arm64",
            "/tmp/root",
            "/out/notes.raw",
            Some(("/k", "/c")),
        );
        assert_eq!(argv[0], "systemd-repart");
        for want in [
            "--make-ddi=sysext",
            "--copy-source=/tmp/root",
            "--private-key=/k",
            "--certificate=/c",
            "--architecture=arm64",
            "--offline=yes",
            "/out/notes.raw",
        ] {
            assert!(argv.iter().any(|a| a == want), "{want}: {argv:?}");
        }
        let bare = image_command(&Signing::Unsigned, "arm64", "/s", "/o.raw", None);
        assert_eq!(bare, ["mkfs.erofs", "--all-root", "/o.raw", "/s"]);
    }

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
