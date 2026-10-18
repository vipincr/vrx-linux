// The IPC clients: intents (sent, and received over Listen), channels and
// file watch, the shapes an applet uses from the SDK side (plan 0008
// D15). Synchronous std Unix sockets: an
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

/// The runtime directory (vrxhost's socket lives at <runtime>/io.vrx.Host).
/// VRX_RUNTIME overrides the default for tests and chroots.
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
    #[error("channel {channel:?}: {source}")]
    Channel {
        channel: String,
        #[source]
        source: std::io::Error,
    },
    #[error("channels and Listen pass file descriptors: Linux only")]
    Unsupported,
}

/// The answer from vrxhost for a sent intent.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SendResult {
    /// An opened handler took it: this applet, at this route.
    Opened { applet: String, route: u32 },
    /// A told handler answered handled.
    Handled { applet: String },
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
    // CON-12 (review 2026-10-17): the read has a deadline — a wedged
    // vrxhost answered nothing and the applet blocked for ever on a
    // socket that never closed. 10 s: the host's own watchdog restarts
    // it well inside that.
    stream
        .set_read_timeout(Some(std::time::Duration::from_secs(10)))
        .map_err(|e| IpcError::BadAnswer(e.to_string()))?;
    loop {
        match stream.read(&mut byte) {
            Ok(0) => return Err(IpcError::BadAnswer("vrxhost closed mid-reply".into())),
            Ok(_) if byte[0] == 0 => break,
            Ok(_) => reply.push(byte[0]),
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock || e.kind() == std::io::ErrorKind::TimedOut => {
                return Err(IpcError::BadAnswer("vrxhost did not answer within 10 s".into()))
            }
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
        Some("handled") => Ok(SendResult::Handled {
            applet: params
                .get("handled_by")
                .and_then(|v| v.as_str())
                .unwrap_or_default()
                .to_owned(),
        }),
        Some("pass") => Ok(SendResult::Pass),
        other => Err(IpcError::BadAnswer(format!("unknown verdict {other:?}"))),
    }
}

/// A channel (plan 0008 D15): a stream between two applets that vrxhost
/// opened, carrying ordered JSON records, one per line.
#[derive(Debug)]
pub struct Channel {
    name: String,
    writer: UnixStream,
    reader: BufReader<UnixStream>,
}

impl Channel {
    /// Open `<to>.<channel>`: the channel must be in this applet's
    /// channels.opens and the other applet's channels.offers, and that
    /// applet must be listening.
    pub fn open(to: &str, channel: &str) -> Result<Self, IpcError> {
        let name = format!("{to}.{channel}");
        let (reply, mut fds) = fd::call(
            "io.vrx.Host.Open",
            serde_json::json!({ "to": to, "channel": channel }),
        )?;
        refused(&reply)?;
        let fd = fds
            .pop()
            .ok_or_else(|| IpcError::BadAnswer("Open replied without a stream".into()))?;
        Self::from_stream(name, UnixStream::from(fd))
    }

    /// A stream handed over by vrxhost (a Listen delivery).
    pub fn from_stream(name: String, stream: UnixStream) -> Result<Self, IpcError> {
        let reader = stream.try_clone().map_err(|source| IpcError::Channel {
            channel: name.clone(),
            source,
        })?;
        Ok(Self {
            name,
            writer: stream,
            reader: BufReader::new(reader),
        })
    }

    /// `<applet>.<channel>`.
    pub fn name(&self) -> &str {
        &self.name
    }

    /// The stream itself, for a buffer queue: before any record is read, so
    /// nothing sits in the reader's buffer.
    #[cfg(target_os = "linux")]
    pub(crate) fn into_stream(self) -> UnixStream {
        self.writer
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
            .map_err(|source| IpcError::Channel {
                channel: self.name.clone(),
                source,
            })
    }

    /// Write one JSON line with no envelope: the first line of a buffer
    /// queue's stream is a bare offer (plan 0009 D10), and a producer that
    /// refuses a claimant says so in the same bare form, `{"error": "busy"}`.
    pub fn write_bare_line(&mut self, line: &serde_json::Value) -> Result<(), IpcError> {
        let mut bytes =
            serde_json::to_vec(line).map_err(|e| IpcError::BadAnswer(e.to_string()))?;
        bytes.push(b'\n');
        self.writer
            .write_all(&bytes)
            .map_err(|source| IpcError::Channel {
                channel: self.name.clone(),
                source,
            })
    }

