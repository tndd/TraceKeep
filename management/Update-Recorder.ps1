$ErrorActionPreference='Stop'
$principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Run this update once from an Administrator PowerShell.'}
$codeRoot=Join-Path $env:ProgramFiles 'PCDiagnostics';$dataRoot=Join-Path $env:ProgramData 'PCDiagnostics';$logRoot=Join-Path $dataRoot 'logs'
$package=Split-Path $PSScriptRoot
$shell=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$manager=Join-Path $codeRoot 'management\Manage-Recorder.ps1'
$manifest=Get-Content -Encoding UTF8 (Join-Path $package 'update-manifest.json') -Raw|ConvertFrom-Json
$migration=Get-Content -Encoding UTF8 (Join-Path $dataRoot 'migration.json') -Raw|ConvertFrom-Json
if($migration.phase -ne 'active'){throw 'The unified installation must be active before upgrading.'}
$task=Get-ScheduledTask -TaskName 'PC Diagnostics Recorder'
if($task.State -ne 'Running' -or $task.Actions.Count -ne 1 -or $task.Actions[0].Execute -ine $shell -or -not $task.Actions[0].Arguments.Contains('"'+(Join-Path $codeRoot 'management\Run-Recorder.ps1')+'"')){throw 'Unexpected or stopped recorder task; no changes made.'}
$files=@($manifest.files)
$expected=@('pcdiag.exe','collectors\Evidence-Core.ps1','collectors\Start-EvidenceLogging.ps1','collectors\Start-AutomaticCpuLogging.ps1','collectors\Start-MotherboardLogging.ps1','collectors\Start-ContinuousDiagnostics.ps1','collectors\Read-NvidiaDiagnostics.ps1','management\Run-Recorder.ps1','management\Manage-Recorder.ps1')
if($files.Count -ne $expected.Count){throw 'Unexpected update file count'}
foreach($entry in $files){
    if($entry.path -notin $expected){throw 'Unexpected update path'}
    if((Get-FileHash -LiteralPath (Join-Path $package $entry.path) -Algorithm SHA256).Hash -ne $entry.sha256){throw ('Update checksum failed: '+$entry.path)}
    if($entry.path.EndsWith('.ps1')){
        $tokens=$null;$errors=$null;[void][Management.Automation.Language.Parser]::ParseFile((Join-Path $package $entry.path),[ref]$tokens,[ref]$errors)
        if($errors.Count){throw ('Update syntax failed: '+$entry.path)}
    }
}
if(@($files.path|Select-Object -Unique).Count -ne $expected.Count){throw 'Duplicate update path'}
. (Join-Path $package 'collectors\Evidence-Core.ps1')
$backup=Join-Path $dataRoot ('update-backup-'+(Get-Date -Format yyyyMMdd-HHmmss)+'-'+[guid]::NewGuid().ToString('N').Substring(0,6))
[void][IO.Directory]::CreateDirectory($backup)
$oldFiles=@()
foreach($entry in $files){$old=Join-Path $codeRoot $entry.path;if(Test-Path -LiteralPath $old){$dest=Join-Path $backup $entry.path;[void][IO.Directory]::CreateDirectory((Split-Path $dest));Copy-Item -LiteralPath $old -Destination $dest;$oldFiles+=$entry.path}}
$audit=Join-Path $backup 'update.json'
Save-EvidenceJson $audit @{phase='prepared';time=[DateTimeOffset]::Now.ToString('o');files=$files;previousFiles=$oldFiles}
$changed=$false
try {
    $changed=$true
    & $shell -NoProfile -ExecutionPolicy Bypass -File $manager -Action stop
    if($LASTEXITCODE -ne 0){throw 'Could not stop recorder for update'}
    foreach($entry in $files){Copy-Item -LiteralPath (Join-Path $package $entry.path) -Destination (Join-Path $codeRoot $entry.path) -Force}
    $since=[DateTimeOffset]::Now
    & $shell -NoProfile -ExecutionPolicy Bypass -File $manager -Action start
    if($LASTEXITCODE -ne 0){throw 'Updated sensor workers failed verification'}
    $deadline=(Get-Date).AddSeconds(120);$verified=$false
    do {
        $file=Get-ChildItem -LiteralPath $logRoot -Filter 'evidence-*.jsonl'|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 1
        if($file){$row=Get-Content -Encoding UTF8 -LiteralPath $file.FullName -Tail 1|ConvertFrom-Json;if(Test-EvidenceReady $row $since){$verified=$true;break};if($row.event -eq 'heartbeat' -and ([DateTimeOffset]$row.time) -ge $since -and @($row.errors).Count -gt 0){throw 'Evidence worker reported errors; update cannot be marked successful. Inspect the retained evidence log.'}}
        Start-Sleep -Seconds 2
    }while((Get-Date) -lt $deadline)
    if(-not $verified){throw 'Evidence worker did not verify System event checkpointing'}
    Save-EvidenceJson $audit @{phase='active';verifiedAt=[DateTimeOffset]::Now.ToString('o');files=$files;previousFiles=$oldFiles;evidenceErrors=$row.errors}
    [pscustomobject]@{status='Evidence upgrade verified';logs=$logRoot;incidents=(Join-Path $dataRoot 'incidents');checkpoints=(Join-Path $dataRoot 'event-checkpoints');backup=$backup;eventIntervalSeconds=15;storageIntervalSeconds=300;sensorIntervalSeconds=2;evidenceErrors=$row.errors;bootRestartTested=$false}|ConvertTo-Json -Depth 6
}catch{
    $failure=$_.Exception.Message
    if($changed){
        try {
            & $shell -NoProfile -ExecutionPolicy Bypass -File $manager -Action stop
            if($LASTEXITCODE -ne 0){throw 'Rollback could not stop updated workers'}
            foreach($entry in $files){$dest=Join-Path $codeRoot $entry.path;if($entry.path -in $oldFiles){Copy-Item -LiteralPath (Join-Path $backup $entry.path) -Destination $dest -Force}elseif(Test-Path -LiteralPath $dest){Remove-Item -LiteralPath $dest}}
            & $shell -NoProfile -ExecutionPolicy Bypass -File $manager -Action start
            if($LASTEXITCODE -ne 0){throw 'Previous workers failed verification'}
            Save-EvidenceJson $audit @{phase='rolled-back';failure=$failure;time=[DateTimeOffset]::Now.ToString('o')}
        }catch{throw "Update failed: $failure. Rollback needs attention: $($_.Exception.Message). Backup: $backup"}
    }
    throw "Update failed; previous recording restored: $failure"
}
