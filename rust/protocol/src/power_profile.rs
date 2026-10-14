// The board's power profile (plan 0012 D8, G028): what each part of the
// board costs in milliwatts, measured on the bench meter, and the energy
// budgets applets are held to (D11). One file per board family,
// installed by vrx-power-tuning as /usr/share/vrx/power-profile, plus a
// carrier's file in /usr/share/vrx/power-profile.d/ for what the carrier
// adds (its panel). The same files carry the tuning lines (`sysfs`,
// `udev`, plan 0012 D3); this parser reads only its own kinds and leaves
// the rest to their readers.
//
//   model <part> [<step>] <mW> measured=<YYYY-MM-DD> meter=<name> [method=<text>]
//   budget background|front <percent> <minutes>
//   walk-budget <metric> <value>
//
// Parts: `floor` (the board idle, screen off, radios off), `cpu <kHz>`
// (one core fully busy at that frequency, above the floor), `gpu` (the
// 3D engine busy), `display` (lit at full brightness, above the floor),
// `display-dim` (lit at the brightness floor), `wifi-idle`,
// `wifi-active`, `bt`. A number without its measurement is refused:
// a model line must say when and with what it was measured. Budgets are
// thresholds, chosen, not measured; so are walk budgets (plan 0014 D11),
// the defaults a walk holds every applet to where its manifest sets none.

use std::collections::BTreeMap;

/// The parts a model line may name.
pub const PARTS: [&str; 8] = [
    "floor",
    "cpu",
    "gpu",
    "display",
    "display-dim",
    "wifi-idle",
    "wifi-active",
    "bt",
];

/// How a model number was measured.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Measurement {
    pub date: String,
    pub meter: String,
    pub method: Option<String>,
}

/// An energy budget (D11): an applet using more than `percent` of the
/// system's power averaged over `minutes` is over it.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Budget {
    pub percent: f64,
    pub minutes: u32,
}

/// The profile: measured numbers and budgets. Empty `cpu` and no other
/// part: not calibrated.
#[derive(Debug, Clone, PartialEq)]
pub struct PowerProfile {
    /// Milliwatts per part (other than cpu).
    pub parts: BTreeMap<String, u32>,
    /// Milliwatts for one core fully busy, per frequency in kHz.
    pub cpu: BTreeMap<u32, u32>,
    /// The newest measurement date among the numbers, for "calibrated on".
    pub measured: Option<Measurement>,
    pub background: Budget,
    pub front: Budget,
    /// The walk budgets every applet is held to by default.
    pub walk: crate::walk::Budgets,
}

/// D11's starting thresholds, until a board's file sets its own.
pub const BACKGROUND_DEFAULT: Budget = Budget {
    percent: 5.0,
    minutes: 10,
};
pub const FRONT_DEFAULT: Budget = Budget {
    percent: 30.0,
    minutes: 30,
};

impl Default for PowerProfile {
    fn default() -> Self {
        Self {
            parts: BTreeMap::new(),
            cpu: BTreeMap::new(),
            measured: None,
            background: BACKGROUND_DEFAULT,
            front: FRONT_DEFAULT,
            walk: crate::walk::Budgets::default(),
        }
    }
}

/// A line the profile refuses, with its line number (1-based).
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("{source_name}:{line}: {reason}")]
pub struct ProfileError {
    pub source_name: String,
    pub line: usize,
    pub reason: String,
}

impl PowerProfile {
    /// The board has measured numbers to estimate with.
    pub fn calibrated(&self) -> bool {
        self.parts.contains_key("floor") && !self.cpu.is_empty()
    }

    /// A part's milliwatts, 0 when not measured.
    pub fn part(&self, name: &str) -> f64 {
        f64::from(self.parts.get(name).copied().unwrap_or(0))
    }

    /// One fully busy core at `khz`: the measured step, else the line
    /// between the two measured steps around it, else the nearest end.
    pub fn cpu_mw(&self, khz: u32) -> f64 {
        if let Some(mw) = self.cpu.get(&khz) {
            return f64::from(*mw);
        }
        let below = self.cpu.range(..khz).next_back();
        let above = self.cpu.range(khz..).next();
        match (below, above) {
            (Some((&f0, &p0)), Some((&f1, &p1))) => {
                let t = f64::from(khz - f0) / f64::from(f1 - f0);
                f64::from(p0) + t * (f64::from(p1) - f64::from(p0))
            }
            (Some((_, &p)), None) | (None, Some((_, &p))) => f64::from(p),
            (None, None) => 0.0,
        }
    }

