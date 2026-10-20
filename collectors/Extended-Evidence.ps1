function Get-ExtendedNextDeadline([double]$DueMs,[double]$CompletedMs,[double]$IntervalMs) {
    if($IntervalMs -le 0){throw 'Interval must be positive'}
    $next=$DueMs+$IntervalMs
    $missed=if($next -lt $CompletedMs){[Math]::Ceiling(($CompletedMs-$next)/$IntervalMs)}else{0}
    return @{nextMs=($next+$missed*$IntervalMs);missedIntervals=[long]$missed}
}
function Add-ExtendedResult($LogRoot,[string]$Name,$Result,[hashtable]$Hashes,[DateTimeOffset]$Started,[long]$DurationMs,[DateTimeOffset]$Now=[DateTimeOffset]::Now,$Schedule=$null) {
    $json=$Result|ConvertTo-Json -Depth 12 -Compress
    $sha=[Security.Cryptography.SHA256]::Create()
    try {$hash=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($json)))).Replace('-','')}finally{$sha.Dispose()}
    $day=$Now.LocalDateTime.ToString('yyyyMMdd')
    $unchanged=$Hashes.ContainsKey($Name) -and $Hashes[$Name].day -eq $day -and $Hashes[$Name].hash -eq $hash
    $record=@{time=$Now.ToString('o');startedAt=$Started.ToString('o');monotonicTicks=[Diagnostics.Stopwatch]::GetTimestamp();monotonicFrequency=[Diagnostics.Stopwatch]::Frequency;module=$Name;durationMs=$DurationMs;status=$Result.status;sha256=$hash;unchanged=$unchanged}
    if($Schedule){$record.schedule=$Schedule}
    if(-not $unchanged){$record.result=$Result}
    # Filename and reference scope use the same captured date, including midnight.
    # Commit the reference only after the full record has reached durable storage.
    Add-EvidenceRecord $LogRoot ('detail-'+$Name) $record -Day $day
    $Hashes[$Name]=@{day=$day;hash=$hash}
    return $record
}
function Read-DiagnosticClass($Class,$Properties,$Namespace='root/cimv2',$Filter) {
    $args=@{ClassName=$Class;Namespace=$Namespace;ErrorAction='Stop';OperationTimeoutSec=8}
    if($Filter){$args.Filter=$Filter}
    return @(Get-CimInstance @args|Select-Object -Property $Properties)
}
function Get-ExtendedEvidence($Module) {
    $data=[ordered]@{};$issues=@()
    $queries=@(switch($Module){
        'performance' {@(
            @('cpu','Win32_PerfFormattedData_PerfOS_Processor',@('Name','PercentProcessorTime','PercentPrivilegedTime','PercentInterruptTime','PercentDPCTime','InterruptsPersec','DPCsQueuedPersec')),
            @('memory','Win32_PerfFormattedData_PerfOS_Memory',@('AvailableMBytes','CommittedBytes','CommitLimit','PercentCommittedBytesInUse','PagesInputPersec','PagesOutputPersec','PageReadsPersec','PageWritesPersec','PoolNonpagedBytes','PoolPagedBytes')),
            @('disks','Win32_PerfFormattedData_PerfDisk_PhysicalDisk',@('Name','CurrentDiskQueueLength','AvgDisksecPerRead','AvgDisksecPerWrite','AvgDisksecPerTransfer','DiskReadsPersec','DiskWritesPersec','DiskReadBytesPersec','DiskWriteBytesPersec','PercentIdleTime','SplitIOPerSec')),
            @('diskLatencyRaw','Win32_PerfRawData_PerfDisk_PhysicalDisk',@('Name','AvgDisksecPerRead','AvgDisksecPerRead_Base','AvgDisksecPerWrite','AvgDisksecPerWrite_Base','AvgDisksecPerTransfer','AvgDisksecPerTransfer_Base','Frequency_PerfTime','Timestamp_PerfTime')),
            @('system','Win32_PerfFormattedData_PerfOS_System',@('ProcessorQueueLength','ContextSwitchesPersec','Threads','Processes','SystemUpTime'))
        )}
        'processes' {,@('processes','Win32_Process',@('Name','ProcessId','ParentProcessId','CreationDate','KernelModeTime','UserModeTime','WorkingSetSize','PrivatePageCount','PageFaults','HandleCount','ThreadCount','ReadTransferCount','WriteTransferCount'))}
        'inventory' {@(
            @('board','Win32_BaseBoard',@('Manufacturer','Product','Version')),
            @('bios','Win32_BIOS',@('Manufacturer','SMBIOSBIOSVersion','ReleaseDate')),
            @('cpu','Win32_Processor',@('Name','NumberOfCores','NumberOfLogicalProcessors','MaxClockSpeed','CurrentClockSpeed')),
            @('memory','Win32_PhysicalMemory',@('BankLabel','DeviceLocator','Manufacturer','PartNumber','Capacity','Speed','ConfiguredClockSpeed','ConfiguredVoltage','MinVoltage','MaxVoltage')),
            @('drivers','Win32_PnPSignedDriver',@('DeviceName','DeviceClass','DeviceID','DriverVersion','DriverDate','DriverProviderName','InfName','IsSigned')),
            @('devices','Win32_PnPEntity',@('Name','PNPClass','DeviceID','Service','Status','ConfigManagerErrorCode')),
            @('disks','Win32_DiskDrive',@('Index','Model','FirmwareRevision','InterfaceType','Size','Status')),
            @('os','Win32_OperatingSystem',@('Version','BuildNumber','LastBootUpTime','InstallDate','OSArchitecture')),
            @('updates','Win32_QuickFixEngineering',@('HotFixID','InstalledOn','Description'))
        )}
        'power' {,@('batteries','Win32_Battery',@('Name','BatteryStatus','EstimatedChargeRemaining','EstimatedRunTime','Status'))}
        default {@()}
    })
    foreach($q in $queries){
        try {$data[$q[0]]=@(Read-DiagnosticClass $q[1] $q[2])}catch{$issues+=@{source=$q[0];status='unavailable';error=$_.Exception.Message}}
    }
    if($Module -eq 'power'){
        foreach($arg in @('/getactivescheme','/requests','/lastwake','/waketimers','/a','/qh')){
            try {$data[$arg]=Invoke-DiagnosticProcess (Join-Path $env:WINDIR 'System32\powercfg.exe') $arg 5000 ([Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage))}catch{$issues+=@{source=$arg;status='unavailable';error=$_.Exception.Message}}
        }
        try {$data.thermalZones=@(Read-DiagnosticClass 'MSAcpi_ThermalZoneTemperature' @('InstanceName','CurrentTemperature','CriticalTripPoint','PassiveTripPoint','ThermalStamp') 'root/wmi')}catch{$issues+=@{source='ACPI thermal zones';status='unavailable';error=$_.Exception.Message}}
    }
    if($Module -eq 'reliability'){
        try {
            $since=[Management.ManagementDateTimeConverter]::ToDmtfDateTime((Get-Date).AddDays(-7))
            $data.records=@(Read-DiagnosticClass 'Win32_ReliabilityRecords' @('RecordNumber','SourceName','EventIdentifier','TimeGenerated','ProductName','Message','Logfile') 'root/cimv2' ("TimeGenerated >= '"+$since+"'"))
        }catch{$issues+=@{source='reliability';status='unavailable';error=$_.Exception.Message}}
    }
    if($Module -eq 'gpuDetails'){
        try {
            $exe=Get-ChildItem -Path (Join-Path $env:WINDIR 'System32\DriverStore\FileRepository\nv*\nvidia-smi.exe') -ErrorAction Stop|Select-Object -First 1 -ExpandProperty FullName
            if(-not $exe){throw 'NVIDIA diagnostics executable unavailable'}
            [xml]$xml=Invoke-DiagnosticProcess $exe '-q -x' 5000
            foreach($node in @($xml.SelectNodes('//processes'))){[void]$node.ParentNode.RemoveChild($node)}
            $data.xml=$xml.OuterXml
        }catch{$issues+=@{source='nvidia-smi XML';status='unavailable';error=$_.Exception.Message}}
    }
    return @{data=$data;issues=$issues;status=if($issues.Count){'partial'}else{'ok'}}
}
function Get-DiagnosticFiles($Roots,$Pattern,[int]$Limit=512) {
    $files=@();$issues=@();$queue=[Collections.Generic.Queue[string]]::new()
    foreach($root in $Roots){if(Test-Path -LiteralPath $root){$queue.Enqueue($root)}}
    $visited=0
    while($queue.Count -and $files.Count -lt $Limit -and $visited -lt 2048){
        $dir=$queue.Dequeue();$visited++
        try {foreach($item in @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction Stop)){
            if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){continue}
            if($item.PSIsContainer){$queue.Enqueue($item.FullName)}elseif($item.Name -like $Pattern){$files+=$item;if($files.Count -ge $Limit){break}}
        }}catch{$issues+=@{path=$dir;error=$_.Exception.Message}}
    }
    return @{files=$files;limited=($queue.Count -gt 0 -or $files.Count -ge $Limit);issues=$issues}
}
function Get-DiagnosticDumpValidation([string]$Path) {
    # Lightweight structural checks, not a debugger verdict. All bytes are retained.
    $stream=[IO.File]::OpenRead($Path)
    try {
        if($stream.Length -eq 0){return @{version=1;status='invalid';reason='empty-file';analysisVerified=$false}}
        $header=New-Object byte[] 32
        $count=$stream.Read($header,0,$header.Length)
        if($count -lt 8){return @{version=1;status='invalid';reason='incomplete-header';analysisVerified=$false}}
        $signature=[Text.Encoding]::ASCII.GetString($header,0,4)
        if($signature -eq 'MDMP'){
            if($count -lt 32){return @{version=1;status='invalid';reason='incomplete-minidump-header';analysisVerified=$false}}
            [long]$streams=[BitConverter]::ToUInt32($header,8);[long]$directory=[BitConverter]::ToUInt32($header,12)
            if($streams -eq 0 -or $directory -lt 32 -or $directory+$streams*12 -gt $stream.Length){
                return @{version=1;status='invalid';reason='incomplete-stream-directory';analysisVerified=$false}
            }
            if($streams -gt 4096){return @{version=1;status='unverified';reason='directory-check-budget';analysisVerified=$false}}
            [void]$stream.Seek($directory,[IO.SeekOrigin]::Begin)
            $entry=New-Object byte[] 12
            for($i=0;$i -lt $streams;$i++){
                if($stream.Read($entry,0,12) -ne 12){return @{version=1;status='invalid';reason='incomplete-stream-directory';analysisVerified=$false}}
                [long]$bytes=[BitConverter]::ToUInt32($entry,4);[long]$offset=[BitConverter]::ToUInt32($entry,8)
                if($offset+$bytes -gt $stream.Length){return @{version=1;status='invalid';reason='incomplete-stream-data';analysisVerified=$false}}
            }
            return @{version=1;status='structure-checked';format='minidump';analysisVerified=$false;note='Directory and stream ranges checked; nested contents and debugger analysis not verified'}
        }
        # Kernel dumps use a different format; do not label an unfamiliar format
        # corrupt merely because it is not a user-mode MINIDUMP_HEADER.
        return @{version=1;status='unverified';reason='format-requires-debugger';signature=$signature;analysisVerified=$false}
    }finally{$stream.Dispose()}
}
function Copy-DiagnosticArchive($Files,$ArchiveRoot,$Limits,[int]$BudgetSeconds=20) {
    [void][IO.Directory]::CreateDirectory($ArchiveRoot)
    $timer=[Diagnostics.Stopwatch]::StartNew();$results=@();$count=0
    foreach($item in $Files){
        if($count -ge $Limits.maxFilesPerPass -or $timer.Elapsed.TotalSeconds -ge $BudgetSeconds){$results+=@{status='deferred';reason='pass-budget';remainingFiles=(@($Files).Count-$count)};break}
        $count++
        $identity=$item.FullName+'|'+$item.Length+'|'+$item.LastWriteTimeUtc.Ticks
        $sha=[Security.Cryptography.SHA256]::Create();try {$key=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($identity)))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
        $receipt=Join-Path $ArchiveRoot ($key+'.json');$dest=Join-Path $ArchiveRoot ($key+$item.Extension);$partial=$dest+'.partial'
        if(Test-Path $receipt){
            $saved=Get-Content -Encoding UTF8 $receipt -Raw|ConvertFrom-Json
            if((Test-Path $dest) -and (Get-Item $dest).Length -eq $item.Length){
                if($item.Extension -ieq '.dmp'){
                    $validation=Get-DiagnosticDumpValidation $dest
                    if($saved.validation.version -ne $validation.version -or $saved.validation.status -ne $validation.status -or $saved.validation.reason -ne $validation.reason){
                        $saved|Add-Member -NotePropertyName validation -NotePropertyValue $validation -Force
                        Save-EvidenceJson $receipt $saved
                    }
                    # Persist the warning even when no new copy is necessary.
                    if($validation.status -ne 'structure-checked'){$results+=$saved}
                }
                continue
            }
        }
        $row=@{source=$item.FullName;bytes=$item.Length;sourceModifiedUtc=$item.LastWriteTimeUtc.ToString('o');status='pending'}
        if($item.Length -gt $Limits.maxArchiveFileBytes){$row.status='skipped';$row.reason='file-size-limit';$results+=$row;continue}
        if(([DateTime]::UtcNow-$item.LastWriteTimeUtc).TotalSeconds -lt 60){$row.reason='source-recent';$results+=$row;continue}
        try {
            $have=if(Test-Path $partial){(Get-Item $partial).Length}else{0}
            $total=(Get-ChildItem -LiteralPath $ArchiveRoot -File|Measure-Object Length -Sum).Sum
            $drive=[IO.DriveInfo]::new([IO.Path]::GetPathRoot($ArchiveRoot))
            if($total+$item.Length-$have -gt $Limits.maxArchiveBytes -or $drive.AvailableFreeSpace-($item.Length-$have) -lt $Limits.reserveFreeBytes){$row.status='skipped';$row.reason='archive-budget-or-free-space';$results+=$row;continue}
            # Exclusive against writers: actively written dumps remain pending.
            $source=[IO.FileStream]::new($item.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
            try {
                if($source.Length -ne $item.Length -or [IO.File]::GetLastWriteTimeUtc($item.FullName) -ne $item.LastWriteTimeUtc){throw 'Source changed since inventory'}
                $target=[IO.FileStream]::new($partial,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::Write,[IO.FileShare]::Read,1048576,[IO.FileOptions]::WriteThrough)
                try {
                    if($target.Length -gt $source.Length){throw 'Partial archive exceeds source length'}
                    [void]$source.Seek($target.Length,[IO.SeekOrigin]::Begin);[void]$target.Seek(0,[IO.SeekOrigin]::End)
                    $buffer=New-Object byte[] 1048576
                    while($timer.Elapsed.TotalSeconds -lt $BudgetSeconds -and ($n=$source.Read($buffer,0,$buffer.Length)) -gt 0){$target.Write($buffer,0,$n)}
                    $target.Flush($true);$complete=($target.Length -eq $source.Length)
                }finally{$target.Dispose()}
            }finally{$source.Dispose()}
            if($complete){
                $row.sha256=(Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash
                if(Test-Path $dest){if((Get-FileHash $dest).Hash -ne $row.sha256){throw 'Existing archive hash conflict; both copies retained'};Remove-Item -LiteralPath $partial}else{[IO.File]::Move($partial,$dest)}
                $row.status='archived';$row.destination=$dest
                if($item.Extension -ieq '.dmp'){$row.validation=Get-DiagnosticDumpValidation $dest}
                Save-EvidenceJson $receipt $row
            }else{$row.status='pending';$row.reason='copy-resumes-next-pass';$row.copiedBytes=(Get-Item $partial).Length}
        }catch{$row.status='unavailable';$row.error=$_.Exception.Message}
        $results+=$row
    }
    return $results
}
function Get-ArchiveEvidence($Module,$DataRoot,$Limits) {
    $roots=if($Module -eq 'dumpArchive'){@((Join-Path $env:WINDIR 'Minidump'),(Join-Path $env:WINDIR 'LiveKernelReports'))}else{@((Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportArchive'),(Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportQueue'))}
    $scan=Get-DiagnosticFiles $roots $(if($Module -eq 'dumpArchive'){'*.dmp'}else{'Report.wer'})
    if($Module -eq 'dumpArchive'){
        $dumpSettings=Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' -ErrorAction Stop
        foreach($path in @((Join-Path $env:WINDIR 'MEMORY.DMP'),$dumpSettings.DumpFile)){
            if($path){$path=[Environment]::ExpandEnvironmentVariables($path);if(Test-Path -LiteralPath $path -PathType Leaf){$scan.files+=Get-Item -LiteralPath $path}}
        }
        if($dumpSettings.MinidumpDir){$extra=Get-DiagnosticFiles @([Environment]::ExpandEnvironmentVariables($dumpSettings.MinidumpDir)) '*.dmp';$scan.files+=$extra.files;$scan.issues+=$extra.issues;$scan.limited=$scan.limited -or $extra.limited}
    }
    $files=@($scan.files|Sort-Object FullName -Unique|Sort-Object LastWriteTimeUtc -Descending)
    $rows=@(Copy-DiagnosticArchive $files (Join-Path $DataRoot ('archive\'+$Module)) $Limits)
    $qualityIssues=@($rows|Where-Object {$_.validation -and $_.validation.status -ne 'structure-checked'}|ForEach-Object {@{source=$_.source;status=$_.validation.status;reason=$_.validation.reason;bytesPreserved=$true}})
    return @{status=if($scan.issues.Count -or $scan.limited -or @($rows|Where-Object status -NE 'archived').Count -or $qualityIssues.Count){'partial'}else{'ok'};data=@{discovered=$files.Count;scanLimited=$scan.limited;files=$rows};issues=@($scan.issues)+$qualityIssues}
}
function Get-LogSpaceEvidence($DataRoot,$Limits) {
    $drive=[IO.DriveInfo]::new([IO.Path]::GetPathRoot($DataRoot))
    $logs=Get-ChildItem -LiteralPath (Join-Path $DataRoot 'logs') -File|Measure-Object Length -Sum
    $archive=if(Test-Path (Join-Path $DataRoot 'archive')){(Get-ChildItem (Join-Path $DataRoot 'archive') -Recurse -File|Measure-Object Length -Sum).Sum}else{0}
    return @{status=if($drive.AvailableFreeSpace -lt $Limits.reserveFreeBytes){'warning'}else{'ok'};issues=@();data=@{freeBytes=$drive.AvailableFreeSpace;totalBytes=$drive.TotalSize;logBytes=$logs.Sum;archiveBytes=$archive;reserveFreeBytes=$Limits.reserveFreeBytes;automaticDeletion=$false}}
}
