//! Typed, read-only WMI queries. Each module runs in its own worker process.
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use serde_json::{json, Map, Value};

pub(crate) trait Query: DeserializeOwned + Serialize {
    const ALLOW_MISSING: bool = false;
    const CLASS: &'static str;
    const FIELDS: &'static [&'static str];
}
macro_rules! query {
    ($name:ident, $class:literal, {$($field:ident:$kind:ty),+ $(,)?}) => {
        #[allow(non_snake_case)]
        #[derive(Deserialize, Serialize)]
        pub(crate) struct $name { $( $field: Option<$kind> ),+ }
        impl Query for $name {
            const CLASS: &'static str = $class;
            const FIELDS: &'static [&'static str] = &[$(stringify!($field)),+];
        }
    };
}
pub(crate) use query;
query!(Cpu, "Win32_PerfFormattedData_PerfOS_Processor", {
    Name:String, PercentProcessorTime:u64, PercentPrivilegedTime:u64,
    PercentInterruptTime:u64, PercentDPCTime:u64, InterruptsPersec:u64, DPCsQueuedPersec:u64
});
query!(Memory, "Win32_PerfFormattedData_PerfOS_Memory", {
    AvailableMBytes:u64, CommittedBytes:u64, CommitLimit:u64, PercentCommittedBytesInUse:u64,
    PagesInputPersec:u64, PagesOutputPersec:u64, PageReadsPersec:u64, PageWritesPersec:u64,
    PoolNonpagedBytes:u64, PoolPagedBytes:u64
});
query!(Disks, "Win32_PerfFormattedData_PerfDisk_PhysicalDisk", {
    Name:String, CurrentDiskQueueLength:u64, AvgDisksecPerRead:u64, AvgDisksecPerWrite:u64,
    AvgDisksecPerTransfer:u64, DiskReadsPersec:u64, DiskWritesPersec:u64, DiskReadBytesPersec:u64,
    DiskWriteBytesPersec:u64, PercentIdleTime:u64, SplitIOPerSec:u64
});
query!(DiskRaw, "Win32_PerfRawData_PerfDisk_PhysicalDisk", {
    Name:String, AvgDisksecPerRead:u64, AvgDisksecPerRead_Base:u64, AvgDisksecPerWrite:u64,
    AvgDisksecPerWrite_Base:u64, AvgDisksecPerTransfer:u64, AvgDisksecPerTransfer_Base:u64,
    Frequency_PerfTime:u64, Timestamp_PerfTime:u64
});
query!(System, "Win32_PerfFormattedData_PerfOS_System", {
    ProcessorQueueLength:u64, ContextSwitchesPersec:u64, Threads:u64, Processes:u64, SystemUpTime:u64
});
query!(Reliability, "Win32_ReliabilityRecords", {
    RecordNumber:u64, SourceName:String, EventIdentifier:u64, TimeGenerated:String,
    ProductName:String, Message:String, Logfile:String
});

fn query_text<T: Query>(filter: Option<&str>) -> String {
    let mut text = format!(
        "SELECT {} FROM {}",
        if T::ALLOW_MISSING {
            "*".into()
        } else {
            T::FIELDS.join(",")
        },
        T::CLASS
    );
    if let Some(filter) = filter {
        text.push_str(" WHERE ");
        text.push_str(filter);
    }
    text
}

fn reliability_filter(at: chrono::DateTime<chrono::Local>) -> Result<String, String> {
    // Match AddDays(-7): seven local calendar days, including DST transitions.
    let since = at
        .checked_sub_days(chrono::Days::new(7))
        .ok_or("Ambiguous reliability cutoff")?;
    Ok(format!(
        "TimeGenerated >= '{}{:+04}'",
        since.format("%Y%m%d%H%M%S%.6f"),
        since.offset().local_minus_utc() / 60
    ))
}

fn cim_date_millis(date: &str) -> Result<i64, String> {
    // CIM treats unspecified microseconds and UTC offset as zero. DriverDate
    // commonly uses YYYYMMDD000000.******+***; ManagementDateTimeConverter's
    // local-time default differs from the Get-CimInstance contract here.
    let mut date = date.to_owned();
    if date.len() == 25 && date.is_ascii() {
        if &date[15..21] == "******" {
            date.replace_range(15..21, "000000");
        }
        if &date[22..25] == "***" {
            date.replace_range(21..25, "+000");
        }
    }
    crate::collect::date_millis(&date)
}

fn legacy_time(row: &mut Value) -> Result<(), String> {
    for field in [
        "TimeGenerated",
        "ReleaseDate",
        "DriverDate",
        "LastBootUpTime",
        "InstallDate",
    ] {
        if let Some(date) = row[field].as_str() {
            row[field] = json!(format!("/Date({})/", cim_date_millis(date)?));
        }
    }
    Ok(())
}

