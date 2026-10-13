$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot) 'collectors\Evidence-Core.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('pcdiag-evidence-test-'+[guid]::NewGuid().ToString('N'))
$state=Join-Path $root 'state';[void][IO.Directory]::CreateDirectory($state)
function Assert($condition,$message){if(-not $condition){throw $message}}
$cursor=[pscustomobject]@{channel='System';recordId=45}
$xpath=Get-EvidenceXPath 'System' $cursor 100 ([DateTimeOffset]::Now)
Assert ($xpath.Contains('EventRecordID > 45') -and -not $xpath.Contains('TimeCreated')) 'Checkpoint must survive time changes and long downtime'
Assert ((Get-EvidenceXPath 'System' $cursor 10 ([DateTimeOffset]::Now)).Contains('TimeCreated')) 'Log reset must recover bounded history'
$script:event= [pscustomobject]@{TimeCreated=(Get-Date);RecordId=46L;ProviderName='Synthetic WHEA';Id=19;Level=3}
$script:event|Add-Member ScriptMethod ToXml {'<Event>synthetic</Event>'}
function Get-WinEvent {param($LogName,$MaxEvents,$ErrorAction);return [pscustomobject]@{RecordId=100}}
function Read-EvidenceEvents {param($channel,$xpath,$limit);return @($script:event)}
$result=Sync-EvidenceChannel $root $state 'System'
Assert ((Get-EvidenceCursor $state 'System').recordId -eq 100 -and $result.recovered -eq 1) 'Cursor must advance after durable records'
$saved=Get-Content (Join-Path $root ('events-'+(Get-Date -Format yyyyMMdd)+'.jsonl'))|ConvertFrom-Json
Assert ($saved.xml -eq '<Event>synthetic</Event>' -and $saved.channel -eq 'System') 'Full event XML and channel must be retained'
$realWrite=${function:Add-EvidenceRecord}
function Add-EvidenceRecord {param($root,$kind,$value);throw 'synthetic disk write failure'}
$failed=$false;try {Sync-EvidenceChannel $root $state 'System'}catch{$failed=$true}
Assert ($failed -and (Get-EvidenceCursor $state 'System').recordId -eq 100) 'Failed append must never advance checkpoint'
Set-Item Function:\Add-EvidenceRecord $realWrite
$cursorPath=Join-Path $state 'System.json'
Save-EvidenceJson $cursorPath @{channel='System';recordId=101}
[IO.File]::WriteAllText($cursorPath,'{broken')
Assert ((Get-EvidenceCursor $state 'System').recordId -eq 100) 'Corrupt checkpoint must recover previous checkpoint'
[IO.File]::WriteAllText($cursorPath+'.previous','{broken')
$failed=$false;try {Get-EvidenceCursor $state 'System'}catch{$failed=$true}
Assert $failed 'Both damaged checkpoints must be reported instead of silently skipping events'
$source=Join-Path $root 'source.jsonl';$dest=Join-Path $root 'tail.jsonl'
[IO.File]::WriteAllText($source,"{`"old`":1}`n{`"new`":2}`n{partial",$script:EvidenceUtf8)
$copy=Copy-EvidenceTail $source $dest 24
$tail=Get-Content $dest -Raw
Assert ($copy.tailLimited -and $tail.Contains('"new":2') -and -not $tail.Contains('partial')) 'Tail must be bounded and omit incomplete rows'
Assert ($copy.sha256 -eq (Get-FileHash $dest -Algorithm SHA256).Hash) 'Bundle hash must match saved bytes'
# Empty final fragment and a file with no complete rows are valid empty evidence.
[IO.File]::WriteAllText($source,'{partial',$script:EvidenceUtf8)
$null=Copy-EvidenceTail $source $dest
Assert ((Get-Item $dest).Length -eq 0) 'Partial-only source must not masquerade as a complete record'
Save-EvidenceJson (Join-Path $root 'empty.json') @()
Assert (((Get-Content (Join-Path $root 'empty.json') -Raw) -replace '\s','') -eq '[]') 'Empty event batch must serialize as an array'
Save-EvidenceJson (Join-Path $root 'null.json') $null
Assert ((Get-Content (Join-Path $root 'null.json') -Raw).Trim() -eq 'null') 'Missing value must serialize explicitly'
$boot=[DateTimeOffset]::Now.AddMinutes(-5)
$script:event.Id=41;$script:event.TimeCreated=$boot.LocalDateTime.AddSeconds(5)
$bundle=New-IncidentBundle $root $root $boot @{settings=@{};os=@{}}
$manifest=Get-Content (Join-Path $bundle 'manifest.json') -Raw|ConvertFrom-Json
Assert ($manifest.classification -eq 'abnormal-boot-evidence' -and $manifest.abnormalEventCount -eq 1) 'Boot event must classify the saved evidence'
$hash=(Get-FileHash (Join-Path $bundle 'manifest.json')).Hash
$null=New-IncidentBundle $root $root $boot @{settings=@{changed=$true}}
Assert ((Get-FileHash (Join-Path $bundle 'manifest.json')).Hash -eq $hash) 'Repeated worker starts must preserve the boot bundle'
Write-Output 'PASS: durable checkpoint ordering, time-independent recovery, log reset, corrupt-state fallback, raw XML, bounded tails and partial-write handling.'
