// Software update (plan 0016): a signed RAUC bundle installed into the
// slot that is not running, a trial boot of it, and the person's view of
// both. RAUC does the work that needs privilege (D1): it checks the
// bundle's signature and machine, writes the other slot and keeps the
// slots' status; vrxhost asks it over D-Bus and adds what RAUC has no
// notion of: where bundles are offered from (D11), the release image's
// refusal of an older version (D7, beside RAUC's own pre-install
// handler), the trial reboot through logind with the board's restart
// argument (D2), and the sentence after a fall-back.
//
// The board says how its trial boot is asked for in
// /usr/lib/vrx/update.conf (written by its layer):
//   reboot-parameter=0 tryboot     the Pi firmware's one-shot boot
//   downgrades=yes|no              no on release images
// An image without the file has no updates: every method answers
// Unavailable.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use serde::Serialize;
use serde_json::{json, Value};
use zbus::zvariant::{OwnedValue, Value as ZValue};
use zbus::{proxy, Connection};

/// Bundles offered: uploads from the Manage page and the USB drive's
/// `updates/` folder land here (D11).
pub const UPDATES: &str = "/data/vrx/updates";
/// vrxhost's record of a trial it asked for, to tell a fall-back.
pub const STATE: &str = "/data/vrx/update";
/// The board's update settings.
pub const CONF: &str = "/usr/lib/vrx/update.conf";
/// The shell's first frame is on the panel (the health target waits on it, D6).
pub const SHELL_SHOWN: &str = "/run/vrx/shell-shown";
/// The board's trial test: exits 0 on a boot that is a trial (D6).
pub const TRIAL: &str = "/usr/lib/vrx/update/trial";

/// The board's update settings.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Conf {
    pub reboot_parameter: String,
    pub downgrades: bool,
}

pub fn parse_conf(text: &str) -> Conf {
    let mut conf = Conf {
        reboot_parameter: String::new(),
        downgrades: false,
    };
    for line in text.lines() {
        let line = line.split('#').next().unwrap_or("").trim();
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        match key.trim() {
            "reboot-parameter" => conf.reboot_parameter = value.trim().to_owned(),
            "downgrades" => conf.downgrades = value.trim() == "yes",
            _ => {}
        }
    }
    conf
}

pub fn load_conf() -> Option<Conf> {
    std::fs::read_to_string(CONF).ok().map(|t| parse_conf(&t))
}

/// Record that the shell's first frame is up (once per boot).
pub fn shell_shown() {
    if !Path::new(SHELL_SHOWN).exists() {
        if let Err(err) = std::fs::write(SHELL_SHOWN, "") {
            tracing::warn!(error = %err, "cannot record the shell's first frame");
        } else {
            tracing::info!("the shell's first frame is up (update health)");
        }
    }
}

/// The running image's version (`VERSION_ID`).
pub fn running_version(os_release: &str) -> String {
    os_release
        .lines()
        .find_map(|l| l.strip_prefix("VERSION_ID="))
        .map(|v| v.trim_matches('"').to_owned())
        .unwrap_or_default()
}

/// Why an offered bundle cannot be installed, if it cannot: another
/// machine's, an older version where downgrades are refused (G049), or
/// the version already running. RAUC's own checks (signature, format)
/// come first and travel as "unsigned" or "unreadable".
pub fn judge(
    version: &str,
    compatible: &str,
    running: &str,
    machine: &str,
    downgrades: bool,
) -> Option<&'static str> {
    if !machine.is_empty() && compatible != machine {
        return Some("machine");
    }
    match crate::install::version_cmp(version, running) {
        std::cmp::Ordering::Equal => Some("same"),
        std::cmp::Ordering::Less if !downgrades => Some("older"),
        _ => None,
    }
}

/// A bundle file's name: letters, digits, `.`, `_`, `-`, ending `.raucb`.
pub fn bundle_name_ok(name: &str) -> bool {
    name.len() <= 96
        && name.ends_with(".raucb")
        && !name.starts_with('.')
        && name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'_' || b == b'-')
}

/// RAUC's errors as one word each (the kit's words table has a sentence
/// for every one).
pub fn reason_of_rauc_error(message: &str) -> &'static str {
    let m = message.to_ascii_lowercase();
    if m.contains("signature") || m.contains("verify") || m.contains("cms") {
        "unsigned"
    } else if m.contains("compatible") {
        "machine"
    } else if m.contains("plain") || m.contains("format") {
        "unsigned"
    } else if m.contains("space") {
        "space"
    } else {
        "unreadable"
    }
}

