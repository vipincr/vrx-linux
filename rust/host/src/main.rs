// The vrxhost binary: scan the registry, start the boot plan's
// applets, control the compositor's focus, serve the intent socket
// until the system goes down. All policy lives in the library
// (session.rs decides; this file carries the orders out).

use std::collections::VecDeque;
use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::Arc;

use tokio::sync::mpsc;
use vrx_host::compositor::{self, LinkEvent};
use vrx_host::intent::NavRequest;
use vrx_host::launch::{self, Credential};
use vrx_host::session::{Order, Session};
use vrx_host::supervisor::{Event, Supervisor};
use vrx_host::{intent, paths, registry};
use vrx_protocol::Registry;

#[tokio::main]
async fn main() -> ExitCode {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    let paths = paths::VrxPaths::system();
    let registry = match registry::scan(&paths) {
        Ok(registry) => Arc::new(registry),
        Err(err) => {
            tracing::error!(error = %err, "registry scan failed");
            return ExitCode::FAILURE;
        }
    };
    let builtins = registry.iter().filter(|e| e.builtin).count();
    let installed = registry.len() - builtins;
    tracing::info!(builtins, installed, "registry ready");

    // amendment B: applets never run as root
    let cred = match launch::applet_credential() {
        Ok(cred) => cred,
        Err(err) => {
            tracing::error!(error = %err, "no applet identity");
            return ExitCode::FAILURE;
        }
    };

    let (supervisor, supervision) = Supervisor::new();
    let (focus_tx, focus_rx) = mpsc::unbounded_channel();
    let (link_tx, link_rx) = mpsc::unbounded_channel();
    let (nav_tx, nav_rx) = mpsc::unbounded_channel();

    tokio::spawn(compositor::run(
        PathBuf::from(compositor::SOCKET),
        focus_rx,
        link_tx,
    ));

    match Session::home_of(&registry) {
        Some(home) => {
            let host = Host {
                registry: registry.clone(),
                runtime: paths.runtime.clone(),
                cred,
                supervisor,
                focus: focus_tx,
            };
            tokio::spawn(host.run(Session::new(home), supervision, link_rx, nav_rx));
        }
        None => {
            // headless: nothing to put on screen, intents still route
            tracing::warn!("no applet holds the home role; nothing will be shown");
        }
    }

    let socket = paths.intent_socket();
    if let Err(err) = intent::serve(&socket, registry, nav_tx).await {
        tracing::error!(socket = %socket.display(), error = %err, "intent router stopped");
        return ExitCode::FAILURE;
    }
    ExitCode::SUCCESS
}

/// What carries the session's orders out.
struct Host {
    registry: Arc<Registry>,
    runtime: PathBuf,
    cred: Credential,
    supervisor: Supervisor,
    focus: mpsc::UnboundedSender<u32>,
}

impl Host {
    async fn run(
        self,
        mut session: Session,
        mut supervision: mpsc::UnboundedReceiver<Event>,
        mut link: mpsc::UnboundedReceiver<LinkEvent>,
        mut nav: mpsc::UnboundedReceiver<NavRequest>,
    ) {
        let orders = session.boot(&self.registry);
        self.carry_out(&mut session, orders);
        loop {
            let orders = tokio::select! {
                Some(event) = supervision.recv() => {
                    tracing::info!(?event, "supervision");
                    session.supervision(&event)
                }
                Some(event) = link.recv() => {
                    tracing::info!(?event, "compositor");
                    session.link(&event)
                }
                Some((op, reply)) = nav.recv() => {
                    tracing::info!(?op, "nav");
                    match session.nav(&self.registry, op) {
                        Ok(orders) => {
                            let _ = reply.send(Ok(session.top().unwrap_or_default().to_owned()));
                            orders
                        }
                        Err(err) => {
                            let _ = reply.send(Err(err));
                            Vec::new()
                        }
                    }
                }
                else => return,
            };
            self.carry_out(&mut session, orders);
        }
    }

    fn carry_out(&self, session: &mut Session, orders: Vec<Order>) {
        let mut orders = VecDeque::from(orders);
        while let Some(order) = orders.pop_front() {
            match order {
                Order::Focus(pid) => {
                    tracing::info!(pid, top = ?session.top(), "focus");
                    let _ = self.focus.send(pid);
                }
                Order::Start(applet) => {
                    let launch = self
                        .registry
                        .find(&applet)
                        .ok_or_else(|| format!("{applet}: not in the registry"))
                        .and_then(|entry| {
                            launch::for_entry(
                                entry,
                                &self.runtime,
                                Some(self.cred.clone()),
                            )
                            .map_err(|e| e.to_string())
                        });
                    match launch {
                        Ok(launch) => {
                            tracing::info!(%applet, program = ?launch.program, args = ?launch.args, "start");
                            self.supervisor.supervise(&applet, launch);
                        }
                        Err(err) => {
                            // a launch that cannot even be built is a
                            // disabled applet, decided the same way
                            tracing::error!(error = %err, "cannot start");
                            orders.extend(
                                session
                                    .supervision(&Event::Disabled { applet, crashes: 0 }),
                            );
                        }
                    }
                }
            }
        }
    }
}
