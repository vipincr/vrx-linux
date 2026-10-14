// The responsiveness scan (plan 0008 D19): source forms that block an
// applet's event loop or frame, banned by file and line. A line that
// needs one says so with `vrx-allow: <reason>` on the line or the line
// above; a bare marker without a reason does not count. One
// implementation: `cargo xtask gate` scans the repo, `vrx build` the
// applet it builds.
//
// The source is tokenized before it is matched (plan 0011, evrx-rt rule
// 93: checkers parse, never grep): comments never match, and a rule about
// code (a call, a class) never matches inside a string literal. A rule
// about a value (a path, a class name) matches in strings too, which is
// where such values live.

use std::path::{Path, PathBuf};

/// One banned form: where it applies, what it matches, why it is banned.
struct Rule {
    /// File extension the rule reads.
    ext: &'static str,
    /// Substring that marks a violation.
    needle: &'static str,
    why: &'static str,
    /// Files (path parts) where the form is the job: the kit's theme
    /// may spell a colour, the boot reader a display class.
    except: &'static [&'static str],
    /// The form is a value that lives in string literals (a path, a class
    /// name); otherwise it is code, and a string never matches it.
    in_strings: bool,
}

/// The kit: where the SDK's own forms (dialogs, timers, raw gestures) are
/// built once, for every applet.
const KIT: &[&str] = &["vrx_kit/lib/"];

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
const NO_SCREEN_POWER: &str = "G019: the screen's power is the compositor's (plan 0010 D1); the backlight is reached through the kit's ScreenSettings, a hold is StoreModel.keepsScreenOn";
const NO_DIALOG: &str = "G020: a modal is a route the kit opens (vrxConfirm, vrxAsk), so Back, Escape and the strip close it first (plan 0011 D1)";
const NO_TIMER: &str = "G021: a periodic source is VrxTicker, which rests while the applet is hidden (plan 0011 D3)";
const NO_POLL: &str = "G027: nothing polls (plan 0012 D6): the system's state arrives as events (vrxhost's Facts and Watch, D-Bus signals, inotify); a loop that must wake on a clock says why with `// poll-ok: <reason>`";
const ONE_WRITER: &str = "G031: the store loop is the only writer (plan 0013 D1): a fact becomes an action the model reduces, so nothing outside state.dart assigns a model field";
const NO_RAW_PRESS: &str = "a tappable control comes from the kit's press components (VrxPress and the rows, chips and buttons on it), so every press is acknowledged the same way";

/// Forms no `vrx-allow` excuses. G019: an applet that switches the light
/// or the panel can leave a person with no screen to switch it back on.
/// G020 and G021: the kit's forms are the only way to open a modal or
/// tick, by construction.
const NEVER_ALLOWED: &[&str] = &[
    "/sys/class/backlight",
    "bl_power",
    "dpms",
    "DPMS",
    "showDialog",
    "showGeneralDialog",
    "showModalBottomSheet",
    "Timer.periodic",
    "model.<field> =",
];

/// Where Linux's backlight is wrapped: the kit's vrx interface to it
/// (brightness on the backlight's own attribute, plan 0010).
const BACKLIGHT_HOME: &[&str] = &["vrx_kit/lib/src/screen.dart"];

