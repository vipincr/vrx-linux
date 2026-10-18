// Impact selection for the gate. The owner, 2026-10-13: tests run on what
// changed, never the whole suite out of habit. Each check names its
// inputs (its own tree, the path dependencies it builds against, the
// lockfiles and data it reads); a green run records their hash in
// target/gate/<check>, and a check whose inputs still hash to that record
// is skipped. `cargo xtask gate --all` runs every check.

use std::path::{Path, PathBuf};

/// Directory and file names no check reads: build output, tool state and
/// version control.
const SKIP: &[&str] = &["build", "target", ".dart_tool", ".git", "node_modules"];

/// FNV-1a, 64-bit: stable across Rust versions, unlike DefaultHasher.
#[derive(Clone, Copy)]
struct Fnv(u64);

impl Fnv {
    fn new() -> Self {
        Self(0xcbf2_9ce4_8422_2325)
    }

    fn write(&mut self, bytes: &[u8]) {
        for b in bytes {
            self.0 ^= u64::from(*b);
            self.0 = self.0.wrapping_mul(0x0100_0000_01b3);
        }
    }
}

fn walk(path: &Path, out: &mut Vec<PathBuf>) {
    walk_skipping(path, out, true);
}

/// The walk. `top` marks the input's own root: build output and tool state
/// (SKIP) are skipped there, and hidden entries at any depth, but a SOURCE
/// directory named "build" or "target" below the top is content the check
/// reads and hashes (review 2026-10-17, CON-03: a skip at every depth made
/// any such directory invisible to every gate).
fn walk_skipping(path: &Path, out: &mut Vec<PathBuf>, top: bool) {
    let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("");
    if (top && SKIP.contains(&name)) || (name.starts_with('.') && name != ".") {
        return;
    }
    if path.is_dir() {
        if let Ok(entries) = std::fs::read_dir(path) {
            for entry in entries.flatten() {
                walk_skipping(&entry.path(), out, false);
            }
        }
    } else if path.is_file() {
        out.push(path.to_path_buf());
    }
}

/// The hash of every file under `inputs` (files or trees): each file's
/// path relative to `repo` and its bytes, in path order. A missing input
/// hashes as absent, so creating it is a change.
pub fn hash(repo: &Path, inputs: &[PathBuf]) -> u64 {
    let mut files = Vec::new();
    for input in inputs {
        walk(input, &mut files);
    }
    files.sort();
    files.dedup();
    let mut h = Fnv::new();
    for file in files {
        let rel = file.strip_prefix(repo).unwrap_or(&file);
        h.write(rel.to_string_lossy().as_bytes());
        h.write(&[0]);
        // an unreadable file hashes as its error, never as an empty file:
        // the two are indistinguishable in the output otherwise (CON-03)
        match std::fs::read(&file) {
            Ok(bytes) => h.write(&bytes),
            Err(err) => h.write(format!("unreadable: {err}").as_bytes()),
        }
        h.write(&[0]);
    }
    h.0
}

/// The toolchain an input's checks run under: a rust-toolchain file at
/// the repo root changes every Rust answer, so every hash carries it
/// (CON-03: no toolchain input meant a toolchain bump never invalidated
/// a stamp).
pub fn toolchain_files(repo: &Path) -> Vec<PathBuf> {
    ["rust-toolchain.toml", "rust-toolchain"]
        .iter()
        .map(|n| repo.join(n))
        .filter(|p| p.is_file())
        .collect()
}

/// The local path dependencies a package builds against, transitively:
/// `path:` entries in a pubspec.yaml, `path = "…"` in a Cargo.toml.
pub fn path_deps(dir: &Path) -> Vec<PathBuf> {
    let mut seen: Vec<PathBuf> = Vec::new();
    let mut todo = vec![dir.to_path_buf()];
    while let Some(d) = todo.pop() {
        for manifest in ["pubspec.yaml", "Cargo.toml"] {
            let Ok(text) = std::fs::read_to_string(d.join(manifest)) else {
                continue;
            };
            for line in text.lines() {
                let line = line.split('#').next().unwrap_or("").trim();
                let dep = if let Some(rest) = line.strip_prefix("path:") {
                    Some(rest.trim().trim_matches('"').to_owned())
                } else {
                    line.find("path = \"").and_then(|at| {
                        let rest = &line[at + 8..];
                        rest.find('"').map(|end| rest[..end].to_owned())
                    })
                };
                let Some(dep) = dep else { continue };
                let Ok(found) = d.join(&dep).canonicalize() else {
                    continue;
                };
                if found != dir && !seen.contains(&found) {
                    seen.push(found.clone());
                    todo.push(found);
                }
            }
        }
    }
    seen.sort();
    seen
}

/// Files a Rust crate reads at compile time from outside its tree:
/// every `include_str!("…")` and `include_bytes!("…")` in its sources,
/// resolved against the source file (rust/sdk's display table,
/// rust/protocol's grants.conf).
pub fn included_files(dir: &Path) -> Vec<PathBuf> {
    let mut sources = Vec::new();
    walk(&dir.join("src"), &mut sources);
    walk(&dir.join("tests"), &mut sources);
    let mut found = Vec::new();
    for src in sources
        .iter()
        .filter(|p| p.extension().is_some_and(|e| e == "rs"))
    {
        let Ok(text) = std::fs::read_to_string(src) else {
            continue;
        };
        for marker in ["include_str!(\"", "include_bytes!(\""] {
            for piece in text.split(marker).skip(1) {
                let Some(end) = piece.find('"') else { continue };
                let target = src.parent().unwrap_or(dir).join(&piece[..end]);
                if let Ok(target) = target.canonicalize() {
                    if !found.contains(&target) {
                        found.push(target);
                    }
                }
            }
        }
    }
    found.sort();
    found
}

