// Installing applets (plan 0011 D16): an installed applet is a systemd
// system extension, `<id>.raw`, an erofs image holding exactly its folder
// (`usr/lib/vrx/apps/<id>/`) and its extension-release file. systemd does
// the work: `systemd-dissect` reads an image without merging it,
// `systemd-sysext` merges what is in /var/lib/extensions over /usr, and
// refuses an image built for another SYSEXT_LEVEL after an update. vrx
// adds what systemd has no notion of: the offer and the consent, the
// checks that keep an installed applet inside its folder and without
// authority (G023), and its unit drop-in, written by the one generator
// built-ins use (vrx_protocol::unit, D17).
//
// Offers wait in /var/lib/vrx/offers (a developer copies one there over
// ssh), and come in from the USB drive's `apps/` folder once file
// sharing has stopped. Nothing is copied before the person agrees, and
// what they agreed to is the build (the image's SHA-256): a file changed
// between the offer and the consent is refused.

use std::path::{Path, PathBuf};

use serde::Serialize;
use vrx_protocol::sysext::{release_ok, release_path, APPS_DIR};
use vrx_protocol::unit::{dropin, settings_defaults, Grants, Place};
use vrx_protocol::{Manifest, Registry, RegistryEntry};

/// Where systemd-sysext looks for extensions (on /data's /var).
pub const EXTENSIONS: &str = "/var/lib/extensions";

/// Where offers wait for consent.
pub const OFFERS: &str = "/var/lib/vrx/offers";

/// The USB drive's image (plan 0008 Part G) and the unit sharing it.
pub const DRIVE: &str = "/data/usb/files.img";
pub const DRIVE_UNIT: &str = "vrx-usb-files.service";

/// Why an image is not installed. Each has one sentence in the kit's
/// words table; the reason travels as its key.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum Refusal {
    #[error("name: the file is not named <applet>.raw")]
    Name,
    #[error("paths: the image holds {0}, outside its applet's folder")]
    Paths(String),
    #[error("release: its extension-release is not vrx's at this SYSEXT_LEVEL")]
    Release,
    #[error("manifest: {0}")]
    Manifest(String),
    #[error("builtin: {0} is a built-in applet")]
    Builtin(String),
    #[error("flutter: its bundle was built for Flutter {0}, this system runs {1}")]
    Flutter(String, String),
    #[error("unreadable: {0}")]
    Unreadable(String),
}

impl Refusal {
    /// The key the kit phrases.
    pub fn key(&self) -> &'static str {
        match self {
            Refusal::Name => "name",
            Refusal::Paths(_) => "paths",
            Refusal::Release => "release",
            Refusal::Manifest(_) => "manifest",
            Refusal::Builtin(_) => "builtin",
            Refusal::Flutter(..) => "flutter",
            Refusal::Unreadable(_) => "unreadable",
        }
    }
}

/// The applet id an offer file names: `<id>.raw`, as systemd-sysext
/// requires (the image's name is its extension's name).
pub fn id_of_file(file: &str) -> Option<&str> {
    let id = file.strip_suffix(".raw")?;
    let ok = !id.is_empty()
        && id.len() <= 32
        && id.chars().next().is_some_and(|c| c.is_ascii_lowercase())
        && id
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_');
    ok.then_some(id)
}

/// Check `systemd-dissect --list`'s output for applet `id`: nothing but
/// its folder, the directories above it and its extension-release file.
/// A Flutter bundle's folder (`<version>/release`, with lib/libapp.so) is
/// returned, relative to the applet's folder.
pub fn check_listing(id: &str, listing: &str) -> Result<Option<String>, Refusal> {
    let own = format!("{APPS_DIR}/{id}/");
    let release = release_path(id);
    let parents = [
        "usr",
        "usr/lib",
        "usr/lib/vrx",
        APPS_DIR,
        "usr/lib/extension-release.d",
    ];
    let mut bundle = None;
    for line in listing.lines() {
        let path = line.trim().trim_start_matches("./").trim_start_matches('/');
        let path = path.strip_suffix('/').unwrap_or(path);
        if path.is_empty() || path == "." || parents.contains(&path) || path == release {
            continue;
        }
        if path.split('/').any(|c| c == "..") {
            return Err(Refusal::Paths(path.to_owned()));
        }
        let Some(inside) = format!("{path}/").strip_prefix(&own).map(str::to_owned)
        else {
            return Err(Refusal::Paths(path.to_owned()));
        };
        if let Some(dir) = inside.strip_suffix("/release/lib/libapp.so/") {
            bundle = Some(format!("{dir}/release"));
        }
    }
    Ok(bundle)
}

