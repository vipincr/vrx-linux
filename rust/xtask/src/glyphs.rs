// `cargo xtask glyphs`: vrx_kit's VrxSymbols from the glyph purpose table
// (plan 0013 D5, G033). The table (standard/glyphs.toml) says what each
// glyph means and where it may appear; the catalogue
// (standard/material-symbols.codepoints) is the font recipe's pinned
// file, vendored, and checked against the recipe's sha256 so the two
// cannot drift. Only tabled glyphs are generated: a glyph missing from
// the table does not exist in Dart. The gate checks the Dart file is
// current, and that every manifest's icon is an applet-icon glyph no
// other applet uses.

use std::collections::BTreeMap;
use std::fmt::Write as _;
use std::path::{Path, PathBuf};

use toml::Value;

const DOMAINS: &[&str] = &["signal", "navigation", "action", "applet-icon"];

fn standard(repo: &Path) -> PathBuf {
    repo.join("flutter/vrx_kit/standard")
}

pub fn table_path(repo: &Path) -> PathBuf {
    standard(repo).join("glyphs.toml")
}

pub fn catalogue_path(repo: &Path) -> PathBuf {
    standard(repo).join("material-symbols.codepoints")
}

pub fn dart_path(repo: &Path) -> PathBuf {
    repo.join("flutter/vrx_kit/lib/src/symbols.dart")
}

fn recipe(repo: &Path) -> Result<PathBuf, String> {
    let dir = repo.join("layer/recipes-fonts/ttf-material-symbols");
    std::fs::read_dir(&dir)
        .map_err(|e| format!("{}: {e}", dir.display()))?
        .flatten()
        .map(|e| e.path())
        .find(|p| p.extension().is_some_and(|x| x == "bb"))
        .ok_or_else(|| format!("{}: no recipe", dir.display()))
}

/// `NAME = "value"` from the font recipe (its one pin).
fn recipe_field(text: &str, key: &str) -> Option<String> {
    text.lines().find_map(|l| {
        let (k, v) = l.split_once('=')?;
        (k.trim() == key).then(|| v.trim().trim_matches('"').to_owned())
    })
}

/// One row of the table.
#[derive(Debug, Clone, PartialEq)]
pub struct Glyph {
    pub purpose: String,
    pub domains: Vec<String>,
}

/// The table, by name, every row checked.
pub fn parse_table(text: &str) -> Result<BTreeMap<String, Glyph>, String> {
    let doc: Value = text.parse().map_err(|e| format!("glyphs.toml: {e}"))?;
    let rows = doc
        .get("glyph")
        .and_then(Value::as_table)
        .ok_or("glyphs.toml has no [glyph.*] rows")?;
    let mut out = BTreeMap::new();
    for (name, row) in rows {
        if !name
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_')
        {
            return Err(format!("glyph {name}: not a symbol name"));
        }
        let purpose = row
            .get("purpose")
            .and_then(Value::as_str)
            .filter(|p| !p.trim().is_empty())
            .ok_or_else(|| format!("glyph {name}: no purpose (say what it means)"))?;
        let domains: Vec<String> = row
            .get("domains")
            .and_then(Value::as_array)
            .ok_or_else(|| format!("glyph {name}: no domains"))?
            .iter()
            .map(|d| {
                d.as_str()
                    .map(str::to_owned)
                    .ok_or_else(|| format!("glyph {name}: a domain is not a string"))
            })
            .collect::<Result<_, _>>()?;
        if domains.is_empty() {
            return Err(format!("glyph {name}: no domains"));
        }
        if let Some(bad) = domains.iter().find(|d| !DOMAINS.contains(&d.as_str())) {
            return Err(format!(
                "glyph {name}: unknown domain {bad} ({})",
                DOMAINS.join(", ")
            ));
        }
        out.insert(
            name.clone(),
            Glyph {
                purpose: purpose.trim().to_owned(),
                domains,
            },
        );
    }
    Ok(out)
}

/// The catalogue: name to codepoint.
pub fn parse_catalogue(text: &str) -> Result<BTreeMap<String, u32>, String> {
    let mut out = BTreeMap::new();
    for line in text.lines().filter(|l| !l.trim().is_empty()) {
        let (name, code) = line
            .split_once(' ')
            .ok_or_else(|| format!("catalogue: {line:?}"))?;
        let code = u32::from_str_radix(code.trim(), 16)
            .map_err(|e| format!("catalogue: {line:?}: {e}"))?;
        out.insert(name.to_owned(), code);
    }
    Ok(out)
}

