// A walk (plan 0014 D9): a scripted path through the UI, played on the
// board by `vrx-walk` and measured. The file is TOML, kept in
// tools/walks/*.walk:
//
//   name = "drawer"
//   about = "Open the drawer, slide the brightness, close it"
//   repeat = 3                      # the measured section, N times
//
//   [setup]
//   restart = ["launcher"]          # applets restarted before the run
//   fixture = [{ applet = "clock", from = "fixtures/alarms.json", to = "state/alarms.json" }]
//   warmup_s = 2                    # settle before the first measured step
//   capture = "frames"              # the Perfetto config around the measured section
//
//   [budgets]                       # walk-wide limits on the system rows
//   input_to_screen_p95_ms = 50
//
//   [[prepare]]                     # unmeasured: reach the starting screen
//   action = "home"
//
//   [[step]]                        # the measured section
//   action = "swipe"
//   xy = [240, 2]
//   to = [240, 400]
//   expect = { label = "Close the drawer" }
//
// A control is found by its semantic label (D8, G038) or given as panel
// pixels. Screenshots are taken only outside the measured section, so a
// `shot` in a `step` is refused here, before a board is touched. This
// module is the format's one parser: the workstation's `vrx walk` checks a
// file with it and the board's driver plays what it returns.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

/// The Perfetto configs a capture may use (vrx-traced's, in
/// /usr/share/vrx/profile); `vrx profile capture` takes the same names.
pub const CAPTURE_CONFIGS: [&str; 5] = ["frames", "cpu", "memory", "io", "full"];

/// The keys a `key` step may press, with their Linux input codes
/// (input-event-codes.h), as the bench keyboard (tools/bench/hid.py)
/// sends them. Letters and digits come from [`key_code`].
pub const NAMED_KEYS: [(&str, u16); 11] = [
    ("ESC", 1),
    ("BACKSPACE", 14),
    ("TAB", 15),
    ("ENTER", 28),
    ("LEFTCTRL", 29),
    ("LEFTSHIFT", 42),
    ("SPACE", 57),
    ("UP", 103),
    ("LEFT", 105),
    ("RIGHT", 106),
    ("DOWN", 108),
];

/// A key's input code: a named key, a letter or a digit.
pub fn key_code(name: &str) -> Option<u16> {
    let upper = name.to_ascii_uppercase();
    if let Some((_, code)) = NAMED_KEYS.iter().find(|(n, _)| *n == upper) {
        return Some(*code);
    }
    let mut chars = upper.chars();
    let (Some(c), None) = (chars.next(), chars.next()) else {
        return None;
    };
    let row = |keys: &str, first: u16| {
        keys.find(c)
            .and_then(|i| u16::try_from(i).ok())
            .map(|i| first + i)
    };
    row("1234567890", 2)
        .or_else(|| row("QWERTYUIOP", 16))
        .or_else(|| row("ASDFGHJKL", 30))
        .or_else(|| row("ZXCVBNM", 44))
}

/// What a step does.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Action {
    /// Touch a control (by label) or a point, 60 ms, as a finger does.
    Tap,
    /// Touch and keep the finger down for `ms`.
    Hold,
    /// Drag from a control or point to `to` over `ms`.
    Swipe,
    /// Press and release a key.
    Key,
    /// Type lower-case letters, digits and spaces.
    Type,
    /// Wait `secs`.
    Wait,
    /// Open an applet (io.vrx.Host.Push), at a route if given.
    Open,
    /// One step back along the trail (io.vrx.Host.Pop).
    Back,
    /// The home applet (io.vrx.Host.Home).
    Home,
    /// A screenshot named `name`; outside the measured section only.
    Shot,
}

/// What must be true after a step, within `timeout_s`.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Expect {
    /// A control with this label is on screen.
    #[serde(default)]
    pub label: Option<String>,
    /// No control with this label is on screen.
    #[serde(default)]
    pub gone: Option<String>,
    /// This applet is in front.
    #[serde(default)]
    pub front: Option<String>,
}

