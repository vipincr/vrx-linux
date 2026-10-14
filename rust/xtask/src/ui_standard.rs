// `cargo xtask ui-standard`: vrx_kit's tables from the vrx UI standard
// (plan 0009 D1) and vrx's motion overlay (plan 0017 D4). The standard is
// evrx-rt's, vendored unchanged at the commit standard/PIN names; the
// overlay, standard/vrx-motion.toml, is ours and adds beside it. This reads
// both and writes flutter/vrx_kit/lib/src/ui_standard.g.dart. Nothing here computes a
// colour: the schemes were generated in evrx-rt (make_ui_schemes.py) and
// are copied, so the C runtime and the Flutter kit draw the same values.
// The gate (G018) checks the pin and that the Dart file is current.

use std::fmt::Write as _;
use std::path::{Path, PathBuf};

use toml::Value;

fn kit(repo: &Path) -> PathBuf {
    repo.join("flutter/vrx_kit")
}

pub fn standard_path(repo: &Path) -> PathBuf {
    kit(repo).join("standard/vrx-ui-standard.toml")
}

pub fn overlay_path(repo: &Path) -> PathBuf {
    kit(repo).join("standard/vrx-motion.toml")
}

pub fn pin_path(repo: &Path) -> PathBuf {
    kit(repo).join("standard/PIN")
}

pub fn dart_path(repo: &Path) -> PathBuf {
    kit(repo).join("lib/src/ui_standard.g.dart")
}

/// `key = "value"` from the PIN file.
fn pin_field(pin: &str, key: &str) -> Option<String> {
    pin.lines().find_map(|l| {
        let (k, v) = l.split_once('=')?;
        (k.trim() == key).then(|| v.trim().trim_matches('"').to_owned())
    })
}

/// snake_case to lowerCamel: `on_primary_container` to `onPrimaryContainer`.
fn camel(name: &str) -> String {
    let mut out = String::new();
    let mut up = false;
    for c in name.chars() {
        if c == '_' {
            up = true;
        } else if up {
            out.extend(c.to_uppercase());
            up = false;
        } else {
            out.push(c);
        }
    }
    out
}

fn table<'a>(
    v: &'a Value,
    key: &str,
) -> Result<&'a toml::map::Map<String, Value>, String> {
    v.get(key)
        .and_then(Value::as_table)
        .ok_or_else(|| format!("the standard has no [{key}]"))
}

fn array<'a>(v: &'a Value, key: &str) -> Result<&'a Vec<Value>, String> {
    v.get(key)
        .and_then(Value::as_array)
        .ok_or_else(|| format!("the standard has no {key} array"))
}

fn str_of<'a>(v: &'a Value, key: &str) -> Result<&'a str, String> {
    v.get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| format!("{key}: not a string"))
}

fn int_of(v: &Value, key: &str) -> Result<i64, String> {
    v.get(key)
        .and_then(Value::as_integer)
        .ok_or_else(|| format!("{key}: not an integer"))
}

/// A scheme's 32 colours: "#RRGGBB" strings to 0xFFRRGGBB.
fn colours(v: &Value, what: &str, count: usize) -> Result<Vec<u32>, String> {
    let list = v
        .as_array()
        .ok_or_else(|| format!("{what}: not an array"))?;
    if list.len() != count {
        return Err(format!(
            "{what}: {} colours, the slots are {count}",
            list.len()
        ));
    }
    list.iter()
        .map(|c| {
            let s = c.as_str().ok_or_else(|| format!("{what}: not a string"))?;
            let hex = s.strip_prefix('#').filter(|h| h.len() == 6);
            hex.and_then(|h| u32::from_str_radix(h, 16).ok())
                .map(|rgb| 0xFF00_0000 | rgb)
                .ok_or_else(|| format!("{what}: {s:?} is not #RRGGBB"))
        })
        .collect()
}

/// A grey map's 32 levels.
fn greys(v: &Value, what: &str, count: usize) -> Result<Vec<u8>, String> {
    let list = v
        .as_array()
        .ok_or_else(|| format!("{what}: not an array"))?;
    if list.len() != count {
        return Err(format!(
            "{what}: {} levels, the slots are {count}",
            list.len()
        ));
    }
    list.iter()
        .map(|g| {
            g.as_integer()
                .and_then(|n| u8::try_from(n).ok())
                .ok_or_else(|| format!("{what}: a level outside 0..255"))
        })
        .collect()
}

fn num(v: &Value, what: &str) -> Result<f64, String> {
    v.as_float()
        .or_else(|| v.as_integer().map(|i| i as f64))
        .ok_or_else(|| format!("{what}: not a number"))
}

fn opt_num(row: &Value, key: &str, what: &str) -> Result<Option<f64>, String> {
    row.get(key)
        .map(|v| num(v, &format!("{what}.{key}")))
        .transpose()
}

/// A Dart string literal for `s` (single quotes; the standard's prose has
/// no `$` or `\`, and a stray one is escaped rather than trusted).
fn dart_str(s: &str) -> String {
    let body = s
        .replace('\\', "\\\\")
        .replace('\'', "\\'")
        .replace('$', "\\$");
    format!("'{body}'")
}

