// The intent router: vrxhost's signal mechanism. Handlers are asked in
// the registry's order (priority descending, built-ins first); the first
// HANDLED wins. An **opened** handler (declared `at <route>`) makes
// vrxhost start or front the applet at that route with the payload (a
// trail push, through the session). A **told** handler must be running to
// answer; a told handler that is not running (or stays silent past its
// 100ms) is a PASS and the next handler is asked. Told delivery needs the
// applet protocol (part G); until then a told handler without a live
// connection passes, which is the same answer silence gives.
//
// The wire is vrxhost's Varlink interface (varlink.rs, `io.vrx.Host.Intent`);
// this module is the routing decision alone.

use vrx_protocol::{Intent, Registry};

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
}
