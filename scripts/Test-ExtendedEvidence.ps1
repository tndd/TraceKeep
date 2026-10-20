$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot
. (Join-Path $repo 'collectors\Evidence-Core.ps1')
. (Join-Path $repo 'collectors\Collection-Settings.ps1')
. (Join-Path $repo 'collectors\Extended-Evidence.ps1')
. (Join-Path $repo 'management\CrashDump-Policy.ps1')
function Assert($condition,$message){if(-not $condition){throw $message}}
$root=Join-Path $env:TEMP ('pcdiag-extended-test-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($root)
$config=Get-CollectionSettings $root
Assert (@($config.modules.Keys|Where-Object {-not $config.modules[$_].enabled}).Count -eq 0) 'Default modules must be enabled'
$config.modules.processes.enabled=$false;Save-EvidenceJson (Join-Path $root 'collection-settings.json') $config
Assert (-not (Get-CollectionSettings $root).modules.processes.enabled) 'Opt-out lost on reload'
$config.modules.cpu.intervalSeconds=0;Save-EvidenceJson (Join-Path $root 'collection-settings.json') $config
$failed=$false;try {Get-CollectionSettings $root|Out-Null}catch{$failed=$true};Assert $failed 'Invalid interval accepted'
$config=Get-CollectionDefaults;$config.modules['typo']=@{enabled=$true};Save-EvidenceJson (Join-Path $root 'collection-settings.json') $config
$failed=$false;try {Get-CollectionSettings $root|Out-Null}catch{$failed=$true};Assert $failed 'Unknown module silently ignored'
# No hardware/WMI calls: fake query checks inventory shape and partial errors.
function Get-CimInstance {param($ClassName,$Namespace,$ErrorAction,$OperationTimeoutSec,$Filter);if($ClassName -eq 'Win32_BIOS'){throw 'synthetic provider missing'};[pscustomobject]@{Name='synthetic';ProcessId=123;DriverVersion='test'}}
$r=Get-ExtendedEvidence processes;Assert ($r.status -eq 'ok' -and @($r.data.processes).Count -eq 1 -and $r.data.processes[0].ProcessId -eq 123) 'Single-query module lost array shape'
$r=Get-ExtendedEvidence inventory;Assert ($r.status -eq 'partial' -and $r.issues.Count -eq 1 -and $r.data.drivers.Count -eq 1) 'One failed provider must not lose other results'
# Synthetic archive: byte integrity, stable receipt, partial resume, limits and locked source.
$source=Join-Path $root 'sample.dmp';$bytes=New-Object byte[] 8192;for($i=0;$i -lt $bytes.Length;$i++){$bytes[$i]=$i%251};[Text.Encoding]::ASCII.GetBytes('MDMP').CopyTo($bytes,0);[BitConverter]::GetBytes([uint32]1).CopyTo($bytes,8);[BitConverter]::GetBytes([uint32]32).CopyTo($bytes,12);[BitConverter]::GetBytes([uint32]4).CopyTo($bytes,36);[BitConverter]::GetBytes([uint32]44).CopyTo($bytes,40);[IO.File]::WriteAllBytes($source,$bytes);[IO.File]::SetLastWriteTimeUtc($source,[DateTime]::UtcNow.AddMinutes(-2))
$archive=Join-Path $root 'archive';$limits=@{maxArchiveFileBytes=1MB;maxArchiveBytes=10MB;reserveFreeBytes=1;maxFilesPerPass=64}
$rows=@(Copy-DiagnosticArchive @((Get-Item $source)) $archive $limits)
Assert ($rows.Count -eq 1 -and $rows[0].status -eq 'archived' -and (Get-FileHash $rows[0].destination).Hash -eq (Get-FileHash $source).Hash) 'Archive did not preserve exact bytes'
Assert (@(Copy-DiagnosticArchive @((Get-Item $source)) $archive $limits).Count -eq 0) 'Archive duplicated an unchanged source'
$dest=$rows[0].destination;Remove-Item -LiteralPath ([IO.Path]::ChangeExtension($dest,'.json'));Remove-Item -LiteralPath $dest
[IO.File]::WriteAllBytes(($dest+'.partial'),$bytes[0..1023])
$rows=@(Copy-DiagnosticArchive @((Get-Item $source)) $archive $limits)
Assert ($rows[0].status -eq 'archived' -and (Get-FileHash $dest).Hash -eq (Get-FileHash $source).Hash) 'Partial copy resume corrupted content'
$limits.maxArchiveFileBytes=100
$rows=@(Copy-DiagnosticArchive @((Get-Item $source)) (Join-Path $root 'too-small') $limits)
Assert ($rows[0].status -eq 'skipped' -and $rows[0].reason -eq 'file-size-limit') 'Archive limit silently discarded a source'
$limits.maxArchiveFileBytes=1MB
$lock=[IO.File]::Open($source,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite)
try {$rows=@(Copy-DiagnosticArchive @((Get-Item $source)) (Join-Path $root 'locked') $limits);Assert ($rows[0].status -eq 'unavailable') 'Actively written source was archived'}finally{$lock.Dispose()}
# In-memory registry stubs: production registry is never modified.
$script:registry=@{CrashDumpEnabled=3;LogEvent=0}
function Get-ItemProperty {param($LiteralPath,$ErrorAction);[pscustomobject]$script:registry}
function New-ItemProperty {param($LiteralPath,$Name,$Value,$PropertyType,[switch]$Force,$ErrorAction);$script:registry[$Name]=$Value}
function Remove-ItemProperty {param($LiteralPath,$Name,$ErrorAction);$script:registry.Remove($Name)}
$policy=Enable-DiagnosticDumps $root 'synthetic'
Assert ($policy.restartRequired -and $script:registry.CrashDumpEnabled -eq 7 -and $script:registry.AlwaysKeepMemoryDump -eq 1) 'Dump policy was not applied'
$script:registry.CrashDumpEnabled=1
Restore-DiagnosticDumps $root 'synthetic'|Out-Null
Assert ($script:registry.CrashDumpEnabled -eq 1 -and $script:registry.LogEvent -eq 0 -and -not $script:registry.ContainsKey('AlwaysKeepMemoryDump')) 'Restore overwrote external setting or failed to restore originals'
# Run a fully opted-out worker against isolated logs; any provider work would be a bug.
$sandbox=Join-Path $root 'isolated';[void][IO.Directory]::CreateDirectory((Join-Path $sandbox 'logs'))
$config=Get-CollectionDefaults;foreach($name in $config.modules.Keys){$config.modules[$name].enabled=$false};Save-EvidenceJson (Join-Path $sandbox 'collection-settings.json') $config
$scripts=Join-Path $root 'collectors';Copy-Item (Join-Path $repo 'collectors') $scripts -Recurse
$start=Join-Path $scripts 'Start-ExtendedLogging.ps1';$text=[IO.File]::ReadAllText($start).Replace('Global\PCDiagnostics-Extended-v1',('Local\PCDiagnostics-Test-'+[guid]::NewGuid().ToString('N')));[IO.File]::WriteAllText($start,$text)
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $start -LogRoot (Join-Path $sandbox 'logs') -MaxSamples 1
Assert ($LASTEXITCODE -eq 0) 'Disabled worker failed'
$coverage=Get-Content -Encoding UTF8 (Join-Path $sandbox 'coverage.json') -Raw|ConvertFrom-Json
Assert (@($coverage.modules.PSObject.Properties|Where-Object {$_.Value.status -ne 'disabled'}).Count -eq 0 -and @(Get-ChildItem (Join-Path $sandbox 'logs') -Filter 'detail-*').Count -eq 0) 'Opted-out modules still collected data'
Write-Output 'PASS: settings validation, opt-out, partial providers, archive fidelity/resume/limits/locking, reversible dump policy and disabled worker. No production tasks, registry or hardware touched.'
