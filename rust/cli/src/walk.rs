// `vrx walk`: scripted paths through the UI, measured (plan 0014 D9,
// D11). The walk file's format and checks are vrx-protocol's (walk.rs);
// the board plays it with `vrx-walk` (meta-vrx-profiling); this side
// copies it over, takes the results off the store and judges them.
//
//   vrx walk plan <file.walk>
//   vrx walk run <file.walk> --host <board> [--out <dir>] [--scanout <scanout.py>]
//   vrx walk summary <run-dir>
//   vrx walk check <run-dir>
//
// A run lands in <out>/<walk>/<stamp>/ (out defaults to walks/): the
// trace, the board's result file, the screenshots and summary.json.

use std::collections::BTreeMap;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode, Stdio};

use vrx_protocol::walk::{judge, Budgets, Summary, Walk};

use crate::profile::{flag, on_board, summarize, summary_lines, take, SSH_OPTS};

/// vrx-walk's exit when the board is unfit to measure (governor,
/// throttling): the run is repeated once after a pause.
const UNFIT: i32 = 3;

fn read_walk(file: &Path) -> Result<Walk, String> {
    let text =
        std::fs::read_to_string(file).map_err(|e| format!("{}: {e}", file.display()))?;
    Walk::parse(&text).map_err(|e| format!("{}: {e}", file.display()))
}

/// Pack files under `dir` (relative paths) and unpack them on the board
/// in `dest`.
fn send(host: &str, dir: &Path, files: &[&str], dest: &str) -> Result<(), String> {
    let tar = Command::new("tar")
        .arg("-C")
        .arg(dir)
        .arg("-cf")
        .arg("-")
        .args(files)
        .stdout(Stdio::piped())
        .spawn()
        .map_err(|e| format!("tar: {e}"))?;
    let ok = Command::new("ssh")
        .args(SSH_OPTS)
        .arg(format!("root@{host}"))
        .arg(format!("tar -C {dest} -xf -"))
        .stdin(tar.stdout.ok_or("tar gave no output")?)
        .status()
        .map_err(|e| format!("ssh: {e}"))?
        .success();
    ok.then_some(())
        .ok_or_else(|| format!("copying to {host}:{dest} failed"))
}

/// Play the walk once on the board: its exit code and the files it left
/// in the store.
fn play(
    host: &str,
    dest: &str,
    file: &str,
    scanout: bool,
) -> Result<(i32, Vec<String>), String> {
    let mut cmd = format!("vrx-walk run {dest}/{file}");
    if scanout {
        cmd += &format!(" --scanout {dest}/scanout.py");
    }
    let out = Command::new("ssh")
        .args(SSH_OPTS)
        .arg(format!("root@{host}"))
        .arg(cmd)
        .stderr(Stdio::inherit())
        .output()
        .map_err(|e| format!("ssh: {e}"))?;
    let files = String::from_utf8_lossy(&out.stdout)
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.contains('/'))
        .map(str::to_owned)
        .collect();
    Ok((out.status.code().unwrap_or(1), files))
}

fn run(args: &[String]) -> Result<ExitCode, String> {
    let file = PathBuf::from(args.get(1).ok_or("run <file.walk> --host <board>")?);
    let walk = read_walk(&file)?;
    let host = flag(args, "--host").ok_or("--host <board> is needed")?;
    let dir = file
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    let name = file
        .file_name()
        .ok_or("no file name")?
        .to_string_lossy()
        .into_owned();
    let scanout = flag(args, "--scanout")
        .map(PathBuf::from)
        .unwrap_or_else(|| dir.join("../bench/scanout.py"));

    let dest = on_board(host, "mktemp -d /run/vrx-walk.XXXXXX")?
        .trim()
        .to_owned();
    if !dest.starts_with("/run/vrx-walk.") {
        return Err(format!("the board made no work directory ({dest:?})"));
    }
    let mut files: Vec<&str> = vec![&name];
    files.extend(walk.setup.fixture.iter().map(|f| f.from.as_str()));
    send(host, dir, &files, &dest)?;
    let has_scanout = scanout.is_file();
    if has_scanout {
        send(
            host,
            scanout.parent().unwrap_or(Path::new(".")),
            &["scanout.py"],
            &dest,
        )?;
    } else {
        eprintln!(
            "vrx walk: no {} here; the run takes no screenshots",
            scanout.display()
        );
    }

    let (mut code, mut made) = play(host, &dest, &name, has_scanout)?;
    if code == UNFIT {
        eprintln!("vrx walk: the board was unfit to measure; once more in 60 s");
        let out =
            flag(args, "--out").map_or_else(|| PathBuf::from("walks"), PathBuf::from);
        // keep what the refused run left (its result says why), then retry
        for f in &made {
            take(host, f, &out.join(&walk.name).join("refused"))?;
        }
        std::thread::sleep(std::time::Duration::from_secs(60));
        (code, made) = play(host, &dest, &name, has_scanout)?;
    }
    let _ = on_board(host, &format!("rm -r {dest}"));

    let stamp = made
        .iter()
        .find_map(|f| f.split_once("-walk-").map(|(s, _)| s.to_owned()))
        .unwrap_or_else(|| "unfinished".to_owned());
    let out = flag(args, "--out")
        .map_or_else(|| PathBuf::from("walks"), PathBuf::from)
        .join(&walk.name)
        .join(stamp);
    for f in &made {
        take(host, f, &out)?;
    }
    println!("{}", out.display());
    if code != 0 {
        eprintln!("vrx walk: the walk did not complete (vrx-walk exited {code}); see the result file");
        return Ok(ExitCode::FAILURE);
    }
    match summary(&out) {
        Ok(s) => {
            print!("{}", summary_lines(&s));
            check(&out)
        }
        Err(e) => {
            eprintln!("vrx walk: no summary: {e}");
            Ok(ExitCode::SUCCESS)
        }
    }
}

