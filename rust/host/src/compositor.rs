// vrxhost's link to the compositor (flutter-vrx --compositor, plan 0007
// amendment C). vrxhost is the compositor's one controller: it connects
// to the compositor's socket, says CONTROL, then names the focused app
// and the shell (plan 0008 D10) by pid; the compositor reports each app
// that registers or leaves.
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
pub const MSG_SET_SHELL: u32 = 12;
/// The battery's brightness cap (plan 0012 D10): permille of the range
/// above the floor, 1000 = none.
pub const MSG_LIGHT_CAP: u32 = 18;

const ID_LEN: usize = 64;
const HEADER_LEN: usize = 8;
const APP_STATE_LEN: usize = 4 + 4 + ID_LEN;

/// How long to wait between connection attempts: the compositor may
/// start after vrxhost, or restart under it.
const RETRY: Duration = Duration::from_millis(500);

/// The last brightness cap ordered, re-sent when the link reconnects.
pub static LIGHT_CAP: std::sync::atomic::AtomicU32 =
    std::sync::atomic::AtomicU32::new(1000);

/// An app's state at the compositor (vrx_ipc.h `enum vrx_app_state`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AppState {
    /// Disconnected.
    Gone,
    /// Registered: connected and sized.
    Registered,
    /// Its first frame is on the panel: the UI is up.
    Shown,
}

/// What the link reports.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LinkEvent {
    /// Connected and accepted as controller. Whatever focus vrxhost
    /// wants must be (re)sent now: a restarted compositor knows none.
    Connected,
    /// An app's state at the compositor changed.
    App {
        pid: u32,
        state: AppState,
        id: String,
    },
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

/// What vrxhost tells the compositor.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Control {
    /// Focus the app with this pid (0 = none).
    Focus(u32),
    /// The app with this pid is the shell (0 = none).
    Shell(u32),
    /// Cap the brightness at this share of the range above the floor
    /// (permille; 1000 lifts it). The battery's WARN zone.
    LightCap(u32),
}

impl Control {
    /// The message on the wire.
    pub fn encode(self) -> Vec<u8> {
        let (kind, pid) = match self {
            Control::Focus(pid) => (MSG_SET_FOCUS, pid),
            Control::Shell(pid) => (MSG_SET_SHELL, pid),
            Control::LightCap(permille) => {
                return encode(MSG_LIGHT_CAP, &permille.min(1000).to_ne_bytes())
            }
        };
        encode(kind, &i32::try_from(pid).unwrap_or(0).to_ne_bytes())
    }
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
    let state = match word(HEADER_LEN + 4)? {
        0 => AppState::Gone,
        1 => AppState::Registered,
        2 => AppState::Shown,
        _ => return None,
    };
    let raw = msg.get(HEADER_LEN + 8..HEADER_LEN + 8 + ID_LEN)?;
    let end = raw.iter().position(|&b| b == 0).unwrap_or(ID_LEN);
    let id = String::from_utf8_lossy(&raw[..end]).into_owned();
    Some(LinkEvent::App {
        pid: u32::try_from(pid).ok()?,
        state,
        id,
    })
}

/// Run the link forever: connect (retrying), declare control, then
/// forward focus and shell orders from `control` and report events on
/// `events`.
/// Returns only when vrxhost drops either channel.
pub async fn run(
    socket: PathBuf,
    mut control: mpsc::UnboundedReceiver<Control>,
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
        // a cap set before a compositor restart still holds
        let cap = LIGHT_CAP.load(std::sync::atomic::Ordering::Relaxed);
        if cap < 1000 && send(&fd, &Control::LightCap(cap).encode()).await.is_err() {
            tokio::time::sleep(RETRY).await;
            continue;
        }
        if events.send(LinkEvent::Connected).is_err() {
            return;
        }
        let ended = serve(&fd, &mut control, &events).await;
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
    control: &mut mpsc::UnboundedReceiver<Control>,
    events: &mpsc::UnboundedSender<LinkEvent>,
) -> Served {
    let mut buf = [0u8; 512];
    loop {
        tokio::select! {
            order = control.recv() => {
                let Some(order) = order else { return Served::ChannelClosed };
                if let Err(err) = send(fd, &order.encode()).await {
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

    fn app_state(pid: i32, state: u32, id: &str) -> Vec<u8> {
        let mut payload = Vec::new();
        payload.extend_from_slice(&pid.to_ne_bytes());
        payload.extend_from_slice(&state.to_ne_bytes());
        let mut name = [0u8; ID_LEN];
        name[..id.len()].copy_from_slice(id.as_bytes());
        payload.extend_from_slice(&name);
        encode(MSG_APP_STATE, &payload)
    }

    #[test]
    fn the_wire_matches_vrx_ipc_h() {
        // struct vrx_msg_header {u32 type; u32 length} + int32_t pid
        let msg = Control::Focus(412).encode();
        assert_eq!(msg.len(), 12);
        assert_eq!(&msg[0..4], &10u32.to_ne_bytes());
        assert_eq!(&msg[4..8], &4u32.to_ne_bytes());
        assert_eq!(&msg[8..12], &412i32.to_ne_bytes());
        // struct vrx_msg_set_shell {int32_t pid}
        let msg = Control::Shell(77).encode();
        assert_eq!(&msg[0..4], &12u32.to_ne_bytes());
        assert_eq!(&msg[4..8], &4u32.to_ne_bytes());
        assert_eq!(&msg[8..12], &77i32.to_ne_bytes());
        // struct vrx_msg_app_state {int32 pid; u32 state; char id[64]}
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
                state: AppState::Registered,
                id: "launcher".into()
            })
        );
        assert_eq!(
            decode(&app_state(394, 0, "launcher")),
            Some(LinkEvent::App {
                pid: 394,
                state: AppState::Gone,
                id: "launcher".into()
            })
        );
        let truncated = &app_state(1, 1, "a")[..20];
        assert_eq!(decode(truncated), None);
        assert_eq!(decode(&encode(MSG_SET_FOCUS, &[0; 4])), None);
        assert_eq!(decode(&[]), None);
    }
}
