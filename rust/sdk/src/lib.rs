// The vrx Rust SDK: what an applet developer imports.
//
// Plan 0007 part G. The store trait (model + reducer + view + effects),
// the IPC clients (intent send, pipe, file watch) that work when
// vrxhost is running and degrade standalone, and the console kit for
// applets that render as text. Ships with vrx-test, the host-runnable
// store harness.

#![deny(unsafe_code)]

pub mod prelude {
    pub use vrx_protocol::{Intent, IntentPayload, PipeMessage, Verdict};
}
