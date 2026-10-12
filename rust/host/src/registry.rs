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

/// Scan both applet roots into one registry: built-ins first (so an
/// installed applet cannot steal a built-in's id), then installed.
pub fn scan(paths: &crate::paths::VrxPaths) -> Result<Registry, ScanError> {
    let mut registry = Registry::new();
    scan_into(&mut registry, &paths.system_defaults, true).map_err(|source| {
        ScanError::Builtins {
            dir: paths.system_defaults.display().to_string(),
            source,
        }
    })?;
    scan_into(&mut registry, &paths.apps, false).map_err(|source| {
        ScanError::Installed {
            dir: paths.apps.display().to_string(),
            source,
        }
    })?;
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
        let err = scan(&paths).expect_err("duplicate id must refuse");
        assert!(
            err.to_string().contains("apps"),
            "the refusing dir is named: {err}"
        );
    }
}
