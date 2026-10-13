// vrxhost's interface, `io.vrx.Host`, on Varlink (plan 0008 D8): the
// protocol systemd chooses for new system interfaces. JSON objects,
// NUL-terminated, on a unix socket (`/run/vrx/io.vrx.Host`, group vrx);
// `varlinkctl` can introspect and call it. The caller is the socket
// peer's pid, mapped to its applet through its cgroup.

use std::path::Path;
use std::sync::Arc;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tokio::sync::{mpsc, oneshot, watch};
use vrx_protocol::{Intent, Registry};
use zlink::{Call, Reply};

use crate::applets::applet_of_pid;
use crate::bridge::{Bridge, Delivery, ANSWER_BUDGET};
use crate::intent::{handlers, Handler};
use crate::session::{NavError, NavOp};

pub const INTERFACE: &str = "io.vrx.Host";

/// The interface description, served by GetInterfaceDescription.
pub const IDL: &str = "# vrxhost, the vrx applet OS daemon: the back trail, the registry, intents.
interface io.vrx.Host

type Applet (id: string, name: string, icon: ?string, position: int)

# One declared setting (plan 0008 D5): its value lives in
# /etc/vrx/settings/<applet>.conf as key=value; default is JSON.
type Setting (key: string, label: string, category: string, type: string, default: object, options: ?[]string)

type AppletSettings (id: string, name: string, settings: []Setting)

# Push an applet onto the back trail at a named route; it starts if it is not running.
method Push(applet: string, route: ?string) -> (top: string)

# Pop one trail entry; an empty trail goes Home.
method Pop() -> (top: string)

# Clear the trail to the home applet.
method Home() -> (top: string)

# Route an intent: handlers in priority order; an opened one is pushed at
# its route (and, running, told over its Listen); a told one is asked over
# its Listen and has 100 ms to Answer. verdict: opened, handled or pass.
method Intent(name: string, payload: ?object) -> (verdict: string, handled_by: ?string, route: ?int)

# Held with \"more\" by a running applet (plan 0008 D15): each reply is an
# intent it handles (kind \"intent\"; with an id, Answer it) or a channel
# another applet opened on it (kind \"channel\"; the stream's end rides as
# a file descriptor). The newest Listen of an applet wins.
method Listen() -> (kind: string, id: ?int, name: ?string, payload: ?object, from: ?string, channel: ?string)

# The answer to an intent a Listen asked about: handled or pass.
method Answer(id: int, verdict: string) -> ()

# Open a channel another applet offers (its manifest's channels.offers;
# yours must list <to>.<channel> in channels.opens): a stream socket, one
# end in the reply as a file descriptor, the other handed to that applet's
# Listen. A descriptor sent with the call is handed instead, and the reply
# carries none: a dmabuf, or a memfd sealed against shrinking (anything else
# is NotShareable). A buffer queue passes its buffers over the stream itself.
method Open(to: string, channel: string) -> ()

# The applets the launcher shows (display.tile), in position order.
method Applets() -> (applets: []Applet)

# Every applet that declares settings, and what it declares (D5).
method Settings() -> (applets: []AppletSettings)

# The front applet and the trail depth; with \"more\", again on every change.
method Watch() -> (front: string, depth: int)

error NoSuchApplet (applet: string)
error NoSuchRoute (applet: string, route: string)
error NotOpenable (applet: string)
error Disabled (applet: string)
error NoHandler (name: string)
error NotDeclared (channel: string)
error NotOffered (applet: string, channel: string)
error NotListening (applet: string)
error NotShareable (channel: string)
error NotAnApplet ()
error Unavailable ()
";

const SERVICE_IDL: &str = "# The Varlink Service Interface is provided by every varlink service.
interface org.varlink.service

method GetInfo() -> (vendor: string, product: string, version: string, url: string, interfaces: []string)

method GetInterfaceDescription(interface: string) -> (description: string)

