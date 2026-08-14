#!/bin/bash
set -Eeuo pipefail
export LC_ALL=C TZ=UTC
umask 077

readonly NORMAL_UNLOCK_STATE=/boot/config/plugins/blackcoin-quantum-nodes
readonly NORMAL_UNLOCK_SECRET=/mnt/disk1/blackcoin-wallet-safety/runtime-secrets/blackcoin-wallet.passphrase
readonly NORMAL_UNLOCK_RPC=/usr/local/bin/blackcoin-cli
readonly NORMAL_UNLOCK_DATADIR=/home/blackcoin/.blackcoin

normal_unlock_valid_node()
{
    [[ "${1:-}" =~ ^([1-9]|[12][0-9]|3[0-2])$ ]]
}

normal_unlock_container_for_node()
{
    local node=$1
    normal_unlock_valid_node "$node" || return 1
    if [[ "$node" -eq 1 ]]; then
        printf '%s\n' blackcoin-v4-gui
    else
        printf 'blackcoin-v4-gui-%s\n' "$node"
    fi
}

normal_unlock_docker()
{
    local timeout_seconds=$1
    shift
    timeout -k 2 "$timeout_seconds" docker "$@"
}

# The unnamed wallet is represented by an empty string in listwallets. Passing
# -rpcwallet= for that wallet does not select the same RPC endpoint, so the
# selector must be absent. A named wallet remains one exact argv element.
normal_unlock_wallet_rpc()
{
    local timeout_seconds=$1 container=$2 wallet=$3
    shift 3
    local -a rpc_args=("$NORMAL_UNLOCK_RPC" "-datadir=$NORMAL_UNLOCK_DATADIR")
    [[ -z "$wallet" ]] || rpc_args+=("-rpcwallet=$wallet")
    normal_unlock_docker "$timeout_seconds" exec "$container" "${rpc_args[@]}" "$@"
}

normal_unlock_wallet_rpc_stdin()
{
    local timeout_seconds=$1 container=$2 wallet=$3
    shift 3
    local -a rpc_args=("$NORMAL_UNLOCK_RPC" "-datadir=$NORMAL_UNLOCK_DATADIR")
    [[ -z "$wallet" ]] || rpc_args+=("-rpcwallet=$wallet")
    normal_unlock_docker "$timeout_seconds" exec -i "$container" "${rpc_args[@]}" "$@"
}

normal_unlock_die()
{
    printf '%s FATAL: %s\n' "$(date -u +%FT%TZ)" "$*" >&2
    return 1
}

normal_unlock_main()
{
    [[ "$#" -eq 1 ]] || return 64
    local node=$1 padded container manifest secret_mode wallet loaded expected deadline wi si
    local node_fd
    normal_unlock_valid_node "$node" || return 64
    printf -v padded '%02d' "$node"
    manifest="$NORMAL_UNLOCK_STATE/runtime-wallet-manifests/node-$padded.json"
    container=$(normal_unlock_container_for_node "$node") || return 64

    [[ "$(id -u)" -eq 0 ]] || normal_unlock_die 'root required' || return
    exec {node_fd}>"/run/blackcoin-node-$padded-runtime.lock"
    flock -n "$node_fd" || normal_unlock_die "node $node runtime lock is busy" || return
    for file in "$manifest" "$NORMAL_UNLOCK_SECRET"; do
        [[ -f "$file" && ! -L "$file" ]] ||
            normal_unlock_die "protected input invalid: $(basename "$file")" || return
    done
    [[ "$(stat -c '%u:%g:%a' "$manifest")" == 0:0:600 ]] ||
        normal_unlock_die 'wallet manifest permissions invalid' || return
    secret_mode=$(stat -c '%u:%g:%a' "$NORMAL_UNLOCK_SECRET")
    [[ "$secret_mode" == 0:0:400 || "$secret_mode" == 0:0:600 ]] ||
        normal_unlock_die 'wallet secret permissions invalid' || return
    [[ "$(wc -l < "$NORMAL_UNLOCK_SECRET")" -eq 1 &&
       "$(stat -c '%s' "$NORMAL_UNLOCK_SECRET")" -le 1024 ]] ||
        normal_unlock_die 'wallet secret shape invalid' || return

    wallet=$(jq -r 'if type == "array" and length == 1 then .[0] else error("invalid") end' \
        "$manifest") || normal_unlock_die 'wallet manifest is invalid' || return
    loaded=$(normal_unlock_wallet_rpc 30 "$container" '' listwallets | jq -c 'sort') ||
        normal_unlock_die 'loaded wallet inventory is unavailable' || return
    expected=$(jq -c 'sort' "$manifest") ||
        normal_unlock_die 'wallet manifest cannot be normalized' || return
    [[ "$loaded" == "$expected" ]] || normal_unlock_die 'loaded wallet inventory changed' || return

    normal_unlock_wallet_rpc_stdin 65 "$container" "$wallet" \
        -stdinwalletpassphrase walletpassphrase 86400 false \
        < "$NORMAL_UNLOCK_SECRET" >/dev/null || normal_unlock_die 'normal wallet unlock failed' || return
    normal_unlock_wallet_rpc 30 "$container" "$wallet" staking true >/dev/null ||
        normal_unlock_die 'PoS enable failed' || return

    deadline=$((SECONDS + 180))
    while ((SECONDS < deadline)); do
        wi=$(normal_unlock_wallet_rpc 30 "$container" "$wallet" getwalletinfo 2>/dev/null ||
            printf '{}')
        si=$(normal_unlock_wallet_rpc 30 "$container" "$wallet" getstakinginfo 2>/dev/null ||
            printf '{}')
        if jq -e '.unlocked_staking_only == false and
            (.unlocked_until // 0) > (now + 43200)' <<< "$wi" >/dev/null 2>&1 &&
           jq -e '.enabled == true and .staking == true and
            (.weight // 0) > 0' <<< "$si" >/dev/null 2>&1; then
            printf '%s complete node=%s wallet=normally_unlocked pos=active\n' \
                "$(date -u +%FT%TZ)" "$padded"
            return 0
        fi
        sleep 5
    done
    normal_unlock_die 'normal unlock and active PoS were not confirmed'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    normal_unlock_main "$@"
fi
