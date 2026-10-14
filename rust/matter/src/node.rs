// The Matter node (plan 0015 D1, D2, D3, D12): rs-matter's stack on the
// device's IP network, mDNS through Avahi, the fabrics in the state
// directory. Endpoint 0 is the root node; 1 the screen, a Dimmable
// Plug-in Unit whose On/Off is the screen lit and whose Level is the
// brightness; 2 an aggregator, and under it one bridged On/Off Plug-in
// Unit per exposed applet. Every command goes to vrxhost (link.rs) and
// its outcome is the Matter status; every attribute follows vrxhost's
// facts or the last command given.
//
// rs-matter's state is not Send: the whole stack runs on one thread
// (main.rs gives it a current-thread runtime of its own).

use core::cell::{Cell, RefCell};
use core::pin::pin;
use std::net::UdpSocket;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use embassy_futures::select::{select, select4, Either};
use rand::Rng;
use rs_matter::crypto::{default_crypto, Crypto};
use rs_matter::dm::clusters::app::level_control::{self, LevelControlHooks};
use rs_matter::dm::clusters::app::on_off::{self, OnOffHooks};
use rs_matter::dm::clusters::basic_info::BasicInfoConfig;
use rs_matter::dm::clusters::decl::bridged_device_basic_information::{
    self as bridged_info, ClusterHandler as _, KeepActiveRequest,
};
use rs_matter::dm::clusters::decl::level_control::{
    AttributeId as LevelAttr, CommandId as LevelCmd, OptionsBitmap,
    FULL_CLUSTER as LEVEL_FULL,
};
use rs_matter::dm::clusters::decl::on_off as on_off_decl;
use rs_matter::dm::clusters::desc::{self, ClusterHandler as _};
// the ids the SDK's test DAC is issued for: a debug image's (G042)
use rs_matter::dm::devices::test::{TEST_PID, TEST_VID};
use rs_matter::dm::devices::{DEV_TYPE_AGGREGATOR, DEV_TYPE_BRIDGED_NODE};
use rs_matter::dm::endpoints;
use rs_matter::dm::networks::eth::EthNetwork;
use rs_matter::dm::networks::SysNetifs;
use rs_matter::dm::{
    Async, Cluster, DataModel, Dataver, DeviceType, Endpoint, InvokeContext, Node,
    ReadContext,
};
use rs_matter::error::{Error, ErrorCode};
use rs_matter::im::{EthInteractionModelState, InteractionModel};
use rs_matter::pairing::qr::{no_optional_data, CommFlowType, NoOptionalData, QrPayload};
use rs_matter::pairing::DiscoveryCapabilities;
use rs_matter::persist::DirKvBlobStore;
use rs_matter::respond::DefaultResponder;
use rs_matter::sc::pase::CommWindowState;
use rs_matter::sc::pase::{Spake2pVerifierPassword, Spake2pVerifierPasswordRef};
use rs_matter::tlv::{Nullable, TLVBuilderParent, Utf8StrBuilder};
use rs_matter::transport::exchange::MatterBuffers;
use rs_matter::transport::network::btp::Btp;
use rs_matter::transport::network::{Address, ChainedNetwork};
use rs_matter::transport::MATTER_SOCKET_BIND_ADDR;
use rs_matter::utils::select::Coalesce;
use rs_matter::{
    clusters, devices, root_endpoint, with, BasicCommData, Matter, MATTER_PORT,
};
use tokio::sync::mpsc;
use vrx_protocol::matter::Command;

use crate::layout::{Layout, AGGREGATOR, SCREEN};
use crate::link::{Fabric, Grant, Request, Shared};

/// Dimmable Plug-in Unit. Recalled from the Matter 1.4 Device Library
/// (plan 0015's re-verification duty): confirm the id and revision.
pub const DEV_TYPE_DIMMABLE_PLUG: DeviceType = DeviceType {
    dtype: 0x010B,
    drev: 4,
};

/// On/Off Plug-in Unit (same caveat).
pub const DEV_TYPE_ON_OFF_PLUG: DeviceType = DeviceType {
    dtype: 0x010A,
    drev: 3,
};

/// The On/Off cluster every endpoint here carries: On, Off and Toggle on
/// the OnOff attribute, no lighting feature.
const ON_OFF_CLUSTER: Cluster<'static> = on_off_decl::FULL_CLUSTER
    .with_revision(6)
    .with_features(0)
    .with_attrs(with!(required; on_off_decl::AttributeId::OnOff))
    .with_cmds(with!(
        on_off_decl::CommandId::Off
            | on_off_decl::CommandId::On
            | on_off_decl::CommandId::Toggle
    ));

