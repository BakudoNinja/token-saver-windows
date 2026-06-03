param(
    [string]$InstallRoot = "",
    [switch]$RemoveData,
    [switch]$KeepGlobalAgents,
    [switch]$KeepProjectData
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
    $base = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $env:USERPROFILE "AppData\Local" }
    $InstallRoot = Join-Path $base "TokenUsageHelper"
}

$installRootFull = [System.IO.Path]::GetFullPath($InstallRoot)
$expectedBase = if ($env:LOCALAPPDATA) { [System.IO.Path]::GetFullPath($env:LOCALAPPDATA) } else { [System.IO.Path]::GetFullPath((Join-Path $env:USERPROFILE "AppData\Local")) }
$defaultInstallRoot = [System.IO.Path]::GetFullPath((Join-Path $expectedBase "TokenUsageHelper"))
$isDefaultArea = $installRootFull.TrimEnd('\') -ieq $defaultInstallRoot.TrimEnd('\')

if (-not $isDefaultArea -and -not $RemoveData) {
    throw "Refusing to remove a non-default install root without -RemoveData: $installRootFull"
}

$manifestPath = Join-Path $installRootFull "install-manifest.json"
$manifest = $null
$desktopPath = [Environment]::GetFolderPath("Desktop")
$shortcutPath = Join-Path $desktopPath "Token saver.lnk"
$programsPath = [Environment]::GetFolderPath("Programs")
$startMenuShortcutPath = if ([string]::IsNullOrWhiteSpace($programsPath)) { "" } else { Join-Path (Join-Path $programsPath "Token saver") "Token saver.lnk" }
if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        if ($manifest.PSObject.Properties.Name -contains "shortcutPath" -and -not [string]::IsNullOrWhiteSpace([string]$manifest.shortcutPath)) {
            $shortcutPath = [string]$manifest.shortcutPath
        }
        if ($manifest.PSObject.Properties.Name -contains "startMenuShortcutPath" -and -not [string]::IsNullOrWhiteSpace([string]$manifest.startMenuShortcutPath)) {
            $startMenuShortcutPath = [string]$manifest.startMenuShortcutPath
        }
    }
    catch {
        $manifest = $null
    }
}

function Remove-TokenSaverAgentsBlock {
    param([object]$Manifest)

    if ($KeepGlobalAgents) {
        return $false
    }

    $agentsPath = ""
    if ($null -ne $Manifest -and $Manifest.PSObject.Properties.Name -contains "autoAttach" -and $null -ne $Manifest.autoAttach) {
        $agentsPath = [string]($Manifest.autoAttach.agentsPath)
    }
    if ([string]::IsNullOrWhiteSpace($agentsPath) -and $null -ne $Manifest -and $Manifest.PSObject.Properties.Name -contains "codexHome") {
        $agentsPath = Join-Path ([string]$Manifest.codexHome) "AGENTS.md"
    }
    if ([string]::IsNullOrWhiteSpace($agentsPath)) {
        $agentsPath = Join-Path "$env:USERPROFILE\.codex" "AGENTS.md"
    }
    if (-not (Test-Path -LiteralPath $agentsPath -PathType Leaf)) {
        return $false
    }

    $raw = Get-Content -LiteralPath $agentsPath -Raw
    $pattern = '(?s)\r?\n?<!-- BEGIN TOKEN SAVER AUTO ATTACH -->.*?<!-- END TOKEN SAVER AUTO ATTACH -->\r?\n?'
    $next = [regex]::Replace($raw, $pattern, [Environment]::NewLine).TrimEnd() + [Environment]::NewLine
    if ($next -ne $raw) {
        Set-Content -LiteralPath $agentsPath -Value $next -Encoding UTF8
        return $true
    }
    return $false
}

