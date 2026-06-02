Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($null -eq (Get-Variable -Name tuhSessionFileCache -Scope Script -ErrorAction SilentlyContinue)) {
    $script:tuhSessionFileCache = @()
    $script:tuhSessionFileCacheAtUtc = [datetime]::MinValue
    $script:tuhSessionUsageCache = $null
    $script:tuhSessionUsageCacheAtUtc = [datetime]::MinValue
    $script:tuhHelperHistoryCache = $null
    $script:tuhHelperHistoryCacheAtUtc = [datetime]::MinValue
    $script:tuhHelperHistoryCacheWriteUtc = [datetime]::MinValue
    $script:tuhHelperHistoryCacheLength = -1L
}

function Get-TuhDefaultDataPath {
    $base = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $env:USERPROFILE "AppData\Local" }
    return (Join-Path $base "TokenUsageHelper\data")
}

function Resolve-TuhDataPath {
    param([string]$DataPath = "")

    if ([string]::IsNullOrWhiteSpace($DataPath)) {
        return [System.IO.Path]::GetFullPath((Get-TuhDefaultDataPath))
    }

    if ([System.IO.Path]::GetExtension($DataPath).ToLowerInvariant() -eq ".json") {
        return [System.IO.Path]::GetFullPath((Split-Path -Parent $DataPath))
    }

    return [System.IO.Path]::GetFullPath($DataPath)
}

function Get-TuhStatePath {
    param([string]$DataPath = "")

    if (-not [string]::IsNullOrWhiteSpace($DataPath) -and [System.IO.Path]::GetExtension($DataPath).ToLowerInvariant() -eq ".json") {
        return [System.IO.Path]::GetFullPath($DataPath)
    }

    return (Join-Path (Resolve-TuhDataPath -DataPath $DataPath) "state.json")
}

function Get-TuhConfigPath {
    param([string]$DataPath = "")
    return (Join-Path (Resolve-TuhDataPath -DataPath $DataPath) "config.json")
}

function Get-TuhHealthEventsPath {
    param([string]$DataPath = "")
    return (Join-Path (Resolve-TuhDataPath -DataPath $DataPath) "health-events.json")
}

function ConvertTo-TuhJson {
    param([object]$Value)
    if ($null -ne $Value -and $Value -is [System.Array] -and $Value.Length -eq 0) {
        return "[]"
    }
    return ($Value | ConvertTo-Json -Depth 20 -Compress)
}

function Read-TuhJsonFile {
    param(
        [string]$Path,
        [object]$DefaultValue
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $DefaultValue
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $DefaultValue
        }
        return ($raw | ConvertFrom-Json)
    }
    catch {
        return $DefaultValue
    }
}

function Save-TuhJsonFile {
    param(
        [string]$Path,
        [object]$Value
    )

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    ConvertTo-TuhJson -Value $Value | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-TuhProp {
    param(
        [object]$Object,
        [string]$Name,
        [object]$DefaultValue = $null
    )

    if ($null -eq $Object -or -not ($Object.PSObject.Properties.Name -contains $Name)) {
        return $DefaultValue
    }
    return $Object.$Name
}

function Get-TuhLong {
    param(
        [object]$Value,
        [long]$DefaultValue = 0
    )

    if ($null -eq $Value) {
        return $DefaultValue
    }
    $result = 0L
    if ([long]::TryParse([string]$Value, [ref]$result)) {
        return $result
    }
    return $DefaultValue
}

function Get-TuhBool {
    param(
        [object]$Value,
        [bool]$DefaultValue = $true
    )

    if ($null -eq $Value) {
        return $DefaultValue
    }
    if ($Value -is [bool]) {
        return [bool]$Value
    }
    return ([string]$Value).ToLowerInvariant() -in @("1", "true", "yes", "on", "enabled")
}

function New-TuhDefaultConfig {
    param([string]$DataPath = "")

    return [PSCustomObject]@{
        schemaVersion = 1
        helperEnabled = $true
        thresholdTokens = 8000
        contextBudgetChars = 12000
        refreshSeconds = 5
        panelOpacityPercent = 72
        panelX = -1
        panelY = -1
        panelWidth = 460
        panelHeight = 270
        dataPath = (Resolve-TuhDataPath -DataPath $DataPath)
        updatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    }
}

function Read-TuhConfig {
    param([string]$DataPath = "")

    $defaults = New-TuhDefaultConfig -DataPath $DataPath
    $path = Get-TuhConfigPath -DataPath $DataPath
    $stored = Read-TuhJsonFile -Path $path -DefaultValue $defaults

    return [PSCustomObject]@{
        schemaVersion = 1
        helperEnabled = Get-TuhBool -Value (Get-TuhProp -Object $stored -Name "helperEnabled" -DefaultValue $defaults.helperEnabled) -DefaultValue $true
        thresholdTokens = [int](Get-TuhLong -Value (Get-TuhProp -Object $stored -Name "thresholdTokens" -DefaultValue $defaults.thresholdTokens) -DefaultValue $defaults.thresholdTokens)
        contextBudgetChars = [int](Get-TuhLong -Value (Get-TuhProp -Object $stored -Name "contextBudgetChars" -DefaultValue $defaults.contextBudgetChars) -DefaultValue $defaults.contextBudgetChars)
        refreshSeconds = [int](Get-TuhLong -Value (Get-TuhProp -Object $stored -Name "refreshSeconds" -DefaultValue $defaults.refreshSeconds) -DefaultValue $defaults.refreshSeconds)
        panelOpacityPercent = [int](Get-TuhLong -Value (Get-TuhProp -Object $stored -Name "panelOpacityPercent" -DefaultValue $defaults.panelOpacityPercent) -DefaultValue $defaults.panelOpacityPercent)
        panelX = [int](Get-TuhLong -Value (Get-TuhProp -Object $stored -Name "panelX" -DefaultValue $defaults.panelX) -DefaultValue $defaults.panelX)
        panelY = [int](Get-TuhLong -Value (Get-TuhProp -Object $stored -Name "panelY" -DefaultValue $defaults.panelY) -DefaultValue $defaults.panelY)
        panelWidth = [int](Get-TuhLong -Value (Get-TuhProp -Object $stored -Name "panelWidth" -DefaultValue $defaults.panelWidth) -DefaultValue $defaults.panelWidth)
        panelHeight = [int](Get-TuhLong -Value (Get-TuhProp -Object $stored -Name "panelHeight" -DefaultValue $defaults.panelHeight) -DefaultValue $defaults.panelHeight)
        dataPath = (Resolve-TuhDataPath -DataPath (Get-TuhProp -Object $stored -Name "dataPath" -DefaultValue $defaults.dataPath))
        updatedAtUtc = Get-TuhProp -Object $stored -Name "updatedAtUtc" -DefaultValue $defaults.updatedAtUtc
    }
}

function Save-TuhConfig {
    param(
        [object]$Config,
        [string]$DataPath = ""
    )

    $normalized = [PSCustomObject]@{
        schemaVersion = 1
        helperEnabled = Get-TuhBool -Value (Get-TuhProp -Object $Config -Name "helperEnabled" -DefaultValue $true) -DefaultValue $true
        thresholdTokens = [int](Get-TuhLong -Value (Get-TuhProp -Object $Config -Name "thresholdTokens" -DefaultValue 8000) -DefaultValue 8000)
        contextBudgetChars = [int][Math]::Min(120000, [Math]::Max(4000, (Get-TuhLong -Value (Get-TuhProp -Object $Config -Name "contextBudgetChars" -DefaultValue 12000) -DefaultValue 12000)))
        refreshSeconds = [int](Get-TuhLong -Value (Get-TuhProp -Object $Config -Name "refreshSeconds" -DefaultValue 5) -DefaultValue 5)
        panelOpacityPercent = [int][Math]::Min(100, [Math]::Max(35, (Get-TuhLong -Value (Get-TuhProp -Object $Config -Name "panelOpacityPercent" -DefaultValue 72) -DefaultValue 72)))
        panelX = [int](Get-TuhLong -Value (Get-TuhProp -Object $Config -Name "panelX" -DefaultValue -1) -DefaultValue -1)
        panelY = [int](Get-TuhLong -Value (Get-TuhProp -Object $Config -Name "panelY" -DefaultValue -1) -DefaultValue -1)
        panelWidth = [int][Math]::Min(1600, [Math]::Max(380, (Get-TuhLong -Value (Get-TuhProp -Object $Config -Name "panelWidth" -DefaultValue 460) -DefaultValue 460)))
        panelHeight = [int][Math]::Min(1200, [Math]::Max(220, (Get-TuhLong -Value (Get-TuhProp -Object $Config -Name "panelHeight" -DefaultValue 270) -DefaultValue 270)))
        dataPath = (Resolve-TuhDataPath -DataPath (Get-TuhProp -Object $Config -Name "dataPath" -DefaultValue $DataPath))
        updatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    }
    Save-TuhJsonFile -Path (Get-TuhConfigPath -DataPath $DataPath) -Value $normalized
    return $normalized
}

function New-TuhDefaultState {
    return [PSCustomObject]@{
        schemaVersion = 1
        cumulativeUsageTokens = 0L
        cumulativeSavedTokens = 0L
        currentUsageTokens = 0L
        currentSavedTokens = 0L
        lastObservedUsageTokens = 0L
        lastObservedSavedTokens = 0L
        lastProjectPath = ""
        lastRefreshAtUtc = ""
        observations = @{}
        samples = @()
    }
}

function Read-TuhState {
    param([string]$DataPath = "")
    $path = Get-TuhStatePath -DataPath $DataPath
    $state = Read-TuhJsonFile -Path $path -DefaultValue (New-TuhDefaultState)
    if ($null -eq $state) {
        return (New-TuhDefaultState)
    }
    return $state
}

function Save-TuhState {
    param(
        [object]$State,
        [string]$DataPath = ""
    )
    Save-TuhJsonFile -Path (Get-TuhStatePath -DataPath $DataPath) -Value $State
}

function Get-TuhObjectList {
    param([object]$Items)

    $list = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Items) {
        return ,$list
    }
    foreach ($item in @($Items)) {
        if ($null -ne $item) {
            [void]$list.Add($item)
        }
    }
    return ,$list
}

