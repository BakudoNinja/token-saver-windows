param(
    [string]$ProjectPath = ".",
    [int]$Port = 8790,
    [switch]$KeepServer
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = (Get-Item -LiteralPath $ProjectPath).FullName
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$tokenKit = Join-Path $scriptRoot "codex-token-kit.ps1"
$dashboardServer = Join-Path $scriptRoot "codex-dashboard-server.ps1"
$tokenAudit = Join-Path $scriptRoot "codex-token-audit.ps1"
$dashboardSmoke = Join-Path $scriptRoot "codex-dashboard-smoke.ps1"
$dashboardJsSmoke = Join-Path $scriptRoot "codex-dashboard-js-smoke.ps1"
$dashboardPerformance = Join-Path $scriptRoot "codex-dashboard-performance.ps1"
$tokenUsageRegression = Join-Path $scriptRoot "codex-token-usage-regression.ps1"
$contextRegression = Join-Path $scriptRoot "codex-context-regression.ps1"
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

function Read-JsonFile {
    param([string]$Path)
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Get-IntProperty {
    param(
        [object]$Object,
        [string]$Name
    )

    if ($null -eq $Object -or -not ($Object.PSObject.Properties.Name -contains $Name)) {
        Add-Failure "Missing integer property: $Name"
        return 0
    }

    $value = 0
    [void][int]::TryParse([string]$Object.$Name, [ref]$value)
    return $value
}

function Get-FreePort {
    param([int]$PreferredPort)

    foreach ($candidate in @($PreferredPort) + (8800..8899)) {
        $tcpListener = $null
        $httpListener = $null
        try {
            $tcpListener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Parse("127.0.0.1"), $candidate)
            $tcpListener.Start()
            $tcpListener.Stop()
            $tcpListener = $null

            $httpListener = [System.Net.HttpListener]::new()
            $httpListener.Prefixes.Add("http://127.0.0.1:$candidate/")
            $httpListener.Start()
            return $candidate
        }
        catch {
        }
        finally {
            if ($null -ne $httpListener) {
                $httpListener.Close()
            }
            if ($null -ne $tcpListener) {
                $tcpListener.Stop()
            }
        }
    }

    throw "No free local port found for health check."
}

function Get-DashboardPortFromCommandLine {
    param([string]$CommandLine)

    $match = [regex]::Match([string]$CommandLine, "(?i)(?:^|\s)-Port\s+(\d+)")
    if ($match.Success) {
        return [int]$match.Groups[1].Value
    }
    return -1
}

function Get-ProjectDashboardServerProcesses {
    $fullRoot = [System.IO.Path]::GetFullPath($root)
    return @(
        Get-CimInstance Win32_Process -Filter "name = 'powershell.exe'" |
            Where-Object {
                $_.ProcessId -ne $PID -and
                $_.CommandLine -like "*codex-dashboard-server.ps1*" -and
                $_.CommandLine -like "*$fullRoot*"
            }
    )
}

function Get-CanonicalDashboardPort {
    $urlPath = Join-Path $root ".codex\dashboard-url.txt"
    if (-not (Test-Path -LiteralPath $urlPath -PathType Leaf)) {
        return -1
    }

    try {
        $text = (Get-Content -LiteralPath $urlPath -Raw).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) {
            return -1
        }
        return ([Uri]$text).Port
    }
    catch {
        return -1
    }
}

function Invoke-LocalJsonWithRetry {
    param(
        [string]$Uri,
        [string]$Label,
        [int]$Retries = 8,
        [int]$DelayMs = 500,
        [int]$TimeoutSeconds = 20
    )

    $lastError = $null
    for ($i = 0; $i -lt $Retries; $i++) {
        try {
            return Invoke-RestMethod -Uri $Uri -TimeoutSec $TimeoutSeconds
        }
        catch {
            $lastError = $_
            Start-Sleep -Milliseconds ($DelayMs * ($i + 1))
        }
    }

    throw "$Label did not become reachable: $($lastError.Exception.Message)"
}

function Invoke-LocalPageWithRetry {
    param(
        [string]$Uri,
        [string]$Label,
        [int]$Retries = 8,
        [int]$DelayMs = 500,
        [int]$TimeoutSeconds = 10
    )

    $lastError = $null
    for ($i = 0; $i -lt $Retries; $i++) {
        try {
            return Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec $TimeoutSeconds
        }
        catch {
            $lastError = $_
            Start-Sleep -Milliseconds ($DelayMs * ($i + 1))
        }
    }

    throw "$Label did not become reachable: $($lastError.Exception.Message)"
}

