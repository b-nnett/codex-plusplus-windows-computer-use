param(
  [switch]$Json
)

$ErrorActionPreference = "Stop"

$RootDir = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$Bridge = Join-Path $RootDir "scripts\windows-bridge.ps1"

if ($env:OS -ne "Windows_NT") {
  throw "Windows Computer Use setup checks must be run on Windows."
}

$payloadBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("{}"))
try {
  $env:WCU_PAYLOAD_BASE64 = $payloadBase64
  $result = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Bridge -Command setup-check | ConvertFrom-Json
} finally {
  Remove-Item Env:WCU_PAYLOAD_BASE64 -ErrorAction SilentlyContinue
}

if ($Json) {
  $result | ConvertTo-Json -Depth 16
  exit 0
}

Write-Host "Windows Computer Use setup: $($result.status)"
Write-Host "PowerShell: $($result.powershellVersion)"
Write-Host "Elevated: $($result.isElevated)"
Write-Host "State dir: $($result.stateDir)"
Write-Host ""
Write-Host "Checks:"

foreach ($check in $result.checks) {
  $mark = if ($check.ok) { "OK" } else { "FAIL" }
  Write-Host ("  [{0}] {1} ({2})" -f $mark, $check.name, $check.severity)
  if (!$check.ok -and $check.detail) {
    Write-Host ("       {0}" -f ($check.detail | ConvertTo-Json -Depth 4 -Compress))
  }
}

Write-Host ""
Write-Host "Notes:"
foreach ($item in $result.recommendations) {
  Write-Host "  - $item"
}

if ($result.status -ne "ready") {
  exit 1
}
