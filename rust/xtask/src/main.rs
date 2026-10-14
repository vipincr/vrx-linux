// The gate (octiva discipline, plan 0007 part K).
//
// `cargo xtask gate` runs, in order, all blocking:
//   1. per workspace crate: cargo fmt --check, clippy -D warnings, test
//   2. the docs AGENTS.md names (G036), the crates manifest, the
//      responsiveness scan, the image's fonts
//   3. per Flutter package: pub get, analyze, test (layout checks too)
//   4. per Rust applet: fmt, clippy, test (its layout check too)
//   5. cargo deny check bans licenses sources
// Checks are chosen by impact (impact.rs): one whose inputs are unchanged
// since it last passed is skipped; `cargo xtask gate --all` runs all.
// A change is not done until the gate is green. The gate is a build
// tool: it reports to stdout and spawns cargo; the applet print and
// spawn lints do not apply here.

#![allow(clippy::print_stdout, clippy::print_stderr)]
#![cfg_attr(test, allow(clippy::unwrap_used, clippy::expect_used, clippy::panic))]

mod crates_inc;
mod docs;
mod fonts;
mod impact;
mod ui_standard;

use std::process::{Command, ExitCode, Stdio};

fn main() -> ExitCode {
    let mut args = std::env::args().skip(1);
    let task = args.next().unwrap_or_default();
    let args: Vec<String> = args.collect();
    match task.as_str() {
        "gate" => gate(args.iter().any(|a| a == "--all")),
        "crates-inc" => crates_inc::run(&args),
        "ui-standard" => match ui_standard::run(&repo_root()) {
            Ok(()) => ExitCode::SUCCESS,
            Err(err) => {
                eprintln!("ui-standard: {err}");
                ExitCode::FAILURE
            }
        },
        "fonts" => match fonts::ensure() {
            Ok(()) => {
                println!("fonts: in {}", fonts::dir().display());
                ExitCode::SUCCESS
            }
            Err(err) => {
                eprintln!("fonts: {err}");
                ExitCode::FAILURE
            }
        },
        _ => {
            eprintln!(
                "usage: cargo xtask gate [--all] | crates-inc | ui-standard | fonts"
            );
            ExitCode::from(64)
        }
    }
}

/// The Rust applets under applets/ (standalone crates, outside the
/// workspace): fmt, clippy -D warnings and their tests, which include the
/// layout check every applet carries (tests/layout.rs, AGENTS.md rule 11),
/// the same steps `vrx build` runs before it compiles one.
fn rust_applets_gate(repo: &std::path::Path, stamps: &impact::Stamps) -> bool {
    let Ok(entries) = std::fs::read_dir(repo.join("applets")) else {
        return true;
    };
    let mut crates: Vec<_> = entries
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.join("Cargo.toml").is_file())
        .collect();
    crates.sort();
    for dir in crates {
        let shown = dir.strip_prefix(repo).unwrap_or(&dir).display().to_string();
        // a service has no screen, so nothing to lay out (manifest kind)
        let service = std::fs::read_to_string(dir.join("manifest.toml"))
            .ok()
            .and_then(|t| t.parse::<vrx_protocol::manifest::Manifest>().ok())
            .is_some_and(|m| m.applet.kind == vrx_protocol::manifest::Kind::Service);
        if !service && !dir.join("tests").join("layout.rs").is_file() {
            eprintln!(
                "gate: FAILED — {shown} has no tests/layout.rs (AGENTS.md rule 11)"
            );
            return false;
        }
        let mut inputs = vec![dir.clone()];
        for dep in impact::path_deps(&dir).into_iter().chain([dir.clone()]) {
            inputs.extend(impact::included_files(&dep));
            inputs.push(dep);
        }
        let hash = impact::hash(repo, &inputs);
        let check = format!("rust {shown}");
        if stamps.fresh(&check, hash) {
            println!("gate: {shown}: unchanged since it passed");
            continue;
        }
        let steps: [&[&str]; 3] = [
            &["fmt", "--check"],
            &["clippy", "--all-targets", "--", "-D", "warnings"],
            &["test"],
        ];
        for args in steps {
            println!("gate: cargo {} ({shown})", args.join(" "));
            let ok = Command::new("cargo")
                .args(args)
                .current_dir(&dir)
                .status()
                .map(|s| s.success())
                .unwrap_or(false);
            if !ok {
                eprintln!("gate: FAILED at cargo {} in {shown}", args.join(" "));
                return false;
            }
        }
        stamps.record(&check, hash);
    }
    true
}

