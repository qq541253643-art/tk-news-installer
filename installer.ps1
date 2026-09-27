[CmdletBinding()]
param(
    [ValidatePattern("^[A-Za-z0-9._-]+$")]
    [string]$Distribution = "Ubuntu",

    [switch]$SkipBrowser
)

$ErrorActionPreference = "Stop"
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$repository = "qq541253643-art/tk-cutout-remix-workbench"
$desktop = [Environment]::GetFolderPath("Desktop")
$installLogPath = Join-Path $desktop ("TK安装日志-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".txt")
$script:installTranscriptStarted = $false

function Stop-InstallTranscript {
    if (-not $script:installTranscriptStarted) {
        return
    }
    try {
        Stop-Transcript | Out-Null
    }
    catch {
        # 安装失败信息已经显示，停止日志失败不能覆盖原始错误。
    }
    $script:installTranscriptStarted = $false
}

try {
    Start-Transcript -LiteralPath $installLogPath -Force | Out-Null
    $script:installTranscriptStarted = $true
}
catch {
    Write-Warning "无法创建桌面安装日志：$($_.Exception.Message)"
}

trap {
    $failureMessage = $_.Exception.Message
    Write-Host "`n[FAIL] 安装未完成：$failureMessage" -ForegroundColor Red
    if ($script:installTranscriptStarted) {
        Write-Host "安装日志：$installLogPath" -ForegroundColor Yellow
    }
    Stop-InstallTranscript
    [void](Read-Host "错误窗口将保留；记录或发送日志后，按 Enter 退出")
    exit 1
}

function Invoke-WslScript {
    param(
        [Parameter(Mandatory = $true)][string]$Script,
        [string[]]$Arguments = @(),
        [string]$FailureMessage = "WSL 操作失败"
    )

    $temporaryScript = Join-Path ([IO.Path]::GetTempPath()) ("tk-wsl-" + [Guid]::NewGuid().ToString("N") + ".sh")
    $normalizedScript = $Script.Replace("`r`n", "`n").Replace("`r", "`n")
    if (-not $normalizedScript.EndsWith("`n")) {
        $normalizedScript += "`n"
    }
    [IO.File]::WriteAllText($temporaryScript, $normalizedScript, $utf8)

    try {
        $portableTemporaryScript = $temporaryScript.Replace("\", "/")
        $wslScriptPath = (& wsl.exe -d $Distribution -- wslpath -a -- $portableTemporaryScript | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($wslScriptPath)) {
            throw "无法把临时安装脚本交给 WSL：$temporaryScript"
        }
        & wsl.exe -d $Distribution -- bash $wslScriptPath @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw "$FailureMessage；请保留本窗口中的 [FAIL] 信息"
        }
    }
    finally {
        Remove-Item -LiteralPath $temporaryScript -Force -ErrorAction SilentlyContinue
    }
}

function Set-WslDownloadNetwork {
    $minimumBuild = 22621
    $windowsBuild = [Environment]::OSVersion.Version.Build
    if ($windowsBuild -lt $minimumBuild) {
        Write-Warning "Windows 版本低于 Windows 11 22H2，跳过 WSL 镜像网络配置。"
        return
    }

    $configPath = Join-Path ([Environment]::GetFolderPath("UserProfile")) ".wslconfig"
    $settings = [ordered]@{
        "networkingMode" = "mirrored"
        "autoProxy" = "true"
        "dnsTunneling" = "true"
    }
    $existingText = if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        [IO.File]::ReadAllText($configPath)
    } else { "" }
    $lines = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrEmpty($existingText)) {
        foreach ($line in ($existingText -split "`r?`n")) { $lines.Add($line) }
    }

    $sectionStart = -1
    $sectionEnd = $lines.Count
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match '^\s*\[wsl2\]\s*(?:[;#].*)?$') {
            $sectionStart = $index
            for ($cursor = $index + 1; $cursor -lt $lines.Count; $cursor++) {
                if ($lines[$cursor] -match '^\s*\[[^\]]+\]') {
                    $sectionEnd = $cursor
                    break
                }
            }
            break
        }
    }

    $configured = $sectionStart -ge 0
    if ($configured) {
        foreach ($entry in $settings.GetEnumerator()) {
            $keyPattern = '^\s*' + [Regex]::Escape($entry.Key) + '\s*='
            $valuePattern = '^\s*' + [Regex]::Escape($entry.Key) + '\s*=\s*' + [Regex]::Escape($entry.Value) + '\s*(?:[;#].*)?$'
            $found = $false
            for ($index = $sectionStart + 1; $index -lt $sectionEnd; $index++) {
                if ($lines[$index] -match $keyPattern -and $lines[$index] -notmatch $valuePattern) {
                    $configured = $false
                }
                if ($lines[$index] -match $valuePattern) { $found = $true }
            }
            if (-not $found) { $configured = $false }
        }
    }
    if ($configured) {
        Write-Host "[PASS] WSL 下载网络已是推荐配置" -ForegroundColor Green
        return
    }

    if ($sectionStart -lt 0) {
        if ($lines.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($lines[$lines.Count - 1])) {
            $lines.Add("")
        }
        $lines.Add("[wsl2]")
        foreach ($entry in $settings.GetEnumerator()) {
            $lines.Add("$($entry.Key)=$($entry.Value)")
        }
    }
    else {
        $insertAt = $sectionEnd
        foreach ($entry in $settings.GetEnumerator()) {
            $keyPattern = '^\s*' + [Regex]::Escape($entry.Key) + '\s*='
            $matches = New-Object System.Collections.Generic.List[int]
            for ($index = $sectionStart + 1; $index -lt $insertAt; $index++) {
                if ($lines[$index] -match $keyPattern) { $matches.Add($index) }
            }
            if ($matches.Count -eq 0) {
                $lines.Insert($insertAt, "$($entry.Key)=$($entry.Value)")
                $insertAt++
            }
            else {
                $lines[$matches[0]] = "$($entry.Key)=$($entry.Value)"
                for ($cursor = $matches.Count - 1; $cursor -ge 1; $cursor--) {
                    $lines.RemoveAt($matches[$cursor])
                    $insertAt--
                }
            }
        }
    }

    $backupPath = ""
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        $backupPath = "$configPath.tk-news-backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item -LiteralPath $configPath -Destination $backupPath -Force
    }
    $temporary = "$configPath.tk-news-$([Guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllText($temporary, (($lines.ToArray() -join "`r`n").TrimEnd() + "`r`n"), $utf8)
    Move-Item -LiteralPath $temporary -Destination $configPath -Force
    Write-Host "[PASS] WSL 下载网络已优化，正在重启 WSL 后继续安装" -ForegroundColor Green
    if (-not [string]::IsNullOrWhiteSpace($backupPath)) {
        Write-Host "原配置备份：$backupPath"
    }
    & wsl.exe --shutdown
    Start-Sleep -Seconds 4
}

