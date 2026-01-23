<#
.SYNOPSIS
Rime 小狼毫自动化同步与部署

.DESCRIPTION
从云端拉取 -> 本地 /sync 合并 -> 推送回云端 -> 重新部署。
支持参数覆盖同步目录与远端配置，并提供 dry-run、日志、互斥锁与帮助信息。

.PARAMETER SyncDir
本地同步中转目录（默认当前目录）。

.PARAMETER RemoteName
rclone 远端名称（默认 r2）。

.PARAMETER CloudPath
云端目录（默认 rime）。

.PARAMETER DryRun
仅预演，不实际传输。

.PARAMETER UseSync
使用 rclone sync（会删除目标端多余文件）。

.PARAMETER LogPath
日志文件路径（可选）。

.PARAMETER Help
显示帮助信息。

.EXAMPLE
PS> .\newSync.ps1
默认使用当前目录进行同步。
.EXAMPLE
PS> .\newSync.ps1 -SyncDir "D:\rime_sync" -RemoteName "r2" -CloudPath "rime"
指定同步目录与远端配置。
.EXAMPLE
PS> .\newSync.ps1 -DryRun -LogPath ".\newSync.log"
仅预演并写入日志。
#>

param(
    [string]$SyncDir,
    [string]$RemoteName = "r2",
    [string]$CloudPath = "rime",
    [switch]$DryRun,
    [switch]$UseSync,
    [string]$LogPath,
    [switch]$Help
)

if ($Help) {
    $helpText = Get-Help $MyInvocation.MyCommand.Path -Detailed | Out-String
    $lines = $helpText -split "\r?\n"
    $sb = New-Object System.Text.StringBuilder
    $blankRun = 0
    foreach ($line in $lines) {
        if ($line -match '^\s*$') {
            $blankRun++
            if ($blankRun -gt 1) { continue }
        }
        else {
            $blankRun = 0
        }
        [void]$sb.AppendLine($line)
    }
    $sb.ToString().TrimEnd() | Write-Host
    return
}

$ErrorActionPreference = "Stop"

# ================= 配置区域 =================

# 1. Rime 小狼毫执行文件路径 (根据你的安装位置修改)
$WeaselDeployerPath = "C:\Program Files\Rime\weasel-0.17.4\WeaselDeployer.exe"

# 2. 本地同步中转目录 (默认使用当前目录，可用 -SyncDir 覆盖；必须与 installation.yaml 里的 sync_dir 一致)
$LocalSyncDir = if ($SyncDir) { $SyncDir } else { (Get-Location).Path }

# 3. Rclone 配置 (根据你的 rclone config 修改)
$RcloneRemoteName = $RemoteName
$RcloneCloudPath = $CloudPath

# 4. 日志与锁
$LockFile = Join-Path $LocalSyncDir ".newSync.lock"

function Get-MutexName {
    param([string]$Path)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Path.ToLowerInvariant())
    $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    $hex = ($hash | ForEach-Object { $_.ToString("x2") }) -join ""
    return "Global\RimeSync_$hex"
}

function Write-Log {
    param(
        [string]$Message,
        [ConsoleColor]$Color = "White"
    )
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$ts] $Message" -ForegroundColor $Color
    if ($LogPath) {
        $logDir = Split-Path -Parent $LogPath
        if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        Add-Content -Path $LogPath -Value "[$ts] $Message" -Encoding utf8
    }
}

function Pause-IfInteractive {
    try {
        if ($Host.UI -and $Host.UI.RawUI) {
            Write-Host "按任意键继续..." -ForegroundColor DarkGray
            $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        }
    }
    catch {
        # 非交互环境下忽略
    }
}

