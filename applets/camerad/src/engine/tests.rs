// The engine against a fake camera and a fake consumer: no libcamera, no
// sockets, no threads, time passed by hand. Rung 1 of plan 0018's
// verification (the FakeSource is a test double, not a second backend).

use std::sync::mpsc::channel;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use super::*;
use crate::bounds::{MIN_FREE_BYTES, QUEUE_BUFFERS};
use crate::protocol::{Request, Response};
use crate::types::{CameraInfo, Kind, Location, Pixels, Raw};

#[derive(Debug, Clone, PartialEq, Eq)]
enum Cmd {
    Start(u64, String, (u32, u32)),
    Stop,
    GiveBack(u32),
    Still(u64, String, (u32, u32)),
}

#[derive(Clone, Default)]
struct FakeSource(Arc<Mutex<Vec<Cmd>>>);

impl Source for FakeSource {
    fn start_view(&mut self, g: u64, camera: &str, size: (u32, u32)) {
        self.0
            .lock()
            .unwrap()
            .push(Cmd::Start(g, camera.into(), size));
    }
    fn stop_view(&mut self) {
        self.0.lock().unwrap().push(Cmd::Stop);
    }
    fn give_back(&mut self, slot: u32) {
        self.0.lock().unwrap().push(Cmd::GiveBack(slot));
    }
    fn still(&mut self, t: u64, camera: &str, size: (u32, u32)) {
        self.0
            .lock()
            .unwrap()
            .push(Cmd::Still(t, camera.into(), size));
    }
}

#[derive(Default)]
struct SinkLog {
    refused: Option<Refusal>,
    offered: Option<(u32, u64, Format, bool)>,
    free: Vec<u32>,
    queued: Vec<u32>,
    notify: Option<Notify>,
}

#[derive(Clone, Default)]
struct FakeSink(Arc<Mutex<SinkLog>>);

impl FrameSink for FakeSink {
    fn refuse(self: Box<Self>, why: Refusal) {
        self.0.lock().unwrap().refused = Some(why);
    }
    fn offer_copy(
        &mut self,
        count: u32,
        size: u64,
        f: Format,
        n: Notify,
    ) -> Result<(), String> {
        let mut l = self.0.lock().unwrap();
        l.offered = Some((count, size, f, false));
        l.free = (0..count).collect();
        l.notify = Some(n);
        Ok(())
    }
    #[cfg(unix)]
    fn offer_dmabufs(
        &mut self,
        fds: Vec<std::os::fd::OwnedFd>,
        size: u64,
        f: Format,
        n: Notify,
    ) -> Result<(), String> {
        let mut l = self.0.lock().unwrap();
        l.offered = Some((fds.len() as u32, size, f, true));
        l.notify = Some(n);
        Ok(())
    }
    fn take_free(&mut self) -> Option<u32> {
        let mut l = self.0.lock().unwrap();
        if l.free.is_empty() {
            None
        } else {
            Some(l.free.remove(0))
        }
    }
    fn write_slot(&mut self, _slot: u32, _pixels: &[u8]) -> Result<(), String> {
        Ok(())
    }
    fn queue(&mut self, slot: u32, _bytes: u64) -> Result<(), String> {
        self.0.lock().unwrap().queued.push(slot);
        Ok(())
    }
    fn push_free(&mut self, slot: u32) {
        self.0.lock().unwrap().free.push(slot);
    }
}

struct Rig {
    engine: Engine,
    source: FakeSource,
    announced: Arc<Mutex<Vec<String>>>,
    now: Instant,
    dir: tempfile::TempDir,
    free: Arc<Mutex<u64>>,
}

fn cam(id: &str, kind: Kind, max: [u32; 2]) -> CameraInfo {
    CameraInfo {
        id: id.into(),
        kind,
        name: format!("cam {id}"),
        location: Location::External,
        max,
    }
}

fn rig(conf: &str) -> Rig {
    let dir = tempfile::tempdir().unwrap();
    let source = FakeSource::default();
    let announced = Arc::new(Mutex::new(Vec::new()));
    let free = Arc::new(Mutex::new(u64::MAX));
    let (tx, rx) = channel();
    let a = Arc::clone(&announced);
    let f = Arc::clone(&free);
    std::fs::create_dir(dir.path().join("run")).unwrap();
    let env = Env {
        conf: Conf::parse(conf),
        state_dir: dir.path().join("run"),
        folder: Folder::with_free(
            dir.path().join("photos"),
            Box::new(move |_| Ok(*f.lock().unwrap())),
        ),
        small_display: false,
        inhibit: Box::new(|| None),
        announce: Box::new(move |n| a.lock().unwrap().push(n.into())),
        log: |_| {},
    };
    Rig {
        engine: Engine::new(env, Box::new(source.clone()), tx, rx),
        source,
        announced,
        now: Instant::now(),
        dir,
        free,
    }
}

