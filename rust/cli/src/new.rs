// `vrx new`: scaffold a working applet. Both scaffolds compile and
// pass their tests immediately — the developer starts from a working
// applet, not a blank page.
//
// The Rust scaffold keeps the applet model in lib.rs so the same
// model compiles into the store test (the plan's own rule); main.rs
// stays three lines.

use std::path::{Path, PathBuf};
use std::process::ExitCode;

pub fn run(args: &[String]) -> ExitCode {
    let Some(name) = args.first() else {
        eprintln!("vrx new: an applet name is required (vrx new myapp --rust)");
        return ExitCode::from(64);
    };
    let id = sanitize_id(name);
    if id.is_empty() {
        eprintln!("vrx new: {name:?} cannot become an applet id ([a-z][a-z0-9_]*)");
        return ExitCode::from(64);
    }
    let flutter = args.iter().any(|a| a == "--flutter");
    let rust = args.iter().any(|a| a == "--rust");
    if flutter == rust {
        eprintln!("vrx new: pick exactly one runtime: --rust or --flutter");
        return ExitCode::from(64);
    }
    let target = PathBuf::from(&id);
    if target.exists() {
        eprintln!("vrx new: {} already exists", target.display());
        return ExitCode::from(73);
    }
    let sdk = sdk_path(args);
    let result = if rust {
        scaffold_rust(&target, &id, &sdk)
    } else {
        scaffold_flutter(&target, &id, &sdk)
    };
    match result {
        Ok(()) => {
            println!("scaffolded applet in {}/", target.display());
            if rust {
                println!("  cd {} && cargo test", id);
            } else {
                println!("  cd {} && flutter test", id);
            }
            ExitCode::SUCCESS
        }
        Err(err) => {
            eprintln!("vrx new: {err}");
            ExitCode::FAILURE
        }
    }
}

/// [a-z][a-z0-9_]*, refusing the reserved id; "My-App" becomes
/// "my_app", a leading digit gets a prefix.
fn sanitize_id(name: &str) -> String {
    let mut id: String = name
        .chars()
        .map(|c| {
            if c.is_ascii_lowercase() || c.is_ascii_digit() {
                c
            } else if c.is_ascii_uppercase() {
                c.to_ascii_lowercase()
            } else {
                '_'
            }
        })
        .collect();
    if id.starts_with(|c: char| c.is_ascii_digit()) {
        id.insert(0, 'a');
    }
    while id.starts_with('_') {
        id.remove(0);
    }
    if id == "vrx" || id.is_empty() {
        String::new()
    } else {
        id
    }
}

/// Where the SDK lives: --sdk, then VRX_SDK, then walking up from
/// this binary (a checkout build puts vrx in <ws>/target/{debug,release}).
fn sdk_path(args: &[String]) -> PathBuf {
    if let Some(i) = args.iter().position(|a| a == "--sdk") {
        if let Some(p) = args.get(i + 1) {
            return PathBuf::from(p);
        }
    }
    if let Some(p) = std::env::var_os("VRX_SDK") {
        return PathBuf::from(p);
    }
    if let Ok(exe) = std::env::current_exe() {
        for dir in exe.ancestors().skip(1) {
            if dir.join("rust").join("sdk").join("Cargo.toml").exists() {
                return dir.to_path_buf();
            }
        }
    }
    PathBuf::from(".")
}

fn write(path: impl AsRef<Path>, text: &str) -> std::io::Result<()> {
    let path = path.as_ref();
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(path, text)
}

fn manifest(id: &str, runtime: &str) -> String {
    let display = id.split(['_', '-']).next().unwrap_or(id);
    format!(
        "[applet]\nid = \"{id}\"\nname = \"{}\"\nversion = \"0.1.0\"\nruntime = \"{runtime}\"\n",
        display
    )
}

fn camel(name: &str) -> String {
    let mut out = String::new();
    let mut upper = true;
    for c in name.chars() {
        match c {
            '_' | '-' => upper = true,
            c if upper => {
                out.extend(c.to_uppercase());
                upper = false;
            }
            c => out.push(c),
        }
    }
    out
}

