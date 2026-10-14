// What the driver reads from the board before and after a walk: whether
// a measurement would be honest (the governor, throttling), the panel's
// size, and the budgets each applet is held to. Every path is under
// `root` so the tests can build a board in a directory.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use vrx_protocol::power_profile::PowerProfile;
use vrx_protocol::walk::Budgets;
use vrx_protocol::Registry;

pub struct Board {
    pub root: PathBuf,
}

fn read(path: &Path) -> Option<String> {
    std::fs::read_to_string(path)
        .ok()
        .map(|s| s.trim().to_owned())
}

fn entries(dir: &Path, prefix: &str) -> Vec<PathBuf> {
    let mut out: Vec<PathBuf> = std::fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .filter(|e| e.file_name().to_string_lossy().starts_with(prefix))
        .map(|e| e.path())
        .collect();
    out.sort();
    out
}

impl Board {
    pub fn system() -> Self {
        Self { root: "/".into() }
    }

    pub fn path(&self, p: &str) -> PathBuf {
        self.root.join(p.trim_start_matches('/'))
    }

    /// Why a measurement now would not be comparable, if it would not:
    /// a cpufreq policy not on schedutil (the governor every vrx image
    /// runs, plan 0012 A), or a CPU cooling device engaged (the thermal
    /// framework is capping the clock).
    pub fn unfit(&self) -> Option<String> {
        let mut why = Vec::new();
        for policy in entries(&self.path("/sys/devices/system/cpu/cpufreq"), "policy") {
            let gov = read(&policy.join("scaling_governor")).unwrap_or_default();
            if gov != "schedutil" {
                why.push(format!(
                    "{} runs the {gov:?} governor, not schedutil",
                    policy.file_name().unwrap_or_default().to_string_lossy()
                ));
            }
        }
        for dev in entries(&self.path("/sys/class/thermal"), "cooling_device") {
            let kind = read(&dev.join("type")).unwrap_or_default();
            let state = read(&dev.join("cur_state"))
                .and_then(|s| s.parse::<u64>().ok())
                .unwrap_or(0);
            if state > 0 && (kind.contains("cpufreq") || kind.starts_with("cpu")) {
                why.push(format!("throttled: {kind} at cooling state {state}"));
            }
        }
        (!why.is_empty()).then(|| why.join("; "))
    }

    /// The connected panel's mode, width by height, from DRM's sysfs: the
    /// first mode a connected connector lists is its preferred one.
    pub fn panel(&self) -> Option<(u32, u32)> {
        entries(&self.path("/sys/class/drm"), "card")
            .into_iter()
            .filter(|c| read(&c.join("status")).as_deref() == Some("connected"))
            .find_map(|c| {
                let modes = read(&c.join("modes"))?;
                let (w, h) = modes.lines().next()?.split_once('x')?;
                let h: String = h.chars().take_while(char::is_ascii_digit).collect();
                Some((w.parse().ok()?, h.parse().ok()?))
            })
    }

    /// Every applet's walk budgets: its manifest's `[applet.budgets]` over
    /// the board's power profile defaults (`walk-budget` lines).
    pub fn budgets(&self) -> Result<BTreeMap<String, Budgets>, String> {
        let mut files = vec![self.path("/usr/share/vrx/power-profile")];
        files.extend(entries(&self.path("/usr/share/vrx/power-profile.d"), ""));
        let texts: Vec<(String, String)> = files
            .iter()
            .filter_map(|f| {
                Some((f.display().to_string(), std::fs::read_to_string(f).ok()?))
            })
            .collect();
        let profile =
            PowerProfile::parse_all(texts.iter().map(|(n, t)| (n.as_str(), t.as_str())))
                .map_err(|e| e.to_string())?;
        let mut registry = Registry::new();
        for (dir, builtin) in [("/system/defaults", true), ("/usr/lib/vrx/apps", false)] {
            registry
                .scan_dir(&self.path(dir), builtin)
                .map_err(|e| format!("{dir}: {e}"))?;
        }
        Ok(registry
            .iter()
            .map(|e| {
                let own = e.manifest.applet.budgets.clone().unwrap_or_default();
                (e.manifest.applet.id.clone(), own.over(&profile.walk))
            })
            .collect())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn put(root: &Path, path: &str, text: &str) {
        let p = root.join(path);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, text).unwrap();
    }

    #[test]
    fn a_board_off_schedutil_or_throttled_is_unfit() {
        let tmp = tempfile::tempdir().unwrap();
        let b = Board {
            root: tmp.path().into(),
        };
        put(
            tmp.path(),
            "sys/devices/system/cpu/cpufreq/policy0/scaling_governor",
            "schedutil\n",
        );
        put(
            tmp.path(),
            "sys/class/thermal/cooling_device0/type",
            "cpufreq-cpu0\n",
        );
        put(
            tmp.path(),
            "sys/class/thermal/cooling_device0/cur_state",
            "0\n",
        );
        assert_eq!(b.unfit(), None);
        put(
            tmp.path(),
            "sys/class/thermal/cooling_device0/cur_state",
            "2\n",
        );
        assert!(b.unfit().unwrap().contains("throttled: cpufreq-cpu0"));
        put(
            tmp.path(),
            "sys/class/thermal/cooling_device0/cur_state",
            "0\n",
        );
        put(
            tmp.path(),
            "sys/devices/system/cpu/cpufreq/policy0/scaling_governor",
            "performance\n",
        );
        assert!(b.unfit().unwrap().contains("not schedutil"));
    }

    #[test]
    fn the_panel_is_the_connected_connectors_first_mode() {
        let tmp = tempfile::tempdir().unwrap();
        let b = Board {
            root: tmp.path().into(),
        };
        put(
            tmp.path(),
            "sys/class/drm/card0-HDMI-A-1/status",
            "disconnected\n",
        );
        put(
            tmp.path(),
            "sys/class/drm/card0-HDMI-A-1/modes",
            "1920x1080\n",
        );
        put(
            tmp.path(),
            "sys/class/drm/card1-DPI-1/status",
            "connected\n",
        );
        put(
            tmp.path(),
            "sys/class/drm/card1-DPI-1/modes",
            "480x640\n320x240\n",
        );
        assert_eq!(b.panel(), Some((480, 640)));
    }

    #[test]
    fn an_applets_budgets_override_the_boards() {
        let tmp = tempfile::tempdir().unwrap();
        let b = Board {
            root: tmp.path().into(),
        };
        put(
            tmp.path(),
            "usr/share/vrx/power-profile",
            "walk-budget p95_frame_ms 16.7\nwalk-budget peak_mb 100\n",
        );
        put(
            tmp.path(),
            "system/defaults/clock/manifest.toml",
            "[applet]\nid = \"clock\"\nname = \"Clock\"\nversion = \"1.0.0\"\nruntime = \"flutter\"\n[applet.budgets]\npeak_mb = 60\n",
        );
        let all = b.budgets().unwrap();
        assert_eq!(
            all["clock"].limits(),
            vec![("p95_frame_ms", 16.7), ("peak_mb", 60.0)]
        );
    }
}
