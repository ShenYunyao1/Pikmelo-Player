param(
    [string]$Source = (Join-Path $PSScriptRoot '../icon_lucency.png')
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$projectRoot = Split-Path $PSScriptRoot -Parent
$sourceImage = [System.Drawing.Image]::FromFile((Resolve-Path -LiteralPath $Source))

function ConvertTo-IconPng([int]$Size) {
    $bitmap = [System.Drawing.Bitmap]::new($Size, $Size)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $stream = [System.IO.MemoryStream]::new()
    try {
        $graphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.DrawImage($sourceImage, 0, 0, $Size, $Size)
        $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
        return ,$stream.ToArray()
    } finally {
        $stream.Dispose()
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

try {
    $densities = [ordered]@{ mdpi = 48; hdpi = 72; xhdpi = 96; xxhdpi = 144; xxxhdpi = 192 }
    foreach ($density in $densities.GetEnumerator()) {
        $target = Join-Path $projectRoot "android/app/src/main/res/mipmap-$($density.Key)/ic_launcher.png"
        [System.IO.File]::WriteAllBytes($target, (ConvertTo-IconPng $density.Value))
    }
    $foreground = Join-Path $projectRoot 'android/app/src/main/res/drawable-nodpi/ic_launcher_foreground.png'
    [System.IO.Directory]::CreateDirectory((Split-Path $foreground -Parent)) | Out-Null
    [System.IO.File]::WriteAllBytes($foreground, (ConvertTo-IconPng 432))

    $sizes = @(16, 24, 32, 48, 64, 128, 256)
    $images = @($sizes | ForEach-Object { ,(ConvertTo-IconPng $_) })
    $ico = Join-Path $projectRoot 'windows/runner/resources/app_icon.ico'
    $writer = [System.IO.BinaryWriter]::new([System.IO.File]::Create($ico))
    try {
        $writer.Write([uint16]0)
        $writer.Write([uint16]1)
        $writer.Write([uint16]$sizes.Count)
        $offset = 6 + 16 * $sizes.Count
        for ($index = 0; $index -lt $sizes.Count; $index++) {
            $dimension = $sizes[$index] % 256
            $writer.Write([byte]$dimension)
            $writer.Write([byte]$dimension)
            $writer.Write([byte]0)
            $writer.Write([byte]0)
            $writer.Write([uint16]1)
            $writer.Write([uint16]32)
            $writer.Write([uint32]$images[$index].Length)
            $writer.Write([uint32]$offset)
            $offset += $images[$index].Length
        }
        foreach ($png in $images) { $writer.Write([byte[]]$png) }
    } finally { $writer.Dispose() }
} finally { $sourceImage.Dispose() }
