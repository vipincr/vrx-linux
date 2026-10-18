// The node's layout (plan 0015 D1): which endpoints exist and their ids,
// kept in the state directory so a controller sees the same ids across
// restarts. Endpoint 0 is the root, 1 the screen (when exposed), 2 the
// aggregator, 3 and up one bridged node per exposed applet. An applet
// keeps its id while it stays exposed; a new one takes the next id never
// used before, so a controller never mistakes one applet for another.
//
// The layout is built once at start: vrx-matter restarts when vrxhost's
// exposed set differs from it (main.rs), after bumping the node's
// ConfigurationVersion.

use std::path::Path;

use serde::{Deserialize, Serialize};
use vrx_protocol::manifest::MatterDeviceType;
use vrx_protocol::matter::{Exposed, HostState};

pub const SCREEN: u16 = 1;
pub const AGGREGATOR: u16 = 2;
const FIRST_BRIDGED: u16 = 3;

/// One bridged applet.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Bridged {
    pub id: u16,
    pub applet: String,
    pub name: String,
    pub device_type: MatterDeviceType,
    /// The last On/Off a home app gave it (no applet publishes its own).
    #[serde(default)]
    pub on: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Layout {
    pub screen: bool,
    pub bridged: Vec<Bridged>,
    /// The next id a newly exposed applet takes.
    pub next: u16,
}

impl Default for Layout {
    /// Before vrxhost has said anything: the screen alone (plan 0015 D8).
    fn default() -> Self {
        Self {
            screen: true,
            bridged: Vec::new(),
            next: FIRST_BRIDGED,
        }
    }
}

impl Layout {
    pub const FILE: &'static str = "layout.json";

    /// Loads the layout. A missing file is a first boot (every id is
    /// new). A file that EXISTS but will not parse stops the caller
    /// (CON-10, review 2026-10-17): loading it as empty re-used every
    /// id the file held, which the type promises never happens.
    pub fn load(dir: &Path) -> Result<Self, String> {
        let path = dir.join(Self::FILE);
        match std::fs::read_to_string(&path) {
            Ok(t) => serde_json::from_str(&t)
                .map_err(|e| format!("{}: {e}", path.display())),
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(Self::default()),
            Err(err) => Err(format!("{}: {err}", path.display())),
        }
    }

    /// The old signature where the caller wants first-boot semantics for
    /// an unreadable layout: it must say so itself, never silently.
    pub fn load_or_default(dir: &Path) -> (Self, Option<String>) {
        match Self::load(dir) {
            Ok(l) => (l, None),
            Err(err) => {
                tracing::error!(error = %err, "layout: unreadable; starting from none");
                (Self::default(), Some(err))
            }
        }
    }

    /// Written whole and renamed into place.
    pub fn save(&self, dir: &Path) -> std::io::Result<()> {
        let tmp = dir.join(format!("{}.tmp", Self::FILE));
        std::fs::write(
            &tmp,
            serde_json::to_vec(self).map_err(std::io::Error::other)?,
        )?;
        // fsync before the rename (CON-10): a power cut between the
        // write and the sync leaves an empty layout, which load treats
        // as a first boot and hands every id out again
        let f = std::fs::File::open(&tmp)?;
        f.sync_all()?;
        drop(f);
        std::fs::rename(tmp, dir.join(Self::FILE))
    }

    /// The layout vrxhost's state asks for: kept ids for applets still
    /// exposed, new ids after every id used before.
    pub fn follow(&self, host: &HostState) -> Self {
        let mut next = self.next.max(FIRST_BRIDGED);
        let bridged = host
            .applets
            .iter()
            .map(
                |e: &Exposed| match self.bridged.iter().find(|b| b.applet == e.applet) {
                    Some(b) => Bridged {
                        name: e.name.clone(),
                        device_type: e.device_type,
                        ..b.clone()
                    },
                    None => {
                        let id = next;
                        next = next.saturating_add(1);
                        Bridged {
                            id,
                            applet: e.applet.clone(),
                            name: e.name.clone(),
                            device_type: e.device_type,
                            on: false,
                        }
                    }
                },
            )
            .collect();
        Self {
            screen: host.screen,
            bridged,
            next,
        }
    }

    /// The endpoints differ: a restart is due to rebuild the node.
    pub fn differs(&self, other: &Self) -> bool {
        let shape = |l: &Self| {
            (
                l.screen,
                l.bridged
                    .iter()
                    .map(|b| (b.id, b.applet.clone(), b.name.clone(), b.device_type))
                    .collect::<Vec<_>>(),
            )
        };
        shape(self) != shape(other)
    }

    pub fn bridged_by_endpoint(&self, endpoint: u16) -> Option<&Bridged> {
        self.bridged.iter().find(|b| b.id == endpoint)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn host(screen: bool, applets: &[&str]) -> HostState {
        HostState {
            screen_on: true,
            brightness: 50,
            screen,
            applets: applets
                .iter()
                .map(|a| Exposed {
                    applet: (*a).to_owned(),
                    name: a.to_uppercase(),
                    device_type: MatterDeviceType::OnOffPlug,
                })
                .collect(),
            exposable: Vec::new(),
        }
    }

    /// A controller never sees one applet's id given to another.
    #[test]
    fn ids_are_kept_and_never_reused() {
        let start = Layout::default();
        let a = start.follow(&host(true, &["clock", "recorder"]));
        assert_eq!(
            a.bridged
                .iter()
                .map(|b| (b.applet.as_str(), b.id))
                .collect::<Vec<_>>(),
            [("clock", 3), ("recorder", 4)]
        );
        assert!(a.differs(&start));
        let b = a.follow(&host(true, &["recorder"]));
        assert_eq!(b.bridged[0].id, 4);
        let c = b.follow(&host(true, &["recorder", "clock"]));
        assert_eq!(c.bridged[1].id, 5, "clock comes back as a new device");
        assert!(!c.differs(&c.follow(&host(true, &["recorder", "clock"]))));
        assert!(c.differs(&c.follow(&host(false, &["recorder", "clock"]))));
    }

    #[test]
    fn the_layout_survives_a_restart() {
        let dir = tempfile::tempdir().unwrap();
        {
            let (l, why) = Layout::load_or_default(dir.path());
            assert_eq!(l, Layout::default());
            assert!(why.is_none(), "a missing file is a first boot");
        }
        let mut l = Layout::default().follow(&host(true, &["clock"]));
        l.bridged[0].on = true;
        l.save(dir.path()).unwrap();
        {
            let (got, why) = Layout::load_or_default(dir.path());
            assert_eq!(got, l);
            assert!(why.is_none());
        }
    }
}
