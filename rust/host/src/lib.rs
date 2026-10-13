// vrxhost: the applet OS daemon.
//
// Owns the registry (scans /apps and /system/defaults), the supervisor
// (spawn/monitor/restart), the intent router (the Unix socket
// /tmp/vrx/vrx.sock), the back trail, and the session that turns the
// trail into the compositor's focus (amendment C: flutter-vrx composites,
// vrxhost decides what runs and what is shown). vrxinit starts it after
// the hardware services.
// This crate is a library so every piece is host-testable; main.rs is
// the thin binary that wires them together.

#![cfg_attr(test, allow(clippy::unwrap_used, clippy::expect_used, clippy::panic))]

pub mod compositor;
pub mod intent;
pub mod launch;
pub mod paths;
pub mod registry;
pub mod session;
pub mod supervisor;
pub mod trail;
