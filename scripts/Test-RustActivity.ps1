param([string]$Worker,[string]$Cli)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot
if(-not $Worker){$Worker=Join-Path $repo 'recorder\target\release\tracekeep-worker.exe'}
if(-not $Cli){$Cli=Join-Path $repo 'src-tauri\target\release\pcdiag.exe'}
$root=Join-Path $env:TEMP ('tracekeep-activity-test-'+[guid]::NewGuid().ToString('N'))
$logs=Join-Path $root 'logs';[void][IO.Directory]::CreateDirectory($logs)
$utf8=[Text.UTF8Encoding]::new($false)
$settings=Join-Path $root 'settings.json'
[IO.File]::WriteAllText($settings,'{"schemaVersion":1,"modules":{"activity":{"enabled":true,"intervalSeconds":1}}}',$utf8)
function Assert($v,$message){if(-not $v){throw $message}}
function Launch([int]$Samples=1){
    $p=Start-Process $Worker -ArgumentList ('--module activity --log-root "'+$logs+'" --settings "'+$settings+'" --run-id synthetic-activity --samples '+$Samples) -WindowStyle Hidden -PassThru -RedirectStandardError (Join-Path $root 'stderr.txt')
    $null=$p.Handle;return $p
}
function Finish($p){
    try{Assert ($p.WaitForExit(90000)) 'Activity timed out';Assert ($p.ExitCode -eq 0) ('Activity failed: '+(Get-Content -Encoding UTF8 (Join-Path $root 'stderr.txt') -Raw))}finally{if(-not $p.HasExited){$p.Kill();$null=$p.WaitForExit(5000)};$p.Dispose()}
}
# Run on an isolated CI host: production activity must never be stopped by tests.
foreach($name in @('Global\PCDiagnostics-Activity-v2',('Local\CodexPCDiagnostics-'+$env:USERNAME+'-20261010'))){
    $mutex=[Threading.Mutex]::new($false,$name);$locked=$false
    try{
        try{$locked=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true}
        Assert $locked 'An activity collector is already running; use an isolated host for this test'
        Finish (Launch)
        Assert (@(Get-ChildItem $logs -Filter '*.jsonl').Count -eq 0) 'Legacy/current mutex allowed duplicate recording'
    }finally{if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()}
}
$start=[DateTimeOffset]::Now.AddSeconds(-1)
Finish (Launch 6)
$file=Get-ChildItem $logs -Filter 'activity-*.jsonl'|Select-Object -First 1
$rows=@(Get-Content -Encoding UTF8 $file.FullName|ConvertFrom-Json)
Assert ($rows.Count -eq 6) 'Missing activity samples'
Assert ($rows[-1].sequence -eq 5 -and @($rows.session|Select-Object -Unique).Count -eq 1) 'Invalid sequence/session'
foreach($row in $rows){
    Assert ($row.cpuLoadPercent -ge 0 -and $row.cpuLoadPercent -le 100) 'CPU sample unavailable'
    Assert ($row.availableMemoryMB -gt 0 -and $row.committedMemoryPercent -ge 0) 'Memory sample unavailable'
    Assert ($row.intervalMilliseconds -eq 1000 -and $row.monotonicFrequency -gt 0) 'Missing sample timing'
    Assert ($row.errors.Count -eq 0) 'Unexpected provider error'
}
Assert (@($rows[0..4].availableMemoryMB|Select-Object -Unique).Count -eq 1) 'Memory cache cadence changed'
$progress=@(Get-Content -Encoding UTF8 (Join-Path $logs ('progress-'+$file.Name))|ConvertFrom-Json)
Assert ($progress.Count -eq 7 -and $null -eq $progress[0].previousCommit) 'Missing pre-provider progress'
Assert ($progress[-1].previousCommit.offset -gt 0 -and $progress[-1].sequence -eq 5) 'Missing committed offset'
$sessions=@(Get-Content -Encoding UTF8 (Get-ChildItem $logs -Filter 'sessions-*.jsonl').FullName|ConvertFrom-Json)
Assert ($sessions[0].lastBoot -and $sessions[0].osVersion -and $sessions[-1].samples -eq 6) 'Session metadata missing'

