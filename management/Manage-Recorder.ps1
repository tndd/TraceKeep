param([Parameter(Mandatory=$true)][ValidateSet('install','start','stop','restart','rollback')][string]$Action,[string]$LegacyActivityRoot)
$ErrorActionPreference='Stop'
$principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Open an Administrator terminal for recorder management. Read-only pcdiag status/logs/export do not require elevation.'}
$codeRoot=Join-Path $env:ProgramFiles 'PCDiagnostics'
$dataRoot=Join-Path $env:ProgramData 'PCDiagnostics'
$logRoot=Join-Path $dataRoot 'logs'
$oldRoot=Join-Path $env:ProgramFiles 'CodexPCDiagnostics'
$taskName='PC Diagnostics Recorder'
$statePath=Join-Path $dataRoot 'migration.json'
$shell=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$utf8=[Text.UTF8Encoding]::new($false)
function Write-Json($path,$value){[IO.File]::WriteAllText($path,($value|ConvertTo-Json -Depth 8),$utf8)}
function Protect-Directory($path){
    [void][IO.Directory]::CreateDirectory($path)
    $acl=[Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true,$false)
    foreach($rule in @(@('S-1-5-18','FullControl'),@('S-1-5-32-544','FullControl'),@('S-1-5-32-545','ReadAndExecute'))){
        $sid=[Security.Principal.SecurityIdentifier]::new($rule[0])
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,$rule[1],'ContainerInherit,ObjectInherit','None','Allow'))
    }
    Set-Acl -LiteralPath $path -AclObject $acl
}
function Clear-Markers {
    foreach($path in @((Join-Path $dataRoot 'STOP-ALL'),(Join-Path $logRoot 'STOP-CPU'),(Join-Path $logRoot 'STOP-BOARD'),(Join-Path $logRoot 'STOP'),(Join-Path $logRoot 'STOP-EVIDENCE'))){if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path}}
}
function Stop-Unified {
    $task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if($task){Disable-ScheduledTask -TaskName $taskName|Out-Null;[IO.File]::WriteAllText((Join-Path $dataRoot 'STOP-ALL'),'requested by pcdiag',$utf8)
        $deadline=(Get-Date).AddSeconds(25)
        do {Start-Sleep -Seconds 1;$task=Get-ScheduledTask -TaskName $taskName}while($task.State -eq 'Running' -and (Get-Date) -lt $deadline)
        if($task.State -eq 'Running'){Stop-ScheduledTask -TaskName $taskName}
        # Only recorder processes executing this protected installation are eligible.
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'"|Where-Object {$_.CommandLine -and $_.CommandLine.Contains('"'+$codeRoot+'\collectors\')}|ForEach-Object {Stop-Process -Id $_.ProcessId -ErrorAction SilentlyContinue}
    }
}
function Start-Unified {
    if(-not(Test-Path (Join-Path $dataRoot 'sources.json'))){throw 'Unified installation is not active. Run install first.'}
    Clear-Markers
    Enable-ScheduledTask -TaskName $taskName|Out-Null
    Start-ScheduledTask -TaskName $taskName
}
function Verify-Fresh([DateTimeOffset]$since,[int]$TimeoutSeconds=40){
    $deadline=(Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $ready=$true
        foreach($prefix in @('cpu-auto-','board-auto-','activity-')){
            $file=Get-ChildItem -LiteralPath $logRoot -Filter ($prefix+'*.jsonl')|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 1
            $records=if($file){@(Get-Content -Encoding UTF8 -LiteralPath $file.FullName -Tail 5|ForEach-Object {try{$_|ConvertFrom-Json}catch{}})}else{@()}
            $fresh=@($records|Where-Object {$_.time -and ([DateTimeOffset]$_.time) -ge $since})
            if($fresh.Count -lt 3 -or ([DateTimeOffset]::Now-([DateTimeOffset]$fresh[-1].time)).TotalSeconds -gt 10){$ready=$false;continue}
            if($prefix -eq 'cpu-auto-' -and -not @($fresh[-1].sensors|Where-Object type -EQ 'Temperature').Count){$ready=$false}
            if($prefix -eq 'board-auto-' -and -not @($fresh[-1].sensors|Where-Object {$_.type -eq 'Voltage' -and $_.available}).Count){$ready=$false}
            if($prefix -eq 'activity-' -and ($fresh[-1].errors.Count -gt 0 -or -not $fresh[-1].gpu -or -not $fresh[-1].gpu[0].temperatureC)){$ready=$false}
        }
        if($ready){return}
        Start-Sleep -Seconds 2
    }while((Get-Date) -lt $deadline)
    throw 'The unified recorder did not produce three fresh usable samples from every stream.'
}
function Restore-Legacy($state){
    Stop-Unified
    if(Test-Path (Join-Path $dataRoot 'sources.json')){Move-Item -LiteralPath (Join-Path $dataRoot 'sources.json') -Destination (Join-Path $dataRoot 'sources.inactive.json') -Force}
    foreach($old in $state.tasks){
        Register-ScheduledTask -TaskName $old.name -Xml (Get-Content -Encoding UTF8 -LiteralPath $old.xml -Raw) -Force|Out-Null
        if($old.running){Start-ScheduledTask -TaskName $old.name}
    }
    if($state.startupBackup -and (Test-Path -LiteralPath $state.startupBackup)){Copy-Item -LiteralPath $state.startupBackup -Destination $state.startupPath -Force}
    if($state.activityWasRunning){
        # The old activity script is user-writable: never relaunch it elevated.
        $recoveryName='PC Diagnostics Legacy Activity Recovery'
        $existing=Get-ScheduledTask -TaskName $recoveryName -ErrorAction SilentlyContinue
        if($existing -and -not $existing.Actions[0].Arguments.Contains('"'+$state.activityScript+'"')){throw 'Unexpected legacy recovery task already exists.'}
        $recoveryAction=New-ScheduledTaskAction -Execute $shell -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$state.activityScript+'"')
        $recoveryOwner=New-ScheduledTaskPrincipal -UserId $state.activityUserSid -LogonType Interactive -RunLevel Limited
        $recoverySettings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName $recoveryName -Action $recoveryAction -Principal $recoveryOwner -Settings $recoverySettings -Force|Out-Null
        Start-ScheduledTask -TaskName $recoveryName
    }
    $state.phase='rolled-back';Write-Json $statePath $state
}
if($Action -eq 'rollback'){
    if(-not(Test-Path $statePath)){throw 'No migration record exists.'}
    $state=Get-Content -Encoding UTF8 -LiteralPath $statePath -Raw|ConvertFrom-Json
    if($state.phase -eq 'rolled-back'){Write-Output 'Legacy recording was already restored.';exit 0}
    Restore-Legacy $state
    Write-Output 'Legacy tasks and startup entry restored. All old and unified logs retained.';exit 0
}
if($Action -ne 'install'){
    if($Action -in @('stop','restart')){Stop-Unified}
    if($Action -in @('start','restart')){$since=[DateTimeOffset]::Now;Start-Unified;Verify-Fresh $since}
    Write-Output ('Recorder action completed: '+$Action);exit 0
}