const RULES: &[Rule] = &[
    Rule {
        ext: "dart",
        needle: "Sync(",
        why: "a synchronous dart:io call blocks the isolate that builds frames",
        except: &[],
        in_strings: false,
    },
    Rule {
        ext: "dart",
        needle: "sleep(",
        why: "sleep blocks the isolate that builds frames",
        except: &[],
        in_strings: false,
    },
    Rule {
        ext: "dart",
        needle: "Navigator.",
        why: "navigation is vrxhost's back trail (Nav), never Navigator",
        except: &[],
        in_strings: false,
    },
    Rule {
        ext: "dart",
        needle: "print(",
        why: "stdout is not a log: debugPrint",
        except: &[],
        in_strings: false,
    },
    Rule {
        ext: "dart",
        needle: "Color(0x",
        why: NO_COLOUR,
        except: COLOUR_HOME,
        in_strings: false,
    },
    Rule {
        ext: "dart",
        needle: "Colors.",
        why: NO_COLOUR,
        except: COLOUR_HOME,
        in_strings: false,
    },
    Rule {
        ext: "dart",
        needle: "VrxPalette",
        why: "VrxPalette is gone: the 32 slots are VrxColors (plan 0009 D2)",
        except: &[],
        in_strings: false,
    },
    Rule {
        ext: "dart",
        needle: "epaper",
        why: NO_CLASS,
        except: CLASS_HOME,
        in_strings: true,
    },
    Rule {
        ext: "dart",
        needle: "lcdColour",
        why: NO_CLASS,
        except: CLASS_HOME,
        in_strings: true,
    },
    Rule {
        ext: "dart",
        needle: "display-class",
        why: NO_CLASS,
        except: CLASS_HOME,
        in_strings: true,
    },
    Rule {
        ext: "dart",
        needle: "/sys/class/backlight",
        why: NO_SCREEN_POWER,
        except: BACKLIGHT_HOME,
        in_strings: true,
    },
    Rule {
        ext: "dart",
        needle: "bl_power",
        why: NO_SCREEN_POWER,
        except: &[],
        in_strings: true,
    },
    Rule {
        ext: "dart",
        needle: "dpms",
        why: NO_SCREEN_POWER,
        except: &[],
        in_strings: true,
    },
    Rule {
        ext: "dart",
        needle: "DPMS",
        why: NO_SCREEN_POWER,
        except: &[],
        in_strings: true,
    },
    Rule {
        ext: "rs",
        needle: "/sys/class/backlight",
        why: NO_SCREEN_POWER,
        except: &[],
        in_strings: true,
    },
    Rule {
        ext: "rs",
        needle: "bl_power",
        why: NO_SCREEN_POWER,
        except: &[],
        in_strings: true,
    },
    Rule {
        ext: "rs",
        needle: "dpms",
        why: NO_SCREEN_POWER,
        except: &[],
        in_strings: true,
    },
    Rule {
        ext: "rs",
        needle: "DPMS",
        why: NO_SCREEN_POWER,
        except: &[],
        in_strings: true,
    },
    Rule {
        ext: "dart",
        needle: "showDialog",
        why: NO_DIALOG,
        except: KIT,
        in_strings: false,
    },
    Rule {
        ext: "dart",
        needle: "showGeneralDialog",
        why: NO_DIALOG,
        except: KIT,
        in_strings: false,
    },
    Rule {
        ext: "dart",
        needle: "showModalBottomSheet",
        why: NO_DIALOG,
        except: KIT,
        in_strings: false,
    },
    Rule {
        ext: "dart",
        needle: "Timer.periodic",
        why: NO_TIMER,
        except: KIT,
        in_strings: false,
    },
    Rule {
        ext: "dart",
        needle: "InkWell",
        why: NO_RAW_PRESS,
        except: KIT,
        in_strings: false,
    },
    Rule {
        ext: "dart",
        needle: "GestureDetector",
        why: NO_RAW_PRESS,
        except: KIT,
        in_strings: false,
    },
    Rule {
        ext: "dart",
        needle: "VrxDisplayClass",
        why: NO_CLASS,
        except: KIT,
        in_strings: false,
    },
    Rule {
        ext: "dart",
        needle: "classRow",
        why: NO_CLASS,
        except: KIT,
        in_strings: false,
    },
    Rule {
        ext: "dart",
        needle: "displayClass",
        why: NO_CLASS,
        except: KIT,
        in_strings: false,
    },
    Rule {
        ext: "rs",
        needle: "thread::sleep(",
        why: "sleeping stalls the applet's loop and its watchdog",
        except: &[],
        in_strings: false,
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

/// Two views of a source file, each the same length line for line:
/// comments blanked in both; string literals' contents kept in the first
/// and blanked in the second. Dart: `//`, nested `/* */`, '…', "…",
/// triple-quoted and raw (r'…') strings. Rust: `//`, nested `/* */`,
/// "…", raw r#"…"# and byte strings, char literals (not lifetimes).
pub fn views(ext: &str, text: &str) -> (String, String) {
    let chars: Vec<char> = text.chars().collect();
    let mut kept = String::with_capacity(text.len());
    let mut code = String::with_capacity(text.len());
    let blank = |c: char| if c == '\n' { '\n' } else { ' ' };
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        let next = chars.get(i + 1).copied();
        // a line comment
        if c == '/' && next == Some('/') {
            while i < chars.len() && chars[i] != '\n' {
                kept.push(' ');
                code.push(' ');
                i += 1;
            }
            continue;
        }
        // a block comment, nested in both languages
        if c == '/' && next == Some('*') {
            let mut depth = 0;
            while i < chars.len() {
                if chars[i] == '/' && chars.get(i + 1) == Some(&'*') {
                    depth += 1;
                    kept.push_str("  ");
                    code.push_str("  ");
                    i += 2;
                    continue;
                }
                if chars[i] == '*' && chars.get(i + 1) == Some(&'/') {
                    depth -= 1;
                    kept.push_str("  ");
                    code.push_str("  ");
                    i += 2;
                    if depth == 0 {
                        break;
                    }
                    continue;
                }
                kept.push(blank(chars[i]));
                code.push(blank(chars[i]));
                i += 1;
            }
            continue;
        }
        let prev_ident = i > 0 && (chars[i - 1].is_alphanumeric() || chars[i - 1] == '_');
        // a Rust raw string: r"…", r#"…"#, br"…"
        if ext == "rs" && (c == 'r' || (c == 'b' && next == Some('r'))) && !prev_ident {
            let start = if c == 'b' { i + 2 } else { i + 1 };
            let mut j = start;
            while chars.get(j) == Some(&'#') {
                j += 1;
            }
            if chars.get(j) == Some(&'"') {
                let hashes = j - start;
                for &ch in &chars[i..=j] {
                    kept.push(ch);
                    code.push(ch);
                }
                i = j + 1;
                while i < chars.len() {
                    if chars[i] == '"'
                        && (0..hashes).all(|h| chars.get(i + 1 + h) == Some(&'#'))
                    {
                        for &ch in &chars[i..=i + hashes] {
                            kept.push(ch);
                            code.push(ch);
                        }
                        i += hashes + 1;
                        break;
                    }
                    kept.push(chars[i]);
                    code.push(blank(chars[i]));
                    i += 1;
                }
                continue;
            }
        }
        // a Rust char literal ('a', '\n', '\u{..}'); a lifetime is code
        if ext == "rs" && c == '\'' {
            let close = if next == Some('\\') {
                (i + 2..chars.len().min(i + 12)).find(|&k| chars[k] == '\'')
            } else if chars.get(i + 2) == Some(&'\'') {
                Some(i + 2)
            } else {
                None
            };
            if let Some(end) = close {
                kept.push('\'');
                code.push('\'');
                for &ch in &chars[i + 1..end] {
                    kept.push(ch);
                    code.push(' ');
                }
                kept.push('\'');
                code.push('\'');
                i = end + 1;
                continue;
            }
            kept.push(c);
            code.push(c);
            i += 1;
            continue;
        }
        // a string literal
        if c == '"' || (ext == "dart" && c == '\'') {
            let raw = ext == "dart"
                && i > 0
                && chars[i - 1] == 'r'
                && !(i > 1 && (chars[i - 2].is_alphanumeric() || chars[i - 2] == '_'));
            let triple = ext == "dart" && next == Some(c) && chars.get(i + 2) == Some(&c);
            let open = if triple { 3 } else { 1 };
            for &ch in &chars[i..i + open] {
                kept.push(ch);
                code.push(ch);
            }
            i += open;
            while i < chars.len() {
                let d = chars[i];
                if d == '\\' && !raw {
                    kept.push(d);
                    code.push(' ');
                    if let Some(&e) = chars.get(i + 1) {
                        kept.push(e);
                        code.push(blank(e));
                    }
                    i += 2;
                    continue;
                }
                let closes = if triple {
                    d == c && chars.get(i + 1) == Some(&c) && chars.get(i + 2) == Some(&c)
                } else {
                    d == c
                };
                if closes {
                    for &ch in &chars[i..i + open] {
                        kept.push(ch);
                        code.push(ch);
                    }
                    i += open;
                    break;
                }
                // a single-line Dart string ends at the line (malformed)
                if d == '\n' && !triple && ext == "dart" {
                    break;
                }
                kept.push(d);
                code.push(blank(d));
                i += 1;
            }
            continue;
        }
        kept.push(c);
        code.push(c);
        i += 1;
    }
    (kept, code)
}

fn allowed(line: &str) -> bool {
    line.split_once("vrx-allow:")
        .is_some_and(|(_, reason)| !reason.trim().is_empty())
}

/// A polling form's reason (G027), on its line or the line above.
fn poll_ok(line: &str) -> bool {
    line.split_once("poll-ok:")
        .is_some_and(|(_, reason)| !reason.trim().is_empty())
}

fn ident_char(c: char) -> bool {
    c.is_alphanumeric() || c == '_'
}

/// The identifier ending just before `at` in `chars`, skipping blanks.
fn ident_before(chars: &[char], at: usize) -> String {
    let mut end = at;
    while end > 0 && chars[end - 1].is_whitespace() {
        end -= 1;
    }
    let mut start = end;
    while start > 0 && ident_char(chars[start - 1]) {
        start -= 1;
    }
    chars[start..end].iter().collect()
}

/// The polling forms in Dart code (comments and strings already blanked):
/// (line, form). A periodic stream or timer; `Future.delayed` inside a
/// loop body; a `Timer(` whose arguments name the function it is in (it
/// re-arms itself). Loops and functions are found by their braces: a `{`
/// after `while`, `for` or `do` opens a loop body, and a `{` after
/// `name(...)` (with `async`, `sync*` or `async*` between) opens that
/// function's body.
fn polls(code: &str) -> Vec<(usize, &'static str)> {
    let chars: Vec<char> = code.chars().collect();
    let mut found = Vec::new();
    // per open brace: whether it opened a loop body, and a function's name
    let mut stack: Vec<(bool, Option<String>)> = Vec::new();
    let mut loop_pending = false;
    let mut line = 1;
    let starts = |i: usize, word: &str| -> bool {
        let w: Vec<char> = word.chars().collect();
        chars.len() >= i + w.len()
            && chars[i..i + w.len()] == w[..]
            && (i == 0 || !ident_char(chars[i - 1]))
    };
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        if c == '\n' {
            line += 1;
            i += 1;
            continue;
        }
        for word in ["while", "for", "do"] {
            if starts(i, word)
                && !chars.get(i + word.len()).copied().is_some_and(ident_char)
            {
                loop_pending = true;
            }
        }
        if starts(i, "Timer.periodic") {
            found.push((line, "Timer.periodic"));
        }
        // Stream.periodic / Stream<T>.periodic, Future.delayed /
        // Future<T>.delayed: the class before the dot, past any type
        // arguments
        let class_before_dot = |at: usize| -> String {
            let mut j = at;
            if j > 0 && chars[j - 1] == '>' {
                let mut depth = 0;
                while j > 0 {
                    j -= 1;
                    match chars[j] {
                        '>' => depth += 1,
                        '<' => {
                            depth -= 1;
                            if depth == 0 {
                                break;
                            }
                        }
                        _ => {}
                    }
                }
            }
            ident_before(&chars, j)
        };
        if c == '.' && starts(i + 1, "periodic") && class_before_dot(i) == "Stream" {
            found.push((line, "Stream.periodic"));
        }
        if c == '.'
            && starts(i + 1, "delayed")
            && class_before_dot(i) == "Future"
            && stack.iter().any(|(is_loop, _)| *is_loop)
        {
            found.push((line, "Future.delayed in a loop"));
        }
        if starts(i, "Timer(") {
            // the call's arguments, to its closing parenthesis
            let mut depth = 0;
            let mut j = i + 5;
            let mut args = String::new();
            while j < chars.len() {
                match chars[j] {
                    '(' => depth += 1,
                    ')' => {
                        depth -= 1;
                        if depth == 0 {
                            break;
                        }
                    }
                    _ => {}
                }
                args.push(chars[j]);
                j += 1;
            }
            let arg_chars: Vec<char> = args.chars().collect();
            let names_self = stack
                .iter()
                .rev()
                .find_map(|(_, f)| f.as_ref())
                .is_some_and(|f| {
                    let w: Vec<char> = f.chars().collect();
                    (0..arg_chars.len()).any(|k| {
                        arg_chars.len() >= k + w.len()
                            && arg_chars[k..k + w.len()] == w[..]
                            && (k == 0 || !ident_char(arg_chars[k - 1]))
                            && !arg_chars
                                .get(k + w.len())
                                .copied()
                                .is_some_and(ident_char)
                    })
                });
            if names_self {
                found.push((line, "a Timer re-armed in its own callback"));
            }
        }
        match c {
            '{' => {
                // what precedes the brace: `name(...) [async|sync*|async*]`
                let mut k = i;
                while k > 0 && chars[k - 1].is_whitespace() {
                    k -= 1;
                }
                for modifier in ["async*", "sync*", "async"] {
                    let m: Vec<char> = modifier.chars().collect();
                    if k >= m.len() && chars[k - m.len()..k] == m[..] {
                        k -= m.len();
                        while k > 0 && chars[k - 1].is_whitespace() {
                            k -= 1;
                        }
                        break;
                    }
                }
                let mut name = None;
                if k > 0 && chars[k - 1] == ')' {
                    let mut depth = 0;
                    let mut j = k;
                    while j > 0 {
                        j -= 1;
                        match chars[j] {
                            ')' => depth += 1,
                            '(' => {
                                depth -= 1;
                                if depth == 0 {
                                    break;
                                }
                            }
                            _ => {}
                        }
                    }
                    let n = ident_before(&chars, j);
                    if !n.is_empty()
                        && !matches!(
                            n.as_str(),
                            "if" | "while" | "for" | "switch" | "catch"
                        )
                    {
                        name = Some(n);
                    }
                }
                stack.push((loop_pending, name));
                loop_pending = false;
            }
            '}' => {
                stack.pop();
            }
            ';' => loop_pending = false,
            _ => {}
        }
        i += 1;
    }
    found
}

