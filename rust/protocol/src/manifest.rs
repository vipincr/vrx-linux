// The manifest: an applet's declaration. Every field from evrx-rt,
// adapted for Linux. This file is the single source of truth for what
// a manifest may say; vrxhost admits against it, the SDK scaffolds it,
// and `vrx build` validates it.
//
// Parsing is strict: an unknown key is a named parse error, not a
// silent ignore. A typo that quietly drops a permission grant would be
// a security hole that looks like a configuration mistake.

use indexmap::IndexMap;
use serde::{Deserialize, Serialize};

use crate::intent;

/// The maximum number of settings one applet may declare.
pub const SETTINGS_MAX: usize = 12;

/// The applet id reserved for the system ("vrx" is the OS, never an applet).
pub const RESERVED_ID: &str = "vrx";

/// The applet runtime an executable is built against.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Runtime {
    /// A UI applet: a Flutter bundle run by flutter-vrx in its app role.
    Flutter,
    /// A headless Dart applet, compiled AOT to a native executable (`app`).
    Dart,
    /// A Rust applet (`app`), headless or a console.
    Rust,
    /// Any other native executable (`app`).
    Native,
}

/// A system grant (plan 0008 D2): the vrxhost interface an applet may
/// call (`vrx.sys.<grant>.<verb>`). Built-ins only: on an installed
/// applet any grant is an admission error. Named like Snap interfaces,
/// one grant per Linux service family.
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize,
)]
#[serde(rename_all = "lowercase")]
pub enum SystemGrant {
    /// Wi-Fi and ethernet (connman).
    Network,
    /// Bluetooth power, pairing, bonds (BlueZ).
    Bluetooth,
    /// Time zone, automatic time, set time, alarms and timers.
    Time,
    /// The device name.
    Hostname,
    /// How the screen behaves: its brightness and idle timeout (plan 0010
    /// D7), which the compositor alone applies.
    Display,
    /// Power off and restart.
    Power,
    /// The USB gadget mode.
    Usb,
    /// Install and remove applets.
    Apps,
    /// The management web page.
    Serve,
    /// GPIO lines (through gpiod's io.gpiod1 service).
    Gpio,
    /// I2C buses.
    I2c,
    /// SPI buses.
    Spi,
    /// Serial ports.
    Serial,
    /// Audio devices.
    Audio,
    /// Cameras (V4L2).
    Camera,
    /// Input devices read directly (keys, encoders, sensors as input).
    Input,
    /// Industrial I/O sensors (IIO).
    Iio,
    /// Write any applet's settings file (plan 0008 D5).
    Settings,
    /// The local model servers' sockets (plan 0011 D18).
    Ml,
    /// The system's locale, which the time format follows (systemd-localed's
    /// SetLocale, plan 0011 D7).
    Locale,
}

impl SystemGrant {
    /// The grant as it appears in requests and manifests.
    pub fn as_str(self) -> &'static str {
        match self {
            SystemGrant::Network => "network",
            SystemGrant::Bluetooth => "bluetooth",
            SystemGrant::Time => "time",
            SystemGrant::Hostname => "hostname",
            SystemGrant::Display => "display",
            SystemGrant::Power => "power",
            SystemGrant::Usb => "usb",
            SystemGrant::Apps => "apps",
            SystemGrant::Serve => "serve",
            SystemGrant::Gpio => "gpio",
            SystemGrant::I2c => "i2c",
            SystemGrant::Spi => "spi",
            SystemGrant::Serial => "serial",
            SystemGrant::Audio => "audio",
            SystemGrant::Camera => "camera",
            SystemGrant::Input => "input",
            SystemGrant::Iio => "iio",
            SystemGrant::Settings => "settings",
            SystemGrant::Ml => "ml",
            SystemGrant::Locale => "locale",
        }
    }

    /// Every grant, for table checks.
    pub const ALL: [SystemGrant; 20] = [
        SystemGrant::Network,
        SystemGrant::Bluetooth,
        SystemGrant::Time,
        SystemGrant::Hostname,
        SystemGrant::Display,
        SystemGrant::Power,
        SystemGrant::Usb,
        SystemGrant::Apps,
        SystemGrant::Serve,
        SystemGrant::Gpio,
        SystemGrant::I2c,
        SystemGrant::Spi,
        SystemGrant::Serial,
        SystemGrant::Audio,
        SystemGrant::Camera,
        SystemGrant::Input,
        SystemGrant::Iio,
        SystemGrant::Settings,
        SystemGrant::Ml,
        SystemGrant::Locale,
    ];
}

