use crate::metrics::{query, Evidence, Query};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::path::PathBuf;
#[cfg(windows)]
use std::time::Duration;

query!(Battery, "Win32_Battery", {Name:String, BatteryStatus:u16, EstimatedChargeRemaining:u16, EstimatedRunTime:u32, Status:String});
query!(Thermal, "MSAcpi_ThermalZoneTemperature", {InstanceName:String, CurrentTemperature:u32, CriticalTripPoint:u32, PassiveTripPoint:u32, ThermalStamp:u32});

#[cfg(windows)]
pub fn power(reader: &mut crate::metrics::Reader, thermal: &mut crate::metrics::Reader) -> Value {
    let mut evidence = Evidence::default();
    evidence.add(
        "batteries",
        "batteries",
        reader.read::<Battery>(None, false, 262144),
    );
    let executable =
        PathBuf::from(std::env::var_os("WINDIR").unwrap_or_default()).join("System32/powercfg.exe");
    for argument in [
        "/getactivescheme",
        "/requests",
        "/lastwake",
        "/waketimers",
        "/a",
        "/qh",
    ] {
        match crate::command::run(&executable, argument, Duration::from_secs(5), true) {
            Ok(text) => {
                evidence.data.insert(argument.into(), json!(text));
            }
            Err(error) => evidence
                .issues
                .push(json!({"source":argument,"status":"unavailable","error":error})),
        }
    }
    evidence.add(
        "thermalZones",
        "ACPI thermal zones",
        thermal.read::<Thermal>(None, false, 262144),
    );
    evidence.finish_bounded()
}

pub fn nvidia_executable() -> Result<PathBuf, String> {
    let root = PathBuf::from(std::env::var_os("WINDIR").ok_or("Missing WINDIR")?)
        .join("System32/DriverStore/FileRepository");
    let mut paths = Vec::new();
    for (index, entry) in std::fs::read_dir(root)
        .map_err(|e| e.to_string())?
        .enumerate()
    {
        if index > 100000 {
            return Err("Driver directory enumeration limit".into());
        }
        let entry = entry.map_err(|e| e.to_string())?;
        if entry
            .file_name()
            .to_string_lossy()
            .to_ascii_lowercase()
            .starts_with("nv")
        {
            let path = entry.path().join("nvidia-smi.exe");
            if path.is_file() {
                paths.push(path)
            }
        }
    }
    paths.sort_by_key(|p| p.to_string_lossy().to_ascii_lowercase());
    paths
        .into_iter()
        .next()
        .ok_or("NVIDIA diagnostics executable unavailable".into())
}

fn strip_processes(xml: &str) -> Result<String, String> {
    use quick_xml::{events::Event, Reader, Writer};
    let mut reader = Reader::from_str(xml);
    let mut writer = Writer::new(Vec::new());
    let (mut depth, mut skip, mut roots) = (0usize, None, 0usize);
    loop {
        let event = reader.read_event().map_err(|e| e.to_string())?;
        if let Event::Start(tag) | Event::Empty(tag) = &event {
            for attribute in tag.attributes() {
                attribute
                    .map_err(|e| e.to_string())?
                    .decode_and_unescape_value(reader.decoder())
                    .map_err(|e| e.to_string())?;
            }
        }
        match &event {
            Event::GeneralRef(reference) => {
                if depth == 0 {
                    return Err("Reference outside NVIDIA XML root".into());
                }
                if reference
                    .resolve_char_ref()
                    .map_err(|e| e.to_string())?
                    .is_none()
                    && !matches!(
                        reference.as_ref(),
                        b"amp" | b"lt" | b"gt" | b"apos" | b"quot"
                    )
                {
                    return Err(
                        "Unsupported NVIDIA XML entity; external entities are not loaded".into(),
                    );
                }
            }
            Event::CData(_) if depth == 0 => return Err("CDATA outside NVIDIA XML root".into()),
            Event::Start(tag) => {
                if depth == 0 {
                    roots += 1;
                }
                if skip.is_none() && tag.name().as_ref() == b"processes" {
                    skip = Some(depth);
                }
                depth += 1;
                if depth > 128 {
                    return Err("NVIDIA XML nesting limit".into());
                }
            }
            Event::Empty(tag) => {
                if depth == 0 {
                    roots += 1;
                }
                if tag.name().as_ref() == b"processes" {
                    continue;
                }
            }
            Event::End(_) => {
                depth = depth.checked_sub(1).ok_or("Unbalanced NVIDIA XML")?;
                if skip == Some(depth) {
                    skip = None;
                    continue;
                }
            }
            Event::Eof => break,
            Event::Text(text)
                if depth == 0 && !text.as_ref().iter().all(u8::is_ascii_whitespace) =>
            {
                return Err("Unexpected text outside NVIDIA XML root".into());
            }
            _ => {}
        }
        if roots > 1 {
            return Err("Multiple NVIDIA XML roots".into());
        }
        if skip.is_none() {
            writer.write_event(event).map_err(|e| e.to_string())?;
        }
    }
    if depth != 0 || roots != 1 || skip.is_some() {
        return Err("Incomplete NVIDIA XML".into());
    }
    String::from_utf8(writer.into_inner()).map_err(|e| e.to_string())
}

#[cfg(windows)]
pub fn gpu() -> Value {
    let result = nvidia_executable()
        .and_then(|exe| crate::command::run(&exe, "-q -x", Duration::from_secs(5), false))
        .and_then(|text| strip_processes(&text));
    match result {
        Ok(xml) => {
            let mut evidence = Evidence::default();
            evidence.data.insert("xml".into(), json!(xml));
            evidence.finish_bounded()
        }
        Err(error) => {
            json!({"status":"partial","data":{},"issues":[{"source":"nvidia-smi XML","status":"unavailable","error":error}]})
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn removes_every_process_tree_but_retains_fault_counters_and_rejects_truncation() {
        let xml = r#"<?xml version="1.0"?><nvidia_smi_log><gpu><ecc>3</ecc><processes><process><name>private</name></process></processes><power>99</power></gpu><gpu><processes/><pcie>4</pcie></gpu></nvidia_smi_log>"#;
        let output = strip_processes(xml).unwrap();
        assert!(!output.contains("process"));
        assert!(!output.contains("private"));
        assert!(output.contains("<ecc>3</ecc>"));
        assert!(output.contains("<pcie>4</pcie>"));
        for invalid in [
            "<gpu>",
            "<gpu></other>",
            "<gpu/><gpu/>",
            "text<gpu/>",
            "<gpu>&unknown;</gpu>",
            "<gpu a=unquoted/>",
            "<gpu a='1' a='2'/>",
            "",
        ] {
            assert!(strip_processes(invalid).is_err(), "{invalid}");
        }
    }
}
