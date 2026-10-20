param([Parameter(Mandatory=$true)][string]$LogRoot,[int]$MaxSamples=0)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Evidence-Core.ps1')
. (Join-Path $PSScriptRoot 'Collection-Settings.ps1')
. (Join-Path $PSScriptRoot 'Read-NvidiaDiagnostics.ps1')
. (Join-Path $PSScriptRoot 'Extended-Evidence.ps1')
$dataRoot=Split-Path $LogRoot;$config=Get-CollectionSettings $dataRoot
$mutex=[Threading.Mutex]::new($false,'Global\PCDiagnostics-Extended-v1');$locked=$false
try {
    try {$locked=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true}
    if(-not $locked){exit 0}
    $modules=@('performance','processes','gpuDetails','inventory','reliability','power','dumpArchive','werArchive','diskSpace')
    $state=@{};$next=@{};$lastStart=@{};$missed=@{};$hashes=@{};$iteration=0
    $clock=[Diagnostics.Stopwatch]::StartNew()
    foreach($name in $modules){$state[$name]=@{status=if($config.modules[$name].enabled){'pending'}else{'disabled'};enabled=$config.modules[$name].enabled};$next[$name]=0.0;$missed[$name]=0L}
    while(-not(Test-Path (Join-Path $LogRoot 'STOP-EXTENDED'))){
        $cycle=[Diagnostics.Stopwatch]::StartNew()
        foreach($name in $modules){
            if(-not $config.modules[$name].enabled -or $clock.Elapsed.TotalMilliseconds -lt $next[$name]){continue}
            $started=[DateTimeOffset]::Now;$timer=[Diagnostics.Stopwatch]::StartNew()
            $startedMs=$clock.Elapsed.TotalMilliseconds
            $schedule=@{configuredIntervalSeconds=$config.modules[$name].intervalSeconds;latenessMs=[Math]::Max(0,$startedMs-$next[$name]);actualIntervalMs=if($lastStart.ContainsKey($name)){$startedMs-$lastStart[$name]}else{$null};missedIntervals=$missed[$name]}
            $lastStart[$name]=$startedMs
            # Publish before slow work so a terminated/hung query is identifiable.
            $state[$name]=@{status='collecting';enabled=$true;started=$started.ToString('o');schedule=$schedule}
            Add-EvidenceRecord $LogRoot 'extended' @{time=$started.ToString('o');event='heartbeat';activeModule=$name;modules=$state;errors=@()}
            try {
                $result=if($name -in @('dumpArchive','werArchive')){Get-ArchiveEvidence $name $dataRoot $config.limits}elseif($name -eq 'diskSpace'){Get-LogSpaceEvidence $dataRoot $config.limits}else{Get-ExtendedEvidence $name}
                $record=Add-ExtendedResult $LogRoot $name $result $hashes $started $timer.ElapsedMilliseconds -Schedule $schedule
                $state[$name]=@{status=$result.status;enabled=$true;time=$record.time;durationMs=$timer.ElapsedMilliseconds;issues=$result.issues;schedule=$schedule}
            }catch{$state[$name]=@{status='error';enabled=$true;time=[DateTimeOffset]::Now.ToString('o');error=$_.Exception.Message;schedule=$schedule};Add-EvidenceRecord $LogRoot ('detail-'+$name) $state[$name]}
            # Advance the original monotonic deadline, never completion + interval.
            # Skip missed slots explicitly rather than issuing a catch-up burst.
            $advance=Get-ExtendedNextDeadline $next[$name] $clock.Elapsed.TotalMilliseconds ($config.modules[$name].intervalSeconds*1000.0)
            $next[$name]=$advance.nextMs;$missed[$name]+=$advance.missedIntervals
            $state[$name].schedule.missedIntervals=$missed[$name]
        }
        $errors=@($state.Keys|Where-Object {$state[$_].status -eq 'error'}|ForEach-Object {@{module=$_;error=$state[$_].error}})
        $row=@{time=[DateTimeOffset]::Now.ToString('o');event='heartbeat';modules=$state;errors=$errors;sampleDurationMs=$cycle.ElapsedMilliseconds}
        Add-EvidenceRecord $LogRoot 'extended' $row
        Save-EvidenceJson (Join-Path $dataRoot 'coverage.json') $row
        $iteration++;if($MaxSamples -gt 0 -and $iteration -ge $MaxSamples){break}
        $wait=15000.0
        foreach($name in $modules){if($config.modules[$name].enabled){$wait=[Math]::Min($wait,$next[$name]-$clock.Elapsed.TotalMilliseconds)}}
        Start-Sleep -Milliseconds ([int][Math]::Max(1,[Math]::Ceiling($wait)))
    }
}finally{if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()}
