param(
  [string]$App = "edge",
  [string]$OutDir = "$env:TEMP\wcu-no-real-cursor-click-test"
)

$ErrorActionPreference = "Stop"

$RootDir = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$Bridge = Join-Path $RootDir "scripts\windows-bridge.ps1"

Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class NoRealCursorTestWin32 {
  [StructLayout(LayoutKind.Sequential)]
  public struct POINT {
    public int X;
    public int Y;
  }

  [DllImport("user32.dll")]
  public static extern bool GetCursorPos(out POINT lpPoint);
}
"@

function Get-CursorPoint {
  $point = New-Object NoRealCursorTestWin32+POINT
  [NoRealCursorTestWin32]::GetCursorPos([ref]$point) | Out-Null
  [pscustomobject]@{ x = [int]$point.X; y = [int]$point.Y }
}

function Get-TargetScreenCenter($Target) {
  if ($Target.screenCenter) {
    return [pscustomobject]@{ x = [int]$Target.screenCenter.x; y = [int]$Target.screenCenter.y }
  }
  if ($Target.screen -and $Target.screen.Count -ge 2) {
    return [pscustomobject]@{ x = [int]$Target.screen[0]; y = [int]$Target.screen[1] }
  }
  return $null
}

function Get-TargetIndex($Target) {
  if ($Target.i) { return "$($Target.i)" }
  return "$($Target.index)"
}

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

if ($env:OS -ne "Windows_NT") {
  throw "This test must be run on Windows."
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

try { Invoke-Bridge -Command "hide-fake-cursor" | Out-Null } catch {}

$state = Invoke-Bridge -Command "get-app-state" -Payload @{
  app = $App
  includeCursor = $true
  depth = 4
  maxActionableElements = 120
  timeoutMs = 8000
}
if ($state.status -ne "found") {
  throw "App not found for no-real-cursor click test: $App"
}

$targets = Invoke-Bridge -Command "dump-app-targets" -Payload @{
  app = $App
  depth = 8
  maxTargets = 250
  includeOffscreen = $false
  timeoutMs = 8000
}

$target = @(
  $targets.targets |
    Where-Object {
      (Get-TargetScreenCenter $_) -and
      (("$($_.label)" -match "Search|Address|検索|Suchen|Buscar|Rechercher") -or
       ("$($_.name)" -match "Search|Address|検索|Suchen|Buscar|Rechercher") -or
       ("$($_.automationId)" -match "search"))
    } |
    Select-Object -First 1
)

if ($target.Count -eq 0) {
  throw "No usable click target found in $App."
}

$scrollTarget = @(
  $targets.targets |
    Where-Object {
      (Get-TargetScreenCenter $_) -and $_.actions -and ($_.actions -contains "scroll")
    } |
    Select-Object -First 1
)
if ($scrollTarget.Count -eq 0) {
  $scrollTarget = $target
}

$before = Get-CursorPoint
$clickCenter = Get-TargetScreenCenter $target[0]
$scrollCenter = Get-TargetScreenCenter $scrollTarget[0]
$click = Invoke-Bridge -Command "click" -Payload @{
  app = $App
  x = [int]$clickCenter.x
  y = [int]$clickCenter.y
  coordinateSpace = "screen"
  showFakeCursor = $true
}
Start-Sleep -Milliseconds 250
$scroll = Invoke-Bridge -Command "scroll" -Payload @{
  app = $App
  element_index = (Get-TargetIndex $scrollTarget[0])
  direction = "down"
  pages = 0.25
  showFakeCursor = $true
}
Start-Sleep -Milliseconds 250
$drag = Invoke-Bridge -Command "drag" -Payload @{
  app = $App
  from_x = [int]$scrollCenter.x
  from_y = [int]$scrollCenter.y
  to_x = ([int]$scrollCenter.x + 24)
  to_y = ([int]$scrollCenter.y + 16)
  showFakeCursor = $true
}
Start-Sleep -Milliseconds 250
$after = Get-CursorPoint
$hidden = Invoke-Bridge -Command "hide-fake-cursor"

$unchanged = ([int]$before.x -eq [int]$after.x) -and ([int]$before.y -eq [int]$after.y)
$verified = (
  $unchanged -and
  ([bool]$click.fakeCursorVisible) -and
  ([bool]$scroll.fakeCursorVisible) -and
  ([bool]$drag.fakeCursorVisible) -and
  ($click.style -eq "software" -or $click.PSObject.Properties["style"] -eq $null) -and
  ($scroll.style -eq "software" -or $scroll.PSObject.Properties["style"] -eq $null) -and
  ($drag.style -eq "software" -or $drag.PSObject.Properties["style"] -eq $null) -and
  ($click.movedRealCursor -eq $false) -and
  ($scroll.movedRealCursor -eq $false) -and
  ($drag.movedRealCursor -eq $false)
)

$report = [pscustomobject]@{
  status = if ($verified) { "ok" } else { "failed" }
  app = $App
  target = $target[0]
  scrollTarget = $scrollTarget[0]
  beforeCursor = $before
  afterCursor = $after
  cursorUnchanged = $unchanged
  click = $click
  scroll = $scroll
  drag = $drag
  fakeCursorHidden = $hidden
  verified = $verified
}

$reportPath = Join-Path $OutDir "visual-report.json"
$report | ConvertTo-Json -Depth 32 | Set-Content -Path $reportPath -Encoding UTF8
$report | ConvertTo-Json -Depth 32

if (!$verified) {
  throw "Real cursor moved or fake cursor/click result was not verified."
}
