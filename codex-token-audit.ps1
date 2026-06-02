param(
    [string]$ProjectPath = ".",
    [string]$StatsUrl = "",
    [int]$ToleranceTokens = 8,
    [int]$DynamicLogToleranceTokens = 250000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = (Get-Item -LiteralPath $ProjectPath).FullName
$statsPath = Join-Path $root ".codex\stats.json"
$historyPath = Join-Path $env:USERPROFILE ".codex\codex-token-helper-history.jsonl"
$failures = New-Object System.Collections.Generic.List[string]

function Add-Failure {
    param([string]$Message)
    [void]$failures.Add($Message)
}

function Assert-EqualLong {
    param(
        [long]$Actual,
        [long]$Expected,
        [string]$Message
    )

    if ([Math]::Abs($Actual - $Expected) -gt $ToleranceTokens) {
        Add-Failure "$Message Actual=$Actual Expected=$Expected"
    }
}

function Get-LongProperty {
    param(
        [object]$Object,
        [string]$Name
    )

    if ($null -eq $Object -or -not ($Object.PSObject.Properties.Name -contains $Name)) {
        Add-Failure "Missing numeric property: $Name"
        return 0L
    }

    $value = 0L
    [void][long]::TryParse([string]$Object.$Name, [ref]$value)
    return $value
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

function Get-RawCodexRequestAudit {
    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($null -eq $python) {
        return [PSCustomObject]@{
            ok = $false
            message = "python not found"
            totalTokens = 0L
            requestCount = 0
            threads = @()
        }
    }

    $script = @'
import json, os, re, sqlite3

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

threads = {}
total_tokens = 0
request_count = 0
if os.path.exists(logs_path):
    con = sqlite3.connect(logs_path)
    cur = con.cursor()
    query = "select thread_id, feedback_log_body from logs where feedback_log_body like '%response.completed%' and feedback_log_body like '%\"usage\"%'"
    for thread_id, body in cur.execute(query):
        if not thread_id or not body:
            continue
        match = re.search(r"websocket event: (\{.*\})", body)
        if not match:
            continue
        try:
            data = (json.loads(match.group(1)).get("response", {}).get("usage") or {})
        except Exception:
            continue
        total = int(data.get("total_tokens") or 0)
        if total <= 0:
            continue
        cwd_match = re.search(r"cwd=([^}]+)\}:try_run_sampling_request", body)
        cwd = cwd_match.group(1) if cwd_match else ""
        item = threads.setdefault(thread_id, {
            "threadId": thread_id,
            "conversationName": titles.get(thread_id, thread_id),
            "cwd": cwd,
            "requestCount": 0,
            "inputTokens": 0,
            "outputTokens": 0,
            "totalTokens": 0,
        })
        item["requestCount"] += 1
        item["inputTokens"] += int(data.get("input_tokens") or 0)
        item["outputTokens"] += int(data.get("output_tokens") or 0)
        item["totalTokens"] += total
        total_tokens += total
        request_count += 1

print(json.dumps({
    "ok": True,
    "message": "ok",
    "totalTokens": total_tokens,
    "requestCount": request_count,
    "threads": list(threads.values()),
}, ensure_ascii=False))
'@

    try {
        $json = $script | & $python.Source -
        return ($json | ConvertFrom-Json)
    }
    catch {
        return [PSCustomObject]@{
            ok = $false
            message = $_.Exception.Message
            totalTokens = 0L
            requestCount = 0
            threads = @()
        }
    }
}

function Get-HistoryAudit {
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

    $actual = @(Get-DedupedActualEntries -Items @($entries.ToArray() | Where-Object { Test-EntryKind -Entry $_ -Kind "actual" }))
    $latestOutput = 0L
    $latestSaved = 0L
    $latestOriginal = 0L
    foreach ($group in @($actual | Group-Object -Property projectPath)) {
        $latest = $null
        $lastRun = ""
        foreach ($entry in @($group.Group)) {
            if ([string]$entry.generatedAt -gt $lastRun) {
                $lastRun = [string]$entry.generatedAt
                $latest = $entry
            }
        }
        if ($null -ne $latest) {
            $latestOutput += [long]$latest.outputTokens
            $latestSaved += [long]$latest.savedTokens
            $latestOriginal += [long]$latest.originalTokens
        }
    }

    return [PSCustomObject]@{
        actualRunCount = $actual.Count
        latestProjectOriginalTokens = $latestOriginal
        latestProjectOutputTokens = $latestOutput
        latestProjectSavedTokens = $latestSaved
    }
}

if (-not [string]::IsNullOrWhiteSpace($StatsUrl)) {
    $stats = Invoke-RestMethod -Uri $StatsUrl -TimeoutSec 30
}
else {
    if (-not (Test-Path -LiteralPath $statsPath)) {
        throw "stats.json not found: $statsPath"
    }
    $stats = Get-Content -LiteralPath $statsPath -Raw | ConvertFrom-Json
}

$rawRequests = Get-RawCodexRequestAudit
$history = Get-HistoryAudit

$gh = $stats.globalHistory
$ghTotalOutput = Get-LongProperty -Object $gh -Name "totalOutputTokens"
$ghTotalSaved = Get-LongProperty -Object $gh -Name "totalSavedTokens"
$ghTotalOriginal = Get-LongProperty -Object $gh -Name "totalOriginalTokens"
$ghTotalOriginalAll = Get-LongProperty -Object $gh -Name "totalOriginalAllTokens"
$ghTotalHelperAll = Get-LongProperty -Object $gh -Name "totalHelperAllTokens"
$ghTotalAllSaved = Get-LongProperty -Object $gh -Name "totalAllSavedTokens"

Assert-EqualLong -Actual $ghTotalOutput -Expected ([long]$history.latestProjectOutputTokens) -Message "globalHistory.totalOutputTokens must equal latest-per-project helper output tokens."
Assert-EqualLong -Actual $ghTotalSaved -Expected ([long]$history.latestProjectSavedTokens) -Message "globalHistory.totalSavedTokens must equal latest-per-project helper saved tokens."
Assert-EqualLong -Actual $ghTotalOriginal -Expected ([long]$history.latestProjectOriginalTokens) -Message "globalHistory.totalOriginalTokens must equal latest-per-project helper original tokens."

$computedSaved = [Math]::Max(0L, ($ghTotalOriginalAll - $ghTotalHelperAll))
Assert-EqualLong -Actual $ghTotalAllSaved -Expected ([long]$computedSaved) -Message "totalAllSavedTokens must equal originalAll minus helperAll."

$matchedRequestTotal = 0L
$matchedRequestCount = 0
$postHelperMatchedRequestTotal = 0L
$postHelperMatchedRequestCount = 0
foreach ($item in @($stats.globalHistory.conversations)) {
    if (($item.PSObject.Properties.Name -contains "requestUsageMatched") -and [bool]$item.requestUsageMatched) {
        $matchedRequestTotal += [long]$item.requestTotalTokens
        $matchedRequestCount += [int]$item.requestCount
        if (($item.PSObject.Properties.Name -contains "requestUsageAfterHelper") -and [bool]$item.requestUsageAfterHelper) {
            $postHelperMatchedRequestTotal += [long]$item.requestTotalTokens
            $postHelperMatchedRequestCount += [int]$item.requestCount
        }
    }
}

$fallbackContextTotal = $ghTotalHelperAll - $postHelperMatchedRequestTotal
if ($fallbackContextTotal -lt 0) {
    Add-Failure "Post-helper matched request total exceeds helperAllTokens. Matched=$postHelperMatchedRequestTotal HelperAll=$ghTotalHelperAll"
}

if ($rawRequests.ok -and ($stats.appQuota.PSObject.Properties.Name -contains "currentGlobalRequestTokens") -and [long]$stats.appQuota.currentGlobalRequestTokens -gt 0) {
    $currentQuotaTokens = [long]$stats.appQuota.currentGlobalRequestTokens
    $rawTotalTokens = [long]$rawRequests.totalTokens
    if (($currentQuotaTokens + $DynamicLogToleranceTokens) -lt $rawTotalTokens) {
        Add-Failure "appQuota.currentGlobalRequestTokens must not lag behind raw Codex request log total. Actual=$currentQuotaTokens Raw=$rawTotalTokens DynamicTolerance=$DynamicLogToleranceTokens"
    }
}

$report = [PSCustomObject]@{
    ok = ($failures.Count -eq 0)
    generatedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    projectPath = $root
    statsSource = if ([string]::IsNullOrWhiteSpace($StatsUrl)) { $statsPath } else { $StatsUrl }
    rawCodexRequestTokens = [long]$rawRequests.totalTokens
    rawCodexRequestCount = [int]$rawRequests.requestCount
    dynamicLogToleranceTokens = [int]$DynamicLogToleranceTokens
    helperTrackedRequestTokens = [long]$ghTotalHelperAll
    helperEstimatedAvoidedContextTokens = [long]$ghTotalAllSaved
    helperLatestProjectOutputTokens = [long]$history.latestProjectOutputTokens
    helperLatestProjectSavedTokens = [long]$history.latestProjectSavedTokens
    matchedRequestTokens = [long]$matchedRequestTotal
    matchedRequestCount = [int]$matchedRequestCount
    postHelperMatchedRequestTokens = [long]$postHelperMatchedRequestTotal
    postHelperMatchedRequestCount = [int]$postHelperMatchedRequestCount
    historicalMatchedRequestTokens = [long]($matchedRequestTotal - $postHelperMatchedRequestTotal)
    fallbackContextTokens = [long]$fallbackContextTotal
    note = "rawCodexRequestTokens 是所有 Codex 真实请求日志；postHelperMatchedRequestTokens 才参与 helper 后实际口径，helper 前历史请求只保留为审计参考。"
    failures = @($failures.ToArray())
}

$report | ConvertTo-Json -Depth 6

if ($failures.Count -gt 0) {
    exit 1
}
