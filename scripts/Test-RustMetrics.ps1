param([string]$Worker,[string]$Cli)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot
if(-not $Worker){$Worker=Join-Path $repo 'recorder\target\release\tracekeep-worker.exe'}
if(-not $Cli){$Cli=Join-Path $repo 'src-tauri\target\release\pcdiag.exe'}
. (Join-Path $repo 'collectors\Evidence-Core.ps1')
. (Join-Path $repo 'collectors\Collection-Settings.ps1')
. (Join-Path $repo 'collectors\Extended-Evidence.ps1')
function Assert($Value,$Message){if(-not $Value){throw $Message}}
$root=Join-Path $env:TEMP ('tracekeep-metrics-'+[guid]::NewGuid().ToString('N'))
$logs=Join-Path $root 'logs';$settings=Join-Path $root 'active-collection-settings.json'
[void][IO.Directory]::CreateDirectory((Join-Path $logs 'nested'))
[void][IO.Directory]::CreateDirectory((Join-Path $root 'archive\nested'))
[IO.File]::WriteAllText((Join-Path $logs 'nested\excluded'),'not a top-level log')
[IO.File]::WriteAllBytes((Join-Path $root 'archive\a'),[byte[]](1,2,3))
[IO.File]::WriteAllBytes((Join-Path $root 'archive\nested\b'),[byte[]](1,2,3,4,5))
$config=Get-CollectionDefaults
$config.limits.reserveFreeBytes=1
Save-EvidenceJson $settings $config
$start=[DateTimeOffset]::Now.AddSeconds(-1)
function Sample([string]$Module){
    $p=Start-Process $Worker -ArgumentList ('--log-root "'+$logs+'" --settings "'+$settings+'" --module '+$Module+' --run-id isolated-metrics-test --samples 1') -WindowStyle Hidden -PassThru -RedirectStandardError (Join-Path $root ($Module+'-stderr.txt'))
    $null=$p.Handle
    try{
        Assert ($p.WaitForExit(60000)) ('Native sample timed out: '+$Module)
        Assert ($p.ExitCode -eq 0) ('Native sample failed: '+$Module+' '+(Get-Content (Join-Path $root ($Module+'-stderr.txt')) -Raw))
    }finally{if(-not $p.HasExited){$p.Kill();$null=$p.WaitForExit(5000)};$p.Dispose()}
    $file=Join-Path $logs ('detail-'+$Module+'-'+(Get-Date -Format yyyyMMdd)+'.jsonl')
    return (Get-Content $file -Tail 1 -Encoding UTF8|ConvertFrom-Json)
}

$performance=Sample performance
Assert ($performance.status -eq 'ok') 'Native performance provider incomplete'
$expected=Get-ExtendedEvidence performance
Assert ($expected.status -eq 'ok') 'Reference performance provider incomplete'
foreach($key in @('cpu','memory','disks','diskLatencyRaw','system')){
    $rows=@($performance.result.data.$key);$reference=@($expected.data[$key])
    Assert ($rows.Count -gt 0 -and $reference.Count -gt 0) ('Missing performance source: '+$key)
    $fields=@($reference[0].PSObject.Properties.Name|Sort-Object)
    foreach($row in $rows){
        Assert ((@($row.PSObject.Properties.Name|Sort-Object) -join ',') -ceq ($fields -join ',')) ('Counter schema changed: '+$key)
        foreach($field in $fields|Where-Object {$_ -ne 'Name'}){
            Assert ($null -eq $row.$field -or $row.$field -is [ValueType]) ('Counter changed to text: '+$key+'.'+$field)
        }
    }
}
$reliability=Sample reliability
$expected=Get-ExtendedEvidence reliability
Assert ($reliability.status -eq $expected.status) 'Reliability availability differs'
if($expected.status -eq 'ok'){
    $reference=@{};foreach($row in $expected.data.records){$reference[[string]$row.RecordNumber]=$row|ConvertTo-Json|ConvertFrom-Json}
    foreach($row in @($reliability.result.data.records)){
        $match=$reference[[string]$row.RecordNumber]
        Assert ($null -ne $match) 'Reliability record not found in reference query'
        foreach($field in @('RecordNumber','SourceName','EventIdentifier','TimeGenerated','ProductName','Message','Logfile')){
            Assert ($row.$field -ceq $match.$field) ('Reliability field mismatch: '+$field)
        }
    }
}