$canonicalDashboardPortAtStart = Get-CanonicalDashboardPort
$canonicalDashboardProcessIdsAtStart = @(
    if ($canonicalDashboardPortAtStart -gt 0) {
        Get-ProjectDashboardServerProcesses | Where-Object {
            (Get-DashboardPortFromCommandLine -CommandLine ([string]$_.CommandLine)) -eq $canonicalDashboardPortAtStart
        } | ForEach-Object { [int]$_.ProcessId }
    }
)

function Remove-NonCanonicalDashboardServers {
    $canonicalPort = Get-CanonicalDashboardPort
    if ($canonicalPort -le 0) {
        return 0
    }

    try {
        $canonicalPing = Invoke-RestMethod -Uri "http://127.0.0.1:$canonicalPort/api/ping" -TimeoutSec 2
        if ($null -eq $canonicalPing -or [string]$canonicalPing.status -ne "ok" -or [string]$canonicalPing.projectPath -ne $root) {
            return 0
        }
    }
    catch {
        return 0
    }

    $removed = 0
    foreach ($process in @(Get-ProjectDashboardServerProcesses)) {
        if ($canonicalDashboardProcessIdsAtStart -contains [int]$process.ProcessId) {
            continue
        }
        $processPort = Get-DashboardPortFromCommandLine -CommandLine ([string]$process.CommandLine)
        if ($processPort -gt 0 -and $processPort -ne $canonicalPort) {
            $shouldStop = $false
            try {
                $ping = Invoke-RestMethod -Uri "http://127.0.0.1:$processPort/api/ping" -TimeoutSec 2
                $health = Invoke-RestMethod -Uri "http://127.0.0.1:$processPort/api/health" -TimeoutSec 4
                if ($null -eq $ping -or [string]$ping.status -ne "ok" -or [string]$ping.projectPath -ne $root) {
                    $shouldStop = $true
                }
                elseif (($health.PSObject.Properties.Name -contains "summary") -and
                    ($health.summary.PSObject.Properties.Name -contains "serverStaleAfterScriptUpdate") -and
                    [bool]$health.summary.serverStaleAfterScriptUpdate) {
                    $shouldStop = $true
                }
            }
            catch {
                $shouldStop = $true
            }

            if ($shouldStop) {
                Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
                $removed++
            }
        }
    }
    return $removed
}

$beforeHistoryPath = Join-Path $env:USERPROFILE ".codex\codex-token-helper-history.jsonl"
$beforeActual = 0
$beforeRefresh = 0
$beforeHealthActual = 0
$beforeDashboardRefreshActual = 0
if (Test-Path -LiteralPath $beforeHistoryPath) {
    foreach ($line in (Get-Content -LiteralPath $beforeHistoryPath)) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        try {
            $entry = $line | ConvertFrom-Json
            if (-not ($entry.PSObject.Properties.Name -contains "runKind") -or $entry.runKind -eq "actual") {
                $beforeActual++
                if (($entry.PSObject.Properties.Name -contains "conversationName") -and [string]$entry.conversationName -eq "health-check") {
                    $beforeHealthActual++
                }
                if (($entry.PSObject.Properties.Name -contains "conversationName") -and [string]$entry.conversationName -eq "dashboard-refresh") {
                    $beforeDashboardRefreshActual++
                }
            }
            elseif ($entry.runKind -eq "refresh") {
                $beforeRefresh++
            }
        }
        catch {
        }
    }
}

$removedNonCanonicalServers = Remove-NonCanonicalDashboardServers

$tokenKitOutput = & powershell -ExecutionPolicy Bypass -File $tokenKit -ProjectPath $root -MaxChars 12000 -ConversationName "health-check" -RunKind refresh -Quiet 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "codex-token-kit.ps1 failed."
}
$tokenKitText = (($tokenKitOutput | Out-String).Trim())
Assert-True ($tokenKitText -match "全局 context 减少") "codex-token-kit.ps1 output must label global context savings explicitly."
Assert-True ($tokenKitText -match "全对话有效性") "codex-token-kit.ps1 output must include all-conversation effectiveness."
Assert-True (-not ($tokenKitText -match "(?m)^全局减少:")) "codex-token-kit.ps1 output must not use the ambiguous legacy '全局减少' label."

$statsPath = Join-Path $root ".codex\stats.json"
$dashboardPath = Join-Path $root ".codex\dashboard.html"
$contextPath = Join-Path $root ".codex\context.md"
$globalBin = Join-Path $env:USERPROFILE ".codex\bin"
$globalInstallManifest = Join-Path $globalBin "codex-helper-install.json"
$runningFromGlobalBin = ([System.IO.Path]::GetFullPath($scriptRoot) -eq [System.IO.Path]::GetFullPath($globalBin))
$requiredBinScripts = @(
    "codex-token-kit.ps1",
    "codex-slim.ps1",
    "codex-dashboard.ps1",
    "codex-dashboard-server.ps1",
    "codex-dashboard-smoke.ps1",
    "codex-dashboard-js-smoke.ps1",
    "codex-dashboard-performance.ps1",
    "codex-token-audit.ps1",
    "codex-token-usage-regression.ps1",
    "codex-helper-health.ps1",
    "codex-save-openai-admin-key.ps1",
    "codex-sync-global-bin.ps1"
)

