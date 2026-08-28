#!/usr/bin/env bash
export LC_ALL=C TZ=UTC
set -Eeuo pipefail
umask 077
unset BASH_ENV ENV CDPATH GLOBIGNORE
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

# Recurring, nonfinancial PoS liveness for the exact installed v30.1.4 fleet.
# The pinned helper owns every wallet manifest, secret, RPC, unlock, and staking
# check.  This wrapper only serializes that helper across the 32 installed
# nodes and writes a small durable receipt.

readonly POS_INSTALL_PATH='/boot/config/plugins/blackcoin-quantum-nodes/pos-unlock-recurring/pos_unlock_recurring.sh'
readonly POS_HELPER='/boot/config/plugins/blackcoin-quantum-nodes/blackcoin_node_normal_unlock.sh'
readonly POS_HELPER_SHA256='aa924baf0a9d384759019d50e3815e03e264b906c7b51ecc76023c854b91a3e7'
readonly POS_RECEIPT_ROOT='/mnt/disk1/blackcoin-wallet-safety/runtime-audits/pos-unlock-recurring'
readonly POS_NODE_COUNT=32
readonly POS_HELPER_TIMEOUT_SECONDS=240
readonly POS_HELPER_KILL_AFTER_SECONDS=15
readonly POS_GLOBAL_LOCK='/run/blackcoin-emergency-pos-renewal.lock'
readonly POS_PER_NODE_LOCK_PATTERN='/run/blackcoin-pos-unlock-renewal-node-%02d.lock'
readonly -a POS_SHARED_LOCKS=(
    /run/blackcoin-v3015-rollout.lock
    /run/blackcoin-endpoint-guard.lock
    /run/blackcoin-node-cutover.lock
    /run/blackcoin-pow-quarantine-cycle.lock
    /run/blackcoin-wallet-runtime-guard.lock
)

declare -a POS_LOCK_FDS=()
POS_WORK_DIR=''
POS_HELPER_SNAPSHOT=''
POS_STARTED=false
POS_TERMINAL=false
POS_STARTED_EPOCH=''
POS_STARTED_UTC=''
POS_ATTEMPTED='[]'
POS_SUCCEEDED='[]'
POS_FAILED='[]'
POS_FAILURE_REASON='unexpected_exit'
POS_WRAPPER_SHA256=''

pos_die()
{
    printf 'pos unlock recurring: %s\n' "$*" >&2
    return 1
}

pos_sha256_file()
{
    sha256sum -- "$1" | awk '{print $1}'
}

pos_realpath_existing()
{
    [[ -e "$1" || -L "$1" ]] || return 1
    realpath -e -- "$1" 2>/dev/null || realpath -- "$1" 2>/dev/null
}

pos_secure_regular_file()
{
    local file=$1 mode=$2 uid=$3 gid=$4 actual
    [[ -f "$file" && ! -L "$file" ]] || return 1
    [[ "$(pos_realpath_existing "$file")" == "$file" ]] || return 1
    actual=$(stat -c '%u:%g:%a:%h' -- "$file" 2>/dev/null ||
      stat -f '%u:%g:%Lp:%l' -- "$file" 2>/dev/null) || return 1
    [[ "$actual" == "$uid:$gid:$mode:1" ]]
}

pos_secure_directory()
{
    local directory=$1 mode=$2 uid=$3 gid=$4 actual
    [[ -d "$directory" && ! -L "$directory" ]] || return 1
    [[ "$(pos_realpath_existing "$directory")" == "$directory" ]] || return 1
    actual=$(stat -c '%u:%g:%a' -- "$directory" 2>/dev/null ||
      stat -f '%u:%g:%Lp' -- "$directory" 2>/dev/null) || return 1
    [[ "$actual" == "$uid:$gid:$mode" ]]
}

pos_verify_helper()
{
    local helper=$1 uid=$2 gid=$3
    pos_secure_regular_file "$helper" 600 "$uid" "$gid" &&
      [[ "$(pos_sha256_file "$helper")" == "$POS_HELPER_SHA256" ]]
}

