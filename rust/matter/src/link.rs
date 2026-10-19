// io.vrx.Matter (plan 0015 D9): the one vrx interface to Matter, on
// /run/vrx-matter/io.vrx.Matter (group vrx-matter, the `matter` grant).
// The Settings applet reads the state and opens the window; vrxhost, as
// root, holds `Link` and sends `Host` and `Done` (vrx_protocol::matter).
// Varlink by hand, the way vrxhost serves io.vrx.Host.

use std::collections::HashMap;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tokio::sync::{mpsc, oneshot, watch};
use vrx_protocol::matter::{Command, HostState, LinkCommand};
use zlink::{Call, Reply};

/// How long a command waits for vrxhost's Done before it is a failure.
const DONE_BUDGET: Duration = Duration::from_secs(2);

/// How long the Bluetooth arbiter may take: it may hide Device Link's
/// window on BlueZ first.
const ARBITER_BUDGET: Duration = Duration::from_secs(5);

pub const IDL: &str = "# vrx-matter: the device on a Matter fabric (vrx plan 0015).
interface io.vrx.Matter

type Fabric (index: int, vendor_id: int, fabric_id: int, label: string)
type Endpoint (endpoint: int, applet: string, name: string)
type Exposable (applet: string, name: string, device_type: string)

# The device: commissioned (on at least one fabric), the fabrics, the
# commissioning window open and until when (unix seconds), ble: this
# window is offered over Bluetooth too (built with it, an adapter with
# its radio on, and vrxhost's arbiter agreed), and the attestation it
# carries (test or factory). With \"more\", again on every change.
method State() -> (commissioned: bool, fabrics: int, window: bool, window_until: int, ble: bool, attestation: string)

# Open the commissioning window for a home app to pair, at most 15
# minutes (the default, the spec's ceiling). On the network always, over
# Bluetooth too where State says ble.
method OpenWindow(minutes: ?int) -> ()

method CloseWindow() -> ()

# The pairing payload while a window is open: the QR code's text (its
# discovery bits say Bluetooth only while this window offers it) and the
# 11-digit manual code.
method Payload() -> (qr: string, manual: string)

method Fabrics() -> (fabrics: []Fabric)

# Leave every fabric: the device is uncommissioned and restarts.
method Forget() -> ()

# What a home app sees: the screen's endpoint and the bridged applets;
# and every applet that declares a Matter block (vrxhost's word), which
# Settings offers to expose.
method Endpoints() -> (screen: bool, applets: []Endpoint, exposable: []Exposable)

# vrxhost only (root): each reply is a command a home app gave.
method Link() -> (id: int, command: object)

# vrxhost only: a command's outcome.
method Done(id: int, ok: bool) -> ()

# vrxhost only: the screen, its brightness and the exposed set.
method Host(screen_on: bool, brightness: int, screen: bool, applets: []object) -> ()

error WindowClosed ()
error NotPermitted ()
error Unavailable (detail: string)
";

/// What the Settings applet sees (`State`).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct Status {
    pub commissioned: bool,
    pub fabrics: Vec<Fabric>,
    pub window: bool,
    pub window_until: u64,
    pub ble: bool,
    pub attestation: &'static str,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Fabric {
    pub index: u8,
    pub vendor_id: u16,
    pub fabric_id: u64,
    pub label: String,
}

/// vrxhost's arbiter agreed that vrx-matter may advertise on Bluetooth
/// (G044). Made only by [`Shared::advertise`]; the BLE transport
/// (ble.rs) takes one, so it has no way to start without the arbiter.
pub struct Grant(());

/// What the Matter thread is asked to do.
#[derive(Debug)]
pub enum Request {
    Open {
        secs: u16,
        reply: oneshot::Sender<Result<(), String>>,
    },
    Close {
        reply: oneshot::Sender<Result<(), String>>,
    },
    Forget {
        reply: oneshot::Sender<Result<(), String>>,
    },
}

/// Shared by the Varlink side and the Matter thread.
pub struct Shared {
    /// vrxhost's latest state; None until it has connected.
    pub host: watch::Sender<Option<HostState>>,
    pub status: watch::Sender<Status>,
    pub requests: mpsc::UnboundedSender<Request>,
    /// The pairing payload (fixed for this device): the QR code for the
    /// network alone, for the network and Bluetooth (a build with BLE,
    /// D5), and the manual code.
    pub qr: String,
    pub qr_ble: Option<String>,
    pub manual: String,
    pub endpoints: Value,
    /// The held Link: commands go out on it.
    link: Mutex<Option<mpsc::UnboundedSender<LinkCommand>>>,
    pending: Mutex<HashMap<u64, oneshot::Sender<bool>>>,
    next: AtomicU64,
}

