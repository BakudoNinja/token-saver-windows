param(
    [string]$ProjectPath = "",
    [string]$CodexHome = "$env:USERPROFILE\.codex",
    [string]$BinPath = "$env:USERPROFILE\.codex\bin",
    [int]$MaxProjects = 25,
    [string[]]$Agents = @("Codex"),
    [switch]$SkipContextGeneration,
    [switch]$DisableFallbackScan,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$coreScript = Join-Path $scriptRoot "token-helper-core.ps1"
if (Test-Path -LiteralPath $coreScript -PathType Leaf) {
    . $coreScript
}

function Write-AutoAttachLog {
    param([string]$Message)
    if (-not $Quiet) {
        Write-Host $Message
    }
}

function Normalize-TokenSaverAgents {
    param([string[]]$AgentNames)

    $result = New-Object System.Collections.Generic.List[string]
    foreach ($name in @($AgentNames)) {
        foreach ($part in ([string]$name -split ",")) {
            $agent = $part.Trim()
            if ([string]::IsNullOrWhiteSpace($agent)) {
                continue
            }
            if ($agent.Equals("All", [System.StringComparison]::OrdinalIgnoreCase)) {
                foreach ($allAgent in @("Codex", "Claude", "Cursor", "Aider", "Generic")) {
                    if (@($result.ToArray()) -notcontains $allAgent) {
                        [void]$result.Add($allAgent)
                    }
                }
                continue
            }
            $canonical = switch -Regex ($agent.ToLowerInvariant()) {
                "^codex$" { "Codex"; break }
                "^claude|claude-code$" { "Claude"; break }
                "^cursor$" { "Cursor"; break }
                "^aider$" { "Aider"; break }
                "^generic|other$" { "Generic"; break }
                default { throw "Unsupported agent adapter: $agent" }
            }
            if (@($result.ToArray()) -notcontains $canonical) {
                [void]$result.Add($canonical)
            }
        }
    }
    if ($result.Count -eq 0) {
        [void]$result.Add("Codex")
    }
    return @($result.ToArray())
}

function Get-TokenSaverAgentBlock {
    param(
        [string]$TokenKitPath,
        [string]$Agent = "Codex"
    )

    $kit = [System.IO.Path]::GetFullPath($TokenKitPath)
    $agentLabel = if ($Agent -eq "Codex") { "Codex" } else { $Agent }
    return @"
<!-- BEGIN TOKEN SAVER AUTO ATTACH -->
## Token Saver Auto Attach

For $agentLabel coding tasks in any project, before broad codebase exploration, run Token saver once for that project unless `.codex/context.md` has already been generated in this session:

```powershell
powershell -ExecutionPolicy Bypass -File $kit -ProjectPath .
```

Then read `.codex/context.md` first and only open specific source files when needed. This makes the project use Token saver and lets the global dashboard measure actual project savings. Do not print saved keys or secrets.
<!-- END TOKEN SAVER AUTO ATTACH -->
"@
}

function Set-TokenSaverBlockInFile {
    param(
        [string]$Path,
        [string]$Block
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $fullPath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $existed = Test-Path -LiteralPath $fullPath -PathType Leaf
    $existing = if ($existed) { Get-Content -LiteralPath $fullPath -Raw } else { "" }
    $pattern = '(?s)<!-- BEGIN TOKEN SAVER AUTO ATTACH -->.*?<!-- END TOKEN SAVER AUTO ATTACH -->'
    $next = if ([regex]::IsMatch($existing, $pattern)) {
        [regex]::Replace($existing, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $Block })
    }
    elseif ([string]::IsNullOrWhiteSpace($existing)) {
        $Block + [Environment]::NewLine
    }
    else {
        $existing.TrimEnd() + [Environment]::NewLine + [Environment]::NewLine + $Block + [Environment]::NewLine
    }
    Set-Content -LiteralPath $fullPath -Value $next -Encoding UTF8
    return [PSCustomObject]@{
        path = $fullPath
        existed = $existed
    }
}

function Install-TokenSaverGlobalAgents {
    param(
        [string]$TargetCodexHome,
        [string]$TokenKitPath,
        [string[]]$AgentNames
    )

    $written = New-Object System.Collections.Generic.List[object]
    if (@($AgentNames) -notcontains "Codex") {
        return @($written.ToArray())
    }
    $codexHomeFull = [System.IO.Path]::GetFullPath($TargetCodexHome)
    New-Item -ItemType Directory -Force -Path $codexHomeFull | Out-Null
    $agentsPath = Join-Path $codexHomeFull "AGENTS.md"
    $block = Get-TokenSaverAgentBlock -TokenKitPath $TokenKitPath -Agent "Codex"
    $record = Set-TokenSaverBlockInFile -Path $agentsPath -Block $block
    $record | Add-Member -NotePropertyName agent -NotePropertyValue "Codex" -Force
    $record | Add-Member -NotePropertyName scope -NotePropertyValue "global" -Force
    [void]$written.Add($record)
    return @($written.ToArray())
}

function Install-TokenSaverProjectAgentRules {
    param(
        [string]$TargetProjectPath,
        [string]$TokenKitPath,
        [string[]]$AgentNames
    )

    $project = [System.IO.Path]::GetFullPath($TargetProjectPath)
    $written = New-Object System.Collections.Generic.List[object]
    $targets = @(
        [PSCustomObject]@{ agent = "Claude"; path = (Join-Path $project "CLAUDE.md") },
        [PSCustomObject]@{ agent = "Cursor"; path = (Join-Path $project ".cursor\rules\token-saver.mdc") },
        [PSCustomObject]@{ agent = "Aider"; path = (Join-Path $project ".aider.token-saver.md") },
        [PSCustomObject]@{ agent = "Generic"; path = (Join-Path $project "TOKEN_SAVER.md") }
    )
    foreach ($target in $targets) {
        if (@($AgentNames) -notcontains [string]$target.agent) {
            continue
        }
        $block = Get-TokenSaverAgentBlock -TokenKitPath $TokenKitPath -Agent ([string]$target.agent)
        $record = Set-TokenSaverBlockInFile -Path ([string]$target.path) -Block $block
        $record | Add-Member -NotePropertyName agent -NotePropertyValue ([string]$target.agent) -Force
        $record | Add-Member -NotePropertyName scope -NotePropertyValue "project" -Force
        [void]$written.Add($record)
    }
    return @($written.ToArray())
}

function Add-CandidatePath {
    param(
        [System.Collections.Generic.List[string]]$List,
        [hashtable]$Seen,
        [string]$Path,
        [bool]$SkipTempProjects = $false
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }
    try {
        $full = [System.IO.Path]::GetFullPath($Path.Trim('"'))
        if (-not (Test-Path -LiteralPath $full -PathType Container)) {
            return
        }
        if ($SkipTempProjects) {
            $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\')
            if ($full.TrimEnd('\').ToLowerInvariant().StartsWith($tempRoot.ToLowerInvariant())) {
                return
            }
        }
        $lower = $full.ToLowerInvariant()
        if ($Seen.ContainsKey($lower)) {
            return
        }
        $Seen[$lower] = $true
        [void]$List.Add($full)
    }
    catch {
    }
}

function Get-TokenSaverCandidateProjects {
    param(
        [string]$TargetCodexHome,
        [string]$ExplicitProjectPath,
        [int]$Limit,
        [bool]$AllowFallbackScan = $true
    )

    $items = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    $realCodexHome = [System.IO.Path]::GetFullPath("$env:USERPROFILE\.codex").ToLowerInvariant()
    $currentCodexHome = [System.IO.Path]::GetFullPath($TargetCodexHome).ToLowerInvariant()
    $skipTempProjects = ($currentCodexHome -eq $realCodexHome)
    Add-CandidatePath -List $items -Seen $seen -Path $ExplicitProjectPath -SkipTempProjects:$false

    $historyPath = Join-Path $TargetCodexHome "codex-token-helper-history.jsonl"
    if (Test-Path -LiteralPath $historyPath -PathType Leaf) {
        foreach ($line in @(Get-Content -LiteralPath $historyPath -Tail 300 -ErrorAction SilentlyContinue)) {
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }
            try {
                $entry = $line | ConvertFrom-Json
                Add-CandidatePath -List $items -Seen $seen -Path ([string](Get-TuhProp -Object $entry -Name "projectPath" -DefaultValue "")) -SkipTempProjects:$skipTempProjects
            }
            catch {
            }
            if ($items.Count -ge $Limit) {
                return @($items.ToArray())
            }
        }
    }

    $python = Get-Command python -ErrorAction SilentlyContinue
    $sqlitePath = Join-Path $TargetCodexHome "logs_2.sqlite"
    if ($null -ne $python -and (Test-Path -LiteralPath $sqlitePath -PathType Leaf)) {
        $py = @'
import os, re, sqlite3, sys
path = sys.argv[1]
limit = int(sys.argv[2])
seen = set()
try:
    con = sqlite3.connect(path)
    cur = con.cursor()
    rows = cur.execute("select feedback_log_body from logs where feedback_log_body like '%cwd=%' order by id desc limit 4000")
    for (body,) in rows:
        if not body:
            continue
        for match in re.finditer(r"cwd=([A-Za-z]:\\[^}:]+)", str(body)):
            p = match.group(1).strip().strip('"')
            key = p.lower()
            if key in seen:
                continue
            seen.add(key)
            print(p)
            if len(seen) >= limit:
                raise SystemExit(0)
finally:
    try:
        con.close()
    except Exception:
        pass
'@
        try {
            $paths = @($py | & $python.Source - $sqlitePath $Limit 2>$null)
            foreach ($path in $paths) {
                Add-CandidatePath -List $items -Seen $seen -Path $path -SkipTempProjects:$skipTempProjects
                if ($items.Count -ge $Limit) {
                    return @($items.ToArray())
                }
            }
        }
        catch {
        }
    }

    if (-not $AllowFallbackScan) {
        return @($items.ToArray())
    }

    $documents = [Environment]::GetFolderPath("MyDocuments")
    foreach ($root in @($documents, (Join-Path $documents "Codex"))) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            continue
        }
        foreach ($dir in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 80)) {
            $hasMarker = $false
            foreach ($marker in @(".git", ".codex", "package.json", "pyproject.toml", "README.md", "AGENTS.md")) {
                if (Test-Path -LiteralPath (Join-Path $dir.FullName $marker)) {
                    $hasMarker = $true
                    break
                }
            }
            if ($hasMarker) {
                Add-CandidatePath -List $items -Seen $seen -Path $dir.FullName -SkipTempProjects:$skipTempProjects
            }
            if ($items.Count -ge $Limit) {
                return @($items.ToArray())
            }
        }
    }

    return @($items.ToArray())
}

