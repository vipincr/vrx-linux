// The vrxhost binary: scan the registry, start the boot plan's applets
// through systemd, control the compositor's focus, serve io.vrx.Host
// until the system goes down. All policy lives in the library
// (session.rs decides; this file carries the orders out).

use std::collections::{HashSet, VecDeque};
use std::path::PathBuf;
use std::process::ExitCode;

use tokio::sync::{mpsc, watch};
use vrx_host::applets::{Applets, Event};
use vrx_host::compositor::{self, Control, LinkEvent};
use vrx_host::freeze::{self, Freezer};
use vrx_host::session::{NavOp, Order, Session};
use vrx_host::varlink::{self, Front, NavRequest};
use vrx_host::{paths, power, registry, supply, usb};
use vrx_protocol::Intent;

/// Raise a system intent on the host wire, off the caller's loop. An
/// intent name the protocol refuses is logged and dropped: the watcher
/// that raised it must keep watching.
fn raise_system_intent(host: varlink::Host, name: &str, payload: serde_json::Value) {
    let name = name.to_owned();
    tokio::spawn(async move {
        match Intent::new(&name, payload) {
            Ok(intent) => varlink::raise(&host, intent).await,
            Err(err) => {
                tracing::warn!(name = %name, error = %err, "cannot raise the system intent")
            }
        }
    });
}

