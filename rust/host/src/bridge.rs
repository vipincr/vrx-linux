// The inter-applet bridge (plan 0008 D15): what vrxhost hands to running
// applets over their `Listen` call. A listening applet receives the
// intents it handles (asked, for a told handler, with a 100 ms budget for
// its `Answer`; told, for an opened handler already running) and the
// channels other applets open on it, each with the stream's end as a
// file descriptor.

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
    /// intent id -> who waits for the answer
    pending: HashMap<u64, oneshot::Sender<bool>>,
    next: u64,
}

/// Shared by every io.vrx.Host connection.
#[derive(Clone, Default)]
pub struct Bridge {
    inner: Arc<Mutex<Inner>>,
}

impl Bridge {
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
            inner.pending.insert(id, tx);
            id
        };
        let delivery = Delivery::Intent {
            id: Some(id),
            name: name.to_owned(),
            payload: payload.clone(),
        };
        let answer = if self.send(applet, delivery).is_ok() {
            tokio::time::timeout(budget, rx)
                .await
                .ok()
                .and_then(Result::ok)
        } else {
            None
        };
        self.lock().pending.remove(&id);
        answer
    }

    /// Tell an opened handler that is running: no answer wanted.
    pub fn tell(&self, applet: &str, name: &str, payload: &Value) {
        let _ = self.send(
            applet,
            Delivery::Intent {
                id: None,
                name: name.to_owned(),
                payload: payload.clone(),
            },
        );
    }

    /// An Answer arrived; false when nobody waits for it (late, or never
    /// asked).
    pub fn answer(&self, id: u64, handled: bool) -> bool {
        match self.lock().pending.remove(&id) {
            Some(tx) => tx.send(handled).is_ok(),
            None => false,
        }
    }

    /// Hand a stream's end to `applet`'s Listen; false (the descriptor
    /// dropped) when it is not listening. The caller keeps its own copy.
    pub fn hand(&self, applet: &str, from: &str, channel: &str, fd: OwnedFd) -> bool {
        let delivery = Delivery::Channel {
            from: from.to_owned(),
            channel: channel.to_owned(),
            fd,
        };
        self.send(applet, delivery).is_ok()
    }
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

    #[test]
    fn the_newest_listen_wins_and_an_old_one_ending_leaves_it() {
        let bridge = Bridge::default();
        let (old, _a) = bridge.listen("clock");
        let (_new, mut b) = bridge.listen("clock");
        bridge.unlisten("clock", old);
        assert!(bridge.listening("clock"));
        bridge.tell("clock", "sys.alarm.ring", &json!({"id": 1}));
        assert!(matches!(
            b.try_recv(),
            Ok(Delivery::Intent { id: None, .. })
        ));
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
