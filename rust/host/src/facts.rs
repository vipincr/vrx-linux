// System facts that change, for applets to hear rather than poll (plan
// 0012 D6). Each is watched here once, by the kernel's own notification:
// the USB device port's state by POLLPRI on the UDC (usb.rs), the
// backlight's level by its `change` uevent (power.rs), the supply alarm
// by POLLPRI on rpi_volt's attribute (supply.rs), the screen's state by
// the compositor's own report (compositor.rs, plan 0015 D12), who
// advertises on Bluetooth by the arbiter's decision (bt_arbiter.rs), the
// devices plugged into the board by the kernel's uevents (usb.rs, plan
// 0019 D7). `io.vrx.Host.Facts`
// streams them; the kit reads sysfs again when one moves, where it read
// every second before.
//
// One process-wide channel: every watcher writes it from its own module
// and every Facts call subscribes, with no plumbing through the daemon's
// wiring. A value nobody watches costs nothing (a watch channel keeps the
// latest only).

use std::sync::OnceLock;

use serde::Serialize;
use tokio::sync::watch;

/// What `Facts` reports.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Facts {
    /// The USB device port's UDC state ("configured" once a computer has
    /// enumerated the gadget); empty on a board with no UDC.
    pub usb: String,
    /// The supply is below the board's alarm (rpi_volt's
    /// in0_lcrit_alarm); false where there is no such alarm.
    pub supply_low: bool,
    /// Counts changes to the backlight's level: the kit reads sysfs again
    /// when it moves. 0 until the first change.
    pub backlight: u64,
    /// The battery's charge in percent, as shown (plan 0012 D10's
    /// hysteresis); -1 where there is no battery.
    pub battery: i32,
    /// "", "warn" or "critical": the battery's zone while discharging.
    pub battery_zone: String,
    /// The earliest time (unix seconds) an applet asked the system to wake
    /// for (plan 0012 D15, Clock's next alarm); 0 = none.
    pub next_wake: u64,
    /// The profiler's runtime switch is on (plan 0014 D1): the kit
    /// aggregates frame timings and sends them.
    pub profiling: bool,
    /// The screen is lit, as the compositor reports it (plan 0015 D12);
    /// false headless.
    pub screen_on: bool,
    /// The brightness as the slider's position, 0 to 100, from the
    /// compositor; -1 where the screen cannot dim (or none has said).
    pub brightness: i32,
    /// Who holds the Bluetooth adapter's advertising (plan 0015 D4, the
    /// arbiter): "", "device-link" or "matter".
    pub advertising: String,
    /// The devices plugged into the board's USB host ports (plan 0019
    /// D7); empty on a board with none.
    pub usb_devices: Vec<crate::usb::Device>,
    /// "none" (no host ports), "open", "allowlist", or "failed" (the
    /// allow-list's daemon is not running: nothing new is authorised).
    pub usb_policy: String,
    /// What the image declared (plan 0019 D12): the host ports' labels,
    /// whether their power is switched ("unswitched", "switched",
    /// "unknown") and whether an overload is reported ("none",
    /// "reported", "unknown").
    pub usb_ports: Vec<String>,
    pub usb_vbus: String,
    pub usb_overcurrent: String,
    /// "Allow new USB devices" as vrxhost last set it (plan 0019 D11);
    /// true until someone switches it off.
    pub usb_allow_new: bool,
}

impl Default for Facts {
    fn default() -> Self {
        Self {
            usb: String::new(),
            supply_low: false,
            backlight: 0,
            battery: -1,
            battery_zone: String::new(),
            next_wake: 0,
            profiling: false,
            screen_on: false,
            brightness: -1,
            advertising: String::new(),
            usb_devices: Vec::new(),
            usb_policy: "none".to_owned(),
            usb_ports: Vec::new(),
            usb_vbus: String::new(),
            usb_overcurrent: String::new(),
            usb_allow_new: true,
        }
    }
}

fn channel() -> &'static watch::Sender<Facts> {
    static CHANNEL: OnceLock<watch::Sender<Facts>> = OnceLock::new();
    CHANNEL.get_or_init(|| watch::channel(Facts::default()).0)
}

/// The facts now, and on every change.
pub fn subscribe() -> watch::Receiver<Facts> {
    channel().subscribe()
}

/// Change the facts; subscribers hear only a real change.
pub fn update(change: impl FnOnce(&mut Facts)) {
    channel().send_if_modified(|facts| {
        let before = facts.clone();
        change(facts);
        *facts != before
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn a_change_is_heard_and_a_non_change_is_not() {
        let mut rx = subscribe();
        rx.borrow_and_update();
        update(|f| f.usb = "configured".into());
        assert!(rx.has_changed().unwrap());
        assert_eq!(rx.borrow_and_update().usb, "configured");
        update(|f| f.usb = "configured".into());
        assert!(!rx.has_changed().unwrap(), "the same value is not news");
        update(|f| f.backlight += 1);
        assert!(rx.has_changed().unwrap());
    }
}

/// Read the facts other processes own, once at start (CON-04, review
/// 2026-10-17): the wake timer systemd is already holding, and
/// USBGuard's allow-new switch where it runs. Unknown stays unknown —
/// neither is defaulted to a guess here.
pub async fn seed_owned() -> Result<(), String> {
    let conn = zbus::Connection::system().await.map_err(|e| e.to_string())?;
    // systemd's timers: the earliest NextElapseUSRtc the bus names
    #[zbus::proxy(
        interface = "org.freedesktop.systemd1.Manager",
        default_service = "org.freedesktop.systemd1",
        default_path = "/org/freedesktop/systemd1"
    )]
    trait Systemd {
        #[zbus(property)]
        fn timers_property(&self) -> zbus::Result<Vec<zbus::zvariant::OwnedObjectPath>>;
    }
    // USBGuard's switch, when it runs (usbguard-daemon's DBus interface)
    #[zbus::proxy(
        interface = "org.usbguard1",
        default_service = "org.usbguard1",
        default_path = "/org/usbguard1"
    )]
    trait UsbGuard {
        #[zbus(property)]
        fn implicit_policy_target(&self) -> zbus::Result<String>;
    }

    let systemd = SystemdProxy::new(&conn).await.map_err(|e| e.to_string())?;
    if let Ok(paths) = systemd.timers_property().await {
        // each timer unit's monotonic next elapse is a property; asking
        // every unit is the honest read, and none means no wake
        let mut earliest: Option<u64> = None;
        for path in paths {
            let Ok(introspect) = zbus::Proxy::new(
                &conn,
                "org.freedesktop.systemd1",
                path,
                "org.freedesktop.systemd1.Timer",
            )
            .await
            else {
                continue;
            };
            let next: Result<i64, _> = introspect.get_property("NextElapseUSecMonotonic").await;
            if let Ok(us) = next {
                if us > 0 {
                    earliest = Some(earliest.map_or(us as u64, |e: u64| e.min(us as u64)));
                }
            }
        }
        let next = earliest.unwrap_or(0);
        update(|f| f.next_wake = next);
        tracing::debug!(next, "facts: next wake seeded from systemd");
    }

    let guard = UsbGuardProxy::new(&conn).await;
    if let Ok(guard) = guard {
        if let Ok(target) = guard.implicit_policy_target().await {
            // allow when USBGuard's implicit target allows what is listed
            let allow = target != "block";
            update(|f| f.usb_allow_new = allow);
            tracing::debug!(target = %target, "facts: usb_allow_new seeded from USBGuard");
        }
    }
    Ok(())
}