fn scaffold_rust(dir: &Path, id: &str, sdk: &Path) -> std::io::Result<()> {
    let crate_name = id.replace('-', "_");
    write(dir.join("manifest.toml"), &manifest(id, "rust"))?;
    write(dir.join("Cargo.toml"), &rust_cargo_toml(&crate_name, sdk))?;
    write(dir.join("deny.toml"), RUST_DENY_TOML)?;
    write(dir.join("src").join("lib.rs"), &rust_lib_rs(&crate_name))?;
    write(dir.join("src").join("main.rs"), &rust_main_rs(&crate_name))?;
    write(
        dir.join("tests").join("store_test.rs"),
        &rust_test_rs(&crate_name),
    )?;
    write(
        dir.join("tests").join("layout.rs"),
        &rust_layout_rs(&crate_name),
    )?;
    Ok(())
}

/// The layout check `vrx build` runs with the tests: every screen's text
/// fits the console grid on every display vrx drives (vrx::layout).
fn rust_layout_rs(name: &str) -> String {
    format!(
        r#"use {name}::{{Action, {Camel}}};
use vrx::prelude::*;

/// Every screen the applet draws, on every display vrx drives: no row
/// cut, no word broken (AGENTS.md rule 11). Add each new screen here,
/// with facts in it as long as real ones get.
#[test]
fn every_screen_fits_every_display() {{
    let mut harness = StoreHarness::new({Camel}::new());
    assert_clean_layout(&{Camel}::screen_of(harness.view()));
    for _ in 0..12345 {{
        harness.dispatch(Action::Tap);
    }}
    assert_clean_layout(&{Camel}::screen_of(harness.view()));
}}
"#,
        Camel = camel(name)
    )
}

fn rust_cargo_toml(name: &str, sdk: &Path) -> String {
    format!(
        r#"# {name}: a vrx Rust applet (generated by `vrx new`).
[package]
name = "{name}"
version = "0.1.0"
edition = "2021"
license = "MIT"

[dependencies]
# pre-publish: the SDK by path; a published crate replaces this line
vrx = {{ path = {:?} }}
serde = {{ version = "1", features = ["derive"] }}
serde_json = "1"

[lints.clippy]
all = "deny"
unwrap_used = "deny"
expect_used = "deny"
panic = "deny"
print_stdout = "deny"      # applet_main owns stdout; use vrx logging
"#,
        sdk.join("rust").join("sdk")
    )
}

const RUST_DENY_TOML: &str = r#"# vrx applet dependency restrictions (generated by `vrx new`).
[bans]
multiple-versions = "warn"
deny = [
    # GUI crates — Rust applets render via the vrx console kit or Flutter
    { name = "sdl2" }, { name = "minifb" }, { name = "winit" },
    { name = "gtk" }, { name = "fltk" },
    # Applets are clients, not servers
    { name = "actix-web" }, { name = "rocket" }, { name = "warp" },
    # Persistence goes through vrx::File
    { name = "rusqlite" }, { name = "diesel" },
]

[licenses]
allow = ["MIT", "Apache-2.0", "ISC", "BSD-3-Clause", "Zlib", "Unicode-3.0"]
"#;

