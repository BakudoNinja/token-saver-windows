param(
    [string]$ProjectPath = ".",
    [string]$OutputPath = "",
    [int]$MaxChars = 24000,
    [string[]]$Include = @(),
    [int]$MaxFiles = 24,
    [int]$PerFileChars = 2600,
    [string]$StatsPath = "",
    [string]$ContextCachePath = "",
    [string]$GlobalHistoryPath = "$env:USERPROFILE\.codex\codex-token-helper-history.jsonl",
    [string]$ConversationName = "",
    [string]$RunKind = "actual"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-TokenEstimate {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) {
        return 0
    }
    return [int][Math]::Ceiling($Text.Length / 4.0)
}

function Resolve-ProjectPath {
    param([string]$Path)
    return (Get-Item -LiteralPath $Path).FullName
}

function Get-RelativePath {
    param(
        [string]$BasePath,
        [string]$FullPath
    )
    $baseUri = [System.Uri]($BasePath.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar)
    $fileUri = [System.Uri]$FullPath
    return [System.Uri]::UnescapeDataString($baseUri.MakeRelativeUri($fileUri).ToString()).Replace("/", [System.IO.Path]::DirectorySeparatorChar)
}

function Test-IgnoredPath {
    param([string]$RelativePath)

    $normalized = $RelativePath -replace "\\", "/"
    $parts = $normalized -split "/"
    $ignoredDirs = @(
        ".git", ".hg", ".svn", ".idea", ".vscode", ".codex",
        "node_modules", "vendor", "dist", "release", "releases", "build", "out", "target",
        ".next", ".nuxt", ".cache", ".turbo", ".parcel-cache",
        "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache",
        "coverage", ".venv", "venv", "env", ".gradle",
        "diagnostics", "screenshots", "captures", "evidence", "recordings",
        "logs", "tmp", "temp"
    )
    foreach ($part in $parts) {
        if ($ignoredDirs -contains $part) {
            return $true
        }
    }

    $ignoredFiles = @(
        "package-lock.json", "pnpm-lock.yaml", "yarn.lock",
        "Cargo.lock", "poetry.lock", "uv.lock"
    )
    if ($ignoredFiles -contains [System.IO.Path]::GetFileName($normalized)) {
        return $true
    }

    $ignoredExtensions = @(
        ".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico", ".pdf",
        ".zip", ".tar", ".gz", ".7z", ".rar", ".exe", ".dll",
        ".so", ".dylib", ".bin", ".obj", ".pdb", ".mp4", ".mov",
        ".mp3", ".wav", ".woff", ".woff2", ".ttf", ".eot"
    )
    return $ignoredExtensions -contains [System.IO.Path]::GetExtension($normalized).ToLowerInvariant()
}

