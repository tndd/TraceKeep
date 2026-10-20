mod activity;
mod collect;
mod command;
mod coverage;
mod crash;
mod diagnostics;
mod inventory;
mod maintenance;
mod metrics;
mod space;
mod storage;

use chrono::{Local, SecondsFormat};
use serde_json::{json, Value};
use std::{
    fs, io,
    path::PathBuf,
    time::{Duration, Instant},
};

fn now() -> String {
    Local::now().to_rfc3339_opts(SecondsFormat::Nanos, false)
}
fn day() -> String {
    Local::now().format("%Y%m%d").to_string()
}
#[cfg(windows)]
fn ticks() -> (i64, i64) {
    use windows_sys::Win32::System::Performance::{
        QueryPerformanceCounter, QueryPerformanceFrequency,
    };
    let (mut counter, mut frequency) = (0, 0);
    unsafe {
        QueryPerformanceCounter(&mut counter);
        QueryPerformanceFrequency(&mut frequency);
    }
    (counter, frequency)
}
#[cfg(not(windows))]
fn ticks() -> (i64, i64) {
    (0, 1)
}

struct Recorder {
    logs: PathBuf,
    module: String,
    run_id: String,
    session: String,
    baseline: Option<(String, String)>,
}
impl Recorder {
    fn new(logs: PathBuf, module: String, run_id: String) -> Self {
        // PID plus QPC and wall time also separates PID reuse across reboots.
        let session = format!(
            "{}-{}-{}",
            std::process::id(),
            ticks().0,
            chrono::Utc::now().timestamp_nanos_opt().unwrap_or_default()
        );
        Self {
            logs,
            module,
            run_id,
            session,
            baseline: None,
        }
    }
    fn state(&self, mut state: Value) -> io::Result<()> {
        state["time"] = json!(now());
        state["runId"] = json!(self.run_id);
        state["session"] = json!(self.session);
        state["pid"] = json!(std::process::id());
        state["event"] = json!("heartbeat");
        state["enabled"] = json!(true);
        state["backend"] = json!("rust");
        state["errors"] = if state["status"] == "error" {
            json!([{"module":self.module,"error":state["error"]}])
        } else {
            json!([])
        };
        storage::append(
            &self
                .logs
                .join(format!("module-{}-{}.jsonl", self.module, day())),
            &state,
        )?;
        let directory = self
            .logs
            .parent()
            .ok_or_else(|| io::Error::other("Missing data root"))?
            .join("module-state");
        fs::create_dir_all(&directory)?;
        storage::snapshot(&directory.join(format!("{}.json", self.module)), &state)
    }
    fn result(
        &mut self,
        result: Value,
        started: &str,
        duration_ms: u64,
        sequence: u64,
        schedule: &Value,
        at: chrono::DateTime<Local>,
    ) -> io::Result<()> {
        let date = at.format("%Y%m%d").to_string();
        let hash = storage::sha(&storage::json_bytes(&result)?);
        let unchanged = self
            .baseline
            .as_ref()
            .is_some_and(|(d, h)| d == &date && h == &hash);
        let (counter, frequency) = ticks();
        let mut row = json!({"time":at.to_rfc3339_opts(SecondsFormat::Nanos,false),"startedAt":started,"monotonicTicks":counter,"monotonicFrequency":frequency,
            "module":self.module,"durationMs":duration_ms,"status":result["status"],
            "sha256":hash,"unchanged":unchanged,"session":self.session,"sequence":sequence,
            "schedule":schedule,"backend":"rust"});
        if !unchanged {
            row["result"] = result;
        }
        storage::append(
            &self
                .logs
                .join(format!("detail-{}-{date}.jsonl", self.module)),
            &row,
        )?;
        // Never publish a reference to a record whose durable write failed.
        self.baseline = Some((date, hash));
        Ok(())
    }
}

