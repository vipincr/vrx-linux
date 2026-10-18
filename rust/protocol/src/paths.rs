//! The device's vrx paths, one home (review 2026-10-17, KRN-04): the
//! host and the manage daemon spell the same constants today, and a path
//! that moves must not be found by one writer and missed by the other.
//!
//! These are the DEVICE's paths (the target's rootfs): the cross-build
//! tools and host-side scripts keep their own.

/// Where update bundles wait (`/data`'s updates directory).
pub const UPDATES: &str = "/data/vrx/updates";
/// vrxhost's record of a trial it asked for.
pub const UPDATE_STATE: &str = "/data/vrx/update";
/// Room `/data` keeps after an upload lands, for the applets' state.
/// Both writers of `UPDATES` admit against this (review CON-01).
pub const UPLOAD_HEADROOM: u64 = 256 << 20;
