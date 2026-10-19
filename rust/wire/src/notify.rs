//! The systemd notify protocol, moved from the applet SDK beside the
//! watcher it travels with (review 2026-10-17, MOD-09): a daemon's
//! READY=1 and its watchdog interval are daemon plumbing, not applet-SDK
//! surface, and vrxhost linked the SDK for them. The SDK re-exports both;
//! applet code is unchanged.

use std::os::unix::net::UnixDatagram;
use std::time::Duration;

/// Send one notification to the service manager, if there is one. A
/// no-op outside systemd (no NOTIFY_SOCKET).
pub fn notify(state: &str) {
    let Some(path) = std::env::var_os("NOTIFY_SOCKET") else {
        return;
    };
    let Ok(socket) = UnixDatagram::unbound() else {
        return;
    };
    let path = path.to_string_lossy().into_owned();
    let sent = if let Some(name) = path.strip_prefix('@') {
        abstract_send(&socket, name, state)
    } else {
        socket.send_to(state.as_bytes(), &path).map(|_| ())
    };
    if let Err(err) = sent {
        tracing::debug!(error = %err, "sd_notify failed");
    }
}

#[cfg(target_os = "linux")]
fn abstract_send(socket: &UnixDatagram, name: &str, state: &str) -> std::io::Result<()> {
    use std::os::linux::net::SocketAddrExt;
    let addr = std::os::unix::net::SocketAddr::from_abstract_name(name.as_bytes())?;
    socket.send_to_addr(state.as_bytes(), &addr).map(|_| ())
}

#[cfg(not(target_os = "linux"))]
fn abstract_send(_: &UnixDatagram, _: &str, _: &str) -> std::io::Result<()> {
    Ok(())
}

/// The watchdog interval systemd asked for (WATCHDOG_USEC), if any, and
/// only when it is meant for this process (WATCHDOG_PID, when set).
pub fn watchdog_interval() -> Option<Duration> {
    if let Some(pid) = std::env::var_os("WATCHDOG_PID") {
        if pid.to_string_lossy() != std::process::id().to_string() {
            return None;
        }
    }
    let usec: u64 = std::env::var("WATCHDOG_USEC").ok()?.parse().ok()?;
    (usec > 0).then(|| Duration::from_micros(usec))
}
