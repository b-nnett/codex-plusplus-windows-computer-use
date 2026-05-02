param(
  [string]$OutDir = "$env:TEMP\wcu-target-border-visual-test",
  [int]$MaxTargets = 80
)

$ErrorActionPreference = "Stop"

$RootDir = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$Bridge = Join-Path $RootDir "scripts\windows-bridge.ps1"

Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class TargetBorderVisualWin32 {
  [DllImport("user32.dll")]
  public static extern bool SetForegroundWindow(IntPtr hWnd);

  [DllImport("user32.dll")]
  public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
"@ -ErrorAction SilentlyContinue

function Invoke-Bridge {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Command,

    [hashtable]$Payload = @{}
  )

  $json = $Payload | ConvertTo-Json -Depth 24 -Compress
  $payloadBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json))
  try {
    $env:WCU_PAYLOAD_BASE64 = $payloadBase64
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Bridge -Command $Command |
      ConvertFrom-Json
  } finally {
    Remove-Item Env:WCU_PAYLOAD_BASE64 -ErrorAction SilentlyContinue
  }
}

function Stop-StaleFakeCursorOverlay {
  try {
    $statePath = Join-Path $env:LOCALAPPDATA "codex-plusplus\windows-computer-use\state.json"
    if (Test-Path $statePath) {
      $state = Get-Content $statePath -Raw | ConvertFrom-Json
      $pid = $state.cursor.overlayPid
      if ($pid) { Stop-Process -Id ([int]$pid) -Force -ErrorAction SilentlyContinue }
    }
  } catch {}
  try {
    Get-CimInstance Win32_Process |
      Where-Object { "$($_.CommandLine)" -match "fake-cursor-overlay\.ps1" } |
      ForEach-Object {
        try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {}
      }
  } catch {}
}

function Focus-TestAppWindow {
  param(
    [Parameter(Mandatory = $true)]
    [string]$App
  )

  $needle = $App.ToLowerInvariant()
  $proc = Get-Process |
    Where-Object {
      $_.MainWindowHandle -ne 0 -and
      ($_.ProcessName.ToLowerInvariant().Contains($needle) -or "$($_.MainWindowTitle)".ToLowerInvariant().Contains($needle))
    } |
    Select-Object -First 1
  if ($null -ne $proc) {
    [TargetBorderVisualWin32]::ShowWindow($proc.MainWindowHandle, 9) | Out-Null
    [TargetBorderVisualWin32]::SetForegroundWindow($proc.MainWindowHandle) | Out-Null
    Start-Sleep -Milliseconds 700
  }
}

function Start-TestApp {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Kind
  )

  switch ($Kind) {
    "explorer" {
      $folder = $env:USERPROFILE
      Start-Process explorer.exe $folder | Out-Null
      Start-Sleep -Seconds 2
      return (Split-Path -Leaf $folder)
    }
    "calculator" {
      Start-Process "calculator:" | Out-Null
      Start-Sleep -Seconds 2
      return "calculator"
    }
    "edge" {
      Start-Process msedge.exe "https://example.com" | Out-Null
      Start-Sleep -Seconds 3
      return "msedge"
    }
    default {
      throw "Unknown app kind: $Kind"
    }
  }
}

function Get-TargetColor {
  param($Target)

  $meta = "$($Target.meta)"
  if ($meta -match "source=synthetic") {
    return [System.Drawing.Color]::FromArgb(238, 71, 255)
  }
  if ($meta -match "source=raw-view") {
    return [System.Drawing.Color]::FromArgb(0, 190, 255)
  }
  return [System.Drawing.Color]::FromArgb(68, 230, 120)
}

function Get-TargetStroke {
  param($Target)

  $meta = "$($Target.meta)"
  if ($meta -match "source=synthetic") { return 4 }
  if ($meta -match "source=raw-view") { return 2 }
  return 2
}

function New-ShortLabel {
  param($Target)

  $index = "$($Target.i)"
  if ($index -eq "synthetic:browser-address-bar") { return "addr" }
  if ($index -eq "synthetic:browser-page") { return "page" }
  if ($index.StartsWith("raw:")) {
    return "r" + $index.Substring(4)
  }
  return $index
}