Write-Host "TK新闻精品二创工作台：一键联网安装" -ForegroundColor Cyan
Write-Host "安装来源：GitHub 与官方依赖源"

Set-WslDownloadNetwork

$prepareScript = @'
set -Eeuo pipefail
[[ "$(id -u)" -ne 0 ]] || { printf "[FAIL] 请使用普通 Ubuntu 用户，不要使用 root\n" >&2; exit 1; }
command -v sudo >/dev/null 2>&1 || { printf "[FAIL] Ubuntu 缺少 sudo\n" >&2; exit 1; }
required_packages=(
  build-essential ca-certificates curl ffmpeg fonts-noto-color-emoji git iproute2
  libgl1 libglib2.0-0 openssh-client python3 python3-pip python3-venv
)
missing_packages=()
for package in "${required_packages[@]}"; do
  if ! dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -Fqx 'install ok installed'; then
    missing_packages+=("$package")
  fi
done
current_user="$(id -un)"
linger_state="$(loginctl show-user "$current_user" -p Linger --value 2>/dev/null || true)"
if [[ "${#missing_packages[@]}" -gt 0 || "$linger_state" != "yes" ]]; then
  printf "[INFO] 首次准备系统依赖，只需输入一次 Ubuntu 管理密码\n"
  sudo -v
  if [[ "${#missing_packages[@]}" -gt 0 ]]; then
    sudo apt-get update
    sudo apt-get install -y "${required_packages[@]}"
  fi
  if [[ "$linger_state" != "yes" ]]; then
    sudo loginctl enable-linger "$current_user"
  fi
