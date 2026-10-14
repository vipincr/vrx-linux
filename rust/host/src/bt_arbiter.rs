// The Bluetooth arbiter (plan 0015 D4, G044): the one place that decides
// who advertises on the adapter. Two parties want it: Device Link's
// pairing window (BlueZ's Discoverable and Pairable, plan 0011 D19) and
// vrx-matter's BLE commissioning (rs-matter's GATT service and LE
// advertisement, plan 0015 D4). BlueZ has the mechanism, several
// advertisements at once, but no policy; two pairing flows at once
// confuse a person, and the CHIP SDK notes that the system's own
// advertising can block Matter's. So:
//
// - Device Link asks through io.vrx.Host.PairingWindow (the bluetooth
//   grant), and the arbiter sets BlueZ's properties as root. While Matter
//   holds the adapter the answer is Busy.
// - vrx-matter asks over its link (Command::Advertise) when a window
//   opens. The arbiter hides Device Link's window, keeping what was left
//   of it, and grants. Command::AdvertiseEnd, the link dropping, or the
//   window's ceiling passing gives the adapter back, and Device Link's
//   window reopens for its remainder.
//
// The radio stays the person's: a window opened while Bluetooth is off
// is refused BLE and pairs on the network only. The decisions are a pure
// ledger (host-tested); BlueZ is reached only to carry them out. The fact
// `advertising` says who holds the adapter, so Device Link can say why
// its window waits.

use std::collections::HashMap;
use std::sync::OnceLock;
use std::time::{Duration, Instant};

use tokio::sync::Mutex;
use zbus::zvariant::{OwnedObjectPath, OwnedValue};
use zbus::Connection;

/// The longest a Matter window may hold the adapter: the spec's ceiling
/// for a commissioning window (15 minutes). vrx-matter says when it is
/// done; this is for a vrx-matter that never says.
pub const MATTER_CEILING: u64 = 900;

/// The longest Device Link's window may be (BlueZ's default is 180 s).
pub const DEVICE_LINK_CEILING: u32 = 300;

/// Who holds the adapter, and until when (seconds on the arbiter's
/// monotonic clock).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Holder {
    #[default]
    Nobody,
    /// Device Link's pairing window: BlueZ discoverable and pairable.
    DeviceLink { until: u64 },
    /// vrx-matter's BLE commissioning; `paused` is what was left of
    /// Device Link's window when Matter took the adapter.
    Matter { until: u64, paused: Option<u64> },
}

/// What BlueZ is told.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Effect {
    /// Discoverable and pairable for `secs`.
    Show { secs: u32 },
    /// Neither.
    Hide,
}

/// Device Link asked while a home app pairs over Bluetooth.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Busy;

/// The decisions, apart from BlueZ.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Ledger {
    pub holder: Holder,
}

impl Ledger {
    /// Device Link opens (`on`) or closes its window. Closing while Matter
    /// holds the adapter drops the paused remainder, so nothing reopens.
    pub fn device_link(
        &mut self,
        on: bool,
        secs: u32,
        now: u64,
    ) -> Result<Vec<Effect>, Busy> {
        self.expire(now);
        match (self.holder, on) {
            (Holder::Matter { .. }, true) => Err(Busy),
            (Holder::Matter { until, .. }, false) => {
                self.holder = Holder::Matter {
                    until,
                    paused: None,
                };
                Ok(Vec::new())
            }
            (_, true) => {
                let secs = secs.clamp(1, DEVICE_LINK_CEILING);
                self.holder = Holder::DeviceLink {
                    until: now + u64::from(secs),
                };
                Ok(vec![Effect::Show { secs }])
            }
            (_, false) => {
                self.holder = Holder::Nobody;
                Ok(vec![Effect::Hide])
            }
        }
    }

    /// vrx-matter takes the adapter for a window of `secs`: Device Link's
    /// window, if open, is hidden and its remainder kept. Asking again
    /// while holding moves the ceiling.
    pub fn matter_acquire(&mut self, secs: u64, now: u64) -> Vec<Effect> {
        self.expire(now);
        let until = now + secs.clamp(1, MATTER_CEILING);
        match self.holder {
            Holder::Matter { paused, .. } => {
                self.holder = Holder::Matter { until, paused };
                Vec::new()
            }
            Holder::DeviceLink { until: open } => {
                self.holder = Holder::Matter {
                    until,
                    paused: Some(open - now),
                };
                vec![Effect::Hide]
            }
            Holder::Nobody => {
                self.holder = Holder::Matter {
                    until,
                    paused: None,
                };
                Vec::new()
            }
        }
    }

