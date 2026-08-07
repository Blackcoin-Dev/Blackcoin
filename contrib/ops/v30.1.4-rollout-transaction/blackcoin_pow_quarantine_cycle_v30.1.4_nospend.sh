#!/usr/bin/env bash
export LC_ALL=C

# Cron-safe fleet liveness cycle for the v30.1.4 transition. This program has
# no transaction-construction or transaction-broadcast path. Its only mutation
# helpers are the exact, pinned normal-unlock and start-only PoW helpers.

set -Eeuo pipefail
umask 077
export TZ=UTC

readonly STATE_DIR=/boot/config/plugins/blackcoin-quantum-nodes
readonly IMAGE_POLICY="$STATE_DIR/fleet-image-policy.json"
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
readonly SOURCE_LABEL_KEY=org.blackcoin.source.commit
readonly IMMUTABLE_V3014_SOURCE_COMMIT=13262151077cce3f72d07d17dc7725b2b6a8e1ab

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

immutable_v3014_claim_state_clean()
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

pow_contract_identity_for()
{
    local node="$1" padded container inspect actual_id source expected_id
    [[ "$node" =~ ^([1-9]|[12][0-9]|3[0-2])$ ]] || return 1
    padded=$(printf '%02d' "$node") || return 1
    container=$(container_for "$node") || return 1
    protected_regular_file "$IMAGE_POLICY" '^600$' || return 1
    inspect=$(docker inspect "$container") || return 1
    actual_id=$(jq -er '
        select(type == "array" and length == 1) |
        .[0].Image | select(type == "string" and
          test("^sha256:[0-9a-f]{64}$"))
    ' <<< "$inspect") || return 1
    source=$(jq -er --arg key "$SOURCE_LABEL_KEY" '
        select(type == "array" and length == 1) |
        .[0].Config.Labels[$key] |
        select(type == "string" and test("^[0-9a-f]{40}$"))
    ' <<< "$inspect") || return 1
    expected_id=$(jq -er --arg node "$padded" '
        select(.schema == 1 and (.images | type) == "object" and
          (.nodes | type) == "object" and (.nodes | length) == 32) as $policy |
        $policy.nodes[$node] as $class |
        select($class | type == "string") |
        $policy.images[$class].image_id |
        select(type == "string" and test("^sha256:[0-9a-f]{64}$"))
    ' "$IMAGE_POLICY") || return 1
    [[ "$actual_id" == "$expected_id" ]] || return 1
    if [[ "$source" == "$IMMUTABLE_V3014_SOURCE_COMMIT" ]]; then
        printf '%s\n' immutable-v30.1.4
    else
        printf '%s\n' typed-hotfix-candidate
    fi
}

pow_contract_for()
{
    local node="$1" mining="$2" present identity
    present=$(jq -er '
        select(type == "object") as $object |
        [
            "mining_gate_coherent",
            "mining_gate_action",
            "mining_gate_can_submit",
            "mining_gate_database_ambiguous",
            "mining_gate_unresolved_components",
            "mining_gate_live_claims",
            "mining_gate_eligible_claims",
            "mining_gate_family_claims",
            "mining_gate_unsafe_claims",
            "mining_gate_unsafe_components",
            "mining_gate_relay_txid",
            "mining_gate_lineage_head_txid",
            "mining_gate_candidate_state_fingerprint"
        ] as $fields |
        [$fields[] as $field | $object | has($field)] |
        map(select(. == true)) | length
    ' <<< "$mining") || return 1
    identity=$(pow_contract_identity_for "$node") || return 1
    case "$identity:$present" in
        immutable-v30.1.4:0)
            printf '%s\n' immutable-v30.1.4
            ;;
        typed-hotfix-candidate:13)
            printf '%s\n' typed-hotfix-candidate
            ;;
        *)
            # Exact immutable identity permits zero typed fields. Every other
            # policy-pinned v30.1.4 image requires the complete candidate
            # schema; zero or partial visibility fails closed.
            return 1
            ;;
    esac
}

candidate_claim_state_clean()
{
    local mining="$1" recovery="$2"
    jq -e '
        type == "object" and
        (.mining_gate_coherent | type) == "boolean" and
        .mining_gate_coherent == true and
        (.mining_gate_action | type) == "string" and
        (.mining_gate_action as $action |
            ["create_new_anchor", "wait_for_live", "wait_for_next_tip",
             "relay_existing", "refresh_same_anchor"] | index($action)) != null and
        (.mining_gate_can_submit | type) == "boolean" and
        (if (.mining_gate_action == "create_new_anchor" or
             .mining_gate_action == "refresh_same_anchor")
         then .mining_gate_can_submit == true
         elif .mining_gate_action == "wait_for_next_tip"
         then true
         else .mining_gate_can_submit == false end) and
        (.mining_gate_database_ambiguous | type) == "boolean" and
        .mining_gate_database_ambiguous == false and
        (.claim_recovery_database_outcome_ambiguous | type) == "boolean" and
        .claim_recovery_database_outcome_ambiguous == false and
        ([.unresolved_claims,
          .live_claims,
          .quarantined_claims,
          .blocking_quarantined_claims,
          .raw_quarantined_claims] |
            all(type == "number" and . >= 0 and floor == .)) and
        ([.mining_gate_unresolved_components,
          .mining_gate_live_claims,
          .mining_gate_eligible_claims,
          .mining_gate_family_claims,
          .mining_gate_unsafe_claims,
          .mining_gate_unsafe_components] |
            all(type == "number" and . >= 0 and floor == .)) and
        .mining_gate_unsafe_claims == 0 and
        .mining_gate_unsafe_components == 0 and
        (.mining_gate_relay_txid | type) == "string" and
        (.mining_gate_relay_txid | test("^[0-9a-f]{64}$")) and
        (if .mining_gate_action == "relay_existing"
         then .mining_gate_relay_txid !=
          "0000000000000000000000000000000000000000000000000000000000000000"
         elif .mining_gate_action == "wait_for_next_tip"
         then true
         else .mining_gate_relay_txid ==
          "0000000000000000000000000000000000000000000000000000000000000000"
         end) and
        (.mining_gate_lineage_head_txid | type) == "string" and
        (.mining_gate_lineage_head_txid | test("^[0-9a-f]{64}$")) and
        (.mining_gate_candidate_state_fingerprint | type) == "string" and
        (.mining_gate_candidate_state_fingerprint | test("^[0-9a-f]{64}$"))
    ' >/dev/null <<< "$mining" &&
        jq -e '
            type == "object" and
            (.policy | type) == "object" and
            (.policy.version | type) == "number" and
            (.policy.version | floor) == .policy.version and .policy.version >= 0 and
            (.policy.mode | type) == "string" and
            (.policy.choice_recorded | type) == "boolean" and
            (.policy.automatic_enabled | type) == "boolean" and
            (.policy_authoritative | type) == "boolean" and
            .policy_authoritative == true and
            (.policy.automatic_authorized | type) == "boolean" and
            .policy.automatic_authorized == false and
            ([.policy.max_fee_per_resolution,
              .policy.aggregate_batch_fee_cap,
              .policy.rolling_fee_budget] |
                all(type == "number" and . >= 0)) and
            ([.policy.rolling_fee_window_seconds,
              .policy.max_actions_per_window,
              .policy.minimum_stale_blocks] |
                all(type == "number" and . >= 0 and floor == .)) and
            (.policy_state_status | type) == "string" and
            (.policy_state_detail | type) == "string" and
            (.chain_ready | type) == "boolean" and .chain_ready == true and
            (.database_outcome_ambiguous | type) == "boolean" and
            .database_outcome_ambiguous == false and
            (.active_tip | type) == "string" and
            (.active_tip | test("^[0-9a-f]{64}$")) and
            (.active_height | type) == "number" and
            (.active_height | floor) == .active_height and .active_height >= -1 and
            (.wallet_processed_tip | type) == "string" and
            (.wallet_processed_tip | test("^[0-9a-f]{64}$")) and
            (.wallet_processed_height | type) == "number" and
            (.wallet_processed_height | floor) == .wallet_processed_height and
            (.wallet_generation | type) == "number" and
            (.wallet_generation | floor) == .wallet_generation and
            .wallet_generation >= 0 and
            (.wallet_tip_matches | type) == "boolean" and
            .wallet_tip_matches == true and
            ([.raw_quarantined_claims,
              .blocking_quarantined_claims,
              .actionable_quarantined_claims,
              .resolved_on_active_chain_claims,
              .indeterminate_quarantined_claims,
              .components,
              .raw_claim_objects,
              .live_claim_objects,
              .quarantined_claim_objects,
              .blocking_components,
              .retired_claim_objects,
              .retired_components,
              .resolved_components,
              .confirmed_manual_resolutions,
              .confirmed_automatic_resolutions,
              .automatic_actions_in_window,
              .reconciled_descendant_claims,
              .claims_recycled] |
                all(type == "number" and . >= 0 and floor == .)) and
            (.pending_manual_resolutions | type) == "number" and
            (.pending_manual_resolutions | floor) == .pending_manual_resolutions and
            .pending_manual_resolutions >= 0 and
            (.pending_automatic_resolutions | type) == "number" and
            (.pending_automatic_resolutions | floor) == .pending_automatic_resolutions and
            .pending_automatic_resolutions >= 0 and
            (.confirmed_resolution_fees | type) == "number" and
            .confirmed_resolution_fees >= 0 and
            (.automatic_fee_exposure_in_window | type) == "number" and
            .automatic_fee_exposure_in_window >= 0
        ' >/dev/null <<< "$recovery"
}

node_claim_state_clean()
{
    local node="$1" version="$2" mining="$3" recovery contract
    case "$version" in
        300103)
            legacy_claim_state_clean "$mining"
            ;;
        300104)
            recovery=$(wallet_rpc_for "$node" getpowclaimrecoveryinfo 2>/dev/null) || return 1
            contract=$(pow_contract_for "$node" "$mining") || return 1
            case "$contract" in
                immutable-v30.1.4)
                    immutable_v3014_claim_state_clean "$mining" "$recovery"
                    ;;
                typed-hotfix-candidate)
                    candidate_claim_state_clean "$mining" "$recovery"
                    ;;
                *)
                    return 1
                    ;;
            esac
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

