param(
    [string]$ProjectPath = ".",
    [int]$Port = 8890,
    [int]$Samples = 5,
    [int]$SampleDelayMs = 1000,
    [switch]$KeepServer
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = (Get-Item -LiteralPath $ProjectPath).FullName
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$launcher = Join-Path $scriptRoot "codex-dashboard.ps1"
$serverScript = [System.IO.Path]::GetFullPath((Join-Path $scriptRoot "codex-dashboard-server.ps1"))
$auditScript = Join-Path $scriptRoot "codex-token-audit.ps1"
$failures = New-Object System.Collections.Generic.List[string]
$dashboardUrlPath = Join-Path $root ".codex\dashboard-url.txt"
$previousDashboardUrl = ""
$hadPreviousDashboardUrl = Test-Path -LiteralPath $dashboardUrlPath -PathType Leaf
if ($hadPreviousDashboardUrl) {
    $previousDashboardUrl = Get-Content -LiteralPath $dashboardUrlPath -Raw
}

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

function Get-Number {
    param(
        [object]$Object,
        [string]$Name
    )

    if ($null -eq $Object -or -not ($Object.PSObject.Properties.Name -contains $Name)) {
        Add-Failure "Missing numeric property: $Name"
        return 0.0
    }

    $value = 0.0
    [void][double]::TryParse([string]$Object.$Name, [ref]$value)
    return $value
}

function Get-ProjectDashboardServers {
    param([int]$TargetPort = $Port)

    $fullRoot = [System.IO.Path]::GetFullPath($root)
    return @(
        Get-CimInstance Win32_Process -Filter "name = 'powershell.exe'" |
            Where-Object {
                $_.CommandLine -like "*codex-dashboard-server.ps1*" -and
                $_.CommandLine -like "*$serverScript*" -and
                $_.CommandLine -like "*$fullRoot*" -and
                $_.CommandLine -like "*-Port $TargetPort*"
            }
    )
}

function Test-Percent {
    param(
        [double]$Value,
        [string]$Name
    )

    Assert-True ($Value -ge 0 -and $Value -le 100) "$Name must be between 0 and 100. Actual=$Value"
}

function Invoke-RestMethodWithRetry {
    param(
        [string]$Uri,
        [int]$Retries = 5,
        [int]$DelayMs = 700
    )

    $lastError = $null
    for ($i = 0; $i -lt $Retries; $i++) {
        try {
            return Invoke-RestMethod -Uri $Uri -TimeoutSec 20
        }
        catch {
            $lastError = $_
            Start-Sleep -Milliseconds $DelayMs
        }
    }

    throw $lastError
}

$beforeServerIds = @((Get-ProjectDashboardServers) | ForEach-Object { [int]$_.ProcessId })
$launchOutput = & $launcher -ProjectPath $root -Port $Port -NoOpen

$url = (($launchOutput | Where-Object { [string]$_ -match "^http://127\.0\.0\.1:\d+/" } | Select-Object -Last 1) -as [string]).Trim()
if ([string]::IsNullOrWhiteSpace($url)) {
    throw "codex-dashboard.ps1 did not print a dashboard URL."
}
$actualPort = ([Uri]$url).Port

try {
    Start-Sleep -Milliseconds 500
    $servers = @(Get-ProjectDashboardServers -TargetPort $actualPort)
    $newServers = @($servers | Where-Object { $beforeServerIds -notcontains [int]$_.ProcessId })
    Assert-True ($newServers.Count -le 1) "Expected at most one new dashboard server for this project/port. Actual=$($newServers.Count)"
    Assert-True (($newServers.Count -eq 1) -or ($servers.Count -ge 1)) "Expected a reusable or newly-started dashboard server for this project/port."

    $statsUrl = ($url -replace "/\.codex/dashboard\.html$", "/api/stats")
    $healthUrl = ($url -replace "/\.codex/dashboard\.html$", "/api/health")
    $pingUrl = ($url -replace "/\.codex/dashboard\.html$", "/api/ping")
    $ping = Invoke-RestMethodWithRetry -Uri $pingUrl -Retries 8 -DelayMs 500
    Assert-True ($ping.PSObject.Properties.Name -contains "status") "api/ping is missing status."
    Assert-True ([string]$ping.status -eq "ok") "api/ping did not return ok status."
    Assert-True ([string]$ping.projectPath -eq $root) "api/ping projectPath does not match the smoke project."

    $page = $null
    $lastPageError = $null
    for ($attempt = 1; $attempt -le 8; $attempt++) {
        try {
            $page = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 15
            break
        }
        catch {
            $lastPageError = $_
            Start-Sleep -Milliseconds (500 * $attempt)
        }
    }
    if ($null -eq $page) {
        $errLog = Join-Path (Join-Path $root ".codex") "dashboard-server-$actualPort.err.log"
        $outLog = Join-Path (Join-Path $root ".codex") "dashboard-server-$actualPort.out.log"
        $errTail = if (Test-Path -LiteralPath $errLog) { ((Get-Content -LiteralPath $errLog -Tail 8 -ErrorAction SilentlyContinue) -join " ") } else { "" }
        $outTail = if (Test-Path -LiteralPath $outLog) { ((Get-Content -LiteralPath $outLog -Tail 8 -ErrorAction SilentlyContinue) -join " ") } else { "" }
        Add-Failure "dashboard page did not become reachable. Url=$url LastError=$($lastPageError.Exception.Message) Out=$outTail Err=$errTail"
        $page = [PSCustomObject]@{ StatusCode = 0; Content = "" }
    }
    Assert-True ($page.StatusCode -eq 200) "dashboard page did not return HTTP 200."
    Assert-True ($page.Content.Length -lt 2000000) "dashboard page is too large; embedded stats JSON may have regressed."
    $health = Invoke-RestMethodWithRetry -Uri $healthUrl
    Assert-True ($health.PSObject.Properties.Name -contains "status") "api/health is missing status."
    Assert-True ($health.PSObject.Properties.Name -contains "checks") "api/health is missing checks."
    Assert-True ($health.PSObject.Properties.Name -contains "summary") "api/health is missing summary."
    Assert-True ([string]$health.status -ne "error") "api/health returned error status."
    Assert-True (@($health.checks).Count -ge 6) "api/health returned too few checks."
    foreach ($check in @($health.checks)) {
        Assert-True ($check.PSObject.Properties.Name -contains "failureSeverity") "api/health check is missing failureSeverity: $($check.name)"
        if ([bool]$check.ok) {
            Assert-True ([string]$check.severity -eq "ok") "passing api/health check must use severity=ok, not warning/error: $($check.name)"
            Assert-True (-not ([string]$check.message -match "^(output|untracked|audit warnings|stats generated|server started) ")) "passing api/health check message should be a clear OK explanation: $($check.name) => $($check.message)"
        }
    }
    $budgetHealth = @($health.checks | Where-Object { [string]$_.name -eq "budget" } | Select-Object -First 1)
    Assert-True ($budgetHealth.Count -eq 1) "api/health must include budget check."
    if ($budgetHealth.Count -eq 1 -and [bool]$budgetHealth[0].ok) {
        Assert-True ([string]$budgetHealth[0].message -match "预算容差") "passing budget health message must explain budget tolerance."
    }
        Assert-True ($health.summary.PSObject.Properties.Name -contains "helperVersion") "api/health summary is missing helperVersion."
        Assert-True ($health.summary.PSObject.Properties.Name -contains "statsStaleAfterScriptUpdate") "api/health summary is missing statsStaleAfterScriptUpdate."
        Assert-True ($health.summary.PSObject.Properties.Name -contains "serverStaleAfterScriptUpdate") "api/health summary is missing serverStaleAfterScriptUpdate."
        Assert-True ($health.summary.PSObject.Properties.Name -contains "globalInstallOk") "api/health summary is missing globalInstallOk."
        Assert-True ($health.summary.PSObject.Properties.Name -contains "globalInstallSyncedAtUtc") "api/health summary is missing globalInstallSyncedAtUtc."
    $embeddedStats = $null
    $statsDataMatch = [regex]::Match($page.Content, '<script type="application/json" id="stats-data">([\s\S]*?)</script>')
    Assert-True ($statsDataMatch.Success) "dashboard page is missing embedded stats-data JSON."
    if ($statsDataMatch.Success) {
        $embeddedStatsJson = $statsDataMatch.Groups[1].Value
        Assert-True (-not $embeddedStatsJson.Contains("&quot;")) "embedded stats-data JSON must not be HTML-entity encoded."
        Assert-True (-not $embeddedStatsJson.Contains("&amp;")) "embedded stats-data JSON must not contain HTML ampersand entities."
        try {
            $embeddedStats = $embeddedStatsJson | ConvertFrom-Json
            Assert-True ($embeddedStats.PSObject.Properties.Name -contains "globalHistory") "embedded stats-data is missing globalHistory."
            Assert-True ($embeddedStats.PSObject.Properties.Name -contains "appQuota") "embedded stats-data is missing appQuota."
            Assert-True ($embeddedStats.PSObject.Properties.Name -contains "tooling") "embedded stats-data is missing tooling."
        }
        catch {
            Add-Failure "embedded stats-data JSON cannot be parsed directly: $($_.Exception.Message)"
        }
    }

    foreach ($needle in @(
        "短周期估算剩余率",
        "周额度估算剩余率",
        "套餐百分比按截图锚点换算",
        "周容量估算",
        "context 避免",
        "/api/health",
        "缓存复用",
        "可接入",
        "数据审计",
        "command-center",
        "quotaBasisBadge",
        "state-badge",
        "项目消耗和异常",
        "helper 后实际",
        "请求/Helper",
        "旧请求审计",
        "Codex日志多",
        "线程仍活跃",
        "本地 Python worker 的持续运行不计入",
        "模型对话消耗主导",
        "主要消耗来自后续模型对话",
        "无可压缩上下文",
        "helper可能过旧",
        "usageProjectRows",
        "usageIssueRows",
        "usageLineChart",
        "usageLineLegend",
        "savedLineChart",
        "savedLineLegend",
        "最近 60 分钟 token 使用率面积图",
        "最近 60 分钟 helper 节省 token 面积图",
        "Helper 节省",
        "helper 前历史请求已排除",
        "completed usage",
        "session token_count",
        "主图 session token_count",
        "主图 completed usage",
        "主图 helper actual",
        "真实请求 token",
        "真实请求线覆盖 helper 线",
        "同提交多响应",
        "原本全对话估算",
        "使用 helper 后实际",
        "实际减少",
        "减少率",
        "真实模型请求 token"
    )) {
        Assert-True ($page.Content.Contains($needle)) "dashboard page is missing expected text or DOM marker: $needle"
    }

    $previousQuotaTokens = -1.0
    $previousWeeklyRemaining = 101.0
    $previousHelperAll = -1.0
    $previousOriginalAll = -1.0
    $lastStats = $null
    for ($i = 0; $i -lt $Samples; $i++) {
        $stats = Invoke-RestMethodWithRetry -Uri $statsUrl
        $lastStats = $stats
        Assert-True ($stats.PSObject.Properties.Name -contains "globalHistory") "api/stats is missing globalHistory."
        Assert-True ($stats.PSObject.Properties.Name -contains "appQuota") "api/stats is missing appQuota."
        Assert-True ($stats.PSObject.Properties.Name -contains "contextCache") "api/stats is missing contextCache."
        Assert-True ($stats.PSObject.Properties.Name -contains "tooling") "api/stats is missing tooling."
        Assert-True ($stats.tooling.PSObject.Properties.Name -contains "helperVersion") "api/stats tooling is missing helperVersion."
        Assert-True ($stats.tooling.PSObject.Properties.Name -contains "coreScriptMaxWriteUtc") "api/stats tooling is missing coreScriptMaxWriteUtc."
        if ($stats.appQuota -and [bool]$stats.appQuota.configured) {
            Assert-True ($stats.appQuota.PSObject.Properties.Name -contains "quotaLogResetProtected") "appQuota is missing quotaLogResetProtected."
            Assert-True ($stats.appQuota.PSObject.Properties.Name -contains "quotaIncrementalRequestTokens") "appQuota is missing quotaIncrementalRequestTokens."
        }
        Assert-True ($stats.globalHistory.PSObject.Properties.Name -contains "usageDetection") "globalHistory is missing usageDetection."
        Assert-True ($stats.globalHistory.usageDetection.PSObject.Properties.Name -contains "untrackedRequestThreadCount") "usageDetection is missing untrackedRequestThreadCount."
        Assert-True ($stats.globalHistory.usageDetection.PSObject.Properties.Name -contains "autoJoinDiagnostics") "usageDetection is missing autoJoinDiagnostics."
        Assert-True ($stats.globalHistory.usageDetection.PSObject.Properties.Name -contains "sessionTokenLineSeries") "usageDetection is missing sessionTokenLineSeries."
        Assert-True ($stats.globalHistory.usageDetection.PSObject.Properties.Name -contains "savedLineSeries") "usageDetection is missing savedLineSeries."
        Assert-True ($stats.globalHistory.usageDetection.PSObject.Properties.Name -contains "historicalRequestProjectCount") "usageDetection is missing historicalRequestProjectCount."
        Assert-True ($stats.globalHistory.usageDetection.PSObject.Properties.Name -contains "postHelperRequestProjectCount") "usageDetection is missing postHelperRequestProjectCount."
        Assert-True ($stats.globalHistory.usageDetection.PSObject.Properties.Name -contains "helperReviewProjectCount") "usageDetection is missing helperReviewProjectCount."
        Assert-True ($stats.globalHistory.usageDetection.PSObject.Properties.Name -contains "helperReviewProjects") "usageDetection is missing helperReviewProjects."
        Assert-True ($stats.globalHistory.usageDetection.autoJoinDiagnostics.PSObject.Properties.Name -contains "joinableThreadCount") "autoJoinDiagnostics is missing joinableThreadCount."
        Assert-True ($stats.globalHistory.usageDetection.autoJoinDiagnostics.PSObject.Properties.Name -contains "lastAutoRefreshStale") "autoJoinDiagnostics is missing lastAutoRefreshStale."
        Assert-True ($stats.contextCache.PSObject.Properties.Name -contains "stableReferenceCount") "contextCache is missing stableReferenceCount."
        $requestSeriesWithCache = @($stats.globalHistory.usageDetection.requestLineSeries | Where-Object {
            ($_.PSObject.Properties.Name -contains "rawTotalRequestTokens") -and
            ($_.PSObject.Properties.Name -contains "cachedRequestTokens") -and
            ($_.PSObject.Properties.Name -contains "effectiveRequestTokens") -and
            ($_.PSObject.Properties.Name -contains "dedupedTotalRequestTokens") -and
            ($_.PSObject.Properties.Name -contains "duplicateResponseGroupCount") -and
            ($_.PSObject.Properties.Name -contains "threadId") -and
            [long]$_.rawTotalRequestTokens -eq [long]$_.totalRequestTokens -and
            [long]$_.effectiveRequestTokens -eq ([long]$_.totalRequestTokens - [long]$_.cachedRequestTokens)
        })
        Assert-True ($requestSeriesWithCache.Count -gt 0) "requestLineSeries must expose actual total_tokens with cached/effective/deduped split fields."
        $sessionSeries = @($stats.globalHistory.usageDetection.sessionTokenLineSeries | Where-Object {
            ($_.PSObject.Properties.Name -contains "points") -and @($_.points).Count -gt 0
        })
        Assert-True ($sessionSeries.Count -gt 0) "sessionTokenLineSeries must expose token_count points for ongoing conversations."
        $activityAwareConversations = @($stats.globalHistory.conversations | Where-Object {
            ($_.PSObject.Properties.Name -contains "latestThreadActivityRun") -and
            ($_.PSObject.Properties.Name -contains "latestRequestRun") -and
            ($_.PSObject.Properties.Name -contains "threadActiveAfterRequest")
        })
        Assert-True ($activityAwareConversations.Count -gt 0) "conversations must expose thread activity separately from completed usage records."
        $historicalMatches = @($stats.globalHistory.usageDetection.projectUsage | Where-Object {
            ($_.PSObject.Properties.Name -contains "requestUsageMatched") -and
            [bool]$_.requestUsageMatched -and
            ($_.PSObject.Properties.Name -contains "requestUsageAfterHelper") -and
            -not [bool]$_.requestUsageAfterHelper -and
            [long]$_.requestTotalTokens -gt [long]$_.totalOutputTokens
        })
        foreach ($item in $historicalMatches) {
            Assert-True ([long]$item.helperAllTokens -eq [long]$item.totalOutputTokens) "$($item.conversationName) historical request audit must not inflate helper-after actual tokens."
        }
        $expectedProjectUsage = @($stats.globalHistory.conversations | Sort-Object @{ Expression = "helperAllTokens"; Descending = $true }, @{ Expression = "totalOutputTokens"; Descending = $true } | Select-Object -First 8)
        $actualProjectUsage = @($stats.globalHistory.usageDetection.projectUsage)
        foreach ($item in $expectedProjectUsage) {
            $match = @($actualProjectUsage | Where-Object { [string]$_.projectPath -eq [string]$item.projectPath } | Select-Object -First 1)
            Assert-True ($match.Count -gt 0) "projectUsage must include top helper-after actual project: $($item.conversationName)"
        }

        $currentQuotaTokens = Get-Number -Object $stats.appQuota -Name "currentGlobalRequestTokens"
        $weeklyRemaining = Get-Number -Object $stats.appQuota -Name "estimatedWeeklyUsedPercent"
        $shortRemaining = Get-Number -Object $stats.appQuota -Name "estimatedShortUsedPercent"
        $weeklyTotal = Get-Number -Object $stats.appQuota -Name "weeklyTotalEstimateTokens"

        Test-Percent -Value $weeklyRemaining -Name "weekly remaining percent"
        Test-Percent -Value $shortRemaining -Name "short remaining percent"
        Assert-True ($weeklyTotal -gt 0) "weeklyTotalEstimateTokens must be positive."

        if ($previousQuotaTokens -ge 0) {
            Assert-True ($currentQuotaTokens -ge $previousQuotaTokens) "currentGlobalRequestTokens must not decrease between polls. Previous=$previousQuotaTokens Current=$currentQuotaTokens"
            Assert-True ($weeklyRemaining -le ($previousWeeklyRemaining + 0.05)) "weekly remaining percent must not bounce upward during polling. Previous=$previousWeeklyRemaining Current=$weeklyRemaining"
        }

        $helperAll = Get-Number -Object $stats.globalHistory -Name "totalHelperAllTokens"
        $originalAll = Get-Number -Object $stats.globalHistory -Name "totalOriginalAllTokens"
        if ($previousHelperAll -ge 0) {
            Assert-True ($helperAll -ge $previousHelperAll) "totalHelperAllTokens must not decrease between polls. Previous=$previousHelperAll Current=$helperAll"
            Assert-True ($originalAll -ge $previousOriginalAll) "totalOriginalAllTokens must not decrease between polls. Previous=$previousOriginalAll Current=$originalAll"
        }

        $previousQuotaTokens = $currentQuotaTokens
        $previousWeeklyRemaining = $weeklyRemaining
        $previousHelperAll = $helperAll
        $previousOriginalAll = $originalAll
        Start-Sleep -Milliseconds $SampleDelayMs
    }

    if ($null -ne $lastStats) {
        $gh = $lastStats.globalHistory
        $totalOriginalAll = [long](Get-Number -Object $gh -Name "totalOriginalAllTokens")
        $totalHelperAll = [long](Get-Number -Object $gh -Name "totalHelperAllTokens")
        $totalAllSaved = [long](Get-Number -Object $gh -Name "totalAllSavedTokens")
        $effectiveRunCount = [int](Get-Number -Object $gh -Name "effectiveRunCount")
        $dedupedRunCount = [int](Get-Number -Object $gh -Name "dedupedRunCount")
        $conversations = @($gh.conversations)

        Assert-True ($totalAllSaved -eq [Math]::Max(0L, ($totalOriginalAll - $totalHelperAll))) "totalAllSavedTokens must equal max(0, originalAll - helperAll)."
        if ($totalOriginalAll -gt 0) {
            $savedPercent = [Math]::Round(($totalAllSaved / $totalOriginalAll) * 100)
            Assert-True ($savedPercent -ge 0 -and $savedPercent -le 100) "effectiveness saved percent must be based on originalAll and stay within 0..100. Actual=$savedPercent"
        }
        Assert-True ($effectiveRunCount -eq $conversations.Count) "effectiveRunCount must equal conversations.Count."
        Assert-True ($dedupedRunCount -ge 0) "dedupedRunCount must be non-negative."

        if ($lastStats.appQuota.PSObject.Properties.Name -contains "quotaEstimateBasis") {
            Assert-True ([string]$lastStats.appQuota.quotaEstimateBasis -like "real_request_tokens*") "quotaEstimateBasis should be based on real request tokens."
        }

        if ($null -ne $embeddedStats) {
            Assert-True ([int]$embeddedStats.globalHistory.conversationCount -eq [int]$lastStats.globalHistory.conversationCount) "embedded stats-data conversationCount must match api/stats."
            $embeddedWeekly = [double]$embeddedStats.appQuota.estimatedWeeklyUsedPercent
            $latestWeekly = [double]$lastStats.appQuota.estimatedWeeklyUsedPercent
            Assert-True ([Math]::Abs($embeddedWeekly - $latestWeekly) -le 1.0) "embedded stats-data weekly quota drift is too large at first load. Embedded=$embeddedWeekly Latest=$latestWeekly"
        }
    }

    $auditJson = $null
    $auditExitCode = 1
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $auditJson = & powershell -NoProfile -ExecutionPolicy Bypass -File $auditScript -ProjectPath $root -StatsUrl $statsUrl 2>&1
        $auditExitCode = $LASTEXITCODE
        if ($auditExitCode -eq 0) {
            break
        }
        Start-Sleep -Milliseconds (400 * $attempt)
    }
    if ($auditExitCode -ne 0) {
        $auditText = (($auditJson | Out-String).Trim())
        if ($auditText.Length -gt 500) {
            $auditText = $auditText.Substring(0, 500)
        }
        Add-Failure "codex-token-audit.ps1 failed for smoke stats URL. Exit=$auditExitCode Output=$auditText"
    }
    else {
        $audit = $auditJson | ConvertFrom-Json
        Assert-True ([bool]$audit.ok) "codex-token-audit.ps1 returned ok=false."
    }
}
finally {
    if (-not $KeepServer) {
        foreach ($server in @(Get-ProjectDashboardServers -TargetPort $actualPort | Where-Object { $beforeServerIds -notcontains [int]$_.ProcessId })) {
            Stop-Process -Id $server.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
    if ($hadPreviousDashboardUrl) {
        Set-Content -LiteralPath $dashboardUrlPath -Value $previousDashboardUrl -Encoding UTF8
    }
    elseif (Test-Path -LiteralPath $dashboardUrlPath -PathType Leaf) {
        Remove-Item -LiteralPath $dashboardUrlPath -Force -ErrorAction SilentlyContinue
    }
}

if ($failures.Count -gt 0) {
    Write-Host "Codex dashboard smoke check failed:"
    foreach ($failure in $failures) {
        Write-Host "- $failure"
    }
    exit 1
}

[PSCustomObject]@{
    ok = $true
    dashboardUrl = $url
    samples = $Samples
    projectPath = $root
} | ConvertTo-Json -Depth 4
