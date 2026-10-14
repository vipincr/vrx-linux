# 03 · How applets talk

There are four ways, and no fifth (AGENTS.md rule 7). The authoritative
description of the bridge is the Varlink interface itself: `IDL` in
`rust/host/src/varlink.rs`, served at runtime by
`org.varlink.service.GetInterfaceDescription("io.vrx.Host")` on
`/run/vrx/io.vrx.Host`. This page explains it; where they differ, the IDL
is right.

| Shape | What | Mechanism |
|---|---|---|
| State | a value that stays true until it changes | a file (`/etc/vrx/*`, `/sys`) watched with inotify, or a service's own D-Bus properties behind the kit's services |
| Signal | something happened or is wanted; small; has a verdict | an intent through `io.vrx.Host.Intent` |
| Stream | ordered records, one writer to one reader | a socket pair vrxhost hands to both ends (`Open`) |
| Device data | frames or samples too large to copy | buffers by index: a dmabuf or a sealed memfd passed once, then only `{index, bytes, sequence}` records |

vrxhost knows a caller by its cgroup: an applet is whichever
`vrx-applet@<id>.service` its process lives in. Nothing an applet sends can
claim another identity.

## Intents

`Intent(name, payload)` routes a signal to its handlers, asked in priority
order (higher first, built-ins before installed at equal priority); the
first `handled` wins.

- An **opened** handler declares a route (`at = "ring"`): vrxhost starts or
  fronts the applet there and, if it is running, also tells it over its
  `Listen`. Silence for 15 s counts as a pass.
- A **told** handler must be running; it hears the intent on `Listen` and
  has 100 ms to `Answer` `handled` or `pass`. Silence is a pass.

vrxhost refuses at the socket (G022): an intent the sender's manifest does
not `emit` (`NotDeclared`), a `sys.` name from an installed applet
(`Reserved`), and a payload over 4 KiB (`PayloadTooLarge`). Send an
identifier, never the data: a path, an id, a route.

In the kit: `Intent.send(name, payload)`, and an applet hears its own
through `VrxChannel`'s deliveries. In Rust: `vrx::ipc::intent_send` and
`Listener`.

## Navigation

`Push(applet, route)`, `Pop()` and `Home()` move vrxhost's back trail;
the front of the trail has the focus. A route the applet does not declare
opens its root. An applet asks where it was opened with `Route()`, and
hears later routes on `Listen` (kind `route`). `Watch()` streams the front
applet, the trail's depth, and `stopped` when an applet crashed.

The kit wraps these as `Nav.push`, `Nav.pop`, `Nav.home`; an applet never
uses Flutter's `Navigator` (the scan refuses it).

## Channels

An applet that offers a stream lists it (`[applet.channels] offers =
["frames"]`); one that opens it lists `<applet>.<channel>` in `opens`.
`Open(to, channel)` returns one end of a fresh socket pair as a file
descriptor and hands the other to the offerer's `Listen` (kind
`channel`). An undeclared channel is `NotDeclared`; an offerer not
listening is `NotListening`.

## Buffers by index

Device data stays in buffers its kernel driver owns (V4L2's `QBUF` and
`DQBUF` by index, ALSA's mmap ring, DRM and GBM). Between two applets the
buffer queue does the same: the producer passes its buffers once, over the
stream, and then only indices travel. A descriptor passed with `Open` must
be a dmabuf or a memfd sealed against shrinking; anything else is
`NotShareable`, so a receiver's mapping cannot lose its pages. The kit's
`VrxBufferQueue` and the SDK's `BufferQueue` implement it;
`tools/bench/bridge-check.sh` proves it on a board (1000 frames through 4
buffers, no payload on the stream).

## System facts and power

| Method | What |
|---|---|
| `Facts()` | the USB device port's state, the supply alarm, backlight changes, what is plugged into the USB host ports, streamed (plan 0012 D6): an applet hears these and never polls |
| `Applets()`, `Settings()` | the launcher's tiles; every declared setting |
| `Offers()`, `Install(file, build)`, `Uninstall(applet)` | applets a person installs, as systemd system extensions, with consent bound to the image's SHA-256 (the `apps` grant) |
| `Energy(hours)`, `Awake()` | what each applet costs and why the device is awake (the `power-stats` grant, plan 0012 D8, D12) |
| `PowerAlerts()`, `PowerAlertAnswer(applet, answer)` | applets over their power budget, for the shell's banner |
| `UsbEject(mount)`, `UsbPolicy(allow_new)` | eject a drive plugged into the board; "Allow new USB devices" under the image's allow-list (the `usb` grant, plan 0019 D10, D11) |

### USB, both directions

The board's USB raises two families of intents, named apart. The device
side is `sys.usb.connected`: a computer enumerated the board's gadget (the
console and file sharing, plan 0008 D11), and the `usb` fact is the UDC's
state. The host side is something plugged into the board (plan 0019):
`sys.usb.attached` and `sys.usb.detached` carry `{class, name, port}`, and
`sys.usb.blocked` carries `{name, port, reason}` for a device the image's
allow-list (USBGuard) left unauthorised for 1.5 s; the reason is `policy`,
or `policy-failed` when USBGuard is not running. `class` is one of `hid`,
`storage`, `audio`, `video`, `serial`, `hub`, `other`; `port` is the
device's place on the bus (`1-1.2`), stable while it stays plugged there.

The host side's facts:

| Fact | What |
|---|---|
| `usb_devices` | each device: `port`, `name`, `class`, `id` (vendor:product), `speed` (Mb/s), `authorized`, `blocked`, and a drive's `mounts` |
| `usb_policy` | `none` (no host ports), `open` (a debug image), `allowlist`, or `failed` (nothing newly plugged in works) |
| `usb_ports`, `usb_vbus`, `usb_overcurrent` | what the image declared (`/usr/lib/vrx/usb.toml`): the ports' labels, whether their power is `switched`, `unswitched` or `unknown`, whether an overload is `reported`, `none` or `unknown` |
| `usb_allow_new` | the policy switch as vrxhost last set it |

A drive's partitions mount read-only, never executable, at
`/run/vrx/usb/<port>-p<partition>`; an applet reads them with the
`usb-media` grant (a group, no device). No grant opens the bus or a block
device (G064). Each class has its owner: keyboards and mice reach the
compositor's libinput, cameras camerad (plan 0018), audio ALSA, serial
adapters `/dev/ttyUSB*` and `/dev/ttyACM*` under the `serial` grant. In
the kit: `VrxUsbHost.service`.

## Errors

Each refusal is named: `NoSuchApplet`, `NotOpenable` (a service has no
screen), `Disabled`, `NoHandler`, `NotDeclared`, `Reserved`,
`PayloadTooLarge`, `NotOffered`, `NotListening`, `NotShareable`,
`NotAnApplet` (a caller outside any applet's cgroup), `NotPermitted` (a
missing grant), `OfferChanged`, `OfferRefused`, `NotInstalled`,
`InstallFailed`, `Unavailable`. The kit turns each into one sentence a
person reads (`VrxWords`); the error's name goes to the log.
