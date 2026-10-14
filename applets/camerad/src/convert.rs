// Pixel conversion to the viewfinder's XRGB8888 (plan 0018 D8): the one
// unavoidable pass when a device produces YUYV, NV12 or MJPEG. Integer
// BT.601 limited range, the encoding webcams and the virtual camera use.
// CSI frames come out of the ISP as XRGB8888 already and are never here.

use crate::jpeg;
use crate::types::{Pixels, Raw};

/// Why a frame could not be converted.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConvertError {
    /// The buffer is shorter than its own geometry says.
    Short { have: usize, need: usize },
    /// Odd sides: 4:2:2 and 4:2:0 share chroma across pixel pairs.
    OddSize,
    /// An MJPEG frame libjpeg-turbo could not decode.
    Jpeg(String),
}

impl std::fmt::Display for ConvertError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ConvertError::Short { have, need } => {
                write!(f, "frame has {have} bytes, its geometry needs {need}")
            }
            ConvertError::OddSize => write!(f, "odd frame size"),
            ConvertError::Jpeg(e) => write!(f, "mjpeg: {e}"),
        }
    }
}

impl std::error::Error for ConvertError {}

fn clamp(v: i32) -> u8 {
    v.clamp(0, 255) as u8
}

/// One pixel: Y U V (0..255, limited range) to B G R.
fn yuv(y: u8, u: u8, v: u8) -> [u8; 3] {
    let c = i32::from(y) - 16;
    let d = i32::from(u) - 128;
    let e = i32::from(v) - 128;
    let r = (298 * c + 409 * e + 128) >> 8;
    let g = (298 * c - 100 * d - 208 * e + 128) >> 8;
    let b = (298 * c + 516 * d + 128) >> 8;
    [clamp(b), clamp(g), clamp(r)]
}

/// The frame as tightly packed XRGB8888 (B G R X, stride width * 4).
pub fn to_xrgb(raw: &Raw) -> Result<Vec<u8>, ConvertError> {
    let (w, h, stride) = (raw.width as usize, raw.height as usize, raw.stride as usize);
    let mut out = vec![0u8; w * h * 4];
    match raw.pixels {
        Pixels::Xrgb8888 => {
            need(raw, stride * h.saturating_sub(1) + w * 4)?;
            for y in 0..h {
                out[y * w * 4..(y + 1) * w * 4]
                    .copy_from_slice(&raw.data[y * stride..y * stride + w * 4]);
            }
        }
        Pixels::Yuyv => {
            if w % 2 != 0 {
                return Err(ConvertError::OddSize);
            }
            need(raw, stride * h.saturating_sub(1) + w * 2)?;
            for y in 0..h {
                let row = &raw.data[y * stride..y * stride + w * 2];
                for (x, quad) in row.chunks_exact(4).enumerate() {
                    let (y0, u, y1, v) = (quad[0], quad[1], quad[2], quad[3]);
                    let at = (y * w + x * 2) * 4;
                    let [b, g, r] = yuv(y0, u, v);
                    out[at..at + 4].copy_from_slice(&[b, g, r, 0xff]);
                    let [b, g, r] = yuv(y1, u, v);
                    out[at + 4..at + 8].copy_from_slice(&[b, g, r, 0xff]);
                }
            }
        }
        Pixels::Nv12 => {
            if w % 2 != 0 || h % 2 != 0 {
                return Err(ConvertError::OddSize);
            }
            let uv_at = stride * h;
            need(raw, uv_at + stride * (h / 2).saturating_sub(1) + w)?;
            for y in 0..h {
                for x in 0..w {
                    let luma = raw.data[y * stride + x];
                    let c = uv_at + (y / 2) * stride + (x / 2) * 2;
                    let [b, g, r] = yuv(luma, raw.data[c], raw.data[c + 1]);
                    let at = (y * w + x) * 4;
                    out[at..at + 4].copy_from_slice(&[b, g, r, 0xff]);
                }
            }
        }
        Pixels::Yuv420 => {
            if w % 2 != 0 || h % 2 != 0 {
                return Err(ConvertError::OddSize);
            }
            let cs = stride / 2;
            let u_at = stride * h;
            let v_at = u_at + cs * (h / 2);
            need(raw, v_at + cs * (h / 2).saturating_sub(1) + w / 2)?;
            for y in 0..h {
                for x in 0..w {
                    let luma = raw.data[y * stride + x];
                    let c = (y / 2) * cs + x / 2;
                    let [b, g, r] = yuv(luma, raw.data[u_at + c], raw.data[v_at + c]);
                    let at = (y * w + x) * 4;
                    out[at..at + 4].copy_from_slice(&[b, g, r, 0xff]);
                }
            }
        }
        Pixels::Mjpeg => {
            let (px, dw, dh) = jpeg::decode_xrgb(&raw.data)
                .map_err(|e| ConvertError::Jpeg(e.to_string()))?;
            if dw != w || dh != h {
                return Err(ConvertError::Jpeg(format!(
                    "frame is {dw}x{dh}, its geometry says {w}x{h}"
                )));
            }
            out = px;
        }
    }
    Ok(out)
}

