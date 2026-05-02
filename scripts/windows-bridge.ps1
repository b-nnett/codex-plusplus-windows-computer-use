param(
  [string]$Command = "",

  [string]$Payload = "{}",

  [string]$PayloadBase64 = "",

  [switch]$Server
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class Win32ComputerUse {
  [DllImport("user32.dll")]
  public static extern bool GetCursorPos(out POINT lpPoint);

  [DllImport("user32.dll")]
  public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

  [DllImport("user32.dll")]
  public static extern bool SetForegroundWindow(IntPtr hWnd);

  [DllImport("user32.dll")]
  public static extern IntPtr GetForegroundWindow();

  [DllImport("user32.dll")]
  public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

  [DllImport("user32.dll")]
  public static extern IntPtr WindowFromPoint(POINT Point);

  [DllImport("user32.dll")]
  public static extern bool ScreenToClient(IntPtr hWnd, ref POINT lpPoint);

  [DllImport("user32.dll", SetLastError = true)]
  public static extern bool PostMessage(IntPtr hWnd, UInt32 Msg, IntPtr wParam, IntPtr lParam);

  [StructLayout(LayoutKind.Sequential)]
  public struct POINT {
    public int X;
    public int Y;
  }

  [StructLayout(LayoutKind.Sequential)]
  public struct RECT {
    public int Left;
    public int Top;
    public int Right;
    public int Bottom;
  }
}
"@

$WindowMessages = @{
  MouseMove = 0x0200
  LeftDown = 0x0201
  LeftUp = 0x0202
  RightDown = 0x0204
  RightUp = 0x0205
  MiddleDown = 0x0207
  MiddleUp = 0x0208
  MouseWheel = 0x020A
  MouseHWheel = 0x020E
}

$MouseKeyState = @{
  Left = 0x0001
  Right = 0x0002
  Middle = 0x0010
}

$StateDir = Join-Path $env:LOCALAPPDATA "codex-plusplus\windows-computer-use"
$StateFile = Join-Path $StateDir "state.json"
$OverlayStdout = Join-Path $StateDir "overlay-output.log"
$OverlayStderr = Join-Path $StateDir "overlay-error.log"
$RootDir = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$OverlayScript = Join-Path $RootDir "scripts\fake-cursor-overlay.ps1"
$OverlayAssetDir = Join-Path $RootDir "assets\macos-computer-use"

function ConvertFrom-Payload {
  if (![string]::IsNullOrWhiteSpace($env:WCU_PAYLOAD_BASE64)) {
    $json = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:WCU_PAYLOAD_BASE64))
    return $json | ConvertFrom-Json
  }
  if (![string]::IsNullOrWhiteSpace($PayloadBase64)) {
    $json = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($PayloadBase64))
    return $json | ConvertFrom-Json
  }
  if ([string]::IsNullOrWhiteSpace($Payload)) {
    return [pscustomobject]@{}
  }
  return $Payload | ConvertFrom-Json
}

function ConvertTo-BridgeJson($Value) {
  $Value | ConvertTo-Json -Depth 32 -Compress
}

function Write-Json($Value) {
  ConvertTo-BridgeJson $Value
}

function Ensure-StateDir {
  if (!(Test-Path $StateDir)) {
    New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
  }
}

function Read-State {
  Ensure-StateDir
  if (!(Test-Path $StateFile)) {
    return [pscustomobject]@{
      cursor = [pscustomobject]@{ x = 0; y = 0; visible = $false; style = "software"; isPressed = $false; overlayPid = $null }
      sessions = @{}
    }
  }
  $lastError = $null
  for ($attempt = 0; $attempt -lt 8; $attempt++) {
    try {
      return Get-Content $StateFile -Raw | ConvertFrom-Json
    } catch {
      $lastError = $_
      Start-Sleep -Milliseconds 20
    }
  }
  throw $lastError
}

function Write-State($State) {
  Ensure-StateDir
  $json = $State | ConvertTo-Json -Depth 16
  $lastError = $null
  for ($attempt = 0; $attempt -lt 8; $attempt++) {
    try {
      $json | Set-Content -Path $StateFile -Encoding UTF8
      return
    } catch {
      $lastError = $_
      Start-Sleep -Milliseconds 20
    }
  }
  throw $lastError
}

function Ensure-CursorShape($State) {
  if ($null -eq $State.cursor) {
    $State | Add-Member -NotePropertyName cursor -NotePropertyValue ([pscustomobject]@{}) -Force
  }
  if ($null -eq $State.cursor.PSObject.Properties["x"]) {
    $State.cursor | Add-Member -NotePropertyName x -NotePropertyValue 0 -Force
  }
  if ($null -eq $State.cursor.PSObject.Properties["y"]) {
    $State.cursor | Add-Member -NotePropertyName y -NotePropertyValue 0 -Force
  }
  if ($null -eq $State.cursor.PSObject.Properties["visible"]) {
    $State.cursor | Add-Member -NotePropertyName visible -NotePropertyValue $false -Force
  }
  if ($null -eq $State.cursor.PSObject.Properties["style"]) {
    $State.cursor | Add-Member -NotePropertyName style -NotePropertyValue "software" -Force
  }
  if ($null -eq $State.cursor.PSObject.Properties["isPressed"]) {
    $State.cursor | Add-Member -NotePropertyName isPressed -NotePropertyValue $false -Force
  }
  if ($null -eq $State.cursor.PSObject.Properties["overlayPid"]) {
    $State.cursor | Add-Member -NotePropertyName overlayPid -NotePropertyValue $null -Force
  }
  if ($null -eq $State.cursor.PSObject.Properties["debugFramePath"]) {
    $State.cursor | Add-Member -NotePropertyName debugFramePath -NotePropertyValue $null -Force
  }
  if ($null -eq $State.cursor.PSObject.Properties["clickPulseUntil"]) {
    $State.cursor | Add-Member -NotePropertyName clickPulseUntil -NotePropertyValue 0 -Force
  }
  if ($null -eq $State.cursor.PSObject.Properties["hasPosition"]) {
    $State.cursor | Add-Member -NotePropertyName hasPosition -NotePropertyValue $false -Force
  }
  return $State
}

function Get-UnixMilliseconds {
  [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
}

function Normalize-CursorStyle($Style) {
  $value = "$Style".ToLowerInvariant()
  if ($value -eq "software" -or $value -eq "pointer") { return "software" }
  if ($value -eq "lens") { return "lens" }
  if ($value -eq "fog") { return "fog" }
  return "software"
}

function Test-ProcessAlive($ProcessId) {
  if ($null -eq $ProcessId -or "$ProcessId" -eq "") { return $false }
  try {
    $proc = Get-Process -Id ([int]$ProcessId) -ErrorAction Stop
    return $null -ne $proc
  } catch {
    return $false
  }
}

function Quote-ProcessArg([string]$Value) {
  if ($null -eq $Value) { return '""' }
  return '"' + $Value.Replace('"', '\"') + '"'
}

function Start-FakeCursorOverlay($State) {
  $State = Ensure-CursorShape $State
  if (Test-ProcessAlive $State.cursor.overlayPid) {
    return $State.cursor.overlayPid
  }
  if (!(Test-Path $OverlayScript)) {
    throw "Fake cursor overlay script not found: $OverlayScript"
  }
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = "powershell.exe"
  $psi.UseShellExecute = $true
  $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
  $launchArgs = @(
    "-NoProfile",
    "-Sta",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    $OverlayScript,
    "-StateFile",
    $StateFile,
    "-AssetDir",
    $OverlayAssetDir
  )
  $psi.Arguments = (($launchArgs | ForEach-Object { Quote-ProcessArg "$_" }) -join " ")
  $proc = [System.Diagnostics.Process]::Start($psi)
  Start-Sleep -Milliseconds 200
  if ($proc.HasExited) {
    $stderr = if (Test-Path "$StateFile.overlay-error.log") { Get-Content "$StateFile.overlay-error.log" -Raw } else { "" }
    throw "Fake cursor overlay exited during startup with code $($proc.ExitCode). $stderr"
  }
  $State.cursor.overlayPid = $proc.Id
  Write-State $State
  return $proc.Id
}

function Stop-FakeCursorOverlay($State) {
  $State = Ensure-CursorShape $State
  $pidValue = $State.cursor.overlayPid
  if (Test-ProcessAlive $pidValue) {
    try { & taskkill.exe /PID ([int]$pidValue) /T /F | Out-Null } catch {}
    try { Stop-Process -Id ([int]$pidValue) -Force -ErrorAction SilentlyContinue } catch {}
  }
  $State.cursor.overlayPid = $null
  $State.cursor.visible = $false
  Write-State $State
}

function New-Check($Name, [bool]$Ok, $Detail = $null, $Severity = "info") {
  [pscustomobject]@{
    name = $Name
    ok = $Ok
    severity = $Severity
    detail = $Detail
  }
}

function Test-StateDirWritable {
  try {
    Ensure-StateDir
    $probe = Join-Path $StateDir ("setup-check-{0}.tmp" -f ([Guid]::NewGuid().ToString("n")))
    "ok" | Set-Content -Path $probe -Encoding UTF8
    Remove-Item -Path $probe -Force
    return $true
  } catch {
    return $false
  }
}

function Test-IsElevated {
  try {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal $identity
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
  } catch {
    return $false
  }
}

function Test-RootAutomation {
  try {
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    return $null -ne $root
  } catch {
    return $false
  }
}

function Test-BitmapCapturePrimitive {
  try {
    $bitmap = New-Object System.Drawing.Bitmap 1, 1
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.CopyFromScreen(0, 0, 0, 0, $bitmap.Size)
    $graphics.Dispose()
    $bitmap.Dispose()
    return $true
  } catch {
    return $false
  }
}

function Test-CursorPrimitive {
  try {
    $point = New-Object Win32ComputerUse+POINT
    return [Win32ComputerUse]::GetCursorPos([ref]$point)
  } catch {
    return $false
  }
}

function Get-SetupCheck {
  $isWindows = $env:OS -eq "Windows_NT"
  $checks = New-Object System.Collections.ArrayList
  $checks.Add((New-Check "windows-platform" $isWindows @{ os = $env:OS })) | Out-Null
  $checks.Add((New-Check "powershell-version" ($PSVersionTable.PSVersion.Major -ge 5) @{ version = "$($PSVersionTable.PSVersion)" })) | Out-Null
  $checks.Add((New-Check "state-dir-writable" (Test-StateDirWritable) @{ path = $StateDir } "required")) | Out-Null
  $checks.Add((New-Check "bridge-script-present" (Test-Path $PSCommandPath) @{ path = $PSCommandPath } "required")) | Out-Null
  $checks.Add((New-Check "overlay-script-present" (Test-Path $OverlayScript) @{ path = $OverlayScript } "required")) | Out-Null
  $checks.Add((New-Check "overlay-assets-present" (Test-Path $OverlayAssetDir) @{ path = $OverlayAssetDir } "required")) | Out-Null
  $lensDir = Join-Path $OverlayAssetDir "LensSequence"
  $lensFrameCount = @(Get-ChildItem -Path $lensDir -Filter "Lens_frame_*.png" -ErrorAction SilentlyContinue).Count
  $checks.Add((New-Check "lens-sequence-present" ((Test-Path $lensDir) -and ($lensFrameCount -gt 0)) @{ path = $lensDir; frameCount = $lensFrameCount } "recommended")) | Out-Null
  $checks.Add((New-Check "uia-root-available" (Test-RootAutomation) "Windows UI Automation RootElement can be read." "required")) | Out-Null
  $checks.Add((New-Check "screen-capture-primitive" (Test-BitmapCapturePrimitive) "System.Drawing CopyFromScreen can capture at least one pixel." "required")) | Out-Null
  $checks.Add((New-Check "cursor-primitive" (Test-CursorPrimitive) "user32 GetCursorPos is callable." "required")) | Out-Null
  $checks.Add((New-Check "process-elevated" (Test-IsElevated) "Only needed when controlling elevated/admin target apps. Normal apps should be tested from a non-elevated Codex process." "caveat")) | Out-Null

  $executionPolicy = [pscustomobject]@{}
  foreach ($scope in @("Process", "CurrentUser", "LocalMachine")) {
    try {
      $executionPolicy | Add-Member -NotePropertyName $scope -NotePropertyValue (Get-ExecutionPolicy -Scope $scope) -Force
    } catch {}
  }

  $requiredFailures = @($checks | Where-Object { $_.severity -eq "required" -and !$_.ok })
  $recommendations = @(
    "There is no macOS-style Accessibility permission prompt on Windows for this bridge.",
    "Run Codex and the bridge at the same integrity level as the target app; elevated apps require elevated Codex.",
    "UAC secure desktop, lock screen, credential prompts, and some protected system surfaces cannot be automated reliably.",
    "Screenshots require an unlocked interactive desktop. Minimized, disconnected, or locked RDP sessions can produce blank or stale captures.",
    "The launch commands use -ExecutionPolicy Bypass for this process, so persistent execution-policy changes should not be necessary.",
    "Call get_app_state after every navigation or dialog change; UIA element indexes are snapshots and can become stale."
  )

  [pscustomobject]@{
    status = if ($requiredFailures.Count -eq 0) { "ready" } else { "blocked" }
    platform = "win32"
    isElevated = Test-IsElevated
    powershellVersion = "$($PSVersionTable.PSVersion)"
    is64BitProcess = [Environment]::Is64BitProcess
    is64BitOperatingSystem = [Environment]::Is64BitOperatingSystem
    executionPolicy = $executionPolicy
    stateDir = $StateDir
    overlayScript = $OverlayScript
    overlayAssetDir = $OverlayAssetDir
    visibleWindowCount = @(Get-VisibleApps).Count
    checks = @($checks)
    recommendations = $recommendations
  }
}

function Get-VisibleApps {
  Get-Process |
    Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle } |
    Sort-Object ProcessName |
    ForEach-Object {
      $display = Get-AppDisplay $_ $false
      $path = $null
      try { $path = $_.Path } catch {}
      [pscustomobject]@{
        name = $_.ProcessName
        pid = $_.Id
        title = $_.MainWindowTitle
        path = $path
        handle = "0x{0:x}" -f $_.MainWindowHandle.ToInt64()
        display = $display
      }
    }
}