function Remove-TokenSaverBlockFromRuleFile {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }
    $raw = Get-Content -LiteralPath $Path -Raw
    $pattern = '(?s)\r?\n?<!-- BEGIN TOKEN SAVER AUTO ATTACH -->.*?<!-- END TOKEN SAVER AUTO ATTACH -->\r?\n?'
    $next = [regex]::Replace($raw, $pattern, [Environment]::NewLine).TrimEnd()
    if ($next.Length -gt 0) {
        $next = $next + [Environment]::NewLine
    }
    if ($next -ne $raw) {
        if ([string]::IsNullOrWhiteSpace($next)) {
            Remove-Item -LiteralPath $Path -Force
        }
        else {
            Set-Content -LiteralPath $Path -Value $next -Encoding UTF8
        }
        return $true
    }
    return $false
}

function Remove-TokenSaverAgentRuleFiles {
    param([object]$Manifest)

    $removed = New-Object System.Collections.Generic.List[string]
    if ($KeepGlobalAgents -or $null -eq $Manifest -or -not ($Manifest.PSObject.Properties.Name -contains "autoAttach") -or $null -eq $Manifest.autoAttach) {
        return @($removed.ToArray())
    }

    foreach ($rule in @($Manifest.autoAttach.agentRuleFiles)) {
        $path = [string](Get-TuhManifestProp -Object $rule -Name "path")
        if (Remove-TokenSaverBlockFromRuleFile -Path $path) {
            if (@($removed.ToArray()) -notcontains $path) {
                [void]$removed.Add($path)
            }
        }
    }
    foreach ($project in @($Manifest.autoAttach.attachedProjects)) {
        foreach ($rule in @($project.agentRuleFiles)) {
            $path = [string](Get-TuhManifestProp -Object $rule -Name "path")
            if (Remove-TokenSaverBlockFromRuleFile -Path $path) {
                if (@($removed.ToArray()) -notcontains $path) {
                    [void]$removed.Add($path)
                }
            }
        }
    }

    return @($removed.ToArray())
}

function Get-TuhManifestProp {
    param(
        [object]$Object,
        [string]$Name
    )
    if ($null -eq $Object -or -not ($Object.PSObject.Properties.Name -contains $Name)) {
        return ""
    }
    return $Object.$Name
}

