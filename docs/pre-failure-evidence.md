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
