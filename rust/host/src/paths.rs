// Where vrx lives on the filesystem. The plan's locations are the
// defaults; tests (and a chrooted vrx) override them so nothing in the
// daemon hard-codes a path twice.

use std::path::PathBuf;

/// The filesystem locations vrxhost works with.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VrxPaths {
    /// Built-in applets (shipped by the OS): /system/defaults.
    pub system_defaults: PathBuf,
    /// Installed applets: /usr/lib/vrx/apps, where systemd-sysext merges
    /// each installed applet's image (plan 0011 D16).
    pub apps: PathBuf,
    /// Runtime state (the io.vrx.Host socket, pipes): /run/vrx.
    pub runtime: PathBuf,
}

impl VrxPaths {
    /// The plan's locations.
    pub fn system() -> Self {
        Self {
            system_defaults: PathBuf::from("/system/defaults"),
            apps: PathBuf::from("/usr/lib/vrx/apps"),
            runtime: PathBuf::from("/run/vrx"),
        }
    }

    /// vrxhost's Varlink socket: <runtime>/io.vrx.Host (the interface
    /// name, as systemd names its own Varlink sockets).
    pub fn host_socket(&self) -> PathBuf {
        self.runtime.join(crate::varlink::INTERFACE)
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
