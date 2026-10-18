// vrx-manage: the management page and its JSON API (plan 0008 Part G),
// served while vrx-manage.service runs. The Manage applet starts and
// stops it (the serve grant); it stops itself after ten minutes in which
// nobody asked for anything, which closes the port. Port 80 comes from
// the unit's CAP_NET_BIND_SERVICE: no socket handed over, no unsafe.
//
// The contract is evrx-rt's docs/47-management-api.md: HTTP/1.1 with
// Connection: close on every answer, one request per connection, GET and
// HEAD, the Host check before the path, no CORS, a 5 s deadline to the
// end of the head and 20 s for the whole connection, two at a time. One
// exception (plan 0016 D11): a POST of an update bundle to /api/update,
// which has the time a large body needs (upload.rs, http.rs).

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
use vrx_manage::{api, files, http, upload};

const HEAD_DEADLINE: Duration = Duration::from_secs(5);
const CONN_DEADLINE: Duration = Duration::from_secs(20);
const CONNS: usize = 2;
/// An upload ends if the client sends nothing for this long, or runs past
/// the whole deadline.
const UPLOAD_STALL: Duration = Duration::from_secs(15);
const UPLOAD_DEADLINE: Duration = Duration::from_secs(30 * 60);

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

/// The pairing secret this run answers (SEC-03, review 2026-10-17): the
/// management page serves the journal and a 2 GiB write slot, and before
/// this any host on the LAN could use them. vrx-manage prints a 6-digit
/// pairing code at start and every request must carry it
/// (X-Vrx-Pairing). The idle stop still closes the port whatever peers
/// send: the code gates requests, not the timer.
fn pairing_code() -> String {
    let mut buf = [0u8; 4];
    getrandom_fill(&mut buf);
    let n = u32::from_le_bytes(buf) % 1_000_000;
    format!("{n:06}")
}

fn getrandom_fill(buf: &mut [u8]) {
    // no getrandom crate: read the device where it exists (Linux), else a
    // time/pid mix (a host test — never a device)
    if let Ok(mut f) = std::fs::File::open("/dev/urandom") {
        use std::io::Read;
        let _ = f.read_exact(buf);
    } else {
        let t = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.subsec_nanos())
            .unwrap_or(0);
        let pid = std::process::id();
        for (i, b) in buf.iter_mut().enumerate() {
            *b = ((t >> (i * 8)) as u8) ^ (pid as u8) ^ (i as u8).wrapping_mul(31);
        }
    }
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> ExitCode {
    tracing_subscriber::fmt().with_target(false).init();
    let port: u16 = env_or("VRX_MANAGE_PORT", 80);
    let idle = Duration::from_secs(env_or("VRX_MANAGE_IDLE", 600));
    let code = std::sync::Arc::new(pairing_code());
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
    // the pairing code is the journal's too: the person reads it from the
    // console or the journal, and it changes every start
    eprintln!("vrx-manage: pairing code {code}  (send it as the X-Vrx-Pairing header)");
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
        let mut left = idle.saturating_sub(quiet);
        if left.is_zero() && slots.available_permits() < CONNS {
            // an upload still running keeps the server up
            left = Duration::from_secs(1);
        } else if left.is_zero() {
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
                let code = code.clone();
                tokio::spawn(async move {
                    serve(stream, &root, peer, &code).await;
                    drop(permit);
                });
            }
            () = tokio::time::sleep(left) => {}
        }
    }
}

