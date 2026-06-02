param(
    [string]$ProjectPath = ".",
    [string]$OutputPath = "",
    [int]$MaxChars = 24000,
    [string[]]$Include = @(),
    [int]$MaxFiles = 24,
    [int]$PerFileChars = 2600,
    [string]$StatsPath = "",
    [string]$DashboardPath = "",
    [string]$ContextCachePath = "",
    [string]$PlanName = "",
    [long]$PlanTotalTokens = -1,
    [long]$PlanUsedTokens = -1,
    [switch]$ReadOpenAIUsage,
    [int]$OpenAIUsageDays = 31,
    [string]$OpenAIAdminKeyEnv = "OPENAI_ADMIN_KEY",
    [string]$OpenAIAdminKeyPath = "$env:USERPROFILE\.codex\openai-admin-key.dpapi",
    [string]$GlobalHistoryPath = "$env:USERPROFILE\.codex\codex-token-helper-history.jsonl",
    [string]$ConversationName = "",
    [string]$RunKind = "actual"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-ProjectPath {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path
    return $item.FullName
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
        "win-unpacked", "linux-unpacked", "mac", "mas",
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

function Get-RelativePath {
    param(
        [string]$BasePath,
        [string]$FullPath
    )

    $baseUri = [System.Uri]($BasePath.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar)
    $fileUri = [System.Uri]$FullPath
    return [System.Uri]::UnescapeDataString($baseUri.MakeRelativeUri($fileUri).ToString()) -replace "/", [System.IO.Path]::DirectorySeparatorChar
}

function Get-TextFileScore {
    param(
        [string]$RelativePath,
        [hashtable]$ChangedPathSet = @{}
    )

    $name = [System.IO.Path]::GetFileName($RelativePath).ToLowerInvariant()
    $ext = [System.IO.Path]::GetExtension($RelativePath).ToLowerInvariant()
    $path = ($RelativePath -replace "\\", "/").ToLowerInvariant()
    $score = 0

    if ($Include.Count -gt 0) {
        foreach ($item in $Include) {
            $needle = ($item -replace "\\", "/").ToLowerInvariant()
            if ($path -eq $needle -or $path.StartsWith($needle.TrimEnd("/") + "/") -or $path.Contains($needle)) {
                $score += 1000
            }
        }
    }

    if ($ChangedPathSet.ContainsKey($path)) {
        $score += 900
    }

    if ($name -in @("readme.md", "package.json", "pyproject.toml", "cargo.toml", "go.mod", "pom.xml", "build.gradle", "vite.config.ts", "next.config.js", "tsconfig.json")) {
        $score += 500
    }

    if ($path -match "(^|/)(src|app|lib|server|client|components|pages|routes|api)(/|$)") {
        $score += 180
    }

    if ($path -match "^\.ai-codex/") {
        $score += 420
    }

    if ($path -match "(test|spec|__tests__)") {
        $score += 120
    }

    if ($name -match "^(main|index|app|server|router|config)\.") {
        $score += 160
    }

    if ($ext -in @(".md", ".json", ".toml", ".yaml", ".yml", ".js", ".jsx", ".ts", ".tsx", ".py", ".rs", ".go", ".java", ".cs", ".php", ".rb", ".css", ".scss", ".html")) {
        $score += 80
    }

    return $score
}

function Get-ContextCategory {
    param(
        [string]$RelativePath,
        [datetime]$LastWriteTime,
        [hashtable]$ChangedPathSet
    )

    $normalized = ($RelativePath -replace "\\", "/").ToLowerInvariant()
    $name = [System.IO.Path]::GetFileName($normalized)
    $categories = New-Object System.Collections.Generic.List[string]

    if ($ChangedPathSet.ContainsKey($normalized)) {
        [void]$categories.Add("changed")
    }
    if ($name -in @("readme.md", "package.json", "pyproject.toml", "cargo.toml", "go.mod", "pom.xml", "build.gradle", "vite.config.ts", "vite.config.js", "next.config.js", "tsconfig.json", "requirements.txt", "dockerfile", "makefile")) {
        [void]$categories.Add("essential")
    }
    if ($normalized -match "(^|/)(src|app|lib|server|client|pages|routes|api)(/|$)" -and $name -match "^(main|index|app|server|router|config)\.") {
        [void]$categories.Add("entry")
    }
    if ($normalized -match "(test|spec|__tests__)") {
        [void]$categories.Add("test")
    }
    if ($LastWriteTime -gt (Get-Date).AddDays(-7)) {
        [void]$categories.Add("recent")
    }

    if ($categories.Count -eq 0) {
        [void]$categories.Add("normal")
    }

    return ($categories.ToArray() -join ",")
}

function Get-GitChangedPathSet {
    param([string]$Root)

    $set = @{}
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($null -eq $git) {
        return $set
    }

    Push-Location $Root
    try {
        $oldErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        $inside = git rev-parse --is-inside-work-tree 2>$null
        $ErrorActionPreference = $oldErrorActionPreference
        if ($LASTEXITCODE -ne 0 -or $inside -ne "true") {
            return $set
        }

        foreach ($line in @(git status --short 2>$null)) {
            if ([string]::IsNullOrWhiteSpace($line) -or $line.Length -lt 4) {
                continue
            }

            $pathText = $line.Substring(3).Trim()
            if ($pathText.Contains(" -> ")) {
                $parts = $pathText -split " -> ", 2
                $pathText = $parts[1].Trim()
            }

            $normalized = ($pathText -replace "\\", "/").Trim('"').ToLowerInvariant()
            if (-not [string]::IsNullOrWhiteSpace($normalized)) {
                $set[$normalized] = $true
            }
        }
    }
    catch {
    }
    finally {
        Pop-Location
    }

    return $set
}

function Get-CoverageAudit {
    param(
        [array]$Candidates,
        [array]$Selected
    )

    $selectedSet = @{}
    foreach ($item in @($Selected)) {
        $selectedSet[[string]$item.NormalizedPath] = $true
    }

    $changed = @($Candidates | Where-Object { ([string]$_.Categories).Contains("changed") })
    $essential = @($Candidates | Where-Object { ([string]$_.Categories).Contains("essential") -or ([string]$_.Categories).Contains("entry") })
    $recent = @($Candidates | Where-Object { ([string]$_.Categories).Contains("recent") })
    $changedIncluded = @($changed | Where-Object { $selectedSet.ContainsKey([string]$_.NormalizedPath) })
    $essentialIncluded = @($essential | Where-Object { $selectedSet.ContainsKey([string]$_.NormalizedPath) })
    $recentIncluded = @($recent | Where-Object { $selectedSet.ContainsKey([string]$_.NormalizedPath) })
    $omittedImportant = @($Candidates |
        Where-Object { -not $selectedSet.ContainsKey([string]$_.NormalizedPath) -and ($_.Score -ge 500 -or ([string]$_.Categories).Contains("changed")) } |
        Sort-Object @{ Expression = "Score"; Descending = $true }, @{ Expression = "LastWriteTime"; Descending = $true } |
        Select-Object -First 8)

    $warnings = New-Object System.Collections.Generic.List[string]
    $risk = "low"
    if ($changed.Count -gt $changedIncluded.Count) {
        $risk = "high"
        [void]$warnings.Add("有 $($changed.Count - $changedIncluded.Count) 个当前改动文件没有进入 context。")
    }
    if ($essential.Count -gt 0 -and $essentialIncluded.Count -lt [Math]::Min($essential.Count, 3)) {
        if ($risk -ne "high") { $risk = "medium" }
        [void]$warnings.Add("入口/配置覆盖不足：$($essentialIncluded.Count)/$($essential.Count)。")
    }
    if ($omittedImportant.Count -gt 0 -and $risk -eq "low") {
        $risk = "medium"
        [void]$warnings.Add("仍有 $($omittedImportant.Count) 个高优先级文件被预算省略。")
    }
    if ($warnings.Count -eq 0) {
        [void]$warnings.Add("关键改动、入口配置和近期活跃文件覆盖正常。")
    }

    return [PSCustomObject]@{
        risk = $risk
        warnings = @($warnings.ToArray())
        changedFileCount = $changed.Count
        changedFilesIncludedCount = $changedIncluded.Count
        essentialFileCount = $essential.Count
        essentialFilesIncludedCount = $essentialIncluded.Count
        recentFileCount = $recent.Count
        recentFilesIncludedCount = $recentIncluded.Count
        omittedImportantFiles = @($omittedImportant | ForEach-Object {
            [PSCustomObject]@{
                path = [string]$_.RelativePath
                score = [int]$_.Score
                categories = [string]$_.Categories
            }
        })
    }
}

function Test-ContextCandidateFile {
    param([string]$RelativePath)

    $name = [System.IO.Path]::GetFileName($RelativePath).ToLowerInvariant()
    $ext = [System.IO.Path]::GetExtension($RelativePath).ToLowerInvariant()
    $textExtensions = @(
        ".md", ".txt", ".json", ".jsonl", ".toml", ".yaml", ".yml", ".xml",
        ".js", ".jsx", ".ts", ".tsx", ".mjs", ".cjs",
        ".py", ".rs", ".go", ".java", ".cs", ".php", ".rb", ".swift", ".kt",
        ".css", ".scss", ".sass", ".less", ".html", ".htm", ".vue", ".svelte",
        ".sql", ".sh", ".ps1", ".bat", ".cmd", ".dockerfile", ".env",
        ".gitignore", ".gitattributes"
    )

    if ($name -in @("dockerfile", "makefile", "readme", "license")) {
        return $true
    }

    return $textExtensions -contains $ext
}

function Read-TextPreview {
    param(
        [string]$Path,
        [int]$Limit
    )

    try {
        $content = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    }
    catch {
        return "[无法读取文件: $($_.Exception.Message)]"
    }

    $content = Optimize-ContextText -Path $Path -Content $content

    if ($content.Length -le $Limit) {
        return $content.Trim()
    }

    $headLimit = [Math]::Max(400, [int]($Limit * 0.72))
    $tailLimit = [Math]::Max(250, $Limit - $headLimit - 120)
    $head = $content.Substring(0, [Math]::Min($headLimit, $content.Length))
    $tailStart = [Math]::Max(0, $content.Length - $tailLimit)
    $tail = $content.Substring($tailStart)
    return ($head.TrimEnd() + "`n`n[...中间已压缩，原文件约 $($content.Length) 字符...]`n`n" + $tail.TrimStart()).Trim()
}

function Optimize-ContextText {
    param(
        [string]$Path,
        [string]$Content
    )

    if ([string]::IsNullOrEmpty($Content)) {
        return ""
    }

    $ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    $optimized = $Content

    if ($ext -eq ".json") {
        try {
            $json = $Content | ConvertFrom-Json -ErrorAction Stop
            $compressed = $json | ConvertTo-Json -Depth 100 -Compress
            if (-not [string]::IsNullOrWhiteSpace($compressed) -and $compressed.Length -lt $optimized.Length) {
                $optimized = $compressed
            }
        }
        catch {
            $optimized = $Content
        }
    }

    $lines = $optimized -split "\r?\n"
    $trimmedLines = @($lines | ForEach-Object { $_ -replace "\s+$", "" })
    $optimized = ($trimmedLines -join "`n")
    $optimized = [regex]::Replace($optimized, "(\n[ \t]*){3,}", "`n`n")

    return $optimized
}

function Get-FileCacheStamp {
    param([string]$Path)

    try {
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        return [PSCustomObject]@{
            length = [long]$item.Length
            lastWriteUtcTicks = [long]$item.LastWriteTimeUtc.Ticks
        }
    }
    catch {
        return [PSCustomObject]@{
            length = -1L
            lastWriteUtcTicks = -1L
        }
    }
}

function Get-HelperToolingInfo {
    param(
        [string]$ScriptRoot,
        [datetime]$StatsGeneratedAtUtc
    )

    $scriptNames = @(
        "codex-slim.ps1",
        "codex-token-kit.ps1",
        "codex-dashboard.ps1",
        "codex-dashboard-server.ps1",
        "codex-dashboard-smoke.ps1",
        "codex-helper-health.ps1",
        "codex-context-regression.ps1",
        "codex-dashboard-js-smoke.ps1",
        "codex-dashboard-performance.ps1",
        "codex-token-audit.ps1",
        "codex-token-usage-regression.ps1",
        "codex-sync-global-bin.ps1"
    )

    $scripts = New-Object System.Collections.Generic.List[object]
    foreach ($name in $scriptNames) {
        $path = Join-Path $ScriptRoot $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            continue
        }

        $item = Get-Item -LiteralPath $path
        [void]$scripts.Add([PSCustomObject]@{
            name = $name
            path = $item.FullName
            lastWriteUtc = $item.LastWriteTimeUtc.ToString("o")
            lastWriteLocal = $item.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
            length = [long]$item.Length
        })
    }

    $latest = @($scripts.ToArray() | Sort-Object -Property lastWriteUtc -Descending | Select-Object -First 1)
    $latestItem = if ($latest.Count -gt 0) { $latest[0] } else { $null }
    $latestUtcText = if ($null -ne $latestItem) { [string]$latestItem.lastWriteUtc } else { "" }
    $latestPath = if ($null -ne $latestItem) { [string]$latestItem.path } else { "" }
    $latestLocal = if ($null -ne $latestItem) { [string]$latestItem.lastWriteLocal } else { "" }
    $stale = $false
    if ($null -ne $latestItem) {
        $latestUtc = [DateTime]::Parse([string]$latestItem.lastWriteUtc).ToUniversalTime()
        $stale = ($StatsGeneratedAtUtc.AddSeconds(2) -lt $latestUtc)
    }

    return [PSCustomObject]@{
        schemaVersion = 1
        generatedBy = "codex-token-helper"
        helperVersion = if ($null -ne $latestItem) { "local-$($latestUtcText.Replace(':', '').Replace('-', '').Replace('.', ''))" } else { "local-unknown" }
        scriptRoot = $ScriptRoot
        statsGeneratedAtUtc = $StatsGeneratedAtUtc.ToString("o")
        coreScriptMaxWriteUtc = $latestUtcText
        coreScriptMaxWriteLocal = $latestLocal
        coreScriptMaxWritePath = $latestPath
        statsStaleAfterScriptUpdate = [bool]$stale
        scripts = @($scripts.ToArray())
    }
}

function Read-ContextCache {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [PSCustomObject]@{
            version = 1
            files = [PSCustomObject]@{}
        }
    }

    try {
        $cache = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        if ($null -eq $cache -or -not ($cache.PSObject.Properties.Name -contains "files")) {
            throw "invalid cache"
        }
        return $cache
    }
    catch {
        return [PSCustomObject]@{
            version = 1
            files = [PSCustomObject]@{}
        }
    }
}

function Get-ContextCacheEntry {
    param(
        [object]$Cache,
        [string]$Key
    )

    if ($null -eq $Cache -or $null -eq $Cache.files) {
        return $null
    }
    $names = @($Cache.files.PSObject.Properties | ForEach-Object { $_.Name })
    if ($names -contains $Key) {
        return $Cache.files.$Key
    }
    return $null
}

function Set-ContextCacheEntry {
    param(
        [object]$Cache,
        [string]$Key,
        [object]$Entry
    )

    if ($null -eq $Cache.files) {
        $Cache | Add-Member -NotePropertyName files -NotePropertyValue ([PSCustomObject]@{}) -Force
    }
    $Cache.files | Add-Member -NotePropertyName $Key -NotePropertyValue $Entry -Force
}

function Test-StableCacheReferenceAllowed {
    param(
        [object]$File,
        [int]$Index
    )

    if ($Index -lt 6) {
        return $false
    }

    $categories = ",$([string]$File.Categories),"
    foreach ($protected in @("changed", "essential", "entry", "test")) {
        if ($categories.Contains(",$protected,")) {
            return $false
        }
    }

    return $categories -eq ",normal,"
}

function New-StableCacheReference {
    param(
        [object]$File,
        [object]$Entry
    )

    $path = [string]$File.RelativePath -replace "\\", "/"
    $previewTokens = if ($null -ne $Entry -and ($Entry.PSObject.Properties.Name -contains "previewTokens")) { [int]$Entry.previewTokens } else { 0 }
    return "[未变化低优先级文件，复用缓存索引] path=$path; cachedPreviewTokens=$previewTokens; reason=normal file unchanged; read full file only if task touches it."
}

function Estimate-Tokens {
    param([int]$CharCount)
    if ($CharCount -le 0) {
        return 0
    }

    return [int][Math]::Ceiling($CharCount / 4.0)
}

function Get-Percent {
    param(
        [double]$Numerator,
        [double]$Denominator
    )

    if ($Denominator -le 0) {
        return 0
    }

    $percent = [int][Math]::Floor(($Numerator / $Denominator) * 100.0)
    if ($percent -ge 100 -and $Numerator -lt $Denominator) {
        return 99
    }
    return [Math]::Max(0, [Math]::Min(100, $percent))
}

function Get-PercentDecimal {
    param(
        [double]$Numerator,
        [double]$Denominator
    )

    if ($Denominator -le 0) {
        return 0.0
    }

    return [double]([Math]::Floor((($Numerator / $Denominator) * 1000.0) + 0.5) / 10.0)
}

function Escape-Html {
    param([string]$Value)
    if ($null -eq $Value) {
        return ""
    }

    return [System.Net.WebUtility]::HtmlEncode($Value)
}

function Escape-JsonForScript {
    param([string]$Value)
    if ($null -eq $Value) {
        return "{}"
    }

    return $Value.Replace("<", "\u003c").Replace(">", "\u003e").Replace("&", "\u0026")
}