/// Every applet's literal intents and pushes against the manifests under
/// applets/ (vrx_protocol::scan::sent_violations), as `applets/<id>/...`.
fn sent_literals_gate(repo: &std::path::Path) -> Vec<String> {
    let Ok(entries) = std::fs::read_dir(repo.join("applets")) else {
        return Vec::new();
    };
    let mut dirs: Vec<_> = entries.flatten().map(|e| e.path()).collect();
    dirs.sort();
    let manifests: Vec<(std::path::PathBuf, vrx_protocol::Manifest)> = dirs
        .into_iter()
        .filter_map(|d| {
            let text = std::fs::read_to_string(d.join("manifest.toml")).ok()?;
            Some((d, text.parse().ok()?))
        })
        .collect();
    let known: Vec<vrx_protocol::Manifest> =
        manifests.iter().map(|(_, m)| m.clone()).collect();
    let mut out = Vec::new();
    for (dir, manifest) in &manifests {
        let shown = dir.strip_prefix(repo).unwrap_or(dir).display().to_string();
        for f in vrx_protocol::scan::sent_violations(dir, manifest, Some(&known)) {
            out.push(format!("{shown}/{f}"));
        }
    }
    out
}

/// The Flutter SDK's version file: an SDK upgrade changes every package's
/// analysis and tests.
fn flutter_version_file() -> Option<std::path::PathBuf> {
    let out = Command::new("sh")
        .args(["-c", "command -v flutter"])
        .output()
        .ok()?;
    let bin = std::path::PathBuf::from(String::from_utf8_lossy(&out.stdout).trim())
        .canonicalize()
        .ok()?;
    let version = bin.parent()?.parent()?.join("version");
    version.is_file().then_some(version)
}

/// flutter analyze (the vrx lint set, errors fail) and flutter test, in
/// every package with a pubspec: the SDK and tools under flutter/, then
/// the applets. Refuses to pass silently without a flutter binary.
fn flutter_gate(repo: &std::path::Path, stamps: &impact::Stamps) -> bool {
    let mut dirs = Vec::new();
    for root in ["flutter", "applets"] {
        if let Ok(entries) = std::fs::read_dir(repo.join(root)) {
            let mut found: Vec<_> = entries
                .flatten()
                .map(|e| e.path())
                .filter(|p| p.join("pubspec.yaml").is_file())
                .collect();
            found.sort();
            dirs.extend(found);
        }
    }
    let mut shared = vec![fonts::dir()];
    shared.extend(flutter_version_file());
    for dir in dirs {
        let shown = dir.strip_prefix(repo).unwrap_or(&dir).display().to_string();
        // every screen of every applet on every display (AGENTS.md rule 11,
        // evrx-rt rule 52): an applet without its layout test is refused,
        // as `vrx build` refuses it
        if dir.parent() == Some(&repo.join("applets"))
            && !dir.join("test").join("layout_test.dart").is_file()
        {
            eprintln!(
                "gate: FAILED — {shown} has no test/layout_test.dart (AGENTS.md rule 11)"
            );
            return false;
        }
        let mut inputs = vec![dir.clone()];
        inputs.extend(impact::path_deps(&dir));
        inputs.extend(shared.iter().cloned());
        let hash = impact::hash(repo, &inputs);
        let check = format!("flutter {shown}");
        if stamps.fresh(&check, hash) {
            println!("gate: {shown}: unchanged since it passed");
            continue;
        }
        // the lockfile must already resolve the package (the Yocto build
        // resolves offline with --enforce-lockfile): a stale lockfile fails
        // here, not in the image build
        println!("gate: flutter pub get --enforce-lockfile ({shown})");
        let resolved = Command::new("flutter")
            .args(["pub", "get", "--enforce-lockfile"])
            .current_dir(&dir)
            .status()
            .map(|s| s.success())
            .unwrap_or(false);
        if !resolved {
            eprintln!("gate: FAILED: {shown}/pubspec.lock does not resolve its pubspec (run flutter pub get there)");
            return false;
        }
        for args in [["analyze", "--no-pub"], ["test", "--no-pub"]] {
            let shown = dir.strip_prefix(repo).unwrap_or(&dir).display().to_string();
            println!("gate: flutter {} ({shown})", args[0]);
            let status = Command::new("flutter")
                .args(args)
                .current_dir(&dir)
                .status();
            match status {
                Ok(s) if s.success() => {}
                Ok(_) => {
                    eprintln!("gate: FAILED at flutter {} in {shown}", args[0]);
                    return false;
                }
                Err(_) => {
                    eprintln!("gate: FAILED: flutter is not installed (the Flutter half of the gate cannot be skipped)");
                    return false;
                }
            }
        }
        stamps.record(&check, hash);
    }
    true
}

