// The supervisor: vrxhost's half of applet lifecycle. Spawns applet
// processes (through launch.rs, so every one runs sandboxed), watches
// them, restarts on crash: at most MAX_RESTARTS times, then the applet
// is disabled and a human is told. A clean exit is an applet finishing
// (app.finished), not a crash.

use std::process::Stdio;

use tokio::sync::mpsc;

use crate::launch::{self, Launch};

/// Restarts allowed after a crash before the applet is disabled.
pub const MAX_RESTARTS: u32 = 3;

/// What the supervisor tells vrxhost about a supervised applet.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    /// The applet process started (spawn or restart) with this pid: the
    /// pid the compositor sees on its socket, so focus is named by it.
    Started { applet: String, pid: u32 },
    /// The applet exited cleanly (it finished; not restarted).
    Finished { applet: String },
    /// The applet crashed and is being restarted.
    Restarting { applet: String, attempt: u32 },
    /// The applet crashed too many times, or could not be spawned at
    /// all; it is now disabled.
    Disabled { applet: String, crashes: u32 },
}

impl Event {
    pub fn applet(&self) -> &str {
        match self {
            Event::Started { applet, .. }
            | Event::Finished { applet }
            | Event::Restarting { applet, .. }
            | Event::Disabled { applet, .. } => applet,
        }
    }
}

/// The supervisor. Owns one monitoring task per supervised applet; all
/// events surface on one channel, which is the source of truth for
/// applet state. The launch is rebuilt into a fresh command per spawn
/// (tokio Commands cannot be cloned).
#[derive(Debug, Clone)]
pub struct Supervisor {
    events_tx: mpsc::UnboundedSender<Event>,
}

impl Supervisor {
    /// A supervisor and the receiving end of its event channel.
    pub fn new() -> (Self, mpsc::UnboundedReceiver<Event>) {
        let (events_tx, events_rx) = mpsc::unbounded_channel();
        (Self { events_tx }, events_rx)
    }

    /// Spawn and supervise an applet: `applet` is its id, `launch` how
    /// it starts, re-applied verbatim on restart.
    pub fn supervise(&self, applet: &str, launch: Launch) {
        let applet = applet.to_owned();
        let events = self.events_tx.clone();

        tokio::spawn(async move {
            let mut restarts = 0u32;
            loop {
                let spawned = launch::prepare_home(&launch).and_then(|()| {
                    let mut command = launch::command(&launch);
                    command.stdin(Stdio::null());
                    // the applet's output goes where vrxhost's goes: the
                    // journal, under vrxhost's unit
                    command.stdout(Stdio::inherit());
                    command.stderr(Stdio::inherit());
                    command.kill_on_drop(true);
                    command.spawn()
                });
                let mut child = match spawned {
                    Ok(child) => child,
                    Err(err) => {
                        // could not spawn at all: a configuration
                        // failure, not a crash loop; do not spin
                        tracing::warn!(applet = %applet, error = %err, "spawn failed");
                        let _ = events.send(Event::Disabled {
                            applet: applet.clone(),
                            crashes: 0,
                        });
                        return;
                    }
                };
                let _ = events.send(Event::Started {
                    applet: applet.clone(),
                    pid: child.id().unwrap_or(0),
                });
                match child.wait().await {
                    Ok(status) if status.success() => {
                        let _ = events.send(Event::Finished {
                            applet: applet.clone(),
                        });
                        return;
                    }
                    Ok(status) => {
                        tracing::warn!(applet = %applet, %status, "applet crashed");
                        if restarts >= MAX_RESTARTS {
                            let _ = events.send(Event::Disabled {
                                applet: applet.clone(),
                                crashes: restarts + 1,
                            });
                            return;
                        }
                        restarts += 1;
                        let _ = events.send(Event::Restarting {
                            applet: applet.clone(),
                            attempt: restarts,
                        });
                    }
                    Err(err) => {
                        tracing::warn!(applet = %applet, error = %err, "wait failed");
                        let _ = events.send(Event::Disabled {
                            applet: applet.clone(),
                            crashes: restarts + 1,
                        });
                        return;
                    }
                }
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sh(script: &str) -> Launch {
        let home = std::env::temp_dir().join("vrx-supervisor-test");
        Launch {
            program: "/bin/sh".into(),
            args: vec!["-c".into(), script.into()],
            env: vec![("PATH".into(), "/usr/bin:/bin".into())],
            cwd: "/".into(),
            home,
            cred: None,
        }
    }

    #[tokio::test]
    async fn a_crashing_applet_is_restarted_then_disabled() {
        let (sup, mut events) = Supervisor::new();
        sup.supervise("crasher", sh("exit 3"));
        let mut restarts = 0;
        let mut disabled = false;
        for _ in 0..30 {
            match events.recv().await {
                Some(Event::Started { .. }) => {}
                Some(Event::Restarting { attempt, .. }) => {
                    restarts += 1;
                    assert_eq!(attempt, restarts);
                }
                Some(Event::Disabled { crashes, .. }) => {
                    assert_eq!(crashes, MAX_RESTARTS + 1);
                    disabled = true;
                    break;
                }
                Some(Event::Finished { .. }) => {
                    panic!("a crasher never finishes cleanly")
                }
                None => panic!("events channel closed early"),
            }
        }
        assert!(disabled, "must disable after too many crashes");
        assert_eq!(restarts, MAX_RESTARTS, "three restarts, then disabled");
    }

    #[tokio::test]
    async fn a_clean_exit_finishes_without_restart() {
        let (sup, mut events) = Supervisor::new();
        sup.supervise("finisher", sh("exit 0"));
        loop {
            match events.recv().await {
                Some(Event::Started { .. }) => continue,
                Some(Event::Finished { applet }) => {
                    assert_eq!(applet, "finisher");
                    return;
                }
                other => panic!("expected Finished, got {other:?}"),
            }
        }
    }

    #[tokio::test]
    async fn a_spawn_failure_disables_without_a_loop() {
        let (sup, mut events) = Supervisor::new();
        let mut launch = sh("");
        launch.program = "/nonexistent/vrx/applet".into();
        sup.supervise("ghost", launch);
        loop {
            match events.recv().await {
                Some(Event::Started { .. }) => continue,
                Some(Event::Disabled { applet, crashes }) => {
                    assert_eq!(applet, "ghost");
                    assert_eq!(crashes, 0);
                    return;
                }
                other => panic!("expected Disabled, got {other:?}"),
            }
        }
    }
}
