// vrxhost: the applet OS daemon.
//
// Owns the registry (scans /apps and /system/defaults), the supervisor
// (spawn/monitor/restart), the intent router (the Unix socket
// /tmp/vrx/vrx.sock) and the back trail. vrxinit starts it after the
// hardware services; the compositor handshake arrives with part E.
// This crate is a library so every piece is host-testable; main.rs is
// the thin binary that wires them together.

#![cfg_attr(test, allow(clippy::unwrap_used, clippy::expect_used, clippy::panic))]

pub mod intent;
pub mod paths;
pub mod registry;
pub mod supervisor;
pub mod trail;