/// A Dart identifier for a symbol name: a digit first gets a `$`, a
/// reserved word a trailing underscore.
fn ident(name: &str) -> String {
    const RESERVED: &[&str] = &[
        "abstract",
        "as",
        "assert",
        "async",
        "await",
        "break",
        "case",
        "catch",
        "class",
        "const",
        "continue",
        "default",
        "deferred",
        "do",
        "dynamic",
        "else",
        "enum",
        "export",
        "extends",
        "extension",
        "external",
        "factory",
        "false",
        "final",
        "finally",
        "for",
        "get",
        "if",
        "implements",
        "import",
        "in",
        "interface",
        "is",
        "late",
        "library",
        "mixin",
        "new",
        "null",
        "on",
        "operator",
        "part",
        "required",
        "rethrow",
        "return",
        "set",
        "show",
        "static",
        "super",
        "switch",
        "sync",
        "this",
        "throw",
        "true",
        "try",
        "typedef",
        "var",
        "void",
        "while",
        "with",
        "yield",
        "names",
        "named",
    ];
    if name.starts_with(|c: char| c.is_ascii_digit()) {
        format!("${name}")
    } else if RESERVED.contains(&name) {
        format!("{name}_")
    } else {
        name.to_owned()
    }
}

/// The Dart source for the table over the catalogue.
pub fn generate(table: &str, catalogue: &str, commit: &str) -> Result<String, String> {
    let glyphs = parse_table(table)?;
    let codes = parse_catalogue(catalogue)?;
    let mut out = String::new();
    let _ = writeln!(
        out,
        "// GENERATED by `cargo xtask glyphs` from standard/glyphs.toml over the"
    );
    let _ = writeln!(
        out,
        "// Material Symbols catalogue at google/material-design-icons {commit}."
    );
    let _ = writeln!(
        out,
        "// Do not edit: add a row to the table (plan 0013 D5, G033)."
    );
    let _ = writeln!(out);
    let _ = writeln!(
        out,
        "// ignore_for_file: constant_identifier_names, non_constant_identifier_names"
    );
    let _ = writeln!(out);
    let _ = writeln!(
        out,
        "/// vrx's glyphs ({}): the ones the purpose table lists, each for",
        glyphs.len()
    );
    let _ = writeln!(
        out,
        "/// what its row says. The font is the whole Material Symbols set,"
    );
    let _ = writeln!(
        out,
        "/// installed system-wide (ttf-material-symbols); only these are named."
    );
    let _ = writeln!(
        out,
        "/// A manifest's display.icon is one with the applet-icon domain."
    );
    let _ = writeln!(out, "library;");
    let _ = writeln!(out);
    let _ = writeln!(out, "import 'package:flutter/widgets.dart';");
    let _ = writeln!(out);
    let _ = writeln!(out, "const String _family = 'Material Symbols Rounded';");
    let _ = writeln!(out);
    let _ = writeln!(out, "abstract final class VrxSymbols {{");
    let _ = writeln!(
        out,
        "  /// The glyph for a tabled name (`alarm`, `settings`), or null."
    );
    let _ = writeln!(
        out,
        "  static IconData? named(String name) => byName[name];"
    );
    for (name, g) in &glyphs {
        let code = codes.get(name).ok_or_else(|| {
            format!("glyph {name}: not in the Material Symbols catalogue at {commit}")
        })?;
        let _ = writeln!(out);
        let _ = writeln!(out, "  /// {} ({}).", g.purpose, g.domains.join(", "));
        let _ = writeln!(
            out,
            "  static const IconData {} = IconData(0x{code:x}, fontFamily: _family);",
            ident(name)
        );
    }
    let _ = writeln!(out);
    let _ = writeln!(out, "  static const Map<String, IconData> byName = {{");
    for name in glyphs.keys() {
        let _ = writeln!(out, "    '{name}': {},", ident(name));
    }
    let _ = writeln!(out, "  }};");
    let _ = writeln!(out, "}}");
    Ok(out)
}

fn expected(repo: &Path) -> Result<String, String> {
    let recipe = recipe(repo)?;
    let rtext = std::fs::read_to_string(&recipe)
        .map_err(|e| format!("{}: {e}", recipe.display()))?;
    let commit = recipe_field(&rtext, "MSYM_COMMIT")
        .ok_or("the font recipe has no MSYM_COMMIT")?;
    let pinned = recipe_field(&rtext, "SRC_URI[codepoints.sha256sum]")
        .ok_or("the font recipe pins no codepoints sha256")?;
    let catalogue = catalogue_path(repo);
    let have = crate::fonts::sha256(&catalogue)?;
    if have != pinned {
        return Err(format!(
            "{} hashes to {have}, the font recipe pins {pinned}: the catalogue and the font must be the same file",
            catalogue.display()
        ));
    }
    let table = std::fs::read_to_string(table_path(repo))
        .map_err(|e| format!("glyphs.toml: {e}"))?;
    let cat = std::fs::read_to_string(&catalogue)
        .map_err(|e| format!("{}: {e}", catalogue.display()))?;
    generate(&table, &cat, &commit)
}

/// `cargo xtask glyphs`.
pub fn run(repo: &Path) -> Result<(), String> {
    let dart = expected(repo)?;
    let path = dart_path(repo);
    std::fs::write(&path, dart).map_err(|e| format!("{}: {e}", path.display()))?;
    println!("glyphs: wrote {}", path.display());
    Ok(())
}

/// The gate: the Dart file is the table's.
pub fn is_current(repo: &Path) -> Result<bool, String> {
    let want = expected(repo)?;
    Ok(std::fs::read_to_string(dart_path(repo)).is_ok_and(|have| have == want))
}

