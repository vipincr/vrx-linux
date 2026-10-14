# 00 · vrx-linux architecture

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

| Piece | Where | Doc |
|---|---|---|
| The protocol: manifest, intents, registry, the scan, the unit generator | `rust/protocol` | `03-ipc.md` |
| vrxhost: registry, back trail and focus, intents, `io.vrx.Host` on Varlink, installs, freezing, energy | `rust/host` | `03-ipc.md`, below |
| The Rust SDK (`vrx`: applet, store, IPC, console kit, layout check, services) | `rust/sdk` | `04-native.md` |
| The Flutter SDK (`vrx_kit`: store, components, theme, Nav, the system services) | `flutter/vrx_kit` | `01-applet-guide.md`, `02-design-system.md` |
| The layout checker (`vrx_check`, the display table) | `flutter/vrx_check` | `01-applet-guide.md` |
| The `vrx` CLI (`new`, `build`, `test`, `unit`, `pack`) | `rust/cli` | `01-applet-guide.md` |
| The gate | `rust/xtask` | `AGENTS.md` |
| The compositor (DRM/KMS, input, screen power) | flutter-vrx (`--compositor`, C, its own repo) | below |
| The Yocto layer (recipes, units, policy, grants) | `layer/` | the vrx repo's docs |
| The built-in applets | `applets/` | each applet's `manifest.toml` |

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
| brightness, where the compositor dims with a black plane (a GPIO light, HDMI) | `brightness` in `/etc/vrx/display/screen.conf` | Linux has no software dimming |
| the idle timeout | `light_off` in `screen.conf` | the compositor's own policy |

The compositor says which dimming it does in `/run/vrx-ui/screen`
(`dim=backlight|alpha|none`); the slider is offered only where it can
dim. `alpha` means a dedicated overlay plane above the shell's, scanning
out a black buffer at partial alpha; the app's and the shell's planes stay
opaque, so the drawer never shows the app through it. A position maps to a backlight level linearly and is never written
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

## The time format

The time format is the system's locale, so it has one home: `LC_TIME` in
`/etc/locale.conf`, which systemd-localed writes (plan 0011 D7).
flutter-vrx reads it at start and whenever the file changes, and tells
every applet through Flutter's own `alwaysUse24HourFormat`; an applet
formats with `VrxTimeFormat` and keeps no 12/24 setting of its own.
Settings > Time > Time format lists the installed locales with an
example of each and sets one with localed's `SetLocale`. That call needs
the `locale` grant (group `vrx-locale`, held by Settings), whose polkit
rule allows exactly `org.freedesktop.locale1.set-locale`.

## Device Link

Device Link pairs a phone over Bluetooth (plan 0011 D19). connman owns
the radio's power, through its `bluetooth` technology, as it does for
Wi-Fi; BlueZ owns the adapter, pairing and the bonds. The kit's
`BluetoothService` is the vrx interface over both. What neither provides
is a person's answer to a pairing request, so the Device Link applet is
BlueZ's agent (`org.bluez.Agent1`, `DisplayYesNo`) while its window is
open: the six digits go on the screen, beside Cancel and Pair.

| Step | Mechanism |
|---|---|
| radio on or off | connman `Technology(bluetooth).SetProperty("Powered")` |
| the window | the agent registered as BlueZ's default, then `Adapter1.Pairable` and `Discoverable` with a 180 s timeout (BlueZ's own default) |
| a request | `RequestConfirmation` (digits to compare) or `RequestAuthorization` (yes or no), answered on screen; a confirmed device is marked `Trusted` so it reconnects with no agent running |
| paired phones | ObjectManager, `Device1.Paired` |
| forget | `Adapter1.RemoveDevice`, after a confirm |

Reading the radio needs only the `network` grant, so the shell's strip
glyph and drawer button follow connman without reaching BlueZ. The
adapter, pairing and the bonds need the `bluetooth` grant: vrx-policy's
bus policy keeps `org.bluez` to that group, because BlueZ's own policy
lets any user change the adapter. Device Link and Settings hold it.
Device Link holds the screen on while a passkey is up and while phones
can pair. The phone companion's GATT protocol is a separate approval and
is not part of this.

## The local models

The Assistant and speech-to-text (plan 0011 D18) run on llama.cpp's
`llama-server` and whisper.cpp's `whisper-server`, each behind a unix
socket in `/run/vrx-ml` that only the `ml` grant's group reaches; systemd
starts a server on its socket's first connection (through
`systemd-socket-proxyd`, the server itself in a network namespace of its
own) and stops it two minutes after the last request.

A model is never downloaded on the device. Each is its own recipe in
meta-vrx (`recipes-ml/models`), fetched by bitbake against a pinned
SHA-256 with its licence in the image manifest, and built in only where
the build lists it in `VRX_ML_MODELS` (empty by default). A model is named
by its role (`chat-…`, `speech-…`) and installs the role's link
(`/usr/share/vrx-ml/chat.gguf`, `speech.bin`) that its server reads; its
package brings that role's units (`vrx-ml-chat`, `vrx-ml-speech`) and
engine. The Assistant ships only with a chat model, stt only with a
speech model, and the Assistant offers Speak only where stt's socket
exists and ALSA lists a capture device.

