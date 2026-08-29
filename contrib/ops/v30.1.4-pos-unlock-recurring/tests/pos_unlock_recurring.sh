#!/usr/bin/env bash
export LC_ALL=C TZ=UTC
set -Eeuo pipefail
umask 077

package_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
tool="$package_dir/pos_unlock_recurring.sh"
helper="$package_dir/../v30.1.5-rollout-durability/blackcoin_node_normal_unlock.sh"
tests=0
failures=0

ok() { tests=$((tests + 1)); printf 'ok %03d - %s\n' "$tests" "$1"; }
not_ok() { tests=$((tests + 1)); failures=$((failures + 1)); printf 'not ok %03d - %s\n' "$tests" "$1"; }
expect_pass()
{
    local name=$1 output
    shift
    if output=$("$@" 2>&1); then ok "$name"; else not_ok "$name"; printf '# %s\n' "$output"; fi
}
expect_fail()
{
    local name=$1
    shift
    if "$@" >/dev/null 2>&1; then not_ok "$name"; else ok "$name"; fi
}

cron_is_exact_unraid_root_fragment()
{
    local file=$1 expected
    expected='7 * * * * /usr/bin/env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin /bin/bash --noprofile --norc /boot/config/plugins/blackcoin-quantum-nodes/pos-unlock-recurring/pos_unlock_recurring.sh >/dev/null 2>&1'
    [[ -f "$file" && ! -L "$file" ]] || return 1
    [[ "$(wc -l <"$file" | tr -d ' ')" == 1 ]] || return 1
    [[ "$(sed -n '1p' "$file")" == "$expected" ]] || return 1
    [[ "$(awk '{print $6}' "$file")" == /usr/bin/env ]] || return 1
    ! grep -Eq '^[[:space:]]*(SHELL|PATH)[[:space:]]*=' "$file"
}

cron_is_authority_free_and_environment_clean()
{
    local file=$1
    ! grep -Eiq 'authority|receipt-sha|valid-until' "$file" &&
      [[ "$(awk '{print $6}' "$file")" == /usr/bin/env ]] &&
      ! grep -Eq '^[[:space:]]*(SHELL|PATH)[[:space:]]*=' "$file"
}

tmp=$(realpath "$(mktemp -d "${TMPDIR:-/tmp}/pos-unlock-recurring-tests.XXXXXX")")
trap 'rm -rf -- "$tmp"' EXIT

expect_pass 'Bash syntax is valid' bash -n "$tool"
expect_pass 'ShellCheck accepts the wrapper' shellcheck "$tool"
expect_pass 'installed helper remains the exact pinned bytes' bash -c \
  'test "$(sha256sum "$1" | cut -d " " -f 1)" = aa924baf0a9d384759019d50e3815e03e264b906c7b51ecc76023c854b91a3e7' \
  bash "$helper"
expect_pass 'wrapper pins the exact installed helper and canonical path' bash -c \
  "grep -Fqx \"readonly POS_HELPER='/boot/config/plugins/blackcoin-quantum-nodes/blackcoin_node_normal_unlock.sh'\" \"\$1\" &&
   grep -Fqx \"readonly POS_HELPER_SHA256='aa924baf0a9d384759019d50e3815e03e264b906c7b51ecc76023c854b91a3e7'\" \"\$1\"" \
  bash "$tool"
expect_pass 'canonical supervisor lock order is preserved' bash -c \
  'awk "/readonly -a POS_SHARED_LOCKS=/{f=1} f{print} /^\\)/{if(f)exit}" "$1" | grep -Fq /run/blackcoin-v3015-rollout.lock &&
   grep -Fq "POS_GLOBAL_LOCK=" "$1" && grep -Fq "/run/blackcoin-emergency-pos-renewal.lock" "$1" &&
   grep -Fq "POS_PER_NODE_LOCK_PATTERN=" "$1" && grep -Fq "/run/blackcoin-pos-unlock-renewal-node-%02d.lock" "$1"' \
  bash "$tool"
cron_file="$package_dir/blackcoin-pos-unlock-recurring.cron"
expect_pass 'cron is the exact one-line Unraid root fragment' \
  cron_is_exact_unraid_root_fragment "$cron_file"
expect_pass 'cron remains hourly authority-free and environment-clean' \
  cron_is_authority_free_and_environment_clean "$cron_file"

old_system_cron="$tmp/old-system.cron"
printf '%s\n' \
  'SHELL=/bin/bash' \
  'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
  '7 * * * * root /usr/bin/env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin /bin/bash --noprofile --norc /boot/config/plugins/blackcoin-quantum-nodes/pos-unlock-recurring/pos_unlock_recurring.sh >/dev/null 2>&1' \
  >"$old_system_cron"
expect_fail 'old system-crontab form is rejected as an Unraid fragment' \
  cron_is_exact_unraid_root_fragment "$old_system_cron"

root_column_cron="$tmp/root-column.cron"
printf '%s\n' \
  '7 * * * * root /usr/bin/env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin /bin/bash --noprofile --norc /boot/config/plugins/blackcoin-quantum-nodes/pos-unlock-recurring/pos_unlock_recurring.sh >/dev/null 2>&1' \
  >"$root_column_cron"
expect_fail 'standalone root user column is rejected' \
  cron_is_exact_unraid_root_fragment "$root_column_cron"
expect_pass 'wrapper has no financial PoW chain or role-changing interface' bash -c \
  '! grep -Eiq "sendrawtransaction|setpowmining|createwallet|import(privkey|descriptors)|reindex|rewind|repairwallet|abandontransaction|walletpassphrase|fee[_ -]?rate|payout[_ -]?address" "$1" &&
   ! grep -Eq "docker[[:space:]]+(stop|start|restart|rm)|staking[[:space:]]+false" "$1"' \
  bash "$tool"