#[tokio::main]
async fn main() -> ExitCode {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    let paths = paths::VrxPaths::system();
    // vrx-wakealarm.service, before a halt: the next alarm into the RTC
    // (plan 0012 D14, D15)
    if std::env::args().nth(1).as_deref() == Some("wakealarm") {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_secs());
        let rtc = std::path::Path::new("/sys/class/rtc/rtc0/wakealarm");
        return if vrx_host::wake::arm_rtc(rtc, now).await {
            ExitCode::SUCCESS
        } else {
            ExitCode::FAILURE
        };
    }
    // vrx-install.service: the privileged half of an install (install.rs)
    if std::env::args().nth(1).as_deref() == Some("install-helper") {
        return if vrx_host::install::helper_main(&paths).await {
            ExitCode::SUCCESS
        } else {
            ExitCode::FAILURE
        };
    }
    let registry = match registry::scan(&paths) {
        Ok(registry) => registry,
        Err(err) => {
            tracing::error!(error = %err, "registry scan failed");
            return ExitCode::FAILURE;
        }
    };
    let builtins = registry.iter().filter(|e| e.builtin).count();
    let installed = registry.len() - builtins;
    tracing::info!(builtins, installed, "registry ready");

    let (events_tx, events_rx) = mpsc::unbounded_channel();
    let ids: HashSet<String> = registry
        .iter()
        .map(|e| e.manifest.applet.id.clone())
        .collect();
    let applets = match Applets::watch(ids.clone(), events_tx.clone()).await {
        Ok(applets) => applets,
        Err(err) => {
            tracing::error!(error = %err, "cannot reach systemd");
            return ExitCode::FAILURE;
        }
    };

    let (focus_tx, focus_rx) = mpsc::unbounded_channel();
    let focus_for_battery = focus_tx.clone();
    let (link_tx, link_rx) = mpsc::unbounded_channel();
    let (nav_tx, nav_rx) = mpsc::unbounded_channel();
    let (front_tx, front_rx) = watch::channel(Front::default());

    // A home applet means the image has a UI: control the compositor.
    // Without one the image is headless (plan 0008 D14): applets still
    // run, intents still route, nothing is focused.
    let home = Session::home_of(&registry);
    let shell = home.as_ref().and_then(|_| Session::shell_of(&registry));
    let registry = registry::Shared::new(registry);
    // applets behind the screen are frozen (plan 0012 D2); a headless
    // image has no screen to be behind
    let freezer = home.as_ref().map(|_| {
        Freezer::new(
            Box::new(freeze::LinuxBackend {
                applets: applets.clone(),
            }),
            registry.clone(),
            [home.clone(), shell.clone()]
                .into_iter()
                .flatten()
                .collect(),
            freeze::DELAY,
        )
    });
    let (added_tx, added_rx) = mpsc::unbounded_channel();
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
    let applets_for_energy = applets.clone();
    let front_for_energy = front_rx.clone();
    let installer = varlink::Installer {
        paths: paths.clone(),
        applets: applets.clone(),
        added: added_tx,
        lock: Default::default(),
        build_cache: Default::default(),
    };
    let host = Host {
        registry: registry.clone(),
        applets,
        watched: ids,
        events: events_tx,
        focus: focus_tx,
        front: front_tx,
        stopped: None,
        freezer: freezer.clone(),
        focus_generation: Default::default(),
    };
    tokio::spawn(host.run(
        Session::new(home, shell),
        events_rx,
        link_rx,
        nav_rx,
        added_rx,
    ));

    // what each applet costs (plan 0012 D8, D11): sampled from Linux's
    // counters, priced with the board's measured profile
    let energy = vrx_host::energy::Energy::new(
        vrx_host::energy::Roots::system(),
        registry
            .get()
            .iter()
            .map(|e| (e.manifest.applet.id.clone(), e.manifest.applet.name.clone()))
            .collect(),
        std::sync::Arc::new(vrx_host::energy::LinuxActions {
            freezer: freezer.clone(),
            applets: applets_for_energy,
        }),
    );
    tokio::spawn(energy.clone().run(front_for_energy));

    // the profiler's switch and counter output (plan 0014 D1, D4): the
    // compositor and the applets follow it
    let profiler = vrx_host::profile::Profiler::system();
    tokio::spawn(profiler.clone().run());
    let mut semantics = profiler.watch_semantics();
    let semantics_link = focus_for_battery.clone();
    tokio::spawn(async move {
        while semantics.changed().await.is_ok() {
            let on = *semantics.borrow_and_update();
            compositor::SEMANTICS.store(on, std::sync::atomic::Ordering::Relaxed);
            let _ = semantics_link.send(Control::Semantics(on));
        }
    });
    let mut profiling = profiler.watch();
    let profiling_link = focus_for_battery.clone();
    tokio::spawn(async move {
        while profiling.changed().await.is_ok() {
            let on = *profiling.borrow_and_update();
            compositor::PROFILING.store(on, std::sync::atomic::Ordering::Relaxed);
            let _ = profiling_link.send(Control::Profiling(on));
            vrx_host::facts::update(|f| f.profiling = on);
        }
    });

    let socket = paths.host_socket();
    let host = varlink::Host {
        registry,
        installer: Some(installer),
        nav: nav_tx,
        front: front_rx,
        bridge: freezer.map_or_else(
            vrx_host::bridge::Bridge::default,
            vrx_host::bridge::Bridge::with_freezer,
        ),
        energy: Some(energy),
        profiler: Some(profiler),
    };
    // a computer on the USB device port (plan 0008 D11), on boards with one
    if let Some(state) = usb::state_file(std::path::Path::new(usb::UDC_ROOT)) {
        let raiser = host.clone();
        tokio::spawn(async move {
            let ended = usb::watch(state, move || {
                raise_system_intent(
                    raiser.clone(),
                    usb::CONNECTED,
                    serde_json::Value::Null,
                );
            })
            .await;
            if let Err(err) = ended {
                tracing::warn!(error = %err, "USB device port: not watched");
            }
        });
    }
    // the supply's under-voltage alarm, published as a fact (plan 0012
    // D6); a board without rpi_volt has none
    if let Some(alarm) = supply::alarm_file(std::path::Path::new(supply::HWMON_ROOT)) {
        tokio::spawn(async move {
            if let Err(err) = supply::watch(alarm).await {
                tracing::warn!(error = %err, "supply alarm: not watched");
            }
        });
    }
    // the kernel's power supplies (plan 0011 D12): a change is relayed
    // as sys.power.changed; a board with none never sends one
    let raiser = host.clone();
    // the battery's rules (plan 0012 D10): fed by the same changes, and a
    // WARN cap goes to the compositor on the focus link
    let (battery_tx, battery_rx) = mpsc::unbounded_channel();
    let matter_link = focus_for_battery.clone();
    let cap_link = focus_for_battery;
    tokio::spawn(power::battery(
        std::path::PathBuf::from("/sys/class/power_supply"),
        std::path::PathBuf::from("/usr/share/vrx"),
        battery_rx,
        move |permille| {
            compositor::LIGHT_CAP.store(permille, std::sync::atomic::Ordering::Relaxed);
            let _ = cap_link.send(Control::LightCap(permille));
        },
    ));
    let (power_tx, power_rx) = mpsc::unbounded_channel();
    tokio::spawn(power::watch(power_rx, move |supply| {
        let _ = battery_tx.send(());
        raise_system_intent(
            raiser.clone(),
            power::CHANGED,
            serde_json::json!({ "supply": supply }),
        );
    }));
    // devices plugged into the board (plan 0019 D7): the image's
    // declaration, the device list from the same uevents, the drives'
    // mounts; a board that declares no host port publishes none
    let usb_config = usb::Config::load(std::path::Path::new(usb::CONFIG));
    let declared = usb_config.clone();
    vrx_host::facts::update(move |f| {
        f.usb_ports = declared.ports;
        f.usb_vbus = declared.vbus;
        f.usb_overcurrent = declared.overcurrent;
    });
    let (usb_tx, usb_rx) = mpsc::unbounded_channel();
    let usb_host = (!usb_config.ports.is_empty()).then(|| usb_tx.clone());
    if usb_host.is_some() {
        let mounts_tx = usb_tx.clone();
        tokio::spawn(async move {
            if let Err(err) = vrx_host::mounts::watch(usb::MOUNT_ROOT, mounts_tx).await {
                tracing::warn!(error = %err, "usb drives' mounts: not watched");
            }
        });
    }
    let (raiser, scanner) = (host.clone(), host.clone());
    let probe_applets = host.installer.as_ref().map(|i| i.applets.clone());
    tokio::spawn(usb::host(
        std::path::PathBuf::from(usb::DEVICES_ROOT),
        usb_config,
        usb_rx,
        |devices, policy| {
            vrx_host::facts::update(move |f| {
                f.usb_devices = devices;
                f.usb_policy = policy.to_owned();
            });
        },
        move |name: &'static str, payload: serde_json::Value| {
            raise_system_intent(raiser.clone(), name, payload);
        },
        move || {
            let applets = probe_applets.clone();
            async move {
                match applets {
                    Some(a) => a.is_active("usbguard.service").await,
                    None => false,
                }
            }
        },
        move || {
            let host = scanner.clone();
            tokio::spawn(async move { varlink::import_drives(&host).await });
        },
    ));
    // CON-04 (review 2026-10-17): the facts systemd and USBGuard own are
    // read from their owners at start, not defaulted and corrected at the
    // next event — next_wake from the timers systemd is already holding,
    // usb_allow_new from USBGuard when it runs. Both settle before the
    // first Facts call answers.
    tokio::spawn(async move {
        match vrx_host::facts::seed_owned().await {
            Ok(()) => {}
            Err(err) => {
                tracing::warn!(error = %err, "facts: owned facts unread; they stay unknown")
            }
        }
    });

    // the kernel's uevents, heard once (G065): power supplies and the
    // backlight to power.rs, USB devices to usb.rs
    tokio::spawn(async move {
        // CON-08 (review 2026-10-17): a netlink overrun re-opens the
        // listener and re-reads state; the loop never ends the listening
        // for the life of the process. The senders are shared by every
        // re-open's closure.
        let power_tx = std::sync::Arc::new(power_tx);
        let usb_host = usb_host.map(std::sync::Arc::new);
        loop {
            let again = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
            let flag = again.clone();
            let power_tx = power_tx.clone();
            let usb_host = usb_host.clone();
            let ended = vrx_host::uevents::listen(move |message| {
                flag.store(true, std::sync::atomic::Ordering::Relaxed);
                match message.subsystem() {
                    "power_supply" | "backlight" => {
                        let _ = power_tx.send(message);
                    }
                    "usb" => {
                        if let Some(tx) = usb_host.as_ref() {
                            let _ = tx.send(usb::HostEvent::Uevent(message));
                        }
                    }
                    _ => {}
                }
            })
            .await;
            let heard = again.load(std::sync::atomic::Ordering::Relaxed);
            match ended {
                Ok(()) => break,
                Err(err) if err.raw_os_error() == Some(105) => {
                    // ENOBUFS
                    tracing::warn!(error = %err, %heard, "kernel uevents: overrun; re-opening");
                }
                Err(err) => {
                    tracing::warn!(error = %err, "kernel uevents: not heard");
                    break;
                }
            }
        }
    });
    // Matter (plan 0015): only where the image carries vrx-matter; the
    // screen orders go to the compositor on the focus link
    if std::path::Path::new(MATTER_BIN).exists() {
        tokio::spawn(vrx_host::matter::run(
            host.clone(),
            matter_link,
            vrx_host::matter::exposure(),
        ));
    }
    // OPS-07 (review 2026-10-17): the host's liveness contract. READY
    // once the socket serves; the watchdog pinged from the same task, so
    // a wedged event loop stops the pings and systemd restarts the host.
    vrx_wire::notify("READY=1");
    let watchdog = vrx_wire::watchdog_interval();
    let mut next_ping = std::time::Instant::now();
    let ping_every = watchdog.map(|w| w / 2);
    if let Some(w) = watchdog {
        tracing::info!(watchdog_s = w.as_secs(), "watchdog armed");
    }
    let serve = varlink::serve(&socket, host);
    tokio::pin!(serve);
    // SIGTERM drains instead of dying mid-write (RES-04, review
    // 2026-10-17): the energy ring and the install state rename into
    // place, and a kill in that window is a torn file
    let mut term =
        tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
            .map_err(|e| tracing::warn!(error = %e, "cannot listen for SIGTERM"))
            .ok();
    loop {
        let mut wait = std::time::Duration::from_secs(3600);
        if ping_every.is_some() {
            wait = next_ping.saturating_duration_since(std::time::Instant::now());
        }
        tokio::select! {
            r = &mut serve => {
                if let Err(err) = r {
                    tracing::error!(socket = %socket.display(), error = %err, "io.vrx.Host stopped");
                    return ExitCode::FAILURE;
                }
                return ExitCode::SUCCESS;
            }
            _ = async {
                if let Some(t) = term.as_mut() {
                    t.recv().await;
                } else {
                    std::future::pending::<()>().await;
                }
            } => {
                tracing::info!("SIGTERM: draining and stopping");
                return ExitCode::SUCCESS;
            }
            () = tokio::time::sleep(wait) => {
                if let Some(every) = ping_every {
                    vrx_wire::notify("WATCHDOG=1");
                    next_ping = std::time::Instant::now() + every;
                }
            }
        }
    }
}

