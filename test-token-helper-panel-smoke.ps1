Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$work = Join-Path $env:TEMP ("token-helper-panel-smoke-" + [Guid]::NewGuid().ToString("N"))
$project = Join-Path $work "project"
$data = Join-Path $work "data"
$codex = Join-Path $project ".codex"
New-Item -ItemType Directory -Force -Path $codex, $data | Out-Null

function Get-PanelProcesses {
    param([string]$Needle)

    return @(Get-CimInstance Win32_Process | Where-Object {
        $_.ProcessId -ne $PID -and
        $_.CommandLine -like "*token-helper-panel.ps1*" -and
        $_.CommandLine -like "*$Needle*" -and
        $_.CommandLine -notlike "*Get-CimInstance*"
    })
}

function Get-RefreshProcesses {
    param([string]$Needle)

    return @(Get-CimInstance Win32_Process | Where-Object {
        $_.ProcessId -ne $PID -and
        $_.CommandLine -like "*token-helper.ps1*" -and
        $_.CommandLine -like "* refresh *" -and
        $_.CommandLine -like "*$Needle*" -and
        $_.CommandLine -notlike "*Get-CimInstance*"
    })
}

try {
    [PSCustomObject]@{
        outputTokens = 1000
        originalTokens = 3000
        savedTokens = 2000
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $codex "stats.json") -Encoding UTF8

    $existingPanels = @(Get-CimInstance Win32_Process | Where-Object {
        $_.ProcessId -ne $PID -and
        $_.CommandLine -like "*token-helper-panel.ps1*" -and
        $_.CommandLine -notlike "*Get-CimInstance*"
    })
    if ($existingPanels.Count -gt 0) {
        [PSCustomObject]@{
            ok = $true
            skipped = $true
            reason = "panel already running; global mutex intentionally allows only one panel"
            existingPanelCount = $existingPanels.Count
        } | ConvertTo-Json -Depth 4
        return
    }

    $first = Start-Process -FilePath powershell.exe -WindowStyle Hidden -PassThru -ArgumentList @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        (Join-Path $scriptRoot "token-helper.ps1"),
        "panel",
        "-ProjectPath",
        $project,
        "-DataPath",
        $data
    )
    $first.WaitForExit(5000) | Out-Null
    if (-not $first.HasExited) {
        throw "token-helper panel command did not return promptly"
    }

    Start-Sleep -Seconds 2
    $panelsAfterFirst = @(Get-PanelProcesses -Needle $project)
    if ($panelsAfterFirst.Count -ne 1) {
        throw "expected one panel process after first launch, got $($panelsAfterFirst.Count)"
    }

    $second = Start-Process -FilePath powershell.exe -WindowStyle Hidden -PassThru -ArgumentList @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        (Join-Path $scriptRoot "token-helper.ps1"),
        "panel",
        "-ProjectPath",
        $project,
        "-DataPath",
        $data
    )
    $second.WaitForExit(5000) | Out-Null
    if (-not $second.HasExited) {
        throw "second token-helper panel command did not return promptly"
    }

    Start-Sleep -Seconds 1
    $panelsAfterSecond = @(Get-PanelProcesses -Needle $project)
    if ($panelsAfterSecond.Count -ne 1) {
        throw "global mutex failed; expected one panel process after second launch, got $($panelsAfterSecond.Count)"
    }
    Stop-Process -Id $panelsAfterSecond[0].ProcessId -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 800
    $leftoverRefresh = @(Get-RefreshProcesses -Needle $project)
    if ($leftoverRefresh.Count -ne 0) {
        throw "panel close left refresh child processes: $($leftoverRefresh.Count)"
    }

    [PSCustomObject]@{
        ok = $true
        skipped = $false
        panelProcessId = $panelsAfterSecond[0].ProcessId
    } | ConvertTo-Json -Depth 4
}
finally {
    Get-PanelProcesses -Needle $project | ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $work) {
        Remove-Item -LiteralPath $work -Recurse -Force
    }
}