function Get-SafeFileName([string]$Value) {
  $name = if ([string]::IsNullOrWhiteSpace($Value)) { "app" } else { $Value }
  foreach ($char in [System.IO.Path]::GetInvalidFileNameChars()) {
    $name = $name.Replace($char, "_")
  }
  return $name
}

function Save-AppIcon($Process, [bool]$IncludeDataUri = $false) {
  try {
    $path = $Process.Path
    if ([string]::IsNullOrWhiteSpace($path) -or !(Test-Path $path)) { return $null }
    Ensure-StateDir
    $iconDir = Join-Path $StateDir "icons"
    if (!(Test-Path $iconDir)) {
      New-Item -ItemType Directory -Path $iconDir -Force | Out-Null
    }
    $safeName = Get-SafeFileName $Process.ProcessName
    $file = Join-Path $iconDir ("{0}-{1}.png" -f $safeName, $Process.Id)
    if (!(Test-Path $file)) {
      $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($path)
      if ($null -eq $icon) { return $null }
      $bitmap = $icon.ToBitmap()
      try {
        $bitmap.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
      } finally {
        $bitmap.Dispose()
        $icon.Dispose()
      }
    }
    $dataUri = $null
    if ($IncludeDataUri -and (Test-Path $file)) {
      $bytes = [System.IO.File]::ReadAllBytes($file)
      $dataUri = "data:image/png;base64," + [Convert]::ToBase64String($bytes)
    }
    $result = [ordered]@{
      path = $file
      mimeType = "image/png"
    }
    if ($IncludeDataUri) {
      $result.dataUri = $dataUri
    }
    return [pscustomobject]$result
  } catch {
    return $null
  }
}

function Get-AppDisplay($Process, [bool]$IncludeIconData = $false) {
  $fileDescription = $null
  $productName = $null
  $path = $null
  try { $path = $Process.Path } catch {}
  if (![string]::IsNullOrWhiteSpace($path) -and (Test-Path $path)) {
    try {
      $versionInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($path)
      $fileDescription = $versionInfo.FileDescription
      $productName = $versionInfo.ProductName
    } catch {}
  }
  $displayName = @($fileDescription, $productName, $Process.ProcessName) |
    Where-Object { ![string]::IsNullOrWhiteSpace("$_") } |
    Select-Object -First 1
  [pscustomobject]@{
    name = "$displayName"
    processName = $Process.ProcessName
    pid = $Process.Id
    windowTitle = $Process.MainWindowTitle
    executablePath = $path
    handle = "0x{0:x}" -f $Process.MainWindowHandle.ToInt64()
    icon = Save-AppIcon $Process $IncludeIconData
  }
}

function Find-AppProcess($App, [int]$TimeoutMs = 0) {
  $needle = "$App".ToLowerInvariant()
  $deadline = [DateTimeOffset]::UtcNow.AddMilliseconds([Math]::Max(0, $TimeoutMs))
  do {
    $match = Get-Process |
      Where-Object {
        $_.MainWindowHandle -ne 0 -and
        $_.MainWindowTitle -and
        ($_.ProcessName.ToLowerInvariant().Contains($needle) -or $_.MainWindowTitle.ToLowerInvariant().Contains($needle))
      } |
      Select-Object -First 1
    if ($null -ne $match) { return $match }
    if ([DateTimeOffset]::UtcNow -lt $deadline) {
      Start-Sleep -Milliseconds 100
    }
  } while ([DateTimeOffset]::UtcNow -lt $deadline)
  return $null
}

function Focus-App($App) {
  if (!$App) { return $null }
  $proc = Find-AppProcess $App
  if ($null -ne $proc) {
    [Win32ComputerUse]::SetForegroundWindow($proc.MainWindowHandle) | Out-Null
    Start-Sleep -Milliseconds 80
  }
  return $proc
}

function Get-ForegroundWindowInfo {
  $hwnd = [Win32ComputerUse]::GetForegroundWindow()
  $processId = 0
  if ($hwnd -ne [IntPtr]::Zero) {
    [Win32ComputerUse]::GetWindowThreadProcessId($hwnd, [ref]$processId) | Out-Null
  }
  $proc = $null
  if ($processId -ne 0) {
    try { $proc = Get-Process -Id ([int]$processId) -ErrorAction Stop } catch {}
  }
  [pscustomobject]@{
    handle = if ($hwnd -ne [IntPtr]::Zero) { "0x{0:x}" -f $hwnd.ToInt64() } else { $null }
    pid = if ($processId -ne 0) { [int]$processId } else { $null }
    processName = if ($null -ne $proc) { $proc.ProcessName } else { $null }
    windowTitle = if ($null -ne $proc) { $proc.MainWindowTitle } else { $null }
  }
}

function Test-ForegroundMatchesProcess($Process) {
  if ($null -eq $Process) { return $false }
  $foreground = Get-ForegroundWindowInfo
  return ($foreground.pid -eq $Process.Id)
}

function Focus-AppStrict($App, [int]$TimeoutMs = 900) {
  if (!$App) { throw "Target app is required for key input." }
  $proc = Find-AppProcess $App
  if ($null -eq $proc) { throw "App not found: $App" }

  $deadline = [DateTimeOffset]::UtcNow.AddMilliseconds([Math]::Max(100, $TimeoutMs))
  do {
    [Win32ComputerUse]::SetForegroundWindow($proc.MainWindowHandle) | Out-Null
    Start-Sleep -Milliseconds 80
    if (Test-ForegroundMatchesProcess $proc) {
      return [pscustomobject]@{
        process = $proc
        foreground = Get-ForegroundWindowInfo
        verified = $true
      }
    }
  } while ([DateTimeOffset]::UtcNow -lt $deadline)

  $foreground = Get-ForegroundWindowInfo
  throw "Refusing to send keys: target app '$App' is not focused. Foreground is '$($foreground.processName)' pid=$($foreground.pid) title='$($foreground.windowTitle)'."
}

function New-ActionPresentation($Action, $Process, [string]$Summary, $Extra = $null) {
  $display = Get-AppDisplay $Process $false
  $presentation = [ordered]@{
    appName = $display.name
    processName = $display.processName
    iconPath = $display.icon.path
    windowTitle = $display.windowTitle
    action = $Action
    summary = $Summary
  }
  if ($null -ne $Extra) {
    foreach ($property in $Extra.PSObject.Properties) {
      $presentation[$property.Name] = $property.Value
    }
  }
  [pscustomobject]@{
    appDisplay = $display
    presentation = [pscustomobject]$presentation
  }
}

function Get-PreviewText([string]$Text, [int]$MaxLength = 60) {
  if ($null -eq $Text) { return "" }
  $singleLine = $Text.Replace("`r", " ").Replace("`n", " ")
  if ($singleLine.Length -le $MaxLength) { return $singleLine }
  return $singleLine.Substring(0, [Math]::Max(0, $MaxLength - 3)) + "..."
}

function Get-WindowRectObject($Process) {
  $rect = New-Object Win32ComputerUse+RECT
  [Win32ComputerUse]::GetWindowRect($Process.MainWindowHandle, [ref]$rect) | Out-Null
  [pscustomobject]@{
    x = $rect.Left
    y = $rect.Top
    width = [Math]::Max(0, $rect.Right - $rect.Left)
    height = [Math]::Max(0, $rect.Bottom - $rect.Top)
    left = $rect.Left
    top = $rect.Top
    right = $rect.Right
    bottom = $rect.Bottom
  }
}

function Get-AppRoot($App) {
  $proc = Find-AppProcess $App
  if ($null -eq $proc) {
    throw "App not found: $App"
  }
  [System.Windows.Automation.AutomationElement]::FromHandle($proc.MainWindowHandle)
}

function Find-ElementByIndexWithWalker($Element, [string]$TargetIndex, [ref]$Index, $Walker) {
  if ($null -eq $Element) { return $null }
  $currentIndex = "$($Index.Value)"
  $Index.Value += 1
  if ($currentIndex -eq "$TargetIndex") {
    return $Element
  }

  $child = $Walker.GetFirstChild($Element)
  while ($null -ne $child) {
    $found = Find-ElementByIndexWithWalker $child $TargetIndex $Index $Walker
    if ($null -ne $found) { return $found }
    $child = $Walker.GetNextSibling($child)
  }
  return $null
}