function Get-GitChangedFiles {
    param([string]$Root)

    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($null -eq $git) {
        return @()
    }

    Push-Location $Root
    try {
        $changed = @(& $git.Source status --porcelain 2>$null | ForEach-Object {
            if ($_ -match '^\s*(?:[ MADRCU?]{1,2})\s+(.+)$') {
                $matches[1].Trim('"')
            }
        })
        return @($changed | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    }
    catch {
        return @()
    }
    finally {
        Pop-Location
    }
}

function Get-GitStatusText {
    param([string]$Root)

    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($null -eq $git) {
        return "git not available"
    }

    Push-Location $Root
    try {
        $status = & $git.Source status --short 2>$null
        if ($LASTEXITCODE -ne 0 -or $null -eq $status) {
            return "not a git repository or status unavailable"
        }
        if (@($status).Count -eq 0) {
            return "clean"
        }
        return ($status -join [Environment]::NewLine)
    }
    catch {
        return "git status unavailable"
    }
    finally {
        Pop-Location
    }
}

function Get-FileCategory {
    param(
        [string]$RelativePath,
        [hashtable]$ChangedSet,
        [string[]]$IncludeList
    )

    $normalized = ($RelativePath -replace "\\", "/").ToLowerInvariant()
    $categories = New-Object System.Collections.Generic.List[string]

    if ($ChangedSet.ContainsKey($normalized)) {
        [void]$categories.Add("changed")
    }
    foreach ($include in @($IncludeList)) {
        if ([string]::IsNullOrWhiteSpace($include)) {
            continue
        }
        $inc = ($include -replace "\\", "/").Trim("/").ToLowerInvariant()
        if ($normalized -eq $inc -or $normalized.StartsWith($inc + "/")) {
            [void]$categories.Add("included")
        }
    }
    if ($normalized -match '(^|/)readme(\.[^/]+)?$|(^|/)agents\.md$|(^|/)claude\.md$|(^|/)token_saver\.md$') {
        [void]$categories.Add("essential")
    }
    if ($normalized -match '(^|/)(package\.json|pyproject\.toml|requirements\.txt|tsconfig\.json|vite\.config\.[jt]s|next\.config\.[jt]s|svelte\.config\.js|cargo\.toml|go\.mod)$') {
        [void]$categories.Add("config")
    }
    if ($normalized -match '(^|/)(src|app|lib|server|client|pages|routes)/.*\.(ps1|py|js|jsx|ts|tsx|go|rs|java|cs)$|(^|/)(main|index|app|server|cli)\.(ps1|py|js|ts|go|rs)$') {
        [void]$categories.Add("entry")
    }
    if ($normalized -match '(^|/)(test|tests|spec|__tests__)/|(\.test|\.spec)\.(js|jsx|ts|tsx|py|ps1)$') {
        [void]$categories.Add("test")
    }
    if ($categories.Count -eq 0) {
        [void]$categories.Add("normal")
    }
    return @($categories.ToArray())
}

function Get-CategoryScore {
    param([string[]]$Categories)

    $score = 10
    if ($Categories -contains "changed") { $score += 1000 }
    if ($Categories -contains "included") { $score += 900 }
    if ($Categories -contains "essential") { $score += 700 }
    if ($Categories -contains "config") { $score += 500 }
    if ($Categories -contains "entry") { $score += 450 }
    if ($Categories -contains "test") { $score += 350 }
    return $score
}

function Read-Cache {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        try {
            return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        }
        catch {
        }
    }
    return [PSCustomObject]@{ files = @{} }
}

function Get-CacheFileMap {
    param([object]$Cache)
    $map = @{}
    if ($null -ne $Cache -and $Cache.PSObject.Properties.Name -contains "files") {
        foreach ($prop in @($Cache.files.PSObject.Properties)) {
            $map[[string]$prop.Name] = $prop.Value
        }
    }
    return $map
}

$root = Resolve-ProjectPath -Path $ProjectPath
$codexDir = Join-Path $root ".codex"
New-Item -ItemType Directory -Force -Path $codexDir | Out-Null

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $codexDir "context.md"
}
else {
    $OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
}
if ([string]::IsNullOrWhiteSpace($StatsPath)) {
    $StatsPath = Join-Path $codexDir "stats.json"
}
else {
    $StatsPath = [System.IO.Path]::GetFullPath($StatsPath)
}
if ([string]::IsNullOrWhiteSpace($ContextCachePath)) {
    $ContextCachePath = Join-Path $codexDir "context-cache.json"
}
else {
    $ContextCachePath = [System.IO.Path]::GetFullPath($ContextCachePath)
}

$changedFiles = @(Get-GitChangedFiles -Root $root)
$changedSet = @{}
foreach ($changed in $changedFiles) {
    $changedSet[($changed -replace "\\", "/").ToLowerInvariant()] = $true
}

$cache = Read-Cache -Path $ContextCachePath
$cacheMap = Get-CacheFileMap -Cache $cache
$nextCache = [ordered]@{
    schemaVersion = 1
    updatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    files = [ordered]@{}
}