    /// Write one JSON record with a descriptor riding on it (SCM_RIGHTS): a
    /// photo's sealed memfd, as `camerad.photos` answers (plan 0018 D7).
    #[cfg(target_os = "linux")]
    pub fn write_with_fd(
        &mut self,
        record: vrx_protocol::IntentPayload,
        fd: std::os::fd::BorrowedFd<'_>,
    ) -> Result<(), IpcError> {
        use rustix::net::{
            sendmsg, SendAncillaryBuffer, SendAncillaryMessage, SendFlags,
        };
        use std::io::IoSlice;
        use std::mem::MaybeUninit;
        let message = PipeMessage::new(self.name.clone(), record)
            .map_err(|e| IpcError::BadAnswer(e.to_string()))?;
        let mut line = serde_json::to_vec(&message)
            .map_err(|e| IpcError::BadAnswer(e.to_string()))?;
        line.push(b'\n');
        let fds = [fd];
        let mut space = [MaybeUninit::uninit(); rustix::cmsg_space!(ScmRights(1))];
        let mut control = SendAncillaryBuffer::new(&mut space);
        control.push(SendAncillaryMessage::ScmRights(&fds));
        sendmsg(
            &self.writer,
            &[IoSlice::new(&line)],
            &mut control,
            SendFlags::empty(),
        )
        .map(|_| ())
        .map_err(|e| IpcError::Channel {
            channel: self.name.clone(),
            source: e.into(),
        })
    }

    /// Block for the next record and the descriptor that came with it, if
    /// any; None when the other end closed. Reads a byte at a time so a
    /// descriptor stays with its own record: use it on a channel that only
    /// ever strictly alternates request and response (`camerad.photos`),
    /// never after [Self::next_record] has buffered more than one line.
    #[cfg(target_os = "linux")]
    pub fn next_record_with_fd(
        &mut self,
    ) -> Option<(vrx_protocol::IntentPayload, Option<std::os::fd::OwnedFd>)> {
        use rustix::net::{
            recvmsg, RecvAncillaryBuffer, RecvAncillaryMessage, RecvFlags,
        };
        use std::io::IoSliceMut;
        use std::mem::MaybeUninit;
        if !self.reader.buffer().is_empty() {
            return None;
        }
        let mut line = Vec::new();
        let mut fd = None;
        loop {
            let mut byte = [0u8; 1];
            let mut space = [MaybeUninit::uninit(); rustix::cmsg_space!(ScmRights(1))];
            let mut control = RecvAncillaryBuffer::new(&mut space);
            let got = recvmsg(
                self.reader.get_ref(),
                &mut [IoSliceMut::new(&mut byte)],
                &mut control,
                RecvFlags::CMSG_CLOEXEC,
            )
            .ok()?;
            for message in control.drain() {
                if let RecvAncillaryMessage::ScmRights(fds) = message {
                    fd = fd.or(fds.into_iter().next());
                }
            }
            if got.bytes == 0 {
                return None;
            }
            if byte[0] == b'\n' {
                break;
            }
            line.push(byte[0]);
        }
        let message: PipeMessage = serde_json::from_slice(&line).ok()?;
        Some((message.record, fd))
    }

    /// Block for the next record; None when the other end closed.
    pub fn next_record(&mut self) -> Option<vrx_protocol::IntentPayload> {
        let mut line = String::new();
        match self.reader.read_line(&mut line) {
            Ok(0) | Err(_) => None,
            Ok(_) => serde_json::from_str::<PipeMessage>(line.trim())
                .ok()
                .map(|m| m.record),
        }
    }
}

/// What vrxhost hands a listening applet.
#[derive(Debug)]
pub enum Delivery {
    /// An intent this applet handles; with an id, [answer] it within
    /// 100 ms (silence is a pass).
    Intent {
        id: Option<u64>,
        name: String,
        payload: vrx_protocol::IntentPayload,
    },
    /// Another applet opened one of this applet's channels.
    Channel { from: String, channel: Channel },
}

/// This applet's Listen: the intents it handles and the channels opened
/// on it, as they come.
pub struct Listener {
    inner: fd::Stream,
}

impl Listener {
    /// Start listening (the newest Listen of an applet wins).
    pub fn start() -> Result<Self, IpcError> {
        Ok(Self {
            inner: fd::Stream::call("io.vrx.Host.Listen")?,
        })
    }

