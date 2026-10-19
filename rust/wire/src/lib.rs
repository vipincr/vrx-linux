//! The Varlink server skeleton `io.vrx.Host` and `io.vrx.Matter` share
//! (review 2026-10-17, KRN-04): bind over a stale socket, accept with
//! retry (one bad accept does not end the server), connections bounded
//! by the fd limit, each connection handled on its own task. What an
//! interface answers is its daemon's; this crate carries only the loop,
//! written once instead of as two drifting copies.
//!
//! vrx-protocol stays pure types (KRN-08): the skeleton that needs
//! tokio and zlink lives here, beside it, not inside it.

use std::future::Future;
use std::path::Path;

/// Serve until the listener fails.
///
/// `name` is the interface's, for the log lines. `socket_mode` is applied
/// to the socket after the bind (vrx-matter's is group-writable; the
/// host's directory already gates who may connect).
///
/// The accept-error and bounding policy is the skeleton's, not the
/// caller's: a peer that opens sockets to exhaust the daemon is refused
/// by the permit (a eighth of the fd limit, at least 16), and the server
/// outlives one bad accept (MEM-06).
pub async fn serve<S, F, Fut>(
    socket: &Path,
    name: &str,
    socket_mode: Option<u32>,
    ctx: S,
    handle: F,
) -> std::io::Result<()>
where
    S: Clone + Send + 'static,
    F: Fn(zlink::tokio::unix::Connection, S) -> Fut + Send + Sync + Clone + 'static,
    Fut: Future<Output = ()> + Send + 'static,
{
    // a stale socket from a previous run would fail the bind
    let _ = std::fs::remove_file(socket);
    let mut listener = zlink::tokio::unix::bind(socket).map_err(std::io::Error::other)?;
    if let Some(mode) = socket_mode {
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(socket, std::fs::Permissions::from_mode(mode))?;
        }
        #[cfg(not(unix))]
        let _ = mode;
    }
    tracing::info!(socket = %socket.display(), "{name} listening");
    let max_conns = std::fs::read_to_string("/proc/sys/fs/nr_open")
        .ok()
        .and_then(|t| t.trim().parse::<usize>().ok())
        .map(|n| n / 8)
        .unwrap_or(256)
        .max(16);
    let sem = std::sync::Arc::new(tokio::sync::Semaphore::new(max_conns));
    tracing::info!(max_conns, "{name} connection bound");
    loop {
        let conn = match zlink::Listener::accept(&mut listener).await {
            Ok(Some(conn)) => conn,
            Ok(None) => continue,
            // an accept error is logged and retried (MEM-06): the server
            // outlives one bad accept
            Err(err) => {
                tracing::warn!(error = %err, "{name} accept; retrying");
                tokio::time::sleep(std::time::Duration::from_millis(100)).await;
                continue;
            }
        };
        let Ok(permit) = sem.clone().acquire_owned().await else {
            continue;
        };
        let (ctx, handle) = (ctx.clone(), handle.clone());
        tokio::spawn(async move {
            handle(conn, ctx).await;
            drop(permit);
        });
    }
}
