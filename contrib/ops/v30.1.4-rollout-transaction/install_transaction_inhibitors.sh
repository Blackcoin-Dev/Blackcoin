#!/usr/bin/env bash

# Installs the permanent no-spend quarantine cycle and the durable Free Claim
# pause wrapper. Default `probe` is read-only; `install` is explicit and gated.

set -Eeuo pipefail
umask 077
export LC_ALL=C TZ=UTC

PACKAGE_ROOT=$(CDPATH='' cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || exit 1
readonly PACKAGE_ROOT
readonly ACTION=${1:-probe}
readonly CONFIRM_VALUE=v30.1.4-install-transaction-inhibitors
readonly STATE_DIR=/boot/config/plugins/blackcoin-quantum-nodes
readonly FREE_CLAIM_ROOT=/mnt/pulsar/Blackcoin_Blocks/operations/free-claim-pool
readonly ENDPOINT_LOCK=/run/blackcoin-endpoint-guard.lock
readonly CUTOVER_LOCK=/var/run/blackcoin-node-cutover.lock
readonly CYCLE_LOCK=/run/blackcoin-pow-quarantine-cycle.lock
readonly WALLET_LOCK=/var/run/blackcoin-wallet-runtime-guard.lock
readonly FREE_CLAIM_LOCK=/var/run/blackcoin-free-claim-pool.lock
readonly TRANSITION_LOCK=/var/run/blackcoin-free-claim-pause-transition.lock
readonly CYCLE_LIVE="$STATE_DIR/blackcoin_pow_quarantine_cycle.sh"
readonly CYCLE_DISABLED="$STATE_DIR/blackcoin_pow_quarantine_cycle.v30.1.3-fee-capable.disabled"
readonly CYCLE_OLD_SHA256=156acca0ed86fbeba008d9f87eb862aa2f93fc32f57ed2995d7dc05dcdb7312d
readonly CYCLE_SOURCE="$PACKAGE_ROOT/blackcoin_pow_quarantine_cycle_v30.1.4_nospend.sh"
readonly DAEMON_LIVE="$FREE_CLAIM_ROOT/pool_daemon.sh"
readonly DAEMON_ORIGINAL="$FREE_CLAIM_ROOT/pool_daemon.v30.1.4-original"
readonly DAEMON_ORIGINAL_SHA256=cacc958f9ae9530c896caa23a36faca2c89e209e55dcf71f8ed3134547a3e1c6
readonly WRAPPER_SOURCE="$PACKAGE_ROOT/free_claim_daemon_pause_wrapper.sh"
readonly PAUSE_MARKER="$FREE_CLAIM_ROOT/.v30.1.4-free-claim-paused"
readonly PAUSE_CONTENT='schema=1 state=paused authority=v30.1.4-fleet-transaction'
readonly BROADCAST_DONE_DIR="$FREE_CLAIM_ROOT/done"

die()
{
    printf '%s FATAL: %s\n' "$(date -u +%FT%TZ)" "$*" >&2
    exit 1
}

file_sha()
{
    sha256sum "$1" | awk '{print $1}'
}

protected_file()
{
    local path="$1" mode
    [[ -f "$path" && ! -L "$path" && "$(realpath -e -- "$path")" == "$path" &&
       "$(stat -c '%u' "$path")" == 0 ]] || return 1
    mode=$(stat -c '%a' "$path") || return 1
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 0022) == 0 ))
}

protected_directory()
{
    local path="$1" owner_uid mode
    [[ -d "$path" && ! -L "$path" && "$(realpath -e -- "$path")" == "$path" ]] || return 1
    owner_uid=$(stat -c '%u' "$path") || return 1
    mode=$(stat -c '%a' "$path") || return 1
    [[ "$owner_uid" == 0 && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 0022) == 0 ))
}

