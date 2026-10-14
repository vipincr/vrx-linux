// The seam between camerad's logic and a camera (plan 0018 D3): a Source
// takes commands and reports events. Everything libcamera-shaped sits behind
// it in libcamera_source.rs; the engine and its tests see only this. A
// source sends its events into the engine's input channel itself (libcamera
// calls back on its own thread), so there is no polling.

#[cfg(unix)]
use std::os::fd::OwnedFd;

use crate::types::{CameraInfo, Raw};

/// What a source tells the engine.
pub enum SourceEvent {
    /// The cameras now present: sent at start and on every hotplug.
    Cameras(Vec<CameraInfo>),
    /// A view started: frames follow with this generation (the evrx rule:
    /// a late fact from an ended session is refused by its number).
    Started {
        generation: u64,
        view: View,
    },
    StartFailed {
        generation: u64,
        why: String,
    },
    /// A viewfinder frame. `slot` names the source's own buffer in a
    /// zero-copy view (`raw` is None: the pixels are in the dmabuf); in a
    /// copy view `raw` holds them and `slot` is ignored.
    Frame {
        generation: u64,
        slot: u32,
        raw: Option<Raw>,
    },
    /// The camera went away (unplugged) or died under a running view.
    Lost {
        generation: u64,
    },
    /// A still, or why there is none.
    Still {
        ticket: u64,
        result: Result<Raw, String>,
    },
}

/// What a started view is: its picture size and, for a source whose frames
/// are already XRGB8888 in dmabufs, the buffers themselves.
pub struct View {
    pub width: u32,
    pub height: u32,
    pub stride: u32,
    /// One dmabuf per slot, when frames are never copied.
    #[cfg(unix)]
    pub zero_copy: Option<Vec<OwnedFd>>,
}

/// What the engine asks of a camera. Every method returns at once; the
/// outcome arrives as an event.
pub trait Source: Send {
    /// Start `camera` as a viewfinder of about `size`, tagged `generation`.
    fn start_view(&mut self, generation: u64, camera: &str, size: (u32, u32));
    /// Stop whatever is streaming and release the camera. A no-op when idle.
    fn stop_view(&mut self);
    /// A zero-copy slot the consumer returned: fill it again.
    fn give_back(&mut self, slot: u32);
    /// One still of about `size`. When a view is running on `camera` the
    /// source pauses and resumes it (frames continue under the same
    /// generation); otherwise it starts the camera for the shot alone.
    fn still(&mut self, ticket: u64, camera: &str, size: (u32, u32));
}
