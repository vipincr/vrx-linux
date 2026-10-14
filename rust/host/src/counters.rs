// Every per-applet counter vrxhost reads, read here once (plan 0014 D4,
// G037): the energy estimate (energy.rs, plan 0012 D8) and the profiler
// (profile.rs) both call this module, so one reading has one reader.
// All of it is Linux's own accounting, read from files:
//
// - each applet unit's cgroup: `cpu.stat` (usage), `memory.current`,
//   `memory.peak`, `memory.events` (oom kills), `io.stat` (bytes read and
//   written), and the three pressure files (`cpu.pressure`,
//   `memory.pressure`, `io.pressure`: total stall time, "some");
// - each of its processes: `voluntary_ctxt_switches` (wakeups, the cheap
//   proxy) and its render-node DRM clients' `drm-engine-*` nanoseconds in
//   /proc/<pid>/fdinfo (v3d prints them; vc4 and pvr do not, so a board
//   with no such client reports no GPU time rather than zero);
// - the vc4 HVS underrun counter in debugfs, on the boards that have one.
//
// A source that cannot be read is None, never 0 (G040): a pressure file
// that says "unavailable" (psi=0 on the kernel command line), a kernel
// without memory.peak, a GPU driver without fdinfo engine time.

use std::collections::BTreeMap;
use std::path::Path;

/// Where systemd puts the applet units.
pub const APPLET_SLICE: &str = "system.slice/system-vrx\\x2dapplet.slice";
/// Where the Scripts applet's background scripts run, one unit each
/// (vrx-script@<name>.service, plan 0013 D13): counted as rows of their
/// own, keyed `script:<name>`, so a script behind the screen is seen by
/// the energy estimate and the profiler like any applet.
pub const SCRIPT_SLICE: &str = "system.slice/system-vrx\\x2dscript.slice";

/// One applet's counters at a moment. `cpu_us`, `gpu_ns` and `wakeups`
/// are what the energy estimate prices; the rest are the profiler's.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Applet {
    pub cpu_us: u64,
    /// Summed over its render-node clients; meaningful only when
    /// `gpu_clients` > 0 (otherwise the board has no such counter).
    pub gpu_ns: u64,
    pub gpu_clients: u32,
    pub wakeups: u64,
    pub mem_bytes: Option<u64>,
    pub mem_peak_bytes: Option<u64>,
    pub oom_kills: Option<u64>,
    pub io_read_bytes: Option<u64>,
    pub io_write_bytes: Option<u64>,
    /// Pressure stall totals ("some", microseconds).
    pub cpu_stall_us: Option<u64>,
    pub mem_stall_us: Option<u64>,
    pub io_stall_us: Option<u64>,
}

fn read(path: &Path) -> Option<String> {
    std::fs::read_to_string(path).ok()
}

fn read_u64(path: &Path) -> Option<u64> {
    read(path)?.trim().parse().ok()
}

/// A `key value` line's value.
fn keyed(text: &str, key: &str) -> Option<u64> {
    text.lines().find_map(|l| {
        let (k, v) = l.split_once(char::is_whitespace)?;
        (k == key).then(|| v.trim().parse().ok()).flatten()
    })
}

/// A cgroup's `cpu.stat` usage, microseconds.
pub fn cpu_us(cgroup_dir: &Path) -> Option<u64> {
    keyed(&read(&cgroup_dir.join("cpu.stat"))?, "usage_usec")
}

/// A pressure file's "some" total, microseconds. A kernel booted with PSI
/// off still has the file but refuses the read: None.
fn stall_us(file: &Path) -> Option<u64> {
    read(file)?.lines().find_map(|l| {
        let rest = l.strip_prefix("some ")?;
        rest.split_whitespace()
            .find_map(|f| f.strip_prefix("total="))
            .and_then(|v| v.parse().ok())
    })
}

/// `io.stat` summed over devices: (rbytes, wbytes). An empty file (no IO
/// yet) is (0, 0); a missing one None.
fn io_bytes(file: &Path) -> Option<(u64, u64)> {
    let text = read(file)?;
    let (mut r, mut w) = (0, 0);
    for line in text.lines() {
        for field in line.split_whitespace().skip(1) {
            if let Some(v) = field.strip_prefix("rbytes=") {
                r += v.parse::<u64>().unwrap_or(0);
            } else if let Some(v) = field.strip_prefix("wbytes=") {
                w += v.parse::<u64>().unwrap_or(0);
            }
        }
    }
    Some((r, w))
}

fn wakeups_of(proc_: &Path, pid: u32) -> u64 {
    read(&proc_.join(pid.to_string()).join("status"))
        .and_then(|s| {
            s.lines().find_map(|l| {
                l.strip_prefix("voluntary_ctxt_switches:")
                    .and_then(|v| v.trim().parse().ok())
            })
        })
        .unwrap_or(0)
}

