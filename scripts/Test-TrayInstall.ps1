param([string]$Executable=(Join-Path (Split-Path $PSScriptRoot) 'src-tauri\target\release\pc-diagnostics.exe'))
$ErrorActionPreference='Stop'
if($env:CI -ne 'true' -or (Test-Path (Join-Path $env:ProgramData 'PCDiagnostics\sources.json'))){throw 'Run only on an isolated CI host.'}
$key='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$shortcutPath=Join-Path ([Environment]::GetFolderPath('Programs')) 'TraceKeep.lnk'
if((Get-ItemProperty -LiteralPath $key -Name TraceKeep -ErrorAction SilentlyContinue) -or (Test-Path -LiteralPath $shortcutPath)){throw 'An existing TraceKeep install must not be changed by this test.'}
$testRoot=Join-Path $env:TEMP ('tracekeep-install-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
Copy-Item -LiteralPath $Executable -Destination (Join-Path $testRoot 'pc-diagnostics.exe')
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Install-Tray.ps1') -Destination $testRoot
Copy-Item -LiteralPath (Join-Path (Split-Path $PSScriptRoot) 'src-tauri\icons\icon.ico') -Destination (Join-Path $testRoot 'TraceKeep.ico')
try {
 # Use Windows' real known folder on this disposable host. Overriding only
 # LOCALAPPDATA leaves Shell Link known-folder resolution using another path.
 $result=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $testRoot 'Install-Tray.ps1') -Startup -NoLaunch
 if($LASTEXITCODE -ne 0){throw 'Installer failed'}
 $result=$result|ConvertFrom-Json
 if(-not $result.windowsStartupRecognized){throw 'Windows did not recognize the startup registration'}
 $link=(New-Object -ComObject WScript.Shell).CreateShortcut($shortcutPath)
 if($link.TargetPath -ne $result.executable -or $link.Arguments -ne '--tray' -or $link.IconLocation -ne ($result.icon+',0')){throw ('Start-menu shortcut mismatch: '+(@{actualTarget=$link.TargetPath;expectedTarget=$result.executable;arguments=$link.Arguments;actualIcon=$link.IconLocation;expectedIcon=($result.icon+',0')}|ConvertTo-Json -Compress))}
 if((Get-FileHash -LiteralPath $Executable).Hash -ne (Get-FileHash -LiteralPath $result.executable).Hash){throw 'Installed executable mismatch'}
 if((Get-FileHash -LiteralPath $Executable).Hash -ne (Get-FileHash -LiteralPath (Join-Path (Split-Path $result.executable) 'pc-diagnostics.exe')).Hash){throw 'Legacy CLI viewer alias mismatch'}
 if($result.recorderChanged -or (Test-Path (Join-Path $env:ProgramData 'PCDiagnostics\sources.json'))){throw 'Viewer installation changed the recorder'}
 Write-Output 'PASS: physical install, Windows startup inventory, branded shortcut/icon, CLI alias, no recorder installation'
} finally {
 Remove-ItemProperty -LiteralPath $key -Name TraceKeep -ErrorAction SilentlyContinue
 if(Test-Path -LiteralPath $shortcutPath){Remove-Item -LiteralPath $shortcutPath}
 # Retain the uniquely named synthetic files in TEMP for CI diagnosis.
}
