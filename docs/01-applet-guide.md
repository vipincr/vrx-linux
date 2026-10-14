# 01 · Writing an applet

**Linux first.** Where Linux, systemd or Flutter already provides a thing,
an applet uses it through the kit (`vrx_kit`) or the SDK (`vrx`); vrx
builds its own only where Linux has none, and never a second home beside
Linux's. Every rule below follows from that one, and each names the check
that holds it. A rule with no check says so.

`vrx new <id>` scaffolds a Flutter applet that already passes every check
here; `vrx build` runs them all before it compiles.

## The applet is a store

An applet is a model, its effects and a view, joined by one loop
(`flutter/vrx_kit/lib/src/store.dart`, `rust/sdk/src/store.rs`):

- `reduce(state, action)` applies an action and returns the view model. It
  is deterministic and does no I/O.
- `effects(state, action)` is the only place an applet touches the world
  (an intent, a file, a service call); the effect's result comes back as
  an action.
- The view draws the view model and turns taps into actions. It decides
  nothing.

`runApplet(model, view)` starts it; `AppletHost` installs the theme, the
insets under the strip, Back, the input root and the store. The same model
runs on the Mac in a test (`StoreHarness`), which fails a reduce over 2 ms.

## The manifest

`manifest.toml` beside the code says who the applet is and what it may
do. The parser refuses an unknown key by name (`rust/protocol/src/manifest.rs`).

| Section | What it declares |
|---|---|
| `[applet]` | `id`, `name` (what a person reads), `version`, `runtime` (`flutter`, `rust`, `native`), `kind` (`service` for no screen), `background` (why it runs behind the screen, built-ins only) |
| `[applet.display]` | `icon` (a Material Symbol), `tile`, `position`, `orientation` |
| `[applet.roles]` | `home`, `shell`, `installs`, `resident` (alive from boot) |
| `[applet.permissions]` | `system` grants, `fs` paths |
| `[applet.intents]` | `handles` (name, priority, optional `at` route), `emits` |
| `[applet.channels]` | `offers`, `opens` (`<applet>.<channel>`) |
| `[applet.routes]` | named screens; route 0 is the root and is never declared |
| `[[applet.settings]]` | key, label, category, type, default, options |

A grant is a group membership and nothing else (G017): `network`
(connman), `bluetooth` (BlueZ), `time`, `hostname`, `display`, `power`,
`usb`, `apps`, `serve`, `gpio`, `i2c`, `spi`, `serial`, `audio`, `camera`,
`input`, `iio`, `settings`, `ml`, `locale`, `power-stats`. The service
behind each checks the group itself. An installed applet gets none, runs as
a dynamic user and may not declare `background`, `fs` or a `sys.` emit
(G023).

## Rules and their checks

| Rule | Why | Check |
|---|---|---|
| Nothing blocks the UI isolate: no `*Sync(`, no `sleep(`, no `thread::sleep(` | a frame is 16 ms; a blocked isolate drops them | the scan (`rust/protocol/src/scan.rs`) |
| Navigation is vrxhost's back trail (`Nav`), never `Navigator.` | one Back for the whole device | the scan |
| A dialog is the kit's: `vrxConfirm`, `vrxAsk` | Back, Esc and the mouse's back button close the dialog first | the scan (G020) and the kit's modal tests |
| Every tappable thing is the kit's (`VrxPress`, `VrxRow`, `VrxChip`), never `InkWell` or `GestureDetector` | press feedback on touch-down, the action on release, the focus ring | the scan |
| A timer runs only while the applet is in front: `VrxTicker`, never `Timer.periodic` | a clock nobody sees costs power | the scan (G021) |
| Nothing polls; a loop that must wake on a clock says why with `// poll-ok: <reason>` | each poll is a wake; the system's state arrives as events | the scan (G027) |
| Colour is a slot (`VrxColors.of(context)`), never `Colors.` or `Color(0x` | twenty schemes and four display classes | the scan (G018 pins the slots) |
| An applet does not know its screen: no `VrxDisplayClass`, `classRow`, `displayClass`, `epaper` | the kit adapts, the applet stays the same | the scan |
| The screen's light and power are the compositor's: no `/sys/class/backlight`, `bl_power` or `dpms` outside the kit | a person can never be left with a dark screen | the scan (G019) |
| An applet sends only the intents it `emits`, and pushes only applets and routes that exist | a signal into the void is a silent bug | the gate and `vrx build` (G022); vrxhost refuses at the socket |
| `stdout` is not a log: `debugPrint` | the journal gets it with the applet's name | the scan |
| Every screen is in the layout test, on every display | text cut, overlapping or off the glass is found on the Mac | `test/layout_test.dart` with `expectCleanLayout`; the gate refuses a Flutter applet without one |
| A person reads full sentences, never an exception: `VrxWords` | one table of what went wrong, in their words | none (review) |
| Each applet has its own icon | the launcher is icon-led | none yet (plan 0013 D5, G033) |

