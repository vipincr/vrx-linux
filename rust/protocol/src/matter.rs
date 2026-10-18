// Matter (plan 0015): what the device shows a home app, and the link
// between vrxhost and vrx-matter. vrx-matter speaks Matter on the network
// and owns the fabrics; vrxhost owns what may be reached through it. This
// file is the one home of both halves' shared rules:
//
// - the allow-list (D8): `/etc/vrx/settings/vrx.conf`, written by the
//   Settings applet through the kit's settings writer. `matter_screen`
//   (default on) exposes the device's own endpoint, the screen;
//   `matter_expose` names the applets a person switched on;
// - the exposed set (G043): the registry's applets that declare
//   `[applet.matter]`, intersected with the allow-list. vrxhost sends it
//   to vrx-matter, which builds its endpoints from nothing else;
// - a command's intent (G043): vrxhost turns a Matter command into the
//   applet's own intent only for an applet in the exposed set, and
//   refuses anything else by name;
// - the link's messages: vrxhost connects to io.vrx.Matter as root and
//   holds `Link`, whose replies are commands; it answers each with
//   `Done` and tells vrx-matter its state with `Host`. The same link
//   carries vrx-matter's request for Bluetooth (`Advertise`), which
//   vrxhost's arbiter grants or refuses (D4, G044).

use serde::{Deserialize, Serialize};

use crate::manifest::{MatterDeviceType, MatterSection};
use crate::Registry;

/// The system's own settings file (the reserved id's): the allow-list.
pub const SETTINGS_FILE: &str = "/etc/vrx/settings/vrx.conf";

/// vrx-matter's socket (D9): group vrx-matter, the `matter` grant's.
pub const SOCKET: &str = "/run/vrx-matter/io.vrx.Matter";

/// The interface vrx-matter serves.
pub const INTERFACE: &str = "io.vrx.Matter";

/// What a person allowed (D8).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Exposure {
    /// The device's endpoint 1: the screen's on/off and brightness.
    pub screen: bool,
    /// The applets switched on, by id.
    pub applets: Vec<String>,
    /// Why nothing is exposed (review 2026-10-17, CON-08): an
    /// unreadable or malformed allow-list exposes nothing and says why,
    /// instead of quietly reading as the default.
    pub error: Option<String>,
}

impl Default for Exposure {
    /// Nothing written yet: the screen on (D8), no applet.
    fn default() -> Self {
        Self {
            screen: true,
            applets: Vec::new(),
            error: None,
        }
    }
}

impl Exposure {
    /// Read the allow-list from vrx.conf's text (`key=value` lines, the
    /// kit's settings format). Unknown keys are other settings'.
    pub fn parse(text: &str) -> Self {
        let mut out = Self::default();
        out.error = None;
for line in text.lines() {
            let Some((key, value)) = line.split_once('=') else {
                continue;
            };
            match key.trim() {
                "matter_screen" => {
                    // only the literal words count: anything else names a
                    // fault, not a screen quietly exposed
                    out.screen = match value.trim() {
                        "true" => true,
                        "false" => false,
                        other => {
                            out.screen = false;
                            out.error = Some(format!("matter_screen is '{other}', not true or false"));
                            false
                        }
                    };
                }
                "matter_expose" => {
                    out.applets = value
                        .split(',')
                        .map(str::trim)
                        .filter(|id| !id.is_empty())
                        .map(str::to_owned)
                        .collect();
                }
                _ => {}
            }
        }
        out
    }

    /// The allow-list now. A file that cannot be READ is not the default
    /// allow-list: unknown is never yes (review 2026-10-17, CON-08), so
    /// an unreadable file exposes nothing and says why. A key that is
    /// neither true nor false is an error, not a hidden expose.
    pub fn read() -> Self {
        match std::fs::read_to_string(SETTINGS_FILE) {
            Ok(t) => Self::parse(&t),
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => Self::default(),
            Err(err) => {
                Self::broken(format!("{SETTINGS_FILE}: {err}"))
            }
        }
    }

