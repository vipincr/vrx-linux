// The intent router: vrxhost's signal mechanism (plan 0008 D15). Handlers
// are asked in the registry's order (priority descending, built-ins
// first); the first that takes it wins. An **opened** handler (declared
// `at <route>`) takes it by being started or fronted at that route (a
// trail push, through the session); if it is already running it also
// receives the payload over its Listen. A **told** handler must be
// running and listening: it is asked over its Listen and answers
// handled or pass within 100 ms; silence, or not listening, is a pass
// and the next handler is asked.
//
// The wire is vrxhost's Varlink interface (varlink.rs: `Intent`, `Listen`,
// `Answer`); this module is the order alone.

use vrx_protocol::{Intent, Registry};

/// One handler of an intent, in the order they are asked.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Handler {
    /// Takes it by being fronted at this route.
    Opened { applet: String, route: u32 },
    /// Asked over its Listen; it answers handled or pass.
    Told { applet: String },
}

/// The handlers of one intent, in the order they are asked; empty when
/// none is declared.
pub fn handlers(registry: &Registry, intent: &Intent) -> Vec<Handler> {
    registry
        .handlers_for(&intent.name)
        .into_iter()
        .filter_map(|entry| {
            let handle = entry
                .manifest
                .applet
                .intents
                .handles
                .iter()
                .find(|h| h.name == intent.name)?;
            let applet = entry.manifest.applet.id.clone();
            Some(match &handle.at {
                Some(route_name) => Handler::Opened {
                    route: entry.manifest.route_number(route_name).unwrap_or(0),
                    applet,
                },
                None => Handler::Told { applet },
            })
        })
        .collect()
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
    fn handlers_come_in_priority_order_opened_and_told() {
        let intent =
            Intent::new("sys.alarm.ring", serde_json::json!({"id": 7})).expect("intent");
        // clock (opened, 900) is asked before listener (told, 100)
        assert_eq!(
            handlers(&registry(), &intent),
            vec![
                Handler::Opened {
                    applet: "clock".into(),
                    route: 1,
                },
                Handler::Told {
                    applet: "listener".into()
                },
            ]
        );
    }

    #[test]
    fn an_intent_without_handlers_has_none() {
        let intent = Intent::new("ghost.ping", serde_json::json!(null)).expect("intent");
        assert!(handlers(&registry(), &intent).is_empty());
    }
}