    /// Block for the next delivery. Three answers where the old Option
    /// folded them into one None (CON-05, review 2026-10-17): the stream
    /// ended, the record did not parse, or the delivery kind is one this
    /// SDK does not know (a newer vrxhost). A caller can tell a shutdown
    /// from a protocol fault.
    pub fn next_delivery(&mut self) -> NextDelivery {
        let Some((reply, fd)) = self.inner.next() else {
            return NextDelivery::Ended;
        };
        let Some(params) = reply.get("parameters") else {
            return NextDelivery::Malformed("the reply names no parameters".into());
        };
        let text = |k: &str| {
            params
                .get(k)
                .and_then(|v| v.as_str())
                .unwrap_or_default()
                .to_owned()
        };
        let kind = match params.get("kind").and_then(|v| v.as_str()) {
            Some(k) => k,
            None => return NextDelivery::Malformed("the delivery names no kind".into()),
        };
        match kind {
            "intent" => NextDelivery::Delivery(Delivery::Intent {
                id: params.get("id").and_then(|v| v.as_u64()),
                name: text("name"),
                payload: params.get("payload").cloned().unwrap_or_default(),
            }),
            "channel" => {
                let Some(fd) = fd else {
                    return NextDelivery::Malformed("a channel delivery with no descriptor".into());
                };
                let stream = UnixStream::from(fd);
                let channel = match Channel::from_stream(text("channel"), stream) {
                    Ok(c) => c,
                    Err(e) => return NextDelivery::Malformed(format!("the channel delivery: {e}")),
                };
                NextDelivery::Delivery(Delivery::Channel {
                    from: text("from"),
                    channel,
                })
            }
            other => NextDelivery::Unknown(other.to_owned()),
        }
    }
}

/// [Listener::next_delivery]'s three answers (CON-05).
#[derive(Debug)]
pub enum NextDelivery {
    /// A delivery.
    Delivery(Delivery),
    /// vrxhost hung up: the applet's lifetime's end.
    Ended,
    /// A record that does not parse: a protocol fault, named.
    Malformed(String),
    /// A delivery kind this SDK does not know (a newer vrxhost).
    Unknown(String),
}

/// Answer an intent a Listen asked about.
pub fn answer(id: u64, handled: bool) -> Result<(), IpcError> {
    let reply = varlink_call(
        "io.vrx.Host.Answer",
        serde_json::json!({ "id": id, "verdict": if handled { "handled" } else { "pass" } }),
    )?;
    refused(&reply)
}

fn refused(reply: &serde_json::Value) -> Result<(), IpcError> {
    match reply.get("error").and_then(|v| v.as_str()) {
        Some(error) => Err(IpcError::Refused {
            error: error.to_owned(),
            parameters: reply.get("parameters").cloned().unwrap_or_default(),
        }),
        None => Ok(()),
    }
}

/// Varlink with file descriptors: a reply's descriptors arrive with its
/// first byte (SCM_RIGHTS), read through rustix's recvmsg.
#[cfg(target_os = "linux")]
mod fd {
    use std::collections::VecDeque;
    use std::io::{IoSliceMut, Write};
    use std::mem::MaybeUninit;
    use std::os::fd::OwnedFd;
    use std::os::unix::net::UnixStream;

    use rustix::net::{recvmsg, RecvAncillaryBuffer, RecvAncillaryMessage, RecvFlags};

    use super::{host_socket, IpcError};

    pub struct Stream {
        socket: UnixStream,
        bytes: Vec<u8>,
        fds: VecDeque<OwnedFd>,
    }

    impl Stream {
        fn connect(
            method: &str,
            parameters: serde_json::Value,
            more: bool,
        ) -> Result<Self, IpcError> {
            let path = host_socket();
            let mut socket =
                UnixStream::connect(&path).map_err(|_| IpcError::NoHost { path })?;
            let mut call = serde_json::to_vec(&serde_json::json!({
                "method": method, "parameters": parameters, "more": more,
            }))
            .map_err(|e| IpcError::BadAnswer(e.to_string()))?;
            call.push(0);
            socket
                .write_all(&call)
                .map_err(|e| IpcError::BadAnswer(e.to_string()))?;
            Ok(Self {
                socket,
                bytes: Vec::new(),
                fds: VecDeque::new(),
            })
        }

        /// A `more` call: its replies, one by one.
        pub fn call(method: &str) -> Result<Self, IpcError> {
            Self::connect(method, serde_json::json!({}), true)
        }

