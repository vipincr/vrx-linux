// vrx-matter (plan 0015): the device on a Matter fabric. A home app
// (Apple Home, Google Home, chip-tool) pairs it over the IP network and
// sees the screen (endpoint 1) and the applets a person exposed (bridged
// nodes); every command it gives is carried out by vrxhost, which holds
// the rules (G043). Its own interface is io.vrx.Matter (link.rs). Where
// the board has Bluetooth, a window is offered over BLE too (ble.rs),
// with vrxhost's arbiter's leave (D4, G044).
//
// Two threads: the Varlink side on a tokio runtime, and the Matter stack
// on a current-thread runtime of its own (rs-matter's state is not Send).
// The stack stops when its endpoints change or its fabrics are left; the
// process then exits and systemd (Restart=always) starts it again.

#![cfg_attr(test, allow(clippy::unwrap_used, clippy::expect_used, clippy::panic))]

mod attestation;
mod ble;
mod layout;
mod link;
mod node;

use std::path::PathBuf;
use std::process::ExitCode;

use serde_json::json;
use tokio::sync::mpsc;

fn main() -> ExitCode {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();
    // the unit's StateDirectory (D10)
    let dir = PathBuf::from(
        std::env::var("STATE_DIRECTORY").unwrap_or_else(|_| "/var/lib/vrx-matter".into()),
    );
    if attestation::credentials().is_none() {
        tracing::error!(
            "no attestation in this build (a release image needs factory data; plan 0015 D11)"
        );
        return ExitCode::FAILURE;
    }
    let id = match node::identity(&dir) {
        Ok(id) => id,
        Err(err) => {
            tracing::error!(dir = %dir.display(), error = %err, "no setup code");
            return ExitCode::FAILURE;
        }
    };
    let (qr, manual) = match node::payload(&id) {
        Ok(p) => p,
        Err(err) => {
            tracing::error!(error = %err, "no pairing payload");
            return ExitCode::FAILURE;
        }
    };
    // CON-10 (review 2026-10-17): a layout that exists but will not
    // parse stops the start with a named error — loading it as empty
    // re-used every id the file held. The unit's start limit then stops
    // the loop instead of restarting into the same refusal.
    let layout = match layout::Layout::load(&dir) {
        Ok(l) => l,
        Err(err) => {
            tracing::error!(error = %err, "layout: refusing to start");
            return ExitCode::FAILURE;
        }
    };
    let endpoints = json!({
        "screen": layout.screen,
        "applets": layout
            .bridged
            .iter()
            .map(|b| json!({ "endpoint": b.id, "applet": b.applet, "name": b.name }))
            .collect::<Vec<_>>(),
    });
    let (requests_tx, requests) = mpsc::unbounded_channel();
    let shared = link::Shared::new(requests_tx, qr, manual, endpoints);

    let stack = {
        let shared = shared.clone();
        std::thread::spawn(move || {
            let runtime = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build();
            match runtime {
                Ok(rt) => rt
                    .block_on(node::run(&id, layout, &dir, shared, requests))
                    .map_err(|e| e.to_string()),
                Err(err) => Err(err.to_string()),
            }
        })
    };
    let runtime = match tokio::runtime::Builder::new_multi_thread()
        .worker_threads(1)
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(err) => {
            tracing::error!(error = %err, "no runtime");
            return ExitCode::FAILURE;
        }
    };
    let socket = PathBuf::from(vrx_protocol::matter::SOCKET);
    runtime.spawn(async move {
        if let Err(err) = link::serve(&socket, shared).await {
            tracing::error!(socket = %socket.display(), error = %err, "io.vrx.Matter stopped");
            std::process::exit(1);
        }
    });
    match stack.join() {
        Ok(Ok(exit)) => {
            tracing::info!(?exit, "restarting");
            ExitCode::SUCCESS
        }
        Ok(Err(err)) => {
            tracing::error!(error = %err, "the Matter stack stopped");
            ExitCode::FAILURE
        }
        Err(_) => ExitCode::FAILURE,
    }
}
