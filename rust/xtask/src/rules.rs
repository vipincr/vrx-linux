//! Two repo-level rules the gate runs before any crate is built (review
//! 2026-10-17, steps 43 and 44): the three-valued answer scan, and the
//! contract vectors' two-reader check.

use std::path::Path;

/// R4 (review 2026-10-17, step 43): a check, a probe or a gate answers
/// pass, fail or unknown, and unknown stops the gate or refuses the
/// request. On an authority read (the caller's identity, the USB policy,
/// the Matter allow-list, Facts) "cannot tell" collapsed into a value is
/// an elevation: the old code read an unreadable cgroup as "not an
/// applet", and a non-applet holds every grant. The scan refuses a NEW
/// `unwrap_or` / `unwrap_or_default` / `map_or(true` in those files; the
/// sites that existed when the rule landed are the baseline below, each
/// either an honest default on a non-authority path or owed its own
/// three-valued read. A new site that is genuinely benign says so on its
/// line: `// three-valued: <why>`.
const AUTHORITY_READS: &[&str] = &[
    "rust/host/src/varlink.rs",
    "rust/host/src/usb.rs",
    "rust/host/src/matter.rs",
    "rust/host/src/facts.rs",
];

const COLLAPSES: [&str; 3] = ["unwrap_or(", "unwrap_or_default(", "map_or(true"];

const BASELINE: &[&str] = &[
    "rust/host/src/varlink.rs:366",
    "rust/host/src/varlink.rs:564",
    "rust/host/src/varlink.rs:720",
    "rust/host/src/varlink.rs:739",
    "rust/host/src/varlink.rs:858",
    "rust/host/src/varlink.rs:868",
    "rust/host/src/varlink.rs:872",
    "rust/host/src/varlink.rs:879",
    "rust/host/src/varlink.rs:901",
    "rust/host/src/varlink.rs:907",
    "rust/host/src/varlink.rs:984",
    "rust/host/src/varlink.rs:1087",
    "rust/host/src/varlink.rs:1231",
    "rust/host/src/varlink.rs:1277",
    "rust/host/src/varlink.rs:1390",
    "rust/host/src/varlink.rs:1397",
    "rust/host/src/usb.rs:152",
    "rust/host/src/usb.rs:155",
    "rust/host/src/usb.rs:158",
    "rust/host/src/usb.rs:309",
    "rust/host/src/usb.rs:324",
    "rust/host/src/usb.rs:348",
    "rust/host/src/facts.rs:183",
];

/// False when a new collapse appeared (the gate fails).
pub fn three_valued(repo: &Path) -> bool {
    let mut clean = true;
    for rel in AUTHORITY_READS {
        let Ok(text) = std::fs::read_to_string(repo.join(rel)) else {
            eprintln!("three-valued: {rel}: unreadable");
            clean = false;
            continue;
        };
        for (i, line) in text.lines().enumerate() {
            let found = COLLAPSES.iter().find(|c| line.contains(*c));
            let Some(collapse) = found else { continue };
            let row = format!("{rel}:{}", i + 1);
            if BASELINE.contains(&row.as_str()) {
                continue;
            }
            if line.contains("three-valued:") || text.lines().nth(i).map(|l| l.contains("three-valued:")).unwrap_or(false) {
                continue;
            }
            eprintln!(
                "three-valued: {row} collapses `{collapse}…` on an authority read; \
                 unknown is never yes: return it, or mark the line \
                 `// three-valued: <why>` if it is not an authority answer"
            );
            clean = false;
        }
    }
    clean
}