/// G031 (plan 0013 D1): writes through `model` in Dart code (comments and
/// strings already blanked): `model.a.b = x`, `model.a += x`, `model.a++`,
/// `++model.a`, and cascades, `model..a = x` on one line or across lines.
/// Returns the 1-based line of each write.
fn model_writes(code: &str) -> Vec<usize> {
    let chars: Vec<char> = code.chars().collect();
    let line_of = |at: usize| chars[..at].iter().filter(|c| **c == '\n').count() + 1;
    let ident = |c: char| c.is_alphanumeric() || c == '_';
    let skip_ws = |mut i: usize| {
        while i < chars.len() && chars[i].is_whitespace() {
            i += 1;
        }
        i
    };
    // the operator at i writes: `=` (not `==`, `=>`), a compound `op=`,
    // `++` or `--`
    let writes_at = |i: usize| -> bool {
        let next = |k: usize| chars.get(i + k).copied().unwrap_or(' ');
        match next(0) {
            '=' => next(1) != '=' && next(1) != '>',
            '+' | '-' => next(1) == next(0) || next(1) == '=',
            '*' | '%' | '|' | '&' | '^' => next(1) == '=',
            '/' => next(1) == '=',
            '~' => next(1) == '/' && next(2) == '=',
            '?' => next(1) == '?' && next(2) == '=',
            _ => false,
        }
    };
    let mut found = Vec::new();
    let mut i = 0;
    while i + 5 <= chars.len() {
        let here: String = chars[i..i + 5].iter().collect();
        let before = if i == 0 { ' ' } else { chars[i - 1] };
        let after = chars.get(i + 5).copied().unwrap_or(' ');
        // `model`, or a private `_model` (the launcher's)
        let private = before == '_' && (i < 2 || !ident(chars[i - 2]));
        if here != "model" || (ident(before) && !private) || ident(after) {
            i += 1;
            continue;
        }
        // prefix ++model.x / --model.x
        let mut b = i;
        while b > 0 && chars[b - 1] == ' ' {
            b -= 1;
        }
        if b >= 2
            && ((chars[b - 1] == '+' && chars[b - 2] == '+')
                || (chars[b - 1] == '-' && chars[b - 2] == '-'))
        {
            found.push(line_of(i));
        }
        let mut j = skip_ws(i + 5);
        if chars.get(j) == Some(&'.') && chars.get(j + 1) == Some(&'.') {
            // a cascade: every `..field … op` up to the statement's end
            let end = chars[j..]
                .iter()
                .position(|c| *c == ';')
                .map_or(chars.len(), |p| j + p);
            let mut k = j;
            while k + 1 < end {
                if chars[k] == '.'
                    && chars[k + 1] == '.'
                    && (k == 0 || chars[k - 1] != '.')
                {
                    let mut m = k + 2;
                    while m < end && (ident(chars[m]) || chars[m] == '.') {
                        m += 1;
                    }
                    let op = skip_ws(m);
                    if op < end && writes_at(op) {
                        found.push(line_of(k));
                    }
                    k = m;
                } else {
                    k += 1;
                }
            }
            i = end.max(i + 5);
            continue;
        }
        // a chain: model.a.b[k] … op (an index write is a write too); a
        // declaration (`final model = …`) consumes no segment and is no write
        let mut segments = 0;
        loop {
            if chars.get(j) == Some(&'.') && chars.get(j + 1).is_some_and(|c| ident(*c)) {
                j += 1;
                while j < chars.len() && ident(chars[j]) {
                    j += 1;
                }
                segments += 1;
            } else if segments > 0 && chars.get(j) == Some(&'[') {
                let mut depth = 0usize;
                while j < chars.len() {
                    match chars[j] {
                        '[' => depth += 1,
                        ']' => {
                            depth -= 1;
                            if depth == 0 {
                                j += 1;
                                break;
                            }
                        }
                        _ => {}
                    }
                    j += 1;
                }
                segments += 1;
            } else {
                break;
            }
        }
        if segments > 0 {
            let op = skip_ws(j);
            if op < chars.len() && writes_at(op) {
                found.push(line_of(i));
            }
        }
        i += 5;
    }
    found.dedup();
    found
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
    let (kept, bare) = views(ext, text);
    let kept: Vec<&str> = kept.lines().collect();
    let bare: Vec<&str> = bare.lines().collect();
    let mut found = Vec::new();
    for (i, line) in lines.iter().enumerate() {
        let with_strings = kept.get(i).copied().unwrap_or("");
        let code_only = bare.get(i).copied().unwrap_or("");
        if ext == "dart" && with_strings.chars().any(is_emoji) {
            found.push((
                i + 1,
                "emoji",
                "the image ships no emoji font: use a VrxSymbols glyph",
            ));
        }
        for rule in RULES
            .iter()
            .filter(|r| r.ext == ext && !r.except.iter().any(|e| path.contains(e)))
        {
            let code = if rule.in_strings {
                with_strings
            } else {
                code_only
            };
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
    // G031, applets only: the model's fields are written in state.dart
    // (its reducer), nowhere else; no marker excuses it
    if ext == "dart"
        && !KIT.iter().any(|k| path.contains(k))
        && !path.ends_with("state.dart")
    {
        let code: String = bare.join("\n");
        for n in model_writes(&code) {
            found.push((n, "model.<field> =", ONE_WRITER));
        }
    }
    // G027, applets and the kit alike: a polling form needs its reason
    if ext == "dart" {
        let code: String = bare.join("\n");
        let kit = KIT.iter().any(|k| path.contains(k));
        for (n, form) in polls(&code) {
            // in an applet a periodic timer is already G021's, never allowed
            if form == "Timer.periodic" && !kit {
                continue;
            }
            let here = lines.get(n - 1).copied().unwrap_or("");
            let above = n
                .checked_sub(2)
                .and_then(|j| lines.get(j))
                .copied()
                .unwrap_or("");
            if !poll_ok(here) && !poll_ok(above) {
                found.push((n, form, NO_POLL));
            }
        }
    }
    found.sort_by_key(|f| f.0);
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

impl Violation {
    /// What would make the line acceptable, for the message: a polling
    /// form's reason (G027), nothing for a form no marker excuses, or a
    /// reasoned `vrx-allow`.
    pub fn remedy(&self) -> &'static str {
        if self.why == NO_POLL {
            " (or say why it must wake on a clock: `// poll-ok: <reason>`)"
        } else if NEVER_ALLOWED.contains(&self.needle) {
            ""
        } else {
            " (or mark the line `vrx-allow: <reason>`)"
        }
    }
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

/// A form with one home (G037, G044): the files where it is the job.
/// Anywhere else under the scanned trees it is a second reader or a
/// second decider, and no marker excuses it.
struct Homed {
    ext: &'static str,
    /// Names that end at a word boundary: `hvs_underruns`, a counter's
    /// name in a reply, is not the debugfs file `hvs_underrun`.
    needles: &'static [&'static str],
    /// Path suffixes of the home; empty: nowhere in these trees.
    home: &'static [&'static str],
    why: &'static str,
    /// A line with any of these is not the form: `/proc/self/fdinfo` is a
    /// descriptor's own seals (bridge.rs's buffer check), `props[` a read
    /// of BlueZ's properties.
    unless: &'static [&'static str],
}

