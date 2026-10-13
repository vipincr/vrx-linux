// The intent router: vrxhost's signal mechanism. One Unix socket
// (/tmp/vrx/vrx.sock), newline-delimited JSON, one request per line:
//
//   request:  {"name": "sys.alarm.ring", "payload": {...}}
//   response: {"ok": true, "verdict": "opened", "handled_by": "clock", "route": 4}
//             {"ok": true, "verdict": "pass"}
//             {"ok": false, "errno": -2, "error": "..."}
//
// Handlers are asked in the registry's order (priority descending,
// built-ins first); the first HANDLED wins. An **opened** handler
// (declared `at <route>`) makes vrxhost start or front the applet at
// that route with the payload. A **told** handler must be running to
// answer; a told handler that is not running (or stays silent past its
// 100ms) is a PASS and the next handler is asked. Told delivery needs
// the applet protocol (part G); until then a told handler without a
// live connection passes, which is the same answer silence gives.
//
// Names under `vrx.` that vrxhost answers itself, never routed to an
// applet (the trail and the registry are vrxhost's):
//
//   vrx.nav.push {"applet": "clock", "route": 0}  → {"ok": true, "verdict": "opened", "handled_by": "clock"}
//   vrx.nav.pop / vrx.nav.home                    → the same, naming the applet now on top
//   vrx.registry.list                             → {"ok": true, "applets": [{"id", "name", "icon", "position"}]}
//                                                   (the launcher's tiles: display.tile, position order)

use std::path::Path;
use std::sync::Arc;

use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::{mpsc, oneshot};
use vrx_protocol::{Intent, Registry};

use crate::session::{NavError, NavOp};

/// A navigation request on its way to the session, with where to send
/// the answer: the applet on top afterwards, or why it was refused.
pub type NavRequest = (NavOp, oneshot::Sender<Result<String, NavError>>);

/// errno values the router answers with (negative, like the plan's
/// intent verdicts).
pub const ENOENT: i32 = -2;
pub const EINVAL: i32 = -22;
pub const EIO: i32 = -5;

/// How a routed intent settled.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    /// An opened handler took it: start/front this applet at the route.
    Opened { applet: String, route: u32 },
    /// Every handler passed: the intent is dropped, logged.
    PassAll,
    /// No handler is declared for the intent.
    NotFound,
}

/// Route one intent against the registry.
pub fn route(registry: &Registry, intent: &Intent) -> Outcome {
    let handlers = registry.handlers_for(&intent.name);
    let mut asked: Vec<&str> = Vec::new();
    for entry in handlers {
        let handle = entry
            .manifest
            .applet
            .intents
            .handles
            .iter()
            .find(|h| h.name == intent.name);
        let Some(handle) = handle else { continue };
        match &handle.at {
            Some(route_name) => {
                // opened: vrxhost fronts the applet at the route
                let number = entry.manifest.route_number(route_name).unwrap_or(0);
                return Outcome::Opened {
                    applet: entry.manifest.applet.id.clone(),
                    route: number,
                };
            }
            None => {
                // told: needs a live applet connection (part G); a
                // handler that cannot answer is a PASS
                asked.push(&entry.manifest.applet.id);
            }
        }
    }
    if asked.is_empty() {
        Outcome::NotFound
    } else {
        tracing::debug!(intent = %intent.name, asked = ?asked, "all handlers passed");
        Outcome::PassAll
    }
}

/// Serve the intent socket: one JSON request per line, one JSON
/// response per request, until the listener errors.
pub async fn serve(
    socket_path: &Path,
    registry: Arc<Registry>,
    nav: mpsc::UnboundedSender<NavRequest>,
) -> std::io::Result<()> {
    if let Some(parent) = socket_path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    // a stale socket from a previous boot would fail the bind
    let _ = std::fs::remove_file(socket_path);
    let listener = UnixListener::bind(socket_path)?;
    tracing::info!(socket = %socket_path.display(), "intent router listening");
    loop {
        let (stream, _) = match listener.accept().await {
            Ok(accepted) => accepted,
            Err(err) => {
                tracing::warn!(error = %err, "intent accept failed");
                return Err(err);
            }
        };
        let registry = registry.clone();
        let nav = nav.clone();
        tokio::spawn(async move {
            if let Err(err) = handle_connection(stream, registry, nav).await {
                tracing::debug!(error = %err, "intent connection ended");
            }
        });
    }
}

