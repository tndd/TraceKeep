# Collection controls

The recorder enables every implemented diagnostic group by default. It does not claim to collect every possible hardware signal. No benchmark, firmware change, forced crash, new kernel driver, network transmission or reboot is performed. GUI lifetime has no effect on recording.

```
pcdiag config show
pcdiag coverage
pcdiag config disable processes
pcdiag config enable processes
pcdiag config interval performance 30
pcdiag config disable automaticDump
```

Read commands need no elevation. Changes need an Administrator terminal, are saved atomically to `%ProgramData%\PCDiagnostics\collection-settings.json`, and restart the recorder if it was running. A deliberately stopped recorder stays stopped. Existing logs are never deleted by opting out. Each group is independent: disabling `activity` does not disable the separate `gpuDetails` group, and disabling `events` does not disable incident boot-event snapshots. Disable both relevant groups if both forms of evidence are unwanted. Invalid names/values are errors, not silently ignored settings. Adding a new group in a future release defaults it to enabled.

| Group | Default seconds | Data |
| --- | ---: | --- |
| cpu / board / activity | 2 | Existing CPU, board and GPU/aggregate load workers; a disabled group launches no worker |
| events | 15 | All levels of System/Application plus enabled diagnostic operational channels; catalog identifies disabled/unavailable channels |
| storage / nvme / nvmeErrors | 300 | OS reliability, NVMe SMART, controller identity capabilities and full supported error-entry array (up to 256 entries) |
| crashConfiguration | 300 | Dump settings, pagefile, volume space and dump inventory |
| incidents | 15 | Once-per-boot evidence bundle, after boot has settled |
| performance | 15 | CPU DPC/interrupt load, detailed memory pressure, per-disk queues and raw latency counters |
| processes | 30 | Names, PIDs, parent PIDs, creation time, cumulative CPU/I/O and memory; no command lines |
| gpuDetails | 60 | NVIDIA XML including PCIe, memory/ECC, voltage/power and throttling fields exposed by the installed driver; process list removed |
| inventory | 1800 | BIOS, board, RAM, storage firmware, signed drivers, PnP status/problem codes and installed hotfixes |
| reliability | 300 | Seven days of Windows reliability records |
| power | 300 | Power scheme/settings, sleep availability, last wake, wake timers, power requests, batteries and exposed ACPI thermal zones |
| dumpArchive | 60 | Local preservation of stable minidumps, live kernel dumps and configured main dump |
| werArchive | 300 | Machine-wide Windows `Report.wer` files; per-user WER directories are not traversed |
| diskSpace | 60 | Free space, log/archive growth and reserve warning; no deletion |
| automaticDump | Policy | On administrative upgrade/enable, automatic dump plus LogEvent/AlwaysKeepMemoryDump; restores owned settings when disabled |

Sensor intervals support 1–5 seconds. Other intervals support 15–86400 seconds. Extended scheduling runs in 15-second cycles with sequential bounded queries, so requested intervals are minimum delays and actual timestamps/durations must be used. Storage-related groups share a snapshot interval equal to the shortest enabled storage-group interval. Incident and automatic-dump groups are event/policy driven; changing their interval does not create repeat incidents or repeatedly alter the registry. Configuration applies at restart.

`coverage.json` and `detail-<group>-YYYYMMDD.jsonl` distinguish `ok`, `partial`, `unavailable`, `error`, `pending`, `collecting`, `warning` and `disabled`. `ok` describes collection, not hardware health. A partial result keeps successful providers and the missing provider's error. Repeated identical detail results may contain `unchanged:true` plus the previous result's SHA-256 instead of duplicating its body. The first result after each worker start is always complete; keep the earlier full row when exporting/analysing a hash reference.

Memory and I/O process counters are cumulative, not instantaneous utilization; compare samples using PID **and creation time**. Disk latency uses `diskLatencyRaw`: delta numerator divided by counter frequency and delta `_Base`; zero base delta means no observations, not zero latency. WMI formatted latency counters can truncate sub-second values and must not be used to infer zero latency.

## Dumps and archive limits

Upgrade retains any existing complete/kernel/automatic dump selection; otherwise it selects automatic dump. `AutoReboot` and pagefile configuration are unchanged. Original values are saved before edits, disabling `automaticDump` restores values still owned by this policy, and later external changes are respected. **Windows must be restarted normally for changed dump settings to take effect.** This tool never initiates that reboot. Dumps cannot be written after total power loss. [Microsoft configuration documentation](https://learn.microsoft.com/en-us/troubleshoot/windows-server/performance/memory-dump-file-options).

Archives live under `%ProgramData%\PCDiagnostics\archive`, with access restricted to SYSTEM and Administrators; ordinary read-only status commands expose collection metadata. Defaults: 32 GiB per file, 64 GiB per archive group, 10 GiB free-space reserve, 64 files per pass, 20-second copy budget per group. These are configurable `limits` fields in the settings JSON; edit as administrator, then restart. Large copies resume from `.partial`; completed copies receive a SHA-256 receipt. Only files older than 60 seconds that can be opened against writers are copied. No source is deleted. Size/space/scan limits and in-use files produce explicit skipped/pending/unavailable records. Directory reparse points are not followed. Interrupted obsolete partials are retained and count against the archive budget.

Dumps, Windows reports, device IDs and process names can contain private information. Everything stays local in the protected data directory. Opt-out stops new collection but does not erase retained data. `pcdiag export` remains the older bounded sensor export; it is not an all-evidence/dump export. Boot bundles include bounded new detail tails; the continuous original logs and archive remain the authoritative evidence.

## Boundaries

No arbitrary register reads, AC waveforms, PSU-internal protection history, vendor-specific EC/SMBus probes, Windows Analytic/Debug ETW sessions or disabled Windows event channels are enabled. These require hardware-specific validation, may affect stability or can generate excessive data. Available channels and failed capabilities are catalogued instead of pretending these blind spots are covered. Sensor board labels remain unverified. All local driver-exposed diagnostics are collected through existing supported interfaces; future providers fit the same independent opt-out model.
