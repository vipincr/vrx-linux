// An installed applet's package (plan 0011 D16): a systemd system
// extension image holding the applet's folder and an extension-release
// file. One home for its shape, which `vrx pack` writes and vrxhost
// checks.

/// The extension level vrx's images carry and its os-release names
/// (`SYSEXT_LEVEL=1`): bumped when the OS can no longer run what was
/// built for it; systemd-sysext then refuses the old images itself.
pub const SYSEXT_LEVEL: &str = "1";

/// Where an installed applet's folder is inside its image, and on the
/// system once merged (relative to /).
pub const APPS_DIR: &str = "usr/lib/vrx/apps";

/// The extension-release file of applet `id`, relative to /.
pub fn release_path(id: &str) -> String {
    format!("usr/lib/extension-release.d/extension-release.{id}")
}

/// Its contents.
pub fn release_text() -> String {
    format!("ID=vrx\nSYSEXT_LEVEL={SYSEXT_LEVEL}\n")
}

/// The file says `ID=vrx` and this level.
pub fn release_ok(text: &str) -> bool {
    let value = |key: &str| {
        text.lines().find_map(|l| {
            let (k, v) = l.split_once('=')?;
            (k.trim() == key).then(|| v.trim().trim_matches('"').to_owned())
        })
    };
    value("ID").as_deref() == Some("vrx")
        && value("SYSEXT_LEVEL").as_deref() == Some(SYSEXT_LEVEL)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_release_file_is_vrxs_at_this_level() {
        assert!(release_ok(&release_text()));
        assert!(release_ok("ID=\"vrx\"\nSYSEXT_LEVEL=\"1\"\n"));
        assert!(!release_ok("ID=vrx\nSYSEXT_LEVEL=2\n"));
        assert!(!release_ok("ID=fedora\nSYSEXT_LEVEL=1\n"));
        assert!(!release_ok("ID=_any\n"));
    }
}
