param(
    [string]$InstallRoot = "",
    [switch]$NoShortcut,
    [switch]$NoAutoAttach,
    [string]$CodexHome = "$env:USERPROFILE\.codex",
    [int]$MaxAutoAttachProjects = 25,
    [string[]]$Agents = @("Codex"),
    [switch]$SkipAutoAttachContext,
    [switch]$DisableAutoAttachFallbackScan
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
    $base = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $env:USERPROFILE "AppData\Local" }
    $InstallRoot = Join-Path $base "TokenUsageHelper"
}

$scriptRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $MyInvocation.MyCommand.Path))
$installRootFull = [System.IO.Path]::GetFullPath($InstallRoot)
$bin = Join-Path $installRootFull "bin"
$data = Join-Path $installRootFull "data"
New-Item -ItemType Directory -Force -Path $bin, $data | Out-Null

$scripts = @(
    "codex-token-kit.ps1",
    "codex-slim.ps1",
    "codex-token-auto-attach.ps1",
    "test-token-saver-release.ps1",
    "token-helper-core.ps1",
    "token-helper.ps1",
    "token-helper-panel.ps1",
    "README.md"
)

$copied = New-Object System.Collections.Generic.List[object]
foreach ($name in $scripts) {
    $source = Join-Path $scriptRoot $name
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "missing source file: $source"
    }
    $destination = Join-Path $bin $name
    Copy-Item -LiteralPath $source -Destination $destination -Force
    $sourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    $destinationHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
    if ($sourceHash -ne $destinationHash) {
        throw "copy verification failed for $name"
    }
    [void]$copied.Add([PSCustomObject]@{
        name = $name
        bytes = (Get-Item -LiteralPath $destination).Length
        sha256 = $destinationHash
    })
}

foreach ($name in @(
    "install.ps1",
    "install-codex.ps1",
    "install-claude.ps1",
    "install-cursor.ps1",
    "install-aider.ps1",
    "install-generic.ps1",
    "install-all-agents.ps1",
    "uninstall.ps1"
)) {
    $source = Join-Path $scriptRoot $name
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "missing source file: $source"
    }
    $destination = Join-Path $installRootFull $name
    Copy-Item -LiteralPath $source -Destination $destination -Force
    $sourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    $destinationHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
    if ($sourceHash -ne $destinationHash) {
        throw "copy verification failed for $name"
    }
    [void]$copied.Add([PSCustomObject]@{
        name = $name
        bytes = (Get-Item -LiteralPath $destination).Length
        sha256 = $destinationHash
    })
}

$cmdPath = Join-Path $bin "token-helper.cmd"
$cmdContent = "@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File ""%~dp0token-helper.ps1"" %*`r`n"
Set-Content -LiteralPath $cmdPath -Value $cmdContent -Encoding ASCII