Assert-True (Test-Path -LiteralPath $statsPath) "stats.json was not generated."
Assert-True (Test-Path -LiteralPath $dashboardPath) "dashboard.html was not generated."
Assert-True (Test-Path -LiteralPath $contextPath) "context.md was not generated."
Assert-True ((Get-Item -LiteralPath $statsPath).Length -lt 2000000) "stats.json is too large; compact JSON may have regressed."
Assert-True ((Get-Item -LiteralPath $dashboardPath).Length -lt 2000000) "dashboard.html is too large; embedded stats JSON may have regressed."
Assert-True (Test-Path -LiteralPath $globalBin -PathType Container) "global helper bin directory is missing."
Assert-True (Test-Path -LiteralPath $globalInstallManifest -PathType Leaf) "global helper install manifest is missing; run codex-sync-global-bin.ps1."
$installManifest = $null
if (Test-Path -LiteralPath $globalInstallManifest -PathType Leaf) {
    try {
        $installManifest = Read-JsonFile $globalInstallManifest
        Assert-True ([bool]$installManifest.ok) "global helper install manifest is not ok."
        if ($runningFromGlobalBin) {
            Assert-True (Test-Path -LiteralPath ([string]$installManifest.sourceRoot) -PathType Container) "global helper install manifest sourceRoot does not exist."
        }
        else {
            Assert-True ([string]$installManifest.sourceRoot -eq [System.IO.Path]::GetFullPath($scriptRoot)) "global helper install manifest sourceRoot does not match this helper checkout; run codex-sync-global-bin.ps1."
        }
        Assert-True ([string]$installManifest.binPath -eq [System.IO.Path]::GetFullPath($globalBin)) "global helper install manifest binPath is incorrect."
        Assert-True ([int]$installManifest.scriptCount -ge $requiredBinScripts.Count) "global helper install manifest scriptCount is too low."
    }
    catch {
        Add-Failure "global helper install manifest cannot be read: $($_.Exception.Message)"
    }
}
foreach ($scriptName in $requiredBinScripts) {
    $localScript = if ($runningFromGlobalBin -and $null -ne $installManifest -and (Test-Path -LiteralPath ([string]$installManifest.sourceRoot) -PathType Container)) {
        Join-Path ([string]$installManifest.sourceRoot) $scriptName
    }
    else {
        Join-Path $scriptRoot $scriptName
    }
    $binScript = Join-Path $globalBin $scriptName
    Assert-True (Test-Path -LiteralPath $binScript -PathType Leaf) "global bin is missing $scriptName."
    if ((Test-Path -LiteralPath $localScript -PathType Leaf) -and (Test-Path -LiteralPath $binScript -PathType Leaf)) {
        $localHash = (Get-FileHash -LiteralPath $localScript -Algorithm SHA256).Hash
        $binHash = (Get-FileHash -LiteralPath $binScript -Algorithm SHA256).Hash
        Assert-True ($localHash -eq $binHash) "global bin $scriptName is out of sync with the current helper scripts."
        if ($null -ne $installManifest -and ($installManifest.PSObject.Properties.Name -contains "scripts")) {
            $manifestItem = @($installManifest.scripts | Where-Object { [string]$_.name -eq $scriptName } | Select-Object -First 1)
            Assert-True ($manifestItem.Count -gt 0) "global helper install manifest is missing $scriptName."
            if ($manifestItem.Count -gt 0) {
                Assert-True ([string]$manifestItem[0].sha256 -eq $binHash) "global helper install manifest hash is stale for $scriptName."
            }
        }
    }
}