/// One step.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Step {
    pub action: Action,
    /// The control, by its semantic label.
    #[serde(default)]
    pub label: Option<String>,
    /// Which applet's controls to search; the shell, then the front applet,
    /// when not given.
    #[serde(default, rename = "in")]
    pub within: Option<String>,
    /// The point, in panel pixels.
    #[serde(default)]
    pub xy: Option<[u32; 2]>,
    /// A swipe's end, in panel pixels.
    #[serde(default)]
    pub to: Option<[u32; 2]>,
    /// A swipe's end as an offset from its start (a control found by
    /// label is wherever the layout put it).
    #[serde(default)]
    pub by: Option<[i32; 2]>,
    /// A hold's or a swipe's duration.
    #[serde(default)]
    pub ms: Option<u32>,
    #[serde(default)]
    pub key: Option<String>,
    #[serde(default)]
    pub text: Option<String>,
    /// An `open`'s applet and route.
    #[serde(default)]
    pub applet: Option<String>,
    #[serde(default)]
    pub route: Option<String>,
    /// A wait's length.
    #[serde(default)]
    pub secs: Option<f64>,
    /// A shot's name.
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub expect: Option<Expect>,
    #[serde(default = "default_timeout")]
    pub timeout_s: f64,
    /// This step, N times in a row.
    #[serde(default = "one")]
    pub repeat: u32,
}

fn default_timeout() -> f64 {
    3.0
}

fn one() -> u32 {
    1
}

/// A file copied into an applet's state (/var/lib/vrx/<applet>/<to>)
/// before the run, from beside the walk file.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Fixture {
    pub applet: String,
    pub from: String,
    pub to: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Setup {
    #[serde(default)]
    pub restart: Vec<String>,
    #[serde(default)]
    pub fixture: Vec<Fixture>,
    #[serde(default = "default_warmup")]
    pub warmup_s: f64,
    #[serde(default = "default_capture")]
    pub capture: String,
}

fn default_warmup() -> f64 {
    2.0
}

fn default_capture() -> String {
    "frames".to_owned()
}

impl Default for Setup {
    fn default() -> Self {
        Self {
            restart: Vec::new(),
            fixture: Vec::new(),
            warmup_s: default_warmup(),
            capture: default_capture(),
        }
    }
}

/// The limits a walk's summary is checked against (D11). An applet's
/// manifest sets its own (`[applet.budgets]`), a board's power profile
/// the defaults (`walk-budget <metric> <value>`), and a walk file the
/// system rows. A limit not set anywhere is not checked.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Budgets {
    /// The worst 95th-percentile build or raster time, ms.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub p95_frame_ms: Option<f64>,
    /// Dropped refreshes a minute while the applet drew.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dropped_per_min: Option<f64>,
    /// CPU time a minute.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cpu_ms_per_min: Option<f64>,
    /// The most memory the applet held.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub peak_mb: Option<f64>,
    /// Input to screen, the 95th percentile (the system row).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub input_to_screen_p95_ms: Option<f64>,
}

/// The budget metrics, as named in files and in a summary.
pub const BUDGET_METRICS: [&str; 5] = [
    "p95_frame_ms",
    "dropped_per_min",
    "cpu_ms_per_min",
    "peak_mb",
    "input_to_screen_p95_ms",
];

impl Budgets {
    /// Each limit that is set, by metric name.
    pub fn limits(&self) -> Vec<(&'static str, f64)> {
        [
            self.p95_frame_ms,
            self.dropped_per_min,
            self.cpu_ms_per_min,
            self.peak_mb,
            self.input_to_screen_p95_ms,
        ]
        .iter()
        .zip(BUDGET_METRICS)
        .filter_map(|(v, name)| v.map(|v| (name, v)))
        .collect()
    }

    /// Set one limit by name; false for a name that is not a budget.
    pub fn set(&mut self, metric: &str, value: f64) -> bool {
        let slot = match metric {
            "p95_frame_ms" => &mut self.p95_frame_ms,
            "dropped_per_min" => &mut self.dropped_per_min,
            "cpu_ms_per_min" => &mut self.cpu_ms_per_min,
            "peak_mb" => &mut self.peak_mb,
            "input_to_screen_p95_ms" => &mut self.input_to_screen_p95_ms,
            _ => return false,
        };
        *slot = Some(value);
        true
    }