function Find-ElementByIndex($Element, [string]$TargetIndex, [ref]$Index) {
  Find-ElementByIndexWithWalker $Element $TargetIndex $Index ([System.Windows.Automation.TreeWalker]::ControlViewWalker)
}

function Get-ElementByIndex($App, $ElementIndex) {
  if ($null -eq $ElementIndex -or "$ElementIndex" -eq "") {
    return $null
  }
  $root = Get-AppRoot $App
  $index = 0
  $elementKey = "$ElementIndex"
  if ($elementKey.StartsWith("raw:")) {
    $rawIndex = $elementKey.Substring(4)
    $element = Find-ElementByIndexWithWalker $root $rawIndex ([ref]$index) ([System.Windows.Automation.TreeWalker]::RawViewWalker)
  } else {
    $element = Find-ElementByIndex $root $elementKey ([ref]$index)
  }
  if ($null -eq $element) {
    throw "Element index not found: $ElementIndex"
  }
  return $element
}

function Get-ElementCenter($Element) {
  $rect = $Element.Current.BoundingRectangle
  [pscustomobject]@{
    x = [int]($rect.X + ($rect.Width / 2))
    y = [int]($rect.Y + ($rect.Height / 2))
  }
}

function Get-ElementText($Element) {
  $names = @()
  foreach ($prop in @(
    [System.Windows.Automation.AutomationElement]::NameProperty,
    [System.Windows.Automation.AutomationElement]::AutomationIdProperty,
    [System.Windows.Automation.AutomationElement]::ClassNameProperty
  )) {
    try {
      $value = $Element.GetCurrentPropertyValue($prop)
      if ($value) { $names += "$value" }
    } catch {}
  }
  return ($names -join " ").Trim()
}

function Get-ControlTypeName($Element) {
  try {
    $name = "$($Element.Current.ControlType.ProgrammaticName)"
    return $name.Replace("ControlType.", "")
  } catch {
    return ""
  }
}

function Get-ElementPatterns($Element) {
  $patterns = @()
  try {
    foreach ($pattern in $Element.GetSupportedPatterns()) {
      $name = "$($pattern.ProgrammaticName)"
      if ($name) {
        $normalized = $name
        if ($normalized -match "^(.+)PatternIdentifiers\.Pattern$") {
          $normalized = $Matches[1]
        } else {
          $normalized = $normalized.Replace("PatternIdentifiers.Pattern.", "").Replace("Pattern.", "")
        }
        $patterns += $normalized
      }
    }
  } catch {}
  return @($patterns | Sort-Object -Unique)
}

function Get-ElementActionHints($ControlTypeName, $Patterns) {
  $actions = @()
  if ($Patterns -contains "Invoke") { $actions += "click" }
  if ($Patterns -contains "Toggle") { $actions += "toggle" }
  if ($Patterns -contains "ExpandCollapse") { $actions += "expand/collapse" }
  if ($Patterns -contains "SelectionItem") { $actions += "select" }
  if ($Patterns -contains "Value") { $actions += "set_value" }
  if ($Patterns -contains "Scroll") { $actions += "scroll" }
  if ($ControlTypeName -in @("Button", "Hyperlink", "MenuItem", "TabItem", "ListItem", "TreeItem", "DataItem", "CheckBox", "RadioButton", "SplitButton")) {
    $actions += "click"
  }
  if ($ControlTypeName -in @("Edit", "ComboBox", "Document")) {
    $actions += "type_text"
  }
  return @($actions | Sort-Object -Unique)
}

function Get-RecommendedTool($Actions) {
  if ($Actions -contains "set_value") { return "set_value" }
  if ($Actions -contains "type_text") { return "type_text" }
  if ($Actions -contains "toggle") { return "perform_secondary_action:toggle" }
  if ($Actions -contains "expand/collapse") { return "perform_secondary_action:expand" }
  if ($Actions -contains "select") { return "perform_secondary_action:select" }
  if ($Actions -contains "scroll") { return "scroll" }
  if ($Actions -contains "click") { return "click" }
  return "click"
}

function Convert-ElementRect($Rect, $WindowRect) {
  $screen = [pscustomobject]@{
    x = [Math]::Round($Rect.X)
    y = [Math]::Round($Rect.Y)
    width = [Math]::Round($Rect.Width)
    height = [Math]::Round($Rect.Height)
  }
  $center = [pscustomobject]@{
    x = [Math]::Round($Rect.X + ($Rect.Width / 2))
    y = [Math]::Round($Rect.Y + ($Rect.Height / 2))
  }
  $windowRelative = $null
  $windowCenter = $null
  if ($null -ne $WindowRect) {
    $windowRelative = [pscustomobject]@{
      x = [Math]::Round($Rect.X - $WindowRect.x)
      y = [Math]::Round($Rect.Y - $WindowRect.y)
      width = [Math]::Round($Rect.Width)
      height = [Math]::Round($Rect.Height)
    }
    $windowCenter = [pscustomobject]@{
      x = [Math]::Round(($Rect.X - $WindowRect.x) + ($Rect.Width / 2))
      y = [Math]::Round(($Rect.Y - $WindowRect.y) + ($Rect.Height / 2))
    }
  }
  [pscustomobject]@{
    screen = $screen
    window = $windowRelative
    center = $center
    windowCenter = $windowCenter
  }
}

function Convert-Element($Element, [int]$Depth, [ref]$Index, $WindowRect) {
  if ($null -eq $Element -or $Depth -lt 0) {
    return $null
  }

  try {
    $current = $Element.Current
    $rect = $current.BoundingRectangle
    $name = $current.Name
    $automationId = $current.AutomationId
    $controlType = $current.ControlType.ProgrammaticName
    $className = $current.ClassName
    $isEnabled = $current.IsEnabled
    $isOffscreen = $current.IsOffscreen
  } catch {
    return $null
  }

  $currentIndex = $Index.Value
  $Index.Value += 1
  $controlTypeName = Get-ControlTypeName $Element
  $patterns = @(Get-ElementPatterns $Element)
  $actions = @(Get-ElementActionHints $controlTypeName $patterns)
  $children = @()

  if ($Depth -gt 0) {
    try {
      $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
      $child = $walker.GetFirstChild($Element)
      while ($null -ne $child -and $children.Count -lt 160) {
        $converted = Convert-Element $child ($Depth - 1) $Index $WindowRect
        if ($null -ne $converted) { $children += $converted }
        try {
          $child = $walker.GetNextSibling($child)
        } catch {
          $child = $null
        }
      }
    } catch {}
  }

  [pscustomobject]@{
    index = "$currentIndex"
    name = $name
    automationId = $automationId
    controlType = $controlType
    controlTypeName = $controlTypeName
    className = $className
    isEnabled = $isEnabled
    isOffscreen = $isOffscreen
    text = Get-ElementText $Element
    supportedPatterns = $patterns
    actions = $actions
    rect = [pscustomobject]@{
      x = [Math]::Round($rect.X)
      y = [Math]::Round($rect.Y)
      width = [Math]::Round($rect.Width)
      height = [Math]::Round($rect.Height)
    }
    bounds = Convert-ElementRect $rect $WindowRect
    children = $children
  }
}

function Test-ActionableNode($Node, [bool]$IncludeOffscreen) {
  if ($null -eq $Node) { return $false }
  if (!$Node.isEnabled) { return $false }
  if (!$IncludeOffscreen -and $Node.isOffscreen) { return $false }
  if ($Node.rect.width -le 0 -or $Node.rect.height -le 0) { return $false }
  if ($Node.actions -and $Node.actions.Count -gt 0) { return $true }
  return $Node.controlTypeName -in @(
    "Button", "Hyperlink", "Edit", "ComboBox", "MenuItem", "TabItem", "CheckBox", "RadioButton",
    "ListItem", "TreeItem", "DataItem", "SplitButton", "Slider", "Spinner", "Document"
  )
}

function Add-ActionableNodes($Node, $Results, [int]$MaxTargets, [bool]$IncludeOffscreen) {
  if ($null -eq $Node -or $Results.Count -ge $MaxTargets) { return }
  if (Test-ActionableNode $Node $IncludeOffscreen) {
    $label = "$($Node.name)"
    if ([string]::IsNullOrWhiteSpace($label)) { $label = "$($Node.automationId)" }
    if ([string]::IsNullOrWhiteSpace($label)) { $label = "$($Node.text)" }
    $Results.Add([pscustomobject]@{
      index = $Node.index
      label = $label
      name = $Node.name
      automationId = $Node.automationId
      controlType = $Node.controlTypeName
      className = $Node.className
      isEnabled = $Node.isEnabled
      isOffscreen = $Node.isOffscreen
      actions = $Node.actions
      recommendedTool = Get-RecommendedTool $Node.actions
      supportedPatterns = $Node.supportedPatterns
      screenRect = $Node.bounds.screen
      windowRect = $Node.bounds.window
      screenCenter = $Node.bounds.center
      windowCenter = $Node.bounds.windowCenter
    }) | Out-Null
  }
  foreach ($child in @($Node.children)) {
    if ($Results.Count -ge $MaxTargets) { break }
    Add-ActionableNodes $child $Results $MaxTargets $IncludeOffscreen
  }
}

function New-ActionableTargetFromElement($Element, [string]$Index, $WindowRect, [string]$Source) {
  try {
    $current = $Element.Current
    $rect = $current.BoundingRectangle
    $controlTypeName = Get-ControlTypeName $Element
    $patterns = @(Get-ElementPatterns $Element)
    $actions = @(Get-ElementActionHints $controlTypeName $patterns)
    $label = "$($current.Name)"
    if ([string]::IsNullOrWhiteSpace($label)) { $label = "$($current.AutomationId)" }
    if ([string]::IsNullOrWhiteSpace($label)) { $label = Get-ElementText $Element }
    [pscustomobject]@{
      index = $Index
      label = $label
      name = $current.Name
      automationId = $current.AutomationId
      controlType = $controlTypeName
      className = $current.ClassName
      isEnabled = $current.IsEnabled
      isOffscreen = $current.IsOffscreen
      actions = $actions
      recommendedTool = Get-RecommendedTool $actions
      supportedPatterns = $patterns
      screenRect = (Convert-ElementRect $rect $WindowRect).screen
      windowRect = (Convert-ElementRect $rect $WindowRect).window
      screenCenter = (Convert-ElementRect $rect $WindowRect).center
      windowCenter = (Convert-ElementRect $rect $WindowRect).windowCenter
      source = $Source
    }
  } catch {
    return $null
  }
}

function Test-HighValueRawElement($Element, [bool]$IncludeOffscreen) {
  try {
    $current = $Element.Current
    if (!$current.IsEnabled) { return $false }
    if (!$IncludeOffscreen -and $current.IsOffscreen) { return $false }
    $rect = $current.BoundingRectangle
    if ($rect.Width -le 0 -or $rect.Height -le 0) { return $false }
  } catch {
    return $false
  }
  $role = Get-ControlTypeName $Element
  $patterns = @(Get-ElementPatterns $Element)
  if ($patterns -contains "Value" -or $patterns -contains "Invoke" -or $patterns -contains "SelectionItem" -or $patterns -contains "ExpandCollapse") { return $true }
  return $role -in @("Edit", "ComboBox", "Button", "Hyperlink", "MenuItem", "TabItem", "Document", "ListItem", "TreeItem", "DataItem")
}

