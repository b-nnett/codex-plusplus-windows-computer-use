param(
  [string]$OutDir = "$env:TEMP\wcu-persistent-bridge-test"
)

$ErrorActionPreference = "Stop"

$RootDir = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$Server = Join-Path $RootDir "mcp-server.js"

if ($env:OS -ne "Windows_NT") {
  throw "This test must be run on Windows."
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = "node.exe"
$psi.Arguments = "`"$Server`""
$psi.WorkingDirectory = $RootDir
$psi.UseShellExecute = $false
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true

$proc = New-Object System.Diagnostics.Process
$proc.StartInfo = $psi
$proc.Start() | Out-Null

$nextId = 1
function Invoke-Mcp {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Method,

    [hashtable]$Params = @{}
  )

  $script:nextId += 1
  $request = @{
    jsonrpc = "2.0"
    id = $script:nextId
    method = $Method
    params = $Params
  }
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $proc.StandardInput.WriteLine(($request | ConvertTo-Json -Depth 16 -Compress))
  $line = $proc.StandardOutput.ReadLine()
  $sw.Stop()
  if (!$line) { throw "MCP server closed stdout." }
  $message = $line | ConvertFrom-Json
  if ($message.error) { throw $message.error.message }
  return [pscustomobject]@{
    elapsedMs = [int]$sw.ElapsedMilliseconds
    result = $message.result
  }
}

try {
  Invoke-Mcp -Method "initialize" -Params @{
    protocolVersion = "2024-11-05"
    capabilities = @{}
    clientInfo = @{ name = "windows-persistent-bridge-test"; version = "0.0.0" }
  } | Out-Null

  $starting = Invoke-Mcp -Method "tools/call" -Params @{
    name = "start_computer_use"
    arguments = @{ reason = "persistent bridge smoke" }
  }
  $apps1 = Invoke-Mcp -Method "tools/call" -Params @{
    name = "list_apps"
    arguments = @{}
  }
  $apps2 = Invoke-Mcp -Method "tools/call" -Params @{
    name = "list_apps"
    arguments = @{}
  }
  $status1 = Invoke-Mcp -Method "tools/call" -Params @{
    name = "windows_computer_use_status"
    arguments = @{}
  }
  $appsDetailed = Invoke-Mcp -Method "tools/call" -Params @{
    name = "list_apps"
    arguments = @{ detailed = $true }
  }
  $status2 = Invoke-Mcp -Method "tools/call" -Params @{
    name = "windows_computer_use_status"
    arguments = @{}
  }

  $status1Raw = $status1.result.content[0].text | ConvertFrom-Json
  $status2Raw = $status2.result.content[0].text | ConvertFrom-Json
  $verified = (
    $status1Raw.bridge.persistent -eq $true -and
    $status2Raw.bridge.persistent -eq $true -and
    $status1Raw.bridge.fakeCursorOverlayAlive -ne $null -and
    $starting.result.content[0].text -match "Starting Computer Use" -and
    $apps1.result.content[0].text -match "Visible apps" -and
    $apps2.result.content[0].text -match "Visible apps" -and
    $apps2.result._meta.raw.scan.fast -eq $true -and
    $appsDetailed.result._meta.raw.apps[0].display.icon.path
  )

  $report = [pscustomobject]@{
    status = if ($verified) { "ok" } else { "failed" }
    verified = $verified
    timingsMs = [pscustomobject]@{
      startComputerUse = $starting.elapsedMs
      listAppsCold = $apps1.elapsedMs
      listAppsSecond = $apps2.elapsedMs
      statusCold = $status1.elapsedMs
      listAppsDetailed = $appsDetailed.elapsedMs
      statusWarm = $status2.elapsedMs
    }
    bridge = [pscustomobject]@{
      firstPersistent = $status1Raw.bridge.persistent
      secondPersistent = $status2Raw.bridge.persistent
      bridgePid = $status2Raw.bridge.pid
    }
    appsPreview = (($apps2.result.content[0].text -split "`n") | Select-Object -First 6) -join "`n"
  }
  $report | ConvertTo-Json -Depth 32 | Set-Content -Path (Join-Path $OutDir "visual-report.json") -Encoding UTF8
  $report | ConvertTo-Json -Depth 32

  if (!$verified) {
    throw "Persistent bridge was not verified."
  }
} finally {
  if (!$proc.HasExited) {
    $proc.Kill()
  }
}