// Stop consuming the provider iterator at the bound. Do not retain a partial
// result as if it were complete; the caller emits an explicit source issue.
pub(crate) fn bounded_rows(
    rows: impl IntoIterator<Item = Result<Value, String>>,
    max_rows: usize,
    max_bytes: usize,
) -> Result<Vec<Value>, String> {
    let mut result = Vec::new();
    let mut bytes = 2usize;
    for row in rows {
        let row = row?;
        bytes =
            bytes.saturating_add(serde_json::to_vec(&row).map_err(|e| e.to_string())?.len() + 1);
        if result.len() == max_rows || bytes > max_bytes {
            return Err("WMI result exceeds row/byte limit; source omitted".into());
        }
        result.push(row);
    }
    Ok(result)
}

#[derive(Default)]
pub(crate) struct Evidence {
    pub(crate) data: Map<String, Value>,
    pub(crate) issues: Vec<Value>,
}
impl Evidence {
    pub(crate) fn finish_bounded(mut self) -> Value {
        // Leave room for JSON escaping, issues and the recorder envelope below
        // older history readers' 4 MiB line bound.
        let mut remaining = 3 * 1024 * 1024;
        self.data.retain(|source, value| {
            let bytes = value.to_string().len() + source.len() + 8;
            if bytes > remaining {
                self.issues
                    .push(json!({"source":source,"status":"unavailable",
                    "error":"Combined diagnostic result exceeds byte limit; source omitted"}));
                false
            } else {
                remaining -= bytes;
                true
            }
        });
        self.finish()
    }
    pub(crate) fn add(&mut self, key: &str, source: &str, result: Result<Vec<Value>, String>) {
        match result {
            Ok(rows) => {
                self.data.insert(key.into(), json!(rows));
            }
            Err(error) => self
                .issues
                .push(json!({"source":source,"status":"unavailable","error":error})),
        }
    }
    pub(crate) fn finish(self) -> Value {
        json!({"status":if self.issues.is_empty(){"ok"}else{"partial"},"data":self.data,"issues":self.issues})
    }
}