    /// `self` where set, else `defaults`.
    pub fn over(&self, defaults: &Budgets) -> Budgets {
        let mut out = defaults.clone();
        for (name, v) in self.limits() {
            out.set(name, v);
        }
        out
    }
}

/// A walk file.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Walk {
    pub name: String,
    pub about: String,
    #[serde(default = "one")]
    pub repeat: u32,
    #[serde(default)]
    pub setup: Setup,
    #[serde(default)]
    pub budgets: Budgets,
    #[serde(default)]
    pub prepare: Vec<Step>,
    pub step: Vec<Step>,
}

/// Why a walk file is refused, with the step it is about.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("{0}")]
pub struct WalkError(pub String);

impl Step {
    /// What this step needs and refuses, by action.
    fn check(&self, at: &str, measured: bool) -> Result<(), String> {
        let target = match (&self.label, self.xy) {
            (Some(_), Some(_)) => return Err(format!("{at}: label or xy, not both")),
            (Some(_), None) | (None, Some(_)) => true,
            (None, None) => false,
        };
        let a = self.action;
        let wants = |field: bool, name: &str, used: &[Action]| -> Result<(), String> {
            match (field, used.contains(&a)) {
                (true, false) => {
                    Err(format!("{at}: {a:?} takes no {name}").to_lowercase())
                }
                (false, true) => Err(format!("{at}: {a:?} needs {name}").to_lowercase()),
                _ => Ok(()),
            }
        };
        use Action::*;
        wants(target, "label or xy", &[Tap, Hold, Swipe])?;
        if self.to.is_some() && self.by.is_some() {
            return Err(format!("{at}: to or by, not both"));
        }
        wants(self.to.is_some() || self.by.is_some(), "to or by", &[Swipe])?;
        wants(self.key.is_some(), "key", &[Key])?;
        wants(self.text.is_some(), "text", &[Type])?;
        wants(self.applet.is_some(), "applet", &[Open])?;
        wants(self.secs.is_some(), "secs", &[Wait])?;
        wants(self.name.is_some(), "name", &[Shot])?;
        if self.within.is_some() && self.label.is_none() {
            return Err(format!("{at}: `in` names where a label is looked for"));
        }
        if self.ms.is_some() && !matches!(a, Hold | Swipe) {
            return Err(format!("{at}: only a hold or a swipe takes ms"));
        }
        if self.route.is_some() && a != Open {
            return Err(format!("{at}: only an open takes a route"));
        }
        if let Some(key) = &self.key {
            if key_code(key).is_none() {
                return Err(format!("{at}: no key {key:?}"));
            }
        }
        if let Some(text) = &self.text {
            if let Some(c) = text
                .chars()
                .find(|c| !(c.is_ascii_lowercase() || c.is_ascii_digit() || *c == ' '))
            {
                return Err(format!(
                    "{at}: type sends lower-case letters, digits and spaces, not {c:?}"
                ));
            }
        }
        for id in self.applet.iter().chain(&self.within) {
            if !crate::manifest::applet_id_ok(id) {
                return Err(format!("{at}: {id:?} is not an applet id"));
            }
        }
        if let Some(secs) = self.secs {
            if !(0.0..=600.0).contains(&secs) {
                return Err(format!("{at}: a wait is 0 to 600 s"));
            }
        }
        if let Some(name) = &self.name {
            if name.is_empty()
                || !name
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
            {
                return Err(format!("{at}: a shot's name is letters, digits, - and _"));
            }
        }
        if a == Shot && measured {
            return Err(format!(
                "{at}: a shot inside the measured section would be measured; take it in prepare"
            ));
        }
        if !(1..=1000).contains(&self.repeat) {
            return Err(format!("{at}: repeat is 1 to 1000"));
        }
        if !(0.1..=60.0).contains(&self.timeout_s) {
            return Err(format!("{at}: timeout_s is 0.1 to 60"));
        }
        if let Some(e) = &self.expect {
            if e.label.is_none() && e.gone.is_none() && e.front.is_none() {
                return Err(format!("{at}: expect needs label, gone or front"));
            }
        }
        Ok(())
    }