error InterfaceNotFound (interface: string)
error MethodNotFound (method: string)
error MethodNotImplemented (method: string)
error InvalidParameter (parameter: string)
error PermissionDenied ()
error ExpectedMore ()
";

/// A navigation request on its way to the session, with where to send
/// the answer: the applet on top afterwards, or why it was refused.
pub type NavRequest = (NavOp, oneshot::Sender<Result<String, NavError>>);

/// What `Watch` reports.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct Front {
    pub front: String,
    pub depth: u32,
}

/// Any call: the method name and its parameters, dispatched by name.
#[derive(Debug, Deserialize)]
struct AnyMethod {
    method: String,
    #[serde(default)]
    parameters: Value,
}

/// A Varlink error reply.
#[derive(Debug, Serialize)]
struct Failure {
    error: String,
    parameters: Value,
}

impl Failure {
    fn new(name: &str, parameters: Value) -> Self {
        Self {
            error: name.to_owned(),
            parameters,
        }
    }

    fn host(name: &str, parameters: Value) -> Self {
        Self::new(&format!("{INTERFACE}.{name}"), parameters)
    }

    fn invalid(parameter: &str) -> Self {
        Self::new(
            "org.varlink.service.InvalidParameter",
            json!({ "parameter": parameter }),
        )
    }

    fn from_nav(err: NavError) -> Self {
        match err {
            NavError::Unknown(applet) => {
                Self::host("NoSuchApplet", json!({ "applet": applet }))
            }
            NavError::NotOpenable(applet) => {
                Self::host("NotOpenable", json!({ "applet": applet }))
            }
            NavError::Disabled(applet) => {
                Self::host("Disabled", json!({ "applet": applet }))
            }
        }
    }
}

/// Everything a connection needs.
#[derive(Clone)]
pub struct Host {
    pub registry: Arc<Registry>,
    pub nav: mpsc::UnboundedSender<NavRequest>,
    pub front: watch::Receiver<Front>,
    pub bridge: Bridge,
}

/// Serve `io.vrx.Host` until the listener fails.
pub async fn serve(socket: &Path, host: Host) -> std::io::Result<()> {
    // a stale socket from a previous run would fail the bind
    let _ = std::fs::remove_file(socket);
    let mut listener = zlink::tokio::unix::bind(socket).map_err(std::io::Error::other)?;
    tracing::info!(socket = %socket.display(), "io.vrx.Host listening");
    loop {
        let conn = match zlink::Listener::accept(&mut listener).await {
            Ok(Some(conn)) => conn,
            Ok(None) => continue,
            Err(err) => return Err(std::io::Error::other(err)),
        };
        let host = host.clone();
        tokio::spawn(async move { handle(conn, host).await });
    }
}

