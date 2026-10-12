// The back trail: vrxhost's navigation state. A stack of at most 3
// entries that survives a suspend/resume cycle. Back pops one entry;
// Home clears to the `home` role applet. The trail is vrxhost's, not
// the applet's — an applet cannot manipulate it, so this type never
// leaves the daemon.

/// One trail entry: which applet, at which route (0 = the root).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TrailEntry {
    pub applet: String,
    pub route: u32,
}

/// The maximum trail depth. Overflow evicts the oldest entry; an
/// evicted applet loses its state.
pub const TRAIL_MAX: usize = 3;

#[derive(Debug, Default, PartialEq, Eq)]
pub struct Trail {
    entries: Vec<TrailEntry>,
}

impl Trail {
    pub fn new() -> Self {
        Self::default()
    }

    /// Push an entry; when the trail is full the oldest entry is
    /// evicted (its applet's state is lost) and returned.
    pub fn push(&mut self, entry: TrailEntry) -> Option<TrailEntry> {
        let evicted = if self.entries.len() >= TRAIL_MAX {
            if self.entries.is_empty() {
                None
            } else {
                Some(self.entries.remove(0))
            }
        } else {
            None
        };
        self.entries.push(entry);
        evicted
    }

    /// Back: pop the top entry and return it. An empty trail returns
    /// None (the caller takes the applet Home).
    pub fn back(&mut self) -> Option<TrailEntry> {
        self.entries.pop()
    }

    /// Home: clear the trail to the home applet's root.
    pub fn home(&mut self, home_applet: &str) {
        self.entries.clear();
        self.entries.push(TrailEntry {
            applet: home_applet.to_owned(),
            route: 0,
        });
    }

    /// The top of the trail, if any.
    pub fn top(&self) -> Option<&TrailEntry> {
        self.entries.last()
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(applet: &str) -> TrailEntry {
        TrailEntry {
            applet: applet.to_owned(),
            route: 0,
        }
    }

    #[test]
    fn overflow_evicts_the_oldest() {
        let mut trail = Trail::new();
        assert_eq!(trail.push(entry("launcher")), None);
        assert_eq!(trail.push(entry("clock")), None);
        assert_eq!(trail.push(entry("alarms")), None);
        assert_eq!(
            trail.push(entry("timer")),
            Some(entry("launcher")), // evicted; its state is lost
            "the oldest entry is evicted, not the newest refused"
        );
        assert_eq!(trail.len(), TRAIL_MAX);
        assert_eq!(trail.top(), Some(&entry("timer")));
    }

    #[test]
    fn back_pops_one_entry() {
        let mut trail = Trail::new();
        trail.push(entry("launcher"));
        trail.push(entry("clock"));
        assert_eq!(trail.back(), Some(entry("clock")));
        assert_eq!(trail.top(), Some(&entry("launcher")));
    }

    #[test]
    fn back_on_an_empty_trail_is_none() {
        let mut trail = Trail::new();
        assert_eq!(trail.back(), None);
    }

    #[test]
    fn home_clears_to_the_home_applet() {
        let mut trail = Trail::new();
        trail.push(entry("clock"));
        trail.push(entry("alarms"));
        trail.home("launcher");
        assert_eq!(trail.len(), 1);
        assert_eq!(trail.top(), Some(&entry("launcher")));
    }
}