/// The overlay's top-level tables, and no others: a typo is refused.
const OVERLAY_TABLES: &[&str] = &[
    "set",
    "superseded",
    "micro",
    "tier_of_class",
    "light",
    "tolerance",
    "ceiling",
    "input",
];

/// The motion half of the generated file (plan 0017 D4): both spring sets,
/// every micro row of the standard plus the overlay's, the tiers and the
/// class-to-tier map, the engine's tolerance, the ceilings and the input
/// constants. The overlay adds; a key the standard already has is refused.
fn motion(w: &mut String, doc: &Value, overlay: &Value) -> Result<(), String> {
    let overlay_tables = overlay.as_table().ok_or("vrx-motion.toml: not a table")?;
    for name in overlay_tables.keys() {
        if !OVERLAY_TABLES.contains(&name.as_str()) {
            return Err(format!(
                "vrx-motion.toml: [{name}] is not a table the overlay may carry"
            ));
        }
    }
    // the allow-list holds no table the standard has but `micro`, which adds
    // rows beside the standard's (a row it already has is refused below)

    // --- the spring sets: stiffness at mass 1, and the damping coefficient
    // Flutter's SpringDescription takes (ratio x 2 sqrt(k m))
    let springs = doc.get("springs").ok_or("the standard has no [springs]")?;
    let mass = springs
        .get("mass")
        .and_then(Value::as_integer)
        .ok_or("springs.mass: not an integer")? as f64;
    let sets = ["standard", "expressive"];
    let tokens: Vec<String> = table(springs, "standard")?.keys().cloned().collect();
    let _ = writeln!(
        w,
        "// [springs.*], at mass {mass:?}: both sets, the same six tokens"
    );
    let _ = writeln!(w, "enum VrxSpringSet {{");
    for set in sets {
        let _ = writeln!(w, "  {set},");
    }
    let _ = writeln!(w, "}}");
    let _ = writeln!(w);
    let _ = writeln!(w, "enum VrxSpringToken {{");
    for t in &tokens {
        let _ = writeln!(w, "  {},", camel(t));
    }
    let _ = writeln!(w, "}}");
    let _ = writeln!(w);
    let _ = writeln!(
        w,
        "/// A spring: stiffness at mass 1 and Flutter's damping coefficient."
    );
    let _ = writeln!(w, "class VrxSpringRow {{");
    let _ = writeln!(w, "  const VrxSpringRow(this.stiffness, this.damping);");
    let _ = writeln!(w, "  final double stiffness;");
    let _ = writeln!(w, "  final double damping;");
    let _ = writeln!(w, "}}");
    let _ = writeln!(w);
    let _ = writeln!(w, "const double vrxSpringMass = {mass:?};");
    let _ = writeln!(w);
    let _ = writeln!(
        w,
        "const Map<VrxSpringSet, Map<VrxSpringToken, VrxSpringRow>> vrxSprings = {{"
    );
    for set in sets {
        let rows = table(springs, set)?;
        if rows.keys().ne(tokens.iter()) {
            return Err(format!(
                "springs.{set}: its tokens are not those of springs.standard"
            ));
        }
        let _ = writeln!(w, "  VrxSpringSet.{set}: {{");
        for (key, spring) in rows {
            let k = num(
                spring
                    .get("stiffness")
                    .ok_or_else(|| format!("springs.{set}.{key}: no stiffness"))?,
                &format!("springs.{set}.{key}.stiffness"),
            )?;
            let ratio = num(
                spring
                    .get("damping")
                    .ok_or_else(|| format!("springs.{set}.{key}: no damping"))?,
                &format!("springs.{set}.{key}.damping"),
            )?;
            let _ = writeln!(
                w,
                "    VrxSpringToken.{}: VrxSpringRow({k:?}, {:.5}),",
                camel(key),
                ratio * 2.0 * (k * mass).sqrt()
            );
        }
        let _ = writeln!(w, "  }},");
    }
    let _ = writeln!(w, "}};");
    let _ = writeln!(w);

    // --- the micro rows: the standard's (less the superseded) and the overlay's
    let vendored = table(doc, "micro")?;
    let superseded: Vec<&String> = overlay
        .get("superseded")
        .and_then(Value::as_table)
        .map(|t| t.keys().collect())
        .unwrap_or_default();
    for name in &superseded {
        if !vendored.contains_key(name.as_str()) {
            return Err(format!(
                "[superseded] {name}: the standard has no such micro row"
            ));
        }
    }
    let added = overlay
        .get("micro")
        .and_then(Value::as_table)
        .cloned()
        .unwrap_or_default();
    for name in added.keys() {
        if vendored.contains_key(name) {
            return Err(format!("vrx-motion.toml: [micro.{name}] redefines a row of the standard (name it in [superseded] to replace it)"));
        }
    }
    let mut rows: Vec<(&String, &Value)> = vendored
        .iter()
        .filter(|(k, _)| !superseded.contains(k))
        .collect();
    rows.extend(added.iter());
    let set_of = table(overlay, "set")?;
    for (name, _) in &rows {
        if !set_of.contains_key(name.as_str()) {
            return Err(format!(
                "vrx-motion.toml: [set] has no entry for the micro row {name:?}"
            ));
        }
    }
    for name in set_of.keys() {
        if !rows.iter().any(|(r, _)| *r == name) {
            return Err(format!(
                "vrx-motion.toml: [set] names {name:?}, which is no micro row"
            ));
        }
    }
    let token_ok = |t: &str, what: &str| -> Result<(), String> {
        if tokens.iter().any(|x| x == t) {
            Ok(())
        } else {
            Err(format!("{what}: {t:?} is not a spring token"))
        }
    };
    let _ = writeln!(
        w,
        "/// The micro rows (the standard's, and the overlay's), by name."
    );
    let _ = writeln!(w, "enum VrxMicro {{");
    for (name, _) in &rows {
        let _ = writeln!(w, "  {},", camel(name));
    }
    let _ = writeln!(w, "}}");
    let _ = writeln!(w);
    let _ = writeln!(w, "/// What a thing a person acts on does: its tokens (read from [set]'s spring set), scale in");
    let _ = writeln!(
        w,
        "/// permille of its own size, and the distances of an arrival."
    );
    let _ = writeln!(w, "class VrxMicroRow {{");
    let _ = writeln!(w, "  const VrxMicroRow({{");
    let _ = writeln!(w, "    required this.set,");
    let _ = writeln!(w, "    required this.token,");
    let _ = writeln!(w, "    required this.follow,");
    let _ = writeln!(w, "    this.scalePermille,");
    let _ = writeln!(w, "    this.shiftPx,");
    let _ = writeln!(w, "    this.shiftMm,");
    let _ = writeln!(w, "    this.staggerMs,");
    let _ = writeln!(w, "    required this.moves,");
    let _ = writeln!(w, "    required this.still,");
    let _ = writeln!(w, "  }});");
    let _ = writeln!(w, "  final VrxSpringSet set;");
    let _ = writeln!(w, "  final VrxSpringToken token;");
    let _ = writeln!(w, "  final VrxSpringToken follow;");
    let _ = writeln!(w, "  final int? scalePermille;");
    let _ = writeln!(w, "  final double? shiftPx;");
    let _ = writeln!(w, "  final double? shiftMm;");
    let _ = writeln!(w, "  final int? staggerMs;");
    let _ = writeln!(w, "  final String moves;");
    let _ = writeln!(w, "  final String still;");
    let _ = writeln!(w, "}}");
    let _ = writeln!(w);
    let _ = writeln!(w, "const Map<VrxMicro, VrxMicroRow> vrxMicro = {{");
    for (name, row) in &rows {
        let what = format!("micro.{name}");
        let set = set_of[name.as_str()]
            .as_str()
            .filter(|s| sets.contains(s))
            .ok_or_else(|| format!("[set].{name}: not standard or expressive"))?;
        let token = str_of(row, "token").map_err(|e| format!("{what}: {e}"))?;
        let follow = str_of(row, "follow").map_err(|e| format!("{what}: {e}"))?;
        token_ok(token, &format!("{what}.token"))?;
        token_ok(follow, &format!("{what}.follow"))?;
        let mut extra = String::new();
        if let Some(v) = row.get("scale") {
            let _ = write!(
                extra,
                " scalePermille: {},",
                v.as_integer()
                    .ok_or_else(|| format!("{what}.scale: not an integer"))?
            );
        }
        if let Some(v) = opt_num(row, "shift_px", &what)? {
            let _ = write!(extra, " shiftPx: {v:?},");
        }
        if let Some(v) = opt_num(row, "shift_mm", &what)? {
            let _ = write!(extra, " shiftMm: {v:?},");
        }
        if let Some(v) = row.get("stagger_ms") {
            let _ = write!(
                extra,
                " staggerMs: {},",
                v.as_integer()
                    .ok_or_else(|| format!("{what}.stagger_ms: not an integer"))?
            );
        }
        let _ = writeln!(
            w,
            "  VrxMicro.{}: VrxMicroRow(set: VrxSpringSet.{set}, token: VrxSpringToken.{}, follow: VrxSpringToken.{},{extra} moves: {}, still: {}),",
            camel(name),
            camel(token),
            camel(follow),
            dart_str(str_of(row, "moves").map_err(|e| format!("{what}: {e}"))?),
            dart_str(str_of(row, "still").map_err(|e| format!("{what}: {e}"))?),
        );
    }
    let _ = writeln!(w, "}};");
    let _ = writeln!(w);

    // --- the tiers and the class's tier
    let tiers: Vec<&String> = table(doc, "tier")?.keys().collect();
    let _ = writeln!(
        w,
        "/// What a build promises (the standard's [tier.*]); the engine applies it."
    );
    let _ = writeln!(w, "enum VrxTier {{");
    for t in &tiers {
        let _ = writeln!(w, "  {},", camel(t));
    }
    let _ = writeln!(w, "}}");
    let _ = writeln!(w);
    let _ = writeln!(w, "const Map<String, VrxTier> vrxTierNames = {{");
    for t in &tiers {
        let _ = writeln!(w, "  '{t}': VrxTier.{},", camel(t));
    }
    let _ = writeln!(w, "}};");
    let _ = writeln!(w);
    let by_class = table(overlay, "tier_of_class")?;
    let classes = table(doc, "class")?;
    if by_class.keys().ne(classes.keys()) {
        return Err("vrx-motion.toml: [tier_of_class] must name every display class of the standard, in its order".into());
    }
    let _ = writeln!(
        w,
        "/// The tier each display class gets from the build (D5)."
    );
    let _ = writeln!(w, "const Map<VrxDisplayClass, VrxTier> vrxTierOfClass = {{");
    for (class, tier) in by_class {
        let tier = tier
            .as_str()
            .filter(|t| tiers.iter().any(|x| x.as_str() == *t))
            .ok_or_else(|| {
                format!("[tier_of_class].{class}: not a tier of the standard")
            })?;
        let _ = writeln!(
            w,
            "  VrxDisplayClass.{}: VrxTier.{},",
            camel(class),
            camel(tier)
        );
    }
    let _ = writeln!(w, "}};");
    let _ = writeln!(w);

    // --- the light tier's scale limit (D5)
    let light = table(overlay, "light")?;
    let _ = writeln!(
        w,
        "/// At the light tier a scale animates up to this far from rest, in permille (plan 0017 D5)."
    );
    let _ = writeln!(
        w,
        "const int vrxLightScaleLimitPermille = {};",
        light
            .get("scale_limit_permille")
            .and_then(Value::as_integer)
            .ok_or("[light].scale_limit_permille: not an integer")?
    );
    let _ = writeln!(w);

    // --- tolerance (D3)
    let tol = table(overlay, "tolerance")?;
    let _ = writeln!(
        w,
        "// [tolerance]: pixels, never Flutter's default 1e-3 (plan 0017 D3)"
    );
    for (key, name) in [
        ("distance_px", "vrxToleranceDistancePx"),
        ("velocity_px_per_s", "vrxToleranceVelocityPxPerS"),
        ("alpha_step", "vrxToleranceAlphaStep"),
        ("alpha_velocity", "vrxToleranceAlphaVelocity"),
    ] {
        let v = num(
            tol.get(key)
                .ok_or_else(|| format!("[tolerance] has no {key}"))?,
            &format!("tolerance.{key}"),
        )?;
        let _ = writeln!(w, "const double {name} = {v:?};");
    }
    let _ = writeln!(w);

    // --- ceilings (D11)
    let _ = writeln!(
        w,
        "/// A row's ceiling at its reference travel (plan 0017 D11, G051)."
    );
    let _ = writeln!(w, "class VrxCeiling {{");
    let _ = writeln!(w, "  const VrxCeiling(this.name, this.row, this.useFollow, this.travelPx, this.arriveMs, this.settleMs);");
    let _ = writeln!(w, "  final String name;");
    let _ = writeln!(w, "  final VrxMicro row;");
    let _ = writeln!(w, "  final bool useFollow;");
    let _ = writeln!(w, "  final double travelPx;");
    let _ = writeln!(w, "  final int arriveMs;");
    let _ = writeln!(w, "  final int settleMs;");
    let _ = writeln!(w, "}}");
    let _ = writeln!(w);
    let _ = writeln!(w, "const List<VrxCeiling> vrxCeilings = [");
    for (name, c) in table(overlay, "ceiling")? {
        let what = format!("ceiling.{name}");
        let row = str_of(c, "row").map_err(|e| format!("{what}: {e}"))?;
        if !rows.iter().any(|(r, _)| r.as_str() == row) {
            return Err(format!("{what}: row {row:?} is no micro row"));
        }
        let follow = match c.get("use").and_then(Value::as_str) {
            None | Some("token") => false,
            Some("follow") => true,
            Some(other) => {
                return Err(format!("{what}.use: {other:?} is not token or follow"))
            }
        };
        let travel = num(
            c.get("travel_px")
                .ok_or_else(|| format!("{what}: no travel_px"))?,
            &what,
        )?;
        let _ = writeln!(
            w,
            "  VrxCeiling('{name}', VrxMicro.{}, {follow}, {travel:?}, {}, {}),",
            camel(row),
            int_of(c, "arrive_ms").map_err(|e| format!("{what}: {e}"))?,
            int_of(c, "settle_ms").map_err(|e| format!("{what}: {e}"))?,
        );
    }
    let _ = writeln!(w, "];");
    let _ = writeln!(w);

    // --- input (D12)
    let input = table(overlay, "input")?;
    let _ = writeln!(
        w,
        "/// GestureBinding.samplingOffset, in ms (plan 0017 D12; provisional until measured)."
    );
    let _ = writeln!(
        w,
        "const int vrxSamplingOffsetMs = {};",
        input
            .get("sampling_offset_ms")
            .and_then(Value::as_integer)
            .ok_or("[input].sampling_offset_ms: not an integer")?
    );
    let _ = writeln!(w);
    Ok(())
}