function Get-TokenPlan {
    param(
        [string]$Root,
        [string]$Name,
        [long]$TotalTokens,
        [long]$UsedTokens
    )

    $configPath = Join-Path $Root ".codex/token-plan.json"
    $config = $null
    if (Test-Path -LiteralPath $configPath) {
        try {
            $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        }
        catch {
            $config = $null
        }
    }

    $resolvedName = "手动套餐"
    $resolvedTotal = 0L
    $resolvedUsed = 0L

    if ($null -ne $config) {
        if ($config.PSObject.Properties.Name -contains "name") {
            $resolvedName = [string]$config.name
        }
        if ($config.PSObject.Properties.Name -contains "totalTokens") {
            $resolvedTotal = [long]$config.totalTokens
        }
        if ($config.PSObject.Properties.Name -contains "usedTokens") {
            $resolvedUsed = [long]$config.usedTokens
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($Name)) {
        $resolvedName = $Name
    }
    if ($TotalTokens -ge 0) {
        $resolvedTotal = $TotalTokens
    }
    if ($UsedTokens -ge 0) {
        $resolvedUsed = $UsedTokens
    }

    if ($resolvedTotal -lt 0) {
        $resolvedTotal = 0
    }
    if ($resolvedUsed -lt 0) {
        $resolvedUsed = 0
    }
    if ($resolvedTotal -gt 0 -and $resolvedUsed -gt $resolvedTotal) {
        $resolvedUsed = $resolvedTotal
    }

    return [PSCustomObject]@{
        name = $resolvedName
        totalTokens = $resolvedTotal
        usedTokens = $resolvedUsed
        configPath = $configPath
        configured = ($resolvedTotal -gt 0)
    }
}

function Get-OpenAIUsage {
    param(
        [int]$Days,
        [string]$AdminKeyEnv,
        [string]$AdminKeyPath
    )

    $key = [Environment]::GetEnvironmentVariable($AdminKeyEnv)
    $keySource = "env:$AdminKeyEnv"
    if ([string]::IsNullOrWhiteSpace($key) -and (Test-Path -LiteralPath $AdminKeyPath)) {
        try {
            $rawKeyFile = (Get-Content -LiteralPath $AdminKeyPath -Raw).Trim()
            if ($rawKeyFile.StartsWith("dpapi:")) {
                throw "检测到旧版 dpapi: 保存格式，请在仪表盘里重新保存一次 Admin Key。"
            }

            $secure = $rawKeyFile | ConvertTo-SecureString
            $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
            try {
                $key = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
                $keySource = $AdminKeyPath
            }
            finally {
                if ($bstr -ne [IntPtr]::Zero) {
                    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
                }
            }
        }
        catch {
            return [PSCustomObject]@{
                status = "key_read_error"
                message = "无法读取已保存的 Admin Key: $($_.Exception.Message)"
                days = $Days
                inputTokens = 0L
                outputTokens = 0L
                cachedTokens = 0L
                totalTokens = 0L
                requests = 0L
                source = "openai_usage_api"
                keySource = $AdminKeyPath
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($key)) {
        return [PSCustomObject]@{
            status = "missing_key"
            message = "未找到环境变量 $AdminKeyEnv，也未找到 $AdminKeyPath。"
            days = $Days
            inputTokens = 0L
            outputTokens = 0L
            cachedTokens = 0L
            totalTokens = 0L
            requests = 0L
            source = "openai_usage_api"
            keySource = ""
        }
    }

    $daysSafe = [Math]::Max(1, [Math]::Min(31, $Days))
    $start = [DateTimeOffset]::UtcNow.AddDays(-$daysSafe).ToUnixTimeSeconds()
    $url = "https://api.openai.com/v1/organization/usage/completions?start_time=$start&bucket_width=1d&limit=31"
    $headers = @{
        "Authorization" = "Bearer $key"
        "Content-Type" = "application/json"
    }

    try {
        $response = Invoke-RestMethod -Method Get -Uri $url -Headers $headers -ErrorAction Stop
        $inputTokens = 0L
        $outputTokens = 0L
        $cachedTokens = 0L
        $requests = 0L

        foreach ($bucket in @($response.data)) {
            foreach ($result in @($bucket.results)) {
                if ($null -ne $result.input_tokens) {
                    $inputTokens += [long]$result.input_tokens
                }
                if ($null -ne $result.output_tokens) {
                    $outputTokens += [long]$result.output_tokens
                }
                if ($null -ne $result.input_cached_tokens) {
                    $cachedTokens += [long]$result.input_cached_tokens
                }
                if ($null -ne $result.num_model_requests) {
                    $requests += [long]$result.num_model_requests
                }
            }
        }

        return [PSCustomObject]@{
            status = "ok"
            message = "已读取 OpenAI Organization Usage API。"
            days = $daysSafe
            inputTokens = $inputTokens
            outputTokens = $outputTokens
            cachedTokens = $cachedTokens
            totalTokens = ($inputTokens + $outputTokens)
            requests = $requests
            source = "openai_usage_api"
            keySource = $keySource
        }
    }
    catch {
        return [PSCustomObject]@{
            status = "error"
            message = $_.Exception.Message
            days = $daysSafe
            inputTokens = 0L
            outputTokens = 0L
            cachedTokens = 0L
            totalTokens = 0L
            requests = 0L
            source = "openai_usage_api"
            keySource = $keySource
        }
    }
}

function Get-TokenHistorySummary {
    param(
        [string]$HistoryPath,
        [object]$CurrentRun
    )

    $entries = New-Object System.Collections.Generic.List[object]
    if (Test-Path -LiteralPath $HistoryPath) {
        foreach ($line in (Get-Content -LiteralPath $HistoryPath)) {
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }

            try {
                $entry = $line | ConvertFrom-Json
                [void]$entries.Add($entry)
            }
            catch {
            }
        }
    }

    [void]$entries.Add($CurrentRun)

    $actualEntries = @($entries | Where-Object { -not ($_.PSObject.Properties.Name -contains "runKind") -or $_.runKind -eq "actual" })
    $refreshEntries = @($entries | Where-Object { $_.PSObject.Properties.Name -contains "runKind" -and $_.runKind -eq "refresh" })

    $totalOriginal = 0L
    $totalOutput = 0L
    $totalSaved = 0L
    foreach ($entry in $actualEntries) {
        $totalOriginal += [long]$entry.originalTokens
        $totalOutput += [long]$entry.outputTokens
        $totalSaved += [long]$entry.savedTokens
    }

    $latest = $CurrentRun | ConvertTo-Json -Compress -Depth 5
    Add-TokenHistoryLine -HistoryPath $HistoryPath -Line $latest

    return [PSCustomObject]@{
        historyPath = $HistoryPath
        runCount = $actualEntries.Count
        refreshRunCount = $refreshEntries.Count
        totalOriginalTokens = $totalOriginal
        totalOutputTokens = $totalOutput
        totalSavedTokens = $totalSaved
        totalSavedPercent = (Get-Percent -Numerator ([double]$totalSaved) -Denominator ([double]$totalOriginal))
    }
}

function Add-TokenHistoryLine {
    param(
        [string]$HistoryPath,
        [string]$Line,
        [int]$Retries = 8,
        [int]$DelayMilliseconds = 180
    )

    $historyDir = Split-Path -Parent $HistoryPath
    if (-not [string]::IsNullOrWhiteSpace($historyDir)) {
        New-Item -ItemType Directory -Force -Path $historyDir | Out-Null
    }

    for ($attempt = 1; $attempt -le [Math]::Max(1, $Retries); $attempt++) {
        try {
            Add-Content -LiteralPath $HistoryPath -Value $Line -Encoding UTF8
            return
        }
        catch [System.IO.IOException] {
            if ($attempt -ge $Retries) {
                throw
            }
            Start-Sleep -Milliseconds $DelayMilliseconds
        }
    }
}

function Get-GlobalTokenHistorySummary {
    param(
        [string]$HistoryPath,
        [object]$CurrentRun
    )

    $historyDir = Split-Path -Parent $HistoryPath
    if (-not [string]::IsNullOrWhiteSpace($historyDir)) {
        New-Item -ItemType Directory -Force -Path $historyDir | Out-Null
    }

    $entries = New-Object System.Collections.Generic.List[object]
    if (Test-Path -LiteralPath $HistoryPath) {
        foreach ($line in (Get-Content -LiteralPath $HistoryPath)) {
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }

            try {
                $entry = $line | ConvertFrom-Json
                [void]$entries.Add($entry)
            }
            catch {
            }
        }
    }

    [void]$entries.Add($CurrentRun)

    $latest = $CurrentRun | ConvertTo-Json -Compress -Depth 5
    Add-TokenHistoryLine -HistoryPath $HistoryPath -Line $latest

    $actualEntries = @($entries | Where-Object { -not ($_.PSObject.Properties.Name -contains "runKind") -or $_.runKind -eq "actual" })
    $baselineEntries = @($entries | Where-Object { $_.PSObject.Properties.Name -contains "runKind" -and $_.runKind -eq "baseline" })
    $refreshEntries = @($entries | Where-Object { $_.PSObject.Properties.Name -contains "runKind" -and $_.runKind -eq "refresh" })

    function Get-DedupedActualEntries {
        param([array]$Items)

        $kept = New-Object System.Collections.Generic.List[object]
        $latestByProject = @{}
        foreach ($entry in @($Items | Sort-Object -Property generatedAt -Descending)) {
            $projectKey = ([string]$entry.projectPath).ToLowerInvariant()
            $currentAt = [DateTime]::MinValue
            [void][DateTime]::TryParse([string]$entry.generatedAt, [ref]$currentAt)
            $isDuplicate = $false
            if ($latestByProject.ContainsKey($projectKey) -and $currentAt -gt [DateTime]::MinValue) {
                $latest = $latestByProject[$projectKey]
                $minutes = [Math]::Abs(($latest.generatedAt - $currentAt).TotalMinutes)
                $originalDelta = [Math]::Abs([long]$latest.originalTokens - [long]$entry.originalTokens)
                $originalLimit = [Math]::Max(100L, [long]([Math]::Floor(([Math]::Max([long]$latest.originalTokens, [long]$entry.originalTokens) * 0.02) + 0.5)))
                if ($minutes -le 2 -and [long]$latest.outputTokens -eq [long]$entry.outputTokens -and $originalDelta -le $originalLimit) {
                    $isDuplicate = $true
                }
            }

            if (-not $isDuplicate) {
                [void]$kept.Add($entry)
                if ($currentAt -gt [DateTime]::MinValue) {
                    $latestByProject[$projectKey] = [PSCustomObject]@{
                        generatedAt = $currentAt
                        originalTokens = [long]$entry.originalTokens
                        outputTokens = [long]$entry.outputTokens
                    }
                }
            }
        }

        return @($kept.ToArray() | Sort-Object -Property generatedAt)
    }

    $rawActualRunCount = $actualEntries.Count
    $actualEntries = Get-DedupedActualEntries -Items $actualEntries

    function New-HistoryGroups {
        param(
            [array]$Items,
            [hashtable]$RequestUsageByName = @{},
            [hashtable]$RequestUsageByPath = @{},
            [hashtable]$ThreadActivityByPath = @{}
        )

        return @($Items | Group-Object -Property projectPath | ForEach-Object {
            $totalOriginal = 0L
            $totalOutput = 0L
            $totalSaved = 0L
            $latestOriginal = 0L
            $latestOutput = 0L
            $latestSaved = 0L
            $cappedCount = 0
            $lastRun = ""
            $firstRun = ""
            $name = ""

            foreach ($entry in $_.Group) {
                $totalOriginal += [long]$entry.originalTokens
                $totalOutput += [long]$entry.outputTokens
                $totalSaved += [long]$entry.savedTokens
                $isCapped = $false
                if ($entry.PSObject.Properties.Name -contains "outputCapped") {
                    $isCapped = [bool]$entry.outputCapped
                }
                elseif (($entry.PSObject.Properties.Name -contains "budgetTokens") -and [long]$entry.budgetTokens -gt 0) {
                    $isCapped = ([long]$entry.outputTokens -ge ([long]$entry.budgetTokens - 5))
                }
                else {
                    $out = [long]$entry.outputTokens
                    $isCapped = (($out -ge 3000 -and $out -le 3020) -or ($out -ge 6000 -and $out -le 6020))
                }
                if ($isCapped) {
                    $cappedCount++
                }
                if ([string]$entry.generatedAt -gt $lastRun) {
                    $lastRun = [string]$entry.generatedAt
                    $latestOriginal = [long]$entry.originalTokens
                    $latestOutput = [long]$entry.outputTokens
                    $latestSaved = [long]$entry.savedTokens
                }
                if ([string]::IsNullOrWhiteSpace($firstRun) -or [string]$entry.generatedAt -lt $firstRun) {
                    $firstRun = [string]$entry.generatedAt
                }
                if ([string]::IsNullOrWhiteSpace($name) -and $entry.PSObject.Properties.Name -contains "conversationName") {
                    $name = [string]$entry.conversationName
                }
            }

            if ([string]::IsNullOrWhiteSpace($name)) {
                $name = Split-Path -Leaf $_.Name
            }

            $usageKey = $name.ToLowerInvariant()
            $pathKey = ([string]$_.Name).ToLowerInvariant()
            $requestUsage = if ($RequestUsageByPath.ContainsKey($pathKey)) { $RequestUsageByPath[$pathKey] } elseif ($RequestUsageByName.ContainsKey($usageKey)) { $RequestUsageByName[$usageKey] } else { $null }
            $requestTotal = if ($null -ne $requestUsage) { [long]$requestUsage.totalTokens } else { 0L }
            $requestInput = if ($null -ne $requestUsage) { [long]$requestUsage.inputTokens } else { 0L }
            $requestOutput = if ($null -ne $requestUsage) { [long]$requestUsage.outputTokens } else { 0L }
            $requestCount = if ($null -ne $requestUsage) { [int]$requestUsage.requestCount } else { 0 }
            $latestRequestRun = if ($null -ne $requestUsage -and ($requestUsage.PSObject.Properties.Name -contains "lastRun")) { [string]$requestUsage.lastRun } else { "" }
            $threadActivity = if ($ThreadActivityByPath.ContainsKey($pathKey)) { $ThreadActivityByPath[$pathKey] } else { $null }
            $latestThreadActivityRun = if ($null -ne $threadActivity) { [string]$threadActivity.lastActivityRun } else { "" }
            $activeThreadCount = if ($null -ne $threadActivity) { [int]$threadActivity.threadCount } else { 0 }
            $requestUsageAfterHelper = $false
            $helperFirstRunAt = [DateTime]::MinValue
            $requestLatestRunAt = [DateTime]::MinValue
            if ($requestTotal -gt 0 -and -not [string]::IsNullOrWhiteSpace($firstRun) -and -not [string]::IsNullOrWhiteSpace($latestRequestRun)) {
                if ([DateTime]::TryParse($firstRun, [ref]$helperFirstRunAt) -and [DateTime]::TryParse($latestRequestRun, [ref]$requestLatestRunAt)) {
                    $requestUsageAfterHelper = ($requestLatestRunAt -ge $helperFirstRunAt)
                }
            }
            $helperAfter = if ($requestTotal -gt 0 -and $requestUsageAfterHelper) { $requestTotal } else { $latestOutput }
            $originalAll = $helperAfter + $latestSaved
            $requestToHelperRatio = if ($_.Count -gt 0) { [double]$requestCount / [double]$_.Count } else { 0.0 }
            $helperStaleAfterRequestMinutes = 0
            $helperStaleAfterRequest = $false
            $threadActiveAfterRequest = $false
            $threadActivityAfterRequestMinutes = 0
            $helperRunAt = [DateTime]::MinValue
            $requestRunAt = [DateTime]::MinValue
            if (-not [string]::IsNullOrWhiteSpace($lastRun) -and -not [string]::IsNullOrWhiteSpace($latestRequestRun)) {
                if ([DateTime]::TryParse($lastRun, [ref]$helperRunAt) -and [DateTime]::TryParse($latestRequestRun, [ref]$requestRunAt)) {
                    if ($requestRunAt -gt $helperRunAt) {
                        $helperStaleAfterRequestMinutes = [int][Math]::Floor(($requestRunAt - $helperRunAt).TotalMinutes)
                        $helperStaleAfterRequest = ($helperStaleAfterRequestMinutes -ge 30)
                    }
                }
            }
            $threadActivityAt = [DateTime]::MinValue
            if (-not [string]::IsNullOrWhiteSpace($latestThreadActivityRun) -and [DateTime]::TryParse($latestThreadActivityRun, [ref]$threadActivityAt)) {
                if ([string]::IsNullOrWhiteSpace($latestRequestRun)) {
                    $threadActiveAfterRequest = $true
                }
                elseif ([DateTime]::TryParse($latestRequestRun, [ref]$requestRunAt) -and $threadActivityAt -gt $requestRunAt) {
                    $threadActivityAfterRequestMinutes = [int][Math]::Floor(($threadActivityAt - $requestRunAt).TotalMinutes)
                    $threadActiveAfterRequest = ($threadActivityAfterRequestMinutes -ge 5)
                }
            }
            $needsHelperReview = (($requestCount -ge 20 -and $_.Count -gt 0 -and $requestCount -gt ($_.Count * 5)) -or $helperStaleAfterRequest)

            [PSCustomObject]@{
                conversationName = $name
                projectPath = $_.Name
                runCount = $_.Count
                requestUsageMatched = ($requestTotal -gt 0)
                requestCount = $requestCount
                requestInputTokens = $requestInput
                requestOutputTokens = $requestOutput
                requestTotalTokens = $requestTotal
                latestRequestRun = $latestRequestRun
                firstRun = $firstRun
                requestUsageAfterHelper = $requestUsageAfterHelper
                requestToHelperRatio = $requestToHelperRatio
                helperStaleAfterRequest = $helperStaleAfterRequest
                helperStaleAfterRequestMinutes = $helperStaleAfterRequestMinutes
                latestThreadActivityRun = $latestThreadActivityRun
                activeThreadCount = $activeThreadCount
                threadActiveAfterRequest = $threadActiveAfterRequest
                threadActivityAfterRequestMinutes = $threadActivityAfterRequestMinutes
                needsHelperReview = $needsHelperReview
                originalAllTokens = $originalAll
                helperAllTokens = $helperAfter
                totalOriginalTokens = $latestOriginal
                totalOutputTokens = $latestOutput
                totalSavedTokens = $latestSaved
                totalSavedPercent = (Get-Percent -Numerator ([double]$latestSaved) -Denominator ([double]$latestOriginal))
                latestOriginalTokens = $latestOriginal
                latestOutputTokens = $latestOutput
                latestSavedTokens = $latestSaved
                cumulativeOriginalTokens = $totalOriginal
                cumulativeOutputTokens = $totalOutput
                cumulativeSavedTokens = $totalSaved
                averageOutputTokens = if ($_.Count -gt 0) { [long][Math]::Floor(($totalOutput / [double]$_.Count) + 0.5) } else { 0L }
                cappedRunCount = $cappedCount
                contextStatus = if ($cappedCount -gt 0) { "打满上限" } else { "未打满" }
                lastRun = $lastRun
            }
        } | Sort-Object @{ Expression = "totalSavedTokens"; Descending = $true })
    }

    $requestUsage = Get-CodexRequestUsage
    $threadActivity = Get-CodexThreadActivity
    $requestUsageByName = @{}
    $requestUsageByPath = @{}
    $threadActivityByPath = @{}
    foreach ($usage in @($requestUsage)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$usage.conversationName)) {
            Add-RequestUsageAggregate -Map $requestUsageByName -Key ([string]$usage.conversationName.ToLowerInvariant()) -Usage $usage
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$usage.cwd)) {
            Add-RequestUsageAggregate -Map $requestUsageByPath -Key ([string]$usage.cwd.ToLowerInvariant()) -Usage $usage
        }
    }
    foreach ($activity in @($threadActivity)) {
        $pathKey = ([string]$activity.cwd).ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($pathKey)) {
            continue
        }
        if (-not $threadActivityByPath.ContainsKey($pathKey)) {
            $threadActivityByPath[$pathKey] = [PSCustomObject]@{
                lastActivityRun = ""
                threadCount = 0
            }
        }
        $item = $threadActivityByPath[$pathKey]
        $item.threadCount = [int]$item.threadCount + 1
        if ([string]$activity.lastActivityRun -gt [string]$item.lastActivityRun) {
            $item.lastActivityRun = [string]$activity.lastActivityRun
        }
    }

    $groups = New-HistoryGroups -Items $actualEntries -RequestUsageByName $requestUsageByName -RequestUsageByPath $requestUsageByPath -ThreadActivityByPath $threadActivityByPath
    $baselineGroups = New-HistoryGroups -Items $baselineEntries -RequestUsageByName $requestUsageByName -RequestUsageByPath $requestUsageByPath -ThreadActivityByPath $threadActivityByPath
    $trackedNames = @{}
    $trackedPaths = @{}
    foreach ($group in @($groups)) {
        $trackedNames[[string]$group.conversationName.ToLowerInvariant()] = $true
        $trackedPaths[[string]$group.projectPath.ToLowerInvariant()] = $true
    }
    $unmatchedRequestThreads = @($requestUsage | Where-Object {
        $nameKey = [string]$_.conversationName.ToLowerInvariant()
        $pathKey = [string]$_.cwd.ToLowerInvariant()
        [long]$_.totalTokens -gt 0 -and
        ((-not [string]::IsNullOrWhiteSpace($pathKey) -and -not $trackedPaths.ContainsKey($pathKey)) -or
         ([string]::IsNullOrWhiteSpace($pathKey) -and -not $trackedNames.ContainsKey($nameKey)))
    } | Sort-Object @{ Expression = "totalTokens"; Descending = $true } | Select-Object -First 8)
    <#
    $groups = $actualEntries | Group-Object -Property projectPath | ForEach-Object {
        $totalOriginal = 0L
        $totalOutput = 0L
        $totalSaved = 0L
        $lastRun = ""
        $name = ""

        foreach ($entry in $_.Group) {
            $totalOriginal += [long]$entry.originalTokens
            $totalOutput += [long]$entry.outputTokens
            $totalSaved += [long]$entry.savedTokens
            if ([string]$entry.generatedAt -gt $lastRun) {
                $lastRun = [string]$entry.generatedAt
            }
            if ([string]::IsNullOrWhiteSpace($name) -and $entry.PSObject.Properties.Name -contains "conversationName") {
                $name = [string]$entry.conversationName
            }
        }

        if ([string]::IsNullOrWhiteSpace($name)) {
            $name = Split-Path -Leaf $_.Name
        }

        [PSCustomObject]@{
            conversationName = $name
            projectPath = $_.Name
            runCount = $_.Count
            totalOriginalTokens = $totalOriginal
            totalOutputTokens = $totalOutput
            totalSavedTokens = $totalSaved
            totalSavedPercent = (Get-Percent -Numerator ([double]$totalSaved) -Denominator ([double]$totalOriginal))
            lastRun = $lastRun
        }
    } | Sort-Object @{ Expression = "totalSavedTokens"; Descending = $true }
    #>

    $allOriginal = 0L
    $allOutput = 0L
    $allSaved = 0L
    $allOriginalAll = 0L
    $allHelperAll = 0L
    foreach ($group in $groups) {
        $allOriginal += [long]$group.totalOriginalTokens
        $allOutput += [long]$group.totalOutputTokens
        $allSaved += [long]$group.totalSavedTokens
        $allOriginalAll += [long]$group.originalAllTokens
        $allHelperAll += [long]$group.helperAllTokens
    }

    $now = Get-Date
    $recentOutput = 0L
    $lastActualRun = ""
    $lastActualAt = $null
    foreach ($entry in $actualEntries) {
        $parsed = [DateTime]::MinValue
        if ([DateTime]::TryParse([string]$entry.generatedAt, [ref]$parsed)) {
            if ($parsed -gt $now.AddHours(-24)) {
                $recentOutput += [long]$entry.outputTokens
            }
            if ($null -eq $lastActualAt -or $parsed -gt $lastActualAt) {
                $lastActualAt = $parsed
                $lastActualRun = [string]$entry.generatedAt
            }
        }
    }

    $lastRunAgeMinutes = 0
    if ($null -ne $lastActualAt) {
        $lastRunAgeMinutes = [int][Math]::Max(0, [Math]::Floor(($now - $lastActualAt).TotalMinutes))
    }

    $usageStatus = "ok"
    $usageMessage = "检测正常：已经记录到实际 token 使用。"
    if ($actualEntries.Count -eq 0) {
        $usageStatus = "warn"
        $usageMessage = "还没有 actual 记录；其他对话需要先接入 token helper。"
    }
    elseif ($lastRunAgeMinutes -gt 360) {
        $usageStatus = "idle"
        $usageMessage = "最近 6 小时没有新的 actual 记录。"
    }

    $trendEntries = @($actualEntries | Sort-Object -Property generatedAt | Select-Object -Last 14 | ForEach-Object {
        [PSCustomObject]@{
            generatedAt = [string]$_.generatedAt
            conversationName = if ($_.PSObject.Properties.Name -contains "conversationName") { [string]$_.conversationName } else { Split-Path -Leaf ([string]$_.projectPath) }
            outputTokens = [long]$_.outputTokens
            savedTokens = [long]$_.savedTokens
            outputCapped = if ($_.PSObject.Properties.Name -contains "outputCapped") { [bool]$_.outputCapped } else { (($_.outputTokens -ge 3000 -and $_.outputTokens -le 3020) -or ($_.outputTokens -ge 6000 -and $_.outputTokens -le 6020)) }
        }
    })

    $cappedProjectCount = @($groups | Where-Object { $_.cappedRunCount -gt 0 }).Count

    $baselineOriginal = 0L
    $baselineOutput = 0L
    $baselineSaved = 0L
    foreach ($entry in $baselineEntries) {
        $baselineOriginal += [long]$entry.originalTokens
        $baselineOutput += [long]$entry.outputTokens
        $baselineSaved += [long]$entry.savedTokens
    }

    $requestLineSeries = @(Get-CodexRequestLineSeries)
    $sessionTokenLineSeries = @(Get-CodexSessionTokenLineSeries)
    foreach ($line in @($requestLineSeries)) {
        $pathKey = ([string]$line.projectPath).ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($pathKey)) {
            continue
        }
        $matchedGroup = @($groups | Where-Object { ([string]$_.projectPath).ToLowerInvariant() -eq $pathKey } | Select-Object -First 1)
        if ($matchedGroup.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$matchedGroup[0].conversationName)) {
            $line.name = [string]$matchedGroup[0].conversationName
        }
    }
    $helperReviewProjects = @($groups | Where-Object {
        ($_.PSObject.Properties.Name -contains "needsHelperReview") -and [bool]$_.needsHelperReview
    } | Sort-Object @{ Expression = {
        $ratio = if ($_.PSObject.Properties.Name -contains "requestToHelperRatio") { [double]$_.requestToHelperRatio } else { 0.0 }
        $stale = if ($_.PSObject.Properties.Name -contains "helperStaleAfterRequestMinutes") { [int]$_.helperStaleAfterRequestMinutes } else { 0 }
        [Math]::Max($ratio, ($stale / 30.0))
    }; Descending = $true } | Select-Object -First 8)

        return [PSCustomObject]@{
            historyPath = $HistoryPath
            conversationCount = @($groups).Count
            runCount = $actualEntries.Count
            rawRunCount = $rawActualRunCount
            dedupedRunCount = ($rawActualRunCount - $actualEntries.Count)
            effectiveRunCount = @($groups).Count
            totalOriginalTokens = $allOriginal
        totalOutputTokens = $allOutput
        totalSavedTokens = $allSaved
        totalSavedPercent = (Get-Percent -Numerator ([double]$allSaved) -Denominator ([double]$allOriginal))
        totalOriginalAllTokens = $allOriginalAll
        totalHelperAllTokens = $allHelperAll
        totalAllSavedTokens = ([Math]::Max(0L, ($allOriginalAll - $allHelperAll)))
        totalAllSavedPercent = (Get-Percent -Numerator ([double]([Math]::Max(0L, ($allOriginalAll - $allHelperAll)))) -Denominator ([double]$allOriginalAll))
        baselineRunCount = $baselineEntries.Count
        baselineOriginalTokens = $baselineOriginal
        baselineOutputTokens = $baselineOutput
        baselineSavedTokens = $baselineSaved
        baselineSavedPercent = (Get-Percent -Numerator ([double]$baselineSaved) -Denominator ([double]$baselineOriginal))
        refreshRunCount = $refreshEntries.Count
        conversations = @($groups)
        usageDetection = [PSCustomObject]@{
            status = $usageStatus
            message = $usageMessage
            lastRun = $lastActualRun
            lastRunAgeMinutes = $lastRunAgeMinutes
            recent24hOutputTokens = $recentOutput
            currentOutputTokens = $allOutput
            cappedProjectCount = $cappedProjectCount
            helperReviewProjectCount = @($helperReviewProjects).Count
            helperReviewProjects = @($helperReviewProjects)
            cappedRunCount = @($actualEntries | Where-Object {
                if ($_.PSObject.Properties.Name -contains "outputCapped") { [bool]$_.outputCapped }
                else { (($_.outputTokens -ge 3000 -and $_.outputTokens -le 3020) -or ($_.outputTokens -ge 6000 -and $_.outputTokens -le 6020)) }
            }).Count
            historicalRequestProjectCount = @($groups | Where-Object {
                ($_.PSObject.Properties.Name -contains "requestUsageMatched") -and
                [bool]$_.requestUsageMatched -and
                ($_.PSObject.Properties.Name -contains "requestUsageAfterHelper") -and
                -not [bool]$_.requestUsageAfterHelper -and
                [long]$_.requestTotalTokens -gt [long]$_.totalOutputTokens
            }).Count
            postHelperRequestProjectCount = @($groups | Where-Object {
                ($_.PSObject.Properties.Name -contains "requestUsageMatched") -and
                [bool]$_.requestUsageMatched -and
                ($_.PSObject.Properties.Name -contains "requestUsageAfterHelper") -and
                [bool]$_.requestUsageAfterHelper
            }).Count
            untrackedRequestThreadCount = @($unmatchedRequestThreads).Count
            untrackedRequestThreads = @($unmatchedRequestThreads)
            autoJoinDiagnostics = (Get-AutoJoinDiagnostics -UnmatchedRequestThreads $unmatchedRequestThreads)
            capMessage = if ($cappedProjectCount -gt 0) { "$cappedProjectCount 个项目打满 context 预算；相同写入 token 多半是 MaxChars 截断，不代表真实消耗相同。" } else { "未检测到明显 context 预算截断。" }
            trend = @($trendEntries)
            requestLineSeries = @($requestLineSeries)
            sessionTokenLineSeries = @($sessionTokenLineSeries)
            savedLineSeries = @(New-UsageLineSeries -ActualEntries @($actualEntries))
            lineSeries = @(New-UsageLineSeries -ActualEntries (@($actualEntries) + @($refreshEntries)))
            projectUsage = @($groups | Sort-Object @{ Expression = "helperAllTokens"; Descending = $true }, @{ Expression = "totalOutputTokens"; Descending = $true } | Select-Object -First 8)
        }
        baselineConversationCount = @($baselineGroups).Count
        baselineConversations = @($baselineGroups)
    }
}

