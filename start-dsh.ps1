#requires -Version 5.1
<#
.SYNOPSIS
启动 DeepSeek Harness（DSH）Web 界面。

.DESCRIPTION
本脚本启动 DSH 的 web profile（等价于执行官网命令 `npx @deepseek-ai/dsh web`），并自动打开浏览器访问
http://127.0.0.1:3080（端口可通过 -Port 修改）。

- 若目标端口已有 DSH Web 实例在运行，脚本不会重复启动，只会打开浏览器。
- 启动前检查北京时间是否处于高峰时段（9:00-12:00、14:00-18:00）；若处于高峰时段，会提示"当前为高峰时段，是否继续进入"，输入 y 继续、n 退出；非高峰时段直接启动。
- 默认前台运行：日志直接输出到当前终端，按 Ctrl+C 停止服务。
- 使用 -Background 可后台运行（日志写入 %USERPROFILE%\.dsh\logs，并打印 PID 与停止命令）。
- 工作目录会自动切换到本脚本所在目录（D:\CODE），DSH 会话按该目录归类。

.PARAMETER Port
监听端口，默认 3080（DSH 默认端口）；传 0 表示由系统自动分配。

.PARAMETER BindHost
绑定地址，默认 127.0.0.1（仅本机可访问，安全默认值）。

.PARAMETER TrustedHost
额外信任的浏览器来源，对应 dsh 的 --trusted-host（host 或 host:port）。

.PARAMETER NoBrowser
启动后不自动打开浏览器。

.PARAMETER Background
后台启动：立即返回，日志写入文件。

.EXAMPLE
.\start-dsh.ps1

.EXAMPLE
.\start-dsh.ps1 -Port 8080 -NoBrowser

.EXAMPLE
.\start-dsh.ps1 -Background
#>
[CmdletBinding()]
param(
    [int]$Port = 3080,
    [string]$BindHost = '127.0.0.1',
    [string]$TrustedHost = '',
    [switch]$NoBrowser,
    [switch]$Background
)

$ErrorActionPreference = 'Stop'

# 工作目录固定为脚本所在目录（DSH 会话按该目录归类）
Set-Location -LiteralPath $PSScriptRoot

if ($Port -gt 0) {
    $webUrl = "http://${BindHost}:${Port}"
} else {
    $webUrl = $null
}

function Test-PortOpen {
    param([string]$HostName, [int]$PortNumber)
    if ($PortNumber -le 0) { return $false }
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($HostName, $PortNumber, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne(500, $false)) {
            $client.EndConnect($iar)
            return $true
        }
        return $false
    }
    catch { return $false }
    finally { $client.Dispose() }
}

function Resolve-DshCommand {
    # 官网快速开始命令：npx @deepseek-ai/dsh web
    $npx = Get-Command 'npx.cmd' -CommandType Application -ErrorAction SilentlyContinue
    if (-not $npx) { $npx = Get-Command 'npx' -CommandType Application -ErrorAction SilentlyContinue }
    if ($npx) { return @{ Exe = $npx.Source; Args = @('@deepseek-ai/dsh') } }
    # 回退：PATH 中已安装的 dsh（仅当 npx 不可用时）
    $cmd = Get-Command 'dsh.cmd' -CommandType Application -ErrorAction SilentlyContinue
    if (-not $cmd) { $cmd = Get-Command 'dsh' -CommandType Application -ErrorAction SilentlyContinue }
    if ($cmd) { return @{ Exe = $cmd.Source; Args = @() } }
    throw '未找到 npx 或 dsh 命令，请先安装 Node.js。'
}

function Test-BeijingPeakHours {
    # 北京时间 = UTC+8（中国无夏令时），与本地机器时区无关。
    # 高峰时段：9:00-12:00 与 14:00-18:00（含起点、不含终点）。
    $beijingNow = [DateTime]::UtcNow.AddHours(8)
    $hour = $beijingNow.Hour
    return (($hour -ge 9 -and $hour -lt 12) -or ($hour -ge 14 -and $hour -lt 18))
}