function Invoke-TokenSaverAttachProject {
    param(
        [string]$TargetProjectPath,
        [string]$TokenHelperScript,
        [string]$TokenKitScript,
        [bool]$GenerateContext,
        [string[]]$AgentNames
    )

    $project = [System.IO.Path]::GetFullPath($TargetProjectPath)
    $codexDir = Join-Path $project ".codex"
    $codexDirExisted = Test-Path -LiteralPath $codexDir -PathType Container
    $managedFileNames = @("config.json", "state.json", "context.md", "stats.json")
    $preExistingFiles = New-Object System.Collections.Generic.List[string]
    foreach ($fileName in $managedFileNames) {
        if (Test-Path -LiteralPath (Join-Path $codexDir $fileName) -PathType Leaf) {
            [void]$preExistingFiles.Add($fileName)
        }
    }
    New-Item -ItemType Directory -Force -Path $codexDir | Out-Null

    $result = [ordered]@{
        projectPath = $project
        codexDir = $codexDir
        codexDirExisted = $codexDirExisted
        preExistingFiles = @($preExistingFiles.ToArray())
        managedFiles = $managedFileNames
        agentRuleFiles = @()
        configOk = $false
        refreshOk = $false
        contextOk = $false
        skippedContext = -not $GenerateContext
        error = ""
    }

    try {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $TokenHelperScript config -DataPath $codexDir -HelperEnabled true -Json | Out-Null
        $result.configOk = $true
        $result.agentRuleFiles = @(Install-TokenSaverProjectAgentRules -TargetProjectPath $project -TokenKitPath $TokenKitScript -AgentNames $AgentNames)
        & powershell -NoProfile -ExecutionPolicy Bypass -File $TokenHelperScript refresh -ProjectPath $project -DataPath $codexDir -Json | Out-Null
        $result.refreshOk = $true
        if ($GenerateContext) {
            & powershell -NoProfile -ExecutionPolicy Bypass -File $TokenKitScript -ProjectPath $project -SkipAiCodex -Quiet -RunKind actual | Out-Null
            $result.contextOk = Test-Path -LiteralPath (Join-Path $codexDir "context.md") -PathType Leaf
        }
    }
    catch {
        $result.error = $_.Exception.Message
    }

    return [PSCustomObject]$result
}

