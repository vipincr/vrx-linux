// vrxhost's side of Matter (plan 0015 D9, D12, G043). vrx-matter speaks
// Matter on the network and is reachable from it, so it holds no power
// over the device: it cannot even connect to io.vrx.Host. vrxhost
// connects to it instead, as root, on two connections to io.vrx.Matter:
//
// - `Link`, held with "more": each reply is a command a home app gave;
// - calls: `Host` (the screen, its brightness and the exposed set, sent
//   whenever one changes) and `Done` (a command's outcome).
//
// Every command is checked here against the allow-list read fresh from
// vrx.conf and the registry (vrx_protocol::matter, G043), then carried out
// by the part that owns it: the compositor turns the screen on or off,
// the shell writes the brightness through ScreenSettings (the told intent
// `sys.screen.brightness`), an exposed applet is told its own intent.
// vrx-matter's request for Bluetooth goes to the arbiter (bt_arbiter.rs,
// D4), which also takes the adapter back when the link drops.

use std::time::Duration;

use serde_json::{json, Value};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixStream;
use tokio::sync::{mpsc, watch};
use vrx_protocol::matter::{self, Command, Exposure, HostState, LinkCommand};
use vrx_protocol::Intent;

use crate::bridge::ANSWER_BUDGET;
use crate::compositor::Control;
use crate::varlink::{self, Host};

/// The intent the shell handles to set the brightness (its manifest).
pub const BRIGHTNESS: &str = "sys.screen.brightness";

/// How long to wait before connecting again: vrx-matter restarts when its
/// endpoints change.
const RETRY: Duration = Duration::from_secs(2);

/// One Varlink connection: JSON objects, each ending in a NUL.
struct Conn {
    stream: UnixStream,
    pending: Vec<u8>,
}

impl Conn {
    async fn connect() -> std::io::Result<Self> {
        Ok(Self {
            stream: UnixStream::connect(matter::SOCKET).await?,
            pending: Vec::new(),
        })
    }

    async fn send(
        &mut self,
        method: &str,
        parameters: Value,
        more: bool,
    ) -> std::io::Result<()> {
        let mut call = json!({ "method": method, "parameters": parameters });
        if more {
            call["more"] = json!(true);
        }
        let mut bytes = serde_json::to_vec(&call).map_err(std::io::Error::other)?;
        bytes.push(0);
        self.stream.write_all(&bytes).await
    }

    /// The next message. Cancel-safe: a read that is dropped took nothing,
    /// and bytes already read stay pending.
    async fn recv(&mut self) -> std::io::Result<Value> {
        loop {
            if let Some(end) = self.pending.iter().position(|&b| b == 0) {
                let message: Vec<u8> = self.pending.drain(..=end).collect();
                return serde_json::from_slice(&message[..end])
                    .map_err(std::io::Error::other);
            }
            let mut buf = [0u8; 4096];
            let n = self.stream.read(&mut buf).await?;
            if n == 0 {
                return Err(std::io::ErrorKind::UnexpectedEof.into());
            }
            self.pending.extend_from_slice(&buf[..n]);
        }
    }

    /// A call and its reply; an error reply is an error.
    async fn call(&mut self, method: &str, parameters: Value) -> std::io::Result<Value> {
        self.send(method, parameters, false).await?;
        let reply = self.recv().await?;
        match reply.get("error").and_then(Value::as_str) {
            Some(error) => Err(std::io::Error::other(format!("{method}: {error}"))),
            None => Ok(reply),
        }
    }
}

/// What vrx-matter is told: the screen and the exposed set, now.
fn state(host: &Host, exposure: &Exposure) -> HostState {
    let facts = crate::facts::subscribe().borrow().clone();
    HostState {
        screen_on: facts.screen_on,
        brightness: facts.brightness,
        screen: exposure.screen,
        applets: matter::exposed(&host.registry.get(), exposure),
        exposable: matter::exposable(&host.registry.get()),
    }
}

