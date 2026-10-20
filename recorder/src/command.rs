//! Read-only helpers enter a kill-on-close job atomically at process creation.
//! Timeout/output errors and worker death cannot orphan helpers (Windows 10+).
#[cfg(windows)]
mod win {
    use std::{
        io,
        mem::size_of,
        os::windows::ffi::OsStrExt,
        path::Path,
        ptr::{null, null_mut},
        time::{Duration, Instant},
    };
    use windows_sys::Win32::{
        Foundation::*,
        Globalization::*,
        Security::SECURITY_ATTRIBUTES,
        Storage::FileSystem::*,
        System::{JobObjects::*, Pipes::*, Threading::*},
    };
    struct Handle(HANDLE);
    impl Handle {
        fn checked(value: HANDLE) -> io::Result<Self> {
            if value.is_null() || value == INVALID_HANDLE_VALUE {
                Err(io::Error::last_os_error())
            } else {
                Ok(Self(value))
            }
        }
    }
    impl Drop for Handle {
        fn drop(&mut self) {
            unsafe {
                CloseHandle(self.0);
            }
        }
    }
    fn check(ok: i32) -> io::Result<()> {
        if ok == 0 {
            Err(io::Error::last_os_error())
        } else {
            Ok(())
        }
    }
    fn pipe() -> io::Result<(Handle, Handle)> {
        let security = SECURITY_ATTRIBUTES {
            nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
            lpSecurityDescriptor: null_mut(),
            bInheritHandle: 1,
        };
        let (mut read, mut write) = (null_mut(), null_mut());
        unsafe {
            check(CreatePipe(&mut read, &mut write, &security, 0))?;
            let pair = (Handle::checked(read)?, Handle::checked(write)?);
            check(SetHandleInformation(pair.0 .0, HANDLE_FLAG_INHERIT, 0))?;
            Ok(pair)
        }
    }
    fn drain(pipe: &Handle, output: &mut Vec<u8>, limit: usize) -> io::Result<()> {
        let mut available = 0;
        unsafe {
            if PeekNamedPipe(
                pipe.0,
                null_mut(),
                0,
                null_mut(),
                &mut available,
                null_mut(),
            ) == 0
            {
                let e = io::Error::last_os_error();
                return if e.raw_os_error() == Some(ERROR_BROKEN_PIPE as i32) {
                    Ok(())
                } else {
                    Err(e)
                };
            }
            // One bounded batch per pipe per poll: a noisy stdout cannot starve
            // stderr, timeout checks or process exit observation.
            let mut buffer = [0u8; 8192];
            if available > 0 {
                let mut read = 0;
                check(ReadFile(
                    pipe.0,
                    buffer.as_mut_ptr(),
                    available.min(buffer.len() as u32),
                    &mut read,
                    null_mut(),
                ))?;
                if output.len() + read as usize > limit {
                    return Err(io::Error::other("Diagnostic reader output exceeds limit"));
                }
                output.extend_from_slice(&buffer[..read as usize]);
            }
        }
        Ok(())
    }
    pub fn decode(bytes: &[u8], oem: bool) -> io::Result<String> {
        if bytes.is_empty() {
            return Ok(String::new());
        }
        unsafe {
            let mut codepage = CP_ACP;
            if oem {
                // Match CurrentCulture.TextInfo.OEMCodePage used by PowerShell.
                let mut locale = [0u16; 16];
                let count = GetLocaleInfoEx(
                    null(),
                    LOCALE_IDEFAULTCODEPAGE,
                    locale.as_mut_ptr(),
                    locale.len() as i32,
                );
                if count <= 1 {
                    return Err(io::Error::last_os_error());
                }
                codepage = String::from_utf16(&locale[..count as usize - 1])
                    .map_err(io::Error::other)?
                    .parse()
                    .map_err(io::Error::other)?;
            }
            let length = MultiByteToWideChar(
                codepage,
                0,
                bytes.as_ptr(),
                bytes.len() as i32,
                null_mut(),
                0,
            );
            if length == 0 {
                return Err(io::Error::last_os_error());
            }
            let mut wide = vec![0u16; length as usize];
            if MultiByteToWideChar(
                codepage,
                0,
                bytes.as_ptr(),
                bytes.len() as i32,
                wide.as_mut_ptr(),
                length,
            ) != length
            {
                return Err(io::Error::last_os_error());
            }
            String::from_utf16(&wide).map_err(io::Error::other)
        }
    }
    pub fn run(exe: &Path, args: &str, timeout: Duration, oem: bool) -> Result<String, String> {
        run_inner(exe, args, timeout, oem).map_err(|e| e.to_string())
    }
    fn run_inner(exe: &Path, args: &str, timeout: Duration, oem: bool) -> io::Result<String> {
        let text = exe
            .to_str()
            .ok_or_else(|| io::Error::other("Executable path is not Unicode"))?;
        if !exe.is_absolute() || text.contains(['"', '\0']) || args.contains('\0') {
            return Err(io::Error::other(
                "Invalid diagnostic executable or arguments",
            ));
        }
        let application: Vec<u16> = exe.as_os_str().encode_wide().chain(Some(0)).collect();
        let mut command: Vec<u16> = format!("\"{text}\" {args}")
            .encode_utf16()
            .chain(Some(0))
            .collect();
        let ((stdout, stdout_write), (stderr, stderr_write), (stdin_read, stdin_write)) =
            (pipe()?, pipe()?, pipe()?);
        // stdin read must be inherited; its write end is closed to deliver EOF.
        unsafe {
            check(SetHandleInformation(
                stdin_read.0,
                HANDLE_FLAG_INHERIT,
                HANDLE_FLAG_INHERIT,
            ))?;
        }
        drop(stdin_write);
        let job = unsafe { Handle::checked(CreateJobObjectW(null(), null()))? };
        let mut limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = unsafe { std::mem::zeroed() };
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        unsafe {
            check(SetInformationJobObject(
                job.0,
                JobObjectExtendedLimitInformation,
                &limits as *const _ as _,
                size_of_val(&limits) as u32,
            ))?;
        }
        let mut attribute_bytes = 0usize;
        unsafe {
            InitializeProcThreadAttributeList(null_mut(), 2, 0, &mut attribute_bytes);
        }
        let mut backing = vec![0usize; attribute_bytes.div_ceil(size_of::<usize>())];
        let attributes = backing.as_mut_ptr() as LPPROC_THREAD_ATTRIBUTE_LIST;
        unsafe {
            check(InitializeProcThreadAttributeList(
                attributes,
                2,
                0,
                &mut attribute_bytes,
            ))?;
        }
        struct Attributes(LPPROC_THREAD_ATTRIBUTE_LIST);
        impl Drop for Attributes {
            fn drop(&mut self) {
                unsafe {
                    DeleteProcThreadAttributeList(self.0);
                }
            }
        }
        let attributes = Attributes(attributes);
        let handles = [stdin_read.0, stdout_write.0, stderr_write.0];
        unsafe {
            check(UpdateProcThreadAttribute(
                attributes.0,
                0,
                PROC_THREAD_ATTRIBUTE_JOB_LIST as usize,
                &job.0 as *const _ as _,
                size_of::<HANDLE>(),
                null_mut(),
                null(),
            ))?;
            check(UpdateProcThreadAttribute(
                attributes.0,
                0,
                PROC_THREAD_ATTRIBUTE_HANDLE_LIST as usize,
                handles.as_ptr() as _,
                size_of_val(&handles),
                null_mut(),
                null(),
            ))?;
        }
        let mut startup: STARTUPINFOEXW = unsafe { std::mem::zeroed() };
        startup.StartupInfo.cb = size_of_val(&startup) as u32;
        startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
        startup.StartupInfo.hStdInput = stdin_read.0;
        startup.StartupInfo.hStdOutput = stdout_write.0;
        startup.StartupInfo.hStdError = stderr_write.0;
        startup.lpAttributeList = attributes.0;
        let mut info: PROCESS_INFORMATION = unsafe { std::mem::zeroed() };
        unsafe {
            check(CreateProcessW(
                application.as_ptr(),
                command.as_mut_ptr(),
                null(),
                null(),
                1,
                CREATE_NO_WINDOW | EXTENDED_STARTUPINFO_PRESENT,
                null(),
                null(),
                &startup.StartupInfo,
                &mut info,
            ))?;
        }
        let process = Handle::checked(info.hProcess)?;
        let thread = Handle::checked(info.hThread)?;
        drop(thread);
        drop(stdin_read);
        drop(stdout_write);
        drop(stderr_write);
        let started = Instant::now();
        let (mut out, mut err) = (Vec::new(), Vec::new());
        let status = loop {
            drain(&stdout, &mut out, 4 * 1024 * 1024)?;
            drain(&stderr, &mut err, 65536)?;
            if started.elapsed() >= timeout {
                return Err(io::Error::other("Diagnostic reader timed out"));
            }
            if unsafe { WaitForSingleObject(process.0, 0) } == WAIT_OBJECT_0 {
                // Drain the finite remainder. Descendants are terminated by the
                // job even if they inherited a pipe and did not close it.
                loop {
                    let before = out.len() + err.len();
                    drain(&stdout, &mut out, 4 * 1024 * 1024)?;
                    drain(&stderr, &mut err, 65536)?;
                    if out.len() + err.len() == before {
                        break;
                    }
                    if started.elapsed() >= timeout {
                        return Err(io::Error::other(
                            "Diagnostic reader output did not complete",
                        ));
                    }
                }
                let mut code = 0;
                unsafe {
                    check(GetExitCodeProcess(process.0, &mut code))?;
                }
                break code;
            }
            std::thread::sleep(Duration::from_millis(5));
        };
        if status != 0 {
            return Err(io::Error::other(format!(
                "Diagnostic reader exit {status}: {} {}",
                decode(&err, oem)?,
                decode(&out, oem)?
            )));
        }
        decode(&out, oem)
    }
    #[cfg(test)]
    mod tests {
        use super::*;
        #[test]
        fn helper_output_failure_timeout_and_repeated_handles() {
            let exe = std::path::PathBuf::from(std::env::var_os("WINDIR").unwrap())
                .join("System32/cmd.exe");
            for _ in 0..10 {
                assert!(
                    run(&exe, "/d /c echo synthetic", Duration::from_secs(5), false)
                        .unwrap()
                        .contains("synthetic")
                );
            }
            assert!(run(&exe, "/d /c exit 7", Duration::from_secs(5), false)
                .unwrap_err()
                .contains("exit 7"));
            let error = run(
                &exe,
                "/d /c ping -n 10 127.0.0.1",
                Duration::from_millis(100),
                false,
            )
            .unwrap_err();
            assert!(error.contains("timed out"));
        }
    }
}
#[cfg(windows)]
pub use win::run;
