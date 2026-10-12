// The vrxhost binary: scan the registry, supervise the boot plan's
// applets, serve the intent socket until the system goes down.

use std::process::ExitCode;
use std::sync::Arc;

use vrx_host::registry;
use vrx_host::supervisor::Supervisor;
use vrx_host::{intent, paths};

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
        Ok(registry) => registry,
        Err(err) => {
            tracing::error!(error = %err, "registry scan failed");
            return ExitCode::FAILURE;
        }
    };
    let builtins = registry.iter().filter(|e| e.builtin).count();
    let installed = registry.len() - builtins;
    tracing::info!(builtins, installed, "registry ready");

    // The boot plan's process half: the home applet and every resident
    // applet run from boot to power-off; everything else starts on
    // first use (an opened intent or a launcher tap).
    let mut supervisor = Supervisor::new();
    for entry in registry.iter() {
        let roles = &entry.manifest.applet.roles;
        let boots_at_start = roles.home || roles.resident;
        if !boots_at_start {
            continue;
        }
        let binary = entry.path.join("app");
        tracing::info!(applet = %entry.manifest.applet.id, binary = %binary.display(), "boot-plan applet");
        supervisor.supervise(&entry.manifest.applet.id, binary, Vec::new());
    }

    // The supervisor's events (crashes, restarts, disables) surface on
    // one channel; log them as they arrive.
    tokio::spawn(async move {
        while let Some(event) = supervisor.next_event().await {
            tracing::info!(?event, "supervision");
        }
    });

    let socket = paths.intent_socket();
    if let Err(err) = intent::serve(&socket, Arc::new(registry)).await {
        tracing::error!(socket = %socket.display(), error = %err, "intent router stopped");
        return ExitCode::FAILURE;
    }
    ExitCode::SUCCESS
}
