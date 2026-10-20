//! Read-only crash configuration and bounded dump metadata; never changes policy.
use crate::metrics::{query, Query};
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::{
    fs,
    path::{Path, PathBuf},
    time::{Duration, Instant},
};

query!(Os, "Win32_OperatingSystem", {LastBootUpTime:String, Version:String, BuildNumber:String, FreePhysicalMemory:u64, TotalVisibleMemorySize:u64});
query!(Pagefile, "Win32_PageFileUsage", {Name:String, AllocatedBaseSize:u32, CurrentUsage:u32, PeakUsage:u32});
query!(Volume, "Win32_LogicalDisk", {DeviceID:String, FreeSpace:u64, Size:u64});

fn policy(data: &Path, current: &Value) -> Value {
    let prior = match crate::storage::read_shared(&data.join("dump-policy-backup.json"), 262144) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            return json!({"status":"unmanaged","current":current})
        }
        value => value.map_err(|e| e.to_string()).and_then(|bytes| {
            let text = std::str::from_utf8(&bytes)
                .map_err(|e| e.to_string())?
                .trim_start_matches('\u{feff}');
            serde_json::from_str::<Value>(text).map_err(|e| e.to_string())
        }),
    };
    let prior = match prior {
        Ok(value) => value,
        Err(error) => return json!({"status":"unavailable","error":error,"current":current}),
    };
    if prior["active"] != true {
        return json!({"status":"inactive","current":current});
    }
    let Some(entries) = prior["entries"].as_array().filter(|a| !a.is_empty()) else {
        return json!({"status":"unavailable","error":"Active dump policy has no recorded settings","current":current});
    };
    let mut expected = Map::new();
    let mut differences = Vec::new();
    for entry in entries {
        let Some(name) = entry["name"].as_str() else {
            return json!({"status":"unavailable","error":"Invalid dump policy entry","current":current});
        };
        expected.insert(name.into(), entry["applied"].clone());
        let exists = current.get(name).is_some();
        if !exists || current[name] != entry["applied"] {
            differences.push(json!({"name":name,"expected":entry["applied"],"current":current[name],"exists":exists}));
        }
    }
    json!({"status":if differences.is_empty(){"matching"}else{"drifted"},"expected":expected,
        "current":current,"differences":differences,
        "note":"Compared to last applied values; external changes are not overwritten. Dump creation is not guaranteed."})
}
fn dump_files(roots: &[PathBuf]) -> (Vec<Value>, Vec<Value>) {
    let mut files = Vec::new();
    let mut errors = Vec::new();
    let mut visited = 0;
    let deadline = Instant::now() + Duration::from_secs(10);
    for root in roots {
        let mut stack = vec![(root.clone(), 0usize)];
        let mut count = 0;
        while let Some((path, depth)) = stack.pop() {
            visited += 1;
            if visited > 100000 || depth > 128 || Instant::now() >= deadline {
                errors.push(json!(
                    "Dump metadata scan limit reached; results incomplete"
                ));
                return (files, errors);
            }
            let metadata = match fs::symlink_metadata(&path) {
                Ok(value) => value,
                Err(e) if e.kind() == std::io::ErrorKind::NotFound && depth == 0 => continue,
                Err(e) => {
                    errors.push(json!(format!("{}: {e}", path.display())));
                    continue;
                }
            };
            #[cfg(windows)]
            {
                use std::os::windows::fs::MetadataExt;
                if metadata.file_attributes() & (2 | 4) != 0 {
                    continue;
                }
                if metadata.file_attributes() & 0x400 != 0 {
                    errors.push(json!(format!(
                        "Dump metadata reparse point not followed: {}",
                        path.display()
                    )));
                    continue;
                }
            }
            if metadata.file_type().is_symlink() {
                errors.push(json!(format!(
                    "Dump metadata link not followed: {}",
                    path.display()
                )));
                continue;
            }
            if metadata.is_dir() {
                match fs::read_dir(&path) {
                    Ok(entries) => {
                        for entry in entries {
                            match entry {
                                Ok(entry) => {
                                    stack.push((entry.path(), depth + 1));
                                    if stack.len() > 100000 {
                                        errors.push(json!("Dump directory enumeration limit"));
                                        return (files, errors);
                                    }
                                }
                                Err(e) => errors.push(json!(e.to_string())),
                            }
                        }
                    }
                    Err(e) => errors.push(json!(format!("{}: {e}", path.display()))),
                }
            } else if path
                .extension()
                .is_some_and(|e| e.to_string_lossy().eq_ignore_ascii_case("dmp"))
            {
                if count == 100 {
                    errors.push(json!(format!(
                        "Dump metadata file limit reached: {}",
                        root.display()
                    )));
                    break;
                }
                match metadata.modified() {
                    Ok(time) => {
                        let time: chrono::DateTime<chrono::Utc> = time.into();
                        files.push(json!({"FullName":path.to_string_lossy(),"Length":metadata.len(),"LastWriteTimeUtc":format!("/Date({})/",time.timestamp_millis())}));
                        count += 1;
                    }
                    Err(e) => errors.push(json!(e.to_string())),
                }
            }
        }
    }
    (files, errors)
}
#[cfg(windows)]
pub fn collect(data: &Path, reader: &mut crate::metrics::Reader) -> Value {
    let mut errors = Vec::new();
    let settings = match crate::collect::registry() {
        Ok(registry) => Value::Object(
            registry
                .as_object()
                .unwrap()
                .iter()
                .map(|(k, v)| (k.clone(), v["value"].clone()))
                .collect(),
        ),
        Err(error) => {
            errors.push(json!(error));
            Value::Null
        }
    };
    let os = match reader.read::<Os>(None, true, 262144) {
        Ok(mut rows) => {
            if rows.len() == 1 {
                rows.remove(0)
            } else if rows.is_empty() {
                Value::Null
            } else {
                json!(rows)
            }
        }
        Err(error) => {
            errors.push(json!(error));
            Value::Null
        }
    };
    let pagefiles = reader
        .read::<Pagefile>(None, false, 262144)
        .unwrap_or_else(|e| {
            errors.push(json!(e));
            Vec::new()
        });
    let volumes = reader
        .read::<Volume>(Some("DriveType=3"), false, 262144)
        .unwrap_or_else(|e| {
            errors.push(json!(e));
            Vec::new()
        });
    let windows = PathBuf::from(std::env::var_os("WINDIR").unwrap_or_default());
    let mut roots = vec![
        windows.join("MEMORY.DMP"),
        windows.join("Minidump"),
        windows.join("LiveKernelReports"),
    ];
    for field in ["DumpFile", "MinidumpDir"] {
        if let Some(text) = settings[field].as_str().filter(|s| !s.is_empty()) {
            if !roots
                .iter()
                .any(|p| p.to_string_lossy().eq_ignore_ascii_case(text))
            {
                roots.push(text.into());
            }
        }
    }
    let (files, scan_errors) = dump_files(&roots);
    errors.extend(scan_errors);
    let policy = if settings.is_null() {
        json!({"status":"unavailable"})
    } else {
        policy(data, &settings)
    };
    let crash = json!({"time":crate::now(),"settings":settings,"policy":policy,"os":os,"pagefiles":pagefiles,
        "volumes":volumes,"dumpFiles":files,"errors":errors,
        "note":"Read-only configuration and dump metadata; dump creation is not guaranteed by these settings."});
    json!({"status":if errors.is_empty(){"ok"}else{"partial"},"data":crash,"issues":errors})
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn drift_is_reported_without_modifying_policy_or_dump() {
        let root = std::env::temp_dir().join(format!(
            "crash-native-test-{}",
            chrono::Utc::now().timestamp_nanos_opt().unwrap()
        ));
        fs::create_dir_all(&root).unwrap();
        let settings = json!({"CrashDumpEnabled":3,"AlwaysKeepMemoryDump":1});
        assert_eq!(policy(&root, &settings)["status"], "unmanaged");
        let path = root.join("dump-policy-backup.json");
        fs::write(
            &path,
            br#"{"active":true,"entries":[{"name":"CrashDumpEnabled","applied":7}]}"#,
        )
        .unwrap();
        let original = fs::read(&path).unwrap();
        assert_eq!(policy(&root, &settings)["status"], "drifted");
        assert_eq!(fs::read(&path).unwrap(), original);
        let dump = root.join("synthetic.dmp");
        fs::write(&dump, b"not a real dump").unwrap();
        let (files, errors) = dump_files(&[root.clone()]);
        assert!(errors.is_empty());
        assert_eq!(files.len(), 1);
        assert_eq!(files[0]["Length"], 15);
        assert_eq!(fs::read(dump).unwrap(), b"not a real dump");
        fs::write(&path, b"{").unwrap();
        assert_eq!(policy(&root, &settings)["status"], "unavailable");
    }
}
