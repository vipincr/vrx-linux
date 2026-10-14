// An installed applet's package (plan 0011 D16): a systemd system
// extension image holding the applet's folder and an extension-release
// file. One home for its shape, which `vrx pack` writes and vrxhost
// checks, and for the install policy the image was built with (plan 0013
// D3): whether it installs at all, and whether an image must be signed.

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

/// The install policy the image was built with (plan 0013 D3), written by
/// vrxhost's recipe from `VRX_INSTALLS`: `installs=yes` or `installs=no`.
/// Absent, or anything else, means no installs: the default is closed.
pub const INSTALL_CONF: &str = "/usr/lib/vrx/install.conf";

/// Whether INSTALL_CONF's text allows installs.
pub fn installs_on(text: &str) -> bool {
    conf_value(text, "installs").as_deref() == Some("yes")
}

/// The systemd-sysext configuration drop-in a release image ships (plan
/// 0013 D3). Its `[SysExt] ImagePolicy=` is what systemd-sysext enforces
/// when it merges, at boot and through its Varlink socket; vrxhost reads
/// the same file and inspects offers under the same policy, so what the
/// launcher offers is what systemd will merge. A debug image ships no
/// drop-in: systemd's default policy, which also takes unsigned images.
pub const SIGNED_DROPIN: &str = "/usr/lib/systemd/sysext.conf.d/50-vrx-signed.conf";

/// The `ImagePolicy=` value a sysext.conf drop-in's text sets, if any.
pub fn image_policy(text: &str) -> Option<String> {
    let mut in_section = false;
    let mut found = None;
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') || line.starts_with(';') {
            continue;
        }
        if line.starts_with('[') {
            in_section = line == "[SysExt]";
            continue;
        }
        if !in_section {
            continue;
        }
        if let Some((k, v)) = line.split_once('=') {
            if k.trim() == "ImagePolicy" {
                found = Some(v.trim().to_owned());
            }
        }
    }
    found.filter(|v| !v.is_empty())
}

/// The GPT partition types of a verity signature partition (systemd's
/// Discoverable Partitions Specification, `src/systemd/sd-gpt.h` in
/// systemd 259), for the architectures vrx builds for: root and usr,
/// arm64 and x86-64. Only the wording of a refusal reads this ("unsigned"
/// against "untrusted"); the decision is systemd's and the kernel's.
const VERITY_SIG_TYPES: [[u8; 16]; 4] = [
    // root-arm64-verity-sig 6db69de6-29f4-4758-a7a5-962190f00ce3
    guid(
        0x6db6_9de6,
        0x29f4,
        0x4758,
        [0xa7, 0xa5, 0x96, 0x21, 0x90, 0xf0, 0x0c, 0xe3],
    ),
    // usr-arm64-verity-sig c23ce4ff-44bd-4b00-b2d4-b41b3419e02a
    guid(
        0xc23c_e4ff,
        0x44bd,
        0x4b00,
        [0xb2, 0xd4, 0xb4, 0x1b, 0x34, 0x19, 0xe0, 0x2a],
    ),
    // root-x86-64-verity-sig 41092b05-9fc8-4523-994f-2def0408b176
    guid(
        0x4109_2b05,
        0x9fc8,
        0x4523,
        [0x99, 0x4f, 0x2d, 0xef, 0x04, 0x08, 0xb1, 0x76],
    ),
    // usr-x86-64-verity-sig e7bb33fb-06cf-4e81-8273-e543b413e2e2
    guid(
        0xe7bb_33fb,
        0x06cf,
        0x4e81,
        [0x82, 0x73, 0xe5, 0x43, 0xb4, 0x13, 0xe2, 0xe2],
    ),
];

/// A GUID in its on-disk (mixed-endian) byte order.
const fn guid(a: u32, b: u16, c: u16, d: [u8; 8]) -> [u8; 16] {
    let a = a.to_le_bytes();
    let b = b.to_le_bytes();
    let c = c.to_le_bytes();
    [
        a[0], a[1], a[2], a[3], b[0], b[1], c[0], c[1], d[0], d[1], d[2], d[3], d[4],
        d[5], d[6], d[7],
    ]
}

/// The image carries a verity signature partition: it is a GPT disk image
/// (a Discoverable Disk Image, as `systemd-repart --make-ddi=sysext`
/// writes) with a root or usr verity-sig partition. A bare erofs image, or
/// a disk image without one, is unsigned.
pub fn has_verity_signature(image: &mut (impl std::io::Read + std::io::Seek)) -> bool {
    use std::io::SeekFrom;
    let mut header = [0u8; 92];
    if image.seek(SeekFrom::Start(512)).is_err() || image.read_exact(&mut header).is_err()
    {
        return false;
    }
    if &header[..8] != b"EFI PART" {
        return false;
    }
    let field = |at: usize, len: usize| {
        let mut b = [0u8; 8];
        b[..len].copy_from_slice(&header[at..at + len]);
        u64::from_le_bytes(b)
    };
    let (lba, count, size) = (field(72, 8), field(80, 4), field(84, 4) as usize);
    if !(128..=4096).contains(&size) || count > 1024 {
        return false;
    }
    if image
        .seek(SeekFrom::Start(lba.saturating_mul(512)))
        .is_err()
    {
        return false;
    }
    let mut entry = vec![0u8; size];
    for _ in 0..count {
        if image.read_exact(&mut entry).is_err() {
            return false;
        }
        if VERITY_SIG_TYPES.iter().any(|t| entry[..16] == *t) {
            return true;
        }
    }
    false
}