function Remove-TokenSaverAutoAttachedProjectFiles {
    param([object]$Manifest)

    $removed = New-Object System.Collections.Generic.List[string]
    if ($KeepProjectData -or $null -eq $Manifest -or -not ($Manifest.PSObject.Properties.Name -contains "autoAttach") -or $null -eq $Manifest.autoAttach) {
        return @($removed.ToArray())
    }

    foreach ($project in @($Manifest.autoAttach.attachedProjects)) {
        $codexDirRaw = ""
        if ($project.PSObject.Properties.Name -contains "codexDir") {
            $codexDirRaw = [string]$project.codexDir
        }
        if ([string]::IsNullOrWhiteSpace($codexDirRaw)) {
            $projectPathRaw = ""
            if ($project.PSObject.Properties.Name -contains "projectPath") {
                $projectPathRaw = [string]$project.projectPath
            }
            if ([string]::IsNullOrWhiteSpace($projectPathRaw)) {
                continue
            }
            $codexDirRaw = Join-Path $projectPathRaw ".codex"
        }
        try {
            $codexDir = [System.IO.Path]::GetFullPath($codexDirRaw)
        }
        catch {
            continue
        }
        if (-not (Test-Path -LiteralPath $codexDir -PathType Container)) {
            continue
        }

        $preExisting = @{}
        foreach ($name in @($project.preExistingFiles)) {
            $preExisting[[string]$name] = $true
        }
        $managedFiles = if ($project.PSObject.Properties.Name -contains "managedFiles" -and @($project.managedFiles).Count -gt 0) {
            @($project.managedFiles)
        }
        else {
            @("config.json", "state.json", "context.md", "stats.json")
        }

        foreach ($nameObj in $managedFiles) {
            $name = [string]$nameObj
            if ([string]::IsNullOrWhiteSpace($name) -or $preExisting.ContainsKey($name)) {
                continue
            }
            $target = Join-Path $codexDir $name
            try {
                $targetFull = [System.IO.Path]::GetFullPath($target)
                $codexPrefix = $codexDir.TrimEnd('\') + "\"
                if (-not $targetFull.ToLowerInvariant().StartsWith($codexPrefix.ToLowerInvariant())) {
                    continue
                }
                if (Test-Path -LiteralPath $targetFull -PathType Leaf) {
                    Remove-Item -LiteralPath $targetFull -Force
                    [void]$removed.Add($targetFull)
                }
            }
            catch {
            }
        }

        try {
            $remaining = @(Get-ChildItem -LiteralPath $codexDir -Force -ErrorAction SilentlyContinue)
            $codexDirExisted = $true
            if ($project.PSObject.Properties.Name -contains "codexDirExisted") {
                $codexDirExisted = [bool]$project.codexDirExisted
            }
            if (-not $codexDirExisted -and $remaining.Count -eq 0) {
                Remove-Item -LiteralPath $codexDir -Force
                [void]$removed.Add($codexDir)
            }
        }
        catch {
        }
    }

    return @($removed.ToArray())
}

$removedAgentsBlock = Remove-TokenSaverAgentsBlock -Manifest $manifest
$removedAgentRuleFiles = @(Remove-TokenSaverAgentRuleFiles -Manifest $manifest)
$removedProjectFiles = @(Remove-TokenSaverAutoAttachedProjectFiles -Manifest $manifest)

$removedShortcuts = New-Object System.Collections.Generic.List[string]
$legacyShortcutPath = Join-Path $desktopPath "Token Usage Helper.lnk"
$legacyStartMenuShortcutPath = if ([string]::IsNullOrWhiteSpace($programsPath)) { "" } else { Join-Path (Join-Path $programsPath "Token saver") "Token Usage Helper.lnk" }
foreach ($candidateShortcut in @($shortcutPath, $startMenuShortcutPath, $legacyShortcutPath, $legacyStartMenuShortcutPath)) {
    if (-not [string]::IsNullOrWhiteSpace($candidateShortcut) -and (Test-Path -LiteralPath $candidateShortcut -PathType Leaf)) {
        Remove-Item -LiteralPath $candidateShortcut -Force
        [void]$removedShortcuts.Add($candidateShortcut)
    }
}
if (-not [string]::IsNullOrWhiteSpace($programsPath)) {
    $startMenuDir = Join-Path $programsPath "Token saver"
    if ((Test-Path -LiteralPath $startMenuDir -PathType Container) -and @((Get-ChildItem -LiteralPath $startMenuDir -Force -ErrorAction SilentlyContinue)).Count -eq 0) {
        Remove-Item -LiteralPath $startMenuDir -Force
    }
}

$bin = Join-Path $installRootFull "bin"
if (Test-Path -LiteralPath $bin -PathType Container) {
    Remove-Item -LiteralPath $bin -Recurse -Force
}

if ($RemoveData) {
    if (Test-Path -LiteralPath $installRootFull -PathType Container) {
        Remove-Item -LiteralPath $installRootFull -Recurse -Force
    }
}
else {
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        Remove-Item -LiteralPath $manifestPath -Force
    }
}

[PSCustomObject]@{
    ok = $true
    installRoot = $installRootFull
    removedData = [bool]$RemoveData
    removedShortcut = $shortcutPath
    removedShortcuts = @($removedShortcuts.ToArray())
    removedAgentsBlock = [bool]$removedAgentsBlock
    removedAgentRuleFileCount = $removedAgentRuleFiles.Count
    removedAgentRuleFiles = @($removedAgentRuleFiles)
    removedProjectFileCount = $removedProjectFiles.Count
    removedProjectFiles = @($removedProjectFiles)
} | ConvertTo-Json -Depth 5
