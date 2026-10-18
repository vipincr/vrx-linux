// Every number that bounds a capture, in one place (plan 0018 D15, G059).
// A request can never exceed these; a numeric literal for one outside this
// file is refused by the scan, so a second spelling cannot drift.

use std::time::Duration;

/// A still is at most this many pixels (8 MP). Raised by one line once the
/// CMA bench row passes (plan 0018 risks).
pub const MAX_PIXELS: u64 = 8_000_000;
/// A JPEG over this many bytes is `too-large` and nothing is written.
pub const MAX_JPEG_BYTES: usize = 8 * 1024 * 1024;
/// A client that can ask at once: at most four, the fifth is `busy`.
pub const MAX_CLIENTS: usize = 4;
/// `keep` refuses below this much free space (`no-room`).
pub const MIN_FREE_BYTES: u64 = 32 * 1024 * 1024;
/// The viewfinder queue's buffers.
pub const QUEUE_BUFFERS: u32 = 4;
/// The camera stops this long after the last client or capture (D12), so
/// back-to-back captures do not restart the sensor.
pub const IDLE_STOP: Duration = Duration::from_secs(2);
/// The highest photo number, IMG_9999.JPG.
pub const MAX_PHOTO_NUMBER: u32 = 9999;
/// evrx's JPEG quality.
pub const DEFAULT_QUALITY: u8 = 85;
/// A display under this many pixels on its short side is small: the
/// viewfinder drops to VIEWFINDER_SMALL.
pub const SMALL_DISPLAY: u32 = 480;
/// The viewfinder's size, and the one under a small display, in the
/// camera's 4:3.
pub const VIEWFINDER: (u32, u32) = (640, 480);
pub const VIEWFINDER_SMALL: (u32, u32) = (320, 240);
/// A capture in flight is given this long before it is answered `failed`.
pub const STILL_TIMEOUT: Duration = Duration::from_secs(10);

// the caps are consistent: checked when the crate compiles, not when tests run
const _: () = {
    // an uncompressed 8 MP frame is far over the JPEG cap on purpose: the cap
    // bounds what is written, not what is sensed
    assert!(MAX_PIXELS * 4 > MAX_JPEG_BYTES as u64);
    // a queue is one message with its descriptors: at most 16 (the SDK's cap)
    assert!(QUEUE_BUFFERS <= 16);
    assert!((VIEWFINDER.0 as u64) * (VIEWFINDER.1 as u64) < MAX_PIXELS);
};
