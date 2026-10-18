// camerad's decisions, testable on any host (plan 0018): the engine, the
// photo folder, the conversions, the wire. The camera is a [source::Source];
// libcamera sits behind the `libcamera` feature in its own module and the
// Linux glue (memfd photos, the buffer queue) in `linux`.

#![deny(unsafe_code)]
#![cfg_attr(test, allow(clippy::unwrap_used, clippy::expect_used, clippy::panic))]

pub mod bounds;
pub mod convert;
pub mod engine;
pub mod jpeg;
pub mod protocol;
pub mod source;
pub mod state;
pub mod store;
pub mod take;
pub mod types;

#[cfg(target_os = "linux")]
pub mod linux;

#[cfg(all(target_os = "linux", feature = "libcamera"))]
pub mod libcamera_source;

/// One line to the journal, through the SDK's tracing (KRN-04, review
/// 2026-10-17): the hand-written eprintln was a second logging mechanism
/// beside the one the applet already installs at start.
pub fn log(line: &str) {
    tracing::info!("{line}");
}