    /// The step in a line, as a plan and the trace name it.
    pub fn describe(&self) -> String {
        let mut s = format!("{:?}", self.action).to_lowercase();
        if let Some(l) = &self.label {
            s += &format!(" {l:?}");
        }
        if let Some(w) = &self.within {
            s += &format!(" in {w}");
        }
        if let Some([x, y]) = self.xy {
            s += &format!(" at {x},{y}");
        }
        if let Some([x, y]) = self.to {
            s += &format!(" to {x},{y}");
        }
        if let Some([x, y]) = self.by {
            s += &format!(" by {x},{y}");
        }
        if let Some(ms) = self.ms {
            s += &format!(" over {ms} ms");
        }
        for v in [&self.key, &self.text, &self.applet, &self.name]
            .into_iter()
            .flatten()
        {
            s += &format!(" {v}");
        }
        if let Some(r) = &self.route {
            s += &format!(" at route {r}");
        }
        if let Some(secs) = self.secs {
            s += &format!(" {secs} s");
        }
        if self.repeat > 1 {
            s += &format!(", {} times", self.repeat);
        }
        if let Some(e) = &self.expect {
            let mut wants = Vec::new();
            if let Some(l) = &e.label {
                wants.push(format!("{l:?} shown"));
            }
            if let Some(g) = &e.gone {
                wants.push(format!("{g:?} gone"));
            }
            if let Some(f) = &e.front {
                wants.push(format!("{f} in front"));
            }
            s += &format!(", expecting {}", wants.join(" and "));
        }
        s
    }
}

impl Walk {
    /// Read and check a walk file.
    pub fn parse(text: &str) -> Result<Self, WalkError> {
        let walk: Walk = toml::from_str(text).map_err(|e| WalkError(e.to_string()))?;
        walk.check().map_err(WalkError)?;
        Ok(walk)
    }

    fn check(&self) -> Result<(), String> {
        if self.name.is_empty()
            || !self
                .name
                .chars()
                .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
        {
            return Err(format!(
                "name {:?}: lower-case letters, digits and -",
                self.name
            ));
        }
        if self.step.is_empty() {
            return Err("a walk measures at least one step".to_owned());
        }
        if !(1..=100).contains(&self.repeat) {
            return Err("repeat is 1 to 100".to_owned());
        }
        if !CAPTURE_CONFIGS.contains(&self.setup.capture.as_str()) {
            return Err(format!(
                "capture {:?}: one of {}",
                self.setup.capture,
                CAPTURE_CONFIGS.join(", ")
            ));
        }
        if !(0.0..=60.0).contains(&self.setup.warmup_s) {
            return Err("warmup_s is 0 to 60".to_owned());
        }
        for id in self
            .setup
            .restart
            .iter()
            .chain(self.setup.fixture.iter().map(|f| &f.applet))
        {
            if !crate::manifest::applet_id_ok(id) {
                return Err(format!("setup: {id:?} is not an applet id"));
            }
        }
        for f in &self.setup.fixture {
            // relative and downward only: a fixture stays beside the walk
            // and inside the applet's own state
            for p in [&f.from, &f.to] {
                if p.starts_with('/') || p.split('/').any(|c| c == ".." || c.is_empty()) {
                    return Err(format!("fixture {p:?}: a relative path, no .."));
                }
            }
        }
        for (i, s) in self.prepare.iter().enumerate() {
            s.check(&format!("prepare {}", i + 1), false)?;
        }
        for (i, s) in self.step.iter().enumerate() {
            s.check(&format!("step {}", i + 1), true)?;
        }
        Ok(())
    }

