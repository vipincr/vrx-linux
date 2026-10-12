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

use std::path::Path;
use std::sync::Arc;

use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};
use vrx_protocol::{Intent, Registry};

/// errno values the router answers with (negative, like the plan's
/// intent verdicts).
pub const ENOENT: i32 = -2;
pub const EINVAL: i32 = -22;

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
pub async fn serve(socket_path: &Path, registry: Arc<Registry>) -> std::io::Result<()> {
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
        tokio::spawn(async move {
            if let Err(err) = handle_connection(stream, registry).await {
                tracing::debug!(error = %err, "intent connection ended");
            }
        });
    }
}

async fn handle_connection(
    stream: UnixStream,
    registry: Arc<Registry>,
) -> std::io::Result<()> {
    // one intent per connection: the socket answers and closes; a
    // client that wants another asks again (verdicts are settled per
    // ask, and a held connections would pin handlers' 100ms budgets)
    let (reader, mut writer) = stream.into_split();
    let mut lines = BufReader::new(reader).lines();
    if let Some(line) = lines.next_line().await? {
        let response = answer(&registry, &line);
        let mut bytes = serde_json::to_string(&response)
            .unwrap_or_else(|_| "{\"ok\":false,\"errno\":-22}".to_owned());
        bytes.push('\n');
        writer.write_all(bytes.as_bytes()).await?;
        writer.flush().await?;
    }
    Ok(())
}

fn answer(registry: &Registry, line: &str) -> serde_json::Value {
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
    match route(registry, &intent) {
        Outcome::Opened { applet, route } => serde_json::json!({
            "ok": true,
            "verdict": "opened",
            "handled_by": applet,
            "route": route,
        }),
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
        let server = tokio::spawn(async move { serve(&bound, registry).await });

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

        server.abort();
    }
}
