param(
  [Parameter(Mandatory = $true)]
  [string]$StateFile,

  [Parameter(Mandatory = $true)]
  [string]$AssetDir
)

$ErrorActionPreference = "Stop"
$OverlayErrorLog = "$StateFile.overlay-error.log"
$OverlayHeartbeat = "$StateFile.overlay-heartbeat.json"

trap {
  try {
    Add-Content -Path $OverlayErrorLog -Value ("[{0}] fatal: {1}`n{2}" -f (Get-Date -Format o), $_.Exception.Message, $_.ScriptStackTrace) -Encoding UTF8
  } catch {}
  break
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class OverlayWin32 {
  public const int GWL_EXSTYLE = -20;
  public const int WS_EX_TRANSPARENT = 0x00000020;
  public const int WS_EX_LAYERED = 0x00080000;
  public const int WS_EX_TOOLWINDOW = 0x00000080;
  public const int WS_EX_NOACTIVATE = 0x08000000;
  public const int ULW_ALPHA = 0x00000002;
  public const byte AC_SRC_OVER = 0x00;
  public const byte AC_SRC_ALPHA = 0x01;
  public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
  public const uint SWP_NOSIZE = 0x0001;
  public const uint SWP_NOMOVE = 0x0002;
  public const uint SWP_NOACTIVATE = 0x0010;
  public const uint SWP_SHOWWINDOW = 0x0040;

  [StructLayout(LayoutKind.Sequential)]
  public struct POINT {
    public int x;
    public int y;
  }

  [StructLayout(LayoutKind.Sequential)]
  public struct SIZE {
    public int cx;
    public int cy;
  }

  [StructLayout(LayoutKind.Sequential, Pack = 1)]
  public struct BLENDFUNCTION {
    public byte BlendOp;
    public byte BlendFlags;
    public byte SourceConstantAlpha;
    public byte AlphaFormat;
  }

  [DllImport("user32.dll")]
  public static extern int GetWindowLong(IntPtr hWnd, int nIndex);

  [DllImport("user32.dll")]
  public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);

  [DllImport("user32.dll")]
  public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

  [DllImport("user32.dll")]
  public static extern IntPtr GetDC(IntPtr hWnd);

  [DllImport("user32.dll")]
  public static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);

  [DllImport("gdi32.dll")]
  public static extern IntPtr CreateCompatibleDC(IntPtr hDC);

  [DllImport("gdi32.dll")]
  public static extern bool DeleteDC(IntPtr hdc);

  [DllImport("gdi32.dll")]
  public static extern IntPtr SelectObject(IntPtr hDC, IntPtr hObject);

  [DllImport("gdi32.dll")]
  public static extern bool DeleteObject(IntPtr hObject);

  [DllImport("user32.dll")]
  public static extern bool UpdateLayeredWindow(
    IntPtr hwnd,
    IntPtr hdcDst,
    ref POINT pptDst,
    ref SIZE psize,
    IntPtr hdcSrc,
    ref POINT pptSrc,
    int crKey,
    ref BLENDFUNCTION pblend,
    int dwFlags
  );
}
"@

$CursorImagePath = Join-Path $AssetDir "cursor.png"
$LensDir = Join-Path $AssetDir "LensSequence"
$FrameSize = 184
$TickMs = 33

function Read-CursorState {
  try {
    if (!(Test-Path $StateFile)) {
      return [pscustomobject]@{ x = 0; y = 0; visible = $false; style = "software"; isPressed = $false }
    }
    $state = Get-Content $StateFile -Raw | ConvertFrom-Json
    if ($null -eq $state.cursor) {
      return [pscustomobject]@{ x = 0; y = 0; visible = $false; style = "software"; isPressed = $false }
    }
    return $state.cursor
  } catch {
    return [pscustomobject]@{ x = 0; y = 0; visible = $false; style = "software"; isPressed = $false }
  }
}

