//! Read-only temperature presentation. No hardware access, health diagnosis or controls.
use crate::{LogReader, recorder_status, row_time};
use serde_json::Value;
use windows_sys::Win32::{Foundation::SIZE, Graphics::Gdi::*};

#[derive(Debug, PartialEq)]
pub struct Display { pub text: String, pub tooltip: String, pub color: [u8;3] }

pub fn display(coordinator: &Value, reader: &LogReader, now: i64) -> Display {
    let summary=recorder_status::summary(coordinator);
    let state=summary["state"].as_str().unwrap_or("unknown");
    let label=summary["label"].as_str().unwrap_or("未確認");
    let cpu=coordinator["runtime"]["workers"].as_array().and_then(|ws|ws.iter().find(|w|w["name"]=="cpu"));
    let stopped=matches!(state,"stopped"|"stopping");
    let disabled=cpu.is_some_and(|w|w["enabled"]==false);
    let valid_worker=cpu.is_some_and(|w|w["enabled"]!=false&&w["state"]=="recording"&&w["errorCount"].as_u64()==Some(0));
    let temperature=reader.rows.back().filter(|r|row_time(r).is_some_and(|t|(0..=10_000).contains(&(now-t))))
        .and_then(|r|r["sensors"].as_array()).and_then(|s|s.iter().find(|s|s["id"]=="/amdcpu/0/temperature/2"&&s["available"]!=false))
        .and_then(|s|s["value"].as_f64()).filter(|t|t.is_finite()&&(0.0..=150.0).contains(t));
    let value=if matches!(state,"recording"|"attention")&&valid_worker&&reader.error.is_none(){temperature}else{None};
    let text=if stopped {"Ⅱ".into()}else{value.map(|t|format!("{:.0}°",t)).unwrap_or_else(||"—".into())};
    let detail=if stopped {"CPU温度表示は停止中".into()}else if disabled {"CPUは収集対象外".into()}else{value.map(|t|format!("CPU {t:.1} °C")).unwrap_or_else(||"CPUの最新温度を確認できません".into())};
    Display{text,tooltip:format!("PC Diagnostics · {detail}\n{label}"),color:if stopped||disabled{[156,169,182]}else if state=="recording"&&value.is_some(){[100,231,207]}else{[255,191,102]}}
}

