// camerad's logic (plan 0018 D6, D7, D8, D11, D12, D15): one thread owns
// every decision. Clients (the photos channel's threads, a frames claimant,
// the intent, the settings watcher) and the camera (a Source) all talk to it
// through one input channel, so there is no shared state and no lock. The
// engine never touches a descriptor or a socket directly: frames go out
// through a FrameSink and answers through a reply channel, which is what
// lets the whole of it run in a host test with a fake camera.
//
// Generation rule (evrx's camera_model.c): every view start gets a number
// and a fact from a session that ended is refused by it.
//
// G058: there is exactly one function that starts a camera (`camera_on`)
// and exactly one that stops it (`camera_off`); `active` in state.json is
// set in the first and cleared in the second, so nothing can run the camera
// with the indicator dark.

use std::collections::HashMap;
use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender};
use std::time::Instant;

use crate::bounds::{
    IDLE_STOP, MAX_CLIENTS, MAX_JPEG_BYTES, MAX_PIXELS, QUEUE_BUFFERS, STILL_TIMEOUT,
    VIEWFINDER, VIEWFINDER_SMALL,
};
use crate::convert;
use crate::jpeg;
use crate::protocol::{still_size, CaptureIntent, Refusal, Request, Response};
use crate::source::{Source, SourceEvent, View};
use crate::state::{self, Conf, Progress, State};
use crate::store::{Folder, SaveError};
use crate::types::{CameraInfo, Pixels};

/// The answer to one photos request: the response line and, when the client
/// asked for the bytes, the JPEG (the client's thread seals it into a memfd).
pub struct Done {
    pub response: Response,
    pub jpeg: Option<Vec<u8>>,
}

/// Where one photos request's answer goes.
pub type Reply = Sender<Done>;

/// A picture's geometry on the frames queue (always XRGB8888).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Format {
    pub width: u32,
    pub height: u32,
    pub stride: u32,
}

/// What a sink needs to report a returned buffer or a closed consumer back
/// to the engine.
#[derive(Clone)]
pub struct Notify {
    pub claim: u64,
    pub tx: Sender<Input>,
}

/// The engine's end of a frames claimant (the buffer queue of plan 0009
/// D10 on Linux; a recorder in a test).
pub trait FrameSink: Send {
    /// The claim is refused: say why on the stream and close it.
    fn refuse(self: Box<Self>, why: Refusal);
    /// Hand over `count` buffers of `size` bytes that the engine will fill
    /// (a copy view), and start telling `notify` what comes back.
    fn offer_copy(
        &mut self,
        count: u32,
        size: u64,
        format: Format,
        notify: Notify,
    ) -> Result<(), String>;
    /// Hand over the source's own dmabufs (a zero-copy view).
    #[cfg(unix)]
    fn offer_dmabufs(
        &mut self,
        fds: Vec<std::os::fd::OwnedFd>,
        size: u64,
        format: Format,
        notify: Notify,
    ) -> Result<(), String>;
    /// A buffer to fill, if the consumer has given one back.
    fn take_free(&mut self) -> Option<u32>;
    /// Write the picture into buffer `slot`.
    fn write_slot(&mut self, slot: u32, pixels: &[u8]) -> Result<(), String>;
    /// Buffer `slot` holds `bytes`: the consumer gets it.
    fn queue(&mut self, slot: u32, bytes: u64) -> Result<(), String>;
    /// The consumer gave `slot` back (a copy view).
    fn push_free(&mut self, slot: u32);
}

/// Everything that arrives at the engine.
pub enum Input {
    Source(SourceEvent),
    /// A photos client connected; true if there is room (at most four).
    Join {
        reply: Sender<bool>,
    },
    Leave,
    Photos {
        request: Request,
        reply: Reply,
    },
    /// Someone claims the viewfinder.
    Claim {
        sink: Box<dyn FrameSink>,
    },
    /// The consumer gave a frames buffer back.
    Returned {
        claim: u64,
        slot: u32,
    },
    /// The consumer closed the frames queue.
    ViewerGone {
        claim: u64,
    },
    /// `sys.camera.capture`.
    Intent(CaptureIntent),
    /// The Settings switch.
    Settings {
        enabled: bool,
    },
}

