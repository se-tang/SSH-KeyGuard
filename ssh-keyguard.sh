#!/usr/bin/env bash
# SSH KeyGuard - lightweight SSH key and authentication manager
# Targets: Debian / Ubuntu / Alpine with OpenSSH Server and Bash.
set -Eeuo pipefail
umask 077

APP_VERSION="0.3.2"
CONFIG="${SSH_KEYGUARD_CONFIG:-/etc/ssh/sshd_config}"
BACKUP_DIR="${SSH_KEYGUARD_BACKUP_DIR:-/var/backups/ssh-keyguard}"
SSHD="${SSHD_BIN:-$(command -v sshd || true)}"
if [[ -z "$SSHD" && -x /usr/sbin/sshd ]]; then SSHD=/usr/sbin/sshd; fi

DISTRO_ID="unknown"
DISTRO_NAME="unknown Linux"
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  DISTRO_ID="${ID:-unknown}"
  DISTRO_NAME="${PRETTY_NAME:-$DISTRO_ID}"
fi

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo '请使用 root 运行：sudo ./ssh-keyguard.sh'
  exit 1
fi
if [[ ! -f "$CONFIG" || -z "$SSHD" || ! -x "$SSHD" ]]; then
  echo '未找到 OpenSSH 服务端配置或 sshd。请先安装并启动 OpenSSH Server。'
  if [[ "$DISTRO_ID" == alpine ]]; then
    echo 'Alpine 可执行：apk add bash openssh'
  fi
  exit 1
fi
case "$DISTRO_ID" in
  debian|ubuntu|alpine) ;;
  *) echo "提示：当前系统为 $DISTRO_NAME，尚未列入项目的主要适配目标；将尝试使用通用 Linux 服务管理方式。" ;;
esac
mkdir -p "$BACKUP_DIR"

pause() { read -r -p '回车继续...' _ || true; }

SERVICE_MANAGER=""
SERVICE_NAME=""

service_select() {
  local unit name
  SERVICE_MANAGER=""; SERVICE_NAME=""

  # systemd: Debian / Ubuntu and other systemd-based distributions.
  if command -v systemctl >/dev/null 2>&1; then
    for unit in ssh.service sshd.service; do
      if systemctl is-active --quiet "$unit" 2>/dev/null; then
        SERVICE_MANAGER=systemd; SERVICE_NAME=$unit; return 0
      fi
    done
  fi

  # OpenRC: Alpine Linux. Some OpenRC sshd scripts do not implement reload;
  # restart is used as a fallback after the candidate config has been validated.
  if command -v rc-service >/dev/null 2>&1; then
    for name in sshd ssh; do
      if rc-service "$name" status >/dev/null 2>&1; then
        SERVICE_MANAGER=openrc; SERVICE_NAME=$name; return 0
      fi
    done
  fi

  # SysV / service compatibility fallback.
  if command -v service >/dev/null 2>&1; then
    for name in ssh sshd; do
      if service "$name" status >/dev/null 2>&1; then
        SERVICE_MANAGER=sysv; SERVICE_NAME=$name; return 0
      fi
    done
  fi

  echo '未检测到运行中的 SSH 服务，无法自动重载/重启。配置文件可能尚未被服务读取。'
  return 1
}

service_action() {
  case "$SERVICE_MANAGER" in
    systemd) systemctl "$1" "$SERVICE_NAME" ;;
    openrc) rc-service "$SERVICE_NAME" "$1" ;;
    sysv) service "$SERVICE_NAME" "$1" ;;
    *) echo '没有已选定的 SSH 服务，无法自动操作。'; return 1 ;;
  esac
}

service_running() {
  if [[ "$SERVICE_MANAGER" == systemd ]]; then
    systemctl is-active --quiet "$SERVICE_NAME"
  else
    service_action status
  fi
}

service_reload() {
  service_select || return 1
  if service_action reload; then
    service_running && return 0
  fi
  echo "$SERVICE_NAME 重载失败或服务未运行，尝试 restart..."
  service_action restart && service_running
}

