function Get-CollectionDefaults {
    $modules=[ordered]@{}
    foreach($entry in @(
        @('cpu',2,'CPU sensors'),@('board',2,'Motherboard sensors'),@('activity',2,'GPU and aggregate load'),
        @('events',15,'System, Application and enabled diagnostic channels'),@('storage',300,'Windows storage reliability'),@('nvme',300,'Controller SMART health'),@('nvmeErrors',300,'NVMe error log and identify capabilities'),
        @('crashConfiguration',300,'Dump, pagefile and free-space configuration'),@('configurationJournal',15,'Observed configuration history and active recorder configuration'),@('incidents',15,'Bounded boot evidence snapshots'),
        @('performance',15,'Memory, per-disk latency, CPU interrupt and DPC counters'),@('gpuDetails',60,'NVIDIA XML: PCIe, power, clocks, memory, ECC and throttling; process entries removed'),@('processes',30,'Process name, PID, CPU time, memory and handles; no command lines'),
        @('inventory',1800,'Firmware, drivers, PnP devices, disks and memory topology'),@('reliability',300,'Windows reliability records, seven-day window'),
        @('power',300,'Power plan, wake reasons, battery and ACPI thermal data'),@('dumpArchive',60,'Preserve stable crash dumps locally'),@('werArchive',300,'Preserve Windows Report.wer files locally'),
        @('diskSpace',60,'Log growth and free-space warnings'),@('automaticDump',300,'Configure automatic dump and retention; preserve original settings')
    )){$modules[$entry[0]]=[ordered]@{enabled=$true;intervalSeconds=[int]$entry[1];description=$entry[2]}}
    return [ordered]@{schemaVersion=1;modules=$modules;limits=[ordered]@{maxArchiveFileBytes=34359738368;maxArchiveBytes=68719476736;reserveFreeBytes=10737418240;maxFilesPerPass=64};note='All diagnostic groups enabled by default. Limits produce explicit gaps; no automatic deletion. Configuration changes apply after recorder restart.'}
}
function Get-CollectionSettings([string]$DataRoot,[string]$SettingsPath) {
    $settings=Get-CollectionDefaults
    $path=if($SettingsPath){$SettingsPath}else{Join-Path $DataRoot 'collection-settings.json'}
    if($SettingsPath -and -not(Test-Path -LiteralPath $path)){throw 'Active recorder configuration is missing'}
    if(-not(Test-Path -LiteralPath $path)){return $settings}
    $saved=Get-Content -Encoding UTF8 -LiteralPath $path -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
    if($saved.schemaVersion -ne 1){throw 'Unsupported collection settings schema'}
    foreach($p in $saved.PSObject.Properties){if($p.Name -notin @('schemaVersion','modules','limits','note')){throw ('Unknown settings property: '+$p.Name)}}
    foreach($p in $saved.modules.PSObject.Properties){
        if(-not $settings.modules.Contains($p.Name)){throw ('Unknown collection module: '+$p.Name)}
        foreach($q in $p.Value.PSObject.Properties){if($q.Name -notin @('enabled','intervalSeconds','description')){throw ('Unknown module setting: '+$q.Name)}}
        if($p.Value.enabled -isnot [bool]){throw ('Enabled must be boolean: '+$p.Name)}
        $settings.modules[$p.Name].enabled=$p.Value.enabled
        if($null -ne $p.Value.intervalSeconds){
            $v=$p.Value.intervalSeconds
            $min=if($p.Name -in @('cpu','board','activity')){1}else{15};$max=if($p.Name -in @('cpu','board','activity')){5}else{86400}
            if($v -isnot [int] -and $v -isnot [long]){throw 'Intervals must be integer seconds'}
            if($v -lt $min -or $v -gt $max){throw ('Interval out of range: '+$p.Name)}
            $settings.modules[$p.Name].intervalSeconds=[int]$v
        }
    }
    foreach($p in $saved.limits.PSObject.Properties){
        if(-not $settings.limits.Contains($p.Name) -or ($p.Value -isnot [long] -and $p.Value -isnot [int]) -or $p.Value -lt 1){throw 'Invalid collection limit'}
        if($p.Name -eq 'maxFilesPerPass' -and $p.Value -gt 1024){throw 'File pass limit exceeds 1024'}
        $settings.limits[$p.Name]=[long]$p.Value
    }
    return $settings
}
function Get-IsolatedCollectionModules {
    return @('performance','processes','gpuDetails','inventory','reliability','power','dumpArchive','werArchive','diskSpace','storage','crashConfiguration','configurationJournal')
}
function Test-CollectionModuleEnabled($Config,[string]$Name) {
    if($Name -eq 'storage'){return ($Config.modules.storage.enabled -or $Config.modules.nvme.enabled -or $Config.modules.nvmeErrors.enabled)}
    return $Config.modules[$Name].enabled
}
function Get-CollectionModuleInterval($Config,[string]$Name) {
    if($Name -eq 'storage'){return (@('storage','nvme','nvmeErrors')|Where-Object {$Config.modules[$_].enabled}|ForEach-Object {$Config.modules[$_].intervalSeconds}|Measure-Object -Minimum).Minimum}
    return $Config.modules[$Name].intervalSeconds
}
function Test-CollectionCoverageReady($Coverage,$Config,[DateTimeOffset]$Since) {
    if(-not $Coverage.time -or ([DateTimeOffset]$Coverage.time) -lt $Since){return $false}
    foreach($name in Get-IsolatedCollectionModules){
        $state=$Coverage.modules.$name
        if(-not(Test-CollectionModuleEnabled $Config $name)){
            if($state.status -ne 'disabled'){return $false}
        }elseif($state.status -notin @('ok','partial') -or -not $state.completedAt -or ([DateTimeOffset]$state.completedAt) -lt $Since){return $false}
    }
    return $true
}
