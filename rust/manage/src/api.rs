// The JSON API the page reads (evrx-rt docs/47-management-api.md):
// /api/status, the device's summary, and /api/log, the journal's last
// lines. Each reads its facts from Linux; a fact the board does not have
// is left out, never sent as a placeholder. The parsers are pure.

use std::path::Path;

use serde_json::{json, Map, Value};

fn read(root: &Path, path: &str) -> Option<String> {
    let text = std::fs::read_to_string(root.join(path.trim_start_matches('/'))).ok()?;
    let text = text
        .trim_matches(|c: char| c == '\0' || c.is_whitespace())
        .to_owned();
    (!text.is_empty()).then_some(text)
}

/// `KEY="value"` lines (os-release).
fn os_release(text: &str, key: &str) -> Option<String> {
    text.lines().find_map(|l| {
        let v = l.strip_prefix(key)?.strip_prefix('=')?;
        Some(v.trim_matches('"').to_owned())
    })
}

/// MemAvailable, in kB.
fn mem_available_kb(meminfo: &str) -> Option<u64> {
    meminfo.lines().find_map(|l| {
        l.strip_prefix("MemAvailable:")?
            .split_whitespace()
            .next()?
            .parse()
            .ok()
    })
}

/// `df -kP <dir>`: the total, in kB.
pub fn df_total_kb(df: &str) -> Option<u64> {
    df.lines().nth(1)?.split_whitespace().nth(1)?.parse().ok()
}

/// `df -kP <dir>`: what is free, in kB.
pub fn df_avail_kb(df: &str) -> Option<u64> {
    df.lines().nth(1)?.split_whitespace().nth(3)?.parse().ok()
}

/// `ip -o -4 addr show scope global`: "eth0 10.10.10.8" per link.
pub fn links(ip: &str) -> Vec<String> {
    ip.lines()
        .filter_map(|l| {
            let mut f = l.split_whitespace();
            let _index = f.next()?;
            let name = f.next()?;
            let _family = f.next()?;
            let addr = f.next()?.split('/').next()?;
            Some(format!("{name} {addr}"))
        })
        .collect()
}

/// The device's summary. `root` is `/` on the device (a fixture tree in
/// tests); `data_kb` and `links` come from df and ip.
pub fn status(
    root: &Path,
    hostname: &str,
    data_kb: Option<u64>,
    links: &[String],
) -> Value {
    let mut s = Map::new();
    if !hostname.is_empty() {
        s.insert("host".into(), json!(hostname));
        s.insert("hostname".into(), json!(format!("{hostname}.local")));
    }
    if let Some(model) = read(root, "/proc/device-tree/model") {
        s.insert("board".into(), json!(model));
    }
    if let Some(os) = read(root, "/etc/os-release") {
        if let Some(v) = os_release(&os, "VERSION") {
            s.insert("version".into(), json!(v));
        }
        if let Some(b) = os_release(&os, "BUILD_ID") {
            s.insert("built".into(), json!(b));
        }
    }
    // the SoC: the device tree's last compatible string ("brcm,bcm2711")
    if let Some(compat) = read(root, "/proc/device-tree/compatible") {
        if let Some(chip) = compat.split('\0').rfind(|c| !c.is_empty()) {
            s.insert(
                "chip".into(),
                json!(chip.split(',').next_back().unwrap_or(chip)),
            );
        }
    }
    let uptime = read(root, "/proc/uptime")
        .and_then(|u| {
            u.split_whitespace()
                .next()?
                .split('.')
                .next()?
                .parse::<u64>()
                .ok()
        })
        .unwrap_or(0);
    s.insert("uptime_s".into(), json!(uptime));
    if let Some(kb) = read(root, "/proc/meminfo")
        .as_deref()
        .and_then(mem_available_kb)
    {
        s.insert("memory".into(), json!({ "fast_free_kb": kb }));
    }
    if let Some(kb) = data_kb {
        s.insert("storage".into(), json!({ "fs_kb": kb }));
    }
    if !links.is_empty() {
        s.insert("network".into(), json!({ "link": links.join(", ") }));
    }
    Value::Object(s)
}

/// The log's levels, by syslog priority.
fn level(priority: u64) -> &'static str {
    match priority {
        0..=3 => "error",
        4 => "warn",
        5 | 6 => "info",
        _ => "debug",
    }
}

/// `journalctl -o json` lines, oldest first, each cut at 240 bytes.
pub fn log(journal: &str) -> Value {
    let lines: Vec<Value> = journal
        .lines()
        .filter_map(|l| serde_json::from_str::<Value>(l).ok())
        .map(|r| {
            let field =
                |k: &str| r.get(k).and_then(Value::as_str).unwrap_or("").to_owned();
            let mut text = field("MESSAGE");
            if text.len() > 240 {
                let mut cut = 240;
                while !text.is_char_boundary(cut) {
                    cut -= 1;
                }
                text.truncate(cut);
            }
            let t_ms = field("__MONOTONIC_TIMESTAMP").parse::<u64>().unwrap_or(0) / 1000;
            let priority = field("PRIORITY").parse::<u64>().unwrap_or(6);
            json!({
                "t_ms": t_ms,
                "level": level(priority),
                "source": field("SYSLOG_IDENTIFIER"),
                "text": text,
            })
        })
        .collect();
    json!({ "lines": lines })
}

