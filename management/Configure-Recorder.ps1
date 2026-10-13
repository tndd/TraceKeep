param([ValidateSet('show','enable','disable','interval')][string]$Operation='show',[string]$Module,[int]$Seconds)
$ErrorActionPreference='Stop'
$codeRoot=Split-Path $PSScriptRoot;$dataRoot=Join-Path $env:ProgramData 'PCDiagnostics'
. (Join-Path $codeRoot 'collectors\Collection-Settings.ps1')
. (Join-Path $codeRoot 'collectors\Evidence-Core.ps1')
$settings=Get-CollectionSettings $dataRoot
$oldDumpEnabled=$settings.modules.automaticDump.enabled
if($Operation -eq 'show'){$settings|ConvertTo-Json -Depth 6;exit 0}
$principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Configuration changes require an Administrator terminal.'}
if(-not $settings.modules.Contains($Module)){throw 'Unknown module. Run pcdiag config show.'}
if($Operation -eq 'interval'){
    $min=if($Module -in @('cpu','board','activity')){1}else{15};$max=if($Module -in @('cpu','board','activity')){5}else{86400}
    if($Seconds -lt $min -or $Seconds -gt $max){throw "Interval must be $min..$max seconds"}
    $settings.modules[$Module].intervalSeconds=$Seconds
}else{$settings.modules[$Module].enabled=($Operation -eq 'enable')}
$task=Get-ScheduledTask -TaskName 'PC Diagnostics Recorder' -ErrorAction Stop
$path=Join-Path $dataRoot 'collection-settings.json';$existed=Test-Path $path;$previous=if($existed){[IO.File]::ReadAllText($path)}else{$null}
Save-EvidenceJson $path $settings
try {
    if($Module -eq 'automaticDump'){
        . (Join-Path $PSScriptRoot 'CrashDump-Policy.ps1')
        if($settings.modules.automaticDump.enabled){Enable-DiagnosticDumps $dataRoot|Out-Null}else{Restore-DiagnosticDumps $dataRoot|Out-Null}
    }
    if($task.State -eq 'Running'){
        & (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Manage-Recorder.ps1') -Action restart
        if($LASTEXITCODE -ne 0){throw 'Recorder restart failed'}
    }
}catch{
    $failure=$_.Exception.Message
    if($existed){[IO.File]::WriteAllText($path,$previous,[Text.UTF8Encoding]::new($false))}else{Remove-Item -LiteralPath $path}
    if($Module -eq 'automaticDump'){if($oldDumpEnabled){Enable-DiagnosticDumps $dataRoot|Out-Null}else{Restore-DiagnosticDumps $dataRoot|Out-Null}}
    if($task.State -eq 'Running'){& (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Manage-Recorder.ps1') -Action restart}
    throw ('Configuration failed; previous configuration restored. Inspect pcdiag doctor before continuing: '+$failure)
}
[pscustomobject]@{module=$Module;configuration=$settings.modules[$Module];recorderRestarted=($task.State -eq 'Running');existingLogsRetained=$true;dumpPolicyRequiresNextBoot=($Module -eq 'automaticDump')}|ConvertTo-Json -Depth 5