/// What an applet is: one with screens (the default); a library, a
/// linkable kit never launched; or a service, launched and supervised like
/// any applet but with no screen, so never opened and never focused
/// (stt, plan 0011 D18). A service has no layout to check.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    #[default]
    Applet,
    Library,
    Service,
}

impl Kind {
    /// It has screens a person opens.
    pub fn opens(self) -> bool {
        self == Kind::Applet
    }
}

/// Screen orientation an applet accepts.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Orientation {
    Any,
    Landscape,
    Portrait,
    Locked,
}

/// A setting's value type, as the Settings applet renders it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SettingType {
    Enum,
    Bool,
    Int,
    Float,
    Text,
}

#[derive(Debug, thiserror::Error)]
pub enum ManifestError {
    #[error("manifest parse error: {0}")]
    Parse(String),
    #[error("manifest invalid: {0}")]
    Invalid(String),
}

//
// The manifest sections, in declaration order. Every struct carries
// `deny_unknown_fields`: unknown keys must fail, named.
//

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Manifest {
    pub applet: AppletSection,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AppletSection {
    pub id: String,
    pub name: String,
    pub version: String,
    pub runtime: Runtime,
    #[serde(default)]
    pub kind: Kind,
    /// Why this applet must keep running behind the screen (plan 0012
    /// D2). vrxhost freezes an applet 30 s after it leaves the screen
    /// unless it says why not; the reason is the value, so a bare `true`
    /// cannot be written. Built-ins only: an installed applet that kept
    /// itself awake would spend the battery without a reason anyone read.
    #[serde(default)]
    pub background: Option<String>,

    #[serde(default)]
    pub display: Option<DisplaySection>,
    #[serde(default)]
    pub resources: Option<ResourcesSection>,
    #[serde(default)]
    pub roles: RolesSection,
    #[serde(default)]
    pub permissions: PermissionsSection,
    #[serde(default)]
    pub intents: IntentsSection,
    #[serde(default)]
    pub channels: ChannelsSection,
    #[serde(default)]
    pub routes: IndexMap<String, RouteSection>,
    #[serde(default)]
    pub command: Option<CommandSection>,
    #[serde(default)]
    pub settings: Vec<SettingDecl>,
}

/// Launcher presentation. Absent means: not a tile.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DisplaySection {
    pub icon: String,
    #[serde(default)]
    pub tile: bool,
    #[serde(default)]
    pub position: u32,
    #[serde(default = "default_orientation")]
    pub orientation: Orientation,
}

fn default_orientation() -> Orientation {
    Orientation::Any
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ResourcesSection {
    #[serde(default = "default_heap_mb")]
    pub heap_mb: u32,
}

fn default_heap_mb() -> u32 {
    64
}

/// System roles. Held by at most the declared holders; on installed
/// (non-built-in) applets, any role is an admission error.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RolesSection {
    #[serde(default)]
    pub home: bool,
    #[serde(default)]
    pub shell: bool,
    #[serde(default)]
    pub installs: bool,
    #[serde(default)]
    pub resident: bool,
}

