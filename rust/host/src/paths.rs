// Where vrx lives on the filesystem. The plan's locations are the
// defaults; tests (and a chrooted vrx) override them so nothing in the
// daemon hard-codes a path twice.

use std::path::PathBuf;

/// The filesystem locations vrxhost works with.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VrxPaths {
    /// Built-in applets (shipped by the OS): /system/defaults.
    pub system_defaults: PathBuf,
    /// Installed applets: /apps.
    pub apps: PathBuf,
    /// Runtime state (the intent socket, pipes): /tmp/vrx.
    pub runtime: PathBuf,
}

impl VrxPaths {
    /// The plan's locations.
    pub fn system() -> Self {
        Self {
            system_defaults: PathBuf::from("/system/defaults"),
            apps: PathBuf::from("/apps"),
            runtime: PathBuf::from("/tmp/vrx"),
        }
    }

    /// The intent socket path: <runtime>/vrx.sock.
    pub fn intent_socket(&self) -> PathBuf {
        self.runtime.join("vrx.sock")
    }

    /// The pipes directory: <runtime>/pipes.
    pub fn pipes(&self) -> PathBuf {
        self.runtime.join("pipes")
    }
}

impl Default for VrxPaths {
    fn default() -> Self {
        Self::system()
    }
}
