# vrx-linux

The applet operating system for Linux processors: Linux is the kernel,
vrx is the OS. A Rust workspace that ports the evrx-rt applet paradigm
(store/model/view, four IPC shapes, intents, the back trail) to Linux,
with Flutter as the UI framework. The plan of record is
`plans/0007-vrx-linux.md` in the vrx repo; Parts A–N there execute here.

## The gate is sacred

```bash
cargo xtask gate   # from the repo root (the workspace root)
```

fmt + clippy -D warnings + tests + cargo-deny, all blocking, chosen by
impact: a check whose inputs (its tree, its path dependencies, the
lockfiles, the fonts, the Flutter SDK) are unchanged since it last
passed is skipped (records in target/gate/). `cargo xtask gate --all`
runs every check; say why before using it. A change is not done until
the gate is green.

## Layout

| Path | What |
|---|---|
| `rust/protocol` | shared types: Manifest, Intent, PipeMessage, registry |
| `rust/host` | vrxhost: registry, trail and focus, intents, io.vrx.Host (Varlink); applets run as systemd units |
| `rust/sdk` | the `vrx` crate: what applet developers import |
| `rust/cli` | the `vrx` tool: new/build/install/test |
| `rust/xtask` | the gate |
| `flutter/vrx_kit` | the Flutter SDK package |
| `applets/` | built-in applets: launcher, settings, clock, terminal |
| `layer/` | the Yocto layer consumed by the vrx build |

`AGENTS.md` carries the hard rules (no unwrap/expect/panic, one job per
crate, no unsafe, the four IPC
shapes, vrx always lowercase). Read it before writing code.