pos_acquire_verified_lock()
{
    local path=$1 uid=$2 gid=$3 fd inode_path inode_fd
    [[ "$path" == /* && ! -L "$path" ]] || return 1
    exec {fd}<>"$path" || return 1
    if ! pos_secure_regular_file "$path" 600 "$uid" "$gid"; then
        exec {fd}>&-
        return 1
    fi
    if [[ -e "/proc/$$/fd/$fd" ]]; then
        inode_path=$(stat -Lc '%d:%i' -- "$path") || { exec {fd}>&-; return 1; }
        inode_fd=$(stat -Lc '%d:%i' -- "/proc/$$/fd/$fd") || { exec {fd}>&-; return 1; }
        [[ "$inode_path" == "$inode_fd" ]] || { exec {fd}>&-; return 1; }
    fi
    if ! flock -n "$fd"; then
        exec {fd}>&-
        return 1
    fi
    POS_LOCK_FDS+=("$fd")
}

pos_acquire_lock()
{
    [[ "$1" == /run/* ]] || return 1
    pos_acquire_verified_lock "$@"
}

pos_acquire_fleet_locks()
{
    local uid=$1 gid=$2 shared node padded path
    for shared in "${POS_SHARED_LOCKS[@]}"; do
        pos_acquire_lock "$shared" "$uid" "$gid" || return 1
    done
    pos_acquire_lock "$POS_GLOBAL_LOCK" "$uid" "$gid" || return 1
    for node in $(seq 1 "$POS_NODE_COUNT"); do
        printf -v padded '%02d' "$node"
        path=${POS_PER_NODE_LOCK_PATTERN/'%02d'/$padded}
        pos_acquire_lock "$path" "$uid" "$gid" || return 1
    done
}

pos_release_locks()
{
    local index fd
    for ((index=${#POS_LOCK_FDS[@]} - 1; index >= 0; index--)); do
        fd=${POS_LOCK_FDS[$index]}
        flock -u "$fd" 2>/dev/null || true
        exec {fd}>&-
    done
    POS_LOCK_FDS=()
}

pos_prepare_helper_snapshot()
{
    pos_verify_helper "$POS_HELPER" 0 0 || return 1
    POS_WORK_DIR=$(mktemp -d /run/.blackcoin-pos-unlock-recurring.XXXXXX) || return 1
    chown root:root "$POS_WORK_DIR" || return 1
    chmod 700 "$POS_WORK_DIR" || return 1
    pos_secure_directory "$POS_WORK_DIR" 700 0 0 || return 1
    POS_HELPER_SNAPSHOT="$POS_WORK_DIR/blackcoin_node_normal_unlock.sh"
    install -o root -g root -m 600 -- "$POS_HELPER" "$POS_HELPER_SNAPSHOT" || return 1
    pos_verify_helper "$POS_HELPER_SNAPSHOT" 0 0
}

pos_invoke_helper()
{
    local node=$1
    [[ "$node" =~ ^([1-9]|[12][0-9]|3[0-2])$ ]] || return 1
    pos_verify_helper "$POS_HELPER_SNAPSHOT" 0 0 || return 1
    /usr/bin/timeout --foreground --signal=TERM \
      --kill-after="$POS_HELPER_KILL_AFTER_SECONDS" "$POS_HELPER_TIMEOUT_SECONDS" \
      /usr/bin/env -i PATH="$PATH" LC_ALL=C TZ=UTC \
      /bin/bash --noprofile --norc "$POS_HELPER_SNAPSHOT" "$node" >/dev/null 2>&1
}

pos_run_cycle()
{
    local node
    for node in $(seq 1 "$POS_NODE_COUNT"); do
        POS_ATTEMPTED=$(jq -cn --argjson prior "$POS_ATTEMPTED" --argjson node "$node" \
          '$prior + [$node]')
        if pos_invoke_helper "$node"; then
            POS_SUCCEEDED=$(jq -cn --argjson prior "$POS_SUCCEEDED" --argjson node "$node" \
              '$prior + [$node]')
        else
            POS_FAILED=$(jq -cn --argjson prior "$POS_FAILED" --argjson node "$node" \
              '$prior + [$node]')
        fi
    done
}

pos_publish_receipt()
{
    local status=$1 reason=$2 finished_utc json temporary destination suffix receipt_sha
    pos_secure_directory "$POS_RECEIPT_ROOT" 700 0 0 || return 1
    finished_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ) || return 1
    json=$(jq -cn --arg status "$status" --arg reason "$reason" \
      --arg started "$POS_STARTED_UTC" --arg finished "$finished_utc" \
      --arg wrapper "$POS_WRAPPER_SHA256" --arg helper "$POS_HELPER_SHA256" \
      --argjson attempted "$POS_ATTEMPTED" --argjson succeeded "$POS_SUCCEEDED" \
      --argjson failed "$POS_FAILED" '{
        schema:1,kind:"blackcoin-pos-unlock-recurring",status:$status,reason:$reason,
        started_utc:$started,finished_utc:$finished,
        wrapper_sha256:$wrapper,helper_sha256:$helper,
        nodes:{attempted:$attempted,succeeded:$succeeded,failed:$failed},
        authority:{external_required:false,expires:false},
        scope:{nodes:[range(1;33)],normal_unlock:true,staking_true:true,
          financial_action:false,pow_action:false,chain_action:false,
          node30_role_change:false}
      }') || return 1
    temporary=$(mktemp "$POS_RECEIPT_ROOT/.receipt.XXXXXX") || return 1
    suffix=${temporary##*.receipt.}
    destination="$POS_RECEIPT_ROOT/renewal-$POS_STARTED_EPOCH-$suffix.json"
    printf '%s\n' "$json" >"$temporary" || return 1
    chown root:root "$temporary" || return 1
    chmod 600 "$temporary" || return 1
    sync -f "$temporary" || return 1
    mv -n -- "$temporary" "$destination" || return 1
    [[ ! -e "$temporary" && -f "$destination" && ! -L "$destination" ]] || return 1
    sync -f "$destination" || return 1
    sync -f "$POS_RECEIPT_ROOT" || return 1
    pos_secure_regular_file "$destination" 600 0 0 || return 1
    receipt_sha=$(pos_sha256_file "$destination") || return 1
    printf '%s %s\n' "$destination" "$receipt_sha"
}

pos_cleanup()
{
    pos_release_locks
    if [[ -n "$POS_WORK_DIR" &&
          "$POS_WORK_DIR" =~ ^/run/[.]blackcoin-pos-unlock-recurring[.][A-Za-z0-9]+$ &&
          -d "$POS_WORK_DIR" && ! -L "$POS_WORK_DIR" ]]; then
        rm -rf -- "$POS_WORK_DIR"
    fi
    POS_WORK_DIR=''
    POS_HELPER_SNAPSHOT=''
}

pos_on_exit()
{
    local rc=$?
    trap - EXIT HUP INT TERM
    set +e
    if [[ "$POS_STARTED" == true && "$POS_TERMINAL" == false ]]; then
        pos_publish_receipt PARTIAL "$POS_FAILURE_REASON" >/dev/null 2>&1
    fi
    pos_cleanup
    exit "$rc"
}

pos_signal()
{
    POS_FAILURE_REASON="signal_$1"
    exit "$2"
}

pos_main()
{
    local script_dir script_path status
    [[ "$#" -eq 0 ]] || return 64
    ((BASH_VERSINFO[0] >= 4)) || pos_die 'Bash 4 or newer required' || return
    [[ "$(id -u)" -eq 0 ]] || pos_die 'root required' || return
    for command in awk bash chown chmod date flock install jq mktemp mv realpath \
      rm seq sha256sum stat sync timeout; do
        command -v "$command" >/dev/null 2>&1 ||
          pos_die "required command unavailable: $command" || return
    done
    script_dir=$(CDPATH='' cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
    script_path="$script_dir/$(basename -- "${BASH_SOURCE[0]}")"
    [[ "$script_path" == "$POS_INSTALL_PATH" ]] || pos_die 'noncanonical wrapper path' || return
    pos_secure_regular_file "$script_path" 600 0 0 ||
        pos_die 'wrapper ownership or mode invalid' || return
    pos_verify_helper "$POS_HELPER" 0 0 || pos_die 'installed helper identity invalid' || return
    pos_secure_directory "$POS_RECEIPT_ROOT" 700 0 0 ||
        pos_die 'receipt root ownership or mode invalid' || return

    POS_STARTED=true
    POS_STARTED_EPOCH=$(date +%s)
    POS_STARTED_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    POS_WRAPPER_SHA256=$(pos_sha256_file "$script_path")
    trap pos_on_exit EXIT
    trap 'pos_signal HUP 129' HUP
    trap 'pos_signal INT 130' INT
    trap 'pos_signal TERM 143' TERM

    if ! pos_acquire_fleet_locks 0 0; then
        POS_FAILURE_REASON='canonical_lock_busy'
        pos_publish_receipt SKIPPED_BUSY "$POS_FAILURE_REASON"
        POS_TERMINAL=true
        return 0
    fi
    POS_FAILURE_REASON='helper_snapshot_failed'
    pos_prepare_helper_snapshot || return 1
    POS_FAILURE_REASON='helper_cycle_incomplete'
    pos_run_cycle
    if [[ "$(jq -r 'length' <<<"$POS_FAILED")" -eq 0 ]]; then
        status=PASS
        POS_FAILURE_REASON='complete'
    else
        status=PARTIAL
        POS_FAILURE_REASON='one_or_more_helpers_failed'
    fi
    pos_publish_receipt "$status" "$POS_FAILURE_REASON"
    POS_TERMINAL=true
    [[ "$status" == PASS ]]
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    pos_main "$@"
fi
