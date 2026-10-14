// The profiler's runtime switch and its counter output (plan 0014 D1, D4,
// D5). Profiling is two switches: the opt-in layer meta-vrx-profiling
// puts the tools in an image (its configs in /usr/share/vrx/profile mark
// it), and this switch turns the cheap in-process records into trace
// output on an image that has the layer. vrxhost owns the switch: a
// person (a caller that is no applet: root at the shell, varlinkctl, the
// walk driver) sets it with io.vrx.Host.Profiling; vrxhost writes
// /run/vrx/profiling as the record, tells applets through Facts (the
// kit's frame timings) and the compositor on its control link (the flip
// record).
//
// While it is on, vrxhost reads the shared counters (counters.rs, G037)
// once a second and writes each applet's rates as Perfetto counter lines
// on ftrace's trace_marker (`C|<pid>|vrx.<applet>.<metric>|<value>`):
// Perfetto's systrace importer turns them into counter tracks, so
// vrxhost needs no tracing SDK. Applets' frame summaries (the kit's
// FrameTiming aggregation, every 5 s) arrive on io.vrx.Host.FrameStats
// and go out the same way; the latest of everything is what
// io.vrx.Host.ProfileStats answers, for walks.
//
// A source that cannot be read is absent from the output, never written
// as 0 (G040).

use std::collections::BTreeMap;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use serde::Serialize;
use tokio::sync::watch;

use crate::counters::Applet;

/// The record of the switch, for anything that reads files.
pub const SWITCH: &str = "/run/vrx/profiling";
/// Installed by meta-vrx-profiling: an image without it was built without
/// profiling.
pub const LAYER_MARK: &str = "/usr/share/vrx/profile";
pub const TRACE_MARKER: &str = "/sys/kernel/tracing/trace_marker";
pub const DEBUGFS: &str = "/sys/kernel/debug";

/// What the switch reports.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Status {
    pub on: bool,
    /// The image has the profiling layer.
    pub available: bool,
    /// Why not, in a sentence, when not available or a source is missing.
    pub reason: Option<String>,
    /// ftrace's trace_marker can be written (tracefs mounted).
    pub trace_marker: bool,
    /// The kernel was booted with pressure stall information on.
    pub psi: bool,
}

/// An applet's frame summary over the last window, from the kit.
#[derive(Debug, Clone, Default, PartialEq, Serialize, serde::Deserialize)]
pub struct Frames {
    pub route: String,
    pub frames: u64,
    pub build_p50_us: u64,
    pub build_p95_us: u64,
    pub build_p99_us: u64,
    pub raster_p50_us: u64,
    pub raster_p95_us: u64,
    pub raster_p99_us: u64,
    /// Frames whose build or raster phase overran the refresh budget.
    pub over_build: u64,
    pub over_raster: u64,
    pub budget_us: u64,
}

/// One applet's rates over the last second, and its latest frame summary.
#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct AppletStats {
    pub cpu_ms_per_s: f64,
    /// None where the board's GPU driver reports no engine time.
    pub gpu_ms_per_s: Option<f64>,
    pub wakeups_per_s: f64,
    pub mem_mb: Option<f64>,
    pub mem_peak_mb: Option<f64>,
    pub read_kb_per_s: Option<f64>,
    pub write_kb_per_s: Option<f64>,
    pub cpu_stall_ms_per_s: Option<f64>,
    pub mem_stall_ms_per_s: Option<f64>,
    pub io_stall_ms_per_s: Option<f64>,
    pub frames: Option<Frames>,
}