struct Options {
    logs: PathBuf,
    settings: PathBuf,
    module: String,
    run_id: String,
    samples: u64,
    interval_ms: Option<u64>,
}
impl Options {
    fn parse(args: impl IntoIterator<Item = String>) -> Result<Self, String> {
        let mut values = std::collections::HashMap::new();
        let mut args = args.into_iter();
        while let Some(key) = args.next() {
            if ![
                "--log-root",
                "--settings",
                "--module",
                "--run-id",
                "--samples",
                "--interval-ms",
            ]
            .contains(&key.as_str())
            {
                return Err(format!("Unknown argument: {key}"));
            }
            let value = args.next().ok_or("Argument needs a value")?;
            if values.insert(key, value).is_some() {
                return Err("Duplicate argument".into());
            }
        }
        let mut required = |key: &str| {
            values
                .remove(key)
                .filter(|s| !s.is_empty())
                .ok_or_else(|| format!("Missing {key}"))
        };
        let logs = PathBuf::from(required("--log-root")?);
        let settings = PathBuf::from(required("--settings")?);
        let module = required("--module")?;
        let run_id = required("--run-id")?;
        if ![
            "activity",
            "configurationJournal",
            "processes",
            "performance",
            "reliability",
            "diskSpace",
            "inventory",
            "crashConfiguration",
            "power",
            "gpuDetails",
            "extended",
            "maintenance",
        ]
        .contains(&module.as_str())
        {
            return Err("Unsupported Rust module".into());
        }
        if !logs.is_absolute() || !settings.is_absolute() {
            return Err("Paths must be absolute".into());
        }
        let samples = values
            .remove("--samples")
            .map(|s| s.parse::<u64>())
            .transpose()
            .map_err(|_| "Invalid sample count")?
            .unwrap_or(0);
        let interval_ms = values
            .remove("--interval-ms")
            .map(|s| s.parse::<u64>())
            .transpose()
            .map_err(|_| "Invalid sampling interval")?;
        if interval_ms.is_some_and(|v| module != "activity" || !(1000..=5000).contains(&v)) {
            return Err("Activity interval must be 1000..5000 ms".into());
        }
        Ok(Self {
            interval_ms,
            logs,
            settings,
            module,
            run_id,
            samples,
        })
    }
}

fn interval(settings: &Value, module: &str) -> Result<Option<Duration>, String> {
    if settings["schemaVersion"] != 1 {
        return Err("Unsupported settings schema".into());
    }
    let defaults = match module {
        "activity" => 2,
        "processes" => 30,
        "reliability" | "power" | "crashConfiguration" => 300,
        "inventory" => 1800,
        "gpuDetails" => 60,
        "diskSpace" => 60,
        _ => 15,
    };
    let entry = &settings["modules"][module];
    if entry["enabled"] == false {
        return Ok(None);
    }
    if !entry.is_null() && entry["enabled"] != true {
        return Err("Enabled must be boolean".into());
    }
    let seconds = if entry["intervalSeconds"].is_null() {
        defaults
    } else {
        entry["intervalSeconds"]
            .as_u64()
            .ok_or("Invalid interval")?
    };
    let range = if module == "activity" {
        1..=5
    } else {
        15..=86400
    };
    if !range.contains(&seconds) {
        return Err("Interval out of range".into());
    }
    Ok(Some(Duration::from_secs(seconds)))
}

fn advance(due: Duration, finished: Duration, interval: Duration) -> (Duration, u64) {
    let mut next = due + interval;
    let missed = if next < finished {
        (finished - next).as_nanos().div_ceil(interval.as_nanos()) as u64
    } else {
        0
    };
    next += interval.saturating_mul(missed.min(u32::MAX as u64) as u32);
    (next, missed)
}

