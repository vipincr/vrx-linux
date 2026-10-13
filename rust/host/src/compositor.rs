// vrxhost's link to the compositor (flutter-vrx --compositor, plan 0007
// amendment C). vrxhost is the compositor's one controller: it connects
// to the compositor's socket, says CONTROL, then names the focused app
// by pid; the compositor reports each app that registers or leaves.
//
// The wire is flutter-vrx's src/vrx_ipc.h: SOCK_SEQPACKET (one send is
// one message), a native-endian header {u32 type, u32 length} and a
// type-specific payload. Only the controller messages live here; the
// numbers must match vrx_ipc.h.

use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::time::Duration;

use socket2::{Domain, SockAddr, Socket, Type};
use tokio::io::unix::AsyncFd;
use tokio::sync::mpsc;

/// The compositor's socket (VRX_UI_SOCKET in vrx_ipc.h).
pub const SOCKET: &str = "/run/vrx-ui/vrx.sock";

pub const MSG_CONTROL: u32 = 9;
pub const MSG_SET_FOCUS: u32 = 10;
pub const MSG_APP_STATE: u32 = 11;

const ID_LEN: usize = 64;
const HEADER_LEN: usize = 8;
const APP_STATE_LEN: usize = 4 + 4 + ID_LEN;

/// How long to wait between connection attempts: the compositor may
/// start after vrxhost, or restart under it.
const RETRY: Duration = Duration::from_millis(500);

/// What the link reports.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LinkEvent {
    /// Connected and accepted as controller. Whatever focus vrxhost
    /// wants must be (re)sent now: a restarted compositor knows none.
    Connected,
    /// An app registered with the compositor (alive) or disconnected.
    App { pid: u32, alive: bool, id: String },
    /// The connection dropped; the link is reconnecting.
    Lost,
}

/// Encode one message: header plus payload.
pub fn encode(kind: u32, payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(HEADER_LEN + payload.len());
    out.extend_from_slice(&kind.to_ne_bytes());
    out.extend_from_slice(&u32::try_from(payload.len()).unwrap_or(0).to_ne_bytes());
    out.extend_from_slice(payload);
    out
}

/// SET_FOCUS for a pid (0 = none).
pub fn set_focus(pid: u32) -> Vec<u8> {
    encode(
        MSG_SET_FOCUS,
        &i32::try_from(pid).unwrap_or(0).to_ne_bytes(),
    )
}

/// Decode one received message into an event; anything that is not an
/// APP_STATE (or is malformed) is None.
pub fn decode(msg: &[u8]) -> Option<LinkEvent> {
    let word = |at: usize| -> Option<u32> {
        let bytes: [u8; 4] = msg.get(at..at + 4)?.try_into().ok()?;
        Some(u32::from_ne_bytes(bytes))
    };
    if word(0)? != MSG_APP_STATE || (word(4)? as usize) < APP_STATE_LEN {
        return None;
    }
    let pid = i32::from_ne_bytes(word(HEADER_LEN)?.to_ne_bytes());
    let alive = word(HEADER_LEN + 4)? != 0;
    let raw = msg.get(HEADER_LEN + 8..HEADER_LEN + 8 + ID_LEN)?;
    let end = raw.iter().position(|&b| b == 0).unwrap_or(ID_LEN);
    let id = String::from_utf8_lossy(&raw[..end]).into_owned();
    Some(LinkEvent::App {
        pid: u32::try_from(pid).ok()?,
        alive,
        id,
    })
}

/// Run the link forever: connect (retrying), declare control, then
/// forward focus orders from `focus` and report events on `events`.
/// Returns only when vrxhost drops either channel.
pub async fn run(
    socket: PathBuf,
    mut focus: mpsc::UnboundedReceiver<u32>,
    events: mpsc::UnboundedSender<LinkEvent>,
) {
    let mut announced_wait = false;
    loop {
        let fd = match connect(&socket) {
            Ok(fd) => fd,
            Err(err) => {
                if !announced_wait {
                    tracing::info!(socket = %socket.display(), error = %err, "waiting for the compositor");
                    announced_wait = true;
                }
                tokio::time::sleep(RETRY).await;
                continue;
            }
        };
        announced_wait = false;
        if send(&fd, &encode(MSG_CONTROL, &[])).await.is_err() {
            tokio::time::sleep(RETRY).await;
            continue;
        }
        tracing::info!(socket = %socket.display(), "controlling the compositor");
        if events.send(LinkEvent::Connected).is_err() {
            return;
        }
        let ended = serve(&fd, &mut focus, &events).await;
        if events.send(LinkEvent::Lost).is_err() {
            return;
        }
        match ended {
            Served::ChannelClosed => return,
            Served::Disconnected(err) => {
                tracing::warn!(error = %err, "compositor link lost; reconnecting");
            }
        }
        tokio::time::sleep(RETRY).await;
    }
}

