// stt's decisions, testable on any host: the voice detector, the clip
// as a WAV, the request to whisper-server and its answer.
//
// Linux and whisper.cpp do the work: ALSA's arecord records, the local
// whisper-server transcribes. What stt adds is evrx-rt's voice detector
// (evrx-rt components/applets/stt, docs/48), which decides when a person
// started and stopped speaking.

#![deny(unsafe_code)]
#![cfg_attr(test, allow(clippy::unwrap_used, clippy::expect_used, clippy::panic))]

use std::io::{Read, Write};
use std::path::Path;

/// 16 kHz mono, 16-bit: what arecord records and whisper reads.
pub const RATE: u32 = 16_000;
/// One frame of the detector: 20 ms.
pub const FRAME: usize = (RATE as usize) / 50;
const FRAME_MS: u32 = 20;

/// evrx-rt's detector, its numbers.
pub const CALIBRATE_MS: u32 = 250;
pub const SPEECH_START_MS: u32 = 100;
pub const QUIET_END_MS: u32 = 900;
pub const WAIT_MS: u32 = 4_000;
pub const CAP_MS: u32 = 8_000;

/// Speech is this many times the room's level, and never quieter than
/// [FLOOR] (a silent room would make breathing speech).
const FACTOR: f64 = 3.0;
const FLOOR: f64 = 300.0;
/// A room whose quietest calibration frame is louder than this was no
/// room: the person was already speaking when recording began, and the
/// room is taken to be at [FLOOR].
const ROOM_MAX: f64 = 1_500.0;

/// What the detector says after a frame.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Step {
    /// Keep recording.
    More,
    /// The speech ended (or reached the cap): here it is.
    Heard(Vec<i16>),
    /// Nobody spoke within [WAIT_MS].
    NothingHeard,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Phase {
    Calibrating,
    Waiting,
    Speaking,
}

/// The voice detector: learn the room, wait for speech, keep it until a
/// quiet long enough to be the end.
#[derive(Debug)]
pub struct Vad {
    phase: Phase,
    ms: u32,
    /// The quietest frame of the calibration window.
    quietest: f64,
    /// The calibration window's frames, replayed once the room is known.
    preroll: Vec<Vec<i16>>,
    threshold: f64,
    loud_run: u32,
    quiet_run: u32,
    pending: Vec<i16>,
    clip: Vec<i16>,
}

impl Default for Vad {
    fn default() -> Self {
        Self::new()
    }
}

impl Vad {
    pub fn new() -> Self {
        Self {
            phase: Phase::Calibrating,
            ms: 0,
            quietest: f64::INFINITY,
            preroll: Vec::new(),
            threshold: FLOOR,
            loud_run: 0,
            quiet_run: 0,
            pending: Vec::new(),
            clip: Vec::new(),
        }
    }

    /// Feed one [FRAME] of samples.
    ///
    /// The first [CALIBRATE_MS] learn the room from their quietest frame
    /// and are kept, then replayed as if heard after it: speech that began
    /// while the room was being learnt is detected and starts the clip
    /// (bench, CM4, 2026-10-14: a question spoken 1.2 s after the tap was
    /// lost to a mean that counted it as the room). [WAIT_MS] counts from
    /// the first frame.
    pub fn frame(&mut self, samples: &[i16]) -> Step {
        let level = rms(samples);
        self.ms += FRAME_MS;
        if self.phase != Phase::Calibrating {
            return self.after_calibration(samples, level);
        }
        self.quietest = self.quietest.min(level);
        self.preroll.push(samples.to_vec());
        if self.ms < CALIBRATE_MS {
            return Step::More;
        }
        let room = if self.quietest > ROOM_MAX {
            FLOOR
        } else {
            self.quietest
        };
        self.threshold = (room * FACTOR).max(FLOOR);
        self.phase = Phase::Waiting;
        // replay the window against the room just learnt, keeping time
        self.ms = 0;
        for f in std::mem::take(&mut self.preroll) {
            let l = rms(&f);
            self.ms += FRAME_MS;
            match self.after_calibration(&f, l) {
                Step::More => {}
                done => return done,
            }
        }
        Step::More
    }

