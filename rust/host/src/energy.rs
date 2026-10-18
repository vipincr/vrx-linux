// What each applet costs (plan 0012 D8, D9, D11). Linux counts and
// vrx attributes: no Linux facility produces joules per process, so
// vrxhost samples Linux's own counters and prices them with the board's
// measured power profile (vrx_protocol::power_profile):
//
// - CPU: each applet unit's cgroup `cpu.stat` usage, priced at the mix
//   of frequencies the CPU ran at (cpufreq `time_in_state`);
// - GPU: each applet process's render-node client in /proc/<pid>/fdinfo
//   (`drm-engine-*`, ns; applets render on their own GBM device, so
//   the busy time is theirs);
// - wakeups: `voluntary_ctxt_switches`, the cheap proxy;
// - the screen, Wi-Fi and Bluetooth from sysfs (DPMS, the brightness,
//   operstate and byte counts, rfkill), as rows of their own;
// - where a fuel gauge or a power monitor reports the system's real
//   power (power_supply `power_now`, hwmon `power1_input`), the shares
//   are scaled to it: the Android BatteryStats method on Linux counters.
//
// A board without measured numbers says "not calibrated": time is still
// counted, energy is not invented. Records: a minute-by-minute ring in
// /run/vrx/energy (tmpfs, 24 h) and an hourly summary per day in
// /data/vrx/energy (14 days); an over-budget applet is a journal event
// with structured fields (`journalctl VRX_APPLET=web`) and one alert the
// shell turns into a banner. Still over budget ten minutes after an
// unanswered alert, an applet behind the screen is frozen (the owner,
// 2026-10-14: "Freeze it after 10 min"); never stopped without a person.