/// The process's GPU busy time: every render-node client it holds, each
/// counted once (`drm-client-id`), its `drm-engine-*` nanoseconds summed.
/// A client open on several fds counts its largest reading: the fds are
/// listed in no fixed order, and keeping the first one read made the
/// total depend on directory order. Returns (ns added, clients added).
fn gpu_of(proc_: &Path, pid: u32, seen: &mut BTreeMap<String, u64>) -> (u64, u32) {
    let dir = proc_.join(pid.to_string());
    let Ok(fds) = std::fs::read_dir(dir.join("fd")) else {
        return (0, 0);
    };
    let (mut total, mut clients) = (0, 0);
    for fd in fds.flatten() {
        let render = std::fs::read_link(fd.path())
            .is_ok_and(|t| t.to_string_lossy().starts_with("/dev/dri/renderD"));
        if !render {
            continue;
        }
        let Some(info) = read(&dir.join("fdinfo").join(fd.file_name())) else {
            continue;
        };
        let client = info.lines().find_map(|l| {
            l.strip_prefix("drm-client-id:")
                .map(|v| v.trim().to_owned())
        });
        let engines: Vec<u64> = info
            .lines()
            .filter_map(|l| l.strip_prefix("drm-engine-"))
            .filter_map(|rest| {
                let (_, v) = rest.split_once(':')?;
                v.trim().trim_end_matches("ns").trim().parse::<u64>().ok()
            })
            .collect();
        if engines.is_empty() {
            continue;
        }
        let ns = engines.iter().sum::<u64>();
        match client {
            Some(c) => match seen.get(&c).copied() {
                Some(prev) if ns > prev => {
                    total += ns - prev;
                    seen.insert(c, ns);
                }
                Some(_) => {}
                None => {
                    seen.insert(c, ns);
                    clients += 1;
                    total += ns;
                }
            },
            None => {
                clients += 1;
                total += ns;
            }
        }
    }
    (total, clients)
}

/// One applet unit's counters, from its cgroup directory.
pub fn applet(unit_dir: &Path, proc_: &Path) -> Applet {
    let mut c = Applet {
        cpu_us: cpu_us(unit_dir).unwrap_or(0),
        mem_bytes: read_u64(&unit_dir.join("memory.current")),
        mem_peak_bytes: read_u64(&unit_dir.join("memory.peak")),
        oom_kills: read(&unit_dir.join("memory.events"))
            .and_then(|t| keyed(&t, "oom_kill")),
        cpu_stall_us: stall_us(&unit_dir.join("cpu.pressure")),
        mem_stall_us: stall_us(&unit_dir.join("memory.pressure")),
        io_stall_us: stall_us(&unit_dir.join("io.pressure")),
        ..Applet::default()
    };
    if let Some((r, w)) = io_bytes(&unit_dir.join("io.stat")) {
        c.io_read_bytes = Some(r);
        c.io_write_bytes = Some(w);
    }
    let mut seen = BTreeMap::new();
    for pid in read(&unit_dir.join("cgroup.procs"))
        .unwrap_or_default()
        .lines()
        .filter_map(|l| l.trim().parse::<u32>().ok())
    {
        c.wakeups += wakeups_of(proc_, pid);
        let (ns, clients) = gpu_of(proc_, pid, &mut seen);
        c.gpu_ns += ns;
        c.gpu_clients += clients;
    }
    c
}

/// Every applet unit's counters (and each background script's, keyed
/// `script:<name>`), and the applets whose cgroup is frozen.
pub fn applets(cgroup: &Path, proc_: &Path) -> (BTreeMap<String, Applet>, Vec<String>) {
    let mut out = BTreeMap::new();
    let mut frozen = Vec::new();
    for (slice, prefix, key) in [
        (APPLET_SLICE, "vrx-applet@", ""),
        (SCRIPT_SLICE, "vrx-script@", "script:"),
    ] {
        let Ok(units) = std::fs::read_dir(cgroup.join(slice)) else {
            continue;
        };
        for unit in units.flatten() {
            let name = unit.file_name().to_string_lossy().into_owned();
            let Some(id) = name
                .strip_prefix(prefix)
                .and_then(|n| n.strip_suffix(".service"))
            else {
                continue;
            };
            let id = format!("{key}{id}");
            let dir = unit.path();
            if read(&dir.join("cgroup.freeze")).is_some_and(|v| v.trim() == "1") {
                frozen.push(id.clone());
            }
            out.insert(id, applet(&dir, proc_));
        }
    }
    (out, frozen)
}

/// A system unit's CPU usage (the model servers).
pub fn unit_cpu_us(cgroup: &Path, unit: &str) -> Option<u64> {
    cpu_us(&cgroup.join("system.slice").join(unit))
}

/// The whole system's CPU usage (the root cgroup).
pub fn total_cpu_us(cgroup: &Path) -> Option<u64> {
    cpu_us(cgroup)
}

