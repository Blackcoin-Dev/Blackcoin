#!/usr/bin/env bash
export LC_ALL=C

# Cron-safe fleet liveness cycle for the v30.1.4 transition. This program has
# no transaction-construction or transaction-broadcast path. Its only mutation
# helpers are the exact, pinned normal-unlock and start-only PoW helpers.

set -Eeuo pipefail
umask 077
export TZ=UTC

readonly STATE_DIR=/boot/config/plugins/blackcoin-quantum-nodes
readonly CYCLE_LOCK=/run/blackcoin-pow-quarantine-cycle.lock
readonly MAINTENANCE_MARKER="$STATE_DIR/V30_1_4_ROLLOUT_MAINTENANCE.json"
readonly NORMAL_UNLOCK_HELPER="$STATE_DIR/blackcoin_node_normal_unlock.sh"
readonly POW_START_HELPER="$STATE_DIR/blackcoin_pow_start_only.sh"
readonly NORMAL_UNLOCK_SHA256=acf28446e842fd0fa92b06c2ebc182e9da38fcde7bac06dd920d50a33e4e3dd1
readonly POW_START_SHA256=21808f232ca3961e180a4c2dd3853e4aef93c2dfdf4821b5d63ca5106c5676ea
readonly STATUS_FILE="$STATE_DIR/blackcoin-pow-quarantine-cycle-status.json"
readonly CLI=/usr/local/bin/blackcoin-cli
readonly DATADIR=/home/blackcoin/.blackcoin
readonly NODE_COUNT=32
readonly FREE_CLAIM_NODE=30

WORK_DIR=
NORMAL_UNLOCK_SNAPSHOT=
POW_START_SNAPSHOT=

log()
{
    printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >&2
}

die()
{
    log "FATAL: $*"
    exit 1
}

cleanup()
{
    [[ -z "$WORK_DIR" || ! -d "$WORK_DIR" || -L "$WORK_DIR" ]] || rm -rf -- "$WORK_DIR"
}

container_for()
{
    if [[ "$1" -eq 1 ]]; then
        printf '%s\n' blackcoin-v4-gui
    else
        printf 'blackcoin-v4-gui-%d\n' "$1"
    fi
}

manifest_for()
{
    printf '%s/pow-wallet-manifests/node-%02d.json\n' "$STATE_DIR" "$1"
}

rpc_for()
{
    local node="$1"
    shift
    timeout --foreground --kill-after=2 30 docker exec "$(container_for "$node")" \
        "$CLI" -datadir="$DATADIR" "$@"
}

wallet_rpc_for()
{
    local node="$1" wallets wallet
    shift
    wallets=$(rpc_for "$node" listwallets 2>/dev/null) || return 1
    wallet=$(jq -er 'select(type == "array" and length == 1) |
        .[0] | select(type == "string" and length <= 128)' \
        <<< "$wallets") || return 1
    timeout --foreground --kill-after=2 30 docker exec "$(container_for "$node")" \
        "$CLI" -datadir="$DATADIR" -rpcwallet="$wallet" "$@"
}

protected_regular_file()
{
    local path="$1" mode_pattern="$2" owner mode
    [[ -f "$path" && ! -L "$path" && "$(realpath -e -- "$path")" == "$path" ]] || return 1
    owner=$(stat -c '%u:%g' "$path") || return 1
    mode=$(stat -c '%a' "$path") || return 1
    [[ "$owner" == 0:0 && "$mode" =~ $mode_pattern ]]
}

protected_directory()
{
    local path="$1" owner mode
    [[ -d "$path" && ! -L "$path" && "$(realpath -e -- "$path")" == "$path" ]] || return 1
    owner=$(stat -c '%u:%g' "$path") || return 1
    mode=$(stat -c '%a' "$path") || return 1
    [[ "$owner" == 0:0 && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 0022) == 0 ))
}

snapshot_helper()
{
    local source="$1" destination="$2" expected="$3" source_sha copied_sha
    protected_regular_file "$source" '^(500|600|700)$' || return 1
    source_sha=$(sha256sum "$source" | awk '{print $1}') || return 1
    [[ "$source_sha" == "$expected" ]] || return 1
    install -m 500 -o root -g root -- "$source" "$destination" || return 1
    copied_sha=$(sha256sum "$destination" | awk '{print $1}') || return 1
    [[ "$copied_sha" == "$expected" ]]
}

