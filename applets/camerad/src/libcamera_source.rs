// The one camera backend (plan 0018 D2, D3): libcamera, for CSI and for USB.
// Its pipeline handlers do the matching (uvcvideo for webcams, rpi/vc4 and
// rpi/pisp for the Pi, simple for K3, virtual for the qemu rung); this file
// is the translation from camerad's Source commands to libcamera's API and
// from its completed requests to camerad's events. It is the only file that
// names libcamera (G056), and a break in the Rust binding is confined to it.
//
// One thread owns the CameraManager and the running camera, so no libcamera
// object ever crosses threads; commands, hotplug and completed requests all
// arrive as messages on one channel.
//
// v1 takes every viewfinder frame through the copy path (the engine converts
// into the queue's memfds, the plugin uploads or imports): zero-copy CSI
// dmabufs wait for the bench rows on the v3d import and on re-importing a
// buffer across the reconfigure a still needs (plan 0018 Hardware claims).

use std::sync::mpsc::{channel, Receiver, Sender};
use std::time::Duration;

use libcamera::{
    camera::{ActiveCamera, CameraConfiguration},
    camera_manager::CameraManager,
    framebuffer::AsFrameBuffer,
    framebuffer_allocator::{FrameBuffer, FrameBufferAllocator},
    framebuffer_map::MemoryMappedFrameBuffer,
    geometry::Size,
    pixel_format::PixelFormat,
    properties,
    request::{Request, RequestStatus, ReuseFlag},
    stream::{Stream, StreamRole},
};

use crate::bounds::STILL_TIMEOUT;
use crate::engine::Input;
use crate::source::{Source, SourceEvent, View};
use crate::types::{kind_of, CameraInfo, Location, Pixels, Raw};

/// Frames the sensor makes before a still is taken, so exposure and white
/// balance have settled (libcamera's AGC and AWB run on the first frames).
const SETTLE_FRAMES: usize = 4;
/// Buffers a stream is given.
const STREAM_BUFFERS: u32 = 4;

fn fourcc(code: &[u8; 4]) -> u32 {
    u32::from_le_bytes(*code)
}

fn pixels_of(format: PixelFormat) -> Option<Pixels> {
    match format.fourcc() {
        f if f == fourcc(b"XR24") => Some(Pixels::Xrgb8888),
        f if f == fourcc(b"YUYV") => Some(Pixels::Yuyv),
        f if f == fourcc(b"NV12") => Some(Pixels::Nv12),
        f if f == fourcc(b"YU12") => Some(Pixels::Yuv420),
        f if f == fourcc(b"MJPG") => Some(Pixels::Mjpeg),
        _ => None,
    }
}

fn format_of(pixels: Pixels) -> PixelFormat {
    let code = match pixels {
        Pixels::Xrgb8888 => b"XR24",
        Pixels::Yuyv => b"YUYV",
        Pixels::Nv12 => b"NV12",
        Pixels::Yuv420 => b"YU12",
        Pixels::Mjpeg => b"MJPG",
    };
    PixelFormat::new(fourcc(code), 0)
}

enum Cmd {
    StartView {
        generation: u64,
        camera: String,
        size: (u32, u32),
    },
    StopView,
    Still {
        ticket: u64,
        camera: String,
        size: (u32, u32),
    },
}

enum Msg {
    Cmd(Cmd),
    Hotplug,
    Completed { generation: u64, request: Request },
}

/// The Source the engine drives.
pub struct LibcameraSource {
    tx: Sender<Msg>,
}

impl LibcameraSource {
    /// Start libcamera's thread. Events go to `events` as they happen; the
    /// camera list is sent first. Fails when libcamera cannot start.
    pub fn spawn(events: Sender<Input>) -> std::io::Result<Self> {
        let (tx, rx) = channel();
        let (ready_tx, ready_rx) = channel();
        let inner = tx.clone();
        std::thread::Builder::new()
            .name("libcamera".into())
            .spawn(move || run(&events, &inner, &rx, &ready_tx))?;
        ready_rx
            .recv()
            .map_err(|_| std::io::Error::other("the libcamera thread ended"))??;
        Ok(Self { tx })
    }

    fn send(&self, cmd: Cmd) {
        let _ = self.tx.send(Msg::Cmd(cmd));
    }
}

