// The update upload (plan 0016 D11): the page sends a RAUC bundle to
// /api/update and it lands in /data/vrx/updates, where Settings > Software
// update offers it. Nothing here trusts the bundle: RAUC checks its
// signature when vrxhost inspects it, and installing waits for the person
// at the device. The name is the server's, so the client names nothing.

/// Where bundles wait (vrxhost's update::UPDATES).
pub const UPDATES: &str = "/data/vrx/updates";
/// The one upload kept: a new one replaces it.
pub const NAME: &str = "manage-upload.raucb";
/// Written here, renamed to NAME once every byte is in. The leading dot
/// keeps it out of the offers.
pub const PART: &str = ".manage-upload.part";
/// A bundle larger than a root slot cannot install anyway (VRX_ROOT_SLOT_MB
/// is 3072); 2 GiB covers a compressed one.
pub const MAX: u64 = 2 << 30;
/// Room /data keeps after the upload, for the applets' state.
pub const HEADROOM: u64 = 256 << 20;

/// Why an upload of `length` bytes is refused, with `avail_kb` free where
/// it would land: 413 too large, 507 no room, 400 empty.
pub fn refusal(length: u64, max: u64, avail_kb: Option<u64>) -> Option<u16> {
    if length == 0 {
        return Some(400);
    }
    if length > max {
        return Some(413);
    }
    match avail_kb {
        Some(kb) if kb.saturating_mul(1024) >= length.saturating_add(HEADROOM) => None,
        _ => Some(507),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_upload_needs_a_body_under_the_cap_and_room_to_spare() {
        let gib = 1u64 << 30;
        assert_eq!(refusal(gib, MAX, Some(4 * gib / 1024)), None);
        assert_eq!(refusal(0, MAX, Some(u64::MAX)), Some(400));
        assert_eq!(refusal(MAX + 1, MAX, Some(u64::MAX)), Some(413));
        assert_eq!(
            refusal(gib, MAX, Some((gib + HEADROOM) / 1024 - 1)),
            Some(507),
            "the headroom stays free"
        );
        assert_eq!(refusal(gib, MAX, None), Some(507), "df unread: refused");
    }

    #[test]
    fn the_names_stay_out_of_the_offers_until_complete() {
        assert!(PART.starts_with('.'));
        assert!(NAME.ends_with(".raucb") && !NAME.starts_with('.'));
    }
}
