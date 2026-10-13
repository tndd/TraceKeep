use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{collections::{BTreeMap, VecDeque}, fs::{self, File}, io::{Read, Seek, SeekFrom}, path::PathBuf};

const MAX_READ: u64 = 8 * 1024 * 1024;
const HISTORY: usize = 450;

pub mod recorder_status;
#[cfg(windows)]
pub mod desktop;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Sources { pub sensor_root: PathBuf, pub activity_root: PathBuf }

pub fn app_dir() -> PathBuf {
    std::env::var_os("LOCALAPPDATA").map(PathBuf::from).unwrap_or_else(std::env::temp_dir).join("PCDiagnostics")
}
pub fn machine_dir() -> PathBuf {
    std::env::var_os("ProgramData").map(PathBuf::from).unwrap_or_else(||PathBuf::from("C:\\ProgramData")).join("PCDiagnostics")
}
impl Default for Sources {
    fn default() -> Self {
        Self { sensor_root: std::env::var_os("ProgramFiles").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("C:\\Program Files")).join("CodexPCDiagnostics/sensor-logs"), activity_root: app_dir().join("logs") }
    }
}
impl Sources {
    pub fn load() -> Result<Self, String> {
        let shared=machine_dir().join("sources.json");
        if shared.exists() { return serde_json::from_slice(&fs::read(shared).map_err(|e|e.to_string())?).map_err(|e|format!("Invalid machine source configuration: {e}")); }
        let path = app_dir().join("sources.json");
        if !path.exists() { return Ok(Self::default()); }
        serde_json::from_slice(&fs::read(path).map_err(|e| e.to_string())?).map_err(|e| format!("Invalid source configuration: {e}"))
    }
    pub fn save(&self) -> Result<(), String> {
        if machine_dir().join("sources.json").exists() { return Err("Unified recording is configured. Use pcdiag logs to inspect its shared location; per-user source overrides are disabled.".into()); }
        if !self.sensor_root.is_dir() || !self.activity_root.is_dir() { return Err("Both log directories must exist.".into()); }
        fs::create_dir_all(app_dir()).map_err(|e| e.to_string())?;
        fs::write(app_dir().join("sources.json"), serde_json::to_vec_pretty(self).unwrap()).map_err(|e| e.to_string())
    }
}

fn millis(time: &str) -> Option<i64> { DateTime::parse_from_rfc3339(time).ok().map(|t| t.timestamp_millis()) }
fn row_time(row: &Value) -> Option<i64> { millis(row.get("time")?.as_str()?) }
fn sensor(row: &Value, id: &str) -> Value {
    row["sensors"].as_array().and_then(|s| s.iter().find(|v| v["id"] == id)).map(|v| v["value"].clone()).unwrap_or(Value::Null)
}
fn numeric(value: &Value) -> Value {
    if value.is_number() { return value.clone(); }
    value.as_str().and_then(|s| s.parse::<f64>().ok()).filter(|v| v.is_finite()).map(|v| json!(v)).unwrap_or(Value::Null)
}
fn compact(kind: &str, row: &Value) -> Value {
    let mut point = json!({"time":row["time"],"session":row["session"],"sequence":row["sequence"]});
    match kind {
        "cpu" => { point["cpuTemp"] = sensor(row,"/amdcpu/0/temperature/2"); point["cpuPower"] = sensor(row,"/amdcpu/0/power/0"); }
        "board" => {
            for (key, id) in [("v12","voltage/0"),("v5","voltage/1"),("v33","voltage/8"),("vrm","temperature/2"),("fan","fan/0")] { point[key] = sensor(row,&format!("/lpc/nct6687d/0/{id}")); }
        }
        "activity" => { let gpu = &row["gpu"][0]; point["gpuTemp"] = numeric(&gpu["temperatureC"]); point["gpuPower"] = numeric(&gpu["powerW"]); point["cpuLoad"] = row["cpuLoadPercent"].clone(); point["gpu"] = gpu.clone(); }
        _ => {}
    }
    point
}