enum Served {
    ChannelClosed,
    Disconnected(io::Error),
}

async fn serve(
    fd: &AsyncFd<Socket>,
    focus: &mut mpsc::UnboundedReceiver<u32>,
    events: &mpsc::UnboundedSender<LinkEvent>,
) -> Served {
    let mut buf = [0u8; 512];
    loop {
        tokio::select! {
            pid = focus.recv() => {
                let Some(pid) = pid else { return Served::ChannelClosed };
                if let Err(err) = send(fd, &set_focus(pid)).await {
                    return Served::Disconnected(err);
                }
            }
            ready = fd.readable() => {
                let mut guard = match ready {
                    Ok(guard) => guard,
                    Err(err) => return Served::Disconnected(err),
                };
                match guard.try_io(|inner| inner.get_ref().read(&mut buf)) {
                    Ok(Ok(0)) => {
                        return Served::Disconnected(io::ErrorKind::UnexpectedEof.into());
                    }
                    Ok(Ok(n)) => {
                        if let Some(event) = decode(&buf[..n]) {
                            if events.send(event).is_err() {
                                return Served::ChannelClosed;
                            }
                        }
                    }
                    Ok(Err(err)) => return Served::Disconnected(err),
                    Err(_would_block) => continue,
                }
            }
        }
    }
}

fn connect(path: &Path) -> io::Result<AsyncFd<Socket>> {
    let socket = Socket::new(Domain::UNIX, Type::SEQPACKET, None)?;
    socket.connect(&SockAddr::unix(path)?)?;
    socket.set_nonblocking(true)?;
    AsyncFd::new(socket)
}

async fn send(fd: &AsyncFd<Socket>, msg: &[u8]) -> io::Result<()> {
    loop {
        let mut guard = fd.writable().await?;
        match guard.try_io(|inner| inner.get_ref().write(msg)) {
            Ok(result) => return result.map(|_| ()),
            Err(_would_block) => continue,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn app_state(pid: i32, alive: u32, id: &str) -> Vec<u8> {
        let mut payload = Vec::new();
        payload.extend_from_slice(&pid.to_ne_bytes());
        payload.extend_from_slice(&alive.to_ne_bytes());
        let mut name = [0u8; ID_LEN];
        name[..id.len()].copy_from_slice(id.as_bytes());
        payload.extend_from_slice(&name);
        encode(MSG_APP_STATE, &payload)
    }

    #[test]
    fn the_wire_matches_vrx_ipc_h() {
        // struct vrx_msg_header {u32 type; u32 length} + int32_t pid
        let msg = set_focus(412);
        assert_eq!(msg.len(), 12);
        assert_eq!(&msg[0..4], &10u32.to_ne_bytes());
        assert_eq!(&msg[4..8], &4u32.to_ne_bytes());
        assert_eq!(&msg[8..12], &412i32.to_ne_bytes());
        // struct vrx_msg_app_state {int32 pid; u32 alive; char id[64]}
        assert_eq!(app_state(1, 1, "x").len(), HEADER_LEN + 72);
        let control = encode(MSG_CONTROL, &[]);
        assert_eq!(control.len(), HEADER_LEN);
        assert_eq!(&control[0..4], &9u32.to_ne_bytes());
        assert_eq!(&control[4..8], &0u32.to_ne_bytes());
    }

    #[test]
    fn app_state_decodes_and_junk_does_not() {
        assert_eq!(
            decode(&app_state(394, 1, "launcher")),
            Some(LinkEvent::App {
                pid: 394,
                alive: true,
                id: "launcher".into()
            })
        );
        assert_eq!(
            decode(&app_state(394, 0, "launcher")),
            Some(LinkEvent::App {
                pid: 394,
                alive: false,
                id: "launcher".into()
            })
        );
        let truncated = &app_state(1, 1, "a")[..20];
        assert_eq!(decode(truncated), None);
        assert_eq!(decode(&encode(MSG_SET_FOCUS, &[0; 4])), None);
        assert_eq!(decode(&[]), None);
    }
}
