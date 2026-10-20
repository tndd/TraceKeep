//! The aggregate sampler retains its own process, legacy mutexes and paired
//! progress/commit records. No hardware or configuration writes.
use serde_json::{json, Value};
use std::{
    io,
    path::Path,
    time::{Duration, Instant},
};

const FIELDS: &str = "temperature.gpu,utilization.gpu,power.draw,power.limit,fan.speed,clocks.gr,clocks.mem,pstate,clocks_event_reasons.hw_thermal_slowdown,clocks_event_reasons.hw_power_brake_slowdown,clocks_event_reasons.sw_thermal_slowdown,clocks_event_reasons.sw_power_cap,clocks_event_reasons_counters.hw_power_brake_slowdown,clocks_event_reasons_counters.hw_thermal_slowdown,clocks_event_reasons_counters.sw_thermal_slowdown,clocks_event_reasons_counters.sw_power_cap";
const HEADERS: [&str; 16] = [
    "temperatureC",
    "loadPercent",
    "powerW",
    "powerLimitW",
    "fanPercent",
    "graphicsMHz",
    "memoryMHz",
    "pstate",
    "hwThermalSlowdown",
    "hwPowerBrakeSlowdown",
    "swThermalSlowdown",
    "swPowerCap",
    "hwPowerBrakeMicroseconds",
    "hwThermalMicroseconds",
    "swThermalMicroseconds",
    "swPowerCapMicroseconds",
];

fn gpu_rows(text: &str) -> Result<Value, String> {
    let mut rows = Vec::new();
    for line in text.lines().filter(|l| !l.trim().is_empty()) {
        let fields = line.split(',').map(str::trim).collect::<Vec<_>>();
        if fields.len() != HEADERS.len() {
            return Err("GPU reader returned an incomplete or unexpected row".into());
        }
        let mut row = serde_json::Map::new();
        let mut unsupported = Vec::new();
        for (key, value) in HEADERS.iter().zip(fields) {
            // NVIDIA's fields contain no embedded CSV delimiters. Permit quoted
            // scalar cells but reject malformed quoting instead of shifting data.
            let value = if value.starts_with('"') && value.ends_with('"') && value.len() >= 2 {
                &value[1..value.len() - 1]
            } else {
                value
            };
            if value.contains('"') {
                return Err("Malformed GPU CSV".into());
            }
            let missing = ["N/A", "[N/A]", "[Not Supported]"]
                .iter()
                .any(|v| v.eq_ignore_ascii_case(value));
            if missing {
                unsupported.push(*key);
            }
            row.insert(
                (*key).into(),
                if missing { Value::Null } else { json!(value) },
            );
        }
        row.insert("unsupportedFields".into(), json!(unsupported));
        rows.push(Value::Object(row));
    }
    Ok(json!(rows))
}

#[cfg(windows)]
struct Mutex(windows_sys::Win32::Foundation::HANDLE);
#[cfg(windows)]
impl Mutex {
    fn acquire(name: &str) -> io::Result<Option<Self>> {
        use windows_sys::Win32::{
            Foundation::{CloseHandle, WAIT_ABANDONED, WAIT_OBJECT_0, WAIT_TIMEOUT},
            System::Threading::{CreateMutexW, WaitForSingleObject},
        };
        let wide = name.encode_utf16().chain(Some(0)).collect::<Vec<_>>();
        unsafe {
            let handle = CreateMutexW(std::ptr::null(), 0, wide.as_ptr());
            if handle.is_null() {
                return Err(io::Error::last_os_error());
            }
            match WaitForSingleObject(handle, 0) {
                WAIT_OBJECT_0 | WAIT_ABANDONED => Ok(Some(Self(handle))),
                WAIT_TIMEOUT => {
                    CloseHandle(handle);
                    Ok(None)
                }
                _ => {
                    let e = io::Error::last_os_error();
                    CloseHandle(handle);
                    Err(e)
                }
            }
        }
    }
}
#[cfg(windows)]
impl Drop for Mutex {
    fn drop(&mut self) {
        unsafe {
            windows_sys::Win32::System::Threading::ReleaseMutex(self.0);
            windows_sys::Win32::Foundation::CloseHandle(self.0);
        }
    }
}

struct Log {
    root: std::path::PathBuf,
    session: String,
    previous: Value,
    previous_day: String,
}
impl Log {
    fn append(&self, kind: &str, row: &Value) -> io::Result<(String, u64)> {
        let file = format!("{kind}-{}.jsonl", crate::day());
        let offset = crate::storage::append(&self.root.join(&file), row)?;
        Ok((file, offset))
    }
    fn progress(&self, sequence: u64, stage: &str) -> io::Result<()> {
        let (ticks, frequency) = crate::ticks();
        self.append("progress-activity",&json!({"time":crate::now(),"session":self.session,"sequence":sequence,"stage":stage,
            "monotonicTicks":ticks,"monotonicFrequency":frequency,
            "previousCommit":if self.previous_day==crate::day(){self.previous.clone()}else{Value::Null}}))?;
        Ok(())
    }
    fn commit(&mut self, row: &Value) -> io::Result<()> {
        let (file, offset) = self.append("activity", row)?;
        self.previous_day = file
            .trim_start_matches("activity-")
            .trim_end_matches(".jsonl")
            .to_owned();
        self.previous = json!({"file":file,"offset":offset,"time":crate::now()});
        Ok(())
    }
}

