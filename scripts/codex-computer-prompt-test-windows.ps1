param(
  [string]$OutDir = "$env:TEMP\wcu-codex-computer-test",
  [string]$Prompt = "@computer open Calculator and compute 2 + 2 using visible mouse/cursor movement only. For Calculator input, do not use press_key, type_text, keyboard shortcuts, or direct text entry. Use get_app_state or dump_app_targets to find the on-screen Calculator buttons, keep the fake/software cursor visible, move_cursor to each button, and click the visible 2, +, 2, and = buttons. Take screenshots during the flow and confirm the visible result is 4.",
  [int]$TimeoutSeconds = 180
)

$ErrorActionPreference = "Stop"

$RootDir = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$Bridge = Join-Path $RootDir "scripts\windows-bridge.ps1"

function Invoke-Bridge {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Command,
    [object]$Payload = @{}
  )

  $json = $Payload | ConvertTo-Json -Depth 20 -Compress
  $payloadBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json))
  $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Bridge -Command $Command -PayloadBase64 $payloadBase64
  $text = ($output | Out-String).Trim()
  if ([string]::IsNullOrWhiteSpace($text)) { return $null }
  try {
    return $text | ConvertFrom-Json
  } catch {
    $start = $text.IndexOf("{")
    $end = $text.LastIndexOf("}")
    if ($start -ge 0 -and $end -gt $start) {
      return $text.Substring($start, $end - $start + 1) | ConvertFrom-Json
    }
    throw
  }
}

function Save-DesktopScreenshot {
  param([string]$Path)
  Add-Type -AssemblyName System.Drawing
  Add-Type -AssemblyName System.Windows.Forms
  $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
  $bitmap = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  try {
    $graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
    $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
  } finally {
    $graphics.Dispose()
    $bitmap.Dispose()
  }
  [pscustomobject]@{ path = $Path; width = $bounds.Width; height = $bounds.Height }
}

function Find-CodexExe {
  $appsRoot = Join-Path $env:LOCALAPPDATA "codex-plusplus\store-apps"
  $candidate = Get-ChildItem -Path $appsRoot -Recurse -Filter Codex.exe -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
  if ($null -eq $candidate) { throw "Codex.exe not found under $appsRoot" }
  return $candidate.FullName
}

function Wait-AppState {
  param([string]$App, [int]$TimeoutMs = 30000)
  $state = Invoke-Bridge -Command "get-app-state" -Payload @{
    app = $App
    includeCursor = $true
    depth = 8
    maxActionableElements = 300
    timeoutMs = $TimeoutMs
  }
  if ($state.status -ne "found") { throw "$App window not found" }
  return $state
}

function Find-ComposerTarget {
  param($State)
  $targets = @($State.actionableElements)
  $composer = @(
    $targets |
      Where-Object {
        $_.screenCenter -and
        ($_.controlType -in @("Edit", "Document") -or "$($_.label)" -match "Ask|Message|Prompt|chat|composer|input")
      } |
      Sort-Object @{ Expression = { [double]$_.screenCenter.y }; Descending = $true }
  ) | Select-Object -First 1
  if ($null -ne $composer) { return $composer }

  $rect = $State.window.rect
  return [pscustomobject]@{
    index = $null
    label = "fallback-composer-coordinate"
    screenCenter = [pscustomobject]@{
      x = [int]($rect.x + ($rect.width / 2))
      y = [int]($rect.y + $rect.height - 72)
    }
  }
}

function Get-CalculatorResultText {
  $state = Invoke-Bridge -Command "get-app-state" -Payload @{
    app = "calculator"
    includeCursor = $true
    depth = 8
    maxActionableElements = 300
    timeoutMs = 1000
  }
  if ($state.status -ne "found") { return $null }
  $text = ($state.accessibilityTree | ConvertTo-Json -Depth 30)
  $verified = $text -match '"automationId":\s+"CalculatorResults"[\s\S]{0,500}?"Display is 4"' -or
    $text -match '"name":\s+"Display is 4"[\s\S]{0,500}?"automationId":\s+"CalculatorResults"'
  return [pscustomobject]@{ state = $state; text = $text; verified = $verified }
}

