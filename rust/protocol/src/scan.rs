// The responsiveness scan (plan 0008 D19): source forms that block an
// applet's event loop or frame, banned by file and line. A line that
// needs one says so with `vrx-allow: <reason>` on the line or the line
// above; a bare marker without a reason does not count. One
// implementation: `cargo xtask gate` scans the repo, `vrx build` the
// applet it builds.

use std::path::{Path, PathBuf};

/// One banned form: where it applies, what it matches, why it is banned.
struct Rule {
    /// File extension the rule reads.
    ext: &'static str,
    /// Substring that marks a violation.
    needle: &'static str,
    why: &'static str,
    /// Files (path endings) where the form is the job: the kit's theme
    /// may spell a colour, the boot reader a display class.
    except: &'static [&'static str],
}

/// Where colour is decided (plan 0009 D2, D7): the slots' home and the
/// generated tables.
const COLOUR_HOME: &[&str] = &[
    "vrx_kit/lib/src/theme.dart",
    "vrx_kit/lib/src/ui_standard.g.dart",
];

/// Where the display class is read (plan 0009 D4).
const CLASS_HOME: &[&str] = &[
    "vrx_kit/lib/src/theme.dart",
    "vrx_kit/lib/src/ui_standard.g.dart",
    "vrx_kit/lib/src/applet.dart",
];

const NO_COLOUR: &str =
    "colour is a slot (VrxTheme.of(context).<slot>, VrxHue, VrxSignal), never a literal";
const NO_CLASS: &str =
    "an applet never knows what panel it is on (plan 0009 D4): the kit answers by class";
const NO_SCREEN_POWER: &str = "G019: the screen's light and power are the compositor's alone (plan 0010 D1): brightness and the timeout are ScreenSettings, a hold is VrxKeepScreenOn";

/// G019: forms no `vrx-allow` excuses. An applet that switches the light
/// or the panel can leave a person with no screen to switch it back on.
const NEVER_ALLOWED: &[&str] = &["/sys/class/backlight", "bl_power", "dpms", "DPMS"];

const RULES: &[Rule] = &[
    Rule {
        ext: "dart",
        needle: "Sync(",
        why: "a synchronous dart:io call blocks the isolate that builds frames",
        except: &[],
    },
    Rule {
        ext: "dart",
        needle: "sleep(",
        why: "sleep blocks the isolate that builds frames",
        except: &[],
    },
    Rule {
        ext: "dart",
        needle: "Navigator.",
        why: "navigation is vrxhost's back trail (Nav), never Navigator",
        except: &[],
    },
    Rule {
        ext: "dart",
        needle: "print(",
        why: "stdout is not a log: debugPrint",
        except: &[],
    },
    Rule {
        ext: "dart",
        needle: "Color(0x",
        why: NO_COLOUR,
        except: COLOUR_HOME,
    },
    Rule {
        ext: "dart",
        needle: "Colors.",
        why: NO_COLOUR,
        except: COLOUR_HOME,
    },
    Rule {
        ext: "dart",
        needle: "VrxPalette",
        why: "VrxPalette is gone: the 32 slots are VrxColors (plan 0009 D2)",
        except: &[],
    },
    Rule {
        ext: "dart",
        needle: "epaper",
        why: NO_CLASS,
        except: CLASS_HOME,
    },
    Rule {
        ext: "dart",
        needle: "lcdColour",
        why: NO_CLASS,
        except: CLASS_HOME,
    },
    Rule {
        ext: "dart",
        needle: "display-class",
        why: NO_CLASS,
        except: CLASS_HOME,
    },
    Rule {
        ext: "dart",
        needle: "/sys/class/backlight",
        why: NO_SCREEN_POWER,
        except: &[],
    },
    Rule {
        ext: "dart",
        needle: "bl_power",
        why: NO_SCREEN_POWER,
        except: &[],
    },
    Rule {
        ext: "dart",
        needle: "dpms",
        why: NO_SCREEN_POWER,
        except: &[],
    },
    Rule {
        ext: "dart",
        needle: "DPMS",
        why: NO_SCREEN_POWER,
        except: &[],
    },
    Rule {
        ext: "rs",
        needle: "/sys/class/backlight",
        why: NO_SCREEN_POWER,
        except: &[],
    },
    Rule {
        ext: "rs",
        needle: "bl_power",
        why: NO_SCREEN_POWER,
        except: &[],
    },
    Rule {
        ext: "rs",
        needle: "dpms",
        why: NO_SCREEN_POWER,
        except: &[],
    },
    Rule {
        ext: "rs",
        needle: "DPMS",
        why: NO_SCREEN_POWER,
        except: &[],
    },
    Rule {
        ext: "rs",
        needle: "thread::sleep(",
        why: "sleeping stalls the applet's loop and its watchdog",
        except: &[],
    },
];

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
fn violations(
    path: &str,
    ext: &str,
    text: &str,
) -> Vec<(usize, &'static str, &'static str)> {
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
        for rule in RULES
            .iter()
            .filter(|r| r.ext == ext && !r.except.iter().any(|e| path.ends_with(e)))
        {
            if !code.contains(rule.needle) {
                continue;
            }
            // `Colors.` the class, not the end of a name (VrxColors.resolve);
            // and transparency is not a colour: nothing to resolve by scheme
            if rule.needle == "Colors." {
                let stray = code.replace("Colors.transparent", "");
                let real = stray.match_indices("Colors.").any(|(at, _)| {
                    !stray[..at]
                        .chars()
                        .next_back()
                        .is_some_and(|c| c.is_alphanumeric() || c == '_')
                });
                if !real {
                    continue;
                }
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
            if !NEVER_ALLOWED.contains(&rule.needle) && (allowed(line) || allowed(above))
            {
                continue;
            }
            found.push((i + 1, rule.needle, rule.why));
        }
    }
    found
}