$panelCmdPath = Join-Path $bin "token-helper-panel.cmd"
$panelCmdContent = "@echo off`r`nstart """" /min powershell -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File ""%~dp0token-helper.ps1"" panel %*`r`n"
Set-Content -LiteralPath $panelCmdPath -Value $panelCmdContent -Encoding ASCII

function New-TokenSaverIconFile {
    param([string]$Path)

    Add-Type -AssemblyName System.Drawing
    $bitmap = [System.Drawing.Bitmap]::new(64, 64)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.Clear([System.Drawing.Color]::FromArgb(12, 18, 30))
    $fill = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(16, 185, 129))
    $graphics.FillEllipse($fill, 6, 6, 52, 52)
    $fill.Dispose()
    $inner = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(12, 18, 30))
    $graphics.FillEllipse($inner, 13, 13, 38, 38)
    $inner.Dispose()
    $pen = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(74, 222, 128), 6)
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    $points = @(
        [System.Drawing.Point]::new(14, 43),
        [System.Drawing.Point]::new(24, 33),
        [System.Drawing.Point]::new(32, 38),
        [System.Drawing.Point]::new(44, 18),
        [System.Drawing.Point]::new(52, 27)
    )
    $graphics.DrawLines($pen, $points)
    $pen.Dispose()
    $graphics.Dispose()

    $icon = [System.Drawing.Icon]::FromHandle($bitmap.GetHicon())
    $stream = [System.IO.File]::Create($Path)
    try {
        $icon.Save($stream)
    }
    finally {
        $stream.Dispose()
        $icon.Dispose()
        $bitmap.Dispose()
    }
}

$iconPath = Join-Path $bin "token-saver.ico"
New-TokenSaverIconFile -Path $iconPath

$shortcutPath = ""
$startMenuShortcutPath = ""
if (-not $NoShortcut) {
    $shell = New-Object -ComObject WScript.Shell
    $shortcutTargets = New-Object System.Collections.Generic.List[object]
    $desktop = [Environment]::GetFolderPath("Desktop")
    if (-not [string]::IsNullOrWhiteSpace($desktop)) {
        [void]$shortcutTargets.Add([PSCustomObject]@{ path = (Join-Path $desktop "Token saver.lnk"); kind = "desktop" })
    }
    $programs = [Environment]::GetFolderPath("Programs")
    if (-not [string]::IsNullOrWhiteSpace($programs)) {
        $startMenuDir = Join-Path $programs "Token saver"
        New-Item -ItemType Directory -Force -Path $startMenuDir | Out-Null
        [void]$shortcutTargets.Add([PSCustomObject]@{ path = (Join-Path $startMenuDir "Token saver.lnk"); kind = "startMenu" })
    }
    foreach ($target in @($shortcutTargets.ToArray())) {
        $shortcut = $shell.CreateShortcut([string]$target.path)
        $shortcut.TargetPath = "powershell.exe"
        $shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$($bin)\token-helper.ps1`" panel"
        $shortcut.WorkingDirectory = $bin
        $shortcut.IconLocation = "$iconPath,0"
        $shortcut.WindowStyle = 7
        $shortcut.Save()
        if ([string]$target.kind -eq "desktop") {
            $shortcutPath = [string]$target.path
        }
        elseif ([string]$target.kind -eq "startMenu") {
            $startMenuShortcutPath = [string]$target.path
        }
    }
}

$manifest = [PSCustomObject]@{
    ok = $true
    installedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    sourceRoot = $scriptRoot
    installRoot = $installRootFull
    binPath = $bin
    dataPath = $data
    shortcutPath = $shortcutPath
    startMenuShortcutPath = $startMenuShortcutPath
    iconPath = $iconPath
    files = @($copied.ToArray())
    commands = @(
        "token-helper status",
        "token-helper refresh",
        "token-helper config",
        "token-helper health",
        "token-helper paths",
        "token-helper doctor",
        "token-helper panel",
        "token-helper reset"
    )
}
$manifestPath = Join-Path $installRootFull "install-manifest.json"

$autoAttach = [PSCustomObject]@{
    ok = $true
    skipped = $true
    reason = "NoAutoAttach"
    agentsPath = ""
    autoAttachProjectCount = 0
    autoAttachOkCount = 0
}
if (-not $NoAutoAttach) {
    $autoAttachArgs = @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        (Join-Path $bin "codex-token-auto-attach.ps1"),
        "-CodexHome",
        $CodexHome,
        "-BinPath",
        $bin,
        "-MaxProjects",
        $MaxAutoAttachProjects,
        "-Agents",
        ($Agents -join ","),
        "-Quiet"
    )
    if ($SkipAutoAttachContext) {
        $autoAttachArgs += "-SkipContextGeneration"
    }
    if ($DisableAutoAttachFallbackScan) {
        $autoAttachArgs += "-DisableFallbackScan"
    }
    $autoAttach = & powershell @autoAttachArgs | ConvertFrom-Json
}
$manifest | Add-Member -NotePropertyName autoAttach -NotePropertyValue $autoAttach -Force
$manifest | Add-Member -NotePropertyName codexHome -NotePropertyValue ([System.IO.Path]::GetFullPath($CodexHome)) -Force
$manifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

[PSCustomObject]@{
    ok = $true
    installRoot = $installRootFull
    binPath = $bin
    dataPath = $data
    manifestPath = $manifestPath
    shortcutPath = $shortcutPath
    startMenuShortcutPath = $startMenuShortcutPath
    iconPath = $iconPath
    autoAttach = $autoAttach
    pathHint = "Add this to PATH if needed: $bin"
} | ConvertTo-Json -Depth 6