function Read-TuhHealthEvents {
    param([string]$DataPath = "")

    $items = Read-TuhJsonFile -Path (Get-TuhHealthEventsPath -DataPath $DataPath) -DefaultValue @()
    return ,(Get-TuhObjectList -Items $items)
}

function Write-TuhHealthEvent {
    param(
        [string]$DataPath = "",
        [string]$Level = "info",
        [string]$Label = "",
        [string]$Detail = "",
        [string]$ProjectPath = "",
        [string]$Source = "panel",
        [int]$MaxEvents = 100
    )

    $events = Read-TuhHealthEvents -DataPath $DataPath
    [void]$events.Add([PSCustomObject]@{
        atUtc = (Get-Date).ToUniversalTime().ToString("o")
        level = $Level
        label = $Label
        detail = $Detail
        projectPath = $ProjectPath
        source = $Source
    })

    $max = [Math]::Max(1, $MaxEvents)
    while ($events.Count -gt $max) {
        $events.RemoveAt(0)
    }
    Save-TuhJsonFile -Path (Get-TuhHealthEventsPath -DataPath $DataPath) -Value @($events.ToArray())
    return $events[$events.Count - 1]
}

function Get-TuhSampleList {
    param([object]$Samples)

    $list = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Samples) {
        return $list
    }
    foreach ($sample in @($Samples)) {
        if ($null -ne $sample) {
            [void]$list.Add($sample)
        }
    }
    return $list
}

function Reset-TuhState {
    param([string]$DataPath = "")
    if ([string]::IsNullOrWhiteSpace($DataPath)) {
        $config = Read-TuhConfig -DataPath $DataPath
        $DataPath = [string](Get-TuhProp -Object $config -Name "dataPath" -DefaultValue $DataPath)
    }
    $state = New-TuhDefaultState
    Save-TuhState -State $state -DataPath $DataPath
    Save-TuhJsonFile -Path (Get-TuhHealthEventsPath -DataPath $DataPath) -Value @()
    return $state
}

function Estimate-TuhTokens {
    param([long]$Chars)
    if ($Chars -le 0) {
        return 0L
    }
    return [long][Math]::Ceiling($Chars / 4.0)
}

function Get-TuhMatchingConversation {
    param(
        [object]$Stats,
        [string]$ProjectPath
    )

    $global = Get-TuhProp -Object $Stats -Name "globalHistory"
    $conversations = Get-TuhProp -Object $global -Name "conversations"
    if ($null -eq $conversations) {
        return $null
    }

    $root = [System.IO.Path]::GetFullPath($ProjectPath).TrimEnd("\").ToLowerInvariant()
    foreach ($conversation in @($conversations)) {
        $path = [string](Get-TuhProp -Object $conversation -Name "projectPath" -DefaultValue "")
        if (-not [string]::IsNullOrWhiteSpace($path)) {
            $normalized = [System.IO.Path]::GetFullPath($path).TrimEnd("\").ToLowerInvariant()
            if ($normalized -eq $root) {
                return $conversation
            }
        }
    }
    return $null
}

function Get-TuhTextFileTokens {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return 0L
    }
    return Estimate-TuhTokens -Chars (Get-Item -LiteralPath $Path).Length
}

function Get-TuhLogFiles {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return @()
    }
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        return @((Get-Item -LiteralPath $Path))
    }

    return @(Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Length -le 10485760 -and $_.Extension.ToLowerInvariant() -in @(".json", ".jsonl", ".log", ".txt") } |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 100)
}

