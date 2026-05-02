param(
  [string]$TaskName = "CodexWCUVisualTest",
  [string]$VisualScriptName = "visual-test-windows.ps1",
  [string]$OutDir = "$env:TEMP\wcu-visual-test",
  [int]$TimeoutSeconds = 45,
  [switch]$Highest
)

$ErrorActionPreference = "Stop"

$RootDir = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
if ([System.IO.Path]::IsPathRooted($VisualScriptName)) {
  $VisualScript = $VisualScriptName
} else {
  $VisualScript = Join-Path (Join-Path $RootDir "scripts") $VisualScriptName
}

if ($env:OS -ne "Windows_NT") {
  throw "This launcher must be run on Windows."
}

if (!(Test-Path $VisualScript)) {
  throw "Visual test script not found: $VisualScript"
}

Remove-Item -Recurse -Force $OutDir -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

$taskOutput = Join-Path $OutDir "task-output.txt"
$taskError = Join-Path $OutDir "task-error.txt"
$taskEntry = Join-Path $OutDir "task-entry.ps1"
$entry = @"
`$ErrorActionPreference = "Stop"
try {
  & "$VisualScript" -OutDir "$OutDir" 6>&1 5>&1 4>&1 3>&1 2>&1 | Tee-Object -FilePath "$taskOutput"
  exit 0
} catch {
  "ERROR: `$(`$_.Exception.Message)" | Out-File -FilePath "$taskError" -Encoding UTF8
  `$_.Exception | Format-List * -Force | Out-File -FilePath "$taskError" -Encoding UTF8 -Append
  `$_.ScriptStackTrace | Out-File -FilePath "$taskError" -Encoding UTF8 -Append
  exit 1
}
"@
$entry | Set-Content -Path $taskEntry -Encoding UTF8
$argument = "-WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File `"$taskEntry`""
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $argument
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1)
$identityName = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
if ([string]::IsNullOrWhiteSpace($identityName)) {
  $identityName = (whoami).Trim()
}
$runLevel = if ($Highest) { "Highest" } else { "Limited" }
$principal = New-ScheduledTaskPrincipal -UserId $identityName -LogonType Interactive -RunLevel $runLevel

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$reportPath = Join-Path $OutDir "visual-report.json"
do {
  Start-Sleep -Milliseconds 500
  $info = Get-ScheduledTaskInfo -TaskName $TaskName
  if (Test-Path $reportPath) {
    break
  }
} while ((Get-Date) -lt $deadline)

$result = [pscustomobject]@{
  taskName = $TaskName
  outDir = $OutDir
  reportPath = $reportPath
  taskOutput = $taskOutput
  taskError = $taskError
  taskEntry = $taskEntry
  reportExists = Test-Path $reportPath
  runLevel = $runLevel
  identityName = $identityName
  files = @(Get-ChildItem -Path $OutDir -ErrorAction SilentlyContinue | Select-Object Name, Length, LastWriteTime)
  taskInfo = Get-ScheduledTaskInfo -TaskName $TaskName
}

$result | ConvertTo-Json -Depth 16