/// The rates between two readings `dt_s` apart, as (metric, value) pairs
/// in the order they are written, and the same as a struct. A counter
/// that went backwards (a restarted applet) gives no rate.
pub fn rates(prev: &Applet, now: &Applet, dt_s: f64) -> AppletStats {
    let per_s = |a: u64, b: u64, scale: f64| -> Option<f64> {
        (dt_s > 0.0 && b >= a).then(|| (b - a) as f64 / scale / dt_s)
    };
    let opt = |a: Option<u64>, b: Option<u64>, scale: f64| -> Option<f64> {
        per_s(a?, b?, scale)
    };
    AppletStats {
        cpu_ms_per_s: per_s(prev.cpu_us, now.cpu_us, 1_000.0).unwrap_or(0.0),
        gpu_ms_per_s: (now.gpu_clients > 0)
            .then(|| per_s(prev.gpu_ns, now.gpu_ns, 1_000_000.0))
            .flatten(),
        wakeups_per_s: per_s(prev.wakeups, now.wakeups, 1.0).unwrap_or(0.0),
        mem_mb: now.mem_bytes.map(|b| b as f64 / 1_048_576.0),
        mem_peak_mb: now.mem_peak_bytes.map(|b| b as f64 / 1_048_576.0),
        read_kb_per_s: opt(prev.io_read_bytes, now.io_read_bytes, 1024.0),
        write_kb_per_s: opt(prev.io_write_bytes, now.io_write_bytes, 1024.0),
        cpu_stall_ms_per_s: opt(prev.cpu_stall_us, now.cpu_stall_us, 1_000.0),
        mem_stall_ms_per_s: opt(prev.mem_stall_us, now.mem_stall_us, 1_000.0),
        io_stall_ms_per_s: opt(prev.io_stall_us, now.io_stall_us, 1_000.0),
        frames: None,
    }
}

/// The counter lines for one applet's stats: only what was measured.
pub fn counter_lines(pid: u32, applet: &str, s: &AppletStats) -> Vec<String> {
    let mut out = Vec::new();
    let mut put = |name: &str, v: Option<f64>| {
        if let Some(v) = v {
            out.push(format!("C|{pid}|vrx.{applet}.{name}|{}", v.round() as i64));
        }
    };
    put("cpu_ms_per_s", Some(s.cpu_ms_per_s));
    put("gpu_ms_per_s", s.gpu_ms_per_s);
    put("wakeups_per_s", Some(s.wakeups_per_s));
    put("mem_mb", s.mem_mb);
    put("read_kb_per_s", s.read_kb_per_s);
    put("write_kb_per_s", s.write_kb_per_s);
    put("cpu_stall_ms_per_s", s.cpu_stall_ms_per_s);
    put("mem_stall_ms_per_s", s.mem_stall_ms_per_s);
    put("io_stall_ms_per_s", s.io_stall_ms_per_s);
    out
}

/// The counter lines for a frame summary.
pub fn frame_lines(pid: u32, applet: &str, f: &Frames) -> Vec<String> {
    [
        ("frames", f.frames),
        ("build_p95_us", f.build_p95_us),
        ("raster_p95_us", f.raster_p95_us),
        ("over_build", f.over_build),
        ("over_raster", f.over_raster),
    ]
    .iter()
    .map(|(name, v)| format!("C|{pid}|vrx.{applet}.{name}|{v}"))
    .collect()
}

/// ftrace's trace_marker, or nowhere.
pub struct Marker {
    file: Option<std::fs::File>,
}

impl Marker {
    pub fn open(path: &Path) -> Self {
        Self {
            file: std::fs::OpenOptions::new().write(true).open(path).ok(),
        }
    }

    pub fn works(&self) -> bool {
        self.file.is_some()
    }

    /// Each line is one write: trace_marker takes a write as one event.
    pub fn write(&mut self, line: &str) {
        if let Some(f) = self.file.as_mut() {
            if f.write_all(line.as_bytes()).is_err() {
                self.file = None;
            }
        }
    }
}

/// The switch, the latest stats, and where to read.
#[derive(Clone)]
pub struct Profiler {
    inner: Arc<Mutex<Inner>>,
    on: watch::Sender<bool>,
    /// Walks' semantics trees (plan 0014 D8).
    semantics: watch::Sender<bool>,
    layer: PathBuf,
    record: PathBuf,
    marker: PathBuf,
    cgroup: PathBuf,
    proc_: PathBuf,
    debugfs: PathBuf,
}

#[derive(Default)]
struct Inner {
    stats: BTreeMap<String, AppletStats>,
    underruns: Option<u64>,
}

impl Profiler {
    pub fn system() -> Self {
        Self::new(
            PathBuf::from(LAYER_MARK),
            PathBuf::from(SWITCH),
            PathBuf::from(TRACE_MARKER),
            PathBuf::from("/sys/fs/cgroup"),
            PathBuf::from("/proc"),
            PathBuf::from(DEBUGFS),
        )
    }

