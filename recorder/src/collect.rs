use crate::storage;
use serde_json::{json, Map, Value};
use std::path::Path;

const FILES: &[&str] = &[
    "collection-settings.json",
    "recorder-settings.json",
    "sensor-driver-isolation.json",
    "dump-policy-backup.json",
    "event-channel-coverage.json",
    "recorder-run.json",
];
const DUMP_KEYS: &[&str] = &[
    "CrashDumpEnabled",
    "DumpFile",
    "MinidumpDir",
    "AutoReboot",
    "LogEvent",
    "AlwaysKeepMemoryDump",
    "DedicatedDumpFile",
    "DumpFileSize",
];

fn read_config(path: &Path) -> Value {
    // Preserve raw bytes/hash independently of the parsed JSON representation.
    let bytes = match storage::read_shared(path, 262144) {
        Ok(bytes) => bytes,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return json!({"status":"missing"}),
        Err(e) => {
            if let Ok(m) = path.metadata() {
                if m.len() > 262144 {
                    return json!({"status":"too-large","bytes":m.len(),"limitBytes":262144});
                }
            }
            return json!({"status":"unavailable","error":e.to_string()});
        }
    };
    let hash = storage::sha(&bytes);
    let text = match std::str::from_utf8(&bytes) {
        Ok(text) => text.trim_start_matches('\u{feff}'),
        Err(e) => return json!({"status":"unavailable","error":e.to_string()}),
    };
    if serde_json::from_str::<Value>(text).is_err() {
        return json!({"status":"invalid","sha256":hash,"bytes":bytes.len(),"error":"Invalid JSON; source left unchanged"});
    }
    json!({"status":"observed","sha256":hash,"bytes":bytes.len(),"json":text})
}

pub fn journal(root: &Path, registry: Result<Value, String>) -> Value {
    let mut files = Map::new();
    let mut issues = Vec::new();
    for name in FILES {
        let value = read_config(&root.join(name));
        if matches!(
            value["status"].as_str(),
            Some("invalid" | "unavailable" | "too-large")
        ) {
            issues.push(json!({"source":name,"status":value["status"]}));
        }
        files.insert((*name).into(), value);
    }
    let dump = match registry {
        Ok(values) => json!({"status":"observed","values":values}),
        Err(error) => {
            issues.push(json!({"source":"CrashControl","status":"unavailable"}));
            json!({"status":"unavailable","error":error})
        }
    };
    json!({"status":if issues.is_empty(){"ok"}else{"partial"},"data":{"files":files,"crashControl":dump,"timeScope":"Observed at sampling time; changes between polls may be missed. recorder-run.json describes coordinator-applied settings; saved settings may await restart."},"issues":issues})
}

#[cfg(windows)]
pub fn registry() -> Result<Value, String> {
    use windows_sys::Win32::{Foundation::ERROR_FILE_NOT_FOUND, System::Registry::*};
    let wide = |s: &str| s.encode_utf16().chain(Some(0)).collect::<Vec<_>>();
    let mut key = std::ptr::null_mut();
    let result = unsafe {
        RegOpenKeyExW(
            HKEY_LOCAL_MACHINE,
            wide(r"SYSTEM\CurrentControlSet\Control\CrashControl").as_ptr(),
            0,
            KEY_READ | KEY_WOW64_64KEY,
            &mut key,
        )
    };
    if result != 0 {
        return Err(format!("CrashControl open: {result}"));
    }
    struct Key(HKEY);
    impl Drop for Key {
        fn drop(&mut self) {
            unsafe {
                RegCloseKey(self.0);
            }
        }
    }
    let key = Key(key);
    let mut values = Map::new();
    for name in DUMP_KEYS {
        let mut kind = 0;
        let mut length = 0;
        let name_w = wide(name);
        let result = unsafe {
            RegQueryValueExW(
                key.0,
                name_w.as_ptr(),
                std::ptr::null(),
                &mut kind,
                std::ptr::null_mut(),
                &mut length,
            )
        };
        if result == ERROR_FILE_NOT_FOUND {
            values.insert((*name).into(), json!({"present":false,"value":null}));
            continue;
        }
        if result != 0 || length > 262144 {
            return Err(format!("Registry size/query failed for {name}: {result}"));
        }
        let mut bytes = vec![0u8; length as usize];
        let result = unsafe {
            RegQueryValueExW(
                key.0,
                name_w.as_ptr(),
                std::ptr::null(),
                &mut kind,
                bytes.as_mut_ptr(),
                &mut length,
            )
        };
        if result != 0 {
            return Err(format!("Registry read failed for {name}: {result}"));
        }
        bytes.truncate(length as usize);
        let value = match kind {
            REG_DWORD if bytes.len() == 4 => json!(u32::from_le_bytes(bytes.try_into().unwrap())),
            REG_QWORD if bytes.len() == 8 => json!(u64::from_le_bytes(bytes.try_into().unwrap())),
            REG_SZ | REG_EXPAND_SZ if bytes.len() % 2 == 0 => {
                let words: Vec<u16> = bytes
                    .chunks_exact(2)
                    .map(|p| u16::from_le_bytes([p[0], p[1]]))
                    .collect();
                let text = String::from_utf16(&words).map_err(|e| e.to_string())?;
                let text = text.trim_end_matches('\0');
                // Match Get-ItemProperty's expansion for REG_EXPAND_SZ.
                if kind == REG_EXPAND_SZ {
                    json!(expand_environment(text))
                } else {
                    json!(text)
                }
            }
            _ => return Err(format!("Unexpected registry value type for {name}: {kind}")),
        };
        values.insert((*name).into(), json!({"present":true,"value":value}));
    }
    Ok(Value::Object(values))
}

