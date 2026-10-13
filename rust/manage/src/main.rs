// vrx-manage: the management page and its JSON API (plan 0008 Part G),
// served while vrx-manage.service runs. The Manage applet starts and
// stops it (the serve grant); it stops itself after ten minutes in which
// nobody asked for anything, which closes the port. Port 80 comes from
// the unit's CAP_NET_BIND_SERVICE: no socket handed over, no unsafe.
//
// The contract is evrx-rt's docs/47-management-api.md: HTTP/1.1 with
// Connection: close on every answer, one request per connection, GET and
// HEAD, the Host check before the path, no CORS, a 5 s deadline to the
// end of the head and 20 s for the whole connection, two at a time.

#![deny(unsafe_code)]

use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use serde_json::{json, Value};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::Semaphore;
use vrx_manage::{api, files, http};

const HEAD_DEADLINE: Duration = Duration::from_secs(5);
const CONN_DEADLINE: Duration = Duration::from_secs(20);
const CONNS: usize = 2;

fn env_or<T: std::str::FromStr>(name: &str, default: T) -> T {
    std::env::var(name)
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
}

fn hostname() -> String {
    std::fs::read_to_string("/proc/sys/kernel/hostname")
        .map(|h| h.trim().to_owned())
        .unwrap_or_default()
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> ExitCode {
    tracing_subscriber::fmt().with_target(false).init();
    let port: u16 = env_or("VRX_MANAGE_PORT", 80);
    let idle = Duration::from_secs(env_or("VRX_MANAGE_IDLE", 600));
    let root = PathBuf::from(env_or(
        "VRX_MANAGE_ROOT",
        String::from("/usr/share/vrx/manage-ui"),
    ));
    let listener = match TcpListener::bind(("0.0.0.0", port)).await {
        Ok(l) => l,
        Err(err) => {
            tracing::error!(port, error = %err, "cannot listen");
            return ExitCode::FAILURE;
        }
    };
    tracing::info!(port, root = %root.display(), idle_s = idle.as_secs(), "serving the management page");
    let start = Instant::now();
    // seconds since start of the last request, for the idle stop
    let last = Arc::new(AtomicU64::new(0));
    let slots = Arc::new(Semaphore::new(CONNS));
    let root = Arc::new(root);
    loop {
        let quiet = Duration::from_secs(
            start
                .elapsed()
                .as_secs()
                .saturating_sub(last.load(Ordering::Relaxed)),
        );
        let left = idle.saturating_sub(quiet);
        if left.is_zero() {
            tracing::info!(idle_s = idle.as_secs(), "nobody asked: stopping");
            return ExitCode::SUCCESS;
        }
        tokio::select! {
            accepted = listener.accept() => {
                let Ok((stream, peer)) = accepted else { continue };
                // a third waits in the backlog until a place is free
                let Ok(permit) = slots.clone().acquire_owned().await else { continue };
                last.store(start.elapsed().as_secs(), Ordering::Relaxed);
                let root = root.clone();
                tokio::spawn(async move {
                    if tokio::time::timeout(CONN_DEADLINE, serve(stream, &root)).await.is_err() {
                        tracing::debug!(%peer, "connection over its 20 s");
                    }
                    drop(permit);
                });
            }
            () = tokio::time::sleep(left) => {}
        }
    }
}

/// Read up to the blank line: the head, or the status that ends it (None:
/// close without an answer).
async fn read_head(stream: &mut TcpStream) -> Result<Vec<u8>, Option<u16>> {
    let mut buf = Vec::with_capacity(512);
    let mut chunk = [0u8; 512];
    let deadline = tokio::time::Instant::now() + HEAD_DEADLINE;
    loop {
        if let Some(end) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            buf.truncate(end);
            return Ok(buf);
        }
        if buf.len() > http::HEAD_MAX {
            return Err(Some(431));
        }
        match tokio::time::timeout_at(deadline, stream.read(&mut chunk)).await {
            Ok(Ok(0)) | Ok(Err(_)) => return Err(None),
            Ok(Ok(n)) => buf.extend_from_slice(&chunk[..n]),
            // nothing sent: closed without an answer; part of one: 408
            Err(_) => return Err(if buf.is_empty() { None } else { Some(408) }),
        }
    }
}