use std::collections::{BTreeMap, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use serde::{Deserialize, Serialize};
use tokio::sync::watch;
use vrx_protocol::power_profile::PowerProfile;

use crate::freeze::BoxFuture;

/// How often the counters are read while the screen is lit, and while
/// it is off (nobody is watching a ranking then; a slower tick costs
/// fewer wakes).
pub const TICK_LIT: std::time::Duration = std::time::Duration::from_secs(10);
pub const TICK_DARK: std::time::Duration = std::time::Duration::from_secs(60);

/// The ring's length: a day of minutes.
const RING_MINUTES: u64 = 24 * 60;
/// An unanswered alert this long, still over budget: the applet is frozen.
pub const FREEZE_AFTER_S: u64 = 10 * 60;

/// The system rows, by key and name.
pub const SYSTEM_ROWS: [(&str, &str); 6] = [
    ("system:screen", "Screen"),
    ("system:wifi", "Wi-Fi"),
    ("system:bluetooth", "Bluetooth"),
    ("system:floor", "Idle floor"),
    ("system:models", "Local models"),
    ("system:other", "System"),
];

/// Where the counters are read from (the tests use temporary trees).
#[derive(Debug, Clone)]
pub struct Roots {
    pub sys: PathBuf,
    pub proc_: PathBuf,
    pub cgroup: PathBuf,
    /// The compositor's runtime facts (`screen`: dim=…).
    pub ui: PathBuf,
    /// The screen's settings (brightness where it dims by alpha).
    pub display_conf: PathBuf,
    /// The profile and the carrier's profiles.
    pub profile: PathBuf,
    pub ring: PathBuf,
    pub days: PathBuf,
}

impl Roots {
    pub fn system() -> Self {
        Self {
            sys: "/sys".into(),
            proc_: "/proc".into(),
            cgroup: "/sys/fs/cgroup".into(),
            ui: "/run/vrx-ui".into(),
            display_conf: "/etc/vrx/display/screen.conf".into(),
            profile: "/usr/share/vrx/power-profile".into(),
            ring: "/run/vrx/energy".into(),
            days: "/data/vrx/energy".into(),
        }
    }
}

/// The board's profile: the family's file, then each carrier file in
/// `power-profile.d`, in name order. Unreadable or refused: not
/// calibrated, and why, for the log.
pub fn load_profile(path: &Path) -> (PowerProfile, Option<String>) {
    let mut files = Vec::new();
    if let Ok(text) = std::fs::read_to_string(path) {
        files.push((path.display().to_string(), text));
    }
    let dir = PathBuf::from(format!("{}.d", path.display()));
    if let Ok(entries) = std::fs::read_dir(&dir) {
        let mut names: Vec<PathBuf> = entries.flatten().map(|e| e.path()).collect();
        names.sort();
        for p in names {
            if let Ok(text) = std::fs::read_to_string(&p) {
                files.push((p.display().to_string(), text));
            }
        }
    }
    match PowerProfile::parse_all(files.iter().map(|(n, t)| (n.as_str(), t.as_str()))) {
        Ok(p) => (p, None),
        Err(err) => (PowerProfile::default(), Some(err.to_string())),
    }
}

/// A row's name: the applet's, or "Script <name>" for a background
/// script (counters keys them `script:<name>`), or the key.
fn display_name(names: &BTreeMap<String, String>, key: &str) -> String {
    if let Some(script) = key.strip_prefix("script:") {
        return format!("Script {script}");
    }
    names.get(key).cloned().unwrap_or_else(|| key.to_owned())
}

fn read(path: &Path) -> Option<String> {
    std::fs::read_to_string(path).ok()
}

fn read_u64(path: &Path) -> Option<u64> {
    read(path)?.trim().parse().ok()
}

/// One applet's counters at a moment: read by `counters` (G037), shared
/// with the profiler.
pub use crate::counters::Applet as Counters;

/// Everything read at one moment.
#[derive(Debug, Clone, Default)]
pub struct Snapshot {
    pub applets: BTreeMap<String, Counters>,
    pub models_us: u64,
    pub total_us: u64,
    /// cpufreq time per frequency (kHz -> 10 ms units), summed over policies.
    pub freq: BTreeMap<u32, u64>,
    pub wifi_up: bool,
    pub wifi_bytes: u64,
    pub bt_on: bool,
    /// Lit, and at what fraction of its brightness range; None dark.
    pub lit: Option<f64>,
    /// The system's real power where a gauge or monitor reports it.
    pub measured_mw: Option<f64>,
    /// Applets whose cgroup is frozen now.
    pub frozen: Vec<String>,
}

#[cfg(test)]
use crate::counters::APPLET_SLICE;

/// Read every counter once.
pub fn snapshot(r: &Roots) -> Snapshot {
    let mut s = Snapshot::default();
    (s.applets, s.frozen) = crate::counters::applets(&r.cgroup, &r.proc_);
    for unit in ["vrx-llm-server.service", "vrx-stt-server.service"] {
        s.models_us += crate::counters::unit_cpu_us(&r.cgroup, unit).unwrap_or(0);
    }
    s.total_us = crate::counters::total_cpu_us(&r.cgroup).unwrap_or(0);
    if let Ok(policies) = std::fs::read_dir(r.sys.join("devices/system/cpu/cpufreq")) {
        for p in policies.flatten() {
            for line in read(&p.path().join("stats/time_in_state"))
                .unwrap_or_default()
                .lines()
            {
                let mut w = line.split_whitespace();
                if let (Some(Ok(khz)), Some(Ok(t))) = (
                    w.next().map(str::parse::<u32>),
                    w.next().map(str::parse::<u64>),
                ) {
                    *s.freq.entry(khz).or_default() += t;
                }
            }
        }
    }
    if let Ok(nets) = std::fs::read_dir(r.sys.join("class/net")) {
        for n in nets.flatten() {
            if !n.file_name().to_string_lossy().starts_with("wlan") {
                continue;
            }
            let p = n.path();
            if read(&p.join("operstate")).is_some_and(|v| v.trim() == "up") {
                s.wifi_up = true;
            }
            s.wifi_bytes += read_u64(&p.join("statistics/rx_bytes")).unwrap_or(0)
                + read_u64(&p.join("statistics/tx_bytes")).unwrap_or(0);
        }
    }
    if let Ok(rf) = std::fs::read_dir(r.sys.join("class/rfkill")) {
        for k in rf.flatten() {
            let p = k.path();
            if read(&p.join("type")).is_some_and(|t| t.trim() == "bluetooth")
                && read(&p.join("state")).is_some_and(|v| v.trim() == "1")
            {
                s.bt_on = true;
            }
        }
    }
    s.lit = lit(r);
    s.measured_mw = measured_mw(r);
    s
}

/// The screen is lit when a connected, enabled connector's DPMS is On;
/// its brightness fraction from the backlight's own level, or from the
/// screen's settings where the compositor dims by alpha.
fn lit(r: &Roots) -> Option<f64> {
    let on = std::fs::read_dir(r.sys.join("class/drm"))
        .ok()?
        .flatten()
        .any(|c| {
            let p = c.path();
            read(&p.join("enabled")).is_some_and(|v| v.trim() == "enabled")
                && read(&p.join("dpms")).is_some_and(|v| v.trim() == "On")
        });
    if !on {
        return None;
    }
    let dim = read(&r.ui.join("screen")).unwrap_or_default();
    if dim.contains("dim=backlight") {
        if let Some(b) = std::fs::read_dir(r.sys.join("class/backlight"))
            .ok()
            .and_then(|mut d| d.next())
            .and_then(Result::ok)
        {
            let level = read_u64(&b.path().join("brightness")).unwrap_or(0) as f64;
            let max = read_u64(&b.path().join("max_brightness"))
                .unwrap_or(1)
                .max(1) as f64;
            return Some(level / max);
        }
    }
    let position = read(&r.display_conf)
        .unwrap_or_default()
        .lines()
        .find_map(|l| {
            l.trim()
                .strip_prefix("brightness=")
                .and_then(|v| v.parse::<f64>().ok())
        })
        .unwrap_or(100.0);
    Some(position / 100.0)
}

/// A discharging battery's power, or a power monitor's.
fn measured_mw(r: &Roots) -> Option<f64> {
    if let Ok(supplies) = std::fs::read_dir(r.sys.join("class/power_supply")) {
        for s in supplies.flatten() {
            let p = s.path();
            if read(&p.join("type")).is_some_and(|t| t.trim() == "Battery")
                && read(&p.join("status")).is_some_and(|t| t.trim() == "Discharging")
            {
                if let Some(uw) = read_u64(&p.join("power_now")) {
                    return Some(uw as f64 / 1000.0);
                }
                let uv = read_u64(&p.join("voltage_now"));
                let ua = read_u64(&p.join("current_now"));
                if let (Some(uv), Some(ua)) = (uv, ua) {
                    return Some(uv as f64 * ua as f64 / 1e9);
                }
            }
        }
    }
    let hw = std::fs::read_dir(r.sys.join("class/hwmon")).ok()?;
    for h in hw.flatten() {
        let p = h.path();
        if read(&p.join("name")).is_some_and(|n| n.trim().starts_with("ina")) {
            if let Some(uw) = read_u64(&p.join("power1_input")) {
                return Some(uw as f64 / 1000.0);
            }
        }
    }
    None
}

/// What one key used in an interval or a minute.
#[derive(Debug, Clone, Copy, Default, PartialEq, Serialize, Deserialize)]
pub struct Use {
    /// Millijoules; 0 on a board that is not calibrated.
    pub mj: f64,
    pub cpu_ms: f64,
    pub gpu_ms: f64,
    pub wakeups: u64,
    /// Seconds the applet was in front.
    pub front_s: f64,
}

impl Use {
    fn add(&mut self, o: &Use) {
        self.mj += o.mj;
        self.cpu_ms += o.cpu_ms;
        self.gpu_ms += o.gpu_ms;
        self.wakeups += o.wakeups;
        self.front_s += o.front_s;
    }
}

/// Price the interval between two snapshots. Keys: applet ids and the
/// `system:` rows.
pub fn charge(
    profile: &PowerProfile,
    before: &Snapshot,
    now: &Snapshot,
    secs: f64,
    front: &str,
) -> BTreeMap<String, Use> {
    let calibrated = profile.calibrated();
    // one busy core's milliwatts, at the frequencies the CPU ran at
    let mut weights = 0u64;
    let mut priced = 0.0;
    for (khz, t) in &now.freq {
        let d = t.saturating_sub(before.freq.get(khz).copied().unwrap_or(0));
        weights += d;
        priced += d as f64 * profile.cpu_mw(*khz);
    }
    let core_mw = if weights > 0 {
        priced / weights as f64
    } else {
        // no cpufreq statistics: the top step, so nothing is under-priced
        profile
            .cpu
            .values()
            .next_back()
            .map_or(0.0, |v| f64::from(*v))
    };
    let price = |cpu_s: f64, gpu_s: f64| {
        if calibrated {
            cpu_s * core_mw + gpu_s * profile.part("gpu")
        } else {
            0.0
        }
    };
    let mut out = BTreeMap::new();
    let mut applets_us = 0u64;
    for (id, c) in &now.applets {
        let b = before.applets.get(id).copied().unwrap_or(*c);
        let cpu_us = c.cpu_us.saturating_sub(b.cpu_us);
        let gpu_ns = c.gpu_ns.saturating_sub(b.gpu_ns);
        applets_us += cpu_us;
        let cpu_s = cpu_us as f64 / 1e6;
        let gpu_s = gpu_ns as f64 / 1e9;
        out.insert(
            id.clone(),
            Use {
                mj: price(cpu_s, gpu_s),
                cpu_ms: cpu_s * 1e3,
                gpu_ms: gpu_s * 1e3,
                wakeups: c.wakeups.saturating_sub(b.wakeups),
                front_s: if id == front { secs } else { 0.0 },
            },
        );
    }
    let models_us = now.models_us.saturating_sub(before.models_us);
    let total_us = now.total_us.saturating_sub(before.total_us);
    let other_us = total_us.saturating_sub(applets_us + models_us);
    let cpu_row = |us: u64| Use {
        mj: price(us as f64 / 1e6, 0.0),
        cpu_ms: us as f64 / 1e3,
        ..Use::default()
    };
    out.insert("system:models".into(), cpu_row(models_us));
    out.insert("system:other".into(), cpu_row(other_us));
    let flat = |mw: f64| Use {
        mj: if calibrated { mw * secs } else { 0.0 },
        ..Use::default()
    };
    out.insert(
        "system:screen".into(),
        now.lit
            .map_or_else(Use::default, |f| flat(profile.display_mw(f))),
    );
    let wifi = if now.wifi_up {
        // a crude activity share: bytes against a busy link's 250 kB/s
        let bytes = now.wifi_bytes.saturating_sub(before.wifi_bytes) as f64;
        let active = (bytes / (secs.max(1.0) * 250_000.0)).min(1.0);
        let idle = profile.part("wifi-idle");
        flat(idle + active * (profile.part("wifi-active") - idle).max(0.0))
    } else {
        Use::default()
    };
    out.insert("system:wifi".into(), wifi);
    out.insert(
        "system:bluetooth".into(),
        if now.bt_on {
            flat(profile.part("bt"))
        } else {
            Use::default()
        },
    );
    out.insert("system:floor".into(), flat(profile.part("floor")));
    // the gauge's or monitor's truth: everything above the floor scaled
    // to it, within reason (a factor of four either way)
    if let (true, Some(real)) = (calibrated, now.measured_mw) {
        let floor = profile.part("floor") * secs;
        let est: f64 = out.values().map(|u| u.mj).sum();
        if est - floor > 1.0 {
            let k = ((real * secs - floor) / (est - floor)).clamp(0.25, 4.0);
            for (key, u) in &mut out {
                if key != "system:floor" {
                    u.mj *= k;
                }
            }
        }
    }
    out
}

/// One minute's use by one key.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MinuteRow {
    pub minute: u64,
    pub key: String,
    #[serde(flatten)]
    pub used: Use,
}

