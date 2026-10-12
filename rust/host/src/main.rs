// vrxhost: the applet OS daemon.
//
// Plan 0007 part C. Owns the registry (scans /apps and
// /system/defaults), the supervisor (spawn/monitor/restart), the
// intent router (the Unix socket /tmp/vrx/vrx.sock) and the back
// trail. This skeleton stands up the process; the parts land in
// execution order with integration tests.

use std::process::ExitCode;

fn main() -> ExitCode {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();
    tracing::info!("vrxhost starting (part C: registry, supervisor, intents, trail)");
    ExitCode::SUCCESS
}
