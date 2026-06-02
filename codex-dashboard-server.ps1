param(
    [string]$ProjectPath = ".",
    [int]$Port = 8766,
    [string]$AdminKeyPath = "$env:USERPROFILE\.codex\openai-admin-key.dpapi"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = (Get-Item -LiteralPath $ProjectPath).FullName
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$tokenKit = Join-Path $scriptRoot "codex-token-kit.ps1"
$script:serverStartedAt = Get-Date
$script:serverStartedAtUtc = $script:serverStartedAt.ToUniversalTime()
$script:requestUsageCache = $null
$script:requestUsageCacheAt = [DateTime]::MinValue
$script:requestUsageStableByThread = @{}
$script:requestLineSeriesCache = $null
$script:requestLineSeriesCacheAt = [DateTime]::MinValue
$script:sessionTokenLineSeriesCache = $null
$script:sessionTokenLineSeriesCacheAt = [DateTime]::MinValue
$script:threadActivityCache = $null
$script:threadActivityCacheAt = [DateTime]::MinValue
$script:globalRequestTokensCache = $null
$script:globalRequestTokensCacheAt = [DateTime]::MinValue
$script:quotaReadMaxCurrentRequestTokens = 0L
$script:maxTotalOriginalAllTokens = 0L
$script:maxTotalHelperAllTokens = 0L
$script:usageCacheTtlSeconds = 30
$script:currentStatsCache = $null
$script:currentStatsJsonCache = $null
$script:currentStatsCacheAt = [DateTime]::MinValue
$script:currentStatsCacheWriteUtc = [DateTime]::MinValue
$script:currentStatsCacheTtlSeconds = 5
$script:autoJoinedPaths = @{}
$script:autoRefreshedStalePaths = @{}
$script:autoJoinLastSummary = [PSCustomObject]@{
    attempted = 0
    succeeded = 0
    failed = 0
    skippedThrottled = 0
    at = ""
    errors = @()
}
$script:autoRefreshStaleLastSummary = [PSCustomObject]@{
    attempted = 0
    succeeded = 0
    failed = 0
    skippedThrottled = 0
    at = ""
    errors = @()
}

function Send-Text {
    param(
        [System.Net.HttpListenerResponse]$Response,
        [int]$StatusCode,
        [string]$Text,
        [string]$ContentType = "text/plain; charset=utf-8"
    )

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $Response.StatusCode = $StatusCode
    $Response.ContentType = $ContentType
    try {
        $Response.ContentLength64 = $bytes.Length
    }
    catch {
        # Some local clients can cause HttpListener to consider headers submitted.
        # The body is still valid without an explicit Content-Length.
    }
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Response.OutputStream.Close()
}

function Send-Json {
    param(
        [System.Net.HttpListenerResponse]$Response,
        [int]$StatusCode,
        [object]$Body
    )

    Send-Text -Response $Response -StatusCode $StatusCode -Text ($Body | ConvertTo-Json -Depth 5) -ContentType "application/json; charset=utf-8"
}

function Escape-JsonForScript {
    param([string]$Value)
    if ($null -eq $Value) {
        return "{}"
    }

    return $Value.Replace("<", "\u003c").Replace(">", "\u003e").Replace("&", "\u0026")
}

function Get-DateTimeOrNull {
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

function Get-HelperToolingInfo {
    param([datetime]$StatsGeneratedAtUtc)

    $scriptNames = @(
        "codex-slim.ps1",
        "codex-token-kit.ps1",
        "codex-dashboard.ps1",
        "codex-dashboard-server.ps1",
        "codex-dashboard-smoke.ps1",
        "codex-helper-health.ps1",
        "codex-context-regression.ps1",
        "codex-dashboard-js-smoke.ps1"
    )

    $scripts = New-Object System.Collections.Generic.List[object]
    foreach ($name in $scriptNames) {
        $path = Join-Path $scriptRoot $name
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
    $latestUtc = if ($null -ne $latestItem) { [DateTime]::Parse($latestUtcText).ToUniversalTime() } else { [DateTime]::MinValue }

    return [PSCustomObject]@{
        schemaVersion = 1
        generatedBy = "codex-token-helper"
        helperVersion = if ($null -ne $latestItem) { "local-$($latestUtcText.Replace(':', '').Replace('-', '').Replace('.', ''))" } else { "local-unknown" }
        scriptRoot = $scriptRoot
        statsGeneratedAtUtc = $StatsGeneratedAtUtc.ToString("o")
        coreScriptMaxWriteUtc = $latestUtcText
        coreScriptMaxWriteLocal = if ($null -ne $latestItem) { [string]$latestItem.lastWriteLocal } else { "" }
        coreScriptMaxWritePath = if ($null -ne $latestItem) { [string]$latestItem.path } else { "" }
        statsStaleAfterScriptUpdate = [bool]($StatsGeneratedAtUtc.AddSeconds(2) -lt $latestUtc)
        serverStartedAtUtc = $script:serverStartedAtUtc.ToString("o")
        serverStartedAtLocal = $script:serverStartedAt.ToString("yyyy-MM-dd HH:mm:ss")
        serverStaleAfterScriptUpdate = [bool]($script:serverStartedAtUtc.AddSeconds(2) -lt $latestUtc)
        scripts = @($scripts.ToArray())
    }
}

function Get-GlobalInstallInfo {
    $globalBin = Join-Path $env:USERPROFILE ".codex\bin"
    $manifestPath = Join-Path $globalBin "codex-helper-install.json"
    $info = [PSCustomObject]@{
        ok = $false
        manifestPath = $manifestPath
        binPath = $globalBin
        sourceRoot = ""
        syncedAtUtc = ""
        scriptCount = 0
        cmdShimCount = 0
        message = "manifest missing"
    }

    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        return $info
    }

    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $sourceRoot = [string]$manifest.sourceRoot
        $binPath = [string]$manifest.binPath
        $ok = [bool]$manifest.ok -and
            (Test-Path -LiteralPath $sourceRoot -PathType Container) -and
            ([System.IO.Path]::GetFullPath($binPath) -eq [System.IO.Path]::GetFullPath($globalBin))

        return [PSCustomObject]@{
            ok = [bool]$ok
            manifestPath = $manifestPath
            binPath = $binPath
            sourceRoot = $sourceRoot
            syncedAtUtc = [string]$manifest.syncedAtUtc
            scriptCount = [int]$manifest.scriptCount
            cmdShimCount = [int]$manifest.cmdShimCount
            message = if ($ok) { "global bin synced" } else { "manifest invalid or source missing" }
        }
    }
    catch {
        $info.message = "manifest unreadable: $($_.Exception.Message)"
        return $info
    }
}

function Send-DashboardHtml {
    param(
        [System.Net.HttpListenerResponse]$Response,
        [string]$Path
    )

    $html = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    $statsJson = Get-CurrentStatsJson
    if (-not [string]::IsNullOrWhiteSpace($statsJson)) {
        $encoded = Escape-JsonForScript $statsJson
        $pattern = '<script type="application/json" id="stats-data">[\s\S]*?</script>'
        $replacement = '<script type="application/json" id="stats-data">' + $encoded + '</script>'
        $html = [System.Text.RegularExpressions.Regex]::Replace($html, $pattern, $replacement, [System.Text.RegularExpressions.RegexOptions]::Singleline)
    }

    $Response.Headers["Cache-Control"] = "no-store, max-age=0"
    Send-Text -Response $Response -StatusCode 200 -Text $html -ContentType "text/html; charset=utf-8"
}

function Save-AdminKey {
    param([string]$AdminKey)

    if ([string]::IsNullOrWhiteSpace($AdminKey)) {
        throw "Admin Key 为空。"
    }

    $outDir = Split-Path -Parent $AdminKeyPath
    if (-not [string]::IsNullOrWhiteSpace($outDir)) {
        New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    }

    $secure = ConvertTo-SecureString -String $AdminKey -AsPlainText -Force
    $encrypted = $secure | ConvertFrom-SecureString
    Set-Content -LiteralPath $AdminKeyPath -Value $encrypted -Encoding ASCII
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
            if (-not ($entry.PSObject.Properties.Name -contains "runKind") -or [string]$entry.runKind -eq "actual") {
                $total += [long]$entry.outputTokens
            }
        }
        catch {
        }
    }

    return $total
}