function Normalize-CursorStyle($Style) {
  $value = "$Style".ToLowerInvariant()
  if ($value -eq "software" -or $value -eq "pointer") { return "software" }
  if ($value -eq "lens") { return "lens" }
  if ($value -eq "fog") { return "fog" }
  return "software"
}

function Get-NowMilliseconds {
  [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
}

function Clamp-Unit([double]$Value) {
  if ($Value -lt 0) { return 0.0 }
  if ($Value -gt 1) { return 1.0 }
  return $Value
}

function Update-AnimatedCursorPoint([double]$TargetX, [double]$TargetY) {
  $now = Get-NowMilliseconds
  if ($null -eq $script:VisualX -or $null -eq $script:VisualY) {
    $script:VisualX = $TargetX
    $script:VisualY = $TargetY
    $script:TargetX = $TargetX
    $script:TargetY = $TargetY
    $script:AnimationStartMs = $now
  }

  if ([Math]::Abs($TargetX - $script:TargetX) -gt 0.5 -or [Math]::Abs($TargetY - $script:TargetY) -gt 0.5) {
    $script:StartX = $script:VisualX
    $script:StartY = $script:VisualY
    $script:TargetX = $TargetX
    $script:TargetY = $TargetY
    $script:AnimationStartMs = $now
    $script:CurveDirection = -1 * $script:CurveDirection
  }

  $duration = [Math]::Max(1, $script:AnimationDurationMs)
  $t = Clamp-Unit (([double]($now - $script:AnimationStartMs)) / $duration)
  $ease = (3 * $t * $t) - (2 * $t * $t * $t)
  $dx = $script:TargetX - $script:StartX
  $dy = $script:TargetY - $script:StartY
  $distance = [Math]::Sqrt(($dx * $dx) + ($dy * $dy))
  $arc = 0.0
  $nx = 0.0
  $ny = 0.0
  if ($distance -gt 1) {
    $arc = [Math]::Sin([Math]::PI * $t) * [Math]::Min(82, $distance * 0.18) * $script:CurveDirection
    $nx = -1 * $dy / $distance
    $ny = $dx / $distance
  }

  $script:VisualX = $script:StartX + ($dx * $ease) + ($nx * $arc)
  $script:VisualY = $script:StartY + ($dy * $ease) + ($ny * $arc)

  if ($t -ge 1) {
    $script:VisualX = $script:TargetX
    $script:VisualY = $script:TargetY
  }

  [pscustomobject]@{ x = [int][Math]::Round($script:VisualX); y = [int][Math]::Round($script:VisualY); progress = $t }
}

function Load-LensFrames {
  if (!(Test-Path $LensDir)) { return @() }
  Get-ChildItem -Path $LensDir -Filter "Lens_frame_*.png" |
    Sort-Object Name |
    ForEach-Object {
      try { [System.Drawing.Image]::FromFile($_.FullName) } catch { $null }
    } |
    Where-Object { $null -ne $_ }
}

function New-CursorImage {
  if (Test-Path $CursorImagePath) {
    try { return [System.Drawing.Image]::FromFile($CursorImagePath) } catch {}
  }
  $legacyCursor = Join-Path $AssetDir "SoftwareCursor.png"
  if (Test-Path $legacyCursor) {
    try { return [System.Drawing.Image]::FromFile($legacyCursor) } catch {}
  }
  return $null
}

function Set-LayeredBitmap {
  param(
    [Parameter(Mandatory = $true)]
    [System.Windows.Forms.Form]$Form,

    [Parameter(Mandatory = $true)]
    [System.Drawing.Bitmap]$Bitmap,

    [Parameter(Mandatory = $true)]
    [int]$X,

    [Parameter(Mandatory = $true)]
    [int]$Y
  )

  $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
  $sourceX = 0
  $sourceY = 0
  $destX = $X
  $destY = $Y
  $width = $Bitmap.Width
  $height = $Bitmap.Height

  if ($destX -lt $bounds.Left) {
    $sourceX = $bounds.Left - $destX
    $width -= $sourceX
    $destX = $bounds.Left
  }
  if ($destY -lt $bounds.Top) {
    $sourceY = $bounds.Top - $destY
    $height -= $sourceY
    $destY = $bounds.Top
  }
  if (($destX + $width) -gt $bounds.Right) {
    $width = $bounds.Right - $destX
  }
  if (($destY + $height) -gt $bounds.Bottom) {
    $height = $bounds.Bottom - $destY
  }
  if ($width -le 0 -or $height -le 0) {
    return
  }

  $screenDc = [OverlayWin32]::GetDC([IntPtr]::Zero)
  $memoryDc = [OverlayWin32]::CreateCompatibleDC($screenDc)
  $bitmapHandle = [IntPtr]::Zero
  $oldBitmap = [IntPtr]::Zero
  try {
    $bitmapHandle = $Bitmap.GetHbitmap([System.Drawing.Color]::FromArgb(0, 0, 0, 0))
    $oldBitmap = [OverlayWin32]::SelectObject($memoryDc, $bitmapHandle)

    $destination = New-Object OverlayWin32+POINT
    $destination.x = $destX
    $destination.y = $destY

    $size = New-Object OverlayWin32+SIZE
    $size.cx = $width
    $size.cy = $height

    $source = New-Object OverlayWin32+POINT
    $source.x = $sourceX
    $source.y = $sourceY

    $blend = New-Object OverlayWin32+BLENDFUNCTION
    $blend.BlendOp = [OverlayWin32]::AC_SRC_OVER
    $blend.BlendFlags = 0
    $blend.SourceConstantAlpha = 255
    $blend.AlphaFormat = [OverlayWin32]::AC_SRC_ALPHA

    [OverlayWin32]::UpdateLayeredWindow(
      $Form.Handle,
      $screenDc,
      [ref]$destination,
      [ref]$size,
      $memoryDc,
      [ref]$source,
      0,
      [ref]$blend,
      [OverlayWin32]::ULW_ALPHA
    ) | Out-Null
    [OverlayWin32]::SetWindowPos($Form.Handle, [OverlayWin32]::HWND_TOPMOST, 0, 0, 0, 0, ([OverlayWin32]::SWP_NOMOVE -bor [OverlayWin32]::SWP_NOSIZE -bor [OverlayWin32]::SWP_NOACTIVATE -bor [OverlayWin32]::SWP_SHOWWINDOW)) | Out-Null
  } finally {
    if ($oldBitmap -ne [IntPtr]::Zero) { [OverlayWin32]::SelectObject($memoryDc, $oldBitmap) | Out-Null }
    if ($bitmapHandle -ne [IntPtr]::Zero) { [OverlayWin32]::DeleteObject($bitmapHandle) | Out-Null }
    if ($memoryDc -ne [IntPtr]::Zero) { [OverlayWin32]::DeleteDC($memoryDc) | Out-Null }
    if ($screenDc -ne [IntPtr]::Zero) { [OverlayWin32]::ReleaseDC([IntPtr]::Zero, $screenDc) | Out-Null }
  }
}

function Set-OverlayWindowStyle($Form) {
  $style = [OverlayWin32]::GetWindowLong($Form.Handle, [OverlayWin32]::GWL_EXSTYLE)
  $style = $style -bor [OverlayWin32]::WS_EX_TRANSPARENT -bor [OverlayWin32]::WS_EX_LAYERED -bor [OverlayWin32]::WS_EX_TOOLWINDOW -bor [OverlayWin32]::WS_EX_NOACTIVATE
  [OverlayWin32]::SetWindowLong($Form.Handle, [OverlayWin32]::GWL_EXSTYLE, $style) | Out-Null
}

function Draw-FogCursor($Graphics) {
  $center = [single]($script:FrameSize / 2)
  $outer = New-Object System.Drawing.RectangleF -ArgumentList 4, 4, ($script:FrameSize - 8), ($script:FrameSize - 8)
  $path = New-Object System.Drawing.Drawing2D.GraphicsPath
  $path.AddEllipse($outer)
  $brush = New-Object System.Drawing.Drawing2D.PathGradientBrush -ArgumentList $path
  $brush.CenterPoint = New-Object System.Drawing.PointF -ArgumentList $center, $center
  $brush.CenterColor = [System.Drawing.Color]::FromArgb(42, 255, 255, 255)
  $brush.SurroundColors = [System.Drawing.Color[]]@([System.Drawing.Color]::FromArgb(0, 255, 255, 255))
  $Graphics.FillPath($brush, $path)
  $brush.Dispose()
  $path.Dispose()

  $shadowPen = New-Object System.Drawing.Pen -ArgumentList ([System.Drawing.Color]::FromArgb(36, 0, 0, 0)), 10
  $glowPen = New-Object System.Drawing.Pen -ArgumentList ([System.Drawing.Color]::FromArgb(80, 255, 255, 255)), 2
  $innerPen = New-Object System.Drawing.Pen -ArgumentList ([System.Drawing.Color]::FromArgb(90, 122, 216, 255)), 1
  $Graphics.DrawEllipse($shadowPen, 30, 30, ($script:FrameSize - 60), ($script:FrameSize - 60))
  $Graphics.DrawEllipse($glowPen, 38, 38, ($script:FrameSize - 76), ($script:FrameSize - 76))
  $Graphics.DrawEllipse($innerPen, 58, 58, ($script:FrameSize - 116), ($script:FrameSize - 116))
  $shadowPen.Dispose()
  $glowPen.Dispose()
  $innerPen.Dispose()

  if ($script:IsPressed) {
    $pressBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(36, 255, 255, 255))
    $Graphics.FillEllipse($pressBrush, 54, 54, ($script:FrameSize - 108), ($script:FrameSize - 108))
    $pressBrush.Dispose()
  }
}

