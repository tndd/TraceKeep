# Evidence completeness

This revision fixes five evidence gaps without rewriting existing sensor logs,
changing external dump settings, or deleting unusable evidence.

- History returns every matching GPU-detail and process sample within the same
  bounds as other streams. The dashboard process diagram still computes its
  summary from the final two samples; this no longer discards the underlying
  period history. `returnedRows`, `matchedRowsInScan`, and `omittedRows` describe
  the returned data. The existing two-hour query, 512 MiB decompressed file scan,
  100,000-row and 32 MiB output bounds remain. A reached bound sets `truncated`;
  `matchedRowsInScan` is not a claim about unread portions of a limited file.
- Extended collection uses monotonic deadlines and sleeps until the earliest
  due module (at most 15 seconds between idle heartbeats). Provider duration
  no longer shifts every deadline to completion plus the configured interval.
  Actual start
  interval, deadline lateness and skipped intervals are recorded, and expired
  slots are skipped without catch-up bursts. This is not a hard real-time
  scheduler or a new set of hardware collectors. The subsequent
  [pre-failure evidence change](pre-failure-evidence.md) separates the modules
  into independently supervised processes.
- An active dump-policy receipt is compared with current registry values.
  External changes/missing values return `drifted`, not `already-configured`.
  Comparison is read-only and preserves the original rollback receipt.
  `crash-configuration.json` includes the periodic observed policy state;
  CLI evidence/coverage and the dashboard settings inspector expose it with its
  observation time. Reading historical sensor data does not turn this current
  observation into historical configuration. Actual dump creation remains
  unverified.
- Dump preservation and dump usability are separate. Empty or structurally
  incomplete minidumps remain archived byte-for-byte, with `validation.status`
  set to `invalid`. Bounded minidump header/directory/stream-range checks produce
  `structure-checked`, never a claim of successful debugger analysis. Other
  formats, including kernel dumps, remain `unverified` rather than being declared
  corrupt. Unusable/unverified files keep aggregate archive coverage `partial`
  across repeated scans, including files with old receipts. Existing archives
  are not deleted; a legacy receipt can gain validation metadata with its
  previous version retained.
- New boot bundles copy collection settings, coverage, sensor isolation, dump
  policy and event-channel coverage as well as inventory/legacy settings.
  `conditions.json` records capture time, hashes, reported timestamps, and
  missing/unavailable/invalid files. These are observations **after the boot**,
  not proof of conditions before a failure. Existing bundles remain immutable;
  missing conditions receive a separate `conditions-recovery` supplement with
  its own observation timestamp, never a replacement of the old manifest.

The minidump structural checks follow Microsoft's
[MINIDUMP_HEADER](https://learn.microsoft.com/en-us/windows/win32/api/minidumpapiset/ns-minidumpapiset-minidump_header)
and [MINIDUMP_DIRECTORY](https://learn.microsoft.com/en-us/windows/win32/api/minidumpapiset/ns-minidumpapiset-minidump_directory)
layout. Nested stream contents and debugger interpretation are outside this
lightweight validation.

## Regression verification

`scripts/Test-EvidenceCompleteness.ps1` supports separate `-Case` selections:
`history`, `schedule`, `dump-policy`, `dump-quality`, and `bundle`.
`-Cli` selects a built CLI. All inputs are generated under unique temporary
directories; no installed tasks, production logs, registry settings or hardware
are modified. The scheduler runs a private worker copy with a unique local mutex,
synthetic provider and one-second test-only interval. Normal configuration
validation still enforces the existing minimum interval.

On the pre-fix revision the five cases reproduced:

1. 14 saved detail samples reduced to 2 returned samples.
2. A one-second test interval became approximately 15 seconds with a 200 ms
   provider.
3. An active policy expecting dump mode 7 accepted actual mode 3 as configured.
4. A zero-byte dump lacked an unusable-evidence state.
5. The boot bundle omitted `collection-settings.json`.

The fixed tests also cover raw/gzip parity, row/byte-bound reporting, overrun and
exact-deadline scheduling, external policy changes without writes, cached/legacy
empty dumps, truncated directory/stream offsets, unfamiliar dump formats, stable
partial coverage, immutable snapshots, and separately labeled old-bundle
supplements. Existing archive integrity/resume, event recovery, daily gzip,
worker coordination and isolated updater tests remain required.

Deployment is separate from source validation. Running this test suite neither
updates nor restarts an installed recorder.
