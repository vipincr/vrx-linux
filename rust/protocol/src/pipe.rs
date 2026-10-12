// The pipe: vrx's stream shape. Ordered records, one writer to one
// reader, with backpressure. A Unix socket in /tmp/vrx/pipes/, carrying
// JSON records in this envelope.
//
// Pipe names follow the intent naming rule (dotted lower-case,
// two-plus segments): one spelling rule for every named thing in vrx.

use serde::{Deserialize, Serialize};

use crate::intent;

/// An error from pipe name or message validation.
#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum PipeError {
    #[error("pipe name {name:?}: {source}")]
    BadName {
        name: String,
        source: intent::IntentError,
    },
}

/// Validate a pipe name (same rule as intent names).
pub fn validate_name(name: &str) -> Result<(), PipeError> {
    intent::validate_name(name).map_err(|source| PipeError::BadName {
        name: name.to_owned(),
        source,
    })
}

/// One record on a pipe: the pipe's name plus one JSON value.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PipeMessage {
    pub pipe: String,
    pub record: serde_json::Value,
}

impl PipeMessage {
    /// Construct a message, validating the pipe name.
    pub fn new(
        pipe: impl Into<String>,
        record: serde_json::Value,
    ) -> Result<Self, PipeError> {
        let pipe = pipe.into();
        validate_name(&pipe)?;
        Ok(Self { pipe, record })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn valid_pipe_names_pass() {
        for name in ["audio.samples", "sensor.imu.raw", "a.b"] {
            assert_eq!(validate_name(name), Ok(()), "{name}");
        }
    }

    #[test]
    fn invalid_pipe_names_are_refused() {
        for name in ["samples", "Audio.samples", "audio..samples"] {
            assert!(validate_name(name).is_err(), "{name}");
        }
    }

    #[test]
    fn message_construction_validates() {
        assert!(PipeMessage::new("ok.data", serde_json::json!(1)).is_ok());
        assert!(PipeMessage::new("bad", serde_json::json!(1)).is_err());
    }
}