verify_package()
{
    protected_directory "$PACKAGE_ROOT" && protected_file "$PACKAGE_ROOT/SHA256SUMS" &&
        [[ "$(stat -c '%a' "$PACKAGE_ROOT/SHA256SUMS")" == 600 ]] &&
        [[ -z "$(find "$PACKAGE_ROOT" -type l -print -quit)" &&
           -z "$(find "$PACKAGE_ROOT" ! -type d ! -type f -print -quit)" ]] &&
        cmp -s \
            <(cd "$PACKAGE_ROOT" && find . -type f ! -path './SHA256SUMS' -print | sort) \
            <(awk 'NF == 2 && $1 ~ /^[0-9a-f]{64}$/ {
                name=$2; sub(/^\\*/, "", name); sub(/^[.]\//, "", name); print "./" name
            }' "$PACKAGE_ROOT/SHA256SUMS" | sort) &&
        (cd "$PACKAGE_ROOT" && sha256sum --strict -c SHA256SUMS >/dev/null)
}

valid_marker()
{
    protected_file "$PAUSE_MARKER" && [[ "$(stat -c '%a' "$PAUSE_MARKER")" == 600 ]] &&
        printf '%s\n' "$PAUSE_CONTENT" | cmp -s - "$PAUSE_MARKER"
}

source_assets_valid()
{
    protected_file "$CYCLE_SOURCE" && protected_file "$WRAPPER_SOURCE"
}

install_atomic()
{
    local source="$1" destination="$2" temporary
    temporary=$(mktemp "${destination}.install.XXXXXX") || return 1
    install -m 700 -o root -g root -- "$source" "$temporary" || return 1
    [[ "$(file_sha "$temporary")" == "$(file_sha "$source")" ]] || {
        rm -f -- "$temporary"
        return 1
    }
    sync -f "$temporary" || return 1
    mv -fT -- "$temporary" "$destination" || return 1
    sync -f "${destination%/*}" || return 1
}

create_marker_atomic()
{
    local temporary
    if [[ -e "$PAUSE_MARKER" || -L "$PAUSE_MARKER" ]]; then
        valid_marker
        return
    fi
    temporary=$(mktemp "$FREE_CLAIM_ROOT/.v30.1.4-free-claim-paused.install.XXXXXX") || return 1
    printf '%s\n' "$PAUSE_CONTENT" > "$temporary" || return 1
    chmod 600 "$temporary" || return 1
    chown root:root "$temporary" || return 1
    sync -f "$temporary" || return 1
    mv -T -- "$temporary" "$PAUSE_MARKER" || return 1
    sync -f "$FREE_CLAIM_ROOT" || return 1
}

classify_and_verify()
{
    local cycle_source_sha wrapper_source_sha
    cycle_source_sha=$(file_sha "$CYCLE_SOURCE") || return 1
    wrapper_source_sha=$(file_sha "$WRAPPER_SOURCE") || return 1

    if [[ -e "$CYCLE_DISABLED" || -L "$CYCLE_DISABLED" ]]; then
        protected_file "$CYCLE_DISABLED" &&
            [[ "$(file_sha "$CYCLE_DISABLED")" == "$CYCLE_OLD_SHA256" ]] || return 1
    fi
    if [[ -e "$CYCLE_LIVE" || -L "$CYCLE_LIVE" ]]; then
        protected_file "$CYCLE_LIVE" || return 1
        case "$(file_sha "$CYCLE_LIVE")" in
            "$CYCLE_OLD_SHA256"|"$cycle_source_sha") ;;
            *) return 1 ;;
        esac
    fi
    if [[ -e "$DAEMON_ORIGINAL" || -L "$DAEMON_ORIGINAL" ]]; then
        protected_file "$DAEMON_ORIGINAL" &&
            [[ "$(file_sha "$DAEMON_ORIGINAL")" == "$DAEMON_ORIGINAL_SHA256" ]] || return 1
    fi
    if [[ -e "$DAEMON_LIVE" || -L "$DAEMON_LIVE" ]]; then
        protected_file "$DAEMON_LIVE" || return 1
        case "$(file_sha "$DAEMON_LIVE")" in
            "$DAEMON_ORIGINAL_SHA256"|"$wrapper_source_sha") ;;
            *) return 1 ;;
        esac
    fi
}

completed_state()
{
    installed_bytes_valid && valid_marker
}

installed_bytes_valid()
{
    protected_file "$CYCLE_LIVE" && protected_file "$CYCLE_DISABLED" &&
        protected_file "$DAEMON_LIVE" && protected_file "$DAEMON_ORIGINAL" &&
        [[ "$(file_sha "$CYCLE_LIVE")" == "$(file_sha "$CYCLE_SOURCE")" &&
           "$(file_sha "$CYCLE_DISABLED")" == "$CYCLE_OLD_SHA256" &&
           "$(file_sha "$DAEMON_LIVE")" == "$(file_sha "$WRAPPER_SOURCE")" &&
           "$(file_sha "$DAEMON_ORIGINAL")" == "$DAEMON_ORIGINAL_SHA256" &&
           "$(stat -c '%a' "$CYCLE_LIVE")" == 600 &&
           "$(stat -c '%a' "$CYCLE_DISABLED")" == 600 &&
           "$(stat -c '%a' "$DAEMON_LIVE")" == 700 &&
           "$(stat -c '%a' "$DAEMON_ORIGINAL")" == 600 ]]
}

