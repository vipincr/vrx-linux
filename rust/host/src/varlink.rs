// vrxhost's interface, `io.vrx.Host`, on Varlink (plan 0008 D8): the
// protocol systemd chooses for new system interfaces. JSON objects,
// NUL-terminated, on a unix socket (`/run/vrx/io.vrx.Host`, group vrx);
// `varlinkctl` can introspect and call it. The caller is the socket
// peer's pid, mapped to its applet through its cgroup.

use std::path::Path;

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

# Push an applet onto the back trail at a named route; it starts if it is
# not running. A route it does not declare opens its root (plan 0011 D5).
method Push(applet: string, route: ?string) -> (top: string)

# Pop one trail entry; an empty trail goes Home.
method Pop() -> (top: string)

# Clear the trail to the home applet.
method Home() -> (top: string)

# Route an intent: handlers in priority order; an opened one is pushed at
# its route (and, running, told over its Listen); a told one is asked over
# its Listen and has 100 ms to Answer. verdict: opened, handled or pass.
# An applet may send only what its manifest emits (NotDeclared), a sys.
# name only if it is built in (Reserved), and at most 4 KiB of payload
# (PayloadTooLarge) (plan 0011 D9).
method Intent(name: string, payload: ?object) -> (verdict: string, handled_by: ?string, route: ?int)

# Where the calling applet was last opened: an empty route is its root; payload
# and intent when an intent opened it there (plan 0011 D5).
method Route() -> (route: string, payload: ?object, intent: ?string)

# Held with \"more\" by a running applet (plan 0008 D15): each reply is an
# intent it handles (kind \"intent\"; with an id, Answer it), the route it
# was opened at (kind \"route\"; name is the intent that opened it there,
# if one did), or a channel another applet opened on it (kind \"channel\";
# the stream's end rides as a file descriptor). The newest Listen of an
# applet wins.
method Listen() -> (kind: string, id: ?int, name: ?string, payload: ?object, route: ?string, from: ?string, channel: ?string)

# The answer to an intent a Listen asked about: handled or pass.
method Answer(id: int, verdict: string) -> ()

# Open a channel another applet offers (its manifest's channels.offers;
# yours must list <to>.<channel> in channels.opens; an offer that names a
# grant (requires) opens only for a built-in holding it, else NotPermitted;
# a caller that is no applet is the system and needs neither): a stream socket, one
# end in the reply as a file descriptor, the other handed to that applet's
# Listen. A descriptor sent with the call is handed instead, and the reply
# carries none: a dmabuf, or a memfd sealed against shrinking (anything else
# is NotShareable). A buffer queue passes its buffers over the stream itself.
method Open(to: string, channel: string) -> ()

# The applets the launcher shows (display.tile), in position order.
method Applets() -> (applets: []Applet)

# Every applet that declares settings, and what it declares (D5).
method Settings() -> (applets: []AppletSettings)

# An applet offered for installing (plan 0011 D16): file in
# /var/lib/vrx/offers, its build (the image's SHA-256, what consent is
# given to), kind install, update, replace, older or same, the installed
# version, and problem: why it cannot be installed (name, paths, release,
# manifest, builtin, flutter, unreadable).
type Offer (file: string, id: string, name: string, version: string, build: string, kind: string, installed: ?string, problem: ?string)

# The offers waiting, the USB drive's apps/ folder read in first when
# nothing shares it. For callers holding the apps grant.
method Offers() -> (offers: []Offer)

# Install an offer the person agreed to: refused if its build is no
# longer the one they saw. It runs as its own dynamic user with no
# system grants.
method Install(file: string, build: string) -> (id: string)

# Software update (plan 0016 D11), for callers holding the update grant.
# The bundles offered (the USB drive's updates/ folder read in first when
# nothing shares it, and the Manage page's uploads): each inspected by
# RAUC, which checks its signature; problem says why it cannot be
# installed (unsigned, machine, older, same, unreadable).
type UpdateOffer (file: string, version: string, compatible: string, problem: ?string)
method UpdateOffers() -> (running: string, offers: []UpdateOffer)

# Install an offered bundle into the slot that is not running. Nothing
# restarts: UpdateRestart does, when the person says so.
method UpdateInstall(file: string) -> (version: string)

# Restart into the installed slot on trial: kept only if the device comes
# up healthy, otherwise the next boot is the old slot again (D2, D6).
method UpdateRestart() -> ()

# The running version, the slot booted, whether this boot is a trial, the
# last update's outcome (none, trial, kept, fell-back) and each root slot.
type UpdateSlot (name: string, bootname: string, state: string, boot_status: string, version: string)
method UpdateStatus() -> (running: string, booted: string, trial: bool, last: string, slots: []UpdateSlot)

# Uninstall an installed applet: its unit stops; its image, drop-in,
# saved state, cache and settings are deleted.
method Uninstall(applet: string) -> ()

# Wake the system at a time (unix seconds) for the caller's next alarm or
# timer, through a systemd timer with WakeSystem=yes; null cancels. One
# per applet, replacing the last (plan 0012 D15). For callers holding the
# time grant.
method WakeAt(at: ?int) -> ()

# Let phones find and pair with this device for seconds (1-300, default
# 180, BlueZ's own) or stop: the adapter discoverable and pairable, set
# by the Bluetooth arbiter (plan 0015 D4), which refuses with Busy while
# a home app pairs over Bluetooth and reopens the window for what was
# left of it after. The caller registers its own pairing agent first.
# For callers holding the bluetooth grant.
method PairingWindow(on: bool, seconds: ?int) -> ()

# The front applet and the trail depth; with \"more\", again on every
# change. stopped names an applet that crashed (systemd restarted it, or
# gave up), until the next navigation (plan 0011 D2).
method Watch() -> (front: string, depth: int, stopped: ?string)