function Approve-CodexToolPrompt {
  $targetsResponse = Invoke-Bridge -Command "dump-app-targets" -Payload @{
    app = "Codex"
    depth = 12
    maxTargets = 600
    includeOffscreen = $false
    timeoutMs = 1000
  }
  if ($targetsResponse.status -ne "found") { return $false }
  $targets = @($targetsResponse.targets)

  $allowForChat = @(
    $targets |
      Where-Object { $_.screenCenter -and "$($_.label)" -match "^Allow for this chat" } |
      Select-Object -First 1
  )
  if ($allowForChat.Count -gt 0) {
    Invoke-Bridge -Command "click" -Payload @{
      app = "Codex"
      x = [int]$allowForChat[0].screenCenter.x
      y = [int]$allowForChat[0].screenCenter.y
      mouse_button = "left"
      click_count = 1
    } | Out-Null
    Start-Sleep -Milliseconds 250
  }

  $allow = @(
    $targets |
      Where-Object {
        $_.screenCenter -and
        "$($_.label)" -match "^Allow$|Allow.*↵|Allow.*Enter" -and
        "$($_.label)" -notmatch "for this chat"
      } |
      Sort-Object @{ Expression = { [double]$_.screenCenter.x }; Descending = $true } |
      Select-Object -First 1
  )
  if ($allow.Count -eq 0) { return $false }

  Invoke-Bridge -Command "click" -Payload @{
    app = "Codex"
    x = [int]$allow[0].screenCenter.x
    y = [int]$allow[0].screenCenter.y
    mouse_button = "left"
    click_count = 1
  } | Out-Null
  Start-Sleep -Milliseconds 250
  Invoke-Bridge -Command "press-key" -Payload @{ app = "Codex"; key = "enter" } | Out-Null
  return $true
}

function Approve-CodexToolPromptFallback {
  $state = Invoke-Bridge -Command "get-app-state" -Payload @{
    app = "Codex"
    includeCursor = $true
    depth = 8
    maxActionableElements = 300
    timeoutMs = 1000
  }
  if ($state.status -ne "found") { return $false }
  $text = $state.accessibilityTree | ConvertTo-Json -Depth 30
  if ($text -match "Do you want to") { return $false }
  $rect = $state.window.rect

  # The Codex approval card is not always exposed as a stable Button through
  # UIA, so use its stable position in the Codex window as a test harness
  # fallback. This only approves inside Codex during this explicit test run.
  Invoke-Bridge -Command "click" -Payload @{
    app = "Codex"
    x = [int]($rect.x + 345)
    y = [int]($rect.y + $rect.height - 210)
    mouse_button = "left"
    click_count = 1
  } | Out-Null
  Start-Sleep -Milliseconds 250
  Invoke-Bridge -Command "click" -Payload @{
    app = "Codex"
    x = [int]($rect.x + $rect.width - 78)
    y = [int]($rect.y + $rect.height - 210)
    mouse_button = "left"
    click_count = 1
  } | Out-Null
  return $true
}

function Approve-CodexCommandPrompt {
  $state = Invoke-Bridge -Command "get-app-state" -Payload @{
    app = "Codex"
    includeCursor = $true
    depth = 8
    maxActionableElements = 300
    timeoutMs = 1000
  }
  if ($state.status -ne "found") { return $false }
  $rect = $state.window.rect
  Invoke-Bridge -Command "click" -Payload @{
    app = "Codex"
    x = [int]($rect.x + $rect.width - 82)
    y = [int]($rect.y + $rect.height - 66)
    mouse_button = "left"
    click_count = 1
  } | Out-Null
  return $true
}