pub struct LogReader {
    root: PathBuf, prefix: String, path: Option<PathBuf>, offset: u64, pending: Vec<u8>,
    pub rows: VecDeque<Value>, pub error: Option<String>, invalid: u64,
}
impl LogReader {
    pub fn new(root: PathBuf, prefix: &str) -> Self { Self {root,prefix:prefix.into(),path:None,offset:0,pending:vec![],rows:VecDeque::new(),error:None,invalid:0} }
    pub fn update(&mut self) { self.error = self.read().err().map(|e| e.to_string()); }
    fn read(&mut self) -> std::io::Result<()> {
        if !self.root.exists() { return Ok(()); }
        let newest = fs::read_dir(&self.root)?.filter_map(Result::ok).filter(|e| e.file_name().to_str().is_some_and(|s| s.starts_with(&self.prefix) && s.ends_with(".jsonl")))
            .filter_map(|e| e.metadata().ok().and_then(|m| m.modified().ok()).map(|t| (t,e.path()))).max_by_key(|(t,_)| *t).map(|(_,p)| p);
        if newest != self.path { self.path = newest; self.offset = 0; self.pending.clear(); }
        let Some(path) = &self.path else { return Ok(()); };
        let mut file = File::open(path)?;
        let size = file.metadata()?.len();
        if size < self.offset { self.offset = 0; self.pending.clear(); self.rows.clear(); }
        let skip = size.saturating_sub(self.offset) > MAX_READ;
        if skip { self.offset = size - MAX_READ; self.pending.clear(); }
        file.seek(SeekFrom::Start(self.offset))?;
        let mut bytes = Vec::new();
        let read = file.take(MAX_READ).read_to_end(&mut bytes)?;
        self.offset += read as u64;
        if skip { if let Some(i) = bytes.iter().position(|b| *b == b'\n') { bytes.drain(..=i); } else { bytes.clear(); } }
        self.pending.extend(bytes);
        let Some(end) = self.pending.iter().rposition(|b| *b == b'\n') else {
            if self.pending.len() > MAX_READ as usize { self.pending.clear(); self.invalid += 1; }
            return Ok(());
        };
        let complete: Vec<u8> = self.pending.drain(..=end).collect();
        for line in complete.split(|b| *b == b'\n') {
            if line.iter().all(u8::is_ascii_whitespace) { continue; }
            let line = line.strip_prefix(&[0xef,0xbb,0xbf]).unwrap_or(line);
            match serde_json::from_slice::<Value>(line) {
                Ok(row) if row_time(&row).is_some() => { self.rows.push_back(row); if self.rows.len() > HISTORY { self.rows.pop_front(); } }
                _ => self.invalid += 1,
            }
        }
        Ok(())
    }
    fn view(&self, kind: &str, now: i64) -> Value {
        let last = self.rows.back();
        let age = last.and_then(row_time).map(|t| (now-t) as f64/1000.0);
        let state = if self.error.is_some() {"error"} else if kind == "events" {"archive"} else { match age {None=>"missing",Some(v) if v < -5.0=>"clock",Some(v) if v > 10.0=>"stale",_=>"recording"} };
        let history:Vec<Value> = if kind == "events" {vec![]} else { self.rows.iter().map(|r|compact(kind,r)).collect() };
        let gaps:Vec<Value> = history.windows(2).filter_map(|w| { let gap=row_time(&w[1])?-row_time(&w[0])?; (gap > 6000).then(||json!({"time":w[1]["time"],"seconds":gap as f64/1000.0,"sessionChanged":w[0]["session"]!=w[1]["session"]})) }).collect();
        json!({"state":state,"age":age,"path":self.path,"error":self.error,"invalidLines":self.invalid,"latest":if kind=="events"{None}else{last},"history":history,"gaps":gaps.into_iter().rev().take(10).collect::<Vec<_>>()})
    }
}