/// Who this device is on a fabric: its basic information and its setup
/// code (a passcode and discriminator drawn once and kept).
pub struct Identity {
    pub info: &'static BasicInfoConfig<'static>,
    pub comm: BasicCommData,
}

/// Passcodes Matter forbids (Core 5.1.7.1).
const INVALID_PASSCODES: [u32; 12] = [
    0, 11111111, 22222222, 33333333, 44444444, 55555555, 66666666, 77777777, 88888888,
    99999999, 12345678, 87654321,
];

/// The setup code from `setup` in the state directory, drawn on first
/// start: "<passcode> <discriminator>".
fn setup_code(dir: &Path) -> std::io::Result<(u32, u16)> {
    let path = dir.join("setup");
    if let Ok(text) = std::fs::read_to_string(&path) {
        let mut w = text.split_whitespace();
        if let (Some(Ok(p)), Some(Ok(d))) =
            (w.next().map(str::parse), w.next().map(str::parse))
        {
            if !INVALID_PASSCODES.contains(&p) && p < 99_999_999 && d < 4096 {
                return Ok((p, d));
            }
        }
    }
    use rand::RngExt as _;
    let mut rng = rand::rng();
    let passcode = loop {
        let p = rng.random_range(1..99_999_999);
        if !INVALID_PASSCODES.contains(&p) {
            break p;
        }
    };
    let discriminator = rng.random_range(0..4096);
    std::fs::write(&path, format!("{passcode} {discriminator}\n"))?;
    Ok((passcode, discriminator))
}

/// The device's identity: its name (the hostname), its serial (the
/// machine id), and its setup code.
pub fn identity(dir: &Path) -> std::io::Result<Identity> {
    let (passcode, discriminator) = setup_code(dir)?;
    let machine = std::fs::read_to_string("/etc/machine-id").unwrap_or_default();
    let serial: &'static str = Box::leak(
        machine
            .trim()
            .chars()
            .take(16)
            .collect::<String>()
            .into_boxed_str(),
    );
    let host = std::fs::read_to_string("/etc/hostname").unwrap_or_default();
    let name: &'static str = Box::leak(
        match host.trim() {
            "" => "vrx".to_owned(),
            h => h.chars().take(32).collect(),
        }
        .into_boxed_str(),
    );
    let info = Box::leak(Box::new(BasicInfoConfig {
        vid: TEST_VID,
        pid: TEST_PID,
        hw_ver: 1,
        hw_ver_str: "1",
        sw_ver: 1,
        sw_ver_str: env!("CARGO_PKG_VERSION"),
        serial_no: if serial.is_empty() { "0" } else { serial },
        manufacturing_date: "20261014",
        product_name: "vrx",
        vendor_name: "vrx",
        device_name: name,
        ..BasicInfoConfig::new()
    }));
    let bytes = passcode.to_le_bytes();
    Ok(Identity {
        info,
        comm: BasicCommData {
            password: Spake2pVerifierPassword::new_from_ref(
                Spake2pVerifierPasswordRef::new(&bytes),
            ),
            discriminator,
        },
    })
}

/// The pairing payload: the QR code's text for the network alone, for the
/// network and Bluetooth where this build has the BLE transport (D5), and
/// the 11-digit manual code (which names no transport).
pub fn payload(id: &Identity) -> Result<((String, Option<String>), String), Error> {
    let qr = |caps: DiscoveryCapabilities| -> Result<String, Error> {
        let qr = QrPayload::new_from_basic_info(
            caps,
            CommFlowType::Standard,
            id.comm.clone(),
            id.info,
            no_optional_data as NoOptionalData,
        );
        let mut buf = [0u8; 256];
        Ok(qr.as_str(&mut buf)?.0.to_owned())
    };
    let ble = if crate::ble::BUILT {
        Some(qr(DiscoveryCapabilities::IP | DiscoveryCapabilities::BLE)?)
    } else {
        None
    };
    Ok((
        (qr(DiscoveryCapabilities::IP)?, ble),
        id.comm.compute_pairing_code().as_str().to_owned(),
    ))
}