$candidateFiles = New-Object System.Collections.Generic.List[object]
foreach ($file in @(Get-ChildItem -LiteralPath $root -File -Recurse -ErrorAction SilentlyContinue)) {
    $relative = Get-RelativePath -BasePath $root -FullPath $file.FullName
    if (Test-IgnoredPath -RelativePath $relative) {
        continue
    }
    if ($file.Length -gt 512KB) {
        continue
    }
    $categories = @(Get-FileCategory -RelativePath $relative -ChangedSet $changedSet -IncludeList $Include)
    $score = Get-CategoryScore -Categories $categories
    [void]$candidateFiles.Add([PSCustomObject]@{
        fullPath = $file.FullName
        path = $relative
        size = [long]$file.Length
        lastWriteTimeUtc = $file.LastWriteTimeUtc
        categories = @($categories)
        score = $score
    })
}

$orderedFiles = @($candidateFiles.ToArray() | Sort-Object @{ Expression = "score"; Descending = $true }, @{ Expression = "lastWriteTimeUtc"; Descending = $true }, "path")
$selectedFiles = @($orderedFiles | Select-Object -First $MaxFiles)

$sections = New-Object System.Collections.Generic.List[string]
$filesForStats = New-Object System.Collections.Generic.List[object]
$originalChars = 0
$outputChars = 0
$hitCount = 0
$stableReferenceCount = 0
$stableReferenceSavedTokens = 0

$header = @"
# Token saver context

Project: `$root`
Generated: $((Get-Date).ToString("yyyy-MM-dd HH:mm:ss"))

## Git status

````text
$(Get-GitStatusText -Root $root)
````
"@
[void]$sections.Add($header.Trim())
$outputChars += $header.Length