candidate_pow_role_common_ready()
{
    jq -e '
        type == "object" and
        (.enabled | type) == "boolean" and
        (.autostart | type) == "boolean" and .autostart == false and
        (.state | type) == "string" and
        (.threads | type) == "number" and (.threads | floor) == .threads and
        .threads == 1 and
        (.cpu_percent | type) == "number" and .cpu_percent == 1 and
        (.hashrate | type) == "number" and .hashrate >= 0 and
        ([.unresolved_claims,
          .live_claims,
          .quarantined_claims,
          .blocking_quarantined_claims,
          .raw_quarantined_claims] |
            all(type == "number" and . >= 0 and floor == .)) and
        (.claim_recovery_database_outcome_ambiguous | type) == "boolean" and
        .claim_recovery_database_outcome_ambiguous == false and
        .allow_automatic_quantum_key_creation == false and
        (.allow_automatic_quantum_key_creation | type) == "boolean"
    ' >/dev/null <<< "$1"
}

candidate_regular_pow_reserve_ready()
{
    jq -e '
        type == "object" and
        (.stake_reserve_snapshot_available | type) == "boolean" and
        .stake_reserve_snapshot_available == true and
        (.reserved_stake_coins | type) == "number" and
        (.reserved_stake_coins | floor) == .reserved_stake_coins and
        .reserved_stake_coins >= 1 and
        (.last_stake_coin_guard | type) == "boolean"
    ' >/dev/null <<< "$1"
}