acquire_inhibitor_locks()
{
    [[ ! -L "$ENDPOINT_LOCK" && ! -L "$CUTOVER_LOCK" && ! -L "$CYCLE_LOCK" &&
       ! -L "$WALLET_LOCK" && ! -L "$TRANSITION_LOCK" && ! -L "$FREE_CLAIM_LOCK" ]] ||
        return 1
    case "${INHERITED_ENDPOINT_LOCK_FD:-}" in
        '')
            exec 12>"$ENDPOINT_LOCK"
            flock -w 1800 12 || return 1
            ;;
        20)
            # A root operator may hand the already-held endpoint lock from the
            # reserved maintenance shell to this transaction.  Duplicating the
            # inherited open-file description avoids an unlock/relock race with
            # a queued supervisor.  No arbitrary descriptor is accepted.
            [[ "$(readlink -f "/proc/$$/fd/20" 2>/dev/null || true)" == \
               "$ENDPOINT_LOCK" ]] || return 1
            exec 12>&20
            flock -n 12 || return 1
            ;;
        *) return 1 ;;
    esac
    exec 13>"$CUTOVER_LOCK"
    flock -w 1800 13 || return 1
    exec 9>"$CYCLE_LOCK"
    flock -w 1800 9 || return 1
    exec 14>"$WALLET_LOCK"
    flock -w 1800 14 || return 1
    exec 11>"$TRANSITION_LOCK"
    flock -w 1800 11 || return 1
    exec 10>"$FREE_CLAIM_LOCK"
    flock -w 1800 10
}

no_existing_broadcast_markers()
{
    local entry
    [[ -d "$BROADCAST_DONE_DIR" && ! -L "$BROADCAST_DONE_DIR" &&
       "$(realpath -e -- "$BROADCAST_DONE_DIR")" == "$BROADCAST_DONE_DIR" ]] || return 1
    entry=$(find "$BROADCAST_DONE_DIR" -mindepth 1 -maxdepth 1 \
        -name '*.broadcast' -print -quit) || return 1
    [[ -z "$entry" ]]
}

probe()
{
    verify_package || die 'package integrity verification failed'
    source_assets_valid || die 'package inhibitor assets are unsafe'
    classify_and_verify || die 'live inhibitor paths contain unexpected bytes'
    if completed_state; then
        printf '%s\n' 'state=installed-and-paused cycle=v30.1.4-no-spend free_claim=paused'
    else
        printf '%s\n' 'state=not-installed-or-partial'
        return 1
    fi
}