    /// An allow-list that exposes nothing, carrying why (shown to the
    /// person, logged by vrxhost).
    pub fn broken(reason: String) -> Self {
        Self {
            screen: false,
            applets: Vec::new(),
            error: Some(reason),
        }
    }
}

/// One applet shown to a home app: a bridged node on the aggregator.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Exposed {
    pub applet: String,
    /// What a home app labels it with: the applet's name.
    pub name: String,
    pub device_type: MatterDeviceType,
}

/// The exposed set (G043): applets that declare a valid `[applet.matter]`
/// and that the person switched on, in registry order.
pub fn exposed(registry: &Registry, exposure: &Exposure) -> Vec<Exposed> {
    exposable(registry)
        .into_iter()
        .filter(|e| exposure.applets.contains(&e.applet))
        .collect()
}

/// Every applet that declares `[applet.matter]`, in registry order.
pub fn exposable(registry: &Registry) -> Vec<Exposed> {
    registry
        .iter()
        .filter_map(|e| {
            let m = e.manifest.applet.matter.as_ref()?;
            Some(Exposed {
                applet: e.manifest.applet.id.clone(),
                name: e.manifest.applet.name.clone(),
                device_type: m.device_type,
            })
        })
        .collect()
}

/// A command a home app gave, as vrx-matter hands it to vrxhost.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Command {
    /// Endpoint 1's On/Off: the screen on (woken) or off.
    Screen { on: bool },
    /// Endpoint 1's Level Control: the brightness position, 0 to 100.
    Brightness { position: u8 },
    /// A bridged applet's On/Off.
    OnOff { applet: String, on: bool },
    /// Not a home app's: vrx-matter asks vrxhost's Bluetooth arbiter for
    /// hci0 before its BLE transport advertises, for at most `secs` (the
    /// window; plan 0015 D4, G044). Done true is the grant: Device Link's
    /// window is paused and the radio is on.
    Advertise { secs: u16 },
    /// The BLE transport stopped (the window closed, or it failed): the
    /// arbiter gives Device Link back what was left of its window.
    AdvertiseEnd,
}

/// Why vrxhost refused a command (G043), named in the log and the reply.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum Refusal {
    #[error("the screen is not exposed to Matter")]
    ScreenNotExposed,
    #[error("applet {0:?} is not exposed to Matter")]
    NotExposed(String),
}

/// The intent a bridged applet's command becomes: its manifest's own
/// binding, and only for an applet the person exposed (G043).
pub fn command_intent(
    registry: &Registry,
    exposure: &Exposure,
    applet: &str,
    on: bool,
) -> Result<String, Refusal> {
    let refused = || Refusal::NotExposed(applet.to_owned());
    if !exposure.applets.iter().any(|a| a == applet) {
        return Err(refused());
    }
    let section: &MatterSection = registry
        .find(applet)
        .and_then(|e| e.manifest.applet.matter.as_ref())
        .ok_or_else(refused)?;
    let commands = &section.on_off.as_ref().ok_or_else(refused)?.command;
    Ok(if on { &commands.on } else { &commands.off }.clone())
}

/// A screen command passes only while the screen is exposed.
pub fn screen_allowed(exposure: &Exposure) -> Result<(), Refusal> {
    if exposure.screen {
        Ok(())
    } else {
        Err(Refusal::ScreenNotExposed)
    }
}

/// One reply of `Link`: a command and the id `Done` answers.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LinkCommand {
    pub id: u64,
    pub command: Command,
}