/// G037 (plan 0014 D4): the per-applet counters have one reader,
/// vrxhost's `counters` module, shared by the energy estimate and the
/// profiler.
const COUNTER_FILES: &[&str] = &[
    "cpu.stat",
    "memory.stat",
    "memory.current",
    "memory.peak",
    "memory.events",
    "io.stat",
    "cpu.pressure",
    "memory.pressure",
    "io.pressure",
    "fdinfo",
    "hvs_underrun",
];
const ONE_READER: &str = "G037: per-applet counters have one reader, vrxhost's counters module (plan 0014 D4); call it instead of reading the file";

/// G044 (plan 0015 D4): who advertises on Bluetooth is vrxhost's
/// arbiter's decision. BlueZ's discoverable window is set there alone
/// (Device Link asks through io.vrx.Host.PairingWindow); vrx-matter's
/// GATT peripheral lives in its BLE module, whose one entry point takes
/// the arbiter's Grant; nothing registers an LE advertisement directly.
const BLUEZ_WINDOW: &[&str] = &[
    "Discoverable",
    "DiscoverableTimeout",
    "Pairable",
    "PairableTimeout",
];
const ADVERTISING: &[&str] = &[
    "RegisterAdvertisement",
    "register_advertisement",
    "LEAdvertisingManager1",
];
const ONE_ARBITER: &str = "G044: who advertises on Bluetooth is vrxhost's arbiter's decision (plan 0015 D4): Device Link asks io.vrx.Host.PairingWindow, vrx-matter asks over its link";
const ARBITER_HOME: &[&str] = &["rust/host/src/bt_arbiter.rs"];

/// G050 (plan 0017 D2, D3, D10): motion has one engine. Every spring,
/// curve, animated widget and scroll physics lives in the kit's motion.dart;
/// everything else names a micro row and gets the engine's, with its
/// tolerance in pixels and the build's tier. Comments never match.
const MOTION_HOME: &[&str] = &["flutter/vrx_kit/lib/src/motion.dart"];
const ONE_ENGINE: &str = "G050: motion has one engine (plan 0017 D2): name a micro row and let VrxMotion (flutter/vrx_kit/lib/src/motion.dart) run it, never an AnimationController, a Curve, an Animated widget, a hand duration or a scroll physics";
const ENGINE_FORMS: &[&str] = &[
    "AnimationController",
    "SpringSimulation(",
    "ScrollSpringSimulation(",
    "FrictionSimulation(",
    "ClampingScrollSimulation(",
    "BouncingScrollSimulation(",
    "CurvedAnimation",
    "Curves.",
    "extends Curve",
    "TweenAnimationBuilder",
    "PageRouteBuilder",
    "AnimatedAlign",
    "AnimatedBuilder",
    "AnimatedContainer",
    "AnimatedCrossFade",
    "AnimatedDefaultTextStyle",
    "AnimatedFractionallySizedBox",
    "AnimatedList",
    "AnimatedModalBarrier",
    "AnimatedOpacity",
    "AnimatedPadding",
    "AnimatedPhysicalModel",
    "AnimatedPositioned",
    "AnimatedRotation",
    "AnimatedScale",
    "AnimatedSize",
    "AnimatedSlide",
    "AnimatedSwitcher",
    "AnimatedWidget",
    // a duration given to a scroll animation is a hand-tuned curve
    ".animateTo(",
    ".animateToItem(",
    ".animateToPage(",
    ".nextPage(",
    ".previousPage(",
    // any scroll physics but the engine's, named or subclassed
    "ScrollPhysics",
];

