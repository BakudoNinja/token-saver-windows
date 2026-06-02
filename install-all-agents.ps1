param(
    [string]$InstallRoot = "",
    [switch]$NoShortcut,
    [switch]$NoAutoAttach,
    [string]$CodexHome = "$env:USERPROFILE\.codex",
    [int]$MaxAutoAttachProjects = 25,
    [switch]$SkipAutoAttachContext,
    [switch]$DisableAutoAttachFallbackScan,
    [switch]$ForceAll,
    [string[]]$DetectedAgents = @()
)

function Test-TokenSaverCommand {
    param([string]$Name)
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Get-TokenSaverDetectedAgents {
    param([string]$TargetCodexHome)

    if (@($DetectedAgents).Count -gt 0) {
        return @($DetectedAgents)
    }

    $found = New-Object System.Collections.Generic.List[string]
    $codexHomeFull = [System.IO.Path]::GetFullPath($TargetCodexHome)
    if ((Test-Path -LiteralPath $codexHomeFull -PathType Container) -or (Test-TokenSaverCommand "codex")) {
        [void]$found.Add("Codex")
    }
    if ((Test-TokenSaverCommand "claude") -or (Test-Path -LiteralPath (Join-Path $env:USERPROFILE ".claude") -PathType Container)) {
        [void]$found.Add("Claude")
    }
    $cursorCandidates = @(
        (Join-Path $env:LOCALAPPDATA "Programs\Cursor\Cursor.exe"),
        (Join-Path $env:LOCALAPPDATA "Cursor"),
        (Join-Path $env:APPDATA "Cursor")
    )
    if ((Test-TokenSaverCommand "cursor") -or (@($cursorCandidates | Where-Object { Test-Path -LiteralPath $_ }).Count -gt 0)) {
        [void]$found.Add("Cursor")
    }
    if ((Test-TokenSaverCommand "aider") -or (Test-TokenSaverCommand "aider-chat")) {
        [void]$found.Add("Aider")
    }
    return @($found.ToArray())
}

$allAgents = @("Codex", "Claude", "Cursor", "Aider", "Generic")
$selectedAgents = if ($ForceAll) { $allAgents } else { @(Get-TokenSaverDetectedAgents -TargetCodexHome $CodexHome) }
if (@($selectedAgents).Count -eq 0) {
    $selectedAgents = @("Codex")
}
$skippedAgents = @($allAgents | Where-Object { @($selectedAgents) -notcontains $_ })

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$argsList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $scriptRoot "install.ps1"), "-Agents", ($selectedAgents -join ","))
if (-not [string]::IsNullOrWhiteSpace($InstallRoot)) { $argsList += @("-InstallRoot", $InstallRoot) }
if ($NoShortcut) { $argsList += "-NoShortcut" }
if ($NoAutoAttach) { $argsList += "-NoAutoAttach" }
if (-not [string]::IsNullOrWhiteSpace($CodexHome)) { $argsList += @("-CodexHome", $CodexHome) }
$argsList += @("-MaxAutoAttachProjects", $MaxAutoAttachProjects)
if ($SkipAutoAttachContext) { $argsList += "-SkipAutoAttachContext" }
if ($DisableAutoAttachFallbackScan) { $argsList += "-DisableAutoAttachFallbackScan" }
$result = & powershell @argsList | ConvertFrom-Json
$result | Add-Member -NotePropertyName allAgentsMode -NotePropertyValue ([PSCustomObject]@{
    forceAll = [bool]$ForceAll
    appliedAgents = @($selectedAgents)
    skippedAgents = @($skippedAgents)
}) -Force
$result | ConvertTo-Json -Depth 12