function Add-RawHighValueTargets($Element, $Results, [ref]$RawIndex, [int]$MaxTargets, [bool]$IncludeOffscreen, $WindowRect, [int]$Depth) {
  if ($null -eq $Element -or $Results.Count -ge $MaxTargets -or $Depth -lt 0) { return }
  $currentRawIndex = $RawIndex.Value
  $RawIndex.Value += 1

  if (Test-HighValueRawElement $Element $IncludeOffscreen) {
    $target = New-ActionableTargetFromElement $Element ("raw:{0}" -f $currentRawIndex) $WindowRect "raw-view"
    if ($null -ne $target) { $Results.Add($target) | Out-Null }
  }

  try {
    $walker = [System.Windows.Automation.TreeWalker]::RawViewWalker
    $child = $walker.GetFirstChild($Element)
    while ($null -ne $child -and $Results.Count -lt $MaxTargets) {
      Add-RawHighValueTargets $child $Results $RawIndex $MaxTargets $IncludeOffscreen $WindowRect ($Depth - 1)
      $child = $walker.GetNextSibling($child)
    }
  } catch {}
}

function Get-RawHighValueTargets($Root, $WindowRect, [int]$MaxTargets, [bool]$IncludeOffscreen, [int]$Depth) {
  $results = New-Object System.Collections.ArrayList
  $rawIndex = 0
  Add-RawHighValueTargets $Root $results ([ref]$rawIndex) $MaxTargets $IncludeOffscreen $WindowRect $Depth
  return @($results)
}

function Add-UniqueTargets($Existing, $Additional, [int]$MaxTargets) {
  $results = New-Object System.Collections.ArrayList
  $seen = @{}
  foreach ($target in @($Existing + $Additional)) {
    if ($null -eq $target -or $results.Count -ge $MaxTargets) { continue }
    $label = "$($target.label)".ToLowerInvariant()
    $rect = $target.windowRect
    $key = "{0}|{1}|{2}|{3}|{4}|{5}" -f $target.controlType, $label, $rect.x, $rect.y, $rect.width, $rect.height
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = $true
    $results.Add($target) | Out-Null
  }
  return @($results)
}

function Test-BrowserProcess($Process) {
  if ($null -eq $Process) { return $false }
  $name = "$($Process.ProcessName)".ToLowerInvariant()
  return $name -in @("msedge", "chrome", "brave", "firefox", "opera", "vivaldi")
}

function Test-FileExplorerProcess($Process) {
  if ($null -eq $Process) { return $false }
  $name = "$($Process.ProcessName)".ToLowerInvariant()
  return $name -eq "explorer"
}

function New-SyntheticTarget($Index, $Label, $Role, $Tool, $Actions, $WindowRect, [int]$X, [int]$Y, [int]$Width, [int]$Height, $Meta) {
  $screenRect = [pscustomobject]@{
    x = [int]($WindowRect.x + $X)
    y = [int]($WindowRect.y + $Y)
    width = [int]$Width
    height = [int]$Height
  }
  [pscustomobject]@{
    index = $Index
    label = $Label
    name = $Label
    automationId = $Index
    controlType = $Role
    className = "SyntheticTarget"
    isEnabled = $true
    isOffscreen = $false
    actions = @($Actions)
    recommendedTool = $Tool
    supportedPatterns = @("Synthetic")
    screenRect = $screenRect
    windowRect = [pscustomobject]@{ x = [int]$X; y = [int]$Y; width = [int]$Width; height = [int]$Height }
    screenCenter = [pscustomobject]@{ x = [int]($screenRect.x + ($Width / 2)); y = [int]($screenRect.y + ($Height / 2)) }
    windowCenter = [pscustomobject]@{ x = [int]($X + ($Width / 2)); y = [int]($Y + ($Height / 2)) }
    source = "synthetic"
    meta = $Meta
  }
}

function Get-SyntheticTargets($Process, $WindowRect) {
  $targets = New-Object System.Collections.ArrayList

  if (Test-BrowserProcess $Process) {
    # Chromium/Firefox browser chrome is geometrically stable even when UIA hides
    # its toolbar Edit from ControlView. Expose it explicitly so models can use a
    # reliable target and a reliable shortcut-backed set_value path.
    $x = [Math]::Min(190, [Math]::Max(112, [int]($WindowRect.width * 0.14)))
    $rightReserve = [Math]::Min(260, [Math]::Max(160, [int]($WindowRect.width * 0.24)))
    $width = [Math]::Max(220, [int]($WindowRect.width - $x - $rightReserve))
    $targets.Add((New-SyntheticTarget "synthetic:browser-address-bar" "Address and search bar" "Edit" "set_value" @("click", "set_value", "type_text") $WindowRect $x 44 $width 32 "synthetic=browser-address-bar shortcut=ctrl+l confidence=geometry-fallback")) | Out-Null

    $contentY = 80
    if ($WindowRect.height -gt 180) {
      $targets.Add((New-SyntheticTarget "synthetic:browser-page" "Browser page content" "Document" "click" @("click", "scroll") $WindowRect 8 $contentY ([Math]::Max(1, $WindowRect.width - 16)) ([Math]::Max(1, $WindowRect.height - $contentY - 8)) "synthetic=browser-page confidence=geometry-fallback")) | Out-Null
    }
  }

  if (Test-FileExplorerProcess $Process) {
    # Explorer's address/search fields are stable chrome but often missing from
    # ControlView on recent Windows builds. Publish shortcut-backed targets so
    # agents can reliably navigate/search without trusting brittle tree order.
    $topY = 43
    $fieldHeight = 34
    $navWidth = [Math]::Min(190, [Math]::Max(132, [int]($WindowRect.width * 0.16)))
    $searchWidth = [Math]::Min(340, [Math]::Max(220, [int]($WindowRect.width * 0.26)))
    $rightMargin = 18
    $searchX = [Math]::Max(($navWidth + 180), [int]($WindowRect.width - $searchWidth - $rightMargin))
    $addressX = $navWidth
    $addressWidth = [Math]::Max(220, [int]($searchX - $addressX - 12))
    $targets.Add((New-SyntheticTarget "synthetic:file-explorer-address-bar" "File Explorer address bar" "Edit" "set_value" @("click", "set_value", "type_text") $WindowRect $addressX $topY $addressWidth $fieldHeight "synthetic=file-explorer-address-bar shortcut=alt+d confidence=geometry-fallback")) | Out-Null
    $targets.Add((New-SyntheticTarget "synthetic:file-explorer-search" "File Explorer search box" "Edit" "set_value" @("click", "set_value", "type_text") $WindowRect $searchX $topY $searchWidth $fieldHeight "synthetic=file-explorer-search shortcut=ctrl+f confidence=geometry-fallback")) | Out-Null
  }

  return @($targets)
}

function Resolve-SyntheticTarget($App, [string]$ElementIndex) {
  if (!$ElementIndex.StartsWith("synthetic:")) { return $null }
  $proc = Find-AppProcess $App
  if ($null -eq $proc) { throw "App not found: $App" }
  $rect = Get-WindowRectObject $proc
  $target = @(Get-SyntheticTargets $proc $rect | Where-Object { "$($_.index)" -eq $ElementIndex } | Select-Object -First 1)
  if ($target.Count -eq 0) { throw "Synthetic element index not found: $ElementIndex" }
  return $target[0]
}

function Get-ActionableElements($Tree, [int]$MaxTargets, [bool]$IncludeOffscreen) {
  $results = New-Object System.Collections.ArrayList
  Add-ActionableNodes $Tree $results $MaxTargets $IncludeOffscreen
  return @($results)
}

function Get-CompactLabel($Node) {
  foreach ($value in @($Node.name, $Node.automationId, $Node.text, $Node.className)) {
    $label = "$value".Trim()
    if (![string]::IsNullOrWhiteSpace($label)) {
      if ($label.Length -gt 160) { return $label.Substring(0, 157) + "..." }
      return $label
    }
  }
  return ""
}

function Test-MeaningfulCompactNode($Node, [bool]$IncludeOffscreen) {
  if ($null -eq $Node) { return $false }
  if (!$IncludeOffscreen -and $Node.isOffscreen) { return $false }
  if ($Node.rect.width -le 0 -or $Node.rect.height -le 0) { return $false }
  if ($Node.actions -and $Node.actions.Count -gt 0) { return $true }
  if ($Node.controlTypeName -in @("Window", "Document", "Edit", "ComboBox", "Tab", "TabItem", "ToolBar", "MenuBar", "List", "Tree", "DataGrid")) { return $true }
  $label = Get-CompactLabel $Node
  if ([string]::IsNullOrWhiteSpace($label)) { return $false }
  return $Node.controlTypeName -notin @("Pane", "Group", "Custom")
}

function Add-CompactTreeLines($Node, $Lines, [int]$Depth, [int]$MaxNodes, [bool]$IncludeOffscreen) {
  if ($null -eq $Node -or $Lines.Count -ge $MaxNodes) { return }
  if (Test-MeaningfulCompactNode $Node $IncludeOffscreen) {
    $label = Get-CompactLabel $Node
    $actionsText = ""
    if ($Node.actions -and $Node.actions.Count -gt 0) {
      $actionsText = " [" + (($Node.actions | Select-Object -First 4) -join ",") + "]"
    }
    $idText = ""
    if (![string]::IsNullOrWhiteSpace("$($Node.automationId)")) {
      $idText = " id=$($Node.automationId)"
    }
    $indent = " " * ([Math]::Min(12, $Depth * 2))
    $labelText = if ($label) { " " + $label } else { "" }
    $line = "{0}{1} {2}{3}{4} @{5},{6} {7}x{8}" -f $indent, $Node.index, $Node.controlTypeName, $actionsText, $labelText, $Node.bounds.window.x, $Node.bounds.window.y, $Node.bounds.window.width, $Node.bounds.window.height
    if ($idText) { $line += $idText }
    $Lines.Add($line) | Out-Null
  }
  foreach ($child in @($Node.children)) {
    if ($Lines.Count -ge $MaxNodes) { break }
    Add-CompactTreeLines $child $Lines ($Depth + 1) $MaxNodes $IncludeOffscreen
  }
}

function Get-CompactAccessibilityTree($Tree, [int]$MaxNodes, [bool]$IncludeOffscreen) {
  $lines = New-Object System.Collections.ArrayList
  Add-CompactTreeLines $Tree $lines 0 $MaxNodes $IncludeOffscreen
  return @($lines)
}

function Convert-CompactTarget($Target) {
  $id = "$($Target.automationId)"
  $className = "$($Target.className)"
  $extra = @()
  if (![string]::IsNullOrWhiteSpace($id)) { $extra += "id=$id" }
  if (![string]::IsNullOrWhiteSpace($className)) { $extra += "class=$className" }
  if (![string]::IsNullOrWhiteSpace("$($Target.source)")) { $extra += "source=$($Target.source)" }
  if (![string]::IsNullOrWhiteSpace("$($Target.meta)")) { $extra += "$($Target.meta)" }
  [pscustomobject]@{
    i = $Target.index
    role = $Target.controlType
    label = $Target.label
    tool = $Target.recommendedTool
    actions = @($Target.actions)
    screen = @($Target.screenCenter.x, $Target.screenCenter.y)
    window = @($Target.windowCenter.x, $Target.windowCenter.y)
    rect = @($Target.windowRect.x, $Target.windowRect.y, $Target.windowRect.width, $Target.windowRect.height)
    meta = $extra -join " "
  }
}