impl Shared {
    pub fn new(
        requests: mpsc::UnboundedSender<Request>,
        qr: (String, Option<String>),
        manual: String,
        endpoints: Value,
    ) -> Arc<Self> {
        Arc::new(Self {
            host: watch::Sender::new(None),
            status: watch::Sender::new(Status::default()),
            requests,
            qr: qr.0,
            qr_ble: qr.1,
            manual,
            endpoints,
            link: Mutex::new(None),
            pending: Mutex::new(HashMap::new()),
            next: AtomicU64::new(1),
        })
    }

    /// Hand a command to vrxhost and wait for its outcome: false when no
    /// vrxhost holds the link, it refused, or it did not answer in time.
    pub async fn command(&self, command: Command) -> bool {
        self.command_within(command, DONE_BUDGET).await
    }

    /// Ask vrxhost's Bluetooth arbiter for the adapter for a window of
    /// `secs` (D4, G044): its yes is the only Grant there is, and the BLE
    /// transport starts only with one.
    pub async fn advertise(&self, secs: u16) -> Option<Grant> {
        self.command_within(Command::Advertise { secs }, ARBITER_BUDGET)
            .await
            .then_some(Grant(()))
    }

    /// The QR code for the window as it is: Bluetooth's bit only while
    /// this window is offered over it.
    pub fn qr_now(&self) -> &str {
        match &self.qr_ble {
            Some(qr) if self.status.borrow().ble => qr,
            _ => &self.qr,
        }
    }

    async fn command_within(&self, command: Command, budget: Duration) -> bool {
        let id = self.next.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = oneshot::channel();
        let sent = {
            let link = self
                .link
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            match link.as_ref() {
                Some(link) => {
                    self.pending
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner)
                        .insert(id, tx);
                    link.send(LinkCommand {
                        id,
                        command: command.clone(),
                    })
                    .is_ok()
                }
                None => false,
            }
        };
        if !sent {
            tracing::warn!(?command, "no vrxhost on the link; command dropped");
            return false;
        }
        let ok = matches!(tokio::time::timeout(budget, rx).await, Ok(Ok(true)));
        self.pending
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(&id);
        ok
    }

    fn done(&self, id: u64, ok: bool) {
        if let Some(tx) = self
            .pending
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(&id)
        {
            let _ = tx.send(ok);
        }
    }
}

#[derive(Debug, Deserialize)]
struct AnyMethod {
    method: String,
    #[serde(default)]
    parameters: Value,
}

#[derive(Debug, Serialize)]
struct Failure {
    error: String,
    parameters: Value,
}

impl Failure {
    fn new(name: &str, parameters: Value) -> Self {
        Self {
            error: format!("io.vrx.Matter.{name}"),
            parameters,
        }
    }

    fn invalid(parameter: &str) -> Self {
        Self {
            error: "org.varlink.service.InvalidParameter".to_owned(),
            parameters: json!({ "parameter": parameter }),
        }
    }
}

/// Serve io.vrx.Matter until the listener fails. The loop is the shared
/// skeleton (vrx_wire; KRN-04, review 2026-10-17); this interface's
/// socket is group-writable (vrx-matter; the unit's RuntimeDirectory is
/// 0750, so the group and root reach it).
pub async fn serve(socket: &Path, shared: Arc<Shared>) -> std::io::Result<()> {
    vrx_wire::serve(socket, "io.vrx.Matter", Some(0o660), shared, |conn, shared| handle(conn, shared)).await
}

async fn handle(mut conn: zlink::tokio::unix::Connection, shared: Arc<Shared>) {
    let root = conn
        .peer_credentials()
        .await
        .is_ok_and(|c| c.unix_user_id().as_raw() == 0);
    loop {
        let (call, _fds) = match conn.receive_call::<AnyMethod>().await {
            Ok(call) => call,
            Err(_) => return,
        };
        let call: Call<AnyMethod> = call;
        let method = call.method().method.clone();
        let params = call.method().parameters.clone();
        let more = call.more();
        if more && method == "io.vrx.Matter.Link" {
            if root {
                link(conn, &shared).await;
            } else {
                let _ = conn
                    .send_error(&Failure::new("NotPermitted", json!({})), Vec::new())
                    .await;
            }
            return;
        }
        if more && method == "io.vrx.Matter.State" {
            watch_state(&mut conn, shared.status.subscribe()).await;
            return;
        }
        let answer = dispatch(&shared, root, &method, &params).await;
        if call.oneway() {
            continue;
        }
        let sent = match answer {
            Ok(value) => conn.send_reply(&Reply::new(Some(value)), Vec::new()).await,
            Err(failure) => conn.send_error(&failure, Vec::new()).await,
        };
        if sent.is_err() {
            return;
        }
    }
}

