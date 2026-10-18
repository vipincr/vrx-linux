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
//
// Signing (plan 0013 D3) is systemd's and the kernel's too. A release
// image ships a sysext.conf drop-in whose ImagePolicy= requires a signed
// image (dm-verity with a root hash signature the kernel verified against
// its built-in keyring); systemd-sysext enforces it when it merges, and
// every systemd-dissect here runs under the same policy, so an offer that
// would not merge is refused before it is copied. vrx adds only the
// sentence: "unsigned" when the image carries no signature at all,
// "untrusted" when it carries one the kernel refused. A debug image ships
// no drop-in and takes unsigned images, as the owner decided.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use vrx_protocol::sysext::{
    has_verity_signature, image_policy, installs_on, release_ok, release_path, APPS_DIR,
    INSTALL_CONF, SIGNED_DROPIN,
};
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
    #[error("unsigned: this image installs only signed applets, and it is not signed")]
    Unsigned,
    #[error("untrusted: its signature is not from a key this device trusts")]
    Untrusted,
    #[error("off: this image does not install applets")]
    Off,
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
            Refusal::Unsigned => "unsigned",
            Refusal::Untrusted => "untrusted",
            Refusal::Off => "off",
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

/// The install policy the image was built with (plan 0013 D3): whether it
/// installs at all (INSTALL_CONF, closed when absent) and the image policy
/// systemd-sysext merges under (SIGNED_DROPIN; None is systemd's default,
/// which also takes unsigned images).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Policy {
    pub installs: bool,
    pub image_policy: Option<String>,
}

impl Policy {
    /// Read from the system under `root` ("/" on the device).
    pub fn load(root: &Path) -> Self {
        let read =
            |p: &str| std::fs::read_to_string(root.join(p.trim_start_matches('/')));
        Self {
            installs: read(INSTALL_CONF).is_ok_and(|t| installs_on(&t)),
            image_policy: read(SIGNED_DROPIN).ok().and_then(|t| image_policy(&t)),
        }
    }

    /// The `--image-policy=` argument systemd-dissect runs with, if any.
    fn arg(&self) -> Option<String> {
        self.image_policy
            .as_ref()
            .map(|p| format!("--image-policy={p}"))
    }
}

