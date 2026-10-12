// The applet trait: the store contract, Rust side. The model instance
// owns its state as fields (the evrx-rt style): `reduce` applies the
// action to the model's state and returns the derived view model —
// pure in the sense of deterministic and free of side effects (side
// effects belong in `effects`). `snapshot` is the state vrxhost keeps
// when it suspends the applet and restores when it resumes.

/// A vrx applet.
pub trait Applet: Sized + 'static {
    /// The state type: what suspension preserves and eviction loses.
    type State;

    /// The action type: everything the applet reacts to.
    type Action;

    /// The view model type: what `render` draws.
    type View;

    /// The state a fresh applet starts from, and what a resume
    /// restores.
    fn initial() -> Self::State;

    /// The action whose reduce produces the first view (an applet's
    /// `Init`); its effects fire on boot — resident applets
    /// legitimately announce themselves.
    fn boot_action() -> Self::Action;

    /// Pure: apply the action to the state, return the derived view
    /// model. No side effects.
    fn reduce(&mut self, state: &Self::State, action: &Self::Action) -> Self::View;

    /// Side effects for this action (intents, I/O). Runs after reduce.
    fn effects(
        &mut self,
        _state: &Self::State,
        _action: &Self::Action,
    ) -> Vec<crate::store::Effect> {
        Vec::new()
    }

    /// The model's current state, captured after every reduce.
    fn snapshot(&self) -> Self::State;

    /// Render a view model. A console applet renders as text through
    /// the kit; the runtime owns every other rendering path.
    fn render(view: &Self::View) -> String;
}