function Draw-Lens($Graphics) {
  if ($script:LensFrames -and $script:LensFrames.Length -gt 0) {
    $frame = $script:LensFrames[$script:LensFrameIndex % $script:LensFrames.Length]
    $lensSize = 48
    $lensOrigin = [int](($script:FrameSize - $lensSize) / 2)
    $Graphics.DrawImage($frame, $lensOrigin, $lensOrigin, $lensSize, $lensSize)
    $script:LensFrameIndex++
  }
}

function Draw-SoftwareCursor($Graphics) {
  if ($script:CursorImage -eq $null) { return }

  $pulse = Clamp-Unit ([double]$script:PressPulse)
  $size = [single](111 + (5 * $pulse))
  $x = [single](($script:FrameSize - $size) / 2)
  $y = [single](($script:FrameSize - $size) / 2)

  $state = $Graphics.Save()
  try {
    $Graphics.TranslateTransform([single]($script:FrameSize / 2), [single]($script:FrameSize / 2))
    $Graphics.RotateTransform([single]$script:PointerAngle)
    $Graphics.TranslateTransform([single](-1 * $script:FrameSize / 2), [single](-1 * $script:FrameSize / 2))
    $Graphics.DrawImage($script:CursorImage, $x, $y, $size, $size)
  } finally {
    $Graphics.Restore($state)
  }
}