/// Brightness position (0-100) and Level (1-254), both ways.
pub fn level_of(position: i32) -> u8 {
    let p = position.clamp(0, 100) as u32;
    u8::try_from(1 + (p * 253 + 50) / 100).unwrap_or(254)
}

pub fn position_of(level: u8) -> u8 {
    let l = u32::from(level.clamp(1, 254)) - 1;
    u8::try_from((l * 100 + 126) / 253).unwrap_or(100)
}

/// Endpoint 1's On/Off: the screen lit, as the compositor reports it.
struct ScreenOnOff {
    shared: Arc<Shared>,
    on: Cell<bool>,
}

impl OnOffHooks for ScreenOnOff {
    const CLUSTER: Cluster<'static> = ON_OFF_CLUSTER;

    fn on_off(&self) -> bool {
        self.on.get()
    }

    fn set_on_off(&self, on: bool) {
        // the state echoed back from a report is not a command
        if self.on.replace(on) == on {
            return;
        }
        let shared = self.shared.clone();
        tokio::spawn(async move {
            if !shared.command(Command::Screen { on }).await {
                tracing::warn!(on, "the screen command was not carried out");
            }
        });
    }

    fn start_up_on_off(&self) -> Nullable<on_off::StartUpOnOffEnum> {
        Nullable::none()
    }

    fn set_start_up_on_off(
        &self,
        _value: Nullable<on_off::StartUpOnOffEnum>,
    ) -> Result<(), Error> {
        Err(ErrorCode::InvalidAction.into())
    }

    async fn handle_off_with_effect(&self, _effect: on_off::EffectVariantEnum) {}

    async fn run<F: Fn(on_off::OutOfBandMessage)>(&self, notify: F) {
        let mut host = self.shared.host.subscribe();
        loop {
            let lit = host.borrow_and_update().as_ref().map(|h| h.screen_on);
            if let Some(lit) = lit {
                if lit != self.on.get() {
                    self.on.set(lit);
                    notify(on_off::OutOfBandMessage::Update);
                }
            }
            if host.changed().await.is_err() {
                core::future::pending::<()>().await;
            }
        }
    }
}

/// Endpoint 1's Level Control: the brightness position.
struct ScreenLevel {
    shared: Arc<Shared>,
    level: Cell<Option<u8>>,
}

impl LevelControlHooks for ScreenLevel {
    const MIN_LEVEL: u8 = 1;
    const MAX_LEVEL: u8 = 254;
    const FASTEST_RATE: u8 = 50;
    const CLUSTER: Cluster<'static> = LEVEL_FULL
        .with_features(level_control::Feature::ON_OFF.bits())
        .with_attrs(with!(
            required;
            LevelAttr::CurrentLevel
            | LevelAttr::MinLevel
            | LevelAttr::MaxLevel
            | LevelAttr::OnLevel
            | LevelAttr::Options
        ))
        .with_cmds(with!(
            LevelCmd::MoveToLevel
                | LevelCmd::Move
                | LevelCmd::Step
                | LevelCmd::Stop
                | LevelCmd::MoveToLevelWithOnOff
                | LevelCmd::MoveWithOnOff
                | LevelCmd::StepWithOnOff
                | LevelCmd::StopWithOnOff
        ));

    fn set_device_level(&self, level: u8) -> Result<Option<u8>, ()> {
        let host = self.shared.host.borrow().clone();
        let position = position_of(level);
        // a dark screen keeps the person's brightness (the On/Off
        // coupling moves the level to its minimum on Off); a report
        // echoed back is not a command
        let wanted = host.as_ref().is_some_and(|h| {
            h.screen_on && h.brightness >= 0 && h.brightness != i32::from(position)
        });
        if wanted {
            let shared = self.shared.clone();
            tokio::spawn(async move {
                if !shared.command(Command::Brightness { position }).await {
                    tracing::warn!(
                        position,
                        "the brightness command was not carried out"
                    );
                }
            });
        }
        Ok(Some(level))
    }

    fn current_level(&self) -> Option<u8> {
        self.level.get()
    }

    fn set_current_level(&self, level: Option<u8>) {
        self.level.set(level);
    }

