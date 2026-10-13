#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
use diagnostics_core::{Monitor,Sources,export_snapshot,recorder_status,desktop};
use std::sync::{Arc,Mutex,atomic::{AtomicBool,Ordering}};
use serde_json::{json,Value};
use tauri::{Manager,menu::{Menu,MenuItem},tray::{TrayIconBuilder,TrayIconEvent,MouseButton,MouseButtonState}};
type Shared=Arc<Mutex<Monitor>>;
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
    let (label,url,title,width,height)=match view {
        "mini"=>("mini","mini.html","PC Diagnostics · ミニモニター",430.,620.),
        "full"=>("main","index.html","PC Diagnostics · 詳細",1320.,900.),
        _=>return Err("Unknown view".into())
    };
    if let Some(window)=app.get_webview_window(label){window.unminimize().map_err(|e|e.to_string())?;window.show().map_err(|e|e.to_string())?;window.set_focus().map_err(|e|e.to_string())?;return Ok(());}
    let mut builder=tauri::WebviewWindowBuilder::new(app,label,tauri::WebviewUrl::App(url.into()))
        .title(title).inner_size(width,height).min_inner_size(if view=="mini"{380.}else{720.},if view=="mini"{520.}else{600.});
    if view=="mini" {
        if let Ok(Some(monitor))=app.primary_monitor(){let scale=monitor.scale_factor();let pos=monitor.position();let size=monitor.size();
            builder=builder.position((pos.x as f64+size.width as f64-width*scale-20.*scale)/scale,(pos.y as f64+size.height as f64-height*scale-60.*scale).max(pos.y as f64)/scale);}
    }
    let window=builder.build().map_err(|e|e.to_string())?;
    window.show().map_err(|e|e.to_string())?;window.set_focus().map_err(|e|e.to_string())?;Ok(())
}
#[tauri::command]
async fn open_view(app:tauri::AppHandle,view:String)->Result<(),String>{show_view(&app,&view)}

fn tray_icon(state:&str)->tauri::image::Image<'static>{
    let color=match state{"recording"=>[78,224,181,255],"stopped"|"stopping"=>[147,157,175,255],_=>[255,188,92,255]};
    let mut pixels=vec![0u8;32*32*4];
    for y in 0..32usize {for x in 0..32usize {
        let ring=(4..28).contains(&x)&&(4..28).contains(&y)&&(x<6||x>=26||y<6||y>=26);
        let pulse=(8..12).contains(&x)&&(16..19).contains(&y)||(12..15).contains(&x)&&(10..19).contains(&y)||(15..18).contains(&x)&&(10..23).contains(&y)||(18..21).contains(&x)&&(15..23).contains(&y)||(21..25).contains(&x)&&(15..18).contains(&y);
        let dot=(x as i32-26).pow(2)+(y as i32-26).pow(2)<=20;
        let p=if dot{color}else if ring||pulse{[199,231,242,255]}else{[0,0,0,0]};pixels[(y*32+x)*4..(y*32+x)*4+4].copy_from_slice(&p);
    }}tauri::image::Image::new_owned(pixels,32,32)
}
fn main(){
    let view=if std::env::args().any(|a|a=="--tray"){"tray"}else if std::env::args().any(|a|a=="--full"){"full"}else{"mini"};
    let Some(instance)=desktop::Instance::acquire(view).expect("Unable to register tray instance") else{return;};
    let sources=Sources::load().unwrap_or_default();
    let app=tauri::Builder::default().manage(Arc::new(Mutex::new(Monitor::new(sources)))).manage(Control::default())
        .invoke_handler(tauri::generate_handler![get_snapshot,save_snapshot,set_sources,viewer_state,set_viewer_startup,recorder_action,open_view])
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
            let menu=Menu::with_items(app,&[&mini,&full,&quit])?;
            TrayIconBuilder::with_id("diagnostics").icon(tray_icon("unknown")).tooltip("PC Diagnostics · 記録を確認中")
                .menu(&menu).show_menu_on_left_click(false)
                .on_menu_event(|app,event|match event.id.as_ref(){
                    "mini"|"full"=>{let _=show_view(app,event.id.as_ref());},
                    "quit"=>{let app=app.clone();tauri::async_runtime::spawn(async move{if control(app.clone(),"stop".into(),true).await.is_err(){let _=show_view(&app,"mini");}});},_=>{}
                })
                .on_tray_icon_event(|tray,event|{if matches!(event,TrayIconEvent::Click{button:MouseButton::Left,button_state:MouseButtonState::Up,..}){let _=show_view(tray.app_handle(),"mini");}}).build(app)?;
            if view!="tray"{show_view(app.handle(),view).map_err(std::io::Error::other)?;}
            let handle=app.handle().clone();
            std::thread::spawn(move||{let mut previous=String::new();loop{
                if let Some(view)=instance.requested_view(){let app=handle.clone();let _=handle.run_on_main_thread(move||{let _=show_view(&app,view);});}
                let status=recorder_status::summary(&recorder_status::read_coordinator());let state=status["state"].as_str().unwrap_or("unknown");
                if state!=previous{previous=state.into();if let Some(tray)=handle.tray_by_id("diagnostics"){let _=tray.set_icon(Some(tray_icon(state)));let _=tray.set_tooltip(Some(format!("PC Diagnostics · {}",status["label"].as_str().unwrap_or("確認が必要"))));}}
                std::thread::sleep(std::time::Duration::from_secs(2));
            }});Ok(())
        }).build(tauri::generate_context!()).expect("Unable to start PC Diagnostics");
    // Closing the final window releases its WebView; the native tray stays alive.
    app.run(|_,event|{if let tauri::RunEvent::ExitRequested{code:None,api,..}=event{api.prevent_exit();}});
}
