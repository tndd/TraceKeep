param([string]$Worker,[string]$Cli)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot
if(-not $Worker){$Worker=Join-Path $repo 'recorder\target\release\tracekeep-worker.exe'}
if(-not $Cli){$Cli=Join-Path $repo 'src-tauri\target\release\pcdiag.exe'}
. (Join-Path $repo 'collectors\Evidence-Core.ps1')
. (Join-Path $repo 'collectors\Collection-Settings.ps1')
. (Join-Path $repo 'collectors\Extended-Evidence.ps1')
function Assert($value,$message){if(-not $value){throw $message}}
$root=Join-Path $env:TEMP ('tracekeep-native-'+[guid]::NewGuid().ToString('N'))
$logs=Join-Path $root 'logs'
[void][IO.Directory]::CreateDirectory($logs)
$utf8=[Text.UTF8Encoding]::new($false)
$settings=Join-Path $root 'active-collection-settings.json'
Save-EvidenceJson $settings (Get-CollectionDefaults)
Save-EvidenceJson (Join-Path $root 'collection-settings.json') @{schemaVersion=1;modules=@{processes=@{enabled=$false;intervalSeconds=60}}}
Save-EvidenceJson (Join-Path $root 'recorder-run.json') @{runId='synthetic-applied';collection=@{modules=@{processes=@{enabled=$true;intervalSeconds=30}}}}
function Start-Native($Module,[int]$Samples=0){
    $p=Start-Process $Worker -ArgumentList ('--log-root "'+$logs+'" --settings "'+$settings+'" --module '+$Module+' --run-id synthetic-test --samples '+$Samples) -WindowStyle Hidden -PassThru
    $null=$p.Handle;return $p
}
function Read-State($Module){
    try {return Get-Content -LiteralPath (Join-Path $root ('module-state\'+$Module+'.json')) -Raw -Encoding UTF8|ConvertFrom-Json}catch{return $null}
}
function Wait-Complete($Module,$Process){
    $deadline=(Get-Date).AddSeconds(40)
    do {
        $state=Read-State $Module
        if($state.pid -eq $Process.Id -and $state.completedAt){return $state}
        if($Process.HasExited){throw ('Worker exited early: '+$Process.ExitCode)}
        Start-Sleep -Milliseconds 100
    }while((Get-Date) -lt $deadline)
    throw ('Worker did not complete: '+$Module)
}
function Stop-TestProcess($Process){if($Process -and -not $Process.HasExited){$Process.Kill();$null=$Process.WaitForExit(5000)}}

$journal=$null;$processes=$null;$restart=$null
$start=[DateTimeOffset]::Now.AddSeconds(-1)
try {
    $journal=Start-Native configurationJournal
    $processes=Start-Native processes
    $state=Wait-Complete configurationJournal $journal
    Assert ($state.backend -eq 'rust' -and $state.status -eq 'ok') 'Native journal not healthy'
    $state=Wait-Complete processes $processes
    Assert ($state.status -eq 'ok') 'Native process provider failed'
    $journalFile=Join-Path $logs ('detail-configurationJournal-'+(Get-Date -Format yyyyMMdd)+'.jsonl')
    $row=Get-Content $journalFile -Encoding UTF8 -Tail 1|ConvertFrom-Json
    $expected=Get-ConfigurationJournalEvidence $root
    foreach($name in $expected.data.files.Keys){
        $actual=$row.result.data.files.$name
        Assert ($actual.status -eq $expected.data.files[$name].status) ('Journal status differs: '+$name)
        Assert ($actual.sha256 -ceq $expected.data.files[$name].sha256) ('Journal byte hash differs: '+$name)
        Assert ($actual.json -ceq $expected.data.files[$name].json) ('Journal raw text differs: '+$name)
    }
    foreach($name in $expected.data.crashControl.values.Keys){
        Assert (($row.result.data.crashControl.values.$name|ConvertTo-Json -Compress) -ceq ($expected.data.crashControl.values[$name]|ConvertTo-Json -Compress)) ('Registry result differs: '+$name)
    }
    $processFile=Join-Path $logs ('detail-processes-'+(Get-Date -Format yyyyMMdd)+'.jsonl')
    $processRow=Get-Content $processFile -Tail 1 -Encoding UTF8|ConvertFrom-Json
    $actual=@($processRow.result.data.processes|Where-Object ProcessId -EQ $PID)[0]
    $expectedProcess=Get-CimInstance Win32_Process -Filter "ProcessId=$PID"|Select-Object Name,ProcessId,ParentProcessId,CreationDate,KernelModeTime,UserModeTime,WorkingSetSize,PrivatePageCount,PageFaults,HandleCount,ThreadCount,ReadTransferCount,WriteTransferCount
    $expectedJson=$expectedProcess|ConvertTo-Json|ConvertFrom-Json
    foreach($name in @('Name','ProcessId','ParentProcessId','CreationDate')){Assert ($actual.$name -ceq $expectedJson.$name) ('Process identity differs: '+$name)}
    foreach($name in @('KernelModeTime','UserModeTime','WorkingSetSize','PrivatePageCount','PageFaults','HandleCount','ThreadCount','ReadTransferCount','WriteTransferCount')){
        Assert ($null -ne $actual.$name -and $actual.$name -isnot [string]) ('Process counter missing or string: '+$name)
    }
    # A second backend cannot claim the same module/root while this one lives.
    $duplicate=Start-Native configurationJournal 1
    try {Assert ($duplicate.WaitForExit(10000) -and $duplicate.ExitCode -ne 0) 'Duplicate Rust worker accepted'}finally{Stop-TestProcess $duplicate}
    $fallback=Join-Path $root 'fallback'
    Copy-Item (Join-Path $repo 'collectors') $fallback -Recurse
    $fallbackScript=Join-Path $fallback 'Start-ExtendedLogging.ps1'
    [IO.File]::WriteAllText($fallbackScript,([IO.File]::ReadAllText($fallbackScript).Replace('Global\PCDiagnostics-Extended-v1',('Local\TraceKeep-Fallback-Test-'+[guid]::NewGuid().ToString('N')))),$utf8)
    $psDuplicate=Start-Process powershell.exe -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "'+$fallbackScript+'" -LogRoot "'+$logs+'" -Module configurationJournal -SettingsPath "'+$settings+'" -MaxSamples 1') -WindowStyle Hidden -PassThru
    $null=$psDuplicate.Handle
    try {Assert ($psDuplicate.WaitForExit(10000) -and $psDuplicate.ExitCode -ne 0) 'PowerShell fallback bypassed owner lock'}finally{Stop-TestProcess $psDuplicate}
    # Forced termination releases the owner lock without touching other modules.
    $oldSession=(Read-State processes).session
    Stop-TestProcess $processes
    Assert (-not $journal.HasExited) 'Independent journal terminated with process collector'
    $restart=Start-Native processes
    $state=Wait-Complete processes $restart
    Assert ($state.session -ne $oldSession -and $state.sequence -eq 0) 'Restart did not start a new session'
    $row=Get-Content $processFile -Tail 1 -Encoding UTF8|ConvertFrom-Json
    Assert (-not $row.unchanged -and $row.result) 'Restart baseline not self-contained'
    # Observe saved configuration changes without changing applied configuration.
    Save-EvidenceJson (Join-Path $root 'collection-settings.json') @{schemaVersion=1;modules=@{processes=@{enabled=$true;intervalSeconds=60}}}
    $deadline=(Get-Date).AddSeconds(25);$changed=$false
    do {
        Start-Sleep -Milliseconds 250
        $full=@(Get-Content $journalFile -Tail 5 -Encoding UTF8|ConvertFrom-Json|Where-Object result)
        if($full.Count){$row=$full[-1];$changed=($row.result.data.files.'collection-settings.json'.json|ConvertFrom-Json).modules.processes.enabled -eq $true}
    }while(-not $changed -and (Get-Date) -lt $deadline)
    Assert $changed 'Journal failed to observe saved configuration change'
    Assert (($row.result.data.files.'recorder-run.json'.json|ConvertFrom-Json).runId -eq 'synthetic-applied') 'Applied configuration identity changed'
    [IO.File]::WriteAllText((Join-Path $logs 'STOP-EXTENDED'),'test stop',$utf8)
    Assert ($journal.WaitForExit(5000) -and $restart.WaitForExit(5000)) 'Graceful stop timed out'
    Assert ($journal.ExitCode -eq 0 -and $restart.ExitCode -eq 0) 'Graceful stop failed'
}finally{Stop-TestProcess $journal;Stop-TestProcess $processes;Stop-TestProcess $restart}

# Existing CLI must return exactly the same history before/after compression.
$oldProgramData=$env:ProgramData
try {
    $env:ProgramData=Join-Path $root 'query'
    [void][IO.Directory]::CreateDirectory((Join-Path $env:ProgramData 'PCDiagnostics'))
    Save-EvidenceJson (Join-Path $env:ProgramData 'PCDiagnostics\sources.json') @{sensorRoot=$logs;activityRoot=$logs}
    $end=[DateTimeOffset]::Now.AddSeconds(1).ToString('o')
    $before=& $Cli history $start.ToString('o') $end|ConvertFrom-Json
    Assert ($LASTEXITCODE -eq 0) 'Raw history failed'
    foreach($file in Get-ChildItem $logs -Filter '*.jsonl'){$null=Compress-DiagnosticLog $file.FullName}
    $after=& $Cli history $start.ToString('o') $end|ConvertFrom-Json
    Assert ($LASTEXITCODE -eq 0) 'Compressed history failed'
    foreach($name in @('configurationJournal','processes')){
        Assert ($before.streams.$name.rows.Count -gt 0) ('History missing '+$name)
        Assert (($before.streams.$name|ConvertTo-Json -Depth 30 -Compress) -ceq ($after.streams.$name|ConvertTo-Json -Depth 30 -Compress)) ('Raw/gzip history mismatch '+$name)
        Assert ($after.streams.$name.unresolvedReferences -eq 0 -and $after.streams.$name.invalidLines -eq 0) ('Unresolved or invalid native history '+$name)
    }
}finally{$env:ProgramData=$oldProgramData}
Write-Output 'PASS: Rust/PowerShell journal and process identity parity, owner exclusion, independent termination/restart, configuration observation, stop and raw/gzip history'
