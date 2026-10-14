// BLE commissioning (plan 0015 D4, D5, G044): rs-matter's BTP over
// BlueZ's GATT, through BlueZ's D-Bus API (the `zbus` feature's
// `run_peripheral`: the Matter service with its C1 and C2
// characteristics, and the LE advertisement carrying the discriminator).
// Built only where the board has Bluetooth (the `ble` feature, from the
// machine's MACHINE_FEATURES), run only inside a commissioning window,
// and started only with vrxhost's arbiter's Grant: this file is the one
// home of `run_peripheral` (the scan's G044), and its one entry point
// takes a Grant, which only the arbiter's yes makes (link.rs).
//
// Each window has its own bus connection. When the window closes the
// future is dropped: rs-matter unregisters the advertisement and the
// GATT application, and the connection goes with them.

use rs_matter::dm::clusters::basic_info::BasicInfoConfig;
use rs_matter::error::Error;
use rs_matter::transport::network::btp::Btp;

use crate::link::Grant;

/// This build carries the BLE transport (D5): the QR code may say so.
pub const BUILT: bool = cfg!(all(feature = "ble", target_os = "linux"));

/// What the advertisement calls the device (the scan response has room
/// for little; home apps find a device by the Matter service data).
#[cfg(all(feature = "ble", target_os = "linux"))]
const NAME: &str = "vrx";

/// BlueZ lists an adapter: worth asking the arbiter for. Whether its
/// radio is on is the arbiter's question.
#[cfg(all(feature = "ble", target_os = "linux"))]
pub async fn present() -> bool {
    use rs_matter::utils::zbus::{fdo::ObjectManagerProxy, Connection};
    let listed = async {
        let conn = Connection::system().await?;
        let manager = ObjectManagerProxy::builder(&conn)
            .destination("org.bluez")?
            .path("/")?
            .build()
            .await?;
        let objects = manager.get_managed_objects().await?;
        Ok::<bool, rs_matter::utils::zbus::Error>(
            objects
                .values()
                .any(|ifaces| ifaces.keys().any(|i| i.as_str() == "org.bluez.Adapter1")),
        )
    };
    match listed.await {
        Ok(found) => found,
        Err(err) => {
            tracing::info!(error = %err, "no Bluetooth adapter: this window is on the network only");
            false
        }
    }
}

#[cfg(not(all(feature = "ble", target_os = "linux")))]
pub async fn present() -> bool {
    false
}

/// Serve Matter's BLE commissioning until the future is dropped (the
/// window closed) or BlueZ fails.
#[cfg(all(feature = "ble", target_os = "linux"))]
pub async fn advertise(
    _grant: &Grant,
    info: &BasicInfoConfig<'_>,
    discriminator: u16,
    btp: &Btp,
) -> Result<(), Error> {
    use rs_matter::transport::network::btp::{bluez, AdvData};
    use rs_matter::utils::zbus::Connection;
    let conn = Connection::system().await?;
    let adv = AdvData::new(info, discriminator);
    tracing::info!("advertising Matter over Bluetooth");
    bluez::run_peripheral(&conn, None, NAME, &adv, btp).await
}

#[cfg(not(all(feature = "ble", target_os = "linux")))]
pub async fn advertise(
    _grant: &Grant,
    _info: &BasicInfoConfig<'_>,
    _discriminator: u16,
    _btp: &Btp,
) -> Result<(), Error> {
    core::future::pending().await
}
