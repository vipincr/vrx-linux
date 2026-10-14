// The kernel's uevents, heard once (plan 0019 D7, G065). The kernel
// multicasts every device event on the kobject-uevent netlink socket,
// group 1 (udev re-sends its own on group 2); vrxhost binds one socket
// here and hands each message to whoever wants its subsystem: power.rs
// (power_supply and backlight changes) and usb.rs (devices plugged in and
// pulled out). No libudev and no second listener: the fields vrxhost
// needs are in the kernel's own message.
//
// A message is `action@devpath`, then NUL-separated KEY=value lines
// (ACTION, DEVPATH, SUBSYSTEM, DEVTYPE, PRODUCT, ...).

/// One kernel uevent.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Message {
    /// add, remove, change, bind, unbind, move, online, offline.
    pub action: String,
    /// The device's path under /sys.
    pub devpath: String,
    env: Vec<(String, String)>,
}

impl Message {
    /// A field's value.
    pub fn get(&self, key: &str) -> Option<&str> {
        self.env
            .iter()
            .find(|(k, _)| k == key)
            .map(|(_, v)| v.as_str())
    }

    /// SUBSYSTEM, or "".
    pub fn subsystem(&self) -> &str {
        self.get("SUBSYSTEM").unwrap_or("")
    }
}

/// A kernel uevent's bytes, read. Anything else (udev's own format, a
/// truncated header) is None.
pub fn parse(message: &[u8]) -> Option<Message> {
    let mut fields = message.split(|b| *b == 0).filter(|f| !f.is_empty());
    let header = std::str::from_utf8(fields.next()?).ok()?;
    let (action, devpath) = header.split_once('@')?;
    if action.is_empty() || !devpath.starts_with('/') {
        return None;
    }
    let env = fields
        .filter_map(|f| std::str::from_utf8(f).ok())
        .filter_map(|f| f.split_once('='))
        .map(|(k, v)| (k.to_owned(), v.to_owned()))
        .collect();
    Some(Message {
        action: action.to_owned(),
        devpath: devpath.to_owned(),
        env,
    })
}

/// Listen to the kernel's uevents forever, calling `on` with each.
#[cfg(target_os = "linux")]
pub async fn listen(mut on: impl FnMut(Message)) -> std::io::Result<()> {
    use rustix::net::{
        bind, netlink, socket_with, AddressFamily, SocketFlags, SocketType,
    };
    use tokio::io::unix::AsyncFd;

    let sock = socket_with(
        AddressFamily::NETLINK,
        SocketType::DGRAM,
        SocketFlags::CLOEXEC | SocketFlags::NONBLOCK,
        Some(netlink::KOBJECT_UEVENT),
    )?;
    // multicast group 1: the kernel's own uevents (udev re-sends on 2)
    bind(&sock, &netlink::SocketAddrNetlink::new(0, 1))?;
    let fd = AsyncFd::new(sock)?;
    let mut buf = vec![0u8; 8192];
    loop {
        let mut guard = fd.readable().await?;
        match guard.try_io(|s| {
            rustix::io::read(s.get_ref(), &mut buf[..]).map_err(std::io::Error::from)
        }) {
            Ok(Ok(n)) => {
                if let Some(message) = parse(&buf[..n]) {
                    on(message);
                }
            }
            Ok(Err(err)) => return Err(err),
            Err(_would_block) => {}
        }
    }
}

/// Uevents are Linux's; a host build (the gate) has none.
#[cfg(not(target_os = "linux"))]
pub async fn listen(_on: impl FnMut(Message)) -> std::io::Result<()> {
    Err(std::io::ErrorKind::Unsupported.into())
}

#[cfg(test)]
pub(crate) fn message(header: &str, fields: &[&str]) -> Vec<u8> {
    let mut bytes = header.as_bytes().to_vec();
    for f in fields {
        bytes.push(0);
        bytes.extend_from_slice(f.as_bytes());
    }
    bytes.push(0);
    bytes
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_kernel_message_is_read_and_anything_else_is_not() {
        let m = parse(&message(
            "add@/devices/platform/scb/fe980000.usb/usb1/1-1/1-1.2",
            &[
                "ACTION=add",
                "DEVPATH=/devices/platform/scb/fe980000.usb/usb1/1-1/1-1.2",
                "SUBSYSTEM=usb",
                "DEVTYPE=usb_device",
                "PRODUCT=46d/825/12",
                "TYPE=239/2/1",
            ],
        ))
        .unwrap();
        assert_eq!(m.action, "add");
        assert_eq!(m.subsystem(), "usb");
        assert_eq!(m.get("DEVTYPE"), Some("usb_device"));
        assert_eq!(m.get("PRODUCT"), Some("46d/825/12"));
        assert_eq!(m.get("NOPE"), None);
        // udev's re-sent format starts with its magic, and a bare word
        // carries no device
        assert!(parse(b"libudev\0\xfe\xed\xca\xfe").is_none());
        assert!(parse(b"change\0SUBSYSTEM=usb\0").is_none());
        assert!(parse(b"@/devices\0").is_none());
        assert!(parse(b"").is_none());
    }
}