/// `lines=N` from a query: 30 by default, at most 100.
pub fn lines_wanted(query: &str) -> usize {
    query
        .split('&')
        .find_map(|kv| kv.strip_prefix("lines=")?.parse::<usize>().ok())
        .unwrap_or(30)
        .clamp(1, 100)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn status_reads_the_board_and_leaves_out_what_it_lacks() {
        let root =
            std::env::temp_dir().join(format!("vrx-manage-{}", std::process::id()));
        std::fs::create_dir_all(root.join("proc/device-tree")).unwrap();
        std::fs::create_dir_all(root.join("etc")).unwrap();
        std::fs::write(
            root.join("proc/device-tree/model"),
            "Raspberry Pi Compute Module 4 Rev 1.1\0",
        )
        .unwrap();
        std::fs::write(
            root.join("proc/device-tree/compatible"),
            "raspberrypi,4-compute-module\0brcm,bcm2711\0",
        )
        .unwrap();
        std::fs::write(
            root.join("etc/os-release"),
            "ID=vrx\nVERSION=\"0.1.0082 (cm4-bcm2711)\"\n",
        )
        .unwrap();
        std::fs::write(root.join("proc/uptime"), "412.77 1000.00\n").unwrap();
        std::fs::write(
            root.join("proc/meminfo"),
            "MemTotal: 1891000 kB\nMemAvailable:    1203456 kB\n",
        )
        .unwrap();
        let s = status(&root, "gg", Some(13_421_772), &["eth0 10.10.10.8".into()]);
        assert_eq!(s["host"], "gg");
        assert_eq!(s["hostname"], "gg.local");
        assert_eq!(s["board"], "Raspberry Pi Compute Module 4 Rev 1.1");
        assert_eq!(s["version"], "0.1.0082 (cm4-bcm2711)");
        assert_eq!(s["chip"], "bcm2711");
        assert_eq!(s["uptime_s"], 412);
        assert_eq!(s["memory"]["fast_free_kb"], 1_203_456);
        assert_eq!(s["storage"]["fs_kb"], 13_421_772);
        assert_eq!(s["network"]["link"], "eth0 10.10.10.8");
        assert!(
            s.get("built").is_none()
                && s.get("battery").is_none()
                && s.get("wifi").is_none()
        );
        let bare = status(&root.join("nothing"), "", None, &[]);
        assert_eq!(bare, json!({ "uptime_s": 0 }));
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn df_and_ip_parse() {
        let df = "Filesystem     1024-blocks    Used Available Capacity Mounted on\n/dev/mmcblk0p3    13421772  322000  12400000       3% /data\n";
        assert_eq!(df_total_kb(df), Some(13_421_772));
        assert_eq!(df_avail_kb(df), Some(12_400_000));
        let ip = "2: eth0    inet 10.10.10.8/24 brd 10.10.10.255 scope global eth0\\       valid_lft forever\n3: wlan0    inet 192.168.1.20/24 scope global dynamic wlan0\n";
        assert_eq!(links(ip), vec!["eth0 10.10.10.8", "wlan0 192.168.1.20"]);
    }

    #[test]
    fn the_log_reads_journal_json_with_levels_and_a_cut() {
        let long = "x".repeat(300);
        let journal = format!(
            "{{\"__MONOTONIC_TIMESTAMP\":\"5121000\",\"PRIORITY\":\"4\",\"SYSLOG_IDENTIFIER\":\"connmand\",\"MESSAGE\":\"eth0 up\"}}\nnot json\n{{\"MESSAGE\":\"{long}\",\"PRIORITY\":\"2\"}}\n"
        );
        let l = log(&journal);
        let lines = l["lines"].as_array().unwrap();
        assert_eq!(lines.len(), 2);
        assert_eq!(
            lines[0],
            json!({ "t_ms": 5121, "level": "warn", "source": "connmand", "text": "eth0 up" })
        );
        assert_eq!(lines[1]["level"], "error");
        assert_eq!(lines[1]["text"].as_str().unwrap().len(), 240);
    }

    #[test]
    fn lines_default_to_30_and_stop_at_100() {
        assert_eq!(lines_wanted(""), 30);
        assert_eq!(lines_wanted("lines=5"), 5);
        assert_eq!(lines_wanted("a=1&lines=500"), 100);
        assert_eq!(lines_wanted("lines=0"), 1);
    }
}
