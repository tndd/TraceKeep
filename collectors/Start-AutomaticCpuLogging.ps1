param([int]$MaxSamples = 0, [switch]$Probe, [string]$LogRoot, [string]$LibraryDirectory, [ValidateRange(1000,5000)][int]$IntervalMilliseconds=2000)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Log-Storage.ps1')
$root = $LogRoot
if (-not $root) { $root = Join-Path $PSScriptRoot 'sensor-logs' }
$libraryDir = $LibraryDirectory
if (-not $libraryDir) { $libraryDir = Join-Path (Split-Path $PSScriptRoot) 'work\diagnostics\LibreHardwareMonitor' }
[void][IO.Directory]::CreateDirectory($root)
$mutex = [Threading.Mutex]::new($false, 'Global\Codex-AutomaticCpuLogging-20261010')
$locked = $false
$computer = $null
$writer = $null
$day = ''
$sample = 0
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'CPU sensor reading requires an elevated process. Use Enable-AutomaticCpuLogging.ps1 from an administrator terminal once.'
}
function Collect-Sensors($hardware) {
    $hardware.Update()
    foreach ($sensor in $hardware.Sensors) {
        if ($null -ne $sensor.Value) {
            [pscustomobject]@{hardware=$hardware.Name; id=$sensor.Identifier.ToString(); name=$sensor.Name; type=$sensor.SensorType.ToString(); value=[double]$sensor.Value}
        }
    }
    foreach ($sub in $hardware.SubHardware) { Collect-Sensors $sub }
}
try {
    try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { exit 0 }
    if (Test-Path -LiteralPath (Join-Path $root 'STOP-CPU')) { exit 0 }
    [void][Reflection.Assembly]::LoadFrom((Join-Path $libraryDir 'LibreHardwareMonitorLib.dll'))
    if (-not [LibreHardwareMonitor.PawnIo.PawnIo]::IsInstalled) { throw 'The signed PawnIO driver is not installed.' }
    $computer = [LibreHardwareMonitor.Hardware.Computer]::new()
    $computer.IsCpuEnabled = $true
    # CPU only: do not change fan control or add a second motherboard/SMART poller.
    $session = [guid]::NewGuid().ToString()
    if(-not $Probe){Write-DiagnosticProgress $root 'cpu' $session $sample $writer -Stage 'initializing'}
    $computer.Open()
    while (-not (Test-Path -LiteralPath (Join-Path $root 'STOP-CPU'))) {
        $clock = [Diagnostics.Stopwatch]::StartNew()
        if(-not $Probe){Write-DiagnosticProgress $root 'cpu' $session $sample $writer}
        $readings = @($computer.Hardware | ForEach-Object { Collect-Sensors $_ })
        $temperatures = @($readings | Where-Object { $_.type -eq 'Temperature' -and $_.value -gt 0 -and $_.value -lt 150 })
        if ($temperatures.Count -eq 0) { throw 'No usable CPU temperature was obtained. Automatic CPU logging has not been verified.' }
        $record = [ordered]@{time=[DateTimeOffset]::Now.ToString('o'); session=$session; sequence=$sample; sampleDurationMs=$clock.ElapsedMilliseconds; sensors=$readings}
        $record.monotonicTicks=[Diagnostics.Stopwatch]::GetTimestamp()
        $record.monotonicFrequency=[Diagnostics.Stopwatch]::Frequency
        $record.intervalMilliseconds=$IntervalMilliseconds
        if ($Probe) {
            $record | ConvertTo-Json -Depth 6
        } else {
            $today = Get-Date -Format 'yyyyMMdd'
            if ($today -ne $day) {
                Close-DiagnosticLogWriter $writer
                $writer = $null
                $writer = Open-DiagnosticLogWriter (Join-Path $root "cpu-auto-$today.jsonl")
                $day = $today
            }
            Write-DiagnosticLogLine $writer ($record | ConvertTo-Json -Depth 6 -Compress)
        }
        $sample++
        if ($MaxSamples -gt 0 -and $sample -ge $MaxSamples) { break }
        Start-Sleep -Milliseconds ([Math]::Max(1, $IntervalMilliseconds - [int]$clock.ElapsedMilliseconds))
    }
} catch {
    $failure = @{time=[DateTimeOffset]::Now.ToString('o'); status='CPU logging failed'; error=$_.Exception.ToString(); pid=$PID} | ConvertTo-Json -Compress
    [IO.File]::WriteAllText((Join-Path $root 'cpu-auto-last-error.json'), $failure, [Text.UTF8Encoding]::new($false))
    Write-Error $_ -ErrorAction Continue
    exit 1
} finally {
    Close-DiagnosticLogWriter $writer
    if ($computer) { $computer.Close() }
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
