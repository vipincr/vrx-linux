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

// ── the battery (plan 0012 D10) ──────────────────────────────────────────
// Where a battery exists its gauge driver (bq27xxx, max17048, an INA226 by
// ina2xx) puts it in /sys/class/power_supply like any other supply, and
// that is the one source: vrxhost reads it on each change the uevents
// carry (the Limiter above already holds a chatty gauge to one in 10 s).
// evrx-rt's rules, which were paid for:
// - a move of 2 points lands at once, a 1-point move needs two agreeing
//   reads, so a gauge hovering on a boundary does not flap;
// - zones only while discharging, announced once per crossing, and a gauge
//   that cannot be read is never a warning;
// - WARN caps the light at a quarter of the range above the floor without
//   touching the stored setting (the compositor stays the light's owner);
// - CRITICAL is an orderly power-off through logind, said on screen 30 s
//   first, called off if the device goes on a charger meanwhile.
// The thresholds are the board's (`battery warn|critical <percent>` in its
// power profile: a chemistry is a board fact).

/// The battery's zone.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Zone {
    Normal,
    Warn,
    Critical,
}

impl Zone {
    /// As the Facts stream says it: "", "warn", "critical".
    pub fn as_str(self) -> &'static str {
        match self {
            Zone::Normal => "",
            Zone::Warn => "warn",
            Zone::Critical => "critical",
        }
    }
}

/// The board's battery thresholds, in percent.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Thresholds {
    pub warn: u8,
    pub critical: u8,
}

impl Default for Thresholds {
    fn default() -> Self {
        Self {
            warn: 15,
            critical: 5,
        }
    }
}

/// The share of the range above the floor WARN leaves the light (permille).
pub const WARN_CAP: u32 = 250;
/// No cap.
pub const NO_CAP: u32 = 1000;
/// How long CRITICAL says so before powering off.
pub const CRITICAL_GRACE: Duration = Duration::from_secs(30);
/// Leaving a zone needs this many points above its threshold, so a
/// reading on the boundary does not announce it twice.
const ZONE_MARGIN: u8 = 2;

/// One reading of the battery.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Reading {
    /// Percent, 0-100.
    pub capacity: u8,
    /// The kernel says Discharging (not Charging, Full or Not charging).
    pub discharging: bool,
}

/// What a reading asks vrxhost to do.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    /// Cap the light (permille above the floor; NO_CAP lifts it).
    Cap(u32),
    /// The zone or the shown capacity changed: publish it.
    Announce { zone: Zone, capacity: u8 },
    /// Power off after CRITICAL_GRACE, unless called off.
    PowerOffSoon,
    /// The pending power-off is called off (a charger, a reading back up).
    CallOff,
}

/// The battery's rules, pure: readings in, actions out.
#[derive(Debug, Clone)]
pub struct Battery {
    thresholds: Thresholds,
    shown: Option<u8>,
    candidate: Option<u8>,
    zone: Zone,
}

impl Battery {
    pub fn new(thresholds: Thresholds) -> Self {
        Self {
            thresholds,
            shown: None,
            candidate: None,
            zone: Zone::Normal,
        }
    }

    /// The zone now.
    pub fn zone(&self) -> Zone {
        self.zone
    }

    /// Feed one reading.
    pub fn feed(&mut self, r: Reading) -> Vec<Action> {
        let mut out = Vec::new();
        let capacity = r.capacity.min(100);
        let moved = match self.shown {
            None => true,
            Some(s) if s.abs_diff(capacity) >= 2 => true,
            Some(s) if s == capacity => false,
            // one point: only when the read before said the same
            Some(_) => self.candidate == Some(capacity),
        };
        self.candidate = Some(capacity);
        if moved {
            self.shown = Some(capacity);
        }
        let shown = self.shown.unwrap_or(capacity);
        let t = self.thresholds;
        let zone = if !r.discharging {
            Zone::Normal
        } else {
            match self.zone {
                _ if shown <= t.critical => Zone::Critical,
                Zone::Critical if shown <= t.critical.saturating_add(ZONE_MARGIN) => {
                    Zone::Critical
                }
                _ if shown <= t.warn => Zone::Warn,
                Zone::Warn | Zone::Critical
                    if shown <= t.warn.saturating_add(ZONE_MARGIN) =>
                {
                    Zone::Warn
                }
                _ => Zone::Normal,
            }
        };
        if zone != self.zone {
            let was = self.zone;
            self.zone = zone;
            if was == Zone::Critical {
                out.push(Action::CallOff);
            }
            match zone {
                Zone::Normal => out.push(Action::Cap(NO_CAP)),
                Zone::Warn => out.push(Action::Cap(WARN_CAP)),
                Zone::Critical => {
                    if was == Zone::Normal {
                        out.push(Action::Cap(WARN_CAP));
                    }
                    out.push(Action::PowerOffSoon);
                }
            }
        }
        if zone != Zone::Normal || moved {
            out.push(Action::Announce {
                zone,
                capacity: shown,
            });
        }
        out
    }
}