    async fn run<F: Fn(level_control::OutOfBandMessage)>(&self, notify: F) {
        let mut host = self.shared.host.subscribe();
        loop {
            let position = host.borrow_and_update().as_ref().map(|h| h.brightness);
            if let Some(position) = position.filter(|p| *p >= 0) {
                let level = level_of(position);
                if self.level.get() != Some(level) {
                    self.level.set(Some(level));
                    notify(level_control::OutOfBandMessage::Update(level));
                }
            }
            if host.changed().await.is_err() {
                core::future::pending::<()>().await;
            }
        }
    }
}

/// Every bridged applet's On/Off: a command is the applet's own intent
/// (vrxhost tells it, G043), the attribute the last command it took.
struct BridgedOnOff {
    dataver: Dataver,
    shared: Arc<Shared>,
    layout: RefCell<Layout>,
    dir: PathBuf,
}

impl BridgedOnOff {
    fn state(&self, endpoint: u16) -> Result<(String, bool), Error> {
        self.layout
            .borrow()
            .bridged_by_endpoint(endpoint)
            .map(|b| (b.applet.clone(), b.on))
            .ok_or_else(|| ErrorCode::EndpointNotFound.into())
    }

    async fn set(&self, ctx: impl InvokeContext, on: Option<bool>) -> Result<(), Error> {
        let endpoint = ctx.cmd().endpoint_id;
        let (applet, now) = self.state(endpoint)?;
        let on = on.unwrap_or(!now);
        if !self
            .shared
            .command(Command::OnOff {
                applet: applet.clone(),
                on,
            })
            .await
        {
            return Err(ErrorCode::Failure.into());
        }
        let mut layout = self.layout.borrow_mut();
        if let Some(b) = layout.bridged.iter_mut().find(|b| b.id == endpoint) {
            b.on = on;
        }
        if let Err(err) = layout.save(&self.dir) {
            tracing::warn!(%applet, error = %err, "the On/Off state was not kept");
        }
        drop(layout);
        ctx.notify_own_attr_changed(on_off_decl::AttributeId::OnOff as _);
        Ok(())
    }
}

impl on_off_decl::ClusterAsyncHandler for BridgedOnOff {
    const CLUSTER: Cluster<'static> = ON_OFF_CLUSTER;

    fn dataver(&self) -> u32 {
        self.dataver.get()
    }

    fn dataver_changed(&self) {
        self.dataver.changed();
    }

    async fn on_off(&self, ctx: impl ReadContext) -> Result<bool, Error> {
        Ok(self.state(ctx.attr().endpoint_id)?.1)
    }

    async fn handle_off(&self, ctx: impl InvokeContext) -> Result<(), Error> {
        self.set(ctx, Some(false)).await
    }

    async fn handle_on(&self, ctx: impl InvokeContext) -> Result<(), Error> {
        self.set(ctx, Some(true)).await
    }

    async fn handle_toggle(&self, ctx: impl InvokeContext) -> Result<(), Error> {
        self.set(ctx, None).await
    }

    async fn handle_off_with_effect(
        &self,
        _ctx: impl InvokeContext,
        _request: on_off_decl::OffWithEffectRequest<'_>,
    ) -> Result<(), Error> {
        Err(ErrorCode::CommandNotFound.into())
    }

    async fn handle_on_with_recall_global_scene(
        &self,
        _ctx: impl InvokeContext,
    ) -> Result<(), Error> {
        Err(ErrorCode::CommandNotFound.into())
    }

    async fn handle_on_with_timed_off(
        &self,
        _ctx: impl InvokeContext,
        _request: on_off_decl::OnWithTimedOffRequest<'_>,
    ) -> Result<(), Error> {
        Err(ErrorCode::CommandNotFound.into())
    }
}

/// Every bridged node's Bridged Device Basic Information: reachable, its
/// applet's name as the label and its id as the unique id.
struct BridgedInfo {
    dataver: Dataver,
    layout: Layout,
}

impl BridgedInfo {
    fn bridged(&self, endpoint: u16) -> Result<&crate::layout::Bridged, Error> {
        self.layout
            .bridged_by_endpoint(endpoint)
            .ok_or_else(|| ErrorCode::EndpointNotFound.into())
    }
}

impl bridged_info::ClusterHandler for BridgedInfo {
    const CLUSTER: Cluster<'static> = bridged_info::FULL_CLUSTER
        .with_features(0)
        .with_attrs(with!(required; bridged_info::AttributeId::NodeLabel))
        .with_cmds(with!());

    fn dataver(&self) -> u32 {
        self.dataver.get()
    }

    fn dataver_changed(&self) {
        self.dataver.changed();
    }

