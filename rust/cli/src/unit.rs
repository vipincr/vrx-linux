// `vrx unit`: write an applet's unit drop-in and settings defaults from
// its manifest (plan 0011 D17). The image build calls it from
// vrx-applet-unit.bbclass for every built-in; vrxhost calls the same
// generator (vrx_protocol::unit) when it installs one.
//
//   vrx unit --manifest <manifest.toml> --dir <installed dir>
//            [--bundle <dir>] [--grants <grants.conf>]
//            [--runtime release|profile]
//            --dropin <out> [--settings <out>]

use std::path::PathBuf;
use std::process::ExitCode;

use vrx_protocol::unit::{dropin, settings_defaults, FlutterMode, Grants, Place};
use vrx_protocol::Manifest;

fn value<'a>(args: &'a [String], flag: &str) -> Option<&'a str> {
    args.iter()
        .position(|a| a == flag)
        .and_then(|i| args.get(i + 1))
        .map(String::as_str)
}

pub fn run(args: &[String]) -> ExitCode {
    let (Some(manifest_path), Some(dir), Some(out)) = (
        value(args, "--manifest"),
        value(args, "--dir"),
        value(args, "--dropin"),
    ) else {
        eprintln!("vrx unit: --manifest, --dir and --dropin are required");
        return ExitCode::from(64);
    };
    let manifest: Manifest = match std::fs::read_to_string(manifest_path)
        .map_err(|e| e.to_string())
        .and_then(|t| t.parse::<Manifest>().map_err(|e| e.to_string()))
    {
        Ok(m) => m,
        Err(err) => {
            eprintln!("vrx unit: {manifest_path}: {err}");
            return ExitCode::from(65);
        }
    };
    let grants = match value(args, "--grants") {
        Some(path) => match std::fs::read_to_string(path)
            .map_err(|e| e.to_string())
            .and_then(|t| Grants::parse(&t).map_err(|e| e.to_string()))
        {
            Ok(g) => g,
            Err(err) => {
                eprintln!("vrx unit: {path}: {err}");
                return ExitCode::from(65);
            }
        },
        None => Grants::shipped(),
    };
    let mut place = Place::builtin(dir, value(args, "--bundle").map(str::to_owned));
    if let Some(mode) = value(args, "--runtime") {
        let Some(mode) = FlutterMode::parse(mode) else {
            eprintln!("vrx unit: --runtime is release or profile, not {mode}");
            return ExitCode::from(64);
        };
        place.flutter_mode = mode;
    }
    let text = match dropin(&manifest, &place, &grants) {
        Ok(text) => text,
        Err(err) => {
            eprintln!("vrx unit: {err}");
            return ExitCode::from(65);
        }
    };
    if let Err(err) = write(PathBuf::from(out), &text) {
        eprintln!("vrx unit: {out}: {err}");
        return ExitCode::FAILURE;
    }
    if let (Some(path), Some(defaults)) =
        (value(args, "--settings"), settings_defaults(&manifest))
    {
        if let Err(err) = write(PathBuf::from(path), &defaults) {
            eprintln!("vrx unit: {path}: {err}");
            return ExitCode::FAILURE;
        }
    }
    ExitCode::SUCCESS
}

fn write(path: PathBuf, text: &str) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(path, text)
}
