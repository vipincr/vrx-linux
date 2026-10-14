// The `camerad.photos` channel's records and the intents (plan 0018 D7):
// JSON lines, one request and one response per id; the JPEG rides the
// response as a memfd sealed against shrink, grow and write (or is only
// stored, with `keep`, and named by `path`).

use serde::{Deserialize, Serialize};

use crate::bounds::{DEFAULT_QUALITY, MAX_PIXELS};
use crate::types::CameraInfo;

fn quality() -> u8 {
    DEFAULT_QUALITY
}

fn yes() -> bool {
    true
}

/// What a client of `camerad.photos` asks.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(tag = "op", rename_all = "lowercase")]
pub enum Request {
    Capture {
        id: u64,
        /// A camera's id; null is the first listed.
        #[serde(default)]
        camera: Option<String>,
        /// The width wanted; null is the camera's largest. The height keeps
        /// the camera's aspect.
        #[serde(default)]
        width: Option<u32>,
        #[serde(default = "quality")]
        quality: u8,
        /// Store the JPEG in the photo folder and name it in `path`.
        #[serde(default)]
        keep: bool,
        /// Attach the JPEG as a memfd to the response (the default). A client
        /// that cannot receive descriptors (the Camera applet) sends false.
        #[serde(default = "yes")]
        fd: bool,
    },
    List {
        #[serde(default)]
        id: Option<u64>,
    },
    /// Choose the camera the viewfinder (and a capture with `camera: null`)
    /// uses. Refused with `busy` while a viewfinder is open: the Camera
    /// applet closes `camerad.frames`, switches, and opens it again.
    Select {
        #[serde(default)]
        id: Option<u64>,
        camera: String,
    },
}

/// Why a capture did not happen: the words of the response's `error`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Refusal {
    NoCamera,
    Busy,
    Disabled,
    NoRoom,
    FolderFull,
    TooLarge,
    Failed,
}

impl Refusal {
    pub fn as_str(self) -> &'static str {
        match self {
            Refusal::NoCamera => "no-camera",
            Refusal::Busy => "busy",
            Refusal::Disabled => "disabled",
            Refusal::NoRoom => "no-room",
            Refusal::FolderFull => "folder-full",
            Refusal::TooLarge => "too-large",
            Refusal::Failed => "failed",
        }
    }
}

/// One response line.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(untagged)]
pub enum Response {
    Photo {
        id: u64,
        ok: bool,
        bytes: usize,
        width: u32,
        height: u32,
        mime: &'static str,
        path: Option<String>,
    },
    Cameras {
        id: Option<u64>,
        ok: bool,
        cameras: Vec<CameraInfo>,
    },
    Done {
        id: Option<u64>,
        ok: bool,
    },
    Refused {
        id: Option<u64>,
        ok: bool,
        error: &'static str,
    },
}

impl Response {
    pub fn photo(
        id: u64,
        bytes: usize,
        width: u32,
        height: u32,
        path: Option<String>,
    ) -> Self {
        Response::Photo {
            id,
            ok: true,
            bytes,
            width,
            height,
            mime: "image/jpeg",
            path,
        }
    }

    pub fn refused(id: Option<u64>, why: Refusal) -> Self {
        Response::Refused {
            id,
            ok: false,
            error: why.as_str(),
        }
    }

    pub fn done(id: Option<u64>) -> Self {
        Response::Done { id, ok: true }
    }

    pub fn cameras(id: Option<u64>, cameras: Vec<CameraInfo>) -> Self {
        Response::Cameras {
            id,
            ok: true,
            cameras,
        }
    }
}

/// The body of `sys.camera.capture`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
pub struct CaptureIntent {
    #[serde(default)]
    pub keep: bool,
    #[serde(default)]
    pub announce: bool,
}

/// The body of `sys.camera.photo`: the stored photo's file name.
pub fn photo_intent(name: &str) -> serde_json::Value {
    serde_json::json!({ "path": name })
}

