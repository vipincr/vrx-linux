// The board's USB, both directions. They are two families, named apart:
// `sys.usb.connected` is the device side (a computer enumerated the
// board's gadget); `sys.usb.attached`, `detached` and `blocked` are the
// host side (something was plugged into the board, plan 0019).
//
// The device side (plan 0008 D11). A computer on the other end of the
// board's USB. The
// UDC's `state` reads "configured" once a host has enumerated the gadget;
// on that edge vrxhost raises `sys.usb.connected` and the USB applet
// offers to share files. The kernel tells only through sysfs_notify on
// that attribute (usb_gadget_state_work), never a uevent, so no udev rule
// can see it: this waits for POLLPRI on the file, reading it again after
// each wake, and publishes each state as a fact (plan 0012 D6) so the kit
// hears it instead of reading the file every second. A board without a
// UDC has nothing to watch.

#[cfg(any(target_os = "linux", test))]
use std::fs::File;
#[cfg(any(target_os = "linux", test))]
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

/// Where the kernel lists UDCs.
pub const UDC_ROOT: &str = "/sys/class/udc";

/// The intent a connection raises.
pub const CONNECTED: &str = "sys.usb.connected";

/// The board's UDC state file, if it has a UDC.
pub fn state_file(root: &Path) -> Option<PathBuf> {
    let mut udcs: Vec<PathBuf> = std::fs::read_dir(root)
        .ok()?
        .flatten()
        .map(|e| e.path().join("state"))
        .filter(|p| p.exists())
        .collect();
    udcs.sort();
    udcs.into_iter().next()
}

/// A host has just finished enumerating the gadget.
pub fn connected(before: &str, now: &str) -> bool {
    now == "configured" && before != "configured"
}

#[cfg(any(target_os = "linux", test))]
fn read_state(mut file: impl Read + Seek) -> std::io::Result<String> {
    let mut text = String::new();
    file.seek(SeekFrom::Start(0))?;
    file.read_to_string(&mut text)?;
    Ok(text.trim().to_owned())
}

/// Watch `state` forever, calling `on_connect` on each connection. The
/// state at start is not an edge: a vrxhost restarted with a cable in
/// does not ask again.
#[cfg(target_os = "linux")]
pub async fn watch(state: PathBuf, mut on_connect: impl FnMut()) -> std::io::Result<()> {
    use tokio::io::unix::AsyncFd;
    use tokio::io::Interest;

    let file = File::open(&state)?;
    let mut before = read_state(&file)?;
    tracing::info!(state = %state.display(), now = %before, "watching the USB device port");
    let start = before.clone();
    crate::facts::update(|f| f.usb = start);
    let fd = AsyncFd::with_interest(file, Interest::PRIORITY)?;
    loop {
        let mut guard = fd.ready(Interest::PRIORITY).await?;
        guard.clear_ready();
        drop(guard);
        let now = read_state(fd.get_ref())?;
        if now != before {
            tracing::info!(from = %before, to = %now, "USB device port");
            let state = now.clone();
            crate::facts::update(|f| f.usb = state);
        }
        if connected(&before, &now) {
            on_connect();
        }
        before = now;
    }
}

/// POLLPRI on a sysfs file is Linux's; a host build (the gate) has no UDC.
#[cfg(not(target_os = "linux"))]
pub async fn watch(_state: PathBuf, _on_connect: impl FnMut()) -> std::io::Result<()> {
    Err(std::io::ErrorKind::Unsupported.into())
}

// ── the host side (plan 0019) ────────────────────────────────────────────
// Linux enumerates, binds and authorises; vrx hears it and says so (D1,
// D7). The kernel's uevents on the one listener (uevents.rs) say when
// something under /sys/bus/usb changed; the tree is then read again from
// sysfs (a board has a handful of devices) and the difference raised as
// `sys.usb.attached` and `sys.usb.detached`. A device the policy left
// unauthorised for SETTLE (USBGuard decides in milliseconds) is
// `sys.usb.blocked`. Its interfaces come from the `descriptors` attribute,
// which the kernel fills before any driver binds and which is all an
// unauthorised device has. What the image declared (ports, power, policy)
// is /usr/lib/vrx/usb.toml, written by meta-vrx's vrx-usb-host.bbclass.
// Drives mount through udev and systemd-mount (vrx-usb-host's rule, D8);
// mounts.rs tells this loop which are mounted, by the port path in the
// mount's name.

/// A device was plugged in (payload: class, name, port).
pub const ATTACHED: &str = "sys.usb.attached";
/// A device was pulled out (payload: class, name, port).
pub const DETACHED: &str = "sys.usb.detached";
/// A device stayed unauthorised by the policy (payload: name, port,
/// reason: "policy", or "policy-failed" when USBGuard is down).
pub const BLOCKED: &str = "sys.usb.blocked";