/// G053 (plan 0017 D5): motion is decided in two places only, the build's
/// tier (a file vrx-theme writes, read once at boot) and the Reduce motion
/// row (Flutter's `disableAnimations`, read by the engine). Nothing else
/// slows, stops or reads either.
const DECIDED_TWICE: &str = "G053: motion is decided in two places only (plan 0017 D5): the build's tier, read from /usr/lib/vrx/motion-tier at boot (applet.dart), and the Reduce motion row, read as MediaQuery's disableAnimations by the engine (motion.dart)";

const HOMED: &[Homed] = &[
    Homed {
        ext: "dart",
        needles: ENGINE_FORMS,
        home: MOTION_HOME,
        why: ONE_ENGINE,
        unless: &[],
    },
    Homed {
        ext: "dart",
        needles: &[
            "disableAnimations",
            "disableAnimationsOf",
            "maybeDisableAnimationsOf",
        ],
        home: MOTION_HOME,
        why: DECIDED_TWICE,
        unless: &[],
    },
    Homed {
        ext: "dart",
        needles: &["motion-tier"],
        home: &["flutter/vrx_kit/lib/src/applet.dart"],
        why: DECIDED_TWICE,
        unless: &[],
    },
    Homed {
        ext: "dart",
        needles: &["timeDilation"],
        home: &[],
        why: DECIDED_TWICE,
        unless: &[],
    },
    // a `physics:` argument is the engine's two named constants, or nothing:
    // the behaviour installs the rest
    Homed {
        ext: "dart",
        needles: &["physics:"],
        home: MOTION_HOME,
        why: ONE_ENGINE,
        unless: &["vrxPagedPhysics", "vrxWheelPhysics"],
    },
    Homed {
        ext: "rs",
        needles: COUNTER_FILES,
        home: &["rust/host/src/counters.rs"],
        why: ONE_READER,
        unless: &["/proc/self/fdinfo"],
    },
    Homed {
        ext: "rs",
        needles: BLUEZ_WINDOW,
        home: ARBITER_HOME,
        why: ONE_ARBITER,
        unless: &[],
    },
    Homed {
        ext: "rs",
        needles: ADVERTISING,
        home: ARBITER_HOME,
        why: ONE_ARBITER,
        unless: &[],
    },
    Homed {
        ext: "rs",
        needles: &["run_peripheral"],
        home: &["rust/matter/src/ble.rs"],
        why: ONE_ARBITER,
        unless: &[],
    },
    Homed {
        ext: "dart",
        needles: BLUEZ_WINDOW,
        home: &[],
        why: ONE_ARBITER,
        unless: &["props["],
    },
    Homed {
        ext: "dart",
        needles: ADVERTISING,
        home: &[],
        why: ONE_ARBITER,
        unless: &[],
    },
];

/// Every source under [roots] (Rust tests excluded) that names a form
/// outside its home (G037, G044). Comments never match; string literals
/// do, since a file's or a D-Bus member's name lives in one.
pub fn one_home(roots: &[PathBuf]) -> Vec<Violation> {
    let mut all = Vec::new();
    for root in roots {
        files(root, &mut all);
    }
    all.sort();
    let mut out = Vec::new();
    for path in all {
        let ext = path.extension().and_then(|e| e.to_str()).unwrap_or("");
        let shown = path.to_string_lossy();
        let rules: Vec<&Homed> = HOMED
            .iter()
            .filter(|h| h.ext == ext && !h.home.iter().any(|home| shown.ends_with(home)))
            .collect();
        if rules.is_empty() {
            continue;
        }
        let Ok(text) = std::fs::read_to_string(&path) else {
            continue;
        };
        let body = if ext == "rs" {
            text.split("#[cfg(test)]").next().unwrap_or("")
        } else {
            &text
        };
        let (kept, _) = views(ext, body);
        // a name stands on word boundaries at its alphanumeric ends: a
        // needle that ends in punctuation (`Curves.`, `Foo(`) is a prefix by
        // its nature, and one that starts with it (`.animateTo(`) is free
        // of a boundary before
        let names = |line: &str, needle: &str| {
            line.match_indices(needle).any(|(at, _)| {
                let first = needle.chars().next().is_some_and(ident_char);
                let last = needle.chars().next_back().is_some_and(ident_char);
                let before = line[..at].chars().next_back().is_some_and(ident_char);
                let after = line[at + needle.len()..]
                    .chars()
                    .next()
                    .is_some_and(ident_char);
                let prefix_form = first && !last && before;
                !(prefix_form || (last && after))
            })
        };
        for (n, line) in kept.lines().enumerate() {
            for rule in &rules {
                if rule.unless.iter().any(|u| line.contains(u)) {
                    continue;
                }
                for needle in rule.needles {
                    if names(line, needle) {
                        out.push(Violation {
                            path: path.clone(),
                            line: n + 1,
                            needle,
                            why: rule.why,
                        });
                    }
                }
            }
        }
    }
    out
}

/// A literal an applet's Dart source sends: an intent by name, or a push
/// to an applet (and route). What is computed at run time is not here;
/// vrxhost refuses it at the socket instead (plan 0011 D9).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Sent {
    Intent {
        line: usize,
        name: String,
    },
    Push {
        line: usize,
        applet: String,
        route: Option<String>,
    },
}

/// The string literal that opens `chars` (after blanks), if it is one
/// with no interpolation.
fn literal_at(chars: &[char]) -> Option<String> {
    let mut i = chars.iter().position(|c| !c.is_whitespace())?;
    let quote = chars[i];
    if quote != '\'' && quote != '"' {
        return None;
    }
    i += 1;
    let mut out = String::new();
    while let Some(&c) = chars.get(i) {
        if c == quote {
            return Some(out);
        }
        if c == '$' || c == '\\' {
            return None;
        }
        out.push(c);
        i += 1;
    }
    None
}

