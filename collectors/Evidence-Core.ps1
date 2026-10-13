$script:EvidenceUtf8=[Text.UTF8Encoding]::new($false)
function Save-EvidenceJson($path,$value) {
    $temp=$path+'.tmp'
    $json=if($null -eq $value){'null'}else{ConvertTo-Json -InputObject $value -Depth 12}
    $bytes=$script:EvidenceUtf8.GetBytes($json)
    $stream=[IO.FileStream]::new($temp,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::Read,4096,[IO.FileOptions]::WriteThrough)
    try {$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
    if(Test-Path -LiteralPath $path){[IO.File]::Replace($temp,$path,$path+'.previous')}else{[IO.File]::Move($temp,$path)}
}
function Add-EvidenceRecord($root,$kind,$value) {
    $path=Join-Path $root ($kind+'-'+(Get-Date -Format yyyyMMdd)+'.jsonl')
    $stream=[IO.FileStream]::new($path,[IO.FileMode]::Append,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite,4096,[IO.FileOptions]::WriteThrough)
    $writer=[IO.StreamWriter]::new($stream,$script:EvidenceUtf8)
    try {$writer.WriteLine(($value|ConvertTo-Json -Compress -Depth 12));$writer.Flush();$stream.Flush($true)}finally{$writer.Dispose()}
}
function Get-EvidenceCursor($stateRoot,$channel) {
    $key=$channel -replace '[^A-Za-z0-9_-]','_'
    $path=Join-Path $stateRoot ($key+'.json')
    if(Test-Path -LiteralPath $path){
        foreach($candidate in @($path,($path+'.previous'))){
            try {$c=Get-Content -LiteralPath $candidate -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop;if($c.channel -eq $channel -and $null -ne $c.recordId){return $c}}catch{}
        }
        throw "No valid event checkpoint for $channel; refusing to silently skip history"
    }
    return $null
}
function Get-EvidenceXPath($channel,$cursor,[long]$latestId,[DateTimeOffset]$now) {
    $selection=if($channel -eq 'System'){"(Level=1 or Level=2 or Level=3 or Provider[@Name='Microsoft-Windows-Kernel-Power'] or Provider[@Name='Microsoft-Windows-Kernel-Boot'] or Provider[@Name='Microsoft-Windows-Kernel-Processor-Power'] or Provider[@Name='Microsoft-Windows-WHEA-Logger'] or Provider[@Name='EventLog'] or Provider[@Name='User32'] or Provider[@Name='volmgr'] or Provider[@Name='disk'] or Provider[@Name='stornvme'] or Provider[@Name='Ntfs'])"}elseif($channel -eq 'Application'){"(Level=1 or Level=2 or Level=3 or Provider[@Name='Windows Error Reporting'])"}else{'(Level=1 or Level=2 or Level=3)'}
    # Query through a fixed watermark. Record IDs rather than wall time survive clock changes.
    if($cursor -and [long]$cursor.recordId -le $latestId){$position='EventRecordID > '+[long]$cursor.recordId}
    else {$position="TimeCreated[@SystemTime >= '"+$now.UtcDateTime.AddDays(-7).ToString('yyyy-MM-ddTHH:mm:ss.fffZ')+"']"}
    return '*[System['+$selection+' and ('+$position+') and EventRecordID <= '+$latestId+']]'
}
function Read-EvidenceEvents($channel,$xpath,[int]$limit=2000) {
    try {return @(Get-WinEvent -LogName $channel -FilterXPath $xpath -Oldest -MaxEvents $limit -ErrorAction Stop)}catch{if($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*'){return @()};throw}
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
    # Read only the last bounded byte range, including files still being appended.
    $stream=[IO.FileStream]::new($source,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    try {
        $length=$stream.Length;$start=[Math]::Max(0,$length-$maxBytes)
        [void]$stream.Seek($start,[IO.SeekOrigin]::Begin)
        $reader=[IO.StreamReader]::new($stream,$script:EvidenceUtf8,$true,4096,$true)
        try {if($start -gt 0){$null=$reader.ReadLine()};$text=$reader.ReadToEnd()}finally{$reader.Dispose()}
        # A final incomplete JSONL row is omitted; the original remains intact.
        $lastNewline=$text.LastIndexOf("`n")
        $text=if($lastNewline -ge 0){$text.Substring(0,$lastNewline+1)}else{''}
        [IO.File]::WriteAllText($destination,$text,$script:EvidenceUtf8)
        return @{source=$source;sourceBytes=$length;copiedBytes=(Get-Item -LiteralPath $destination).Length;tailLimited=($start -gt 0);sha256=(Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash}
    }finally{$stream.Dispose()}
}
function Get-CrashConfiguration {
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
    return @{time=[DateTimeOffset]::Now.ToString('o');settings=$settings;os=$os;pagefiles=$pagefiles;volumes=$volumes;dumpFiles=$dumps;errors=$errors;note='Read-only configuration and dump metadata; dump creation is not guaranteed by these settings.'}
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
function Get-StorageEvidence {
    $items=@();$errors=@()
    try {
        foreach($disk in @(Get-PhysicalDisk -ErrorAction Stop)){
            $counter=$null;$error=$null
            try {$counter=$disk|Get-StorageReliabilityCounter -ErrorAction Stop|Select-Object Temperature,TemperatureMax,Wear,PowerOnHours,ReadErrorsTotal,ReadErrorsUncorrected,WriteErrorsTotal,WriteErrorsUncorrected,ReadLatencyMax,WriteLatencyMax,FlushLatencyMax}catch{$error=$_.Exception.Message}
            $items+=@{deviceId=$disk.DeviceId;name=$disk.FriendlyName;busType=[string]$disk.BusType;health=[string]$disk.HealthStatus;operational=@($disk.OperationalStatus|ForEach-Object {[string]$_});size=$disk.Size;reliability=$counter;error=$error}
        }
    }catch{$errors+=$_.Exception.Message}
    return @{time=[DateTimeOffset]::Now.ToString('o');disks=$items;errors=$errors;note='Windows-exposed counters only. Null/unsupported is not zero or healthy; raw NVMe SMART/unsafe-shutdown counters are not guaranteed.'}
}
function New-IncidentBundle($logRoot,$dataRoot,$bootTime,$crash) {
    $key=([DateTimeOffset]$bootTime).UtcDateTime.ToString('yyyyMMddTHHmmssZ')
    $parent=Join-Path $dataRoot 'incidents';[void][IO.Directory]::CreateDirectory($parent)
    $dest=Join-Path $parent ('boot-'+$key)
    if(Test-Path -LiteralPath (Join-Path $dest 'manifest.json')){return $dest}
    [void][IO.Directory]::CreateDirectory($dest)
    $errors=@();$copied=@();$events=@()
    try {$events=@(Read-EvidenceEvents 'System' ("*[System[(EventID=41 or EventID=6008 or EventID=1001 or EventID=46 or EventID=161 or Provider[@Name='Microsoft-Windows-WHEA-Logger']) and TimeCreated[@SystemTime >= '"+([DateTimeOffset]$bootTime).UtcDateTime.AddDays(-3).ToString('yyyy-MM-ddTHH:mm:ss.fffZ')+"']]") 5000)}catch{$errors+=$_.Exception.Message}
    $abnormal=@($events|Where-Object {$_.Id -in @(41,6008) -and ([DateTimeOffset]$_.TimeCreated) -ge ([DateTimeOffset]$bootTime).AddMinutes(-2)})
    Save-EvidenceJson (Join-Path $dest 'crash-configuration.json') $crash
    foreach($name in @('machine-inventory.json','recorder-settings.json')){if(Test-Path -LiteralPath (Join-Path $dataRoot $name)){Copy-Item -LiteralPath (Join-Path $dataRoot $name) -Destination (Join-Path $dest $name) -Force}}
    Save-EvidenceJson (Join-Path $dest 'boot-events.json') @($events|ForEach-Object {@{time=$_.TimeCreated.ToString('o');channel='System';recordId=$_.RecordId;provider=$_.ProviderName;id=$_.Id;xml=$_.ToXml()}})
    foreach($prefix in @('cpu-auto-','board-auto-','activity-','events-','sessions-','coordinator-','storage-','evidence-')){
        foreach($file in @(Get-ChildItem -LiteralPath $logRoot -Filter ($prefix+'*.jsonl')|Sort-Object Name -Descending|Select-Object -First 2)){
            try {$copied+=Copy-EvidenceTail $file.FullName (Join-Path $dest $file.Name)}catch{$errors+=$_.Exception.Message}
        }
    }
    Save-EvidenceJson (Join-Path $dest 'manifest.json') @{version=1;createdAt=[DateTimeOffset]::Now.ToString('o');bootTime=([DateTimeOffset]$bootTime).ToString('o');classification=if($abnormal.Count){'abnormal-boot-evidence'}else{'boot-snapshot-unclassified'};abnormalEventCount=$abnormal.Count;files=$copied;errors=$errors;limits='Last two log dates per stream; last 8 MiB per file, final partial row omitted. Event lookback 3 days, maximum 5000. Dumps indexed only. Missing events do not prove a clean shutdown.'}
    return $dest
}
