// vrxinit: PID 1. Mount the basics, hand the system to systemd (which
// starts the hardware services and vrxhost per the shipped unit), and
// only ever keep a console when the kernel cmdline asks for one
// (vrx.debug) — no getty, no display-manager, ever.
//
// The decisions live in plan.rs (pure, host-tested); this file is the
// side-effecting half and runs only on the target.

mod plan;

use std::process::ExitCode;

fn main() -> ExitCode {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    let cmdline = std::fs::read_to_string("/proc/cmdline").unwrap_or_default();
    let boot = plan::plan(&cmdline);
    tracing::info!(?boot.steps, debug = boot.debug, "vrxinit boot plan");

    for step in &boot.steps {
        if let Err(err) = run_step(step) {
            // A failed mount is fatal (the system cannot come up
            // half-mounted); a failed debug console is not.
            match step {
                plan::Step::DebugConsole => {
                    tracing::warn!(error = %err, ?step, "step failed (non-fatal)");
                }
                _ => {
                    tracing::error!(error = %err, ?step, "fatal boot step failed");
                    return ExitCode::FAILURE;
                }
            }
        }
    }

    if boot.debug {
        // inherited by every service: the units can shape their output
        std::env::set_var("VRX_DEBUG", "1");
    }

    // systemd becomes PID 1: it starts the hardware services and, per
    // the vrxhost.service unit, the applet OS daemon.
    tracing::info!("exec systemd as PID 1");
    let err = exec_systemd();
    tracing::error!(error = %err, "exec systemd failed — dropping to a shell");
    ExitCode::FAILURE
}

fn run_step(step: &plan::Step) -> Result<(), String> {
    use plan::Step;
    match step {
        Step::MountProc => mount("proc", "/proc", "proc"),
        Step::MountSys => mount("sysfs", "/sys", "sysfs"),
        Step::MountDev => mount("devtmpfs", "/dev", "devtmpfs"),
        Step::RuntimeDir => {
            std::fs::create_dir_all("/tmp/vrx").map_err(|e| format!("/tmp/vrx: {e}"))?;
            Ok(())
        }
        Step::DebugConsole => std::process::Command::new("/bin/sh")
            .arg("-c")
            .arg("exec /bin/sh </dev/console >/dev/console 2>&1")
            .spawn()
            .map(|_| ())
            .map_err(|e| format!("debug console: {e}")),
    }
}

#[cfg(target_os = "linux")]
fn mount(source: &str, target: &str, fstype: &str) -> Result<(), String> {
    // SAFETY: mount(2) with plain NUL-terminated string arguments; no
    // pointer into Rust-managed memory outlives the call. The libc
    // binding carries the per-arch syscall number — never hand-roll it
    // (it is not portable, and a wrong number muxes another syscall).
    let c_source = std::ffi::CString::new(source).map_err(|e| e.to_string())?;
    let c_target = std::ffi::CString::new(target).map_err(|e| e.to_string())?;
    let c_fstype = std::ffi::CString::new(fstype).map_err(|e| e.to_string())?;
    let rc = unsafe {
        libc::mount(
            c_source.as_ptr(),
            c_target.as_ptr(),
            c_fstype.as_ptr(),
            0,
            std::ptr::null(),
        )
    };
    if rc != 0 {
        return Err(format!(
            "mount {source} at {target}: {}",
            std::io::Error::last_os_error()
        ));
    }
    Ok(())
}

#[cfg(not(target_os = "linux"))]
fn mount(_source: &str, _target: &str, _fstype: &str) -> Result<(), String> {
    Err("vrxinit only mounts on Linux (this build is for another host)".to_owned())
}

#[cfg(target_os = "linux")]
fn exec_systemd() -> std::io::Error {
    use std::os::unix::process::CommandExt;
    let error = std::process::Command::new("/lib/systemd/systemd")
        .arg("--system")
        .exec();
    error
}

#[cfg(not(target_os = "linux"))]
fn exec_systemd() -> std::io::Error {
    std::io::Error::other("vrxinit only execs systemd on Linux")
}