/// Every literal `Intent.send('…')` and `Nav.push('…', route: '…')` in a
/// Dart file, found in its code (never in comments or strings).
pub fn sent_literals(text: &str) -> Vec<Sent> {
    let (kept, bare) = views("dart", text);
    let mut out = Vec::new();
    for (n, (k, b)) in kept.lines().zip(bare.lines()).enumerate() {
        let k: Vec<char> = k.chars().collect();
        let b: String = b.to_owned();
        let bc: Vec<char> = b.chars().collect();
        for (call, is_push) in [("Intent.send(", false), ("Nav.push(", true)] {
            let pat: Vec<char> = call.chars().collect();
            let mut at = 0;
            while at + pat.len() <= bc.len() {
                if bc[at..at + pat.len()] != pat[..]
                    || (at > 0 && (bc[at - 1].is_alphanumeric() || bc[at - 1] == '_'))
                {
                    at += 1;
                    continue;
                }
                let args = &k[at + pat.len()..];
                if let Some(first) = literal_at(args) {
                    if is_push {
                        // a route: '…' named argument inside the same call
                        let close = bc[at..]
                            .iter()
                            .position(|c| *c == ')')
                            .map_or(bc.len(), |p| at + p);
                        let call_text: String = bc[at..close].iter().collect();
                        let route = call_text.find("route:").and_then(|r| {
                            let start =
                                at + call_text[..r].chars().count() + "route:".len();
                            literal_at(&k[start..])
                        });
                        out.push(Sent::Push {
                            line: n + 1,
                            applet: first,
                            route,
                        });
                    } else {
                        out.push(Sent::Intent {
                            line: n + 1,
                            name: first,
                        });
                    }
                }
                at += pat.len();
            }
        }
    }
    out
}

