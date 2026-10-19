// The applet's side of its systemd unit (plan 0008 D18): READY=1 once the
// applet is usable, and the watchdog. Applet authors write none of this;
// applet_main does it. Both are no-ops outside systemd (no NOTIFY_SOCKET).
//
// The watchdog pings from a thread, but only while the action loop is
// healthy: idle (blocked waiting for the next action) or busy for less
// than half the watchdog interval. A reducer or effect stuck past that
// stops the pings, and systemd kills and restarts the applet, the same
// verdict a hung UI loop gets.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

// notify and watchdog_interval moved to vrx-wire beside the watcher
// (review 2026-10-17, MOD-09); applet code re-exports them here.
pub use vrx_wire::notify::{notify, watchdog_interval};

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

/// One line to the journal, the SDK's own log path (KRN-04, review
/// 2026-10-17): `log!`-style callers stay on tracing, and the binary
/// installs its subscriber with `tracing_subscriber::fmt().init()` —
/// one mechanism per process.
#[macro_export]
macro_rules! log {
    ($($arg:tt)*) => {
        tracing::info!($($arg)*)
    };
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
