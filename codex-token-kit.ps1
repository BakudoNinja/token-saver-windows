param(
    [string]$ProjectPath = ".",
    [int]$MaxChars = -1,
    [string[]]$Include = @(),
    [switch]$SkipAiCodex,
    [switch]$Quiet,
    [string]$PlanName = "",
    [long]$PlanTotalTokens = -1,
    [long]$PlanUsedTokens = -1,
    [switch]$ReadOpenAIUsage,
    [int]$OpenAIUsageDays = 31,
    [string]$OpenAIAdminKeyEnv = "OPENAI_ADMIN_KEY",
    [string]$OpenAIAdminKeyPath = "$env:USERPROFILE\.codex\openai-admin-key.dpapi",
    [string]$ConversationName = "",
    [string]$RunKind = "actual"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = (Get-Item -LiteralPath $ProjectPath).FullName
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$slimScript = Join-Path $scriptRoot "codex-slim.ps1"
$coreScript = Join-Path $scriptRoot "token-helper-core.ps1"
$helperConfig = $null
$autoBudgetMode = ($MaxChars -lt 0)
if (Test-Path -LiteralPath $coreScript -PathType Leaf) {
    . $coreScript
    $projectConfigPath = Join-Path $root ".codex"
    $helperConfig = if (Test-Path -LiteralPath (Get-TuhConfigPath -DataPath $projectConfigPath) -PathType Leaf) {
        Read-TuhConfig -DataPath $projectConfigPath
    }
    else {
        Read-TuhConfig
    }
    if (-not (Get-TuhBool -Value (Get-TuhProp -Object $helperConfig -Name "helperEnabled" -DefaultValue $true) -DefaultValue $true)) {
        if (-not $Quiet) {
            Write-Host "Token saver disabled; skipping context generation."
        }
        return
    }
    if ($autoBudgetMode) {
        $tokenSaverPreflight = Get-TuhProjectMetrics -ProjectPath $root -Config $helperConfig
        $preflightUsage = Get-TuhLong -Value (Get-TuhProp -Object $tokenSaverPreflight -Name "currentUsageTokens" -DefaultValue 0) -DefaultValue 0
        $preflightThreshold = Get-TuhLong -Value (Get-TuhProp -Object $helperConfig -Name "thresholdTokens" -DefaultValue 8000) -DefaultValue 8000
        if ($preflightUsage -gt 0 -and $preflightUsage -lt $preflightThreshold) {
            if (-not $Quiet) {
                Write-Host ("Token saver skipped; estimated usage {0:N0} is below threshold {1:N0}." -f $preflightUsage, $preflightThreshold)
            }
            return
        }
    }
}
if ($MaxChars -lt 0 -and $null -ne $helperConfig) {
    $MaxChars = [int]$helperConfig.contextBudgetChars
}
if ($MaxChars -lt 0) {
    $MaxChars = 12000
}

function Write-Step {
    param([string]$Message)
    if (-not $Quiet) {
        Write-Host $Message
    }
}

function Test-NodeProject {
    param([string]$Path)
    $markers = @("package.json", "tsconfig.json", "next.config.js", "next.config.ts", "vite.config.js", "vite.config.ts", "svelte.config.js")
    foreach ($marker in $markers) {
        if (Test-Path -LiteralPath (Join-Path $Path $marker)) {
            return $true
        }
    }
    return $false
}

Write-Step "项目: $root"

if (-not $SkipAiCodex -and (Test-NodeProject $root)) {
    $npx = Get-Command npx.cmd -ErrorAction SilentlyContinue
    if ($null -eq $npx) {
        $npx = Get-Command npx -ErrorAction SilentlyContinue
    }
    if ($null -ne $npx) {
        Write-Step "检测到 Node/TS 项目，运行 ai-codex 生成 .ai-codex 索引..."
        Push-Location $root
        try {
            & $npx.Source --yes ai-codex --quiet
            if ($LASTEXITCODE -ne 0) {
                Write-Step "ai-codex 退出码 $LASTEXITCODE，继续生成 slim context。"
            }
        }
        finally {
            Pop-Location
        }
    }
    else {
        Write-Step "检测到 Node/TS 项目，但 npx 不可用，跳过 ai-codex。"
    }
}
elseif (-not $SkipAiCodex) {
    Write-Step "未检测到 Node/TS 项目标记，跳过 ai-codex。"
}

Write-Step "生成 .codex/context.md..."
$slimArgs = @(
    "-ExecutionPolicy", "Bypass",
    "-File", $slimScript,
    "-ProjectPath", $root,
    "-MaxChars", $MaxChars
)

if ($Include.Count -gt 0) {
    $slimArgs += "-Include"
    $slimArgs += $Include
}

if (-not [string]::IsNullOrWhiteSpace($PlanName)) {
    $slimArgs += "-PlanName"
    $slimArgs += $PlanName
}
if ($PlanTotalTokens -ge 0) {
    $slimArgs += "-PlanTotalTokens"
    $slimArgs += $PlanTotalTokens
}
if ($PlanUsedTokens -ge 0) {
    $slimArgs += "-PlanUsedTokens"
    $slimArgs += $PlanUsedTokens
}
if ($ReadOpenAIUsage) {
    $slimArgs += "-ReadOpenAIUsage"
    $slimArgs += "-OpenAIUsageDays"
    $slimArgs += $OpenAIUsageDays
    $slimArgs += "-OpenAIAdminKeyEnv"
    $slimArgs += $OpenAIAdminKeyEnv
    $slimArgs += "-OpenAIAdminKeyPath"
    $slimArgs += $OpenAIAdminKeyPath
}
if (-not [string]::IsNullOrWhiteSpace($ConversationName)) {
    $slimArgs += "-ConversationName"
    $slimArgs += $ConversationName
}
$slimArgs += "-RunKind"
$slimArgs += $RunKind

& powershell @slimArgs
if ($LASTEXITCODE -ne 0) {
    throw "codex-slim.ps1 失败，退出码 $LASTEXITCODE"
}

Write-Step ""
Write-Step "完成。下一步给 Codex：先读 .codex/context.md；如果存在 .ai-codex/，先读其中相关索引，再读取具体源码。"
