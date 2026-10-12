# PC Diagnostics

A **CUI-first Windows recorder** for investigating unexpected power loss. The Rust `pcdiag` command controls one boot task with isolated CPU, motherboard and GPU/Windows workers. Tauri is an optional viewer of the same logs.

Recording needs no GUI, browser, Python server or logged-in user after migration. Closing either `pcdiag watch` or the optional GUI does not stop the boot task. Only an explicit administrative stop changes recording.

## Unified CUI

Extract the entire `pc-diagnostics-windows` Actions artifact. Keep `management/` and `collectors/` next to the executables.

```powershell
.\pcdiag.exe status             # Freshness, locations and last readings
.\pcdiag.exe status --json      # Machine-readable snapshot
.\pcdiag.exe watch              # Refresh every two seconds; Ctrl+C exits the viewer
.\pcdiag.exe logs               # Resolved source directories
.\pcdiag.exe export             # Local recent-history snapshot, including coordinator status
.\pcdiag.exe doctor             # Stream and coordinator health
```

Before migration these read the existing per-user source configuration. Exit codes: `0` success, `1` command/configuration failure, `2` missing/stale/error data (or unconfigured/stale coordinator for doctor).

To migrate an existing installation, run once from an **Administrator terminal**, using the actual directory of the old activity logs:

```powershell
.\pcdiag.exe install --legacy-activity-root "C:\path\to\old\sensor-logs"
```

The installer requires the existing protected LibreHardwareMonitor/PawnIO setup and both legacy CPU/board tasks. It does not download or install a driver. It copies code into `%ProgramFiles%\PCDiagnostics`, and all streams into `%ProgramData%\PCDiagnostics\logs`. Code and data allow only Administrators/SYSTEM to write; ordinary users can read. It backs up task definitions/startup entries, stops legacy writers, copies their history without deleting originals, then verifies three fresh usable samples per stream. Failure restores legacy tasks and the user-level activity recorder. Switching entails a brief sampling gap, recorded in `migration.json`.

After installation:

```powershell
& "$env:ProgramFiles\PCDiagnostics\pcdiag.exe" start
& "$env:ProgramFiles\PCDiagnostics\pcdiag.exe" stop
& "$env:ProgramFiles\PCDiagnostics\pcdiag.exe" restart
& "$env:ProgramFiles\PCDiagnostics\pcdiag.exe" rollback
```

These four control commands require elevation. `stop` disables automatic starts until `start` is issued. `rollback` restores the old configuration and retains both sets of logs. Reinstallation over an existing migration is deliberately rejected. A rollback activity recovery task uses the original user's interactive, limited token; it never runs a user-writable script as SYSTEM.

One SYSTEM task, **PC Diagnostics Recorder**, starts at boot. The coordinator monitors worker exits and log-file freshness. No writes for 60 seconds trigger an isolated worker restart. Repeated failures are limited to three restarts per ten minutes; other workers keep running. Coordinator events and a heartbeat explain recovery actions. This detects stalled recording, not hardware health. Boot configuration is installed, but a real reboot test remains a separate check.

Machine `sources.json` takes precedence for both CUI and GUI. Per-user GUI source overrides are disabled while unified recording is configured. The recorder orchestration and hardware workers currently use PowerShell; Rust owns CUI commands, log reading, health presentation and export. Sensor access still uses the existing library/driver and `nvidia-smi`.

## Development

Install stable Rust, the Microsoft C++ build tools and WebView2 as described in the [Tauri prerequisites](https://v2.tauri.app/start/prerequisites/).

```powershell
cd src-tauri
cargo test
cargo run
cargo run --bin pc-diagnostics # optional GUI
cargo build --release
```

Windows CI runs Rust tests and builds a portable executable. The executable requires the WebView2 runtime installed on Windows. It is not code-signed in this development release.

The artifact contains `pcdiag.exe` and the optional `pc-diagnostics.exe`. The first GUI launch can be configured in Settings before migration; no administrator privileges are needed for the viewer. `scripts/Start-Desktop.ps1` also accepts an extracted executable via `-ExecutablePath`.

## Log sources

The overview uses temperature trends, an empirical voltage histogram, GPU power history with peak/mean summaries, and plain-language recording status. Voltage distributions count observed samples; they do not fit a normal curve or imply a pass/fail test. A fixed reading stays a single occupied interval. Missing samples remain gaps. Recording status lists saved time ranges, sample counts and gaps over six seconds within the selected history window. The common time selector applies to all history views. Run `node --test scripts/Test-Visualizations.cjs` to check these data semantics.

The viewer reads existing JSONL logs. It does not install drivers or start another hardware poller. Use **Settings** to select existing sensor and activity log directories. Configuration is stored locally at `%LOCALAPPDATA%\PCDiagnostics\sources.json`.

| Stream | Filename | Lifetime |
| --- | --- | --- |
| CPU | `cpu-auto-YYYYMMDD.jsonl` | Unified boot task / isolated CPU worker |
| Motherboard | `board-auto-YYYYMMDD.jsonl` | Unified boot task / isolated board worker |
| GPU, load | `activity-YYYYMMDD.jsonl` | Unified boot task / activity worker |
| Windows events | `events-YYYYMMDD.jsonl` | Unified boot task / activity worker |

The `collectors/` directory contains the PowerShell source used by these independent recorders. CPU and board reading uses LibreHardwareMonitor and PawnIO; GPU reading uses NVIDIA's installed `nvidia-smi`. Those third-party binaries are not redistributed here. Deploying new collector code over an existing installation needs an explicit migration; do not run a second collector alongside the installed version.

The auxiliary collector also acquires the legacy per-user mutex, so it exits when the installed first-generation recorder already owns it. The existing installation is not overwritten by opening or building the GUI.

## Diagnostic limits

* Freshness is a property of the saved logs, not a guarantee that hardware is healthy.
* Polling cannot capture AC waveforms or internal PSU protection history.
* Generic motherboard labels are preserved with sensor IDs. Unverified labels must not be treated as confirmed physical components.
* GPU power-brake counters are clues, not proof of PSU failure. Counters can reset when the driver resets.
* A sudden loss of power can still lose the final uncommitted write.
* Each file is read incrementally, with at most 8 MiB on initial load and 450 samples of in-memory history. This is a recent-history console, not an all-history analysis engine.

## Privacy and permissions

Real sensor logs, crash dumps, exports, machine-specific configuration and third-party binaries are excluded from Git. Exports are saved locally under `%LOCALAPPDATA%\PCDiagnostics\snapshots`.

The GUI runs without administrator privileges and exposes only read/status, export and log-source configuration commands. Hardware collector administration remains separate. The current UI sensor shortcuts target the initial AMD CPU/Nuvoton setup; unsupported identifiers display unavailable instead of zero.

## Roadmap

* Automatic incident bundles after abnormal boots.
* Additional WHEA/storage channels and periodic NVMe health counters.
* Configurable sensor mappings across motherboard/CPU models.

Verification includes Rust log-reader tests, visualization semantics, legacy mutex coexistence, isolated simulated worker recovery/stop, empty-reading rejection, and mocked rollback with limited-token recovery. Tests never poll hardware or alter installed tasks.
