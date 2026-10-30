#!/usr/bin/env bash
# Uses a pseudo-terminal and fake downloads; never accesses the network/sshd.
set -euo pipefail
[[ $EUID == 0 ]] || { echo 'Run as root to test the launcher root check.'; exit 1; }
script_bin=$(command -v script) || { echo 'This test needs the script utility (util-linux).'; exit 1; }
launcher=$(cd "$(dirname "$0")/.." && pwd)/install.sh
work=$(mktemp -d /tmp/keyguard-launcher-test.XXXXXX)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin" "$work/tmp"
for tool in id mktemp rm bash sh cat cp; do ln -s "$(command -v "$tool")" "$work/bin/$tool"; done
export KG_TEST_WORK="$work" KG_LAUNCHER="$launcher" TMPDIR="$work/tmp"
export KG_MANAGER="$(dirname "$launcher")/ssh-keyguard.sh"
export SSH_KEYGUARD_CONFIG="$work/sshd_config" SSH_KEYGUARD_BACKUP_DIR="$work/backups" SSHD_BIN=/bin/true
printf '# isolated fixture\n' > "$SSH_KEYGUARD_CONFIG"
cat > "$work/bin/curl" <<'MOCK'
#!/bin/sh
target=''
while [ "$#" -gt 0 ]; do
  case "$1" in -o|-O) target=$2; shift;; esac
  shift
done
if [ -z "$target" ]; then cat "$KG_LAUNCHER"; exit 0; fi
case "$KG_TEST_MODE" in
  partial) printf 'echo unsafe > "%s/marker"\n' "$KG_TEST_WORK" > "$target"; exit 22;;
  empty) : > "$target";;
  syntax) printf 'if then\n' > "$target";;
  menu) cp "$KG_MANAGER" "$target";;
  *)
    cat > "$target" <<'MANAGER'
#!/usr/bin/env bash
IFS= read -r answer
[[ "$answer" == menu-input ]] || exit 90
printf 'menu-ok\n' > "$KG_TEST_WORK/marker"
exit "${KG_TEST_EXIT:-0}"
MANAGER
    ;;
esac
MOCK
chmod 755 "$work/bin/curl"
cp "$work/bin/curl" "$work/bin/wget"
run_case() {
  local mode=$1 expected=$2 backend=${3:-curl} status=0
  rm -f "$work/marker"
  local input=menu-input
  [[ $mode != menu ]] || input=0
  printf '%s\n' "$input" | env PATH="$work/bin" KG_TEST_MODE="$mode" \
    "$script_bin" -q -e -c "$backend -fsSL launcher-url | sh" /dev/null > "$work/output" 2>&1 || status=$?
  [[ $status == "$expected" ]] || { cat "$work/output"; echo "FAIL: $mode exit=$status"; exit 1; }
  if [[ $mode == success ]]; then
    [[ -f "$work/marker" ]] || { echo 'FAIL: menu did not receive terminal input'; exit 1; }
  else
    [[ ! -f "$work/marker" ]] || { echo 'FAIL: unverified script was run'; exit 1; }
  fi
  if [[ $mode == menu ]]; then
    grep -q 'SSH KeyGuard' "$work/output" || { cat "$work/output"; echo 'FAIL: real menu not shown'; exit 1; }
  fi
  [[ -z $(find "$work/tmp" -mindepth 1 -print -quit) ]] || { echo 'FAIL: temporary download not cleaned'; exit 1; }
  echo "PASS: $backend $mode (status $status; cleaned)"
}
run_case success 0
run_case partial 1
run_case empty 1
run_case syntax 1
export KG_TEST_EXIT=37
run_case success 37
unset KG_TEST_EXIT
# The real menu uses mkdir and the OS-release file, but never any service action.
ln -s "$(command -v mkdir)" "$work/bin/mkdir"
run_case menu 0
rm "$work/bin/curl"
run_case success 0 wget
echo 'All launcher checks passed; no network or SSH service used.'