maintenance_state()
{
    if [[ ! -e "$MAINTENANCE_MARKER" && ! -L "$MAINTENANCE_MARKER" ]]; then
        return 1
    fi
    protected_regular_file "$MAINTENANCE_MARKER" '^600$' &&
        jq -e '
            .schema == 1 and .transaction == "v30.1.4-fleet-rollout" and
            .state == "active" and
            (.run_nonce | type == "string" and test("^[0-9a-f]{64}$")) and
            (.run_dir | type == "string" and startswith("/mnt/pulsar/Blackcoin_Blocks/operations/v30.1.4-fleet-rollout/rollout-"))
        ' "$MAINTENANCE_MARKER" >/dev/null 2>&1
}

manifest_allows_role()
{
    local node="$1" manifest expected
    manifest=$(manifest_for "$node")
    protected_regular_file "$manifest" '^600$' || return 1
    if [[ "$node" -eq "$FREE_CLAIM_NODE" ]]; then expected=false; else expected=true; fi
    jq -e --arg node "$(printf '%02d' "$node")" --argjson enabled "$expected" '
        .schema == 1 and .node_id == $node and .enabled == $enabled
    ' "$manifest" >/dev/null
}

legacy_claim_state_clean()
{
    jq -e '
        (.live_claims | type) == "number" and .live_claims >= 0 and .live_claims <= 64 and
        (.unresolved_claims | type) == "number" and .unresolved_claims >= .live_claims and
        (.quarantined_claims | type) == "number" and .quarantined_claims == 0
    ' >/dev/null <<< "$1"
}

current_claim_state_clean()
{
    local mining="$1" recovery="$2"
    jq -e '
        (.live_claims | type) == "number" and .live_claims >= 0 and .live_claims <= 64 and
        (.blocking_quarantined_claims | type) == "number" and .blocking_quarantined_claims == 0 and
        (.quarantined_claims | type) == "number" and .quarantined_claims == 0 and
        .claim_recovery_database_outcome_ambiguous == false
    ' >/dev/null <<< "$mining" &&
        jq -e '
            .policy_authoritative == true and .policy.automatic_authorized == false and
            .database_outcome_ambiguous == false and .chain_ready == true and
            .wallet_tip_matches == true and .blocking_quarantined_claims == 0 and
            .blocking_components == 0 and .indeterminate_quarantined_claims == 0 and
            .pending_manual_resolutions == 0 and .pending_automatic_resolutions == 0
        ' >/dev/null <<< "$recovery"
}

node_claim_state_clean()
{
    local node="$1" version="$2" mining="$3" recovery
    case "$version" in
        300103)
            legacy_claim_state_clean "$mining"
            ;;
        300104)
            recovery=$(wallet_rpc_for "$node" getpowclaimrecoveryinfo 2>/dev/null) || return 1
            current_claim_state_clean "$mining" "$recovery"
            ;;
        *)
            return 1
            ;;
    esac
}

staking_preunlock_safe()
{
    local wallet_info="$1" staking="$2"
    jq -e '.private_keys_enabled == true and .scanning == false and
        (.unlocked_until | type) == "number" and
        (.unlocked_staking_only | type) == "boolean"' \
        >/dev/null <<< "$wallet_info" &&
        jq -e '.automatic_qqsignal == false and
            .automatic_demurrage_attestation == false and
            .automatic_redelegation == false and
            .allow_automatic_quantum_key_creation == false' \
        >/dev/null <<< "$staking"
}

donation_defaults_off()
{
    local node="$1" version="$2" legacy qq
    legacy=$(wallet_rpc_for "$node" getstakingdonationinfo 2>/dev/null) || return 1
    case "$version" in
        300103)
            jq -e '.enabled == false and .percentage == 0' \
                >/dev/null <<< "$legacy"
            ;;
        300104)
            qq=$(wallet_rpc_for "$node" getqqdevelopmentdonationinfo 2>/dev/null) || return 1
            jq -e '.retired == true and .enabled == false and .percentage == 0 and
                .target_address == ""' >/dev/null <<< "$legacy" &&
                jq -e '.enabled == false and .percentage == 0 and
                    .database_outcome_ambiguous == false' >/dev/null <<< "$qq"
            ;;
        *)
            return 1
            ;;
    esac
}

