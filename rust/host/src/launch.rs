// How an applet process is started: the command line for its runtime,
// and the sandbox it runs in (amendment B). vrxhost runs as root; every
// applet runs as the unprivileged `vrx` user with exactly the groups
// its display needs, in vrxhost's own read-only mount namespace (the
// unit's ProtectSystem=strict), under NoNewPrivileges (the unit's
// too), so an applet cannot regain root through su, sudo or a file
// capability.

use std::ffi::OsString;
use std::io;
use std::path::{Path, PathBuf};

use vrx_protocol::manifest::{Kind, Runtime};
use vrx_protocol::RegistryEntry;

/// The Flutter applet runtime: flutter-vrx in its app role.
pub const FLUTTER_RUNTIME: &str = "/usr/bin/flutter-vrx";

/// The account applets run as (created by the vrxhost package).
pub const APPLET_USER: &str = "vrx";

/// Supplementary groups an applet needs to render: `video` opens the
/// KMS node its buffers are allocated on (scanout memory comes from the
/// display driver), `render` the GPU's render node. Absent groups are
/// skipped; a board without a render node has no `render` group.
pub const APPLET_GROUPS: &[&str] = &["video", "render"];

/// Everything needed to (re)start one applet process.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Launch {
    pub program: OsString,
    pub args: Vec<OsString>,
    /// The whole environment: nothing leaks from vrxhost's.
    pub env: Vec<(OsString, OsString)>,
    /// Working directory (the applet's directory).
    pub cwd: PathBuf,
    /// Writable per-applet home, created before every start.
    pub home: PathBuf,
    /// Who the process runs as; None runs it as vrxhost's own user
    /// (host tests only: the daemon always resolves a credential).
    pub cred: Option<Credential>,
}

/// A resolved unprivileged identity.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Credential {
    pub uid: u32,
    pub gid: u32,
    pub groups: Vec<u32>,
}

#[derive(Debug, thiserror::Error)]
pub enum LaunchError {
    #[error("{applet}: no Flutter bundle (<dir>/<engine-version>/release) under {dir}")]
    NoBundle { applet: String, dir: String },
    #[error("{0}: a library is linked, never launched")]
    Library(String),
    #[error("no user {0:?} in /etc/passwd (the vrxhost package creates it)")]
    NoUser(String),
    #[error("reading the account databases: {0}")]
    Accounts(#[from] io::Error),
}

/// Build the launch for a registry entry. `runtime_dir` is vrxhost's
/// writable runtime directory (homes live under it).
pub fn for_entry(
    entry: &RegistryEntry,
    runtime_dir: &Path,
    cred: Option<Credential>,
) -> Result<Launch, LaunchError> {
    let applet = &entry.manifest.applet;
    if applet.kind == Kind::Library {
        return Err(LaunchError::Library(applet.id.clone()));
    }
    let (program, args) = match applet.runtime {
        Runtime::Flutter => {
            let bundle =
                flutter_bundle(&entry.path).ok_or_else(|| LaunchError::NoBundle {
                    applet: applet.id.clone(),
                    dir: entry.path.display().to_string(),
                })?;
            // --release: the engine vrx ships is AOT-only
            (
                OsString::from(FLUTTER_RUNTIME),
                vec!["--release".into(), "--app".into(), bundle.into_os_string()],
            )
        }
        Runtime::Rust | Runtime::Native => {
            (entry.path.join("app").into_os_string(), Vec::new())
        }
    };
    let home = runtime_dir.join("home").join(&applet.id);
    let mut env: Vec<(OsString, OsString)> = vec![
        ("PATH".into(), "/usr/bin:/bin".into()),
        ("HOME".into(), home.clone().into_os_string()),
        (
            "XDG_CACHE_HOME".into(),
            home.join(".cache").into_os_string(),
        ),
        ("VRX_APPLET".into(), applet.id.clone().into()),
    ];
    // the locale is the system's, not vrxhost's business to pick
    for key in ["LANG", "LC_ALL", "TZ"] {
        if let Some(value) = std::env::var_os(key) {
            env.push((key.into(), value));
        }
    }
    Ok(Launch {
        program,
        args,
        env,
        cwd: entry.path.clone(),
        home,
        cred,
    })
}

/// The bundle directory of an installed Flutter applet:
/// <dir>/<engine-version>/release (meta-flutter's install layout). The
/// lexically last version wins, so a leftover older engine's bundle
/// never shadows the current one.
pub fn flutter_bundle(dir: &Path) -> Option<PathBuf> {
    let mut found: Vec<PathBuf> = std::fs::read_dir(dir)
        .ok()?
        .filter_map(Result::ok)
        .map(|e| e.path().join("release"))
        .filter(|p| p.is_dir())
        .collect();
    found.sort();
    found.pop()
}

/// Resolve the applet credential from the account databases.
pub fn applet_credential() -> Result<Credential, LaunchError> {
    let passwd = std::fs::read_to_string("/etc/passwd")?;
    let group = std::fs::read_to_string("/etc/group")?;
    resolve_credential(&passwd, &group, APPLET_USER, APPLET_GROUPS)
}

/// The pure half of [`applet_credential`]: parse passwd/group text.
pub fn resolve_credential(
    passwd: &str,
    group: &str,
    user: &str,
    extra_groups: &[&str],
) -> Result<Credential, LaunchError> {
    let (uid, gid) = passwd
        .lines()
        .map(|l| l.split(':').collect::<Vec<_>>())
        .find(|f| f.len() >= 4 && f[0] == user)
        .and_then(|f| Some((f[2].parse().ok()?, f[3].parse().ok()?)))
        .ok_or_else(|| LaunchError::NoUser(user.to_owned()))?;
    let mut groups = vec![gid];
    for name in extra_groups {
        let found = group
            .lines()
            .map(|l| l.split(':').collect::<Vec<_>>())
            .find(|f| f.len() >= 3 && f[0] == *name)
            .and_then(|f| f[2].parse::<u32>().ok());
        if let Some(g) = found {
            if !groups.contains(&g) {
                groups.push(g);
            }
        }
    }
    Ok(Credential { uid, gid, groups })
}

/// Create the applet's home: private to the applet user. An existing
/// home is kept as it is (vrxhost holds no CAP_FOWNER, so it could not
/// chmod a directory the applet owns; it set the mode when it made it).
pub fn prepare_home(launch: &Launch) -> io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    if launch.home.is_dir() {
        return Ok(());
    }
    if let Some(parent) = launch.home.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::create_dir(&launch.home)?;
    // mode first: after the chown the directory is no longer ours
    std::fs::set_permissions(&launch.home, std::fs::Permissions::from_mode(0o700))?;
    if let Some(cred) = &launch.cred {
        std::os::unix::fs::chown(&launch.home, Some(cred.uid), Some(cred.gid))?;
    }
    Ok(())
}