/// Carry out one command, after the G043 check; true when it was done.
pub async fn carry_out(
    host: &Host,
    screen: &mpsc::UnboundedSender<Control>,
    exposure: &Exposure,
    command: &Command,
) -> bool {
    let refused = |why: matter::Refusal| {
        tracing::warn!(?command, %why, "Matter command refused (G043)");
        false
    };
    match command {
        Command::Screen { on } => match matter::screen_allowed(exposure) {
            Ok(()) => screen.send(Control::Screen(*on)).is_ok(),
            Err(why) => refused(why),
        },
        Command::Brightness { position } => match matter::screen_allowed(exposure) {
            Ok(()) => match Intent::new(BRIGHTNESS, json!({ "position": position })) {
                Ok(intent) => varlink::route(host, intent).await,
                Err(_) => false,
            },
            Err(why) => refused(why),
        },
        Command::OnOff { applet, on } => {
            match matter::command_intent(&host.registry.get(), exposure, applet, *on) {
                // told to that applet alone: a home app switches this
                // applet's thing, never whichever handler comes first
                Ok(name) => {
                    host.bridge
                        .ask(applet, &name, &json!({}), ANSWER_BUDGET)
                        .await
                        == Some(true)
                }
                Err(why) => refused(why),
            }
        }
        // vrx-matter's BLE transport asks the arbiter for the adapter
        // (D4, G044): the window's ceiling is the arbiter's too
        Command::Advertise { secs } => crate::bt_arbiter::matter_acquire(*secs).await,
        Command::AdvertiseEnd => {
            crate::bt_arbiter::matter_release().await;
            true
        }
    }
}

/// The allow-list now and on every change of vrx.conf (inotify, through
/// the SDK's watched file).
pub fn exposure() -> watch::Receiver<Exposure> {
    let (tx, rx) = watch::channel(Exposure::read());
    std::thread::spawn(move || {
        let watched = vrx::ipc::File::watch(matter::SETTINGS_FILE);
        if let Err(err) = watched.watch_forever(|text| {
            tx.send_replace(Exposure::parse(text));
        }) {
            tracing::warn!(error = %err, "the Matter allow-list is read only at start");
        }
    });
    rx
}

/// Hold the link to vrx-matter forever, reconnecting when it restarts.
pub async fn run(
    host: Host,
    screen: mpsc::UnboundedSender<Control>,
    mut allowed: watch::Receiver<Exposure>,
) {
    let mut announced = false;
    loop {
        let served = serve(&host, &screen, &mut allowed).await;
        // a vrx-matter that is gone advertises nothing: the adapter goes
        // back to Device Link (D4)
        crate::bt_arbiter::matter_release().await;
        match served {
            Ok(()) => return,
            Err(err) => {
                if !announced {
                    tracing::info!(error = %err, "Matter link down; retrying");
                    announced = true;
                }
            }
        }
        tokio::time::sleep(RETRY).await;
    }
}