staking_ready()
{
    local version="$1" wallet_info="$2" staking="$3"
    staking_preunlock_safe "$wallet_info" "$staking" || return 1
    jq -e '.unlocked_until > now and .unlocked_staking_only == false' \
        >/dev/null <<< "$wallet_info" || return 1
    case "$version" in
        300103)
            # v30.1.3 can transiently report staking=false while the enabled
            # worker rotates its search interval at a new tip.  The stable
            # readiness contract is enabled + positive, current weight + an
            # active search interval; do not re-run the unlock helper merely
            # because the timing-sensitive legacy field is false.
            jq -e '.enabled == true and ."search-interval" > 0 and
                .weight > 0 and .weight_cached == true' >/dev/null <<< "$staking"
            ;;
        300104)
            jq -e '.enabled == true and .staking == true and
                .worker_running == true and .eligible == true and
                .staking_snapshot_current == true and .staking_state == "searching" and
                .weight > 0 and .weight_cached == true' >/dev/null <<< "$staking"
            ;;
        *)
            return 1
            ;;
    esac
}

pow_prestart_safe()
{
    jq -e '.allow_automatic_quantum_key_creation == false' >/dev/null <<< "$1"
}

regular_pow_ready()
{
    jq -e '.enabled == true and .threads == 1 and .cpu_percent == 1 and
        .hashrate > 0 and (.live_claims | type) == "number" and
        .live_claims >= 0 and .live_claims <= 64 and
        .allow_automatic_quantum_key_creation == false' >/dev/null <<< "$1"
}

free_claim_pow_ready()
{
    jq -e '.enabled == false and .hashrate == 0 and .live_claims == 0 and
        .allow_automatic_quantum_key_creation == false' >/dev/null <<< "$1"
}

write_node_status()
{
    local node="$1" version="$2" result="$3" staking_action="$4" pow_action="$5"
    jq -n --argjson node "$node" --argjson version "$version" --arg result "$result" \
        --arg staking_action "$staking_action" --arg pow_action "$pow_action" \
        '{node:$node,version:$version,result:$result,
          staking_action:$staking_action,pow_action:$pow_action}'
}

process_node()
{
    local node="$1" container network version mining wallet_info staking
    local staking_action=none pow_action=none
    container=$(container_for "$node")
    if ! docker inspect "$container" | jq -e 'length == 1 and .[0].State.Running == true and
        .[0].State.Health.Status == "healthy"' >/dev/null 2>&1; then
        write_node_status "$node" 0 unavailable none none
        return 1
    fi
    manifest_allows_role "$node" || {
        write_node_status "$node" 0 manifest-refused none none
        return 1
    }
    network=$(rpc_for "$node" getnetworkinfo 2>/dev/null) || {
        write_node_status "$node" 0 rpc-unavailable none none
        return 1
    }
    version=$(jq -er '.version | select(. == 300103 or . == 300104)' <<< "$network") || {
        write_node_status "$node" 0 unsupported-version none none
        return 1
    }
    mining=$(wallet_rpc_for "$node" getpowmininginfo 2>/dev/null) || {
        write_node_status "$node" "$version" mining-state-unavailable none none
        return 1
    }
    if ! node_claim_state_clean "$node" "$version" "$mining"; then
        write_node_status "$node" "$version" claim-state-not-clean none none
        return 1
    fi
    wallet_info=$(wallet_rpc_for "$node" getwalletinfo 2>/dev/null || true)
    staking=$(wallet_rpc_for "$node" getstakinginfo 2>/dev/null || true)
    if ! staking_preunlock_safe "$wallet_info" "$staking" ||
       ! donation_defaults_off "$node" "$version" ||
       ! pow_prestart_safe "$mining"; then
        write_node_status "$node" "$version" pre-helper-safety-refused none none
        return 1
    fi
    if ! staking_ready "$version" "$wallet_info" "$staking"; then
        if /bin/bash "$NORMAL_UNLOCK_SNAPSHOT" "$node" >/dev/null 2>&1; then
            staking_action=restored
        else
            write_node_status "$node" "$version" staking-helper-failed failed none
            return 1
        fi
    fi
    if [[ "$node" -ne "$FREE_CLAIM_NODE" ]] && ! regular_pow_ready "$mining"; then
        if /bin/bash "$POW_START_SNAPSHOT" "$node" >/dev/null 2>&1; then
            pow_action=restored
        else
            write_node_status "$node" "$version" pow-helper-failed "$staking_action" failed
            return 1
        fi
    fi
    for _ in $(seq 1 12); do
        wallet_info=$(wallet_rpc_for "$node" getwalletinfo 2>/dev/null || true)
        staking=$(wallet_rpc_for "$node" getstakinginfo 2>/dev/null || true)
        mining=$(wallet_rpc_for "$node" getpowmininginfo 2>/dev/null || true)
        if staking_ready "$version" "$wallet_info" "$staking" &&
           donation_defaults_off "$node" "$version" &&
           { { [[ "$node" -eq "$FREE_CLAIM_NODE" ]] && free_claim_pow_ready "$mining"; } ||
             { [[ "$node" -ne "$FREE_CLAIM_NODE" ]] && regular_pow_ready "$mining"; }; } &&
           node_claim_state_clean "$node" "$version" "$mining"; then
            write_node_status "$node" "$version" healthy "$staking_action" "$pow_action"
            return 0
        fi
        sleep 1
    done
    write_node_status "$node" "$version" post-helper-gate-failed "$staking_action" "$pow_action"
    return 1
}