function Get-GlobalActualRequestTokens {
    if ($null -ne $script:globalRequestTokensCache -and ((Get-Date) - $script:globalRequestTokensCacheAt).TotalSeconds -lt $script:usageCacheTtlSeconds) {
        return [long]$script:globalRequestTokensCache
    }

    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($null -eq $python) {
        return 0L
    }

    $script = @'
import datetime, json, os, re, sqlite3
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
        $script:globalRequestTokensCache = $value
        $script:globalRequestTokensCacheAt = Get-Date
        return $value
    }
    catch {
        return 0L
    }
}

function Get-QuotaTotalEstimate {
    param(
        [long]$CurrentOutputTokens,
        [double]$UsedPercent
    )

    if ($CurrentOutputTokens -le 0 -or $UsedPercent -le 0) {
        return 0L
    }

    return [long]([Math]::Floor(($CurrentOutputTokens / ($UsedPercent / 100.0)) + 0.5))
}

function Get-NewRequestTokensSince {
    param([string]$Since)

    $sinceAt = Get-DateTimeOrNull $Since
    if ($null -eq $sinceAt) {
        $sinceAt = [DateTime]::MinValue
    }

    $tokens = 0L
    $maxAt = $sinceAt
    $series = @(Get-CodexRequestLineSeries -MaxSeries 128 -MaxPoints 500 -MinTotalTokens 1)
    foreach ($item in $series) {
        foreach ($point in @($item.points)) {
            $pointAt = Get-DateTimeOrNull ([string]$point.t)
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

function Save-AppQuota {
    param([object]$Payload)

    $codexDir = Join-Path $root ".codex"
    New-Item -ItemType Directory -Force -Path $codexDir | Out-Null
    $path = Join-Path $codexDir "app-quota.json"

    $shortPercent = [double]$Payload.shortUsedPercent
    $weeklyPercent = [double]$Payload.weeklyUsedPercent
    if ($shortPercent -lt 0 -or $shortPercent -gt 100 -or $weeklyPercent -lt 0 -or $weeklyPercent -gt 100) {
        throw "百分比必须在 0 到 100 之间。"
    }

    $currentOutput = Get-GlobalActualOutputTokens
    $currentRequest = Get-GlobalActualRequestTokens
    $quotaBasis = if ($currentRequest -gt 0) { $currentRequest } else { $currentOutput }
    $shortTotalEstimate = Get-QuotaTotalEstimate -CurrentOutputTokens $quotaBasis -UsedPercent $shortPercent
    $weeklyTotalEstimate = Get-QuotaTotalEstimate -CurrentOutputTokens $quotaBasis -UsedPercent $weeklyPercent

    $quota = [PSCustomObject]@{
        shortWindowLabel = [string]$Payload.shortWindowLabel
        shortUsedPercent = $shortPercent
        shortRemainingPercent = $shortPercent
        weeklyWindowLabel = [string]$Payload.weeklyWindowLabel
        weeklyUsedPercent = $weeklyPercent
        weeklyRemainingPercent = $weeklyPercent
        weeklyResetLabel = [string]$Payload.weeklyResetLabel
        calibratedGlobalOutputTokens = $currentOutput
        calibratedGlobalRequestTokens = $currentRequest
        lastObservedGlobalRequestTokens = $currentRequest
        lastObservedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        quotaEstimateBasis = if ($currentRequest -gt 0) { "real_request_tokens" } else { "helper_context_tokens" }
        shortTotalEstimateTokens = $shortTotalEstimate
        weeklyTotalEstimateTokens = $weeklyTotalEstimate
        updatedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    }

    Set-Content -LiteralPath $path -Value ($quota | ConvertTo-Json -Depth 4) -Encoding UTF8
}

function Get-LiveAppQuota {
    param([switch]$UpdateState)

    $path = Join-Path $root ".codex/app-quota.json"
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

            if (-not $UpdateState -and $script:quotaReadMaxCurrentRequestTokens -gt 0) {
                $current = [Math]::Max([long]$current, [long]$script:quotaReadMaxCurrentRequestTokens)
            }
            if ($current -gt $script:quotaReadMaxCurrentRequestTokens) {
                $script:quotaReadMaxCurrentRequestTokens = [long]$current
            }

            if ($UpdateState -and $localEffective -gt $localObservedMax -and $quota.PSObject.Properties.Name -contains "calibratedGlobalRequestTokens") {
                $quota | Add-Member -NotePropertyName localObservedMaxRequestTokens -NotePropertyValue ([long]$localEffective) -Force
            }
            if ($UpdateState -and $newRequestTokens -gt 0 -and $quota.PSObject.Properties.Name -contains "calibratedGlobalRequestTokens") {
                $quotaIncrementalTotal += [long]$newRequestTokens
                $quota | Add-Member -NotePropertyName quotaIncrementalRequestTokens -NotePropertyValue ([long]$quotaIncrementalTotal) -Force
                if (-not [string]::IsNullOrWhiteSpace([string]$newSinceLastApplied.maxAtLocal)) {
                    $quota | Add-Member -NotePropertyName quotaLastAppliedRequestAt -NotePropertyValue ([string]$newSinceLastApplied.maxAtLocal) -Force
                }
            }

            if ($UpdateState -and $current -gt $lastObserved -and $quota.PSObject.Properties.Name -contains "calibratedGlobalRequestTokens") {
                $quota | Add-Member -NotePropertyName lastObservedGlobalRequestTokens -NotePropertyValue ([long]$current) -Force
                $quota | Add-Member -NotePropertyName lastObservedAt -NotePropertyValue (Get-Date -Format "yyyy-MM-dd HH:mm:ss") -Force
                Set-Content -LiteralPath $path -Value ($quota | ConvertTo-Json -Depth 8) -Encoding UTF8
                $lastObserved = [long]$current
            }
            elseif ($UpdateState -and $localEffective -gt $localObservedMax -and $quota.PSObject.Properties.Name -contains "calibratedGlobalRequestTokens") {
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
                $resetAt = Get-DateTimeOrNull ([string]$quota.shortWindowResetAt)
                if ($null -ne $resetAt) {
                    $nowUtc = (Get-Date).ToUniversalTime()
                    while ($resetAt -le $nowUtc) {
                        $resetAt = $resetAt.AddHours(5)
                    }
                    $shortBaselineAt = if ($quota.PSObject.Properties.Name -contains "shortWindowBaselineRequestAt") { Get-DateTimeOrNull ([string]$quota.shortWindowBaselineRequestAt) } else { $null }
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

function Get-ContentType {
    param([string]$Path)

    switch ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        ".html" { "text/html; charset=utf-8" }
        ".json" { "application/json; charset=utf-8" }
        ".js" { "text/javascript; charset=utf-8" }
        ".css" { "text/css; charset=utf-8" }
        ".png" { "image/png" }
        default { "application/octet-stream" }
    }
}

function Get-StatsPath {
    return (Join-Path $root ".codex\stats.json")
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

function Test-EntryKind {
    param(
        [object]$Entry,
        [string]$Kind
    )

    if (-not ($Entry.PSObject.Properties.Name -contains "runKind")) {
        return $Kind -eq "actual"
    }

    return [string]$Entry.runKind -eq $Kind
}

function New-HistoryGroups {
    param(
        [array]$Entries,
        [hashtable]$RequestUsageByName = @{},
        [hashtable]$RequestUsageByPath = @{},
        [hashtable]$ThreadActivityByPath = @{}
    )

    return @($Entries | Group-Object -Property projectPath | ForEach-Object {
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

    if ($null -ne $script:requestLineSeriesCache -and ((Get-Date) - $script:requestLineSeriesCacheAt).TotalSeconds -lt $script:usageCacheTtlSeconds) {
        return @($script:requestLineSeriesCache)
    }

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
        $script:requestLineSeriesCache = @($result)
        $script:requestLineSeriesCacheAt = Get-Date
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
    if ($null -ne $script:sessionTokenLineSeriesCache -and ((Get-Date) - $script:sessionTokenLineSeriesCacheAt).TotalSeconds -lt $script:usageCacheTtlSeconds) {
        return @($script:sessionTokenLineSeriesCache)
    }

    $script = @'
import collections, datetime, json, os

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
            usage = (((row.get("payload") or {}).get("info") or {}).get("last_token_usage") or {})
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
        $script:sessionTokenLineSeriesCache = @($result)
        $script:sessionTokenLineSeriesCacheAt = Get-Date
        return @($result)
    }
    catch {
        return @()
    }
}

function Get-UsageDetection {
    param(
        [array]$ActualEntries,
        [array]$RefreshEntries = @(),
        [array]$RequestLineSeries = @(),
        [array]$SessionTokenLineSeries = @(),
        [array]$Groups,
        [array]$UnmatchedRequestThreads = @()
    )

    $now = Get-Date
    $recentOutput = 0L
    $allOutput = 0L
    $lastActualRun = ""
    $lastActualAt = $null

    foreach ($entry in $ActualEntries) {
        $allOutput += [long]$entry.outputTokens
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
    if ($ActualEntries.Count -eq 0) {
        $usageStatus = "warn"
        $usageMessage = "还没有 actual 记录；其他对话需要先接入 token helper。"
    }
    elseif ($lastRunAgeMinutes -gt 360) {
        $usageStatus = "idle"
        $usageMessage = "最近 6 小时没有新的 actual 记录。"
    }

    $trendEntries = @($ActualEntries | Sort-Object -Property generatedAt | Select-Object -Last 14 | ForEach-Object {
        [PSCustomObject]@{
            generatedAt = [string]$_.generatedAt
            conversationName = if ($_.PSObject.Properties.Name -contains "conversationName") { [string]$_.conversationName } else { Split-Path -Leaf ([string]$_.projectPath) }
            outputTokens = [long]$_.outputTokens
            savedTokens = [long]$_.savedTokens
            outputCapped = if ($_.PSObject.Properties.Name -contains "outputCapped") { [bool]$_.outputCapped } else { (($_.outputTokens -ge 3000 -and $_.outputTokens -le 3020) -or ($_.outputTokens -ge 6000 -and $_.outputTokens -le 6020)) }
        }
    })
    $cappedProjectCount = @($Groups | Where-Object { $_.cappedRunCount -gt 0 }).Count
    $helperReviewProjects = @($Groups | Where-Object {
        ($_.PSObject.Properties.Name -contains "needsHelperReview") -and [bool]$_.needsHelperReview
    } | Sort-Object @{ Expression = {
        $ratio = if ($_.PSObject.Properties.Name -contains "requestToHelperRatio") { [double]$_.requestToHelperRatio } else { 0.0 }
        $stale = if ($_.PSObject.Properties.Name -contains "helperStaleAfterRequestMinutes") { [int]$_.helperStaleAfterRequestMinutes } else { 0 }
        [Math]::Max($ratio, ($stale / 30.0))
    }; Descending = $true } | Select-Object -First 8)
    $autoJoinDiagnostics = Get-AutoJoinDiagnostics -UnmatchedRequestThreads $UnmatchedRequestThreads

    return [PSCustomObject]@{
        status = $usageStatus
        message = $usageMessage
        lastRun = $lastActualRun
        lastRunAgeMinutes = $lastRunAgeMinutes
        recent24hOutputTokens = $recentOutput
        currentOutputTokens = $allOutput
        cappedProjectCount = $cappedProjectCount
        helperReviewProjectCount = @($helperReviewProjects).Count
        helperReviewProjects = @($helperReviewProjects)
        cappedRunCount = @($ActualEntries | Where-Object {
            if ($_.PSObject.Properties.Name -contains "outputCapped") { [bool]$_.outputCapped }
            else { (($_.outputTokens -ge 3000 -and $_.outputTokens -le 3020) -or ($_.outputTokens -ge 6000 -and $_.outputTokens -le 6020)) }
        }).Count
        historicalRequestProjectCount = @($Groups | Where-Object {
            ($_.PSObject.Properties.Name -contains "requestUsageMatched") -and
            [bool]$_.requestUsageMatched -and
            ($_.PSObject.Properties.Name -contains "requestUsageAfterHelper") -and
            -not [bool]$_.requestUsageAfterHelper -and
            [long]$_.requestTotalTokens -gt [long]$_.totalOutputTokens
        }).Count
        postHelperRequestProjectCount = @($Groups | Where-Object {
            ($_.PSObject.Properties.Name -contains "requestUsageMatched") -and
            [bool]$_.requestUsageMatched -and
            ($_.PSObject.Properties.Name -contains "requestUsageAfterHelper") -and
            [bool]$_.requestUsageAfterHelper
        }).Count
        untrackedRequestThreadCount = @($UnmatchedRequestThreads).Count
        untrackedRequestThreads = @($UnmatchedRequestThreads)
        autoJoinDiagnostics = $autoJoinDiagnostics
        capMessage = if ($cappedProjectCount -gt 0) { "$cappedProjectCount 个项目打满 context 预算；相同写入 token 多半是 MaxChars 截断，不代表真实消耗相同。" } else { "未检测到明显 context 预算截断。" }
        trend = @($trendEntries)
        requestLineSeries = @($RequestLineSeries)
        sessionTokenLineSeries = @($SessionTokenLineSeries)
        savedLineSeries = @(New-UsageLineSeries -ActualEntries @($ActualEntries))
        lineSeries = @(New-UsageLineSeries -ActualEntries (@($ActualEntries) + @($RefreshEntries)))
        projectUsage = @($Groups | Sort-Object @{ Expression = "helperAllTokens"; Descending = $true }, @{ Expression = "totalOutputTokens"; Descending = $true } | Select-Object -First 8)
    }
}

function Get-AutoJoinDiagnostics {
    param([array]$UnmatchedRequestThreads = @())

    $joinable = 0
    $missingPath = 0
    $noPath = 0
    $throttled = 0
    $topJoinable = New-Object System.Collections.Generic.List[object]
    $now = Get-Date

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

        $key = $path.ToLowerInvariant()
        $last = if ($script:autoJoinedPaths.ContainsKey($key)) { [DateTime]$script:autoJoinedPaths[$key] } else { [DateTime]::MinValue }
        if (($now - $last).TotalMinutes -lt 10) {
            $throttled++
        }
        else {
            $joinable++
            if ($topJoinable.Count -lt 5) {
                [void]$topJoinable.Add([PSCustomObject]@{
                    conversationName = [string]$item.conversationName
                    cwd = $path
                    totalTokens = [long]$item.totalTokens
                })
            }
        }
    }

    return [PSCustomObject]@{
        totalUntracked = @($UnmatchedRequestThreads).Count
        joinableThreadCount = $joinable
        missingPathThreadCount = $missingPath
        noPathThreadCount = $noPath
        throttledThreadCount = $throttled
        topJoinableThreads = @($topJoinable.ToArray())
        lastAutoJoin = $script:autoJoinLastSummary
        lastAutoRefreshStale = $script:autoRefreshStaleLastSummary
        message = if (@($UnmatchedRequestThreads).Count -eq 0) {
            "所有有路径的近期请求都已接入或已匹配。"
        }
        elseif ($joinable -gt 0) {
            "$joinable 个线程可自动接入，刷新时会优先处理。"
        }
        else {
            "暂无可自动接入线程；可能缺少项目路径、路径不可访问，或刚接入过正在限流。"
        }
    }
}

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

function Get-CodexRequestUsage {
    if ($null -ne $script:requestUsageCache -and ((Get-Date) - $script:requestUsageCacheAt).TotalSeconds -lt $script:usageCacheTtlSeconds) {
        return @($script:requestUsageCache)
    }

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
usage = {}
if os.path.exists(logs_path):
    con = sqlite3.connect(logs_path)
    cur = con.cursor()
    for ts, thread_id, body in cur.execute("select ts, thread_id, feedback_log_body from logs where feedback_log_body like '%response.completed%' and feedback_log_body like '%\"usage\"%'"):
        if not thread_id or not body:
            continue
        m = re.search(r"websocket event: (\{.*\})", body)
        if not m:
            continue
        try:
            data = (json.loads(m.group(1)).get("response", {}).get("usage") or {})
        except Exception:
            continue
        total = int(data.get("total_tokens") or 0)
        if total <= 0:
            continue
        cwd_match = re.search(r"cwd=([^}]+)\}:try_run_sampling_request", body)
        cwd = cwd_match.group(1) if cwd_match else ""
        item = usage.setdefault(thread_id, {"threadId": thread_id, "conversationName": titles.get(thread_id, thread_id), "cwd": cwd, "requestCount": 0, "inputTokens": 0, "outputTokens": 0, "totalTokens": 0, "lastTs": 0})
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
        foreach ($item in $result) {
            $key = if (-not [string]::IsNullOrWhiteSpace([string]$item.threadId)) {
                [string]$item.threadId
            }
            else {
                ([string]$item.cwd + "|" + [string]$item.conversationName).ToLowerInvariant()
            }

            if ([string]::IsNullOrWhiteSpace($key)) {
                continue
            }

            if (-not $script:requestUsageStableByThread.ContainsKey($key)) {
                $script:requestUsageStableByThread[$key] = [PSCustomObject]@{
                    threadId = [string]$item.threadId
                    conversationName = [string]$item.conversationName
                    cwd = [string]$item.cwd
                    requestCount = [int]$item.requestCount
                    inputTokens = [long]$item.inputTokens
                    outputTokens = [long]$item.outputTokens
                    totalTokens = [long]$item.totalTokens
                    lastTs = if ($item.PSObject.Properties.Name -contains "lastTs") { [long]$item.lastTs } else { 0L }
                    lastRun = if ($item.PSObject.Properties.Name -contains "lastRun") { [string]$item.lastRun } else { "" }
                }
                continue
            }

            $existing = $script:requestUsageStableByThread[$key]
            if ([string]::IsNullOrWhiteSpace([string]$existing.conversationName) -and -not [string]::IsNullOrWhiteSpace([string]$item.conversationName)) {
                $existing.conversationName = [string]$item.conversationName
            }
            if ([string]::IsNullOrWhiteSpace([string]$existing.cwd) -and -not [string]::IsNullOrWhiteSpace([string]$item.cwd)) {
                $existing.cwd = [string]$item.cwd
            }
            $existing.requestCount = [Math]::Max([int]$existing.requestCount, [int]$item.requestCount)
            $existing.inputTokens = [Math]::Max([long]$existing.inputTokens, [long]$item.inputTokens)
            $existing.outputTokens = [Math]::Max([long]$existing.outputTokens, [long]$item.outputTokens)
            $existing.totalTokens = [Math]::Max([long]$existing.totalTokens, [long]$item.totalTokens)
            if ($item.PSObject.Properties.Name -contains "lastTs") {
                $existing.lastTs = [Math]::Max([long]$existing.lastTs, [long]$item.lastTs)
            }
            if ([long]$existing.lastTs -gt 0) {
                try {
                    $existing.lastRun = ([DateTimeOffset]::FromUnixTimeSeconds([long]$existing.lastTs).LocalDateTime).ToString("yyyy-MM-dd HH:mm:ss")
                }
                catch {
                    $existing.lastRun = if ($item.PSObject.Properties.Name -contains "lastRun") { [string]$item.lastRun } else { [string]$existing.lastRun }
                }
            }
        }

        $stable = @($script:requestUsageStableByThread.Values | Sort-Object -Property totalTokens -Descending)
        $script:requestUsageCache = $stable
        $script:requestUsageCacheAt = Get-Date
        return @($stable)
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
    if ($null -ne $script:threadActivityCache -and ((Get-Date) - $script:threadActivityCacheAt).TotalSeconds -lt $script:usageCacheTtlSeconds) {
        return @($script:threadActivityCache)
    }

    $items = New-Object System.Collections.Generic.List[object]
    foreach ($file in @(Get-ChildItem -LiteralPath $sessionsRoot -Recurse -Filter "*.jsonl" -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 40)) {
        $threadId = ""
        $cwd = ""
        $lastTimestamp = ""
        try {
            foreach ($line in @(Get-Content -LiteralPath $file.FullName -First 6 -ErrorAction Stop)) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                $row = $null
                try { $row = $line | ConvertFrom-Json } catch { continue }
                if (($row.PSObject.Properties.Name -contains "type") -and [string]$row.type -eq "session_meta") {
                    if ($row.payload.PSObject.Properties.Name -contains "id") { $threadId = [string]$row.payload.id }
                    if ($row.payload.PSObject.Properties.Name -contains "cwd") { $cwd = [string]$row.payload.cwd }
                    break
                }
            }
            foreach ($line in @(Get-Content -LiteralPath $file.FullName -Tail 30 -ErrorAction Stop)) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
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
            try { $lastActivity = ([DateTimeOffset]::Parse($lastTimestamp).LocalDateTime).ToString("yyyy-MM-dd HH:mm:ss") } catch {}
        }

        [void]$items.Add([PSCustomObject]@{
            threadId = $threadId
            cwd = $cwd
            lastActivityRun = $lastActivity
            sessionPath = $file.FullName
        })
    }

    $result = @($items.ToArray())
    $script:threadActivityCache = $result
    $script:threadActivityCacheAt = Get-Date
    return @($result)
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
            $item.lastRun = if ($Usage.PSObject.Properties.Name -contains "lastRun") { [string]$Usage.lastRun } else { [string]$item.lastRun }
        }
    }
    $item.threadCount = [int]$item.threadCount + 1
}

function Get-LiveGlobalHistory {
    $historyPath = Join-Path $env:USERPROFILE ".codex\codex-token-helper-history.jsonl"
    $entries = New-Object System.Collections.Generic.List[object]

    if (Test-Path -LiteralPath $historyPath) {
        foreach ($line in (Get-Content -LiteralPath $historyPath)) {
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }
            try {
                [void]$entries.Add(($line | ConvertFrom-Json))
            }
            catch {
            }
        }
    }

    $allEntries = @($entries.ToArray())
    $actualEntries = @($allEntries | Where-Object { Test-EntryKind -Entry $_ -Kind "actual" })
    $baselineEntries = @($allEntries | Where-Object { Test-EntryKind -Entry $_ -Kind "baseline" })
    $refreshEntries = @($allEntries | Where-Object { Test-EntryKind -Entry $_ -Kind "refresh" })
    $rawActualRunCount = $actualEntries.Count
    $actualEntries = Get-DedupedActualEntries -Items $actualEntries

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

    $groups = New-HistoryGroups -Entries $actualEntries -RequestUsageByName $requestUsageByName -RequestUsageByPath $requestUsageByPath -ThreadActivityByPath $threadActivityByPath
    $baselineGroups = New-HistoryGroups -Entries $baselineEntries -RequestUsageByName $requestUsageByName -RequestUsageByPath $requestUsageByPath -ThreadActivityByPath $threadActivityByPath
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

    $script:maxTotalOriginalAllTokens = [Math]::Max([long]$script:maxTotalOriginalAllTokens, [long]$allOriginalAll)
    $script:maxTotalHelperAllTokens = [Math]::Max([long]$script:maxTotalHelperAllTokens, [long]$allHelperAll)
    $stableOriginalAll = [long]$script:maxTotalOriginalAllTokens
    $stableHelperAll = [long]$script:maxTotalHelperAllTokens
    $stableAllSaved = [Math]::Max(0L, ($stableOriginalAll - $stableHelperAll))

    return [PSCustomObject]@{
        historyPath = $historyPath
        conversationCount = @($groups).Count
        runCount = $actualEntries.Count
        rawRunCount = $rawActualRunCount
        dedupedRunCount = ($rawActualRunCount - $actualEntries.Count)
        effectiveRunCount = @($groups).Count
        totalOriginalTokens = $allOriginal
        totalOutputTokens = $allOutput
        totalSavedTokens = $allSaved
        totalSavedPercent = (Get-Percent -Numerator ([double]$allSaved) -Denominator ([double]$allOriginal))
        totalOriginalAllTokens = $stableOriginalAll
        totalHelperAllTokens = $stableHelperAll
        totalAllSavedTokens = $stableAllSaved
        totalAllSavedPercent = (Get-Percent -Numerator ([double]$stableAllSaved) -Denominator ([double]$stableOriginalAll))
        baselineRunCount = $baselineEntries.Count
        baselineOriginalTokens = $baselineOriginal
        baselineOutputTokens = $baselineOutput
        baselineSavedTokens = $baselineSaved
        baselineSavedPercent = (Get-Percent -Numerator ([double]$baselineSaved) -Denominator ([double]$baselineOriginal))
        refreshRunCount = $refreshEntries.Count
        conversations = @($groups)
        usageDetection = (Get-UsageDetection -ActualEntries $actualEntries -RefreshEntries $refreshEntries -RequestLineSeries $requestLineSeries -SessionTokenLineSeries $sessionTokenLineSeries -Groups $groups -UnmatchedRequestThreads $unmatchedRequestThreads)
        baselineConversationCount = @($baselineGroups).Count
        baselineConversations = @($baselineGroups)
    }
}

function Get-LiveStatsAudit {
    param([object]$GlobalHistory)

    $warnings = New-Object System.Collections.Generic.List[object]
    foreach ($item in @($GlobalHistory.conversations)) {
        if (($item.PSObject.Properties.Name -contains "requestUsageMatched") -and -not [bool]$item.requestUsageMatched) {
            [void]$warnings.Add([PSCustomObject]@{
                severity = "warning"
                message = "项目 '$($item.conversationName)' 还没有匹配到真实请求日志。"
            })
        }
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
                    "项目 '$($item.conversationName)' 最新 Codex 请求晚于 helper actual，已尝试自动刷新。"
                }
                else {
                    "项目 '$($item.conversationName)' 历史 Codex 请求多于 helper actual；这是历史覆盖不足，不代表当前后台进程耗 token。"
                }
            })
        }
    }

    $untracked = 0
    if ($GlobalHistory.PSObject.Properties.Name -contains "usageDetection") {
        $untracked = [int]$GlobalHistory.usageDetection.untrackedRequestThreadCount
    }
    if ($untracked -gt 0) {
        [void]$warnings.Add([PSCustomObject]@{
            severity = "warning"
            message = "$untracked 个线程有真实请求日志但还没有 helper actual。"
        })
    }

    $warningArray = @($warnings.ToArray())
    $actionableCount = @($warningArray | Where-Object { [string]$_.severity -ne "info" }).Count

    return [PSCustomObject]@{
        ok = ($actionableCount -eq 0)
        warningCount = $actionableCount
        infoCount = @($warningArray | Where-Object { [string]$_.severity -eq "info" }).Count
        warnings = $warningArray
    }
}

