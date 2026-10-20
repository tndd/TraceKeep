//! Shares the PowerShell writer's exclusive sidecar lock and preservation rules.
use flate2::read::MultiGzDecoder;
use serde_json::Value;
use sha2::{Digest, Sha256};
#[cfg(windows)]
use std::os::windows::fs::OpenOptionsExt;
use std::{
    fs::{self, File, OpenOptions},
    io::{self, Read, Seek, SeekFrom, Write},
    path::{Path, PathBuf},
};

pub(crate) fn suffix(path: &Path, suffix: &str) -> PathBuf {
    let mut p = path.as_os_str().to_os_string();
    p.push(suffix);
    p.into()
}
pub fn sha(bytes: &[u8]) -> String {
    format!("{:X}", Sha256::digest(bytes))
}

pub fn json_bytes(row: &Value) -> io::Result<Vec<u8>> {
    // Windows PowerShell recognizes legacy WMI date values as DateTime only
    // with escaped slashes. Do not coerce unrelated strings that resemble dates.
    let mut text = serde_json::to_string(row)?;
    for field in [
        "CreationDate",
        "TimeGenerated",
        "ReleaseDate",
        "DriverDate",
        "LastBootUpTime",
        "InstallDate",
    ] {
        text = escape_legacy_date(&text, field);
    }
    Ok(text.into_bytes())
}

fn escape_legacy_date(text: &str, field: &str) -> String {
    let marker = format!("\"{field}\":\"/Date(");
    let mut output = String::with_capacity(text.len());
    let mut offset = 0;
    while let Some(index) = text[offset..].find(&marker) {
        let start = offset + index;
        output.push_str(&text[offset..start]);
        let number = start + marker.len();
        if let Some(end) = text[number..].find(")/\"") {
            let end = number + end;
            if text[number..end].parse::<i64>().is_ok() {
                output.push_str(&format!("\"{field}\":\"\\/Date("));
                output.push_str(&text[number..end]);
                output.push_str(")\\/\"");
                offset = end + 3;
                continue;
            }
        }
        output.push_str(&marker);
        offset = number;
    }
    output.push_str(&text[offset..]);
    output
}

pub fn exclusive(path: &Path) -> io::Result<File> {
    let mut options = OpenOptions::new();
    options.read(true).write(true).create(true).truncate(false);
    #[cfg(windows)]
    options.share_mode(0);
    options.open(path)
}

pub fn read_shared(path: &Path, limit: u64) -> io::Result<Vec<u8>> {
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(windows)]
    options.share_mode(7); // read/write/delete: allow snapshot replacement
    let file = options.open(path)?;
    let mut bytes = Vec::new();
    file.take(limit + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > limit {
        return Err(io::Error::other("input exceeds size limit"));
    }
    Ok(bytes)
}

fn hash_stream(mut source: impl Read, mut target: impl Write) -> io::Result<String> {
    let mut hash = Sha256::new();
    let mut buffer = [0u8; 65536];
    loop {
        let n = source.read(&mut buffer)?;
        if n == 0 {
            break;
        }
        hash.update(&buffer[..n]);
        target.write_all(&buffer[..n])?;
    }
    Ok(format!("{:X}", hash.finalize()))
}

// Called only while owning the .lock file. Complete raw data exists before
// removing an archive. A corrupt/mismatching archive is never overwritten.
fn restore(path: &Path) -> io::Result<()> {
    let archive = suffix(path, ".gz");
    if !archive.exists() {
        return Ok(());
    }
    let receipt = suffix(&archive, ".sha256");
    if path.exists() {
        let raw_hash = hash_stream(File::open(path)?, io::sink())?;
        let archived_hash = hash_stream(MultiGzDecoder::new(File::open(&archive)?), io::sink())?;
        if raw_hash != archived_hash {
            return Err(io::Error::other("raw/gzip conflict; both retained"));
        }
    } else {
        let expected = String::from_utf8(read_shared(&receipt, 256)?)
            .map_err(io::Error::other)?
            .trim()
            .to_uppercase();
        let partial = suffix(path, ".restore.partial");
        let mut target = File::create(&partial)?;
        let actual = hash_stream(MultiGzDecoder::new(File::open(&archive)?), &mut target)?;
        target.sync_all()?;
        drop(target);
        if actual != expected {
            return Err(io::Error::other("gzip receipt mismatch; archive retained"));
        }
        fs::rename(&partial, path)?;
    }
    fs::remove_file(archive)?;
    if receipt.exists() {
        fs::remove_file(receipt)?;
    }
    Ok(())
}

pub fn append(path: &Path, row: &Value) -> io::Result<u64> {
    let bytes = json_bytes(row)?;
    if bytes.len() > 8 * 1024 * 1024 {
        return Err(io::Error::other("record exceeds 8 MiB"));
    }
    let _gate = exclusive(&suffix(path, ".lock"))?;
    restore(path)?;
    let mut options = OpenOptions::new();
    options.read(true).write(true).create(true).truncate(false);
    #[cfg(windows)]
    options.share_mode(1).custom_flags(0x80000000); // READ / WRITE_THROUGH
    let mut file = options.open(path)?;
    if file.metadata()?.len() > 0 {
        file.seek(SeekFrom::End(-1))?;
        let mut last = [0];
        file.read_exact(&mut last)?;
        file.seek(SeekFrom::End(0))?;
        if last[0] != b'\n' {
            file.write_all(b"\n")?;
        }
    }
    file.write_all(&bytes)?;
    file.write_all(b"\n")?;
    file.sync_all()?;
    file.stream_position()
}