impl Rig {
    fn cmds(&self) -> Vec<Cmd> {
        self.source.0.lock().unwrap().clone()
    }
    fn send(&mut self, i: Input) {
        let now = self.now;
        self.engine.handle(i, now);
    }
    fn advance(&mut self, by: Duration) {
        self.now += by;
        let now = self.now;
        self.engine.tick(now);
    }
    fn cameras(&mut self, list: Vec<CameraInfo>) {
        self.send(Input::Source(SourceEvent::Cameras(list)));
    }
    fn state(&self) -> serde_json::Value {
        serde_json::from_slice(
            &std::fs::read(self.dir.path().join("run/state.json")).unwrap(),
        )
        .unwrap()
    }
    fn ask(&mut self, request: Request) -> Receiver<Done> {
        let (tx, rx) = channel();
        self.send(Input::Photos { request, reply: tx });
        rx
    }
    fn capture(&mut self, keep: bool, fd: bool, width: Option<u32>) -> Receiver<Done> {
        self.ask(Request::Capture {
            id: 7,
            camera: None,
            width,
            quality: 85,
            keep,
            fd,
        })
    }
    fn claim(&mut self) -> FakeSink {
        let sink = FakeSink::default();
        self.send(Input::Claim {
            sink: Box::new(sink.clone()),
        });
        sink
    }
    fn view_started(&mut self, generation: u64) {
        self.send(Input::Source(SourceEvent::Started {
            generation,
            view: View {
                width: 640,
                height: 480,
                stride: 2560,
                #[cfg(unix)]
                zero_copy: None,
            },
        }));
    }
    fn frame(&mut self, generation: u64) {
        self.send(Input::Source(SourceEvent::Frame {
            generation,
            slot: 0,
            raw: Some(yuyv(64, 48)),
        }));
    }
    fn still_ticket(&self) -> u64 {
        self.cmds()
            .iter()
            .rev()
            .find_map(|c| match c {
                Cmd::Still(t, ..) => Some(*t),
                _ => None,
            })
            .expect("a still was asked for")
    }
    fn still_done(&mut self, raw: Raw) {
        let ticket = self.still_ticket();
        self.send(Input::Source(SourceEvent::Still {
            ticket,
            result: Ok(raw),
        }));
    }
}

fn yuyv(w: u32, h: u32) -> Raw {
    Raw {
        pixels: Pixels::Yuyv,
        width: w,
        height: h,
        stride: w * 2,
        data: (0..w * h).flat_map(|_| [126u8, 128]).collect(),
    }
}

fn refused(rx: &Receiver<Done>) -> String {
    match rx.try_recv().expect("an answer").response {
        Response::Refused { error, .. } => error.to_owned(),
        other => format!("not refused: {other:?}"),
    }
}

const USB: &str = "tokens=usb\n";

#[test]
fn with_no_camera_everything_is_refused_and_the_camera_is_never_started() {
    let mut r = rig("tokens=usb csi\nsensor=imx219\n");
    r.engine.publish();
    assert_eq!(r.state()["reason"], "expected-csi-missing");
    let rx = r.capture(false, true, None);
    assert_eq!(refused(&rx), "no-camera");
    let sink = r.claim();
    assert_eq!(sink.0.lock().unwrap().refused, Some(Refusal::NoCamera));
    assert!(r.cmds().is_empty(), "nothing was started for nothing");
    assert_eq!(r.state()["active"], false);
    let mut r = rig(USB);
    r.cameras(vec![]);
    assert_eq!(r.state()["reason"], "none-found");
}

