// The session: what runs and what is on screen. vrxhost's one decision
// point for focus (plan 0007 amendment C): the back trail's top applet
// is the focused one. A headless image (plan 0008 D14) has no home
// applet and no compositor: the session then only starts the resident
// applets and keeps opened applets running; nothing is focused. This
// module turns navigation, supervision and compositor events into orders:
// start an applet, focus a pid, name the shell's pid (plan 0008 D10). It does no I/O, so every policy below is host-testable; main.rs
// carries the orders out.

use std::collections::HashMap;

use vrx_protocol::Registry;

use crate::applets::Event;
use crate::compositor::{AppState, LinkEvent};
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
    /// Tell the compositor this pid is the shell.
    Shell(u32),
}

/// Why a navigation request was refused.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum NavError {
    #[error("no applet {0:?} in the registry")]
    Unknown(String),
    #[error(
        "applet {0:?} is a library, a service or the shell; it has no screen to open"
    )]
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
    home: Option<String>,
    /// The shell-role applet: always running, never focused, named to the
    /// compositor, which draws it above whatever is focused.
    shell: Option<String>,
    shell_sent: Option<u32>,
    trail: Trail,
    procs: HashMap<String, Proc>,
    linked: bool,
    sent: Option<u32>,
    /// Applets started in the background once Home is up (D17): opening
    /// a warm applet is a focus switch, not a cold start.
    warm: Vec<String>,
}

impl Session {
    /// A session whose Home is `home` (the registry's home-role applet),
    /// or a headless one (None), with the chrome drawn by `shell`.
    pub fn new(home: Option<String>, shell: Option<String>) -> Self {
        Self {
            home,
            shell,
            shell_sent: None,
            trail: Trail::new(),
            procs: HashMap::new(),
            linked: false,
            sent: None,
            warm: Vec::new(),
        }
    }

    /// The home-role applet in a registry, if one is declared.
    pub fn home_of(registry: &Registry) -> Option<String> {
        registry
            .iter()
            .find(|e| e.manifest.applet.roles.home)
            .map(|e| e.manifest.applet.id.clone())
    }

    /// The shell-role applet in a registry, if one is declared.
    pub fn shell_of(registry: &Registry) -> Option<String> {
        registry
            .iter()
            .find(|e| e.manifest.applet.roles.shell)
            .map(|e| e.manifest.applet.id.clone())
    }

    fn is_kept(&self, applet: &str) -> bool {
        self.home.as_deref() == Some(applet) || self.shell.as_deref() == Some(applet)
    }