# Complete all preflight checks before touching a running task.
if(Test-Path $statePath){throw 'A migration record already exists. Inspect pcdiag doctor; use rollback for recovery. Reinstallation is intentionally not automatic.'}
if((Test-Path -LiteralPath $codeRoot) -or (Test-Path -LiteralPath $dataRoot)){throw 'Installation directories already exist without a migration record. Inspect them before proceeding; existing directories will not be repurposed.'}
if(-not $LegacyActivityRoot -or $LegacyActivityRoot.Contains('"')){throw 'Specify the existing activity log directory without quote characters.'}
$LegacyActivityRoot=(Resolve-Path -LiteralPath $LegacyActivityRoot).Path
$activityScript=Join-Path (Split-Path $LegacyActivityRoot) 'Start-ContinuousDiagnostics.ps1'
if(-not(Test-Path -LiteralPath $activityScript)){throw 'Legacy activity recorder script was not found beside the log directory.'}
if(-not(Test-Path (Join-Path $oldRoot 'library\LibreHardwareMonitorLib.dll'))){throw 'Existing protected sensor library was not found. No driver or library will be downloaded.'}
$package=Split-Path $PSScriptRoot
foreach($file in @('pcdiag.exe','pc-diagnostics.exe','management\Run-Recorder.ps1','management\Manage-Recorder.ps1','collectors\Start-AutomaticCpuLogging.ps1','collectors\Start-MotherboardLogging.ps1','collectors\Start-ContinuousDiagnostics.ps1','collectors\Read-NvidiaDiagnostics.ps1','collectors\Evidence-Core.ps1','collectors\Start-EvidenceLogging.ps1')){if(-not(Test-Path (Join-Path $package $file))){throw "Incomplete package: $file"}}
$legacyTasks=@()
foreach($name in @('Codex Automatic CPU Diagnostics','Codex Automatic Motherboard Diagnostics')){
    $t=Get-ScheduledTask -TaskName $name
    $expectedScript=Join-Path $oldRoot $(if($name -like '*Motherboard*'){'Start-MotherboardLogging.ps1'}else{'Start-AutomaticCpuLogging.ps1'})
    if($t.Actions.Count -ne 1 -or $t.Actions[0].Execute -ine $shell -or -not $t.Actions[0].Arguments.Contains('"'+$expectedScript+'"')){throw "Unexpected legacy task action: $name"}
    $legacyTasks+=,$t
}
if(Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue){throw 'Unified task already exists; refusing to replace it.'}
$activityProcesses=@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'"|Where-Object {$_.CommandLine -and $_.CommandLine.Contains('"'+$activityScript+'"')})
$startupPath=Join-Path ([Environment]::GetFolderPath('Startup')) 'PC Diagnostics Logger.lnk'
if(Test-Path -LiteralPath $startupPath){$link=(New-Object -ComObject WScript.Shell).CreateShortcut($startupPath);if($link.TargetPath -ine $shell -or -not $link.Arguments.Contains('"'+$activityScript+'"')){throw 'Unexpected startup shortcut target.'}}
$activitySid=if($activityProcesses.Count){(Invoke-CimMethod -InputObject $activityProcesses[0] -MethodName GetOwnerSid).Sid}else{[Security.Principal.WindowsIdentity]::GetCurrent().User.Value}
if(-not $activitySid){throw 'Cannot resolve the original activity recorder owner.'}
foreach($marker in @((Join-Path $oldRoot 'sensor-logs\STOP-CPU'),(Join-Path $oldRoot 'sensor-logs\STOP-BOARD'),(Join-Path $LegacyActivityRoot 'STOP'))){if(Test-Path -LiteralPath $marker){throw "An intentional stop marker exists: $marker"}}
Protect-Directory $codeRoot
Protect-Directory $dataRoot
Protect-Directory $logRoot
$backup=Join-Path $dataRoot ('migration-backup-'+(Get-Date -Format yyyyMMdd-HHmmss));Protect-Directory $backup
foreach($dir in @('management','collectors')){Copy-Item -LiteralPath (Join-Path $package $dir) -Destination $codeRoot -Recurse -Force}
foreach($file in @('pcdiag.exe','pc-diagnostics.exe')){Copy-Item -LiteralPath (Join-Path $package $file) -Destination $codeRoot -Force}
Copy-Item -LiteralPath (Join-Path $oldRoot 'library') -Destination $codeRoot -Recurse -Force
$state=[ordered]@{phase='prepared';time=[DateTimeOffset]::Now.ToString('o');tasks=@();activityScript=$activityScript;activityUserSid=$activitySid;activityWasRunning=($activityProcesses.Count -gt 0);legacyActivityRoot=$LegacyActivityRoot;startupPath=$startupPath;startupBackup=$null;logRoot=$logRoot}
foreach($t in $legacyTasks){$xml=Join-Path $backup ($t.TaskName+'.xml');[IO.File]::WriteAllText($xml,(Export-ScheduledTask -TaskName $t.TaskName),$utf8);$state.tasks+=@{name=$t.TaskName;running=($t.State -eq 'Running');xml=$xml}}
if(Test-Path -LiteralPath $startupPath){$state.startupBackup=Join-Path $backup 'PC Diagnostics Logger.lnk';Copy-Item -LiteralPath $startupPath -Destination $state.startupBackup}
Write-Json $statePath $state
$changed=$false
try {
    $changed=$true;$state.phase='switching';Write-Json $statePath $state
    foreach($t in $legacyTasks){Disable-ScheduledTask -TaskName $t.TaskName|Out-Null;Stop-ScheduledTask -TaskName $t.TaskName}
    if(Test-Path -LiteralPath $startupPath){Remove-Item -LiteralPath $startupPath}
    foreach($p in $activityProcesses){$live=Get-CimInstance Win32_Process -Filter "ProcessId=$($p.ProcessId)";if($live -and $live.CreationDate -eq $p.CreationDate -and $live.CommandLine -eq $p.CommandLine){Stop-Process -Id $p.ProcessId -ErrorAction Stop}}
    # Sources are no longer being appended. Preserve original files, copy complete history.
    foreach($root in @((Join-Path $oldRoot 'sensor-logs'),$LegacyActivityRoot)){
        Get-ChildItem -LiteralPath $root -Filter '*.jsonl'|Where-Object {$_.Name -match '^(cpu-auto|board-auto|activity|events|sessions|errors)-'}|ForEach-Object {
            $dest=Join-Path $logRoot $_.Name
            if(Test-Path -LiteralPath $dest){throw "Destination history already exists: $dest"}
            Copy-Item -LiteralPath $_.FullName -Destination $dest
        }
    }
    $sources=@{sensorRoot=$logRoot;activityRoot=$logRoot};Write-Json (Join-Path $dataRoot 'sources.json') $sources
    $actionArgs='-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+(Join-Path $codeRoot 'management\Run-Recorder.ps1')+'" -DataRoot "'+$dataRoot+'"'
    $taskAction=New-ScheduledTaskAction -Execute $shell -Argument $actionArgs -WorkingDirectory $codeRoot
    $trigger=New-ScheduledTaskTrigger -AtStartup
    $owner=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $taskName -Action $taskAction -Trigger $trigger -Principal $owner -Settings $settings -Description 'Unified read-only CPU, motherboard, GPU and Windows event recording. Independent workers, shared logs, bounded restart watchdog.'|Out-Null
    $since=[DateTimeOffset]::Now;Start-Unified;Verify-Fresh $since
    $state.phase='active';$state.verifiedAt=[DateTimeOffset]::Now.ToString('o');Write-Json $statePath $state
    Write-Json (Join-Path $dataRoot 'installation.json') @{codeRoot=$codeRoot;dataRoot=$dataRoot;task=$taskName;verifiedAt=$state.verifiedAt;bootRestartTested=$false}
    [pscustomobject]@{status='Unified recording verified';command=(Join-Path $codeRoot 'pcdiag.exe');logs=$logRoot;task=$taskName;legacyTasks='disabled, retained for rollback';history='copied, originals retained';bootRestartTested=$false}|ConvertTo-Json
} catch {
    $failure=$_.Exception.Message
    if($changed){try{Restore-Legacy ([pscustomobject]$state)}catch{throw "Migration failed: $failure. Rollback also needs attention: $($_.Exception.Message). See $statePath"}}
    throw "Migration failed and legacy recording was restored: $failure"
}