foreach ($item in $selectedFiles) {
    $raw = ""
    try {
        $raw = Get-Content -LiteralPath $item.fullPath -Raw -ErrorAction Stop
    }
    catch {
        continue
    }
    $originalChars += $raw.Length
    $hash = (Get-FileHash -LiteralPath $item.fullPath -Algorithm SHA256).Hash
    $cacheKey = ($item.path -replace "\\", "/")
    $previous = if ($cacheMap.ContainsKey($cacheKey)) { $cacheMap[$cacheKey] } else { $null }
    $protected = @($item.categories | Where-Object { $_ -in @("changed", "included", "essential", "entry", "test") }).Count -gt 0
    $canReference = (
        -not $protected -and
        $null -ne $previous -and
        [string]$previous.sha256 -eq $hash -and
        [string]$previous.summary -ne ""
    )

    $contentForContext = ""
    $cacheReference = $false
    if ($canReference) {
        $cacheReference = $true
        $hitCount++
        $stableReferenceCount++
        $contentForContext = "[unchanged stable file; cached summary]`n$($previous.summary)"
        $stableReferenceSavedTokens += [Math]::Max(0, (Get-TokenEstimate -Text $raw) - (Get-TokenEstimate -Text $contentForContext))
    }
    else {
        $contentForContext = if ($raw.Length -gt $PerFileChars) { $raw.Substring(0, $PerFileChars) + "`n...[truncated]" } else { $raw }
    }

    $section = @"
## File: $($item.path)

Categories: $([string]::Join(", ", @($item.categories)))

````text
$contentForContext
````
"@
    if (($outputChars + $section.Length) -gt $MaxChars -and $filesForStats.Count -gt 0) {
        break
    }
    [void]$sections.Add($section.Trim())
    $outputChars += $section.Length

    $summary = ($raw -split "\r?\n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 8) -join " "
    if ($summary.Length -gt 700) {
        $summary = $summary.Substring(0, 700)
    }
    $nextCache.files[$cacheKey] = [ordered]@{
        sha256 = $hash
        summary = $summary
        tokens = Get-TokenEstimate -Text $raw
        updatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    }

    [void]$filesForStats.Add([PSCustomObject]@{
        path = $item.path
        categories = @($item.categories)
        bytes = $item.size
        tokens = Get-TokenEstimate -Text $raw
        includedChars = [Math]::Min($raw.Length, $contentForContext.Length)
        cacheReference = $cacheReference
    })
}

$context = [string]::Join([Environment]::NewLine + [Environment]::NewLine, $sections.ToArray()) + [Environment]::NewLine
$outputDir = Split-Path -Parent $OutputPath
if (-not [string]::IsNullOrWhiteSpace($outputDir)) {
    New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
}
Set-Content -LiteralPath $OutputPath -Value $context -Encoding UTF8

$statsDir = Split-Path -Parent $StatsPath
if (-not [string]::IsNullOrWhiteSpace($statsDir)) {
    New-Item -ItemType Directory -Force -Path $statsDir | Out-Null
}
$nextCache | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ContextCachePath -Encoding UTF8

$outputTokens = Get-TokenEstimate -Text $context
$originalTokens = [Math]::Max((Get-TokenEstimate -Text ($sections -join "`n")), (Get-TokenEstimate -Text (" " * [Math]::Min($originalChars, 1000000))))
if ($originalChars -gt 0) {
    $originalTokens = Get-TokenEstimate -Text (" " * [Math]::Min($originalChars, 1000000))
}
$savedTokens = [Math]::Max(0, $originalTokens - $outputTokens + $stableReferenceSavedTokens)

$changedIncluded = @($filesForStats.ToArray() | Where-Object { @($_.categories) -contains "changed" }).Count
$coverageRisk = "low"
if ($changedFiles.Count -gt 0 -and $changedIncluded -lt $changedFiles.Count) {
    $coverageRisk = "medium"
}
if ($filesForStats.Count -eq 0) {
    $coverageRisk = "high"
}

$stats = [ordered]@{
    schemaVersion = 2
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    projectPath = $root
    contextPath = $OutputPath
    statsPath = $StatsPath
    maxChars = $MaxChars
    maxFiles = $MaxFiles
    perFileChars = $PerFileChars
    scannedFileCount = $candidateFiles.Count
    selectedFileCount = $filesForStats.Count
    originalTokens = [long]$originalTokens
    outputTokens = [long]$outputTokens
    savedTokens = [long]$savedTokens
    files = @($filesForStats.ToArray())
    coverageAudit = [ordered]@{
        risk = $coverageRisk
        changedFileCount = [int]$changedFiles.Count
        changedFilesIncludedCount = [int]$changedIncluded
    }
    contextCache = [ordered]@{
        path = $ContextCachePath
        hitCount = [int]$hitCount
        stableReferenceCount = [int]$stableReferenceCount
        stableReferenceSavedTokens = [long]$stableReferenceSavedTokens
    }
}

$stats | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $StatsPath -Encoding UTF8

$historyEntry = [ordered]@{
    atUtc = (Get-Date).ToUniversalTime().ToString("o")
    projectPath = $root
    conversationName = $ConversationName
    runKind = $RunKind
    outputTokens = [long]$outputTokens
    originalTokens = [long]$originalTokens
    savedTokens = [long]$savedTokens
}
if (-not [string]::IsNullOrWhiteSpace($GlobalHistoryPath)) {
    $historyDir = Split-Path -Parent $GlobalHistoryPath
    if (-not [string]::IsNullOrWhiteSpace($historyDir)) {
        New-Item -ItemType Directory -Force -Path $historyDir | Out-Null
    }
    Add-Content -LiteralPath $GlobalHistoryPath -Value ($historyEntry | ConvertTo-Json -Compress -Depth 6) -Encoding UTF8
}

Write-Host "Context: $OutputPath"
Write-Host "Stats: $StatsPath"
Write-Host ("Estimated tokens: original {0:N0}, context {1:N0}, saved {2:N0}" -f $originalTokens, $outputTokens, $savedTokens)