/// What the engine needs from its surroundings besides the camera.
pub struct Env {
    pub conf: Conf,
    /// The runtime directory state.json is written in.
    pub state_dir: std::path::PathBuf,
    pub folder: Folder,
    /// The display is under 480 pixels: the viewfinder is 320x240.
    pub small_display: bool,
    /// Hold off sleep while a capture is in flight; the guard is dropped
    /// when the last one is answered. None where there is no logind.
    pub inhibit: Box<dyn FnMut() -> Option<Box<dyn Send>> + Send>,
    /// Tell whoever handles it that a photo was stored (`sys.camera.photo`).
    pub announce: Box<dyn FnMut(&str) + Send>,
    pub log: fn(&str),
}

struct Viewer {
    claim: u64,
    sink: Box<dyn FrameSink>,
    camera: String,
    generation: u64,
    /// Set when the view started and the offer went out.
    live: Option<Mode>,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Mode {
    Copy,
    ZeroCopy,
}

struct Pending {
    reply: Option<Reply>,
    id: Option<u64>,
    keep: bool,
    want_fd: bool,
    quality: u8,
    announce: bool,
    deadline: Instant,
}

pub struct Engine {
    env: Env,
    source: Box<dyn Source>,
    tx: Sender<Input>,
    rx: Receiver<Input>,
    enabled: bool,
    cameras: Vec<CameraInfo>,
    selected: Option<String>,
    active: bool,
    failed: bool,
    clients: usize,
    viewer: Option<Viewer>,
    claims: u64,
    generation: u64,
    tickets: u64,
    pending: HashMap<u64, Pending>,
    idle_at: Option<Instant>,
    hold: Option<Box<dyn Send>>,
    written: Option<State>,
}

impl Engine {
    pub fn new(
        env: Env,
        source: Box<dyn Source>,
        tx: Sender<Input>,
        rx: Receiver<Input>,
    ) -> Self {
        Self {
            env,
            source,
            tx,
            rx,
            enabled: true,
            cameras: Vec::new(),
            selected: None,
            active: false,
            failed: false,
            clients: 0,
            viewer: None,
            claims: 0,
            generation: 0,
            tickets: 0,
            pending: HashMap::new(),
            idle_at: None,
            hold: None,
            written: None,
        }
    }

    /// Run until every sender is gone. `busy` and `idle` bracket each input
    /// for the watchdog.
    pub fn run(&mut self, busy: impl Fn(), idle: impl Fn()) {
        self.publish();
        loop {
            let now = Instant::now();
            let input = match self.next_deadline() {
                Some(at) => match self.rx.recv_timeout(at.saturating_duration_since(now))
                {
                    Ok(input) => Some(input),
                    Err(RecvTimeoutError::Timeout) => None,
                    Err(RecvTimeoutError::Disconnected) => return,
                },
                None => match self.rx.recv() {
                    Ok(input) => Some(input),
                    Err(_) => return,
                },
            };
            busy();
            let now = Instant::now();
            if let Some(input) = input {
                self.handle(input, now);
            }
            self.tick(now);
            idle();
        }
    }

    fn next_deadline(&self) -> Option<Instant> {
        self.pending
            .values()
            .map(|p| p.deadline)
            .chain(self.idle_at)
            .min()
    }

    // ---- the one start and the one stop (G058) ---------------------------

    /// The only place a camera is started. `active` goes true here.
    fn camera_on(&mut self, job: Job) {
        self.active = true;
        self.idle_at = None;
        match job {
            Job::View {
                generation,
                camera,
                size,
            } => self.source.start_view(generation, &camera, size),
            Job::Still {
                ticket,
                camera,
                size,
            } => {
                if self.hold.is_none() {
                    self.hold = (self.env.inhibit)();
                }
                self.source.still(ticket, &camera, size);
            }
        }
        self.publish();
    }

