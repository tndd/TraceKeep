param([Parameter(Mandatory=$true)][string]$LogRoot,[int]$MaxSamples=0,[string]$SettingsPath)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Evidence-Core.ps1')
. (Join-Path $PSScriptRoot 'Collection-Settings.ps1')
$dataRoot=Split-Path $LogRoot
$config=Get-CollectionSettings $dataRoot -SettingsPath $SettingsPath
$stateRoot=Join-Path $dataRoot 'event-checkpoints'
[void][IO.Directory]::CreateDirectory($stateRoot)
$mutex=[Threading.Mutex]::new($false,'Global\PCDiagnostics-Evidence-v1');$locked=$false
try {
    try {$locked=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true}
    if(-not $locked){exit 0}
    $channels=@('System','Application')
    $catalog=@()
    foreach($pattern in @('*WHEA*','*StorPort*','*Storage-ClassPnP*','*Ntfs*','*Kernel-Power*','*Kernel-Boot*','*Kernel-PnP*','*DriverFrameworks*','*Diagnostics-Performance*','*WindowsUpdateClient*','*WER*','*Storage-Stor*','*Thermal*','*TaskScheduler*')){
        try {$logs=@(Get-WinEvent -ListLog $pattern -ErrorAction Stop);$catalog+=@($logs|Select-Object LogName,IsEnabled,LogType,MaximumSizeInBytes,RecordCount);$channels+=@($logs|Where-Object {$_.IsEnabled -and $_.LogType -eq 'Operational'}|Select-Object -ExpandProperty LogName)}catch{$catalog+=@{pattern=$pattern;status='unavailable';error=$_.Exception.Message}}
    }
    $channels=@($channels|Select-Object -Unique)
    if(-not $config.modules.events.enabled){$channels=@()}
    Save-EvidenceJson (Join-Path $dataRoot 'event-channel-coverage.json') @{time=[DateTimeOffset]::Now.ToString('o');enabled=$config.modules.events.enabled;selected=$channels;catalog=$catalog;note='Disabled Windows channels are catalogued, not enabled. Analytic/debug ETW sessions are not started.'}
    $crash=@{status='pending'}
    $boot=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    $session=[guid]::NewGuid().ToString();$iteration=0;$nextEvents=[DateTimeOffset]::MinValue;$bundlePending=$config.modules.incidents.enabled;$lastRecovery=@()
    Add-EvidenceRecord $LogRoot 'evidence' @{time=[DateTimeOffset]::Now.ToString('o');event='evidence-start';session=$session;channels=$channels;eventIntervalSeconds=15;storageIntervalSeconds=300;initialLookbackDays=7}
    while(-not(Test-Path -LiteralPath (Join-Path $LogRoot 'STOP-EVIDENCE'))){
        $timer=[Diagnostics.Stopwatch]::StartNew();$errors=@();$recovery=@()
        if([DateTimeOffset]::Now -ge $nextEvents){
            foreach($channel in $channels){
                Add-EvidenceRecord $LogRoot 'evidence' @{time=[DateTimeOffset]::Now.ToString('o');event='collecting-events';channel=$channel;errors=$errors}
                try {$recovery+=Sync-EvidenceChannel $LogRoot $stateRoot $channel}catch{$errors+=@{channel=$channel;error=$_.Exception.Message}}
            }
            $lastRecovery=$recovery;$lastEventErrors=$errors;$nextEvents=[DateTimeOffset]::Now.AddSeconds($config.modules.events.intervalSeconds)
        }else{$recovery=$lastRecovery;$errors=@($lastEventErrors)}
        # Wait for boot events to settle before saving one immutable snapshot per boot.
        if($bundlePending -and $boot -and ([DateTimeOffset]::Now-([DateTimeOffset]$boot)).TotalSeconds -ge 90){
            # The isolated worker owns the snapshot. Do not block event recovery
            # on CIM, disk metadata or dump enumeration.
            try {$crash=Get-Content -LiteralPath (Join-Path $dataRoot 'crash-configuration.json') -Encoding UTF8 -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop}catch{$crash=@{status='unavailable';error=$_.Exception.Message}}
            try {$bundle=New-IncidentBundle $LogRoot $dataRoot $boot $crash;$bundlePending=$false;Add-EvidenceRecord $LogRoot 'evidence' @{time=[DateTimeOffset]::Now.ToString('o');event='boot-bundle-created';path=$bundle}}catch{$errors+=@{error=$_.Exception.Message}}
        }
        Add-EvidenceRecord $LogRoot 'evidence' @{time=[DateTimeOffset]::Now.ToString('o');monotonicTicks=[Diagnostics.Stopwatch]::GetTimestamp();monotonicFrequency=[Diagnostics.Stopwatch]::Frequency;event='heartbeat';session=$session;sequence=$iteration;sampleDurationMs=$timer.ElapsedMilliseconds;channels=$recovery;eventsStatus=if($config.modules.events.enabled){'enabled'}else{'disabled'};collectionSettings=$config.modules;errors=$errors}
        $iteration++;if($MaxSamples -gt 0 -and $iteration -ge $MaxSamples){break}
        Start-Sleep -Milliseconds ([Math]::Max(1,15000-[int]$timer.ElapsedMilliseconds))
    }
}catch{try {Add-EvidenceRecord $LogRoot 'evidence' @{time=[DateTimeOffset]::Now.ToString('o');event='evidence-failed';error=$_.Exception.ToString()}}catch{};exit 1}
finally{if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()}