/// vrx-matter's binary: present when the image opted into Matter
/// (VRX_MATTER, plan 0015 D13).
const MATTER_BIN: &str = "/usr/bin/vrx-matter";

/// The first-boot applet and the marker it writes when the walk is done.
const SETUP: &str = "setup";
const SETUP_DONE: &str = "/var/lib/vrx/setup/done";

/// What carries the session's orders out.
struct Host {
    registry: registry::Shared,
    applets: Applets,
    /// The applets whose units are watched (an installed one joins).
    watched: HashSet<String>,
    events: mpsc::UnboundedSender<Event>,
    focus: mpsc::UnboundedSender<Control>,
    front: watch::Sender<Front>,
    /// An applet that crashed, by name, until the next navigation (plan
    /// 0011 D2: the shell says "X stopped." once).
    stopped: Option<String>,
    /// Freezes applets behind the screen (plan 0012 D2); None headless.
    freezer: Option<Freezer>,
    /// Bumped by every focus order, so a focus that waited for a thaw is
    /// not sent after a newer one.
    focus_generation: std::sync::Arc<std::sync::atomic::AtomicU64>,
}

impl Host {
    async fn run(
        mut self,
        mut session: Session,
        mut events: mpsc::UnboundedReceiver<Event>,
        mut link: mpsc::UnboundedReceiver<LinkEvent>,
        mut nav: mpsc::UnboundedReceiver<NavRequest>,
        mut added: mpsc::UnboundedReceiver<Vec<String>>,
    ) {
        let mut orders = session.boot(&self.registry.get());
        // first boot (plan 0008 D10): Setup over Home until it has written
        // its marker in its own state directory (a factory reset, which
        // wipes /data, brings it back)
        if self.registry.get().find(SETUP).is_some()
            && !std::path::Path::new(SETUP_DONE).exists()
        {
            tracing::info!("first boot: opening setup");
            let push = NavOp::Push {
                applet: SETUP.to_owned(),
                route: 0,
            };
            if let Ok(more) = session.nav(&self.registry.get(), push) {
                orders.extend(more);
            }
        }
        self.carry_out(&mut session, orders);
        loop {
            let orders = tokio::select! {
                Some(event) = events.recv() => {
                    tracing::info!(?event, "applet");
                    if let Some(freezer) = &self.freezer {
                        match &event {
                            Event::Started { applet, pid } => freezer.started(applet, *pid),
                            _ => freezer.gone(event.applet()),
                        }
                    }
                    if let Event::Restarting { applet, .. } | Event::Disabled { applet, .. } = &event {
                        self.stopped = Some(
                            self.registry
                                .get()
                                .find(applet)
                                .map_or_else(|| applet.clone(), |e| e.manifest.applet.name.clone()),
                        );
                    }
                    session.supervision(&event)
                }
                Some(event) = link.recv() => {
                    tracing::info!(?event, "compositor");
                    if let LinkEvent::App { pid, state: vrx_host::compositor::AppState::Shown, .. } = &event {
                        if session.is_shell_pid(*pid) {
                            vrx_host::update::shell_shown();
                        }
                    }
                    if let LinkEvent::Screen { on, position } = event {
                        vrx_host::facts::update(|f| {
                            f.screen_on = on;
                            f.brightness = position;
                        });
                    }
                    session.link(&event)
                }
                Some((op, reply)) = nav.recv() => {
                    tracing::info!(?op, "nav");
                    self.stopped = None;
                    match session.nav(&self.registry.get(), op) {
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
                Some(ids) = added.recv() => {
                    // an install (plan 0011 D16): its unit is watched from now
                    for id in ids {
                        if self.watched.insert(id.clone()) {
                            if let Err(err) = self.applets.watch_one(id.clone(), self.events.clone()).await {
                                tracing::error!(applet = %id, error = %err, "cannot watch the installed applet");
                            }
                        }
                    }
                    Vec::new()
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
                    let generation = self
                        .focus_generation
                        .fetch_add(1, std::sync::atomic::Ordering::SeqCst)
                        + 1;
                    let top = session.top().unwrap_or_default().to_owned();
                    match &self.freezer {
                        // frozen (or unknown): thawed first, so it can
                        // present its frame when focused
                        Some(freezer) if freezer.shown(&top) => {
                            let freezer = freezer.clone();
                            let focus = self.focus.clone();
                            let current = self.focus_generation.clone();
                            tokio::spawn(async move {
                                freezer.thaw(&top, "focus").await;
                                if current.load(std::sync::atomic::Ordering::SeqCst)
                                    == generation
                                {
                                    let _ = focus.send(Control::Focus(pid));
                                }
                            });
                        }
                        _ => {
                            let _ = self.focus.send(Control::Focus(pid));
                        }
                    }
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
            stopped: self.stopped.clone(),
        };
        self.front.send_if_modified(|now| {
            let changed = *now != front;
            *now = front;
            changed
        });
    }
}
