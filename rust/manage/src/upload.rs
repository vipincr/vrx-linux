// The update upload (plan 0016 D11): the page sends a RAUC bundle to
// /api/update and it lands in /data/vrx/updates, where Settings > Software
// update offers it. Nothing here trusts the bundle: RAUC checks its
// signature when vrxhost inspects it, and installing waits for the person
// at the device. The name is the server's, so the client names nothing.

/// Where bundles wait (vrxhost's update::UPDATES).
pub use vrx_protocol::paths::UPDATES;
/// The one upload kept: a new one replaces it.
pub const NAME: &str = "manage-upload.raucb";
/// Written here, renamed to NAME once every byte is in. The leading dot
/// keeps it out of the offers.
pub const PART: &str = ".manage-upload.part";
/// A bundle larger than a root slot cannot install anyway (VRX_ROOT_SLOT_MB
/// is 3072); 2 GiB covers a compressed one.
pub const MAX: u64 = 2 << 30;
/// Room /data keeps after the upload, for the applets' state.
pub use vrx_protocol::paths::UPLOAD_HEADROOM as HEADROOM;

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

/// The largest upload refusal() would take now, with `avail_kb` free:
/// what GET /api/update tells the page, so the limit has one home (here)
/// and the page names it before sending anything. 0: nothing fits.
pub fn largest(max: u64, avail_kb: Option<u64>) -> u64 {
    let room = avail_kb
        .map(|kb| kb.saturating_mul(1024).saturating_sub(HEADROOM))
        .unwrap_or(0);
    room.min(max)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn largest_is_exactly_what_refusal_takes() {
        let gib = 1u64 << 30;
        for avail in [
            None,
            Some(0),
            Some(gib / 1024),
            Some(5 * gib / 1024),
            Some(u64::MAX / 2048),
        ] {
            let n = largest(MAX, avail);
            if n > 0 {
                assert_eq!(refusal(n, MAX, avail), None, "largest() fits: {avail:?}");
            }
            assert!(
                refusal(n + 1, MAX, avail).is_some(),
                "one more does not: {avail:?}"
            );
        }
        assert_eq!(largest(MAX, Some(u64::MAX / 2048)), MAX);
        assert_eq!(largest(MAX, None), 0, "df unread: nothing fits");
    }

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