async fn serve(
    host: &Host,
    screen: &mpsc::UnboundedSender<Control>,
    allowed: &mut watch::Receiver<Exposure>,
) -> std::io::Result<()> {
    let mut link = Conn::connect().await?;
    let mut ctl = Conn::connect().await?;
    link.send(&format!("{}.Link", matter::INTERFACE), json!({}), true)
        .await?;
    tracing::info!("Matter link up");
    let mut facts = crate::facts::subscribe();
    let mut registry = host.registry.changes();
    let (done_tx, mut done_rx) = mpsc::unbounded_channel::<(u64, bool)>();
    let mut sent: Option<HostState> = None;
    loop {
        let now = state(host, &allowed.borrow());
        if sent.as_ref() != Some(&now) {
            let params = serde_json::to_value(&now).map_err(std::io::Error::other)?;
            ctl.call(&format!("{}.Host", matter::INTERFACE), params)
                .await?;
            sent = Some(now);
        }
        tokio::select! {
            reply = link.recv() => {
                let reply = reply?;
                if let Some(error) = reply.get("error").and_then(Value::as_str) {
                    return Err(std::io::Error::other(format!("Link: {error}")));
                }
                let Some(command) = reply
                    .get("parameters")
                    .cloned()
                    .and_then(|p| serde_json::from_value::<LinkCommand>(p).ok())
                else {
                    tracing::warn!(%reply, "Matter link: not a command");
                    continue;
                };
                let (host, screen, done) = (host.clone(), screen.clone(), done_tx.clone());
                tokio::spawn(async move {
                    // the allow-list as the file says now, never a copy
                    // older than the person's last switch
                    let ok = carry_out(&host, &screen, &Exposure::read(), &command.command).await;
                    tracing::info!(command = ?command.command, ok, "Matter command");
                    let _ = done.send((command.id, ok));
                });
            }
            Some((id, ok)) = done_rx.recv() => {
                ctl.call(&format!("{}.Done", matter::INTERFACE), json!({ "id": id, "ok": ok })).await?;
            }
            changed = facts.changed() => if changed.is_err() { return Ok(()) },
            changed = registry.changed() => if changed.is_err() { return Ok(()) },
            changed = allowed.changed() => if changed.is_err() { return Ok(()) },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::sync::oneshot;
    use vrx_protocol::{Registry, RegistryEntry};

    fn host() -> (Host, mpsc::UnboundedReceiver<crate::varlink::NavRequest>) {
        let mut r = Registry::new();
        let clock = "[applet]\nid = \"clock\"\nname = \"Clock\"\nversion = \"1\"\nruntime = \"rust\"\n[applet.intents]\nhandles = [{ name = \"vrx.clock.alarm.arm\", priority = 500 }, { name = \"vrx.clock.alarm.disarm\", priority = 500 }]\n[applet.matter]\ndevice_type = \"on_off_plug\"\nclusters = [\"on_off\"]\non_off.command.on = \"vrx.clock.alarm.arm\"\non_off.command.off = \"vrx.clock.alarm.disarm\"\n";
        r.admit(RegistryEntry {
            manifest: clock.parse().unwrap(),
            path: "/x".into(),
            builtin: true,
        })
        .unwrap();
        let (nav, nav_rx) = mpsc::unbounded_channel();
        let (_, front) = watch::channel(crate::varlink::Front::default());
        let host = Host {
            registry: crate::registry::Shared::new(r),
            installer: None,
            nav,
            front,
            bridge: crate::bridge::Bridge::default(),
            energy: None,
            profiler: None,
        };
        (host, nav_rx)
    }

    /// G043 at the point of action: nothing reaches the compositor or an
    /// applet unless the person exposed it.
    #[tokio::test]
    async fn commands_are_carried_out_only_when_exposed_g043() {
        let (host, _nav) = host();
        let (screen, mut orders) = mpsc::unbounded_channel();
        let hidden = Exposure::parse("matter_screen=false");
        assert!(
            !carry_out(&host, &screen, &hidden, &Command::Screen { on: false }).await
        );
        assert!(orders.try_recv().is_err(), "nothing sent to the compositor");
        let shown = Exposure::default();
        assert!(carry_out(&host, &screen, &shown, &Command::Screen { on: false }).await);
        assert_eq!(orders.try_recv().ok(), Some(Control::Screen(false)));

        // clock is not on the allow-list: refused before any delivery
        let command = Command::OnOff {
            applet: "clock".into(),
            on: true,
        };
        assert!(!carry_out(&host, &screen, &shown, &command).await);
        // allowed, but the applet is not listening: not done
        let exposed = Exposure::parse("matter_expose=clock");
        assert!(!carry_out(&host, &screen, &exposed, &command).await);
    }

    /// An exposed applet is told its own intent and its answer is the
    /// outcome.
    #[tokio::test]
    async fn an_exposed_applet_is_told_its_intent() {
        let (host, _nav) = host();
        let (screen, _orders) = mpsc::unbounded_channel();
        let (_, mut deliveries) = host.bridge.listen("clock");
        let (seen_tx, seen) = oneshot::channel();
        let bridge = host.bridge.clone();
        tokio::spawn(async move {
            if let Some(crate::bridge::Delivery::Intent { id, name, .. }) =
                deliveries.recv().await
            {
                let _ = seen_tx.send(name);
                if let Some(id) = id {
                    bridge.answer(id, true);
                }
            }
        });
        let exposed = Exposure::parse("matter_expose=clock");
        let command = Command::OnOff {
            applet: "clock".into(),
            on: false,
        };
        assert!(carry_out(&host, &screen, &exposed, &command).await);
        assert_eq!(seen.await.unwrap(), "vrx.clock.alarm.disarm");
    }
}
