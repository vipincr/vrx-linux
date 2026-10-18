// Stills (plan 0018 D9): libjpeg-turbo, the one encoder on every board
// (evrx's quality 85). A webcam's MJPEG frame is stored as it is, with no
// re-encode and no loss; any other frame is converted to XRGB8888 and
// compressed. There is no hardware JPEG path: a second encoder for one
// family would be a second implementation of one job.

use turbojpeg::{Compressor, Decompressor, Image, PixelFormat, Subsamp};

use crate::convert::{self, ConvertError};
use crate::types::{Pixels, Raw};

/// Why a still could not be made.
#[derive(Debug)]
pub enum JpegError {
    Convert(ConvertError),
    Codec(String),
}

impl std::fmt::Display for JpegError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            JpegError::Convert(e) => write!(f, "{e}"),
            JpegError::Codec(e) => write!(f, "libjpeg-turbo: {e}"),
        }
    }
}

impl std::error::Error for JpegError {}

/// Compress tightly packed XRGB8888 (B G R X) at `quality` (1..=100).
pub fn encode_xrgb(
    xrgb: &[u8],
    width: u32,
    height: u32,
    quality: u8,
) -> Result<Vec<u8>, JpegError> {
    let mut c = Compressor::new().map_err(|e| JpegError::Codec(e.to_string()))?;
    c.set_quality(i32::from(quality.clamp(1, 100)))
        .map_err(|e| JpegError::Codec(e.to_string()))?;
    c.set_subsamp(Subsamp::Sub2x2)
        .map_err(|e| JpegError::Codec(e.to_string()))?;
    let image = Image {
        pixels: xrgb,
        width: width as usize,
        pitch: width as usize * 4,
        height: height as usize,
        format: PixelFormat::BGRX,
    };
    c.compress_to_vec(image)
        .map_err(|e| JpegError::Codec(e.to_string()))
}

/// Decode a JPEG to tightly packed XRGB8888: the pixels, width, height.
pub fn decode_xrgb(jpeg: &[u8]) -> Result<(Vec<u8>, usize, usize), JpegError> {
    let mut d = Decompressor::new().map_err(|e| JpegError::Codec(e.to_string()))?;
    let header = d
        .read_header(jpeg)
        .map_err(|e| JpegError::Codec(e.to_string()))?;
    let (w, h) = (header.width, header.height);
    let mut pixels = vec![0u8; w * h * 4];
    let image = Image {
        pixels: &mut pixels[..],
        width: w,
        pitch: w * 4,
        height: h,
        format: PixelFormat::BGRX,
    };
    d.decompress(jpeg, image)
        .map_err(|e| JpegError::Codec(e.to_string()))?;
    Ok((pixels, w, h))
}

/// The JPEG for a still frame: an MJPEG frame as it is, anything else
/// converted and compressed. The size is the frame's own.
pub fn still(raw: &Raw, quality: u8) -> Result<(Vec<u8>, u32, u32), JpegError> {
    if raw.pixels == Pixels::Mjpeg {
        // CON-03 (review 2026-10-17): the camera's bytes are checked
        // before they are stored — a sensor that hands back garbage
        // produced a corrupt "photo" and a failed gallery render, and a
        // zero-length frame produced an empty file with a .jpg name
        if !crate::jpeg::is_jpeg(&raw.data) {
            return Err(JpegError::Codec(
            "the MJPEG frame is not a JPEG".to_owned(),
        ));
        }
        let pixels = u64::from(raw.width) * u64::from(raw.height);
        if pixels == 0 || pixels > crate::bounds::MAX_PIXELS {
            return Err(JpegError::Codec(
            "the MJPEG frame's size is out of bounds".to_owned(),
        ));
        }
        return Ok((raw.data.clone(), raw.width, raw.height));
    }
    let xrgb = convert::to_xrgb(raw).map_err(JpegError::Convert)?;
    let jpeg = encode_xrgb(&xrgb, raw.width, raw.height, quality)?;
    Ok((jpeg, raw.width, raw.height))
}

/// A JPEG starts FF D8 and ends FF D9.
pub fn is_jpeg(bytes: &[u8]) -> bool {
    bytes.len() > 4
        && bytes[..2] == [0xff, 0xd8]
        && bytes[bytes.len() - 2..] == [0xff, 0xd9]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn grey(w: u32, h: u32) -> Raw {
        Raw {
            pixels: Pixels::Yuyv,
            width: w,
            height: h,
            stride: w * 2,
            data: (0..w * h).flat_map(|_| [126u8, 128]).collect(),
        }
    }

    #[test]
    fn a_still_is_a_valid_jpeg_of_the_frames_size_and_reads_back() {
        let (jpeg, w, h) = still(&grey(64, 48), 85).unwrap();
        assert!(is_jpeg(&jpeg), "FF D8 ... FF D9");
        assert_eq!((w, h), (64, 48));
        let (px, dw, dh) = decode_xrgb(&jpeg).unwrap();
        assert_eq!((dw, dh), (64, 48));
        let mid = (24 * 64 + 32) * 4;
        assert!((120..=135).contains(&px[mid]), "grey survives: {}", px[mid]);
    }

    #[test]
    fn mjpeg_is_stored_as_it_is_and_a_higher_quality_is_bigger() {
        let (jpeg, _, _) = still(&grey(64, 48), 85).unwrap();
        let frame = Raw {
            pixels: Pixels::Mjpeg,
            width: 64,
            height: 48,
            stride: 0,
            data: jpeg.clone(),
        };
        let (again, w, h) = still(&frame, 50).unwrap();
        assert_eq!((again, w, h), (jpeg, 64, 48), "no re-encode, no loss");
        let noisy: Vec<u8> = (0..64 * 48 * 4)
            .map(|i: u32| (i.wrapping_mul(2_654_435_761) >> 13) as u8)
            .collect();
        let low = encode_xrgb(&noisy, 64, 48, 20).unwrap();
        let high = encode_xrgb(&noisy, 64, 48, 95).unwrap();
        assert!(high.len() > low.len());
    }

    #[test]
    fn garbage_is_an_error() {
        assert!(decode_xrgb(&[0, 1, 2, 3]).is_err());
        assert!(!is_jpeg(&[0xff, 0xd8]));
    }
}