    fn after_calibration(&mut self, samples: &[i16], level: f64) -> Step {
        match self.phase {
            Phase::Calibrating => Step::More,
            Phase::Waiting => {
                if level >= self.threshold {
                    self.loud_run += FRAME_MS;
                    self.pending.extend_from_slice(samples);
                    if self.loud_run >= SPEECH_START_MS {
                        // the start of speech is part of the clip
                        self.clip = std::mem::take(&mut self.pending);
                        self.phase = Phase::Speaking;
                        self.ms = self.loud_run;
                    }
                } else {
                    self.loud_run = 0;
                    self.pending.clear();
                }
                if self.phase == Phase::Waiting && self.ms >= WAIT_MS {
                    return Step::NothingHeard;
                }
                Step::More
            }
            Phase::Speaking => {
                self.clip.extend_from_slice(samples);
                if level >= self.threshold {
                    self.quiet_run = 0;
                } else {
                    self.quiet_run += FRAME_MS;
                }
                if self.quiet_run >= QUIET_END_MS || self.ms >= CAP_MS {
                    return Step::Heard(std::mem::take(&mut self.clip));
                }
                Step::More
            }
        }
    }
}

fn rms(samples: &[i16]) -> f64 {
    if samples.is_empty() {
        return 0.0;
    }
    let sum: f64 = samples.iter().map(|&s| f64::from(s) * f64::from(s)).sum();
    (sum / samples.len() as f64).sqrt()
}

/// 16-bit little-endian samples from arecord's raw output.
pub fn samples(bytes: &[u8]) -> Vec<i16> {
    bytes
        .chunks_exact(2)
        .map(|b| i16::from_le_bytes([b[0], b[1]]))
        .collect()
}

/// The clip as a WAV file: what whisper-server's /inference takes.
pub fn wav(samples: &[i16]) -> Vec<u8> {
    let data = u32::try_from(samples.len() * 2).unwrap_or(u32::MAX);
    let mut out = Vec::with_capacity(44 + samples.len() * 2);
    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&(36 + data).to_le_bytes());
    out.extend_from_slice(b"WAVEfmt ");
    out.extend_from_slice(&16u32.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes()); // PCM
    out.extend_from_slice(&1u16.to_le_bytes()); // mono
    out.extend_from_slice(&RATE.to_le_bytes());
    out.extend_from_slice(&(RATE * 2).to_le_bytes());
    out.extend_from_slice(&2u16.to_le_bytes());
    out.extend_from_slice(&16u16.to_le_bytes());
    out.extend_from_slice(b"data");
    out.extend_from_slice(&data.to_le_bytes());
    for s in samples {
        out.extend_from_slice(&s.to_le_bytes());
    }
    out
}

const BOUNDARY: &str = "vrx-stt-7f3a9c";

/// The /inference request: the clip, and JSON back.
pub fn inference_request(clip_wav: &[u8]) -> Vec<u8> {
    let mut body = Vec::new();
    for (name, value) in [("response_format", "json"), ("temperature", "0.0")] {
        body.extend_from_slice(
            format!("--{BOUNDARY}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n")
                .as_bytes(),
        );
    }
    body.extend_from_slice(
        format!(
            "--{BOUNDARY}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"clip.wav\"\r\nContent-Type: audio/wav\r\n\r\n"
        )
        .as_bytes(),
    );
    body.extend_from_slice(clip_wav);
    body.extend_from_slice(format!("\r\n--{BOUNDARY}--\r\n").as_bytes());
    let mut req = format!(
        "POST /inference HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nContent-Type: multipart/form-data; boundary={BOUNDARY}\r\nContent-Length: {}\r\n\r\n",
        body.len()
    )
    .into_bytes();
    req.extend_from_slice(&body);
    req
}

/// Why a clip has no text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Failure {
    /// The server did not answer, or answered with an error.
    Engine(String),
}

