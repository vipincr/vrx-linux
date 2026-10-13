// The session: what runs and what is on screen. vrxhost's one decision
// point for focus (plan 0007 amendment C): the back trail's top applet
// is the focused one; this module turns navigation, supervision and
// compositor events into two kinds of order: start an applet, focus a
// pid. It does no I/O, so every policy below is host-testable; main.rs
// carries the orders out.

use std::collections::HashMap;

use vrx_protocol::Registry;

use crate::compositor::LinkEvent;
use crate::supervisor::Event;
use crate::trail::{Trail, TrailEntry};

/// A navigation request (Nav in vrx_kit, over the intent socket).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum NavOp {
    Push { applet: String, route: u32 },
    Pop,
    Home,
}

/// An order for main.rs to carry out.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Order {
    /// Start (and supervise) this applet.
    Start(String),
    /// Tell the compositor to focus this pid.
    Focus(u32),
}

/// Why a navigation request was refused.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum NavError {
    #[error("no applet {0:?} in the registry")]
    Unknown(String),
    #[error("applet {0:?} is a library or has no display; it cannot be opened")]
    NotOpenable(String),
    #[error("applet {0:?} is disabled after repeated crashes")]
    Disabled(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Proc {
    Starting,
    Running(u32),
    Disabled,
}

#[derive(Debug)]
pub struct Session {
    home: String,
    trail: Trail,
    procs: HashMap<String, Proc>,
    linked: bool,
    sent: Option<u32>,
}

impl Session {
    /// A session whose Home is `home` (the registry's home-role applet).
    pub fn new(home: impl Into<String>) -> Self {
        Self {
            home: home.into(),
            trail: Trail::new(),
            procs: HashMap::new(),
            linked: false,
            sent: None,
        }
    }

    /// The home-role applet in a registry, if one is declared.
    pub fn home_of(registry: &Registry) -> Option<String> {
        registry
            .iter()
            .find(|e| e.manifest.applet.roles.home)
            .map(|e| e.manifest.applet.id.clone())
    }

    /// Boot: the trail starts at Home; the home applet and every
    /// resident applet start now, everything else on first use.
    pub fn boot(&mut self, registry: &Registry) -> Vec<Order> {
        self.trail.home(&self.home);
        let mut orders = Vec::new();
        for entry in registry.iter() {
            let applet = &entry.manifest.applet;
            if applet.id == self.home || applet.roles.resident {
                orders.extend(self.start(&applet.id));
            }
        }
        orders.extend(self.refocus());
        orders
    }

    /// The applet the trail shows (what has, or is about to get, focus).
    pub fn top(&self) -> Option<&str> {
        self.trail.top().map(|e| e.applet.as_str())
    }

    pub fn nav(
        &mut self,
        registry: &Registry,
        op: NavOp,
    ) -> Result<Vec<Order>, NavError> {
        match op {
            NavOp::Push { applet, route } => {
                let entry = registry
                    .find(&applet)
                    .ok_or_else(|| NavError::Unknown(applet.clone()))?;
                if entry.manifest.applet.kind == vrx_protocol::manifest::Kind::Library {
                    return Err(NavError::NotOpenable(applet));
                }
                if self.procs.get(&applet) == Some(&Proc::Disabled) {
                    return Err(NavError::Disabled(applet));
                }
                if self.top() != Some(applet.as_str()) {
                    // an evicted entry keeps its process for now; B4's
                    // suspension policy decides what eviction costs
                    let _evicted = self.trail.push(TrailEntry { applet, route });
                }
            }
            NavOp::Pop => {
                self.trail.back();
                if self.trail.is_empty() {
                    self.trail.home(&self.home);
                }
            }
            NavOp::Home => self.trail.home(&self.home),
        }
        Ok(self.refocus())
    }

    /// A supervisor event.
    pub fn supervision(&mut self, event: &Event) -> Vec<Order> {
        let applet = event.applet().to_owned();
        match event {
            Event::Started { pid, .. } => {
                self.procs.insert(applet, Proc::Running(*pid));
            }
            Event::Restarting { .. } => {
                // the supervisor respawns it; Started brings the new pid
                self.procs.insert(applet, Proc::Starting);
            }
            Event::Finished { .. } => {
                self.procs.remove(&applet);
                self.leave(&applet);
                if applet == self.home {
                    // Home is always there to go back to
                    return [self.start(&applet), self.refocus()].concat();
                }
            }
            Event::Disabled { .. } => {
                self.procs.insert(applet.clone(), Proc::Disabled);
                self.leave(&applet);
            }
        }
        self.refocus()
    }

    /// A compositor link event.
    pub fn link(&mut self, event: &LinkEvent) -> Vec<Order> {
        match event {
            LinkEvent::Connected => {
                self.linked = true;
                self.sent = None; // a new compositor knows no focus
                self.refocus()
            }
            LinkEvent::Lost => {
                self.linked = false;
                self.sent = None;
                Vec::new()
            }
            LinkEvent::App { .. } => Vec::new(),
        }
    }

    /// The applet can no longer be shown: drop it from the trail.
    fn leave(&mut self, applet: &str) {
        while self.top() == Some(applet) {
            self.trail.back();
        }
        if self.trail.is_empty() {
            self.trail.home(&self.home);
        }
    }

    fn start(&mut self, applet: &str) -> Vec<Order> {
        match self.procs.get(applet) {
            Some(Proc::Running(_) | Proc::Starting | Proc::Disabled) => Vec::new(),
            None => {
                self.procs.insert(applet.to_owned(), Proc::Starting);
                vec![Order::Start(applet.to_owned())]
            }
        }
    }

    /// Make the compositor's focus match the trail's top, starting the
    /// top applet if it is not running.
    fn refocus(&mut self) -> Vec<Order> {
        let Some(top) = self.top().map(str::to_owned) else {
            return Vec::new();
        };
        match self.procs.get(&top) {
            Some(Proc::Running(pid)) => {
                let pid = *pid;
                if self.linked && self.sent != Some(pid) {
                    self.sent = Some(pid);
                    vec![Order::Focus(pid)]
                } else {
                    Vec::new()
                }
            }
            Some(Proc::Starting | Proc::Disabled) => Vec::new(),
            None => self.start(&top),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use vrx_protocol::RegistryEntry;

    fn registry() -> Registry {
        let mut r = Registry::new();
        for (id, extra) in [
            ("launcher", "\n[applet.roles]\nhome = true\n"),
            ("clock", ""),
            ("settings", ""),
        ] {
            let text = format!(
                "[applet]\nid = \"{id}\"\nname = \"N\"\nversion = \"1.0.0\"\nruntime = \"flutter\"\n{extra}"
            );
            r.admit(RegistryEntry {
                manifest: text.parse().unwrap(),
                path: PathBuf::from("/system/defaults").join(id),
                builtin: true,
            })
            .unwrap();
        }
        r
    }

    fn started(applet: &str, pid: u32) -> Event {
        Event::Started {
            applet: applet.into(),
            pid,
        }
    }

    fn push(applet: &str) -> NavOp {
        NavOp::Push {
            applet: applet.into(),
            route: 0,
        }
    }

    /// Booted, linked, launcher running as pid 100.
    fn booted() -> (Registry, Session) {
        let reg = registry();
        let mut s = Session::new(Session::home_of(&reg).unwrap());
        assert_eq!(s.boot(&reg), vec![Order::Start("launcher".into())]);
        assert_eq!(s.supervision(&started("launcher", 100)), vec![]);
        assert_eq!(s.link(&LinkEvent::Connected), vec![Order::Focus(100)]);
        (reg, s)
    }

    #[test]
    fn boot_starts_home_and_focuses_it_once_linked() {
        let (_reg, s) = booted();
        assert_eq!(s.top(), Some("launcher"));
    }

    #[test]
    fn focus_waits_for_the_link_and_is_resent_after_a_reconnect() {
        let reg = registry();
        let mut s = Session::new("launcher");
        s.boot(&reg);
        assert_eq!(s.supervision(&started("launcher", 7)), vec![]);
        assert_eq!(s.link(&LinkEvent::Connected), vec![Order::Focus(7)]);
        assert_eq!(s.link(&LinkEvent::Lost), vec![]);
        assert_eq!(s.link(&LinkEvent::Connected), vec![Order::Focus(7)]);
    }

    #[test]
    fn push_starts_the_applet_then_focuses_its_pid() {
        let (reg, mut s) = booted();
        assert_eq!(
            s.nav(&reg, push("clock")).unwrap(),
            vec![Order::Start("clock".into())]
        );
        assert_eq!(
            s.supervision(&started("clock", 200)),
            vec![Order::Focus(200)]
        );
        // pushing what is already on top changes nothing
        assert_eq!(s.nav(&reg, push("clock")).unwrap(), vec![]);
    }

    #[test]
    fn pop_and_home_return_to_running_applets_without_restarting_them() {
        let (reg, mut s) = booted();
        s.nav(&reg, push("clock")).unwrap();
        s.supervision(&started("clock", 200));
        s.nav(&reg, push("settings")).unwrap();
        s.supervision(&started("settings", 300));
        assert_eq!(s.nav(&reg, NavOp::Pop).unwrap(), vec![Order::Focus(200)]);
        assert_eq!(s.nav(&reg, NavOp::Home).unwrap(), vec![Order::Focus(100)]);
        // popping past Home stays Home
        assert_eq!(s.nav(&reg, NavOp::Pop).unwrap(), vec![]);
        assert_eq!(s.top(), Some("launcher"));
    }

    #[test]
    fn an_unknown_applet_is_refused_by_name() {
        let (reg, mut s) = booted();
        assert_eq!(
            s.nav(&reg, push("ghost")),
            Err(NavError::Unknown("ghost".into()))
        );
    }

    #[test]
    fn a_restarted_applet_regains_focus_under_its_new_pid() {
        let (reg, mut s) = booted();
        s.nav(&reg, push("clock")).unwrap();
        s.supervision(&started("clock", 200));
        let restarting = Event::Restarting {
            applet: "clock".into(),
            attempt: 1,
        };
        assert_eq!(s.supervision(&restarting), vec![]);
        assert_eq!(
            s.supervision(&started("clock", 201)),
            vec![Order::Focus(201)]
        );
    }

    #[test]
    fn a_finished_or_disabled_top_falls_back_down_the_trail() {
        let (reg, mut s) = booted();
        s.nav(&reg, push("clock")).unwrap();
        s.supervision(&started("clock", 200));
        let finished = Event::Finished {
            applet: "clock".into(),
        };
        assert_eq!(s.supervision(&finished), vec![Order::Focus(100)]);

        s.nav(&reg, push("settings")).unwrap();
        s.supervision(&started("settings", 300));
        let disabled = Event::Disabled {
            applet: "settings".into(),
            crashes: 4,
        };
        assert_eq!(s.supervision(&disabled), vec![Order::Focus(100)]);
        assert_eq!(
            s.nav(&reg, push("settings")),
            Err(NavError::Disabled("settings".into()))
        );
    }

    #[test]
    fn home_finishing_is_started_again() {
        let (_reg, mut s) = booted();
        let finished = Event::Finished {
            applet: "launcher".into(),
        };
        assert_eq!(
            s.supervision(&finished),
            vec![Order::Start("launcher".into())]
        );
        assert_eq!(
            s.supervision(&started("launcher", 101)),
            vec![Order::Focus(101)]
        );
    }
}