fn rust_lib_rs(name: &str) -> String {
    format!(
        r#"//! {name}: a vrx applet. The model lives in lib so the same
//! code compiles into the store test — an applet's decisions are
//! testable without a board.

use serde::{{Deserialize, Serialize}};
use vrx::prelude::*;

/// Everything the applet reacts to.
#[derive(Serialize, Deserialize, Debug, PartialEq)]
pub enum Action {{
    Init,
    Tap,
}}

/// What `render` draws.
#[derive(Debug, PartialEq)]
pub struct View {{
    pub taps: i32,
}}

/// The applet: state as fields, reduce applies and derives the view.
pub struct {Camel} {{
    taps: i32,
}}

impl {Camel} {{
    pub fn new() -> Self {{
        Self {{ taps: 0 }}
    }}
}}

impl Default for {Camel} {{
    fn default() -> Self {{
        Self::new()
    }}
}}

impl Applet for {Camel} {{
    type State = i32;
    type Action = Action;
    type View = View;

    fn initial() -> i32 {{
        0
    }}

    fn boot_action() -> Action {{
        Action::Init
    }}

    fn reduce(&mut self, _state: &i32, action: &Action) -> View {{
        match action {{
            Action::Init => {{}}
            Action::Tap => self.taps += 1,
        }}
        View {{ taps: self.taps }}
    }}

    fn snapshot(&self) -> i32 {{
        self.taps
    }}

    fn render(view: &View) -> String {{
        Self::screen_of(view).render()
    }}
}}

impl {Camel} {{
    /// The screen for a view: what render draws, and what the layout
    /// test checks on every display (tests/layout.rs).
    pub fn screen_of(view: &View) -> Screen {{
        screen(vec![
            text_title("{name}"),
            text_row("taps", view.taps.to_string()),
            button("Tap", "{name}.tap"),
        ])
    }}
}}
"#,
        Camel = camel(name)
    )
}

fn rust_main_rs(name: &str) -> String {
    format!(
        "use {name}::{Camel};\n\nfn main() -> std::process::ExitCode {{\n    vrx::applet_main::<{Camel}>({Camel}::new())\n}}\n",
        Camel = camel(name)
    )
}

fn rust_test_rs(name: &str) -> String {
    format!(
        r#"use {name}::{{Action, {Camel}}};
use vrx::prelude::*;

#[test]
fn tapping_increments_the_counter() {{
    let mut harness = StoreHarness::new({Camel}::new());
    assert_eq!(harness.view().taps, 0, "the boot action seeds the view");
    harness.dispatch(Action::Tap);
    assert_eq!(harness.view().taps, 1);
}}

#[test]
fn the_store_reduces_in_order() {{
    let mut harness = StoreHarness::new({Camel}::new());
    harness.dispatch(Action::Tap);
    harness.dispatch(Action::Tap);
    assert_eq!(harness.view().taps, 2);
}}
"#,
        Camel = camel(name)
    )
}

fn scaffold_flutter(dir: &Path, id: &str, sdk: &Path) -> std::io::Result<()> {
    let pkg = id.replace('-', "_");
    write(dir.join("manifest.toml"), &manifest(id, "flutter"))?;
    write(dir.join("pubspec.yaml"), &flutter_pubspec(&pkg, sdk))?;
    write(dir.join("analysis_options.yaml"), FLUTTER_ANALYSIS)?;
    write(dir.join("lib").join("main.dart"), &flutter_main_dart(&pkg))?;
    write(
        dir.join("lib").join("state.dart"),
        &flutter_state_dart(&pkg),
    )?;
    write(
        dir.join("test").join("store_test.dart"),
        &flutter_test_dart(&pkg),
    )?;
    write(
        dir.join("test").join("layout_test.dart"),
        &flutter_layout_test_dart(&pkg),
    )?;
    Ok(())
}

/// The layout check `vrx build` runs before compiling: every screen on
/// every display vrx drives (vrx_check).
fn flutter_layout_test_dart(pkg: &str) -> String {
    format!(
        r#"import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_check/vrx_check.dart';

import 'package:{pkg}/main.dart';

/// Every screen of the applet on every display vrx drives: no overlap,
/// no cut or broken text, controls 9mm and 1mm apart on touch panels,
/// nothing off the screen. Add each new screen here (AGENTS.md rule 11).
void main() {{
  for (final display in allDisplays) {{
    testWidgets('home screen on ${{display.name}}', (tester) async {{
      await expectCleanLayout(tester, {Pkg}Applet(), display: display);
    }});
  }}
}}
"#,
        Pkg = camel(pkg)
    )
}