function Get-CompactTargets($Targets) {
  @($Targets | ForEach-Object { Convert-CompactTarget $_ })
}

function Get-AppState($InputArgs) {
  $timeoutMs = if ($InputArgs.timeoutMs -ne $null) { [Math]::Max(0, [Math]::Min(30000, [int]$InputArgs.timeoutMs)) } else { 0 }
  $includeIconData = if ($InputArgs.includeIconData -ne $null) { [bool]$InputArgs.includeIconData } else { $false }
  $proc = Find-AppProcess $InputArgs.app $timeoutMs
  if ($null -eq $proc) {
    return [pscustomobject]@{
      app = $InputArgs.app
      status = "not-found"
      timeoutMs = $timeoutMs
      screenshot = $null
      accessibilityTree = @()
      actionableElements = @()
    }
  }

  $rect = Get-WindowRectObject $proc
  $appDisplay = Get-AppDisplay $proc $includeIconData
  $root = [System.Windows.Automation.AutomationElement]::FromHandle($proc.MainWindowHandle)
  $index = 0
  $depth = if ($InputArgs.depth -ne $null) { [Math]::Max(0, [Math]::Min(10, [int]$InputArgs.depth)) } else { 4 }
  $maxActionable = if ($InputArgs.maxActionableElements -ne $null) { [Math]::Max(1, [Math]::Min(500, [int]$InputArgs.maxActionableElements)) } else { 120 }
  $maxTreeLines = if ($InputArgs.maxTreeLines -ne $null) { [Math]::Max(1, [Math]::Min(500, [int]$InputArgs.maxTreeLines)) } else { 160 }
  $compactOutput = if ($InputArgs.compact -ne $null) { [bool]$InputArgs.compact } else { $true }
  $includeRawTree = if ($InputArgs.includeRawAccessibilityTree -ne $null) { [bool]$InputArgs.includeRawAccessibilityTree } else { $false }
  $includeActionable = if ($InputArgs.includeActionableElements -ne $null) { [bool]$InputArgs.includeActionableElements } else { $true }
  $includeOffscreen = if ($InputArgs.includeOffscreen -ne $null) { [bool]$InputArgs.includeOffscreen } else { $false }
  $includeRawViewTargets = if ($InputArgs.includeRawViewTargets -ne $null) { [bool]$InputArgs.includeRawViewTargets } else { $true }
  $includeSyntheticTargets = if ($InputArgs.includeSyntheticTargets -ne $null) { [bool]$InputArgs.includeSyntheticTargets } else { $true }
  $tree = Convert-Element $root $depth ([ref]$index) $rect
  $screenshot = Save-WindowScreenshot $proc $InputArgs.includeCursor
  $actionable = @()
  $rawTargets = @()
  $syntheticTargets = @()
  if ($includeActionable) {
    $actionable = @(Get-ActionableElements $tree $maxActionable $includeOffscreen)
    if ($includeRawViewTargets) {
      $rawTargets = @(Get-RawHighValueTargets $root $rect $maxActionable $includeOffscreen ([Math]::Max(6, $depth + 4)))
    }
    if ($includeSyntheticTargets) {
      $syntheticTargets = @(Get-SyntheticTargets $proc $rect)
    }
    $actionable = @(Add-UniqueTargets $syntheticTargets (@($actionable) + @($rawTargets)) $maxActionable)
  }
  $returnedTree = if ($compactOutput) { @(Get-CompactAccessibilityTree $tree $maxTreeLines $includeOffscreen) } else { $tree }
  $returnedActionable = if ($compactOutput) { @(Get-CompactTargets $actionable) } else { $actionable }

  $result = [ordered]@{
    app = $InputArgs.app
    status = "found"
    appDisplay = $appDisplay
    window = [pscustomobject]@{
      name = $proc.ProcessName
      pid = $proc.Id
      title = $proc.MainWindowTitle
      handle = "0x{0:x}" -f $proc.MainWindowHandle.ToInt64()
      rect = $rect
    }
    screenshot = $screenshot
    accessibilityTree = $returnedTree
    actionableElements = $returnedActionable
    elementCount = $index
    scan = [pscustomobject]@{
      depth = $depth
      actionableCount = $actionable.Count
      rawViewTargetCount = $rawTargets.Count
      syntheticTargetCount = $syntheticTargets.Count
      maxActionableElements = $maxActionable
      treeFormat = if ($compactOutput) { "compact-lines" } else { "raw-tree" }
      maxTreeLines = $maxTreeLines
      includeOffscreen = $includeOffscreen
      includeRawViewTargets = $includeRawViewTargets
      includeSyntheticTargets = $includeSyntheticTargets
    }
  }
  if ($includeRawTree) {
    $result.rawAccessibilityTree = $tree
  }
  [pscustomobject]$result
}

function Dump-AppTargets($InputArgs) {
  $timeoutMs = if ($InputArgs.timeoutMs -ne $null) { [Math]::Max(0, [Math]::Min(30000, [int]$InputArgs.timeoutMs)) } else { 0 }
  $includeIconData = if ($InputArgs.includeIconData -ne $null) { [bool]$InputArgs.includeIconData } else { $false }
  $proc = Find-AppProcess $InputArgs.app $timeoutMs
  if ($null -eq $proc) {
    return [pscustomobject]@{
      app = $InputArgs.app
      status = "not-found"
      timeoutMs = $timeoutMs
      targets = @()
    }
  }

  $rect = Get-WindowRectObject $proc
  $appDisplay = Get-AppDisplay $proc $includeIconData
  $root = [System.Windows.Automation.AutomationElement]::FromHandle($proc.MainWindowHandle)
  $index = 0
  $depth = if ($InputArgs.depth -ne $null) { [Math]::Max(0, [Math]::Min(12, [int]$InputArgs.depth)) } else { 6 }
  $maxTargets = if ($InputArgs.maxTargets -ne $null) { [Math]::Max(1, [Math]::Min(800, [int]$InputArgs.maxTargets)) } else { 200 }
  $compactOutput = if ($InputArgs.compact -ne $null) { [bool]$InputArgs.compact } else { $true }
  $includeRawTargets = if ($InputArgs.includeRawTargets -ne $null) { [bool]$InputArgs.includeRawTargets } else { $false }
  $includeOffscreen = if ($InputArgs.includeOffscreen -ne $null) { [bool]$InputArgs.includeOffscreen } else { $false }
  $includeRawViewTargets = if ($InputArgs.includeRawViewTargets -ne $null) { [bool]$InputArgs.includeRawViewTargets } else { $true }
  $includeSyntheticTargets = if ($InputArgs.includeSyntheticTargets -ne $null) { [bool]$InputArgs.includeSyntheticTargets } else { $true }
  $tree = Convert-Element $root $depth ([ref]$index) $rect
  $targets = @(Get-ActionableElements $tree $maxTargets $includeOffscreen)
  $rawTargets = @()
  $syntheticTargets = @()
  if ($includeRawViewTargets) {
    $rawTargets = @(Get-RawHighValueTargets $root $rect $maxTargets $includeOffscreen ([Math]::Max(8, $depth + 4)))
  }
  if ($includeSyntheticTargets) {
    $syntheticTargets = @(Get-SyntheticTargets $proc $rect)
  }
  $targets = @(Add-UniqueTargets $syntheticTargets (@($targets) + @($rawTargets)) $maxTargets)
  $returnedTargets = if ($compactOutput) { @(Get-CompactTargets $targets) } else { $targets }

  $result = [ordered]@{
    app = $InputArgs.app
    status = "found"
    appDisplay = $appDisplay
    window = [pscustomobject]@{
      name = $proc.ProcessName
      pid = $proc.Id
      title = $proc.MainWindowTitle
      handle = "0x{0:x}" -f $proc.MainWindowHandle.ToInt64()
      rect = $rect
    }
    targetCount = $targets.Count
    elementCount = $index
    scan = [pscustomobject]@{
      depth = $depth
      maxTargets = $maxTargets
      includeOffscreen = $includeOffscreen
      rawViewTargetCount = $rawTargets.Count
      syntheticTargetCount = $syntheticTargets.Count
      includeRawViewTargets = $includeRawViewTargets
      includeSyntheticTargets = $includeSyntheticTargets
      targetFormat = if ($compactOutput) { "compact" } else { "raw" }
    }
    targets = $returnedTargets
  }
  if ($includeRawTargets) {
    $result.rawTargets = $targets
  }
  [pscustomobject]$result
}

function Save-WindowScreenshot($Process, $IncludeCursor) {
  $rect = Get-WindowRectObject $Process
  if ($rect.width -le 0 -or $rect.height -le 0) {
    return $null
  }

  Ensure-StateDir
  $file = Join-Path $StateDir ("screenshot-{0}-{1}.png" -f $Process.Id, ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()))
  $bitmap = New-Object System.Drawing.Bitmap $rect.width, $rect.height
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  try {
    $graphics.CopyFromScreen($rect.x, $rect.y, 0, 0, $bitmap.Size)
    if ($IncludeCursor) {
      $point = New-Object Win32ComputerUse+POINT
      [Win32ComputerUse]::GetCursorPos([ref]$point) | Out-Null
      if ($point.X -ge $rect.x -and $point.X -lt $rect.right -and $point.Y -ge $rect.y -and $point.Y -lt $rect.bottom) {
        $cursorRect = New-Object System.Drawing.Rectangle -ArgumentList ($point.X - $rect.x), ($point.Y - $rect.y), 32, 32
        [System.Windows.Forms.Cursors]::Default.Draw($graphics, $cursorRect)
      }
    }
    $bitmap.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
  } finally {
    $graphics.Dispose()
    $bitmap.Dispose()
  }

  [pscustomobject]@{
    path = $file
    width = $rect.width
    height = $rect.height
    coordinateSpace = "window-relative-pixels"
    screenOrigin = [pscustomobject]@{
      x = $rect.x
      y = $rect.y
    }
    screenRect = $rect
  }
}

