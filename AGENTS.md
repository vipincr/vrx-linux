# AGENTS.md — vrx-linux

**vrx-linux** is the applet operating system for Linux processors: a Rust
workspace that provides the applet framework (store/model/view), the host
daemon (lifecycle, intents, navigation, the compositor's focus), and the
SDK for both Rust and Flutter applet developers. The compositor is
flutter-vrx (C, its own repo; plan 0007 amendment C), not a crate here. It is consumed by
the vrx Yocto build as a layer. Linux is the kernel; vrx is the OS.

> ## The gate is sacred

```bash
cargo xtask gate   # from the repo root (the workspace root)
```

Runs: fmt + clippy -D warnings + tests + cargo-deny. All blocking. A
change is not "done" until the gate is green.

> ## Hard rules

1. **No unwrap/expect/panic/todo/unimplemented/dbg!/print* in non-test
   code.** Use `?`, `tracing`, and proper error types. Tests relax via
   `#![cfg_attr(test, allow(...))]`.
2. **`[profile.dev] opt-level = 2` stays in the workspace Cargo.toml.**
   Without it, tests run 31x slower and time out (octiva lesson).
3. **One job per crate.** `protocol` is shared types only. `host` is the
   daemon. `sdk` is what applet developers import. `cli` is the `vrx`
   tool. No cross-boundary imports.
4. **No `unsafe`.** Applets are systemd units with their own users
   (plan 0008 D1), so vrxhost needs no privilege drop; the display and
   the engine FFI live in flutter-vrx, in C. A future block needs a
   SAFETY comment and a reason Linux offers no safe interface.
5. **"vrx" is always lowercase** — in prose, in code, in comments, in
   docs. Never "vrx" capitalized, never "VRX" except as a literal
   constant inherited from existing code.
6. **Linux is the kernel, vrx is the OS.** Users and developers think in
   vrx terms. The Linux filesystem is fully visible (like AOSP) but the
   primary experience is the vrx UI. No artificial hiding.
7. **The four IPC shapes** (state, signal, stream, device data) are the
   only ways applets communicate, and `io.vrx.Host` (Varlink) is the
   bridge that carries signals and hands out stream and device-data
   descriptors (plan 0008 D15). No fifth way. The gate enforces this.
8. **An applet is a store** (model + reducer + view + effects). The
   same model compiles into a host test. An applet reaches hardware
   only through what its manifest grants (plan 0008 D16): a group and
   a DeviceAllow class per device grant, enforced by its unit.
9. **Map onto Linux before writing code.** Supervision is systemd,
   authority is groups, bus policy and polkit, live system state is the
   services' own interfaces behind vrx_kit's domain services, persistent
   settings live in /etc (plan 0008). vrx code fills only the gaps.

> ## Planning uses the plan skill

Any request to plan, spec, design, or architect anything uses the
`plan` skill (in the vrx repo at `.claude/skills/plan/`). Not an
ad-hoc sketch. Plans persist to `plans/` on approval, never committed
by the agent.

## Documentation

- `docs/00-architecture.md` — how it fits together
- `docs/01-applet-guide.md` — how to write an applet (THE developer doc)
- `docs/02-design-system.md` — type, spacing, colour, motion
- `docs/03-ipc.md` — intents, pipes, files
- `docs/04-native.md` — Rust/console applets

## Layout

| Path | What |
|---|---|
| `rust/protocol/` | shared types (Manifest, Intent, PipeMessage) |
| `rust/host/` | vrxhost: the applet OS daemon |
| `rust/sdk/` | the Rust SDK crate (`vrx`) |
| `rust/cli/` | the `vrx` command-line tool |
| `rust/xtask/` | the gate |
| `flutter/vrx_kit/` | the Flutter SDK package |
| `applets/` | built-in applets (launcher, settings, clock, terminal) |
| `layer/` | Yocto layer |
