// Applet processes are systemd units (plan 0008 D1): each applet <id>
// runs as `vrx-applet@<id>.service`, as its own user `vrx-<id>`, with the
// sandbox and the restart policy in the unit. This module asks systemd to
// start them (org.freedesktop.systemd1 over D-Bus) and turns unit state
// into the session's events. vrxhost forks nothing.

use futures_util::StreamExt;
use tokio::sync::mpsc;
use zbus::proxy::CacheProperties;
use zbus::zvariant::OwnedObjectPath;
use zbus::{proxy, Connection};

/// What becomes of a supervised applet, read from its unit.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    /// The unit's main process is up with this pid: the pid the
    /// compositor sees on its socket, so focus is named by it.
    Started { applet: String, pid: u32 },
    /// The applet exited cleanly (it finished; systemd does not restart it).
    Finished { applet: String },
    /// The applet crashed and systemd is restarting it.
    Restarting { applet: String, attempt: u32 },
    /// The unit failed: it crashed past its start limit, or could not
    /// start at all.
    Disabled { applet: String, crashes: u32 },
}

impl Event {
    pub fn applet(&self) -> &str {
        match self {
            Event::Started { applet, .. }
            | Event::Finished { applet }
            | Event::Restarting { applet, .. }
            | Event::Disabled { applet, .. } => applet,
        }
    }
}

/// The unit an applet runs in.
pub fn unit_name(applet: &str) -> String {
    format!("vrx-applet@{applet}.service")
}

/// The applet a cgroup path belongs to: the last component names its
/// unit, `vrx-applet@<id>.service`. Applet ids are `[a-z][a-z0-9_]*`, so
/// systemd never escapes them.
pub fn applet_of_cgroup(cgroup: &str) -> Option<String> {
    cgroup.lines().find_map(|line| {
        let path = line.rsplit(':').next()?;
        let unit = path.rsplit('/').find(|c| c.starts_with("vrx-applet@"))?;
        let id = unit.strip_prefix("vrx-applet@")?.strip_suffix(".service")?;
        (!id.is_empty()).then(|| id.to_owned())
    })
}

/// The applet a process belongs to, from its cgroup; None for anything
/// that is not an applet unit (vrxhost itself, root diagnostics).
pub fn applet_of_pid(pid: u32) -> Option<String> {
    std::fs::read_to_string(format!("/proc/{pid}/cgroup"))
        .ok()
        .as_deref()
        .and_then(applet_of_cgroup)
}

/// A unit's state, as systemd reports it.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct UnitState {
    pub active: String,
    pub sub: String,
    pub pid: u32,
    pub restarts: u32,
    pub result: String,
}

/// What an applet's watcher has already reported, so a property signal
/// that changes nothing we care about reports nothing.
#[derive(Debug, Default)]
pub struct Seen {
    pid: u32,
    started: bool,
    attempt: u32,
}

/// Turn a unit state into at most one event.
pub fn interpret(applet: &str, s: &UnitState, seen: &mut Seen) -> Option<Event> {
    let applet = applet.to_owned();
    match s.active.as_str() {
        "active" if s.pid != 0 && s.pid != seen.pid => {
            seen.pid = s.pid;
            seen.started = true;
            Some(Event::Started { applet, pid: s.pid })
        }
        "activating" if s.sub == "auto-restart" && s.restarts != seen.attempt => {
            seen.pid = 0;
            seen.attempt = s.restarts;
            Some(Event::Restarting {
                applet,
                attempt: s.restarts,
            })
        }
        "failed" if seen.pid != 0 || seen.started || seen.attempt != 0 => {
            *seen = Seen::default();
            Some(Event::Disabled {
                applet,
                crashes: s.restarts + 1,
            })
        }
        "inactive" if seen.started => {
            *seen = Seen::default();
            Some(Event::Finished { applet })
        }
        _ => None,
    }
}

#[proxy(
    interface = "org.freedesktop.systemd1.Manager",
    default_service = "org.freedesktop.systemd1",
    default_path = "/org/freedesktop/systemd1"
)]
trait Manager {
    fn subscribe(&self) -> zbus::Result<()>;
    fn load_unit(&self, name: &str) -> zbus::Result<OwnedObjectPath>;
    fn start_unit(&self, name: &str, mode: &str) -> zbus::Result<OwnedObjectPath>;
    fn stop_unit(&self, name: &str, mode: &str) -> zbus::Result<OwnedObjectPath>;
    fn reset_failed_unit(&self, name: &str) -> zbus::Result<()>;
    fn reload(&self) -> zbus::Result<()>;
}

