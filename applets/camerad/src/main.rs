// camerad's process (plan 0018 D1): a resident service with no screen.
// libcamera runs on its own thread and the engine on this one; a listener
// thread turns vrxhost's deliveries into engine inputs (the intent, the two
// channels) and a settings thread turns the Camera switch into one.

#[cfg(not(all(target_os = "linux", feature = "libcamera")))]
fn main() -> std::process::ExitCode {
    camerad::log(
        "this build has no camera backend (needs Linux and the `libcamera` feature)",
    );
    std::process::ExitCode::FAILURE
}

#[cfg(all(target_os = "linux", feature = "libcamera"))]
fn main() -> std::process::ExitCode {
    service::run()
}

#[cfg(all(target_os = "linux", feature = "libcamera"))]
mod service {
    use std::path::PathBuf;
    use std::process::ExitCode;
    use std::sync::mpsc::{channel, Sender};

    use camerad::bounds;
    use camerad::engine::{Engine, Env, Input};
    use camerad::libcamera_source::LibcameraSource;
    use camerad::linux::{announce, inhibit, serve_photos, QueueSink};
    use camerad::log;
    use camerad::protocol::CaptureIntent;
    use camerad::state::Conf;
    use camerad::store::Folder;
    use vrx::ipc::{answer, Delivery, File, Listener};
    use vrx::service::{notify, Liveness};

    const CONF: &str = "/etc/vrx/camera/camera.conf";
    const SETTINGS: &str = "/etc/vrx/settings/camerad.conf";

    fn env_path(var: &str, default: &str) -> PathBuf {
        std::env::var_os(var).map_or_else(|| PathBuf::from(default), PathBuf::from)
    }

    /// The Settings "Camera" row: `camera_enabled=false` switches it off.
    fn enabled(text: &str) -> bool {
        !text.lines().any(|l| {
            l.split_once('=')
                .is_some_and(|(k, v)| k.trim() == "camera_enabled" && v.trim() == "false")
        })
    }

    /// Under [bounds::SMALL_DISPLAY] pixels on its short side the
    /// viewfinder is 320x240. The framebuffer's size is what the kernel
    /// says about the screen.
    fn small_display() -> bool {
        std::fs::read_to_string("/sys/class/graphics/fb0/virtual_size")
            .ok()
            .and_then(|s| {
                let (w, h) = s.trim().split_once(',')?;
                Some(
                    w.parse::<u32>().ok()?.min(h.parse::<u32>().ok()?)
                        < bounds::SMALL_DISPLAY,
                )
            })
            .unwrap_or(false)
    }

    fn listen(tx: &Sender<Input>) -> Result<(), String> {
        let mut listener = Listener::start().map_err(|e| e.to_string())?;
        let tx = tx.clone();
        std::thread::spawn(move || {
            while let vrx::ipc::NextDelivery::Delivery(delivery) =
                listener.next_delivery()
            {
                match delivery {
                    Delivery::Intent { id, name, payload } => {
                        let ours = name == "sys.camera.capture";
                        if let Some(id) = id {
                            // told: answered at once, the photo made afterwards
                            if let Err(e) = answer(id, ours) {
                                log(&format!("answer: {e}"));
                            }
                        }
                        if ours {
                            // a malformed payload keeps nothing: saving a
                            // photo the caller cannot have asked for is
                            // the wrong side to err on
                            let intent = serde_json::from_value::<CaptureIntent>(payload)
                                .unwrap_or(CaptureIntent {
                                    keep: false,
                                    announce: false,
                                });
                            if tx.send(Input::Intent(intent)).is_err() {
                                return;
                            }
                        }
                    }
                    Delivery::Channel { from, channel } => {
                        let which =
                            channel.name().rsplit('.').next().unwrap_or("").to_owned();
                        match which.as_str() {
                            "photos" => {
                                let tx = tx.clone();
                                std::thread::spawn(move || serve_photos(channel, tx));
                            }
                            "frames" => {
                                let sink = Box::new(QueueSink::new(channel));
                                if tx.send(Input::Claim { sink }).is_err() {
                                    return;
                                }
                            }
                            other => log(&format!(
                                "{from} opened {other:?}, which camerad does not offer"
                            )),
                        }
                    }
                }
            }
            // vrxhost went away: systemd starts camerad again with it
            log("vrxhost hung up");
            std::process::exit(1);
        });
        Ok(())
    }

    pub fn run() -> ExitCode {
        let liveness = Liveness::new();
        liveness.spawn_watchdog();
        let conf = Conf::parse(&std::fs::read_to_string(CONF).unwrap_or_default());
        let (tx, rx) = channel();
        let source = match LibcameraSource::spawn(tx.clone()) {
            Ok(s) => s,
            Err(e) => {
                log(&format!("libcamera cannot start: {e}"));
                return ExitCode::FAILURE;
            }
        };
        let env = Env {
            conf,
            state_dir: env_path("CAMERAD_RUNTIME", "/run/vrx/camera"),
            folder: Folder::new(env_path("VRX_PHOTO_DIR", "/data/photos")),
            small_display: small_display(),
            inhibit: Box::new(inhibit),
            announce: Box::new(announce),
            log,
        };
        let mut engine = Engine::new(env, Box::new(source), tx.clone(), rx);
        // the switch: read now, then on every change (inotify, never a poll)
        let settings = File::watch(SETTINGS);
        let _ = tx.send(Input::Settings {
            enabled: settings.value().is_none_or(enabled),
        });
        let on_change = tx.clone();
        std::thread::spawn(move || {
            let _ = settings.watch_forever(|text| {
                let _ = on_change.send(Input::Settings {
                    enabled: enabled(text),
                });
            });
        });
        if let Err(e) = listen(&tx) {
            log(&format!("cannot listen: {e}"));
            return ExitCode::FAILURE;
        }
        drop(tx);
        notify("READY=1");
        engine.run(|| liveness.busy(), || liveness.idle());
        ExitCode::FAILURE
    }
}
