// The intent: vrx's signal shape. Something happened or is asked; small;
// has a verdict. Sent over the vrx Unix socket as one JSON value.
//
// Names are dotted lower-case, at least two segments, each segment
// starting with a letter (`sys.alarm.ring`, `vrx.ping.hello`), max 24
// bytes total. The bound exists so a name always fits a fixed-size log
// line; payloads are unbounded but should stay small — send an
// identifier, not a document.

use serde::{Deserialize, Serialize};

/// The maximum length of an intent name, in bytes.
pub const NAME_MAX_BYTES: usize = 24;

/// One JSON value carried by an intent.
pub type IntentPayload = serde_json::Value;

/// An error from intent name or payload validation.
#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum IntentError {
    #[error("intent name {name:?}: must be dotted lower-case with at least two segments, each starting with a letter (e.g. `sys.alarm.ring`)")]
    BadName { name: String },
    #[error("intent name {name:?}: longer than {NAME_MAX_BYTES} bytes")]
    NameTooLong { name: String },
}

/// Validate an intent name against the naming rule.
///
/// A segment matches `[a-z][a-z0-9]*`; a name is two or more segments
/// joined by `.`, at most [`NAME_MAX_BYTES`] bytes.
pub fn validate_name(name: &str) -> Result<(), IntentError> {
    let bad = || IntentError::BadName {
        name: name.to_owned(),
    };
    if name.len() > NAME_MAX_BYTES {
        return Err(IntentError::NameTooLong {
            name: name.to_owned(),
        });
    }
    let segments: Vec<&str> = name.split('.').collect();
    if segments.len() < 2 {
        return Err(bad());
    }
    for segment in segments {
        let mut chars = segment.chars();
        match chars.next() {
            Some(first) if first.is_ascii_lowercase() => {}
            _ => return Err(bad()),
        }
        if !chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit()) {
            return Err(bad());
        }
    }
    Ok(())
}

/// An intent: a name plus one JSON payload.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Intent {
    pub name: String,
    pub payload: IntentPayload,
}

impl Intent {
    /// Construct an intent, validating the name.
    pub fn new(
        name: impl Into<String>,
        payload: IntentPayload,
    ) -> Result<Self, IntentError> {
        let name = name.into();
        validate_name(&name)?;
        Ok(Self { name, payload })
    }
}

/// The verdict a handler returns for an intent.
///
/// Handlers are asked in priority order; the first `Handled` wins.
/// Silence (a timeout) counts as `Pass` and the next handler is asked.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Verdict {
    /// The handler took the intent; no further handler is asked.
    Handled,
    /// Not for this handler; ask the next one.
    Pass,
    /// The handler failed (negative errno); logged, then ask the next one.
    Err(i32),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn valid_names_pass() {
        for name in ["sys.alarm.ring", "vrx.ping.hello", "a.b", "app1.tap2.go3"] {
            assert_eq!(validate_name(name), Ok(()), "{name}");
        }
    }

    #[test]
    fn invalid_names_are_named() {
        for name in [
            "",          // empty
            "single",    // one segment
            "sys",       // one segment
            "Sys.alarm", // upper-case
            "sys..ring", // empty segment
            ".sys.ring", // leading dot
            "sys.ring.", // trailing dot
            "1sys.ring", // segment starts with a digit
            "sys.ri_ng", // underscore is not a segment character
            "sys alarm", // space
        ] {
            assert!(
                matches!(validate_name(name), Err(IntentError::BadName { .. })),
                "{name:?} should be refused"
            );
        }
    }

    #[test]
    fn oversize_name_is_refused() {
        let name = format!("{}.{}", "a".repeat(NAME_MAX_BYTES), "b");
        assert_eq!(
            validate_name(&name),
            Err(IntentError::NameTooLong { name: name.clone() })
        );
    }

    #[test]
    fn intent_construction_validates() {
        assert!(Intent::new("ok.tap", serde_json::json!({})).is_ok());
        assert!(Intent::new("bad", serde_json::json!({})).is_err());
    }
}
