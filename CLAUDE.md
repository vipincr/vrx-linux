# vrx-linux

The applet operating system for Linux processors: Linux is the kernel,
vrx is the OS. A Rust workspace that ports the evrx-rt applet paradigm
(store/model/view, four IPC shapes, intents, the back trail) to Linux,
with Flutter as the UI framework. The plan of record is
`plans/0007-vrx-linux.md` in the vrx repo; Parts A–N there execute here.

## The gate is sacred

```bash
cd rust && cargo xtask gate
```

fmt + clippy -D warnings + tests + cargo-deny, all blocking. A change
is not done until the gate is green.

## Layout

| Path | What |
|---|---|
| `rust/protocol` | shared types: Manifest, Intent, PipeMessage, registry |
| `rust/host` | vrxhost: registry scan, supervisor, intent router, trail |
| `rust/compositor` | vrx-compositor: DRM/KMS, input, Flutter engine |
| `rust/flutter-bridge` | bindgen for flutter_embedder.h |
| `rust/sdk` | the `vrx` crate: what applet developers import |
| `rust/cli` | the `vrx` tool: new/build/install/test |
| `rust/xtask` | the gate |
| `rust/walk` | UI walk-test framework |
| `flutter/vrx_kit` | the Flutter SDK package |
| `applets/` | built-in applets: launcher, settings, clock, terminal |
| `layer/` | the Yocto layer consumed by the vrx build |

`AGENTS.md` carries the hard rules (no unwrap/expect/panic, one job per
crate, unsafe only in flutter-bridge and compositor, the four IPC
shapes, vrx always lowercase). Read it before writing code.