/// Hold vrxhost's Link: every command becomes a reply that continues. A
/// newer Link replaces this one.
async fn link(mut conn: zlink::tokio::unix::Connection, shared: &Shared) {
    let (tx, mut rx) = mpsc::unbounded_channel();
    *shared
        .link
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(tx);
    tracing::info!("vrxhost holds the link");
    while let Some(command) = rx.recv().await {
        let reply = Reply::new(Some(command)).set_continues(Some(true));
        if conn.send_reply(&reply, Vec::new()).await.is_err() {
            break;
        }
    }
    // CON-07 (review 2026-10-17): the link's state dies with the link —
    // it stayed registered after vrxhost left, Reachable kept answering
    // true, and every command sent in that window was "carried out"
    // while nothing listened
    let _ = shared.host.send_replace(None);
    tracing::info!("vrxhost left the link");
}

async fn watch_state(
    conn: &mut zlink::tokio::unix::Connection,
    mut status: watch::Receiver<Status>,
) {
    loop {
        let now = status.borrow_and_update().clone();
        let reply = Reply::new(Some(state_json(&now))).set_continues(Some(true));
        if conn.send_reply(&reply, Vec::new()).await.is_err()
            || status.changed().await.is_err()
        {
            return;
        }
    }
}

fn state_json(s: &Status) -> Value {
    json!({
        "commissioned": s.commissioned,
        "fabrics": s.fabrics.len(),
        "window": s.window,
        "window_until": s.window_until,
        "ble": s.ble,
        "attestation": s.attestation,
    })
}

async fn ask(
    shared: &Shared,
    make: impl FnOnce(oneshot::Sender<Result<(), String>>) -> Request,
) -> Result<Value, Failure> {
    let (tx, rx) = oneshot::channel();
    let unavailable =
        |detail: String| Failure::new("Unavailable", json!({ "detail": detail }));
    shared
        .requests
        .send(make(tx))
        .map_err(|_| unavailable("the Matter stack stopped".into()))?;
    match rx.await {
        Ok(Ok(())) => Ok(json!({})),
        Ok(Err(detail)) => Err(unavailable(detail)),
        Err(_) => Err(unavailable("the Matter stack stopped".into())),
    }
}