    /// The panel lit at `fraction` of its brightness range (0 the floor,
    /// 1 full): between `display-dim` and `display`.
    pub fn display_mw(&self, fraction: f64) -> f64 {
        let full = self.part("display");
        let dim = self
            .parts
            .get("display-dim")
            .map_or(full, |v| f64::from(*v));
        dim + fraction.clamp(0.0, 1.0) * (full - dim)
    }

    /// Read every profile file in order (the family's, then the
    /// carrier's): a later file's number for the same part replaces an
    /// earlier one.
    pub fn parse_all<'a>(
        files: impl IntoIterator<Item = (&'a str, &'a str)>,
    ) -> Result<Self, ProfileError> {
        let mut p = Self::default();
        for (name, text) in files {
            p.parse_into(name, text)?;
        }
        Ok(p)
    }

    /// Read one file.
    pub fn parse(name: &str, text: &str) -> Result<Self, ProfileError> {
        Self::parse_all([(name, text)])
    }

    fn parse_into(&mut self, name: &str, text: &str) -> Result<(), ProfileError> {
        for (n, raw) in text.lines().enumerate() {
            let err = |reason: String| ProfileError {
                source_name: name.to_owned(),
                line: n + 1,
                reason,
            };
            let line = raw.split('#').next().unwrap_or("").trim();
            let mut words = line.split_whitespace();
            match words.next() {
                Some("model") => {
                    let rest: Vec<&str> = words.collect();
                    let (numbers, fields): (Vec<&str>, Vec<&str>) =
                        rest.iter().partition(|w| !w.contains('='));
                    let part = *numbers.first().ok_or_else(|| {
                        err("model <part> [<step>] <mW> measured=…".into())
                    })?;
                    if !PARTS.contains(&part) {
                        return Err(err(format!("unknown part {part:?}")));
                    }
                    let want = if part == "cpu" { 3 } else { 2 };
                    if numbers.len() != want {
                        return Err(err(if part == "cpu" {
                            "model cpu <kHz> <mW> measured=…".into()
                        } else {
                            format!("model {part} <mW> measured=…")
                        }));
                    }
                    let number = |s: &str| {
                        s.parse::<u32>()
                            .map_err(|_| err(format!("{s:?} is not a whole number")))
                    };
                    let mw = number(numbers[want - 1])?;
                    let field = |key: &str| {
                        fields.iter().find_map(|f| {
                            f.strip_prefix(key)
                                .and_then(|v| v.strip_prefix('='))
                                .map(str::to_owned)
                        })
                    };
                    // G028: no number without its measurement
                    let date = field("measured").ok_or_else(|| {
                        err(format!("{part}: a number needs measured=<date>"))
                    })?;
                    let valid_date = date.len() == 10
                        && date.bytes().enumerate().all(|(i, b)| {
                            if i == 4 || i == 7 {
                                b == b'-'
                            } else {
                                b.is_ascii_digit()
                            }
                        });
                    if !valid_date {
                        return Err(err(format!(
                            "measured={date}: a date is YYYY-MM-DD"
                        )));
                    }
                    let meter = field("meter").ok_or_else(|| {
                        err(format!("{part}: a number needs meter=<name>"))
                    })?;
                    let m = Measurement {
                        date,
                        meter,
                        method: field("method"),
                    };
                    if self.measured.as_ref().is_none_or(|old| m.date > old.date) {
                        self.measured = Some(m);
                    }
                    if part == "cpu" {
                        let khz = number(numbers[1])?;
                        self.cpu.insert(khz, mw);
                    } else {
                        self.parts.insert(part.to_owned(), mw);
                    }
                }
                Some("budget") => {
                    let rest: Vec<&str> = words.collect();
                    let [kind, percent, minutes] = rest.as_slice() else {
                        return Err(err(
                            "budget background|front <percent> <minutes>".into()
                        ));
                    };
                    let percent = percent
                        .trim_end_matches('%')
                        .parse::<f64>()
                        .ok()
                        .filter(|p| *p > 0.0 && *p <= 100.0)
                        .ok_or_else(|| err(format!("{percent:?}: a percent 0-100")))?;
                    let minutes = minutes
                        .parse::<u32>()
                        .ok()
                        .filter(|m| (1..=1440).contains(m))
                        .ok_or_else(|| err(format!("{minutes:?}: minutes 1-1440")))?;
                    let b = Budget { percent, minutes };
                    match *kind {
                        "background" => self.background = b,
                        "front" => self.front = b,
                        other => {
                            return Err(err(format!(
                                "budget {other:?}: background or front"
                            )))
                        }
                    }
                }
                Some("walk-budget") => {
                    let rest: Vec<&str> = words.collect();
                    let [metric, value] = rest.as_slice() else {
                        return Err(err("walk-budget <metric> <value>".into()));
                    };
                    let value =
                        value.parse::<f64>().ok().filter(|v| *v > 0.0).ok_or_else(
                            || err(format!("{value:?}: a positive number")),
                        )?;
                    if !self.walk.set(metric, value) {
                        return Err(err(format!(
                            "walk-budget {metric:?}: one of {}",
                            crate::walk::BUDGET_METRICS.join(", ")
                        )));
                    }
                }
                // tuning lines (D3), battery thresholds (D10) and anything a
                // later reader owns
                _ => {}
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const CM4: &str = "\
# bcm2711
sysfs /sys/module/usbcore/parameters/autosuspend 2
model floor 1350 measured=2026-10-14 meter=fnb58 method=idle-screen-off
model cpu 600000 180 measured=2026-10-14 meter=fnb58
model cpu 1500000 520 measured=2026-10-14 meter=fnb58
model gpu 400 measured=2026-10-13 meter=fnb58
budget background 4 15
";

    #[test]
    fn a_measured_profile_reads_and_interpolates() {
        let p = PowerProfile::parse("bcm2711.power", CM4).unwrap();
        assert!(p.calibrated());
        assert_eq!(p.part("floor"), 1350.0);
        assert_eq!(p.cpu_mw(600_000), 180.0);
        assert_eq!(p.cpu_mw(1_050_000), 350.0);
        assert_eq!(p.cpu_mw(2_000_000), 520.0, "above the top step: the top");
        assert_eq!(
            p.background,
            Budget {
                percent: 4.0,
                minutes: 15
            }
        );
        assert_eq!(p.front, FRONT_DEFAULT);
        assert_eq!(p.measured.as_ref().unwrap().date, "2026-10-14");
    }

    #[test]
    fn a_number_without_its_measurement_is_refused_g028() {
        for bad in [
            "model floor 1350",
            "model floor 1350 meter=fnb58",
            "model floor 1350 measured=yesterday meter=fnb58",
            "model gpu 400 measured=2026-10-14",
            "model cpu 400 measured=2026-10-14 meter=fnb58",
            "model fan 30 measured=2026-10-14 meter=fnb58",
            "model floor lots measured=2026-10-14 meter=fnb58",
            "budget background 0 10",
            "budget sideways 5 10",
        ] {
            let e = PowerProfile::parse("p", bad).unwrap_err();
            assert_eq!(e.line, 1, "{bad}: {e}");
        }
    }

    #[test]
    fn walk_budgets_are_board_defaults_and_named() {
        let p = PowerProfile::parse(
            "b.power",
            "walk-budget p95_frame_ms 16.7\nwalk-budget dropped_per_min 6\n",
        )
        .unwrap();
        assert_eq!(
            p.walk.limits(),
            vec![("p95_frame_ms", 16.7), ("dropped_per_min", 6.0)]
        );
        let e = PowerProfile::parse("b.power", "walk-budget fps 60\n").unwrap_err();
        assert!(e.reason.contains("one of"), "{e}");
        assert!(PowerProfile::parse("b.power", "walk-budget peak_mb -1\n").is_err());
    }

    #[test]
    fn no_numbers_is_not_calibrated_and_a_carrier_adds_its_panel() {
        let family = "# candidates only\n# sysfs /x 1\n";
        let p = PowerProfile::parse("bcm2711.power", family).unwrap();
        assert!(!p.calibrated());
        assert_eq!(p.background, BACKGROUND_DEFAULT);
        let carrier = "model display 900 measured=2026-10-15 meter=fnb58\nmodel display-dim 500 measured=2026-10-15 meter=fnb58\n";
        let p =
            PowerProfile::parse_all([("bcm2711.power", CM4), ("disp28a.power", carrier)])
                .unwrap();
        assert_eq!(p.display_mw(1.0), 900.0);
        assert_eq!(p.display_mw(0.0), 500.0);
        assert_eq!(p.display_mw(0.5), 700.0);
        assert_eq!(
            p.measured.unwrap().date,
            "2026-10-15",
            "the newest measurement"
        );
    }
}