/// The value of `key` in a key=value file (the last one wins).
fn conf_value(text: &str, key: &str) -> Option<String> {
    text.lines()
        .filter_map(|l| {
            let l = l.trim();
            if l.starts_with('#') {
                return None;
            }
            let (k, v) = l.split_once('=')?;
            (k.trim() == key).then(|| v.trim().trim_matches('"').to_owned())
        })
        .next_back()
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

    #[test]
    fn installs_are_off_unless_the_policy_file_says_yes() {
        assert!(installs_on("# written by vrxhost's recipe\ninstalls=yes\n"));
        assert!(!installs_on("installs=no\n"));
        assert!(!installs_on(""));
        assert!(!installs_on("installs=YES\n"));
    }

    #[test]
    fn the_image_policy_is_read_from_the_sysext_section_only() {
        let text =
            "# c\n[SysExt]\nImagePolicy=root=signed+absent:usr=signed+absent:=ignore\n";
        assert_eq!(
            image_policy(text).as_deref(),
            Some("root=signed+absent:usr=signed+absent:=ignore")
        );
        assert_eq!(image_policy("[ConfExt]\nImagePolicy=*\n"), None);
        assert_eq!(image_policy("ImagePolicy=*\n"), None);
        assert_eq!(image_policy("[SysExt]\nMutable=no\n"), None);
    }

    /// The shipped drop-in, the one home of the policy string, requires a
    /// signature for root and usr and uses nothing else.
    #[test]
    fn the_shipped_signed_policy_requires_signed_root_and_usr() {
        let shipped =
            include_str!("../../../layer/recipes-core/vrxhost/files/50-vrx-signed.conf");
        let policy = image_policy(shipped).expect("an ImagePolicy= line");
        let parts: Vec<&str> = policy.split(':').collect();
        assert!(parts.contains(&"root=signed+absent"), "{policy}");
        assert!(parts.contains(&"usr=signed+absent"), "{policy}");
        assert!(parts.contains(&"=ignore"), "{policy}");
        assert!(!policy.contains("unprotected"), "{policy}");
        assert!(!policy.contains("verity"), "{policy}");
    }

    /// A GPT image with a root-arm64-verity-sig partition reads as signed;
    /// a bare filesystem or a GPT without one does not.
    #[test]
    fn a_verity_signature_partition_is_found_in_the_gpt() {
        fn disk(types: &[[u8; 16]]) -> std::io::Cursor<Vec<u8>> {
            let mut d = vec![0u8; 512 * 40];
            let h = &mut d[512..512 + 92];
            h[..8].copy_from_slice(b"EFI PART");
            h[72..80].copy_from_slice(&2u64.to_le_bytes());
            h[80..84].copy_from_slice(&128u32.to_le_bytes());
            h[84..88].copy_from_slice(&128u32.to_le_bytes());
            for (i, t) in types.iter().enumerate() {
                let at = 1024 + i * 128;
                d[at..at + 16].copy_from_slice(t);
            }
            std::io::Cursor::new(d)
        }
        // root-arm64 b921b045-1df0-41c3-af44-4c6f280d3fae, as repart writes it
        let root = guid(
            0xb921_b045,
            0x1df0,
            0x41c3,
            [0xaf, 0x44, 0x4c, 0x6f, 0x28, 0x0d, 0x3f, 0xae],
        );
        assert!(has_verity_signature(&mut disk(&[
            root,
            VERITY_SIG_TYPES[0]
        ])));
        assert!(!has_verity_signature(&mut disk(&[root])));
        assert!(!has_verity_signature(&mut std::io::Cursor::new(vec![
            0u8;
            4096
        ])));
        assert!(!has_verity_signature(&mut std::io::Cursor::new(vec![
            0u8;
            10
        ])));
        // the on-disk order of 6db69de6-29f4-4758-a7a5-962190f00ce3, as read
        // from an image systemd-repart 257 signed (bench, 2026-10-14)
        assert_eq!(
            VERITY_SIG_TYPES[0],
            [
                0xe6, 0x9d, 0xb6, 0x6d, 0xf4, 0x29, 0x58, 0x47, 0xa7, 0xa5, 0x96, 0x21,
                0x90, 0xf0, 0x0c, 0xe3
            ]
        );
    }
}