try {
    # 基本检查
    if (-not (Get-Command rclone -ErrorAction SilentlyContinue)) {
        Write-Log "错误: 未找到 rclone，请确认已安装并在 PATH 中。" -Color Red
        Pause-IfInteractive
        Exit 1
    }

    if (-not (Test-Path -LiteralPath $WeaselDeployerPath)) {
        Write-Log "错误: 未找到 WeaselDeployer.exe: $WeaselDeployerPath" -Color Red
        Pause-IfInteractive
        Exit 1
    }

    if (-not (Test-Path -LiteralPath $LocalSyncDir)) {
        Write-Log "错误: 本地同步目录不存在: $LocalSyncDir" -Color Red
        Pause-IfInteractive
        Exit 1
    }

    $mutexName = Get-MutexName -Path $LocalSyncDir
    $createdNew = $false
    $mutex = New-Object System.Threading.Mutex($false, $mutexName, [ref]$createdNew)
    if (-not $createdNew) {
        Write-Log "错误: 检测到已有同步在运行 (互斥锁): $mutexName" -Color Red
        Pause-IfInteractive
        Exit 1
    }
    if (-not $DryRun) {
        $lockInfo = @(
            "pid=$PID"
            "started=$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")"
        ) -join "`r`n"
        Set-Content -Path $LockFile -Value $lockInfo -Encoding utf8
    }

    if ($UseSync) {
        Write-Log "注意: 已启用 -UseSync，rclone sync 会删除目标端多余文件。" -Color Yellow
    }

    $dryRunArgs = @()
    if ($DryRun) {
        $dryRunArgs += "--dry-run"
        Write-Log "已启用 DryRun：不执行 Rime 同步/部署，仅做 rclone 预演传输。" -Color Yellow
    }

    $rcloneVerb = if ($UseSync) { "sync" } else { "copy" }
    $baseArgs = @("--progress", "-v", "--exclude", ".newSync.lock")
    if (-not $UseSync) {
        $baseArgs += "--update"
    }

    Write-Log ">>> 步骤 1/4: 正在从云端拉取最新数据 (Rclone Pull)..." -Color Cyan
    & rclone $rcloneVerb "$($RcloneRemoteName):$RcloneCloudPath" "$LocalSyncDir" @baseArgs @dryRunArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Log "错误: Rclone 拉取失败，脚本终止。" -Color Red
        Pause
        Exit 1
    }

    Write-Log "`n>>> 步骤 2/4: 执行 Rime 内部数据合并 (Weasel Sync)..." -Color Cyan
    # 这一步对应“点击同步按钮”。
    # Rime 会读取 LocalSyncDir 里的数据合并到输入法，并将输入法的新数据写回 LocalSyncDir
    if ($DryRun) {
        Write-Log "DryRun：跳过 Weasel Sync。" -Color Yellow
    }
    else {
        $syncProcess = Start-Process -FilePath $WeaselDeployerPath -ArgumentList "/sync" -Wait -PassThru
        if ($syncProcess.ExitCode -ne 0) {
            Write-Log "错误: Weasel Sync 失败，脚本终止。ExitCode=$($syncProcess.ExitCode)" -Color Red
            Pause-IfInteractive
            Exit 1
        }
    }

    Write-Log "`n>>> 步骤 3/4: 将合并后的数据推送到云端 (Rclone Push)..." -Color Cyan
    # 现在 LocalSyncDir 里已经是最新、最全的数据了，上传到云端
    & rclone $rcloneVerb "$LocalSyncDir" "$($RcloneRemoteName):$RcloneCloudPath" @baseArgs @dryRunArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Log "错误: Rclone 推送失败。" -Color Red
        Pause-IfInteractive
        Exit 1
    }

    Write-Log "`n>>> 步骤 4/4: 重新部署 Rime (Deploy)..." -Color Cyan
    # 这一步对应“重新部署”，让配置和词典生效
    if ($DryRun) {
        Write-Log "DryRun：跳过 Weasel Deploy。" -Color Yellow
    }
    else {
        $deployProcess = Start-Process -FilePath $WeaselDeployerPath -ArgumentList "/deploy" -Wait -PassThru
        if ($deployProcess.ExitCode -ne 0) {
            Write-Log "错误: Weasel Deploy 失败。ExitCode=$($deployProcess.ExitCode)" -Color Red
            Pause-IfInteractive
            Exit 1
        }
    }

    Write-Log "`n>>> 全部完成！你的 Rime 现在的状态是：本地最新 + 云端已备份 + 配置已生效。" -Color Green
    Start-Sleep -Seconds 3
}
catch {
    Write-Log "发生异常: $($_.Exception.Message)" -Color Red
    Pause-IfInteractive
    Exit 1
}
finally {
    if (Test-Path -LiteralPath $LockFile) {
        Remove-Item -LiteralPath $LockFile -Force -ErrorAction SilentlyContinue
    }
    if ($mutex) {
        try { $mutex.ReleaseMutex() } catch { }
        $mutex.Dispose()
    }
}