impl Source for LibcameraSource {
    fn start_view(&mut self, generation: u64, camera: &str, size: (u32, u32)) {
        self.send(Cmd::StartView {
            generation,
            camera: camera.to_owned(),
            size,
        });
    }

    fn stop_view(&mut self) {
        self.send(Cmd::StopView);
    }

    fn give_back(&mut self, _slot: u32) {
        // copy views only: a frame's buffer went back to the camera when it
        // was copied out
    }

    fn still(&mut self, ticket: u64, camera: &str, size: (u32, u32)) {
        self.send(Cmd::Still {
            ticket,
            camera: camera.to_owned(),
            size,
        });
    }
}

/// A running viewfinder. Fields drop in order: the allocator before the
/// camera it allocated from, and `Drop` stops the camera first.
struct Session<'d> {
    _alloc: FrameBufferAllocator,
    camera: ActiveCamera<'d>,
    stream: Stream,
    generation: u64,
    id: String,
    size: (u32, u32),
    pixels: Pixels,
    width: u32,
    height: u32,
    stride: u32,
}

impl Drop for Session<'_> {
    fn drop(&mut self) {
        let _ = self.camera.stop();
    }
}

fn run(
    events: &Sender<Input>,
    inner: &Sender<Msg>,
    rx: &Receiver<Msg>,
    ready: &Sender<std::io::Result<()>>,
) {
    let mut manager = match CameraManager::new() {
        Ok(m) => m,
        Err(e) => {
            let _ = ready.send(Err(e));
            return;
        }
    };
    let hotplug = manager.subscribe_hotplug_events();
    let forward = inner.clone();
    std::thread::spawn(move || {
        for _ in hotplug {
            if forward.send(Msg::Hotplug).is_err() {
                break;
            }
        }
    });
    let _ = ready.send(Ok(()));
    let emit = |event: SourceEvent| {
        let _ = events.send(Input::Source(event));
    };
    emit(SourceEvent::Cameras(list(&manager)));
    let mut view: Option<Session<'_>> = None;
    while let Ok(msg) = rx.recv() {
        match msg {
            Msg::Hotplug => {
                let now = list(&manager);
                let gone = view
                    .as_ref()
                    .filter(|s| !now.iter().any(|c| c.id == s.id))
                    .map(|s| s.generation);
                emit(SourceEvent::Cameras(now));
                if let Some(generation) = gone {
                    view = None;
                    emit(SourceEvent::Lost { generation });
                }
            }
            Msg::Cmd(Cmd::StopView) => view = None,
            Msg::Cmd(Cmd::StartView {
                generation,
                camera,
                size,
            }) => {
                view = None;
                match start_view(&manager, inner, generation, &camera, size) {
                    Ok(session) => {
                        emit(SourceEvent::Started {
                            generation,
                            view: View {
                                width: session.width,
                                height: session.height,
                                // the engine converts into XRGB8888 rows
                                stride: session.width * 4,
                                zero_copy: None,
                            },
                        });
                        view = Some(session);
                    }
                    Err(why) => emit(SourceEvent::StartFailed { generation, why }),
                }
            }
            Msg::Cmd(Cmd::Still {
                ticket,
                camera,
                size,
            }) => {
                // a still reconfigures the camera: pause a running view on
                // it, take the shot, and resume under the same generation
                let resume = view.take().map(|s| (s.generation, s.id.clone(), s.size));
                let result = capture_still(&manager, &camera, size);
                emit(SourceEvent::Still { ticket, result });
                if let Some((generation, id, size)) = resume {
                    match start_view(&manager, inner, generation, &id, size) {
                        Ok(session) => view = Some(session),
                        Err(_) => emit(SourceEvent::Lost { generation }),
                    }
                }
            }
            Msg::Completed {
                generation,
                mut request,
            } => {
                let Some(session) = view.as_mut().filter(|s| s.generation == generation)
                else {
                    continue;
                };
                if request.status() != RequestStatus::Complete {
                    continue;
                }
                let raw = frame_of(&request, &session.stream, session);
                request.reuse(ReuseFlag::REUSE_BUFFERS);
                if session.camera.queue_request(request).is_err() {
                    continue;
                }
                if let Some(raw) = raw {
                    emit(SourceEvent::Frame {
                        generation,
                        slot: 0,
                        raw: Some(raw),
                    });
                }
            }
        }
    }
}

