#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
use diagnostics_core::{Monitor,Sources,export_snapshot};
use std::sync::{Arc,Mutex};
use serde_json::Value;
type Shared = Arc<Mutex<Monitor>>;

#[tauri::command]
async fn get_snapshot(state: tauri::State<'_,Shared>) -> Result<Value,String> {
    let state=state.inner().clone();
    tauri::async_runtime::spawn_blocking(move || state.lock().map_err(|e|e.to_string()).map(|mut m|m.snapshot())).await.map_err(|e|e.to_string())?
}
#[tauri::command]
async fn save_snapshot(state: tauri::State<'_,Shared>) -> Result<String,String> {
    let state=state.inner().clone();
    tauri::async_runtime::spawn_blocking(move || {
        let snapshot=state.lock().map_err(|e|e.to_string())?.snapshot();
        export_snapshot(&snapshot).map(|p|p.to_string_lossy().into_owned())
    }).await.map_err(|e|e.to_string())?
}
#[tauri::command]
fn set_sources(sensor_root:String,activity_root:String,state:tauri::State<'_,Shared>) -> Result<(),String> {
    let sources=Sources{sensor_root:sensor_root.into(),activity_root:activity_root.into()};
    sources.save()?;
    *state.lock().map_err(|e|e.to_string())?=Monitor::new(sources);
    Ok(())
}
fn main() {
    // Closing the window exits only the viewer. Collectors run independently.
    let sources=Sources::load().unwrap_or_default();
    tauri::Builder::default().manage(Arc::new(Mutex::new(Monitor::new(sources))))
        .invoke_handler(tauri::generate_handler![get_snapshot,save_snapshot,set_sources])
        .run(tauri::generate_context!()).expect("Unable to start PC Diagnostics");
}
