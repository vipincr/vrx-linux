// `vrx profile`: the profiler's one interface, on the workstation (plan
// 0014 D12). It drives the board over ssh: the switch through vrxhost's
// io.vrx.Host.Profiling (varlinkctl), captures through the board's
// vrx-profile (Perfetto's tracebox with vrx-traced's configs, under the
// trace store's quota), and pulls traces off the device, deleting each
// one there once it is copied (the owner, 2026-10-14).
//
//   vrx profile on|off|status --host <board>
//   vrx profile capture <frames|cpu|memory|io|full> [--for <seconds>] --host <board>
//   vrx profile stats --host <board>
//   vrx profile pull --host <board> [--out <dir>]
//   vrx profile summary <trace>        trace_processor and the summary spec
//   vrx profile open <trace>           the Perfetto UI on a local trace

use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode, Stdio};

pub const SSH_OPTS: &[&str] = &[
    "-o",
    // SEC-04 (review 2026-10-17): the board's key is taken the first
    // time and checked after — a changed key refuses instead of blindly
    // trusting whatever answers on the bench LAN
    "StrictHostKeyChecking=accept-new",
    "-o",
    "LogLevel=ERROR",
    "-o",
    "ConnectTimeout=8",
];
use vrx_protocol::walk::{Summary, CAPTURE_CONFIGS as CONFIGS};

/// The summary spec (plan 0014 D11), built in so the CLI needs no
/// checkout to find it.
const SPEC: &str = include_str!("../../../tools/profile/summary/vrx.pbtx");

/// The value after `flag`, if given: the one flag reader (crate::flags).
pub fn flag<'a>(args: &'a [String], flag: &str) -> Option<&'a str> {
    crate::flags::value(args, flag)
}

/// One command on the board, as root; its stdout, or why not.
pub fn on_board(host: &str, command: &str) -> Result<String, String> {
    let out = Command::new("ssh")
        .args(SSH_OPTS)
        .arg(format!("root@{host}"))
        .arg(command)
        .stderr(Stdio::inherit())
        .output()
        .map_err(|e| format!("ssh: {e}"))?;
    if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    } else {
        Err(format!("on {host}: `{command}` exited {}", out.status))
    }
}

/// The varlinkctl call for the switch.
pub fn switch_command(on: Option<bool>) -> String {
    let params = match on {
        Some(on) => format!("{{\"on\":{on}}}"),
        None => "{}".to_owned(),
    };
    format!("varlinkctl call /run/vrx/io.vrx.Host io.vrx.Host.Profiling '{params}'")
}

/// The capture command for a config and a duration.
pub fn capture_command(config: &str, seconds: u32) -> Result<String, String> {
    if !CONFIGS.contains(&config) {
        return Err(format!(
            "no config '{config}' (frames, cpu, memory, io, full)"
        ));
    }
    if seconds == 0 || seconds > 600 {
        return Err("a capture lasts 1 to 600 seconds".to_owned());
    }
    Ok(format!("vrx-profile capture {config} {seconds}"))
}

/// The traces `vrx-profile list` reports: name and size (KiB).
pub fn parse_list(text: &str) -> Vec<(String, u64)> {
    text.lines()
        .filter_map(|l| {
            let (name, kb) = l.split_once(' ')?;
            let kb = kb.trim().parse().ok()?;
            [".pftrace", ".json", ".png"]
                .iter()
                .any(|ext| name.ends_with(ext))
                .then(|| (name.to_owned(), kb))
        })
        .collect()
}

