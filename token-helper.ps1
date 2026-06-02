param(
    [ValidateSet("status", "refresh", "reset", "config", "panel", "health", "paths", "doctor")]
    [string]$Command = "status",
    [string]$ProjectPath = ".",
    [string]$DataPath = "",
    [string]$ContextPath = "",
    [string]$LogPath = "",
    [long]$ManualUsageTokens = -1,
    [long]$ManualSavedTokens = -1,
    [string]$HelperEnabled = "",
    [int]$ThresholdTokens = -1,
    [int]$ContextBudgetChars = -1,
    [switch]$AllProjects,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot "token-helper-core.ps1")

function Write-TuhResult {
    param(
        [object]$Value,
        [switch]$AsJson
    )

    if ($AsJson) {
        $Value | ConvertTo-Json -Depth 20
        return
    }

    $config = $Value.config
    $state = $Value.state
    $metrics = $Value.metrics
    $deltas = $Value.deltas
    if ($null -eq $state) {
        $state = $Value
    }

    Write-Host "Token Usage Helper"
    if ($null -ne $metrics) {
        $scope = [string](Get-TuhProp -Object $metrics -Name "scope" -DefaultValue "project")
        if ($scope -eq "all-projects") {
            Write-Host "Scope:   all Codex projects"
        }
        else {
            Write-Host ("Project: {0}" -f $metrics.projectPath)
        }
        Write-Host ("Source:  {0} ({1})" -f $metrics.source, $metrics.confidence)
    }
    $displayUsage = if ($null -ne $metrics) { [long]$metrics.currentUsageTokens } else { [long]$state.currentUsageTokens }
    $displaySaved = if ($null -ne $metrics) { [long]$metrics.currentSavedTokens } else { [long]$state.currentSavedTokens }
    Write-Host ("Current usage:     {0:N0} tokens" -f $displayUsage)
    Write-Host ("Current savings:   {0:N0} tokens" -f $displaySaved)
    Write-Host ("Cumulative usage:  {0:N0} tokens" -f [long]$state.cumulativeUsageTokens)
    Write-Host ("Cumulative saved:  {0:N0} tokens" -f [long]$state.cumulativeSavedTokens)
    if ($null -ne $deltas) {
        Write-Host ("This refresh:      +{0:N0} usage / +{1:N0} saved" -f [long]$deltas.usageTokens, [long]$deltas.savedTokens)
    }
    if ($null -ne $config) {
        Write-Host ("Helper:            {0}" -f $(if ($config.helperEnabled) { "on" } else { "off" }))
        Write-Host ("Threshold:         {0:N0} tokens" -f [int]$config.thresholdTokens)
        Write-Host ("Context budget:    {0:N0} chars" -f [int]$config.contextBudgetChars)
        Write-Host ("Data path:         {0}" -f $config.dataPath)
    }
    if ($null -ne $metrics -and $metrics.notes.Count -gt 0) {
        Write-Host "Notes:"
        foreach ($note in $metrics.notes) {
            Write-Host ("- {0}" -f $note)
        }
    }
}

