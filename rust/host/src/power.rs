// The kernel's power supplies (plan 0011 D12): a battery's charge and a
// charger's presence live in /sys/class/power_supply, where the kit reads
// them; what sysfs cannot do is say when they change. The kernel does,
// as a `change` uevent on the power_supply class, which vrxhost hears on
// the kobject-uevent netlink socket and relays as `sys.power.changed`
// (payload: the supply's name), so an applet showing the battery reads
// sysfs again instead of polling it. No supply, no events, nothing sent.
//
// A fuel gauge may send a change every few seconds; each raise asks the
// handlers in turn, so a supply raises at most once in MIN_GAP: the first
// change at once, later ones at the end of the gap, never dropped (plan
// 0012 D6, evrx-rt's BATTERY_NOTIFY_MIN_MS). The same socket carries the
// backlight's `change` (its level was written), published as a fact so
// the kit reads the level again instead of every second (facts.rs).

use std::collections::HashMap;
use std::time::{Duration, Instant};

/// The intent a supply's change raises.
pub const CHANGED: &str = "sys.power.changed";

/// The shortest time between two raises for one supply.
pub const MIN_GAP: Duration = Duration::from_secs(10);

/// What a kernel uevent says, of the ones vrxhost hears.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Uevent {
    /// A power supply changed: its name.
    Supply(String),
    /// A backlight's level was written.
    Backlight,
}

/// A kernel uevent, if it is a power_supply or backlight `change`: the
/// message is `change@<devpath>` then NUL-separated KEY=value lines.
pub fn uevent(message: &[u8]) -> Option<Uevent> {
    let mut fields = message.split(|b| *b == 0).filter(|f| !f.is_empty());
    let header = std::str::from_utf8(fields.next()?).ok()?;
    if !header.starts_with("change@") {
        return None;
    }
    let (mut subsystem, mut name) = (None, None);
    for field in fields {
        let Ok(field) = std::str::from_utf8(field) else {
            continue;
        };
        if let Some(v) = field.strip_prefix("SUBSYSTEM=") {
            subsystem = Some(v);
        } else if let Some(v) = field.strip_prefix("POWER_SUPPLY_NAME=") {
            name = Some(v.to_owned());
        }
    }
    match subsystem? {
        "power_supply" => name.map(Uevent::Supply),
        "backlight" => Some(Uevent::Backlight),
        _ => None,
    }
}

/// At most one raise per supply in MIN_GAP: the first change at once,
/// the rest deferred to the end of the gap (one pending per supply), none
/// dropped.
#[derive(Debug, Default)]
pub struct Limiter {
    last: HashMap<String, Instant>,
    pending: HashMap<String, Instant>,
}

impl Limiter {
    /// `supply` changed at `now`: true to raise it now; otherwise it
    /// waits for [`Limiter::due`].
    pub fn change(&mut self, supply: &str, now: Instant) -> bool {
        match self.last.get(supply) {
            Some(&at) if now < at + MIN_GAP => {
                self.pending
                    .entry(supply.to_owned())
                    .or_insert(at + MIN_GAP);
                false
            }
            _ => {
                self.last.insert(supply.to_owned(), now);
                true
            }
        }
    }

    /// When the earliest deferred raise is due.
    pub fn next_due(&self) -> Option<Instant> {
        self.pending.values().min().copied()
    }

    /// The deferred raises due at `now`, counted as raised.
    pub fn due(&mut self, now: Instant) -> Vec<String> {
        let mut ready: Vec<String> = self
            .pending
            .iter()
            .filter(|(_, at)| **at <= now)
            .map(|(s, _)| s.clone())
            .collect();
        ready.sort();
        for supply in &ready {
            self.pending.remove(supply);
            self.last.insert(supply.clone(), now);
        }
        ready
    }
}

