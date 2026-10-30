#!/bin/sh
# One-command launcher. The interactive manager is downloaded before execution.
set -eu
umask 077

if [ "$(id -u)" -ne 0 ]; then
  echo '请以 root 运行；普通用户可将启动命令末尾的 sh 改为 sudo sh。' >&2
  exit 1
fi
if ! command -v bash >/dev/null 2>&1; then
  echo '缺少 Bash。Debian/Ubuntu：apt-get install -y bash；Alpine：apk add bash。' >&2
  exit 1
fi
if ! ( : </dev/tty ) 2>/dev/null; then
  echo '需要交互终端。请在 SSH 终端运行此命令；远程执行时请使用 ssh -t。' >&2
  exit 1
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/ssh-keyguard.XXXXXX") || exit 1
trap 'rm -rf "$work"' 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
target="$work/ssh-keyguard.sh"
url='https://raw.githubusercontent.com/se-tang/SSH-KeyGuard/main/ssh-keyguard.sh'

if command -v curl >/dev/null 2>&1; then
  if ! curl -fSL --connect-timeout 15 --max-time 120 "$url" -o "$target"; then
    echo '下载失败，未运行管理脚本。' >&2
    exit 1
  fi
elif command -v wget >/dev/null 2>&1; then
  if ! wget -T 120 -O "$target" "$url"; then
    echo '下载失败，未运行管理脚本。' >&2
    exit 1
  fi
else
  echo '缺少 curl/wget，请先安装其中一个下载工具。' >&2
  exit 1
fi
if [ ! -s "$target" ] || ! bash -n "$target"; then
  echo '下载的管理脚本为空或未通过语法检查，未执行。' >&2
  exit 1
fi

# stdin belongs to the download pipe when launched as curl | sh.
# Reopen the terminal so menu selections/public keys never come from that pipe.
bash "$target" </dev/tty
