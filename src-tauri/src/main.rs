#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
use diagnostics_core::{Monitor,Sources,export_snapshot,recorder_status,desktop,tray_temperature,LogReader};
use std::sync::{Arc,Mutex,atomic::{AtomicBool,Ordering}};
use serde_json::{json,Value};
use tauri::{Manager,menu::{Menu,MenuItem,CheckMenuItem},tray::{TrayIconBuilder,TrayIconEvent,MouseButton,MouseButtonState}};
type Shared=Arc<Mutex<Monitor>>;
static VIEW_LOCK:Mutex<()>=Mutex::new(());
static HISTORY_BUSY:AtomicBool=AtomicBool::new(false);
// Local UI health marker for diagnosing blank or failed WebView loads. No log content.
#[tauri::command]
fn report_workspace_state(ready:bool,message:String)->Result<(),String>{
    let root=diagnostics_core::app_dir();std::fs::create_dir_all(&root).map_err(|e|e.to_string())?;
    let value=json!({"ready":ready,"message":message.chars().take(500).collect::<String>(),"pid":std::process::id(),"time":chrono::Utc::now().to_rfc3339()});
    std::fs::write(root.join("workspace-state.json"),value.to_string()).map_err(|e|e.to_string())
}
#[tauri::command]
async fn query_history(start:String,end:String)->Result<Value,String>{
    if HISTORY_BUSY.swap(true,Ordering::SeqCst){return Err("記録を読み込み中です。".into());}
    let result=tauri::async_runtime::spawn_blocking(move||diagnostics_core::history::query(&Sources::load()?,&start,&end)).await.map_err(|e|e.to_string()).and_then(|v|v);
    HISTORY_BUSY.store(false,Ordering::SeqCst);result
}
#[tauri::command]
fn export_history_view(value:Value)->Result<String,String>{
    if value.to_string().len()>64*1024*1024{return Err("Export exceeds 64 MiB".into());}
    export_snapshot(&value).map(|p|p.to_string_lossy().into_owned())
}
#[derive(Default)]struct Control {busy:AtomicBool,message:Mutex<String>}

#[tauri::command]
async fn get_snapshot(state:tauri::State<'_,Shared>)->Result<Value,String>{
    let state=state.inner().clone();
    tauri::async_runtime::spawn_blocking(move||state.lock().map_err(|e|e.to_string()).map(|mut m|m.unified_snapshot())).await.map_err(|e|e.to_string())?
}
#[tauri::command]
async fn save_snapshot(state:tauri::State<'_,Shared>)->Result<String,String>{
    let state=state.inner().clone();
    tauri::async_runtime::spawn_blocking(move||{
        let snapshot=state.lock().map_err(|e|e.to_string())?.unified_snapshot();
        export_snapshot(&snapshot).map(|p|p.to_string_lossy().into_owned())
    }).await.map_err(|e|e.to_string())?
}
#[tauri::command]
fn set_sources(sensor_root:String,activity_root:String,state:tauri::State<'_,Shared>)->Result<(),String>{
    let sources=Sources{sensor_root:sensor_root.into(),activity_root:activity_root.into()};sources.save()?;
    *state.lock().map_err(|e|e.to_string())?=Monitor::new(sources);Ok(())
}
#[tauri::command]
fn viewer_state(state:tauri::State<'_,Control>)->Result<Value,String>{
    Ok(json!({"busy":state.busy.load(Ordering::SeqCst),"message":state.message.lock().map_err(|e|e.to_string())?.clone(),"startup":desktop::startup_status()?}))
}
#[tauri::command]
fn set_viewer_startup(enabled:bool)->Result<(),String>{desktop::set_startup(enabled,&std::env::current_exe().map_err(|e|e.to_string())?)}