/// The tokio command for a launch, with the identity drop applied in
/// the child before exec.
pub fn command(launch: &Launch) -> tokio::process::Command {
    let mut command = tokio::process::Command::new(&launch.program);
    command.args(&launch.args);
    command.env_clear();
    command.envs(launch.env.iter().map(|(k, v)| (k, v)));
    command.current_dir(&launch.cwd);
    if let Some(cred) = launch.cred.clone() {
        drop_privileges(&mut command, cred);
    }
    command
}

// std's uid()/gid() cannot set supplementary groups (CommandExt::groups
// is unstable) and clears them instead, which would cut the applet off
// from the GPU. So the drop is done here, in the forked child, in the
// only safe order: groups, then gid, then uid (after setuid there is no
// privilege left to change the other two).
#[allow(unsafe_code)]
fn drop_privileges(command: &mut tokio::process::Command, cred: Credential) {
    // SAFETY: the closure runs in the forked child before exec and calls
    // only async-signal-safe functions (setgroups, setgid, setuid) on
    // data moved in before the fork; it allocates nothing.
    unsafe {
        command.pre_exec(move || {
            #[cfg(target_os = "linux")]
            let n = cred.groups.len();
            #[cfg(not(target_os = "linux"))]
            let n = cred.groups.len() as libc::c_int;
            if libc::setgroups(n, cred.groups.as_ptr()) != 0
                || libc::setgid(cred.gid) != 0
                || libc::setuid(cred.uid) != 0
            {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const PASSWD: &str =
        "root:x:0:0:root:/root:/bin/sh\nvrx:x:993:990::/nonexistent:/sbin/nologin\n";
    const GROUP: &str = "root:x:0:\nvideo:x:44:\nrender:x:107:\nvrx:x:990:\n";

    #[test]
    fn the_credential_carries_the_render_groups() {
        let cred = resolve_credential(PASSWD, GROUP, "vrx", APPLET_GROUPS).unwrap();
        assert_eq!(
            cred,
            Credential {
                uid: 993,
                gid: 990,
                groups: vec![990, 44, 107]
            }
        );
    }

    #[test]
    fn an_absent_group_is_skipped_and_an_absent_user_refused() {
        let cred =
            resolve_credential(PASSWD, "video:x:44:\n", "vrx", APPLET_GROUPS).unwrap();
        assert_eq!(cred.groups, vec![990, 44]);
        let err = resolve_credential(PASSWD, GROUP, "ghost", APPLET_GROUPS).unwrap_err();
        assert!(err.to_string().contains("ghost"), "{err}");
    }

    fn entry(dir: &Path, runtime: &str) -> RegistryEntry {
        let manifest = format!(
            "[applet]\nid = \"clock\"\nname = \"Clock\"\nversion = \"1.0.0\"\nruntime = \"{runtime}\"\n"
        );
        RegistryEntry {
            manifest: manifest.parse().unwrap(),
            path: dir.to_path_buf(),
            builtin: true,
        }
    }

    #[test]
    fn a_flutter_applet_launches_its_newest_bundle_in_the_app_role() {
        let tmp = tempfile::tempdir().unwrap();
        for v in ["3.38.0", "3.41.0"] {
            std::fs::create_dir_all(tmp.path().join(v).join("release")).unwrap();
        }
        let launch =
            for_entry(&entry(tmp.path(), "flutter"), Path::new("/tmp/vrx"), None)
                .unwrap();
        assert_eq!(launch.program, OsString::from(FLUTTER_RUNTIME));
        let bundle = tmp.path().join("3.41.0/release").into_os_string();
        assert_eq!(
            launch.args,
            vec!["--release".into(), "--app".into(), bundle]
        );
        assert_eq!(launch.home, PathBuf::from("/tmp/vrx/home/clock"));
        assert!(launch
            .env
            .iter()
            .any(|(k, v)| k == "HOME" && v == "/tmp/vrx/home/clock"));
    }

    #[test]
    fn a_flutter_applet_without_a_bundle_is_refused_by_name() {
        let tmp = tempfile::tempdir().unwrap();
        let err = for_entry(&entry(tmp.path(), "flutter"), Path::new("/tmp/vrx"), None)
            .unwrap_err();
        assert!(
            err.to_string().starts_with("clock: no Flutter bundle"),
            "{err}"
        );
    }

    #[test]
    fn a_native_applet_runs_its_app_binary() {
        let tmp = tempfile::tempdir().unwrap();
        let launch =
            for_entry(&entry(tmp.path(), "rust"), Path::new("/tmp/vrx"), None).unwrap();
        assert_eq!(launch.program, tmp.path().join("app").into_os_string());
        assert!(launch.args.is_empty());
    }
}
