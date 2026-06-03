Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot "token-helper-core.ps1")
$work = Join-Path $env:TEMP ("token-helper-mvp-" + [Guid]::NewGuid().ToString("N"))
$project = Join-Path $work "project"
$codex = Join-Path $project ".codex"
$data = Join-Path $work "data"
$installRoot = Join-Path $work "install"
New-Item -ItemType Directory -Force -Path $codex, $data | Out-Null
$previousLiveDisable = $env:TOKEN_HELPER_DISABLE_LIVE

try {
    $env:TOKEN_HELPER_DISABLE_LIVE = "1"

    $cliText = Get-Content -LiteralPath (Join-Path $scriptRoot "token-helper.ps1") -Raw
    $coreText = Get-Content -LiteralPath (Join-Path $scriptRoot "token-helper-core.ps1") -Raw
    $panelText = Get-Content -LiteralPath (Join-Path $scriptRoot "token-helper-panel.ps1") -Raw
    $readmeText = Get-Content -LiteralPath (Join-Path $scriptRoot "README.md") -Raw
    $validateMatch = [regex]::Match($cliText, '\[ValidateSet\(([^\)]*)\)\]')
    if (-not $validateMatch.Success) {
        throw "could not find token-helper ValidateSet"
    }
    $commands = [regex]::Matches($validateMatch.Groups[1].Value, '"([^"]+)"') | ForEach-Object { $_.Groups[1].Value }
    foreach ($commandName in $commands) {
        if ($readmeText -notmatch [regex]::Escape("token-helper $commandName")) {
            throw "README does not mention token-helper $commandName"
        }
    }
    $panelMenuItems = [regex]::Matches($panelText, 'Items\.Add\("([^"]+)"\)') | ForEach-Object { $_.Groups[1].Value }
    foreach ($menuItem in @("Settings", "Reset Stats", "Exit")) {
        if (@($panelMenuItems) -notcontains $menuItem) {
            throw "panel menu missing $menuItem"
        }
    }
    foreach ($removedMenuItem in @("Doctor", "Health Log", "Refresh", "Open Data Folder")) {
        if (@($panelMenuItems) -contains $removedMenuItem) {
            throw "panel menu should not show $removedMenuItem"
        }
    }
    if ($panelText -match 'Add_DoubleClick') {
        throw "panel should not open settings on double-click"
    }
    if ($panelText -match [regex]::Escape("Token Usage Helper") -or $panelText -notmatch [regex]::Escape("Token saver")) {
        throw "floating panel should be named Token saver"
    }
    if ($panelText -notmatch [regex]::Escape("token-saver.ico") -or $panelText -notmatch [regex]::Escape("[System.Drawing.Icon]::new")) {
        throw "floating panel should prefer the Token saver icon file"
    }
    $installText = Get-Content -LiteralPath (Join-Path $scriptRoot "install.ps1") -Raw
    $uninstallText = Get-Content -LiteralPath (Join-Path $scriptRoot "uninstall.ps1") -Raw
    $agentInstallerNames = @(
        "install-codex.ps1",
        "install-claude.ps1",
        "install-cursor.ps1",
        "install-aider.ps1",
        "install-generic.ps1",
        "install-all-agents.ps1"
    )
    foreach ($agentInstallerName in $agentInstallerNames) {
        if (-not (Test-Path -LiteralPath (Join-Path $scriptRoot $agentInstallerName) -PathType Leaf)) {
            throw "missing agent installer $agentInstallerName"
        }
        if ($readmeText -notmatch [regex]::Escape($agentInstallerName)) {
            throw "README does not mention agent installer $agentInstallerName"
        }
        if ($installText -notmatch [regex]::Escape($agentInstallerName)) {
            throw "install.ps1 should copy agent installer $agentInstallerName"
        }
    }
    $detectedInstallRoot = Join-Path $work "detected-install"
    $detectedInstall = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot "install-all-agents.ps1") -InstallRoot $detectedInstallRoot -NoShortcut -NoAutoAttach -DetectedAgents Codex,Cursor | ConvertFrom-Json
    if (@($detectedInstall.allAgentsMode.appliedAgents) -notcontains "Codex" -or @($detectedInstall.allAgentsMode.appliedAgents) -notcontains "Cursor") {
        throw "install-all should apply detected agents"
    }
    foreach ($missingAgent in @("Claude", "Aider", "Generic")) {
        if (@($detectedInstall.allAgentsMode.skippedAgents) -notcontains $missingAgent) {
            throw "install-all should list missing agent as skipped: $missingAgent"
        }
    }
    $forceInstallRoot = Join-Path $work "force-all-install"
    $forceInstall = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot "install-all-agents.ps1") -InstallRoot $forceInstallRoot -NoShortcut -NoAutoAttach -DetectedAgents Codex -ForceAll | ConvertFrom-Json
    foreach ($forcedAgent in @("Codex", "Claude", "Cursor", "Aider", "Generic")) {
        if (@($forceInstall.allAgentsMode.appliedAgents) -notcontains $forcedAgent) {
            throw "install-all -ForceAll should apply $forcedAgent"
        }
    }
    if (@($forceInstall.allAgentsMode.skippedAgents).Count -ne 0) {
        throw "install-all -ForceAll should not report skipped agents"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $scriptRoot "test-token-saver-release.ps1") -PathType Leaf)) {
        throw "missing release gate test-token-saver-release.ps1"
    }
    if ($readmeText -notmatch [regex]::Escape("test-token-saver-release.ps1")) {
        throw "README should document the full release gate"
    }
    $changelogText = Get-Content -LiteralPath (Join-Path $scriptRoot "CHANGELOG.md") -Raw
    foreach ($changelogGuard in @("corrupt runtime data", "transient missing usage data", "locked history files", "panel child-process cleanup", "structured JSON")) {
        if ($changelogText -notmatch [regex]::Escape($changelogGuard)) {
            throw "CHANGELOG should mention reliability work: $changelogGuard"
        }
    }
    if ($readmeText -notmatch [regex]::Escape("JSON summary")) {
        throw "README should explain release gate JSON summary output"
    }
    $releaseGatePath = Join-Path $scriptRoot "test-token-saver-release.ps1"
    $releaseGateTextRaw = Get-Content -LiteralPath $releaseGatePath -Raw
    foreach ($releaseGateText in @("releaseGateFailed", "failedCount", "skippedCount", "InjectFailureForSelfTest")) {
        if ($releaseGateTextRaw -notmatch [regex]::Escape($releaseGateText)) {
            throw "release gate should report failures as structured JSON: $releaseGateText"
        }
    }
    if ($releaseGateTextRaw -notmatch [regex]::Escape("SelfTestOnly")) {
        throw "release gate should provide a non-recursive self-test mode"
    }
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $releaseSelfTestOutput = & powershell -NoProfile -ExecutionPolicy Bypass -File $releaseGatePath -SelfTestOnly 2>&1
        $releaseSelfTestExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($releaseSelfTestExitCode -eq 0) {
        throw "release gate self-test should exit nonzero"
    }
    $releaseSelfTestJson = ($releaseSelfTestOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    $releaseSelfTest = $releaseSelfTestJson | ConvertFrom-Json
    if ([bool]$releaseSelfTest.ok -or [int]$releaseSelfTest.failedCount -ne 1 -or [string]$releaseSelfTest.results[0].status -ne "failed") {
        throw "release gate self-test should return structured failed JSON"
    }
    foreach ($panelResetGuard in @("function Invoke-TuhPanelReset", "Clear-TuhRefreshProcess -Kill `$true", "lastResetAtUtc", "settingsResetApplied")) {
        if ($panelText -notmatch [regex]::Escape($panelResetGuard)) {
            throw "panel reset should be immediate and race-safe: $panelResetGuard"
        }
    }
    $mutexIndex = $panelText.IndexOf('Global\TokenUsageHelperPanel')
    $formsAddTypeIndex = $panelText.IndexOf('Add-Type -AssemblyName System.Windows.Forms')
    if ($mutexIndex -lt 0 -or $formsAddTypeIndex -lt 0 -or $mutexIndex -gt $formsAddTypeIndex) {
        throw "panel mutex should be acquired before WinForms loading so duplicate launches exit quickly"
    }
    if ($installText -notmatch [regex]::Escape("Token saver.lnk")) {
        throw "install shortcut should be named Token saver.lnk"
    }
    foreach ($releaseGateDependency in @("codex-context-regression.ps1", "test-token-helper-mvp.ps1", "test-token-helper-panel-smoke.ps1")) {
        if ($installText -notmatch [regex]::Escape($releaseGateDependency)) {
            throw "install.ps1 should copy release gate dependency $releaseGateDependency"
        }
    }
    if ($installText -notmatch [regex]::Escape("token-saver.ico") -or $installText -notmatch [regex]::Escape("IconLocation")) {
        throw "install should generate and assign a Token saver shortcut icon"
    }
    if ($installText -notmatch [regex]::Escape("startMenuShortcutPath") -or $installText -notmatch [regex]::Escape("Programs")) {
        throw "install should create a Start Menu Token saver shortcut"
    }
    if ($uninstallText -notmatch [regex]::Escape("Token saver.lnk") -or $uninstallText -notmatch [regex]::Escape("Token Usage Helper.lnk")) {
        throw "uninstall should remove new Token saver shortcut and legacy Token Usage Helper shortcut"
    }
    if ($uninstallText -notmatch [regex]::Escape("startMenuShortcutPath") -or $uninstallText -notmatch [regex]::Escape("removedShortcuts")) {
        throw "uninstall should remove Start Menu Token saver shortcuts"
    }
    $settingsMatch = [regex]::Match($panelText, '(?s)function Show-TuhSettings\s*\{.*?function Show-TuhHealthLog')
    if (-not $settingsMatch.Success) {
        throw "could not isolate Show-TuhSettings block"
    }
    $settingsText = $settingsMatch.Value
    foreach ($removedSettingsText in @("Data path", "Opacity", "Doctor")) {
        if ($settingsText -match ('\.Text\s*=\s*"' + [regex]::Escape($removedSettingsText) + '"')) {
            throw "settings should not show $removedSettingsText"
        }
    }
    if ($settingsText -match '\.Text\s*=\s*"Center"') {
        throw "settings should not show Center"
    }
    if ($settingsText -notmatch '\.Text\s*=\s*"Reset data"') {
        throw "settings should show Reset data"
    }
    if ($settingsText -match 'Enable token saving helper') {
        throw "settings should say token saver instead of helper"
    }
    foreach ($removedChartText in @("Global token usage", "Global helper saved", "Helper saved", "Token saver saved - 15m")) {
        if ($panelText -match [regex]::Escape($removedChartText)) {
            throw "panel should not show old chart title $removedChartText"
        }
    }
    foreach ($expectedChartText in @("Token activity - 15m", "Token usage", "Token saved", "usage peak", "max/run", "Token saver", "online", "offline")) {
        if ($panelText -notmatch [regex]::Escape($expectedChartText)) {
            throw "panel missing expected text $expectedChartText"
        }
    }
    if ($panelText -notmatch 'state\.cumulativeUsageTokens' -or $panelText -notmatch 'state\.cumulativeSavedTokens') {
        throw "panel totals should use reset-aware cumulative state counters"
    }
    foreach ($clickThroughText in @("TuhClickThroughForm", "HTTRANSPARENT", "WM_NCHITTEST", "New-Object TuhClickThroughForm")) {
        if ($panelText -notmatch [regex]::Escape($clickThroughText)) {
            throw "panel missing pinned click-through support: $clickThroughText"
        }
    }
    foreach ($nativeClickThroughText in @("WS_EX_TRANSPARENT", "WS_EX_LAYERED", "SetMouseClickThrough", "SetHandleMouseClickThrough", "usageChart.Handle", "savingChart.Handle", "clickThroughTimer")) {
        if ($panelText -notmatch [regex]::Escape($nativeClickThroughText)) {
            throw "panel missing native click-through support: $nativeClickThroughText"
        }
    }
    foreach ($childNoLayeredText in @('SetHandleMouseClickThrough($usageChart.Handle, $shouldPassThrough, $false)', 'SetHandleMouseClickThrough($savingChart.Handle, $shouldPassThrough, $false)')) {
        if ($panelText -notmatch [regex]::Escape($childNoLayeredText)) {
            throw "child panels should not use WS_EX_LAYERED because it can blank rendering: $childNoLayeredText"
        }
    }
    foreach ($wholeWindowOpacityText in @("Get-TuhChartBackColor", "Get-TuhStripBackColor", 'Get-TuhPinnedOpacity', '$script:panelForm.Opacity = if ($script:panelPinned)')) {
        if ($panelText -notmatch [regex]::Escape($wholeWindowOpacityText)) {
            throw "panel missing whole-window pinned transparency support: $wholeWindowOpacityText"
        }
    }
    if ($panelText -notmatch '\$script:panelForm\.TransparencyKey\s*=\s*\[System\.Drawing\.Color\]::Empty') {
        throw "pinned mode should not use full transparency keying"
    }
    foreach ($removedAcrylicText in @("SetAcrylicBackground", "ACCENT_ENABLE_ACRYLICBLURBEHIND", "TuhTransparentPanel", "Get-TuhChartTintColor", "Get-TuhStripTintColor")) {
        if ($panelText -match [regex]::Escape($removedAcrylicText)) {
            throw "pinned mode should use stable whole-window opacity, not acrylic/background-only transparency: $removedAcrylicText"
        }
    }
    if ($coreText -notmatch '\$cumulativeSaved\s+-gt\s+0') {
        throw "saved chart history should not backfill after Reset data until saved total is nonzero"
    }
    if ($coreText -notmatch 'liveHelperSavedLatestProjectPath' -or $coreText -notmatch 'savedSourceProjectPath') {
        throw "saved samples should preserve the source project path"
    }
    if ($readmeText -match [regex]::Escape("Open Data Folder")) {
        throw "README should not mention removed panel menu item Open Data Folder"
    }
    if ($panelText -notmatch 'Apply-TuhDoctorResultToPanel\s+-Doctor\s+\$doctor') {
        throw "panel Doctor must apply doctor result back to the main panel"
    }
    if ($panelText -match '\$doctorItem\.Add_Click\(\{\s*Show-TuhDoctor\s+-Owner\s+\$script:panelForm;\s*Refresh-TuhPanel\s*\}\)') {
        throw "panel Doctor menu should not run a second refresh after doctor"
    }
    foreach ($settingsImmediateText in @("Apply-TuhPanelConfigImmediately", "Clear-TuhRefreshProcess -Kill `$true", "Apply-TuhPanelConfigImmediately -Config `$savedConfig")) {
        if ($panelText -notmatch [regex]::Escape($settingsImmediateText)) {
            throw "settings save should immediately apply config and redraw status: $settingsImmediateText"
        }
    }
    if ($panelText -match 'max/run\s+\{0\}\s+\{1\}' -or $panelText -match 'savedPeakProject') {
        throw "panel should not show project names next to max/run"
    }
    foreach ($chartAnchorText in @("function Get-TuhChartAnchorUtc", "lastChartAnchorUtc", "-AnchorUtc `$chartAnchorUtc")) {
        if ($panelText -notmatch [regex]::Escape($chartAnchorText)) {
            throw "panel charts should use a stable refresh anchor: $chartAnchorText"
        }
    }

    $stats = [PSCustomObject]@{
        projectPath = $project
        outputTokens = 3008
        originalTokens = 50000
        savedTokens = 46992
        globalHistory = [PSCustomObject]@{
            conversations = @(
                [PSCustomObject]@{
                    conversationName = "mvp-test"
                    projectPath = $project
                    helperAllTokens = 12000
                    totalSavedTokens = 38000
                    latestRequestRun = "2026-06-01 12:00:00"
                    needsHelperReview = $false
                },
                [PSCustomObject]@{
                    conversationName = "other-test"
                    projectPath = (Join-Path $work "other-project")
                    helperAllTokens = 8000
                    totalSavedTokens = 5000
                    latestRequestRun = "2026-06-01 12:05:00"
                    needsHelperReview = $false
                }
            )
        }
    }
    $stats | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $codex "stats.json") -Encoding UTF8
    "context body" | Set-Content -LiteralPath (Join-Path $codex "context.md") -Encoding UTF8

    $first = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot "token-helper.ps1") refresh -ProjectPath $project -DataPath $data -Json | ConvertFrom-Json
    if ([long]$first.state.cumulativeUsageTokens -ne 0) {
        throw "first refresh should establish usage baseline, got $($first.state.cumulativeUsageTokens)"
    }
    if ([long]$first.state.cumulativeSavedTokens -ne 0) {
        throw "first refresh should establish saved baseline, got $($first.state.cumulativeSavedTokens)"
    }
    if ([string]$first.metrics.confidence -ne "request-matched") {
        throw "expected request-matched confidence, got $($first.metrics.confidence)"
    }

    $second = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot "token-helper.ps1") refresh -ProjectPath $project -DataPath $data -Json | ConvertFrom-Json
    if ([long]$second.state.cumulativeUsageTokens -ne 0) {
        throw "refresh double-counted usage"
    }
    if ([long]$second.state.cumulativeSavedTokens -ne 0) {
        throw "refresh double-counted savings"
    }

    $stats.globalHistory.conversations[0].helperAllTokens = 12750
    $stats.globalHistory.conversations[0].totalSavedTokens = 39250
    $stats | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $codex "stats.json") -Encoding UTF8
    $third = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot "token-helper.ps1") refresh -ProjectPath $project -DataPath $data -Json | ConvertFrom-Json
    if ([long]$third.state.cumulativeUsageTokens -ne 750) {
        throw "refresh did not add only new usage delta, got $($third.state.cumulativeUsageTokens)"
    }
    if ([long]$third.state.cumulativeSavedTokens -ne 1250) {
        throw "refresh did not add only new saved delta, got $($third.state.cumulativeSavedTokens)"
    }

    $resetForGlobal = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot "token-helper.ps1") reset -DataPath $data -Json | ConvertFrom-Json
    if ([long]$resetForGlobal.state.cumulativeUsageTokens -ne 0 -or [long]$resetForGlobal.state.cumulativeSavedTokens -ne 0) {
        throw "reset before global refresh did not clear cumulative counters"
    }
    $globalFirst = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot "token-helper.ps1") refresh -ProjectPath $project -DataPath $data -AllProjects -Json | ConvertFrom-Json
    if ([string]$globalFirst.metrics.scope -ne "all-projects" -or [string]$globalFirst.metrics.confidence -notin @("global-history", "global-history+live-session")) {
        throw "global refresh did not use all-project history"
    }
    if ([long]$globalFirst.metrics.currentUsageTokens -ne 20750 -or [long]$globalFirst.metrics.currentSavedTokens -ne 44250) {
        throw "global refresh returned wrong aggregate: $($globalFirst.metrics | ConvertTo-Json -Compress)"
    }
    if ($globalFirst.metrics.PSObject.Properties.Name -contains "liveSessionTokens" -and [long]$globalFirst.metrics.liveSessionTokens -lt 0) {
        throw "global refresh returned invalid live session token count"
    }
    if ([int]$globalFirst.metrics.conversationCount -ne 2) {
        throw "global refresh returned wrong conversation count"
    }
    if ([long]$globalFirst.state.cumulativeUsageTokens -ne 0 -or [long]$globalFirst.state.cumulativeSavedTokens -ne 0) {
        throw "first global refresh should establish baseline, got $($globalFirst.state | ConvertTo-Json -Compress)"
    }
    $globalSecond = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot "token-helper.ps1") refresh -ProjectPath $project -DataPath $data -AllProjects -Json | ConvertFrom-Json
    if ([long]$globalSecond.state.cumulativeUsageTokens -ne 0 -or [long]$globalSecond.state.cumulativeSavedTokens -ne 0) {
        throw "global refresh double-counted aggregates"
    }

    $stats.globalHistory.conversations[0].helperAllTokens = 13000
    $stats.globalHistory.conversations[0].totalSavedTokens = 40000
    $stats.globalHistory.conversations[1].helperAllTokens = 8200
    $stats.globalHistory.conversations[1].totalSavedTokens = 5300
    $stats | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $codex "stats.json") -Encoding UTF8
    $globalThird = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot "token-helper.ps1") refresh -ProjectPath $project -DataPath $data -AllProjects -Json | ConvertFrom-Json
    if ([long]$globalThird.state.cumulativeUsageTokens -ne 450 -or [long]$globalThird.state.cumulativeSavedTokens -ne 1050) {
        throw "global refresh did not add only aggregate deltas: $($globalThird.state | ConvertTo-Json -Compress)"
    }

    $reset = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot "token-helper.ps1") reset -DataPath $data -Json | ConvertFrom-Json
    if ([long]$reset.state.cumulativeUsageTokens -ne 0 -or [long]$reset.state.cumulativeSavedTokens -ne 0) {
        throw "reset did not clear cumulative counters"
    }
    if (@($reset.state.samples).Count -ne 0) {
        throw "reset did not clear samples"
    }
    if (@($reset.state.observations.PSObject.Properties).Count -ne 0) {
        throw "reset did not clear observations"
    }
    Write-TuhHealthEvent -DataPath $data -Level "warn" -Label "before-reset" -Detail "clear me" -ProjectPath $project -Source "test" | Out-Null
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot "token-helper.ps1") reset -DataPath $data -Json | Out-Null
    if ((Read-TuhHealthEvents -DataPath $data).Count -ne 0) {
        throw "reset did not clear health events"
    }
    $afterResetRefresh = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot "token-helper.ps1") refresh -ProjectPath $project -DataPath $data -AllProjects -Json | ConvertFrom-Json
    if ([long]$afterResetRefresh.state.cumulativeUsageTokens -ne 0 -or [long]$afterResetRefresh.state.cumulativeSavedTokens -ne 0) {
        throw "reset refresh backfilled old aggregate data"
    }
    $afterResetSampleUsage = @($afterResetRefresh.state.samples | Where-Object { [long]$_.usageTokens -gt 0 })
    $afterResetSampleSaved = @($afterResetRefresh.state.samples | Where-Object { [long]$_.savedTokens -gt 0 })
    if ($afterResetSampleUsage.Count -ne 0 -or $afterResetSampleSaved.Count -ne 0) {
        throw "reset refresh backfilled chart peak samples"
    }

    $manual = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot "token-helper.ps1") refresh -ProjectPath $project -DataPath $data -ManualUsageTokens 900 -ManualSavedTokens 120 -Json | ConvertFrom-Json
    if ([long]$manual.state.cumulativeUsageTokens -ne 900 -or [long]$manual.state.cumulativeSavedTokens -ne 120) {
        throw "manual refresh did not add explicit token deltas"
    }
    if ([string]$manual.metrics.confidence -ne "manual") {
        throw "expected manual confidence, got $($manual.metrics.confidence)"
    }

    $previousUserProfile = $env:USERPROFILE
    $historyUserProfile = Join-Path $work "history-user"
    $historyCodexHome = Join-Path $historyUserProfile ".codex"
    New-Item -ItemType Directory -Force -Path $historyCodexHome | Out-Null
    $historyProjectOld = Join-Path $work "history-old"
    $historyProjectNew = Join-Path $work "history-new"
    New-Item -ItemType Directory -Force -Path $historyProjectOld, $historyProjectNew | Out-Null
    @(
        ([PSCustomObject]@{
            atUtc = (Get-Date).ToUniversalTime().AddMinutes(-3).ToString("o")
            projectPath = $historyProjectOld
            runKind = "actual"
            savedTokens = 111
        } | ConvertTo-Json -Compress),
        ([PSCustomObject]@{
            generatedAt = (Get-Date).ToUniversalTime().AddMinutes(-1).ToString("o")
            projectPath = $historyProjectNew
            runKind = "actual"
            savedTokens = 222
        } | ConvertTo-Json -Compress)
    ) | Set-Content -LiteralPath (Join-Path $historyCodexHome "codex-token-helper-history.jsonl") -Encoding UTF8
    try {
        $env:USERPROFILE = $historyUserProfile
        $script:tuhHelperHistoryCache = $null
        $script:tuhHelperHistoryCacheAtUtc = [datetime]::MinValue
        $script:tuhHelperHistoryCacheWriteUtc = [datetime]::MinValue
        $script:tuhHelperHistoryCacheLength = -1L
        $historySavedMetrics = Get-TuhHelperHistorySavedMetrics
        if (-not [bool]$historySavedMetrics.ok -or [long]$historySavedMetrics.totalSavedTokens -ne 333 -or [string]$historySavedMetrics.latestProjectPath -ne [System.IO.Path]::GetFullPath($historyProjectNew)) {
            throw "helper history saved metrics should read atUtc/generatedAt timestamps: $($historySavedMetrics | ConvertTo-Json -Compress)"
        }
        $historySavedSamples = @(Get-TuhRecentHelperSavedSamples -SinceUtc (Get-Date).ToUniversalTime().AddMinutes(-15))
        if ($historySavedSamples.Count -ne 2 -or @($historySavedSamples | Where-Object { [long]$_.savedTokens -gt 0 }).Count -ne 2) {
            throw "helper history saved samples should include atUtc/generatedAt entries"
        }
    }
    finally {
        $env:USERPROFILE = $previousUserProfile
        $script:tuhHelperHistoryCache = $null
        $script:tuhHelperHistoryCacheAtUtc = [datetime]::MinValue
        $script:tuhHelperHistoryCacheWriteUtc = [datetime]::MinValue
        $script:tuhHelperHistoryCacheLength = -1L
    }

    $previousUserProfile = $env:USERPROFILE
    $sessionUserProfile = Join-Path $work "session-user"
    $sessionRoot = Join-Path $sessionUserProfile ".codex\sessions"
    New-Item -ItemType Directory -Force -Path $sessionRoot | Out-Null
    $sessionFileOne = Join-Path $sessionRoot "session-one.jsonl"
    $sessionFileTwo = Join-Path $sessionRoot "session-two.jsonl"
    @(
        ([PSCustomObject]@{
            timestamp = (Get-Date).ToUniversalTime().AddMinutes(-4).ToString("o")
            type = "event"
            payload = [PSCustomObject]@{
                type = "token_count"
                info = [PSCustomObject]@{
                    total_token_usage = [PSCustomObject]@{ total_tokens = 100 }
                }
            }
        } | ConvertTo-Json -Compress -Depth 8),
        ([PSCustomObject]@{
            timestamp = (Get-Date).ToUniversalTime().AddMinutes(-2).ToString("o")
            type = "event"
            payload = [PSCustomObject]@{
                type = "token_count"
                info = [PSCustomObject]@{
                    total_token_usage = [PSCustomObject]@{ total_tokens = 700 }
                }
            }
        } | ConvertTo-Json -Compress -Depth 8)
    ) | Set-Content -LiteralPath $sessionFileOne -Encoding UTF8
    @(
        '{"type":"event","payload":{"type":"other"}}',
        ([PSCustomObject]@{
            timestamp = (Get-Date).ToUniversalTime().AddMinutes(-1).ToString("o")
            type = "event"
            payload = [PSCustomObject]@{
                type = "token_count"
                info = [PSCustomObject]@{
                    total_token_usage = [PSCustomObject]@{ total_tokens = 1300 }
                }
            }
        } | ConvertTo-Json -Compress -Depth 8)
    ) | Set-Content -LiteralPath $sessionFileTwo -Encoding UTF8
    try {
        $env:USERPROFILE = $sessionUserProfile
        $script:tuhSessionFileCache = @()
        $script:tuhSessionFileCacheAtUtc = [datetime]::MinValue
        $script:tuhSessionUsageCache = $null
        $script:tuhSessionUsageCacheAtUtc = [datetime]::MinValue
        $sessionMetrics = Get-TuhCodexSessionUsageMetrics -RecentFileCount 6 -TailLines 20
        if (-not [bool]$sessionMetrics.ok -or [long]$sessionMetrics.totalTokens -ne 2000 -or [int]$sessionMetrics.fileCount -ne 2) {
            throw "codex session token_count parser should sum latest token_count from each session file: $($sessionMetrics | ConvertTo-Json -Compress)"
        }
        if ([string]::IsNullOrWhiteSpace([string]$sessionMetrics.latestTokenAtUtc)) {
            throw "codex session token_count parser should report latest token timestamp"
        }
    }
    finally {
        $env:USERPROFILE = $previousUserProfile
        $script:tuhSessionFileCache = @()
        $script:tuhSessionFileCacheAtUtc = [datetime]::MinValue
        $script:tuhSessionUsageCache = $null
        $script:tuhSessionUsageCacheAtUtc = [datetime]::MinValue
    }

    $defaultConfig = Read-TuhConfig -DataPath (Join-Path $work "fresh-data")
    if ([int]$defaultConfig.panelOpacityPercent -ne 72) {
        throw "expected default panel opacity 72, got $($defaultConfig.panelOpacityPercent)"
    }
    if ([int]$defaultConfig.contextBudgetChars -ne 12000) {
        throw "expected default context budget 12000, got $($defaultConfig.contextBudgetChars)"
    }
    $updatedConfig = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot "token-helper.ps1") config -DataPath (Join-Path $work "fresh-data") -ContextBudgetChars 18000 -Json | ConvertFrom-Json
    if ([int]$updatedConfig.contextBudgetChars -ne 18000) {
        throw "config did not save context budget"
    }

    $corruptData = Join-Path $work "corrupt-data"
    New-Item -ItemType Directory -Force -Path $corruptData | Out-Null
    "{ bad config" | Set-Content -LiteralPath (Join-Path $corruptData "config.json") -Encoding UTF8
    "{ bad state" | Set-Content -LiteralPath (Join-Path $corruptData "state.json") -Encoding UTF8
    $corruptStatus = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot "token-helper.ps1") status -ProjectPath $project -DataPath $corruptData -Json | ConvertFrom-Json
    if ($null -eq $corruptStatus.config -or [int]$corruptStatus.config.contextBudgetChars -ne 12000) {
        throw "corrupt config should fall back to normalized defaults"
    }
    if ($null -eq $corruptStatus.state -or [long]$corruptStatus.state.cumulativeUsageTokens -ne 0 -or [long]$corruptStatus.state.cumulativeSavedTokens -ne 0) {
        throw "corrupt state should fall back to default counters"
    }
    $corruptRefresh = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot "token-helper.ps1") refresh -ProjectPath $project -DataPath $corruptData -ManualUsageTokens 11 -ManualSavedTokens 7 -Json | ConvertFrom-Json
    if ([long]$corruptRefresh.state.cumulativeUsageTokens -ne 11 -or [long]$corruptRefresh.state.cumulativeSavedTokens -ne 7) {
        throw "refresh should recover from corrupt config/state files"
    }

    $budgetProject = Join-Path $work "budget-project"
    $budgetCodex = Join-Path $budgetProject ".codex"
    New-Item -ItemType Directory -Force -Path $budgetCodex | Out-Null
    for ($i = 1; $i -le 10; $i++) {
        ("budget file $i`n" + ("abcdefghij" * 800)) | Set-Content -LiteralPath (Join-Path $budgetProject "file$i.txt") -Encoding UTF8
    }
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot "token-helper.ps1") config -DataPath $budgetCodex -ContextBudgetChars 4000 -Json | Out-Null
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot "codex-token-kit.ps1") -ProjectPath $budgetProject -SkipAiCodex -Quiet -RunKind refresh | Out-Null
    $budgetStats = Get-Content -LiteralPath (Join-Path $budgetCodex "stats.json") -Raw | ConvertFrom-Json
    $budgetContext = Get-Content -LiteralPath (Join-Path $budgetCodex "context.md") -Raw
    if ([int]$budgetStats.maxChars -ne 4000 -or $budgetContext.Length -gt 4300) {
        throw "codex-token-kit did not honor project context budget: maxChars=$($budgetStats.maxChars), length=$($budgetContext.Length)"
    }
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot "codex-token-kit.ps1") -ProjectPath $budgetProject -MaxChars 9000 -SkipAiCodex -Quiet -RunKind refresh | Out-Null
    $overrideStats = Get-Content -LiteralPath (Join-Path $budgetCodex "stats.json") -Raw | ConvertFrom-Json
    if ([int]$overrideStats.maxChars -ne 9000) {
        throw "explicit MaxChars should override project context budget"
    }

    $thresholdProject = Join-Path $work "threshold-project"
    $thresholdCodex = Join-Path $thresholdProject ".codex"
    New-Item -ItemType Directory -Force -Path $thresholdCodex | Out-Null
    ("threshold project`n" + ("xyz" * 2000)) | Set-Content -LiteralPath (Join-Path $thresholdProject "source.txt") -Encoding UTF8
    [PSCustomObject]@{
        projectPath = $thresholdProject
        outputTokens = 1000
        originalTokens = 5000
        savedTokens = 4000
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $thresholdCodex "stats.json") -Encoding UTF8
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot "token-helper.ps1") config -DataPath $thresholdCodex -ThresholdTokens 2000 -Json | Out-Null
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot "codex-token-kit.ps1") -ProjectPath $thresholdProject -SkipAiCodex -Quiet | Out-Null
    if (Test-Path -LiteralPath (Join-Path $thresholdCodex "context.md")) {
        throw "codex-token-kit should skip saver when estimated usage is below threshold"
    }
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot "token-helper.ps1") config -DataPath $thresholdCodex -ThresholdTokens 500 -Json | Out-Null
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot "codex-token-kit.ps1") -ProjectPath $thresholdProject -SkipAiCodex -Quiet | Out-Null
    if (-not (Test-Path -LiteralPath (Join-Path $thresholdCodex "context.md"))) {
        throw "codex-token-kit should run saver when estimated usage is above threshold"
    }
    Remove-Item -LiteralPath (Join-Path $thresholdCodex "context.md") -Force
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot "token-helper.ps1") config -DataPath $thresholdCodex -ThresholdTokens 2000000 -Json | Out-Null
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot "codex-token-kit.ps1") -ProjectPath $thresholdProject -MaxChars 4500 -SkipAiCodex -Quiet | Out-Null
    if (-not (Test-Path -LiteralPath (Join-Path $thresholdCodex "context.md"))) {
        throw "explicit MaxChars should force context generation even above threshold"
    }

    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot "token-helper.ps1") reset -DataPath $data -Json | Out-Null
    $genericProject = Join-Path $work "generic-project"
    $genericContext = Join-Path $genericProject "context.txt"
    $genericLogs = Join-Path $genericProject "logs"
    New-Item -ItemType Directory -Force -Path $genericLogs | Out-Null
    ("abcd" * 1000) | Set-Content -LiteralPath $genericContext -Encoding UTF8
    @(
        '{"model":"x","input_tokens":100,"output_tokens":25,"saved_tokens":300}',
        '{"model":"x","total_tokens":250,"helper_saved_tokens":700}'
    ) | Set-Content -LiteralPath (Join-Path $genericLogs "usage.jsonl") -Encoding UTF8

    $logResult = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot "token-helper.ps1") refresh -ProjectPath $genericProject -DataPath $data -LogPath $genericLogs -Json | ConvertFrom-Json
    if ([long]$logResult.metrics.currentUsageTokens -ne 375) {
        throw "generic log usage parse failed: $($logResult.metrics.currentUsageTokens)"
    }
    if ([long]$logResult.metrics.currentSavedTokens -ne 1000) {
        throw "generic log saved parse failed: $($logResult.metrics.currentSavedTokens)"
    }
    if ([string]$logResult.metrics.confidence -ne "log-estimate") {
        throw "expected log-estimate confidence, got $($logResult.metrics.confidence)"
    }

    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot "token-helper.ps1") reset -DataPath $data -Json | Out-Null
    $contextResult = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot "token-helper.ps1") refresh -ProjectPath $genericProject -DataPath $data -ContextPath $genericContext -Json | ConvertFrom-Json
    if ([long]$contextResult.metrics.currentUsageTokens -le 0) {
        throw "context fallback did not estimate tokens"
    }
    if ([string]$contextResult.metrics.confidence -ne "context-only") {
        throw "expected context-only confidence, got $($contextResult.metrics.confidence)"
    }

    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot "token-helper.ps1") reset -DataPath $data -Json | Out-Null
    $transientProject = Join-Path $work "transient-missing-project"
    $transientLogs = Join-Path $transientProject "logs"
    New-Item -ItemType Directory -Force -Path $transientLogs | Out-Null
    $transientLogFile = Join-Path $transientLogs "usage.jsonl"
    '{"total_tokens":1000,"saved_tokens":400}' | Set-Content -LiteralPath $transientLogFile -Encoding UTF8
    $transientFirst = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot "token-helper.ps1") refresh -ProjectPath $transientProject -DataPath $data -LogPath $transientLogs -Json | ConvertFrom-Json
    if ([long]$transientFirst.state.cumulativeUsageTokens -ne 0 -or [long]$transientFirst.state.cumulativeSavedTokens -ne 0) {
        throw "first transient log refresh should establish baseline"
    }
    Remove-Item -LiteralPath $transientLogFile -Force
    $transientMissing = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot "token-helper.ps1") refresh -ProjectPath $transientProject -DataPath $data -LogPath $transientLogs -Json | ConvertFrom-Json
    if ([string]$transientMissing.metrics.confidence -ne "missing") {
        throw "expected transient missing confidence, got $($transientMissing.metrics.confidence)"
    }
    if ([long]$transientMissing.state.cumulativeUsageTokens -ne 0 -or [long]$transientMissing.state.cumulativeSavedTokens -ne 0) {
        throw "transient missing data should not add token deltas"
    }
    '{"total_tokens":1000,"saved_tokens":400}' | Set-Content -LiteralPath $transientLogFile -Encoding UTF8
    $transientRestored = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot "token-helper.ps1") refresh -ProjectPath $transientProject -DataPath $data -LogPath $transientLogs -Json | ConvertFrom-Json
    if ([long]$transientRestored.state.cumulativeUsageTokens -ne 0 -or [long]$transientRestored.state.cumulativeSavedTokens -ne 0) {
        throw "restored old logs should not be counted as new usage after a transient miss"
    }
    '{"total_tokens":1300,"saved_tokens":500}' | Set-Content -LiteralPath $transientLogFile -Encoding UTF8
    $transientIncreased = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot "token-helper.ps1") refresh -ProjectPath $transientProject -DataPath $data -LogPath $transientLogs -Json | ConvertFrom-Json
    if ([long]$transientIncreased.state.cumulativeUsageTokens -ne 300 -or [long]$transientIncreased.state.cumulativeSavedTokens -ne 100) {
        throw "transient recovery should count only true new deltas"
    }

    $nowUtc = (Get-Date).ToUniversalTime()
    $diagConfigOn = [PSCustomObject]@{ helperEnabled = $true }
    $diagConfigOff = [PSCustomObject]@{ helperEnabled = $false }
    $diagStateFresh = [PSCustomObject]@{ lastRefreshAtUtc = $nowUtc.AddSeconds(-5).ToString("o") }
    $diagStateStale = [PSCustomObject]@{ lastRefreshAtUtc = $nowUtc.AddSeconds(-45).ToString("o") }
    $diagMetricsOk = [PSCustomObject]@{ status = "ok"; confidence = "request-matched"; currentUsageTokens = 12000; currentSavedTokens = 38000 }
    $diagMetricsMissing = [PSCustomObject]@{ status = "missing"; confidence = "missing"; currentUsageTokens = 0; currentSavedTokens = 0 }

    $diagOk = Get-TuhDiagnostic -Config $diagConfigOn -State $diagStateFresh -Metrics $diagMetricsOk -NowUtc $nowUtc
    if ([string]$diagOk.level -ne "ok" -or [string]$diagOk.label -ne "healthy") {
        throw "expected healthy diagnostic, got $($diagOk | ConvertTo-Json -Compress)"
    }

    $diagOff = Get-TuhDiagnostic -Config $diagConfigOff -State $diagStateFresh -Metrics $diagMetricsOk -NowUtc $nowUtc
    if ([string]$diagOff.label -ne "helper off") {
        throw "expected helper off diagnostic, got $($diagOff.label)"
    }

    $diagStale = Get-TuhDiagnostic -Config $diagConfigOn -State $diagStateStale -Metrics $diagMetricsOk -NowUtc $nowUtc
    if ([string]$diagStale.label -ne "stale") {
        throw "expected stale diagnostic, got $($diagStale.label)"
    }

    $diagMissing = Get-TuhDiagnostic -Config $diagConfigOn -State $diagStateFresh -Metrics $diagMetricsMissing -NowUtc $nowUtc
    if ([string]$diagMissing.label -ne "no data") {
        throw "expected no data diagnostic, got $($diagMissing.label)"
    }

    $diagError = Get-TuhDiagnostic -Config $diagConfigOn -State $diagStateFresh -Metrics $diagMetricsOk -RefreshError "boom" -NowUtc $nowUtc
    if ([string]$diagError.label -ne "refresh failed") {
        throw "expected refresh failed diagnostic, got $($diagError.label)"
    }

    $healthData = Join-Path $work "health-data"
    for ($i = 1; $i -le 105; $i++) {
        Write-TuhHealthEvent -DataPath $healthData -Level "warn" -Label "test-$i" -Detail "detail-$i" -ProjectPath $project -Source "test" | Out-Null
    }
    $healthEvents = Read-TuhHealthEvents -DataPath $healthData
    if ($healthEvents.Count -ne 100) {
        throw "expected capped health events 100, got $($healthEvents.Count)"
    }
    if ([string]$healthEvents[0].label -ne "test-6") {
        throw "expected oldest retained health event test-6, got $($healthEvents[0].label)"
    }
    if ([string]$healthEvents[$healthEvents.Count - 1].label -ne "test-105") {
        throw "expected latest health event test-105, got $($healthEvents[$healthEvents.Count - 1].label)"
    }
    $healthCli = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot "token-helper.ps1") health -DataPath $healthData -Json | ConvertFrom-Json
    if ([int]$healthCli.count -ne 100) {
        throw "expected health CLI count 100, got $($healthCli.count)"
    }
    if ([string]$healthCli.events[-1].label -ne "test-105") {
        throw "expected health CLI latest test-105, got $($healthCli.events[-1].label)"
    }
    $pathsCli = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot "token-helper.ps1") paths -DataPath (Join-Path $healthData "custom-state.json") -Json | ConvertFrom-Json
    if ([string]$pathsCli.dataPath -ne [System.IO.Path]::GetFullPath($healthData)) {
        throw "expected paths CLI dataPath $healthData, got $($pathsCli.dataPath)"
    }
    if ([string]$pathsCli.statePath -ne [System.IO.Path]::GetFullPath((Join-Path $healthData "custom-state.json"))) {
        throw "expected paths CLI statePath custom-state.json, got $($pathsCli.statePath)"
    }
    if ([System.IO.Path]::GetFileName([string]$pathsCli.healthEventsPath) -ne "health-events.json") {
        throw "expected health-events.json path, got $($pathsCli.healthEventsPath)"
    }
    $doctorCli = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot "token-helper.ps1") doctor -ProjectPath $project -DataPath $data -Json | ConvertFrom-Json
    if ($null -eq $doctorCli.diagnostic -or [string]::IsNullOrWhiteSpace([string]$doctorCli.diagnostic.label)) {
        throw "doctor CLI did not return diagnostic"
    }
    if ([string]$doctorCli.diagnostic.label -eq "stale") {
        throw "doctor CLI should refresh before diagnosing stale state"
    }
    if (@($doctorCli.checks).Count -lt 5) {
        throw "doctor CLI returned too few checks"
    }
    if ([string]$doctorCli.paths.statePath -ne [System.IO.Path]::GetFullPath((Join-Path $data "state.json"))) {
        throw "doctor CLI returned wrong state path: $($doctorCli.paths.statePath)"
    }
    $doctorGlobal = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot "token-helper.ps1") doctor -ProjectPath $project -DataPath $data -AllProjects -Json | ConvertFrom-Json
    if ([string]$doctorGlobal.scope -ne "all-projects" -or [string]$doctorGlobal.metrics.confidence -notin @("global-history", "global-history+live-session")) {
        throw "global doctor did not use all-project metrics"
    }

    $autoCodexHome = Join-Path $work "codex-home"
    $autoOldProject = Join-Path $work "auto-old-project"
    $autoOldCodex = Join-Path $autoOldProject ".codex"
    New-Item -ItemType Directory -Force -Path $autoCodexHome, $autoOldCodex | Out-Null
    "auto old project" | Set-Content -LiteralPath (Join-Path $autoOldProject "README.md") -Encoding UTF8
    $preExistingClaudeText = "# Existing Claude rules`n`nKeep this project-specific instruction."
    $preExistingClaudePath = Join-Path $autoOldProject "CLAUDE.md"
    $preExistingClaudeText | Set-Content -LiteralPath $preExistingClaudePath -Encoding UTF8
    [PSCustomObject]@{
        projectPath = $autoOldProject
        outputTokens = 1200
        originalTokens = 8000
        savedTokens = 6800
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $autoOldCodex "stats.json") -Encoding UTF8
    $autoHistoryLines = New-Object System.Collections.Generic.List[string]
    foreach ($historyIndex in 1..4) {
        $olderProject = Join-Path $work ("auto-older-project-{0}" -f $historyIndex)
        New-Item -ItemType Directory -Force -Path $olderProject | Out-Null
        "auto older project $historyIndex" | Set-Content -LiteralPath (Join-Path $olderProject "README.md") -Encoding UTF8
        [void]$autoHistoryLines.Add(([PSCustomObject]@{
            generatedAt = (Get-Date).AddMinutes(-10 + $historyIndex).ToUniversalTime().ToString("o")
            conversationName = ("auto-older-{0}" -f $historyIndex)
            projectPath = $olderProject
            originalTokens = 7000 + $historyIndex
            outputTokens = 1000
            savedTokens = 6000 + $historyIndex
            runKind = "actual"
        } | ConvertTo-Json -Compress))
    }
    [void]$autoHistoryLines.Add(([PSCustomObject]@{
        generatedAt = (Get-Date).ToUniversalTime().ToString("o")
        conversationName = "auto-old"
        projectPath = $autoOldProject
        originalTokens = 8000
        outputTokens = 1200
        savedTokens = 6800
        runKind = "actual"
    } | ConvertTo-Json -Compress))
    $autoHistoryLines.ToArray() | Set-Content -LiteralPath (Join-Path $autoCodexHome "codex-token-helper-history.jsonl") -Encoding UTF8

    $install = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot "install.ps1") -InstallRoot $installRoot -NoShortcut -CodexHome $autoCodexHome -MaxAutoAttachProjects 3 -Agents All -SkipAutoAttachContext -DisableAutoAttachFallbackScan | ConvertFrom-Json
    if (-not (Test-Path -LiteralPath (Join-Path $install.binPath "token-helper.ps1") -PathType Leaf)) {
        throw "install did not copy token-helper.ps1"
    }
    foreach ($installedScriptName in @("codex-token-kit.ps1", "codex-slim.ps1", "codex-token-auto-attach.ps1")) {
        if (-not (Test-Path -LiteralPath (Join-Path $install.binPath $installedScriptName) -PathType Leaf)) {
            throw "install did not copy auto attach dependency $installedScriptName"
        }
    }
    foreach ($installedTestName in @("test-token-saver-release.ps1", "codex-context-regression.ps1", "test-token-helper-mvp.ps1", "test-token-helper-panel-smoke.ps1")) {
        if (-not (Test-Path -LiteralPath (Join-Path $install.binPath $installedTestName) -PathType Leaf)) {
            throw "install did not copy release gate dependency $installedTestName"
        }
    }
    foreach ($agentInstallerName in $agentInstallerNames) {
        if (-not (Test-Path -LiteralPath (Join-Path $install.installRoot $agentInstallerName) -PathType Leaf)) {
            throw "install did not copy agent installer $agentInstallerName"
        }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $install.binPath "token-helper.cmd") -PathType Leaf)) {
        throw "install did not create token-helper.cmd"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $install.binPath "token-saver.ico") -PathType Leaf)) {
        throw "install did not generate token-saver.ico"
    }
    if ($null -eq $install.autoAttach -or [string]::IsNullOrWhiteSpace([string]$install.autoAttach.agentsPath)) {
        throw "install did not return autoAttach result"
    }
    $agentsText = Get-Content -LiteralPath (Join-Path $autoCodexHome "AGENTS.md") -Raw
    if ($agentsText -notmatch [regex]::Escape("Token Saver Auto Attach") -or $agentsText -notmatch [regex]::Escape("codex-token-kit.ps1")) {
        throw "install did not write global Token saver AGENTS instructions"
    }
    foreach ($agentRulePath in @(
        (Join-Path $autoOldProject "CLAUDE.md"),
        (Join-Path $autoOldProject ".cursor\rules\token-saver.mdc"),
        (Join-Path $autoOldProject ".aider.token-saver.md"),
        (Join-Path $autoOldProject "TOKEN_SAVER.md")
    )) {
        if (-not (Test-Path -LiteralPath $agentRulePath -PathType Leaf)) {
            throw "install did not write multi-agent Token saver rule: $agentRulePath"
        }
        $agentRuleText = Get-Content -LiteralPath $agentRulePath -Raw
        if ($agentRuleText -notmatch [regex]::Escape("Token Saver Auto Attach")) {
            throw "multi-agent rule missing Token Saver block: $agentRulePath"
        }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $autoOldCodex "config.json") -PathType Leaf) -or -not (Test-Path -LiteralPath (Join-Path $autoOldCodex "state.json") -PathType Leaf)) {
        throw "install auto-attach did not initialize old project .codex config/state"
    }
    if ([int]$install.autoAttach.autoAttachProjectCount -ne 3 -or [int]$install.autoAttach.autoAttachOkCount -ne 3) {
        throw "install auto-attach did not report attached old project"
    }
    $attachedProjectPaths = @($install.autoAttach.attachedProjects | ForEach-Object { [string]$_.projectPath })
    if ([string]$attachedProjectPaths[0] -ne [System.IO.Path]::GetFullPath($autoOldProject)) {
        throw "install auto-attach should process most recent history project first"
    }
    if (@($attachedProjectPaths).Count -ne 3 -or @($attachedProjectPaths | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
        throw "install auto-attach should honor MaxAutoAttachProjects"
    }
    $autoManifest = Get-Content -LiteralPath $install.manifestPath -Raw | ConvertFrom-Json
    if ($null -eq $autoManifest.autoAttach -or @($autoManifest.autoAttach.attachedProjects).Count -lt 1) {
        throw "install manifest should record auto-attach projects for cautious uninstall"
    }
    $autoAttachedRecord = @($autoManifest.autoAttach.attachedProjects | Where-Object { [string]$_.projectPath -eq [System.IO.Path]::GetFullPath($autoOldProject) } | Select-Object -First 1)
    if ($autoAttachedRecord.Count -ne 1 -or @($autoAttachedRecord[0].preExistingFiles) -notcontains "stats.json") {
        throw "auto-attach manifest should remember pre-existing project files"
    }
    if (@($autoAttachedRecord[0].agentRuleFiles).Count -lt 4 -or @($autoManifest.autoAttach.agentRuleFiles).Count -lt 1) {
        throw "auto-attach manifest should record global and project agent rule files"
    }
    $claudeRuleRecord = @($autoAttachedRecord[0].agentRuleFiles | Where-Object { [string]$_.path -eq [System.IO.Path]::GetFullPath($preExistingClaudePath) } | Select-Object -First 1)
    if ($claudeRuleRecord.Count -ne 1 -or -not [bool]$claudeRuleRecord[0].existed) {
        throw "auto-attach manifest should remember pre-existing CLAUDE.md"
    }
    $installedPaths = & (Join-Path $install.binPath "token-helper.cmd") paths -DataPath $data -Json | ConvertFrom-Json
    if ([string]$installedPaths.dataPath -ne [System.IO.Path]::GetFullPath($data)) {
        throw "installed token-helper.cmd paths returned wrong data path: $($installedPaths.dataPath)"
    }
    $installedHealth = & (Join-Path $install.binPath "token-helper.cmd") health -DataPath $healthData -Json | ConvertFrom-Json
    if ([int]$installedHealth.count -ne 100) {
        throw "installed token-helper.cmd health returned wrong count: $($installedHealth.count)"
    }
    $installedDoctor = & (Join-Path $install.binPath "token-helper.cmd") doctor -ProjectPath $project -DataPath $data -Json | ConvertFrom-Json
    if ($null -eq $installedDoctor.diagnostic) {
        throw "installed token-helper.cmd doctor did not return diagnostic"
    }
    $manifest = Get-Content -LiteralPath $install.manifestPath -Raw | ConvertFrom-Json
    foreach ($expectedCommand in @("token-helper config", "token-helper health", "token-helper paths", "token-helper doctor")) {
        if (@($manifest.commands) -notcontains $expectedCommand) {
            throw "install manifest missing command $expectedCommand"
        }
    }

    $uninstallAuto = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot "uninstall.ps1") -InstallRoot $installRoot -RemoveData | ConvertFrom-Json
    if (Test-Path -LiteralPath $installRoot) {
        throw "uninstall did not remove test install root"
    }
    if (-not [bool]$uninstallAuto.removedAgentsBlock) {
        throw "uninstall should remove Token Saver Auto Attach block from AGENTS"
    }
    $agentsAfterUninstall = if (Test-Path -LiteralPath (Join-Path $autoCodexHome "AGENTS.md")) { Get-Content -LiteralPath (Join-Path $autoCodexHome "AGENTS.md") -Raw } else { "" }
    if ($agentsAfterUninstall -match [regex]::Escape("Token Saver Auto Attach")) {
        throw "uninstall left Token Saver Auto Attach block in AGENTS"
    }
    foreach ($agentRulePath in @(
        (Join-Path $autoOldProject "CLAUDE.md"),
        (Join-Path $autoOldProject ".cursor\rules\token-saver.mdc"),
        (Join-Path $autoOldProject ".aider.token-saver.md"),
        (Join-Path $autoOldProject "TOKEN_SAVER.md")
    )) {
        if (Test-Path -LiteralPath $agentRulePath -PathType Leaf) {
            $agentRuleAfter = Get-Content -LiteralPath $agentRulePath -Raw
            if ($agentRuleAfter -match [regex]::Escape("Token Saver Auto Attach")) {
                throw "uninstall left Token Saver block in multi-agent rule: $agentRulePath"
            }
        }
    }
    if ([int]$uninstallAuto.removedAgentRuleFileCount -lt 4) {
        throw "uninstall should report removed multi-agent rule blocks"
    }
    if (-not (Test-Path -LiteralPath $preExistingClaudePath -PathType Leaf)) {
        throw "uninstall should keep pre-existing CLAUDE.md"
    }
    $claudeAfterUninstall = Get-Content -LiteralPath $preExistingClaudePath -Raw
    if ($claudeAfterUninstall -notmatch [regex]::Escape("Keep this project-specific instruction.") -or $claudeAfterUninstall -match [regex]::Escape("Token Saver Auto Attach")) {
        throw "uninstall should preserve user CLAUDE.md content while removing Token Saver block"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $autoOldCodex "stats.json") -PathType Leaf)) {
        throw "uninstall should not remove pre-existing project stats.json"
    }
    if (Test-Path -LiteralPath (Join-Path $autoOldCodex "state.json") -PathType Leaf) {
        throw "uninstall should remove auto-created project state.json"
    }

    $unsafeInstallRoot = Join-Path $work "unsafe-install-root"
    New-Item -ItemType Directory -Force -Path $unsafeInstallRoot | Out-Null
    "do not delete without explicit RemoveData" | Set-Content -LiteralPath (Join-Path $unsafeInstallRoot "sentinel.txt") -Encoding UTF8
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $unsafeUninstallOutput = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot "uninstall.ps1") -InstallRoot $unsafeInstallRoot 2>&1
        $unsafeUninstallExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($unsafeUninstallExitCode -eq 0) {
        throw "uninstall should refuse non-default install roots without -RemoveData"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $unsafeInstallRoot "sentinel.txt") -PathType Leaf)) {
        throw "uninstall refusal should leave non-default install root untouched"
    }
    if (($unsafeUninstallOutput -join "`n") -notmatch [regex]::Escape("Refusing to remove a non-default install root without -RemoveData")) {
        throw "uninstall refusal did not explain non-default install root safety"
    }

    $keepInstallRoot = Join-Path $work "keep-install"
    $keepCodexHome = Join-Path $work "keep-codex-home"
    $keepOldProject = Join-Path $work "keep-old-project"
    $keepOldCodex = Join-Path $keepOldProject ".codex"
    New-Item -ItemType Directory -Force -Path $keepCodexHome, $keepOldCodex | Out-Null
    "keep old project" | Set-Content -LiteralPath (Join-Path $keepOldProject "README.md") -Encoding UTF8
    [PSCustomObject]@{
        generatedAt = (Get-Date).ToUniversalTime().ToString("o")
        conversationName = "keep-old"
        projectPath = $keepOldProject
        originalTokens = 9000
        outputTokens = 1500
        savedTokens = 7500
        runKind = "actual"
    } | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $keepCodexHome "codex-token-helper-history.jsonl") -Encoding UTF8
    $keepInstall = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot "install.ps1") -InstallRoot $keepInstallRoot -NoShortcut -CodexHome $keepCodexHome -MaxAutoAttachProjects 3 -Agents All -SkipAutoAttachContext -DisableAutoAttachFallbackScan | ConvertFrom-Json
    $keepAgentRulePaths = @(
        (Join-Path $keepCodexHome "AGENTS.md"),
        (Join-Path $keepOldProject "CLAUDE.md"),
        (Join-Path $keepOldProject ".cursor\rules\token-saver.mdc"),
        (Join-Path $keepOldProject ".aider.token-saver.md"),
        (Join-Path $keepOldProject "TOKEN_SAVER.md")
    )
    foreach ($keepRulePath in $keepAgentRulePaths) {
        if (-not (Test-Path -LiteralPath $keepRulePath -PathType Leaf)) {
            throw "keep uninstall fixture missing agent rule: $keepRulePath"
        }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $keepOldCodex "config.json") -PathType Leaf) -or -not (Test-Path -LiteralPath (Join-Path $keepOldCodex "state.json") -PathType Leaf)) {
        throw "keep uninstall fixture missing auto-attached project data"
    }
    $keepUninstall = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot "uninstall.ps1") -InstallRoot $keepInstall.installRoot -RemoveData -KeepGlobalAgents -KeepProjectData | ConvertFrom-Json
    if (Test-Path -LiteralPath $keepInstallRoot) {
        throw "keep uninstall should still remove install root when -RemoveData is explicit"
    }
    if ([bool]$keepUninstall.removedAgentsBlock -or [int]$keepUninstall.removedAgentRuleFileCount -ne 0 -or [int]$keepUninstall.removedProjectFileCount -ne 0) {
        throw "keep uninstall should not remove agent rules or project data"
    }
    foreach ($keepRulePath in $keepAgentRulePaths) {
        $keepRuleText = Get-Content -LiteralPath $keepRulePath -Raw
        if ($keepRuleText -notmatch [regex]::Escape("Token Saver Auto Attach")) {
            throw "keep uninstall should preserve Token Saver agent rule: $keepRulePath"
        }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $keepOldCodex "config.json") -PathType Leaf) -or -not (Test-Path -LiteralPath (Join-Path $keepOldCodex "state.json") -PathType Leaf)) {
        throw "keep uninstall should preserve auto-attached project config/state"
    }

    [PSCustomObject]@{
        ok = $true
        testedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        workDir = $work
    } | ConvertTo-Json -Depth 4
}
finally {
    if ($null -eq $previousLiveDisable) {
        Remove-Item Env:\TOKEN_HELPER_DISABLE_LIVE -ErrorAction SilentlyContinue
    }
    else {
        $env:TOKEN_HELPER_DISABLE_LIVE = $previousLiveDisable
    }
    if (Test-Path -LiteralPath $work) {
        Remove-Item -LiteralPath $work -Recurse -Force
    }
}
