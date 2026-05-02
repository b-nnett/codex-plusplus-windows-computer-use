param(
  [string]$App = "edge",
  [string]$OutDir = "$env:TEMP\wcu-compact-state-test"
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
  throw "This test must be run on Windows."
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$state = Invoke-Bridge -Command "get-app-state" -Payload @{
  app = $App
  includeCursor = $false
  depth = 6
  maxActionableElements = 80
  maxTreeLines = 80
  timeoutMs = 8000
}

if ($state.status -ne "found") {
  throw "App not found for compact state test: $App"
}

$rawState = Invoke-Bridge -Command "get-app-state" -Payload @{
  app = $App
  includeCursor = $false
  depth = 3
  maxActionableElements = 20
  maxTreeLines = 20
  includeRawAccessibilityTree = $true
  timeoutMs = 8000
}

$targets = @($state.actionableElements)
$treeLines = @($state.accessibilityTree)
$verified = (
  $state.scan.treeFormat -eq "compact-lines" -and
  $treeLines.Count -gt 0 -and
  ($treeLines[0] -is [string]) -and
  $targets.Count -gt 0 -and
  $null -ne $targets[0].i -and
  $null -ne $targets[0].screen -and
  $null -ne $targets[0].window -and
  $null -ne $rawState.rawAccessibilityTree -and
  $null -eq $state.appDisplay.icon.PSObject.Properties["dataUri"]
)

$report = [pscustomobject]@{
  status = if ($verified) { "ok" } else { "failed" }
  app = $App
  appDisplay = $state.appDisplay
  treeFormat = $state.scan.treeFormat
  treeLineCount = $treeLines.Count
  treePreview = @($treeLines | Select-Object -First 12)
  targetCount = $targets.Count
  targetPreview = @($targets | Select-Object -First 8)
  rawTreeOptInWorked = $null -ne $rawState.rawAccessibilityTree
  iconDataUriOmitted = $null -eq $state.appDisplay.icon.PSObject.Properties["dataUri"]
  verified = $verified
}

$reportPath = Join-Path $OutDir "visual-report.json"
$report | ConvertTo-Json -Depth 32 | Set-Content -Path $reportPath -Encoding UTF8
$report | ConvertTo-Json -Depth 32

if (!$verified) {
  throw "Compact state format was not verified."
}