/// An HTTP/1.1 response: its status and body (chunked or not).
pub fn response(raw: &[u8]) -> Result<(u16, Vec<u8>), Failure> {
    let head_end = raw
        .windows(4)
        .position(|w| w == b"\r\n\r\n")
        .ok_or_else(|| Failure::Engine("no HTTP header".into()))?;
    let head = String::from_utf8_lossy(&raw[..head_end]);
    let mut lines = head.split("\r\n");
    let status = lines
        .next()
        .and_then(|l| l.split_whitespace().nth(1))
        .and_then(|s| s.parse::<u16>().ok())
        .ok_or_else(|| Failure::Engine("no HTTP status".into()))?;
    let chunked = lines.any(|l| {
        let l = l.to_ascii_lowercase();
        l.starts_with("transfer-encoding:") && l.contains("chunked")
    });
    let body = &raw[head_end + 4..];
    if !chunked {
        return Ok((status, body.to_vec()));
    }
    let mut out = Vec::new();
    let mut rest = body;
    while let Some(eol) = rest.windows(2).position(|w| w == b"\r\n") {
        let size_text = String::from_utf8_lossy(&rest[..eol]);
        let size =
            usize::from_str_radix(size_text.split(';').next().unwrap_or("").trim(), 16)
                .map_err(|_| Failure::Engine("bad chunk".into()))?;
        rest = &rest[eol + 2..];
        if size == 0 || rest.len() < size {
            break;
        }
        out.extend_from_slice(&rest[..size]);
        rest = rest.get(size + 2..).unwrap_or(&[]);
    }
    Ok((status, out))
}

/// The text in whisper-server's JSON answer, without its edges.
pub fn text_of(body: &[u8]) -> Option<String> {
    let v: serde_json::Value = serde_json::from_slice(body).ok()?;
    Some(v.get("text")?.as_str()?.trim().to_owned())
}

/// Send the clip to the whisper-server behind `socket`, get the text.
pub fn transcribe(socket: &Path, clip: &[i16]) -> Result<String, Failure> {
    let mut stream = std::os::unix::net::UnixStream::connect(socket)
        .map_err(|e| Failure::Engine(format!("{}: {e}", socket.display())))?;
    stream
        .write_all(&inference_request(&wav(clip)))
        .map_err(|e| Failure::Engine(e.to_string()))?;
    let mut raw = Vec::new();
    stream
        .read_to_end(&mut raw)
        .map_err(|e| Failure::Engine(e.to_string()))?;
    let (status, body) = response(&raw)?;
    if status != 200 {
        return Err(Failure::Engine(format!("HTTP {status}")));
    }
    text_of(&body).ok_or_else(|| Failure::Engine("no text in the answer".into()))
}

/// Whether the board can hear: a capture device in ALSA's PCM list.
pub fn has_capture(pcm_list: &str) -> bool {
    pcm_list.lines().any(|l| l.contains(": capture "))
}

/// Why there is no text: the ONE vocabulary for sys.stt.heard's error
/// (CON-06, review 2026-10-17 — bare literals in three files drifted).
/// The applet that asked puts each in a person's words.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Why {
    /// The board has no capture device at all.
    NoMicrophone,
    /// Capture failed mid-stream (the microphone went away).
    CaptureFailed,
    /// Recorded and heard nothing.
    NothingHeard,
    /// Whisper refused or crashed on the clip.
    TranscribeFailed,
}

impl Why {
    pub fn as_str(self) -> &'static str {
        match self {
            Why::NoMicrophone => "no-microphone",
            Why::CaptureFailed => "capture-failed",
            Why::NothingHeard => "nothing-heard",
            Why::TranscribeFailed => "transcribe-failed",
        }
    }
}