    /// The only place a camera is stopped. `active` goes false here.
    fn camera_off(&mut self) {
        self.source.stop_view();
        self.active = false;
        self.idle_at = None;
        self.hold = None;
        self.publish();
    }

    // ---- inputs -----------------------------------------------------------

    pub fn handle(&mut self, input: Input, now: Instant) {
        match input {
            Input::Join { reply } => {
                let room = self.clients < MAX_CLIENTS;
                if room {
                    self.clients += 1;
                }
                let _ = reply.send(room);
            }
            Input::Leave => self.clients = self.clients.saturating_sub(1),
            Input::Photos { request, reply } => self.photos(request, reply, now),
            Input::Claim { sink } => self.claim(sink, now),
            Input::Returned { claim, slot } => {
                let Some(v) = self.viewer.as_mut().filter(|v| v.claim == claim) else {
                    return;
                };
                match v.live {
                    Some(Mode::Copy) => v.sink.push_free(slot),
                    Some(Mode::ZeroCopy) => self.source.give_back(slot),
                    None => {}
                }
            }
            Input::ViewerGone { claim } => {
                if self.viewer.as_ref().is_some_and(|v| v.claim == claim) {
                    self.end_viewer(now);
                }
            }
            Input::Intent(intent) => {
                // an intent has no reply: the photo is stored, and announced
                // when asked to be, which is what makes it useful to a script
                self.capture(
                    None,
                    None,
                    None,
                    None,
                    85,
                    true,
                    false,
                    intent.announce,
                    now,
                );
            }
            Input::Settings { enabled } => self.settings(enabled, now),
            Input::Source(event) => self.source_event(event, now),
        }
        self.publish();
    }

    fn settings(&mut self, enabled: bool, now: Instant) {
        if enabled == self.enabled {
            return;
        }
        self.enabled = enabled;
        if !enabled {
            self.viewer = None;
            let tickets: Vec<u64> = self.pending.keys().copied().collect();
            for t in tickets {
                self.finish(t, Err(Refusal::Disabled));
            }
            self.camera_off();
        }
        let _ = now;
    }

