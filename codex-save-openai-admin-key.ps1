param(
    [string]$OutputPath = "$env:USERPROFILE\.codex\openai-admin-key.dpapi"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$outDir = Split-Path -Parent $OutputPath
if (-not [string]::IsNullOrWhiteSpace($outDir)) {
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
}

Write-Host "请输入新的 OpenAI Admin Key。输入时不会显示字符。"
$secure = Read-Host -AsSecureString "OpenAI Admin Key"

if ($secure.Length -eq 0) {
    throw "没有输入 Admin Key。"
}

$encrypted = $secure | ConvertFrom-SecureString
Set-Content -LiteralPath $OutputPath -Value $encrypted -Encoding ASCII

Write-Host "已加密保存到: $OutputPath"
Write-Host "此文件使用 Windows DPAPI 当前用户加密，仅当前 Windows 用户可解密。"
