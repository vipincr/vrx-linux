// The host side of the registry: scan the real directories in a
// deterministic order (built-ins first, then installed, each sorted by
// path) and report refusals with the directory that caused them.

use std::path::Path;

use thiserror::Error;
use vrx_protocol::{Registry, RegistryError};

#[derive(Debug, Error)]
pub enum ScanError {
    #[error("while scanning built-ins in {dir}: {source}")]
    Builtins {
        dir: String,
        #[source]
        source: RegistryError,
    },
    #[error("while scanning installed applets in {dir}: {source}")]
    Installed {
        dir: String,
        #[source]
        source: RegistryError,
    },
}

/// The registry every part of vrxhost reads, replaced whole when an
/// install or uninstall changes what is on the system (plan 0011 D16):
/// a reader takes a snapshot (`get`) and keeps using it for its call; a
/// part that follows it (the Matter link's exposed set) hears each
/// replacement (`changes`).
#[derive(Debug, Clone)]
pub struct Shared(std::sync::Arc<tokio::sync::watch::Sender<std::sync::Arc<Registry>>>);

impl Shared {
    pub fn new(registry: Registry) -> Self {
        Self(std::sync::Arc::new(tokio::sync::watch::Sender::new(
            std::sync::Arc::new(registry),
        )))
    }

    /// The registry now.
    pub fn get(&self) -> std::sync::Arc<Registry> {
        self.0.borrow().clone()
    }

    /// Replace it.
    pub fn set(&self, registry: Registry) {
        self.0.send_replace(std::sync::Arc::new(registry));
    }

    /// The registry now, and again on every replacement.
    pub fn changes(&self) -> tokio::sync::watch::Receiver<std::sync::Arc<Registry>> {
        self.0.subscribe()
    }
}

/// Scan both applet roots into one registry: built-ins first (so an
/// installed applet cannot steal a built-in's id), then installed.
pub fn scan(paths: &crate::paths::VrxPaths) -> Result<Registry, ScanError> {
    let mut registry = Registry::new();
    // CON-10 (review 2026-10-17): a built-in image's applets must all be
    // valid or the image is broken (fail loudly). An INSTALLED applet's
    // defect quarantines it — the bad one is named at start and the host
    // boots with the good ones.
    scan_into(&mut registry, &paths.system_defaults, true).map_err(|source| {
        ScanError::Builtins {
            dir: paths.system_defaults.display().to_string(),
            source,
        }
    })?;
    let refused_before = registry.refused.len();
    scan_into(&mut registry, &paths.apps, false).map_err(|source| {
        ScanError::Installed {
            dir: paths.apps.display().to_string(),
            source,
        }
    })?;
    for (id, why) in &registry.refused[refused_before..] {
        tracing::warn!(applet = %id, error = %why, "installed applet refused (quarantined)");
    }
    Ok(registry)
}

fn scan_into(
    registry: &mut Registry,
    dir: &Path,
    builtin: bool,
) -> Result<(), RegistryError> {
    registry.scan_dir(dir, builtin)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::paths::VrxPaths;
    use std::fs;

    fn applet_dir(root: &std::path::Path, id: &str, builtin: bool) {
        let dir = root
            .join(if builtin { "defaults" } else { "apps" })
            .join(id);
        fs::create_dir_all(&dir).expect("mkdir");
        fs::write(
            dir.join("manifest.toml"),
            format!(
                "[applet]\nid = \"{id}\"\nname = \"N\"\nversion = \"0.1.0\"\nruntime = \"rust\"\n"
            ),
        )
        .expect("manifest");
    }

    #[test]
    fn a_missing_root_scans_empty() {
        let paths = VrxPaths {
            system_defaults: "/nonexistent-vrx-1".into(),
            apps: "/nonexistent-vrx-2".into(),
            runtime: "/tmp".into(),
        };
        let registry = scan(&paths).expect("absent roots admit nothing");
        assert!(registry.is_empty());
    }

    #[test]
    fn builtins_win_id_conflicts_against_installed() {
        let tmp = tempfile::tempdir().expect("tmp");
        applet_dir(tmp.path(), "clock", true);
        applet_dir(tmp.path(), "clock", false);
        let paths = VrxPaths {
            system_defaults: tmp.path().join("defaults"),
            apps: tmp.path().join("apps"),
            runtime: "/tmp".into(),
        };
        // the quarantine contract (CON-10, review 2026-10-17): a bad
        // applet is refused by name, the built-in stays, and one conflict
        // stops nothing else
        let registry = scan(&paths).expect("the built-in survives the conflict");
        assert_eq!(registry.len(), 1);
        assert!(registry.find("clock").is_some_and(|e| e.builtin));
        assert_eq!(
            registry.refusals(),
            &[(
                "clock".to_owned(),
                "applet id \"clock\" is already registered".to_owned()
            )],
            "the refusal names the applet and why"
        );
    }
}