#[cfg(windows)]
pub struct Reader {
    connection: Option<wmi::WMIConnection>,
    namespace: &'static str,
}
#[cfg(windows)]
impl Default for Reader {
    fn default() -> Self {
        Self::namespace("ROOT/CIMV2")
    }
}
#[cfg(windows)]
impl Reader {
    pub fn namespace(namespace: &'static str) -> Self {
        Self {
            connection: None,
            namespace,
        }
    }
    pub(crate) fn read<T: Query>(
        &mut self,
        filter: Option<&str>,
        dates: bool,
        max_bytes: usize,
    ) -> Result<Vec<Value>, String> {
        let result = (|| {
            if self.connection.is_none() {
                self.connection = Some(
                    wmi::WMIConnection::with_namespace_path(self.namespace)
                        .map_err(|e| e.to_string())?,
                );
            }
            let rows = self
                .connection
                .as_ref()
                .unwrap()
                .exec_query(query_text::<T>(filter))
                .map_err(|e| e.to_string())?;
            bounded_rows(
                rows.map(|row| {
                    let row = row.map_err(|e| e.to_string())?;
                    let value: T = if T::ALLOW_MISSING {
                        let names = row.list_properties().map_err(|e| e.to_string())?;
                        let mut fields = Map::new();
                        for field in T::FIELDS {
                            let value = if names.iter().any(|name| name.eq_ignore_ascii_case(field))
                            {
                                serde_json::to_value(
                                    row.get_property(field).map_err(|e| e.to_string())?,
                                )
                                .map_err(|e| e.to_string())?
                            } else {
                                Value::Null
                            };
                            fields.insert((*field).into(), value);
                        }
                        serde_json::from_value(Value::Object(fields)).map_err(|e| e.to_string())?
                    } else {
                        row.into_desr().map_err(|e| e.to_string())?
                    };
                    let mut value = serde_json::to_value(value).map_err(|e| e.to_string())?;
                    if dates {
                        legacy_time(&mut value)?;
                    }
                    Ok(value)
                }),
                32768,
                max_bytes,
            )
        })();
        if result.is_err() {
            self.connection = None;
        }
        result
    }
    pub fn performance(&mut self) -> Value {
        let mut result = Evidence::default();
        // Keep both formatted counters and raw latency numerator/base/frequency.
        // Do not recompute units or replace missing/reset counters with zero.
        result.add("cpu", "cpu", self.read::<Cpu>(None, false, 1024 * 1024));
        result.add(
            "memory",
            "memory",
            self.read::<Memory>(None, false, 1024 * 1024),
        );
        result.add(
            "disks",
            "disks",
            self.read::<Disks>(None, false, 1024 * 1024),
        );
        result.add(
            "diskLatencyRaw",
            "diskLatencyRaw",
            self.read::<DiskRaw>(None, false, 1024 * 1024),
        );
        result.add(
            "system",
            "system",
            self.read::<System>(None, false, 1024 * 1024),
        );
        result.finish()
    }
    pub fn reliability(&mut self) -> Value {
        let mut result = Evidence::default();
        let rows = reliability_filter(chrono::Local::now())
            .and_then(|filter| self.read::<Reliability>(Some(&filter), true, 6 * 1024 * 1024));
        result.add("records", "reliability", rows);
        result.finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn cim_driver_dates_with_unspecified_fraction_and_offset_match_cim_utc() {
        assert_eq!(
            cim_date_millis("20060621000000.******+***").unwrap(),
            1150848000000
        );
        assert_eq!(
            cim_date_millis("20060621000000.123456+***").unwrap(),
            1150848000123
        );
        assert!(cim_date_millis("********000000.******+***").is_err());
    }
    #[test]
    fn combined_diagnostics_stay_readable_with_explicit_omissions() {
        let mut result = Evidence::default();
        result
            .data
            .insert("large".into(), json!("x".repeat(3 * 1024 * 1024)));
        result.data.insert("small".into(), json!({"value":1}));
        let result = result.finish_bounded();
        assert_eq!(result["status"], "partial");
        assert!(result["data"].get("large").is_none());
        assert_eq!(result["data"]["small"]["value"], 1);
        assert_eq!(result["issues"][0]["source"], "large");
    }
    #[test]
    fn counter_precision_nulls_and_latency_fields_survive_serialization() {
        let input = json!({"Name":"disk","AvgDisksecPerRead":9007199254740993u64,
            "AvgDisksecPerRead_Base":0,"AvgDisksecPerWrite":null,
            "AvgDisksecPerWrite_Base":1,"AvgDisksecPerTransfer":2,
            "AvgDisksecPerTransfer_Base":3,"Frequency_PerfTime":10000000,
            "Timestamp_PerfTime":u64::MAX});
        let typed: DiskRaw = serde_json::from_value(input.clone()).unwrap();
        assert_eq!(serde_json::to_value(typed).unwrap(), input);
        assert!(!query_text::<Cpu>(None).contains('*'));
    }
    #[test]
    fn missing_provider_does_not_discard_other_sources_or_invent_rows() {
        let mut result = Evidence::default();
        result.add("cpu", "cpu", Ok(vec![json!({"Name":"_Total"})]));
        result.add("memory", "memory", Err("synthetic provider failure".into()));
        result.add("disks", "disks", Ok(vec![]));
        let result = result.finish();
        assert_eq!(result["status"], "partial");
        assert!(result["data"]["cpu"].is_array());
        assert_eq!(result["data"]["disks"], json!([]));
        assert!(result["data"].get("memory").is_none());
        assert_eq!(result["issues"][0]["source"], "memory");
    }
    #[test]
    fn bounded_enumeration_stops_and_reports_truncation_as_failure() {
        let mut visited = 0;
        let result = bounded_rows(
            (0..100).map(|_| {
                visited += 1;
                Ok(json!({"a":1}))
            }),
            2,
            100,
        );
        assert!(result.is_err());
        assert_eq!(visited, 3);
        assert!(bounded_rows([Ok(json!({"large":"12345678"}))], 2, 8).is_err());
    }
    #[test]
    fn reliability_preserves_windows_dates_and_seven_day_filter() {
        let at = chrono::DateTime::parse_from_rfc3339("2026-10-20T22:00:00+09:00")
            .unwrap()
            .with_timezone(&chrono::Local);
        let filter = reliability_filter(at).unwrap();
        let date = filter
            .strip_prefix("TimeGenerated >= '")
            .unwrap()
            .strip_suffix('\'')
            .unwrap();
        assert_eq!(
            crate::collect::date_millis(date).unwrap(),
            at.checked_sub_days(chrono::Days::new(7))
                .unwrap()
                .timestamp_millis()
        );
        let mut row = json!({"TimeGenerated":"20261020220000.123456+540","Message":"/Date(1)/"});
        legacy_time(&mut row).unwrap();
        assert_eq!(row["TimeGenerated"], "/Date(1792501200123)/");
        assert_eq!(row["Message"], "/Date(1)/");
        assert!(legacy_time(&mut json!({"TimeGenerated":"invalid"})).is_err());
    }
}
