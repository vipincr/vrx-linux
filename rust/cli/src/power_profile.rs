// `vrx power-profile`: check a board's power profile files (plan 0012
// G028). The image build runs it on the family's and the carrier's
// files: a model number without its measurement, or a UI board with no
// measured numbers at all when --measured is given, fails the build.
//
//   vrx power-profile [--measured] <file>...

use std::process::ExitCode;

use vrx_protocol::power_profile::PowerProfile;

pub fn run(args: &[String]) -> ExitCode {
    let measured = crate::flags::present(args, "--measured");
    let files: Vec<&String> = args.iter().filter(|a| !a.starts_with("--")).collect();
    if files.is_empty() {
        eprintln!("vrx power-profile: name the profile files");
        return ExitCode::from(64);
    }
    let mut texts = Vec::new();
    for f in &files {
        match std::fs::read_to_string(f) {
            Ok(t) => texts.push((f.as_str(), t)),
            Err(err) => {
                eprintln!("vrx power-profile: {f}: {err}");
                return ExitCode::from(66);
            }
        }
    }
    match PowerProfile::parse_all(texts.iter().map(|(n, t)| (*n, t.as_str()))) {
        Ok(p) if measured && !p.calibrated() => {
            eprintln!(
                "vrx power-profile: no measured floor and cpu numbers: the board is not calibrated (G028)"
            );
            ExitCode::from(65)
        }
        Ok(p) => {
            match &p.measured {
                Some(m) => println!(
                    "calibrated {} with {}: {} parts, {} cpu steps; budgets {}% over {} min behind, {}% over {} min in front",
                    m.date, m.meter, p.parts.len(), p.cpu.len(),
                    p.background.percent, p.background.minutes, p.front.percent, p.front.minutes
                ),
                None => println!("not calibrated: no measured numbers"),
            }
            ExitCode::SUCCESS
        }
        Err(err) => {
            eprintln!("vrx power-profile: {err}");
            ExitCode::from(65)
        }
    }
}