/// The Dart source for the standard's text.
pub fn generate(text: &str, overlay_text: &str, commit: &str) -> Result<String, String> {
    let doc: Value = text.parse().map_err(|e| format!("the standard: {e}"))?;
    let overlay: Value = overlay_text
        .parse()
        .map_err(|e| format!("vrx-motion.toml: {e}"))?;
    let colour = doc.get("colour").ok_or("the standard has no [colour]")?;

    // the slots, in the file's order: the order is the index (plan 0062 D1)
    let slots: Vec<String> = array(colour, "slot")?
        .iter()
        .map(|s| str_of(s, "name").map(str::to_owned))
        .collect::<Result<_, _>>()?;
    let n = slots.len();
    let index = |name: &str| {
        slots
            .iter()
            .position(|s| s == name)
            .ok_or_else(|| format!("no slot {name:?}"))
    };
    // a slot has an on-colour when the next slot is on_<it> (ui_kit's
    // UI_COLOR_HAS_ON_MASK, derived the same way)
    let mut has_on: u64 = 0;
    for (i, s) in slots.iter().enumerate() {
        if slots
            .get(i + 1)
            .is_some_and(|next| *next == format!("on_{s}"))
        {
            has_on |= 1 << i;
        }
    }

    let mut out = String::new();
    let w = &mut out;
    let _ = writeln!(
        w,
        "// GENERATED by `cargo xtask ui-standard` from standard/vrx-ui-standard.toml,"
    );
    let _ = writeln!(
        w,
        "// evrx-rt {commit}. Do not edit: bump the pin and run it (plan 0009 D1)."
    );
    let _ = writeln!(w, "//");
    let _ = writeln!(
        w,
        "// The colour slots, the 20 schemes, the grey maps, the display classes and the"
    );
    let _ = writeln!(
        w,
        "// contrast floors of the vrx UI standard, exactly as the C runtime has them."
    );
    let _ = writeln!(w);
    let _ = writeln!(w, "import 'dart:ui' show Color;");
    let _ = writeln!(w);
    let _ = writeln!(w, "/// What a colour is FOR (plan 0062 D1). The index is the column of every table below.");
    let _ = writeln!(w, "enum VrxSlot {{");
    for s in &slots {
        let _ = writeln!(w, "  {},", camel(s));
    }
    let _ = writeln!(w, "}}");
    let _ = writeln!(w);
    let _ = writeln!(
        w,
        "/// Each slot by name, over a lookup by slot (VrxColors mixes this in)."
    );
    let _ = writeln!(w, "mixin VrxSlotNames {{");
    let _ = writeln!(w, "  Color operator [](VrxSlot slot);");
    for s in &slots {
        let c = camel(s);
        let _ = writeln!(w, "  Color get {c} => this[VrxSlot.{c}];");
    }
    let _ = writeln!(w, "}}");
    let _ = writeln!(w);
    let _ = writeln!(
        w,
        "/// The slots with an on-colour (the next slot), as a mask over the index."
    );
    let _ = writeln!(w, "const int vrxSlotHasOnMask = 0x{has_on:08X};");
    let _ = writeln!(w);

    // the physical numbers: millimetres, points, device pixels (the kit
    // converts; plan 0009 Part C)
    for (section, prefix) in [
        ("spacing_mm", "vrxSpacingMm"),
        ("radius_mm", "vrxRadiusMm"),
        ("size_mm", "vrxSizeMm"),
        ("device_px", "vrxDevicePx"),
        ("gesture", "vrxGesture"),
        ("type_pt", "vrxTypePt"),
    ] {
        let _ = writeln!(w, "// [{section}]");
        for (key, value) in table(&doc, section)? {
            let number = value
                .as_float()
                .or_else(|| value.as_integer().map(|i| i as f64))
                .ok_or_else(|| format!("{section}.{key}: not a number"))?;
            let name = format!("{prefix}{}", camel(&format!("_{key}")));
            let _ = writeln!(w, "const double {name} = {number:?};");
        }
        let _ = writeln!(w);
    }
    motion(w, &doc, &overlay)?;

    // the schemes, numbered 1.. in the file's [schemes] order
    let schemes = table(&doc, "schemes")?;
    let _ = writeln!(w, "/// One scheme: a seed hue and a harmony rule, each slot in light and dark (0xAARRGGBB).");
    let _ = writeln!(w, "class VrxSchemeRow {{");
    let _ = writeln!(
        w,
        "  const VrxSchemeRow(this.id, this.seed, this.rule, this.light, this.dark);"
    );
    let _ = writeln!(w, "  final int id;");
    let _ = writeln!(w, "  final String seed;");
    let _ = writeln!(w, "  final String rule;");
    let _ = writeln!(w, "  final List<int> light;");
    let _ = writeln!(w, "  final List<int> dark;");
    let _ = writeln!(w, "}}");
    let _ = writeln!(w);
    let _ = writeln!(w, "const List<VrxSchemeRow> vrxSchemes = [");
    let mut ids: Vec<u32> = schemes
        .keys()
        .map(|k| {
            k.parse()
                .map_err(|_| format!("[schemes.{k}]: not a number"))
        })
        .collect::<Result<_, _>>()?;
    ids.sort_unstable();
    for (expect, id) in (1u32..).zip(&ids) {
        if *id != expect {
            return Err(format!(
                "schemes are not numbered 1..: found {id} where {expect} belongs"
            ));
        }
        let row = &schemes[&id.to_string()];
        let seed = str_of(row, "seed")?;
        let rule = str_of(row, "rule")?;
        let light = colours(
            row.get("light").ok_or("no light")?,
            &format!("schemes.{id}.light"),
            n,
        )?;
        let dark = colours(
            row.get("dark").ok_or("no dark")?,
            &format!("schemes.{id}.dark"),
            n,
        )?;
        let hex = |v: &[u32]| {
            v.iter()
                .map(|c| format!("0x{c:08X}"))
                .collect::<Vec<_>>()
                .join(", ")
        };
        let _ = writeln!(
            w,
            "  VrxSchemeRow({id}, '{seed}', '{rule}', [{}], [{}]),",
            hex(&light),
            hex(&dark)
        );
    }
    let _ = writeln!(w, "];");
    let _ = writeln!(w);

    // the grey maps a class can take
    let maps = table(&doc, "map")?;
    for name in ["grey4", "grey2"] {
        let map = maps.get(name).ok_or_else(|| format!("no [map.{name}]"))?;
        let levels = greys(
            map.get("light").ok_or("no light")?,
            &format!("map.{name}.light"),
            n,
        )?;
        let list = levels
            .iter()
            .map(|g| format!("0x{g:02X}"))
            .collect::<Vec<_>>()
            .join(", ");
        let _ = writeln!(
            w,
            "/// Each slot's grey on a {name} panel (r = g = b), light polarity."
        );
        let _ = writeln!(
            w,
            "const List<int> vrxMap{} = [{list}];",
            camel(&format!("_{name}"))
        );
        let _ = writeln!(w);
    }

    // the display classes (plan 0062 D14)
    let classes = table(&doc, "class")?;
    let _ = writeln!(
        w,
        "/// The kinds of panel, and what differs between them (plan 0062 D14)."
    );
    let _ = writeln!(w, "enum VrxDisplayClass {{");
    for name in classes.keys() {
        let _ = writeln!(w, "  {},", camel(name));
    }
    let _ = writeln!(w, "}}");
    let _ = writeln!(w);
    let _ = writeln!(w, "class VrxClassRow {{");
    let _ = writeln!(w, "  const VrxClassRow({{required this.pressedLayerPermille, required this.liveMinMs, required this.ambientMinMs, required this.dither}});");
    let _ = writeln!(w, "  final int pressedLayerPermille;");
    let _ = writeln!(w, "  final int liveMinMs;");
    let _ = writeln!(w, "  final int ambientMinMs;");
    let _ = writeln!(w, "  final String dither;");
    let _ = writeln!(w, "}}");
    let _ = writeln!(w);
    let _ = writeln!(
        w,
        "/// The file's name for each class (what a board declares)."
    );
    let _ = writeln!(w, "const Map<String, VrxDisplayClass> vrxClassNames = {{");
    for name in classes.keys() {
        let _ = writeln!(w, "  '{name}': VrxDisplayClass.{},", camel(name));
    }
    let _ = writeln!(w, "}};");
    let _ = writeln!(w);
    let _ = writeln!(w, "const Map<VrxDisplayClass, VrxClassRow> vrxClasses = {{");
    for (name, row) in classes {
        let _ = writeln!(
            w,
            "  VrxDisplayClass.{}: VrxClassRow(pressedLayerPermille: {}, liveMinMs: {}, ambientMinMs: {}, dither: '{}'),",
            camel(name),
            int_of(row, "pressed_layer_permille")?,
            int_of(row, "live_min_ms")?,
            int_of(row, "ambient_min_ms")?,
            str_of(row, "dither")?,
        );
    }
    let _ = writeln!(w, "}};");
    let _ = writeln!(w);

    // the contrast floors the tables were generated to hold
    let _ = writeln!(
        w,
        "/// A pair of slots read together, and its WCAG contrast floor times 100."
    );
    let _ = writeln!(w, "class VrxPairFloor {{");
    let _ = writeln!(w, "  const VrxPairFloor(this.bg, this.fg, this.minX100);");
    let _ = writeln!(w, "  final VrxSlot bg;");
    let _ = writeln!(w, "  final VrxSlot fg;");
    let _ = writeln!(w, "  final int minX100;");
    let _ = writeln!(w, "}}");
    let _ = writeln!(w);
    let _ = writeln!(w, "const List<VrxPairFloor> vrxPairFloors = [");
    for p in array(colour, "pair")? {
        let bg = index(str_of(p, "bg")?)?;
        let fg = index(str_of(p, "fg")?)?;
        let _ = writeln!(
            w,
            "  VrxPairFloor(VrxSlot.{}, VrxSlot.{}, {}),",
            camel(&slots[bg]),
            camel(&slots[fg]),
            int_of(p, "min")?
        );
    }
    let _ = writeln!(w, "];");
    Ok(out)
}