publish_status()
{
    local result="$1" temporary nodes_json total healthy failed
    if [[ -e "$STATUS_FILE" || -L "$STATUS_FILE" ]]; then
        [[ -f "$STATUS_FILE" && ! -L "$STATUS_FILE" ]] || die 'status path is unsafe'
    fi
    nodes_json=$(jq -s 'sort_by(.node)' "$WORK_DIR"/node-*.json 2>/dev/null || printf '[]')
    total=$(jq -er 'length' <<< "$nodes_json") || return 1
    healthy=$(jq -er '[.[] | select(.result == "healthy")] | length' <<< "$nodes_json") || return 1
    failed=$((total - healthy))
    temporary=$(mktemp "$STATE_DIR/.blackcoin-pow-quarantine-cycle-status.XXXXXX")
    jq -n --arg generated_at "$(date -u +%FT%TZ)" --arg result "$result" \
        --argjson nodes "$nodes_json" --argjson total "$total" \
        --argjson healthy "$healthy" --argjson failed "$failed" \
        '{schema:1,mode:"v30.1.4-no-spend",generated_at:$generated_at,
          result:$result,total_nodes:$total,healthy_nodes:$healthy,failed_nodes:$failed,
          nodes:$nodes}' > "$temporary"
    chmod 600 "$temporary"
    chown root:root "$temporary"
    sync -f "$temporary"
    mv -fT -- "$temporary" "$STATUS_FILE"
    sync -f "$STATE_DIR"
}

main()
{
    local node pid failed=0
    local -a pids=()
    for command in awk chmod chown date docker find flock install jq mktemp mv realpath rm seq sha256sum sleep stat sync timeout wc; do
        command -v "$command" >/dev/null 2>&1 || die "required command unavailable: $command"
    done
    [[ "$(id -u)" -eq 0 ]] || die 'root is required'
    protected_directory "$STATE_DIR" || die 'state directory is unsafe'
    [[ ! -L "$CYCLE_LOCK" ]] || die 'cycle lock path is a symlink'
    exec 9>"$CYCLE_LOCK"
    flock -n 9 || exit 0
    WORK_DIR=$(mktemp -d "$STATE_DIR/.blackcoin-pow-quarantine-nospend.XXXXXX")
    chmod 700 "$WORK_DIR"
    chown root:root "$WORK_DIR"
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if maintenance_state; then
        publish_status maintenance-inhibited
        return 0
    elif [[ -e "$MAINTENANCE_MARKER" || -L "$MAINTENANCE_MARKER" ]]; then
        publish_status invalid-maintenance-marker-inhibited
        return 1
    fi
    NORMAL_UNLOCK_SNAPSHOT="$WORK_DIR/blackcoin_node_normal_unlock.sh"
    POW_START_SNAPSHOT="$WORK_DIR/blackcoin_pow_start_only.sh"
    snapshot_helper "$NORMAL_UNLOCK_HELPER" "$NORMAL_UNLOCK_SNAPSHOT" "$NORMAL_UNLOCK_SHA256" ||
        die 'normal-unlock helper identity is invalid'
    snapshot_helper "$POW_START_HELPER" "$POW_START_SNAPSHOT" "$POW_START_SHA256" ||
        die 'PoW start-only helper identity is invalid'
    for node in $(seq 1 "$NODE_COUNT"); do
        (process_node "$node" > "$WORK_DIR/node-$(printf '%02d' "$node").json") &
        pids+=("$!")
    done
    for pid in "${pids[@]}"; do
        wait "$pid" || failed=1
    done
    if [[ "$failed" -eq 0 ]] &&
       [[ "$(find "$WORK_DIR" -maxdepth 1 -type f -name 'node-*.json' | wc -l)" -eq "$NODE_COUNT" ]] &&
       jq -e -s --argjson count "$NODE_COUNT" \
           'length == $count and all(.[]; .result == "healthy")' "$WORK_DIR"/node-*.json >/dev/null; then
        publish_status completed
        return 0
    fi
    publish_status degraded
    return 1
}

main "$@"
