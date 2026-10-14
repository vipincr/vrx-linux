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

The reducer is the only writer (plan 0013 D1). A watch, a timer or a
finished call never writes a model field: it sends an action that carries
what happened (`UsbFacts(usb: u)`, `SettingsGo(open: Change(c))`), and
`state.dart` decides. An action type is sealed: an enum for the bare
signals (`init`, `back`) and a class per kind of fact; `Change(value)`
lets a fact set a field to null. The scan refuses `model.<field> =`
outside `state.dart` (G031).

A store test ends with `harness.verify(fresh: …)` (G032). It replays the
test's own actions from a fresh model and checks that every action from
every state reached reduces without a throw, that the replay gives the
same `fingerprint`, that `restore(snapshot)` round-trips, that Back
(`backAction`, until `atRoot`) reaches the root in 50 steps, and that an
applet opened at each route Backs out the same way. A fingerprint that
holds lists or maps is a list, so it compares deeply; a record compares
its fields with `==` only.

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
| `[applet.matter]` | what a home app sees once a person exposes the applet (plan 0015 D7): `device_type` (`on_off_plug`), `clusters` (`["on_off"]`), `on_off.command.on` and `.off`, two intents the applet handles told (no `at`) |
| `[applet.budgets]` | what a walk holds it to: `p95_frame_ms`, `dropped_per_min`, `cpu_ms_per_min`, `peak_mb` (plan 0014 D11); unset ones fall back to the board's `walk-budget` lines |

A grant is a group membership and nothing else (G017): `network`
(connman), `bluetooth` (BlueZ), `time`, `hostname`, `display`, `power`,
`usb`, `apps`, `serve`, `gpio`, `i2c`, `spi`, `serial`, `audio`, `camera`,
`input`, `iio`, `settings`, `ml`, `locale`, `power-stats`, `scripts`,
`matter` (vrx-matter's socket: pairing and what a home app sees). The service
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
| Every control says what it does in words: a glyph-only `VrxIconButton` takes a `label`, `VrxPress` a `label` where its child has no text | a screen reader and a walk find controls by those words | the layout test (G038, rule `label`) |
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

A Matter command (`[applet.matter]`) arrives the same way: vrxhost tells
the applet its own intent and nobody else's, and the answer is the home
app's status. Clock's block arms or disarms every alarm:

```toml
[applet.matter]
device_type = "on_off_plug"
clusters = ["on_off"]
on_off.command.on = "vrx.clock.alarm.arm"
on_off.command.off = "vrx.clock.alarm.disarm"
```

What a home app reads back is the last command it gave: no applet
publishes its own state to vrxhost yet.

## Input

Touch, a mouse and a keyboard all reach every control: the focus ring
moves with Tab and the arrows, Enter activates, Esc and the mouse's back
button are Back. A drag has a key form (the wheels, the slider). The kit
tracks which hands are in use (`VrxHandsScope`); no built-in applet varies
its layout by them yet, so evrx-rt's "ask what the hands are doing" note
applies to the first applet that does.

The on-screen keyboard is Flutter's text input control (plan 0013 D6). A
`TextField` that takes focus brings it up under the screen through
`VrxKeyboardHost`, which `AppletHost` installs; no screen places a keyboard
itself. It steps aside while a physical keyboard types, and, unless
Settings > Device > On-screen keyboard says Show, whenever the compositor
reports a keyboard plugged in (`keyboard=1` in `/run/vrx-ui/screen`). A
field that brings its own keys (the Scripts editor's terminal keys on a
short panel) declares `keyboardType: TextInputType.none` and gets none. A
screen that sizes itself around the keyboard decides on the display, never
on its layout box: the keyboard takes its share of the box when it comes
up, and a layout that changes because it did would put it away again.
Check: `flutter/vrx_kit/test/text_input_test.dart`.

The touch floor is the hardware's (G034). The compositor says `touch=1` or
`0` from udev's classification of the input devices, and `AppletHost`
installs `VrxInputModality.touch` only for 1; on a board with no
touchscreen, controls size to their content and keys reach them. vrx_check
lays every applet out both ways: with the display's own modality, and on a
touch panel again without the floor. Check: the G034 test in
`text_input_test.dart`, and `checkApplet` in vrx_check.

One finger drives the UI (plan 0013 D8). The compositor delivers the
first contact of a touch and holds the others back until it lifts, so two
fingers cannot press two controls at once. No applet gets more than one.

The swipe chain is Flutter's gesture arena (plan 0013 D9). A drag goes to
the innermost recogniser that claims it (a list, a wheel, the slider),
then outwards; whether a drag is the shell's is decided by the compositor
where the finger went down (plan 0008 D10). A screen whose body can be
taller than the client wraps it in `VrxPaged`: a vertical drag nothing
inside claims then pages the body a client height at a time, and a body
that fits does not move. Check: `flutter/vrx_kit/test/paged_test.dart`.

## Testing

```bash
flutter test                 # the store, the layout on every display
cargo xtask gate             # from the repo root: what changed, by impact
vrx build                    # the scan, analyze, the tests, then compile
```

The gate runs only the checks whose inputs changed since they last passed.

On a board with the profiling layer, a walk measures the applet in use
(plan 0014): `tools/walks/*.walk` is a path through the UI by control
labels, and

```bash
vrx walk run tools/walks/clock-alarm.walk --host 10.10.10.8
```

plays it on the device, captures a Perfetto trace around it, summarises
frames, drops, CPU, memory and I/O per applet with trace_processor, and
fails a metric over the applet's `[applet.budgets]`, naming the step where
it was worst. `vrx profile` is the same capture without a walk.
