$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot) 'collectors\Read-NvmeHealth.ps1')
function Assert($condition,$message){if(-not $condition){throw $message}}
function Must-Fail([scriptblock]$Action){$failed=$false;try {& $Action|Out-Null}catch{$failed=$true};Assert $failed 'Invalid input was accepted'}
Initialize-NvmeReader
$b=New-Object byte[] 512
$b[1]=0x40;$b[2]=1;$b[3]=100;$b[4]=10
$b[144]=35;$b[160]=2;$b[176]=7;$b[192]=4;$b[196]=5
$b[200]=0x40;$b[201]=1
# Maximum unsigned 128-bit counter exercises JSON precision and sign handling.
for($i=128;$i -lt 144;$i++){$b[$i]=255}
$health=ConvertFrom-NvmeHealth $b
Assert ($health.counters.unsafeShutdowns -ceq '35' -and $health.counters.mediaErrors -ceq '2' -and $health.counters.errorLogEntryCount -ceq '7') 'Wrong NVMe counter offsets'
Assert ($health.counters.powerOnHours -ceq '340282366920938463463374607431768211455') '128-bit unsigned precision lost'
Assert ($health.temperatureC -eq 46.85 -and $health.temperatureSensorsC.Count -eq 8 -and $null -eq $health.temperatureSensorsC[1]) 'Temperature conversion or absent sensor handling failed'
Assert ($health.warningTemperatureMinutes -eq 4 -and $health.criticalTemperatureMinutes -eq 5) 'Wrong temperature time offsets'
Assert ([Convert]::FromBase64String($health.rawHealthBase64).Length -eq 512) 'Raw evidence lost'
$roundTrip=$health|ConvertTo-Json -Depth 6|ConvertFrom-Json
Assert ($roundTrip.counters.powerOnHours -is [string]) 'JSON must keep counters as strings'
Must-Fail {ConvertFrom-NvmeHealth (New-Object byte[] 511)}
Must-Fail {ConvertFrom-NvmeHealth (New-Object byte[] 512)}
$query=[PCDiagnostics.NvmeHealthReader]::Request()
Assert ($query.Length -eq 560 -and [BitConverter]::ToUInt32($query,0) -eq 49 -and [BitConverter]::ToUInt32($query,16) -eq 2 -and [BitConverter]::ToUInt32($query,44) -eq 1) 'Query must request only controller health and retain asynchronous events'
$response=$query.Clone();[BitConverter]::GetBytes([uint32]48).CopyTo($response,0);[BitConverter]::GetBytes([uint32]48).CopyTo($response,4);$b.CopyTo($response,48)
Assert ([PCDiagnostics.NvmeHealthReader]::Extract($response,560).Length -eq 512) 'Valid response rejected'
Must-Fail {[PCDiagnostics.NvmeHealthReader]::Extract($response,559)}
Must-Fail {[PCDiagnostics.NvmeHealthReader]::Extract($response,561)}
$bad=$response.Clone();[BitConverter]::GetBytes([uint32]4294967295).CopyTo($bad,24)
Must-Fail {[PCDiagnostics.NvmeHealthReader]::Extract($bad,560)}
$bad=$response.Clone();[BitConverter]::GetBytes([uint32]39).CopyTo($bad,24)
Must-Fail {[PCDiagnostics.NvmeHealthReader]::Extract($bad,560)}
$bad=$response.Clone();$bad[8]=2
Must-Fail {[PCDiagnostics.NvmeHealthReader]::Extract($bad,560)}
# Inventory failures are explicit, never converted to an empty healthy result.
function Get-Disk {param($ErrorAction);throw 'synthetic disk enumeration failure'}
$result=Get-NvmeHealthEvidence
Assert ($result.errors.Count -eq 1 -and $result.disks.Count -eq 0) 'Inventory error hidden'
Write-Output 'PASS: NVMe health decoding, precision, nulls, raw retention, query flags, descriptor bounds and unavailable inventory; no disk queries performed.'