/// What sys.stt.heard carries: the text, or why there is none.
pub fn heard(outcome: Result<String, Why>) -> serde_json::Value {
    match outcome {
        Ok(text) if text.is_empty() => {
            serde_json::json!({ "error": Why::NothingHeard.as_str() })
        }
        Ok(text) => serde_json::json!({ "text": text }),
        Err(why) => serde_json::json!({ "error": why.as_str() }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frames(level: i16, ms: u32) -> Vec<Vec<i16>> {
        (0..ms / FRAME_MS)
            .map(|i| {
                (0..FRAME)
                    .map(|j| {
                        if (i as usize + j).is_multiple_of(2) {
                            level
                        } else {
                            -level
                        }
                    })
                    .collect()
            })
            .collect()
    }

    /// 250 ms of the room is 13 frames of 20 ms.
    fn calibrate(vad: &mut Vad, level: i16) {
        assert_eq!(
            run(
                vad,
                frames(level, CALIBRATE_MS.div_ceil(FRAME_MS) * FRAME_MS)
            ),
            None
        );
    }

    fn run(vad: &mut Vad, chunks: Vec<Vec<i16>>) -> Option<Step> {
        for f in chunks {
            match vad.frame(&f) {
                Step::More => {}
                done => return Some(done),
            }
        }
        None
    }

    #[test]
    fn speech_after_the_room_is_learnt_ends_after_900_ms_of_quiet() {
        let mut vad = Vad::new();
        calibrate(&mut vad, 100);
        assert_eq!(
            run(&mut vad, frames(100, 500)),
            None,
            "the room's own level is not speech"
        );
        assert_eq!(run(&mut vad, frames(5000, 1000)), None);
        assert_eq!(
            run(&mut vad, frames(100, QUIET_END_MS - 20)),
            None,
            "a pause is not the end"
        );
        match run(&mut vad, frames(100, 20)) {
            Some(Step::Heard(clip)) => {
                let ms = clip.len() as u32 * 1000 / RATE;
                assert_eq!(ms, 1000 + QUIET_END_MS, "the clip starts with the speech");
            }
            other => panic!("expected the clip, got {other:?}"),
        }
    }

    #[test]
    fn a_click_shorter_than_100_ms_is_not_speech_and_silence_gives_up_at_4_s() {
        let mut vad = Vad::new();
        calibrate(&mut vad, 100);
        let learnt = CALIBRATE_MS.div_ceil(FRAME_MS) * FRAME_MS;
        assert_eq!(run(&mut vad, frames(5000, SPEECH_START_MS - 20)), None);
        // the 4 s count from the first frame, the room's included
        let left = WAIT_MS - learnt - (SPEECH_START_MS - 20);
        assert_eq!(run(&mut vad, frames(100, left - 20)), None);
        assert_eq!(run(&mut vad, frames(100, 20)), Some(Step::NothingHeard));
    }

    fn clip_ms(step: Option<Step>) -> u32 {
        match step {
            Some(Step::Heard(clip)) => clip.len() as u32 * 1000 / RATE,
            other => panic!("expected a clip, got {other:?}"),
        }
    }

    #[test]
    fn speech_from_the_first_frame_is_heard_whole() {
        // the person spoke before the room could be learnt: its quietest
        // frame is speech, so the room is taken to be at the floor
        let mut vad = Vad::new();
        assert_eq!(run(&mut vad, frames(5000, 1000)), None);
        assert_eq!(
            clip_ms(run(&mut vad, frames(100, QUIET_END_MS))),
            1000 + QUIET_END_MS
        );
    }

    #[test]
    fn speech_100_ms_in_is_heard_from_its_start() {
        let mut vad = Vad::new();
        assert_eq!(run(&mut vad, frames(100, 100)), None);
        assert_eq!(run(&mut vad, frames(5000, 1000)), None);
        assert_eq!(
            clip_ms(run(&mut vad, frames(100, QUIET_END_MS))),
            1000 + QUIET_END_MS,
            "the clip starts with the speech, not the room before it"
        );
    }

    #[test]
    fn a_question_starting_inside_the_window_takes_the_quiet_before_it_as_the_room() {
        // a mean over the window would make the room loud and the speech
        // never cross 3x it (bench, CM4, 2026-10-14)
        let mut vad = Vad::new();
        assert_eq!(run(&mut vad, frames(150, 160)), None);
        assert_eq!(run(&mut vad, frames(1200, 1500)), None);
        assert_eq!(
            clip_ms(run(&mut vad, frames(150, QUIET_END_MS))),
            1500 + QUIET_END_MS
        );
    }

    #[test]
    fn talking_on_is_cut_at_8_s() {
        let mut vad = Vad::new();
        calibrate(&mut vad, 100);
        match run(&mut vad, frames(5000, CAP_MS + 1000)) {
            Some(Step::Heard(clip)) => {
                assert_eq!(clip.len() as u32 * 1000 / RATE, CAP_MS)
            }
            other => panic!("expected the clip at the cap, got {other:?}"),
        }
    }

    #[test]
    fn a_silent_room_does_not_make_breathing_speech() {
        let mut vad = Vad::new();
        calibrate(&mut vad, 0);
        assert_eq!(run(&mut vad, frames(200, 1000)), None, "under the floor");
    }

    #[test]
    fn the_wav_header_says_16_khz_mono_16_bit() {
        let w = wav(&[1, -1, 2]);
        assert_eq!(&w[..4], b"RIFF");
        assert_eq!(u32::from_le_bytes(w[24..28].try_into().unwrap()), RATE);
        assert_eq!(u16::from_le_bytes(w[22..24].try_into().unwrap()), 1);
        assert_eq!(u32::from_le_bytes(w[40..44].try_into().unwrap()), 6);
        assert_eq!(w.len(), 44 + 6);
        assert_eq!(samples(&w[44..]), vec![1, -1, 2]);
    }

    #[test]
    fn the_request_is_multipart_with_its_length() {
        let req = inference_request(b"WAVDATA");
        let text = String::from_utf8_lossy(&req);
        let (head, body) = text.split_once("\r\n\r\n").unwrap();
        assert!(head.starts_with("POST /inference HTTP/1.1\r\n"));
        let len: usize = head
            .lines()
            .find_map(|l| l.strip_prefix("Content-Length: "))
            .unwrap()
            .parse()
            .unwrap();
        assert_eq!(len, body.len());
        assert!(body.contains("name=\"file\"; filename=\"clip.wav\""));
        assert!(body.contains("WAVDATA"));
        assert!(body.contains("name=\"response_format\"\r\n\r\njson"));
    }

    #[test]
    fn answers_plain_and_chunked() {
        let plain = b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"text\":\" Hello there. \"}";
        let (status, body) = response(plain).unwrap();
        assert_eq!(status, 200);
        assert_eq!(text_of(&body).as_deref(), Some("Hello there."));
        let chunked = b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n6\r\n{\"text\r\nb\r\n\":\"Hi\"}    \r\n0\r\n\r\n";
        let (_, body) = response(chunked).unwrap();
        assert_eq!(text_of(&body).as_deref(), Some("Hi"));
        assert!(response(b"garbage").is_err());
    }

    #[test]
    fn capture_and_what_heard_carries() {
        assert!(!has_capture(
            "00-00: MAI PCM i2s-hifi-0 : MAI PCM i2s-hifi-0 : playback 1\n"
        ));
        assert!(has_capture(
            "01-00: Loopback PCM : Loopback PCM : playback 8 : capture 8\n"
        ));
        assert_eq!(heard(Ok("hi".into())), serde_json::json!({"text": "hi"}));
        assert_eq!(
            heard(Ok(String::new())),
            serde_json::json!({"error": "nothing-heard"})
        );
        assert_eq!(
            heard(Err(Why::NoMicrophone)),
            serde_json::json!({"error": "no-microphone"})
        );
    }

    #[test]
    fn a_whisper_server_on_a_unix_socket_is_asked_and_answers() {
        let dir = tempdir();
        let path = dir.join("stt.sock");
        let listener = std::os::unix::net::UnixListener::bind(&path).unwrap();
        let server = std::thread::spawn(move || {
            let (mut s, _) = listener.accept().unwrap();
            let mut buf = vec![0u8; 1 << 16];
            let mut got = Vec::new();
            loop {
                let n = s.read(&mut buf).unwrap();
                got.extend_from_slice(&buf[..n]);
                if n == 0 || got.ends_with(b"--\r\n") {
                    break;
                }
            }
            s.write_all(
                b"HTTP/1.1 200 OK\r\nContent-Length: 18\r\n\r\n{\"text\":\" Hello\"}",
            )
            .unwrap();
            String::from_utf8_lossy(&got).contains("RIFF")
        });
        assert_eq!(transcribe(&path, &[0; 160]).unwrap(), "Hello");
        assert!(server.join().unwrap(), "the clip went as a WAV");
        assert!(matches!(
            transcribe(&dir.join("absent.sock"), &[0; 16]),
            Err(Failure::Engine(_))
        ));
        let _ = std::fs::remove_dir_all(dir);
    }

    fn tempdir() -> std::path::PathBuf {
        let d = std::env::temp_dir().join(format!("vrx-stt-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }
}