/// Where the kernel lists USB devices.
pub const DEVICES_ROOT: &str = "/sys/bus/usb/devices";
/// What the image declared (vrx-usb-host.bbclass).
pub const CONFIG: &str = "/usr/lib/vrx/usb.toml";
/// Where drives are mounted, one directory per partition.
pub const MOUNT_ROOT: &str = "/run/vrx/usb";
/// How long a device may stay unauthorised before it counts as blocked.
pub const SETTLE: std::time::Duration = std::time::Duration::from_millis(1500);

/// What the image declared about its USB host ports (D5, D6, D12).
#[derive(Debug, Clone, PartialEq, Eq, Default, serde::Deserialize)]
#[serde(default)]
pub struct Config {
    /// The host ports' labels; empty: the board has none.
    pub ports: Vec<String>,
    /// unswitched, switched or unknown.
    pub vbus: String,
    /// none, reported or unknown.
    pub overcurrent: String,
    /// The classes the policy allows (hid storage audio video serial).
    pub classes: Vec<String>,
    /// allowlist or open.
    pub policy: String,
    /// The filesystems a drive is mounted with.
    pub fs: Vec<String>,
}

impl Config {
    /// The image's declaration. A MISSING file is a board with no host
    /// ports; an UNREADABLE or unparseable one is a fault and the
    /// ports are reported as none with the reason logged (review
    /// 2026-10-17, CON-08: it read as "no host ports" silently).
    pub fn load(path: &Path) -> Self {
        match std::fs::read_to_string(path) {
            Ok(t) => match toml::from_str(&t) {
                Ok(c) => c,
                Err(err) => {
                    tracing::error!(path = %path.display(), error = %err, "usb config: unparseable; no host ports");
                    toml::from_str("").unwrap_or_default()
                }
            },
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => toml::from_str("").unwrap_or_default(),
            Err(err) => {
                tracing::error!(path = %path.display(), error = %err, "usb config: unreadable; no host ports");
                toml::from_str("").unwrap_or_default()
            }
        }
    }
}

/// What `usb_policy` says: none (no host ports), open, allowlist, or
/// failed (the allow-list is the image's but USBGuard is not running, so
/// nothing new is authorised).
pub fn policy_word(config: &Config, daemon_active: bool) -> &'static str {
    if config.ports.is_empty() {
        "none"
    } else if config.policy == "open" {
        "open"
    } else if daemon_active {
        "allowlist"
    } else {
        "failed"
    }
}

/// What a device is, in the closed set the kit and camerad share.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Class {
    Hid,
    Storage,
    Audio,
    Video,
    Serial,
    Hub,
    Other,
}

impl Class {
    pub fn as_str(self) -> &'static str {
        match self {
            Class::Hid => "hid",
            Class::Storage => "storage",
            Class::Audio => "audio",
            Class::Video => "video",
            Class::Serial => "serial",
            Class::Hub => "hub",
            Class::Other => "other",
        }
    }
}

/// Vendor-class (0xff) serial adapters the policy names by vendor (plan
/// 0019 Part C): FTDI, Silicon Labs, WCH, Prolific.
pub const SERIAL_VENDORS: [u16; 4] = [0x0403, 0x10c4, 0x1a86, 0x067b];

/// A device's class from its device class and its interfaces' (class,
/// subclass, protocol). A composite device is what its weightiest
/// interface makes it: a webcam with a microphone is video, a stick that
/// also types is storage (and the policy blocks it).
pub fn class_of(vendor: u16, device_class: u8, interfaces: &[(u8, u8, u8)]) -> Class {
    let has = |c: u8| interfaces.iter().any(|i| i.0 == c);
    if device_class == 0x09
        || (!interfaces.is_empty() && interfaces.iter().all(|i| i.0 == 0x09))
    {
        return Class::Hub;
    }
    if has(0x08) {
        Class::Storage
    } else if has(0x0e) {
        Class::Video
    } else if has(0x01) {
        Class::Audio
    } else if has(0x03) {
        Class::Hid
    } else if has(0x02) || has(0x0a) || (has(0xff) && SERIAL_VENDORS.contains(&vendor)) {
        Class::Serial
    } else {
        Class::Other
    }
}

/// The `descriptors` attribute read: the device descriptor, then every
/// configuration's descriptors as the device sent them. Answers the
/// vendor, the device class and each interface's (class, subclass,
/// protocol), once each.
pub fn read_descriptors(raw: &[u8]) -> (u16, u8, Vec<(u8, u8, u8)>) {
    let (mut vendor, mut device_class, mut interfaces) = (0u16, 0u8, Vec::new());
    let mut at = 0;
    while at + 2 <= raw.len() {
        let len = usize::from(raw[at]);
        if len < 2 || at + len > raw.len() {
            break;
        }
        let d = &raw[at..at + len];
        match d[1] {
            1 if len >= 18 => {
                device_class = d[4];
                vendor = u16::from_le_bytes([d[8], d[9]]);
            }
            4 if len >= 9 => {
                let triplet = (d[5], d[6], d[7]);
                if !interfaces.contains(&triplet) {
                    interfaces.push(triplet);
                }
            }
            _ => {}
        }
        at += len;
    }
    (vendor, device_class, interfaces)
}

