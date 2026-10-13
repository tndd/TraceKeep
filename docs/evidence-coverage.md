# Evidence coverage and remaining limits

The recorder gathers evidence for diagnosing a failure; it cannot guarantee prevention or identify every sudden power loss. Recording availability and component health are separate facts.

| Evidence | Collection | Interpretation and missing coverage |
| --- | --- | --- |
| CPU/board temperature, voltage and fans | 2 seconds by default | Can reveal sustained heat or voltage changes. Board names and scale factors are library mappings, not calibrated measurements. No sub-second waveform or PSU internal protection state. |
| GPU load, power and throttling causes/counters | 2 seconds by default | External power-brake or thermal flags can help establish sequence. Unsupported counters stay null. Power-brake is not a diagnosis of PSU failure. |
| System/Application and enabled WHEA/storage channels | 15 seconds, checkpointed | Preserves selected raw XML with IDs, provider and timestamps. Windows may never commit the last event; already overwritten events cannot be recovered. Event 41 is a symptom. |
| NVMe controller SMART log 0x02 | Startup and every 5 minutes | Unsafe shutdown, power cycle, media error and error-log counters persist across power cycles. Compare before/after on the same SSD; totals alone do not date incidents. Counter reset/replacement must not be interpreted as recovery. |
| Windows storage reliability | Every 5 minutes | Separate OS-exposed counters; missing or failed fields are not zero. Historical maxima have no event timestamp. |
| Dump configuration, pagefile, free space and dump inventory | Startup and every 5 minutes | Shows whether crash evidence is configured and whether a dump appeared. A full power cut prevents Windows writing a dump. The dumpArchive group preserves stable files subject to explicit limits. |
| Recorder heartbeat, worker exits, monotonic clock and bounded boot snapshot | Continuously / per boot | Separates recorder failure from host failure where possible. Startup configuration still requires a real reboot test. Flushes reduce buffered loss but cannot guarantee the last SSD write survives power loss. |

## Direct NVMe query

`Read-NvmeHealth.ps1` uses the documented `IOCTL_STORAGE_QUERY_PROPERTY`, `StorageAdapterProtocolSpecificProperty`, `ProtocolTypeNvme`, `NVMeDataTypeLogPage` path. The only log ID is 0x02 and the request length is fixed at 512 bytes. A zero-access handle is opened for the disk number returned by `Get-Disk`. There is no NVMe command pass-through, write, firmware change or driver installation. `RetainAsynEvent=1` preserves pending asynchronous notifications. Header and payload bounds are validated before decoding. All-zero payloads are unavailable, not a healthy result. On access/driver failure the error and native Windows code are recorded, without falling back to invasive commands.

Unsafe shutdown count increases when the controller loses power without its shutdown notification. This supports an unclean shutdown history but cannot distinguish AC interruption, PSU protection, motherboard power control, a forced reset or other causes. Media errors and error-log counts are distinct; neither zero count proves the SSD or power supply fault-free. Warning temperature duration can be zero if the controller has no applicable configured threshold, so zero is not a universal proof that overheating never happened.

The nvmeErrors group now reads Identify Controller capabilities and the supported error-entry array (log 0x01, up to 256 entries). Raw error bytes and decoded nonzero entries are retained. Entries have no wall-clock timestamps. NVMe thermal-management extension fields after byte 215 are preserved in raw form but not decoded.

API references: [Windows NVMe queries](https://learn.microsoft.com/en-us/windows/win32/fileio/working-with-nvme-devices), [health page fields](https://learn.microsoft.com/en-us/windows/win32/api/nvme/ns-nvme-nvme_health_info_log), [retain asynchronous events](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntddstor/ns-ntddstor-storage_protocol_data_subvalue_get_log_page).

## Remaining improvements, in priority order

1. Validate boot recovery at the next planned reboot, including fresh samples, event checkpoint continuation and incident creation. Do not deliberately cut power as a test.
2. Check whether a small dump should be changed to an automatic/kernel dump for software/driver failures. Preserve completed dumps against overwrite. Changing configuration is a separate administrative operation, not performed by the recorder. [Microsoft dump comparison](https://learn.microsoft.com/en-us/windows-hardware/drivers/debugger/varieties-of-kernel-mode-dump-files).
3. Validate motherboard sensor labels/scale factors against model-specific evidence. Keep raw IDs and library names until then; never infer memory overvoltage from a generic DIMM label alone.
4. Compare incident windows using sensor changes, WHEA/PCIe/storage errors, GPU counters and NVMe counter deltas. Report supporting/conflicting evidence and gaps instead of uncalibrated failure probabilities.
5. Implement disk-space alerts and an explicit retention/archive policy; current verbose JSON grows without automatic deletion. A full disk defeats evidence collection.
6. If software evidence remains silent, capture power independently of the failing PC. Input AC disturbances require an appropriate power-quality instrument. Output rails and ATX control/status signals require a suitable isolated, independently powered acquisition setup and qualified handling. No direct mains probing instructions are part of this project.

For external acquisition, the useful channels are AC input, DC rails, standby power, PS_ON# and PWR_OK. Their timing can help distinguish motherboard-requested shutdown from loss of valid PSU output, but a collapsing output alone does not distinguish an internal PSU fault from excessive downstream load/short circuit. A PC-powered USB logger alone can fail at the same instant as the PC. An ordinary slow wattmeter does not replace transient capture.

The SF-L documentation lists electrical protections but does not document a software telemetry connection or a readable protection-trip history. This is a documented-interface limitation, not a claim that all PSUs lack telemetry. [Corsair SF-L manual](https://assets.corsair.com/image/upload/documents/49_002592_AB_WW_SFL_Series_QSG_Web_F.pdf), [Intel ATX design guide](https://www.intel.com/content/www/us/en/content-details/336521/atx-version-3-multi-rail-desktop-platform-power-supply-design-guide.html).

The extended collection release implements process/performance/driver/device/power/reliability providers, default-on automatic dump configuration, dump/WER archives, disk-space warnings and independent opt-outs. See [current settings](collection-settings.md); historical recommendations above remain subject to capability and reboot validation.
