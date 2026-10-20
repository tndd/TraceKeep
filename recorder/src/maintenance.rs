//! Streaming, verified compression. The original is the recovery copy until
//! gzip verification and its durable receipt have both committed.
use crate::storage::{self, suffix};
use flate2::{read::MultiGzDecoder, write::GzEncoder, Compression};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
#[cfg(windows)]
use std::os::windows::fs::OpenOptionsExt;
use std::{
    fs::{self, File, OpenOptions},
    io::{self, Read, Seek, SeekFrom, Write},
    path::Path,
    time::{Duration, Instant},
};

fn copy_hash(
    mut source: impl Read,
    mut target: impl Write,
    progress: &mut impl FnMut() -> io::Result<()>,
) -> io::Result<String> {
    let mut hash = Sha256::new();
    let mut buffer = [0u8; 65536];
    loop {
        progress()?;
        let n = source.read(&mut buffer)?;
        if n == 0 {
            break;
        }
        hash.update(&buffer[..n]);
        target.write_all(&buffer[..n])?;
    }
    Ok(format!("{:X}", hash.finalize()))
}
fn compress(path: &Path, progress: &mut impl FnMut() -> io::Result<()>) -> io::Result<Value> {
    let _gate = storage::exclusive(&suffix(path, ".lock"))?;
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(windows)]
    options.share_mode(1);
    let mut source = options.open(path)?;
    let original = source.metadata()?.len();
    let hash = copy_hash(&mut source, io::sink(), progress)?;
    source.seek(SeekFrom::Start(0))?;
    let archive = suffix(path, ".gz");
    if !archive.exists() {
        let partial = suffix(&archive, ".partial");
        let output = File::create(&partial)?;
        let mut gzip = GzEncoder::new(output, Compression::default());
        copy_hash(&mut source, &mut gzip, progress)?;
        gzip.finish()?.sync_all()?;
        if copy_hash(
            MultiGzDecoder::new(File::open(&partial)?),
            io::sink(),
            progress,
        )? != hash
        {
            return Err(io::Error::other(
                "Compressed content differs; original retained",
            ));
        }
        fs::rename(partial, &archive)?;
    } else if copy_hash(
        MultiGzDecoder::new(File::open(&archive)?),
        io::sink(),
        progress,
    )? != hash
    {
        return Err(io::Error::other("Existing archive differs; both retained"));
    }
    storage::snapshot_bytes(&suffix(&archive, ".sha256"), hash.as_bytes())?;
    let compressed = archive.metadata()?.len();
    progress()?;
    drop(source);
    fs::remove_file(path)?;
    Ok(
        json!({"file":path.file_name().unwrap().to_string_lossy(),"status":"compressed",
        "originalBytes":original,"compressedBytes":compressed,"sha256":hash}),
    )
}
fn eligible(name: &str, cutoff: chrono::NaiveDate) -> bool {
    let Some(stem) = name.strip_suffix(".jsonl") else {
        return false;
    };
    let Some((prefix, date)) = stem.rsplit_once('-') else {
        return false;
    };
    if prefix.is_empty()
        || !prefix.as_bytes()[0].is_ascii_alphabetic()
        || !prefix
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || c == b'-')
        || date.len() != 8
        || !date.bytes().all(|c| c.is_ascii_digit())
    {
        return false;
    }
    chrono::NaiveDate::parse_from_str(date, "%Y%m%d").is_ok_and(|day| day < cutoff)
}
fn pass(
    logs: &Path,
    at: chrono::NaiveDate,
    progress: &mut impl FnMut() -> io::Result<()>,
) -> io::Result<Vec<Value>> {
    let cutoff = at
        .pred_opt()
        .ok_or_else(|| io::Error::other("Invalid cutoff"))?;
    let mut paths = Vec::new();
    for entry in fs::read_dir(logs)? {
        let entry = entry?;
        if entry.file_type()?.is_file() && eligible(&entry.file_name().to_string_lossy(), cutoff) {
            paths.push(entry.path());
            if paths.len() > 100000 {
                return Err(io::Error::other("Log directory exceeds enumeration limit"));
            }
        }
    }
    paths.sort();
    let mut results = Vec::new();
    for path in paths.into_iter().take(64) {
        progress()?;
        results.push(compress(&path,progress).unwrap_or_else(|e|json!({
            "file":path.file_name().unwrap().to_string_lossy(),"status":"deferred","error":e.to_string()})));
    }
    Ok(results)
}
pub fn run(options: &crate::Options) -> io::Result<()> {
    let _owner = storage::exclusive(&options.logs.join("maintenance.owner.lock"))?;
    let stop = options.logs.join("STOP-MAINTENANCE");
    let data = options
        .logs
        .parent()
        .ok_or_else(|| io::Error::other("Missing data root"))?;
    let mut previous_errors = json!([]);
    let mut count = 0;
    while !stop.exists() {
        let mut last = Instant::now() - Duration::from_secs(15);
        let mut progress = || {
            if stop.exists() {
                return Err(io::Error::other(
                    "Log maintenance stop requested; original retained",
                ));
            }
            if last.elapsed() >= Duration::from_secs(15) {
                storage::append(
                    &options
                        .logs
                        .join(format!("maintenance-{}.jsonl", crate::day())),
                    &json!({
                    "time":crate::now(),"event":"heartbeat","phase":"compressing","errors":previous_errors}),
                )?;
                last = Instant::now();
            }
            Ok(())
        };
        let files = match pass(
            &options.logs,
            chrono::Local::now().date_naive(),
            &mut progress,
        ) {
            Ok(files) => {
                previous_errors = json!(files
                    .iter()
                    .filter(|f| f["status"] != "compressed")
                    .collect::<Vec<_>>());
                files
            }
            Err(error) => {
                previous_errors = json!([{"error":error.to_string()}]);
                Vec::new()
            }
        };
        let row = json!({"time":crate::now(),"event":"heartbeat","phase":"idle","files":files,
            "errors":previous_errors,"policy":"Keep today and yesterday raw; gzip older daily logs; no age-based deletion"});
        storage::append(
            &options
                .logs
                .join(format!("maintenance-{}.jsonl", crate::day())),
            &row,
        )?;
        storage::snapshot(&data.join("log-maintenance.json"), &row)?;
        count += 1;
        if options.samples > 0 && count >= options.samples {
            break;
        }
        let until = Instant::now() + Duration::from_secs(60);
        while Instant::now() < until && !stop.exists() {
            std::thread::sleep(Duration::from_millis(250));
        }
    }
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    fn root() -> std::path::PathBuf {
        let root = std::env::temp_dir().join(format!(
            "maintenance-rust-{}",
            chrono::Utc::now().timestamp_nanos_opt().unwrap()
        ));
        fs::create_dir_all(&root).unwrap();
        root
    }
    #[test]
    fn retention_crc_receipt_and_clock_rollback_preserve_bytes() {
        let root = root();
        let date = chrono::NaiveDate::from_ymd_opt(2026, 10, 21).unwrap();
        for name in [
            "detail-test-20261019.jsonl",
            "detail-test-20261020.jsonl",
            "detail-test-20261021.jsonl",
            "detail-test-20260230.jsonl",
        ] {
            fs::write(root.join(name), b"{partial\n{\"sequence\":0}\n").unwrap();
        }
        let results = pass(&root, date, &mut || Ok(())).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0]["status"], "compressed");
        let raw = root.join("detail-test-20261019.jsonl");
        assert!(!raw.exists());
        storage::append(&raw, &json!({"sequence":1})).unwrap();
        assert!(fs::read(&raw)
            .unwrap()
            .starts_with(b"{partial\n{\"sequence\":0}\n"));
        assert!(!suffix(&raw, ".gz").exists());
    }
    #[test]
    fn interrupted_commit_resumes_and_conflict_corruption_never_remove_original() {
        let root = root();
        let raw = root.join("detail-test-20261019.jsonl");
        fs::write(&raw, b"original\n").unwrap();
        // Interrupt after the archive has been published, before deleting raw.
        assert!(compress(&raw, &mut || if suffix(&raw, ".gz").exists() {
            Err(io::Error::other("injected crash"))
        } else {
            Ok(())
        })
        .is_err());
        assert!(raw.exists());
        assert!(suffix(&raw, ".gz").exists());
        assert_eq!(
            compress(&raw, &mut || Ok(())).unwrap()["status"],
            "compressed"
        );
        fs::write(&raw, b"conflicting original\n").unwrap();
        assert!(compress(&raw, &mut || Ok(())).is_err());
        assert!(raw.exists());
        fs::write(suffix(&raw, ".gz"), b"corrupt").unwrap();
        assert!(compress(&raw, &mut || Ok(())).is_err());
        assert!(raw.exists());
    }
}