/// An applet over its budget, as the shell shows it.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Alert {
    pub applet: String,
    pub name: String,
    /// "background" or "front".
    pub budget: String,
    /// Its share of the system's power (or of the CPU, not calibrated).
    pub percent: f64,
    /// Unix seconds when it was raised.
    pub since: u64,
    /// The person's answer: "", "later" or "stop"; "frozen" once frozen.
    pub answer: String,
}

/// What an over-budget applet may have done to it.
pub trait Actions: Send + Sync {
    /// Freeze it (the freezer's rules still apply); the outcome, in words.
    fn freeze<'a>(&'a self, applet: &'a str) -> BoxFuture<'a, String>;
    /// Stop its unit.
    fn stop<'a>(&'a self, applet: &'a str) -> BoxFuture<'a, Result<(), String>>;
}

/// The real actions: the freezer's freeze_now, systemd's StopUnit.
pub struct LinuxActions {
    pub freezer: Option<crate::freeze::Freezer>,
    pub applets: crate::applets::Applets,
}

impl Actions for LinuxActions {
    fn freeze<'a>(&'a self, applet: &'a str) -> BoxFuture<'a, String> {
        Box::pin(async move {
            match &self.freezer {
                Some(f) => match f.freeze_now(applet, "over its power budget").await {
                    crate::freeze::Verdict::Freeze => "frozen".to_owned(),
                    crate::freeze::Verdict::Never(why)
                    | crate::freeze::Verdict::NotNow(why) => {
                        format!("kept running: {why}")
                    }
                },
                None => "kept running: no freezer (headless)".to_owned(),
            }
        })
    }

    fn stop<'a>(&'a self, applet: &'a str) -> BoxFuture<'a, Result<(), String>> {
        Box::pin(
            async move { self.applets.stop(applet).await.map_err(|e| e.to_string()) },
        )
    }
}

/// The estimator's state.
struct State {
    profile: PowerProfile,
    profile_error: Option<String>,
    ring: VecDeque<MinuteRow>,
    minute: u64,
    current: BTreeMap<String, Use>,
    hour: u64,
    alerts: BTreeMap<String, Alert>,
    /// The day (unix days) each applet was last alerted: once a day.
    alerted_day: BTreeMap<String, u64>,
    names: BTreeMap<String, String>,
    ncpu: f64,
}

/// The estimator: shared between the sampling loop and io.vrx.Host.
#[derive(Clone)]
pub struct Energy {
    state: Arc<Mutex<State>>,
    alerts: watch::Sender<Vec<Alert>>,
    roots: Roots,
    actions: Arc<dyn Actions>,
}

