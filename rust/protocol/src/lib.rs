// vrx-protocol: shared types for the vrx applet OS.
//
// The one crate both vrxhost and the SDK agree on: the manifest, the
// intent envelope, the pipe message, and the applet registry entry.
// No logic lives here — just the shapes on the wire and on disk, plus
// the validation rules every side must enforce identically (a manifest
// that parses on the host but not in the SDK would be a fifth IPC shape
// by the back door).

#![deny(unsafe_code)]
#![cfg_attr(test, allow(clippy::unwrap_used, clippy::expect_used))]

pub mod bufq;
pub mod intent;
pub mod manifest;
pub mod pipe;
pub mod registry;
pub mod scan;

pub use intent::{Intent, IntentPayload, Verdict};
pub use manifest::{HandleDecl, Manifest, SystemGrant};
pub use pipe::PipeMessage;
pub use registry::{Registry, RegistryEntry, RegistryError};
