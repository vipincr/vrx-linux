# 01 — vrx-linux architecture

Linux is the kernel; vrx is the OS. An applet is a store: a pure model
(state, actions, a reducer, a derived view model), its effects, and a
view — joined by one loop that is the only writer of the state. The
same model compiles into a host test: every applet's decisions are
testable without a board.

This document describes what exists today and where each piece lives.
The plan of record is `plans/0007-vrx-linux.md` in the vrx repo; where
this file and the plan disagree, the plan names the intent and this
file names the reality.

## The pieces

| Piece | Where | State |
|---|---|---|
| The protocol (manifest, intent, pipe, registry) | `rust/protocol` | landed; strict parse, unknown keys named |
| vrxhost (registry scan, supervisor, intent socket, trail) | `rust/host` | landed; integration-tested on host |
| The Rust SDK (`vrx` crate: applet, store, IPC clients, console kit) | `rust/sdk` | landed; hello example proves it end to end |
| The Flutter SDK (`vrx_kit`: store, theme, Nav, Motion, IPC) | `flutter/vrx_kit` | landed; 6 tests |
| The `vrx` CLI (new/build/install/test) | `rust/cli` | landed; both scaffolds pass their own tests |
| The gate (fmt + clippy -D warnings + tests + cargo-deny) | `rust/xtask` | landed; `cargo xtask gate` |
| The launcher (home applet) | `applets/launcher` | model landed; UI pending the compositor |
| The clock | `applets/clock` | model landed |
| Settings | `applets/settings` | model landed |
| The terminal (console + pipeline stage) | `applets/terminal` | landed; interactive half pending input (part E) |
| vrxinit (PID 1) | `rust/init` | decisions landed + tested; exec half is bench-verified |
| The compositor (DRM/KMS + Flutter engine) | `rust/compositor` | not started — part E, bench |
| flutter-bridge (bindgen for flutter_embedder.h) | `rust/flutter-bridge` | not started — part D, bench |
| The Yocto layer | `layer/` | vrxhost recipe + packagegroup; container-verified rung below |

## The four IPC shapes (there is no fifth way)

| Shape | What it is | vrx-linux mechanism |
|---|---|---|
| State | a value that stays true until it changes, watchable by anyone | a file (/data/settings/*, /sys), watched |
| Signal | something happened or is asked; small; has a verdict | an intent over /tmp/vrx/vrx.sock, one JSON value |
| Stream | ordered records, one writer to one reader, backpressure | a Unix socket in /tmp/vrx/pipes/ |
| Device data | frames/samples too large to copy | memfd or dmabuf (with the compositor) |

## The intent chain

Handlers are asked in priority order (priority descending, built-ins
before installed at equal priority); the first HANDLED wins. An
**opened** handler (`at <route>` in the manifest) makes vrxhost start
or front the applet at that route. A **told** handler must be running
to answer; silence (100ms told / 15s opened) is a PASS and the next
handler is asked.

## The boot

```
Linux kernel
  → vrxinit (PID 1): mount /proc /sys /dev, ensure /tmp/vrx,
    debug console only when the cmdline carries vrx.debug
  → systemd (hardware services; starts vrxhost per its unit)
  → vrxhost: scan /apps + /system/defaults → registry →
    supervise home + resident applets → serve the intent socket
  → (with the compositor, part E) the screen lights: the launcher
```

## The build rungs

Everything above claims only rungs it has actually reached:

- `cargo xtask gate` — green (fmt, clippy -D warnings, 60+ tests,
  cargo-deny bans/licenses/sources)
- `flutter test` — green in vrx_kit and every applet
- the Yocto recipe (vrxhost) — fetch verified in the container;
  the compile rung is tracked in the vrx repo's plan 0007 notes
- boots on hardware — pending the bench trip (parts E, M)