/// Copy one file off the store into `out`; `take` deletes it on the
/// device only after a whole copy (the owner, 2026-10-14).
pub fn take(host: &str, name: &str, out: &Path) -> Result<PathBuf, String> {
    std::fs::create_dir_all(out).map_err(|e| format!("{}: {e}", out.display()))?;
    let dest = out.join(name);
    let file =
        std::fs::File::create(&dest).map_err(|e| format!("{}: {e}", dest.display()))?;
    let status = Command::new("ssh")
        .args(SSH_OPTS)
        .arg(format!("root@{host}"))
        .arg(format!("vrx-profile take {name}"))
        .stdout(file)
        .status()
        .map_err(|e| format!("ssh: {e}"))?;
    if !status.success() {
        let _ = std::fs::remove_file(&dest);
        return Err(format!("taking {name} failed; it stays on the device"));
    }
    Ok(dest)
}

fn pull(host: &str, out: &Path) -> Result<Vec<PathBuf>, String> {
    parse_list(&on_board(host, "vrx-profile list")?)
        .into_iter()
        .map(|(name, _)| {
            // CON-05 (review 2026-10-17): the name came over ssh from
            // the board's reply; a plain base name only, as `vrx walk
            // run` already demands — a reply naming ../x cannot write
            // outside out
            if name.split('/').count() != 1 || name.starts_with('.') {
                return Err(format!(
                    "the board named a profile {name:?}, which is not a plain file name"
                ));
            }
            take(host, &name, out)
        })
        .collect()
}

/// trace_processor_shell: $VRX_TRACE_PROCESSOR, else on the PATH (the
/// prebuilt from Perfetto's release, mac-arm64.zip or linux-*.zip).
fn trace_processor() -> String {
    std::env::var("VRX_TRACE_PROCESSOR")
        .unwrap_or_else(|_| "trace_processor_shell".to_owned())
}