/// The workspace members, from the root Cargo.toml: (directory, package).
fn workspace_crates(repo: &std::path::Path) -> Vec<(std::path::PathBuf, String)> {
    let text = std::fs::read_to_string(repo.join("Cargo.toml")).unwrap_or_default();
    let Some(list) = text
        .split("members = [")
        .nth(1)
        .and_then(|t| t.split(']').next())
    else {
        return Vec::new();
    };
    list.split(',')
        .filter_map(|m| {
            let dir = repo.join(m.trim().trim_matches('"'));
            let manifest = std::fs::read_to_string(dir.join("Cargo.toml")).ok()?;
            let name = manifest.lines().find_map(|l| {
                l.trim()
                    .strip_prefix("name = \"")?
                    .strip_suffix('"')
                    .map(str::to_owned)
            })?;
            Some((dir, name))
        })
        .collect()
}

/// An applet whose user (vrx-<id>) is a grant's group, named.
fn applet_user_clash(repo: &std::path::Path) -> Option<String> {
    // the drop-in generator the image build and vrxhost run (plan 0011
    // D17) refuses the clash; asking it for every applet's drop-in finds
    // it here, with any other reason a drop-in could not be written
    let grants = vrx_protocol::unit::Grants::parse(
        &std::fs::read_to_string(
            repo.join("layer/recipes-applets/vrx-applets/files/grants.conf"),
        )
        .ok()?,
    )
    .ok()?;
    let mut entries: Vec<_> = std::fs::read_dir(repo.join("applets"))
        .ok()?
        .flatten()
        .collect();
    entries.sort_by_key(|e| e.path());
    for entry in entries {
        let Ok(text) = std::fs::read_to_string(entry.path().join("manifest.toml")) else {
            continue;
        };
        let Ok(manifest) = text.parse::<vrx_protocol::Manifest>() else {
            continue; // the crate tests and vrx build name a bad manifest
        };
        let place = vrx_protocol::unit::Place::builtin(
            format!("/system/defaults/{}", manifest.applet.id),
            Some("/bundle".to_owned()),
        );
        if let Err(err) = vrx_protocol::unit::dropin(&manifest, &place, &grants) {
            return Some(format!("{err}: choose another id or fix the grant"));
        }
    }
    None
}

/// `cargo test` for the picked crates on Linux, in the official Rust image
/// at the host's rustc version, under podman or docker (whichever the vrx
/// build uses; on a Mac its VM is the Linux). The gate refuses to pass
/// silently without one.
fn linux_tests(repo: &std::path::Path, picked: &[&str]) -> bool {
    let engine = ["podman", "docker"].into_iter().find(|e| {
        Command::new(e)
            .arg("--version")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .is_ok_and(|s| s.success())
    });
    let Some(engine) = engine else {
        eprintln!("gate: FAILED — the Linux tests need podman or docker (the vrx build's container engine)");
        return false;
    };
    let version = Command::new("rustc")
        .arg("--version")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .and_then(|v| v.split_whitespace().nth(1).map(str::to_owned))
        .unwrap_or_else(|| "latest".into());
    let mount = format!("{}:/src", repo.display());
    let mut args: Vec<String> = [
        "run",
        "--rm",
        "-v",
        &mount,
        "-v",
        "vrx-cargo-target:/target",
        "-w",
        "/src",
        "-e",
        "CARGO_TARGET_DIR=/target",
    ]
    .iter()
    .map(|s| (*s).to_owned())
    .collect();
    args.push(format!("rust:{version}"));
    args.extend(["cargo", "test", "-q"].map(str::to_owned));
    args.extend(picked.iter().map(|s| (*s).to_owned()));
    println!("gate: cargo test on Linux ({engine}, rust:{version})");
    let ok = Command::new(engine)
        .args(&args)
        .status()
        .map(|s| s.success())
        .unwrap_or(false);
    if !ok {
        eprintln!("gate: FAILED at the Linux tests");
    }
    ok
}

