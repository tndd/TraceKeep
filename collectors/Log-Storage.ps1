# Shared durable JSONL storage. A persistent sidecar lock coordinates append,
# compression and clock-rollback restoration; lock files themselves contain no data.
function Enter-DiagnosticLogLock([string]$Path) {
    return [IO.FileStream]::new($Path+'.lock',[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
}
function Get-DiagnosticStreamHash($Stream,[scriptblock]$Progress) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try {
        if(-not $Progress){return ([BitConverter]::ToString($sha.ComputeHash($Stream))).Replace('-','').ToLowerInvariant()}
        $sink=[Security.Cryptography.CryptoStream]::new([IO.Stream]::Null,$sha,[Security.Cryptography.CryptoStreamMode]::Write)
        try {Copy-DiagnosticStream $Stream $sink $Progress;$sink.FlushFinalBlock();return ([BitConverter]::ToString($sha.Hash)).Replace('-','').ToLowerInvariant()}finally{$sink.Dispose()}
    }finally{$sha.Dispose()}
}
function Copy-DiagnosticStream($Source,$Destination,[scriptblock]$Progress) {
    $buffer=New-Object byte[] 1048576
    $clock=[Diagnostics.Stopwatch]::StartNew()
    while(($n=$Source.Read($buffer,0,$buffer.Length)) -gt 0){
        $Destination.Write($buffer,0,$n)
        if($Progress -and $clock.Elapsed.TotalSeconds -ge 10){& $Progress;$clock.Restart()}
    }
}
function Test-DiagnosticGzip([string]$Path,[string]$ExpectedHash,[scriptblock]$Progress) {
    # Windows PowerShell's older GZipStream does not reliably reject a damaged
    # trailer. Verify CRC32 and ISIZE explicitly as well as the original SHA-256.
    if(-not ('PCDiagnostics.LogCrc32' -as [type])){
        Add-Type -TypeDefinition @'
namespace PCDiagnostics {
    public static class LogCrc32 {
        static readonly uint[] Table = MakeTable();
        static uint[] MakeTable() {
            var table = new uint[256];
            for (uint i=0; i<256; i++) {
                uint c=i;
                for (int j=0; j<8; j++) c=(c&1)!=0 ? 0xedb88320u^(c>>1) : c>>1;
                table[i]=c;
            }
            return table;
        }
        public static uint Update(uint crc, byte[] bytes, int count) {
            for (int i=0; i<count; i++) crc=Table[(crc^bytes[i])&255]^(crc>>8);
            return crc;
        }
        public static uint Finish(uint crc) { return crc^0xffffffffu; }
    }
}
'@
    }
    $compressedInput=[IO.File]::OpenRead($Path)
    try {
        if($compressedInput.Length -lt 18 -or $compressedInput.ReadByte() -ne 31 -or $compressedInput.ReadByte() -ne 139 -or $compressedInput.ReadByte() -ne 8){throw 'Invalid gzip header'}
        [void]$compressedInput.Seek(-8,[IO.SeekOrigin]::End)
        $trailer=New-Object byte[] 8
        if($compressedInput.Read($trailer,0,8) -ne 8){throw 'Missing gzip trailer'}
        [void]$compressedInput.Seek(0,[IO.SeekOrigin]::Begin)
        $gzip=[IO.Compression.GZipStream]::new($compressedInput,[IO.Compression.CompressionMode]::Decompress)
        $sha=[Security.Cryptography.SHA256]::Create()
        try {
            $sink=[Security.Cryptography.CryptoStream]::new([IO.Stream]::Null,$sha,[Security.Cryptography.CryptoStreamMode]::Write)
            try {
                $buffer=New-Object byte[] 1048576;$crc=[uint32]::MaxValue;[long]$length=0
                $clock=[Diagnostics.Stopwatch]::StartNew()
                while(($n=$gzip.Read($buffer,0,$buffer.Length)) -gt 0){
                    $sink.Write($buffer,0,$n);$crc=[PCDiagnostics.LogCrc32]::Update($crc,$buffer,$n);$length+=$n
                    if($Progress -and $clock.Elapsed.TotalSeconds -ge 10){& $Progress;$clock.Restart()}
                }
                $sink.FlushFinalBlock();$actual=([BitConverter]::ToString($sha.Hash)).Replace('-','').ToLowerInvariant()
                if([PCDiagnostics.LogCrc32]::Finish($crc) -ne [BitConverter]::ToUInt32($trailer,0) -or [uint32]($length%4294967296) -ne [BitConverter]::ToUInt32($trailer,4)){throw 'Invalid gzip trailer; original log retained'}
            }finally{$sink.Dispose()}
            if($ExpectedHash -and $actual -ne $ExpectedHash){throw 'Compressed log hash mismatch; original log retained'}
        }finally{$sha.Dispose();$gzip.Dispose()}
    }finally{$compressedInput.Dispose()}
}
function Restore-DiagnosticLog([string]$Path) {
    # Caller owns the sidecar lock. A clock rollback may reopen an archived date.
    $archive=$Path+'.gz'
    if(-not [IO.File]::Exists($archive)){return}
    if([IO.File]::Exists($Path)){
        $source=[IO.File]::OpenRead($Path)
        try {$hash=Get-DiagnosticStreamHash $source}finally{$source.Dispose()}
        Test-DiagnosticGzip $archive $hash
    }else{
        $receipt=$archive+'.sha256'
        if(-not [IO.File]::Exists($receipt)){throw 'Archived log has no integrity receipt; refusing to overwrite it'}
        $hash=[IO.File]::ReadAllText($receipt).Trim()
        Test-DiagnosticGzip $archive $hash
        $input=[IO.File]::OpenRead($archive)
        try {
            $gzip=[IO.Compression.GZipStream]::new($input,[IO.Compression.CompressionMode]::Decompress)
            try {
                $output=[IO.FileStream]::new($Path+'.restore.partial',[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None,65536,[IO.FileOptions]::WriteThrough)
                try {Copy-DiagnosticStream $gzip $output;$output.Flush($true)}finally{$output.Dispose()}
            }finally{$gzip.Dispose()}
        }finally{$input.Dispose()}
        [IO.File]::Move($Path+'.restore.partial',$Path)
    }
    # The complete original exists before removing the redundant archive.
    [IO.File]::Delete($archive)
    [IO.File]::Delete($archive+'.sha256')
}
function Open-DiagnosticLogWriter([string]$Path) {
    $gate=Enter-DiagnosticLogLock $Path
    $stream=$null
    try {
        Restore-DiagnosticLog $Path
        $stream=[IO.FileStream]::new($Path,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Read,4096,[IO.FileOptions]::WriteThrough)
        if($stream.Length -gt 0){
            [void]$stream.Seek(-1,[IO.SeekOrigin]::End)
            if($stream.ReadByte() -ne 10){
                # Preserve the interrupted bytes, but prevent them swallowing the
                # next valid record. Readers report the isolated malformed line.
                [void]$stream.Seek(0,[IO.SeekOrigin]::End)
                $stream.WriteByte(10);$stream.Flush($true)
            }
        }
        [void]$stream.Seek(0,[IO.SeekOrigin]::End)
        $writer=[IO.StreamWriter]::new($stream,[Text.UTF8Encoding]::new($false))
        return @{writer=$writer;gate=$gate}
    }catch{if($stream){$stream.Dispose()};$gate.Dispose();throw}
}
function Write-DiagnosticLogLine($Handle,[string]$Line) {
    $Handle.writer.WriteLine($Line)
    $Handle.writer.Flush()
    $Handle.writer.BaseStream.Flush($true)
}
function Close-DiagnosticLogWriter($Handle) {
    if($Handle){try {$Handle.writer.Dispose()}finally{$Handle.gate.Dispose()}}
}
function Compress-DiagnosticLog([string]$Path,[scriptblock]$Progress) {
    $gate=Enter-DiagnosticLogLock $Path
    $source=$null
    try {
        $source=[IO.FileStream]::new($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $originalBytes=$source.Length
        $hash=Get-DiagnosticStreamHash $source $Progress
        [void]$source.Seek(0,[IO.SeekOrigin]::Begin)
        $archive=$Path+'.gz';$partial=$archive+'.partial'
        if(-not [IO.File]::Exists($archive)){
            $output=[IO.FileStream]::new($partial,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None,65536,[IO.FileOptions]::WriteThrough)
            try {
                $gzip=[IO.Compression.GZipStream]::new($output,[IO.Compression.CompressionLevel]::Optimal,$true)
                try {Copy-DiagnosticStream $source $gzip $Progress}finally{$gzip.Dispose()}
                $output.Flush($true)
            }finally{$output.Dispose()}
            Test-DiagnosticGzip $partial $hash $Progress
            [IO.File]::Move($partial,$archive)
        }else{
            # Resume an interrupted commit only if the existing archive is exact.
            Test-DiagnosticGzip $archive $hash $Progress
        }
        $receipt=$archive+'.sha256';$bytes=[Text.Encoding]::ASCII.GetBytes($hash)
        $output=[IO.FileStream]::new($receipt+'.tmp',[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough)
        try {$output.Write($bytes,0,$bytes.Length);$output.Flush($true)}finally{$output.Dispose()}
        if([IO.File]::Exists($receipt)){
            [IO.File]::Replace($receipt+'.tmp',$receipt,$receipt+'.previous')
            [IO.File]::Delete($receipt+'.previous')
        }else{[IO.File]::Move($receipt+'.tmp',$receipt)}
        $compressedBytes=(Get-Item -LiteralPath $archive).Length
        $source.Dispose();$source=$null
        # Writers cannot reopen the date until this commit releases the gate.
        [IO.File]::Delete($Path)
        return @{file=[IO.Path]::GetFileName($Path);status='compressed';originalBytes=$originalBytes;compressedBytes=$compressedBytes;sha256=$hash}
    }finally{if($source){$source.Dispose()};$gate.Dispose()}
}
function Invoke-DiagnosticLogMaintenance([string]$LogRoot,[datetime]$Now=(Get-Date),[scriptblock]$Progress,[int]$MaxFiles=64) {
    $cutoff=$Now.Date.AddDays(-1);$results=@();$count=0
    foreach($file in @(Get-ChildItem -LiteralPath $LogRoot -Filter '*.jsonl' -File|Sort-Object Name)){
        if($file.Name -notmatch '^([A-Za-z][A-Za-z0-9-]*)-(\d{8})\.jsonl$'){continue}
        $day=[datetime]::MinValue
        if(-not [datetime]::TryParseExact($Matches[2],'yyyyMMdd',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$day) -or $day -ge $cutoff){continue}
        if($count -ge $MaxFiles){break};$count++
        if($Progress){& $Progress}
        try {$results+=Compress-DiagnosticLog $file.FullName $Progress}
        catch {$results+=@{file=$file.Name;status='deferred';error=$_.Exception.Message}}
    }
    return $results
}
function Get-DiagnosticDailyLogs([string]$Root,[string]$Prefix) {
    $pattern='^'+[regex]::Escape($Prefix)+'\d{8}\.jsonl(\.gz)?$'
    # During an interrupted compression commit both copies may exist. Prefer raw.
    return @(Get-ChildItem -LiteralPath $Root -File -Filter ($Prefix+'*')|
        Where-Object {$_.Name -match $pattern}|
        Group-Object {$_.Name -replace '\.gz$',''}|
        ForEach-Object {$_.Group|Sort-Object {$_.Name.Length}|Select-Object -First 1}|
        Sort-Object Name)
}
function Read-DiagnosticLogTail([string]$Path,[int]$MaxBytes) {
    if(-not [IO.File]::Exists($Path)){
        if($Path.EndsWith('.gz') -and [IO.File]::Exists($Path.Substring(0,$Path.Length-3))){$Path=$Path.Substring(0,$Path.Length-3)}
        elseif([IO.File]::Exists($Path+'.gz')){$Path+='.gz'}
    }
    $source=[IO.FileStream]::new($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    try {
        if(-not $Path.EndsWith('.gz')){
            $length=$source.Length;$start=[Math]::Max(0,$length-$MaxBytes)
            [void]$source.Seek($start,[IO.SeekOrigin]::Begin)
            $bytes=New-Object byte[] ([int]($length-$start));$offset=0
            while($offset -lt $bytes.Length){$n=$source.Read($bytes,$offset,$bytes.Length-$offset);if(-not $n){break};$offset+=$n}
            return @{bytes=$bytes;length=$length;path=$Path}
        }
        $receipt=$Path+'.sha256'
        $expectedHash=if([IO.File]::Exists($receipt)){[IO.File]::ReadAllText($receipt).Trim()}else{''}
        Test-DiagnosticGzip $Path $expectedHash
        $gzip=[IO.Compression.GZipStream]::new($source,[IO.Compression.CompressionMode]::Decompress)
        try {
            $ring=New-Object byte[] $MaxBytes;$buffer=New-Object byte[] 65536
            $position=0;[long]$length=0
            while(($n=$gzip.Read($buffer,0,$buffer.Length)) -gt 0){
                $length+=$n
                if($n -ge $MaxBytes){[Array]::Copy($buffer,$n-$MaxBytes,$ring,0,$MaxBytes);$position=0}
                else{
                    $first=[Math]::Min($n,$MaxBytes-$position)
                    [Array]::Copy($buffer,0,$ring,$position,$first)
                    if($n -gt $first){[Array]::Copy($buffer,$first,$ring,0,$n-$first)}
                    $position=($position+$n)%$MaxBytes
                }
            }
            $size=[int][Math]::Min($length,$MaxBytes);$bytes=New-Object byte[] $size
            $start=if($length -gt $MaxBytes){$position}else{0}
            $first=[Math]::Min($size,$MaxBytes-$start)
            [Array]::Copy($ring,$start,$bytes,0,$first)
            if($size -gt $first){[Array]::Copy($ring,0,$bytes,$first,$size-$first)}
            return @{bytes=$bytes;length=$length;path=$Path}
        }finally{$gzip.Dispose()}
    }finally{$source.Dispose()}
}
