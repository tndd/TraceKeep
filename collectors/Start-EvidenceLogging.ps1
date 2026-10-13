param([Parameter(Mandatory=$true)][string]$LogRoot,[int]$MaxSamples=0)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Evidence-Core.ps1')
$dataRoot=Split-Path $LogRoot
$stateRoot=Join-Path $dataRoot 'event-checkpoints'
[void][IO.Directory]::CreateDirectory($stateRoot)
$mutex=[Threading.Mutex]::new($false,'Global\PCDiagnostics-Evidence-v1');$locked=$false
try {
    try {$locked=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true}
    if(-not $locked){exit 0}
    $channels=@('System','Application')
    foreach($pattern in @('*WHEA*','*StorPort*','*Storage-ClassPnP*','*Ntfs*')){
        try {$channels+=@(Get-WinEvent -ListLog $pattern -ErrorAction Stop|Where-Object {$_.IsEnabled -and $_.LogType -eq 'Operational'}|Select-Object -ExpandProperty LogName)}catch{}
    }
    $channels=@($channels|Select-Object -Unique)
    $crash=Get-CrashConfiguration
    Save-EvidenceJson (Join-Path $dataRoot 'machine-inventory.json') (Get-MachineEvidence)
    $boot=$crash.os.LastBootUpTime
    $session=[guid]::NewGuid().ToString();$iteration=0;$nextHealth=[DateTimeOffset]::MinValue;$bundlePending=$true
    Add-EvidenceRecord $LogRoot 'evidence' @{time=[DateTimeOffset]::Now.ToString('o');event='evidence-start';session=$session;channels=$channels;eventIntervalSeconds=15;storageIntervalSeconds=300;initialLookbackDays=7}
    while(-not(Test-Path -LiteralPath (Join-Path $LogRoot 'STOP-EVIDENCE'))){
        $timer=[Diagnostics.Stopwatch]::StartNew();$errors=@();$recovery=@()
        foreach($channel in $channels){try {$recovery+=Sync-EvidenceChannel $LogRoot $stateRoot $channel}catch{$errors+=@{channel=$channel;error=$_.Exception.Message}}}
        if([DateTimeOffset]::Now -ge $nextHealth){
            Add-EvidenceRecord $LogRoot 'storage' (Get-StorageEvidence)
            $crash=Get-CrashConfiguration;Save-EvidenceJson (Join-Path $dataRoot 'crash-configuration.json') $crash
            $nextHealth=[DateTimeOffset]::Now.AddMinutes(5)
        }
        # Wait for boot events to settle before saving one immutable snapshot per boot.
        if($bundlePending -and $boot -and ([DateTimeOffset]::Now-([DateTimeOffset]$boot)).TotalSeconds -ge 90){
            try {$bundle=New-IncidentBundle $LogRoot $dataRoot $boot $crash;$bundlePending=$false;Add-EvidenceRecord $LogRoot 'evidence' @{time=[DateTimeOffset]::Now.ToString('o');event='boot-bundle-created';path=$bundle}}catch{$errors+=@{error=$_.Exception.Message}}
        }
        Add-EvidenceRecord $LogRoot 'evidence' @{time=[DateTimeOffset]::Now.ToString('o');monotonicTicks=[Diagnostics.Stopwatch]::GetTimestamp();monotonicFrequency=[Diagnostics.Stopwatch]::Frequency;event='heartbeat';session=$session;sequence=$iteration;sampleDurationMs=$timer.ElapsedMilliseconds;channels=$recovery;errors=$errors}
        $iteration++;if($MaxSamples -gt 0 -and $iteration -ge $MaxSamples){break}
        Start-Sleep -Milliseconds ([Math]::Max(1,15000-[int]$timer.ElapsedMilliseconds))
    }
}catch{try {Add-EvidenceRecord $LogRoot 'evidence' @{time=[DateTimeOffset]::Now.ToString('o');event='evidence-failed';error=$_.Exception.ToString()}}catch{};exit 1}
finally{if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()}
