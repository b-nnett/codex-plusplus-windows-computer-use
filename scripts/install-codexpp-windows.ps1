param(
  [string]$SourceRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
  [string]$TweakId = "co.bennett.windows-computer-use"
)

$ErrorActionPreference = "Stop"

if (-not $IsWindows -and $env:OS -ne "Windows_NT") {
  throw "Windows Computer Use must be installed from Windows."
}

$targetRoot = Join-Path $env:APPDATA "codex-plusplus\tweaks\$TweakId"
$configPath = Join-Path $env:USERPROFILE ".codex\config.toml"
$serverPath = Join-Path $targetRoot "mcp-server.js"
$localPluginsRoot = Join-Path $env:USERPROFILE ".codex\local-plugins"
$pluginSourceRoot = Join-Path $localPluginsRoot "plugins\computer"
$marketplacePath = Join-Path $localPluginsRoot ".agents\plugins\marketplace.json"
$pluginCacheRoot = Join-Path $env:USERPROFILE ".codex\plugins\cache\bennett-local\computer"

function Set-Utf8NoBom {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [string]$Value
  )

  $encoding = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Value, $encoding)
}

$existingBridge = Join-Path $targetRoot "scripts\windows-bridge.ps1"
if (Test-Path $existingBridge) {
  try {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $existingBridge -Command hide-fake-cursor | Out-Null
    Start-Sleep -Milliseconds 250
  } catch {}
}
Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -like "*fake-cursor-overlay.ps1*" -and $_.CommandLine -like "*$TweakId*" } |
  ForEach-Object {
    try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch {}
  }
Start-Sleep -Milliseconds 250

New-Item -ItemType Directory -Force (Split-Path $targetRoot) | Out-Null
Remove-Item -Recurse -Force $targetRoot -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $targetRoot | Out-Null

$exclude = @(".git", "node_modules", ".DS_Store")
Get-ChildItem -LiteralPath $SourceRoot -Force | Where-Object {
  $exclude -notcontains $_.Name
} | ForEach-Object {
  Copy-Item -LiteralPath $_.FullName -Destination $targetRoot -Recurse -Force
}

New-Item -ItemType Directory -Force $pluginSourceRoot | Out-Null
Remove-Item -Recurse -Force $pluginSourceRoot -ErrorAction SilentlyContinue
Copy-Item -LiteralPath (Join-Path $targetRoot "codex-plugin") -Destination $pluginSourceRoot -Recurse -Force

$pluginManifestPath = Join-Path $pluginSourceRoot ".codex-plugin\plugin.json"
$pluginManifest = Get-Content -LiteralPath $pluginManifestPath -Raw | ConvertFrom-Json
$pluginVersion = [string]$pluginManifest.version
if (-not $pluginVersion) {
  throw "Plugin manifest is missing version."
}

$pluginCacheVersionRoot = Join-Path $pluginCacheRoot $pluginVersion
New-Item -ItemType Directory -Force $pluginCacheRoot | Out-Null
Remove-Item -Recurse -Force $pluginCacheVersionRoot -ErrorAction SilentlyContinue
Copy-Item -LiteralPath $pluginSourceRoot -Destination $pluginCacheVersionRoot -Recurse -Force

New-Item -ItemType Directory -Force (Split-Path $marketplacePath) | Out-Null
$computerPluginEntry = [ordered]@{
  name = "computer"
  source = [ordered]@{
    source = "local"
    path = "./plugins/computer"
  }
  policy = [ordered]@{
    installation = "AVAILABLE"
    authentication = "ON_INSTALL"
  }
  category = "Productivity"
}

if (Test-Path $marketplacePath) {
  try {
    $marketplace = Get-Content -LiteralPath $marketplacePath -Raw | ConvertFrom-Json
  } catch {
    $marketplace = $null
  }
}

