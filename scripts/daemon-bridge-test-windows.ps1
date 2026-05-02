param(
  [string]$OutDir = "$env:TEMP\wcu-daemon-bridge-test",
  [int]$WarmupSeconds = 10
)

$ErrorActionPreference = "Stop"

$RootDir = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$Server = Join-Path $RootDir "mcp-server.js"
$Daemon = Join-Path $RootDir "scripts\bridge-daemon.js"
$PipeName = "\\.\pipe\codex-plusplus-wcu-test-$PID"
$env:WINDOWS_COMPUTER_USE_BRIDGE_PIPE = $PipeName

if ($env:OS -ne "Windows_NT") {
  throw "This test must be run on Windows."
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

function Start-McpServer {
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
  return $proc
}

$nextId = 1
function Invoke-Mcp {
  param(
    [Parameter(Mandatory = $true)]
    [System.Diagnostics.Process]$Proc,

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
  $Proc.StandardInput.WriteLine(($request | ConvertTo-Json -Depth 16 -Compress))
  $line = $Proc.StandardOutput.ReadLine()
  $sw.Stop()
  if (!$line) { throw "MCP server closed stdout." }
  $message = $line | ConvertFrom-Json
  if ($message.error) { throw $message.error.message }
  return [pscustomobject]@{
    elapsedMs = [int]$sw.ElapsedMilliseconds
    result = $message.result
  }
}

$daemonProcess = Start-Process node.exe -ArgumentList "`"$Daemon`"" -WorkingDirectory $RootDir -WindowStyle Hidden -PassThru
$mcp = $null
try {
  Start-Sleep -Seconds $WarmupSeconds
  $mcp = Start-McpServer

  Invoke-Mcp -Proc $mcp -Method "initialize" -Params @{
    protocolVersion = "2024-11-05"
    capabilities = @{}
    clientInfo = @{ name = "windows-daemon-bridge-test"; version = "0.0.0" }
  } | Out-Null

  $starting = Invoke-Mcp -Proc $mcp -Method "tools/call" -Params @{
    name = "start_computer_use"
    arguments = @{ reason = "daemon bridge smoke" }
  }
  $status1 = Invoke-Mcp -Proc $mcp -Method "tools/call" -Params @{
    name = "windows_computer_use_status"
    arguments = @{}
  }
  $status2 = Invoke-Mcp -Proc $mcp -Method "tools/call" -Params @{
    name = "windows_computer_use_status"
    arguments = @{}
  }

  $status1Raw = $status1.result.content[0].text | ConvertFrom-Json
  $status2Raw = $status2.result.content[0].text | ConvertFrom-Json
  $verified = (
    $starting.result.content[0].text -match "Starting Computer Use" -and
    $status1Raw.bridge.persistent -eq $true -and
    $status2Raw.bridge.persistent -eq $true -and
    $status1.elapsedMs -lt 5000
  )

  $report = [pscustomobject]@{
    status = if ($verified) { "ok" } else { "failed" }
    verified = $verified
    daemonPid = $daemonProcess.Id
    daemonWarmupSeconds = $WarmupSeconds
    pipeName = $PipeName
    timingsMs = [pscustomobject]@{
      startComputerUse = $starting.elapsedMs
      statusAfterDaemonWarmup = $status1.elapsedMs
      statusSecond = $status2.elapsedMs
    }
    bridge = [pscustomobject]@{
      firstPersistent = $status1Raw.bridge.persistent
      secondPersistent = $status2Raw.bridge.persistent
      bridgePid = $status2Raw.bridge.pid
    }
  }
  $report | ConvertTo-Json -Depth 32 | Set-Content -Path (Join-Path $OutDir "visual-report.json") -Encoding UTF8
  $report | ConvertTo-Json -Depth 32

  if (!$verified) {
    throw "Daemon bridge was not verified."
  }
} finally {
  if ($mcp -and !$mcp.HasExited) {
    $mcp.Kill()
  }
  if ($daemonProcess -and !$daemonProcess.HasExited) {
    Stop-Process -Id $daemonProcess.Id -Force
  }
}