    /// The walk as it will run, one line per step.
    pub fn plan(&self) -> Vec<String> {
        let mut out = vec![format!("{}: {}", self.name, self.about)];
        let s = &self.setup;
        if !s.restart.is_empty() {
            out.push(format!("  restart {}", s.restart.join(", ")));
        }
        for f in &s.fixture {
            out.push(format!("  fixture {} -> {}:{}", f.from, f.applet, f.to));
        }
        for (i, step) in self.prepare.iter().enumerate() {
            out.push(format!("  prepare {}: {}", i + 1, step.describe()));
        }
        out.push(format!(
            "  warm up {} s, then capture {} around the measured section{}",
            s.warmup_s,
            s.capture,
            if self.repeat > 1 {
                format!(", {} times", self.repeat)
            } else {
                String::new()
            }
        ));
        for (i, step) in self.step.iter().enumerate() {
            out.push(format!("  step {}: {}", i + 1, step.describe()));
        }
        for (name, v) in self.budgets.limits() {
            out.push(format!("  budget {name} {v}"));
        }
        out
    }
}

/// One row of a walk's summary (D11): an applet's metric over the walk,
/// or over one step (`step` non-empty). `system` is the compositor's rows.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SummaryRow {
    pub applet: String,
    pub metric: String,
    pub step: String,
    pub value: f64,
}

/// A summary: the rows trace_processor computed from the trace. A metric
/// with no row was not measured (G040): there is no default zero.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Summary {
    pub rows: Vec<SummaryRow>,
}

impl Summary {
    /// The walk-wide value of `metric` for `applet`, if measured.
    pub fn get(&self, applet: &str, metric: &str) -> Option<f64> {
        self.rows
            .iter()
            .find(|r| r.applet == applet && r.metric == metric && r.step.is_empty())
            .map(|r| r.value)
    }

    /// The step where `metric` was worst for `applet`, if steps were
    /// recorded for it.
    pub fn worst_step(&self, applet: &str, metric: &str) -> Option<&SummaryRow> {
        self.rows
            .iter()
            .filter(|r| r.applet == applet && r.metric == metric && !r.step.is_empty())
            .max_by(|a, b| a.value.total_cmp(&b.value))
    }

    /// The applets with rows, in order.
    pub fn applets(&self) -> Vec<&str> {
        let mut out: Vec<&str> = self.rows.iter().map(|r| r.applet.as_str()).collect();
        out.sort_unstable();
        out.dedup();
        out
    }

    /// Read trace_processor's text-format TraceSummary: each `row` holds
    /// its dimensions (applet, metric, step) and one value.
    pub fn from_textproto(text: &str) -> Result<Self, String> {
        let mut rows = Vec::new();
        let mut dims: Vec<String> = Vec::new();
        let mut value: Option<f64> = None;
        let mut in_row = false;
        let mut depth = 0usize;
        let mut row_depth = 0usize;
        for line in text.lines().map(str::trim) {
            if line == "row {" {
                in_row = true;
                row_depth = depth;
                dims.clear();
                value = None;
            }
            if line.ends_with('{') {
                depth += 1;
            }
            if line == "}" {
                depth = depth.saturating_sub(1);
                if in_row && depth == row_depth {
                    in_row = false;
                    let [applet, metric, step] = dims.as_slice() else {
                        return Err(format!(
                            "a summary row has {} dimensions, not applet, metric and step",
                            dims.len()
                        ));
                    };
                    let value = value.ok_or("a summary row has no value")?;
                    rows.push(SummaryRow {
                        applet: applet.clone(),
                        metric: metric.clone(),
                        step: step.clone(),
                        value,
                    });
                }
                continue;
            }
            if !in_row {
                continue;
            }
            if let Some(s) = line.strip_prefix("string_value:") {
                let s = s.trim();
                let s = s
                    .strip_prefix('"')
                    .and_then(|s| s.strip_suffix('"'))
                    .unwrap_or(s);
                dims.push(
                    s.replace("\\\"", "\"")
                        .replace("\\'", "'")
                        .replace("\\\\", "\\"),
                );
            } else if let Some(v) = line
                .strip_prefix("double_value:")
                .or_else(|| line.strip_prefix("int64_value:"))
            {
                value = Some(
                    v.trim()
                        .parse()
                        .map_err(|_| format!("a summary value {v:?} is not a number"))?,
                );
            }
        }
        Ok(Self { rows })
    }
}