if ($env:OS -ne "Windows_NT") {
  throw "This test must run on Windows."
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
try { Invoke-Bridge -Command "hide-fake-cursor" | Out-Null } catch {}

Get-Process Codex -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Get-Process Calculator -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Get-Process ApplicationFrameHost -ErrorAction SilentlyContinue |
  Where-Object { $_.MainWindowTitle -match "Calculator" } |
  Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 1000
$codexExe = Find-CodexExe
Start-Process -FilePath $codexExe | Out-Null
Start-Sleep -Seconds 8

$beforeDesktop = Save-DesktopScreenshot (Join-Path $OutDir "01-desktop-after-codex-launch.png")
$codexState = Wait-AppState "Codex" 30000
$codexState | ConvertTo-Json -Depth 30 | Set-Content -Path (Join-Path $OutDir "02-codex-state-before-prompt.json") -Encoding UTF8

$composer = Find-ComposerTarget $codexState
$click = Invoke-Bridge -Command "click" -Payload @{
  app = "Codex"
  x = [int]$composer.screenCenter.x
  y = [int]$composer.screenCenter.y
  mouse_button = "left"
  click_count = 1
}
Start-Sleep -Milliseconds 500

$typed = Invoke-Bridge -Command "type-text" -Payload @{ app = "Codex"; text = $Prompt }
$submittedDesktop = Save-DesktopScreenshot (Join-Path $OutDir "03-prompt-typed.png")
$enter = Invoke-Bridge -Command "press-key" -Payload @{ app = "Codex"; key = "enter" }
Start-Sleep -Seconds 3
$afterSubmitDesktop = Save-DesktopScreenshot (Join-Path $OutDir "04-after-submit.png")
$approvalClicks = 0
$commandApprovalClicks = 0

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$resultVerified = $false
$resultText = $null
$calculatorState = $null
$samples = @()
do {
  Start-Sleep -Seconds 5
  $approved = (Approve-CodexToolPrompt) -or (Approve-CodexToolPromptFallback)
  if (!$approved -and $commandApprovalClicks -lt 1) {
    $approved = Approve-CodexCommandPrompt
    if ($approved) { $commandApprovalClicks += 1 }
  }
  if ($approved) {
    $approvalClicks += 1
    Start-Sleep -Seconds 2
  }
  $samplePath = Join-Path $OutDir ("sample-{0:HHmmss}.png" -f (Get-Date))
  $samples += Save-DesktopScreenshot $samplePath
  $calc = Get-CalculatorResultText
  if ($null -ne $calc) {
    $calculatorState = $calc.state
    $resultText = $calc.text
    if ($calc.verified) {
      $resultVerified = $true
      break
    }
  }
} while ((Get-Date) -lt $deadline)

if ($null -ne $calculatorState) {
  $calculatorState | ConvertTo-Json -Depth 30 | Set-Content -Path (Join-Path $OutDir "05-calculator-state.json") -Encoding UTF8
}
$finalDesktop = Save-DesktopScreenshot (Join-Path $OutDir "06-final-desktop.png")
$finalCodex = Invoke-Bridge -Command "get-app-state" -Payload @{
  app = "Codex"
  includeCursor = $true
  depth = 8
  maxActionableElements = 300
  timeoutMs = 1000
}
$finalCodex | ConvertTo-Json -Depth 30 | Set-Content -Path (Join-Path $OutDir "07-codex-state-final.json") -Encoding UTF8

$report = [pscustomobject]@{
  status = if ($resultVerified) { "ok" } else { "failed" }
  prompt = $Prompt
  codexExe = $codexExe
  composer = $composer
  click = $click
  typed = $typed
  enter = $enter
  approvalClicks = $approvalClicks
  commandApprovalClicks = $commandApprovalClicks
  resultVerified = $resultVerified
  resultText = $resultText
  screenshots = @($beforeDesktop, $submittedDesktop, $afterSubmitDesktop, $samples, $finalDesktop)
  outDir = $OutDir
}
$report | ConvertTo-Json -Depth 30 | Set-Content -Path (Join-Path $OutDir "visual-report.json") -Encoding UTF8
$report | ConvertTo-Json -Depth 30

if (!$resultVerified) {
  throw "Codex @computer prompt did not produce a verified Calculator result of 4 within $TimeoutSeconds seconds."
}