/// The extension-release file: `ID=vrx` and vrx's `SYSEXT_LEVEL`.
pub fn check_release(text: &str) -> Result<(), Refusal> {
    if release_ok(text) {
        Ok(())
    } else {
        Err(Refusal::Release)
    }
}

/// What agreeing to an offer would do.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    /// Not installed: install it.
    Install,
    /// A newer version of an installed applet.
    Update,
    /// The same version, a different build.
    Replace,
    /// An older version than the installed one.
    Older,
    /// Exactly what is installed: nothing to do.
    Same,
}

/// Dotted versions compared number by number (1.10 > 1.9); a part that
/// is not a number compares as text.
pub fn version_cmp(a: &str, b: &str) -> std::cmp::Ordering {
    let parts = |v: &str| {
        v.split(['.', '-', '+'])
            .map(str::to_owned)
            .collect::<Vec<_>>()
    };
    let (pa, pb) = (parts(a), parts(b));
    for i in 0..pa.len().max(pb.len()) {
        let (x, y) = (
            pa.get(i).map_or("0", String::as_str),
            pb.get(i).map_or("0", String::as_str),
        );
        let o = match (x.parse::<u64>(), y.parse::<u64>()) {
            (Ok(x), Ok(y)) => x.cmp(&y),
            _ => x.cmp(y),
        };
        if o != std::cmp::Ordering::Equal {
            return o;
        }
    }
    std::cmp::Ordering::Equal
}

/// The offer's kind against what is installed (version, build).
pub fn kind_of(installed: Option<(&str, &str)>, version: &str, build: &str) -> Kind {
    use std::cmp::Ordering;
    match installed {
        None => Kind::Install,
        Some((_, b)) if b == build => Kind::Same,
        Some((v, _)) => match version_cmp(version, v) {
            Ordering::Greater => Kind::Update,
            Ordering::Equal => Kind::Replace,
            Ordering::Less => Kind::Older,
        },
    }
}

/// Admit `manifest` as an installed applet beside the registry's other
/// applets (a built-in's id refused, the installed rules applied: no
/// roles, no system grants, no fs, no sys. emits, priorities 0-499). An
/// installed applet of the same id is the one being replaced.
pub fn check_manifest(
    registry: &Registry,
    manifest: &Manifest,
    dir: PathBuf,
) -> Result<(), Refusal> {
    let id = &manifest.applet.id;
    if registry.find(id).is_some_and(|e| e.builtin) {
        return Err(Refusal::Builtin(id.clone()));
    }
    let mut scratch = Registry::new();
    for e in registry.iter().filter(|e| e.builtin) {
        let _ = scratch.admit(e.clone());
    }
    scratch
        .admit(RegistryEntry {
            manifest: manifest.clone(),
            path: dir,
            builtin: false,
        })
        .map_err(|e| Refusal::Manifest(e.to_string()))
}

/// The Flutter version this system's built-ins were built for: the name
/// of the directory holding a built-in's `release` bundle.
pub fn system_flutter(defaults: &Path) -> Option<String> {
    let mut dirs: Vec<PathBuf> = std::fs::read_dir(defaults)
        .ok()?
        .flatten()
        .map(|e| e.path())
        .collect();
    dirs.sort();
    dirs.iter().find_map(|applet| {
        std::fs::read_dir(applet).ok()?.flatten().find_map(|v| {
            v.path()
                .join("release/lib/libapp.so")
                .is_file()
                .then(|| v.file_name().to_string_lossy().into_owned())
        })
    })
}

/// One offer, as the launcher shows it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Offer {
    pub file: String,
    pub id: String,
    pub name: String,
    pub version: String,
    /// The image's SHA-256: the build the person agrees to.
    pub build: String,
    pub kind: Kind,
    /// The installed version, when one is.
    pub installed: Option<String>,
    /// Why it cannot be installed (a Refusal key), when it cannot.
    pub problem: Option<String>,
}

/// What an image says about itself, read without merging it.
pub struct Inspected {
    pub manifest: Manifest,
    pub bundle: Option<String>,
    pub build: String,
}