function Invoke-AutoJoinUntrackedThreads {
    param(
        [object]$GlobalHistory,
        [int]$MaxChars = 12000
    )

    if ($null -eq $GlobalHistory -or -not ($GlobalHistory.PSObject.Properties.Name -contains "usageDetection")) {
        return $false
    }

    $untracked = @($GlobalHistory.usageDetection.untrackedRequestThreads)
    if ($untracked.Count -eq 0) {
        return $false
    }

    $joined = $false
    $attempted = 0
    $succeeded = 0
    $failed = 0
    $skippedThrottled = 0
    $errors = New-Object System.Collections.Generic.List[object]
    foreach ($item in @($untracked | Sort-Object -Property totalTokens -Descending)) {
        $path = [string]$item.cwd
        if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Container)) {
            continue
        }

        $key = $path.ToLowerInvariant()
        $last = if ($script:autoJoinedPaths.ContainsKey($key)) { [DateTime]$script:autoJoinedPaths[$key] } else { [DateTime]::MinValue }
        if (((Get-Date) - $last).TotalMinutes -lt 10) {
            $skippedThrottled++
            continue
        }

        $name = [string]$item.conversationName
        if ([string]::IsNullOrWhiteSpace($name)) {
            $name = Split-Path -Leaf $path
        }

        $attempted++
        & powershell -NoProfile -ExecutionPolicy Bypass -File $tokenKit -ProjectPath $path -MaxChars $MaxChars -ConversationName $name -RunKind actual -SkipAiCodex -Quiet | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $script:autoJoinedPaths[$key] = Get-Date
            $joined = $true
            $succeeded++
        }
        else {
            $failed++
            if ($errors.Count -lt 5) {
                [void]$errors.Add([PSCustomObject]@{
                    conversationName = $name
                    cwd = $path
                    exitCode = $LASTEXITCODE
                })
            }
        }
    }

    $script:autoJoinLastSummary = [PSCustomObject]@{
        attempted = $attempted
        succeeded = $succeeded
        failed = $failed
        skippedThrottled = $skippedThrottled
        at = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        errors = @($errors.ToArray())
    }

    return $joined
}

