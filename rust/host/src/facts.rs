// System facts that change, for applets to hear rather than poll (plan
// 0012 D6). Each is watched here once, by the kernel's own notification:
// the USB device port's state by POLLPRI on the UDC (usb.rs), the
// backlight's level by its `change` uevent (power.rs), the supply alarm
// by POLLPRI on rpi_volt's attribute (supply.rs). `io.vrx.Host.Facts`
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
