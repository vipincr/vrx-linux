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

#[cfg(test)]
mod vector_tests {
    /// The .power grammar's second reader (review step 44): the bench
    /// command holds the sleep ladder to vectors/power-verbs.json, as
    /// vrx-protocol's power_profile tests do; a rung this side refuses
    /// names the rung.
    #[test]
    fn the_sleep_ladder_is_the_vectors() {
        let vector: serde_json::Value =
            serde_json::from_str(include_str!("../../../vectors/power-verbs.json"))
                .expect("vectors/power-verbs.json parses");
        let kinds = vector["sleep_kinds"].as_object().expect("sleep_kinds");
        assert_eq!(kinds.len(), 3, "sleep, deep and off");
        for kind in ["sleep", "deep", "off"] {
            assert!(kinds.contains_key(kind), "the vector lost {kind}");
        }
    }
}
