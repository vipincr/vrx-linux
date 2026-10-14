// vrx-walk: plays a walk on the board and measures it (plan 0014 D9).
// `vrx walk run` on the workstation copies the walk here and runs this
// over ssh; the taps come from the device itself (uinput), so the network
// is not in the timing.
//
//   vrx-walk run <file.walk> [--scanout <scanout.py>]
//   vrx-walk ready            exits 0 when a measurement now would be fair
//
// A run: refuse an unfit board (governor, throttling); switch profiling
// and semantics on; restart the setup's applets with their fixtures; play
// `prepare`; warm up; start a capture (vrx-profile, the store's one
// writer, under its quota); play the measured steps `repeat` times, each
// one a slice on trace_marker; wait for the last frame window; stop the
// capture. The trace, a result file and any screenshots land in the
// trace store, and their names go to stdout, one a line, for `vrx walk
// run` to take. Exit 1: a step failed (the result says which, with a
// screenshot); 3: the board was unfit, before or during the run.

#![allow(clippy::print_stdout, clippy::print_stderr)]
#![cfg_attr(test, allow(clippy::unwrap_used, clippy::expect_used, clippy::panic))]

mod board;
mod input;
mod screen;

use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode, Stdio};
use std::time::{Duration, Instant};

use serde::Serialize;
use vrx_protocol::walk::{key_code, Action, Budgets, Step, Walk};

use board::Board;
use input::Hands;

const STORE: &str = "/data/vrx/profile";
const HOST: &str = "/run/vrx/io.vrx.Host";
const TRACE_MARKER: &str = "/sys/kernel/tracing/trace_marker";
/// Frame summaries arrive every 5 s: wait one window and a second after
/// the last step so the section's frames are in the trace.
const COOLDOWN: Duration = Duration::from_secs(6);

