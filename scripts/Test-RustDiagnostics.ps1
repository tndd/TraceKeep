param([string]$Worker,[string]$Cli)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot
if(-not $Worker){$Worker=Join-Path $repo 'recorder\target\release\tracekeep-worker.exe'}
if(-not $Cli){$Cli=Join-Path $repo 'src-tauri\target\release\pcdiag.exe'}
. (Join-Path $repo 'collectors\Evidence-Core.ps1')
. (Join-Path $repo 'collectors\Collection-Settings.ps1')
. (Join-Path $repo 'collectors\Extended-Evidence.ps1')
. (Join-Path $repo 'collectors\Read-NvidiaDiagnostics.ps1')
function Assert($condition,$message){if(-not $condition){throw $message}}
$root=Join-Path $env:TEMP ('tracekeep-native-diagnostics-'+[guid]::NewGuid().ToString('N'))
$logs=Join-Path $root 'logs';[void][IO.Directory]::CreateDirectory($logs)
$settings=Join-Path $root 'active-collection-settings.json'
$config=Get-CollectionDefaults
foreach($name in @($config.modules.Keys)){$config.modules[$name].enabled=($name -in @('inventory','power','gpuDetails','crashConfiguration'))}
Save-EvidenceJson $settings $config
$settingsHash=(Get-FileHash $settings).Hash
$start=[DateTimeOffset]::Now.AddSeconds(-1)
function Run([string]$module,[switch]$Failure){
    $stderr=Join-Path $root ($module+'-stderr.txt')
    $p=Start-Process $Worker -ArgumentList ('--log-root "'+$logs+'" --settings "'+$settings+'" --module '+$module+' --run-id native-diagnostics-test --samples 1') -WindowStyle Hidden -PassThru -RedirectStandardError $stderr
    $null=$p.Handle
    try{
        Assert ($p.WaitForExit(90000)) ('Native module timed out: '+$module)
        if($Failure){Assert ($p.ExitCode -ne 0) 'Duplicate owner was accepted'}
        else{Assert ($p.ExitCode -eq 0) ('Native module failed: '+$module+' '+(Get-Content $stderr -Raw))}
    }finally{if(-not $p.HasExited){$p.Kill();$null=$p.WaitForExit(5000)};$p.Dispose()}
}
foreach($module in @('inventory','power','gpuDetails','crashConfiguration')){
    Run $module
    $row=Get-Content (Join-Path $logs ('detail-'+$module+'-'+(Get-Date -Format yyyyMMdd)+'.jsonl')) -Tail 1|ConvertFrom-Json
    if($module -eq 'crashConfiguration'){
        $snapshot=Get-Content (Join-Path $root 'crash-configuration.json') -Raw|ConvertFrom-Json
        $reference=Get-CrashConfiguration $root
        foreach($field in @('CrashDumpEnabled','DumpFile','MinidumpDir','AlwaysKeepMemoryDump','AutoReboot','LogEvent','DedicatedDumpFile','DumpFileSize')){Assert ($snapshot.settings.$field -eq $reference.settings.$field) ('Crash setting mismatch: '+$field)}
        Assert ($snapshot.policy.status -eq $reference.policy.status) 'Crash policy status differs'
        Assert ($snapshot.pagefiles.Count -eq $reference.pagefiles.Count -and $snapshot.volumes.Count -eq $reference.volumes.Count) 'Crash configuration source rows differ'
        continue
    }
    $reference=Get-ExtendedEvidence $module
    Assert ($row.status -eq $reference.status) ('Availability changed: '+$module+' '+($row.result.issues|ConvertTo-Json -Depth 8))
    if($module -eq 'inventory'){
        foreach($key in @('board','bios','cpu','memory','drivers','devices','disks','os','updates')){
            if(-not $reference.data.Contains($key)){continue}
            $actual=@($row.result.data.$key);$expected=@($reference.data[$key]|ConvertTo-Json -Depth 8|ConvertFrom-Json)
            # Match by stable row identity; provider ordering is not contractual.
            Assert ($actual.Count -eq $expected.Count) ('Inventory row count changed: '+$key)
            if($actual.Count){
                Assert ((@($actual[0].PSObject.Properties.Name|Sort-Object)-join ',') -eq (@($expected[0].PSObject.Properties.Name|Sort-Object)-join ',')) ('Inventory fields changed: '+$key)
                foreach($field in @('ReleaseDate','DriverDate','LastBootUpTime','InstallDate')){
                    if($field -in $actual[0].PSObject.Properties.Name){
                        Assert ((@($actual|ForEach-Object {$_.$field}|Sort-Object)-join ',') -eq (@($expected|ForEach-Object {$_.$field}|Sort-Object)-join ',')) ('Inventory date changed: '+$field)
                    }
                }
            }
        }
        $snapshot=Get-Content (Join-Path $root 'machine-inventory.json') -Raw|ConvertFrom-Json
        $expected=Get-MachineEvidence
        foreach($key in @('board','bios','cpu','memory','video','disk')){
            Assert (@($snapshot.$key).Count -eq @($expected[$key]).Count) ('Incident snapshot rows changed: '+$key)
            if(@($snapshot.$key).Count){
                Assert ((@($snapshot.$key[0].PSObject.Properties.Name|Sort-Object)-join ',') -eq (@($expected[$key][0].PSObject.Properties.Name|Sort-Object)-join ',')) ('Incident snapshot fields changed: '+$key)
            }
        }
    }elseif($module -eq 'power'){
        foreach($argument in @('/getactivescheme','/a','/qh')){
            if($reference.data.Contains($argument)){
                Assert ($row.result.data.$argument.Trim() -ceq $reference.data[$argument].Trim()) ('Power output/encoding changed: '+$argument)
            }
        }
    }elseif($row.status -eq 'ok'){
        [xml]$xml=$row.result.data.xml
        Assert ($xml.SelectNodes('//processes').Count -eq 0) 'GPU XML retained process identities'
        Assert ($xml.SelectNodes('//gpu').Count -gt 0) 'GPU XML lost devices'
    }
}
Run extended
$coverage=Get-Content (Join-Path $root 'coverage.json') -Raw|ConvertFrom-Json
Assert ($coverage.runId -eq 'native-diagnostics-test' -and $coverage.errors.Count -eq 0) 'Coverage lost fresh run status'
Assert ($coverage.modules.storage.status -eq 'disabled') 'Disabled storage group is not disabled'