fn run(program: &str, args: &[&str]) -> bool {
    println!("gate: {program} {}", args.join(" "));
    let ok = Command::new(program)
        .args(args)
        .status()
        .map(|s| s.success())
        .unwrap_or(false);
    if !ok {
        eprintln!("gate: FAILED at {program} {}", args.join(" "));
    }
    ok
}

/// The repository root (xtask lives at rust/xtask).
fn repo_root() -> std::path::PathBuf {
    let up = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    up.canonicalize().unwrap_or(up)
}

fn gate(all: bool) -> ExitCode {
    let repo = repo_root();
    let stamps = impact::Stamps::new(&repo, all);

    // the workspace: each crate checked when it, a crate it builds
    // against, the lockfile or the workspace manifest changed
    let mut stale = Vec::new();
    for (dir, name) in workspace_crates(&repo) {
        let mut inputs = vec![repo.join("Cargo.lock"), repo.join("Cargo.toml")];
        // the crate, what it builds against, and what any of them reads
        // with include_str! (rust/sdk's display table, rust/protocol's
        // grants.conf)
        for dep in impact::path_deps(&dir).into_iter().chain([dir.clone()]) {
            inputs.extend(impact::included_files(&dep));
            inputs.push(dep);
        }
        let hash = impact::hash(&repo, &inputs);
        let check = format!("crate {name}");
        if stamps.fresh(&check, hash) {
            println!("gate: {name}: unchanged since it passed");
        } else {
            stale.push((name, check, hash));
        }
    }
    if !stale.is_empty() {
        let mut picked: Vec<&str> = Vec::new();
        for (name, _, _) in &stale {
            picked.extend(["-p", name.as_str()]);
        }
        let fmt = [&["fmt", "--check"][..], &picked].concat();
        let clippy = [
            &["clippy"][..],
            &picked,
            &["--all-targets", "--", "-D", "warnings"],
        ]
        .concat();
        let test = [&["test"][..], &picked].concat();
        if !run("cargo", &fmt) || !run("cargo", &clippy) || !run("cargo", &test) {
            return ExitCode::FAILURE;
        }
        // the code under cfg(target_os = "linux") (descriptor passing, the
        // buffer queue, the USB watcher) is tested where it runs
        if !linux_tests(&repo, &picked) {
            return ExitCode::FAILURE;
        }
        for (_, check, hash) in &stale {
            stamps.record(check, *hash);
        }
    }

    // G036 (plan 0013 D16): every doc AGENTS.md names exists
    println!("gate: the docs AGENTS.md names exist");
    match docs::missing(&repo) {
        Ok(missing) if missing.is_empty() => {}
        Ok(missing) => {
            eprintln!(
                "gate: FAILED (G036) — AGENTS.md names docs that do not exist: {}",
                missing.join(", ")
            );
            return ExitCode::FAILURE;
        }
        Err(err) => {
            eprintln!("gate: FAILED (G036): {err}");
            return ExitCode::FAILURE;
        }
    }

    // the layer's crates manifest must match Cargo.lock, or the Yocto
    // build fails offline (--frozen) far from the change that caused it
    println!("gate: crates manifest matches Cargo.lock");
    match crates_inc::is_current() {
        Ok(true) => {}
        Ok(false) => {
            eprintln!("gate: FAILED — layer/recipes-core/vrx-workspace-crates.inc is stale: run `cargo xtask crates-inc`");
            return ExitCode::FAILURE;
        }
        Err(err) => {
            eprintln!("gate: FAILED reading the crates manifest: {err}");
            return ExitCode::FAILURE;
        }
    }

    // G018 (plan 0009 D1): the vendored UI standard hashes to its pin, and
    // vrx_kit's generated tables are what it produces
    println!("gate: the UI standard's pin and vrx_kit's tables");
    match ui_standard::is_current(&repo) {
        Ok(true) => {}
        Ok(false) => {
            eprintln!("gate: FAILED — flutter/vrx_kit/lib/src/ui_standard.g.dart is stale: run `cargo xtask ui-standard`");
            return ExitCode::FAILURE;
        }
        Err(err) => {
            eprintln!("gate: FAILED (G018): {err}");
            return ExitCode::FAILURE;
        }
    }

    // the responsiveness scan and the Flutter half (plan 0008 D19)
    println!("gate: responsiveness scan (applet and SDK sources)");
    // the trees whose code runs inside applets: the Flutter SDK, the Rust
    // SDK and every applet
    let mut roots = vec![repo.join("flutter/vrx_kit/lib"), repo.join("rust/sdk/src")];
    if let Ok(entries) = std::fs::read_dir(repo.join("applets")) {
        for entry in entries.flatten() {
            roots.extend(vrx_protocol::scan::applet_roots(&entry.path()));
        }
    }
    let found = vrx_protocol::scan::scan(&roots);
    for v in &found {
        let shown = v.path.strip_prefix(&repo).unwrap_or(&v.path).display();
        eprintln!(
            "{shown}:{}: `{}`: {}{}",
            v.line,
            v.needle,
            v.why,
            v.remedy()
        );
    }
    if !found.is_empty() {
        eprintln!("gate: FAILED at the responsiveness scan");
        return ExitCode::FAILURE;
    }
    // G022 (plan 0011 D9): what applets send by name is what they declare,
    // and what they push by name exists
    println!("gate: intents sent are declared; pushes name real applets and routes");
    let found = sent_literals_gate(&repo);
    for f in &found {
        eprintln!("{f}");
    }
    if !found.is_empty() {
        eprintln!("gate: FAILED at the declared-intents check (G022)");
        return ExitCode::FAILURE;
    }
    // an applet runs as user vrx-<id> (plan 0008 D1); a grant is a group
    // vrx-…: an id whose user is a grant's group would hold that grant by
    // name (the image build refuses it in do_install; caught here first)
    println!("gate: applet users are not grant groups");
    if let Some(clash) = applet_user_clash(&repo) {
        eprintln!("gate: FAILED — {clash}");
        return ExitCode::FAILURE;
    }
    // the layout tests measure text in the image's fonts (vrx_check)
    println!("gate: the image's fonts for the layout check");
    if let Err(err) = fonts::ensure() {
        eprintln!("gate: FAILED fetching the fonts: {err}");
        return ExitCode::FAILURE;
    }
    if !flutter_gate(&repo, &stamps) {
        return ExitCode::FAILURE;
    }
    if !rust_applets_gate(&repo, &stamps) {
        return ExitCode::FAILURE;
    }

    // cargo-deny is a gate step when the binary is available; the gate
    // refuses to silently pass without it.
    match Command::new("cargo")
        .args(["deny", "--version"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
    {
        Ok(status) if status.success() => {
            // what crates and licences the lockfile pins, judged by deny.toml
            let inputs = [
                repo.join("Cargo.lock"),
                repo.join("deny.toml"),
                repo.join("Cargo.toml"),
            ];
            let hash = impact::hash(&repo, &inputs);
            if stamps.fresh("deny", hash) {
                println!("gate: cargo deny: the lockfile is unchanged since it passed");
            } else if run("cargo", &["deny", "check", "bans", "licenses", "sources"]) {
                stamps.record("deny", hash);
            } else {
                return ExitCode::FAILURE;
            }
        }
        _ => {
            eprintln!(
                "gate: FAILED — cargo-deny is not installed (cargo install cargo-deny)"
            );
            return ExitCode::FAILURE;
        }
    }

    println!("gate: green");
    ExitCode::SUCCESS
}
