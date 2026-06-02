param(
    [string]$DashboardUrl = "http://127.0.0.1:8805/.codex/dashboard.html",
    [double]$MaxWarmStatsSeconds = 2.0,
    [double]$MaxWarmPageSeconds = 3.0,
    [double]$MaxPingSeconds = 0.5,
    [int]$PingSamples = 3,
    [int]$StatsSamples = 3,
    [int]$PageSamples = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$statsUrl = $DashboardUrl -replace "/\.codex/dashboard\.html$", "/api/stats"
$pingUrl = $DashboardUrl -replace "/\.codex/dashboard\.html$", "/api/ping"
$failures = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]

function Add-Failure {
    param([string]$Message)
    [void]$failures.Add($Message)
}

function Measure-RequestSeconds {
    param(
        [scriptblock]$Block,
        [int]$TimeoutSeconds = 30
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & $Block | Out-Null
    $sw.Stop()
    return [Math]::Round($sw.Elapsed.TotalSeconds, 3)
}

function Measure-RequestOrFail {
    param(
        [scriptblock]$Block,
        [string]$Label,
        [double]$FailureValue = 999.0
    )

    try {
        return (Measure-RequestSeconds -Block $Block)
    }
    catch {
        Add-Failure "${Label} failed: $($_.Exception.Message)"
        return $FailureValue
    }
}

function Get-Percentile {
    param(
        [double[]]$Values,
        [double]$Percentile
    )

    if ($Values.Count -eq 0) {
        return 0.0
    }

    $sorted = @($Values | Sort-Object)
    $index = [Math]::Min($sorted.Count - 1, [Math]::Max(0, [int][Math]::Ceiling(($Percentile / 100.0) * $sorted.Count) - 1))
    return [double]$sorted[$index]
}

function Get-Median {
    param([double[]]$Values)

    if ($Values.Count -eq 0) {
        return 0.0
    }

    $sorted = @($Values | Sort-Object)
    $middle = [int][Math]::Floor($sorted.Count / 2)
    if (($sorted.Count % 2) -eq 1) {
        return [double]$sorted[$middle]
    }
    return [double](($sorted[$middle - 1] + $sorted[$middle]) / 2.0)
}

$pingTimes = New-Object System.Collections.Generic.List[double]
for ($i = 0; $i -lt $PingSamples; $i++) {
    try {
        $seconds = Measure-RequestSeconds -Block {
            $ping = Invoke-RestMethod -Uri $pingUrl -TimeoutSec 10
            if ([string]$ping.status -ne "ok") {
                throw "api/ping did not return ok."
            }
        }
        [void]$pingTimes.Add($seconds)
    }
    catch {
        [void]$warnings.Add("api/ping sample $($i + 1) failed: $($_.Exception.Message)")
    }
    Start-Sleep -Milliseconds 120
}
$pingSeconds = if ($pingTimes.Count -gt 0) { [Math]::Round((@($pingTimes.ToArray()) | Measure-Object -Minimum).Minimum, 3) } else { 999.0 }
if ($pingTimes.Count -eq 0) {
    Add-Failure "all api/ping samples failed."
}

# Warm the server-side stats/object/json cache before measuring the steady state.
$coldStatsSeconds = Measure-RequestOrFail -Label "cold api/stats" -Block {
    Invoke-RestMethod -Uri $statsUrl -TimeoutSec 60
}

if ($pingTimes.Count -gt 0 -and $pingSeconds -gt $MaxPingSeconds) {
    $retryPingTimes = New-Object System.Collections.Generic.List[double]
    for ($i = 0; $i -lt $PingSamples; $i++) {
        try {
            $seconds = Measure-RequestSeconds -Block {
                $ping = Invoke-RestMethod -Uri $pingUrl -TimeoutSec 10
                if ([string]$ping.status -ne "ok") {
                    throw "api/ping did not return ok."
                }
            }
            [void]$retryPingTimes.Add($seconds)
        }
        catch {
            [void]$warnings.Add("api/ping warm retry $($i + 1) failed: $($_.Exception.Message)")
        }
        Start-Sleep -Milliseconds 120
    }
    if ($retryPingTimes.Count -gt 0) {
        $retryBest = [Math]::Round((@($retryPingTimes.ToArray()) | Measure-Object -Minimum).Minimum, 3)
        if ($retryBest -lt $pingSeconds) {
            $pingSeconds = $retryBest
            $pingTimes = $retryPingTimes
        }
    }
}
if ($pingSeconds -gt $MaxPingSeconds) {
    Add-Failure "api/ping best-of-$PingSamples is too slow after warm retry. Actual=${pingSeconds}s Limit=${MaxPingSeconds}s"
}

$statsTimes = New-Object System.Collections.Generic.List[double]
for ($i = 0; $i -lt $StatsSamples; $i++) {
    [void]$statsTimes.Add((Measure-RequestOrFail -Label "warm api/stats sample $($i + 1)" -Block {
        Invoke-RestMethod -Uri $statsUrl -TimeoutSec 30
    }))
    Start-Sleep -Milliseconds 150
}

$pageTimes = New-Object System.Collections.Generic.List[double]
for ($i = 0; $i -lt $PageSamples; $i++) {
    [void]$pageTimes.Add((Measure-RequestOrFail -Label "warm dashboard page sample $($i + 1)" -Block {
        Invoke-WebRequest -Uri $DashboardUrl -UseBasicParsing -TimeoutSec 30
    }))
    Start-Sleep -Milliseconds 150
}

$statsP95 = [Math]::Round((Get-Percentile -Values ([double[]]$statsTimes.ToArray()) -Percentile 95), 3)
$pageP95 = [Math]::Round((Get-Percentile -Values ([double[]]$pageTimes.ToArray()) -Percentile 95), 3)
$statsSteady = [Math]::Round((Get-Median -Values ([double[]]$statsTimes.ToArray())), 3)
$pageSteady = [Math]::Round((Get-Median -Values ([double[]]$pageTimes.ToArray())), 3)

if ($statsSteady -gt $MaxWarmStatsSeconds) {
    Add-Failure "warm api/stats steady median is too slow. Median=${statsSteady}s P95=${statsP95}s Limit=${MaxWarmStatsSeconds}s"
}
if ($pageSteady -gt $MaxWarmPageSeconds) {
    Add-Failure "warm dashboard page steady median is too slow. Median=${pageSteady}s P95=${pageP95}s Limit=${MaxWarmPageSeconds}s"
}

$result = [PSCustomObject]@{
    ok = ($failures.Count -eq 0)
    dashboardUrl = $DashboardUrl
    pingSeconds = $pingSeconds
    pingSamples = @($pingTimes.ToArray())
    coldStatsSeconds = $coldStatsSeconds
    warmStatsSeconds = @($statsTimes.ToArray())
    warmStatsSteadySeconds = $statsSteady
    warmStatsP95Seconds = $statsP95
    warmPageSeconds = @($pageTimes.ToArray())
    warmPageSteadySeconds = $pageSteady
    warmPageP95Seconds = $pageP95
    limits = [PSCustomObject]@{
        maxPingSeconds = $MaxPingSeconds
        maxWarmStatsSeconds = $MaxWarmStatsSeconds
        maxWarmPageSeconds = $MaxWarmPageSeconds
    }
    warnings = @($warnings.ToArray())
    failures = @($failures.ToArray())
}

$result | ConvertTo-Json -Depth 5

if ($failures.Count -gt 0) {
    exit 1
}
