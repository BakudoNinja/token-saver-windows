param(
    [string]$WorkRoot = "",
    [switch]$KeepFixture
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$tokenKit = Join-Path $scriptRoot "codex-token-kit.ps1"
$failures = New-Object System.Collections.Generic.List[string]

function Add-Failure {
    param([string]$Message)
    [void]$failures.Add($Message)
}

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        Add-Failure $Message
    }
}

function Write-TextFile {
    param(
        [string]$Path,
        [string]$Text
    )

    $dir = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    Set-Content -LiteralPath $Path -Value $Text -Encoding UTF8
}

function Invoke-TokenKitForFixture {
    param([string]$Path)

    & powershell -NoProfile -ExecutionPolicy Bypass -File $tokenKit -ProjectPath $Path -MaxChars 24000 -ConversationName "context-regression" -RunKind refresh -SkipAiCodex -Quiet | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "codex-token-kit.ps1 failed for regression fixture."
    }
}

if ([string]::IsNullOrWhiteSpace($WorkRoot)) {
    $WorkRoot = Join-Path $env:TEMP ("codex-context-regression-" + [guid]::NewGuid().ToString("N"))
}

$fixture = [System.IO.Path]::GetFullPath($WorkRoot)
New-Item -ItemType Directory -Force -Path $fixture | Out-Null

try {
    Write-TextFile -Path (Join-Path $fixture ".gitignore") -Text ".codex`n"
    Write-TextFile -Path (Join-Path $fixture "README.md") -Text @"
# Regression Fixture

README_SENTINEL_context_quality
This file proves essential documentation remains visible.
"@
    Write-TextFile -Path (Join-Path $fixture "package.json") -Text '{"name":"codex-context-regression","version":"1.0.0","scripts":{"test":"node src/app.js"}}'
    Write-TextFile -Path (Join-Path $fixture "src/app.js") -Text @"
export function importantValue() {
  return 'ENTRY_SENTINEL_before_change';
}
"@
    Write-TextFile -Path (Join-Path $fixture "tests/app.test.js") -Text @"
import { importantValue } from '../src/app.js';
console.log('TEST_SENTINEL_quality_gate', importantValue());
"@

    foreach ($i in 1..12) {
        $normalPath = Join-Path $fixture ("notes/note-{0:D2}.txt" -f $i)
        $normalText = "NORMAL_SENTINEL_$i`n" + ((1..90 | ForEach-Object { "stable background line $_ for low priority cache reuse" }) -join "`n")
        Write-TextFile -Path $normalPath -Text $normalText
        (Get-Item -LiteralPath $normalPath).LastWriteTime = (Get-Date).AddDays(-30)
    }

    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($null -ne $git) {
        Push-Location $fixture
        try {
            git init | Out-Null
            git config user.email "codex-helper@example.invalid" | Out-Null
            git config user.name "Codex Helper Regression" | Out-Null
            git config core.autocrlf false | Out-Null
            git add . 2>$null | Out-Null
            git commit -m "baseline" 2>$null | Out-Null
        }
        finally {
            Pop-Location
        }
    }

    Write-TextFile -Path (Join-Path $fixture "src/app.js") -Text @"
export function importantValue() {
  return 'CHANGED_SENTINEL_after_change';
}
"@

    Invoke-TokenKitForFixture -Path $fixture
    $firstStatsPath = Join-Path $fixture ".codex/stats.json"
    $firstStats = Get-Content -LiteralPath $firstStatsPath -Raw | ConvertFrom-Json

    Invoke-TokenKitForFixture -Path $fixture
    $statsPath = Join-Path $fixture ".codex/stats.json"
    $contextPath = Join-Path $fixture ".codex/context.md"
    $stats = Get-Content -LiteralPath $statsPath -Raw | ConvertFrom-Json
    $context = Get-Content -LiteralPath $contextPath -Raw

    Assert-True ($context.Contains("CHANGED_SENTINEL_after_change")) "changed entry file content must remain in context."
    Assert-True ($context.Contains("README_SENTINEL_context_quality")) "essential README content must remain in context."
    Assert-True ($context.Contains("TEST_SENTINEL_quality_gate")) "test file content must remain in context."
    Assert-True ([string]$stats.coverageAudit.risk -ne "high") "fixture coverage risk must not be high."
    Assert-True ([int]$stats.coverageAudit.changedFilesIncludedCount -eq [int]$stats.coverageAudit.changedFileCount) "fixture changed files must all be selected."
    Assert-True ([int]$stats.contextCache.hitCount -gt 0) "second fixture run should hit context cache."
    Assert-True ([int]$stats.contextCache.stableReferenceCount -gt 0) "second fixture run should use stable cache references for low-priority normal files."
    Assert-True ([int]$stats.contextCache.stableReferenceSavedTokens -gt 0) "stable cache references should save estimated tokens."
    Assert-True ([int]$firstStats.contextCache.stableReferenceCount -eq 0) "first fixture run should not use stable cache references."

    foreach ($file in @($stats.files)) {
        $categories = ",$([string]$file.categories),"
        $protected = $categories.Contains(",changed,") -or $categories.Contains(",essential,") -or $categories.Contains(",entry,") -or $categories.Contains(",test,")
        if ($protected) {
            Assert-True (-not [bool]$file.cacheReference) "protected file must not use a stable cache reference: $($file.path)"
        }
    }

    $lockedHistoryPath = Join-Path $fixture ".codex/locked-history.jsonl"
    $lockStream = [System.IO.File]::Open($lockedHistoryPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try {
        $lockedContextPath = Join-Path $fixture ".codex/locked-context.md"
        $lockedStatsPath = Join-Path $fixture ".codex/locked-stats.json"
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot "codex-slim.ps1") `
            -ProjectPath $fixture `
            -OutputPath $lockedContextPath `
            -StatsPath $lockedStatsPath `
            -ContextCachePath (Join-Path $fixture ".codex/locked-cache.json") `
            -GlobalHistoryPath $lockedHistoryPath `
            -ConversationName "locked-history-regression" `
            -RunKind refresh | Out-Null
        Assert-True ($LASTEXITCODE -eq 0) "codex-slim should not fail when global history file is locked."
        Assert-True (Test-Path -LiteralPath $lockedContextPath -PathType Leaf) "locked history run should still write context."
        Assert-True (Test-Path -LiteralPath $lockedStatsPath -PathType Leaf) "locked history run should still write stats."
    }
    finally {
        $lockStream.Dispose()
    }
}
finally {
    if (-not $KeepFixture -and (Test-Path -LiteralPath $fixture)) {
        Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($failures.Count -gt 0) {
    Write-Host "Codex context regression failed:"
    foreach ($failure in $failures) {
        Write-Host "- $failure"
    }
    exit 1
}

[PSCustomObject]@{
    ok = $true
    fixture = $fixture
    cacheHits = [int]$stats.contextCache.hitCount
    cacheReferences = [int]$stats.contextCache.stableReferenceCount
    cacheSavedTokens = [int]$stats.contextCache.stableReferenceSavedTokens
    coverageRisk = [string]$stats.coverageAudit.risk
} | ConvertTo-Json -Depth 4