impl RolesSection {
    pub fn any(&self) -> bool {
        self.home || self.shell || self.installs || self.resident
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PermissionsSection {
    /// Explicit path grants outside the named permissions.
    #[serde(default)]
    pub fs: Vec<String>,
    /// System grants (plan 0008 D2): built-ins only.
    #[serde(default)]
    pub system: Vec<SystemGrant>,
}

/// A handler declaration: which intent, at what priority, opened at
/// which route (if any).
///
/// Told (no `at`): the intent is delivered to the running applet as an
/// action. Opened (with `at`): vrxhost starts or fronts the applet at
/// that route with the payload.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct HandleDecl {
    pub name: String,
    pub priority: u16,
    #[serde(default)]
    pub at: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct IntentsSection {
    #[serde(default)]
    pub handles: Vec<HandleDecl>,
    #[serde(default)]
    pub emits: Vec<String>,
}

/// The streams an applet offers and opens through vrxhost (plan 0008
/// D15): `offers` are channel names others may open on this applet;
/// `opens` are `<applet>.<channel>` this applet may open. vrxhost refuses
/// any other.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ChannelsSection {
    #[serde(default)]
    pub offers: Vec<String>,
    #[serde(default)]
    pub opens: Vec<String>,
}

/// A channel or applet name: [a-z][a-z0-9_]*, at most 32.
fn is_name(s: &str) -> bool {
    s.len() <= 32
        && s.chars().next().is_some_and(|c| c.is_ascii_lowercase())
        && s.chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_')
}

/// Route 0 is the root and is never declared; declaration order is the
/// numbering. The section body is empty today; it stays a table so a
/// route can carry configuration without a format break.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RouteSection {
    // intentionally empty
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CommandSection {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default)]
    pub usage: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SettingDecl {
    pub key: String,
    pub label: String,
    pub category: String,
    pub r#type: SettingType,
    pub default: serde_json::Value,
    #[serde(default)]
    pub options: Option<Vec<String>>,
}

/// Trees no applet may be granted write access to (plan 0011 D10): the
/// OS's own configuration, programs, boot files and kernel interfaces.
pub const FS_REFUSED: &[&str] = &[
    "/etc", "/usr", "/boot", "/proc", "/sys", "/dev", "/bin", "/sbin", "/lib",
];

/// A manifest fs path: absolute, normal (no `.`, `..` or doubled `/`),
/// not the root, and outside [`FS_REFUSED`].
pub fn fs_path_ok(path: &str) -> Result<(), &'static str> {
    if !path.starts_with('/') {
        return Err("must be an absolute path");
    }
    if path == "/" {
        return Err("the whole filesystem cannot be granted");
    }
    let rest = path.strip_suffix('/').unwrap_or(path);
    if rest[1..]
        .split('/')
        .any(|c| c.is_empty() || c == "." || c == "..")
    {
        return Err("must be a normal path (no ., .. or //)");
    }
    if rest.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return Err("must not contain spaces or control characters");
    }
    if FS_REFUSED
        .iter()
        .any(|t| rest == *t || rest.starts_with(&format!("{t}/")))
    {
        return Err("is the system's own (/etc, /usr, /boot, /proc, /sys, /dev and the program trees are refused)");
    }
    Ok(())
}

/// Built-in handlers hold priorities 500-999; installed applets 0-499.
/// A card app can never be asked before a built-in.
pub const PRIORITY_BUILTIN_MIN: u16 = 500;
pub const PRIORITY_MAX: u16 = 999;

impl std::str::FromStr for Manifest {
    type Err = ManifestError;

    /// Parse and validate a manifest from its TOML text.
    fn from_str(text: &str) -> Result<Self, Self::Err> {
        let manifest: Manifest =
            toml::from_str(text).map_err(|e| ManifestError::Parse(e.to_string()))?;
        manifest.validate()?;
        Ok(manifest)
    }
}

