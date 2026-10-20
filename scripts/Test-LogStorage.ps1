$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot
. (Join-Path $repo 'collectors\Evidence-Core.ps1')
. (Join-Path $repo 'collectors\Extended-Evidence.ps1')
function Assert($condition,$message){if(-not $condition){throw $message}}
$root=Join-Path $env:TEMP ('pcdiag-storage-test-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$utf8=[Text.UTF8Encoding]::new($false)

# A crash fragment must never swallow the replayed event or advance past a
# newly unreadable record. Exercise the real event commit function.
$state=Join-Path $root 'state';[void][IO.Directory]::CreateDirectory($state)
$eventPath=Join-Path $root ('events-'+(Get-Date -Format yyyyMMdd)+'.jsonl')
$fragment='{"xml":"interrupted'
[IO.File]::WriteAllText($eventPath,$fragment,$utf8)
$script:fakeEvent=[pscustomobject]@{TimeCreated=(Get-Date);RecordId=46L;ProviderName='Synthetic';Id=19;Level=3}
$script:fakeEvent|Add-Member ScriptMethod ToXml {'<Event>synthetic</Event>'}
function Get-WinEvent {param($LogName,$MaxEvents,$ErrorAction);return $script:fakeEvent}
function Read-EvidenceEvents {param($channel,$xpath,$limit);return @($script:fakeEvent)}
$null=Sync-EvidenceChannel $root $state 'System'
$lines=[IO.File]::ReadAllLines($eventPath)
Assert ($lines.Count -eq 2 -and $lines[0] -ceq $fragment) 'Interrupted bytes were lost or joined to the replay'
Assert (($lines[1]|ConvertFrom-Json).recordId -eq 46 -and (Get-EvidenceCursor $state 'System').recordId -eq 46) 'Checkpoint advanced without a readable replay'

# No cache commit on failure, and every local date starts with a full result.
$realAppend=${function:Add-EvidenceRecord}
function Add-EvidenceRecord {param($root,$kind,$value,$Day);throw 'synthetic append failure'}
$hashes=@{};$result=@{status='ok';data=@{value=123};issues=@()}
$now=[DateTimeOffset]::Now
try {$null=Add-ExtendedResult $root 'performance' $result $hashes $now 1 $now}catch{}
Assert (-not $hashes.ContainsKey('performance')) 'Failed append poisoned the unchanged cache'
Set-Item Function:\Add-EvidenceRecord $realAppend
$first=Add-ExtendedResult $root 'performance' $result $hashes $now 1 $now
$same=Add-ExtendedResult $root 'performance' $result $hashes $now 1 $now
$next=Add-ExtendedResult $root 'performance' $result $hashes $now 1 ($now.AddDays(1))
Assert ($first.ContainsKey('result') -and -not $first.unchanged -and $same.unchanged -and -not $same.ContainsKey('result') -and $next.ContainsKey('result') -and -not $next.unchanged) 'Daily reference boundary or retry lost the full result'

# Policy uses calendar dates, not a sliding 48-hour duration.
$logs=Join-Path $root 'logs';[void][IO.Directory]::CreateDirectory($logs)
$calendar=Get-Date
$text=("{`"value`":123,`"label`":`""+([char]0x6e29)+([char]0x5ea6)+"`"}`n")*10000+'{partial'
foreach($age in @(0,1,2)){
    $path=Join-Path $logs ('cpu-auto-'+$calendar.AddDays(-$age).ToString('yyyyMMdd')+'.jsonl')
    [IO.File]::WriteAllText($path,$text,$utf8)
}
$old=Join-Path $logs ('cpu-auto-'+$calendar.AddDays(-2).ToString('yyyyMMdd')+'.jsonl')
$expected=(Get-FileHash -LiteralPath $old).Hash.ToLowerInvariant()
$rows=@(Invoke-DiagnosticLogMaintenance $logs -Now $calendar)
Assert ($rows.Count -eq 1 -and $rows[0].status -eq 'compressed' -and -not(Test-Path -LiteralPath $old) -and (Test-Path -LiteralPath ($old+'.gz'))) 'Calendar retention compressed a recent day or missed an old one'
Test-DiagnosticGzip ($old+'.gz') $expected
Assert (([IO.File]::ReadAllText($old+'.gz.sha256')).Trim() -eq $expected) 'Missing durable integrity receipt'
$archiveBytes=[IO.File]::ReadAllBytes($old+'.gz')
$corrupt=Join-Path $root 'corrupt.jsonl.gz'
$damaged=$archiveBytes.Clone();$damaged[$damaged.Length-8]=$damaged[$damaged.Length-8] -bxor 255
[IO.File]::WriteAllBytes($corrupt,$damaged)
$failed=$false;try {Test-DiagnosticGzip $corrupt $expected}catch{$failed=$true}
Assert $failed 'Corrupt gzip CRC was accepted'
[IO.File]::WriteAllBytes($corrupt,$archiveBytes[0..($archiveBytes.Length-6)])
$failed=$false;try {Test-DiagnosticGzip $corrupt $expected}catch{$failed=$true}
Assert $failed 'Truncated gzip footer was accepted'
$tail=Join-Path $root 'tail.jsonl'
$copied=Copy-EvidenceTail ($old+'.gz') $tail 1024
Assert ($copied.tailLimited -and ([IO.File]::ReadAllText($tail)).EndsWith("`n") -and -not([IO.File]::ReadAllText($tail)).Contains('partial')) 'Gzip incident tail lost its bounds or included a partial row'
# Compare ring-buffer output against the exact raw tail at several wrap sizes.
$rawBytes=$utf8.GetBytes($text)
foreach($limit in @(1,24,65535,65536,70000,1000000)){
    $tailBytes=Read-DiagnosticLogTail ($old+'.gz') $limit
    $start=[Math]::Max(0,$rawBytes.Length-$limit)
    $wanted=New-Object byte[] ($rawBytes.Length-$start)
    [Array]::Copy($rawBytes,$start,$wanted,0,$wanted.Length)
    Assert ([Convert]::ToBase64String($tailBytes.bytes) -ceq [Convert]::ToBase64String($wanted)) 'Gzip ring buffer reordered or omitted bytes'
}

# Interrupted archive commit (both copies) resumes without duplicating data.
[IO.File]::WriteAllText($old,$text,$utf8)
$daily=@(Get-DiagnosticDailyLogs $logs 'cpu-auto-')
Assert ($daily.Count -eq 3 -and @($daily|Where-Object Name -EQ ([IO.Path]::GetFileName($old))).Count -eq 1) 'Raw/gzip pair was counted twice'
$null=Compress-DiagnosticLog $old
Assert (-not(Test-Path -LiteralPath $old)) 'Verified interrupted commit did not finish'

# Clock rollback reopens an archived date with all original bytes preserved.
$handle=Open-DiagnosticLogWriter $old
try {Write-DiagnosticLogLine $handle '{"value":"after-clock-rollback"}'}finally{Close-DiagnosticLogWriter $handle}
$restored=[IO.File]::ReadAllText($old)
Assert ($restored.StartsWith($text+"`n") -and $restored.Contains('after-clock-rollback') -and -not(Test-Path -LiteralPath ($old+'.gz'))) 'Clock rollback lost archived data'

# A live writer, including a legacy writer without the gate, must prevent compression.
$handle=Open-DiagnosticLogWriter $old
try {$rows=@(Invoke-DiagnosticLogMaintenance $logs -Now $calendar);Assert ($rows[0].status -eq 'deferred' -and (Test-Path $old)) 'Maintenance compressed an active writer'}finally{Close-DiagnosticLogWriter $handle}
$legacy=[IO.FileStream]::new($old,[IO.FileMode]::Append,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite)
try {$failed=$false;try {$null=Compress-DiagnosticLog $old}catch{$failed=$true};Assert ($failed -and (Test-Path $old)) 'Legacy writer was not excluded'}finally{$legacy.Dispose()}

# Failed validation and corrupt/conflicting archives retain the original.
$realVerify=${function:Test-DiagnosticGzip}
function Test-DiagnosticGzip {param($Path,$ExpectedHash,$Progress);throw 'synthetic verification interruption'}
$failed=$false;try {$null=Compress-DiagnosticLog $old}catch{$failed=$true}
Assert ($failed -and (Test-Path $old) -and -not(Test-Path ($old+'.gz'))) 'Failed verification deleted or published data'
Set-Item Function:\Test-DiagnosticGzip $realVerify
$null=Compress-DiagnosticLog $old
Assert (-not(Test-Path $old)) 'Stale partial did not recover'
[IO.File]::WriteAllText($old,'conflicting bytes',$utf8)
$failed=$false;try {$null=Compress-DiagnosticLog $old}catch{$failed=$true}
Assert ($failed -and ([IO.File]::ReadAllText($old) -eq 'conflicting bytes') -and (Test-Path ($old+'.gz'))) 'Conflicting archive silently replaced an original'

# Fully isolated maintenance worker: no production mutex, tasks or logs.
$sandbox=Join-Path $root 'worker';$workerLogs=Join-Path $sandbox 'logs'
[void][IO.Directory]::CreateDirectory($workerLogs)
$scripts=Join-Path $sandbox 'collectors'
Copy-Item -LiteralPath (Join-Path $repo 'collectors') -Destination $scripts -Recurse
$start=Join-Path $scripts 'Start-LogMaintenance.ps1'
$source=[IO.File]::ReadAllText($start).Replace('Global\PCDiagnostics-LogMaintenance-v1',('Local\PCDiagnostics-StorageTest-'+[guid]::NewGuid().ToString('N')))
[IO.File]::WriteAllText($start,$source,$utf8)
$sample=Join-Path $workerLogs ('activity-'+$calendar.AddDays(-3).ToString('yyyyMMdd')+'.jsonl')
[IO.File]::WriteAllText($sample,"{`"value`":1}`n",$utf8)
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $start -LogRoot $workerLogs -MaxPasses 1
Assert ($LASTEXITCODE -eq 0 -and (Test-Path ($sample+'.gz')) -and (Test-Path (Join-Path $sandbox 'log-maintenance.json'))) 'Isolated maintenance worker failed'
# Boot snapshots must find archived days even after a long recording gap.
$boot=[DateTimeOffset]::Now.AddMinutes(-5)
$bundle=New-IncidentBundle $workerLogs $sandbox $boot @{settings=@{}}
$bundleManifest=Get-Content -LiteralPath (Join-Path $bundle 'manifest.json') -Raw|ConvertFrom-Json
Assert ((Test-Path (Join-Path $bundle ([IO.Path]::GetFileName($sample)))) -and @($bundleManifest.files|Where-Object {$_.source.EndsWith('.gz')}).Count -eq 1) 'Boot snapshot missed archived history'
Write-Output 'PASS: interrupted append replay, cache commit ordering, daily full records, gzip retention/integrity, bounded incident tails, interrupted compression, active writers, clock rollback and isolated maintenance.'