/// Read up to the blank line: the head and the body bytes read past it, or
/// the status that ends it (None: close without an answer).
async fn read_head(stream: &mut TcpStream) -> Result<(Vec<u8>, Vec<u8>), Option<u16>> {
    let mut buf = Vec::with_capacity(512);
    let mut chunk = [0u8; 512];
    let deadline = tokio::time::Instant::now() + HEAD_DEADLINE;
    loop {
        if let Some(end) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            let rest = buf.split_off(end + 4);
            buf.truncate(end);
            return Ok((buf, rest));
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
            403 => "An upload needs the page's X-Vrx-Upload header.",
            405 => {
                "Only GET and HEAD are answered, and a POST of an update to /api/update."
            }
            406 => "The page is sent gzipped; this client does not accept gzip.",
            408 => "The request did not arrive in time.",
            411 => "An upload needs a Content-Length.",
            413 => "That is larger than an update can be.",
            421 => "This host name is not this device.",
            431 => "The request's head is too long.",
            507 => "There is not enough room on the device for that update.",
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
        p if p == http::UPLOAD_PATH => {
            // what an upload may be now, for the page's update section
            let max = env_or("VRX_MANAGE_UPLOAD_MAX", upload::MAX);
            let dir = env_or("VRX_MANAGE_UPDATES", upload::UPDATES.to_owned());
            let df = output("df", &["-kP", &dir]).await;
            Reply::json(
                200,
                &json!({
                    "max_bytes": max,
                    "largest_bytes": upload::largest(max, api::df_avail_kb(&df)),
                }),
            )
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

/// Receive an update bundle into upload::UPDATES: `rest` is what came
/// with the head, the remainder is read to `length` bytes, then renamed
/// into place whole. Any failure removes the part.
async fn receive_upload(stream: &mut TcpStream, length: u64, rest: Vec<u8>) -> Reply {
    let max = env_or("VRX_MANAGE_UPLOAD_MAX", upload::MAX);
    let dir = PathBuf::from(env_or("VRX_MANAGE_UPDATES", upload::UPDATES.to_owned()));
    let df = output("df", &["-kP", &dir.to_string_lossy()]).await;
    if let Some(status) = upload::refusal(length, max, api::df_avail_kb(&df)) {
        return Reply::refusal(status);
    }
    // INT-13 (review 2026-10-17): every upload lands in its OWN part file,
    // created new — two concurrent uploads (a retry racing a stalled
    // first) wrote one shared file and could store a corrupt bundle.
    let uniq = std::process::id() ^ (std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.subsec_nanos())
        .unwrap_or(0));
    let part = dir.join(format!("{}.part-{}", upload::NAME, uniq));
    let received =
        tokio::time::timeout(UPLOAD_DEADLINE, receive(stream, &part, length, rest)).await;
    let status = match received {
        Ok(Ok(())) => match std::fs::rename(&part, dir.join(upload::NAME)) {
            Ok(()) => {
                tracing::info!(bytes = length, "update bundle received");
                return Reply::json(
                    200,
                    &json!({ "stored": upload::NAME, "bytes": length }),
                );
            }
            Err(err) => {
                // CLN-01 (review 2026-10-17): the browser saw a 500 with
                // no line anywhere saying why
                tracing::error!(error = %err, "update bundle: rename into place failed");
                500
            }
        },
        Ok(Err(status)) => status,
        Err(_) => 408,
    };
    let _ = std::fs::remove_file(&part);
    Reply::refusal(status)
}

async fn receive(
    stream: &mut TcpStream,
    part: &Path,
    length: u64,
    mut rest: Vec<u8>,
) -> Result<(), u16> {
    use std::io::Write;
    let mut file = std::fs::File::create(part).map_err(|_| 500u16)?;
    rest.truncate(
        usize::try_from(length)
            .unwrap_or(usize::MAX)
            .min(rest.len()),
    );
    file.write_all(&rest).map_err(|_| 507u16)?;
    let mut got = rest.len() as u64;
    let mut buf = vec![0u8; 64 * 1024];
    while got < length {
        let want = usize::try_from(length - got)
            .unwrap_or(usize::MAX)
            .min(buf.len());
        match tokio::time::timeout(UPLOAD_STALL, stream.read(&mut buf[..want])).await {
            Ok(Ok(0)) | Ok(Err(_)) => return Err(400),
            Ok(Ok(n)) => {
                file.write_all(&buf[..n]).map_err(|_| 507u16)?;
                got += n as u64;
            }
            Err(_) => return Err(408),
        }
    }
    file.sync_all().map_err(|_| 500u16)
}

fn constant_eq(a: &str, b: &str) -> bool {
    if a.len() != b.len() {
        return false;
    }
    a.bytes()
        .zip(b.bytes())
        .fold(0u8, |acc, (x, y)| acc | (x ^ y))
        == 0
}

async fn serve(
    mut stream: TcpStream,
    root: &Path,
    peer: std::net::SocketAddr,
    code: &str,
) {
    let started = tokio::time::Instant::now();
    let (reply, head_only) = match read_head(&mut stream).await {
        Err(None) => return,
        Err(Some(status)) => (Reply::refusal(status), false),
        Ok((head, rest)) => {
            // every request names the pairing code; a wrong or missing
            // code is a 401 that says so and writes nothing
            let head_text = String::from_utf8_lossy(&head);
            let sent = head_text
                .lines()
                .find_map(|l| {
                    let (name, value) = l.split_once(':')?;
                    name.eq_ignore_ascii_case("x-vrx-pairing")
                        .then(|| value.trim().to_owned())
                })
                .unwrap_or_default();
            if !constant_eq(&sent, code) {
                tracing::warn!(%peer, "wrong pairing code");
                (Reply::refusal(401), false)
            } else {
                match http::parse(&head, &hostname()) {
                Ok(req) if req.method == http::Method::Post => {
                    (receive_upload(&mut stream, req.length, rest).await, false)
                }
                Ok(req) => {
                    match tokio::time::timeout_at(started + CONN_DEADLINE, answer(&req, root))
                        .await
                    {
                        Ok(reply) => (reply, req.method == http::Method::Head),
                        Err(_) => {
                            tracing::debug!(%peer, "connection over its 20 s");
                            return;
                        }
                    }
                }
                Err(http::Refusal(status)) => (Reply::refusal(status), false),
                }
            }
        }
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
