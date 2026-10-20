param([Parameter(Mandatory=$true)][string]$LogRoot,[int]$MaxSamples=0,[string]$Module,[string]$RunId='standalone',[string]$SettingsPath)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Evidence-Core.ps1')
. (Join-Path $PSScriptRoot 'Collection-Settings.ps1')
. (Join-Path $PSScriptRoot 'Read-NvidiaDiagnostics.ps1')
. (Join-Path $PSScriptRoot 'Extended-Evidence.ps1')
$dataRoot=Split-Path $LogRoot;$config=Get-CollectionSettings $dataRoot -SettingsPath $SettingsPath
$mutexName='Global\PCDiagnostics-Extended-v1'
if($Module){if($Module -notin @(Get-IsolatedCollectionModules)){throw 'Unknown isolated module'};$mutexName+='-'+$Module}
$mutex=[Threading.Mutex]::new($false,$mutexName);$locked=$false
try {
    try {$locked=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true}
    if(-not $locked){exit 0}
    $session=[guid]::NewGuid().ToString();$iteration=0;$hashes=@{};$next=0.0;$lastStart=$null;$missed=0L
    $clock=[Diagnostics.Stopwatch]::StartNew()
    if($Module -and -not(Test-CollectionModuleEnabled $config $Module)){exit 0}
    $state=@{status='pending'}
    while(-not(Test-Path (Join-Path $LogRoot 'STOP-EXTENDED'))){
        if(-not $Module){
            # This process only aggregates bounded status files; it never queries
            # hardware, enumerates dumps, or waits for an individual provider.
            $row=Get-CollectionCoverage $dataRoot $config $RunId
            Add-EvidenceRecord $LogRoot 'extended' $row
            Save-EvidenceJson (Join-Path $dataRoot 'coverage.json') $row
            $iteration++;if($MaxSamples -gt 0 -and $iteration -ge $MaxSamples){break}
            for($tick=0;$tick -lt 30 -and -not(Test-Path (Join-Path $LogRoot 'STOP-EXTENDED'));$tick++){Start-Sleep -Milliseconds 500}
            continue
        }
        if($clock.Elapsed.TotalMilliseconds -ge $next){
            $started=[DateTimeOffset]::Now;$timer=[Diagnostics.Stopwatch]::StartNew();$startedMs=$clock.Elapsed.TotalMilliseconds
            $interval=Get-CollectionModuleInterval $config $Module
            $schedule=@{configuredIntervalSeconds=$interval;latenessMs=[Math]::Max(0,$startedMs-$next);actualIntervalMs=if($null -ne $lastStart){$startedMs-$lastStart}else{$null};missedIntervals=$missed}
            $lastStart=$startedMs
            $state=@{status='collecting';startedAt=$started.ToString('o');sequence=$iteration;schedule=$schedule}
            Save-CollectionModuleState $LogRoot $Module $RunId $session $state
            try {
                if($Module -eq 'storage'){
                    $result=Get-StorageEvidence $config;$result.session=$session;$result.sequence=$iteration
                    Add-EvidenceRecord $LogRoot 'storage' $result
                    $result.status=if(@($result.errors).Count){'partial'}else{'ok'}
                }elseif($Module -eq 'crashConfiguration'){
                    $crash=Get-CrashConfiguration $dataRoot
                    $result=@{status=if(@($crash.errors).Count){'partial'}else{'ok'};data=$crash;issues=$crash.errors}
                    $null=Add-ExtendedResult $LogRoot $Module $result $hashes $started $timer.ElapsedMilliseconds -Schedule $schedule -Session $session -Sequence $iteration
                    Save-EvidenceJson (Join-Path $dataRoot 'crash-configuration.json') $crash
                }else{
                    if($Module -eq 'inventory'){Save-EvidenceJson (Join-Path $dataRoot 'machine-inventory.json') (Get-MachineEvidence)}
                    $result=if($Module -eq 'configurationJournal'){Get-ConfigurationJournalEvidence $dataRoot}elseif($Module -in @('dumpArchive','werArchive')){Get-ArchiveEvidence $Module $dataRoot $config.limits}elseif($Module -eq 'diskSpace'){Get-LogSpaceEvidence $dataRoot $config.limits}else{Get-ExtendedEvidence $Module}
                    $null=Add-ExtendedResult $LogRoot $Module $result $hashes $started $timer.ElapsedMilliseconds -Schedule $schedule -Session $session -Sequence $iteration
                }
                $state=@{status=$result.status;completedAt=[DateTimeOffset]::Now.ToString('o');sequence=$iteration;durationMs=$timer.ElapsedMilliseconds;issues=$result.issues;schedule=$schedule}
            }catch{$state=@{status='error';sequence=$iteration;error=$_.Exception.Message;schedule=$schedule}}
            $advance=Get-ExtendedNextDeadline $next $clock.Elapsed.TotalMilliseconds ($interval*1000.0)
            $next=$advance.nextMs;$missed+=$advance.missedIntervals;$state.schedule.missedIntervals=$missed
            Save-CollectionModuleState $LogRoot $Module $RunId $session $state
            $iteration++;if($MaxSamples -gt 0 -and $iteration -ge $MaxSamples){break}
        }else{Save-CollectionModuleState $LogRoot $Module $RunId $session $state}
        # Short sleeps keep graceful shutdown bounded; heartbeats at most 15 s.
        $wake=[Math]::Min($next,$clock.Elapsed.TotalMilliseconds+15000)
        while($clock.Elapsed.TotalMilliseconds -lt $wake -and -not(Test-Path (Join-Path $LogRoot 'STOP-EXTENDED'))){Start-Sleep -Milliseconds ([int][Math]::Max(1,[Math]::Min(500,$wake-$clock.Elapsed.TotalMilliseconds)))}
    }
}finally{if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()}
