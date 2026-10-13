$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot
$utf8=[Text.UTF8Encoding]::new($false)
foreach($mode in @('success','failure','evidence-error')){
    $root=Join-Path $env:TEMP ('pcdiag-update-simulation-'+[guid]::NewGuid().ToString('N'))
    $codeRoot=Join-Path $root 'installed';$dataRoot=Join-Path $root 'data';$package=Join-Path $root 'package'
    foreach($dir in @($codeRoot,$dataRoot,(Join-Path $dataRoot 'logs'),(Join-Path $codeRoot 'management'),(Join-Path $codeRoot 'collectors'),(Join-Path $package 'management'),(Join-Path $package 'collectors'))){[void][IO.Directory]::CreateDirectory($dir)}
    [IO.File]::WriteAllText((Join-Path $dataRoot 'migration.json'),'{"phase":"active"}',$utf8)
    $files=@('pcdiag.exe','collectors\Evidence-Core.ps1','collectors\Start-EvidenceLogging.ps1','collectors\Start-AutomaticCpuLogging.ps1','collectors\Start-MotherboardLogging.ps1','collectors\Start-ContinuousDiagnostics.ps1','collectors\Read-NvidiaDiagnostics.ps1','management\Run-Recorder.ps1','management\Manage-Recorder.ps1')
    foreach($file in $files){
        [IO.File]::WriteAllText((Join-Path $package $file),'# synthetic update fixture',$utf8)
        if($file -notin @('collectors\Evidence-Core.ps1','collectors\Start-EvidenceLogging.ps1')){[IO.File]::WriteAllText((Join-Path $codeRoot $file),'# previous synthetic fixture',$utf8)}
    }
    Copy-Item (Join-Path $repo 'collectors\Evidence-Core.ps1') (Join-Path $package 'collectors\Evidence-Core.ps1')
    $oldManager='param([string]$Action); exit 0 # previous synthetic manager'
    [IO.File]::WriteAllText((Join-Path $codeRoot 'management\Manage-Recorder.ps1'),$oldManager,$utf8)
    $newManager=if($mode -eq 'failure'){'param([string]$Action); if($Action -eq "start"){exit 1};exit 0'}else{
        'param([string]$Action);if($Action -eq "start"){$root="'+$dataRoot+'";$row=@{time=[DateTimeOffset]::Now.ToString("o");event="heartbeat";channels=@(@{channel="System";watermark=123});errors=@()}|ConvertTo-Json -Compress -Depth 5;[IO.File]::WriteAllText((Join-Path $root ("logs\evidence-"+(Get-Date -Format yyyyMMdd)+".jsonl")),$row+"`n")};exit 0'
    }
    if($mode -eq 'evidence-error'){$newManager=$newManager.Replace('errors=@()','errors=@(@{error="synthetic evidence failure"})')}
    [IO.File]::WriteAllText((Join-Path $package 'management\Manage-Recorder.ps1'),$newManager,$utf8)
    $manifest=@{files=@($files|ForEach-Object {@{path=$_;sha256=(Get-FileHash (Join-Path $package $_)).Hash}})}
    [IO.File]::WriteAllText((Join-Path $package 'update-manifest.json'),($manifest|ConvertTo-Json -Depth 5),$utf8)
    $source=Get-Content (Join-Path $repo 'management\Update-Recorder.ps1') -Raw
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
