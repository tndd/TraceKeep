param([string]$DataRoot = (Join-Path $env:ProgramData 'PCDiagnostics'))
$ErrorActionPreference = 'Stop'
$codeRoot = Split-Path $PSScriptRoot
$logRoot = Join-Path $DataRoot 'logs'
$library = Join-Path $codeRoot 'library'
$shell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$mutex = [Threading.Mutex]::new($false,'Global\PCDiagnostics-Coordinator-v1')
$locked=$false
$workers=@{}
$utf8=[Text.UTF8Encoding]::new($false)
function Record-Controller($value) {
    $value.time=[DateTimeOffset]::Now.ToString('o')
    $path=Join-Path $logRoot ('coordinator-'+(Get-Date -Format yyyyMMdd)+'.jsonl')
    $file=[IO.FileStream]::new($path,[IO.FileMode]::Append,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite,4096,[IO.FileOptions]::WriteThrough)
    $writer=[IO.StreamWriter]::new($file,$utf8)
    try {$writer.WriteLine(($value|ConvertTo-Json -Compress -Depth 5));$writer.Flush();$file.Flush($true)} finally {$writer.Dispose()}
}
function Launch-Worker($w) {
    $args='-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$w.script+'" -LogRoot "'+$logRoot+'"'
    if($w.name -ne 'activity') {$args+=' -LibraryDirectory "'+$library+'"'}
    $w.process=Start-Process -FilePath $shell -ArgumentList $args -WindowStyle Hidden -PassThru
    $null=$w.process.Handle
    $w.started=[DateTimeOffset]::Now
    $w.state='starting'
    Record-Controller @{event='worker-start';worker=$w.name;pid=$w.process.Id}
}
try {
    try {$locked=$mutex.WaitOne(0)} catch [Threading.AbandonedMutexException] {$locked=$true}
    if(-not $locked){exit 0}
    if(Test-Path (Join-Path $DataRoot 'STOP-ALL')){exit 0}
    foreach($marker in @('STOP-CPU','STOP-BOARD','STOP')){$path=Join-Path $logRoot $marker;if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path}}
    foreach($entry in @(@('cpu','Start-AutomaticCpuLogging.ps1','cpu-auto-'),@('board','Start-MotherboardLogging.ps1','board-auto-'),@('activity','Start-ContinuousDiagnostics.ps1','activity-'))){
        $workers[$entry[0]]=@{name=$entry[0];script=(Join-Path $codeRoot ('collectors\'+$entry[1]));prefix=$entry[2];process=$null;started=[DateTimeOffset]::Now;restarts=@();retryAt=[DateTimeOffset]::Now;state='starting'}
        Launch-Worker $workers[$entry[0]]
    }
    while(-not (Test-Path (Join-Path $DataRoot 'STOP-ALL'))){
        $now=[DateTimeOffset]::Now
        foreach($w in $workers.Values){
            $file=Get-ChildItem -LiteralPath $logRoot -Filter ($w.prefix+'*.jsonl')|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 1
            $age=if($file){($now.UtcDateTime-$file.LastWriteTimeUtc).TotalSeconds}else{$null}
            $elapsed=($now-$w.started).TotalSeconds
            $alive=$w.process -and -not $w.process.HasExited
            $stalled=$alive -and $elapsed -gt 60 -and ($null -eq $age -or $age -gt 60)
            if($stalled){Record-Controller @{event='worker-stalled';worker=$w.name;pid=$w.process.Id;logAgeSeconds=$age};$w.process.Kill();$null=$w.process.WaitForExit(5000);$alive=-not $w.process.HasExited}
            if(-not $alive){
                $w.restarts=@($w.restarts|Where-Object {($now-$_).TotalMinutes -lt 10})
                if($w.state -ne 'waiting' -and $w.state -ne 'cooldown'){$w.state='waiting';$w.retryAt=$now.AddSeconds(10);Record-Controller @{event='worker-exited';worker=$w.name}}
                if($w.restarts.Count -ge 3){$w.state='cooldown'}
                elseif($now -ge $w.retryAt){$w.restarts+=,$now;if($w.process){$w.process.Dispose()};Launch-Worker $w}
            } else {$w.state=if($null -ne $age -and $age -le 10){'recording'}else{'waiting-for-samples'}}
        }
        $runtime=@{time=$now.ToString('o');pid=$PID;logRoot=$logRoot;workers=@($workers.Values|ForEach-Object {@{name=$_.name;pid=if($_.process){$_.process.Id}else{$null};state=$_.state;recentRestarts=$_.restarts.Count}})}
        $temp=Join-Path $DataRoot 'runtime.tmp'
        [IO.File]::WriteAllText($temp,($runtime|ConvertTo-Json -Depth 5),$utf8)
        $dest=Join-Path $DataRoot 'runtime.json'
        if(Test-Path $dest){[IO.File]::Replace($temp,$dest,(Join-Path $DataRoot 'runtime.previous.json'))}else{[IO.File]::Move($temp,$dest)}
        Start-Sleep -Seconds 2
    }
} finally {
    if($locked){
        foreach($marker in @('STOP-CPU','STOP-BOARD','STOP')){[IO.File]::WriteAllText((Join-Path $logRoot $marker),'coordinator stop',$utf8)}
        foreach($w in $workers.Values){if($w.process){if(-not $w.process.HasExited -and -not $w.process.WaitForExit(5000)){$w.process.Kill();$null=$w.process.WaitForExit(5000)};$w.process.Dispose()}}
        Record-Controller @{event='coordinator-stopped'}
        $mutex.ReleaseMutex()
    }
    $mutex.Dispose()
}