    /// vrx-matter is done (or gone): Device Link's window reopens for what
    /// was left of it.
    pub fn matter_release(&mut self, now: u64) -> Vec<Effect> {
        let Holder::Matter { paused, .. } = self.holder else {
            return Vec::new();
        };
        match paused.filter(|&left| left > 0) {
            Some(left) => {
                let secs = u32::try_from(left).unwrap_or(DEVICE_LINK_CEILING);
                self.holder = Holder::DeviceLink {
                    until: now + u64::from(secs),
                };
                vec![Effect::Show { secs }]
            }
            None => {
                self.holder = Holder::Nobody;
                Vec::new()
            }
        }
    }

    /// A hold past its ceiling ends: Device Link's window has already
    /// closed in BlueZ (its own timeout), a Matter hold is released.
    pub fn expire(&mut self, now: u64) -> Vec<Effect> {
        match self.holder {
            Holder::DeviceLink { until } if until <= now => {
                self.holder = Holder::Nobody;
                Vec::new()
            }
            Holder::Matter { until, .. } if until <= now => self.matter_release(now),
            _ => Vec::new(),
        }
    }

    /// The fact: "", "device-link" or "matter".
    pub fn advertising(&self) -> &'static str {
        match self.holder {
            Holder::Nobody => "",
            Holder::DeviceLink { .. } => "device-link",
            Holder::Matter { .. } => "matter",
        }
    }

    /// When the current hold ends, if it does.
    fn deadline(&self) -> Option<u64> {
        match self.holder {
            Holder::Nobody => None,
            Holder::DeviceLink { until } | Holder::Matter { until, .. } => Some(until),
        }
    }
}

/// Why a request was not carried out, for the reply.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Refused {
    /// A home app is pairing over Bluetooth.
    Busy,
    /// No adapter, or its radio is off.
    Unavailable(String),
}

fn ledger() -> &'static Mutex<Ledger> {
    static LEDGER: OnceLock<Mutex<Ledger>> = OnceLock::new();
    LEDGER.get_or_init(|| Mutex::new(Ledger::default()))
}

/// Seconds on a monotonic clock: a wall-clock step at boot (NTP) moves no
/// ceiling.
fn now() -> u64 {
    static START: OnceLock<Instant> = OnceLock::new();
    START.get_or_init(Instant::now).elapsed().as_secs()
}

#[zbus::proxy(interface = "org.bluez.Adapter1", default_service = "org.bluez")]
trait Adapter {
    #[zbus(property)]
    fn powered(&self) -> zbus::Result<bool>;
    #[zbus(property)]
    fn set_discoverable(&self, value: bool) -> zbus::Result<()>;
    #[zbus(property)]
    fn set_discoverable_timeout(&self, value: u32) -> zbus::Result<()>;
    #[zbus(property)]
    fn set_pairable(&self, value: bool) -> zbus::Result<()>;
    #[zbus(property)]
    fn set_pairable_timeout(&self, value: u32) -> zbus::Result<()>;
}

/// The first adapter BlueZ lists, and whether its radio is on.
async fn adapter(conn: &Connection) -> Result<(AdapterProxy<'static>, bool), Refused> {
    let unavailable = |e: zbus::Error| Refused::Unavailable(e.to_string());
    let manager = zbus::fdo::ObjectManagerProxy::builder(conn)
        .destination("org.bluez")
        .map_err(unavailable)?
        .path("/")
        .map_err(unavailable)?
        .build()
        .await
        .map_err(unavailable)?;
    let objects: HashMap<OwnedObjectPath, HashMap<_, HashMap<String, OwnedValue>>> =
        manager
            .get_managed_objects()
            .await
            .map_err(|e| Refused::Unavailable(e.to_string()))?;
    let mut paths: Vec<&str> = objects
        .iter()
        .filter(|(_, ifaces)| ifaces.keys().any(|i| i.as_str() == "org.bluez.Adapter1"))
        .map(|(path, _)| path.as_str())
        .collect();
    paths.sort_unstable();
    let path = paths
        .first()
        .ok_or_else(|| Refused::Unavailable("no Bluetooth adapter".into()))?;
    let proxy = AdapterProxy::builder(conn)
        .path((*path).to_owned())
        .map_err(unavailable)?
        .build()
        .await
        .map_err(unavailable)?;
    let on = proxy.powered().await.map_err(unavailable)?;
    Ok((proxy, on))
}

