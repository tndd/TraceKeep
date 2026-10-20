//! Bounded, read-only saved-log queries shared by CLI and desktop.
use crate::{Sources,machine_dir};
use chrono::{DateTime,Utc,Local};
use serde_json::{json,Value};
use std::{collections::{BTreeMap,VecDeque},fs,io::{Read,BufRead,BufReader},path::Path};
const FILE_LIMIT:u64=512*1024*1024;
const ROW_LIMIT:usize=100_000;
const OUTPUT_LIMIT:usize=32*1024*1024;
pub fn query(sources:&Sources,start:&str,end:&str)->Result<Value,String>{
    let a=DateTime::parse_from_rfc3339(start).map_err(|_|"Invalid start timestamp")?.timestamp_millis();
    let b=DateTime::parse_from_rfc3339(end).map_err(|_|"Invalid end timestamp")?.timestamp_millis();
    if b<=a||b-a>7_200_000{return Err("Select a positive range of at most two hours".into());}
    let mut streams=BTreeMap::new();
    for (key,prefix,sensor) in [("cpu","cpu-auto-",true),("board","board-auto-",true),("activity","activity-",false),("events","events-",false),("performance","detail-performance-",false),("processes","detail-processes-",false),("gpuDetails","detail-gpuDetails-",false),("storage","storage-",false)]{
        streams.insert(key,read_stream(if sensor{&sources.sensor_root}else{&sources.activity_root},prefix,a,b));
    }
    let read_json=|name:&str|fs::read(machine_dir().join(name)).ok().and_then(|x|serde_json::from_slice::<Value>(&x).ok()).unwrap_or(Value::Null);
    Ok(json!({"schemaVersion":1,"start":start,"end":end,"queriedAt":Utc::now().to_rfc3339(),"streams":streams,"settings":read_json("collection-settings.json"),"coverage":read_json("coverage.json"),"crashConfiguration":read_json("crash-configuration.json"),"sources":sources}))
}
fn compact(prefix:&str,mut row:Value)->Value{
    if prefix=="events-" && row["provider"].as_str().is_some_and(|p|p.contains("PowerShell")) {row["xml"]=Value::Null;row["xmlOmitted"]=json!("High-volume PowerShell content omitted from view; retained in original log");}
    if let Some(sensors)=row["sensors"].as_array_mut(){for s in sensors{if let Some(o)=s.as_object_mut(){o.retain(|k,_|matches!(k.as_str(),"id"|"name"|"type"|"value"|"hardware"|"available"));}}}
    row
}
fn read_stream(root:&Path,prefix:&str,a:i64,b:i64)->Value{
    read_stream_with_limit(root,prefix,a,b,FILE_LIMIT)
}
fn read_stream_with_limit(root:&Path,prefix:&str,a:i64,b:i64,file_limit:u64)->Value{
    read_stream_with_limits(root,prefix,a,b,file_limit,ROW_LIMIT,OUTPUT_LIMIT)
}
fn read_stream_with_limits(root:&Path,prefix:&str,a:i64,b:i64,file_limit:u64,row_limit:usize,output_limit:usize)->Value{
    let mut issues=vec![];let mut invalid=0;let mut incomplete=0;let mut unresolved=0;let mut clipped=false;let mut rows=VecDeque::new();let mut bytes_out=0;let mut cache:BTreeMap<String,Value>=BTreeMap::new();
    let mut matched=0usize;let mut omitted=0usize;
    let files=match crate::log_files::daily_paths(root,prefix){Ok(v)=>v,Err(e)=>return json!({"rows":[],"issues":[e.to_string()],"truncated":false})};
    // Collectors name files using the recording machine's local calendar.
    let min=DateTime::from_timestamp_millis(a).unwrap().with_timezone(&Local).format("%Y%m%d").to_string();
    let max=DateTime::from_timestamp_millis(b-1+if prefix=="events-"{86_400_000}else{0}).unwrap().with_timezone(&Local).format("%Y%m%d").to_string();
    let paths=files.into_iter().filter(|(day,_)|day>=&min&&day<=&max).map(|(_,path)|path);
    for path in paths.into_iter().take(4){
        let result=(||->Result<(),String>{
            let mut file=crate::log_files::open_snapshot(&path).map_err(|e|e.to_string())?;
            // Apply the bound to DECOMPRESSED bytes, including gzip expansion.
            let mut reader=BufReader::new(file.by_ref().take(file_limit));let mut discarding=false;
            loop {
                let mut line=Vec::new();
                // Bound even a malformed single line, while continuing after its newline.
                let count=Read::by_ref(&mut reader).take(4*1024*1024).read_until(b'\n',&mut line).map_err(|e|e.to_string())?;
                if count==0{break;}
                if line.last()!=Some(&b'\n') {if count==4*1024*1024{if !discarding{invalid+=1;}discarding=true;}else{incomplete+=1;}continue;}
                if discarding{discarding=false;continue;}
                if line.iter().all(u8::is_ascii_whitespace){continue;}
                let line=line.strip_prefix(&[239,187,191]).unwrap_or(&line);
                let mut r=match serde_json::from_slice::<Value>(line){Ok(r)=>r,Err(_)=>{invalid+=1;continue;}};
                if let Some(hash)=r["sha256"].as_str().map(str::to_owned){
                    if !r["result"].is_null(){if cache.len()>=64{cache.clear();}cache.insert(hash,r["result"].clone());}
                    else if r["unchanged"]==true {if let Some(v)=cache.get(&hash){r["result"]=v.clone();}else{unresolved+=1;}}
                }
                let Some(t)=r["time"].as_str().and_then(|t|DateTime::parse_from_rfc3339(t).ok()).map(|t|t.timestamp_millis()) else{invalid+=1;continue;};
                if t<a||t>=b{continue;}
                matched+=1;
                let r=compact(prefix,r);let n=r.to_string().len();
                rows.push_back((r,n));bytes_out+=n;
                while rows.len()>row_limit||bytes_out>output_limit {if let Some((_,n))=rows.pop_front(){bytes_out-=n;clipped=true;omitted+=1;}else{break;}}
            }
            // Probe EOF through the decoder to validate its trailer/checksum.
            drop(reader);
            let mut probe=[0u8;1];
            if file.read(&mut probe).map_err(|e|e.to_string())?>0{clipped=true;}
            Ok(())
        })();if let Err(e)=result{issues.push(format!("{}: {e}",path.file_name().unwrap().to_string_lossy()));}
    }
    json!({"returnedRows":rows.len(),"matchedRowsInScan":matched,"omittedRows":omitted,"rows":rows.into_iter().map(|(r,_)|r).collect::<Vec<_>>(),"issues":issues,"invalidLines":invalid,"incompleteTails":incomplete,"unresolvedReferences":unresolved,"truncated":clipped,"retention":"bounded range; all matching samples unless explicit limits are reached"})
}
#[cfg(test)]mod tests{
 use super::*;
 use std::io::Write;
 use flate2::{write::GzEncoder,Compression};
 fn gzip(path:&Path,bytes:&[u8]) {
  let mut encoder=GzEncoder::new(fs::File::create(path).unwrap(),Compression::default());
  encoder.write_all(bytes).unwrap();encoder.finish().unwrap();
 }
 #[test]fn detailed_history_keeps_intermediate_samples_and_reports_real_limits(){
  let dir=std::env::temp_dir().join(format!("tracekeep-complete-{}",Utc::now().timestamp_nanos_opt().unwrap()));fs::create_dir_all(&dir).unwrap();
  let start=Local::now();let a=start.timestamp_millis();let b=a+60_000;
  for prefix in ["detail-processes-","detail-gpuDetails-"] {
   let path=dir.join(format!("{prefix}{}.jsonl",start.format("%Y%m%d")));
   let bytes=(0..14).map(|i|format!("{}\n",json!({"time":start.to_rfc3339(),"sequence":i,"result":{"data":i}}))).collect::<String>();
   fs::write(&path,&bytes).unwrap();
   let raw=read_stream(&dir,prefix,a,b);
   assert_eq!(raw["rows"].as_array().unwrap().len(),14);
   assert_eq!(raw["rows"][0]["sequence"],0);assert_eq!(raw["rows"][13]["sequence"],13);
   assert_eq!(raw["matchedRowsInScan"],14);assert_eq!(raw["omittedRows"],0);assert_eq!(raw["truncated"],false);
   gzip(&path.with_extension("jsonl.gz"),bytes.as_bytes());fs::remove_file(&path).unwrap();
   assert_eq!(read_stream(&dir,prefix,a,b),raw);
   let capped=read_stream_with_limits(&dir,prefix,a,b,FILE_LIMIT,3,OUTPUT_LIMIT);
   assert_eq!(capped["returnedRows"],3);assert_eq!(capped["omittedRows"],11);assert_eq!(capped["truncated"],true);
   let byte_capped=read_stream_with_limits(&dir,prefix,a,b,FILE_LIMIT,ROW_LIMIT,1);
   assert_eq!(byte_capped["returnedRows"],0);assert_eq!(byte_capped["omittedRows"],14);assert_eq!(byte_capped["truncated"],true);
  }
  fs::remove_dir_all(dir).unwrap();
 }
 #[test]fn bounds_partial_and_references(){
  let dir=std::env::temp_dir().join(format!("tracekeep-history-{}",Utc::now().timestamp_nanos_opt().unwrap()));fs::create_dir_all(&dir).unwrap();
  let source=Sources{sensor_root:dir.clone(),activity_root:dir.clone()};
  fs::write(dir.join("cpu-auto-20260101.jsonl"),"{\"time\":\"2026-01-01T00:00:00Z\",\"sensors\":[]}\nbad\n{\"time\":").unwrap();
  fs::write(dir.join("detail-performance-20260101.jsonl"),"{\"time\":\"2025-12-31T23:59:00Z\",\"sha256\":\"x\",\"result\":{\"data\":5}}\n{\"time\":\"2026-01-01T00:01:00Z\",\"sha256\":\"x\",\"unchanged\":true}\n").unwrap();
  let q=query(&source,"2026-01-01T00:00:00Z","2026-01-01T02:00:00Z").unwrap();
  assert_eq!(q["streams"]["cpu"]["rows"].as_array().unwrap().len(),1);assert_eq!(q["streams"]["cpu"]["invalidLines"],1);assert_eq!(q["streams"]["cpu"]["incompleteTails"],1);
  assert_eq!(q["streams"]["performance"]["rows"][0]["result"]["data"],5);
  assert!(query(&source,"2026-01-01T00:00:00Z","2026-01-02T00:00:00Z").is_err());
  fs::write(dir.join("cpu-auto-20260101.jsonl"),"\n").unwrap();assert_eq!(query(&source,"2026-01-01T00:00:00Z","2026-01-01T02:00:00Z").unwrap()["streams"]["cpu"]["rows"],json!([]));fs::remove_dir_all(dir).unwrap();
 }
 #[test]fn gzip_history_matches_raw_and_deduplicates_interrupted_commit(){
  let dir=std::env::temp_dir().join(format!("tracekeep-gzip-{}",Utc::now().timestamp_nanos_opt().unwrap()));
  fs::create_dir_all(&dir).unwrap();
  let a=DateTime::parse_from_rfc3339("2026-01-01T10:00:00+09:00").unwrap().timestamp_millis();
  let b=a+3_600_000;
  let day=DateTime::from_timestamp_millis(a).unwrap().with_timezone(&Local).format("%Y%m%d").to_string();
  let raw=dir.join(format!("detail-performance-{day}.jsonl"));let compressed=raw.with_extension("jsonl.gz");
  let bytes=b"{\"time\":\"2026-01-01T10:01:00+09:00\",\"sha256\":\"x\",\"result\":{\"data\":5}}\n{\"time\":\"2026-01-01T10:02:00+09:00\",\"sha256\":\"x\",\"unchanged\":true}\nbad\n{\"time\":";
  fs::write(&raw,bytes).unwrap();
  let expected=read_stream(&dir,"detail-performance-",a,b);
  gzip(&compressed,bytes);
  assert_eq!(read_stream(&dir,"detail-performance-",a,b),expected);
  fs::remove_file(&raw).unwrap();
  let actual=read_stream(&dir,"detail-performance-",a,b);
  assert_eq!(actual,expected);
  assert_eq!(actual["rows"][1]["result"]["data"],5);
  // A reader which discovered raw before compression can open the archive.
  let mut recovered=vec![];crate::log_files::open_snapshot(&raw).unwrap().read_to_end(&mut recovered).unwrap();
  assert_eq!(recovered,bytes);
  let clipped=read_stream_with_limit(&dir,"detail-performance-",a,b,80);
  assert_eq!(clipped["truncated"],true);
  let mut broken=fs::read(&compressed).unwrap();
  let last=broken.len()-8;broken[last]^=0xff;fs::write(&compressed,&broken).unwrap();
  assert!(!read_stream(&dir,"detail-performance-",a,b)["issues"].as_array().unwrap().is_empty());
  gzip(&compressed,bytes);let mut truncated=fs::read(&compressed).unwrap();truncated.truncate(truncated.len()-5);fs::write(&compressed,truncated).unwrap();
  assert!(!read_stream(&dir,"detail-performance-",a,b)["issues"].as_array().unwrap().is_empty());
  fs::remove_dir_all(dir).unwrap();
 }
 #[test]fn mixed_midnight_raw_and_gzip_history(){
  let dir=std::env::temp_dir().join(format!("tracekeep-midnight-{}",Utc::now().timestamp_nanos_opt().unwrap()));
  fs::create_dir_all(&dir).unwrap();
  use chrono::TimeZone;
  let midnight=Local.with_ymd_and_hms(2026,1,2,0,0,0).single().unwrap();
  let before=midnight-chrono::Duration::minutes(1);let after=midnight+chrono::Duration::minutes(1);
  let first=format!("{}\n",json!({"time":before.to_rfc3339(),"sequence":1}));
  let second=format!("{}\n",json!({"time":after.to_rfc3339(),"sequence":2}));
  gzip(&dir.join(format!("cpu-auto-{}.jsonl.gz",before.format("%Y%m%d"))),first.as_bytes());
  fs::write(dir.join(format!("cpu-auto-{}.jsonl",after.format("%Y%m%d"))),second).unwrap();
  let value=read_stream(&dir,"cpu-auto-",before.timestamp_millis(),after.timestamp_millis()+1);
  assert_eq!(value["rows"].as_array().unwrap().len(),2);
  assert_eq!(value["rows"][0]["sequence"],1);assert_eq!(value["rows"][1]["sequence"],2);
  assert_eq!(value["truncated"],false);assert!(value["issues"].as_array().unwrap().is_empty());
  fs::remove_dir_all(dir).unwrap();
 }
}