function Resolve-InputPoint($InputArgs, [string]$DefaultApp = $null) {
  if ($InputArgs.x -eq $null -or $InputArgs.y -eq $null) {
    return $null
  }

  $rawX = [int][Math]::Round([double]$InputArgs.x)
  $rawY = [int][Math]::Round([double]$InputArgs.y)
  $space = if ($InputArgs.coordinateSpace -ne $null) { "$($InputArgs.coordinateSpace)".ToLowerInvariant() } else { "auto" }
  $app = if ($InputArgs.app -ne $null) { "$($InputArgs.app)" } else { $DefaultApp }

  if ($space -in @("screen", "screen-pixels", "absolute")) {
    return [pscustomobject]@{
      x = $rawX
      y = $rawY
      inputX = $rawX
      inputY = $rawY
      coordinateSpace = "screen"
      inferred = $false
      window = $null
    }
  }

  $rect = $null
  if (![string]::IsNullOrWhiteSpace($app)) {
    try {
      $proc = Find-AppProcess $app 0
      if ($null -ne $proc) { $rect = Get-WindowRectObject $proc }
    } catch {}
  }

  if ($space -in @("window", "window-relative", "window-relative-pixels", "screenshot", "screenshot-pixels")) {
    if ($null -eq $rect) {
      throw "coordinateSpace '$space' requires a visible app window."
    }
    return [pscustomobject]@{
      x = [int]($rect.x + $rawX)
      y = [int]($rect.y + $rawY)
      inputX = $rawX
      inputY = $rawY
      coordinateSpace = "window-relative"
      inferred = $false
      window = $rect
    }
  }

  if ($space -ne "auto") {
    throw "Unsupported coordinateSpace: $($InputArgs.coordinateSpace)"
  }

  if ($null -ne $rect) {
    $insideWindow = $rawX -ge $rect.x -and $rawX -lt $rect.right -and $rawY -ge $rect.y -and $rawY -lt $rect.bottom
    $insideWindowRelative = $rawX -ge 0 -and $rawY -ge 0 -and $rawX -le $rect.width -and $rawY -le $rect.height
    if (!$insideWindow -and $insideWindowRelative) {
      return [pscustomobject]@{
        x = [int]($rect.x + $rawX)
        y = [int]($rect.y + $rawY)
        inputX = $rawX
        inputY = $rawY
        coordinateSpace = "window-relative"
        inferred = $true
        window = $rect
      }
    }
  }

  [pscustomobject]@{
    x = $rawX
    y = $rawY
    inputX = $rawX
    inputY = $rawY
    coordinateSpace = "screen"
    inferred = $false
    window = $rect
  }
}

function Get-CurrentCursorPoint {
  $current = New-Object Win32ComputerUse+POINT
  [Win32ComputerUse]::GetCursorPos([ref]$current) | Out-Null
  [pscustomobject]@{
    x = [int]$current.X
    y = [int]$current.Y
  }
}

function Prepare-FakeCursorTravel($State, [bool]$Visible, [int]$TargetX, [int]$TargetY) {
  if (!$Visible) { return $null }

  $overlayPid = $null
  $wasVisible = [bool]$State.cursor.visible
  if (!$wasVisible) {
    if (!([bool]$State.cursor.hasPosition)) {
      $State.cursor.x = $TargetX
      $State.cursor.y = $TargetY
      $State.cursor.hasPosition = $true
    }
    $State.cursor.visible = $true
    $State.cursor.isPressed = $false
    Write-State $State
    $overlayPid = Start-FakeCursorOverlay $State
    Start-Sleep -Milliseconds 90
  } else {
    $overlayPid = Start-FakeCursorOverlay $State
  }

  $State.cursor.x = $TargetX
  $State.cursor.y = $TargetY
  $State.cursor.visible = $true
  $State.cursor.hasPosition = $true
  Write-State $State
  return $overlayPid
}

function Get-ShowFakeCursor($InputArgs) {
  if ($InputArgs.showFakeCursor -ne $null) { return [bool]$InputArgs.showFakeCursor }
  return $true
}

function Set-CursorStyleFromInput($State, $InputArgs) {
  if ($InputArgs.style -ne $null) {
    $State.cursor.style = Normalize-CursorStyle $InputArgs.style
  } else {
    $State.cursor.style = "software"
  }
}

function Set-FakeCursorPressed($State, [bool]$Pressed) {
  if (!$State.cursor.visible) { return }
  $State.cursor.isPressed = $Pressed
  if ($Pressed) {
    $State.cursor.clickPulseUntil = (Get-UnixMilliseconds) + 620
  }
  Write-State $State
}

function New-ClickLParam([int]$X, [int]$Y) {
  $packed = (($Y -band 0xffff) -shl 16) -bor ($X -band 0xffff)
  return [IntPtr]$packed
}

function New-WheelWParam([int]$Delta) {
  $packed = (($Delta -band 0xffff) -shl 16)
  return [IntPtr]$packed
}

function Invoke-WindowPointClick([int]$ScreenX, [int]$ScreenY, [string]$Button, [int]$Count) {
  $point = New-Object Win32ComputerUse+POINT
  $point.X = $ScreenX
  $point.Y = $ScreenY
  $hwnd = [Win32ComputerUse]::WindowFromPoint($point)
  if ($hwnd -eq [IntPtr]::Zero) {
    throw "No target window found at screen point $ScreenX,$ScreenY."
  }

  $clientPoint = New-Object Win32ComputerUse+POINT
  $clientPoint.X = $ScreenX
  $clientPoint.Y = $ScreenY
  [Win32ComputerUse]::ScreenToClient($hwnd, [ref]$clientPoint) | Out-Null
  $lParam = New-ClickLParam $clientPoint.X $clientPoint.Y

  $down = [uint32]$WindowMessages.LeftDown
  $up = [uint32]$WindowMessages.LeftUp
  $keyState = [IntPtr]$MouseKeyState.Left
  if ($Button -eq "right") {
    $down = [uint32]$WindowMessages.RightDown
    $up = [uint32]$WindowMessages.RightUp
    $keyState = [IntPtr]$MouseKeyState.Right
  }
  if ($Button -eq "middle") {
    $down = [uint32]$WindowMessages.MiddleDown
    $up = [uint32]$WindowMessages.MiddleUp
    $keyState = [IntPtr]$MouseKeyState.Middle
  }

  for ($i = 0; $i -lt $Count; $i++) {
    [Win32ComputerUse]::PostMessage($hwnd, $down, $keyState, $lParam) | Out-Null
    Start-Sleep -Milliseconds 80
    [Win32ComputerUse]::PostMessage($hwnd, $up, [IntPtr]::Zero, $lParam) | Out-Null
    Start-Sleep -Milliseconds 80
  }

  [pscustomobject]@{
    method = "post-message"
    hwnd = ("0x{0:x}" -f $hwnd.ToInt64())
    clientX = $clientPoint.X
    clientY = $clientPoint.Y
  }
}

function Invoke-WindowPointMouseMove([int]$ScreenX, [int]$ScreenY, [IntPtr]$KeyState = [IntPtr]::Zero) {
  $point = New-Object Win32ComputerUse+POINT
  $point.X = $ScreenX
  $point.Y = $ScreenY
  $hwnd = [Win32ComputerUse]::WindowFromPoint($point)
  if ($hwnd -eq [IntPtr]::Zero) {
    throw "No target window found at screen point $ScreenX,$ScreenY."
  }

  $clientPoint = New-Object Win32ComputerUse+POINT
  $clientPoint.X = $ScreenX
  $clientPoint.Y = $ScreenY
  [Win32ComputerUse]::ScreenToClient($hwnd, [ref]$clientPoint) | Out-Null
  $lParam = New-ClickLParam $clientPoint.X $clientPoint.Y
  [Win32ComputerUse]::PostMessage($hwnd, [uint32]$WindowMessages.MouseMove, $KeyState, $lParam) | Out-Null
  return $hwnd
}

function Try-InvokeElementClick($Element, [string]$Button, [int]$Count) {
  if ($Button -ne "left" -or $Count -ne 1) { return $false }
  try {
    $pattern = $Element.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
    if ($null -eq $pattern) { return $false }
    $pattern.Invoke()
    return $true
  } catch {
    return $false
  }
}

function Move-Cursor($InputArgs) {
  $focusedProcess = Focus-App $InputArgs.app
  $point = Resolve-InputPoint $InputArgs
  $state = Ensure-CursorShape (Read-State)
  $showFakeCursor = Get-ShowFakeCursor $InputArgs
  Set-CursorStyleFromInput $state $InputArgs
  if ($InputArgs.isPressed -ne $null) {
    $state.cursor.isPressed = [bool]$InputArgs.isPressed
    if ([bool]$InputArgs.isPressed) {
      $state.cursor.clickPulseUntil = (Get-UnixMilliseconds) + 620
    }
  }
  if ($InputArgs.debugFramePath -ne $null) {
    $state.cursor.debugFramePath = "$($InputArgs.debugFramePath)"
  }
  $overlayPid = Prepare-FakeCursorTravel $state $showFakeCursor $point.x $point.y
  if (!$showFakeCursor) {
    $state.cursor.visible = $false
    $state.cursor.x = $point.x
    $state.cursor.y = $point.y
    $state.cursor.hasPosition = $true
    Write-State $state
  }
  $presentationData = $null
  if ($null -ne $focusedProcess) {
    $displayName = (Get-AppDisplay $focusedProcess $false).name
    $presentationData = New-ActionPresentation "move_cursor" $focusedProcess ("Moved cursor in {0}" -f $displayName) ([pscustomobject]@{
      x = $point.x
      y = $point.y
      coordinateSpace = $point.coordinateSpace
      movedRealCursor = $false
    })
  }

  $result = [ordered]@{
    status = "ok"
    x = $point.x
    y = $point.y
    inputX = $point.inputX
    inputY = $point.inputY
    coordinateSpace = $point.coordinateSpace
    inferredCoordinateSpace = $point.inferred
    fakeCursorVisible = [bool]$state.cursor.visible
    style = $state.cursor.style
    isPressed = [bool]$state.cursor.isPressed
    overlayPid = $overlayPid
    focusedApp = if ($null -ne $focusedProcess) { $focusedProcess.ProcessName } else { $null }
    movedRealCursor = $false
  }
  if ($null -ne $presentationData) {
    $result.appDisplay = $presentationData.appDisplay
    $result.presentation = $presentationData.presentation
  }
  [pscustomobject]$result
}