#[test]
fn a_capture_returns_a_jpeg_lights_active_and_the_camera_stops_two_seconds_later() {
    let mut r = rig(USB);
    r.cameras(vec![cam("c0", Kind::Usb, [1280, 720])]);
    assert_eq!(r.state()["reason"], "ok");
    let rx = r.capture(false, true, None);
    assert_eq!(r.cmds(), [Cmd::Still(1, "c0".into(), (1280, 720))]);
    assert_eq!(r.state()["active"], true, "lit as the camera starts");
    assert_eq!(r.state()["clients"], 1);
    r.still_done(yuyv(64, 48));
    let done = rx.try_recv().unwrap();
    assert!(jpeg::is_jpeg(&done.jpeg.unwrap()));
    match done.response {
        Response::Photo {
            id,
            ok,
            width,
            height,
            path,
            ..
        } => {
            assert_eq!((id, ok, width, height, path), (7, true, 64, 48, None));
        }
        other => panic!("{other:?}"),
    }
    // still lit: the camera idles for IDLE_STOP so back-to-back shots do not
    // restart the sensor
    r.advance(Duration::from_millis(1900));
    assert_eq!(r.state()["active"], true);
    let _again = r.capture(false, true, None);
    assert!(!r.cmds().contains(&Cmd::Stop));
    r.still_done(yuyv(64, 48));
    r.advance(Duration::from_millis(1900));
    assert_eq!(
        r.state()["active"],
        true,
        "the clock restarted with the shot"
    );
    r.advance(Duration::from_millis(200));
    assert_eq!(r.state()["active"], false);
    assert_eq!(r.cmds().last(), Some(&Cmd::Stop));
}

#[test]
fn a_client_that_sends_fd_false_gets_no_bytes_and_keep_stores_and_announces() {
    let mut r = rig(USB);
    r.cameras(vec![cam("c0", Kind::Usb, [640, 480])]);
    let rx = r.capture(true, false, None);
    r.still_done(yuyv(64, 48));
    let done = rx.try_recv().unwrap();
    assert!(done.jpeg.is_none());
    match done.response {
        Response::Photo { path, .. } => assert_eq!(path.as_deref(), Some("IMG_0001.JPG")),
        other => panic!("{other:?}"),
    }
    assert!(jpeg::is_jpeg(
        &std::fs::read(r.dir.path().join("photos/IMG_0001.JPG")).unwrap()
    ));
    // the intent: stored, announced, no reply
    r.send(Input::Intent(CaptureIntent {
        keep: true,
        announce: true,
    }));
    r.still_done(yuyv(64, 48));
    assert_eq!(*r.announced.lock().unwrap(), ["IMG_0002.JPG"]);
    // never reuse a lower number than the highest present
    std::fs::write(r.dir.path().join("photos/IMG_0007.JPG"), b"x").unwrap();
    let rx = r.capture(true, false, None);
    r.still_done(yuyv(64, 48));
    match rx.try_recv().unwrap().response {
        Response::Photo { path, .. } => assert_eq!(path.as_deref(), Some("IMG_0008.JPG")),
        other => panic!("{other:?}"),
    }
}

#[test]
fn keep_is_refused_without_room_or_numbers_and_never_starts_the_camera_for_it() {
    let mut r = rig(USB);
    r.cameras(vec![cam("c0", Kind::Usb, [640, 480])]);
    *r.free.lock().unwrap() = MIN_FREE_BYTES - 1;
    let rx = r.capture(true, false, None);
    assert_eq!(refused(&rx), "no-room");
    assert!(r.cmds().is_empty());
    // the same request without keep still works
    let rx = r.capture(false, true, None);
    r.still_done(yuyv(64, 48));
    assert!(rx.try_recv().unwrap().jpeg.is_some());
    // a full folder
    *r.free.lock().unwrap() = u64::MAX;
    std::fs::create_dir_all(r.dir.path().join("photos")).unwrap();
    std::fs::write(r.dir.path().join("photos/IMG_9999.JPG"), b"x").unwrap();
    let rx = r.capture(true, false, None);
    assert_eq!(refused(&rx), "folder-full");
}

