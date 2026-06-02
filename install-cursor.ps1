param(
    [string]$InstallRoot = "",
    [switch]$NoShortcut,
    [switch]$NoAutoAttach,
    [string]$CodexHome = "$env:USERPROFILE\.codex",
    [int]$MaxAutoAttachProjects = 25,
    [switch]$SkipAutoAttachContext,
    [switch]$DisableAutoAttachFallbackScan
)

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$argsList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $scriptRoot "install.ps1"), "-Agents", "Cursor")
if (-not [string]::IsNullOrWhiteSpace($InstallRoot)) { $argsList += @("-InstallRoot", $InstallRoot) }
if ($NoShortcut) { $argsList += "-NoShortcut" }
if ($NoAutoAttach) { $argsList += "-NoAutoAttach" }
if (-not [string]::IsNullOrWhiteSpace($CodexHome)) { $argsList += @("-CodexHome", $CodexHome) }
$argsList += @("-MaxAutoAttachProjects", $MaxAutoAttachProjects)
if ($SkipAutoAttachContext) { $argsList += "-SkipAutoAttachContext" }
if ($DisableAutoAttachFallbackScan) { $argsList += "-DisableAutoAttachFallbackScan" }
& powershell @argsList
