// An applet's systemd side (plan 0008 D1, D2, D16; plan 0011 D17): the
// drop-in vrx-applet@<id>.service.d/10-manifest.conf and the settings
// defaults file, generated from its manifest. One implementation for both
// callers: the build (`vrx unit`, from vrx-applet-unit.bbclass) for a
// built-in, and vrxhost at install for an installed applet. systemd does
// the confining; this only says, per applet, what the template unit
// (vrx-applet@.service) leaves open.

use std::collections::BTreeSet;
use std::fmt::Write as _;

use crate::manifest::{Manifest, Runtime, SystemGrant};

/// What a grant becomes (grants.conf, plan 0008 D2): a group, the device
/// classes the unit may open, the paths it may write.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Grant {
    pub group: String,
    pub devices: Vec<String>,
    pub paths: Vec<String>,
}

/// grants.conf, parsed: `grant = group [device class | path:<dir>...]`.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Grants {
    table: Vec<(String, Grant)>,
}

/// The layer's grants.conf, as the image ships it.
pub const GRANTS_CONF: &str =
    include_str!("../../../layer/recipes-applets/vrx-applets/files/grants.conf");

impl Grants {
    /// Parse grants.conf text.
    pub fn parse(text: &str) -> Result<Self, UnitError> {
        let mut table = Vec::new();
        for line in text.lines() {
            let line = line.split('#').next().unwrap_or("").trim();
            if line.is_empty() {
                continue;
            }
            let (key, rest) = line.split_once('=').ok_or_else(|| {
                UnitError::Grants(format!("{line:?}: not grant = group"))
            })?;
            let mut words = rest.split_whitespace();
            let group = words
                .next()
                .ok_or_else(|| UnitError::Grants(format!("{}: no group", key.trim())))?
                .to_owned();
            let (mut devices, mut paths) = (Vec::new(), Vec::new());
            for word in words {
                match word.strip_prefix("path:") {
                    Some(path) => paths.push(path.to_owned()),
                    None => devices.push(word.to_owned()),
                }
            }
            table.push((
                key.trim().to_owned(),
                Grant {
                    group,
                    devices,
                    paths,
                },
            ));
        }
        Ok(Self { table })
    }

    /// The image's own table.
    pub fn shipped() -> Self {
        Self::parse(GRANTS_CONF).unwrap_or_default()
    }

    pub fn get(&self, grant: &str) -> Option<&Grant> {
        self.table.iter().find(|(k, _)| k == grant).map(|(_, g)| g)
    }

    /// Every grant name the table defines.
    pub fn keys(&self) -> impl Iterator<Item = &str> {
        self.table.iter().map(|(k, _)| k.as_str())
    }
}

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum UnitError {
    #[error("grants.conf: {0}")]
    Grants(String),
    #[error("{applet}: manifest grants {grant:?}, which grants.conf does not define")]
    UnknownGrant { applet: String, grant: String },
    #[error("{0}: its user vrx-{0} is also a grant group in grants.conf")]
    UserIsGrantGroup(String),
    #[error("{0}: a flutter applet needs its bundle directory")]
    NoBundle(String),
    #[error("{0}: an installed applet holds no system grants and no fs paths")]
    InstalledWithAuthority(String),
}

/// Where the applet lives and how its unit is budgeted.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Place {
    /// The directory holding manifest.toml (and `app` for a native runtime).
    pub dir: String,
    /// A flutter applet's AOT bundle (`<dir>/<flutter version>/release`).
    pub bundle: Option<String>,
    /// Start to usable (plan 0008 D18).
    pub start_budget: String,
    /// Event-loop liveness (plan 0008 D18).
    pub watchdog: String,
    /// Installed (plan 0011 D16): a dynamic user, no grants.
    pub installed: bool,
}

impl Place {
    /// A built-in at `dir` with the image's budgets (5 s each).
    pub fn builtin(dir: impl Into<String>, bundle: Option<String>) -> Self {
        Self {
            dir: dir.into(),
            bundle,
            start_budget: "5s".to_owned(),
            watchdog: "5s".to_owned(),
            installed: false,
        }
    }
}

