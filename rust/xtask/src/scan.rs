// The responsiveness scan (plan 0008 D19): source forms that block an
// applet's event loop or frame, banned by file and line. A line that
// genuinely needs one says so with `vrx-allow: <reason>` on the line or
// the line above; a bare marker without a reason does not count.

use std::path::{Path, PathBuf};

/// One banned form: where it applies, what it matches, why it is banned.
struct Rule {
    /// File extension the rule reads.
    ext: &'static str,
    /// Substring that marks a violation.
    needle: &'static str,
    why: &'static str,
}

const RULES: &[Rule] = &[
    Rule {
        ext: "dart",
        needle: "Sync(",
        why: "a synchronous dart:io call blocks the isolate that builds frames",
    },
    Rule {
        ext: "dart",
        needle: "sleep(",
        why: "sleep blocks the isolate that builds frames",
    },
    Rule {
        ext: "dart",
        needle: "Navigator.",
        why: "navigation is vrxhost's back trail (Nav), never Navigator",
    },
    Rule {
        ext: "dart",
        needle: "print(",
        why: "stdout is not a log: debugPrint",
    },
    Rule {
        ext: "rs",
        needle: "thread::sleep(",
        why: "sleeping stalls the applet's loop and its watchdog",
    },
];

/// The trees whose code runs inside applets: the Flutter SDK, the Rust
/// SDK and every applet.
fn roots(repo: &Path) -> Vec<PathBuf> {
    let mut roots = vec![repo.join("flutter/vrx_kit/lib"), repo.join("rust/sdk/src")];
    if let Ok(entries) = std::fs::read_dir(repo.join("applets")) {
        for entry in entries.flatten() {
            for sub in ["lib", "src"] {
                let dir = entry.path().join(sub);
                if dir.is_dir() {
                    roots.push(dir);
                }
            }
        }
    }
    roots
}

fn files(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            files(&path, out);
        } else {
            out.push(path);
        }
    }
}

fn allowed(line: &str) -> bool {
    line.split_once("vrx-allow:")
        .is_some_and(|(_, reason)| !reason.trim().is_empty())
}

/// An emoji: the image ships no emoji font, so one renders as a
/// missing-glyph box (bench 2026-10-13: the Wi-Fi lock). Symbols come
/// from the icon font (VrxSymbols) instead.
fn is_emoji(c: char) -> bool {
    matches!(u32::from(c), 0x1F300..=0x1FAFF | 0x2600..=0x27BF | 0x1F000..=0x1F2FF)
}

/// Violations in one file's text: (line number, rule).
fn violations(ext: &str, text: &str) -> Vec<(usize, &'static str, &'static str)> {
    let lines: Vec<&str> = text.lines().collect();
    let mut found = Vec::new();
    for (i, line) in lines.iter().enumerate() {
        let code = line.split("//").next().unwrap_or("");
        if ext == "dart" && code.chars().any(is_emoji) {
            found.push((
                i + 1,
                "emoji",
                "the image ships no emoji font: use a VrxSymbols glyph",
            ));
        }
        for rule in RULES.iter().filter(|r| r.ext == ext) {
            if !code.contains(rule.needle) {
                continue;
            }
            // debugPrint( is the sanctioned form of print(
            if rule.needle == "print("
                && code.contains("debugPrint(")
                && !code.replace("debugPrint(", "").contains("print(")
            {
                continue;
            }
            let above = i
                .checked_sub(1)
                .and_then(|j| lines.get(j))
                .copied()
                .unwrap_or("");
            if allowed(line) || allowed(above) {
                continue;
            }
            found.push((i + 1, rule.needle, rule.why));
        }
    }
    found
}

/// Scan the repo; print each violation; true when clean.
pub fn run(repo: &Path) -> bool {
    let mut all = Vec::new();
    for root in roots(repo) {
        files(&root, &mut all);
    }
    let mut clean = true;
    for path in all {
        let ext = path.extension().and_then(|e| e.to_str()).unwrap_or("");
        if ext != "dart" && ext != "rs" {
            continue;
        }
        let Ok(text) = std::fs::read_to_string(&path) else {
            continue;
        };
        // a Rust file's test module is host code, not applet code
        let body = if ext == "rs" {
            text.split("#[cfg(test)]").next().unwrap_or("").to_owned()
        } else {
            text
        };
        for (line, needle, why) in violations(ext, &body) {
            clean = false;
            let shown = path.strip_prefix(repo).unwrap_or(&path).display();
            eprintln!("{shown}:{line}: `{needle}`: {why} (or mark the line `vrx-allow: <reason>`)");
        }
    }
    clean
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn banned_forms_are_found_and_reasoned_allows_pass() {
        let dart = "final x = File(p).readAsStringSync();\nsleep(d);\n// vrx-allow: startup probe, once\nfinal t = FileSystemEntity.typeSync(p);\nfinal u = typeSync(p); // vrx-allow:\ndebugPrint('ok');\nprint('no');\n";
        let found: Vec<usize> = violations("dart", dart).iter().map(|v| v.0).collect();
        // line 4 is allowed with a reason; line 5's bare marker is not
        assert_eq!(found, vec![1, 2, 5, 7]);
        assert_eq!(
            violations("dart", "final v = n.secured ? '\u{1F512}' : '';\n").len(),
            1
        );
        let rs = "fn f() { std::thread::sleep(d); }\n";
        assert_eq!(violations("rs", rs).len(), 1);
    }
}
