# Camera (plan 0018)

camerad is a headless service applet (`applets/camerad`, `kind = "service"`,
resident). It is the only process that links libcamera and holds the `camera`
grant (G056). The Camera applet, `vrx camera`, a script or another service are
its clients. A board with no display gets all of it.

## What a client reaches

A client needs the `camera-use` grant in its manifest and the channel in its
`opens` list. vrxhost checks the grant at `Open` (`NotPermitted`, G057); a
caller that is no applet (root at a shell) is the system and passes. An
installed (sideloaded) applet cannot hold any system grant, so it can never
reach the camera.

### `camerad.photos`: JSON lines, one request and one response per id

| Request | Response |
|---|---|
| `{"op":"capture","id":7,"camera":null,"width":null,"quality":85,"keep":false,"fd":true}` | `{"id":7,"ok":true,"bytes":123456,"width":1920,"height":1080,"mime":"image/jpeg","path":null}` with the JPEG attached as a memfd sealed against shrink, grow and write; `path` names `IMG_dddd.JPG` when `keep` stored it |
| `{"op":"list","id":1}` | `{"id":1,"ok":true,"cameras":[{"id","kind":"csi|usb|virtual","name","location":"front|back|external","max":[w,h]}]}` |
| `{"op":"select","id":2,"camera":"<id>"}` | `{"id":2,"ok":true}`; refused `busy` while a viewfinder is open |

Failures are `{"id":7,"ok":false,"error":"no-camera|busy|disabled|no-room|folder-full|too-large|failed"}`.
A client that cannot receive descriptors (the Camera applet) sends `"fd":false`.
Requests on one channel are answered in order, one at a time; at most four
clients are served, a fifth is told `busy`. `width` is clamped so the picture
stays within 8,000,000 pixels and the camera's own size, keeping its aspect.
A JPEG over 8 MiB is `too-large` and nothing is written; `keep` refuses below
32 MiB free (`no-room`) and past `IMG_9999.JPG` (`folder-full`). All bounds are
in `applets/camerad/src/bounds.rs` and nowhere else (G059).

### `camerad.frames`: the viewfinder as a buffer queue

One claimant at a time. The first line is the `BufferOffer` with its
descriptors: four buffers and a `format` `{fourcc, width, height, stride,
modifier}` (XRGB8888, 640x480, or 320x240 under a 480-pixel display). A second
claimant, or a claim while the camera is off or absent, gets one bare line
`{"error":"busy|disabled|no-camera|failed"}` and a closed stream. From then on
only `{index, bytes, sequence}` goes one way and `{index}` the other; the
pictures never cross the socket. v1 fills the queue's memfds (the engine
converts the camera's YUYV, NV12, planar YUV or MJPEG to XRGB8888); the SDK
and the engine also carry a zero-copy path (`offer_dmabufs`) that the libcamera
backend does not use yet.

### `sys.camera.capture` and `sys.camera.photo`

`sys.camera.capture {"keep":true,"announce":true}` is told: answered `handled`
at once, the photo made afterwards, stored as the next `IMG_dddd.JPG` in
`/data/photos`, and with `announce` sent on as `sys.camera.photo {"path":
"IMG_0042.JPG"}` to whoever handles it. That is the shape for a board with a
button script and no screen. With nobody handling it the photo stays.

## State

`/run/vrx/camera/state.json`, written only by camerad (atomically, world
readable, no image data), watch it with inotify:

```json
{"enabled":true,"cameras":[],"active":false,"clients":0,"reason":"none-found"}
```

`reason` is one of `ok`, `none-found`, `disabled`, `expected-csi-missing` (the
build named a CSI sensor and nothing enumerated), `starting`, `failed`. The
directory is the unit's `RuntimeDirectory`, so it vanishes with the unit and a
dead camerad cannot leave `active: true`. `active` is set in the one function
that starts a camera and cleared in the one that stops it (G058); the shell's
strip shows a camera mark while it is true.

## Detection

A CSI ribbon is not hot pluggable and the Pi firmware loads the sensor overlay
at boot, so a CSI camera is found at the next boot after it is attached. USB
cameras are listed and removed live (libcamera's hotplug). The Settings row
"Camera" is a software switch: off refuses everything and releases the camera.
The camera runs only while someone uses it and stops two seconds after the last
client or capture.

## Command line

`vrx camera list`, `vrx camera capture [-o FILE] [--keep] [--width N] [--camera ID]`
(the JPEG comes back as the sealed memfd and is written to FILE).

## Testing

Host: `cd applets/camerad && cargo test` (the engine against a fake camera;
libjpeg-turbo through pkg-config). Linux and the libcamera backend:
`tmp/camerad-linux.sh` in the rust image. Board: `tools/bench/camera-check.sh
<host>`. The Yocto side (knobs, kernel modules, overlays) is in the vrx repo's
`docs/CAMERA.md`.