fn record_loop(
    options: &Options,
    interval: Duration,
    mut collect: impl FnMut() -> Value,
) -> io::Result<()> {
    fs::create_dir_all(&options.logs)?;
    // Also held by the PowerShell fallback, preventing mixed-backend writers.
    let _owner = storage::exclusive(
        &options
            .logs
            .join(format!("module-{}.owner.lock", options.module)),
    )?;
    let mut recorder = Recorder::new(
        options.logs.clone(),
        options.module.clone(),
        options.run_id.clone(),
    );
    let clock = Instant::now();
    let mut due = Duration::ZERO;
    let mut last = None;
    let mut sequence = 0u64;
    let mut missed = 0u64;
    let stop = options.logs.join("STOP-EXTENDED");
    while !stop.exists() {
        let start = clock.elapsed();
        let started = now();
        let timer = Instant::now();
        let mut schedule = json!({"configuredIntervalSeconds":interval.as_secs(),
            "latenessMs":start.saturating_sub(due).as_millis() as u64,
            "actualIntervalMs":last.map(|v:Duration|(start-v).as_millis() as u64),"missedIntervals":missed});
        last = Some(start);
        recorder.state(json!({"status":"collecting","startedAt":started,"sequence":sequence,"schedule":schedule}))?;
        // Provider calls run only here, never in the coordinator or another worker.
        let result = collect();
        let crash_snapshot =
            (options.module == "crashConfiguration").then(|| result["data"].clone());
        let status = result["status"].clone();
        let issues = result["issues"].clone();
        let duration = timer.elapsed().as_millis() as u64;
        recorder.result(
            result,
            &started,
            duration,
            sequence,
            &schedule,
            Local::now(),
        )?;
        if let Some(crash) = crash_snapshot {
            storage::snapshot(
                &options
                    .logs
                    .parent()
                    .unwrap()
                    .join("crash-configuration.json"),
                &crash,
            )?;
        }
        let completed = now();
        let (next, skipped) = advance(due, clock.elapsed(), interval);
        due = next;
        missed += skipped;
        schedule["missedIntervals"] = json!(missed);
        let state = json!({"status":status,"completedAt":completed,"sequence":sequence,"durationMs":duration,"issues":issues,"schedule":schedule});
        recorder.state(state.clone())?;
        sequence += 1;
        if options.samples > 0 && sequence >= options.samples {
            break;
        }
        let mut heartbeat = clock.elapsed() + Duration::from_secs(15);
        while clock.elapsed() < due && !stop.exists() {
            std::thread::sleep(
                due.saturating_sub(clock.elapsed())
                    .min(Duration::from_millis(250)),
            );
            if clock.elapsed() >= heartbeat {
                recorder.state(state.clone())?;
                heartbeat = clock.elapsed() + Duration::from_secs(15);
            }
        }
    }
    Ok(())
}

#[cfg(windows)]
fn run(options: &Options) -> Result<(), String> {
    let settings: Value = serde_json::from_slice(
        &storage::read_shared(&options.settings, 262144).map_err(|e| e.to_string())?,
    )
    .map_err(|e| e.to_string())?;
    fs::create_dir_all(&options.logs).map_err(|e| e.to_string())?;
    if options.module == "activity" {
        return activity::run(options, &settings);
    }
    if options.module == "extended" {
        return coverage::run(options, &settings).map_err(|e| e.to_string());
    }
    if options.module == "maintenance" {
        return maintenance::run(options).map_err(|e| e.to_string());
    }
    let Some(interval) = interval(&settings, &options.module)? else {
        return Ok(());
    };
    let data = options.logs.parent().ok_or("Log root has no parent")?;
    let mut processes = collect::Processes::new();
    let mut metrics = metrics::Reader::default();
    let mut thermal = metrics::Reader::namespace("ROOT/WMI");
    let reserve = if options.module == "diskSpace" {
        space::reserve(&settings)?
    } else {
        0
    };
    record_loop(options, interval, || match options.module.as_str() {
        "configurationJournal" => collect::journal(data, collect::registry()),
        "processes" => processes.collect(),
        "performance" => metrics.performance(),
        "power" => diagnostics::power(&mut metrics,&mut thermal),
        "gpuDetails" => diagnostics::gpu(),
        "crashConfiguration" => crash::collect(data,&mut metrics),
        "inventory" => {
            let machine=metrics.machine();
            let saved=storage::snapshot(&data.join("machine-inventory.json"),&machine);
            let mut result=metrics.inventory();
            for issue in machine["errors"].as_array().unwrap() { result["issues"].as_array_mut().unwrap().push(json!({"source":"machine-inventory","status":"unavailable","error":issue})); }
            if let Err(error)=saved { result["issues"].as_array_mut().unwrap().push(json!({"source":"machine-inventory.json","status":"unavailable","error":error.to_string()})); }
            if !result["issues"].as_array().unwrap().is_empty(){result["status"]=json!("partial");}
            result
        },
        "reliability" => metrics.reliability(),
        "diskSpace" => space::collect(data, reserve),
        _ => unreachable!(),
    })
    .map_err(|e| e.to_string())
}
#[cfg(not(windows))]
fn run(_: &Options) -> Result<(), String> {
    Err("Windows is required".into())
}