/// The overlay's text, and its hash.
fn overlay_text(repo: &Path) -> Result<(String, String), String> {
    let path = overlay_path(repo);
    let text =
        std::fs::read_to_string(&path).map_err(|e| format!("{}: {e}", path.display()))?;
    Ok((text, crate::fonts::sha256(&path)?))
}

/// The Dart the vendored standard and the overlay should produce, and
/// whether the pin holds. [repin] rewrites the overlay's line in PIN first
/// (the overlay is ours: `cargo xtask ui-standard` is how an edit of it is
/// recorded); the vendored file's hash is never rewritten.
pub fn expected(repo: &Path, repin: bool) -> Result<String, String> {
    let path = standard_path(repo);
    let text =
        std::fs::read_to_string(&path).map_err(|e| format!("{}: {e}", path.display()))?;
    let mut pin = std::fs::read_to_string(pin_path(repo))
        .map_err(|e| format!("standard/PIN: {e}"))?;
    let want = pin_field(&pin, "sha256").ok_or("standard/PIN has no sha256")?;
    let got = crate::fonts::sha256(&path)?;
    if got != want {
        return Err(format!(
            "standard/vrx-ui-standard.toml hashes to {got}, standard/PIN says {want}: the file was edited, or the pin not bumped with it"
        ));
    }
    let (overlay, overlay_got) = overlay_text(repo)?;
    if repin && pin_field(&pin, "overlay_sha256").as_deref() != Some(overlay_got.as_str())
    {
        pin = pin
            .lines()
            .filter(|l| !l.trim_start().starts_with("overlay_sha256"))
            .collect::<Vec<_>>()
            .join("\n");
        pin.push_str(&format!("\noverlay_sha256 = \"{overlay_got}\"\n"));
        std::fs::write(pin_path(repo), &pin).map_err(|e| format!("standard/PIN: {e}"))?;
    }
    let overlay_want =
        pin_field(&pin, "overlay_sha256").ok_or("standard/PIN has no overlay_sha256")?;
    if overlay_got != overlay_want {
        return Err(format!(
            "standard/vrx-motion.toml hashes to {overlay_got}, standard/PIN says {overlay_want}: run `cargo xtask ui-standard` to record the edit"
        ));
    }
    let commit = pin_field(&pin, "commit").ok_or("standard/PIN has no commit")?;
    generate(&text, &overlay, &commit)
}

