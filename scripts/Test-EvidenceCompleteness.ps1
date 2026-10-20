param([ValidateSet('all','history','schedule','dump-policy','dump-quality','bundle')][string]$Case='all',[string]$Cli)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot
. (Join-Path $repo 'collectors\Evidence-Core.ps1')
. (Join-Path $repo 'collectors\Collection-Settings.ps1')
. (Join-Path $repo 'collectors\Extended-Evidence.ps1')
. (Join-Path $repo 'management\CrashDump-Policy.ps1')
function Assert($condition,$message){if(-not $condition){throw $message}}
$root=Join-Path $env:TEMP ('tracekeep-completeness-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
if($Case -in @('all','history')){
    if(-not $Cli){$Cli=Join-Path $repo 'src-tauri\target\release\pcdiag.exe'}
    $machine=Join-Path $root 'PCDiagnostics';[void][IO.Directory]::CreateDirectory($machine)
    Save-EvidenceJson (Join-Path $machine 'sources.json') @{sensorRoot=$root;activityRoot=$root}
    $date=[DateTimeOffset]::Now.Date.AddHours(10);$start=[DateTimeOffset]$date
    foreach($kind in @('gpuDetails','processes')){
        0..13|ForEach-Object {Add-EvidenceRecord $root ('detail-'+$kind) @{time=$start.AddSeconds($_).ToString('o');sequence=$_;result=@{data=@{synthetic=$_}}}}
    }
    $before=@(Get-ChildItem $root -Filter '*.jsonl'|Get-FileHash)
    $originalProgramData=$env:ProgramData
    try {$env:ProgramData=$root;$json=& $Cli history $start.ToString('o') $start.AddMinutes(1).ToString('o');Assert ($LASTEXITCODE -eq 0) 'History query failed';$history=$json|ConvertFrom-Json}
    finally {$env:ProgramData=$originalProgramData}
    foreach($kind in @('gpuDetails','processes')){
        $stream=$history.streams.$kind
        Assert ($stream.rows.Count -eq 14 -and $stream.rows[0].sequence -eq 0) "$kind silently loses intermediate evidence: expected 14, got $($stream.rows.Count)"
        Assert (-not $stream.truncated) 'Small history unexpectedly truncated'
    }
    foreach($file in $before){Assert ((Get-FileHash -LiteralPath $file.Path).Hash -eq $file.Hash) 'History changed original bytes'}
    Write-Output 'PASS history: all intermediate samples, original bytes unchanged'
}
if($Case -in @('all','schedule')){
    $copy=Join-Path $root 'collectors';Copy-Item -LiteralPath (Join-Path $repo 'collectors') -Destination $copy -Recurse
    $logs=Join-Path $root 'logs';[void][IO.Directory]::CreateDirectory($logs)
    $path=Join-Path $copy 'Start-ExtendedLogging.ps1'
    $text=[IO.File]::ReadAllText($path).Replace('Global\PCDiagnostics-Extended-v1',('Local\TraceKeep-Test-'+[guid]::NewGuid().ToString('N')))
    # Override providers/config only in the private copy. Real worker scheduling,
    # disk writes and wall clock remain in use; no production mutex or sensors.
    $stubs=@'
function Get-CollectionSettings {
    $c=Get-CollectionDefaults
    foreach($n in $c.modules.Keys){$c.modules[$n].enabled=$false}
    $c.modules.performance.enabled=$true;$c.modules.performance.intervalSeconds=1
    return $c
}
function Get-ExtendedEvidence {param($Module);Start-Sleep -Milliseconds 200;return @{status='ok';issues=@();data=@{synthetic=$true}}}
'@
    $text=$text.Replace('$dataRoot=Split-Path $LogRoot',($stubs+"`r`n"+'$dataRoot=Split-Path $LogRoot'))
    [IO.File]::WriteAllText($path,$text)
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $path -LogRoot $logs -MaxSamples 2
    Assert ($LASTEXITCODE -eq 0) 'Isolated scheduler failed'
    $rows=@(Get-Content (Join-Path $logs ('detail-performance-'+(Get-Date -Format yyyyMMdd)+'.jsonl'))|ConvertFrom-Json)
    Assert ($rows.Count -eq 2) 'Expected two scheduled samples'
    $gap=([DateTimeOffset]$rows[1].startedAt-[DateTimeOffset]$rows[0].startedAt).TotalSeconds
    Assert ($gap -ge 0.8 -and $gap -lt 2.5) "Configured 1 s interval became $gap s"
    Assert ($rows[1].schedule.actualIntervalMs -gt 800 -and $rows[1].schedule.configuredIntervalSeconds -eq 1) 'Observed cadence metadata missing'
    $advance=Get-ExtendedNextDeadline 0 200 1000
    Assert ($advance.nextMs -eq 1000 -and $advance.missedIntervals -eq 0) 'Provider duration shifted deadline'
    $advance=Get-ExtendedNextDeadline 1000 3600 1000
    Assert ($advance.nextMs -eq 4000 -and $advance.missedIntervals -eq 2) 'Slow provider did not expose skipped slots'
    $advance=Get-ExtendedNextDeadline 0 1000 1000
    Assert ($advance.nextMs -eq 1000 -and $advance.missedIntervals -eq 0) 'Exactly due slot was discarded'
    Write-Output "PASS schedule: start-to-start interval $gap s with 200 ms provider"
}
if($Case -in @('all','dump-policy')){
    $policyRoot=Join-Path $root 'policy';[void][IO.Directory]::CreateDirectory($policyRoot)
    $script:registry=@{CrashDumpEnabled=3;AlwaysKeepMemoryDump=1;LogEvent=1}
    function Get-ItemProperty {param($LiteralPath,$ErrorAction);[pscustomobject]$script:registry}
    function New-ItemProperty {throw 'Registry must not be changed for external drift'}
    $path=Join-Path $policyRoot 'dump-policy-backup.json'
    Save-EvidenceJson $path @{active=$true;entries=@(@{name='CrashDumpEnabled';applied=7;previous=3;existed=$true},@{name='AlwaysKeepMemoryDump';applied=1;previous=$null;existed=$false})}
    $hash=(Get-FileHash $path).Hash
    $status=Enable-DiagnosticDumps $policyRoot 'synthetic'
    Assert ($status.status -eq 'drifted' -and $status.differences[0].current -eq 3) 'External dump setting drift reported as configured'
    Assert ((Get-FileHash $path).Hash -eq $hash -and $script:registry.CrashDumpEnabled -eq 3) 'External setting or original backup overwritten'
    $script:registry.CrashDumpEnabled=7
    Assert ((Enable-DiagnosticDumps $policyRoot 'synthetic').status -eq 'already-configured') 'Matching dump settings reported as drifted'
    $script:registry.Remove('AlwaysKeepMemoryDump')
    Assert ((Enable-DiagnosticDumps $policyRoot 'synthetic').status -eq 'drifted') 'Missing registry value ignored'
    Write-Output 'PASS dump-policy: external change and missing value detected without writes'
}
if($Case -in @('all','dump-quality')){
    $empty=Join-Path $root 'empty.dmp';[IO.File]::WriteAllBytes($empty,[byte[]]@())
    [IO.File]::SetLastWriteTimeUtc($empty,[DateTime]::UtcNow.AddMinutes(-2))
    $limits=@{maxArchiveFileBytes=1MB;maxArchiveBytes=10MB;reserveFreeBytes=1;maxFilesPerPass=64}
    $archive=Join-Path $root 'archive'
    $rows=@(Copy-DiagnosticArchive @((Get-Item $empty)) $archive $limits)
    Assert ($rows.Count -eq 1 -and $rows[0].validation.status -eq 'invalid') 'Empty dump lacks unusable evidence status'
    Assert ((Test-Path $empty) -and (Test-Path $rows[0].destination) -and (Get-Item $rows[0].destination).Length -eq 0) 'Invalid dump original/copy lost'
    $again=@(Copy-DiagnosticArchive @((Get-Item $empty)) $archive $limits)
    Assert ($again.Count -eq 1 -and $again[0].validation.status -eq 'invalid') 'Cached unusable dump disappeared from coverage'
    # Legacy receipts must be checked too, without changing archived bytes.
    $receipt=[IO.Path]::ChangeExtension($rows[0].destination,'.json')
    $legacy=Get-Content $receipt -Raw|ConvertFrom-Json
    $legacy.PSObject.Properties.Remove('validation');Save-EvidenceJson $receipt $legacy
    $again=@(Copy-DiagnosticArchive @((Get-Item $empty)) $archive $limits)
    Assert ($again[0].validation.reason -eq 'empty-file') 'Legacy receipt bypassed validation'
    $sample=Join-Path $root 'structural.dmp';$bytes=New-Object byte[] 48
    [Text.Encoding]::ASCII.GetBytes('MDMP').CopyTo($bytes,0)
    [BitConverter]::GetBytes([uint32]1).CopyTo($bytes,8)
    [BitConverter]::GetBytes([uint32]32).CopyTo($bytes,12)
    [BitConverter]::GetBytes([uint32]4).CopyTo($bytes,36)
    [BitConverter]::GetBytes([uint32]44).CopyTo($bytes,40)
    [IO.File]::WriteAllBytes($sample,$bytes)
    $validation=Get-DiagnosticDumpValidation $sample
    Assert ($validation.status -eq 'structure-checked' -and -not $validation.analysisVerified) 'Basic format check claimed full analysis or rejected a bounded stream'
    [IO.File]::WriteAllBytes($sample,$bytes[0..31])
    Assert ((Get-DiagnosticDumpValidation $sample).status -eq 'invalid') 'Truncated stream directory accepted'
    [BitConverter]::GetBytes([uint32]4294967295).CopyTo($bytes,40)
    [IO.File]::WriteAllBytes($sample,$bytes)
    Assert ((Get-DiagnosticDumpValidation $sample).reason -eq 'incomplete-stream-data') 'Out-of-file stream range accepted'
    [Text.Encoding]::ASCII.GetBytes('PAGEDU64').CopyTo($bytes,0)
    [IO.File]::WriteAllBytes($sample,$bytes)
    Assert ((Get-DiagnosticDumpValidation $sample).status -eq 'unverified') 'Non-minidump format falsely declared valid or corrupt'
    # Check aggregate coverage without enumerating the real Windows folders.
    $script:qualitySource=$empty
    function Get-DiagnosticFiles {param($Roots,$Pattern);return @{files=@((Get-Item $script:qualitySource));issues=@();limited=$false}}
    function Get-ItemProperty {param($LiteralPath,$ErrorAction);return [pscustomobject]@{}}
    $originalWindir=$env:WINDIR
    try {
        $env:WINDIR=$root
        $result=Get-ArchiveEvidence 'dumpArchive' $root $limits
        Assert ($result.status -eq 'partial' -and $result.issues[0].reason -eq 'empty-file') 'Aggregate coverage hides unusable dump'
        $result=Get-ArchiveEvidence 'dumpArchive' $root $limits
        Assert ($result.status -eq 'partial') 'Repeat scan became healthy without usable dump'
    }finally{$env:WINDIR=$originalWindir}
    Write-Output 'PASS dump-quality: empty dump preserved and remains visibly unusable'
}
if($Case -in @('all','bundle')){
    $bundleRoot=Join-Path $root 'bundle';$logs=Join-Path $bundleRoot 'logs';[void][IO.Directory]::CreateDirectory($logs)
    foreach($name in @('collection-settings.json','coverage.json','sensor-driver-isolation.json')){
        Save-EvidenceJson (Join-Path $bundleRoot $name) @{synthetic='before';time=[DateTimeOffset]::Now.ToString('o')}
    }
    function Read-EvidenceEvents {param($channel,$xpath,$limit,[switch]$Newest);return @()}
    $boot=[DateTimeOffset]::Now.AddMinutes(-5)
    $bundle=New-IncidentBundle $logs $bundleRoot $boot @{}
    foreach($name in @('collection-settings.json','coverage.json','sensor-driver-isolation.json')){
        Assert (Test-Path (Join-Path $bundle $name)) "Boot bundle missing $name"
        Assert ((Get-FileHash (Join-Path $bundle $name)).Hash -eq (Get-FileHash (Join-Path $bundleRoot $name)).Hash) "Bundle changed $name bytes"
    }
    Save-EvidenceJson (Join-Path $bundleRoot 'collection-settings.json') @{synthetic='after'}
    $null=New-IncidentBundle $logs $bundleRoot $boot @{}
    Assert ((Get-Content (Join-Path $bundle 'collection-settings.json') -Raw|ConvertFrom-Json).synthetic -eq 'before') 'Worker restart replaced captured boot conditions'
    $conditions=Get-Content (Join-Path $bundle 'conditions.json') -Raw|ConvertFrom-Json
    Assert ($conditions.timeScope -match 'after this boot' -and @($conditions.files|Where-Object status -EQ 'missing').Count -gt 0) 'Snapshot timing or missing files not disclosed'
    # An old bundle stays immutable; a separately labeled supplement records
    # present-day observations instead of pretending they are historical facts.
    $oldBoot=$boot.AddDays(-1);$old=Join-Path $bundleRoot ('incidents\boot-'+$oldBoot.UtcDateTime.ToString('yyyyMMddTHHmmssZ'))
    [void][IO.Directory]::CreateDirectory($old)
    Save-EvidenceJson (Join-Path $old 'manifest.json') @{version=1;errors=@()}
    Save-EvidenceJson (Join-Path $old 'machine-inventory.json') @{synthetic='old-immutable'}
    $oldHash=(Get-FileHash (Join-Path $old 'manifest.json')).Hash
    $null=New-IncidentBundle $logs $bundleRoot $oldBoot @{}
    Assert ((Get-FileHash (Join-Path $old 'manifest.json')).Hash -eq $oldHash) 'Legacy manifest changed'
    Assert ((Get-Content (Join-Path $old 'machine-inventory.json') -Raw|ConvertFrom-Json).synthetic -eq 'old-immutable') 'Legacy inventory changed'
    Assert ((Get-Content (Join-Path $old 'conditions-recovery\collection-settings.json') -Raw|ConvertFrom-Json).synthetic -eq 'after') 'Labeled supplement missing'
    Write-Output 'PASS bundle: conditions copied exactly and immutable across worker restarts'
}