    /// Boot: the trail starts at Home; the home applet and every
    /// resident applet start now, everything else on first use.
    pub fn boot(&mut self, registry: &Registry) -> Vec<Order> {
        self.go_home();
        // the launcher's tiles: what a person is about to open (plan 0008
        // D17); started when Home is on screen, not before, so they never
        // delay the first frame
        if self.home.is_some() {
            self.warm = registry
                .iter()
                .filter(|e| e.manifest.applet.display.as_ref().is_some_and(|d| d.tile))
                .map(|e| e.manifest.applet.id.clone())
                .collect();
        }
        let mut orders = Vec::new();
        for entry in registry.iter() {
            let applet = &entry.manifest.applet;
            if self.is_kept(&applet.id) || applet.roles.resident {
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

    /// How many entries the trail holds.
    pub fn depth(&self) -> usize {
        self.trail.len()
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
                if !entry.manifest.applet.kind.opens()
                    || self.shell.as_deref() == Some(applet.as_str())
                {
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
                    self.go_home();
                }
            }
            NavOp::Home => self.go_home(),
        }
        Ok(self.refocus())
    }

    /// A supervisor event.
    pub fn supervision(&mut self, event: &Event) -> Vec<Order> {
        let applet = event.applet().to_owned();
        match event {
            Event::Started { pid, .. } => {
                self.procs.insert(applet, Proc::Running(*pid));
                return [self.reshell(), self.refocus()].concat();
            }
            Event::Restarting { .. } => {
                // the supervisor respawns it; Started brings the new pid
                self.procs.insert(applet, Proc::Starting);
            }
            Event::Finished { .. } => {
                self.procs.remove(&applet);
                self.leave(&applet);
                if self.is_kept(&applet) {
                    // Home is always there to go back to; the shell is
                    // the chrome
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
                // a new compositor knows no focus and no shell
                self.sent = None;
                self.shell_sent = None;
                // an applet disabled while the compositor was away most
                // likely died of that; a returning compositor is a new
                // chance (and Home and the shell must come back regardless)
                self.procs.retain(|_, p| *p != Proc::Disabled);
                let kept = [self.home.clone(), self.shell.clone()];
                let mut orders: Vec<Order> =
                    kept.iter().flatten().flat_map(|a| self.start(a)).collect();
                orders.extend(self.reshell());
                orders.extend(self.refocus());
                orders
            }
            LinkEvent::Lost => {
                self.linked = false;
                self.sent = None;
                self.shell_sent = None;
                Vec::new()
            }
            LinkEvent::App { pid, state, .. } => {
                // Home's first frame is on the panel: now the tiles may
                // start without competing with it (D17)
                let home_pid = self.home.as_ref().and_then(|h| match self.procs.get(h) {
                    Some(Proc::Running(p)) => Some(*p),
                    _ => None,
                });
                if *state == AppState::Shown
                    && home_pid == Some(*pid)
                    && !self.warm.is_empty()
                {
                    let warm = std::mem::take(&mut self.warm);
                    warm.iter().flat_map(|a| self.start(a)).collect()
                } else {
                    Vec::new()
                }
            }
        }
    }

    /// The applet can no longer be shown: drop it from the trail.
    fn leave(&mut self, applet: &str) {
        while self.top() == Some(applet) {
            self.trail.back();
        }
        if self.trail.is_empty() {
            self.go_home();
        }
    }

    /// Clear the trail to Home; headless, clear it.
    fn go_home(&mut self) {
        match &self.home {
            Some(home) => self.trail.home(home),
            None => while self.trail.back().is_some() {},
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

    /// Name the running shell to the compositor, once per pid and link.
    fn reshell(&mut self) -> Vec<Order> {
        let Some(shell) = &self.shell else {
            return Vec::new();
        };
        match self.procs.get(shell) {
            Some(Proc::Running(pid)) if self.linked && self.shell_sent != Some(*pid) => {
                self.shell_sent = Some(*pid);
                vec![Order::Shell(*pid)]
            }
            _ => Vec::new(),
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
        let mut s = Session::new(Session::home_of(&reg), None);
        assert_eq!(s.boot(&reg), vec![Order::Start("launcher".into())]);
        assert_eq!(s.supervision(&started("launcher", 100)), vec![]);
        assert_eq!(s.link(&LinkEvent::Connected), vec![Order::Focus(100)]);
        (reg, s)
    }

    #[test]
    fn the_shell_runs_beside_home_is_named_once_per_link_and_never_opens() {
        let mut reg = registry();
        reg.admit(RegistryEntry {
            manifest: "[applet]\nid = \"shell\"\nname = \"S\"\nversion = \"1.0.0\"\nruntime = \"flutter\"\n[applet.roles]\nshell = true\n"
                .parse()
                .unwrap(),
            path: PathBuf::from("/system/defaults/shell"),
            builtin: true,
        })
        .unwrap();
        let mut s = Session::new(Session::home_of(&reg), Session::shell_of(&reg));
        let mut boot = s.boot(&reg);
        boot.sort_by_key(|o| format!("{o:?}"));
        assert_eq!(
            boot,
            vec![
                Order::Start("launcher".into()),
                Order::Start("shell".into())
            ]
        );
        s.supervision(&started("launcher", 100));
        assert_eq!(s.supervision(&started("shell", 50)), vec![]);
        assert_eq!(
            s.link(&LinkEvent::Connected),
            vec![Order::Shell(50), Order::Focus(100)]
        );
        // a respawned shell is named again; the focus stays
        s.supervision(&Event::Restarting {
            applet: "shell".into(),
            attempt: 1,
        });
        assert_eq!(s.supervision(&started("shell", 51)), vec![Order::Shell(51)]);
        // it is chrome, not an app: it cannot be opened
        assert_eq!(
            s.nav(&reg, push("shell")),
            Err(NavError::NotOpenable("shell".into()))
        );
        // a shell that exits comes back
        assert_eq!(
            s.supervision(&Event::Finished {
                applet: "shell".into(),
            }),
            vec![Order::Start("shell".into())]
        );
        // a new compositor is told again
        s.supervision(&started("shell", 52));
        s.link(&LinkEvent::Lost);
        assert_eq!(
            s.link(&LinkEvent::Connected),
            vec![Order::Shell(52), Order::Focus(100)]
        );
    }

    #[test]
    fn boot_starts_home_and_focuses_it_once_linked() {
        let (_reg, s) = booted();
        assert_eq!(s.top(), Some("launcher"));
    }

    #[test]
    fn focus_waits_for_the_link_and_is_resent_after_a_reconnect() {
        let reg = registry();
        let mut s = Session::new(Some("launcher".into()), None);
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
    fn a_returning_compositor_revives_what_died_while_it_was_away() {
        let (_reg, mut s) = booted();
        assert_eq!(s.link(&LinkEvent::Lost), vec![]);
        let dead = Event::Disabled {
            applet: "launcher".into(),
            crashes: 4,
        };
        assert_eq!(s.supervision(&dead), vec![]);
        assert_eq!(
            s.link(&LinkEvent::Connected),
            vec![Order::Start("launcher".into())]
        );
        assert_eq!(
            s.supervision(&started("launcher", 900)),
            vec![Order::Focus(900)]
        );
    }

    #[test]
    fn a_headless_session_starts_residents_and_focuses_nothing() {
        let mut reg = Registry::new();
        for (id, extra) in [
            ("sensor", "\n[applet.roles]\nresident = true\n"),
            ("logger", ""),
        ] {
            let text = format!(
                "[applet]\nid = \"{id}\"\nname = \"N\"\nversion = \"1.0.0\"\nruntime = \"rust\"\n{extra}"
            );
            reg.admit(RegistryEntry {
                manifest: text.parse().unwrap(),
                path: PathBuf::from("/system/defaults").join(id),
                builtin: true,
            })
            .unwrap();
        }
        let mut s = Session::new(Session::home_of(&reg), None);
        assert_eq!(s.boot(&reg), vec![Order::Start("sensor".into())]);
        assert_eq!(s.supervision(&started("sensor", 10)), vec![]);
        // opening an applet starts it; nothing is focused without a compositor
        assert_eq!(
            s.nav(&reg, push("logger")).unwrap(),
            vec![Order::Start("logger".into())]
        );
        assert_eq!(s.supervision(&started("logger", 11)), vec![]);
    }

    #[test]
    fn tile_applets_warm_up_once_home_is_running() {
        let mut reg = Registry::new();
        for (id, extra) in [
            ("launcher", "\n[applet.roles]\nhome = true\n"),
            (
                "clock",
                "\n[applet.display]\nicon = \"schedule\"\ntile = true\n",
            ),
            (
                "wifi",
                "\n[applet.display]\nicon = \"wifi\"\ntile = false\n",
            ),
        ] {
            let text = format!(
                "[applet]\nid = \"{id}\"\nname = \"N\"\nversion = \"1.0.0\"\nruntime = \"flutter\"\n{extra}"
            );
            reg.admit(RegistryEntry {
                manifest: text.parse().unwrap(),
                path: PathBuf::from("/system/defaults").join(id),
                builtin: true,
            })
            .unwrap();
        }
        let mut s = Session::new(Session::home_of(&reg), None);
        let shown = |pid| LinkEvent::App {
            pid,
            state: AppState::Shown,
            id: String::new(),
        };
        // Home first, alone: its process start warms nothing
        assert_eq!(s.boot(&reg), vec![Order::Start("launcher".into())]);
        assert_eq!(s.supervision(&started("launcher", 1)), vec![]);
        assert_eq!(s.link(&LinkEvent::Connected), vec![Order::Focus(1)]);
        // another app's frame is not Home's
        assert_eq!(s.link(&shown(99)), vec![]);
        // Home on the panel: the tiles (not the untiled wifi), once
        assert_eq!(s.link(&shown(1)), vec![Order::Start("clock".into())]);
        assert_eq!(s.supervision(&started("clock", 2)), vec![]);
        assert_eq!(s.link(&shown(1)), vec![]);
        // opening the warm applet is a focus, not a start
        assert_eq!(s.nav(&reg, push("clock")).unwrap(), vec![Order::Focus(2)]);
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