/// A device's name under /sys/bus/usb/devices: `<bus>-<port>[.<port>...]`.
/// Root hubs (`usb1`) and interfaces (`1-1.2:1.0`) are not devices here.
pub fn is_device_name(name: &str) -> bool {
    let Some((bus, ports)) = name.split_once('-') else {
        return false;
    };
    let digits = |s: &str| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit());
    digits(bus) && ports.split('.').all(digits)
}

/// The device a drive's mount belongs to: `/run/vrx/usb/1-1.2-p1` is
/// device `1-1.2`, partition 1 (the name vrx-usb-mount gives it).
pub fn device_of_mount(mount: &str) -> Option<&str> {
    let name = mount.rsplit('/').next()?;
    let (port, part) = name.rsplit_once("-p")?;
    (is_device_name(port) && !part.is_empty() && part.bytes().all(|b| b.is_ascii_digit()))
        .then_some(port)
}

/// One device plugged into the board, as the `usb_devices` fact says it.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct Device {
    /// Its place on the bus (`1-1.2`): stable while it stays in that port.
    pub port: String,
    /// What it calls itself ("" when it says nothing).
    pub name: String,
    pub class: Class,
    /// vendor:product, four hex digits each.
    pub id: String,
    /// Mb/s, as the kernel says it ("480", "12", "1.5").
    pub speed: String,
    /// The policy let its drivers bind.
    pub authorized: bool,
    /// It stayed unauthorised past SETTLE.
    pub blocked: bool,
    /// Its partitions' mounts under /run/vrx/usb.
    pub mounts: Vec<String>,
}

fn attr(dir: &Path, name: &str) -> String {
    std::fs::read_to_string(dir.join(name))
        .map(|s| s.trim().to_owned())
        .unwrap_or_default()
}

/// One device read from sysfs; None when it is gone, or has not finished
/// enumerating (no descriptors yet).
pub fn read_device(root: &Path, port: &str) -> Option<Device> {
    let dir = root.join(port);
    let raw = std::fs::read(dir.join("descriptors")).ok()?;
    let (vendor, device_class, interfaces) = read_descriptors(&raw);
    if raw.len() < 18 {
        return None;
    }
    let name = [attr(&dir, "product"), attr(&dir, "manufacturer")]
        .into_iter()
        .find(|s| !s.is_empty())
        .unwrap_or_default();
    Some(Device {
        port: port.to_owned(),
        name,
        class: class_of(vendor, device_class, &interfaces),
        id: format!("{}:{}", attr(&dir, "idVendor"), attr(&dir, "idProduct")),
        speed: attr(&dir, "speed"),
        // CON-08 (review 2026-10-17): an unreadable `authorized` reads
        // as REFUSED, not authorized — unknown is never yes
        authorized: attr(&dir, "authorized") == "1",
        blocked: false,
        mounts: Vec::new(),
    })
}

/// Every device on the board's buses, by port.
pub fn scan(root: &Path) -> Vec<Device> {
    let mut names: Vec<String> = std::fs::read_dir(root)
        .map(|d| {
            d.flatten()
                .map(|e| e.file_name().to_string_lossy().into_owned())
                .filter(|n| is_device_name(n))
                .collect()
        })
        .unwrap_or_default();
    names.sort();
    names.iter().filter_map(|n| read_device(root, n)).collect()
}

/// A uevent that may change the device list: the device's port, and
/// whether it is an arrival (add or bind) rather than a departure or a
/// change.
pub fn event(message: &crate::uevents::Message) -> Option<(String, bool)> {
    if message.subsystem() != "usb" {
        return None;
    }
    let last = message.devpath.rsplit('/').next()?;
    let port = last.split(':').next()?;
    if !is_device_name(port) {
        return None;
    }
    let arrival = matches!(message.action.as_str(), "add" | "bind");
    Some((port.to_owned(), arrival))
}

/// The devices now, given what was there before: the blocked marks and
/// mounts carry over to a device still in its port; the new arrivals and
/// the departures are answered.
pub fn merge(
    before: &[Device],
    mut now: Vec<Device>,
    mounts: &[String],
) -> (Vec<Device>, Vec<Device>, Vec<Device>) {
    for d in &mut now {
        if let Some(old) = before.iter().find(|o| o.port == d.port && o.id == d.id) {
            d.blocked = old.blocked && !d.authorized;
        }
        d.mounts = mounts
            .iter()
            .filter(|m| device_of_mount(m) == Some(d.port.as_str()))
            .cloned()
            .collect();
    }
    let same = |a: &Device, b: &Device| a.port == b.port && a.id == b.id;
    let attached = now
        .iter()
        .filter(|d| !before.iter().any(|o| same(o, d)))
        .cloned()
        .collect();
    let detached = before
        .iter()
        .filter(|o| !now.iter().any(|d| same(o, d)))
        .cloned()
        .collect();
    (now, attached, detached)
}

