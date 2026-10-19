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
pub use vrx_protocol::paths::UPDATES;
/// The floor /data keeps before any writer of UPDATES lands more
/// (review 2026-10-17, CON-01): the manage upload and the drive import
/// both admit against this, so one rule protects the applets' state.
pub const UPDATES_MIN_FREE: u64 = 256 << 20;
/// vrxhost's record of a trial it asked for, to tell a fall-back.
pub use vrx_protocol::paths::UPDATE_STATE as STATE;
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
/// or under "update" (1.11 and later). RAUC wraps "update" in a variant of
/// its own, so the a{sv} value is v(a{sv}): read as a dictionary straight
/// away it was nothing, every bundle's compatible was "" and every bundle
/// was refused as another machine's (bench, CM4, 0.1.0122, 2026-10-16).
fn compatible_and_version(info: &HashMap<String, OwnedValue>) -> (String, String) {
    if let (Some(c), Some(v)) =
        (string_of(info, "compatible"), string_of(info, "version"))
    {
        return (c, v);
    }
    let nested: Option<HashMap<String, OwnedValue>> = info.get("update").and_then(|v| {
        let mut v = ZValue::from(v.try_clone().ok()?);
        while let ZValue::Value(inner) = v {
            v = *inner;
        }
        HashMap::<String, OwnedValue>::try_from(OwnedValue::try_from(v).ok()?).ok()
    });
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
    if booted.is_empty() {
        tracing::warn!("update: RAUC names no booted slot; the answer is unknown");
    }
    let _ = std::fs::create_dir_all(STATE);
    let record = json!({ "from": booted }).to_string();
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
    // the record is written only now, after the restart was accepted: a
    // restart that never happened left a record that lied about one
    // (review 2026-10-17, CON-05)
    crate::install::atomic_write(&Path::new(STATE).join("pending.json"), &record)
        .map_err(|e| {
            (
                "UpdateFailed".to_owned(),
                json!({ "file": "", "detail": e }),
            )
        })?;
    Ok(json!({}))
}

/// What a pending record and this boot say: still on trial, kept, or
/// fallen back to the slot it came from.
pub fn outcome(
    pending_from: Option<&str>,
    booted: &str,
    on_trial: Option<bool>,
) -> &'static str {
    match pending_from {
        None => "none",
        // trial unknown: a slot that is not the primary's and has a
        // pending record is on trial until it is kept (the primary moves
        // at mark-good), so unknown reads as trial here — the one reading
        // that never wrongly reports "kept" while a trial could still
        // fall back (review 2026-10-17, CON-11)
        Some(_) if on_trial.unwrap_or(true) => "trial",
        Some(from) if from == booted => "fell-back",
        Some(_) => "kept",
    }
}

/// The running version, the slots and the last update's outcome.
pub async fn status() -> Result<Value, (String, Value)> {
    load_conf().ok_or_else(unavailable)?;
    let rauc = rauc().await?;
    let booted = rauc.boot_slot().await.unwrap_or_default();
    if booted.is_empty() {
        tracing::warn!("update: RAUC names no booted slot; the answer is unknown");
    }
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
    // trial answers 0 yes, 1 no, 2 cannot tell (the Pi script's contract,
    // review 2026-10-17, CON-11): unknown is an Option, never a no
    let firmware_trial = match tokio::process::Command::new(TRIAL).status().await {
        Ok(s) if s.success() => Some(true),
        Ok(s) if s.code() == Some(1) => Some(false),
        Ok(s) if s.code() == Some(2) => None,
        _ => None,
    };
    let primary = rauc.get_primary().await.ok();
    let primary_bootname = slots
        .iter()
        .find(|s| Some(&s.name) == primary.as_ref())
        .map(|s| s.bootname.clone());
    let on_trial =
        firmware_trial.map(|t| t && primary_bootname.as_deref() != Some(booted.as_str()));
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
        "trial": on_trial.unwrap_or(false),
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

    /// The downgrade rule's rows are the shared vector (review 2026-10-17,
    /// KRN-07): pre-install's test reads the same rows, so the shell rule
    /// and this one cannot drift.
    #[test]
    fn the_downgrade_rule_matches_the_shared_vector() {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../vectors/downgrade.json");
        let rows: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
        for row in rows.as_array().unwrap() {
            let i = &row["input"];
            let expect = row["expect"].as_str();
            // judge without the machine gate: the vector carries no machine
            // column, and the machine rule has its own test
            let order = crate::install::version_cmp(
                i["bundle"].as_str().unwrap(),
                i["running"].as_str().unwrap(),
            );
            let downgrades = i["downgrades"].as_bool().unwrap();
            let verdict = match order {
                std::cmp::Ordering::Equal => Some("same"),
                std::cmp::Ordering::Less if !downgrades => Some("older"),
                _ => None,
            };
            assert_eq!(verdict, expect, "row {:?}", row);
            // and judge itself agrees wherever the machine matches
            let got = judge(
                i["bundle"].as_str().unwrap(),
                "m",
                i["running"].as_str().unwrap(),
                "m",
                downgrades,
            );
            let got = match got {
                Some("machine") => None, // a matching machine never says machine
                other => other,
            };
            assert_eq!(got, expect, "judge row {:?}", row);
        }
    }

    fn dict(pairs: &[(&str, &str)]) -> HashMap<String, OwnedValue> {
        pairs
            .iter()
            .filter_map(|(k, v)| {
                Some((
                    (*k).to_owned(),
                    OwnedValue::try_from(ZValue::from(*v)).ok()?,
                ))
            })
            .collect()
    }

    fn wrapped(inner: HashMap<String, OwnedValue>, depth: usize) -> Option<OwnedValue> {
        let mut v = ZValue::from(inner);
        for _ in 0..depth {
            v = ZValue::Value(Box::new(v));
        }
        OwnedValue::try_from(v).ok()
    }

    #[test]
    fn rauc_s_update_dictionary_is_read_through_its_own_variant() {
        // what RAUC 1.15 sent on the CM4: "update" => v(a{sv})
        let update = dict(&[
            ("compatible", "vrxboard-cm4-disp28a"),
            ("version", "0.1.0125"),
        ]);
        for depth in [0, 1] {
            let mut info = HashMap::new();
            if let Some(u) = wrapped(update.clone(), depth) {
                info.insert("update".to_owned(), u);
            }
            assert_eq!(
                compatible_and_version(&info),
                ("vrxboard-cm4-disp28a".to_owned(), "0.1.0125".to_owned()),
                "depth {depth}"
            );
        }
    }

    #[test]
    fn an_older_rauc_s_top_level_answer_still_reads() {
        let info = dict(&[("compatible", "vrxboard-am62x"), ("version", "0.1.0001")]);
        assert_eq!(
            compatible_and_version(&info),
            ("vrxboard-am62x".to_owned(), "0.1.0001".to_owned())
        );
        assert_eq!(
            compatible_and_version(&HashMap::new()),
            (String::new(), String::new())
        );
    }

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
        assert_eq!(outcome(None, "A", Some(false)), "none");
        assert_eq!(outcome(Some("A"), "B", Some(true)), "trial");
        assert_eq!(outcome(Some("A"), "A", Some(false)), "fell-back");
        assert_eq!(outcome(Some("A"), "B", Some(false)), "kept");
        // an unknown trial never reports kept while it could still fall
        // back (CON-11): unknown reads as trial
        assert_eq!(outcome(Some("A"), "B", None), "trial");
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