$stats = Read-JsonFile $statsPath
Assert-True ($stats.PSObject.Properties.Name -contains "globalHistory") "stats.globalHistory is missing."
Assert-True ($stats.PSObject.Properties.Name -contains "audit") "stats.audit is missing."
Assert-True ($stats.globalHistory.PSObject.Properties.Name -contains "usageDetection") "stats.globalHistory.usageDetection is missing."
Assert-True ($stats.globalHistory.usageDetection.PSObject.Properties.Name -contains "trend") "usageDetection.trend is missing."
Assert-True ($stats.globalHistory.usageDetection.PSObject.Properties.Name -contains "autoJoinDiagnostics") "usageDetection.autoJoinDiagnostics is missing."
Assert-True ($stats.globalHistory.usageDetection.PSObject.Properties.Name -contains "savedLineSeries") "usageDetection.savedLineSeries is missing."
Assert-True ($stats.globalHistory.usageDetection.PSObject.Properties.Name -contains "historicalRequestProjectCount") "usageDetection.historicalRequestProjectCount is missing."
Assert-True ($stats.globalHistory.usageDetection.PSObject.Properties.Name -contains "postHelperRequestProjectCount") "usageDetection.postHelperRequestProjectCount is missing."
Assert-True ($stats.globalHistory.PSObject.Properties.Name -contains "dedupedRunCount") "stats.globalHistory.dedupedRunCount is missing."
Assert-True ($stats.globalHistory.PSObject.Properties.Name -contains "effectiveRunCount") "stats.globalHistory.effectiveRunCount is missing."
Assert-True ($stats.PSObject.Properties.Name -contains "outputCapped") "stats.outputCapped is missing."
Assert-True ($stats.PSObject.Properties.Name -contains "coverageAudit") "stats.coverageAudit is missing."
Assert-True ($stats.PSObject.Properties.Name -contains "contextCache") "stats.contextCache is missing."
Assert-True ($stats.PSObject.Properties.Name -contains "tooling") "stats.tooling is missing."
Assert-True ($stats.PSObject.Properties.Name -contains "generatedAtUtc") "stats.generatedAtUtc is missing."
Assert-True ($stats.coverageAudit.PSObject.Properties.Name -contains "risk") "coverageAudit.risk is missing."
Assert-True ($stats.contextCache.PSObject.Properties.Name -contains "stableReferenceCount") "contextCache.stableReferenceCount is missing."
Assert-True ($stats.contextCache.PSObject.Properties.Name -contains "stableReferenceSavedTokens") "contextCache.stableReferenceSavedTokens is missing."
Assert-True ($stats.tooling.PSObject.Properties.Name -contains "helperVersion") "tooling.helperVersion is missing."
Assert-True ($stats.tooling.PSObject.Properties.Name -contains "coreScriptMaxWriteUtc") "tooling.coreScriptMaxWriteUtc is missing."
Assert-True ($stats.tooling.PSObject.Properties.Name -contains "statsStaleAfterScriptUpdate") "tooling.statsStaleAfterScriptUpdate is missing."
Assert-True ($stats.globalHistory.usageDetection.PSObject.Properties.Name -contains "capMessage") "usageDetection.capMessage is missing."
Assert-True ($stats.outputTokens -gt 0) "stats.outputTokens should be positive."
Assert-True ($stats.originalTokens -ge 0) "stats.originalTokens should be non-negative."
Assert-True ($stats.candidateFileCount -le $stats.scannedFileCount) "candidateFileCount cannot exceed scannedFileCount."
Assert-True ($stats.globalHistory.baselineSavedTokens -ge 0) "baselineSavedTokens should be non-negative."
Assert-True ($stats.contextCache.stableReferenceCount -ge 0) "stableReferenceCount should be non-negative."
Assert-True ($stats.contextCache.stableReferenceSavedTokens -ge 0) "stableReferenceSavedTokens should be non-negative."
    Assert-True ($stats.globalHistory.usageDetection.autoJoinDiagnostics.PSObject.Properties.Name -contains "joinableThreadCount") "autoJoinDiagnostics.joinableThreadCount is missing."
    Assert-True ($stats.globalHistory.usageDetection.autoJoinDiagnostics.PSObject.Properties.Name -contains "missingPathThreadCount") "autoJoinDiagnostics.missingPathThreadCount is missing."
    Assert-True ($stats.globalHistory.usageDetection.autoJoinDiagnostics.PSObject.Properties.Name -contains "noPathThreadCount") "autoJoinDiagnostics.noPathThreadCount is missing."

$contextText = Get-Content -LiteralPath $contextPath -Raw
Assert-True (-not [string]::IsNullOrWhiteSpace($contextText)) "context.md must not be empty."
Assert-True ($contextText.Contains("## 使用提示")) "context.md is missing usage guidance."
Assert-True ($contextText.Contains("## Git 状态")) "context.md is missing git status."
Assert-True ($contextText.Contains("## 文件地图")) "context.md is missing file map."
Assert-True ($contextText.Contains("## 关键文件摘录")) "context.md is missing key file excerpts."
Assert-True ([string]$stats.coverageAudit.risk -ne "high") "coverage risk is high; token reduction may be hurting task performance."

