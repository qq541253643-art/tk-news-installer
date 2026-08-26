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

Write-Host "TK新闻精品二创工作台：一键联网安装" -ForegroundColor Cyan
Write-Host "安装来源：GitHub 与官方依赖源"

& wsl.exe -d $Distribution -- sudo -v
if ($LASTEXITCODE -ne 0) {
    throw "Ubuntu sudo 验证失败；请确认当前 Windows 用户可以进入 $Distribution"
}

$prepareScript = @'
set -Eeuo pipefail
[[ "$(id -u)" -ne 0 ]] || { printf "[FAIL] 请使用普通 Ubuntu 用户，不要使用 root\n" >&2; exit 1; }
command -v sudo >/dev/null 2>&1 || { printf "[FAIL] Ubuntu 缺少 sudo\n" >&2; exit 1; }
sudo apt-get update
sudo apt-get install -y ca-certificates curl git openssh-client python3
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
  bash scripts/install.sh
else
  TK_CODE_ALREADY_UPDATED=1 bash scripts/update.sh
fi
'@

Invoke-WslScript -Script $installScript -FailureMessage "联网安装失败"

Write-Host "`n安装完成。" -ForegroundColor Green
Write-Host "面板地址：http://127.0.0.1:18766"
Write-Host "维护命令：tk-update、tk-doctor、tk-register、tk-authorize"
