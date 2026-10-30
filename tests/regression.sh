#!/usr/bin/env bash
# No real SSH daemon or service manager is invoked. Run as root in Linux.
set -euo pipefail
umask 077
[[ $EUID == 0 ]] || { echo 'Run this isolated test as root (uses runuser/su for nobody).'; exit 1; }
src=$(cd "$(dirname "$0")/.." && pwd)/ssh-keyguard.sh
work=$(mktemp -d /tmp/keyguard-regression.XXXXXX)
trap 'rm -rf "$work"' EXIT
chmod 755 "$work"
export CONFIG="$work/config" BACKUP_DIR="$work/backups"
mkdir "$BACKUP_DIR" "$work/home" "$work/bin"
chmod 755 "$work/bin"
chown nobody "$work/home"
chmod 700 "$work/home"
source <(awk '/^pause\(\)/ {copy=1} /^while true; do/ {exit} copy' "$src")
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
printf '#!/bin/sh\nexit 0\n' > "$work/sshd"
chmod 755 "$work/sshd"
SSHD="$work/sshd"

# Service mocks: failed reload, failed restart leaves inactive, recovery succeeds.
mock_action() {
  local manager=$1 action=$2
  [[ $manager == "$backend" ]] || return 1
  case "$action" in
    status|is-active) [[ $state == active ]];;
    reload) echo reload >> "$work/calls"; return 1;;
    restart)
      echo restart >> "$work/calls"
      attempts=$((attempts+1))
      if [[ $attempts == 1 ]]; then state=inactive; return 1; fi
      state=active;;
    *) return 1;;
  esac
}
systemctl() { mock_action systemd "$1"; }
rc-service() { mock_action openrc "$2"; }
service() { mock_action sysv "$2"; }
for backend in systemd openrc sysv; do
  state=active; attempts=0; : > "$work/calls"
  printf 'original\n' > "$work/original"
  printf 'changed\n' > "$CONFIG"
  if service_reload > "$work/output" 2>&1; then fail "$backend must simulate failed restart"; fi
  [[ $state == inactive && $SERVICE_MANAGER == "$backend" ]] || fail 'lost service identity'
  rollback_config "$work/original" yes >> "$work/output" 2>&1 || fail "$backend recovery failed"
  [[ $state == active && $attempts == 2 ]] || fail "$backend did not restart inactive service"
  cmp "$CONFIG" "$work/original" || fail 'config not restored'
  pass "$backend restarts original service after failed restart"
done
backend=systemd; state=inactive; attempts=0
SERVICE_MANAGER=systemd; SERVICE_NAME=ssh.service
service_action() { return 1; }
if rollback_config "$work/original" yes > "$work/output" 2>&1; then fail 'recovery failure hidden'; fi
grep -q '严重错误' "$work/output" || fail 'missing recovery warning'
grep -q 'systemctl restart' "$work/output" || fail 'missing rescue command'
pass 'persistent service recovery failure is reported with rescue command'
# Reload original definitions to restore service_action.
source <(awk '/^pause\(\)/ {copy=1} /^while true; do/ {exit} copy' "$src")

# Exercise the actual configuration transaction, not only the recovery helper.
cat > "$work/sshd" <<'MOCK_SSHD'
#!/bin/sh
for arg do config=$arg; done
if [ "$1" = -t ]; then exit 0; fi
if [ "${KG_REJECT_CANDIDATE:-no}" = yes ]; then exit 1; fi
awk '!/^#/ {print tolower($1), tolower($2)}' "$config"
MOCK_SSHD
printf '# fixture\nPasswordAuthentication yes\n' > "$CONFIG"
cp "$CONFIG" "$work/original"
backend=systemd; state=active; attempts=0; : > "$work/calls"
if apply_mode lock yes > "$work/output" 2>&1; then fail 'failed apply reported success'; fi
cmp "$CONFIG" "$work/original" || fail 'apply did not roll back config'
[[ $state == active && $attempts == 2 ]] || fail 'apply did not restore service'
pass 'apply transaction restores config and restarts stopped service on failure'
attempts=1; state=active
apply_mode lock yes > "$work/output" 2>&1 || fail 'valid apply rejected'
grep -q '^PasswordAuthentication no$' "$CONFIG" || fail 'lock configuration not installed'
pass 'valid candidate installs and verifies requested policy'
cp "$CONFIG" "$work/before"
export KG_REJECT_CANDIDATE=yes
if apply_mode lock yes > "$work/output" 2>&1; then fail 'bad candidate accepted'; fi
unset KG_REJECT_CANDIDATE
cmp "$CONFIG" "$work/before" || fail 'bad candidate modified config'
pass 'candidate validation failure leaves config unchanged'

