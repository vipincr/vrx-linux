#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

// The applet id grammar is one predicate (vrx_protocol::manifest::
// applet_id_ok) and one vector: this test and manifest.rs's own hold the
// predicate to vectors/applet-id.json, so a rule loosened or tightened on
// either side fails a test that names the row (review step 44).
use serde_json::Value;
use vrx_protocol::manifest::applet_id_ok;

#[test]
fn the_grammar_is_the_vectors() {
    let v: Value = serde_json::from_str(include_str!("../../../vectors/applet-id.json"))
        .expect("vectors/applet-id.json parses");
    for id in v["valid"].as_array().expect("valid") {
        let id = id.as_str().expect("a string");
        assert!(applet_id_ok(id), "{id:?} must be a valid id");
    }
    for id in v["invalid"].as_array().expect("invalid") {
        let id = id.as_str().expect("a string");
        assert!(!applet_id_ok(id), "{id:?} must be refused");
    }
}
