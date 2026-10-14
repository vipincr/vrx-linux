// The vrx command-line tool: new / build / pack / unit / test / profile. A CLI's
// job is stdout; the applet print lints do not apply here (they bind
// the SDK, not the tools).

#![allow(clippy::print_stdout, clippy::print_stderr)]
#![cfg_attr(test, allow(clippy::unwrap_used, clippy::expect_used, clippy::panic))]

mod build;
mod new;
mod pack;
mod power_profile;
mod profile;
mod test_cmd;
mod unit;

use std::process::ExitCode;

const USAGE: &str = "vrx — the applet tool

usage:
  vrx new <name> --rust | --flutter   scaffold a working applet
  vrx build [--in <dir>]              validate the manifest, then compile
  vrx pack <dir> [--out <dir>] (--key <key.pem> --cert <cert.pem> | --unsigned)
           [--arch arm64|x86-64]
                                      an applet as it installs, as <id>.raw:
                                      a signed system extension the device
                                      offers (--unsigned: debug images only)
  vrx unit --manifest <f> --dir <d> --dropin <out> [--bundle <d>]
           [--grants <f>] [--settings <out>]
                                      the applet's systemd drop-in (the build)
  vrx power-profile [--measured] <file>...
                                      check a board's power profile (G028)
  vrx test                            run the store tests on the host
  vrx profile on|off|status|stats --host <board>
  vrx profile capture <frames|cpu|memory|io|full> [--for <s>] --host <board>
  vrx profile pull --host <board> [--out <dir>]
                                      the profiler (plan 0014): the switch, a
                                      Perfetto capture, traces off the device
";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("new") => new::run(&args[1..]),
        Some("build") => build::run(&args[1..]),
        Some("pack") => pack::run(&args[1..]),
        Some("power-profile") => power_profile::run(&args[1..]),
        Some("unit") => unit::run(&args[1..]),
        Some("test") => test_cmd::run(&args[1..]),
        Some("profile") => profile::run(&args[1..]),
        _ => {
            print!("{USAGE}");
            ExitCode::SUCCESS
        }
    }
}
