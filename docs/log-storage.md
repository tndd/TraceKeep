# Durable logs and daily gzip

The recorder keeps the current and previous **local calendar dates** as JSONL.
An independent maintenance worker compresses older daily files to
`<stream>-YYYYMMDD.jsonl.gz` in the same log directory. It scans at startup and
then every minute, handling at most 64 eligible files per pass. Locked files and
failures are deferred and reported in `log-maintenance.json` and the
`maintenance-YYYYMMDD.jsonl` stream. It never expires archived dates.

All writers and maintenance use a per-file `.lock` sidecar. A live writer holds
its lock until it closes that file; legacy writers are also excluded by Windows
file sharing. Empty lock files remain so their identity cannot change during a
handoff. They do not contain log records.

Compression writes `.gz.partial`, closes the gzip stream and flushes it, then
decompresses it to verify SHA-256, CRC32 and length against the original. Only
then does it publish `.gz`, durably write `.gz.sha256`, and remove the identical
raw copy. Source and archive conflicts retain both files and report an error.
Interrupted work retries from the original; it does not append to an incomplete
gzip stream. A crash after publishing the archive but before removing the raw
file is recovered by verifying their equality. Readers prefer raw while both
copies exist. Temporary compressed copies require additional free space; if
space runs out, the original remains and maintenance reports failure.

If the system clock moves back to an archived date, a writer restores that day's
verified original before appending. An interrupted JSONL tail is preserved and
terminated with a newline before the next record. Readers can report the
malformed fragment without losing the next valid event. Event checkpoints still
advance only after the complete batch was durably written.

Detailed unchanged-result references are committed only after successful
append. Each new local date begins with a full result, so newly collected daily
files do not depend on the previous date's payload.

The shared CLI/desktop period-history query supports raw, gzip and mixed date
ranges. The existing 512 MiB per-file read limit applies to **decompressed**
bytes, not compressed size; clipping and gzip failures are returned explicitly.
Boot evidence bundles read bounded tails from either format and save plain
JSONL copies with hashes. All files continue to use the existing protected
log-directory permissions.

## Known limits and rollout

- Compression does not impose a total archive budget or delete old dates.
- The existing history-query limit is two hours, at most four files per stream,
  100,000 retained rows and 32 MiB output per stream. Daily files larger than
  512 MiB may still have a clipped late-day query; size-based segmentation is a
  separate change.
- Old detail logs may already contain cross-day references without a payload in
  the queried files. New collection is fixed; compression preserves old bytes
  exactly and cannot reconstruct missing payloads.
- Events recovered more than one day after their event timestamp can remain
  outside the history query's current file-date selection.
- Existing general collection `partial`/`warning` aggregation is unchanged.
  Maintenance failures are included in recorder status and `pcdiag doctor`.

Build and test the full package before deployment. Updating collector scripts
and the CLI uses the existing explicit recorder upgrade procedure; update the
optional viewer from the same build so its embedded history reader supports
gzip. Do not deploy only the compression worker with an older viewer.

Tests: `scripts/Test-LogStorage.ps1` covers crash-tail replay, reference commit
ordering, daily boundaries, integrity and interrupted compression, active-writer
exclusion, clock rollback, bounded archive tails, boot bundles and an isolated
maintenance worker. Rust history tests cover raw/gzip equivalence, mixed
midnight ranges, duplicate-copy selection, decompressed bounds and corruption.
