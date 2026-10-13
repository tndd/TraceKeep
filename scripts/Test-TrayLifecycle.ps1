param([string]$Executable=(Join-Path (Split-Path $PSScriptRoot) 'src-tauri\target\release\pc-diagnostics.exe'))
$ErrorActionPreference='Stop'
# Do not run UI lifecycle tests in an actual recording environment.
if(Test-Path (Join-Path $env:ProgramData 'PCDiagnostics\sources.json')){throw 'Use an isolated CI host, not the live diagnostics computer.'}
Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class TrayWindows {
  delegate bool EnumProc(IntPtr h,IntPtr p);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc fn,IntPtr p);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h,out uint p);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h,StringBuilder b,int n);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h,uint m,IntPtr w,IntPtr l);
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h,int index);
  public static IntPtr[] Visible(int pid) {var list=new List<IntPtr>();EnumWindows((h,p)=>{uint owner;GetWindowThreadProcessId(h,out owner);var name=new StringBuilder(256);GetWindowText(h,name,256);if(owner==pid&&IsWindowVisible(h)&&name.ToString().StartsWith("TraceKeep"))list.Add(h);return true;},IntPtr.Zero);return list.ToArray();}
}
'@
$fixture=Join-Path $env:TEMP ('pcdiag-tray-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
$previousData=$env:ProgramData
$viewer=$null
try {
    $env:ProgramData=$fixture
    $viewer=Start-Process -FilePath $Executable -ArgumentList '--mini' -WindowStyle Hidden -PassThru
    $deadline=(Get-Date).AddSeconds(45)
    do {Start-Sleep -Milliseconds 500;$windows=@([TrayWindows]::Visible($viewer.Id));if($viewer.HasExited){throw 'Viewer exited before displaying its first window'}}while($windows.Count -eq 0 -and (Get-Date) -lt $deadline)
    if($windows.Count -eq 0){throw 'Mini monitor did not open'}
    foreach($window in $windows){if(([TrayWindows]::GetWindowLong($window,-16) -band 0x00C00000) -ne 0){throw 'Mini monitor still has a native title bar'}}
    foreach($window in $windows){[void][TrayWindows]::PostMessage($window,0x10,[IntPtr]::Zero,[IntPtr]::Zero)}
    Start-Sleep -Seconds 3
    if($viewer.HasExited){throw 'Window X incorrectly terminated the tray'}
    if(@([TrayWindows]::Visible($viewer.Id)).Count){throw 'Window X did not close its window'}
    $second=Start-Process -FilePath $Executable -ArgumentList '--mini' -WindowStyle Hidden -PassThru
    if(-not $second.WaitForExit(10000)){throw 'A second tray instance was created'}
    $deadline=(Get-Date).AddSeconds(15)
    do {Start-Sleep -Milliseconds 500;$windows=@([TrayWindows]::Visible($viewer.Id))}while($windows.Count -eq 0 -and (Get-Date) -lt $deadline)
    if($windows.Count -eq 0){throw 'Repeated launch did not reopen the existing mini monitor'}
    if(Test-Path (Join-Path $fixture 'PCDiagnostics\STOP-ALL')){throw 'A window action changed recorder state'}
    Write-Output 'PASS: window X retains tray, repeated launch reopens a single instance, no recorder mutation'
} finally {
    $env:ProgramData=$previousData
    if($viewer -and -not $viewer.HasExited){Stop-Process -Id $viewer.Id -Force}
    # Fixture contains only this test's synthetic data; retain it on CI for diagnosis.
}
