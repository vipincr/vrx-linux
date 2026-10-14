// Which drives are mounted (plan 0019 D8). udev and systemd-mount mount a
// plugged drive under /run/vrx/usb (vrx-usb-host's rule); vrxhost asks
// nobody, it watches its own mount table: /proc/self/mountinfo raises
// POLLPRI when a mount comes or goes (proc(5)), and the table is read
// again then. The mounts under /run/vrx/usb go to usb.rs, which ties each
// to its device by the port path in its name and runs the offers scanner
// for a new one (D9).

/// The mount points under `root` in a mountinfo table, in order, each
/// once (an automount's autofs entry and the filesystem over it are one
/// drive).
pub fn under(mountinfo: &str, root: &str) -> Vec<String> {
    let prefix = format!("{}/", root.trim_end_matches('/'));
    let mut out: Vec<String> = Vec::new();
    for line in mountinfo.lines() {
        // id parent major:minor root mount-point options ...
        let Some(point) = line.split(' ').nth(4) else {
            continue;
        };
        let point = unescape(point);
        if point.starts_with(&prefix) && !out.contains(&point) {
            out.push(point);
        }
    }
    out
}

/// mountinfo writes a space, tab, newline and backslash in a path as
/// `\040`, `\011`, `\012`, `\134`.
fn unescape(field: &str) -> String {
    let bytes = field.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut at = 0;
    while at < bytes.len() {
        let octal = bytes.get(at + 1..at + 4).filter(|d| {
            bytes[at] == b'\\' && d.iter().all(|b| (b'0'..=b'7').contains(b))
        });
        match octal {
            Some(d) => {
                let v = d.iter().fold(0u32, |v, b| v * 8 + u32::from(b - b'0'));
                out.push(u8::try_from(v).unwrap_or(b'?'));
                at += 4;
            }
            None => {
                out.push(bytes[at]);
                at += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Watch this process's mount table forever, sending the mounts under
/// `root` each time they change (and once at the start).
#[cfg(target_os = "linux")]
pub async fn watch(
    root: &str,
    tx: tokio::sync::mpsc::UnboundedSender<crate::usb::HostEvent>,
) -> std::io::Result<()> {
    use std::io::{Read, Seek, SeekFrom};
    use tokio::io::unix::AsyncFd;
    use tokio::io::Interest;

    let read = |mut file: &std::fs::File| -> std::io::Result<Vec<String>> {
        let mut text = String::new();
        file.seek(SeekFrom::Start(0))?;
        file.read_to_string(&mut text)?;
        Ok(under(&text, root))
    };
    let file = std::fs::File::open("/proc/self/mountinfo")?;
    let mut before = read(&file)?;
    if tx
        .send(crate::usb::HostEvent::Mounts(before.clone()))
        .is_err()
    {
        return Ok(());
    }
    let fd = AsyncFd::with_interest(file, Interest::PRIORITY)?;
    loop {
        let mut guard = fd.ready(Interest::PRIORITY).await?;
        guard.clear_ready();
        drop(guard);
        let now = read(fd.get_ref())?;
        if now != before {
            if tx.send(crate::usb::HostEvent::Mounts(now.clone())).is_err() {
                return Ok(());
            }
            before = now;
        }
    }
}

/// The mount table's POLLPRI is Linux's; a host build (the gate) has none.
#[cfg(not(target_os = "linux"))]
pub async fn watch(
    _root: &str,
    _tx: tokio::sync::mpsc::UnboundedSender<crate::usb::HostEvent>,
) -> std::io::Result<()> {
    Err(std::io::ErrorKind::Unsupported.into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_drives_under_the_root_are_read_from_the_table() {
        let table = "\
22 1 179:2 / / ro,relatime shared:1 - ext4 /dev/root ro
30 22 0:26 / /run rw,nosuid,nodev shared:5 - tmpfs tmpfs rw
91 30 0:45 / /run/vrx/usb/1-1.2-p1 rw,relatime shared:60 - autofs systemd-1 rw,fd=50
94 91 8:1 / /run/vrx/usb/1-1.2-p1 ro,nosuid,nodev,noexec,nosymfollow shared:62 - vfat /dev/sda1 ro,gid=990
95 30 8:17 / /run/vrx/usb/1-1.3-p1 ro shared:63 - exfat /dev/sdb1 ro
96 30 8:33 / /run/vrx/usbx/1-1-p1 ro shared:64 - vfat /dev/sdc1 ro
97 30 0:46 / /run/vrx/usb/odd\\040name rw - autofs systemd-1 rw
";
        assert_eq!(
            under(table, "/run/vrx/usb"),
            vec![
                "/run/vrx/usb/1-1.2-p1",
                "/run/vrx/usb/1-1.3-p1",
                "/run/vrx/usb/odd name"
            ]
        );
        assert!(under(table, "/run/vrx/usb/").len() == 3);
        assert!(under("", "/run/vrx/usb").is_empty());
        assert!(under("short line\n", "/run/vrx/usb").is_empty());
    }

    #[test]
    fn escapes_are_undone_and_a_bad_one_is_kept() {
        assert_eq!(unescape("a\\040b\\011c\\134d"), "a b\tc\\d");
        assert_eq!(unescape("a\\04"), "a\\04");
        assert_eq!(unescape("a\\9xy"), "a\\9xy");
    }
}