expect_pass 'wrapper only invokes helper with one canonical node argument' bash -c \
  'grep -Fq "/bin/bash --noprofile --norc \"\$POS_HELPER_SNAPSHOT\" \"\$node\"" "$1" &&
   grep -Fq "for node in \$(seq 1 \"\$POS_NODE_COUNT\")" "$1"' \
  bash "$tool"
expect_pass 'receipt denies external authority and out-of-scope actions' bash -c \
  'grep -Fq "authority:{external_required:false,expires:false}" "$1" &&
   grep -Fq "financial_action:false,pow_action:false,chain_action:false" "$1" &&
   grep -Fq "node30_role_change:false" "$1"' \
  bash "$tool"

# Source-only unit tests do not call the fixed live main path.
# shellcheck disable=SC1090
source "$tool"
uid=$(id -u)
gid=$(stat -c '%g' "$tmp" 2>/dev/null || stat -f '%g' "$tmp")

# macOS lacks the util-linux flock command. This test adapter exercises the
# same kernel advisory locks through Python's fcntl wrapper on the inherited
# file descriptor; live execution still requires and uses util-linux flock.
flock()
{
    local operation fd
    case "${1:-}" in
        -n) operation=lock; fd=$2 ;;
        -u) operation=unlock; fd=$2 ;;
        *) return 64 ;;
    esac
    python3 - "$operation" "$fd" <<'PY'
import fcntl
import sys

operation, descriptor = sys.argv[1], int(sys.argv[2])
flag = fcntl.LOCK_UN if operation == "unlock" else fcntl.LOCK_EX | fcntl.LOCK_NB
try:
    fcntl.flock(descriptor, flag)
except BlockingIOError:
    raise SystemExit(1)
PY
}

helper_copy="$tmp/helper"
cp "$helper" "$helper_copy"
chmod 600 "$helper_copy"
expect_pass 'exact helper copy passes identity gate' pos_verify_helper "$helper_copy" "$uid" "$gid"
printf '\n' >>"$helper_copy"
expect_fail 'one-byte helper change fails identity gate' pos_verify_helper "$helper_copy" "$uid" "$gid"

regular="$tmp/regular"
: >"$regular"
chmod 600 "$regular"
expect_pass 'secure singleton passes file gate' pos_secure_regular_file "$regular" 600 "$uid" "$gid"
chmod 644 "$regular"
expect_fail 'wrong mode fails file gate' pos_secure_regular_file "$regular" 600 "$uid" "$gid"
chmod 600 "$regular"
ln "$regular" "$tmp/hardlink"
expect_fail 'hardlinked input fails file gate' pos_secure_regular_file "$regular" 600 "$uid" "$gid"
rm "$tmp/hardlink"
ln -s "$regular" "$tmp/symlink"
expect_fail 'symlink input fails file gate' pos_secure_regular_file "$tmp/symlink" 600 "$uid" "$gid"

# A holder created in another process proves the nonblocking no-overlap lock.
# The lower-level primitive is identical; live callers additionally require
# every lock pathname to be under /run.
lock="$tmp/no-overlap.lock"
( pos_acquire_verified_lock "$lock" "$uid" "$gid"; printf ready >"$tmp/ready"; sleep 8 ) &
holder=$!
for _ in $(seq 1 40); do [[ -f "$tmp/ready" ]] && break; sleep 0.05; done
expect_pass 'first process holds the renewal lock' test -f "$tmp/ready"
expect_fail 'second process cannot overlap the held renewal lock' \
  pos_acquire_verified_lock "$lock" "$uid" "$gid"
kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true
rm -f "$lock"

# One failed helper cannot starve later nodes in the same recurring cycle.
invoke_log="$tmp/invocations"
pos_invoke_helper()
{
    printf '%s\n' "$1" >>"$invoke_log"
    [[ "$1" != 7 && "$1" != 30 ]]
}
POS_ATTEMPTED='[]'
POS_SUCCEEDED='[]'
POS_FAILED='[]'
pos_run_cycle
expect_pass 'cycle attempts every node despite isolated failures' bash -c \
  'test "$(wc -l < "$1" | tr -d " ")" = 32 && test "$(tail -1 "$1")" = 32' \
  bash "$invoke_log"
expect_pass 'cycle records exact failed subset' jq -e '. == [7,30]' <<<"$POS_FAILED"
expect_pass 'cycle records all 30 successful nodes' jq -e 'length == 30 and index(7) == null and index(30) == null' <<<"$POS_SUCCEEDED"
expect_pass 'cycle records canonical attempted order' jq -e '. == [range(1;33)]' <<<"$POS_ATTEMPTED"

expect_pass 'package manifest is exact and valid' bash -c '
  set -euo pipefail
  cd "$1"
  actual=$(find . -type f ! -name SHA256SUMS -print | LC_ALL=C sort)
  listed=$(sed -E "s/^[0-9a-f]{64}  //" SHA256SUMS | LC_ALL=C sort)
  test "$actual" = "$listed"
  test "$(printf "%s\n" "$listed" | wc -l | tr -d " ")" = 4
  sha256sum --strict -c SHA256SUMS >/dev/null
' bash "$package_dir"

printf '1..%d\n' "$tests"
if ((failures != 0)); then
    printf '%d/%d tests failed\n' "$failures" "$tests" >&2
    exit 1
fi
printf '%d/%d tests passed\n' "$tests" "$tests"
