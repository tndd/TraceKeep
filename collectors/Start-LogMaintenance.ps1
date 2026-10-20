param([Parameter(Mandatory=$true)][string]$LogRoot,[int]$MaxPasses=0)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Evidence-Core.ps1')
$dataRoot=Split-Path $LogRoot
$mutex=[Threading.Mutex]::new($false,'Global\PCDiagnostics-LogMaintenance-v1');$locked=$false;$owner=$null
try {
    try {$locked=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true}
    if(-not $locked){exit 0}
    $owner=[IO.FileStream]::new((Join-Path $LogRoot 'maintenance.owner.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $iteration=0
    $previousErrors=@()
    while(-not(Test-Path -LiteralPath (Join-Path $LogRoot 'STOP-MAINTENANCE'))){
        $progress={
            if(Test-Path -LiteralPath (Join-Path $LogRoot 'STOP-MAINTENANCE')){throw 'Log maintenance stop requested; original retained'}
            Add-EvidenceRecord $LogRoot 'maintenance' @{time=[DateTimeOffset]::Now.ToString('o');event='heartbeat';phase='compressing';errors=$previousErrors}
        }
        try {
            $files=@(Invoke-DiagnosticLogMaintenance $LogRoot -Progress $progress)
            $previousErrors=@($files|Where-Object status -NE 'compressed')
        }catch{$files=@();$previousErrors=@(@{error=$_.Exception.Message})}
        $row=@{time=[DateTimeOffset]::Now.ToString('o');event='heartbeat';phase='idle';files=$files;errors=$previousErrors;policy='Keep today and yesterday raw; gzip older daily logs; no age-based deletion'}
        Add-EvidenceRecord $LogRoot 'maintenance' $row
        Save-EvidenceJson (Join-Path $dataRoot 'log-maintenance.json') $row
        $iteration++;if($MaxPasses -gt 0 -and $iteration -ge $MaxPasses){break}
        for($i=0;$i -lt 60 -and -not(Test-Path -LiteralPath (Join-Path $LogRoot 'STOP-MAINTENANCE'));$i++){Start-Sleep -Seconds 1}
    }
}finally{if($owner){$owner.Dispose()};if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()}