#[test]
fn a_request_over_the_pixel_bound_is_clamped_and_an_oversize_frame_or_jpeg_is_refused() {
    let mut r = rig(USB);
    r.cameras(vec![cam("c0", Kind::Usb, [4056, 3040])]);
    let rx = r.capture(false, true, None);
    let Cmd::Still(_, _, (w, h)) = r.cmds()[0].clone() else {
        panic!()
    };
    assert!(u64::from(w) * u64::from(h) <= MAX_PIXELS, "{w}x{h}");
    // a source that hands back more than the bound anyway
    r.still_done(Raw {
        pixels: Pixels::Yuyv,
        width: 4056,
        height: 3040,
        stride: 4056 * 2,
        data: vec![],
    });
    assert_eq!(refused(&rx), "too-large");
    // a JPEG over 8 MiB is too-large and nothing is written
    let rx = r.capture(true, false, Some(640));
    r.still_done(Raw {
        pixels: Pixels::Mjpeg,
        width: 640,
        height: 480,
        stride: 0,
        data: vec![0; MAX_JPEG_BYTES + 1],
    });
    assert_eq!(refused(&rx), "too-large");
    assert!(r.engine.env.folder.names().is_empty());
}

#[test]
fn a_still_the_source_fails_or_never_returns_is_answered_failed() {
    let mut r = rig(USB);
    r.cameras(vec![cam("c0", Kind::Usb, [640, 480])]);
    let rx = r.capture(false, true, None);
    let t = r.still_ticket();
    r.send(Input::Source(SourceEvent::Still {
        ticket: t,
        result: Err("no frame".into()),
    }));
    assert_eq!(refused(&rx), "failed");
    let rx = r.capture(false, true, None);
    r.advance(STILL_TIMEOUT + Duration::from_millis(1));
    assert_eq!(refused(&rx), "failed");
    // the late answer is ignored
    let t = r.still_ticket();
    r.send(Input::Source(SourceEvent::Still {
        ticket: t,
        result: Ok(yuyv(64, 48)),
    }));
    assert!(rx.try_recv().is_err());
}

#[test]
fn the_viewfinder_is_exclusive_and_frames_flow_through_four_buffers() {
    let mut r = rig(USB);
    r.cameras(vec![cam("c0", Kind::Usb, [640, 480])]);
    let a = r.claim();
    assert_eq!(r.cmds(), [Cmd::Start(1, "c0".into(), (640, 480))]);
    assert_eq!(r.state()["reason"], "starting");
    let b = r.claim();
    assert_eq!(b.0.lock().unwrap().refused, Some(Refusal::Busy));
    r.view_started(1);
    {
        let l = a.0.lock().unwrap();
        let (count, size, f, zero) = l.offered.unwrap();
        assert_eq!((count, size, zero), (QUEUE_BUFFERS, 2560 * 480, false));
        assert_eq!((f.width, f.height, f.stride), (640, 480, 2560));
    }
    assert_eq!(r.state()["reason"], "ok");
    // 1000 frames, the consumer returning each: none lost
    let claim = a.0.lock().unwrap().notify.as_ref().unwrap().claim;
    for _ in 0..1000 {
        r.frame(1);
        let q = a.0.lock().unwrap().queued.last().copied().unwrap();
        r.send(Input::Returned { claim, slot: q });
    }
    assert_eq!(a.0.lock().unwrap().queued.len(), 1000);
    // a consumer that never returns: after 4 frames the rest drop
    let mut r = rig(USB);
    r.cameras(vec![cam("c0", Kind::Usb, [640, 480])]);
    let a = r.claim();
    r.view_started(1);
    for _ in 0..10 {
        r.frame(1);
    }
    assert_eq!(a.0.lock().unwrap().queued.len(), 4);
}

#[test]
fn a_fact_from_an_ended_session_is_refused_by_its_generation() {
    let mut r = rig(USB);
    r.cameras(vec![cam("c0", Kind::Usb, [640, 480])]);
    let first = r.claim();
    r.view_started(1);
    let claim = first.0.lock().unwrap().notify.as_ref().unwrap().claim;
    r.send(Input::ViewerGone { claim });
    let second = r.claim();
    // late facts from generation 1 arrive after the second claimant started
    r.view_started(1);
    r.frame(1);
    assert!(second.0.lock().unwrap().offered.is_none());
    assert!(second.0.lock().unwrap().queued.is_empty());
    r.view_started(2);
    r.frame(2);
    assert_eq!(second.0.lock().unwrap().queued.len(), 1);
}