/// One row of `io.vrx.Host.Energy`.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Row {
    pub key: String,
    pub name: String,
    /// "applet" or "system".
    pub kind: String,
    /// Millijoules over the period; None when not calibrated.
    pub mj: Option<u64>,
    pub cpu_ms: u64,
    pub gpu_ms: u64,
    pub wakeups: u64,
    pub front_s: u64,
    pub over: bool,
}

/// `io.vrx.Host.Energy`'s reply.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Report {
    pub calibrated: bool,
    /// "2026-10-14 with fnb58", when calibrated.
    pub measured: Option<String>,
    /// Why the profile was refused, if it was.
    pub problem: Option<String>,
    pub hours: u32,
    /// Most energy first (most time, not calibrated).
    pub rows: Vec<Row>,
}

/// The wall clock, read once and carried monotonically (review
/// 2026-10-17, CON-12): a board with no RTC steps the clock when NTP
/// first syncs, and a timer that asks the wall clock again sees the step
/// as a huge (or negative) interval — the freeze countdown fired at once
/// and the alert's once-a-day gate re-armed. The anchor is taken at
/// start; day boundaries still use the real calendar clock, read ONCE
/// per transition, never differenced.
fn unix_now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs())
}


/// "2026-10-14" for a unix day (UTC), from Howard Hinnant's civil_from_days.
pub fn date_of(day: u64) -> String {
    let z = day as i64 + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    format!("{:04}-{:02}-{:02}", if m <= 2 { y + 1 } else { y }, m, d)
}

/// Write `text` to `path` through a temporary file and a rename.
fn write_atomic(path: &Path, text: &str) -> std::io::Result<()> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let tmp = path.with_extension("tmp");
    std::fs::write(&tmp, text)?;
    // fsync before the rename (RES-04, review 2026-10-17): the photo
    // store does this and the energy ring did not — a power cut left the
    // rename ahead of the data
    let f = std::fs::File::open(&tmp)?;
    f.sync_all()?;
    drop(f);
    std::fs::rename(tmp, path)
}

/// A journal entry with vrx's structured fields, by journald's native
/// protocol; the log line goes to stderr as well.
fn journal(message: &str, fields: &[(&str, String)]) {
    tracing::warn!("{message}");
    let mut entry = format!("MESSAGE={message}\nPRIORITY=4\nSYSLOG_IDENTIFIER=vrxhost\n");
    for (k, v) in fields {
        entry.push_str(&format!("{k}={}\n", v.replace('\n', " ")));
    }
    // OBS-08 (review 2026-10-17): a send error is SAID, once — a full
    // journald socket dropped the entry silently and the record the
    // review needs was nowhere
    match std::os::unix::net::UnixDatagram::unbound()
        .and_then(|sock| sock.send_to(entry.as_bytes(), "/run/systemd/journal/socket"))
    {
        Ok(_) => {}
        Err(err) => {
            static SAID: std::sync::atomic::AtomicBool =
                std::sync::atomic::AtomicBool::new(false);
            if !SAID.swap(true, std::sync::atomic::Ordering::Relaxed) {
                tracing::warn!(error = %err, "journal socket: entries not landing");
            }
        }
    }
}