    pub fn new(
        layer: PathBuf,
        record: PathBuf,
        marker: PathBuf,
        cgroup: PathBuf,
        proc_: PathBuf,
        debugfs: PathBuf,
    ) -> Self {
        Self {
            inner: Arc::new(Mutex::new(Inner::default())),
            on: watch::channel(false).0,
            semantics: watch::channel(false).0,
            layer,
            record,
            marker,
            cgroup,
            proc_,
            debugfs,
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Inner> {
        self.inner
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// The switch, as a channel (the compositor link and Facts follow it).
    pub fn watch(&self) -> watch::Receiver<bool> {
        self.on.subscribe()
    }

    pub fn status(&self) -> Status {
        let available = self.layer.is_dir();
        let trace_marker = Marker::open(&self.marker).works();
        let psi = std::fs::read_to_string("/proc/pressure/cpu").is_ok();
        let reason = if !available {
            Some("this image was built without profiling (meta-vrx-profiling)".to_owned())
        } else if !trace_marker {
            Some(
                "ftrace's trace_marker cannot be written: tracefs is not mounted"
                    .to_owned(),
            )
        } else if !psi {
            Some(
                "pressure stall rows are not available: psi=0 on the kernel command line"
                    .to_owned(),
            )
        } else {
            None
        };
        Status {
            on: *self.on.borrow(),
            available,
            reason,
            trace_marker,
            psi,
        }
    }

    /// Switch on or off. Refused on an image without the layer.
    pub fn set(&self, on: bool) -> Result<Status, String> {
        if on && !self.layer.is_dir() {
            return Err(
                "this image was built without profiling (meta-vrx-profiling)".to_owned(),
            );
        }
        if on {
            if let Some(dir) = self.record.parent() {
                let _ = std::fs::create_dir_all(dir);
            }
            let _ = std::fs::write(&self.record, "1\n");
        } else {
            let _ = std::fs::remove_file(&self.record);
            self.lock().stats.clear();
        }
        self.on.send_replace(on);
        tracing::info!(on, "profiling switched");
        Ok(self.status())
    }

    /// The semantics trees' switch, as a channel (the compositor link).
    pub fn watch_semantics(&self) -> watch::Receiver<bool> {
        self.semantics.subscribe()
    }

    /// Walks turn the semantics trees on to find controls by label, and
    /// off for timed runs (the tree costs a build pass per frame).
    pub fn set_semantics(&self, on: bool) -> bool {
        self.semantics.send_replace(on);
        tracing::info!(on, "semantics trees switched");
        on
    }

    /// An applet's frame summary (the kit sends one every 5 s while on).
    pub fn frames(&self, applet: &str, f: Frames) {
        if !*self.on.borrow() {
            return;
        }
        let mut m = Marker::open(&self.marker);
        for line in frame_lines(std::process::id(), applet, &f) {
            m.write(&line);
        }
        self.lock()
            .stats
            .entry(applet.to_owned())
            .or_default()
            .frames = Some(f);
    }

    /// The latest stats, for walks.
    pub fn stats(&self) -> (BTreeMap<String, AppletStats>, Option<u64>) {
        let st = self.lock();
        (st.stats.clone(), st.underruns)
    }

    /// While on: read the shared counters once a second and write them.
    pub async fn run(self) {
        let mut on = self.on.subscribe();
        loop {
            while !*on.borrow_and_update() {
                if on.changed().await.is_err() {
                    return;
                }
            }
            let mut marker = Marker::open(&self.marker);
            let mut prev = crate::counters::applets(&self.cgroup, &self.proc_).0;
            let mut last = std::time::Instant::now();
            let mut tick = tokio::time::interval(std::time::Duration::from_secs(1));
            tick.tick().await;
            while *on.borrow() {
                tokio::select! {
                    _ = tick.tick() => {}
                    changed = on.changed() => {
                        if changed.is_err() { return; }
                        continue;
                    }
                }
                let now = crate::counters::applets(&self.cgroup, &self.proc_).0;
                let dt = last.elapsed().as_secs_f64();
                last = std::time::Instant::now();
                let pid = std::process::id();
                let underruns = crate::counters::hvs_underruns(&self.debugfs);
                let mut st = self.lock();
                for (id, c) in &now {
                    let Some(p) = prev.get(id) else { continue };
                    let mut s = rates(p, c, dt);
                    s.frames = st.stats.get(id).and_then(|o| o.frames.clone());
                    for line in counter_lines(pid, id, &s) {
                        marker.write(&line);
                    }
                    st.stats.insert(id.clone(), s);
                }
                if let Some(n) = underruns {
                    marker.write(&format!("C|{pid}|vrx.hvs_underruns|{n}"));
                }
                st.underruns = underruns;
                drop(st);
                prev = now;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn applet(cpu_us: u64, gpu_ns: u64, gpu_clients: u32, io: Option<u64>) -> Applet {
        Applet {
            cpu_us,
            gpu_ns,
            gpu_clients,
            wakeups: cpu_us / 100,
            mem_bytes: Some(32 * 1_048_576),
            io_read_bytes: io,
            io_write_bytes: io,
            ..Applet::default()
        }
    }

    #[test]
    fn rates_are_per_second_and_a_missing_source_stays_missing() {
        let s = rates(
            &applet(1_000_000, 0, 1, Some(0)),
            &applet(1_250_000, 40_000_000, 1, Some(10_240)),
            2.0,
        );
        assert_eq!(s.cpu_ms_per_s, 125.0);
        assert_eq!(s.gpu_ms_per_s, Some(20.0));
        assert_eq!(s.read_kb_per_s, Some(5.0));
        assert_eq!(s.mem_mb, Some(32.0));
        assert_eq!(
            s.cpu_stall_ms_per_s, None,
            "no pressure file: absent (G040)"
        );
        let lines = counter_lines(7, "web", &s);
        assert!(lines.contains(&"C|7|vrx.web.cpu_ms_per_s|125".to_owned()));
        assert!(
            !lines.iter().any(|l| l.contains("stall")),
            "absent, never 0"
        );
    }

    #[test]
    fn a_driver_without_engine_time_has_no_gpu_rate() {
        let s = rates(&applet(0, 0, 0, None), &applet(100, 0, 0, None), 1.0);
        assert_eq!(s.gpu_ms_per_s, None);
        assert_eq!(s.read_kb_per_s, None);
        assert!(!counter_lines(1, "clock", &s)
            .iter()
            .any(|l| l.contains("gpu")));
    }

    #[test]
    fn a_restarted_applet_gives_no_rate_from_a_counter_that_went_back() {
        let s = rates(
            &applet(5_000, 0, 1, Some(10)),
            &applet(100, 0, 1, Some(0)),
            1.0,
        );
        assert_eq!(s.cpu_ms_per_s, 0.0);
        assert_eq!(s.read_kb_per_s, None);
    }

    #[test]
    fn the_switch_is_refused_without_the_layer_and_recorded_with_it() {
        let dir = tempfile::tempdir().unwrap();
        let d = dir.path();
        let p = Profiler::new(
            d.join("layer"),
            d.join("run/profiling"),
            d.join("marker"),
            d.join("cg"),
            d.join("proc"),
            d.join("debug"),
        );
        let err = p.set(true).unwrap_err();
        assert!(err.contains("built without profiling"));
        assert!(!p.status().available);
        std::fs::create_dir_all(d.join("layer")).unwrap();
        std::fs::write(d.join("marker"), "").unwrap();
        let st = p.set(true).unwrap();
        assert!(st.on && st.available && st.trace_marker);
        assert!(d.join("run/profiling").exists());
        p.frames(
            "web",
            Frames {
                frames: 60,
                build_p95_us: 4000,
                ..Frames::default()
            },
        );
        let written = std::fs::read_to_string(d.join("marker")).unwrap();
        assert!(written.contains("C|"), "frame counters reach the marker");
        assert!(p.stats().0["web"].frames.is_some());
        p.set(false).unwrap();
        assert!(!d.join("run/profiling").exists());
        assert!(p.stats().0.is_empty());
    }
}