/// The drop-in text for `manifest` at `place`.
pub fn dropin(
    manifest: &Manifest,
    place: &Place,
    grants: &Grants,
) -> Result<String, UnitError> {
    let a = &manifest.applet;
    let id = &a.id;
    // an applet's own user and group is vrx-<id>; a grant group of that
    // name would make every member of the grant that applet (the settings
    // applet met the settings grant's first group name, vrx-settings)
    let own = format!("vrx-{id}");
    if grants.table.iter().any(|(_, g)| g.group == own) {
        return Err(UnitError::UserIsGrantGroup(id.clone()));
    }
    if place.installed
        && (!a.permissions.system.is_empty() || !a.permissions.fs.is_empty())
    {
        return Err(UnitError::InstalledWithAuthority(id.clone()));
    }
    let mut groups = BTreeSet::new();
    let mut devices = BTreeSet::new();
    let mut writable = BTreeSet::new();
    for grant in &a.permissions.system {
        let name = SystemGrant::as_str(*grant);
        let g = grants.get(name).ok_or_else(|| UnitError::UnknownGrant {
            applet: id.clone(),
            grant: name.to_owned(),
        })?;
        groups.insert(g.group.clone());
        devices.extend(g.devices.iter().cloned());
        writable.extend(g.paths.iter().cloned());
    }
    let exec_start = match a.runtime {
        Runtime::Flutter => {
            let bundle = place
                .bundle
                .as_deref()
                .ok_or_else(|| UnitError::NoBundle(id.clone()))?;
            // the KMS node its buffers come from and the GPU's render node
            groups.insert("video".to_owned());
            groups.insert("render".to_owned());
            devices.insert("char-drm".to_owned());
            format!("/usr/bin/flutter-vrx --release --app {bundle}")
        }
        Runtime::Dart | Runtime::Rust | Runtime::Native => format!("{}/app", place.dir),
    };
    let mut out = String::new();
    let _ = writeln!(
        out,
        "# Generated from the {id} manifest by vrx-applet-unit.bbclass. Do not edit."
    );
    out.push_str("[Service]\n");
    let _ = writeln!(out, "ExecStart={exec_start}");
    if place.installed {
        // plan 0011 D16: its own transient user; the template's User=
        // names it, its state lands under /var/lib/private/vrx/<id>
        out.push_str("DynamicUser=yes\n");
    }
    // D18: runtimes that speak the service protocol (flutter-vrx's app
    // role, the Rust SDK) get the start budget and the watchdog
    if matches!(a.runtime, Runtime::Flutter | Runtime::Rust) {
        out.push_str("Type=notify\nNotifyAccess=main\n");
        let _ = writeln!(out, "TimeoutStartSec={}", place.start_budget);
        let _ = writeln!(out, "WatchdogSec={}", place.watchdog);
    }
    if !groups.is_empty() {
        let list: Vec<&str> = groups.iter().map(String::as_str).collect();
        let _ = writeln!(out, "SupplementaryGroups={}", list.join(" "));
    }
    for device in &devices {
        let _ = writeln!(out, "DeviceAllow={device} rw");
    }
    // a grant's paths are writable through ProtectSystem=strict; the
    // manifest's own fs paths too (plan 0011 D10), each optional ("-"), so
    // a path the device does not have yet does not stop the start
    let fs: Vec<String> = a.permissions.fs.iter().map(|p| format!("-{p}")).collect();
    if !writable.is_empty() || !fs.is_empty() {
        let mut list: Vec<String> = writable.into_iter().collect();
        list.extend(fs);
        let _ = writeln!(out, "ReadWritePaths={}", list.join(" "));
    }
    Ok(out)
}

