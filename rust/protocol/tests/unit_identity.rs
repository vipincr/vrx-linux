// Plan 0011 D17: the drop-ins and settings defaults vrx_protocol::unit
// writes for the 13 built-ins, byte for byte against the files the
// bbclass's Python wrote for the same manifests (recorded in tests/unit/
// before the Python was deleted, with the manifests frozen beside them).
// A difference is either a regression or a deliberate change, and a
// deliberate one updates the recorded file in the same commit.

#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use std::path::Path;

use vrx_protocol::unit::{dropin, settings_defaults, Grants, Place};
use vrx_protocol::Manifest;

const FLUTTER: &str = "3.47.5";

#[test]
fn every_builtin_dropin_is_byte_identical_to_the_record() {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/unit");
    let grants = Grants::shipped();
    let mut seen = 0;
    let mut entries: Vec<_> = std::fs::read_dir(&dir).unwrap().flatten().collect();
    entries.sort_by_key(|e| e.path());
    for entry in entries {
        let path = entry.path();
        let name = path.file_name().unwrap().to_string_lossy().into_owned();
        let Some(id) = name.strip_suffix(".manifest.toml") else {
            continue;
        };
        let manifest: Manifest = std::fs::read_to_string(&path).unwrap().parse().unwrap();
        let home = format!("/system/defaults/{id}");
        let bundle = format!("{home}/{FLUTTER}/release");
        let place = Place::builtin(home, Some(bundle));
        let want = std::fs::read_to_string(dir.join(format!("{id}.conf"))).unwrap();
        assert_eq!(
            dropin(&manifest, &place, &grants).unwrap(),
            want,
            "{id}: drop-in"
        );
        let settings = dir.join(format!("{id}.settings"));
        assert_eq!(
            settings_defaults(&manifest),
            std::fs::read_to_string(&settings).ok(),
            "{id}: settings defaults"
        );
        seen += 1;
    }
    assert_eq!(seen, 13, "the 13 built-ins");
}