/// Every camera libcamera has now, as camerad lists them.
fn list(manager: &CameraManager) -> Vec<CameraInfo> {
    let cameras = manager.cameras();
    cameras
        .iter()
        .map(|cam| {
            let id = cam.id().to_string();
            let name = cam
                .properties()
                .get::<properties::Model>()
                .map_or_else(|_| id.clone(), |m| (*m).clone());
            let location = match cam.properties().get::<properties::Location>() {
                Ok(properties::Location::CameraFront) => Location::Front,
                Ok(properties::Location::CameraBack) => Location::Back,
                _ => Location::External,
            };
            // the largest still the camera offers: its StillCapture default
            let max = cam
                .generate_configuration(&[StreamRole::StillCapture])
                .and_then(|c| c.get(0).map(|s| s.get_size()))
                .map_or([0, 0], |s| [s.width, s.height]);
            CameraInfo {
                kind: kind_of(&id),
                id,
                name,
                location,
                max,
            }
        })
        .collect()
}

/// Ask for `size` in the first of `prefer` the pipeline keeps as asked; if it
/// keeps none, take what it adjusted the last ask to when camerad handles
/// that format.
fn negotiate(
    cfgs: &mut CameraConfiguration,
    size: (u32, u32),
    prefer: &[Pixels],
) -> Result<(Pixels, u32, u32, u32), String> {
    let mut last = None;
    for pixels in prefer {
        let Some(mut cfg) = cfgs.get_mut(0) else {
            return Err("the camera offers no stream".into());
        };
        cfg.set_pixel_format(format_of(*pixels));
        cfg.set_size(Size::new(size.0, size.1));
        let status = cfgs.validate();
        if status.is_invalid() {
            continue;
        }
        let cfg = cfgs.get(0).ok_or("the camera offers no stream")?;
        let got = pixels_of(cfg.get_pixel_format());
        let result = got.map(|p| {
            let s = cfg.get_size();
            (p, s.width, s.height, cfg.get_stride())
        });
        if got == Some(*pixels) {
            return result.ok_or_else(|| "unreachable".to_owned());
        }
        last = result.or(last);
    }
    last.ok_or_else(|| "the camera has no format camerad handles".to_owned())
}

/// The planes of a completed request's buffer as one frame of pixels.
fn frame_of(request: &Request, stream: &Stream, s: &Session<'_>) -> Option<Raw> {
    raw_from(request, stream, s.pixels, s.width, s.height, s.stride)
}

fn raw_from(
    request: &Request,
    stream: &Stream,
    pixels: Pixels,
    width: u32,
    height: u32,
    stride: u32,
) -> Option<Raw> {
    let buffer: &MemoryMappedFrameBuffer<FrameBuffer> = request.buffer(stream)?;
    let planes = buffer.data();
    let mut data = Vec::new();
    if pixels == Pixels::Mjpeg {
        let used = buffer
            .metadata()?
            .planes()
            .get(0)
            .map_or(0, |p| p.bytes_used as usize);
        data.extend_from_slice(planes.first()?.get(..used)?);
    } else {
        for plane in &planes {
            data.extend_from_slice(plane);
        }
    }
    Some(Raw {
        pixels,
        width,
        height,
        stride,
        data,
    })
}

/// Configure, allocate, queue and start `camera` for `role`.
struct Started<'d> {
    alloc: FrameBufferAllocator,
    camera: ActiveCamera<'d>,
    stream: Stream,
    pixels: Pixels,
    width: u32,
    height: u32,
    stride: u32,
}