function Click-At($InputArgs) {
  $focusedProcess = Focus-App $InputArgs.app
  $resolvedPoint = $null
  $element = $null
  if ($InputArgs.element_index -ne $null -and "$($InputArgs.element_index)" -ne "") {
    $elementIndex = "$($InputArgs.element_index)"
    if ($elementIndex.StartsWith("synthetic:")) {
      $synthetic = Resolve-SyntheticTarget $InputArgs.app $elementIndex
      $center = $synthetic.screenCenter
    } else {
      $element = Get-ElementByIndex $InputArgs.app $InputArgs.element_index
      $center = Get-ElementCenter $element
    }
    $InputArgs | Add-Member -NotePropertyName x -NotePropertyValue $center.x -Force
    $InputArgs | Add-Member -NotePropertyName y -NotePropertyValue $center.y -Force
    $InputArgs | Add-Member -NotePropertyName coordinateSpace -NotePropertyValue "screen" -Force
  }
  $state = Ensure-CursorShape (Read-State)
  $showFakeCursor = Get-ShowFakeCursor $InputArgs
  Set-CursorStyleFromInput $state $InputArgs
  $overlayPid = $null
  if ($InputArgs.x -ne $null -and $InputArgs.y -ne $null) {
    $resolvedPoint = Resolve-InputPoint $InputArgs "$($InputArgs.app)"
    $overlayPid = Prepare-FakeCursorTravel $state $showFakeCursor $resolvedPoint.x $resolvedPoint.y
    if ($showFakeCursor) {
      Start-Sleep -Milliseconds 260
    } else {
      $state.cursor.visible = $false
      $state.cursor.x = $resolvedPoint.x
      $state.cursor.y = $resolvedPoint.y
      $state.cursor.hasPosition = $true
      Write-State $state
    }
  }
  $button = if ($InputArgs.mouse_button) { "$($InputArgs.mouse_button)".ToLowerInvariant() } else { "left" }
  $count = if ($InputArgs.click_count) { [int]$InputArgs.click_count } else { 1 }
  $clickMethod = $null
  $clickDispatch = $null
  $invokedElement = $false
  if ($null -ne $element) {
    $invokedElement = Try-InvokeElementClick $element $button $count
  }
  for ($i = 0; $i -lt $count; $i++) {
    if ($state.cursor.visible) {
      if ($null -ne $resolvedPoint) {
        $state.cursor.x = $resolvedPoint.x
        $state.cursor.y = $resolvedPoint.y
        $state.cursor.hasPosition = $true
      }
      Set-FakeCursorPressed $state $true
    }
    if ($invokedElement) {
      $clickMethod = "uia-invoke"
    } elseif ($null -ne $resolvedPoint) {
      $clickDispatch = Invoke-WindowPointClick $resolvedPoint.x $resolvedPoint.y $button 1
      $clickMethod = $clickDispatch.method
    } else {
      throw "Click requires an element_index or coordinates."
    }
    if ($state.cursor.visible) {
      Set-FakeCursorPressed $state $false
    }
    Start-Sleep -Milliseconds 120
    if ($invokedElement) { break }
  }
  $resultX = $null
  $resultY = $null
  $resultInputX = $null
  $resultInputY = $null
  $resultCoordinateSpace = $null
  $resultInferredCoordinateSpace = $false
  if ($null -ne $resolvedPoint) {
    $resultX = $resolvedPoint.x
    $resultY = $resolvedPoint.y
    $resultInputX = $resolvedPoint.inputX
    $resultInputY = $resolvedPoint.inputY
    $resultCoordinateSpace = $resolvedPoint.coordinateSpace
    $resultInferredCoordinateSpace = $resolvedPoint.inferred
  }

  $presentationData = $null
  if ($null -ne $focusedProcess) {
    $displayName = (Get-AppDisplay $focusedProcess $false).name
    $presentationData = New-ActionPresentation "click" $focusedProcess ("Clicked in {0}" -f $displayName) ([pscustomobject]@{
      button = $button
      clickCount = $count
      x = $resultX
      y = $resultY
      coordinateSpace = $resultCoordinateSpace
      method = $clickMethod
      movedRealCursor = $false
    })
  }

  $result = [ordered]@{
    status = "ok"
    button = $button
    clickCount = $count
    x = $resultX
    y = $resultY
    inputX = $resultInputX
    inputY = $resultInputY
    coordinateSpace = $resultCoordinateSpace
    inferredCoordinateSpace = $resultInferredCoordinateSpace
    fakeCursorVisible = [bool]$state.cursor.visible
    style = $state.cursor.style
    overlayPid = $overlayPid
    method = $clickMethod
    dispatch = $clickDispatch
    movedRealCursor = $false
  }
  if ($null -ne $presentationData) {
    $result.appDisplay = $presentationData.appDisplay
    $result.presentation = $presentationData.presentation
  }
  [pscustomobject]$result
}

function Drag-Cursor($InputArgs) {
  $focusedProcess = Focus-App $InputArgs.app
  $fromX = [int]$InputArgs.from_x
  $fromY = [int]$InputArgs.from_y
  $toX = [int]$InputArgs.to_x
  $toY = [int]$InputArgs.to_y
  $state = Ensure-CursorShape (Read-State)
  $showFakeCursor = Get-ShowFakeCursor $InputArgs
  Set-CursorStyleFromInput $state $InputArgs
  $overlayPid = Prepare-FakeCursorTravel $state $showFakeCursor $fromX $fromY
  if ($showFakeCursor) {
    Start-Sleep -Milliseconds 220
    Set-FakeCursorPressed $state $true
    Start-Sleep -Milliseconds 60
  } else {
    $state.cursor.visible = $false
    $state.cursor.x = $fromX
    $state.cursor.y = $fromY
    $state.cursor.hasPosition = $true
    Write-State $state
  }
  $point = New-Object Win32ComputerUse+POINT
  $point.X = $fromX
  $point.Y = $fromY
  $hwnd = [Win32ComputerUse]::WindowFromPoint($point)
  if ($hwnd -eq [IntPtr]::Zero) {
    throw "No target window found at drag start $fromX,$fromY."
  }
  $clientPoint = New-Object Win32ComputerUse+POINT
  $clientPoint.X = $fromX
  $clientPoint.Y = $fromY
  [Win32ComputerUse]::ScreenToClient($hwnd, [ref]$clientPoint) | Out-Null
  $lParam = New-ClickLParam $clientPoint.X $clientPoint.Y
  [Win32ComputerUse]::PostMessage($hwnd, [uint32]$WindowMessages.LeftDown, [IntPtr]$MouseKeyState.Left, $lParam) | Out-Null
  Start-Sleep -Milliseconds 40
  $steps = 16
  for ($i = 1; $i -le $steps; $i++) {
    $x = [int]([double]$fromX + (([double]$toX - [double]$fromX) * $i / $steps))
    $y = [int]([double]$fromY + (([double]$toY - [double]$fromY) * $i / $steps))
    if ($state.cursor.visible) {
      $state.cursor.x = $x
      $state.cursor.y = $y
      $state.cursor.hasPosition = $true
      Write-State $state
    }
    Invoke-WindowPointMouseMove $x $y ([IntPtr]$MouseKeyState.Left) | Out-Null
    Start-Sleep -Milliseconds 12
  }
  $endPoint = New-Object Win32ComputerUse+POINT
  $endPoint.X = $toX
  $endPoint.Y = $toY
  [Win32ComputerUse]::ScreenToClient($hwnd, [ref]$endPoint) | Out-Null
  $endLParam = New-ClickLParam $endPoint.X $endPoint.Y
  [Win32ComputerUse]::PostMessage($hwnd, [uint32]$WindowMessages.LeftUp, [IntPtr]::Zero, $endLParam) | Out-Null
  Set-FakeCursorPressed $state $false

  $presentationData = $null
  if ($null -ne $focusedProcess) {
    $displayName = (Get-AppDisplay $focusedProcess $false).name
    $presentationData = New-ActionPresentation "drag" $focusedProcess ("Dragged in {0}" -f $displayName) ([pscustomobject]@{ from = @($fromX, $fromY); to = @($toX, $toY); movedRealCursor = $false })
  }

  $result = [ordered]@{ status = "ok"; from = @($fromX, $fromY); to = @($toX, $toY); method = "post-message"; fakeCursorVisible = [bool]$state.cursor.visible; style = $state.cursor.style; overlayPid = $overlayPid; movedRealCursor = $false }
  if ($null -ne $presentationData) {
    $result.appDisplay = $presentationData.appDisplay
    $result.presentation = $presentationData.presentation
  }
  [pscustomobject]$result
}

function Press-Key($InputArgs) {
  $focus = Focus-AppStrict "$($InputArgs.app)"
  $key = "$($InputArgs.key)"
  [System.Windows.Forms.SendKeys]::SendWait((Convert-KeyChord $key))
  Start-Sleep -Milliseconds 40
  $after = Get-ForegroundWindowInfo
  $presentationData = New-ActionPresentation "press_key" $focus.process ("Pressed key in {0}" -f (Get-AppDisplay $focus.process $false).name) ([pscustomobject]@{ key = $key })
  [pscustomobject]@{
    status = "ok"
    key = $key
    appDisplay = $presentationData.appDisplay
    presentation = $presentationData.presentation
    focus = [pscustomobject]@{
      verifiedBeforeSend = [bool]$focus.verified
      foregroundBeforeSend = $focus.foreground
      foregroundAfterSend = $after
      targetPid = $focus.process.Id
    }
  }
}