/// The size of a still: `width` (or the camera's largest) clamped so the
/// picture stays within [MAX_PIXELS] and never exceeds the camera's own
/// size, with the camera's aspect and even sides (a YUV 4:2:0 frame needs
/// them). None when the camera reports no size.
pub fn still_size(max: [u32; 2], width: Option<u32>) -> Option<(u32, u32)> {
    let [mw, mh] = max;
    if mw == 0 || mh == 0 {
        return None;
    }
    let wanted = width.unwrap_or(mw).clamp(2, mw);
    let mut w = u64::from(wanted);
    let mut h = (w * u64::from(mh)).div_ceil(u64::from(mw));
    if w * h > MAX_PIXELS {
        // scale both sides by the root of the ratio, rounding down
        let scale = (MAX_PIXELS as f64 / (w * h) as f64).sqrt();
        w = (w as f64 * scale) as u64;
        h = (w * u64::from(mh)).div_ceil(u64::from(mw));
        while w * h > MAX_PIXELS && w > 2 {
            w -= 2;
            h = (w * u64::from(mh)).div_ceil(u64::from(mw));
        }
    }
    let even = |n: u64| (n.max(2) & !1) as u32;
    Some((even(w), even(h)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_capture_reads_with_its_defaults_and_a_list_without_an_id() {
        let r: Request = serde_json::from_str(r#"{"op":"capture","id":7}"#).unwrap();
        assert_eq!(
            r,
            Request::Capture {
                id: 7,
                camera: None,
                width: None,
                quality: 85,
                keep: false,
                fd: true
            }
        );
        let r: Request =
            serde_json::from_str(r#"{"op":"capture","id":8,"keep":true,"fd":false}"#)
                .unwrap();
        assert!(matches!(
            r,
            Request::Capture {
                keep: true,
                fd: false,
                ..
            }
        ));
        assert_eq!(
            serde_json::from_str::<Request>(r#"{"op":"list"}"#).unwrap(),
            Request::List { id: None }
        );
        assert!(serde_json::from_str::<Request>(r#"{"op":"selfdestruct"}"#).is_err());
        assert!(serde_json::from_str::<Request>(r#"{"op":"capture"}"#).is_err());
    }

    #[test]
    fn responses_are_the_lines_the_plan_names() {
        let ok = Response::photo(7, 123_456, 1920, 1080, None);
        assert_eq!(
            serde_json::to_string(&ok).unwrap(),
            r#"{"id":7,"ok":true,"bytes":123456,"width":1920,"height":1080,"mime":"image/jpeg","path":null}"#
        );
        for (why, word) in [
            (Refusal::NoCamera, "no-camera"),
            (Refusal::Busy, "busy"),
            (Refusal::Disabled, "disabled"),
            (Refusal::NoRoom, "no-room"),
            (Refusal::FolderFull, "folder-full"),
            (Refusal::TooLarge, "too-large"),
            (Refusal::Failed, "failed"),
        ] {
            assert_eq!(
                serde_json::to_string(&Response::refused(Some(7), why)).unwrap(),
                format!(r#"{{"id":7,"ok":false,"error":"{word}"}}"#)
            );
        }
    }

    #[test]
    fn a_request_over_the_pixel_bound_is_clamped_and_keeps_its_aspect() {
        // 12 MP sensor, 4:3
        let (w, h) = still_size([4056, 3040], None).unwrap();
        assert!(u64::from(w) * u64::from(h) <= MAX_PIXELS, "{w}x{h}");
        assert!(w % 2 == 0 && h % 2 == 0);
        let ratio = f64::from(w) / f64::from(h);
        assert!((ratio - 4056.0 / 3040.0).abs() < 0.01, "{ratio}");
        // under the bound: as asked
        assert_eq!(still_size([1920, 1080], None), Some((1920, 1080)));
        assert_eq!(still_size([1920, 1080], Some(640)), Some((640, 360)));
        // never larger than the camera
        assert_eq!(still_size([640, 480], Some(4000)), Some((640, 480)));
        // odd sizes round to even
        assert_eq!(still_size([1280, 720], Some(641)), Some((640, 360)));
        assert_eq!(still_size([0, 0], None), None);
    }
}