/// One violation: where, what matched, and why it is banned.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Violation {
    pub path: PathBuf,
    pub line: usize,
    pub needle: &'static str,
    pub why: &'static str,
}

/// Scan every .dart and .rs file under [roots]. A Rust file's test module
/// is host code, not applet code, and is skipped.
pub fn scan(roots: &[PathBuf]) -> Vec<Violation> {
    let mut all = Vec::new();
    for root in roots {
        files(root, &mut all);
    }
    all.sort();
    let mut out = Vec::new();
    for path in all {
        let ext = path.extension().and_then(|e| e.to_str()).unwrap_or("");
        if ext != "dart" && ext != "rs" {
            continue;
        }
        let Ok(text) = std::fs::read_to_string(&path) else {
            continue;
        };
        let body = if ext == "rs" {
            text.split("#[cfg(test)]").next().unwrap_or("").to_owned()
        } else {
            text
        };
        let shown = path.to_string_lossy();
        for (line, needle, why) in violations(&shown, ext, &body) {
            out.push(Violation {
                path: path.clone(),
                line,
                needle,
                why,
            });
        }
    }
    out
}

/// An applet's own source trees: lib/ (Flutter) and src/ (Rust).
pub fn applet_roots(dir: &Path) -> Vec<PathBuf> {
    ["lib", "src"]
        .iter()
        .map(|s| dir.join(s))
        .filter(|d| d.is_dir())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn banned_forms_are_found_and_reasoned_allows_pass() {
        let dart = "final x = File(p).readAsStringSync();\nsleep(d);\n// vrx-allow: startup probe, once\nfinal t = FileSystemEntity.typeSync(p);\nfinal u = typeSync(p); // vrx-allow:\ndebugPrint('ok');\nprint('no');\n";
        let found: Vec<usize> = violations("a.dart", "dart", dart)
            .iter()
            .map(|v| v.0)
            .collect();
        // line 4 is allowed with a reason; line 5's bare marker is not
        assert_eq!(found, vec![1, 2, 5, 7]);
        assert_eq!(
            violations(
                "a.dart",
                "dart",
                "final v = n.secured ? '\u{1F512}' : '';\n"
            )
            .len(),
            1
        );
        let rs = "fn f() { std::thread::sleep(d); }\n";
        assert_eq!(violations("a.rs", "rs", rs).len(), 1);
    }

    #[test]
    fn the_screen_is_never_switched_by_an_applet_g019() {
        let applet = "applets/x/lib/main.dart";
        let code = "File('/sys/class/backlight/x/brightness').writeAsString('0');\nfinal p = 'bl_power';\n// vrx-allow: just this once\nsetDpms('dpms');\n";
        let found: Vec<&str> = violations(applet, "dart", code)
            .iter()
            .map(|v| v.1)
            .collect();
        // a reason does not excuse it, in the kit as in an applet
        assert_eq!(found, vec!["/sys/class/backlight", "bl_power", "dpms"]);
        assert_eq!(
            violations(
                "flutter/vrx_kit/lib/src/system.dart",
                "dart",
                "Directory('/sys/class/backlight')\n"
            )
            .len(),
            1
        );
        let rs = "let f = \"/sys/class/backlight/x/bl_power\"; // vrx-allow: no\n";
        assert_eq!(violations("applets/y/src/main.rs", "rs", rs).len(), 2);
        // what the kit says instead is not caught
        assert!(violations(applet, "dart", "VrxKeepScreenOn(child: c);\nScreenSettings().setBrightness(0);\nVrxDimming.backlight;\n").is_empty());
    }

    #[test]
    fn colour_and_the_display_class_stay_in_the_kit() {
        let applet = "applets/x/lib/main.dart";
        let code = "a(Colors.red);\nb(Colors.transparent);\nVrxColors.resolve();\nc(const Color(0xFF112233));\nif (cls == 'epaper') {}\nVrxPalette p;\n";
        let found: Vec<&str> = violations(applet, "dart", code)
            .iter()
            .map(|v| v.1)
            .collect();
        assert_eq!(found, vec!["Colors.", "Color(0x", "epaper", "VrxPalette"]);
        // the theme is where a colour is spelled; the boot reader names the class
        assert!(violations(
            "flutter/vrx_kit/lib/src/theme.dart",
            "dart",
            "Color(0xFF000000)\n"
        )
        .is_empty());
        assert!(violations(
            "flutter/vrx_kit/lib/src/applet.dart",
            "dart",
            "'/usr/lib/vrx/display-class'\n"
        )
        .is_empty());
        assert_eq!(
            violations(
                "flutter/vrx_kit/lib/src/applet.dart",
                "dart",
                "Colors.red\n"
            )
            .len(),
            1
        );
    }
}
