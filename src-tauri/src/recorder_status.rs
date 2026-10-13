//! Shared CUI/tray interpretation. Describes recording, never hardware health.
use serde_json::{json, Value};
use crate::machine_dir;

pub fn read_coordinator() -> Value {
    let root=machine_dir();
    let runtime=std::fs::read(root.join("runtime.json"))
        .map_err(|e|e.to_string()).and_then(|bytes|serde_json::from_slice::<Value>(&bytes).map_err(|e|e.to_string()))
        .unwrap_or_else(|e|json!({"error":e}));
    let age=runtime["time"].as_str().and_then(|t|chrono::DateTime::parse_from_rfc3339(t).ok())
        .map(|t|(chrono::Utc::now()-t.with_timezone(&chrono::Utc)).num_seconds());
    json!({"configured":root.join("sources.json").is_file(),"stopRequested":root.join("STOP-ALL").is_file(),"heartbeatAgeSeconds":age,"runtime":runtime})
}
pub fn summary(c:&Value) -> Value {
    let fresh=c["heartbeatAgeSeconds"].as_i64().is_some_and(|age|(0..=10).contains(&age));
    let workers=c["runtime"]["workers"].as_array();
    let running=workers.map(|a|a.iter().filter(|w|w["state"]=="recording"&&w["enabled"]!=false&&w["errorCount"].as_u64()==Some(0)).count()).unwrap_or(0);
    let enabled=workers.map(|a|a.iter().filter(|w|w["enabled"]!=false).count()).unwrap_or(0);
    let complete=["cpu","board","activity","evidence","extended"].iter().all(|name|workers.is_some_and(|a|a.iter().any(|w|w["name"]==*name && ((w["enabled"]==false&&w["state"]=="disabled")||(w["state"]=="recording"&&w["errorCount"].as_u64()==Some(0))))));
    let (state,label)=if c["configured"]!=true {("unconfigured","記録が未設定です")}
        else if c["stopRequested"]==true {if fresh {("stopping","記録を停止しています")}else{("stopped","記録は停止中です")}}
        else if !fresh {("unknown","記録の更新を確認できません")}
        else if complete {("recording","記録中")}
        else {("attention","一部の記録を確認してください")};
    json!({"state":state,"label":label,"runningWorkers":running,"enabledWorkers":enabled,"heartbeatAgeSeconds":c["heartbeatAgeSeconds"],"time":c["runtime"]["time"]})
}

#[cfg(test)] mod tests {
    use super::*;
    fn healthy()->Value {
        let workers=["cpu","board","activity","evidence","extended"].iter().map(|n|json!({"name":n,"enabled":true,"state":"recording","errorCount":0})).collect::<Vec<_>>();
        json!({"configured":true,"heartbeatAgeSeconds":1,"runtime":{"workers":workers}})
    }
    #[test] fn stale_and_missing_do_not_show_green(){let mut c=healthy();assert_eq!(summary(&c)["state"],"recording");c["heartbeatAgeSeconds"]=json!(11);assert_eq!(summary(&c)["state"],"unknown");c["heartbeatAgeSeconds"]=json!(-2);assert_eq!(summary(&c)["state"],"unknown");assert_ne!(summary(&json!({}))["state"],"recording");}
    #[test] fn failure_and_opt_out_are_different(){let mut c=healthy();c["runtime"]["workers"][0]["errorCount"]=json!(1);assert_eq!(summary(&c)["state"],"attention");c["runtime"]["workers"][0]["enabled"]=json!(false);assert_eq!(summary(&c)["state"],"attention");c["runtime"]["workers"][0]["state"]=json!("disabled");assert_eq!(summary(&c)["state"],"recording");}
    #[test] fn explicit_stop_is_not_a_recording_failure(){let mut c=healthy();c["stopRequested"]=json!(true);assert_eq!(summary(&c)["state"],"stopping");c["heartbeatAgeSeconds"]=json!(30);assert_eq!(summary(&c)["state"],"stopped");}
}
