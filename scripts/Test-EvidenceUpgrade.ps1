$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot
$utf8=[Text.UTF8Encoding]::new($false)
# Exercise the production reader without invoking the elevated updater body.
$tokens=$null;$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'management\Update-Recorder.ps1'),[ref]$tokens,[ref]$parseErrors)
if($parseErrors){throw 'Updater parse failed'}
$definition=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Read-UpdateSnapshot'},$true)
Invoke-Expression $definition.Extent.Text
$summaryDefinition=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-UpdateDumpPolicySummary'},$true)
Invoke-Expression $summaryDefinition.Extent.Text
# A registry provider graph is irrelevant to the diagnostic values. Never walk it.
$provider=New-Object PSObject
$provider|Add-Member ScriptProperty ExpensiveGraph {throw 'Provider metadata was traversed'}
$policy=@{status='already-configured';current=[pscustomobject]@{CrashDumpEnabled=7;AlwaysKeepMemoryDump=1;DumpFile='%SystemRoot%\MEMORY.DMP';PSPath='synthetic';PSParentPath='synthetic';PSChildName='CrashControl';PSDrive=$provider;PSProvider=$provider};differences=@()}
$summary=Get-UpdateDumpPolicySummary $policy
$encoded=$summary|ConvertTo-Json -Depth 8
$decoded=$encoded|ConvertFrom-Json
if($decoded.current.CrashDumpEnabled -ne 7 -or $decoded.current.AlwaysKeepMemoryDump -ne 1 -or $decoded.current.DumpFile -ne '%SystemRoot%\MEMORY.DMP' -or $encoded.Length -gt 1000 -or @($decoded.current.PSObject.Properties.Name|Where-Object {$_ -like 'PS*'}).Count){throw 'Dump policy output retained provider metadata or lost registry values'}
Write-Output 'PASS: dump policy JSON excludes provider graphs and retains registry values'
$readerRoot=Join-Path $env:TEMP ('tracekeep-snapshot-reader-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($readerRoot)
$snapshot=Join-Path $readerRoot 'coverage.json'
[IO.File]::WriteAllText($snapshot,'{"status":"synthetic"}',$utf8)
# A short exclusive writer reproduces the sharing exception seen in deployment.
$lockScript=Join-Path $readerRoot 'lock.ps1'
[IO.File]::WriteAllText($lockScript,@'
param($Path,$Ready,$Release)
$ErrorActionPreference='Stop'
$stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try {
    [IO.File]::WriteAllText($Ready,'locked')
    $deadline=(Get-Date).AddSeconds(10)
    while(-not(Test-Path $Release) -and (Get-Date) -lt $deadline){Start-Sleep -Milliseconds 20}
    Start-Sleep -Milliseconds 500
}finally{$stream.Dispose()}
'@,$utf8)
$ready=Join-Path $readerRoot 'ready';$release=Join-Path $readerRoot 'release'
$locker=Start-Process powershell.exe -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "'+$lockScript+'" -Path "'+$snapshot+'" -Ready "'+$ready+'" -Release "'+$release+'"') -WindowStyle Hidden -PassThru
$null=$locker.Handle
try {
    $deadline=(Get-Date).AddSeconds(10)
    while(-not(Test-Path $ready) -and -not $locker.HasExited -and (Get-Date) -lt $deadline){Start-Sleep -Milliseconds 20}
    if(-not(Test-Path $ready)){throw 'Lock fixture failed'}
    $reproduced=$false;try {Get-Content -LiteralPath $snapshot -Raw -ErrorAction Stop|Out-Null}catch{$reproduced=$true}
    if(-not $reproduced){throw 'Original sharing failure did not reproduce'}
    [IO.File]::WriteAllText($release,'release after delay',$utf8)
    if((Read-UpdateSnapshot $snapshot).status -ne 'synthetic'){throw 'Transient sharing conflict did not recover'}
    $null=$locker.WaitForExit(5000)
    [IO.File]::WriteAllText($snapshot,'{invalid',$utf8)
    $rejected=$false;try {Read-UpdateSnapshot $snapshot|Out-Null}catch{$rejected=$true}
    if(-not $rejected){throw 'Invalid JSON accepted'}
    $hold=[IO.File]::Open($snapshot,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
        $rejected=$false;try {Read-UpdateSnapshot $snapshot|Out-Null}catch{$rejected=$true}
        if(-not $rejected){throw 'Persistent sharing conflict accepted'}
    }finally{$hold.Dispose()}
    Write-Output 'PASS: reproduced sharing violation, retry recovery, malformed and persistently locked snapshot rejection'
}finally{if(-not $locker.HasExited){$locker.Kill();$null=$locker.WaitForExit(5000)};$locker.Dispose()}
foreach($mode in @('success','failure','evidence-error','storage-missing','coverage-incomplete')){
    $root=Join-Path $env:TEMP ('pcdiag-update-simulation-'+[guid]::NewGuid().ToString('N'))
    $codeRoot=Join-Path $root 'installed';$dataRoot=Join-Path $root 'data';$package=Join-Path $root 'package'
    foreach($dir in @($codeRoot,$dataRoot,(Join-Path $dataRoot 'logs'),(Join-Path $codeRoot 'management'),(Join-Path $codeRoot 'collectors'),(Join-Path $package 'management'),(Join-Path $package 'collectors'))){[void][IO.Directory]::CreateDirectory($dir)}
    [IO.File]::WriteAllText((Join-Path $dataRoot 'migration.json'),'{"phase":"active"}',$utf8)
    $files=@('collectors\Log-Storage.ps1','collectors\Start-LogMaintenance.ps1','collectors\Collection-Settings.ps1','collectors\Extended-Evidence.ps1','collectors\Start-ExtendedLogging.ps1','management\Configure-Recorder.ps1','management\CrashDump-Policy.ps1','pcdiag.exe','tracekeep-worker.exe','collectors\Evidence-Core.ps1','collectors\Read-NvmeHealth.ps1','collectors\Start-EvidenceLogging.ps1','collectors\Start-AutomaticCpuLogging.ps1','collectors\Start-MotherboardLogging.ps1','collectors\Start-ContinuousDiagnostics.ps1','collectors\Read-NvidiaDiagnostics.ps1','management\Run-Recorder.ps1','management\Manage-Recorder.ps1')
    foreach($file in $files){
        [IO.File]::WriteAllText((Join-Path $package $file),'# synthetic update fixture',$utf8)
        if($file -notin @('collectors\Evidence-Core.ps1','collectors\Read-NvmeHealth.ps1','collectors\Start-EvidenceLogging.ps1')){[IO.File]::WriteAllText((Join-Path $codeRoot $file),'# previous synthetic fixture',$utf8)}
    }
    Copy-Item (Join-Path $repo 'collectors\Log-Storage.ps1') (Join-Path $package 'collectors\Log-Storage.ps1')
    Copy-Item (Join-Path $repo 'collectors\Evidence-Core.ps1') (Join-Path $package 'collectors\Evidence-Core.ps1')
    Copy-Item (Join-Path $repo 'collectors\Read-NvmeHealth.ps1') (Join-Path $package 'collectors\Read-NvmeHealth.ps1')
    Copy-Item (Join-Path $repo 'collectors\Collection-Settings.ps1') (Join-Path $package 'collectors\Collection-Settings.ps1')
    [IO.File]::WriteAllText((Join-Path $package 'management\CrashDump-Policy.ps1'),'function Enable-DiagnosticDumps($DataRoot){return @{status="simulated"}};function Restore-DiagnosticDumps($DataRoot){};function Protect-DiagnosticArchive($Path){}',$utf8)
    $oldManager='param([string]$Action); exit 0 # previous synthetic manager'
    [IO.File]::WriteAllText((Join-Path $codeRoot 'management\Manage-Recorder.ps1'),$oldManager,$utf8)
    $newManager=if($mode -eq 'failure'){'param([string]$Action); if($Action -eq "start"){exit 1};exit 0'}else{
        'param([string]$Action);if($Action -eq "start"){$root="'+$dataRoot+'";$row=@{time=[DateTimeOffset]::Now.ToString("o");event="heartbeat";channels=@(@{channel="System";watermark=123});errors=@()}|ConvertTo-Json -Compress -Depth 5;[IO.File]::WriteAllText((Join-Path $root ("logs\evidence-"+(Get-Date -Format yyyyMMdd)+".jsonl")),$row+"`n")};exit 0'
    }
    if($mode -eq 'evidence-error'){$newManager=$newManager.Replace('errors=@()','errors=@(@{error="synthetic evidence failure"})')}
    if($mode -in @('success','coverage-incomplete')){
        $storageFixture='$storage=@{time=[DateTimeOffset]::Now.ToString("o");nvme=@{disks=@();errors=@()}}|ConvertTo-Json -Compress -Depth 5;[IO.File]::WriteAllText((Join-Path $root ("logs\storage-"+(Get-Date -Format yyyyMMdd)+".jsonl")),$storage+"`n");. (Join-Path (Split-Path $PSScriptRoot) "collectors\Collection-Settings.ps1");$modules=@{};foreach($n in Get-IsolatedCollectionModules){$modules[$n]=@{status="ok";completedAt=[DateTimeOffset]::Now.ToString("o")}};$coverage=@{time=[DateTimeOffset]::Now.ToString("o");modules=$modules}|ConvertTo-Json -Depth 5;[IO.File]::WriteAllText((Join-Path $root "coverage.json"),$coverage);'
        $newManager=$newManager.Replace('$row=@{',$storageFixture+'$row=@{')
    }
    if($mode -eq 'coverage-incomplete'){$newManager=$newManager.Replace('status="ok"','status="collecting"')}
    [IO.File]::WriteAllText((Join-Path $package 'management\Manage-Recorder.ps1'),$newManager,$utf8)
    $manifest=@{files=@($files|ForEach-Object {@{path=$_;sha256=(Get-FileHash (Join-Path $package $_)).Hash}})}
    [IO.File]::WriteAllText((Join-Path $package 'update-manifest.json'),($manifest|ConvertTo-Json -Depth 5),$utf8)
    $source=Get-Content (Join-Path $repo 'management\Update-Recorder.ps1') -Raw
    $source=$source.Replace('AddSeconds(150)','AddSeconds(2)')
    $start=$source.IndexOf('$principal=');$end=$source.IndexOf('$package=',$start)
    if($start -lt 0 -or $end -lt 0){throw 'Unable to isolate production roots and elevation guard'}
    $source=$source.Remove($start,$end-$start).Insert($start,('$codeRoot="'+$codeRoot+'";$dataRoot="'+$dataRoot+'";$logRoot=Join-Path $dataRoot "logs"'+"`n"))
    if($source.Contains('$env:ProgramFiles') -or $source.Contains('$env:ProgramData')){throw 'Simulation retained production roots'}
    [IO.File]::WriteAllText((Join-Path $package 'management\Update-Recorder.ps1'),$source,$utf8)
    $global:pcdiagSimulationRoot=$codeRoot
    function Get-ScheduledTask {param($TaskName);return [pscustomobject]@{State='Running';Actions=@([pscustomobject]@{Execute=(Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe');Arguments=('-File "'+(Join-Path $global:pcdiagSimulationRoot 'management\Run-Recorder.ps1')+'"')})}}
    $failed=$false
    try {& (Join-Path $package 'management\Update-Recorder.ps1')|Out-Null}catch{if($mode -eq 'success'){throw};$failed=$true}
    $audit=Get-ChildItem $dataRoot -Recurse -Filter 'update.json'|Select-Object -First 1
    if(-not $audit){throw 'No update audit'}
    $state=Get-Content $audit.FullName -Raw|ConvertFrom-Json
    if($mode -eq 'success' -and $state.phase -ne 'active'){throw 'Successful update did not verify evidence'}
    if($mode -ne 'success'){
        if(-not $failed -or $state.phase -ne 'rolled-back' -or (Get-Content (Join-Path $codeRoot 'management\Manage-Recorder.ps1') -Raw) -ne $oldManager -or (Test-Path (Join-Path $codeRoot 'collectors\Start-EvidenceLogging.ps1'))){throw 'Failed update did not restore original fixtures'}
    }
}
Write-Output 'PASS: update verification and rollback exercised with isolated files and synthetic managers; no production tasks or logs touched.'
