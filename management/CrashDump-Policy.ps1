# Functions only. Registry writes are invoked by explicit administrative upgrade/config.
function Protect-DiagnosticArchive($Path) {
    [void][IO.Directory]::CreateDirectory($Path)
    $acl=[Security.AccessControl.DirectorySecurity]::new();$acl.SetAccessRuleProtection($true,$false)
    foreach($sidText in @('S-1-5-18','S-1-5-32-544')){
        $sid=[Security.Principal.SecurityIdentifier]::new($sidText)
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}
function Enable-DiagnosticDumps($DataRoot,$Key='HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl') {
    $path=Join-Path $DataRoot 'dump-policy-backup.json'
    if(Test-Path $path){$prior=Get-Content -Encoding UTF8 $path -Raw|ConvertFrom-Json;if($prior.active){return @{status='already-configured';restartRequired=$true}}}
    $current=Get-ItemProperty -LiteralPath $Key -ErrorAction Stop
    $wanted=@{CrashDumpEnabled=7;AlwaysKeepMemoryDump=1;LogEvent=1}
    if($current.CrashDumpEnabled -in @(1,2,7)){$wanted.CrashDumpEnabled=[int]$current.CrashDumpEnabled}
    $entries=@(foreach($name in $wanted.Keys){@{name=$name;existed=($current.PSObject.Properties.Name -contains $name);previous=$current.$name;applied=$wanted[$name]}})
    Save-EvidenceJson $path @{active=$true;time=[DateTimeOffset]::Now.ToString('o');entries=$entries;restartRequired=$true}
    try {foreach($entry in $entries){New-ItemProperty -LiteralPath $Key -Name $entry.name -Value $entry.applied -PropertyType DWord -Force -ErrorAction Stop|Out-Null}}catch{Restore-DiagnosticDumps $DataRoot $Key|Out-Null;throw}
    return @{status='configured';restartRequired=$true;autoRebootChanged=$false;pagefileChanged=$false}
}
function Restore-DiagnosticDumps($DataRoot,$Key='HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl') {
    $path=Join-Path $DataRoot 'dump-policy-backup.json'
    if(-not(Test-Path $path)){return @{status='no-owned-settings'}}
    $state=Get-Content -Encoding UTF8 $path -Raw|ConvertFrom-Json
    if(-not $state.active){return @{status='already-restored'}}
    $current=Get-ItemProperty -LiteralPath $Key -ErrorAction Stop
    foreach($entry in $state.entries){
        # Respect settings changed externally after our update.
        if($current.($entry.name) -ne $entry.applied){continue}
        if($entry.existed){New-ItemProperty -LiteralPath $Key -Name $entry.name -Value $entry.previous -PropertyType DWord -Force -ErrorAction Stop|Out-Null}else{Remove-ItemProperty -LiteralPath $Key -Name $entry.name -ErrorAction Stop}
    }
    $state.active=$false;Save-EvidenceJson $path $state
    return @{status='restored-owned-settings';restartRequired=$true}
}
