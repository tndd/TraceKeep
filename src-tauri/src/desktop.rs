//! Windows viewer integration. No sensor access or collector deployment.
use std::{path::{Path,PathBuf}, ptr::{null,null_mut}, process::Command, os::windows::process::CommandExt};
use windows_sys::Win32::{Foundation::*, System::{Threading::*, Registry::*}, UI::{Shell::*, WindowsAndMessaging::SW_HIDE}};
use windows_sys::Win32::System::Com::{CoInitializeEx,CoUninitialize,COINIT_APARTMENTTHREADED,COINIT_DISABLE_OLE1DDE};

fn wide(value:&str)->Vec<u16>{value.encode_utf16().chain(Some(0)).collect()}
struct Handle(HANDLE);
// Handles are owned, closed once, and only used with thread-safe kernel APIs.
unsafe impl Send for Handle {}
impl Drop for Handle {fn drop(&mut self){unsafe{CloseHandle(self.0);}}}
struct ComApartment(bool);
impl Drop for ComApartment {fn drop(&mut self){if self.0{unsafe{CoUninitialize();}}}}
pub struct Instance { _mutex:Handle, mini:Handle, full:Handle }
impl Instance {
    pub fn acquire(view:&str)->Result<Option<Self>,String>{unsafe{
        let mini=CreateEventW(null(),0,0,wide("Local\\PCDiagnostics.Viewer.Mini.v1").as_ptr());
        if mini.is_null(){return Err(std::io::Error::last_os_error().to_string());}let mini=Handle(mini);
        let full=CreateEventW(null(),0,0,wide("Local\\PCDiagnostics.Viewer.Full.v1").as_ptr());
        if full.is_null(){return Err(std::io::Error::last_os_error().to_string());}let full=Handle(full);
        let mutex=CreateMutexW(null(),0,wide("Local\\PCDiagnostics.Viewer.Instance.v1").as_ptr());
        let exists=GetLastError()==ERROR_ALREADY_EXISTS;
        if mutex.is_null(){return Err(std::io::Error::last_os_error().to_string());}let mutex=Handle(mutex);
        if exists {if view!="tray"{SetEvent(if view=="full"{full.0}else{mini.0});}return Ok(None);}
        Ok(Some(Self{_mutex:mutex,mini,full}))
    }}
    pub fn requested_view(&self)->Option<&'static str>{unsafe{
        if WaitForSingleObject(self.full.0,0)==WAIT_OBJECT_0 {Some("full")}
        else if WaitForSingleObject(self.mini.0,0)==WAIT_OBJECT_0 {Some("mini")}else{None}
    }}
}

