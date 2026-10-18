// G059's scan (plan 0018 D15): a numeric literal that names a capture
// bound lives in src/bounds.rs and nowhere else, so a second spelling
// cannot drift. Comments and the crate's own tests are prose and
// fixtures (IMG_9999.JPG, a fake camera's 640x480); only live code is
// scanned. DEFAULT_QUALITY's 85 is not scanned: too generic a number to
// tell from any other eighty-five.

use std::path::Path;

/// Strip `//` comments and whole `mod tests` blocks (from `mod tests {`
/// or `#[cfg(test)] mod` to the matching close) from Rust source.
fn code_only(text: &str) -> String {
    let mut out = String::new();
    let mut depth: i32 = 0;
    for line in text.lines() {
        let code = line.split("//").next().unwrap_or("").trim_end();
        if depth > 0 {
            depth += code.matches('{').count() as i32;
            depth -= code.matches('}').count() as i32;
            continue;
        }
        if code.contains("mod tests") || (code.contains("#[cfg(test)]")) {
            if code.contains('{') {
                depth = code.matches('{').count() as i32 - code.matches('}').count() as i32;
                continue;
            }
            continue;
        }
        out.push_str(code);
        out.push('\n');
    }
    out
}

/// `token` appears as a literal of its own, not inside a longer number
/// (0o640 is a file mode), an identifier or a path.
fn has_own_literal(code: &str, token: &str) -> bool {
    let bytes = code.as_bytes();
    let mut at = 0;
    while let Some(found) = code[at..].find(token) {
        let start = at + found;
        let end = start + token.len();
        let before_ok = start == 0 || !(bytes[start - 1].is_ascii_alphanumeric() || bytes[start - 1] == b'_' || bytes[start - 1] == b'.');
        let after_ok = end == bytes.len() || !(bytes[end].is_ascii_alphanumeric() || bytes[end] == b'_' || bytes[end] == b'.');
        if before_ok && after_ok {
            return true;
        }
        at = end;
    }
    false
}

#[test]
fn no_bound_literal_outside_bounds_rs() {
    const TOKENS: &[&str] = &[
        "8_000_000",       // MAX_PIXELS
        "1024 * 1024",     // MAX_JPEG_BYTES, MIN_FREE_BYTES
        "9999",            // MAX_PHOTO_NUMBER
        "480",             // SMALL_DISPLAY, VIEWFINDER
        "640",             // VIEWFINDER
        "320",             // VIEWFINDER_SMALL
        "240",             // VIEWFINDER_SMALL
    ];
    let src = Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
    let mut bad = String::new();
    let mut entries: Vec<_> = std::fs::read_dir(&src)
        .expect("camerad's src/")
        .flatten()
        .map(|e| e.path())
        .collect();
    entries.sort();
    for path in entries {
        let name = path.file_name().unwrap().to_string_lossy().into_owned();
        if name == "bounds.rs" || !name.ends_with(".rs") {
            continue;
        }
        let code = code_only(&std::fs::read_to_string(&path).unwrap());
        for token in TOKENS {
            if has_own_literal(&code, token) {
                bad.push_str(&format!(
                    "{}: `{}` is a bound's literal; use the const from bounds.rs\n",
                    name, token
                ));
            }
        }
    }
    assert!(bad.is_empty(), "{bad}");
}
