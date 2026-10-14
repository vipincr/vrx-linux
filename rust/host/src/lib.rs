// vrxhost: the applet OS daemon.
//
// Owns the registry (scans /apps and /system/defaults), the back trail,
// the session that turns the trail into the compositor's focus
// (amendment C), the intent router, and the io.vrx.Host Varlink
// interface. Applet processes are systemd units (plan 0008 D1): vrxhost
// starts them through systemd and reads their state; it forks nothing.
// This crate is a library so every piece is host-testable; main.rs is
// the thin binary that wires them together.

#![cfg_attr(test, allow(clippy::unwrap_used, clippy::expect_used, clippy::panic))]

pub mod applets;
pub mod bridge;
pub mod compositor;
pub mod freeze;
pub mod install;
pub mod intent;
pub mod paths;
pub mod power;
pub mod registry;
pub mod session;
pub mod trail;
pub mod usb;
pub mod varlink;