impl Manifest {
    /// Enforce every cross-field rule. Parse-time structural rules are
    /// serde's; these are the ones both sides must check identically.
    pub fn validate(&self) -> Result<(), ManifestError> {
        let a = &self.applet;
        let invalid = |msg: String| Err(ManifestError::Invalid(msg));

        // id: [a-z][a-z0-9_]*, max 32, "vrx" refused.
        let id = &a.id;
        let id_ok = id.len() <= 32
            && id != RESERVED_ID
            && id.chars().next().is_some_and(|c| c.is_ascii_lowercase())
            && id
                .chars()
                .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_');
        if !id_ok {
            return invalid(format!(
                "applet.id {id:?}: must match [a-z][a-z0-9_]* (max 32) and not be {RESERVED_ID:?}"
            ));
        }

        if a.name.is_empty() || a.name.chars().count() > 32 {
            return invalid(format!(
                "applet.name {:?}: must be 1-32 characters (a person reads it)",
                a.name
            ));
        }

        if a.version.is_empty() {
            return invalid("applet.version: must not be empty".to_owned());
        }

        // a reason a person can read: a sentence, not a flag
        if let Some(why) = &a.background {
            let n = why.trim().chars().count();
            if !(12..=160).contains(&n) || why.contains('\n') {
                return invalid(format!(
                    "applet.background {why:?}: say why it runs behind the screen, in one line of 12-160 characters"
                ));
            }
        }

        // a service has no screen: it cannot be Flutter, a tile, or a
        // place a deep link opens
        if a.kind == Kind::Service {
            if a.runtime == Runtime::Flutter {
                return invalid("kind = \"service\": a Flutter applet has screens; a service has none".to_owned());
            }
            if a.display.as_ref().is_some_and(|d| d.tile) || !a.routes.is_empty() {
                return invalid("kind = \"service\": a service has no screen, so no tile and no routes".to_owned());
            }
            if a.intents.handles.iter().any(|h| h.at.is_some()) {
                return invalid("kind = \"service\": a handler opens at a route, and a service has none".to_owned());
            }
        }

        // Intent names: shared rule with the intent wire type.
        for handle in &a.intents.handles {
            intent::validate_name(&handle.name)
                .map_err(|e| ManifestError::Invalid(format!("handles entry: {e}")))?;
            if handle.priority > PRIORITY_MAX {
                return invalid(format!(
                    "handles {:?}: priority {} exceeds the maximum {}",
                    handle.name, handle.priority, PRIORITY_MAX
                ));
            }
            if let Some(route) = &handle.at {
                if !a.routes.contains_key(route) {
                    return invalid(format!(
                        "handles {:?}: opens at route {route:?} which the manifest does not declare",
                        handle.name
                    ));
                }
            }
        }
        for name in &a.intents.emits {
            intent::validate_name(name)
                .map_err(|e| ManifestError::Invalid(format!("emits entry: {e}")))?;
        }
        for name in &a.channels.offers {
            if !is_name(name) {
                return invalid(format!(
                    "channels.offers {name:?}: must match [a-z][a-z0-9_]* (max 32)"
                ));
            }
        }
        for name in &a.channels.opens {
            let ok = name
                .split_once('.')
                .is_some_and(|(applet, channel)| is_name(applet) && is_name(channel));
            if !ok {
                return invalid(format!(
                    "channels.opens {name:?}: must be <applet>.<channel>"
                ));
            }
        }

        // fs (plan 0011 D10): absolute directories an applet may write,
        // never the system's own trees
        for path in &a.permissions.fs {
            if let Err(why) = fs_path_ok(path) {
                return invalid(format!("permissions.fs {path:?}: {why}"));
            }
        }

        if a.settings.len() > SETTINGS_MAX {
            return invalid(format!(
                "settings: {} declared, at most {SETTINGS_MAX} allowed",
                a.settings.len()
            ));
        }
        for setting in &a.settings {
            if setting.key.is_empty() {
                return invalid(format!(
                    "setting {:?}: key must not be empty",
                    setting.label
                ));
            }
            if a.settings.iter().filter(|s| s.key == setting.key).count() > 1 {
                return invalid(format!("setting {:?}: key declared twice", setting.key));
            }
            let fits = match (setting.r#type, &setting.default) {
                (SettingType::Enum, serde_json::Value::String(v)) => {
                    match &setting.options {
                        Some(options) => options.contains(v),
                        None => {
                            return invalid(format!(
                                "setting {:?}: type enum requires options",
                                setting.key
                            ))
                        }
                    }
                }
                (SettingType::Bool, serde_json::Value::Bool(_)) => true,
                (SettingType::Int, serde_json::Value::Number(n)) => {
                    n.is_i64() || n.is_u64()
                }
                (SettingType::Float, serde_json::Value::Number(_)) => true,
                (SettingType::Text, serde_json::Value::String(_)) => true,
                _ => false,
            };
            if !fits {
                return invalid(format!(
                    "setting {:?}: default {} is not a {:?}{}",
                    setting.key,
                    setting.default,
                    setting.r#type,
                    if setting.r#type == SettingType::Enum {
                        " among its options"
                    } else {
                        ""
                    }
                ));
            }
        }