pub fn validate_action(action:&str)->Result<&str,String>{
    if matches!(action,"start"|"stop"){Ok(action)}else{Err("Only start and stop are allowed from the viewer.".into())}
}
// A newly launched tray resumes an explicitly stopped installation. Unknown,
// stale or unconfigured states never trigger automatic recorder operations.
pub fn should_start_on_launch(coordinator:&serde_json::Value)->bool {
    crate::recorder_status::summary(coordinator)["state"]=="stopped"
}
pub fn installed_cli()->Result<PathBuf,String>{
    let root=std::env::var_os("ProgramFiles").ok_or("ProgramFiles is unavailable")?;
    let path=PathBuf::from(root).join("PCDiagnostics/pcdiag.exe");
    if !path.is_file(){return Err("統合記録プログラムが見つかりません。CUIのインストールを確認してください。".into());}Ok(path)
}
pub fn control_recorder(action:&str)->Result<(),String>{
    let action=validate_action(action)?;
    elevated_cli(action)
}
pub fn configure_module(module:&str,enabled:bool)->Result<(),String>{
    const ALLOWED:&[&str]=&["cpu","board","activity","events","storage","nvme","nvmeErrors","crashConfiguration","incidents","performance","gpuDetails","processes","inventory","reliability","power","dumpArchive","werArchive","diskSpace","automaticDump"];
    if !ALLOWED.contains(&module){return Err("Unknown module".into());}
    elevated_cli(&format!("config {} {}",if enabled{"enable"}else{"disable"},module))
}
fn elevated_cli(args:&str)->Result<(),String>{
    let executable=wide(&installed_cli()?.to_string_lossy());
    let arguments=wide(args);let verb=wide("runas");
    // Elevate only the installed CLI, never a script beside a portable viewer.
    unsafe{
        let com_result=CoInitializeEx(null(),(COINIT_APARTMENTTHREADED|COINIT_DISABLE_OLE1DDE) as u32);
        // A pre-existing apartment is valid too; only uninitialize one we acquired.
        if com_result<0 && com_result!=RPC_E_CHANGED_MODE{return Err(format!("Windows の操作準備に失敗しました ({com_result})"));}
        let _apartment=ComApartment(com_result>=0);
        let mut info:SHELLEXECUTEINFOW=std::mem::zeroed();
        info.cbSize=std::mem::size_of::<SHELLEXECUTEINFOW>() as u32;
        info.fMask=SEE_MASK_NOCLOSEPROCESS|SEE_MASK_NOASYNC|SEE_MASK_FLAG_NO_UI;
        info.lpVerb=verb.as_ptr();info.lpFile=executable.as_ptr();info.lpParameters=arguments.as_ptr();info.nShow=SW_HIDE;
        if ShellExecuteExW(&mut info)==0 {
            let error=GetLastError();return Err(if error==ERROR_CANCELLED{"管理者権限の確認がキャンセルされました。トレイは残ります。".into()}else{format!("記録操作を開始できませんでした (Windows {error})")});
        }
        if info.hProcess.is_null(){return Err("記録操作のプロセスを確認できませんでした。".into());}
        let process=Handle(info.hProcess);
        if WaitForSingleObject(process.0,INFINITE)!=WAIT_OBJECT_0{return Err("記録操作の完了を確認できませんでした。".into());}
        let mut exit_code=1;
        if GetExitCodeProcess(process.0,&mut exit_code)==0 || exit_code!=0{return Err(format!("記録操作に失敗しました (終了コード {exit_code})。pcdiag doctor で確認してください。"));}
    }
    Ok(())
}

const RUN_KEY:&str="Software\\Microsoft\\Windows\\CurrentVersion\\Run";
const RUN_VALUE:&str="TraceKeep";
pub fn startup_command(path:&Path)->Result<String,String>{
    let path=path.to_str().ok_or("Executable path is not Unicode")?;
    if path.contains('"')||path.contains('\n')||path.contains('\r'){return Err("Invalid executable path".into());}
    Ok(format!("\"{path}\" --tray"))
}
pub fn startup_status()->Result<Option<String>,String>{unsafe{
    let mut bytes=0;
    let key=wide(RUN_KEY);let name=wide(RUN_VALUE);
    let result=RegGetValueW(HKEY_CURRENT_USER,key.as_ptr(),name.as_ptr(),RRF_RT_REG_SZ,null_mut(),null_mut(),&mut bytes);
    if result==ERROR_FILE_NOT_FOUND{return Ok(None);}
    if result!=ERROR_SUCCESS{return Err(format!("Startup registry read failed: {result}"));}
    if bytes>32768{return Err("Unexpected startup entry size".into());}
    let mut buffer=vec![0u16;(bytes as usize+1)/2];
    let result=RegGetValueW(HKEY_CURRENT_USER,key.as_ptr(),name.as_ptr(),RRF_RT_REG_SZ,null_mut(),buffer.as_mut_ptr().cast(),&mut bytes);
    if result!=ERROR_SUCCESS{return Err(format!("Startup registry read failed: {result}"));}
    let end=buffer.iter().position(|c|*c==0).unwrap_or(buffer.len());Ok(Some(String::from_utf16_lossy(&buffer[..end])))
}}
pub fn set_startup(enabled:bool,executable:&Path)->Result<(),String>{
    let command=startup_command(executable)?;
    if enabled&&!executable.is_file(){return Err("Viewer executable does not exist".into());}
    unsafe{
        let mut key=null_mut();
        let result=RegCreateKeyExW(HKEY_CURRENT_USER,wide(RUN_KEY).as_ptr(),0,null(),0,KEY_SET_VALUE,null(),&mut key,null_mut());
        if result!=ERROR_SUCCESS{return Err(format!("Startup registry open failed: {result}"));}
        let value=wide(&command);
        let result=if enabled {RegSetValueExW(key,wide(RUN_VALUE).as_ptr(),0,REG_SZ,value.as_ptr().cast(),(value.len()*2) as u32)}else{RegDeleteValueW(key,wide(RUN_VALUE).as_ptr())};
        // Remove only our old registration, avoiding two launches at sign-in.
        if result==ERROR_SUCCESS || (result==ERROR_FILE_NOT_FOUND&&!enabled) {
            RegDeleteValueW(key,wide("PCDiagnosticsTray").as_ptr());
        }
        RegCloseKey(key);
        if result!=ERROR_SUCCESS&&!(result==ERROR_FILE_NOT_FOUND&&!enabled){return Err(format!("Startup update failed: {result}"));}
    }Ok(())
}
pub fn viewer_path()->Result<PathBuf,String>{
    let branded=crate::app_dir().join("viewer/TraceKeep.exe");
    if branded.is_file(){return Ok(branded);}
    let local=crate::app_dir().join("viewer/pc-diagnostics.exe");
    if local.is_file(){return Ok(local);}
    let path=std::env::current_exe().map_err(|e|e.to_string())?.with_file_name("pc-diagnostics.exe");
    if path.is_file(){Ok(path)}else{Err("Optional viewer is not installed.".into())}
}