    fn reachable(&self, _ctx: impl ReadContext) -> Result<bool, Error> {
        Ok(true)
    }

    fn node_label<P: TLVBuilderParent>(
        &self,
        ctx: impl ReadContext,
        builder: Utf8StrBuilder<P>,
    ) -> Result<P, Error> {
        builder.set(&self.bridged(ctx.attr().endpoint_id)?.name)
    }

    fn unique_id<P: TLVBuilderParent>(
        &self,
        ctx: impl ReadContext,
        builder: Utf8StrBuilder<P>,
    ) -> Result<P, Error> {
        builder.set(&self.bridged(ctx.attr().endpoint_id)?.applet)
    }

    fn handle_keep_active(
        &self,
        _ctx: impl InvokeContext,
        _request: KeepActiveRequest<'_>,
    ) -> Result<(), Error> {
        Err(ErrorCode::CommandNotFound.into())
    }
}

const SCREEN_CLUSTERS: &[Cluster<'static>] = clusters!(
    desc::DescHandler::CLUSTER,
    ON_OFF_CLUSTER,
    ScreenLevel::CLUSTER,
);
const AGGREGATOR_CLUSTERS: &[Cluster<'static>] = clusters!(desc::DescHandler::CLUSTER);
const BRIDGED_CLUSTERS: &[Cluster<'static>] = clusters!(
    desc::DescHandler::CLUSTER,
    BridgedInfo::CLUSTER,
    ON_OFF_CLUSTER,
);

/// The node for a layout: built once at start, leaked for the process's
/// life (a new layout is a restart).
const ROOT: Endpoint<'static> = root_endpoint!(eth);

pub fn node(layout: &Layout) -> Node<'static> {
    let mut endpoints = vec![ROOT];
    if layout.screen {
        endpoints.push(Endpoint::new(
            SCREEN,
            devices!(DEV_TYPE_DIMMABLE_PLUG),
            SCREEN_CLUSTERS,
        ));
    }
    if !layout.bridged.is_empty() {
        endpoints.push(Endpoint::new(
            AGGREGATOR,
            devices!(DEV_TYPE_AGGREGATOR),
            AGGREGATOR_CLUSTERS,
        ));
        for b in &layout.bridged {
            endpoints.push(Endpoint::new(
                b.id,
                devices!(DEV_TYPE_ON_OFF_PLUG, DEV_TYPE_BRIDGED_NODE),
                BRIDGED_CLUSTERS,
            ));
        }
    }
    Node {
        endpoints: endpoints.leak(),
    }
}

/// Why the stack stopped: the process exits and systemd starts it again.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Exit {
    /// vrxhost's exposed set differs from the layout: rebuilt on restart.
    Relayout,
    /// Every fabric was left.
    Forgotten,
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs())
}