/// G022 at build time: every intent an applet's Dart code sends by name
/// is in its manifest's emits, and every applet it pushes by name exists
/// with the route it names (`known`: the other manifests; None checks the
/// intents only, as `vrx build` does for one applet). One finding per
/// line: `path:line: why`.
pub fn sent_violations(
    dir: &Path,
    own: &crate::Manifest,
    known: Option<&[crate::Manifest]>,
) -> Vec<String> {
    let mut sources = Vec::new();
    files(&dir.join("lib"), &mut sources);
    sources.retain(|p| p.extension().is_some_and(|e| e == "dart"));
    sources.sort();
    let mut out = Vec::new();
    for path in sources {
        let Ok(text) = std::fs::read_to_string(&path) else {
            continue;
        };
        let shown = path
            .strip_prefix(dir)
            .unwrap_or(&path)
            .display()
            .to_string();
        for sent in sent_literals(&text) {
            match sent {
                Sent::Intent { line, name } => {
                    if !own.applet.intents.emits.contains(&name) {
                        out.push(format!(
                            "{shown}:{line}: sends {name:?}, which {}'s manifest does not emit (G022)",
                            own.applet.id
                        ));
                    }
                }
                Sent::Push {
                    line,
                    applet,
                    route,
                } => {
                    let Some(known) = known else { continue };
                    match known.iter().find(|m| m.applet.id == applet) {
                        None => out.push(format!(
                            "{shown}:{line}: pushes {applet:?}, which is no applet (G022)"
                        )),
                        Some(target) => {
                            if let Some(route) =
                                route.filter(|r| target.route_number(r).is_none())
                            {
                                out.push(format!(
                                    "{shown}:{line}: pushes {applet:?} at {route:?}, a route it does not declare (G022)"
                                ));
                            }
                        }
                    }
                }
            }
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
    fn a_second_counter_reader_is_refused_g037() {
        let dir = std::env::temp_dir().join(format!("vrx-g037-{}", std::process::id()));
        let src = dir.join("rust/host/src");
        std::fs::create_dir_all(&src).unwrap();
        std::fs::write(src.join("counters.rs"), "fn a() { read(\"cpu.stat\"); }\n")
            .unwrap();
        std::fs::write(
            src.join("bridge.rs"),
            "fn b() { open(\"/proc/self/fdinfo/3\"); } // reads memory.stat in a comment\n",
        )
        .unwrap();
        assert!(
            one_home(std::slice::from_ref(&dir)).is_empty(),
            "the home and a descriptor's own seals pass"
        );
        std::fs::write(
            src.join("other.rs"),
            "fn c() { let p = dir.join(\"io.pressure\"); }\n",
        )
        .unwrap();
        std::fs::write(
            src.join("reply.rs"),
            "fn d() { json!({ \"hvs_underruns\": n }); }\n",
        )
        .unwrap();
        let found = one_home(std::slice::from_ref(&dir));
        assert_eq!(
            found.len(),
            1,
            "a counter's name in a reply is not the file"
        );
        assert_eq!((found[0].needle, found[0].line), ("io.pressure", 1));
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// G050 (plan 0017 D2, D10): every form of hand-rolled motion is refused
    /// outside the engine's file, one negative per pattern; the engine's own
    /// file, comments and the two named physics constants pass.
    #[test]
    fn motion_has_one_engine_g050() {
        let dir = std::env::temp_dir().join(format!("vrx-g050-{}", std::process::id()));
        let kit = dir.join("flutter/vrx_kit/lib/src");
        let applet = dir.join("applets/a/lib");
        for d in [&kit, &applet] {
            std::fs::create_dir_all(d).unwrap();
        }
        let every = ENGINE_FORMS.join(" ");
        std::fs::write(
            kit.join("motion.dart"),
            format!("final x = {every}; physics: Foo();\n"),
        )
        .unwrap();
        std::fs::write(
            kit.join("fine.dart"),
            "// AnimationController and Curves.easeOut in a comment\nfinal l = ListView(physics: vrxPagedPhysics);\nfinal w = ListWheelScrollView(physics: vrxWheelPhysics);\nfinal v = value.springTo(1, spring);\n",
        )
        .unwrap();
        assert!(
            one_home(std::slice::from_ref(&dir)).is_empty(),
            "the engine, comments and the named constants pass"
        );
        for form in ENGINE_FORMS {
            let line = format!("final x = {form}(thing);\n");
            std::fs::write(applet.join("main.dart"), &line).unwrap();
            let found = one_home(std::slice::from_ref(&dir));
            assert!(
                found
                    .iter()
                    .any(|v| v.needle == *form && v.why == ONE_ENGINE),
                "{form} outside the engine passes: {found:?}"
            );
        }
        for line in [
            "ListView(physics: const ClampingScrollPhysics())",
            "ListView(physics: custom)",
            "class P extends Curve { }",
        ] {
            std::fs::write(applet.join("main.dart"), format!("final x = {line};\n"))
                .unwrap();
            let found = one_home(std::slice::from_ref(&dir));
            assert!(
                found.iter().any(|v| v.why == ONE_ENGINE),
                "{line} passes: {found:?}"
            );
        }
        std::fs::write(
            kit.join("fine.dart"),
            "var a = AnimatedFoo();\nfinal c = Curved();\n",
        )
        .unwrap();
        std::fs::write(
            applet.join("main.dart"),
            "final c = MyCurves.x; final d = Duration(seconds: 1);\n",
        )
        .unwrap();
        assert!(
            one_home(std::slice::from_ref(&dir)).is_empty(),
            "a name that merely contains a form, and a duration for a timer, pass"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// G053 (plan 0017 D5): the tier is read from one file in one place, the
    /// Reduce motion flag by the engine alone, and nothing dilates time.
    #[test]
    fn motion_is_decided_in_two_places_g053() {
        let dir = std::env::temp_dir().join(format!("vrx-g053-{}", std::process::id()));
        let kit = dir.join("flutter/vrx_kit/lib/src");
        let applet = dir.join("applets/a/lib");
        for d in [&kit, &applet] {
            std::fs::create_dir_all(d).unwrap();
        }
        std::fs::write(
            kit.join("motion.dart"),
            "final r = MediaQuery.maybeDisableAnimationsOf(c) ?? false;\n",
        )
        .unwrap();
        std::fs::write(
            kit.join("applet.dart"),
            "const f = '/usr/lib/vrx/motion-tier';\n",
        )
        .unwrap();
        assert!(one_home(std::slice::from_ref(&dir)).is_empty());
        for line in [
            "final r = MediaQuery.disableAnimationsOf(context);",
            "final r = MediaQuery.of(context).disableAnimations;",
            "final r = platformDispatcher.accessibilityFeatures.disableAnimations;",
            "final f = File('/usr/lib/vrx/motion-tier');",
            "timeDilation = 0.5;",
        ] {
            std::fs::write(applet.join("main.dart"), format!("{line}\n")).unwrap();
            let found = one_home(std::slice::from_ref(&dir));
            assert!(
                found.iter().any(|v| v.why == DECIDED_TWICE),
                "{line} passes: {found:?}"
            );
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// G044 fires: an advertisement registered in vrx-matter, the GATT
    /// peripheral started outside its BLE module, and BlueZ's window set
    /// from the kit are refused; the arbiter, the BLE module and a read
    /// of BlueZ's properties pass.
    #[test]
    fn one_arbiter_decides_who_advertises_g044() {
        let dir = std::env::temp_dir().join(format!("vrx-g044-{}", std::process::id()));
        let host = dir.join("rust/host/src");
        let matter = dir.join("rust/matter/src");
        let kit = dir.join("flutter/vrx_kit/lib/src");
        for d in [&host, &matter, &kit] {
            std::fs::create_dir_all(d).unwrap();
        }
        std::fs::write(
            host.join("bt_arbiter.rs"),
            "fn a() { set(\"Discoverable\", true); set(\"PairableTimeout\", 180); }\n",
        )
        .unwrap();
        std::fs::write(
            matter.join("ble.rs"),
            "async fn b() { bluez::run_peripheral(&c, None, n, &a, b).await }\n",
        )
        .unwrap();
        std::fs::write(
            kit.join("bluetooth.dart"),
            "final on = a.props['Discoverable']?.asBoolean();\n// sets Pairable in a comment\nfinal d = s.discoverable;\n",
        )
        .unwrap();
        assert!(
            one_home(std::slice::from_ref(&dir)).is_empty(),
            "the homes, a read and a comment pass"
        );

        std::fs::write(
            matter.join("node.rs"),
            "async fn c() {\n    lm.register_advertisement(&path, opts).await?;\n    run_peripheral(&c, None, n, &a, b).await\n}\n",
        )
        .unwrap();
        std::fs::write(
            kit.join("bluetooth.dart"),
            "await set('Discoverable', const DBusBoolean(true));\nawait a.setProperty(i, 'Pairable', v);\nfinal on = a.props['Discoverable'];\n",
        )
        .unwrap();
        let found: Vec<(String, usize, &str)> = one_home(std::slice::from_ref(&dir))
            .into_iter()
            .map(|v| {
                let name = v.path.file_name().unwrap().to_string_lossy().into_owned();
                (name, v.line, v.needle)
            })
            .collect();
        assert_eq!(
            found,
            [
                ("bluetooth.dart".to_owned(), 1, "Discoverable"),
                ("bluetooth.dart".to_owned(), 2, "Pairable"),
                ("node.rs".to_owned(), 2, "register_advertisement"),
                ("node.rs".to_owned(), 3, "run_peripheral"),
            ]
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

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
        // a reason does not excuse it
        assert_eq!(found, vec!["/sys/class/backlight", "bl_power", "dpms"]);
        // the kit's screen.dart wraps the backlight; nowhere else in the kit
        let kit = "const backlightRoot = '/sys/class/backlight';\n";
        assert!(
            violations("flutter/vrx_kit/lib/src/screen.dart", "dart", kit).is_empty()
        );
        assert_eq!(
            violations("flutter/vrx_kit/lib/src/system.dart", "dart", kit).len(),
            1
        );
        // and even there, switching the panel is not the kit's
        assert_eq!(
            violations(
                "flutter/vrx_kit/lib/src/screen.dart",
                "dart",
                "write('bl_power', 4);\n"
            )
            .len(),
            1
        );
        let rs = "let f = \"/sys/class/backlight/x/bl_power\"; // vrx-allow: no\n";
        assert_eq!(violations("applets/y/src/main.rs", "rs", rs).len(), 2);
        // what the kit says instead is not caught
        assert!(violations(
            applet,
            "dart",
            "bool get keepsScreenOn => ringing;\nScreenSettings().setBrightness(0);\nVrxDimming.backlight;\n"
        )
        .is_empty());
    }

    #[test]
    fn comments_never_match_and_strings_match_only_values() {
        let applet = "applets/x/lib/main.dart";
        let code = "// print('x') and Timer.periodic in a comment\n/* showDialog\n   still a comment */\nfinal s = 'print(1) showDialog InkWell';\nfinal t = '''\nTimer.periodic\n''';\nfinal u = 'http://x/print(';\nfinal p = '/sys/class/backlight';\n";
        let found: Vec<(usize, &str)> = violations(applet, "dart", code)
            .iter()
            .map(|v| (v.0, v.1))
            .collect();
        // only the value rule fires, in its string
        assert_eq!(found, vec![(9, "/sys/class/backlight")]);
        let rs = "let s = \"thread::sleep(\"; // thread::sleep(\nlet r = r#\"thread::sleep(\"#;\nfn f<'a>(x: &'a str) -> char { 'x' }\nstd::thread::sleep(d);\n";
        let found: Vec<usize> =
            violations("a.rs", "rs", rs).iter().map(|v| v.0).collect();
        assert_eq!(found, vec![4]);
        let (kept, bare) = views("dart", "a('b\\'c') // d\n");
        assert_eq!(kept, "a('b\\'c')     \n");
        assert_eq!(bare, "a('    ')     \n");
    }

    /// G020, G021, rule 16 and rule 34: the kit's forms outside the kit.
    #[test]
    fn nothing_polls_without_a_reason_in_applets_or_the_kit_g027() {
        let periodic = "Stream<void>.periodic(const Duration(seconds: 1)).listen(f);\n\
                        final t = Stream.periodic(d);\n";
        let found = violations("applets/a/lib/main.dart", "dart", periodic);
        assert_eq!(
            found.iter().filter(|f| f.1 == "Stream.periodic").count(),
            2,
            "{found:?}"
        );
        // the kit is no exception
        assert!(
            violations("flutter/vrx_kit/lib/src/x.dart", "dart", periodic)
                .iter()
                .any(|f| f.1 == "Stream.periodic")
        );
        let kit_timer = "  _t = Timer.periodic(p, (_) => tick());\n";
        assert!(
            violations("flutter/vrx_kit/lib/src/x.dart", "dart", kit_timer)
                .iter()
                .any(|f| f.1 == "Timer.periodic" && f.2 == NO_POLL)
        );
        let delayed = "Future<void> f() async {\n  while (true) {\n    await g();\n    await Future<void>.delayed(d);\n  }\n}\nFuture<void> once() async {\n  await Future<void>.delayed(d);\n}\n";
        let found = violations("applets/a/lib/main.dart", "dart", delayed);
        assert_eq!(
            found
                .iter()
                .filter(|f| f.1 == "Future.delayed in a loop")
                .map(|f| f.0)
                .collect::<Vec<_>>(),
            [4],
            "{found:?}"
        );
        let rearm = "void _tick() {\n  dispatch();\n  _timer = Timer(next(), _tick);\n}\nvoid _later() {\n  _t = Timer(d, () => flush());\n}\n";
        let found = violations("applets/a/lib/main.dart", "dart", rearm);
        assert_eq!(
            found
                .iter()
                .filter(|f| f.1 == "a Timer re-armed in its own callback")
                .map(|f| f.0)
                .collect::<Vec<_>>(),
            [3],
            "{found:?}"
        );
        // a stated reason passes, on the line or above; a bare marker does not
        let ok = "  _t = Timer(next(), _tick); // poll-ok: the face shows minutes\n";
        assert!(violations(
            "applets/a/lib/main.dart",
            "dart",
            &format!("void _tick() {{\n{ok}}}\n")
        )
        .is_empty());
        let bare = "void _tick() {\n  // poll-ok:\n  _t = Timer(next(), _tick);\n}\n";
        assert!(!violations("applets/a/lib/main.dart", "dart", bare).is_empty());
        // a comment or a string never polls
        assert!(violations(
            "applets/a/lib/main.dart",
            "dart",
            "// Stream.periodic(d)\nfinal s = 'Timer.periodic';\n"
        )
        .is_empty());
    }

    #[test]
    fn dialogs_timers_raw_presses_and_the_class_stay_in_the_kit() {
        let applet = "applets/x/lib/main.dart";
        // (a marker covers its own line and the one below)
        let code = "InkWell(onTap: f);\nVrxColors.classRow;\nif (VrxDisplayClass.lcdColour == x) {}\nshowModalBottomSheet(c);\n\nshowDialog(context: c, builder: b); // vrx-allow: legacy\nTimer.periodic(d, f); // vrx-allow: legacy\nGestureDetector(onTap: f); // vrx-allow: a drag surface\n";
        let found: Vec<(usize, &str)> = violations(applet, "dart", code)
            .iter()
            .map(|v| (v.0, v.1))
            .collect();
        // a reason excuses a raw press, never a dialog or a timer
        assert_eq!(
            found,
            vec![
                (1, "InkWell"),
                (2, "classRow"),
                (3, "lcdColour"),
                (3, "VrxDisplayClass"),
                (4, "showModalBottomSheet"),
                (6, "showDialog"),
                (7, "Timer.periodic"),
            ]
        );
        assert!(violations(
            "flutter/vrx_kit/lib/src/modals.dart",
            "dart",
            "showDialog(c);\nTimer.periodic(d, f); // poll-ok: the kit's one ticker\nInkWell();\n"
        )
        .is_empty());
    }

    #[test]
    fn sent_literals_are_found_in_code_only() {
        let text = "await Intent.send('sys.alarm.ring', {'k': 1});\n// Intent.send('in.comment')\nNav.push('docs');\nNav.push('setup', route: 'again');\nNav.push(row.key);\nIntent.send('a.$b');\nfinal s = \"Nav.push('x')\";\nMyIntent.send('no.match');\n";
        assert_eq!(
            sent_literals(text),
            vec![
                Sent::Intent {
                    line: 1,
                    name: "sys.alarm.ring".into()
                },
                Sent::Push {
                    line: 3,
                    applet: "docs".into(),
                    route: None
                },
                Sent::Push {
                    line: 4,
                    applet: "setup".into(),
                    route: Some("again".into())
                },
            ]
        );
    }

    #[test]
    fn an_undeclared_intent_or_a_missing_applet_or_route_is_named_g022() {
        let dir = std::env::temp_dir().join(format!("vrx-sent-{}", std::process::id()));
        std::fs::create_dir_all(dir.join("lib")).unwrap();
        std::fs::write(
            dir.join("lib/main.dart"),
            "Intent.send('web.done');\nIntent.send('web.other');\nNav.push('docs');\nNav.push('ghost');\nNav.push('setup', route: 'again');\nNav.push('setup', route: 'nope');\n",
        )
        .unwrap();
        let m = |id: &str, extra: &str| -> crate::Manifest {
            format!("[applet]\nid = \"{id}\"\nname = \"N\"\nversion = \"1\"\nruntime = \"flutter\"\n{extra}")
                .parse()
                .unwrap()
        };
        let own = m("web", "[applet.intents]\nemits = [\"web.done\"]\n");
        let known = [
            own.clone(),
            m("docs", ""),
            m("setup", "[applet.routes]\nagain = {}\n"),
        ];
        let found = sent_violations(&dir, &own, Some(&known));
        let lines: Vec<&str> = found
            .iter()
            .map(|f| f.split(": ").next().unwrap())
            .collect();
        assert_eq!(
            lines,
            ["lib/main.dart:2", "lib/main.dart:4", "lib/main.dart:6"],
            "{found:?}"
        );
        assert_eq!(sent_violations(&dir, &own, None).len(), 1, "intents only");
        let _ = std::fs::remove_dir_all(&dir);
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

    /// G031 (plan 0013 D1): a write through `model` outside state.dart is
    /// found in every spelling; reads, comparisons and arrows are not; the
    /// reducer's own file and the kit are exempt.
    #[test]
    fn the_store_is_the_only_writer_g031() {
        let code = "model.error = e;\nif (model.error == null) x();\nfinal f = () => model.view;\nmodel.count += 1;\nmodel.count++;\n++model.taps;\nmodel..open = c\n  ..error = null;\nmodel.list.add(x);\nmodel.ips ??= [];\nmodel.a.b = 2; // vrx-allow: no\nh.model.x = 1;\nmyModel.x = 1;\nmodel.world[z] ??= y;\nif (model.values['a'] == b) {}\nmodel.h12 = !f;\nfinal model = M();\nvar model2 = 1;\n_model.error = null;\nmy_model.x = 1;\n";
        let found: Vec<usize> = violations("applets/x/lib/main.dart", "dart", code)
            .into_iter()
            .filter(|f| f.1 == "model.<field> =")
            .map(|f| f.0)
            .collect();
        assert_eq!(found, vec![1, 4, 5, 6, 7, 8, 10, 11, 12, 14, 16, 19]);
        assert!(violations("applets/x/lib/state.dart", "dart", code)
            .iter()
            .all(|f| f.1 != "model.<field> ="));
        assert!(violations("flutter/vrx_kit/lib/src/x.dart", "dart", code)
            .iter()
            .all(|f| f.1 != "model.<field> ="));
    }
}