#[proxy(
    interface = "de.pengutronix.rauc.Installer",
    default_service = "de.pengutronix.rauc",
    default_path = "/"
)]
trait Installer {
    fn inspect_bundle(
        &self,
        source: &str,
        args: HashMap<&str, ZValue<'_>>,
    ) -> zbus::Result<HashMap<String, OwnedValue>>;
    fn install_bundle(
        &self,
        source: &str,
        args: HashMap<&str, ZValue<'_>>,
    ) -> zbus::Result<()>;
    fn get_slot_status(&self)
        -> zbus::Result<Vec<(String, HashMap<String, OwnedValue>)>>;
    fn get_primary(&self) -> zbus::Result<String>;
    #[zbus(signal)]
    fn completed(&self, result: i32) -> zbus::Result<()>;
    #[zbus(property)]
    fn last_error(&self) -> zbus::Result<String>;
    #[zbus(property)]
    fn boot_slot(&self) -> zbus::Result<String>;
    #[zbus(property)]
    fn compatible(&self) -> zbus::Result<String>;
}

#[proxy(
    interface = "org.freedesktop.login1.Manager",
    default_service = "org.freedesktop.login1",
    default_path = "/org/freedesktop/login1"
)]
trait Login {
    fn set_reboot_parameter(&self, parameter: &str) -> zbus::Result<()>;
    fn reboot(&self, interactive: bool) -> zbus::Result<()>;
}

fn string_of(map: &HashMap<String, OwnedValue>, key: &str) -> Option<String> {
    map.get(key)
        .and_then(|v| String::try_from(v.try_clone().ok()?).ok())
}

