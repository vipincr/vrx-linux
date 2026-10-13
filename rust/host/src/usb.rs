// A computer on the other end of the board's USB (plan 0008 D11). The
// UDC's `state` reads "configured" once a host has enumerated the gadget;
// on that edge vrxhost raises `sys.usb.connected` and the USB applet
// offers to share files. The kernel tells only through sysfs_notify on
// that attribute (usb_gadget_state_work), never a uevent, so no udev rule
// can see it: this waits for POLLPRI on the file, reading it again after
// each wake. A board without a UDC has nothing to watch.

#[cfg(any(target_os = "linux", test))]
use std::fs::File;
#[cfg(any(target_os = "linux", test))]
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

/// Where the kernel lists UDCs.
pub const UDC_ROOT: &str = "/sys/class/udc";

/// The intent a connection raises.
pub const CONNECTED: &str = "sys.usb.connected";

/// The board's UDC state file, if it has a UDC.
pub fn state_file(root: &Path) -> Option<PathBuf> {
    let mut udcs: Vec<PathBuf> = std::fs::read_dir(root)
        .ok()?
        .flatten()
        .map(|e| e.path().join("state"))
        .filter(|p| p.exists())
        .collect();
    udcs.sort();
    udcs.into_iter().next()
}

/// A host has just finished enumerating the gadget.
pub fn connected(before: &str, now: &str) -> bool {
    now == "configured" && before != "configured"
}

#[cfg(any(target_os = "linux", test))]
fn read_state(mut file: impl Read + Seek) -> std::io::Result<String> {
    let mut text = String::new();
    file.seek(SeekFrom::Start(0))?;
    file.read_to_string(&mut text)?;
    Ok(text.trim().to_owned())
}

/// Watch `state` forever, calling `on_connect` on each connection. The
/// state at start is not an edge: a vrxhost restarted with a cable in
/// does not ask again.
#[cfg(target_os = "linux")]
pub async fn watch(state: PathBuf, mut on_connect: impl FnMut()) -> std::io::Result<()> {
    use tokio::io::unix::AsyncFd;
    use tokio::io::Interest;

    let file = File::open(&state)?;
    let mut before = read_state(&file)?;
    tracing::info!(state = %state.display(), now = %before, "watching the USB device port");
    let fd = AsyncFd::with_interest(file, Interest::PRIORITY)?;
    loop {
        let mut guard = fd.ready(Interest::PRIORITY).await?;
        guard.clear_ready();
        drop(guard);
        let now = read_state(fd.get_ref())?;
        if now != before {
            tracing::info!(from = %before, to = %now, "USB device port");
        }
        if connected(&before, &now) {
            on_connect();
        }
        before = now;
    }
}

/// POLLPRI on a sysfs file is Linux's; a host build (the gate) has no UDC.
#[cfg(not(target_os = "linux"))]
pub async fn watch(_state: PathBuf, _on_connect: impl FnMut()) -> std::io::Result<()> {
    Err(std::io::ErrorKind::Unsupported.into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_the_edge_into_configured_is_a_connection() {
        assert!(connected("addressed", "configured"));
        assert!(connected("not attached", "configured"));
        assert!(!connected("configured", "configured"));
        assert!(!connected("configured", "not attached"));
        assert!(!connected("powered", "default"));
    }

    #[test]
    fn the_first_udc_is_watched_and_none_means_nothing_to_watch() {
        let root = tempfile::tempdir().unwrap();
        assert_eq!(state_file(root.path()), None);
        for name in ["fe980000.usb", "a.usb"] {
            std::fs::create_dir(root.path().join(name)).unwrap();
            std::fs::write(root.path().join(name).join("state"), "not attached\n")
                .unwrap();
        }
        assert_eq!(
            state_file(root.path()),
            Some(root.path().join("a.usb/state"))
        );
        assert_eq!(state_file(Path::new("/nonexistent")), None);
    }

    #[test]
    fn the_state_reads_again_from_the_start() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("state");
        std::fs::write(&path, "configured\n").unwrap();
        let file = File::open(&path).unwrap();
        assert_eq!(read_state(&file).unwrap(), "configured");
        assert_eq!(read_state(&file).unwrap(), "configured");
    }
}