#[proxy(
    interface = "org.freedesktop.systemd1.Unit",
    default_service = "org.freedesktop.systemd1"
)]
trait Unit {
    #[zbus(property)]
    fn active_state(&self) -> zbus::Result<String>;
    #[zbus(property)]
    fn sub_state(&self) -> zbus::Result<String>;
}

#[proxy(
    interface = "org.freedesktop.systemd1.Service",
    default_service = "org.freedesktop.systemd1"
)]
trait Service {
    #[zbus(property, name = "MainPID")]
    fn main_pid(&self) -> zbus::Result<u32>;
    #[zbus(property, name = "NRestarts")]
    fn n_restarts(&self) -> zbus::Result<u32>;
    #[zbus(property)]
    fn result(&self) -> zbus::Result<String>;
}

/// The applet controller: start orders in, events out.
#[derive(Debug, Clone)]
pub struct Applets {
    conn: Connection,
}

impl Applets {
    /// Connect to systemd and watch every listed applet's unit. Events
    /// for all of them arrive on `events`, from the first state read on,
    /// so applets already running (vrxhost restarted under them) are
    /// adopted rather than started twice.
    pub async fn watch(
        applets: impl IntoIterator<Item = String>,
        events: mpsc::UnboundedSender<Event>,
    ) -> zbus::Result<Self> {
        let conn = Connection::system().await?;
        let manager = ManagerProxy::new(&conn).await?;
        // systemd emits unit signals only to subscribed clients
        manager.subscribe().await?;
        for applet in applets {
            let path = manager.load_unit(&unit_name(&applet)).await?;
            tokio::spawn(watch_unit(conn.clone(), applet, path, events.clone()));
        }
        Ok(Self { conn })
    }

    /// Watch one more applet's unit (one installed after the start).
    pub async fn watch_one(
        &self,
        applet: String,
        events: mpsc::UnboundedSender<Event>,
    ) -> zbus::Result<()> {
        let manager = ManagerProxy::new(&self.conn).await?;
        let path = manager.load_unit(&unit_name(&applet)).await?;
        tokio::spawn(watch_unit(self.conn.clone(), applet, path, events));
        Ok(())
    }

    /// Stop an applet's unit (an uninstall).
    pub async fn stop(&self, applet: &str) -> zbus::Result<()> {
        let manager = ManagerProxy::new(&self.conn).await?;
        manager.stop_unit(&unit_name(applet), "replace").await?;
        Ok(())
    }

    /// systemd reads its units again (a drop-in written or removed).
    pub async fn reload(&self) -> zbus::Result<()> {
        ManagerProxy::new(&self.conn).await?.reload().await
    }

    /// The unit is active now.
    pub async fn is_active(&self, unit: &str) -> bool {
        let read = async {
            let manager = ManagerProxy::new(&self.conn).await?;
            let path = manager.load_unit(unit).await?;
            let proxy = UnitProxy::builder(&self.conn)
                .path(path)?
                .cache_properties(CacheProperties::No)
                .build()
                .await?;
            proxy.active_state().await
        };
        read.await.is_ok_and(|state| state == "active")
    }

    /// Start an applet's unit. A unit that failed past its start limit
    /// is reset first: a start order is a new chance.
    pub async fn start(&self, applet: &str) -> zbus::Result<()> {
        let manager = ManagerProxy::new(&self.conn).await?;
        let name = unit_name(applet);
        let _ = manager.reset_failed_unit(&name).await;
        manager.start_unit(&name, "replace").await?;
        Ok(())
    }
}

async fn read_state(
    unit: &UnitProxy<'_>,
    service: &ServiceProxy<'_>,
) -> zbus::Result<UnitState> {
    Ok(UnitState {
        active: unit.active_state().await?,
        sub: unit.sub_state().await?,
        pid: service.main_pid().await?,
        restarts: service.n_restarts().await?,
        result: service.result().await?,
    })
}

