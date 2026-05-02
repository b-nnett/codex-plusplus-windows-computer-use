param(
  [string]$App = "notepad",
  [switch]$SkipLaunch
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

if ($env:OS -ne "Windows_NT") {
  throw "This smoke test must be run on Windows."
}

if (!$SkipLaunch -and $App -eq "notepad") {
  $existing = Get-Process -Name notepad -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
  if ($null -eq $existing) {
    Start-Process notepad.exe | Out-Null
    Start-Sleep -Milliseconds 700
  }
}

Write-Host "== status =="
Invoke-Bridge -Command "status" | ConvertTo-Json -Depth 8

Write-Host "`n== visible apps =="
$apps = Invoke-Bridge -Command "list-apps"
$apps.apps | Select-Object -First 12 name, pid, title, handle | Format-Table -AutoSize

Write-Host "`n== get app state =="
$state = Invoke-Bridge -Command "get-app-state" -Payload @{
  app = $App
  includeCursor = $true
  depth = 5
  maxActionableElements = 80
}
$state | Select-Object app, status, elementCount | ConvertTo-Json -Depth 4
$state.window | ConvertTo-Json -Depth 6
$state.screenshot | ConvertTo-Json -Depth 6

Write-Host "`n== actionable elements from get_app_state =="
$state.actionableElements |
  Select-Object -First 30 index, label, controlType, recommendedTool, actions, screenCenter, windowCenter |
  Format-Table -AutoSize

Write-Host "`n== dump app targets =="
$targets = Invoke-Bridge -Command "dump-app-targets" -Payload @{
  app = $App
  depth = 7
  maxTargets = 120
}
$targets | Select-Object app, status, targetCount, elementCount | ConvertTo-Json -Depth 4
$targets.targets |
  Select-Object -First 40 index, label, controlType, recommendedTool, actions, screenCenter, windowCenter |
  Format-Table -AutoSize

Write-Host "`n== layered fake cursor =="
$rect = $state.window.rect
$x = [int]($rect.x + [Math]::Min(160, [Math]::Max(40, $rect.width / 2)))
$y = [int]($rect.y + [Math]::Min(120, [Math]::Max(40, $rect.height / 2)))
Invoke-Bridge -Command "show-fake-cursor" -Payload @{ x = $x; y = $y; style = "software" } | ConvertTo-Json -Depth 6
Start-Sleep -Milliseconds 500
Invoke-Bridge -Command "move-cursor" -Payload @{ x = ($x + 80); y = ($y + 40); showFakeCursor = $true; style = "software"; isPressed = $true } | ConvertTo-Json -Depth 6
Start-Sleep -Milliseconds 500
Invoke-Bridge -Command "hide-fake-cursor" | ConvertTo-Json -Depth 6

Write-Host "`nSmoke test complete."
