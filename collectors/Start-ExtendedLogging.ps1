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
    $state=@{};$next=@{};$hashes=@{};$iteration=0
    foreach($name in $modules){$state[$name]=@{status=if($config.modules[$name].enabled){'pending'}else{'disabled'};enabled=$config.modules[$name].enabled};$next[$name]=[DateTimeOffset]::MinValue}
    while(-not(Test-Path (Join-Path $LogRoot 'STOP-EXTENDED'))){
        $cycle=[Diagnostics.Stopwatch]::StartNew()
        foreach($name in $modules){
            if(-not $config.modules[$name].enabled -or [DateTimeOffset]::Now -lt $next[$name]){continue}
            $started=[DateTimeOffset]::Now;$timer=[Diagnostics.Stopwatch]::StartNew()
            # Publish before slow work so a terminated/hung query is identifiable.
            $state[$name]=@{status='collecting';enabled=$true;started=$started.ToString('o')}
            Add-EvidenceRecord $LogRoot 'extended' @{time=$started.ToString('o');event='heartbeat';activeModule=$name;modules=$state;errors=@()}
            try {
                $result=if($name -in @('dumpArchive','werArchive')){Get-ArchiveEvidence $name $dataRoot $config.limits}elseif($name -eq 'diskSpace'){Get-LogSpaceEvidence $dataRoot $config.limits}else{Get-ExtendedEvidence $name}
                $json=$result|ConvertTo-Json -Depth 12 -Compress
                $sha=[Security.Cryptography.SHA256]::Create();try {$hash=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($json)))).Replace('-','')}finally{$sha.Dispose()}
                $unchanged=$hashes[$name] -eq $hash
                $record=@{time=[DateTimeOffset]::Now.ToString('o');startedAt=$started.ToString('o');monotonicTicks=[Diagnostics.Stopwatch]::GetTimestamp();monotonicFrequency=[Diagnostics.Stopwatch]::Frequency;module=$name;durationMs=$timer.ElapsedMilliseconds;status=$result.status;sha256=$hash;unchanged=$unchanged}
                if(-not $unchanged){$record.result=$result;$hashes[$name]=$hash}
                Add-EvidenceRecord $LogRoot ('detail-'+$name) $record
                $state[$name]=@{status=$result.status;enabled=$true;time=$record.time;durationMs=$timer.ElapsedMilliseconds;issues=$result.issues}
            }catch{$state[$name]=@{status='error';enabled=$true;time=[DateTimeOffset]::Now.ToString('o');error=$_.Exception.Message};Add-EvidenceRecord $LogRoot ('detail-'+$name) $state[$name]}
            $next[$name]=[DateTimeOffset]::Now.AddSeconds($config.modules[$name].intervalSeconds)
        }
        $errors=@($state.Keys|Where-Object {$state[$_].status -eq 'error'}|ForEach-Object {@{module=$_;error=$state[$_].error}})
        $row=@{time=[DateTimeOffset]::Now.ToString('o');event='heartbeat';modules=$state;errors=$errors;sampleDurationMs=$cycle.ElapsedMilliseconds}
        Add-EvidenceRecord $LogRoot 'extended' $row
        Save-EvidenceJson (Join-Path $dataRoot 'coverage.json') $row
        $iteration++;if($MaxSamples -gt 0 -and $iteration -ge $MaxSamples){break}
        Start-Sleep -Milliseconds ([Math]::Max(1,15000-[int]$cycle.ElapsedMilliseconds))
    }
}finally{if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()}