/// `cargo xtask ui-standard`.
pub fn run(repo: &Path) -> Result<(), String> {
    let dart = expected(repo, true)?;
    let path = dart_path(repo);
    std::fs::write(&path, dart).map_err(|e| format!("{}: {e}", path.display()))?;
    println!("ui-standard: wrote {}", path.display());
    Ok(())
}

/// The gate: the pin holds and the Dart file is current.
pub fn is_current(repo: &Path) -> Result<bool, String> {
    let want = expected(repo, false)?;
    Ok(std::fs::read_to_string(dart_path(repo)).is_ok_and(|have| have == want))
}

#[cfg(test)]
mod tests {
    use super::*;

    const MINI: &str = r##"
[spacing_mm]
xs = 1
[radius_mm]
sm = 1
[size_mm]
touch_min = 9
[device_px]
hairline = 2
[gesture]
swipe_min_mm = 2.5
[type_pt]
body = 9.9
[springs]
mass = 1
[springs.standard]
spatial = { stiffness = 700, damping = 0.9 }
effects = { stiffness = 1600, damping = 1.0 }
[springs.expressive]
spatial = { stiffness = 380, damping = 0.8 }
effects = { stiffness = 1600, damping = 1.0 }

[micro.press]
token = "spatial"
follow = "spatial"
scale = 970
moves = "sinks"
still = "inverts"
[micro.drawer]
token = "spatial"
follow = "effects"
moves = "slides"
still = "one paint"

[tier.still]
promise = "nothing"
[tier.full]
promise = "all"

[colour]
slot = [
  { name = "page" }, { name = "text" }, { name = "primary" }, { name = "on_primary" },
]
pair = [ { bg = "primary", fg = "on_primary", min = 450 } ]

[class.lcd_colour]
pressed_layer_permille = 200
live_min_ms = 0
ambient_min_ms = 0
dither = "none"

[schemes.1]
seed = "blue"
rule = "analogous"
light = ["#FFFFFF", "#000000", "#105EB1", "#FFFFFF"]
dark = ["#121212", "#EEEEEE", "#A0C9FF", "#203147"]

[map.grey4]
light = [255, 32, 0, 255]

[map.grey2]
light = [255, 0, 0, 255]
"##;