async fn handle_connection(
    stream: UnixStream,
    registry: Arc<Registry>,
    nav: mpsc::UnboundedSender<NavRequest>,
) -> std::io::Result<()> {
    // one intent per connection: the socket answers and closes; a
    // client that wants another asks again (verdicts are settled per
    // ask, and a held connections would pin handlers' 100ms budgets)
    let (reader, mut writer) = stream.into_split();
    let mut lines = BufReader::new(reader).lines();
    if let Some(line) = lines.next_line().await? {
        let response = answer(&registry, &nav, &line).await;
        let mut bytes = serde_json::to_string(&response)
            .unwrap_or_else(|_| "{\"ok\":false,\"errno\":-22}".to_owned());
        bytes.push('\n');
        writer.write_all(bytes.as_bytes()).await?;
        writer.flush().await?;
    }
    Ok(())
}

async fn answer(
    registry: &Registry,
    nav: &mpsc::UnboundedSender<NavRequest>,
    line: &str,
) -> serde_json::Value {
    let intent: Intent = match serde_json::from_str(line) {
        Ok(intent) => intent,
        Err(err) => {
            return serde_json::json!({
                "ok": false,
                "errno": EINVAL,
                "error": format!("intent is not valid JSON: {err}"),
            });
        }
    };
    if let Err(err) = vrx_protocol::intent::validate_name(&intent.name) {
        return serde_json::json!({
            "ok": false,
            "errno": EINVAL,
            "error": err.to_string(),
        });
    }
    if intent.name == "vrx.registry.list" {
        return registry_list(registry);
    }
    if let Some(op) = nav_op(registry, &intent) {
        return match op {
            Ok(op) => navigate(nav, op).await,
            Err(error) => {
                serde_json::json!({ "ok": false, "errno": EINVAL, "error": error })
            }
        };
    }
    match route(registry, &intent) {
        Outcome::Opened { applet, route } => {
            // an opened handler is fronted at its route: a trail push
            let pushed = navigate(
                nav,
                NavOp::Push {
                    applet: applet.clone(),
                    route,
                },
            )
            .await;
            if pushed["ok"] != true {
                return pushed;
            }
            serde_json::json!({
                "ok": true,
                "verdict": "opened",
                "handled_by": applet,
                "route": route,
            })
        }
        Outcome::PassAll => serde_json::json!({
            "ok": true,
            "verdict": "pass",
        }),
        Outcome::NotFound => serde_json::json!({
            "ok": false,
            "errno": ENOENT,
            "error": format!("no handler for {:?}", intent.name),
        }),
    }
}

/// The `vrx.nav.*` request an intent names, if any. A push's route is
/// a number or a route name from the applet's manifest (Nav.push in
/// vrx_kit sends names).
fn nav_op(registry: &Registry, intent: &Intent) -> Option<Result<NavOp, String>> {
    match intent.name.as_str() {
        "vrx.nav.push" => {
            let Some(applet) = intent.payload.get("applet").and_then(|v| v.as_str())
            else {
                return Some(Err("vrx.nav.push needs {\"applet\": <id>}".to_owned()));
            };
            let route = match intent.payload.get("route") {
                None => Some(0),
                Some(serde_json::Value::Number(n)) => {
                    n.as_u64().and_then(|n| u32::try_from(n).ok())
                }
                Some(serde_json::Value::String(name)) => registry
                    .find(applet)
                    .map_or(Some(0), |e| e.manifest.route_number(name)),
                Some(_) => None,
            };
            Some(match route {
                Some(route) => Ok(NavOp::Push {
                    applet: applet.to_owned(),
                    route,
                }),
                None => Err(format!("vrx.nav.push: {applet} has no such route")),
            })
        }
        "vrx.nav.pop" => Some(Ok(NavOp::Pop)),
        "vrx.nav.home" => Some(Ok(NavOp::Home)),
        _ => None,
    }
}

async fn navigate(
    nav: &mpsc::UnboundedSender<NavRequest>,
    op: NavOp,
) -> serde_json::Value {
    let (tx, rx) = oneshot::channel();
    if nav.send((op, tx)).is_err() {
        return serde_json::json!({ "ok": false, "errno": EIO, "error": "the session is gone" });
    }
    match rx.await {
        Ok(Ok(top)) => {
            serde_json::json!({ "ok": true, "verdict": "opened", "handled_by": top })
        }
        Ok(Err(err)) => serde_json::json!({
            "ok": false,
            "errno": match err { NavError::Unknown(_) => ENOENT, _ => EINVAL },
            "error": err.to_string(),
        }),
        Err(_) => {
            serde_json::json!({ "ok": false, "errno": EIO, "error": "the session is gone" })
        }
    }
}