$disk=Sample diskSpace
Assert ($disk.status -eq 'ok' -and $disk.result.data.archiveBytes -eq 8) 'Archive accounting mismatch'
$moduleFile=Join-Path $logs ('module-diskSpace-'+(Get-Date -Format yyyyMMdd)+'.jsonl')
$detailFile=Join-Path $logs ('detail-diskSpace-'+(Get-Date -Format yyyyMMdd)+'.jsonl')
$completion=Get-Content $moduleFile -Tail 1 -Encoding UTF8
$finalBytes=(Get-ChildItem $logs -File|Measure-Object Length -Sum).Sum
$expectedLogBytes=$finalBytes-(Get-Item $detailFile).Length-[Text.Encoding]::UTF8.GetByteCount($completion+"`n")
Assert ($disk.result.data.logBytes -eq $expectedLogBytes) 'Top-level log byte count mismatch'
$drive=[IO.DriveInfo]::new([IO.Path]::GetPathRoot($root))
Assert ($disk.result.data.totalBytes -eq $drive.TotalSize -and $disk.result.data.freeBytes -gt 0) 'Drive capacity changed'
Assert (-not $disk.result.data.automaticDeletion -and $disk.result.data.reserveFreeBytes -eq 1) 'Space policy changed'
$config.limits.reserveFreeBytes=[long]::MaxValue
Save-EvidenceJson $settings $config
Assert ((Sample diskSpace).status -eq 'warning') 'Low space did not warn'
Assert ((Get-Item (Join-Path $root 'archive\a')).Length -eq 3) 'Space collector deleted data'
# Junctions cannot cause recursive scans outside the fixture or silent undercounts.
$link=Join-Path $root 'archive\junction'
$null=New-Item -ItemType Junction -Path $link -Value (Join-Path $logs 'nested')
$config.limits.reserveFreeBytes=1
Save-EvidenceJson $settings $config
$partial=Sample diskSpace
Assert ($partial.status -eq 'partial' -and $null -eq $partial.result.data.archiveBytes -and $partial.result.issues.Count -gt 0) 'Incomplete archive scan reported a complete byte count'

# Opt-out returns without appending or starting a collection session.
foreach($module in @('performance','reliability','diskSpace')){
    $config.modules[$module].enabled=$false
}
Save-EvidenceJson $settings $config
foreach($module in @('performance','reliability','diskSpace')){
    $file=Join-Path $logs ('detail-'+$module+'-'+(Get-Date -Format yyyyMMdd)+'.jsonl')
    $hash=(Get-FileHash $file).Hash
    $null=Sample $module
    Assert ((Get-FileHash $file).Hash -eq $hash) ('Disabled native module wrote a record: '+$module)
}

$oldProgramData=$env:ProgramData
try {
    $env:ProgramData=Join-Path $root 'query'
    [void][IO.Directory]::CreateDirectory((Join-Path $env:ProgramData 'PCDiagnostics'))
    Save-EvidenceJson (Join-Path $env:ProgramData 'PCDiagnostics\sources.json') @{sensorRoot=$logs;activityRoot=$logs}
    $end=[DateTimeOffset]::Now.AddSeconds(1).ToString('o')
    $before=& $Cli history $start.ToString('o') $end|ConvertFrom-Json
    Assert ($LASTEXITCODE -eq 0) 'Native metrics raw history failed'
    foreach($file in Get-ChildItem $logs -Filter '*.jsonl'){$null=Compress-DiagnosticLog $file.FullName}
    $after=& $Cli history $start.ToString('o') $end|ConvertFrom-Json
    Assert ($LASTEXITCODE -eq 0) 'Native metrics gzip history failed'
    foreach($module in @('performance','reliability','diskSpace')){
        Assert ($before.streams.$module.rows.Count -gt 0) ('Missing native history: '+$module)
        Assert (($before.streams.$module|ConvertTo-Json -Depth 30 -Compress) -ceq ($after.streams.$module|ConvertTo-Json -Depth 30 -Compress)) ('Raw/gzip history mismatch: '+$module)
        Assert ($after.streams.$module.invalidLines -eq 0 -and $after.streams.$module.unresolvedReferences -eq 0) ('Invalid native history: '+$module)
    }
}finally{$env:ProgramData=$oldProgramData}
Write-Output 'PASS: native performance schema, reliability field/date parity, space accounting/warnings/junction bounds, opt-out and raw/gzip history'