#[tauri::command]
async fn configure_module(app:tauri::AppHandle,module:String,enabled:bool)->Result<(),String>{
    if app.state::<Control>().busy.swap(true,Ordering::SeqCst){return Err("記録操作は実行中です。".into());}
    let result=tauri::async_runtime::spawn_blocking(move||desktop::configure_module(&module,enabled)).await.map_err(|e|e.to_string()).and_then(|v|v);
    app.state::<Control>().busy.store(false,Ordering::SeqCst);result
}
// Only explicit user actions reach this function. UAC failure never exits the tray.
async fn control(app:tauri::AppHandle,action:String,exit_after:bool)->Result<(),String>{
    desktop::validate_action(&action)?;
    {let state=app.state::<Control>();if state.busy.swap(true,Ordering::SeqCst){return Err("記録操作は実行中です。".into());}
        if let Ok(mut message)=state.message.lock(){*message="管理者権限の確認と記録操作の完了を待っています…".into();};}
    let result=tauri::async_runtime::spawn_blocking(move||desktop::control_recorder(&action)).await.map_err(|e|e.to_string()).and_then(|v|v);
    {let state=app.state::<Control>();state.busy.store(false,Ordering::SeqCst);
        if let Ok(mut message)=state.message.lock(){*message=match &result{Ok(())=>"記録操作が完了しました。状態の更新を待っています。".into(),Err(e)=>e.clone()};};}
    if result.is_ok()&&exit_after {app.exit(0);}
    result
}
#[tauri::command]
async fn recorder_action(app:tauri::AppHandle,action:String)->Result<(),String>{control(app,action,false).await}

fn show_view(app:&tauri::AppHandle,view:&str)->Result<(),String>{
    let _opening=VIEW_LOCK.lock().map_err(|e|e.to_string())?;
    let (label,url,title,width,height)=match view {
        "mini"=>("mini","mini.html","TraceKeep · ミニモニター",300.,228.),
        "full"=>("main","dashboard/index.html","TraceKeep · 詳細",1320.,900.),
        _=>return Err("Unknown view".into())
    };
    if let Some(window)=app.get_webview_window(label){window.unminimize().map_err(|e|e.to_string())?;window.show().map_err(|e|e.to_string())?;window.set_focus().map_err(|e|e.to_string())?;return Ok(());}
    let mut builder=tauri::WebviewWindowBuilder::new(app,label,tauri::WebviewUrl::App(url.into()))
        .title(title).visible(false).inner_size(width,height).min_inner_size(if view=="mini"{280.}else{720.},if view=="mini"{228.}else{600.});
    if view=="mini" {
        builder=builder.decorations(false);
        if let Ok(Some(monitor))=app.primary_monitor(){let scale=monitor.scale_factor();let pos=monitor.position();let size=monitor.size();
            builder=builder.position((pos.x as f64+size.width as f64-width*scale-20.*scale)/scale,(pos.y as f64+size.height as f64-height*scale-60.*scale).max(pos.y as f64)/scale);}
    }
    let window=builder.build().map_err(|e|e.to_string())?;
    window.show().map_err(|e|e.to_string())?;window.set_focus().map_err(|e|e.to_string())?;Ok(())
}
#[tauri::command]
async fn open_view(app:tauri::AppHandle,view:String)->Result<(),String>{show_view(&app,&view)}
fn request_view(app:&tauri::AppHandle,view:&str){
    let app=app.clone();let view=view.to_owned();
    // WebView2 creation must not block a synchronous Windows event handler.
    tauri::async_runtime::spawn_blocking(move||{let _=show_view(&app,&view);});
}