fn begin<'d>(
    manager: &CameraManager,
    id: &str,
    role: StreamRole,
    size: (u32, u32),
    prefer: &[Pixels],
    completed: impl FnOnce(&mut ActiveCamera<'d>),
) -> Result<Started<'d>, String> {
    let cam = manager.get(id).ok_or("the camera is gone")?;
    let mut camera = cam.acquire().map_err(|e| format!("acquire: {e}"))?;
    let mut cfgs = camera
        .generate_configuration(&[role])
        .ok_or("no configuration for this role")?;
    let (pixels, width, height, stride) = negotiate(&mut cfgs, size, prefer)?;
    if let Some(mut c) = cfgs.get_mut(0) {
        c.set_buffer_count(STREAM_BUFFERS);
    }
    camera
        .configure(&mut cfgs)
        .map_err(|e| format!("configure: {e}"))?;
    let stream = cfgs
        .get(0)
        .and_then(|c| c.stream())
        .ok_or("no stream after configure")?;
    let mut alloc = FrameBufferAllocator::new(&camera);
    let buffers = alloc.alloc(&stream).map_err(|e| format!("buffers: {e}"))?;
    let mut requests = Vec::new();
    for (i, buffer) in buffers.into_iter().enumerate() {
        let mapped =
            MemoryMappedFrameBuffer::new(buffer).map_err(|e| format!("map: {e}"))?;
        let mut request = camera.create_request(Some(i as u64)).ok_or("no request")?;
        request
            .add_buffer(&stream, mapped)
            .map_err(|e| format!("add buffer: {e}"))?;
        requests.push(request);
    }
    completed(&mut camera);
    camera.start(None).map_err(|e| format!("start: {e}"))?;
    for request in requests {
        camera
            .queue_request(request)
            .map_err(|(_, e)| format!("queue: {e}"))?;
    }
    Ok(Started {
        alloc,
        camera,
        stream,
        pixels,
        width,
        height,
        stride,
    })
}

fn start_view<'d>(
    manager: &CameraManager,
    inner: &Sender<Msg>,
    generation: u64,
    id: &str,
    size: (u32, u32),
) -> Result<Session<'d>, String> {
    let forward = inner.clone();
    let started = begin(
        manager,
        id,
        StreamRole::ViewFinder,
        size,
        // what the Pi's ISP makes; a webcam adjusts to YUYV or MJPEG
        &[Pixels::Xrgb8888, Pixels::Yuyv, Pixels::Nv12],
        move |camera| {
            let completed = camera.subscribe_request_completed();
            std::thread::spawn(move || {
                for request in completed {
                    if forward
                        .send(Msg::Completed {
                            generation,
                            request,
                        })
                        .is_err()
                    {
                        break;
                    }
                }
            });
        },
    )?;
    Ok(Session {
        _alloc: started.alloc,
        camera: started.camera,
        stream: started.stream,
        generation,
        id: id.to_owned(),
        size,
        pixels: started.pixels,
        width: started.width,
        height: started.height,
        stride: started.stride,
    })
}

/// One still: configure for it alone, let the exposure settle, take the next
/// frame, release the camera. A webcam's MJPEG frame is preferred (stored as
/// it is, no re-encode); the Pi's ISP gives XRGB8888 or planar YUV.
fn capture_still(
    manager: &CameraManager,
    id: &str,
    size: (u32, u32),
) -> Result<Raw, String> {
    let mut completed = None;
    let started = begin(
        manager,
        id,
        StreamRole::StillCapture,
        size,
        &[
            Pixels::Mjpeg,
            Pixels::Xrgb8888,
            Pixels::Yuv420,
            Pixels::Yuyv,
            Pixels::Nv12,
        ],
        |camera| completed = Some(camera.subscribe_request_completed()),
    )?;
    let rx = completed.ok_or("no completion channel")?;
    let mut taken = 0;
    let outcome = loop {
        let mut request = rx
            .recv_timeout(STILL_TIMEOUT.min(Duration::from_secs(8)))
            .map_err(|_| "the camera produced no frame".to_owned())?;
        if request.status() != RequestStatus::Complete {
            continue;
        }
        taken += 1;
        if taken > SETTLE_FRAMES {
            break raw_from(
                &request,
                &started.stream,
                started.pixels,
                started.width,
                started.height,
                started.stride,
            )
            .ok_or_else(|| "the frame had no pixels".to_owned());
        }
        request.reuse(ReuseFlag::REUSE_BUFFERS);
        started
            .camera
            .queue_request(request)
            .map_err(|(_, e)| format!("requeue: {e}"))?;
    };
    let mut camera = started.camera;
    let _ = camera.stop();
    drop(started.alloc);
    outcome
}