/// One budget judged: what was measured against what was allowed.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Verdict {
    pub applet: String,
    pub metric: String,
    pub limit: f64,
    /// None: the source was not available, so the budget was not judged.
    pub measured: Option<f64>,
    /// The worst step, when the summary has steps for this metric.
    pub step: Option<String>,
}

impl Verdict {
    pub fn over(&self) -> bool {
        self.measured.is_some_and(|m| m > self.limit)
    }

    pub fn line(&self) -> String {
        match self.measured {
            None => format!(
                "{} {}: not available, budget {} not judged",
                self.applet, self.metric, self.limit
            ),
            Some(m) => format!(
                "{} {}: {m:.1} against {} {}{}",
                self.applet,
                self.metric,
                self.limit,
                if m > self.limit { "OVER" } else { "ok" },
                self.step
                    .as_ref()
                    .map(|s| format!(" (worst at {s})"))
                    .unwrap_or_default()
            ),
        }
    }
}

/// The summary's walk-wide value for a budget metric. A frame budget is
/// held by the worse phase, build or raster.
fn measured(summary: &Summary, applet: &str, metric: &str) -> Option<f64> {
    match metric {
        "p95_frame_ms" => {
            let b = summary.get(applet, "build_p95_ms");
            let r = summary.get(applet, "raster_p95_ms");
            match (b, r) {
                (Some(b), Some(r)) => Some(b.max(r)),
                (b, r) => b.or(r),
            }
        }
        other => summary.get(applet, other),
    }
}

