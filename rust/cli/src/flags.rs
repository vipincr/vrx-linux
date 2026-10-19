//! One flag reader for every subcommand (review 2026-10-17, KRN-04):
//! six hand spellings of "the value after --flag" meant each new
//! subcommand re-derived the helpers, and drifted (`-o` in one, `--out`
//! in another; a trailing flag read as absent in one and panicked in
//! another). Everything here borrows; no subcommand clones args for this.

/// The value after `flag`, or None. A flag at the end of the arguments
/// has no value and reads as absent; the caller that needs one reports
/// its own error naming the flag.
pub fn value<'a>(args: &'a [String], flag: &str) -> Option<&'a str> {
    args.windows(2)
        .find(|w| w[0] == flag)
        .map(|w| w[1].as_str())
}

/// Whether `flag` appears at all (a boolean flag: `--keep`, `--measured`).
pub fn present(args: &[String], flag: &str) -> bool {
    args.iter().any(|a| a == flag)
}

/// The positional arguments: whatever is neither a flag that takes a
/// value, the value itself, nor a valueless flag. An argument starting
/// `--` that neither list names is an error, so a typo cannot silently
/// become a positional and eat a file name's slot.
pub fn positionals<'a>(
    args: &'a [String],
    with_value: &[&str],
    valueless: &[&str],
) -> Result<Vec<&'a str>, String> {
    let mut out = Vec::new();
    let mut skip_value = false;
    for a in args {
        if skip_value {
            skip_value = false;
            continue;
        }
        if with_value.contains(&a.as_str()) {
            skip_value = true;
            continue;
        }
        if valueless.contains(&a.as_str()) {
            continue;
        }
        if a.starts_with("--") {
            return Err(format!("unknown flag {a}"));
        }
        out.push(a.as_str());
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(list: &[&str]) -> Vec<String> {
        list.iter().map(ToString::to_string).collect()
    }

    #[test]
    fn a_trailing_flag_has_no_value() {
        let a = args(&["capture", "--width"]);
        assert_eq!(value(&a, "--width"), None);
        assert!(present(&a, "--width"));
    }

    #[test]
    fn the_first_occurrence_wins_like_everywhere() {
        let a = args(&["--host", "a", "--host", "b"]);
        assert_eq!(value(&a, "--host"), Some("a"));
    }

    #[test]
    fn a_typo_cannot_become_a_positional() {
        let a = args(&["--mesaured", "board.power"]);
        let err = positionals(&a, &[], &[]).unwrap_err();
        assert!(err.contains("--mesaured"), "{err}");
    }

    #[test]
    fn flags_and_their_values_leave_the_positionals_alone() {
        let a = args(&["--out", "d", "applet", "--unsigned"]);
        let p = positionals(&a, &["--out"], &["--unsigned"]).unwrap();
        assert_eq!(p, vec!["applet"]);
    }
}
