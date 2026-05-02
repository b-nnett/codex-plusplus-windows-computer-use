param(
  [string]$App = "edge",
  [string]$OutDir = "$env:TEMP\wcu-coordinate-offset-test",
  [int]$HoldMs = 700
)

$ErrorActionPreference = "Stop"

$RootDir = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$Bridge = Join-Path $RootDir "scripts\windows-bridge.ps1"

function Invoke-Bridge {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Command,

    [hashtable]$Payload = @{}
  )

  $json = $Payload | ConvertTo-Json -Depth 16 -Compress
  $payloadBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json))
  try {
    $env:WCU_PAYLOAD_BASE64 = $payloadBase64
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Bridge -Command $Command |
      ConvertFrom-Json
  } finally {
    Remove-Item Env:WCU_PAYLOAD_BASE64 -ErrorAction SilentlyContinue
  }
}

function Save-DesktopScreenshot {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing
  Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class CoordinateOffsetCaptureWin32 {
  public const int SRCCOPY = 0x00CC0020;
  public const int CAPTUREBLT = 0x40000000;

  [DllImport("user32.dll")]
  public static extern IntPtr GetDC(IntPtr hWnd);

  [DllImport("user32.dll")]
  public static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);

  [DllImport("gdi32.dll")]
  public static extern IntPtr CreateCompatibleDC(IntPtr hDC);

  [DllImport("gdi32.dll")]
  public static extern IntPtr CreateCompatibleBitmap(IntPtr hDC, int width, int height);

  [DllImport("gdi32.dll")]
  public static extern IntPtr SelectObject(IntPtr hDC, IntPtr hObject);

  [DllImport("gdi32.dll")]
  public static extern bool BitBlt(IntPtr hdcDest, int xDest, int yDest, int width, int height, IntPtr hdcSrc, int xSrc, int ySrc, int rasterOp);

  [DllImport("gdi32.dll")]
  public static extern bool DeleteObject(IntPtr hObject);

  [DllImport("gdi32.dll")]
  public static extern bool DeleteDC(IntPtr hDC);
}
"@ -ErrorAction SilentlyContinue

  $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
  $screenDc = [CoordinateOffsetCaptureWin32]::GetDC([IntPtr]::Zero)
  $memoryDc = [CoordinateOffsetCaptureWin32]::CreateCompatibleDC($screenDc)
  $bitmapHandle = [CoordinateOffsetCaptureWin32]::CreateCompatibleBitmap($screenDc, $bounds.Width, $bounds.Height)
  $oldBitmap = [CoordinateOffsetCaptureWin32]::SelectObject($memoryDc, $bitmapHandle)
  try {
    [CoordinateOffsetCaptureWin32]::BitBlt($memoryDc, 0, 0, $bounds.Width, $bounds.Height, $screenDc, $bounds.Left, $bounds.Top, ([CoordinateOffsetCaptureWin32]::SRCCOPY -bor [CoordinateOffsetCaptureWin32]::CAPTUREBLT)) | Out-Null
    $bitmap = [System.Drawing.Image]::FromHbitmap($bitmapHandle)
    $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
  } finally {
    if ($oldBitmap -ne [IntPtr]::Zero) { [CoordinateOffsetCaptureWin32]::SelectObject($memoryDc, $oldBitmap) | Out-Null }
    if ($bitmapHandle -ne [IntPtr]::Zero) { [CoordinateOffsetCaptureWin32]::DeleteObject($bitmapHandle) | Out-Null }
    if ($memoryDc -ne [IntPtr]::Zero) { [CoordinateOffsetCaptureWin32]::DeleteDC($memoryDc) | Out-Null }
    if ($screenDc -ne [IntPtr]::Zero) { [CoordinateOffsetCaptureWin32]::ReleaseDC([IntPtr]::Zero, $screenDc) | Out-Null }
  }

  [pscustomobject]@{
    path = $Path
    width = $bounds.Width
    height = $bounds.Height
  }
}

if ($env:OS -ne "Windows_NT") {
  throw "This coordinate offset test must be run on Windows."
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

try { Invoke-Bridge -Command "hide-fake-cursor" | Out-Null } catch {}

$setup = Invoke-Bridge -Command "setup-check"
$state = Invoke-Bridge -Command "get-app-state" -Payload @{
  app = $App
  includeCursor = $true
  depth = 4
  maxActionableElements = 120
  timeoutMs = 8000
}

if ($state.status -ne "found") {
  throw "App not found for coordinate offset test: $App"
}

$targets = Invoke-Bridge -Command "dump-app-targets" -Payload @{
  app = $App
  depth = 8
  maxTargets = 250
  includeOffscreen = $false
  timeoutMs = 8000
}

$origin = $state.screenshot.screenOrigin
$width = [int]$state.screenshot.width
$height = [int]$state.screenshot.height
$searchTarget = @(
  $targets.targets |
    Where-Object {
      $_.screenCenter -and
      (("$($_.label)" -match "Search|検索|Suchen|Buscar|Rechercher") -or
       ("$($_.name)" -match "Search|検索|Suchen|Buscar|Rechercher") -or
       ("$($_.automationId)" -match "search"))
    } |
    Select-Object -First 1
)

if ($searchTarget.Count -gt 0) {
  $inputX = [int]([double]$searchTarget[0].screenCenter.x - [double]$origin.x)
  $inputY = [int]([double]$searchTarget[0].screenCenter.y - [double]$origin.y)
} else {
  $inputX = [Math]::Max(30, [Math]::Min($width - 30, [int]($width * 0.72)))
  $inputY = [Math]::Max(30, [Math]::Min($height - 30, 80))
}

$expectedX = [int]([double]$origin.x + $inputX)
$expectedY = [int]([double]$origin.y + $inputY)
$framePath = Join-Path $OutDir "offset-cursor-frame.png"
$moved = Invoke-Bridge -Command "move-cursor" -Payload @{
  app = $App
  x = $inputX
  y = $inputY
  coordinateSpace = "screenshot"
  showFakeCursor = $true
  style = "software"
  isPressed = $false
  debugFramePath = $framePath
}

Start-Sleep -Milliseconds $HoldMs

$desktopScreenshot = Save-DesktopScreenshot (Join-Path $OutDir "offset-cursor-desktop.png")
$hidden = Invoke-Bridge -Command "hide-fake-cursor"

$verified = ([int]$moved.x -eq $expectedX) -and ([int]$moved.y -eq $expectedY) -and [bool]$moved.fakeCursorVisible

$report = [pscustomobject]@{
  status = if ($verified) { "ok" } else { "failed" }
  app = $App
  setupStatus = $setup.status
  window = $state.window
  screenshot = $state.screenshot
  targetUsed = if ($searchTarget.Count -gt 0) { $searchTarget[0] } else { $null }
  input = [pscustomobject]@{ x = $inputX; y = $inputY; coordinateSpace = "screenshot" }
  expectedScreen = [pscustomobject]@{ x = $expectedX; y = $expectedY }
  moved = $moved
  verified = $verified
  overlayFrame = $framePath
  desktopScreenshot = $desktopScreenshot
  fakeCursorHidden = $hidden
}

$reportPath = Join-Path $OutDir "visual-report.json"
$report | ConvertTo-Json -Depth 32 | Set-Content -Path $reportPath -Encoding UTF8
$report | ConvertTo-Json -Depth 32

if (!$verified) {
  throw "Coordinate offset move was not verified."
}