function Get-TuhGenericLogMetrics {
    param([string]$LogPath)

    $usage = 0L
    $saved = 0L
    $lineCount = 0
    $fileCount = 0
    $latestUtc = $null
    $files = Get-TuhLogFiles -Path $LogPath

    foreach ($file in $files) {
        $fileCount++
        if ($null -eq $latestUtc -or $file.LastWriteTimeUtc -gt $latestUtc) {
            $latestUtc = $file.LastWriteTimeUtc
        }
        try {
            foreach ($line in (Get-Content -LiteralPath $file.FullName -ErrorAction Stop)) {
                $lineCount++
                $lineUsage = 0L
                $totalMatch = [regex]::Match($line, '(?i)"?(?:total_tokens|totalTokens|tokens_total|usage_tokens)"?\s*[:=]\s*(\d+)')
                if ($totalMatch.Success) {
                    $lineUsage += Get-TuhLong -Value $totalMatch.Groups[1].Value
                }
                else {
                    foreach ($match in [regex]::Matches($line, '(?i)"?(?:input_tokens|output_tokens|prompt_tokens|completion_tokens|inputTokens|outputTokens)"?\s*[:=]\s*(\d+)')) {
                        $lineUsage += Get-TuhLong -Value $match.Groups[1].Value
                    }
                }

                $lineSaved = 0L
                foreach ($match in [regex]::Matches($line, '(?i)"?(?:saved_tokens|savedTokens|helper_saved_tokens|helperSavedTokens|context_saved_tokens)"?\s*[:=]\s*(\d+)')) {
                    $lineSaved += Get-TuhLong -Value $match.Groups[1].Value
                }
                $usage += $lineUsage
                $saved += $lineSaved
            }
        }
        catch {
            continue
        }
    }

    return [PSCustomObject]@{
        usageTokens = $usage
        savedTokens = $saved
        fileCount = $fileCount
        lineCount = $lineCount
        latestWriteUtc = if ($null -eq $latestUtc) { "" } else { $latestUtc.ToString("o") }
    }
}

function Get-TuhProjectMetrics {
    param(
        [string]$ProjectPath = ".",
        [object]$Config = $null,
        [string]$ContextPath = "",
        [string]$LogPath = "",
        [long]$ManualUsageTokens = -1,
        [long]$ManualSavedTokens = -1
    )

    $root = [System.IO.Path]::GetFullPath($ProjectPath)
    $statsPath = Join-Path $root ".codex\stats.json"
    $contextPath = if ([string]::IsNullOrWhiteSpace($ContextPath)) { Join-Path $root ".codex\context.md" } else { [System.IO.Path]::GetFullPath($ContextPath) }
    $source = "none"
    $confidence = "missing"
    $usage = 0L
    $saved = 0L
    $original = 0L
    $output = 0L
    $latestRequest = ""
    $contextTokens = 0L
    $notes = New-Object System.Collections.Generic.List[string]

    if ($ManualUsageTokens -ge 0 -or $ManualSavedTokens -ge 0) {
        $usage = [Math]::Max(0L, $ManualUsageTokens)
        $saved = [Math]::Max(0L, $ManualSavedTokens)
        $output = $usage
        $source = "manual refresh"
        $confidence = "manual"
        [void]$notes.Add("本次数据来自手动输入，按增量累计。")
    }

    if (Test-Path -LiteralPath $contextPath -PathType Leaf) {
        $contextTokens = Get-TuhTextFileTokens -Path $contextPath
    }

    if ($confidence -eq "missing" -and -not [string]::IsNullOrWhiteSpace($LogPath)) {
        $logMetrics = Get-TuhGenericLogMetrics -LogPath ([System.IO.Path]::GetFullPath($LogPath))
        if ($logMetrics.usageTokens -gt 0 -or $logMetrics.savedTokens -gt 0) {
            $usage = [long]$logMetrics.usageTokens
            $saved = [long]$logMetrics.savedTokens
            $output = $usage
            $source = "generic token log"
            $confidence = "log-estimate"
            $latestRequest = [string]$logMetrics.latestWriteUtc
            [void]$notes.Add(("读取 {0} 个日志文件、{1} 行；支持 total_tokens/input_tokens/output_tokens/saved_tokens 字段。" -f $logMetrics.fileCount, $logMetrics.lineCount))
        }
    }

    if ($confidence -eq "missing" -and (Test-Path -LiteralPath $statsPath -PathType Leaf)) {
        $stats = Read-TuhJsonFile -Path $statsPath -DefaultValue $null
        if ($null -ne $stats) {
            $output = Get-TuhLong -Value (Get-TuhProp -Object $stats -Name "outputTokens") -DefaultValue $contextTokens
            $original = Get-TuhLong -Value (Get-TuhProp -Object $stats -Name "originalTokens") -DefaultValue 0
            $saved = Get-TuhLong -Value (Get-TuhProp -Object $stats -Name "savedTokens") -DefaultValue 0
            $usage = $output
            $source = ".codex/stats.json"
            $confidence = "context-estimate"

            $conversation = Get-TuhMatchingConversation -Stats $stats -ProjectPath $root
            if ($null -ne $conversation) {
                $requestTokens = Get-TuhLong -Value (Get-TuhProp -Object $conversation -Name "helperAllTokens") -DefaultValue 0
                $effectiveSaved = Get-TuhLong -Value (Get-TuhProp -Object $conversation -Name "totalSavedTokens") -DefaultValue 0
                if ($requestTokens -gt 0) {
                    $usage = $requestTokens
                    $source = "matched Codex request logs"
                    $confidence = "request-matched"
                }
                if ($effectiveSaved -gt 0) {
                    $saved = $effectiveSaved
                }
                $latestRequest = [string](Get-TuhProp -Object $conversation -Name "latestRequestRun" -DefaultValue "")
                if (Get-TuhBool -Value (Get-TuhProp -Object $conversation -Name "needsHelperReview" -DefaultValue $false) -DefaultValue $false) {
                    [void]$notes.Add("该项目有活跃请求晚于 helper 记录，需要复核接入。")
                }
            }

            if ($original -gt 0 -and $usage -gt $original) {
                [void]$notes.Add("实际请求 token 高于单次 context 原始估算，说明该项目包含多轮请求；节省量使用已匹配日志口径。")
                $saved = [Math]::Max(0L, $saved)
            }
        }
    }
    elseif ($confidence -eq "missing" -and $contextTokens -gt 0) {
        $usage = $contextTokens
        $output = $contextTokens
        $source = if ([string]::IsNullOrWhiteSpace($ContextPath)) { ".codex/context.md" } else { "context file" }
        $confidence = "context-only"
        [void]$notes.Add("未找到可用 stats 或日志，只能估算 context 文件 token。")
    }

    $threshold = 8000
    if ($null -ne $Config) {
        $threshold = [int](Get-TuhLong -Value (Get-TuhProp -Object $Config -Name "thresholdTokens" -DefaultValue 8000) -DefaultValue 8000)
        if (-not (Get-TuhBool -Value (Get-TuhProp -Object $Config -Name "helperEnabled" -DefaultValue $true) -DefaultValue $true)) {
            [void]$notes.Add("helper 当前关闭，只统计不建议自动压缩。")
        }
    }

    $status = if ($usage -le 0) { "missing" } elseif ($usage -ge $threshold) { "above-threshold" } else { "ok" }
    return [PSCustomObject]@{
        projectPath = $root
        source = $source
        confidence = $confidence
        status = $status
        currentUsageTokens = $usage
        currentSavedTokens = [Math]::Max(0L, $saved)
        originalTokens = $original
        outputTokens = $output
        contextTokens = $contextTokens
        thresholdTokens = $threshold
        latestRequestRun = $latestRequest
        contextPath = $contextPath
        logPath = $LogPath
        notes = @($notes.ToArray())
    }
}

