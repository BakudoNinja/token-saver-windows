param(
    [string]$BinPath = "$env:USERPROFILE\.codex\bin",
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$bin = [System.IO.Path]::GetFullPath($BinPath)
New-Item -ItemType Directory -Force -Path $bin | Out-Null

$scripts = @(
    "codex-token-kit.ps1",
    "codex-token-auto-attach.ps1",
    "codex-slim.ps1",
    "codex-context-regression.ps1",
    "codex-sync-global-bin.ps1",
    "test-token-saver-release.ps1",
    "token-helper-core.ps1",
    "token-helper.ps1",
    "token-helper-panel.ps1",
    "README.md",
    "install.ps1",
    "install-codex.ps1",
    "install-claude.ps1",
    "install-cursor.ps1",
    "install-aider.ps1",
    "install-generic.ps1",
    "install-all-agents.ps1",
    "uninstall.ps1",
    "test-token-helper-mvp.ps1",
    "test-token-helper-panel-smoke.ps1"
)

$cmdShims = @{
    "codex-token-kit.cmd" = "codex-token-kit.ps1"
    "codex-token-auto-attach.cmd" = "codex-token-auto-attach.ps1"
    "codex-sync-global-bin.cmd" = "codex-sync-global-bin.ps1"
    "token-helper.cmd" = "token-helper.ps1"
    "token-helper-panel.cmd" = "token-helper-panel.ps1"
    "install-token-saver.cmd" = "install.ps1"
    "install-token-saver-codex.cmd" = "install-codex.ps1"
    "install-token-saver-claude.cmd" = "install-claude.ps1"
    "install-token-saver-cursor.cmd" = "install-cursor.ps1"
    "install-token-saver-aider.cmd" = "install-aider.ps1"
    "install-token-saver-generic.cmd" = "install-generic.ps1"
    "install-token-saver-all-agents.cmd" = "install-all-agents.ps1"
}

$copied = New-Object System.Collections.Generic.List[object]
foreach ($scriptName in $scripts) {
    $source = Join-Path $scriptRoot $scriptName
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "missing source script: $source"
    }

    $destination = Join-Path $bin $scriptName
    Copy-Item -LiteralPath $source -Destination $destination -Force
    $sourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    $destinationHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
    if ($sourceHash -ne $destinationHash) {
        throw "copy verification failed for $scriptName"
    }

    [void]$copied.Add([PSCustomObject]@{
        name = $scriptName
        bytes = (Get-Item -LiteralPath $destination).Length
        sha256 = $destinationHash
    })
}

foreach ($entry in $cmdShims.GetEnumerator()) {
    $cmdPath = Join-Path $bin $entry.Key
    $target = $entry.Value
    if ($entry.Key -eq "token-helper-panel.cmd") {
        $content = "@echo off`r`nstart """" /min powershell -WindowStyle Hidden -ExecutionPolicy Bypass -File ""%USERPROFILE%\.codex\bin\token-helper.ps1"" panel %*`r`n"
    }
    else {
        $content = "@echo off`r`npowershell -ExecutionPolicy Bypass -File ""%USERPROFILE%\.codex\bin\$target"" %*`r`n"
    }
    Set-Content -LiteralPath $cmdPath -Value $content -Encoding ASCII
}

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

$manifest = [PSCustomObject]@{
    ok = $true
    syncedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    sourceRoot = [System.IO.Path]::GetFullPath($scriptRoot)
    binPath = $bin
    scriptCount = $copied.Count
    cmdShimCount = $cmdShims.Count
    iconPath = $iconPath
    scripts = @($copied.ToArray())
}
$manifestPath = Join-Path $bin "codex-helper-install.json"
$manifest | ConvertTo-Json -Depth 5 -Compress | Set-Content -LiteralPath $manifestPath -Encoding UTF8

$result = [PSCustomObject]@{
    ok = $true
    binPath = $bin
    manifestPath = $manifestPath
    syncedAtUtc = $manifest.syncedAtUtc
    sourceRoot = $manifest.sourceRoot
    scriptCount = $copied.Count
    cmdShimCount = $cmdShims.Count
    iconPath = $iconPath
    copied = @($copied.ToArray())
}

if (-not $Quiet) {
    $result | ConvertTo-Json -Depth 4
}