    fn photos(&mut self, request: Request, reply: Reply, now: Instant) {
        let send = |r: Response| {
            let _ = reply.send(Done {
                response: r,
                jpeg: None,
            });
        };
        match request {
            Request::List { id } => {
                if !self.enabled {
                    return send(Response::refused(id, Refusal::Disabled));
                }
                send(Response::cameras(id, self.cameras.clone()));
            }
            Request::Select { id, camera } => {
                if !self.enabled {
                    return send(Response::refused(id, Refusal::Disabled));
                }
                if self.viewer.is_some() {
                    return send(Response::refused(id, Refusal::Busy));
                }
                if !self.cameras.iter().any(|c| c.id == camera) {
                    return send(Response::refused(id, Refusal::NoCamera));
                }
                self.selected = Some(camera);
                send(Response::done(id));
            }
            Request::Capture {
                id,
                camera,
                width,
                quality,
                keep,
                fd,
            } => self.capture(
                Some(reply),
                Some(id),
                camera,
                width,
                quality,
                keep,
                fd,
                false,
                now,
            ),
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn capture(
        &mut self,
        reply: Option<Reply>,
        id: Option<u64>,
        camera: Option<String>,
        width: Option<u32>,
        quality: u8,
        keep: bool,
        want_fd: bool,
        announce: bool,
        now: Instant,
    ) {
        let refuse = |why: Refusal| {
            if let Some(reply) = &reply {
                let _ = reply.send(Done {
                    response: Response::refused(id, why),
                    jpeg: None,
                });
            } else {
                (self.env.log)(&format!("capture refused: {}", why.as_str()));
            }
        };
        if !self.enabled {
            return refuse(Refusal::Disabled);
        }
        // one capture in flight per client is the client thread's own
        // serialisation; a request that would exceed what camerad can hold
        // is refused here
        if self.pending.len() >= MAX_CLIENTS {
            return refuse(Refusal::Busy);
        }
        if keep {
            if let Err(e) = self.env.folder.can_keep() {
                return refuse(match e {
                    SaveError::FolderFull => Refusal::FolderFull,
                    SaveError::NoRoom => Refusal::NoRoom,
                    SaveError::Failed(why) => {
                        (self.env.log)(&format!("photo folder: {why}"));
                        Refusal::Failed
                    }
                });
            }
        }
        let chosen = camera
            .as_ref()
            .or(self.selected.as_ref())
            .and_then(|id| self.cameras.iter().find(|c| &c.id == id))
            .or(self.cameras.first())
            .cloned();
        let Some(cam) = chosen else {
            return refuse(Refusal::NoCamera);
        };
        let Some(size) = still_size(cam.max, width) else {
            return refuse(Refusal::NoCamera);
        };
        self.tickets += 1;
        let ticket = self.tickets;
        self.pending.insert(
            ticket,
            Pending {
                reply,
                id,
                keep,
                want_fd,
                quality: quality.clamp(1, 100),
                announce,
                deadline: now + STILL_TIMEOUT,
            },
        );
        self.camera_on(Job::Still {
            ticket,
            camera: cam.id,
            size,
        });
    }

    fn claim(&mut self, sink: Box<dyn FrameSink>, now: Instant) {
        if !self.enabled {
            return sink.refuse(Refusal::Disabled);
        }
        if self.viewer.is_some() {
            return sink.refuse(Refusal::Busy);
        }
        let Some(cam) = self
            .selected
            .as_ref()
            .and_then(|id| self.cameras.iter().find(|c| &c.id == id))
            .or(self.cameras.first())
            .cloned()
        else {
            return sink.refuse(Refusal::NoCamera);
        };
        self.claims += 1;
        self.generation += 1;
        self.failed = false;
        let size = if self.env.small_display {
            VIEWFINDER_SMALL
        } else {
            VIEWFINDER
        };
        self.viewer = Some(Viewer {
            claim: self.claims,
            sink,
            camera: cam.id.clone(),
            generation: self.generation,
            live: None,
        });
        let _ = now;
        self.camera_on(Job::View {
            generation: self.generation,
            camera: cam.id,
            size,
        });
    }

    fn end_viewer(&mut self, now: Instant) {
        // dropping the sink closes the consumer's stream
        self.viewer = None;
        self.arm_idle(now);
    }

    fn arm_idle(&mut self, now: Instant) {
        if self.active && self.viewer.is_none() && self.pending.is_empty() {
            self.idle_at = Some(now + IDLE_STOP);
        }
    }

    fn source_event(&mut self, event: SourceEvent, now: Instant) {
        match event {
            SourceEvent::Cameras(list) => {
                self.cameras = list;
                if self
                    .selected
                    .as_ref()
                    .is_some_and(|s| !self.cameras.iter().any(|c| &c.id == s))
                {
                    self.selected = None;
                }
                let gone = self
                    .viewer
                    .as_ref()
                    .is_some_and(|v| !self.cameras.iter().any(|c| c.id == v.camera));
                if gone {
                    self.end_viewer(now);
                }
            }
            SourceEvent::Started { generation, view } => {
                self.started(generation, view, now)
            }
            SourceEvent::StartFailed { generation, why } => {
                if self
                    .viewer
                    .as_ref()
                    .is_some_and(|v| v.generation == generation)
                {
                    (self.env.log)(&format!("start failed: {why}"));
                    if let Some(v) = self.viewer.take() {
                        v.sink.refuse(Refusal::Failed);
                    }
                    self.failed = true;
                    self.camera_off();
                }
            }
            SourceEvent::Frame {
                generation,
                slot,
                raw,
            } => self.frame(generation, slot, raw, now),
            SourceEvent::Lost { generation } => {
                if self
                    .viewer
                    .as_ref()
                    .is_some_and(|v| v.generation == generation)
                {
                    (self.env.log)("the camera went away under a running view");
                    self.viewer = None;
                    if self.pending.is_empty() {
                        self.camera_off();
                    }
                }
            }
            SourceEvent::Still { ticket, result } => {
                let outcome = match result {
                    Ok(raw) => self.encode(ticket, &raw),
                    Err(why) => {
                        (self.env.log)(&format!("still: {why}"));
                        Err(Refusal::Failed)
                    }
                };
                self.finish(ticket, outcome);
                self.arm_idle(now);
            }
        }
    }

    fn started(&mut self, generation: u64, view: View, now: Instant) {
        let Some(v) = self.viewer.as_mut().filter(|v| v.generation == generation) else {
            return;
        };
        let format = Format {
            width: view.width,
            height: view.height,
            stride: view.stride,
        };
        let size = u64::from(view.stride) * u64::from(view.height);
        let notify = Notify {
            claim: v.claim,
            tx: self.tx.clone(),
        };
        #[cfg(unix)]
        let offered = match view.zero_copy {
            Some(fds) => v
                .sink
                .offer_dmabufs(fds, size, format, notify)
                .map(|()| Mode::ZeroCopy),
            None => v
                .sink
                .offer_copy(QUEUE_BUFFERS, size, format, notify)
                .map(|()| Mode::Copy),
        };
        #[cfg(not(unix))]
        let offered = v
            .sink
            .offer_copy(QUEUE_BUFFERS, size, format, notify)
            .map(|()| Mode::Copy);
        match offered {
            Ok(mode) => v.live = Some(mode),
            Err(why) => {
                (self.env.log)(&format!("the frames offer failed: {why}"));
                self.failed = true;
                self.end_viewer(now);
            }
        }
    }

    fn frame(
        &mut self,
        generation: u64,
        slot: u32,
        raw: Option<crate::types::Raw>,
        now: Instant,
    ) {
        let Some(v) = self.viewer.as_mut().filter(|v| v.generation == generation) else {
            return;
        };
        let sent = match (v.live, raw) {
            (Some(Mode::ZeroCopy), None) => v.sink.queue(slot, 0),
            (Some(Mode::Copy), Some(raw)) => match v.sink.take_free() {
                // no free buffer: the frame is dropped, the sequence says so
                None => Ok(()),
                Some(free) => match convert::to_xrgb(&raw) {
                    Ok(pixels) => v
                        .sink
                        .write_slot(free, &pixels)
                        .and_then(|()| v.sink.queue(free, pixels.len() as u64)),
                    Err(e) => {
                        (self.env.log)(&format!("frame dropped: {e}"));
                        v.sink.push_free(free);
                        Ok(())
                    }
                },
            },
            _ => Ok(()),
        };
        if let Err(why) = sent {
            (self.env.log)(&format!("the frames consumer is gone: {why}"));
            self.end_viewer(now);
        }
    }

    /// The JPEG for a finished still, within the bounds.
    fn encode(
        &mut self,
        ticket: u64,
        raw: &crate::types::Raw,
    ) -> Result<Encoded, Refusal> {
        let quality = self.pending.get(&ticket).map_or(85, |p| p.quality);
        // a source must not hand over more than the bound allows (G059)
        if raw.area() > MAX_PIXELS && raw.pixels != Pixels::Mjpeg {
            return Err(Refusal::TooLarge);
        }
        let (bytes, width, height) = jpeg::still(raw, quality).map_err(|e| {
            (self.env.log)(&format!("encoding: {e}"));
            Refusal::Failed
        })?;
        if bytes.len() > MAX_JPEG_BYTES {
            return Err(Refusal::TooLarge);
        }
        Ok(Encoded {
            bytes,
            width,
            height,
        })
    }

    /// Answer a capture: store it if asked, announce it if asked, hand the
    /// bytes to the client if it wants them.
    fn finish(&mut self, ticket: u64, outcome: Result<Encoded, Refusal>) {
        let Some(p) = self.pending.remove(&ticket) else {
            return;
        };
        if self.pending.is_empty() {
            self.hold = None;
        }
        let result = outcome.and_then(|enc| {
            let path = if p.keep {
                match self.env.folder.save(&enc.bytes) {
                    Ok(name) => Some(name),
                    Err(SaveError::FolderFull) => return Err(Refusal::FolderFull),
                    Err(SaveError::NoRoom) => return Err(Refusal::NoRoom),
                    Err(SaveError::Failed(why)) => {
                        (self.env.log)(&format!("saving: {why}"));
                        return Err(Refusal::Failed);
                    }
                }
            } else {
                None
            };
            Ok((enc, path))
        });
        match result {
            Ok((enc, path)) => {
                if let (true, Some(name)) = (p.announce, &path) {
                    (self.env.announce)(name);
                }
                if let Some(reply) = p.reply {
                    let _ = reply.send(Done {
                        response: Response::photo(
                            p.id.unwrap_or(0),
                            enc.bytes.len(),
                            enc.width,
                            enc.height,
                            path,
                        ),
                        jpeg: p.want_fd.then_some(enc.bytes),
                    });
                }
            }
            Err(why) => {
                if let Some(reply) = p.reply {
                    let _ = reply.send(Done {
                        response: Response::refused(p.id, why),
                        jpeg: None,
                    });
                } else {
                    (self.env.log)(&format!("capture failed: {}", why.as_str()));
                }
            }
        }
    }

    /// Time passes: a capture that never came back is answered `failed`,
    /// and a camera nobody has used for IDLE_STOP is stopped.
    pub fn tick(&mut self, now: Instant) {
        let overdue: Vec<u64> = self
            .pending
            .iter()
            .filter(|(_, p)| p.deadline <= now)
            .map(|(t, _)| *t)
            .collect();
        for t in overdue {
            (self.env.log)("a capture timed out");
            self.finish(t, Err(Refusal::Failed));
            self.arm_idle(now);
        }
        if self.idle_at.is_some_and(|at| at <= now)
            && self.viewer.is_none()
            && self.pending.is_empty()
        {
            self.camera_off();
        }
        self.publish();
    }

    fn publish(&mut self) {
        let progress = if self.failed {
            Progress::Failed
        } else if self.viewer.as_ref().is_some_and(|v| v.live.is_none()) {
            Progress::Starting
        } else {
            Progress::Idle
        };
        let state = State {
            enabled: self.enabled,
            cameras: self.cameras.clone(),
            active: self.active,
            clients: u32::from(self.viewer.is_some())
                + u32::try_from(self.pending.len()).unwrap_or(u32::MAX),
            reason: state::reason(&self.env.conf, &self.cameras, self.enabled, progress),
        };
        if self.written.as_ref() == Some(&state) {
            return;
        }
        // CON-08 (review 2026-10-17): a failed write is RETRIED on every
        // change and reported — latching "written" on failure left the
        // camera indicator dark until the next unrelated change
        match state::write(&self.env.state_dir, &state) {
            Ok(()) => self.written = Some(state),
            Err(e) => {
                (self.env.log)(&format!("state.json: {e}; retrying on the next change"));
            }
        }
    }
}

struct Encoded {
    bytes: Vec<u8>,
    width: u32,
    height: u32,
}

enum Job {
    View {
        generation: u64,
        camera: String,
        size: (u32, u32),
    },
    Still {
        ticket: u64,
        camera: String,
        size: (u32, u32),
    },
}

#[cfg(test)]
pub(crate) mod tests;