function Render-CursorFrame {
  $bitmap = New-Object System.Drawing.Bitmap -ArgumentList $script:FrameSize, $script:FrameSize, ([System.Drawing.Imaging.PixelFormat]::Format32bppPArgb)
  $g = [System.Drawing.Graphics]::FromImage($bitmap)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $g.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceOver
  $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
  $g.Clear([System.Drawing.Color]::Transparent)

  if ($script:CursorStyle -eq "software") {
    Draw-SoftwareCursor $g
    $g.Dispose()
    return $bitmap
  }

  if ($script:CursorStyle -eq "fog") {
    Draw-FogCursor $g
  }

  Draw-Lens $g
  $g.Dispose()
  return $bitmap
}

[System.Windows.Forms.Application]::EnableVisualStyles()

$script:CursorImage = New-CursorImage
$script:LensFrames = @(Load-LensFrames)
$script:LensFrameIndex = 0
$script:CursorStyle = "software"
$script:IsPressed = $false
$script:PressPulse = 0.0
$script:PointerAngle = 0.0
$script:VisualX = $null
$script:VisualY = $null
$script:StartX = 0.0
$script:StartY = 0.0
$script:TargetX = 0.0
$script:TargetY = 0.0
$script:AnimationStartMs = Get-NowMilliseconds
$script:AnimationDurationMs = 420
$script:CurveDirection = 1

