# Regenerates ram-monitor.ico (multi-resolution) and assets/icon.png
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tools\make-icon.ps1
Add-Type -AssemblyName System.Drawing

function New-IconBitmap([int]$s) {
    $bmp = New-Object System.Drawing.Bitmap($s, $s)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)

    # Rounded violet gradient background
    $r = [int]($s * 0.22); $d = $r * 2
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc(0, 0, $d, $d, 180, 90)
    $path.AddArc($s - $d, 0, $d, $d, 270, 90)
    $path.AddArc($s - $d, $s - $d, $d, $d, 0, 90)
    $path.AddArc(0, $s - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    $grad = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        (New-Object System.Drawing.Point(0, 0)), (New-Object System.Drawing.Point($s, $s)),
        [System.Drawing.Color]::FromArgb(126, 96, 240), [System.Drawing.Color]::FromArgb(66, 45, 158))
    $g.FillPath($grad, $path)
    $grad.Dispose(); $path.Dispose()

    # RAM module: white bar with chips and pins
    $mx = [int]($s * 0.16); $my = [int]($s * 0.22)
    $mw = [int]($s * 0.68); $mh = [int]($s * 0.26)
    $white = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(245, 245, 250))
    $g.FillRectangle($white, $mx, $my, $mw, $mh)

    if ($s -ge 32) {
        $chipBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(104, 78, 214))
        $chipW = [int]($s * 0.10); $chipH = [int]($s * 0.14)
        $chipY = $my + [int](($mh - $chipH) / 2)
        for ($i = 0; $i -lt 4; $i++) {
            $chipX = $mx + [int]($s * 0.05) + $i * [int]($s * 0.16)
            $g.FillRectangle($chipBrush, $chipX, $chipY, $chipW, $chipH)
        }
        $chipBrush.Dispose()
        $pinBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(200, 200, 215))
        $pinW = [int][math]::Max(1, $s * 0.045); $pinH = [int]($s * 0.06)
        for ($i = 0; $i -lt 7; $i++) {
            $pinX = $mx + [int]($s * 0.03) + $i * [int]($s * 0.095)
            $g.FillRectangle($pinBrush, $pinX, ($my + $mh), $pinW, $pinH)
        }
        $pinBrush.Dispose()
    }
    $white.Dispose()

    # Lightning bolt (the Optimize signature)
    if ($s -ge 24) {
        $bolt = @(
            (New-Object System.Drawing.PointF([single]($s * 0.56), [single]($s * 0.56))),
            (New-Object System.Drawing.PointF([single]($s * 0.40), [single]($s * 0.76))),
            (New-Object System.Drawing.PointF([single]($s * 0.50), [single]($s * 0.76))),
            (New-Object System.Drawing.PointF([single]($s * 0.45), [single]($s * 0.92))),
            (New-Object System.Drawing.PointF([single]($s * 0.63), [single]($s * 0.70))),
            (New-Object System.Drawing.PointF([single]($s * 0.53), [single]($s * 0.70)))
        )
        $boltBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 205, 60))
        $g.FillPolygon($boltBrush, $bolt)
        $boltBrush.Dispose()
    }

    $g.Dispose()
    return $bmp
}

$root    = Split-Path -Parent $PSScriptRoot
$icoPath = Join-Path $root 'ram-monitor.ico'
$pngPath = Join-Path $root 'assets\icon.png'

$sizes = 16, 20, 24, 32, 48, 64, 128, 256
$pngs = @()
foreach ($s in $sizes) {
    $b = New-IconBitmap $s
    $ms = New-Object System.IO.MemoryStream
    $b.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    if ($s -eq 256) { $b.Save($pngPath, [System.Drawing.Imaging.ImageFormat]::Png) }
    $b.Dispose()
    $pngs += ,$ms.ToArray()
    $ms.Dispose()
}

$fs = [System.IO.File]::Create($icoPath)
$bw = New-Object System.IO.BinaryWriter($fs)
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $s = $sizes[$i]
    $bw.Write([byte]$(if ($s -ge 256) { 0 } else { $s }))
    $bw.Write([byte]$(if ($s -ge 256) { 0 } else { $s }))
    $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([uint16]1); $bw.Write([uint16]32)
    $bw.Write([uint32]$pngs[$i].Length)
    $bw.Write([uint32]$offset)
    $offset += $pngs[$i].Length
}
foreach ($p in $pngs) { $bw.Write($p) }
$bw.Close(); $fs.Close()
"Icon written: $icoPath"
"Preview written: $pngPath"
