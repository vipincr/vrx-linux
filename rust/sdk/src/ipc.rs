// The IPC clients: intent send, pipes, file watch — the three shapes
// an applet uses from the SDK side. Synchronous std Unix sockets: an
// applet is simple, small, and single-purpose; async belongs to the
// runtime, not the applet developer.
//
// Degraded standalone: when vrxhost is not running (a shell run, a
// host test), every client returns a clearly-named error instead of
// silently doing nothing.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::Duration;

use vrx_protocol::{Intent, PipeMessage};

/// The runtime directory (the socket lives at <runtime>/vrx.sock, the
/// pipes at <runtime>/pipes). VRX_RUNTIME overrides the default for
/// tests and chroots.
pub fn runtime_dir() -> PathBuf {
    std::env::var_os("VRX_RUNTIME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp/vrx"))
}

/// An IPC failure, each cause named.
#[derive(Debug, thiserror::Error)]
pub enum IpcError {
    #[error("vrxhost is not running (no socket at {path}): the applet runs degraded standalone")]
    NoHost { path: PathBuf },
    #[error("vrxhost answered an error: {errno} {error}")]
    HostErrno { errno: i32, error: String },
    #[error("malformed vrxhost answer: {0}")]
    BadAnswer(String),
    #[error("pipe {pipe:?}: {source}")]
    Pipe {
        pipe: String,
        #[source]
        source: std::io::Error,
    },
}

/// The answer from vrxhost for a sent intent.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SendResult {
    /// An opened handler took it: this applet, at this route.
    Opened { applet: String, route: u32 },
    /// Everyone passed; the intent was dropped.
    Pass,
}

/// Send an intent over the vrxhost socket, settle with its verdict.
pub fn intent_send(
    name: impl Into<String>,
    payload: vrx_protocol::IntentPayload,
) -> Result<SendResult, IpcError> {
    let intent =
        Intent::new(name, payload).map_err(|e| IpcError::BadAnswer(e.to_string()))?;
    let socket = runtime_dir().join("vrx.sock");
    let mut stream =
        UnixStream::connect(&socket).map_err(|_| IpcError::NoHost { path: socket })?;

    let mut request =
        serde_json::to_string(&intent).map_err(|e| IpcError::BadAnswer(e.to_string()))?;
    request.push('\n');
    stream
        .write_all(request.as_bytes())
        .map_err(|e| IpcError::BadAnswer(e.to_string()))?;

    let mut answer = String::new();
    BufReader::new(stream)
        .read_line(&mut answer)
        .map_err(|e| IpcError::BadAnswer(e.to_string()))?;
    parse_answer(answer.trim())
}

fn parse_answer(answer: &str) -> Result<SendResult, IpcError> {
    let value: serde_json::Value =
        serde_json::from_str(answer).map_err(|e| IpcError::BadAnswer(e.to_string()))?;
    if value.get("ok").and_then(|v| v.as_bool()) == Some(true) {
        match value.get("verdict").and_then(|v| v.as_str()) {
            Some("opened") => Ok(SendResult::Opened {
                applet: value
                    .get("handled_by")
                    .and_then(|v| v.as_str())
                    .unwrap_or_default()
                    .to_owned(),
                route: value.get("route").and_then(|v| v.as_u64()).unwrap_or(0) as u32,
            }),
            Some("pass") => Ok(SendResult::Pass),
            other => Err(IpcError::BadAnswer(format!("unknown verdict {other:?}"))),
        }
    } else {
        Err(IpcError::HostErrno {
            errno: value.get("errno").and_then(|v| v.as_i64()).unwrap_or(0) as i32,
            error: value
                .get("error")
                .and_then(|v| v.as_str())
                .unwrap_or("unnamed error")
                .to_owned(),
        })
    }
}

/// A pipe handle: ordered records, one writer to one reader.
#[derive(Debug)]
pub struct Pipe {
    name: String,
    writer: UnixStream,
}

impl Pipe {
    /// Open a pipe for writing by dotted name.
    pub fn open(name: impl Into<String>) -> Result<Self, IpcError> {
        let name = name.into();
        let path = pipe_path(&name);
        let writer = UnixStream::connect(&path).map_err(|source| IpcError::Pipe {
            pipe: name.clone(),
            source,
        })?;
        Ok(Self { name, writer })
    }

