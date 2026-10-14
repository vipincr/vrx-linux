// The supply's under-voltage alarm (plan 0012 D6): the Raspberry Pi
// firmware's "rpi_volt" hwmon device and its in0_lcrit_alarm, set below
// about 4.63 V at the module. The kit read it every 2 s; this waits for
// the kernel's sysfs_notify (POLLPRI) on the attribute and re-reads it at
// most once a minute regardless, so a driver that never notifies still
// reports within a minute at one wake a minute, and one that does
// reports at once. The value goes to facts.rs. A board without the
// device has nothing to watch.

use std::path::{Path, PathBuf};

/// Where hwmon devices are listed.
pub const HWMON_ROOT: &str = "/sys/class/hwmon";

/// The longest wait between two reads.
pub const RECHECK: std::time::Duration = std::time::Duration::from_secs(60);

/// The board's supply alarm file, if it has one.
pub fn alarm_file(root: &Path) -> Option<PathBuf> {
    let mut found: Vec<PathBuf> = std::fs::read_dir(root)
        .ok()?
        .flatten()
        .filter(|e| {
            std::fs::read_to_string(e.path().join("name"))
                .is_ok_and(|n| n.trim() == "rpi_volt")
        })
        .map(|e| e.path().join("in0_lcrit_alarm"))
        .filter(|p| p.exists())
        .collect();
    found.sort();
    found.into_iter().next()
}

/// The alarm's text says the supply is low.
pub fn low(text: &str) -> bool {
    text.trim() == "1"
}

/// Watch `alarm` forever, publishing each change.
#[cfg(target_os = "linux")]
pub async fn watch(alarm: PathBuf) -> std::io::Result<()> {
    use std::fs::File;
    use std::io::{Read, Seek, SeekFrom};
    use tokio::io::unix::AsyncFd;
    use tokio::io::Interest;

    fn read(mut file: &File) -> std::io::Result<bool> {
        let mut text = String::new();
        file.seek(SeekFrom::Start(0))?;
        file.read_to_string(&mut text)?;
        Ok(low(&text))
    }
    let file = File::open(&alarm)?;
    let now = read(&file)?;
    crate::facts::update(|f| f.supply_low = now);
    tracing::info!(alarm = %alarm.display(), low = now, "watching the supply");
    let fd = AsyncFd::with_interest(file, Interest::PRIORITY)?;
    loop {
        // the kernel's notification, or the minute's re-read
        if let Ok(guard) =
            tokio::time::timeout(RECHECK, fd.ready(Interest::PRIORITY)).await
        {
            guard?.clear_ready();
        }
        let now = read(fd.get_ref())?;
        crate::facts::update(|f| {
            if f.supply_low != now {
                tracing::info!(low = now, "supply");
            }
            f.supply_low = now;
        });
    }
}

/// POLLPRI on a sysfs file is Linux's; a host build (the gate) has none.
#[cfg(not(target_os = "linux"))]
pub async fn watch(_alarm: PathBuf) -> std::io::Result<()> {
    Err(std::io::ErrorKind::Unsupported.into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_rpi_volt_alarm_is_found_and_nothing_else_is() {
        let root = tempfile::tempdir().unwrap();
        assert_eq!(alarm_file(root.path()), None);
        for (dir, name) in [("hwmon0", "cpu_thermal"), ("hwmon1", "rpi_volt")] {
            std::fs::create_dir(root.path().join(dir)).unwrap();
            std::fs::write(root.path().join(dir).join("name"), format!("{name}\n"))
                .unwrap();
        }
        assert_eq!(alarm_file(root.path()), None, "no alarm attribute yet");
        std::fs::write(root.path().join("hwmon1/in0_lcrit_alarm"), "0\n").unwrap();
        assert_eq!(
            alarm_file(root.path()),
            Some(root.path().join("hwmon1/in0_lcrit_alarm"))
        );
        assert_eq!(alarm_file(Path::new("/nonexistent")), None);
    }

    #[test]
    fn one_means_low() {
        assert!(low("1\n"));
        assert!(!low("0\n"));
        assert!(!low(""));
    }
}