/// Listen to the kernel's uevents forever, calling `on_change` with each
/// power supply that changed (limited by [`Limiter`]) and publishing each
/// backlight change as a fact.
#[cfg(target_os = "linux")]
pub async fn watch(mut on_change: impl FnMut(String)) -> std::io::Result<()> {
    use rustix::net::{
        bind, netlink, socket_with, AddressFamily, SocketFlags, SocketType,
    };
    use tokio::io::unix::AsyncFd;

    let sock = socket_with(
        AddressFamily::NETLINK,
        SocketType::DGRAM,
        SocketFlags::CLOEXEC | SocketFlags::NONBLOCK,
        Some(netlink::KOBJECT_UEVENT),
    )?;
    // multicast group 1: the kernel's own uevents (udev re-sends on 2)
    bind(&sock, &netlink::SocketAddrNetlink::new(0, 1))?;
    let fd = AsyncFd::new(sock)?;
    let mut buf = vec![0u8; 8192];
    let mut limiter = Limiter::default();
    loop {
        let due = limiter.next_due();
        let deferred = async {
            match due {
                Some(at) => tokio::time::sleep_until(at.into()).await,
                None => std::future::pending().await,
            }
        };
        tokio::select! {
            ready = fd.readable() => {
                let mut guard = ready?;
                match guard.try_io(|s| {
                    rustix::io::read(s.get_ref(), &mut buf[..]).map_err(std::io::Error::from)
                }) {
                    Ok(Ok(n)) => match uevent(&buf[..n]) {
                        Some(Uevent::Supply(supply)) => {
                            if limiter.change(&supply, Instant::now()) {
                                on_change(supply);
                            }
                        }
                        Some(Uevent::Backlight) => crate::facts::update(|f| f.backlight += 1),
                        None => {}
                    },
                    Ok(Err(err)) => return Err(err),
                    Err(_would_block) => {}
                }
            }
            () = deferred => {
                for supply in limiter.due(Instant::now()) {
                    on_change(supply);
                }
            }
        }
    }
}

/// Uevents are Linux's; a host build (the gate) has none.
#[cfg(not(target_os = "linux"))]
pub async fn watch(_on_change: impl FnMut(String)) -> std::io::Result<()> {
    Err(std::io::ErrorKind::Unsupported.into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_power_supply_change_names_its_supply_and_a_backlight_change_is_told() {
        let msg = b"change@/devices/platform/battery/power_supply/BAT0\0ACTION=change\0\
                    DEVPATH=/devices/platform/battery/power_supply/BAT0\0SUBSYSTEM=power_supply\0\
                    POWER_SUPPLY_NAME=BAT0\0POWER_SUPPLY_CAPACITY=81\0";
        assert_eq!(uevent(msg), Some(Uevent::Supply("BAT0".into())));
        let add = b"add@/devices/x/power_supply/AC\0ACTION=add\0SUBSYSTEM=power_supply\0POWER_SUPPLY_NAME=AC\0";
        assert_eq!(uevent(add), None, "only changes");
        let light =
            b"change@/devices/x/backlight/b\0ACTION=change\0SUBSYSTEM=backlight\0SOURCE=sysfs\0";
        assert_eq!(uevent(light), Some(Uevent::Backlight));
        let other = b"change@/devices/x/net/wlan0\0ACTION=change\0SUBSYSTEM=net\0";
        assert_eq!(uevent(other), None);
        assert_eq!(
            uevent(b"libudev\0\xfe"),
            None,
            "udev's binary header is not ours"
        );
    }

    #[test]
    fn a_gauge_changing_every_2_s_raises_once_in_10_s_and_the_last_change_is_kept() {
        let t0 = Instant::now();
        let mut l = Limiter::default();
        assert!(l.change("BAT0", t0), "the first change at once");
        assert_eq!(l.next_due(), None);
        for s in [2, 4, 6, 8] {
            assert!(!l.change("BAT0", t0 + Duration::from_secs(s)));
        }
        assert_eq!(l.next_due(), Some(t0 + MIN_GAP), "one deferred raise");
        assert!(l.due(t0 + Duration::from_secs(9)).is_empty());
        assert_eq!(l.due(t0 + MIN_GAP), ["BAT0"], "never dropped");
        assert_eq!(l.next_due(), None);
        assert!(
            !l.change("BAT0", t0 + Duration::from_secs(12)),
            "a gap from the deferred raise"
        );
        assert!(
            l.change("AC", t0 + Duration::from_secs(12)),
            "another supply is its own"
        );
        assert_eq!(l.due(t0 + Duration::from_secs(20)), ["BAT0"]);
    }
}
