param(
  [string]$OutDir = "$env:TEMP\wcu-mcp-key-presentation-test"
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
  $proc.StandardInput.WriteLine(($request | ConvertTo-Json -Depth 16 -Compress))
  $line = $proc.StandardOutput.ReadLine()
  if (!$line) { throw "MCP server closed stdout." }
  $message = $line | ConvertFrom-Json
  if ($message.error) { throw $message.error.message }
  return $message.result
}

try {
  Invoke-Mcp -Method "initialize" -Params @{
    protocolVersion = "2024-11-05"
    capabilities = @{}
    clientInfo = @{ name = "windows-mcp-presentation-test"; version = "0.0.0" }
  } | Out-Null

  Start-Process notepad.exe | Out-Null
  Start-Sleep -Milliseconds 900

  $apps = Invoke-Mcp -Method "tools/call" -Params @{
    name = "list_apps"
    arguments = @{}
  }
  $state = Invoke-Mcp -Method "tools/call" -Params @{
    name = "get_app_state"
    arguments = @{
      app = "notepad"
      depth = 4
      maxActionableElements = 40
    }
  }
  $move = Invoke-Mcp -Method "tools/call" -Params @{
    name = "move_cursor"
    arguments = @{
      app = "notepad"
      x = 50
      y = 120
      coordinateSpace = "window"
    }
  }
  $click = Invoke-Mcp -Method "tools/call" -Params @{
    name = "click"
    arguments = @{
      app = "notepad"
      x = 50
      y = 120
      coordinateSpace = "window"
    }
  }

  $text = "wcu mcp presentation " + ([Guid]::NewGuid().ToString("n").Substring(0, 8))
  $typed = Invoke-Mcp -Method "tools/call" -Params @{
    name = "type_text"
    arguments = @{
      app = "notepad"
      text = $text
    }
  }
  $enter = Invoke-Mcp -Method "tools/call" -Params @{
    name = "press_key"
    arguments = @{
      app = "notepad"
      key = "ENTER"
    }
  }
  $hide = Invoke-Mcp -Method "tools/call" -Params @{
    name = "hide_fake_cursor"
    arguments = @{}
  }

  $appsText = $apps.content[0].text
  $stateText = $state.content[0].text
  $moveText = $move.content[0].text
  $clickText = $click.content[0].text
  $typedText = $typed.content[0].text
  $enterText = $enter.content[0].text
  $verified = (
    $appsText -match "Visible apps" -and
    $appsText -notmatch '^\s*\{' -and
    $stateText -match 'tree \(' -and
    $stateText -match "screenshot:" -and
    $stateText -notmatch '^\s*\{' -and
    $moveText -match "Moved cursor in" -and
    $moveText -match "Icon: " -and
    $move.structuredContent -eq $null -and
    $move._meta.presentation.summary -match "Moved cursor in" -and
    $move._meta.raw.movedRealCursor -eq $false -and
    $clickText -match "Clicked in" -and
    $clickText -match "Icon: " -and
    $click.structuredContent -eq $null -and
    $click._meta.presentation.summary -match "Clicked in" -and
    $click._meta.raw.movedRealCursor -eq $false -and
    $typedText -match "Typed text" -and
    $typedText -match "App: " -and
    $typedText -match "Icon: " -and
    $typedText -notmatch '^\s*\{' -and
    $typed.structuredContent -eq $null -and
    $typed._meta.presentation.summary -match "Typed text" -and
    $typed._meta.raw.focus.verifiedBeforeSend -eq $true -and
    $enterText -match "Pressed key" -and
    $enterText -match "Focus verified before send" -and
    $enterText -notmatch '^\s*\{' -and
    $enter.structuredContent -eq $null -and
    $enter._meta.presentation.summary -match "Pressed key" -and
    $enter._meta.raw.focus.verifiedBeforeSend -eq $true -and
    @($hide.content).Count -eq 0 -and
    $hide.structuredContent -eq $null -and
    $hide._meta.raw.stopped -eq $true
  )

  $report = [pscustomobject]@{
    status = if ($verified) { "ok" } else { "failed" }
    verified = $verified
    appsText = $appsText
    stateTextPreview = ($stateText -split "`n" | Select-Object -First 14) -join "`n"
    moveText = $moveText
    clickText = $clickText
    typedText = $typedText
    enterText = $enterText
    hideContentCount = @($hide.content).Count
    moveMeta = $move._meta
    clickMeta = $click._meta
    typedMeta = $typed._meta
    enterMeta = $enter._meta
  }
  $report | ConvertTo-Json -Depth 32 | Set-Content -Path (Join-Path $OutDir "visual-report.json") -Encoding UTF8
  $report | ConvertTo-Json -Depth 32

  if (!$verified) {
    throw "MCP key presentation was not verified."
  }
} finally {
  if (!$proc.HasExited) {
    $proc.Kill()
  }
}