rollback_config() {
  local original=$1 recover_service=${2:-no}
  if ! cp -a "$original" "$CONFIG" || ! "$SSHD" -t -f "$CONFIG"; then
    echo '严重错误：备份恢复或恢复后的配置验证失败。请保留当前连接并通过控制台救援。'
    printf '备份：%s\n目标：%s\n' "$original" "$CONFIG"
    printf '配置恢复命令：cp -a -- %q %q\n' "$original" "$CONFIG"
    return 1
  fi
  if [[ "$recover_service" == yes ]]; then
    # Keep the original manager/unit even if the failed restart left it stopped.
    if ! service_action restart || ! service_running; then
      echo '严重错误：配置已恢复，但 SSH 服务未确认恢复运行。请保留当前连接并通过控制台救援。'
      printf '备份：%s\n' "$original"
      case "$SERVICE_MANAGER" in
        systemd) printf '服务恢复命令：systemctl restart %q\n' "$SERVICE_NAME" ;;
        openrc) printf '服务恢复命令：rc-service %q restart\n' "$SERVICE_NAME" ;;
        sysv) printf '服务恢复命令：service %q restart\n' "$SERVICE_NAME" ;;
        *) echo '未能识别 SSH 服务，请在控制台确认服务名后启动。' ;;
      esac
      return 1
    fi
  fi
  echo '已恢复备份配置。'
}

backup() {
  local dir
  dir=$(mktemp -d "$BACKUP_DIR/$(date +%Y%m%d-%H%M%S)-$$.XXXXXX") || return 1
  if ! cp -a "$CONFIG" "$dir/sshd_config"; then
    rm -rf "$dir"
    return 1
  fi
  printf '%s\n' "$dir"
}

get_value() {
  local key=$1 output=$2
  awk -v key="$key" 'tolower($1)==tolower(key) {print tolower($2); exit}' <<< "$output"
}

show_policy() {
  local output=$1 root_policy
  printf '%s\n' "$output" | grep -Ei '^(pubkeyauthentication|passwordauthentication|kbdinteractiveauthentication|permitrootlogin|authenticationmethods|authorizedkeysfile) ' || true
  root_policy="$(get_value permitrootlogin "$output")"
  case "$root_policy" in
    prohibit-password|without-password)
      echo 'Root 登录策略：仅允许密钥等非密码认证（配置正确）。'
      ;;
    yes)
      echo '警告：Root 密码登录可能被允许。'
      ;;
    no)
      echo '提示：Root 远程登录已完全禁止。'
      ;;
    *)
      echo '请人工确认 Root 登录策略。'
      ;;
  esac
}

status() {
  local output
  output=$("$SSHD" -T -f "$CONFIG" 2>&1) || {
    echo "读取 sshd 生效配置失败：$output"
    return 1
  }
  echo '当前 SSH 全局生效配置：'
  show_policy "$output"
  echo
  echo '说明：Match 条件可能针对特定用户、来源地址或端口覆盖全局设置。'
}

user_home() {
  local home=""
  if command -v getent >/dev/null 2>&1; then
    home=$(getent passwd "$1" 2>/dev/null | awk -F: 'NR==1 {print $6}')
  fi
  if [[ -z "$home" && -r /etc/passwd ]]; then
    home=$(awk -F: -v user="$1" '$1==user {print $6; exit}' /etc/passwd)
  fi
  printf '%s\n' "$home"
}

