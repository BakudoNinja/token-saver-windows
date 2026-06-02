param(
    [string]$ProjectPath = ".",
    [int]$Port = 8766,
    [switch]$NoOpen,
    [switch]$KeepExisting
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = (Get-Item -LiteralPath $ProjectPath).FullName
$dashboard = Join-Path $root ".codex/dashboard.html"
$dashboardUrlFile = Join-Path $root ".codex/dashboard-url.txt"
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$serverScript = [System.IO.Path]::GetFullPath((Join-Path $scriptRoot "codex-dashboard-server.ps1"))

if (-not (Test-Path -LiteralPath $dashboard)) {
    throw "没有找到 $dashboard。请先运行 codex-token-kit.ps1 生成仪表盘。"
}

function Get-FreePort {
    param([int]$StartPort)

    for ($port = $StartPort; $port -lt ($StartPort + 40); $port++) {
        $tcpListener = $null
        $httpListener = $null
        try {
            $tcpListener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Parse("127.0.0.1"), $port)
            $tcpListener.Start()
            $tcpListener.Stop()
            $tcpListener = $null

            $httpListener = [System.Net.HttpListener]::new()
            $httpListener.Prefixes.Add("http://127.0.0.1:$port/")
            $httpListener.Start()
            return $port
        }
        catch {
        }
        finally {
            if ($null -ne $httpListener) {
                $httpListener.Close()
            }
            if ($null -ne $tcpListener) {
                $tcpListener.Stop()
            }
        }
    }

    throw "没有找到可用端口。"
}

function Test-DashboardReady {
    param(
        [string]$Url,
        [System.Diagnostics.Process]$Process,
        [int]$MaxAttempts = 80
    )

    $apiUrl = $Url -replace "/\.codex/dashboard\.html$", "/api/ping"
    for ($i = 0; $i -lt $MaxAttempts; $i++) {
        if ($Process.HasExited) {
            return $false
        }

        try {
            $apiProbe = Invoke-RestMethod -Uri $apiUrl -TimeoutSec 3
            if ($null -ne $apiProbe -and [string]$apiProbe.status -eq "ok" -and [string]$apiProbe.projectPath -eq $root) {
                return $true
            }
        }
        catch {
        }

        Start-Sleep -Milliseconds 500
    }

    return $false
}

function Get-LogTailText {
    param(
        [string]$Path,
        [int]$LineCount = 8,
        [int]$MaxChars = 600
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ""
    }

    try {
        $text = (Get-Content -LiteralPath $Path -Tail $LineCount -ErrorAction Stop) -join " "
        $text = [regex]::Replace([string]$text, "\s+", " ").Trim()
        if ($text.Length -gt $MaxChars) {
            return $text.Substring(0, $MaxChars) + "..."
        }
        return $text
    }
    catch {
        return ""
    }
}

function Quote-PowerShellSingle {
    param([string]$Value)
    return "'" + ([string]$Value).Replace("'", "''") + "'"
}

function Start-DetachedDashboardServer {
    param(
        [string]$ServerScript,
        [string]$ProjectRoot,
        [int]$ServerPort,
        [string]$OutLog,
        [string]$ErrLog
    )

    $scriptCommand = "& " + (Quote-PowerShellSingle $ServerScript) +
        " -ProjectPath " + (Quote-PowerShellSingle $ProjectRoot) +
        " -Port $ServerPort *> " + (Quote-PowerShellSingle $OutLog) +
        " 2> " + (Quote-PowerShellSingle $ErrLog)
    $commandLine = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "' + $scriptCommand.Replace('"', '\"') + '"'
    $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $commandLine; CurrentDirectory = $ProjectRoot }
    if ([int]$result.ReturnValue -ne 0 -or [int]$result.ProcessId -le 0) {
        throw "无法启动 dashboard server，Win32_Process.Create 返回 $($result.ReturnValue)。"
    }

    Start-Sleep -Milliseconds 100
    return [System.Diagnostics.Process]::GetProcessById([int]$result.ProcessId)
}

function Get-ProjectDashboardServers {
    param([int]$TargetPort = -1)

    return @(
        Get-CimInstance Win32_Process -Filter "name = 'powershell.exe'" |
            Where-Object {
                $_.ProcessId -ne $PID -and
                $_.CommandLine -like "*codex-dashboard-server.ps1*" -and
                $_.CommandLine -like "*$escapedServerScript*" -and
                $_.CommandLine -like "*$escapedRoot*" -and
                ($TargetPort -lt 0 -or $_.CommandLine -like "*-Port $TargetPort*")
            }
    )
}

