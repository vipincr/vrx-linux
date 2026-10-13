// The kernel's power supplies (plan 0011 D12): a battery's charge and a
// charger's presence live in /sys/class/power_supply, where the kit reads
// them; what sysfs cannot do is say when they change. The kernel does,
// as a `change` uevent on the power_supply class, which vrxhost hears on
// the kobject-uevent netlink socket and relays as `sys.power.changed`
// (payload: the supply's name), so an applet showing the battery reads
// sysfs again instead of polling it. No supply, no events, nothing sent.

/// The intent a supply's change raises.
pub const CHANGED: &str = "sys.power.changed";

/// The supply a kernel uevent says changed, if it is a power_supply
/// `change`: the message is `change@<devpath>` then NUL-separated
/// KEY=value lines.
pub fn changed_supply(message: &[u8]) -> Option<String> {
    let mut fields = message.split(|b| *b == 0).filter(|f| !f.is_empty());
    let header = std::str::from_utf8(fields.next()?).ok()?;
    if !header.starts_with("change@") {
        return None;
    }
    let (mut subsystem, mut name) = (None, None);
    for field in fields {
        let Ok(field) = std::str::from_utf8(field) else {
            continue;
        };
        if let Some(v) = field.strip_prefix("SUBSYSTEM=") {
            subsystem = Some(v);
        } else if let Some(v) = field.strip_prefix("POWER_SUPPLY_NAME=") {
            name = Some(v.to_owned());
        }
    }
    (subsystem == Some("power_supply"))
        .then_some(name)
        .flatten()
}

/// Listen to the kernel's uevents forever, calling `on_change` with each
/// power supply that changed.
#[cfg(target_os = "linux")]
pub async fn watch(mut on_change: impl FnMut(String)) -> std::io::Result<()> {
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
                if let Some(supply) = changed_supply(&buf[..n]) {
                    on_change(supply);
                }
            }
            Ok(Err(err)) => return Err(err),
            Err(_would_block) => continue,
        }
    }
}

/// Uevents are Linux's; a host build (the gate) has none.
#[cfg(not(target_os = "linux"))]
pub async fn watch(_on_change: impl FnMut(String)) -> std::io::Result<()> {
    Err(std::io::ErrorKind::Unsupported.into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_power_supply_change_names_its_supply_and_nothing_else_does() {
        let msg = b"change@/devices/platform/battery/power_supply/BAT0\0ACTION=change\0\
                    DEVPATH=/devices/platform/battery/power_supply/BAT0\0SUBSYSTEM=power_supply\0\
                    POWER_SUPPLY_NAME=BAT0\0POWER_SUPPLY_CAPACITY=81\0";
        assert_eq!(changed_supply(msg), Some("BAT0".into()));
        let add = b"add@/devices/x/power_supply/AC\0ACTION=add\0SUBSYSTEM=power_supply\0POWER_SUPPLY_NAME=AC\0";
        assert_eq!(changed_supply(add), None, "only changes");
        let other =
            b"change@/devices/x/backlight/b\0ACTION=change\0SUBSYSTEM=backlight\0";
        assert_eq!(changed_supply(other), None);
        assert_eq!(
            changed_supply(b"libudev\0\xfe"),
            None,
            "udev's binary header is not ours"
        );
    }
}
