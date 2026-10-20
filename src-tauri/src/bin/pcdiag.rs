use diagnostics_core::{Monitor,Sources,export_snapshot,machine_dir};
use serde_json::{json,Value};
use std::{path::PathBuf,process::{Command,ExitCode},time::Duration,io::{Read,Seek,SeekFrom}};

fn management(action:&str,extra:&[String])->Result<i32,String>{
    let exe=std::env::current_exe().map_err(|e|e.to_string())?;
    let script=exe.parent().unwrap().join(if action=="upgrade"{"management/Update-Recorder.ps1"}else if action=="config"{"management/Configure-Recorder.ps1"}else{"management/Manage-Recorder.ps1"});
    if !script.is_file(){return Err("Management package missing next to pcdiag.exe (management/Manage-Recorder.ps1). Extract the complete bundle.".into());}
    let shell=PathBuf::from(std::env::var_os("WINDIR").ok_or("WINDIR is unavailable")?).join("System32/WindowsPowerShell/v1.0/powershell.exe");
    let mut cmd=Command::new(shell);cmd.args(["-NoProfile","-ExecutionPolicy","Bypass","-File"]).arg(script);
    if action!="upgrade" && action!="config"{cmd.args(["-Action",action]);}
    let status=cmd.args(extra).status().map_err(|e|e.to_string())?;
    Ok(status.code().unwrap_or(1))
}
fn intentionally_disabled(v:&Value,key:&str)->bool{
    v["coordinator"]["runtime"]["workers"].as_array().is_some_and(|a|a.iter().any(|w|w["name"]==key && w["enabled"]==false && w["state"]=="disabled"))
}
fn healthy(v:&Value)->bool{["cpu","board","activity"].iter().all(|k|intentionally_disabled(v,k)||v["streams"][k]["state"]=="recording")}
fn evidence_healthy(v:&Value)->bool{
    v["coordinator"]["runtime"]["workers"].as_array().is_some_and(|workers|workers.iter().any(|w|w["name"]=="evidence" && w["state"]=="recording" && w["errorCount"].as_u64()==Some(0)))
}
fn read_json(path:PathBuf)->Value{
    match std::fs::read(&path){Ok(bytes)=>serde_json::from_slice(&bytes).unwrap_or_else(|e|json!({"error":e.to_string(),"path":path})),Err(e)=>json!({"error":e.to_string(),"path":path})}
}
fn latest_evidence(prefix:&str)->Value{
    let root=machine_dir().join("logs");
    let mut paths=match std::fs::read_dir(root){Ok(entries)=>entries.filter_map(Result::ok).map(|e|e.path()).filter(|p|p.file_name().and_then(|s|s.to_str()).is_some_and(|s|s.starts_with(prefix)&&s.ends_with(".jsonl"))).collect::<Vec<_>>(),Err(e)=>return json!({"error":e.to_string()})};
    paths.sort();
    let Some(path)=paths.last() else{return json!({"error":"No evidence log yet"})};
    let result=(||->Result<Value,String>{let mut file=std::fs::File::open(path).map_err(|e|e.to_string())?;let length=file.metadata().map_err(|e|e.to_string())?.len();let start=length.saturating_sub(256*1024);file.seek(SeekFrom::Start(start)).map_err(|e|e.to_string())?;let mut bytes=Vec::new();file.take(256*1024).read_to_end(&mut bytes).map_err(|e|e.to_string())?;let text=String::from_utf8_lossy(&bytes);text.lines().rev().find_map(|line|serde_json::from_str::<Value>(line).ok()).ok_or("No complete evidence row".into())})();
    result.unwrap_or_else(|e|json!({"error":e,"path":path}))
}
fn display(v:&Value){
    println!("TraceKeep  {}",v["time"].as_str().unwrap_or(""));
    for k in ["cpu","board","activity"]{let s=&v["streams"][k];println!("{k:10} {:12} age={}s  {}",if intentionally_disabled(v,k){"disabled"}else{s["state"].as_str().unwrap_or("unknown")},s["age"],s["path"].as_str().unwrap_or("no log"));}
    let last=|key:&str|v["streams"][key]["history"].as_array().and_then(|a|a.last()).cloned().unwrap_or(Value::Null);
    let cpu=last("cpu");let board=last("board");let gpu=last("activity");
    println!("Last readings: CPU {} C | GPU {} C / {} W | board +12V {} V",cpu["cpuTemp"],gpu["gpuTemp"],gpu["gpuPower"],board["v12"]);
}
fn run()->Result<i32,String>{
    let args:Vec<String>=std::env::args().skip(1).collect();
    let command=args.first().map(String::as_str).unwrap_or("help");
    if command=="history" || command=="workspace-history" {
        if args.len()!=3{return Err("Use: pcdiag history START_RFC3339 END_RFC3339 (at most two hours)".into());}
        println!("{}",if command=="workspace-history"{diagnostics_core::history::query_workspace(&Sources::load()?,&args[1],&args[2])?}else{diagnostics_core::history::query(&Sources::load()?,&args[1],&args[2])?});return Ok(0);
    }
    #[cfg(windows)]
    if command=="tray" {
        use diagnostics_core::desktop;
        match args.get(1).map(String::as_str) {
            None if args.len()==1=>desktop::launch("mini")?,
            Some("--mini"|"--full"|"--tray") if args.len()==2=>desktop::launch(args[1].trim_start_matches("--"))?,
            Some("startup") if args.len()==3=>match args[2].as_str(){
                "status"=>println!("{}",json!({"startup":desktop::startup_status()?})),
                "on"|"off"=>desktop::set_startup(args[2]=="on",&desktop::viewer_path()?)?,
                _=>return Err("Use: pcdiag tray startup on|off|status".into())
            },
            _=>return Err("Use: pcdiag tray [--mini|--full|--tray] | startup on|off|status".into())
        }return Ok(0);
    }
    if ["help","--help","-h"].contains(&command){
        println!("pcdiag history START_RFC3339 END_RFC3339  (read-only JSON, at most two hours)");
        println!("pcdiag tray [--mini|--full|--tray]\npcdiag tray startup on|off|status\nWindow X keeps recording in the tray. Tray Exit stops recording (UAC) before exiting.");
        println!("pcdiag config show\npcdiag config enable|disable MODULE\npcdiag config interval MODULE SECONDS\npcdiag coverage\nConfiguration changes restart a running recorder; existing logs are retained.");
        println!("pcdiag status [--json]\npcdiag watch [--json]\npcdiag logs\npcdiag export\npcdiag doctor [--json]\npcdiag evidence\npcdiag incidents\npcdiag install --legacy-activity-root PATH\npcdiag upgrade\npcdiag start | stop | restart | rollback\n\nThe GUI is optional. Control/install/upgrade commands require an Administrator terminal.\nExit codes: 0 success, 1 command failure, 2 stale/missing/error streams.");return Ok(0);
    }
    if command=="config"{
        let operation=args.get(1).map(String::as_str).unwrap_or("show");
        let extra=match operation{
            "show" if args.len()<=2=>vec!["-Operation".into(),"show".into()],
            "enable"|"disable" if args.len()==3 && args[2].chars().all(|c|c.is_ascii_alphanumeric())=>vec!["-Operation".into(),operation.into(),"-Module".into(),args[2].clone()],
            "interval" if args.len()==4 && args[2].chars().all(|c|c.is_ascii_alphanumeric()) && args[3].parse::<u32>().is_ok()=>vec!["-Operation".into(),operation.into(),"-Module".into(),args[2].clone(),"-Seconds".into(),args[3].clone()],
            _=>return Err("Use: pcdiag config show | enable/disable MODULE | interval MODULE SECONDS".into())
        };return management("config",&extra);
    }
    if command=="coverage"{if args.len()!=1{return Err("Unexpected argument".into());}println!("{}",serde_json::to_string_pretty(&json!({"coverage":read_json(machine_dir().join("coverage.json")),"eventChannels":read_json(machine_dir().join("event-channel-coverage.json")),"settings":read_json(machine_dir().join("collection-settings.json")),"dumpPolicy":read_json(machine_dir().join("dump-policy-backup.json")),"dumpPolicyObservation":read_json(machine_dir().join("crash-configuration.json"))})).unwrap());return Ok(0);}
    if ["start","stop","restart","rollback","upgrade"].contains(&command){if args.len()!=1{return Err("Unexpected argument".into());}return management(command,&[]);}
    if ["evidence","incidents"].contains(&command){
        if args.len()!=1{return Err("Unexpected argument".into());}
        let value=if command=="evidence"{json!({"evidence":latest_evidence("evidence-"),"storage":latest_evidence("storage-"),"crashConfiguration":read_json(machine_dir().join("crash-configuration.json"))})}else{
            let root=machine_dir().join("incidents");let mut paths=std::fs::read_dir(&root).map_err(|e|format!("{}: {e}",root.display()))?.filter_map(Result::ok).map(|e|e.path().join("manifest.json")).filter(|p|p.is_file()).collect::<Vec<_>>();paths.sort();json!(paths.iter().map(|p|json!({"path":p,"manifest":read_json(p.clone())})).collect::<Vec<_>>())
        };
        println!("{}",serde_json::to_string_pretty(&value).unwrap());return Ok(0);
    }
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
        let mut v=monitor.unified_snapshot();
        if command=="export"{println!("{}",export_snapshot(&v)?.display());return Ok(0);}
        let extended_ok=v["coordinator"]["runtime"]["workers"].as_array().is_some_and(|a|a.iter().any(|w|w["name"]=="extended"&&w["state"]=="recording"&&w["errorCount"].as_u64()==Some(0)));
        if command=="doctor"{v["coverage"]=read_json(machine_dir().join("coverage.json"));}
        let maintenance_ok=v["coordinator"]["runtime"]["workers"].as_array().is_some_and(|a|a.iter().filter(|w|w["name"]=="maintenance").all(|w|w["state"]=="recording"&&w["errorCount"].as_u64()==Some(0)));
        let ok=healthy(&v) && (command!="doctor" || (evidence_healthy(&v) && extended_ok && maintenance_ok && diagnostics_core::recorder_status::summary(&v["coordinator"])["state"]=="recording"));
        if args.iter().any(|a|a=="--json"){println!("{}",serde_json::to_string(&v).unwrap());}else{display(&v);if command=="doctor"{println!("Unified configuration: {}\nCoordinator heartbeat age: {}s\nWorkers: {}\nCoverage (partial/unavailable is not healthy hardware): {}",v["coordinator"]["configured"],v["coordinator"]["heartbeatAgeSeconds"],v["coordinator"]["runtime"]["workers"],v["coverage"]["modules"]);}}
        if command!="watch"{return Ok(if ok{0}else{2});}
        std::thread::sleep(Duration::from_secs(2));
    }
}
fn main()->ExitCode{match run(){Ok(code)=>ExitCode::from(code as u8),Err(e)=>{eprintln!("pcdiag: {e}");ExitCode::FAILURE}}}
#[cfg(test)]mod tests{use super::*;#[test]fn status_requires_all_streams(){let mut s=json!({"streams":{"cpu":{"state":"recording"},"board":{"state":"recording"},"activity":{"state":"stale"}}});assert!(!healthy(&s));s["streams"]["activity"]["state"]=json!("recording");assert!(healthy(&s));assert!(!healthy(&json!({})));}}
#[cfg(test)]mod evidence_tests{use super::*;#[test]fn missing_or_failing_evidence_is_not_healthy(){assert!(!evidence_healthy(&json!({})));let mut v=json!({"coordinator":{"runtime":{"workers":[{"name":"evidence","state":"recording","errorCount":0}]}}});assert!(evidence_healthy(&v));v["coordinator"]["runtime"]["workers"][0]["errorCount"]=json!(1);assert!(!evidence_healthy(&v));}}
#[cfg(test)]mod opt_out_tests{use super::*;#[test]fn only_explicit_disabled_workers_are_exempt(){let mut v=json!({"streams":{"cpu":{"state":"stale"},"board":{"state":"recording"},"activity":{"state":"recording"}},"coordinator":{"runtime":{"workers":[{"name":"cpu","state":"disabled","enabled":false}]}}});assert!(healthy(&v));v["coordinator"]["runtime"]["workers"][0]["enabled"]=json!(true);assert!(!healthy(&v));v["coordinator"]["runtime"]["workers"][0]["enabled"]=json!(false);v["coordinator"]["runtime"]["workers"][0]["state"]=json!("failed");assert!(!healthy(&v));}}
