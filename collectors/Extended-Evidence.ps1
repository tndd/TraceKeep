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
function Copy-DiagnosticArchive($Files,$ArchiveRoot,$Limits,[int]$BudgetSeconds=20) {
    [void][IO.Directory]::CreateDirectory($ArchiveRoot)
    $timer=[Diagnostics.Stopwatch]::StartNew();$results=@();$count=0
    foreach($item in $Files){
        if($count -ge $Limits.maxFilesPerPass -or $timer.Elapsed.TotalSeconds -ge $BudgetSeconds){$results+=@{status='deferred';reason='pass-budget';remainingFiles=(@($Files).Count-$count)};break}
        $count++
        $identity=$item.FullName+'|'+$item.Length+'|'+$item.LastWriteTimeUtc.Ticks
        $sha=[Security.Cryptography.SHA256]::Create();try {$key=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($identity)))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
        $receipt=Join-Path $ArchiveRoot ($key+'.json');$dest=Join-Path $ArchiveRoot ($key+$item.Extension);$partial=$dest+'.partial'
        if(Test-Path $receipt){$saved=Get-Content -Encoding UTF8 $receipt -Raw|ConvertFrom-Json;if((Test-Path $dest) -and (Get-Item $dest).Length -eq $item.Length){continue}}
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
                $row.status='archived';$row.destination=$dest;Save-EvidenceJson $receipt $row
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
    return @{status=if($scan.issues.Count -or $scan.limited -or @($rows|Where-Object status -NE 'archived').Count){'partial'}else{'ok'};data=@{discovered=$files.Count;scanLimited=$scan.limited;files=$rows};issues=$scan.issues}
}
function Get-LogSpaceEvidence($DataRoot,$Limits) {
    $drive=[IO.DriveInfo]::new([IO.Path]::GetPathRoot($DataRoot))
    $logs=Get-ChildItem -LiteralPath (Join-Path $DataRoot 'logs') -File|Measure-Object Length -Sum
    $archive=if(Test-Path (Join-Path $DataRoot 'archive')){(Get-ChildItem (Join-Path $DataRoot 'archive') -Recurse -File|Measure-Object Length -Sum).Sum}else{0}
    return @{status=if($drive.AvailableFreeSpace -lt $Limits.reserveFreeBytes){'warning'}else{'ok'};issues=@();data=@{freeBytes=$drive.AvailableFreeSpace;totalBytes=$drive.TotalSize;logBytes=$logs.Sum;archiveBytes=$archive;reserveFreeBytes=$Limits.reserveFreeBytes;automaticDeletion=$false}}
}
