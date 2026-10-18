param([switch]$Startup,[switch]$NoLaunch,[switch]$ReplaceViewer)
$ErrorActionPreference='Stop'
# Per-user viewer only. No installed recorder files, tasks or settings are changed.
$source=Join-Path $PSScriptRoot 'pc-diagnostics.exe'
if(-not(Test-Path -LiteralPath $source -PathType Leaf)){throw 'Extract the complete desktop artifact and run its Install-Tray.ps1.'}
$iconSource=Join-Path $PSScriptRoot 'TraceKeep.ico'
if(-not(Test-Path -LiteralPath $iconSource -PathType Leaf)){throw 'TraceKeep.ico is missing from the desktop package.'}
$destination=Join-Path $env:LOCALAPPDATA 'PCDiagnostics\viewer'
[void][IO.Directory]::CreateDirectory($destination)
# MSIX can redirect both AppData files and HKCU writes into a private package
# view. Verify a real file handle before creating any OS startup registration.
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class TraceKeepInstallerNative {
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
 public static extern uint GetFinalPathNameByHandle(SafeFileHandle handle,StringBuilder path,uint size,uint flags);
 [DllImport("shell32.dll")] public static extern void SHChangeNotify(uint eventId,uint flags,IntPtr first,IntPtr second);
}
'@
$probePath=Join-Path $destination ('.install-probe-'+[guid]::NewGuid().ToString('N'))
$probe=$null
try {
 $probe=[IO.File]::Open($probePath,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Read)
 $physical=[Text.StringBuilder]::new(32768)
 $count=[TraceKeepInstallerNative]::GetFinalPathNameByHandle($probe.SafeFileHandle,$physical,32768,0)
 if($count -eq 0 -or $count -ge 32768){throw 'Cannot verify the physical installation directory.'}
 $resolved=$physical.ToString()
 if($resolved.StartsWith('\\?\')){$resolved=$resolved.Substring(4)}
 if(-not [string]::Equals($resolved,[IO.Path]::GetFullPath($probePath),[StringComparison]::OrdinalIgnoreCase)){
  throw ('Windows redirected this installer into an app-private location: '+$resolved+'. Run this same installer once from an ordinary Windows PowerShell opened from the Start menu. No startup registration or viewer replacement was performed.')
 }
} finally {if($probe){$probe.Dispose()};if(Test-Path -LiteralPath $probePath){Remove-Item -LiteralPath $probePath}}
$target=Join-Path $destination 'TraceKeep.exe'
$running=@(Get-Process -Name 'pc-diagnostics','TraceKeep' -ErrorAction SilentlyContinue|Where-Object {
 $p=$_.Path
 $p -in @($target,(Join-Path $destination 'pc-diagnostics.exe')) -or
 ($p -and $p.StartsWith((Join-Path $env:USERPROFILE 'AppData\Local\Packages\'),[StringComparison]::OrdinalIgnoreCase) -and $p -match '\\LocalCache\\Local\\PCDiagnostics\\viewer\\(TraceKeep|pc-diagnostics)\.exe$' -and $_.MainModule.FileVersionInfo.ProductName -eq 'TraceKeep')
})
if($running.Count -and -not $ReplaceViewer){throw 'The installed viewer is running. Use -ReplaceViewer to replace only the GUI while recording continues.'}
foreach($viewer in $running){Stop-Process -Id $viewer.Id -ErrorAction Stop;$viewer.WaitForExit(10000)|Out-Null}
if(Test-Path -LiteralPath $target){Copy-Item -LiteralPath $target -Destination ($target+'.previous') -Force}
Copy-Item -LiteralPath $source -Destination $target -Force
if((Get-FileHash -LiteralPath $source).Hash -ne (Get-FileHash -LiteralPath $target).Hash){throw 'Viewer copy verification failed.'}
# Keep older installed pcdiag commands working as well.
Copy-Item -LiteralPath $source -Destination (Join-Path $destination 'pc-diagnostics.exe') -Force
$iconTarget=Join-Path $destination 'TraceKeep.ico'
Copy-Item -LiteralPath $iconSource -Destination $iconTarget -Force
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
$shortcut.IconLocation=$iconTarget+',0'
$shortcut.Description='TraceKeep - PC diagnostics tray monitor'
$shortcut.Save()
[TraceKeepInstallerNative]::SHChangeNotify(0x08000000,0,[IntPtr]::Zero,[IntPtr]::Zero)
$recognized=if($Startup){@((Get-CimInstance Win32_StartupCommand -ErrorAction Stop)|Where-Object {$_.Name -eq 'TraceKeep' -and $_.Command -eq ('"'+$target+'" --tray')}).Count -eq 1}else{$null}
if(-not $NoLaunch){Start-Process -FilePath $target -ArgumentList '--tray' -WorkingDirectory $destination -WindowStyle Hidden}
[pscustomobject]@{status=if($Startup -and -not $recognized){'Viewer installed; Windows startup recognition needs investigation'}else{'TraceKeep installed'};executable=$target;icon=$iconTarget;startMenuShortcut=$shortcutPath;startupRequested=[bool]$Startup;windowsStartupRecognized=$recognized;launchMode='tray';recorderChanged=$false;signInTested=$false}|ConvertTo-Json