function Invoke-AutoRefreshStaleHelperProjects {
    param(
        [object]$GlobalHistory,
        [int]$MaxChars = 12000
    )

    if ($null -eq $GlobalHistory -or -not ($GlobalHistory.PSObject.Properties.Name -contains "usageDetection")) {
        return $false
    }

    $reviewProjects = @($GlobalHistory.usageDetection.helperReviewProjects | Where-Object {
        ($_.PSObject.Properties.Name -contains "helperStaleAfterRequest") -and
        [bool]$_.helperStaleAfterRequest
    })
    if ($reviewProjects.Count -eq 0) {
        return $false
    }

    $refreshed = $false
    $attempted = 0
    $succeeded = 0
    $failed = 0
    $skippedThrottled = 0
    $errors = New-Object System.Collections.Generic.List[object]
    foreach ($item in @($reviewProjects | Sort-Object -Property helperStaleAfterRequestMinutes -Descending)) {
        $path = [string]$item.projectPath
        if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Container)) {
            continue
        }

        $key = $path.ToLowerInvariant()
        $last = if ($script:autoRefreshedStalePaths.ContainsKey($key)) { [DateTime]$script:autoRefreshedStalePaths[$key] } else { [DateTime]::MinValue }
        if (((Get-Date) - $last).TotalMinutes -lt 10) {
            $skippedThrottled++
            continue
        }

        $name = [string]$item.conversationName
        if ([string]::IsNullOrWhiteSpace($name)) {
            $name = Split-Path -Leaf $path
        }

        $attempted++
        & powershell -NoProfile -ExecutionPolicy Bypass -File $tokenKit -ProjectPath $path -MaxChars $MaxChars -ConversationName $name -RunKind actual -SkipAiCodex -Quiet | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $script:autoRefreshedStalePaths[$key] = Get-Date
            $refreshed = $true
            $succeeded++
        }
        else {
            $failed++
            if ($errors.Count -lt 5) {
                [void]$errors.Add([PSCustomObject]@{
                    conversationName = $name
                    projectPath = $path
                    exitCode = $LASTEXITCODE
                })
            }
        }
    }

    $script:autoRefreshStaleLastSummary = [PSCustomObject]@{
        attempted = $attempted
        succeeded = $succeeded
        failed = $failed
        skippedThrottled = $skippedThrottled
        at = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        errors = @($errors.ToArray())
    }

    return $refreshed
}