pub fn snapshot(path: &Path, row: &Value) -> io::Result<()> {
    snapshot_bytes(path, &json_bytes(row)?)
}

pub(crate) fn snapshot_bytes(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let temp = suffix(path, ".tmp");
    let mut file = File::create(&temp)?;
    file.write_all(bytes)?;
    file.sync_all()?;
    drop(file);
    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStrExt;
        use windows_sys::Win32::Storage::FileSystem::{
            MoveFileExW, ReplaceFileW, MOVEFILE_WRITE_THROUGH,
        };
        let wide = |p: &Path| {
            p.as_os_str()
                .encode_wide()
                .chain(Some(0))
                .collect::<Vec<_>>()
        };
        let dest = wide(path);
        let src = wide(&temp);
        let backup = wide(&suffix(path, ".previous"));
        for attempt in 0..20 {
            let ok = unsafe {
                if path.exists() {
                    ReplaceFileW(
                        dest.as_ptr(),
                        src.as_ptr(),
                        backup.as_ptr(),
                        0,
                        std::ptr::null(),
                        std::ptr::null(),
                    )
                } else {
                    MoveFileExW(src.as_ptr(), dest.as_ptr(), MOVEFILE_WRITE_THROUGH)
                }
            };
            if ok != 0 {
                return Ok(());
            }
            let error = io::Error::last_os_error();
            if !matches!(error.raw_os_error(), Some(5 | 32 | 33)) || attempt == 19 {
                return Err(error);
            }
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
        unreachable!()
    }
    #[cfg(not(windows))]
    fs::rename(temp, path)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    fn root() -> PathBuf {
        let p = std::env::temp_dir().join(format!(
            "tracekeep-rust-storage-{}-{}",
            std::process::id(),
            chrono::Utc::now().timestamp_nanos_opt().unwrap()
        ));
        fs::create_dir_all(&p).unwrap();
        p
    }
    #[test]
    fn partial_tail_is_preserved_and_next_record_is_separate() {
        let path = root().join("log.jsonl");
        fs::write(&path, b"{interrupted").unwrap();
        append(&path, &json!({"sequence":1})).unwrap();
        let bytes = fs::read(path).unwrap();
        assert!(bytes.starts_with(b"{interrupted\n"));
        assert_eq!(
            serde_json::from_slice::<Value>(&bytes[13..]).unwrap()["sequence"],
            1
        );
    }
    #[test]
    fn archived_day_restores_and_corruption_is_preserved() {
        use flate2::{write::GzEncoder, Compression};
        let path = root().join("log.jsonl");
        let raw = b"{\"sequence\":0}\n";
        let mut gzip = GzEncoder::new(Vec::new(), Compression::default());
        gzip.write_all(raw).unwrap();
        let compressed = gzip.finish().unwrap();
        fs::write(suffix(&path, ".gz"), &compressed).unwrap();
        fs::write(suffix(&path, ".gz.sha256"), sha(raw)).unwrap();
        append(&path, &json!({"sequence":1})).unwrap();
        assert!(fs::read(&path).unwrap().starts_with(raw));
        let broken = root().join("broken.jsonl");
        let mut corrupt = compressed;
        let index = corrupt.len() - 8;
        corrupt[index] ^= 1;
        fs::write(suffix(&broken, ".gz"), &corrupt).unwrap();
        fs::write(suffix(&broken, ".gz.sha256"), sha(raw)).unwrap();
        assert!(append(&broken, &json!({})).is_err());
        assert_eq!(fs::read(suffix(&broken, ".gz")).unwrap(), corrupt);
        assert!(!broken.exists());
    }
    #[test]
    fn snapshot_replaces_and_bounded_read_rejects_oversize() {
        let path = root().join("state.json");
        snapshot(&path, &json!({"sequence":0})).unwrap();
        snapshot(&path, &json!({"sequence":1})).unwrap();
        assert_eq!(
            serde_json::from_slice::<Value>(&read_shared(&path, 100).unwrap()).unwrap()["sequence"],
            1
        );
        assert!(read_shared(&path, 1).is_err());
    }
    #[test]
    fn legacy_dates_keep_powershell_datetime_decoding_without_changing_json_values() {
        let row = json!({"CreationDate":"/Date(123)/","TimeGenerated":"/Date(789)/","raw":"{\"path\":\"a/b\"}","ordinary":"/Date(456)/"});
        let bytes = json_bytes(&row).unwrap();
        assert!(String::from_utf8(bytes.clone())
            .unwrap()
            .contains(r"\/Date(789)\/"));
        assert!(String::from_utf8(bytes.clone())
            .unwrap()
            .contains(r"\/Date(123)\/"));
        assert!(String::from_utf8(bytes.clone())
            .unwrap()
            .contains(r#""ordinary":"/Date(456)/""#));
        assert_eq!(serde_json::from_slice::<Value>(&bytes).unwrap(), row);
    }
}