# A forced termination leaves independently committed rows intact; restart uses
# a new session and recovers a torn tail without rewriting the preserved prefix.
$p=Launch 0
try{
    $deadline=(Get-Date).AddSeconds(30)
    do{Start-Sleep -Milliseconds 200;$count=@(Get-Content -Encoding UTF8 $file.FullName|ForEach-Object{try{$_|ConvertFrom-Json -ErrorAction Stop}catch{}}).Count}while($count -lt 8 -and (Get-Date) -lt $deadline)
    Assert ($count -ge 8) 'Continuous activity did not progress'
    $p.Kill();$null=$p.WaitForExit(5000)
}finally{if(-not $p.HasExited){$p.Kill();$null=$p.WaitForExit(5000)};$p.Dispose()}
[IO.File]::AppendAllText($file.FullName,'{"syntheticTornTail":',$utf8)
$prefix=[IO.File]::ReadAllBytes($file.FullName)
Finish (Launch 2)
$all=[IO.File]::ReadAllBytes($file.FullName)
for($i=0;$i -lt $prefix.Length;$i++){Assert ($prefix[$i] -eq $all[$i]) 'Existing prefix changed'}

# Use an explicit isolated source root, including after compression.
$source=Join-Path $root 'PCDiagnostics';[void][IO.Directory]::CreateDirectory($source)
[IO.File]::WriteAllText((Join-Path $source 'sources.json'),(@{sensorRoot=$logs;activityRoot=$logs}|ConvertTo-Json),$utf8)
$prior=$env:ProgramData
try{
    $env:ProgramData=$root;$end=[DateTimeOffset]::Now.AddSeconds(1)
    $raw=(& $Cli history $start.ToString('o') $end.ToString('o')|ConvertFrom-Json)
    Assert ($LASTEXITCODE -eq 0 -and $raw.sources.activityRoot -eq $logs) 'Wrong history source'
    Assert ($raw.streams.activity.returnedRows -ge 10 -and $raw.streams.activity.invalidLines -ge 1) 'Torn-tail history recovery failed'
    foreach($path in Get-ChildItem $logs -Filter '*.jsonl'){
        $sourceStream=[IO.File]::OpenRead($path.FullName);$output=[IO.File]::Create($path.FullName+'.gz');$gzip=[IO.Compression.GZipStream]::new($output,[IO.Compression.CompressionMode]::Compress)
        try{$sourceStream.CopyTo($gzip)}finally{$sourceStream.Dispose();$gzip.Dispose();$output.Dispose()}
        Move-Item -LiteralPath $path.FullName -Destination ($path.FullName+'.preserved')
    }
    $archived=(& $Cli history $start.ToString('o') $end.ToString('o')|ConvertFrom-Json)
    Assert (($raw.streams.activity|ConvertTo-Json -Depth 30 -Compress) -eq ($archived.streams.activity|ConvertTo-Json -Depth 30 -Compress)) 'Archived activity differs'
    Assert (($raw.streams.activityProgress|ConvertTo-Json -Depth 30 -Compress) -eq ($archived.streams.activityProgress|ConvertTo-Json -Depth 30 -Compress)) 'Archived progress differs'
}finally{$env:ProgramData=$prior}
[IO.File]::WriteAllText((Join-Path $logs 'STOP'),'synthetic stop',$utf8)
Finish (Launch)
Assert (@(Get-ChildItem $logs -Filter 'activity-*.jsonl').Count -eq 0) 'Stop marker allowed collection'
Remove-Item -LiteralPath (Join-Path $logs 'STOP')
[IO.File]::WriteAllText($settings,'{"schemaVersion":1,"modules":{"activity":{"enabled":false,"intervalSeconds":1}}}',$utf8)
Finish (Launch)
Assert (@(Get-ChildItem $logs -Filter 'activity-*.jsonl').Count -eq 0) 'Disabled collector wrote samples'
Write-Output 'PASS: native activity, legacy ownership, cadence, durable progress, forced termination, torn-tail preservation, opt-out and raw/gzip history'