function Get-TuhGlobalMetrics {
    param(
        [string]$ProjectPath = ".",
        [object]$Config = $null,
        [string]$ContextPath = "",
        [string]$LogPath = ""
    )

    $root = [System.IO.Path]::GetFullPath($ProjectPath)
    $statsPath = Join-Path $root ".codex\stats.json"
    if (-not (Test-Path -LiteralPath $statsPath -PathType Leaf)) {
        return Get-TuhProjectMetrics -ProjectPath $ProjectPath -Config $Config -ContextPath $ContextPath -LogPath $LogPath
    }

    $stats = Read-TuhJsonFile -Path $statsPath -DefaultValue $null
    $global = Get-TuhProp -Object $stats -Name "globalHistory"
    $conversations = @(Get-TuhProp -Object $global -Name "conversations" -DefaultValue @())
    if ($null -eq $stats -or $conversations.Count -le 0) {
        return Get-TuhProjectMetrics -ProjectPath $ProjectPath -Config $Config -ContextPath $ContextPath -LogPath $LogPath
    }

    $usage = 0L
    $saved = 0L
    $active = 0
    $needsReview = 0
    $latestRequest = ""
    $latestDate = [datetime]::MinValue
    foreach ($conversation in $conversations) {
        $usage += [Math]::Max(0L, (Get-TuhLong -Value (Get-TuhProp -Object $conversation -Name "helperAllTokens" -DefaultValue 0) -DefaultValue 0))
        $saved += [Math]::Max(0L, (Get-TuhLong -Value (Get-TuhProp -Object $conversation -Name "totalSavedTokens" -DefaultValue 0) -DefaultValue 0))
        if (Get-TuhBool -Value (Get-TuhProp -Object $conversation -Name "needsHelperReview" -DefaultValue $false) -DefaultValue $false) {
            $needsReview++
        }

        $rawLatest = [string](Get-TuhProp -Object $conversation -Name "latestRequestRun" -DefaultValue "")
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParse($rawLatest, [ref]$parsed)) {
            if ($parsed -gt $latestDate) {
                $latestDate = $parsed
                $latestRequest = $rawLatest
            }
            if ($parsed -ge (Get-Date).AddHours(-24)) {
                $active++
            }
        }
    }

    $threshold = 8000
    $notes = New-Object System.Collections.Generic.List[string]
    if ($null -ne $Config) {
        $threshold = [int](Get-TuhLong -Value (Get-TuhProp -Object $Config -Name "thresholdTokens" -DefaultValue 8000) -DefaultValue 8000)
        if (-not (Get-TuhBool -Value (Get-TuhProp -Object $Config -Name "helperEnabled" -DefaultValue $true) -DefaultValue $true)) {
            [void]$notes.Add("helper 当前关闭，只统计不建议自动压缩。")
        }
    }
    if ($needsReview -gt 0) {
        [void]$notes.Add(("{0} 个对话需要复核 helper 是否持续接入。" -f $needsReview))
    }

    $status = if ($usage -le 0) { "missing" } elseif ($usage -ge $threshold) { "above-threshold" } else { "ok" }
    return [PSCustomObject]@{
        projectPath = "__all_codex_projects__"
        scope = "all-projects"
        source = "global Codex request logs"
        confidence = "global-history"
        status = $status
        currentUsageTokens = $usage
        currentSavedTokens = [Math]::Max(0L, $saved)
        originalTokens = 0L
        outputTokens = $usage
        contextTokens = 0L
        thresholdTokens = $threshold
        latestRequestRun = $latestRequest
        contextPath = ""
        logPath = $LogPath
        conversationCount = $conversations.Count
        activeConversationCount = $active
        needsReviewCount = $needsReview
        notes = @($notes.ToArray())
    }
}

