// The IPC clients: intent send, pipes, file watch — the three shapes
// an applet uses from the SDK side. Synchronous std Unix sockets: an
// applet is simple, small, and single-purpose; async belongs to the
// runtime, not the applet developer. Intents go to vrxhost's Varlink
// interface io.vrx.Host (plan 0008 D8): JSON objects, NUL-terminated.
//
// Degraded standalone: when vrxhost is not running (a shell run, a
// host test), every client returns a clearly-named error instead of
// silently doing nothing.

use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};

use vrx_protocol::{Intent, PipeMessage};

/// The runtime directory (vrxhost's socket lives at <runtime>/io.vrx.Host,
/// the pipes at <runtime>/pipes). VRX_RUNTIME overrides the default for
/// tests and chroots.
pub fn runtime_dir() -> PathBuf {
    std::env::var_os("VRX_RUNTIME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/run/vrx"))
}

/// vrxhost's Varlink socket.
pub fn host_socket() -> PathBuf {
    runtime_dir().join("io.vrx.Host")
}

/// An IPC failure, each cause named.
#[derive(Debug, thiserror::Error)]
pub enum IpcError {
    #[error("vrxhost is not running (no socket at {path}): the applet runs degraded standalone")]
    NoHost { path: PathBuf },
    #[error("vrxhost refused: {error} {parameters}")]
    Refused {
        error: String,
        parameters: serde_json::Value,
    },
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

/// Send an intent through io.vrx.Host, settle with its verdict.
pub fn intent_send(
    name: impl Into<String>,
    payload: vrx_protocol::IntentPayload,
) -> Result<SendResult, IpcError> {
    let intent =
        Intent::new(name, payload).map_err(|e| IpcError::BadAnswer(e.to_string()))?;
    let reply = varlink_call(
        "io.vrx.Host.Intent",
        serde_json::json!({ "name": intent.name, "payload": intent.payload }),
    )?;
    parse_answer(&reply)
}

/// One Varlink call on vrxhost's socket: the reply object.
fn varlink_call(
    method: &str,
    parameters: serde_json::Value,
) -> Result<serde_json::Value, IpcError> {
    let socket = host_socket();
    let mut stream =
        UnixStream::connect(&socket).map_err(|_| IpcError::NoHost { path: socket })?;
    let mut call = serde_json::to_vec(&serde_json::json!({
        "method": method,
        "parameters": parameters,
    }))
    .map_err(|e| IpcError::BadAnswer(e.to_string()))?;
    call.push(0);
    stream
        .write_all(&call)
        .map_err(|e| IpcError::BadAnswer(e.to_string()))?;
    let mut reply = Vec::new();
    let mut byte = [0u8; 1];
    loop {
        match stream.read(&mut byte) {
            Ok(0) => return Err(IpcError::BadAnswer("vrxhost closed mid-reply".into())),
            Ok(_) if byte[0] == 0 => break,
            Ok(_) => reply.push(byte[0]),
            Err(e) => return Err(IpcError::BadAnswer(e.to_string())),
        }
    }
    serde_json::from_slice(&reply).map_err(|e| IpcError::BadAnswer(e.to_string()))
}

fn parse_answer(reply: &serde_json::Value) -> Result<SendResult, IpcError> {
    let params = reply
        .get("parameters")
        .cloned()
        .unwrap_or(serde_json::Value::Null);
    if let Some(error) = reply.get("error").and_then(|v| v.as_str()) {
        return Err(IpcError::Refused {
            error: error.to_owned(),
            parameters: params,
        });
    }
    match params.get("verdict").and_then(|v| v.as_str()) {
        Some("opened") => Ok(SendResult::Opened {
            applet: params
                .get("handled_by")
                .and_then(|v| v.as_str())
                .unwrap_or_default()
                .to_owned(),
            route: u32::try_from(
                params.get("route").and_then(|v| v.as_u64()).unwrap_or(0),
            )
            .unwrap_or(0),
        }),
        Some("pass") => Ok(SendResult::Pass),
        other => Err(IpcError::BadAnswer(format!("unknown verdict {other:?}"))),
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
/// changes. `poll` reads it now; `watch_forever` waits on inotify.
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

    /// Wait for changes forever, on inotify (no polling, no period: the
    /// closure runs as soon as the file is written or replaced). The
    /// parent directory is watched, because state files are replaced by
    /// rename. Returns only on an error.
    #[cfg(target_os = "linux")]
    pub fn watch_forever<F: FnMut(&str)>(
        mut self,
        mut on_change: F,
    ) -> std::io::Result<()> {
        use rustix::fs::inotify;
        let dir = self
            .path
            .parent()
            .unwrap_or_else(|| Path::new("/"))
            .to_owned();
        let fd = inotify::init(inotify::CreateFlags::CLOEXEC)?;
        inotify::add_watch(
            &fd,
            &dir,
            inotify::WatchFlags::CLOSE_WRITE
                | inotify::WatchFlags::MOVED_TO
                | inotify::WatchFlags::CREATE
                | inotify::WatchFlags::DELETE,
        )?;
        let mut buf = [std::mem::MaybeUninit::<u8>::uninit(); 4096];
        let mut events = inotify::Reader::new(&fd, &mut buf);
        loop {
            // blocks in the kernel until something in the directory changes
            events.next()?;
            if let Some(Some(value)) = self.poll() {
                on_change(&value);
            }
        }
    }

    /// inotify is Linux's; elsewhere (a developer's host) there is no
    /// change notification to wait on.
    #[cfg(not(target_os = "linux"))]
    pub fn watch_forever<F: FnMut(&str)>(self, _on_change: F) -> std::io::Result<()> {
        Err(std::io::Error::new(
            std::io::ErrorKind::Unsupported,
            "File::watch_forever needs inotify (Linux)",
        ))
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
        let opened = serde_json::json!({"parameters": {"verdict": "opened", "handled_by": "clock", "route": 4}});
        assert_eq!(
            parse_answer(&opened).expect("parses"),
            SendResult::Opened {
                applet: "clock".into(),
                route: 4
            }
        );
        let pass = serde_json::json!({"parameters": {"verdict": "pass"}});
        assert_eq!(parse_answer(&pass).expect("parses"), SendResult::Pass);
        let refused = serde_json::json!({"error": "io.vrx.Host.NoHandler", "parameters": {"name": "x.y"}});
        assert!(matches!(
            parse_answer(&refused),
            Err(IpcError::Refused { error, .. }) if error == "io.vrx.Host.NoHandler"
        ));
    }
}
