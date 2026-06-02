param(
    [switch]$SkipPanelSmoke,
    [switch]$CloseExistingPanel
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$results = New-Object System.Collections.Generic.List[object]

function Add-ReleaseResult {
    param(
        [string]$Name,
        [string]$Status,
        [string]$Detail = ""
    )

    [void]$results.Add([PSCustomObject]@{
        name = $Name
        status = $Status
        detail = $Detail
    })
}

function Invoke-ReleaseStep {
    param(
        [string]$Name,
        [scriptblock]$Script
    )

    try {
        $detail = & $Script
        Add-ReleaseResult -Name $Name -Status "passed" -Detail ([string]$detail)
    }
    catch {
        Add-ReleaseResult -Name $Name -Status "failed" -Detail $_.Exception.Message
        throw
    }
}

function Get-TokenSaverPanelProcesses {
    return @(Get-CimInstance Win32_Process | Where-Object {
        $_.ProcessId -ne $PID -and
        $_.CommandLine -like "*token-helper-panel.ps1*" -and
        $_.CommandLine -notlike "*Get-CimInstance*"
    })
}

Invoke-ReleaseStep -Name "powershell-parse" -Script {
    $errors = @()
    foreach ($path in @(Get-ChildItem -LiteralPath $scriptRoot -Filter "*.ps1" -File)) {
        $parseErrors = $null
        [System.Management.Automation.PSParser]::Tokenize((Get-Content -LiteralPath $path.FullName -Raw), [ref]$parseErrors) | Out-Null
        foreach ($parseError in @($parseErrors)) {
            $errors += ("{0}: {1}" -f $path.Name, $parseError.Message)
        }
    }
    if ($errors.Count -gt 0) {
        throw ($errors -join "; ")
    }
    "all ps1 files parse"
}

Invoke-ReleaseStep -Name "mvp-regression" -Script {
    $result = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot "test-token-helper-mvp.ps1") | ConvertFrom-Json
    if (-not [bool]$result.ok) {
        throw "MVP regression returned ok=false"
    }
    "ok at $($result.testedAtUtc)"
}

Invoke-ReleaseStep -Name "context-regression" -Script {
    $result = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot "codex-context-regression.ps1") | ConvertFrom-Json
    if (-not [bool]$result.ok) {
        throw "context regression returned ok=false"
    }
    ("cacheHits={0}; cacheSavedTokens={1}; coverageRisk={2}" -f $result.cacheHits, $result.cacheSavedTokens, $result.coverageRisk)
}

if ($SkipPanelSmoke) {
    Add-ReleaseResult -Name "panel-smoke" -Status "skipped" -Detail "SkipPanelSmoke was set"
}
else {
    $existingPanels = @(Get-TokenSaverPanelProcesses)
    if ($existingPanels.Count -gt 0 -and $CloseExistingPanel) {
        foreach ($panel in $existingPanels) {
            Stop-Process -Id $panel.ProcessId -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Milliseconds 500
        $existingPanels = @(Get-TokenSaverPanelProcesses)
    }

    if ($existingPanels.Count -gt 0) {
        Add-ReleaseResult -Name "panel-smoke" -Status "skipped" -Detail "panel already running; rerun with -CloseExistingPanel for full smoke"
    }
    else {
        Invoke-ReleaseStep -Name "panel-smoke" -Script {
            $result = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot "test-token-helper-panel-smoke.ps1") | ConvertFrom-Json
            if (-not [bool]$result.ok) {
                throw "panel smoke returned ok=false"
            }
            if ([bool]$result.skipped) {
                throw "panel smoke unexpectedly skipped"
            }
            "panelProcessId=$($result.panelProcessId)"
        }
    }
}

$failed = @($results.ToArray() | Where-Object { [string]$_.status -eq "failed" })
$summary = [PSCustomObject]@{
    ok = ($failed.Count -eq 0)
    testedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    resultCount = $results.Count
    results = @($results.ToArray())
}

$summary | ConvertTo-Json -Depth 6
if (-not [bool]$summary.ok) {
    exit 1
}