$form = New-Object System.Windows.Forms.Form
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$form.ShowInTaskbar = $false
$form.TopMost = $true
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$form.Size = New-Object System.Drawing.Size -ArgumentList $script:FrameSize, $script:FrameSize
$form.Location = New-Object System.Drawing.Point -ArgumentList -32000, -32000
$form.Add_Shown({ Set-OverlayWindowStyle $form })
$form.Add_Paint({})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $TickMs
$timer.Add_Tick({
  try {
    $cursor = Read-CursorState
    if ($env:WCU_OVERLAY_DEBUG -eq "1" -or $cursor.debugFramePath) {
      [pscustomobject]@{
        pid = $PID
        tickedAt = Get-Date -Format o
        visible = [bool]$cursor.visible
        x = $cursor.x
        y = $cursor.y
        style = $cursor.style
        isPressed = $cursor.isPressed
        debugFramePath = $cursor.debugFramePath
        formVisible = $form.Visible
      } | ConvertTo-Json -Compress | Set-Content -Path $script:OverlayHeartbeat -Encoding UTF8
    }
    if ($cursor.visible) {
      $x = [int]$cursor.x
      $y = [int]$cursor.y
      $script:CursorStyle = Normalize-CursorStyle $cursor.style
      $script:IsPressed = ($cursor.isPressed -eq $true)
      $nowMs = Get-NowMilliseconds
      $pulseUntil = 0
      try { $pulseUntil = [int64]$cursor.clickPulseUntil } catch {}
      $script:PressPulse = if ($script:IsPressed) { 1.0 } else { Clamp-Unit (([double]($pulseUntil - $nowMs)) / 620.0) }
      $script:PointerAngle = if ($script:CursorStyle -eq "software") { -8.0 * $script:PressPulse } else { 0.0 }
      $point = Update-AnimatedCursorPoint $x $y
      $half = [int]($script:FrameSize / 2)
      if (!$form.Visible) { $form.Show() }
      $bitmap = Render-CursorFrame
      try {
        if ($cursor.debugFramePath) {
          try { $bitmap.Save("$($cursor.debugFramePath)", [System.Drawing.Imaging.ImageFormat]::Png) } catch {}
        }
        Set-LayeredBitmap -Form $form -Bitmap $bitmap -X ($point.x - $half) -Y ($point.y - $half)
      } finally {
        $bitmap.Dispose()
      }
    } else {
      $form.Location = New-Object System.Drawing.Point -ArgumentList -32000, -32000
    }
  } catch {
    Add-Content -Path $script:OverlayErrorLog -Value ("[{0}] {1}`n{2}" -f (Get-Date -Format o), $_.Exception.Message, $_.ScriptStackTrace) -Encoding UTF8
    $timer.Stop()
    $form.Close()
  }
})

$form.Add_FormClosed({
  $timer.Stop()
  foreach ($frame in $script:LensFrames) {
    try { $frame.Dispose() } catch {}
  }
  try { $script:CursorImage.Dispose() } catch {}
})

$timer.Start()
[System.Windows.Forms.Application]::Run($form)
