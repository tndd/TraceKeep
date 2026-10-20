//! Daily raw/gzip discovery and finite readers, shared by saved-history consumers.
use std::{collections::BTreeMap, fs::{self,File}, io::{self,Read}, path::{Path,PathBuf}};
use flate2::read::MultiGzDecoder;

pub fn daily_paths(root:&Path,prefix:&str)->io::Result<BTreeMap<String,PathBuf>> {
    let mut paths=BTreeMap::new();
    for entry in fs::read_dir(root)? {
        let entry=entry?;
        if !entry.file_type()?.is_file(){continue;}
        let name=entry.file_name();
        let Some(name)=name.to_str() else{continue};
        let compressed=name.ends_with(".gz");
        let raw=name.strip_suffix(".gz").unwrap_or(name);
        let Some(day)=raw.strip_prefix(prefix).and_then(|s|s.strip_suffix(".jsonl")) else{continue};
        if day.len()!=8 || !day.bytes().all(|b|b.is_ascii_digit()){continue;}
        // An interrupted compression commit leaves identical raw/gzip copies.
        if !compressed || !paths.contains_key(day){paths.insert(day.to_owned(),entry.path());}
    }
    Ok(paths)
}

pub fn open_snapshot(path:&Path)->io::Result<Box<dyn Read>> {
    let (file,compressed)=match File::open(path) {
        Ok(file)=>(file,path.extension().is_some_and(|s|s=="gz")),
        Err(e) if e.kind()==io::ErrorKind::NotFound=>{
            // Compression/restoration may finish between discovery and open.
            let compressed=path.extension().is_some_and(|s|s=="gz");
            let alternate=if compressed{path.with_extension("")}else{PathBuf::from(format!("{}.gz",path.display()))};
            (File::open(alternate)?,!compressed)
        },
        Err(e)=>return Err(e),
    };
    let length=file.metadata()?.len();
    let snapshot=file.take(length);
    Ok(if compressed{Box::new(MultiGzDecoder::new(snapshot))}else{Box::new(snapshot)})
}
