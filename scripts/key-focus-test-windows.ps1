param(
  [string]$OutDir = "$env:TEMP\wcu-key-focus-test"
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

Start-Process notepad.exe | Out-Null
Start-Sleep -Milliseconds 900

$text = "wcu focus smoke " + ([Guid]::NewGuid().ToString("n").Substring(0, 8))
$typed = Invoke-Bridge -Command "type-text" -Payload @{
  app = "notepad"
  text = $text
}
$enter = Invoke-Bridge -Command "press-key" -Payload @{
  app = "notepad"
  key = "ENTER"
}
$state = Invoke-Bridge -Command "get-app-state" -Payload @{
  app = "notepad"
  includeCursor = $false
  depth = 4
  maxActionableElements = 40
  timeoutMs = 8000
}

$verified = (
  $typed.status -eq "ok" -and
  $typed.focus.verifiedBeforeSend -eq $true -and
  $typed.focus.foregroundBeforeSend.pid -eq $typed.focus.targetPid -and
  $typed.presentation.appName -and
  $typed.presentation.iconPath -and
  $typed.presentation.summary -match "Typed text" -and
  $typed.textPreview -match "wcu focus smoke" -and
  $enter.status -eq "ok" -and
  $enter.focus.verifiedBeforeSend -eq $true -and
  $enter.focus.foregroundBeforeSend.pid -eq $enter.focus.targetPid -and
  $enter.presentation.summary -match "Pressed key" -and
  $state.scan.treeFormat -eq "compact-lines"
)

$report = [pscustomobject]@{
  status = if ($verified) { "ok" } else { "failed" }
  typed = $typed
  enter = $enter
  statePreview = [pscustomobject]@{
    appDisplay = $state.appDisplay
    treeFormat = $state.scan.treeFormat
    treePreview = @($state.accessibilityTree | Select-Object -First 8)
    targetPreview = @($state.actionableElements | Select-Object -First 8)
  }
  verified = $verified
}

$reportPath = Join-Path $OutDir "visual-report.json"
$report | ConvertTo-Json -Depth 32 | Set-Content -Path $reportPath -Encoding UTF8
$report | ConvertTo-Json -Depth 32

if (!$verified) {
  throw "Key focus validation was not verified."
}
