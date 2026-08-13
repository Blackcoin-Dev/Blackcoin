#!/usr/bin/env bash

# Durable pause interlock for the node-30 Free Claim worker. The wrapper emits
# no payout and performs no queue operation. The original daemon remains pinned
# by hash and is entered only after the shared worker lock has been released.

set -Eeuo pipefail
umask 077
export LC_ALL=C TZ=UTC

readonly FREE_CLAIM_ROOT=/mnt/pulsar/Blackcoin_Blocks/operations/free-claim-pool
readonly FREE_CLAIM_LOCK=/var/run/blackcoin-free-claim-pool.lock
readonly TRANSITION_LOCK=/var/run/blackcoin-free-claim-pause-transition.lock
readonly PAUSE_MARKER="$FREE_CLAIM_ROOT/.v30.1.4-free-claim-paused"
readonly PAUSE_CONTENT='schema=1 state=paused authority=v30.1.4-fleet-transaction'
readonly ORIGINAL_DAEMON="$FREE_CLAIM_ROOT/pool_daemon.v30.1.4-original"
readonly ORIGINAL_DAEMON_SHA256=cacc958f9ae9530c896caa23a36faca2c89e209e55dcf71f8ed3134547a3e1c6

die()
{
    printf '%s FATAL: %s\n' "$(date -u +%FT%TZ)" "$*" >&2
    exit 1
}

valid_pause_marker()
{
    [[ -f "$PAUSE_MARKER" && ! -L "$PAUSE_MARKER" &&
       "$(realpath -e -- "$PAUSE_MARKER")" == "$PAUSE_MARKER" &&
       "$(stat -c '%u:%g:%a' "$PAUSE_MARKER")" == 0:0:600 ]] || return 1
    printf '%s\n' "$PAUSE_CONTENT" | cmp -s - "$PAUSE_MARKER"
}

valid_original_daemon()
{
    local actual
    [[ -f "$ORIGINAL_DAEMON" && ! -L "$ORIGINAL_DAEMON" &&
       "$(realpath -e -- "$ORIGINAL_DAEMON")" == "$ORIGINAL_DAEMON" &&
       "$(stat -c '%u:%g' "$ORIGINAL_DAEMON")" == 0:0 ]] || return 1
    actual=$(sha256sum "$ORIGINAL_DAEMON" | awk '{print $1}') || return 1
    [[ "$actual" == "$ORIGINAL_DAEMON_SHA256" ]]
}

valid_root_directory()
{
    local owner mode
    [[ -d "$FREE_CLAIM_ROOT" && ! -L "$FREE_CLAIM_ROOT" &&
       "$(realpath -e -- "$FREE_CLAIM_ROOT")" == "$FREE_CLAIM_ROOT" ]] || return 1
    owner=$(stat -c '%u:%g' "$FREE_CLAIM_ROOT") || return 1
    mode=$(stat -c '%a' "$FREE_CLAIM_ROOT") || return 1
    [[ "$owner" == 0:0 && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 0022) == 0 ))
}

main()
{
    for command in awk cmp date flock realpath sha256sum stat; do
        command -v "$command" >/dev/null 2>&1 || die "required command unavailable: $command"
    done
    [[ "$(id -u)" -eq 0 ]] || die 'root is required'
    if ! valid_root_directory || [[ -L "$FREE_CLAIM_LOCK" || -L "$TRANSITION_LOCK" ]]; then
        die 'Free Claim path is unsafe'
    fi
    # This outer lock intentionally survives exec. Install/release operations
    # drain it before changing the pause marker, closing the dispatch-to-lock
    # race in the original worker.
    exec 8>"$TRANSITION_LOCK"
    flock -w 300 8 || die 'Free Claim pause transition did not drain'
    exec 9>"$FREE_CLAIM_LOCK"
    flock -w 300 9 || die 'Free Claim worker lock did not drain'
    if [[ -e "$PAUSE_MARKER" || -L "$PAUSE_MARKER" ]]; then
        valid_pause_marker || die 'Free Claim pause marker is malformed; refusing daemon execution'
        flock -u 9
        exec 9>&-
        flock -u 8
        exec 8>&-
        exit 0
    fi
    valid_original_daemon || die 'pinned original Free Claim daemon is unavailable'

    # The original daemon opens and owns the worker lock. The separate outer
    # transition lock remains inherited for its complete lifetime.
    flock -u 9
    exec 9>&-
    exec /bin/bash "$ORIGINAL_DAEMON" "$@"
}

main "$@"
