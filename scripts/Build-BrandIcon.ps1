$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Drawing
$root=Split-Path $PSScriptRoot
$source=[Drawing.Image]::FromFile((Join-Path $root 'assets\tracekeep-source.png'))
$sizes=@(16,20,24,32,48,64,128,256)
$images=[Collections.Generic.List[byte[]]]::new()
try {
    foreach($size in $sizes){
        $bitmap=[Drawing.Bitmap]::new($size,$size,[Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $graphics=[Drawing.Graphics]::FromImage($bitmap)
        $stream=[IO.MemoryStream]::new()
        try {
            $graphics.CompositingMode=[Drawing.Drawing2D.CompositingMode]::SourceCopy
            $graphics.CompositingQuality=[Drawing.Drawing2D.CompositingQuality]::HighQuality
            $graphics.InterpolationMode=[Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $graphics.PixelOffsetMode=[Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $graphics.DrawImage($source,[Drawing.Rectangle]::new(0,0,$size,$size))
            $bitmap.Save($stream,[Drawing.Imaging.ImageFormat]::Png)
            $images.Add($stream.ToArray())
            if($size -eq 128){[IO.File]::WriteAllBytes((Join-Path $root 'ui\tracekeep.png'),$stream.ToArray())}
        } finally {$stream.Dispose();$graphics.Dispose();$bitmap.Dispose()}
    }
    $file=[IO.File]::Create((Join-Path $root 'src-tauri\icons\icon.ico'))
    $writer=[IO.BinaryWriter]::new($file)
    try {
        $writer.Write([uint16]0);$writer.Write([uint16]1);$writer.Write([uint16]$sizes.Count)
        $offset=6+16*$sizes.Count
        for($i=0;$i -lt $sizes.Count;$i++){
            $dimension=if($sizes[$i] -eq 256){0}else{$sizes[$i]}
            $writer.Write([byte]$dimension);$writer.Write([byte]$dimension);$writer.Write([byte]0);$writer.Write([byte]0)
            $writer.Write([uint16]1);$writer.Write([uint16]32);$writer.Write([uint32]$images[$i].Length);$writer.Write([uint32]$offset)
            $offset+=$images[$i].Length
        }
        foreach($image in $images){$writer.Write($image)}
    } finally {$writer.Dispose()}
} finally {$source.Dispose()}