    const OVERLAY: &str = r##"
[set]
press = "standard"
drawer_open = "expressive"
[superseded]
drawer = "replaced"
[micro.drawer_open]
token = "spatial"
follow = "effects"
shift_px = 24
moves = "opens"
still = "one paint"
[tier_of_class]
lcd_colour = "full"
[light]
scale_limit_permille = 100
[tolerance]
distance_px = 0.5
velocity_px_per_s = 5
alpha_step = 0.004
alpha_velocity = 0.02
[ceiling.drawer_open]
row = "drawer_open"
travel_px = 300
arrive_ms = 120
settle_ms = 450
[input]
sampling_offset_ms = -16
"##;

    fn with(overlay_edit: impl Fn(&str) -> String) -> Result<String, String> {
        generate(MINI, &overlay_edit(OVERLAY), "abc")
    }

    #[test]
    fn the_tables_come_out_in_slot_order_with_the_on_mask_derived() {
        let dart = generate(MINI, OVERLAY, "abc").unwrap();
        assert!(dart
            .contains("enum VrxSlot {\n  page,\n  text,\n  primary,\n  onPrimary,\n}"));
        // primary (index 2) is followed by on_primary
        assert!(dart.contains("vrxSlotHasOnMask = 0x00000004"));
        assert!(dart.contains("VrxSchemeRow(1, 'blue', 'analogous', [0xFFFFFFFF, 0xFF000000, 0xFF105EB1, 0xFFFFFFFF]"));
        assert!(dart.contains("vrxMapGrey4 = [0xFF, 0x20, 0x00, 0xFF]"));
        assert!(dart.contains("'lcd_colour': VrxDisplayClass.lcdColour"));
        assert!(dart.contains("VrxPairFloor(VrxSlot.primary, VrxSlot.onPrimary, 450)"));
        // the physical numbers, and Flutter's damping coefficient from the ratio
        assert!(dart.contains("const double vrxSpacingMmXs = 1.0;"));
        assert!(dart.contains("const double vrxTypePtBody = 9.9;"));
        assert!(dart.contains("VrxSpringToken.spatial: VrxSpringRow(700.0, 47.62352)"));
        // the expressive set beside it: 0.8 x 2 x sqrt(380)
        assert!(dart.contains("VrxSpringToken.spatial: VrxSpringRow(380.0, 31.189"));
    }