/// Judge a summary: every applet in it against its budgets (`applets`,
/// resolved on the board from manifests and the power profile), and the
/// system rows against the walk's own.
pub fn judge(
    summary: &Summary,
    applets: &BTreeMap<String, Budgets>,
    walk: &Budgets,
) -> Vec<Verdict> {
    let mut out = Vec::new();
    let mut push = |applet: &str, budgets: &Budgets| {
        for (metric, limit) in budgets.limits() {
            let step = match metric {
                "dropped_per_min" => summary.worst_step(applet, "dropped"),
                _ => None,
            };
            out.push(Verdict {
                applet: applet.to_owned(),
                metric: metric.to_owned(),
                limit,
                measured: measured(summary, applet, metric),
                step: step.map(|s| s.step.clone()),
            });
        }
    };
    for applet in summary.applets() {
        if applet == "system" {
            continue;
        }
        if let Some(b) = applets.get(applet) {
            push(applet, b);
        }
    }
    push("system", walk);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const DRAWER: &str = r#"
name = "drawer"
about = "Open the drawer and close it"
repeat = 2

[setup]
restart = ["shell"]
capture = "frames"

[budgets]
input_to_screen_p95_ms = 50

[[prepare]]
action = "home"

[[prepare]]
action = "shot"
name = "home"

[[step]]
action = "swipe"
xy = [240, 2]
to = [240, 400]
ms = 250
expect = { label = "Close the drawer" }

[[step]]
action = "tap"
label = "Close the drawer"
expect = { gone = "Close the drawer" }
"#;

    /// G054 (plan 0017 D11c): the drawer drops no frame. The budgets of the
    /// shipped drawer walk are what the bench run judges; this makes them
    /// impossible to delete or loosen quietly. The bench half is not a build
    /// gate: `vrx walk check` on a board makes the numbers true.
    #[test]
    fn the_drawer_walk_holds_its_frame_budgets_g054() {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tools/walks/drawer.walk");
        let w = Walk::parse(&std::fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(
            w.budgets.dropped_per_min,
            Some(0.0),
            "the drawer drops no refresh"
        );
        let p95 = w.budgets.p95_frame_ms.expect("a frame-time budget");
        assert!(p95 <= 16.7, "a frame within one 60 Hz period, not {p95} ms");
        // the three speeds and the cancel are in the walk: more than one swipe from the strip
        let pulls = w
            .step
            .iter()
            .filter(|s| s.action == Action::Swipe && s.xy == Some([240, 2]))
            .count();
        assert!(
            pulls >= 5,
            "an open, three speeds and a cancel are measured, not {pulls} pulls"
        );
        // the two motions Part E adds are held to the same numbers
        for name in ["screen-switch", "applet-entrance"] {
            let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                .join(format!("../../tools/walks/{name}.walk"));
            let w = Walk::parse(&std::fs::read_to_string(&path).unwrap()).unwrap();
            assert_eq!(w.budgets.dropped_per_min, Some(0.0), "{name}");
            assert!(w.budgets.p95_frame_ms.is_some_and(|p| p <= 16.7), "{name}");
        }
    }

    #[test]
    fn a_walk_reads_and_plans() {
        let w = Walk::parse(DRAWER).unwrap();
        assert_eq!(w.step.len(), 2);
        assert_eq!(w.setup.warmup_s, 2.0, "the default warm-up");
        let plan = w.plan().join("\n");
        assert!(plan.contains("step 1: swipe at 240,2 to 240,400 over 250 ms, expecting \"Close the drawer\" shown"), "{plan}");
        assert!(plan.contains("budget input_to_screen_p95_ms 50"), "{plan}");
    }

    #[test]
    fn a_step_takes_what_its_action_needs_and_nothing_else() {
        let bad = |step: &str| {
            let text = format!("name = \"x\"\nabout = \"\"\n[[step]]\n{step}\n");
            Walk::parse(&text).unwrap_err().0
        };
        assert!(bad("action = \"tap\"").contains("needs label or xy"));
        assert!(bad("action = \"tap\"\nlabel = \"A\"\nxy = [1, 2]").contains("not both"));
        assert!(bad("action = \"tap\"\nlabel = \"A\"\nkey = \"ENTER\"")
            .contains("takes no key"));
        assert!(bad("action = \"swipe\"\nxy = [1, 2]").contains("needs to or by"));
        assert!(
            bad("action = \"swipe\"\nxy = [1, 2]\nto = [3, 4]\nby = [5, 0]")
                .contains("not both")
        );
        assert!(bad("action = \"key\"\nkey = \"F13\"").contains("no key"));
        assert!(bad("action = \"type\"\ntext = \"Hello\"").contains("lower-case"));
        assert!(
            bad("action = \"open\"\napplet = \"Bad-Id\"").contains("not an applet id")
        );
        assert!(
            bad("action = \"wait\"\nsecs = 1.0\nexpect = {}").contains("expect needs")
        );
        assert!(
            bad("action = \"tap\"\nlabel = \"A\"\nbogus = 1").contains("bogus"),
            "unknown keys fail, named"
        );
    }

    #[test]
    fn a_shot_in_the_measured_section_is_refused() {
        let text =
            "name = \"x\"\nabout = \"\"\n[[step]]\naction = \"shot\"\nname = \"a\"\n";
        assert!(Walk::parse(text)
            .unwrap_err()
            .0
            .contains("take it in prepare"));
    }

    #[test]
    fn a_fixture_stays_beside_the_walk_and_inside_the_applet() {
        for p in ["/etc/passwd", "../x", "a/../../b"] {
            let text = format!(
                "name = \"x\"\nabout = \"\"\n[setup]\nfixture = [{{ applet = \"clock\", from = \"{p}\", to = \"state/a\" }}]\n[[step]]\naction = \"home\"\n"
            );
            assert!(
                Walk::parse(&text).unwrap_err().0.contains("relative path"),
                "{p}"
            );
        }
    }

    #[test]
    fn keys_are_the_bench_keyboards_codes() {
        assert_eq!(key_code("enter"), Some(28));
        assert_eq!(key_code("q"), Some(16));
        assert_eq!(key_code("M"), Some(50));
        assert_eq!(key_code("0"), Some(11));
        assert_eq!(key_code("F1"), None);
    }

    #[test]
    fn budgets_layer_and_name_their_metrics() {
        let board = Budgets {
            p95_frame_ms: Some(16.7),
            dropped_per_min: Some(6.0),
            ..Budgets::default()
        };
        let applet = Budgets {
            p95_frame_ms: Some(12.0),
            peak_mb: Some(80.0),
            ..Budgets::default()
        };
        let b = applet.over(&board);
        assert_eq!(
            b.limits(),
            vec![
                ("p95_frame_ms", 12.0),
                ("dropped_per_min", 6.0),
                ("peak_mb", 80.0)
            ]
        );
        assert!(!b.clone().set("fps", 1.0));
    }

    const SUMMARY: &str = r#"
metric_bundles {
  specs {
    id: "vrx_walk"
    dimensions: "applet"
  }
  row {
    dimension {
      string_value: "clock"
    }
    dimension {
      string_value: "build_p95_ms"
    }
    dimension {
      string_value: ""
    }
    values {
      double_value: 9.000000
    }
  }
  row {
    dimension {
      string_value: "clock"
    }
    dimension {
      string_value: "raster_p95_ms"
    }
    dimension {
      string_value: ""
    }
    values {
      double_value: 21.500000
    }
  }
  row {
    dimension {
      string_value: "clock"
    }
    dimension {
      string_value: "dropped"
    }
    dimension {
      string_value: "step 2 tap \"Close the drawer\""
    }
    values {
      double_value: 3.000000
    }
  }
  row {
    dimension {
      string_value: "clock"
    }
    dimension {
      string_value: "dropped_per_min"
    }
    dimension {
      string_value: ""
    }
    values {
      double_value: 1.000000
    }
  }
}
"#;

    #[test]
    fn a_summary_reads_from_trace_processor_text() {
        let s = Summary::from_textproto(SUMMARY).unwrap();
        assert_eq!(s.rows.len(), 4);
        assert_eq!(s.get("clock", "raster_p95_ms"), Some(21.5));
        assert_eq!(
            s.worst_step("clock", "dropped").map(|r| r.step.as_str()),
            Some("step 2 tap \"Close the drawer\"")
        );
    }

    /// trace_processor 51.2's own output for tools/profile/summary's
    /// fixture trace, through vrx.pbtx.
    #[test]
    fn the_spec_output_on_the_fixture_trace_reads() {
        let s = Summary::from_textproto(include_str!(
            "../../../tools/profile/summary/fixture.summary.txt"
        ))
        .unwrap();
        assert_eq!(s.get("clock", "cpu_ms"), Some(42.0));
        assert_eq!(s.get("clock", "dropped"), Some(2.0));
        assert_eq!(s.get("system", "dropped_app_late"), Some(2.0));
        assert_eq!(s.get("system", "input_to_screen_p95_ms"), Some(80.0));
        assert_eq!(s.get("clock", "gpu_ms"), None, "no source, no row (G040)");
        assert_eq!(
            s.worst_step("clock", "dropped").map(|r| r.step.as_str()),
            Some("step 1 tap \"Settings\"")
        );
    }

    #[test]
    fn a_budget_is_judged_on_what_was_measured_and_never_on_a_zero_g040() {
        let s = Summary::from_textproto(SUMMARY).unwrap();
        let mut applets = BTreeMap::new();
        applets.insert(
            "clock".to_owned(),
            Budgets {
                p95_frame_ms: Some(16.7),
                dropped_per_min: Some(6.0),
                cpu_ms_per_min: Some(500.0),
                ..Budgets::default()
            },
        );
        let walk = Budgets {
            input_to_screen_p95_ms: Some(50.0),
            ..Budgets::default()
        };
        let v = judge(&s, &applets, &walk);
        let frame = v.iter().find(|v| v.metric == "p95_frame_ms").unwrap();
        assert_eq!(
            frame.measured,
            Some(21.5),
            "the worse phase holds the budget"
        );
        assert!(frame.over());
        let dropped = v.iter().find(|v| v.metric == "dropped_per_min").unwrap();
        assert!(!dropped.over());
        assert_eq!(
            dropped.step.as_deref(),
            Some("step 2 tap \"Close the drawer\"")
        );
        let cpu = v.iter().find(|v| v.metric == "cpu_ms_per_min").unwrap();
        assert_eq!(cpu.measured, None, "no row is not available, not zero");
        assert!(!cpu.over());
        assert!(cpu.line().contains("not available"));
        let latency = v.iter().find(|v| v.applet == "system").unwrap();
        assert_eq!(latency.measured, None);
    }
}
