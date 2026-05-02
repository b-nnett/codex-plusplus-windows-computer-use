param(
  [string]$OutDir = "$env:TEMP\wcu-calculator-test",
  [int]$HoldMs = 180
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

public static class CalculatorCaptureWin32 {
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
  $screenDc = [CalculatorCaptureWin32]::GetDC([IntPtr]::Zero)
  $memoryDc = [CalculatorCaptureWin32]::CreateCompatibleDC($screenDc)
  $bitmapHandle = [CalculatorCaptureWin32]::CreateCompatibleBitmap($screenDc, $bounds.Width, $bounds.Height)
  $oldBitmap = [CalculatorCaptureWin32]::SelectObject($memoryDc, $bitmapHandle)
  try {
    [CalculatorCaptureWin32]::BitBlt($memoryDc, 0, 0, $bounds.Width, $bounds.Height, $screenDc, $bounds.Left, $bounds.Top, ([CalculatorCaptureWin32]::SRCCOPY -bor [CalculatorCaptureWin32]::CAPTUREBLT)) | Out-Null
    $bitmap = [System.Drawing.Image]::FromHbitmap($bitmapHandle)
    $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
  } finally {
    if ($oldBitmap -ne [IntPtr]::Zero) { [CalculatorCaptureWin32]::SelectObject($memoryDc, $oldBitmap) | Out-Null }
    if ($bitmapHandle -ne [IntPtr]::Zero) { [CalculatorCaptureWin32]::DeleteObject($bitmapHandle) | Out-Null }
    if ($memoryDc -ne [IntPtr]::Zero) { [CalculatorCaptureWin32]::DeleteDC($memoryDc) | Out-Null }
    if ($screenDc -ne [IntPtr]::Zero) { [CalculatorCaptureWin32]::ReleaseDC([IntPtr]::Zero, $screenDc) | Out-Null }
  }

  [pscustomobject]@{
    path = $Path
    width = $bounds.Width
    height = $bounds.Height
  }
}

function Find-Target {
  param(
    [array]$Targets,
    [string]$Name,
    [string[]]$AutomationIds = @(),
    [string[]]$LabelPatterns = @()
  )

  foreach ($automationId in $AutomationIds) {
    $match = @($Targets | Where-Object { "$($_.automationId)" -eq $automationId -and $_.screenCenter } | Select-Object -First 1)
    if ($match.Count -gt 0) { return $match[0] }
  }

  foreach ($pattern in $LabelPatterns) {
    $match = @(
      $Targets |
        Where-Object {
          $_.screenCenter -and
          (("$($_.label)" -match $pattern) -or ("$($_.name)" -match $pattern))
        } |
        Select-Object -First 1
    )
    if ($match.Count -gt 0) { return $match[0] }
  }

  throw "Calculator target not found: $Name"
}

function Move-And-Click {
  param(
    [Parameter(Mandatory = $true)]
    $Target,

    [Parameter(Mandatory = $true)]
    [string]$Name,

    [Parameter(Mandatory = $true)]
    [string]$FramePath
  )

  $x = [int]$Target.screenCenter.x
  $y = [int]$Target.screenCenter.y
  $move = Invoke-Bridge -Command "move-cursor" -Payload @{
    x = $x
    y = $y
    showFakeCursor = $true
    style = "software"
    isPressed = $false
    debugFramePath = $FramePath
  }
  Start-Sleep -Milliseconds $script:HoldMs
  $click = Invoke-Bridge -Command "click" -Payload @{
    app = "calculator"
    x = $x
    y = $y
    mouse_button = "left"
    click_count = 1
  }
  Start-Sleep -Milliseconds ([Math]::Max(180, $script:HoldMs))
  [pscustomobject]@{
    name = $Name
    x = $x
    y = $y
    move = $move
    click = $click
    target = $Target
  }
}

function Get-CalculatorTargets {
  Invoke-Bridge -Command "dump-app-targets" -Payload @{
    app = "calculator"
    depth = 10
    maxTargets = 300
    includeOffscreen = $false
    timeoutMs = 8000
  }
}

if ($env:OS -ne "Windows_NT") {
  throw "This calculator test must be run on Windows."
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

try { Invoke-Bridge -Command "hide-fake-cursor" | Out-Null } catch {}

Start-Process "calculator:" | Out-Null
Start-Sleep -Milliseconds 1200

$setup = Invoke-Bridge -Command "setup-check"
$initialState = Invoke-Bridge -Command "get-app-state" -Payload @{
  app = "calculator"
  includeCursor = $true
  depth = 6
  maxActionableElements = 120
  timeoutMs = 8000
}
if ($initialState.status -ne "found") {
  throw "Calculator did not open."
}

$initialScreenshot = Save-DesktopScreenshot (Join-Path $OutDir "calculator-opened.png")

$targetsResponse = Get-CalculatorTargets
if ($targetsResponse.status -ne "found") {
  throw "Calculator targets unavailable."
}

$targets = @($targetsResponse.targets)
$clear = $null
try {
  $clear = Find-Target $targets "clear" @("clearButton", "clearEntryButton") @("^Clear$", "Clear entry")
} catch {}
$two = Find-Target $targets "two" @("num2Button") @("^Two$", "^2$")
$plus = Find-Target $targets "plus" @("plusButton") @("^Plus$", "\+")
$equals = Find-Target $targets "equals" @("equalButton") @("^Equals$", "=")

$steps = @()
if ($null -ne $clear) {
  $steps += Move-And-Click $clear "clear" (Join-Path $OutDir "cursor-clear.png")
  $targetsResponse = Get-CalculatorTargets
  $targets = @($targetsResponse.targets)
  $two = Find-Target $targets "two" @("num2Button") @("^Two$", "^2$")
  $plus = Find-Target $targets "plus" @("plusButton") @("^Plus$", "\+")
  $equals = Find-Target $targets "equals" @("equalButton") @("^Equals$", "=")
}

$steps += Move-And-Click $two "two-first" (Join-Path $OutDir "cursor-two-first.png")
$steps += Move-And-Click $plus "plus" (Join-Path $OutDir "cursor-plus.png")
$steps += Move-And-Click $two "two-second" (Join-Path $OutDir "cursor-two-second.png")
$steps += Move-And-Click $equals "equals" (Join-Path $OutDir "cursor-equals.png")

Start-Sleep -Milliseconds 500

$resultState = Invoke-Bridge -Command "get-app-state" -Payload @{
  app = "calculator"
  includeCursor = $true
  depth = 8
  maxActionableElements = 200
  timeoutMs = 8000
}
$resultTargets = Get-CalculatorTargets
$resultScreenshot = Save-DesktopScreenshot (Join-Path $OutDir "calculator-result.png")

$displayCandidates = @($resultTargets.targets | Where-Object {
  "$($_.automationId)" -eq "CalculatorResults" -or
  "$($_.label)" -match "Display|Result|結果|Ergebnis|Resultado|Résultat"
})
$displayText = ($displayCandidates | ForEach-Object { "$($_.label) $($_.name)" } | Where-Object { $_.Trim() } | Select-Object -First 1)
if ([string]::IsNullOrWhiteSpace($displayText)) {
  $displayText = ($resultState.accessibilityTree | ConvertTo-Json -Depth 32)
}

$verified = "$displayText" -match "(^|[^0-9])4([^0-9]|$)"
$hidden = Invoke-Bridge -Command "hide-fake-cursor"

$report = [pscustomobject]@{
  status = if ($verified) { "ok" } else { "failed" }
  app = "calculator"
  expression = "2 + 2"
  expected = "4"
  setupStatus = $setup.status
  setupChecks = $setup.checks
  window = $initialState.window
  initialScreenshot = $initialScreenshot
  resultScreenshot = $resultScreenshot
  targetCount = $targetsResponse.targetCount
  steps = $steps
  resultDisplay = $displayText
  resultVerified = $verified
  fakeCursorHidden = $hidden
}

$reportPath = Join-Path $OutDir "visual-report.json"
$report | ConvertTo-Json -Depth 32 | Set-Content -Path $reportPath -Encoding UTF8
$report | ConvertTo-Json -Depth 32

if (!$verified) {
  throw "Calculator result was not verified as 4. Display: $displayText"
}