function Type-Text($InputArgs) {
  $focus = Focus-AppStrict "$($InputArgs.app)"
  $text = "$($InputArgs.text)"
  [System.Windows.Forms.SendKeys]::SendWait((Escape-SendKeysLiteral $text))
  Start-Sleep -Milliseconds 40
  $after = Get-ForegroundWindowInfo
  $preview = Get-PreviewText $text
  $presentationData = New-ActionPresentation "type_text" $focus.process ("Typed text `"{0}`" in {1}" -f $preview, (Get-AppDisplay $focus.process $false).name) ([pscustomobject]@{ textPreview = $preview; length = $text.Length })
  [pscustomobject]@{
    status = "ok"
    length = $text.Length
    textPreview = $preview
    appDisplay = $presentationData.appDisplay
    presentation = $presentationData.presentation
    focus = [pscustomobject]@{
      verifiedBeforeSend = [bool]$focus.verified
      foregroundBeforeSend = $focus.foreground
      foregroundAfterSend = $after
      targetPid = $focus.process.Id
    }
  }
}

function Escape-SendKeysLiteral([string]$Text) {
  # SendKeys treats these as syntax characters; braces escape them literally.
  $escaped = $Text
  foreach ($char in @("{", "}", "+", "^", "%", "~", "(", ")", "[", "]")) {
    $escaped = $escaped.Replace($char, "{$char}")
  }
  return $escaped
}

function Convert-KeyChord([string]$Key) {
  $value = $Key.Trim()
  $lower = $value.ToLowerInvariant()
  $lower = $lower.Replace("cmd+", "ctrl+").Replace("command+", "ctrl+")
  $parts = $lower -split "\+"
  $mods = ""
  $main = $parts[-1]
  if ($parts.Length -gt 1) {
    foreach ($part in $parts[0..($parts.Length - 2)]) {
      if ($part -eq "ctrl" -or $part -eq "control") { $mods += "^" }
      elseif ($part -eq "alt" -or $part -eq "option") { $mods += "%" }
      elseif ($part -eq "shift") { $mods += "+" }
    }
  }
  $special = @{
    "enter" = "{ENTER}"
    "return" = "{ENTER}"
    "escape" = "{ESC}"
    "esc" = "{ESC}"
    "tab" = "{TAB}"
    "backspace" = "{BACKSPACE}"
    "delete" = "{DELETE}"
    "up" = "{UP}"
    "down" = "{DOWN}"
    "left" = "{LEFT}"
    "right" = "{RIGHT}"
    "home" = "{HOME}"
    "end" = "{END}"
    "pagedown" = "{PGDN}"
    "pageup" = "{PGUP}"
  }
  if ($special.ContainsKey($main)) {
    return $mods + $special[$main]
  }
  return $mods + $main.ToUpperInvariant()
}

function Scroll-At($InputArgs) {
  $focusedProcess = Focus-App $InputArgs.app
  $center = $null
  if ($InputArgs.element_index -ne $null -and "$($InputArgs.element_index)" -ne "") {
    $elementIndex = "$($InputArgs.element_index)"
    if ($elementIndex.StartsWith("synthetic:")) {
      $synthetic = Resolve-SyntheticTarget $InputArgs.app $elementIndex
      $center = $synthetic.screenCenter
    } else {
      $element = Get-ElementByIndex $InputArgs.app $InputArgs.element_index
      $center = Get-ElementCenter $element
    }
  } else {
    throw "Scroll requires element_index so it can target a window without moving the user's cursor."
  }
  $pages = if ($InputArgs.pages) { [double]$InputArgs.pages } else { 1.0 }
  $direction = "$($InputArgs.direction)".ToLowerInvariant()
  $delta = [int](120 * $pages)
  if ($direction -eq "down" -or $direction -eq "right") { $delta = -$delta }
  $point = New-Object Win32ComputerUse+POINT
  $point.X = [int]$center.x
  $point.Y = [int]$center.y
  $hwnd = [Win32ComputerUse]::WindowFromPoint($point)
  if ($hwnd -eq [IntPtr]::Zero) {
    throw "No target window found at scroll point $($center.x),$($center.y)."
  }
  $state = Ensure-CursorShape (Read-State)
  $showFakeCursor = Get-ShowFakeCursor $InputArgs
  Set-CursorStyleFromInput $state $InputArgs
  $overlayPid = Prepare-FakeCursorTravel $state $showFakeCursor ([int]$center.x) ([int]$center.y)
  if ($showFakeCursor) {
    Start-Sleep -Milliseconds 180
  } else {
    $state.cursor.visible = $false
    $state.cursor.x = [int]$center.x
    $state.cursor.y = [int]$center.y
    $state.cursor.hasPosition = $true
    Write-State $state
  }
  $message = if ($direction -eq "left" -or $direction -eq "right") { [uint32]$WindowMessages.MouseHWheel } else { [uint32]$WindowMessages.MouseWheel }
  $wParam = New-WheelWParam $delta
  $lParam = New-ClickLParam ([int]$center.x) ([int]$center.y)
  [Win32ComputerUse]::PostMessage($hwnd, $message, $wParam, $lParam) | Out-Null
  if ($state.cursor.visible) {
    $state.cursor.clickPulseUntil = (Get-UnixMilliseconds) + 420
    Write-State $state
  }

  $presentationData = $null
  if ($null -ne $focusedProcess) {
    $displayName = (Get-AppDisplay $focusedProcess $false).name
    $presentationData = New-ActionPresentation "scroll" $focusedProcess ("Scrolled in {0}" -f $displayName) ([pscustomobject]@{ direction = $direction; pages = $pages; movedRealCursor = $false })
  }

  $result = [ordered]@{ status = "ok"; direction = $direction; pages = $pages; method = "post-message"; fakeCursorVisible = [bool]$state.cursor.visible; style = $state.cursor.style; overlayPid = $overlayPid; movedRealCursor = $false }
  if ($null -ne $presentationData) {
    $result.appDisplay = $presentationData.appDisplay
    $result.presentation = $presentationData.presentation
  }
  [pscustomobject]$result
}

function Perform-SecondaryAction($InputArgs) {
  Focus-App $InputArgs.app | Out-Null
  $element = Get-ElementByIndex $InputArgs.app $InputArgs.element_index
  $action = "$($InputArgs.action)".ToLowerInvariant()

  if ($action -eq "invoke" -or $action -eq "press" -or $action -eq "click") {
    $pattern = $element.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
    $pattern.Invoke()
    return [pscustomobject]@{ status = "ok"; action = "invoke"; element_index = "$($InputArgs.element_index)" }
  }
  if ($action -eq "toggle") {
    $pattern = $element.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
    $pattern.Toggle()
    return [pscustomobject]@{ status = "ok"; action = "toggle"; element_index = "$($InputArgs.element_index)" }
  }
  if ($action -eq "expand" -or $action -eq "collapse") {
    $pattern = $element.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
    if ($action -eq "expand") { $pattern.Expand() } else { $pattern.Collapse() }
    return [pscustomobject]@{ status = "ok"; action = $action; element_index = "$($InputArgs.element_index)" }
  }
  if ($action -eq "select") {
    $pattern = $element.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
    $pattern.Select()
    return [pscustomobject]@{ status = "ok"; action = "select"; element_index = "$($InputArgs.element_index)" }
  }

  throw "Unsupported secondary action: $($InputArgs.action)"
}

function Set-ElementValue($InputArgs) {
  $syntheticSetters = @{
    "synthetic:browser-address-bar" = @{
      shortcut = "^l"
      label = "address bar"
      displayShortcut = "ctrl+l"
    }
    "synthetic:file-explorer-address-bar" = @{
      shortcut = "%d"
      label = "File Explorer address bar"
      displayShortcut = "alt+d"
    }
    "synthetic:file-explorer-search" = @{
      shortcut = "^f"
      label = "File Explorer search box"
      displayShortcut = "ctrl+f"
    }
  }
  $elementIndex = "$($InputArgs.element_index)"
  if ($syntheticSetters.ContainsKey($elementIndex)) {
    $setter = $syntheticSetters[$elementIndex]
    $focus = Focus-AppStrict "$($InputArgs.app)"
    $value = "$($InputArgs.value)"
    [System.Windows.Forms.SendKeys]::SendWait($setter.shortcut)
    Start-Sleep -Milliseconds 40
    [System.Windows.Forms.SendKeys]::SendWait((Escape-SendKeysLiteral $value))
    Start-Sleep -Milliseconds 40
    $after = Get-ForegroundWindowInfo
    $preview = Get-PreviewText $value
    $presentationData = New-ActionPresentation "set_value" $focus.process ("Set {0} in {1}" -f $setter.label, (Get-AppDisplay $focus.process $false).name) ([pscustomobject]@{ element_index = $elementIndex; textPreview = $preview; length = $value.Length })
    return [pscustomobject]@{
      status = "ok"
      element_index = $elementIndex
      valueLength = $value.Length
      textPreview = $preview
      method = "shortcut"
      shortcut = $setter.displayShortcut
      appDisplay = $presentationData.appDisplay
      presentation = $presentationData.presentation
      focus = [pscustomobject]@{
        verifiedBeforeSend = [bool]$focus.verified
        foregroundBeforeSend = $focus.foreground
        foregroundAfterSend = $after
        targetPid = $focus.process.Id
      }
    }
  }

  Focus-App $InputArgs.app | Out-Null
  $element = Get-ElementByIndex $InputArgs.app $InputArgs.element_index
  $pattern = $element.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
  $pattern.SetValue("$($InputArgs.value)")
  [pscustomobject]@{ status = "ok"; element_index = "$($InputArgs.element_index)"; valueLength = "$($InputArgs.value)".Length }
}

function Invoke-BridgeCommand([string]$CommandName, $InputArgs) {
  switch ($CommandName) {
    "warmup" {
      Ensure-StateDir
      return [pscustomobject]@{
        status = "ok"
        bridge = "powershell-uia"
        persistent = [bool]$Server
        pid = $PID
        stateDir = $StateDir
      }
    }
    "status" {
    $state = Ensure-CursorShape (Read-State)
    return [pscustomobject]@{
      platform = "win32"
      bridge = "powershell-uia"
      persistent = [bool]$Server
      pid = $PID
      setupStatus = "not-run"
      isElevated = Test-IsElevated
      powershellVersion = "$($PSVersionTable.PSVersion)"
      is64BitProcess = [Environment]::Is64BitProcess
      stateDir = $StateDir
      overlayScript = $OverlayScript
      overlayAssetDir = $OverlayAssetDir
      fakeCursorOverlayAlive = Test-ProcessAlive $state.cursor.overlayPid
      fakeCursorOverlayPid = $state.cursor.overlayPid
    }
  }
  "setup-check" { return Get-SetupCheck }
  "list-apps" { return [pscustomobject]@{ apps = @(Get-VisibleApps) } }
  "get-app-state" { return Get-AppState $InputArgs }
  "dump-app-targets" { return Dump-AppTargets $InputArgs }
  "screenshot-window" {
    $timeoutMs = if ($InputArgs.timeoutMs -ne $null) { [Math]::Max(0, [Math]::Min(30000, [int]$InputArgs.timeoutMs)) } else { 0 }
    $proc = Find-AppProcess $InputArgs.app $timeoutMs
    if ($null -eq $proc) { return [pscustomobject]@{ status = "not-found"; app = $InputArgs.app; timeoutMs = $timeoutMs } }
    else {
      $includeIconData = if ($InputArgs.includeIconData -ne $null) { [bool]$InputArgs.includeIconData } else { $false }
      return [pscustomobject]@{ status = "ok"; app = $InputArgs.app; appDisplay = (Get-AppDisplay $proc $includeIconData); screenshot = (Save-WindowScreenshot $proc $InputArgs.includeCursor) }
    }
  }
  "move-cursor" { return Move-Cursor $InputArgs }
  "click" { return Click-At $InputArgs }
  "drag" { return Drag-Cursor $InputArgs }
  "press-key" { return Press-Key $InputArgs }
  "type-text" { return Type-Text $InputArgs }
  "scroll" { return Scroll-At $InputArgs }
  "perform-secondary-action" { return Perform-SecondaryAction $InputArgs }
  "set-value" { return Set-ElementValue $InputArgs }
  "show-fake-cursor" {
    $state = Ensure-CursorShape (Read-State)
    if ($InputArgs.x -ne $null) { $state.cursor.x = [int]$InputArgs.x }
    if ($InputArgs.y -ne $null) { $state.cursor.y = [int]$InputArgs.y }
    if ($InputArgs.style -ne $null) { $state.cursor.style = Normalize-CursorStyle $InputArgs.style } else { $state.cursor.style = "software" }
    if ($InputArgs.isPressed -ne $null) { $state.cursor.isPressed = [bool]$InputArgs.isPressed }
    if ($InputArgs.debugFramePath -ne $null) { $state.cursor.debugFramePath = "$($InputArgs.debugFramePath)" }
    $state.cursor.visible = $true
    $pidValue = Start-FakeCursorOverlay $state
    Write-State $state
    return [pscustomobject]@{ status = "ok"; visible = $true; style = $state.cursor.style; isPressed = [bool]$state.cursor.isPressed; overlayPid = $pidValue; overlayScript = $OverlayScript }
  }
  "hide-fake-cursor" {
    $state = Ensure-CursorShape (Read-State)
    Stop-FakeCursorOverlay $state
    return [pscustomobject]@{ status = "ok"; visible = $false; stopped = $true }
  }
  default { throw "Unsupported bridge command: $Command" }
  }
}

function Start-BridgeServer {
  [Console]::Out.WriteLine((ConvertTo-BridgeJson ([pscustomobject]@{ type = "ready"; bridge = "powershell-uia"; persistent = $true; pid = $PID })))
  [Console]::Out.Flush()

  while ($true) {
    $line = [Console]::In.ReadLine()
    if ($null -eq $line) { break }
    if ([string]::IsNullOrWhiteSpace($line)) { continue }

    $requestId = $null
    try {
      $request = $line | ConvertFrom-Json
      $requestId = $request.id
      $payload = if ($request.PSObject.Properties.Name -contains "payload") { $request.payload } else { [pscustomobject]@{} }
      $result = Invoke-BridgeCommand "$($request.command)" $payload
      [Console]::Out.WriteLine((ConvertTo-BridgeJson ([pscustomobject]@{ id = $requestId; ok = $true; result = $result })))
    } catch {
      [Console]::Out.WriteLine((ConvertTo-BridgeJson ([pscustomobject]@{
        id = $requestId
        ok = $false
        error = "$($_.Exception.Message)"
      })))
    }
    [Console]::Out.Flush()
  }
}

if ($Server) {
  Start-BridgeServer
  exit 0
}

if ([string]::IsNullOrWhiteSpace($Command)) {
  throw "Command is required unless -Server is supplied."
}

$argsObject = ConvertFrom-Payload
Write-Json (Invoke-BridgeCommand $Command $argsObject)