#[cfg(windows)]
fn expand_environment(text: &str) -> String {
    let mut output = String::new();
    let mut rest = text;
    while let Some(start) = rest.find('%') {
        output.push_str(&rest[..start]);
        rest = &rest[start + 1..];
        if let Some(end) = rest.find('%') {
            let name = &rest[..end];
            output.push_str(&std::env::var(name).unwrap_or_else(|_| format!("%{name}%")));
            rest = &rest[end + 1..];
        } else {
            output.push('%');
            break;
        }
    }
    output.push_str(rest);
    output
}

// Keep the original WMI provider, field types and Windows PowerShell date format.
// Native per-process APIs would change access-denied/idle-process semantics.
#[cfg(windows)]
#[derive(serde::Deserialize, serde::Serialize)]
#[serde(rename_all = "PascalCase")]
struct Process {
    name: Option<String>,
    process_id: u32,
    parent_process_id: u32,
    creation_date: Option<String>,
    kernel_mode_time: Option<u64>,
    user_mode_time: Option<u64>,
    working_set_size: Option<u64>,
    private_page_count: Option<u64>,
    page_faults: Option<u32>,
    handle_count: Option<u32>,
    thread_count: Option<u32>,
    read_transfer_count: Option<u64>,
    write_transfer_count: Option<u64>,
}

pub(crate) fn date_millis(value: &str) -> Result<i64, String> {
    if value.len() != 25 || !value.is_ascii() {
        return Err("Unexpected WMI datetime".into());
    }
    let local = chrono::NaiveDateTime::parse_from_str(&value[..21], "%Y%m%d%H%M%S%.f")
        .map_err(|e| e.to_string())?;
    let minutes: i32 = value[22..].parse().map_err(|_| "Invalid WMI timezone")?;
    let sign = match &value[21..22] {
        "+" => 1,
        "-" => -1,
        _ => return Err("Invalid WMI timezone sign".into()),
    };
    let offset =
        chrono::FixedOffset::east_opt(sign * minutes * 60).ok_or("Invalid WMI timezone offset")?;
    use chrono::TimeZone;
    Ok(offset
        .from_local_datetime(&local)
        .single()
        .ok_or("Invalid WMI timestamp")?
        .timestamp_millis())
}

#[cfg(windows)]
pub struct Processes(Option<wmi::WMIConnection>);
#[cfg(windows)]
impl Processes {
    pub fn new() -> Self {
        Self(None)
    }
    pub fn collect(&mut self) -> Value {
        let result = (|| -> Result<Vec<Value>, String> {
            if self.0.is_none() {
                self.0 = Some(wmi::WMIConnection::new().map_err(|e| e.to_string())?);
            }
            let connection = self.0.as_ref().unwrap();
            let rows:Vec<Process>=connection.raw_query("SELECT Name,ProcessId,ParentProcessId,CreationDate,KernelModeTime,UserModeTime,WorkingSetSize,PrivatePageCount,PageFaults,HandleCount,ThreadCount,ReadTransferCount,WriteTransferCount FROM Win32_Process").map_err(|e|e.to_string())?;
            if rows.len() > 32768 {
                return Err("Process count exceeds bound".into());
            }
            rows.into_iter()
                .map(|mut row| {
                    if let Some(date) = row.creation_date.take() {
                        row.creation_date = Some(format!("/Date({})/", date_millis(&date)?));
                    }
                    serde_json::to_value(row).map_err(|e| e.to_string())
                })
                .collect()
        })();
        match result {
            Ok(rows) => json!({"status":"ok","data":{"processes":rows},"issues":[]}),
            Err(error) => {
                self.0 = None;
                json!({"status":"partial","data":{},"issues":[{"source":"processes","status":"unavailable","error":error}]})
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn timestamp_preserves_offset_and_milliseconds() {
        assert_eq!(
            date_millis("20261020210000.123456+540").unwrap(),
            chrono::DateTime::parse_from_rfc3339("2026-10-20T12:00:00.123Z")
                .unwrap()
                .timestamp_millis()
        );
        assert!(date_millis("2026**********.******+***").is_err());
    }
    #[test]
    fn journal_preserves_exact_bytes_and_detects_missing_invalid_and_changes() {
        let root = std::env::temp_dir().join(format!(
            "tracekeep-journal-{}",
            chrono::Utc::now().timestamp_nanos_opt().unwrap()
        ));
        std::fs::create_dir_all(&root).unwrap();
        let path = root.join(FILES[0]);
        let bytes = b"\xef\xbb\xbf{ \"enabled\": true }\r\n";
        std::fs::write(&path, bytes).unwrap();
        let first = journal(
            &root,
            Ok(json!({"CrashDumpEnabled":{"present":true,"value":7}})),
        );
        assert_eq!(
            first["data"]["files"][FILES[0]]["sha256"],
            storage::sha(bytes)
        );
        assert_eq!(
            first["data"]["files"][FILES[0]]["json"],
            "{ \"enabled\": true }\r\n"
        );
        assert_eq!(first["data"]["files"][FILES[1]]["status"], "missing");
        assert_eq!(std::fs::read(&path).unwrap(), bytes);
        std::fs::write(&path, b"{partial").unwrap();
        let broken = journal(&root, Err("synthetic denied".into()));
        assert_eq!(broken["status"], "partial");
        assert_eq!(broken["data"]["files"][FILES[0]]["status"], "invalid");
        std::fs::write(&path, vec![b' '; 262145]).unwrap();
        assert_eq!(
            journal(&root, Ok(json!({})))["data"]["files"][FILES[0]]["status"],
            "too-large"
        );
    }
}
