$ErrorActionPreference='Stop'
function Get-UpdateDumpPolicySummary($Policy) {
    # Registry provider metadata contains a large live object graph, not settings.
    if($Policy.current){
        $values=[ordered]@{}
        foreach($property in $Policy.current.PSObject.Properties){
            if($property.Name -notin @('PSPath','PSParentPath','PSChildName','PSDrive','PSProvider')){
                $values[$property.Name]=$property.Value
            }
        }
        $Policy.current=$values
    }
    return $Policy
}
function Read-UpdateSnapshot([string]$Path) {
    # Readers must permit atomic replacement and tolerate short sharing windows.
    # A permanently locked, missing or invalid snapshot still fails verification.
    for($attempt=0;$attempt -lt 20;$attempt++){
        try {
            $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            try {
                $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8,$true)
                try {$text=$reader.ReadToEnd()}finally{$reader.Dispose()}
            }finally{$stream.Dispose()}
            return ($text|ConvertFrom-Json -ErrorAction Stop)
        }catch [IO.IOException]{
            if($attempt -eq 19){throw}
            Start-Sleep -Milliseconds 100
        }
    }
}
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
$expected=@('collectors\Log-Storage.ps1','collectors\Start-LogMaintenance.ps1','collectors\Collection-Settings.ps1','collectors\Extended-Evidence.ps1','collectors\Start-ExtendedLogging.ps1','management\Configure-Recorder.ps1','management\CrashDump-Policy.ps1','pcdiag.exe','tracekeep-worker.exe','collectors\Evidence-Core.ps1','collectors\Read-NvmeHealth.ps1','collectors\Start-EvidenceLogging.ps1','collectors\Start-AutomaticCpuLogging.ps1','collectors\Start-MotherboardLogging.ps1','collectors\Start-ContinuousDiagnostics.ps1','collectors\Read-NvidiaDiagnostics.ps1','management\Run-Recorder.ps1','management\Manage-Recorder.ps1')
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
. (Join-Path $package 'collectors\Read-NvmeHealth.ps1')
# Compile the read-only reader before interrupting existing recording.
Initialize-NvmeReader
. (Join-Path $package 'collectors\Collection-Settings.ps1')
. (Join-Path $package 'management\CrashDump-Policy.ps1')
$collection=Get-CollectionSettings $dataRoot
$settingsPath=Join-Path $dataRoot 'collection-settings.json';$settingsCreated=$false;$dumpPolicyChanged=$false
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
    Protect-DiagnosticArchive (Join-Path $dataRoot 'archive')
    if(-not(Test-Path $settingsPath)){
        $legacySettings=Join-Path $dataRoot 'recorder-settings.json'
        if(Test-Path $legacySettings){$legacy=Get-Content -Encoding UTF8 $legacySettings -Raw|ConvertFrom-Json;foreach($name in @('cpu','board','activity')){if($legacy.intervalMilliseconds.$name){$collection.modules[$name].intervalSeconds=[Math]::Ceiling($legacy.intervalMilliseconds.$name/1000)}}}
        Save-EvidenceJson $settingsPath $collection;$settingsCreated=$true
    }
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
    $coverage=$null;$storage=$null;$ready=$false;$deadline=(Get-Date).AddSeconds(150)
    do {
        $coveragePath=Join-Path $dataRoot 'coverage.json'
        if(Test-Path $coveragePath){
            $coverage=Read-UpdateSnapshot $coveragePath
            if(Test-CollectionCoverageReady $coverage $collection $since){
                $storageFile=Get-ChildItem -LiteralPath $logRoot -Filter 'storage-*.jsonl'|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 1
                $storage=if($storageFile){Get-Content -Encoding UTF8 -LiteralPath $storageFile.FullName -Tail 1|ConvertFrom-Json}else{$null}
                $needsNvme=$collection.modules.nvme.enabled -or $collection.modules.nvmeErrors.enabled
                if(-not(Test-CollectionModuleEnabled $collection 'storage') -or ($storage -and ([DateTimeOffset]$storage.time) -ge $since -and (-not $needsNvme -or $storage.nvme))){$ready=$true;break}
            }
        }
        Start-Sleep -Seconds 2
    }while((Get-Date) -lt $deadline)
    if(-not $ready){throw 'Isolated collectors did not complete fresh initial evidence; inspect coverage and storage logs'}
    . (Join-Path $package 'management\CrashDump-Policy.ps1')
    $dumpPolicy=@{status='disabled'}
    if($collection.modules.automaticDump.enabled){$dumpPolicy=Get-UpdateDumpPolicySummary (Enable-DiagnosticDumps $dataRoot);$dumpPolicyChanged=$dumpPolicy.status -eq 'configured'}
    $nvmeStatus=@($storage.nvme.disks|ForEach-Object {[pscustomobject]@{number=$_.number;status=$_.status;unsafeShutdowns=$_.health.counters.unsafeShutdowns;mediaErrors=$_.health.counters.mediaErrors;errorLogEntryCount=$_.health.counters.errorLogEntryCount;error=$_.error}})
    Save-EvidenceJson $audit @{phase='active';verifiedAt=[DateTimeOffset]::Now.ToString('o');files=$files;previousFiles=$oldFiles;evidenceErrors=$row.errors}
    [pscustomobject]@{status='Extended evidence upgrade verified';logs=$logRoot;incidents=(Join-Path $dataRoot 'incidents');checkpoints=(Join-Path $dataRoot 'event-checkpoints');backup=$backup;collectionSettings=$settingsPath;coverage=$coverage.modules;evidenceErrors=$row.errors;nvmeHealth=$nvmeStatus;nvmeErrors=$storage.nvme.errors;dumpPolicy=$dumpPolicy;bootRestartTested=$false}|ConvertTo-Json -Depth 8
}catch{
    $failure=$_.Exception.Message
    if($changed){
        try {
            & $shell -NoProfile -ExecutionPolicy Bypass -File $manager -Action stop
            if($LASTEXITCODE -ne 0){throw 'Rollback could not stop updated workers'}
            if($dumpPolicyChanged){Restore-DiagnosticDumps $dataRoot|Out-Null}
            if($settingsCreated -and (Test-Path $settingsPath)){Remove-Item -LiteralPath $settingsPath}
            foreach($entry in $files){$dest=Join-Path $codeRoot $entry.path;if($entry.path -in $oldFiles){Copy-Item -LiteralPath (Join-Path $backup $entry.path) -Destination $dest -Force}elseif(Test-Path -LiteralPath $dest){Remove-Item -LiteralPath $dest}}
            & $shell -NoProfile -ExecutionPolicy Bypass -File $manager -Action start
            if($LASTEXITCODE -ne 0){throw 'Previous workers failed verification'}
            Save-EvidenceJson $audit @{phase='rolled-back';failure=$failure;time=[DateTimeOffset]::Now.ToString('o')}
        }catch{throw "Update failed: $failure. Rollback needs attention: $($_.Exception.Message). Backup: $backup"}
    }
    throw "Update failed; previous recording restored: $failure"
}