/// What the host side hears, besides the clock.
#[derive(Debug)]
pub enum HostEvent {
    /// A kernel uevent.
    Uevent(crate::uevents::Message),
    /// The mounts under MOUNT_ROOT now (mounts.rs).
    Mounts(Vec<String>),
}

/// The host side's loop: the device list on every relevant uevent, the
/// mounts as mounts.rs reports them, the blocked marks after SETTLE.
/// `publish` takes the device list and the policy word on every change
/// (the daemon makes them facts); `raise` sends an intent; `probe`
/// answers whether USBGuard is running; `on_mount` runs when a new drive
/// is mounted (the offers scanner, D9). A board that declares no host
/// port publishes `none` once and listens to nothing.
pub async fn host<P, F>(
    root: PathBuf,
    config: Config,
    mut events: tokio::sync::mpsc::UnboundedReceiver<HostEvent>,
    mut publish: impl FnMut(Vec<Device>, &'static str),
    mut raise: impl FnMut(&'static str, serde_json::Value),
    probe: P,
    mut on_mount: impl FnMut(),
) where
    P: Fn() -> F,
    F: std::future::Future<Output = bool>,
{
    use std::collections::HashMap;
    use tokio::time::Instant;

    let mut policy = policy_word(&config, probe().await);
    if config.ports.is_empty() {
        publish(Vec::new(), policy);
        return;
    }
    let mut mounts: Vec<String> = Vec::new();
    let (mut devices, _, _) = merge(&[], scan(&root), &mounts);
    // port -> (when it counts as blocked, whether to say so): a device
    // present at the start is marked, never announced again
    let mut settling: HashMap<String, (Instant, bool)> = devices
        .iter()
        .filter(|d| !d.authorized)
        .map(|d| (d.port.clone(), (Instant::now() + SETTLE, false)))
        .collect();
    publish(devices.clone(), policy);
    loop {
        let due = settling.values().map(|(at, _)| *at).min();
        let settle = async {
            match due {
                Some(at) => tokio::time::sleep_until(at).await,
                None => std::future::pending().await,
            }
        };
        tokio::select! {
            event = events.recv() => {
                let Some(event) = event else { return };
                let arrivals: Vec<String> = match event {
                    HostEvent::Uevent(message) => match self::event(&message) {
                        Some((port, true)) => vec![port],
                        Some((_, false)) => Vec::new(),
                        None => continue,
                    },
                    HostEvent::Mounts(now) => {
                        let fresh = now.iter().any(|m| !mounts.contains(m));
                        mounts = now;
                        if fresh {
                            on_mount();
                        }
                        Vec::new()
                    }
                };
                let (now, attached, detached) = merge(&devices, scan(&root), &mounts);
                for d in &attached {
                    tracing::info!(port = %d.port, class = d.class.as_str(), name = %d.name, "usb attached");
                    raise(ATTACHED, serde_json::json!({ "class": d.class, "name": d.name, "port": d.port }));
                    if !d.authorized {
                        settling.insert(d.port.clone(), (Instant::now() + SETTLE, true));
                    }
                }
                for d in &detached {
                    tracing::info!(port = %d.port, class = d.class.as_str(), "usb detached");
                    settling.remove(&d.port);
                    raise(DETACHED, serde_json::json!({ "class": d.class, "name": d.name, "port": d.port }));
                }
                // a re-plug in the same port settles again
                for port in arrivals {
                    if now.iter().any(|d| d.port == port && !d.authorized) {
                        settling.entry(port).or_insert((Instant::now() + SETTLE, true));
                    }
                }
                devices = now;
                publish(devices.clone(), policy);
            }
            () = settle => {
                let now = Instant::now();
                let ripe: Vec<(String, bool)> = settling
                    .iter()
                    .filter(|(_, (at, _))| *at <= now)
                    .map(|(p, (_, say))| (p.clone(), *say))
                    .collect();
                for (port, say) in ripe {
                    settling.remove(&port);
                    let Some(d) = devices.iter_mut().find(|d| d.port == port) else { continue };
                    if d.authorized || read_device(&root, &port).is_some_and(|r| r.authorized) {
                        continue;
                    }
                    d.blocked = true;
                    policy = policy_word(&config, probe().await);
                    let reason = if policy == "failed" { "policy-failed" } else { "policy" };
                    tracing::warn!(%port, name = %d.name, reason, "usb blocked");
                    if say {
                        raise(BLOCKED, serde_json::json!({ "name": d.name, "port": d.port, "reason": reason }));
                    }
                }
                publish(devices.clone(), policy);
            }
        }
    }
}

/// The policy switch "Allow new USB devices" (D11): USBGuard's
/// InsertedDevicePolicy, `apply-policy` (the rules decide) or `block`
/// (nothing new is authorised; what is attached keeps working). Through
/// its own CLI as root: vrxhost writes no sysfs.
pub async fn set_allow_new(allow: bool) -> Result<(), String> {
    let value = if allow { "apply-policy" } else { "block" };
    let out = tokio::process::Command::new("/usr/bin/usbguard")
        .args(["set-parameter", "InsertedDevicePolicy", value])
        .output()
        .await
        .map_err(|e| e.to_string())?;
    if out.status.success() {
        Ok(())
    } else {
        Err(String::from_utf8_lossy(&out.stderr).trim().to_owned())
    }
}

/// A drive's mount path as vrxhost accepts it from an applet: directly
/// under MOUNT_ROOT, named by a port and a partition.
pub fn mount_ok(mount: &str) -> bool {
    mount
        .strip_prefix(MOUNT_ROOT)
        .and_then(|rest| rest.strip_prefix('/'))
        .is_some_and(|name| !name.contains('/') && device_of_mount(name).is_some())
}

/// A drive's two units, as systemd-mount made them: the automount, then
/// the mount (an eject stops them in that order, so nothing mounts it
/// again).
pub fn mount_units(mount: &str) -> [String; 2] {
    let base = escape_path(mount);
    [format!("{base}.automount"), format!("{base}.mount")]
}

/// A path as systemd names its units (systemd-escape --path): the path
/// without its outer slashes, `/` as `-`, and every byte outside
/// `[A-Za-z0-9:_.]` (and a leading `.`) as `\xNN`. In Rust because
/// systemd-escape is in systemd-extra-utils, which an image need not have.
pub fn escape_path(path: &str) -> String {
    use std::fmt::Write as _;
    let trimmed = path.trim_matches('/');
    let mut out = String::new();
    for (i, b) in trimmed.bytes().enumerate() {
        match b {
            b'/' => out.push('-'),
            b'.' if i == 0 => out.push_str("\\x2e"),
            b if b.is_ascii_alphanumeric() || b == b':' || b == b'_' || b == b'.' => {
                out.push(char::from(b));
            }
            b => {
                let _ = write!(out, "\\x{b:02x}");
            }
        }
    }
    if out.is_empty() {
        out.push('-');
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_the_edge_into_configured_is_a_connection() {
        assert!(connected("addressed", "configured"));
        assert!(connected("not attached", "configured"));
        assert!(!connected("configured", "configured"));
        assert!(!connected("configured", "not attached"));
        assert!(!connected("powered", "default"));
    }

    #[test]
    fn the_first_udc_is_watched_and_none_means_nothing_to_watch() {
        let root = tempfile::tempdir().unwrap();
        assert_eq!(state_file(root.path()), None);
        for name in ["fe980000.usb", "a.usb"] {
            std::fs::create_dir(root.path().join(name)).unwrap();
            std::fs::write(root.path().join(name).join("state"), "not attached\n")
                .unwrap();
        }
        assert_eq!(
            state_file(root.path()),
            Some(root.path().join("a.usb/state"))
        );
        assert_eq!(state_file(Path::new("/nonexistent")), None);
    }

    #[test]
    fn the_state_reads_again_from_the_start() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("state");
        std::fs::write(&path, "configured\n").unwrap();
        let file = File::open(&path).unwrap();
        assert_eq!(read_state(&file).unwrap(), "configured");
        assert_eq!(read_state(&file).unwrap(), "configured");
    }

    // ── the host side (plan 0019) ──

    /// A device's `descriptors`: the device descriptor, one configuration
    /// with the given interfaces.
    fn descriptors(
        vendor: u16,
        device_class: u8,
        interfaces: &[(u8, u8, u8)],
    ) -> Vec<u8> {
        let v = vendor.to_le_bytes();
        let mut d = vec![
            18,
            1,
            0x00,
            0x02,
            device_class,
            0,
            0,
            64,
            v[0],
            v[1],
            0x25,
            0x08,
            0x12,
            0x00,
            1,
            2,
            3,
            1,
        ];
        let total = 9 + 9 * interfaces.len();
        d.extend_from_slice(&[
            9,
            2,
            total as u8,
            0,
            interfaces.len() as u8,
            1,
            0,
            0x80,
            50,
        ]);
        for (n, (c, s, p)) in interfaces.iter().enumerate() {
            d.extend_from_slice(&[9, 4, n as u8, 0, 1, *c, *s, *p, 0]);
            // an endpoint between interfaces is skipped over
            d.extend_from_slice(&[7, 5, 0x81, 3, 8, 0, 10]);
        }
        d
    }

    fn plug(
        root: &Path,
        port: &str,
        name: &str,
        vendor: u16,
        interfaces: &[(u8, u8, u8)],
        authorized: bool,
    ) {
        let dir = root.join(port);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("descriptors"), descriptors(vendor, 0, interfaces))
            .unwrap();
        std::fs::write(dir.join("product"), format!("{name}\n")).unwrap();
        std::fs::write(dir.join("idVendor"), format!("{vendor:04x}\n")).unwrap();
        std::fs::write(dir.join("idProduct"), "0825\n").unwrap();
        std::fs::write(dir.join("speed"), "480\n").unwrap();
        std::fs::write(
            dir.join("authorized"),
            if authorized { "1\n" } else { "0\n" },
        )
        .unwrap();
    }

    #[test]
    fn a_device_is_what_its_weightiest_interface_makes_it() {
        assert_eq!(
            class_of(0x046d, 0, &[(0x0e, 1, 0), (0x0e, 2, 0), (0x01, 1, 0)]),
            Class::Video
        );
        assert_eq!(
            class_of(0x1234, 0, &[(0x03, 1, 1), (0x03, 1, 2)]),
            Class::Hid
        );
        assert_eq!(
            class_of(0x1234, 0, &[(0x08, 6, 0x50), (0x03, 1, 1)]),
            Class::Storage,
            "a stick that types"
        );
        assert_eq!(class_of(0x1234, 0x09, &[(0x09, 0, 0)]), Class::Hub);
        assert_eq!(
            class_of(0x1234, 0, &[(0x01, 1, 0), (0x01, 2, 0)]),
            Class::Audio
        );
        assert_eq!(
            class_of(0x2e8a, 0, &[(0x02, 2, 1), (0x0a, 0, 0)]),
            Class::Serial,
            "CDC ACM"
        );
        assert_eq!(
            class_of(0x0403, 0, &[(0xff, 0xff, 0xff)]),
            Class::Serial,
            "FTDI"
        );
        assert_eq!(
            class_of(0x0bda, 0, &[(0xff, 0xff, 0xff)]),
            Class::Other,
            "an unlisted vendor class"
        );
        assert_eq!(
            class_of(0x0bda, 0, &[(0xe0, 1, 1)]),
            Class::Other,
            "wireless"
        );
        assert_eq!(
            class_of(0x0bda, 0, &[]),
            Class::Other,
            "unconfigured, nothing known"
        );
    }

    #[test]
    fn descriptors_give_the_vendor_and_each_interface_once() {
        let raw = descriptors(
            0x046d,
            0xef,
            &[(0x0e, 1, 0), (0x0e, 2, 0), (0x0e, 2, 0), (0x01, 1, 0)],
        );
        let (vendor, class, interfaces) = read_descriptors(&raw);
        assert_eq!((vendor, class), (0x046d, 0xef));
        assert_eq!(interfaces, vec![(0x0e, 1, 0), (0x0e, 2, 0), (0x01, 1, 0)]);
        // a truncated or zero-length descriptor ends the walk, no panic
        assert_eq!(read_descriptors(&raw[..20]).2, Vec::<(u8, u8, u8)>::new());
        assert_eq!(read_descriptors(&[0, 0, 0]), (0, 0, Vec::new()));
        assert_eq!(read_descriptors(&[]), (0, 0, Vec::new()));
    }

    #[test]
    fn devices_ports_and_mounts_are_named_by_the_bus() {
        for ok in ["1-1", "1-1.2", "2-1.4.3", "10-3"] {
            assert!(is_device_name(ok), "{ok}");
        }
        for not in [
            "usb1",
            "1-1.2:1.0",
            "1-",
            "-1",
            "1-1..2",
            "a-1",
            "1-1.x",
            "",
        ] {
            assert!(!is_device_name(not), "{not}");
        }
        assert_eq!(device_of_mount("/run/vrx/usb/1-1.2-p1"), Some("1-1.2"));
        assert_eq!(device_of_mount("1-1-p0"), Some("1-1"));
        assert_eq!(
            device_of_mount("/run/vrx/usb/STICK"),
            None,
            "a label is never a name"
        );
        assert_eq!(device_of_mount("/run/vrx/usb/1-1.2-p"), None);
        assert!(mount_ok("/run/vrx/usb/1-1.2-p1"));
        for bad in [
            "/run/vrx/usb/../usb/1-1-p1",
            "/run/vrx/usb/1-1-p1/x",
            "/run/vrx/usbx/1-1-p1",
            "/data",
            "/run/vrx/usb/",
        ] {
            assert!(!mount_ok(bad), "{bad}");
        }
    }

    #[test]
    fn a_mounts_unit_is_named_as_systemd_escape_names_it() {
        // systemd-escape --path --suffix=mount /run/vrx/usb/1-1.2-p1
        assert_eq!(
            mount_units("/run/vrx/usb/1-1.2-p1"),
            [
                "run-vrx-usb-1\\x2d1.2\\x2dp1.automount".to_owned(),
                "run-vrx-usb-1\\x2d1.2\\x2dp1.mount".to_owned()
            ]
        );
        assert_eq!(escape_path("/"), "-");
        assert_eq!(escape_path("/a b/.c"), "a\\x20b-.c");
        assert_eq!(escape_path("/.x"), "\\x2ex");
    }

    #[test]
    fn the_policy_word_follows_the_declaration_and_the_daemon() {
        let none = Config::default();
        let mut allow = Config {
            ports: vec!["USB-A".into()],
            policy: "allowlist".into(),
            ..Config::default()
        };
        assert_eq!(policy_word(&none, true), "none");
        assert_eq!(policy_word(&allow, true), "allowlist");
        assert_eq!(policy_word(&allow, false), "failed");
        allow.policy = "open".into();
        assert_eq!(policy_word(&allow, false), "open");
    }

    #[test]
    fn the_declaration_is_read_and_a_missing_one_is_no_host() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("usb.toml");
        assert_eq!(Config::load(&path), Config::default());
        std::fs::write(
            &path,
            "ports = [\"USB-A\"]\nvbus = \"unswitched\"\novercurrent = \"none\"\n\
             classes = [\"hid\", \"storage\"]\npolicy = \"allowlist\"\nfs = [\"vfat\", \"exfat\"]\n",
        )
        .unwrap();
        let c = Config::load(&path);
        assert_eq!(c.ports, vec!["USB-A"]);
        assert_eq!(
            (c.vbus.as_str(), c.overcurrent.as_str(), c.policy.as_str()),
            ("unswitched", "none", "allowlist")
        );
        assert_eq!(c.fs, vec!["vfat", "exfat"]);
        std::fs::write(&path, "ports = 3\n").unwrap();
        assert_eq!(
            Config::load(&path),
            Config::default(),
            "unreadable is no host"
        );
    }

    #[test]
    fn the_tree_lists_devices_only_and_skips_one_still_enumerating() {
        let root = tempfile::tempdir().unwrap();
        plug(
            root.path(),
            "1-1",
            "USB2.0 Hub",
            0x05e3,
            &[(0x09, 0, 0)],
            true,
        );
        plug(
            root.path(),
            "1-1.2",
            "Keyboard",
            0x1234,
            &[(0x03, 1, 1)],
            true,
        );
        std::fs::create_dir_all(root.path().join("usb1")).unwrap();
        std::fs::create_dir_all(root.path().join("1-1.2:1.0")).unwrap();
        std::fs::create_dir_all(root.path().join("1-1.3")).unwrap(); // no descriptors yet
        let devices = scan(root.path());
        let ports: Vec<_> = devices.iter().map(|d| (d.port.as_str(), d.class)).collect();
        assert_eq!(ports, vec![("1-1", Class::Hub), ("1-1.2", Class::Hid)]);
        assert_eq!(devices[1].name, "Keyboard");
        assert_eq!(devices[1].id, "1234:0825");
        assert_eq!(devices[1].speed, "480");
        assert!(devices[1].authorized);
        assert!(scan(Path::new("/nonexistent")).is_empty());
    }

    #[test]
    fn merging_names_arrivals_and_departures_and_keeps_marks_and_mounts() {
        let root = tempfile::tempdir().unwrap();
        plug(
            root.path(),
            "1-1.2",
            "Stick",
            0x0781,
            &[(0x08, 6, 0x50)],
            true,
        );
        let mounts = vec![
            "/run/vrx/usb/1-1.2-p1".to_owned(),
            "/run/vrx/usb/1-1.2-p2".to_owned(),
            "/run/vrx/usb/1-1.3-p1".to_owned(),
        ];
        let (now, attached, detached) = merge(&[], scan(root.path()), &mounts);
        assert_eq!(attached.len(), 1);
        assert!(detached.is_empty());
        assert_eq!(
            now[0].mounts,
            mounts[..2].to_vec(),
            "three partitions would be three mounts, one row"
        );
        // the same device again: no arrival
        let (again, attached, _) = merge(&now, scan(root.path()), &mounts);
        assert!(attached.is_empty());
        // pulled
        std::fs::remove_dir_all(root.path().join("1-1.2")).unwrap();
        let (gone, _, detached) = merge(&again, scan(root.path()), &[]);
        assert!(gone.is_empty());
        assert_eq!(detached[0].port, "1-1.2");
        // a blocked mark stays while it stays unauthorised
        plug(
            root.path(),
            "1-1.4",
            "Thing",
            0x0bda,
            &[(0xff, 0xff, 0xff)],
            false,
        );
        let (mut a, _, _) = merge(&[], scan(root.path()), &[]);
        a[0].blocked = true;
        let (b, _, _) = merge(&a, scan(root.path()), &[]);
        assert!(b[0].blocked);
        plug(
            root.path(),
            "1-1.4",
            "Thing",
            0x0bda,
            &[(0xff, 0xff, 0xff)],
            true,
        );
        let (c, _, _) = merge(&b, scan(root.path()), &[]);
        assert!(!c[0].blocked, "authorised later: not blocked");
    }

    #[test]
    fn only_usb_devices_and_their_interfaces_are_events() {
        use crate::uevents::{message, parse};
        let ev = |header: &str, sub: &str| {
            event(&parse(&message(header, &[&format!("SUBSYSTEM={sub}")])).unwrap())
        };
        assert_eq!(
            ev("add@/devices/platform/x.usb/usb1/1-1/1-1.2", "usb"),
            Some(("1-1.2".into(), true))
        );
        assert_eq!(
            ev(
                "add@/devices/platform/x.usb/usb1/1-1/1-1.2/1-1.2:1.0",
                "usb"
            ),
            Some(("1-1.2".into(), true))
        );
        assert_eq!(
            ev("remove@/devices/platform/x.usb/usb1/1-1/1-1.2", "usb"),
            Some(("1-1.2".into(), false))
        );
        assert_eq!(
            ev("change@/devices/platform/x.usb/usb1/1-1/1-1.2", "usb"),
            Some(("1-1.2".into(), false))
        );
        assert_eq!(
            ev("add@/devices/platform/x.usb/usb1", "usb"),
            None,
            "a root hub"
        );
        assert_eq!(ev("add@/devices/x/block/sda", "block"), None);
    }

    /// The loop: a device present at the start is listed and not
    /// announced; a keyboard plugged is attached; a device the policy
    /// leaves unauthorised is blocked after SETTLE; a pull is detached; a
    /// new mount runs the scanner once.
    #[tokio::test(start_paused = true)]
    async fn the_host_loop_hears_plugs_pulls_blocks_and_mounts() {
        use crate::uevents::{message, parse};
        use std::sync::{Arc, Mutex};
        let root = tempfile::tempdir().unwrap();
        plug(root.path(), "1-1", "Hub", 0x05e3, &[(0x09, 0, 0)], true);
        let config = Config {
            ports: vec!["USB-A".into()],
            policy: "allowlist".into(),
            ..Config::default()
        };
        let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
        let raised = Arc::new(Mutex::new(Vec::<(String, serde_json::Value)>::new()));
        let state = Arc::new(Mutex::new((Vec::<Device>::new(), "")));
        let scans = Arc::new(Mutex::new(0));
        let (r, s, n) = (raised.clone(), state.clone(), scans.clone());
        let task = tokio::spawn(host(
            root.path().to_path_buf(),
            config,
            rx,
            move |d, p| *s.lock().unwrap() = (d, p),
            move |name, payload| r.lock().unwrap().push((name.to_owned(), payload)),
            || async { true },
            move || *n.lock().unwrap() += 1,
        ));
        let uevent = |action: &str, port: &str| {
            HostEvent::Uevent(
                parse(&message(
                    &format!("{action}@/devices/p/usb1/1-1/{port}"),
                    &["SUBSYSTEM=usb"],
                ))
                .unwrap(),
            )
        };
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        assert_eq!(state.lock().unwrap().0.len(), 1);
        assert_eq!(state.lock().unwrap().1, "allowlist");
        assert!(
            raised.lock().unwrap().is_empty(),
            "present at the start: not announced"
        );

        plug(
            root.path(),
            "1-1.2",
            "Keyboard",
            0x1234,
            &[(0x03, 1, 1)],
            true,
        );
        tx.send(uevent("add", "1-1.2")).unwrap();
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        assert_eq!(raised.lock().unwrap()[0].0, ATTACHED);
        assert_eq!(raised.lock().unwrap()[0].1["class"], "hid");

        plug(
            root.path(),
            "1-1.3",
            "Net",
            0x0bda,
            &[(0x02, 6, 0), (0x0a, 0, 0)],
            false,
        );
        tx.send(uevent("add", "1-1.3")).unwrap();
        tokio::time::sleep(SETTLE + std::time::Duration::from_millis(100)).await;
        {
            let raised = raised.lock().unwrap();
            let blocked: Vec<_> = raised.iter().filter(|(n, _)| n == BLOCKED).collect();
            assert_eq!(blocked.len(), 1, "{raised:?}");
            assert_eq!(blocked[0].1["port"], "1-1.3");
            assert_eq!(blocked[0].1["reason"], "policy");
        }
        assert!(state
            .lock()
            .unwrap()
            .0
            .iter()
            .any(|d| d.port == "1-1.3" && d.blocked));

        std::fs::remove_dir_all(root.path().join("1-1.2")).unwrap();
        tx.send(uevent("remove", "1-1.2")).unwrap();
        tx.send(HostEvent::Mounts(vec!["/run/vrx/usb/1-1.3-p1".into()]))
            .unwrap();
        tx.send(HostEvent::Mounts(vec!["/run/vrx/usb/1-1.3-p1".into()]))
            .unwrap();
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        assert!(raised
            .lock()
            .unwrap()
            .iter()
            .any(|(n, p)| n == DETACHED && p["port"] == "1-1.2"));
        assert_eq!(*scans.lock().unwrap(), 1, "the same mounts twice: one scan");
        assert_eq!(
            state
                .lock()
                .unwrap()
                .0
                .iter()
                .find(|d| d.port == "1-1.3")
                .unwrap()
                .mounts
                .len(),
            1
        );
        drop(tx);
        task.await.unwrap();
    }

    #[tokio::test]
    async fn a_board_with_no_host_port_publishes_none_and_returns() {
        let (_tx, rx) = tokio::sync::mpsc::unbounded_channel();
        let mut said = Vec::new();
        host(
            PathBuf::from("/nonexistent"),
            Config::default(),
            rx,
            |d, p| said.push((d, p)),
            |_, _| {},
            || async { true },
            || {},
        )
        .await;
        assert_eq!(said, vec![(Vec::new(), "none")]);
    }
}
