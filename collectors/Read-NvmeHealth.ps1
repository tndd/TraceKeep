# Read-only Windows storage-property queries. No pass-through commands or new driver.
# See docs/evidence-coverage.md for API references and interpretation limits.
function Initialize-NvmeReader {
    if('PCDiagnostics.NvmeHealthReader' -as [type]){return}
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace PCDiagnostics {
    public static class NvmeHealthReader {
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern SafeFileHandle CreateFile(string path, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError=true)]
        static extern bool DeviceIoControl(SafeFileHandle handle, uint code, byte[] input, uint inputSize, [Out] byte[] output, uint outputSize, out uint returned, IntPtr overlapped);
        static void Put(byte[] b, int offset, uint value) { Array.Copy(BitConverter.GetBytes(value),0,b,offset,4); }
        public static byte[] Request() {
            byte[] b=new byte[560];
            Put(b,0,49); // StorageAdapterProtocolSpecificProperty: controller-wide SMART
            Put(b,4,0);  // PropertyStandardQuery
            Put(b,8,3);  // ProtocolTypeNvme
            Put(b,12,2); // NVMeDataTypeLogPage
            Put(b,16,2); // NVME_LOG_PAGE_HEALTH_INFO; fixed, not caller supplied
            Put(b,24,40); Put(b,28,512);
            Put(b,44,1); // RetainAsynEvent; do not acknowledge/clear an async warning
            return b;
        }
        public static byte[] Extract(byte[] b, uint returned) {
            return ExtractData(b,returned,512,2);
        }
        static byte[] ExtractData(byte[] b, uint returned, uint expectedLength, uint expectedType) {
            if(b==null || returned>b.Length || returned<48) throw new InvalidDataException("Truncated NVMe descriptor");
            if(BitConverter.ToUInt32(b,0)!=48 || BitConverter.ToUInt32(b,4)!=48 || BitConverter.ToUInt32(b,8)!=3 || BitConverter.ToUInt32(b,12)!=expectedType)
                throw new InvalidDataException("Unexpected NVMe descriptor");
            uint offset=BitConverter.ToUInt32(b,24), length=BitConverter.ToUInt32(b,28);
            if(offset<40 || length!=expectedLength || 8UL+offset+length>returned) throw new InvalidDataException("Invalid NVMe payload bounds");
            byte[] health=new byte[length]; Array.Copy(b,(long)(8UL+offset),health,0,length); return health;
        }
        public static byte[] Read(uint diskNumber) {
            return Query(diskNumber,Request(),512,2);
        }
        public static byte[] Identify(uint diskNumber) {
            byte[] b=new byte[4144]; Array.Copy(Request(),b,48);
            Put(b,12,1); Put(b,16,1); Put(b,28,4096); Put(b,44,0);
            return Query(diskNumber,b,4096,1);
        }
        public static byte[] Errors(uint diskNumber, int entryCount) {
            if(entryCount<1 || entryCount>256) throw new ArgumentOutOfRangeException("entryCount");
            uint length=(uint)Math.Max(512,entryCount*64);
            byte[] b=new byte[48+length]; Array.Copy(Request(),b,48);
            Put(b,16,1); Put(b,28,length);
            return Query(diskNumber,b,length,2);
        }
        static byte[] Query(uint diskNumber, byte[] b, uint length, uint dataType) {
            using(SafeFileHandle handle=CreateFile(@"\\.\PhysicalDrive"+diskNumber,0,3,IntPtr.Zero,3,0,IntPtr.Zero)) {
                if(handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error(),"Open physical disk for health query");
                uint returned;
                if(!DeviceIoControl(handle,0x002D1400,b,(uint)b.Length,b,(uint)b.Length,out returned,IntPtr.Zero))
                    throw new Win32Exception(Marshal.GetLastWin32Error(),"NVMe SMART storage-property query");
                return ExtractData(b,returned,length,dataType);
            }
        }
    }
}
'@
}
function ConvertFrom-NvmeHealth([byte[]]$Bytes) {
    if($null -eq $Bytes -or $Bytes.Length -ne 512){throw 'NVMe health page must contain exactly 512 bytes'}
    if(@($Bytes|Where-Object {$_ -ne 0}).Count -eq 0){throw 'Empty NVMe health page; cannot interpret as healthy'}
    Add-Type -AssemblyName System.Numerics
    $counterNames=@('dataUnitsRead','dataUnitsWritten','hostReadCommands','hostWriteCommands','controllerBusyMinutes','powerCycles','powerOnHours','unsafeShutdowns','mediaErrors','errorLogEntryCount')
    $counters=[ordered]@{}
    for($i=0;$i -lt $counterNames.Count;$i++){
        $unsigned=New-Object byte[] 17
        [Array]::Copy($Bytes,32+16*$i,$unsigned,0,16)
        $counters[$counterNames[$i]]=[Numerics.BigInteger]::new($unsigned).ToString([Globalization.CultureInfo]::InvariantCulture)
    }
    $kelvin=[BitConverter]::ToUInt16($Bytes,1)
    $temperatures=@(for($i=0;$i -lt 8;$i++){$t=[BitConverter]::ToUInt16($Bytes,200+2*$i);if($t -eq 0){$null}else{[Math]::Round($t-273.15,2)}})
    return [ordered]@{
        criticalWarning=[int]$Bytes[0]
        temperatureC=if($kelvin -eq 0){$null}else{[Math]::Round($kelvin-273.15,2)}
        availableSparePercent=[int]$Bytes[3];spareThresholdPercent=[int]$Bytes[4];percentageUsed=[int]$Bytes[5]
        counters=$counters;warningTemperatureMinutes=[BitConverter]::ToUInt32($Bytes,192);criticalTemperatureMinutes=[BitConverter]::ToUInt32($Bytes,196)
        temperatureSensorsC=$temperatures;rawHealthBase64=[Convert]::ToBase64String($Bytes)
        counterEncoding='Unsigned 128-bit decimal strings; data units are 512000 bytes'
    }
}
function Get-NvmeHealthEvidence([bool]$IncludeHealth=$true,[bool]$IncludeErrors=$false) {
    $result=@{time=[DateTimeOffset]::Now.ToString('o');method='IOCTL_STORAGE_QUERY_PROPERTY / controller SMART log 0x02';disks=@();errors=@()}
    try {
        Initialize-NvmeReader
        # Get-Disk.Number maps to PhysicalDriveN; Get-PhysicalDisk.DeviceId need not.
        foreach($disk in @(Get-Disk -ErrorAction Stop|Where-Object {[string]$_.BusType -eq 'NVMe'})){
            $row=@{number=[uint32]$disk.Number;name=$disk.FriendlyName;status='unavailable';health=$null;error=$null;win32Error=$null}
            try {if($IncludeHealth){$row.health=ConvertFrom-NvmeHealth ([PCDiagnostics.NvmeHealthReader]::Read([uint32]$disk.Number));$row.status='ok'}else{$row.status='disabled'}}catch{
                $row.error=$_.Exception.GetBaseException().Message
                $base=$_.Exception.GetBaseException();if($base -is [ComponentModel.Win32Exception]){$row.win32Error=$base.NativeErrorCode}
            }
            $row.details=@{status='disabled'}
            if($IncludeErrors){
                try {
                    $id=[PCDiagnostics.NvmeHealthReader]::Identify([uint32]$disk.Number)
                    if([BitConverter]::ToUInt16($id,0) -eq 0){throw 'Empty NVMe controller identify response'}
                    $count=[int]$id[262]+1
                    $raw=[PCDiagnostics.NvmeHealthReader]::Errors([uint32]$disk.Number,$count)
                    $entries=@(for($i=0;$i -lt $count;$i++){
                        $o=$i*64;$ec=[BitConverter]::ToUInt64($raw,$o)
                        if($ec -ne 0){@{errorCount=$ec.ToString();submissionQueue=[BitConverter]::ToUInt16($raw,$o+8);commandId=[BitConverter]::ToUInt16($raw,$o+10);statusRaw=[BitConverter]::ToUInt16($raw,$o+12);parameterErrorLocation=[BitConverter]::ToUInt16($raw,$o+14);lba=[BitConverter]::ToUInt64($raw,$o+16).ToString();namespace=[BitConverter]::ToUInt32($raw,$o+24)}}
                    })
                    $identityHash=[Security.Cryptography.SHA256]::Create();try {$deviceKey=([BitConverter]::ToString($identityHash.ComputeHash($id[4..63]))).Replace('-','')}finally{$identityHash.Dispose()}
                    $w=[BitConverter]::ToUInt16($id,266);$c=[BitConverter]::ToUInt16($id,268)
                    $row.details=@{status='ok';deviceKey=$deviceKey;model=[Text.Encoding]::ASCII.GetString($id,24,40).Trim();firmware=[Text.Encoding]::ASCII.GetString($id,64,8).Trim();warningTemperatureC=if($w){[Math]::Round($w-273.15,2)}else{$null};criticalTemperatureC=if($c){[Math]::Round($c-273.15,2)}else{$null};supportedErrorEntries=$count;entries=$entries;rawErrorBase64=[Convert]::ToBase64String($raw);note='Error entries have no wall-clock timestamp. Device key is a local hash of controller identity; serial number not stored in plaintext.'}
                }catch{$row.details=@{status='unavailable';error=$_.Exception.GetBaseException().Message}}
            }
            $result.disks+= $row
        }
    }catch{$result.errors+=$_.Exception.Message}
    $result.note='Lifetime counters, not an attribution of PSU failure. Unsafe shutdown increments mean no shutdown notification before power loss. Unsupported or failed queries remain unavailable.'
    return $result
}