async fn output(program: &str, args: &[&str]) -> Result<String, Refusal> {
    let out = tokio::process::Command::new(program)
        .args(args)
        .output()
        .await
        .map_err(|e| Refusal::Unreadable(format!("{program}: {e}")))?;
    if !out.status.success() {
        return Err(Refusal::Unreadable(format!(
            "{program} {}: {}",
            args.first().unwrap_or(&""),
            String::from_utf8_lossy(&out.stderr).trim()
        )));
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

/// A file inside an image, through `systemd-dissect --copy-from`.
async fn read_inside(image: &Path, path: &str) -> Result<String, Refusal> {
    let tmp = std::env::temp_dir().join(format!(
        "vrx-inspect-{}-{}",
        std::process::id(),
        path.replace('/', "_")
    ));
    let _ = std::fs::remove_file(&tmp);
    output(
        "systemd-dissect",
        &[
            "--copy-from",
            &image.to_string_lossy(),
            path,
            &tmp.to_string_lossy(),
        ],
    )
    .await?;
    let text =
        std::fs::read_to_string(&tmp).map_err(|e| Refusal::Unreadable(e.to_string()));
    let _ = std::fs::remove_file(&tmp);
    text
}

/// The image's SHA-256.
pub async fn build_of(image: &Path) -> Result<String, Refusal> {
    let out = output("sha256sum", &[&image.to_string_lossy()]).await?;
    out.split_whitespace()
        .next()
        .map(str::to_owned)
        .ok_or_else(|| Refusal::Unreadable("sha256sum said nothing".into()))
}

/// Read an offer: its listing, its release file and its manifest, every
/// check but the registry's.
pub async fn inspect(image: &Path) -> Result<Inspected, Refusal> {
    let file = image
        .file_name()
        .map(|f| f.to_string_lossy().into_owned())
        .unwrap_or_default();
    let id = id_of_file(&file).ok_or(Refusal::Name)?.to_owned();
    let listing =
        output("systemd-dissect", &["--list", &image.to_string_lossy()]).await?;
    let bundle = check_listing(&id, &listing)?;
    check_release(&read_inside(image, &format!("/{}", release_path(&id))).await?)?;
    let manifest: Manifest =
        read_inside(image, &format!("/{APPS_DIR}/{id}/manifest.toml"))
            .await?
            .parse()
            .map_err(|e: vrx_protocol::manifest::ManifestError| {
                Refusal::Manifest(e.to_string())
            })?;
    if manifest.applet.id != id {
        return Err(Refusal::Name);
    }
    Ok(Inspected {
        manifest,
        bundle,
        build: build_of(image).await?,
    })
}

/// The unit drop-in of installed applet `id`.
pub fn dropin_path(id: &str) -> PathBuf {
    PathBuf::from(format!(
        "/etc/systemd/system/vrx-applet@{id}.service.d/10-manifest.conf"
    ))
}

/// Write what systemd and Settings need for an installed applet: its
/// drop-in (installed = true: a dynamic user, no grants) and, when absent,
/// its settings defaults.
pub fn write_unit(inspected: &Inspected) -> Result<(), String> {
    let a = &inspected.manifest.applet;
    let dir = format!("/{APPS_DIR}/{}", a.id);
    let place = Place {
        installed: true,
        ..Place::builtin(
            dir.clone(),
            inspected.bundle.as_ref().map(|b| format!("{dir}/{b}")),
        )
    };
    let text = dropin(&inspected.manifest, &place, &Grants::shipped())
        .map_err(|e| e.to_string())?;
    let path = dropin_path(&a.id);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    atomic_write(&path, &text)?;
    if let Some(defaults) = settings_defaults(&inspected.manifest) {
        let settings = PathBuf::from(format!("/etc/vrx/settings/{}.conf", a.id));
        if !settings.exists() {
            atomic_write(&settings, &defaults)?;
        }
    }
    Ok(())
}

fn atomic_write(path: &Path, text: &str) -> Result<(), String> {
    let tmp = path.with_extension("tmp");
    std::fs::write(&tmp, text).map_err(|e| format!("{}: {e}", tmp.display()))?;
    std::fs::rename(&tmp, path).map_err(|e| format!("{}: {e}", path.display()))
}

/// Copy an offer into /var/lib/extensions as `<id>.raw` (temp, rename).
pub async fn stage(image: &Path, id: &str) -> Result<(), String> {
    let image = image.to_path_buf();
    let id = id.to_owned();
    tokio::task::spawn_blocking(move || {
        std::fs::create_dir_all(EXTENSIONS).map_err(|e| e.to_string())?;
        let dest = Path::new(EXTENSIONS).join(format!("{id}.raw"));
        let tmp = Path::new(EXTENSIONS).join(format!(".{id}.raw.tmp"));
        std::fs::copy(&image, &tmp).map_err(|e| e.to_string())?;
        std::fs::rename(&tmp, &dest).map_err(|e| e.to_string())
    })
    .await
    .map_err(|e| e.to_string())?
}

/// Merge what /var/lib/extensions now holds: systemd-sysext's Varlink
/// interface when it is there (`io.systemd.sysext.Refresh`), else the
/// command, which does the same.
pub async fn refresh() -> Result<(), String> {
    let socket = Path::new("/run/systemd/io.systemd.sysext");
    if socket.exists() {
        match varlink_call(socket, "io.systemd.sysext.Refresh", serde_json::json!({}))
            .await
        {
            Ok(()) => return Ok(()),
            Err(err) => {
                tracing::warn!(error = %err, "io.systemd.sysext.Refresh; running systemd-sysext refresh")
            }
        }
    }
    output("systemd-sysext", &["refresh"])
        .await
        .map(|_| ())
        .map_err(|e| e.to_string())
}

/// One Varlink call, its reply checked for an error.
async fn varlink_call(
    socket: &Path,
    method: &str,
    parameters: serde_json::Value,
) -> Result<(), String> {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let mut stream = tokio::net::UnixStream::connect(socket)
        .await
        .map_err(|e| e.to_string())?;
    let mut bytes = serde_json::to_vec(
        &serde_json::json!({ "method": method, "parameters": parameters }),
    )
    .map_err(|e| e.to_string())?;
    bytes.push(0);
    stream.write_all(&bytes).await.map_err(|e| e.to_string())?;
    let mut reply = Vec::new();
    loop {
        let mut byte = [0u8; 1];
        stream
            .read_exact(&mut byte)
            .await
            .map_err(|e| e.to_string())?;
        if byte[0] == 0 {
            break;
        }
        reply.push(byte[0]);
    }
    let reply: serde_json::Value =
        serde_json::from_slice(&reply).map_err(|e| e.to_string())?;
    match reply.get("error").and_then(serde_json::Value::as_str) {
        Some(error) => Err(error.to_owned()),
        None => Ok(()),
    }
}

/// Bring the USB drive's `apps/` offers into /var/lib/vrx/offers: read
/// from the drive's image with `systemd-dissect --copy-from`, only while
/// nothing shares it (the caller checks the unit).
pub async fn import_drive() {
    if !Path::new(DRIVE).exists() {
        return;
    }
    let landing = Path::new(OFFERS).join(".drive");
    let _ = std::fs::remove_dir_all(&landing);
    if output(
        "systemd-dissect",
        &["--copy-from", DRIVE, "/apps", &landing.to_string_lossy()],
    )
    .await
    .is_err()
    {
        return; // no apps/ folder on the drive
    }
    if let Ok(entries) = std::fs::read_dir(&landing) {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if id_of_file(&name).is_some() {
                let _ = std::fs::rename(entry.path(), Path::new(OFFERS).join(&name));
            }
        }
    }
    let _ = std::fs::remove_dir_all(&landing);
}

/// Every offer waiting, read and checked against the registry.
pub async fn offers(registry: &Registry, defaults: &Path) -> Vec<Offer> {
    let mut files: Vec<PathBuf> = std::fs::read_dir(OFFERS)
        .map(|r| r.flatten().map(|e| e.path()).collect())
        .unwrap_or_default();
    files.retain(|p| p.extension().is_some_and(|e| e == "raw"));
    files.sort();
    let flutter = system_flutter(defaults);
    let mut out = Vec::new();
    for path in files {
        let file = path
            .file_name()
            .map(|f| f.to_string_lossy().into_owned())
            .unwrap_or_default();
        let id = id_of_file(&file).unwrap_or("").to_owned();
        let mut offer = Offer {
            file: file.clone(),
            id: id.clone(),
            name: id.clone(),
            version: String::new(),
            build: String::new(),
            kind: Kind::Install,
            installed: None,
            problem: None,
        };
        match check_offer(registry, &path, flutter.as_deref()).await {
            Ok(inspected) => {
                let installed = installed_build(registry, &id).await;
                offer.name = inspected.manifest.applet.name.clone();
                offer.version = inspected.manifest.applet.version.clone();
                offer.kind = kind_of(
                    installed.as_ref().map(|(v, b)| (v.as_str(), b.as_str())),
                    &offer.version,
                    &inspected.build,
                );
                offer.installed = installed.map(|(v, _)| v);
                offer.build = inspected.build;
            }
            Err(refusal) => {
                tracing::info!(%file, reason = %refusal, "offer cannot be installed");
                offer.problem = Some(refusal.key().to_owned());
            }
        }
        out.push(offer);
    }
    out
}

/// Inspect an offer and run every check, the registry's and Flutter's.
pub async fn check_offer(
    registry: &Registry,
    image: &Path,
    flutter: Option<&str>,
) -> Result<Inspected, Refusal> {
    let inspected = inspect(image).await?;
    let id = inspected.manifest.applet.id.clone();
    check_manifest(
        registry,
        &inspected.manifest,
        PathBuf::from(format!("/{APPS_DIR}/{id}")),
    )?;
    if inspected.manifest.applet.runtime == vrx_protocol::manifest::Runtime::Flutter {
        let theirs = inspected
            .bundle
            .as_deref()
            .and_then(|b| b.strip_suffix("/release"))
            .unwrap_or("")
            .to_owned();
        if let Some(ours) = flutter {
            if theirs != ours {
                return Err(Refusal::Flutter(theirs, ours.to_owned()));
            }
        }
    }
    Ok(inspected)
}

/// The installed applet `id`'s version and build, when it is installed.
async fn installed_build(registry: &Registry, id: &str) -> Option<(String, String)> {
    let entry = registry.find(id).filter(|e| !e.builtin)?;
    let build = build_of(&Path::new(EXTENSIONS).join(format!("{id}.raw")))
        .await
        .ok()?;
    Some((entry.manifest.applet.version.clone(), build))
}

/// Remove installed applet `id`: its image, drop-in, state, cache and
/// settings. The caller stops its unit first and refreshes after.
pub fn remove(id: &str) -> Result<(), String> {
    let gone = |p: PathBuf| match std::fs::remove_file(&p) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(format!("{}: {e}", p.display())),
    };
    gone(Path::new(EXTENSIONS).join(format!("{id}.raw")))?;
    gone(dropin_path(id))?;
    gone(PathBuf::from(format!("/etc/vrx/settings/{id}.conf")))?;
    for dir in [
        format!("/var/lib/private/vrx/{id}"),
        format!("/var/cache/private/vrx/{id}"),
    ] {
        match std::fs::remove_dir_all(&dir) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(format!("{dir}: {e}")),
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_offer_file_names_its_applet() {
        assert_eq!(id_of_file("notes.raw"), Some("notes"));
        assert_eq!(id_of_file("notes_2.raw"), Some("notes_2"));
        for bad in [
            "notes",
            "Notes.raw",
            ".raw",
            "../x.raw",
            "9n.raw",
            "a b.raw",
        ] {
            assert_eq!(id_of_file(bad), None, "{bad}");
        }
    }

    /// G023: an image holding anything outside its applet's folder is
    /// refused before it is copied, whatever the manifest says.
    #[test]
    fn only_the_applets_folder_and_its_release_file_may_be_inside_g023() {
        let ok = "usr/\nusr/lib/\nusr/lib/vrx/\nusr/lib/vrx/apps/\nusr/lib/vrx/apps/notes/\nusr/lib/vrx/apps/notes/manifest.toml\nusr/lib/vrx/apps/notes/3.47.5/release/lib/libapp.so\nusr/lib/extension-release.d/\nusr/lib/extension-release.d/extension-release.notes\n";
        assert_eq!(
            check_listing("notes", ok),
            Ok(Some("3.47.5/release".into()))
        );
        let su = format!("{ok}usr/bin/su\n");
        assert_eq!(
            check_listing("notes", &su),
            Err(Refusal::Paths("usr/bin/su".into()))
        );
        let unit =
            format!("{ok}usr/lib/systemd/system/vrx-applet@notes.service.d/x.conf\n");
        assert!(matches!(
            check_listing("notes", &unit),
            Err(Refusal::Paths(_))
        ));
        let other = format!("{ok}usr/lib/vrx/apps/clock/manifest.toml\n");
        assert!(matches!(
            check_listing("notes", &other),
            Err(Refusal::Paths(_))
        ));
        let sneaky = format!("{ok}usr/lib/vrx/apps/notes/../clock/x\n");
        assert!(matches!(
            check_listing("notes", &sneaky),
            Err(Refusal::Paths(_))
        ));
        let release_of_another =
            format!("{ok}usr/lib/extension-release.d/extension-release.clock\n");
        assert!(matches!(
            check_listing("notes", &release_of_another),
            Err(Refusal::Paths(_))
        ));
        assert_eq!(
            check_listing("notes", "usr/lib/vrx/apps/notes/app\n"),
            Ok(None)
        );
    }

    #[test]
    fn the_release_file_must_be_vrxs_and_this_level() {
        assert_eq!(check_release("ID=vrx\nSYSEXT_LEVEL=1\n"), Ok(()));
        assert_eq!(check_release("ID=\"vrx\"\nSYSEXT_LEVEL=\"1\"\n"), Ok(()));
        assert_eq!(
            check_release("ID=vrx\nSYSEXT_LEVEL=2\n"),
            Err(Refusal::Release)
        );
        assert_eq!(
            check_release("ID=fedora\nSYSEXT_LEVEL=1\n"),
            Err(Refusal::Release)
        );
        assert_eq!(check_release("ID=_any\n"), Err(Refusal::Release));
    }

    #[test]
    fn the_consent_matches_what_the_offer_would_do() {
        assert_eq!(kind_of(None, "1.2.0", "aa"), Kind::Install);
        assert_eq!(kind_of(Some(("1.2.0", "aa")), "1.2.0", "aa"), Kind::Same);
        assert_eq!(kind_of(Some(("1.2.0", "aa")), "1.3.0", "bb"), Kind::Update);
        assert_eq!(kind_of(Some(("1.2.0", "aa")), "1.2.0", "bb"), Kind::Replace);
        assert_eq!(kind_of(Some(("1.10.0", "aa")), "1.9.0", "bb"), Kind::Older);
        assert_eq!(version_cmp("1.10", "1.9"), std::cmp::Ordering::Greater);
        assert_eq!(version_cmp("1.0", "1"), std::cmp::Ordering::Equal);
    }

    #[test]
    fn an_installed_manifest_is_refused_authority_and_built_in_ids() {
        let mut registry = Registry::new();
        registry
            .admit(RegistryEntry {
                manifest: "[applet]\nid = \"clock\"\nname = \"Clock\"\nversion = \"1\"\nruntime = \"flutter\"\n"
                    .parse()
                    .unwrap(),
                path: "/system/defaults/clock".into(),
                builtin: true,
            })
            .unwrap();
        let m = |extra: &str, id: &str| -> Manifest {
            format!("[applet]\nid = \"{id}\"\nname = \"N\"\nversion = \"1\"\nruntime = \"flutter\"\n{extra}")
                .parse()
                .unwrap()
        };
        let dir = PathBuf::from("/usr/lib/vrx/apps/x");
        assert_eq!(
            check_manifest(&registry, &m("", "notes"), dir.clone()),
            Ok(())
        );
        assert_eq!(
            check_manifest(&registry, &m("", "clock"), dir.clone()),
            Err(Refusal::Builtin("clock".into()))
        );
        let network = m("[applet.permissions]\nsystem = [\"network\"]\n", "notes");
        assert!(matches!(
            check_manifest(&registry, &network, dir.clone()),
            Err(Refusal::Manifest(_))
        ));
        let home = m("[applet.roles]\nhome = true\n", "notes");
        assert!(matches!(
            check_manifest(&registry, &home, dir),
            Err(Refusal::Manifest(_))
        ));
    }

    #[test]
    fn the_systems_flutter_is_a_built_ins_bundle_folder() {
        let root = tempfile::tempdir().unwrap();
        assert_eq!(system_flutter(root.path()), None);
        std::fs::create_dir_all(root.path().join("clock/3.47.5/release/lib")).unwrap();
        std::fs::write(root.path().join("clock/3.47.5/release/lib/libapp.so"), "")
            .unwrap();
        std::fs::write(root.path().join("clock/manifest.toml"), "").unwrap();
        assert_eq!(system_flutter(root.path()), Some("3.47.5".into()));
    }
}
