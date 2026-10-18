# Optional Windows tray

The recorder remains CUI-first. The Tauri process reads the same Rust snapshot and invokes the installed `%ProgramFiles%\PCDiagnostics\pcdiag.exe` for recording controls. Viewing runs as an ordinary user; start/stop and collection configuration request Windows elevation. The viewer does not deploy collectors or poll hardware.

## User contract

- Left-click the tray: open the mini monitor. Right-click: mini monitor, detailed monitor, or **stop recording and exit**.
- Window X closes/releases that WebView and leaves the native tray and recording running.
- Explicit tray Exit requests `pcdiag stop` with Windows UAC. The icon disappears only after that command succeeds. Cancellation/failure leaves the icon and displays the error. A failed or cancelled stop is never reported as success.
- The tray menu can start/stop recording without exiting. Stop retains logs and disables the recorder boot task until Start is issued. Start waits for the existing CUI's fresh-sample verification. The stopped mini monitor also offers a Start button.
- GUI crashes, Task Manager termination, Explorer notification-area overflow and sign-out are **not** explicit recorder stop commands. Recording remains independent in these cases so diagnostic evidence is not lost.
- Launching a new viewer instance, including at sign-in, checks the recorder. A confirmed stopped installation requests elevation to resume. Cancelling leaves recording stopped and the tray visible; retry Start from the mini monitor or tray menu. Unknown, stale-without-stop-marker and unconfigured states never trigger automatic starts. Opening another view in an existing instance does not resume an intentional pause.
- Stop/start operate on the machine-wide recorder, affecting all logged-in users. The tray is a single instance per Windows session.

## Installation and CUI

Extract the Actions artifact and run `Install-Tray.ps1` as the ordinary user. It installs only the viewer to `%LOCALAPPDATA%\PCDiagnostics\viewer`; no administrative recorder upgrade or collection interruption is needed. Use `-Startup` to also register login startup, or the tray menu afterwards. A launched viewer can request elevation to resume a stopped recorder. Keep the full artifact if using its optional CUI launcher.

```powershell
.\pcdiag.exe tray
.\pcdiag.exe tray --full
.\pcdiag.exe tray --tray
.\pcdiag.exe tray startup on
.\pcdiag.exe tray startup off
.\pcdiag.exe tray startup status
```

The launcher prefers the per-user installed viewer, then the adjacent packaged viewer. These commands are in the new packaged CLI; an older installed recorder CLI does not gain them merely by installing the viewer. Directly launching the viewer starts in the tray; `--mini` or `--full` opens a monitor. Startup uses the current user's Run key and applies after login, separately from the recorder's existing SYSTEM boot task. Disabling tray startup does not disable recording.

## Status and limits

The native tray reads the coordinator heartbeat every two seconds; no WebView or sensor scan is needed while all windows are closed. Green means the expected enabled recording workers report fresh successful recording; it does not certify healthy hardware. Stopped is grey, stale/missing/failed is amber. The mini monitor shows unavailable/stale temperatures as a dash and honours explicit module opt-outs. Individual unavailable providers remain available through `pcdiag coverage`.

Snapshot reads time out after 10 seconds; history reads after 30 seconds. The UI reports the failure and permits retry instead of waiting forever. Timed-out native reads are not cancelled; periodic refreshes reuse the outstanding read instead of queuing more work. Recording controls have no UI timeout because elevation or a running mutation must not be mistaken for cancellation. Saved history remains readable while recording is stopped.

The detailed monitor displays the saved device workspace. A real Windows login/startup test remains separate from registration verification. UAC start/stop must not be tested on a live diagnostic installation simply to test the GUI; automated lifecycle tests use an isolated synthetic environment, verify fresh mini readings and stopped readings through native IPC, and render history while the fixture recorder is stopped.

The mini monitor has no native title bar. Drag its TraceKeep header to move it; its small × button closes the window back to the tray through the same close handler. Recording continues. The full monitor retains its standard window controls.