function Get-AutoJoinDiagnostics {
    param([array]$UnmatchedRequestThreads = @())

    $joinable = 0
    $missingPath = 0
    $noPath = 0
    $topJoinable = New-Object System.Collections.Generic.List[object]

    foreach ($item in @($UnmatchedRequestThreads)) {
        $path = [string]$item.cwd
        if ([string]::IsNullOrWhiteSpace($path)) {
            $noPath++
            continue
        }
        if (-not (Test-Path -LiteralPath $path -PathType Container)) {
            $missingPath++
            continue
        }

        $joinable++
        if ($topJoinable.Count -lt 5) {
            [void]$topJoinable.Add([PSCustomObject]@{
                conversationName = [string]$item.conversationName
                cwd = $path
                totalTokens = [long]$item.totalTokens
            })
        }
    }

    return [PSCustomObject]@{
        totalUntracked = @($UnmatchedRequestThreads).Count
        joinableThreadCount = $joinable
        missingPathThreadCount = $missingPath
        noPathThreadCount = $noPath
        throttledThreadCount = 0
        topJoinableThreads = @($topJoinable.ToArray())
        lastAutoJoin = [PSCustomObject]@{
            attempted = 0
            succeeded = 0
            failed = 0
            skippedThrottled = 0
            at = ""
            errors = @()
        }
        message = if (@($UnmatchedRequestThreads).Count -eq 0) {
            "所有有路径的近期请求都已接入或已匹配。"
        }
        elseif ($joinable -gt 0) {
            "$joinable 个线程可由 dashboard 服务自动接入。"
        }
        else {
            "暂无可自动接入线程；可能缺少项目路径或路径不可访问。"
        }
    }
}

function New-UsageLineSeries {
    param(
        [array]$ActualEntries,
        [int]$MaxSeries = 16,
        [int]$MaxPoints = 24,
        [long]$MinOutputTokens = 1000
    )

    $byKey = @{}
    foreach ($entry in @($ActualEntries)) {
        $at = [DateTime]::MinValue
        if (-not [DateTime]::TryParse([string]$entry.generatedAt, [ref]$at)) {
            continue
        }

        $name = if ($entry.PSObject.Properties.Name -contains "conversationName" -and -not [string]::IsNullOrWhiteSpace([string]$entry.conversationName)) {
            [string]$entry.conversationName
        }
        else {
            Split-Path -Leaf ([string]$entry.projectPath)
        }
        $path = if ($entry.PSObject.Properties.Name -contains "projectPath") { [string]$entry.projectPath } else { "" }
        $key = if (-not [string]::IsNullOrWhiteSpace($path)) { $path.ToLowerInvariant() } else { $name.ToLowerInvariant() }

        if (-not $byKey.ContainsKey($key)) {
            $byKey[$key] = [PSCustomObject]@{
                name = $name
                projectPath = $path
                lastAt = $at
                totalOutputTokens = 0L
                totalSavedTokens = 0L
                points = New-Object System.Collections.Generic.List[object]
            }
        }

        $item = $byKey[$key]
        if ($at -gt [DateTime]$item.lastAt) {
            $item.lastAt = $at
        }
        $item.totalOutputTokens = [long]$item.totalOutputTokens + [long]$entry.outputTokens
        $item.totalSavedTokens = [long]$item.totalSavedTokens + [long]$entry.savedTokens
        [void]$item.points.Add([PSCustomObject]@{
            at = $at
            generatedAt = [string]$entry.generatedAt
            outputTokens = [long]$entry.outputTokens
            savedTokens = [long]$entry.savedTokens
            outputCapped = if ($entry.PSObject.Properties.Name -contains "outputCapped") { [bool]$entry.outputCapped } else { (([long]$entry.outputTokens -ge 3000 -and [long]$entry.outputTokens -le 3020) -or ([long]$entry.outputTokens -ge 6000 -and [long]$entry.outputTokens -le 6020)) }
        })
    }

    $series = New-Object System.Collections.Generic.List[object]
    foreach ($item in @($byKey.Values | Where-Object { [long]$_.totalOutputTokens -ge $MinOutputTokens } | Sort-Object @{ Expression = "lastAt"; Descending = $true }, @{ Expression = "totalOutputTokens"; Descending = $true } | Select-Object -First $MaxSeries)) {
        $runningOutput = 0L
        $runningSaved = 0L
        $points = New-Object System.Collections.Generic.List[object]
        foreach ($point in @($item.points.ToArray() | Sort-Object -Property at | Select-Object -Last $MaxPoints)) {
            $runningOutput += [long]$point.outputTokens
            $runningSaved += [long]$point.savedTokens
            [void]$points.Add([PSCustomObject]@{
                t = ([DateTime]$point.at).ToString("o")
                label = ([DateTime]$point.at).ToString("MM-dd HH:mm")
                value = $runningOutput
                outputTokens = [long]$point.outputTokens
                savedTokens = [long]$point.savedTokens
                cumulativeSavedTokens = $runningSaved
                outputCapped = [bool]$point.outputCapped
            })
        }

        [void]$series.Add([PSCustomObject]@{
            name = [string]$item.name
            projectPath = [string]$item.projectPath
            lastRun = ([DateTime]$item.lastAt).ToString("yyyy-MM-dd HH:mm:ss")
            totalOutputTokens = [long]$item.totalOutputTokens
            totalSavedTokens = [long]$item.totalSavedTokens
            points = @($points.ToArray())
        })
    }

    return @($series.ToArray())
}

function Get-CodexRequestLineSeries {
    param(
        [int]$MaxSeries = 16,
        [int]$MaxPoints = 36,
        [long]$MinTotalTokens = 1000
    )

    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($null -eq $python) {
        return @()
    }

    $script = @'
import datetime, json, os, re, sqlite3

home = os.path.expanduser("~")
session_path = os.path.join(home, ".codex", "session_index.jsonl")
logs_path = os.path.join(home, ".codex", "logs_2.sqlite")

titles = {}
try:
    with open(session_path, "r", encoding="utf-8") as f:
        for line in f:
            if line.strip():
                try:
                    row = json.loads(line)
                    titles[row.get("id", "")] = row.get("thread_name", "")
                except Exception:
                    pass
except Exception:
    pass

groups = {}
if os.path.exists(logs_path):
    con = sqlite3.connect(logs_path)
    cur = con.cursor()
    query = "select ts, thread_id, feedback_log_body from logs where feedback_log_body like '%response.completed%' and feedback_log_body like '%\"usage\"%'"
    for ts, thread_id, body in cur.execute(query):
        if not body:
            continue
        match = re.search(r"websocket event: (\{.*\})", body)
        if not match:
            continue
        try:
            usage = (json.loads(match.group(1)).get("response", {}).get("usage") or {})
            total = int(usage.get("total_tokens") or 0)
            output = int(usage.get("output_tokens") or 0)
            input_tokens = int(usage.get("input_tokens") or 0)
            cached_tokens = int(((usage.get("input_tokens_details") or {}).get("cached_tokens")) or 0)
        except Exception:
            continue
        if total <= 0:
            continue
        effective_total = max(0, total - cached_tokens)
        cwd_match = re.search(r"cwd=([^}]+)\}:try_run_sampling_request", body)
        cwd = cwd_match.group(1) if cwd_match else ""
        submission_match = re.search(r"submission.id=\"([^\"]+)\"", body)
        submission_id = submission_match.group(1) if submission_match else ("ts:" + str(ts or ""))
        title = titles.get(thread_id, "") or thread_id or ""
        name = title or (os.path.basename(cwd) if cwd else "未知对话")
        key = ("thread:" + thread_id) if thread_id else (cwd.lower() if cwd else ("name:" + name))
        item = groups.setdefault(key, {
            "name": name,
            "threadId": thread_id or "",
            "projectPath": cwd,
            "lastTs": 0,
            "totalTokens": 0,
            "effectiveTokens": 0,
            "rawTotalTokens": 0,
            "cachedTokens": 0,
            "inputTokens": 0,
            "outputTokens": 0,
            "points": [],
            "submissionTotals": {},
            "submissionRawTotals": {},
            "submissionCachedTotals": {},
            "submissionCounts": {},
        })
        item["lastTs"] = max(item["lastTs"], int(ts or 0))
        item["totalTokens"] += total
        item["effectiveTokens"] += effective_total
        item["rawTotalTokens"] += total
        item["cachedTokens"] += cached_tokens
        item["inputTokens"] += input_tokens
        item["outputTokens"] += output
        item["submissionTotals"][submission_id] = max(int(item["submissionTotals"].get(submission_id, 0)), total)
        item["submissionRawTotals"][submission_id] = max(int(item["submissionRawTotals"].get(submission_id, 0)), total)
        item["submissionCachedTotals"][submission_id] = max(int(item["submissionCachedTotals"].get(submission_id, 0)), cached_tokens)
        item["submissionCounts"][submission_id] = int(item["submissionCounts"].get(submission_id, 0)) + 1
        try:
            dt = datetime.datetime.fromtimestamp(int(ts or 0))
            iso = dt.isoformat()
            label = dt.strftime("%m-%d %H:%M")
        except Exception:
            iso = ""
            label = ""
        item["points"].append({
            "ts": int(ts or 0),
            "t": iso,
            "label": label,
            "submissionId": submission_id,
            "requestTokens": total,
            "effectiveRequestTokens": effective_total,
            "rawRequestTokens": total,
            "cachedTokens": cached_tokens,
            "inputTokens": input_tokens,
            "outputTokens": output,
        })

series = []
for item in sorted(groups.values(), key=lambda x: (x["lastTs"], x["totalTokens"]), reverse=True):
    if item["totalTokens"] < __MIN_TOTAL__:
        continue
    duplicate_groups = sum(1 for count in item.get("submissionCounts", {}).values() if int(count or 0) > 1)
    deduped_total = sum(int(value or 0) for value in item.get("submissionTotals", {}).values())
    deduped_raw = sum(int(value or 0) for value in item.get("submissionRawTotals", {}).values())
    deduped_cached = sum(int(value or 0) for value in item.get("submissionCachedTotals", {}).values())
    running = 0
    points = []
    for point in sorted(item["points"], key=lambda x: x["ts"])[-__MAX_POINTS__:]:
        running += int(point["requestTokens"] or 0)
        points.append({
            "t": point["t"],
            "label": point["label"],
            "submissionId": point.get("submissionId") or "",
            "value": running,
            "requestTokens": int(point["requestTokens"] or 0),
            "effectiveRequestTokens": int(point.get("effectiveRequestTokens") or 0),
            "rawRequestTokens": int(point.get("rawRequestTokens") or 0),
            "cachedTokens": int(point.get("cachedTokens") or 0),
            "inputTokens": int(point["inputTokens"] or 0),
            "outputTokens": int(point["outputTokens"] or 0),
            "outputCapped": False,
        })
    if not points:
        continue
    series.append({
        "name": item["name"],
        "threadId": item.get("threadId") or "",
        "projectPath": item["projectPath"],
        "lastRun": datetime.datetime.fromtimestamp(item["lastTs"]).strftime("%Y-%m-%d %H:%M:%S") if item["lastTs"] else "",
        "totalOutputTokens": int(item["totalTokens"]),
        "totalRequestTokens": int(item["totalTokens"]),
        "effectiveRequestTokens": int(item.get("effectiveTokens") or 0),
        "rawTotalRequestTokens": int(item.get("rawTotalTokens") or 0),
        "cachedRequestTokens": int(item.get("cachedTokens") or 0),
        "dedupedTotalRequestTokens": int(deduped_total),
        "dedupedRawTotalRequestTokens": int(deduped_raw),
        "dedupedCachedRequestTokens": int(deduped_cached),
        "submissionCount": len(item.get("submissionCounts", {})),
        "duplicateResponseGroupCount": int(duplicate_groups),
        "totalSavedTokens": 0,
        "points": points,
        "source": "request",
    })
    if len(series) >= __MAX_SERIES__:
        break

print(json.dumps(series, ensure_ascii=False))
'@
    $script = $script.Replace("__MIN_TOTAL__", [string]$MinTotalTokens).Replace("__MAX_POINTS__", [string]$MaxPoints).Replace("__MAX_SERIES__", [string]$MaxSeries)

    try {
        $json = $script | & $python.Source -
        if ([string]::IsNullOrWhiteSpace($json)) {
            return @()
        }
        $result = @($json | ConvertFrom-Json)
        if ($result.Count -eq 1 -and $result[0] -is [array]) {
            $result = @($result[0])
        }
        return @($result)
    }
    catch {
        return @()
    }
}

function Get-CodexSessionTokenLineSeries {
    param(
        [int]$MaxSeries = 16,
        [int]$MaxPoints = 240,
        [long]$MinTotalTokens = 1000
    )

    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($null -eq $python) {
        return @()
    }

    $script = @'
import collections, datetime, json, os, re

home = os.path.expanduser("~")
sessions_root = os.path.join(home, ".codex", "sessions")
session_index = os.path.join(home, ".codex", "session_index.jsonl")

titles = {}
try:
    with open(session_index, "r", encoding="utf-8") as f:
        for line in f:
            if line.strip():
                try:
                    row = json.loads(line)
                    titles[row.get("id", "")] = row.get("thread_name", "")
                except Exception:
                    pass
except Exception:
    pass

groups = {}
if os.path.isdir(sessions_root):
    files = []
    for root, _, names in os.walk(sessions_root):
        for name in names:
            if name.endswith(".jsonl"):
                path = os.path.join(root, name)
                try:
                    files.append((os.path.getmtime(path), path))
                except Exception:
                    pass
    files.sort(reverse=True)
    for _, path in files[:40]:
        thread_id = ""
        cwd = ""
        try:
            with open(path, "r", encoding="utf-8") as f:
                head = []
                for _ in range(40):
                    line = f.readline()
                    if not line:
                        break
                    head.append(line)
                for line in head:
                    try:
                        row = json.loads(line)
                    except Exception:
                        continue
                    if row.get("type") == "session_meta":
                        payload = row.get("payload") or {}
                        thread_id = payload.get("id") or ""
                        cwd = payload.get("cwd") or ""
                        break

            tail = collections.deque(maxlen=__MAX_SCAN_LINES__)
            with open(path, "r", encoding="utf-8") as f:
                for line in f:
                    tail.append(line)
        except Exception:
            continue
        title = titles.get(thread_id, "") or thread_id or os.path.basename(cwd) or "未知对话"
        key = ("thread:" + thread_id) if thread_id else (cwd.lower() if cwd else path)
        item = groups.setdefault(key, {
            "name": title,
            "threadId": thread_id,
            "projectPath": cwd,
            "lastTs": 0,
            "totalTokens": 0,
            "cachedTokens": 0,
            "effectiveTokens": 0,
            "points": [],
        })
        for line in tail:
            if '"type":"token_count"' not in line and '"type": "token_count"' not in line:
                continue
            try:
                row = json.loads(line)
            except Exception:
                continue
            payload = row.get("payload") or {}
            info = payload.get("info") or {}
            usage = info.get("last_token_usage") or {}
            total = int(usage.get("total_tokens") or 0)
            if total <= 0:
                continue
            cached = int(usage.get("cached_input_tokens") or 0)
            effective = max(0, total - cached)
            timestamp = row.get("timestamp") or ""
            try:
                dt = datetime.datetime.fromisoformat(timestamp.replace("Z", "+00:00")).astimezone()
                ts = int(dt.timestamp())
                label = dt.strftime("%m-%d %H:%M")
                iso = dt.replace(tzinfo=None).isoformat()
            except Exception:
                continue
            item["lastTs"] = max(item["lastTs"], ts)
            item["totalTokens"] += total
            item["cachedTokens"] += cached
            item["effectiveTokens"] += effective
            item["points"].append({
                "t": iso,
                "label": label,
                "requestTokens": total,
                "rawRequestTokens": total,
                "cachedTokens": cached,
                "effectiveRequestTokens": effective,
                "inputTokens": int(usage.get("input_tokens") or 0),
                "outputTokens": int(usage.get("output_tokens") or 0),
                "source": "session_token_count",
            })

series = []
for item in sorted(groups.values(), key=lambda x: (x["lastTs"], x["totalTokens"]), reverse=True):
    if item["totalTokens"] < __MIN_TOTAL__:
        continue
    points = sorted(item["points"], key=lambda x: x["t"])[-__MAX_POINTS__:]
    if not points:
        continue
    series.append({
        "name": item["name"],
        "threadId": item["threadId"],
        "projectPath": item["projectPath"],
        "lastRun": datetime.datetime.fromtimestamp(item["lastTs"]).strftime("%Y-%m-%d %H:%M:%S") if item["lastTs"] else "",
        "totalRequestTokens": int(item["totalTokens"]),
        "rawTotalRequestTokens": int(item["totalTokens"]),
        "cachedRequestTokens": int(item["cachedTokens"]),
        "effectiveRequestTokens": int(item["effectiveTokens"]),
        "totalOutputTokens": int(item["totalTokens"]),
        "points": points,
        "source": "session_token_count",
    })
    if len(series) >= __MAX_SERIES__:
        break

print(json.dumps(series, ensure_ascii=False))
'@
    $script = $script.Replace("__MIN_TOTAL__", [string]$MinTotalTokens).Replace("__MAX_POINTS__", [string]$MaxPoints).Replace("__MAX_SERIES__", [string]$MaxSeries).Replace("__MAX_SCAN_LINES__", "1500")

    try {
        $json = $script | & $python.Source -
        if ([string]::IsNullOrWhiteSpace($json)) {
            return @()
        }
        $result = @($json | ConvertFrom-Json)
        if ($result.Count -eq 1 -and $result[0] -is [array]) {
            $result = @($result[0])
        }
        return @($result)
    }
    catch {
        return @()
    }
}

function Get-UtcDateTimeOrNull {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $offset = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse($Value, [ref]$offset)) {
        return $offset.UtcDateTime
    }

    return $null
}

