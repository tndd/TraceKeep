//! Bounded, read-only saved-log queries shared by CLI and desktop.
use crate::{Sources,machine_dir};
use chrono::{DateTime,Utc,Local};
use serde_json::{json,Value};
use std::{collections::{BTreeMap,VecDeque},fs::{self,File},io::{Read,BufRead,BufReader},path::Path};
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
    Ok(json!({"schemaVersion":1,"start":start,"end":end,"queriedAt":Utc::now().to_rfc3339(),"streams":streams,"settings":read_json("collection-settings.json"),"coverage":read_json("coverage.json"),"sources":sources}))
}
fn compact(prefix:&str,mut row:Value)->Value{
    if prefix=="events-" && row["provider"].as_str().is_some_and(|p|p.contains("PowerShell")) {row["xml"]=Value::Null;row["xmlOmitted"]=json!("High-volume PowerShell content omitted from view; retained in original log");}
    if let Some(sensors)=row["sensors"].as_array_mut(){for s in sensors{if let Some(o)=s.as_object_mut(){o.retain(|k,_|matches!(k.as_str(),"id"|"name"|"type"|"value"|"hardware"|"available"));}}}
    row
}
fn read_stream(root:&Path,prefix:&str,a:i64,b:i64)->Value{
    let mut issues=vec![];let mut invalid=0;let mut incomplete=0;let mut unresolved=0;let mut clipped=false;let mut rows=VecDeque::new();let mut bytes_out=0;let mut cache:BTreeMap<String,Value>=BTreeMap::new();
    let files=match fs::read_dir(root){Ok(v)=>v,Err(e)=>return json!({"rows":[],"issues":[e.to_string()],"truncated":false})};
    // Collectors name files using the recording machine's local calendar.
    let min=DateTime::from_timestamp_millis(a).unwrap().with_timezone(&Local).format("%Y%m%d").to_string();
    let max=DateTime::from_timestamp_millis(b-1+if prefix=="events-"{86_400_000}else{0}).unwrap().with_timezone(&Local).format("%Y%m%d").to_string();
    let mut paths=files.filter_map(Result::ok).map(|e|e.path()).filter(|p|p.file_name().and_then(|n|n.to_str()).is_some_and(|n|n.strip_prefix(prefix).and_then(|s|s.strip_suffix(".jsonl")).is_some_and(|s|s.len()==8&&s>=min.as_str()&&s<=max.as_str()))).collect::<Vec<_>>();paths.sort();
    for path in paths.into_iter().take(4){
        let result=(||->Result<(),String>{
            let file=File::open(&path).map_err(|e|e.to_string())?;
            if file.metadata().map_err(|e|e.to_string())?.len()>FILE_LIMIT{clipped=true;}
            let mut reader=BufReader::new(file.take(FILE_LIMIT));let mut discarding=false;
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
                let r=compact(prefix,r);let n=r.to_string().len();
                if matches!(prefix,"detail-processes-"|"detail-gpuDetails-") && rows.len()>=2 {if let Some((_,n))=rows.pop_front(){bytes_out-=n;}}
                rows.push_back((r,n));bytes_out+=n;
                while rows.len()>ROW_LIMIT||bytes_out>OUTPUT_LIMIT {if let Some((_,n))=rows.pop_front(){bytes_out-=n;clipped=true;}else{break;}}
            }Ok(())
        })();if let Err(e)=result{issues.push(format!("{}: {e}",path.file_name().unwrap().to_string_lossy()));}
    }
    json!({"rows":rows.into_iter().map(|(r,_)|r).collect::<Vec<_>>(),"issues":issues,"invalidLines":invalid,"incompleteTails":incomplete,"unresolvedReferences":unresolved,"truncated":clipped,"retention":if matches!(prefix,"detail-processes-"|"detail-gpuDetails-"){"last two samples in range"}else{"bounded range"}})
}
#[cfg(test)]mod tests{
 use super::*;
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
}
