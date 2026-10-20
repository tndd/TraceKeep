# Evidence before an interrupted recording session

This change builds on the five evidence-completeness fixes. Deployment and
merging remain separate operations. Existing sensor files, archives, incident
bundles and crash settings are not rewritten by this change.

## Configuration history

`configurationJournal` is an independently supervised, read-only module, enabled
by default with a 15-second observation interval. It records
`detail-configurationJournal-YYYYMMDD.jsonl`. Each changed observation contains:

- Saved collection settings and legacy recorder settings.
- Sensor-driver isolation, dump-policy receipts and event-channel coverage.
- The coordinator's `recorder-run.json`, including its run ID and applied
  collection configuration and CPU/board/activity intervals.
- The actual CrashControl registry values, including explicit missing values.

Saved configuration and applied configuration are separate. The coordinator
publishes an atomic `active-collection-settings.json` at startup; event and
isolated workers, including restarted workers, read that snapshot instead of
silently adopting a subsequently edited settings file.

Files are read with a 256 KiB bound each. Missing, invalid, unreadable and oversized
inputs are explicit states. Valid JSON is kept as exact text with its SHA-256;
the observer never repairs or changes the source. Unchanged observations refer
to the full earlier result. Each process restart and local date starts with a
full result, using the existing durable append and gzip infrastructure.

These are observations, not an audit hook for every registry/file write. A change
and reversal between polls can be missed. The first record establishes a baseline
at startup; it cannot reconstruct settings before the feature was deployed.
`detail-crashConfiguration` separately retains periodic full dump/pagefile/disk
configuration observations; `crash-configuration.json` remains the latest view.

## Independent collection

The existing coordinator now directly owns one process per enabled extended
module: performance, processes, GPU details, inventory, reliability, power,
dump archive, WER archive, disk space, storage/NVMe, crash configuration and
configuration journal. The original `extended` process only aggregates status
every 15 seconds. Storage and crash queries no longer block event recovery.

Each module durably records its start before querying and completion/error
afterward in `module-NAME-YYYYMMDD.jsonl`, using a session ID and sequence.
An atomically replaced `module-state/NAME.json` supports current coverage.
Coverage rejects observations from a different coordinator run or stale clocks.
Normal idle intervals produce heartbeats at least every 15 seconds; a synchronous
query cannot refresh its own heartbeat while stuck.

The supervisor kills and restarts only the stalled worker after 135 seconds
without progress (600 seconds for archive copying). Existing restart controls
remain: a 10-second retry delay and at most three restarts in ten minutes.
Long legitimate queries can exceed these deadlines and must be diagnosed from
the retained progress records. A shared five-second shutdown grace period
prevents the increased worker count multiplying stop latency.

This costs additional processes: all-enabled operation uses 18 recorder
PowerShell processes instead of six. Memory/CPU overhead with actual providers
must be measured during a separately authorized deployment. Process separation
does not isolate a kernel driver failure, shared WMI service failure, disk I/O
failure, or OS-wide hang.

The tray and doctor check every reported worker, including cooldown/failed
isolated modules. Upgrade verification waits for fresh completed observations
from all enabled modules, rather than accepting an aggregator heartbeat alone.
Partial provider support remains explicitly partial; completion is not proof
of healthy hardware or successful future dump creation.

## Last recorded boundary

The shared writer already used WriteThrough and `Flush(true)` for every JSONL
line. These remain mandatory. The writer now advances an in-memory committed
byte offset only after both flush operations succeed.

CPU, motherboard and activity workers append a separate durable `progress-*`
record before initialization and before each sample. Records include session,
sequence and monotonic time; sample-start records also include the preceding
sample's acknowledged file name, byte offset and time when available. Match
session/sequence against the sensor record to identify an in-flight query.
Extended modules provide the same start/completion distinction in their module
logs. No claim of successful collection is made before the data append returns.

This adds a progress append and flush to each sensor sample. It does not buffer
the last seconds in memory to save writes. A process termination test verifies
that acknowledged rows survive without normal disposal, and that restarting
after an incomplete tail preserves the original bytes and separates the next
record. This is not a physical power-cut or storage-firmware test: OS flush
acknowledgment cannot guarantee survival on a device that ignores it.

New journals, coverage history and CPU/board/activity progress are included in
bounded incident tails and `pcdiag history` (raw and gzip), under the stream keys
`configurationJournal`, `crashConfigurationHistory`, `collectorHealth`,
`cpuProgress`, `boardProgress`, and `activityProgress`. The existing two-hour and
per-stream output limits still apply. Module logs remain available as original
daily files; the aggregated coverage history carries their observed status.

## Synthetic verification

Run `scripts/Test-PreFailureEvidence.ps1`. It never queries real sensors,
modifies registry settings, or stops an installed recorder. It covers:

- Configuration drift, missing/invalid inputs, applied versus saved settings,
  unchanged references, restart/day baselines and gzip integrity.