fn flutter_pubspec(pkg: &str, sdk: &Path) -> String {
    format!(
        r#"name: {pkg}
description: a vrx Flutter applet (generated by `vrx new`)
publish_to: none
version: 0.1.0

environment:
  sdk: ">=3.0.0 <4.0.0"

dependencies:
  flutter:
    sdk: flutter
  vrx_kit:
    path: {path:?}

dev_dependencies:
  vrx_check:
    path: {check:?}
  flutter_test:
    sdk: flutter
  flutter_lints: ^5.0.0

flutter:
"#,
        path = sdk.join("flutter").join("vrx_kit"),
        check = sdk.join("flutter").join("vrx_check")
    )
}

const FLUTTER_ANALYSIS: &str = r#"include: package:flutter_lints/flutter.yaml

# vrx-specific rules (banned raw Navigator/Colors/font sizes/spacing)
# arrive with the vrx_lints package.
"#;

fn flutter_state_dart(pkg: &str) -> String {
    format!(
        r#"import 'package:vrx_kit/vrx_kit.dart';

/// Everything the applet reacts to.
enum {Pkg}Action {{ init, tap }}

/// What build draws.
class {Pkg}View {{
  const {Pkg}View({{required this.taps}});

  final int taps;
}}

/// The applet model: state as fields, reduce applies and derives the
/// view — the same code a host test drives.
class {Pkg}Model extends StoreModel<int, {Pkg}Action, {Pkg}View> {{
  int taps = 0;

  @override
  int get initial => 0;

  @override
  {Pkg}Action get bootAction => {Pkg}Action.init;

  @override
  {Pkg}View reduce(int state, {Pkg}Action action) {{
    switch (action) {{
      case {Pkg}Action.init:
        taps = 0;
      case {Pkg}Action.tap:
        taps += 1;
    }}
    return {Pkg}View(taps: taps);
  }}

  @override
  int get snapshot => taps;
}}
"#,
        Pkg = camel(pkg)
    )
}

fn flutter_main_dart(pkg: &str) -> String {
    format!(
        r#"import 'package:flutter/material.dart' hide Intent; // vrx's Intent
import 'package:vrx_kit/vrx_kit.dart';

import 'state.dart';

/// The applet: the model plus its Flutter view.
class {Pkg}Applet extends Applet<int, {Pkg}Action, {Pkg}View> {{
  final _model = {Pkg}Model();

  @override
  int get initial => _model.initial;

  @override
  {Pkg}Action get bootAction => _model.bootAction;

  @override
  {Pkg}View reduce(int state, {Pkg}Action action) =>
      _model.reduce(state, action);

  @override
  List<Effect> effects(int state, {Pkg}Action action) => const [];

  @override
  int get snapshot => _model.snapshot;

  @override
  Widget build(BuildContext context, {Pkg}View view) {{
    // the kit's own controls: 9mm rows, focus, hover and keys included,
    // so the layout check (test/layout_test.dart) passes from the start
    return Scaffold(
      body: SafeArea(
        child: VrxList(children: [
          const VrxHeader(title: '{pkg}', onBack: Nav.pop),
          VrxRow(label: 'Taps', value: '${{view.taps}}'),
          VrxRow(glyph: VrxSymbols.touch_app, label: 'Tap', onTap: () => AppletScope.dispatch(context, {Pkg}Action.tap)),
        ]),
      ),
    );
  }}
}}

void main() {{
  // The flutter-vrx runtime hosts applets; this entry point exists so
  // the applet also runs under `flutter run` during development.
  runApp(const _Host());
}}

class _Host extends StatelessWidget {{
  const _Host();

  @override
  Widget build(BuildContext context) {{
    return const MaterialApp(home: Scaffold(body: SizedBox.shrink()));
  }}
}}
"#,
        Pkg = camel(pkg)
    )
}

fn flutter_test_dart(pkg: &str) -> String {
    format!(
        r#"import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

import 'package:{pkg}/state.dart';

void main() {{
  test('tapping increments the counter', () {{
    final harness = StoreHarness({Pkg}Model());
    harness.dispatch({Pkg}Action.tap);
    harness.assertView((v) => v.taps == 1);
  }});

  test('the boot action seeds the initial view', () {{
    final harness = StoreHarness({Pkg}Model());
    harness.assertView((v) => v.taps == 0);
  }});
}}
"#,
        Pkg = camel(pkg)
    )
}