/// One varlinkctl call to vrxhost; its reply's parameters.
fn host(method: &str, params: serde_json::Value) -> Result<serde_json::Value, String> {
    let out = Command::new("varlinkctl")
        .args([
            "call",
            "--json=short",
            HOST,
            &format!("io.vrx.Host.{method}"),
            &params.to_string(),
        ])
        .stderr(Stdio::piped())
        .output()
        .map_err(|e| format!("varlinkctl: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "io.vrx.Host.{method}: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    serde_json::from_slice(&out.stdout).map_err(|e| format!("io.vrx.Host.{method}: {e}"))
}

fn front() -> Result<String, String> {
    host("Watch", serde_json::json!({}))?
        .get("front")
        .and_then(|f| f.as_str())
        .map(str::to_owned)
        .ok_or_else(|| "io.vrx.Host.Watch named no front applet".to_owned())
}

fn systemctl(verb: &str, applet: &str) -> Result<(), String> {
    let unit = format!("vrx-applet@{applet}.service");
    let ok = Command::new("systemctl")
        .args([verb, &unit])
        .status()
        .map_err(|e| format!("systemctl: {e}"))?
        .success();
    ok.then_some(())
        .ok_or_else(|| format!("systemctl {verb} {unit} failed"))
}

/// The trace's slices: B and E lines on trace_marker.
struct Marks {
    file: std::fs::File,
    pid: u32,
}

impl Marks {
    fn open() -> Result<Self, String> {
        let file = std::fs::OpenOptions::new()
            .write(true)
            .open(TRACE_MARKER)
            .map_err(|e| {
                format!("{TRACE_MARKER}: {e} (tracefs not mounted, or not root)")
            })?;
        Ok(Self {
            file,
            pid: std::process::id(),
        })
    }

    fn begin(&mut self, name: &str) {
        let _ = write!(self.file, "B|{}|{}", self.pid, name.replace('|', "/"));
    }

    fn end(&mut self) {
        let _ = write!(self.file, "E|{}", self.pid);
    }
}

#[derive(Serialize)]
struct StepRecord {
    phase: &'static str,
    rep: u32,
    index: usize,
    step: String,
    /// From the start of the run.
    start_ms: u64,
    ms: u64,
    error: Option<String>,
}

#[derive(Serialize)]
struct Record {
    walk: Walk,
    started: String,
    panel: (u32, u32),
    budgets: std::collections::BTreeMap<String, Budgets>,
    steps: Vec<StepRecord>,
    trace: Option<String>,
    shots: Vec<String>,
    /// Why the run stopped short, if it did.
    failed: Option<String>,
    /// The board became unfit during the run: the numbers are not
    /// comparable, and `vrx walk run` repeats it.
    unfit: Option<String>,
}

struct Run {
    started: Instant,
    stamp: String,
    walk: Walk,
    scanout: Option<PathBuf>,
    hands: Hands,
    marks: Marks,
    sem: screen::Changes,
    panel: (u32, u32),
    record_steps: Vec<StepRecord>,
    shots: Vec<String>,
}

impl Run {
    fn shot(&mut self, name: &str) -> Result<(), String> {
        let Some(scanout) = &self.scanout else {
            return Err("no screenshot: run with --scanout".to_owned());
        };
        let file = format!("{}-walk-{}-{name}.png", self.stamp, self.walk.name);
        let ok = Command::new("python3")
            .arg(scanout)
            .arg(Path::new(STORE).join(&file))
            .status()
            .map_err(|e| format!("python3: {e}"))?
            .success();
        if !ok {
            return Err(format!("screenshot {name} failed"));
        }
        self.shots.push(file);
        Ok(())
    }

    fn point(&self, step: &Step) -> Result<(u32, u32), String> {
        if let Some([x, y]) = step.xy {
            return Ok((x, y));
        }
        let label = step.label.as_deref().unwrap_or_default();
        let dir = Path::new(screen::SEMANTICS_DIR);
        let deadline = Instant::now() + Duration::from_secs_f64(step.timeout_s);
        loop {
            let order = screen::search_order(step.within.as_deref(), &front()?);
            for applet in &order {
                if let Some(p) = screen::find(&screen::nodes(dir, applet), label)? {
                    return Ok(p);
                }
            }
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() || !self.sem.wait(left) {
                return Err(format!(
                    "no control labelled {label:?} in {}",
                    order.join(" or ")
                ));
            }
        }
    }

    fn expect(&self, step: &Step) -> Result<(), String> {
        let Some(e) = &step.expect else {
            return Ok(());
        };
        let dir = Path::new(screen::SEMANTICS_DIR);
        let deadline = Instant::now() + Duration::from_secs_f64(step.timeout_s);
        loop {
            let now_front = front()?;
            let order = screen::search_order(None, &now_front);
            let mut missing = Vec::new();
            if let Some(l) = &e.label {
                if !screen::shown(dir, &order, l) {
                    missing.push(format!("{l:?} is not shown"));
                }
            }
            if let Some(g) = &e.gone {
                if screen::shown(dir, &order, g) {
                    missing.push(format!("{g:?} is still shown"));
                }
            }
            if let Some(f) = &e.front {
                if *f != now_front {
                    missing.push(format!("{now_front} is in front, not {f}"));
                }
            }
            if missing.is_empty() {
                return Ok(());
            }
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() || !self.sem.wait(left) {
                return Err(format!(
                    "after {} s: {}",
                    step.timeout_s,
                    missing.join("; ")
                ));
            }
        }
    }

    fn act(&mut self, step: &Step) -> Result<(), String> {
        let io = |e: std::io::Error| format!("input: {e}");
        match step.action {
            Action::Tap => {
                let p = self.point(step)?;
                self.hands.press(p, 60).map_err(io)?;
            }
            Action::Hold => {
                let p = self.point(step)?;
                self.hands.press(p, step.ms.unwrap_or(800)).map_err(io)?;
            }
            Action::Swipe => {
                let p = self.point(step)?;
                let to = match (step.to, step.by) {
                    (Some([x, y]), _) => (x, y),
                    (None, Some([dx, dy])) => {
                        let clamp = |v: u32, d: i32, max: u32| {
                            (i64::from(v) + i64::from(d))
                                .clamp(0, i64::from(max.saturating_sub(1)))
                                as u32
                        };
                        (clamp(p.0, dx, self.panel.0), clamp(p.1, dy, self.panel.1))
                    }
                    (None, None) => return Err("a swipe needs to or by".to_owned()),
                };
                self.hands
                    .swipe(p, to, step.ms.unwrap_or(250))
                    .map_err(io)?;
            }
            Action::Key => {
                let code = step.key.as_deref().and_then(key_code).ok_or("no key")?;
                self.hands.key(code).map_err(io)?;
            }
            Action::Type => {
                for c in step.text.as_deref().unwrap_or_default().chars() {
                    let name = if c == ' ' {
                        "SPACE".to_owned()
                    } else {
                        c.to_string()
                    };
                    let code =
                        key_code(&name).ok_or_else(|| format!("no key for {c:?}"))?;
                    self.hands.key(code).map_err(io)?;
                }
            }
            Action::Wait => {
                std::thread::sleep(Duration::from_secs_f64(step.secs.unwrap_or(0.0)))
            }
            Action::Open => {
                let mut p = serde_json::json!({ "applet": step.applet });
                if let Some(r) = &step.route {
                    p["route"] = serde_json::json!(r);
                }
                host("Push", p)?;
            }
            Action::Back => {
                host("Pop", serde_json::json!({}))?;
            }
            Action::Home => {
                host("Home", serde_json::json!({}))?;
            }
            Action::Shot => {
                let name = step.name.clone().unwrap_or_default();
                self.shot(&name)?;
            }
        }
        self.expect(step)
    }

    /// Play steps; the first failure stops them.
    fn play(
        &mut self,
        phase: &'static str,
        rep: u32,
        steps: &[Step],
    ) -> Result<(), String> {
        for (i, step) in steps.iter().enumerate() {
            for _ in 0..step.repeat {
                let name = format!("step {} {}", i + 1, step.describe());
                let t0 = self.started.elapsed();
                if phase == "step" {
                    self.marks.begin(&name);
                }
                let result = self.act(step);
                if phase == "step" {
                    self.marks.end();
                }
                let t1 = self.started.elapsed();
                self.record_steps.push(StepRecord {
                    phase,
                    rep,
                    index: i + 1,
                    step: step.describe(),
                    start_ms: t0.as_millis() as u64,
                    ms: (t1 - t0).as_millis() as u64,
                    error: result.as_ref().err().cloned(),
                });
                result.map_err(|e| {
                    format!("{phase} {}: {}: {e}", i + 1, step.describe())
                })?;
            }
        }
        Ok(())
    }
}

/// The capture around the measured section: vrx-profile in the
/// foreground, stopped by SIGTERM (it forwards it to tracebox, which ends
/// the session and writes the trace). Its stdout is the trace's path.
struct Capture {
    child: std::process::Child,
}

impl Capture {
    fn start(config: &str) -> Result<Self, String> {
        let child = Command::new("vrx-profile")
            .args(["capture", config, "600"])
            .stdout(Stdio::piped())
            .spawn()
            .map_err(|e| {
                format!("vrx-profile: {e} (an image without meta-vrx-profiling?)")
            })?;
        // tracebox starts its data sources before the first event counts
        std::thread::sleep(Duration::from_secs(2));
        Ok(Self { child })
    }

    #[cfg(target_os = "linux")]
    fn terminate(&self) {
        use rustix::process::{kill_process, Pid, Signal};
        let _ = kill_process(Pid::from_child(&self.child), Signal::TERM);
    }

    #[cfg(not(target_os = "linux"))]
    fn terminate(&self) {}

    /// Stop it; the trace's file name in the store.
    fn stop(mut self) -> Result<String, String> {
        self.terminate();
        let mut path = String::new();
        if let Some(out) = self.child.stdout.take() {
            for line in BufReader::new(out).lines().map_while(Result::ok) {
                path = line;
            }
        }
        let status = self.child.wait().map_err(|e| format!("vrx-profile: {e}"))?;
        if !status.success() || path.is_empty() {
            return Err(format!("the capture did not finish whole ({status}); no summary from a partial trace"));
        }
        Ok(Path::new(&path)
            .file_name()
            .map(|f| f.to_string_lossy().into_owned())
            .unwrap_or(path))
    }
}

fn stamp() -> String {
    Command::new("date")
        .args(["-u", "+%Y%m%dT%H%M%SZ"])
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_owned())
        .unwrap_or_else(|| "now".to_owned())
}

fn arg<'a>(args: &'a [String], flag: &str) -> Option<&'a str> {
    args.windows(2)
        .find(|w| w[0] == flag)
        .map(|w| w[1].as_str())
}