/// Run the stack until a restart is due.
pub async fn run(
    id: &Identity,
    layout: Layout,
    dir: &Path,
    shared: Arc<Shared>,
    mut requests: mpsc::UnboundedReceiver<Request>,
) -> Result<Exit, Error> {
    let (attestation, dac_key) =
        crate::attestation::credentials().ok_or(ErrorCode::Invalid)?;
    let matter = Matter::new(id.info, id.comm.clone(), attestation, MATTER_PORT);
    let store = DirKvBlobStore::new(dir.join("kvs"));
    let buffers: MatterBuffers = MatterBuffers::new();
    let state: EthInteractionModelState =
        EthInteractionModelState::new(EthNetwork::new_default());
    let kv = matter.kv(store);
    matter.startup(&kv)?;
    let crypto = default_crypto(rand::rng(), dac_key);
    let mut rand = crypto.rand()?;

    let lit = shared.host.borrow().as_ref().is_some_and(|h| h.screen_on);
    let screen_on_off = on_off::OnOffHandler::new(
        Dataver::new_rand(&mut rand),
        SCREEN,
        ScreenOnOff {
            shared: shared.clone(),
            on: Cell::new(lit),
        },
    );
    let screen_level = level_control::LevelControlHandler::new(
        Dataver::new_rand(&mut rand),
        SCREEN,
        ScreenLevel {
            shared: shared.clone(),
            level: Cell::new(None),
        },
        level_control::AttributeDefaults {
            options: OptionsBitmap::EXECUTE_IF_OFF,
            ..Default::default()
        },
    );
    screen_on_off.init(Some(&screen_level));
    screen_level.init(Some(&screen_on_off));
    let bridged = BridgedOnOff {
        dataver: Dataver::new_rand(&mut rand),
        shared: shared.clone(),
        layout: RefCell::new(layout.clone()),
        dir: dir.to_owned(),
    };
    let info = BridgedInfo {
        dataver: Dataver::new_rand(&mut rand),
        layout: layout.clone(),
    };

    let im = InteractionModel::new(
        &matter,
        &crypto,
        &buffers,
        data_model(
            node(&layout),
            rand,
            &screen_on_off,
            &screen_level,
            &bridged,
            &info,
        ),
        &kv,
        &state,
    );
    im.startup().await?;
    let responder = DefaultResponder::new(&im);
    let mut respond = pin!(responder.run::<4, 4>());
    let mut im_job = pin!(im.run());
    let socket = async_io::Async::<UdpSocket>::bind(MATTER_SOCKET_BIND_ADDR)?;
    let bus = rs_matter::utils::zbus::Connection::system()
        .await
        .map_err(|_| ErrorCode::StdIoError)?;
    let mut avahi = rs_matter::transport::network::mdns::avahi::AvahiMdns::new(bus);
    let mut mdns = pin!(avahi.run(&matter));
    // BTP beside UDP: a message to a Bluetooth peer goes out over BTP, one
    // from either is taken; with no BLE session BTP is silent (D4)
    let btp = Btp::new();
    let net = || ChainedNetwork::new(Address::is_btp, &btp, &socket);
    let mut transport = pin!(matter.run(&crypto, net(), net(), &socket));
    tracing::info!(
        endpoints = node(&layout).endpoints.len(),
        commissioned = matter.has_fabrics(),
        "Matter node up"
    );

    // BLE commissioning (D4): wanted while a window the arbiter granted is
    // open; the grant waits in `granted` for the transport to take
    let (want_ble, mut wanted) = tokio::sync::watch::channel(false);
    let granted: RefCell<Option<Grant>> = RefCell::new(None);
    let ble_on = Cell::new(false);
    let mut ble = pin!(async {
        loop {
            if wanted.wait_for(|w| *w).await.is_err() {
                return Ok::<(), Error>(());
            }
            let grant = granted.borrow_mut().take();
            if let Some(grant) = grant {
                let serve =
                    crate::ble::advertise(&grant, id.info, id.comm.discriminator, &btp);
                let closed = wanted.wait_for(|w| !*w);
                if let Either::First(Err(err)) = select(serve, closed).await {
                    tracing::warn!(error = %err, "BLE commissioning stopped; the window stays open on the network");
                }
                btp.reset();
                ble_on.set(false);
                shared.status.send_modify(|st| st.ble = false);
                // the adapter goes back to the arbiter (Device Link's window)
                if !shared.command(Command::AdvertiseEnd).await {
                    tracing::warn!("the arbiter did not hear BLE commissioning end");
                }
            }
            // a failure keeps BLE off until this window closes
            if wanted.wait_for(|w| !*w).await.is_err() {
                return Ok(());
            }
        }
    });

    let exit = Cell::new(None);
    let mut control = pin!(async {
        let mut host = shared.host.subscribe();
        let mut tick = tokio::time::interval(Duration::from_secs(1));
        let mut until = 0u64;
        loop {
            tokio::select! {
                request = requests.recv() => match request {
                    Some(Request::Open { secs, reply }) => {
                        let done = im.open_basic_comm_window(secs).map_err(|e| e.to_string());
                        if done.is_ok() {
                            until = now() + u64::from(secs);
                            // over Bluetooth too where it is built, BlueZ has an
                            // adapter and the arbiter agrees (D4, D5); asked
                            // before the reply so the QR code is right at once
                            if crate::ble::BUILT && crate::ble::present().await {
                                if let Some(grant) = shared.advertise(secs).await {
                                    *granted.borrow_mut() = Some(grant);
                                    ble_on.set(true);
                                    want_ble.send_replace(true);
                                }
                            }
                            tracing::info!(secs, ble = ble_on.get(), "commissioning window open");
                            // said at once: Payload answers only while it is
                            shared.status.send_modify(|st| {
                                st.window = true;
                                st.window_until = until;
                                st.ble = ble_on.get();
                            });
                        }
                        let _ = reply.send(done);
                    }
                    Some(Request::Close { reply }) => {
                        let done = im.close_comm_window().map(|_| ()).map_err(|e| e.to_string());
                        want_ble.send_replace(false);
                        let _ = reply.send(done);
                    }
                    Some(Request::Forget { reply }) => {
                        let done = matter
                            .factory_reset(&kv)
                            .map_err(|e| e.to_string());
                        let done = match done {
                            Ok(()) => im.factory_reset().await.map_err(|e| e.to_string()),
                            err => err,
                        };
                        let ok = done.is_ok();
                        let _ = reply.send(done);
                        if ok {
                            tracing::info!("every fabric left; restarting");
                            exit.set(Some(Exit::Forgotten));
                            return Ok::<(), Error>(());
                        }
                    }
                    None => return Ok(()),
                },
                changed = host.changed() => {
                    if changed.is_err() {
                        return Ok(());
                    }
                    let want = host.borrow_and_update().as_ref().map(|h| layout.follow(h));
                    if let Some(want) = want.filter(|w| w.differs(&layout)) {
                        // a controller re-reads the node once the version moves
                        if let Err(err) = im.bump_configuration_version() {
                            tracing::warn!(error = %err, "ConfigurationVersion not bumped");
                        }
                        let mut keep = want;
                        for b in &mut keep.bridged {
                            b.on = bridged.layout.borrow().bridged.iter().any(|o| o.id == b.id && o.on);
                        }
                        if let Err(err) = keep.save(dir) {
                            tracing::error!(error = %err, "the new layout was not saved");
                        }
                        tracing::info!(applets = keep.bridged.len(), screen = keep.screen, "endpoints changed; restarting");
                        exit.set(Some(Exit::Relayout));
                        return Ok(());
                    }
                }
                _ = tick.tick() => {
                    let window = matches!(matter.comm_window_state(), CommWindowState::Open { .. });
                    // closed: timed out, or a home app finished pairing
                    if !window {
                        want_ble.send_replace(false);
                    }
                    let fabrics: Vec<Fabric> = matter.with_state(|s| {
                        s.fabrics
                            .iter()
                            .map(|f| Fabric {
                                index: f.fab_idx().get(),
                                vendor_id: f.vendor_id(),
                                fabric_id: f.fabric_id(),
                                label: f.label().to_owned(),
                            })
                            .collect()
                    });
                    shared.status.send_if_modified(|st| {
                        let next = crate::link::Status {
                            commissioned: !fabrics.is_empty(),
                            fabrics: fabrics.clone(),
                            window,
                            window_until: if window { until } else { 0 },
                            ble: window && ble_on.get(),
                            attestation: crate::attestation::KIND,
                        };
                        let changed = *st != next;
                        *st = next;
                        changed
                    });
                }
            }
        }
    });

    select4(
        &mut transport,
        &mut mdns,
        select(&mut respond, &mut im_job).coalesce(),
        select(&mut control, &mut ble).coalesce(),
    )
    .coalesce()
    .await?;
    exit.get().ok_or_else(|| ErrorCode::Invalid.into())
}

