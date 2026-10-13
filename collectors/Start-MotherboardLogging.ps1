param([int]$MaxSamples = 0, [string]$LogRoot, [string]$LibraryDirectory, [ValidateRange(1000,5000)][int]$IntervalMilliseconds=2000)
$ErrorActionPreference = 'Stop'
if (-not $LogRoot) { $LogRoot = Join-Path $PSScriptRoot 'sensor-logs' }
if (-not $LibraryDirectory) { $LibraryDirectory = Join-Path $PSScriptRoot 'library' }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Motherboard sensors require an administrator or SYSTEM process.' }
[void][IO.Directory]::CreateDirectory($LogRoot)
$mutex = [Threading.Mutex]::new($false, 'Global\Codex-MotherboardLogging-20261012')
$locked = $false
$computer = $null
$writer = $null
$day = ''
$sequence = 0
$session = [guid]::NewGuid().ToString()
$uptime = [Diagnostics.Stopwatch]::StartNew()
function Read-BoardHardware($hardware) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $hardware.Update()
    $sampleTime = [DateTimeOffset]::Now.ToString('o')
    foreach ($sensor in $hardware.Sensors) {
        if ($sensor.SensorType.ToString() -notin @('Voltage','Temperature','Fan','Control')) { continue }
        $value = $null
        if ($null -ne $sensor.Value) { $value = [double]$sensor.Value }
        [pscustomobject]@{
            hardware=$hardware.Name; hardwareType=$hardware.HardwareType.ToString()
            id=$sensor.Identifier.ToString(); index=$sensor.Index; name=$sensor.Name
            type=$sensor.SensorType.ToString(); value=$value; available=($null -ne $value)
            time=$sampleTime; hardwareReadMs=$timer.ElapsedMilliseconds
            labelQuality='Library label; board-specific wiring not independently verified'
        }
    }
    foreach ($sub in $hardware.SubHardware) { Read-BoardHardware $sub }
}
try {
    try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { throw 'Motherboard logger is already running.' }
    if (Test-Path -LiteralPath (Join-Path $LogRoot 'STOP-BOARD')) { throw 'STOP-BOARD exists; logger will not start.' }
    [void][Reflection.Assembly]::LoadFrom((Join-Path $LibraryDirectory 'LibreHardwareMonitorLib.dll'))
    if (-not [LibreHardwareMonitor.PawnIo.PawnIo]::IsInstalled) { throw 'The existing PawnIO driver is required.' }
    # A new Computer has empty settings. Fan control remains Undefined.
    # Never load GUI settings or call SetDefault/SetSoftware on a control.
    $computer = [LibreHardwareMonitor.Hardware.Computer]::new()
    $computer.IsMotherboardEnabled = $true
    $computer.Open()
    while (-not (Test-Path -LiteralPath (Join-Path $LogRoot 'STOP-BOARD'))) {
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $readings = @($computer.Hardware | ForEach-Object { Read-BoardHardware $_ })
        $usable = @($readings | Where-Object { $_.hardwareType -eq 'SuperIO' -and $_.available -and $_.type -in @('Voltage','Temperature','Fan') })
        if (-not $usable.Count) { throw 'No usable SuperIO voltage, temperature or fan sensors were obtained.' }
        $record = [ordered]@{
            schemaVersion=1; time=[DateTimeOffset]::Now.ToString('o'); session=$session
            sequence=$sequence; monotonicMs=$uptime.ElapsedMilliseconds; sampleDurationMs=$timer.ElapsedMilliseconds
            libraryVersion=$computer.GetType().Assembly.GetName().Version.ToString()
            sensors=$readings
        }
        $today = Get-Date -Format 'yyyyMMdd'
        if ($today -ne $day) {
            if ($writer) { $writer.Dispose() }
            $stream = [IO.FileStream]::new((Join-Path $LogRoot "board-auto-$today.jsonl"), [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite, 4096, [IO.FileOptions]::WriteThrough)
            $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false))
            $day = $today
        }
        $record.monotonicTicks=[Diagnostics.Stopwatch]::GetTimestamp()
        $record.monotonicFrequency=[Diagnostics.Stopwatch]::Frequency
        $record.intervalMilliseconds=$IntervalMilliseconds
        $writer.WriteLine(($record | ConvertTo-Json -Depth 6 -Compress))
        $writer.Flush()
        $writer.BaseStream.Flush($true)
        $sequence++
        if ($MaxSamples -gt 0 -and $sequence -ge $MaxSamples) { break }
        Start-Sleep -Milliseconds ([Math]::Max(1, $IntervalMilliseconds - [int]$timer.ElapsedMilliseconds))
    }
} catch {
    [IO.File]::WriteAllText((Join-Path $LogRoot 'board-auto-last-error.json'), (@{time=[DateTimeOffset]::Now.ToString('o'); error=$_.Exception.ToString(); session=$session} | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
    Write-Error $_ -ErrorAction Continue
    exit 1
} finally {
    if ($writer) { $writer.Dispose() }
    if ($computer) { $computer.Close() }
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