/// Copy the fixtures into the applets' state, stopped, owned by them.
fn fixtures(walk: &Walk, dir: &Path) -> Result<(), String> {
    for f in &walk.setup.fixture {
        systemctl("stop", &f.applet)?;
        let to = Path::new("/var/lib/vrx").join(&f.applet).join(&f.to);
        if let Some(parent) = to.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|e| format!("{}: {e}", parent.display()))?;
        }
        std::fs::copy(dir.join(&f.from), &to)
            .map_err(|e| format!("fixture {}: {e}", f.from))?;
        let user = format!("vrx-{0}:vrx-{0}", f.applet);
        let ok = Command::new("chown")
            .args(["-R", &user, &format!("/var/lib/vrx/{}", f.applet)])
            .status()
            .map_err(|e| format!("chown: {e}"))?
            .success();
        if !ok {
            return Err(format!("chown {user} failed"));
        }
    }
    Ok(())
}

fn run(args: &[String]) -> Result<ExitCode, String> {
    let file = PathBuf::from(
        args.first()
            .ok_or("run <file.walk> [--scanout <scanout.py>]")?,
    );
    let text =
        std::fs::read_to_string(&file).map_err(|e| format!("{}: {e}", file.display()))?;
    let walk = Walk::parse(&text).map_err(|e| format!("{}: {e}", file.display()))?;
    let dir = file.parent().unwrap_or(Path::new(".")).to_owned();
    let board = Board::system();
    if let Some(why) = board.unfit() {
        eprintln!("vrx-walk: refused, the board is unfit to measure: {why}");
        return Ok(ExitCode::from(3));
    }
    let panel = board
        .panel()
        .ok_or("no connected panel in /sys/class/drm")?;
    let budgets = board.budgets()?;
    std::fs::create_dir_all(STORE).map_err(|e| format!("{STORE}: {e}"))?;

    let was_profiling = host("Profiling", serde_json::json!({}))?
        .get("on")
        .and_then(serde_json::Value::as_bool)
        .unwrap_or(false);
    let status = host("Profiling", serde_json::json!({ "on": true }))?;
    if status.get("available").and_then(serde_json::Value::as_bool) == Some(false) {
        return Err(format!(
            "profiling is not available: {}",
            status
                .get("reason")
                .and_then(|r| r.as_str())
                .unwrap_or("built without profiling")
        ));
    }
    host("Semantics", serde_json::json!({ "on": true }))?;
    let restore = || {
        let _ = host("Semantics", serde_json::json!({ "on": false }));
        let _ = host("Profiling", serde_json::json!({ "on": was_profiling }));
    };

    let outcome = (|| -> Result<(Record, bool), String> {
        fixtures(&walk, &dir)?;
        let mut applets: Vec<&String> = walk
            .setup
            .restart
            .iter()
            .chain(walk.setup.fixture.iter().map(|f| &f.applet))
            .collect();
        applets.sort();
        applets.dedup();
        for a in applets {
            systemctl("restart", a)?;
        }
        let sem_dir = Path::new(screen::SEMANTICS_DIR);
        let mut r = Run {
            started: Instant::now(),
            stamp: stamp(),
            walk: walk.clone(),
            scanout: arg(args, "--scanout").map(PathBuf::from),
            hands: Hands::new(panel.0, panel.1).map_err(|e| format!("uinput: {e}"))?,
            marks: Marks::open()?,
            sem: screen::Changes::watch(sem_dir)
                .map_err(|e| format!("{}: {e}", sem_dir.display()))?,
            panel,
            record_steps: Vec::new(),
            shots: Vec::new(),
        };
        let mut failed = r.play("prepare", 1, &walk.prepare).err();
        let mut trace = None;
        if failed.is_none() {
            std::thread::sleep(Duration::from_secs_f64(walk.setup.warmup_s));
            let capture = Capture::start(&walk.setup.capture)?;
            r.marks.begin(&format!("walk:{}", walk.name));
            for rep in 1..=walk.repeat {
                if walk.repeat > 1 {
                    r.marks.begin(&format!("rep {rep}"));
                }
                let result = r.play("step", rep, &walk.step);
                if walk.repeat > 1 {
                    r.marks.end();
                }
                if let Err(e) = result {
                    failed = Some(e);
                    break;
                }
            }
            r.marks.end();
            if failed.is_none() {
                std::thread::sleep(COOLDOWN);
            }
            match capture.stop() {
                Ok(t) => trace = Some(t),
                Err(e) => failed = failed.or(Some(e)),
            }
        }
        if let Some(f) = &failed {
            eprintln!("vrx-walk: {f}");
            if let Err(e) = r.shot("failed") {
                eprintln!("vrx-walk: {e}");
            }
        }
        let unfit = board.unfit();
        let ok = failed.is_none() && unfit.is_none();
        Ok((
            Record {
                walk: walk.clone(),
                started: r.stamp.clone(),
                panel: r.panel,
                budgets,
                steps: r.record_steps,
                trace,
                shots: r.shots,
                failed,
                unfit,
            },
            ok,
        ))
    })();
    restore();
    let (record, ok) = outcome?;

    let name = format!("{}-walk-{}.json", record.started, walk.name);
    let json = serde_json::to_string_pretty(&record).map_err(|e| e.to_string())?;
    std::fs::write(Path::new(STORE).join(&name), json)
        .map_err(|e| format!("{name}: {e}"))?;
    for f in record.trace.iter().chain(&record.shots) {
        println!("{f}");
    }
    println!("{name}");
    Ok(if ok {
        ExitCode::SUCCESS
    } else if record.unfit.is_some() {
        eprintln!(
            "vrx-walk: the board became unfit during the run: {}",
            record.unfit.as_deref().unwrap_or("")
        );
        ExitCode::from(3)
    } else {
        ExitCode::FAILURE
    })
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let result = match args.first().map(String::as_str) {
        Some("run") => run(&args[1..]),
        Some("ready") => Ok(match Board::system().unfit() {
            None => ExitCode::SUCCESS,
            Some(why) => {
                eprintln!("vrx-walk: unfit: {why}");
                ExitCode::from(3)
            }
        }),
        _ => Err("run <file.walk> [--scanout <scanout.py>] | ready".to_owned()),
    };
    result.unwrap_or_else(|e| {
        eprintln!("vrx-walk: {e}");
        ExitCode::FAILURE
    })
}