pub fn initial_view(args:impl IntoIterator<Item=String>)->&'static str {
    let args:Vec<String>=args.into_iter().collect();
    if args.iter().any(|a|a=="--tray"){"tray"}
    else if args.iter().any(|a|a=="--full"){"full"}
    else if args.iter().any(|a|a=="--mini"){"mini"}
    else {"tray"}
}
pub fn launch(view:&str)->Result<(),String>{
    if !matches!(view,"tray"|"mini"|"full"){return Err("Unknown viewer mode".into());}
    Command::new(viewer_path()?).arg(format!("--{view}")).creation_flags(CREATE_NO_WINDOW).spawn().map_err(|e|e.to_string())?;Ok(())
}

#[cfg(test)]mod tests{use super::*;
    #[test]fn ordinary_and_login_launches_do_not_open_a_window(){
        for args in [vec![],vec!["--tray"],vec!["--unknown"],vec!["--mini","--tray"]]{assert_eq!(initial_view(args.into_iter().map(String::from)),"tray");}
        assert_eq!(initial_view(["--mini".to_owned()]),"mini");
        assert_eq!(initial_view(["--full".to_owned()]),"full");
    }
    #[test]fn commands_are_not_arbitrary(){assert!(validate_action("stop").is_ok());for a in ["upgrade","stop; whoami","restart",""]{assert!(validate_action(a).is_err());}}
    #[test]fn relaunch_only_resumes_a_confirmed_stopped_installation(){
        use serde_json::json;
        assert!(should_start_on_launch(&json!({"configured":true,"stopRequested":true,"heartbeatAgeSeconds":30})));
        for c in [json!({}),json!({"configured":false,"stopRequested":true}),json!({"configured":true,"heartbeatAgeSeconds":30}),json!({"configured":true,"stopRequested":true,"heartbeatAgeSeconds":1})]{assert!(!should_start_on_launch(&c));}
    }
    #[test]fn startup_quotes_paths_and_launches_only_the_viewer(){let v=startup_command(Path::new("C:\\Apps With Space\\viewer.exe")).unwrap();assert_eq!(v,"\"C:\\Apps With Space\\viewer.exe\" --tray");assert!(startup_command(Path::new("bad\"path")).is_err());}
}