function Test-ExistingDashboardReusable {
    param([string]$Url)

    try {
        $statsUrl = $Url -replace "/\.codex/dashboard\.html$", "/api/stats"
        $healthUrl = $Url -replace "/\.codex/dashboard\.html$", "/api/health"
        $existingStats = Invoke-RestMethod -Uri $statsUrl -TimeoutSec 10
        if ($null -eq $existingStats -or [string]$existingStats.projectPath -ne $root) {
            return $false
        }

        $health = Invoke-RestMethod -Uri $healthUrl -TimeoutSec 10
        if ($null -eq $health -or [string]$health.status -eq "error") {
            return $false
        }
        if (-not ($health.PSObject.Properties.Name -contains "summary")) {
            return $false
        }
        if (-not ($health.summary.PSObject.Properties.Name -contains "serverStaleAfterScriptUpdate")) {
            return $false
        }
        if ([bool]$health.summary.serverStaleAfterScriptUpdate) {
            return $false
        }

        return $true
    }
    catch {
        return $false
    }
}

$escapedServerScript = [System.IO.Path]::GetFullPath($serverScript)
$escapedRoot = [System.IO.Path]::GetFullPath($root)
$existingUrl = "http://127.0.0.1:$Port/.codex/dashboard.html"
if (Test-ExistingDashboardReusable -Url $existingUrl) {
    Set-Content -LiteralPath $dashboardUrlFile -Value $existingUrl -Encoding UTF8
    if (-not $NoOpen) {
        Start-Process $existingUrl
    }
    Write-Output $existingUrl
    return
}

if (-not $KeepExisting) {
    @(Get-ProjectDashboardServers -TargetPort $Port) | ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }

    for ($i = 0; $i -lt 20; $i++) {
        $stillRunning = @(Get-ProjectDashboardServers -TargetPort $Port)
        if ($stillRunning.Count -eq 0) {
            break
        }
        Start-Sleep -Milliseconds 150
    }
}
else {
    if (Test-ExistingDashboardReusable -Url $existingUrl) {
        try {
            $existingProbe = Invoke-WebRequest -Uri $existingUrl -UseBasicParsing -TimeoutSec 5
            if ($existingProbe.StatusCode -eq 200) {
                Set-Content -LiteralPath $dashboardUrlFile -Value $existingUrl -Encoding UTF8
                if (-not $NoOpen) {
                    Start-Process $existingUrl
                }
                Write-Output $existingUrl
                return
            }
        }
        catch {
        }
    }
}

$logDir = Join-Path $root ".codex"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

$attempts = New-Object System.Collections.Generic.List[string]
$attemptDetails = New-Object System.Collections.Generic.List[object]
$server = $null
$url = ""
$ready = $false
$nextPort = $Port
for ($attempt = 0; $attempt -lt 4 -and -not $ready; $attempt++) {
    $freePort = Get-FreePort $nextPort
    $nextPort = $freePort + 1
    $url = "http://127.0.0.1:$freePort/.codex/dashboard.html"
    [void]$attempts.Add([string]$freePort)
    $outLog = Join-Path $logDir "dashboard-server-$freePort.out.log"
    $errLog = Join-Path $logDir "dashboard-server-$freePort.err.log"
    Remove-Item -LiteralPath $outLog, $errLog -ErrorAction SilentlyContinue

    $server = Start-DetachedDashboardServer -ServerScript $escapedServerScript -ProjectRoot $escapedRoot -ServerPort $freePort -OutLog $outLog -ErrLog $errLog

    $ready = Test-DashboardReady -Url $url -Process $server
    if (-not $ready) {
        $reason = if ($server.HasExited) { "进程退出 code $($server.ExitCode)" } else { "健康检查超时" }
        $errTail = Get-LogTailText -Path $errLog
        $outTail = Get-LogTailText -Path $outLog
        [void]$attemptDetails.Add([PSCustomObject]@{
            port = $freePort
            reason = $reason
            errLog = $errLog
            outLog = $outLog
            error = $errTail
            output = $outTail
        })
        Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 400
    }
}

if (-not $ready) {
    $detail = (@($attemptDetails.ToArray()) | ForEach-Object {
        $msg = "端口 $($_.port): $($_.reason)"
        if (-not [string]::IsNullOrWhiteSpace([string]$_.error)) {
            $msg += "；错误：$($_.error)"
        }
        elseif (-not [string]::IsNullOrWhiteSpace([string]$_.output)) {
            $msg += "；输出：$($_.output)"
        }
        $msg += "；日志：$($_.errLog)"
        $msg
    }) -join " | "
    throw "dashboard 服务启动失败或端口未响应。已尝试端口: $($attempts -join ', ')。$detail"
}

if (-not $NoOpen) {
    Start-Process $url
}

Set-Content -LiteralPath $dashboardUrlFile -Value $url -Encoding UTF8
if ($url -ne $existingUrl) {
    Write-Warning "请求端口 $Port 当前不可用或不健康，dashboard 已切到 $url。最新地址已写入 $dashboardUrlFile。"
}
Write-Output $url