pub struct Monitor { pub sources: Sources, readers: BTreeMap<String,LogReader> }
impl Monitor {
    pub fn new(sources: Sources) -> Self {
        let readers=[("cpu",&sources.sensor_root,"cpu-auto-"),("board",&sources.sensor_root,"board-auto-"),("activity",&sources.activity_root,"activity-"),("events",&sources.activity_root,"events-")].into_iter().map(|(key,root,prefix)|(key.into(),LogReader::new(root.clone(),prefix))).collect();
        Self {sources,readers}
    }
    pub fn snapshot(&mut self) -> Value {
        let now = Utc::now();
        for reader in self.readers.values_mut() { reader.update(); }
        let streams: BTreeMap<_,_> = self.readers.iter().map(|(key,r)|(key,r.view(key,now.timestamp_millis()))).collect();
        let events:Vec<Value> = self.readers["events"].rows.iter().rev().take(20).map(|r|json!({"time":r["time"],"provider":r["provider"],"id":r["id"],"level":r["level"]})).collect();
        let mut snapshot=json!({"app":"PC Diagnostics","version":2,"time":now.to_rfc3339(),"streams":streams,"events":events,"sources":self.sources});
        snapshot["coordinator"]=recorder_status::read_coordinator();
        snapshot["recorder"]=recorder_status::summary(&snapshot["coordinator"]);
        if let Some(workers)=snapshot["coordinator"]["runtime"]["workers"].as_array().cloned() {
            for worker in workers { if worker["enabled"]==false && worker["state"]=="disabled" {
                if let Some(name)=worker["name"].as_str() { if let Some(stream)=snapshot["streams"].get_mut(name) {stream["state"]=json!("disabled");} }
            } }
        }
        snapshot
    }
}

pub fn export_snapshot(value: &Value) -> Result<PathBuf,String> {
    let folder = app_dir().join("snapshots");
    fs::create_dir_all(&folder).map_err(|e|e.to_string())?;
    let path=folder.join(format!("diagnostics-{}.json",Utc::now().format("%Y%m%d-%H%M%S-%f")));
    fs::write(&path,serde_json::to_vec_pretty(value).map_err(|e|e.to_string())?).map_err(|e|e.to_string())?;
    Ok(path)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    struct Fixture(PathBuf);
    impl Fixture { fn new() -> Self { let path=std::env::temp_dir().join(format!("diagnostics-test-{}-{}",std::process::id(),Utc::now().timestamp_nanos_opt().unwrap())); fs::create_dir_all(&path).unwrap(); Self(path) } }
    impl Drop for Fixture {fn drop(&mut self){let _=fs::remove_dir_all(&self.0);}}
    #[test] fn partial_corrupt_and_truncated() {
        let dir=Fixture::new();let path=dir.0.join("cpu-auto-test.jsonl");
        let row=json!({"time":Utc::now().to_rfc3339(),"sequence":1}).to_string();
        fs::write(&path,&row[..15]).unwrap();let mut reader=LogReader::new(dir.0.clone(),"cpu-auto-");reader.update();assert!(reader.rows.is_empty());
        writeln!(fs::OpenOptions::new().append(true).open(&path).unwrap(),"{}\nbad",&row[15..]).unwrap();reader.update();assert_eq!(reader.rows.len(),1);assert_eq!(reader.invalid,1);
        fs::write(&path,b"\n").unwrap();reader.update();assert!(reader.rows.is_empty());
    }
    #[test] fn stale_and_quiet_events_are_distinct() {
        let dir=Fixture::new();let old=Utc::now()-chrono::Duration::seconds(30);
        fs::write(dir.0.join("cpu-auto-test.jsonl"),format!("{}\n",json!({"time":old.to_rfc3339()}))).unwrap();
        let mut monitor=Monitor::new(Sources{sensor_root:dir.0.clone(),activity_root:dir.0.clone()});let state=monitor.snapshot();
        assert_eq!(state["streams"]["cpu"]["state"],"stale");assert_eq!(state["streams"]["board"]["state"],"missing");assert_eq!(state["streams"]["events"]["state"],"archive");
    }
    #[test] fn unavailable_numeric_is_not_zero() {assert_eq!(numeric(&json!("N/A")),Value::Null);assert_eq!(numeric(&json!("0")),json!(0.0));}
    #[test] fn complete_samples_survive_rotation() {
        let dir=Fixture::new();let a=dir.0.join("board-auto-1.jsonl");fs::write(&a,format!("{}\n",json!({"time":Utc::now().to_rfc3339(),"sequence":1}))).unwrap();
        let mut reader=LogReader::new(dir.0.clone(),"board-auto-");reader.update();fs::rename(&a,dir.0.join("archived.txt")).unwrap();
        fs::write(dir.0.join("board-auto-2.jsonl"),format!("{}\n",json!({"time":Utc::now().to_rfc3339(),"sequence":2}))).unwrap();reader.update();assert_eq!(reader.rows.len(),2);assert_eq!(reader.rows.back().unwrap()["sequence"],2);
    }
}
