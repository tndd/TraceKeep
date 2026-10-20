//! Read-only space accounting with bounded traversal and explicit incomplete scans.
use serde_json::{json, Value};
use std::{
    fs, io,
    path::Path,
    time::{Duration, Instant},
};

pub fn reserve(settings: &Value) -> Result<u64, String> {
    let value = &settings["limits"]["reserveFreeBytes"];
    if value.is_null() {
        return Ok(10 * 1024 * 1024 * 1024);
    }
    value
        .as_u64()
        .filter(|v| *v > 0 && *v <= i64::MAX as u64)
        .ok_or_else(|| "Invalid reserveFreeBytes".into())
}

struct Budget {
    remaining: usize,
    deadline: Instant,
}
impl Budget {
    fn visit(&mut self) -> io::Result<()> {
        if self.remaining == 0 || Instant::now() >= self.deadline {
            return Err(io::Error::other(
                "directory scan limit reached; byte count unavailable",
            ));
        }
        self.remaining -= 1;
        Ok(())
    }
}
fn visible_regular(metadata: &fs::Metadata) -> io::Result<bool> {
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        let attributes = metadata.file_attributes();
        // Match Get-ChildItem without -Force, but do not follow junctions.
        if attributes & (2 | 4) != 0 {
            return Ok(false);
        }
        if attributes & 0x400 != 0 {
            return Err(io::Error::other(
                "reparse point not traversed; byte count unavailable",
            ));
        }
    }
    if metadata.file_type().is_symlink() {
        return Err(io::Error::other(
            "symbolic link not traversed; byte count unavailable",
        ));
    }
    Ok(true)
}
fn sum_directory(
    path: &Path,
    recurse: bool,
    depth: usize,
    budget: &mut Budget,
) -> io::Result<Option<u64>> {
    budget.visit()?;
    if depth > 128 {
        return Err(io::Error::other("directory depth limit reached"));
    }
    let metadata = fs::symlink_metadata(path)?;
    if !visible_regular(&metadata)? {
        return Ok(None);
    }
    let mut total: Option<u64> = None;
    for entry in fs::read_dir(path)? {
        budget.visit()?;
        let entry = entry?;
        let metadata = fs::symlink_metadata(entry.path())?;
        if !visible_regular(&metadata)? {
            continue;
        }
        let size = if metadata.is_file() {
            Some(metadata.len())
        } else if metadata.is_dir() && recurse {
            sum_directory(&entry.path(), true, depth + 1, budget)?
        } else {
            None
        };
        if let Some(size) = size {
            total = Some(
                total
                    .unwrap_or(0)
                    .checked_add(size)
                    .ok_or_else(|| io::Error::other("byte count overflow"))?,
            );
        }
    }
    Ok(total)
}

#[cfg(windows)]
fn drive_space(root: &Path) -> io::Result<(u64, u64)> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Storage::FileSystem::GetDiskFreeSpaceExW;
    let path: Vec<u16> = root.as_os_str().encode_wide().chain(Some(0)).collect();
    let (mut free, mut total) = (0, 0);
    if unsafe { GetDiskFreeSpaceExW(path.as_ptr(), &mut free, &mut total, std::ptr::null_mut()) }
        == 0
    {
        return Err(io::Error::last_os_error());
    }
    Ok((free, total))
}

fn evidence(
    root: &Path,
    reserve: u64,
    drive: io::Result<(u64, u64)>,
    budget: &mut Budget,
) -> Value {
    let mut issues = vec![];
    let (free, total) = match drive {
        Ok((free, total)) => (Some(free), Some(total)),
        Err(error) => {
            issues.push(json!({"source":"drive","status":"unavailable","error":error.to_string()}));
            (None, None)
        }
    };
    let mut scan = |name: &str, recursive: bool| -> Option<u64> {
        let path = root.join(name);
        let result = if name == "archive" {
            match fs::symlink_metadata(&path) {
                Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(Some(0)),
                Err(e) => Err(e),
                Ok(_) => sum_directory(&path, recursive, 0, budget),
            }
        } else {
            sum_directory(&path, recursive, 0, budget)
        };
        match result {
            Ok(bytes) => bytes,
            Err(error) => {
                issues
                    .push(json!({"source":name,"status":"unavailable","error":error.to_string()}));
                None
            }
        }
    };
    let logs = scan("logs", false);
    let archive = scan("archive", true);
    // Preserve the low-space warning even if an independent scan failed.
    let status = if free.is_some_and(|f| f < reserve) {
        "warning"
    } else if issues.is_empty() {
        "ok"
    } else {
        "partial"
    };
    json!({"status":status,"issues":issues,"data":{"freeBytes":free,"totalBytes":total,
        "logBytes":logs,"archiveBytes":archive,"reserveFreeBytes":reserve,"automaticDeletion":false}})
}

#[cfg(windows)]
pub fn collect(root: &Path, reserve: u64) -> Value {
    let mut budget = Budget {
        remaining: 100_000,
        deadline: Instant::now() + Duration::from_secs(10),
    };
    evidence(root, reserve, drive_space(root), &mut budget)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn root() -> std::path::PathBuf {
        let root = std::env::temp_dir().join(format!(
            "tracekeep-space-{}",
            chrono::Utc::now().timestamp_nanos_opt().unwrap()
        ));
        fs::create_dir_all(root.join("logs/nested")).unwrap();
        fs::write(root.join("logs/a.jsonl"), b"123").unwrap();
        fs::write(root.join("logs/nested/excluded"), b"123456789").unwrap();
        root
    }
    fn budget(remaining: usize) -> Budget {
        Budget {
            remaining,
            deadline: Instant::now() + Duration::from_secs(10),
        }
    }
    #[test]
    fn counts_top_level_logs_recursive_archive_and_warns_without_deleting() {
        let root = root();
        fs::create_dir_all(root.join("archive/nested")).unwrap();
        fs::write(root.join("archive/nested/a"), b"12345").unwrap();
        let row = evidence(&root, 10, Ok((9, 100)), &mut budget(100));
        assert_eq!(row["status"], "warning");
        assert_eq!(row["data"]["logBytes"], 3);
        assert_eq!(row["data"]["archiveBytes"], 5);
        assert_eq!(row["data"]["automaticDeletion"], false);
        assert!(root.join("archive/nested/a").exists());
        assert!(row["issues"].as_array().unwrap().is_empty());
    }
    #[test]
    fn missing_archive_empty_scan_and_incomplete_scan_are_distinct() {
        let root = root();
        assert_eq!(
            evidence(&root, 1, Ok((10, 100)), &mut budget(100))["data"]["archiveBytes"],
            0
        );
        fs::create_dir(root.join("archive")).unwrap();
        assert!(
            evidence(&root, 1, Ok((10, 100)), &mut budget(100))["data"]["archiveBytes"].is_null()
        );
        let row = evidence(&root, 1, Ok((10, 100)), &mut budget(1));
        assert_eq!(row["status"], "partial");
        assert!(row["data"]["logBytes"].is_null());
        assert!(!row["issues"].as_array().unwrap().is_empty());
        let row = evidence(
            &root,
            1,
            Err(io::Error::other("synthetic denied")),
            &mut budget(100),
        );
        assert!(row["data"]["freeBytes"].is_null());
        assert_eq!(row["data"]["logBytes"], 3);
        assert!(reserve(&json!({"limits":{"reserveFreeBytes":0}})).is_err());
    }
}