async fn handle(mut conn: zlink::tokio::unix::Connection, host: Host) {
    // the caller: its applet (the cgroup of the socket peer's pid), or
    // what it is for the log
    let (applet, caller) = match conn.peer_credentials().await {
        Ok(creds) => {
            let pid =
                u32::try_from(creds.process_id().as_raw_nonzero().get()).unwrap_or(0);
            let applet = applet_of_pid(pid);
            let caller = applet.clone().unwrap_or_else(|| format!("pid {pid}"));
            (applet, caller)
        }
        Err(_) => (None, "unknown".to_owned()),
    };
    loop {
        let (call, fds) = match conn.receive_call::<AnyMethod>().await {
            Ok(call) => call,
            Err(err) => {
                tracing::debug!(%caller, error = %err, "io.vrx.Host connection ended");
                return;
            }
        };
        let call: Call<AnyMethod> = call;
        let method = call.method().method.clone();
        tracing::debug!(%caller, %method, "call");
        if method == format!("{INTERFACE}.Watch") && call.more() {
            watch_front(&mut conn, host.front.clone()).await;
            return;
        }
        if method == format!("{INTERFACE}.Listen") && call.more() {
            match applet {
                Some(applet) => listen(conn, &host.bridge, &applet).await,
                None => {
                    let _ = conn
                        .send_error(&Failure::host("NotAnApplet", json!({})), Vec::new())
                        .await;
                }
            }
            return;
        }
        if method == format!("{INTERFACE}.Open") {
            let params = call.method().parameters.clone();
            let sent = match open(&host, applet.as_deref(), &params, fds) {
                Ok(back) => conn.send_reply(&Reply::new(Some(json!({}))), back).await,
                Err(failure) => conn.send_error(&failure, Vec::new()).await,
            };
            if sent.is_err() {
                return;
            }
            continue;
        }
        let answer = dispatch(&host, &method, &call.method().parameters).await;
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

/// Hold a Listen: every delivery for `applet` becomes a reply with
/// `continues`, until the applet hangs up or a newer Listen replaces it.
async fn listen(conn: zlink::tokio::unix::Connection, bridge: &Bridge, applet: &str) {
    let (generation, mut deliveries) = bridge.listen(applet);
    tracing::info!(%applet, "listening");
    let (mut read, mut write) = conn.split();
    loop {
        tokio::select! {
            // a Listen connection carries nothing more from the applet:
            // a read that ends is the applet hanging up
            ended = read.receive_call::<AnyMethod>() => {
                if ended.is_err() {
                    break;
                }
            }
            delivery = deliveries.recv() => {
                let Some(delivery) = delivery else { break };
                let (body, fds) = match delivery {
                    Delivery::Intent { id, name, payload } => (
                        json!({ "kind": "intent", "id": id, "name": name, "payload": payload }),
                        Vec::new(),
                    ),
                    Delivery::Channel { from, channel, fd } => (
                        json!({ "kind": "channel", "from": from, "channel": channel }),
                        vec![fd],
                    ),
                };
                let reply = Reply::new(Some(body)).set_continues(Some(true));
                if write.send_reply(&reply, fds).await.is_err() {
                    break;
                }
            }
        }
    }
    bridge.unlisten(applet, generation);
    tracing::info!(%applet, "stopped listening");
}

/// Open a channel: the caller's manifest must open it and the target's
/// offer it. The descriptor that goes back to the caller, if any.
fn open(
    host: &Host,
    caller: Option<&str>,
    params: &Value,
    mut fds: Vec<std::os::fd::OwnedFd>,
) -> Result<Vec<std::os::fd::OwnedFd>, Failure> {
    let caller = caller.ok_or_else(|| Failure::host("NotAnApplet", json!({})))?;
    let to = params
        .get("to")
        .and_then(Value::as_str)
        .ok_or_else(|| Failure::invalid("to"))?;
    let channel = params
        .get("channel")
        .and_then(Value::as_str)
        .ok_or_else(|| Failure::invalid("channel"))?;
    let wanted = format!("{to}.{channel}");
    let declared = host
        .registry
        .find(caller)
        .is_some_and(|e| e.manifest.applet.channels.opens.contains(&wanted));
    if !declared {
        return Err(Failure::host("NotDeclared", json!({ "channel": wanted })));
    }
    let offered = host.registry.find(to).is_some_and(|e| {
        e.manifest
            .applet
            .channels
            .offers
            .iter()
            .any(|c| c == channel)
    });
    if !offered {
        return Err(Failure::host(
            "NotOffered",
            json!({ "applet": to, "channel": channel }),
        ));
    }
    let not_listening = || Failure::host("NotListening", json!({ "applet": to }));
    if !fds.is_empty() {
        // the caller's own descriptor (device data): handed as it came, if
        // it is a buffer the other side can safely map
        let fd = fds.swap_remove(0);
        if !crate::bridge::shareable(&fd) {
            return Err(Failure::host("NotShareable", json!({ "channel": channel })));
        }
        return if host.bridge.hand(to, caller, channel, fd) {
            Ok(Vec::new())
        } else {
            Err(not_listening())
        };
    }
    let (mine, theirs) = std::os::unix::net::UnixStream::pair()
        .map_err(|_| Failure::host("Unavailable", json!({})))?;
    if host
        .bridge
        .hand(to, caller, channel, std::os::fd::OwnedFd::from(theirs))
    {
        tracing::info!(from = %caller, %to, %channel, "channel opened");
        Ok(vec![std::os::fd::OwnedFd::from(mine)])
    } else {
        Err(not_listening())
    }
}

async fn watch_front(
    conn: &mut zlink::tokio::unix::Connection,
    mut front: watch::Receiver<Front>,
) {
    loop {
        let now = front.borrow_and_update().clone();
        let reply = Reply::new(Some(now)).set_continues(Some(true));
        if conn.send_reply(&reply, Vec::new()).await.is_err() {
            return;
        }
        if front.changed().await.is_err() {
            return;
        }
    }
}

async fn dispatch(host: &Host, method: &str, params: &Value) -> Result<Value, Failure> {
    let str_param = |name: &str| params.get(name).and_then(Value::as_str);
    match method {
        "io.vrx.Host.Push" => {
            let applet = str_param("applet").ok_or_else(|| Failure::invalid("applet"))?;
            let route = match str_param("route") {
                None | Some("") => 0,
                Some(name) => host
                    .registry
                    .find(applet)
                    .and_then(|e| e.manifest.route_number(name))
                    .ok_or_else(|| {
                        if host.registry.find(applet).is_none() {
                            Failure::host("NoSuchApplet", json!({ "applet": applet }))
                        } else {
                            Failure::host(
                                "NoSuchRoute",
                                json!({ "applet": applet, "route": name }),
                            )
                        }
                    })?,
            };
            let top = navigate(
                host,
                NavOp::Push {
                    applet: applet.to_owned(),
                    route,
                },
            )
            .await?;
            Ok(json!({ "top": top }))
        }
        "io.vrx.Host.Pop" => Ok(json!({ "top": navigate(host, NavOp::Pop).await? })),
        "io.vrx.Host.Home" => Ok(json!({ "top": navigate(host, NavOp::Home).await? })),
        "io.vrx.Host.Intent" => {
            let name = str_param("name").ok_or_else(|| Failure::invalid("name"))?;
            let payload = params.get("payload").cloned().unwrap_or(Value::Null);
            let intent =
                Intent::new(name, payload).map_err(|_| Failure::invalid("name"))?;
            deliver(host, &intent).await
        }
        "io.vrx.Host.Answer" => {
            let id = params
                .get("id")
                .and_then(Value::as_u64)
                .ok_or_else(|| Failure::invalid("id"))?;
            let handled = match str_param("verdict") {
                Some("handled") => true,
                Some("pass") => false,
                _ => return Err(Failure::invalid("verdict")),
            };
            // a late answer finds nobody waiting: the intent moved on
            host.bridge.answer(id, handled);
            Ok(json!({}))
        }
        "io.vrx.Host.Applets" => Ok(json!({ "applets": tiles(&host.registry) })),
        "io.vrx.Host.Settings" => {
            Ok(json!({ "applets": declared_settings(&host.registry) }))
        }
        "io.vrx.Host.Watch" => {
            Ok(serde_json::to_value(host.front.borrow().clone()).unwrap_or(Value::Null))
        }
        "org.varlink.service.GetInfo" => Ok(json!({
            "vendor": "vrx",
            "product": "vrxhost",
            "version": env!("CARGO_PKG_VERSION"),
            "url": "https://github.com/vipincr/vrx-linux",
            "interfaces": ["org.varlink.service", INTERFACE],
        })),
        "org.varlink.service.GetInterfaceDescription" => match str_param("interface") {
            Some(INTERFACE) => Ok(json!({ "description": IDL })),
            Some("org.varlink.service") => Ok(json!({ "description": SERVICE_IDL })),
            Some(other) => Err(Failure::new(
                "org.varlink.service.InterfaceNotFound",
                json!({ "interface": other }),
            )),
            None => Err(Failure::invalid("interface")),
        },
        other => Err(Failure::new(
            "org.varlink.service.MethodNotFound",
            json!({ "method": other }),
        )),
    }
}

/// Route an intent through its handlers in order (intent.rs): an opened
/// one is pushed (and told over its Listen when running); a told one is
/// asked and has the answer budget. The Varlink `Intent` call and
/// vrxhost's own sources (the USB watcher) share it.
async fn deliver(host: &Host, intent: &Intent) -> Result<Value, Failure> {
    let order = handlers(&host.registry, intent);
    if order.is_empty() {
        return Err(Failure::host("NoHandler", json!({ "name": intent.name })));
    }
    for handler in order {
        match handler {
            Handler::Opened { applet, route } => {
                navigate(
                    host,
                    NavOp::Push {
                        applet: applet.clone(),
                        route,
                    },
                )
                .await?;
                host.bridge.tell(&applet, &intent.name, &intent.payload);
                return Ok(
                    json!({ "verdict": "opened", "handled_by": applet, "route": route }),
                );
            }
            Handler::Told { applet } => {
                if host
                    .bridge
                    .ask(&applet, &intent.name, &intent.payload, ANSWER_BUDGET)
                    .await
                    == Some(true)
                {
                    return Ok(json!({ "verdict": "handled", "handled_by": applet }));
                }
            }
        }
    }
    tracing::debug!(intent = %intent.name, "every handler passed");
    Ok(json!({ "verdict": "pass" }))
}

/// An intent vrxhost raises itself; the outcome is logged.
pub async fn raise(host: &Host, intent: Intent) {
    match deliver(host, &intent).await {
        Ok(verdict) => tracing::info!(intent = %intent.name, %verdict, "raised"),
        Err(failure) => {
            tracing::warn!(intent = %intent.name, error = %failure.error, "raised; not handled")
        }
    }
}

async fn navigate(host: &Host, op: NavOp) -> Result<String, Failure> {
    let (tx, rx) = oneshot::channel();
    host.nav
        .send((op, tx))
        .map_err(|_| Failure::host("Unavailable", json!({})))?;
    match rx.await {
        Ok(Ok(top)) => Ok(top),
        Ok(Err(err)) => Err(Failure::from_nav(err)),
        Err(_) => Err(Failure::host("Unavailable", json!({}))),
    }
}

/// The launcher's tiles: applets with display.tile, in position order.
fn tiles(registry: &Registry) -> Vec<Value> {
    let mut tiles: Vec<_> = registry
        .iter()
        .filter_map(|e| {
            let display = e.manifest.applet.display.as_ref()?;
            display.tile.then_some((display.position, e))
        })
        .collect();
    tiles.sort_by_key(|(position, _)| *position);
    tiles
        .into_iter()
        .map(|(position, e)| {
            let applet = &e.manifest.applet;
            json!({
                "id": applet.id,
                "name": applet.name,
                "icon": applet.display.as_ref().map(|d| d.icon.clone()),
                "position": position,
            })
        })
        .collect()
}

/// Every applet that declares settings, by name, with its declarations
/// as the manifest gives them (the one parser of manifests is this one).
fn declared_settings(registry: &Registry) -> Vec<Value> {
    let mut out: Vec<_> = registry
        .iter()
        .filter(|e| !e.manifest.applet.settings.is_empty())
        .map(|e| {
            let applet = &e.manifest.applet;
            json!({ "id": applet.id, "name": applet.name, "settings": applet.settings })
        })
        .collect();
    out.sort_by(|a, b| a["name"].as_str().cmp(&b["name"].as_str()));
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::UnixStream;
    use vrx_protocol::RegistryEntry;

    fn registry() -> Registry {
        let mut r = Registry::new();
        for (id, extra) in [
            ("launcher", "\n[applet.roles]\nhome = true\n"),
            (
                "clock",
                "\n[applet.display]\nicon = \"schedule\"\ntile = true\nposition = 3\n\
                 [applet.routes]\nalarms = {}\nring = {}\n\
                 [applet.intents]\nhandles = [{ name = \"sys.alarm.ring\", priority = 900, at = \"ring\" }]\n\
                 [[applet.settings]]\nkey = \"clock_format\"\nlabel = \"Time format\"\ncategory = \"Clock\"\n\
                 type = \"enum\"\ndefault = \"24h\"\noptions = [\"12h\", \"24h\"]\n",
            ),
        ] {
            let text = format!(
                "[applet]\nid = \"{id}\"\nname = \"N\"\nversion = \"1.0.0\"\nruntime = \"flutter\"\n{extra}"
            );
            r.admit(RegistryEntry {
                manifest: text.parse().unwrap(),
                path: PathBuf::from("/system/defaults").join(id),
                builtin: true,
            })
            .unwrap();
        }
        r
    }

    /// One Varlink exchange: a call out, every reply until one does not
    /// continue.
    async fn call(stream: &mut UnixStream, msg: Value) -> Vec<Value> {
        let mut bytes = serde_json::to_vec(&msg).unwrap();
        bytes.push(0);
        stream.write_all(&bytes).await.unwrap();
        let mut replies = Vec::new();
        let mut buf = Vec::new();
        loop {
            let mut byte = [0u8; 1];
            stream.read_exact(&mut byte).await.unwrap();
            if byte[0] != 0 {
                buf.push(byte[0]);
                continue;
            }
            let reply: Value = serde_json::from_slice(&buf).unwrap();
            buf.clear();
            let more = reply["continues"] == true;
            replies.push(reply);
            if !more {
                return replies;
            }
        }
    }

    async fn started() -> (PathBuf, watch::Sender<Front>, tempfile::TempDir) {
        let dir = tempfile::tempdir().unwrap();
        let socket = dir.path().join("io.vrx.Host");
        let (nav_tx, mut nav_rx) = mpsc::unbounded_channel::<NavRequest>();
        // a stand-in session: pushes answer with the pushed applet, ghost
        // is unknown, pop/home answer "launcher"
        tokio::spawn(async move {
            while let Some((op, reply)) = nav_rx.recv().await {
                let answer = match op {
                    NavOp::Push { applet, .. } if applet == "ghost" => {
                        Err(NavError::Unknown(applet))
                    }
                    NavOp::Push { applet, .. } => Ok(applet),
                    NavOp::Pop | NavOp::Home => Ok("launcher".to_owned()),
                };
                let _ = reply.send(answer);
            }
        });
        let (front_tx, front_rx) = watch::channel(Front {
            front: "launcher".into(),
            depth: 1,
        });
        let host = Host {
            registry: Arc::new(registry()),
            nav: nav_tx,
            front: front_rx,
            bridge: Bridge::default(),
        };
        let bound = socket.clone();
        tokio::spawn(async move { serve(&bound, host).await });
        for _ in 0..100 {
            if socket.exists() {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(5)).await;
        }
        (socket, front_tx, dir)
    }

    #[tokio::test]
    async fn the_host_answers_varlink() {
        let (socket, _front, _dir) = started().await;
        let mut s = UnixStream::connect(&socket).await.unwrap();

        let r = call(&mut s, json!({"method": "io.vrx.Host.Push", "parameters": {"applet": "clock", "route": "alarms"}})).await;
        assert_eq!(r[0]["parameters"]["top"], "clock", "{r:?}");

        let r = call(&mut s, json!({"method": "io.vrx.Host.Push", "parameters": {"applet": "clock", "route": "nope"}})).await;
        assert_eq!(r[0]["error"], "io.vrx.Host.NoSuchRoute", "{r:?}");

        let r = call(
            &mut s,
            json!({"method": "io.vrx.Host.Push", "parameters": {"applet": "ghost"}}),
        )
        .await;
        assert_eq!(r[0]["error"], "io.vrx.Host.NoSuchApplet", "{r:?}");

        let r = call(
            &mut s,
            json!({"method": "io.vrx.Host.Push", "parameters": {}}),
        )
        .await;
        assert_eq!(
            r[0]["error"], "org.varlink.service.InvalidParameter",
            "{r:?}"
        );

        let r = call(&mut s, json!({"method": "io.vrx.Host.Intent", "parameters": {"name": "sys.alarm.ring"}})).await;
        assert_eq!(r[0]["parameters"]["verdict"], "opened", "{r:?}");
        assert_eq!(r[0]["parameters"]["handled_by"], "clock", "{r:?}");

        let r = call(
            &mut s,
            json!({"method": "io.vrx.Host.Intent", "parameters": {"name": "ghost.ping"}}),
        )
        .await;
        assert_eq!(r[0]["error"], "io.vrx.Host.NoHandler", "{r:?}");

        let r = call(&mut s, json!({"method": "io.vrx.Host.Applets"})).await;
        assert_eq!(r[0]["parameters"]["applets"][0]["id"], "clock", "{r:?}");

        let r = call(&mut s, json!({"method": "io.vrx.Host.Settings"})).await;
        let clock = &r[0]["parameters"]["applets"][0];
        assert_eq!(clock["id"], "clock", "{r:?}");
        assert_eq!(clock["settings"][0]["key"], "clock_format", "{r:?}");
        assert_eq!(clock["settings"][0]["type"], "enum", "{r:?}");
        assert_eq!(clock["settings"][0]["options"][1], "24h", "{r:?}");

        let r = call(&mut s, json!({"method": "io.vrx.Host.Home"})).await;
        assert_eq!(r[0]["parameters"]["top"], "launcher", "{r:?}");

        let r = call(&mut s, json!({"method": "org.varlink.service.GetInfo"})).await;
        assert_eq!(r[0]["parameters"]["interfaces"][1], INTERFACE, "{r:?}");

        let r = call(&mut s, json!({"method": "org.varlink.service.GetInterfaceDescription", "parameters": {"interface": "io.vrx.Host"}})).await;
        assert!(r[0]["parameters"]["description"]
            .as_str()
            .unwrap()
            .contains("interface io.vrx.Host"));

        let r = call(&mut s, json!({"method": "io.vrx.Host.Teleport"})).await;
        assert_eq!(r[0]["error"], "org.varlink.service.MethodNotFound", "{r:?}");
    }

    #[tokio::test]
    async fn watch_streams_the_front_applet() {
        let (socket, front, _dir) = started().await;
        let mut s = UnixStream::connect(&socket).await.unwrap();
        let mut bytes =
            serde_json::to_vec(&json!({"method": "io.vrx.Host.Watch", "more": true}))
                .unwrap();
        bytes.push(0);
        s.write_all(&bytes).await.unwrap();
        let mut read_one = async || {
            let mut buf = Vec::new();
            loop {
                let mut byte = [0u8; 1];
                s.read_exact(&mut byte).await.unwrap();
                if byte[0] == 0 {
                    return serde_json::from_slice::<Value>(&buf).unwrap();
                }
                buf.push(byte[0]);
            }
        };
        let first = read_one().await;
        assert_eq!(first["parameters"]["front"], "launcher", "{first}");
        assert_eq!(first["continues"], true, "{first}");
        front
            .send(Front {
                front: "clock".into(),
                depth: 2,
            })
            .unwrap();
        let second = read_one().await;
        assert_eq!(second["parameters"]["front"], "clock", "{second}");
        assert_eq!(second["parameters"]["depth"], 2, "{second}");
    }
}