function Get-TuhCodexSessionUsageMetrics {
    param(
        [int]$RecentFileCount = 6,
        [int]$TailLines = 160
    )

    $sessionRoot = Join-Path $env:USERPROFILE ".codex\sessions"
    $nowUtc = (Get-Date).ToUniversalTime()
    if ($null -ne $script:tuhSessionUsageCache -and ($nowUtc - $script:tuhSessionUsageCacheAtUtc).TotalSeconds -lt 10) {
        return $script:tuhSessionUsageCache
    }

    if (-not (Test-Path -LiteralPath $sessionRoot -PathType Container)) {
        return [PSCustomObject]@{
            ok = $false
            source = "codex session token_count"
            totalTokens = 0L
            fileCount = 0
            latestTokenAtUtc = ""
        }
    }

    $total = 0L
    $fileCount = 0
    $latestAt = [datetime]::MinValue
    if ($script:tuhSessionFileCache.Count -le 0 -or ($nowUtc - $script:tuhSessionFileCacheAtUtc).TotalSeconds -gt 30) {
        $script:tuhSessionFileCache = @(Get-ChildItem -LiteralPath $sessionRoot -Recurse -File -Filter "*.jsonl" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -First $RecentFileCount)
        $script:tuhSessionFileCacheAtUtc = $nowUtc
    }
    $files = @($script:tuhSessionFileCache | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First $RecentFileCount)

    foreach ($file in $files) {
        $lines = @()
        try {
            $lines = @(Get-Content -LiteralPath $file.FullName -Tail $TailLines -ErrorAction Stop)
        }
        catch {
            continue
        }

        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            $line = [string]$lines[$i]
            if ($line.IndexOf('"token_count"', [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
                continue
            }

            try {
                $entry = $line | ConvertFrom-Json
                $payload = Get-TuhProp -Object $entry -Name "payload"
                if ([string](Get-TuhProp -Object $payload -Name "type" -DefaultValue "") -ne "token_count") {
                    continue
                }
                $info = Get-TuhProp -Object $payload -Name "info"
                $totalUsage = Get-TuhProp -Object $info -Name "total_token_usage"
                $tokens = Get-TuhLong -Value (Get-TuhProp -Object $totalUsage -Name "total_tokens" -DefaultValue 0) -DefaultValue 0
                if ($tokens -le 0) {
                    continue
                }

                $total += $tokens
                $fileCount++
                $rawAt = [string](Get-TuhProp -Object $entry -Name "timestamp" -DefaultValue "")
                $parsedAt = [datetime]::MinValue
                if ([datetime]::TryParse($rawAt, [ref]$parsedAt) -and $parsedAt.ToUniversalTime() -gt $latestAt) {
                    $latestAt = $parsedAt.ToUniversalTime()
                }
                break
            }
            catch {
                continue
            }
        }
    }

    $result = [PSCustomObject]@{
        ok = ($fileCount -gt 0)
        source = "codex session token_count"
        totalTokens = $total
        fileCount = $fileCount
        latestTokenAtUtc = if ($latestAt -eq [datetime]::MinValue) { "" } else { $latestAt.ToString("o") }
    }
    $script:tuhSessionUsageCache = $result
    $script:tuhSessionUsageCacheAtUtc = $nowUtc
    return $result
}

function Get-TuhHelperHistorySavedMetrics {
    param(
        [int]$TailLines = 1200
    )

    $historyPath = Join-Path $env:USERPROFILE ".codex\codex-token-helper-history.jsonl"
    if (-not (Test-Path -LiteralPath $historyPath -PathType Leaf)) {
        return [PSCustomObject]@{
            ok = $false
            source = "helper history savedTokens"
            totalSavedTokens = 0L
            entryCount = 0
            latestSavedAtUtc = ""
            latestProjectPath = ""
            latestSavedTokens = 0L
        }
    }

    $item = Get-Item -LiteralPath $historyPath
    $nowUtc = (Get-Date).ToUniversalTime()
    if ($null -ne $script:tuhHelperHistoryCache -and
        $script:tuhHelperHistoryCacheLength -eq $item.Length -and
        $script:tuhHelperHistoryCacheWriteUtc -eq $item.LastWriteTimeUtc -and
        ($nowUtc - $script:tuhHelperHistoryCacheAtUtc).TotalSeconds -lt 10) {
        return $script:tuhHelperHistoryCache
    }

    $total = 0L
    $entryCount = 0
    $latestAt = [datetime]::MinValue
    $latestProjectPath = ""
    $latestSavedTokens = 0L
    try {
        foreach ($line in @(Get-Content -LiteralPath $historyPath -Tail $TailLines -ErrorAction Stop)) {
            if ([string]::IsNullOrWhiteSpace($line) -or $line.IndexOf('"savedTokens"', [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
                continue
            }
            try {
                $entry = $line | ConvertFrom-Json
                if ([string](Get-TuhProp -Object $entry -Name "runKind" -DefaultValue "actual") -ne "actual") {
                    continue
                }
                $saved = Get-TuhLong -Value (Get-TuhProp -Object $entry -Name "savedTokens" -DefaultValue 0) -DefaultValue 0
                if ($saved -le 0) {
                    continue
                }
                $total += $saved
                $entryCount++
                $rawAt = [string](Get-TuhProp -Object $entry -Name "generatedAtUtc" -DefaultValue "")
                $parsedAt = [datetime]::MinValue
                if ([datetime]::TryParse($rawAt, [ref]$parsedAt) -and $parsedAt.ToUniversalTime() -gt $latestAt) {
                    $latestAt = $parsedAt.ToUniversalTime()
                    $latestProjectPath = [string](Get-TuhProp -Object $entry -Name "projectPath" -DefaultValue "")
                    $latestSavedTokens = $saved
                }
            }
            catch {
                continue
            }
        }
    }
    catch {
    }

    $result = [PSCustomObject]@{
        ok = ($entryCount -gt 0)
        source = "helper history savedTokens"
        totalSavedTokens = $total
        entryCount = $entryCount
        latestSavedAtUtc = if ($latestAt -eq [datetime]::MinValue) { "" } else { $latestAt.ToString("o") }
        latestProjectPath = $latestProjectPath
        latestSavedTokens = $latestSavedTokens
    }
    $script:tuhHelperHistoryCache = $result
    $script:tuhHelperHistoryCacheAtUtc = $nowUtc
    $script:tuhHelperHistoryCacheWriteUtc = $item.LastWriteTimeUtc
    $script:tuhHelperHistoryCacheLength = $item.Length
    return $result
}

function Get-TuhRecentHelperSavedSamples {
    param(
        [datetime]$SinceUtc,
        [int]$TailLines = 300
    )

    $historyPath = Join-Path $env:USERPROFILE ".codex\codex-token-helper-history.jsonl"
    $samples = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $historyPath -PathType Leaf)) {
        return @()
    }

    try {
        foreach ($line in @(Get-Content -LiteralPath $historyPath -Tail $TailLines -ErrorAction Stop)) {
            if ([string]::IsNullOrWhiteSpace($line) -or $line.IndexOf('"savedTokens"', [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
                continue
            }
            try {
                $entry = $line | ConvertFrom-Json
                if ([string](Get-TuhProp -Object $entry -Name "runKind" -DefaultValue "actual") -ne "actual") {
                    continue
                }
                $saved = Get-TuhLong -Value (Get-TuhProp -Object $entry -Name "savedTokens" -DefaultValue 0) -DefaultValue 0
                if ($saved -le 0) {
                    continue
                }
                $rawAt = [string](Get-TuhProp -Object $entry -Name "generatedAtUtc" -DefaultValue "")
                $at = [datetime]::MinValue
                if (-not [datetime]::TryParse($rawAt, [ref]$at)) {
                    continue
                }
                $atUtc = $at.ToUniversalTime()
                if ($atUtc -lt $SinceUtc) {
                    continue
                }
                [void]$samples.Add([PSCustomObject]@{
                    atUtc = $atUtc.ToString("o")
                    scope = "all-projects"
                    projectPath = [string](Get-TuhProp -Object $entry -Name "projectPath" -DefaultValue "__all_codex_projects__")
                    usageTokens = 0L
                    savedTokens = $saved
                    source = "helper history savedTokens"
                    confidence = "helper-history"
                })
            }
            catch {
                continue
            }
        }
    }
    catch {
    }
    return @($samples.ToArray())
}

function Get-TuhDiagnostic {
    param(
        [object]$Config = $null,
        [object]$State = $null,
        [object]$Metrics = $null,
        [string]$RefreshError = "",
        [datetime]$NowUtc = (Get-Date).ToUniversalTime()
    )

    $helperEnabled = Get-TuhBool -Value (Get-TuhProp -Object $Config -Name "helperEnabled" -DefaultValue $true) -DefaultValue $true
    $status = [string](Get-TuhProp -Object $Metrics -Name "status" -DefaultValue "missing")
    $confidence = [string](Get-TuhProp -Object $Metrics -Name "confidence" -DefaultValue "missing")
    $usage = Get-TuhLong -Value (Get-TuhProp -Object $Metrics -Name "currentUsageTokens" -DefaultValue 0) -DefaultValue 0
    $saved = Get-TuhLong -Value (Get-TuhProp -Object $Metrics -Name "currentSavedTokens" -DefaultValue 0) -DefaultValue 0
    $lastRefreshRaw = [string](Get-TuhProp -Object $State -Name "lastRefreshAtUtc" -DefaultValue "")
    $lastRefresh = [datetime]::MinValue
    $hasRefreshTime = [datetime]::TryParse($lastRefreshRaw, [ref]$lastRefresh)
    $secondsSinceRefresh = if ($hasRefreshTime) { [int][Math]::Max(0, ($NowUtc - $lastRefresh.ToUniversalTime()).TotalSeconds) } else { -1 }

    if (-not [string]::IsNullOrWhiteSpace($RefreshError)) {
        return [PSCustomObject]@{
            level = "error"
            label = "refresh failed"
            detail = $RefreshError
            confidence = $confidence
            secondsSinceRefresh = $secondsSinceRefresh
        }
    }

    if (-not $helperEnabled) {
        return [PSCustomObject]@{
            level = "warn"
            label = "helper off"
            detail = "Helper is disabled in config."
            confidence = $confidence
            secondsSinceRefresh = $secondsSinceRefresh
        }
    }

    if (-not $hasRefreshTime) {
        return [PSCustomObject]@{
            level = "warn"
            label = "waiting"
            detail = "No successful refresh has been recorded yet."
            confidence = $confidence
            secondsSinceRefresh = $secondsSinceRefresh
        }
    }

    if ($secondsSinceRefresh -gt 20) {
        return [PSCustomObject]@{
            level = "warn"
            label = "stale"
            detail = ("Last successful refresh was {0}s ago." -f $secondsSinceRefresh)
            confidence = $confidence
            secondsSinceRefresh = $secondsSinceRefresh
        }
    }

    if ($status -eq "missing" -and $usage -le 0 -and $saved -le 0) {
        return [PSCustomObject]@{
            level = "warn"
            label = "no data"
            detail = "No usable token metrics were found for this project."
            confidence = $confidence
            secondsSinceRefresh = $secondsSinceRefresh
        }
    }

    return [PSCustomObject]@{
        level = "ok"
        label = "healthy"
        detail = "Refresh loop and token metrics are available."
        confidence = $confidence
        secondsSinceRefresh = $secondsSinceRefresh
    }
}

function Invoke-TuhDoctor {
    param(
        [string]$ProjectPath = ".",
        [string]$DataPath = "",
        [string]$ContextPath = "",
        [string]$LogPath = "",
        [switch]$AllProjects
    )

    $checks = New-Object System.Collections.Generic.List[object]
    $config = Read-TuhConfig -DataPath $DataPath
    $isTokenSaverEnabled = Get-TuhBool -Value (Get-TuhProp -Object $config -Name "helperEnabled" -DefaultValue $true) -DefaultValue $true
    $stateDataPath = if ([string]::IsNullOrWhiteSpace($DataPath)) { [string]$config.dataPath } else { $DataPath }
    $dataRoot = Resolve-TuhDataPath -DataPath $stateDataPath
    $statePath = Get-TuhStatePath -DataPath $stateDataPath
    $configPath = Get-TuhConfigPath -DataPath $stateDataPath
    $healthPath = Get-TuhHealthEventsPath -DataPath $stateDataPath

    try {
        if (-not (Test-Path -LiteralPath $dataRoot -PathType Container)) {
            New-Item -ItemType Directory -Force -Path $dataRoot | Out-Null
        }
        [void]$checks.Add([PSCustomObject]@{ name = "data path"; ok = $true; detail = $dataRoot })
    }
    catch {
        [void]$checks.Add([PSCustomObject]@{ name = "data path"; ok = $false; detail = $_.Exception.Message })
    }

    try {
        $probe = Join-Path $dataRoot (".write-test-{0}.tmp" -f [Guid]::NewGuid().ToString("N"))
        "ok" | Set-Content -LiteralPath $probe -Encoding ASCII
        Remove-Item -LiteralPath $probe -Force
        [void]$checks.Add([PSCustomObject]@{ name = "data writable"; ok = $true; detail = $dataRoot })
    }
    catch {
        [void]$checks.Add([PSCustomObject]@{ name = "data writable"; ok = $false; detail = $_.Exception.Message })
    }

    $state = Read-TuhState -DataPath $stateDataPath
    [void]$checks.Add([PSCustomObject]@{ name = "state readable"; ok = ($null -ne $state); detail = $statePath })
    [void]$checks.Add([PSCustomObject]@{ name = "config readable"; ok = ($null -ne $config); detail = $configPath })

    $refreshResult = $null
    try {
        $refreshResult = Update-TuhState -ProjectPath $ProjectPath -DataPath $stateDataPath -ContextPath $ContextPath -LogPath $LogPath -AllProjects:$AllProjects
        $config = $refreshResult.config
        $state = $refreshResult.state
        $metrics = $refreshResult.metrics
        [void]$checks.Add([PSCustomObject]@{ name = "refresh"; ok = $true; detail = "state refreshed for doctor" })
    }
    catch {
        $metrics = if ($AllProjects) { Get-TuhGlobalMetrics -ProjectPath $ProjectPath -Config $config -ContextPath $ContextPath -LogPath $LogPath } else { Get-TuhProjectMetrics -ProjectPath $ProjectPath -Config $config -ContextPath $ContextPath -LogPath $LogPath }
        [void]$checks.Add([PSCustomObject]@{ name = "refresh"; ok = $false; detail = $_.Exception.Message })
    }
    $diagnostic = Get-TuhDiagnostic -Config $config -State $state -Metrics $metrics
    $metricsCheckName = if ($AllProjects) { "global metrics" } else { "project metrics" }
    [void]$checks.Add([PSCustomObject]@{ name = $metricsCheckName; ok = ([string]$metrics.confidence -ne "missing"); detail = ("{0} / {1}" -f $metrics.source, $metrics.confidence) })
    [void]$checks.Add([PSCustomObject]@{ name = "diagnostic"; ok = ([string]$diagnostic.level -ne "error"); detail = ("{0}: {1}" -f $diagnostic.label, $diagnostic.detail) })

    $events = Read-TuhHealthEvents -DataPath $stateDataPath
    $recentEvents = @($events.ToArray() | Select-Object -Last 5)
    $failed = @($checks.ToArray() | Where-Object { -not $_.ok })
    $doctorScope = if ($AllProjects) { "all-projects" } else { "project" }

    return [PSCustomObject]@{
        ok = ($failed.Count -eq 0)
        projectPath = [System.IO.Path]::GetFullPath($ProjectPath)
        scope = $doctorScope
        config = $config
        state = $state
        paths = [PSCustomObject]@{
            dataPath = $dataRoot
            statePath = $statePath
            configPath = $configPath
            healthEventsPath = $healthPath
        }
        diagnostic = $diagnostic
        metrics = [PSCustomObject]@{
            source = $metrics.source
            confidence = $metrics.confidence
            status = $metrics.status
            currentUsageTokens = $metrics.currentUsageTokens
            currentSavedTokens = $metrics.currentSavedTokens
        }
        checks = @($checks.ToArray())
        recentHealthEvents = $recentEvents
        deltas = if ($null -ne $refreshResult) { $refreshResult.deltas } else { $null }
    }
}

function Update-TuhState {
    param(
        [string]$ProjectPath = ".",
        [string]$DataPath = "",
        [string]$ContextPath = "",
        [string]$LogPath = "",
        [long]$ManualUsageTokens = -1,
        [long]$ManualSavedTokens = -1,
        [switch]$AllProjects
    )

    $config = Read-TuhConfig -DataPath $DataPath
    $isTokenSaverEnabled = Get-TuhBool -Value (Get-TuhProp -Object $config -Name "helperEnabled" -DefaultValue $true) -DefaultValue $true
    $stateDataPath = if ([string]::IsNullOrWhiteSpace($DataPath)) { [string]$config.dataPath } else { $DataPath }
    $state = Read-TuhState -DataPath $stateDataPath
    $manualMode = ($ManualUsageTokens -ge 0 -or $ManualSavedTokens -ge 0)
    $liveDisabled = ([string]$env:TOKEN_HELPER_DISABLE_LIVE -eq "1")
    $metrics = if ($AllProjects -and -not $manualMode) {
        $globalMetrics = Get-TuhGlobalMetrics -ProjectPath $ProjectPath -Config $config -ContextPath $ContextPath -LogPath $LogPath
        if (-not $liveDisabled) {
            $liveSession = Get-TuhCodexSessionUsageMetrics
            if ($null -ne $liveSession -and [bool]$liveSession.ok) {
                $globalMetrics | Add-Member -NotePropertyName liveSessionTokens -NotePropertyValue ([long]$liveSession.totalTokens) -Force
                $globalMetrics | Add-Member -NotePropertyName liveSessionSource -NotePropertyValue ([string]$liveSession.source) -Force
                $globalMetrics | Add-Member -NotePropertyName liveSessionFileCount -NotePropertyValue ([int]$liveSession.fileCount) -Force
                $globalMetrics | Add-Member -NotePropertyName liveSessionLatestTokenAtUtc -NotePropertyValue ([string]$liveSession.latestTokenAtUtc) -Force
                $globalMetrics | Add-Member -NotePropertyName confidence -NotePropertyValue "global-history+live-session" -Force
                $globalMetrics | Add-Member -NotePropertyName source -NotePropertyValue "global Codex request logs + live session token_count" -Force
            }
            if ($isTokenSaverEnabled) {
                $liveSaved = Get-TuhHelperHistorySavedMetrics
                if ($null -ne $liveSaved -and [bool]$liveSaved.ok) {
                    $globalMetrics | Add-Member -NotePropertyName liveHelperSavedTokens -NotePropertyValue ([long]$liveSaved.totalSavedTokens) -Force
                    $globalMetrics | Add-Member -NotePropertyName liveHelperSavedSource -NotePropertyValue ([string]$liveSaved.source) -Force
                    $globalMetrics | Add-Member -NotePropertyName liveHelperSavedEntryCount -NotePropertyValue ([int]$liveSaved.entryCount) -Force
                    $globalMetrics | Add-Member -NotePropertyName liveHelperSavedLatestAtUtc -NotePropertyValue ([string]$liveSaved.latestSavedAtUtc) -Force
                    $globalMetrics | Add-Member -NotePropertyName liveHelperSavedLatestProjectPath -NotePropertyValue ([string]$liveSaved.latestProjectPath) -Force
                    $globalMetrics | Add-Member -NotePropertyName liveHelperSavedLatestSavedTokens -NotePropertyValue ([long]$liveSaved.latestSavedTokens) -Force
                }
            }
        }
        $globalMetrics
    }
    else {
        Get-TuhProjectMetrics -ProjectPath $ProjectPath -Config $config -ContextPath $ContextPath -LogPath $LogPath -ManualUsageTokens $ManualUsageTokens -ManualSavedTokens $ManualSavedTokens
    }

    $observations = Get-TuhProp -Object $state -Name "observations" -DefaultValue @{}
    if ($null -eq $observations) {
        $observations = @{}
    }
    if ($observations -isnot [hashtable]) {
        $converted = @{}
        foreach ($prop in $observations.PSObject.Properties) {
            $converted[$prop.Name] = $prop.Value
        }
        $observations = $converted
    }

    $scopeKey = if ($AllProjects -and -not $manualMode -and [string](Get-TuhProp -Object $metrics -Name "scope" -DefaultValue "") -eq "all-projects") { "__all_codex_projects__" } else { $metrics.projectPath.ToLowerInvariant() }
    $sampleScope = if ($scopeKey -eq "__all_codex_projects__") { "all-projects" } else { "project" }
    $key = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($scopeKey))
    $prior = if ($observations.ContainsKey($key)) { $observations[$key] } else { $null }
    $priorUsage = Get-TuhLong -Value (Get-TuhProp -Object $prior -Name "usage" -DefaultValue 0) -DefaultValue 0
    $priorSaved = Get-TuhLong -Value (Get-TuhProp -Object $prior -Name "saved" -DefaultValue 0) -DefaultValue 0
    $priorLiveUsage = Get-TuhLong -Value (Get-TuhProp -Object $prior -Name "liveUsage" -DefaultValue 0) -DefaultValue 0
    $priorLiveSaved = Get-TuhLong -Value (Get-TuhProp -Object $prior -Name "liveSaved" -DefaultValue 0) -DefaultValue 0
    $currentUsage = Get-TuhLong -Value (Get-TuhProp -Object $metrics -Name "currentUsageTokens" -DefaultValue 0) -DefaultValue 0
    $currentSaved = Get-TuhLong -Value (Get-TuhProp -Object $metrics -Name "currentSavedTokens" -DefaultValue 0) -DefaultValue 0
    $hasPriorObservation = ($null -ne $prior)
    $usageDelta = 0L
    $savedDelta = 0L
    if ($manualMode) {
        $usageDelta = [Math]::Max(0L, [long]$currentUsage)
        $savedDelta = [Math]::Max(0L, [long]$currentSaved)
    }
    elseif ($hasPriorObservation) {
        $usageDelta = [Math]::Max(0L, ([long]$currentUsage - [long]$priorUsage))
        $savedDelta = [Math]::Max(0L, ([long]$currentSaved - [long]$priorSaved))
    }
    $liveUsage = Get-TuhLong -Value (Get-TuhProp -Object $metrics -Name "liveSessionTokens" -DefaultValue 0) -DefaultValue 0
    $liveUsageDelta = if ($manualMode -or -not $hasPriorObservation -or $liveUsage -le 0 -or $priorLiveUsage -le 0) { 0L } else { [Math]::Max(0L, $liveUsage - $priorLiveUsage) }
    if ($liveUsageDelta -gt $usageDelta) {
        $usageDelta = $liveUsageDelta
    }
    $liveSaved = Get-TuhLong -Value (Get-TuhProp -Object $metrics -Name "liveHelperSavedTokens" -DefaultValue 0) -DefaultValue 0
    $liveSavedDelta = if ($manualMode -or -not $hasPriorObservation -or $liveSaved -le 0 -or $priorLiveSaved -le 0) { 0L } else { [Math]::Max(0L, $liveSaved - $priorLiveSaved) }
    if ($liveSavedDelta -gt $savedDelta) {
        $savedDelta = $liveSavedDelta
    }
    if (-not $isTokenSaverEnabled -and -not $manualMode) {
        $savedDelta = 0L
        $liveSavedDelta = 0L
    }
    $sampleProjectPath = $metrics.projectPath
    $sampleSavedSourceProject = ""
    $sampleSavedRunTokens = 0L
    if ($savedDelta -gt 0 -and $liveSavedDelta -gt 0 -and $liveSavedDelta -ge $savedDelta) {
        $sampleSavedSourceProject = [string](Get-TuhProp -Object $metrics -Name "liveHelperSavedLatestProjectPath" -DefaultValue "")
        $sampleSavedRunTokens = Get-TuhLong -Value (Get-TuhProp -Object $metrics -Name "liveHelperSavedLatestSavedTokens" -DefaultValue 0) -DefaultValue 0
        if (-not [string]::IsNullOrWhiteSpace($sampleSavedSourceProject)) {
            $sampleProjectPath = $sampleSavedSourceProject
        }
    }

    $cumulativeUsage = Get-TuhLong -Value (Get-TuhProp -Object $state -Name "cumulativeUsageTokens" -DefaultValue 0) -DefaultValue 0
    $cumulativeSaved = Get-TuhLong -Value (Get-TuhProp -Object $state -Name "cumulativeSavedTokens" -DefaultValue 0) -DefaultValue 0
    $nowDate = (Get-Date).ToUniversalTime()
    $now = $nowDate.ToString("o")
    $samples = Get-TuhSampleList -Samples (Get-TuhProp -Object $state -Name "samples" -DefaultValue @())
    $cutoff = $nowDate.AddMinutes(-15)
    $keptSamples = New-Object System.Collections.Generic.List[object]
    foreach ($sample in $samples) {
        $sampleAt = [datetime]::MinValue
        $sampleAtRaw = [string](Get-TuhProp -Object $sample -Name "atUtc" -DefaultValue "")
        $existingScope = [string](Get-TuhProp -Object $sample -Name "scope" -DefaultValue "project")
        if ([datetime]::TryParse($sampleAtRaw, [ref]$sampleAt) -and $sampleAt.ToUniversalTime() -ge $cutoff) {
            if ($existingScope -eq $sampleScope) {
                [void]$keptSamples.Add($sample)
            }
        }
    }
    if ($isTokenSaverEnabled -and $AllProjects -and -not $manualMode -and -not $liveDisabled -and $hasPriorObservation -and $cumulativeSaved -gt 0 -and @($keptSamples.ToArray() | Where-Object { (Get-TuhLong -Value (Get-TuhProp -Object $_ -Name "savedTokens" -DefaultValue 0) -DefaultValue 0) -gt 0 }).Count -eq 0) {
        foreach ($recentSavedSample in @(Get-TuhRecentHelperSavedSamples -SinceUtc $cutoff)) {
            [void]$keptSamples.Add($recentSavedSample)
        }
    }
    [void]$keptSamples.Add([PSCustomObject]@{
        atUtc = $now
        scope = $sampleScope
        projectPath = $sampleProjectPath
        usageTokens = $usageDelta
        savedTokens = $savedDelta
        source = $metrics.source
        confidence = $metrics.confidence
        liveUsageTokens = $liveUsage
        liveHelperSavedTokens = $liveSaved
        savedSourceProjectPath = $sampleSavedSourceProject
        savedSourceRunTokens = $sampleSavedRunTokens
    })

    $observations[$key] = [PSCustomObject]@{
        projectPath = $metrics.projectPath
        usage = $currentUsage
        saved = $currentSaved
        liveUsage = $liveUsage
        liveSaved = $liveSaved
        updatedAtUtc = $now
    }

    $newState = [PSCustomObject]@{
        schemaVersion = 1
        cumulativeUsageTokens = ($cumulativeUsage + $usageDelta)
        cumulativeSavedTokens = ($cumulativeSaved + $savedDelta)
        currentUsageTokens = $currentUsage
        currentSavedTokens = $currentSaved
        lastObservedUsageTokens = $currentUsage
        lastObservedSavedTokens = $currentSaved
        lastProjectPath = $metrics.projectPath
        lastRefreshAtUtc = $now
        observations = $observations
        samples = @($keptSamples.ToArray())
    }
    Save-TuhState -State $newState -DataPath $stateDataPath

    return [PSCustomObject]@{
        ok = $true
        config = $config
        state = $newState
        metrics = $metrics
        deltas = [PSCustomObject]@{
            usageTokens = $usageDelta
            savedTokens = $savedDelta
        }
    }
}
