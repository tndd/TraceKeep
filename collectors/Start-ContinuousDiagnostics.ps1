param([int]$MaxSamples = 0, [string]$LogRoot, [ValidateRange(1000,5000)][int]$IntervalMilliseconds=2000)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Log-Storage.ps1')
. (Join-Path $PSScriptRoot 'Read-NvidiaDiagnostics.ps1')
$root = $LogRoot
if (-not $root) { $root = Join-Path $PSScriptRoot 'sensor-logs' }
[void][IO.Directory]::CreateDirectory($root)
$mutex = [Threading.Mutex]::new($false, 'Global\PCDiagnostics-Activity-v2')
$locked = $false
$legacyMutex = [Threading.Mutex]::new($false, ('Local\CodexPCDiagnostics-' + $env:USERNAME + '-20261010'))
$legacyLocked = $false
$writers = @{}
$utf8 = [Text.UTF8Encoding]::new($false)
function Write-DurableLine([string]$kind, [string]$line) {
    $day = Get-Date -Format 'yyyyMMdd'
    $key = "$kind-$day"
    if (-not $writers.ContainsKey($key)) {
        foreach ($old in @($writers.Keys | Where-Object { $_ -like "$kind-*" })) {
            Close-DiagnosticLogWriter $writers[$old]
            $writers.Remove($old)
        }
        $path = Join-Path $root "$key.jsonl"
        $writers[$key] = Open-DiagnosticLogWriter $path
    }
    Write-DiagnosticLogLine $writers[$key] $line
}
function Write-Record([string]$kind, $record) {
    Write-DurableLine $kind ($record | ConvertTo-Json -Compress -Depth 8)
}
try {
    try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { exit 0 }
    # Coordinate with the installed first-generation recorder during migration.
    try { $legacyLocked = $legacyMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $legacyLocked = $true }
    if (-not $legacyLocked) { exit 0 }
    if (Test-Path -LiteralPath (Join-Path $root 'STOP')) { exit 0 }
    $session = [guid]::NewGuid().ToString()
    $gpuExe = Get-ChildItem -Path 'C:\Windows\System32\DriverStore\FileRepository\nv*\nvidia-smi.exe' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
    $os = Get-CimInstance Win32_OperatingSystem
    Write-Record 'sessions' ([ordered]@{time=[DateTimeOffset]::Now.ToString('o'); session=$session; pid=$PID; intervalSeconds=($IntervalMilliseconds/1000); lastBoot=$os.LastBootUpTime.ToString('o'); osVersion=$os.Version; gpuReader=$gpuExe; logRoot=$root; note='No AC waveform or internal PSU protection measurements are available.'})
    $nextSizeCheck = (Get-Date).AddMinutes(1)
    $memory = $null
    $iteration = 0
    $sizeWarningSent = $false
    while (-not (Test-Path -LiteralPath (Join-Path $root 'STOP'))) {
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $now = [DateTimeOffset]::Now
        $record = [ordered]@{time=$now.ToString('o'); session=$session; sequence=$iteration; cpuLoadPercent=$null; availableMemoryMB=$null; committedMemoryPercent=$null; diskReadBytesPerSecond=$null; diskWriteBytesPerSecond=$null; diskQueueLength=$null; gpu=$null; errors=@()}
        try {
            $cpu = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'"
            $record.cpuLoadPercent = $cpu.PercentProcessorTime
            if ($iteration % 5 -eq 0) { $memory = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory }
            $record.availableMemoryMB = $memory.AvailableMBytes
            $record.committedMemoryPercent = $memory.PercentCommittedBytesInUse
            $disk = Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk -Filter "Name='_Total'"
            $record.diskReadBytesPerSecond = $disk.DiskReadBytesPersec
            $record.diskWriteBytesPerSecond = $disk.DiskWriteBytesPersec
            $record.diskQueueLength = $disk.CurrentDiskQueueLength
        } catch { $record.errors += $_.Exception.Message }
        if ($gpuExe) {
            try {
                $record.gpu = @(Read-NvidiaDiagnostics -Executable $gpuExe)
                $record.gpuSampleTime = [DateTimeOffset]::Now.ToString('o')
            } catch { $record.errors += $_.Exception.Message }
        }
        $record.sampleDurationMs = $timer.ElapsedMilliseconds
        $record.monotonicTicks=[Diagnostics.Stopwatch]::GetTimestamp()
        $record.monotonicFrequency=[Diagnostics.Stopwatch]::Frequency
        $record.intervalMilliseconds=$IntervalMilliseconds
        Write-Record 'activity' $record
        if ((Get-Date) -ge $nextSizeCheck) {
            $total = (Get-ChildItem -LiteralPath $root -Filter '*.jsonl' | Measure-Object Length -Sum).Sum
            if ($total -ge 2GB -and -not $sizeWarningSent) {
                Write-Record 'sessions' @{time=[DateTimeOffset]::Now.ToString('o'); session=$session; status='Logs exceed 2 GiB; logging continues, no files deleted'; bytes=$total}
                $sizeWarningSent = $true
            }
            $nextSizeCheck = (Get-Date).AddMinutes(1)
        }
        $iteration++
        if ($MaxSamples -gt 0 -and $iteration -ge $MaxSamples) { break }
        $delay = [Math]::Max(1, $IntervalMilliseconds - [int]$timer.ElapsedMilliseconds)
        Start-Sleep -Milliseconds $delay
    }
    Write-Record 'sessions' @{time=[DateTimeOffset]::Now.ToString('o'); session=$session; status='Stopped normally'; samples=$iteration}
} catch {
    try { Write-Record 'errors' @{time=[DateTimeOffset]::Now.ToString('o'); error=$_.Exception.ToString()} } catch {}
    exit 1
} finally {
    foreach ($writer in $writers.Values) { Close-DiagnosticLogWriter $writer }
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
    if ($legacyLocked) { $legacyMutex.ReleaseMutex() }
    $legacyMutex.Dispose()
}
