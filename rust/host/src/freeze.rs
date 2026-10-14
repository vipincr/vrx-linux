// Applets behind the screen are frozen (plan 0012 D2, G026). Linux has
// the mechanism: cgroup v2 freeze, which systemd exposes as FreezeUnit and
// ThawUnit on its manager. An applet that leaves the screen is frozen
// DELAY later (a quick switch back costs nothing) and thawed before it is
// focused or handed anything. A frozen process takes no CPU and no timer
// wakes, and systemd stops a frozen service's watchdog and resets it on
// thaw (systemd v259 src/core/service.c, service_freezer_action), so a
// frozen applet is never killed for missing its pings.
//
// Never frozen: the shell and Home; resident applets and services; an
// applet that declares why it runs behind the screen (`background`). Not
// now (asked again DELAY later): an applet holding a logind inhibitor,
// with an open ALSA PCM in its cgroup, holding a channel end vrxhost
// handed it, or handed an intent or a route within DELAY.
//
// `decide` is the policy, pure; `Freezer` keeps the per-applet state and
// the timers and does the I/O through a `Backend`, so the whole thing is
// host-testable.

use std::collections::HashMap;
use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use crate::registry;

/// How long after leaving the screen an applet is frozen.
pub const DELAY: Duration = Duration::from_secs(30);

/// What vrxhost knows about an applet when it decides.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Facts {
    /// the shell or Home
    pub kept: bool,
    /// a resident applet, or a service
    pub resident: bool,
    /// declares a reason to run behind the screen
    pub background: bool,
    /// on screen now
    pub visible: bool,
    /// holds a logind inhibitor (its screen hold, a sleep delay)
    pub inhibitor: bool,
    /// an ALSA PCM is open in its cgroup (playing or recording)
    pub audio: bool,
    /// still holds a channel end vrxhost handed it
    pub channel: bool,
    /// was handed an intent or a route within DELAY
    pub delivery: bool,
}