/// The applet-icon rule over (applet, icon) pairs: every icon a tabled
/// applet-icon glyph, no two applets with one.
pub fn check_icons(
    glyphs: &BTreeMap<String, Glyph>,
    icons: &[(String, String)],
) -> Vec<String> {
    let mut faults = Vec::new();
    let mut seen: BTreeMap<&str, &str> = BTreeMap::new();
    for (applet, icon) in icons {
        match glyphs.get(icon) {
            None => {
                faults.push(format!("{applet}: icon {icon} is not in the glyph table"))
            }
            Some(g) if !g.domains.iter().any(|d| d == "applet-icon") => {
                faults.push(format!(
                    "{applet}: icon {icon} is not an applet-icon glyph ({})",
                    g.purpose
                ));
            }
            Some(_) => {}
        }
        if let Some(other) = seen.insert(icon, applet) {
            faults.push(format!(
                "{applet}: icon {icon} is already {other}'s (one icon per applet)"
            ));
        }
    }
    faults
}

/// The repo's manifests' icons, checked.
pub fn check_manifests(repo: &Path) -> Result<Vec<String>, String> {
    let table = std::fs::read_to_string(table_path(repo))
        .map_err(|e| format!("glyphs.toml: {e}"))?;
    let glyphs = parse_table(&table)?;
    let mut icons = Vec::new();
    let mut dirs: Vec<PathBuf> = std::fs::read_dir(repo.join("applets"))
        .map_err(|e| format!("applets: {e}"))?
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.join("manifest.toml").is_file())
        .collect();
    dirs.sort();
    for dir in dirs {
        let path = dir.join("manifest.toml");
        let text = std::fs::read_to_string(&path)
            .map_err(|e| format!("{}: {e}", path.display()))?;
        let doc: Value = text
            .parse()
            .map_err(|e| format!("{}: {e}", path.display()))?;
        let id = doc
            .get("applet")
            .and_then(|a| a.get("id"))
            .and_then(Value::as_str)
            .unwrap_or("?")
            .to_owned();
        if let Some(icon) = doc
            .get("applet")
            .and_then(|a| a.get("display"))
            .and_then(|d| d.get("icon"))
            .and_then(Value::as_str)
        {
            icons.push((id, icon.to_owned()));
        }
    }
    Ok(check_icons(&glyphs, &icons))
}

#[cfg(test)]
mod tests {
    use super::*;

    const TABLE: &str = r#"
[glyph.alarm]
purpose = "An alarm"
domains = ["action", "applet-icon"]
[glyph.10k]
purpose = "Ten thousand"
domains = ["signal"]
[glyph.class]
purpose = "A class"
domains = ["navigation"]
"#;
    const CATALOGUE: &str = "10k e951\nalarm e855\nclass e86e\nzoom_in e8ff\n";

    #[test]
    fn only_tabled_glyphs_are_generated_each_with_its_purpose() {
        let dart = generate(TABLE, CATALOGUE, "abc").unwrap();
        assert!(dart.contains("/// An alarm (action, applet-icon).\n  static const IconData alarm = IconData(0xe855"));
        assert!(dart.contains("static const IconData $10k = IconData(0xe951"));
        assert!(dart.contains("static const IconData class_ = IconData(0xe86e"));
        assert!(
            !dart.contains("zoom_in"),
            "a glyph outside the table does not exist in Dart"
        );
    }

    #[test]
    fn a_row_without_a_purpose_or_with_an_unknown_domain_or_glyph_is_refused() {
        assert!(parse_table("[glyph.alarm]\ndomains = [\"action\"]\n")
            .unwrap_err()
            .contains("no purpose"));
        assert!(parse_table(
            "[glyph.alarm]\npurpose = \"x\"\ndomains = [\"decoration\"]\n"
        )
        .unwrap_err()
        .contains("unknown domain"));
        let missing = "[glyph.nope]\npurpose = \"x\"\ndomains = [\"signal\"]\n";
        assert!(generate(missing, CATALOGUE, "abc")
            .unwrap_err()
            .contains("not in the Material Symbols catalogue"));
    }

    #[test]
    fn two_applets_with_one_icon_or_a_non_icon_glyph_are_refused_g033() {
        let glyphs = parse_table(TABLE).unwrap();
        let ok = [("clock".to_owned(), "alarm".to_owned())];
        assert!(check_icons(&glyphs, &ok).is_empty());
        let twice = [
            ("manage".to_owned(), "alarm".to_owned()),
            ("web".to_owned(), "alarm".to_owned()),
        ];
        let faults = check_icons(&glyphs, &twice);
        assert!(
            faults.iter().any(|f| f.contains("already manage's")),
            "{faults:?}"
        );
        let signal = [("x".to_owned(), "10k".to_owned())];
        assert!(check_icons(&glyphs, &signal)[0].contains("not an applet-icon glyph"));
        let untabled = [("x".to_owned(), "zoom_in".to_owned())];
        assert!(check_icons(&glyphs, &untabled)[0].contains("not in the glyph table"));
    }
}
