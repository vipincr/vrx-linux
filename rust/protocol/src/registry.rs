// The registry: what vrxhost knows about the applets on the system.
//
// Built-ins live under /system/defaults; installed applets under /apps.
// Admission enforces the rules both directories share: one id per
// system, roles only on built-ins, and the priority bands (built-in
// handlers 500-999, installed 0-499 — a card app can never be asked
// before a built-in).

use std::path::PathBuf;

use crate::manifest::{Manifest, PRIORITY_BUILTIN_MIN};

/// An admitted applet: its manifest, its directory, and whether it is
/// a built-in (shipped by the OS) or installed (added later).
#[derive(Debug, Clone, PartialEq)]
pub struct RegistryEntry {
    pub manifest: Manifest,
    pub path: PathBuf,
    pub builtin: bool,
}

/// An admission refusal, with the rule that refused it.
#[derive(Debug, thiserror::Error, PartialEq)]
pub enum RegistryError {
    #[error("applet id {0:?} is already registered")]
    DuplicateId(String),
    #[error("applet id {0:?}: roles are held by built-ins only (home/shell/installs/resident declared on an installed applet)")]
    RoleOnInstalled(String),
    #[error("applet id {0:?}: system grants are held by built-ins only (permissions.system declared on an installed applet)")]
    SystemOnInstalled(String),
    #[error("applet id {id:?}: installed applets hold handler priorities 0-{below}, got {got}")]
    PriorityBand { id: String, below: u16, got: u16 },
    #[error("applet id {0:?}: manifest invalid: {1}")]
    Invalid(String, String),
}

/// The set of applets vrxhost will consider. Order of admission is
/// kept; lookups are by id.
#[derive(Debug, Default, PartialEq)]
pub struct Registry {
    entries: Vec<RegistryEntry>,
}

impl Registry {
    pub fn new() -> Self {
        Self::default()
    }

    /// Admit an entry, enforcing the shared rules.
    pub fn admit(&mut self, entry: RegistryEntry) -> Result<(), RegistryError> {
        let id = entry.manifest.applet.id.clone();
        entry
            .manifest
            .validate()
            .map_err(|e| RegistryError::Invalid(id.clone(), e.to_string()))?;

        if self.entries.iter().any(|e| e.manifest.applet.id == id) {
            return Err(RegistryError::DuplicateId(id));
        }
        if !entry.builtin {
            if entry.manifest.applet.roles.any() {
                return Err(RegistryError::RoleOnInstalled(id));
            }
            if !entry.manifest.applet.permissions.system.is_empty() {
                return Err(RegistryError::SystemOnInstalled(id));
            }
            for handle in &entry.manifest.applet.intents.handles {
                if handle.priority >= PRIORITY_BUILTIN_MIN {
                    return Err(RegistryError::PriorityBand {
                        id,
                        below: PRIORITY_BUILTIN_MIN - 1,
                        got: handle.priority,
                    });
                }
            }
        }
        self.entries.push(entry);
        Ok(())
    }