/// The vc4 HVS underrun count (debugfs, rpi families), summed over DRM
/// devices; None where no device has the file (another SoC, debugfs not
/// mounted).
pub fn hvs_underruns(debugfs: &Path) -> Option<u64> {
    let mut found = None;
    for dev in std::fs::read_dir(debugfs.join("dri")).ok()?.flatten() {
        if let Some(n) = read_u64(&dev.path().join("hvs_underrun")) {
            found = Some(found.unwrap_or(0) + n);
        }
    }
    found
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_applets_counters_come_from_its_cgroup_and_processes() {
        let dir = tempfile::tempdir().unwrap();
        let d = dir.path();
        let unit = d
            .join("cg")
            .join(APPLET_SLICE)
            .join("vrx-applet@web.service");
        std::fs::create_dir_all(&unit).unwrap();
        std::fs::write(unit.join("cpu.stat"), "usage_usec 1234\nuser_usec 1000\n")
            .unwrap();
        std::fs::write(unit.join("memory.current"), "4096\n").unwrap();
        std::fs::write(unit.join("memory.peak"), "8192\n").unwrap();
        std::fs::write(unit.join("memory.events"), "low 0\noom 0\noom_kill 2\n").unwrap();
        std::fs::write(
            unit.join("io.stat"),
            "179:0 rbytes=100 wbytes=50 rios=1 wios=1\n8:0 rbytes=10 wbytes=5\n",
        )
        .unwrap();
        std::fs::write(
            unit.join("cpu.pressure"),
            "some avg10=0.00 avg60=0.00 avg300=0.00 total=777\nfull avg10=0.00 total=1\n",
        )
        .unwrap();
        std::fs::write(unit.join("cgroup.procs"), "42\n").unwrap();
        std::fs::write(unit.join("cgroup.freeze"), "1\n").unwrap();
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
        let (all, frozen) = applets(&d.join("cg"), &d.join("proc"));
        let web = all["web"];
        assert_eq!(web.cpu_us, 1234);
        assert_eq!(
            (web.gpu_ns, web.gpu_clients),
            (500, 1),
            "one client counted once"
        );
        assert_eq!(web.wakeups, 17);
        assert_eq!(web.mem_bytes, Some(4096));
        assert_eq!(web.mem_peak_bytes, Some(8192));
        assert_eq!(web.oom_kills, Some(2));
        assert_eq!(
            (web.io_read_bytes, web.io_write_bytes),
            (Some(110), Some(55))
        );
        assert_eq!(web.cpu_stall_us, Some(777));
        assert_eq!(web.mem_stall_us, None, "a missing file is not 0 (G040)");
        assert_eq!(frozen, ["web"]);
    }

    #[test]
    fn a_background_script_is_a_row_of_its_own() {
        let dir = tempfile::tempdir().unwrap();
        let d = dir.path();
        let unit = d
            .join("cg")
            .join(SCRIPT_SLICE)
            .join("vrx-script@sensors.service");
        std::fs::create_dir_all(&unit).unwrap();
        std::fs::write(unit.join("cpu.stat"), "usage_usec 500\n").unwrap();
        let app = d
            .join("cg")
            .join(APPLET_SLICE)
            .join("vrx-applet@scripts.service");
        std::fs::create_dir_all(&app).unwrap();
        std::fs::write(app.join("cpu.stat"), "usage_usec 7\n").unwrap();
        let (all, _) = applets(&d.join("cg"), &d.join("proc"));
        assert_eq!(all["script:sensors"].cpu_us, 500);
        assert_eq!(all["scripts"].cpu_us, 7);
    }

    #[test]
    fn a_driver_without_engine_time_reports_no_gpu_clients() {
        let dir = tempfile::tempdir().unwrap();
        let d = dir.path();
        let unit = d
            .join("cg")
            .join(APPLET_SLICE)
            .join("vrx-applet@clock.service");
        std::fs::create_dir_all(&unit).unwrap();
        std::fs::write(unit.join("cgroup.procs"), "7\n").unwrap();
        let p = d.join("proc/7");
        std::fs::create_dir_all(p.join("fd")).unwrap();
        std::fs::create_dir_all(p.join("fdinfo")).unwrap();
        std::os::unix::fs::symlink("/dev/dri/renderD128", p.join("fd/3")).unwrap();
        std::fs::write(p.join("fdinfo/3"), "drm-driver:\tpvr\ndrm-client-id:\t1\n")
            .unwrap();
        let (all, _) = applets(&d.join("cg"), &d.join("proc"));
        assert_eq!(all["clock"].gpu_clients, 0, "pvr: not available, not zero");
        assert_eq!(all["clock"].cpu_us, 0);
        assert_eq!(all["clock"].mem_bytes, None);
    }

    #[test]
    fn the_hvs_underrun_count_is_read_where_debugfs_has_it() {
        let dir = tempfile::tempdir().unwrap();
        let d = dir.path();
        assert_eq!(hvs_underruns(d), None, "no debugfs dri: None");
        std::fs::create_dir_all(d.join("dri/0")).unwrap();
        std::fs::create_dir_all(d.join("dri/1")).unwrap();
        assert_eq!(hvs_underruns(d), None, "no vc4: None");
        std::fs::write(d.join("dri/1/hvs_underrun"), "3\n").unwrap();
        assert_eq!(hvs_underruns(d), Some(3));
    }
}
