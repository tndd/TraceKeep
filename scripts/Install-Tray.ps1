param([switch]$Startup,[switch]$NoLaunch)
$ErrorActionPreference='Stop'
# Per-user viewer only. No installed recorder files, tasks or settings are changed.
$source=Join-Path $PSScriptRoot 'pc-diagnostics.exe'
if(-not(Test-Path -LiteralPath $source -PathType Leaf)){throw 'Extract the complete desktop artifact and run its Install-Tray.ps1.'}
$destination=Join-Path $env:LOCALAPPDATA 'PCDiagnostics\viewer'
[void][IO.Directory]::CreateDirectory($destination)
$target=Join-Path $destination 'TraceKeep.exe'
if(@(Get-Process -Name 'pc-diagnostics','TraceKeep' -ErrorAction SilentlyContinue|Where-Object {$_.Path -in @($target,(Join-Path $destination 'pc-diagnostics.exe'))}).Count){throw 'The installed tray is running. This installer will not close it or interrupt recording.'}
if(Test-Path -LiteralPath $target){Copy-Item -LiteralPath $target -Destination ($target+'.previous') -Force}
Copy-Item -LiteralPath $source -Destination $target -Force
if((Get-FileHash -LiteralPath $source).Hash -ne (Get-FileHash -LiteralPath $target).Hash){throw 'Viewer copy verification failed.'}
if($Startup){
    $key='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    if(-not(Test-Path $key)){[void](New-Item -Path $key -Force)}
    [void](New-ItemProperty -LiteralPath $key -Name 'TraceKeep' -PropertyType String -Value ('"'+$target+'" --tray') -Force)
    Remove-ItemProperty -LiteralPath $key -Name 'PCDiagnosticsTray' -ErrorAction SilentlyContinue
}
$shortcutPath=Join-Path ([Environment]::GetFolderPath('Programs')) 'TraceKeep.lnk'
$shortcut=(New-Object -ComObject WScript.Shell).CreateShortcut($shortcutPath)
$shortcut.TargetPath=$target
$shortcut.Arguments='--tray'
$shortcut.WorkingDirectory=$destination
$shortcut.IconLocation=$target+',0'
$shortcut.Description='TraceKeep - PC diagnostics tray monitor'
$shortcut.Save()
if(-not $NoLaunch){Start-Process -FilePath $target -ArgumentList '--tray' -WorkingDirectory $destination -WindowStyle Hidden}
[pscustomobject]@{status='TraceKeep installed';executable=$target;startMenuShortcut=$shortcutPath;startupRequested=[bool]$Startup;launchMode='tray';recorderChanged=$false}|ConvertTo-Json