    /// Scan a directory of applet directories (each holding a
    /// manifest.toml), admitting each in sorted path order so the
    /// registry is deterministic across boots.
    pub fn scan_dir(
        &mut self,
        root: &std::path::Path,
        builtin: bool,
    ) -> Result<(), RegistryError> {
        let mut dirs: Vec<PathBuf> = match std::fs::read_dir(root) {
            Ok(read) => read
                .filter_map(|e| e.ok().map(|e| e.path()))
                .filter(|p| p.is_dir())
                .collect(),
            Err(_) => return Ok(()), // an absent directory admits nothing
        };
        dirs.sort();
        for dir in dirs {
            let manifest_path = dir.join("manifest.toml");
            let Ok(text) = std::fs::read_to_string(&manifest_path) else {
                continue; // a directory without a manifest is not an applet
            };
            let manifest = text.parse::<Manifest>().map_err(|e| {
                RegistryError::Invalid(dir.display().to_string(), e.to_string())
            })?;
            self.admit(RegistryEntry {
                manifest,
                path: dir,
                builtin,
            })?;
        }
        Ok(())
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    pub fn iter(&self) -> impl Iterator<Item = &RegistryEntry> {
        self.entries.iter()
    }

    pub fn find(&self, id: &str) -> Option<&RegistryEntry> {
        self.entries.iter().find(|e| e.manifest.applet.id == id)
    }

    /// Handlers for an intent across all applets, in asking order:
    /// priority descending, built-ins first at equal priority.
    pub fn handlers_for(&self, intent: &str) -> Vec<&RegistryEntry> {
        let mut handlers: Vec<&RegistryEntry> = self
            .entries
            .iter()
            .filter(|e| {
                e.manifest
                    .applet
                    .intents
                    .handles
                    .iter()
                    .any(|h| h.name == intent)
            })
            .collect();
        handlers.sort_by(|a, b| {
            let pa = a
                .manifest
                .applet
                .intents
                .handles
                .iter()
                .find(|h| h.name == intent)
                .map_or(0, |h| h.priority);
            let pb = b
                .manifest
                .applet
                .intents
                .handles
                .iter()
                .find(|h| h.name == intent)
                .map_or(0, |h| h.priority);
            pb.cmp(&pa)
                .then(b.builtin.cmp(&a.builtin))
                .then(a.manifest.applet.id.cmp(&b.manifest.applet.id))
        });
        handlers
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(id: &str, builtin: bool) -> RegistryEntry {
        RegistryEntry {
            manifest: format!(
                "[applet]\nid = \"{id}\"\nname = \"N\"\nversion = \"0.1.0\"\nruntime = \"rust\"\n"
            )
            .parse()
            .expect("minimal manifest"),
            path: PathBuf::from(format!("/apps/{id}")),
            builtin,
        }
    }

    #[test]
    fn duplicate_ids_are_refused() {
        let mut r = Registry::new();
        r.admit(entry("clock", false)).expect("first admits");
        assert_eq!(
            r.admit(entry("clock", false)),
            Err(RegistryError::DuplicateId("clock".into()))
        );
    }

    #[test]
    fn roles_on_installed_are_refused() {
        let mut e = entry("shell", false);
        e.manifest.applet.roles.shell = true;
        assert_eq!(
            r_admit(e),
            Err(RegistryError::RoleOnInstalled("shell".into()))
        );
    }

    #[test]
    fn system_grants_are_built_in_only() {
        let mut e = entry("wifi", false);
        e.manifest.applet.permissions.system = vec![crate::SystemGrant::Network];
        assert_eq!(
            r_admit(e.clone()),
            Err(RegistryError::SystemOnInstalled("wifi".into()))
        );
        e.builtin = true;
        assert_eq!(r_admit(e), Ok(()));
    }

    #[test]
    fn a_system_grant_parses_and_an_unknown_one_is_named() {
        let ok: crate::Manifest = "[applet]\nid = \"wifi\"\nname = \"Wi-Fi\"\nversion = \"1\"\nruntime = \"flutter\"\n[applet.permissions]\nsystem = [\"network\", \"time\"]\n".parse().expect("parses");
        assert_eq!(
            ok.applet.permissions.system,
            vec![crate::SystemGrant::Network, crate::SystemGrant::Time]
        );
        let bad = "[applet]\nid = \"wifi\"\nname = \"Wi-Fi\"\nversion = \"1\"\nruntime = \"flutter\"\n[applet.permissions]\nsystem = [\"root\"]\n".parse::<crate::Manifest>();
        assert!(bad.is_err_and(|e| e.to_string().contains("root")));
    }

    #[test]
    fn roles_on_builtins_are_allowed() {
        let mut e = entry("launcher", true);
        e.manifest.applet.roles.home = true;
        let mut r = Registry::new();
        r.admit(e).expect("built-ins may hold roles");
    }

    #[test]
    fn installed_applets_cannot_take_builtin_priorities() {
        let mut e = entry("card", false);
        e.manifest.applet.intents.handles = vec![crate::manifest::HandleDecl {
            name: "sys.alarm.ring".into(),
            priority: 700,
            at: None,
        }];
        let mut r = Registry::new();
        assert!(matches!(
            r.admit(e),
            Err(RegistryError::PriorityBand { .. })
        ));
    }

    #[test]
    fn handlers_are_asked_priority_desc_then_builtins_first() {
        let mut r = Registry::new();
        // card: installed, priority 100. clock: builtin, priority 900.
        let mut card = entry("card", false);
        card.manifest.applet.intents.handles = vec![crate::manifest::HandleDecl {
            name: "sys.alarm.ring".into(),
            priority: 100,
            at: None,
        }];
        let mut clock = entry("clock", true);
        clock.manifest.applet.intents.handles = vec![crate::manifest::HandleDecl {
            name: "sys.alarm.ring".into(),
            priority: 900,
            at: None,
        }];
        r.admit(card).expect("admits");
        r.admit(clock).expect("admits");
        let order: Vec<&str> = r
            .handlers_for("sys.alarm.ring")
            .iter()
            .map(|e| e.manifest.applet.id.as_str())
            .collect();
        assert_eq!(order, ["clock", "card"]);
    }

    #[test]
    fn an_empty_or_absent_directory_admits_nothing() {
        let mut r = Registry::new();
        r.scan_dir(std::path::Path::new("/nonexistent-vrx-test"), false)
            .expect("absent dir is not an error");
        assert!(r.is_empty());
    }

    fn r_admit(e: RegistryEntry) -> Result<(), RegistryError> {
        let mut r = Registry::new();
        r.admit(e)
    }
}