apply_install()
{
    [[ "${CONFIRM_INSTALL_TRANSACTION_INHIBITORS:-}" == "$CONFIRM_VALUE" ]] ||
        die "install requires CONFIRM_INSTALL_TRANSACTION_INHIBITORS=$CONFIRM_VALUE"
    verify_package || die 'package integrity verification failed'
    source_assets_valid || die 'package inhibitor assets are unsafe'
    [[ "$(id -u)" -eq 0 ]] || die 'root is required'
    [[ -d "$STATE_DIR" && ! -L "$STATE_DIR" &&
       -d "$FREE_CLAIM_ROOT" && ! -L "$FREE_CLAIM_ROOT" ]] ||
        die 'live inhibitor paths are unsafe'
    if ! protected_directory "$STATE_DIR" || ! protected_directory "$FREE_CLAIM_ROOT"; then
        die 'live inhibitor directories are not root protected'
    fi

    acquire_inhibitor_locks || die 'inhibitor/guard activity did not drain in canonical order'
    classify_and_verify || die 'live inhibitor paths contain unexpected bytes'
    no_existing_broadcast_markers ||
        die 'Free Claim has an existing .broadcast entry; drain it before pausing the worker'
    if completed_state; then
        printf '%s\n' 'state=installed-and-paused cycle=v30.1.4-no-spend free_claim=paused'
        return 0
    fi

    create_marker_atomic || die 'could not create the durable Free Claim pause marker'

    # Disable the dequeue/broadcast entrypoint first. A SIGKILL after its
    # rename leaves that entrypoint absent; once the wrapper is present, the
    # already-durable marker keeps it paused.
    if [[ -e "$DAEMON_LIVE" || -L "$DAEMON_LIVE" ]]; then
        if [[ "$(file_sha "$DAEMON_LIVE")" == "$DAEMON_ORIGINAL_SHA256" ]]; then
            [[ ! -e "$DAEMON_ORIGINAL" && ! -L "$DAEMON_ORIGINAL" ]] ||
                die 'Free Claim daemon transition is ambiguous'
            mv -T -- "$DAEMON_LIVE" "$DAEMON_ORIGINAL"
            sync -f "$FREE_CLAIM_ROOT"
        elif [[ "$(file_sha "$DAEMON_LIVE")" != "$(file_sha "$WRAPPER_SOURCE")" ]]; then
            die 'live Free Claim daemon is neither original nor installed wrapper bytes'
        fi
    fi
    [[ -f "$DAEMON_ORIGINAL" && ! -L "$DAEMON_ORIGINAL" &&
       "$(file_sha "$DAEMON_ORIGINAL")" == "$DAEMON_ORIGINAL_SHA256" ]] ||
        die 'pinned original Free Claim daemon is invalid'
    chmod 600 "$DAEMON_ORIGINAL"
    chown root:root "$DAEMON_ORIGINAL"
    sync -f "$DAEMON_ORIGINAL"
    if [[ ! -e "$DAEMON_LIVE" && ! -L "$DAEMON_LIVE" ]]; then
        install_atomic "$WRAPPER_SOURCE" "$DAEMON_LIVE" || die 'Free Claim wrapper installation failed'
    fi

    if [[ -e "$CYCLE_LIVE" || -L "$CYCLE_LIVE" ]]; then
        if [[ "$(file_sha "$CYCLE_LIVE")" == "$CYCLE_OLD_SHA256" ]]; then
            [[ ! -e "$CYCLE_DISABLED" && ! -L "$CYCLE_DISABLED" ]] ||
                die 'quarantine-cycle transition is ambiguous'
            mv -T -- "$CYCLE_LIVE" "$CYCLE_DISABLED"
            sync -f "$STATE_DIR"
        elif [[ "$(file_sha "$CYCLE_LIVE")" != "$(file_sha "$CYCLE_SOURCE")" ]]; then
            die 'live quarantine cycle is neither old nor installed no-spend bytes'
        fi
    fi
    [[ -f "$CYCLE_DISABLED" && ! -L "$CYCLE_DISABLED" &&
       "$(file_sha "$CYCLE_DISABLED")" == "$CYCLE_OLD_SHA256" ]] ||
        die 'disabled quarantine-cycle backup is invalid'
    chmod 600 "$CYCLE_DISABLED"
    chown root:root "$CYCLE_DISABLED"
    sync -f "$CYCLE_DISABLED"
    if [[ ! -e "$CYCLE_LIVE" && ! -L "$CYCLE_LIVE" ]]; then
        install_atomic "$CYCLE_SOURCE" "$CYCLE_LIVE" || die 'no-spend cycle installation failed'
    fi

    completed_state || die 'installed inhibitor state did not verify'
    sync -f "$STATE_DIR"
    sync -f "$FREE_CLAIM_ROOT"
    printf '%s\n' 'state=installed-and-paused cycle=v30.1.4-no-spend free_claim=paused'
}

emergency_contain()
{
    local broadcast_count
    [[ "${CONFIRM_EMERGENCY_CONTAIN:-}" == v30.1.4-emergency-repause ]] ||
        die 'emergency-contain requires CONFIRM_EMERGENCY_CONTAIN=v30.1.4-emergency-repause'
    verify_package || die 'package integrity verification failed'
    source_assets_valid || die 'package inhibitor assets are unsafe'
    [[ "$(id -u)" -eq 0 ]] || die 'root is required'
    if ! protected_directory "$STATE_DIR" || ! protected_directory "$FREE_CLAIM_ROOT"; then
        die 'live inhibitor directories are not root protected'
    fi
    acquire_inhibitor_locks || die 'inhibitor/guard activity did not drain in canonical order'
    installed_bytes_valid || die 'emergency containment requires the exact installed no-spend/wrapper bytes'
    broadcast_count=$(find "$BROADCAST_DONE_DIR" -mindepth 1 -maxdepth 1 \
        -name '*.broadcast' -print | wc -l) || die 'could not inventory existing broadcast entries'
    create_marker_atomic || die 'could not atomically restore the Free Claim pause marker'
    completed_state || die 'emergency Free Claim containment did not verify'
    printf 'state=installed-and-paused cycle=v30.1.4-no-spend free_claim=paused preexisting_broadcast_entries=%s\n' \
        "$broadcast_count"
}

for command in awk chmod chown cmp date find flock install jq mktemp mv readlink realpath rm sha256sum sort stat sync wc; do
    command -v "$command" >/dev/null 2>&1 || die "required command unavailable: $command"
done

case "$ACTION" in
    probe) probe ;;
    install) apply_install ;;
    emergency-contain) emergency_contain ;;
    *) printf 'usage: %s [probe|install|emergency-contain]\n' "$0" >&2; exit 64 ;;
esac
