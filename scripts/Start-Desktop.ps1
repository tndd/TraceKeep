param([string]$ExecutablePath)
$ErrorActionPreference = 'Stop'
if (-not $ExecutablePath) {
    $ExecutablePath = Join-Path (Split-Path $PSScriptRoot) 'src-tauri\target\release\pc-diagnostics.exe'
}
if (-not (Test-Path -LiteralPath $ExecutablePath -PathType Leaf)) {
    throw 'Build the Windows executable or pass -ExecutablePath with the extracted CI artifact path.'
}
# This opens only the viewer. It does not start/stop a sensor collector.
Start-Process -FilePath (Resolve-Path -LiteralPath $ExecutablePath).Path