function Get-CurrentStats {
    param([switch]$Force)

    $statsPath = Get-StatsPath
    if (Test-Path -LiteralPath $statsPath -PathType Leaf) {
        try {
            $writeUtc = (Get-Item -LiteralPath $statsPath).LastWriteTimeUtc
            if (-not $Force -and $null -ne $script:currentStatsCache -and
                $script:currentStatsCacheWriteUtc -eq $writeUtc -and
                ((Get-Date) - $script:currentStatsCacheAt).TotalSeconds -lt $script:currentStatsCacheTtlSeconds) {
                return $script:currentStatsCache
            }

            $stats = Get-Content -LiteralPath $statsPath -Raw | ConvertFrom-Json
            $globalHistory = Get-LiveGlobalHistory
            $maxChars = if ($stats.PSObject.Properties.Name -contains "maxChars" -and $stats.maxChars -gt 0) { [int]$stats.maxChars } else { 12000 }
            $changedByAutoJoin = Invoke-AutoJoinUntrackedThreads -GlobalHistory $globalHistory -MaxChars $maxChars
            if ($changedByAutoJoin) {
                $globalHistory = Get-LiveGlobalHistory
            }
            $changedByStaleRefresh = Invoke-AutoRefreshStaleHelperProjects -GlobalHistory $globalHistory -MaxChars $maxChars
            if ($changedByStaleRefresh) {
                $globalHistory = Get-LiveGlobalHistory
            }
            $stats | Add-Member -NotePropertyName globalHistory -NotePropertyValue $globalHistory -Force
            $stats | Add-Member -NotePropertyName audit -NotePropertyValue (Get-LiveStatsAudit -GlobalHistory $globalHistory) -Force
            $stats | Add-Member -NotePropertyName appQuota -NotePropertyValue (Get-LiveAppQuota) -Force
            $script:currentStatsCache = $stats
            $script:currentStatsJsonCache = $null
            $script:currentStatsCacheAt = Get-Date
            $script:currentStatsCacheWriteUtc = $writeUtc
            return $stats
        }
        catch {
        }
    }

    return $null
}

