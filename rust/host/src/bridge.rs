// The inter-applet bridge (plan 0008 D15): what vrxhost hands to running
// applets over their `Listen` call. A listening applet receives the
// intents it handles (asked, for a told handler, with a 100 ms budget for
// its `Answer`), the route it was opened at (plan 0011 D5: a push, or an
// intent opening it there, with the payload), and the channels other
// applets open on it, each with the stream's end as a file descriptor.
// The route an applet was last opened at is kept, so one that starts
// after the push asks for it (`Route`).

use std::collections::HashMap;
use std::os::fd::OwnedFd;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::Value;
use tokio::sync::{mpsc, oneshot};

/// How long a told handler has to answer.
pub const ANSWER_BUDGET: Duration = Duration::from_millis(100);

/// Something for a listening applet.
#[derive(Debug)]
pub enum Delivery {
    /// An intent it handles. `id` is set when an answer is wanted.
    Intent {
        id: Option<u64>,
        name: String,
        payload: Value,
    },
    /// It was opened at `route` ("" is the root), with the payload of the
    /// intent that opened it there, if one did.
    Route {
        route: String,
        payload: Value,
        intent: Option<String>,
    },
    /// Another applet opened one of its channels: the stream's end.
    Channel {
        from: String,
        channel: String,
        fd: OwnedFd,
    },
}

#[derive(Default)]
struct Inner {
    /// applet -> (generation, its Listen)
    listeners: HashMap<String, (u64, mpsc::UnboundedSender<Delivery>)>,
    /// intent id -> (the applet it was asked of, who waits for the answer)
    pending: HashMap<u64, (String, oneshot::Sender<bool>)>,
    /// applet -> the route it was last opened at, its payload and intent
    routes: HashMap<String, (String, Value, Option<String>)>,
    next: u64,
}

/// Why an answer did not land (review 2026-10-17, CON-02).
pub enum AnswerError {
    /// Another applet's intent: the caller was not asked.
    NotAsked,
    /// A late answer; the intent moved on.
    Nobody,
}

/// Shared by every io.vrx.Host connection.
#[derive(Clone, Default)]
pub struct Bridge {
    inner: Arc<Mutex<Inner>>,
    /// Thaws an applet before anything is handed to it (plan 0012 D2);
    /// None in the tests and on a board without systemd's freezer.
    freezer: Option<crate::freeze::Freezer>,
}

impl Bridge {
    /// A bridge that thaws a frozen applet before every delivery.
    pub fn with_freezer(freezer: crate::freeze::Freezer) -> Self {
        Self {
            inner: Arc::default(),
            freezer: Some(freezer),
        }
    }