/// A trace's summary through the spec (trace_processor 51.2's flags).
pub fn summarize(trace: &Path) -> Result<Summary, String> {
    let spec =
        std::env::temp_dir().join(format!("vrx-summary-{}.pbtx", std::process::id()));
    std::fs::write(&spec, SPEC).map_err(|e| format!("{}: {e}", spec.display()))?;
    let out = Command::new(trace_processor())
        .arg("--summary")
        .arg("--summary-spec")
        .arg(&spec)
        .args(["--summary-metrics-v2", "all", "--summary-format", "text"])
        .arg(trace)
        .stderr(Stdio::piped())
        .output();
    let _ = std::fs::remove_file(&spec);
    let out = out.map_err(|e| {
        format!(
            "{}: {e} (get trace_processor_shell from Perfetto's release, or set VRX_TRACE_PROCESSOR)",
            trace_processor()
        )
    })?;
    if !out.status.success() {
        return Err(format!(
            "trace_processor failed on {}: {}",
            trace.display(),
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    Summary::from_textproto(&String::from_utf8_lossy(&out.stdout))
}

/// A summary as lines: the walk-wide rows, then the per-step ones.
pub fn summary_lines(s: &Summary) -> String {
    let mut rows: Vec<_> = s.rows.iter().collect();
    rows.sort_by_key(|r| (!r.step.is_empty(), r.applet.clone(), r.metric.clone()));
    rows.iter()
        .map(|r| {
            let at = if r.step.is_empty() {
                String::new()
            } else {
                format!(" at {}", r.step)
            };
            format!("{} {}{at}: {:.1}\n", r.applet, r.metric, r.value)
        })
        .collect()
}

/// Open a local trace in the Perfetto UI: trace_processor serves it on
/// 127.0.0.1:9001 and ui.perfetto.dev (a static page) loads it from there,
/// so the trace never leaves this machine. Perfetto's releases ship no UI
/// bundle to serve ourselves.
fn open(trace: &Path) -> Result<String, String> {
    let mut server = Command::new(trace_processor())
        .arg("--httpd")
        .arg(trace)
        .spawn()
        .map_err(|e| format!("{}: {e}", trace_processor()))?;
    let opener = if cfg!(target_os = "macos") {
        "open"
    } else {
        "xdg-open"
    };
    let _ = Command::new(opener).arg("https://ui.perfetto.dev").status();
    eprintln!(
        "vrx profile: serving {} on 127.0.0.1:9001 for the UI; Ctrl-C ends it",
        trace.display()
    );
    server.wait().map_err(|e| e.to_string())?;
    Ok(String::new())
}

pub fn run(args: &[String]) -> ExitCode {
    match args.first().map(String::as_str) {
        Some("summary") | Some("open") => {
            let Some(trace) = args.get(1).map(PathBuf::from) else {
                eprintln!("vrx profile: summary|open <trace>");
                return ExitCode::from(64);
            };
            let result = if args[0] == "open" {
                open(&trace)
            } else {
                summarize(&trace).map(|s| summary_lines(&s))
            };
            return finish(result);
        }
        _ => {}
    }
    let Some(host) = flag(args, "--host") else {
        eprintln!("vrx profile: --host <board> is needed");
        return ExitCode::from(64);
    };
    let result = match args.first().map(String::as_str) {
        Some("on") => on_board(host, &switch_command(Some(true))),
        Some("off") => on_board(host, &switch_command(Some(false))),
        Some("status") => on_board(host, &switch_command(None))
            .and_then(|s| Ok(s + &on_board(host, "vrx-profile status")?)),
        Some("stats") => on_board(
            host,
            "varlinkctl call /run/vrx/io.vrx.Host io.vrx.Host.ProfileStats '{}'",
        ),
        Some("capture") => {
            let config = args.get(1).map_or("", String::as_str);
            let seconds = flag(args, "--for")
                .map_or(Ok(20), |s| s.trim_end_matches('s').parse::<u32>())
                .unwrap_or(0);
            capture_command(config, seconds).and_then(|c| on_board(host, &c))
        }
        Some("pull") => {
            let out = flag(args, "--out").map_or_else(
                || PathBuf::from("profile").join(host),
                PathBuf::from,
            );
            pull(host, &out).map(|got| {
                got.iter()
                    .map(|p| format!("{}\n", p.display()))
                    .collect::<String>()
            })
        }
        _ => Err("on|off|status|stats|capture <config> [--for s]|pull [--out dir], with --host <board>; summary|open <trace>".to_owned()),
    };
    finish(result)
}

fn finish(result: Result<String, String>) -> ExitCode {
    match result {
        Ok(text) => {
            print!("{text}");
            ExitCode::SUCCESS
        }
        Err(err) => {
            eprintln!("vrx profile: {err}");
            ExitCode::FAILURE
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_switch_and_a_capture_are_one_command_each() {
        assert_eq!(
            switch_command(Some(true)),
            "varlinkctl call /run/vrx/io.vrx.Host io.vrx.Host.Profiling '{\"on\":true}'"
        );
        assert!(switch_command(None).ends_with("'{}'"));
        assert_eq!(
            capture_command("frames", 20).unwrap(),
            "vrx-profile capture frames 20"
        );
        assert!(
            capture_command("gpu", 20).is_err(),
            "only the configs that exist"
        );
        assert!(capture_command("cpu", 0).is_err());
        assert!(capture_command("cpu", 601).is_err());
    }

    #[test]
    fn only_the_stores_files_are_pulled() {
        let listed = "20261014T100000Z-frames.pftrace 2048\nquota-note 1\n20261014T100100Z-walk-drawer.json 4\n";
        assert_eq!(
            parse_list(listed),
            vec![
                ("20261014T100000Z-frames.pftrace".to_owned(), 2048),
                ("20261014T100100Z-walk-drawer.json".to_owned(), 4)
            ]
        );
    }

    #[test]
    fn a_flag_takes_the_next_word() {
        let args: Vec<String> = ["capture", "cpu", "--for", "30", "--host", "10.10.10.8"]
            .iter()
            .map(|s| (*s).to_owned())
            .collect();
        assert_eq!(flag(&args, "--host"), Some("10.10.10.8"));
        assert_eq!(flag(&args, "--for"), Some("30"));
        assert_eq!(flag(&args, "--out"), None);
    }
}