/// The board's thresholds from its power profile files (the family's,
/// then each carrier's): `battery warn <percent>` and
/// `battery critical <percent>`; other lines are other readers'.
pub fn thresholds(files: &[std::path::PathBuf]) -> Thresholds {
    let mut t = Thresholds::default();
    for file in files {
        let Ok(text) = std::fs::read_to_string(file) else {
            continue;
        };
        for line in text.lines() {
            let line = line.split('#').next().unwrap_or("");
            let mut words = line.split_whitespace();
            if words.next() != Some("battery") {
                continue;
            }
            let (Some(which), Some(value)) = (words.next(), words.next()) else {
                continue;
            };
            let Ok(pct) = value.trim_end_matches('%').parse::<u8>() else {
                continue;
            };
            match which {
                "warn" => t.warn = pct.min(100),
                "critical" => t.critical = pct.min(100),
                _ => {}
            }
        }
    }
    if t.critical >= t.warn {
        tracing::warn!(
            ?t,
            "battery thresholds: critical is not below warn; using the defaults"
        );
        return Thresholds::default();
    }
    t
}

/// The profile files: /usr/share/vrx/power-profile, then
/// /usr/share/vrx/power-profile.d/* in name order.
pub fn profile_files(root: &std::path::Path) -> Vec<std::path::PathBuf> {
    let mut files = vec![root.join("power-profile")];
    let mut extra: Vec<_> = std::fs::read_dir(root.join("power-profile.d"))
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.path())
        .collect();
    extra.sort();
    files.extend(extra);
    files
}

/// The first battery under `root` (/sys/class/power_supply) that is
/// present and readable; None when there is none, or its gauge is silent.
pub fn read_battery(root: &std::path::Path) -> Option<Reading> {
    let mut supplies: Vec<_> = std::fs::read_dir(root)
        .ok()?
        .flatten()
        .map(|e| e.path())
        .collect();
    supplies.sort();
    for dir in supplies {
        let read = |name: &str| {
            std::fs::read_to_string(dir.join(name))
                .ok()
                .map(|s| s.trim().to_owned())
        };
        if read("type").as_deref() != Some("Battery")
            || read("present").as_deref() == Some("0")
        {
            continue;
        }
        let Some(capacity) = read("capacity").and_then(|c| c.parse::<u8>().ok()) else {
            continue;
        };
        let discharging = read("status").as_deref() == Some("Discharging");
        return Some(Reading {
            capacity,
            discharging,
        });
    }
    None
}