else
  printf "[PASS] 系统依赖与常驻服务权限已就绪，不再请求管理密码\n"
fi
systemctl --user show-environment >/dev/null 2>&1 || {
  printf "[FAIL] systemd 用户服务不可用；请在 /etc/wsl.conf 启用 systemd，执行 wsl --shutdown 后重试\n" >&2
  exit 1
}
ssh_dir="$HOME/.ssh"
key_path="$ssh_dir/tk-news-workbench-deploy"
known_hosts="$ssh_dir/tk-news-workbench-known-hosts"
github_host_key="AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"
install -d -m 700 "$ssh_dir"
if [[ -f "$key_path.pub" && ! -f "$key_path" ]]; then
  orphaned_public_key="$(mktemp "$key_path.pub.orphaned-XXXXXXXX")"
  mv -f "$key_path.pub" "$orphaned_public_key"
  printf "[WARN] 旧公钥缺少对应私钥，已备份到：%s\n" "$orphaned_public_key" >&2
fi
if [[ ! -f "$key_path" ]]; then
  machine_id="$(tr -cd "[:alnum:]" </etc/machine-id | cut -c1-8)"
  ssh-keygen -q -t ed25519 -N "" -C "TK-PC-$machine_id" -f "$key_path"
fi
chmod 600 "$key_path"
derived_public_key="$(ssh-keygen -y -f "$key_path" 2>/dev/null | awk '{print $1, $2}')" || {
  printf "[FAIL] 本机私钥无法读取：%s；请保留文件并运行 tk-doctor\n" "$key_path" >&2
  exit 1
}
[[ "$derived_public_key" == ssh-ed25519\ * ]] || {
  printf "[FAIL] 本机私钥不是受支持的 Ed25519 密钥：%s\n" "$key_path" >&2
  exit 1
}
machine_id="$(tr -cd "[:alnum:]" </etc/machine-id | cut -c1-8)"
printf "%s TK-PC-%s\n" "$derived_public_key" "$machine_id" >"$key_path.pub"
chmod 644 "$key_path.pub"
temporary="$(mktemp "$ssh_dir/.tk-known-hosts.XXXXXX")"
printf "github.com ssh-ed25519 %s\n" "$github_host_key" >"$temporary"
printf "[ssh.github.com]:443 ssh-ed25519 %s\n" "$github_host_key" >>"$temporary"
chmod 600 "$temporary"
mv -f "$temporary" "$known_hosts"
'@
Invoke-WslScript -Script $prepareScript -FailureMessage "环境准备或设备密钥生成失败"

$publicKey = (& wsl.exe -d $Distribution -- bash -lc 'cat "$HOME/.ssh/tk-news-workbench-deploy.pub"' | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or -not $publicKey.StartsWith("ssh-ed25519 ")) {
    throw "没有读取到本机公钥；私钥不会显示或复制"
}