$changedCount = Get-IntProperty -Object $stats.coverageAudit -Name "changedFileCount"
$changedIncluded = Get-IntProperty -Object $stats.coverageAudit -Name "changedFilesIncludedCount"
$essentialCount = Get-IntProperty -Object $stats.coverageAudit -Name "essentialFileCount"
$essentialIncluded = Get-IntProperty -Object $stats.coverageAudit -Name "essentialFilesIncludedCount"
$recentCount = Get-IntProperty -Object $stats.coverageAudit -Name "recentFileCount"
$recentIncluded = Get-IntProperty -Object $stats.coverageAudit -Name "recentFilesIncludedCount"

Assert-True ($changedIncluded -eq $changedCount) "all changed files must be selected for context. Included=$changedIncluded Total=$changedCount"
if ($essentialCount -gt 0) {
    Assert-True ($essentialIncluded -ge [Math]::Min($essentialCount, 3)) "entry/config coverage is too low. Included=$essentialIncluded Total=$essentialCount"
}
if ($recentCount -gt 0) {
    Assert-True ($recentIncluded -gt 0) "recent active files should not be completely omitted."
}
if ($stats.candidateFileCount -gt 0) {
    Assert-True ($stats.excerptedFileCount -gt 0) "candidate files exist but no excerpts were written."
}
Assert-True ($stats.outputTokens -le ($stats.budgetTokens + 16)) "outputTokens should stay close to budgetTokens. Output=$($stats.outputTokens) Budget=$($stats.budgetTokens)"

$Port = Get-FreePort -PreferredPort $Port

$server = Start-Process -WindowStyle Hidden -PassThru -FilePath powershell -ArgumentList @(
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    $dashboardServer,
    "-ProjectPath",
    $root,
    "-Port",
    $Port
)