function Get-NewRequestTokensSince {
    param([string]$Since)

    $sinceAt = Get-UtcDateTimeOrNull $Since
    if ($null -eq $sinceAt) {
        $sinceAt = [DateTime]::MinValue
    }

    $tokens = 0L
    $maxAt = $sinceAt
    $series = @(Get-CodexRequestLineSeries -MaxSeries 128 -MaxPoints 500 -MinTotalTokens 1)
    foreach ($item in $series) {
        foreach ($point in @($item.points)) {
            $pointAt = Get-UtcDateTimeOrNull ([string]$point.t)
            if ($null -eq $pointAt) {
                continue
            }
            if ($pointAt -gt $sinceAt) {
                $tokens += [long]$point.requestTokens
                if ($pointAt -gt $maxAt) {
                    $maxAt = $pointAt
                }
            }
        }
    }

    return [PSCustomObject]@{
        tokens = [long]$tokens
        maxAtUtc = if ($maxAt -gt [DateTime]::MinValue) { $maxAt.ToUniversalTime().ToString("o") } else { "" }
        maxAtLocal = if ($maxAt -gt [DateTime]::MinValue) { $maxAt.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss") } else { "" }
    }
}

function Get-AppQuota {
    param([string]$Root)

    $path = Join-Path $Root ".codex/app-quota.json"
    if (Test-Path -LiteralPath $path) {
        try {
            $quota = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            $baseWeeklyPercent = if ($quota.PSObject.Properties.Name -contains "weeklyRemainingPercent") { [double]$quota.weeklyRemainingPercent } else { [double]$quota.weeklyUsedPercent }
            $baseShortPercent = if ($quota.PSObject.Properties.Name -contains "shortRemainingPercent") { [double]$quota.shortRemainingPercent } else { [double]$quota.shortUsedPercent }
            $estimatedWeeklyUsedPercent = $baseWeeklyPercent
            $estimatedShortUsedPercent = $baseShortPercent
            $currentRequest = Get-GlobalActualRequestTokens
            $currentOutput = Get-GlobalActualOutputTokens
            $basis = if ($quota.PSObject.Properties.Name -contains "quotaEstimateBasis") { [string]$quota.quotaEstimateBasis } else { "helper_context_tokens" }
            $calibrated = 0L
            $lastObserved = if ($quota.PSObject.Properties.Name -contains "lastObservedGlobalRequestTokens") { [long]$quota.lastObservedGlobalRequestTokens } else { 0L }
            $screenshotObserved = if ($quota.PSObject.Properties.Name -contains "quotaObservedRequestTokens") { [long]$quota.quotaObservedRequestTokens } else { 0L }
            $localBaseline = if ($quota.PSObject.Properties.Name -contains "localBaselineRequestTokens") { [long]$quota.localBaselineRequestTokens } else { 0L }
            $localObservedMax = if ($quota.PSObject.Properties.Name -contains "localObservedMaxRequestTokens") { [long]$quota.localObservedMaxRequestTokens } else { 0L }
            $localMultiplier = if ($quota.PSObject.Properties.Name -contains "localToQuotaMultiplier") { [double]$quota.localToQuotaMultiplier } else { 1.0 }
            $quotaLastAppliedAt = if ($quota.PSObject.Properties.Name -contains "quotaLastAppliedRequestAt") { [string]$quota.quotaLastAppliedRequestAt } elseif ($quota.PSObject.Properties.Name -contains "lastObservedAt") { [string]$quota.lastObservedAt } else { "" }
            $quotaBaselineAt = if ($quota.PSObject.Properties.Name -contains "quotaBaselineRequestAt") { [string]$quota.quotaBaselineRequestAt } else { $quotaLastAppliedAt }
            $quotaIncrementalTotal = if ($quota.PSObject.Properties.Name -contains "quotaIncrementalRequestTokens") { [long]$quota.quotaIncrementalRequestTokens } else { 0L }
            $newSinceLastApplied = Get-NewRequestTokensSince -Since $quotaLastAppliedAt
            $newSinceBaseline = Get-NewRequestTokensSince -Since $quotaBaselineAt
            $newRequestTokens = [long]$newSinceLastApplied.tokens
            if ($localMultiplier -le 0) {
                $localMultiplier = 1.0
            }
            $localEffective = [Math]::Max([Math]::Max([long]$currentRequest, [long]$localObservedMax), [long]$localBaseline)
            $current = $currentOutput
            if (($quota.PSObject.Properties.Name -contains "calibratedGlobalRequestTokens") -and [long]$quota.calibratedGlobalRequestTokens -gt 0 -and $currentRequest -gt 0) {
                if ([string]::IsNullOrWhiteSpace($basis) -or $basis -eq "helper_context_tokens") {
                    $basis = "real_request_tokens"
                }
                $calibrated = [long]$quota.calibratedGlobalRequestTokens
                if ($screenshotObserved -gt 0 -and $localBaseline -gt 0) {
                    $localDelta = [Math]::Max(0L, [long]$localEffective - [long]$localBaseline)
                    $quotaDelta = [long]([Math]::Floor(($localDelta * $localMultiplier) + 0.5))
                    $current = [Math]::Max([Math]::Max([long]$currentRequest, [long]$calibrated), [long]$screenshotObserved + [long]$quotaDelta)
                }
                else {
                    $current = [Math]::Max([Math]::Max([Math]::Max([long]$currentRequest, [long]$calibrated), [long]$lastObserved), [long]$screenshotObserved)
                }
                if ($newRequestTokens -gt 0 -and $lastObserved -gt 0) {
                    $current = [Math]::Max([long]$current, ([long]$lastObserved + [long]$newRequestTokens))
                }
                $current = [Math]::Max([long]$current, [long]$lastObserved)
            }
            elseif ($currentRequest -gt 0 -and -not ($quota.PSObject.Properties.Name -contains "calibratedGlobalRequestTokens")) {
                $basis = "real_request_tokens_needs_recalibration"
                $calibrated = $currentRequest
                $current = $currentRequest
            }
            elseif ($quota.PSObject.Properties.Name -contains "calibratedGlobalOutputTokens") {
                $calibrated = [long]$quota.calibratedGlobalOutputTokens
            }
            if (($quota.PSObject.Properties.Name -contains "quotaBaselineRequestAt") -and $screenshotObserved -gt 0) {
                $basis = "real_request_tokens_from_latest_screenshot"
                $calibrated = [long]$screenshotObserved
                $current = [long]$screenshotObserved + [long]$newSinceBaseline.tokens
                $newRequestTokens = [long]$newSinceBaseline.tokens
                $quotaIncrementalTotal = [long]$newSinceBaseline.tokens
            }

            if ($localEffective -gt $localObservedMax -and $quota.PSObject.Properties.Name -contains "calibratedGlobalRequestTokens") {
                $quota | Add-Member -NotePropertyName localObservedMaxRequestTokens -NotePropertyValue ([long]$localEffective) -Force
            }
            if ($newRequestTokens -gt 0 -and $quota.PSObject.Properties.Name -contains "calibratedGlobalRequestTokens") {
                $quotaIncrementalTotal += [long]$newRequestTokens
                $quota | Add-Member -NotePropertyName quotaIncrementalRequestTokens -NotePropertyValue ([long]$quotaIncrementalTotal) -Force
                if (-not [string]::IsNullOrWhiteSpace([string]$newSinceLastApplied.maxAtLocal)) {
                    $quota | Add-Member -NotePropertyName quotaLastAppliedRequestAt -NotePropertyValue ([string]$newSinceLastApplied.maxAtLocal) -Force
                }
            }

            if ($current -gt $lastObserved -and $quota.PSObject.Properties.Name -contains "calibratedGlobalRequestTokens") {
                $quota | Add-Member -NotePropertyName lastObservedGlobalRequestTokens -NotePropertyValue ([long]$current) -Force
                $quota | Add-Member -NotePropertyName lastObservedAt -NotePropertyValue (Get-Date -Format "yyyy-MM-dd HH:mm:ss") -Force
                Set-Content -LiteralPath $path -Value ($quota | ConvertTo-Json -Depth 8) -Encoding UTF8
                $lastObserved = [long]$current
            }
            elseif ($localEffective -gt $localObservedMax -and $quota.PSObject.Properties.Name -contains "calibratedGlobalRequestTokens") {
                Set-Content -LiteralPath $path -Value ($quota | ConvertTo-Json -Depth 8) -Encoding UTF8
            }

            if (($quota.PSObject.Properties.Name -contains "weeklyTotalEstimateTokens") -and $calibrated -gt 0) {
                $deltaOutput = [Math]::Max(0L, ([long]$current - [long]$calibrated))
                if ([long]$quota.weeklyTotalEstimateTokens -gt 0) {
                    $estimatedWeeklyUsedPercent = [Math]::Max(0.0, $baseWeeklyPercent - (($deltaOutput / [double]$quota.weeklyTotalEstimateTokens) * 100.0))
                }
                if (($quota.PSObject.Properties.Name -contains "shortTotalEstimateTokens") -and [long]$quota.shortTotalEstimateTokens -gt 0) {
                    $estimatedShortUsedPercent = [Math]::Max(0.0, $baseShortPercent - (($deltaOutput / [double]$quota.shortTotalEstimateTokens) * 100.0))
                }
            }
            if (($quota.PSObject.Properties.Name -contains "shortWindowResetAt") -and ($quota.PSObject.Properties.Name -contains "shortTotalEstimateTokens") -and [long]$quota.shortTotalEstimateTokens -gt 0) {
                $resetAt = Get-UtcDateTimeOrNull ([string]$quota.shortWindowResetAt)
                if ($null -ne $resetAt) {
                    $nowUtc = (Get-Date).ToUniversalTime()
                    while ($resetAt -le $nowUtc) {
                        $resetAt = $resetAt.AddHours(5)
                    }
                    $shortBaselineAt = if ($quota.PSObject.Properties.Name -contains "shortWindowBaselineRequestAt") { Get-UtcDateTimeOrNull ([string]$quota.shortWindowBaselineRequestAt) } else { $null }
                    if ($null -ne $shortBaselineAt -and $shortBaselineAt -lt $resetAt -and $shortBaselineAt -gt $resetAt.AddHours(-5)) {
                        $shortDelta = (Get-NewRequestTokensSince -Since $shortBaselineAt.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss")).tokens
                        $baselineRemaining = if ($quota.PSObject.Properties.Name -contains "shortWindowBaselineRemainingPercent") { [double]$quota.shortWindowBaselineRemainingPercent } else { $baseShortPercent }
                        $estimatedShortUsedPercent = [Math]::Max(0.0, [Math]::Min(100.0, $baselineRemaining - (($shortDelta / [double]$quota.shortTotalEstimateTokens) * 100.0)))
                    }
                    else {
                        $windowStart = $resetAt.AddHours(-5)
                        $shortUsed = (Get-NewRequestTokensSince -Since $windowStart.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss")).tokens
                        $estimatedShortUsedPercent = [Math]::Max(0.0, [Math]::Min(100.0, 100.0 - (($shortUsed / [double]$quota.shortTotalEstimateTokens) * 100.0)))
                    }
                    $quota | Add-Member -NotePropertyName shortWindowResetAt -NotePropertyValue ($resetAt.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss")) -Force
                }
            }

            return [PSCustomObject]@{
                configured = $true
                path = $path
                shortWindowLabel = [string]$quota.shortWindowLabel
                shortUsedPercent = $baseShortPercent
                shortRemainingPercent = $baseShortPercent
                estimatedShortUsedPercent = [double]([Math]::Round($estimatedShortUsedPercent, 1))
                shortWindowResetAt = if ($quota.PSObject.Properties.Name -contains "shortWindowResetAt") { [string]$quota.shortWindowResetAt } else { "" }
                shortWindowStartedAt = if ($quota.PSObject.Properties.Name -contains "shortWindowStartedAt") { [string]$quota.shortWindowStartedAt } else { "" }
                weeklyWindowLabel = [string]$quota.weeklyWindowLabel
                weeklyUsedPercent = $baseWeeklyPercent
                weeklyRemainingPercent = $baseWeeklyPercent
                estimatedWeeklyUsedPercent = [double]([Math]::Round($estimatedWeeklyUsedPercent, 1))
                weeklyResetLabel = [string]$quota.weeklyResetLabel
                updatedAt = [string]$quota.updatedAt
                calibratedGlobalOutputTokens = if ($quota.PSObject.Properties.Name -contains "calibratedGlobalOutputTokens") { [long]$quota.calibratedGlobalOutputTokens } else { 0L }
                calibratedGlobalRequestTokens = if ($quota.PSObject.Properties.Name -contains "calibratedGlobalRequestTokens") { [long]$quota.calibratedGlobalRequestTokens } else { $currentRequest }
                currentGlobalRequestTokens = if ($calibrated -gt 0) { [long]$current } else { [long]$currentRequest }
                localGlobalRequestTokens = [long]$currentRequest
                localBaselineRequestTokens = [long]$localBaseline
                localObservedMaxRequestTokens = [long]$localEffective
                localToQuotaMultiplier = [double]$localMultiplier
                quotaObservedRequestTokens = [long]$screenshotObserved
                unobservedRequestTokens = [long]([Math]::Max(0L, [long]$current - [long]$currentRequest))
                lastObservedGlobalRequestTokens = [long][Math]::Max([long]$lastObserved, [long]$currentRequest)
                lastObservedAt = if ($quota.PSObject.Properties.Name -contains "lastObservedAt") { [string]$quota.lastObservedAt } else { "" }
                quotaLogResetProtected = [bool]($currentRequest -lt $localObservedMax)
                quotaIncrementalRequestTokens = [long]$quotaIncrementalTotal
                quotaLastAppliedRequestAt = if ($quota.PSObject.Properties.Name -contains "quotaLastAppliedRequestAt") { [string]$quota.quotaLastAppliedRequestAt } else { "" }
                quotaNewRequestTokensApplied = [long]$newRequestTokens
                quotaEstimateBasis = $basis
                weeklyTotalEstimateTokens = if ($quota.PSObject.Properties.Name -contains "weeklyTotalEstimateTokens") { [long]$quota.weeklyTotalEstimateTokens } else { 0L }
                shortTotalEstimateTokens = if ($quota.PSObject.Properties.Name -contains "shortTotalEstimateTokens") { [long]$quota.shortTotalEstimateTokens } else { 0L }
            }
        }
        catch {
            return [PSCustomObject]@{
                configured = $false
                path = $path
                errorMessage = $_.Exception.Message
                shortWindowLabel = ""
                shortUsedPercent = 0.0
                estimatedShortUsedPercent = 0.0
                weeklyWindowLabel = ""
                weeklyUsedPercent = 0.0
                estimatedWeeklyUsedPercent = 0.0
                weeklyResetLabel = ""
                updatedAt = ""
                calibratedGlobalOutputTokens = 0L
                calibratedGlobalRequestTokens = 0L
                currentGlobalRequestTokens = 0L
                localGlobalRequestTokens = 0L
                localBaselineRequestTokens = 0L
                localObservedMaxRequestTokens = 0L
                localToQuotaMultiplier = 1.0
                quotaObservedRequestTokens = 0L
                unobservedRequestTokens = 0L
                quotaEstimateBasis = ""
                weeklyTotalEstimateTokens = 0L
                shortTotalEstimateTokens = 0L
            }
        }
    }

    return [PSCustomObject]@{
        configured = $false
        path = $path
        shortWindowLabel = ""
        shortUsedPercent = 0.0
        estimatedShortUsedPercent = 0.0
        weeklyWindowLabel = ""
        weeklyUsedPercent = 0.0
        estimatedWeeklyUsedPercent = 0.0
        weeklyResetLabel = ""
        updatedAt = ""
        calibratedGlobalOutputTokens = 0L
        calibratedGlobalRequestTokens = 0L
        currentGlobalRequestTokens = 0L
        localGlobalRequestTokens = 0L
        localBaselineRequestTokens = 0L
        localObservedMaxRequestTokens = 0L
        localToQuotaMultiplier = 1.0
        quotaObservedRequestTokens = 0L
        unobservedRequestTokens = 0L
        quotaEstimateBasis = ""
        weeklyTotalEstimateTokens = 0L
        shortTotalEstimateTokens = 0L
    }
}

function Get-GlobalActualOutputTokens {
    $historyPath = Join-Path $env:USERPROFILE ".codex\codex-token-helper-history.jsonl"
    $total = 0L
    if (-not (Test-Path -LiteralPath $historyPath)) {
        return $total
    }

    foreach ($line in (Get-Content -LiteralPath $historyPath)) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        try {
            $entry = $line | ConvertFrom-Json
            if (-not ($entry.PSObject.Properties.Name -contains "runKind") -or $entry.runKind -eq "actual") {
                $total += [long]$entry.outputTokens
            }
        }
        catch {
        }
    }

    return $total
}

function Get-GlobalActualRequestTokens {
    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($null -eq $python) {
        return 0L
    }

    $script = @'
import json, os, re, sqlite3
logs_path = os.path.join(os.path.expanduser("~"), ".codex", "logs_2.sqlite")
total = 0
if os.path.exists(logs_path):
    con = sqlite3.connect(logs_path)
    cur = con.cursor()
    for (body,) in cur.execute("select feedback_log_body from logs where feedback_log_body like '%response.completed%' and feedback_log_body like '%\"usage\"%'"):
        if not body:
            continue
        m = re.search(r"websocket event: (\{.*\})", body)
        if not m:
            continue
        try:
            usage = (json.loads(m.group(1)).get("response", {}).get("usage") or {})
            total += int(usage.get("total_tokens") or 0)
        except Exception:
            pass
print(total)
'@

    try {
        $raw = $script | & $python.Source -
        $value = 0L
        [void][long]::TryParse([string]$raw, [ref]$value)
        return $value
    }
    catch {
        return 0L
    }
}

function Get-StatsAudit {
    param([object]$GlobalHistory)

    $warnings = New-Object System.Collections.Generic.List[object]
    foreach ($item in @($GlobalHistory.conversations)) {
        if ($item.totalOriginalTokens -eq 0 -and $item.totalOutputTokens -gt 0) {
            [void]$warnings.Add([PSCustomObject]@{
                severity = "info"
                message = "项目 '$($item.conversationName)' 没有可统计文本候选，只有 context 外壳。"
            })
        }
        elseif ($item.totalSavedPercent -ge 99 -and $item.totalOriginalTokens -gt 1000000) {
            [void]$warnings.Add([PSCustomObject]@{
                severity = "info"
                message = "项目 '$($item.conversationName)' 文本候选很大，减少比例接近 100%；可在异常表中复核是否包含日志或导出文件。"
            })
        }
        if (($item.PSObject.Properties.Name -contains "cappedRunCount") -and $item.cappedRunCount -gt 0) {
            [void]$warnings.Add([PSCustomObject]@{
                severity = "info"
                message = "项目 '$($item.conversationName)' 打满 context 预算；写入 token 是上限估算，不代表真实 API 消耗。"
            })
        }
        if (($item.PSObject.Properties.Name -contains "needsHelperReview") -and [bool]$item.needsHelperReview) {
            $isCurrentStale = (($item.PSObject.Properties.Name -contains "helperStaleAfterRequest") -and [bool]$item.helperStaleAfterRequest)
            [void]$warnings.Add([PSCustomObject]@{
                severity = if ($isCurrentStale) { "warning" } else { "info" }
                message = if ($isCurrentStale) {
                    "项目 '$($item.conversationName)' 最新 Codex 请求晚于 helper actual，需要刷新 helper。"
                }
                else {
                    "项目 '$($item.conversationName)' 历史 Codex 请求多于 helper actual；这是历史覆盖不足，不代表当前后台进程耗 token。"
                }
            })
        }
    }

    $warningArray = @($warnings.ToArray())
    $warningCount = @($warningArray | Where-Object { [string]$_.severity -ne "info" }).Count
    $ok = $warningCount -eq 0

    return [PSCustomObject]@{
        ok = $ok
        warningCount = $warningCount
        infoCount = @($warningArray | Where-Object { [string]$_.severity -eq "info" }).Count
        warnings = $warningArray
    }
}

function Get-CodexRequestUsage {
    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($null -eq $python) {
        return @()
    }

    $script = @'
import datetime, json, os, re, sqlite3, sys

home = os.path.expanduser("~")
session_path = os.path.join(home, ".codex", "session_index.jsonl")
logs_path = os.path.join(home, ".codex", "logs_2.sqlite")

titles = {}
try:
    with open(session_path, "r", encoding="utf-8") as f:
        for line in f:
            if not line.strip():
                continue
            try:
                row = json.loads(line)
                titles[row.get("id", "")] = row.get("thread_name", "")
            except Exception:
                pass
except Exception:
    pass

usage = {}
if os.path.exists(logs_path):
    con = sqlite3.connect(logs_path)
    cur = con.cursor()
    query = "select ts, thread_id, feedback_log_body from logs where feedback_log_body like '%response.completed%' and feedback_log_body like '%\"usage\"%'"
    for ts, thread_id, body in cur.execute(query):
        if not thread_id or not body:
            continue
        match = re.search(r"websocket event: (\{.*\})", body)
        if not match:
            continue
        try:
            event = json.loads(match.group(1))
            data = event.get("response", {}).get("usage") or {}
        except Exception:
            continue
        total = int(data.get("total_tokens") or 0)
        if total <= 0:
            continue
        cwd_match = re.search(r"cwd=([^}]+)\}:try_run_sampling_request", body)
        cwd = cwd_match.group(1) if cwd_match else ""
        item = usage.setdefault(thread_id, {
            "threadId": thread_id,
            "conversationName": titles.get(thread_id, thread_id),
            "cwd": cwd,
            "requestCount": 0,
            "inputTokens": 0,
            "outputTokens": 0,
            "totalTokens": 0,
            "lastTs": 0,
        })
        item["requestCount"] += 1
        item["inputTokens"] += int(data.get("input_tokens") or 0)
        item["outputTokens"] += int(data.get("output_tokens") or 0)
        item["totalTokens"] += total
        item["lastTs"] = max(int(item.get("lastTs") or 0), int(ts or 0))

for item in usage.values():
    item["lastRun"] = datetime.datetime.fromtimestamp(item["lastTs"]).strftime("%Y-%m-%d %H:%M:%S") if item.get("lastTs") else ""

print(json.dumps(list(usage.values()), ensure_ascii=False))
'@

    try {
        $json = $script | & $python.Source -
        if ([string]::IsNullOrWhiteSpace($json)) {
            return @()
        }
        $result = @($json | ConvertFrom-Json)
        if ($result.Count -eq 1 -and $result[0] -is [array]) {
            $result = @($result[0])
        }
        return @($result)
    }
    catch {
        return @()
    }
}

function Get-CodexThreadActivity {
    $sessionsRoot = Join-Path $env:USERPROFILE ".codex\sessions"
    if (-not (Test-Path -LiteralPath $sessionsRoot -PathType Container)) {
        return @()
    }

    $items = New-Object System.Collections.Generic.List[object]
    foreach ($file in @(Get-ChildItem -LiteralPath $sessionsRoot -Recurse -Filter "*.jsonl" -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 40)) {
        $threadId = ""
        $cwd = ""
        $lastTimestamp = ""
        try {
            foreach ($line in @(Get-Content -LiteralPath $file.FullName -First 6 -ErrorAction Stop)) {
                if ([string]::IsNullOrWhiteSpace($line)) {
                    continue
                }
                $row = $null
                try { $row = $line | ConvertFrom-Json } catch { continue }
                if (($row.PSObject.Properties.Name -contains "type") -and [string]$row.type -eq "session_meta") {
                    if ($row.payload.PSObject.Properties.Name -contains "id") { $threadId = [string]$row.payload.id }
                    if ($row.payload.PSObject.Properties.Name -contains "cwd") { $cwd = [string]$row.payload.cwd }
                    break
                }
            }

            foreach ($line in @(Get-Content -LiteralPath $file.FullName -Tail 30 -ErrorAction Stop)) {
                if ([string]::IsNullOrWhiteSpace($line)) {
                    continue
                }
                $row = $null
                try { $row = $line | ConvertFrom-Json } catch { continue }
                if (($row.PSObject.Properties.Name -contains "timestamp") -and -not [string]::IsNullOrWhiteSpace([string]$row.timestamp)) {
                    $lastTimestamp = [string]$row.timestamp
                }
            }
        }
        catch {
            continue
        }

        if ([string]::IsNullOrWhiteSpace($cwd)) {
            continue
        }

        $lastActivity = $file.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
        if (-not [string]::IsNullOrWhiteSpace($lastTimestamp)) {
            try {
                $lastActivity = ([DateTimeOffset]::Parse($lastTimestamp).LocalDateTime).ToString("yyyy-MM-dd HH:mm:ss")
            }
            catch {
            }
        }

        [void]$items.Add([PSCustomObject]@{
            threadId = $threadId
            cwd = $cwd
            lastActivityRun = $lastActivity
            sessionPath = $file.FullName
        })
    }

    return @($items.ToArray())
}

function Add-RequestUsageAggregate {
    param(
        [hashtable]$Map,
        [string]$Key,
        [object]$Usage
    )

    if ([string]::IsNullOrWhiteSpace($Key)) {
        return
    }

    if (-not $Map.ContainsKey($Key)) {
        $Map[$Key] = [PSCustomObject]@{
            conversationName = [string]$Usage.conversationName
            cwd = [string]$Usage.cwd
            requestCount = 0
            inputTokens = 0L
            outputTokens = 0L
            totalTokens = 0L
            lastTs = 0L
            lastRun = ""
            threadCount = 0
        }
    }

    $item = $Map[$Key]
    $item.requestCount = [int]$item.requestCount + [int]$Usage.requestCount
    $item.inputTokens = [long]$item.inputTokens + [long]$Usage.inputTokens
    $item.outputTokens = [long]$item.outputTokens + [long]$Usage.outputTokens
    $item.totalTokens = [long]$item.totalTokens + [long]$Usage.totalTokens
    if ($Usage.PSObject.Properties.Name -contains "lastTs") {
        $item.lastTs = [Math]::Max([long]$item.lastTs, [long]$Usage.lastTs)
    }
    if ([long]$item.lastTs -gt 0) {
        try {
            $item.lastRun = ([DateTimeOffset]::FromUnixTimeSeconds([long]$item.lastTs).LocalDateTime).ToString("yyyy-MM-dd HH:mm:ss")
        }
        catch {
            $item.lastRun = [string]$Usage.lastRun
        }
    }
    $item.threadCount = [int]$item.threadCount + 1
}

function New-DashboardHtml {
    param(
        [object]$Stats,
        [string]$StatsJson
    )

    $encodedJson = Escape-JsonForScript $StatsJson
    $generatedAt = Escape-Html $Stats.generatedAt
    $projectPath = Escape-Html $Stats.projectPath

    return @"
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Codex Token Dashboard</title>
  <style>
    :root {
      color-scheme: light;
      --bg: #f6f7f9;
      --panel: #ffffff;
      --panel-2: #eef3f8;
      --text: #18202a;
      --muted: #657282;
      --line: #d8e0ea;
      --green: #14855f;
      --blue: #246bcb;
      --amber: #a86405;
      --red: #b42318;
      --shadow: 0 10px 28px rgba(24, 32, 42, .08);
      --shadow-soft: 0 1px 2px rgba(24, 32, 42, .05);
    }

    * { box-sizing: border-box; }

    body {
      margin: 0;
      font-family: "Segoe UI", Arial, sans-serif;
      background: var(--bg);
      color: var(--text);
      letter-spacing: 0;
    }

    main {
      width: min(1180px, calc(100vw - 32px));
      margin: 0 auto;
      padding: 28px 0 36px;
    }

    header {
      display: flex;
      justify-content: space-between;
      gap: 18px;
      align-items: flex-start;
      margin-bottom: 18px;
      position: sticky;
      top: 0;
      z-index: 4;
      padding: 12px 0;
      background: rgba(246, 247, 249, .94);
      backdrop-filter: blur(10px);
    }

    h1 {
      margin: 0 0 8px;
      font-size: 28px;
      line-height: 1.15;
      font-weight: 700;
    }

    .meta {
      color: var(--muted);
      font-size: 13px;
      line-height: 1.55;
      word-break: break-all;
    }

    .badge {
      display: inline-flex;
      align-items: center;
      min-height: 30px;
      border: 1px solid var(--line);
      border-radius: 999px;
      padding: 5px 12px;
      background: var(--panel);
      color: var(--muted);
      white-space: nowrap;
      font-size: 13px;
    }

    .header-actions {
      display: flex;
      flex-wrap: wrap;
      gap: 8px;
      justify-content: flex-end;
      align-items: center;
      max-width: 520px;
    }

    .command-center {
      display: grid;
      grid-template-columns: minmax(320px, 1.18fr) minmax(280px, .92fr) minmax(260px, .9fr);
      gap: 12px;
      margin-bottom: 14px;
    }

    .metric-panel {
      display: flex;
      flex-direction: column;
      justify-content: space-between;
      min-height: 210px;
      padding: 18px;
      border: 1px solid var(--line);
      border-radius: 8px;
      background: var(--panel);
      box-shadow: var(--shadow);
    }

    .metric-panel.main {
      border-color: rgba(36, 107, 203, .24);
      background: linear-gradient(180deg, #ffffff, #f6f9fc);
    }

    .metric-head {
      align-items: center;
      justify-content: space-between;
      display: flex;
      gap: 12px;
      margin-bottom: 12px;
    }

    .metric-kicker {
      color: var(--muted);
      font-size: 12px;
      font-weight: 700;
    }

    .metric-primary {
      font-size: 42px;
      line-height: 1;
      font-weight: 780;
      font-variant-numeric: tabular-nums;
    }

    .metric-caption {
      color: var(--muted);
      font-size: 12px;
      line-height: 1.45;
      margin-top: 8px;
    }

    .mini-meter {
      height: 12px;
      margin-top: 14px;
      overflow: hidden;
      border: 1px solid var(--line);
      border-radius: 999px;
      background: var(--panel-2);
    }

    .mini-meter > span {
      display: block;
      width: var(--w);
      height: 100%;
      background: #246bcb;
      transition: width .2s ease;
    }

    .mini-meter.short > span { background: #14855f; }
    .mini-meter.saved > span { background: #14855f; }
    .mini-meter.warn > span { background: #a86405; }

    .metric-row {
      display: flex;
      justify-content: space-between;
      gap: 12px;
      align-items: baseline;
      padding-top: 10px;
      margin-top: 10px;
      border-top: 1px solid var(--line);
      color: var(--muted);
      font-size: 13px;
    }

    .metric-row strong {
      color: var(--text);
      font-size: 15px;
      font-variant-numeric: tabular-nums;
      white-space: nowrap;
    }

    .health-list {
      display: grid;
      gap: 8px;
      margin-top: 6px;
    }

    .grid {
      display: grid;
      grid-template-columns: repeat(4, minmax(0, 1fr));
      gap: 12px;
      margin-bottom: 12px;
    }

    .card, .panel {
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 8px;
      box-shadow: var(--shadow);
    }

    .card {
      padding: 16px;
      min-height: 118px;
      transition: border-color .15s ease, box-shadow .15s ease;
    }

    .card:hover {
      border-color: #b7c5d6;
      box-shadow: 0 12px 30px rgba(24, 32, 42, .1);
    }

    .label {
      color: var(--muted);
      font-size: 13px;
      margin-bottom: 10px;
    }

    .value {
      font-size: 30px;
      line-height: 1;
      font-weight: 750;
      font-variant-numeric: tabular-nums;
    }

    .hint {
      color: var(--muted);
      font-size: 12px;
      margin-top: 10px;
      line-height: 1.45;
    }

    .green { color: var(--green); }
    .blue { color: var(--blue); }
    .amber { color: var(--amber); }
    .red { color: var(--red); }

    .panel {
      padding: 18px;
      margin-top: 12px;
    }

    .panel.primary {
      padding: 20px;
      border-color: rgba(36, 107, 203, .22);
      box-shadow: 0 14px 34px rgba(24, 32, 42, .09);
    }

    .panel-head {
      display: flex;
      justify-content: space-between;
      gap: 16px;
      align-items: center;
      margin-bottom: 14px;
    }

    h2 {
      margin: 0;
      font-size: 17px;
      line-height: 1.25;
    }

    .meter {
      height: 18px;
      background: var(--panel-2);
      border: 1px solid var(--line);
      border-radius: 999px;
      overflow: hidden;
      position: relative;
    }

    .meter > span {
      display: block;
      height: 100%;
      width: var(--w);
      background: linear-gradient(90deg, #14855f, #246bcb);
    }

    .meter.plan > span {
      background: linear-gradient(90deg, #246bcb, #a86405);
    }

    .usage-insight-grid {
      display: grid;
      grid-template-columns: minmax(0, 1.2fr) minmax(320px, .8fr);
      gap: 16px;
      align-items: start;
    }

    .usage-monitor {
      display: grid;
      grid-template-columns: minmax(0, 1fr) minmax(240px, .34fr);
      gap: 14px;
      align-items: stretch;
      margin: 12px 0;
    }

    .usage-chart-shell {
      min-height: 320px;
      overflow: hidden;
      border: 1px solid var(--line);
      border-radius: 8px;
      background: #fff;
    }

    .usage-chart-shell svg {
      display: block;
      width: 100%;
      height: 320px;
    }

    .usage-legend {
      display: grid;
      align-content: start;
      gap: 8px;
      min-width: 0;
      max-height: 320px;
      overflow: auto;
      font-size: 12px;
    }

    .legend-item {
      display: grid;
      grid-template-columns: 10px minmax(0, 1fr);
      gap: 8px;
      align-items: center;
      padding: 8px;
      border: 1px solid var(--line);
      border-radius: 8px;
      background: #fff;
    }

    .legend-item.is-muted {
      opacity: .58;
    }

    .usage-kpis {
      display: grid;
      grid-template-columns: repeat(4, minmax(0, 1fr));
      gap: 10px;
      margin-top: 10px;
    }

    .kpi-tile {
      min-height: 82px;
      padding: 12px;
      border: 1px solid var(--line);
      border-radius: 8px;
      background: #fafbfc;
    }

    .kpi-tile .label {
      margin-bottom: 8px;
      font-size: 12px;
    }

    .kpi-tile .value {
      font-size: 24px;
    }

    .legend-swatch {
      width: 10px;
      height: 10px;
      border-radius: 999px;
      background: var(--c);
    }

    .legend-name {
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
      color: var(--text);
      font-weight: 650;
    }

    .legend-value {
      grid-column: 2;
      color: var(--muted);
      font-variant-numeric: tabular-nums;
      white-space: nowrap;
    }

    .legend-value strong {
      color: var(--text);
      font-weight: 750;
    }

    .usage-details {
      margin-top: 12px;
      border: 1px solid var(--line);
      border-radius: 8px;
      background: #fafbfc;
      overflow: hidden;
    }

    .usage-details summary {
      cursor: pointer;
      padding: 10px 12px;
      font-size: 13px;
      font-weight: 700;
      color: var(--text);
      list-style-position: inside;
    }

    .usage-details[open] summary {
      border-bottom: 1px solid var(--line);
    }

    .usage-details-body {
      padding: 12px;
    }

    .compact-list {
      display: grid;
      gap: 6px;
      margin-top: 10px;
      font-size: 12px;
      color: var(--muted);
    }

    .compact-list div {
      display: flex;
      justify-content: space-between;
      gap: 12px;
      border-top: 1px solid var(--line);
      padding-top: 6px;
    }

    .split {
      display: grid;
      grid-template-columns: minmax(0, 1.25fr) minmax(280px, .75fr);
      gap: 12px;
    }

    .plan-grid {
      display: grid;
      grid-template-columns: repeat(4, minmax(0, 1fr));
      gap: 12px;
      margin-top: 12px;
    }

    table {
      width: 100%;
      border-collapse: collapse;
      font-size: 13px;
    }

    .table-wrap {
      overflow-x: auto;
      border: 1px solid var(--line);
      border-radius: 8px;
    }

    .table-wrap table {
      min-width: 920px;
    }

    th, td {
      text-align: left;
      border-bottom: 1px solid var(--line);
      padding: 10px 8px;
      vertical-align: middle;
    }

    th {
      color: var(--muted);
      font-weight: 650;
      background: #fafbfc;
      position: sticky;
      top: 0;
      z-index: 1;
    }

    tbody tr:hover {
      background: #f8fafc;
    }

    td.num, th.num {
      text-align: right;
      font-variant-numeric: tabular-nums;
      white-space: nowrap;
    }

    .path {
      max-width: 520px;
      word-break: break-word;
      font-family: Consolas, "SFMono-Regular", monospace;
      font-size: 12px;
    }

    .state-badge {
      display: inline-flex;
      align-items: center;
      min-height: 24px;
      padding: 3px 8px;
      border-radius: 999px;
      border: 1px solid var(--line);
      background: #f8fafc;
      color: var(--muted);
      font-size: 12px;
      white-space: nowrap;
    }

    .state-badge.good {
      color: var(--green);
      border-color: rgba(20, 133, 95, .28);
      background: rgba(20, 133, 95, .08);
    }

    .state-badge.warn {
      color: var(--amber);
      border-color: rgba(168, 100, 5, .28);
      background: rgba(168, 100, 5, .08);
    }

    .state-stack {
      display: inline-flex;
      gap: 6px;
      flex-wrap: wrap;
      justify-content: flex-end;
    }

    button {
      border: 1px solid var(--line);
      border-radius: 8px;
      background: var(--panel);
      min-height: 34px;
      padding: 6px 10px;
      cursor: pointer;
      color: var(--text);
    }

    button:hover { border-color: var(--blue); }

    button:focus-visible,
    input:focus-visible {
      outline: 2px solid rgba(36, 107, 203, .35);
      outline-offset: 2px;
    }

    input[type="password"], input[type="text"], input[type="number"] {
      width: 100%;
      min-height: 34px;
      border: 1px solid var(--line);
      border-radius: 8px;
      padding: 6px 10px;
      font: inherit;
      background: var(--panel);
      color: var(--text);
    }

    .status {
      min-height: 18px;
      margin-top: 8px;
      color: var(--muted);
      font-size: 13px;
    }

    .details-panel {
      margin-top: 12px;
      border: 1px solid var(--line);
      border-radius: 8px;
      background: var(--panel);
      box-shadow: var(--shadow-soft);
      overflow: hidden;
    }

    .details-panel > summary {
      cursor: pointer;
      padding: 14px 16px;
      font-weight: 750;
      color: var(--text);
      list-style-position: inside;
    }

    .details-panel[open] > summary {
      border-bottom: 1px solid var(--line);
    }

    .details-body {
      padding: 0 16px 16px;
    }

    @media (max-width: 900px) {
      header, .panel-head { flex-direction: column; align-items: flex-start; }
      .grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
      .command-center { grid-template-columns: 1fr; }
      .plan-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
      .usage-kpis { grid-template-columns: repeat(2, minmax(0, 1fr)); }
      .usage-insight-grid { grid-template-columns: 1fr; }
      .usage-monitor { grid-template-columns: 1fr; }
      .split { grid-template-columns: 1fr; }
      .header-actions { justify-content: flex-start; }
    }

    @media (max-width: 560px) {
      main { width: min(100vw - 20px, 1180px); padding-top: 18px; }
      .grid { grid-template-columns: 1fr; }
      .metric-panel { min-height: auto; }
      .metric-primary { font-size: 34px; }
      .plan-grid { grid-template-columns: 1fr; }
      .usage-kpis { grid-template-columns: 1fr; }
      .value { font-size: 26px; }
      table { font-size: 12px; }
      th, td { padding: 8px 6px; }
    }
  </style>
</head>
<body>
  <main>
    <header>
      <div>
        <h1>Codex Token Dashboard</h1>
        <div class="meta">$projectPath<br>生成时间：$generatedAt</div>
      </div>
      <div class="header-actions">
        <div class="badge">token 为估算值，按字符数 / 4 计算</div>
        <button type="button" id="refreshStats">刷新</button>
        <div class="status" id="liveStatus">实时刷新已开启</div>
      </div>
    </header>

    <section class="command-center" aria-label="token command center">
      <article class="metric-panel main">
        <div>
          <div class="metric-head">
            <span class="metric-kicker">套餐额度</span>
            <span class="state-badge" id="quotaBasisBadge">等待校准</span>
          </div>
          <div class="metric-primary amber" id="overviewWeeklyRemaining">未设置</div>
          <div class="metric-caption" id="overviewWeeklyHint">等待 Codex App 校准</div>
          <div class="mini-meter warn" aria-label="weekly quota remaining"><span id="overviewWeeklyMeter" style="--w:0%"></span></div>
        </div>
        <div>
          <div class="metric-row"><span>短周期剩余</span><strong id="overviewShortRemaining">未设置</strong></div>
          <div class="mini-meter short" aria-label="short window quota remaining"><span id="overviewShortMeter" style="--w:0%"></span></div>
          <div class="metric-row"><span>周容量估算</span><strong id="overviewWeeklyCapacity">未设置</strong></div>
        </div>
      </article>
      <article class="metric-panel">
        <div>
          <div class="metric-head">
            <span class="metric-kicker">节省效果</span>
            <span class="state-badge good" id="savingBasisBadge">全对话口径</span>
          </div>
          <div class="metric-primary blue" id="overviewSavedTokens">0</div>
          <div class="metric-caption" id="overviewSavedHint">按全对话口径</div>
          <div class="mini-meter saved" aria-label="saved token ratio"><span id="overviewSavedMeter" style="--w:0%"></span></div>
        </div>
        <div>
          <div class="metric-row"><span>减少率</span><strong id="overviewSavedRate">0%</strong></div>
          <div class="metric-row"><span>helper 后实际</span><strong id="overviewActualAfter">0</strong></div>
          <div class="metric-row"><span>全对话减少</span><strong id="topAllSavedPercent">0%</strong></div>
        </div>
      </article>
      <article class="metric-panel">
        <div>
          <div class="metric-head">
            <span class="metric-kicker">系统健康</span>
            <span class="state-badge" id="topAuditState">--</span>
          </div>
          <div class="metric-primary green" id="overviewHealth">正常</div>
          <div class="metric-caption" id="overviewHealthHint">日志匹配与审计状态</div>
        </div>
        <div class="health-list">
          <div class="metric-row"><span>日志匹配</span><strong id="topMatchedState">--</strong></div>
          <div class="metric-row"><span>未接入线程</span><strong id="topUntrackedThreads">0</strong></div>
          <div class="metric-row"><span>刷新状态</span><strong id="overviewRefreshState">实时</strong></div>
        </div>
      </article>
    </section>

    <section class="panel primary">
      <div class="panel-head">
        <h2>Usage 监控</h2>
        <span class="meta" id="usageDetectionSummary"></span>
      </div>
      <div class="usage-kpis" aria-label="token usage detection summary">
        <article class="kpi-tile">
          <div class="label">Helper 总写入</div>
          <div class="value blue" id="usageCurrentOutput">0</div>
          <div class="hint">已接入对话的 context token</div>
        </article>
        <article class="kpi-tile">
          <div class="label">近 24 小时写入</div>
          <div class="value amber" id="usageRecent24h">0</div>
          <div class="hint" id="usageRecent24hHint">最近 actual context token</div>
        </article>
        <article class="kpi-tile">
          <div class="label">未接入线程</div>
          <div class="value" id="usageUntracked">0</div>
          <div class="hint" id="usageAutoJoinHint">自动接入监控</div>
        </article>
        <article class="kpi-tile">
          <div class="label">最近 actual</div>
          <div class="value green" id="usageLastRun">--</div>
          <div class="hint" id="usageLastRunHint">等待记录</div>
        </article>
      </div>
      <div class="usage-monitor" aria-label="recent conversation usage monitor">
        <div class="usage-chart-shell">
          <svg id="usageLineChart" viewBox="0 0 760 280" role="img" aria-label="最近 60 分钟 token 使用率面积图"></svg>
        </div>
        <div class="usage-legend" id="usageLineLegend"></div>
      </div>
      <div class="usage-monitor" aria-label="recent helper savings monitor">
        <div class="usage-chart-shell">
          <svg id="savedLineChart" viewBox="0 0 760 220" role="img" aria-label="最近 60 分钟 helper 节省 token 面积图"></svg>
        </div>
        <div class="usage-legend" id="savedLineLegend"></div>
      </div>
      <div class="status" id="usageDetectionStatus"></div>
      <div class="hint" id="usageLineHint"></div>
      <div class="hint" id="savedLineHint"></div>
      <details class="usage-details">
        <summary>项目消耗和异常</summary>
        <div class="usage-details-body">
          <div class="usage-insight-grid">
            <div>
              <div class="table-wrap">
                <table>
                  <thead>
                    <tr>
                      <th>项目</th>
                      <th class="num">helper 后实际</th>
                      <th class="num">请求/Helper</th>
                      <th class="num">旧请求审计</th>
                      <th class="num">累计减少</th>
                      <th class="num">减少率</th>
                      <th class="num">状态</th>
                    </tr>
                  </thead>
                  <tbody id="usageProjectRows"></tbody>
                </table>
              </div>
              <div class="hint" id="projectUsageHint"></div>
            </div>
            <div>
              <div class="table-wrap">
                <table>
                  <thead>
                    <tr>
                      <th>需要注意</th>
                      <th class="num">影响</th>
                    </tr>
                  </thead>
                  <tbody id="usageIssueRows"></tbody>
                </table>
              </div>
              <div class="hint" id="tokenTrendHint"></div>
            </div>
          </div>
        </div>
      </details>
    </section>

    <details class="details-panel">
      <summary>额度与节约明细</summary>
      <div class="details-body">
    <section class="panel">
      <div class="panel-head">
        <h2>节约有效性</h2>
        <span class="meta" id="effectivenessSummary"></span>
      </div>
      <div class="plan-grid" aria-label="token saving effectiveness">
        <article class="card">
          <div class="label">原本全对话估算</div>
          <div class="value amber" id="effectivenessActual">0</div>
          <div class="hint">没有 helper 时预计会进入对话的 token</div>
        </article>
        <article class="card">
          <div class="label">使用 helper 后实际</div>
          <div class="value green" id="effectivenessSaved">0</div>
          <div class="hint">Codex 日志匹配到的真实模型请求 token</div>
        </article>
        <article class="card">
          <div class="label">实际减少</div>
          <div class="value blue" id="effectivenessRatio">0%</div>
          <div class="hint">原本估算减去 helper 后实际</div>
        </article>
        <article class="card">
          <div class="label">减少率</div>
          <div class="value" id="effectivenessNet">0</div>
          <div class="hint">减少 token 占原本估算的比例</div>
        </article>
      </div>
      <div class="status" id="effectivenessLine"></div>
    </section>

    <section class="panel">
      <div class="panel-head">
        <h2>Codex App 额度</h2>
        <span class="meta" id="appQuotaMeta"></span>
      </div>
      <div class="plan-grid" aria-label="codex app quota metrics">
        <article class="card">
          <div class="label">短周期剩余</div>
          <div class="value green" id="appShortWindow">未设置</div>
          <div class="hint">例如 5小时</div>
        </article>
        <article class="card">
          <div class="label">短周期估算剩余率</div>
          <div class="value amber" id="appShortPercent">未设置</div>
          <div class="hint">从 App 剩余用量菜单读取</div>
        </article>
        <article class="card">
          <div class="label">周额度估算剩余率</div>
          <div class="value amber" id="appWeeklyPercent">未设置</div>
          <div class="hint" id="appWeeklyReset">重置日期未设置</div>
        </article>
        <article class="card">
          <div class="label">周容量估算</div>
          <div class="value green" id="appWeeklyCapacity">未设置</div>
          <div class="hint">由截图百分比变化反推</div>
        </article>
      </div>
    </section>
      </div>
    </details>

    <details class="details-panel">
      <summary>当前项目与性能保护</summary>
      <div class="details-body">
    <section class="grid" aria-label="token metrics">
      <article class="card">
        <div class="label">累计减少</div>
        <div class="value green" id="totalSavedTokens">0</div>
        <div class="hint" id="totalSavedHint">历史总节省 0%</div>
      </article>
      <article class="card">
        <div class="label">累计文本候选</div>
        <div class="value" id="totalOriginalTokens">0</div>
        <div class="hint">可作为 context 的文本候选估算</div>
      </article>
      <article class="card">
        <div class="label">累计写入</div>
        <div class="value blue" id="totalOutputTokens">0</div>
        <div class="hint">写入 context 的估算 token</div>
      </article>
      <article class="card">
        <div class="label">累计次数</div>
        <div class="value amber" id="historyRunCount">0</div>
        <div class="hint">`.codex/history.jsonl` 记录</div>
      </article>
    </section>

    <section class="grid" aria-label="current token metrics">
      <article class="card">
        <div class="label">当前上下文</div>
        <div class="value blue" id="currentTokens">0</div>
        <div class="hint">`.codex/context.md` 估算 token</div>
      </article>
      <article class="card">
        <div class="label">文本候选内容</div>
        <div class="value" id="originalTokens">0</div>
        <div class="hint">可作为 context 的文本候选估算</div>
      </article>
      <article class="card">
        <div class="label">预计减少</div>
        <div class="value green" id="savedTokens">0</div>
        <div class="hint" id="savedHint">减少比例 0%</div>
      </article>
      <article class="card">
        <div class="label">预算使用</div>
        <div class="value amber" id="budgetUsed">0%</div>
        <div class="hint" id="budgetHint">预算 0 token</div>
      </article>
      <article class="card">
        <div class="label">缓存复用</div>
        <div class="value green" id="cacheReferences">0</div>
        <div class="hint" id="cacheHint">低优先级稳定文件</div>
      </article>
    </section>

    <section class="panel">
      <div class="panel-head">
        <h2>压缩效果</h2>
        <span class="meta" id="fileSummary"></span>
      </div>
      <div class="meter" aria-label="saved token ratio"><span id="savedMeter" style="--w:0%"></span></div>
      <div class="hint" id="compressionLine"></div>
    </section>

    <section class="panel">
      <div class="panel-head">
        <h2>性能保护</h2>
        <span class="meta" id="coverageSummary"></span>
      </div>
      <div class="plan-grid" aria-label="coverage metrics">
        <article class="card">
          <div class="label">覆盖风险</div>
          <div class="value green" id="coverageRisk">低</div>
          <div class="hint">避免为了省 token 漏掉关键上下文</div>
        </article>
        <article class="card">
          <div class="label">当前改动</div>
          <div class="value blue" id="changedCoverage">0/0</div>
          <div class="hint">git status 中的改动文件</div>
        </article>
        <article class="card">
          <div class="label">入口/配置</div>
          <div class="value" id="essentialCoverage">0/0</div>
          <div class="hint">README、配置和入口文件</div>
        </article>
        <article class="card">
          <div class="label">近期文件</div>
          <div class="value amber" id="recentCoverage">0/0</div>
          <div class="hint">最近 7 天活跃文件</div>
        </article>
      </div>
      <div class="status" id="coverageStatus"></div>
    </section>
      </div>
    </details>

    <section class="panel">
      <div class="panel-head">
        <h2>所有对话统计</h2>
        <span class="meta" id="globalSummary"></span>
      </div>
      <div class="table-wrap">
        <table>
          <thead>
            <tr>
              <th>对话/项目</th>
              <th class="num">运行</th>
              <th class="num">原本全对话估算</th>
              <th class="num">使用 helper 后实际</th>
              <th class="num">状态</th>
              <th class="num">context 避免</th>
              <th class="num">当前口径减少</th>
            </tr>
          </thead>
          <tbody id="globalRows"></tbody>
        </table>
      </div>
      <div class="hint" id="globalLine"></div>
      <div class="hint">原本全对话估算 = Codex 日志里的真实模型请求 token + helper 估算避免读入的上下文 token；使用 helper 后实际 = Codex 日志里的真实模型请求 token。context 避免不是套餐后台扣减，日志未匹配时会退回 context 估算并在状态列标出。</div>
      <div class="status" id="auditLine"></div>
    </section>

    <details class="details-panel">
      <summary>审计和使用趋势</summary>
      <div class="details-body">
    <section class="panel">
      <div class="panel-head">
        <h2>数据审计</h2>
        <span class="meta" id="auditSummary"></span>
      </div>
      <div class="plan-grid" aria-label="data audit metrics">
        <article class="card">
          <div class="label">有效 actual</div>
          <div class="value blue" id="auditEffectiveRuns">0</div>
          <div class="hint">去重后进入统计</div>
        </article>
        <article class="card">
          <div class="label">重复 actual</div>
          <div class="value amber" id="auditDedupedRuns">0</div>
          <div class="hint">近距离重复已排除</div>
        </article>
        <article class="card">
          <div class="label">真实日志匹配</div>
          <div class="value green" id="auditMatchedRuns">0</div>
          <div class="hint">能对上 Codex 请求日志</div>
        </article>
        <article class="card">
          <div class="label">未接入线程</div>
          <div class="value amber" id="auditUntrackedThreads">0</div>
          <div class="hint">有真实请求但无 helper actual</div>
        </article>
      </div>
      <div class="status" id="auditDetailLine"></div>
    </section>

      </div>
    </details>
  </main>

  <script type="application/json" id="stats-data">$StatsJson</script>
  <script>
    let stats = JSON.parse(document.getElementById('stats-data').textContent);
    let latestHealth = null;
    let lastRenderedAt = 0;
    const fmt = new Intl.NumberFormat('zh-CN');
    const pct = (value) => Math.max(0, Math.min(100, value));
    const wholePercent = (numerator, denominator) => {
      const den = Number(denominator || 0);
      const num = Number(numerator || 0);
      if (den <= 0) return 0;
      const value = Math.floor((num / den) * 100);
      if (value >= 100 && num < den) return 99;
      return Math.max(0, Math.min(100, value));
    };

    function statNumber(root, path) {
      return path.reduce((value, key) => value && value[key] !== undefined ? value[key] : 0, root);
    }

    function shouldRenderStats(nextStats, force) {
      if (force || !stats || !stats.globalHistory) return true;
      const now = Date.now();
      const sameStableState =
        statNumber(nextStats, ['globalHistory', 'totalAllSavedTokens']) === statNumber(stats, ['globalHistory', 'totalAllSavedTokens']) &&
        statNumber(nextStats, ['globalHistory', 'conversationCount']) === statNumber(stats, ['globalHistory', 'conversationCount']) &&
        statNumber(nextStats, ['globalHistory', 'usageDetection', 'untrackedRequestThreadCount']) === statNumber(stats, ['globalHistory', 'usageDetection', 'untrackedRequestThreadCount']) &&
        statNumber(nextStats, ['appQuota', 'estimatedWeeklyUsedPercent']) === statNumber(stats, ['appQuota', 'estimatedWeeklyUsedPercent']) &&
        statNumber(nextStats, ['appQuota', 'estimatedShortUsedPercent']) === statNumber(stats, ['appQuota', 'estimatedShortUsedPercent']);
      if (sameStableState && now - lastRenderedAt < 15000) return false;
      return true;
    }

    function renderStats(nextStats, force = false) {
      if (!shouldRenderStats(nextStats, force)) {
        stats = nextStats;
        document.getElementById('stats-data').textContent = JSON.stringify(stats);
        return false;
      }
      stats = nextStats;
      lastRenderedAt = Date.now();
      document.getElementById('stats-data').textContent = JSON.stringify(stats);
      document.getElementById('totalSavedTokens').textContent = fmt.format(stats.history.totalSavedTokens);
      document.getElementById('totalOriginalTokens').textContent = fmt.format(stats.history.totalOriginalTokens);
      document.getElementById('totalOutputTokens').textContent = fmt.format(stats.history.totalOutputTokens);
      document.getElementById('historyRunCount').textContent = fmt.format(stats.history.runCount);
      document.getElementById('totalSavedHint').textContent = '历史总节省 ' + stats.history.totalSavedPercent + '%';
      const capacity = document.getElementById('appWeeklyCapacity');
      if (capacity) capacity.textContent = stats.appQuota && stats.appQuota.weeklyTotalEstimateTokens ? fmt.format(stats.appQuota.weeklyTotalEstimateTokens) : '未设置';
      document.getElementById('currentTokens').textContent = fmt.format(stats.outputTokens);
      document.getElementById('originalTokens').textContent = fmt.format(stats.originalTokens);
      document.getElementById('savedTokens').textContent = fmt.format(stats.savedTokens);
      document.getElementById('savedHint').textContent = '减少比例 ' + stats.savedPercent + '%';
      document.getElementById('budgetUsed').textContent = stats.budgetUsedPercent + '%';
      document.getElementById('budgetHint').textContent = '预算约 ' + fmt.format(stats.budgetTokens) + ' token';
      const cache = stats.contextCache || { hitCount: 0, missCount: 0, stableReferenceCount: 0, stableReferenceSavedTokens: 0 };
      document.getElementById('cacheReferences').textContent = fmt.format(cache.stableReferenceCount || 0);
      document.getElementById('cacheHint').textContent =
        '命中 ' + fmt.format(cache.hitCount || 0) + '，缓存引用少写约 ' + fmt.format(cache.stableReferenceSavedTokens || 0) + ' token';
      document.getElementById('savedMeter').style.setProperty('--w', pct(stats.savedPercent) + '%');
      document.getElementById('fileSummary').textContent = stats.candidateFileCount + ' 个候选文件，摘录 ' + stats.excerptedFileCount + ' 个';
      document.getElementById('compressionLine').textContent =
        '从约 ' + fmt.format(stats.originalTokens) + ' token 压到 ' + fmt.format(stats.outputTokens) + ' token，预计少用 ' + fmt.format(stats.savedTokens) + ' token。' +
        ' 缓存策略只压缩未变化的低优先级 normal 文件，本轮缓存引用 ' + fmt.format(cache.stableReferenceCount || 0) + ' 个。';
      renderCoverage(stats.coverageAudit || {});

      document.getElementById('globalSummary').textContent =
        stats.globalHistory.conversationCount + ' 个对话/项目，安装后实际记录 ' + stats.globalHistory.runCount + ' 次';
      document.getElementById('globalLine').textContent =
        '全对话口径：原本估算约 ' + fmt.format(stats.globalHistory.totalOriginalAllTokens || stats.globalHistory.totalOriginalTokens) +
        ' token，使用 helper 后实际请求约 ' + fmt.format(stats.globalHistory.totalHelperAllTokens || stats.globalHistory.totalOutputTokens) +
        ' token，估算减少 ' + fmt.format(stats.globalHistory.totalAllSavedTokens || stats.globalHistory.totalSavedTokens) +
        ' token，减少比例 ' + (stats.globalHistory.totalAllSavedPercent || stats.globalHistory.totalSavedPercent) + '%。' +
        ' 近距离重复 actual 已去重 ' + fmt.format(stats.globalHistory.dedupedRunCount || 0) + ' 次。' +
        ' 同项目旧 actual 只保留最新口径；静默刷新 ' + fmt.format(stats.globalHistory.refreshRunCount || 0) + ' 次，不计入实际节省。';
      const audit = stats.audit || { ok: true, warningCount: 0, warnings: [] };
      document.getElementById('auditLine').textContent = audit.ok
        ? '自检通过：未发现明显统计异常。'
        : '自检提示 ' + audit.warningCount + ' 项：' + audit.warnings.slice(0, 2).map((item) => item.message).join('；');
      renderDataAudit(stats.globalHistory || {}, audit);
      renderTopStatus(stats.globalHistory || {}, audit, latestHealth);
      renderOverview(stats.globalHistory || {}, stats.appQuota || {}, audit, latestHealth);

      const globalRows = document.getElementById('globalRows');
      globalRows.textContent = '';
      stats.globalHistory.conversations.forEach((item) => {
        const tr = document.createElement('tr');
        tr.innerHTML =
          '<td class="path"></td>' +
          '<td class="num">' + fmt.format(item.runCount) + '</td>' +
          '<td class="num">' + fmt.format(item.originalAllTokens || item.totalOriginalTokens) + '</td>' +
          '<td class="num">' + fmt.format(item.helperAllTokens || item.totalOutputTokens) + '</td>' +
          '<td class="num"><span class="state-stack">' +
            '<span class="state-badge ' + (item.requestUsageMatched ? 'good' : 'warn') + '">' + (item.requestUsageMatched ? '日志已匹配' : '仅 context 估算') + '</span>' +
            '<span class="state-badge ' + (item.contextStatus === '打满上限' ? 'warn' : 'good') + '">' + (item.contextStatus || '未知') + '</span>' +
          '</span></td>' +
          '<td class="num">' + fmt.format(item.totalSavedTokens) + '</td>' +
          '<td class="num">' + (item.originalAllTokens ? wholePercent(item.totalSavedTokens, item.originalAllTokens) : item.totalSavedPercent) + '%</td>';
        const pathCell = tr.querySelector('.path');
        pathCell.textContent = item.conversationName || item.projectPath || '未命名';
        pathCell.title = item.projectPath || '';
        globalRows.appendChild(tr);
      });

      renderTokenUsageDetection(stats.globalHistory.usageDetection || {});
      renderEffectiveness(stats.globalHistory || {});
      renderAppQuota(stats);
      return true;
    }

    function renderTopStatus(globalHistory, audit, health) {
      const conversations = Array.isArray(globalHistory.conversations) ? globalHistory.conversations : [];
      const matched = conversations.filter((item) => item.requestUsageMatched).length;
      const untracked = globalHistory.usageDetection ? Number(globalHistory.usageDetection.untrackedRequestThreadCount || 0) : 0;
      const healthStatus = health && health.status ? health.status : (audit && audit.ok ? 'ok' : 'warn');
      document.getElementById('topAuditState').textContent =
        healthStatus === 'ok' ? '通过' : healthStatus === 'error' ? '异常' : '复核';
      document.getElementById('topAuditState').className =
        'state-badge ' + (healthStatus === 'ok' ? 'good' : 'warn');
      document.getElementById('topMatchedState').textContent = fmt.format(matched) + '/' + fmt.format(conversations.length);
      document.getElementById('topMatchedState').className = matched === conversations.length && conversations.length > 0 ? 'green' : 'amber';
      document.getElementById('topAllSavedPercent').textContent = (globalHistory.totalAllSavedPercent || globalHistory.totalSavedPercent || 0) + '%';
      document.getElementById('topAllSavedPercent').className = 'green';
      document.getElementById('topUntrackedThreads').textContent = fmt.format(untracked);
      document.getElementById('topUntrackedThreads').className = untracked > 0 ? 'amber' : 'green';
    }

    function renderOverview(globalHistory, appQuota, audit, health) {
      const conversations = Array.isArray(globalHistory.conversations) ? globalHistory.conversations : [];
      const matched = conversations.filter((item) => item.requestUsageMatched).length;
      const untracked = globalHistory.usageDetection ? Number(globalHistory.usageDetection.untrackedRequestThreadCount || 0) : 0;
      const weeklyRemainingNumber = appQuota && appQuota.configured ? Number(appQuota.estimatedWeeklyUsedPercent || 0) : 0;
      const shortRemainingNumber = appQuota && appQuota.configured ? Number(appQuota.estimatedShortUsedPercent || 0) : 0;
      const weeklyRemaining = appQuota && appQuota.configured ? weeklyRemainingNumber + '%' : '未设置';
      document.getElementById('overviewWeeklyRemaining').textContent = weeklyRemaining;
      document.getElementById('overviewWeeklyHint').textContent =
        appQuota && appQuota.configured
          ? (appQuota.weeklyWindowLabel || '1周') + ' · 重置 ' + (appQuota.weeklyResetLabel || '未设置')
          : '等待 Codex App 校准';
      document.getElementById('overviewWeeklyMeter').style.setProperty('--w', pct(weeklyRemainingNumber) + '%');
      document.getElementById('overviewShortRemaining').textContent =
        appQuota && appQuota.configured ? (appQuota.shortWindowLabel || '短周期') + ' · ' + shortRemainingNumber + '%' : '未设置';
      document.getElementById('overviewShortMeter').style.setProperty('--w', pct(shortRemainingNumber) + '%');
      const hasUnobserved = appQuota && Number(appQuota.unobservedRequestTokens || 0) > 0;
      document.getElementById('quotaBasisBadge').textContent = appQuota && appQuota.configured ? (hasUnobserved ? '截图校准' : '已校准') : '等待校准';
      document.getElementById('quotaBasisBadge').className = 'state-badge ' + (appQuota && appQuota.configured ? (hasUnobserved ? 'warn' : 'good') : 'warn');
      document.getElementById('overviewWeeklyCapacity').textContent =
        appQuota && appQuota.weeklyTotalEstimateTokens ? fmt.format(appQuota.weeklyTotalEstimateTokens) : '未设置';
      const savedTokens = Number(globalHistory.totalAllSavedTokens || globalHistory.totalSavedTokens || 0);
      const savedPercent = Number(globalHistory.totalAllSavedPercent || globalHistory.totalSavedPercent || 0);
      document.getElementById('overviewSavedTokens').textContent = fmt.format(savedTokens);
      document.getElementById('overviewSavedHint').textContent =
        '原本 ' + fmt.format(globalHistory.totalOriginalAllTokens || globalHistory.totalOriginalTokens || 0) + ' token';
      document.getElementById('overviewSavedRate').textContent = savedPercent + '%';
      document.getElementById('overviewActualAfter').textContent = fmt.format(globalHistory.totalHelperAllTokens || globalHistory.totalOutputTokens || 0);
      document.getElementById('overviewSavedMeter').style.setProperty('--w', pct(savedPercent) + '%');

      const healthStatus = health && health.status ? health.status : '';
      const healthy = healthStatus
        ? healthStatus === 'ok'
        : audit && audit.ok && untracked === 0 && matched === conversations.length && conversations.length > 0;
      document.getElementById('overviewHealth').textContent =
        healthy ? '正常' : healthStatus === 'error' ? '异常' : '复核';
      document.getElementById('overviewHealth').className = 'metric-primary ' + (healthy ? 'green' : 'amber');
      document.getElementById('overviewHealthHint').textContent =
        health && health.message
          ? health.message + ' · ' + fmt.format(health.checks ? health.checks.length : 0) + ' 项检查'
          : '日志匹配 ' + fmt.format(matched) + '/' + fmt.format(conversations.length) + ' · 未接入 ' + fmt.format(untracked);
      document.getElementById('overviewRefreshState').textContent = untracked > 0 ? '接入中' : '实时';
    }

    function renderDataAudit(globalHistory, audit) {
      const conversations = Array.isArray(globalHistory.conversations) ? globalHistory.conversations : [];
      const matched = conversations.filter((item) => item.requestUsageMatched).length;
      const untracked = globalHistory.usageDetection ? Number(globalHistory.usageDetection.untrackedRequestThreadCount || 0) : 0;
      document.getElementById('auditEffectiveRuns').textContent = fmt.format(globalHistory.effectiveRunCount || conversations.length || 0);
      document.getElementById('auditDedupedRuns').textContent = fmt.format(globalHistory.dedupedRunCount || 0);
      document.getElementById('auditMatchedRuns').textContent = fmt.format(matched) + '/' + fmt.format(conversations.length);
      document.getElementById('auditUntrackedThreads').textContent = fmt.format(untracked);
      document.getElementById('auditSummary').textContent = audit && audit.ok ? '通过本地一致性检查' : '存在需要复核的统计提示';
      document.getElementById('auditDetailLine').textContent =
        '统计口径：有效 actual 采用同项目最新记录；重复 actual 不计入总节省；真实日志匹配来自 Codex 本地请求日志。项目累计节省请看 Usage 监控里的“累计减少”。' +
        (globalHistory.rawRunCount ? ' 原始 actual ' + fmt.format(globalHistory.rawRunCount) + ' 次，近距离去重后 ' + fmt.format(globalHistory.runCount || 0) + ' 次，进入总表 ' + fmt.format(globalHistory.effectiveRunCount || conversations.length || 0) + ' 个项目。' : '');
      document.getElementById('auditDetailLine').className =
        'status ' + (audit && audit.ok && untracked === 0 ? 'green' : untracked > 0 ? 'amber' : 'green');
    }

    function renderCoverage(audit) {
      const risk = audit.risk || 'unknown';
      const riskText = risk === 'high' ? '高' : risk === 'medium' ? '中' : risk === 'low' ? '低' : '未知';
      const riskClass = risk === 'high' ? 'value red' : risk === 'medium' ? 'value amber' : 'value green';
      document.getElementById('coverageRisk').textContent = riskText;
      document.getElementById('coverageRisk').className = riskClass;
      document.getElementById('changedCoverage').textContent = fmt.format(audit.changedFilesIncludedCount || 0) + '/' + fmt.format(audit.changedFileCount || 0);
      document.getElementById('essentialCoverage').textContent = fmt.format(audit.essentialFilesIncludedCount || 0) + '/' + fmt.format(audit.essentialFileCount || 0);
      document.getElementById('recentCoverage').textContent = fmt.format(audit.recentFilesIncludedCount || 0) + '/' + fmt.format(audit.recentFileCount || 0);
      document.getElementById('coverageSummary').textContent = '智能选择已开启';
      const warnings = Array.isArray(audit.warnings) ? audit.warnings : [];
      const omitted = Array.isArray(audit.omittedImportantFiles) ? audit.omittedImportantFiles : [];
      document.getElementById('coverageStatus').textContent =
        (warnings.length ? warnings.join('；') : '关键上下文覆盖正常。') +
        (omitted.length ? ' 被省略的高优先级文件：' + omitted.map((item) => item.path).join('、') + '。' : '');
      document.getElementById('coverageStatus').className =
        'status ' + (risk === 'high' ? 'red' : risk === 'medium' ? 'amber' : 'green');
    }

    function shortTime(value) {
      if (!value) return '';
      const parts = String(value).split(' ');
      return parts.length > 1 ? parts[1].slice(0, 5) : String(value).slice(0, 5);
    }

    function renderUsageLineChart(detection) {
      const svg = document.getElementById('usageLineChart');
      const legend = document.getElementById('usageLineLegend');
      const hint = document.getElementById('usageLineHint');
      const requestSeries = Array.isArray(detection.requestLineSeries) ? detection.requestLineSeries : [];
      const sessionSeries = Array.isArray(detection.sessionTokenLineSeries) ? detection.sessionTokenLineSeries : [];
      const helperSeries = Array.isArray(detection.savedLineSeries)
        ? detection.savedLineSeries
        : (Array.isArray(detection.lineSeries) ? detection.lineSeries : []);
      const sourceSeries = sessionSeries.length ? sessionSeries : (requestSeries.length ? requestSeries : helperSeries);
      const sourceLabel = sessionSeries.length ? 'session token_count' : (requestSeries.length ? 'completed usage.total_tokens' : 'helper 写入 token');
      svg.textContent = '';
      legend.textContent = '';

      const width = 760;
      const height = 280;
      const pad = { left: 66, right: 18, top: 26, bottom: 36 };
      const chartW = width - pad.left - pad.right;
      const chartH = height - pad.top - pad.bottom;
      const ns = 'http://www.w3.org/2000/svg';
      const add = (tag, attrs, text) => {
        const node = document.createElementNS(ns, tag);
        Object.entries(attrs || {}).forEach(([key, value]) => node.setAttribute(key, value));
        if (text !== undefined) node.textContent = text;
        svg.appendChild(node);
        return node;
      };
      const compact = (value) => {
        const n = Number(value || 0);
        if (n >= 1000000) return (n / 1000000).toFixed(n >= 10000000 ? 0 : 1) + 'M';
        if (n >= 1000) return (n / 1000).toFixed(n >= 10000 ? 0 : 1) + 'K';
        return fmt.format(Math.round(n));
      };
      const now = Date.now();
      const windowMs = 60 * 60 * 1000;
      const bucketMs = 60 * 1000;
      const startMs = now - windowMs;
      const bucketCount = 60;
      const buckets = Array.from({ length: bucketCount }, (_, index) => ({
        ms: startMs + index * bucketMs,
        tokens: 0,
        cached: 0,
        effective: 0
      }));
      const contributors = new Map();
      sourceSeries.forEach((item) => {
        (Array.isArray(item.points) ? item.points : []).forEach((point) => {
          const ms = Date.parse(point.t);
          if (!Number.isFinite(ms) || ms < startMs || ms > now) return;
          const index = Math.min(bucketCount - 1, Math.max(0, Math.floor((ms - startMs) / bucketMs)));
          const tokens = Number(point.requestTokens || point.outputTokens || 0);
          const cached = Number(point.cachedTokens || 0);
          const effective = Number(point.effectiveRequestTokens || Math.max(0, tokens - cached));
          buckets[index].tokens += tokens;
          buckets[index].cached += cached;
          buckets[index].effective += effective;
          const key = item.name || item.projectPath || '未命名';
          const current = contributors.get(key) || { name: key, tokens: 0, cached: 0, effective: 0, duplicate: 0 };
          current.tokens += tokens;
          current.cached += cached;
          current.effective += effective;
          current.duplicate += Number(item.duplicateResponseGroupCount || 0);
          contributors.set(key, current);
        });
      });

      const maxY = Math.max(1, ...buckets.map((bucket) => bucket.tokens));
      const totalWindow = buckets.reduce((sum, bucket) => sum + bucket.tokens, 0);
      const cachedWindow = buckets.reduce((sum, bucket) => sum + bucket.cached, 0);
      const effectiveWindow = buckets.reduce((sum, bucket) => sum + bucket.effective, 0);
      const nonZeroIndexes = buckets
        .map((bucket, index) => ({ bucket, index }))
        .filter((entry) => entry.bucket.tokens > 0)
        .map((entry) => entry.index);
      const nonZeroMinutes = nonZeroIndexes.length;
      const firstNonZero = nonZeroMinutes ? nonZeroIndexes[0] : -1;
      const lastNonZero = nonZeroMinutes ? nonZeroIndexes[nonZeroMinutes - 1] : -1;
      const xFor = (index) => pad.left + (index / Math.max(1, bucketCount - 1)) * chartW;
      const yFor = (value) => pad.top + chartH - ((value / maxY) * chartH);

      add('rect', { x: 0, y: 0, width, height, fill: '#111827' });
      add('text', { x: pad.left, y: 16, fill: '#f9fafb', 'font-size': 12, 'font-weight': 700 }, 'Token 使用率 · 最近 60 分钟');
      add('text', { x: width - pad.right, y: 16, fill: '#f9fafb', 'font-size': 11, 'text-anchor': 'end' }, '峰值 ' + compact(maxY) + ' token/分钟');
      for (let i = 0; i <= 10; i++) {
        const x = pad.left + (chartW / 10) * i;
        add('line', { x1: x, y1: pad.top, x2: x, y2: height - pad.bottom, stroke: '#2f3a46', 'stroke-width': 1 });
      }
      for (let i = 0; i <= 5; i++) {
        const y = pad.top + (chartH / 5) * i;
        add('line', { x1: pad.left, y1: y, x2: width - pad.right, y2: y, stroke: '#2f3a46', 'stroke-width': 1 });
        const value = Math.round(maxY - (maxY / 5) * i);
        add('text', { x: width - pad.right, y: y - 4, fill: '#cbd5e1', 'font-size': 10, 'text-anchor': 'end' }, compact(value));
      }
      const area = buckets.map((bucket, index) => {
        const command = index === 0 ? 'M' : 'L';
        return command + xFor(index).toFixed(1) + ' ' + yFor(bucket.tokens).toFixed(1);
      }).join(' ') + ' L ' + xFor(bucketCount - 1).toFixed(1) + ' ' + (height - pad.bottom) + ' L ' + pad.left + ' ' + (height - pad.bottom) + ' Z';
      const line = buckets.map((bucket, index) => {
        const command = index === 0 ? 'M' : 'L';
        return command + xFor(index).toFixed(1) + ' ' + yFor(bucket.tokens).toFixed(1);
      }).join(' ');
      add('path', { d: area, fill: '#65a30d', opacity: 0.35 });
      add('path', { d: line, fill: 'none', stroke: '#84cc16', 'stroke-width': 2, 'stroke-linejoin': 'round' });
      add('line', { x1: pad.left, y1: height - pad.bottom, x2: width - pad.right, y2: height - pad.bottom, stroke: '#64748b', 'stroke-width': 1 });
      add('text', { x: pad.left, y: height - 10, fill: '#f9fafb', 'font-size': 11 }, '60 分钟');
      add('text', { x: width - pad.right, y: height - 10, fill: '#f9fafb', 'font-size': 11, 'text-anchor': 'end' }, '现在');
      if (totalWindow === 0) {
        add('text', { x: width / 2, y: height / 2, fill: '#cbd5e1', 'font-size': 13, 'text-anchor': 'middle' }, '最近 60 分钟没有实际 token 请求');
      }
      else if (nonZeroMinutes <= 6) {
        const leftEmptyMinutes = Math.max(0, firstNonZero);
        const activeText = '60 分钟内只有 ' + nonZeroMinutes + ' 分钟有 ' + (sessionSeries.length ? 'session token_count' : 'completed usage') + '；前面 ' + leftEmptyMinutes + ' 分钟为空';
        add('text', { x: pad.left + 10, y: pad.top + 20, fill: '#cbd5e1', 'font-size': 12 }, activeText);
      }

      const topContributors = Array.from(contributors.values())
        .sort((a, b) => b.tokens - a.tokens)
        .slice(0, 6);
      [
        { name: '60 分钟总量', value: compact(totalWindow), detail: sourceLabel },
        { name: 'cached', value: compact(cachedWindow), detail: 'usage.input_tokens_details.cached_tokens' },
        { name: '非缓存', value: compact(effectiveWindow), detail: 'total_tokens - cached_tokens' }
      ].concat(topContributors.map((item) => ({
        name: item.name,
        value: compact(item.tokens),
        detail: (item.cached ? 'cached ' + compact(item.cached) + ' · ' : '') + (item.duplicate ? '同提交多响应 ' + compact(item.duplicate) : '实际请求')
      }))).forEach((item, index) => {
        const row = document.createElement('div');
        row.className = 'legend-item';
        row.innerHTML = '<span class="legend-swatch"></span><span class="legend-name"></span><span class="legend-value"></span>';
        row.querySelector('.legend-swatch').style.setProperty('--c', index < 3 ? '#84cc16' : '#38bdf8');
        row.querySelector('.legend-name').textContent = item.name;
        row.querySelector('.legend-value').innerHTML = '<strong>' + item.value + '</strong> ' + item.detail;
        legend.appendChild(row);
      });
      hint.textContent = sessionSeries.length
        ? '主图按任务管理器口径显示最近 60 分钟每分钟 session token_count；它比 completed usage 更适合持续对话监控，账本总量仍以 completed usage.total_tokens 校验。'
        : '主图按任务管理器口径显示最近 60 分钟每分钟已完成的 usage.total_tokens；前面空白表示这段时间没有 completed usage 记录，正在进行中的线程会先显示为线程活动，完成后才计入曲线。';
    }

    function renderSavedLineChart(detection) {
      const svg = document.getElementById('savedLineChart');
      const legend = document.getElementById('savedLineLegend');
      const hint = document.getElementById('savedLineHint');
      const helperSeries = Array.isArray(detection.lineSeries) ? detection.lineSeries : [];
      svg.textContent = '';
      legend.textContent = '';

      const width = 760;
      const height = 220;
      const pad = { left: 66, right: 18, top: 26, bottom: 34 };
      const chartW = width - pad.left - pad.right;
      const chartH = height - pad.top - pad.bottom;
      const ns = 'http://www.w3.org/2000/svg';
      const add = (tag, attrs, text) => {
        const node = document.createElementNS(ns, tag);
        Object.entries(attrs || {}).forEach(([key, value]) => node.setAttribute(key, value));
        if (text !== undefined) node.textContent = text;
        svg.appendChild(node);
        return node;
      };
      const compact = (value) => {
        const n = Number(value || 0);
        if (n >= 1000000) return (n / 1000000).toFixed(n >= 10000000 ? 0 : 1) + 'M';
        if (n >= 1000) return (n / 1000).toFixed(n >= 10000 ? 0 : 1) + 'K';
        return fmt.format(Math.round(n));
      };
      const now = Date.now();
      const windowMs = 60 * 60 * 1000;
      const bucketMs = 60 * 1000;
      const startMs = now - windowMs;
      const bucketCount = 60;
      const buckets = Array.from({ length: bucketCount }, (_, index) => ({ ms: startMs + index * bucketMs, saved: 0 }));
      const contributors = new Map();
      helperSeries.forEach((item) => {
        (Array.isArray(item.points) ? item.points : []).forEach((point) => {
          const ms = Date.parse(point.t);
          if (!Number.isFinite(ms) || ms < startMs || ms > now) return;
          const index = Math.min(bucketCount - 1, Math.max(0, Math.floor((ms - startMs) / bucketMs)));
          const saved = Number(point.savedTokens || 0);
          buckets[index].saved += saved;
          const key = item.name || item.projectPath || '未命名';
          const current = contributors.get(key) || { name: key, saved: 0 };
          current.saved += saved;
          contributors.set(key, current);
        });
      });

      const maxY = Math.max(1, ...buckets.map((bucket) => bucket.saved));
      const totalWindow = buckets.reduce((sum, bucket) => sum + bucket.saved, 0);
      const xFor = (index) => pad.left + (index / Math.max(1, bucketCount - 1)) * chartW;
      const yFor = (value) => pad.top + chartH - ((value / maxY) * chartH);

      add('rect', { x: 0, y: 0, width, height, fill: '#102018' });
      add('text', { x: pad.left, y: 16, fill: '#f8fafc', 'font-size': 12, 'font-weight': 700 }, 'Helper 节省 · 最近 60 分钟');
      add('text', { x: width - pad.right, y: 16, fill: '#f8fafc', 'font-size': 11, 'text-anchor': 'end' }, '峰值 ' + compact(maxY) + ' token/分钟');
      for (let i = 0; i <= 10; i++) {
        const x = pad.left + (chartW / 10) * i;
        add('line', { x1: x, y1: pad.top, x2: x, y2: height - pad.bottom, stroke: '#244033', 'stroke-width': 1 });
      }
      for (let i = 0; i <= 4; i++) {
        const y = pad.top + (chartH / 4) * i;
        add('line', { x1: pad.left, y1: y, x2: width - pad.right, y2: y, stroke: '#244033', 'stroke-width': 1 });
        const value = Math.round(maxY - (maxY / 4) * i);
        add('text', { x: width - pad.right, y: y - 4, fill: '#bbf7d0', 'font-size': 10, 'text-anchor': 'end' }, compact(value));
      }
      const area = buckets.map((bucket, index) => {
        const command = index === 0 ? 'M' : 'L';
        return command + xFor(index).toFixed(1) + ' ' + yFor(bucket.saved).toFixed(1);
      }).join(' ') + ' L ' + xFor(bucketCount - 1).toFixed(1) + ' ' + (height - pad.bottom) + ' L ' + pad.left + ' ' + (height - pad.bottom) + ' Z';
      const line = buckets.map((bucket, index) => {
        const command = index === 0 ? 'M' : 'L';
        return command + xFor(index).toFixed(1) + ' ' + yFor(bucket.saved).toFixed(1);
      }).join(' ');
      add('path', { d: area, fill: '#22c55e', opacity: 0.32 });
      add('path', { d: line, fill: 'none', stroke: '#4ade80', 'stroke-width': 2, 'stroke-linejoin': 'round' });
      add('line', { x1: pad.left, y1: height - pad.bottom, x2: width - pad.right, y2: height - pad.bottom, stroke: '#86efac', 'stroke-width': 1, opacity: 0.7 });
      add('text', { x: pad.left, y: height - 10, fill: '#f8fafc', 'font-size': 11 }, '60 分钟');
      add('text', { x: width - pad.right, y: height - 10, fill: '#f8fafc', 'font-size': 11, 'text-anchor': 'end' }, '现在');
      if (totalWindow === 0) {
        add('text', { x: width / 2, y: height / 2, fill: '#bbf7d0', 'font-size': 13, 'text-anchor': 'middle' }, '最近 60 分钟没有 helper actual 节省记录');
      }

      [{ name: '60 分钟节省', value: compact(totalWindow), detail: 'helper savedTokens' }]
        .concat(Array.from(contributors.values()).sort((a, b) => b.saved - a.saved).slice(0, 5).map((item) => ({
          name: item.name,
          value: compact(item.saved),
          detail: 'context 避免'
        })))
        .forEach((item, index) => {
          const row = document.createElement('div');
          row.className = 'legend-item';
          row.innerHTML = '<span class="legend-swatch"></span><span class="legend-name"></span><span class="legend-value"></span>';
          row.querySelector('.legend-swatch').style.setProperty('--c', index === 0 ? '#4ade80' : '#22c55e');
          row.querySelector('.legend-name').textContent = item.name;
          row.querySelector('.legend-value').innerHTML = '<strong>' + item.value + '</strong> ' + item.detail;
          legend.appendChild(row);
        });
      hint.textContent = '这张图只看 helper actual 的 savedTokens，表示最近 60 分钟生成 context 时实际少写进对话的 token；refresh 不计入真实节省，它也不是套餐扣费反向值。';
    }

    function renderTokenUsageDetection(detection) {
      const trend = Array.isArray(detection.trend) ? detection.trend : [];
      const projects = Array.isArray(detection.projectUsage) ? detection.projectUsage : [];
      const requestSeries = Array.isArray(detection.requestLineSeries) ? detection.requestLineSeries : [];
      const sessionSeries = Array.isArray(detection.sessionTokenLineSeries) ? detection.sessionTokenLineSeries : [];
      const helperSeries = Array.isArray(detection.lineSeries) ? detection.lineSeries : [];
      const autoJoin = detection.autoJoinDiagnostics || {
        joinableThreadCount: 0,
        missingPathThreadCount: 0,
        noPathThreadCount: 0,
        throttledThreadCount: 0,
        message: ''
      };
      const helperByPath = new Map();
      helperSeries.forEach((item) => {
        const key = String(item.projectPath || item.name || '').toLowerCase();
        if (key) helperByPath.set(key, item);
      });
      const requestOverrides = requestSeries
        .map((item) => {
          const key = String(item.projectPath || item.name || '').toLowerCase();
          const helper = helperByPath.get(key);
          const requestTokens = Number(item.totalRequestTokens || item.totalOutputTokens || 0);
          const helperTokens = Number(helper && helper.totalOutputTokens || 0);
          return {
            name: item.name || item.projectPath || '未命名',
            tokens: requestTokens,
            helperTokens,
            duplicateResponseGroupCount: Number(item.duplicateResponseGroupCount || 0),
            dedupedTotalRequestTokens: Number(item.dedupedTotalRequestTokens || 0),
            rawTotalRequestTokens: Number(item.rawTotalRequestTokens || 0),
            cachedRequestTokens: Number(item.cachedRequestTokens || 0),
            isOverride: requestTokens >= 1000 && (!helper || requestTokens > helperTokens * 3)
          };
        })
        .filter((item) => item.isOverride)
        .sort((a, b) => b.tokens - a.tokens);
      const requestLineGroups = new Map();
      requestSeries.forEach((item) => {
        const key = String(item.projectPath || item.name || '').toLowerCase();
        if (!key) return;
        const current = requestLineGroups.get(key) || {
          name: item.name || item.projectPath || '未命名',
          count: 0,
          tokens: 0
        };
        current.count += 1;
        current.tokens += Number(item.totalRequestTokens || item.totalOutputTokens || 0);
        requestLineGroups.set(key, current);
      });
      const duplicateRequestGroups = Array.from(requestLineGroups.values())
        .filter((item) => item.count > 1)
        .sort((a, b) => b.tokens - a.tokens);
      const projectRows = document.getElementById('usageProjectRows');
      const issueRows = document.getElementById('usageIssueRows');
      projectRows.textContent = '';
      issueRows.textContent = '';
      renderUsageLineChart(detection);
      renderSavedLineChart(detection);

      projects
        .slice()
        .sort((a, b) => Number(b.helperAllTokens || b.requestTotalTokens || b.totalOutputTokens || 0) - Number(a.helperAllTokens || a.requestTotalTokens || a.totalOutputTokens || 0))
        .slice(0, 8)
        .forEach((item) => {
          const actual = Number(item.helperAllTokens || item.requestTotalTokens || item.totalOutputTokens || 0);
          const saved = Number(item.cumulativeSavedTokens || item.totalSavedTokens || 0);
          const original = actual + saved;
          const latestSaved = Number(item.totalSavedTokens || item.latestSavedTokens || 0);
          const savedPercent = original > 0 ? wholePercent(saved, original) : Number(item.totalSavedPercent || 0);
          const requestCount = Number(item.requestCount || 0);
          const runCount = Number(item.runCount || 0);
          const hasManyCodexRequests = requestCount >= 20 && runCount > 0 && requestCount > runCount * 5;
          const noCompressibleContext = actual > 0 && saved === 0 && original === 0 && Number(item.requestTotalTokens || 0) > 0;
          const historicalRequestTokens = item.requestUsageMatched && item.requestUsageAfterHelper === false
            ? Number(item.requestTotalTokens || 0)
            : 0;
          const stateLabel = historicalRequestTokens > actual
            ? '历史已排除'
            : (noCompressibleContext ? '无可压缩上下文' : (hasManyCodexRequests ? 'Codex日志多' : (item.contextStatus || '未知')));
          const stateClass = historicalRequestTokens > actual
            ? 'good'
            : (noCompressibleContext ? 'warn' : (hasManyCodexRequests || item.contextStatus === '打满上限' ? 'warn' : 'good'));
          const row = document.createElement('tr');
          row.innerHTML =
            '<td class="path"></td>' +
            '<td class="num">' + fmt.format(actual) + '</td>' +
            '<td class="num">' + (requestCount ? fmt.format(requestCount) + ' / ' + fmt.format(runCount) : '--') + '</td>' +
            '<td class="num">' + (historicalRequestTokens > actual ? fmt.format(historicalRequestTokens) : '--') + '</td>' +
            '<td class="num">' + fmt.format(saved) + '</td>' +
            '<td class="num">' + savedPercent + '%</td>' +
            '<td class="num"><span class="state-badge ' + stateClass + '">' + stateLabel + '</span></td>';
          row.querySelector('.path').textContent = item.conversationName || item.projectPath || '未命名';
          row.title = historicalRequestTokens > actual
            ? '这些 Codex completed usage 发生在本项目第一次 helper actual 之前，所以只作为旧请求审计，不计入 helper 后实际消耗或当前节省率。最后线程活动：' + (item.latestThreadActivityRun || '--') + '；最后旧请求：' + (item.latestRequestRun || '--') + '；第一次 helper actual：' + (item.firstRun || '--') + '。'
            : (hasManyCodexRequests
              ? 'Codex 模型请求日志次数远多于 helper actual 次数；这是历史或自动化 Codex 对话请求，不代表本地 Python worker 正在消耗 Codex token。最后线程活动：' + (item.latestThreadActivityRun || '--') + '；最后已完成模型用量：' + (item.latestRequestRun || '--') + '；最后 helper actual：' + (item.lastRun || '--') + '。'
              : '累计减少 ' + fmt.format(saved) + '；最后一次 helper 减少 ' + fmt.format(latestSaved) + '。');
          projectRows.appendChild(row);
        });

      const issues = [];
      projects.forEach((item) => {
        const actual = Number(item.helperAllTokens || item.requestTotalTokens || item.totalOutputTokens || 0);
        const saved = Number(item.cumulativeSavedTokens || item.totalSavedTokens || 0);
        const original = actual + saved;
        const savedPercent = original > 0 ? wholePercent(saved, original) : Number(item.totalSavedPercent || 0);
        if (item.contextStatus === '打满上限') {
          issues.push({ name: (item.conversationName || item.projectPath || '未命名') + ' 打满上限', impact: 'context 预算不足' });
        }
        if (actual > 0 && savedPercent < 20) {
          issues.push({ name: (item.conversationName || item.projectPath || '未命名') + ' 减少率低', impact: savedPercent + '%' });
        }
        if (actual > 0 && saved === 0 && original === 0 && Number(item.requestTotalTokens || 0) > 0) {
          issues.push({
            name: (item.conversationName || item.projectPath || '未命名') + ' 无可压缩上下文',
            impact: '主要是模型对话 token'
          });
        }
        const modelRequestTokens = Number(item.requestTotalTokens || 0);
        if (item.requestUsageAfterHelper && modelRequestTokens > 0 && saved > 0 && modelRequestTokens > saved * 20) {
          issues.push({
            name: (item.conversationName || item.projectPath || '未命名') + ' 模型对话消耗主导',
            impact: '请求 ' + fmt.format(modelRequestTokens) + ' / context 避免 ' + fmt.format(saved)
          });
        }
        if (!item.requestUsageMatched) {
          issues.push({ name: (item.conversationName || item.projectPath || '未命名') + ' 未匹配日志', impact: '仅估算' });
        }
        const requestCount = Number(item.requestCount || 0);
        const runCount = Number(item.runCount || 0);
        if (requestCount >= 20 && runCount > 0 && requestCount > runCount * 5) {
          issues.push({
            name: (item.conversationName || item.projectPath || '未命名') + ' Codex日志多',
            impact: '模型日志 ' + fmt.format(requestCount) + ' 次 / helper ' + fmt.format(runCount) + ' 次 · 线程活动 ' + (item.latestThreadActivityRun || '--')
          });
        }
        if (item.threadActiveAfterRequest) {
          issues.push({
            name: (item.conversationName || item.projectPath || '未命名') + ' 线程仍活跃',
            impact: '最后活动 ' + (item.latestThreadActivityRun || '--') + ' · 已完成用量 ' + (item.latestRequestRun || '--')
          });
        }
        if (item.helperStaleAfterRequest) {
          issues.push({
            name: (item.conversationName || item.projectPath || '未命名') + ' helper可能过旧',
            impact: '模型请求晚于 helper ' + fmt.format(item.helperStaleAfterRequestMinutes || 0) + ' 分钟'
          });
        }
      });
      (detection.untrackedRequestThreads || []).forEach((item) => {
        issues.push({ name: (item.conversationName || item.threadId || '未命名') + ' 未接入', impact: fmt.format(item.totalTokens || 0) });
      });
      if (Number(autoJoin.joinableThreadCount || 0) > 0) {
        issues.push({ name: '可自动接入线程', impact: fmt.format(autoJoin.joinableThreadCount || 0) + ' 个' });
      }
      if (Number(autoJoin.missingPathThreadCount || 0) > 0 || Number(autoJoin.noPathThreadCount || 0) > 0) {
        issues.push({
          name: '暂不能自动接入',
          impact: '路径缺失 ' + fmt.format(autoJoin.noPathThreadCount || 0) + ' / 不可访问 ' + fmt.format(autoJoin.missingPathThreadCount || 0)
        });
      }
      requestOverrides.slice(0, 5).forEach((item) => {
        issues.push({
          name: item.name + ' 使用真实请求线',
          impact: fmt.format(item.tokens) + ' token'
        });
      });
      if (Number(detection.historicalRequestProjectCount || 0) > 0) {
        issues.push({
          name: 'helper 前历史请求已排除',
          impact: fmt.format(detection.historicalRequestProjectCount || 0) + ' 个项目'
        });
      }
      requestSeries
        .filter((item) => Number(item.duplicateResponseGroupCount || 0) > 0)
        .slice(0, 5)
        .forEach((item) => {
          const deduped = Number(item.dedupedTotalRequestTokens || 0);
          const total = Number(item.totalRequestTokens || 0);
          issues.push({
            name: (item.name || item.projectPath || '未命名') + ' 同提交多响应',
            impact: '实际 ' + fmt.format(total) + (deduped > 0 && deduped < total ? ' / 去重参考 ' + fmt.format(deduped) : '')
          });
        });
      duplicateRequestGroups.slice(0, 5).forEach((item) => {
        issues.push({
          name: item.name + ' 多线程请求线',
          impact: fmt.format(item.count) + ' 条来源 · 图表按项目合并'
        });
      });
      if (issues.length === 0) {
        issues.push({ name: '没有需要优先处理的异常', impact: '正常' });
      }
      issues.slice(0, 8).forEach((item) => {
        const row = document.createElement('tr');
        row.innerHTML = '<td></td><td class="num"></td>';
        row.children[0].textContent = item.name;
        row.children[1].textContent = item.impact;
        issueRows.appendChild(row);
      });

      const primarySourceLabel = sessionSeries.length
        ? '主图 session token_count'
        : (requestSeries.length ? '主图 completed usage' : '主图 helper actual');
      document.getElementById('usageDetectionSummary').textContent =
        primarySourceLabel + ' · ' +
        (sessionSeries.length
          ? fmt.format(sessionSeries.length) + ' 条'
          : requestSeries.length
            ? fmt.format(requestSeries.length) + ' 条'
            : (detection.status === 'warn' ? '需要处理' : detection.status === 'idle' ? '等待 actual' : 'helper 监控'));
      document.getElementById('usageCurrentOutput').textContent = fmt.format(detection.currentOutputTokens || 0);
      document.getElementById('usageRecent24h').textContent = fmt.format(detection.recent24hOutputTokens || 0);
      const totalHelperOutput = Number(detection.currentOutputTokens || 0);
      const recentHelperOutput = Number(detection.recent24hOutputTokens || 0);
      const recentShare = totalHelperOutput > 0 ? wholePercent(recentHelperOutput, totalHelperOutput) : 0;
      document.getElementById('usageRecent24hHint').textContent =
        totalHelperOutput > 0 ? 'helper actual context，占总写入约 ' + recentShare + '%' : '最近 helper actual context';
      document.getElementById('usageUntracked').textContent = fmt.format(detection.untrackedRequestThreadCount || 0);
      document.getElementById('usageUntracked').className =
        'value ' + (detection.untrackedRequestThreadCount ? 'amber' : 'green');
      document.getElementById('usageAutoJoinHint').textContent =
        (detection.untrackedRequestThreadCount || 0)
          ? '可接入 ' + fmt.format(autoJoin.joinableThreadCount || 0) +
            ' · 路径缺失 ' + fmt.format(autoJoin.noPathThreadCount || 0) +
            ' · 不可访问 ' + fmt.format(autoJoin.missingPathThreadCount || 0)
          : (autoJoin.lastAutoRefreshStale && Number(autoJoin.lastAutoRefreshStale.succeeded || 0) > 0)
            ? '已自动刷新过期 helper ' + fmt.format(autoJoin.lastAutoRefreshStale.succeeded || 0) + ' 个'
            : '全部已匹配或已接入';
      document.getElementById('usageLastRun').textContent = detection.lastRun ? shortTime(detection.lastRun) : '--';
      document.getElementById('usageLastRunHint').textContent =
        detection.lastRun ? '约 ' + (detection.lastRunAgeMinutes || 0) + ' 分钟前' : '还没有 actual';
      document.getElementById('tokenTrendHint').textContent =
        '显示最需要处理或解释的问题：未接入、未匹配、减少率低、打满上限、真实请求线覆盖 helper 线、多线程请求线。';
      document.getElementById('projectUsageHint').textContent =
        '按 helper 后实际 token 排序；累计减少是这个项目多次 helper actual 合计少写入的 context token，悬停可看最后一次减少。“旧请求审计”是首次 helper actual 之前的 completed usage，只用于解释历史，不计入当前 helper 后实际。多线程请求线会按项目合并展示，不代表重复扣费。本地 Python worker 的持续运行不计入；若请求 token 远大于 context 避免，说明主要消耗来自后续模型对话、推理和输出；若显示无可压缩上下文，说明该对话本身没有可供 helper 压缩的项目上下文。';
      document.getElementById('usageDetectionStatus').textContent =
        (detection.message || '检测正常。') +
        (detection.untrackedRequestThreadCount ? ' ' + detection.untrackedRequestThreadCount + ' 个线程还没接入 helper actual。' : '') +
        (autoJoin.message ? ' ' + autoJoin.message : '') +
        (detection.helperReviewProjectCount ? ' ' + detection.helperReviewProjectCount + ' 个项目需要复核 helper 是否持续使用。' : '') +
        (detection.cappedProjectCount ? ' ' + detection.cappedProjectCount + ' 个项目打满 context 预算。' : '') +
        (detection.historicalRequestProjectCount ? ' ' + fmt.format(detection.historicalRequestProjectCount) + ' 个项目的 helper 前历史请求已从 helper 后实际中排除。' : '') +
        (sessionSeries.length
          ? ' 主图当前使用 session token_count 时间线；账本仍用 completed usage 校验。本地后台进程不在扣费口径内。'
          : requestSeries.length
            ? ' 主图当前使用 Codex completed usage 真实 token 时间线；本地后台进程不在这个口径内。' + fmt.format(requestOverrides.length) + ' 个项目用真实请求线覆盖 helper 线。'
            : ' 主图当前使用 helper actual/refresh 时间线。');
      document.getElementById('usageDetectionStatus').className =
        'status ' + (detection.status === 'warn' ? 'red' : detection.status === 'idle' ? 'amber' : 'green');
    }

    function renderEffectiveness(globalHistory) {
      const original = Number(globalHistory.totalOriginalAllTokens || globalHistory.totalOriginalTokens || 0);
      const actual = Number(globalHistory.totalHelperAllTokens || globalHistory.totalOutputTokens || 0);
      const saved = Number(globalHistory.totalAllSavedTokens || globalHistory.totalSavedTokens || 0);
      const allConversationPercent = original > 0 ? wholePercent(saved, original) : 0;
      document.getElementById('effectivenessActual').textContent = fmt.format(original);
      document.getElementById('effectivenessSaved').textContent = fmt.format(actual);
      document.getElementById('effectivenessRatio').textContent = fmt.format(saved);
      document.getElementById('effectivenessNet').textContent = allConversationPercent + '%';
      document.getElementById('effectivenessSummary').textContent =
        actual > 0 ? '真实请求 ' + fmt.format(actual) + ' token' : '等待真实请求日志';
      document.getElementById('effectivenessLine').textContent =
        '结论：按全对话口径，原本约 ' + fmt.format(original) + ' token，使用 helper 后实际约 ' +
        fmt.format(actual) + ' token，减少 ' + fmt.format(saved) + ' token（' + allConversationPercent +
        '%）。套餐扣减仍按真实模型请求计算，多个长任务并行、模型输出和推理会继续消耗额度。';
      document.getElementById('effectivenessLine').className = 'status ' + (saved > 0 ? 'green' : 'amber');
    }

    function renderAppQuota(currentStats) {
      if (currentStats.appQuota && currentStats.appQuota.configured) {
        document.getElementById('appQuotaMeta').textContent = '保存于 ' + currentStats.appQuota.path;
        document.getElementById('appShortWindow').textContent = currentStats.appQuota.shortWindowLabel || '未设置';
        document.getElementById('appShortPercent').textContent = currentStats.appQuota.estimatedShortUsedPercent + '%';
        document.getElementById('appWeeklyPercent').textContent = currentStats.appQuota.estimatedWeeklyUsedPercent + '%';
        document.getElementById('appWeeklyCapacity').textContent =
          currentStats.appQuota.weeklyTotalEstimateTokens ? fmt.format(currentStats.appQuota.weeklyTotalEstimateTokens) : '未设置';
        document.getElementById('appWeeklyReset').textContent =
          (currentStats.appQuota.weeklyWindowLabel || '周周期') + ' · 重置 ' + (currentStats.appQuota.weeklyResetLabel || '未设置') +
          ' · 截图锚点剩余 ' + currentStats.appQuota.weeklyUsedPercent + '%' +
          (currentStats.appQuota.currentGlobalRequestTokens ? ' · 套餐口径 ' + fmt.format(currentStats.appQuota.currentGlobalRequestTokens) + ' token' : '') +
          (currentStats.appQuota.localGlobalRequestTokens ? ' · 本地日志 ' + fmt.format(currentStats.appQuota.localGlobalRequestTokens) + ' token' : '') +
          (currentStats.appQuota.quotaLogResetProtected ? ' · 日志回落保护' : '') +
          (currentStats.appQuota.quotaIncrementalRequestTokens ? ' · 续算 ' + fmt.format(currentStats.appQuota.quotaIncrementalRequestTokens) + ' token' : '') +
          (currentStats.appQuota.unobservedRequestTokens ? ' · 未捕获 ' + fmt.format(currentStats.appQuota.unobservedRequestTokens) + ' token' : '') +
          (currentStats.appQuota.weeklyTotalEstimateTokens ? ' · 截图换算容量 ' + fmt.format(currentStats.appQuota.weeklyTotalEstimateTokens) + ' token' : '');
      if (currentStats.appQuota.quotaEstimateBasis === 'real_request_tokens_needs_recalibration') {
          document.getElementById('appQuotaMeta').textContent += ' · 已切换真实请求 token 口径，等待下一次截图校准';
        } else if (String(currentStats.appQuota.quotaEstimateBasis || '').startsWith('real_request_tokens_from_')) {
          document.getElementById('appQuotaMeta').textContent += ' · 本地 token 是真实日志，套餐百分比按截图锚点换算';
          if (currentStats.appQuota.localBaselineRequestTokens) {
            document.getElementById('appQuotaMeta').textContent += ' · 后续自动按本地增量估算';
          }
        } else if (currentStats.appQuota.quotaEstimateBasis === 'real_request_tokens') {
          document.getElementById('appQuotaMeta').textContent += ' · 真实请求 token 口径';
        }
      } else {
        document.getElementById('appQuotaMeta').textContent = 'App 菜单可见，但目前没有公开 API 可稳定读取';
        document.getElementById('appShortWindow').textContent = '未设置';
        document.getElementById('appShortPercent').textContent = '未设置';
        document.getElementById('appWeeklyPercent').textContent = '未设置';
        document.getElementById('appWeeklyCapacity').textContent = '未设置';
        document.getElementById('appWeeklyReset').textContent = '重置日期未设置';
      }
    }

    renderStats(stats);

    async function refreshHealth() {
      try {
        const response = await fetch('/api/health', { cache: 'no-store' });
        if (!response.ok) {
          throw new Error('health unavailable');
        }
        latestHealth = await response.json();
        renderTopStatus(stats.globalHistory || {}, stats.audit || {}, latestHealth);
        renderOverview(stats.globalHistory || {}, stats.appQuota || {}, stats.audit || {}, latestHealth);
        return latestHealth;
      } catch (error) {
        latestHealth = null;
        return null;
      }
    }

    async function refreshStats() {
      const status = document.getElementById('liveStatus');
      status.textContent = '正在刷新...';
      try {
        const response = await fetch('/api/refresh', { method: 'POST' });
        if (!response.ok) {
          throw new Error('refresh failed');
        }
        const fresh = await response.json();
        renderStats(fresh, true);
        const health = await refreshHealth();
        status.textContent = '已刷新 · ' + new Date().toLocaleTimeString();
        if (health && health.status !== 'ok') {
          status.textContent += ' · health ' + health.status;
        }
      } catch (error) {
        status.textContent = '刷新失败，请确认本地服务仍在运行';
      }
    }

    document.getElementById('refreshStats').addEventListener('click', refreshStats);

    async function pollStats() {
      const status = document.getElementById('liveStatus');
      try {
        const response = await fetch('/api/stats', { cache: 'no-store' });
        if (!response.ok) {
          throw new Error('stats unavailable');
        }
        const fresh = await response.json();
        const rendered = renderStats(fresh);
        const health = await refreshHealth();
        status.textContent =
          (rendered ? '已更新' : '稳定中') + ' · ' + new Date().toLocaleTimeString() +
          (health ? ' · health ' + health.status : '');
      } catch (error) {
        status.textContent = '实时刷新等待本地服务';
      }
    }

    refreshHealth();
    setInterval(pollStats, 5000);
  </script>
</body>
</html>
"@
}

function Get-GitStatus {
    param([string]$Root)

    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($null -eq $git) {
        return "git 不可用。"
    }

    Push-Location $Root
    try {
        $oldErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        $inside = git rev-parse --is-inside-work-tree 2>$null
        $ErrorActionPreference = $oldErrorActionPreference
        if ($LASTEXITCODE -ne 0 -or $inside -ne "true") {
            return "不是 git 仓库。"
        }

        $branch = git branch --show-current 2>$null
        $statusLines = @(git status --short 2>$null)
        if ($statusLines.Count -eq 0) {
            $statusText = "干净工作区。"
        }
        else {
            $statusText = $statusLines -join "`n"
        }

        return "branch: $branch`n$statusText"
    }
    finally {
        Pop-Location
    }
}

function New-CompactTree {
    param(
        [array]$Files,
        [int]$Limit = 180
    )

    $fileList = @($Files)
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($file in ($fileList | Sort-Object RelativePath | Select-Object -First $Limit)) {
        $normalizedPath = $file.RelativePath -replace "\\", "/"
        $lines.Add($normalizedPath)
    }

    if ($fileList.Count -gt $Limit) {
        $lines.Add("... 另有 $($fileList.Count - $Limit) 个文件已省略")
    }

    return ($lines -join "`n")
}

$root = Resolve-ProjectPath $ProjectPath
if ([string]::IsNullOrWhiteSpace($ConversationName)) {
    $ConversationName = Split-Path -Leaf $root
}
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $root ".codex/context.md"
}
if ([string]::IsNullOrWhiteSpace($StatsPath)) {
    $StatsPath = Join-Path $root ".codex/stats.json"
}
if ([string]::IsNullOrWhiteSpace($DashboardPath)) {
    $DashboardPath = Join-Path $root ".codex/dashboard.html"
}
$statsDir = Split-Path -Parent $StatsPath
if ([string]::IsNullOrWhiteSpace($ContextCachePath)) {
    $ContextCachePath = Join-Path $statsDir "context-cache.json"
}

$allFiles = Get-ChildItem -LiteralPath $root -Recurse -File -Force |
    ForEach-Object {
        $relative = Get-RelativePath -BasePath $root -FullPath $_.FullName
        [PSCustomObject]@{
            FullName = $_.FullName
            RelativePath = $relative
            Length = $_.Length
            LastWriteTime = $_.LastWriteTime
            Ignored = Test-IgnoredPath $relative
        }
    } |
    Where-Object { -not $_.Ignored }

$contextFiles = @($allFiles | Where-Object { $_.Length -le 500000 -and (Test-ContextCandidateFile $_.RelativePath) })
$changedPathSet = Get-GitChangedPathSet -Root $root

$rankedCandidates = @($contextFiles |
    ForEach-Object {
        $normalizedPath = ($_.RelativePath -replace "\\", "/").ToLowerInvariant()
        [PSCustomObject]@{
            FullName = $_.FullName
            RelativePath = $_.RelativePath
            NormalizedPath = $normalizedPath
            Length = $_.Length
            LastWriteTime = $_.LastWriteTime
            Score = (Get-TextFileScore -RelativePath $_.RelativePath -ChangedPathSet $changedPathSet)
            Categories = (Get-ContextCategory -RelativePath $_.RelativePath -LastWriteTime $_.LastWriteTime -ChangedPathSet $changedPathSet)
        }
    } |
    Sort-Object @{ Expression = "Score"; Descending = $true }, @{ Expression = "LastWriteTime"; Descending = $true }, @{ Expression = "Length"; Ascending = $true })

$rankedFiles = @($rankedCandidates | Select-Object -First $MaxFiles)
$coverageAudit = Get-CoverageAudit -Candidates $rankedCandidates -Selected $rankedFiles

$builder = New-Object System.Text.StringBuilder
$fileStats = New-Object System.Collections.Generic.List[object]
$contextCache = Read-ContextCache -Path $ContextCachePath
$contextCacheHitCount = 0
$contextCacheMissCount = 0
$contextCacheReferenceCount = 0
$contextCacheReferenceSavedTokens = 0
[void]$builder.AppendLine("# Codex Slim Context")
[void]$builder.AppendLine()
[void]$builder.AppendLine("生成时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
[void]$builder.AppendLine("项目路径: $root")
[void]$builder.AppendLine("预算: 约 $MaxChars 字符")
[void]$builder.AppendLine()
[void]$builder.AppendLine("## 使用提示")
[void]$builder.AppendLine()
[void]$builder.AppendLine("把这份上下文交给 Codex 后，请让它优先基于这些信息行动；只有在需要确认实现细节时再读取具体文件。")
[void]$builder.AppendLine("覆盖风险: $($coverageAudit.risk)。改动文件 $($coverageAudit.changedFilesIncludedCount)/$($coverageAudit.changedFileCount)，入口/配置 $($coverageAudit.essentialFilesIncludedCount)/$($coverageAudit.essentialFileCount)，近期文件 $($coverageAudit.recentFilesIncludedCount)/$($coverageAudit.recentFileCount)。")
[void]$builder.AppendLine("缓存策略: changed/essential/entry/test 永远完整摘录；只有第 7 个以后且未变化的 normal 文件才会用短缓存引用。")
[void]$builder.AppendLine()
[void]$builder.AppendLine("## Git 状态")
[void]$builder.AppendLine()
[void]$builder.AppendLine('```text')
[void]$builder.AppendLine((Get-GitStatus $root))
[void]$builder.AppendLine('```')
[void]$builder.AppendLine()
[void]$builder.AppendLine("## 文件地图")
[void]$builder.AppendLine()
[void]$builder.AppendLine('```text')
[void]$builder.AppendLine((New-CompactTree $allFiles))
[void]$builder.AppendLine('```')
[void]$builder.AppendLine()
[void]$builder.AppendLine("## 关键文件摘录")

$fileIndex = 0
foreach ($file in $rankedFiles) {
    if ($builder.Length -ge $MaxChars) {
        break
    }

    $remaining = $MaxChars - $builder.Length
    $limit = [Math]::Min($PerFileChars, [Math]::Max(600, $remaining - 600))
    if ($limit -lt 600) {
        break
    }

    $displayPath = $file.RelativePath -replace "\\", "/"
    $cacheKey = $displayPath.ToLowerInvariant()
    $stamp = Get-FileCacheStamp -Path $file.FullName
    $cacheEntry = Get-ContextCacheEntry -Cache $contextCache -Key $cacheKey
    $cacheHit = $false
    if ($null -ne $cacheEntry -and
        ($cacheEntry.PSObject.Properties.Name -contains "length") -and
        ($cacheEntry.PSObject.Properties.Name -contains "lastWriteUtcTicks") -and
        [long]$cacheEntry.length -eq [long]$stamp.length -and
        [long]$cacheEntry.lastWriteUtcTicks -eq [long]$stamp.lastWriteUtcTicks) {
        $cacheHit = $true
        $contextCacheHitCount++
    }
    else {
        $contextCacheMissCount++
    }

    $usedCacheReference = $false
    if ($cacheHit -and (Test-StableCacheReferenceAllowed -File $file -Index $fileIndex)) {
        $preview = New-StableCacheReference -File $file -Entry $cacheEntry
        $usedCacheReference = $true
        $contextCacheReferenceCount++
    }
    else {
        $preview = Read-TextPreview -Path $file.FullName -Limit $limit
    }

    $originalChars = [int]$file.Length
    $previewChars = $preview.Length
    $previewTokens = Estimate-Tokens $previewChars
    $fullPreviewTokens = if ($cacheHit -and ($cacheEntry.PSObject.Properties.Name -contains "previewTokens")) { [int]$cacheEntry.previewTokens } else { $previewTokens }
    if ($usedCacheReference) {
        $contextCacheReferenceSavedTokens += [Math]::Max(0, $fullPreviewTokens - $previewTokens)
    }

    [void]$fileStats.Add([PSCustomObject]@{
        path = $displayPath
        score = $file.Score
        originalChars = $originalChars
        previewChars = $previewChars
        originalTokens = Estimate-Tokens $originalChars
        previewTokens = $previewTokens
        savedTokens = [Math]::Max(0, (Estimate-Tokens $originalChars) - (Estimate-Tokens $previewChars))
        savedPercent = (Get-Percent ([Math]::Max(0, $originalChars - $previewChars)) $originalChars)
        categories = [string]$file.Categories
        cacheHit = [bool]$cacheHit
        cacheReference = [bool]$usedCacheReference
    })

    if (-not $usedCacheReference) {
        Set-ContextCacheEntry -Cache $contextCache -Key $cacheKey -Entry ([PSCustomObject]@{
            path = $displayPath
            length = [long]$stamp.length
            lastWriteUtcTicks = [long]$stamp.lastWriteUtcTicks
            previewTokens = [int]$previewTokens
            previewChars = [int]$previewChars
            categories = [string]$file.Categories
            score = [int]$file.Score
            updatedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        })
    }

    [void]$builder.AppendLine()
    [void]$builder.AppendLine("### $displayPath")
    [void]$builder.AppendLine()
    $cacheLabel = if ($usedCacheReference) { "; cache=stable-reference" } elseif ($cacheHit) { "; cache=hit" } else { "; cache=miss" }
    [void]$builder.AppendLine("- meta: size=$($file.Length) bytes; score=$($file.Score); category=$($file.Categories)$cacheLabel")
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('```text')
    [void]$builder.AppendLine($preview)
    [void]$builder.AppendLine('```')
    $fileIndex++
}

if ($builder.Length -gt $MaxChars) {
    $text = $builder.ToString().Substring(0, $MaxChars)
    $text += "`n`n[输出达到 MaxChars 限制，后续内容已省略。]`n"
}
else {
    $text = $builder.ToString()
}

$outDir = Split-Path -Parent $OutputPath
if (-not [string]::IsNullOrWhiteSpace($outDir)) {
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
}

Set-Content -LiteralPath $OutputPath -Value $text -Encoding UTF8
$statsDir = Split-Path -Parent $StatsPath
if (-not [string]::IsNullOrWhiteSpace($statsDir)) {
    New-Item -ItemType Directory -Force -Path $statsDir | Out-Null
}
$historyPath = Join-Path $statsDir "history.jsonl"
if (-not [string]::IsNullOrWhiteSpace($ContextCachePath)) {
    $contextCache | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ContextCachePath -Encoding UTF8
}

$dashboardDir = Split-Path -Parent $DashboardPath
if (-not [string]::IsNullOrWhiteSpace($dashboardDir)) {
    New-Item -ItemType Directory -Force -Path $dashboardDir | Out-Null
}

$outputTokens = Estimate-Tokens $text.Length
$allFileList = @($allFiles)
$contextFileList = @($contextFiles)
$lengthMeasure = $contextFileList | Measure-Object -Property Length -Sum
$sumProperty = $lengthMeasure.PSObject.Properties.Match("Sum")
$originalChars = if ($sumProperty.Count -gt 0 -and $null -ne $sumProperty[0].Value) { [int]$sumProperty[0].Value } else { 0 }
$originalTokens = Estimate-Tokens $originalChars
$savedTokens = [Math]::Max(0, $originalTokens - $outputTokens)
$budgetTokens = Estimate-Tokens $MaxChars
$savedPercent = Get-Percent -Numerator ([double]$savedTokens) -Denominator ([double]$originalTokens)
$budgetUsedPercent = Get-Percent -Numerator ([double]$outputTokens) -Denominator ([double]$budgetTokens)
$outputCapped = $builder.Length -gt $MaxChars
$aiCodexPresent = Test-Path -LiteralPath (Join-Path $root ".ai-codex")
$openAIUsage = if ($ReadOpenAIUsage) { Get-OpenAIUsage -Days $OpenAIUsageDays -AdminKeyEnv $OpenAIAdminKeyEnv -AdminKeyPath $OpenAIAdminKeyPath } else {
    [PSCustomObject]@{
        status = "disabled"
        message = "未启用 OpenAI usage 读取。"
        days = $OpenAIUsageDays
        inputTokens = 0L
        outputTokens = 0L
        cachedTokens = 0L
        totalTokens = 0L
        requests = 0L
        source = "openai_usage_api"
        keySource = ""
    }
}
$plan = Get-TokenPlan -Root $root -Name $PlanName -TotalTokens $PlanTotalTokens -UsedTokens $PlanUsedTokens
if ($ReadOpenAIUsage -and $openAIUsage.status -eq "ok" -and $openAIUsage.totalTokens -gt 0 -and $PlanUsedTokens -lt 0) {
    $plan.usedTokens = [long]$openAIUsage.totalTokens
}
$planRemainingTokens = [Math]::Max(0L, ([long]$plan.totalTokens - [long]$plan.usedTokens))
$planProjectedUsedTokens = [Math]::Min([long]$plan.totalTokens, ([long]$plan.usedTokens + [long]$outputTokens))
$statsGeneratedAt = Get-Date
$statsGeneratedAtUtc = $statsGeneratedAt.ToUniversalTime()
$toolingInfo = Get-HelperToolingInfo -ScriptRoot $PSScriptRoot -StatsGeneratedAtUtc $statsGeneratedAtUtc
$planStats = [PSCustomObject]@{
    name = $plan.name
    totalTokens = [long]$plan.totalTokens
    usedTokens = [long]$plan.usedTokens
    remainingTokens = [long]$planRemainingTokens
    usedPercent = (Get-Percent -Numerator ([double]$plan.usedTokens) -Denominator ([double]$plan.totalTokens))
    contextPercentOfRemaining = (Get-PercentDecimal -Numerator ([double]$outputTokens) -Denominator ([double]$planRemainingTokens))
    projectedUsedTokens = [long]$planProjectedUsedTokens
    projectedUsedPercent = (Get-Percent -Numerator ([double]$planProjectedUsedTokens) -Denominator ([double]$plan.totalTokens))
    configured = [bool]$plan.configured
    configPath = $plan.configPath
    sourceLabel = if ($ReadOpenAIUsage -and $openAIUsage.status -eq "ok" -and $openAIUsage.totalTokens -gt 0 -and $PlanUsedTokens -lt 0) { "OpenAI Usage API + $($plan.configPath)" } else { $plan.configPath }
}
$appQuota = Get-AppQuota -Root $root
$currentRun = [PSCustomObject]@{
    generatedAt = $statsGeneratedAt.ToString("yyyy-MM-dd HH:mm:ss")
    generatedAtUtc = $statsGeneratedAtUtc.ToString("o")
    conversationName = $ConversationName
    projectPath = $root
    runKind = $RunKind
    originalTokens = $originalTokens
    outputTokens = $outputTokens
    outputCapped = $outputCapped
    budgetTokens = $budgetTokens
    maxChars = $MaxChars
    savedTokens = $savedTokens
    savedPercent = $savedPercent
}
$historyStats = Get-TokenHistorySummary -HistoryPath $historyPath -CurrentRun $currentRun
$globalHistoryStats = Get-GlobalTokenHistorySummary -HistoryPath $GlobalHistoryPath -CurrentRun $currentRun
$statsAudit = Get-StatsAudit -GlobalHistory $globalHistoryStats
$contextCacheStats = [PSCustomObject]@{
    path = $ContextCachePath
    hitCount = [int]$contextCacheHitCount
    missCount = [int]$contextCacheMissCount
    stableReferenceCount = [int]$contextCacheReferenceCount
    stableReferenceSavedTokens = [int]$contextCacheReferenceSavedTokens
    policy = "full previews for changed/essential/entry/test and top 6 files; stable references only for unchanged low-priority normal files"
}
$stats = [PSCustomObject]@{
    generatedAt = $statsGeneratedAt.ToString("yyyy-MM-dd HH:mm:ss")
    generatedAtUtc = $statsGeneratedAtUtc.ToString("o")
    tooling = $toolingInfo
    projectPath = $root
    outputPath = $OutputPath
    statsPath = $StatsPath
    dashboardPath = $DashboardPath
    maxChars = $MaxChars
    budgetTokens = $budgetTokens
    outputChars = $text.Length
    outputTokens = $outputTokens
    outputCapped = $outputCapped
    originalChars = $originalChars
    originalTokens = $originalTokens
    savedTokens = $savedTokens
    savedPercent = $savedPercent
    budgetUsedPercent = $budgetUsedPercent
    coverageAudit = $coverageAudit
    contextCache = $contextCacheStats
    candidateFileCount = $contextFileList.Count
    scannedFileCount = $allFileList.Count
    excerptedFileCount = $fileStats.Count
    aiCodexPresent = $aiCodexPresent
    plan = $planStats
    appQuota = $appQuota
    openAIUsage = $openAIUsage
    history = $historyStats
    globalHistory = $globalHistoryStats
    audit = $statsAudit
    files = @($fileStats.ToArray())
}

$statsJson = $stats | ConvertTo-Json -Depth 6 -Compress
Set-Content -LiteralPath $StatsPath -Value $statsJson -Encoding UTF8
Set-Content -LiteralPath $DashboardPath -Value (New-DashboardHtml -Stats $stats -StatsJson $statsJson) -Encoding UTF8

if ($planStats.configured) {
    $planJson = [PSCustomObject]@{
        name = $planStats.name
        totalTokens = $planStats.totalTokens
        usedTokens = if ($ReadOpenAIUsage -and $openAIUsage.status -eq "ok" -and $openAIUsage.totalTokens -gt 0 -and $PlanUsedTokens -lt 0) { [long]$plan.usedTokens } else { $planStats.usedTokens }
        updatedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        lastUsageSource = if ($ReadOpenAIUsage -and $openAIUsage.status -eq "ok" -and $openAIUsage.totalTokens -gt 0 -and $PlanUsedTokens -lt 0) { "openai_usage_api" } else { "manual" }
    } | ConvertTo-Json -Depth 3
    Set-Content -LiteralPath $planStats.configPath -Value $planJson -Encoding UTF8
}

Write-Host "已生成: $OutputPath"
Write-Host "统计: $StatsPath"
Write-Host "仪表盘: $DashboardPath"
Write-Host "字符数: $($text.Length)"
Write-Host "估算 token: $outputTokens / $budgetTokens"
Write-Host "预计减少: $savedTokens token ($($stats.savedPercent)%)"
Write-Host "累计减少: $($historyStats.totalSavedTokens) token ($($historyStats.totalSavedPercent)%)，记录 $($historyStats.runCount) 次"
Write-Host "全局 context 减少: $($globalHistoryStats.totalSavedTokens) token ($($globalHistoryStats.totalSavedPercent)%)，对话/项目 $($globalHistoryStats.conversationCount) 个"
Write-Host "全对话有效性: 原本 $($globalHistoryStats.totalOriginalAllTokens) token，helper 后 $($globalHistoryStats.totalHelperAllTokens) token，减少 $($globalHistoryStats.totalAllSavedTokens) token ($($globalHistoryStats.totalAllSavedPercent)%)"
if ($planStats.configured) {
    Write-Host "套餐: $($planStats.usedTokens) / $($planStats.totalTokens) token，剩余 $($planStats.remainingTokens)"
}
else {
    Write-Host "套餐: 未配置，可传入 -PlanTotalTokens 和 -PlanUsedTokens"
}
if ($ReadOpenAIUsage) {
    Write-Host "OpenAI Usage: $($openAIUsage.status) - $($openAIUsage.message)"
}
Write-Host "文件数: $($allFileList.Count) 个扫描，$($contextFileList.Count) 个文本候选，$(@($rankedFiles).Count) 个摘录"