/// The decision for one applet.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Verdict {
    Freeze,
    /// exempt for as long as it runs; nothing to ask again
    Never(&'static str),
    /// not now; asked again DELAY later
    NotNow(&'static str),
}

/// The policy (plan 0012 D2), in the order a reason is reported.
pub fn decide(f: &Facts) -> Verdict {
    if f.kept {
        Verdict::Never("the shell or Home")
    } else if f.resident {
        Verdict::Never("resident")
    } else if f.background {
        Verdict::Never("declares a background job")
    } else if f.visible {
        Verdict::NotNow("on screen")
    } else if f.inhibitor {
        Verdict::NotNow("holds a logind inhibitor")
    } else if f.audio {
        Verdict::NotNow("playing or recording audio")
    } else if f.channel {
        Verdict::NotNow("holds an open channel")
    } else if f.delivery {
        Verdict::NotNow("just handed an intent or a route")
    } else {
        Verdict::Freeze
    }
}

/// A boxed future, for the backend's D-Bus calls.
pub type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

/// The I/O the freezer needs: systemd's freezer and what Linux says about
/// a process. The real one is `LinuxBackend`; the tests use a fake.
pub trait Backend: Send + Sync {
    fn freeze<'a>(&'a self, applet: &'a str) -> BoxFuture<'a, Result<(), String>>;
    fn thaw<'a>(&'a self, applet: &'a str) -> BoxFuture<'a, Result<(), String>>;
    /// The pids holding a logind inhibitor now.
    fn inhibitor_pids(&self) -> BoxFuture<'_, Vec<u32>>;
    /// The applet a pid belongs to (its cgroup).
    fn applet_of(&self, pid: u32) -> Option<String>;
    /// The pids that own an open ALSA PCM substream.
    fn audio_pids(&self) -> Vec<u32>;
    /// Some process in the applet whose main pid is `pid` still holds one
    /// of these socket inodes.
    fn holds_socket(&self, pid: u32, inodes: &[u64]) -> bool;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Cg {
    /// vrxhost has not seen it either way (it may have restarted under a
    /// frozen applet): a thaw is asked before it is needed
    Unknown,
    Running,
    Frozen,
}

#[derive(Debug)]
struct App {
    pid: u32,
    frozen: Cg,
    /// bumped by every change that makes a pending timer stale
    generation: u64,
    delivered: Option<Instant>,
    /// socket inodes of the channel ends handed to it
    channels: Vec<u64>,
    /// the reason last logged for keeping it awake
    said: Option<&'static str>,
}

#[derive(Default)]
struct State {
    apps: HashMap<String, App>,
    visible: Option<String>,
}

struct Inner {
    state: Mutex<State>,
    backend: Box<dyn Backend>,
    registry: registry::Shared,
    kept: Vec<String>,
    delay: Duration,
}

/// The per-applet freeze state and its timers. Cheap to clone.
#[derive(Clone)]
pub struct Freezer {
    inner: Arc<Inner>,
}

impl std::fmt::Debug for Freezer {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Freezer")
    }
}

impl Freezer {
    /// `kept`: the shell and Home, never frozen.
    pub fn new(
        backend: Box<dyn Backend>,
        registry: registry::Shared,
        kept: Vec<String>,
        delay: Duration,
    ) -> Self {
        Self {
            inner: Arc::new(Inner {
                state: Mutex::new(State::default()),
                backend,
                registry,
                kept,
                delay,
            }),
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.inner
            .state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// The applet's unit is up with this pid; hidden, its timer starts.
    /// Its freezer state is unknown: a vrxhost restarted under a frozen
    /// applet adopts it with this same event, so the first focus or
    /// delivery asks systemd to thaw (a no-op on a running unit).
    pub fn started(&self, applet: &str, pid: u32) {
        let hidden = {
            let mut s = self.lock();
            let visible = s.visible.as_deref() == Some(applet);
            let app = s.apps.entry(applet.to_owned()).or_insert(App {
                pid,
                frozen: Cg::Unknown,
                generation: 0,
                delivered: None,
                channels: Vec::new(),
                said: None,
            });
            app.pid = pid;
            app.frozen = Cg::Unknown;
            app.channels.clear();
            !visible
        };
        if hidden {
            self.arm(applet);
        }
    }

    /// The applet's process is gone (finished, crashed, disabled).
    pub fn gone(&self, applet: &str) {
        self.lock().apps.remove(applet);
    }

    /// `applet` is about to be focused: the one on screen from now. The
    /// one it replaces starts its timer. True when it must be thawed
    /// first (frozen, or vrxhost cannot tell).
    pub fn shown(&self, applet: &str) -> bool {
        let (left, thaw) = {
            let mut s = self.lock();
            let left = s.visible.replace(applet.to_owned());
            let thaw = s.apps.get_mut(applet).is_some_and(|a| {
                a.generation += 1;
                a.frozen != Cg::Running
            });
            (left.filter(|l| l != applet), thaw)
        };
        if let Some(left) = left {
            self.arm(&left);
        }
        thaw
    }

    /// A channel end was handed to `applet`: it holds it until the socket
    /// is closed in every process of its cgroup.
    pub fn channel_handed(&self, applet: &str, inode: u64) {
        if let Some(app) = self.lock().apps.get_mut(applet) {
            app.channels.push(inode);
        }
    }

    /// Thaw `applet` before handing it something (`why` is logged). Its
    /// timer starts again, so it has DELAY to act on what it was handed.
    pub async fn awake(&self, applet: &str, why: &str) {
        let thaw = self.lock().apps.get_mut(applet).map(|app| {
            app.delivered = Some(Instant::now());
            app.generation += 1;
            app.frozen != Cg::Running
        });
        let Some(thaw) = thaw else { return };
        if thaw {
            self.thaw(applet, why).await;
        }
        if self.lock().visible.as_deref() != Some(applet) {
            self.arm(applet);
        }
    }

    /// Thaw now (focus, a delivery); logged with `why`.
    pub async fn thaw(&self, applet: &str, why: &str) {
        match self.inner.backend.thaw(applet).await {
            Ok(()) => {
                let was = self.set_frozen(applet, Cg::Running);
                if was == Some(Cg::Frozen) {
                    tracing::info!(%applet, reason = %why, "thawed");
                }
            }
            Err(err) => {
                tracing::warn!(%applet, reason = %why, error = %err, "thaw refused")
            }
        }
    }

    /// Freeze `applet` now, without its delay (plan 0012 D11: over budget
    /// 10 minutes after its banner). The exemptions still hold, and an
    /// applet on screen is never frozen. What was decided.
    pub async fn freeze_now(&self, applet: &str, why: &str) -> Verdict {
        let mut facts = self.facts(applet).await;
        facts.delivery = false;
        let verdict = decide(&facts);
        if verdict == Verdict::Freeze {
            self.freeze(applet, why).await;
        }
        verdict
    }

    fn set_frozen(&self, applet: &str, to: Cg) -> Option<Cg> {
        self.lock().apps.get_mut(applet).map(|a| {
            let was = a.frozen;
            a.frozen = to;
            was
        })
    }

    async fn freeze(&self, applet: &str, why: &str) {
        match self.inner.backend.freeze(applet).await {
            Ok(()) => {
                self.set_frozen(applet, Cg::Frozen);
                tracing::info!(%applet, reason = %why, "frozen");
            }
            // a pending job, or the unit stopped meanwhile: asked again
            Err(err) => tracing::debug!(%applet, error = %err, "freeze refused"),
        }
    }

    /// What the policy needs to know about `applet` now.
    async fn facts(&self, applet: &str) -> Facts {
        let registry = self.inner.registry.get();
        let manifest = registry.find(applet).map(|e| &e.manifest.applet);
        let (pid, visible, delivered, channels) = {
            let s = self.lock();
            let app = s.apps.get(applet);
            (
                app.map_or(0, |a| a.pid),
                s.visible.as_deref() == Some(applet),
                app.and_then(|a| a.delivered),
                app.map(|a| a.channels.clone()).unwrap_or_default(),
            )
        };
        let backend = &self.inner.backend;
        let mine = |p: u32| backend.applet_of(p).as_deref() == Some(applet);
        let inhibitor = backend.inhibitor_pids().await.into_iter().any(mine);
        let audio = backend.audio_pids().into_iter().any(mine);
        let channel = !channels.is_empty() && backend.holds_socket(pid, &channels);
        if !channel && !channels.is_empty() {
            if let Some(app) = self.lock().apps.get_mut(applet) {
                app.channels.clear();
            }
        }
        Facts {
            kept: self.inner.kept.iter().any(|k| k == applet),
            resident: manifest.is_some_and(|m| {
                m.roles.resident || m.kind == vrx_protocol::manifest::Kind::Service
            }),
            background: manifest.is_some_and(|m| m.background.is_some()),
            visible,
            inhibitor,
            audio,
            channel,
            delivery: delivered.is_some_and(|t| t.elapsed() < self.inner.delay),
        }
    }

    /// Ask again DELAY from now (a newer change makes this one stale).
    fn arm(&self, applet: &str) {
        let generation = {
            let mut s = self.lock();
            let Some(app) = s.apps.get_mut(applet) else {
                return;
            };
            app.generation += 1;
            app.generation
        };
        let this = self.clone();
        let applet = applet.to_owned();
        tokio::spawn(async move {
            tokio::time::sleep(this.inner.delay).await;
            this.check(&applet, generation).await;
        });
    }

    async fn check(&self, applet: &str, generation: u64) {
        let current = |s: &State| {
            s.apps
                .get(applet)
                .is_some_and(|a| a.generation == generation && a.frozen != Cg::Frozen)
        };
        if !current(&self.lock()) {
            return;
        }
        let verdict = decide(&self.facts(applet).await);
        if !current(&self.lock()) {
            return;
        }
        match verdict {
            Verdict::Freeze => {
                let hidden = self.inner.delay.as_secs();
                self.freeze(applet, &format!("hidden for {hidden} s")).await;
                if self
                    .lock()
                    .apps
                    .get(applet)
                    .is_some_and(|a| a.frozen != Cg::Frozen)
                {
                    self.arm(applet);
                }
            }
            Verdict::Never(reason) => self.say(applet, reason),
            Verdict::NotNow(reason) => {
                self.say(applet, reason);
                self.arm(applet);
            }
        }
    }

    /// Log why an applet stays awake, once per reason.
    fn say(&self, applet: &str, reason: &'static str) {
        let mut s = self.lock();
        if let Some(app) = s.apps.get_mut(applet) {
            if app.said != Some(reason) {
                app.said = Some(reason);
                tracing::info!(%applet, %reason, "kept awake behind the screen");
            }
        }
    }

    /// Frozen now (as vrxhost last set it).
    pub fn is_frozen(&self, applet: &str) -> bool {
        self.lock()
            .apps
            .get(applet)
            .is_some_and(|a| a.frozen == Cg::Frozen)
    }
}

/// The real backend: systemd's freezer, logind's inhibitors, and /proc.
pub struct LinuxBackend {
    pub applets: crate::applets::Applets,
}

impl Backend for LinuxBackend {
    fn freeze<'a>(&'a self, applet: &'a str) -> BoxFuture<'a, Result<(), String>> {
        Box::pin(
            async move { self.applets.freeze(applet).await.map_err(|e| e.to_string()) },
        )
    }

    fn thaw<'a>(&'a self, applet: &'a str) -> BoxFuture<'a, Result<(), String>> {
        Box::pin(
            async move { self.applets.thaw(applet).await.map_err(|e| e.to_string()) },
        )
    }

    fn inhibitor_pids(&self) -> BoxFuture<'_, Vec<u32>> {
        Box::pin(async move {
            match crate::energy::inhibitor_rows().await {
                Ok(list) => list.into_iter().map(|(.., pid)| pid).collect(),
                Err(err) => {
                    tracing::debug!(error = %err, "logind inhibitors unread");
                    Vec::new()
                }
            }
        })
    }

    fn applet_of(&self, pid: u32) -> Option<String> {
        crate::applets::applet_of_pid(pid)
    }

    fn audio_pids(&self) -> Vec<u32> {
        audio_owners(std::path::Path::new("/proc/asound"))
    }

    fn holds_socket(&self, pid: u32, inodes: &[u64]) -> bool {
        cgroup_holds_socket(pid, inodes)
    }
}

/// The owners of open ALSA PCM substreams: every
/// `card*/pcm*/sub*/status` under `root` that says `owner_pid : N`
/// (a closed substream says `closed`).
pub fn audio_owners(root: &std::path::Path) -> Vec<u32> {
    let mut pids = Vec::new();
    let dirs = |p: &std::path::Path, prefix: &str| -> Vec<std::path::PathBuf> {
        std::fs::read_dir(p)
            .into_iter()
            .flatten()
            .flatten()
            .filter(|e| e.file_name().to_string_lossy().starts_with(prefix))
            .map(|e| e.path())
            .collect()
    };
    for card in dirs(root, "card") {
        for pcm in dirs(&card, "pcm") {
            for sub in dirs(&pcm, "sub") {
                let Ok(status) = std::fs::read_to_string(sub.join("status")) else {
                    continue;
                };
                for line in status.lines() {
                    if let Some(rest) = line.strip_prefix("owner_pid") {
                        if let Ok(pid) = rest
                            .trim_start_matches([' ', '\t', ':'])
                            .trim()
                            .parse::<u32>()
                        {
                            pids.push(pid);
                        }
                    }
                }
            }
        }
    }
    pids
}

/// Some process in the cgroup of `pid` holds one of these socket inodes
/// (`/proc/<p>/fd/* -> socket:[inode]`).
pub fn cgroup_holds_socket(pid: u32, inodes: &[u64]) -> bool {
    let Ok(cgroup) = std::fs::read_to_string(format!("/proc/{pid}/cgroup")) else {
        return false;
    };
    let Some(path) = cgroup.lines().find_map(|l| l.strip_prefix("0::")) else {
        return false;
    };
    let Ok(procs) = std::fs::read_to_string(format!("/sys/fs/cgroup{path}/cgroup.procs"))
    else {
        return false;
    };
    procs
        .lines()
        .filter_map(|p| p.trim().parse::<u32>().ok())
        .any(|p| {
            std::fs::read_dir(format!("/proc/{p}/fd"))
                .into_iter()
                .flatten()
                .flatten()
                .filter_map(|fd| std::fs::read_link(fd.path()).ok())
                .filter_map(|link| {
                    link.to_string_lossy()
                        .strip_prefix("socket:[")
                        .and_then(|r| r.strip_suffix(']'))
                        .and_then(|n| n.parse::<u64>().ok())
                })
                .any(|ino| inodes.contains(&ino))
        })
}

/// A descriptor's inode (a socket's identity in `/proc/<p>/fd`).
pub fn inode_of(fd: &std::os::fd::OwnedFd) -> Option<u64> {
    use std::os::unix::fs::MetadataExt;
    let file = std::fs::File::from(fd.try_clone().ok()?);
    file.metadata().ok().map(|m| m.ino())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use vrx_protocol::{Registry, RegistryEntry};

    #[test]
    fn every_rule_decides_and_reports_its_reason_g026() {
        let base = Facts::default();
        assert_eq!(decide(&base), Verdict::Freeze);
        type Case = (fn(&mut Facts), Verdict);
        let cases: [Case; 8] = [
            (|f| f.kept = true, Verdict::Never("the shell or Home")),
            (|f| f.resident = true, Verdict::Never("resident")),
            (
                |f| f.background = true,
                Verdict::Never("declares a background job"),
            ),
            (|f| f.visible = true, Verdict::NotNow("on screen")),
            (
                |f| f.inhibitor = true,
                Verdict::NotNow("holds a logind inhibitor"),
            ),
            (
                |f| f.audio = true,
                Verdict::NotNow("playing or recording audio"),
            ),
            (
                |f| f.channel = true,
                Verdict::NotNow("holds an open channel"),
            ),
            (
                |f| f.delivery = true,
                Verdict::NotNow("just handed an intent or a route"),
            ),
        ];
        for (set, want) in cases {
            let mut f = base.clone();
            set(&mut f);
            assert_eq!(decide(&f), want);
        }
        // an exemption outranks a passing reason: a resident that also
        // holds audio is resident, never retried
        let f = Facts {
            resident: true,
            audio: true,
            ..Facts::default()
        };
        assert_eq!(decide(&f), Verdict::Never("resident"));
    }

    #[test]
    fn alsa_owners_are_read_from_substream_status() {
        let dir = tempfile::tempdir().unwrap();
        let sub = |p: &str, text: &str| {
            let d = dir.path().join(p);
            std::fs::create_dir_all(&d).unwrap();
            std::fs::write(d.join("status"), text).unwrap();
        };
        sub("card0/pcm0p/sub0", "closed\n");
        sub(
            "card0/pcm0c/sub0",
            "state: RUNNING\nowner_pid   : 4242\ntrigger_time: 1.0\n",
        );
        sub("card1/pcm1p/sub0", "state: PREPARED\nowner_pid : 7\n");
        let mut pids = audio_owners(dir.path());
        pids.sort_unstable();
        assert_eq!(pids, vec![7, 4242]);
    }

    /// A fake Linux: which applets freeze, hold inhibitors, play audio.
    #[derive(Default)]
    struct Fake {
        log: Mutex<Vec<String>>,
        inhibitors: Mutex<Vec<u32>>,
        audio: Mutex<Vec<u32>>,
        sockets: Mutex<Vec<u64>>,
    }

    impl Backend for Arc<Fake> {
        fn freeze<'a>(&'a self, applet: &'a str) -> BoxFuture<'a, Result<(), String>> {
            self.log.lock().unwrap().push(format!("freeze {applet}"));
            Box::pin(async { Ok(()) })
        }
        fn thaw<'a>(&'a self, applet: &'a str) -> BoxFuture<'a, Result<(), String>> {
            self.log.lock().unwrap().push(format!("thaw {applet}"));
            Box::pin(async { Ok(()) })
        }
        fn inhibitor_pids(&self) -> BoxFuture<'_, Vec<u32>> {
            let pids = self.inhibitors.lock().unwrap().clone();
            Box::pin(async move { pids })
        }
        // pid N belongs to the applet registered with pid N
        fn applet_of(&self, pid: u32) -> Option<String> {
            Some(
                match pid {
                    10 => "clock",
                    20 => "web",
                    30 => "recorder",
                    40 => "launcher",
                    50 => "player",
                    _ => return None,
                }
                .to_owned(),
            )
        }
        fn audio_pids(&self) -> Vec<u32> {
            self.audio.lock().unwrap().clone()
        }
        fn holds_socket(&self, _pid: u32, inodes: &[u64]) -> bool {
            let open = self.sockets.lock().unwrap();
            inodes.iter().any(|i| open.contains(i))
        }
    }

    fn registry() -> registry::Shared {
        let mut r = Registry::new();
        for (id, extra) in [
            ("launcher", "\n[applet.roles]\nhome = true\n"),
            ("clock", "\n[applet.roles]\nresident = true\n"),
            ("web", ""),
            ("recorder", ""),
            (
                "player",
                "background = \"plays music behind other applets\"\n",
            ),
        ] {
            let (applet_extra, tables) = if extra.starts_with('\n') {
                ("", extra)
            } else {
                (extra, "")
            };
            let text = format!(
                "[applet]\nid = \"{id}\"\nname = \"N\"\nversion = \"1.0.0\"\nruntime = \"flutter\"\n{applet_extra}{tables}"
            );
            r.admit(RegistryEntry {
                manifest: text.parse().unwrap(),
                path: PathBuf::from("/system/defaults").join(id),
                builtin: true,
            })
            .unwrap();
        }
        registry::Shared::new(r)
    }

    const D: Duration = Duration::from_millis(40);

    fn freezer() -> (Freezer, Arc<Fake>) {
        let fake = Arc::new(Fake::default());
        let f = Freezer::new(
            Box::new(fake.clone()),
            registry(),
            vec!["launcher".into()],
            D,
        );
        (f, fake)
    }

    async fn settle() {
        tokio::time::sleep(D * 3).await;
    }

    fn log(fake: &Fake) -> Vec<String> {
        std::mem::take(&mut *fake.log.lock().unwrap())
    }

    /// G026: a hidden applet is frozen after the delay and thawed before
    /// it is focused again; Home and residents never are.
    #[tokio::test]
    async fn hidden_applets_freeze_after_the_delay_and_thaw_before_focus_g026() {
        let (f, fake) = freezer();
        f.shown("launcher");
        for (applet, pid) in [("launcher", 40), ("clock", 10), ("web", 20)] {
            f.started(applet, pid);
        }
        settle().await;
        assert_eq!(log(&fake), vec!["freeze web"]);
        assert!(f.is_frozen("web") && !f.is_frozen("clock"));
        // opening it: thaw first; Home (left) is kept
        assert!(f.shown("web"));
        f.thaw("web", "focus").await;
        assert!(!f.is_frozen("web"));
        settle().await;
        assert_eq!(log(&fake), vec!["thaw web"]);
        // leaving it again: frozen again after the delay, not before
        f.shown("launcher");
        tokio::time::sleep(D / 4).await;
        assert!(!f.is_frozen("web"));
        settle().await;
        assert_eq!(log(&fake), vec!["freeze web"]);
    }

    /// A quick switch back costs nothing: no freeze, no thaw.
    #[tokio::test]
    async fn a_quick_switch_back_never_freezes() {
        let (f, fake) = freezer();
        f.shown("web");
        f.started("web", 20);
        f.started("launcher", 40);
        // both known to run (their first-use thaws)
        f.thaw("web", "focus").await;
        f.thaw("launcher", "focus").await;
        log(&fake);
        assert!(!f.shown("launcher"));
        tokio::time::sleep(D / 4).await;
        assert!(!f.shown("web"));
        settle().await;
        assert!(log(&fake).is_empty(), "no freeze, no thaw");
    }

    /// Inhibitor, audio, a channel and a fresh delivery keep a hidden
    /// applet awake until they end; a declared background job always.
    #[tokio::test]
    async fn what_keeps_a_hidden_applet_awake_g026() {
        let (f, fake) = freezer();
        f.shown("launcher");
        f.started("launcher", 40);
        f.started("player", 50);
        f.started("recorder", 30);
        f.started("web", 20);
        fake.inhibitors.lock().unwrap().push(20);
        fake.audio.lock().unwrap().push(30);
        settle().await;
        assert!(log(&fake).is_empty(), "inhibitor and audio keep them awake");
        // the hold and the recording end: frozen at the next look
        fake.inhibitors.lock().unwrap().clear();
        fake.audio.lock().unwrap().clear();
        settle().await;
        let mut l = log(&fake);
        l.sort();
        assert_eq!(l, vec!["freeze recorder", "freeze web"]);
        assert!(
            !f.is_frozen("player"),
            "a declared background job is never frozen"
        );
        // a channel handed to a frozen applet thaws it and keeps it awake
        // while the socket is open
        f.channel_handed("web", 77);
        fake.sockets.lock().unwrap().push(77);
        f.awake("web", "a channel").await;
        assert_eq!(log(&fake), vec!["thaw web"]);
        settle().await;
        assert!(log(&fake).is_empty(), "the open channel keeps it awake");
        fake.sockets.lock().unwrap().clear();
        settle().await;
        assert_eq!(log(&fake), vec!["freeze web"]);
    }

    /// A delivery thaws, and the applet has the delay to act on it.
    #[tokio::test]
    async fn a_delivery_thaws_and_buys_the_delay() {
        let (f, fake) = freezer();
        f.shown("launcher");
        f.started("launcher", 40);
        f.started("web", 20);
        settle().await;
        assert_eq!(log(&fake), vec!["freeze web"]);
        f.awake("web", "an intent").await;
        assert_eq!(log(&fake), vec!["thaw web"]);
        tokio::time::sleep(D / 2).await;
        assert!(!f.is_frozen("web"));
        settle().await;
        assert_eq!(log(&fake), vec!["freeze web"]);
    }

    /// vrxhost restarted under a frozen applet: before focus or delivery
    /// it asks for a thaw, since it cannot tell.
    #[tokio::test]
    async fn an_unknown_state_is_thawed_before_use() {
        let (f, fake) = freezer();
        f.started("web", 20);
        assert!(f.shown("web"));
        f.thaw("web", "focus").await;
        assert_eq!(log(&fake), vec!["thaw web"]);
    }

    /// Over budget (plan 0012 D11): frozen at once, but never Home, a
    /// resident, or the applet on screen.
    #[tokio::test]
    async fn freeze_now_keeps_the_exemptions() {
        let (f, fake) = freezer();
        f.shown("web");
        for (applet, pid) in [
            ("launcher", 40),
            ("clock", 10),
            ("web", 20),
            ("recorder", 30),
        ] {
            f.started(applet, pid);
        }
        assert_eq!(
            f.freeze_now("clock", "over budget").await,
            Verdict::Never("resident")
        );
        assert_eq!(
            f.freeze_now("web", "over budget").await,
            Verdict::NotNow("on screen")
        );
        assert_eq!(
            f.freeze_now("recorder", "over budget").await,
            Verdict::Freeze
        );
        assert_eq!(log(&fake), vec!["freeze recorder"]);
    }
}
