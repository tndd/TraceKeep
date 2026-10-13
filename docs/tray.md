# Optional Windows tray

The recorder remains CUI-first. The Tauri process reads the same Rust snapshot and invokes only the installed `%ProgramFiles%\PCDiagnostics\pcdiag.exe start|stop` for explicit recording controls. It does not deploy collectors or poll hardware.

## User contract

- Left-click the tray: open the mini monitor. Right-click: mini monitor, detailed monitor, or **stop recording and exit**.
- Window X closes/releases that WebView and leaves the native tray and recording running.
- Explicit tray Exit requests `pcdiag stop` with Windows UAC. The icon disappears only after that command succeeds. Cancellation/failure leaves the icon and displays the error. A failed or cancelled stop is never reported as success.
- The mini monitor can start/stop recording without exiting the tray. Stop retains logs and disables the recorder boot task until Start is issued, including across reboots. Start waits for the existing CUI's fresh-sample verification.
- GUI crashes, Task Manager termination, Explorer notification-area overflow and sign-out are **not** explicit recorder stop commands. Recording remains independent in these cases so diagnostic evidence is not lost.
- Opening the viewer or enabling its login startup never starts a stopped recorder automatically. Reopen the mini monitor and press Start to resume after an explicit stop.
- Stop/start operate on the machine-wide recorder, affecting all logged-in users. The tray is a single instance per Windows session.

## Installation and CUI

Extract the Actions artifact and run `Install-Tray.ps1` as the ordinary user. It installs only the viewer to `%LOCALAPPDATA%\PCDiagnostics\viewer`; no administrative recorder upgrade or collection interruption is needed. Use `-Startup` to also register login startup, or the mini monitor checkbox afterwards. Keep the full artifact if using its optional CUI launcher.

```powershell
.\pcdiag.exe tray
.\pcdiag.exe tray --full
.\pcdiag.exe tray --tray
.\pcdiag.exe tray startup on
.\pcdiag.exe tray startup off
.\pcdiag.exe tray startup status
```

The launcher prefers the per-user installed viewer, then the adjacent packaged viewer. These commands are in the new packaged CLI; an older installed recorder CLI does not gain them merely by installing the viewer. Directly launching `pc-diagnostics.exe` opens the mini monitor. `--tray` starts with no WebView/window. Startup uses the current user's Run key and applies after login, separately from the recorder's existing SYSTEM boot task. Disabling tray startup does not disable recording.

## Status and limits

The native tray reads the coordinator heartbeat every two seconds; no WebView or sensor scan is needed while all windows are closed. Green means the expected enabled recording workers report fresh successful recording; it does not certify healthy hardware. Stopped is grey, stale/missing/failed is amber. The mini monitor labels old temperatures as last values and honours explicit module opt-outs. Individual unavailable providers remain available through `pcdiag coverage`.

The detailed monitor uses the existing cockpit; this stage adds its entry point, not a new full dashboard. A real Windows login/startup test remains separate from registration verification. UAC start/stop must not be tested on a live diagnostic installation simply to test the GUI; automated lifecycle tests use an isolated synthetic environment.

The mini monitor has no native title bar. Drag its TraceKeep header to move it; its small × button closes the window back to the tray through the same close handler. Recording continues. The full monitor retains its standard window controls.