#[test]
fn leaving_stops_the_camera_two_seconds_later_and_a_vanished_camera_ends_the_view() {
    let mut r = rig(USB);
    r.cameras(vec![cam("c0", Kind::Usb, [640, 480])]);
    let a = r.claim();
    r.view_started(1);
    let claim = a.0.lock().unwrap().notify.as_ref().unwrap().claim;
    r.send(Input::ViewerGone { claim });
    assert_eq!(r.state()["active"], true);
    r.advance(Duration::from_millis(2100));
    assert_eq!(r.state()["active"], false);
    assert_eq!(r.cmds().last(), Some(&Cmd::Stop));
    // unplugged mid-preview: the list loses it, the viewer is dropped
    let mut r = rig(USB);
    r.cameras(vec![cam("c0", Kind::Usb, [640, 480])]);
    let a = r.claim();
    r.view_started(1);
    r.cameras(vec![]);
    r.send(Input::Source(SourceEvent::Lost { generation: 1 }));
    assert_eq!(r.state()["reason"], "none-found");
    r.advance(Duration::from_millis(2100));
    assert_eq!(r.state()["active"], false, "no stuck dot");
    // a return from the dropped consumer goes nowhere
    let claim = a.0.lock().unwrap().notify.as_ref().unwrap().claim;
    r.send(Input::Returned { claim, slot: 0 });
    // plugged back: claimable again
    r.cameras(vec![cam("c0", Kind::Usb, [640, 480])]);
    let again = r.claim();
    assert!(again.0.lock().unwrap().refused.is_none());
}

#[test]
fn a_view_that_fails_to_start_says_failed_to_the_claimant_and_the_state() {
    let mut r = rig(USB);
    r.cameras(vec![cam("c0", Kind::Usb, [640, 480])]);
    let a = r.claim();
    r.send(Input::Source(SourceEvent::StartFailed {
        generation: 1,
        why: "busy".into(),
    }));
    assert_eq!(a.0.lock().unwrap().refused, Some(Refusal::Failed));
    assert_eq!(r.state()["reason"], "failed");
    assert_eq!(r.state()["active"], false);
    // a new claim clears it
    let _b = r.claim();
    assert_eq!(r.state()["reason"], "starting");
}

#[test]
fn the_settings_switch_refuses_everything_and_releases_the_camera() {
    let mut r = rig(USB);
    r.cameras(vec![cam("c0", Kind::Usb, [640, 480])]);
    let _a = r.claim();
    r.view_started(1);
    let rx = r.capture(false, true, None);
    r.send(Input::Settings { enabled: false });
    assert_eq!(refused(&rx), "disabled");
    assert_eq!(r.state()["reason"], "disabled");
    assert_eq!(r.state()["enabled"], false);
    assert_eq!(r.state()["active"], false);
    assert_eq!(r.cmds().last(), Some(&Cmd::Stop));
    let rx = r.capture(false, true, None);
    assert_eq!(refused(&rx), "disabled");
    let b = r.claim();
    assert_eq!(b.0.lock().unwrap().refused, Some(Refusal::Disabled));
    assert_eq!(refused(&r.ask(Request::List { id: None })), "disabled");
    r.send(Input::Settings { enabled: true });
    assert_eq!(r.state()["reason"], "ok");
}

#[test]
fn at_most_four_clients_and_a_camera_can_be_chosen_only_while_nobody_views() {
    let mut r = rig(USB);
    r.cameras(vec![
        cam("c0", Kind::Usb, [640, 480]),
        cam("c1", Kind::Csi, [1920, 1080]),
    ]);
    let mut answers = Vec::new();
    for _ in 0..5 {
        let (tx, rx) = channel();
        r.send(Input::Join { reply: tx });
        answers.push(rx.try_recv().unwrap());
    }
    assert_eq!(answers, [true, true, true, true, false]);
    r.send(Input::Leave);
    let (tx, rx) = channel();
    r.send(Input::Join { reply: tx });
    assert!(rx.try_recv().unwrap());
    match r
        .ask(Request::List { id: Some(1) })
        .try_recv()
        .unwrap()
        .response
    {
        Response::Cameras { cameras, .. } => assert_eq!(cameras.len(), 2),
        other => panic!("{other:?}"),
    }
    let rx = r.ask(Request::Select {
        id: Some(2),
        camera: "c1".into(),
    });
    assert!(matches!(
        rx.try_recv().unwrap().response,
        Response::Done { ok: true, .. }
    ));
    let _a = r.claim();
    assert_eq!(r.cmds(), [Cmd::Start(1, "c1".into(), (640, 480))]);
    let rx = r.ask(Request::Select {
        id: Some(3),
        camera: "c0".into(),
    });
    assert_eq!(refused(&rx), "busy");
}