/// The records of green runs.
pub struct Stamps {
    dir: PathBuf,
    all: bool,
}

impl Stamps {
    pub fn new(repo: &Path, all: bool) -> Self {
        Self {
            dir: repo.join("target").join("gate"),
            all,
        }
    }

    fn file(&self, check: &str) -> PathBuf {
        self.dir.join(check.replace(['/', ' '], "_"))
    }

    /// The check passed on exactly these inputs before.
    pub fn fresh(&self, check: &str, hash: u64) -> bool {
        !self.all
            && std::fs::read_to_string(self.file(check))
                .map(|t| t.trim() == format!("{hash:016x}"))
                .unwrap_or(false)
    }

    /// The check passed on these inputs.
    pub fn record(&self, check: &str, hash: u64) {
        let _ = std::fs::create_dir_all(&self.dir);
        let _ = std::fs::write(self.file(check), format!("{hash:016x}\n"));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_change_to_any_input_changes_the_hash_and_build_output_does_not() {
        let repo =
            std::env::temp_dir().join(format!("vrx-impact-{}", std::process::id()));
        let pkg = repo.join("pkg");
        std::fs::create_dir_all(pkg.join("lib")).unwrap();
        std::fs::create_dir_all(pkg.join("build")).unwrap();
        std::fs::write(pkg.join("lib/a.dart"), "a").unwrap();
        let before = hash(&repo, std::slice::from_ref(&pkg));
        std::fs::write(pkg.join("build/out"), "noise").unwrap();
        std::fs::write(pkg.join(".hidden"), "noise").unwrap();
        assert_eq!(hash(&repo, std::slice::from_ref(&pkg)), before);
        std::fs::write(pkg.join("lib/a.dart"), "b").unwrap();
        assert_ne!(hash(&repo, std::slice::from_ref(&pkg)), before);
        std::fs::write(pkg.join("lib/a.dart"), "a").unwrap();
        std::fs::write(pkg.join("lib/new.dart"), "").unwrap();
        assert_ne!(
            hash(&repo, std::slice::from_ref(&pkg)),
            before,
            "a new file is a change"
        );
        let _ = std::fs::remove_dir_all(&repo);
    }

    #[test]
    fn path_deps_are_followed_through_pubspecs_and_cargo_manifests() {
        let repo = std::env::temp_dir().join(format!("vrx-deps-{}", std::process::id()));
        for d in ["app", "kit", "check", "sdk", "proto"] {
            std::fs::create_dir_all(repo.join(d)).unwrap();
        }
        std::fs::write(repo.join("app/pubspec.yaml"), "dependencies:\n  kit:\n    path: ../kit\ndev_dependencies:\n  check:\n    path: \"../check\"\n").unwrap();
        std::fs::write(
            repo.join("check/pubspec.yaml"),
            "dependencies:\n  kit:\n    path: ../kit\n",
        )
        .unwrap();
        std::fs::write(
            repo.join("sdk/Cargo.toml"),
            "[dependencies]\nproto = { path = \"../proto\" } # the wire\n",
        )
        .unwrap();
        let canon = |d: &str| repo.join(d).canonicalize().unwrap();
        assert_eq!(
            path_deps(&repo.join("app")),
            vec![canon("check"), canon("kit")]
        );
        assert_eq!(path_deps(&repo.join("sdk")), vec![canon("proto")]);
        assert!(path_deps(&repo.join("kit")).is_empty());
        let _ = std::fs::remove_dir_all(&repo);
    }

    #[test]
    fn included_files_are_inputs() {
        let repo = std::env::temp_dir().join(format!("vrx-incl-{}", std::process::id()));
        std::fs::create_dir_all(repo.join("data")).unwrap();
        std::fs::create_dir_all(repo.join("krate/src")).unwrap();
        std::fs::write(repo.join("data/table.json"), "{}").unwrap();
        std::fs::write(
            repo.join("krate/src/lib.rs"),
            "const T: &str = include_str!(\"../../data/table.json\");\nconst M: &str = include_str!(\"missing\");\n",
        )
        .unwrap();
        assert_eq!(
            included_files(&repo.join("krate")),
            vec![repo.join("data/table.json").canonicalize().unwrap()]
        );
        let _ = std::fs::remove_dir_all(&repo);
    }

    #[test]
    fn a_record_is_fresh_only_for_the_same_inputs_and_never_under_all() {
        let repo =
            std::env::temp_dir().join(format!("vrx-stamps-{}", std::process::id()));
        let stamps = Stamps::new(&repo, false);
        assert!(!stamps.fresh("flutter applets/usb", 7));
        stamps.record("flutter applets/usb", 7);
        assert!(stamps.fresh("flutter applets/usb", 7));
        assert!(!stamps.fresh("flutter applets/usb", 8));
        assert!(!Stamps::new(&repo, true).fresh("flutter applets/usb", 7));
        let _ = std::fs::remove_dir_all(&repo);
    }
}