if (-not $marketplace) {
  $marketplace = [pscustomobject]@{
    name = "bennett-local"
    interface = [pscustomobject]@{
      displayName = "Bennett Local"
    }
    plugins = @()
  }
}

$marketplace.name = "bennett-local"
if (-not $marketplace.interface) {
  $marketplace | Add-Member -MemberType NoteProperty -Name interface -Value ([pscustomobject]@{}) -Force
}
$marketplace.interface | Add-Member -MemberType NoteProperty -Name displayName -Value "Bennett Local" -Force

$plugins = @($marketplace.plugins | Where-Object { $_.name -ne "computer" })
$plugins += [pscustomobject]$computerPluginEntry
$marketplace | Add-Member -MemberType NoteProperty -Name plugins -Value $plugins -Force
Set-Utf8NoBom -Path $marketplacePath -Value ($marketplace | ConvertTo-Json -Depth 12)

$approvalEntries = @"
[mcp_servers.windows-computer-use.tools.click]
approval_mode = "approve"

[mcp_servers.windows-computer-use.tools.press_key]
approval_mode = "approve"

"@

$literalLocalPluginsRoot = "\\?\$localPluginsRoot"
$marketplaceConfigEntry = @"
[marketplaces.bennett-local]
last_updated = "$((Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ"))"
source_type = "local"
source = '$literalLocalPluginsRoot'

"@

$pluginConfigEntry = @"
[plugins."computer@bennett-local"]
enabled = true

"@

New-Item -ItemType Directory -Force (Split-Path $configPath) | Out-Null
$escapedServerPath = $serverPath.Replace("\", "\\")
$entry = @"
[mcp_servers.windows-computer-use]
command = "node"
args = ["$escapedServerPath"]

"@

$configText = if (Test-Path $configPath) { Get-Content -LiteralPath $configPath -Raw } else { "" }
$pattern = "(?ms)^\[mcp_servers\.windows-computer-use\][\s\S]*?(?=^\[(?!mcp_servers\.windows-computer-use\.tools\.)|\z)"
if ($configText -match "(?m)^\[mcp_servers\.windows-computer-use\]\s*$") {
  $configText = [regex]::Replace($configText, $pattern, "$entry$approvalEntries")
} else {
  $configText = "$configText`r`n$entry$approvalEntries"
}

$marketplacePattern = "(?ms)^\[marketplaces\.bennett-local\][\s\S]*?(?=^\[|\z)"
if ($configText -match "(?m)^\[marketplaces\.bennett-local\]\s*$") {
  $configText = [regex]::Replace($configText, $marketplacePattern, $marketplaceConfigEntry)
} else {
  $configText = "$configText`r`n$marketplaceConfigEntry"
}

$pluginPattern = '(?ms)^\[plugins\."computer@bennett-local"\][\s\S]*?(?=^\[|\z)'
if ($configText -match '(?m)^\[plugins\."computer@bennett-local"\]\s*$') {
  $configText = [regex]::Replace($configText, $pluginPattern, $pluginConfigEntry)
} else {
  $configText = "$configText`r`n$pluginConfigEntry"
}

Set-Utf8NoBom -Path $configPath -Value $configText

[pscustomobject]@{
  status = "ok"
  target = $targetRoot
  server = $serverPath
  serverExists = Test-Path $serverPath
  plugin = $pluginSourceRoot
  pluginExists = Test-Path (Join-Path $pluginSourceRoot ".codex-plugin\plugin.json")
  pluginCache = $pluginCacheVersionRoot
  pluginCacheExists = Test-Path (Join-Path $pluginCacheVersionRoot ".codex-plugin\plugin.json")
  marketplace = $marketplacePath
  config = $configPath
  configHasServer = ((Get-Content -LiteralPath $configPath -Raw) -match "(?m)^\[mcp_servers\.windows-computer-use\]\s*$")
  configHasPlugin = ((Get-Content -LiteralPath $configPath -Raw) -match "(?m)^\[plugins\.`"computer@bennett-local`"\]\s*$")
}
