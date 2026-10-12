# PC Diagnostics

A local Windows diagnostics console for investigating unexpected power loss. An on-demand **Tauri 2 + Rust** viewer sits above independent, persistent sensor recorders.

Closing the GUI exits the viewer. Recording continues through the existing Windows tasks. The desktop viewer has no HTTP server, Python runtime, external fonts, CDN, or telemetry.

## Development

Install stable Rust, the Microsoft C++ build tools and WebView2 as described in the [Tauri prerequisites](https://v2.tauri.app/start/prerequisites/).

```powershell
cd src-tauri
cargo test
cargo run
cargo build --release
```

Windows CI runs Rust tests and builds a portable executable. The executable requires the WebView2 runtime installed on Windows. It is not code-signed in this development release.

Extract the `pc-diagnostics-windows` artifact from a successful Actions run and open `target/release/pc-diagnostics.exe`. The first launch can be configured in Settings; no administrator privileges are needed for the viewer. `scripts/Start-Desktop.ps1` also accepts an extracted executable via `-ExecutablePath`.

## Log sources

The overview uses temperature trends, an empirical voltage histogram, GPU power history with peak/mean summaries, and plain-language recording status. Voltage distributions count observed samples; they do not fit a normal curve or imply a pass/fail test. A fixed reading stays a single occupied interval. Missing samples remain gaps. Recording status lists saved time ranges, sample counts and gaps over six seconds within the selected history window. The common time selector applies to all history views. Run `node --test scripts/Test-Visualizations.cjs` to check these data semantics.

The viewer reads existing JSONL logs. It does not install drivers or start another hardware poller. Use **Settings** to select existing sensor and activity log directories. Configuration is stored locally at `%LOCALAPPDATA%\PCDiagnostics\sources.json`.

| Stream | Filename | Lifetime |
| --- | --- | --- |
| CPU | `cpu-auto-YYYYMMDD.jsonl` | Existing SYSTEM startup task |
| Motherboard | `board-auto-YYYYMMDD.jsonl` | Existing SYSTEM startup task |
| GPU, load | `activity-YYYYMMDD.jsonl` | Existing login recorder |
| Windows events | `events-YYYYMMDD.jsonl` | Existing login recorder |

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

* Unified collector deployment with rollback and migration of existing tasks.
* Independent freshness watchdog and incident bundles after abnormal boots.
* Additional WHEA/storage channels and periodic NVMe health counters.
* Configurable sensor mappings across motherboard/CPU models.

The first milestone replaces the Python/browser viewer with Rust/Tauri while preserving the working recording path.
