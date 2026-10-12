// The vrx command-line tool.
//
// Plan 0007 part H: `vrx new` (scaffold an applet, Rust or Flutter),
// `vrx build` (validate the manifest, compile), `vrx install`,
// `vrx test`. A CLI's job is stdout; the applet print lints do not
// apply here (they bind the SDK, not the tools).

#![allow(clippy::print_stdout, clippy::print_stderr)]

use std::process::ExitCode;

const USAGE: &str = "vrx — the applet tool

usage:
  vrx new <name> --rust|--flutter   scaffold a working applet
  vrx build [--release]             validate manifest + build
  vrx install <dir|bundle>          install into /apps
  vrx test                          run the store tests on the host
";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("new") | Some("build") | Some("install") | Some("test") => {
            eprintln!("vrx: `{}` lands with plan 0007 part H", args[0]);
            ExitCode::from(64) // EX_USAGE: the command exists, the work is pending
        }
        _ => {
            print!("{USAGE}");
            ExitCode::SUCCESS
        }
    }
}