    #[test]
    fn the_motion_tables_come_out_of_both_files_g050() {
        let dart = generate(MINI, OVERLAY, "abc").unwrap();
        // a vendored row keeps its tokens and reads the set the overlay says
        assert!(dart.contains("VrxMicro.press: VrxMicroRow(set: VrxSpringSet.standard, token: VrxSpringToken.spatial, follow: VrxSpringToken.spatial, scalePermille: 970,"));
        // an overlay row is added; a superseded vendored row is gone
        assert!(dart
            .contains("VrxMicro.drawerOpen: VrxMicroRow(set: VrxSpringSet.expressive"));
        assert!(!dart.contains("VrxMicro.drawer:"));
        assert!(dart.contains("  drawerOpen,\n"));
        assert!(dart.contains("VrxDisplayClass.lcdColour: VrxTier.full"));
        assert!(dart.contains("const double vrxToleranceDistancePx = 0.5;"));
        assert!(dart.contains(
            "VrxCeiling('drawer_open', VrxMicro.drawerOpen, false, 300.0, 120, 450)"
        ));
        assert!(dart.contains("const int vrxSamplingOffsetMs = -16;"));
    }

    #[test]
    fn the_overlay_adds_and_never_redefines() {
        // a row the standard has
        let err =
            with(|o| o.replace("[micro.drawer_open]", "[micro.press]")).unwrap_err();
        assert!(err.contains("redefines a row of the standard"), "{err}");
        // a table the standard has
        let err = with(|o| format!("{o}\n[springs]\nmass = 2\n")).unwrap_err();
        assert!(err.contains("may carry"), "{err}");
        // a table the overlay may not carry
        let err = with(|o| format!("{o}\n[colour]\nx = 1\n")).unwrap_err();
        assert!(
            err.contains("not a table the overlay may carry")
                || err.contains("redefines"),
            "{err}"
        );
        // superseding a row that is not there
        let err =
            with(|o| o.replace("drawer = \"replaced\"", "nothing = \"x\"")).unwrap_err();
        assert!(err.contains("no such micro row"), "{err}");
    }

