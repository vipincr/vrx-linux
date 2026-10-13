// The vrxhost binary: scan the registry, start the boot plan's applets
// through systemd, control the compositor's focus, serve io.vrx.Host
// until the system goes down. All policy lives in the library
// (session.rs decides; this file carries the orders out).

use std::collections::VecDeque;
use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::Arc;

use tokio::sync::{mpsc, watch};
use vrx_host::applets::{Applets, Event};
use vrx_host::compositor::{self, Control, LinkEvent};
use vrx_host::session::{NavOp, Order, Session};
use vrx_host::varlink::{self, Front, NavRequest};
use vrx_host::{paths, registry, usb};
use vrx_protocol::Intent;
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

    let (events_tx, events_rx) = mpsc::unbounded_channel();
    let ids = registry.iter().map(|e| e.manifest.applet.id.clone());
    let applets = match Applets::watch(ids, events_tx.clone()).await {
        Ok(applets) => applets,
        Err(err) => {
            tracing::error!(error = %err, "cannot reach systemd");
            return ExitCode::FAILURE;
        }
    };

    let (focus_tx, focus_rx) = mpsc::unbounded_channel();
    let (link_tx, link_rx) = mpsc::unbounded_channel();
    let (nav_tx, nav_rx) = mpsc::unbounded_channel();
    let (front_tx, front_rx) = watch::channel(Front::default());

    // A home applet means the image has a UI: control the compositor.
    // Without one the image is headless (plan 0008 D14): applets still
    // run, intents still route, nothing is focused.
    let home = Session::home_of(&registry);
    let shell = home.as_ref().and_then(|_| Session::shell_of(&registry));
    if home.is_some() {
        tokio::spawn(compositor::run(
            PathBuf::from(compositor::SOCKET),
            focus_rx,
            link_tx,
        ));
    } else {
        tracing::info!("no home applet: headless, no compositor link");
        drop(link_tx);
    }
    let host = Host {
        registry: registry.clone(),
        applets,
        events: events_tx,
        focus: focus_tx,
        front: front_tx,
    };
    tokio::spawn(host.run(Session::new(home, shell), events_rx, link_rx, nav_rx));

    let socket = paths.host_socket();
    let host = varlink::Host {
        registry,
        nav: nav_tx,
        front: front_rx,
        bridge: vrx_host::bridge::Bridge::default(),
    };
    // a computer on the USB device port (plan 0008 D11), on boards with one
    if let Some(state) = usb::state_file(std::path::Path::new(usb::UDC_ROOT)) {
        let raiser = host.clone();
        tokio::spawn(async move {
            let ended = usb::watch(state, move || {
                let host = raiser.clone();
                tokio::spawn(async move {
                    if let Ok(intent) =
                        Intent::new(usb::CONNECTED, serde_json::Value::Null)
                    {
                        varlink::raise(&host, intent).await;
                    }
                });
            })
            .await;
            if let Err(err) = ended {
                tracing::warn!(error = %err, "USB device port: not watched");
            }
        });
    }
    if let Err(err) = varlink::serve(&socket, host).await {
        tracing::error!(socket = %socket.display(), error = %err, "io.vrx.Host stopped");
        return ExitCode::FAILURE;
    }
    ExitCode::SUCCESS
}

/// The first-boot applet and the marker it writes when the walk is done.
const SETUP: &str = "setup";
const SETUP_DONE: &str = "/var/lib/vrx/setup/done";

/// What carries the session's orders out.
struct Host {
    registry: Arc<Registry>,
    applets: Applets,
    events: mpsc::UnboundedSender<Event>,
    focus: mpsc::UnboundedSender<Control>,
    front: watch::Sender<Front>,
}

impl Host {
    async fn run(
        self,
        mut session: Session,
        mut events: mpsc::UnboundedReceiver<Event>,
        mut link: mpsc::UnboundedReceiver<LinkEvent>,
        mut nav: mpsc::UnboundedReceiver<NavRequest>,
    ) {
        let mut orders = session.boot(&self.registry);
        // first boot (plan 0008 D10): Setup over Home until it has written
        // its marker in its own state directory (a factory reset, which
        // wipes /data, brings it back)
        if self.registry.find(SETUP).is_some()
            && !std::path::Path::new(SETUP_DONE).exists()
        {
            tracing::info!("first boot: opening setup");
            let push = NavOp::Push {
                applet: SETUP.to_owned(),
                route: 0,
            };
            if let Ok(more) = session.nav(&self.registry, push) {
                orders.extend(more);
            }
        }
        self.carry_out(&mut session, orders);
        loop {
            let orders = tokio::select! {
                Some(event) = events.recv() => {
                    tracing::info!(?event, "applet");
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
                    let _ = self.focus.send(Control::Focus(pid));
                }
                Order::Shell(pid) => {
                    tracing::info!(pid, "shell");
                    let _ = self.focus.send(Control::Shell(pid));
                }
                Order::Start(applet) => {
                    tracing::info!(%applet, "start");
                    let applets = self.applets.clone();
                    let events = self.events.clone();
                    tokio::spawn(async move {
                        if let Err(err) = applets.start(&applet).await {
                            // a unit that cannot even be started is a
                            // disabled applet, decided the same way
                            tracing::error!(%applet, error = %err, "cannot start");
                            let _ = events.send(Event::Disabled { applet, crashes: 0 });
                        }
                    });
                }
            }
        }
        let front = Front {
            front: session.top().unwrap_or_default().to_owned(),
            depth: u32::try_from(session.depth()).unwrap_or(u32::MAX),
        };
        self.front.send_if_modified(|now| {
            let changed = *now != front;
            *now = front;
            changed
        });
    }
}
