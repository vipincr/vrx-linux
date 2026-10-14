// What camerad knows about a camera, in the words state.json and the
// `list` op use (plan 0018 D6).

use serde::{Deserialize, Serialize};

/// How a camera is attached.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    Csi,
    Usb,
    Virtual,
}

/// Where the camera looks, as far as the platform says.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Location {
    Front,
    Back,
    External,
}

/// One camera libcamera enumerated.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CameraInfo {
    pub id: String,
    pub kind: Kind,
    pub name: String,
    pub location: Location,
    /// The largest still it can make, width and height.
    pub max: [u32; 2],
}

/// Pixel layouts camerad converts or encodes. Sources report one of these;
/// anything else is a source error (the pipeline asks for what camerad
/// handles).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Pixels {
    /// 4 bytes a pixel, B G R X in memory (DRM XRGB8888): the viewfinder's.
    Xrgb8888,
    /// 4:2:2 packed, Y0 U Y1 V.
    Yuyv,
    /// 4:2:0 semi-planar: a Y plane, then interleaved U V.
    Nv12,
    /// 4:2:0 planar (I420): Y, then U, then V; the chroma stride is half
    /// the luma stride (libcamera's YUV420, the Pi ISP's still format).
    Yuv420,
    /// A whole JPEG file per frame (a webcam's MJPEG).
    Mjpeg,
}

/// One frame's pixels in memory, as a source hands it over.
#[derive(Debug, Clone)]
pub struct Raw {
    pub pixels: Pixels,
    pub width: u32,
    pub height: u32,
    /// Bytes from one row to the next (the Y plane's for NV12).
    pub stride: u32,
    pub data: Vec<u8>,
}

/// How a camera attaches, from libcamera's camera id: a UVC webcam's id
/// carries its bus path ("usb") or its vendor:product pair, the virtual
/// pipeline's is named for it, and everything else (a Pi sensor's
/// device-tree path, a K3 CSI sensor) is CSI. A heuristic, labelled as one:
/// libcamera has no public "bus" property.
pub fn kind_of(id: &str) -> Kind {
    let lower = id.to_ascii_lowercase();
    let vendor_product = id.rsplit('-').next().is_some_and(|tail| {
        tail.len() == 9
            && tail.as_bytes()[4] == b':'
            && tail
                .bytes()
                .enumerate()
                .all(|(i, b)| i == 4 || b.is_ascii_hexdigit())
    });
    if lower.contains("virtual") {
        Kind::Virtual
    } else if lower.contains("usb") || vendor_product {
        Kind::Usb
    } else {
        Kind::Csi
    }
}

impl Raw {
    /// The size in pixels, as a bound needs it.
    pub fn area(&self) -> u64 {
        u64::from(self.width) * u64::from(self.height)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_camera_id_says_how_it_is_attached() {
        // a UVC webcam by its vendor:product pair (libcamera's example id)
        assert_eq!(
            kind_of("\\_SB_.PCI0.XHC_.RHUB.HS09-9:1.0-0c45:2690"),
            Kind::Usb
        );
        assert_eq!(
            kind_of("/base/soc/usb@7e980000/hub-1:1.0-046d:0825"),
            Kind::Usb
        );
        // a Pi sensor by its device-tree path
        assert_eq!(kind_of("/base/soc/i2c0mux/i2c@1/imx219@10"), Kind::Csi);
        assert_eq!(
            kind_of("/base/axi/pcie@120000/rp1/i2c@88000/imx219@10"),
            Kind::Csi
        );
        assert_eq!(kind_of("Virtual0"), Kind::Virtual);
    }
}