fn find(run: &Path, pick: impl Fn(&str) -> bool) -> Option<PathBuf> {
    let mut found: Vec<PathBuf> = std::fs::read_dir(run)
        .ok()?
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.file_name().is_some_and(|n| pick(&n.to_string_lossy())))
        .collect();
    found.sort();
    found.pop()
}

/// The run's summary: summary.json, else computed from its trace and
/// saved there.
fn summary(run: &Path) -> Result<Summary, String> {
    let saved = run.join("summary.json");
    if let Ok(text) = std::fs::read_to_string(&saved) {
        return serde_json::from_str(&text)
            .map_err(|e| format!("{}: {e}", saved.display()));
    }
    let trace = find(run, |n| n.ends_with(".pftrace"))
        .ok_or_else(|| format!("no trace in {}", run.display()))?;
    let s = summarize(&trace)?;
    let json = serde_json::to_string_pretty(&s).map_err(|e| e.to_string())?;
    std::fs::write(&saved, json).map_err(|e| format!("{}: {e}", saved.display()))?;
    Ok(s)
}

/// The board's result file: the applets' budgets and the walk's own.
#[derive(serde::Deserialize)]
struct Record {
    walk: Walk,
    budgets: BTreeMap<String, Budgets>,
}

/// Judge a run; FAILURE when a measured metric is over its budget, each
/// line naming the applet, the metric and the step where it was worst.
fn check(run: &Path) -> Result<ExitCode, String> {
    let result = find(run, |n| n.contains("-walk-") && n.ends_with(".json"))
        .ok_or_else(|| format!("no result file in {}", run.display()))?;
    let text = std::fs::read_to_string(&result)
        .map_err(|e| format!("{}: {e}", result.display()))?;
    let record: Record =
        serde_json::from_str(&text).map_err(|e| format!("{}: {e}", result.display()))?;
    let verdicts = judge(&summary(run)?, &record.budgets, &record.walk.budgets);
    let mut out = std::io::stdout().lock();
    for v in &verdicts {
        let _ = writeln!(out, "{}", v.line());
    }
    let over = verdicts.iter().filter(|v| v.over()).count();
    if over > 0 {
        let _ = writeln!(
            out,
            "vrx walk: {} over budget in {}",
            over, record.walk.name
        );
        return Ok(ExitCode::FAILURE);
    }
    if verdicts.is_empty() {
        let _ = writeln!(
            out,
            "vrx walk: no budgets set for what {} measured",
            record.walk.name
        );
    }
    Ok(ExitCode::SUCCESS)
}

pub fn run_cli(args: &[String]) -> ExitCode {
    let result = match args.first().map(String::as_str) {
        Some("plan") => args
            .get(1)
            .ok_or_else(|| "plan <file.walk>".to_owned())
            .and_then(|f| read_walk(Path::new(f)))
            .map(|w| {
                println!("{}", w.plan().join("\n"));
                ExitCode::SUCCESS
            }),
        Some("run") => run(args),
        Some("summary") => args
            .get(1)
            .ok_or_else(|| "summary <run-dir>".to_owned())
            .and_then(|d| summary(Path::new(d)))
            .map(|s| {
                print!("{}", summary_lines(&s));
                ExitCode::SUCCESS
            }),
        Some("check") => args
            .get(1)
            .ok_or_else(|| "check <run-dir>".to_owned())
            .and_then(|d| check(Path::new(d))),
        _ => Err("plan <file> | run <file> --host <board> [--out dir] [--scanout f] | summary <run> | check <run>".to_owned()),
    };
    result.unwrap_or_else(|e| {
        eprintln!("vrx walk: {e}");
        ExitCode::FAILURE
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every walk in tools/walks reads and plans: a walk that cannot
    /// parse fails here, not on the board.
    #[test]
    fn the_walks_in_the_tree_read() {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tools/walks");
        let mut n = 0;
        for e in std::fs::read_dir(&dir).unwrap().flatten() {
            let p = e.path();
            if p.extension().is_some_and(|x| x == "walk") {
                let w = read_walk(&p).unwrap();
                for f in &w.setup.fixture {
                    assert!(
                        dir.join(&f.from).is_file(),
                        "{}: fixture {} is missing",
                        p.display(),
                        f.from
                    );
                }
                n += 1;
            }
        }
        assert!(n >= 6, "the starter walks and the latency walk");
    }

    #[test]
    fn a_run_is_judged_from_its_files() {
        let tmp = tempfile::tempdir().unwrap();
        let walk = "name = \"x\"\nabout = \"\"\n[[step]]\naction = \"home\"\n";
        let record = serde_json::json!({
            "walk": Walk::parse(walk).unwrap(),
            "budgets": { "clock": { "peak_mb": 40.0 } },
        });
        std::fs::write(
            tmp.path().join("20261014T1Z-walk-x.json"),
            record.to_string(),
        )
        .unwrap();
        let s = Summary {
            rows: vec![vrx_protocol::walk::SummaryRow {
                applet: "clock".into(),
                metric: "peak_mb".into(),
                step: String::new(),
                value: 44.0,
            }],
        };
        std::fs::write(
            tmp.path().join("summary.json"),
            serde_json::to_string(&s).unwrap(),
        )
        .unwrap();
        assert_eq!(check(tmp.path()).unwrap(), ExitCode::FAILURE);
    }
}