        /// The next reply, and the descriptor that came with it, if any.
        pub fn next(&mut self) -> Option<(serde_json::Value, Option<OwnedFd>)> {
            loop {
                if let Some(end) = self.bytes.iter().position(|b| *b == 0) {
                    let message: Vec<u8> = self.bytes.drain(..=end).collect();
                    let reply = serde_json::from_slice(&message[..end]).ok()?;
                    // descriptors stop a read at their message, so the next
                    // queued one belongs to the next reply that carries one
                    let carries = message_carries_fd(&reply);
                    let fd = if carries { self.fds.pop_front() } else { None };
                    return Some((reply, fd));
                }
                let mut chunk = [0u8; 4096];
                let mut space =
                    [MaybeUninit::uninit(); rustix::cmsg_space!(ScmRights(4))];
                let mut control = RecvAncillaryBuffer::new(&mut space);
                let got = recvmsg(
                    &self.socket,
                    &mut [IoSliceMut::new(&mut chunk)],
                    &mut control,
                    RecvFlags::CMSG_CLOEXEC,
                )
                .ok()?;
                for message in control.drain() {
                    if let RecvAncillaryMessage::ScmRights(fds) = message {
                        self.fds.extend(fds);
                    }
                }
                if got.bytes == 0 {
                    return None;
                }
                self.bytes.extend_from_slice(&chunk[..got.bytes]);
            }
        }
    }

    /// A Listen channel delivery or an Open reply rides with a stream.
    fn message_carries_fd(reply: &serde_json::Value) -> bool {
        let params = reply.get("parameters");
        let kind = params.and_then(|p| p.get("kind")).and_then(|k| k.as_str());
        kind == Some("channel") || (kind.is_none() && reply.get("error").is_none())
    }

    /// One call: its reply and the descriptors it carried.
    pub fn call(
        method: &str,
        parameters: serde_json::Value,
    ) -> Result<(serde_json::Value, Vec<OwnedFd>), IpcError> {
        let mut stream = Stream::connect(method, parameters, false)?;
        let (reply, fd) = stream
            .next()
            .ok_or_else(|| IpcError::BadAnswer("vrxhost closed mid-reply".into()))?;
        Ok((reply, fd.into_iter().collect()))
    }
}

/// Descriptor passing is Linux's; a host build (tests, a developer's
/// machine) names the gap instead of pretending.
#[cfg(not(target_os = "linux"))]
mod fd {
    use std::os::fd::OwnedFd;

    use super::IpcError;

    pub struct Stream;

    impl Stream {
        pub fn call(_method: &str) -> Result<Self, IpcError> {
            Err(IpcError::Unsupported)
        }

        pub fn next(&mut self) -> Option<(serde_json::Value, Option<OwnedFd>)> {
            None
        }
    }

    pub fn call(
        _method: &str,
        _parameters: serde_json::Value,
    ) -> Result<(serde_json::Value, Vec<OwnedFd>), IpcError> {
        Err(IpcError::Unsupported)
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
    fn channel_open_without_vrxhost_is_a_named_error() {
        let err = Channel::open("test", "samples").expect_err("no host");
        assert!(
            matches!(err, IpcError::NoHost { .. } | IpcError::Unsupported),
            "{err}"
        );
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn a_record_carries_its_descriptor_and_a_plain_one_carries_none() {
        use std::os::fd::AsFd;
        let (a, b) = UnixStream::pair().expect("pair");
        let mut left = Channel::from_stream("camerad.photos".into(), a).expect("a");
        let mut right = Channel::from_stream("camerad.photos".into(), b).expect("b");
        let file = std::fs::File::open("/proc/self/status").expect("open");
        left.write_with_fd(serde_json::json!({"id": 1}), file.as_fd())
            .expect("send");
        left.write(serde_json::json!({"id": 2})).expect("plain");
        let (first, fd) = right.next_record_with_fd().expect("first");
        assert_eq!(first["id"], 1);
        assert!(fd.is_some(), "the descriptor came with its record");
        let (second, fd) = right.next_record_with_fd().expect("second");
        assert_eq!(second["id"], 2);
        assert!(fd.is_none(), "and not with the next one");
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
        let handled = serde_json::json!({"parameters": {"verdict": "handled", "handled_by": "notes"}});
        assert_eq!(
            parse_answer(&handled).expect("parses"),
            SendResult::Handled {
                applet: "notes".into()
            }
        );
        let refused = serde_json::json!({"error": "io.vrx.Host.NoHandler", "parameters": {"name": "x.y"}});
        assert!(matches!(
            parse_answer(&refused),
            Err(IpcError::Refused { error, .. }) if error == "io.vrx.Host.NoHandler"
        ));
    }
}