async fn dispatch(
    shared: &Shared,
    root: bool,
    method: &str,
    params: &Value,
) -> Result<Value, Failure> {
    match method {
        "io.vrx.Matter.State" => Ok(state_json(&shared.status.borrow())),
        "io.vrx.Matter.OpenWindow" => {
            let minutes = match params.get("minutes") {
                None | Some(Value::Null) => 15,
                Some(v) => v
                    .as_u64()
                    .filter(|m| (1..=15).contains(m))
                    .ok_or_else(|| Failure::invalid("minutes"))?,
            };
            let secs = u16::try_from(minutes * 60).unwrap_or(900);
            ask(shared, |reply| Request::Open { secs, reply }).await
        }
        "io.vrx.Matter.CloseWindow" => {
            ask(shared, |reply| Request::Close { reply }).await
        }
        "io.vrx.Matter.Payload" => {
            if !shared.status.borrow().window {
                return Err(Failure::new("WindowClosed", json!({})));
            }
            Ok(json!({ "qr": shared.qr_now(), "manual": shared.manual }))
        }
        "io.vrx.Matter.Fabrics" => {
            Ok(json!({ "fabrics": shared.status.borrow().fabrics }))
        }
        "io.vrx.Matter.Forget" => ask(shared, |reply| Request::Forget { reply }).await,
        "io.vrx.Matter.Endpoints" => {
            let mut endpoints = shared.endpoints.clone();
            endpoints["exposable"] = json!(shared
                .host
                .borrow()
                .as_ref()
                .map(|h| h.exposable.clone())
                .unwrap_or_default());
            Ok(endpoints)
        }
        "io.vrx.Matter.Done" | "io.vrx.Matter.Host" | "io.vrx.Matter.Link" if !root => {
            Err(Failure::new("NotPermitted", json!({})))
        }
        "io.vrx.Matter.Done" => {
            let id = params
                .get("id")
                .and_then(Value::as_u64)
                .ok_or_else(|| Failure::invalid("id"))?;
            let ok = params
                .get("ok")
                .and_then(Value::as_bool)
                .ok_or_else(|| Failure::invalid("ok"))?;
            shared.done(id, ok);
            Ok(json!({}))
        }
        "io.vrx.Matter.Host" => {
            let state: HostState = serde_json::from_value(params.clone())
                .map_err(|_| Failure::invalid("state"))?;
            shared.host.send_replace(Some(state));
            Ok(json!({}))
        }
        "org.varlink.service.GetInfo" => Ok(json!({
            "vendor": "vrx",
            "product": "vrx-matter",
            "version": env!("CARGO_PKG_VERSION"),
            "url": "https://github.com/vipincr/vrx-linux",
            "interfaces": ["org.varlink.service", "io.vrx.Matter"],
        })),
        "org.varlink.service.GetInterfaceDescription" => {
            match params.get("interface").and_then(Value::as_str) {
                Some("io.vrx.Matter") => Ok(json!({ "description": IDL })),
                Some(other) => Err(Failure {
                    error: "org.varlink.service.InterfaceNotFound".into(),
                    parameters: json!({ "interface": other }),
                }),
                None => Err(Failure::invalid("interface")),
            }
        }
        other => Err(Failure {
            error: "org.varlink.service.MethodNotFound".into(),
            parameters: json!({ "method": other }),
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn shared() -> (Arc<Shared>, mpsc::UnboundedReceiver<Request>) {
        let (tx, rx) = mpsc::unbounded_channel();
        (
            Shared::new(
                tx,
                ("MT:X".into(), Some("MT:B".into())),
                "34970112332".into(),
                json!({}),
            ),
            rx,
        )
    }

    /// vrxhost's methods are root's alone; the payload only while a window
    /// is open.
    #[tokio::test]
    async fn the_host_methods_are_roots_and_the_payload_needs_a_window() {
        let (s, _rx) = shared();
        for m in ["io.vrx.Matter.Done", "io.vrx.Matter.Host"] {
            let err = dispatch(&s, false, m, &json!({})).await.unwrap_err();
            assert_eq!(err.error, "io.vrx.Matter.NotPermitted", "{m}");
        }
        let err = dispatch(&s, false, "io.vrx.Matter.Payload", &json!({}))
            .await
            .unwrap_err();
        assert_eq!(err.error, "io.vrx.Matter.WindowClosed");
        s.status.send_modify(|st| st.window = true);
        let ok = dispatch(&s, false, "io.vrx.Matter.Payload", &json!({}))
            .await
            .unwrap();
        assert_eq!(ok["manual"], "34970112332");
        assert_eq!(ok["qr"], "MT:X", "no Bluetooth bit unless offered (D5)");
        s.status.send_modify(|st| st.ble = true);
        let ok = dispatch(&s, false, "io.vrx.Matter.Payload", &json!({}))
            .await
            .unwrap();
        assert_eq!(ok["qr"], "MT:B");
        let bad = dispatch(
            &s,
            false,
            "io.vrx.Matter.OpenWindow",
            &json!({ "minutes": 16 }),
        )
        .await;
        assert!(bad.is_err(), "the window is at most 15 minutes");
    }

    /// A command waits for vrxhost's Done; without a link it fails at once.
    #[tokio::test]
    async fn a_command_is_done_by_vrxhost() {
        let (s, _rx) = shared();
        assert!(!s.command(Command::Screen { on: false }).await);
        let (tx, mut out) = mpsc::unbounded_channel();
        *s.link.lock().unwrap() = Some(tx);
        let s2 = s.clone();
        let answer = tokio::spawn(async move {
            let sent = out.recv().await.unwrap();
            assert_eq!(sent.command, Command::Screen { on: false });
            dispatch(
                &s2,
                true,
                "io.vrx.Matter.Done",
                &json!({ "id": sent.id, "ok": true }),
            )
            .await
            .unwrap();
        });
        assert!(s.command(Command::Screen { on: false }).await);
        answer.await.unwrap();
    }

    /// G044: BLE starts only with a Grant, and a Grant is only vrxhost's
    /// arbiter saying yes to Advertise; no vrxhost, or a no, is none.
    #[tokio::test]
    async fn only_the_arbiter_grants_bluetooth_g044() {
        let (s, _rx) = shared();
        assert!(s.advertise(900).await.is_none(), "no vrxhost: no grant");
        let (tx, mut out) = mpsc::unbounded_channel();
        *s.link.lock().unwrap() = Some(tx);
        for verdict in [false, true] {
            let s2 = s.clone();
            let answer = tokio::spawn(async move {
                let sent = out.recv().await.unwrap();
                assert_eq!(sent.command, Command::Advertise { secs: 900 });
                dispatch(
                    &s2,
                    true,
                    "io.vrx.Matter.Done",
                    &json!({ "id": sent.id, "ok": verdict }),
                )
                .await
                .unwrap();
                out
            });
            assert_eq!(s.advertise(900).await.is_some(), verdict);
            out = answer.await.unwrap();
        }
    }
}
