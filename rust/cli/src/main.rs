// The vrx command-line tool: new / build / pack / unit / test. A CLI's
// job is stdout; the applet print lints do not apply here (they bind
// the SDK, not the tools).

#![allow(clippy::print_stdout, clippy::print_stderr)]

mod build;
mod new;
mod pack;
mod test_cmd;
mod unit;

use std::process::ExitCode;

const USAGE: &str = "vrx — the applet tool

usage:
  vrx new <name> --rust | --flutter   scaffold a working applet
  vrx build [--in <dir>]              validate the manifest, then compile
  vrx pack <dir> [--out <dir>]        an applet as it installs, as <id>.raw:
                                      a system extension the device offers
  vrx unit --manifest <f> --dir <d> --dropin <out> [--bundle <d>]
           [--grants <f>] [--settings <out>]
                                      the applet's systemd drop-in (the build)
  vrx test                            run the store tests on the host
";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("new") => new::run(&args[1..]),
        Some("build") => build::run(&args[1..]),
        Some("pack") => pack::run(&args[1..]),
        Some("unit") => unit::run(&args[1..]),
        Some("test") => test_cmd::run(&args[1..]),
        _ => {
            print!("{USAGE}");
            ExitCode::SUCCESS
        }
    }
}