fn tray_icon(display:&tray_temperature::Display)->tauri::image::Image<'static>{
    let pixels=tray_temperature::render(display).unwrap_or_else(|_|{
        // Visible failure marker if Windows cannot allocate a text bitmap.
        let mut p=vec![0;64*64*4];for y in 27..37 {for x in 10..54 {p[(y*64+x)*4..(y*64+x+1)*4].copy_from_slice(&[255,191,102,255]);}}p
    });tauri::image::Image::new_owned(pixels,64,64)
}
fn main(){
    let view=if std::env::args().any(|a|a=="--tray"){"tray"}else if std::env::args().any(|a|a=="--full"){"full"}else{"mini"};
    let Some(instance)=desktop::Instance::acquire(view).expect("Unable to register tray instance") else{return;};
    let sources=Sources::load().unwrap_or_default();
    let app=tauri::Builder::default().manage(Arc::new(Mutex::new(Monitor::new(sources)))).manage(Control::default())
        .invoke_handler(tauri::generate_handler![get_snapshot,save_snapshot,set_sources,viewer_state,set_viewer_startup,recorder_action,open_view,query_history,export_history_view,configure_module,report_workspace_state])
        .on_window_event(|window,event|{
            if let tauri::WindowEvent::CloseRequested{api,..}=event{
                api.prevent_close();
                // Preventing automatic app exit alone also cancels the last close on Windows.
                // Destroy this window explicitly; the tray's event loop remains alive.
                let _=window.destroy();
            }
        })
        .setup(move|app|{
            let mini=MenuItem::with_id(app,"mini","簡易モニター",true,None::<&str>)?;
            let full=MenuItem::with_id(app,"full","詳細モニター",true,None::<&str>)?;
            let quit=MenuItem::with_id(app,"quit","記録を停止して終了…",true,None::<&str>)?;
            let start=MenuItem::with_id(app,"start","記録を開始",true,None::<&str>)?;
            let stop=MenuItem::with_id(app,"stop","記録を停止…",true,None::<&str>)?;
            let startup=CheckMenuItem::with_id(app,"startup","ログオン時にトレイを表示",true,desktop::startup_status().ok().flatten().is_some(),None::<&str>)?;
            let menu=Menu::with_items(app,&[&mini,&full,&start,&stop,&startup,&quit])?;
            TrayIconBuilder::with_id("diagnostics").icon(tray_icon(&tray_temperature::Display{text:"—".into(),tooltip:String::new(),color:[110,128,147]})).tooltip("TraceKeep · 記録を確認中")
                .menu(&menu).show_menu_on_left_click(false)
                .on_menu_event(move|app,event|match event.id.as_ref(){
                    "mini"|"full"=>request_view(app,event.id.as_ref()),
                    "startup"=>{let result=desktop::startup_status().and_then(|current|std::env::current_exe().map_err(|e|e.to_string()).and_then(|exe|desktop::set_startup(current.is_none(),&exe)));let _=startup.set_checked(desktop::startup_status().ok().flatten().is_some());if let Err(e)=result{if let Ok(mut m)=app.state::<Control>().message.lock(){*m=e;}request_view(app,"mini");}},
                    "start"|"stop"=>{let action=event.id.as_ref().to_string();let app=app.clone();tauri::async_runtime::spawn(async move{if control(app.clone(),action,false).await.is_err(){let _=show_view(&app,"mini");}});},
                    "quit"=>{let app=app.clone();tauri::async_runtime::spawn(async move{if control(app.clone(),"stop".into(),true).await.is_err(){let _=show_view(&app,"mini");}});},_=>{}
                })
                .on_tray_icon_event(|tray,event|{if matches!(event,TrayIconEvent::Click{button:MouseButton::Left,button_state:MouseButtonState::Up,..}){request_view(tray.app_handle(),"mini");}}).build(app)?;
            let handle=app.handle().clone();
            std::thread::spawn(move||{
                let mut previous=String::new();let mut previous_tooltip=String::new();
                let mut root=std::path::PathBuf::new();let mut reader=LogReader::latest_only(root.clone(),"cpu-auto-");
                loop{
                if let Some(view)=instance.requested_view(){let _=show_view(&handle,view);}
                let coordinator=recorder_status::read_coordinator();
                let configured=Sources::load();
                if let Ok(sources)=&configured {if root!=sources.sensor_root {root=sources.sensor_root.clone();reader=LogReader::latest_only(root.clone(),"cpu-auto-");}reader.update();}
                else {reader.error=Some("Cannot read source configuration".into());}
                let display=tray_temperature::display(&coordinator,&reader,chrono::Utc::now().timestamp_millis());
                let key=format!("{}{:?}",display.text,display.color);
                if let Some(tray)=handle.tray_by_id("diagnostics"){
                    if key!=previous {if tray.set_icon(Some(tray_icon(&display))).is_ok(){previous=key;}}
                    if display.tooltip!=previous_tooltip {if tray.set_tooltip(Some(&display.tooltip)).is_ok(){previous_tooltip=display.tooltip;}}
                }
                let status=recorder_status::summary(&coordinator);let busy=handle.state::<Control>().busy.load(Ordering::SeqCst);
                let _=start.set_enabled(!busy&&status["state"]=="stopped");
                let _=stop.set_enabled(!busy&&coordinator["configured"]==true&&matches!(status["state"].as_str(),Some("recording"|"attention"|"unknown")));
                std::thread::sleep(std::time::Duration::from_secs(2));
            }});Ok(())
        }).build(tauri::generate_context!()).expect("Unable to start TraceKeep");
    // Closing the final window releases its WebView; the native tray stays alive.
    app.run(move|app,event|match event {
        // Display only after the event handlers are ready. A visible window during
        // setup can receive WM_CLOSE before the application's close handler exists.
        tauri::RunEvent::Ready if view!="tray"=>request_view(app,view),
        tauri::RunEvent::ExitRequested{code:None,api,..}=>api.prevent_exit(),
        _=>{}
    });
}
