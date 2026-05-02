param(
  [string]$OutDir = "$env:TEMP\wcu-browser-target-dump-test"
)

$ErrorActionPreference = "Stop"

$RootDir = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$Bridge = Join-Path $RootDir "scripts\windows-bridge.ps1"

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

Start-Process msedge.exe "https://example.com"
Start-Sleep -Seconds 3

$payload = @{
  app = "msedge"
  maxTargets = 80
  depth = 6
} | ConvertTo-Json -Compress

$raw = & $Bridge -Command dump-app-targets -Payload $payload
$dump = $raw | ConvertFrom-Json
$compact = @($dump.targets)
$addressBar = @($compact | Where-Object { $_.i -eq "synthetic:browser-address-bar" } | Select-Object -First 1)
$rawViewTargets = @($compact | Where-Object { "$($_.meta)" -match "source=raw-view" })

$verified = (
  $dump.status -eq "found" -and
  $addressBar.Count -eq 1 -and
  $addressBar[0].tool -eq "set_value" -and
  $rawViewTargets.Count -gt 0
)

$report = [pscustomobject]@{
  status = if ($verified) { "ok" } else { "failed" }
  verified = $verified
  targetCount = $dump.targetCount
  rawViewTargetCount = $dump.scan.rawViewTargetCount
  syntheticTargetCount = $dump.scan.syntheticTargetCount
  addressBar = if ($addressBar.Count -gt 0) { $addressBar[0] } else { $null }
  preview = (($compact | Select-Object -First 12 | ForEach-Object { "$($_.i) $($_.role) $($_.label) $($_.rect -join ',') $($_.meta)" }) -join "`n")
}

$report | ConvertTo-Json -Depth 32 | Set-Content -Path (Join-Path $OutDir "visual-report.json") -Encoding UTF8
$report | ConvertTo-Json -Depth 32

if (!$verified) {
  throw "Browser target dump did not include expected synthetic/raw targets."
}