/// The declared settings' defaults, /etc/vrx/settings/<id>.conf (plan
/// 0008 D5), or None when the applet declares none.
pub fn settings_defaults(manifest: &Manifest) -> Option<String> {
    let a = &manifest.applet;
    if a.settings.is_empty() {
        return None;
    }
    let mut out = format!(
        "# {}'s settings (its manifest's [[applet.settings]]); Settings writes this\n",
        a.id
    );
    for s in &a.settings {
        let value = match &s.default {
            serde_json::Value::Bool(b) => b.to_string(),
            serde_json::Value::String(text) => text.clone(),
            other => other.to_string(),
        };
        let _ = writeln!(out, "{}={value}", s.key);
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn manifest(extra: &str) -> Manifest {
        format!(
            "[applet]\nid = \"notes\"\nname = \"Notes\"\nversion = \"1.0.0\"\nruntime = \"flutter\"\n{extra}"
        )
        .parse()
        .unwrap()
    }

    #[test]
    fn grants_conf_parses_groups_devices_and_paths() {
        let g = Grants::parse(
            "# c\ni2c = i2c char-i2c\nsettings = vrx-config path:/etc/vrx/settings\n",
        )
        .unwrap();
        assert_eq!(g.get("i2c").unwrap().devices, ["char-i2c"]);
        assert_eq!(g.get("settings").unwrap().paths, ["/etc/vrx/settings"]);
        assert!(Grants::parse("nonsense\n").is_err());
    }

    /// G023: whatever an installed applet's manifest asks for, its unit
    /// carries no grant group, and a manifest asking for authority is
    /// refused outright.
    #[test]
    fn an_installed_applet_runs_as_a_dynamic_user_with_no_grant_groups_g023() {
        let place = Place {
            installed: true,
            ..Place::builtin(
                "/usr/lib/vrx/apps/notes",
                Some("/usr/lib/vrx/apps/notes/3.47.5/release".into()),
            )
        };
        let grants = Grants::shipped();
        let text = dropin(&manifest(""), &place, &grants).unwrap();
        assert!(text.contains("DynamicUser=yes\n"), "{text}");
        assert!(
            text.contains("SupplementaryGroups=render video\n"),
            "{text}"
        );
        assert!(!text.contains("ReadWritePaths"), "{text}");
        let asks = manifest("[applet.permissions]\nsystem = [\"network\"]\n");
        assert_eq!(
            dropin(&asks, &place, &grants),
            Err(UnitError::InstalledWithAuthority("notes".into()))
        );
        let fs = manifest("[applet.permissions]\nfs = [\"/data/notes\"]\n");
        assert_eq!(
            dropin(&fs, &place, &grants),
            Err(UnitError::InstalledWithAuthority("notes".into()))
        );
    }

    #[test]
    fn a_manifest_fs_path_is_writable_and_optional_d10() {
        let m = manifest(
            "[applet.permissions]\nfs = [\"/data/notes\"]\nsystem = [\"settings\"]\n",
        );
        let text = dropin(
            &m,
            &Place::builtin("/system/defaults/notes", Some("/b".into())),
            &Grants::shipped(),
        )
        .unwrap();
        assert!(
            text.contains("ReadWritePaths=/etc/vrx/settings -/data/notes\n"),
            "{text}"
        );
    }

    #[test]
    fn a_grant_group_named_like_the_applet_user_is_refused() {
        let grants = Grants::parse("settings = vrx-notes\n").unwrap();
        let place = Place::builtin("/d", Some("/b".into()));
        assert_eq!(
            dropin(&manifest(""), &place, &grants),
            Err(UnitError::UserIsGrantGroup("notes".into()))
        );
    }

    #[test]
    fn settings_defaults_are_key_value() {
        let m = manifest(
            "[[applet.settings]]\nkey = \"a\"\nlabel = \"A\"\ncategory = \"C\"\ntype = \"bool\"\ndefault = true\n\
             [[applet.settings]]\nkey = \"n\"\nlabel = \"N\"\ncategory = \"C\"\ntype = \"int\"\ndefault = 3\n",
        );
        assert_eq!(
            settings_defaults(&m).unwrap(),
            "# notes's settings (its manifest's [[applet.settings]]); Settings writes this\na=true\nn=3\n"
        );
        assert_eq!(settings_defaults(&manifest("")), None);
    }
}