try {
    $statsUrl = "http://127.0.0.1:$Port/api/stats"
    $healthUrl = "http://127.0.0.1:$Port/api/health"
    $refreshUrl = "http://127.0.0.1:$Port/api/refresh"
    $pageUrl = "http://127.0.0.1:$Port/.codex/dashboard.html"

    $apiStats = Invoke-LocalJsonWithRetry -Uri $statsUrl -Label "api/stats" -TimeoutSeconds 60
    $apiHealth = Invoke-LocalJsonWithRetry -Uri $healthUrl -Label "api/health" -TimeoutSeconds 20
    Assert-True ($apiHealth.PSObject.Properties.Name -contains "status") "api/health did not return status."
    Assert-True ($apiHealth.PSObject.Properties.Name -contains "checks") "api/health did not return checks."
    Assert-True ($apiHealth.PSObject.Properties.Name -contains "summary") "api/health did not return summary."
    Assert-True ([string]$apiHealth.status -ne "error") "api/health returned error status."
    Assert-True (@($apiHealth.checks).Count -ge 6) "api/health returned too few checks."
    Assert-True ($apiHealth.summary.PSObject.Properties.Name -contains "helperVersion") "api/health summary is missing helperVersion."
    Assert-True ($apiHealth.summary.PSObject.Properties.Name -contains "statsStaleAfterScriptUpdate") "api/health summary is missing statsStaleAfterScriptUpdate."
    Assert-True ($apiHealth.summary.PSObject.Properties.Name -contains "serverStaleAfterScriptUpdate") "api/health summary is missing serverStaleAfterScriptUpdate."
    Assert-True ($apiHealth.summary.PSObject.Properties.Name -contains "globalInstallOk") "api/health summary is missing globalInstallOk."
    Assert-True ($apiHealth.summary.PSObject.Properties.Name -contains "globalInstallSyncedAtUtc") "api/health summary is missing globalInstallSyncedAtUtc."
    Assert-True ([bool]$apiHealth.summary.globalInstallOk) "api/health reports global install is not synced."
    Assert-True ($apiStats.globalHistory.runCount -ge 1) "api/stats did not return global actual run count."
    Assert-True ($apiStats.globalHistory.PSObject.Properties.Name -contains "usageDetection") "api/stats did not return usageDetection."
    Assert-True ($apiStats.globalHistory.usageDetection.PSObject.Properties.Name -contains "projectUsage") "api/stats usageDetection.projectUsage is missing."
    Assert-True ($apiStats.globalHistory.usageDetection.PSObject.Properties.Name -contains "sessionTokenLineSeries") "api/stats usageDetection.sessionTokenLineSeries is missing."
    Assert-True ($apiStats.globalHistory.usageDetection.PSObject.Properties.Name -contains "savedLineSeries") "api/stats usageDetection.savedLineSeries is missing."
    Assert-True ($apiStats.globalHistory.usageDetection.PSObject.Properties.Name -contains "historicalRequestProjectCount") "api/stats usageDetection.historicalRequestProjectCount is missing."
    Assert-True ($apiStats.globalHistory.usageDetection.PSObject.Properties.Name -contains "postHelperRequestProjectCount") "api/stats usageDetection.postHelperRequestProjectCount is missing."
    Assert-True ($apiStats.globalHistory.usageDetection.PSObject.Properties.Name -contains "helperReviewProjectCount") "api/stats usageDetection.helperReviewProjectCount is missing."
    Assert-True ($apiStats.globalHistory.usageDetection.PSObject.Properties.Name -contains "helperReviewProjects") "api/stats usageDetection.helperReviewProjects is missing."
    Assert-True ($apiStats.globalHistory.usageDetection.autoJoinDiagnostics.PSObject.Properties.Name -contains "lastAutoRefreshStale") "api/stats autoJoinDiagnostics.lastAutoRefreshStale is missing."
    $activityAwareConversations = @($apiStats.globalHistory.conversations | Where-Object {
        ($_.PSObject.Properties.Name -contains "latestThreadActivityRun") -and
        ($_.PSObject.Properties.Name -contains "latestRequestRun") -and
        ($_.PSObject.Properties.Name -contains "threadActiveAfterRequest")
    })
    Assert-True ($activityAwareConversations.Count -gt 0) "api/stats conversations must expose thread activity separately from completed usage records."
    Assert-True ($apiStats.globalHistory.PSObject.Properties.Name -contains "dedupedRunCount") "api/stats did not return dedupedRunCount."
    Assert-True ($apiStats.PSObject.Properties.Name -contains "appQuota") "api/stats did not return appQuota."
    Assert-True ($apiStats.PSObject.Properties.Name -contains "tooling") "api/stats did not return tooling."
    Assert-True ($apiStats.appQuota.PSObject.Properties.Name -contains "estimatedWeeklyUsedPercent") "api/stats appQuota estimate is missing."
    if ([bool]$apiStats.appQuota.configured) {
        Assert-True ($apiStats.appQuota.PSObject.Properties.Name -contains "quotaLogResetProtected") "api/stats appQuota is missing quotaLogResetProtected."
        Assert-True ($apiStats.appQuota.PSObject.Properties.Name -contains "quotaIncrementalRequestTokens") "api/stats appQuota is missing quotaIncrementalRequestTokens."
    }

    $auditJson = $null
    $auditExitCode = 1
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $auditJson = & powershell -NoProfile -ExecutionPolicy Bypass -File $tokenAudit -ProjectPath $root -StatsUrl $statsUrl 2>&1
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
        Add-Failure "codex-token-audit.ps1 failed for api/stats. Exit=$auditExitCode Output=$auditText"
    }
    else {
        $audit = $auditJson | ConvertFrom-Json
        Assert-True ([bool]$audit.ok) "codex-token-audit.ps1 returned ok=false."
        Assert-True ($audit.PSObject.Properties.Name -contains "rawCodexRequestTokens") "token audit is missing rawCodexRequestTokens."
        Assert-True ($audit.PSObject.Properties.Name -contains "helperEstimatedAvoidedContextTokens") "token audit is missing helperEstimatedAvoidedContextTokens."
    }

    if (Test-Path -LiteralPath $tokenUsageRegression) {
        $usageRegressionJson = & powershell -NoProfile -ExecutionPolicy Bypass -File $tokenUsageRegression -StatsUrl $statsUrl
        if ($LASTEXITCODE -ne 0) {
            Add-Failure "codex-token-usage-regression.ps1 failed."
        }
        else {
            $usageRegression = $usageRegressionJson | ConvertFrom-Json
            Assert-True ([bool]$usageRegression.ok) "codex-token-usage-regression.ps1 returned ok=false."
        }
    }
    else {
        Add-Failure "codex-token-usage-regression.ps1 is missing."
    }

    if (Test-Path -LiteralPath $dashboardPerformance) {
        $performanceJson = & powershell -NoProfile -ExecutionPolicy Bypass -File $dashboardPerformance -DashboardUrl $pageUrl 2>&1
        if ($LASTEXITCODE -ne 0) {
            $performanceText = (($performanceJson | Out-String).Trim())
            if ($performanceText.Length -gt 700) {
                $performanceText = $performanceText.Substring(0, 700)
            }
            Add-Failure "codex-dashboard-performance.ps1 failed. Output=$performanceText"
        }
        else {
            $performance = $performanceJson | ConvertFrom-Json
            Assert-True ([bool]$performance.ok) "codex-dashboard-performance.ps1 returned ok=false."
            Assert-True ([double]$performance.warmStatsSteadySeconds -le [double]$performance.limits.maxWarmStatsSeconds) "warm api/stats steady latency exceeded limit."
            Assert-True ([double]$performance.warmPageSteadySeconds -le [double]$performance.limits.maxWarmPageSeconds) "warm dashboard page steady latency exceeded limit."
        }
    }
    else {
        Add-Failure "codex-dashboard-performance.ps1 is missing."
    }

    $page = Invoke-LocalPageWithRetry -Uri $pageUrl -Label "dashboard page" -TimeoutSeconds 10
    Assert-True ($page.Content.Contains("setInterval(pollStats")) "dashboard is missing realtime polling."
    Assert-True ($page.Content.Contains("/api/stats")) "dashboard is missing stats API polling."
    Assert-True ($page.Content.Contains("/api/health")) "dashboard is missing health API polling."
    Assert-True ($page.Content.Contains("Usage 监控")) "dashboard is missing usage monitor section."
    Assert-True ($page.Content.Contains("缓存复用")) "dashboard is missing context cache reuse metric."
    Assert-True ($page.Content.Contains("可接入")) "dashboard is missing auto-join diagnostics copy."
    Assert-True ($page.Content.Contains("节约有效性")) "dashboard is missing token saving effectiveness section."
    Assert-True ($page.Content.Contains("数据审计")) "dashboard is missing data audit section."
    Assert-True ($page.Content.Contains("context 避免")) "dashboard must label context savings clearly."
    Assert-True ($page.Content.Contains("helper 后实际")) "dashboard must label helper-after actual usage in project rows."
    Assert-True ($page.Content.Contains("旧请求审计")) "dashboard must expose old pre-helper request audit separately."
    Assert-True ($page.Content.Contains("command-center")) "dashboard is missing command center."
    Assert-True ($page.Content.Contains("state-badge")) "dashboard is missing status badges."
    Assert-True ($page.Content.Contains("usageLineChart")) "dashboard is missing usage line chart."
    Assert-True ($page.Content.Contains("usageLineLegend")) "dashboard is missing usage line legend."
    Assert-True ($page.Content.Contains("savedLineChart")) "dashboard is missing helper savings line chart."
    Assert-True ($page.Content.Contains("savedLineLegend")) "dashboard is missing helper savings line legend."
    Assert-True ($page.Content.Contains("Token 使用率")) "dashboard chart must label the task-manager-style usage metric."
    Assert-True ($page.Content.Contains("Helper 节省")) "dashboard chart must label the helper savings metric."
    Assert-True ($page.Content.Contains("helper 前历史请求已排除")) "dashboard must explain pre-helper request history is excluded from post-helper actual tokens."
    Assert-True ($page.Content.Contains("completed usage")) "dashboard chart must explain sparse completed usage windows."
    Assert-True ($page.Content.Contains("原本全对话估算")) "dashboard must show original all-conversation token estimates."
    Assert-True ($page.Content.Contains("使用 helper 后实际")) "dashboard must show actual post-helper request tokens."
    Assert-True ($page.Content.Contains("真实模型请求 token")) "dashboard must distinguish request logs from context estimates."
    Assert-True ($page.Content.Contains("线程仍活跃")) "dashboard must show active threads even when completed usage is older."
    Assert-True ($page.Content.Contains("本地 Python worker 的持续运行不计入")) "dashboard must clarify local workers do not consume Codex tokens by themselves."
    Assert-True ($page.Content.Contains("helper可能过旧")) "dashboard must expose projects whose helper usage may be stale."
    Assert-True (-not $page.Content.Contains("持续运行请求")) "dashboard must not label request-log volume as continuous local execution."
    Assert-True ($page.Content.Contains("打满上限")) "dashboard must expose capped context status."
    Assert-True ($page.Content.Contains("性能保护")) "dashboard must expose coverage risk protection."

    $beforeApiRefresh = $apiStats.globalHistory.refreshRunCount
    $refreshed = Invoke-RestMethod -Method Post -Uri $refreshUrl -TimeoutSec 90
    Assert-True ($refreshed.globalHistory.refreshRunCount -ge ($beforeApiRefresh + 1)) "api/refresh did not increase refresh count."
    Assert-True ($refreshed.globalHistory.PSObject.Properties.Name -contains "usageDetection") "api/refresh dropped usageDetection."
    Assert-True ($refreshed.appQuota.PSObject.Properties.Name -contains "estimatedShortUsedPercent") "api/refresh dropped appQuota estimates."
}
finally {
    if (-not $KeepServer -and $null -ne $server -and -not ($canonicalDashboardProcessIdsAtStart -contains [int]$server.Id)) {
        Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
    }
}