/// The adapter, with its radio on.
async fn powered(conn: &Connection) -> Result<AdapterProxy<'static>, Refused> {
    match adapter(conn).await? {
        (a, true) => Ok(a),
        (_, false) => Err(Refused::Unavailable("Bluetooth is off".into())),
    }
}

/// Tell BlueZ.
async fn apply(conn: &Connection, effects: &[Effect]) -> Result<(), Refused> {
    if effects.is_empty() {
        return Ok(());
    }
    // hiding needs no radio: an adapter that is off or gone shows nothing
    if !effects.iter().any(|e| matches!(e, Effect::Show { .. })) {
        match adapter(conn).await {
            Ok((_, true)) => {}
            Ok((_, false)) | Err(_) => return Ok(()),
        }
    }
    let a = powered(conn).await?;
    let failed = |e: zbus::Error| Refused::Unavailable(e.to_string());
    for effect in effects {
        match *effect {
            Effect::Show { secs } => {
                a.set_pairable_timeout(secs).await.map_err(failed)?;
                a.set_discoverable_timeout(secs).await.map_err(failed)?;
                a.set_pairable(true).await.map_err(failed)?;
                a.set_discoverable(true).await.map_err(failed)?;
            }
            Effect::Hide => {
                a.set_discoverable(false).await.map_err(failed)?;
                a.set_pairable(false).await.map_err(failed)?;
            }
        }
    }
    Ok(())
}

/// Publish who holds the adapter, and wake when the hold ends.
fn settled(ledger: &Ledger) {
    let advertising = ledger.advertising();
    crate::facts::update(|f| f.advertising = advertising.to_owned());
    if let Some(deadline) = ledger.deadline() {
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_secs(deadline.saturating_sub(now()))).await;
            expire().await;
        });
    }
}

async fn system() -> Result<Connection, Refused> {
    Connection::system()
        .await
        .map_err(|e| Refused::Unavailable(e.to_string()))
}

/// io.vrx.Host.PairingWindow: Device Link's window, open for `secs` or
/// closed.
pub async fn device_link(on: bool, secs: u32) -> Result<(), Refused> {
    let conn = system().await?;
    let mut ledger = ledger().lock().await;
    let mut next = ledger.clone();
    let effects = next
        .device_link(on, secs, now())
        .map_err(|Busy| Refused::Busy)?;
    apply(&conn, &effects).await?;
    *ledger = next;
    settled(&ledger);
    tracing::info!(on, secs, holder = ?ledger.holder, "Bluetooth: Device Link's window");
    Ok(())
}

/// Command::Advertise: vrx-matter may advertise for `secs`. False when
/// there is no adapter, its radio is off, or Device Link's window could
/// not be hidden.
pub async fn matter_acquire(secs: u16) -> bool {
    let conn = match system().await {
        Ok(c) => c,
        Err(why) => {
            tracing::info!(?why, "Bluetooth: Matter refused");
            return false;
        }
    };
    let mut ledger = ledger().lock().await;
    // the radio is the person's: off means no BLE for this window
    if let Err(why) = powered(&conn).await {
        tracing::info!(?why, "Bluetooth: Matter refused");
        return false;
    }
    let mut next = ledger.clone();
    let effects = next.matter_acquire(u64::from(secs), now());
    if let Err(why) = apply(&conn, &effects).await {
        tracing::warn!(
            ?why,
            "Bluetooth: Device Link's window not paused; Matter refused"
        );
        return false;
    }
    *ledger = next;
    settled(&ledger);
    tracing::info!(secs, holder = ?ledger.holder, "Bluetooth: Matter holds the adapter");
    true
}

/// Command::AdvertiseEnd, or vrx-matter's link dropped: Device Link gets
/// back what was left of its window.
pub async fn matter_release() {
    let mut ledger = ledger().lock().await;
    if !matches!(ledger.holder, Holder::Matter { .. }) {
        return;
    }
    let effects = ledger.matter_release(now());
    finish(
        &mut ledger,
        &effects,
        "Bluetooth: Matter let the adapter go",
    )
    .await;
}