impl Energy {
    pub fn new(
        roots: Roots,
        names: BTreeMap<String, String>,
        actions: Arc<dyn Actions>,
    ) -> Self {
        let (profile, profile_error) = load_profile(&roots.profile);
        if let Some(err) = &profile_error {
            tracing::error!(error = %err, "power profile refused: not calibrated");
        } else if !profile.calibrated() {
            tracing::info!("power profile has no measured numbers: not calibrated");
        }
        let ring = read(&roots.ring.join("ring.json"))
            .and_then(|t| serde_json::from_str::<VecDeque<MinuteRow>>(&t).ok())
            .unwrap_or_default();
        let ncpu = std::thread::available_parallelism().map_or(1.0, |n| n.get() as f64);
        let now = unix_now();
        Self {
            state: Arc::new(Mutex::new(State {
                profile,
                profile_error,
                ring,
                minute: now / 60,
                current: BTreeMap::new(),
                hour: now / 3600,
                alerts: BTreeMap::new(),
                alerted_day: BTreeMap::new(),
                names,
                ncpu,
            })),
            alerts: watch::channel(Vec::new()).0,
            roots,
            actions,
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// The alerts now, and on every change (the shell's banner).
    pub fn alerts(&self) -> watch::Receiver<Vec<Alert>> {
        self.alerts.subscribe()
    }

    /// Sample until vrxhost stops; `front` is the applet in front.
    pub async fn run(self, front: watch::Receiver<crate::varlink::Front>) {
        let mut before = snapshot(&self.roots);
        let mut at = std::time::Instant::now();
        loop {
            let tick = if before.lit.is_some() {
                TICK_LIT
            } else {
                TICK_DARK
            };
            tokio::time::sleep(tick).await;
            let now = snapshot(&self.roots);
            let secs = at.elapsed().as_secs_f64();
            at = std::time::Instant::now();
            let top = front.borrow().front.clone();
            let due = self.record(&before, &now, secs, &top, unix_now());
            before = now;
            for applet in due {
                let outcome = self.actions.freeze(&applet).await;
                journal(
                    &format!("{applet}: still over its power budget ten minutes after the alert; {outcome}"),
                    &[("VRX_APPLET", applet.clone()), ("VRX_REASON", "over-budget-freeze".into()), ("VRX_OUTCOME", outcome.clone())],
                );
                self.set_answer(
                    &applet,
                    if outcome == "frozen" {
                        "frozen"
                    } else {
                        "kept"
                    },
                );
            }
        }
    }

    /// Account one interval at unix time `t`; returns the applets due to
    /// be frozen (an unanswered alert ten minutes old, still over, behind
    /// the screen).
    pub fn record(
        &self,
        before: &Snapshot,
        now: &Snapshot,
        secs: f64,
        front: &str,
        t: u64,
    ) -> Vec<String> {
        let mut st = self.lock();
        let used = charge(&st.profile, before, now, secs, front);
        for (k, u) in &used {
            st.current.entry(k.clone()).or_default().add(u);
        }
        let minute = t / 60;
        // CON-12 (review 2026-10-17): a board with no RTC steps at the
        // first NTP sync. Forward closes empty minutes (harmless);
        // BACKWARD once stalled the ring and spun this loop hot — a
        // minute older than the last is skipped until the clock catches
        // up, and said once.
        if minute < st.minute {
            static SAID: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
            if !SAID.swap(true, std::sync::atomic::Ordering::Relaxed) {
                tracing::warn!(minute, last = st.minute, "wall clock stepped back; minute rows wait for it");
            }
            return Vec::new();
        }
        if minute != st.minute {
            let closed = std::mem::take(&mut st.current);
            let m = st.minute;
            for (key, used) in closed {
                st.ring.push_back(MinuteRow {
                    minute: m,
                    key,
                    used,
                });
            }
            while st
                .ring
                .front()
                .is_some_and(|r| r.minute + RING_MINUTES <= minute)
            {
                st.ring.pop_front();
            }
            st.minute = minute;
            if let Ok(text) = serde_json::to_string(&st.ring) {
                if let Err(err) = write_atomic(&self.roots.ring.join("ring.json"), &text)
                {
                    tracing::debug!(error = %err, "energy ring not written");
                }
            }
            let hour = t / 3600;
            if hour != st.hour {
                let done = st.hour;
                st.hour = hour;
                flush_hour(&self.roots.days, &st.ring, done);
            }
        }
        let due = Self::budgets(&mut st, front, t);
        let alerts: Vec<Alert> = st.alerts.values().cloned().collect();
        drop(st);
        self.alerts.send_if_modified(|now| {
            let changed = *now != alerts;
            *now = alerts;
            changed
        });
        due
    }

    /// The share an applet used of the system over the last `minutes`
    /// (energy, or CPU and GPU time against the CPU's capacity when not
    /// calibrated), from the ring and the open minute.
    fn share(st: &State, applet: &str, minutes: u32, t: u64) -> f64 {
        let from = (t / 60).saturating_sub(u64::from(minutes));
        let rows = st
            .ring
            .iter()
            .filter(|r| r.minute >= from)
            .map(|r| (r.key.as_str(), r.used))
            .chain(st.current.iter().map(|(k, u)| (k.as_str(), *u)));
        let (mut mine, mut all, mut mine_t) = (0.0, 0.0, 0.0);
        for (k, u) in rows {
            all += u.mj;
            if k == applet {
                mine += u.mj;
                mine_t += u.cpu_ms + u.gpu_ms;
            }
        }
        if st.profile.calibrated() {
            if all > 0.0 {
                100.0 * mine / all
            } else {
                0.0
            }
        } else {
            100.0 * mine_t / (f64::from(minutes) * 60_000.0 * st.ncpu)
        }
    }

    /// D11: raise, clear and act on budgets.
    fn budgets(st: &mut State, front: &str, t: u64) -> Vec<String> {
        let ids: Vec<String> = st
            .current
            .keys()
            .filter(|k| !k.starts_with("system:"))
            .cloned()
            .collect();
        let mut due = Vec::new();
        for id in ids {
            let in_front = id == front;
            let budget = if in_front {
                st.profile.front
            } else {
                st.profile.background
            };
            let pct = Self::share(st, &id, budget.minutes, t);
            let day = t / 86_400;
            match st.alerts.get(&id).cloned() {
                None if pct > budget.percent && st.alerted_day.get(&id) != Some(&day) => {
                    let name = display_name(&st.names, &id);
                    let kind = if in_front { "front" } else { "background" };
                    journal(
                        &format!(
                            "{name} used {pct:.1} % of the system's power over {} min ({kind} budget {} %)",
                            budget.minutes, budget.percent
                        ),
                        &[
                            ("VRX_APPLET", id.clone()),
                            ("VRX_REASON", format!("over-budget-{kind}")),
                            ("VRX_PERCENT", format!("{pct:.1}")),
                        ],
                    );
                    st.alerted_day.insert(id.clone(), day);
                    st.alerts.insert(
                        id.clone(),
                        Alert {
                            applet: id.clone(),
                            name,
                            budget: kind.into(),
                            percent: (pct * 10.0).round() / 10.0,
                            since: t,
                            answer: String::new(),
                        },
                    );
                }
                // hysteresis: cleared below half the threshold
                Some(_) if pct < budget.percent / 2.0 => {
                    st.alerts.remove(&id);
                }
                // a background script runs behind the screen by design, as
                // an applet declaring `background` does, which the freezer
                // never freezes: it is alerted, and a person stops it from
                // Scripts' Running screen
                Some(a)
                    if a.answer.is_empty()
                        && !in_front
                        && !id.starts_with("script:")
                        && pct > budget.percent
                        && t.saturating_sub(a.since) >= FREEZE_AFTER_S =>
                {
                    due.push(id);
                }
                _ => {}
            }
        }
        due
    }

    fn set_answer(&self, applet: &str, answer: &str) {
        let mut st = self.lock();
        if let Some(a) = st.alerts.get_mut(applet) {
            a.answer = answer.to_owned();
        }
        let alerts: Vec<Alert> = st.alerts.values().cloned().collect();
        drop(st);
        self.alerts.send_replace(alerts);
    }

    /// The person answered the banner: "stop" stops the applet, "later"
    /// leaves it (and nothing is done to it without them).
    pub async fn answer(&self, applet: &str, answer: &str) -> Result<(), String> {
        if !self.lock().alerts.contains_key(applet) {
            return Err(format!("{applet} has no alert"));
        }
        match answer {
            "later" => {
                journal(
                    &format!("{applet}: the person said not now"),
                    &[
                        ("VRX_APPLET", applet.into()),
                        ("VRX_REASON", "over-budget-later".into()),
                    ],
                );
                self.set_answer(applet, "later");
                Ok(())
            }
            "stop" => {
                self.actions.stop(applet).await?;
                journal(
                    &format!("{applet}: stopped by the person"),
                    &[
                        ("VRX_APPLET", applet.into()),
                        ("VRX_REASON", "over-budget-stop".into()),
                    ],
                );
                self.lock().alerts.remove(applet);
                let alerts: Vec<Alert> = self.lock().alerts.values().cloned().collect();
                self.alerts.send_replace(alerts);
                Ok(())
            }
            other => Err(format!("{other:?}: later or stop")),
        }
    }

    /// The last `hours` (1-24), most energy (or time) first.
    pub fn report(&self, hours: u32, t: u64) -> Report {
        let hours = hours.clamp(1, 24);
        let st = self.lock();
        let from = (t / 60).saturating_sub(u64::from(hours) * 60);
        let mut totals: BTreeMap<String, Use> = BTreeMap::new();
        for r in st.ring.iter().filter(|r| r.minute >= from) {
            totals.entry(r.key.clone()).or_default().add(&r.used);
        }
        for (k, u) in &st.current {
            totals.entry(k.clone()).or_default().add(u);
        }
        let calibrated = st.profile.calibrated();
        let system: BTreeMap<&str, &str> = SYSTEM_ROWS.into_iter().collect();
        let mut rows: Vec<Row> = totals
            .into_iter()
            .map(|(key, u)| {
                let (kind, name) = match system.get(key.as_str()) {
                    Some(n) => ("system", (*n).to_owned()),
                    None => ("applet", display_name(&st.names, &key)),
                };
                Row {
                    over: st.alerts.contains_key(&key),
                    name,
                    kind: kind.into(),
                    mj: calibrated.then_some(u.mj.round() as u64),
                    cpu_ms: u.cpu_ms.round() as u64,
                    gpu_ms: u.gpu_ms.round() as u64,
                    wakeups: u.wakeups,
                    front_s: u.front_s.round() as u64,
                    key,
                }
            })
            .filter(|r| r.mj.unwrap_or(0) > 0 || r.cpu_ms + r.gpu_ms > 0 || r.front_s > 0)
            .collect();
        rows.sort_by(|a, b| {
            let w = |r: &Row| r.mj.map_or((r.cpu_ms + r.gpu_ms) as f64, |m| m as f64);
            w(b).total_cmp(&w(a)).then_with(|| a.key.cmp(&b.key))
        });
        Report {
            calibrated,
            measured: st
                .profile
                .measured
                .as_ref()
                .map(|m| format!("{} with {}", m.date, m.meter)),
            problem: st.profile_error.clone(),
            hours,
            rows,
        }
    }

    /// Why the device is awake (D12), read now.
    pub async fn awake(&self) -> Awake {
        let s = snapshot(&self.roots);
        let inhibitors = inhibitors().await;
        let mut running: Vec<String> = s
            .applets
            .keys()
            .filter(|k| !s.frozen.contains(k))
            .cloned()
            .collect();
        running.sort();
        let policy = self.roots.sys.join("devices/system/cpu/cpufreq/policy0");
        let wakeups = std::fs::read_dir(self.roots.sys.join("class/wakeup"))
            .map(|d| {
                let mut w: Vec<WakeupSource> = d
                    .flatten()
                    .filter_map(|e| {
                        let p = e.path();
                        Some(WakeupSource {
                            name: read(&p.join("name"))?.trim().to_owned(),
                            events: read_u64(&p.join("event_count")).unwrap_or(0),
                        })
                    })
                    .collect();
                w.sort_by(|a, b| {
                    b.events.cmp(&a.events).then_with(|| a.name.cmp(&b.name))
                });
                w
            })
            .unwrap_or_default();
        Awake {
            inhibitors,
            running,
            frozen: s.frozen,
            wakeups,
            governor: read(&policy.join("scaling_governor"))
                .unwrap_or_default()
                .trim()
                .to_owned(),
            khz: read_u64(&policy.join("scaling_cur_freq")).unwrap_or(0),
            temp_mc: std::fs::read_dir(self.roots.sys.join("class/thermal"))
                .ok()
                .and_then(|d| d.flatten().find_map(|z| read_u64(&z.path().join("temp")))),
            supply_low: crate::facts::subscribe().borrow().supply_low,
            screen_on: s.lit.is_some(),
        }
    }
}

/// Add the finished hour's totals per key to its day's file on /data
/// (one small file per day; systemd-tmpfiles-clean keeps 14). A board
/// without /data keeps the ring only.
fn flush_hour(days: &Path, ring: &VecDeque<MinuteRow>, hour: u64) {
    let mut totals: BTreeMap<String, Use> = BTreeMap::new();
    for r in ring.iter().filter(|r| r.minute / 60 == hour) {
        totals.entry(r.key.clone()).or_default().add(&r.used);
    }
    if totals.is_empty() || !days.parent().is_some_and(Path::exists) {
        return;
    }
    let day = hour / 24;
    let path = days.join(format!("{}.json", date_of(day)));
    let mut file: BTreeMap<String, BTreeMap<String, Use>> = read(&path)
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or_default();
    file.insert(format!("{:02}", hour % 24), totals);
    match serde_json::to_string(&file) {
        Ok(text) => {
            if let Err(err) = write_atomic(&path, &text) {
                tracing::warn!(path = %path.display(), error = %err, "energy summary not written");
            }
        }
        Err(err) => tracing::warn!(error = %err, "energy summary not encoded"),
    }
    // old days are systemd-tmpfiles-clean's to expire (vrxhost-tmpfiles.conf:
    // `d /data/vrx/energy … 14d`)
}

/// One logind inhibitor, and the applet holding it if one does.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Inhibitor {
    pub what: String,
    pub who: String,
    pub why: String,
    pub mode: String,
    pub applet: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct WakeupSource {
    pub name: String,
    pub events: u64,
}

/// `io.vrx.Host.Awake`'s reply.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Awake {
    pub inhibitors: Vec<Inhibitor>,
    pub running: Vec<String>,
    pub frozen: Vec<String>,
    pub wakeups: Vec<WakeupSource>,
    pub governor: String,
    pub khz: u64,
    pub temp_mc: Option<u64>,
    pub supply_low: bool,
    pub screen_on: bool,
}

// logind's Manager, one proxy for vrxhost (Awake, the freezer, the
// battery's power-off).

/// One of logind's inhibitors as ListInhibitors returns it: what, who,
/// why, mode, uid, pid.
pub type InhibitorRow = (String, String, String, String, u32, u32);

#[zbus::proxy(
    interface = "org.freedesktop.login1.Manager",
    default_service = "org.freedesktop.login1",
    default_path = "/org/freedesktop/login1"
)]
trait Login {
    fn list_inhibitors(&self) -> zbus::Result<Vec<InhibitorRow>>;
    fn power_off(&self, interactive: bool) -> zbus::Result<()>;
}