- One hung module while a fast module continues, isolated restart, explicit
  coverage gaps, and shutdown with no remaining test workers.
- Forced process termination before the next sample, acknowledged-prefix
  preservation, partial-tail recovery, and failed-flush receipt ordering.

The isolation test uses private copied scripts and unique local mutexes. Only
test deadlines/intervals are shortened. Existing update simulations now reject
an incomplete first module pass. The existing supervisor test also reproduces
an additional defect: an old error row used to overwrite `waiting`, resetting
the retry time forever after a worker exited. Dead-worker retry states now
remain intact.

## First Rust collectors

The standalone `recorder/` crate builds `tracekeep-worker.exe` without Tauri,
WebView or PowerShell. Packaged coordinators select it for `configurationJournal`
and `processes`; each remains a separate supervised process with the same
intervals, timeouts and retry budget. Other collectors remain unchanged.
Roots without the binary retain the PowerShell backend for compatibility and
synthetic tests; installation/update manifests require the binary in new packages.
Runtime and module records identify the selected backend.

The process collector queries the same `Win32_Process` provider through COM/WMI,
requesting only the existing fields. Numeric counters and Windows PowerShell's
`/Date(milliseconds)/` creation timestamps remain compatible. WMI initialization
and query stalls stay inside the process worker, not the supervisor. This first
step removes the PowerShell host; it does not eliminate WMI provider costs.

Both backends take a per-root module owner lock. The Rust writer also honors
the existing per-log `.lock` protocol, preserves interrupted tails, validates
and restores archived days, syncs records before publishing completion or
unchanged references, and starts a full baseline after restart or a day change.
Configuration observation remains read-only, including exact input hashes/text
and the distinction between saved and coordinator-applied settings.

Build/test after the frontend checks:

```
cargo test --manifest-path recorder/Cargo.toml --locked
cargo build --manifest-path recorder/Cargo.toml --release --locked
powershell.exe -NoProfile -File scripts/Test-UnifiedRecorder.ps1 -Native
powershell.exe -NoProfile -File scripts/Test-RustWorkers.ps1
```

The native integration test uses temporary log roots, read-only process/registry
queries and the existing CLI. It checks field parity, duplicate-backend exclusion,
independent termination/restart, changed settings, graceful stop and raw/gzip
history equality. It does not stop or replace installed collectors, write
registry settings, install drivers or inject hardware faults.

## Second Rust collectors

`performance`, `reliability` and `diskSpace` now also use independent native
workers. The preceding deployment measurement put their combined private
commit at about 282 MiB (92, 105 and 85 MiB respectively). Performance and
space accounting run every 15/60 seconds; reliability runs every 300 seconds.
They remove three PowerShell hosts without changing the sensor/.NET/driver
boundary, event checkpointing, or crash-file preservation.

Performance reads the same five WMI classes and selected fields, including
formatted counters and raw disk-latency numerator/base/frequency values.
Counters remain integers or null, without unit conversion or synthetic zeroes.
Reliability retains the seven-local-calendar-day filter, fields and escaped
Windows PowerShell `TimeGenerated` date encoding. Each provider failure is
reported without discarding successful independent sources. WMI enumeration
is bounded by rows and serialized bytes; exceeding a bound omits that source
with an explicit issue. WMI can still block in the provider, in which case the
existing supervisor stall deadline applies to that worker only.

Space accounting uses `GetDiskFreeSpaceExW`, counts top-level log files and
recursive archive files, respects `reserveFreeBytes`, and never deletes data.
Like the existing collector, it excludes hidden/system entries. Directory
traversal has entry, depth and elapsed-time bounds and does not follow reparse
points. Incomplete counts are null with explicit issues, rather than silently
underreporting usage; known low free space still produces a warning.

The CLI history reader now exposes the existing `reliability` and `diskSpace`
streams as well as `performance`, for both old PowerShell and native records,
including gzip and unchanged-reference resolution. No existing stream is removed.

`scripts/Test-RustMetrics.ps1` checks real read-only provider field/type parity,
reliability timestamps, synthetic directory sizes, low-space warnings, junction
exclusion, opt-out and raw/gzip history equality. Mixed-recorder testing kills
only its private performance worker and verifies recovery without restarting
the other four native workers. Unit tests cover partial provider failures,
counter precision/nulls, query bounds and incomplete directory scans.

## Native diagnostic workers and maintenance

Six more resident PowerShell hosts are replaced: `inventory` (1800 s), `power`
(300 s), `gpuDetails` (60 s), `crashConfiguration` (300 s), `extended` coverage
(15 s) and `maintenance` (60 s). Eleven of eighteen workers are native; the
coordinator remains separate. GUI lifetime, per-worker supervision, settings,
opt-out and fallback behavior are preserved. The two non-module workers share
per-root owner locks with their PowerShell fallbacks as well.