#[test]
fn an_unknown_camera_is_no_camera_when_nobody_views() {
    let mut r = rig(USB);
    r.cameras(vec![cam("c0", Kind::Usb, [640, 480])]);
    let rx = r.ask(Request::Select {
        id: None,
        camera: "nope".into(),
    });
    assert_eq!(refused(&rx), "no-camera");
}

#[test]
fn a_small_display_gets_the_small_viewfinder() {
    let mut r = rig(USB);
    r.engine.env.small_display = true;
    r.cameras(vec![cam("c0", Kind::Usb, [640, 480])]);
    let _a = r.claim();
    assert_eq!(r.cmds(), [Cmd::Start(1, "c0".into(), (320, 240))]);
}

#[cfg(unix)]
#[test]
fn a_zero_copy_view_hands_over_the_sources_buffers_and_returns_go_back_to_it() {
    use std::os::fd::OwnedFd;
    let mut r = rig(USB);
    r.cameras(vec![cam("c1", Kind::Csi, [640, 480])]);
    let a = r.claim();
    let fds: Vec<OwnedFd> = (0..2)
        .map(|_| OwnedFd::from(std::fs::File::open("/dev/null").unwrap()))
        .collect();
    r.send(Input::Source(SourceEvent::Started {
        generation: 1,
        view: View {
            width: 640,
            height: 480,
            stride: 2560,
            zero_copy: Some(fds),
        },
    }));
    assert!(a.0.lock().unwrap().offered.unwrap().3);
    r.send(Input::Source(SourceEvent::Frame {
        generation: 1,
        slot: 1,
        raw: None,
    }));
    assert_eq!(a.0.lock().unwrap().queued, [1]);
    let claim = a.0.lock().unwrap().notify.as_ref().unwrap().claim;
    r.send(Input::Returned { claim, slot: 1 });
    assert_eq!(r.cmds().last(), Some(&Cmd::GiveBack(1)));
}

/// G058: the camera is started in one function and stopped in one, so the
/// indicator cannot be dark while it runs.
#[test]
fn g058_the_camera_has_one_start_and_one_stop() {
    let text = include_str!("../engine.rs");
    let code = text.split("#[cfg(test)]").next().unwrap();
    for (call, want) in [
        ("self.source.start_view(", 1),
        ("self.source.still(", 1),
        ("self.source.stop_view(", 1),
    ] {
        assert_eq!(code.matches(call).count(), want, "{call}");
    }
    // and they sit inside camera_on / camera_off, beside the flag
    let on = code.find("fn camera_on").unwrap();
    let off = code.find("fn camera_off").unwrap();
    assert!(on < off);
    assert!(code[on..off].contains("self.active = true;"));
    assert!(code[on..off].contains("self.source.start_view("));
    assert!(code[on..off].contains("self.source.still("));
    let off_body = &code[off..];
    let end = off_body.find("\n    }\n").unwrap();
    assert!(off_body[..end].contains("self.source.stop_view("));
    assert!(off_body[..end].contains("self.active = false;"));
    // no other file in the crate talks to a Source
    for other in ["main.rs", "linux.rs", "lib.rs"] {
        let p = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("src")
            .join(other);
        if let Ok(t) = std::fs::read_to_string(p) {
            assert!(
                !t.contains(".start_view(") && !t.contains(".stop_view("),
                "{other}"
            );
        }
    }
}

/// G059: the capture bounds are spelled once, in bounds.rs.
#[test]
fn g059_no_other_file_spells_a_bound() {
    let src = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
    let mut stack = vec![src];
    while let Some(dir) = stack.pop() {
        for entry in std::fs::read_dir(dir).unwrap().flatten() {
            let path = entry.path();
            if path.is_dir() {
                stack.push(path);
                continue;
            }
            let name = path.file_name().unwrap().to_string_lossy().into_owned();
            if !name.ends_with(".rs") || name == "bounds.rs" || name == "tests.rs" {
                continue;
            }
            let text = std::fs::read_to_string(&path).unwrap();
            let code = text.split("#[cfg(test)]").next().unwrap();
            for line in code.lines().filter(|l| !l.trim_start().starts_with("//")) {
                for literal in [
                    "8_000_000",
                    "8000000",
                    "9999",
                    "8 * 1024 * 1024",
                    "32 * 1024 * 1024",
                ] {
                    assert!(!line.contains(literal), "{name}: {line}");
                }
            }
        }
    }
}