# Old dates are synthetic. Maintenance must not touch today's results or unrelated files.
$todayFile=Join-Path $logs ('detail-inventory-'+(Get-Date -Format yyyyMMdd)+'.jsonl')
$todayHash=(Get-FileHash $todayFile).Hash
$old=Join-Path $logs 'synthetic-20000101.jsonl'
$yesterday=Join-Path $logs ('synthetic-'+(Get-Date).AddDays(-1).ToString('yyyyMMdd')+'.jsonl')
$bytes=[Text.Encoding]::UTF8.GetBytes("{partial`n{`"time`":`"2000-01-01T00:00:00Z`"}`n")
[IO.File]::WriteAllBytes($old,$bytes);[IO.File]::WriteAllBytes($yesterday,$bytes)
$oldHash=(Get-FileHash $old).Hash
Run maintenance
Assert (-not(Test-Path $old) -and (Test-Path ($old+'.gz'))) 'Old log was not compressed'
Test-DiagnosticGzip ($old+'.gz') $oldHash
Assert ((Get-Content ($old+'.gz.sha256') -Raw).Trim() -eq $oldHash) 'Compression receipt differs'
Assert ((Get-FileHash $todayFile).Hash -eq $todayHash -and (Test-Path $yesterday)) 'Recent logs changed'
foreach($module in @('inventory','power','gpuDetails','crashConfiguration','extended','maintenance')){
    $lockName=if($module -in @('extended','maintenance')){$module+'.owner.lock'}else{'module-'+$module+'.owner.lock'}
    $owner=[IO.FileStream]::new((Join-Path $logs $lockName),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try{Run $module -Failure}finally{$owner.Dispose()}
}
foreach($module in @('inventory','power','gpuDetails','crashConfiguration')){$config.modules[$module].enabled=$false}
Save-EvidenceJson $settings $config
foreach($module in @('inventory','power','gpuDetails','crashConfiguration')){
    $path=Join-Path $logs ('detail-'+$module+'-'+(Get-Date -Format yyyyMMdd)+'.jsonl')
    $hash=(Get-FileHash $path).Hash;Run $module
    Assert ((Get-FileHash $path).Hash -eq $hash) ('Disabled module changed log: '+$module)
}
$oldProgramData=$env:ProgramData
try{
    $env:ProgramData=Join-Path $root 'query'
    [void][IO.Directory]::CreateDirectory((Join-Path $env:ProgramData 'PCDiagnostics'))
    Save-EvidenceJson (Join-Path $env:ProgramData 'PCDiagnostics\sources.json') @{sensorRoot=$logs;activityRoot=$logs}
    $end=[DateTimeOffset]::Now.AddSeconds(1).ToString('o')
    $before=& $Cli history $start.ToString('o') $end|ConvertFrom-Json
    Assert ($LASTEXITCODE -eq 0) 'Native diagnostic raw history failed'
    foreach($file in Get-ChildItem $logs -Filter '*.jsonl'){$null=Compress-DiagnosticLog $file.FullName}
    $after=& $Cli history $start.ToString('o') $end|ConvertFrom-Json
    Assert ($LASTEXITCODE -eq 0) 'Native diagnostic gzip history failed'
    foreach($module in @('inventory','power','gpuDetails','collectorHealth')){
        Assert ($before.streams.$module.rows.Count -gt 0) ('Missing diagnostic history: '+$module)
        Assert (($before.streams.$module|ConvertTo-Json -Depth 30 -Compress) -ceq ($after.streams.$module|ConvertTo-Json -Depth 30 -Compress)) ('Raw/gzip history differs: '+$module)
    }
}finally{$env:ProgramData=$oldProgramData}
Write-Output 'PASS: native inventory and incident snapshot parity, power encoding, GPU privacy, coverage, verified retention, ownership, opt-out and gzip history'