root_home_safe() {
  local path=$1 owner mode
  # Root must not follow a home path replaceable by an unprivileged user.
  [[ "$path" == /* && "$path" != *$'\n'* ]] || return 1
  while [[ "$path" != / && "$path" == */ ]]; do path=${path%/}; done
  while :; do
    [[ -d "$path" && ! -L "$path" ]] || return 1
    owner=$(stat -c '%u' "$path") || return 1
    mode=$(stat -c '%a' "$path") || return 1
    [[ "$owner" == 0 ]] && (( (8#$mode & 0022) == 0 )) || return 1
    [[ "$path" == / ]] && break
    path=$(dirname "$path") || return 1
  done
}

add_key() {
  local user home key uid tmp fingerprint writer
  read -r -p '目标用户名 [root]: ' user || return 1
  user=${user:-root}
  id "$user" >/dev/null 2>&1 || { echo '用户不存在。'; return 1; }
  home=$(user_home "$user")
  [[ -n "$home" && -d "$home" ]] || { echo '用户家目录不存在。'; return 1; }
  [[ "$home" == /* && "$home" != *$'\n'* ]] || { echo '家目录路径无效。'; return 1; }
  uid=$(id -u "$user") || return 1

  echo '请粘贴一整行 SSH 公钥（只粘贴 .pub 公钥，绝不要粘贴私钥）：'
  IFS= read -r key || return 1
  [[ "$key" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-[^[:space:]]+)[[:space:]]+[A-Za-z0-9+/]+={0,3}([[:space:]].*)?$ ]] || {
    echo '公钥格式不符合预期，未写入。'
    return 1
  }

  command -v ssh-keygen >/dev/null 2>&1 || { echo '缺少 ssh-keygen，无法验证公钥，未写入。'; return 1; }
  tmp=$(mktemp) || return 1
  if ! printf '%s\n' "$key" > "$tmp" || ! fingerprint=$(ssh-keygen -lf "$tmp" 2>&1); then
    rm -f "$tmp"
    echo '公钥无法被 OpenSSH 解析，可能已截断或格式损坏，未写入。'
    return 1
  fi
  rm -f "$tmp"
  printf '已验证公钥：%s\n' "$fingerprint"

  # Every operation on a non-root user's paths runs as that user, including
  # chmod and append. A path swap can no longer redirect privileged root I/O.
  writer=$(cat <<'KEYGUARD_WRITER'
set -euo pipefail
umask 077
IFS= read -r home
IFS= read -r key
if [[ -L "$home/.ssh" || -L "$home/.ssh/authorized_keys" ]]; then
  echo '检测到 .ssh 或 authorized_keys 是符号链接，拒绝写入。'
  exit 1
fi
mkdir -p "$home/.ssh"
chmod 700 "$home/.ssh"
file="$home/.ssh/authorized_keys"
[[ ! -e "$file" || -f "$file" ]] || { echo 'authorized_keys 不是普通文件。'; exit 1; }
touch "$file"
chmod 600 "$file"
  if grep -Fxq -- "$key" "$file"; then
    echo '这条公钥已经存在，没有重复添加。'
  else
    last=""
    if [[ -s "$file" ]]; then last=$(tail -c 1 "$file"); fi
    if [[ -n "$last" ]]; then printf '\n' >> "$file"; fi
    printf '%s\n' "$key" >> "$file"
    echo '公钥已添加，原有公钥均已保留。'
  fi
  echo "公钥安装位置：$file"
KEYGUARD_WRITER
  ) || return 1
  if [[ "$uid" == 0 ]]; then
    root_home_safe "$home" || { echo 'Root 家目录或其父目录可被其他用户修改或含符号链接，拒绝写入。'; return 1; }
    if [[ -e "$home/.ssh" || -L "$home/.ssh" ]]; then
      root_home_safe "$home/.ssh" || { echo 'Root .ssh 目录属主、权限或路径不安全，拒绝写入。'; return 1; }
    fi
    /bin/bash -c "$writer" <<< "$home"$'\n'"$key" || return 1
  elif command -v runuser >/dev/null 2>&1; then
    runuser -u "$user" -- /bin/bash -c "$writer" <<< "$home"$'\n'"$key" || {
      echo '目标用户写入失败；请检查目录属主和权限，未以 root 强行修正。'; return 1;
    }
  elif command -v su >/dev/null 2>&1; then
    su -s /bin/bash -c "$writer" "$user" <<< "$home"$'\n'"$key" || {
      echo '目标用户写入失败；请检查目录属主和权限，未以 root 强行修正。'; return 1;
    }
  else
    echo '缺少 runuser/su，无法安全降权写入普通用户公钥。'
    return 1
  fi
  echo '请另开一个终端，用对应私钥测试登录；不要关闭当前会话。'
}

list_keys() {
  local user home file
  read -r -p '目标用户名 [root]: ' user || return 1
  user=${user:-root}
  id "$user" >/dev/null 2>&1 || { echo '用户不存在。'; return 1; }
  home=$(user_home "$user")
  [[ -n "$home" ]] || { echo '无法确定用户家目录。'; return 1; }
  file="$home/.ssh/authorized_keys"
  if [[ -f "$file" ]]; then
    echo "授权公钥列表：$file"
    nl -ba "$file"
  else
    echo '没有找到 authorized_keys。'
  fi
}

verify_policy() {
  local output=$1 pass=$2 kbd=$3 pub root_policy actual_pass actual_kbd
  pub=$(get_value pubkeyauthentication "$output")
  actual_pass=$(get_value passwordauthentication "$output")
  actual_kbd=$(get_value kbdinteractiveauthentication "$output")
  root_policy=$(get_value permitrootlogin "$output")

  [[ "$pub" == yes ]] || { echo '检查失败：PubkeyAuthentication 不是 yes。'; return 1; }
  [[ "$pass" == "$actual_pass" ]] || { echo '检查失败：PasswordAuthentication 不符合预期。'; return 1; }
  [[ "$kbd" == "$actual_kbd" ]] || { echo '检查失败：KbdInteractiveAuthentication 不符合预期。'; return 1; }
  # OpenSSH 的 prohibit-password 与旧别名 without-password 语义相同。
  [[ "$root_policy" == prohibit-password || "$root_policy" == without-password ]] || {
    echo "检查失败：PermitRootLogin 实际值为 ${root_policy:-未知}。"
    return 1
  }
}

apply_mode() {
  local mode=$1 already_confirmed=${2:-no}
  local dir original tmp filtered pass kbd context output config_mode config_owner

  if [[ "$mode" == lock ]]; then
    echo '将一次性设置以下四项 SSH 认证参数：'
    echo '  PermitRootLogin prohibit-password'
    echo '  PubkeyAuthentication yes'
    echo '  PasswordAuthentication no'
    echo '  KbdInteractiveAuthentication no'
    echo
    echo '这会关闭全局密码和 keyboard-interactive 认证；Match 规则仍可能对特定连接覆盖。'
    echo '请确保已从另一个终端使用密钥成功登录，并保留当前会话。'
    if [[ "$already_confirmed" != yes ]]; then
      read -r -p '已从新会话成功使用密钥登录？输入 YES 继续：' context || return 1
      [[ "$context" == YES ]] || { echo '已取消。'; return 1; }
    fi
    pass=no; kbd=no
  else
    echo '将重新开启普通用户的密码与 keyboard-interactive 认证；Root 仍仅允许密钥登录。'
    read -r -p '输入 YES 继续：' context || return 1
    [[ "$context" == YES ]] || { echo '已取消。'; return 1; }
    pass=yes; kbd=yes
  fi

  tmp=$(mktemp "$(dirname "$CONFIG")/.ssh-keyguard.XXXXXX") || return 1
  # 删除主配置文件中原有的全局同名设置；保留 Match 段及其他配置。
  # 新设置放在 Include 之前，利用 OpenSSH 对全局选项“先出现者生效”的规则。
  if ! awk '
    BEGIN { in_match=0 }
    /^[[:space:]]*#/ { print; next }
    tolower($1)=="match" { in_match=1; print; next }
    !in_match && (tolower($1)=="pubkeyauthentication" || tolower($1)=="passwordauthentication" || tolower($1)=="kbdinteractiveauthentication" || tolower($1)=="permitrootlogin") { next }
    { print }
  ' "$CONFIG" > "$tmp"; then
    echo '读取/处理 SSH 配置失败。'; rm -f "$tmp"; return 1
  fi
  filtered="${tmp}.filtered"
  if ! {
    printf 'PermitRootLogin prohibit-password\nPubkeyAuthentication yes\nPasswordAuthentication %s\nKbdInteractiveAuthentication %s\n' "$pass" "$kbd"
    cat "$tmp"
  } > "$filtered"; then
    echo '生成新配置失败。'; rm -f "$tmp" "$filtered"; return 1
  fi
  config_mode=$(stat -c '%a' "$CONFIG") || { echo '读取配置文件权限失败。'; rm -f "$tmp" "$filtered"; return 1; }
  config_owner=$(stat -c '%u:%g' "$CONFIG") || { echo '读取配置文件属主失败。'; rm -f "$tmp" "$filtered"; return 1; }
  if ! chown "$config_owner" "$filtered" || ! chmod "$config_mode" "$filtered"; then
    echo '保留配置文件权限/属主失败。'; rm -f "$tmp" "$filtered"; return 1
  fi

  output=$("$SSHD" -T -f "$filtered" 2>&1) || {
    echo "新配置语法或解析检查失败，原配置未修改：$output"
    rm -f "$tmp" "$filtered"
    return 1
  }
  if ! verify_policy "$output" "$pass" "$kbd"; then
    echo '新配置的有效值不符合预期，原配置未修改。'
    rm -f "$tmp" "$filtered"
    return 1
  fi

  dir=$(backup) || { echo '自动备份失败，未修改配置。'; rm -f "$tmp" "$filtered"; return 1; }
  original="$dir/sshd_config"
  if ! mv -f "$filtered" "$CONFIG"; then
    echo '安装新配置失败，原配置未修改。'; rm -f "$tmp" "$filtered"; return 1
  fi
  rm -f "$tmp"

  if ! "$SSHD" -t -f "$CONFIG"; then
    echo '完整配置验证失败，正在恢复备份。'
    rollback_config "$original" || true
    return 1
  fi
  output=$("$SSHD" -T -f "$CONFIG" 2>&1) || {
    echo '读取新配置的生效值失败，正在恢复备份。'
    rollback_config "$original" || true
    return 1
  }
  if ! verify_policy "$output" "$pass" "$kbd"; then
    echo '实际生效配置不符合预期，正在恢复备份。'
    rollback_config "$original" || true
    return 1
  fi
  if ! service_reload; then
    echo 'SSH 重载/重启失败，正在恢复备份并尝试再次重载。'
    rollback_config "$original" yes || true
    return 1
  fi

  echo "配置已应用。自动备份位置：$dir"
  echo
  status || true
  echo '重要：不要关闭当前 SSH 会话，请另开连接再次验证。'
}

filter_auth_logs() {
  # Compare whole tokens, never IP address prefixes or regex fragments.
  awk -v user="$1" -v addr="$2" '
    /Accepted |Failed |Invalid user/ {
      for (i=2; i<NF; i++) {
        if ($i=="from" && $(i-1)==user && $(i+1)==addr && !seen[$0]++) {
          print; break
        }
      }
    }
  ' | tail -n 10
}

show_auth_logs() {
  local user=$1 addr=$2 logs matched log_file found=no
  if command -v journalctl >/dev/null 2>&1; then
    # journalctl orders entries chronologically and enforces this time window.
    logs=$(journalctl -q -t sshd --since '24 hours ago' -n 1500 --no-pager -o short-iso 2>/dev/null || true)
    if [[ -z "$logs" ]]; then
      logs=$(journalctl -q -u ssh.service -u sshd.service --since '24 hours ago' -n 1500 --no-pager -o short-iso 2>/dev/null || true)
    fi
    matched=$(filter_auth_logs "$user" "$addr" <<< "$logs") || return 1
    if [[ -n "$matched" ]]; then
      echo 'journal：最近 24 小时内最后 1500 条候选中的匹配认证记录（最多 10 条）：'
      printf '%s\n' "$matched"
      found=yes
    fi
  fi
  # Raw syslog formats may omit year/timezone. Keep each source separate and
  # do not present these records as a verified 24-hour window or merged order.
  if command -v logread >/dev/null 2>&1; then
    logs=$(logread 2>/dev/null | tail -n 1500 || true)
    matched=$(filter_auth_logs "$user" "$addr" <<< "$logs") || return 1
    if [[ -n "$matched" ]]; then
      echo 'logread：末尾 1500 条候选中的匹配记录（最多 10 条，未验证时间范围）：'
      printf '%s\n' "$matched"
      found=yes
    fi
  fi
  for log_file in /var/log/auth.log /var/log/secure /var/log/messages; do
    [[ -r "$log_file" ]] || continue
    logs=$(tail -n 1500 "$log_file" 2>/dev/null || true)
    matched=$(filter_auth_logs "$user" "$addr" <<< "$logs") || return 1
    if [[ -n "$matched" ]]; then
      printf '%s：末尾 1500 条候选中的匹配记录（最多 10 条，未验证时间范围）：\n' "$log_file"
      printf '%s\n' "$matched"
      found=yes
    fi
  done
  if [[ "$found" == no ]]; then
    echo '未在可读取的日志候选中匹配到该用户/IP 的成功或失败认证记录。'
    echo '这不代表没有登录；日志可能未保留、未启用或记录在候选范围外。'
  fi
}

check_current_connection() {
  local conn_user conn_addr conn_laddr conn_lport conn_rport user addr spec output
  conn_user="${SUDO_USER:-}"
  if [[ -z "$conn_user" ]]; then conn_user=$(logname 2>/dev/null || printf 'root'); fi
  conn_addr=""; conn_laddr=""; conn_lport=""; conn_rport=""

  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    read -r conn_addr conn_rport conn_laddr conn_lport <<< "$SSH_CONNECTION"
  elif [[ -n "${SSH_CLIENT:-}" ]]; then
    read -r conn_addr conn_rport conn_lport <<< "$SSH_CLIENT"
  fi

  echo '========== 当前连接认证检查 =========='
  echo '先显示全局配置，再尽可能按当前用户/来源 IP 计算 Match 条件。'
  echo
  status || true

  read -r -p "SSH 登录用户名 [${conn_user:-root}]: " user || return 1
  user=${user:-${conn_user:-root}}
  addr="$conn_addr"
  if [[ -z "$addr" ]]; then
    read -r -p '当前 SSH 客户端公网/出口 IP（未知可留空）: ' addr || return 1
  fi

  spec="user=$user"
  [[ -n "$addr" ]] && spec+=",addr=$addr"
  [[ -n "$conn_laddr" ]] && spec+=",laddr=$conn_laddr"
  [[ -n "$conn_lport" ]] && spec+=",lport=$conn_lport"
  output=$("$SSHD" -T -C "$spec" -f "$CONFIG" 2>&1) || {
    echo "按连接上下文计算失败：$output"
    return 1
  }
  echo
  echo "按连接上下文计算的认证策略（$spec）："
  show_policy "$output"
  echo '注意：若配置含 Match Host 等条件，未提供的匹配条件仍需人工核对。'

  if [[ -n "$addr" ]]; then
    echo
    show_auth_logs "$user" "$addr"
  else
    echo
    echo '未提供来源 IP，跳过登录日志匹配。'
  fi
}

restore() {
  local dir safety path
  echo '最近备份：'
  for path in "$BACKUP_DIR"/*; do
    [[ -d "$path" ]] && basename "$path"
  done | sort -r | head -15
  read -r -p '输入要恢复的备份目录名称：' dir || return 1
  [[ "$dir" =~ ^[0-9]{8}-[0-9]{6}-[0-9]+(-[0-9]+|-N|\.[A-Za-z0-9]{6})?$ && -f "$BACKUP_DIR/$dir/sshd_config" ]] || {
    echo '备份不存在或名称无效。'
    return 1
  }
  if ! "$SSHD" -t -f "$BACKUP_DIR/$dir/sshd_config"; then
    echo '备份配置未通过 sshd 语法检查，拒绝恢复。'
    return 1
  fi
  safety=$(backup) || { echo '当前配置备份失败，未执行恢复。'; return 1; }
  cp -a "$BACKUP_DIR/$dir/sshd_config" "$CONFIG" || return 1
  if ! "$SSHD" -t -f "$CONFIG"; then
    echo '恢复后配置验证失败，尝试回滚到恢复前配置。'
    rollback_config "$safety/sshd_config" || true
    return 1
  fi
  if ! service_reload; then
    echo '恢复失败，尝试回滚到恢复前配置。'
    rollback_config "$safety/sshd_config" yes || true
    return 1
  fi
  echo "已恢复。恢复前配置备份：$safety"
  status || true
}

while true; do
  echo
  echo '========== SSH KeyGuard =========='
  echo "轻量 SSH 密钥管理与安全加固工具 v$APP_VERSION"
  echo "当前系统：$DISTRO_NAME"
  echo '----------------------------------'
  echo '1. 添加 SSH 公钥'
  echo '2. 查看授权公钥'
  echo '3. 检查 SSH 全局认证配置'
  echo '4. 一键应用四项 SSH 密钥安全配置（先验证密钥）'
  echo '5. 恢复普通用户密码认证（Root 仍仅限密钥）'
  echo '6. 备份 SSH 配置'
  echo '7. 恢复 SSH 配置'
  echo '8. 检查当前连接策略与最近登录记录'
  echo '0. 退出'
  echo '----------------------------------'
  read -r -p '请选择：' choice || break
  case "$choice" in
    1) add_key || true ;;
    2) list_keys || true ;;
    3) status || true ;;
    4) apply_mode lock || true ;;
    5) apply_mode unlock || true ;;
    6) echo "已备份：$(backup)" ;;
    7) restore || true ;;
    8) check_current_connection || true ;;
    0) exit 0 ;;
    *) echo '无效选项，请输入 0–8。' ;;
  esac
  pause
done