function Draw-TargetOverlay {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ScreenshotPath,

    [Parameter(Mandatory = $true)]
    [array]$Targets,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath
  )

  $source = [System.Drawing.Image]::FromFile($ScreenshotPath)
  $bitmap = New-Object System.Drawing.Bitmap -ArgumentList $source.Width, $source.Height
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
  $font = New-Object System.Drawing.Font -ArgumentList "Segoe UI", 8, ([System.Drawing.FontStyle]::Bold)

  try {
    $graphics.DrawImage($source, 0, 0, $source.Width, $source.Height)
    foreach ($target in @($Targets | Select-Object -First $MaxTargets)) {
      if ($null -eq $target.rect -or $target.rect.Count -lt 4) { continue }
      $x = [int]$target.rect[0]
      $y = [int]$target.rect[1]
      $w = [int]$target.rect[2]
      $h = [int]$target.rect[3]
      if ($w -le 3 -or $h -le 3) { continue }
      if ($x -gt $source.Width -or $y -gt $source.Height) { continue }
      if ($x + $w -lt 0 -or $y + $h -lt 0) { continue }

      $color = Get-TargetColor $target
      $stroke = Get-TargetStroke $target
      $pen = New-Object System.Drawing.Pen -ArgumentList $color, $stroke
      $brush = New-Object System.Drawing.SolidBrush -ArgumentList ([System.Drawing.Color]::FromArgb(230, $color.R, $color.G, $color.B))
      $textBrush = New-Object System.Drawing.SolidBrush -ArgumentList ([System.Drawing.Color]::FromArgb(255, 8, 8, 10))
      try {
        $graphics.DrawRectangle($pen, $x, $y, ([Math]::Max(1, $w)), ([Math]::Max(1, $h)))
        $label = New-ShortLabel $target
        $size = $graphics.MeasureString($label, $font)
        $labelX = [Math]::Max(0, [Math]::Min($x, $source.Width - [int]$size.Width - 6))
        $labelY = [Math]::Max(0, $y - [int]$size.Height - 4)
        if ($labelY -lt 2) { $labelY = [Math]::Min($source.Height - [int]$size.Height - 4, $y + 2) }
        $graphics.FillRectangle($brush, $labelX, $labelY, ([int]$size.Width + 6), ([int]$size.Height + 3))
        $graphics.DrawString($label, $font, $textBrush, ($labelX + 3), ($labelY + 1))
      } finally {
        $pen.Dispose()
        $brush.Dispose()
        $textBrush.Dispose()
      }
    }
    $bitmap.Save($OutputPath, [System.Drawing.Imaging.ImageFormat]::Png)
  } finally {
    $font.Dispose()
    $graphics.Dispose()
    $bitmap.Dispose()
    $source.Dispose()
  }

  return $OutputPath
}

function Capture-AnnotatedApp {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Kind
  )

  $app = Start-TestApp $Kind
  try { Invoke-Bridge -Command "hide-fake-cursor" | Out-Null } catch {}
  Stop-StaleFakeCursorOverlay
  Start-Sleep -Milliseconds 500
  Focus-TestAppWindow $app
  $state = Invoke-Bridge -Command "get-app-state" -Payload @{
    app = $app
    depth = 8
    maxActionableElements = $MaxTargets
    maxTreeLines = 160
    timeoutMs = 8000
    includeCursor = $false
  }
  if ($state.status -ne "found") {
    throw "App not found for target border test: $Kind ($app)"
  }

  $targets = @($state.actionableElements)
  $annotatedPath = Join-Path $OutDir ("{0}-targets.png" -f $Kind)
  Draw-TargetOverlay -ScreenshotPath $state.screenshot.path -Targets $targets -OutputPath $annotatedPath | Out-Null
  if (!(Test-Path $annotatedPath)) {
    Copy-Item -LiteralPath $state.screenshot.path -Destination $annotatedPath -Force
  }

  $rawCount = @($targets | Where-Object { "$($_.meta)" -match "source=raw-view" }).Count
  $syntheticCount = @($targets | Where-Object { "$($_.meta)" -match "source=synthetic" }).Count
  $controlCount = [Math]::Max(0, $targets.Count - $rawCount - $syntheticCount)

  [pscustomobject]@{
    kind = $Kind
    app = $app
    status = $state.status
    windowTitle = $state.window.title
    screenshot = $state.screenshot.path
    annotated = $annotatedPath
    targetCount = $targets.Count
    controlViewTargets = $controlCount
    rawViewTargets = $rawCount
    syntheticTargets = $syntheticCount
    preview = @($targets | Select-Object -First 12)
  }
}

if ($env:OS -ne "Windows_NT") {
  throw "This target border visual test must be run on Windows."
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
try { Invoke-Bridge -Command "hide-fake-cursor" | Out-Null } catch {}
Stop-StaleFakeCursorOverlay

$apps = @("explorer", "calculator", "edge")
$results = @()
foreach ($app in $apps) {
  $results += Capture-AnnotatedApp $app
}

$verified = @($results | Where-Object { $_.status -eq "found" -and $_.targetCount -gt 0 }).Count -eq $apps.Count

$report = [pscustomobject]@{
  status = if ($verified) { "ok" } else { "failed" }
  verified = $verified
  outDir = $OutDir
  legend = [pscustomobject]@{
    controlView = "green"
    rawView = "cyan"
    synthetic = "magenta"
  }
  apps = $results
}

$report | ConvertTo-Json -Depth 32 | Set-Content -Path (Join-Path $OutDir "visual-report.json") -Encoding UTF8
$report | ConvertTo-Json -Depth 32

if (!$verified) {
  throw "Target border visual test failed."
}