    #[test]
    fn every_row_has_a_set_and_every_set_a_row() {
        let err = with(|o| o.replace("press = \"standard\"\n", "")).unwrap_err();
        assert!(
            err.contains("no entry for the micro row \"press\""),
            "{err}"
        );
        let err =
            with(|o| o.replace("[superseded]", "ghost = \"standard\"\n[superseded]"))
                .unwrap_err();
        assert!(err.contains("no micro row"), "{err}");
        let err = with(|o| o.replace("press = \"standard\"", "press = \"snappy\""))
            .unwrap_err();
        assert!(err.contains("not standard or expressive"), "{err}");
    }

    #[test]
    fn tiers_ceilings_and_tokens_are_checked() {
        let err = with(|o| o.replace("lcd_colour = \"full\"", "lcd_colour = \"fast\""))
            .unwrap_err();
        assert!(err.contains("not a tier"), "{err}");
        let err = with(|o| {
            o.replace(
                "[tier_of_class]\nlcd_colour",
                "[tier_of_class]\nlcd_neon = \"still\"\nlcd_colour",
            )
        })
        .unwrap_err();
        assert!(err.contains("every display class"), "{err}");
        let err = with(|o| o.replace("row = \"drawer_open\"", "row = \"nowhere\""))
            .unwrap_err();
        assert!(err.contains("no micro row"), "{err}");
        let err = with(|o| {
            o.replace(
                "token = \"spatial\"\nfollow = \"effects\"\nshift",
                "token = \"swift\"\nfollow = \"effects\"\nshift",
            )
        })
        .unwrap_err();
        assert!(err.contains("not a spring token"), "{err}");
    }

    #[test]
    fn a_short_scheme_or_a_gap_in_the_numbering_is_refused() {
        let short = MINI.replace(r##""#A0C9FF", "#203147"]"##, r##""#A0C9FF"]"##);
        assert!(generate(&short, OVERLAY, "abc")
            .unwrap_err()
            .contains("3 colours"));
        let gap = MINI.replace("[schemes.1]", "[schemes.2]");
        assert!(generate(&gap, OVERLAY, "abc")
            .unwrap_err()
            .contains("numbered"));
        let bad = MINI.replace("#105EB1", "105EB1");
        assert!(generate(&bad, OVERLAY, "abc")
            .unwrap_err()
            .contains("#RRGGBB"));
    }

    #[test]
    fn camel_case_is_dart_case() {
        assert_eq!(camel("on_primary_container"), "onPrimaryContainer");
        assert_eq!(camel("_grey4"), "Grey4");
    }
}