/// InspectBundle's answer: compatible and version at the top (older RAUC)
/// or under "update" (1.11 and later).
fn compatible_and_version(info: &HashMap<String, OwnedValue>) -> (String, String) {
    if let (Some(c), Some(v)) =
        (string_of(info, "compatible"), string_of(info, "version"))
    {
        return (c, v);
    }
    let nested: Option<HashMap<String, OwnedValue>> = info
        .get("update")
        .and_then(|v| HashMap::<String, OwnedValue>::try_from(v.try_clone().ok()?).ok());
    match nested {
        Some(u) => (
            string_of(&u, "compatible").unwrap_or_default(),
            string_of(&u, "version").unwrap_or_default(),
        ),
        None => (String::new(), String::new()),
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct Offer {
    pub file: String,
    pub version: String,
    pub compatible: String,
    pub problem: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct Slot {
    pub name: String,
    pub bootname: String,
    pub state: String,
    pub boot_status: String,
    pub version: String,
}

fn unavailable() -> (String, Value) {
    ("Unavailable".to_owned(), json!({}))
}

async fn rauc() -> Result<InstallerProxy<'static>, (String, Value)> {
    let conn = Connection::system().await.map_err(|e| {
        tracing::error!(error = %e, "update: no system bus");
        unavailable()
    })?;
    InstallerProxy::new(&conn).await.map_err(|e| {
        tracing::error!(error = %e, "update: RAUC is not reachable");
        unavailable()
    })
}

/// The bundles offered, each inspected by RAUC (which checks the
/// signature) and judged against the running image.
pub async fn offers() -> Result<Value, (String, Value)> {
    let conf = load_conf().ok_or_else(unavailable)?;
    let rauc = rauc().await?;
    let running =
        running_version(&std::fs::read_to_string("/etc/os-release").unwrap_or_default());
    // RAUC's own compatible (system.conf's: the machine and its carrier)
    let machine = rauc.compatible().await.unwrap_or_default();
    let mut files: Vec<PathBuf> = std::fs::read_dir(UPDATES)
        .map(|d| d.flatten().map(|e| e.path()).collect())
        .unwrap_or_default();
    files.sort();
    let mut out = Vec::new();
    for path in files {
        let name = path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();
        if !bundle_name_ok(&name) {
            continue;
        }
        let offer = match rauc
            .inspect_bundle(&path.to_string_lossy(), HashMap::new())
            .await
        {
            Ok(info) => {
                let (compatible, version) = compatible_and_version(&info);
                let problem =
                    judge(&version, &compatible, &running, &machine, conf.downgrades)
                        .map(str::to_owned);
                Offer {
                    file: name,
                    version,
                    compatible,
                    problem,
                }
            }
            Err(e) => Offer {
                file: name,
                version: String::new(),
                compatible: String::new(),
                problem: Some(reason_of_rauc_error(&e.to_string()).to_owned()),
            },
        };
        out.push(offer);
    }
    Ok(json!({ "running": running, "offers": out }))
}

/// Install an offered bundle into the other slot; the reboot waits for
/// the person (`restart`). The file must still judge installable.
pub async fn install(file: &str) -> Result<Value, (String, Value)> {
    if !bundle_name_ok(file) {
        return Err((
            "UpdateRefused".to_owned(),
            json!({ "file": file, "reason": "name" }),
        ));
    }
    let listed = offers().await?;
    let offer = listed["offers"]
        .as_array()
        .and_then(|a| a.iter().find(|o| o["file"] == file).cloned())
        .ok_or_else(|| {
            (
                "UpdateRefused".to_owned(),
                json!({ "file": file, "reason": "gone" }),
            )
        })?;
    if let Some(reason) = offer["problem"].as_str() {
        return Err((
            "UpdateRefused".to_owned(),
            json!({ "file": file, "reason": reason }),
        ));
    }
    let rauc = rauc().await?;
    let mut completed = rauc.receive_completed().await.map_err(|e| {
        (
            "UpdateFailed".to_owned(),
            json!({ "file": file, "detail": e.to_string() }),
        )
    })?;
    let path = Path::new(UPDATES).join(file);
    rauc.install_bundle(&path.to_string_lossy(), HashMap::new())
        .await
        .map_err(|e| {
            (
                "UpdateFailed".to_owned(),
                json!({ "file": file, "detail": e.to_string() }),
            )
        })?;
    use futures_util::StreamExt;
    let result = match completed.next().await {
        Some(signal) => signal.args().map(|a| a.result).unwrap_or(1),
        None => 1,
    };
    if result != 0 {
        let detail = rauc.last_error().await.unwrap_or_default();
        tracing::error!(%file, %detail, "update install failed");
        return Err((
            "UpdateFailed".to_owned(),
            json!({ "file": file, "reason": reason_of_rauc_error(&detail), "detail": detail }),
        ));
    }
    let version = offer["version"].as_str().unwrap_or_default().to_owned();
    let _ = std::fs::remove_file(&path);
    tracing::info!(%file, %version, "update installed into the other slot");
    Ok(json!({ "version": version }))
}

/// Restart into the newly installed slot on trial: record what was asked
/// (to tell a fall-back after), then logind's reboot with the board's
/// restart argument (`0 tryboot` on the Pis).
pub async fn restart() -> Result<Value, (String, Value)> {
    let conf = load_conf().ok_or_else(unavailable)?;
    let rauc = rauc().await?;
    let booted = rauc.boot_slot().await.unwrap_or_default();
    let _ = std::fs::create_dir_all(STATE);
    let record = json!({ "from": booted }).to_string();
    crate::install::atomic_write(&Path::new(STATE).join("pending.json"), &record)
        .map_err(|e| {
            (
                "UpdateFailed".to_owned(),
                json!({ "file": "", "detail": e }),
            )
        })?;
    let conn = Connection::system().await.map_err(|_| unavailable())?;
    let login = LoginProxy::new(&conn).await.map_err(|_| unavailable())?;
    if !conf.reboot_parameter.is_empty() {
        login
            .set_reboot_parameter(&conf.reboot_parameter)
            .await
            .map_err(|e| {
                (
                    "UpdateFailed".to_owned(),
                    json!({ "file": "", "detail": e.to_string() }),
                )
            })?;
    }
    tracing::info!(from = %booted, parameter = %conf.reboot_parameter, "restarting into the updated slot on trial");
    login.reboot(false).await.map_err(|e| {
        (
            "UpdateFailed".to_owned(),
            json!({ "file": "", "detail": e.to_string() }),
        )
    })?;
    Ok(json!({}))
}

/// What a pending record and this boot say: still on trial, kept, or
/// fallen back to the slot it came from.
pub fn outcome(pending_from: Option<&str>, booted: &str, on_trial: bool) -> &'static str {
    match pending_from {
        None => "none",
        Some(_) if on_trial => "trial",
        Some(from) if from == booted => "fell-back",
        Some(_) => "kept",
    }
}

/// The running version, the slots and the last update's outcome.
pub async fn status() -> Result<Value, (String, Value)> {
    load_conf().ok_or_else(unavailable)?;
    let rauc = rauc().await?;
    let booted = rauc.boot_slot().await.unwrap_or_default();
    let mut slots = Vec::new();
    for (name, info) in rauc.get_slot_status().await.unwrap_or_default() {
        if string_of(&info, "class").as_deref() != Some("rootfs") {
            continue;
        }
        slots.push(Slot {
            name,
            bootname: string_of(&info, "bootname").unwrap_or_default(),
            state: string_of(&info, "state").unwrap_or_default(),
            boot_status: string_of(&info, "boot-status").unwrap_or_default(),
            version: string_of(&info, "bundle.version").unwrap_or_default(),
        });
    }
    // a trial boot stays one until the booted slot is made primary (RAUC's
    // mark-good, D6); the firmware's flag says trial for the whole boot
    let firmware_trial = tokio::process::Command::new(TRIAL)
        .status()
        .await
        .is_ok_and(|s| s.success());
    let primary = rauc.get_primary().await.ok();
    let primary_bootname = slots
        .iter()
        .find(|s| Some(&s.name) == primary.as_ref())
        .map(|s| s.bootname.clone());
    let on_trial = firmware_trial && primary_bootname.as_deref() != Some(booted.as_str());
    let pending_path = Path::new(STATE).join("pending.json");
    let pending: Option<String> = std::fs::read_to_string(&pending_path)
        .ok()
        .and_then(|t| serde_json::from_str::<Value>(&t).ok())
        .and_then(|v| v["from"].as_str().map(str::to_owned));
    let last = outcome(pending.as_deref(), &booted, on_trial);
    // a kept slot needs no record any more; a fall-back is said until the
    // next install
    if last == "kept" {
        let _ = std::fs::remove_file(&pending_path);
    }
    let running =
        running_version(&std::fs::read_to_string("/etc/os-release").unwrap_or_default());
    Ok(json!({
        "running": running,
        "booted": booted,
        "trial": on_trial,
        "last": last,
        "slots": slots,
    }))
}

/// A new install clears a past fall-back's sentence.
pub fn clear_fallback() {
    let _ = std::fs::remove_file(Path::new(STATE).join("pending.json"));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_board_says_how_a_trial_is_asked_for() {
        let c = parse_conf("# pi\nreboot-parameter=0 tryboot\ndowngrades=no\n");
        assert_eq!(c.reboot_parameter, "0 tryboot");
        assert!(!c.downgrades);
        assert!(parse_conf("downgrades=yes").downgrades);
        assert_eq!(parse_conf("").reboot_parameter, "");
    }

    #[test]
    fn a_release_image_refuses_an_older_bundle_and_another_machines() {
        assert_eq!(
            judge(
                "0.1.0099",
                "vrxboard-cm4",
                "0.1.0100",
                "vrxboard-cm4",
                false
            ),
            Some("older")
        );
        assert_eq!(
            judge("0.1.0099", "vrxboard-cm4", "0.1.0100", "vrxboard-cm4", true),
            None
        );
        assert_eq!(
            judge(
                "0.1.0101",
                "vrxboard-cm5",
                "0.1.0100",
                "vrxboard-cm4",
                false
            ),
            Some("machine")
        );
        assert_eq!(
            judge(
                "0.1.0100",
                "vrxboard-cm4",
                "0.1.0100",
                "vrxboard-cm4",
                false
            ),
            Some("same")
        );
        assert_eq!(
            judge(
                "0.1.0101",
                "vrxboard-cm4",
                "0.1.0100",
                "vrxboard-cm4",
                false
            ),
            None
        );
    }

    #[test]
    fn bundle_names_are_plain() {
        assert!(bundle_name_ok("vrx-bundle-vrxboard-cm4-0.1.0101.raucb"));
        assert!(!bundle_name_ok("../x.raucb"));
        assert!(!bundle_name_ok(".hidden.raucb"));
        assert!(!bundle_name_ok("x.tar"));
        assert!(!bundle_name_ok("a b.raucb"));
    }

    #[test]
    fn a_fall_back_is_told_from_the_pending_record() {
        assert_eq!(outcome(None, "A", false), "none");
        assert_eq!(outcome(Some("A"), "B", true), "trial");
        assert_eq!(outcome(Some("A"), "A", false), "fell-back");
        assert_eq!(outcome(Some("A"), "B", false), "kept");
    }

    #[test]
    fn raucs_errors_become_one_word() {
        assert_eq!(
            reason_of_rauc_error("signature verification failed"),
            "unsigned"
        );
        assert_eq!(
            reason_of_rauc_error("Compatible mismatch: expected X"),
            "machine"
        );
        assert_eq!(
            reason_of_rauc_error("plain bundles are not allowed"),
            "unsigned"
        );
        assert_eq!(reason_of_rauc_error("no space left"), "space");
        assert_eq!(reason_of_rauc_error("weird"), "unreadable");
    }

    #[test]
    fn the_running_version_is_version_id() {
        assert_eq!(
            running_version("NAME=vrx\nVERSION_ID=\"0.1.0100\"\n"),
            "0.1.0100"
        );
        assert_eq!(running_version("VERSION_ID=0.1.0099\n"), "0.1.0099");
    }
}
