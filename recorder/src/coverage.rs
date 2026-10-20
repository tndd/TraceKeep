//! Bounded current-run heartbeat aggregation; no provider calls.
use serde_json::{json, Map, Value};
use std::{
    io,
    path::Path,
    time::{Duration, Instant},
};

pub const MODULES: &[&str] = &[
    "performance",
    "processes",
    "gpuDetails",
    "inventory",
    "reliability",
    "power",
    "dumpArchive",
    "werArchive",
    "diskSpace",
    "storage",
    "crashConfiguration",
    "configurationJournal",
];

fn enabled(config: &Value, name: &str) -> bool {
    if name == "storage" {
        return ["storage", "nvme", "nvmeErrors"]
            .iter()
            .any(|n| config["modules"][n]["enabled"] != false);
    }
    config["modules"][name]["enabled"] != false
}
pub fn collect(
    data: &Path,
    config: &Value,
    run_id: &str,
    now: chrono::DateTime<chrono::Local>,
) -> Value {
    let mut modules = Map::new();
    let mut errors = Vec::new();
    for name in MODULES {
        if !enabled(config, name) {
            modules.insert((*name).into(), json!({"status":"disabled","enabled":false}));
            continue;
        }
        let state = (|| -> Result<Value, String> {
            let bytes = crate::storage::read_shared(
                &data.join("module-state").join(format!("{name}.json")),
                262144,
            )
            .map_err(|e| e.to_string())?;
            let state: Value = serde_json::from_slice(&bytes).map_err(|e| e.to_string())?;
            if state["runId"] != run_id {
                return Err("No observation from this recorder run".into());
            }
            let time = chrono::DateTime::parse_from_rfc3339(
                state["time"].as_str().ok_or("Missing heartbeat time")?,
            )
            .map_err(|e| e.to_string())?;
            let age = (now - time).num_milliseconds();
            if !(-5000..=45000).contains(&age) {
                return Err("Module heartbeat is stale".into());
            }
            if !state["status"].is_string() {
                return Err("Missing module status".into());
            }
            Ok(state)
        })()
        .unwrap_or_else(|error| json!({"status":"unavailable","enabled":true,"error":error}));
        if matches!(
            state["status"].as_str(),
            Some("error" | "unavailable" | "pending")
        ) {
            errors.push(json!({"module":name,"error":state["error"],"status":state["status"]}));
        }
        modules.insert((*name).into(), state);
    }
    json!({"time":now.to_rfc3339(),"event":"heartbeat","runId":run_id,"modules":modules,"errors":errors})
}
pub fn run(options: &crate::Options, config: &Value) -> io::Result<()> {
    let _owner = crate::storage::exclusive(&options.logs.join("extended.owner.lock"))?;
    let data = options
        .logs
        .parent()
        .ok_or_else(|| io::Error::other("Missing data root"))?;
    let stop = options.logs.join("STOP-EXTENDED");
    let mut count = 0;
    while !stop.exists() {
        let row = collect(data, config, &options.run_id, chrono::Local::now());
        crate::storage::append(
            &options
                .logs
                .join(format!("extended-{}.jsonl", crate::day())),
            &row,
        )?;
        crate::storage::snapshot(&data.join("coverage.json"), &row)?;
        count += 1;
        if options.samples > 0 && count >= options.samples {
            break;
        }
        let until = Instant::now() + Duration::from_secs(15);
        while Instant::now() < until && !stop.exists() {
            std::thread::sleep(Duration::from_millis(250));
        }
    }
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_stale_wrong_run_truncated_and_future_states_without_hiding_other_modules() {
        let root = std::env::temp_dir().join(format!(
            "coverage-test-{}-{}",
            std::process::id(),
            crate::ticks().0
        ));
        std::fs::create_dir_all(root.join("module-state")).unwrap();
        let now = chrono::Local::now();
        let config = json!({"modules":{"power":{"enabled":false},"storage":{"enabled":false},"nvme":{"enabled":false},"nvmeErrors":{"enabled":true}}});
        for (name, run, time) in [
            ("processes", "run", now),
            ("inventory", "old", now),
            ("diskSpace", "run", now - chrono::Duration::seconds(46)),
            ("reliability", "run", now + chrono::Duration::seconds(6)),
        ] {
            crate::storage::snapshot(
                &root.join(format!("module-state/{name}.json")),
                &json!({"runId":run,"time":time.to_rfc3339(),"status":"ok"}),
            )
            .unwrap();
        }
        std::fs::write(root.join("module-state/performance.json"), "{").unwrap();
        let row = collect(&root, &config, "run", now);
        assert_eq!(row["modules"]["processes"]["status"], "ok");
        assert_eq!(row["modules"]["power"]["status"], "disabled");
        for name in [
            "inventory",
            "diskSpace",
            "reliability",
            "performance",
            "storage",
        ] {
            assert_eq!(row["modules"][name]["status"], "unavailable");
        }
    }
}