# ---------- 已运行检测：端口已被占用则直接打开浏览器 ----------
if ($Port -gt 0 -and (Test-PortOpen -HostName $BindHost -PortNumber $Port)) {
    Write-Host "DSH Web 已在运行：$webUrl"
    if (-not $NoBrowser) { Start-Process $webUrl }
    exit 0
}

# ---------- 高峰时段检查 ----------
if (Test-BeijingPeakHours) {
    while ($true) {
        $answer = Read-Host '当前为高峰时段（北京时间 9:00-12:00、14:00-18:00），是否继续进入？请输入 y/n'
        if ($answer -match '^[Yy]$') { break }
        if ($answer -match '^[Nn]$') {
            Write-Host '已取消本次启动。'
            exit 0
        }
        Write-Host '输入无效，请输入 y 或 n。'
    }
}

# ---------- 组装启动命令 ----------
$dsh = Resolve-DshCommand
$dshArgs = @('web', '--host', $BindHost, '--port', "$Port")
if ($TrustedHost) { $dshArgs += @('--trusted-host', $TrustedHost) }
$dshArgs = $dsh.Args + $dshArgs

# ---------- 前台运行 ----------
if (-not $Background) {
    if ($webUrl) {
        Write-Host "正在启动 DSH Web（$webUrl），按 Ctrl+C 停止..."
    } else {
        Write-Host '正在启动 DSH Web（端口自动分配，实际地址见下方 dsh 输出），按 Ctrl+C 停止...'
    }
    # 端口就绪后自动打开浏览器；服务退出时清理该任务
    $opener = $null
    if (-not $NoBrowser -and $Port -gt 0) {
        $opener = Start-Job -ArgumentList $BindHost, $Port -ScriptBlock {
            param($h, $p)
            $deadline = (Get-Date).AddSeconds(30)
            while ((Get-Date) -lt $deadline) {
                $client = New-Object System.Net.Sockets.TcpClient
                try {
                    $iar = $client.BeginConnect($h, $p, $null, $null)
                    if ($iar.AsyncWaitHandle.WaitOne(500, $false)) {
                        $client.EndConnect($iar)
                        Start-Process "http://${h}:${p}"
                        break
                    }
                } catch { }
                finally { $client.Dispose() }
                Start-Sleep -Milliseconds 500
            }
        }
    }
    try {
        & $dsh.Exe @dshArgs
    }
    finally {
        if ($opener) { Remove-Job $opener -Force -ErrorAction SilentlyContinue }
    }
    exit $LASTEXITCODE
}

# ---------- 后台运行 ----------
$logDir = Join-Path $env:USERPROFILE '.dsh\logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$outLog = Join-Path $logDir "dsh-web-$stamp.out.log"
$errLog = Join-Path $logDir "dsh-web-$stamp.err.log"

Write-Host '正在后台启动 DSH Web...'
$proc = Start-Process -FilePath $dsh.Exe -ArgumentList $dshArgs `
    -WorkingDirectory $PSScriptRoot `
    -RedirectStandardOutput $outLog -RedirectStandardError $errLog -PassThru

# 等待端口就绪（最多 30 秒）
$deadline = (Get-Date).AddSeconds(30)
while ((Get-Date) -lt $deadline) {
    if ($proc.HasExited) {
        Write-Host "启动失败：进程已退出（退出码 $($proc.ExitCode)），请查看日志：$errLog"
        exit 1
    }
    if (Test-PortOpen -HostName $BindHost -PortNumber $Port) { break }
    Start-Sleep -Milliseconds 500
}

if ($webUrl) {
    if (-not $NoBrowser) { Start-Process $webUrl }
    Write-Host "DSH Web 已启动：$webUrl"
} else {
    Write-Host 'DSH Web 已启动（端口自动分配，见日志）'
}
Write-Host "PID: $($proc.Id)"
Write-Host "日志: $outLog / $errLog"
Write-Host "停止: taskkill /PID $($proc.Id) /T /F"