# System facts that change, for an applet to hear rather than poll (plan
# 0012 D6): usb, the USB device port's UDC state (\"\" with no UDC);
# supply_low, the supply's under-voltage alarm; backlight, a count of
# changes to the backlight's level (read the level again when it moves);
# battery, the charge in percent as shown (-1 with no battery) and
# battery_zone, \"\", warn or critical while discharging (plan 0012 D10);
# next_wake, the earliest time an applet asked to wake for (0: none);
# profiling, the profiler's switch; screen_on and brightness, the screen
# lit and its slider position (-1: it cannot dim), the compositor's word
# (plan 0015 D12); advertising, who holds Bluetooth by the arbiter's
# decision (\"\", device-link or matter; plan 0015 D4); the USB host side
# (plan 0019 D7, D12): usb_devices, what is plugged in (a drive's mounts
# under /run/vrx/usb), usb_policy (none, open, allowlist, or failed when
# the allow-list's daemon is down), and what the image declared:
# usb_ports, usb_vbus (unswitched, switched, unknown), usb_overcurrent
# (none, reported, unknown); usb_allow_new, the policy switch as vrxhost
# last set it. With \"more\", again on every change.
type UsbDevice (port: string, name: string, class: string, id: string, speed: string, authorized: bool, blocked: bool, mounts: []string)
method Facts() -> (usb: string, supply_low: bool, backlight: int, battery: int, battery_zone: string, next_wake: int, profiling: bool, screen_on: bool, brightness: int, advertising: string, usb_devices: []UsbDevice, usb_policy: string, usb_ports: []string, usb_vbus: string, usb_overcurrent: string, usb_allow_new: bool)

# A drive plugged into the board, ejected (plan 0019 D10): its mount under
# /run/vrx/usb stops. For callers holding the usb grant.
method UsbEject(mount: string) -> ()

# \"Allow new USB devices\" (plan 0019 D11): off, nothing plugged in from
# now on is authorised (what is attached keeps working); on, the image's
# allow-list decides again. Only where usb_policy is allowlist. For
# callers holding the usb grant.
method UsbPolicy(allow_new: bool) -> ()

# What each applet and the system's parts cost over the last hours (1-24,
# default 24; plan 0012 D8, D12), most first. mj is millijoules, absent
# on a board whose power profile has no measured numbers (calibrated
# false): time is still counted then. over marks an applet over its
# budget. For callers holding the power-stats grant.
type EnergyRow (key: string, name: string, kind: string, mj: ?int, cpu_ms: int, gpu_ms: int, wakeups: int, front_s: int, over: bool)
method Energy(hours: ?int) -> (calibrated: bool, measured: ?string, problem: ?string, hours: int, rows: []EnergyRow)

# Why the device is awake (plan 0012 D12): logind's inhibitors (and the
# applet holding each), the applets running and frozen, the wakeup
# sources by event count, the CPU's governor and frequency, the
# temperature, the supply alarm, the screen. For the power-stats grant.
type Inhibitor (what: string, who: string, why: string, mode: string, applet: ?string)
type WakeupSource (name: string, events: int)
method Awake() -> (inhibitors: []Inhibitor, running: []string, frozen: []string, wakeups: []WakeupSource, governor: string, khz: int, temp_mc: ?int, supply_low: bool, screen_on: bool)

# Applets over their power budget (plan 0012 D11): the shell's banner.
# answer is \"\" until the person answers (later, stop), or frozen when
# vrxhost froze it ten minutes after an unanswered alert. With \"more\",
# again on every change. For the shell.
type PowerAlert (applet: string, name: string, budget: string, percent: float, since: int, answer: string)
method PowerAlerts() -> (alerts: []PowerAlert)

# The person's answer to a power alert: later (nothing is done to the
# applet) or stop (its unit stops). For the shell.
method PowerAlertAnswer(applet: string, answer: string) -> ()

# The profiler's runtime switch (plan 0014 D1): on, off, or read with no
# argument. Only a caller that is no applet (root at the shell, the walk
# driver) may set it; an image without meta-vrx-profiling refuses to switch on.
method Profiling(on: ?bool) -> (on: bool, available: bool, reason: ?string, trace_marker: bool, psi: bool)

# An applet's frame summary over its last window (the kit sends one every
# 5 s while profiling is on; plan 0014 D5).
method FrameStats(route: string, frames: int, build_p50_us: int, build_p95_us: int, build_p99_us: int, raster_p50_us: int, raster_p95_us: int, raster_p99_us: int, over_build: int, over_raster: int, budget_us: int) -> ()

# Walks' semantics trees (plan 0014 D8): every app builds its tree while
# on, and the compositor writes each to /run/vrx-ui/semantics/<id>.json.
# Not for applets.
method Semantics(on: bool) -> (on: bool)

# The latest per-applet rates and frame summaries while profiling is on,
# for walks (plan 0014 D9). Not for applets.
method ProfileStats() -> (on: bool, applets: object, hvs_underruns: ?int)

error NoSuchApplet (applet: string)
error NotOpenable (applet: string)
error Disabled (applet: string)
error NoHandler (name: string)
error NotDeclared (channel: ?string, intent: ?string)
error Reserved (intent: string)
error PayloadTooLarge (intent: string, bytes: int, limit: int)
error NotOffered (applet: string, channel: string)
error NotListening (applet: string)
error NotShareable (channel: string)
error NotAnApplet ()
error NotPermitted ()
error OfferChanged (file: string)
error OfferRefused (file: string, reason: string)
error NotInstalled (applet: string)
error InstallFailed (applet: string, detail: string)
error Unavailable ()
error Busy ()
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
    /// The name of an applet that just crashed, until the next navigation.
    pub stopped: Option<String>,
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
    pub registry: crate::registry::Shared,
    /// The install path (plan 0011 D16); None where there is no systemd
    /// to install into (the tests).
    pub installer: Option<Installer>,
    pub nav: mpsc::UnboundedSender<NavRequest>,
    pub front: watch::Receiver<Front>,
    pub bridge: Bridge,
    /// What applets cost (plan 0012 D8); None where it is not sampled.
    pub energy: Option<crate::energy::Energy>,
    /// The profiler's switch and latest stats (plan 0014 D1, D4).
    pub profiler: Option<crate::profile::Profiler>,
}

