param([switch]$Native)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('pcdiag-coordinator-test-'+[guid]::NewGuid().ToString('N'))
$dataRoot=Join-Path $testRoot 'data'
$logRoot=Join-Path $dataRoot 'logs'
$utf8=[Text.UTF8Encoding]::new($false)
foreach($dir in @('management','collectors','data\logs')){[void][IO.Directory]::CreateDirectory((Join-Path $testRoot $dir))}
Copy-Item (Join-Path $repo 'collectors\Collection-Settings.ps1') (Join-Path $testRoot 'collectors\Collection-Settings.ps1')
Copy-Item (Join-Path $repo 'collectors\Log-Storage.ps1') (Join-Path $testRoot 'collectors\Log-Storage.ps1')
$codeRoot=$testRoot
if($Native){Copy-Item (Join-Path $repo 'recorder\target\release\tracekeep-worker.exe') (Join-Path $testRoot 'tracekeep-worker.exe')}
# Isolate the test's mutex. Native mode uses read-only WMI/registry/filesystem; sensor and driver collectors stay mocked.
$source=Get-Content (Join-Path $repo 'management\Run-Recorder.ps1') -Raw
$source=$source.Replace('Global\PCDiagnostics-Coordinator-v1',('Local\PCDiagnostics-Test-'+[guid]::NewGuid().ToString('N')))
[IO.File]::WriteAllText((Join-Path $testRoot 'management\Run-Recorder.ps1'),$source,$utf8)
foreach($e in @(@('Start-AutomaticCpuLogging.ps1','cpu-auto'),@('Start-MotherboardLogging.ps1','board-auto'),@('Start-ContinuousDiagnostics.ps1','activity'),@('Start-EvidenceLogging.ps1','evidence'),@('Start-ExtendedLogging.ps1','extended'),@('Start-LogMaintenance.ps1','maintenance'))){
    $fake=@'
param([string]$LogRoot,[string]$LibraryDirectory,[int]$IntervalMilliseconds,[string]$Module,[string]$RunId,[string]$SettingsPath)
$prefix=if($Module){'module-'+$Module}else{'PREFIX'}
$path=Join-Path $LogRoot ($prefix+'-'+(Get-Date -Format yyyyMMdd)+'.jsonl')
$row=@{runId=$RunId;status='ok';completedAt=[DateTimeOffset]::Now.ToString('o');time=[DateTimeOffset]::Now.ToString('o');session='simulation';sequence=0;errors=@();gpu=@(@{temperatureC='50'});sensors=@(@{type='Temperature';value=50},@{type='Voltage';available=$true;value=12})}|ConvertTo-Json -Compress -Depth 5
if($prefix -eq 'evidence'){$row=$row.Replace('"errors":[]','"errors":[{"error":"synthetic provider failure before exit"}]')}
[IO.File]::AppendAllText($path,$row+"`n",[Text.UTF8Encoding]::new($false))
if($Module){$directory=Join-Path (Split-Path $LogRoot) 'module-state';[void][IO.Directory]::CreateDirectory($directory);[IO.File]::WriteAllText((Join-Path $directory ($Module+'.json')),$row,[Text.UTF8Encoding]::new($false))}
# Exit deliberately: the coordinator should relaunch this simulated worker.
'@
    [IO.File]::WriteAllText((Join-Path $testRoot ('collectors\'+$e[0])),$fake.Replace('PREFIX',$e[1]),$utf8)
}
$shell=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$proc=Start-Process -FilePath $shell -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $testRoot 'management\Run-Recorder.ps1')+'" -DataRoot "'+$dataRoot+'"') -WindowStyle Hidden -PassThru -RedirectStandardError (Join-Path $testRoot 'stderr.txt')
$null=$proc.Handle
try {
    $deadline=(Get-Date).AddSeconds(30)
    $expectedRestarts=if($Native){8}else{18}
    do {Start-Sleep -Seconds 1;$runtimePath=Join-Path $dataRoot 'runtime.json';$state=if(Test-Path $runtimePath){Get-Content $runtimePath -Raw|ConvertFrom-Json}else{$null};$restarted=$state -and @($state.workers|Where-Object recentRestarts -GE 1).Count -eq $expectedRestarts}while(-not $restarted -and (Get-Date) -lt $deadline -and -not $proc.HasExited)
    if(-not $restarted){throw ('Supervisor did not restart all simulated workers. '+(Get-Content (Join-Path $testRoot 'stderr.txt') -Raw))}
    $failedRows=@(Get-Content (Join-Path $logRoot ('evidence-'+(Get-Date -Format yyyyMMdd)+'.jsonl'))|ConvertFrom-Json)
    if(-not $failedRows[-1].errors.Count){throw 'Error-before-exit restart regression fixture was not exercised'}
    if($Native){
        $nativeWorkers=@($state.workers|Where-Object backend -EQ 'rust')
        if($nativeWorkers.Count -ne 10 -or @($nativeWorkers|Where-Object state -NE 'recording').Count){throw 'Rust workers were not selected and recording'}
        $peerIds=@{};foreach($w in $nativeWorkers|Where-Object name -NE 'module-performance'){$peerIds[$w.name]=$w.pid}
        $victim=Get-Process -Id ($nativeWorkers|Where-Object name -EQ 'module-performance').pid
        $null=$victim.Handle;$victim.Kill();$null=$victim.WaitForExit(5000);$victim.Dispose()
        $deadline=(Get-Date).AddSeconds(30);$recovered=$false
        do {
            Start-Sleep -Milliseconds 500
            $state=try {Get-Content $runtimePath -Raw -ErrorAction Stop|ConvertFrom-Json}catch{$null}
            $replacement=$state.workers|Where-Object name -EQ 'module-performance'
            $recovered=$replacement.recentRestarts -ge 1 -and $replacement.state -eq 'recording'
        }while(-not $recovered -and (Get-Date) -lt $deadline)
        if(-not $recovered){throw 'Native failure did not recover'}
        foreach($name in $peerIds.Keys){if(($state.workers|Where-Object name -EQ $name).pid -ne $peerIds[$name]){throw ('Native peer restarted unexpectedly: '+$name)}}
    }
    [IO.File]::WriteAllText((Join-Path $dataRoot 'STOP-ALL'),'test stop',$utf8)
    if(-not $proc.WaitForExit(15000)){throw 'Supervisor did not stop'}
    if($proc.ExitCode -ne 0){throw ('Supervisor failed: '+(Get-Content (Join-Path $testRoot 'stderr.txt') -Raw))}
    foreach($prefix in @('cpu-auto','board-auto','activity','evidence')){if(@(Get-Content (Join-Path $logRoot ($prefix+'-'+(Get-Date -Format yyyyMMdd)+'.jsonl'))).Count -lt 2){throw "Missing restarted samples: $prefix"}}
    . (Join-Path $testRoot 'collectors\Collection-Settings.ps1')
    $disabled=Get-CollectionDefaults;$disabled.modules.cpu.enabled=$false
    [IO.File]::WriteAllText((Join-Path $dataRoot 'collection-settings.json'),($disabled|ConvertTo-Json -Depth 6),$utf8)
    $cpuFile=Join-Path $logRoot ('cpu-auto-'+(Get-Date -Format yyyyMMdd)+'.jsonl');$cpuHash=(Get-FileHash $cpuFile).Hash
    Remove-Item -LiteralPath (Join-Path $dataRoot 'STOP-ALL')
    $proc.Dispose();$proc=Start-Process -FilePath $shell -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $testRoot 'management\Run-Recorder.ps1')+'" -DataRoot "'+$dataRoot+'"') -WindowStyle Hidden -PassThru
    $null=$proc.Handle;Start-Sleep -Seconds 4
    $state=Get-Content (Join-Path $dataRoot 'runtime.json') -Raw|ConvertFrom-Json;$cpuWorker=$state.workers|Where-Object name -EQ 'cpu'
    if($cpuWorker.state -ne 'disabled' -or $cpuWorker.pid -or (Get-FileHash $cpuFile).Hash -ne $cpuHash){throw 'Disabled sensor worker still launched or changed logs'}
    [IO.File]::WriteAllText((Join-Path $dataRoot 'STOP-ALL'),'test stop',$utf8);if(-not $proc.WaitForExit(15000)){throw 'Disabled worker simulation did not stop'}
    Remove-Item -LiteralPath (Join-Path $dataRoot 'collection-settings.json')
    # Extract only this verification function; never execute the migration script body.
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'management\Manage-Recorder.ps1'),[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'Management script parse failed'}
    $definition=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Verify-Fresh'},$true)
    Invoke-Expression $definition.Extent.Text
    # Three correctly dated but empty samples must never validate a migration.
    foreach($prefix in @('cpu-auto','board-auto','activity')){
        $path=Join-Path $logRoot ($prefix+'-'+(Get-Date -Format yyyyMMdd)+'.jsonl')
        $row=@{runId=$RunId;status='ok';completedAt=[DateTimeOffset]::Now.ToString('o');time=[DateTimeOffset]::Now.ToString('o');errors=@()}|ConvertTo-Json -Compress
        [IO.File]::WriteAllText($path,(($row+"`n")*3),$utf8)
    }
    $rejected=$false
    try {Verify-Fresh ([DateTimeOffset]::Now.AddMinutes(-1)) 0}catch{$rejected=$true}
    if(-not $rejected){throw 'Empty samples were incorrectly accepted'}
    # Validate the rollback orchestration with mocked scheduler operations only.
    $restore=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Restore-Legacy'},$true)
    Invoke-Expression $restore.Extent.Text
    $script:restored=@();$script:started=@();$script:stopped=$false;$script:rollbackLevel=''
    function Stop-Unified {$script:stopped=$true}
    function Register-ScheduledTask {param($TaskName,$Xml,$Action,$Principal,$Settings,[switch]$Force);$script:restored+=,$TaskName}
    function Start-ScheduledTask {param($TaskName);$script:started+=,$TaskName}
    function Get-ScheduledTask {param($TaskName,$ErrorAction);return $null}
    function New-ScheduledTaskAction {param($Execute,$Argument);return @{Execute=$Execute;Arguments=$Argument}}
    function New-ScheduledTaskPrincipal {param($UserId,$LogonType,$RunLevel);$script:rollbackLevel=$RunLevel;return @{UserId=$UserId}}
    function New-ScheduledTaskSettingsSet {param($ExecutionTimeLimit,$MultipleInstances,[switch]$AllowStartIfOnBatteries,[switch]$DontStopIfGoingOnBatteries);return @{}}
    function Write-Json($path,$value){[IO.File]::WriteAllText($path,($value|ConvertTo-Json -Depth 8),$utf8)}
    $statePath=Join-Path $dataRoot 'migration.json'
    $xml=Join-Path $testRoot 'old-task.xml';[IO.File]::WriteAllText($xml,'<synthetic/>',$utf8)
    $saved=Join-Path $testRoot 'saved.lnk';[IO.File]::WriteAllText($saved,'synthetic shortcut',$utf8)
    [IO.File]::WriteAllText((Join-Path $dataRoot 'sources.json'),'{}',$utf8)
    $legacy=[pscustomobject]@{phase='active';tasks=@(@{name='Synthetic CPU';xml=$xml;running=$true});startupBackup=$saved;startupPath=(Join-Path $testRoot 'startup.lnk');activityWasRunning=$true;activityScript='C:\synthetic\worker.ps1';activityUserSid='S-1-5-21-1-2-3-1001'}
    Restore-Legacy $legacy
    if(-not $script:stopped -or 'Synthetic CPU' -notin $script:started -or $script:rollbackLevel -ne 'Limited' -or $legacy.phase -ne 'rolled-back' -or (Test-Path (Join-Path $dataRoot 'sources.json')) -or -not(Test-Path $legacy.startupPath)){throw 'Rollback failed to restore the expected legacy state'}
    Write-Output 'PASS: simulated worker recovery, shared logs, orderly stop, empty-reading rejection, rollback restores legacy tasks without elevating user scripts.'
} finally {
    if(-not $proc.HasExited){[IO.File]::WriteAllText((Join-Path $dataRoot 'STOP-ALL'),'test cleanup',$utf8);if(-not $proc.WaitForExit(15000)){$proc.Kill()}}
    $proc.Dispose()
    # Keep the small synthetic test directory for failure inspection; never delete user logs.
}