regular_pow_ready()
{
    local node="$1" version="$2" mining="$3" contract
    case "$version" in
        300103)
            jq -e '.enabled == true and .threads == 1 and .cpu_percent == 1 and
                .hashrate > 0 and (.live_claims | type) == "number" and
                .live_claims >= 0 and .live_claims <= 64 and
                .allow_automatic_quantum_key_creation == false' \
                >/dev/null <<< "$mining"
            ;;
        300104)
            contract=$(pow_contract_for "$node" "$mining") || return 1
            case "$contract" in
                immutable-v30.1.4)
                    jq -e '.enabled == true and .threads == 1 and .cpu_percent == 1 and
                        .hashrate > 0 and (.live_claims | type) == "number" and
                        .live_claims >= 0 and .live_claims <= 64 and
                        .allow_automatic_quantum_key_creation == false' \
                        >/dev/null <<< "$mining"
                    ;;
                typed-hotfix-candidate)
                    candidate_pow_role_common_ready "$mining" &&
                        candidate_regular_pow_reserve_ready "$mining" &&
                        jq -e '.enabled == true and
                            (.state == "ready" or .state == "hashing" or
                             .state == "claim_in_flight")' \
                            >/dev/null <<< "$mining"
                    ;;
                *)
                    return 1
                    ;;
            esac
            ;;
        *)
            return 1
            ;;
    esac
}

free_claim_pow_ready()
{
    local node="$1" version="$2" mining="$3" contract
    case "$version" in
        300103)
            jq -e '.enabled == false and .hashrate == 0 and .live_claims == 0 and
                .allow_automatic_quantum_key_creation == false' \
                >/dev/null <<< "$mining"
            ;;
        300104)
            contract=$(pow_contract_for "$node" "$mining") || return 1
            case "$contract" in
                immutable-v30.1.4)
                    jq -e '.enabled == false and .hashrate == 0 and .live_claims == 0 and
                        .allow_automatic_quantum_key_creation == false' \
                        >/dev/null <<< "$mining"
                    ;;
                typed-hotfix-candidate)
                    candidate_pow_role_common_ready "$mining" &&
                        jq -e '.enabled == false and .state == "disabled" and
                            .hashrate == 0' >/dev/null <<< "$mining"
                    ;;
                *)
                    return 1
                    ;;
            esac
            ;;
        *)
            return 1
            ;;
    esac
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
    if [[ "$node" -ne "$FREE_CLAIM_NODE" ]] && ! regular_pow_ready "$node" "$version" "$mining"; then
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
           { { [[ "$node" -eq "$FREE_CLAIM_NODE" ]] && free_claim_pow_ready "$node" "$version" "$mining"; } ||
             { [[ "$node" -ne "$FREE_CLAIM_NODE" ]] && regular_pow_ready "$node" "$version" "$mining"; }; } &&
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