function Get-CurrentStatsJson {
    param([switch]$Force)

    $stats = Get-CurrentStats -Force:$Force
    if ($null -eq $stats) {
        return $null
    }

    if (-not $Force -and -not [string]::IsNullOrWhiteSpace($script:currentStatsJsonCache) -and
        ((Get-Date) - $script:currentStatsCacheAt).TotalSeconds -lt $script:currentStatsCacheTtlSeconds) {
        return $script:currentStatsJsonCache
    }

    $script:currentStatsJsonCache = ($stats | ConvertTo-Json -Depth 8 -Compress)
    return $script:currentStatsJsonCache
}

function Get-HealthSummary {
    $stats = Get-CurrentStats
    if ($null -eq $stats) {
        return [PSCustomObject]@{
            ok = $false
            status = "error"
            generatedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            message = "stats.json not found or unreadable"
            checks = @()
            stats = $null
        }
    }

    $checks = New-Object System.Collections.Generic.List[object]
    $addCheck = {
        param(
            [string]$Name,
            [bool]$Ok,
            [string]$Message,
            [string]$Severity
        )
        [void]$checks.Add([PSCustomObject]@{
            name = $Name
            ok = $Ok
            severity = if ($Ok) { "ok" } else { $Severity }
            failureSeverity = $Severity
            message = $Message
        })
    }

    $coverageRisk = if ($stats.PSObject.Properties.Name -contains "coverageAudit") { [string]$stats.coverageAudit.risk } else { "unknown" }
    $coverageOk = ($coverageRisk -ne "high")
    $coverageMessage = if ($coverageOk) { "context 覆盖风险正常：$coverageRisk" } else { "coverage risk: $coverageRisk" }
    & $addCheck "coverage" $coverageOk $coverageMessage "error"

    $changedOk = $true
    if ($stats.PSObject.Properties.Name -contains "coverageAudit") {
        $changedOk = ([int]$stats.coverageAudit.changedFilesIncludedCount -eq [int]$stats.coverageAudit.changedFileCount)
    }
    $changedMessage = if ($changedOk) {
        "当前改动已覆盖 $($stats.coverageAudit.changedFilesIncludedCount)/$($stats.coverageAudit.changedFileCount)"
    }
    else {
        "changed coverage $($stats.coverageAudit.changedFilesIncludedCount)/$($stats.coverageAudit.changedFileCount)"
    }
    & $addCheck "changed-files" $changedOk $changedMessage "error"

    $budgetOk = ([int]$stats.outputTokens -le ([int]$stats.budgetTokens + 16))
    $budgetMessage = if ($budgetOk) {
        "context 写入在预算容差内：$($stats.outputTokens) / $($stats.budgetTokens)"
    }
    else {
        "output $($stats.outputTokens) / budget $($stats.budgetTokens)"
    }
    & $addCheck "budget" $budgetOk $budgetMessage "warning"

    $untracked = 0
    $joinable = 0
    if ($stats.PSObject.Properties.Name -contains "globalHistory" -and $stats.globalHistory.PSObject.Properties.Name -contains "usageDetection") {
        $untracked = [int]$stats.globalHistory.usageDetection.untrackedRequestThreadCount
        if ($stats.globalHistory.usageDetection.PSObject.Properties.Name -contains "autoJoinDiagnostics") {
            $joinable = [int]$stats.globalHistory.usageDetection.autoJoinDiagnostics.joinableThreadCount
        }
    }
    $autoJoinOk = ($untracked -eq 0 -or $joinable -gt 0)
    $autoJoinMessage = if ($untracked -eq 0) {
        "近期请求都已匹配或接入"
    }
    elseif ($autoJoinOk) {
        "可自动接入 $joinable 个线程，未接入 $untracked 个"
    }
    else {
        "untracked $untracked, joinable $joinable"
    }
    & $addCheck "auto-join" $autoJoinOk $autoJoinMessage "warning"

    $auditOk = $true
    $auditWarnings = 0
    if ($stats.PSObject.Properties.Name -contains "audit") {
        $auditOk = [bool]$stats.audit.ok
        $auditWarnings = [int]$stats.audit.warningCount
    }
    $auditMessage = if ($auditOk) { "统计自检无异常" } else { "audit warnings $auditWarnings" }
    & $addCheck "stats-audit" $auditOk $auditMessage "warning"

    $cacheOk = ($stats.PSObject.Properties.Name -contains "contextCache")
    & $addCheck "context-cache" $cacheOk $(if ($cacheOk) { "context 缓存元数据正常" } else { "context cache metadata missing" }) "warning"

    $quotaProtected = $false
    $quotaApplied = 0L
    $quotaIncrementalTotal = 0L
    if ($stats.PSObject.Properties.Name -contains "appQuota" -and [bool]$stats.appQuota.configured) {
        if ($stats.appQuota.PSObject.Properties.Name -contains "quotaLogResetProtected") {
            $quotaProtected = [bool]$stats.appQuota.quotaLogResetProtected
        }
        if ($stats.appQuota.PSObject.Properties.Name -contains "quotaNewRequestTokensApplied") {
            $quotaApplied = [long]$stats.appQuota.quotaNewRequestTokensApplied
        }
        if ($stats.appQuota.PSObject.Properties.Name -contains "quotaIncrementalRequestTokens") {
            $quotaIncrementalTotal = [long]$stats.appQuota.quotaIncrementalRequestTokens
        }
    }
    $quotaOk = (-not $quotaProtected -or $quotaApplied -gt 0 -or $quotaIncrementalTotal -gt 0)
    $quotaMessage = if ($quotaOk) {
        "套餐估算账本正常：新增 $quotaApplied token，累计增量 $quotaIncrementalTotal"
    }
    else {
        "log reset protected: $quotaProtected, newly applied request tokens: $quotaApplied, incremental total: $quotaIncrementalTotal"
    }
    & $addCheck "quota-tracking" $quotaOk $quotaMessage "warning"

    $statsGeneratedUtc = $null
    if ($stats.PSObject.Properties.Name -contains "generatedAtUtc") {
        $statsGeneratedUtc = Get-DateTimeOrNull ([string]$stats.generatedAtUtc)
    }
    if ($null -eq $statsGeneratedUtc -and $stats.PSObject.Properties.Name -contains "generatedAt") {
        $statsGeneratedLocal = Get-DateTimeOrNull ([string]$stats.generatedAt)
        if ($null -ne $statsGeneratedLocal) {
            $statsGeneratedUtc = $statsGeneratedLocal.ToUniversalTime()
        }
    }
    if ($null -eq $statsGeneratedUtc) {
        $statsGeneratedUtc = (Get-Date).ToUniversalTime()
    }

    $tooling = Get-HelperToolingInfo -StatsGeneratedAtUtc $statsGeneratedUtc
    $statsStale = [bool]$tooling.statsStaleAfterScriptUpdate
    $serverStale = [bool]$tooling.serverStaleAfterScriptUpdate
    $globalInstall = Get-GlobalInstallInfo
    & $addCheck "stats-freshness" (-not $statsStale) $(if (-not $statsStale) { "stats 已跟上脚本更新" } else { "stats generated $($statsGeneratedUtc.ToString('yyyy-MM-dd HH:mm:ss')) UTC, latest script $($tooling.coreScriptMaxWriteLocal)" }) "warning"
    & $addCheck "server-freshness" (-not $serverStale) $(if (-not $serverStale) { "dashboard 服务已使用当前脚本" } else { "server started $($tooling.serverStartedAtLocal), latest script $($tooling.coreScriptMaxWriteLocal)" }) "warning"
    & $addCheck "global-install" ([bool]$globalInstall.ok) $(if ([bool]$globalInstall.ok) { "全局安装已同步" } else { "$($globalInstall.message); synced $($globalInstall.syncedAtUtc)" }) "warning"

    $failed = @($checks.ToArray() | Where-Object { -not [bool]$_.ok })
    $errorFailed = @($failed | Where-Object {
        $severity = if ($_.PSObject.Properties.Name -contains "failureSeverity") { [string]$_.failureSeverity } else { [string]$_.severity }
        $severity -eq "error"
    })
    $status = if ($errorFailed.Count -gt 0) { "error" } elseif ($failed.Count -gt 0) { "warn" } else { "ok" }

    return [PSCustomObject]@{
        ok = ($status -eq "ok")
        status = $status
        generatedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        message = if ($status -eq "ok") { "dashboard health is OK" } elseif ($status -eq "warn") { "dashboard health has warnings" } else { "dashboard health has errors" }
        checks = @($checks.ToArray())
        summary = [PSCustomObject]@{
            coverageRisk = $coverageRisk
            conversations = if ($stats.PSObject.Properties.Name -contains "globalHistory") { [int]$stats.globalHistory.conversationCount } else { 0 }
            requestSeries = if ($stats.PSObject.Properties.Name -contains "globalHistory") { @($stats.globalHistory.usageDetection.requestLineSeries).Count } else { 0 }
            untrackedRequestThreads = $untracked
            joinableRequestThreads = $joinable
            outputTokens = [int]$stats.outputTokens
            budgetTokens = [int]$stats.budgetTokens
            cacheReferences = if ($stats.PSObject.Properties.Name -contains "contextCache") { [int]$stats.contextCache.stableReferenceCount } else { 0 }
            cacheSavedTokens = if ($stats.PSObject.Properties.Name -contains "contextCache") { [int]$stats.contextCache.stableReferenceSavedTokens } else { 0 }
            quotaLogResetProtected = [bool]$quotaProtected
            quotaNewRequestTokensApplied = [long]$quotaApplied
            statsGeneratedAtUtc = $statsGeneratedUtc.ToString("o")
            helperVersion = [string]$tooling.helperVersion
            coreScriptMaxWriteUtc = [string]$tooling.coreScriptMaxWriteUtc
            coreScriptMaxWritePath = [string]$tooling.coreScriptMaxWritePath
            serverStartedAtUtc = [string]$tooling.serverStartedAtUtc
            statsStaleAfterScriptUpdate = [bool]$statsStale
            serverStaleAfterScriptUpdate = [bool]$serverStale
            globalInstallOk = [bool]$globalInstall.ok
            globalInstallSyncedAtUtc = [string]$globalInstall.syncedAtUtc
            globalInstallSourceRoot = [string]$globalInstall.sourceRoot
            globalInstallBinPath = [string]$globalInstall.binPath
        }
    }
}