    /// Write one JSON record.
    pub fn write(&mut self, record: vrx_protocol::IntentPayload) -> Result<(), IpcError> {
        let message = PipeMessage::new(self.name.clone(), record)
            .map_err(|e| IpcError::BadAnswer(e.to_string()))?;
        let mut line = serde_json::to_string(&message)
            .map_err(|e| IpcError::BadAnswer(e.to_string()))?;
        line.push('\n');
        self.writer
            .write_all(line.as_bytes())
            .map_err(|source| IpcError::Pipe {
                pipe: self.name.clone(),
                source,
            })
    }
}

fn pipe_path(name: &str) -> PathBuf {
    runtime_dir().join("pipes").join(name)
}

/// A reader for a pipe: yields each record as it arrives.
pub struct PipeReader {
    reader: BufReader<UnixStream>,
}

impl PipeReader {
    /// Open the reading end of a pipe by dotted name.
    pub fn open(name: impl Into<String>) -> Result<Self, IpcError> {
        let name = name.into();
        let path = pipe_path(&name);
        let stream = UnixStream::connect(&path)
            .map_err(|source| IpcError::Pipe { pipe: name, source })?;
        Ok(Self {
            reader: BufReader::new(stream),
        })
    }

    /// Block for the next record.
    pub fn next_record(&mut self) -> Option<vrx_protocol::IntentPayload> {
        let mut line = String::new();
        match self.reader.read_line(&mut line) {
            Ok(0) | Err(_) => None, // EOF or broken pipe: the stream ended
            Ok(_) => {
                let message: Option<PipeMessage> = serde_json::from_str(line.trim()).ok();
                message.map(|m| m.record)
            }
        }
    }
}

/// A watchable shared-state file: a value that stays true until it
/// changes. Polls (mtime + content); inotify is the target-platform
/// optimization, polling keeps the SDK honest on any host.
pub struct File {
    path: PathBuf,
    seen: Option<String>,
}

impl File {
    /// Start watching a shared-state file.
    pub fn watch(path: impl AsRef<Path>) -> Self {
        Self {
            path: path.as_ref().to_owned(),
            seen: std::fs::read_to_string(path).ok(),
        }
    }

    /// The current value, or None if the file does not exist.
    pub fn value(&self) -> Option<&str> {
        self.seen.as_deref()
    }

    /// Poll once. Returns Some(change) when the file changed since the
    /// last poll — Some(Some(value)) for a new value, Some(None) for a
    /// removal — and None when nothing changed.
    pub fn poll(&mut self) -> Option<Option<String>> {
        let now = std::fs::read_to_string(&self.path).ok();
        if now != self.seen {
            self.seen = now.clone();
            Some(now)
        } else {
            None
        }
    }

    /// Poll forever with this period. The closure sees each change.
    pub fn watch_forever<F: FnMut(&str)>(mut self, period: Duration, mut on_change: F) {
        loop {
            if let Some(Some(value)) = self.poll() {
                on_change(&value);
            }
            std::thread::sleep(period);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn intent_send_without_vrxhost_is_a_named_error() {
        let err = intent_send("test.ping", serde_json::json!(null))
            .expect_err("no host on a test machine");
        assert!(err.to_string().contains("degraded standalone"), "{err}");
    }

    #[test]
    fn pipe_open_without_vrxhost_is_a_named_error() {
        let err = Pipe::open("test.samples").expect_err("no host");
        assert!(err.to_string().contains("test.samples"), "{err}");
    }

    #[test]
    fn file_watch_sees_changes() {
        let dir = tempfile::tempdir().expect("tmp");
        let path = dir.path().join("theme");
        std::fs::write(&path, "dark").expect("write");
        let mut file = File::watch(&path);
        assert_eq!(file.value(), Some("dark"));
        assert_eq!(file.poll(), None, "unchanged is not a change");

        std::fs::write(&path, "light").expect("write");
        assert_eq!(file.poll(), Some(Some("light".to_owned())));
        assert_eq!(file.value(), Some("light"));

        std::fs::remove_file(&path).expect("remove");
        assert_eq!(file.poll(), Some(None), "a removal is a change");
    }

    #[test]
    fn answer_parsing_covers_the_wire_protocol() {
        assert_eq!(
            parse_answer(
                r#"{"ok":true,"verdict":"opened","handled_by":"clock","route":4}"#
            )
            .expect("parses"),
            SendResult::Opened {
                applet: "clock".into(),
                route: 4
            }
        );
        assert_eq!(
            parse_answer(r#"{"ok":true,"verdict":"pass"}"#).expect("parses"),
            SendResult::Pass
        );
        assert!(matches!(
            parse_answer(r#"{"ok":false,"errno":-2,"error":"no handler"}"#),
            Err(IpcError::HostErrno { errno: -2, .. })
        ));
    }
}