ssh-keygen -q -t ed25519 -N '' -C old-key -f "$work/old"
ssh-keygen -q -t ed25519 -N '' -C new-key -f "$work/new"
key=$(cat "$work/new.pub")
user_home() { printf '%s\n' "$work/home"; }
mkdir "$work/home/.ssh"
tr -d '\n' < "$work/old.pub" > "$work/home/.ssh/authorized_keys"
chown -R nobody "$work/home"
add_key <<< $'nobody\n'"$key" > "$work/output" 2>&1 || fail 'valid key rejected'
[[ $(ssh-keygen -lf "$work/home/.ssh/authorized_keys" | wc -l) == 2 ]] || fail 'missing newline/key'
[[ $(stat -c %u "$work/home/.ssh/authorized_keys") == "$(id -u nobody)" ]] || fail 'incorrect owner'
pass 'missing final newline repaired; both real keys parse; file owned by target user'
cp "$work/home/.ssh/authorized_keys" "$work/before"
add_key <<< $'nobody\n'"$key" > "$work/output" 2>&1 || fail 'duplicate rejected'
cmp "$work/before" "$work/home/.ssh/authorized_keys" || fail 'duplicate modified file'
pass 'duplicate key does not modify file'
if add_key <<< $'nobody\nssh-ed25519 AAAA invalid-test' > "$work/output" 2>&1; then fail 'invalid key accepted'; fi
cmp "$work/before" "$work/home/.ssh/authorized_keys" || fail 'invalid key changed file'
pass 'invalid key rejected before writing'

# Force the Alpine-compatible su branch even when runuser is installed.
saved_path=$PATH
command() {
  if [[ ${1:-} == -v && ${2:-} == runuser ]]; then return 1; fi
  builtin command "$@"
}
rm "$work/home/.ssh/authorized_keys"
add_key <<< $'nobody\n'"$key" > "$work/output" 2>&1 || fail 'su fallback failed'
unset -f command
ssh-keygen -lf "$work/home/.ssh/authorized_keys" > /dev/null || fail 'su key invalid'
pass 'su fallback works for an account with a disabled login shell'

# Deterministically simulate the path replacement after the symlink check.
printf 'protected\n' > "$work/victim"
chmod 644 "$work/victim"
cp "$work/victim" "$work/victim-before"
rm "$work/home/.ssh/authorized_keys"
cat > "$work/bin/touch" <<MOCK
#!/bin/sh
ln -s '$work/victim' "\$1"
MOCK
chmod 755 "$work/bin/touch"
PATH="$work/bin:$PATH"
if add_key <<< $'nobody\n'"$key" > "$work/output" 2>&1; then fail 'symlink swap accepted'; fi
PATH=$saved_path
cmp "$work/victim" "$work/victim-before" || fail 'root-owned victim corrupted'
[[ $(stat -c %u:%a "$work/victim") == 0:644 ]] || fail 'victim owner/mode changed'
pass 'post-check symlink swap cannot chmod, chown or append to root-owned file'
if add_key <<< $'nobody\n'"$key" > "$work/output" 2>&1; then fail 'existing symlink accepted'; fi
pass 'existing symlink refused'
if root_home_safe "$work/home"; then fail 'unsafe root home accepted'; fi
pass 'root home beneath world-writable parent refused'

logs=$'2020-01-01 sshd[1]: Accepted password for root from 203.0.113.123 port 1 ssh2\n2026-10-30 sshd[2]: Accepted publickey for root from 203.0.113.1 port 2 ssh2\n2026-10-30 sshd[3]: Failed password for invalid user root from 203.0.113.1 port 3 ssh2\n2026-10-30 sshd[4]: Invalid user root from 203.0.113.1 port 4\n2026-10-30 sshd[5]: Accepted password for root2 from 203.0.113.1 port 5 ssh2'
filtered=$(filter_auth_logs root 203.0.113.1 <<< "$logs")
[[ $(wc -l <<< "$filtered") == 3 ]] || fail 'log token filtering failed'
if grep -q '203.0.113.123\|root2' <<< "$filtered"; then fail 'address/user prefix matched'; fi
pass 'logs require exact IP and username for success/failure/invalid-user events'
journalctl() { return 0; }
logread() { printf '%s\n' '2020-01-01 sshd[1]: Accepted password for root from 203.0.113.1 port 1 ssh2'; }
output=$(show_auth_logs root 203.0.113.1)
grep -q '未验证时间范围' <<< "$output" || fail 'raw log time range not labeled'
if grep -q '最近 24 小时' <<< "$output"; then fail 'stale raw log marked recent'; fi
pass 'raw log records have explicit unverified time range'
echo 'All regression checks passed. No real SSH service was touched.'