    /// Thaw `applet` in the background (the delivery waits in its socket
    /// until it runs again).
    fn wake(&self, applet: &str, why: &'static str) {
        if let Some(freezer) = self.freezer.clone() {
            let applet = applet.to_owned();
            tokio::spawn(async move { freezer.awake(&applet, why).await });
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Inner> {
        // a panic while holding it would be a bug elsewhere; the map is
        // still consistent, so carry on with it
        self.inner
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// `applet` holds Listen: the newest Listen wins (a restarted applet).
    pub fn listen(&self, applet: &str) -> (u64, mpsc::UnboundedReceiver<Delivery>) {
        let (tx, rx) = mpsc::unbounded_channel();
        let mut inner = self.lock();
        inner.next += 1;
        let generation = inner.next;
        inner.listeners.insert(applet.to_owned(), (generation, tx));
        (generation, rx)
    }

    /// That Listen ended; a newer one stays.
    pub fn unlisten(&self, applet: &str, generation: u64) {
        let mut inner = self.lock();
        if inner
            .listeners
            .get(applet)
            .is_some_and(|(g, _)| *g == generation)
        {
            inner.listeners.remove(applet);
        }
    }

    pub fn listening(&self, applet: &str) -> bool {
        self.lock().listeners.contains_key(applet)
    }

    fn send(&self, applet: &str, delivery: Delivery) -> Result<(), Delivery> {
        let inner = self.lock();
        match inner.listeners.get(applet) {
            Some((_, tx)) => tx.send(delivery).map_err(|e| e.0),
            None => Err(delivery),
        }
    }

    /// Ask a told handler: Some(handled) as it answered in time; None when
    /// it is not listening, gone, or silent past the budget.
    pub async fn ask(
        &self,
        applet: &str,
        name: &str,
        payload: &Value,
        budget: Duration,
    ) -> Option<bool> {
        let (tx, rx) = oneshot::channel();
        let id = {
            let mut inner = self.lock();
            inner.next += 1;
            let id = inner.next;
            inner.pending.insert(id, (applet.to_owned(), tx));
            id
        };
        let delivery = Delivery::Intent {
            id: Some(id),
            name: name.to_owned(),
            payload: payload.clone(),
        };
        // thawed before the budget starts: a frozen handler would pass by
        // silence
        if let Some(freezer) = &self.freezer {
            freezer.awake(applet, "an intent").await;
        }
        let answer = if self.send(applet, delivery).is_ok() {
            match tokio::time::timeout(budget, rx).await {
                Ok(Ok(answer)) => Some(answer),
                Ok(Err(_)) => None, // the waiter went away
                Err(_) => {
                    // OBS-01 (review 2026-10-17): a handler that let
                    // the budget pass is named at info, not only measured
                    tracing::info!(
                        applet,
                        intent = name,
                        budget_ms = budget.as_millis() as u64,
                        "a told intent passed its answer budget unanswered"
                    );
                    None
                }
            }
        } else {
            None
        };
        self.lock().pending.remove(&id);
        answer
    }

    /// `applet` was opened at `route`: kept for its `Route` call, and told
    /// over its Listen when it is running.
    pub fn open_at(
        &self,
        applet: &str,
        route: &str,
        payload: &Value,
        intent: Option<&str>,
    ) {
        self.lock().routes.insert(
            applet.to_owned(),
            (route.to_owned(), payload.clone(), intent.map(str::to_owned)),
        );
        self.wake(applet, "a route");
        let _ = self.send(
            applet,
            Delivery::Route {
                route: route.to_owned(),
                payload: payload.clone(),
                intent: intent.map(str::to_owned),
            },
        );
    }

    /// Where `applet` was last opened: the root, with no payload, when it
    /// never was.
    pub fn route(&self, applet: &str) -> (String, Value, Option<String>) {
        self.lock().routes.get(applet).cloned().unwrap_or((
            String::new(),
            Value::Null,
            None,
        ))
    }

    /// An Answer arrived; false when nobody waits for it (late, or never
    /// asked).
    pub fn answer(&self, id: u64, handled: bool) -> bool {
        match self.lock().pending.remove(&id) {
            Some((_, tx)) => tx.send(handled).is_ok(),
            None => false,
        }
    }

    /// [Self::answer] bound to the applet the intent was asked of
    /// (review 2026-10-17, CON-02): the pending record carries its
    /// addressee, and a caller that is not it answers nothing.
    pub fn answer_as(
        &self,
        caller: &str,
        id: u64,
        handled: bool,
    ) -> Result<(), AnswerError> {
        let mut lock = self.lock();
        match lock.pending.get(&id) {
            Some((asked, _)) if asked != caller => Err(AnswerError::NotAsked),
            Some(_) => match lock.pending.remove(&id) {
                // the ask left between the check and the remove (its
                // deadline): the asker is gone, the answer goes nowhere
                Some((_, tx)) => {
                    tx.send(handled).ok();
                    Ok(())
                }
                None => Err(AnswerError::Nobody),
            },
            None => Err(AnswerError::Nobody),
        }
    }

    /// Hand a stream's end to `applet`'s Listen; false (the descriptor
    /// dropped) when it is not listening. The caller keeps its own copy.
    pub fn hand(&self, applet: &str, from: &str, channel: &str, fd: OwnedFd) -> bool {
        // it holds this end until every process of its cgroup closes it
        if let Some(freezer) = &self.freezer {
            if let Some(inode) = crate::freeze::inode_of(&fd) {
                freezer.channel_handed(applet, inode);
            }
        }
        self.wake(applet, "a channel");
        let delivery = Delivery::Channel {
            from: from.to_owned(),
            channel: channel.to_owned(),
            fd,
        };
        self.send(applet, delivery).is_ok()
    }
}

/// A descriptor another applet may safely take as a buffer: a dmabuf (a
/// driver's buffer, exported) or a memfd sealed against shrinking, so the
/// receiver's mapping cannot lose its pages under it (SIGBUS). A plain file
/// or a socket is neither (plan 0009 D10).
#[cfg(target_os = "linux")]
pub fn shareable(fd: &OwnedFd) -> bool {
    use std::os::fd::AsRawFd;
    let info = std::fs::read_to_string(format!("/proc/self/fdinfo/{}", fd.as_raw_fd()))
        .unwrap_or_default();
    if info.lines().any(|l| l.starts_with("exp_name:")) {
        return true;
    }
    rustix::fs::fcntl_get_seals(fd)
        .is_ok_and(|seals| seals.contains(rustix::fs::SealFlags::SHRINK))
}

/// Seals and dmabufs are Linux's; nothing is shareable on a host build.
#[cfg(not(target_os = "linux"))]
pub fn shareable(_fd: &OwnedFd) -> bool {
    false
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[tokio::test]
    async fn a_told_handler_answers_inside_the_budget_or_passes() {
        let bridge = Bridge::default();
        assert_eq!(
            bridge
                .ask("clock", "vrx.open", &json!(null), ANSWER_BUDGET)
                .await,
            None,
            "not listening"
        );
        let (_g, mut rx) = bridge.listen("clock");
        let answering = bridge.clone();
        tokio::spawn(async move {
            while let Some(Delivery::Intent {
                id: Some(id), name, ..
            }) = rx.recv().await
            {
                // handles vrx.open, passes on the rest
                answering.answer(id, name == "vrx.open");
            }
        });
        assert_eq!(
            bridge
                .ask("clock", "vrx.open", &json!({}), ANSWER_BUDGET)
                .await,
            Some(true)
        );
        assert_eq!(
            bridge
                .ask("clock", "vrx.other", &json!({}), ANSWER_BUDGET)
                .await,
            Some(false)
        );
        assert!(!bridge.answer(999, true), "nobody waits for a stray answer");
    }

    #[tokio::test]
    async fn silence_past_the_budget_is_a_pass() {
        let bridge = Bridge::default();
        let (_g, _rx) = bridge.listen("slow");
        let started = tokio::time::Instant::now();
        assert_eq!(
            bridge
                .ask("slow", "vrx.open", &json!(null), Duration::from_millis(30))
                .await,
            None
        );
        assert!(started.elapsed() >= Duration::from_millis(30));
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn only_a_sealed_memfd_or_a_dmabuf_is_shareable() {
        use rustix::fs::{
            fcntl_add_seals, ftruncate, memfd_create, MemfdFlags, SealFlags,
        };
        let fd = memfd_create("t", MemfdFlags::ALLOW_SEALING).unwrap();
        ftruncate(&fd, 4096).unwrap();
        assert!(
            !shareable(&fd),
            "an unsealed memfd can shrink under its reader"
        );
        fcntl_add_seals(&fd, SealFlags::SHRINK).unwrap();
        assert!(shareable(&fd));
        let file = OwnedFd::from(std::fs::File::open("/proc/self/status").unwrap());
        assert!(!shareable(&file));
    }

    #[test]
    fn the_newest_listen_wins_and_an_old_one_ending_leaves_it() {
        let bridge = Bridge::default();
        let (old, _a) = bridge.listen("clock");
        let (_new, mut b) = bridge.listen("clock");
        bridge.unlisten("clock", old);
        assert!(bridge.listening("clock"));
        bridge.open_at("clock", "ring", &json!({"id": 1}), Some("sys.alarm.ring"));
        assert!(matches!(
            b.try_recv(),
            Ok(Delivery::Route { route, .. }) if route == "ring"
        ));
    }

    #[test]
    fn the_route_an_applet_was_opened_at_is_kept_for_its_start() {
        let bridge = Bridge::default();
        assert_eq!(bridge.route("setup"), (String::new(), Value::Null, None));
        // not running yet: nothing to tell, but the route is kept
        bridge.open_at("setup", "again", &Value::Null, None);
        assert_eq!(bridge.route("setup").0, "again");
        bridge.open_at("setup", "", &Value::Null, None);
        assert_eq!(bridge.route("setup").0, "");
    }

    #[test]
    fn a_channel_goes_to_the_listener_or_is_refused() {
        let bridge = Bridge::default();
        let (one, two) = std::os::unix::net::UnixStream::pair().unwrap();
        assert!(
            !bridge.hand("cam", "mic", "frames", OwnedFd::from(one)),
            "not listening"
        );
        let (_g, mut rx) = bridge.listen("cam");
        assert!(bridge.hand("cam", "mic", "frames", OwnedFd::from(two)));
        match rx.try_recv() {
            Ok(Delivery::Channel { from, channel, .. }) => {
                assert_eq!((from.as_str(), channel.as_str()), ("mic", "frames"))
            }
            other => panic!("{other:?}"),
        }
    }
}