fn need(raw: &Raw, need: usize) -> Result<(), ConvertError> {
    if raw.data.len() < need {
        return Err(ConvertError::Short {
            have: raw.data.len(),
            need,
        });
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn raw(pixels: Pixels, w: u32, h: u32, stride: u32, data: Vec<u8>) -> Raw {
        Raw {
            pixels,
            width: w,
            height: h,
            stride,
            data,
        }
    }

    #[test]
    fn limited_range_black_white_and_grey_come_out_right() {
        assert_eq!(yuv(16, 128, 128), [0, 0, 0]);
        assert_eq!(yuv(235, 128, 128), [255, 255, 255]);
        let [b, g, r] = yuv(126, 128, 128);
        assert!((120..=135).contains(&b) && b == g && g == r, "{b} {g} {r}");
        // saturated red: Y 81 U 90 V 240
        let [b, g, r] = yuv(81, 90, 240);
        assert!(r > 240 && g < 20 && b < 20, "{b} {g} {r}");
    }

    #[test]
    fn yuyv_converts_pairs_and_respects_the_stride() {
        // 2x2, stride 8 (4 bytes of padding per row): white then black rows
        let mut data = vec![0u8; 16];
        data[..4].copy_from_slice(&[235, 128, 235, 128]);
        data[8..12].copy_from_slice(&[16, 128, 16, 128]);
        let out = to_xrgb(&raw(Pixels::Yuyv, 2, 2, 8, data)).unwrap();
        assert_eq!(out.len(), 16);
        assert_eq!(&out[..4], &[255, 255, 255, 255]);
        assert_eq!(&out[8..12], &[0, 0, 0, 255]);
    }

    #[test]
    fn nv12_shares_chroma_over_two_by_two() {
        // 2x2: luma 235 235 / 16 16, one chroma pair neutral
        let data = vec![235, 235, 16, 16, 128, 128];
        let out = to_xrgb(&raw(Pixels::Nv12, 2, 2, 2, data)).unwrap();
        assert_eq!(&out[..4], &[255, 255, 255, 255]);
        assert_eq!(&out[8..12], &[0, 0, 0, 255]);
    }

    #[test]
    fn yuv420_planes_have_half_stride_chroma() {
        // 2x2: luma 235 235 / 16 16, U and V planes of one byte each
        let data = vec![235, 235, 16, 16, 128, 128];
        let out = to_xrgb(&raw(Pixels::Yuv420, 2, 2, 2, data)).unwrap();
        assert_eq!(&out[..4], &[255, 255, 255, 255]);
        assert_eq!(&out[8..12], &[0, 0, 0, 255]);
        assert!(to_xrgb(&raw(Pixels::Yuv420, 2, 2, 2, vec![0; 5])).is_err());
    }

    #[test]
    fn xrgb_copies_rows_without_the_padding() {
        let mut data = vec![0u8; 12 * 2];
        data[..4].copy_from_slice(&[1, 2, 3, 4]);
        data[12..16].copy_from_slice(&[5, 6, 7, 8]);
        let out = to_xrgb(&raw(Pixels::Xrgb8888, 1, 2, 12, data)).unwrap();
        assert_eq!(out, [1, 2, 3, 4, 5, 6, 7, 8]);
    }

    #[test]
    fn a_short_buffer_and_odd_sizes_are_refused_not_read_past() {
        assert_eq!(
            to_xrgb(&raw(Pixels::Yuyv, 2, 2, 4, vec![0; 7])),
            Err(ConvertError::Short { have: 7, need: 8 })
        );
        assert_eq!(
            to_xrgb(&raw(Pixels::Yuyv, 3, 2, 6, vec![0; 12])),
            Err(ConvertError::OddSize)
        );
        assert_eq!(
            to_xrgb(&raw(Pixels::Nv12, 2, 3, 2, vec![0; 20])),
            Err(ConvertError::OddSize)
        );
        assert!(to_xrgb(&raw(Pixels::Mjpeg, 2, 2, 0, vec![1, 2, 3])).is_err());
    }
}
