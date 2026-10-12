// The supervisor: vrxhost's half of applet lifecycle. Spawns applet
// processes, watches them, restarts on crash — at most MAX_RESTARTS
// times, then the applet is disabled and a human is told. A clean
// exit is an applet finishing (app.finished), not a crash.

use std::ffi::OsString;
use std::process::Stdio;

use tokio::process::Command;
use tokio::sync::mpsc;

/// Restarts allowed after a crash before the applet is disabled.
pub const MAX_RESTARTS: u32 = 3;

/// What the supervisor tells vrxhost about a supervised applet.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    /// The applet process started (spawn or restart).
    Started { applet: String },
    /// The applet exited cleanly (it finished; not restarted).
    Finished { applet: String },
    /// The applet crashed and is being restarted.
    Restarting { applet: String, attempt: u32 },
    /// The applet crashed too many times, or could not be spawned at
    /// all; it is now disabled.
    Disabled { applet: String, crashes: u32 },
}

/// The supervisor. Owns one monitoring task per supervised applet; all
/// events surface on one channel, which is the source of truth for
/// applet state. The command is held as program + args (tokio Commands
/// cannot be cloned) and rebuilt per spawn.
#[derive(Debug)]
pub struct Supervisor {
    events_tx: mpsc::UnboundedSender<Event>,
    events_rx: mpsc::UnboundedReceiver<Event>,
}

impl Supervisor {
    pub fn new() -> Self {
        let (events_tx, events_rx) = mpsc::unbounded_channel();
        Self {
            events_tx,
            events_rx,
        }
    }

    /// Spawn and supervise an applet: `applet` is its id, the process
    /// is `program` with `args`, re-spawned verbatim on restart.
    pub fn supervise(
        &mut self,
        applet: &str,
        program: impl Into<OsString>,
        args: Vec<OsString>,
    ) {
        let applet = applet.to_owned();
        let program = program.into();
        let events = self.events_tx.clone();

        tokio::spawn(async move {
            let mut restarts = 0u32;
            loop {
                let mut command = Command::new(&program);
                command.args(&args);
                command.stdin(Stdio::null());
                command.stdout(Stdio::null());
                command.stderr(Stdio::null());
                command.kill_on_drop(true);

                let _ = events.send(Event::Started {
                    applet: applet.clone(),
                });
                match command.status().await {
                    Ok(status) if status.success() => {
                        let _ = events.send(Event::Finished {
                            applet: applet.clone(),
                        });
                        return;
                    }
                    Ok(_) => {
                        // a crash: restart, or disable after too many
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
                        // could not spawn at all: a configuration
                        // failure, not a crash loop — do not spin
                        tracing::warn!(applet = %applet, error = %err, "spawn failed");
                        let _ = events.send(Event::Disabled {
                            applet: applet.clone(),
                            crashes: 0,
                        });
                        return;
                    }
                }
            }
        });
    }

    /// The next supervision event, or None when the channel closed.
    pub async fn next_event(&mut self) -> Option<Event> {
        self.events_rx.recv().await
    }
}

impl Default for Supervisor {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sh(script: &str) -> (String, Vec<OsString>) {
        ("/bin/sh".to_owned(), vec!["-c".into(), script.into()])
    }

    #[tokio::test]
    async fn a_crashing_applet_is_restarted_then_disabled() {
        let mut sup = Supervisor::new();
        let (program, args) = sh("exit 3");
        sup.supervise("crasher", program, args);
        let mut restarts = 0;
        let mut disabled = false;
        for _ in 0..30 {
            match sup.next_event().await {
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
        let mut sup = Supervisor::new();
        let (program, args) = sh("exit 0");
        sup.supervise("finisher", program, args);
        loop {
            match sup.next_event().await {
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
        let mut sup = Supervisor::new();
        sup.supervise("ghost", "/nonexistent/vrx/applet", vec![]);
        loop {
            match sup.next_event().await {
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
