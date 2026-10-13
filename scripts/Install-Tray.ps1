param([switch]$Startup,[switch]$NoLaunch)
$ErrorActionPreference='Stop'
# Per-user viewer only. No installed recorder files, tasks or settings are changed.
$source=Join-Path $PSScriptRoot 'pc-diagnostics.exe'
if(-not(Test-Path -LiteralPath $source -PathType Leaf)){throw 'Extract the complete desktop artifact and run its Install-Tray.ps1.'}
$destination=Join-Path $env:LOCALAPPDATA 'PCDiagnostics\viewer'
[void][IO.Directory]::CreateDirectory($destination)
$target=Join-Path $destination 'pc-diagnostics.exe'
if(@(Get-Process -Name 'pc-diagnostics' -ErrorAction SilentlyContinue|Where-Object {$_.Path -eq $target}).Count){throw 'The installed tray is running. Close it explicitly before replacing it; this installer will not interrupt recording.'}
Copy-Item -LiteralPath $source -Destination $target -Force
if((Get-FileHash -LiteralPath $source).Hash -ne (Get-FileHash -LiteralPath $target).Hash){throw 'Viewer copy verification failed.'}
if($Startup){
    $key='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    if(-not(Test-Path $key)){[void](New-Item -Path $key -Force)}
    [void](New-ItemProperty -LiteralPath $key -Name 'PCDiagnosticsTray' -PropertyType String -Value ('"'+$target+'" --tray') -Force)
}
if(-not $NoLaunch){Start-Process -FilePath $target -ArgumentList '--mini' -WindowStyle Hidden}
[pscustomobject]@{status='Viewer installed';executable=$target;startupRequested=[bool]$Startup;recorderChanged=$false}|ConvertTo-Json