$afterActual = 0
$afterRefresh = 0
$afterHealthActual = 0
$afterDashboardRefreshActual = 0
if (Test-Path -LiteralPath $beforeHistoryPath) {
    foreach ($line in (Get-Content -LiteralPath $beforeHistoryPath)) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        try {
            $entry = $line | ConvertFrom-Json
            if (-not ($entry.PSObject.Properties.Name -contains "runKind") -or $entry.runKind -eq "actual") {
                $afterActual++
                if (($entry.PSObject.Properties.Name -contains "conversationName") -and [string]$entry.conversationName -eq "health-check") {
                    $afterHealthActual++
                }
                if (($entry.PSObject.Properties.Name -contains "conversationName") -and [string]$entry.conversationName -eq "dashboard-refresh") {
                    $afterDashboardRefreshActual++
                }
            }
            elseif ($entry.runKind -eq "refresh") {
                $afterRefresh++
            }
        }
        catch {
        }
    }
}

Assert-True ($afterHealthActual -eq $beforeHealthActual) "health check must not add health-check actual records."
Assert-True ($afterDashboardRefreshActual -eq $beforeDashboardRefreshActual) "api/refresh must not add dashboard-refresh actual records."
Assert-True ($afterRefresh -ge ($beforeRefresh + 1)) "health refresh should add at least one refresh record."

