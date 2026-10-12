$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot
$script = Join-Path $repo 'collectors\Start-ContinuousDiagnostics.ps1'
$logRoot = Join-Path $repo 'collectors\sensor-logs'
$mutex = [Threading.Mutex]::new($false, ('Local\CodexPCDiagnostics-' + $env:USERNAME + '-20261010'))
$locked = $false
$child = $null
try {
    try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { throw 'Test requires a clean CI session without an existing collector.' }
    $before = @(Get-ChildItem -LiteralPath $logRoot -Filter '*.jsonl' -ErrorAction SilentlyContinue).Count
    $child = Start-Process powershell.exe -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $script + '" -MaxSamples 1') -WindowStyle Hidden -PassThru
    $null = $child.Handle
    if (-not $child.WaitForExit(10000)) { throw 'Collector did not exit while the legacy lock was held.' }
    if ($child.ExitCode -ne 0) { throw 'Collector lock handoff did not exit cleanly.' }
    $after = @(Get-ChildItem -LiteralPath $logRoot -Filter '*.jsonl' -ErrorAction SilentlyContinue).Count
    if ($after -ne $before) { throw 'A duplicate collector produced a log.' }
    Write-Output 'PASS: existing collector lock prevents duplicate recording.'
} finally {
    if ($child) { $child.Dispose() }
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