async fn expire() {
    let mut ledger = ledger().lock().await;
    let before = ledger.holder;
    let effects = ledger.expire(now());
    if ledger.holder == before {
        return;
    }
    finish(
        &mut ledger,
        &effects,
        "Bluetooth: a hold reached its ceiling",
    )
    .await;
}

/// Carry out a release: the ledger moves on even if BlueZ fails (Device
/// Link's window is then simply gone, and the fact says so).
async fn finish(ledger: &mut Ledger, effects: &[Effect], what: &str) {
    if !effects.is_empty() {
        let applied = match system().await {
            Ok(conn) => apply(&conn, effects).await,
            Err(why) => Err(why),
        };
        if let Err(why) = applied {
            tracing::warn!(?why, "Bluetooth: Device Link's window not restored");
            ledger.holder = Holder::Nobody;
        }
    }
    settled(ledger);
    tracing::info!(holder = ?ledger.holder, "{what}");
}

#[cfg(test)]
mod tests {
    use super::*;

    /// G044: while a home app pairs over Bluetooth, Device Link cannot
    /// open its window; the window it had is paused and comes back with
    /// what was left of it.
    #[test]
    fn matter_pauses_device_link_and_gives_it_back_g044() {
        let mut l = Ledger::default();
        assert_eq!(
            l.device_link(true, 180, 100),
            Ok(vec![Effect::Show { secs: 180 }])
        );
        assert_eq!(l.advertising(), "device-link");

        // 60 s in, a Matter window opens: Device Link hidden, 120 s kept
        assert_eq!(l.matter_acquire(900, 160), vec![Effect::Hide]);
        assert_eq!(
            l.holder,
            Holder::Matter {
                until: 1060,
                paused: Some(120)
            }
        );
        assert_eq!(l.advertising(), "matter");
        assert_eq!(
            l.device_link(true, 180, 200),
            Err(Busy),
            "refused while Matter holds"
        );

        // commissioning done: Device Link back for its remaining 120 s
        assert_eq!(l.matter_release(300), vec![Effect::Show { secs: 120 }]);
        assert_eq!(l.holder, Holder::DeviceLink { until: 420 });
    }

    /// Device Link closing during Matter's hold drops the remainder;
    /// nothing reopens after.
    #[test]
    fn a_window_closed_while_paused_stays_closed() {
        let mut l = Ledger::default();
        l.device_link(true, 180, 0).unwrap();
        l.matter_acquire(900, 10);
        assert_eq!(
            l.device_link(false, 0, 20),
            Ok(vec![]),
            "BlueZ is already hidden"
        );
        assert_eq!(l.matter_release(30), vec![]);
        assert_eq!(l.holder, Holder::Nobody);
        assert_eq!(l.advertising(), "");
    }

    /// Ceilings: Matter's at 15 minutes however long it asks, Device
    /// Link's window gone after BlueZ's own timeout, a Matter hold that
    /// is never released is released at its ceiling.
    #[test]
    fn holds_end_at_their_ceilings() {
        let mut l = Ledger::default();
        l.matter_acquire(10_000, 0);
        assert_eq!(l.deadline(), Some(MATTER_CEILING));
        assert_eq!(l.expire(899), vec![]);
        assert_eq!(l.expire(900), vec![]);
        assert_eq!(l.holder, Holder::Nobody);

        l.device_link(true, 10_000, 0).unwrap();
        assert_eq!(l.deadline(), Some(u64::from(DEVICE_LINK_CEILING)));
        l.expire(300);
        assert_eq!(l.holder, Holder::Nobody);

        // an expired Device Link window is not paused (nothing is left)
        l.device_link(true, 60, 0).unwrap();
        assert_eq!(l.matter_acquire(900, 61), vec![]);
        assert_eq!(l.matter_release(70), vec![]);

        // a Matter hold past its ceiling gives Device Link its remainder
        l.device_link(true, 180, 0).unwrap();
        l.matter_acquire(60, 30);
        assert_eq!(l.expire(90), vec![Effect::Show { secs: 150 }]);
    }

    /// Releasing what Matter does not hold changes nothing (the link
    /// dropping with no window open).
    #[test]
    fn a_release_without_a_hold_is_nothing() {
        let mut l = Ledger::default();
        assert_eq!(l.matter_release(5), vec![]);
        l.device_link(true, 180, 0).unwrap();
        assert_eq!(l.matter_release(5), vec![]);
        assert_eq!(l.holder, Holder::DeviceLink { until: 180 });
    }
}
