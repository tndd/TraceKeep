use diagnostics_core::{Monitor,Sources,export_snapshot,machine_dir};
use serde_json::{json,Value};
use std::{path::PathBuf,process::{Command,ExitCode},time::Duration};

fn management(action:&str,extra:&[String])->Result<i32,String>{
    let exe=std::env::current_exe().map_err(|e|e.to_string())?;
    let script=exe.parent().unwrap().join("management/Manage-Recorder.ps1");
    if !script.is_file(){return Err("Management package missing next to pcdiag.exe (management/Manage-Recorder.ps1). Extract the complete bundle.".into());}
    let shell=PathBuf::from(std::env::var_os("WINDIR").ok_or("WINDIR is unavailable")?).join("System32/WindowsPowerShell/v1.0/powershell.exe");
    let status=Command::new(shell).args(["-NoProfile","-ExecutionPolicy","Bypass","-File"]).arg(script).args(["-Action",action]).args(extra).status().map_err(|e|e.to_string())?;
    Ok(status.code().unwrap_or(1))
}
fn healthy(v:&Value)->bool{["cpu","board","activity"].iter().all(|k|v["streams"][k]["state"]=="recording")}
fn display(v:&Value){
    println!("PC Diagnostics  {}",v["time"].as_str().unwrap_or(""));
    for k in ["cpu","board","activity"]{let s=&v["streams"][k];println!("{k:10} {:12} age={}s  {}",s["state"].as_str().unwrap_or("unknown"),s["age"],s["path"].as_str().unwrap_or("no log"));}
    let last=|key:&str|v["streams"][key]["history"].as_array().and_then(|a|a.last()).cloned().unwrap_or(Value::Null);
    let cpu=last("cpu");let board=last("board");let gpu=last("activity");
    println!("Last readings: CPU {} C | GPU {} C / {} W | board +12V {} V",cpu["cpuTemp"],gpu["gpuTemp"],gpu["gpuPower"],board["v12"]);
}
fn run()->Result<i32,String>{
    let args:Vec<String>=std::env::args().skip(1).collect();
    let command=args.first().map(String::as_str).unwrap_or("help");
    if ["help","--help","-h"].contains(&command){
        println!("pcdiag status [--json]\npcdiag watch [--json]\npcdiag logs\npcdiag export\npcdiag doctor [--json]\npcdiag install --legacy-activity-root PATH\npcdiag start | stop | restart | rollback\n\nThe GUI is optional. Control/install commands require an Administrator terminal.\nExit codes: 0 success, 1 command failure, 2 stale/missing/error streams.");return Ok(0);
    }
    if ["start","stop","restart","rollback"].contains(&command){if args.len()!=1{return Err("Unexpected argument".into());}return management(command,&[]);}
    if command=="install"{
        if args.len()!=3 || args[1]!="--legacy-activity-root" {return Err("Use: pcdiag install --legacy-activity-root PATH".into());}
        return management("install",&["-LegacyActivityRoot".into(),args[2].clone()]);
    }
    if !["status","watch","logs","export","doctor"].contains(&command){return Err(format!("Unknown command: {command}. Run pcdiag help."));}
    if args.len()>2 || (args.len()==2 && (args[1]!="--json" || ["logs","export"].contains(&command))){return Err("Unexpected argument".into());}
    let sources=Sources::load()?;
    if command=="logs"{println!("{}",serde_json::to_string_pretty(&sources).unwrap());return Ok(0);}
    let mut monitor=Monitor::new(sources);
    loop{
        let mut v=monitor.snapshot();
        {
            let status=machine_dir().join("runtime.json");
            let runtime=if status.exists(){serde_json::from_slice::<Value>(&std::fs::read(&status).map_err(|e|e.to_string())?).map_err(|e|e.to_string())?}else{Value::Null};
            let age=runtime["time"].as_str().and_then(|t|chrono::DateTime::parse_from_rfc3339(t).ok()).map(|t|(chrono::Utc::now()-t.with_timezone(&chrono::Utc)).num_seconds());
            v["coordinator"]=json!({"configured":machine_dir().join("sources.json").exists(),"heartbeatAgeSeconds":age,"runtime":runtime});
        }
        if command=="export"{println!("{}",export_snapshot(&v)?.display());return Ok(0);}
        let ok=healthy(&v) && (command!="doctor" || (v["coordinator"]["configured"]==true && v["coordinator"]["heartbeatAgeSeconds"].as_i64().is_some_and(|age|(0..=10).contains(&age))));
        if args.iter().any(|a|a=="--json"){println!("{}",serde_json::to_string(&v).unwrap());}else{display(&v);if command=="doctor"{println!("Unified configuration: {}\nCoordinator heartbeat age: {}s\nWorkers: {}",v["coordinator"]["configured"],v["coordinator"]["heartbeatAgeSeconds"],v["coordinator"]["runtime"]["workers"]);}}
        if command!="watch"{return Ok(if ok{0}else{2});}
        std::thread::sleep(Duration::from_secs(2));
    }
}
fn main()->ExitCode{match run(){Ok(code)=>ExitCode::from(code as u8),Err(e)=>{eprintln!("pcdiag: {e}");ExitCode::FAILURE}}}
#[cfg(test)]mod tests{use super::*;#[test]fn status_requires_all_streams(){let mut s=json!({"streams":{"cpu":{"state":"recording"},"board":{"state":"recording"},"activity":{"state":"stale"}}});assert!(!healthy(&s));s["streams"]["activity"]["state"]=json!("recording");assert!(healthy(&s));assert!(!healthy(&json!({})));}}