function Invoke-TokenKitRefresh {
    param([switch]$ReadOpenAIUsage)

    $stats = Get-CurrentStats
    $maxChars = 24000
    $conversationName = "dashboard-refresh"
    if ($null -ne $stats) {
        if ($stats.PSObject.Properties.Name -contains "maxChars" -and $stats.maxChars -gt 0) {
            $maxChars = [int]$stats.maxChars
        }
    }

    $args = @(
        "-ExecutionPolicy", "Bypass",
        "-File", $tokenKit,
        "-ProjectPath", $root,
        "-MaxChars", $maxChars,
        "-ConversationName", $conversationName,
        "-RunKind", "refresh",
        "-Quiet"
    )

    if ($ReadOpenAIUsage) {
        $args += "-ReadOpenAIUsage"
    }

    & powershell @args | Out-Null
}

$listener = [System.Net.HttpListener]::new()
$prefix = "http://127.0.0.1:$Port/"
$listener.Prefixes.Add($prefix)
$listener.Start()
Write-Host "Codex dashboard server: $prefix"

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response

        try {
            if ($request.HttpMethod -eq "GET" -and $request.Url.AbsolutePath -eq "/api/ping") {
                Send-Json -Response $response -StatusCode 200 -Body @{
                    ok = $true
                    status = "ok"
                    projectPath = $root
                    port = $Port
                    generatedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
                }
                continue
            }

            if ($request.HttpMethod -eq "GET" -and $request.Url.AbsolutePath -eq "/api/stats") {
                $json = Get-CurrentStatsJson
                if ([string]::IsNullOrWhiteSpace($json)) {
                    Send-Json -Response $response -StatusCode 404 -Body @{ ok = $false; message = "stats.json not found" }
                    continue
                }

                Send-Text -Response $response -StatusCode 200 -Text $json -ContentType "application/json; charset=utf-8"
                continue
            }

            if ($request.HttpMethod -eq "GET" -and $request.Url.AbsolutePath -eq "/api/health") {
                $health = Get-HealthSummary
                $json = $health | ConvertTo-Json -Depth 8 -Compress
                Send-Text -Response $response -StatusCode 200 -Text $json -ContentType "application/json; charset=utf-8"
                continue
            }

            if ($request.HttpMethod -eq "POST" -and $request.Url.AbsolutePath -eq "/api/refresh") {
                Invoke-TokenKitRefresh
                if ($LASTEXITCODE -ne 0) {
                    throw "刷新 stats 失败。"
                }

                $json = Get-CurrentStatsJson -Force
                Send-Text -Response $response -StatusCode 200 -Text $json -ContentType "application/json; charset=utf-8"
                continue
            }

            if ($request.HttpMethod -eq "POST" -and $request.Url.AbsolutePath -eq "/api/save-openai-admin-key") {
                $reader = [System.IO.StreamReader]::new($request.InputStream, $request.ContentEncoding)
                $bodyText = $reader.ReadToEnd()
                $payload = $bodyText | ConvertFrom-Json

                Save-AdminKey -AdminKey ([string]$payload.adminKey)

                if ($payload.PSObject.Properties.Name -contains "refresh" -and [bool]$payload.refresh) {
                    Invoke-TokenKitRefresh -ReadOpenAIUsage
                    if ($LASTEXITCODE -ne 0) {
                        throw "Key 已保存，但刷新 usage 失败。"
                    }
                    Send-Json -Response $response -StatusCode 200 -Body @{
                        ok = $true
                        message = "已加密保存，并刷新 usage。"
                    }
                }
                else {
                    Send-Json -Response $response -StatusCode 200 -Body @{
                        ok = $true
                        message = "已加密保存到本机。"
                    }
                }

                continue
            }

            if ($request.HttpMethod -eq "POST" -and $request.Url.AbsolutePath -eq "/api/save-app-quota") {
                $reader = [System.IO.StreamReader]::new($request.InputStream, $request.ContentEncoding)
                $bodyText = $reader.ReadToEnd()
                $payload = $bodyText | ConvertFrom-Json

                Save-AppQuota -Payload $payload
                Invoke-TokenKitRefresh
                if ($LASTEXITCODE -ne 0) {
                    throw "App 额度已保存，但刷新仪表盘失败。"
                }

                Send-Json -Response $response -StatusCode 200 -Body @{
                    ok = $true
                    message = "已保存 Codex App 额度。"
                }

                continue
            }

            if ($request.HttpMethod -ne "GET") {
                Send-Json -Response $response -StatusCode 405 -Body @{ ok = $false; message = "Method not allowed" }
                continue
            }

            $relative = [System.Uri]::UnescapeDataString($request.Url.AbsolutePath.TrimStart("/"))
            if ([string]::IsNullOrWhiteSpace($relative)) {
                $relative = ".codex/dashboard.html"
            }

            $relative = $relative -replace "/", [System.IO.Path]::DirectorySeparatorChar
            $fullPath = [System.IO.Path]::GetFullPath((Join-Path $root $relative))

            if (-not $fullPath.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
                Send-Json -Response $response -StatusCode 403 -Body @{ ok = $false; message = "Forbidden" }
                continue
            }

            if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
                Send-Json -Response $response -StatusCode 404 -Body @{ ok = $false; message = "Not found" }
                continue
            }

            if ([System.IO.Path]::GetFileName($fullPath).Equals("dashboard.html", [System.StringComparison]::OrdinalIgnoreCase)) {
                Send-DashboardHtml -Response $response -Path $fullPath
                continue
            }

            $bytes = [System.IO.File]::ReadAllBytes($fullPath)
            $response.StatusCode = 200
            $response.ContentType = Get-ContentType $fullPath
            $response.ContentLength64 = $bytes.Length
            $response.OutputStream.Write($bytes, 0, $bytes.Length)
            $response.OutputStream.Close()
        }
        catch {
            Send-Json -Response $response -StatusCode 500 -Body @{ ok = $false; message = $_.Exception.Message }
        }
    }
}
finally {
    $listener.Stop()
}
