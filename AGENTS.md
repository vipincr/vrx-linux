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

fmt + clippy -D warnings + tests + cargo-deny, all blocking, chosen by
impact: a check whose inputs (its tree, its path dependencies, the
lockfiles, the fonts, the Flutter SDK) are unchanged since it last
passed is skipped (records in target/gate/). `cargo xtask gate --all`
runs every check; say why before using it. A change is not done until
the gate is green.

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
10. **Responsiveness is a contract, with hard gates** (plan 0008 D18,
    D19). The budgets: start to usable 5 s (systemd `TimeoutStartSec`),
    event loop alive 5 s (systemd `WatchdogSec`), input to screen p95
    50 ms (the bench gate), a told intent 100 ms, one reduce 2 ms (the
    store harnesses). In applet and SDK code:
    - nothing blocks the UI isolate or the event loop: no synchronous
      `dart:io` (`*Sync(`), no `sleep`, no `std::thread::sleep`; work
      goes into effects, I/O is async;
    - timers tick no faster than the manifest's `repaints_per_min`
      allows, and stop when the applet is not focused;
    - touch targets are 9mm; the exceptions are VrxKeyboard's key
      width (ten keys across a 43mm panel), which keeps the 9mm height,
      and the debug-only Terminal, whose keyboard is 6mm tall and whose
      text is 2mm (five 9mm rows fill a 57mm panel; 3.5mm text gives a
      20-column shell);
    - lists build lazily (`ListView.builder`, never a list of all rows);
      `build` does no work beyond describing widgets; const where it can;
    - every future is awaited or explicitly `unawaited`, every stream and
      subscription is closed;
    - only AOT release builds ship (the image build refuses anything else).
    The vrx lint set (`package:vrx_kit/analysis_options.yaml`, errors not
    warnings) and the gate's responsiveness scan enforce these; a line
    that must break one says `vrx-allow: <reason>`.
11. **Layout is computed, not eyeballed.** Every applet keeps a layout
    test that checks each of its screens, with real facts in them, on
    every display in the one table (`flutter/vrx_check/lib/displays.json`:
    the 2.8" panel, 7" DSI and HDMI panels, a 1080p monitor, a monitor
    with no EDID size). A Flutter applet's `test/layout_test.dart` mounts
    each screen and calls `expectCleanLayout`; a Rust applet's
    `tests/layout.rs` calls `vrx::layout::assert_clean_layout` on each
    screen, which computes the console grid from the panel's millimetres
    (Liberation Mono at body size, scaled as vrx_kit scales) and fails a
    row wider than it or a word longer than a line. `vrx build` refuses
    an applet without one and runs it, with the scan, fmt/clippy or
    analyze, and the tests, before compiling; `vrx new` scaffolds it.
    Home's and Settings' tests read every manifest, so an applet's name
    and setting labels are measured with no test of its own. It fails on a Flex
    overflow, text cut or wrapped inside a word, text over text, a
    control over a control or under 1mm from one (cells of a list or row
    excepted), a control under 9mm on a touch display, and anything off
    the screen. The gate runs it in the image's own fonts (`cargo xtask
    fonts`). A new screen is not done until it is in that test.
12. **The screen is the compositor's** (plan 0010, G019). No applet or
    kit code switches the light or the panel: brightness and the idle
    timeout are `ScreenSettings` (the `display` grant), and the one way
    to keep the screen on is `VrxKeepScreenOn`, wrapped round what is
    watched without being touched (a ring, a viewfinder), never round a
    whole applet. The compositor honours it only while the applet is in
    front.

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