fn data_model<'a>(
    node: Node<'static>,
    mut rand: impl Rng + Copy,
    on_off: &'a on_off::OnOffHandler<'a, ScreenOnOff, ScreenLevel>,
    level: &'a level_control::LevelControlHandler<'a, ScreenLevel, ScreenOnOff>,
    bridged: &'a BridgedOnOff,
    info: &'a BridgedInfo,
) -> impl DataModel + 'a {
    (
        node,
        endpoints::EthSysHandlerBuilder::new()
            .netif_diag(&SysNetifs)
            .build(rand)
            .chain(
                |e, c| e == SCREEN && c == desc::DescHandler::CLUSTER.id,
                Async(desc::DescHandler::new(Dataver::new_rand(&mut rand)).adapt()),
            )
            .chain(
                |e, c| e == SCREEN && c == ON_OFF_CLUSTER.id,
                on_off::HandlerAsyncAdaptor(on_off),
            )
            .chain(
                |e, c| e == SCREEN && c == ScreenLevel::CLUSTER.id,
                level_control::HandlerAsyncAdaptor(level),
            )
            .chain(
                |e, c| e == AGGREGATOR && c == desc::DescHandler::CLUSTER.id,
                Async(
                    desc::DescHandler::new_aggregator(Dataver::new_rand(&mut rand))
                        .adapt(),
                ),
            )
            .chain(
                |e, c| e > AGGREGATOR && c == desc::DescHandler::CLUSTER.id,
                Async(desc::DescHandler::new(Dataver::new_rand(&mut rand)).adapt()),
            )
            .chain(
                |e, c| e > AGGREGATOR && c == BridgedInfo::CLUSTER.id,
                Async(bridged_info::HandlerAdaptor(info)),
            )
            .chain(
                |e, c| e > AGGREGATOR && c == ON_OFF_CLUSTER.id,
                on_off_decl::HandlerAsyncAdaptor(bridged),
            ),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    /// rs-matter validates a cluster's shape when its handlers are wired
    /// and panics on a wrong one: the screen's pair passes.
    #[test]
    fn the_screen_clusters_pass_rs_matter_validation() {
        let (tx, _rx) = tokio::sync::mpsc::unbounded_channel();
        let shared = Shared::new(
            tx,
            (String::new(), None),
            String::new(),
            serde_json::json!({}),
        );
        let on_off = on_off::OnOffHandler::new(
            Dataver::new(0),
            SCREEN,
            ScreenOnOff {
                shared: shared.clone(),
                on: Cell::new(true),
            },
        );
        let level = level_control::LevelControlHandler::new(
            Dataver::new(0),
            SCREEN,
            ScreenLevel {
                shared,
                level: Cell::new(None),
            },
            level_control::AttributeDefaults {
                options: OptionsBitmap::EXECUTE_IF_OFF,
                ..Default::default()
            },
        );
        on_off.init(Some(&level));
        level.init(Some(&on_off));
    }

    #[test]
    fn brightness_and_level_round_trip() {
        assert_eq!(level_of(0), 1);
        assert_eq!(level_of(100), 254);
        assert_eq!(position_of(1), 0);
        assert_eq!(position_of(254), 100);
        for p in 0..=100 {
            assert_eq!(i32::from(position_of(level_of(p))), p, "{p}");
        }
    }

    #[test]
    fn the_setup_code_is_drawn_once_and_valid() {
        let dir = tempfile::tempdir().unwrap();
        let (p, d) = setup_code(dir.path()).unwrap();
        assert!(!INVALID_PASSCODES.contains(&p) && p < 99_999_999);
        assert!(d < 4096);
        assert_eq!(setup_code(dir.path()).unwrap(), (p, d), "kept");
        std::fs::write(dir.path().join("setup"), "12345678 10\n").unwrap();
        assert_ne!(
            setup_code(dir.path()).unwrap().0,
            12345678,
            "a forbidden code is drawn again"
        );
    }

    #[test]
    fn the_node_follows_the_layout_d1() {
        let empty = Layout {
            screen: false,
            ..Layout::default()
        };
        assert_eq!(node(&empty).endpoints.len(), 1, "the root alone");
        let mut l = Layout::default();
        assert_eq!(node(&l).endpoints.len(), 2, "root and screen");
        l.bridged.push(crate::layout::Bridged {
            id: 3,
            applet: "clock".into(),
            name: "Clock".into(),
            device_type: vrx_protocol::manifest::MatterDeviceType::OnOffPlug,
            on: false,
        });
        let ids: Vec<u16> = node(&l).endpoints.iter().map(|e| e.id).collect();
        assert_eq!(ids, [0, 1, 2, 3]);
    }

    #[test]
    fn the_payload_is_a_matter_qr_and_an_11_digit_code() {
        let dir = tempfile::tempdir().unwrap();
        let id = identity(dir.path()).unwrap();
        let ((qr, qr_ble), manual) = payload(&id).unwrap();
        assert!(qr.starts_with("MT:"), "{qr}");
        assert_eq!(manual.len(), 11);
        assert!(manual.chars().all(|c| c.is_ascii_digit()));
        // D5: the Bluetooth bit only from a build with the BLE transport
        let caps = |qr: &str| {
            let mut buf = [0u8; 256];
            let parsed = rs_matter::pairing::qr::QrPayload::parse(qr, &mut buf).unwrap();
            parsed.discovery_capabilities()
        };
        assert_eq!(caps(&qr), DiscoveryCapabilities::IP);
        assert_eq!(qr_ble.is_some(), crate::ble::BUILT);
        if let Some(qr) = qr_ble {
            assert_eq!(
                caps(&qr),
                DiscoveryCapabilities::IP | DiscoveryCapabilities::BLE
            );
        }
    }
}
