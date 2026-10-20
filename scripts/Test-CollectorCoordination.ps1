$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot
$testRoot=Join-Path $env:TEMP ('tracekeep-lock-test-'+[guid]::NewGuid().ToString('N'))
Copy-Item -LiteralPath (Join-Path $repo 'collectors') -Destination $testRoot -Recurse
$script = Join-Path $testRoot 'Start-ContinuousDiagnostics.ps1'
$logRoot = Join-Path $testRoot 'sensor-logs'
$legacyName='Local\TraceKeep-Test-Legacy-'+[guid]::NewGuid().ToString('N')
$currentName='Local\TraceKeep-Test-Current-'+[guid]::NewGuid().ToString('N')
$source=[IO.File]::ReadAllText($script)
$source=$source.Replace('Global\PCDiagnostics-Activity-v2',$currentName).Replace("('Local\CodexPCDiagnostics-' + `$env:USERNAME + '-20261010')",("'"+$legacyName+"'"))
# Fail before hardware access even if a future regression bypasses the locks.
$source=$source.Replace('$root = $LogRoot',("function Get-CimInstance { throw 'Lock test reached a hardware provider' }`r`n"+'$root = $LogRoot'))
[IO.File]::WriteAllText($script,$source)
$mutex = [Threading.Mutex]::new($false, $legacyName)
$locked = $false
$child = $null
try {
    try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { throw 'Could not acquire the isolated test lock.' }
    $before = @(Get-ChildItem -LiteralPath $logRoot -Filter '*.jsonl' -ErrorAction SilentlyContinue).Count
    $child = Start-Process powershell.exe -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $script + '" -MaxSamples 1') -WindowStyle Hidden -PassThru -RedirectStandardError (Join-Path $testRoot 'stderr.txt')
    $null = $child.Handle
    if (-not $child.WaitForExit(10000)) { throw 'Collector did not exit while the legacy lock was held.' }
    if ($child.ExitCode -ne 0) { throw ('Collector lock handoff did not exit cleanly: '+(Get-Content (Join-Path $testRoot 'stderr.txt') -Raw)) }
    $after = @(Get-ChildItem -LiteralPath $logRoot -Filter '*.jsonl' -ErrorAction SilentlyContinue).Count
    if ($after -ne $before) { throw 'A duplicate collector produced a log.' }
    Write-Output 'PASS: existing collector lock prevents duplicate recording.'
} finally {
    if ($child) { $child.Dispose() }
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
