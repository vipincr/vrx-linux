// Device attestation (plan 0015 D11, G042). A debug image carries the
// SDK's published test chain (the test PAA, PAI and DAC for VID 0xFFF1,
// PID 0x8001, as rs-matter ships them): a home app pairs it with an
// "uncertified device" warning. A release image needs the owner's
// factory data (DAC, PAI, CD), which v1 does not load yet: built without
// the `test-attestation` feature, vrx-matter has no credentials and
// refuses to start, and the recipe refuses such a build before that.

use rs_matter::crypto::CanonPkcSecretKeyRef;
use rs_matter::dm::clusters::dev_att::DeviceAttestation;

/// What `State` reports.
#[cfg(feature = "test-attestation")]
pub const KIND: &str = "test";
#[cfg(not(feature = "test-attestation"))]
pub const KIND: &str = "none";

/// The device's attestation and its DAC's key, if this build has any.
#[cfg(feature = "test-attestation")]
pub fn credentials() -> Option<(
    &'static dyn DeviceAttestation,
    CanonPkcSecretKeyRef<'static>,
)> {
    use rs_matter::dm::devices::test::{DAC_PRIVKEY, TEST_DEV_ATT};
    Some((&TEST_DEV_ATT, DAC_PRIVKEY))
}

#[cfg(not(feature = "test-attestation"))]
pub fn credentials() -> Option<(
    &'static dyn DeviceAttestation,
    CanonPkcSecretKeyRef<'static>,
)> {
    None
}