struct Reply {
    status: u16,
    content_type: &'static str,
    body: Vec<u8>,
    gzip: bool,
    no_store: bool,
}

impl Reply {
    fn json(status: u16, value: &Value) -> Self {
        Self {
            status,
            content_type: "application/json; charset=utf-8",
            body: value.to_string().into_bytes(),
            gzip: false,
            no_store: true,
        }
    }

    fn refusal(status: u16) -> Self {
        let sentence = match status {
            404 => "There is nothing here.",
            405 => "Only GET and HEAD are answered.",
            406 => "The page is sent gzipped; this client does not accept gzip.",
            408 => "The request did not arrive in time.",
            421 => "This host name is not this device.",
            431 => "The request's head is too long.",
            _ => http::reason(status),
        };
        Self::json(status, &json!({ "error": sentence }))
    }
}

async fn output(cmd: &str, args: &[&str]) -> String {
    tokio::process::Command::new(cmd)
        .args(args)
        .output()
        .await
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_default()
}

async fn answer(req: &http::Request, root: &Path) -> Reply {
    match req.path.as_str() {
        "/api/status" => {
            let df = output("df", &["-kP", "/data"]).await;
            let ip = output("ip", &["-o", "-4", "addr", "show", "scope", "global"]).await;
            Reply::json(
                200,
                &api::status(
                    Path::new("/"),
                    &hostname(),
                    api::df_total_kb(&df),
                    &api::links(&ip),
                ),
            )
        }
        "/api/log" => {
            let n = api::lines_wanted(&req.query).to_string();
            let journal =
                output("journalctl", &["-o", "json", "-n", &n, "-q", "--no-pager"]).await;
            Reply::json(200, &api::log(&journal))
        }
        p if p == "/api" || p.starts_with("/api/") => Reply::refusal(404),
        p => match files::find(root, p, req.accepts_gzip) {
            files::Answer::File { path, content_type } => {
                // a page file is tens of kB: read in place
                match std::fs::read(&path) {
                    Ok(body) => Reply {
                        status: 200,
                        content_type,
                        body,
                        gzip: true,
                        no_store: false,
                    },
                    Err(_) => Reply::refusal(404),
                }
            }
            files::Answer::NotFound => Reply::refusal(404),
            files::Answer::NotAcceptable => Reply::refusal(406),
        },
    }
}

async fn serve(mut stream: TcpStream, root: &Path) {
    let (reply, head_only) = match read_head(&mut stream).await {
        Err(None) => return,
        Err(Some(status)) => (Reply::refusal(status), false),
        Ok(head) => match http::parse(&head, &hostname()) {
            Ok(req) => (answer(&req, root).await, req.method == http::Method::Head),
            Err(http::Refusal(status)) => (Reply::refusal(status), false),
        },
    };
    let mut out = format!(
        "HTTP/1.1 {} {}\r\nContent-Type: {}\r\nContent-Length: {}\r\nConnection: close\r\n",
        reply.status,
        http::reason(reply.status),
        reply.content_type,
        reply.body.len()
    );
    if reply.gzip {
        out.push_str("Content-Encoding: gzip\r\nVary: Accept-Encoding\r\n");
    }
    if reply.no_store {
        out.push_str("Cache-Control: no-store\r\n");
    }
    if reply.status == 405 {
        out.push_str("Allow: GET, HEAD\r\n");
    }
    out.push_str("\r\n");
    let mut bytes = out.into_bytes();
    if !head_only {
        bytes.extend_from_slice(&reply.body);
    }
    if stream.write_all(&bytes).await.is_err() {
        return;
    }
    let _ = stream.shutdown().await;
    // read and drop what the client sent after its request, so the close
    // is not a reset that takes the answer with it
    let mut sink = [0u8; 512];
    let _ = tokio::time::timeout(Duration::from_millis(200), async {
        while matches!(stream.read(&mut sink).await, Ok(n) if n > 0) {}
    })
    .await;
}
