// The applet's side of its systemd unit (plan 0008 D18): READY=1 once the
// applet is usable, and the watchdog. Applet authors write none of this;
// applet_main does it. Both are no-ops outside systemd (no NOTIFY_SOCKET).
//
// The watchdog pings from a thread, but only while the action loop is
// healthy: idle (blocked waiting for the next action) or busy for less
// than half the watchdog interval. A reducer or effect stuck past that
// stops the pings, and systemd kills and restarts the applet, the same
// verdict a hung UI loop gets.

use std::os::unix::net::UnixDatagram;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

/// Send one notification to the service manager, if there is one.
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

/// The action loop's liveness, shared with the watchdog thread.
#[derive(Clone, Debug)]
pub struct Liveness {
    start: Instant,
    /// Milliseconds since `start` when the current action began; 0 = idle.
    busy_since_ms: Arc<AtomicU64>,
}

impl Liveness {
    pub fn new() -> Self {
        Self {
            start: Instant::now(),
            busy_since_ms: Arc::new(AtomicU64::new(0)),
        }
    }

    /// The loop starts handling an action.
    pub fn busy(&self) {
        let now = u64::try_from(self.start.elapsed().as_millis())
            .unwrap_or(u64::MAX)
            .max(1);
        self.busy_since_ms.store(now, Ordering::Relaxed);
    }

    /// The loop finished it and waits for the next.
    pub fn idle(&self) {
        self.busy_since_ms.store(0, Ordering::Relaxed);
    }

    /// Healthy: idle, or busy for less than `limit`.
    pub fn healthy(&self, limit: Duration) -> bool {
        let since = self.busy_since_ms.load(Ordering::Relaxed);
        if since == 0 {
            return true;
        }
        let now = u64::try_from(self.start.elapsed().as_millis()).unwrap_or(u64::MAX);
        Duration::from_millis(now.saturating_sub(since)) < limit
    }

    /// Ping the watchdog at half its interval while the loop is healthy.
    pub fn spawn_watchdog(&self) {
        let Some(interval) = watchdog_interval() else {
            return;
        };
        let liveness = self.clone();
        std::thread::spawn(move || loop {
            // vrx-allow: the watchdog thread's own timer; nothing renders here
            std::thread::sleep(interval / 2);
            if liveness.healthy(interval / 2) {
                notify("WATCHDOG=1");
            }
        });
    }
}

impl Default for Liveness {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn idle_and_short_work_are_healthy_stuck_work_is_not() {
        let l = Liveness::new();
        assert!(l.healthy(Duration::from_millis(50)));
        l.busy();
        assert!(l.healthy(Duration::from_millis(50)));
        std::thread::sleep(Duration::from_millis(80));
        assert!(
            !l.healthy(Duration::from_millis(50)),
            "stuck past the limit"
        );
        l.idle();
        assert!(l.healthy(Duration::from_millis(50)));
    }

    #[test]
    fn notify_without_systemd_is_a_no_op() {
        notify("READY=1");
    }
}