#[cfg(windows)]
pub fn run(options: &crate::Options, settings: &Value) -> Result<(), String> {
    use crate::metrics::{query, Query, Reader};
    use serde::{Deserialize, Serialize};
    query!(Os,"Win32_OperatingSystem",{LastBootUpTime:String,Version:String});
    query!(Cpu,"Win32_PerfFormattedData_PerfOS_Processor",{PercentProcessorTime:u64});
    query!(Memory,"Win32_PerfFormattedData_PerfOS_Memory",{AvailableMBytes:u64,PercentCommittedBytesInUse:u64});
    query!(Disk,"Win32_PerfFormattedData_PerfDisk_PhysicalDisk",{DiskReadBytesPersec:u64,DiskWriteBytesPersec:u64,CurrentDiskQueueLength:u64});
    let Some(interval) = crate::interval(settings, "activity")? else {
        return Ok(());
    };
    let interval = options
        .interval_ms
        .map(Duration::from_millis)
        .unwrap_or(interval);
    let Some(_current) =
        Mutex::acquire("Global\\PCDiagnostics-Activity-v2").map_err(|e| e.to_string())?
    else {
        return Ok(());
    };
    let user = std::env::var("USERNAME").map_err(|_| "Missing USERNAME for legacy ownership")?;
    let Some(_legacy) = Mutex::acquire(&format!("Local\\CodexPCDiagnostics-{user}-20261010"))
        .map_err(|e| e.to_string())?
    else {
        return Ok(());
    };
    let _owner = crate::storage::exclusive(&options.logs.join("activity.owner.lock"))
        .map_err(|e| e.to_string())?;
    let stop = options.logs.join("STOP");
    if stop.exists() {
        return Ok(());
    }
    let mut log = Log {
        root: options.logs.clone(),
        session: crate::Recorder::new(
            options.logs.clone(),
            "activity".into(),
            options.run_id.clone(),
        )
        .session,
        previous: Value::Null,
        previous_day: String::new(),
    };
    let io_error = |e: io::Error| e.to_string();
    log.progress(0, "initializing").map_err(io_error)?;
    let gpu = crate::diagnostics::nvidia_executable().ok();
    let mut reader = Reader::default();
    let os = reader
        .read::<Os>(None, false, 262144)?
        .into_iter()
        .next()
        .ok_or("Missing OS data")?;
    let boot =
        crate::collect::date_millis(os["LastBootUpTime"].as_str().ok_or("Missing boot time")?)?;
    log.append("sessions",&json!({"time":crate::now(),"session":log.session,"pid":std::process::id(),
        "intervalSeconds":interval.as_secs_f64(),"lastBoot":chrono::DateTime::from_timestamp_millis(boot).map(|t|t.with_timezone(&chrono::Local).to_rfc3339()),
        "osVersion":os["Version"],"gpuReader":gpu,"logRoot":options.logs,"backend":"rust",
        "note":"No AC waveform or internal PSU protection measurements are available."})).map_err(io_error)?;
    let mut memory = Value::Null;
    let mut sequence = 0;
    let mut warned = false;
    let mut size_check = Instant::now();
    while !stop.exists() {
        let timer = Instant::now();
        let started = crate::now();
        log.progress(sequence, "collecting").map_err(io_error)?;
        let mut row = json!({"time":started,"session":log.session,"sequence":sequence,"cpuLoadPercent":null,
            "availableMemoryMB":null,"committedMemoryPercent":null,"diskReadBytesPerSecond":null,
            "diskWriteBytesPerSecond":null,"diskQueueLength":null,"gpu":null,"errors":[],"backend":"rust","runId":options.run_id});
        let system = (|| -> Result<(), String> {
            let cpu = reader.read::<Cpu>(Some("Name='_Total'"), false, 65536)?;
            row["cpuLoadPercent"] = cpu
                .first()
                .map(|r| r["PercentProcessorTime"].clone())
                .unwrap_or(Value::Null);
            if sequence % 5 == 0 {
                memory = reader
                    .read::<Memory>(None, false, 65536)?
                    .into_iter()
                    .next()
                    .unwrap_or(Value::Null);
            }
            row["availableMemoryMB"] = memory["AvailableMBytes"].clone();
            row["committedMemoryPercent"] = memory["PercentCommittedBytesInUse"].clone();
            let disk = reader
                .read::<Disk>(Some("Name='_Total'"), false, 65536)?
                .into_iter()
                .next()
                .unwrap_or(Value::Null);
            row["diskReadBytesPerSecond"] = disk["DiskReadBytesPersec"].clone();
            row["diskWriteBytesPerSecond"] = disk["DiskWriteBytesPersec"].clone();
            row["diskQueueLength"] = disk["CurrentDiskQueueLength"].clone();
            Ok(())
        })();
        if let Err(error) = system {
            row["errors"].as_array_mut().unwrap().push(json!(error));
        }
        if let Some(executable) = &gpu {
            match crate::command::run(
                executable,
                &format!("--query-gpu={FIELDS} --format=csv,noheader,nounits"),
                Duration::from_secs(5),
                false,
            )
            .and_then(|s| gpu_rows(&s))
            {
                Ok(value) => {
                    row["gpu"] = value;
                    row["gpuSampleTime"] = json!(crate::now());
                }
                Err(error) => row["errors"].as_array_mut().unwrap().push(json!(error)),
            }
        }
        let (ticks, frequency) = crate::ticks();
        row["sampleDurationMs"] = json!(timer.elapsed().as_millis() as u64);
        row["monotonicTicks"] = json!(ticks);
        row["monotonicFrequency"] = json!(frequency);
        row["intervalMilliseconds"] = json!(interval.as_millis() as u64);
        log.commit(&row).map_err(io_error)?;
        if !warned && size_check.elapsed() >= Duration::from_secs(60) {
            let total = raw_size(&options.logs).map_err(io_error)?;
            if total >= 2 * 1024 * 1024 * 1024 {
                log.append("sessions",&json!({"time":crate::now(),"session":log.session,"status":"Logs exceed 2 GiB; logging continues, no files deleted","bytes":total})).map_err(io_error)?;
                warned = true;
            }
            size_check = Instant::now();
        }
        sequence += 1;
        if options.samples > 0 && sequence >= options.samples {
            break;
        }
        // Same start-to-start cadence as PowerShell; a slow provider never
        // launches a catch-up sample or blocks a peer worker.
        while timer.elapsed() < interval && !stop.exists() {
            std::thread::sleep(
                interval
                    .saturating_sub(timer.elapsed())
                    .min(Duration::from_millis(100)),
            );
        }
    }
    log.append("sessions",&json!({"time":crate::now(),"session":log.session,"status":"Stopped normally","samples":sequence})).map_err(io_error)?;
    Ok(())
}
fn raw_size(root: &Path) -> io::Result<u64> {
    std::fs::read_dir(root)?.try_fold(0u64, |sum, entry| {
        let entry = entry?;
        if entry.path().extension().is_some_and(|e| e == "jsonl") {
            Ok(sum.saturating_add(entry.metadata()?.len()))
        } else {
            Ok(sum)
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn gpu_csv_keeps_string_counters_nulls_and_multiple_devices() {
        let line="50, 42, 100.5, 200, [N/A], 2400, 8000, P0, Not Active, Not Active, Not Active, Active, 18446744073709551615, 0, [Not Supported], 123";
        let rows = gpu_rows(&format!("{line}\r\n{line}\n")).unwrap();
        assert_eq!(rows.as_array().unwrap().len(), 2);
        assert_eq!(rows[0]["hwPowerBrakeMicroseconds"], "18446744073709551615");
        assert!(rows[0]["fanPercent"].is_null());
        assert_eq!(
            rows[0]["unsupportedFields"],
            json!(["fanPercent", "swThermalMicroseconds"])
        );
        assert!(gpu_rows("1,2").is_err());
        assert!(gpu_rows(&line.replace("50", "\"50")).is_err());
    }
    #[test]
    fn progress_refers_only_to_a_durable_same_day_commit() {
        let root = std::env::temp_dir().join(format!(
            "tracekeep-activity-test-{}",
            chrono::Utc::now().timestamp_nanos_opt().unwrap()
        ));
        std::fs::create_dir_all(&root).unwrap();
        let mut log = Log {
            root: root.clone(),
            session: "synthetic".into(),
            previous: Value::Null,
            previous_day: String::new(),
        };
        log.progress(0, "collecting").unwrap();
        log.commit(&json!({"sequence":0})).unwrap();
        let saved = log.previous.clone();
        log.progress(1, "collecting").unwrap();
        let rows =
            std::fs::read_to_string(root.join(format!("progress-activity-{}.jsonl", crate::day())))
                .unwrap()
                .lines()
                .map(|s| serde_json::from_str::<Value>(s).unwrap())
                .collect::<Vec<_>>();
        assert!(rows[0]["previousCommit"].is_null());
        assert_eq!(rows[1]["previousCommit"], saved);
        assert_eq!(
            saved["offset"].as_u64().unwrap(),
            std::fs::metadata(root.join(saved["file"].as_str().unwrap()))
                .unwrap()
                .len()
        );
        let owner = crate::storage::exclusive(&crate::storage::suffix(
            &root.join(saved["file"].as_str().unwrap()),
            ".lock",
        ))
        .unwrap();
        assert!(log.commit(&json!({"sequence":1})).is_err());
        assert_eq!(log.previous, saved);
        drop(owner);
        log.previous_day = "19000101".into();
        log.progress(2, "collecting").unwrap();
        let text =
            std::fs::read_to_string(root.join(format!("progress-activity-{}.jsonl", crate::day())))
                .unwrap();
        assert!(
            serde_json::from_str::<Value>(text.lines().last().unwrap()).unwrap()["previousCommit"]
                .is_null()
        );
        std::fs::remove_dir_all(root).unwrap();
    }
}
