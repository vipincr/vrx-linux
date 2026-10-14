// /run/vrx/camera/state.json (plan 0018 D6): what camerad knows, as a file
// others watch with inotify (a value that stays true until it changes).
// camerad is the only writer; the directory is the unit's RuntimeDirectory,
// so it vanishes when camerad stops and a crashed camerad cannot leave
// `active: true` behind. No image data is ever in it.

use std::path::{Path, PathBuf};

use serde::Serialize;

use crate::types::{CameraInfo, Kind};

/// Why the camera list is what it is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Reason {
    Ok,
    NoneFound,
    Disabled,
    /// The build named a CSI sensor and nothing enumerated.
    ExpectedCsiMissing,
    Starting,
    Failed,
}

/// What the build said to expect (/etc/vrx/camera/camera.conf).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Conf {
    /// VRX_CAMERA's tokens: usb, csi, virtual.
    pub tokens: Vec<String>,
    /// VRX_CAMERA_SENSOR: auto, or imx219 and friends with an optional
    /// `:cam0`. None when the file does not say.
    pub sensor: Option<String>,
    pub machine: String,
}

impl Conf {
    /// `key=value` lines, `#` comments, values optionally quoted:
    /// tokens=usb csi / sensor=imx219:cam0 / machine=vrxboard-cm4.
    pub fn parse(text: &str) -> Self {
        let mut conf = Conf::default();
        for line in text.lines() {
            let line = line.split('#').next().unwrap_or("").trim();
            let Some((key, value)) = line.split_once('=') else {
                continue;
            };
            let value = value.trim().trim_matches('"').trim_matches('\'').trim();
            match key.trim() {
                "tokens" => {
                    conf.tokens = value.split_whitespace().map(str::to_owned).collect()
                }
                "sensor" if !value.is_empty() => conf.sensor = Some(value.to_owned()),
                "machine" => conf.machine = value.to_owned(),
                _ => {}
            }
        }
        conf
    }

    /// A CSI sensor was named, so one should answer at boot.
    pub fn expects_csi(&self) -> bool {
        self.tokens.iter().any(|t| t == "csi")
            && self.sensor.as_deref().is_some_and(|s| s != "auto")
    }
}

/// The session's progress, as far as the reason cares.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Progress {
    Idle,
    Starting,
    Failed,
}

/// The reason for the current list: a switch off beats everything, a start
/// in progress or failed beats the list, and an empty list is a missing
/// CSI sensor when the build named one.
pub fn reason(
    conf: &Conf,
    cameras: &[CameraInfo],
    enabled: bool,
    progress: Progress,
) -> Reason {
    if !enabled {
        return Reason::Disabled;
    }
    match progress {
        Progress::Starting => return Reason::Starting,
        Progress::Failed => return Reason::Failed,
        Progress::Idle => {}
    }
    if cameras.is_empty() {
        if conf.expects_csi() {
            Reason::ExpectedCsiMissing
        } else {
            Reason::NoneFound
        }
    } else if conf.expects_csi() && !cameras.iter().any(|c| c.kind == Kind::Csi) {
        // a webcam is there but the sensor the build named is not: the list
        // is ok and the missing sensor is the reason worth showing
        Reason::ExpectedCsiMissing
    } else {
        Reason::Ok
    }
}

/// The whole file.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct State {
    pub enabled: bool,
    pub cameras: Vec<CameraInfo>,
    /// A libcamera camera is started (written by the one function that
    /// starts one and cleared by the one that stops it, G058).
    pub active: bool,
    /// Clients holding the frames queue, or a capture in flight.
    pub clients: u32,
    pub reason: Reason,
}

/// Where the file lives.
pub fn path(dir: &Path) -> PathBuf {
    dir.join("state.json")
}

/// Write the file atomically: a temp file in the same directory, renamed
/// over the old one, so a watcher never reads half of it.
pub fn write(dir: &Path, state: &State) -> std::io::Result<()> {
    let body = serde_json::to_vec(state).map_err(std::io::Error::other)?;
    let tmp = dir.join(".state.json.tmp");
    std::fs::write(&tmp, &body)?;
    // the unit's UMask is 0077; everyone may read what camerad knows
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o644))?;
    }
    std::fs::rename(&tmp, path(dir))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::Location;

    fn cam(kind: Kind) -> CameraInfo {
        CameraInfo {
            id: "c0".into(),
            kind,
            name: "Cam".into(),
            location: Location::External,
            max: [640, 480],
        }
    }

    #[test]
    fn the_build_facts_read_from_key_value_lines() {
        let c = Conf::parse(
            "# written at build\ntokens=\"usb csi\"\nsensor=imx219:cam0\nmachine=vrxboard-cm4\n",
        );
        assert_eq!(c.tokens, ["usb", "csi"]);
        assert_eq!(c.sensor.as_deref(), Some("imx219:cam0"));
        assert_eq!(c.machine, "vrxboard-cm4");
        assert!(c.expects_csi());
        assert!(!Conf::parse("tokens=usb csi\nsensor=auto\n").expects_csi());
        assert!(!Conf::parse("tokens=usb\nsensor=imx219\n").expects_csi());
        assert_eq!(Conf::parse(""), Conf::default());
    }

    #[test]
    fn the_reasons_in_their_order() {
        let usb_csi = Conf::parse("tokens=usb csi\nsensor=imx219\n");
        let usb = Conf::parse("tokens=usb\n");
        let r = |c: &Conf, cams: &[CameraInfo], en, p| reason(c, cams, en, p);
        // off beats everything, even a camera that is there
        assert_eq!(
            r(&usb, &[cam(Kind::Usb)], false, Progress::Idle),
            Reason::Disabled
        );
        assert_eq!(r(&usb, &[], true, Progress::Starting), Reason::Starting);
        assert_eq!(r(&usb, &[], true, Progress::Failed), Reason::Failed);
        assert_eq!(r(&usb, &[], true, Progress::Idle), Reason::NoneFound);
        assert_eq!(
            r(&usb_csi, &[], true, Progress::Idle),
            Reason::ExpectedCsiMissing
        );
        assert_eq!(
            r(&usb_csi, &[cam(Kind::Usb)], true, Progress::Idle),
            Reason::ExpectedCsiMissing
        );
        assert_eq!(
            r(&usb_csi, &[cam(Kind::Csi)], true, Progress::Idle),
            Reason::Ok
        );
        assert_eq!(r(&usb, &[cam(Kind::Usb)], true, Progress::Idle), Reason::Ok);
    }

    #[test]
    fn the_file_is_written_whole_and_has_the_planned_keys() {
        let dir = tempfile::tempdir().unwrap();
        let s = State {
            enabled: true,
            cameras: vec![cam(Kind::Usb)],
            active: false,
            clients: 0,
            reason: Reason::NoneFound,
        };
        write(dir.path(), &s).unwrap();
        let v: serde_json::Value =
            serde_json::from_slice(&std::fs::read(path(dir.path())).unwrap()).unwrap();
        assert_eq!(v["reason"], "none-found");
        assert_eq!(v["cameras"][0]["kind"], "usb");
        assert_eq!(v["cameras"][0]["location"], "external");
        assert_eq!(v["cameras"][0]["max"][0], 640);
        assert_eq!(v["active"], false);
        // no stray temp file is left behind
        assert!(!dir.path().join(".state.json.tmp").exists());
        // readable by others under the unit's 0077 umask
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(path(dir.path()))
                .unwrap()
                .permissions()
                .mode();
            assert_eq!(mode & 0o777, 0o644);
        }
    }
}
