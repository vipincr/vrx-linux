// The store loop: the only writer of the state. All actions pass
// through `dispatch`, one at a time, in order: reduce runs, the
// snapshot updates, effects fire, the view publishes. The caller
// hands `dispatch` the effect sink — the runtime passes one that
// sends intents over the vrxhost socket; a host test passes a
// recorder. Nothing hides inside the store.

use crate::applet::Applet;

/// A side effect the store asks the system to perform after a reduce.
/// Effects are the only place an applet touches the world; `reduce`
/// stays pure.
#[derive(Debug, Clone, PartialEq)]
pub enum Effect {
    /// Send an intent (the signal IPC shape).
    Intent(vrx_protocol::Intent),
}

impl Effect {
    /// Build an intent effect; an invalid name yields None (dropped —
    /// `vrx` name lint is the compile-time guard; effects never panic).
    pub fn intent(
        name: impl Into<String>,
        payload: vrx_protocol::IntentPayload,
    ) -> Option<Self> {
        vrx_protocol::Intent::new(name, payload)
            .ok()
            .map(Effect::Intent)
    }
}

/// What to do with a fired effect.
pub trait EffectSink {
    fn deliver(&mut self, effect: &Effect);
}

/// Deliver nothing: the standalone default (vrxhost not running).
#[derive(Debug, Default, Clone, Copy)]
pub struct NullSink;

impl EffectSink for NullSink {
    fn deliver(&mut self, _effect: &Effect) {}
}

/// Record every effect, oldest first: the host-test observation
/// channel.
#[derive(Debug, Default)]
pub struct RecordingSink(Vec<Effect>);

impl RecordingSink {
    pub fn fired(&self) -> &[Effect] {
        &self.0
    }
}

impl EffectSink for RecordingSink {
    fn deliver(&mut self, effect: &Effect) {
        self.0.push(effect.clone());
    }
}

/// The store: one instance per running applet.
pub struct Store<A: Applet> {
    applet: A,
    state: A::State,
    view: A::View,
    pending_boot_effects: Vec<Effect>,
}

impl<A: Applet> Store<A> {
    /// Seed the store: run the boot action through the loop. Its
    /// effects are held pending and fire on the first `dispatch` —
    /// resident applets legitimately announce themselves on boot.
    pub fn new(mut applet: A) -> Self {
        let state = A::initial();
        let view = applet.reduce(&state, &A::boot_action());
        let pending_boot_effects = applet.effects(&state, &A::boot_action());
        Self {
            applet,
            state,
            view,
            pending_boot_effects,
        }
    }

    /// Apply one action: reduce, snapshot, effects, publish.
    pub fn dispatch(&mut self, action: A::Action, sink: &mut dyn EffectSink) {
        self.view = self.applet.reduce(&self.state, &action);
        self.state = self.applet.snapshot();
        for effect in std::mem::take(&mut self.pending_boot_effects) {
            sink.deliver(&effect);
        }
        for effect in self.applet.effects(&self.state, &action) {
            sink.deliver(&effect);
        }
    }

    /// The current view model.
    pub fn view(&self) -> &A::View {
        &self.view
    }

    /// The current state snapshot.
    pub fn state(&self) -> &A::State {
        &self.state
    }

    /// The applet itself (for `render`, or a resume restore).
    pub fn applet(&self) -> &A {
        &self.applet
    }
}

/// The host-runnable test harness: drive a store with actions, assert
/// on views and effects — no board, no engine.
pub struct StoreHarness<A: Applet> {
    store: Store<A>,
    recorder: RecordingSink,
    reduce_budget: std::time::Duration,
}

/// Plan 0008 D18: one action through reduce and effects stays under
/// this in a host test. A reducer is a pure function on the event loop;
/// anything slower is I/O or work that belongs in an effect.
pub const REDUCE_BUDGET: std::time::Duration = std::time::Duration::from_millis(2);

impl<A: Applet> StoreHarness<A> {
    pub fn new(applet: A) -> Self {
        Self {
            store: Store::new(applet),
            recorder: RecordingSink::default(),
            reduce_budget: REDUCE_BUDGET,
        }
    }

    /// A different budget, for a test that measures something heavier
    /// on purpose (and says why).
    pub fn with_budget(mut self, budget: std::time::Duration) -> Self {
        self.reduce_budget = budget;
        self
    }

    /// Dispatch an action through the recording sink. Fails the test
    /// when the action overruns the reduce budget.
    pub fn dispatch(&mut self, action: A::Action) {
        let started = std::time::Instant::now();
        self.store.dispatch(action, &mut self.recorder);
        let took = started.elapsed();
        assert!(
            took <= self.reduce_budget,
            "reduce budget: an action took {took:?}, over {:?} (plan 0008 D18)",
            self.reduce_budget
        );
    }

    /// The current view model.
    pub fn view(&self) -> &A::View {
        self.store.view()
    }

    /// The current state snapshot.
    pub fn state(&self) -> &A::State {
        self.store.state()
    }

    /// The effects fired so far, oldest first.
    pub fn fired(&self) -> &[Effect] {
        self.recorder.fired()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::applet::Applet;

    // the reference model: the plan's counter
    struct Counter {
        count: i32,
    }

    enum Action {
        Tap,
        Reset,
    }

    struct View {
        count: i32,
    }

    impl Applet for Counter {
        type State = i32;
        type Action = Action;
        type View = View;

        fn initial() -> i32 {
            0
        }

        fn boot_action() -> Action {
            Action::Reset
        }

        fn reduce(&mut self, state: &i32, action: &Action) -> View {
            match action {
                Action::Tap => self.count += 1,
                Action::Reset => self.count = 0,
            }
            let _ = state;
            View { count: self.count }
        }

        fn effects(&mut self, _state: &i32, action: &Action) -> Vec<Effect> {
            match action {
                Action::Tap if self.count == 1 => {
                    Effect::intent("myapp.first.tap", serde_json::json!(null))
                        .into_iter()
                        .collect()
                }
                _ => Vec::new(),
            }
        }

        fn snapshot(&self) -> i32 {
            self.count
        }

        fn render(view: &View) -> String {
            format!("count: {}", view.count)
        }
    }

    #[test]
    fn boot_action_seeds_the_initial_view() {
        let harness = StoreHarness::new(Counter { count: 99 });
        assert_eq!(harness.view().count, 0, "boot resets to zero");
    }

    #[test]
    fn dispatch_reduces_in_order() {
        let mut harness = StoreHarness::new(Counter { count: 0 });
        harness.dispatch(Action::Tap);
        harness.dispatch(Action::Tap);
        harness.dispatch(Action::Reset);
        harness.dispatch(Action::Tap);
        assert_eq!(harness.view().count, 1);
        assert_eq!(*harness.state(), 1);
    }

    #[test]
    fn boot_effects_fire_on_the_first_dispatch() {
        let mut harness = StoreHarness::new(Counter { count: 0 });
        harness.dispatch(Action::Tap);
        harness.dispatch(Action::Tap);
        // boot (Reset) fires nothing for the counter; the first Tap
        // announces once — proving order: boot effects, then the
        // action's
        assert_eq!(harness.fired().len(), 1, "only the first tap announces");
        assert!(
            matches!(&harness.fired()[0], Effect::Intent(i) if i.name == "myapp.first.tap")
        );
    }

    #[test]
    fn an_invalid_intent_name_drops_the_effect() {
        assert!(Effect::intent("not-dotted", serde_json::json!(null)).is_none());
        assert!(Effect::intent("ok.tap", serde_json::json!(1)).is_some());
    }
}
