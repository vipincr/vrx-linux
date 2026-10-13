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
| vrxhost (registry, trail and focus, intents, io.vrx.Host on Varlink; applets as systemd units, one user each) | `rust/host` | plan 0008 Part A |
| The Rust SDK (`vrx` crate: applet, store, IPC clients, console kit) | `rust/sdk` | landed; hello example proves it end to end |
| The Flutter SDK (`vrx_kit`: store, theme, Nav, Motion, IPC) | `flutter/vrx_kit` | landed; 6 tests |
| The `vrx` CLI (new/build/install/test) | `rust/cli` | landed; both scaffolds pass their own tests |
| The gate (fmt + clippy -D warnings + tests + cargo-deny) | `rust/xtask` | landed; `cargo xtask gate` |
| The launcher (home applet) | `applets/launcher` | model landed; UI pending the compositor |
| The clock | `applets/clock` | model landed |
| Settings | `applets/settings` | model landed |
| The console (Rust SDK applet + pipeline stage) | `applets/console` | landed, host-proven; ships in no image |
| The terminal (zsh on a pty, debug images) | `applets/terminal` | landed (plan 0008 Part F) |
| vrxinit (PID 1) | `rust/init` | decisions landed + tested; exec half is bench-verified |
| The compositor (DRM/KMS, input, one fullscreen app at a time) | flutter-vrx (`--compositor`, C, its own repo) | amendment C; vrxhost names the focus by pid over its socket |
| The Yocto layer | `layer/` | vrxhost + vrxinit recipes, packagegroup; image-built (below) |
| The design system (metrics, type, palettes, springs) | `flutter/vrx_kit` | landed with evrx-rt's exact numbers |
| The component library (rows, header, segmented, chip, banner, press) | `flutter/vrx_kit` | landed; contracts pinned by tests |
| The shell chrome (status strip) + boot screens (drawer, setup walk) + modals | `flutter/vrx_kit` | landed |
| Display scaling + input modality | `flutter/vrx_kit` | landed; reference 480 short side, touch floor by modality |

## The four IPC shapes (there is no fifth way)

| Shape | What it is | vrx-linux mechanism |
|---|---|---|
| State | a value that stays true until it changes, watchable by anyone | a file (/etc/vrx/*, /sys), watched; system state is the services' own D-Bus properties behind vrx_kit's domain services |
| Signal | something happened or is asked; small; has a verdict | an intent through `io.vrx.Host.Intent` (Varlink); a running handler receives it on its `Listen` call |
| Stream | ordered records, one writer to one reader, backpressure | a socket pair vrxhost hands to both ends (`io.vrx.Host.Open`) |
| Device data | frames/samples too large to copy | a sealed memfd or dmabuf passed the same way |

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
  → vrxinit (PID 1): mount /proc /sys /dev,
    debug console only when the cmdline carries vrx.debug
  → systemd (hardware services; tmpfiles makes /run/vrx; starts vrxhost)
  → vrx-ui (UI images only): flutter-vrx --compositor takes the display
  → vrxhost: scan /apps + /system/defaults → registry →
    start home + resident applets as systemd units
    (vrx-applet@<id>.service, user vrx-<id>) → with a UI, control the
    compositor (focus = the trail's top) → serve io.vrx.Host
  → the screen lights: the launcher (headless: the resident applets run)
```

## The build rungs

Everything above claims only rungs it has actually reached:

- `cargo xtask gate` — green (fmt, clippy -D warnings, 60+ tests,
  cargo-deny bans/licenses/sources)
- `flutter test` — green in vrx_kit and every applet
- the Yocto recipes (vrxhost, vrxinit) — image-built: the cm4/disp28a
  wic (0.1.0071) carries packagegroup-vrx-linux, vrxhost, vrxinit
- vrxboard-qemu — the software test target (same image, QEMU virt,
  runqemu in the container): boot and vrxhost-live verification run
  there before any bench trip
- boots on hardware — the bench keeps what only hardware can say:
  real panels and touch controllers, GPU acceleration, power