/// Run the battery's rules: on every power-supply change (`changes`) and
/// once at start. Light caps go to the compositor through `cap`.
pub async fn battery(
    sysfs: std::path::PathBuf,
    profile: std::path::PathBuf,
    mut changes: tokio::sync::mpsc::UnboundedReceiver<()>,
    cap: impl Fn(u32),
) {
    let t = thresholds(&profile_files(&profile));
    let mut rules = Battery::new(t);
    let mut deadline: Option<tokio::time::Instant> = None;
    let mut first = true;
    loop {
        if !first {
            let timeout = async {
                match deadline {
                    Some(at) => tokio::time::sleep_until(at).await,
                    None => std::future::pending().await,
                }
            };
            tokio::select! {
                change = changes.recv() => {
                    if change.is_none() {
                        return;
                    }
                }
                () = timeout => {
                    deadline = None;
                    // still critical and on battery after the grace: off
                    if rules.zone() == Zone::Critical
                        && read_battery(&sysfs).is_some_and(|r| r.discharging)
                    {
                        tracing::warn!("battery critical: powering off");
                        if let Err(err) = crate::energy::power_off().await {
                            tracing::error!(error = %err, "battery critical: power off failed");
                        }
                    }
                    continue;
                }
            }
        }
        first = false;
        let Some(reading) = read_battery(&sysfs) else {
            continue;
        };
        for action in rules.feed(reading) {
            match action {
                Action::Cap(permille) => cap(permille),
                Action::Announce { zone, capacity } => {
                    if zone != Zone::Normal {
                        tracing::info!(zone = zone.as_str(), capacity, "battery");
                    }
                    crate::facts::update(|f| {
                        f.battery = i32::from(capacity);
                        f.battery_zone = zone.as_str().to_owned();
                    });
                }
                Action::PowerOffSoon => {
                    tracing::warn!(
                        capacity = reading.capacity,
                        "battery critical: power off in 30 s"
                    );
                    deadline = Some(tokio::time::Instant::now() + CRITICAL_GRACE);
                }
                Action::CallOff => {
                    tracing::info!("battery: the power-off is called off");
                    deadline = None;
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn r(capacity: u8) -> Reading {
        Reading {
            capacity,
            discharging: true,
        }
    }

    #[test]
    fn a_one_point_move_needs_two_agreeing_reads_and_two_points_land_at_once() {
        let mut b = Battery::new(Thresholds::default());
        assert_eq!(
            b.feed(r(80)),
            [Action::Announce {
                zone: Zone::Normal,
                capacity: 80
            }]
        );
        assert!(b.feed(r(79)).is_empty(), "one point, once: not yet");
        assert_eq!(
            b.feed(r(79)),
            [Action::Announce {
                zone: Zone::Normal,
                capacity: 79
            }],
            "the second agreeing read lands it"
        );
        assert!(b.feed(r(80)).is_empty(), "hovering back is not news");
        assert_eq!(
            b.feed(r(77)),
            [Action::Announce {
                zone: Zone::Normal,
                capacity: 77
            }]
        );
    }

    #[test]
    fn warn_caps_the_light_once_and_charging_lifts_it() {
        let mut b = Battery::new(Thresholds::default());
        b.feed(r(20));
        let a = b.feed(r(15));
        assert!(a.contains(&Action::Cap(WARN_CAP)), "{a:?}");
        assert!(a.contains(&Action::Announce {
            zone: Zone::Warn,
            capacity: 15
        }));
        assert!(
            !b.feed(r(15)).contains(&Action::Cap(WARN_CAP)),
            "announced once per crossing"
        );
        assert!(
            !b.feed(r(16)).iter().any(|a| matches!(a, Action::Cap(_))),
            "16 is inside the margin: still warn"
        );
        let a = b.feed(Reading {
            capacity: 16,
            discharging: false,
        });
        assert!(
            a.contains(&Action::Cap(NO_CAP)),
            "a charger lifts it: {a:?}"
        );
        assert_eq!(b.zone(), Zone::Normal);
    }

    #[test]
    fn critical_powers_off_soon_and_a_charger_calls_it_off() {
        let mut b = Battery::new(Thresholds::default());
        b.feed(r(12));
        let a = b.feed(r(5));
        assert!(a.contains(&Action::PowerOffSoon), "{a:?}");
        let a = b.feed(Reading {
            capacity: 5,
            discharging: false,
        });
        assert!(a.contains(&Action::CallOff), "{a:?}");
        assert!(a.contains(&Action::Cap(NO_CAP)));
    }

    #[test]
    fn charging_at_5_percent_does_nothing_and_a_silent_gauge_is_no_warning() {
        let mut b = Battery::new(Thresholds::default());
        let a = b.feed(Reading {
            capacity: 5,
            discharging: false,
        });
        assert_eq!(
            a,
            [Action::Announce {
                zone: Zone::Normal,
                capacity: 5
            }]
        );
        let dir = std::env::temp_dir().join(format!("vrx-bat-{}", std::process::id()));
        let bat = dir.join("BAT0");
        std::fs::create_dir_all(&bat).unwrap();
        std::fs::write(bat.join("type"), "Battery\n").unwrap();
        std::fs::write(bat.join("status"), "Discharging\n").unwrap();
        assert_eq!(read_battery(&dir), None, "no capacity: silent, not empty");
        std::fs::write(bat.join("capacity"), "42\n").unwrap();
        assert_eq!(read_battery(&dir), Some(r(42)));
        let ac = dir.join("AC");
        std::fs::create_dir_all(&ac).unwrap();
        std::fs::write(ac.join("type"), "Mains\n").unwrap();
        assert_eq!(
            read_battery(&dir),
            Some(r(42)),
            "a charger is not a battery"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_thresholds_are_the_boards_and_a_bad_pair_falls_back() {
        let dir = std::env::temp_dir().join(format!("vrx-thr-{}", std::process::id()));
        std::fs::create_dir_all(dir.join("power-profile.d")).unwrap();
        std::fs::write(
            dir.join("power-profile"),
            "model floor 900 measured=2026-10-14 meter=fnb58\nbattery warn 20\n",
        )
        .unwrap();
        std::fs::write(
            dir.join("power-profile.d/carrier"),
            "battery critical 8%  # a LiPo\n",
        )
        .unwrap();
        assert_eq!(
            thresholds(&profile_files(&dir)),
            Thresholds {
                warn: 20,
                critical: 8
            }
        );
        std::fs::write(dir.join("power-profile.d/carrier"), "battery critical 30\n")
            .unwrap();
        assert_eq!(thresholds(&profile_files(&dir)), Thresholds::default());
        let _ = std::fs::remove_dir_all(&dir);
    }

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
