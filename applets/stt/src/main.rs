// stt's process: listen for sys.stt.listen, answer it at once (a told
// handler has 100 ms), then record (saying sys.stt.listening when the
// first frame arrives), detect, transcribe and send sys.stt.heard. One clip at a time; an ask while one is in progress is
// answered and joins it (the one answer goes to whoever listens).

use std::io::Read;
use std::path::Path;
use std::process::{Command, ExitCode, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use stt::{has_capture, heard, samples, transcribe, Step, Vad, Why, FRAME, RATE};
use vrx::ipc::{answer, intent_send, Delivery, Listener};
use vrx::service::{notify, Liveness};

const SOCKET: &str = "/run/vrx-ml/stt.sock";

/// Record until the detector decides; the outcome sys.stt.heard carries.
/// [started] runs once, when the microphone's first frame arrives.
fn listen_once(started: impl FnOnce()) -> Result<String, Why> {
    let pcm = std::fs::read_to_string("/proc/asound/pcm").unwrap_or_default();
    if !has_capture(&pcm) {
        return Err(Why::NoMicrophone);
    }
    let rate = RATE.to_string();
    let mut rec = Command::new("arecord")
        .args(["-q", "-t", "raw", "-f", "S16_LE", "-c", "1", "-r", &rate])
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .map_err(|e| {
            log(&format!("arecord: {e}"));
            Why::NoMicrophone
        })?;
    let Some(mut out) = rec.stdout.take() else {
        return Err(Why::NoMicrophone);
    };
    let mut vad = Vad::new();
    let mut frame = vec![0u8; FRAME * 2];
    let mut started = Some(started);
    let outcome = loop {
        if out.read_exact(&mut frame).is_err() {
            break Err(Why::CaptureFailed);
        }
        if let Some(say) = started.take() {
            say();
        }
        match vad.frame(&samples(&frame)) {
            Step::More => {}
            Step::NothingHeard => break Ok(String::new()),
            Step::Heard(clip) => {
                // CON-07 (review 2026-10-17): the microphone closes
                // BEFORE inference — arecord stayed alive through
                // transcribe, holding the capture device (and the
                // camera's audio path, on boards that share one)
                drop(out);
                let _ = rec.kill();
                let _ = rec.wait();
                break transcribe(Path::new(SOCKET), &clip).map_err(|e| {
                    log(&format!("whisper-server: {e:?}"));
                    Why::TranscribeFailed
                })
            }
        }
    };
    let _ = rec.kill();
    let _ = rec.wait();
    outcome
}

fn log(line: &str) {
    // KRN-04 (review 2026-10-17): the SDK's tracing, with the
    // subscriber main installs — one logging mechanism per process
    tracing::info!("{line}");
}

fn main() -> ExitCode {
    tracing_subscriber::fmt().with_target(false).init();
    let liveness = Liveness::new();
    liveness.spawn_watchdog();
    let mut listener = match Listener::start() {
        Ok(l) => l,
        Err(err) => {
            log(&format!("cannot listen: {err}"));
            return ExitCode::FAILURE;
        }
    };
    notify("READY=1");
    let busy = Arc::new(AtomicBool::new(false));
    // blocked here is idle: the watchdog keeps pinging
    while let Some(delivery) = listener.next_delivery() {
        let Delivery::Intent { id, name, .. } = delivery else {
            continue;
        };
        if name != "sys.stt.listen" {
            if let Some(id) = id {
                let _ = answer(id, false);
            }
            continue;
        }
        if let Some(id) = id {
            if let Err(err) = answer(id, true) {
                log(&format!("answer: {err}"));
            }
        }
        if busy.swap(true, Ordering::SeqCst) {
            continue;
        }
        let busy = Arc::clone(&busy);
        std::thread::spawn(move || {
            // CON-07 (review 2026-10-17): a guard, not a trailing store —
            // a hang unwound by the watchdog or a panic released nothing
            // and stt answered "busy" for the rest of the process's life
            struct Gate(Arc<AtomicBool>);
            impl Drop for Gate {
                fn drop(&mut self) {
                    self.0.store(false, Ordering::SeqCst);
                }
            }
            let _gate = Gate(busy);
            let outcome = listen_once(|| {
                if let Err(err) =
                    intent_send("sys.stt.listening", serde_json::Value::Null)
                {
                    log(&format!("sys.stt.listening: {err}"));
                }
            });
            if let Err(err) = intent_send("sys.stt.heard", heard(outcome)) {
                log(&format!("sys.stt.heard: {err}"));
            }
        });
    }
    // vrxhost went away: systemd starts stt again with it
    log("vrxhost hung up");
    ExitCode::FAILURE
}