fn main() {
    let options = match Options::parse(std::env::args().skip(1)) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(1)
        }
    };
    if let Err(error) = run(&options) {
        if options.module == "activity" {
            let _ = storage::append(
                &options.logs.join(format!("errors-{}.jsonl", day())),
                &json!({"time":now(),"error":error,"pid":std::process::id(),"runId":options.run_id}),
            );
        }
        // Best effort only: an unwritable disk must not be reported as success.
        let _ = storage::snapshot(
            &options
                .logs
                .join(format!("rust-{}-last-error.json", options.module)),
            &json!({"time":now(),"status":"error","error":error,"pid":std::process::id(),"runId":options.run_id}),
        );
        eprintln!("{error}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn root() -> PathBuf {
        let root = std::env::temp_dir().join(format!(
            "tracekeep-worker-test-{}",
            chrono::Utc::now().timestamp_nanos_opt().unwrap()
        ));
        fs::create_dir_all(root.join("logs")).unwrap();
        root
    }
    #[test]
    fn interval_and_overruns_are_explicit() {
        assert!(interval(&json!({"schemaVersion":1,"modules":{"processes":{"enabled":true,"intervalSeconds":0}}}),"processes").is_err());
        assert_eq!(
            interval(
                &json!({"schemaVersion":1,"modules":{"processes":{"enabled":false}}}),
                "processes"
            )
            .unwrap(),
            None
        );
        assert_eq!(
            advance(
                Duration::ZERO,
                Duration::from_secs(31),
                Duration::from_secs(15)
            ),
            (Duration::from_secs(45), 2)
        );
    }
    #[test]
    fn starts_before_collection_and_only_completes_after_durable_result() {
        let root = root();
        let options = Options {
            logs: root.join("logs"),
            settings: root.join("unused"),
            module: "configurationJournal".into(),
            run_id: "synthetic".into(),
            samples: 1,
            interval_ms: None,
        };
        record_loop(&options,Duration::from_secs(15),||{
            let state:Value=serde_json::from_slice(&fs::read(root.join("module-state/configurationJournal.json")).unwrap()).unwrap();
            assert_eq!(state["status"],"collecting");assert!(state["completedAt"].is_null());
            json!({"status":"partial","data":{},"issues":[{"source":"synthetic","status":"unavailable"}]})
        }).unwrap();
        let state: Value = serde_json::from_slice(
            &fs::read(root.join("module-state/configurationJournal.json")).unwrap(),
        )
        .unwrap();
        assert_eq!(state["status"], "partial");
        assert!(state["completedAt"].is_string());
        assert_eq!(state["runId"], "synthetic");
    }
    fn stamp(day: &str) -> chrono::DateTime<Local> {
        chrono::DateTime::parse_from_str(&format!("{day}T12:00:00+0000"), "%Y%m%dT%H:%M:%S%z")
            .unwrap()
            .with_timezone(&Local)
    }
    #[test]
    fn restart_midnight_and_failed_write_keep_resolvable_baselines() {
        let root = root();
        let mut recorder = Recorder::new(root.join("logs"), "processes".into(), "run".into());
        let result = json!({"status":"ok","data":{"processes":[]},"issues":[]});
        for date in ["20261020", "20261020", "20261021"] {
            recorder
                .result(result.clone(), &now(), 1, 0, &json!({}), stamp(date))
                .unwrap();
        }
        let rows: Vec<Value> =
            fs::read_to_string(root.join("logs/detail-processes-20261020.jsonl"))
                .unwrap()
                .lines()
                .map(|s| serde_json::from_str(s).unwrap())
                .collect();
        assert_eq!(rows[0]["unchanged"], false);
        assert_eq!(rows[1]["unchanged"], true);
        let next: Value = serde_json::from_slice(
            &fs::read(root.join("logs/detail-processes-20261021.jsonl")).unwrap(),
        )
        .unwrap();
        assert_eq!(next["unchanged"], false);
        let mut restart = Recorder::new(root.join("logs"), "processes".into(), "run".into());
        assert_ne!(restart.session, recorder.session);
        restart
            .result(result.clone(), &now(), 1, 0, &json!({}), stamp("20261021"))
            .unwrap();
        let failed_path = root.join("logs/detail-processes-20261022.jsonl");
        fs::create_dir(&failed_path).unwrap();
        assert!(restart
            .result(result, &now(), 1, 0, &json!({}), stamp("20261022"))
            .is_err());
        assert_eq!(restart.baseline.unwrap().0, "20261021");
    }
}
