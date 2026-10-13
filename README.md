# TraceKeep

A **CUI-first Windows recorder** for investigating unexpected power loss. The Rust `pcdiag` command controls one boot task with isolated CPU, motherboard and GPU/Windows workers. Tauri is an optional viewer of the same logs.

The extended recorder adds an isolated worker for detailed performance, processes, GPU XML, driver/device inventory, reliability history, power configuration and local dump/WER preservation. Every implemented diagnostic group is enabled by default and independently configurable. Read [collection controls, defaults and limits](docs/collection-settings.md) before changing capture policy.

```powershell
.\pcdiag.exe config show
.\pcdiag.exe coverage
.\pcdiag.exe config disable processes  # Administrator; keeps existing data
.\pcdiag.exe config enable processes
.\pcdiag.exe config interval performance 30
```

Recording needs no GUI, browser, Python server or logged-in user after migration. Window X returns to the optional tray and keeps recording; the tray's explicit **stop recording and exit** stops the boot task through the CUI before removing the icon. Closing `pcdiag watch` or a GUI crash does not stop recording. See [tray setup and lifecycle](docs/tray.md).

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

One SYSTEM task, **PC Diagnostics Recorder**, starts at boot. The coordinator monitors worker exits and log-file freshness. Stalled workers trigger an isolated restart after at least 120 seconds (270 seconds for the extended worker). Disabled workers are reported and never launched. Repeated failures are limited to three restarts per ten minutes; other workers keep running. Coordinator events and a heartbeat explain recovery actions. This detects stalled recording, not hardware health. Boot configuration is installed, but a real reboot test remains a separate check.

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
| Windows events | `events-YYYYMMDD.jsonl` | Unified boot task / evidence worker |
| Storage / NVMe health | `storage-YYYYMMDD.jsonl` | Unified boot task / evidence worker |

The `collectors/` directory contains the PowerShell source used by these independent recorders. CPU and board reading uses LibreHardwareMonitor and PawnIO; GPU reading uses NVIDIA's installed `nvidia-smi`. Those third-party binaries are not redistributed here. Deploying new collector code over an existing installation needs an explicit migration; do not run a second collector alongside the installed version.

The auxiliary collector also acquires the legacy per-user mutex, so it exits when the installed first-generation recorder already owns it. The existing installation is not overwritten by opening or building the GUI.

## Evidence recorder

The isolated evidence worker runs every 15 seconds. It stores the full XML of System/Application events at every level and enabled diagnostic operational channels. Durable per-channel record-ID checkpoints survive recorder restarts and long downtime; first-time recovery is bounded to seven days. Each batch is capped at 2,000 selected events and drains remaining backlog on subsequent passes. A failed append never advances its checkpoint. An interrupted batch can replay records: deduplicate by channel, record ID and event time. Record-ID rollback or loss/replacement of the saved event-time anchor triggers bounded recovery and an explicit gap notice. Windows events already overwritten before recovery cannot be reconstructed.

At worker startup and every five minutes it captures Windows-exposed storage reliability counters, direct NVMe SMART/health, crash-dump settings, page-file allocation, local-volume free space and dump metadata. Unsupported fields are null, and access failures are retained explicitly. NVMe health uses the built-in Windows storage-property query with no new driver or device configuration changes. Controller lifetime counters include unsafe shutdowns, power cycles, media errors, error-log count and temperature warning duration. Full 512-byte health pages are retained as Base64; unsigned 128-bit counters are decimal strings to avoid loss of precision. These appear under `storage.nvme` in `pcdiag evidence`. A successful recorder heartbeat does not make an unavailable device query healthy: inspect each NVMe disk's `status` and `error`. Machine firmware/driver inventory is captured at worker startup without serial numbers. See [evidence coverage and limits](docs/evidence-coverage.md).

After boot events settle for 90 seconds, one snapshot per OS boot is saved under `%ProgramData%\PCDiagnostics\incidents\boot-...`. It includes recent raw boot/failure events, crash configuration and bounded tails from the last two dates of each stream (8 MiB per file). The manifest records truncation, failures and SHA-256 hashes. Original logs remain intact; dumps are independently preserved by the dumpArchive group. A snapshot without event 41/6008 is unclassified, not proof of clean shutdown. Late events remain in the continuous event archive; the snapshot is immutable. Sleep/resume does not create a new OS-boot snapshot.

Sensor defaults remain 2,000 ms. An administrator can set per-stream `cpu`, `board` and `activity` values from 1,000 to 5,000 ms in `recorder-settings.json` under the data root using an `intervalMilliseconds` object, then restart the recorder. Event and storage intervals are independent. Poll duration is elapsed time, not CPU utilization; shorter intervals cannot capture PSU protection waveforms. Current verbose sensor JSON can consume about 0.8 GiB/day on the initial machine. No automatic deletion or compression is performed.

To upgrade an active unified installation, extract the complete new package and run `management/Update-Recorder.ps1` once in Administrator PowerShell. It verifies the package's script checksums and syntax, backs up the installed scripts, stops recording briefly, and requires fresh sensor samples and successful System-event checkpointing. Failure restores the previous scripts and recording. It adds no drivers, changes no hardware controls and does not reboot. With automaticDump enabled, it backs up Windows dump settings and configures automatic dumps and retention; these changes require the next normal reboot. The checksum manifest detects package corruption; it is not a publisher signature.

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

* Incident comparison across boots, with counter changes and explicit sampling gaps.
* Independent external power-signal recorder import and clock alignment.
* Configurable sensor mappings across motherboard/CPU models.

Verification includes Rust log-reader tests, visualization semantics, legacy mutex coexistence, isolated simulated worker recovery/stop, empty-reading rejection, and mocked rollback with limited-token recovery. Tests never poll hardware or alter installed tasks.

### Compact tray temperature display

The notification icon displays the latest saved CPU temperature rounded to whole degrees every two seconds. Hover for the decimal reading and recorder state. `Ⅱ` means recording is stopped/stopping; `—` means the latest temperature is unavailable, disabled, stale (over ten seconds), or untrusted. The small accent indicates recording status, not an overheating diagnosis. The current CPU mapping is the same AMD Tctl/Tdie sensor used by the dashboard.

When all windows are closed, only a bounded CPU log tail (256 KiB per read, one retained sample) and the recorder heartbeat are read. No additional hardware poller is started. The compact monitor shows CPU/GPU temperatures and five recording lamps; amber denotes a missing/stale/error condition, gray denotes stopped/opted out. Hover or keyboard focus exposes each lamp's state. Recording start/stop and login startup are in the tray context menu. Window X still returns to the tray, while explicit Exit stops recording before exiting.

TraceKeep is the product display name. Existing `pcdiag` commands, executable names, scheduled task and data paths remain compatible with previous installations.

The compact temperature gauges use one uniform arc color that changes only with the current temperature, without colored scale ticks. Display anchors: CPU green through 70 °C, yellow at 85 °C, red at 95 °C; GPU green through 60 °C, yellow at 75 °C, red at 90 °C, with interpolation between anchors. These are visual conventions, not hardware protection limits or fault diagnoses. Both arc lengths use a 0–100 °C display scale, capped at the end while the number preserves higher valid readings. Missing/stale readings show an empty gray track.
