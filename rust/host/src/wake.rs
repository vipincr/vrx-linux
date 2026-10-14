// Waking the system for an applet (plan 0012 D15): Clock's next alarm or
// timer must ring through a sleep. Linux has the mechanism, so vrx builds
// none: a systemd timer with WakeSystem=yes arms CLOCK_REALTIME_ALARM,
// which the kernel carries through suspend in the RTC. vrxhost creates one
// transient timer per applet, `vrx-wake@<applet>.timer`, for the time the
// applet asks (io.vrx.Host.WakeAt, for applets holding the `time` grant:
// "alarms and timers" are already its meaning). The timer starts
// vrx-wake@<applet>.service, which does nothing: waking is the point, and
// the applet rings on its own when told it resumed (lifecycle). Before a
// halt, vrx-wakealarm.service writes the earliest of these timers into the
// RTC's wakealarm, so a board whose deep sleep is a halt (the CM5) boots
// for it. A board with no RTC keeps the timers and simply cannot wake.
// Transient units end at a reboot; an applet asks again when it starts.

use std::collections::BTreeMap;
use std::sync::{Mutex, OnceLock};

/// The timer for `applet`.
pub fn unit_name(applet: &str) -> String {
    format!("vrx-wake@{applet}.timer")
}

/// A systemd calendar spec for a unix time, in UTC:
/// "2026-10-15 01:30:00 UTC".
pub fn on_calendar(unix: u64) -> String {
    let days = i64::try_from(unix / 86_400).unwrap_or(0);
    let secs = unix % 86_400;
    // civil from days (Howard Hinnant's algorithm)
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!(
        "{year:04}-{month:02}-{day:02} {:02}:{:02}:{:02} UTC",
        secs / 3600,
        secs % 3600 / 60,
        secs % 60
    )
}

fn asked() -> &'static Mutex<BTreeMap<String, u64>> {
    static ASKED: OnceLock<Mutex<BTreeMap<String, u64>>> = OnceLock::new();
    ASKED.get_or_init(|| Mutex::new(BTreeMap::new()))
}

/// Record what `applet` asked for and publish the earliest wake.
fn remember(applet: &str, at: Option<u64>) {
    let Ok(mut map) = asked().lock() else { return };
    match at {
        Some(at) => map.insert(applet.to_owned(), at),
        None => map.remove(applet),
    };
    let next = map.values().min().copied().unwrap_or(0);
    drop(map);
    crate::facts::update(|f| f.next_wake = next);
}

#[zbus::proxy(
    interface = "org.freedesktop.systemd1.Manager",
    default_service = "org.freedesktop.systemd1",
    default_path = "/org/freedesktop/systemd1"
)]
trait Systemd {
    fn stop_unit(
        &self,
        name: &str,
        mode: &str,
    ) -> zbus::Result<zbus::zvariant::OwnedObjectPath>;
    fn start_transient_unit(
        &self,
        name: &str,
        mode: &str,
        properties: &[(&str, zbus::zvariant::Value<'_>)],
        aux: &[(&str, &[(&str, zbus::zvariant::Value<'_>)])],
    ) -> zbus::Result<zbus::zvariant::OwnedObjectPath>;
}

/// Wake the system for `applet` at `at` (unix seconds), replacing what it
/// asked before; None, or a time already past, cancels.
pub async fn set(applet: &str, at: Option<u64>, now: u64) -> Result<(), String> {
    let at = at.filter(|&t| t > now);
    let name = unit_name(applet);
    let conn = zbus::Connection::system()
        .await
        .map_err(|e| e.to_string())?;
    let systemd = SystemdProxy::new(&conn).await.map_err(|e| e.to_string())?;
    // the old one goes; one that is not there is not an error
    let _ = systemd.stop_unit(&name, "replace").await;
    remember(applet, at);
    let Some(at) = at else {
        tracing::info!(applet, "wake: cancelled");
        return Ok(());
    };
    let calendar = on_calendar(at);
    let description = format!("vrx: wake the system for {applet}");
    let timers = vec![("OnCalendar".to_owned(), calendar.clone())];
    let properties = [
        (
            "Description",
            zbus::zvariant::Value::from(description.as_str()),
        ),
        ("TimersCalendar", zbus::zvariant::Value::from(timers)),
        ("WakeSystem", zbus::zvariant::Value::from(true)),
        ("AccuracyUSec", zbus::zvariant::Value::from(1_000_000u64)),
        ("RemainAfterElapse", zbus::zvariant::Value::from(false)),
    ];
    systemd
        .start_transient_unit(&name, "replace", &properties, &[])
        .await
        .map_err(|e| e.to_string())?;
    tracing::info!(applet, at = %calendar, "wake: set");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_unix_time_is_a_utc_calendar_spec() {
        assert_eq!(on_calendar(0), "1970-01-01 00:00:00 UTC");
        assert_eq!(
            on_calendar(951_782_400),
            "2000-02-29 00:00:00 UTC",
            "a leap day"
        );
        assert_eq!(on_calendar(1_791_998_100), "2026-10-14 17:15:00 UTC");
        assert_eq!(unit_name("clock"), "vrx-wake@clock.timer");
    }

    #[test]
    fn the_earliest_wake_is_published_and_a_cancel_removes_it() {
        remember("clock", Some(2_000));
        remember("other", Some(1_000));
        assert_eq!(crate::facts::subscribe().borrow().next_wake, 1_000);
        remember("other", None);
        assert_eq!(crate::facts::subscribe().borrow().next_wake, 2_000);
        remember("clock", None);
        assert_eq!(crate::facts::subscribe().borrow().next_wake, 0);
    }
}