/// Why systemd-dissect refused an image under a signing policy: a
/// signature the kernel did not trust, or no signature at all.
pub fn refusal_under_policy(signed: bool) -> Refusal {
    if signed {
        Refusal::Untrusted
    } else {
        Refusal::Unsigned
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
    /// Its signature was verified by the kernel against the key this
    /// image trusts (plan 0013 D3): true only under the signing policy,
    /// where nothing unverified gets this far. A debug image checks no
    /// signature, and says so.
    pub signed: bool,
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
        // a signature is the kernel's to verify against its built-in
        // keyring, never systemd's against certificates under /etc, which
        // root can write (plan 0013 D3)
        .env("SYSTEMD_ALLOW_USERSPACE_VERITY", "0")
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

/// A file inside an image, through `systemd-dissect --copy-from`, under
/// the image policy.
async fn read_inside(
    image: &Path,
    path: &str,
    policy: &Policy,
) -> Result<String, Refusal> {
    let tmp = std::env::temp_dir().join(format!(
        "vrx-inspect-{}-{}",
        std::process::id(),
        path.replace('/', "_")
    ));
    let _ = std::fs::remove_file(&tmp);
    let image = image.to_string_lossy();
    let tmp_arg = tmp.to_string_lossy();
    let policy_arg = policy.arg();
    let mut args: Vec<&str> = policy_arg.iter().map(String::as_str).collect();
    args.extend(["--copy-from", &image, path, &tmp_arg]);
    output("systemd-dissect", &args).await?;
    let text =
        std::fs::read_to_string(&tmp).map_err(|e| Refusal::Unreadable(e.to_string()));
    let _ = std::fs::remove_file(&tmp);
    text
}

/// The image's SHA-256.
pub async fn build_of(image: &Path) -> Result<String, Refusal> {
    // the cache: an unchanged image (path, size, mtime) hashed this run
    // is not hashed again (review 2026-10-17, ALG-02)
    let stat = std::fs::metadata(image).ok();
    let key = stat.as_ref().map(|m| {
        use std::os::unix::fs::MetadataExt;
        (image.to_path_buf(), m.size(), m.mtime() as u64)
    });
    if let Some(k) = &key {
        if let Ok(cache) = BUILD_CACHE.lock() {
            if let Some((_, _, _, build)) = cache.iter().find(|e| &e.0 == &k.0 && e.1 == k.1 && e.2 == k.2) {
                return Ok(build.clone());
            }
        }
    }
    let out = output("sha256sum", &[&image.to_string_lossy()]).await?;
    let build = out
        .split_whitespace()
        .next()
        .map(str::to_owned)
        .ok_or_else(|| Refusal::Unreadable("sha256sum said nothing".into()))?;
    if let Some(k) = key {
        if let Ok(mut cache) = BUILD_CACHE.lock() {
            cache.push((k.0, k.1, k.2, build.clone()));
        }
    }
    Ok(build)
}

/// The run's offer-build cache (see [build_of]).
pub static BUILD_CACHE: std::sync::Mutex<Vec<(PathBuf, u64, u64, String)>> =
    std::sync::Mutex::new(Vec::new());

/// Read an offer: its listing, its release file and its manifest, every
/// check but the registry's, all under the image policy.
pub async fn inspect(image: &Path, policy: &Policy) -> Result<Inspected, Refusal> {
    let file = image
        .file_name()
        .map(|f| f.to_string_lossy().into_owned())
        .unwrap_or_default();
    let id = id_of_file(&file).ok_or(Refusal::Name)?.to_owned();
    let image_arg = image.to_string_lossy();
    let policy_arg = policy.arg();
    let mut args: Vec<&str> = policy_arg.iter().map(String::as_str).collect();
    args.extend(["--list", &image_arg]);
    let listing = match output("systemd-dissect", &args).await {
        Ok(listing) => listing,
        // under a signing policy, a refusal is the signature's: say which
        Err(_) if policy.image_policy.is_some() => {
            let signed = std::fs::File::open(image)
                .map(|mut f| has_verity_signature(&mut f))
                .unwrap_or(false);
            return Err(refusal_under_policy(signed));
        }
        Err(other) => return Err(other),
    };
    let bundle = check_listing(&id, &listing)?;
    check_release(
        &read_inside(image, &format!("/{}", release_path(&id)), policy).await?,
    )?;
    let manifest: Manifest =
        read_inside(image, &format!("/{APPS_DIR}/{id}/manifest.toml"), policy)
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

pub(crate) fn atomic_write(path: &Path, text: &str) -> Result<(), String> {
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

/// Bring the USB drives' `apps/` offers into /var/lib/vrx/offers (and,
/// plan 0016 D11, their `updates/` bundles into /data/vrx/updates). One
/// scanner, two sources (plan 0019 D9): the board's own gadget image,
/// read with `systemd-dissect --copy-from` only while nothing shares it,
/// and every drive plugged into the board, mounted read-only under
/// /run/vrx/usb. A stick adds bytes and no trust: the signature is
/// checked at install, as for any offer.
pub async fn import_drive(drive_idle: bool) {
    import_drive_folder("/apps", Path::new(OFFERS), drive_idle, |n| {
        id_of_file(n).is_some()
    })
    .await;
}

/// Where a drive's files come from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Source {
    /// The board's own USB drive image (the gadget's, plan 0008 Part G).
    Gadget(PathBuf),
    /// A drive plugged into the board, mounted at this directory.
    Mounted(PathBuf),
}

/// The sources to read now: the gadget's image when nothing shares it,
/// then every mounted drive under `mounts`, in order.
pub fn sources(drive_idle: bool, image: &Path, mounts: &Path) -> Vec<Source> {
    let mut out = Vec::new();
    if drive_idle && image.exists() {
        out.push(Source::Gadget(image.to_path_buf()));
    }
    let mut mounted: Vec<PathBuf> = std::fs::read_dir(mounts)
        .map(|d| {
            d.flatten()
                .map(|e| e.path())
                .filter(|p| {
                    p.file_name()
                        .and_then(|n| n.to_str())
                        .is_some_and(|n| crate::usb::device_of_mount(n).is_some())
                })
                .collect()
        })
        .unwrap_or_default();
    mounted.sort();
    out.extend(mounted.into_iter().map(Source::Mounted));
    out
}

/// The largest file taken from a drive: a root slot's size (plan 0016,
/// 3 GiB); an update bundle is smaller than its slot.
pub const MAX_DRIVE_FILE: u64 = 3 << 30;

/// `folder` on every drive into `dest`, keeping the names `accept` takes.
pub async fn import_drive_folder(
    folder: &str,
    dest: &Path,
    drive_idle: bool,
    accept: impl Fn(&str) -> bool,
) {
    for source in sources(
        drive_idle,
        Path::new(DRIVE),
        Path::new(crate::usb::MOUNT_ROOT),
    ) {
        import_from(&source, folder, dest, &accept, MAX_DRIVE_FILE).await;
    }
}

/// `folder` on one drive into `dest`. Everything lands in `dest/.drive`
/// first and only a complete copy is renamed into place, so a copy that
/// fails halfway (a stick pulled) leaves no offer and no landing behind.
pub async fn import_from(
    source: &Source,
    folder: &str,
    dest: &Path,
    accept: &impl Fn(&str) -> bool,
    max_bytes: u64,
) {
    // CON-01 (review 2026-10-17): the drive import admits against the same
    // /data headroom the manage upload does — one writer protecting the
    // space and the other filling it to the brim was the finding.
    if let Ok(out) = tokio::process::Command::new("df")
        .args(["-kP", &dest.to_string_lossy()])
        .output()
        .await
    {
        // "Filesystem 1024-blocks Used Available ..." — the one number
        let text = String::from_utf8_lossy(&out.stdout);
        if let Some(avail_kb) = text
            .lines()
            .nth(1)
            .and_then(|l| l.split_whitespace().nth(3))
            .and_then(|v| v.parse::<u64>().ok())
        {
            if avail_kb * 1024 < crate::update::UPDATES_MIN_FREE {
                tracing::warn!(
                    avail_kb,
                    min_kb = crate::update::UPDATES_MIN_FREE / 1024,
                    "drive import skipped: /data's headroom comes first"
                );
                return;
            }
        }
    }
    let landing = dest.join(".drive");
    let _ = std::fs::remove_dir_all(&landing);
    let copied = match source {
        Source::Gadget(image) => output(
            "systemd-dissect",
            &[
                "--copy-from",
                &image.to_string_lossy(),
                folder,
                &landing.to_string_lossy(),
            ],
        )
        .await
        .map(drop)
        .map_err(|e| e.to_string()),
        Source::Mounted(root) => {
            copy_folder(
                &root.join(folder.trim_start_matches('/')),
                &landing,
                accept,
                max_bytes,
            )
            .await
        }
    };
    match copied {
        Ok(()) => {
            if let Ok(entries) = std::fs::read_dir(&landing) {
                for entry in entries.flatten() {
                    let name = entry.file_name().to_string_lossy().into_owned();
                    if accept(&name) {
                        let _ = std::fs::rename(entry.path(), dest.join(&name));
                    }
                }
            }
        }
        // no such folder on the drive, or the copy failed: nothing lands
        Err(err) => tracing::debug!(?source, folder, %err, "drive: nothing imported"),
    }
    let _ = std::fs::remove_dir_all(&landing);
}

/// The regular files in `src` that `accept` takes and are at most
/// `max_bytes`, copied into `landing`. A folder that is missing (or a
/// file where the folder belongs) has nothing to copy; links, folders and
/// devices inside it are skipped; a read that fails ends the copy with
/// the error.
pub async fn copy_folder(
    src: &Path,
    landing: &Path,
    accept: &impl Fn(&str) -> bool,
    max_bytes: u64,
) -> Result<(), String> {
    let Ok(entries) = std::fs::read_dir(src) else {
        return Ok(());
    };
    std::fs::create_dir_all(landing).map_err(|e| e.to_string())?;
    for entry in entries {
        let entry = entry.map_err(|e| e.to_string())?;
        let Some(name) = entry.file_name().to_str().map(str::to_owned) else {
            continue;
        };
        if !accept(&name) {
            continue;
        }
        let meta = std::fs::symlink_metadata(entry.path()).map_err(|e| e.to_string())?;
        if !meta.file_type().is_file() || meta.len() > max_bytes {
            tracing::info!(%name, bytes = meta.len(), "drive: not a file this takes");
            continue;
        }
        tokio::fs::copy(entry.path(), landing.join(&name))
            .await
            .map_err(|e| format!("{name}: {e}"))?;
    }
    Ok(())
}

/// Every offer waiting, read and checked against the registry. An image
/// built without installs offers nothing.
pub async fn offers(registry: &Registry, defaults: &Path, policy: &Policy) -> Vec<Offer> {
    if !policy.installs {
        return Vec::new();
    }
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
            signed: false,
        };
        match check_offer(registry, &path, flutter.as_deref(), policy).await {
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
                offer.signed = policy.image_policy.is_some();
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
    policy: &Policy,
) -> Result<Inspected, Refusal> {
    if !policy.installs {
        return Err(Refusal::Off);
    }
    let inspected = inspect(image, policy).await?;
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

/// The privileged half of installing. vrxhost runs sandboxed (no
/// capabilities, a read-only system but /run/vrx), and the work here
/// cannot: systemd-dissect needs a mount namespace and loop devices, the
/// copy writes /var/lib/extensions and /etc/systemd/system. So it runs in
/// vrx-install.service, this same binary (`vrxhost install-helper`),
/// started by the daemon over D-Bus for each call, the request and its
/// outcome in HELPER_DIR. The daemon keeps the consent's caller check,
/// the merge (systemd-sysext's Varlink socket merges in the system's
/// mount namespace; a refresh inside this unit's would merge only there),
/// the reload and the registry.
pub const HELPER_UNIT: &str = "vrx-install.service";
pub const HELPER_DIR: &str = "/run/vrx/install";

/// One call to the helper.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "lowercase")]
pub enum Request {
    /// The offers waiting; the USB drive's apps/ read in first when
    /// nothing shares the drive.
    Offers { drive_idle: bool },
    /// Copy an agreed offer in: check it, write its drop-in, stage it.
    Install { file: String, build: String },
    /// Delete an installed applet's image, drop-in, state and settings.
    Uninstall { applet: String },
    /// The USB drives' `updates/` bundles into /data/vrx/updates (plan
    /// 0016 D11); the gadget's image only when nothing shares it.
    ImportUpdates { drive_idle: bool },
    /// A drive was mounted (plan 0019 D9): both folders from every drive,
    /// so the offer and the bundle wait before anyone opens a screen.
    Import { drive_idle: bool },
}

/// A refusal as the daemon replies it: an io.vrx.Host error and its
/// parameters.
fn refused(error: &str, parameters: serde_json::Value) -> serde_json::Value {
    serde_json::json!({ "error": error, "parameters": parameters })
}

/// Carry out `request` against the system's registry.
pub async fn helper(
    paths: &crate::paths::VrxPaths,
    request: Request,
) -> serde_json::Value {
    use serde_json::json;
    let policy = Policy::load(Path::new("/"));
    let registry = match crate::registry::scan(paths) {
        Ok(r) => r,
        Err(err) => {
            return refused(
                "InstallFailed",
                json!({ "applet": "", "detail": err.to_string() }),
            )
        }
    };
    match request {
        Request::ImportUpdates { drive_idle } => {
            import_updates(drive_idle).await;
            json!({})
        }
        Request::Import { drive_idle } => {
            if policy.installs {
                import_drive(drive_idle).await;
            }
            import_updates(drive_idle).await;
            json!({})
        }
        Request::Offers { drive_idle } => {
            import_drive(drive_idle).await;
            json!({ "offers": offers(&registry, &paths.system_defaults, &policy).await })
        }
        Request::Install { file, build } => {
            if id_of_file(&file).is_none() {
                return refused(
                    "OfferRefused",
                    json!({ "file": file, "reason": "name" }),
                );
            }
            let image = Path::new(OFFERS).join(&file);
            let flutter = system_flutter(&paths.system_defaults);
            let inspected =
                match check_offer(&registry, &image, flutter.as_deref(), &policy).await {
                    Ok(i) => i,
                    Err(r) => {
                        tracing::warn!(%file, reason = %r, "install refused");
                        return refused(
                            "OfferRefused",
                            json!({ "file": file, "reason": r.key() }),
                        );
                    }
                };
            if inspected.build != build {
                return refused("OfferChanged", json!({ "file": file }));
            }
            let id = inspected.manifest.applet.id.clone();
            // CON-05 (review 2026-10-17): one transaction. The image is
            // copied and hashed FIRST, the drop-in (the thing systemd and
            // Settings read) goes LAST — a failure anywhere before it
            // leaves the previous applet whole. The old order wrote the
            // drop-in before staging, so a failed copy left a unit for an
            // applet whose image was not there.
            let staged = async {
                stage(&image, &id).await?;
                write_unit(&inspected)
            };
            if let Err(detail) = staged.await {
                // undo the half that landed: no image, no drop-in
                let _ = std::fs::remove_file(Path::new(EXTENSIONS).join(format!("{id}.raw")));
                let _ = std::fs::remove_file(dropin_path(&id));
                return refused(
                    "InstallFailed",
                    json!({ "applet": id, "detail": detail }),
                );
            }
            let _ = std::fs::remove_file(&image);
            json!({ "id": id, "version": inspected.manifest.applet.version })
        }
        Request::Uninstall { applet } => {
            if registry.find(&applet).is_none_or(|e| e.builtin) {
                return refused("NotInstalled", json!({ "applet": applet }));
            }
            match remove(&applet) {
                Ok(()) => json!({}),
                Err(detail) => refused(
                    "InstallFailed",
                    json!({ "applet": applet, "detail": detail }),
                ),
            }
        }
    }
}

/// The drives' `updates/` bundles into /data/vrx/updates.
async fn import_updates(drive_idle: bool) {
    let dest = Path::new(crate::update::UPDATES);
    let _ = std::fs::create_dir_all(dest);
    import_drive_folder("/updates", dest, drive_idle, crate::update::bundle_name_ok)
        .await;
}

/// `vrxhost install-helper`: read the request, write the outcome.
pub async fn helper_main(paths: &crate::paths::VrxPaths) -> bool {
    let dir = Path::new(HELPER_DIR);
    let request: Request = match std::fs::read_to_string(dir.join("request.json"))
        .map_err(|e| e.to_string())
        .and_then(|t| serde_json::from_str(&t).map_err(|e| e.to_string()))
    {
        Ok(r) => r,
        Err(err) => {
            tracing::error!(error = %err, "install helper: no request");
            return false;
        }
    };
    let outcome = helper(paths, request).await;
    atomic_write(&dir.join("result.json"), &outcome.to_string())
        .map_err(|err| tracing::error!(error = %err, "install helper: no result"))
        .is_ok()
}

/// Remove installed applet `id`: its image, drop-in, state, cache and
/// settings. The caller stops its unit first and refreshes after.
pub fn remove(id: &str) -> Result<(), String> {
    // every path is tried: one that cannot go must not leave the rest
    // (the image above all) behind; the first failure is reported
    let mut first = None;
    let mut note = |r: Result<(), String>| {
        if let Err(e) = r {
            first.get_or_insert(e);
        }
    };
    let gone = |p: PathBuf| match std::fs::remove_file(&p) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(format!("{}: {e}", p.display())),
    };
    note(gone(Path::new(EXTENSIONS).join(format!("{id}.raw"))));
    note(gone(dropin_path(id)));
    note(gone(PathBuf::from(format!("/etc/vrx/settings/{id}.conf"))));
    for dir in [
        format!("/var/lib/private/vrx/{id}"),
        format!("/var/cache/private/vrx/{id}"),
    ] {
        note(match std::fs::remove_dir_all(&dir) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(format!("{dir}: {e}")),
        });
    }
    first.map_or(Ok(()), Err)
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

    /// Plan 0013 D3: installs are closed unless the image says yes, and the
    /// image policy is the release drop-in's when it ships one.
    #[test]
    fn the_install_policy_is_read_from_the_image() {
        let root = tempfile::tempdir().unwrap();
        assert_eq!(Policy::load(root.path()), Policy::default());
        let conf = root.path().join(INSTALL_CONF.trim_start_matches('/'));
        std::fs::create_dir_all(conf.parent().unwrap()).unwrap();
        std::fs::write(&conf, "installs=yes\n").unwrap();
        let debug = Policy::load(root.path());
        assert!(debug.installs);
        assert_eq!(debug.image_policy, None);
        assert_eq!(debug.arg(), None);
        let dropin = root.path().join(SIGNED_DROPIN.trim_start_matches('/'));
        std::fs::create_dir_all(dropin.parent().unwrap()).unwrap();
        std::fs::write(
            &dropin,
            include_str!("../../../layer/recipes-core/vrxhost/files/50-vrx-signed.conf"),
        )
        .unwrap();
        let release = Policy::load(root.path());
        assert_eq!(
            release.arg().as_deref(),
            Some("--image-policy=root=signed+absent:usr=signed+absent:=ignore")
        );
        std::fs::write(&conf, "installs=no\n").unwrap();
        assert!(!Policy::load(root.path()).installs);
    }

    #[test]
    fn a_refusal_under_a_signing_policy_names_the_signature() {
        assert_eq!(refusal_under_policy(false), Refusal::Unsigned);
        assert_eq!(refusal_under_policy(true), Refusal::Untrusted);
        assert_eq!(Refusal::Unsigned.key(), "unsigned");
        assert_eq!(Refusal::Untrusted.key(), "untrusted");
        assert_eq!(Refusal::Off.key(), "off");
    }

    #[tokio::test]
    async fn an_image_built_without_installs_offers_and_installs_nothing() {
        let off = Policy::default();
        assert!(offers(&Registry::new(), Path::new("/nonexistent"), &off)
            .await
            .is_empty());
        assert!(matches!(
            check_offer(&Registry::new(), Path::new("/x/notes.raw"), None, &off).await,
            Err(Refusal::Off)
        ));
    }

    #[test]
    fn a_helper_request_is_one_json_object_per_operation() {
        let r = Request::Install {
            file: "notes.raw".into(),
            build: "ab".into(),
        };
        let text = serde_json::to_string(&r).unwrap();
        assert_eq!(text, r#"{"op":"install","file":"notes.raw","build":"ab"}"#);
        assert_eq!(serde_json::from_str::<Request>(&text).unwrap(), r);
        assert_eq!(
            serde_json::from_str::<Request>(r#"{"op":"offers","drive_idle":true}"#)
                .unwrap(),
            Request::Offers { drive_idle: true }
        );
        assert_eq!(
            serde_json::from_str::<Request>(r#"{"op":"import","drive_idle":false}"#)
                .unwrap(),
            Request::Import { drive_idle: false }
        );
    }

    // ── a stick as a source (plan 0019 D9, Part E 6) ──

    fn stick() -> (tempfile::TempDir, PathBuf, PathBuf) {
        let dir = tempfile::tempdir().unwrap();
        let mount = dir.path().join("usb/1-1.2-p1");
        let dest = dir.path().join("offers");
        std::fs::create_dir_all(mount.join("apps")).unwrap();
        std::fs::create_dir_all(&dest).unwrap();
        (dir, mount, dest)
    }

    fn names(dir: &Path) -> Vec<String> {
        let mut n: Vec<String> = std::fs::read_dir(dir)
            .unwrap()
            .flatten()
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .collect();
        n.sort();
        n
    }

    fn takes(n: &str) -> bool {
        id_of_file(n).is_some()
    }

    #[tokio::test]
    async fn a_sticks_offers_land_and_nothing_else_does() {
        let (_dir, mount, dest) = stick();
        let apps = mount.join("apps");
        std::fs::write(apps.join("notes.raw"), b"image").unwrap();
        std::fs::write(apps.join("README.txt"), b"x").unwrap();
        std::fs::write(apps.join(format!("{}.raw", "a".repeat(40))), b"x").unwrap(); // name over 32
        std::fs::create_dir(apps.join("folder.raw")).unwrap();
        #[cfg(unix)]
        std::os::unix::fs::symlink("/etc/passwd", apps.join("linked.raw")).unwrap();
        std::fs::write(apps.join("big.raw"), vec![0u8; 2048]).unwrap();
        import_from(
            &Source::Mounted(mount.clone()),
            "/apps",
            &dest,
            &takes,
            1024,
        )
        .await;
        assert_eq!(
            names(&dest),
            vec!["notes.raw"],
            "only a regular file, named right, under the cap"
        );
        assert_eq!(std::fs::read(dest.join("notes.raw")).unwrap(), b"image");
        assert!(!dest.join(".drive").exists(), "the landing is gone");
        // a name with a path in it never passes the filter
        assert!(!takes("../x.raw") && !takes("a/b.raw") && !takes(".raw"));
    }

    #[tokio::test]
    async fn a_missing_folder_or_a_file_in_its_place_imports_nothing() {
        let (_dir, mount, dest) = stick();
        import_from(
            &Source::Mounted(mount.clone()),
            "/updates",
            &dest,
            &takes,
            MAX_DRIVE_FILE,
        )
        .await;
        std::fs::remove_dir_all(mount.join("apps")).unwrap();
        std::fs::write(mount.join("apps"), b"not a folder").unwrap();
        import_from(
            &Source::Mounted(mount),
            "/apps",
            &dest,
            &takes,
            MAX_DRIVE_FILE,
        )
        .await;
        assert!(names(&dest).is_empty());
    }

    /// A stick pulled mid-copy: one file read, the next fails. Nothing is
    /// offered and no landing is left (the copy is all or nothing).
    #[cfg(unix)]
    #[tokio::test]
    async fn a_copy_that_fails_halfway_leaves_no_offer_and_no_landing() {
        use std::os::unix::fs::PermissionsExt;
        let (_dir, mount, dest) = stick();
        let apps = mount.join("apps");
        std::fs::write(apps.join("aaa.raw"), b"first").unwrap();
        std::fs::write(apps.join("zzz.raw"), b"second").unwrap();
        std::fs::write(apps.join("mmm.raw"), b"third").unwrap();
        std::fs::set_permissions(
            apps.join("mmm.raw"),
            std::fs::Permissions::from_mode(0o000),
        )
        .unwrap();
        if std::fs::read(apps.join("mmm.raw")).is_ok() {
            return; // running as root: the failure cannot be staged
        }
        import_from(
            &Source::Mounted(mount),
            "/apps",
            &dest,
            &takes,
            MAX_DRIVE_FILE,
        )
        .await;
        assert!(names(&dest).is_empty(), "{:?}", names(&dest));
    }

    #[test]
    fn the_sources_are_the_idle_gadget_then_each_mounted_drive() {
        let dir = tempfile::tempdir().unwrap();
        let image = dir.path().join("files.img");
        let mounts = dir.path().join("usb");
        for m in ["1-1.3-p1", "1-1.2-p2", "STICK", "1-1.2-p1"] {
            std::fs::create_dir_all(mounts.join(m)).unwrap();
        }
        let mounted = |n: &str| Source::Mounted(mounts.join(n));
        assert_eq!(
            sources(true, &image, &mounts),
            vec![
                mounted("1-1.2-p1"),
                mounted("1-1.2-p2"),
                mounted("1-1.3-p1")
            ],
            "no image, and a label is not a drive's name"
        );
        std::fs::write(&image, b"").unwrap();
        assert_eq!(
            sources(true, &image, &mounts)[0],
            Source::Gadget(image.clone())
        );
        assert_eq!(
            sources(false, &image, &mounts).len(),
            3,
            "a shared gadget is not read"
        );
        assert!(sources(false, &image, &dir.path().join("none")).is_empty());
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
