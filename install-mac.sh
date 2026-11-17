#!/usr/bin/env bash
set -Eeuo pipefail

repository="qq541253643-art/tk-cutout-remix-workbench"
panel_url="http://127.0.0.1:18766"

fail() {
  printf '\n[FAIL] %s\n' "$1" >&2
  exit 1
}

pass() {
  printf '[PASS] %s\n' "$1"
}

info() {
  printf '[INFO] %s\n' "$1"
}

trap 'status=$?; if (( status != 0 )); then printf "[FAIL] 安装在第 %s 行中断；请保留上方错误信息。\n" "$LINENO" >&2; fi' ERR

[[ "$(uname -s)" == "Darwin" ]] || fail "此安装器只支持 macOS"
[[ "$(uname -m)" == "arm64" ]] || fail "当前安装器只支持 Apple Silicon（M1/M2/M3/M4）"
(( EUID != 0 )) || fail "请不要使用 sudo 或 root 运行安装器"

macos_version="$(sw_vers -productVersion)"
major_version="${macos_version%%.*}"
[[ "$major_version" =~ ^[0-9]+$ ]] && (( major_version >= 13 )) \
  || fail "需要 macOS 13 或更高版本；当前为 $macos_version"
pass "macOS $macos_version / Apple Silicon"

export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:$PATH"
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_ENV_HINTS=1
export HOMEBREW_NO_ANALYTICS=1

ensure_command_line_tools() {
  if xcode-select -p >/dev/null 2>&1 && xcrun --find clang >/dev/null 2>&1; then
    pass "Apple Command Line Tools 已安装"
    return
  fi

  info "缺少 Apple Command Line Tools，正在打开系统安装窗口"
  xcode-select --install >/dev/null 2>&1 || true
  printf '[ACTION] 如果出现 Apple 安装弹窗，请点击“安装”并等待完成。脚本会自动继续。\n'

  local attempt
  for attempt in $(seq 1 240); do
    if xcode-select -p >/dev/null 2>&1 && xcrun --find clang >/dev/null 2>&1; then
      pass "Apple Command Line Tools 安装完成"
      return
    fi
    if (( attempt % 12 == 0 )); then
      info "仍在等待 Apple Command Line Tools：${attempt}0秒"
    fi
    sleep 5
  done
  fail "等待 Command Line Tools 超时；请完成系统安装弹窗后重新运行同一条命令"
}

ensure_homebrew() {
  local brew_bin=""
  if command -v brew >/dev/null 2>&1; then
    brew_bin="$(command -v brew)"
  elif [[ -x /opt/homebrew/bin/brew ]]; then
    brew_bin=/opt/homebrew/bin/brew
  elif [[ -x /usr/local/bin/brew ]]; then
    brew_bin=/usr/local/bin/brew
  fi

  if [[ -z "$brew_bin" ]]; then
    info "缺少 Homebrew，正在自动安装；此步骤可能要求输入一次 Mac 登录密码"
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    if [[ -x /opt/homebrew/bin/brew ]]; then
      brew_bin=/opt/homebrew/bin/brew
    elif [[ -x /usr/local/bin/brew ]]; then
      brew_bin=/usr/local/bin/brew
    fi
  fi

  [[ -n "$brew_bin" ]] || fail "Homebrew 自动安装后仍不可用"
  local brew_prefix
  brew_prefix="$("$brew_bin" --prefix)"
  export PATH="$brew_prefix/bin:$brew_prefix/sbin:$PATH"
  pass "Homebrew 可用：$brew_prefix"
}

