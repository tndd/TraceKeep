param([ValidateSet('all','journal','isolation','durability')][string]$Case='all')
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot
. (Join-Path $repo 'collectors\Evidence-Core.ps1')
. (Join-Path $repo 'collectors\Collection-Settings.ps1')
. (Join-Path $repo 'collectors\Extended-Evidence.ps1')
function Assert($ok,$message){if(-not $ok){throw $message}}
$root=Join-Path $env:TEMP ('tracekeep-prefailure-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$utf8=[Text.UTF8Encoding]::new($false)
$shell=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
if($Case -in @('all','journal')){
    $data=Join-Path $root 'journal';$logs=Join-Path $data 'logs'
    [void][IO.Directory]::CreateDirectory($logs)
    # No real registry or driver access.
    $script:fakeDump=7
    function Get-ItemProperty {param($Path,$ErrorAction);return [pscustomobject]@{CrashDumpEnabled=$script:fakeDump;LogEvent=1}}
    $path=Join-Path $data 'collection-settings.json'
    Save-EvidenceJson $path @{schemaVersion=1;modules=@{processes=@{enabled=$true;intervalSeconds=30}}}
    Save-EvidenceJson (Join-Path $data 'recorder-run.json') @{runId='original-run';collection=@{modules=@{processes=@{enabled=$true;intervalSeconds=30}}}}
    $original=[IO.File]::ReadAllBytes($path);$hashes=@{};$now=[DateTimeOffset]::Now
    $r=Get-ConfigurationJournalEvidence $data
    $first=Add-ExtendedResult $logs configurationJournal $r $hashes $now 1 $now
    $same=Add-ExtendedResult $logs configurationJournal (Get-ConfigurationJournalEvidence $data) $hashes $now 1 $now
    Assert ($first.result -and $same.unchanged) 'Baseline or unchanged reference missing'
    Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) -ceq [Convert]::ToBase64String($original)) 'Observer changed original settings'
    $script:fakeDump=3
    Save-EvidenceJson $path @{schemaVersion=1;modules=@{processes=@{enabled=$false;intervalSeconds=60}}}
    $changed=Add-ExtendedResult $logs configurationJournal (Get-ConfigurationJournalEvidence $data) $hashes $now 1 $now
    Assert (-not $changed.unchanged -and $changed.result.data.crashControl.values.CrashDumpEnabled.value -eq 3) 'Registry drift lost from history'
    $saved=$changed.result.data.files['collection-settings.json'].json|ConvertFrom-Json
    $applied=$changed.result.data.files['recorder-run.json'].json|ConvertFrom-Json
    Assert (-not $saved.modules.processes.enabled -and $applied.collection.modules.processes.enabled) 'Saved and applied settings confused'
    [IO.File]::WriteAllText($path,'{"interrupted":',$utf8)
    $invalid=Get-ConfigurationJournalEvidence $data
    Assert ($invalid.status -eq 'partial' -and $invalid.data.files['collection-settings.json'].status -eq 'invalid') 'Partial settings hidden'
    $null=Add-ExtendedResult $logs configurationJournal $invalid $hashes $now 1 $now
    Remove-Item -LiteralPath $path
    $missing=Get-ConfigurationJournalEvidence $data
    Assert ($missing.data.files['collection-settings.json'].status -eq 'missing') 'Removed settings hidden'
    $null=Add-ExtendedResult $logs configurationJournal $missing $hashes $now 1 $now
    $restart=Add-ExtendedResult $logs configurationJournal $missing @{} $now 1 $now
    $tomorrow=Add-ExtendedResult $logs configurationJournal $missing $hashes $now 1 ($now.AddDays(1))
    Assert ($restart.result -and $tomorrow.result) 'Restart or midnight lost full baseline'
    $daily=Join-Path $logs ('detail-configurationJournal-'+$now.LocalDateTime.ToString('yyyyMMdd')+'.jsonl')
    $rows=@(Get-Content $daily -Encoding UTF8|ConvertFrom-Json)
    Assert ($rows[0].result.data.crashControl.values.CrashDumpEnabled.value -eq 7 -and $rows[2].result.data.crashControl.values.CrashDumpEnabled.value -eq 3) 'Earlier observation overwritten'
    $before=(Get-FileHash $daily).Hash.ToLowerInvariant();$null=Compress-DiagnosticLog $daily
    Test-DiagnosticGzip ($daily+'.gz') $before
    Write-Output 'PASS journal: append-only observations, applied vs saved, drift/missing/invalid, restart/day baselines, gzip integrity'
}
if($Case -in @('all','durability')){
    $logs=Join-Path $root 'durability';[void][IO.Directory]::CreateDirectory($logs)
    $childScript=Join-Path $root 'durable-child.ps1'
    $child=@'
param($Library,$Root)
$ErrorActionPreference='Stop'
. $Library
$writer=Open-DiagnosticLogWriter (Join-Path $Root ('cpu-auto-'+(Get-Date -Format yyyyMMdd)+'.jsonl'))
for($i=0;$i -lt 3;$i++){
    Write-DiagnosticProgress $Root cpu 'synthetic-session' $i $writer
    Write-DiagnosticLogLine $writer (@{time=[DateTimeOffset]::Now.ToString('o');session='synthetic-session';sequence=$i;sensors=@()}|ConvertTo-Json -Compress)
}
Write-DiagnosticProgress $Root cpu 'synthetic-session' 3 $writer
[IO.File]::WriteAllText((Join-Path $Root 'ready'),'ready')
# Simulate a query stuck before it can produce the next sample. No Dispose/Close.
Start-Sleep -Seconds 120
'@
    [IO.File]::WriteAllText($childScript,$child,$utf8)
    $proc=Start-Process $shell -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "'+$childScript+'" -Library "'+(Join-Path $repo 'collectors\Log-Storage.ps1')+'" -Root "'+$logs+'"') -WindowStyle Hidden -PassThru
    $null=$proc.Handle
    try {
        $deadline=(Get-Date).AddSeconds(15)
        while(-not(Test-Path (Join-Path $logs 'ready')) -and (Get-Date) -lt $deadline -and -not $proc.HasExited){Start-Sleep -Milliseconds 100}
        Assert (Test-Path (Join-Path $logs 'ready')) 'Synthetic writer did not become ready'
        $proc.Kill();Assert ($proc.WaitForExit(5000)) 'Synthetic writer did not terminate'
        $path=Join-Path $logs ('cpu-auto-'+(Get-Date -Format yyyyMMdd)+'.jsonl')
        $preserved=[IO.File]::ReadAllBytes($path)
        $rows=@(Get-Content $path|ConvertFrom-Json)
        $progress=@(Get-Content (Join-Path $logs ('progress-cpu-'+(Get-Date -Format yyyyMMdd)+'.jsonl'))|ConvertFrom-Json)
        Assert ($rows.Count -eq 3 -and $progress[-1].sequence -eq 3 -and $progress[-1].previousCommit.offset -eq $preserved.Length) 'Forced termination lost acknowledged data or active-query boundary'
        [IO.File]::AppendAllText($path,'{"sequence":3,"interrupted":',$utf8)
        $writer=Open-DiagnosticLogWriter $path
        try {Write-DiagnosticLogLine $writer '{"sequence":4,"restarted":true}'}finally{Close-DiagnosticLogWriter $writer}
        $after=[IO.File]::ReadAllBytes($path)
        Assert ([Convert]::ToBase64String($after[0..($preserved.Length-1)]) -ceq [Convert]::ToBase64String($preserved)) 'Recovery rewrote committed prefix'
        $lines=[IO.File]::ReadAllLines($path)
        Assert ($lines.Count -eq 5 -and ($lines[-1]|ConvertFrom-Json).sequence -eq 4 -and $lines[3] -ceq '{"sequence":3,"interrupted":') 'Partial tail swallowed next sample or was deleted'
        # A failed OS flush must not advance the acknowledged boundary.
        $fakeStream=New-Object psobject
        $fakeStream|Add-Member ScriptMethod Flush {param($durable);throw 'synthetic flush failure'}
        $fakeWriter=New-Object psobject -Property @{BaseStream=$fakeStream}
        $fakeWriter|Add-Member ScriptMethod WriteLine {param($line)}
        $fakeWriter|Add-Member ScriptMethod Flush {}
        $handle=@{writer=$fakeWriter;lastCommit=@{offset=123}}
        $failed=$false;try {Write-DiagnosticLogLine $handle 'synthetic'}catch{$failed=$true}
        Assert ($failed -and $handle.lastCommit.offset -eq 123) 'Failed flush advanced commit receipt'
        Write-Output 'PASS durability: forced process termination without cleanup, committed prefix, in-flight boundary, partial-tail recovery, failed-flush receipt'
    }finally{if(-not $proc.HasExited){$proc.Kill();$null=$proc.WaitForExit(5000)};$proc.Dispose()}
}
if($Case -in @('all','isolation')){
    $sandbox=Join-Path $root 'isolation';[void][IO.Directory]::CreateDirectory($sandbox)
    Copy-Item -LiteralPath (Join-Path $repo 'collectors') -Destination (Join-Path $sandbox 'collectors') -Recurse
    [void][IO.Directory]::CreateDirectory((Join-Path $sandbox 'management'))
    $data=Join-Path $sandbox 'data';$logs=Join-Path $data 'logs';[void][IO.Directory]::CreateDirectory($logs)
    $c=Get-CollectionDefaults
    foreach($name in $c.modules.Keys){$c.modules[$name].enabled=$false}
    $c.modules.performance.enabled=$true;$c.modules.processes.enabled=$true
    $c.modules.performance.intervalSeconds=1;$c.modules.processes.intervalSeconds=1
    Save-EvidenceJson (Join-Path $data 'collection-settings.json') $c
    $settingsPath=Join-Path $sandbox 'collectors\Collection-Settings.ps1'
    [IO.File]::WriteAllText($settingsPath,([IO.File]::ReadAllText($settingsPath).Replace('else{15}','else{1}')),$utf8)
    $providerPath=Join-Path $sandbox 'collectors\Extended-Evidence.ps1'
    $stubs=@'
function Get-ExtendedEvidence($Module){
    if($Module -eq 'performance'){Start-Sleep -Seconds 120}
    elseif($Module -ne 'processes'){throw 'Unexpected real provider in test'}
    return @{status='ok';issues=@();data=@{synthetic=$true}}
}
function Get-CimInstance {throw 'Hardware access forbidden in simulation'}
'@
    [IO.File]::WriteAllText($providerPath,([IO.File]::ReadAllText($providerPath).Replace('$age -gt 45','$age -gt 3')+"`n"+$stubs),$utf8)
    $coordinator=Join-Path $sandbox 'management\Run-Recorder.ps1'
    $source=[IO.File]::ReadAllText((Join-Path $repo 'management\Run-Recorder.ps1'))
    $source=$source.Replace('Global\PCDiagnostics-Coordinator-v1',('Local\TraceKeep-Coordinator-'+[guid]::NewGuid().ToString('N')))
    $source=$source.Replace('$stallLimit=[Math]::Max(120,3*$freshLimit)','$stallLimit=if($w.module -eq "performance"){6}else{120}')
    [IO.File]::WriteAllText($coordinator,$source,$utf8)
    $extended=Join-Path $sandbox 'collectors\Start-ExtendedLogging.ps1'
    [IO.File]::WriteAllText($extended,([IO.File]::ReadAllText($extended).Replace('Global\PCDiagnostics-Extended-v1',('Local\TraceKeep-Extended-'+[guid]::NewGuid().ToString('N')))),$utf8)
    # All other launched workers are inert. CPU/board/activity are disabled.
    foreach($name in @('Start-EvidenceLogging.ps1','Start-LogMaintenance.ps1')){
        $prefix=if($name -like '*Evidence*'){'evidence'}else{'maintenance'}
        $fake=@'
param($LogRoot,$SettingsPath)
. (Join-Path $PSScriptRoot 'Evidence-Core.ps1')
while(-not(Test-Path (Join-Path (Split-Path $LogRoot) 'STOP-ALL'))){
    Add-EvidenceRecord $LogRoot 'PREFIX' @{time=[DateTimeOffset]::Now.ToString('o');event='heartbeat';errors=@()}
    Start-Sleep -Milliseconds 200
}
'@
        [IO.File]::WriteAllText((Join-Path $sandbox ('collectors\'+$name)),$fake.Replace('PREFIX',$prefix),$utf8)
    }
    $proc=Start-Process $shell -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "'+$coordinator+'" -DataRoot "'+$data+'"') -WindowStyle Hidden -PassThru -RedirectStandardError (Join-Path $sandbox 'stderr.txt')
    $null=$proc.Handle;$seenGap=$false;$children=@{}
    try {
        $deadline=(Get-Date).AddSeconds(40);$restarted=$false
        do {
            Start-Sleep -Milliseconds 500
            $runtime=try {Get-Content (Join-Path $data 'runtime.json') -Raw -ErrorAction Stop|ConvertFrom-Json}catch{$null}
            $coverage=try {Get-Content (Join-Path $data 'coverage.json') -Raw -ErrorAction Stop|ConvertFrom-Json}catch{$null}
            if($runtime){
                foreach($childId in @($runtime.workers|Where-Object pid|Select-Object -ExpandProperty pid)){
                    if(-not $children.ContainsKey($childId)){
                        $child=Get-Process -Id $childId -ErrorAction SilentlyContinue
                        if($child){try {$null=$child.Handle;$children[$childId]=$child}catch{$child.Dispose()}}
                    }
                }
                $restarted=@($runtime.workers|Where-Object {$_.name -eq 'module-performance' -and $_.recentRestarts -ge 1}).Count -eq 1
            }
            # A one-second healthy worker can be observed during its durable
            # collecting/complete transition. Its completed records and cadence
            # are independently required below; don't rely on timer phase.
            if($coverage.modules.performance.status -eq 'unavailable' -and $coverage.modules.processes.status -in @('ok','collecting')){$seenGap=$true}
        }while(-not($restarted -and $seenGap) -and (Get-Date) -lt $deadline -and -not $proc.HasExited)
        Assert ($restarted -and $seenGap) ('Hung module not isolated/restarted: restarted='+$restarted+' gap='+$seenGap+' coverage='+($coverage|ConvertTo-Json -Depth 6 -Compress)+' '+(Get-Content (Join-Path $sandbox 'stderr.txt') -Raw))
        $rows=@(Get-Content (Join-Path $logs ('detail-processes-'+(Get-Date -Format yyyyMMdd)+'.jsonl'))|ConvertFrom-Json)
        Assert ($rows.Count -ge 8) 'Fast provider starved by hung provider'
        $gaps=for($i=1;$i -lt $rows.Count;$i++){([DateTimeOffset]$rows[$i].startedAt-[DateTimeOffset]$rows[$i-1].startedAt).TotalSeconds}
        Assert (($gaps|Measure-Object -Maximum).Maximum -lt 3) 'Fast provider cadence blocked'
        Assert (@($runtime.workers|Where-Object {$_.name -eq 'module-processes' -and $_.recentRestarts -ne 0}).Count -eq 0) 'Healthy module restarted with hung module'
        [IO.File]::WriteAllText((Join-Path $data 'STOP-ALL'),'synthetic stop',$utf8)
        Assert ($proc.WaitForExit(15000)) 'Coordinator stop exceeded global grace period'
        Assert ($proc.ExitCode -eq 0) 'Coordinator shutdown failed'
        foreach($child in $children.Values){Assert $child.HasExited 'Isolated worker survived coordinator shutdown'}
        Write-Output ('PASS isolation: stuck provider restarted alone, fast samples='+$rows.Count+', explicit gap, all children stopped')
    }finally{
        [IO.File]::WriteAllText((Join-Path $data 'STOP-ALL'),'synthetic cleanup',$utf8)
        if(-not $proc.HasExited -and -not $proc.WaitForExit(15000)){$proc.Kill();$null=$proc.WaitForExit(5000)}
        # Retained process handles prevent PID reuse targeting a different process.
        foreach($child in $children.Values){if(-not $child.HasExited){$child.Kill();$null=$child.WaitForExit(5000)};$child.Dispose()}
        $proc.Dispose()
    }
}
Write-Output ('Synthetic evidence retained at '+$root)
