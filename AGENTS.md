# AGENTS.md — vrx-linux

**vrx-linux** is the applet operating system for Linux processors: a Rust
workspace that provides the applet framework (store/model/view), the host
daemon (lifecycle, intents, navigation), the compositor (DRM + Flutter),
and the SDK for both Rust and Flutter applet developers. It is consumed by
the vrx Yocto build as a layer. Linux is the kernel; vrx is the OS.

> ## The gate is sacred

```bash
cd rust && cargo xtask gate
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
   tool. `compositor` is display. No cross-boundary imports.
4. **`unsafe` only in `flutter-bridge` and `compositor`** (the FFI and
   DRM layers). Everywhere else: none.
5. **"vrx" is always lowercase** — in prose, in code, in comments, in
   docs. Never "vrx" capitalized, never "VRX" except as a literal
   constant inherited from existing code.
6. **Linux is the kernel, vrx is the OS.** Users and developers think in
   vrx terms. The Linux filesystem is fully visible (like AOSP) but the
   primary experience is the vrx UI. No artificial hiding.
7. **The four IPC shapes** (state, signal, stream, device data) are the
   only ways applets communicate. No fifth way. The gate enforces this.
8. **An applet is a store** (model + reducer + view + effects). The
   same model compiles into a host test. No applet has direct hardware
   access.

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
| `rust/compositor/` | vrx-compositor: DRM + input + Flutter engine |
| `rust/flutter-bridge/` | FFI bindings to the Flutter engine |
| `rust/sdk/` | the Rust SDK crate (`vrx`) |
| `rust/cli/` | the `vrx` command-line tool |
| `rust/xtask/` | the gate |
| `flutter/vrx_kit/` | the Flutter SDK package |
| `applets/` | built-in applets (launcher, settings, clock, terminal) |
| `layer/` | Yocto layer |