if (Test-Path -LiteralPath $dashboardSmoke) {
    $smokeJson = & powershell -NoProfile -ExecutionPolicy Bypass -File $dashboardSmoke -ProjectPath $root -Port $Port -Samples 3 -SampleDelayMs 500
    if ($LASTEXITCODE -ne 0) {
        Add-Failure "codex-dashboard-smoke.ps1 failed."
    }
    else {
        $smoke = $smokeJson | ConvertFrom-Json
        Assert-True ([bool]$smoke.ok) "codex-dashboard-smoke.ps1 returned ok=false."
    }
}
else {
    Add-Failure "codex-dashboard-smoke.ps1 is missing."
}

if (Test-Path -LiteralPath $dashboardJsSmoke) {
    $jsSmokeJson = & powershell -NoProfile -ExecutionPolicy Bypass -File $dashboardJsSmoke -DashboardPath $dashboardPath -StatsPath $statsPath
    if ($LASTEXITCODE -ne 0) {
        Add-Failure "codex-dashboard-js-smoke.ps1 failed."
    }
    else {
        $jsSmoke = $jsSmokeJson | ConvertFrom-Json
        Assert-True ([bool]$jsSmoke.ok) "codex-dashboard-js-smoke.ps1 returned ok=false."
    }
}
else {
    Add-Failure "codex-dashboard-js-smoke.ps1 is missing."
}

if (Test-Path -LiteralPath $contextRegression) {
    $regressionJson = & powershell -NoProfile -ExecutionPolicy Bypass -File $contextRegression
    if ($LASTEXITCODE -ne 0) {
        Add-Failure "codex-context-regression.ps1 failed."
    }
    else {
        $regression = $regressionJson | ConvertFrom-Json
        Assert-True ([bool]$regression.ok) "codex-context-regression.ps1 returned ok=false."
        Assert-True ([int]$regression.cacheReferences -gt 0) "context regression did not exercise stable cache references."
    }
}
else {
    Add-Failure "codex-context-regression.ps1 is missing."
}

$canonicalPort = Get-CanonicalDashboardPort
if ($canonicalPort -gt 0) {
    $staleNonCanonicalServers = @(
        Get-ProjectDashboardServerProcesses | Where-Object {
            $port = Get-DashboardPortFromCommandLine -CommandLine ([string]$_.CommandLine)
            if ($port -le 0 -or $port -eq $canonicalPort) {
                return $false
            }
            try {
                $ping = Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/ping" -TimeoutSec 2
                $health = Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/health" -TimeoutSec 4
                if ($null -eq $ping -or [string]$ping.status -ne "ok" -or [string]$ping.projectPath -ne $root) {
                    return $true
                }
                return (($health.PSObject.Properties.Name -contains "summary") -and
                    ($health.summary.PSObject.Properties.Name -contains "serverStaleAfterScriptUpdate") -and
                    [bool]$health.summary.serverStaleAfterScriptUpdate)
            }
            catch {
                return $true
            }
        }
    )
    Assert-True ($staleNonCanonicalServers.Count -eq 0) "stale or unreachable non-canonical dashboard servers should be cleaned up. CanonicalPort=$canonicalPort Extra=$($staleNonCanonicalServers.Count) CleanedAtStart=$removedNonCanonicalServers"
}

if ($failures.Count -gt 0) {
    Write-Host "Codex helper health check failed:"
    foreach ($failure in $failures) {
        Write-Host "- $failure"
    }
    exit 1
}

Write-Host "Codex helper health check passed."
Write-Host "Project: $root"
Write-Host "Stats: $statsPath"
Write-Host "Dashboard: $dashboardPath"
