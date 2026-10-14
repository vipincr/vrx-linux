// A buffer queue between two applets (plan 0009 D10, after evrx-rt's plan
// 0037): the producer hands N buffers over a channel once, as file
// descriptors with the first message, and from then on the two sides send
// only which buffer moved. The data never crosses the stream.
//
// The wire, one JSON object per line on the channel's stream:
//   producer -> consumer  {"buffers": N, "size": S}   with the N descriptors
//                         (plus "format" for a queue of pictures, below)
//   producer -> consumer  {"index": i, "bytes": b, "sequence": n}   filled
//   consumer -> producer  {"index": i}                given back
// A frame the producer has no free buffer for is dropped and counted, and
// the sequence numbers say so (a gap).

use serde::{Deserialize, Serialize};

/// What a queue of pictures holds (plan 0018 D8): the DRM fourcc and the
/// geometry a viewfinder needs to import a buffer. A queue of anything
/// else sends none.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct BufferFormat {
    /// DRM fourcc (drm_fourcc.h), e.g. [FOURCC_XRGB8888].
    pub fourcc: u32,
    pub width: u32,
    pub height: u32,
    /// Bytes from one row to the next.
    pub stride: u32,
    /// DRM format modifier; 0 is linear.
    pub modifier: u64,
}

/// DRM_FORMAT_XRGB8888: 'X' 'R' '2' '4', little endian.
pub const FOURCC_XRGB8888: u32 = 0x3432_5258;

/// The first message: how many buffers came with it, their size, and for a
/// queue of pictures their format. A reader that predates `format` ignores
/// it, and a writer with none omits it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct BufferOffer {
    pub buffers: u32,
    pub size: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub format: Option<BufferFormat>,
}

/// A filled buffer, producer to consumer.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct BufferFilled {
    pub index: u32,
    pub bytes: u64,
    pub sequence: u64,
}

/// A buffer given back, consumer to producer.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct BufferReturned {
    pub index: u32,
}

/// The most buffers one queue holds (a descriptor each, in one message).
pub const MAX_BUFFERS: u32 = 16;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_offer_carries_a_format_only_when_it_has_one() {
        let plain = BufferOffer {
            buffers: 2,
            size: 64,
            format: None,
        };
        let line = serde_json::to_string(&plain).unwrap();
        assert_eq!(
            line, r#"{"buffers":2,"size":64}"#,
            "old readers see no change"
        );
        assert_eq!(serde_json::from_str::<BufferOffer>(&line).unwrap(), plain);
        let picture = BufferOffer {
            buffers: 4,
            size: 640 * 480 * 4,
            format: Some(BufferFormat {
                fourcc: FOURCC_XRGB8888,
                width: 640,
                height: 480,
                stride: 2560,
                modifier: 0,
            }),
        };
        let line = serde_json::to_string(&picture).unwrap();
        assert_eq!(serde_json::from_str::<BufferOffer>(&line).unwrap(), picture);
        // a reader that does not know `format` reads the two fields it knows
        #[derive(Deserialize)]
        struct Old {
            buffers: u32,
            size: u64,
        }
        let old: Old = serde_json::from_str(&line).unwrap();
        assert_eq!((old.buffers, old.size), (4, 1_228_800));
        assert_eq!(FOURCC_XRGB8888, u32::from_le_bytes(*b"XR24"));
    }

    #[test]
    fn the_records_are_one_line_each_and_read_back() {
        let filled = BufferFilled {
            index: 3,
            bytes: 4096,
            sequence: 17,
        };
        let line = serde_json::to_string(&filled).unwrap();
        assert_eq!(line, r#"{"index":3,"bytes":4096,"sequence":17}"#);
        assert_eq!(serde_json::from_str::<BufferFilled>(&line).unwrap(), filled);
        // a returned record is not a filled one
        assert!(serde_json::from_str::<BufferFilled>(r#"{"index":3}"#).is_err());
        assert_eq!(
            serde_json::from_str::<BufferReturned>(r#"{"index":3}"#)
                .unwrap()
                .index,
            3
        );
    }
}
