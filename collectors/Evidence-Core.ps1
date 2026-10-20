$script:EvidenceUtf8=[Text.UTF8Encoding]::new($false)
$script:EvidenceCollectorDirectory=$PSScriptRoot
. (Join-Path $PSScriptRoot 'Log-Storage.ps1')
function Test-EvidenceReady($row,[DateTimeOffset]$since) {
    return $row -and $row.event -eq 'heartbeat' -and $row.time -and ([DateTimeOffset]$row.time) -ge $since -and ($row.PSObject.Properties.Name -contains 'errors') -and @($row.errors).Count -eq 0 -and ($row.eventsStatus -eq 'disabled' -or @($row.channels|Where-Object {$_.channel -eq 'System' -and $null -ne $_.watermark}).Count -gt 0)
}
function Save-EvidenceJson($path,$value) {
    Save-DiagnosticJson $path $value
}
function Add-EvidenceRecord($root,$kind,$value,[string]$Day=(Get-Date -Format yyyyMMdd)) {
    $path=Join-Path $root ($kind+'-'+$Day+'.jsonl')
    $handle=Open-DiagnosticLogWriter $path
    try {Write-DiagnosticLogLine $handle ($value|ConvertTo-Json -Compress -Depth 12)}finally{Close-DiagnosticLogWriter $handle}
}
function Get-EvidenceCursor($stateRoot,$channel) {
    $key=$channel -replace '[^A-Za-z0-9_-]','_'
    $path=Join-Path $stateRoot ($key+'.json')
    if(Test-Path -LiteralPath $path){
        foreach($candidate in @($path,($path+'.previous'))){
            try {$c=Get-Content -Encoding UTF8 -LiteralPath $candidate -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop;if($c.channel -eq $channel -and $null -ne $c.recordId){return $c}}catch{}
        }
        throw "No valid event checkpoint for $channel; refusing to silently skip history"
    }
    return $null
}
function Get-EvidenceXPath($channel,$cursor,[long]$latestId,[DateTimeOffset]$now) {
    $selection=if($channel -eq 'System'){"(Level=1 or Level=2 or Level=3 or Provider[@Name='Microsoft-Windows-Kernel-Power'] or Provider[@Name='Microsoft-Windows-Kernel-Boot'] or Provider[@Name='Microsoft-Windows-Kernel-Processor-Power'] or Provider[@Name='Microsoft-Windows-WHEA-Logger'] or Provider[@Name='EventLog'] or Provider[@Name='User32'] or Provider[@Name='volmgr'] or Provider[@Name='disk'] or Provider[@Name='stornvme'] or Provider[@Name='Ntfs'])"}elseif($channel -eq 'Application'){"(Level=1 or Level=2 or Level=3 or Provider[@Name='Windows Error Reporting'])"}elseif($channel -like '*WHEA*'){'(EventRecordID >= 0)'}else{'(Level=1 or Level=2 or Level=3)'}
    # Query through a fixed watermark. Record IDs rather than wall time survive clock changes.
    # Collect every level from the selected diagnostic channels, including context before a failure.
    $selection='(EventRecordID >= 0)'
    if($cursor -and [long]$cursor.recordId -le $latestId){$position='EventRecordID > '+[long]$cursor.recordId}
    else {$position="TimeCreated[@SystemTime >= '"+$now.UtcDateTime.AddDays(-7).ToString('yyyy-MM-ddTHH:mm:ss.fffZ')+"']"}
    return '*[System['+$selection+' and ('+$position+') and EventRecordID <= '+$latestId+']]'
}
function Read-EvidenceEvents($channel,$xpath,[int]$limit=2000,[switch]$Newest) {
    try {return @(Get-WinEvent -LogName $channel -FilterXPath $xpath -Oldest:(!$Newest) -MaxEvents $limit -ErrorAction Stop)}catch{if($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*'){return @()};throw}
}
function Sync-EvidenceChannel($logRoot,$stateRoot,$channel) {
    $cursor=Get-EvidenceCursor $stateRoot $channel
    try {$head=Get-WinEvent -LogName $channel -MaxEvents 1 -ErrorAction Stop}catch{
        if($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*'){return @{channel=$channel;recovered=0;watermark=$null;backlog=$false;state='empty'}}
        throw
    }
    $latest=[long]$head.RecordId
    if($cursor -and $cursor.recordTime){
        $anchor=$null
        try {$anchor=Get-WinEvent -LogName $channel -FilterXPath ('*[System[EventRecordID='+[long]$cursor.recordId+']]') -MaxEvents 1 -ErrorAction Stop}catch{if($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*'){throw}}
        if(-not $anchor -or $anchor.TimeCreated.ToString('o') -ne $cursor.recordTime){
            Add-EvidenceRecord $logRoot 'evidence' @{time=[DateTimeOffset]::Now.ToString('o');event='event-checkpoint-anchor-lost';channel=$channel;previousRecordId=$cursor.recordId;note='Log cleared/replaced or checkpoint aged out; recover retained last seven days'}
            $cursor=$null
        }
    }
    if($cursor -and [long]$cursor.recordId -gt $latest){Add-EvidenceRecord $logRoot 'evidence' @{time=[DateTimeOffset]::Now.ToString('o');event='event-log-reset';channel=$channel;previousRecordId=$cursor.recordId;latestRecordId=$latest};$cursor=$null}
    $xpath=Get-EvidenceXPath $channel $cursor $latest ([DateTimeOffset]::Now)
    $batch=@(Read-EvidenceEvents $channel $xpath)
    foreach($e in $batch){Add-EvidenceRecord $logRoot 'events' @{time=$e.TimeCreated.ToString('o');channel=$channel;recordId=[long]$e.RecordId;provider=$e.ProviderName;id=$e.Id;level=$e.Level;xml=$e.ToXml();recovered=$true}}
    # Commit only after every selected event has been durably appended. A crash can
    # replay rows; (channel, recordId, time) is the deduplication identity.
    $watermark=if($batch.Count -eq 2000){[long]$batch[-1].RecordId}else{$latest}
    $anchorTime=if($batch.Count -eq 2000){$batch[-1].TimeCreated}else{$head.TimeCreated}
    Save-EvidenceJson (Join-Path $stateRoot (($channel -replace '[^A-Za-z0-9_-]','_')+'.json')) @{channel=$channel;recordId=$watermark;recordTime=if($anchorTime){$anchorTime.ToString('o')}else{$null};time=[DateTimeOffset]::Now.ToString('o');initialLookbackDays=7}
    return @{channel=$channel;recovered=$batch.Count;watermark=$watermark;backlog=($batch.Count -eq 2000)}
}
function Copy-EvidenceTail($source,$destination,[long]$maxBytes=8MB) {
    # Gzip is streamed through a bounded ring; incident bundles remain plain JSONL.
    $tail=Read-DiagnosticLogTail $source ([int]$maxBytes)
    $bytes=$tail.bytes;$start=0;$end=$bytes.Length
    if($tail.length -gt $maxBytes){while($start -lt $end -and $bytes[$start] -ne 10){$start++};$start=[Math]::Min($end,$start+1)}
    while($end -gt $start -and $bytes[$end-1] -ne 10){$end--}
    $output=[IO.FileStream]::new($destination,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::Read,4096,[IO.FileOptions]::WriteThrough)
    try {$output.Write($bytes,$start,$end-$start);$output.Flush($true)}finally{$output.Dispose()}
    return @{source=$tail.path;sourceBytes=$tail.length;copiedBytes=(Get-Item -LiteralPath $destination).Length;tailLimited=($tail.length -gt $maxBytes);sha256=(Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash}
}
function Get-CrashConfiguration([string]$DataRoot=(Join-Path $env:ProgramData 'PCDiagnostics')) {
    $errors=@();$settings=$null;$os=$null;$pagefiles=@();$dumps=@();$volumes=@()
    try {$settings=Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'|Select-Object CrashDumpEnabled,DumpFile,MinidumpDir,AutoReboot,LogEvent,AlwaysKeepMemoryDump,DedicatedDumpFile,DumpFileSize}catch{$errors+=$_.Exception.Message}
    try {$os=Get-CimInstance Win32_OperatingSystem|Select-Object LastBootUpTime,Version,BuildNumber,FreePhysicalMemory,TotalVisibleMemorySize}catch{$errors+=$_.Exception.Message}
    try {$pagefiles=@(Get-CimInstance Win32_PageFileUsage|Select-Object Name,AllocatedBaseSize,CurrentUsage,PeakUsage)}catch{$errors+=$_.Exception.Message}
    try {$volumes=@(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3'|Select-Object DeviceID,FreeSpace,Size)}catch{$errors+=$_.Exception.Message}
    $paths=@((Join-Path $env:WINDIR 'MEMORY.DMP'),(Join-Path $env:WINDIR 'Minidump'),(Join-Path $env:WINDIR 'LiveKernelReports'))
    if($settings){foreach($p in @($settings.DumpFile,$settings.MinidumpDir)){if($p){$paths+=[Environment]::ExpandEnvironmentVariables($p)}}}
    foreach($p in @($paths|Select-Object -Unique)){
        try {if(Test-Path -LiteralPath $p){$dumps+=@(Get-ChildItem -LiteralPath $p -Filter '*.dmp' -Recurse -File -ErrorAction Stop|Select-Object -First 100 FullName,Length,LastWriteTimeUtc)}}catch{$errors+=$_.Exception.Message}
    }
    $policy=@{status='unavailable'}
    if($settings){
        try {
            . (Join-Path (Split-Path $script:EvidenceCollectorDirectory) 'management\CrashDump-Policy.ps1')
            $policy=Get-DiagnosticDumpPolicyState $DataRoot $settings
        }catch{$policy=@{status='unavailable';error=$_.Exception.Message}}
    }
    return @{time=[DateTimeOffset]::Now.ToString('o');settings=$settings;policy=$policy;os=$os;pagefiles=$pagefiles;volumes=$volumes;dumpFiles=$dumps;errors=$errors;note='Read-only configuration and dump metadata; dump creation is not guaranteed by these settings.'}
}
function Get-MachineEvidence {
    $result=@{time=[DateTimeOffset]::Now.ToString('o');errors=@()}
    foreach($entry in @(@('board','Win32_BaseBoard'),@('bios','Win32_BIOS'),@('cpu','Win32_Processor'),@('memory','Win32_PhysicalMemory'),@('video','Win32_VideoController'),@('disk','Win32_DiskDrive'))){
        try {
            # Deliberately omit serial numbers, user names and network identities.
            $result[$entry[0]]=@(Get-CimInstance $entry[1] -ErrorAction Stop|Select-Object Manufacturer,Name,Product,Version,SMBIOSBIOSVersion,ReleaseDate,DriverVersion,DriverDate,Model,FirmwareRevision,Capacity,ConfiguredClockSpeed,PartNumber)
        }catch{$result.errors+=@{category=$entry[0];error=$_.Exception.Message}}
    }
    return $result
}
function Get-StorageEvidence($Config=$null) {
    $items=@();$errors=@()
    try {
        foreach($disk in $(if(-not $Config -or $Config.modules.storage.enabled){@(Get-PhysicalDisk -ErrorAction Stop)}else{@()})){
            $counter=$null;$error=$null
            try {$counter=$disk|Get-StorageReliabilityCounter -ErrorAction Stop|Select-Object Temperature,TemperatureMax,Wear,PowerOnHours,ReadErrorsTotal,ReadErrorsUncorrected,WriteErrorsTotal,WriteErrorsUncorrected,ReadLatencyMax,WriteLatencyMax,FlushLatencyMax}catch{$error=$_.Exception.Message}
            $items+=@{deviceId=$disk.DeviceId;name=$disk.FriendlyName;busType=[string]$disk.BusType;health=[string]$disk.HealthStatus;operational=@($disk.OperationalStatus|ForEach-Object {[string]$_});size=$disk.Size;reliability=$counter;error=$error}
        }
    }catch{$errors+=$_.Exception.Message}
    $nvme=$null
    try {
        . (Join-Path $script:EvidenceCollectorDirectory 'Read-NvmeHealth.ps1')
        if(-not $Config){$nvme=Get-NvmeHealthEvidence}elseif($Config.modules.nvme.enabled -or $Config.modules.nvmeErrors.enabled){$nvme=Get-NvmeHealthEvidence -IncludeHealth $Config.modules.nvme.enabled -IncludeErrors $Config.modules.nvmeErrors.enabled}else{$nvme=@{status='disabled';disks=@();errors=@()}}
    }catch{$errors+=('NVMe reader: '+$_.Exception.Message)}
    return @{time=[DateTimeOffset]::Now.ToString('o');disks=$items;nvme=$nvme;errors=$errors;note='Windows reliability and direct NVMe SMART counters. Null/unsupported is not zero or healthy. Lifetime counters do not date or attribute a failure.'}
}
function Get-BootEvidenceXPath($bootTime) {
    return "*[System[(EventID=41 or EventID=6008 or EventID=1001 or EventID=46 or EventID=161 or Provider[@Name='Microsoft-Windows-WHEA-Logger']) and TimeCreated[@SystemTime >= '"+([DateTimeOffset]$bootTime).UtcDateTime.AddDays(-3).ToString('yyyy-MM-ddTHH:mm:ss.fffZ')+"']]]"
}
function Save-IncidentConditions($DataRoot,$Destination,$BootTime) {
    [void][IO.Directory]::CreateDirectory($Destination)
    $manifest=Join-Path $Destination 'conditions.json'
    if(Test-Path -LiteralPath $manifest){return $manifest}
    $files=@()
    foreach($name in @('machine-inventory.json','recorder-settings.json','collection-settings.json','recorder-run.json','coverage.json','sensor-driver-isolation.json','dump-policy-backup.json','event-channel-coverage.json')){
        $source=Join-Path $DataRoot $name;$target=Join-Path $Destination $name
        $entry=@{file=$name;observedAt=[DateTimeOffset]::Now.ToString('o')}
        try {
            if(Test-Path -LiteralPath $target){$entry.status='retained-existing-copy'}
            elseif(Test-Path -LiteralPath $source){
                Copy-Item -LiteralPath $source -Destination $target -ErrorAction Stop
                $entry.status='captured'
            }else{$entry.status='missing'}
            if(Test-Path -LiteralPath $target){
                $entry.sha256=(Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
                $entry.bytes=(Get-Item -LiteralPath $target).Length
                try {
                    $content=Get-Content -Encoding UTF8 -LiteralPath $target -Raw|ConvertFrom-Json -ErrorAction Stop
                    $entry.reportedTime=$content.time
                }catch{$entry.status='invalid-json';$entry.error=$_.Exception.Message}
            }
        }catch{$entry.status='unavailable';$entry.error=$_.Exception.Message}
        $files+=$entry
    }
    Save-EvidenceJson $manifest @{schemaVersion=1;capturedAt=[DateTimeOffset]::Now.ToString('o');bootTime=([DateTimeOffset]$BootTime).ToString('o');timeScope='Observed after this boot; not proof of pre-failure settings. Reported timestamps may be from an earlier worker/session.';files=$files}
    return $manifest
}
function New-IncidentBundle($logRoot,$dataRoot,$bootTime,$crash) {
    $key=([DateTimeOffset]$bootTime).UtcDateTime.ToString('yyyyMMddTHHmmssZ')
    $parent=Join-Path $dataRoot 'incidents';[void][IO.Directory]::CreateDirectory($parent)
    $dest=Join-Path $parent ('boot-'+$key)
    $manifestPath=Join-Path $dest 'manifest.json'
    if(Test-Path -LiteralPath $manifestPath){
        $existing=Get-Content -Encoding UTF8 -LiteralPath $manifestPath -Raw|ConvertFrom-Json
        if(-not(Test-Path -LiteralPath (Join-Path $dest 'conditions.json'))){
            # Old immutable bundles get a dated-observation supplement, never a
            # replacement that would pretend today's settings existed before loss.
            $null=Save-IncidentConditions $dataRoot (Join-Path $dest 'conditions-recovery') $bootTime
        }
        if(@($existing.errors).Count -gt 0 -and -not(Test-Path -LiteralPath (Join-Path $dest 'event-recovery.json'))){
            # Preserve the original snapshot and failure manifest. Add a recovery
            # supplement without replacing any original sensor or event files.
            $recovered=@(Read-EvidenceEvents 'System' (Get-BootEvidenceXPath $bootTime) 5000 -Newest)
            Save-EvidenceJson (Join-Path $dest 'boot-events-recovered.json') @($recovered|ForEach-Object {@{time=$_.TimeCreated.ToString('o');channel='System';recordId=$_.RecordId;provider=$_.ProviderName;id=$_.Id;xml=$_.ToXml()}})
            Save-EvidenceJson (Join-Path $dest 'event-recovery.json') @{time=[DateTimeOffset]::Now.ToString('o');eventCount=$recovered.Count;status='boot-event-query-recovered';originalErrors=$existing.errors;note='Original snapshot retained; this supplement repairs only boot-event extraction.'}
        }
        return $dest
    }
    [void][IO.Directory]::CreateDirectory($dest)
    $errors=@();$copied=@();$events=@()
    try {$events=@(Read-EvidenceEvents 'System' (Get-BootEvidenceXPath $bootTime) 5000 -Newest)}catch{$errors+=$_.Exception.Message}
    $abnormal=@($events|Where-Object {$_.Id -in @(41,6008) -and ([DateTimeOffset]$_.TimeCreated) -ge ([DateTimeOffset]$bootTime).AddMinutes(-2)})
    Save-EvidenceJson (Join-Path $dest 'crash-configuration.json') $crash
    $conditions=Save-IncidentConditions $dataRoot $dest $bootTime
    Save-EvidenceJson (Join-Path $dest 'boot-events.json') @($events|ForEach-Object {@{time=$_.TimeCreated.ToString('o');channel='System';recordId=$_.RecordId;provider=$_.ProviderName;id=$_.Id;xml=$_.ToXml()}})
    foreach($prefix in @('cpu-auto-','board-auto-','activity-','events-','sessions-','coordinator-','storage-','evidence-','extended-','maintenance-','detail-performance-','detail-processes-','detail-gpuDetails-','detail-inventory-','detail-power-','detail-reliability-','detail-dumpArchive-','detail-werArchive-','detail-diskSpace-','detail-configurationJournal-','detail-crashConfiguration-','progress-cpu-','progress-board-','progress-activity-')){
        foreach($file in @(Get-DiagnosticDailyLogs $logRoot $prefix|Sort-Object Name -Descending|Select-Object -First 2)){
            try {$copied+=Copy-EvidenceTail $file.FullName (Join-Path $dest ($file.Name -replace '\.gz$',''))}catch{$errors+=$_.Exception.Message}
        }
    }
    Save-EvidenceJson (Join-Path $dest 'manifest.json') @{version=2;createdAt=[DateTimeOffset]::Now.ToString('o');bootTime=([DateTimeOffset]$bootTime).ToString('o');classification=if($abnormal.Count){'abnormal-boot-evidence'}else{'boot-snapshot-unclassified'};abnormalEventCount=$abnormal.Count;conditions=$conditions;files=$copied;errors=$errors;limits='Last two log dates per stream; last 8 MiB per file, final partial row omitted. Event lookback 3 days, maximum 5000. Dumps indexed only. Missing events do not prove a clean shutdown.'}
    return $dest
}