Inventory retains all nine projections and the thirteen-field incident snapshot.
Missing properties remain null; provider metadata and identities outside the
existing allowlist are not serialized. Driver timestamps with unspecified
fractional seconds/offset follow `Get-CimInstance` UTC semantics, not
`ManagementDateTimeConverter`'s different local-time default. The history API
also exposes `inventory` and `power`, including older PowerShell records.

Power still queries battery/ACPI and the six read-only `powercfg` commands, with
OEM decoding. NVIDIA XML still excludes every process subtree. Helpers enter
an unnamed kill-on-close job at creation, with only their three standard handles
inherited (Windows 10+). Each has a 5 s deadline, 4 MiB stdout and 64 KiB stderr
bounds; errors are limited to 4096 characters. Malformed XML, provider errors
and omitted oversized sources are explicit partial results. Inventory/power/GPU
results have a combined 3 MiB data budget compatible with older history
readers, including recorder metadata and date escaping. WMI calls remain
isolated and subject to the coordinator's stall recovery.

Crash configuration reads the existing registry/pagefile/volume/OS fields and
compares the saved dump policy without changing it. The durable detail record
precedes `crash-configuration.json` and the completion heartbeat. Dump metadata
scans have time/entry/depth bounds, at most 100 files per root, and report
incomplete scans and skipped links; they never read or modify dump contents.

Coverage reads bounded state files, rejects another run, heartbeats older than
45 s or more than 5 s in the future, and retains storage/NVMe enablement rules.
Maintenance streams 64 KiB chunks under the existing writer lock, keeps today
and yesterday raw, verifies decompressed SHA-256 and gzip CRC, commits the hash
receipt, then removes the redundant raw copy. A failed/aborted pass, active
writer, corrupt archive or mismatching archive retains the original. Interrupted
commits resume without overwriting conflicting evidence; clock rollback restores
verified archives before appending. A pass handles at most 64 files, with
compression heartbeats and stop checks between chunks. There is no age or
free-space deletion policy.

Validation includes `scripts/Test-RustDiagnostics.ps1`, the mixed-worker restart
test, standalone unit tests and the complete Windows pipeline. Native tests
cover provider parity, Unicode dates/output, policy/snapshot preservation,
ownership, opt-out and raw/gzip history. Synthetic tests cover interrupted
compression, conflicts, malformed XML, stale coverage, bounded results and native
helper failure/output limits. Native unit-test failures explicitly stop CI before
the release-build command can mask them.

Remaining boundaries are CPU/board sensors (LibreHardwareMonitor/PawnIO),
storage (Windows reliability
and NVMe IOCTL contracts), event recovery/incident capture, dump/WER preservation,
and the coordinator. These require provider or recovery/failure tests of their
own; they are not consolidated into another collector to reduce process count.


The history reader previously rejected lines above 4 MiB although native writers
allow 8 MiB and reliability queries allow 6 MiB. A synthetic 5 MiB record
reproduces the lost history row. Reading now allows 8 MiB plus CRLF, with the same
malformed/oversized-line recovery. The reference cache is bounded by 32 MiB of
serialized data as well as 64 entries, independently of the output-row budget.
Tests cover large raw/gzip records, unchanged references, subsequent valid rows
after an oversized line and cache replacement/eviction accounting.


## Native aggregate activity and workspace reads

The activity sampler is also an independent Rust process (12 of 18 workers).
It acquires both the current global and first-generation per-user named mutexes
before accessing providers, plus a per-root owner lock. Its `sessions`, `activity`,
`progress-activity` and fatal `errors` JSONL remain compatible. Aggregate CPU,
memory (cached for five iterations), disk and NVIDIA CSV fields retain nulls,
string-valued GPU counters and unsupported-field lists. Settings and legacy
millisecond interval overrides retain their 1–5 second bounds. NVIDIA helpers
use the existing bounded kill-on-close job; WMI stalls remain isolated under
the supervisor. Progress precedes providers and points only to a successful
same-day durable append. A restart has a new session, and torn tails retain
their original bytes. The fallback PowerShell collector remains packaged.
`Test-RustActivity.ps1` runs on an isolated host: it must not stop a production
collector to acquire the legacy mutexes.

The detailed workspace previously requested every full history stream, even
though its model immediately discarded unused rows. The workspace query now
requests its eight displayed streams, transports process history as the last
two samples with complete count/time/gap metadata, selects the last available
GPU XML sample, and uses a lossless metadata catalog for sensor rows. There is
no sensor decimation. Full `pcdiag history` and on-disk data are unchanged;
`pcdiag workspace-history START END` exposes the presentation transport for
validation. Projection is explicit in stream metadata, and existing read-limit
warnings remain on requested streams. The frontend parses event XML once per
shown group and GPU XML once per view, retaining all event records for inspection.
A missing histogram palette caused the CPU/GPU comparison exception; rendering
regressions now exercise distribution, scatter and evolution with data and empty
periods, alongside catalog/model parity.
