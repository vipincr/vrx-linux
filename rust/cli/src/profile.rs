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

use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode, Stdio};

const SSH_OPTS: &[&str] = &[
    "-o",
    "StrictHostKeyChecking=no",
    "-o",
    "UserKnownHostsFile=/dev/null",
    "-o",
    "LogLevel=ERROR",
    "-o",
    "ConnectTimeout=8",
];
const CONFIGS: &[&str] = &["frames", "cpu", "memory", "io", "full"];

/// The value after `flag`, if given.
pub fn flag<'a>(args: &'a [String], flag: &str) -> Option<&'a str> {
    args.windows(2)
        .find(|w| w[0] == flag)
        .map(|w| w[1].as_str())
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
            (name.ends_with(".pftrace")).then(|| (name.to_owned(), kb))
        })
        .collect()
}

fn pull(host: &str, out: &Path) -> Result<Vec<PathBuf>, String> {
    std::fs::create_dir_all(out).map_err(|e| format!("{}: {e}", out.display()))?;
    let mut got = Vec::new();
    for (name, _) in parse_list(&on_board(host, "vrx-profile list")?) {
        let dest = out.join(&name);
        let file = std::fs::File::create(&dest)
            .map_err(|e| format!("{}: {e}", dest.display()))?;
        // `take` prints the trace and deletes it only after a whole copy
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
        got.push(dest);
    }
    Ok(got)
}

pub fn run(args: &[String]) -> ExitCode {
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
        _ => Err("on|off|status|stats|capture <config> [--for s]|pull [--out dir], with --host <board>".to_owned()),
    };
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
    fn only_traces_are_pulled() {
        let listed = "20261014T100000Z-frames.pftrace 2048\nquota-note 1\n20261014T100100Z-cpu.pftrace 30000\n";
        assert_eq!(
            parse_list(listed),
            vec![
                ("20261014T100000Z-frames.pftrace".to_owned(), 2048),
                ("20261014T100100Z-cpu.pftrace".to_owned(), 30000)
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