/// What installing needs: where the applets live, systemd, and the way
/// to tell vrxhost's session about applets that were not there before.
#[derive(Clone)]
pub struct Installer {
    pub paths: crate::paths::VrxPaths,
    pub applets: crate::applets::Applets,
    /// The applet ids now on the system, after an install or uninstall.
    pub added: mpsc::UnboundedSender<Vec<String>>,
    /// One install-helper call at a time (they share its request file).
    pub lock: std::sync::Arc<tokio::sync::Mutex<()>>,
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
        if method == format!("{INTERFACE}.Facts") && call.more() {
            watch_facts(&mut conn, crate::facts::subscribe()).await;
            return;
        }
        if method == format!("{INTERFACE}.PowerAlerts") && call.more() {
            match (&host.energy, is_shell(&host, applet.as_deref())) {
                (Some(energy), true) => watch_alerts(&mut conn, energy.alerts()).await,
                (None, true) => {
                    let _ = conn
                        .send_error(&Failure::host("Unavailable", json!({})), Vec::new())
                        .await;
                }
                (_, false) => {
                    let _ = conn
                        .send_error(&Failure::host("NotPermitted", json!({})), Vec::new())
                        .await;
                }
            }
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
        let answer =
            dispatch(&host, applet.as_deref(), &method, &call.method().parameters).await;
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
                    Delivery::Route { route, payload, intent } => (
                        json!({ "kind": "route", "route": route, "name": intent, "payload": payload }),
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

/// Whether `caller` may open `to`'s `channel`: the target must offer it
/// (NotOffered), and when the offer names a grant (`requires`, plan 0018
/// D10) the caller must be a built-in whose manifest holds it
/// (NotPermitted, G057). An installed applet holds no system grant, so it
/// can never open a gated channel.
fn channel_gate(
    registry: &Registry,
    caller: Option<&str>,
    to: &str,
    channel: &str,
) -> Result<(), Failure> {
    let offer = registry
        .find(to)
        .and_then(|e| e.manifest.applet.channels.offer(channel))
        .ok_or_else(|| {
            Failure::host("NotOffered", json!({ "applet": to, "channel": channel }))
        })?;
    if let Some(grant) = offer.requires() {
        let holds = caller.is_none_or(|applet| {
            registry.find(applet).is_some_and(|e| {
                e.builtin && e.manifest.applet.permissions.system.contains(&grant)
            })
        });
        if !holds {
            return Err(Failure::host("NotPermitted", json!({})));
        }
    }
    Ok(())
}

/// Open a channel: the caller's manifest must open it and the target's
/// offer it. The descriptor that goes back to the caller, if any. A caller
/// that is no applet (root at the shell: `vrx camera`, a diagnostic, as
/// with intents and `holds`) is the system: it needs no `opens` and passes
/// a `requires`, and the channel's `from` is "system".
fn open(
    host: &Host,
    caller: Option<&str>,
    params: &Value,
    mut fds: Vec<std::os::fd::OwnedFd>,
) -> Result<Vec<std::os::fd::OwnedFd>, Failure> {
    let to = params
        .get("to")
        .and_then(Value::as_str)
        .ok_or_else(|| Failure::invalid("to"))?;
    let channel = params
        .get("channel")
        .and_then(Value::as_str)
        .ok_or_else(|| Failure::invalid("channel"))?;
    let wanted = format!("{to}.{channel}");
    if let Some(caller) = caller {
        let declared = host
            .registry
            .get()
            .find(caller)
            .is_some_and(|e| e.manifest.applet.channels.opens.contains(&wanted));
        if !declared {
            return Err(Failure::host(
                "NotDeclared",
                json!({ "channel": wanted, "intent": null }),
            ));
        }
    }
    channel_gate(&host.registry.get(), caller, to, channel)?;
    let caller = caller.unwrap_or("system");
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

async fn watch_facts(
    conn: &mut zlink::tokio::unix::Connection,
    mut facts: watch::Receiver<crate::facts::Facts>,
) {
    loop {
        let now = facts.borrow_and_update().clone();
        let reply = Reply::new(Some(now)).set_continues(Some(true));
        if conn.send_reply(&reply, Vec::new()).await.is_err() {
            return;
        }
        if facts.changed().await.is_err() {
            return;
        }
    }
}

async fn watch_alerts(
    conn: &mut zlink::tokio::unix::Connection,
    mut alerts: watch::Receiver<Vec<crate::energy::Alert>>,
) {
    loop {
        let now = alerts.borrow_and_update().clone();
        let reply = Reply::new(Some(json!({ "alerts": now }))).set_continues(Some(true));
        if conn.send_reply(&reply, Vec::new()).await.is_err() {
            return;
        }
        if alerts.changed().await.is_err() {
            return;
        }
    }
}

/// The caller holds `grant` (a built-in's manifest says so), or is not an
/// applet at all (the system, a root diagnostic).
fn holds(host: &Host, caller: Option<&str>, grant: vrx_protocol::SystemGrant) -> bool {
    caller.is_none_or(|applet| {
        host.registry.get().find(applet).is_some_and(|e| {
            e.builtin && e.manifest.applet.permissions.system.contains(&grant)
        })
    })
}

/// The caller is the shell (the role), or not an applet at all.
fn is_shell(host: &Host, caller: Option<&str>) -> bool {
    caller.is_none_or(|applet| {
        host.registry
            .get()
            .find(applet)
            .is_some_and(|e| e.builtin && e.manifest.applet.roles.shell)
    })
}

fn energy_of(host: &Host, allowed: bool) -> Result<&crate::energy::Energy, Failure> {
    if !allowed {
        return Err(Failure::host("NotPermitted", json!({})));
    }
    host.energy
        .as_ref()
        .ok_or_else(|| Failure::host("Unavailable", json!({})))
}

async fn dispatch(
    host: &Host,
    caller: Option<&str>,
    method: &str,
    params: &Value,
) -> Result<Value, Failure> {
    let str_param = |name: &str| params.get(name).and_then(Value::as_str);
    match method {
        "io.vrx.Host.Push" => {
            let applet = str_param("applet").ok_or_else(|| Failure::invalid("applet"))?;
            let registry = host.registry.get();
            let entry = registry.find(applet).ok_or_else(|| {
                Failure::host("NoSuchApplet", json!({ "applet": applet }))
            })?;
            // a deep link is a hint (plan 0011 D5): a route the applet does
            // not declare (renamed, or never there) opens its root
            let (route, name) = match str_param("route") {
                None | Some("") => (0, ""),
                Some(name) => match entry.manifest.route_number(name) {
                    Some(number) => (number, name),
                    None => {
                        tracing::warn!(%applet, route = %name, "no such route; opening the root");
                        (0, "")
                    }
                },
            };
            let top = navigate(
                host,
                NavOp::Push {
                    applet: applet.to_owned(),
                    route,
                },
            )
            .await?;
            host.bridge.open_at(applet, name, &Value::Null, None);
            Ok(json!({ "top": top }))
        }
        "io.vrx.Host.Route" => {
            let applet = caller.ok_or_else(|| Failure::host("NotAnApplet", json!({})))?;
            let (route, payload, intent) = host.bridge.route(applet);
            Ok(json!({ "route": route, "payload": payload, "intent": intent }))
        }
        "io.vrx.Host.Pop" => Ok(json!({ "top": navigate(host, NavOp::Pop).await? })),
        "io.vrx.Host.Home" => Ok(json!({ "top": navigate(host, NavOp::Home).await? })),
        "io.vrx.Host.Intent" => {
            let name = str_param("name").ok_or_else(|| Failure::invalid("name"))?;
            let payload = params.get("payload").cloned().unwrap_or(Value::Null);
            let intent = admit_intent(&host.registry.get(), caller, name, payload)?;
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
        "io.vrx.Host.Applets" => Ok(json!({ "applets": tiles(&host.registry.get()) })),
        "io.vrx.Host.Offers" => {
            let installer = may_install(host, caller)?;
            offers(installer).await
        }
        "io.vrx.Host.Install" => {
            let installer = may_install(host, caller)?;
            let file = str_param("file").ok_or_else(|| Failure::invalid("file"))?;
            let build = str_param("build").ok_or_else(|| Failure::invalid("build"))?;
            install(host, installer, file, build).await
        }
        "io.vrx.Host.Uninstall" => {
            let installer = may_install(host, caller)?;
            let applet = str_param("applet").ok_or_else(|| Failure::invalid("applet"))?;
            uninstall(host, installer, applet).await
        }
        "io.vrx.Host.UpdateOffers" => {
            may_update(host, caller)?;
            if let Some(installer) = host.installer.as_ref() {
                let drive_idle = !installer
                    .applets
                    .is_active(crate::install::DRIVE_UNIT)
                    .await;
                let _ = helper(
                    installer,
                    crate::install::Request::ImportUpdates { drive_idle },
                )
                .await;
            }
            crate::update::offers()
                .await
                .map_err(|(e, p)| Failure::host(&e, p))
        }
        "io.vrx.Host.UpdateInstall" => {
            may_update(host, caller)?;
            let file = str_param("file").ok_or_else(|| Failure::invalid("file"))?;
            crate::update::clear_fallback();
            crate::update::install(file)
                .await
                .map_err(|(e, p)| Failure::host(&e, p))
        }
        "io.vrx.Host.UpdateRestart" => {
            may_update(host, caller)?;
            crate::update::restart()
                .await
                .map_err(|(e, p)| Failure::host(&e, p))
        }
        "io.vrx.Host.UpdateStatus" => {
            may_update(host, caller)?;
            crate::update::status()
                .await
                .map_err(|(e, p)| Failure::host(&e, p))
        }
        "io.vrx.Host.WakeAt" => {
            // the time grant's meaning includes alarms and timers
            // (an applet only: the timer is named for it)
            let Some(applet) = caller else {
                return Err(Failure::host("NotPermitted", json!({})));
            };
            if !holds(host, Some(applet), vrx_protocol::SystemGrant::Time) {
                return Err(Failure::host("NotPermitted", json!({})));
            }
            let at = match params.get("at") {
                None | Some(Value::Null) => None,
                Some(v) => Some(v.as_u64().ok_or_else(|| Failure::invalid("at"))?),
            };
            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_or(0, |d| d.as_secs());
            crate::wake::set(applet, at, now)
                .await
                .map(|()| json!({}))
                .map_err(|detail| {
                    Failure::host("Unavailable", json!({ "detail": detail }))
                })
        }
        "io.vrx.Host.PairingWindow" => {
            if !holds(host, caller, vrx_protocol::SystemGrant::Bluetooth) {
                return Err(Failure::host("NotPermitted", json!({})));
            }
            let on = params
                .get("on")
                .and_then(Value::as_bool)
                .ok_or_else(|| Failure::invalid("on"))?;
            let seconds = match params.get("seconds") {
                None | Some(Value::Null) => 180,
                Some(v) => v
                    .as_u64()
                    .filter(|s| {
                        (1..=u64::from(crate::bt_arbiter::DEVICE_LINK_CEILING))
                            .contains(s)
                    })
                    .and_then(|s| u32::try_from(s).ok())
                    .ok_or_else(|| Failure::invalid("seconds"))?,
            };
            crate::bt_arbiter::device_link(on, seconds)
                .await
                .map(|()| json!({}))
                .map_err(|why| match why {
                    crate::bt_arbiter::Refused::Busy => Failure::host("Busy", json!({})),
                    crate::bt_arbiter::Refused::Unavailable(detail) => {
                        Failure::host("Unavailable", json!({ "detail": detail }))
                    }
                })
        }
        "io.vrx.Host.Settings" => {
            Ok(json!({ "applets": declared_settings(&host.registry.get()) }))
        }
        "io.vrx.Host.Watch" => {
            Ok(serde_json::to_value(host.front.borrow().clone()).unwrap_or(Value::Null))
        }
        "io.vrx.Host.Energy" => {
            let energy = energy_of(
                host,
                holds(host, caller, vrx_protocol::SystemGrant::PowerStats),
            )?;
            let hours = params
                .get("hours")
                .and_then(Value::as_u64)
                .map_or(24, |h| u32::try_from(h).unwrap_or(24));
            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_or(0, |d| d.as_secs());
            Ok(serde_json::to_value(energy.report(hours, now)).unwrap_or(Value::Null))
        }
        "io.vrx.Host.Awake" => {
            let energy = energy_of(
                host,
                holds(host, caller, vrx_protocol::SystemGrant::PowerStats),
            )?;
            Ok(serde_json::to_value(energy.awake().await).unwrap_or(Value::Null))
        }
        "io.vrx.Host.PowerAlerts" => {
            let energy = energy_of(host, is_shell(host, caller))?;
            Ok(json!({ "alerts": *energy.alerts().borrow() }))
        }
        "io.vrx.Host.PowerAlertAnswer" => {
            let energy = energy_of(host, is_shell(host, caller))?;
            let applet = str_param("applet").ok_or_else(|| Failure::invalid("applet"))?;
            let answer = str_param("answer").ok_or_else(|| Failure::invalid("answer"))?;
            energy
                .answer(applet, answer)
                .await
                .map(|()| json!({}))
                .map_err(|_| Failure::invalid("answer"))
        }
        "io.vrx.Host.Profiling" => {
            let p = host
                .profiler
                .as_ref()
                .ok_or_else(|| Failure::host("Unavailable", json!({})))?;
            match params.get("on").and_then(Value::as_bool) {
                None => Ok(serde_json::to_value(p.status()).unwrap_or(Value::Null)),
                Some(_) if caller.is_some() => {
                    Err(Failure::host("NotPermitted", json!({})))
                }
                Some(on) => p
                    .set(on)
                    .map(|st| serde_json::to_value(st).unwrap_or(Value::Null))
                    .map_err(|detail| {
                        Failure::host("Unavailable", json!({ "detail": detail }))
                    }),
            }
        }
        "io.vrx.Host.FrameStats" => {
            let applet = caller.ok_or_else(|| Failure::host("NotAnApplet", json!({})))?;
            let p = host
                .profiler
                .as_ref()
                .ok_or_else(|| Failure::host("Unavailable", json!({})))?;
            let frames: crate::profile::Frames =
                serde_json::from_value(params.clone())
                    .map_err(|_| Failure::invalid("frames"))?;
            p.frames(applet, frames);
            Ok(json!({}))
        }
        "io.vrx.Host.Semantics" => {
            if caller.is_some() {
                return Err(Failure::host("NotPermitted", json!({})));
            }
            let p = host
                .profiler
                .as_ref()
                .ok_or_else(|| Failure::host("Unavailable", json!({})))?;
            let on = params
                .get("on")
                .and_then(Value::as_bool)
                .ok_or_else(|| Failure::invalid("on"))?;
            Ok(json!({ "on": p.set_semantics(on) }))
        }
        "io.vrx.Host.ProfileStats" => {
            if caller.is_some() {
                return Err(Failure::host("NotPermitted", json!({})));
            }
            let p = host
                .profiler
                .as_ref()
                .ok_or_else(|| Failure::host("Unavailable", json!({})))?;
            let (stats, underruns) = p.stats();
            Ok(
                json!({ "on": p.status().on, "applets": stats, "hvs_underruns": underruns }),
            )
        }
        "io.vrx.Host.UsbEject" => {
            let applets = may_usb(host, caller)?;
            let mount = str_param("mount").ok_or_else(|| Failure::invalid("mount"))?;
            if !crate::usb::mount_ok(mount) {
                return Err(Failure::invalid("mount"));
            }
            for unit in crate::usb::mount_units(mount) {
                if let Err(err) = applets.stop_unit(&unit).await {
                    tracing::debug!(%unit, error = %err, "usb eject");
                }
            }
            Ok(json!({}))
        }
        "io.vrx.Host.UsbPolicy" => {
            may_usb(host, caller)?;
            let allow = params
                .get("allow_new")
                .and_then(Value::as_bool)
                .ok_or_else(|| Failure::invalid("allow_new"))?;
            if crate::facts::subscribe().borrow().usb_policy != "allowlist" {
                return Err(Failure::host("Unavailable", json!({})));
            }
            crate::usb::set_allow_new(allow).await.map_err(|detail| {
                tracing::warn!(%detail, "usb policy");
                Failure::host("Unavailable", json!({}))
            })?;
            crate::facts::update(|f| f.usb_allow_new = allow);
            Ok(json!({}))
        }
        "io.vrx.Host.Facts" => Ok(serde_json::to_value(
            crate::facts::subscribe().borrow().clone(),
        )
        .unwrap_or(Value::Null)),
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

/// The intent contract at the socket (plan 0011 D9, G022): the name well
/// formed, the payload at most 4 KiB, and from an applet only what its
/// manifest emits, a `sys.` name only from a built-in. A caller that is
/// no applet (vrxhost's own sources, a root tool on the bench) is the
/// system and may send any well-formed intent.
fn admit_intent(
    registry: &Registry,
    caller: Option<&str>,
    name: &str,
    payload: Value,
) -> Result<Intent, Failure> {
    use vrx_protocol::intent::{is_reserved, IntentError, PAYLOAD_MAX_BYTES};
    let intent = Intent::new(name, payload).map_err(|err| match err {
        IntentError::PayloadTooLarge { bytes, .. } => Failure::host(
            "PayloadTooLarge",
            json!({ "intent": name, "bytes": bytes, "limit": PAYLOAD_MAX_BYTES }),
        ),
        IntentError::BadName { .. } | IntentError::NameTooLong { .. } => {
            Failure::invalid("name")
        }
    })?;
    let Some(applet) = caller else {
        return Ok(intent);
    };
    let entry = registry.find(applet);
    if is_reserved(name) && !entry.is_some_and(|e| e.builtin) {
        tracing::warn!(%applet, intent = %name, "refused: sys. is the system's");
        return Err(Failure::host("Reserved", json!({ "intent": name })));
    }
    if !entry.is_some_and(|e| e.manifest.applet.intents.emits.iter().any(|n| n == name)) {
        tracing::warn!(%applet, intent = %name, "refused: not in its manifest's emits");
        return Err(Failure::host(
            "NotDeclared",
            json!({ "channel": null, "intent": name }),
        ));
    }
    Ok(intent)
}

/// Route an intent through its handlers in order (intent.rs): an opened
/// one is pushed (and told over its Listen when running); a told one is
/// asked and has the answer budget. The Varlink `Intent` call and
/// vrxhost's own sources (the USB watcher) share it.
async fn deliver(host: &Host, intent: &Intent) -> Result<Value, Failure> {
    let order = handlers(&host.registry.get(), intent);
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
                let name = host
                    .registry
                    .get()
                    .find(&applet)
                    .and_then(|e| e.manifest.route_name(route))
                    .unwrap_or("")
                    .to_owned();
                host.bridge
                    .open_at(&applet, &name, &intent.payload, Some(&intent.name));
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

/// Route an intent vrxhost raises itself and say whether a handler took
/// it (opened or handled); the outcome is logged.
pub async fn route(host: &Host, intent: Intent) -> bool {
    match deliver(host, &intent).await {
        Ok(verdict) => {
            tracing::info!(intent = %intent.name, %verdict, "raised");
            verdict.get("verdict").and_then(Value::as_str) != Some("pass")
        }
        Err(failure) => {
            tracing::warn!(intent = %intent.name, error = %failure.error, "raised; not handled");
            false
        }
    }
}

/// An intent vrxhost raises itself; the outcome is logged.
pub async fn raise(host: &Host, intent: Intent) {
    route(host, intent).await;
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

/// The install methods are for callers holding the `apps` grant (and the
/// system); there must be a systemd to install into.
fn may_install<'a>(
    host: &'a Host,
    caller: Option<&str>,
) -> Result<&'a Installer, Failure> {
    if !holds(host, caller, vrx_protocol::SystemGrant::Apps) {
        return Err(Failure::host("NotPermitted", json!({})));
    }
    host.installer
        .as_ref()
        .ok_or_else(|| Failure::host("Unavailable", json!({})))
}

/// The update methods are for built-ins holding the `update` grant (and
/// the system).
fn may_update(host: &Host, caller: Option<&str>) -> Result<(), Failure> {
    if !holds(host, caller, vrx_protocol::SystemGrant::Update) {
        return Err(Failure::host("NotPermitted", json!({})));
    }
    Ok(())
}

/// The USB host actions (plan 0019 D10) are for built-ins holding the
/// `usb` grant (and the system); they need systemd.
fn may_usb<'a>(
    host: &'a Host,
    caller: Option<&str>,
) -> Result<&'a crate::applets::Applets, Failure> {
    if !holds(host, caller, vrx_protocol::SystemGrant::Usb) {
        return Err(Failure::host("NotPermitted", json!({})));
    }
    host.installer
        .as_ref()
        .map(|i| &i.applets)
        .ok_or_else(|| Failure::host("Unavailable", json!({})))
}

/// A drive was mounted (plan 0019 D9): its offers and bundles are brought
/// in now, so they wait before anyone opens Manage or Settings.
pub async fn import_drives(host: &Host) {
    let Some(installer) = host.installer.as_ref() else {
        return;
    };
    let drive_idle = !installer
        .applets
        .is_active(crate::install::DRIVE_UNIT)
        .await;
    if let Err(err) =
        helper(installer, crate::install::Request::Import { drive_idle }).await
    {
        tracing::warn!(error = %err.error, "drive import");
    }
}

/// Run one request in vrx-install.service (install.rs, the privileged
/// half) and return its outcome; an outcome naming an error is that
/// error.
async fn helper(
    installer: &Installer,
    request: crate::install::Request,
) -> Result<Value, Failure> {
    use crate::install::{HELPER_DIR, HELPER_UNIT};
    let failed = |detail: String| {
        tracing::error!(%detail, "install helper");
        Failure::host("InstallFailed", json!({ "applet": "", "detail": detail }))
    };
    let _one = installer.lock.lock().await;
    let dir = Path::new(HELPER_DIR);
    std::fs::create_dir_all(dir).map_err(|e| failed(e.to_string()))?;
    let _ = std::fs::remove_file(dir.join("result.json"));
    let text = serde_json::to_string(&request).map_err(|e| failed(e.to_string()))?;
    std::fs::write(dir.join("request.json"), text).map_err(|e| failed(e.to_string()))?;
    let result = installer
        .applets
        .run_oneshot(HELPER_UNIT)
        .await
        .map_err(|e| failed(e.to_string()))?;
    if result != "done" {
        return Err(failed(format!("{HELPER_UNIT}: {result}")));
    }
    let outcome: Value = std::fs::read_to_string(dir.join("result.json"))
        .map_err(|e| e.to_string())
        .and_then(|t| serde_json::from_str(&t).map_err(|e| e.to_string()))
        .map_err(failed)?;
    match outcome.get("error").and_then(Value::as_str) {
        Some(error) => Err(Failure::host(
            error,
            outcome.get("parameters").cloned().unwrap_or(Value::Null),
        )),
        None => Ok(outcome),
    }
}

async fn offers(installer: &Installer) -> Result<Value, Failure> {
    let drive_idle = !installer
        .applets
        .is_active(crate::install::DRIVE_UNIT)
        .await;
    helper(installer, crate::install::Request::Offers { drive_idle }).await
}

/// Scan again after an install or uninstall, and tell the session which
/// applets are now on the system.
fn rescan(host: &Host, installer: &Installer) {
    match crate::registry::scan(&installer.paths) {
        Ok(registry) => {
            let ids = registry
                .iter()
                .map(|e| e.manifest.applet.id.clone())
                .collect();
            host.registry.set(registry);
            let _ = installer.added.send(ids);
        }
        Err(err) => {
            tracing::error!(error = %err, "registry scan after an install failed")
        }
    }
}

async fn install(
    host: &Host,
    installer: &Installer,
    file: &str,
    build: &str,
) -> Result<Value, Failure> {
    let request = crate::install::Request::Install {
        file: file.to_owned(),
        build: build.to_owned(),
    };
    let outcome = helper(installer, request).await?;
    let id = outcome
        .get("id")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_owned();
    let failed = |detail: String| {
        tracing::error!(applet = %id, %detail, "install failed");
        Failure::host("InstallFailed", json!({ "applet": id, "detail": detail }))
    };
    crate::install::refresh().await.map_err(failed)?;
    installer
        .applets
        .reload()
        .await
        .map_err(|e| failed(e.to_string()))?;
    rescan(host, installer);
    tracing::info!(applet = %id, version = ?outcome.get("version"), %build, "installed");
    Ok(json!({ "id": id }))
}

async fn uninstall(
    host: &Host,
    installer: &Installer,
    applet: &str,
) -> Result<Value, Failure> {
    if host.registry.get().find(applet).is_none_or(|e| e.builtin) {
        return Err(Failure::host("NotInstalled", json!({ "applet": applet })));
    }
    let failed = |detail: String| {
        tracing::error!(%applet, %detail, "uninstall failed");
        Failure::host(
            "InstallFailed",
            json!({ "applet": applet, "detail": detail }),
        )
    };
    installer
        .applets
        .stop(applet)
        .await
        .map_err(|e| failed(e.to_string()))?;
    let request = crate::install::Request::Uninstall {
        applet: applet.to_owned(),
    };
    // whatever the helper could not delete, what it did delete (the
    // image first) is merged out and forgotten
    let removed = helper(installer, request).await;
    crate::install::refresh().await.map_err(failed)?;
    installer
        .applets
        .reload()
        .await
        .map_err(|e| failed(e.to_string()))?;
    rescan(host, installer);
    removed?;
    tracing::info!(%applet, "uninstalled");
    Ok(json!({}))
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
            stopped: None,
        });
        let host = Host {
            registry: crate::registry::Shared::new(registry()),
            installer: None,
            nav: nav_tx,
            front: front_rx,
            bridge: Bridge::default(),
            energy: None,
            profiler: None,
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

        // an undeclared route opens the root (plan 0011 D5)
        let r = call(&mut s, json!({"method": "io.vrx.Host.Push", "parameters": {"applet": "clock", "route": "nope"}})).await;
        assert_eq!(r[0]["parameters"]["top"], "clock", "{r:?}");

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

        // the energy methods (plan 0012 D12): a caller that is not an
        // applet may ask; nothing is sampled in this host
        for m in ["Energy", "Awake", "PowerAlerts"] {
            let r = call(&mut s, json!({"method": format!("io.vrx.Host.{m}")})).await;
            assert_eq!(r[0]["error"], "io.vrx.Host.Unavailable", "{m}: {r:?}");
        }
        let r = call(&mut s, json!({"method": "org.varlink.service.GetInterfaceDescription", "parameters": {"interface": "io.vrx.Host"}})).await;
        let idl = r[0]["parameters"]["description"].as_str().unwrap();
        assert!(
            idl.contains("method Energy(") && idl.contains("method PowerAlertAnswer(")
        );
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
                stopped: Some("Clock".into()),
            })
            .unwrap();
        let second = read_one().await;
        assert_eq!(second["parameters"]["front"], "clock", "{second}");
        assert_eq!(second["parameters"]["depth"], 2, "{second}");
        assert_eq!(second["parameters"]["stopped"], "Clock", "{second}");
    }

    /// G057: a channel that names a grant opens only for a built-in that
    /// holds it; one that names none is unchanged.
    #[test]
    fn a_gated_channel_needs_the_grant_g057() {
        let mut r = Registry::new();
        for (id, builtin, extra) in [
            (
                "camerad",
                true,
                "kind = \"service\"\n[applet.permissions]\nsystem = [\"camera\"]\n\
                 [applet.channels]\noffers = [{ name = \"frames\", requires = \"camera-use\" }, \"plain\"]\n",
            ),
            ("viewer", true, "[applet.permissions]\nsystem = [\"camera-use\"]\n"),
            ("nosy", true, ""),
            ("sideloaded", false, ""),
        ] {
            let text = format!(
                "[applet]\nid = \"{id}\"\nname = \"N\"\nversion = \"1.0.0\"\nruntime = \"rust\"\n{extra}"
            );
            r.admit(RegistryEntry {
                manifest: text.parse().unwrap(),
                path: PathBuf::from("/x").join(id),
                builtin,
            })
            .unwrap();
        }
        let verdict = |caller: &str, channel: &str| {
            channel_gate(&r, Some(caller), "camerad", channel)
                .map(|()| "ok".to_owned())
                .unwrap_or_else(|f| f.error)
        };
        assert_eq!(verdict("viewer", "frames"), "ok");
        assert_eq!(verdict("nosy", "frames"), "io.vrx.Host.NotPermitted");
        assert_eq!(verdict("sideloaded", "frames"), "io.vrx.Host.NotPermitted");
        assert_eq!(
            verdict("nosy", "plain"),
            "ok",
            "an ungated offer is unchanged"
        );
        assert_eq!(verdict("viewer", "ghost"), "io.vrx.Host.NotOffered");
        assert!(
            channel_gate(&r, None, "camerad", "frames").is_ok(),
            "root at the shell is the system"
        );
    }

    /// Plan 0019 D10: eject and the policy switch are the usb grant's; an
    /// applet without it is NotPermitted, one with it (or the system)
    /// reaches systemd, which this host has none of.
    #[tokio::test]
    async fn the_usb_actions_need_the_usb_grant() {
        let mut r = Registry::new();
        for (id, builtin, extra) in [
            (
                "settings",
                true,
                "[applet.permissions]\nsystem = [\"usb\"]\n",
            ),
            ("nosy", true, ""),
            ("sideloaded", false, ""),
        ] {
            let text = format!(
                "[applet]\nid = \"{id}\"\nname = \"N\"\nversion = \"1.0.0\"\nruntime = \"rust\"\n{extra}"
            );
            r.admit(RegistryEntry {
                manifest: text.parse().unwrap(),
                path: PathBuf::from("/x").join(id),
                builtin,
            })
            .unwrap();
        }
        let (nav, _) = mpsc::unbounded_channel();
        let (_front_tx, front) = watch::channel(Front::default());
        let host = Host {
            registry: crate::registry::Shared::new(r),
            installer: None,
            nav,
            front,
            bridge: Bridge::default(),
            energy: None,
            profiler: None,
        };
        let eject = json!({ "mount": "/run/vrx/usb/1-1.2-p1" });
        let policy = json!({ "allow_new": false });
        for (method, params) in [
            ("io.vrx.Host.UsbEject", &eject),
            ("io.vrx.Host.UsbPolicy", &policy),
        ] {
            for caller in ["nosy", "sideloaded"] {
                let e = dispatch(&host, Some(caller), method, params)
                    .await
                    .unwrap_err();
                assert_eq!(e.error, "io.vrx.Host.NotPermitted", "{caller} {method}");
            }
            for caller in [Some("settings"), None] {
                let e = dispatch(&host, caller, method, params).await.unwrap_err();
                assert_eq!(e.error, "io.vrx.Host.Unavailable", "{caller:?} {method}");
            }
        }
    }

    fn builtin_and_installed() -> Registry {
        let mut r = registry();
        for (id, builtin, extra) in [
            ("web", true, "[applet.intents]\nemits = [\"web.done\"]\n"),
            (
                "notes",
                false,
                "[applet.intents]\nemits = [\"notes.saved\"]\n",
            ),
        ] {
            let text = format!(
                "[applet]\nid = \"{id}\"\nname = \"N\"\nversion = \"1.0.0\"\nruntime = \"flutter\"\n{extra}"
            );
            r.admit(RegistryEntry {
                manifest: text.parse().unwrap(),
                path: PathBuf::from("/x").join(id),
                builtin,
            })
            .unwrap();
        }
        r
    }

    fn refusal(r: Result<Intent, Failure>) -> String {
        r.map(|_| "admitted".to_owned()).unwrap_or_else(|f| f.error)
    }

    /// G022: each refusal of the intent contract fires, and what an
    /// applet declares goes through.
    #[test]
    fn the_intent_contract_refuses_by_name_g022() {
        let r = builtin_and_installed();
        let null = Value::Null;
        // clock is built in and emits nothing in this registry
        assert_eq!(
            refusal(admit_intent(&r, Some("web"), "web.done", null.clone())),
            "admitted"
        );
        assert_eq!(
            refusal(admit_intent(&r, Some("web"), "web.other", null.clone())),
            "io.vrx.Host.NotDeclared"
        );
        assert_eq!(
            refusal(admit_intent(
                &r,
                Some("web"),
                "sys.alarm.ring",
                null.clone()
            )),
            "io.vrx.Host.NotDeclared",
            "a built-in still sends only what it declares"
        );
        assert_eq!(
            refusal(admit_intent(
                &r,
                Some("notes"),
                "sys.alarm.ring",
                null.clone()
            )),
            "io.vrx.Host.Reserved"
        );
        assert_eq!(
            refusal(admit_intent(&r, Some("notes"), "notes.saved", null.clone())),
            "admitted"
        );
        let big = json!({ "d": "x".repeat(5000) });
        assert_eq!(
            refusal(admit_intent(&r, Some("web"), "web.done", big.clone())),
            "io.vrx.Host.PayloadTooLarge"
        );
        assert_eq!(
            refusal(admit_intent(&r, None, "web.done", big)),
            "io.vrx.Host.PayloadTooLarge",
            "the bound holds for the system too"
        );
        assert_eq!(
            refusal(admit_intent(&r, None, "sys.usb.connected", null)),
            "admitted",
            "no applet: the system"
        );
    }
}