/// Power off through logind, asking nobody (the battery's critical zone).
pub async fn power_off() -> zbus::Result<()> {
    let conn = zbus::Connection::system().await?;
    LoginProxy::new(&conn).await?.power_off(false).await
}

/// logind's inhibitors now: the one reader, for Awake and the freezer.
pub async fn inhibitor_rows() -> zbus::Result<Vec<InhibitorRow>> {
    let conn = zbus::Connection::system().await?;
    LoginProxy::new(&conn).await?.list_inhibitors().await
}

async fn inhibitors() -> Vec<Inhibitor> {
    let list = inhibitor_rows();
    match list.await {
        Ok(list) => list
            .into_iter()
            .map(|(what, who, why, mode, _uid, pid)| Inhibitor {
                applet: crate::applets::applet_of_pid(pid),
                what,
                who,
                why,
                mode,
            })
            .collect(),
        Err(err) => {
            tracing::debug!(error = %err, "logind inhibitors unread");
            Vec::new()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const PROFILE: &str = "\
model floor 1000 measured=2026-10-14 meter=fnb58
model cpu 600000 200 measured=2026-10-14 meter=fnb58
model cpu 1500000 600 measured=2026-10-14 meter=fnb58
model gpu 500 measured=2026-10-14 meter=fnb58
model display 800 measured=2026-10-14 meter=fnb58
model display-dim 400 measured=2026-10-14 meter=fnb58
budget background 5 10
";

    fn snap(
        applets: &[(&str, u64, u64, u64)],
        total_us: u64,
        freq: &[(u32, u64)],
        lit: Option<f64>,
    ) -> Snapshot {
        Snapshot {
            applets: applets
                .iter()
                .map(|(id, cpu_us, gpu_ns, wakeups)| {
                    (
                        (*id).to_owned(),
                        Counters {
                            cpu_us: *cpu_us,
                            gpu_ns: *gpu_ns,
                            gpu_clients: u32::from(*gpu_ns > 0),
                            wakeups: *wakeups,
                            ..Counters::default()
                        },
                    )
                })
                .collect(),
            total_us,
            freq: freq.iter().copied().collect(),
            lit,
            ..Snapshot::default()
        }
    }

    #[test]
    fn an_interval_is_priced_by_frequency_and_parts() {
        let p = PowerProfile::parse("p", PROFILE).unwrap();
        let a = snap(
            &[("web", 0, 0, 0)],
            0,
            &[(600_000, 0), (1_500_000, 0)],
            Some(1.0),
        );
        // 10 s: web used 2 s of CPU and 1 s of GPU; the CPU spent half its
        // time at each step
        let b = snap(
            &[("web", 2_000_000, 1_000_000_000, 7)],
            3_000_000,
            &[(600_000, 500), (1_500_000, 500)],
            Some(1.0),
        );
        let used = charge(&p, &a, &b, 10.0, "web");
        let web = used["web"];
        assert!(
            (web.mj - (2.0 * 400.0 + 1.0 * 500.0)).abs() < 1e-6,
            "{web:?}"
        );
        assert_eq!(web.wakeups, 7);
        assert_eq!(web.front_s, 10.0);
        assert!((used["system:screen"].mj - 8000.0).abs() < 1e-6);
        assert!((used["system:floor"].mj - 10_000.0).abs() < 1e-6);
        assert!(
            (used["system:other"].cpu_ms - 1000.0).abs() < 1e-6,
            "total minus applets"
        );
    }

    #[test]
    fn not_calibrated_counts_time_but_invents_no_energy() {
        let p = PowerProfile::default();
        let a = snap(&[("web", 0, 0, 0)], 0, &[], Some(0.5));
        let b = snap(&[("web", 2_000_000, 0, 0)], 2_000_000, &[], Some(0.5));
        let used = charge(&p, &a, &b, 10.0, "");
        assert_eq!(used["web"].mj, 0.0);
        assert_eq!(used["web"].cpu_ms, 2000.0);
        assert_eq!(used["system:screen"].mj, 0.0);
    }

    #[test]
    fn a_measured_total_scales_the_shares_above_the_floor() {
        let p = PowerProfile::parse("p", PROFILE).unwrap();
        let a = snap(&[("web", 0, 0, 0)], 0, &[(1_500_000, 0)], None);
        let mut b = snap(
            &[("web", 10_000_000, 0, 0)],
            10_000_000,
            &[(1_500_000, 1000)],
            None,
        );
        // estimate: floor 10 J + web 6 J = 16 J over 10 s; the gauge says 1.9 W
        b.measured_mw = Some(1900.0);
        let used = charge(&p, &a, &b, 10.0, "");
        assert!(
            (used["system:floor"].mj - 10_000.0).abs() < 1e-6,
            "the floor stays"
        );
        assert!((used["web"].mj - 9_000.0).abs() < 1e-3, "{:?}", used["web"]);
    }

    struct Recorded(Mutex<Vec<String>>);
    impl Actions for Recorded {
        fn freeze<'a>(&'a self, applet: &'a str) -> BoxFuture<'a, String> {
            self.0.lock().unwrap().push(format!("freeze {applet}"));
            Box::pin(async { "frozen".to_owned() })
        }
        fn stop<'a>(&'a self, applet: &'a str) -> BoxFuture<'a, Result<(), String>> {
            self.0.lock().unwrap().push(format!("stop {applet}"));
            Box::pin(async { Ok(()) })
        }
    }

    fn energy(dir: &Path) -> (Energy, Arc<Recorded>) {
        std::fs::write(dir.join("power-profile"), PROFILE).unwrap();
        let roots = Roots {
            sys: dir.join("sys"),
            proc_: dir.join("proc"),
            cgroup: dir.join("cg"),
            ui: dir.join("ui"),
            display_conf: dir.join("screen.conf"),
            profile: dir.join("power-profile"),
            ring: dir.join("ring"),
            days: dir.join("data/energy"),
        };
        let actions = Arc::new(Recorded(Mutex::new(Vec::new())));
        let names = [("web".to_owned(), "Web requests".to_owned())]
            .into_iter()
            .collect();
        (Energy::new(roots, names, actions.clone()), actions)
    }

    /// web busy on one core behind the screen, for `minutes` from `t0`.
    fn busy(
        e: &Energy,
        t0: u64,
        minutes: u64,
        cpu_per_tick_us: u64,
    ) -> (u64, Vec<String>) {
        let mut due_all = Vec::new();
        let mut cpu = 0;
        let mut t = t0;
        let mut before = snap(&[("web", 0, 0, 0)], 0, &[(1_500_000, 0)], None);
        for i in 1..=minutes * 6 {
            cpu += cpu_per_tick_us;
            let now = snap(&[("web", cpu, 0, 0)], cpu, &[(1_500_000, i * 1000)], None);
            t = t0 + i * 10;
            due_all.extend(e.record(&before, &now, 10.0, "launcher", t));
            before = now;
        }
        (t, due_all)
    }

    #[test]
    fn a_busy_background_applet_is_alerted_once_and_frozen_ten_minutes_later() {
        let dir = tempfile::tempdir().unwrap();
        let (e, actions) = energy(dir.path());
        let t0 = 1_791_900_000 - 1_791_900_000 % 86_400 + 3600;
        // busy: 5 s of CPU per 10 s tick (half a core), far above 5 %
        let (_, due) = busy(&e, t0, 3, 5_000_000);
        let alerts = e.alerts().borrow().clone();
        assert_eq!(alerts.len(), 1);
        assert_eq!(alerts[0].name, "Web requests");
        assert_eq!(alerts[0].budget, "background");
        assert!(due.is_empty(), "the alert is younger than ten minutes");
        let (t, due) = busy(&e, t0 + 3 * 60, 10, 5_000_000);
        assert_eq!(
            due.first().map(String::as_str),
            Some("web"),
            "unanswered, still over, behind the screen"
        );
        // never twice in a day: cleared and over again, no new alert
        e.lock().alerts.clear();
        let _ = busy(&e, t, 3, 5_000_000);
        assert!(e.alerts().borrow().is_empty());
        assert!(
            actions.0.lock().unwrap().is_empty(),
            "record() decides; run() acts"
        );
    }

    #[tokio::test]
    async fn an_answered_alert_is_not_frozen_and_stop_stops() {
        let dir = tempfile::tempdir().unwrap();
        let (e, actions) = energy(dir.path());
        let t0 = 1_791_900_000;
        let _ = busy(&e, t0, 12, 5_000_000);
        e.answer("web", "later").await.unwrap();
        let (_, due) = busy(&e, t0 + 12 * 60, 12, 5_000_000);
        assert!(due.is_empty(), "the person said not now");
        e.answer("web", "stop").await.unwrap();
        assert_eq!(actions.0.lock().unwrap().as_slice(), ["stop web"]);
        assert!(e.alerts().borrow().is_empty());
        assert!(e.answer("web", "stop").await.is_err(), "no alert any more");
    }

    #[test]
    fn a_quiet_applet_is_never_alerted_and_the_report_ranks_by_energy() {
        let dir = tempfile::tempdir().unwrap();
        let (e, _) = energy(dir.path());
        let (t, _) = busy(&e, 1_791_900_000, 15, 20_000);
        assert!(e.alerts().borrow().is_empty(), "0.2 % of a core");
        let r = e.report(24, t);
        assert!(r.calibrated);
        assert_eq!(r.measured.as_deref(), Some("2026-10-14 with fnb58"));
        assert_eq!(
            r.rows[0].key, "system:floor",
            "the floor dominates an idle board"
        );
        let web = r.rows.iter().find(|r| r.key == "web").unwrap();
        assert_eq!(web.name, "Web requests");
        assert!(web.mj.unwrap() > 0);
        assert!(
            dir.path().join("ring/ring.json").exists(),
            "the ring is on tmpfs"
        );
    }

    #[test]
    fn counters_are_read_from_cgroups_and_fdinfo() {
        let dir = tempfile::tempdir().unwrap();
        let d = dir.path();
        let unit = d
            .join("cg")
            .join(APPLET_SLICE)
            .join("vrx-applet@web.service");
        std::fs::create_dir_all(&unit).unwrap();
        std::fs::write(unit.join("cpu.stat"), "usage_usec 1234\nuser_usec 1000\n")
            .unwrap();
        std::fs::write(unit.join("cgroup.procs"), "42\n").unwrap();
        std::fs::write(unit.join("cgroup.freeze"), "1\n").unwrap();
        std::fs::write(d.join("cg/cpu.stat"), "usage_usec 99999\n").unwrap();
        let p = d.join("proc/42");
        std::fs::create_dir_all(p.join("fd")).unwrap();
        std::fs::create_dir_all(p.join("fdinfo")).unwrap();
        std::fs::write(
            p.join("status"),
            "Name:\tapp\nvoluntary_ctxt_switches:\t17\n",
        )
        .unwrap();
        std::os::unix::fs::symlink("/dev/dri/renderD128", p.join("fd/7")).unwrap();
        std::os::unix::fs::symlink("/dev/dri/renderD128", p.join("fd/8")).unwrap();
        std::os::unix::fs::symlink("/dev/null", p.join("fd/0")).unwrap();
        std::fs::write(
            p.join("fdinfo/7"),
            "drm-client-id:\t5\ndrm-engine-render:\t300 ns\ndrm-engine-bin:\t200 ns\n",
        )
        .unwrap();
        std::fs::write(
            p.join("fdinfo/8"),
            "drm-client-id:\t5\ndrm-engine-render:\t300 ns\n",
        )
        .unwrap();
        let roots = Roots {
            sys: d.join("sys"),
            proc_: d.join("proc"),
            cgroup: d.join("cg"),
            ui: d.join("ui"),
            display_conf: d.join("c"),
            profile: d.join("p"),
            ring: d.join("r"),
            days: d.join("x"),
        };
        let s = snapshot(&roots);
        let web = s.applets["web"];
        assert_eq!(
            (web.cpu_us, web.gpu_ns, web.wakeups),
            (1234, 500, 17),
            "one client counted once"
        );
        assert_eq!(s.total_us, 99999);
        assert_eq!(s.frozen, ["web"]);
        assert_eq!(s.lit, None, "no connector: dark");
    }

    #[test]
    fn dates_are_civil() {
        assert_eq!(date_of(0), "1970-01-01");
        assert_eq!(date_of(1_791_936_000 / 86_400), "2026-10-14");
    }
}