A line that must break a scan rule says `vrx-allow: <reason>` above it.
The dialog, timer, poll and screen rules accept no `vrx-allow`.

## Lifecycle

An applet is a systemd unit, `vrx-applet@<id>.service`, running as user
`vrx-<id>` (plan 0008 D1). It has 5 s from start to its first frame
(`TimeoutStartSec`) and pings the watchdog once a minute (`WatchdogSec`).

- **Hidden.** When the applet loses focus or the screen goes off,
  flutter-vrx tells Flutter `AppLifecycleState.hidden`: frames stop,
  `VrxTicker` rests, Dart timers keep running. Listen with Flutter's own
  `AppLifecycleListener`.
- **Frozen.** 30 s after leaving the screen, vrxhost freezes the unit
  (systemd `FreezeUnit`), and thaws it before giving it focus, an intent,
  a route or a channel. A built-in that must keep working behind the
  screen declares `background = "<reason>"`; a resident applet, a service,
  the shell and Home are never frozen.
- **Stopped.** On SIGTERM the kit flushes pending writes (`VrxFile`, 2 s)
  before the process exits.

An applet keeps the screen on by its model saying why:
`String? get keepsScreenOn` returns a reason only while something is being
watched or must be seen (a ringing alarm, a viewfinder). The store takes a
logind idle inhibitor after the reduce that sets it, so a hidden applet's
ring still wakes the screen; the compositor honours it only while that
applet is in front.

## State, settings and files

- **Settings** a person changes are declared in the manifest and live in
  `/etc/vrx/settings/<id>.conf`; Settings shows them, `AppletSettings`
  reads and watches them.
- **The applet's own state** lives in its `StateDirectory`
  (`/var/lib/vrx/<id>`, `$HOME`), written atomically through `VrxFile`.
- **System facts** come from the kit's services (`VrxSystem.time`,
  `.network`, `.power`, `.bluetooth`, `ScreenSettings`, `PowerSupplyService`),
  which wrap the Linux service that owns each fact.

## Routes and intents

A screen another applet may open is a named route. `Nav.push(applet,
route: 'alarms')` opens it; an undeclared route opens the root. An intent
names something that happened or is wanted; handlers are asked in priority
order and the first `handled` wins. `03-ipc.md` has the chain, the channels
and the buffer queue.

## Input

Touch, a mouse and a keyboard all reach every control: the focus ring
moves with Tab and the arrows, Enter activates, Esc and the mouse's back
button are Back. A drag has a key form (the wheels, the slider). The kit
tracks which hands are in use (`VrxHandsScope`); no built-in applet varies
its layout by them yet, so evrx-rt's "ask what the hands are doing" note
applies to the first applet that does.

## Testing

```bash
flutter test                 # the store, the layout on every display
cargo xtask gate             # from the repo root: what changed, by impact
vrx build                    # the scan, analyze, the tests, then compile
```

The gate runs only the checks whose inputs changed since they last passed.
