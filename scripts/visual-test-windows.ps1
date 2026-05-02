param(
  [string]$App = "notepad",
  [string]$OutDir = "$env:TEMP\wcu-visual-test",
  [int]$HoldMs = 900
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

public static class VisualCaptureWin32 {
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
  $screenDc = [VisualCaptureWin32]::GetDC([IntPtr]::Zero)
  $memoryDc = [VisualCaptureWin32]::CreateCompatibleDC($screenDc)
  $bitmapHandle = [VisualCaptureWin32]::CreateCompatibleBitmap($screenDc, $bounds.Width, $bounds.Height)
  $oldBitmap = [VisualCaptureWin32]::SelectObject($memoryDc, $bitmapHandle)
  try {
    [VisualCaptureWin32]::BitBlt($memoryDc, 0, 0, $bounds.Width, $bounds.Height, $screenDc, $bounds.Left, $bounds.Top, ([VisualCaptureWin32]::SRCCOPY -bor [VisualCaptureWin32]::CAPTUREBLT)) | Out-Null
    $bitmap = [System.Drawing.Image]::FromHbitmap($bitmapHandle)
    $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
  } finally {
    if ($oldBitmap -ne [IntPtr]::Zero) { [VisualCaptureWin32]::SelectObject($memoryDc, $oldBitmap) | Out-Null }
    if ($bitmapHandle -ne [IntPtr]::Zero) { [VisualCaptureWin32]::DeleteObject($bitmapHandle) | Out-Null }
    if ($memoryDc -ne [IntPtr]::Zero) { [VisualCaptureWin32]::DeleteDC($memoryDc) | Out-Null }
    if ($screenDc -ne [IntPtr]::Zero) { [VisualCaptureWin32]::ReleaseDC([IntPtr]::Zero, $screenDc) | Out-Null }
  }

  [pscustomobject]@{
    path = $Path
    width = $bounds.Width
    height = $bounds.Height
  }
}

if ($env:OS -ne "Windows_NT") {
  throw "This visual test must be run on Windows."
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

try { Invoke-Bridge -Command "hide-fake-cursor" | Out-Null } catch {}

if ($App -eq "notepad") {
  $existing = Get-Process -Name notepad -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
  if ($null -eq $existing) {
    Start-Process notepad.exe | Out-Null
    Start-Sleep -Milliseconds 800
  }
}

$setup = Invoke-Bridge -Command "setup-check"
$state = Invoke-Bridge -Command "get-app-state" -Payload @{
  app = $App
  includeCursor = $true
  depth = 5
  maxActionableElements = 80
  timeoutMs = 5000
}

if ($state.status -ne "found") {
  throw "App not found for visual test: $App"
}

$screenBounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$x = [int]($screenBounds.Left + ($screenBounds.Width * 0.76))
$y = [int]($screenBounds.Top + ($screenBounds.Height * 0.48))

$shown = Invoke-Bridge -Command "show-fake-cursor" -Payload @{
  x = $x
  y = $y
  style = "software"
  isPressed = $false
  debugFramePath = (Join-Path $OutDir "fake-cursor-frame.png")
}

Start-Sleep -Milliseconds $HoldMs

$screenshotPath = Join-Path $OutDir "fake-cursor-desktop.png"
$desktopScreenshot = Save-DesktopScreenshot $screenshotPath

$moved = Invoke-Bridge -Command "move-cursor" -Payload @{
  x = ($x + 90)
  y = ($y + 45)
  showFakeCursor = $true
  style = "software"
  isPressed = $true
  debugFramePath = (Join-Path $OutDir "fake-cursor-pressed-frame.png")
}

Start-Sleep -Milliseconds ([Math]::Max(250, [int]($HoldMs / 2)))

$pressedScreenshotPath = Join-Path $OutDir "fake-cursor-pressed-desktop.png"
$pressedScreenshot = Save-DesktopScreenshot $pressedScreenshotPath

$hidden = Invoke-Bridge -Command "hide-fake-cursor"

$report = [pscustomobject]@{
  status = "ok"
  app = $App
  setupStatus = $setup.status
  setupChecks = $setup.checks
  window = $state.window
  screenshot = $state.screenshot
  actionablePreview = @($state.actionableElements | Select-Object -First 12)
  fakeCursor = [pscustomobject]@{
    shown = $shown
    moved = $moved
    hidden = $hidden
    firstPoint = [pscustomobject]@{ x = $x; y = $y }
    secondPoint = [pscustomobject]@{ x = ($x + 90); y = ($y + 45) }
  }
  overlayFrames = @(
    (Join-Path $OutDir "fake-cursor-frame.png"),
    (Join-Path $OutDir "fake-cursor-pressed-frame.png")
  )
  desktopScreenshots = @($desktopScreenshot, $pressedScreenshot)
}

$reportPath = Join-Path $OutDir "visual-report.json"
$report | ConvertTo-Json -Depth 32 | Set-Content -Path $reportPath -Encoding UTF8
$report | ConvertTo-Json -Depth 32
