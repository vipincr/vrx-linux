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
| Device data | frames/samples too large to copy | buffers by index: a dmabuf or a memfd sealed against shrinking passed once (on `Open`, or N of them over the stream as a buffer queue: SDK `BufferQueue`, vrx_kit `VrxBufferQueue`), then only `{index, bytes, sequence}` records |

**Buffers belong to the driver that fills them** (plan 0009 D10, after evrx-rt's plans 0037
and 0063). A device's data stays in buffers its kernel driver owns: V4L2's streaming I/O
(`REQBUFS`, `QBUF`/`DQBUF` by index, `EXPBUF` to a dmabuf), ALSA's mmap ring, DRM and GBM for
the panel (the compositor imports every app frame as a dmabuf). Above the driver, everything
exchanges which buffer moved, never the bytes. Between two applets, which the kernel has no
node for, the buffer queue does the same: the producer hands its buffers once, the consumer
gives indices back, and a frame with no free buffer is dropped and shows as a gap in the
sequence. vrxhost refuses a passed descriptor that is neither a dmabuf nor a sealed memfd
(`NotShareable`), so a receiver's mapping cannot lose its pages. No vrx code copies a frame or
a period the hardware could have moved. `tools/bench/bridge-check.sh` proves it on a board.

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
  → vrxhost: scan /system/defaults + /usr/lib/vrx/apps (installed
    applets, merged by systemd-sysext, plan 0011 D16) → registry →
    start home + resident applets as systemd units
    (vrx-applet@<id>.service, user vrx-<id>) → with a UI, control the
    compositor (focus = the trail's top) → serve io.vrx.Host
  → the screen lights: the launcher (headless: the resident applets run)
```

## The screen

The rule here, as everywhere in vrx: Linux first. Where Linux provides
the thing, vrx wraps or extends it behind a vrx interface; vrx keeps its
own only where Linux has none (plan 0010).

The compositor owns the screen's power. After `light_off` seconds with
no touch, click or key it turns the backlight off and powers the panel
down (DPMS), and tells every app it is hidden (Flutter's
`AppLifecycleState.hidden`: frames stop, Dart timers keep running, so an
alarm still fires). The next input wakes it, and that first press is
swallowed so it never presses what is under the finger.

Each setting has one home, and the kit's `ScreenSettings` is the vrx
interface to all of them:

| Setting | Home | Why there |
|---|---|---|
| brightness, where the backlight has levels | the backlight's own sysfs `brightness` | Linux's attribute; systemd-backlight keeps it across boots |
| brightness, where the compositor dims by plane alpha (a GPIO light, HDMI) | `brightness` in `/etc/vrx/display/screen.conf` | Linux has no software dimming |
| the idle timeout | `light_off` in `screen.conf` | the compositor's own policy |

The compositor says which dimming it does in `/run/vrx-ui/screen`
(`dim=backlight|alpha|none`); the slider is offered only where it can
dim. A position maps to a backlight level linearly and is never written
as 0, and the compositor keeps a perceptual floor above that, so no
value, row or button makes the screen dark by hand. The display grant
(group `vrx-display`, Settings and the shell) writes the brightness
attribute (udev opens it to that group) and `screen.conf`. G019: the
scan refuses `/sys/class/backlight` outside the kit's `screen.dart`, and
`bl_power` and `dpms` everywhere, with no `vrx-allow`.

A hold belongs to the model's state: an applet keeps the screen on by
its model saying why (`StoreModel.keepsScreenOn`), true only while
something is being watched or must be seen (a ringing alarm, a
viewfinder). The store reads it after every reduce, never in a build: an
applet behind another or under a dark screen is
`AppLifecycleState.hidden` and builds nothing, and a widget-held hold
could never wake the screen (bench, CM4, 2026-10-14: a timer rang behind
a dark screen and no inhibitor was taken). The store takes a logind idle
inhibitor (`Inhibit("idle", <applet>, <why>, "block")`, no grant needed),
one per applet, released when the model's reason goes or with the
process (logind drops it with its descriptor); `systemd-inhibit --list`
shows it. The compositor honours an inhibitor
only while its applet is in front, one that takes effect with the screen
off wakes it (that is how an alarm lights the screen), and a released
one restarts the full timeout. A reason that is always set is a screen
that never goes off.

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
