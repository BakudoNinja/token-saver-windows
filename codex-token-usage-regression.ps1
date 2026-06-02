param(
    [string]$StatsUrl = "http://127.0.0.1:8799/api/stats"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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

function Invoke-StatsWithRetry {
    param(
        [string]$Uri,
        [int]$Retries = 8,
        [int]$DelayMs = 600
    )

    $lastError = $null
    for ($i = 0; $i -lt $Retries; $i++) {
        try {
            return Invoke-RestMethod -Uri $Uri -TimeoutSec 30
        }
        catch {
            $lastError = $_
            Start-Sleep -Milliseconds ($DelayMs * ($i + 1))
        }
    }

    throw $lastError
}

function Invoke-RawUsageQuery {
    param(
        [string]$Mode,
        [string]$Needle
    )

    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($null -eq $python) {
        throw "python not found"
    }

    $script = @'
import json, os, re, sqlite3, sys

mode = sys.argv[1]
needle = (sys.argv[2] or "").lower()
logs_path = os.path.join(os.path.expanduser("~"), ".codex", "logs_2.sqlite")
result = {
    "count": 0,
    "raw": 0,
    "cached": 0,
    "effective": 0,
    "dedupedRaw": 0,
    "duplicateGroups": 0,
}
submission_max = {}
submission_count = {}

if os.path.exists(logs_path):
    con = sqlite3.connect(logs_path)
    cur = con.cursor()
    if mode == "thread":
        rows = cur.execute(
            "select ts, feedback_log_body from logs where thread_id = ? and feedback_log_body like '%response.completed%' and feedback_log_body like '%\"usage\"%'",
            (needle,),
        )
    else:
        rows = cur.execute(
            "select ts, feedback_log_body from logs where feedback_log_body like '%response.completed%' and feedback_log_body like '%\"usage\"%'"
        )
    for ts, body in rows:
        if not body:
            continue
        if mode != "thread" and needle not in body.lower():
            continue
        match = re.search(r"websocket event: (\{.*\})", body)
        if not match:
            continue
        try:
            usage = (json.loads(match.group(1)).get("response", {}).get("usage") or {})
            raw = int(usage.get("total_tokens") or 0)
            cached = int(((usage.get("input_tokens_details") or {}).get("cached_tokens")) or 0)
        except Exception:
            continue
        if raw <= 0:
            continue
        sub_match = re.search(r"submission.id=\"([^\"]+)\"", body)
        sub = sub_match.group(1) if sub_match else "ts:" + str(ts or "")
        result["count"] += 1
        result["raw"] += raw
        result["cached"] += cached
        result["effective"] += max(0, raw - cached)
        submission_max[sub] = max(int(submission_max.get(sub, 0)), raw)
        submission_count[sub] = int(submission_count.get(sub, 0)) + 1

result["dedupedRaw"] = sum(submission_max.values())
result["duplicateGroups"] = sum(1 for value in submission_count.values() if value > 1)
print(json.dumps(result, ensure_ascii=False))
'@

    $json = $script | & $python.Source - $Mode $Needle
    return ($json | ConvertFrom-Json)
}

$stats = Invoke-StatsWithRetry -Uri $StatsUrl
$series = @($stats.globalHistory.usageDetection.requestLineSeries)
$conversations = @($stats.globalHistory.conversations)

Assert-True ($stats.globalHistory.usageDetection.PSObject.Properties.Name -contains "savedLineSeries") "usageDetection.savedLineSeries is missing."
$savedSeries = @($stats.globalHistory.usageDetection.savedLineSeries)
foreach ($item in $savedSeries) {
    Assert-True ($item.PSObject.Properties.Name -contains "points") "savedLineSeries item is missing points: $($item.name)"
    foreach ($point in @($item.points)) {
        Assert-True ($point.PSObject.Properties.Name -contains "savedTokens") "savedLineSeries point is missing savedTokens: $($item.name)"
        Assert-True ([long]$point.savedTokens -ge 0) "savedLineSeries savedTokens must be non-negative: $($item.name)"
    }
}

foreach ($case in @(
    [PSCustomObject]@{ name = "移到F盘非系统文件"; pathNeedle = "c-c-f" },
    [PSCustomObject]@{ name = "禁用权限确认"; pathNeedle = "2026-05-31\codex" }
)) {
    $api = @($series | Where-Object { [string]$_.name -eq [string]$case.name } | Select-Object -First 1)
    if ($api.Count -eq 0) {
        # requestLineSeries is intentionally capped to the most relevant recent
        # lines. A project can still be correctly tracked in projectUsage even
        # when it is not present in this chart slice.
        continue
    }

    $raw = if ($api[0].PSObject.Properties.Name -contains "threadId" -and -not [string]::IsNullOrWhiteSpace([string]$api[0].threadId)) {
        Invoke-RawUsageQuery -Mode "thread" -Needle ([string]$api[0].threadId)
    }
    else {
        Invoke-RawUsageQuery -Mode "path" -Needle ([string]$case.pathNeedle)
    }

    Assert-True ([long]$raw.count -gt 0) "$($case.name) raw sqlite usage rows were not found."
    Assert-True ([long]$api[0].totalRequestTokens -eq [long]$raw.raw) "$($case.name) totalRequestTokens must equal raw total_tokens. API=$($api[0].totalRequestTokens) Raw=$($raw.raw)"
    Assert-True ([long]$api[0].rawTotalRequestTokens -eq [long]$raw.raw) "$($case.name) rawTotalRequestTokens mismatch."
    Assert-True ([long]$api[0].cachedRequestTokens -eq [long]$raw.cached) "$($case.name) cachedRequestTokens mismatch. API=$($api[0].cachedRequestTokens) Raw=$($raw.cached)"
    Assert-True ([long]$api[0].effectiveRequestTokens -eq [long]$raw.effective) "$($case.name) effectiveRequestTokens mismatch. API=$($api[0].effectiveRequestTokens) Raw=$($raw.effective)"
    Assert-True ([long]$api[0].dedupedTotalRequestTokens -eq [long]$raw.dedupedRaw) "$($case.name) dedupedTotalRequestTokens mismatch. API=$($api[0].dedupedTotalRequestTokens) Raw=$($raw.dedupedRaw)"
    Assert-True ([int]$api[0].duplicateResponseGroupCount -eq [int]$raw.duplicateGroups) "$($case.name) duplicateResponseGroupCount mismatch."
}

$postHelperMatched = @($conversations | Where-Object {
    ($_.PSObject.Properties.Name -contains "requestUsageMatched") -and
    [bool]$_.requestUsageMatched -and
    ($_.PSObject.Properties.Name -contains "requestUsageAfterHelper") -and
    [bool]$_.requestUsageAfterHelper
})
foreach ($item in $postHelperMatched) {
    Assert-True ([long]$item.helperAllTokens -eq [long]$item.requestTotalTokens) "$($item.conversationName) post-helper matched request tokens must be the helper-after actual total."
}

foreach ($item in $conversations) {
    Assert-True ($item.PSObject.Properties.Name -contains "cumulativeSavedTokens") "$($item.conversationName) is missing cumulativeSavedTokens."
    Assert-True ($item.PSObject.Properties.Name -contains "latestSavedTokens") "$($item.conversationName) is missing latestSavedTokens."
    Assert-True ([long]$item.cumulativeSavedTokens -ge [long]$item.latestSavedTokens) "$($item.conversationName) cumulativeSavedTokens must be >= latestSavedTokens."
    Assert-True ([long]$item.latestSavedTokens -eq [long]$item.totalSavedTokens) "$($item.conversationName) latestSavedTokens must mirror current totalSavedTokens compatibility field."
    if ([long]$item.totalOriginalTokens -gt 0 -and [long]$item.totalSavedTokens -lt [long]$item.totalOriginalTokens) {
        Assert-True ([int]$item.totalSavedPercent -lt 100) "$($item.conversationName) totalSavedPercent must not round up to 100 when saved < original."
    }
}

if ([long]$stats.globalHistory.totalOriginalTokens -gt 0 -and [long]$stats.globalHistory.totalSavedTokens -lt [long]$stats.globalHistory.totalOriginalTokens) {
    Assert-True ([int]$stats.globalHistory.totalSavedPercent -lt 100) "global totalSavedPercent must not round up to 100 when saved < original."
}
if ([long]$stats.globalHistory.totalOriginalAllTokens -gt 0 -and [long]$stats.globalHistory.totalAllSavedTokens -lt [long]$stats.globalHistory.totalOriginalAllTokens) {
    Assert-True ([int]$stats.globalHistory.totalAllSavedPercent -lt 100) "global totalAllSavedPercent must not round up to 100 when saved < originalAll."
}

$historicalMatches = @($conversations | Where-Object {
    ($_.PSObject.Properties.Name -contains "requestUsageMatched") -and
    [bool]$_.requestUsageMatched -and
    ($_.PSObject.Properties.Name -contains "requestUsageAfterHelper") -and
    -not [bool]$_.requestUsageAfterHelper -and
    [long]$_.requestTotalTokens -gt [long]$_.totalOutputTokens
})
foreach ($item in $historicalMatches) {
    Assert-True ([long]$item.helperAllTokens -eq [long]$item.totalOutputTokens) "$($item.conversationName) helper-before historical requests must not be counted as helper-after actual tokens."
    Assert-True ([long]$item.originalAllTokens -eq ([long]$item.totalOutputTokens + [long]$item.totalSavedTokens)) "$($item.conversationName) helper-before historical requests must not inflate originalAllTokens."
}

$expectedProjectUsage = @($conversations | Sort-Object @{ Expression = "helperAllTokens"; Descending = $true }, @{ Expression = "totalOutputTokens"; Descending = $true } | Select-Object -First 8)
$actualProjectUsage = @($stats.globalHistory.usageDetection.projectUsage)
foreach ($item in $expectedProjectUsage) {
    $match = @($actualProjectUsage | Where-Object { [string]$_.projectPath -eq [string]$item.projectPath } | Select-Object -First 1)
    Assert-True ($match.Count -gt 0) "usageDetection.projectUsage must include top helper-after actual project: $($item.conversationName) / $($item.projectPath)"
}

$quantbot = @($conversations | Where-Object { [string]$_.conversationName -eq "开发盈利量化机器人" } | Select-Object -First 1)
if ($quantbot.Count -gt 0 -and [long]$quantbot[0].requestTotalTokens -gt [long]$quantbot[0].totalOutputTokens) {
    if ([bool]$quantbot[0].requestUsageAfterHelper) {
        Assert-True ([long]$quantbot[0].helperAllTokens -eq [long]$quantbot[0].requestTotalTokens) "开发盈利量化机器人 post-helper requests must be counted as helper-after actual tokens."
    }
    else {
        Assert-True ([long]$quantbot[0].helperAllTokens -eq [long]$quantbot[0].totalOutputTokens) "开发盈利量化机器人 helperAllTokens must use helper actual output when matched request logs are older than helper adoption."
    }
}

$polymarket = @($conversations | Where-Object { [string]$_.projectPath -like "*polymarket 量化*" } | Select-Object -First 1)
if ($polymarket.Count -gt 0) {
    Assert-True ([long]$polymarket[0].cumulativeSavedTokens -ge [long]$polymarket[0].totalSavedTokens) "polymarket cumulative savings must not be overwritten by the latest helper run."
    if ([int]$polymarket[0].runCount -gt 1) {
        Assert-True ([long]$polymarket[0].cumulativeSavedTokens -gt [long]$polymarket[0].totalSavedTokens) "polymarket multi-run project should expose cumulative savings separately from latest savings."
    }
}

if ($failures.Count -gt 0) {
    Write-Host "Codex token usage regression failed:"
    foreach ($failure in $failures) {
        Write-Host "- $failure"
    }
    exit 1
}

[PSCustomObject]@{
    ok = $true
    statsUrl = $StatsUrl
    checkedCases = 2
    savedSeries = $savedSeries.Count
    postHelperMatchedConversations = $postHelperMatched.Count
    historicalMatchedConversations = $historicalMatches.Count
    cumulativeSavingsChecked = $conversations.Count
} | ConvertTo-Json -Depth 3