$accessCheck = 'key_path="$HOME/.ssh/tk-news-workbench-deploy"; known_hosts="$HOME/.ssh/tk-news-workbench-known-hosts"; ssh_command="ssh -i $key_path -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$known_hosts"; GIT_SSH_COMMAND="$ssh_command" timeout 25 git ls-remote "ssh://git@ssh.github.com:443/qq541253643-art/tk-cutout-remix-workbench.git" refs/heads/main'
$accessOutput = (& wsl.exe -d $Distribution -- bash -lc $accessCheck 2>&1 | Out-String).Trim()
$accessStatus = $LASTEXITCODE
$keyAlreadyAuthorized = $accessStatus -eq 0
if ($keyAlreadyAuthorized) {
    Write-Host "[PASS] 已复用本机现有 GitHub 只读授权，无需重新绑定" -ForegroundColor Green
}
elseif ($accessOutput -match 'Permission denied \(publickey\)|Repository not found') {
    try {
        Set-Clipboard -Value $publicKey
        Write-Host "`n本机公钥已复制到剪贴板。" -ForegroundColor Green
    } catch {
        Write-Warning "无法写入剪贴板，请手动复制下面这一整行公钥。"
    }
    Write-Host "`n$publicKey`n"
    Write-Host "请把公钥发给 GitHub 管理电脑，由管理员添加到仓库 Deploy keys。"
    Write-Host "管理员必须保持 Allow write access 未勾选；本机无需登录 GitHub。" -ForegroundColor Yellow
    [void](Read-Host "管理员添加完成后按 Enter 继续验证")
}
elseif ($accessStatus -eq 124) {
    throw "连接 GitHub SSH 超过 25 秒；现有密钥未被判定失效，请检查 WSL 网络后重试"
}
else {
    $accessReason = if ([string]::IsNullOrWhiteSpace($accessOutput)) { "未知连接错误" } else { $accessOutput }
    throw "无法验证现有 GitHub 授权：$accessReason"
}

$installScript = @'
set -Eeuo pipefail
repository="qq541253643-art/tk-cutout-remix-workbench"
project="$HOME/projects/tk-news-remix-workbench"
key_path="$HOME/.ssh/tk-news-workbench-deploy"
known_hosts="$HOME/.ssh/tk-news-workbench-known-hosts"
ssh_command="ssh -i $key_path -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$known_hosts"
ssh_remote="ssh://git@ssh.github.com:443/$repository.git"
if ! GIT_SSH_COMMAND="$ssh_command" timeout 25 git ls-remote "$ssh_remote" refs/heads/main >/dev/null; then
  printf "[FAIL] 本机公钥尚未获仓库授权，或 WSL 无法连接 GitHub SSH 443\n" >&2
  printf "[FAIL] 请检查 Deploy keys 中的公钥，然后重新运行同一条联网安装命令\n" >&2
  exit 1
fi
mkdir -p "$HOME/projects"
existing_project=0
if [[ -d "$project/.git" ]]; then
  existing_project=1
  [[ -z "$(git -C "$project" status --porcelain --untracked-files=normal)" ]] || {
    printf "[FAIL] 已有项目存在本地改动，未自动覆盖：%s\n" "$project" >&2
    exit 1
  }
  [[ "$(git -C "$project" symbolic-ref --quiet --short HEAD || true)" == "main" ]] || {
    printf "[FAIL] 已有项目当前不是 main 分支：%s\n" "$project" >&2
    exit 1
  }
  GIT_SSH_COMMAND="$ssh_command" git -C "$project" fetch \
    "$ssh_remote" main:refs/remotes/origin/main
  git -C "$project" merge --ff-only refs/remotes/origin/main
else
  GIT_SSH_COMMAND="$ssh_command" git clone "$ssh_remote" "$project"
fi
cd "$project"
bash scripts/deploy-key-access.sh activate
if [[ "$existing_project" -eq 0 || ! -x .venv/bin/python ]]; then
  TK_SYSTEM_PREREQUISITES_READY=1 bash scripts/install.sh
else
  TK_CODE_ALREADY_UPDATED=1 bash scripts/update.sh
fi
'@

Invoke-WslScript -Script $installScript -FailureMessage "联网安装失败"

Write-Host "`n安装完成。" -ForegroundColor Green
Write-Host "面板地址：http://127.0.0.1:18766"
Write-Host "桌面入口：TK新闻精品二创工作台.url"
Write-Host "维护命令：tk-update、tk-doctor、tk-register、tk-authorize"
Write-Host "安装日志：$installLogPath"
Stop-InstallTranscript