/// The launcher's tiles: applets with display.tile, in position order.
fn registry_list(registry: &Registry) -> serde_json::Value {
    let mut tiles: Vec<_> = registry
        .iter()
        .filter_map(|e| {
            let display = e.manifest.applet.display.as_ref()?;
            display.tile.then_some((display.position, e))
        })
        .collect();
    tiles.sort_by_key(|(position, _)| *position);
    let applets: Vec<_> = tiles
        .into_iter()
        .map(|(position, e)| {
            let applet = &e.manifest.applet;
            serde_json::json!({
                "id": applet.id,
                "name": applet.name,
                "icon": applet.display.as_ref().map(|d| d.icon.clone()),
                "position": position,
            })
        })
        .collect();
    serde_json::json!({ "ok": true, "applets": applets })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use vrx_protocol::{HandleDecl, Manifest, RegistryEntry};

    fn manifest(id: &str, handles: Vec<HandleDecl>) -> Manifest {
        let handles_decl = if handles.is_empty() {
            String::new()
        } else {
            let entries: Vec<String> = handles
                .iter()
                .map(|h| match &h.at {
                    Some(route) => format!(
                        "{{ name = \"{}\", priority = {}, at = \"{}\" }}",
                        h.name, h.priority, route
                    ),
                    None => {
                        format!("{{ name = \"{}\", priority = {} }}", h.name, h.priority)
                    }
                })
                .collect();
            format!("\n[applet.intents]\nhandles = [{}]\n", entries.join(", "))
        };
        let text = format!(
            "[applet]\nid = \"{id}\"\nname = \"N\"\nversion = \"0.1.0\"\nruntime = \"rust\"\n\
             \n[applet.routes]\nring = {{}}\n{handles_decl}"
        );
        text.parse().expect("manifest")
    }

    fn registry() -> Registry {
        let mut r = Registry::new();
        r.admit(RegistryEntry {
            manifest: manifest(
                "clock",
                vec![HandleDecl {
                    name: "sys.alarm.ring".into(),
                    priority: 900,
                    at: Some("ring".into()),
                }],
            ),
            path: PathBuf::from("/system/defaults/clock"),
            builtin: true,
        })
        .expect("admit");
        r.admit(RegistryEntry {
            manifest: manifest(
                "listener",
                vec![HandleDecl {
                    name: "sys.alarm.ring".into(),
                    priority: 100,
                    at: None,
                }],
            ),
            path: PathBuf::from("/apps/listener"),
            builtin: false,
        })
        .expect("admit");
        r
    }

    #[test]
    fn an_opened_handler_takes_the_intent() {
        let intent =
            Intent::new("sys.alarm.ring", serde_json::json!({"id": 7})).expect("intent");
        // the opened handler (clock, priority 900) outranks the told
        // one (listener, 100): opened wins
        assert_eq!(
            route(&registry(), &intent),
            Outcome::Opened {
                applet: "clock".into(),
                route: 1,
            }
        );
    }

    #[test]
    fn an_intent_without_handlers_is_enoent() {
        let intent = Intent::new("ghost.ping", serde_json::json!(null)).expect("intent");
        assert_eq!(route(&registry(), &intent), Outcome::NotFound);
    }

    async fn ask(socket: &std::path::Path, text: String) -> String {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let mut stream = UnixStream::connect(socket).await.expect("connect");
        // the wire protocol is newline-delimited: the request line must
        // be terminated or the server (rightly) keeps waiting for it
        let mut line = text.into_bytes();
        line.push(b'\n');
        stream.write_all(&line).await.expect("write");
        let mut buf = Vec::new();
        let mut reader = stream.take(4096);
        reader.read_to_end(&mut buf).await.expect("read");
        String::from_utf8_lossy(&buf).trim().to_owned()
    }

    #[tokio::test]
    async fn the_socket_answers_the_wire_protocol() {
        let dir = tempfile::tempdir().expect("tmp");
        let socket = dir.path().join("vrx.sock");
        let registry = Arc::new(registry());
        let bound = socket.clone();
        // a stand-in session: records each request, answers with the
        // pushed applet (pop/home answer "launcher")
        let (nav_tx, mut nav_rx) = mpsc::unbounded_channel::<NavRequest>();
        let seen = Arc::new(std::sync::Mutex::new(Vec::new()));
        let log = seen.clone();
        tokio::spawn(async move {
            while let Some((op, reply)) = nav_rx.recv().await {
                let top = match &op {
                    NavOp::Push { applet, .. } if applet == "ghost" => {
                        let _ = reply.send(Err(NavError::Unknown(applet.clone())));
                        continue;
                    }
                    NavOp::Push { applet, .. } => applet.clone(),
                    NavOp::Pop | NavOp::Home => "launcher".to_owned(),
                };
                log.lock().unwrap().push(op);
                let _ = reply.send(Ok(top));
            }
        });
        let server = tokio::spawn(async move { serve(&bound, registry, nav_tx).await });

        // give the listener a moment to bind
        for _ in 0..50 {
            if socket.exists() {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }

        // bad JSON → EINVAL
        let r: serde_json::Value =
            serde_json::from_str(&ask(&socket, "not json".to_owned()).await)
                .expect("resp");
        assert_eq!(r["ok"], false, "{r}");
        assert_eq!(r["errno"], EINVAL, "{r}");

        // no handler → ENOENT
        let ghost = Intent::new("ghost.ping", serde_json::json!(null)).expect("intent");
        let r: serde_json::Value = serde_json::from_str(
            &ask(&socket, serde_json::to_string(&ghost).expect("ser")).await,
        )
        .expect("resp");
        assert_eq!(r["errno"], ENOENT, "{r}");

        // opened handler → verdict opened, handled_by, route
        let alarm = Intent::new("sys.alarm.ring", serde_json::json!({})).expect("intent");
        let r: serde_json::Value = serde_json::from_str(
            &ask(&socket, serde_json::to_string(&alarm).expect("ser")).await,
        )
        .expect("resp");
        assert_eq!(r["ok"], true, "{r}");
        assert_eq!(r["verdict"], "opened", "{r}");
        assert_eq!(r["handled_by"], "clock", "{r}");
        assert_eq!(r["route"], 1, "{r}");

        // vrxhost's own names: nav and the registry, never routed
        let send = |name: &str, payload: serde_json::Value| {
            serde_json::to_string(&Intent::new(name, payload).expect("intent"))
                .expect("ser")
        };
        let r: serde_json::Value = serde_json::from_str(
            &ask(
                &socket,
                send("vrx.nav.push", serde_json::json!({"applet": "clock"})),
            )
            .await,
        )
        .expect("resp");
        assert_eq!(r["handled_by"], "clock", "{r}");
        let r: serde_json::Value = serde_json::from_str(
            &ask(&socket, send("vrx.nav.home", serde_json::json!(null))).await,
        )
        .expect("resp");
        assert_eq!(r["handled_by"], "launcher", "{r}");
        let r: serde_json::Value = serde_json::from_str(
            &ask(
                &socket,
                send("vrx.nav.push", serde_json::json!({"applet": "ghost"})),
            )
            .await,
        )
        .expect("resp");
        assert_eq!(r["errno"], ENOENT, "{r}");
        let r: serde_json::Value = serde_json::from_str(
            &ask(&socket, send("vrx.nav.push", serde_json::json!({}))).await,
        )
        .expect("resp");
        assert_eq!(r["errno"], EINVAL, "{r}");
        let r: serde_json::Value = serde_json::from_str(
            &ask(&socket, send("vrx.registry.list", serde_json::json!(null))).await,
        )
        .expect("resp");
        assert_eq!(r["ok"], true, "{r}");
        assert!(r["applets"].is_array(), "{r}");

        // a route by name resolves through the manifest; an unknown one is refused
        let r: serde_json::Value = serde_json::from_str(
            &ask(
                &socket,
                send(
                    "vrx.nav.push",
                    serde_json::json!({"applet": "clock", "route": "ring"}),
                ),
            )
            .await,
        )
        .expect("resp");
        assert_eq!(r["ok"], true, "{r}");
        let r: serde_json::Value = serde_json::from_str(
            &ask(
                &socket,
                send(
                    "vrx.nav.push",
                    serde_json::json!({"applet": "clock", "route": "nope"}),
                ),
            )
            .await,
        )
        .expect("resp");
        assert_eq!(r["errno"], EINVAL, "{r}");

        // the opened alarm went through the session as a push at route 1
        assert_eq!(
            seen.lock().unwrap().first(),
            Some(&NavOp::Push {
                applet: "clock".into(),
                route: 1
            })
        );

        server.abort();
    }
}
