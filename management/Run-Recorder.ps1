param([string]$DataRoot = (Join-Path $env:ProgramData 'PCDiagnostics'))
$ErrorActionPreference = 'Stop'
$codeRoot = Split-Path $PSScriptRoot
$logRoot = Join-Path $DataRoot 'logs'
$library = Join-Path $codeRoot 'library'
$shell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$mutex = [Threading.Mutex]::new($false,'Global\PCDiagnostics-Coordinator-v1')
$locked=$false
$workers=@{}
$runId=[guid]::NewGuid().ToString()
$activeSettings=Join-Path $DataRoot 'active-collection-settings.json'
$utf8=[Text.UTF8Encoding]::new($false)
. (Join-Path $codeRoot 'collectors\Collection-Settings.ps1')
. (Join-Path $codeRoot 'collectors\Log-Storage.ps1')
$collection=Get-CollectionSettings $DataRoot
$intervals=@{cpu=2000;board=2000;activity=2000}
$configuration=Join-Path $DataRoot 'recorder-settings.json'
if(Test-Path -LiteralPath $configuration){
    $settings=Get-Content -Encoding UTF8 -LiteralPath $configuration -Raw|ConvertFrom-Json
    foreach($name in @('cpu','board','activity')){
        if($null -ne $settings.intervalMilliseconds.$name){
            $value=[int]$settings.intervalMilliseconds.$name
            if($value -lt 1000 -or $value -gt 5000){throw "Invalid sampling interval for $name (1000..5000 ms)"}
            $intervals[$name]=$value
        }
    }
}
if(Test-Path (Join-Path $DataRoot 'collection-settings.json')){foreach($name in @('cpu','board','activity')){$intervals[$name]=1000*$collection.modules[$name].intervalSeconds}}
function Record-Controller($value) {
    $value.time=[DateTimeOffset]::Now.ToString('o')
    $path=Join-Path $logRoot ('coordinator-'+(Get-Date -Format yyyyMMdd)+'.jsonl')
    $handle=Open-DiagnosticLogWriter $path
    try {Write-DiagnosticLogLine $handle ($value|ConvertTo-Json -Compress -Depth 5)}finally{Close-DiagnosticLogWriter $handle}
}
function Launch-Worker($w) {
    $native=Join-Path $codeRoot 'tracekeep-worker.exe'
    $w.backend='powershell'
    $nativeModule=if($w.name -in @('activity','extended','maintenance')){$w.name}else{$w.module}
    if($nativeModule -in @('activity','configurationJournal','processes','performance','reliability','diskSpace','inventory','power','gpuDetails','crashConfiguration','extended','maintenance') -and (Test-Path -LiteralPath $native)){
        $args='--log-root "'+$logRoot+'" --settings "'+$activeSettings+'" --module '+$nativeModule+' --run-id "'+$runId+'"'
        if($nativeModule -eq 'activity'){$args+=' --interval-ms '+$intervals.activity}
        $w.process=Start-Process -FilePath $native -ArgumentList $args -WindowStyle Hidden -PassThru
        $w.backend='rust'
    }else{
    $args='-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$w.script+'" -LogRoot "'+$logRoot+'"'
    if($w.name -in @('cpu','board')) {$args+=' -LibraryDirectory "'+$library+'"'}
    if($w.name -in @('cpu','board','activity')) {$args+=' -IntervalMilliseconds '+$intervals[$w.name]}
    if($w.name -in @('evidence','extended') -or $w.module){$args+=' -SettingsPath "'+$activeSettings+'"'}
    if($w.name -eq 'extended' -or $w.module){$args+=' -RunId "'+$runId+'"'}
    if($w.module){$args+=' -Module "'+$w.module+'"'}
    $w.process=Start-Process -FilePath $shell -ArgumentList $args -WindowStyle Hidden -PassThru
    }
    $null=$w.process.Handle
    $w.started=[DateTimeOffset]::Now
    $w.state='starting'
    Record-Controller @{event='worker-start';worker=$w.name;pid=$w.process.Id;backend=$w.backend}
}
try {
    try {$locked=$mutex.WaitOne(0)} catch [Threading.AbandonedMutexException] {$locked=$true}
    if(-not $locked){exit 0}
    if(Test-Path (Join-Path $DataRoot 'STOP-ALL')){exit 0}
    Save-DiagnosticJson $activeSettings $collection
    Save-DiagnosticJson (Join-Path $DataRoot 'recorder-run.json') @{time=[DateTimeOffset]::Now.ToString('o');runId=$runId;pid=$PID;collection=$collection;intervalMilliseconds=$intervals}
    foreach($marker in @('STOP-CPU','STOP-BOARD','STOP','STOP-EVIDENCE','STOP-EXTENDED','STOP-MAINTENANCE')){$path=Join-Path $logRoot $marker;if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path}}
    foreach($entry in @(@('cpu','Start-AutomaticCpuLogging.ps1','cpu-auto-'),@('board','Start-MotherboardLogging.ps1','board-auto-'),@('activity','Start-ContinuousDiagnostics.ps1','activity-'),@('evidence','Start-EvidenceLogging.ps1','evidence-'),@('extended','Start-ExtendedLogging.ps1','extended-'),@('maintenance','Start-LogMaintenance.ps1','maintenance-'))){
        $workers[$entry[0]]=@{name=$entry[0];script=(Join-Path $codeRoot ('collectors\'+$entry[1]));prefix=$entry[2];process=$null;started=[DateTimeOffset]::Now;restarts=@();retryAt=[DateTimeOffset]::Now;state='starting'}
        $workers[$entry[0]].enabled=($entry[0] -in @('evidence','extended','maintenance') -or $collection.modules[$entry[0]].enabled)
        if($workers[$entry[0]].enabled){Launch-Worker $workers[$entry[0]]}else{$workers[$entry[0]].state='disabled';$workers[$entry[0]].errorCount=0}
    }
    foreach($name in Get-IsolatedCollectionModules){
        $key='module-'+$name
        $workers[$key]=@{name=$key;module=$name;script=(Join-Path $codeRoot 'collectors\Start-ExtendedLogging.ps1');prefix=($key+'-');process=$null;started=[DateTimeOffset]::Now;restarts=@();retryAt=[DateTimeOffset]::Now;state='starting';enabled=(Test-CollectionModuleEnabled $collection $name)}
        if($workers[$key].enabled){Launch-Worker $workers[$key]}else{$workers[$key].state='disabled';$workers[$key].errorCount=0}
    }
    while(-not (Test-Path (Join-Path $DataRoot 'STOP-ALL'))){
        $now=[DateTimeOffset]::Now
        foreach($w in $workers.Values){
            if(-not $w.enabled){continue}
            $file=Get-ChildItem -LiteralPath $logRoot -Filter ($w.prefix+'*.jsonl')|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 1
            $age=if($file){($now.UtcDateTime-$file.LastWriteTimeUtc).TotalSeconds}else{$null}
            $elapsed=($now-$w.started).TotalSeconds
            $alive=$w.process -and -not $w.process.HasExited
            $freshLimit=if($w.module){45}elseif($w.name -in @('extended','maintenance')){90}elseif($w.name -eq 'evidence'){45}else{[Math]::Max(10,$intervals[$w.name]/1000+5)}
            $stallLimit=[Math]::Max(120,3*$freshLimit)
            if($w.module -in @('dumpArchive','werArchive')){$stallLimit=600}
            $stalled=$alive -and $elapsed -gt $stallLimit -and ($null -eq $age -or $age -gt $stallLimit)
            if($stalled){Record-Controller @{event='worker-stalled';worker=$w.name;pid=$w.process.Id;logAgeSeconds=$age};$w.process.Kill();$null=$w.process.WaitForExit(5000);$alive=-not $w.process.HasExited}
            if(-not $alive){
                $w.restarts=@($w.restarts|Where-Object {($now-$_).TotalMinutes -lt 10})
                if($w.state -ne 'waiting' -and $w.state -ne 'cooldown'){$w.state='waiting';$w.retryAt=$now.AddSeconds(10);Record-Controller @{event='worker-exited';worker=$w.name}}
                if($w.restarts.Count -ge 3){$w.state='cooldown'}
                elseif($now -ge $w.retryAt){$w.restarts+=,$now;if($w.process){$w.process.Dispose()};Launch-Worker $w}
            } else {$w.state=if($null -ne $age -and $age -le $freshLimit){'recording'}else{'waiting-for-samples'}}
            $w.errorCount=0
            # Do not replace waiting/cooldown with a stale error row: that would
            # reset retryAt on every pass and prevent recovery indefinitely.
            if($alive -and ($w.name -in @('evidence','extended','maintenance') -or $w.module) -and $file){
                try {$row=Get-Content -Encoding UTF8 -LiteralPath $file.FullName -Tail 1|ConvertFrom-Json;$w.errorCount=@($row.errors).Count;if($w.errorCount){$w.state='recording-with-errors'}}catch{$w.state='unreadable-evidence';$w.errorCount=1}
            }
        }
        $runtime=@{time=$now.ToString('o');pid=$PID;runId=$runId;logRoot=$logRoot;workers=@($workers.Values|ForEach-Object {@{name=$_.name;enabled=$_.enabled;backend=$_.backend;pid=if($_.process){$_.process.Id}else{$null};state=$_.state;errorCount=$_.errorCount;recentRestarts=$_.restarts.Count}})}
        $temp=Join-Path $DataRoot 'runtime.tmp'
        [IO.File]::WriteAllText($temp,($runtime|ConvertTo-Json -Depth 5),$utf8)
        $dest=Join-Path $DataRoot 'runtime.json'
        if(Test-Path $dest){[IO.File]::Replace($temp,$dest,(Join-Path $DataRoot 'runtime.previous.json'))}else{[IO.File]::Move($temp,$dest)}
        Start-Sleep -Seconds 2
    }
} finally {
    if($locked){
        foreach($marker in @('STOP-CPU','STOP-BOARD','STOP','STOP-EVIDENCE','STOP-EXTENDED','STOP-MAINTENANCE')){[IO.File]::WriteAllText((Join-Path $logRoot $marker),'coordinator stop',$utf8)}
        # One shared grace period, not five seconds multiplied by worker count.
        $stopClock=[Diagnostics.Stopwatch]::StartNew()
        while($stopClock.Elapsed.TotalSeconds -lt 5 -and @($workers.Values|Where-Object {$_.process -and -not $_.process.HasExited}).Count){Start-Sleep -Milliseconds 100}
        foreach($w in $workers.Values){if($w.process){if(-not $w.process.HasExited){$w.process.Kill()};$w.process.Dispose()}}
        Record-Controller @{event='coordinator-stopped'}
        $mutex.ReleaseMutex()
    }
    $mutex.Dispose()
}
