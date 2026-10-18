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
    // the LIVE manifests under applets/ (review 2026-10-17, TST-10): an
    // edit to one reaches this test the moment it is saved, where the
    // frozen copies beside the goldens never changed again
    let goldens = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/unit");
    let grants = Grants::shipped();
    let applets = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../applets");
    let recipes = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../layer/recipes-applets/vrx-applets");
    let mut live: Vec<_> = std::fs::read_dir(&applets)
        .expect("applets/ beside the workspace")
        .flatten()
        .map(|e| e.path())
        // only applets that ship: a recipe builds them. A directory with
        // no recipe (console, work in progress) never reaches the
        // generator and has nothing to record.
        .filter(|d| {
            d.join("manifest.toml").is_file()
                && d.file_name()
                    .and_then(|n| n.to_str())
                    .is_some_and(|id| recipes.join(format!("vrx-applet-{id}.bb")).is_file())
        })
        .collect();
    live.sort();
    let mut seen = 0;
    for dir in live {
        let Some(id) = dir.file_name().and_then(|n| n.to_str()) else {
            continue;
        };
        let manifest: Manifest =
            std::fs::read_to_string(dir.join("manifest.toml")).unwrap().parse().unwrap();
        let home = format!("/system/defaults/{id}");
        let bundle = (manifest.applet.runtime
            == vrx_protocol::manifest::Runtime::Flutter)
            .then(|| format!("{home}/{FLUTTER}/release"));
        let place = Place::builtin(home, bundle);
        let want = std::fs::read_to_string(goldens.join(format!("{id}.conf")));
        assert!(want.is_ok(), "{id}: no recorded drop-in in tests/unit/ (add {id}.conf)");
        assert_eq!(
            dropin(&manifest, &place, &grants).unwrap(),
            want.unwrap(),
            "{id}: drop-in"
        );
        let settings = goldens.join(format!("{id}.settings"));
        assert_eq!(
            settings_defaults(&manifest),
            std::fs::read_to_string(&settings).ok(),
            "{id}: settings defaults"
        );
        seen += 1;
    }
    assert!(seen > 0, "no live applets found");
    // every golden belongs to a live applet: a deleted applet's record
    // does not outlive it
    for entry in std::fs::read_dir(&goldens).unwrap().flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        let Some(id) = name.strip_suffix(".conf") else { continue };
        assert!(
            applets.join(id).join("manifest.toml").is_file(),
            "{id}: a recorded drop-in with no live applet"
        );
    }
}

/// Records the drop-in and settings of every live applet that has none
/// yet. Run it deliberately, once, when a new applet lands (it never
/// overwrites: regenerating a golden that changed would bake the change
/// in; edit the .conf by hand or review the diff).
#[test]
#[ignore = "records new applets' goldens on purpose"]
fn record_missing_goldens() {
    let goldens = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/unit");
    let grants = Grants::shipped();
    let applets = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../applets");
    let recipes = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../layer/recipes-applets/vrx-applets");
    for entry in std::fs::read_dir(&applets).unwrap().flatten() {
        let dir = entry.path();
        let Some(id) = dir.file_name().and_then(|n| n.to_str()) else {
            continue;
        };
        if !dir.join("manifest.toml").is_file()
            || goldens.join(format!("{id}.conf")).is_file()
            || !recipes.join(format!("vrx-applet-{id}.bb")).is_file()
        {
            continue;
        }
        let manifest: Manifest =
            std::fs::read_to_string(dir.join("manifest.toml")).unwrap().parse().unwrap();
        let home = format!("/system/defaults/{id}");
        let bundle = (manifest.applet.runtime
            == vrx_protocol::manifest::Runtime::Flutter)
            .then(|| format!("{home}/{FLUTTER}/release"));
        let place = Place::builtin(home, bundle);
        std::fs::write(
            goldens.join(format!("{id}.conf")),
            dropin(&manifest, &place, &grants).unwrap(),
        )
        .unwrap();
        // no settings defaults, no golden file: the identity test reads a
        // missing file as None, which is the answer it must match
        if let Some(text) = settings_defaults(&manifest) {
            std::fs::write(goldens.join(format!("{id}.settings")), text).unwrap();
        }
        println!("recorded {id}");
    }
}