        Ok(())
    }

    /// The name of route `number`: "" for the root, None past the declared.
    pub fn route_name(&self, number: u32) -> Option<&str> {
        if number == 0 {
            return Some("");
        }
        self.applet
            .routes
            .get_index(number as usize - 1)
            .map(|(name, _)| name.as_str())
    }

    /// The number of a declared route: 0 is the root (never declared),
    /// declaration order is the numbering.
    pub fn route_number(&self, name: &str) -> Option<u32> {
        if name.is_empty() {
            // the root
            return Some(0);
        }
        self.applet.routes.get_index_of(name).map(|i| i as u32 + 1)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn with(extra: &str) -> Result<Manifest, ManifestError> {
        format!("[applet]\nid = \"a\"\nname = \"A\"\nversion = \"1\"\nruntime = \"rust\"\n{extra}").parse()
    }

    /// plan 0012 D2: a background exemption is a reason, read by a person.
    #[test]
    fn background_is_a_reason_not_a_flag_d2() {
        assert!(with("background = \"rings alarms while hidden\"\n").is_ok());
        assert!(with("background = true\n").is_err());
        assert!(with("background = \"yes\"\n").is_err());
        assert!(with("background = \"two\\nlines are not one reason\"\n").is_err());
        assert_eq!(with("").unwrap().applet.background, None);
    }

    #[test]
    fn fs_paths_are_absolute_normal_and_outside_the_system_d10() {
        for ok in ["/data/notes", "/var/lib/vrx/x/", "/media/sd"] {
            assert_eq!(fs_path_ok(ok), Ok(()), "{ok}");
        }
        for bad in [
            "data",
            "/",
            "/etc",
            "/etc/vrx",
            "/usr/bin",
            "/boot",
            "/proc/1",
            "/sys/devices",
            "/dev/mem",
            "/data/../etc",
            "/data//x",
            "/data/./x",
            "/data/a b",
            "/lib/x",
        ] {
            assert!(fs_path_ok(bad).is_err(), "{bad} should be refused");
        }
        assert!(with("[applet.permissions]\nfs = [\"/usr/bin\"]\n").is_err());
        assert!(with("[applet.permissions]\nfs = [\"/data/a\"]\n").is_ok());
    }

    #[test]
    fn a_setting_default_fits_its_type_and_keys_are_unique() {
        let decl = |ty: &str, default: &str, options: &str| {
            with(&format!("[[applet.settings]]\nkey = \"k\"\nlabel = \"K\"\ncategory = \"C\"\ntype = \"{ty}\"\ndefault = {default}\n{options}"))
        };
        assert!(decl("enum", "\"b\"", "options = [\"a\", \"b\"]").is_ok());
        assert!(decl("enum", "\"c\"", "options = [\"a\", \"b\"]").is_err());
        assert!(decl("enum", "\"a\"", "").is_err());
        assert!(decl("bool", "true", "").is_ok());
        assert!(decl("bool", "\"yes\"", "").is_err());
        assert!(decl("int", "3", "").is_ok());
        assert!(decl("int", "3.5", "").is_err());
        assert!(decl("float", "3", "").is_ok());
        assert!(decl("text", "\"x\"", "").is_ok());
        assert!(decl("text", "1", "").is_err());
        let twice = "[[applet.settings]]\nkey = \"k\"\nlabel = \"K\"\ncategory = \"C\"\ntype = \"bool\"\ndefault = true\n";
        assert!(with(&format!("{twice}{twice}")).is_err());
    }

    /// The reference manifest: the clock example from the plan, verbatim.
    const CLOCK: &str = r#"
[applet]
id = "clock"                   # [a-z][a-z0-9_]*, max 32, "vrx" refused
name = "Clock"                 # what a person reads, max 32
version = "1.0.0"
runtime = "flutter"            # "flutter" | "rust" | "native"
kind = "applet"                # "applet" (default), "library" or "service" (no screen)
background = "rings alarms while another applet is in front" # why it is never frozen (plan 0012 D2)

[applet.display]
icon = "icon.png"              # or a glyph from the icon font
tile = true                    # show in the launcher?
position = 3                   # launcher order
orientation = "landscape"      # "any" | "landscape" | "portrait" | "locked"

[applet.resources]
heap_mb = 128                  # memory limit (enforced by vrxhost via cgroups)

[applet.roles]
home = false                   # where Home goes (one holder)
shell = false                  # draws the chrome (one holder)
installs = false               # can install/remove other applets
resident = false               # alive from boot to power-off, never evicted

[applet.permissions]
system = ["time", "audio"]     # system grants: groups the services check (plan 0008 D2)
fs = ["/data/clock", "/run/ping.pong"] # writable paths (plan 0011 D10)

[applet.intents]
handles = [
    { name = "sys.alarm.ring", priority = 900, at = "ring" },
    { name = "vrx.open", priority = 500 },
]
emits = ["alarm.fire", "app.finished"]

[applet.routes]                # screens reachable by deep link
# Route 0 is the root (never declared); declaration order is the numbering
clock = {}                     # route 1
alarms = {}                    # route 2
timer = {}                     # route 3
ring = {}                      # route 4 (the sys.alarm.ring deep link)

[applet.command]               # make the applet a shell pipeline stage
enabled = true
usage = "clock [--set HH:MM]"

[[applet.settings]]            # up to 12, surfaced in the Settings applet
key = "clock_format"
label = "Time format"
category = "Clock"
type = "enum"
default = "24h"
options = ["12h", "24h"]
"#;

    #[test]
    fn the_reference_manifest_parses() {
        let m = CLOCK
            .parse::<Manifest>()
            .expect("reference manifest must parse");
        assert_eq!(m.applet.id, "clock");
        assert_eq!(m.applet.runtime, Runtime::Flutter);
        assert_eq!(m.applet.permissions.fs, ["/data/clock", "/run/ping.pong"]);
        assert_eq!(m.applet.intents.handles.len(), 2);
        assert_eq!(
            m.applet.intents.handles[0],
            HandleDecl {
                name: "sys.alarm.ring".to_owned(),
                priority: 900,
                at: Some("ring".to_owned()),
            }
        );
    }

    #[test]
    fn a_service_has_no_screen_no_tile_and_no_routes() {
        let base = "[applet]\nid = \"stt\"\nname = \"S\"\nversion = \"0.1.0\"\n";
        let ok = format!("{base}runtime = \"rust\"\nkind = \"service\"\n[applet.display]\nicon = \"mic\"\ntile = false\n");
        let m = ok.parse::<Manifest>().expect("a rust service parses");
        assert_eq!(m.applet.kind, Kind::Service);
        assert!(!m.applet.kind.opens());
        assert!(Kind::Applet.opens() && !Kind::Library.opens());
        for bad in [
            format!("{base}runtime = \"flutter\"\nkind = \"service\"\n"),
            format!("{base}runtime = \"rust\"\nkind = \"service\"\n[applet.display]\nicon = \"mic\"\ntile = true\n"),
            format!("{base}runtime = \"rust\"\nkind = \"service\"\n[applet.routes]\nx = {{}}\n"),
        ] {
            assert!(bad.parse::<Manifest>().is_err(), "refused: {bad}");
        }
    }

    #[test]
    fn route_numbers_follow_declaration_order() {
        let m = CLOCK.parse::<Manifest>().expect("parses");
        assert_eq!(m.route_number(""), Some(0)); // the root
        assert_eq!(m.route_number("clock"), Some(1));
        assert_eq!(m.route_number("alarms"), Some(2));
        assert_eq!(m.route_number("timer"), Some(3));
        assert_eq!(m.route_number("ring"), Some(4));
        assert_eq!(m.route_number("nope"), None);
    }

    #[test]
    fn unknown_key_is_a_named_parse_error() {
        let text = r#"
[applet]
id = "clock"
name = "Clock"
version = "1.0.0"
runtime = "rust"

[applet.permissioms]
network = true
"#;
        let err = text.parse::<Manifest>().unwrap_err();
        assert!(
            err.to_string().contains("permissioms"),
            "the unknown key must be named: {err}"
        );
    }

    #[test]
    fn channels_are_names_and_opens_name_the_applet() {
        let with =
            |body: &str| format!("{}\n[applet.channels]\n{body}\n", minimal("cam"));
        let m: Manifest = with("offers = [\"frames\"]\nopens = [\"mic.samples\"]")
            .parse()
            .unwrap();
        assert_eq!(m.applet.channels.offers, vec!["frames"]);
        assert_eq!(m.applet.channels.opens, vec!["mic.samples"]);
        for bad in [
            "offers = [\"Frames\"]",
            "opens = [\"samples\"]",
            "opens = [\"mic.\"]",
            "opens = [\"a.b.c\"]",
        ] {
            let err = with(bad).parse::<Manifest>().unwrap_err();
            assert!(err.to_string().contains("channels."), "{bad}: {err}");
        }
    }

    #[test]
    fn the_reserved_id_is_refused() {
        let text = minimal("vrx");
        let err = &text.parse::<Manifest>().unwrap_err();
        assert!(err.to_string().contains("vrx"), "{err}");
    }

    #[test]
    fn a_bad_id_is_refused() {
        for id in ["Clock", "1clock", "clock-app", ""] {
            let err = minimal(id).parse::<Manifest>().unwrap_err();
            assert!(err.to_string().contains("applet.id"), "{id}: {err}");
        }
    }

    #[test]
    fn a_handler_for_an_undeclared_route_is_refused() {
        let text = minimal("clock") + "\n[applet.intents]\nhandles = [{ name = \"x.y\", priority = 10, at = \"ghost\" }]\n";
        let err = &text.parse::<Manifest>().unwrap_err();
        assert!(err.to_string().contains("ghost"), "{err}");
    }

    #[test]
    fn priority_over_the_band_max_is_refused() {
        let text = minimal("clock")
            + "\n[applet.intents]\nhandles = [{ name = \"x.y\", priority = 1000 }]\n";
        let err = &text.parse::<Manifest>().unwrap_err();
        assert!(err.to_string().contains("priority"), "{err}");
    }

    #[test]
    fn enum_setting_without_options_is_refused() {
        let text = minimal("clock")
            + "\n[[applet.settings]]\nkey = \"k\"\nlabel = \"K\"\ncategory = \"C\"\ntype = \"enum\"\ndefault = \"a\"\n";
        let err = &text.parse::<Manifest>().unwrap_err();
        assert!(err.to_string().contains("options"), "{err}");
    }

    #[test]
    fn the_minimal_manifest_parses_with_defaults() {
        let m = minimal("hello")
            .parse::<Manifest>()
            .expect("minimal must parse");
        assert_eq!(m.applet.kind, Kind::Applet);
        assert!(!m.applet.roles.any());
        assert!(m.applet.permissions.fs.is_empty());
        assert!(m.applet.command.is_none());
    }

    fn minimal(id: &str) -> String {
        format!(
            "[applet]\nid = \"{id}\"\nname = \"N\"\nversion = \"0.1.0\"\nruntime = \"rust\"\n"
        )
    }
}

#[cfg(test)]
mod grant_table {
    use super::SystemGrant;

    /// G017 (plan 0008): every grant maps to exactly one group in the
    /// layer's grants.conf, and grants.conf names no grant the manifest
    /// cannot carry.
    #[test]
    fn grants_conf_matches_system_grant() {
        let text =
            include_str!("../../../layer/recipes-applets/vrx-applets/files/grants.conf");
        let mut keys: Vec<String> = text
            .lines()
            .map(|l| l.split('#').next().unwrap_or("").trim())
            .filter(|l| !l.is_empty())
            .map(|l| {
                let (key, group) = l.split_once('=').expect("grant = group");
                assert!(!group.trim().is_empty(), "{key}: no group");
                key.trim().to_owned()
            })
            .collect();
        keys.sort();
        let mut want: Vec<String> = SystemGrant::ALL
            .iter()
            .map(|g| g.as_str().to_owned())
            .collect();
        want.sort();
        assert_eq!(keys, want);
    }
}