$bin = [System.IO.Path]::GetFullPath($BinPath)
$tokenHelperScript = Join-Path $bin "token-helper.ps1"
$tokenKitScript = Join-Path $bin "codex-token-kit.ps1"
if (-not (Test-Path -LiteralPath $tokenHelperScript -PathType Leaf)) {
    $tokenHelperScript = Join-Path $scriptRoot "token-helper.ps1"
}
if (-not (Test-Path -LiteralPath $tokenKitScript -PathType Leaf)) {
    $tokenKitScript = Join-Path $scriptRoot "codex-token-kit.ps1"
}

$agentNames = Normalize-TokenSaverAgents -AgentNames $Agents
$globalAgentRuleFiles = @(Install-TokenSaverGlobalAgents -TargetCodexHome $CodexHome -TokenKitPath $tokenKitScript -AgentNames $agentNames)
$projects = Get-TokenSaverCandidateProjects -TargetCodexHome $CodexHome -ExplicitProjectPath $ProjectPath -Limit $MaxProjects -AllowFallbackScan:(-not $DisableFallbackScan)
$attached = New-Object System.Collections.Generic.List[object]
foreach ($project in $projects) {
    Write-AutoAttachLog "Attaching Token saver: $project"
    [void]$attached.Add((Invoke-TokenSaverAttachProject -TargetProjectPath $project -TokenHelperScript $tokenHelperScript -TokenKitScript $tokenKitScript -GenerateContext:(-not $SkipContextGeneration) -AgentNames $agentNames))
}

$okCount = @($attached.ToArray() | Where-Object { [bool]$_.configOk -and [bool]$_.refreshOk }).Count
$result = [PSCustomObject]@{
    ok = $true
    codexHome = [System.IO.Path]::GetFullPath($CodexHome)
    agentsPath = if ($globalAgentRuleFiles.Count -gt 0) { [string]$globalAgentRuleFiles[0].path } else { "" }
    agents = @($agentNames)
    agentRuleFiles = @($globalAgentRuleFiles)
    autoAttachProjectCount = $attached.Count
    autoAttachOkCount = $okCount
    attachedProjects = @($attached.ToArray())
}

$result | ConvertTo-Json -Depth 8