ensure_packages() {
  local missing=()
  local formula
  for formula in python@3.13 ffmpeg@7 git gh; do
    if ! brew list --versions "$formula" >/dev/null 2>&1; then
      missing+=("$formula")
    fi
  done
  if (( ${#missing[@]} > 0 )); then
    info "自动安装 Homebrew 依赖：${missing[*]}"
    brew install "${missing[@]}"
  else
    pass "Homebrew 依赖已齐全"
  fi
  command -v python3.13 >/dev/null 2>&1 \
    || [[ -x "$(brew --prefix python@3.13)/bin/python3.13" ]] \
    || fail "Python 3.13 安装后不可用"
  local ffmpeg_bin ffmpeg_bin_dir formula_name
  ffmpeg_bin=""
  for formula_name in ffmpeg@7 ffmpeg07; do
    ffmpeg_bin="$(brew list "$formula_name" 2>/dev/null | awk '/\/bin\/ffmpeg$/{last=$0} END{if(last) print last}')"
    [[ -n "$ffmpeg_bin" ]] && break
  done
  if [[ -z "$ffmpeg_bin" ]]; then
    ffmpeg_bin="$(brew --prefix ffmpeg@7)/bin/ffmpeg"
  fi
  [[ -x "$ffmpeg_bin" ]] || fail "FFmpeg 7 安装后不可用"
  ffmpeg_bin_dir="$(dirname "$ffmpeg_bin")"
  [[ -x "$ffmpeg_bin_dir/ffprobe" ]] || fail "FFprobe 安装后不可用"
  export PATH="$ffmpeg_bin_dir:$PATH"
  "$ffmpeg_bin" -hide_banner -filters 2>/dev/null | grep -F rubberband >/dev/null \
    || fail "FFmpeg 7 缺少 rubberband 声音时长校正组件"
  command -v gh >/dev/null 2>&1 || fail "GitHub CLI 安装后不可用"
}

existing_project_readable() {
  local project
  project="$(select_project_path)"
  [[ -d "$project/.git" ]] || return 1
  GIT_TERMINAL_PROMPT=0 git -C "$project" fetch --quiet origin main >/dev/null 2>&1
}


ensure_github_access() {
  if gh auth status --hostname github.com >/dev/null 2>&1 \
    && gh api "repos/$repository" >/dev/null 2>&1; then
    pass "GitHub 授权可读取私有项目"
    gh auth setup-git --hostname github.com
    return
  fi

  if existing_project_readable; then
    pass "已有仓库可通过本机只读密钥读取项目，跳过 GitHub 登录"
    return
  fi

  printf '\n[ACTION] 首次安装需要一次 GitHub 浏览器授权。\n'
  printf '[ACTION] 屏幕出现一次性验证码和“Press Enter”时，按一次回车；浏览器会打开，请登录有仓库权限的 GitHub 账号并确认。\n'
  gh auth login \
    --hostname github.com \
    --git-protocol https \
    --web \
    --scopes repo
  gh auth setup-git --hostname github.com

  gh api "repos/$repository" >/dev/null 2>&1 \
    || fail "当前 GitHub 账号无法读取私有项目 $repository；请让仓库管理员授予 Read 权限后重试"
  pass "GitHub 授权可读取私有项目"
}

select_project_path() {
  local candidate
  if [[ -n "${TK_MAC_INSTALL_ROOT:-}" ]]; then
    printf '%s\n' "${TK_MAC_INSTALL_ROOT%/}"
    return
  fi
  for candidate in \
    "$HOME/projects/tk-news-workbench" \
    "$HOME/tk-cutout-remix-workbench" \
    "$HOME/tk-cutout-remix-workbench-mac"; do
    if [[ -d "$candidate/.git" ]]; then
      printf '%s\n' "$candidate"
      return
    fi
  done
  printf '%s\n' "$HOME/projects/tk-news-workbench"
}

install_or_update_project() {
  local project
  project="$(select_project_path)"

  if [[ -d "$project/.git" ]]; then
    [[ -z "$(git -C "$project" status --porcelain --untracked-files=normal)" ]] \
      || fail "已有项目存在本地改动，未自动覆盖：$project"
    [[ "$(git -C "$project" symbolic-ref --quiet --short HEAD || true)" == "main" ]] \
      || fail "已有项目当前不是 main 分支：$project"
    if ! GIT_TERMINAL_PROMPT=0 git -C "$project" fetch origin main; then
      git -C "$project" remote set-url origin "https://github.com/$repository.git"
      git -C "$project" fetch origin main
    fi
    git -C "$project" merge --ff-only FETCH_HEAD
    pass "项目已更新：$project"
  else
    if [[ -e "$project" ]]; then
      if [[ -d "$project" && -z "$(ls -A "$project")" ]]; then
        rmdir "$project"
      else
        fail "安装目录已存在但不是有效 Git 仓库：$project；请先改名或移走该目录"
      fi
    fi
    mkdir -p "$(dirname "$project")"
    gh repo clone "$repository" "$project"
    pass "项目已克隆：$project"
  fi

  printf '\n[INFO] 依赖与项目已就绪，开始安装生产环境、模型和面板。首次下载可能需要较长时间。\n'
  ( cd "$project" && bash scripts/install-macos.sh )
}

printf 'TK新闻精品二创工作台：macOS 一条命令安装\n'
ensure_command_line_tools
ensure_homebrew
ensure_packages
ensure_github_access
install_or_update_project

printf '\n[PASS] macOS 安装完成\n'
printf '面板地址：%s\n' "$panel_url"
printf '以后重新运行同一条命令即可自动更新。\n'