async fn watch_unit(
    conn: Connection,
    applet: String,
    path: OwnedObjectPath,
    events: mpsc::UnboundedSender<Event>,
) {
    let built = async {
        let unit = UnitProxy::builder(&conn)
            .path(path.clone())?
            .cache_properties(CacheProperties::No)
            .build()
            .await?;
        let service = ServiceProxy::builder(&conn)
            .path(path.clone())?
            .cache_properties(CacheProperties::No)
            .build()
            .await?;
        let props = zbus::fdo::PropertiesProxy::builder(&conn)
            .destination("org.freedesktop.systemd1")?
            .path(path.clone())?
            .build()
            .await?;
        zbus::Result::Ok((unit, service, props))
    };
    let (unit, service, props) = match built.await {
        Ok(proxies) => proxies,
        Err(err) => {
            tracing::error!(%applet, error = %err, "cannot watch the applet's unit");
            return;
        }
    };
    let mut changes = match props.receive_properties_changed().await {
        Ok(stream) => stream,
        Err(err) => {
            tracing::error!(%applet, error = %err, "cannot subscribe to the applet's unit");
            return;
        }
    };
    let mut seen = Seen::default();
    let mut last: Option<UnitState> = None;
    loop {
        match read_state(&unit, &service).await {
            Ok(state) => {
                if last.as_ref() != Some(&state) {
                    tracing::debug!(%applet, ?state, "unit");
                    if let Some(event) = interpret(&applet, &state, &mut seen) {
                        if events.send(event).is_err() {
                            return;
                        }
                    }
                    last = Some(state);
                }
            }
            Err(err) => tracing::warn!(%applet, error = %err, "reading the unit failed"),
        }
        // any property change on the unit object: re-read the whole state
        if changes.next().await.is_none() {
            tracing::warn!(%applet, "unit signal stream ended");
            return;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn state(active: &str, sub: &str, pid: u32, restarts: u32) -> UnitState {
        UnitState {
            active: active.into(),
            sub: sub.into(),
            pid,
            restarts,
            result: "success".into(),
        }
    }

    #[test]
    fn the_cgroup_names_the_applet() {
        let cg =
            "0::/system.slice/system-vrx\\x2dapplet.slice/vrx-applet@clock.service\n";
        assert_eq!(applet_of_cgroup(cg), Some("clock".into()));
        assert_eq!(applet_of_cgroup("0::/system.slice/vrxhost.service\n"), None);
        assert_eq!(
            applet_of_cgroup("0::/user.slice/user-0.slice/session-1.scope\n"),
            None
        );
    }

    #[test]
    fn a_unit_lifecycle_reads_as_events() {
        let mut seen = Seen::default();
        // loaded but never started: nothing to say
        assert_eq!(
            interpret("clock", &state("inactive", "dead", 0, 0), &mut seen),
            None
        );
        assert_eq!(
            interpret("clock", &state("active", "running", 200, 0), &mut seen),
            Some(Event::Started {
                applet: "clock".into(),
                pid: 200
            })
        );
        // the same state again (another property changed): nothing
        assert_eq!(
            interpret("clock", &state("active", "running", 200, 0), &mut seen),
            None
        );
        assert_eq!(
            interpret(
                "clock",
                &state("activating", "auto-restart", 0, 1),
                &mut seen
            ),
            Some(Event::Restarting {
                applet: "clock".into(),
                attempt: 1
            })
        );
        assert_eq!(
            interpret("clock", &state("active", "running", 201, 1), &mut seen),
            Some(Event::Started {
                applet: "clock".into(),
                pid: 201
            })
        );
        assert_eq!(
            interpret("clock", &state("failed", "failed", 0, 4), &mut seen),
            Some(Event::Disabled {
                applet: "clock".into(),
                crashes: 5
            })
        );
    }

    #[test]
    fn a_clean_exit_is_finished_and_a_stale_failure_is_not_news() {
        let mut seen = Seen::default();
        // a unit that was failed before vrxhost looked: not this run's news
        assert_eq!(
            interpret("x", &state("failed", "failed", 0, 0), &mut seen),
            None
        );
        interpret("x", &state("active", "running", 9, 0), &mut seen);
        assert_eq!(
            interpret("x", &state("inactive", "dead", 0, 0), &mut seen),
            Some(Event::Finished { applet: "x".into() })
        );
    }
}
