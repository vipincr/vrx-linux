// A buffer queue between two applets (plan 0009 D10, after evrx-rt's plan
// 0037): the producer hands N buffers over a channel once, as file
// descriptors with the first message, and from then on the two sides send
// only which buffer moved. The data never crosses the stream.
//
// The wire, one JSON object per line on the channel's stream:
//   producer -> consumer  {"buffers": N, "size": S}   with the N descriptors
//   producer -> consumer  {"index": i, "bytes": b, "sequence": n}   filled
//   consumer -> producer  {"index": i}                given back
// A frame the producer has no free buffer for is dropped and counted, and
// the sequence numbers say so (a gap).

use serde::{Deserialize, Serialize};

/// The first message: how many buffers came with it and their size.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct BufferOffer {
    pub buffers: u32,
    pub size: u64,
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
