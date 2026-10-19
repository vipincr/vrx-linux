//! A watchable shared-state file, moved from the applet SDK (review
//! 2026-10-17, MOD-09): vrxhost linked the whole SDK for this one
//! watcher. The SDK re-exports it, so an applet's `vrx::ipc::File` is
//! unchanged; the host links the plumbing, not the SDK.

use std::path::{Path, PathBuf};

/// A watchable shared-state file: a value that stays true until it
/// changes. `poll` reads it now; `watch_forever` waits on inotify.
pub struct File {
    path: PathBuf,
    seen: Option<String>,
}

impl File {
    /// Start watching a shared-state file.
    pub fn watch(path: impl AsRef<Path>) -> Self {
        Self {
            path: path.as_ref().to_owned(),
            seen: std::fs::read_to_string(path).ok(),
        }
    }

    /// The current value, or None if the file does not exist.
    pub fn value(&self) -> Option<&str> {
        self.seen.as_deref()
    }

    /// Poll once. Returns Some(change) when the file changed since the
    /// last poll (Some(Some(value)) for a new value, Some(None) for a
    /// removal) and None when nothing changed.
    pub fn poll(&mut self) -> Option<Option<String>> {
        let now = std::fs::read_to_string(&self.path).ok();
        if now != self.seen {
            self.seen = now.clone();
            Some(now)
        } else {
            None
        }
    }

    /// Wait for changes forever, on inotify (no polling, no period: the
    /// closure runs as soon as the file is written or replaced). The
    /// parent directory is watched, because state files are replaced by
    /// rename. Returns only on an error.
    #[cfg(target_os = "linux")]
    pub fn watch_forever<F: FnMut(&str)>(
        mut self,
        mut on_change: F,
    ) -> std::io::Result<()> {
        use rustix::fs::inotify;
        let dir = self
            .path
            .parent()
            .unwrap_or_else(|| Path::new("/"))
            .to_owned();
        let fd = inotify::init(inotify::CreateFlags::CLOEXEC)?;
        inotify::add_watch(
            &fd,
            &dir,
            inotify::WatchFlags::CLOSE_WRITE
                | inotify::WatchFlags::MOVED_TO
                | inotify::WatchFlags::CREATE
                | inotify::WatchFlags::DELETE,
        )?;
        let mut buf = [std::mem::MaybeUninit::<u8>::uninit(); 4096];
        let mut events = inotify::Reader::new(&fd, &mut buf);
        loop {
            // blocks in the kernel until something in the directory changes
            events.next()?;
            if let Some(Some(value)) = self.poll() {
                on_change(&value);
            }
        }
    }

    /// inotify is Linux's; elsewhere (a developer's host) there is no
    /// change notification to wait on.
    #[cfg(not(target_os = "linux"))]
    pub fn watch_forever<F: FnMut(&str)>(self, _on_change: F) -> std::io::Result<()> {
        Err(std::io::Error::new(
            std::io::ErrorKind::Unsupported,
            "File::watch_forever needs inotify (Linux)",
        ))
    }
}