/// GDI draws white text into an isolated bitmap, never onto a desktop/window.
/// A dark outline keeps the numeric icon legible on both light and dark taskbars.
pub fn render(display: &Display) -> Result<Vec<u8>,String> {
    const SIDE:usize=64;
    unsafe {
        let dc=CreateCompatibleDC(std::ptr::null_mut());
        if dc.is_null(){return Err("Cannot create icon DC".into());}
        let mut info:BITMAPINFO=std::mem::zeroed();
        info.bmiHeader.biSize=std::mem::size_of::<BITMAPINFOHEADER>() as u32;
        info.bmiHeader.biWidth=SIDE as i32;info.bmiHeader.biHeight=-(SIDE as i32);
        info.bmiHeader.biPlanes=1;info.bmiHeader.biBitCount=32;
        let mut bits=std::ptr::null_mut();
        let bitmap=CreateDIBSection(dc,&info,DIB_RGB_COLORS,&mut bits,std::ptr::null_mut(),0);
        if bitmap.is_null()||bits.is_null(){if !bitmap.is_null(){DeleteObject(bitmap);}DeleteDC(dc);return Err("Cannot allocate icon bitmap".into());}
        let font_name:Vec<u16>="Segoe UI\0".encode_utf16().collect();
        let height=if display.text.chars().count()>3{30}else{40};
        let font=CreateFontW(-height,0,0,0,700,0,0,0,DEFAULT_CHARSET as u32,OUT_DEFAULT_PRECIS as u32,CLIP_DEFAULT_PRECIS as u32,ANTIALIASED_QUALITY as u32,DEFAULT_PITCH as u32,font_name.as_ptr());
        if font.is_null(){DeleteObject(bitmap);DeleteDC(dc);return Err("Cannot create icon font".into());}
        let old_bitmap=SelectObject(dc,bitmap);let old_font=SelectObject(dc,font);
        std::ptr::write_bytes(bits,0,SIDE*SIDE*4);
        SetBkMode(dc,TRANSPARENT as i32);SetTextColor(dc,0x00ffffff);
        let text:Vec<u16>=display.text.encode_utf16().collect();let mut size:SIZE=std::mem::zeroed();
        let measured=GetTextExtentPoint32W(dc,text.as_ptr(),text.len() as i32,&mut size);
        let drawn=TextOutW(dc,((SIDE as i32-size.cx)/2).max(1),(SIDE as i32-size.cy)/2-2,text.as_ptr(),text.len() as i32);
        GdiFlush();
        let raw=std::slice::from_raw_parts(bits as *const u8,SIDE*SIDE*4);
        let mask:Vec<u8>=raw.chunks_exact(4).map(|p|p[0].max(p[1]).max(p[2])).collect();
        SelectObject(dc,old_font);SelectObject(dc,old_bitmap);DeleteObject(font);DeleteObject(bitmap);DeleteDC(dc);
        if measured==0||drawn==0{return Err("Cannot draw icon text".into());}
        let mut rgba=vec![0u8;SIDE*SIDE*4];
        for y in 0..SIDE {for x in 0..SIDE {
            let fill=mask[y*SIDE+x] as f32/255.;let mut outline=0u8;
            for ny in y.saturating_sub(2)..=(y+2).min(SIDE-1){for nx in x.saturating_sub(2)..=(x+2).min(SIDE-1){outline=outline.max(mask[ny*SIDE+nx]);}}
            let alpha=fill+(outline as f32/255.)*(1.-fill);
            let p=&mut rgba[(y*SIDE+x)*4..(y*SIDE+x+1)*4];
            if alpha>0. {for channel in &mut p[..3]{*channel=((245.*fill+20.*(alpha-fill))/alpha).round() as u8;}p[3]=(alpha*255.).round() as u8;}
            // This color indicates recording status, not a temperature alarm.
            if (26..38).contains(&x)&&(59..62).contains(&y){p.copy_from_slice(&[display.color[0],display.color[1],display.color[2],255]);}
        }}
        Ok(rgba)
    }
}

#[cfg(test)]mod tests {
    use super::*;use serde_json::json;
    fn fixture()->(Value,LogReader,i64){
        let now=chrono::Utc::now();let mut r=LogReader::latest_only(std::path::PathBuf::new(),"cpu-auto-");
        r.rows.push_back(json!({"time":now.to_rfc3339(),"sensors":[{"id":"/amdcpu/0/temperature/2","value":57.4}]}));
        let workers=["cpu","board","activity","evidence","extended"].iter().map(|n|json!({"name":n,"enabled":true,"state":"recording","errorCount":0})).collect::<Vec<_>>();
        (json!({"configured":true,"heartbeatAgeSeconds":1,"runtime":{"workers":workers}}),r,now.timestamp_millis())
    }
    #[test]fn fresh_stale_and_stop_are_distinct(){let(mut c,r,n)=fixture();assert_eq!(display(&c,&r,n).text,"57°");assert_eq!(display(&c,&r,n+10001).text,"—");assert_eq!(display(&c,&r,n-1).text,"—");c["stopRequested"]=json!(true);assert_eq!(display(&c,&r,n).text,"Ⅱ");}
    #[test]fn missing_disabled_and_failed_never_show_last_temperature(){let(mut c,mut r,n)=fixture();c["runtime"]["workers"][0]["enabled"]=json!(false);assert_eq!(display(&c,&r,n).text,"—");c["runtime"]["workers"][0]["enabled"]=json!(true);r.error=Some("read failed".into());assert_eq!(display(&c,&r,n).text,"—");r.error=None;r.rows.clear();assert_eq!(display(&c,&r,n).text,"—");}
    #[test]fn three_digits_and_rendering(){let(c,mut r,n)=fixture();r.rows[0]["sensors"][0]["value"]=json!(100.0);let d=display(&c,&r,n);assert_eq!(d.text,"100°");for text in ["57°","100°","—","Ⅱ"]{let pixels=render(&Display{text:text.into(),tooltip:String::new(),color:[100,231,207]}).unwrap();assert_eq!(pixels.len(),64*64*4);assert!(pixels[..58*64*4].chunks_exact(4).filter(|p|p[3]>0).count()>100);assert!(pixels.chunks_exact(4).any(|p|p[3]==0));}}
}
