// Finding controls on screen (plan 0014 D8): each applet's semantics
// tree, as the compositor writes it to /run/vrx-ui/semantics/<id>.json
// while semantics is on. A node is {id, rect: [l, t, r, b] in panel
// pixels, tap, label, value, hint, tooltip}.

use std::path::Path;

use serde::Deserialize;

pub const SEMANTICS_DIR: &str = "/run/vrx-ui/semantics";

#[derive(Debug, Clone, Deserialize)]
pub struct Node {
    pub rect: [f64; 4],
    #[serde(default)]
    pub tap: bool,
    #[serde(default)]
    pub label: Option<String>,
}

#[derive(Debug, Deserialize)]
struct Tree {
    nodes: Vec<Node>,
}

/// An applet's nodes; none when it has sent no tree.
pub fn nodes(dir: &Path, applet: &str) -> Vec<Node> {
    std::fs::read_to_string(dir.join(format!("{applet}.json")))
        .ok()
        .and_then(|t| serde_json::from_str::<Tree>(&t).ok())
        .map(|t| t.nodes)
        .unwrap_or_default()
}

/// The point to touch for `label` among `nodes`: the centre of the one
/// control with that label (a tappable node first). Two different controls
/// with the label is an error, named, since guessing would walk the wrong
/// path.
pub fn find(nodes: &[Node], label: &str) -> Result<Option<(u32, u32)>, String> {
    let named: Vec<&Node> = nodes
        .iter()
        .filter(|n| n.label.as_deref() == Some(label))
        .collect();
    let tappable: Vec<&Node> = named.iter().copied().filter(|n| n.tap).collect();
    let pick = if tappable.is_empty() { named } else { tappable };
    let Some(first) = pick.first() else {
        return Ok(None);
    };
    if pick.iter().any(|n| n.rect != first.rect) {
        return Err(format!(
            "{} controls are labelled {label:?}; name the applet with `in` or use xy",
            pick.len()
        ));
    }
    let [l, t, r, b] = first.rect;
    let centre = |a: f64, b: f64| ((a + b) / 2.0).max(0.0).round() as u32;
    Ok(Some((centre(l, r), centre(t, b))))
}

/// Where to look: the applet named, else the shell (drawn above
/// everything) then the front applet.
pub fn search_order(within: Option<&str>, front: &str) -> Vec<String> {
    match within {
        Some(a) => vec![a.to_owned()],
        None => vec!["shell".to_owned(), front.to_owned()],
    }
}

/// `label` on screen, in any of `applets`.
pub fn shown(dir: &Path, applets: &[String], label: &str) -> bool {
    applets.iter().any(|a| {
        nodes(dir, a)
            .iter()
            .any(|n| n.label.as_deref() == Some(label))
    })
}

/// Waits for the semantics directory to change, or the timeout: the
/// compositor replaces a tree by rename, which inotify reports.
pub struct Changes {
    #[cfg(target_os = "linux")]
    fd: std::os::fd::OwnedFd,
}

impl Changes {
    #[cfg(target_os = "linux")]
    pub fn watch(dir: &Path) -> std::io::Result<Self> {
        use rustix::fs::inotify;
        let fd = inotify::init(
            inotify::CreateFlags::CLOEXEC | inotify::CreateFlags::NONBLOCK,
        )?;
        inotify::add_watch(
            &fd,
            dir,
            inotify::WatchFlags::MOVED_TO
                | inotify::WatchFlags::CLOSE_WRITE
                | inotify::WatchFlags::DELETE,
        )?;
        Ok(Self { fd })
    }

    #[cfg(not(target_os = "linux"))]
    pub fn watch(dir: &Path) -> std::io::Result<Self> {
        Err(std::io::Error::new(
            std::io::ErrorKind::Unsupported,
            format!("watching {} needs inotify (Linux)", dir.display()),
        ))
    }

    /// Block until something in the directory changes or `timeout`
    /// passes; true for a change.
    #[cfg(target_os = "linux")]
    pub fn wait(&self, timeout: std::time::Duration) -> bool {
        use rustix::event::{poll, PollFd, PollFlags, Timespec};
        let ts = Timespec {
            tv_sec: timeout.as_secs() as i64,
            tv_nsec: i64::from(timeout.subsec_nanos()),
        };
        let mut fds = [PollFd::new(&self.fd, PollFlags::IN)];
        let ready = matches!(poll(&mut fds, Some(&ts)), Ok(n) if n > 0);
        if ready {
            // drain: the events only say "look again"
            let mut buf = [std::mem::MaybeUninit::<u8>::uninit(); 4096];
            let mut events = rustix::fs::inotify::Reader::new(&self.fd, &mut buf);
            while events.next().is_ok() {}
        }
        ready
    }

    #[cfg(not(target_os = "linux"))]
    pub fn wait(&self, _timeout: std::time::Duration) -> bool {
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn node(rect: [f64; 4], tap: bool, label: &str) -> Node {
        Node {
            rect,
            tap,
            label: Some(label.to_owned()),
        }
    }

    #[test]
    fn a_label_is_the_centre_of_its_control() {
        let nodes = vec![
            node([0.0, 0.0, 480.0, 40.0], false, "Settings"),
            node([20.0, 100.0, 220.0, 160.0], true, "Settings"),
        ];
        assert_eq!(
            find(&nodes, "Settings").unwrap(),
            Some((120, 130)),
            "the tappable one"
        );
        assert_eq!(find(&nodes, "Wi-Fi").unwrap(), None);
    }

    #[test]
    fn two_controls_with_one_label_are_named_not_guessed() {
        let nodes = vec![
            node([0.0, 0.0, 10.0, 10.0], true, "Back"),
            node([0.0, 50.0, 10.0, 60.0], true, "Back"),
        ];
        assert!(find(&nodes, "Back").unwrap_err().contains("2 controls"));
    }

    #[test]
    fn a_tree_reads_from_the_compositors_file() {
        let tmp = tempfile::tempdir().unwrap();
        std::fs::write(
            tmp.path().join("settings.json"),
            r#"{"nodes":[{"id":3,"rect":[0,40,480,96],"actions":1,"flags":0,"tap":true,"label":"Wi-Fi","value":"Home"}]}"#,
        )
        .unwrap();
        let order = search_order(None, "settings");
        assert_eq!(order, vec!["shell", "settings"]);
        assert!(shown(tmp.path(), &order, "Wi-Fi"));
        assert!(!shown(tmp.path(), &order, "Bluetooth"));
        assert_eq!(
            find(&nodes(tmp.path(), "settings"), "Wi-Fi").unwrap(),
            Some((240, 68))
        );
    }
}