/// `Host`'s parameters: what vrx-matter reports and builds from.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HostState {
    /// The screen is lit (the compositor's word).
    pub screen_on: bool,
    /// The brightness position, 0 to 100; -1 where the screen cannot dim.
    pub brightness: i32,
    /// Endpoint 1 is exposed.
    pub screen: bool,
    /// The bridged applets.
    pub applets: Vec<Exposed>,
    /// Every applet that declares a Matter block, exposed or not: what
    /// Settings > Matter offers to switch on.
    pub exposable: Vec<Exposed>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::RegistryEntry;

    fn registry() -> Registry {
        let mut r = Registry::new();
        let clock = "[applet]\nid = \"clock\"\nname = \"Clock\"\nversion = \"1\"\nruntime = \"rust\"\n[applet.intents]\nhandles = [{ name = \"vrx.clock.alarm.arm\", priority = 500 }, { name = \"vrx.clock.alarm.disarm\", priority = 500 }]\n[applet.matter]\ndevice_type = \"on_off_plug\"\nclusters = [\"on_off\"]\non_off.command.on = \"vrx.clock.alarm.arm\"\non_off.command.off = \"vrx.clock.alarm.disarm\"\n";
        let notes = "[applet]\nid = \"notes\"\nname = \"Notes\"\nversion = \"1\"\nruntime = \"rust\"\n";
        for text in [clock, notes] {
            r.admit(RegistryEntry {
                manifest: text.parse().unwrap(),
                path: "/x".into(),
                builtin: true,
            })
            .unwrap();
        }
        r
    }

    #[test]
    fn the_allow_list_defaults_to_the_screen_alone_d8() {
        assert_eq!(Exposure::parse(""), Exposure::default());
        assert!(Exposure::default().screen);
        let e = Exposure::parse(
            "theme=dark\nmatter_screen=false\nmatter_expose=clock, notes,\n",
        );
        assert!(!e.screen);
        assert_eq!(e.applets, ["clock", "notes"]);
    }

    /// G043: an endpoint only for a declared, allowed applet; a command
    /// only to one, as its own binding.
    #[test]
    fn exposure_is_declared_and_allowed_g043() {
        let r = registry();
        let none = Exposure::default();
        assert!(exposed(&r, &none).is_empty());
        let both = Exposure::parse("matter_expose=clock,notes,ghost");
        let set = exposed(&r, &both);
        assert_eq!(set.len(), 1, "notes declares no block, ghost is absent");
        assert_eq!(set[0].applet, "clock");
        assert_eq!(set[0].name, "Clock");

        assert_eq!(
            command_intent(&r, &both, "clock", true).as_deref(),
            Ok("vrx.clock.alarm.arm")
        );
        assert_eq!(
            command_intent(&r, &both, "clock", false).as_deref(),
            Ok("vrx.clock.alarm.disarm")
        );
        for (exposure, applet) in [(&none, "clock"), (&both, "notes"), (&both, "ghost")] {
            assert_eq!(
                command_intent(&r, exposure, applet, true),
                Err(Refusal::NotExposed(applet.into()))
            );
        }
        assert_eq!(
            screen_allowed(&Exposure::parse("matter_screen=false")),
            Err(Refusal::ScreenNotExposed)
        );
        assert_eq!(screen_allowed(&none), Ok(()));
    }

    #[test]
    fn the_link_messages_are_tagged_json() {
        let c = LinkCommand {
            id: 3,
            command: Command::OnOff {
                applet: "clock".into(),
                on: true,
            },
        };
        let text = serde_json::to_string(&c).unwrap();
        assert_eq!(
            text,
            r#"{"id":3,"command":{"kind":"on_off","applet":"clock","on":true}}"#
        );
        assert_eq!(serde_json::from_str::<LinkCommand>(&text).unwrap(), c);
        let b: Command =
            serde_json::from_str(r#"{"kind":"brightness","position":40}"#).unwrap();
        assert_eq!(b, Command::Brightness { position: 40 });
        let a: Command =
            serde_json::from_str(r#"{"kind":"advertise","secs":900}"#).unwrap();
        assert_eq!(a, Command::Advertise { secs: 900 });
        assert_eq!(
            serde_json::to_string(&Command::AdvertiseEnd).unwrap(),
            r#"{"kind":"advertise_end"}"#
        );
    }
}