switch ($Command) {
    "refresh" {
        $result = Update-TuhState -ProjectPath $ProjectPath -DataPath $DataPath -ContextPath $ContextPath -LogPath $LogPath -ManualUsageTokens $ManualUsageTokens -ManualSavedTokens $ManualSavedTokens -AllProjects:$AllProjects
        Write-TuhResult -Value $result -AsJson:$Json
    }
    "status" {
        $config = Read-TuhConfig -DataPath $DataPath
        $stateDataPath = if ([string]::IsNullOrWhiteSpace($DataPath)) { [string]$config.dataPath } else { $DataPath }
        $state = Read-TuhState -DataPath $stateDataPath
        $manualMode = ($ManualUsageTokens -ge 0 -or $ManualSavedTokens -ge 0)
        $metrics = if ($AllProjects -and -not $manualMode) {
            Get-TuhGlobalMetrics -ProjectPath $ProjectPath -Config $config -ContextPath $ContextPath -LogPath $LogPath
        }
        else {
            Get-TuhProjectMetrics -ProjectPath $ProjectPath -Config $config -ContextPath $ContextPath -LogPath $LogPath -ManualUsageTokens $ManualUsageTokens -ManualSavedTokens $ManualSavedTokens
        }
        $result = [PSCustomObject]@{
            ok = $true
            config = $config
            state = $state
            metrics = $metrics
            deltas = $null
        }
        Write-TuhResult -Value $result -AsJson:$Json
    }
    "reset" {
        $state = Reset-TuhState -DataPath $DataPath
        $result = [PSCustomObject]@{
            ok = $true
            message = "state reset"
            state = $state
        }
        if ($Json) {
            $result | ConvertTo-Json -Depth 20
        }
        else {
            Write-Host "Token Usage Helper state reset."
        }
    }
    "config" {
        $config = Read-TuhConfig -DataPath $DataPath
        $changed = $false
        if (-not [string]::IsNullOrWhiteSpace($HelperEnabled)) {
            $config.helperEnabled = Get-TuhBool -Value $HelperEnabled -DefaultValue $config.helperEnabled
            $changed = $true
        }
        if ($ThresholdTokens -ge 0) {
            $config.thresholdTokens = $ThresholdTokens
            $changed = $true
        }
        if ($ContextBudgetChars -ge 0) {
            $config.contextBudgetChars = $ContextBudgetChars
            $changed = $true
        }
        if ($changed) {
            $config = Save-TuhConfig -Config $config -DataPath $DataPath
        }
        if ($Json) {
            $config | ConvertTo-Json -Depth 20
        }
        else {
            Write-Host "Token Usage Helper config"
            Write-Host ("Helper:    {0}" -f $(if ($config.helperEnabled) { "on" } else { "off" }))
            Write-Host ("Threshold: {0:N0} tokens" -f [int]$config.thresholdTokens)
            Write-Host ("Budget:    {0:N0} chars" -f [int]$config.contextBudgetChars)
            Write-Host ("Data path: {0}" -f $config.dataPath)
        }
    }
    "health" {
        $events = Read-TuhHealthEvents -DataPath $DataPath
        $result = [PSCustomObject]@{
            ok = $true
            count = $events.Count
            events = @($events.ToArray())
        }
        if ($Json) {
            $result | ConvertTo-Json -Depth 20
        }
        else {
            Write-Host "Token Usage Helper health events"
            if ($events.Count -eq 0) {
                Write-Host "No health events recorded."
            }
            else {
                foreach ($event in @($events.ToArray())) {
                    Write-Host ("[{0}] {1} {2}: {3}" -f $event.atUtc, $event.level, $event.label, $event.detail)
                }
            }
        }
    }
    "paths" {
        $dataRoot = Resolve-TuhDataPath -DataPath $DataPath
        $result = [PSCustomObject]@{
            ok = $true
            dataPath = $dataRoot
            statePath = Get-TuhStatePath -DataPath $DataPath
            configPath = Get-TuhConfigPath -DataPath $DataPath
            healthEventsPath = Get-TuhHealthEventsPath -DataPath $DataPath
        }
        if ($Json) {
            $result | ConvertTo-Json -Depth 20
        }
        else {
            Write-Host "Token Usage Helper paths"
            Write-Host ("Data path:         {0}" -f $result.dataPath)
            Write-Host ("State:             {0}" -f $result.statePath)
            Write-Host ("Config:            {0}" -f $result.configPath)
            Write-Host ("Health events:     {0}" -f $result.healthEventsPath)
        }
    }
    "doctor" {
        $result = Invoke-TuhDoctor -ProjectPath $ProjectPath -DataPath $DataPath -ContextPath $ContextPath -LogPath $LogPath -AllProjects:$AllProjects
        if ($Json) {
            $result | ConvertTo-Json -Depth 20
        }
        else {
            Write-Host "Token Usage Helper doctor"
            Write-Host ("Overall:           {0}" -f $(if ($result.ok) { "ok" } else { "needs attention" }))
            Write-Host ("Diagnostic:        {0} / {1}" -f $result.diagnostic.level, $result.diagnostic.label)
            Write-Host ("Data path:         {0}" -f $result.paths.dataPath)
            foreach ($check in @($result.checks)) {
                Write-Host ("[{0}] {1}: {2}" -f $(if ($check.ok) { "ok" } else { "fail" }), $check.name, $check.detail)
            }
        }
    }
    "panel" {
        $panel = Join-Path $scriptRoot "token-helper-panel.ps1"
        $panelArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $panel, "-ProjectPath", $ProjectPath)
        if (-not [string]::IsNullOrWhiteSpace($DataPath)) {
            $panelArgs += @("-DataPath", $DataPath)
        }
        $panelArgs += "-AllProjects"
        Start-Process -FilePath powershell.exe -WindowStyle Hidden -ArgumentList $panelArgs | Out-Null
    }
}