## Scripts

The Scripts applet runs Python scripts from its folder
(`/var/lib/vrx/scripts/scripts`) as its own user, in its sandbox. Two
things go beyond a console (vrx plan 0013 D13).

**A script's own screen.** The `vrx` module (`applets/scripts/python/vrx.py`,
installed beside the applet and on `PYTHONPATH`) prints one JSON line,
`{"screen": [items], "title": "…"}`, where an item is `{"row": label,
"value": …, "tap": id}` or `{"text": paragraph}`; at most 50 items. The
applet reads its output a line at a time, draws such a line with kit rows
and puts every other line in the console. A pressed row writes
`{"tap": "<id>"}` to the script's input; `vrx.taps()` yields the ids and
`vrx.events()` also yields typed lines. `{"screen": null}` goes back to the
console. There is no other channel, so a script run in a terminal shows the
JSON and reads taps typed by hand. `samples/counter.py` is the example.

**Background scripts.** A script named with letters, digits, `-` and `_`
can run in the background as `vrx-script@<name>.service`, an instance of a
template the layer ships with a fixed ExecStart (`python3 -u` on that file),
the Scripts applet's user and the applet sandbox. The applet's `scripts`
grant (group `vrx-scripting`) lets it start, stop and reset-failed those
instances and no other unit (vrx-policy's polkit rule).
`StartTransientUnit` is never granted: polkit cannot see a transient unit's
properties, so granting it would hand out any command as root. systemd
restarts a crash (`Restart=on-failure`) and stops trying after five starts
in a minute. The applet's "In the background" screen lists the instances
from systemd (`ListUnitsByPatterns`, refreshed on systemd's job, unit and
property signals, never polled) and shows a unit that has restarted as
failing and one systemd gave up on as "Stopped after failing", which a tap
clears. Each instance is its own cgroup under
`system.slice/system-vrx\x2dscript.slice`; the shared counters
(`rust/host/src/counters.rs`) read only the applet slice today, so a
background script's cost is not yet in the energy record or a profile.

## Power

Efficiency is the default on every board, battery or not (plan 0012). The
rule is the same as everywhere: Linux counts and switches, vrx decides
and attributes.

- **CPU speed** is the kernel's `schedutil` on every board
  (`vrx-power-tuning`, meta-vrx). A local model server gets full speed
  only while it runs: `vrx-ml-speed.service` holds `scaling_min_freq` at
  the maximum through systemd's reference counting, and the minimum
  falls back when the last server stops (plan 0012 D1).
- **Applets behind the screen are frozen**: vrxhost freezes an applet
  through systemd's `FreezeUnit` 30 s after it leaves the screen and
  thaws it before focus, an intent, a route or a channel
  (`rust/host/src/freeze.rs`, G026). Never frozen: the shell, Home,
  resident applets, services, and an applet whose manifest says why it
  runs behind the screen (`background = "<reason>"`, built-ins only). Not
  frozen yet, asked again 30 s later: an applet holding a logind
  inhibitor, an open ALSA PCM, a channel end vrxhost handed it, or an
  intent or route from the last 30 s. systemd stops a frozen unit's
  watchdog and resets it on thaw (v259, `service_freezer_action`).
- **Nothing polls** (G027): the system's state reaches applets as
  events. vrxhost's `Facts` stream carries the USB port's state, the
  supply alarm and backlight changes; the rest is D-Bus signals and
  inotify. A loop that must wake on a clock says why (`// poll-ok:`).
- **Wakes are few**: the applet watchdog pings once a minute (D4);
  resident applets and services run with 50 ms timer slack (D5).
- **Each applet's cost is measured** (`rust/host/src/energy.rs`, D8,
  D9): vrxhost samples each applet unit's cgroup CPU time priced at the
  frequencies the CPU ran at, each applet process's GPU time from its
  render-node client in `/proc/<pid>/fdinfo`, voluntary context switches
  as the wakeup proxy, and the screen and radios from sysfs, priced with
  the board's measured power profile. Where a fuel gauge or a power
  monitor reports real power the shares are scaled to it. A board with
  no measured numbers says "not calibrated" and counts time only. A
  minute ring lives in `/run/vrx/energy`, hourly summaries in
  `/data/vrx/energy`; an applet over its budget is one journal event and
  one alert, and still over budget ten minutes after an unanswered alert
  it is frozen, never stopped without a person.

The measured numbers for the CM4 bench, and the per-SoC sleep model, are
in the vrx repo's `docs/POWER.md`.

## The build rungs

Everything above claims only rungs it has actually reached:

- `cargo xtask gate` — green (fmt, clippy -D warnings, 60+ tests,
  cargo-deny bans/licenses/sources)
- `flutter test` — green in vrx_kit and every applet
- the Yocto recipes: image-built in the container; 0.1.0094 (vrxboard-cm4,
  disp28a) flashed and booted on 2026-10-14 with every built-in applet,
  the local models opted in, and systemd-sysext
- vrxboard-qemu — the software test target (same image, QEMU virt,
  runqemu in the container): boot and vrxhost-live verification run
  there before any bench trip
- boots on hardware — the bench keeps what only hardware can say:
  real panels and touch controllers, GPU acceleration, power