/// Step 44 (review 2026-10-17): every file under vectors/ is a rule at
/// least two languages read, so at least two test files must read it: a
/// vector with one reader is a private copy again, and a deleted second
/// reader fails here rather than silently stranding the rule.
pub fn vectors_read_twice(repo: &Path) -> bool {
    let vectors = repo.join("vectors");
    let mut clean = true;
    let Ok(entries) = std::fs::read_dir(&vectors) else {
        eprintln!("vectors: {} unreadable", vectors.display());
        return false;
    };
    // the test files: anything under a test/tests directory, or named
    // *_test / *-test, in the languages a reader can be written in
    let mut tests: Vec<(String, String)> = Vec::new();
    let mut stack: Vec<std::path::PathBuf> = vec![
        repo.join("rust"),
        repo.join("flutter"),
        repo.join("applets"),
        repo.join("tools"),
    ];
    while let Some(d) = stack.pop() {
        let Ok(read) = std::fs::read_dir(&d) else { continue };
        for e in read.flatten() {
            let p = e.path();
            if p.is_dir() {
                let name = p.file_name().and_then(|n| n.to_str()).unwrap_or("");
                if !matches!(name, "target" | "build" | ".dart_tool" | ".git") {
                    stack.push(p);
                }
                continue;
            }
            let ext = p.extension().and_then(|e| e.to_str()).unwrap_or("");
            if !matches!(ext, "rs" | "dart" | "sh" | "py") {
                continue;
            }
            let is_test = p.components().any(|c| {
                matches!(c.as_os_str().to_str(), Some("test" | "tests"))
            }) || p
                .file_stem()
                .and_then(|n| n.to_str())
                .is_some_and(|n| n.ends_with("_test") || n.ends_with("-test"));
            if !is_test {
                continue;
            }
            if let Ok(text) = std::fs::read_to_string(&p) {
                tests.push((
                    p.strip_prefix(repo).unwrap_or(&p).display().to_string(),
                    text,
                ));
            }
        }
    }
    for e in entries.flatten() {
        let name = e.file_name().to_string_lossy().into_owned();
        if !name.ends_with(".json") {
            continue;
        }
        let mut readers: Vec<String> = tests
            .iter()
            .filter(|(_, t)| t.contains(&format!("vectors/{name}")))
            .map(|(p, _)| p.clone())
            .collect();
        readers.sort();
        readers.dedup();
        // a vector whose second reader lives in the vrx superproject
        // (the busybox awk twin of a Rust rule): the file must exist
        // there and must still name the vector, or the twin was lost
        const CROSS_REPO: &[(&str, &str)] =
            &[("downgrade.json", "scripts/tests/downgrade-vector.sh")];
        if let Some((_, outside)) = CROSS_REPO.iter().find(|(v, _)| *v == name) {
            let Some(superproject) = repo.ancestors().nth(4) else {
                eprintln!("vectors: {name}: the vrx superproject is not where the tree says");
                clean = false;
                continue;
            };
            let twin = superproject.join(outside);
            match std::fs::read_to_string(&twin) {
                Ok(text) if text.contains(&format!("vectors/{name}")) => {}
                Ok(_) => {
                    eprintln!(
                        "vectors: {name}: {outside} no longer loads it; the rule lost a reader"
                    );
                    clean = false;
                }
                Err(err) => {
                    eprintln!("vectors: {name}: {outside} unreadable ({err}); the rule lost a reader");
                    clean = false;
                }
            }
        }
        if readers.len() < 2 && !CROSS_REPO.iter().any(|(v, _)| *v == name) {
            eprintln!(
                "vectors: {name} has {} reader(s) ({}) but a vector is a rule at \
                 least two languages read; give the second reader a test that \
                 loads it",
                readers.len(),
                readers.join(", ")
            );
            clean = false;
        }
    }
    clean
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_baseline_names_real_rows() {
        // each baseline row still exists and still holds its collapse:
        // a row that was fixed must leave the baseline, or the scan
        // forgets the site ever needed one
        let repo = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .ancestors()
            .nth(2)
            .expect("the workspace root");
        for row in BASELINE {
            let (rel, line) = row.rsplit_once(':').expect("file:line");
            let text = std::fs::read_to_string(repo.join(rel)).expect(rel);
            let line = text.lines().nth(line.parse::<usize>().expect("number") - 1);
            assert!(
                line.is_some_and(|l| COLLAPSES.iter().any(|c| l.contains(c))),
                "{row} no longer collapses anything: strike it from the baseline"
            );
        }
    }
}
