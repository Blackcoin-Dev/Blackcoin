#!/usr/bin/env bash

# Fail-closed, resumable v30.1.4 fleet rollout. The default action is `plan`,
# which performs no live operation. `apply` requires an explicit confirmation.

set -Eeuo pipefail
umask 077
export LC_ALL=C TZ=UTC

PACKAGE_ROOT=$(CDPATH='' cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || exit 1
readonly PACKAGE_ROOT
bootstrap_package_integrity()
{
    local owner mode
    [[ -d "$PACKAGE_ROOT" && ! -L "$PACKAGE_ROOT" &&
       -f "$PACKAGE_ROOT/SHA256SUMS" && ! -L "$PACKAGE_ROOT/SHA256SUMS" &&
       "$(realpath -e -- "$PACKAGE_ROOT/SHA256SUMS")" == "$PACKAGE_ROOT/SHA256SUMS" &&
       "$(stat -c '%u:%g:%a' "$PACKAGE_ROOT/SHA256SUMS")" == 0:0:600 ]] || return 1
    owner=$(stat -c '%u:%g' "$PACKAGE_ROOT") || return 1
    mode=$(stat -c '%a' "$PACKAGE_ROOT") || return 1
    [[ "$owner" == 0:0 && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 0022) == 0 )) || return 1
    [[ -z "$(find "$PACKAGE_ROOT" -type l -print -quit)" &&
       -z "$(find "$PACKAGE_ROOT" ! -type d ! -type f -print -quit)" ]] || return 1
    cmp -s \
        <(cd "$PACKAGE_ROOT" && find . -type f ! -path './SHA256SUMS' -print | sort) \
        <(awk 'NF == 2 && $1 ~ /^[0-9a-f]{64}$/ {
            name=$2; sub(/^\\*/, "", name); sub(/^[.]\//, "", name); print "./" name
        }' "$PACKAGE_ROOT/SHA256SUMS" | sort) || return 1
    (cd "$PACKAGE_ROOT" && sha256sum --strict -c SHA256SUMS >/dev/null)
}
bootstrap_package_integrity || {
    printf '%s\n' 'FATAL: rollout package failed bootstrap integrity verification' >&2
    exit 1
}
unset -f bootstrap_package_integrity
# shellcheck source=lib/live_checks.sh
source "$PACKAGE_ROOT/lib/live_checks.sh"
# shellcheck source=lib/data_rollback.sh
source "$PACKAGE_ROOT/lib/data_rollback.sh"

readonly ACTION=${1:-plan}
readonly WAVE_PLAN=${WAVE_PLAN:-$PACKAGE_ROOT/waves.txt}
readonly RENDER_COMPOSE="$PACKAGE_ROOT/render_compose_images.awk"
readonly RENDER_POLICY="$PACKAGE_ROOT/render_policy.sh"
readonly RENDER_GUARD="$PACKAGE_ROOT/render_guard_pin.sh"
readonly SOAK_AUDITOR="$PACKAGE_ROOT/fleet_soak_audit.sh"
readonly INHIBITOR_INSTALLER="$PACKAGE_ROOT/install_transaction_inhibitors.sh"
readonly INHIBITOR_RELEASER="$PACKAGE_ROOT/release_transaction_inhibitors.sh"
readonly RUNTIME_COMPAT_INSTALLER="$PACKAGE_ROOT/install_runtime_guard_3014_compat.sh"
readonly NORMAL_UNLOCK_HELPER="$STATE_DIR/blackcoin_node_normal_unlock.sh"
readonly POW_START_HELPER="$STATE_DIR/blackcoin_pow_start_only.sh"
readonly NORMAL_UNLOCK_HELPER_SHA256='acf28446e842fd0fa92b06c2ebc182e9da38fcde7bac06dd920d50a33e4e3dd1'
readonly POW_START_HELPER_SHA256='21808f232ca3961e180a4c2dd3853e4aef93c2dfdf4821b5d63ca5106c5676ea'
readonly FREE_CLAIM_PAUSE_CONTENT='schema=1 state=paused authority=v30.1.4-fleet-transaction'

RUN_DIR=${RESUME_RUN_DIR:-}
CURRENT_WAVE_DIR=
CURRENT_WAVE_NODES=()
CURRENT_WAVE_COMMITTED=0
CURRENT_WAVE_ROLLED_BACK=0
CURRENT_WAVE_LAUNCH_ATTEMPTED=0
CURRENT_WAVE_ACTIVATED=0
CURRENT_WAVE_CONTAINED=0
WAVE_LOCKS_HELD=0
FREE_CLAIM_LOCK_HELD=0
FINALIZATION_ACTIVE=0
FINALIZATION_LOCKS_HELD=0
TERMINAL_COMMIT_ACTIVE=0
TERMINAL_FINALIZED=0
CANARY_HANDOFF_PENDING=0
ACTIVATION_HELPER_PIDS=()
ACTIVATION_HELPER_NODES=()
ACTIVATION_HELPER_PHASES=()
CANDIDATE_BASELINE_HELPER_PIDS=()
CANDIDATE_BASELINE_HELPER_NODES=()
CONTAINMENT_HELPER_PIDS=()
CONTAINMENT_HELPER_NODES=()

atomic_write_json()
{
    local destination="$1" directory temporary
    directory=${destination%/*}
    [[ -d "$directory" && ! -L "$directory" ]] || return 1
    temporary=$(mktemp "$directory/.json-evidence.XXXXXX") || return 1
    if ! jq -S . > "$temporary" || ! chmod 600 "$temporary" ||
       ! chown root:root "$temporary" || ! sync -f "$temporary"; then
        rm -f -- "$temporary"
        return 1
    fi
    if ! mv -fT -- "$temporary" "$destination" || ! sync -f "$directory"; then
        rm -f -- "$temporary"
        return 1
    fi
    [[ -f "$destination" && ! -L "$destination" &&
       "$(stat -c '%u:%g:%a' "$destination")" == 0:0:600 ]]
}

wave_node_prefix()
{
    printf '%s/node-%s\n' "$CURRENT_WAVE_DIR" "$(node_padded "$1")"
}

wave_drain_plan_path()
{
    printf '%s/LEGACY-POW-DRAIN.json\n' "$CURRENT_WAVE_DIR"
}

wave_drain_manifest_path()
{
    printf '%s/WAVE-DRAIN-EVIDENCE.sha256\n' "$CURRENT_WAVE_DIR"
}

wave_node_activation_path()
{
    printf '%s-CANDIDATE-ACTIVATION-ATTEMPTED.json\n' "$(wave_node_prefix "$1")"
}

wave_node_launch_attempt_path()
{
    printf '%s-CANDIDATE-LAUNCH-ATTEMPTED.json\n' "$(wave_node_prefix "$1")"
}

wave_node_launch_authorization_path()
{
    printf '%s-CANDIDATE-LAUNCH-AUTHORIZED.json\n' "$(wave_node_prefix "$1")"
}

wave_node_safe_rollback_path()
{
    printf '%s-SAFE-ROLLBACK.json\n' "$(wave_node_prefix "$1")"
}

wave_node_containment_path()
{
    printf '%s-CONTAINED-NO-ROLLBACK.json\n' "$(wave_node_prefix "$1")"
}

wave_containment_complete_path()
{
    printf '%s/CONTAINMENT-COMPLETE.sha256\n' "$CURRENT_WAVE_DIR"
}

rollback_old_image_authority_dir()
{
    printf '%s/ROLLBACK-OLD-IMAGE-AUTHORITY\n' "$CURRENT_WAVE_DIR"
}

rollback_old_image_authority_path()
{
    printf '%s/AUTHORITY.json\n' "$(rollback_old_image_authority_dir)"
}

rollback_node_old_image_attempt_path()
{
    printf '%s/node-%s-OLD-IMAGE-RECREATE-ATTEMPTED.json\n' \
        "$CURRENT_WAVE_DIR" "$(node_padded "$1")"
}

candidate_recovery_baseline_path()
{
    [[ -n "$CURRENT_WAVE_DIR" && -d "$CURRENT_WAVE_DIR" && ! -L "$CURRENT_WAVE_DIR" ]] || return 1
    printf '%s/candidate-recovery-node-%s.json\n' "$CURRENT_WAVE_DIR" "$(node_padded "$1")"
}

verify_candidate_recovery_baseline_payload()
{
    local node="$1" path prelaunch prelaunch_sha
    valid_node "$node" || return 1
    path=$(candidate_recovery_baseline_path "$node")
    prelaunch="$CURRENT_WAVE_DIR/node-$(node_padded "$node")-wallet-txids.prelaunch.json"
    data_rollback_protected_file "$path" 600 || return 1
    data_rollback_protected_file "$prelaunch" 600 || return 1
    prelaunch_sha=$(sha256sum "$prelaunch" | awk '{print $1}') || return 1
    jq -e --arg image "$CANDIDATE_IMAGE_REF" --arg image_id "$CANDIDATE_IMAGE_ID" \
        --arg source "$SOURCE_COMMIT" --argjson node "$node" \
        --arg prelaunch_sha "$prelaunch_sha" \
        --arg wave_dir "$CURRENT_WAVE_DIR" '
        .schema == 2 and .node == $node and .candidate_image == $image and
        .candidate_image_id == $image_id and .source_commit == $source and
        .wave_dir == $wave_dir and
        (.captured_at | type) == "string" and
        (.container_generation | type) == "string" and (.container_generation | length) > 0 and
        .wallet_locked_throughout == true and
        .wallet_final.unlocked_until == 0 and
        .staking_final.enabled == false and .staking_final.staking == false and
        .staking_final.worker_running == false and
        .staking_final.automatic_qqsignal == false and
        .staking_final.automatic_demurrage_attestation == false and
        .staking_final.automatic_redelegation == false and
        .staking_final.allow_automatic_quantum_key_creation == false and
        .mining_final.enabled == false and .mining_final.autostart == false and
        .mining_final.state == "disabled" and .mining_final.hashrate == 0 and
        .mining_final.live_claims == 0 and .mining_final.quarantined_claims == 0 and
        .mining_final.blocking_quarantined_claims == 0 and
        .mining_final.claim_recovery_database_outcome_ambiguous == false and
        .mining_final.allow_automatic_quantum_key_creation == false and
        .recovery_initial.policy_authoritative == true and
        .recovery_initial.policy.automatic_authorized == false and
        .recovery_initial.database_outcome_ambiguous == false and
        .recovery_final.policy_authoritative == true and
        .recovery_final.policy.automatic_authorized == false and
        .recovery_final.database_outcome_ambiguous == false and
        .recovery_final.chain_ready == true and .recovery_final.wallet_tip_matches == true and
        .recovery_final.blocking_quarantined_claims == 0 and
        .recovery_final.blocking_components == 0 and
        .recovery_final.indeterminate_quarantined_claims == 0 and
        .recovery_final.pending_manual_resolutions == 0 and
        .recovery_final.pending_automatic_resolutions == 0 and
        (.recovery_initial.confirmed_resolution_fees | type) == "number" and
        .recovery_final.confirmed_resolution_fees ==
          .recovery_initial.confirmed_resolution_fees and
        .wallet_transaction_guard.prelaunch_sha256 == $prelaunch_sha and
        .wallet_transaction_guard.first_v3014_sha256 == $prelaunch_sha and
        .wallet_transaction_guard.exactly_unchanged == true
    ' "$path" >/dev/null
}

verify_candidate_recovery_baseline_digest()
{
    local node="$1" path metadata actual_sha expected_sha
    path=$(candidate_recovery_baseline_path "$node") || return 1
    metadata="${path}.sha256"
    verify_candidate_recovery_baseline_payload "$node" || return 1
    data_rollback_protected_file "$metadata" 600 || return 1
    [[ "$(wc -l < "$metadata")" -eq 1 ]] || return 1
    actual_sha=$(sha256sum "$path" | awk '{print $1}') || return 1
    expected_sha=$(awk 'NF == 1 && $1 ~ /^[0-9a-f]{64}$/ {print $1}' "$metadata") || return 1
    [[ -n "$expected_sha" && "$actual_sha" == "$expected_sha" ]]
}

verify_candidate_recovery_baseline()
{
    local node="$1" path first prelaunch_sha first_sha
    path=$(candidate_recovery_baseline_path "$node") || return 1
    first="$CURRENT_WAVE_DIR/node-$(node_padded "$node")-wallet-txids.first-v3014.json"
    verify_candidate_recovery_baseline_digest "$node" || return 1
    data_rollback_protected_file "$first" 600 || return 1
    prelaunch_sha=$(jq -er '.wallet_transaction_guard.prelaunch_sha256' "$path") || return 1
    first_sha=$(sha256sum "$first" | awk '{print $1}') || return 1
    [[ "$first_sha" == "$prelaunch_sha" ]]
}

candidate_recovery_fee_for()
{
    local node="$1" path
    verify_candidate_recovery_baseline "$node" || return 1
    path=$(candidate_recovery_baseline_path "$node")
    jq -er '.recovery_initial.confirmed_resolution_fees | select(type == "number")' "$path"
}

capture_wallet_txid_set()
{
    local node="$1" output="$2" transactions
    transactions=$(wallet_rpc_for "$node" listtransactions '*' 1000000 0 true) || return 1
    jq -e 'type == "array" and all(.[];
        (.txid | type) == "string" and (.txid | test("^[0-9a-f]{64}$")))' \
        >/dev/null <<< "$transactions" || return 1
    jq -cS '[.[].txid | select(type == "string" and test("^[0-9a-f]{64}$"))] |
        unique | sort' <<< "$transactions" > "$output"
}

reprove_candidate_recovery_baseline_live_state()
{
    local node="$1" txids_output="$2" path attempt stopped_generation generation expected_id
    local recovery mining staking wallet_info current_fee expected_fee prelaunch expected_txids_sha
    verify_candidate_recovery_baseline_payload "$node" || return 1
    path=$(candidate_recovery_baseline_path "$node") || return 1
    attempt=$(wave_node_launch_attempt_path "$node") || return 1
    verify_candidate_launch_attempt_marker "$node" 0 || return 1
    stopped_generation=$(jq -er '.candidate_stopped_generation' "$attempt") || return 1
    generation=$(jq -er '.container_generation' "$path") || return 1
    expected_id=${generation%%|*}
    [[ "${stopped_generation%%|*}" == "$expected_id" ]] || return 1
    verify_candidate_running_container "$node" "$expected_id" || return 1
    verify_wave_drain_evidence || return 1
    [[ "$(container_generation_for "$node")" == "$generation" ]] || return 1
    recovery=$(wallet_rpc_for "$node" getpowclaimrecoveryinfo) || return 1
    mining=$(wallet_rpc_for "$node" getpowmininginfo) || return 1
    staking=$(wallet_rpc_for "$node" getstakinginfo) || return 1
    wallet_info=$(wallet_rpc_for "$node" getwalletinfo) || return 1
    jq -e '.unlocked_until == 0' >/dev/null <<< "$wallet_info" || return 1
    jq -e '.enabled == false and .autostart == false and .state == "disabled" and
        .hashrate == 0 and .live_claims == 0 and .quarantined_claims == 0 and
        .blocking_quarantined_claims == 0 and
        .claim_recovery_database_outcome_ambiguous == false and
        .allow_automatic_quantum_key_creation == false' >/dev/null <<< "$mining" || return 1
    jq -e '.enabled == false and .staking == false and .worker_running == false and
        .automatic_qqsignal == false and .automatic_demurrage_attestation == false and
        .automatic_redelegation == false and
        .allow_automatic_quantum_key_creation == false' >/dev/null <<< "$staking" || return 1
    verify_donation_defaults_off "$node" || return 1
    jq -e '.policy_authoritative == true and .policy.automatic_authorized == false and
        .database_outcome_ambiguous == false and .chain_ready == true and
        .wallet_tip_matches == true and .blocking_quarantined_claims == 0 and
        .blocking_components == 0 and .indeterminate_quarantined_claims == 0 and
        .pending_manual_resolutions == 0 and .pending_automatic_resolutions == 0 and
        (.confirmed_resolution_fees | type) == "number"' >/dev/null <<< "$recovery" || return 1
    current_fee=$(jq -c '.confirmed_resolution_fees' <<< "$recovery") || return 1
    expected_fee=$(jq -c '.recovery_initial.confirmed_resolution_fees' "$path") || return 1
    [[ "$current_fee" == "$expected_fee" ]] || return 1
    jq -e --argjson fee "$current_fee" '
        .recovery_initial.confirmed_resolution_fees == $fee and
        .recovery_final.confirmed_resolution_fees == $fee
    ' "$path" >/dev/null || return 1
    prelaunch="$CURRENT_WAVE_DIR/node-$(node_padded "$node")-wallet-txids.prelaunch.json"
    capture_wallet_txid_set "$node" "$txids_output" || return 1
    cmp -s "$prelaunch" "$txids_output" || return 1
    expected_txids_sha=$(jq -er '.wallet_transaction_guard.prelaunch_sha256' "$path") || return 1
    [[ "$(sha256sum "$txids_output" | awk '{print $1}')" == "$expected_txids_sha" ]] || return 1
    [[ "$(container_generation_for "$node")" == "$generation" ]]
}

recover_candidate_recovery_baseline_prefix()
{
    local node="$1" path metadata first txids_tmp metadata_tmp
    path=$(candidate_recovery_baseline_path "$node") || return 1
    metadata="${path}.sha256"
    first="$CURRENT_WAVE_DIR/node-$(node_padded "$node")-wallet-txids.first-v3014.json"
    [[ -e "$path" && ! -L "$path" ]] || return 1
    if [[ -e "$metadata" || -L "$metadata" ]]; then
        verify_candidate_recovery_baseline_digest "$node" || return 1
    else
        verify_candidate_recovery_baseline_payload "$node" || return 1
    fi
    if [[ -e "$first" || -L "$first" ]]; then
        data_rollback_protected_file "$first" 600 || return 1
    fi
    txids_tmp=$(mktemp "$CURRENT_WAVE_DIR/.node-$(node_padded "$node")-baseline-recovery-txids.XXXXXX") ||
        return 1
    if ! reprove_candidate_recovery_baseline_live_state "$node" "$txids_tmp" ||
       ! chmod 600 "$txids_tmp" || ! chown root:root "$txids_tmp" || ! sync -f "$txids_tmp"; then
        rm -f -- "$txids_tmp"
        return 1
    fi
    if ! mv -fT -- "$txids_tmp" "$first" || ! sync -f "$CURRENT_WAVE_DIR"; then
        rm -f -- "$txids_tmp"
        return 1
    fi
    if [[ ! -e "$metadata" && ! -L "$metadata" ]]; then
        metadata_tmp=$(mktemp "${path%/*}/.node-recovery-baseline-sha.XXXXXX") || return 1
        if ! sha256sum "$path" | awk '{print $1}' > "$metadata_tmp" ||
           ! chmod 600 "$metadata_tmp" || ! chown root:root "$metadata_tmp" ||
           ! sync -f "$metadata_tmp"; then
            rm -f -- "$metadata_tmp"
            return 1
        fi
        if ! mv -T -- "$metadata_tmp" "$metadata" || ! sync -f "${path%/*}"; then
            rm -f -- "$metadata_tmp"
            return 1
        fi
    fi
    verify_candidate_recovery_baseline "$node"
}

establish_candidate_recovery_baseline()
{
    local node="$1" path metadata recovery recovery_initial='' temporary metadata_tmp image id
    local ready=0 deadline mining staking wallet_info txids_before txids_after txids_tmp
    local prelaunch_sha first_sha generation generation_now initial_fee
    local launch_attempt stopped_generation expected_container_id
    [[ " ${CURRENT_WAVE_NODES[*]} " == *" $node "* ]] || return 1
    if [[ "$node" -eq "$FREE_CLAIM_NODE" && "$FREE_CLAIM_LOCK_HELD" -ne 1 ]]; then
        return 1
    fi
    path=$(candidate_recovery_baseline_path "$node")
    metadata="${path}.sha256"
    if [[ -e "$path" || -L "$path" || -e "$metadata" || -L "$metadata" ]]; then
        if verify_candidate_recovery_baseline "$node"; then
            return 0
        fi
        [[ -e "$path" && ! -L "$path" && ! -L "$metadata" ]] || return 1
        recover_candidate_recovery_baseline_prefix "$node"
        return
    fi
    launch_attempt=$(wave_node_launch_attempt_path "$node") || return 1
    verify_candidate_launch_attempt_marker "$node" 0 || return 1
    stopped_generation=$(jq -er '.candidate_stopped_generation' "$launch_attempt") || return 1
    expected_container_id=${stopped_generation%%|*}
    verify_candidate_running_container "$node" "$expected_container_id" || return 1
    image=$(docker inspect -f '{{.Config.Image}}' "$(container_for "$node")")
    id=$(docker inspect -f '{{.Image}}' "$(container_for "$node")")
    [[ "$image" == "$CANDIDATE_IMAGE_REF" && "$id" == "$CANDIDATE_IMAGE_ID" ]] ||
        return 1
    verify_wave_drain_evidence || return 1
    txids_before="$CURRENT_WAVE_DIR/node-$(node_padded "$node")-wallet-txids.prelaunch.json"
    [[ -f "$txids_before" && ! -L "$txids_before" ]] || return 1
    generation=$(container_generation_for "$node") || return 1
    txids_tmp=$(mktemp "$CURRENT_WAVE_DIR/.node-$(node_padded "$node")-candidate-txids.XXXXXX") ||
        return 1
    deadline=$((SECONDS + 1200))
    while ((SECONDS < deadline)); do
        recovery=$(wallet_rpc_for "$node" getpowclaimrecoveryinfo 2>/dev/null || true)
        mining=$(wallet_rpc_for "$node" getpowmininginfo 2>/dev/null || true)
        staking=$(wallet_rpc_for "$node" getstakinginfo 2>/dev/null || true)
        wallet_info=$(wallet_rpc_for "$node" getwalletinfo 2>/dev/null || true)
        if [[ -z "$recovery" || -z "$mining" || -z "$staking" || -z "$wallet_info" ]]; then
            sleep 5
            continue
        fi
        generation_now=$(container_generation_for "$node") || { rm -f -- "$txids_tmp"; return 1; }
        [[ "$generation_now" == "$generation" ]] || { rm -f -- "$txids_tmp"; return 1; }
        jq -e '.unlocked_until == 0' >/dev/null 2>&1 <<< "$wallet_info" || {
            rm -f -- "$txids_tmp"; return 1;
        }
        jq -e '.enabled == false and .autostart == false and .state == "disabled" and
            .hashrate == 0 and .live_claims == 0 and
            (.quarantined_claims == 0 or .quarantined_claims == 1) and
            .claim_recovery_database_outcome_ambiguous == false and
            .allow_automatic_quantum_key_creation == false' >/dev/null 2>&1 <<< "$mining" ||
            { rm -f -- "$txids_tmp"; return 1; }
        jq -e '.enabled == false and .staking == false and .worker_running == false and
            .automatic_qqsignal == false and .automatic_demurrage_attestation == false and
            .automatic_redelegation == false and
            .allow_automatic_quantum_key_creation == false' >/dev/null 2>&1 <<< "$staking" ||
            { rm -f -- "$txids_tmp"; return 1; }
        verify_donation_defaults_off "$node" || { rm -f -- "$txids_tmp"; return 1; }
        jq -e '.policy_authoritative == true and .policy.automatic_authorized == false and
            .database_outcome_ambiguous == false and
            (.confirmed_resolution_fees | type) == "number"' >/dev/null 2>&1 <<< "$recovery" ||
            { rm -f -- "$txids_tmp"; return 1; }
        if [[ -z "$recovery_initial" ]]; then
            recovery_initial=$recovery
            initial_fee=$(jq -c '.confirmed_resolution_fees' <<< "$recovery") || {
                rm -f -- "$txids_tmp"; return 1;
            }
        else
            jq -e --argjson fee "$initial_fee" '.confirmed_resolution_fees == $fee' \
                >/dev/null <<< "$recovery" || { rm -f -- "$txids_tmp"; return 1; }
        fi
        capture_wallet_txid_set "$node" "$txids_tmp" || { rm -f -- "$txids_tmp"; return 1; }
        cmp -s "$txids_before" "$txids_tmp" || { rm -f -- "$txids_tmp"; return 1; }
        if jq -e '.chain_ready == true and .wallet_tip_matches == true and
                .blocking_quarantined_claims == 0 and .blocking_components == 0 and
                .indeterminate_quarantined_claims == 0 and .pending_manual_resolutions == 0 and
                .pending_automatic_resolutions == 0' >/dev/null <<< "$recovery" &&
           jq -e '.enabled == false and .autostart == false and .state == "disabled" and
               .hashrate == 0 and .live_claims == 0 and .quarantined_claims == 0 and
               .blocking_quarantined_claims == 0 and
               .claim_recovery_database_outcome_ambiguous == false and
               .allow_automatic_quantum_key_creation == false' >/dev/null <<< "$mining"; then
            ready=1
            break
        fi
        sleep 5
    done
    ((ready == 1)) || { rm -f -- "$txids_tmp"; return 1; }
    [[ "$(container_generation_for "$node")" == "$generation" ]] ||
        { rm -f -- "$txids_tmp"; return 1; }
    verify_candidate_running_container "$node" "$expected_container_id" ||
        { rm -f -- "$txids_tmp"; return 1; }
    txids_after="$CURRENT_WAVE_DIR/node-$(node_padded "$node")-wallet-txids.first-v3014.json"
    if [[ -e "$txids_after" || -L "$txids_after" ]]; then
        data_rollback_protected_file "$txids_after" 600 || { rm -f -- "$txids_tmp"; return 1; }
    fi
    chmod 600 "$txids_tmp"
    chown root:root "$txids_tmp"
    sync -f "$txids_tmp"
    mv -fT -- "$txids_tmp" "$txids_after"
    sync -f "$CURRENT_WAVE_DIR"
    cmp -s "$txids_before" "$txids_after" || return 1
    prelaunch_sha=$(sha256sum "$txids_before" | awk '{print $1}') || return 1
    first_sha=$(sha256sum "$txids_after" | awk '{print $1}') || return 1
    install -d -m 700 -o root -g root "${path%/*}"
    temporary=$(mktemp "${path%/*}/.node-recovery-baseline.XXXXXX")
    metadata_tmp=$(mktemp "${path%/*}/.node-recovery-baseline-sha.XXXXXX")
    jq -n --arg image "$CANDIDATE_IMAGE_REF" --arg image_id "$CANDIDATE_IMAGE_ID" \
        --arg source "$SOURCE_COMMIT" --arg captured_at "$(date -u +%FT%TZ)" \
        --argjson node "$node" --argjson recovery_initial "$recovery_initial" \
        --argjson recovery_final "$recovery" --argjson wallet_final "$wallet_info" \
        --argjson staking_final "$staking" --argjson mining_final "$mining" \
        --arg prelaunch_sha "$prelaunch_sha" --arg first_sha "$first_sha" \
        --arg wave_dir "$CURRENT_WAVE_DIR" --arg generation "$generation" \
        '{schema:2,node:$node,candidate_image:$image,candidate_image_id:$image_id,
          source_commit:$source,wave_dir:$wave_dir,captured_at:$captured_at,
          container_generation:$generation,wallet_locked_throughout:true,
          wallet_final:$wallet_final,staking_final:$staking_final,mining_final:$mining_final,
          recovery_initial:$recovery_initial,recovery_final:$recovery_final,
          wallet_transaction_guard:{prelaunch_sha256:$prelaunch_sha,
            first_v3014_sha256:$first_sha,exactly_unchanged:true}}' > "$temporary"
    chmod 600 "$temporary"
    chown root:root "$temporary"
    sha256sum "$temporary" | awk '{print $1}' > "$metadata_tmp"
    chmod 600 "$metadata_tmp"
    chown root:root "$metadata_tmp"
    sync -f "$temporary"; sync -f "$metadata_tmp"
    if ! mv -fT -- "$temporary" "$path"; then
        rm -f -- "$temporary" "$metadata_tmp"
        return 1
    fi
    sync -f "${path%/*}" || return 1
    if ! mv -fT -- "$metadata_tmp" "$metadata"; then
        rm -f -- "$metadata_tmp"
        return 1
    fi
    sync -f "${path%/*}"
    verify_candidate_recovery_baseline "$node"
}

terminate_and_join_candidate_baseline_helpers()
{
    local pid deadline alive index
    ((${#CANDIDATE_BASELINE_HELPER_PIDS[@]} > 0)) || return 0
    for pid in "${CANDIDATE_BASELINE_HELPER_PIDS[@]}"; do
        [[ "$pid" =~ ^[1-9][0-9]*$ ]] || continue
        kill -TERM -- "-$pid" 2>/dev/null || true
    done
    deadline=$((SECONDS + 20))
    while ((SECONDS < deadline)); do
        alive=0
        for index in "${!CANDIDATE_BASELINE_HELPER_PIDS[@]}"; do
            pid=${CANDIDATE_BASELINE_HELPER_PIDS[index]}
            [[ "$pid" =~ ^[1-9][0-9]*$ ]] || continue
            if kill -0 -- "-$pid" 2>/dev/null; then
                alive=1
            else
                wait "$pid" 2>/dev/null || true
                CANDIDATE_BASELINE_HELPER_PIDS[index]=''
            fi
        done
        ((alive == 0)) && break
        sleep 1
    done
    for index in "${!CANDIDATE_BASELINE_HELPER_PIDS[@]}"; do
        pid=${CANDIDATE_BASELINE_HELPER_PIDS[index]}
        [[ "$pid" =~ ^[1-9][0-9]*$ ]] || continue
        if kill -0 -- "-$pid" 2>/dev/null; then
            kill -KILL -- "-$pid" 2>/dev/null || true
        else
            wait "$pid" 2>/dev/null || true
            CANDIDATE_BASELINE_HELPER_PIDS[index]=''
        fi
    done
    for pid in "${CANDIDATE_BASELINE_HELPER_PIDS[@]}"; do
        [[ "$pid" =~ ^[1-9][0-9]*$ ]] || continue
        wait "$pid" 2>/dev/null || true
    done
    deadline=$((SECONDS + 5))
    while ((SECONDS < deadline)); do
        alive=0
        for index in "${!CANDIDATE_BASELINE_HELPER_PIDS[@]}"; do
            pid=${CANDIDATE_BASELINE_HELPER_PIDS[index]}
            [[ "$pid" =~ ^[1-9][0-9]*$ ]] || continue
            if kill -0 -- "-$pid" 2>/dev/null; then
                alive=1
            else
                CANDIDATE_BASELINE_HELPER_PIDS[index]=''
            fi
        done
        ((alive == 0)) && break
        sleep 1
    done
    ((alive == 0)) || return 1
    CANDIDATE_BASELINE_HELPER_PIDS=()
    CANDIDATE_BASELINE_HELPER_NODES=()
}

establish_wave_recovery_baselines()
{
    local node pid failed=0 index monitor_was_enabled=0 launch_signal=0
    local remaining completed_pid wait_rc found
    local -a active_pids=()
    ((${#CANDIDATE_BASELINE_HELPER_PIDS[@]} == 0)) ||
        die 'a prior candidate baseline helper set is still live'
    [[ $- == *m* ]] && monitor_was_enabled=1
    # Monitor mode gives every asynchronous function a process group whose
    # PGID is its recorded leader PID. Rollback can then kill the worker and
    # any timeout/docker RPC descendants before it reads or mutates evidence.
    trap 'launch_signal=129' HUP
    trap 'launch_signal=130' INT
    trap 'launch_signal=143' TERM
    ((monitor_was_enabled == 1)) || set -m
    for node in "${CURRENT_WAVE_NODES[@]}"; do
        ((launch_signal == 0)) || break
        establish_candidate_recovery_baseline "$node" \
            > "$CURRENT_WAVE_DIR/node-$(node_padded "$node")-recovery-baseline.log" 2>&1 &
        pid=$!
        CANDIDATE_BASELINE_HELPER_PIDS+=("$pid")
        CANDIDATE_BASELINE_HELPER_NODES+=("$node")
        ((launch_signal == 0)) || break
    done
    ((monitor_was_enabled == 1)) || set +m
    remaining=${#CANDIDATE_BASELINE_HELPER_PIDS[@]}
    while ((remaining > 0 && launch_signal == 0)); do
        completed_pid=''
        active_pids=()
        for pid in "${CANDIDATE_BASELINE_HELPER_PIDS[@]}"; do
            [[ "$pid" =~ ^[1-9][0-9]*$ ]] && active_pids+=("$pid")
        done
        ((${#active_pids[@]} == remaining)) || { failed=1; break; }
        if wait -n -p completed_pid "${active_pids[@]}"; then wait_rc=0; else wait_rc=$?; fi
        ((launch_signal == 0)) || break
        [[ "$completed_pid" =~ ^[1-9][0-9]*$ ]] || { failed=1; break; }
        found=-1
        for index in "${!CANDIDATE_BASELINE_HELPER_PIDS[@]}"; do
            if [[ "${CANDIDATE_BASELINE_HELPER_PIDS[index]}" == "$completed_pid" ]]; then
                found=$index
                break
            fi
        done
        ((found >= 0)) || { failed=1; break; }
        if ((wait_rc != 0)); then
            log "node ${CANDIDATE_BASELINE_HELPER_NODES[found]} candidate recovery baseline failed"
            failed=1
        fi
        if kill -0 -- "-$completed_pid" 2>/dev/null; then
            log "node ${CANDIDATE_BASELINE_HELPER_NODES[found]} left a baseline descendant live"
            failed=1
            break
        else
            CANDIDATE_BASELINE_HELPER_PIDS[found]=''
        fi
        remaining=$((remaining - 1))
    done
    terminate_and_join_candidate_baseline_helpers || failed=1
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    ((launch_signal == 0)) || exit "$launch_signal"
    ((failed == 0)) || die 'one or more candidate recovery baselines failed'
}

usage()
{
    cat <<'EOF'
Usage:
  fleet_rollout.sh plan
  fleet_rollout.sh preflight
  CONFIRM_APPLY=v30.1.4-exact-32 fleet_rollout.sh apply
  CONFIRM_ROLLBACK=v30.1.4-rollback fleet_rollout.sh rollback RUN_DIR

All artifact identity variables shown in rollout.env.example are mandatory for
preflight/apply/rollback. No image pull, reindex, chainstate parking, address
generation, wallet creation, or automatic fee-paying claim recovery is used.
EOF
}

require_host_tools()
{
    local compose_up_help option
    ((BASH_VERSINFO[0] > 5 ||
       (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 1))) ||
        die 'Bash 5.1 or newer is required'
    require_command awk bash cmp cp date diff docker find findmnt flock grep install jq \
        mktemp mountpoint mv od readlink realpath rm rsync sed seq setsid sha256sum sort stat sync tar timeout tr wc xargs zfs
    docker compose version >/dev/null 2>&1 || die 'Docker Compose v2 is unavailable'
    compose_up_help=$(docker compose up --help 2>&1) ||
        die 'Docker Compose up capability probe failed'
    for option in --no-start --no-deps --no-recreate --no-build --pull; do
        grep -Fq -- "$option" <<< "$compose_up_help" ||
            die "Docker Compose up lacks required option: $option"
    done
}

verify_activation_helper()
{
    local path="$1" expected_sha="$2"
    [[ -f "$path" && ! -L "$path" && "$(realpath -e -- "$path")" == "$path" &&
       "$(stat -c '%u:%g:%a' "$path")" == 0:0:600 ]] || return 1
    [[ "$(sha256sum "$path" | awk '{print $1}')" == "$expected_sha" ]]
}

run_activation_helper()
{
    local path="$1" expected_sha="$2" node="$3"
    verify_activation_helper "$path" "$expected_sha" || return 1
    /bin/bash "$path" "$node"
}

verify_runtime_guard_3014_compatibility()
{
    local pinned guard marker_begin marker_end
    marker_begin='# BEGIN V30.1.4 DURABLE ROLLOUT MAINTENANCE INHIBITOR'
    marker_end='# END V30.1.4 DURABLE ROLLOUT MAINTENANCE INHIBITOR'
    assert_protected_file "$WALLET_RUNTIME_GUARD" 600
    assert_protected_file "$ENDPOINT_GUARD" 600
    bash -n "$WALLET_RUNTIME_GUARD" || return 1
    bash -n "$ENDPOINT_GUARD" || return 1
    [[ "$(sha256sum "$WALLET_RUNTIME_GUARD" | awk '{print $1}')" == \
       "$EXPECTED_WALLET_RUNTIME_GUARD_SHA256" ]] || return 1
    grep -Fq '[[ "$class" == final3013 || "$class" == node16fix || "$class" == final3014 ]] && expected_replay_schema=12' \
        "$WALLET_RUNTIME_GUARD" || return 1
    pinned=$(sed -n "s/^EXPECTED_RUNTIME_GUARD_SHA='\([0-9a-f]\{64\}\)'$/\1/p" \
        "$ENDPOINT_GUARD") || return 1
    [[ "$pinned" == "$EXPECTED_WALLET_RUNTIME_GUARD_SHA256" ]] || return 1
    for guard in "$WALLET_RUNTIME_GUARD" "$ENDPOINT_GUARD"; do
        [[ "$(grep -Fxc -- "$marker_begin" "$guard")" -eq 1 &&
           "$(grep -Fxc -- "$marker_end" "$guard")" -eq 1 ]] || return 1
    done
}

verify_node_policy_manifests()
{
    local node="$1" padded wallet wallet_manifest identity_manifest pow_manifest backup backup_sha enabled
    padded=$(node_padded "$node") || return 1
    wallet=$(single_wallet_for "$node") || return 1
    wallet_manifest="$STATE_DIR/runtime-wallet-manifests/node-$padded.json"
    identity_manifest="$STATE_DIR/runtime-identity-manifests/node-$padded.json"
    pow_manifest="$STATE_DIR/pow-wallet-manifests/node-$padded.json"
    for protected in "$wallet_manifest" "$identity_manifest" "$pow_manifest"; do
        [[ -f "$protected" && ! -L "$protected" && "$(realpath -e -- "$protected")" == "$protected" &&
           "$(stat -c '%u:%g:%a' "$protected")" == 0:0:600 ]] || return 1
    done
    jq -e --arg wallet "$wallet" '. == [$wallet]' "$wallet_manifest" >/dev/null || return 1
    jq -e --arg node "$padded" --arg wallet "$wallet" '
        .schema == 2 and .node_id == $node and .wallet == $wallet and
        (.legacy_descriptors_sha256 | test("^[0-9a-f]{64}$")) and
        (.quantum_identity_sha256 | test("^[0-9a-f]{64}$")) and
        (.trusted_policy_sha256 | test("^[0-9a-f]{64}$")) and
        (.trusted_legacy_descriptor_set_sha256 | test("^[0-9a-f]{64}$")) and
        (.trusted_quantum_address_set_sha256 | test("^[0-9a-f]{64}$")) and
        (.trusted_quantum_address_count | type) == "number" and
        .trusted_quantum_address_count >= 1
    ' "$identity_manifest" >/dev/null || return 1
    [[ "$node" -eq "$FREE_CLAIM_NODE" ]] && enabled=false || enabled=true
    jq -e --arg node "$padded" --arg wallet "$wallet" --argjson enabled "$enabled" '
        .schema == 1 and .node_id == $node and .wallet == $wallet and
        .enabled == $enabled and
        (.payout_address | test("^blk1s[0-9a-z]+$")) and
        .label == "PoW - Quantum Claim Address" and
        (.backup_sha256 | test("^[0-9a-f]{64}$")) and
        (.inventory_sha256 | test("^[0-9a-f]{64}$")) and
        (.wallet_fingerprint | test("^[0-9a-f]{64}$"))
    ' "$pow_manifest" >/dev/null || return 1
    backup=$(jq -er '.backup_path' "$pow_manifest") || return 1
    backup_sha=$(jq -er '.backup_sha256' "$pow_manifest") || return 1
    [[ -f "$backup" && ! -L "$backup" && "$(sha256sum "$backup" | awk '{print $1}')" == "$backup_sha" ]]
}

verify_all_policy_manifests()
{
    local node pid failed=0
    local -a pids=() nodes=()
    for node in $(seq 1 "$NODE_COUNT"); do
        verify_node_policy_manifests "$node" &
        pids+=("$!")
        nodes+=("$node")
    done
    for index in "${!pids[@]}"; do
        pid=${pids[$index]}
        if ! wait "$pid"; then
            log "policy manifest verification failed node=${nodes[$index]}"
            failed=1
        fi
    done
    ((failed == 0))
}

assert_protected_file()
{
    local path="$1" expected_mode="$2" canonical state
    [[ -f "$path" && ! -L "$path" ]] || die "protected file is missing or unsafe: $path"
    canonical=$(realpath -e -- "$path")
    [[ "$canonical" == "$path" ]] || die "protected file is not canonical: $path"
    state=$(stat -c '%u:%g:%a' "$path")
    [[ "$state" == "0:0:$expected_mode" ]] || die "protected file ownership/mode mismatch: $path ($state)"
}

assert_marker_state()
{
    local path="$1" expected_content="${2:-}"
    [[ -f "$path" && ! -L "$path" && "$(stat -c '%u:%g:%a' "$path")" == 0:0:600 ]] || return 1
    [[ -z "$expected_content" || "$(cat -- "$path")" == "$expected_content" ]]
}

assert_empty_control_marker()
{
    local path="$1"
    [[ -f "$path" && ! -L "$path" && "$(realpath -e -- "$path")" == "$path" &&
       "$(stat -c '%u:%g:%a:%s' "$path")" == 0:0:600:0 ]]
}

publish_state_token()
{
    local path="$1" value="$2" directory temporary owner mode
    directory=${path%/*}
    [[ -d "$directory" && ! -L "$directory" && "$(realpath -e -- "$directory")" == "$directory" ]] ||
        return 1
    owner=$(stat -c '%u:%g' "$directory") || return 1
    mode=$(stat -c '%a' "$directory") || return 1
    [[ "$owner" == 0:0 && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 0022) == 0 )) || return 1
    if [[ -e "$path" || -L "$path" ]]; then
        [[ -f "$path" && ! -L "$path" && "$(stat -c '%u:%g:%a' "$path")" == 0:0:600 ]] ||
            return 1
    fi
    temporary=$(mktemp "$directory/.state-token.XXXXXX") || return 1
    printf '%s\n' "$value" > "$temporary" || return 1
    chmod 600 "$temporary" || return 1
    chown root:root "$temporary" || return 1
    sync -f "$temporary" || return 1
    mv -fT -- "$temporary" "$path" || return 1
    sync -f "$directory" || return 1
    [[ -f "$path" && ! -L "$path" && "$(stat -c '%u:%g:%a' "$path")" == 0:0:600 &&
       "$(cat "$path")" == "$value" ]]
}

maintenance_nonce_path()
{
    printf '%s/MAINTENANCE-NONCE\n' "$RUN_DIR"
}

create_maintenance_nonce()
{
    local path temporary nonce
    path=$(maintenance_nonce_path)
    [[ ! -e "$path" && ! -L "$path" ]] || die 'maintenance nonce path already exists'
    nonce=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')
    valid_sha256_hex "$nonce" || die 'could not generate a 256-bit maintenance nonce'
    temporary=$(mktemp "$RUN_DIR/.maintenance-nonce.XXXXXX")
    printf '%s\n' "$nonce" > "$temporary"
    chmod 600 "$temporary"
    chown root:root "$temporary"
    sync -f "$temporary"
    mv -fT -- "$temporary" "$path"
    sync -f "$RUN_DIR"
}

verify_maintenance_marker()
{
    local nonce run_canonical
    nonce=$(cat "$(maintenance_nonce_path)" 2>/dev/null) || return 1
    valid_sha256_hex "$nonce" || return 1
    run_canonical=$(realpath -e -- "$RUN_DIR") || return 1
    [[ "$run_canonical" == "$RUN_DIR" && -f "$ROLLOUT_MAINTENANCE_MARKER" &&
       ! -L "$ROLLOUT_MAINTENANCE_MARKER" &&
       "$(realpath -e -- "$ROLLOUT_MAINTENANCE_MARKER")" == "$ROLLOUT_MAINTENANCE_MARKER" &&
       "$(stat -c '%u:%g:%a' "$ROLLOUT_MAINTENANCE_MARKER")" == 0:0:600 ]] || return 1
    jq -e --arg nonce "$nonce" --arg run "$RUN_DIR" '
        . == {schema:1,transaction:"v30.1.4-fleet-rollout",state:"active",
              run_nonce:$nonce,run_dir:$run}
    ' "$ROLLOUT_MAINTENANCE_MARKER" >/dev/null
}

canary_predecessor_path()
{
    printf '%s/baseline/CANARY-MAINTENANCE-PREDECESSOR.json\n' "$RUN_DIR"
}

verify_canary_fleet_handoff()
{
    local verify_live="${1:-1}"
    local predecessor evidence predecessor_sha marker_sha transaction_sha result_sha manifest_sha
    local canary_run canary_nonce fleet_nonce transaction="$RUN_DIR/TRANSACTION.json"
    [[ "$verify_live" == 0 || "$verify_live" == 1 ]] || return 1
    predecessor=$(canary_predecessor_path) || return 1
    evidence="$RUN_DIR/CANARY-FLEET-HANDOFF.json"
    [[ -f "$predecessor" && ! -L "$predecessor" &&
       "$(stat -c '%u:%g:%a' "$predecessor")" == 0:0:600 &&
       -f "$evidence" && ! -L "$evidence" &&
       "$(stat -c '%u:%g:%a' "$evidence")" == 0:0:600 ]] || return 1
    jq -e '. == {schema:1,transaction:"v30.1.4-node27-canary",state:"active",
        run_nonce:.run_nonce,run_dir:.run_dir} and
        (.run_nonce | type == "string" and test("^[0-9a-f]{64}$")) and
        (.run_dir | type == "string")' "$predecessor" >/dev/null || return 1
    predecessor_sha=$(sha256sum "$predecessor" | awk '{print $1}') || return 1
    data_rollback_protected_file "$transaction" 600 || return 1
    transaction_sha=$(sha256sum "$transaction" | awk '{print $1}') || return 1
    if [[ "$verify_live" == 1 ]]; then
        result_sha=$(sha256sum "$PUBLISHED_CANARY_RESULT" | awk '{print $1}') || return 1
        manifest_sha=$(sha256sum "$PUBLISHED_CANARY_EVIDENCE_MANIFEST" | awk '{print $1}') ||
            return 1
    else
        result_sha=$(jq -er '.published_canary.sha256 | select(test("^[0-9a-f]{64}$"))' \
            "$transaction") || return 1
        manifest_sha=$(jq -er \
            '.published_canary.evidence_manifest.sha256 | select(test("^[0-9a-f]{64}$"))' \
            "$transaction") || return 1
        [[ "$result_sha" == "$EXPECTED_CANARY_RESULT_SHA256" &&
           "$manifest_sha" == "$EXPECTED_CANARY_EVIDENCE_MANIFEST_SHA256" ]] || return 1
    fi
    canary_run=$(jq -er '.run_dir' "$predecessor") || return 1
    canary_nonce=$(jq -er '.run_nonce' "$predecessor") || return 1
    fleet_nonce=$(cat "$(maintenance_nonce_path)") || return 1
    if [[ "$verify_live" == 1 ]]; then
        verify_maintenance_marker || return 1
        marker_sha=$(sha256sum "$ROLLOUT_MAINTENANCE_MARKER" | awk '{print $1}') || return 1
    else
        marker_sha=$(jq -n --arg nonce "$fleet_nonce" --arg run "$RUN_DIR" '
            {schema:1,transaction:"v30.1.4-fleet-rollout",state:"active",
             run_nonce:$nonce,run_dir:$run}' | sha256sum | awk '{print $1}') || return 1
    fi
    jq -e --arg predecessor_sha "$predecessor_sha" --arg canary_run "$canary_run" \
        --arg canary_nonce "$canary_nonce" '
        .canary_handoff == {required:true,protocol:"atomic-replace-v1",
          predecessor_marker_sha256:$predecessor_sha,
          predecessor_run_dir:$canary_run,predecessor_run_nonce:$canary_nonce}
    ' "$transaction" >/dev/null || return 1
    jq -e --arg run "$RUN_DIR" --arg canary_run "$canary_run" --arg canary_nonce "$canary_nonce" \
        --arg fleet_nonce "$fleet_nonce" --arg predecessor_sha "$predecessor_sha" \
        --arg marker_sha "$marker_sha" --arg transaction_sha "$transaction_sha" \
        --arg result_sha "$result_sha" --arg manifest_sha "$manifest_sha" '
        .schema == 1 and .transaction == "v30.1.4-canary-fleet-handoff" and
        .protocol == "atomic-replace-v1" and .continuous_maintenance == true and
        .canary == {run_dir:$canary_run,run_nonce:$canary_nonce,
          marker_sha256:$predecessor_sha,result_sha256:$result_sha,
          evidence_manifest_sha256:$manifest_sha} and
        .fleet == {run_dir:$run,run_nonce:$fleet_nonce,
          transaction_manifest_sha256:$transaction_sha,marker_sha256:$marker_sha} and
        (.adopted_at | type == "string")
    ' "$evidence" >/dev/null
}

publish_canary_fleet_handoff()
{
    local predecessor evidence predecessor_sha marker_sha transaction_sha result_sha manifest_sha
    local canary_run canary_nonce fleet_nonce
    predecessor=$(canary_predecessor_path) || return 1
    evidence="$RUN_DIR/CANARY-FLEET-HANDOFF.json"
    if [[ -e "$evidence" || -L "$evidence" ]]; then
        verify_canary_fleet_handoff 0
        return
    fi
    verify_maintenance_marker || return 1
    predecessor_sha=$(sha256sum "$predecessor" | awk '{print $1}') || return 1
    marker_sha=$(sha256sum "$ROLLOUT_MAINTENANCE_MARKER" | awk '{print $1}') || return 1
    transaction_sha=$(sha256sum "$RUN_DIR/TRANSACTION.json" | awk '{print $1}') || return 1
    result_sha=$(sha256sum "$PUBLISHED_CANARY_RESULT" | awk '{print $1}') || return 1
    manifest_sha=$(sha256sum "$PUBLISHED_CANARY_EVIDENCE_MANIFEST" | awk '{print $1}') || return 1
    canary_run=$(jq -er '.run_dir' "$predecessor") || return 1
    canary_nonce=$(jq -er '.run_nonce' "$predecessor") || return 1
    fleet_nonce=$(cat "$(maintenance_nonce_path)") || return 1
    jq -n --arg run "$RUN_DIR" --arg canary_run "$canary_run" --arg canary_nonce "$canary_nonce" \
        --arg fleet_nonce "$fleet_nonce" --arg predecessor_sha "$predecessor_sha" \
        --arg marker_sha "$marker_sha" --arg transaction_sha "$transaction_sha" \
        --arg result_sha "$result_sha" --arg manifest_sha "$manifest_sha" \
        --arg adopted_at "$(date -u +%FT%TZ)" '
        {schema:1,transaction:"v30.1.4-canary-fleet-handoff",protocol:"atomic-replace-v1",
         continuous_maintenance:true,
         canary:{run_dir:$canary_run,run_nonce:$canary_nonce,marker_sha256:$predecessor_sha,
           result_sha256:$result_sha,evidence_manifest_sha256:$manifest_sha},
         fleet:{run_dir:$run,run_nonce:$fleet_nonce,
           transaction_manifest_sha256:$transaction_sha,marker_sha256:$marker_sha},
         adopted_at:$adopted_at}' | atomic_write_json "$evidence" || return 1
    verify_canary_fleet_handoff
}

adopt_canary_maintenance_marker()
{
    local predecessor nonce temporary
    [[ "$WAVE_LOCKS_HELD" -eq 1 && "$FREE_CLAIM_LOCK_HELD" -eq 1 ]] || return 1
    predecessor=$(canary_predecessor_path) || return 1
    [[ -f "$predecessor" && ! -L "$predecessor" ]] || return 1
    if verify_maintenance_marker; then
        publish_canary_fleet_handoff
        return
    fi
    verify_published_canary_handoff_ready || return 1
    cmp -s "$predecessor" "$ROLLOUT_MAINTENANCE_MARKER" || return 1
    nonce=$(cat "$(maintenance_nonce_path)") || return 1
    valid_sha256_hex "$nonce" || return 1
    temporary=$(mktemp "$STATE_DIR/.v3014-maintenance-handoff.XXXXXX") || return 1
    jq -n --arg nonce "$nonce" --arg run "$RUN_DIR" \
        '{schema:1,transaction:"v30.1.4-fleet-rollout",state:"active",
          run_nonce:$nonce,run_dir:$run}' > "$temporary" || return 1
    chmod 600 "$temporary" && chown root:root "$temporary" && sync -f "$temporary" || return 1
    mv -fT -- "$temporary" "$ROLLOUT_MAINTENANCE_MARKER" || return 1
    sync -f "$STATE_DIR" || return 1
    verify_maintenance_marker || return 1
    publish_canary_fleet_handoff
}

activate_maintenance_marker()
{
    local reactivation_mode="${1:-initial-handoff}" nonce temporary
    [[ "$reactivation_mode" == initial-handoff ||
       "$reactivation_mode" == post-handoff-reactivation ]] ||
        die 'invalid maintenance-marker activation mode'
    if [[ -e "$ROLLOUT_MAINTENANCE_MARKER" || -L "$ROLLOUT_MAINTENANCE_MARKER" ]]; then
        if verify_maintenance_marker; then
            if [[ -e "$RUN_DIR/CANARY-FLEET-HANDOFF.json" ||
                  -L "$RUN_DIR/CANARY-FLEET-HANDOFF.json" ]]; then
                verify_canary_fleet_handoff 0 ||
                    die 'active fleet maintenance marker has changed handoff evidence'
            elif [[ -f "$(canary_predecessor_path)" &&
                    ! -L "$(canary_predecessor_path)" ]]; then
                [[ "$WAVE_LOCKS_HELD" -eq 1 && "$FREE_CLAIM_LOCK_HELD" -eq 1 ]] ||
                    die 'unsealed fleet maintenance handoff requires wave and Free Claim locks'
                publish_canary_fleet_handoff ||
                    die 'active fleet maintenance marker handoff could not be sealed'
            fi
        elif [[ -f "$(canary_predecessor_path)" && ! -L "$(canary_predecessor_path)" ]]; then
            adopt_canary_maintenance_marker ||
                die 'active canary marker could not be atomically adopted by the fleet transaction'
        else
            die 'foreign or malformed rollout maintenance marker exists'
        fi
        return 0
    fi
    if [[ "$reactivation_mode" == initial-handoff ]]; then
        die 'the exact active canary marker is absent; fresh fleet-marker creation is prohibited'
    fi
    [[ -f "$RUN_DIR/CANARY-FLEET-HANDOFF.json" &&
       ! -L "$RUN_DIR/CANARY-FLEET-HANDOFF.json" ]] ||
        die 'post-handoff maintenance reactivation has no durable canary-to-fleet authority'
    jq -e '.canary_handoff.required == true and
        .canary_handoff.protocol == "atomic-replace-v1"' \
        "$RUN_DIR/TRANSACTION.json" >/dev/null ||
        die 'post-handoff maintenance reactivation has no mandatory handoff identity'
    verify_canary_fleet_handoff 0 ||
        die 'post-handoff maintenance reactivation authority is invalid'
    nonce=$(cat "$(maintenance_nonce_path)")
    valid_sha256_hex "$nonce" || die 'maintenance nonce is invalid'
    temporary=$(mktemp "$STATE_DIR/.v3014-maintenance.XXXXXX")
    jq -n --arg nonce "$nonce" --arg run "$RUN_DIR" \
        '{schema:1,transaction:"v30.1.4-fleet-rollout",state:"active",
          run_nonce:$nonce,run_dir:$run}' > "$temporary"
    chmod 600 "$temporary"
    chown root:root "$temporary"
    sync -f "$temporary"
    mv -fT -- "$temporary" "$ROLLOUT_MAINTENANCE_MARKER"
    sync -f "$STATE_DIR"
    verify_maintenance_marker || die 'maintenance marker failed post-commit verification'
    verify_canary_fleet_handoff 0 ||
        die 'post-handoff maintenance reactivation did not bind to the atomic handoff record'
}

release_maintenance_marker()
{
    verify_maintenance_marker || return 1
    rm -f -- "$ROLLOUT_MAINTENANCE_MARKER" || return 1
    [[ ! -e "$ROLLOUT_MAINTENANCE_MARKER" && ! -L "$ROLLOUT_MAINTENANCE_MARKER" ]] || return 1
    sync -f "$STATE_DIR"
}

finalization_state_path()
{
    printf '%s/FINALIZATION-STATE\n' "$RUN_DIR"
}

maintenance_released_epoch_path()
{
    printf '%s/MAINTENANCE-RELEASED-EPOCH\n' "$RUN_DIR"
}

valid_maintenance_released_epoch()
{
    local path epoch now
    path=$(maintenance_released_epoch_path) || return 1
    [[ -f "$path" && ! -L "$path" && "$(realpath -e -- "$path")" == "$path" &&
       "$(stat -c '%u:%g:%a' "$path")" == 0:0:600 && "$(wc -l < "$path")" -eq 1 ]] ||
        return 1
    epoch=$(<"$path")
    [[ "$epoch" =~ ^[1-9][0-9]{8,10}$ ]] || return 1
    now=$(date +%s) || return 1
    ((10#$epoch <= now))
}

publish_maintenance_released_epoch()
{
    publish_state_token "$(maintenance_released_epoch_path)" "$(date +%s)" || return 1
    valid_maintenance_released_epoch
}

invalidate_maintenance_released_epoch()
{
    local path
    path=$(maintenance_released_epoch_path) || return 1
    if [[ -e "$path" || -L "$path" ]]; then
        [[ -f "$path" && ! -L "$path" && "$(realpath -e -- "$path")" == "$path" &&
           "$(stat -c '%u:%g:%a' "$path")" == 0:0:600 ]] || return 1
        rm -f -- "$path" || return 1
        sync -f "$RUN_DIR" || return 1
    fi
    [[ ! -e "$path" && ! -L "$path" ]]
}

acquire_finalization_guard_locks()
{
    [[ "$FINALIZATION_LOCKS_HELD" -eq 0 ]] || return 1
    [[ ! -L /run/blackcoin-endpoint-guard.lock &&
       ! -L /var/run/blackcoin-node-cutover.lock &&
       ! -L /run/blackcoin-pow-quarantine-cycle.lock &&
       ! -L /var/run/blackcoin-wallet-runtime-guard.lock &&
       ! -L /var/run/blackcoin-free-claim-pause-transition.lock &&
       ! -L /var/run/blackcoin-free-claim-pool.lock ]] || return 1
    exec 20>/run/blackcoin-endpoint-guard.lock
    flock -w 1800 20 || { exec 20>&-; return 1; }
    exec 22>/var/run/blackcoin-node-cutover.lock
    if ! flock -w 1800 22; then
        exec 22>&-
        flock -u 20 2>/dev/null || true
        exec 20>&-
        return 1
    fi
    exec 23>/run/blackcoin-pow-quarantine-cycle.lock
    if ! flock -w 1800 23; then
        exec 23>&-
        flock -u 22 2>/dev/null || true
        exec 22>&-
        flock -u 20 2>/dev/null || true
        exec 20>&-
        return 1
    fi
    exec 21>/var/run/blackcoin-wallet-runtime-guard.lock
    if ! flock -w 1800 21; then
        exec 21>&-
        flock -u 23 2>/dev/null || true
        exec 23>&-
        flock -u 22 2>/dev/null || true
        exec 22>&-
        flock -u 20 2>/dev/null || true
        exec 20>&-
        return 1
    fi
    exec 24>/var/run/blackcoin-free-claim-pause-transition.lock
    if ! flock -w 1800 24; then
        exec 24>&-
        flock -u 21 2>/dev/null || true
        exec 21>&-
        flock -u 23 2>/dev/null || true
        exec 23>&-
        flock -u 22 2>/dev/null || true
        exec 22>&-
        flock -u 20 2>/dev/null || true
        exec 20>&-
        return 1
    fi
    exec 25>/var/run/blackcoin-free-claim-pool.lock
    if ! flock -w 1800 25; then
        exec 25>&-
        flock -u 24 2>/dev/null || true
        exec 24>&-
        flock -u 21 2>/dev/null || true
        exec 21>&-
        flock -u 23 2>/dev/null || true
        exec 23>&-
        flock -u 22 2>/dev/null || true
        exec 22>&-
        flock -u 20 2>/dev/null || true
        exec 20>&-
        return 1
    fi
    FINALIZATION_LOCKS_HELD=1
}

release_finalization_guard_locks()
{
    flock -u 25 2>/dev/null || true
    exec 25>&- 2>/dev/null || true
    flock -u 24 2>/dev/null || true
    exec 24>&- 2>/dev/null || true
    flock -u 21 2>/dev/null || true
    exec 21>&- 2>/dev/null || true
    flock -u 23 2>/dev/null || true
    exec 23>&- 2>/dev/null || true
    flock -u 22 2>/dev/null || true
    exec 22>&- 2>/dev/null || true
    flock -u 20 2>/dev/null || true
    exec 20>&- 2>/dev/null || true
    FINALIZATION_LOCKS_HELD=0
}

activate_free_claim_pause_safely()
{
    local temporary owner mode
    [[ "$FINALIZATION_LOCKS_HELD" -eq 1 ]] || return 1
    [[ -d "$FREE_CLAIM_ROOT" && ! -L "$FREE_CLAIM_ROOT" &&
       "$(realpath -e -- "$FREE_CLAIM_ROOT")" == "$FREE_CLAIM_ROOT" ]] || return 1
    owner=$(stat -c '%u:%g' "$FREE_CLAIM_ROOT") || return 1
    mode=$(stat -c '%a' "$FREE_CLAIM_ROOT") || return 1
    [[ "$owner" == 0:0 && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 0022) == 0 )) || return 1
    if [[ -e "$FREE_CLAIM_PAUSE_MARKER" || -L "$FREE_CLAIM_PAUSE_MARKER" ]]; then
        verify_free_claim_pause
        return
    fi
    temporary=$(mktemp "$FREE_CLAIM_ROOT/.v30.1.4-free-claim-paused.contain.XXXXXX") || return 1
    if ! printf '%s\n' "$FREE_CLAIM_PAUSE_CONTENT" > "$temporary" ||
       ! chmod 600 "$temporary" || ! chown root:root "$temporary" || ! sync -f "$temporary"; then
        rm -f -- "$temporary"
        return 1
    fi
    if ! mv -T -- "$temporary" "$FREE_CLAIM_PAUSE_MARKER" || ! sync -f "$FREE_CLAIM_ROOT"; then
        rm -f -- "$temporary"
        return 1
    fi
    verify_free_claim_pause
}

activate_maintenance_marker_safely()
{
    local nonce temporary
    if [[ -e "$ROLLOUT_MAINTENANCE_MARKER" || -L "$ROLLOUT_MAINTENANCE_MARKER" ]]; then
        verify_maintenance_marker
        return
    fi
    nonce=$(cat "$(maintenance_nonce_path)" 2>/dev/null) || return 1
    valid_sha256_hex "$nonce" || return 1
    temporary=$(mktemp "$STATE_DIR/.v3014-maintenance.XXXXXX") || return 1
    if ! jq -n --arg nonce "$nonce" --arg run "$RUN_DIR" \
        '{schema:1,transaction:"v30.1.4-fleet-rollout",state:"active",
          run_nonce:$nonce,run_dir:$run}' > "$temporary" ||
       ! chmod 600 "$temporary" || ! chown root:root "$temporary" || ! sync -f "$temporary"; then
        rm -f -- "$temporary"
        return 1
    fi
    if ! mv -fT -- "$temporary" "$ROLLOUT_MAINTENANCE_MARKER" || ! sync -f "$STATE_DIR"; then
        rm -f -- "$temporary"
        return 1
    fi
    verify_maintenance_marker
}

release_maintenance_for_finalization()
{
    local rc=0 marker_was_active=0 release_epoch release_state
    acquire_finalization_guard_locks || return 1
    verify_free_claim_pause || rc=1
    if ((rc == 0)) && [[ -e "$ROLLOUT_MAINTENANCE_MARKER" || -L "$ROLLOUT_MAINTENANCE_MARKER" ]]; then
        if verify_maintenance_marker; then
            marker_was_active=1
            invalidate_maintenance_released_epoch || rc=1
            ((rc != 0)) || publish_state_token "$(finalization_state_path)" \
                maintenance-release-authorized || rc=1
        fi
        if ((rc == 0 && marker_was_active == 1)); then
            release_maintenance_marker || rc=1
        elif ((marker_was_active == 0)); then
            rc=1
        fi
    elif ((rc == 0)) && ! valid_maintenance_released_epoch; then
        # A crash may occur after the marker removal but before publishing its
        # epoch. Only the durable pre-removal authority can resume that prefix;
        # a merely missing marker is never treated as an intentional release.
        [[ -f "$(finalization_state_path)" && ! -L "$(finalization_state_path)" &&
           "$(stat -c '%u:%g:%a' "$(finalization_state_path)")" == 0:0:600 &&
           "$(<"$(finalization_state_path)")" == maintenance-release-authorized ]] || rc=1
        ((rc != 0)) || marker_was_active=1
    elif ((rc == 0)); then
        release_epoch=$(<"$(maintenance_released_epoch_path)") || rc=1
        [[ "$release_epoch" =~ ^[1-9][0-9]{8,10}$ ]] || rc=1
        ((rc != 0)) || data_rollback_protected_file "$(finalization_state_path)" 600 || rc=1
        if ((rc == 0)); then
            release_state=$(<"$(finalization_state_path)") || rc=1
            case "$release_state" in
                maintenance-release-authorized|maintenance-released|pre-release-passed|\
                free-claim-released|post-release-passed|finalized) ;;
                *) rc=1 ;;
            esac
        fi
    fi
    if ((rc == 0 && marker_was_active == 1)); then
        publish_maintenance_released_epoch || rc=1
    elif ((rc == 0)); then
        valid_maintenance_released_epoch || rc=1
    fi
    if ((rc == 0)); then
        publish_state_token "$(finalization_state_path)" maintenance-released || rc=1
    fi
    release_finalization_guard_locks
    return "$rc"
}

verify_released_finalization_resume_state()
{
    local state finalization inhibitor epoch_path receipt_dir
    [[ -n "$RUN_DIR" && -n "$ROLLOUT_MAINTENANCE_MARKER" &&
       ! -e "$ROLLOUT_MAINTENANCE_MARKER" && ! -L "$ROLLOUT_MAINTENANCE_MARKER" ]] ||
        return 1
    data_rollback_protected_file "$RUN_DIR/STATE" 600 || return 1
    state=$(<"$RUN_DIR/STATE")
    [[ "$state" == complete ]] || return 1
    data_rollback_protected_file "$(finalization_state_path)" 600 || return 1
    finalization=$(<"$(finalization_state_path)")
    verify_canary_fleet_handoff 0 || return 1
    inhibitor=$(/bin/bash "$INHIBITOR_RELEASER" probe) || return 1
    epoch_path=$(maintenance_released_epoch_path) || return 1
    case "$finalization" in
        maintenance-release-authorized)
            [[ "$inhibitor" == \
               'state=installed-and-paused cycle=v30.1.4-no-spend free_claim=paused' ]] ||
                return 1
            verify_free_claim_pause || return 1
            if [[ -e "$epoch_path" || -L "$epoch_path" ]]; then
                valid_maintenance_released_epoch || return 1
            fi
            ;;
        maintenance-released|pre-release-passed)
            valid_maintenance_released_epoch || return 1
            case "$inhibitor" in
                'state=installed-and-paused cycle=v30.1.4-no-spend free_claim=paused')
                    verify_free_claim_pause || return 1
                    ;;
                'state=installed-and-released cycle=v30.1.4-no-spend free_claim=enabled')
                    data_rollback_finalization_released || return 1
                    ;;
                *) return 1 ;;
            esac
            ;;
        free-claim-released|post-release-passed)
            valid_maintenance_released_epoch || return 1
            data_rollback_finalization_released || return 1
            ;;
        finalized)
            valid_maintenance_released_epoch || return 1
            receipt_dir=$(terminal_receipt_dir) || return 1
            if [[ -e "$receipt_dir" || -L "$receipt_dir" ]]; then
                verify_terminal_receipt complete 0 || return 1
            else
                verify_snapshot_cleanup_resume_prefix || return 1
                verify_terminal_cleanup_prerequisites complete || return 1
                data_rollback_finalization_released || return 1
            fi
            ;;
        *) return 1 ;;
    esac
}

ensure_finalization_containment()
{
    local rc=0 inhibitor_state
    if acquire_finalization_guard_locks; then
        # Recontainment is a new transaction boundary. Publish its authority and
        # revoke every prior release epoch before changing either live inhibitor;
        # a crash in any later prefix can then resume only toward containment.
        publish_state_token "$(finalization_state_path)" containment-authorized || rc=1
        ((rc != 0)) || invalidate_maintenance_released_epoch || rc=1
        inhibitor_state=$(/bin/bash "$INHIBITOR_RELEASER" probe 2>/dev/null || true)
        if ((rc == 0)); then
            case "$inhibitor_state" in
                'state=installed-and-paused cycle=v30.1.4-no-spend free_claim=paused') ;;
                'state=installed-and-released cycle=v30.1.4-no-spend free_claim=enabled')
                    activate_free_claim_pause_safely || rc=1
                    ;;
                *) rc=1 ;;
            esac
        fi
        ((rc != 0)) || verify_free_claim_pause || rc=1
        ((rc != 0)) || activate_maintenance_marker_safely || rc=1
        if ((rc == 0)); then
            publish_state_token "$(finalization_state_path)" contained || rc=1
        fi
        ((rc != 0)) || verify_free_claim_pause || rc=1
        ((rc != 0)) || verify_maintenance_marker || rc=1
        release_finalization_guard_locks
    else
        rc=1
    fi
    inhibitor_state=$(/bin/bash "$INHIBITOR_RELEASER" probe 2>/dev/null || true)
    [[ "$inhibitor_state" == \
       'state=installed-and-paused cycle=v30.1.4-no-spend free_claim=paused' ]] || rc=1
    [[ ! -e "$(maintenance_released_epoch_path)" &&
       ! -L "$(maintenance_released_epoch_path)" ]] || rc=1
    data_rollback_protected_file "$(finalization_state_path)" 600 || rc=1
    [[ "$(<"$(finalization_state_path)")" == contained ]] || rc=1
    verify_maintenance_marker || rc=1
    ((rc == 0))
}

recover_interrupted_finalization_containment_before_preflight()
{
    local run_state finalization state_path
    [[ -n "$RUN_DIR" ]] || return 0
    state_path=$(finalization_state_path) || return 1
    if [[ ! -e "$state_path" && ! -L "$state_path" ]]; then
        return 0
    fi
    data_rollback_protected_file "$state_path" 600 || return 1
    finalization=$(<"$state_path") || return 1
    [[ "$finalization" == containment-authorized ]] || return 0

    require_host_tools
    [[ "$(id -u)" -eq 0 ]] || return 1
    valid_rollout_run_dir "$RUN_DIR" || return 1
    data_rollback_protected_file "$RUN_DIR/STATE" 600 || return 1
    run_state=$(<"$RUN_DIR/STATE") || return 1
    [[ "$run_state" == complete || "$run_state" == rolled-back ]] || return 1
    [[ ! -e "$(terminal_receipt_dir)" && ! -L "$(terminal_receipt_dir)" ]] || return 1
    require_rollout_identity
    require_baseline_identity
    verify_transaction_manifest || return 1
    verify_canary_fleet_handoff 0 || return 1
    [[ -d "$RUN_DIR/baseline" && ! -L "$RUN_DIR/baseline" &&
       -f "$RUN_DIR/baseline/SHA256SUMS" && ! -L "$RUN_DIR/baseline/SHA256SUMS" ]] ||
        return 1
    (cd "$RUN_DIR/baseline" && sha256sum --strict -c SHA256SUMS >/dev/null) || return 1

    ensure_finalization_containment || return 1
    data_rollback_protected_file "$state_path" 600 || return 1
    [[ "$(<"$state_path")" == contained &&
       ! -e "$(maintenance_released_epoch_path)" &&
       ! -L "$(maintenance_released_epoch_path)" ]] || return 1
    verify_maintenance_marker || return 1
    verify_free_claim_pause
}

terminal_receipt_dir()
{
    printf '%s/terminal-finalization\n' "$RUN_DIR"
}

terminal_receipt_path()
{
    printf '%s/terminal-finalization/RESULT.json\n' "$RUN_DIR"
}

terminal_receipt_sha_path()
{
    printf '%s/terminal-finalization/SHA256SUMS\n' "$RUN_DIR"
}

validate_preserved_hour_paths()
{
    local audit="$1" manifest="$2" directories="$3" invalid result_count rel extra
    local target ancestor
    [[ -d "$audit" && ! -L "$audit" && "$(realpath -e -- "$audit")" == "$audit" ]] || return 1
    invalid=$(awk '
        NF != 2 || $1 !~ /^[0-9a-f]{64}$/ {print; next}
        {
          name=$2
          if (seen[name]++) {print; next}
          if (name == "../HOUR-SOAK-DIRECTORIES") {bound_directories++; next}
          if (name !~ /^[.]\/[A-Za-z0-9][A-Za-z0-9._-]*(\/[A-Za-z0-9][A-Za-z0-9._-]*)*$/ ||
              name == "./DIRECTORIES") print
        }
        END {if (bound_directories != 1) print "invalid-directory-binding"}
    ' "$manifest") || return 1
    [[ -z "$invalid" ]] || return 1
    invalid=$(awk '
        $0 !~ /^[.]\/[A-Za-z0-9][A-Za-z0-9._-]*(\/[A-Za-z0-9][A-Za-z0-9._-]*)*$/ {print}
    ' "$directories") || return 1
    [[ -z "$invalid" ]] || return 1
    cmp -s "$directories" <(sort -u "$directories") || return 1
    while IFS= read -r rel; do
        rel=${rel#./}
        target="$audit/$rel"
        [[ -d "$target" && ! -L "$target" && "$(realpath -e -- "$target")" == "$target" ]] ||
            return 1
    done < "$directories"
    while read -r _ rel extra; do
        [[ -z "$extra" ]] || return 1
        [[ "$rel" == "../HOUR-SOAK-DIRECTORIES" ]] && continue
        rel=${rel#./}
        target="$audit/$rel"
        [[ -f "$target" && ! -L "$target" && "$(realpath -e -- "$target")" == "$target" ]] ||
            return 1
        ancestor=${rel%/*}
        while [[ "$ancestor" != "$rel" ]]; do
            grep -Fxq -- "./$ancestor" "$directories" || return 1
            [[ "$ancestor" == */* ]] || break
            ancestor=${ancestor%/*}
        done
    done < "$manifest"
    result_count=$(awk '$2 == "./RESULT.json" {count++} END {print count+0}' "$manifest") ||
        return 1
    [[ "$result_count" -eq 1 ]]
}

verify_success_post_release_evidence()
{
    local audit="$RUN_DIR/exact-32-soak" post="$RUN_DIR/exact-32-soak/POST-RELEASE.json"
    local transaction="$RUN_DIR/TRANSACTION.json" nonce_file="$RUN_DIR/MAINTENANCE-NONCE"
    local hour_manifest="$RUN_DIR/HOUR-SOAK-SHA256SUMS"
    local hour_directories="$RUN_DIR/HOUR-SOAK-DIRECTORIES" path
    local release_receipt="$RUN_DIR/FREE-CLAIM-RELEASED.json"
    local release_sidecar="$RUN_DIR/FREE-CLAIM-RELEASED.sha256"
    local identity_rel supervisor_rel generation_expected_rel generation_final_rel attempt_rel
    local identity supervisor generation_expected generation_final transaction_sha nonce
    local hour_manifest_sha hour_result_sha identity_sha supervisor_sha expected_sha final_sha
    local supervisor_timestamp supervisor_epoch released_epoch release_receipt_sha expected_release_sha
    local free_claim_released_epoch now_epoch
    [[ -d "$audit" && ! -L "$audit" && "$(realpath -e -- "$audit")" == "$audit" &&
       "$(stat -c '%u:%g:%a' "$audit")" == 0:0:700 &&
       -z "$(find "$audit" -type l -print -quit)" &&
       -z "$(find "$audit" ! -type d ! -type f -print -quit)" ]] || return 1
    while IFS= read -r -d '' path; do
        [[ "$(stat -c '%u:%g:%a' "$path")" == 0:0:700 ]] || return 1
    done < <(find "$audit" -mindepth 1 -type d -print0)
    while IFS= read -r -d '' path; do
        [[ "$(stat -c '%u:%g:%a' "$path")" == 0:0:600 ]] || return 1
    done < <(find "$audit" -type f -print0)
    for path in "$audit/DIRECTORIES" "$audit/SHA256SUMS" "$audit/RESULT.json" "$post" \
        "$transaction" "$nonce_file" "$hour_manifest" "$hour_directories" \
        "$release_receipt" "$release_sidecar"; do
        [[ -f "$path" && ! -L "$path" && "$(realpath -e -- "$path")" == "$path" &&
           "$(stat -c '%u:%g:%a' "$path")" == 0:0:600 ]] || return 1
    done
    [[ -f "$RUN_DIR/MAINTENANCE-RELEASED-EPOCH" &&
       ! -L "$RUN_DIR/MAINTENANCE-RELEASED-EPOCH" &&
       "$(realpath -e -- "$RUN_DIR/MAINTENANCE-RELEASED-EPOCH")" == \
          "$RUN_DIR/MAINTENANCE-RELEASED-EPOCH" &&
       "$(stat -c '%u:%g:%a' "$RUN_DIR/MAINTENANCE-RELEASED-EPOCH")" == 0:0:600 ]] || return 1
    cmp -s <(cd "$audit" && find . -mindepth 1 -type d -print | sort) \
        <(sort "$audit/DIRECTORIES") || return 1
    cmp -s "$audit/DIRECTORIES" <(sort -u "$audit/DIRECTORIES") || return 1
    cmp -s <(cd "$audit" && find . -type f ! -path './SHA256SUMS' -print | sort) \
        <(awk 'NF == 2 && $1 ~ /^[0-9a-f]{64}$/ {print $2}' "$audit/SHA256SUMS" | sort) ||
        return 1
    (cd "$audit" && sha256sum --strict -c SHA256SUMS >/dev/null) || return 1
    validate_preserved_hour_paths "$audit" "$hour_manifest" "$hour_directories" || return 1
    (cd "$audit" && sha256sum --strict -c "$hour_manifest" >/dev/null) || return 1
    transaction_sha=$(sha256sum "$transaction" | awk '{print $1}') || return 1
    nonce=$(<"$nonce_file")
    valid_sha256_hex "$nonce" || return 1
    [[ "$(wc -l < "$nonce_file")" -eq 1 ]] || return 1
    jq -e --arg nonce "$nonce" '.maintenance.run_nonce == $nonce' "$transaction" >/dev/null || return 1
    hour_manifest_sha=$(sha256sum "$hour_manifest" | awk '{print $1}') || return 1
    hour_result_sha=$(sha256sum "$audit/RESULT.json" | awk '{print $1}') || return 1
    release_receipt_sha=$(sha256sum "$release_receipt" | awk '{print $1}') || return 1
    expected_release_sha=$(awk 'NF == 1 && $1 ~ /^[0-9a-f]{64}$/ {print $1}' \
        "$release_sidecar") || return 1
    [[ -n "$expected_release_sha" && "$(wc -l < "$release_sidecar")" -eq 1 &&
       "$release_receipt_sha" == "$expected_release_sha" ]] || return 1
    free_claim_released_epoch=$(jq -er '.released_at_epoch | select(type == "number")' \
        "$release_receipt") || return 1
    now_epoch=$(date +%s) || return 1
    [[ "$free_claim_released_epoch" =~ ^[1-9][0-9]*$ &&
       "$free_claim_released_epoch" -le "$now_epoch" ]] || return 1
    identity_rel=$(jq -er '.fleet_identity_evidence' "$post") || return 1
    supervisor_rel=$(jq -er '.supervisor_evidence' "$post") || return 1
    generation_expected_rel=$(jq -er '.generation_expected_evidence' "$post") || return 1
    generation_final_rel=$(jq -er '.generation_before_publication_evidence' "$post") || return 1
    [[ "$identity_rel" =~ ^finalization-post-release-attempt-[0-9]{3,}/FLEET-IDENTITY[.]json$ &&
       "$supervisor_rel" =~ ^finalization-post-release-attempt-[0-9]{3,}/SUPERVISOR-STATUS[.]json$ &&
       "$generation_expected_rel" =~ ^finalization-post-release-attempt-[0-9]{3,}/GENERATIONS[.]expected$ &&
       "$generation_final_rel" =~ ^finalization-post-release-attempt-[0-9]{3,}/GENERATIONS[.]before-publication$ ]] ||
        return 1
    attempt_rel=${identity_rel%/FLEET-IDENTITY.json}
    [[ "${supervisor_rel%/SUPERVISOR-STATUS.json}" == "$attempt_rel" &&
       "${generation_expected_rel%/GENERATIONS.expected}" == "$attempt_rel" &&
       "${generation_final_rel%/GENERATIONS.before-publication}" == "$attempt_rel" ]] || return 1
    identity="$audit/$identity_rel"
    supervisor="$audit/$supervisor_rel"
    generation_expected="$audit/$generation_expected_rel"
    generation_final="$audit/$generation_final_rel"
    identity_sha=$(sha256sum "$identity" | awk '{print $1}') || return 1
    supervisor_sha=$(sha256sum "$supervisor" | awk '{print $1}') || return 1
    expected_sha=$(sha256sum "$generation_expected" | awk '{print $1}') || return 1
    final_sha=$(sha256sum "$generation_final" | awk '{print $1}') || return 1
    [[ "$expected_sha" == "$final_sha" ]] && cmp -s "$generation_expected" "$generation_final" ||
        return 1
    supervisor_timestamp=$(jq -er '.timestamp | select(type == "string")' "$supervisor") || return 1
    supervisor_epoch=$(date -d "$supervisor_timestamp" +%s 2>/dev/null) || return 1
    released_epoch=$(<"$RUN_DIR/MAINTENANCE-RELEASED-EPOCH")
    [[ "$(wc -l < "$RUN_DIR/MAINTENANCE-RELEASED-EPOCH")" -eq 1 &&
       "$supervisor_epoch" =~ ^[1-9][0-9]*$ && "$released_epoch" =~ ^[1-9][0-9]*$ ]] || return 1
    ((free_claim_released_epoch > 10#$released_epoch &&
      supervisor_epoch > free_claim_released_epoch)) || return 1
    jq -e --arg timestamp "$supervisor_timestamp" '
        .timestamp == $timestamp and .state == "healthy" and .verified == 32 and
        .running == 32 and .operational == 32 and .failures == 0
    ' "$supervisor" >/dev/null || return 1
    jq -e --slurpfile transaction "$transaction" \
        -f "$PACKAGE_ROOT/lib/hour_soak_result.jq" "$audit/RESULT.json" >/dev/null || return 1
    jq -e --arg run "$RUN_DIR" --arg transaction_sha "$transaction_sha" --arg nonce "$nonce" \
        --arg image "$CANDIDATE_IMAGE_REF" --arg image_id "$CANDIDATE_IMAGE_ID" \
        --arg source "$SOURCE_COMMIT" --arg hour_result_sha "$hour_result_sha" \
        --arg hour_manifest_sha "$hour_manifest_sha" --arg identity_rel "$identity_rel" \
        --arg identity_sha "$identity_sha" --arg supervisor_rel "$supervisor_rel" \
        --arg supervisor_sha "$supervisor_sha" --arg supervisor_timestamp "$supervisor_timestamp" \
        --arg generation_expected_rel "$generation_expected_rel" --arg expected_sha "$expected_sha" \
        --arg generation_final_rel "$generation_final_rel" --arg final_sha "$final_sha" \
        --arg release_receipt_sha "$release_receipt_sha" \
        --argjson free_claim_released_epoch "$free_claim_released_epoch" \
        --argjson supervisor_epoch "$supervisor_epoch" --argjson released_epoch "$((10#$released_epoch))" \
        --slurpfile transaction "$transaction" --slurpfile hour "$audit/RESULT.json" \
        --slurpfile identity "$identity" '
        ($transaction | length) == 1 and ($hour | length) == 1 and ($identity | length) == 1 and
        ($identity[0].schema == 1) and ($identity[0].nodes | length) == 32 and
        [$identity[0].nodes[].node] == [range(1;33)] and
        all($identity[0].nodes[]; .config_image == $image and .image_id == $image_id) and
        .schema == 1 and .result == "passed" and .phase == "post-release" and
        .run_dir == $run and .transaction_manifest_sha256 == $transaction_sha and
        .run_nonce == $nonce and $transaction[0].maintenance.run_nonce == $nonce and
        .image == $image and .image_id == $image_id and .source_commit == $source and
        .prior_hour_soak_result_sha256 == $hour_result_sha and
        .prior_authenticated_manifest_path == "../HOUR-SOAK-SHA256SUMS" and
        .prior_authenticated_manifest_sha256 == $hour_manifest_sha and
        .maintenance_marker_absent == true and .maintenance_released_epoch == $released_epoch and
        .free_claim_broadcasts_paused == false and .free_claim_service_healthy == true and
        .free_claim_release_receipt_path == "../FREE-CLAIM-RELEASED.json" and
        .free_claim_release_receipt_sha256 == $release_receipt_sha and
        .free_claim_released_at_epoch == $free_claim_released_epoch and
        .supervisor_timestamp_epoch > $free_claim_released_epoch and
        .stale_broadcast_gate_passed == true and
        .supervisor_evidence == $supervisor_rel and .supervisor_status_sha256 == $supervisor_sha and
        .supervisor_timestamp == $supervisor_timestamp and
        .supervisor_timestamp_epoch == $supervisor_epoch and
        .fleet_identity_evidence == $identity_rel and .fleet_identity_evidence_sha256 == $identity_sha and
        .generation_expected_evidence == $generation_expected_rel and
        .generation_expected_sha256 == $expected_sha and
        .generation_before_publication_evidence == $generation_final_rel and
        .generation_before_publication_sha256 == $final_sha and
        .compose_sha256 == $identity[0].compose_sha256 and
        .image_policy_sha256 == $identity[0].image_policy_sha256 and
        .endpoint_guard_sha256 == $identity[0].endpoint_guard_sha256 and
        .wallet_runtime_guard_sha256 == $identity[0].wallet_runtime_guard_sha256 and
        .nodes_healthy == 32 and .pos_active == 32 and .regular_pow_active == 31 and
        .free_claim_node == 30 and .free_claim_regular_pow == false and
        .final_concurrent_dynamic_gate == true and .final_exact_32_generation_fence == true and
        .global_chain_convergence == true and .vpn_proofs_valid_unique == 32 and
        .final_policy_assets_valid == true and .live_compose_container_policy_match == true and
        .identity_recovery_baselines_unchanged == true and
        .claim_recovery_fee_unchanged == true and .fee_payments_authorized == false and
        .claim_recovery_baseline_sha256s == $hour[0].claim_recovery_baseline_sha256s and
        .claim_recovery_baseline_set_sha256 == $hour[0].claim_recovery_baseline_set_sha256
    ' "$post" >/dev/null
}

capture_terminal_generation_fence()
{
    local outcome="$1" source relative expected output
    case "$outcome" in
        complete)
            source="$RUN_DIR/exact-32-soak/POST-RELEASE.json"
            relative=$(jq -er '.generation_before_publication_evidence' "$source") || return 1
            [[ "$relative" =~ ^finalization-post-release-attempt-[0-9]{3,}/GENERATIONS[.]before-publication$ ]] ||
                return 1
            expected="$RUN_DIR/exact-32-soak/$relative"
            output="$RUN_DIR/final-generations.post-release"
            ;;
        rolled-back)
            source="$RUN_DIR/ROLLBACK-FINALIZATION-READY.json"
            relative=$(jq -er '.generation_before_publication_evidence' "$source") || return 1
            [[ "$relative" =~ ^rollback-finalization-attempt-[0-9]{3,}/GENERATIONS[.]before-publication$ ]] ||
                return 1
            expected="$RUN_DIR/$relative"
            output="$RUN_DIR/rollback-final-generations.post-release"
            ;;
        *) return 1 ;;
    esac
    [[ -f "$expected" && ! -L "$expected" && "$(realpath -e -- "$expected")" == "$expected" &&
       "$(stat -c '%u:%g:%a' "$expected")" == 0:0:600 ]] || return 1
    capture_exact_32_generation_map "$output" || return 1
    cmp -s "$expected" "$output"
}

verify_terminal_receipt()
{
    local expected_outcome="$1" verify_live="${2:-1}" receipt_dir_override="${3:-}"
    local receipt receipt_sha_path expected_receipt_sha actual_receipt_sha
    local state finalization_state result ready terminal_result fleet_identity free_claim_identity path
    local cleanup transaction release_receipt release_sidecar transaction_sha release_sha ready_sha result_sha
    local release_result_sha expected_release_sha nonce released_at maintenance_epoch supervisor_epoch now_epoch
    local fleet_identity_sha free_claim_identity_sha cleanup_sha completed receipt_dir
    local evidence_manifest evidence_manifest_path evidence_manifest_sha directories_path directories_sha
    local hour_manifest_path hour_manifest_sha hour_directories_path hour_directories_sha
    local generation_expected_rel generation_expected generation_final generation_expected_sha generation_final_sha
    local regular_pow_active legacy_quarantined_disabled
    [[ "$verify_live" == 0 || "$verify_live" == 1 ]] || return 1
    if [[ -n "$receipt_dir_override" ]]; then
        [[ "$verify_live" == 0 &&
           "$receipt_dir_override" == "$RUN_DIR"/.terminal-finalization.* ]] || return 1
        receipt_dir="$receipt_dir_override"
        receipt="$receipt_dir/RESULT.json"
        receipt_sha_path="$receipt_dir/SHA256SUMS"
    else
        receipt_dir=$(terminal_receipt_dir) || return 1
        receipt=$(terminal_receipt_path) || return 1
        receipt_sha_path=$(terminal_receipt_sha_path) || return 1
    fi
    [[ -d "$receipt_dir" && ! -L "$receipt_dir" && "$(realpath -e -- "$receipt_dir")" == "$receipt_dir" &&
       "$(stat -c '%u:%g:%a' "$receipt_dir")" == 0:0:700 &&
       "$(find "$receipt_dir" -mindepth 1 -maxdepth 1 -type f | wc -l)" -eq 2 &&
       -z "$(find "$receipt_dir" -mindepth 1 ! -type f -print -quit)" &&
       -f "$receipt" && ! -L "$receipt" && "$(realpath -e -- "$receipt")" == "$receipt" &&
       "$(stat -c '%u:%g:%a' "$receipt")" == 0:0:600 &&
       -f "$receipt_sha_path" && ! -L "$receipt_sha_path" &&
       "$(realpath -e -- "$receipt_sha_path")" == "$receipt_sha_path" &&
       "$(stat -c '%u:%g:%a' "$receipt_sha_path")" == 0:0:600 ]] || return 1
    expected_receipt_sha=$(awk 'NF == 2 && $1 ~ /^[0-9a-f]{64}$/ && $2 == "./RESULT.json" {print $1}' \
        "$receipt_sha_path") || return 1
    actual_receipt_sha=$(sha256sum "$receipt" | awk '{print $1}') || return 1
    [[ -n "$expected_receipt_sha" && "$(wc -l < "$receipt_sha_path")" -eq 1 &&
       "$actual_receipt_sha" == "$expected_receipt_sha" ]] || return 1
    (cd "$receipt_dir" && sha256sum --strict -c SHA256SUMS >/dev/null) || return 1
    [[ -f "$RUN_DIR/STATE" && ! -L "$RUN_DIR/STATE" &&
       "$(stat -c '%u:%g:%a' "$RUN_DIR/STATE")" == 0:0:600 &&
       -f "$(finalization_state_path)" && ! -L "$(finalization_state_path)" &&
       "$(stat -c '%u:%g:%a' "$(finalization_state_path)")" == 0:0:600 ]] || return 1
    state=$(<"$RUN_DIR/STATE")
    finalization_state=$(<"$(finalization_state_path)")
    [[ "$state" == "$expected_outcome" && "$finalization_state" == finalized ]] || return 1
    case "$expected_outcome" in
        complete)
            result="$RUN_DIR/exact-32-soak/RESULT.json"
            ready="$RUN_DIR/exact-32-soak/FINALIZATION-READY.json"
            terminal_result="$RUN_DIR/exact-32-soak/POST-RELEASE.json"
            fleet_identity="$RUN_DIR/final-fleet-identity.post-release.json"
            free_claim_identity="$RUN_DIR/final-free-claim-container-identity.post-release.json"
            evidence_manifest_path="$RUN_DIR/exact-32-soak/SHA256SUMS"
            directories_path="$RUN_DIR/exact-32-soak/DIRECTORIES"
            hour_manifest_path="$RUN_DIR/HOUR-SOAK-SHA256SUMS"
            hour_directories_path="$RUN_DIR/HOUR-SOAK-DIRECTORIES"
            verify_success_post_release_evidence || return 1
            for path in "$evidence_manifest_path" "$directories_path" \
                "$hour_manifest_path" "$hour_directories_path"; do
                [[ -f "$path" && ! -L "$path" && "$(realpath -e -- "$path")" == "$path" &&
                   "$(stat -c '%u:%g:%a' "$path")" == 0:0:600 ]] || return 1
            done
            (cd "$RUN_DIR/exact-32-soak" && sha256sum --strict -c SHA256SUMS >/dev/null) || return 1
            (cd "$RUN_DIR/exact-32-soak" && \
                sha256sum --strict -c "$hour_manifest_path" >/dev/null) || return 1
            evidence_manifest_sha=$(sha256sum "$evidence_manifest_path" | awk '{print $1}') || return 1
            directories_sha=$(sha256sum "$directories_path" | awk '{print $1}') || return 1
            hour_manifest_sha=$(sha256sum "$hour_manifest_path" | awk '{print $1}') || return 1
            hour_directories_sha=$(sha256sum "$hour_directories_path" | awk '{print $1}') || return 1
            evidence_manifest=$(jq -cn --arg path "${evidence_manifest_path#"$RUN_DIR/"}" \
                --arg sha "$evidence_manifest_sha" --arg directories "${directories_path#"$RUN_DIR/"}" \
                --arg directories_sha "$directories_sha" \
                --arg hour_manifest "${hour_manifest_path#"$RUN_DIR/"}" \
                --arg hour_manifest_sha "$hour_manifest_sha" \
                --arg hour_directories "${hour_directories_path#"$RUN_DIR/"}" \
                --arg hour_directories_sha "$hour_directories_sha" \
                '{path:$path,sha256:$sha,directories_path:$directories,directories_sha256:$directories_sha,
                  hour_manifest_path:$hour_manifest,hour_manifest_sha256:$hour_manifest_sha,
                  hour_directories_path:$hour_directories,hour_directories_sha256:$hour_directories_sha}') ||
                return 1
            generation_expected_rel=$(jq -er '.generation_before_publication_evidence' \
                "$terminal_result") || return 1
            [[ "$generation_expected_rel" =~ ^finalization-post-release-attempt-[0-9]{3,}/GENERATIONS[.]before-publication$ ]] ||
                return 1
            generation_expected="$RUN_DIR/exact-32-soak/$generation_expected_rel"
            generation_final="$RUN_DIR/final-generations.post-release"
            regular_pow_active=31
            legacy_quarantined_disabled=0
            ;;
        rolled-back)
            result="$RUN_DIR/ROLLBACK_RESULT.json"
            ready="$RUN_DIR/ROLLBACK-FINALIZATION-READY.json"
            terminal_result="$RUN_DIR/rollback-post-release/RESULT.json"
            fleet_identity="$RUN_DIR/rollback-final-fleet-identity.post-release.json"
            free_claim_identity="$RUN_DIR/rollback-free-claim-container-identity.post-release.json"
            evidence_manifest_path="$RUN_DIR/rollback-post-release/SHA256SUMS"
            directories_path="$RUN_DIR/rollback-post-release/DIRECTORIES"
            for path in "$evidence_manifest_path" "$directories_path"; do
                [[ -f "$path" && ! -L "$path" && "$(realpath -e -- "$path")" == "$path" &&
                   "$(stat -c '%u:%g:%a' "$path")" == 0:0:600 ]] || return 1
            done
            evidence_manifest_sha=$(sha256sum "$evidence_manifest_path" | awk '{print $1}') || return 1
            directories_sha=$(sha256sum "$directories_path" | awk '{print $1}') || return 1
            evidence_manifest=$(jq -cn --arg path "${evidence_manifest_path#"$RUN_DIR/"}" \
                --arg sha "$evidence_manifest_sha" --arg directories "${directories_path#"$RUN_DIR/"}" \
                --arg directories_sha "$directories_sha" \
                '{path:$path,sha256:$sha,directories_path:$directories,directories_sha256:$directories_sha,
                  hour_manifest_path:null,hour_manifest_sha256:null,
                  hour_directories_path:null,hour_directories_sha256:null}') || return 1
            generation_expected_rel=$(jq -er '.generation_before_publication_evidence' "$ready") || return 1
            [[ "$generation_expected_rel" =~ ^rollback-finalization-attempt-[0-9]{3,}/GENERATIONS[.]before-publication$ ]] ||
                return 1
            generation_expected="$RUN_DIR/$generation_expected_rel"
            generation_final="$RUN_DIR/rollback-final-generations.post-release"
            verify_rollback_post_release_evidence || return 1
            regular_pow_active=$(jq -er '.regular_pow_active' "$ready") || return 1
            legacy_quarantined_disabled=$(jq -er '.legacy_quarantined_disabled' "$ready") || return 1
            ;;
        *) return 1 ;;
    esac
    cleanup="$RUN_DIR/snapshot-cleanup/RESULT.json"
    transaction="$RUN_DIR/TRANSACTION.json"
    release_receipt="$RUN_DIR/FREE-CLAIM-RELEASED.json"
    release_sidecar="$RUN_DIR/FREE-CLAIM-RELEASED.sha256"
    for path in "$transaction" "$release_receipt" "$ready" "$terminal_result" \
        "$release_sidecar" "$fleet_identity" "$free_claim_identity" "$cleanup" \
        "$RUN_DIR/snapshot-cleanup/RESULT.json.sha256" \
        "$generation_expected" "$generation_final"; do
        [[ -f "$path" && ! -L "$path" && "$(realpath -e -- "$path")" == "$path" &&
           "$(stat -c '%u:%g:%a' "$path")" == 0:0:600 ]] || return 1
    done
    transaction_sha=$(sha256sum "$transaction" | awk '{print $1}') || return 1
    release_sha=$(sha256sum "$release_receipt" | awk '{print $1}') || return 1
    expected_release_sha=$(awk 'NF == 1 && $1 ~ /^[0-9a-f]{64}$/ {print $1}' \
        "$release_sidecar") || return 1
    [[ -n "$expected_release_sha" && "$(wc -l < "$release_sidecar")" -eq 1 &&
       "$expected_release_sha" == "$release_sha" ]] || return 1
    ready_sha=$(sha256sum "$ready" | awk '{print $1}') || return 1
    release_result_sha=$(sha256sum "$result" | awk '{print $1}') || return 1
    result_sha=$(sha256sum "$terminal_result" | awk '{print $1}') || return 1
    fleet_identity_sha=$(sha256sum "$fleet_identity" | awk '{print $1}') || return 1
    free_claim_identity_sha=$(sha256sum "$free_claim_identity" | awk '{print $1}') || return 1
    cleanup_sha=$(sha256sum "$cleanup" | awk '{print $1}') || return 1
    generation_expected_sha=$(sha256sum "$generation_expected" | awk '{print $1}') || return 1
    generation_final_sha=$(sha256sum "$generation_final" | awk '{print $1}') || return 1
    [[ "$generation_expected_sha" == "$generation_final_sha" ]] || return 1
    cmp -s "$generation_expected" "$generation_final" || return 1
    [[ "$(<"$RUN_DIR/snapshot-cleanup/RESULT.json.sha256")" == "$cleanup_sha" ]] || return 1
    nonce=$(jq -er '.maintenance.run_nonce | select(type == "string")' "$transaction") || return 1
    valid_sha256_hex "$nonce" || return 1
    maintenance_epoch=$(jq -er '.maintenance_released_epoch | select(type == "number")' "$ready") ||
        return 1
    supervisor_epoch=$(jq -er '.supervisor_timestamp_epoch | select(type == "number")' "$ready") ||
        return 1
    released_at=$(jq -er '.released_at_epoch | select(type == "number")' "$release_receipt") ||
        return 1
    now_epoch=$(date +%s) || return 1
    ((maintenance_epoch < supervisor_epoch && supervisor_epoch <= released_at &&
      released_at <= supervisor_epoch + 300 && released_at <= now_epoch)) || return 1
    jq -e --arg run "$RUN_DIR" --arg state "$expected_outcome" \
        --arg result_sha "$release_result_sha" --arg ready "$ready" --arg ready_sha "$ready_sha" \
        --arg transaction_sha "$transaction_sha" --arg nonce "$nonce" \
        --argjson maintenance_epoch "$maintenance_epoch" \
        --argjson supervisor_epoch "$supervisor_epoch" --argjson released_at "$released_at" '
        .schema == 1 and .transaction == "v30.1.4-free-claim-release" and
        .run_dir == $run and .state == $state and .result_sha256 == $result_sha and
        .finalization_path == $ready and .finalization_sha256 == $ready_sha and
        .transaction_manifest_sha256 == $transaction_sha and .run_nonce == $nonce and
        .maintenance_released_epoch == $maintenance_epoch and
        .supervisor_timestamp_epoch == $supervisor_epoch and .released_at_epoch == $released_at and
        .supervisor_fresh_at_release == true and .maintenance_marker_absent == true and
        .free_claim_pause_absent == true and
        .receipt_published_before_pause_removal == true and
        .release_protocol == "write-ahead-v1" and
        .release_order == "maintenance-then-supervisor-then-free-claim"
    ' "$release_receipt" >/dev/null || return 1
    if [[ "$verify_live" -eq 1 ]]; then
        /bin/bash "$INHIBITOR_RELEASER" verify-release \
            "$result" "$RUN_DIR/STATE" "$ready" >/dev/null || return 1
    fi
    jq -e --arg run "$RUN_DIR" '
        .schema == 1 and .transaction == "v30.1.4-snapshot-cleanup" and
        .run_dir == $run and .result == "passed" and .cleanup_complete == true and
        .unrelated_snapshots_destroyed == 0 and .recursive_destroy_used == false
    ' "$cleanup" >/dev/null || return 1
    completed=$(jq -er '.completed_at | select(type == "string")' "$receipt") || return 1
    [[ "$completed" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 1
    jq -e --arg run "$RUN_DIR" --arg outcome "$expected_outcome" --arg completed "$completed" \
        --arg transaction_sha "$transaction_sha" --arg release_sha "$release_sha" \
        --arg ready_rel "${ready#"$RUN_DIR/"}" --arg ready_sha "$ready_sha" \
        --arg result_rel "${terminal_result#"$RUN_DIR/"}" --arg result_sha "$result_sha" \
        --arg fleet_rel "${fleet_identity#"$RUN_DIR/"}" --arg fleet_sha "$fleet_identity_sha" \
        --arg free_claim_rel "${free_claim_identity#"$RUN_DIR/"}" \
        --arg free_claim_sha "$free_claim_identity_sha" --arg cleanup_sha "$cleanup_sha" \
        --arg generation_expected_rel "${generation_expected#"$RUN_DIR/"}" \
        --arg generation_expected_sha "$generation_expected_sha" \
        --arg generation_final_rel "${generation_final#"$RUN_DIR/"}" \
        --arg generation_final_sha "$generation_final_sha" \
        --argjson evidence_manifest "$evidence_manifest" \
        --argjson regular_pow_active "$regular_pow_active" \
        --argjson legacy_quarantined_disabled "$legacy_quarantined_disabled" '
        . == {schema:1,transaction:"v30.1.4-fleet-finalization",run_dir:$run,
          outcome:$outcome,state_token:$outcome,finalization_state:"finalized",completed_at:$completed,
          transaction_manifest_sha256:$transaction_sha,free_claim_release_receipt_sha256:$release_sha,
          finalization_ready_evidence:$ready_rel,finalization_ready_sha256:$ready_sha,
          terminal_evidence_manifest:$evidence_manifest,
          terminal_result_evidence:$result_rel,terminal_result_sha256:$result_sha,
          fleet_identity_evidence:$fleet_rel,fleet_identity_sha256:$fleet_sha,
          free_claim_identity_evidence:$free_claim_rel,
          free_claim_identity_sha256:$free_claim_sha,
          snapshot_cleanup_evidence:"snapshot-cleanup/RESULT.json",
          snapshot_cleanup_sha256:$cleanup_sha,
          terminal_generation_expected_evidence:$generation_expected_rel,
          terminal_generation_expected_sha256:$generation_expected_sha,
          terminal_generation_evidence:$generation_final_rel,
          terminal_generation_sha256:$generation_final_sha,
          nodes_operational:32,pos_active:32,
          regular_pow_active:$regular_pow_active,
          legacy_quarantined_disabled:$legacy_quarantined_disabled,
          free_claim_node:30,free_claim_regular_pow:false,
          fee_payments_authorized:false,terminal_evidence_bound:true}
    ' "$receipt" >/dev/null
}

write_terminal_receipt()
{
    local outcome="$1" receipt_dir staging ready terminal_result fleet_identity
    local free_claim_identity cleanup transaction release_receipt transaction_sha release_sha
    local ready_sha result_sha fleet_identity_sha free_claim_identity_sha cleanup_sha temporary sha_tmp
    local result evidence_manifest evidence_manifest_path evidence_manifest_sha directories_path directories_sha path
    local hour_manifest_path hour_manifest_sha hour_directories_path hour_directories_sha
    local generation_expected_rel generation_expected generation_final generation_expected_sha generation_final_sha
    local regular_pow_active legacy_quarantined_disabled
    receipt_dir=$(terminal_receipt_dir) || return 1
    [[ ! -e "$receipt_dir" && ! -L "$receipt_dir" ]] || return 1
    case "$outcome" in
        complete)
            result="$RUN_DIR/exact-32-soak/RESULT.json"
            ready="$RUN_DIR/exact-32-soak/FINALIZATION-READY.json"
            terminal_result="$RUN_DIR/exact-32-soak/POST-RELEASE.json"
            fleet_identity="$RUN_DIR/final-fleet-identity.post-release.json"
            free_claim_identity="$RUN_DIR/final-free-claim-container-identity.post-release.json"
            evidence_manifest_path="$RUN_DIR/exact-32-soak/SHA256SUMS"
            directories_path="$RUN_DIR/exact-32-soak/DIRECTORIES"
            hour_manifest_path="$RUN_DIR/HOUR-SOAK-SHA256SUMS"
            hour_directories_path="$RUN_DIR/HOUR-SOAK-DIRECTORIES"
            verify_success_post_release_evidence || return 1
            for path in "$evidence_manifest_path" "$directories_path" \
                "$hour_manifest_path" "$hour_directories_path"; do
                [[ -f "$path" && ! -L "$path" && "$(realpath -e -- "$path")" == "$path" &&
                   "$(stat -c '%u:%g:%a' "$path")" == 0:0:600 ]] || return 1
            done
            (cd "$RUN_DIR/exact-32-soak" && sha256sum --strict -c SHA256SUMS >/dev/null) || return 1
            (cd "$RUN_DIR/exact-32-soak" && \
                sha256sum --strict -c "$hour_manifest_path" >/dev/null) || return 1
            evidence_manifest_sha=$(sha256sum "$evidence_manifest_path" | awk '{print $1}') || return 1
            directories_sha=$(sha256sum "$directories_path" | awk '{print $1}') || return 1
            hour_manifest_sha=$(sha256sum "$hour_manifest_path" | awk '{print $1}') || return 1
            hour_directories_sha=$(sha256sum "$hour_directories_path" | awk '{print $1}') || return 1
            evidence_manifest=$(jq -cn --arg path "${evidence_manifest_path#"$RUN_DIR/"}" \
                --arg sha "$evidence_manifest_sha" --arg directories "${directories_path#"$RUN_DIR/"}" \
                --arg directories_sha "$directories_sha" \
                --arg hour_manifest "${hour_manifest_path#"$RUN_DIR/"}" \
                --arg hour_manifest_sha "$hour_manifest_sha" \
                --arg hour_directories "${hour_directories_path#"$RUN_DIR/"}" \
                --arg hour_directories_sha "$hour_directories_sha" \
                '{path:$path,sha256:$sha,directories_path:$directories,directories_sha256:$directories_sha,
                  hour_manifest_path:$hour_manifest,hour_manifest_sha256:$hour_manifest_sha,
                  hour_directories_path:$hour_directories,hour_directories_sha256:$hour_directories_sha}') ||
                return 1
            generation_expected_rel=$(jq -er '.generation_before_publication_evidence' \
                "$terminal_result") || return 1
            [[ "$generation_expected_rel" =~ ^finalization-post-release-attempt-[0-9]{3,}/GENERATIONS[.]before-publication$ ]] ||
                return 1
            generation_expected="$RUN_DIR/exact-32-soak/$generation_expected_rel"
            generation_final="$RUN_DIR/final-generations.post-release"
            regular_pow_active=31
            legacy_quarantined_disabled=0
            ;;
        rolled-back)
            result="$RUN_DIR/ROLLBACK_RESULT.json"
            ready="$RUN_DIR/ROLLBACK-FINALIZATION-READY.json"
            terminal_result="$RUN_DIR/rollback-post-release/RESULT.json"
            fleet_identity="$RUN_DIR/rollback-final-fleet-identity.post-release.json"
            free_claim_identity="$RUN_DIR/rollback-free-claim-container-identity.post-release.json"
            evidence_manifest_path="$RUN_DIR/rollback-post-release/SHA256SUMS"
            directories_path="$RUN_DIR/rollback-post-release/DIRECTORIES"
            for path in "$evidence_manifest_path" "$directories_path"; do
                [[ -f "$path" && ! -L "$path" && "$(realpath -e -- "$path")" == "$path" &&
                   "$(stat -c '%u:%g:%a' "$path")" == 0:0:600 ]] || return 1
            done
            evidence_manifest_sha=$(sha256sum "$evidence_manifest_path" | awk '{print $1}') || return 1
            directories_sha=$(sha256sum "$directories_path" | awk '{print $1}') || return 1
            evidence_manifest=$(jq -cn --arg path "${evidence_manifest_path#"$RUN_DIR/"}" \
                --arg sha "$evidence_manifest_sha" --arg directories "${directories_path#"$RUN_DIR/"}" \
                --arg directories_sha "$directories_sha" \
                '{path:$path,sha256:$sha,directories_path:$directories,directories_sha256:$directories_sha,
                  hour_manifest_path:null,hour_manifest_sha256:null,
                  hour_directories_path:null,hour_directories_sha256:null}') || return 1
            generation_expected_rel=$(jq -er '.generation_before_publication_evidence' "$ready") || return 1
            [[ "$generation_expected_rel" =~ ^rollback-finalization-attempt-[0-9]{3,}/GENERATIONS[.]before-publication$ ]] ||
                return 1
            generation_expected="$RUN_DIR/$generation_expected_rel"
            generation_final="$RUN_DIR/rollback-final-generations.post-release"
            verify_rollback_post_release_evidence || return 1
            regular_pow_active=$(jq -er '.regular_pow_active' "$ready") || return 1
            legacy_quarantined_disabled=$(jq -er '.legacy_quarantined_disabled' "$ready") || return 1
            ;;
        *) return 1 ;;
    esac
    cleanup="$RUN_DIR/snapshot-cleanup/RESULT.json"
    transaction="$RUN_DIR/TRANSACTION.json"
    release_receipt="$RUN_DIR/FREE-CLAIM-RELEASED.json"
    for path in "$transaction" "$release_receipt" "$ready" "$terminal_result" \
        "$fleet_identity" "$free_claim_identity" "$cleanup" "$RUN_DIR/snapshot-cleanup/RESULT.json.sha256" \
        "$evidence_manifest_path" "$generation_expected" "$generation_final"; do
        [[ -f "$path" && ! -L "$path" && "$(realpath -e -- "$path")" == "$path" &&
           "$(stat -c '%u:%g:%a' "$path")" == 0:0:600 ]] || return 1
    done
    [[ -f "$RUN_DIR/STATE" && ! -L "$RUN_DIR/STATE" &&
       "$(stat -c '%u:%g:%a' "$RUN_DIR/STATE")" == 0:0:600 &&
       -f "$(finalization_state_path)" && ! -L "$(finalization_state_path)" &&
       "$(stat -c '%u:%g:%a' "$(finalization_state_path)")" == 0:0:600 &&
       "$(<"$RUN_DIR/STATE")" == "$outcome" ]] || return 1
    case "$(<"$(finalization_state_path)")" in
        post-release-passed|finalized) ;;
        *) return 1 ;;
    esac
    /bin/bash "$INHIBITOR_RELEASER" verify-release \
        "$result" "$RUN_DIR/STATE" "$ready" >/dev/null || return 1
    transaction_sha=$(sha256sum "$transaction" | awk '{print $1}') || return 1
    release_sha=$(sha256sum "$release_receipt" | awk '{print $1}') || return 1
    ready_sha=$(sha256sum "$ready" | awk '{print $1}') || return 1
    result_sha=$(sha256sum "$terminal_result" | awk '{print $1}') || return 1
    fleet_identity_sha=$(sha256sum "$fleet_identity" | awk '{print $1}') || return 1
    free_claim_identity_sha=$(sha256sum "$free_claim_identity" | awk '{print $1}') || return 1
    cleanup_sha=$(sha256sum "$cleanup" | awk '{print $1}') || return 1
    generation_expected_sha=$(sha256sum "$generation_expected" | awk '{print $1}') || return 1
    generation_final_sha=$(sha256sum "$generation_final" | awk '{print $1}') || return 1
    [[ "$generation_expected_sha" == "$generation_final_sha" ]] || return 1
    cmp -s "$generation_expected" "$generation_final" || return 1
    [[ "$(<"$RUN_DIR/snapshot-cleanup/RESULT.json.sha256")" == "$cleanup_sha" ]] || return 1
    jq -e --arg run "$RUN_DIR" '
        .schema == 1 and .transaction == "v30.1.4-snapshot-cleanup" and
        .run_dir == $run and .result == "passed" and .cleanup_complete == true and
        .unrelated_snapshots_destroyed == 0 and .recursive_destroy_used == false
    ' "$cleanup" >/dev/null || return 1
    publish_state_token "$(finalization_state_path)" finalized || return 1
    staging=$(mktemp -d "$RUN_DIR/.terminal-finalization.XXXXXX") || return 1
    chmod 700 "$staging" && chown root:root "$staging" || return 1
    temporary="$staging/RESULT.json"
    jq -n --arg run "$RUN_DIR" --arg outcome "$outcome" --arg completed "$(date -u +%FT%TZ)" \
        --arg transaction_sha "$transaction_sha" --arg release_sha "$release_sha" \
        --arg ready_rel "${ready#"$RUN_DIR/"}" --arg ready_sha "$ready_sha" \
        --arg result_rel "${terminal_result#"$RUN_DIR/"}" --arg result_sha "$result_sha" \
        --arg fleet_rel "${fleet_identity#"$RUN_DIR/"}" --arg fleet_sha "$fleet_identity_sha" \
        --arg free_claim_rel "${free_claim_identity#"$RUN_DIR/"}" \
        --arg free_claim_sha "$free_claim_identity_sha" --arg cleanup_sha "$cleanup_sha" \
        --arg generation_expected_rel "${generation_expected#"$RUN_DIR/"}" \
        --arg generation_expected_sha "$generation_expected_sha" \
        --arg generation_final_rel "${generation_final#"$RUN_DIR/"}" \
        --arg generation_final_sha "$generation_final_sha" \
        --argjson evidence_manifest "$evidence_manifest" \
        --argjson regular_pow_active "$regular_pow_active" \
        --argjson legacy_quarantined_disabled "$legacy_quarantined_disabled" '
        {schema:1,transaction:"v30.1.4-fleet-finalization",run_dir:$run,
         outcome:$outcome,state_token:$outcome,finalization_state:"finalized",completed_at:$completed,
         transaction_manifest_sha256:$transaction_sha,free_claim_release_receipt_sha256:$release_sha,
         finalization_ready_evidence:$ready_rel,finalization_ready_sha256:$ready_sha,
         terminal_evidence_manifest:$evidence_manifest,
         terminal_result_evidence:$result_rel,terminal_result_sha256:$result_sha,
         fleet_identity_evidence:$fleet_rel,fleet_identity_sha256:$fleet_sha,
         free_claim_identity_evidence:$free_claim_rel,free_claim_identity_sha256:$free_claim_sha,
         snapshot_cleanup_evidence:"snapshot-cleanup/RESULT.json",
         snapshot_cleanup_sha256:$cleanup_sha,
         terminal_generation_expected_evidence:$generation_expected_rel,
         terminal_generation_expected_sha256:$generation_expected_sha,
         terminal_generation_evidence:$generation_final_rel,
         terminal_generation_sha256:$generation_final_sha,
         nodes_operational:32,pos_active:32,
         regular_pow_active:$regular_pow_active,
         legacy_quarantined_disabled:$legacy_quarantined_disabled,
         free_claim_node:30,free_claim_regular_pow:false,
         fee_payments_authorized:false,terminal_evidence_bound:true}
    ' > "$temporary" || return 1
    chmod 600 "$temporary" && chown root:root "$temporary" && sync -f "$temporary" || return 1
    sha_tmp="$staging/SHA256SUMS"
    (cd "$staging" && sha256sum ./RESULT.json) > "$sha_tmp" || return 1
    chmod 600 "$sha_tmp" && chown root:root "$sha_tmp" && sync -f "$sha_tmp" || return 1
    sync -f "$staging" || return 1
    verify_terminal_receipt "$outcome" 0 "$staging" || return 1
    trap '' HUP INT TERM
    if ! mv -T -- "$staging" "$receipt_dir"; then
        trap 'exit 129' HUP
        trap 'exit 130' INT
        trap 'exit 143' TERM
        return 1
    fi
    # The fully verified terminal directory is now atomically visible. Masked
    # signals close the command-boundary gap, and the terminal flag is set
    # before parent fsync: after a power loss the rename is either replayable or
    # absent, while this process must never recontain a visible terminal receipt.
    TERMINAL_FINALIZED=1
    TERMINAL_COMMIT_ACTIVE=0
    FINALIZATION_ACTIVE=0
    if ! sync -f "$RUN_DIR"; then
        trap 'exit 129' HUP
        trap 'exit 130' INT
        trap 'exit 143' TERM
        return 1
    fi
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    verify_terminal_receipt "$outcome" 0 || return 1
    verify_terminal_receipt "$outcome" 1
}

verify_snapshot_cleanup_resume_prefix()
{
    local cleanup_dir="$RUN_DIR/snapshot-cleanup" plan_sha
    valid_rollout_run_dir "$RUN_DIR" || return 1
    verify_transaction_manifest || return 1
    data_rollback_cleanup_allowed || return 1
    data_rollback_verify_cleanup_plan_dir "$cleanup_dir" || return 1
    data_rollback_verify_cleanup_sources "$cleanup_dir" || return 1
    plan_sha=$(<"$cleanup_dir/PLAN.tsv.sha256")
    [[ "$plan_sha" =~ ^[0-9a-f]{64}$ ]] || return 1
    data_rollback_verify_cleanup_journal_topology "$cleanup_dir" "$plan_sha"
}

verify_terminal_cleanup_prerequisites()
{
    local outcome="$1" terminal_result fleet_identity free_claim_identity
    local generation_source generation_rel generation_expected generation_final path finalization_state
    [[ -f "$RUN_DIR/STATE" && ! -L "$RUN_DIR/STATE" &&
       "$(stat -c '%u:%g:%a' "$RUN_DIR/STATE")" == 0:0:600 &&
       "$(<"$RUN_DIR/STATE")" == "$outcome" &&
       -f "$(finalization_state_path)" && ! -L "$(finalization_state_path)" &&
       "$(stat -c '%u:%g:%a' "$(finalization_state_path)")" == 0:0:600 ]] || return 1
    finalization_state=$(<"$(finalization_state_path)")
    [[ "$finalization_state" == post-release-passed || "$finalization_state" == finalized ]] ||
        return 1
    case "$outcome" in
        complete)
            verify_success_post_release_evidence || return 1
            terminal_result="$RUN_DIR/exact-32-soak/POST-RELEASE.json"
            generation_source="$terminal_result"
            fleet_identity="$RUN_DIR/final-fleet-identity.post-release.json"
            free_claim_identity="$RUN_DIR/final-free-claim-container-identity.post-release.json"
            generation_final="$RUN_DIR/final-generations.post-release"
            ;;
        rolled-back)
            verify_rollback_post_release_evidence || return 1
            terminal_result="$RUN_DIR/rollback-post-release/RESULT.json"
            generation_source="$RUN_DIR/ROLLBACK-FINALIZATION-READY.json"
            fleet_identity="$RUN_DIR/rollback-final-fleet-identity.post-release.json"
            free_claim_identity="$RUN_DIR/rollback-free-claim-container-identity.post-release.json"
            generation_final="$RUN_DIR/rollback-final-generations.post-release"
            ;;
        *) return 1 ;;
    esac
    generation_rel=$(jq -er '.generation_before_publication_evidence' "$generation_source") ||
        return 1
    case "$outcome:$generation_rel" in
        complete:finalization-post-release-attempt-[0-9][0-9][0-9]*'/GENERATIONS.before-publication')
            generation_expected="$RUN_DIR/exact-32-soak/$generation_rel"
            ;;
        rolled-back:rollback-finalization-attempt-[0-9][0-9][0-9]*'/GENERATIONS.before-publication')
            generation_expected="$RUN_DIR/$generation_rel"
            ;;
        *) return 1 ;;
    esac
    for path in "$terminal_result" "$fleet_identity" "$free_claim_identity" \
        "$generation_expected" "$generation_final" \
        "$RUN_DIR/baseline/fleet-identity.json" \
        "$RUN_DIR/baseline/free-claim-container-identity.json"; do
        [[ -f "$path" && ! -L "$path" && "$(realpath -e -- "$path")" == "$path" &&
           "$(stat -c '%u:%g:%a' "$path")" == 0:0:600 ]] || return 1
    done
    jq -e -n --slurpfile before "$RUN_DIR/baseline/fleet-identity.json" \
        --slurpfile after "$fleet_identity" '
        def identity($rows): $rows[0] | map({node,wallets_json,legacy_addresses_sha256,
          quantum_addresses_sha256,quantum_inventory_sha256,runtime_manifest_sha256,
          identity_manifest_sha256,pow_manifest_sha256,blackcoin_conf_sha256,
          settings_json_sha256,vpn_id});
        ($before | length) == 1 and ($after | length) == 1 and
        ($before[0] | type) == "array" and ($after[0] | type) == "array" and
        ($before[0] | length) == 32 and ($after[0] | length) == 32 and
        identity($before) == identity($after)
    ' >/dev/null || return 1
    cmp -s "$RUN_DIR/baseline/free-claim-container-identity.json" "$free_claim_identity" ||
        return 1
    cmp -s "$generation_expected" "$generation_final"
}

finalize_completed_rollout()
{
    local inhibitor_state deadline finalization_ready release_required=0 resume_finalization_state
    [[ -f "$RUN_DIR/STATE" && ! -L "$RUN_DIR/STATE" && "$(cat "$RUN_DIR/STATE")" == complete ]] ||
        return 1
    if [[ -e "$(terminal_receipt_dir)" || -L "$(terminal_receipt_dir)" ]]; then
        trap '' HUP INT TERM
        if ! verify_terminal_receipt complete 0; then
            trap 'exit 129' HUP
            trap 'exit 130' INT
            trap 'exit 143' TERM
            return 1
        fi
        TERMINAL_FINALIZED=1
        FINALIZATION_ACTIVE=0
        trap 'exit 129' HUP
        trap 'exit 130' INT
        trap 'exit 143' TERM
        verify_terminal_receipt complete 1 || return 1
        return 0
    fi
    if [[ -e "$RUN_DIR/snapshot-cleanup" || -L "$RUN_DIR/snapshot-cleanup" ]]; then
        verify_snapshot_cleanup_resume_prefix || return 1
        resume_finalization_state=$(<"$(finalization_state_path)") || return 1
        case "$resume_finalization_state" in
            post-release-passed|finalized)
                verify_terminal_cleanup_prerequisites complete || return 1
                if data_rollback_finalization_released; then
                    TERMINAL_COMMIT_ACTIVE=1
                    FINALIZATION_ACTIVE=0
                    cleanup_transaction_snapshots || return 1
                    write_terminal_receipt complete || return 1
                    TERMINAL_COMMIT_ACTIVE=0
                    return 0
                fi
                ;;
            contained)
                # The cleanup prefix is authenticated, but no destructive
                # cleanup resumes until the normal release state machine below
                # proves fresh post-release evidence again.
                ;;
            *) return 1 ;;
        esac
    fi
    inhibitor_state=$(/bin/bash "$INHIBITOR_RELEASER" probe) || return 1
    finalization_ready="$RUN_DIR/exact-32-soak/FINALIZATION-READY.json"
    case "$inhibitor_state" in
        'state=installed-and-paused cycle=v30.1.4-no-spend free_claim=paused')
            release_maintenance_for_finalization || return 1
            SOAK_PHASE=pre-release "$SOAK_AUDITOR" "$RUN_DIR" || return 1
            publish_state_token "$(finalization_state_path)" pre-release-passed || return 1
            release_required=1
            ;;
        'state=installed-and-released cycle=v30.1.4-no-spend free_claim=enabled')
            [[ ! -e "$ROLLOUT_MAINTENANCE_MARKER" &&
               ! -L "$ROLLOUT_MAINTENANCE_MARKER" ]] || {
                ensure_finalization_containment
                return 1
            }
            valid_maintenance_released_epoch || return 1
            if ! /bin/bash "$INHIBITOR_RELEASER" verify-release \
                "$RUN_DIR/exact-32-soak/RESULT.json" "$RUN_DIR/STATE" "$finalization_ready"; then
                ensure_finalization_containment
                return 1
            fi
            ;;
        *) return 1 ;;
    esac
    if ((release_required == 1)); then
        CONFIRM_RELEASE_TRANSACTION_INHIBITORS=v30.1.4-release-free-claim-after-success \
            /bin/bash "$INHIBITOR_RELEASER" release \
            "$RUN_DIR/exact-32-soak/RESULT.json" "$RUN_DIR/STATE" "$finalization_ready" || return 1
    fi
    /bin/bash "$INHIBITOR_RELEASER" verify-release \
        "$RUN_DIR/exact-32-soak/RESULT.json" "$RUN_DIR/STATE" "$finalization_ready" || return 1
    publish_state_token "$(finalization_state_path)" free-claim-released || return 1
    inhibitor_state=$(/bin/bash "$INHIBITOR_RELEASER" probe) || return 1
    [[ "$inhibitor_state" == 'state=installed-and-released cycle=v30.1.4-no-spend free_claim=enabled' ]] ||
        return 1
    deadline=$((SECONDS + 1200))
    while ((SECONDS < deadline)); do
        verify_node30_free_claim_service && break
        sleep 5
    done
    verify_node30_free_claim_service || return 1
    [[ ! -e "$ROLLOUT_MAINTENANCE_MARKER" && ! -L "$ROLLOUT_MAINTENANCE_MARKER" ]] || return 1
    SOAK_PHASE=post-release "$SOAK_AUDITOR" "$RUN_DIR" || return 1
    publish_state_token "$(finalization_state_path)" post-release-passed || return 1
    assert_fleet_identity_matches_baseline "$RUN_DIR/final-fleet-identity.post-release.json" || return 1
    assert_free_claim_container_identity_matches_baseline \
        "$RUN_DIR/final-free-claim-container-identity.post-release.json" || return 1
    capture_terminal_generation_fence complete || return 1
    verify_terminal_cleanup_prerequisites complete || return 1
    data_rollback_prepare_cleanup_plan "$RUN_DIR/snapshot-cleanup" || return 1
    verify_snapshot_cleanup_resume_prefix || return 1
    data_rollback_finalization_released || return 1
    TERMINAL_COMMIT_ACTIVE=1
    FINALIZATION_ACTIVE=0
    cleanup_transaction_snapshots || return 1
    write_terminal_receipt complete || return 1
    verify_terminal_receipt complete || return 1
    TERMINAL_COMMIT_ACTIVE=0
}

verify_all_baseline_runtime_once()
{
    local node pid failed=0
    local -a pids=() nodes=()
    for node in $(seq 1 "$NODE_COUNT"); do
        verify_policy_runtime_node "$node" &
        pids+=("$!")
        nodes+=("$node")
    done
    for index in "${!pids[@]}"; do
        pid=${pids[$index]}
        if ! wait "$pid"; then
            log "rollback finalization runtime gate failed node=${nodes[$index]}"
            failed=1
        fi
    done
    ((failed == 0)) && assert_unique_vpn_proofs && verify_node30_free_claim_service
}

legacy_restore_counts()
{
    local node baseline mode mining lookup_rc active=0 quarantined=0
    for node in $(seq 1 "$NODE_COUNT"); do
        [[ "$node" -ne "$FREE_CLAIM_NODE" ]] || continue
        if baseline=$(legacy_plan_file_for_node "$node" 2>/dev/null); then
            :
        else
            lookup_rc=$?
            [[ "$lookup_rc" -eq 2 ]] || return 1
            mining=$(wallet_rpc_for "$node" getpowmininginfo | jq -ceS .) || return 1
            mode=$(_legacy_pow_snapshot_mode_json "$node" "$mining") || return 1
            baseline=
        fi
        if [[ -n "$baseline" ]]; then
            mode=$(legacy_pow_baseline_mode "$node" "$baseline") || return 1
        fi
        case "$mode" in
            clean-hashing) active=$((active + 1)) ;;
            quarantined-disabled) quarantined=$((quarantined + 1)) ;;
            *) return 1 ;;
        esac
    done
    ((active + quarantined == NODE_COUNT - 1)) || return 1
    printf '%s %s\n' "$active" "$quarantined"
}

capture_rollback_chain_convergence()
{
    local root="$1" attempt attempt_dir node pid count
    local -a pids=()
    install -d -m 700 -o root -g root "$root" || return 1
    for attempt in $(seq 1 120); do
        attempt_dir=$(printf '%s/attempt-%03d' "$root" "$attempt")
        install -d -m 700 -o root -g root "$attempt_dir" || return 1
        pids=()
        for node in $(seq 1 "$NODE_COUNT"); do
            (
                rpc_for "$node" getblockchaininfo | jq -c --argjson node "$node" \
                    '{node:$node,chain,blocks,headers,bestblockhash,chainwork,initialblockdownload}' \
                    > "$attempt_dir/node-$(node_padded "$node").json"
            ) &
            pids+=("$!")
        done
        for pid in "${pids[@]}"; do wait "$pid" || true; done
        count=$(find "$attempt_dir" -maxdepth 1 -type f -name 'node-*.json' | wc -l) || return 1
        if [[ "$count" -eq "$NODE_COUNT" ]] && jq -e -s '
            length == 32 and all(.[]; .chain == "main" and .initialblockdownload == false and
              .headers >= .blocks and (.headers - .blocks) <= 2) and
            ([.[].blocks] | unique | length) == 1 and
            ([.[].bestblockhash] | unique | length) == 1 and
            ([.[].chainwork] | unique | length) == 1
        ' "$attempt_dir"/node-*.json >/dev/null; then
            jq -s 'sort_by(.node)' "$attempt_dir"/node-*.json > "$root/PASSED.json" || return 1
            chmod 600 "$root/PASSED.json" && chown root:root "$root/PASSED.json" || return 1
            return 0
        fi
        sleep 2
    done
    return 1
}

verify_rollback_post_release_evidence()
{
    local require_current_ready="${1:-1}"
    local evidence="$RUN_DIR/rollback-post-release" ready="$RUN_DIR/ROLLBACK-FINALIZATION-READY.json"
    local ready_copy="$RUN_DIR/rollback-post-release/ROLLBACK-FINALIZATION-READY.json"
    local relative expected before after chain result ready_sha expected_sha before_sha after_sha chain_sha
    local regular_pow_active legacy_quarantined_disabled
    [[ -d "$evidence" && ! -L "$evidence" && "$(realpath -e -- "$evidence")" == "$evidence" &&
       "$(stat -c '%u:%g:%a' "$evidence")" == 0:0:700 &&
       -z "$(find "$evidence" -type l -print -quit)" &&
       -z "$(find "$evidence" ! -type d ! -type f -print -quit)" ]] || return 1
    while IFS= read -r -d '' relative; do
        [[ "$(stat -c '%u:%g:%a' "$relative")" == 0:0:700 ]] || return 1
    done < <(find "$evidence" -mindepth 1 -type d -print0)
    while IFS= read -r -d '' relative; do
        [[ "$(stat -c '%u:%g:%a' "$relative")" == 0:0:600 ]] || return 1
    done < <(find "$evidence" -type f -print0)
    [[ -f "$evidence/DIRECTORIES" && -f "$evidence/SHA256SUMS" ]] || return 1
    cmp -s <(cd "$evidence" && find . -mindepth 1 -type d -print | sort) \
        <(sort "$evidence/DIRECTORIES") || return 1
    cmp -s "$evidence/DIRECTORIES" <(sort -u "$evidence/DIRECTORIES") || return 1
    cmp -s <(cd "$evidence" && find . -type f ! -path './SHA256SUMS' -print | sort) \
        <(awk 'NF == 2 && $1 ~ /^[0-9a-f]{64}$/ {print $2}' "$evidence/SHA256SUMS" | sort) ||
        return 1
    (cd "$evidence" && sha256sum --strict -c SHA256SUMS >/dev/null) || return 1
    [[ "$require_current_ready" == 0 || "$require_current_ready" == 1 ]] || return 1
    result="$evidence/RESULT.json"
    expected="$evidence/GENERATIONS.expected"
    before="$evidence/GENERATIONS.before"
    after="$evidence/GENERATIONS.after"
    chain="$evidence/chain/PASSED.json"
    [[ -f "$ready_copy" && ! -L "$ready_copy" ]] || return 1
    ready_sha=$(sha256sum "$ready_copy" | awk '{print $1}') || return 1
    regular_pow_active=$(jq -er '.regular_pow_active' "$ready_copy") || return 1
    legacy_quarantined_disabled=$(jq -er '.legacy_quarantined_disabled' "$ready_copy") || return 1
    if [[ "$require_current_ready" -eq 1 ]]; then
        [[ -f "$ready" && ! -L "$ready" &&
           "$(sha256sum "$ready" | awk '{print $1}')" == "$ready_sha" ]] || return 1
    fi
    expected_sha=$(sha256sum "$expected" | awk '{print $1}') || return 1
    before_sha=$(sha256sum "$before" | awk '{print $1}') || return 1
    after_sha=$(sha256sum "$after" | awk '{print $1}') || return 1
    chain_sha=$(sha256sum "$chain" | awk '{print $1}') || return 1
    [[ "$expected_sha" == "$before_sha" && "$expected_sha" == "$after_sha" ]] || return 1
    cmp -s "$expected" "$before" && cmp -s "$expected" "$after" || return 1
    jq -e '
        type == "array" and length == 32 and [.[] | .node] == [range(1;33)] and
        all(.[]; .chain == "main" and .initialblockdownload == false) and
        ([.[].blocks] | unique | length) == 1 and
        ([.[].bestblockhash] | unique | length) == 1 and
        ([.[].chainwork] | unique | length) == 1
    ' "$chain" >/dev/null || return 1
    jq -e --arg run "$RUN_DIR" --arg ready_sha "$ready_sha" \
        --arg expected_sha "$expected_sha" --arg before_sha "$before_sha" \
        --arg after_sha "$after_sha" --arg chain_sha "$chain_sha" \
        --argjson regular_pow_active "$regular_pow_active" \
        --argjson legacy_quarantined_disabled "$legacy_quarantined_disabled" '
        .schema == 1 and .transaction == "v30.1.4-rollback-post-release" and
        .run_dir == $run and .result == "passed" and
        .rollback_finalization_ready_sha256 == $ready_sha and
        .generation_expected_evidence == "GENERATIONS.expected" and
        .generation_expected_sha256 == $expected_sha and
        .generation_before_evidence == "GENERATIONS.before" and
        .generation_before_sha256 == $before_sha and
        .generation_after_evidence == "GENERATIONS.after" and
        .generation_after_sha256 == $after_sha and
        .chain_convergence_evidence == "chain/PASSED.json" and
        .chain_convergence_sha256 == $chain_sha and
        .nodes_operational == 32 and .pos_active == 32 and
        .regular_pow_active == $regular_pow_active and
        .legacy_quarantined_disabled == $legacy_quarantined_disabled and
        .regular_pow_active + .legacy_quarantined_disabled == 31 and
        .free_claim_node == 30 and .free_claim_regular_pow == false and
        .vpn_proofs_valid_unique == 32 and .exact_32_generation_fence == true and
        .global_chain_convergence == true and .free_claim_service_healthy == true and
        .fee_payments_authorized == false
    ' "$result" >/dev/null
}

write_rollback_post_release_evidence()
{
    local canonical="$RUN_DIR/rollback-post-release" staging archive_index=1 archive ready
    local ready_rel expected ready_sha expected_sha before_sha after_sha chain_sha temporary
    local regular_pow_active legacy_quarantined_disabled
    if [[ -e "$canonical" || -L "$canonical" ]]; then
        verify_rollback_post_release_evidence 0 || return 1
        while [[ -e "$(printf '%s/rollback-post-release-prior-%03d' "$RUN_DIR" "$archive_index")" ||
                 -L "$(printf '%s/rollback-post-release-prior-%03d' "$RUN_DIR" "$archive_index")" ]]; do
            archive_index=$((archive_index + 1))
        done
        archive=$(printf '%s/rollback-post-release-prior-%03d' "$RUN_DIR" "$archive_index")
        mv -T -- "$canonical" "$archive" || return 1
        sync -f "$RUN_DIR" || return 1
    fi
    staging=$(mktemp -d "$RUN_DIR/.rollback-post-release.XXXXXX") || return 1
    chmod 700 "$staging" && chown root:root "$staging" || return 1
    ready="$RUN_DIR/ROLLBACK-FINALIZATION-READY.json"
    ready_rel=$(jq -er '.generation_before_publication_evidence' "$ready") || return 1
    [[ "$ready_rel" =~ ^rollback-finalization-attempt-[0-9]{3,}/GENERATIONS[.]before-publication$ ]] ||
        return 1
    expected="$RUN_DIR/$ready_rel"
    install -m 600 -o root -g root "$ready" \
        "$staging/ROLLBACK-FINALIZATION-READY.json" || return 1
    install -m 600 -o root -g root "$expected" "$staging/GENERATIONS.expected" || return 1
    capture_exact_32_generation_map "$staging/GENERATIONS.before" || return 1
    cmp -s "$staging/GENERATIONS.expected" "$staging/GENERATIONS.before" || return 1
    verify_all_baseline_runtime_once || return 1
    capture_rollback_chain_convergence "$staging/chain" || return 1
    verify_all_baseline_runtime_once || return 1
    capture_exact_32_generation_map "$staging/GENERATIONS.after" || return 1
    cmp -s "$staging/GENERATIONS.expected" "$staging/GENERATIONS.after" || return 1
    ready_sha=$(sha256sum "$staging/ROLLBACK-FINALIZATION-READY.json" | awk '{print $1}') || return 1
    expected_sha=$(sha256sum "$staging/GENERATIONS.expected" | awk '{print $1}') || return 1
    before_sha=$(sha256sum "$staging/GENERATIONS.before" | awk '{print $1}') || return 1
    after_sha=$(sha256sum "$staging/GENERATIONS.after" | awk '{print $1}') || return 1
    chain_sha=$(sha256sum "$staging/chain/PASSED.json" | awk '{print $1}') || return 1
    read -r regular_pow_active legacy_quarantined_disabled < <(legacy_restore_counts) || return 1
    [[ "$expected_sha" == "$before_sha" && "$expected_sha" == "$after_sha" ]] || return 1
    temporary="$staging/RESULT.json"
    jq -n --arg run "$RUN_DIR" --arg completed "$(date -u +%FT%TZ)" \
        --arg ready_sha "$ready_sha" --arg expected_sha "$expected_sha" \
        --arg before_sha "$before_sha" --arg after_sha "$after_sha" --arg chain_sha "$chain_sha" \
        --argjson regular_pow_active "$regular_pow_active" \
        --argjson legacy_quarantined_disabled "$legacy_quarantined_disabled" '
        {schema:1,transaction:"v30.1.4-rollback-post-release",run_dir:$run,
         result:"passed",completed_at:$completed,rollback_finalization_ready_sha256:$ready_sha,
         generation_expected_evidence:"GENERATIONS.expected",generation_expected_sha256:$expected_sha,
         generation_before_evidence:"GENERATIONS.before",generation_before_sha256:$before_sha,
         generation_after_evidence:"GENERATIONS.after",generation_after_sha256:$after_sha,
         chain_convergence_evidence:"chain/PASSED.json",chain_convergence_sha256:$chain_sha,
         nodes_operational:32,pos_active:32,regular_pow_active:$regular_pow_active,
         legacy_quarantined_disabled:$legacy_quarantined_disabled,free_claim_node:30,
         free_claim_regular_pow:false,vpn_proofs_valid_unique:32,
         exact_32_generation_fence:true,global_chain_convergence:true,
         free_claim_service_healthy:true,fee_payments_authorized:false}
    ' > "$temporary" || return 1
    chmod 600 "$temporary" && chown root:root "$temporary" || return 1
    (cd "$staging" && find . -mindepth 1 -type d -print | sort) > "$staging/DIRECTORIES" || return 1
    chmod 600 "$staging/DIRECTORIES" && chown root:root "$staging/DIRECTORIES" || return 1
    find "$staging" -type d -exec chmod 700 {} + -exec chown root:root {} + || return 1
    find "$staging" -type f -exec chmod 600 {} + -exec chown root:root {} + || return 1
    (cd "$staging" && find . -type f ! -path './SHA256SUMS' -print0 | sort -z | xargs -0 sha256sum) \
        > "$staging/SHA256SUMS" || return 1
    chmod 600 "$staging/SHA256SUMS" && chown root:root "$staging/SHA256SUMS" || return 1
    while IFS= read -r -d '' temporary; do sync -f "$temporary" || return 1; done \
        < <(find "$staging" -type f -print0)
    sync -f "$staging" || return 1
    mv -T -- "$staging" "$canonical" || return 1
    sync -f "$RUN_DIR" || return 1
    verify_rollback_post_release_evidence
}

capture_exact_32_generation_map()
{
    local output="$1" node generation temporary
    temporary="${output}.tmp.$$"
    : > "$temporary" || return 1
    for node in $(seq 1 "$NODE_COUNT"); do
        generation=$(container_generation_for "$node") || { rm -f -- "$temporary"; return 1; }
        printf '%02d|%s\n' "$node" "$generation" >> "$temporary" || {
            rm -f -- "$temporary"; return 1;
        }
    done
    if ! chmod 600 "$temporary" || ! chown root:root "$temporary" || ! sync -f "$temporary"; then
        rm -f -- "$temporary"; return 1;
    fi
    mv -fT -- "$temporary" "$output" || { rm -f -- "$temporary"; return 1; }
    sync -f "$output"
}

capture_fresh_rollback_supervisor()
{
    local output="$1" released_epoch="$2" supervisor before copied after temporary
    local timestamp timestamp_epoch now owner mode deadline=$((SECONDS + 1200))
    supervisor=/mnt/pulsar/Blackcoin_Blocks/operations/fleet-supervisor-status.json
    while ((SECONDS < deadline)); do
        verify_free_claim_pause || return 1
        [[ ! -e "$ROLLOUT_MAINTENANCE_MARKER" && ! -L "$ROLLOUT_MAINTENANCE_MARKER" ]] || return 1
        if [[ -f "$supervisor" && ! -L "$supervisor" &&
              "$(realpath -e -- "$supervisor" 2>/dev/null || true)" == "$supervisor" ]]; then
            owner=$(stat -c '%u:%g' "$supervisor" 2>/dev/null || true)
            mode=$(stat -c '%a' "$supervisor" 2>/dev/null || true)
            if [[ "$owner" == 0:0 && "$mode" =~ ^[0-7]{3,4}$ ]] &&
               (( (8#$mode & 0022) == 0 )); then
                before=$(sha256sum "$supervisor" | awk '{print $1}') || before=''
                temporary=$(mktemp "${output%/*}/.supervisor.XXXXXX") || return 1
                if install -m 600 -o root -g root "$supervisor" "$temporary"; then
                    copied=$(sha256sum "$temporary" | awk '{print $1}') || copied=''
                    after=$(sha256sum "$supervisor" | awk '{print $1}') || after=''
                    timestamp=$(jq -er '.timestamp | select(type == "string")' \
                        "$temporary" 2>/dev/null || true)
                    if [[ "$timestamp" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
                        timestamp_epoch=$(date -d "$timestamp" +%s 2>/dev/null || true)
                    else
                        timestamp_epoch=''
                    fi
                    now=$(date +%s)
                    if valid_sha256_hex "$before" && [[ "$before" == "$copied" && "$before" == "$after" &&
                       "$timestamp_epoch" =~ ^[1-9][0-9]*$ ]] &&
                       ((timestamp_epoch > released_epoch && timestamp_epoch <= now &&
                         timestamp_epoch >= now - 300)) &&
                       jq -e '.state == "healthy" and .verified == 32 and .running == 32 and
                           .operational == 32 and .failures == 0' "$temporary" >/dev/null; then
                        sync -f "$temporary" || { rm -f -- "$temporary"; return 1; }
                        mv -fT -- "$temporary" "$output" || {
                            rm -f -- "$temporary"; return 1;
                        }
                        sync -f "$output" || return 1
                        return 0
                    fi
                fi
                rm -f -- "$temporary"
            fi
        fi
        ((SECONDS < deadline)) && sleep 5
    done
    return 1
}

write_rollback_finalization_ready()
{
    local attempt=1 attempt_dir ready="$RUN_DIR/ROLLBACK-FINALIZATION-READY.json"
    local result="$RUN_DIR/ROLLBACK_RESULT.json" epoch supervisor identity generations_before
    local generations_after generations_final supervisor_sha identity_sha result_sha transaction_sha
    local generations_before_sha generations_final_sha nonce timestamp timestamp_epoch
    local ready_tmp ready_sha_tmp regular_pow_active legacy_quarantined_disabled
    [[ "$(<"$RUN_DIR/STATE")" == rolled-back ]] || return 1
    valid_maintenance_released_epoch || return 1
    epoch=$(<"$(maintenance_released_epoch_path)")
    verify_free_claim_pause || return 1
    [[ ! -e "$ROLLOUT_MAINTENANCE_MARKER" && ! -L "$ROLLOUT_MAINTENANCE_MARKER" ]] || return 1
    while [[ -e "$(printf '%s/rollback-finalization-attempt-%03d' "$RUN_DIR" "$attempt")" ||
             -L "$(printf '%s/rollback-finalization-attempt-%03d' "$RUN_DIR" "$attempt")" ]]; do
        attempt=$((attempt + 1))
    done
    attempt_dir=$(printf '%s/rollback-finalization-attempt-%03d' "$RUN_DIR" "$attempt")
    install -d -m 700 -o root -g root "$attempt_dir" || return 1
    generations_before="$attempt_dir/GENERATIONS.before"
    generations_after="$attempt_dir/GENERATIONS.after"
    generations_final="$attempt_dir/GENERATIONS.before-publication"
    supervisor="$attempt_dir/SUPERVISOR-STATUS.json"
    identity="$attempt_dir/FLEET-IDENTITY.json"
    verify_all_baseline_runtime_once || return 1
    capture_exact_32_generation_map "$generations_before" || return 1
    capture_fresh_rollback_supervisor "$supervisor" "$((10#$epoch))" || return 1
    capture_exact_32_generation_map "$generations_after" || return 1
    cmp -s "$generations_before" "$generations_after" || return 1
    verify_all_baseline_runtime_once || return 1
    assert_fleet_identity_matches_baseline "$identity" || return 1
    verify_free_claim_pause || return 1
    [[ ! -e "$ROLLOUT_MAINTENANCE_MARKER" && ! -L "$ROLLOUT_MAINTENANCE_MARKER" ]] || return 1
    capture_exact_32_generation_map "$generations_final" || return 1
    cmp -s "$generations_before" "$generations_final" || return 1
    supervisor_sha=$(sha256sum "$supervisor" | awk '{print $1}') || return 1
    identity_sha=$(sha256sum "$identity" | awk '{print $1}') || return 1
    generations_before_sha=$(sha256sum "$generations_before" | awk '{print $1}') || return 1
    generations_final_sha=$(sha256sum "$generations_final" | awk '{print $1}') || return 1
    [[ "$generations_before_sha" == "$generations_final_sha" ]] || return 1
    result_sha=$(sha256sum "$result" | awk '{print $1}') || return 1
    transaction_sha=$(sha256sum "$RUN_DIR/TRANSACTION.json" | awk '{print $1}') || return 1
    nonce=$(<"$(maintenance_nonce_path)")
    valid_sha256_hex "$nonce" || return 1
    timestamp=$(jq -er '.timestamp' "$supervisor") || return 1
    timestamp_epoch=$(date -d "$timestamp" +%s) || return 1
    read -r regular_pow_active legacy_quarantined_disabled < <(legacy_restore_counts) || return 1
    ready_tmp=$(mktemp "$RUN_DIR/.rollback-finalization-ready.XXXXXX") || return 1
    jq -n --arg result passed --arg phase rollback-pre-release --arg run "$RUN_DIR" \
        --arg rollback_sha "$result_sha" --arg transaction_sha "$transaction_sha" \
        --arg supervisor_rel "${supervisor#"$RUN_DIR/"}" --arg supervisor_sha "$supervisor_sha" \
        --arg supervisor_timestamp "$timestamp" --arg identity_rel "${identity#"$RUN_DIR/"}" \
        --arg identity_sha "$identity_sha" --argjson supervisor_epoch "$timestamp_epoch" \
        --arg generations_before_rel "${generations_before#"$RUN_DIR/"}" \
        --arg generations_before_sha "$generations_before_sha" \
        --arg generations_final_rel "${generations_final#"$RUN_DIR/"}" \
        --arg generations_final_sha "$generations_final_sha" --arg nonce "$nonce" \
        --argjson released_epoch "$((10#$epoch))" \
        --argjson regular_pow_active "$regular_pow_active" \
        --argjson legacy_quarantined_disabled "$legacy_quarantined_disabled" '
        {schema:1,result:$result,phase:$phase,run_dir:$run,
         rollback_result_sha256:$rollback_sha,transaction_manifest_sha256:$transaction_sha,
         run_nonce:$nonce,
         maintenance_marker_absent:true,maintenance_released_epoch:$released_epoch,
         free_claim_broadcasts_paused:true,supervisor_evidence:$supervisor_rel,
         supervisor_status_sha256:$supervisor_sha,supervisor_timestamp:$supervisor_timestamp,
         supervisor_timestamp_epoch:$supervisor_epoch,fleet_identity_evidence:$identity_rel,
         fleet_identity_evidence_sha256:$identity_sha,nodes_healthy:32,pos_active:32,
         generation_before_evidence:$generations_before_rel,
         generation_before_sha256:$generations_before_sha,
         generation_before_publication_evidence:$generations_final_rel,
         generation_before_publication_sha256:$generations_final_sha,
         regular_pow_active:$regular_pow_active,
         legacy_quarantined_disabled:$legacy_quarantined_disabled,
         free_claim_node:30,free_claim_regular_pow:false,
         exact_32_generation_fence:true,vpn_proofs_valid_unique:32,
         baseline_identity_restored:true,claim_recovery_fee_unchanged:true,
         fee_payments_authorized:false}
    ' > "$ready_tmp" || return 1
    chmod 600 "$ready_tmp" && chown root:root "$ready_tmp" && sync -f "$ready_tmp" || return 1
    mv -fT -- "$ready_tmp" "$ready" || return 1
    ready_sha_tmp=$(mktemp "$RUN_DIR/.rollback-finalization-ready-sha.XXXXXX") || return 1
    sha256sum "$ready" | awk '{print $1}' > "$ready_sha_tmp" || return 1
    chmod 600 "$ready_sha_tmp" && chown root:root "$ready_sha_tmp" && sync -f "$ready_sha_tmp" || return 1
    mv -fT -- "$ready_sha_tmp" "$RUN_DIR/ROLLBACK-FINALIZATION-READY.sha256" || return 1
    sync -f "$RUN_DIR"
}

finalize_rolled_back_run()
{
    local inhibitor_state ready="$RUN_DIR/ROLLBACK-FINALIZATION-READY.json" release_required=0
    local resume_finalization_state
    if [[ -e "$(terminal_receipt_dir)" || -L "$(terminal_receipt_dir)" ]]; then
        trap '' HUP INT TERM
        if ! verify_terminal_receipt rolled-back 0; then
            trap 'exit 129' HUP
            trap 'exit 130' INT
            trap 'exit 143' TERM
            return 1
        fi
        TERMINAL_FINALIZED=1
        FINALIZATION_ACTIVE=0
        trap 'exit 129' HUP
        trap 'exit 130' INT
        trap 'exit 143' TERM
        verify_terminal_receipt rolled-back 1 || return 1
        return 0
    fi
    if [[ -e "$RUN_DIR/snapshot-cleanup" || -L "$RUN_DIR/snapshot-cleanup" ]]; then
        verify_snapshot_cleanup_resume_prefix || return 1
        resume_finalization_state=$(<"$(finalization_state_path)") || return 1
        case "$resume_finalization_state" in
            post-release-passed|finalized)
                verify_terminal_cleanup_prerequisites rolled-back || return 1
                if data_rollback_finalization_released; then
                    TERMINAL_COMMIT_ACTIVE=1
                    FINALIZATION_ACTIVE=0
                    cleanup_transaction_snapshots || return 1
                    write_terminal_receipt rolled-back || return 1
                    TERMINAL_COMMIT_ACTIVE=0
                    return 0
                fi
                ;;
            contained)
                # Preserve the authenticated cleanup prefix and reacquire a
                # fresh release proof through the normal state machine below.
                ;;
            *) return 1 ;;
        esac
    fi
    inhibitor_state=$(/bin/bash "$INHIBITOR_RELEASER" probe) || return 1
    case "$inhibitor_state" in
        'state=installed-and-paused cycle=v30.1.4-no-spend free_claim=paused')
            release_maintenance_for_finalization || return 1
            write_rollback_finalization_ready || return 1
            release_required=1
            ;;
        'state=installed-and-released cycle=v30.1.4-no-spend free_claim=enabled')
            [[ ! -e "$ROLLOUT_MAINTENANCE_MARKER" && ! -L "$ROLLOUT_MAINTENANCE_MARKER" ]] || {
                ensure_finalization_containment
                return 1
            }
            if ! /bin/bash "$INHIBITOR_RELEASER" verify-release \
                "$RUN_DIR/ROLLBACK_RESULT.json" "$RUN_DIR/STATE" "$ready"; then
                ensure_finalization_containment
                return 1
            fi
            ;;
        *) return 1 ;;
    esac
    if ((release_required == 1)); then
        CONFIRM_RELEASE_TRANSACTION_INHIBITORS=v30.1.4-release-free-claim-after-success \
            /bin/bash "$INHIBITOR_RELEASER" release \
            "$RUN_DIR/ROLLBACK_RESULT.json" "$RUN_DIR/STATE" "$ready" || return 1
    fi
    /bin/bash "$INHIBITOR_RELEASER" verify-release \
        "$RUN_DIR/ROLLBACK_RESULT.json" "$RUN_DIR/STATE" "$ready" || return 1
    verify_node30_free_claim_service || return 1
    write_rollback_post_release_evidence || return 1
    assert_fleet_identity_matches_baseline \
        "$RUN_DIR/rollback-final-fleet-identity.post-release.json" || return 1
    assert_free_claim_container_identity_matches_baseline \
        "$RUN_DIR/rollback-free-claim-container-identity.post-release.json" || return 1
    verify_all_baseline_runtime_once || return 1
    capture_terminal_generation_fence rolled-back || return 1
    publish_state_token "$(finalization_state_path)" post-release-passed || return 1
    verify_terminal_cleanup_prerequisites rolled-back || return 1
    data_rollback_prepare_cleanup_plan "$RUN_DIR/snapshot-cleanup" || return 1
    verify_snapshot_cleanup_resume_prefix || return 1
    data_rollback_finalization_released || return 1
    TERMINAL_COMMIT_ACTIVE=1
    FINALIZATION_ACTIVE=0
    cleanup_transaction_snapshots || return 1
    write_terminal_receipt rolled-back || return 1
    verify_terminal_receipt rolled-back || return 1
    TERMINAL_COMMIT_ACTIVE=0
}

write_rollback_success_evidence()
{
    local transaction_sha temporary result_sha sha_tmp regular_pow_active legacy_quarantined_disabled
    transaction_sha=$(sha256sum "$RUN_DIR/TRANSACTION.json" | awk '{print $1}') || return 1
    read -r regular_pow_active legacy_quarantined_disabled < <(legacy_restore_counts) || return 1
    temporary=$(mktemp "$RUN_DIR/.ROLLBACK_RESULT.XXXXXX")
    jq -n --arg transaction_sha "$transaction_sha" \
        --argjson regular_pow_active "$regular_pow_active" \
        --argjson legacy_quarantined_disabled "$legacy_quarantined_disabled" \
        '{schema:1,transaction:"v30.1.4-fleet-rollout",result:"rolled-back",
          state:"rolled-back",transaction_manifest_sha256:$transaction_sha,
          nodes_healthy:32,pos_active:32,regular_pow_active:$regular_pow_active,
          legacy_quarantined_disabled:$legacy_quarantined_disabled,free_claim_node:30,
          free_claim_regular_pow:false,free_claim_broadcasts_paused:true,
          vpn_proofs_valid_unique:32,baseline_identity_restored:true,
          claim_recovery_fee_unchanged:true,fee_payments_authorized:false,
          rollback_verified:true}' > "$temporary" || return 1
    chmod 600 "$temporary"
    chown root:root "$temporary"
    sync -f "$temporary"
    mv -fT -- "$temporary" "$RUN_DIR/ROLLBACK_RESULT.json"
    result_sha=$(sha256sum "$RUN_DIR/ROLLBACK_RESULT.json" | awk '{print $1}') || return 1
    sha_tmp=$(mktemp "$RUN_DIR/.ROLLBACK_RESULT.sha256.XXXXXX")
    printf '%s\n' "$result_sha" > "$sha_tmp"
    chmod 600 "$sha_tmp"
    chown root:root "$sha_tmp"
    sync -f "$sha_tmp"
    mv -fT -- "$sha_tmp" "$RUN_DIR/ROLLBACK_RESULT.sha256"
    sync -f "$RUN_DIR"
}

verify_current_policy_assets()
{
    assert_protected_file "$IMAGE_POLICY" 600
    assert_protected_file "$ENDPOINT_GUARD" 600
    triplet_policy_guard_valid "$IMAGE_POLICY" "$ENDPOINT_GUARD" ||
        die 'endpoint guard does not pin a valid current image policy'
}

triplet_policy_guard_valid()
{
    local policy="$1" guard="$2" policy_sha pin_sha
    [[ -f "$policy" && ! -L "$policy" && -f "$guard" && ! -L "$guard" ]] || return 1
    policy_sha=$(sha256sum "$policy" | awk '{print $1}') || return 1
    pin_sha=$(sed -n "s/^EXPECTED_IMAGE_POLICY_SHA='\([0-9a-f]\{64\}\)'$/\1/p" "$guard") || return 1
    [[ -n "$pin_sha" && "$policy_sha" == "$pin_sha" ]] || return 1
    jq -e '.schema == 1 and (.images | type == "object" and length >= 1) and
        (.nodes | type == "object" and length == 32)' "$policy" >/dev/null ||
        return 1
}

verify_live_fleet_matches_policy()
{
    local model node padded class expected_ref expected_id service container
    model=$(docker compose -f "$COMPOSE_FILE" config --format json) || return 1
    for node in $(seq 1 "$NODE_COUNT"); do
        padded=$(node_padded "$node")
        service=$(service_for "$node")
        container=$(container_for "$node")
        class=$(jq -er --arg node "$padded" '.nodes[$node]' "$IMAGE_POLICY") || return 1
        expected_ref=$(jq -er --arg class "$class" '.images[$class].config_image' "$IMAGE_POLICY") || return 1
        expected_id=$(jq -er --arg class "$class" '.images[$class].image_id' "$IMAGE_POLICY") || return 1
        jq -e --arg service "$service" --arg ref "$expected_ref" \
            '.services[$service].image == $ref' >/dev/null <<< "$model" || return 1
        [[ "$(docker inspect -f '{{.Config.Image}}' "$container")" == "$expected_ref" ]] || return 1
        [[ "$(docker inspect -f '{{.Image}}' "$container")" == "$expected_id" ]] || return 1
    done
}

verify_baseline_hashes()
{
    require_baseline_identity
    [[ "$(sha256sum "$COMPOSE_FILE" | awk '{print $1}')" == "$EXPECTED_COMPOSE_SHA256" ]] ||
        die 'live Compose bytes differ from the audited baseline'
    [[ "$(sha256sum "$IMAGE_POLICY" | awk '{print $1}')" == "$EXPECTED_IMAGE_POLICY_SHA256" ]] ||
        die 'live image-policy bytes differ from the audited baseline'
    [[ "$(sha256sum "$ENDPOINT_GUARD" | awk '{print $1}')" == "$EXPECTED_ENDPOINT_GUARD_SHA256" ]] ||
        die 'live endpoint-guard bytes differ from the audited baseline'
    [[ "$(sha256sum "$WALLET_RUNTIME_GUARD" | awk '{print $1}')" == \
       "$EXPECTED_WALLET_RUNTIME_GUARD_SHA256" ]] ||
        die 'live wallet-runtime-guard bytes differ from the audited compatible baseline'
}

require_baseline_identity()
{
    : "${EXPECTED_COMPOSE_SHA256:?EXPECTED_COMPOSE_SHA256 is required}"
    : "${EXPECTED_IMAGE_POLICY_SHA256:?EXPECTED_IMAGE_POLICY_SHA256 is required}"
    : "${EXPECTED_ENDPOINT_GUARD_SHA256:?EXPECTED_ENDPOINT_GUARD_SHA256 is required}"
    : "${EXPECTED_WALLET_RUNTIME_GUARD_SHA256:?EXPECTED_WALLET_RUNTIME_GUARD_SHA256 is required}"
    valid_sha256_hex "$EXPECTED_COMPOSE_SHA256" || die 'expected Compose hash is malformed'
    valid_sha256_hex "$EXPECTED_IMAGE_POLICY_SHA256" || die 'expected policy hash is malformed'
    valid_sha256_hex "$EXPECTED_ENDPOINT_GUARD_SHA256" || die 'expected endpoint-guard hash is malformed'
    valid_sha256_hex "$EXPECTED_WALLET_RUNTIME_GUARD_SHA256" ||
        die 'expected wallet-runtime-guard hash is malformed'
}

verify_resume_run()
{
    local result state wave wave_name wave_index node
    local -a resume_wave_nodes=()
    valid_rollout_run_dir "$RUN_DIR" ||
        die 'resume directory is unsafe or outside the rollout root'
    [[ -f "$RUN_DIR/STATE" && ! -L "$RUN_DIR/STATE" ]] || die 'resume run state is unsafe'
    state=$(cat "$RUN_DIR/STATE")
    [[ "$state" == prepared || "$state" == applying || "$state" == complete ]] ||
        die 'resume run is not in a prepared, applying, or finalization-eligible complete state'
    [[ -d "$RUN_DIR/baseline" && ! -L "$RUN_DIR/baseline" ]] || die 'resume baseline is absent'
    for file in docker-compose.yml fleet-image-policy.json blackcoin_endpoint_guard.sh \
        blackcoin_wallet_runtime_guard.sh blackcoin_node_normal_unlock.sh blackcoin_pow_start_only.sh \
        fleet-identity.json free-claim-status.json free-claim-container-identity.json \
        LEGACY-POW-INITIAL.json SHA256SUMS; do
        [[ -f "$RUN_DIR/baseline/$file" && ! -L "$RUN_DIR/baseline/$file" ]] ||
            die "resume baseline file is absent or unsafe: $file"
    done
    for node in $(seq 1 "$NODE_COUNT"); do
        [[ -f "$RUN_DIR/baseline/legacy-node-$(node_padded "$node")-pow.json" &&
           ! -L "$RUN_DIR/baseline/legacy-node-$(node_padded "$node")-pow.json" ]] ||
            die "resume legacy PoW baseline is absent for node $node"
    done
    (cd "$RUN_DIR/baseline" && sha256sum --strict -c SHA256SUMS >/dev/null) ||
        die 'resume baseline evidence checksum failed'
    [[ "$(sha256sum "$RUN_DIR/baseline/docker-compose.yml" | awk '{print $1}')" == \
       "$EXPECTED_COMPOSE_SHA256" ]] || die 'resume Compose baseline differs from the audited bytes'
    [[ "$(sha256sum "$RUN_DIR/baseline/fleet-image-policy.json" | awk '{print $1}')" == \
       "$EXPECTED_IMAGE_POLICY_SHA256" ]] || die 'resume policy baseline differs from the audited bytes'
    [[ "$(sha256sum "$RUN_DIR/baseline/blackcoin_endpoint_guard.sh" | awk '{print $1}')" == \
       "$EXPECTED_ENDPOINT_GUARD_SHA256" ]] || die 'resume guard baseline differs from the audited bytes'
    [[ "$(sha256sum "$RUN_DIR/baseline/blackcoin_wallet_runtime_guard.sh" | awk '{print $1}')" == \
       "$EXPECTED_WALLET_RUNTIME_GUARD_SHA256" ]] ||
        die 'resume wallet runtime guard differs from the audited compatible bytes'
    [[ "$(sha256sum "$RUN_DIR/baseline/blackcoin_node_normal_unlock.sh" | awk '{print $1}')" == \
       "$NORMAL_UNLOCK_HELPER_SHA256" ]] || die 'resume unlock helper differs from audited bytes'
    [[ "$(sha256sum "$RUN_DIR/baseline/blackcoin_pow_start_only.sh" | awk '{print $1}')" == \
       "$POW_START_HELPER_SHA256" ]] || die 'resume PoW helper differs from audited bytes'
    assert_empty_control_marker "$ENABLE_GUARD_STARTS" ||
        die 'live guard-start authority marker is absent, nonempty, or unsafe during resume'
    verify_transaction_manifest || die 'resume transaction identity or package bytes changed'
    while IFS= read -r wave; do
        wave_name=${wave##*/}
        [[ "$wave_name" =~ ^wave-([0-9]{2})-nodes- ]] ||
            die "resume contains an invalid wave directory: $wave"
        wave_index=$((10#${BASH_REMATCH[1]}))
        verify_wave_evidence_manifest "$wave" "$wave_index" ||
            die "resume wave evidence or node identity changed: $wave"
        CURRENT_WAVE_DIR="$wave"
        read -r -a resume_wave_nodes < "$wave/NODES"
        if [[ -f "$wave/RESULT" && ! -L "$wave/RESULT" ]]; then
            result=$(cat "$wave/RESULT")
            [[ "$result" == passed || "$result" == rolled-back ]] ||
                die "resume contains an invalid wave result: $wave"
            if [[ "$result" == passed ]]; then
                CURRENT_WAVE_NODES=("${resume_wave_nodes[@]}")
                verify_wave_runtime_evidence ||
                    die "resume passed-wave runtime evidence changed: $wave"
            fi
        else
            [[ -f "$wave/COMMIT_STATE" && ! -L "$wave/COMMIT_STATE" ]] ||
                die "resume contains an unauthenticated unterminated wave: $wave"
        fi
    done < <(find "$RUN_DIR" -maxdepth 1 -type d -name 'wave-*' -print | sort)
}

single_interrupted_wave()
{
    local wave found='' count=0
    while IFS= read -r wave; do
        [[ -f "$wave/RESULT" || -L "$wave/RESULT" ]] && continue
        [[ -f "$wave/COMMIT_STATE" && ! -L "$wave/COMMIT_STATE" ]] || continue
        found="$wave"
        count=$((count + 1))
    done < <(find "$RUN_DIR" -mindepth 1 -maxdepth 1 -type d -name 'wave-*' -print | sort)
    if ((count > 1)); then
        printf '%s\n' __MULTIPLE_INTERRUPTED_WAVES__
        return 0
    fi
    [[ "$count" -eq 1 ]] && printf '%s\n' "$found"
    return 0
}

live_file_matches_wave_generation()
{
    local live="$1" before="$2" candidate="$3" actual before_sha candidate_sha
    [[ -f "$live" && ! -L "$live" && -f "$before" && ! -L "$before" &&
       -f "$candidate" && ! -L "$candidate" ]] || return 1
    actual=$(sha256sum "$live" | awk '{print $1}') || return 1
    before_sha=$(sha256sum "$before" | awk '{print $1}') || return 1
    candidate_sha=$(sha256sum "$candidate" | awk '{print $1}') || return 1
    [[ "$actual" == "$before_sha" || "$actual" == "$candidate_sha" ]]
}

candidate_launch_authorization_manifest_valid()
{
    local marker="$CURRENT_WAVE_DIR/CANDIDATE_LAUNCH_AUTHORIZED" node expected_names actual_names
    [[ -f "$marker" && ! -L "$marker" && "$(realpath -e -- "$marker")" == "$marker" &&
       "$(stat -c '%u:%g:%a' "$marker")" == 0:0:600 ]] || return 1
    expected_names=$(for node in "${CURRENT_WAVE_NODES[@]}"; do
        basename -- "$(wave_node_launch_authorization_path "$node")"
    done | sort) || return 1
    actual_names=$(awk 'NF == 2 && $1 ~ /^[0-9a-f]{64}$/ &&
        $2 ~ /^node-[0-9]{2}-CANDIDATE-LAUNCH-AUTHORIZED[.]json$/ {print $2}' \
        "$marker" | sort) || return 1
    [[ -n "$expected_names" && "$(wc -l < "$marker")" -eq "${#CURRENT_WAVE_NODES[@]}" &&
       "$actual_names" == "$expected_names" ]] || return 1
    (cd "$CURRENT_WAVE_DIR" && sha256sum --strict -c "${marker##*/}" >/dev/null)
}

candidate_launch_attempt_manifest_valid()
{
    local marker="$CURRENT_WAVE_DIR/CANDIDATE_LAUNCH_ATTEMPTED" node expected_names actual_names
    [[ -f "$marker" && ! -L "$marker" && "$(realpath -e -- "$marker")" == "$marker" &&
       "$(stat -c '%u:%g:%a' "$marker")" == 0:0:600 ]] || return 1
    expected_names=$(for node in "${CURRENT_WAVE_NODES[@]}"; do
        basename -- "$(wave_node_launch_attempt_path "$node")"
    done | sort) || return 1
    actual_names=$(awk 'NF == 2 && $1 ~ /^[0-9a-f]{64}$/ &&
        $2 ~ /^node-[0-9]{2}-CANDIDATE-LAUNCH-ATTEMPTED[.]json$/ {print $2}' \
        "$marker" | sort) || return 1
    [[ -n "$expected_names" && "$(wc -l < "$marker")" -eq "${#CURRENT_WAVE_NODES[@]}" &&
       "$actual_names" == "$expected_names" ]] || return 1
    (cd "$CURRENT_WAVE_DIR" && sha256sum --strict -c "${marker##*/}" >/dev/null)
}

candidate_launch_evidence_present()
{
    find "$CURRENT_WAVE_DIR" -maxdepth 1 \
        \( -type f -o -type l \) -name 'node-*-CANDIDATE-LAUNCH-ATTEMPTED.json' \
        -print -quit | grep -q .
}

verify_candidate_launch_authorization_marker()
{
    local node="$1" verify_live=${2:-0} path transaction_sha drain_sha inventory_sha
    local generation inspect
    [[ "$verify_live" == 0 || "$verify_live" == 1 ]] || return 1
    path=$(wave_node_launch_authorization_path "$node") || return 1
    [[ -f "$path" && ! -L "$path" && "$(realpath -e -- "$path")" == "$path" &&
       "$(stat -c '%u:%g:%a' "$path")" == 0:0:600 ]] || return 1
    transaction_sha=$(sha256sum "$RUN_DIR/TRANSACTION.json" | awk '{print $1}') || return 1
    drain_sha=$(sha256sum "$(wave_drain_manifest_path)" | awk '{print $1}') || return 1
    inventory_sha=$(sha256sum "$CURRENT_WAVE_DIR/data-snapshots.tsv" | awk '{print $1}') || return 1
    [[ "$(cat "$CURRENT_WAVE_DIR/data-snapshots.tsv.sha256")" == "$inventory_sha" ]] || return 1
    generation=$(jq -er '.prelaunch_stopped_generation' "$path") || return 1
    data_rollback_validate_stopped_generation "$generation" || return 1
    [[ "$generation" == "$(expected_prelaunch_generation "$node")" ]] || return 1
    jq -e --argjson node "$node" --arg run "$RUN_DIR" --arg wave "$CURRENT_WAVE_DIR" \
        --arg service "$(service_for "$node")" --arg container "$(container_for "$node")" \
        --arg candidate_image "$CANDIDATE_IMAGE_REF" --arg candidate_id "$CANDIDATE_IMAGE_ID" \
        --arg transaction_sha "$transaction_sha" --arg drain_sha "$drain_sha" \
        --arg inventory_sha "$inventory_sha" --arg generation "$generation" '
        (keys | sort) == (["schema","transaction","boundary","candidate_launch_authorized",
          "candidate_launch_attempted","node","run_dir","wave_dir","service","container",
          "candidate_image","candidate_image_id","prelaunch_config_image","prelaunch_image_id",
          "prelaunch_stopped_generation","transaction_manifest_sha256",
          "wave_drain_manifest_sha256","snapshot_inventory_sha256",
          "fee_payments_authorized","created_at"] | sort) and
        .schema == 1 and .transaction == "v30.1.4-fleet-rollout" and
        .boundary == "before-wave-candidate-launches" and
        .candidate_launch_authorized == true and .candidate_launch_attempted == false and
        .node == $node and .run_dir == $run and .wave_dir == $wave and
        .service == $service and .container == $container and
        .candidate_image == $candidate_image and .candidate_image_id == $candidate_id and
        (.prelaunch_config_image | type) == "string" and (.prelaunch_config_image | length) > 0 and
        (.prelaunch_image_id | type) == "string" and
        (.prelaunch_image_id | test("^sha256:[0-9a-f]{64}$")) and
        .prelaunch_stopped_generation == $generation and
        .transaction_manifest_sha256 == $transaction_sha and
        .wave_drain_manifest_sha256 == $drain_sha and
        .snapshot_inventory_sha256 == $inventory_sha and
        .fee_payments_authorized == false and (.created_at | type) == "string"
    ' "$path" >/dev/null || return 1
    if [[ "$verify_live" == 1 ]]; then
        [[ "$(container_generation_for "$node")" == "$generation" ]] || return 1
        inspect=$(docker inspect "$(container_for "$node")") || return 1
        jq -e --arg config_image "$(jq -er '.prelaunch_config_image' "$path")" \
            --arg image_id "$(jq -er '.prelaunch_image_id' "$path")" '
            length == 1 and .[0].State.Running == false and .[0].State.Pid == 0 and
            .[0].State.Restarting == false and .[0].Config.Image == $config_image and
            .[0].Image == $image_id
        ' >/dev/null <<< "$inspect" || return 1
        [[ "$(container_generation_for "$node")" == "$generation" ]] || return 1
    fi
}

verify_candidate_launch_attempt_marker()
{
    local node="$1" verify_live=${2:-0} path authorization authorization_sha
    local transaction_sha drain_sha inventory_sha generation candidate_generation inspect
    [[ "$verify_live" == 0 || "$verify_live" == 1 ]] || return 1
    authorization=$(wave_node_launch_authorization_path "$node") || return 1
    verify_candidate_launch_authorization_marker "$node" 0 || return 1
    authorization_sha=$(sha256sum "$authorization" | awk '{print $1}') || return 1
    path=$(wave_node_launch_attempt_path "$node") || return 1
    [[ -f "$path" && ! -L "$path" && "$(realpath -e -- "$path")" == "$path" &&
       "$(stat -c '%u:%g:%a' "$path")" == 0:0:600 ]] || return 1
    transaction_sha=$(sha256sum "$RUN_DIR/TRANSACTION.json" | awk '{print $1}') || return 1
    drain_sha=$(sha256sum "$(wave_drain_manifest_path)" | awk '{print $1}') || return 1
    inventory_sha=$(sha256sum "$CURRENT_WAVE_DIR/data-snapshots.tsv" | awk '{print $1}') || return 1
    generation=$(jq -er '.prelaunch_stopped_generation' "$authorization") || return 1
    candidate_generation=$(jq -er '.candidate_stopped_generation' "$path") || return 1
    data_rollback_validate_stopped_generation "$candidate_generation" || return 1
    jq -e --argjson node "$node" --arg run "$RUN_DIR" --arg wave "$CURRENT_WAVE_DIR" \
        --arg service "$(service_for "$node")" --arg container "$(container_for "$node")" \
        --arg candidate_image "$CANDIDATE_IMAGE_REF" --arg candidate_id "$CANDIDATE_IMAGE_ID" \
        --arg config_image "$(jq -er '.prelaunch_config_image' "$authorization")" \
        --arg image_id "$(jq -er '.prelaunch_image_id' "$authorization")" \
        --arg generation "$generation" --arg authorization_sha "$authorization_sha" \
        --arg transaction_sha "$transaction_sha" --arg drain_sha "$drain_sha" \
        --arg inventory_sha "$inventory_sha" --arg candidate_generation "$candidate_generation" '
        (keys | sort) == (["schema","transaction","boundary","candidate_launch_attempted",
          "node","run_dir","wave_dir","service","container","candidate_image",
          "candidate_image_id","launch_authorization_sha256","prelaunch_config_image",
          "prelaunch_image_id","prelaunch_stopped_generation","candidate_stopped_generation",
          "transaction_manifest_sha256",
          "wave_drain_manifest_sha256","snapshot_inventory_sha256",
          "fee_payments_authorized","created_at"] | sort) and
        .schema == 1 and .transaction == "v30.1.4-fleet-rollout" and
        .boundary == "immediately-before-node-candidate-launch" and
        .candidate_launch_attempted == true and .node == $node and
        .run_dir == $run and .wave_dir == $wave and .service == $service and
        .container == $container and .candidate_image == $candidate_image and
        .candidate_image_id == $candidate_id and
        .launch_authorization_sha256 == $authorization_sha and
        .prelaunch_config_image == $config_image and .prelaunch_image_id == $image_id and
        .prelaunch_stopped_generation == $generation and
        .candidate_stopped_generation == $candidate_generation and
        .transaction_manifest_sha256 == $transaction_sha and
        .wave_drain_manifest_sha256 == $drain_sha and
        .snapshot_inventory_sha256 == $inventory_sha and
        .fee_payments_authorized == false and (.created_at | type) == "string"
    ' "$path" >/dev/null || return 1
    if [[ "$verify_live" == 1 ]]; then
        [[ "$(container_generation_for "$node")" == "$candidate_generation" ]] || return 1
        inspect=$(docker inspect "$(container_for "$node")") || return 1
        jq -e --arg image "$CANDIDATE_IMAGE_REF" --arg id "$CANDIDATE_IMAGE_ID" '
            length == 1 and .[0].State.Running == false and .[0].State.Pid == 0 and
            .[0].State.Restarting == false and .[0].Config.Image == $image and .[0].Image == $id
        ' >/dev/null <<< "$inspect" || return 1
        [[ "$(container_generation_for "$node")" == "$candidate_generation" ]] || return 1
    fi
}

verify_wave_candidate_launch_authorizations()
{
    local verify_live=${1:-0} node count=0 actual_count
    [[ "$verify_live" == 0 || "$verify_live" == 1 ]] || return 1
    candidate_launch_authorization_manifest_valid || return 1
    for node in "${CURRENT_WAVE_NODES[@]}"; do
        verify_candidate_launch_authorization_marker "$node" "$verify_live" || return 1
        count=$((count + 1))
    done
    ! find "$CURRENT_WAVE_DIR" -maxdepth 1 -type l \
        -name 'node-*-CANDIDATE-LAUNCH-AUTHORIZED.json' -print -quit | grep -q . || return 1
    actual_count=$(find "$CURRENT_WAVE_DIR" -maxdepth 1 -type f \
        -name 'node-*-CANDIDATE-LAUNCH-AUTHORIZED.json' -print | wc -l) || return 1
    [[ "$count" -eq "${#CURRENT_WAVE_NODES[@]}" && "$actual_count" -eq "$count" ]]
}

verify_wave_candidate_launch_markers()
{
    local verify_live=${1:-0} node path count=0 actual_count
    [[ "$verify_live" == 0 || "$verify_live" == 1 ]] || return 1
    verify_wave_candidate_launch_authorizations 0 || return 1
    ! find "$CURRENT_WAVE_DIR" -maxdepth 1 -type l \
        -name 'node-*-CANDIDATE-LAUNCH-ATTEMPTED.json' -print -quit | grep -q . || return 1
    for node in "${CURRENT_WAVE_NODES[@]}"; do
        path=$(wave_node_launch_attempt_path "$node") || return 1
        if [[ -e "$path" || -L "$path" ]]; then
            verify_candidate_launch_attempt_marker "$node" "$verify_live" || return 1
            count=$((count + 1))
        fi
    done
    actual_count=$(find "$CURRENT_WAVE_DIR" -maxdepth 1 -type f \
        -name 'node-*-CANDIDATE-LAUNCH-ATTEMPTED.json' -print | wc -l) || return 1
    [[ "$actual_count" -eq "$count" ]] || return 1
    if [[ -e "$CURRENT_WAVE_DIR/CANDIDATE_LAUNCH_ATTEMPTED" ||
          -L "$CURRENT_WAVE_DIR/CANDIDATE_LAUNCH_ATTEMPTED" ]]; then
        candidate_launch_attempt_manifest_valid || return 1
        [[ "$count" -eq "${#CURRENT_WAVE_NODES[@]}" ]] || return 1
    fi
}

verify_complete_wave_candidate_launch_markers()
{
    local node
    verify_wave_candidate_launch_markers 0 || return 1
    candidate_launch_attempt_manifest_valid || return 1
    for node in "${CURRENT_WAVE_NODES[@]}"; do
        verify_candidate_launch_attempt_marker "$node" 0 || return 1
    done
}

publish_wave_candidate_launch_authorizations()
{
    local node path generation inspect config_image image_id transaction_sha drain_sha inventory_sha
    local marker="$CURRENT_WAVE_DIR/CANDIDATE_LAUNCH_AUTHORIZED" temporary
    [[ ! -e "$marker" && ! -L "$marker" ]] || return 1
    for node in "${CURRENT_WAVE_NODES[@]}"; do
        path=$(wave_node_launch_authorization_path "$node") || return 1
        [[ ! -e "$path" && ! -L "$path" ]] || return 1
    done
    verify_wave_drain_evidence || return 1
    verify_wave_snapshot_inventory || return 1
    transaction_sha=$(sha256sum "$RUN_DIR/TRANSACTION.json" | awk '{print $1}') || return 1
    drain_sha=$(sha256sum "$(wave_drain_manifest_path)" | awk '{print $1}') || return 1
    inventory_sha=$(sha256sum "$CURRENT_WAVE_DIR/data-snapshots.tsv" | awk '{print $1}') || return 1
    for node in "${CURRENT_WAVE_NODES[@]}"; do
        path=$(wave_node_launch_authorization_path "$node") || return 1
        generation=$(container_generation_for "$node") || return 1
        data_rollback_validate_stopped_generation "$generation" || return 1
        [[ "$generation" == "$(expected_prelaunch_generation "$node")" ]] || return 1
        inspect=$(docker inspect "$(container_for "$node")") || return 1
        jq -e 'length == 1 and .[0].State.Running == false and .[0].State.Pid == 0 and
            .[0].State.Restarting == false' >/dev/null <<< "$inspect" || return 1
        config_image=$(jq -er '.[0].Config.Image' <<< "$inspect") || return 1
        image_id=$(jq -er '.[0].Image | select(test("^sha256:[0-9a-f]{64}$"))' \
            <<< "$inspect") || return 1
        [[ "$(container_generation_for "$node")" == "$generation" ]] || return 1
        jq -n --argjson node "$node" --arg run "$RUN_DIR" --arg wave "$CURRENT_WAVE_DIR" \
            --arg service "$(service_for "$node")" --arg container "$(container_for "$node")" \
            --arg candidate_image "$CANDIDATE_IMAGE_REF" --arg candidate_id "$CANDIDATE_IMAGE_ID" \
            --arg config_image "$config_image" --arg image_id "$image_id" \
            --arg generation "$generation" --arg transaction_sha "$transaction_sha" \
            --arg drain_sha "$drain_sha" --arg inventory_sha "$inventory_sha" \
            --arg created_at "$(date -u +%FT%TZ)" '
            {schema:1,transaction:"v30.1.4-fleet-rollout",boundary:"before-wave-candidate-launches",
             candidate_launch_authorized:true,candidate_launch_attempted:false,node:$node,
             run_dir:$run,wave_dir:$wave,service:$service,container:$container,
             candidate_image:$candidate_image,candidate_image_id:$candidate_id,
             prelaunch_config_image:$config_image,prelaunch_image_id:$image_id,
             prelaunch_stopped_generation:$generation,
             transaction_manifest_sha256:$transaction_sha,wave_drain_manifest_sha256:$drain_sha,
             snapshot_inventory_sha256:$inventory_sha,fee_payments_authorized:false,
             created_at:$created_at}' | atomic_write_json "$path" || return 1
        verify_candidate_launch_authorization_marker "$node" 1 || return 1
    done
    temporary=$(mktemp "$CURRENT_WAVE_DIR/.candidate-launch-authorized.XXXXXX") || return 1
    (
        cd "$CURRENT_WAVE_DIR"
        for node in "${CURRENT_WAVE_NODES[@]}"; do
            sha256sum -- "$(basename -- "$(wave_node_launch_authorization_path "$node")")" || exit 1
        done
    ) > "$temporary" || { rm -f -- "$temporary"; return 1; }
    if ! chmod 600 "$temporary" || ! chown root:root "$temporary" ||
       ! sync -f "$temporary" || ! ln -- "$temporary" "$marker"; then
        rm -f -- "$temporary"
        return 1
    fi
    rm -f -- "$temporary"
    sync -f "$CURRENT_WAVE_DIR" || return 1
    verify_wave_candidate_launch_authorizations 1
}

publish_candidate_launch_attempt_marker()
{
    local node="$1" path authorization authorization_sha candidate_generation
    path=$(wave_node_launch_attempt_path "$node") || return 1
    if [[ -e "$path" || -L "$path" ]]; then
        verify_candidate_launch_attempt_marker "$node" 0
        return
    fi
    verify_candidate_launch_authorization_marker "$node" 0 || return 1
    authorization=$(wave_node_launch_authorization_path "$node") || return 1
    authorization_sha=$(sha256sum "$authorization" | awk '{print $1}') || return 1
    candidate_generation=$(container_generation_for "$node") || return 1
    data_rollback_validate_stopped_generation "$candidate_generation" || return 1
    verify_candidate_stopped_container_contract "$node" "$candidate_generation" || return 1
    [[ "$(container_generation_for "$node")" == "$candidate_generation" ]] || return 1
    jq -n --argjson node "$node" --arg run "$RUN_DIR" --arg wave "$CURRENT_WAVE_DIR" \
        --arg service "$(service_for "$node")" --arg container "$(container_for "$node")" \
        --arg candidate_image "$CANDIDATE_IMAGE_REF" --arg candidate_id "$CANDIDATE_IMAGE_ID" \
        --arg authorization_sha "$authorization_sha" \
        --arg config_image "$(jq -er '.prelaunch_config_image' "$authorization")" \
        --arg image_id "$(jq -er '.prelaunch_image_id' "$authorization")" \
        --arg generation "$(jq -er '.prelaunch_stopped_generation' "$authorization")" \
        --arg candidate_generation "$candidate_generation" \
        --arg transaction_sha "$(jq -er '.transaction_manifest_sha256' "$authorization")" \
        --arg drain_sha "$(jq -er '.wave_drain_manifest_sha256' "$authorization")" \
        --arg inventory_sha "$(jq -er '.snapshot_inventory_sha256' "$authorization")" \
        --arg created_at "$(date -u +%FT%TZ)" '
        {schema:1,transaction:"v30.1.4-fleet-rollout",
         boundary:"immediately-before-node-candidate-launch",candidate_launch_attempted:true,
         node:$node,run_dir:$run,wave_dir:$wave,service:$service,container:$container,
         candidate_image:$candidate_image,candidate_image_id:$candidate_id,
         launch_authorization_sha256:$authorization_sha,prelaunch_config_image:$config_image,
         prelaunch_image_id:$image_id,prelaunch_stopped_generation:$generation,
         candidate_stopped_generation:$candidate_generation,
         transaction_manifest_sha256:$transaction_sha,wave_drain_manifest_sha256:$drain_sha,
         snapshot_inventory_sha256:$inventory_sha,fee_payments_authorized:false,
         created_at:$created_at}' | atomic_write_json "$path" || return 1
    sync -f "$CURRENT_WAVE_DIR" || return 1
    verify_candidate_launch_attempt_marker "$node" 1
}

publish_complete_candidate_launch_manifest()
{
    local node marker="$CURRENT_WAVE_DIR/CANDIDATE_LAUNCH_ATTEMPTED" temporary
    [[ ! -e "$marker" && ! -L "$marker" ]] || {
        candidate_launch_attempt_manifest_valid
        return
    }
    for node in "${CURRENT_WAVE_NODES[@]}"; do
        verify_candidate_launch_attempt_marker "$node" 0 || return 1
    done
    temporary=$(mktemp "$CURRENT_WAVE_DIR/.candidate-launch-attempted.XXXXXX") || return 1
    (
        cd "$CURRENT_WAVE_DIR"
        for node in "${CURRENT_WAVE_NODES[@]}"; do
            sha256sum -- "$(basename -- "$(wave_node_launch_attempt_path "$node")")" || exit 1
        done
    ) > "$temporary" || { rm -f -- "$temporary"; return 1; }
    if ! chmod 600 "$temporary" || ! chown root:root "$temporary" ||
       ! sync -f "$temporary" || ! ln -- "$temporary" "$marker"; then
        rm -f -- "$temporary"
        return 1
    fi
    rm -f -- "$temporary"
    sync -f "$CURRENT_WAVE_DIR" || return 1
    verify_complete_wave_candidate_launch_markers
}

expected_old_container_id()
{
    local node="$1" id
    id=$(jq -er --argjson node "$node" \
        '.[] | select(.node == $node) | .container_id' \
        "$RUN_DIR/baseline/fleet-identity.json") || return 1
    [[ "$id" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\n' "$id"
}

expected_prelaunch_generation()
{
    local node="$1" fields
    data_rollback_protected_file "$CURRENT_WAVE_DIR/candidate-launch-sources.json" 600 || return 1
    verify_sealed_wave_evidence_files || return 1
    fields=$(jq -er --argjson node "$node" '
        [.[] | select(.node == $node)] as $rows |
        select(($rows | length) == 1) |
        $rows[0].container_generation |
        select(type == "string" and length > 0)
    ' "$CURRENT_WAVE_DIR/candidate-launch-sources.json") || return 1
    data_rollback_validate_stopped_generation "$fields" || return 1
    printf '%s\n' "$fields"
}

verify_prelaunch_source_node()
{
    local node="$1" require_stopped="$2" generation inspect old_ref old_id
    [[ "$require_stopped" == true || "$require_stopped" == false ]] || return 1
    generation=$(expected_prelaunch_generation "$node") || return 1
    [[ "$(container_generation_for "$node")" == "$generation" ]] || return 1
    verify_interrupted_target_container "$node" || return 1
    old_ref=$(rollback_old_config_image_for "$node") || return 1
    old_id=$(rollback_old_image_id_for "$node") || return 1
    inspect=$(docker inspect "$(container_for "$node")") || return 1
    jq -e --arg ref "$old_ref" --arg id "$old_id" --argjson require_stopped "$require_stopped" '
        length == 1 and .[0].Config.Image == $ref and .[0].Image == $id and
        .[0].State.Restarting == false and .[0].State.Paused == false and
        (if $require_stopped then .[0].State.Running == false and .[0].State.Pid == 0
         else ((.[0].State.Running == true and .[0].State.Pid > 0) or
               (.[0].State.Running == false and .[0].State.Pid == 0)) end)
    ' >/dev/null <<< "$inspect" || return 1
    [[ "$(container_generation_for "$node")" == "$generation" ]]
}

verify_prelaunch_candidate_authorization_prefix()
{
    local marker="$CURRENT_WAVE_DIR/CANDIDATE_LAUNCH_AUTHORIZED" node path count=0 actual_count
    local require_stopped=false
    [[ ! -e "$marker" && ! -L "$marker" &&
       ! -e "$CURRENT_WAVE_DIR/CANDIDATE_LAUNCH_ATTEMPTED" &&
       ! -L "$CURRENT_WAVE_DIR/CANDIDATE_LAUNCH_ATTEMPTED" ]] || return 1
    ! candidate_launch_evidence_present || return 1
    ! find "$CURRENT_WAVE_DIR" -maxdepth 1 -type l \
        -name 'node-*-CANDIDATE-LAUNCH-AUTHORIZED.json' -print -quit | grep -q . || return 1
    actual_count=$(find "$CURRENT_WAVE_DIR" -maxdepth 1 -type f \
        -name 'node-*-CANDIDATE-LAUNCH-AUTHORIZED.json' -print | wc -l) || return 1
    ((actual_count == 0)) || require_stopped=true
    for node in "${CURRENT_WAVE_NODES[@]}"; do
        verify_prelaunch_source_node "$node" "$require_stopped" || return 1
        path=$(wave_node_launch_authorization_path "$node") || return 1
        if [[ -e "$path" || -L "$path" ]]; then
            verify_candidate_launch_authorization_marker "$node" 1 || return 1
            [[ "$(jq -er '.prelaunch_stopped_generation' "$path")" == \
               "$(expected_prelaunch_generation "$node")" ]] || return 1
            count=$((count + 1))
        fi
    done
    [[ "$actual_count" -eq "$count" ]]
}

absent_target_state_safe()
{
    local node="$1" authorization source_generation source_id source_started vpn_id vpn_started
    local container service vpn old_id ids inventory vpn_pid vpn_netns data blocks cmdline cwd fd link
    local process process_comm exe process_netns cgroup
    authorization=$(wave_node_launch_authorization_path "$node") || return 1
    verify_candidate_launch_authorization_marker "$node" 0 || return 1
    source_generation=$(jq -er '.prelaunch_stopped_generation' "$authorization") || return 1
    verify_rollback_vpn_generation "$node" "$source_generation" || return 1
    IFS='|' read -r source_id source_started vpn_id vpn_started <<< "$source_generation" ||
        return 1
    [[ "$source_id" =~ ^[0-9a-f]{64}$ && -n "$source_started" &&
       "$vpn_id" =~ ^[0-9a-f]{64}$ && -n "$vpn_started" ]] || return 1
    container=$(container_for "$node") || return 1
    service=$(service_for "$node") || return 1
    vpn=$(vpn_for "$node") || return 1
    old_id=$(expected_old_container_id "$node") || return 1
    data=$(host_datadir_for "$node") || return 1
    blocks=$(host_blocks_for "$node") || return 1
    ! docker container inspect "$container" >/dev/null 2>&1 || return 1
    ! docker container inspect "$source_id" >/dev/null 2>&1 || return 1
    ! docker container inspect "$old_id" >/dev/null 2>&1 || return 1
    ids=$(docker ps -aq --no-trunc) || return 1
    if [[ -n "$ids" ]]; then
        # shellcheck disable=SC2086
        inventory=$(docker inspect $ids) || return 1
    else
        inventory='[]'
    fi
    jq -e --arg source_id "$source_id" --arg old_id "$old_id" \
        --arg name "/$container" --arg service "$service" \
        --arg data "$data" --arg blocks "$blocks" '
        type == "array" and all(.[];
          .Id != $source_id and .Id != $old_id and .Name != $name and
          ((.Config.Labels["com.docker.compose.service"] // "") != $service) and
          ([.Mounts[]? | select(.Source == $data or .Source == $blocks)] | length) == 0)
    ' >/dev/null <<< "$inventory" || return 1
    vpn_pid=$(docker inspect -f '{{.State.Pid}}' "$vpn") || return 1
    [[ "$vpn_pid" =~ ^[1-9][0-9]*$ ]] || return 1
    vpn_netns=$(readlink "/proc/$vpn_pid/ns/net") || return 1
    [[ -n "$vpn_netns" ]] || return 1
    for process in /proc/[0-9]*; do
        [[ -d "$process" ]] || continue
        process_comm=$(cat "$process/comm" 2>/dev/null || true)
        exe=$(readlink "$process/exe" 2>/dev/null || true)
        case "$process_comm|${exe##*/}" in
            blackcoind\|*|blackcoin-qt\|*|*\|blackcoind|*\|blackcoin-qt|\
            *\|blackcoind\ \(deleted\)|*\|blackcoin-qt\ \(deleted\))
                process_netns=$(readlink "$process/ns/net" 2>/dev/null || true)
                [[ -z "$process_netns" || "$process_netns" != "$vpn_netns" ]] || return 1
                cmdline=$(tr '\0' '\n' < "$process/cmdline" 2>/dev/null || true)
                cwd=$(readlink "$process/cwd" 2>/dev/null || true)
                if [[ "$cmdline" == *"$data"* || "$cmdline" == *"$blocks"* ||
                      "$cwd" == "$data" || "$cwd" == "$data"/* ||
                      "$cwd" == "$blocks" || "$cwd" == "$blocks"/* ]]; then
                    return 1
                fi
                for fd in "$process"/fd/*; do
                    [[ -e "$fd" || -L "$fd" ]] || continue
                    link=$(readlink "$fd" 2>/dev/null || true)
                    if [[ "$link" == "$data" || "$link" == "$data"/* ||
                          "$link" == "$blocks" || "$link" == "$blocks"/* ]]; then
                        return 1
                    fi
                done
                ;;
        esac
        cgroup="$process/cgroup"
        if [[ -r "$cgroup" ]]; then
            ! grep -Fq -- "$source_id" "$cgroup" || return 1
            ! grep -Fq -- "$old_id" "$cgroup" || return 1
        fi
    done
    ! docker container inspect "$container" >/dev/null 2>&1 || return 1
    ! docker container inspect "$source_id" >/dev/null 2>&1 || return 1
    ! docker container inspect "$old_id" >/dev/null 2>&1 || return 1
    verify_rollback_vpn_generation "$node" "$source_generation"
}

publish_absent_target_evidence()
{
    local node="$1" container service vpn old_id vpn_id vpn_pid vpn_netns path temporary
    absent_target_state_safe "$node" || return 1
    container=$(container_for "$node") || return 1
    service=$(service_for "$node") || return 1
    vpn=$(vpn_for "$node") || return 1
    old_id=$(expected_old_container_id "$node") || return 1
    vpn_id=$(docker inspect -f '{{.Id}}' "$vpn") || return 1
    vpn_pid=$(docker inspect -f '{{.State.Pid}}' "$vpn") || return 1
    vpn_netns=$(readlink "/proc/$vpn_pid/ns/net") || return 1
    path="$CURRENT_WAVE_DIR/node-$(node_padded "$node")-candidate-container-absent.json"
    if [[ -e "$path" || -L "$path" ]]; then
        [[ -f "$path" && ! -L "$path" && "$(stat -c '%u:%g:%a' "$path")" == 0:0:600 ]] ||
            return 1
    fi
    temporary=$(mktemp "$CURRENT_WAVE_DIR/.candidate-container-absent.XXXXXX") || return 1
    jq -S -n --argjson node "$node" --arg container "$container" --arg service "$service" \
        --arg old_id "$old_id" --arg vpn "$vpn" --arg vpn_id "$vpn_id" \
        --argjson vpn_pid "$vpn_pid" --arg vpn_netns "$vpn_netns" \
        --arg observed_at "$(date -u +%FT%TZ)" '
        {schema:1,node:$node,container:$container,service:$service,
         expected_old_container_id:$old_id,candidate_launch_attempted:true,
         container_absent_by_exact_name:true,old_container_absent_by_exact_id:true,
         compose_service_container_absent:true,target_wallet_process_absent:true,
         vpn:{name:$vpn,id:$vpn_id,pid:$vpn_pid,netns:$vpn_netns},observed_at:$observed_at}
    ' > "$temporary" || {
        rm -f -- "$temporary"
        return 1
    }
    chmod 600 "$temporary" || return 1
    chown root:root "$temporary" || return 1
    sync -f "$temporary" || return 1
    mv -fT -- "$temporary" "$path" || return 1
    sync -f "$CURRENT_WAVE_DIR" || return 1
    jq -e --argjson node "$node" --arg container "$container" --arg service "$service" \
        --arg old_id "$old_id" '
        .schema == 1 and .node == $node and .container == $container and .service == $service and
        .expected_old_container_id == $old_id and .candidate_launch_attempted == true and
        .container_absent_by_exact_name == true and .old_container_absent_by_exact_id == true and
        .compose_service_container_absent == true and .target_wallet_process_absent == true
    ' "$path" >/dev/null
}

rollback_restore_authority_sha()
{
    local authority sha
    authority=$(data_rollback_authority_path) || return 1
    data_rollback_protected_file "$authority" 600 || return 1
    data_rollback_canonical_single_object_json "$authority" || return 1
    sha=$(sha256sum "$authority" | awk '{print $1}') || return 1
    valid_sha256_hex "$sha" || return 1
    printf '%s\n' "$sha"
}

rollback_data_restored_receipt_sha()
{
    local authority_sha="$1" receipt sha
    receipt="$CURRENT_WAVE_DIR/DATA-RESTORED.json"
    data_rollback_verify_data_restored_receipt "$authority_sha" || return 1
    sha=$(sha256sum "$receipt" | awk '{print $1}') || return 1
    valid_sha256_hex "$sha" || return 1
    printf '%s\n' "$sha"
}

rollback_old_image_evidence_present()
{
    local authority_dir
    [[ -n "$CURRENT_WAVE_DIR" && -d "$CURRENT_WAVE_DIR" && ! -L "$CURRENT_WAVE_DIR" &&
       "$(realpath -e -- "$CURRENT_WAVE_DIR")" == "$CURRENT_WAVE_DIR" ]] || return 1
    authority_dir=$(rollback_old_image_authority_dir) || return 1
    [[ -e "$authority_dir" || -L "$authority_dir" ]] ||
        find "$CURRENT_WAVE_DIR" -maxdepth 1 \( -type f -o -type l \) \
            -name 'node-*-OLD-IMAGE-RECREATE-ATTEMPTED.json' -print -quit | grep -q .
}

rollback_old_config_image_for()
{
    local node="$1" padded class image
    padded=$(node_padded "$node") || return 1
    class=$(jq -er --arg node "$padded" '.nodes[$node]' \
        "$CURRENT_WAVE_DIR/fleet-image-policy.before.json") || return 1
    image=$(jq -er --arg class "$class" \
        '.images[$class].config_image | select(type == "string" and length > 0)' \
        "$CURRENT_WAVE_DIR/fleet-image-policy.before.json") || return 1
    printf '%s\n' "$image"
}

rollback_old_image_id_for()
{
    local node="$1" padded class image_id
    padded=$(node_padded "$node") || return 1
    class=$(jq -er --arg node "$padded" '.nodes[$node]' \
        "$CURRENT_WAVE_DIR/fleet-image-policy.before.json") || return 1
    image_id=$(jq -er --arg class "$class" \
        '.images[$class].image_id | select(test("^sha256:[0-9a-f]{64}$"))' \
        "$CURRENT_WAVE_DIR/fleet-image-policy.before.json") || return 1
    printf '%s\n' "$image_id"
}

verify_rollback_old_image_authority_at()
{
    local authority_dir="$1" authority sums expected_sha actual_sha authority_sha receipt_sha
    local transaction_sha wave_sha before_compose_sha before_policy_sha before_guard_sha
    local candidate_compose_sha candidate_policy_sha candidate_guard_sha expected_nodes_json
    local data_state node source_generation source_config_image source_image_id source_state
    local launch_state old_ref old_id authority_generation live_triplet_state path actual_count=0
    authority="$authority_dir/AUTHORITY.json"
    sums="$authority_dir/SHA256SUMS"
    data_rollback_protected_directory "$authority_dir" 700 || return 1
    [[ "$(find "$authority_dir" -mindepth 1 -maxdepth 1 -type f | wc -l)" -eq 2 &&
       -z "$(find "$authority_dir" -mindepth 1 ! -type f -print -quit)" ]] || return 1
    data_rollback_protected_file "$authority" 600 || return 1
    data_rollback_canonical_single_object_json "$authority" || return 1
    data_rollback_protected_file "$sums" 600 || return 1
    expected_sha=$(awk 'NF == 2 && $1 ~ /^[0-9a-f]{64}$/ && $2 == "./AUTHORITY.json" {print $1}' \
        "$sums") || return 1
    actual_sha=$(sha256sum "$authority" | awk '{print $1}') || return 1
    [[ -n "$expected_sha" && "$(wc -l < "$sums")" -eq 1 &&
       "$actual_sha" == "$expected_sha" ]] || return 1
    (cd "$authority_dir" && sha256sum --strict -c SHA256SUMS >/dev/null) || return 1
    for path in "$RUN_DIR/TRANSACTION.json" "$CURRENT_WAVE_DIR/WAVE-EVIDENCE.sha256" \
        "$CURRENT_WAVE_DIR/docker-compose.before.yml" \
        "$CURRENT_WAVE_DIR/fleet-image-policy.before.json" \
        "$CURRENT_WAVE_DIR/blackcoin_endpoint_guard.before.sh" \
        "$CURRENT_WAVE_DIR/docker-compose.candidate.yml" \
        "$CURRENT_WAVE_DIR/fleet-image-policy.candidate.json" \
        "$CURRENT_WAVE_DIR/blackcoin_endpoint_guard.candidate.sh"; do
        data_rollback_protected_file "$path" 600 || return 1
    done
    transaction_sha=$(sha256sum "$RUN_DIR/TRANSACTION.json" | awk '{print $1}') || return 1
    wave_sha=$(sha256sum "$CURRENT_WAVE_DIR/WAVE-EVIDENCE.sha256" | awk '{print $1}') || return 1
    before_compose_sha=$(sha256sum "$CURRENT_WAVE_DIR/docker-compose.before.yml" | awk '{print $1}') ||
        return 1
    before_policy_sha=$(sha256sum "$CURRENT_WAVE_DIR/fleet-image-policy.before.json" | awk '{print $1}') ||
        return 1
    before_guard_sha=$(sha256sum "$CURRENT_WAVE_DIR/blackcoin_endpoint_guard.before.sh" | awk '{print $1}') ||
        return 1
    candidate_compose_sha=$(sha256sum "$CURRENT_WAVE_DIR/docker-compose.candidate.yml" | awk '{print $1}') ||
        return 1
    candidate_policy_sha=$(sha256sum "$CURRENT_WAVE_DIR/fleet-image-policy.candidate.json" | awk '{print $1}') ||
        return 1
    candidate_guard_sha=$(sha256sum "$CURRENT_WAVE_DIR/blackcoin_endpoint_guard.candidate.sh" | awk '{print $1}') ||
        return 1
    data_state=$(jq -er '.preupgrade_data_state' "$authority") || return 1
    live_triplet_state=$(jq -er '.live_triplet_state_at_authorization' "$authority") || return 1
    case "$data_state" in
        restored)
            [[ "$live_triplet_state" == candidate ]] || return 1
            authority_sha=$(rollback_restore_authority_sha) || return 1
            receipt_sha=$(rollback_data_restored_receipt_sha "$authority_sha") || return 1
            ;;
        unchanged-no-candidate-launch)
            [[ "$live_triplet_state" == before || "$live_triplet_state" == candidate ]] || return 1
            authority_sha=__NULL__
            receipt_sha=__NULL__
            ! candidate_launch_evidence_present || return 1
            for path in "$CURRENT_WAVE_DIR/ROLLBACK-AUTHORITY.json" \
                "$CURRENT_WAVE_DIR/DATA-RESTORE-EVIDENCE.sha256" \
                "$CURRENT_WAVE_DIR/DATA-RESTORED.json" \
                "$CURRENT_WAVE_DIR/DATA-RESTORED.json.sha256"; do
                [[ ! -e "$path" && ! -L "$path" ]] || return 1
            done
            ;;
        *) return 1 ;;
    esac
    expected_nodes_json=$(printf '%s\n' "${CURRENT_WAVE_NODES[@]}" | jq -sc 'map(tonumber)') ||
        return 1
    jq -e --arg run "$RUN_DIR" --arg wave "$CURRENT_WAVE_DIR" \
        --arg data_state "$data_state" --arg authority_sha "$authority_sha" \
        --arg live_triplet_state "$live_triplet_state" \
        --arg receipt_sha "$receipt_sha" --arg transaction_sha "$transaction_sha" \
        --arg wave_sha "$wave_sha" --arg before_compose_sha "$before_compose_sha" \
        --arg before_policy_sha "$before_policy_sha" --arg before_guard_sha "$before_guard_sha" \
        --arg candidate_compose_sha "$candidate_compose_sha" \
        --arg candidate_policy_sha "$candidate_policy_sha" \
        --arg candidate_guard_sha "$candidate_guard_sha" --argjson nodes "$expected_nodes_json" '
        (keys | sort) == (["schema","transaction","purpose","run_dir","wave_dir",
          "old_image_recreation_authorized","preupgrade_data_state",
          "live_triplet_state_at_authorization",
          "rollback_authority_sha256","data_restored_receipt_sha256",
          "transaction_manifest_sha256","wave_evidence_manifest_sha256",
          "before_triplet","candidate_triplet","nodes","fee_payments_authorized",
          "published_at"] | sort) and
        .schema == 1 and .transaction == "v30.1.4-fleet-rollout" and
        .purpose == "old-image-recreation" and .run_dir == $run and .wave_dir == $wave and
        .old_image_recreation_authorized == true and .preupgrade_data_state == $data_state and
        .live_triplet_state_at_authorization == $live_triplet_state and
        (if $authority_sha == "__NULL__" then .rollback_authority_sha256 == null
         else .rollback_authority_sha256 == $authority_sha end) and
        (if $receipt_sha == "__NULL__" then .data_restored_receipt_sha256 == null
         else .data_restored_receipt_sha256 == $receipt_sha end) and
        .transaction_manifest_sha256 == $transaction_sha and
        .wave_evidence_manifest_sha256 == $wave_sha and
        .before_triplet == {compose_sha256:$before_compose_sha,
          image_policy_sha256:$before_policy_sha,endpoint_guard_sha256:$before_guard_sha} and
        .candidate_triplet == {compose_sha256:$candidate_compose_sha,
          image_policy_sha256:$candidate_policy_sha,endpoint_guard_sha256:$candidate_guard_sha} and
        [.nodes[].node] == $nodes and .fee_payments_authorized == false and
        (.published_at | type) == "string" and (.published_at | length) > 0 and
        all(.nodes[];
          (keys | sort) == (["node","launch_state","source_state","source_generation",
            "source_config_image","source_image_id"] | sort))
    ' "$authority" >/dev/null || return 1
    for node in "${CURRENT_WAVE_NODES[@]}"; do
        source_generation=$(jq -er --argjson node "$node" \
            '.nodes[] | select(.node == $node) | .source_generation' "$authority") || return 1
        source_config_image=$(jq -er --argjson node "$node" \
            '.nodes[] | select(.node == $node) | .source_config_image' "$authority") || return 1
        source_image_id=$(jq -er --argjson node "$node" \
            '.nodes[] | select(.node == $node) | .source_image_id' "$authority") || return 1
        source_state=$(jq -er --argjson node "$node" \
            '.nodes[] | select(.node == $node) | .source_state' "$authority") || return 1
        launch_state=$(jq -er --argjson node "$node" \
            '.nodes[] | select(.node == $node) | .launch_state' "$authority") || return 1
        [[ "$(jq -r --argjson node "$node" '[.nodes[] | select(.node == $node)] | length' \
            "$authority")" -eq 1 ]] || return 1
        data_rollback_validate_stopped_generation "$source_generation" || return 1
        old_ref=$(rollback_old_config_image_for "$node") || return 1
        old_id=$(rollback_old_image_id_for "$node") || return 1
        if [[ "$source_config_image" == "$old_ref" && "$source_image_id" == "$old_id" ]]; then
            [[ "$source_state" == authority-stopped-old ]] || return 1
        elif [[ "$source_config_image" == "$CANDIDATE_IMAGE_REF" &&
                "$source_image_id" == "$CANDIDATE_IMAGE_ID" ]]; then
            [[ "$source_state" == authority-stopped-candidate ]] || return 1
        else
            return 1
        fi
        if [[ "$data_state" == restored ]]; then
            authority_generation=$(jq -er --argjson node "$node" \
                '.nodes[] | select(.node == $node) | .stopped_generation' \
                "$CURRENT_WAVE_DIR/ROLLBACK-AUTHORITY.json") || return 1
            [[ "$source_generation" == "$authority_generation" ]] || return 1
            [[ "$launch_state" == "$(data_rollback_authority_node_launch_state \
                "$authority_sha" "$node")" ]] || return 1
        else
            [[ "$launch_state" == not-attempted ]] || return 1
        fi
        actual_count=$((actual_count + 1))
    done
    [[ "$actual_count" -eq "${#CURRENT_WAVE_NODES[@]}" ]]
}

verify_rollback_old_image_authority()
{
    verify_rollback_old_image_authority_at "$(rollback_old_image_authority_dir)"
}

rollback_old_image_authority_sha()
{
    local authority sha
    verify_rollback_old_image_authority || return 1
    authority=$(rollback_old_image_authority_path) || return 1
    sha=$(sha256sum "$authority" | awk '{print $1}') || return 1
    valid_sha256_hex "$sha" || return 1
    printf '%s\n' "$sha"
}

rollback_compose_path_for_image()
{
    local node="$1" config_image="$2" image_id="$3" old_ref old_id
    old_ref=$(rollback_old_config_image_for "$node") || return 1
    old_id=$(rollback_old_image_id_for "$node") || return 1
    if [[ "$config_image" == "$old_ref" && "$image_id" == "$old_id" ]]; then
        printf '%s\n' "$CURRENT_WAVE_DIR/docker-compose.before.yml"
    elif [[ "$config_image" == "$CANDIDATE_IMAGE_REF" &&
            "$image_id" == "$CANDIDATE_IMAGE_ID" ]]; then
        printf '%s\n' "$CURRENT_WAVE_DIR/docker-compose.candidate.yml"
    else
        return 1
    fi
}

verify_sealed_wave_evidence_files()
{
    local manifest="$CURRENT_WAVE_DIR/WAVE-EVIDENCE.sha256"
    [[ -n "$CURRENT_WAVE_DIR" && -d "$CURRENT_WAVE_DIR" && ! -L "$CURRENT_WAVE_DIR" &&
       "$(realpath -e -- "$CURRENT_WAVE_DIR")" == "$CURRENT_WAVE_DIR" ]] || return 1
    data_rollback_protected_file "$manifest" 600 || return 1
    data_rollback_protected_file "$CURRENT_WAVE_DIR/docker-compose.candidate.yml" 600 || return 1
    (cd "$CURRENT_WAVE_DIR" && sha256sum --strict -c "${manifest##*/}" >/dev/null)
}

rollback_compose_service_hash()
{
    local compose_path="$1" service="$2" output output_service hash extra
    data_rollback_protected_file "$compose_path" 600 || return 1
    output=$(docker compose --project-directory "${COMPOSE_FILE%/*}" \
        -f "$compose_path" config --hash "$service") || return 1
    [[ -n "$output" && "$output" != *$'\n'* ]] || return 1
    read -r output_service hash extra <<< "$output" || return 1
    [[ "$output_service" == "$service" && "$hash" =~ ^[0-9a-f]{64}$ && -z "$extra" ]] ||
        return 1
    printf '%s\n' "$hash"
}

verify_local_image_reference_identity()
{
    local expected_ref="$1" expected_id="$2" image_inspect ref_inspect
    [[ -n "$expected_ref" && "$expected_id" =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
    image_inspect=$(docker image inspect "$expected_id") || return 1
    jq -e --arg id "$expected_id" '
        length == 1 and .[0].Id == $id
    ' >/dev/null <<< "$image_inspect" || return 1
    ref_inspect=$(docker image inspect "$expected_ref") || return 1
    jq -e --arg id "$expected_id" '
        length == 1 and .[0].Id == $id
    ' >/dev/null <<< "$ref_inspect"
}

verify_rollback_container_compose_contract()
{
    local node="$1" inspect="$2" compose_path="$3" expected_ref="$4" expected_id="$5"
    local service expected_hash
    service=$(service_for "$node") || return 1
    expected_hash=$(rollback_compose_service_hash "$compose_path" "$service") || return 1
    jq -e --arg ref "$expected_ref" --arg id "$expected_id" \
        --arg service "$service" --arg hash "$expected_hash" '
        length == 1 and .[0].Config.Image == $ref and .[0].Image == $id and
        .[0].State.Paused == false and
        .[0].Config.Labels["com.docker.compose.service"] == $service and
        .[0].Config.Labels["com.docker.compose.config-hash"] == $hash
    ' >/dev/null <<< "$inspect"
}

verify_candidate_replacement_restart_policy()
{
    local inspect="$1" rollback_state="$CURRENT_WAVE_DIR/ROLLBACK_STATE"
    if [[ -e "$rollback_state" || -L "$rollback_state" ]]; then
        assert_marker_state "$rollback_state" rollback-started || return 1
        jq -e '
            length == 1 and
            ((.[0].HostConfig.RestartPolicy.Name == "on-failure" and
              .[0].HostConfig.RestartPolicy.MaximumRetryCount == 3) or
             (.[0].HostConfig.RestartPolicy.Name == "no" and
              .[0].HostConfig.RestartPolicy.MaximumRetryCount == 0))
        ' >/dev/null <<< "$inspect"
    else
        jq -e '
            length == 1 and .[0].HostConfig.RestartPolicy.Name == "on-failure" and
            .[0].HostConfig.RestartPolicy.MaximumRetryCount == 3
        ' >/dev/null <<< "$inspect"
    fi
}

verify_candidate_present_exclusive()
{
    local node="$1" expected_generation="$2" source_generation="$3" expected_running="$4"
    local source_id baseline_id current_id container service vpn vpn_id vpn_started
    local vpn_pid vpn_netns ids inventory process process_comm exe process_netns cgroup
    local data blocks cmdline cwd fd link inspect source_started target_processes=0
    [[ "$expected_running" == true || "$expected_running" == false ]] || return 1
    data_rollback_validate_stopped_generation "$expected_generation" || return 1
    data_rollback_validate_stopped_generation "$source_generation" || return 1
    IFS='|' read -r source_id source_started vpn_id vpn_started <<< "$source_generation" || return 1
    [[ "$source_id" =~ ^[0-9a-f]{64}$ && -n "$source_started" &&
       "$vpn_id" =~ ^[0-9a-f]{64}$ && -n "$vpn_started" ]] || return 1
    baseline_id=$(expected_old_container_id "$node") || return 1
    container=$(container_for "$node") || return 1
    service=$(service_for "$node") || return 1
    vpn=$(vpn_for "$node") || return 1
    data=$(host_datadir_for "$node") || return 1
    blocks=$(host_blocks_for "$node") || return 1
    inspect=$(docker inspect "$container") || return 1
    current_id=$(jq -er '.[0].Id | select(test("^[0-9a-f]{64}$"))' <<< "$inspect") || return 1
    [[ "$current_id" != "$source_id" && "$current_id" != "$baseline_id" &&
       "$(container_generation_for "$node")" == "$expected_generation" ]] || return 1
    ids=$(docker ps -aq --no-trunc) || return 1
    if [[ -n "$ids" ]]; then
        # shellcheck disable=SC2086
        inventory=$(docker inspect $ids) || return 1
    else
        inventory='[]'
    fi
    jq -e --arg current_id "$current_id" --arg source_id "$source_id" \
        --arg baseline_id "$baseline_id" --arg name "/$container" --arg service "$service" \
        --arg data "$data" --arg blocks "$blocks" '
        type == "array" and
        ([.[] | select(.Id == $current_id)] | length) == 1 and
        all(.[];
          if .Id == $current_id then true
          else .Id != $source_id and .Id != $baseline_id and .Name != $name and
            ((.Config.Labels["com.docker.compose.service"] // "") != $service) and
            ([.Mounts[]? | select(.Source == $data or .Source == $blocks)] | length) == 0
          end)
    ' >/dev/null <<< "$inventory" || return 1
    vpn_pid=$(docker inspect -f '{{.State.Pid}}' "$vpn") || return 1
    [[ "$vpn_pid" =~ ^[1-9][0-9]*$ ]] || return 1
    vpn_netns=$(readlink "/proc/$vpn_pid/ns/net") || return 1
    [[ -n "$vpn_netns" ]] || return 1
    for process in /proc/[0-9]*; do
        [[ -d "$process" ]] || continue
        cgroup="$process/cgroup"
        if [[ -r "$cgroup" ]]; then
            ! grep -Fq -- "$source_id" "$cgroup" || return 1
            ! grep -Fq -- "$baseline_id" "$cgroup" || return 1
        fi
        process_comm=$(cat "$process/comm" 2>/dev/null || true)
        exe=$(readlink "$process/exe" 2>/dev/null || true)
        case "$process_comm|${exe##*/}" in
            blackcoind\|*|blackcoin-qt\|*|*\|blackcoind|*\|blackcoin-qt|\
            *\|blackcoind\ \(deleted\)|*\|blackcoin-qt\ \(deleted\))
                process_netns=$(readlink "$process/ns/net" 2>/dev/null || true)
                [[ -n "$process_netns" && -r "$cgroup" ]] || return 1
                if grep -Fq -- "$current_id" "$cgroup"; then
                    [[ "$expected_running" == true && "$process_netns" == "$vpn_netns" ]] ||
                        return 1
                    target_processes=$((target_processes + 1))
                else
                    [[ "$process_netns" != "$vpn_netns" ]] || return 1
                    cmdline=$(tr '\0' '\n' < "$process/cmdline" 2>/dev/null || true)
                    cwd=$(readlink "$process/cwd" 2>/dev/null || true)
                    if [[ "$cmdline" == *"$data"* || "$cmdline" == *"$blocks"* ||
                          "$cwd" == "$data" || "$cwd" == "$data"/* ||
                          "$cwd" == "$blocks" || "$cwd" == "$blocks"/* ]]; then
                        return 1
                    fi
                    for fd in "$process"/fd/*; do
                        [[ -e "$fd" || -L "$fd" ]] || continue
                        link=$(readlink "$fd" 2>/dev/null || true)
                        if [[ "$link" == "$data" || "$link" == "$data"/* ||
                              "$link" == "$blocks" || "$link" == "$blocks"/* ]]; then
                            return 1
                        fi
                    done
                fi
                ;;
        esac
    done
    if [[ "$expected_running" == true ]]; then
        ((target_processes == 1)) || return 1
    else
        ((target_processes == 0)) || return 1
    fi
    verify_rollback_vpn_generation "$node" "$source_generation" || return 1
    [[ "$(container_generation_for "$node")" == "$expected_generation" ]]
}

verify_candidate_stopped_exclusive()
{
    verify_candidate_present_exclusive "$1" "$2" "$3" false
}

verify_candidate_stopped_container_contract()
{
    local node="$1" expected_generation="$2" authorization source_generation vpn_id
    local container service vpn inspect
    data_rollback_validate_stopped_generation "$expected_generation" || return 1
    authorization=$(wave_node_launch_authorization_path "$node") || return 1
    verify_candidate_launch_authorization_marker "$node" 0 || return 1
    source_generation=$(jq -er '.prelaunch_stopped_generation' "$authorization") || return 1
    verify_rollback_vpn_generation "$node" "$source_generation" || return 1
    vpn_id=${source_generation#*|}
    vpn_id=${vpn_id#*|}
    vpn_id=${vpn_id%%|*}
    [[ "$vpn_id" =~ ^[0-9a-f]{64}$ ]] || return 1
    container=$(container_for "$node") || return 1
    service=$(service_for "$node") || return 1
    vpn=$(vpn_for "$node") || return 1
    verify_sealed_wave_evidence_files || return 1
    [[ "$(container_generation_for "$node")" == "$expected_generation" ]] || return 1
    inspect=$(docker inspect "$container") || return 1
    verify_rollback_container_compose_contract "$node" "$inspect" \
        "$CURRENT_WAVE_DIR/docker-compose.candidate.yml" \
        "$CANDIDATE_IMAGE_REF" "$CANDIDATE_IMAGE_ID" || return 1
    jq -e --arg name "/$container" --arg service "$service" \
        --arg node_label "$(node_padded "$node")" --arg vpn "$vpn" \
        --arg mode "container:$vpn_id" --arg data "$(host_datadir_for "$node")" \
        --arg blocks "$(host_blocks_for "$node")" '
        length == 1 and .[0].Name == $name and .[0].State.Status == "created" and
        .[0].State.Running == false and .[0].State.Pid == 0 and
        .[0].State.StartedAt == "0001-01-01T00:00:00Z" and
        .[0].State.Restarting == false and .[0].State.Paused == false and
        .[0].HostConfig.NetworkMode == $mode and .[0].HostConfig.Privileged == false and
        .[0].HostConfig.AutoRemove == false and
        .[0].Config.Labels["com.docker.compose.service"] == $service and
        .[0].Config.Labels["blackcoin.node"] == $node_label and
        .[0].Config.Labels["blackcoin.vpn"] == $vpn and
        .[0].Config.Labels["blackcoin.storage"] == "pulsar" and
        ([.[0].Mounts[] | select(.Destination == "/home/blackcoin/.blackcoin" and
          .Source == $data and .RW == true)] | length) == 1 and
        ([.[0].Mounts[] | select(.Destination == "/home/blackcoin/blocks_storage" and
          .Source == $blocks and .RW == true)] | length) == 1
    ' >/dev/null <<< "$inspect" || return 1
    verify_candidate_replacement_restart_policy "$inspect" || return 1
    verify_candidate_stopped_exclusive "$node" "$expected_generation" "$source_generation" ||
        return 1
    verify_rollback_vpn_generation "$node" "$source_generation" || return 1
    [[ "$(container_generation_for "$node")" == "$expected_generation" ]]
}

verify_candidate_source_stopped_container_contract()
{
    local node="$1" expected_generation="$2" authorization source_generation inspect
    data_rollback_validate_stopped_generation "$expected_generation" || return 1
    authorization=$(wave_node_launch_authorization_path "$node") || return 1
    verify_candidate_launch_authorization_marker "$node" 0 || return 1
    source_generation=$(jq -er '.prelaunch_stopped_generation' "$authorization") || return 1
    [[ "$expected_generation" == "$source_generation" ]] || return 1
    verify_candidate_launch_authorization_marker "$node" 1 || return 1
    verify_interrupted_target_container "$node" || return 1
    inspect=$(docker inspect "$(container_for "$node")") || return 1
    jq -e '
        length == 1 and .[0].State.Running == false and .[0].State.Pid == 0 and
        .[0].State.Restarting == false
    ' >/dev/null <<< "$inspect" || return 1
    verify_candidate_replacement_restart_policy "$inspect" || return 1
    [[ "$(container_generation_for "$node")" == "$expected_generation" ]]
}

classify_candidate_replacement_node()
{
    local node="$1" authorization source_generation generation
    authorization=$(wave_node_launch_authorization_path "$node") || return 1
    verify_candidate_launch_authorization_marker "$node" 0 || return 1
    source_generation=$(jq -er '.prelaunch_stopped_generation' "$authorization") || return 1
    if ! docker inspect "$(container_for "$node")" >/dev/null 2>&1; then
        absent_target_state_safe "$node" || return 1
        printf '%s\n' absent-after-authorized-replacement
        return 0
    fi
    generation=$(container_generation_for "$node") || return 1
    if [[ "$generation" == "$source_generation" ]]; then
        verify_candidate_source_stopped_container_contract "$node" "$generation" || return 1
        printf '%s\n' source-stopped
        return 0
    fi
    verify_candidate_stopped_container_contract "$node" "$generation" || return 1
    printf '%s\n' candidate-stopped
}

ensure_candidate_stopped_container()
{
    local node="$1" state generation source_id service
    valid_immutable_image_ref "$CANDIDATE_IMAGE_REF" || return 1
    state=$(classify_candidate_replacement_node "$node") || return 1
    if [[ "$state" == source-stopped ]]; then
        data_rollback_require_mutation_fences || return 1
        verify_sealed_wave_evidence_files || return 1
        verify_local_image_reference_identity "$CANDIDATE_IMAGE_REF" "$CANDIDATE_IMAGE_ID" ||
            return 1
        generation=$(container_generation_for "$node") || return 1
        verify_candidate_source_stopped_container_contract "$node" "$generation" || return 1
        source_id=${generation%%|*}
        [[ "$source_id" =~ ^[0-9a-f]{64}$ ]] || return 1
        # No force: a concurrent start makes exact-ID removal fail closed.
        docker rm "$source_id" >/dev/null || return 1
        state=$(classify_candidate_replacement_node "$node") || return 1
        [[ "$state" == absent-after-authorized-replacement ]] || return 1
    fi
    if [[ "$state" == absent-after-authorized-replacement ]]; then
        data_rollback_require_mutation_fences || return 1
        service=$(service_for "$node") || return 1
        verify_sealed_wave_evidence_files || return 1
        verify_local_image_reference_identity "$CANDIDATE_IMAGE_REF" "$CANDIDATE_IMAGE_ID" ||
            return 1
        # --no-recreate makes an object introduced after the absence proof fail
        # closed instead of invoking Compose's non-atomic replacement sequence.
        docker compose --project-directory "${COMPOSE_FILE%/*}" \
            -f "$CURRENT_WAVE_DIR/docker-compose.candidate.yml" up --no-start --no-deps \
            --no-recreate --no-build --pull never "$service" || return 1
        state=$(classify_candidate_replacement_node "$node") || return 1
    fi
    [[ "$state" == candidate-stopped ]]
}

verify_candidate_running_container()
{
    local node="$1" expected_id="$2" attempt authorization stopped_generation
    local source_generation generation inspect
    [[ "$expected_id" =~ ^[0-9a-f]{64}$ ]] || return 1
    attempt=$(wave_node_launch_attempt_path "$node") || return 1
    verify_candidate_launch_attempt_marker "$node" 0 || return 1
    stopped_generation=$(jq -er '.candidate_stopped_generation' "$attempt") || return 1
    [[ "${stopped_generation%%|*}" == "$expected_id" ]] || return 1
    authorization=$(wave_node_launch_authorization_path "$node") || return 1
    source_generation=$(jq -er '.prelaunch_stopped_generation' "$authorization") || return 1
    generation=$(container_generation_for "$node") || return 1
    [[ "${generation%%|*}" == "$expected_id" ]] || return 1
    verify_sealed_wave_evidence_files || return 1
    verify_interrupted_target_container "$node" || return 1
    inspect=$(docker inspect "$expected_id") || return 1
    jq -e --arg id "$expected_id" --arg name "/$(container_for "$node")" \
        --arg image "$CANDIDATE_IMAGE_REF" --arg image_id "$CANDIDATE_IMAGE_ID" '
        length == 1 and .[0].Id == $id and .[0].Name == $name and
        .[0].Config.Image == $image and .[0].Image == $image_id and
        .[0].State.Running == true and .[0].State.Pid > 0 and
        .[0].State.Paused == false and .[0].State.Restarting == false
    ' >/dev/null <<< "$inspect" || return 1
    generation=$(container_generation_for "$node") || return 1
    [[ "${generation%%|*}" == "$expected_id" ]] || return 1
    verify_candidate_present_exclusive "$node" "$generation" "$source_generation" true
}

verify_rollback_vpn_generation()
{
    local node="$1" source_generation="$2" container_id container_started vpn_id vpn_started
    local vpn inspect second_inspect
    data_rollback_validate_stopped_generation "$source_generation" || return 1
    IFS='|' read -r container_id container_started vpn_id vpn_started <<< "$source_generation" ||
        return 1
    [[ "$container_id" =~ ^[0-9a-f]{64}$ && -n "$container_started" &&
       "$vpn_id" =~ ^[0-9a-f]{64}$ && -n "$vpn_started" ]] || return 1
    vpn=$(vpn_for "$node") || return 1
    inspect=$(docker inspect "$vpn") || return 1
    jq -e --arg id "$vpn_id" --arg started "$vpn_started" '
        length == 1 and .[0].Id == $id and .[0].State.StartedAt == $started and
        .[0].State.Running == true and .[0].State.Paused == false and
        .[0].State.Restarting == false and .[0].State.Health.Status == "healthy"
    ' >/dev/null <<< "$inspect" || return 1
    second_inspect=$(docker inspect "$vpn") || return 1
    jq -e --arg id "$vpn_id" --arg started "$vpn_started" '
        length == 1 and .[0].Id == $id and .[0].State.StartedAt == $started and
        .[0].State.Running == true and .[0].State.Paused == false and
        .[0].State.Restarting == false and .[0].State.Health.Status == "healthy"
    ' >/dev/null <<< "$second_inspect"
}

verify_rollback_present_old_exclusive()
{
    local node="$1" authority_sha="$2" expected_generation="$3" expected_running="$4"
    local marker source_generation source_id baseline_id current_id container service vpn
    local vpn_id vpn_started vpn_pid vpn_netns ids inventory process process_comm exe
    local process_netns cgroup target_processes=0 inspect ignored data blocks cmdline cwd fd link
    [[ "$expected_running" == true || "$expected_running" == false ]] || return 1
    verify_rollback_old_image_attempt_marker "$node" "$authority_sha" || return 1
    marker=$(rollback_node_old_image_attempt_path "$node") || return 1
    source_generation=$(jq -er '.source_generation' "$marker") || return 1
    verify_rollback_vpn_generation "$node" "$source_generation" || return 1
    IFS='|' read -r source_id ignored vpn_id vpn_started <<< "$source_generation" || return 1
    [[ "$source_id" =~ ^[0-9a-f]{64}$ && "$vpn_id" =~ ^[0-9a-f]{64}$ &&
       -n "$vpn_started" ]] || return 1
    baseline_id=$(expected_old_container_id "$node") || return 1
    [[ "$baseline_id" =~ ^[0-9a-f]{64}$ ]] || return 1
    container=$(container_for "$node") || return 1
    service=$(service_for "$node") || return 1
    vpn=$(vpn_for "$node") || return 1
    data=$(host_datadir_for "$node") || return 1
    blocks=$(host_blocks_for "$node") || return 1
    inspect=$(docker inspect "$container") || return 1
    current_id=$(jq -er '.[0].Id | select(test("^[0-9a-f]{64}$"))' <<< "$inspect") || return 1
    [[ "$current_id" != "$source_id" && "$current_id" != "$baseline_id" &&
       "$(container_generation_for "$node")" == "$expected_generation" ]] || return 1
    ids=$(docker ps -aq --no-trunc) || return 1
    if [[ -n "$ids" ]]; then
        # shellcheck disable=SC2086
        inventory=$(docker inspect $ids) || return 1
    else
        inventory='[]'
    fi
    jq -e --arg current_id "$current_id" --arg source_id "$source_id" \
        --arg baseline_id "$baseline_id" --arg name "/$container" --arg service "$service" \
        --arg data "$data" --arg blocks "$blocks" '
        type == "array" and
        ([.[] | select(.Id == $current_id)] | length) == 1 and
        all(.[];
          if .Id == $current_id then true
          else .Id != $source_id and .Id != $baseline_id and .Name != $name and
            ((.Config.Labels["com.docker.compose.service"] // "") != $service) and
            ([.Mounts[]? | select(.Source == $data or .Source == $blocks)] | length) == 0
          end)
    ' >/dev/null <<< "$inventory" || return 1
    vpn_pid=$(docker inspect -f '{{.State.Pid}}' "$vpn") || return 1
    [[ "$vpn_pid" =~ ^[1-9][0-9]*$ ]] || return 1
    vpn_netns=$(readlink "/proc/$vpn_pid/ns/net") || return 1
    [[ -n "$vpn_netns" ]] || return 1
    for process in /proc/[0-9]*; do
        [[ -d "$process" ]] || continue
        cgroup="$process/cgroup"
        if [[ -r "$cgroup" ]]; then
            ! grep -Fq -- "$source_id" "$cgroup" || return 1
            ! grep -Fq -- "$baseline_id" "$cgroup" || return 1
        fi
        process_comm=$(cat "$process/comm" 2>/dev/null || true)
        exe=$(readlink "$process/exe" 2>/dev/null || true)
        case "$process_comm|${exe##*/}" in
            blackcoind\|*|blackcoin-qt\|*|*\|blackcoind|*\|blackcoin-qt|\
            *\|blackcoind\ \(deleted\)|*\|blackcoin-qt\ \(deleted\))
                process_netns=$(readlink "$process/ns/net" 2>/dev/null || true)
                [[ -n "$process_netns" && -r "$cgroup" ]] || return 1
                if grep -Fq -- "$current_id" "$cgroup"; then
                    [[ "$process_netns" == "$vpn_netns" ]] || return 1
                    target_processes=$((target_processes + 1))
                elif [[ "$process_netns" == "$vpn_netns" ]]; then
                    return 1
                else
                    cmdline=$(tr '\0' '\n' < "$process/cmdline" 2>/dev/null || true)
                    cwd=$(readlink "$process/cwd" 2>/dev/null || true)
                    if [[ "$cmdline" == *"$data"* || "$cmdline" == *"$blocks"* ||
                          "$cwd" == "$data" || "$cwd" == "$data"/* ||
                          "$cwd" == "$blocks" || "$cwd" == "$blocks"/* ]]; then
                        return 1
                    fi
                    for fd in "$process"/fd/*; do
                        [[ -e "$fd" || -L "$fd" ]] || continue
                        link=$(readlink "$fd" 2>/dev/null || true)
                        if [[ "$link" == "$data" || "$link" == "$data"/* ||
                              "$link" == "$blocks" || "$link" == "$blocks"/* ]]; then
                            return 1
                        fi
                    done
                fi
                ;;
        esac
    done
    if [[ "$expected_running" == true ]]; then
        ((target_processes == 1)) || return 1
    else
        ((target_processes == 0)) || return 1
    fi
    verify_rollback_vpn_generation "$node" "$source_generation" || return 1
    [[ "$(container_generation_for "$node")" == "$expected_generation" ]]
}

verify_rollback_authority_source_node_from_file()
{
    local node="$1" authority="$2" source_generation source_config_image source_image_id
    local container vpn vpn_id inspect generation service compose_path
    local source_container_id source_container_started source_vpn_started
    data_rollback_protected_file "$authority" 600 || return 1
    source_generation=$(jq -er --argjson node "$node" \
        '.nodes[] | select(.node == $node) | .source_generation' "$authority") || return 1
    source_config_image=$(jq -er --argjson node "$node" \
        '.nodes[] | select(.node == $node) | .source_config_image' "$authority") || return 1
    source_image_id=$(jq -er --argjson node "$node" \
        '.nodes[] | select(.node == $node) | .source_image_id' "$authority") || return 1
    container=$(container_for "$node") || return 1
    service=$(service_for "$node") || return 1
    vpn=$(vpn_for "$node") || return 1
    verify_rollback_vpn_generation "$node" "$source_generation" || return 1
    IFS='|' read -r source_container_id source_container_started vpn_id source_vpn_started \
        <<< "$source_generation" || return 1
    generation=$(container_generation_for "$node") || return 1
    [[ "$generation" == "$source_generation" ]] || return 1
    inspect=$(docker inspect "$container") || return 1
    compose_path=$(rollback_compose_path_for_image \
        "$node" "$source_config_image" "$source_image_id") || return 1
    verify_rollback_container_compose_contract "$node" "$inspect" "$compose_path" \
        "$source_config_image" "$source_image_id" || return 1
    jq -e --arg image "$source_config_image" --arg image_id "$source_image_id" \
        --arg service "$service" --arg node_label "$(node_padded "$node")" \
        --arg vpn "$vpn" --arg mode "container:$vpn_id" \
        --arg data "$(host_datadir_for "$node")" --arg blocks "$(host_blocks_for "$node")" '
        length == 1 and .[0].Config.Image == $image and .[0].Image == $image_id and
        .[0].State.Running == false and .[0].State.Pid == 0 and
        .[0].State.Restarting == false and .[0].State.Paused == false and
        .[0].HostConfig.RestartPolicy.Name == "no" and
        .[0].Config.Labels["com.docker.compose.service"] == $service and
        .[0].Config.Labels["blackcoin.node"] == $node_label and
        .[0].Config.Labels["blackcoin.vpn"] == $vpn and
        .[0].Config.Labels["blackcoin.storage"] == "pulsar" and
        .[0].HostConfig.NetworkMode == $mode and .[0].HostConfig.Privileged == false and
        .[0].HostConfig.AutoRemove == false and
        ([.[0].Mounts[] | select(.Destination == "/home/blackcoin/.blackcoin" and
          .Source == $data and .RW == true)] | length) == 1 and
        ([.[0].Mounts[] | select(.Destination == "/home/blackcoin/blocks_storage" and
          .Source == $blocks and .RW == true)] | length) == 1
    ' >/dev/null <<< "$inspect" || return 1
    [[ "$(container_generation_for "$node")" == "$source_generation" ]]
}

publish_rollback_old_image_authority()
{
    local data_state="$1" authority_sha=${2:-} authority_dir staging authority nodes_tmp node
    local generation inspect config_image image_id source_state launch_state receipt_sha
    local old_ref old_id transaction_sha wave_sha live_triplet_state path
    authority_dir=$(rollback_old_image_authority_dir) || return 1
    if [[ -e "$authority_dir" || -L "$authority_dir" ]]; then
        rollback_old_image_authority_sha
        return
    fi
    data_rollback_require_mutation_fences || return 1
    case "$data_state" in
        restored)
            valid_sha256_hex "$authority_sha" || return 1
            receipt_sha=$(rollback_data_restored_receipt_sha "$authority_sha") || return 1
            data_rollback_verify_authority_live "$authority_sha" || return 1
            cmp -s "$COMPOSE_FILE" "$CURRENT_WAVE_DIR/docker-compose.candidate.yml" || return 1
            cmp -s "$IMAGE_POLICY" "$CURRENT_WAVE_DIR/fleet-image-policy.candidate.json" || return 1
            cmp -s "$ENDPOINT_GUARD" "$CURRENT_WAVE_DIR/blackcoin_endpoint_guard.candidate.sh" ||
                return 1
            live_triplet_state=candidate
            ;;
        unchanged-no-candidate-launch)
            authority_sha=__NULL__
            receipt_sha=__NULL__
            ! candidate_launch_evidence_present || return 1
            for path in "$CURRENT_WAVE_DIR/ROLLBACK-AUTHORITY.json" \
                "$CURRENT_WAVE_DIR/DATA-RESTORE-EVIDENCE.sha256" \
                "$CURRENT_WAVE_DIR/DATA-RESTORED.json" \
                "$CURRENT_WAVE_DIR/DATA-RESTORED.json.sha256"; do
                [[ ! -e "$path" && ! -L "$path" ]] || return 1
            done
            if cmp -s "$COMPOSE_FILE" "$CURRENT_WAVE_DIR/docker-compose.before.yml" &&
               cmp -s "$IMAGE_POLICY" "$CURRENT_WAVE_DIR/fleet-image-policy.before.json" &&
               cmp -s "$ENDPOINT_GUARD" "$CURRENT_WAVE_DIR/blackcoin_endpoint_guard.before.sh"; then
                live_triplet_state=before
            elif cmp -s "$COMPOSE_FILE" "$CURRENT_WAVE_DIR/docker-compose.candidate.yml" &&
                 cmp -s "$IMAGE_POLICY" "$CURRENT_WAVE_DIR/fleet-image-policy.candidate.json" &&
                 cmp -s "$ENDPOINT_GUARD" \
                    "$CURRENT_WAVE_DIR/blackcoin_endpoint_guard.candidate.sh"; then
                live_triplet_state=candidate
            else
                return 1
            fi
            ;;
        *) return 1 ;;
    esac
    ! find "$CURRENT_WAVE_DIR" -maxdepth 1 \( -type f -o -type l \) \
        -name 'node-*-OLD-IMAGE-RECREATE-ATTEMPTED.json' -print -quit | grep -q . || return 1
    staging=$(mktemp -d "$CURRENT_WAVE_DIR/.rollback-old-image-authority.XXXXXX") || return 1
    if ! chmod 700 "$staging" || ! chown root:root "$staging"; then
        rm -rf -- "$staging"
        return 1
    fi
    authority="$staging/AUTHORITY.json"
    nodes_tmp=$(mktemp "$CURRENT_WAVE_DIR/.rollback-old-image-nodes.XXXXXX") || {
        rm -rf -- "$staging"; return 1;
    }
    : > "$nodes_tmp"
    for node in "${CURRENT_WAVE_NODES[@]}"; do
        generation=$(container_generation_for "$node") || {
            rm -rf -- "$staging"; rm -f -- "$nodes_tmp"; return 1;
        }
        data_rollback_validate_stopped_generation "$generation" || {
            rm -rf -- "$staging"; rm -f -- "$nodes_tmp"; return 1;
        }
        inspect=$(docker inspect "$(container_for "$node")") || {
            rm -rf -- "$staging"; rm -f -- "$nodes_tmp"; return 1;
        }
        config_image=$(jq -er '.[0].Config.Image | select(type == "string" and length > 0)' \
            <<< "$inspect") || { rm -rf -- "$staging"; rm -f -- "$nodes_tmp"; return 1; }
        image_id=$(jq -er '.[0].Image | select(test("^sha256:[0-9a-f]{64}$"))' \
            <<< "$inspect") || { rm -rf -- "$staging"; rm -f -- "$nodes_tmp"; return 1; }
        old_ref=$(rollback_old_config_image_for "$node") || {
            rm -rf -- "$staging"; rm -f -- "$nodes_tmp"; return 1;
        }
        old_id=$(rollback_old_image_id_for "$node") || {
            rm -rf -- "$staging"; rm -f -- "$nodes_tmp"; return 1;
        }
        if [[ "$config_image" == "$old_ref" && "$image_id" == "$old_id" ]]; then
            source_state='authority-stopped-old'
        elif [[ "$config_image" == "$CANDIDATE_IMAGE_REF" &&
                "$image_id" == "$CANDIDATE_IMAGE_ID" ]]; then
            source_state='authority-stopped-candidate'
        else
            rm -rf -- "$staging"; rm -f -- "$nodes_tmp"; return 1
        fi
        if [[ "$data_state" == restored ]]; then
            [[ "$generation" == "$(jq -er --argjson node "$node" \
                '.nodes[] | select(.node == $node) | .stopped_generation' \
                "$CURRENT_WAVE_DIR/ROLLBACK-AUTHORITY.json")" ]] || {
                rm -rf -- "$staging"; rm -f -- "$nodes_tmp"; return 1;
            }
            launch_state=$(data_rollback_authority_node_launch_state "$authority_sha" "$node") || {
                rm -rf -- "$staging"; rm -f -- "$nodes_tmp"; return 1;
            }
        else
            launch_state=not-attempted
        fi
        jq -cn --argjson node "$node" --arg launch_state "$launch_state" \
            --arg source_state "$source_state" --arg generation "$generation" \
            --arg config_image "$config_image" --arg image_id "$image_id" '
            {node:$node,launch_state:$launch_state,source_state:$source_state,
             source_generation:$generation,source_config_image:$config_image,
             source_image_id:$image_id}' >> "$nodes_tmp" || {
            rm -rf -- "$staging"; rm -f -- "$nodes_tmp"; return 1;
        }
    done
    transaction_sha=$(sha256sum "$RUN_DIR/TRANSACTION.json" | awk '{print $1}') || {
        rm -rf -- "$staging"; rm -f -- "$nodes_tmp"; return 1;
    }
    wave_sha=$(sha256sum "$CURRENT_WAVE_DIR/WAVE-EVIDENCE.sha256" | awk '{print $1}') || {
        rm -rf -- "$staging"; rm -f -- "$nodes_tmp"; return 1;
    }
    jq -S -n --arg run "$RUN_DIR" --arg wave "$CURRENT_WAVE_DIR" \
        --arg data_state "$data_state" --arg authority_sha "$authority_sha" \
        --arg live_triplet_state "$live_triplet_state" \
        --arg receipt_sha "$receipt_sha" --arg transaction_sha "$transaction_sha" \
        --arg wave_sha "$wave_sha" \
        --arg before_compose_sha "$(sha256sum "$CURRENT_WAVE_DIR/docker-compose.before.yml" | awk '{print $1}')" \
        --arg before_policy_sha "$(sha256sum "$CURRENT_WAVE_DIR/fleet-image-policy.before.json" | awk '{print $1}')" \
        --arg before_guard_sha "$(sha256sum "$CURRENT_WAVE_DIR/blackcoin_endpoint_guard.before.sh" | awk '{print $1}')" \
        --arg candidate_compose_sha "$(sha256sum "$CURRENT_WAVE_DIR/docker-compose.candidate.yml" | awk '{print $1}')" \
        --arg candidate_policy_sha "$(sha256sum "$CURRENT_WAVE_DIR/fleet-image-policy.candidate.json" | awk '{print $1}')" \
        --arg candidate_guard_sha "$(sha256sum "$CURRENT_WAVE_DIR/blackcoin_endpoint_guard.candidate.sh" | awk '{print $1}')" \
        --arg published_at "$(date -u +%FT%TZ)" --slurpfile nodes "$nodes_tmp" '
        {schema:1,transaction:"v30.1.4-fleet-rollout",purpose:"old-image-recreation",
         run_dir:$run,wave_dir:$wave,old_image_recreation_authorized:true,
         preupgrade_data_state:$data_state,
         live_triplet_state_at_authorization:$live_triplet_state,
         rollback_authority_sha256:(if $authority_sha == "__NULL__" then null else $authority_sha end),
         data_restored_receipt_sha256:(if $receipt_sha == "__NULL__" then null else $receipt_sha end),
         transaction_manifest_sha256:$transaction_sha,wave_evidence_manifest_sha256:$wave_sha,
         before_triplet:{compose_sha256:$before_compose_sha,
           image_policy_sha256:$before_policy_sha,endpoint_guard_sha256:$before_guard_sha},
         candidate_triplet:{compose_sha256:$candidate_compose_sha,
           image_policy_sha256:$candidate_policy_sha,endpoint_guard_sha256:$candidate_guard_sha},
         nodes:$nodes,fee_payments_authorized:false,published_at:$published_at}' > "$authority" || {
        rm -rf -- "$staging"; rm -f -- "$nodes_tmp"; return 1;
    }
    rm -f -- "$nodes_tmp"
    if ! chmod 600 "$authority" || ! chown root:root "$authority" ||
       ! sync -f "$authority"; then
        rm -rf -- "$staging"
        return 1
    fi
    (cd "$staging" && sha256sum ./AUTHORITY.json > SHA256SUMS) || {
        rm -rf -- "$staging"; return 1;
    }
    if ! chmod 600 "$staging/SHA256SUMS" || ! chown root:root "$staging/SHA256SUMS" ||
       ! sync -f "$staging/SHA256SUMS" || ! sync -f "$staging"; then
        rm -rf -- "$staging"
        return 1
    fi
    verify_rollback_old_image_authority_at "$staging" || { rm -rf -- "$staging"; return 1; }
    for node in "${CURRENT_WAVE_NODES[@]}"; do
        verify_rollback_authority_source_node_from_file "$node" "$authority" || {
            rm -rf -- "$staging"; return 1;
        }
    done
    data_rollback_require_mutation_fences || { rm -rf -- "$staging"; return 1; }
    [[ ! -e "$authority_dir" && ! -L "$authority_dir" ]] || {
        rm -rf -- "$staging"; return 1;
    }
    mv -T -- "$staging" "$authority_dir" || { rm -rf -- "$staging"; return 1; }
    sync -f "$CURRENT_WAVE_DIR" || return 1
    rollback_old_image_authority_sha
}

verify_rollback_old_image_attempt_marker()
{
    local node="$1" authority_sha="$2" path authority source_generation source_state
    local source_config_image source_image_id launch_state old_ref old_id receipt_sha
    path=$(rollback_node_old_image_attempt_path "$node") || return 1
    authority=$(rollback_old_image_authority_path) || return 1
    verify_rollback_old_image_authority || return 1
    [[ "$(sha256sum "$authority" | awk '{print $1}')" == "$authority_sha" ]] || return 1
    data_rollback_protected_file "$path" 600 || return 1
    data_rollback_canonical_single_object_json "$path" || return 1
    source_generation=$(jq -er --argjson node "$node" \
        '.nodes[] | select(.node == $node) | .source_generation' "$authority") || return 1
    source_state=$(jq -er --argjson node "$node" \
        '.nodes[] | select(.node == $node) | .source_state' "$authority") || return 1
    source_config_image=$(jq -er --argjson node "$node" \
        '.nodes[] | select(.node == $node) | .source_config_image' "$authority") || return 1
    source_image_id=$(jq -er --argjson node "$node" \
        '.nodes[] | select(.node == $node) | .source_image_id' "$authority") || return 1
    launch_state=$(jq -er --argjson node "$node" \
        '.nodes[] | select(.node == $node) | .launch_state' "$authority") || return 1
    old_ref=$(rollback_old_config_image_for "$node") || return 1
    old_id=$(rollback_old_image_id_for "$node") || return 1
    receipt_sha=$(jq -r '.data_restored_receipt_sha256 // "__NULL__"' "$authority") || return 1
    jq -e --argjson node "$node" --arg run "$RUN_DIR" --arg wave "$CURRENT_WAVE_DIR" \
        --arg service "$(service_for "$node")" --arg container "$(container_for "$node")" \
        --arg authority_sha "$authority_sha" --arg receipt_sha "$receipt_sha" \
        --arg launch_state "$launch_state" --arg source_state "$source_state" \
        --arg source_generation "$source_generation" \
        --arg source_config_image "$source_config_image" --arg source_image_id "$source_image_id" \
        --arg old_ref "$old_ref" --arg old_id "$old_id" '
        (keys | sort) == (["schema","transaction","boundary","old_image_recreate_attempted",
          "node","run_dir","wave_dir","service","container",
          "old_image_authority_sha256","data_restored_receipt_sha256","launch_state",
          "source_state","source_generation","source_config_image","source_image_id",
          "expected_old_config_image","expected_old_image_id","fee_payments_authorized",
          "created_at"] | sort) and
        .schema == 1 and .transaction == "v30.1.4-fleet-rollout" and
        .boundary == "immediately-before-node-old-image-recreation" and
        .old_image_recreate_attempted == true and .node == $node and
        .run_dir == $run and .wave_dir == $wave and .service == $service and
        .container == $container and .old_image_authority_sha256 == $authority_sha and
        (if $receipt_sha == "__NULL__" then .data_restored_receipt_sha256 == null
         else .data_restored_receipt_sha256 == $receipt_sha end) and
        .launch_state == $launch_state and .source_state == $source_state and
        .source_generation == $source_generation and
        .source_config_image == $source_config_image and .source_image_id == $source_image_id and
        .expected_old_config_image == $old_ref and .expected_old_image_id == $old_id and
        .fee_payments_authorized == false and (.created_at | type) == "string" and
        (.created_at | length) > 0
    ' "$path" >/dev/null
}

publish_rollback_old_image_attempt_marker()
{
    local node="$1" authority_sha="$2" path authority temporary
    local launch_state source_state source_generation source_config_image source_image_id
    local old_ref old_id receipt_sha
    path=$(rollback_node_old_image_attempt_path "$node") || return 1
    if [[ -e "$path" || -L "$path" ]]; then
        verify_rollback_old_image_attempt_marker "$node" "$authority_sha"
        return
    fi
    data_rollback_require_mutation_fences || return 1
    verify_rollback_old_image_authority || return 1
    authority=$(rollback_old_image_authority_path) || return 1
    [[ "$(sha256sum "$authority" | awk '{print $1}')" == "$authority_sha" ]] || return 1
    verify_rollback_authority_source_node_from_file "$node" "$authority" || return 1
    launch_state=$(jq -er --argjson node "$node" \
        '.nodes[] | select(.node == $node) | .launch_state' "$authority") || return 1
    source_state=$(jq -er --argjson node "$node" \
        '.nodes[] | select(.node == $node) | .source_state' "$authority") || return 1
    source_generation=$(jq -er --argjson node "$node" \
        '.nodes[] | select(.node == $node) | .source_generation' "$authority") || return 1
    source_config_image=$(jq -er --argjson node "$node" \
        '.nodes[] | select(.node == $node) | .source_config_image' "$authority") || return 1
    source_image_id=$(jq -er --argjson node "$node" \
        '.nodes[] | select(.node == $node) | .source_image_id' "$authority") || return 1
    receipt_sha=$(jq -r '.data_restored_receipt_sha256 // "__NULL__"' "$authority") || return 1
    old_ref=$(rollback_old_config_image_for "$node") || return 1
    old_id=$(rollback_old_image_id_for "$node") || return 1
    temporary=$(mktemp "$CURRENT_WAVE_DIR/.old-image-recreate-attempt.XXXXXX") || return 1
    jq -S -n --argjson node "$node" --arg run "$RUN_DIR" --arg wave "$CURRENT_WAVE_DIR" \
        --arg service "$(service_for "$node")" --arg container "$(container_for "$node")" \
        --arg authority_sha "$authority_sha" --arg receipt_sha "$receipt_sha" \
        --arg launch_state "$launch_state" --arg source_state "$source_state" \
        --arg source_generation "$source_generation" \
        --arg source_config_image "$source_config_image" --arg source_image_id "$source_image_id" \
        --arg old_ref "$old_ref" --arg old_id "$old_id" --arg created_at "$(date -u +%FT%TZ)" '
        {schema:1,transaction:"v30.1.4-fleet-rollout",
         boundary:"immediately-before-node-old-image-recreation",
         old_image_recreate_attempted:true,node:$node,run_dir:$run,wave_dir:$wave,
         service:$service,container:$container,old_image_authority_sha256:$authority_sha,
         data_restored_receipt_sha256:
           (if $receipt_sha == "__NULL__" then null else $receipt_sha end),
         launch_state:$launch_state,source_state:$source_state,
         source_generation:$source_generation,source_config_image:$source_config_image,
         source_image_id:$source_image_id,expected_old_config_image:$old_ref,
         expected_old_image_id:$old_id,fee_payments_authorized:false,created_at:$created_at}' \
        > "$temporary" || { rm -f -- "$temporary"; return 1; }
    if ! chmod 600 "$temporary" || ! chown root:root "$temporary" ||
       ! sync -f "$temporary"; then
        rm -f -- "$temporary"
        return 1
    fi
    ln -- "$temporary" "$path" || { rm -f -- "$temporary"; return 1; }
    rm -f -- "$temporary"
    sync -f "$CURRENT_WAVE_DIR" || return 1
    verify_rollback_old_image_attempt_marker "$node" "$authority_sha" || return 1
    verify_rollback_authority_source_node_from_file "$node" "$authority"
}

rollback_absent_target_state_safe()
{
    local node="$1" authority_sha="$2" path source_generation source_id old_id
    local container service vpn ids inventory vpn_pid vpn_netns process process_comm exe
    local process_netns cgroup source_started vpn_id vpn_started data blocks cmdline cwd fd link
    verify_rollback_old_image_attempt_marker "$node" "$authority_sha" || return 1
    path=$(rollback_node_old_image_attempt_path "$node") || return 1
    source_generation=$(jq -er '.source_generation' "$path") || return 1
    verify_rollback_vpn_generation "$node" "$source_generation" || return 1
    IFS='|' read -r source_id source_started vpn_id vpn_started <<< "$source_generation" ||
        return 1
    [[ "$source_id" =~ ^[0-9a-f]{64}$ && "$vpn_id" =~ ^[0-9a-f]{64}$ ]] || return 1
    old_id=$(expected_old_container_id "$node") || return 1
    container=$(container_for "$node") || return 1
    service=$(service_for "$node") || return 1
    vpn=$(vpn_for "$node") || return 1
    data=$(host_datadir_for "$node") || return 1
    blocks=$(host_blocks_for "$node") || return 1
    ! docker container inspect "$container" >/dev/null 2>&1 || return 1
    ! docker container inspect "$source_id" >/dev/null 2>&1 || return 1
    ! docker container inspect "$old_id" >/dev/null 2>&1 || return 1
    ids=$(docker ps -aq --no-trunc) || return 1
    if [[ -n "$ids" ]]; then
        # shellcheck disable=SC2086
        inventory=$(docker inspect $ids) || return 1
    else
        inventory='[]'
    fi
    jq -e --arg source_id "$source_id" --arg old_id "$old_id" \
        --arg name "/$container" --arg service "$service" \
        --arg data "$data" --arg blocks "$blocks" '
        type == "array" and all(.[];
          .Id != $source_id and .Id != $old_id and .Name != $name and
          ((.Config.Labels["com.docker.compose.service"] // "") != $service) and
          ([.Mounts[]? | select(.Source == $data or .Source == $blocks)] | length) == 0)
    ' >/dev/null <<< "$inventory" || return 1
    vpn_pid=$(docker inspect -f '{{.State.Pid}}' "$vpn") || return 1
    [[ "$vpn_pid" =~ ^[1-9][0-9]*$ ]] || return 1
    vpn_netns=$(readlink "/proc/$vpn_pid/ns/net") || return 1
    [[ -n "$vpn_netns" ]] || return 1
    for process in /proc/[0-9]*; do
        [[ -d "$process" ]] || continue
        process_comm=$(cat "$process/comm" 2>/dev/null || true)
        exe=$(readlink "$process/exe" 2>/dev/null || true)
        case "$process_comm|${exe##*/}" in
            blackcoind\|*|blackcoin-qt\|*|*\|blackcoind|*\|blackcoin-qt|\
            *\|blackcoind\ \(deleted\)|*\|blackcoin-qt\ \(deleted\))
                process_netns=$(readlink "$process/ns/net" 2>/dev/null || true)
                [[ -z "$process_netns" || "$process_netns" != "$vpn_netns" ]] || return 1
                cmdline=$(tr '\0' '\n' < "$process/cmdline" 2>/dev/null || true)
                cwd=$(readlink "$process/cwd" 2>/dev/null || true)
                if [[ "$cmdline" == *"$data"* || "$cmdline" == *"$blocks"* ||
                      "$cwd" == "$data" || "$cwd" == "$data"/* ||
                      "$cwd" == "$blocks" || "$cwd" == "$blocks"/* ]]; then
                    return 1
                fi
                for fd in "$process"/fd/*; do
                    [[ -e "$fd" || -L "$fd" ]] || continue
                    link=$(readlink "$fd" 2>/dev/null || true)
                    if [[ "$link" == "$data" || "$link" == "$data"/* ||
                          "$link" == "$blocks" || "$link" == "$blocks"/* ]]; then
                        return 1
                    fi
                done
                ;;
        esac
        cgroup="$process/cgroup"
        if [[ -r "$cgroup" ]]; then
            ! grep -Fq -- "$source_id" "$cgroup" || return 1
            ! grep -Fq -- "$old_id" "$cgroup" || return 1
        fi
    done
    ! docker container inspect "$container" >/dev/null 2>&1 || return 1
    ! docker container inspect "$source_id" >/dev/null 2>&1 || return 1
    ! docker container inspect "$old_id" >/dev/null 2>&1 || return 1
    verify_rollback_vpn_generation "$node" "$source_generation"
}

verify_rollback_wrong_stopped_recreate_exclusive()
{
    local node="$1" authority_sha="$2" expected_generation="$3" marker source_generation
    local source_id baseline_id container service vpn vpn_id inspect current_id wrong_image_id
    local old_ref old_image_id expected_hash
    verify_rollback_old_image_attempt_marker "$node" "$authority_sha" || return 1
    data_rollback_validate_stopped_generation "$expected_generation" || return 1
    marker=$(rollback_node_old_image_attempt_path "$node") || return 1
    source_generation=$(jq -er '.source_generation' "$marker") || return 1
    verify_rollback_vpn_generation "$node" "$source_generation" || return 1
    source_id=${source_generation%%|*}
    [[ "$source_id" =~ ^[0-9a-f]{64}$ ]] || return 1
    baseline_id=$(expected_old_container_id "$node") || return 1
    container=$(container_for "$node") || return 1
    service=$(service_for "$node") || return 1
    vpn=$(vpn_for "$node") || return 1
    vpn_id=${source_generation#*|}
    vpn_id=${vpn_id#*|}
    vpn_id=${vpn_id%%|*}
    [[ "$vpn_id" =~ ^[0-9a-f]{64}$ ]] || return 1
    old_ref=$(rollback_old_config_image_for "$node") || return 1
    old_image_id=$(rollback_old_image_id_for "$node") || return 1
    expected_hash=$(rollback_compose_service_hash \
        "$CURRENT_WAVE_DIR/docker-compose.before.yml" "$service") || return 1
    [[ "$(container_generation_for "$node")" == "$expected_generation" ]] || return 1
    inspect=$(docker inspect "$container") || return 1
    current_id=$(jq -er '.[0].Id | select(test("^[0-9a-f]{64}$"))' <<< "$inspect") || return 1
    wrong_image_id=$(jq -er '.[0].Image | select(test("^sha256:[0-9a-f]{64}$"))' \
        <<< "$inspect") || return 1
    [[ "$current_id" != "$source_id" && "$current_id" != "$baseline_id" &&
       "$wrong_image_id" != "$old_image_id" ]] || return 1
    jq -e --arg id "$current_id" --arg name "/$container" --arg ref "$old_ref" \
        --arg wrong_id "$wrong_image_id" --arg service "$service" --arg hash "$expected_hash" \
        --arg node_label "$(node_padded "$node")" --arg vpn "$vpn" \
        --arg mode "container:$vpn_id" --arg data "$(host_datadir_for "$node")" \
        --arg blocks "$(host_blocks_for "$node")" '
        length == 1 and .[0].Id == $id and .[0].Name == $name and
        .[0].Config.Image == $ref and .[0].Image == $wrong_id and
        .[0].State.Status == "created" and .[0].State.Running == false and
        .[0].State.Pid == 0 and .[0].State.StartedAt == "0001-01-01T00:00:00Z" and
        .[0].State.Restarting == false and .[0].State.Paused == false and
        .[0].HostConfig.RestartPolicy.Name == "on-failure" and
        .[0].HostConfig.RestartPolicy.MaximumRetryCount == 3 and
        .[0].HostConfig.NetworkMode == $mode and .[0].HostConfig.Privileged == false and
        .[0].HostConfig.AutoRemove == false and
        .[0].Config.Labels["com.docker.compose.service"] == $service and
        .[0].Config.Labels["com.docker.compose.config-hash"] == $hash and
        .[0].Config.Labels["blackcoin.node"] == $node_label and
        .[0].Config.Labels["blackcoin.vpn"] == $vpn and
        .[0].Config.Labels["blackcoin.storage"] == "pulsar" and
        ([.[0].Mounts[] | select(.Destination == "/home/blackcoin/.blackcoin" and
          .Source == $data and .RW == true)] | length) == 1 and
        ([.[0].Mounts[] | select(.Destination == "/home/blackcoin/blocks_storage" and
          .Source == $blocks and .RW == true)] | length) == 1
    ' >/dev/null <<< "$inspect" || return 1
    verify_rollback_present_old_exclusive "$node" "$authority_sha" \
        "$expected_generation" false || return 1
    verify_rollback_vpn_generation "$node" "$source_generation" || return 1
    [[ "$(container_generation_for "$node")" == "$expected_generation" ]]
}

classify_rollback_old_image_node()
{
    local node="$1" authority_sha="$2" marker container service vpn vpn_id inspect generation
    local source_generation source_config_image source_image_id old_ref old_id compose_path
    verify_rollback_old_image_attempt_marker "$node" "$authority_sha" || return 1
    marker=$(rollback_node_old_image_attempt_path "$node") || return 1
    container=$(container_for "$node") || return 1
    service=$(service_for "$node") || return 1
    vpn=$(vpn_for "$node") || return 1
    vpn_id=$(docker inspect -f '{{.Id}}' "$vpn") || return 1
    if ! inspect=$(docker inspect "$container" 2>/dev/null); then
        rollback_absent_target_state_safe "$node" "$authority_sha" || return 1
        printf '%s\n' absent-after-authorized-recreate
        return 0
    fi
    generation=$(container_generation_for "$node") || return 1
    source_generation=$(jq -er '.source_generation' "$marker") || return 1
    source_config_image=$(jq -er '.source_config_image' "$marker") || return 1
    source_image_id=$(jq -er '.source_image_id' "$marker") || return 1
    old_ref=$(rollback_old_config_image_for "$node") || return 1
    old_id=$(rollback_old_image_id_for "$node") || return 1
    verify_rollback_vpn_generation "$node" "$source_generation" || return 1
    jq -e --arg service "$service" --arg node_label "$(node_padded "$node")" \
        --arg vpn "$vpn" --arg mode "container:$vpn_id" \
        --arg data "$(host_datadir_for "$node")" --arg blocks "$(host_blocks_for "$node")" '
        length == 1 and .[0].Config.Labels["com.docker.compose.service"] == $service and
        .[0].Config.Labels["blackcoin.node"] == $node_label and
        .[0].Config.Labels["blackcoin.vpn"] == $vpn and
        .[0].Config.Labels["blackcoin.storage"] == "pulsar" and
        .[0].HostConfig.NetworkMode == $mode and .[0].HostConfig.Privileged == false and
        .[0].HostConfig.AutoRemove == false and
        ([.[0].Mounts[] | select(.Destination == "/home/blackcoin/.blackcoin" and
          .Source == $data and .RW == true)] | length) == 1 and
        ([.[0].Mounts[] | select(.Destination == "/home/blackcoin/blocks_storage" and
          .Source == $blocks and .RW == true)] | length) == 1
    ' >/dev/null <<< "$inspect" || return 1
    [[ "$(container_generation_for "$node")" == "$generation" ]] || return 1
    compose_path=$(rollback_compose_path_for_image \
        "$node" "$source_config_image" "$source_image_id") || return 1
    if [[ "$generation" == "$source_generation" ]] &&
       jq -e --arg image "$source_config_image" --arg image_id "$source_image_id" '
          .[0].Config.Image == $image and .[0].Image == $image_id and
          .[0].State.Running == false and .[0].State.Pid == 0 and
          .[0].State.Restarting == false and .[0].HostConfig.RestartPolicy.Name == "no"
       ' >/dev/null <<< "$inspect"; then
        verify_rollback_container_compose_contract "$node" "$inspect" "$compose_path" \
            "$source_config_image" "$source_image_id" || return 1
        printf '%s\n' authority-source-stopped
        return 0
    fi
    cmp -s "$COMPOSE_FILE" "$CURRENT_WAVE_DIR/docker-compose.before.yml" || return 1
    if jq -e --arg image "$old_ref" --arg old_id "$old_id" '
        .[0].Config.Image == $image and .[0].Image != $old_id and
        (.[0].Image | test("^sha256:[0-9a-f]{64}$")) and
        .[0].State.Status == "created" and .[0].State.Running == false and
        .[0].State.Pid == 0 and .[0].State.StartedAt == "0001-01-01T00:00:00Z"
    ' >/dev/null <<< "$inspect"; then
        verify_rollback_wrong_stopped_recreate_exclusive \
            "$node" "$authority_sha" "$generation" || return 1
        printf '%s\n' wrong-stopped-after-authorized-recreate
        return 0
    fi
    verify_rollback_container_compose_contract "$node" "$inspect" \
        "$CURRENT_WAVE_DIR/docker-compose.before.yml" "$old_ref" "$old_id" || return 1
    jq -e --arg image "$old_ref" --arg image_id "$old_id" '
        .[0].Config.Image == $image and .[0].Image == $image_id and
        .[0].HostConfig.RestartPolicy.Name == "on-failure" and
        .[0].HostConfig.RestartPolicy.MaximumRetryCount == 3 and
        .[0].State.Restarting == false and .[0].State.Paused == false
    ' >/dev/null <<< "$inspect" || return 1
    if jq -e '.[0].State.Running == true and .[0].State.Pid > 0' >/dev/null <<< "$inspect"; then
        verify_rollback_present_old_exclusive "$node" "$authority_sha" "$generation" true ||
            return 1
        [[ "$(container_generation_for "$node")" == "$generation" ]] || return 1
        printf '%s\n' old-running
    elif jq -e '.[0].State.Running == false and .[0].State.Pid == 0' >/dev/null <<< "$inspect"; then
        verify_rollback_present_old_exclusive "$node" "$authority_sha" "$generation" false ||
            return 1
        [[ "$(container_generation_for "$node")" == "$generation" ]] || return 1
        printf '%s\n' old-stopped
    else
        return 1
    fi
}

ensure_rollback_old_image_node()
{
    local node="$1" authority_sha="$2" path state service generation removal_id
    local deadline old_ref old_id selected_id current_generation recreate_attempts=0
    data_rollback_require_mutation_fences || return 1
    verify_rollback_old_image_authority || return 1
    path=$(rollback_node_old_image_attempt_path "$node") || return 1
    if [[ ! -e "$path" && ! -L "$path" ]]; then
        publish_rollback_old_image_attempt_marker "$node" "$authority_sha" || return 1
    fi
    service=$(service_for "$node") || return 1
    while ((recreate_attempts < 4)); do
        state=$(classify_rollback_old_image_node "$node" "$authority_sha") || return 1
        case "$state" in
        authority-source-stopped)
            data_rollback_require_mutation_fences || return 1
            verify_rollback_old_image_attempt_marker "$node" "$authority_sha" || return 1
            cmp -s "$COMPOSE_FILE" "$CURRENT_WAVE_DIR/docker-compose.before.yml" || return 1
            verify_sealed_wave_evidence_files || return 1
            old_ref=$(rollback_old_config_image_for "$node") || return 1
            old_id=$(rollback_old_image_id_for "$node") || return 1
            generation=$(container_generation_for "$node") || return 1
            [[ "$(classify_rollback_old_image_node "$node" "$authority_sha")" == \
               authority-source-stopped ]] || return 1
            removal_id=${generation%%|*}
            [[ "$removal_id" =~ ^[0-9a-f]{64}$ ]] || return 1
            verify_local_image_reference_identity "$old_ref" "$old_id" || return 1
            # Exact ID and no force: a replacement or concurrent start cannot
            # cause this recovery path to delete a different/live container.
            docker rm "$removal_id" >/dev/null || return 1
            [[ "$(classify_rollback_old_image_node "$node" "$authority_sha")" == \
               absent-after-authorized-recreate ]] || return 1
            ;;
        wrong-stopped-after-authorized-recreate)
            data_rollback_require_mutation_fences || return 1
            verify_rollback_old_image_attempt_marker "$node" "$authority_sha" || return 1
            cmp -s "$COMPOSE_FILE" "$CURRENT_WAVE_DIR/docker-compose.before.yml" || return 1
            generation=$(container_generation_for "$node") || return 1
            verify_rollback_wrong_stopped_recreate_exclusive \
                "$node" "$authority_sha" "$generation" || return 1
            removal_id=${generation%%|*}
            [[ "$removal_id" =~ ^[0-9a-f]{64}$ ]] || return 1
            docker rm "$removal_id" >/dev/null || return 1
            [[ "$(classify_rollback_old_image_node "$node" "$authority_sha")" == \
               absent-after-authorized-recreate ]] || return 1
            ;;
        absent-after-authorized-recreate)
            data_rollback_require_mutation_fences || return 1
            verify_rollback_old_image_attempt_marker "$node" "$authority_sha" || return 1
            cmp -s "$COMPOSE_FILE" "$CURRENT_WAVE_DIR/docker-compose.before.yml" || return 1
            verify_sealed_wave_evidence_files || return 1
            old_ref=$(rollback_old_config_image_for "$node") || return 1
            old_id=$(rollback_old_image_id_for "$node") || return 1
            verify_local_image_reference_identity "$old_ref" "$old_id" || return 1
            docker compose --project-directory "${COMPOSE_FILE%/*}" \
                -f "$CURRENT_WAVE_DIR/docker-compose.before.yml" up --no-start --no-deps \
                --no-recreate --no-build --pull never "$service" || return 1
            state=$(classify_rollback_old_image_node "$node" "$authority_sha") || return 1
            case "$state" in
                old-stopped) break ;;
                wrong-stopped-after-authorized-recreate)
                    recreate_attempts=$((recreate_attempts + 1))
                    continue
                    ;;
                *) return 1 ;;
            esac
            ;;
        old-stopped|old-running) break ;;
        *) return 1 ;;
        esac
        recreate_attempts=$((recreate_attempts + 1))
    done
    [[ "$state" == old-stopped || "$state" == old-running ]] || return 1
    current_generation=$(container_generation_for "$node") || return 1
    selected_id=${current_generation%%|*}
    [[ "$selected_id" =~ ^[0-9a-f]{64}$ ]] || return 1
    if [[ "$state" == old-stopped ]]; then
        data_rollback_require_mutation_fences || return 1
        verify_rollback_old_image_attempt_marker "$node" "$authority_sha" || return 1
        cmp -s "$COMPOSE_FILE" "$CURRENT_WAVE_DIR/docker-compose.before.yml" || return 1
        generation=$(container_generation_for "$node") || return 1
        [[ "$(classify_rollback_old_image_node "$node" "$authority_sha")" == old-stopped ]] ||
            return 1
        [[ "${generation%%|*}" == "$selected_id" ]] || return 1
        docker start "$selected_id" >/dev/null || return 1
    fi
    deadline=$((SECONDS + 120))
    while ((SECONDS < deadline)); do
        current_generation=$(container_generation_for "$node" 2>/dev/null || true)
        [[ "${current_generation%%|*}" == "$selected_id" ]] || return 1
        state=$(classify_rollback_old_image_node "$node" "$authority_sha" 2>/dev/null || true)
        case "$state" in
            old-running) return 0 ;;
            old-stopped|'') ;;
            *) return 1 ;;
        esac
        sleep 1
    done
    return 1
}

rollback_resume_phase()
{
    local restore_authority receipt sidecar restore_manifest old_authority old_authority_sha
    local restore_authority_sha data_state path
    restore_authority=$(data_rollback_authority_path) || return 1
    receipt="$CURRENT_WAVE_DIR/DATA-RESTORED.json"
    sidecar="$CURRENT_WAVE_DIR/DATA-RESTORED.json.sha256"
    restore_manifest="$CURRENT_WAVE_DIR/DATA-RESTORE-EVIDENCE.sha256"
    old_authority=$(rollback_old_image_authority_dir) || return 1
    if rollback_old_image_evidence_present; then
        old_authority_sha=$(rollback_old_image_authority_sha) || return 1
        data_state=$(jq -er '.preupgrade_data_state' "$(rollback_old_image_authority_path)") ||
            return 1
        if [[ "$data_state" == restored ]]; then
            restore_authority_sha=$(rollback_restore_authority_sha) || return 1
            rollback_data_restored_receipt_sha "$restore_authority_sha" >/dev/null || return 1
        elif [[ "$data_state" == unchanged-no-candidate-launch ]]; then
            restore_authority_sha=-
        else
            return 1
        fi
        printf 'old-image-authorized|%s|%s\n' "$restore_authority_sha" "$old_authority_sha"
        return 0
    fi
    [[ ! -e "$old_authority" && ! -L "$old_authority" ]] || return 1
    if [[ -e "$restore_authority" || -L "$restore_authority" ]]; then
        restore_authority_sha=$(rollback_restore_authority_sha) || return 1
        cmp -s "$COMPOSE_FILE" "$CURRENT_WAVE_DIR/docker-compose.candidate.yml" || return 1
        cmp -s "$IMAGE_POLICY" "$CURRENT_WAVE_DIR/fleet-image-policy.candidate.json" || return 1
        cmp -s "$ENDPOINT_GUARD" "$CURRENT_WAVE_DIR/blackcoin_endpoint_guard.candidate.sh" ||
            return 1
        if [[ -e "$sidecar" || -L "$sidecar" ]]; then
            [[ -e "$receipt" && ! -L "$receipt" ]] || return 1
            rollback_data_restored_receipt_sha "$restore_authority_sha" >/dev/null || return 1
            data_rollback_verify_authority_live "$restore_authority_sha" || return 1
            printf 'data-restored|%s|-\n' "$restore_authority_sha"
        elif [[ -e "$receipt" || -L "$receipt" ]]; then
            [[ -f "$receipt" && ! -L "$receipt" ]] || return 1
            data_rollback_verify_data_restored_receipt_body "$restore_authority_sha" || return 1
            data_rollback_verify_authority_live "$restore_authority_sha" || return 1
            printf 'restore-authority-live|%s|-\n' "$restore_authority_sha"
        else
            data_rollback_verify_authority_live "$restore_authority_sha" || return 1
            printf 'restore-authority-live|%s|-\n' "$restore_authority_sha"
        fi
        return 0
    fi
    for path in "$receipt" "$sidecar" "$restore_manifest"; do
        [[ ! -e "$path" && ! -L "$path" ]] || return 1
    done
    printf '%s\n' 'pre-restore|-|-'
}

verify_data_restore_authority_source_node()
{
    local node="$1" authority_sha="$2" authority generation launch_state inspect
    local config_image image_id old_ref old_id container service vpn vpn_id compose_path
    authority=$(data_rollback_authority_path) || return 1
    data_rollback_verify_authority_sealed "$authority_sha" || return 1
    generation=$(jq -er --argjson node "$node" \
        '.nodes[] | select(.node == $node) | .stopped_generation' "$authority") || return 1
    launch_state=$(data_rollback_authority_node_launch_state "$authority_sha" "$node") || return 1
    [[ "$(container_generation_for "$node")" == "$generation" ]] || return 1
    verify_rollback_vpn_generation "$node" "$generation" || return 1
    container=$(container_for "$node") || return 1
    service=$(service_for "$node") || return 1
    vpn=$(vpn_for "$node") || return 1
    vpn_id=$(docker inspect -f '{{.Id}}' "$vpn") || return 1
    inspect=$(docker inspect "$container") || return 1
    config_image=$(jq -er '.[0].Config.Image | select(type == "string" and length > 0)' \
        <<< "$inspect") || return 1
    image_id=$(jq -er '.[0].Image | select(test("^sha256:[0-9a-f]{64}$"))' \
        <<< "$inspect") || return 1
    old_ref=$(rollback_old_config_image_for "$node") || return 1
    old_id=$(rollback_old_image_id_for "$node") || return 1
    if [[ "$launch_state" == candidate-attempted ]]; then
        [[ "$config_image" == "$CANDIDATE_IMAGE_REF" &&
           "$image_id" == "$CANDIDATE_IMAGE_ID" ]] || return 1
    elif [[ "$launch_state" == not-attempted ]]; then
        if [[ "$config_image" == "$old_ref" && "$image_id" == "$old_id" ]]; then
            :
        elif [[ "$config_image" == "$CANDIDATE_IMAGE_REF" &&
                "$image_id" == "$CANDIDATE_IMAGE_ID" ]]; then
            jq -e '.[0].State.StartedAt == "0001-01-01T00:00:00Z"' \
                >/dev/null <<< "$inspect" || return 1
        else
            return 1
        fi
    else
        return 1
    fi
    compose_path=$(rollback_compose_path_for_image "$node" "$config_image" "$image_id") ||
        return 1
    verify_rollback_container_compose_contract "$node" "$inspect" "$compose_path" \
        "$config_image" "$image_id" || return 1
    jq -e --arg service "$service" --arg node_label "$(node_padded "$node")" \
        --arg vpn "$vpn" --arg mode "container:$vpn_id" \
        --arg data "$(host_datadir_for "$node")" --arg blocks "$(host_blocks_for "$node")" '
        length == 1 and .[0].State.Running == false and .[0].State.Pid == 0 and
        .[0].State.Restarting == false and .[0].State.Paused == false and
        .[0].HostConfig.RestartPolicy.Name == "no" and
        .[0].Config.Labels["com.docker.compose.service"] == $service and
        .[0].Config.Labels["blackcoin.node"] == $node_label and
        .[0].Config.Labels["blackcoin.vpn"] == $vpn and
        .[0].Config.Labels["blackcoin.storage"] == "pulsar" and
        .[0].HostConfig.NetworkMode == $mode and .[0].HostConfig.Privileged == false and
        .[0].HostConfig.AutoRemove == false and
        ([.[0].Mounts[] | select(.Destination == "/home/blackcoin/.blackcoin" and
          .Source == $data and .RW == true)] | length) == 1 and
        ([.[0].Mounts[] | select(.Destination == "/home/blackcoin/blocks_storage" and
          .Source == $blocks and .RW == true)] | length) == 1
    ' >/dev/null <<< "$inspect" || return 1
    verify_rollback_vpn_generation "$node" "$generation" || return 1
    [[ "$(container_generation_for "$node")" == "$generation" ]]
}

verify_rollback_old_node_quiescent()
{
    local node="$1" authority_sha="$2" expected_generation="$3"
    local wallet_info staking mining txids_tmp
    [[ "$(classify_rollback_old_image_node "$node" "$authority_sha")" == old-running ]] ||
        return 1
    [[ "$(container_generation_for "$node")" == "$expected_generation" ]] || return 1
    wallet_info=$(wallet_rpc_for "$node" getwalletinfo) || return 1
    staking=$(wallet_rpc_for "$node" getstakinginfo) || return 1
    mining=$(wallet_rpc_for "$node" getpowmininginfo) || return 1
    jq -e '.unlocked_until == 0' >/dev/null <<< "$wallet_info" || return 1
    jq -e '.enabled == false and .staking == false and
        ((has("worker_running") | not) or .worker_running == false) and
        .automatic_qqsignal == false and .automatic_demurrage_attestation == false and
        .automatic_redelegation == false and .allow_automatic_quantum_key_creation == false' \
        >/dev/null <<< "$staking" || return 1
    jq -e '.enabled == false and .live_claims == 0' >/dev/null <<< "$mining" || return 1
    txids_tmp=$(mktemp "$CURRENT_WAVE_DIR/.old-quiescent-txids.XXXXXX") || return 1
    if ! capture_wallet_txid_set "$node" "$txids_tmp" ||
       ! cmp -s "$CURRENT_WAVE_DIR/node-$(node_padded "$node")-wallet-txids.prelaunch.json" \
           "$txids_tmp"; then
        rm -f -- "$txids_tmp"
        return 1
    fi
    rm -f -- "$txids_tmp"
    [[ "$(container_generation_for "$node")" == "$expected_generation" ]]
}

quiesce_rollback_old_node()
{
    local node="$1" authority_sha="$2" generation deadline
    [[ "$(classify_rollback_old_image_node "$node" "$authority_sha")" == old-running ]] ||
        return 1
    generation=$(container_generation_for "$node") || return 1
    deadline=$((SECONDS + 1200))
    while ((SECONDS < deadline)); do
        [[ "$(container_generation_for "$node" 2>/dev/null || true)" == "$generation" ]] ||
            return 1
        if [[ "$node" -ne "$FREE_CLAIM_NODE" ]]; then
            wallet_rpc_for "$node" setpowmining false 1 1 >/dev/null 2>&1 || true
        fi
        wallet_rpc_for "$node" staking false >/dev/null 2>&1 || true
        wallet_rpc_for "$node" walletlock >/dev/null 2>&1 || true
        if verify_rollback_old_node_quiescent \
            "$node" "$authority_sha" "$generation" 2>/dev/null; then
            return 0
        fi
        sleep 2
    done
    return 1
}

quiesce_rollback_old_wave()
{
    local authority_sha="$1" node deadline unresolved
    local -A generations=() pending=()
    for node in "${CURRENT_WAVE_NODES[@]}"; do
        [[ "$(classify_rollback_old_image_node "$node" "$authority_sha")" == old-running ]] ||
            return 1
        generations[$node]=$(container_generation_for "$node") || return 1
        pending[$node]=1
    done
    deadline=$((SECONDS + 1200))
    while ((SECONDS < deadline)); do
        unresolved=0
        for node in "${CURRENT_WAVE_NODES[@]}"; do
            [[ -n "${pending[$node]:-}" ]] || continue
            [[ "$(container_generation_for "$node" 2>/dev/null || true)" == \
               "${generations[$node]}" ]] || return 1
            if [[ "$node" -ne "$FREE_CLAIM_NODE" ]]; then
                wallet_rpc_for "$node" setpowmining false 1 1 >/dev/null 2>&1 || true
            fi
            wallet_rpc_for "$node" staking false >/dev/null 2>&1 || true
            wallet_rpc_for "$node" walletlock >/dev/null 2>&1 || true
            if verify_rollback_old_node_quiescent \
                "$node" "$authority_sha" "${generations[$node]}" 2>/dev/null; then
                unset 'pending[$node]'
            else
                unresolved=$((unresolved + 1))
            fi
        done
        ((unresolved == 0)) && break
        sleep 2
    done
    ((unresolved == 0)) || return 1
    for node in "${CURRENT_WAVE_NODES[@]}"; do
        verify_rollback_old_node_quiescent "$node" "$authority_sha" "${generations[$node]}" ||
            return 1
    done
}

verify_interrupted_target_container()
{
    local node="$1" padded before_class candidate_class before_ref before_id candidate_ref candidate_id
    local container vpn vpn_id inspect generation config_image image_id compose_path service
    local container_id container_started vpn_started
    local rollback_state="$CURRENT_WAVE_DIR/ROLLBACK_STATE" stop_authorized=false
    padded=$(node_padded "$node") || return 1
    before_class=$(jq -er --arg node "$padded" '.nodes[$node]' \
        "$CURRENT_WAVE_DIR/fleet-image-policy.before.json") || return 1
    candidate_class=$(jq -er --arg node "$padded" '.nodes[$node]' \
        "$CURRENT_WAVE_DIR/fleet-image-policy.candidate.json") || return 1
    before_ref=$(jq -er --arg class "$before_class" '.images[$class].config_image' \
        "$CURRENT_WAVE_DIR/fleet-image-policy.before.json") || return 1
    before_id=$(jq -er --arg class "$before_class" '.images[$class].image_id' \
        "$CURRENT_WAVE_DIR/fleet-image-policy.before.json") || return 1
    candidate_ref=$(jq -er --arg class "$candidate_class" '.images[$class].config_image' \
        "$CURRENT_WAVE_DIR/fleet-image-policy.candidate.json") || return 1
    candidate_id=$(jq -er --arg class "$candidate_class" '.images[$class].image_id' \
        "$CURRENT_WAVE_DIR/fleet-image-policy.candidate.json") || return 1
    container=$(container_for "$node")
    service=$(service_for "$node") || return 1
    vpn=$(vpn_for "$node")
    if [[ -e "$rollback_state" || -L "$rollback_state" ]]; then
        assert_marker_state "$rollback_state" rollback-started || return 1
        stop_authorized=true
    fi
    if ! inspect=$(docker inspect "$container" 2>/dev/null); then
        absent_target_state_safe "$node"
        return
    fi
    generation=$(container_generation_for "$node") || return 1
    verify_rollback_vpn_generation "$node" "$generation" || return 1
    IFS='|' read -r container_id container_started vpn_id vpn_started <<< "$generation" ||
        return 1
    [[ "$vpn_id" =~ ^[0-9a-f]{64}$ ]] || return 1
    config_image=$(jq -er '.[0].Config.Image | select(type == "string" and length > 0)' \
        <<< "$inspect") || return 1
    image_id=$(jq -er '.[0].Image | select(test("^sha256:[0-9a-f]{64}$"))' \
        <<< "$inspect") || return 1
    compose_path=$(rollback_compose_path_for_image "$node" "$config_image" "$image_id") ||
        return 1
    verify_rollback_container_compose_contract "$node" "$inspect" "$compose_path" \
        "$config_image" "$image_id" || return 1
    jq -e --arg before_ref "$before_ref" --arg before_id "$before_id" \
        --arg candidate_ref "$candidate_ref" --arg candidate_id "$candidate_id" \
        --arg container_id "$container_id" --arg container_started "$container_started" \
        --arg service "$service" --arg node_label "$(node_padded "$node")" \
        --arg vpn "$vpn" --arg mode "container:$vpn_id" \
        --arg data "$(host_datadir_for "$node")" --arg blocks "$(host_blocks_for "$node")" \
        --argjson stop_authorized "$stop_authorized" '
        length == 1 and .[0].Id == $container_id and
        .[0].State.StartedAt == $container_started and
        ((.[0].Config.Image == $before_ref and .[0].Image == $before_id) or
         (.[0].Config.Image == $candidate_ref and .[0].Image == $candidate_id)) and
        .[0].State.Paused == false and .[0].State.Restarting == false and
        ((.[0].State.Running == true and .[0].State.Pid > 0) or
         (.[0].State.Running == false and .[0].State.Pid == 0)) and
        .[0].HostConfig.NetworkMode == $mode and
        (if $stop_authorized then
           ((.[0].HostConfig.RestartPolicy.Name == "on-failure" and
             .[0].HostConfig.RestartPolicy.MaximumRetryCount == 3) or
            (.[0].HostConfig.RestartPolicy.Name == "no" and
             .[0].HostConfig.RestartPolicy.MaximumRetryCount == 0))
         else
           .[0].HostConfig.RestartPolicy.Name == "on-failure" and
           .[0].HostConfig.RestartPolicy.MaximumRetryCount == 3
         end) and
        .[0].HostConfig.Privileged == false and .[0].HostConfig.AutoRemove == false and
        .[0].Config.Labels["com.docker.compose.service"] == $service and
        .[0].Config.Labels["blackcoin.node"] == $node_label and
        .[0].Config.Labels["blackcoin.vpn"] == $vpn and
        .[0].Config.Labels["blackcoin.storage"] == "pulsar" and
        ([.[0].Mounts[] | select(.Destination == "/home/blackcoin/.blackcoin" and
            .Source == $data and .RW == true)] | length) == 1 and
        ([.[0].Mounts[] | select(.Destination == "/home/blackcoin/blocks_storage" and
            .Source == $blocks and .RW == true)] | length) == 1
    ' >/dev/null <<< "$inspect" || return 1
    verify_rollback_vpn_generation "$node" "$generation" || return 1
    [[ "$(container_generation_for "$node")" == "$generation" ]]
}

resume_interrupted_wave_before_live_preflight()
{
    local interrupted="$1" wave_name wave_index node temporary containment_pending=0
    local phase_record rollback_phase restore_authority_sha old_authority_sha attempt state
    require_host_tools
    [[ "$(id -u)" -eq 0 ]] || die 'root is required on the Unraid host'
    verify_package_integrity "$PACKAGE_ROOT" || die 'resume package bytes changed'
    require_rollout_identity
    require_baseline_identity
    verify_resume_run
    verify_maintenance_marker || die 'interrupted resume maintenance marker is absent or changed'
    assert_empty_control_marker "$ENABLE_GUARD_STARTS" ||
        die 'guard-start authority is unsafe during interrupted resume'
    /bin/bash "$INHIBITOR_INSTALLER" probe >/dev/null ||
        die 'transaction inhibitors changed during interrupted resume'
    verify_free_claim_pause || die 'Free Claim pause changed during interrupted resume'
    CURRENT_WAVE_DIR=$(realpath -e -- "$interrupted")
    wave_name=${CURRENT_WAVE_DIR##*/}
    [[ "$wave_name" =~ ^wave-([0-9]{2})-nodes- ]] || die 'interrupted wave name is invalid'
    wave_index=$((10#${BASH_REMATCH[1]}))
    verify_wave_evidence_manifest "$CURRENT_WAVE_DIR" "$wave_index" ||
        die 'interrupted wave preparation evidence changed'
    read -r -a CURRENT_WAVE_NODES < "$CURRENT_WAVE_DIR/NODES"
    if candidate_launch_evidence_present; then
        verify_wave_candidate_launch_markers 0 ||
            die 'interrupted wave has incomplete or changed per-node candidate launch evidence'
    fi
    if find "$CURRENT_WAVE_DIR" -maxdepth 1 \( -type f -o -type l \) \
        -name 'node-*-CONTAINED-NO-ROLLBACK.json' -print -quit | grep -q . ||
       [[ -e "$(wave_containment_complete_path)" || -L "$(wave_containment_complete_path)" ]]; then
        log 'interrupted wave has containment evidence; rollback recovery will resume containment'
        containment_pending=1
    fi
    rollback_phase=pre-restore
    restore_authority_sha=-
    old_authority_sha=-
    if [[ "$containment_pending" -eq 0 ]]; then
        phase_record=$(rollback_resume_phase) ||
            die 'interrupted rollback phase evidence is absent, changed, or contradictory'
        IFS='|' read -r rollback_phase restore_authority_sha old_authority_sha <<< "$phase_record"
        case "$rollback_phase" in
            pre-restore|restore-authority-live|data-restored|old-image-authorized) ;;
            *) die 'interrupted rollback phase classification is invalid' ;;
        esac
    fi
    live_file_matches_wave_generation "$COMPOSE_FILE" \
        "$CURRENT_WAVE_DIR/docker-compose.before.yml" \
        "$CURRENT_WAVE_DIR/docker-compose.candidate.yml" ||
        die 'live Compose is outside the interrupted wave generations'
    live_file_matches_wave_generation "$IMAGE_POLICY" \
        "$CURRENT_WAVE_DIR/fleet-image-policy.before.json" \
        "$CURRENT_WAVE_DIR/fleet-image-policy.candidate.json" ||
        die 'live image policy is outside the interrupted wave generations'
    live_file_matches_wave_generation "$ENDPOINT_GUARD" \
        "$CURRENT_WAVE_DIR/blackcoin_endpoint_guard.before.sh" \
        "$CURRENT_WAVE_DIR/blackcoin_endpoint_guard.candidate.sh" ||
        die 'live endpoint guard is outside the interrupted wave generations'
    verify_runtime_guard_3014_compatibility ||
        die 'runtime guard compatibility changed during interrupted resume'
    temporary=$(mktemp "$RUN_DIR/.unaffected-resume.XXXXXX")
    capture_unaffected_generations "$temporary" "$(IFS=,; printf '%s' "${CURRENT_WAVE_NODES[*]}")" ||
        die 'unaffected generation capture failed during interrupted resume'
    cmp -s "$CURRENT_WAVE_DIR/unaffected.before" "$temporary" ||
        die 'an unaffected node or VPN generation changed during interrupted wave'
    rm -f -- "$temporary"
    for node in "${CURRENT_WAVE_NODES[@]}"; do
        if [[ "$containment_pending" -eq 0 ]]; then
            case "$rollback_phase" in
                pre-restore)
                    verify_interrupted_target_container "$node" ||
                        die "interrupted target topology/image is outside the rollback boundary: node $node"
                    ;;
                restore-authority-live|data-restored)
                    verify_data_restore_authority_source_node "$node" "$restore_authority_sha" ||
                        die "data-restore authority source changed before old-image authorization: node $node"
                    ;;
                old-image-authorized)
                    attempt=$(rollback_node_old_image_attempt_path "$node") ||
                        die "old-image attempt path is invalid: node $node"
                    if [[ -e "$attempt" || -L "$attempt" ]]; then
                        state=$(classify_rollback_old_image_node "$node" "$old_authority_sha") ||
                            die "authorized old-image node state is ambiguous: node $node"
                        case "$state" in
                            authority-source-stopped|absent-after-authorized-recreate|\
                            wrong-stopped-after-authorized-recreate|old-stopped|old-running) ;;
                            *) die "authorized old-image node classification is invalid: node $node" ;;
                        esac
                    else
                        verify_rollback_authority_source_node_from_file "$node" \
                            "$(rollback_old_image_authority_path)" ||
                            die "old-image source changed before its node attempt: node $node"
                    fi
                    ;;
            esac
        fi
        verify_vpn_pair "$node" || die "interrupted target VPN proof changed: node $node"
    done
    assert_unique_vpn_proofs || die 'VPN proof set changed during interrupted resume'
    verify_all_data_domains || die 'data rollback domains changed during interrupted resume'
}

verify_image_policy_local_images()
{
    local class ref expected_id actual_id
    while IFS= read -r class; do
        ref=$(jq -er --arg class "$class" '.images[$class].config_image' "$IMAGE_POLICY") || return 1
        expected_id=$(jq -er --arg class "$class" '.images[$class].image_id' "$IMAGE_POLICY") || return 1
        actual_id=$(docker image inspect -f '{{.Id}}' "$ref" 2>/dev/null) || return 1
        [[ "$actual_id" == "$expected_id" ]] || return 1
    done < <(jq -r '.images | keys[]' "$IMAGE_POLICY")
}

verify_node30_role_policy()
{
    local manifest="$STATE_DIR/pow-wallet-manifests/node-30.json"
    assert_protected_file "$manifest" 600
    jq -e '.schema == 1 and .node_id == "30" and .enabled == false' "$manifest" >/dev/null ||
        die 'node30 PoW manifest does not preserve the Free Claim-only role'
    [[ -x "$FREE_CLAIM_ROOT/pool_daemon.sh" && -x "$FREE_CLAIM_ROOT/pool_keeper.sh" ]] ||
        die 'Free Claim worker assets are unavailable'
}

verify_no_forbidden_compose_directive()
{
    ! grep -Eiq '(^|[[:space:]])-?(reindex|reindex-chainstate)(=|[[:space:]]|$)' "$COMPOSE_FILE" ||
        die 'persistent Compose reindex directive detected'
    ! grep -Eiq 'chainstate.*(park|move|rename)|schema-11' "$COMPOSE_FILE" ||
        die 'obsolete chainstate migration directive detected'
}

live_preflight()
{
    local node container status health run_state='' inhibitor_probe compat_probe
    require_host_tools
    verify_package_integrity "$PACKAGE_ROOT" ||
        die 'rollout package bytes differ from the validated manifest'
    [[ "$(id -u)" -eq 0 ]] || die 'root is required on the Unraid host'
    mountpoint -q /mnt/pulsar || die 'Pulsar storage is not mounted'
    [[ -f "$COMPOSE_FILE" && ! -L "$COMPOSE_FILE" ]] || die 'Compose file is missing or unsafe'
    assert_marker_state "$CUTOVER_MARKER" 'cutover_ready=yes containers=32 state=created' ||
        die 'Pulsar cutover marker is absent or unsafe'
    require_baseline_identity
    if [[ -z "$RUN_DIR" ]]; then
        assert_empty_control_marker "$ENABLE_GUARD_STARTS" ||
            die 'automatic-start authority marker is absent, nonempty, or unsafe'
        if [[ "$ACTION" == apply ]]; then
            [[ -e "$ROLLOUT_MAINTENANCE_MARKER" || -L "$ROLLOUT_MAINTENANCE_MARKER" ]] ||
                die 'apply requires the exact active handoff-ready canary marker'
            verify_published_canary_handoff_ready ||
                die 'existing maintenance marker is not the exact handoff-ready canary authority'
            CANARY_HANDOFF_PENDING=1
        elif [[ -e "$ROLLOUT_MAINTENANCE_MARKER" || -L "$ROLLOUT_MAINTENANCE_MARKER" ]]; then
            verify_published_canary_handoff_ready ||
                die 'existing maintenance marker is not the exact handoff-ready canary authority'
            CANARY_HANDOFF_PENDING=1
        fi
    else
        verify_resume_run
        run_state=$(cat "$RUN_DIR/STATE")
        if [[ "$run_state" == applying ]]; then
            verify_maintenance_marker || die 'resume maintenance marker is absent or changed'
        elif [[ "$run_state" == prepared &&
                ( -e "$ROLLOUT_MAINTENANCE_MARKER" || -L "$ROLLOUT_MAINTENANCE_MARKER" ) ]]; then
            if verify_maintenance_marker; then
                if [[ -f "$(canary_predecessor_path)" &&
                      ! -L "$(canary_predecessor_path)" ]]; then
                    publish_canary_fleet_handoff ||
                        die 'prepared-run atomic canary handoff record could not be recovered'
                fi
            else
                [[ -f "$(canary_predecessor_path)" &&
                   ! -L "$(canary_predecessor_path)" ]] ||
                    die 'prepared-run maintenance marker is foreign or changed'
                cmp -s "$(canary_predecessor_path)" "$ROLLOUT_MAINTENANCE_MARKER" ||
                    die 'prepared-run canary predecessor marker changed'
                verify_published_canary_handoff_ready ||
                    die 'prepared-run canary handoff evidence changed'
                CANARY_HANDOFF_PENDING=1
            fi
        elif [[ "$run_state" == complete ]]; then
            if [[ -e "$ROLLOUT_MAINTENANCE_MARKER" || -L "$ROLLOUT_MAINTENANCE_MARKER" ]]; then
                verify_maintenance_marker ||
                    die 'complete-run maintenance marker is foreign or changed'
            else
                verify_released_finalization_resume_state ||
                    die 'complete-run released finalization state is absent or changed'
            fi
        fi
    fi
    [[ "$(cat /boot/config/plugins/compose.manager/projects/blackcoin30/autostart 2>/dev/null)" == false ]] ||
        die 'Compose autostart is not fail-closed'
    require_rollout_identity
    validate_wave_plan "$WAVE_PLAN" || die 'wave plan is invalid, duplicates nodes, or violates role isolation'
    verify_current_policy_assets
    verify_runtime_guard_3014_compatibility ||
        die 'wallet runtime guard is not the audited v30.1.3/v30.1.4-compatible build'
    if [[ -z "$RUN_DIR" ]]; then
        compat_probe=$(/bin/bash "$RUNTIME_COMPAT_INSTALLER" probe) ||
            die 'runtime-guard compatibility transaction state is not auditable'
        [[ "$compat_probe" == "state=installed runtime_sha256=$EXPECTED_WALLET_RUNTIME_GUARD_SHA256 endpoint_sha256=$EXPECTED_ENDPOINT_GUARD_SHA256" ]] ||
            die 'runtime-guard compatibility transaction is not the exact installed generation'
    fi
    verify_activation_helper "$NORMAL_UNLOCK_HELPER" "$NORMAL_UNLOCK_HELPER_SHA256" ||
        die 'normal-unlock helper bytes or protection changed'
    verify_activation_helper "$POW_START_HELPER" "$POW_START_HELPER_SHA256" ||
        die 'PoW-start helper bytes or protection changed'
    if [[ -z "$RUN_DIR" ]]; then
        verify_baseline_hashes
    fi
    verify_image_policy_local_images || die 'an image pinned by the current policy is absent or has the wrong ID'
    verify_live_fleet_matches_policy || die 'live Compose/container identities differ from the current policy'
    verify_image_identity || die 'candidate image identity, labels, or binary hashes failed'
    if [[ "$CANARY_HANDOFF_PENDING" -eq 1 ]]; then
        verify_published_canary_handoff_ready ||
            die 'active canary handoff authority changed during locked preflight'
    elif [[ -n "$RUN_DIR" ]] &&
         jq -e '.canary_handoff.required == true' "$RUN_DIR/TRANSACTION.json" >/dev/null 2>&1; then
        verify_canary_fleet_handoff 0 ||
            die 'sealed canary-to-fleet maintenance handoff evidence changed'
    elif [[ "$ACTION" == apply ]]; then
        die 'fleet apply/resume lacks mandatory canary-to-fleet handoff authority'
    else
        verify_published_canary ||
            die 'published-package node27 canary evidence does not match this exact image'
    fi
    verify_node30_role_policy
    inhibitor_probe=$(/bin/bash "$INHIBITOR_RELEASER" probe) ||
        die 'permanent no-spend cycle and Free Claim state are not auditable'
    if [[ -z "$RUN_DIR" || "$run_state" == prepared || "$run_state" == applying ]]; then
        [[ "$inhibitor_probe" == 'state=installed-and-paused cycle=v30.1.4-no-spend free_claim=paused' ]] ||
            die 'transaction inhibitors are not in the required paused state'
        verify_free_claim_pause || die 'Free Claim broadcasts are not durably paused'
    else
        [[ "$inhibitor_probe" == 'state=installed-and-paused cycle=v30.1.4-no-spend free_claim=paused' ||
           "$inhibitor_probe" == 'state=installed-and-released cycle=v30.1.4-no-spend free_claim=enabled' ]] ||
            die 'complete-run inhibitor state is invalid'
    fi
    verify_all_policy_manifests || die 'wallet/identity/PoW policy manifests are not exact-32 and coherent'
    verify_all_data_domains || die 'fleet data rollback domains are not safe and dedicated/classified'
    verify_no_forbidden_compose_directive
    assert_no_reindex_directive $(seq 1 "$NODE_COUNT") || die 'a persistent per-node reindex directive exists'
    assert_unique_vpn_proofs || die 'all 32 VPN proofs must be valid and public-IP unique before rollout'
    for node in $(seq 1 "$NODE_COUNT"); do
        container=$(container_for "$node")
        read -r status health < <(docker inspect -f \
            '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container") ||
            die "node $node container is absent"
        [[ "$status" == running && "$health" == healthy ]] || die "node $node is not running and healthy"
        verify_vpn_pair "$node" || die "node $node VPN pair failed preflight"
        single_wallet_for "$node" >/dev/null || die "node $node does not have exactly one loaded wallet"
    done
}

capture_fleet_identity()
{
    local output="$1" node container vpn wallet wallets qaddr qinv legacy manifest identity pow_manifest
    local runtime_sha identity_sha pow_sha conf_sha settings_sha container_id container_started vpn_id vpn_started
    : > "$output"
    for node in $(seq 1 "$NODE_COUNT"); do
        container=$(container_for "$node")
        vpn=$(vpn_for "$node")
        wallets=$(rpc_for "$node" listwallets | jq -cS .) || return 1
        wallet=$(jq -er 'select(type == "array" and length == 1) | .[0]' <<< "$wallets") || return 1
        qaddr=$(timeout --foreground -k 2 45 docker exec "$container" "$CLI_PATH" -datadir="$DATADIR" \
            -rpcwallet="$wallet" listquantumaddresses | jq -cS . | sha256sum | awk '{print $1}') || return 1
        qinv=$(timeout --foreground -k 2 45 docker exec "$container" "$CLI_PATH" -datadir="$DATADIR" \
            -rpcwallet="$wallet" getquantumkeyinventory | jq -cS . | sha256sum | awk '{print $1}') || return 1
        legacy=$(timeout --foreground -k 2 45 docker exec "$container" "$CLI_PATH" -datadir="$DATADIR" \
            -rpcwallet="$wallet" getgoldrushinfo | jq -cS \
            '[.wallet_scripts[].address] | unique | sort | select(length > 0)' | \
            sha256sum | awk '{print $1}') || return 1
        manifest="$STATE_DIR/runtime-wallet-manifests/node-$(node_padded "$node").json"
        identity="$STATE_DIR/runtime-identity-manifests/node-$(node_padded "$node").json"
        pow_manifest="$STATE_DIR/pow-wallet-manifests/node-$(node_padded "$node").json"
        runtime_sha=$(sha256sum "$manifest" | awk '{print $1}') || return 1
        identity_sha=$(sha256sum "$identity" | awk '{print $1}') || return 1
        pow_sha=$(sha256sum "$pow_manifest" | awk '{print $1}') || return 1
        conf_sha=$(sha256sum "$(host_datadir_for "$node")/blackcoin.conf" | awk '{print $1}') || return 1
        if [[ -f "$(host_datadir_for "$node")/settings.json" ]]; then
            settings_sha=$(sha256sum "$(host_datadir_for "$node")/settings.json" | awk '{print $1}') || return 1
        else
            settings_sha=absent
        fi
        container_id=$(docker inspect -f '{{.Id}}' "$container") || return 1
        container_started=$(docker inspect -f '{{.State.StartedAt}}' "$container") || return 1
        vpn_id=$(docker inspect -f '{{.Id}}' "$vpn") || return 1
        vpn_started=$(docker inspect -f '{{.State.StartedAt}}' "$vpn") || return 1
        jq -cn \
            --argjson node "$node" --arg container "$container" --arg vpn "$vpn" \
            --arg wallets "$wallets" --arg qaddr "$qaddr" --arg qinv "$qinv" --arg legacy "$legacy" \
            --arg runtime_manifest "$runtime_sha" --arg identity_manifest "$identity_sha" \
            --arg pow_manifest "$pow_sha" --arg conf "$conf_sha" --arg settings "$settings_sha" \
            --arg container_id "$container_id" --arg container_started "$container_started" \
            --arg vpn_id "$vpn_id" --arg vpn_started "$vpn_started" \
            '{node:$node,container:$container,vpn:$vpn,wallets_json:$wallets,
              quantum_addresses_sha256:$qaddr,quantum_inventory_sha256:$qinv,
              legacy_addresses_sha256:$legacy,
              runtime_manifest_sha256:$runtime_manifest,
              identity_manifest_sha256:$identity_manifest,pow_manifest_sha256:$pow_manifest,
              blackcoin_conf_sha256:$conf,settings_json_sha256:$settings,container_id:$container_id,
              container_started_at:$container_started,vpn_id:$vpn_id,vpn_started_at:$vpn_started}' \
            >> "$output"
    done
    jq -s 'sort_by(.node)' "$output" > "${output}.json"
    mv -- "${output}.json" "$output"
}

capture_free_claim_container_identity()
{
    local output="$1" inspect temporary
    inspect=$(docker inspect blackcoin-pool-api) || return 1
    temporary="${output}.tmp.$$"
    jq -S 'if length == 1 then .[0] else error("expected one Free Claim API container") end |
        {id:.Id,image_id:.Image,name:.Name,
          config:{image:.Config.Image,user:.Config.User,entrypoint:.Config.Entrypoint,
            cmd:.Config.Cmd,labels:.Config.Labels,healthcheck:.Config.Healthcheck},
          host:{restart_policy:.HostConfig.RestartPolicy,network_mode:.HostConfig.NetworkMode,
            privileged:.HostConfig.Privileged,readonly_rootfs:.HostConfig.ReadonlyRootfs,
            binds:.HostConfig.Binds,tmpfs:.HostConfig.Tmpfs,security_opt:.HostConfig.SecurityOpt,
            cap_add:.HostConfig.CapAdd,cap_drop:.HostConfig.CapDrop},
          mounts:[.Mounts[] | {type:.Type,source:.Source,destination:.Destination,rw:.RW}] | sort_by(.destination)}' \
        <<< "$inspect" > "$temporary" || {
        rm -f -- "$temporary"
        return 1
    }
    chmod 600 "$temporary"
    chown root:root "$temporary"
    mv -fT -- "$temporary" "$output"
}

assert_free_claim_container_identity_matches_baseline()
{
    local output="$1"
    capture_free_claim_container_identity "$output" || return 1
    cmp -s "$RUN_DIR/baseline/free-claim-container-identity.json" "$output"
}

assert_fleet_identity_matches_baseline()
{
    local output="$1"
    capture_fleet_identity "$output" || return 1
    jq -e -n --slurpfile before "$RUN_DIR/baseline/fleet-identity.json" \
        --slurpfile after "$output" '
        def identity($rows): $rows[0] | map({node,wallets_json,legacy_addresses_sha256,
          quantum_addresses_sha256,
          quantum_inventory_sha256,runtime_manifest_sha256,identity_manifest_sha256,
          pow_manifest_sha256,blackcoin_conf_sha256,settings_json_sha256,vpn_id});
        identity($before) == identity($after)
    ' >/dev/null
}

wave_nodes_for_index()
{
    local wanted="$1" line index=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=${line%%#*}
        line=$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' <<< "$line")
        [[ -n "$line" ]] || continue
        index=$((index + 1))
        if [[ "$index" -eq "$wanted" ]]; then
            read -r -a expected_nodes <<< "$line"
            printf '%s\n' "${expected_nodes[*]}"
            return 0
        fi
    done < "$WAVE_PLAN"
    return 1
}

write_wave_candidate_source_inventory()
{
    local path="$CURRENT_WAVE_DIR/candidate-launch-sources.json" rows node generation inspect
    local old_ref old_id
    [[ ! -e "$path" && ! -L "$path" ]] || return 1
    rows=$(mktemp "$CURRENT_WAVE_DIR/.candidate-launch-sources.XXXXXX") || return 1
    : > "$rows"
    for node in "${CURRENT_WAVE_NODES[@]}"; do
        generation=$(container_generation_for "$node") || { rm -f -- "$rows"; return 1; }
        old_ref=$(rollback_old_config_image_for "$node") || { rm -f -- "$rows"; return 1; }
        old_id=$(rollback_old_image_id_for "$node") || { rm -f -- "$rows"; return 1; }
        inspect=$(docker inspect "$(container_for "$node")") || { rm -f -- "$rows"; return 1; }
        jq -e --arg ref "$old_ref" --arg id "$old_id" '
            length == 1 and .[0].Config.Image == $ref and .[0].Image == $id and
            .[0].State.Running == true and .[0].State.Pid > 0 and
            .[0].State.Paused == false and .[0].State.Restarting == false
        ' >/dev/null <<< "$inspect" || { rm -f -- "$rows"; return 1; }
        [[ "$(container_generation_for "$node")" == "$generation" ]] || {
            rm -f -- "$rows"; return 1;
        }
        jq -cn --argjson node "$node" --arg container "$(container_for "$node")" \
            --arg generation "$generation" --arg config_image "$old_ref" --arg image_id "$old_id" '
            {node:$node,container:$container,container_generation:$generation,
             config_image:$config_image,image_id:$image_id}' >> "$rows" || {
            rm -f -- "$rows"; return 1;
        }
    done
    if ! jq -sS 'sort_by(.node)' "$rows" | atomic_write_json "$path"; then
        rm -f -- "$rows"
        return 1
    fi
    rm -f -- "$rows"
    verify_wave_candidate_source_inventory
}

verify_wave_candidate_source_inventory()
{
    local wave_dir="${1:-$CURRENT_WAVE_DIR}" expected_nodes node entry
    local generation old_ref old_id
    local CURRENT_WAVE_DIR="$wave_dir"
    local -a CURRENT_WAVE_NODES=()
    [[ -f "$wave_dir/NODES" && ! -L "$wave_dir/NODES" ]] || return 1
    read -r -a CURRENT_WAVE_NODES < "$wave_dir/NODES"
    local path="$CURRENT_WAVE_DIR/candidate-launch-sources.json"
    data_rollback_protected_file "$path" 600 || return 1
    expected_nodes=$(printf '%s\n' "${CURRENT_WAVE_NODES[@]}" | jq -sc 'map(tonumber)') ||
        return 1
    jq -e --argjson nodes "$expected_nodes" '
        type == "array" and [.[] | .node] == $nodes and
        all(.[];
          (keys | sort) == (["node","container","container_generation",
            "config_image","image_id"] | sort) and
          (.node | type) == "number" and (.container | type) == "string" and
          (.container_generation | type) == "string" and
          (.config_image | type) == "string" and
          (.image_id | test("^sha256:[0-9a-f]{64}$")))
    ' "$path" >/dev/null || return 1
    for node in "${CURRENT_WAVE_NODES[@]}"; do
        entry=$(jq -cer --argjson node "$node" '.[] | select(.node == $node)' "$path") || return 1
        [[ "$(jq -r --argjson node "$node" \
            '[.[] | select(.node == $node)] | length' "$path")" == 1 ]] || return 1
        generation=$(jq -er '.container_generation' <<< "$entry") || return 1
        data_rollback_validate_stopped_generation "$generation" || return 1
        old_ref=$(rollback_old_config_image_for "$node") || return 1
        old_id=$(rollback_old_image_id_for "$node") || return 1
        jq -e --arg container "$(container_for "$node")" --arg generation "$generation" \
            --arg ref "$old_ref" --arg id "$old_id" '
            .container == $container and .container_generation == $generation and
            .config_image == $ref and .image_id == $id
        ' >/dev/null <<< "$entry" || return 1
    done
}

verify_wave_node_identity()
{
    local wave_dir="$1" wave_index="$2" expected actual node
    local -A seen=()
    [[ "$wave_index" =~ ^[1-9][0-9]*$ ]] || return 1
    expected=$(wave_nodes_for_index "$wave_index") || return 1
    [[ -f "$wave_dir/NODES" && ! -L "$wave_dir/NODES" ]] || return 1
    read -r -a actual_nodes < "$wave_dir/NODES"
    actual=${actual_nodes[*]}
    [[ "$actual" == "$expected" ]] || return 1
    ((${#actual_nodes[@]} >= 1 && ${#actual_nodes[@]} <= MAX_WAVE_SIZE)) || return 1
    for node in "${actual_nodes[@]}"; do
        valid_node "$node" || return 1
        [[ -z "${seen[$node]:-}" ]] || return 1
        seen[$node]=1
    done
}

write_wave_evidence_manifest()
{
    local wave_index="$1" wave_plan_sha temporary node
    local files=(
        NODES unaffected.before
        candidate-launch-sources.json
        docker-compose.before.yml fleet-image-policy.before.json blackcoin_endpoint_guard.before.sh
        docker-compose.candidate.yml fleet-image-policy.candidate.json blackcoin_endpoint_guard.candidate.sh
    )
    if [[ -f "$CURRENT_WAVE_DIR/node30-legacy-pow.before.json" ]]; then
        files+=(node30-legacy-pow.before.json)
    fi
    for node in "${CURRENT_WAVE_NODES[@]}"; do
        files+=("node-$(node_padded "$node")-loaded-wallet.txt")
        files+=("node-$(node_padded "$node")-legacy-pow.before-drain.json")
    done
    verify_wave_node_identity "$CURRENT_WAVE_DIR" "$wave_index" ||
        die 'wave nodes do not match the pinned wave plan'
    write_wave_candidate_source_inventory ||
        die 'wave candidate source inventory could not be durably published'
    wave_plan_sha=$(sha256sum "$WAVE_PLAN" | awk '{print $1}')
    jq -n --argjson index "$wave_index" --arg nodes "${CURRENT_WAVE_NODES[*]}" \
        --arg wave_plan_sha256 "$wave_plan_sha" \
        '{schema:1,wave_index:$index,nodes:$nodes,wave_plan_sha256:$wave_plan_sha256}' \
        > "$CURRENT_WAVE_DIR/WAVE-IDENTITY.json"
    files+=(WAVE-IDENTITY.json)
    temporary="$CURRENT_WAVE_DIR/.WAVE-EVIDENCE.sha256.$$"
    (
        cd "$CURRENT_WAVE_DIR"
        sha256sum "${files[@]}"
    ) > "$temporary"
    mv -fT -- "$temporary" "$CURRENT_WAVE_DIR/WAVE-EVIDENCE.sha256"
    sync -f "$CURRENT_WAVE_DIR/WAVE-EVIDENCE.sha256"
    sync -f "$CURRENT_WAVE_DIR"
}

verify_wave_evidence_manifest()
{
    local wave_dir="$1" wave_index="$2" expected_nodes wave_plan_sha
    [[ -d "$wave_dir" && ! -L "$wave_dir" && "$wave_dir" == "$RUN_DIR"/wave-* ]] || return 1
    [[ -f "$wave_dir/WAVE-EVIDENCE.sha256" && ! -L "$wave_dir/WAVE-EVIDENCE.sha256" &&
       -f "$wave_dir/WAVE-IDENTITY.json" && ! -L "$wave_dir/WAVE-IDENTITY.json" ]] || return 1
    (cd "$wave_dir" && sha256sum --strict -c WAVE-EVIDENCE.sha256 >/dev/null) || return 1
    verify_wave_node_identity "$wave_dir" "$wave_index" || return 1
    verify_wave_candidate_source_inventory "$wave_dir" || return 1
    expected_nodes=$(wave_nodes_for_index "$wave_index") || return 1
    wave_plan_sha=$(sha256sum "$WAVE_PLAN" | awk '{print $1}') || return 1
    jq -e --argjson index "$wave_index" --arg nodes "$expected_nodes" \
        --arg wave_plan_sha256 "$wave_plan_sha" '
        . == {schema:1,wave_index:$index,nodes:$nodes,wave_plan_sha256:$wave_plan_sha256}
    ' "$wave_dir/WAVE-IDENTITY.json" >/dev/null
}

publish_wave_drain_evidence_manifest()
{
    local manifest temporary node padded
    local -a files=(LEGACY-POW-DRAIN.json)
    manifest=$(wave_drain_manifest_path) || return 1
    [[ ! -e "$manifest" && ! -L "$manifest" ]] || return 1
    verify_wave_drain_payload || return 1
    for node in "${CURRENT_WAVE_NODES[@]}"; do
        padded=$(node_padded "$node") || return 1
        files+=("node-${padded}-legacy-pow.before-drain.json"
            "node-${padded}-legacy-pow.after-drain.json"
            "node-${padded}-legacy-pow-rollback-plan.json"
            "node-${padded}-wallet.after-drain.json"
            "node-${padded}-staking.after-drain.json"
            "node-${padded}-wallet-txids.prelaunch.json")
    done
    temporary=$(mktemp "$CURRENT_WAVE_DIR/.WAVE-DRAIN-EVIDENCE.XXXXXX") || return 1
    (cd "$CURRENT_WAVE_DIR" && sha256sum "${files[@]}") > "$temporary" || {
        rm -f -- "$temporary"; return 1;
    }
    if ! chmod 600 "$temporary" || ! chown root:root "$temporary" ||
       ! sync -f "$temporary" || ! mv -T -- "$temporary" "$manifest" ||
       ! sync -f "$CURRENT_WAVE_DIR"; then
        rm -f -- "$temporary"
        return 1
    fi
    verify_wave_drain_evidence
}

write_wave_drain_evidence()
{
    local node padded before after wallet staking txids node_plan mode role action temporary entries
    local plan manifest
    local before_sha after_sha wallet_sha staking_sha txids_sha
    plan=$(wave_drain_plan_path) || return 1
    manifest=$(wave_drain_manifest_path) || return 1
    if [[ -e "$manifest" || -L "$manifest" ]]; then
        [[ -e "$plan" || -L "$plan" ]] || return 1
        verify_wave_drain_evidence
        return
    fi
    if [[ -e "$plan" || -L "$plan" ]]; then
        publish_wave_drain_evidence_manifest
        return
    fi
    entries=$(mktemp "$CURRENT_WAVE_DIR/.legacy-pow-drain-entries.XXXXXX") || return 1
    : > "$entries"
    for node in "${CURRENT_WAVE_NODES[@]}"; do
        padded=$(node_padded "$node") || { rm -f -- "$entries"; return 1; }
        before="$CURRENT_WAVE_DIR/node-${padded}-legacy-pow.before-drain.json"
        after="$CURRENT_WAVE_DIR/node-${padded}-legacy-pow.after-drain.json"
        wallet="$CURRENT_WAVE_DIR/node-${padded}-wallet.after-drain.json"
        staking="$CURRENT_WAVE_DIR/node-${padded}-staking.after-drain.json"
        txids="$CURRENT_WAVE_DIR/node-${padded}-wallet-txids.prelaunch.json"
        node_plan="$CURRENT_WAVE_DIR/node-${padded}-legacy-pow-rollback-plan.json"
        for temporary in "$before" "$after" "$wallet" "$staking" "$txids"; do
            [[ -f "$temporary" && ! -L "$temporary" &&
               "$(stat -c '%u:%g:%a' "$temporary")" == 0:0:600 ]] || {
                rm -f -- "$entries"; return 1;
            }
        done
        mode=$(legacy_pow_snapshot_mode "$node" "$before") || {
            rm -f -- "$entries"; return 1;
        }
        legacy_pow_projection_is_valid "$node" "$mode" "$before" pre-drain || {
            rm -f -- "$entries"; return 1;
        }
        legacy_pow_projection_is_valid "$node" "$mode" "$after" drained || {
            rm -f -- "$entries"; return 1;
        }
        jq -e '.unlocked_until == 0' "$wallet" >/dev/null || {
            rm -f -- "$entries"; return 1;
        }
        jq -e '.enabled == false and .staking == false and
            ((has("worker_running") | not) or .worker_running == false) and
            .automatic_qqsignal == false and .automatic_demurrage_attestation == false and
            .automatic_redelegation == false and
            .allow_automatic_quantum_key_creation == false' "$staking" >/dev/null || {
            rm -f -- "$entries"; return 1;
        }
        jq -e 'type == "array" and . == (unique | sort) and
            all(.[]; type == "string" and test("^[0-9a-f]{64}$"))' "$txids" >/dev/null || {
            rm -f -- "$entries"; return 1;
        }
        if [[ "$node" -eq "$FREE_CLAIM_NODE" ]]; then
            role=free-claim
            action=skip-pow
        else
            role=regular-pow
            [[ "$mode" == clean-hashing ]] && action=start-pow-helper || action=skip-pow
        fi
        before_sha=$(sha256sum "$before" | awk '{print $1}') || return 1
        after_sha=$(sha256sum "$after" | awk '{print $1}') || return 1
        wallet_sha=$(sha256sum "$wallet" | awk '{print $1}') || return 1
        staking_sha=$(sha256sum "$staking" | awk '{print $1}') || return 1
        txids_sha=$(sha256sum "$txids" | awk '{print $1}') || return 1
        jq -cn --argjson node "$node" --arg role "$role" --arg mode "$mode" \
            --arg action "$action" --arg before_sha "$before_sha" --arg after_sha "$after_sha" \
            --arg wallet_sha "$wallet_sha" --arg staking_sha "$staking_sha" \
            --arg txids_sha "$txids_sha" --slurpfile before "$before" --slurpfile after "$after" '
            {node:$node,role:$role,mode:$mode,rollback_pow_action:$action,
             before_drain_sha256:$before_sha,post_drain_sha256:$after_sha,
             post_drain_wallet_sha256:$wallet_sha,post_drain_staking_sha256:$staking_sha,
             prelaunch_wallet_txids_sha256:$txids_sha,
             baseline:($before[0] | {enabled,autostart,state,threads,cpu_percent,hashrate,
               unresolved_claims,live_claims,quarantined_claims,
               allow_automatic_quantum_key_creation}),
             post_drain:($after[0] | {enabled,autostart,state,threads,cpu_percent,hashrate,
               unresolved_claims,live_claims,quarantined_claims,
               allow_automatic_quantum_key_creation})}' | atomic_write_json "$node_plan" || {
            rm -f -- "$entries"; return 1;
        }
        jq -cS . "$node_plan" >> "$entries" || { rm -f -- "$entries"; return 1; }
    done
    jq -sS --arg run "$RUN_DIR" --arg wave "$CURRENT_WAVE_DIR" \
        '{schema:1,transaction:"v30.1.4-fleet-rollout",run_dir:$run,wave_dir:$wave,
          authority:"post-drain-prelaunch",fee_payments_authorized:false,
          entries:(sort_by(.node))}' "$entries" | atomic_write_json "$(wave_drain_plan_path)" || {
        rm -f -- "$entries"; return 1;
    }
    rm -f -- "$entries"
    publish_wave_drain_evidence_manifest
}

verify_wave_drain_payload()
{
    local plan node padded before after wallet staking txids node_plan entry mode
    plan=$(wave_drain_plan_path) || return 1
    [[ -f "$plan" && ! -L "$plan" && "$(stat -c '%u:%g:%a' "$plan")" == 0:0:600 ]] ||
        return 1
    jq -e --arg run "$RUN_DIR" --arg wave "$CURRENT_WAVE_DIR" \
        --argjson count "${#CURRENT_WAVE_NODES[@]}" '
        .schema == 1 and .transaction == "v30.1.4-fleet-rollout" and
        .run_dir == $run and .wave_dir == $wave and .authority == "post-drain-prelaunch" and
        .fee_payments_authorized == false and (.entries | length) == $count and
        [.entries[].node] == ([.entries[].node] | sort)
    ' "$plan" >/dev/null || return 1
    for node in "${CURRENT_WAVE_NODES[@]}"; do
        padded=$(node_padded "$node") || return 1
        before="$CURRENT_WAVE_DIR/node-${padded}-legacy-pow.before-drain.json"
        after="$CURRENT_WAVE_DIR/node-${padded}-legacy-pow.after-drain.json"
        wallet="$CURRENT_WAVE_DIR/node-${padded}-wallet.after-drain.json"
        staking="$CURRENT_WAVE_DIR/node-${padded}-staking.after-drain.json"
        txids="$CURRENT_WAVE_DIR/node-${padded}-wallet-txids.prelaunch.json"
        node_plan="$CURRENT_WAVE_DIR/node-${padded}-legacy-pow-rollback-plan.json"
        [[ -f "$node_plan" && ! -L "$node_plan" &&
           "$(stat -c '%u:%g:%a' "$node_plan")" == 0:0:600 ]] || return 1
        entry=$(jq -ce --argjson node "$node" '.entries[] | select(.node == $node)' "$plan") ||
            return 1
        [[ "$(jq -c --argjson node "$node" '[.entries[] | select(.node == $node)] | length' "$plan")" == 1 ]] ||
            return 1
        mode=$(jq -er '.mode' <<< "$entry") || return 1
        cmp -s "$node_plan" <(jq -S . <<< "$entry") || return 1
        legacy_pow_projection_is_valid "$node" "$mode" "$before" pre-drain || return 1
        legacy_pow_projection_is_valid "$node" "$mode" "$after" drained || return 1
        verify_legacy_pow_drain_exact "$node" "$node_plan" "$after" || return 1
        jq -e '.unlocked_until == 0' "$wallet" >/dev/null || return 1
        jq -e '.enabled == false and .staking == false and
            ((has("worker_running") | not) or .worker_running == false) and
            .automatic_qqsignal == false and .automatic_demurrage_attestation == false and
            .automatic_redelegation == false and
            .allow_automatic_quantum_key_creation == false' "$staking" >/dev/null || return 1
        jq -e 'type == "array" and . == (unique | sort) and
            all(.[]; type == "string" and test("^[0-9a-f]{64}$"))' "$txids" >/dev/null || return 1
        jq -e --argjson node "$node" --arg before "$(sha256sum "$before" | awk '{print $1}')" \
            --arg after "$(sha256sum "$after" | awk '{print $1}')" \
            --arg wallet "$(sha256sum "$wallet" | awk '{print $1}')" \
            --arg staking "$(sha256sum "$staking" | awk '{print $1}')" \
            --arg txids "$(sha256sum "$txids" | awk '{print $1}')" '
            .node == $node and .before_drain_sha256 == $before and
            .post_drain_sha256 == $after and .post_drain_wallet_sha256 == $wallet and
            .post_drain_staking_sha256 == $staking and
            .prelaunch_wallet_txids_sha256 == $txids
        ' <<< "$entry" >/dev/null || return 1
    done
}

verify_wave_drain_evidence()
{
    local manifest
    manifest=$(wave_drain_manifest_path) || return 1
    [[ -f "$manifest" && ! -L "$manifest" &&
       "$(stat -c '%u:%g:%a' "$manifest")" == 0:0:600 ]] || return 1
    (cd "$CURRENT_WAVE_DIR" && sha256sum --strict -c "${manifest##*/}" >/dev/null) || return 1
    verify_wave_drain_payload
}

wave_legacy_plan_entry()
{
    local node="$1" path
    verify_wave_drain_evidence || return 1
    path="$CURRENT_WAVE_DIR/node-$(node_padded "$node")-legacy-pow-rollback-plan.json"
    [[ -f "$path" && ! -L "$path" ]] || return 1
    printf '%s\n' "$path"
}

legacy_plan_file_for_node()
{
    local node="$1" wave plan node_plan count result rollback_state current_plan=''
    local wave_name lineage authority_lineage=''
    local caller_wave_dir="${CURRENT_WAVE_DIR:-}"
    local CURRENT_WAVE_DIR
    local -a CURRENT_WAVE_NODES=()
    local -a passed_plans=() interrupted_plans=() restored_plans=()
    while IFS= read -r wave; do
        plan="$wave/LEGACY-POW-DRAIN.json"
        [[ -f "$plan" && ! -L "$plan" ]] || continue
        count=$(jq -r --argjson node "$node" '[.entries[] | select(.node == $node)] | length' \
            "$plan" 2>/dev/null) || return 1
        if [[ "$count" == 1 ]]; then
            wave_name=${wave##*/}
            [[ "$wave_name" =~ ^(wave-[0-9]{2}-nodes-[0-9]+(-[0-9]+)*)(-retry-[0-9]{2})?$ ]] ||
                return 1
            lineage=${BASH_REMATCH[1]}
            if [[ -z "$authority_lineage" ]]; then
                authority_lineage=$lineage
            else
                [[ "$lineage" == "$authority_lineage" ]] || return 1
            fi
            node_plan="$wave/node-$(node_padded "$node")-legacy-pow-rollback-plan.json"
            [[ -f "$node_plan" && ! -L "$node_plan" && -f "$wave/NODES" &&
               ! -L "$wave/NODES" ]] || return 1
            CURRENT_WAVE_DIR="$wave"
            read -r -a CURRENT_WAVE_NODES < "$wave/NODES"
            verify_wave_drain_evidence || return 1
            [[ "$wave" == "$caller_wave_dir" ]] && current_plan="$node_plan"
            if [[ -f "$wave/RESULT" && ! -L "$wave/RESULT" ]]; then
                result=$(cat "$wave/RESULT") || return 1
                case "$result" in
                    passed) passed_plans+=("$node_plan") ;;
                    rolled-back)
                        [[ -f "$wave/ROLLBACK_STATE" && ! -L "$wave/ROLLBACK_STATE" ]] || return 1
                        rollback_state=$(cat "$wave/ROLLBACK_STATE") || return 1
                        [[ "$rollback_state" == rollback-passed ]] || return 1
                        restored_plans+=("$node_plan")
                        ;;
                    *) return 1 ;;
                esac
            else
                [[ -f "$wave/COMMIT_STATE" && ! -L "$wave/COMMIT_STATE" ]] || return 1
                interrupted_plans+=("$node_plan")
            fi
            continue
        fi
        [[ "$count" == 0 ]] || return 1
    done < <(find "$RUN_DIR" -maxdepth 1 -type d -name 'wave-*' -print | sort)
    ((${#passed_plans[@]} <= 1 && ${#interrupted_plans[@]} <= 1)) || return 1
    if ((${#interrupted_plans[@]} == 1)); then
        ((${#passed_plans[@]} == 0)) || return 1
        [[ -n "$current_plan" && "$current_plan" == "${interrupted_plans[0]}" ]] || return 1
        printf '%s\n' "$current_plan"
        return 0
    fi
    if ((${#passed_plans[@]} == 1)); then
        if [[ -n "$current_plan" ]]; then
            [[ "$current_plan" == "${passed_plans[0]}" ]] || return 1
        fi
        printf '%s\n' "${passed_plans[0]}"
        return 0
    fi
    if ((${#restored_plans[@]} >= 1)); then
        # Attempts are discovered in canonical base/retry order. The final
        # rollback-passed attempt is the only authority for the live legacy
        # state after all newer passed/current authorities have been excluded.
        printf '%s\n' "${restored_plans[${#restored_plans[@]} - 1]}"
        return 0
    fi
    return 2
}

write_wave_runtime_evidence()
{
    local node temporary
    local -a files=(wave-chain-convergence/PASSED.json WAVE-DRAIN-EVIDENCE.sha256
        CANDIDATE_LAUNCH_AUTHORIZED CANDIDATE_LAUNCH_ATTEMPTED)
    verify_wave_drain_evidence || return 1
    verify_complete_wave_candidate_launch_markers || return 1
    for node in "${CURRENT_WAVE_NODES[@]}"; do
        verify_candidate_recovery_baseline "$node" || return 1
        files+=("node-$(node_padded "$node")-wallet-txids.first-v3014.json")
        files+=("candidate-recovery-node-$(node_padded "$node").json")
        files+=("candidate-recovery-node-$(node_padded "$node").json.sha256")
        files+=("node-$(node_padded "$node")-CANDIDATE-LAUNCH-AUTHORIZED.json")
        files+=("node-$(node_padded "$node")-CANDIDATE-LAUNCH-ATTEMPTED.json")
        files+=("node-$(node_padded "$node")-CANDIDATE-ACTIVATION-ATTEMPTED.json")
    done
    publish_state_token "$CURRENT_WAVE_DIR/RUNTIME-GATE-PASSED" \
        exact-wave-runtime-gate-passed || return 1
    files+=(RUNTIME-GATE-PASSED)
    temporary="$CURRENT_WAVE_DIR/.WAVE-RUNTIME-EVIDENCE.sha256.$$"
    (cd "$CURRENT_WAVE_DIR" && sha256sum "${files[@]}") > "$temporary" || return 1
    chmod 600 "$temporary"
    chown root:root "$temporary"
    sync -f "$temporary"
    mv -fT -- "$temporary" "$CURRENT_WAVE_DIR/WAVE-RUNTIME-EVIDENCE.sha256"
    sync -f "$CURRENT_WAVE_DIR"
}

verify_wave_runtime_evidence()
{
    local node
    verify_wave_drain_evidence || return 1
    verify_complete_wave_candidate_launch_markers || return 1
    [[ -f "$CURRENT_WAVE_DIR/WAVE-RUNTIME-EVIDENCE.sha256" &&
       ! -L "$CURRENT_WAVE_DIR/WAVE-RUNTIME-EVIDENCE.sha256" &&
       "$(stat -c '%u:%g:%a' "$CURRENT_WAVE_DIR/WAVE-RUNTIME-EVIDENCE.sha256")" == 0:0:600 ]] ||
        return 1
    (cd "$CURRENT_WAVE_DIR" && sha256sum --strict -c WAVE-RUNTIME-EVIDENCE.sha256 >/dev/null) ||
        return 1
    [[ "$(cat "$CURRENT_WAVE_DIR/RUNTIME-GATE-PASSED")" == exact-wave-runtime-gate-passed ]] ||
        return 1
    for node in "${CURRENT_WAVE_NODES[@]}"; do
        verify_candidate_recovery_baseline "$node" || return 1
        verify_candidate_activation_marker "$node" || return 1
    done
}

capture_unaffected_generations()
{
    local output="$1" skip_csv="$2" node generation
    : > "$output"
    for node in $(seq 1 "$NODE_COUNT"); do
        [[ ",$skip_csv," == *",$node,"* ]] && continue
        generation=$(container_generation_for "$node") || return 1
        printf '%02d|%s\n' "$node" "$generation" >> "$output"
    done
}

capture_transaction_baseline()
{
    local marker_dir="$RUN_DIR/baseline/markers-present" node pid failed=0 entries temporary mode role
    local deadline round_dir padded captured=0
    local -a pids=() nodes=()
    install -d -m 700 -o root -g root "$RUN_DIR/baseline" "$marker_dir"
    install -m 600 -o root -g root "$COMPOSE_FILE" "$RUN_DIR/baseline/docker-compose.yml"
    install -m 600 -o root -g root "$IMAGE_POLICY" "$RUN_DIR/baseline/fleet-image-policy.json"
    install -m 600 -o root -g root "$ENDPOINT_GUARD" "$RUN_DIR/baseline/blackcoin_endpoint_guard.sh"
    install -m 600 -o root -g root "$WALLET_RUNTIME_GUARD" \
        "$RUN_DIR/baseline/blackcoin_wallet_runtime_guard.sh"
    install -m 600 -o root -g root "$NORMAL_UNLOCK_HELPER" \
        "$RUN_DIR/baseline/blackcoin_node_normal_unlock.sh"
    install -m 600 -o root -g root "$POW_START_HELPER" \
        "$RUN_DIR/baseline/blackcoin_pow_start_only.sh"
    if [[ "$CANARY_HANDOFF_PENDING" -eq 1 ]]; then
        verify_published_canary_handoff_ready ||
            die 'active canary handoff evidence changed before baseline capture'
        install -m 600 -o root -g root "$ROLLOUT_MAINTENANCE_MARKER" \
            "$RUN_DIR/baseline/CANARY-MAINTENANCE-PREDECESSOR.json"
    fi
    if [[ -e "$ENABLE_GUARD_STARTS" || -L "$ENABLE_GUARD_STARTS" ]]; then
        assert_empty_control_marker "$ENABLE_GUARD_STARTS" || die 'guard-start marker became unsafe or nonempty'
        install -m 600 -o root -g root "$ENABLE_GUARD_STARTS" "$marker_dir/ENABLE_GUARD_STARTS"
    fi
    capture_fleet_identity "$RUN_DIR/baseline/fleet-identity.json"
    capture_free_claim_container_identity "$RUN_DIR/baseline/free-claim-container-identity.json" ||
        die 'Free Claim API container identity could not be captured'
    deadline=$((SECONDS + 1200))
    while ((SECONDS < deadline)); do
        round_dir=$(mktemp -d "$RUN_DIR/baseline/.legacy-pow-round.XXXXXX")
        chmod 700 "$round_dir" && chown root:root "$round_dir"
        pids=()
        for node in $(seq 1 "$NODE_COUNT"); do
            padded=$(node_padded "$node")
            (wallet_rpc_for "$node" getpowmininginfo | jq -S . > "$round_dir/node-${padded}.json") &
            pids+=("$!")
        done
        failed=0
        for pid in "${pids[@]}"; do wait "$pid" || failed=1; done
        for node in $(seq 1 "$NODE_COUNT"); do
            padded=$(node_padded "$node")
            temporary="$round_dir/node-${padded}.json"
            [[ "$failed" -eq 0 && -s "$temporary" ]] || { failed=1; continue; }
            chmod 600 "$temporary" && chown root:root "$temporary"
            mode=$(legacy_pow_snapshot_mode "$node" "$temporary" 2>/dev/null || true)
            [[ -n "$mode" ]] &&
                legacy_pow_projection_is_valid "$node" "$mode" "$temporary" pre-drain || failed=1
        done
        if ((failed == 0)); then
            for node in $(seq 1 "$NODE_COUNT"); do
                padded=$(node_padded "$node")
                temporary="$round_dir/node-${padded}.json"
                sync -f "$temporary"
                mv -fT -- "$temporary" "$RUN_DIR/baseline/legacy-node-${padded}-pow.json"
            done
            rmdir "$round_dir"
            sync -f "$RUN_DIR/baseline"
            captured=1
            break
        fi
        rm -rf -- "$round_dir"
        sleep 5
    done
    ((captured == 1)) ||
        die 'all 32 nodes did not concurrently reach an allowed pre-drain PoW state within 20 minutes'
    entries=$(mktemp "$RUN_DIR/baseline/.legacy-pow-initial.XXXXXX")
    : > "$entries"
    for node in $(seq 1 "$NODE_COUNT"); do
        temporary="$RUN_DIR/baseline/legacy-node-$(node_padded "$node")-pow.json"
        mode=$(legacy_pow_snapshot_mode "$node" "$temporary") ||
            die "node $node initial legacy PoW mode is invalid"
        if [[ "$node" -eq "$FREE_CLAIM_NODE" ]]; then role=free-claim; else role=regular-pow; fi
        jq -cn --argjson node "$node" --arg role "$role" --arg mode "$mode" \
            --arg sha "$(sha256sum "$temporary" | awk '{print $1}')" --slurpfile raw "$temporary" '
            {node:$node,role:$role,mode:$mode,raw_sha256:$sha,
             projection:($raw[0] | {enabled,autostart,state,threads,cpu_percent,hashrate,
               unresolved_claims,live_claims,quarantined_claims,
               allow_automatic_quantum_key_creation})}' >> "$entries"
    done
    jq -sS '{schema:1,authority:"transaction-start-audit-only",entries:(sort_by(.node))}' \
        "$entries" | atomic_write_json "$RUN_DIR/baseline/LEGACY-POW-INITIAL.json" ||
        die 'initial legacy PoW inventory could not be committed'
    rm -f -- "$entries"
    docker exec blackcoin-pool-api curl -fsS --max-time 5 http://127.0.0.1:8377/status \
        > "$RUN_DIR/baseline/free-claim-status.json"
    (
        cd "$RUN_DIR/baseline"
        find . -type f -print0 | sort -z | xargs -0 sha256sum
    ) > "$RUN_DIR/.baseline-SHA256SUMS"
    mv -- "$RUN_DIR/.baseline-SHA256SUMS" "$RUN_DIR/baseline/SHA256SUMS"
    sync -f "$RUN_DIR/baseline/SHA256SUMS"
    sync -f "$RUN_DIR/baseline"
}

verify_legacy_rollback_readiness_all_nodes()
{
    local node pid attempt index batch_start batch_end
    local -a readiness_pending=() readiness_next=() pids=() nodes=()
    for node in $(seq 1 "$NODE_COUNT"); do readiness_pending+=("$node"); done
    for attempt in $(seq 1 60); do
        readiness_next=()
        batch_start=0
        while ((batch_start < ${#readiness_pending[@]})); do
            batch_end=$((batch_start + 4))
            ((batch_end <= ${#readiness_pending[@]})) || batch_end=${#readiness_pending[@]}
            pids=()
            nodes=()
            for ((index=batch_start; index<batch_end; index++)); do
                node=${readiness_pending[$index]}
                verify_policy_legacy_runtime_gate "$node" &
                pids+=("$!")
                nodes+=("$node")
            done
            for index in "${!pids[@]}"; do
                pid=${pids[$index]}
                if ! wait "$pid"; then
                    readiness_next+=("${nodes[$index]}")
                fi
            done
            batch_start=$batch_end
        done
        if ((${#readiness_next[@]} == 0)); then
            assert_unique_vpn_proofs || return 1
            assert_empty_control_marker "$ENABLE_GUARD_STARTS"
            return
        fi
        readiness_pending=("${readiness_next[@]}")
        if ((attempt < 60)); then
            log "retrying transient legacy rollback-readiness nodes: ${readiness_pending[*]}"
            sleep 2
        fi
    done
    for node in "${readiness_pending[@]}"; do
        log "legacy rollback-readiness gate failed node=$node"
    done
    return 1
}

write_transaction_manifest()
{
    local package_manifest_sha canary_sha canary_manifest_sha wave_sha temporary maintenance_nonce
    local baseline_manifest_sha handoff_required=true predecessor_sha predecessor_run
    local predecessor_nonce predecessor
    [[ ! -e "$RUN_DIR/package-files.sha256" && ! -e "$RUN_DIR/TRANSACTION.json" ]] ||
        die 'transaction identity outputs already exist'
    (
        cd "$PACKAGE_ROOT"
        find . -type f -print0 | sort -z | xargs -0 sha256sum
    ) > "$RUN_DIR/package-files.sha256"
    package_manifest_sha=$(sha256sum "$RUN_DIR/package-files.sha256" | awk '{print $1}')
    canary_sha=$(sha256sum "$PUBLISHED_CANARY_RESULT" | awk '{print $1}')
    canary_manifest_sha=$(sha256sum "$PUBLISHED_CANARY_EVIDENCE_MANIFEST" | awk '{print $1}')
    [[ "$canary_sha" == "$EXPECTED_CANARY_RESULT_SHA256" &&
       "$canary_manifest_sha" == "$EXPECTED_CANARY_EVIDENCE_MANIFEST_SHA256" ]] ||
        die 'canary evidence changed before transaction manifest creation'
    wave_sha=$(sha256sum "$WAVE_PLAN" | awk '{print $1}')
    baseline_manifest_sha=$(sha256sum "$RUN_DIR/baseline/SHA256SUMS" | awk '{print $1}')
    predecessor=$(canary_predecessor_path)
    [[ -f "$predecessor" && ! -L "$predecessor" &&
       "$(stat -c '%u:%g:%a' "$predecessor")" == 0:0:600 ]] ||
        die 'transaction manifest requires the authenticated active canary predecessor'
    predecessor_sha=$(sha256sum "$predecessor" | awk '{print $1}')
    predecessor_run=$(jq -er '.run_dir' "$predecessor")
    predecessor_nonce=$(jq -er '.run_nonce' "$predecessor")
    maintenance_nonce=$(cat "$(maintenance_nonce_path)")
    valid_sha256_hex "$maintenance_nonce" || die 'maintenance nonce changed before manifest creation'
    temporary="$RUN_DIR/.TRANSACTION.json.$$"
    jq -n \
        --arg image "$CANDIDATE_IMAGE_REF" --arg image_id "$CANDIDATE_IMAGE_ID" \
        --arg source "$SOURCE_COMMIT" --arg source_key "$SOURCE_LABEL_KEY" \
        --arg source_value "$SOURCE_LABEL_VALUE" --arg version_key "$VERSION_LABEL_KEY" \
        --arg version_value "$VERSION_LABEL_VALUE" --arg daemon "$BLACKCOIND_SHA256" \
        --arg cli "$BLACKCOIN_CLI_SHA256" --arg canary_path "$PUBLISHED_CANARY_RESULT" \
        --arg canary_sha "$canary_sha" --arg canary_manifest "$PUBLISHED_CANARY_EVIDENCE_MANIFEST" \
        --arg canary_manifest_sha "$canary_manifest_sha" --arg wave_sha "$wave_sha" \
        --arg package_sha "$package_manifest_sha" --arg baseline_sha "$baseline_manifest_sha" \
        --arg compose "$EXPECTED_COMPOSE_SHA256" \
        --arg policy "$EXPECTED_IMAGE_POLICY_SHA256" --arg guard "$EXPECTED_ENDPOINT_GUARD_SHA256" \
        --arg runtime_guard "$EXPECTED_WALLET_RUNTIME_GUARD_SHA256" \
        --arg unlock_helper "$NORMAL_UNLOCK_HELPER_SHA256" --arg pow_helper "$POW_START_HELPER_SHA256" \
        --arg maintenance_nonce "$maintenance_nonce" --argjson handoff_required "$handoff_required" \
        --arg predecessor_sha "$predecessor_sha" --arg predecessor_run "$predecessor_run" \
        --arg predecessor_nonce "$predecessor_nonce" \
        '{schema:1,candidate_image:$image,candidate_image_id:$image_id,source_commit:$source,
          source_label:{key:$source_key,value:$source_value},
          version_label:{key:$version_key,value:$version_value},
          blackcoind_sha256:$daemon,blackcoin_cli_sha256:$cli,
          published_canary:{path:$canary_path,sha256:$canary_sha,
            evidence_manifest:{path:$canary_manifest,sha256:$canary_manifest_sha}},
          wave_plan_sha256:$wave_sha,package_files_manifest_sha256:$package_sha,
          baseline_manifest_sha256:$baseline_sha,
          canary_handoff:{required:$handoff_required,protocol:(if $handoff_required then
            "atomic-replace-v1" else "none" end),predecessor_marker_sha256:$predecessor_sha,
            predecessor_run_dir:$predecessor_run,predecessor_run_nonce:$predecessor_nonce},
          maintenance:{marker:"/boot/config/plugins/blackcoin-quantum-nodes/V30_1_4_ROLLOUT_MAINTENANCE.json",
            run_nonce:$maintenance_nonce},
          audited_baseline:{compose_sha256:$compose,image_policy_sha256:$policy,
            endpoint_guard_sha256:$guard,wallet_runtime_guard_sha256:$runtime_guard,
            normal_unlock_helper_sha256:$unlock_helper,pow_start_helper_sha256:$pow_helper}}' > "$temporary"
    install -m 600 -o root -g root "$temporary" "$RUN_DIR/TRANSACTION.json"
    rm -f -- "$temporary"
    chmod 600 "$RUN_DIR/package-files.sha256"
    chown root:root "$RUN_DIR/package-files.sha256"
    sync -f "$RUN_DIR/package-files.sha256"
    sync -f "$RUN_DIR/TRANSACTION.json"
}

verify_transaction_manifest()
{
    local canary_sha canary_manifest_sha wave_sha package_sha maintenance_nonce baseline_manifest_sha
    local handoff_required=true predecessor_sha predecessor_run predecessor_nonce
    local predecessor
    [[ -f "$RUN_DIR/TRANSACTION.json" && ! -L "$RUN_DIR/TRANSACTION.json" &&
       -f "$RUN_DIR/package-files.sha256" && ! -L "$RUN_DIR/package-files.sha256" ]] || return 1
    (cd "$PACKAGE_ROOT" && sha256sum --strict -c "$RUN_DIR/package-files.sha256" >/dev/null) || return 1
    canary_sha=$EXPECTED_CANARY_RESULT_SHA256
    canary_manifest_sha=$EXPECTED_CANARY_EVIDENCE_MANIFEST_SHA256
    valid_sha256_hex "$canary_sha" && valid_sha256_hex "$canary_manifest_sha" || return 1
    wave_sha=$(sha256sum "$WAVE_PLAN" | awk '{print $1}') || return 1
    package_sha=$(sha256sum "$RUN_DIR/package-files.sha256" | awk '{print $1}') || return 1
    baseline_manifest_sha=$(sha256sum "$RUN_DIR/baseline/SHA256SUMS" | awk '{print $1}') || return 1
    predecessor=$(canary_predecessor_path) || return 1
    [[ -f "$predecessor" && ! -L "$predecessor" &&
       "$(stat -c '%u:%g:%a' "$predecessor")" == 0:0:600 ]] || return 1
    predecessor_sha=$(sha256sum "$predecessor" | awk '{print $1}') || return 1
    predecessor_run=$(jq -er '.run_dir' "$predecessor") || return 1
    predecessor_nonce=$(jq -er '.run_nonce' "$predecessor") || return 1
    maintenance_nonce=$(cat "$(maintenance_nonce_path)" 2>/dev/null) || return 1
    valid_sha256_hex "$maintenance_nonce" || return 1
    jq -e \
        --arg image "$CANDIDATE_IMAGE_REF" --arg image_id "$CANDIDATE_IMAGE_ID" \
        --arg source "$SOURCE_COMMIT" --arg source_key "$SOURCE_LABEL_KEY" \
        --arg source_value "$SOURCE_LABEL_VALUE" --arg version_key "$VERSION_LABEL_KEY" \
        --arg version_value "$VERSION_LABEL_VALUE" --arg daemon "$BLACKCOIND_SHA256" \
        --arg cli "$BLACKCOIN_CLI_SHA256" --arg canary_path "$PUBLISHED_CANARY_RESULT" \
        --arg canary_sha "$canary_sha" --arg canary_manifest "$PUBLISHED_CANARY_EVIDENCE_MANIFEST" \
        --arg canary_manifest_sha "$canary_manifest_sha" --arg wave_sha "$wave_sha" \
        --arg package_sha "$package_sha" --arg baseline_sha "$baseline_manifest_sha" \
        --arg compose "$EXPECTED_COMPOSE_SHA256" \
        --arg policy "$EXPECTED_IMAGE_POLICY_SHA256" --arg guard "$EXPECTED_ENDPOINT_GUARD_SHA256" \
        --arg runtime_guard "$EXPECTED_WALLET_RUNTIME_GUARD_SHA256" \
        --arg unlock_helper "$NORMAL_UNLOCK_HELPER_SHA256" --arg pow_helper "$POW_START_HELPER_SHA256" \
        --arg maintenance_nonce "$maintenance_nonce" --argjson handoff_required "$handoff_required" \
        --arg predecessor_sha "$predecessor_sha" --arg predecessor_run "$predecessor_run" \
        --arg predecessor_nonce "$predecessor_nonce" '
        .schema == 1 and .candidate_image == $image and .candidate_image_id == $image_id and
        .source_commit == $source and .source_label == {key:$source_key,value:$source_value} and
        .version_label == {key:$version_key,value:$version_value} and
        .blackcoind_sha256 == $daemon and .blackcoin_cli_sha256 == $cli and
        .published_canary == {path:$canary_path,sha256:$canary_sha,
          evidence_manifest:{path:$canary_manifest,sha256:$canary_manifest_sha}} and
        .wave_plan_sha256 == $wave_sha and .package_files_manifest_sha256 == $package_sha and
        .baseline_manifest_sha256 == $baseline_sha and
        .canary_handoff == {required:$handoff_required,
          protocol:(if $handoff_required then "atomic-replace-v1" else "none" end),
          predecessor_marker_sha256:$predecessor_sha,
          predecessor_run_dir:$predecessor_run,predecessor_run_nonce:$predecessor_nonce} and
        .maintenance == {marker:"/boot/config/plugins/blackcoin-quantum-nodes/V30_1_4_ROLLOUT_MAINTENANCE.json",
          run_nonce:$maintenance_nonce} and
        .audited_baseline == {compose_sha256:$compose,image_policy_sha256:$policy,
          endpoint_guard_sha256:$guard,wallet_runtime_guard_sha256:$runtime_guard,
          normal_unlock_helper_sha256:$unlock_helper,pow_start_helper_sha256:$pow_helper}
    ' "$RUN_DIR/TRANSACTION.json" >/dev/null || return 1
    if [[ -e "$RUN_DIR/CANARY-FLEET-HANDOFF.json" ||
          -L "$RUN_DIR/CANARY-FLEET-HANDOFF.json" ]]; then
        verify_canary_fleet_handoff 0 || return 1
    fi
}

acquire_wave_locks()
{
    [[ "$WAVE_LOCKS_HELD" -eq 0 ]] || die 'wave locks are already held'
    exec 15>/run/blackcoin-endpoint-guard.lock
    flock -w 1800 15 || die 'endpoint guard did not drain'
    exec 16>/var/run/blackcoin-node-cutover.lock
    flock -x -w 1800 16 || die 'node cutover lock did not drain'
    exec 14>/run/blackcoin-pow-quarantine-cycle.lock
    flock -w 1800 14 || die 'PoW quarantine cycle did not drain'
    exec 17>/var/run/blackcoin-wallet-runtime-guard.lock
    flock -w 1800 17 || die 'wallet runtime guard did not drain'
    if [[ " ${CURRENT_WAVE_NODES[*]} " == *" 30 "* ]]; then
        exec 18>"$FREE_CLAIM_LOCK"
        flock -w 1800 18 || die 'Free Claim worker did not drain'
        FREE_CLAIM_LOCK_HELD=1
    fi
    WAVE_LOCKS_HELD=1
}

release_free_claim_lock()
{
    [[ "$FREE_CLAIM_LOCK_HELD" -eq 1 ]] || return 0
    flock -u 18 2>/dev/null || true
    exec 18>&- 2>/dev/null || true
    FREE_CLAIM_LOCK_HELD=0
}

reacquire_free_claim_lock()
{
    [[ " ${CURRENT_WAVE_NODES[*]} " == *" 30 "* ]] || return 0
    [[ "$FREE_CLAIM_LOCK_HELD" -eq 0 ]] || return 0
    exec 18>"$FREE_CLAIM_LOCK"
    flock -w 1800 18 || return 1
    FREE_CLAIM_LOCK_HELD=1
}

release_wave_locks()
{
    release_free_claim_lock
    flock -u 17 2>/dev/null || true
    exec 17>&- 2>/dev/null || true
    flock -u 14 2>/dev/null || true
    exec 14>&- 2>/dev/null || true
    flock -u 16 2>/dev/null || true
    exec 16>&- 2>/dev/null || true
    flock -u 15 2>/dev/null || true
    exec 15>&- 2>/dev/null || true
    WAVE_LOCKS_HELD=0
}

capture_wave_legacy_predrain_snapshots()
{
    local node padded temporary mode failed deadline round_dir pid
    local -a pids=()
    deadline=$((SECONDS + 1200))
    while ((SECONDS < deadline)); do
        round_dir=$(mktemp -d "$CURRENT_WAVE_DIR/.predrain-round.XXXXXX") || return 1
        chmod 700 "$round_dir" && chown root:root "$round_dir" || return 1
        pids=()
        for node in "${CURRENT_WAVE_NODES[@]}"; do
            padded=$(node_padded "$node")
            (wallet_rpc_for "$node" getpowmininginfo | jq -S . > "$round_dir/node-${padded}.json") &
            pids+=("$!")
        done
        failed=0
        for pid in "${pids[@]}"; do wait "$pid" || failed=1; done
        for node in "${CURRENT_WAVE_NODES[@]}"; do
            padded=$(node_padded "$node")
            temporary="$round_dir/node-${padded}.json"
            [[ "$failed" -eq 0 && -s "$temporary" ]] || { failed=1; continue; }
            chmod 600 "$temporary" && chown root:root "$temporary" || return 1
            mode=$(legacy_pow_snapshot_mode "$node" "$temporary" 2>/dev/null || true)
            [[ -n "$mode" ]] &&
                legacy_pow_projection_is_valid "$node" "$mode" "$temporary" pre-drain || failed=1
        done
        if ((failed == 0)); then
            for node in "${CURRENT_WAVE_NODES[@]}"; do
                padded=$(node_padded "$node")
                temporary="$round_dir/node-${padded}.json"
                sync -f "$temporary" || return 1
                mv -fT -- "$temporary" \
                    "$CURRENT_WAVE_DIR/node-${padded}-legacy-pow.before-drain.json" || return 1
            done
            rmdir "$round_dir" || return 1
            sync -f "$CURRENT_WAVE_DIR"
            return 0
        fi
        rm -rf -- "$round_dir"
        sleep 5
    done
    return 1
}

stop_wave_cleanly()
{
    local node padded container mining staking wallet_info unresolved deadline before mode mining_probe
    local -A pending=()
    for node in "${CURRENT_WAVE_NODES[@]}"; do
        padded=$(node_padded "$node")
        before="$CURRENT_WAVE_DIR/node-${padded}-legacy-pow.before-drain.json"
        mode=$(legacy_pow_snapshot_mode "$node" "$before") ||
            die "node $node legacy PoW state is not an allowed rollback mode"
        legacy_pow_projection_is_valid "$node" "$mode" "$before" pre-drain ||
            die "node $node legacy PoW pre-drain projection is not exact"
        if [[ "$node" -ne "$FREE_CLAIM_NODE" ]] &&
           { [[ "$mode" == clean-hashing ]] || jq -e '.enabled == true' "$before" >/dev/null; }; then
            wallet_rpc_for "$node" setpowmining false 1 1 \
                > "$CURRENT_WAVE_DIR/node-${padded}-pow-stop.json"
        fi
        wallet_rpc_for "$node" staking false >/dev/null ||
            die "node $node staking could not be disabled before the rollback checkpoint"
        wallet_rpc_for "$node" walletlock >/dev/null ||
            die "node $node wallet could not be locked before the rollback checkpoint"
        pending[$node]=1
    done
    deadline=$((SECONDS + 1200))
    while ((SECONDS < deadline)); do
        unresolved=0
        for node in "${CURRENT_WAVE_NODES[@]}"; do
            [[ -n "${pending[$node]:-}" ]] || continue
            mining=$(wallet_rpc_for "$node" getpowmininginfo 2>/dev/null || true)
            staking=$(wallet_rpc_for "$node" getstakinginfo 2>/dev/null || true)
            wallet_info=$(wallet_rpc_for "$node" getwalletinfo 2>/dev/null || true)
            padded=$(node_padded "$node")
            before="$CURRENT_WAVE_DIR/node-${padded}-legacy-pow.before-drain.json"
            mode=$(legacy_pow_snapshot_mode "$node" "$before" 2>/dev/null || true)
            mining_probe=$(mktemp "$CURRENT_WAVE_DIR/.node-${padded}-drain-pow.XXXXXX") ||
                die "node $node drain probe could not be created"
            if ! jq -S . <<< "$mining" > "$mining_probe" || ! chmod 600 "$mining_probe" ||
               ! chown root:root "$mining_probe"; then
                rm -f -- "$mining_probe"
                die "node $node drain probe could not be protected"
            fi
            if [[ -n "$mode" ]] &&
               legacy_pow_projection_is_valid "$node" "$mode" "$mining_probe" drained 2>/dev/null &&
               jq -e '.unlocked_until == 0' >/dev/null 2>&1 <<< "$wallet_info" &&
               jq -e '.enabled == false and .staking == false and
                   ((has("worker_running") | not) or .worker_running == false) and
                   .automatic_qqsignal == false and
                   .automatic_demurrage_attestation == false and
                   .automatic_redelegation == false and
                   .allow_automatic_quantum_key_creation == false' \
                   >/dev/null 2>&1 <<< "$staking"; then
                sync -f "$mining_probe" || die "node $node drain probe could not be synced"
                mv -fT -- "$mining_probe" \
                    "$CURRENT_WAVE_DIR/node-${padded}-legacy-pow.after-drain.json" ||
                    die "node $node post-drain PoW checkpoint could not be committed"
                printf '%s\n' "$wallet_info" | atomic_write_json \
                    "$CURRENT_WAVE_DIR/node-${padded}-wallet.after-drain.json" ||
                    die "node $node post-drain wallet checkpoint could not be committed"
                printf '%s\n' "$staking" | atomic_write_json \
                    "$CURRENT_WAVE_DIR/node-${padded}-staking.after-drain.json" ||
                    die "node $node post-drain staking checkpoint could not be committed"
                capture_wallet_txid_set "$node" \
                    "$CURRENT_WAVE_DIR/node-${padded}-wallet-txids.prelaunch.json" ||
                    die "node $node post-drain wallet transaction set could not be committed"
                chmod 600 "$CURRENT_WAVE_DIR/node-${padded}-wallet-txids.prelaunch.json"
                chown root:root "$CURRENT_WAVE_DIR/node-${padded}-wallet-txids.prelaunch.json"
                sync -f "$CURRENT_WAVE_DIR/node-${padded}-wallet-txids.prelaunch.json"
                unset 'pending[$node]'
            else
                rm -f -- "$mining_probe"
                unresolved=$((unresolved + 1))
            fi
        done
        ((unresolved == 0)) && break
        sleep 5
    done
    ((unresolved == 0)) || die 'wave did not reach a claim-safe stop boundary within 20 minutes'
    write_wave_drain_evidence ||
        die 'authoritative post-drain rollback plan could not be durably committed'
    for node in "${CURRENT_WAVE_NODES[@]}"; do
        rpc_for "$node" stop >/dev/null 2>&1 || true
    done

    pending=()
    for node in "${CURRENT_WAVE_NODES[@]}"; do pending[$node]=1; done
    deadline=$((SECONDS + 180))
    while ((SECONDS < deadline)); do
        unresolved=0
        for node in "${CURRENT_WAVE_NODES[@]}"; do
            [[ -n "${pending[$node]:-}" ]] || continue
            container=$(container_for "$node")
            if [[ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null)" != true ]]; then
                unset 'pending[$node]'
            else
                unresolved=$((unresolved + 1))
            fi
        done
        ((unresolved == 0)) && break
        sleep 1
    done
    for node in "${CURRENT_WAVE_NODES[@]}"; do
        container=$(container_for "$node")
        if [[ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null)" == true ]]; then
            timeout --foreground --kill-after=30 660 docker stop -t 600 "$container" >/dev/null
        fi
        [[ "$(docker inspect -f '{{.State.Running}}' "$container")" == false ]] ||
            die "node $node did not stop cleanly"
        assert_node_cleanly_stopped "$node" ||
            die "node $node stopped with a non-clean exit; refusing cold backup or image change"
    done
}

assert_node_cleanly_stopped()
{
    local node="$1" inspect
    inspect=$(docker inspect "$(container_for "$node")") || return 1
    jq -e 'length == 1 and .[0].State.Running == false and
        .[0].State.ExitCode == 0 and .[0].State.OOMKilled == false and
        .[0].State.Error == ""' >/dev/null <<< "$inspect"
}

backup_cold_wallets_and_snapshots()
{
    local node host_data wallet wallet_path wallet_relative
    install -d -m 700 -o root -g root "$CURRENT_WAVE_DIR/cold-backups"
    for node in "${CURRENT_WAVE_NODES[@]}"; do
        host_data=$(host_datadir_for "$node")
        wallet=$(cat "$CURRENT_WAVE_DIR/node-$(node_padded "$node")-loaded-wallet.txt")
        if [[ -z "$wallet" ]]; then
            wallet_relative=wallet.dat
        else
            [[ "$wallet" != */* && "$wallet" != .* && "$wallet" != *'..'* ]] ||
                die "node $node loaded wallet name is unsafe"
            wallet_relative="$wallet"
        fi
        wallet_path="$host_data/$wallet_relative"
        [[ -e "$wallet_path" && ! -L "$wallet_path" ]] ||
            die "node $node exact loaded wallet path is absent or unsafe"
        tar --acls --xattrs --numeric-owner -cpf \
            "$CURRENT_WAVE_DIR/cold-backups/node-$(node_padded "$node")-loaded-wallet.tar" \
            -C "$host_data" -- "$wallet_relative"
        install -m 600 -o root -g root "$host_data/blackcoin.conf" \
            "$CURRENT_WAVE_DIR/cold-backups/node-$(node_padded "$node")-blackcoin.conf"
        if [[ -f "$host_data/settings.json" && ! -L "$host_data/settings.json" ]]; then
            install -m 600 -o root -g root "$host_data/settings.json" \
                "$CURRENT_WAVE_DIR/cold-backups/node-$(node_padded "$node")-settings.json"
        fi
    done
    sha256sum "$CURRENT_WAVE_DIR/cold-backups"/* > "$CURRENT_WAVE_DIR/cold-backups/SHA256SUMS"
    snapshot_wave_data || die 'complete held pre-upgrade data snapshots could not be published'
    verify_wave_snapshot_inventory || die 'published data snapshot inventory failed verification'
}

prepare_wave_candidates()
{
    local services_csv='' node service policy_sha
    install -m 600 -o root -g root "$COMPOSE_FILE" "$CURRENT_WAVE_DIR/docker-compose.before.yml"
    install -m 600 -o root -g root "$IMAGE_POLICY" "$CURRENT_WAVE_DIR/fleet-image-policy.before.json"
    install -m 600 -o root -g root "$ENDPOINT_GUARD" "$CURRENT_WAVE_DIR/blackcoin_endpoint_guard.before.sh"
    for node in "${CURRENT_WAVE_NODES[@]}"; do
        service=$(service_for "$node")
        services_csv+="${services_csv:+,}$service"
    done
    awk -v targets="$services_csv" -v image="$CANDIDATE_IMAGE_REF" \
        -f "$RENDER_COMPOSE" "$COMPOSE_FILE" > "$CURRENT_WAVE_DIR/docker-compose.candidate.yml"
    "$RENDER_POLICY" "$IMAGE_POLICY" "$CURRENT_WAVE_DIR/fleet-image-policy.candidate.json" \
        "$CANDIDATE_IMAGE_REF" "$CANDIDATE_IMAGE_ID" "${CURRENT_WAVE_NODES[@]}"
    policy_sha=$(sha256sum "$CURRENT_WAVE_DIR/fleet-image-policy.candidate.json" | awk '{print $1}')
    "$RENDER_GUARD" "$ENDPOINT_GUARD" "$CURRENT_WAVE_DIR/blackcoin_endpoint_guard.candidate.sh" "$policy_sha"
    verify_compose_candidate "$services_csv"
}

verify_compose_candidate()
{
    local services_csv="$1" targets_json before_json after_json
    targets_json=$(tr ',' '\n' <<< "$services_csv" | jq -Rsc 'split("\n") | map(select(length > 0))')
    before_json=$(docker compose -f "$COMPOSE_FILE" config --format json) || die 'current Compose model is invalid'
    after_json=$(docker compose -f "$CURRENT_WAVE_DIR/docker-compose.candidate.yml" config --format json) ||
        die 'candidate Compose model is invalid'
    jq -e --arg image "$CANDIDATE_IMAGE_REF" --argjson targets "$targets_json" '
        . as $model | all($targets[]; $model.services[.].image == $image)
    ' >/dev/null <<< "$after_json" || die 'candidate Compose did not set every wave image'
    jq -e -n --argjson before "$before_json" --argjson after "$after_json" --argjson targets "$targets_json" '
        def neutralize($doc):
          reduce $targets[] as $service ($doc; .services[$service].image = "__WAVE_IMAGE__");
        neutralize($before) == neutralize($after)
    ' >/dev/null || die 'candidate Compose changes more than the selected image scalars'
}

install_triplet()
{
    local compose_candidate="$1" policy_candidate="$2" guard_candidate="$3"
    local compose_tmp policy_tmp guard_tmp compose_backup policy_backup guard_backup
    local compose_mode policy_mode guard_mode rc=0 compose_done=0 policy_done=0 guard_done=0
    local compose_restore_rc=0 policy_restore_rc=0 guard_restore_rc=0
    local compose_original_sha policy_original_sha guard_original_sha
    local compose_candidate_sha policy_candidate_sha guard_candidate_sha
    compose_mode=$(stat -c '%a' "$COMPOSE_FILE")
    policy_mode=$(stat -c '%a' "$IMAGE_POLICY")
    guard_mode=$(stat -c '%a' "$ENDPOINT_GUARD")
    compose_original_sha=$(sha256sum "$COMPOSE_FILE" | awk '{print $1}')
    policy_original_sha=$(sha256sum "$IMAGE_POLICY" | awk '{print $1}')
    guard_original_sha=$(sha256sum "$ENDPOINT_GUARD" | awk '{print $1}')
    compose_candidate_sha=$(sha256sum "$compose_candidate" | awk '{print $1}')
    policy_candidate_sha=$(sha256sum "$policy_candidate" | awk '{print $1}')
    guard_candidate_sha=$(sha256sum "$guard_candidate" | awk '{print $1}')
    compose_tmp=$(mktemp "${COMPOSE_FILE%/*}/.v3014-compose.XXXXXX")
    policy_tmp=$(mktemp "${IMAGE_POLICY%/*}/.v3014-policy.XXXXXX")
    guard_tmp=$(mktemp "${ENDPOINT_GUARD%/*}/.v3014-guard.XXXXXX")
    compose_backup=$(mktemp "${COMPOSE_FILE%/*}/.v3014-compose-rollback.XXXXXX")
    policy_backup=$(mktemp "${IMAGE_POLICY%/*}/.v3014-policy-rollback.XXXXXX")
    guard_backup=$(mktemp "${ENDPOINT_GUARD%/*}/.v3014-guard-rollback.XXXXXX")
    trap 'rm -f -- "${compose_tmp:-}" "${policy_tmp:-}" "${guard_tmp:-}" \
        "${compose_backup:-}" "${policy_backup:-}" "${guard_backup:-}"' RETURN
    install -m "$compose_mode" -o root -g root "$compose_candidate" "$compose_tmp"
    install -m "$policy_mode" -o root -g root "$policy_candidate" "$policy_tmp"
    install -m "$guard_mode" -o root -g root "$guard_candidate" "$guard_tmp"
    install -m "$compose_mode" -o root -g root "$COMPOSE_FILE" "$compose_backup"
    install -m "$policy_mode" -o root -g root "$IMAGE_POLICY" "$policy_backup"
    install -m "$guard_mode" -o root -g root "$ENDPOINT_GUARD" "$guard_backup"
    bash -n "$guard_tmp"
    triplet_policy_guard_valid "$policy_tmp" "$guard_tmp"
    docker compose -f "$compose_tmp" config --quiet
    sync -f "$compose_tmp"; sync -f "$policy_tmp"; sync -f "$guard_tmp"
    sync -f "$compose_backup"; sync -f "$policy_backup"; sync -f "$guard_backup"

    if mv -fT -- "$compose_tmp" "$COMPOSE_FILE"; then compose_done=1; compose_tmp=; else rc=$?; fi
    if ((rc == 0)); then
        if mv -fT -- "$policy_tmp" "$IMAGE_POLICY"; then policy_done=1; policy_tmp=; else rc=$?; fi
    fi
    if ((rc == 0)); then
        if mv -fT -- "$guard_tmp" "$ENDPOINT_GUARD"; then guard_done=1; guard_tmp=; else rc=$?; fi
    fi
    if ((rc == 0)) && ! triplet_policy_guard_valid "$IMAGE_POLICY" "$ENDPOINT_GUARD"; then rc=1; fi
    if ((rc == 0)) &&
       [[ "$(sha256sum "$COMPOSE_FILE" | awk '{print $1}')" != "$compose_candidate_sha" ||
          "$(sha256sum "$IMAGE_POLICY" | awk '{print $1}')" != "$policy_candidate_sha" ||
          "$(sha256sum "$ENDPOINT_GUARD" | awk '{print $1}')" != "$guard_candidate_sha" ]]; then
        rc=1
    fi

    if ((rc != 0)); then
        log 'triplet commit failed; restoring all original bytes before returning failure'
        set +e
        ((compose_done == 0)) || mv -fT -- "$compose_backup" "$COMPOSE_FILE"
        compose_restore_rc=$?
        ((policy_done == 0)) || mv -fT -- "$policy_backup" "$IMAGE_POLICY"
        policy_restore_rc=$?
        ((guard_done == 0)) || mv -fT -- "$guard_backup" "$ENDPOINT_GUARD"
        guard_restore_rc=$?
        sync -f "${COMPOSE_FILE%/*}" || compose_restore_rc=1
        sync -f "$STATE_DIR" || policy_restore_rc=1
        [[ "$(sha256sum "$COMPOSE_FILE" 2>/dev/null | awk '{print $1}')" == \
           "$compose_original_sha" ]] || compose_restore_rc=1
        [[ "$(sha256sum "$IMAGE_POLICY" 2>/dev/null | awk '{print $1}')" == \
           "$policy_original_sha" ]] || policy_restore_rc=1
        [[ "$(sha256sum "$ENDPOINT_GUARD" 2>/dev/null | awk '{print $1}')" == \
           "$guard_original_sha" ]] || guard_restore_rc=1
        triplet_policy_guard_valid "$IMAGE_POLICY" "$ENDPOINT_GUARD" || guard_restore_rc=1
        set -e
        ((compose_restore_rc == 0 && policy_restore_rc == 0 && guard_restore_rc == 0)) ||
            die 'triplet commit and internal byte restoration both failed; operator intervention required'
        return "$rc"
    fi
    sync -f "${COMPOSE_FILE%/*}"; sync -f "$STATE_DIR"
    trap - RETURN
    rm -f -- "$compose_backup" "$policy_backup" "$guard_backup"
    triplet_policy_guard_valid "$IMAGE_POLICY" "$ENDPOINT_GUARD"
}

live_wave_triplet_state()
{
    local before_count=0 candidate_count=0
    if cmp -s "$COMPOSE_FILE" "$CURRENT_WAVE_DIR/docker-compose.before.yml"; then
        before_count=$((before_count + 1))
    elif cmp -s "$COMPOSE_FILE" "$CURRENT_WAVE_DIR/docker-compose.candidate.yml"; then
        candidate_count=$((candidate_count + 1))
    else
        return 1
    fi
    if cmp -s "$IMAGE_POLICY" "$CURRENT_WAVE_DIR/fleet-image-policy.before.json"; then
        before_count=$((before_count + 1))
    elif cmp -s "$IMAGE_POLICY" "$CURRENT_WAVE_DIR/fleet-image-policy.candidate.json"; then
        candidate_count=$((candidate_count + 1))
    else
        return 1
    fi
    if cmp -s "$ENDPOINT_GUARD" "$CURRENT_WAVE_DIR/blackcoin_endpoint_guard.before.sh"; then
        before_count=$((before_count + 1))
    elif cmp -s "$ENDPOINT_GUARD" \
        "$CURRENT_WAVE_DIR/blackcoin_endpoint_guard.candidate.sh"; then
        candidate_count=$((candidate_count + 1))
    else
        return 1
    fi
    if ((before_count == 3)); then
        printf '%s\n' before
    elif ((candidate_count == 3)); then
        printf '%s\n' candidate
    else
        printf '%s\n' mixed
    fi
}

recover_no_launch_triplet_for_rollback()
{
    local state_file="$CURRENT_WAVE_DIR/COMMIT_STATE" state live_state
    ! candidate_launch_evidence_present || return 1
    verify_sealed_wave_evidence_files || return 1
    data_rollback_protected_file "$state_file" 600 || return 1
    state=$(<"$state_file")
    live_state=$(live_wave_triplet_state) || return 1
    case "$state" in
        rollback-boundary-established)
            [[ "$live_state" == before ]]
            return
            ;;
        commit-started|committed)
            if [[ "$live_state" == before ]]; then
                return 0
            fi
            data_rollback_require_mutation_fences || return 1
            install_triplet "$CURRENT_WAVE_DIR/docker-compose.before.yml" \
                "$CURRENT_WAVE_DIR/fleet-image-policy.before.json" \
                "$CURRENT_WAVE_DIR/blackcoin_endpoint_guard.before.sh" || return 1
            [[ "$(live_wave_triplet_state)" == before ]]
            ;;
        *) return 1 ;;
    esac
}

commit_wave_triplet()
{
    CURRENT_WAVE_COMMITTED=1
    publish_state_token "$CURRENT_WAVE_DIR/COMMIT_STATE" commit-started ||
        die 'wave commit-started state could not be published'
    install_triplet "$CURRENT_WAVE_DIR/docker-compose.candidate.yml" \
        "$CURRENT_WAVE_DIR/fleet-image-policy.candidate.json" \
        "$CURRENT_WAVE_DIR/blackcoin_endpoint_guard.candidate.sh" ||
        die 'wave triplet commit failed after internal restoration'
    publish_state_token "$CURRENT_WAVE_DIR/COMMIT_STATE" committed ||
        die 'wave committed state could not be published'
    sha256sum "$COMPOSE_FILE" "$IMAGE_POLICY" "$ENDPOINT_GUARD" > "$CURRENT_WAVE_DIR/live-triplet.sha256"
}

start_wave_candidate()
{
    local node candidate_generation candidate_id attempt
    verify_wave_candidate_launch_authorizations 1 ||
        die 'candidate launch refused because complete prelaunch authorization is absent or changed'
    for node in "${CURRENT_WAVE_NODES[@]}"; do
        ensure_candidate_stopped_container "$node" ||
            die "node $node stopped candidate replacement could not be completed safely"
        candidate_generation=$(container_generation_for "$node") ||
            die "node $node candidate generation is unavailable after creation"
        verify_candidate_stopped_container_contract "$node" "$candidate_generation" ||
            die "node $node stopped candidate contract differs from the sealed Compose snapshot"
        publish_candidate_launch_attempt_marker "$node" ||
            die "node $node candidate launch-attempt marker could not be durably published"
        CURRENT_WAVE_LAUNCH_ATTEMPTED=1
        attempt=$(wave_node_launch_attempt_path "$node") ||
            die "node $node launch-attempt path is invalid"
        candidate_generation=$(jq -er '.candidate_stopped_generation' "$attempt") ||
            die "node $node launch-attempt generation is unavailable"
        verify_candidate_stopped_container_contract "$node" "$candidate_generation" ||
            die "node $node candidate contract changed immediately before first start"
        verify_sealed_wave_evidence_files ||
            die "node $node sealed wave evidence changed immediately before first start"
        data_rollback_require_mutation_fences ||
            die "node $node mutation fences changed immediately before first start"
        candidate_id=${candidate_generation%%|*}
        [[ "$candidate_id" =~ ^[0-9a-f]{64}$ ]] ||
            die "node $node candidate container ID is invalid before first start"
        docker start "$candidate_id" >/dev/null ||
            die "node $node candidate launch failed"
        verify_candidate_running_container "$node" "$candidate_id" ||
            die "node $node exact candidate generation changed during first start"
    done
    publish_complete_candidate_launch_manifest ||
        die 'complete per-node candidate launch-attempt manifest could not be durably published'
}

verify_candidate_activation_marker()
{
    local node="$1" path baseline prelaunch generation transaction_sha drain_sha baseline_sha txids_sha
    path=$(wave_node_activation_path "$node") || return 1
    baseline=$(candidate_recovery_baseline_path "$node") || return 1
    prelaunch="$CURRENT_WAVE_DIR/node-$(node_padded "$node")-wallet-txids.prelaunch.json"
    [[ -f "$path" && ! -L "$path" && "$(stat -c '%u:%g:%a' "$path")" == 0:0:600 &&
       -f "$baseline" && ! -L "$baseline" && -f "$prelaunch" && ! -L "$prelaunch" ]] || return 1
    transaction_sha=$(sha256sum "$RUN_DIR/TRANSACTION.json" | awk '{print $1}') || return 1
    drain_sha=$(sha256sum "$(wave_drain_manifest_path)" | awk '{print $1}') || return 1
    baseline_sha=$(sha256sum "$baseline" | awk '{print $1}') || return 1
    txids_sha=$(sha256sum "$prelaunch" | awk '{print $1}') || return 1
    generation=$(container_generation_for "$node") || return 1
    jq -e --argjson node "$node" --arg run "$RUN_DIR" --arg wave "$CURRENT_WAVE_DIR" \
        --arg image "$CANDIDATE_IMAGE_REF" --arg image_id "$CANDIDATE_IMAGE_ID" \
        --arg generation "$generation" --arg transaction_sha "$transaction_sha" \
        --arg drain_sha "$drain_sha" --arg baseline_sha "$baseline_sha" --arg txids_sha "$txids_sha" '
        .schema == 1 and .transaction == "v30.1.4-fleet-rollout" and
        .boundary == "before-first-wallet-unlock" and .activation_attempted == true and
        .node == $node and .run_dir == $run and .wave_dir == $wave and
        .candidate_image == $image and .candidate_image_id == $image_id and
        .container_generation == $generation and
        .transaction_manifest_sha256 == $transaction_sha and
        .wave_drain_manifest_sha256 == $drain_sha and
        .candidate_recovery_baseline_sha256 == $baseline_sha and
        .prelaunch_wallet_txids_sha256 == $txids_sha and
        .fee_payments_authorized == false and
        (.created_at | type == "string")
    ' "$path" >/dev/null
}

publish_candidate_activation_marker()
{
    local node="$1" path baseline prelaunch generation transaction_sha drain_sha baseline_sha txids_sha
    verify_candidate_recovery_baseline "$node" || return 1
    verify_wave_drain_evidence || return 1
    path=$(wave_node_activation_path "$node") || return 1
    if [[ -e "$path" || -L "$path" ]]; then
        verify_candidate_activation_marker "$node"
        return
    fi
    baseline=$(candidate_recovery_baseline_path "$node") || return 1
    prelaunch="$CURRENT_WAVE_DIR/node-$(node_padded "$node")-wallet-txids.prelaunch.json"
    generation=$(container_generation_for "$node") || return 1
    transaction_sha=$(sha256sum "$RUN_DIR/TRANSACTION.json" | awk '{print $1}') || return 1
    drain_sha=$(sha256sum "$(wave_drain_manifest_path)" | awk '{print $1}') || return 1
    baseline_sha=$(sha256sum "$baseline" | awk '{print $1}') || return 1
    txids_sha=$(sha256sum "$prelaunch" | awk '{print $1}') || return 1
    jq -n --argjson node "$node" --arg run "$RUN_DIR" --arg wave "$CURRENT_WAVE_DIR" \
        --arg image "$CANDIDATE_IMAGE_REF" --arg image_id "$CANDIDATE_IMAGE_ID" \
        --arg generation "$generation" --arg transaction_sha "$transaction_sha" \
        --arg drain_sha "$drain_sha" --arg baseline_sha "$baseline_sha" --arg txids_sha "$txids_sha" \
        --arg created_at "$(date -u +%FT%TZ)" '
        {schema:1,transaction:"v30.1.4-fleet-rollout",boundary:"before-first-wallet-unlock",
         activation_attempted:true,node:$node,run_dir:$run,wave_dir:$wave,
         candidate_image:$image,candidate_image_id:$image_id,container_generation:$generation,
         transaction_manifest_sha256:$transaction_sha,wave_drain_manifest_sha256:$drain_sha,
         candidate_recovery_baseline_sha256:$baseline_sha,
         prelaunch_wallet_txids_sha256:$txids_sha,fee_payments_authorized:false,
         created_at:$created_at}' | atomic_write_json "$path" || return 1
    verify_candidate_activation_marker "$node"
}

terminate_and_join_activation_helpers()
{
    local pid deadline alive index
    ((${#ACTIVATION_HELPER_PIDS[@]} > 0)) || return 0
    for pid in "${ACTIVATION_HELPER_PIDS[@]}"; do
        [[ "$pid" =~ ^[1-9][0-9]*$ ]] || continue
        kill -TERM -- "-$pid" 2>/dev/null || true
    done
    deadline=$((SECONDS + 20))
    while ((SECONDS < deadline)); do
        alive=0
        for index in "${!ACTIVATION_HELPER_PIDS[@]}"; do
            pid=${ACTIVATION_HELPER_PIDS[index]}
            [[ "$pid" =~ ^[1-9][0-9]*$ ]] || continue
            if kill -0 -- "-$pid" 2>/dev/null; then
                alive=1
            else
                wait "$pid" 2>/dev/null || true
                ACTIVATION_HELPER_PIDS[index]=''
            fi
        done
        ((alive == 0)) && break
        sleep 1
    done
    for index in "${!ACTIVATION_HELPER_PIDS[@]}"; do
        pid=${ACTIVATION_HELPER_PIDS[index]}
        [[ "$pid" =~ ^[1-9][0-9]*$ ]] || continue
        if kill -0 -- "-$pid" 2>/dev/null; then
            kill -KILL -- "-$pid" 2>/dev/null || true
        else
            wait "$pid" 2>/dev/null || true
            ACTIVATION_HELPER_PIDS[index]=''
        fi
    done
    for pid in "${ACTIVATION_HELPER_PIDS[@]}"; do
        [[ "$pid" =~ ^[1-9][0-9]*$ ]] || continue
        wait "$pid" 2>/dev/null || true
    done
    deadline=$((SECONDS + 5))
    while ((SECONDS < deadline)); do
        alive=0
        for index in "${!ACTIVATION_HELPER_PIDS[@]}"; do
            pid=${ACTIVATION_HELPER_PIDS[index]}
            [[ "$pid" =~ ^[1-9][0-9]*$ ]] || continue
            if kill -0 -- "-$pid" 2>/dev/null; then
                alive=1
            else
                ACTIVATION_HELPER_PIDS[index]=''
            fi
        done
        ((alive == 0)) && break
        sleep 1
    done
    ((alive == 0)) || return 1
    ACTIVATION_HELPER_PIDS=()
    ACTIVATION_HELPER_NODES=()
    ACTIVATION_HELPER_PHASES=()
}

publish_wave_activation_markers()
{
    local node
    ((${#CANDIDATE_BASELINE_HELPER_PIDS[@]} == 0)) || return 1
    ((${#ACTIVATION_HELPER_PIDS[@]} == 0)) || return 1
    for node in "${CURRENT_WAVE_NODES[@]}"; do
        publish_candidate_activation_marker "$node" || return 1
    done
    sync -f "$CURRENT_WAVE_DIR" || return 1
    for node in "${CURRENT_WAVE_NODES[@]}"; do
        verify_candidate_activation_marker "$node" || return 1
    done
    CURRENT_WAVE_ACTIVATED=1
}

activate_wave_phase()
{
    local phase="$1" node pid failed=0 marker index path sha worker_source
    local launch_signal=0 monitor_was_enabled=0 remaining completed_pid wait_rc found
    local -a active_pids=()
    ((${#ACTIVATION_HELPER_PIDS[@]} == 0)) ||
        die 'a prior activation helper set is still live'
    for node in "${CURRENT_WAVE_NODES[@]}"; do
        verify_candidate_activation_marker "$node" ||
            die "node $node activation boundary changed before $phase helpers"
        [[ "$phase" != pow || "$node" -ne "$FREE_CLAIM_NODE" ]] || continue
        if [[ "$phase" == pow ]]; then
            marker="$CURRENT_WAVE_DIR/node-$(node_padded "$node")-pow-activation-attempted"
            publish_state_token "$marker" yes ||
                die "node $node PoW activation boundary could not be committed"
        fi
    done
    sync -f "$CURRENT_WAVE_DIR" || die "$phase activation boundaries were not durable"
    if [[ "$phase" == staking ]]; then
        path=$NORMAL_UNLOCK_HELPER
        sha=$NORMAL_UNLOCK_HELPER_SHA256
    else
        [[ "$phase" == pow ]] || die "invalid wave activation phase: $phase"
        path=$POW_START_HELPER
        sha=$POW_START_HELPER_SHA256
    fi
    worker_source=$(declare -f verify_activation_helper activate_one_node_phase) ||
        die 'activation worker functions could not be serialized'
    [[ $- == *m* ]] && monitor_was_enabled=1
    trap 'launch_signal=129' HUP
    trap 'launch_signal=130' INT
    trap 'launch_signal=143' TERM
    ((monitor_was_enabled == 0)) || set +m
    for node in "${CURRENT_WAVE_NODES[@]}"; do
        ((launch_signal == 0)) || break
        [[ "$phase" != pow || "$node" -ne "$FREE_CLAIM_NODE" ]] || continue
        setsid /bin/bash -c "$worker_source"$'\n''activate_one_node_phase "$1" "$2" "$3" "$4"' \
            activation-worker "$phase" "$node" "$path" "$sha" \
            > "$CURRENT_WAVE_DIR/node-$(node_padded "$node")-${phase}-activation.log" 2>&1 &
        pid=$!
        ACTIVATION_HELPER_PIDS+=("$pid")
        ACTIVATION_HELPER_NODES+=("$node")
        ACTIVATION_HELPER_PHASES+=("$phase")
        ((launch_signal == 0)) || break
    done
    remaining=${#ACTIVATION_HELPER_PIDS[@]}
    while ((remaining > 0 && launch_signal == 0)); do
        completed_pid=''
        active_pids=()
        for pid in "${ACTIVATION_HELPER_PIDS[@]}"; do
            [[ "$pid" =~ ^[1-9][0-9]*$ ]] && active_pids+=("$pid")
        done
        ((${#active_pids[@]} == remaining)) || { failed=1; break; }
        if wait -n -p completed_pid "${active_pids[@]}"; then wait_rc=0; else wait_rc=$?; fi
        ((launch_signal == 0)) || break
        [[ "$completed_pid" =~ ^[1-9][0-9]*$ ]] || { failed=1; break; }
        found=-1
        for index in "${!ACTIVATION_HELPER_PIDS[@]}"; do
            if [[ "${ACTIVATION_HELPER_PIDS[index]}" == "$completed_pid" ]]; then
                found=$index
                break
            fi
        done
        ((found >= 0)) || { failed=1; break; }
        if ((wait_rc != 0)); then
            log "node ${ACTIVATION_HELPER_NODES[found]} ${ACTIVATION_HELPER_PHASES[found]} activation failed"
            failed=1
        fi
        if kill -0 -- "-$completed_pid" 2>/dev/null; then
            log "node ${ACTIVATION_HELPER_NODES[found]} ${ACTIVATION_HELPER_PHASES[found]} left an activation descendant live"
            failed=1
            break
        else
            ACTIVATION_HELPER_PIDS[found]=''
        fi
        remaining=$((remaining - 1))
    done
    terminate_and_join_activation_helpers || failed=1
    ((monitor_was_enabled == 0)) || set -m
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    ((launch_signal == 0)) || exit "$launch_signal"
    ((failed == 0)) || die "one or more wave $phase activations failed"
}

activate_one_node_phase()
{
    local phase="$1" node="$2" path="${3:-}" sha="${4:-}" deadline helper_pid='' attempt_rc
    cleanup_activation_child()
    {
        local tick
        [[ -n "$helper_pid" ]] || return 0
        kill -TERM -- "-$helper_pid" 2>/dev/null || kill -TERM "$helper_pid" 2>/dev/null || true
        for ((tick = 0; tick < 50; tick++)); do
            kill -0 "$helper_pid" 2>/dev/null || break
            sleep 0.1
        done
        kill -KILL -- "-$helper_pid" 2>/dev/null || kill -KILL "$helper_pid" 2>/dev/null || true
        wait "$helper_pid" 2>/dev/null || true
        helper_pid=''
    }
    trap 'cleanup_activation_child; exit 129' HUP
    trap 'cleanup_activation_child; exit 143' TERM
    trap 'cleanup_activation_child; exit 130' INT
    if [[ -z "$path" || -z "$sha" ]]; then
        if [[ "$phase" == staking ]]; then
            path=${NORMAL_UNLOCK_HELPER:-}
            sha=${NORMAL_UNLOCK_HELPER_SHA256:-}
        else
            [[ "$phase" == pow && "$node" -ne "${FREE_CLAIM_NODE:-30}" ]] || return 1
            path=${POW_START_HELPER:-}
            sha=${POW_START_HELPER_SHA256:-}
        fi
    fi
    [[ -n "$path" && -n "$sha" && ( "$phase" == staking || "$phase" == pow ) ]] || return 1
    deadline=$((SECONDS + 300))
    while ((SECONDS < deadline)); do
        verify_activation_helper "$path" "$sha" || {
            trap - HUP INT TERM
            return 1
        }
        timeout --foreground --signal=TERM --kill-after=15 120 /bin/bash "$path" "$node" &
        helper_pid=$!
        if wait "$helper_pid"; then
            helper_pid=''
            trap - HUP INT TERM
            return 0
        else
            attempt_rc=$?
        fi
        helper_pid=''
        [[ "$attempt_rc" -ne 130 && "$attempt_rc" -ne 143 ]] || {
            trap - HUP INT TERM
            return "$attempt_rc"
        }
        sleep 5
    done
    cleanup_activation_child
    trap - HUP INT TERM
    return 1
}

probe_wave_nodes_once()
{
    local probe_dir="$1" node result fee generation_before generation_after pid failed=0
    local -a pids=()
    install -d -m 700 -o root -g root "$probe_dir"
    for node in "${CURRENT_WAVE_NODES[@]}"; do
        result="$probe_dir/node-$(node_padded "$node").result"
        (
            fee=$(candidate_recovery_fee_for "$node") || exit 1
            generation_before=$(container_generation_for "$node") || exit 1
            verify_node_runtime_gate "$node" "$fee" || exit 1
            generation_after=$(container_generation_for "$node") || exit 1
            [[ "$generation_before" == "$generation_after" ]] || exit 1
            printf '%s\n' "$generation_after" > "${result}.generation"
            printf '%s\n' pass > "$result"
        ) &
        pids+=("$!")
    done
    for pid in "${pids[@]}"; do wait "$pid" || failed=1; done
    ((failed == 0)) || return 1
    for node in "${CURRENT_WAVE_NODES[@]}"; do
        result="$probe_dir/node-$(node_padded "$node").result"
        [[ -f "$result" && "$(cat "$result")" == pass ]] || return 1
        generation_after=$(container_generation_for "$node") || return 1
        [[ "$generation_after" == "$(cat "${result}.generation")" ]] || return 1
    done
}

verify_wave_chain_convergence()
{
    local root="$CURRENT_WAVE_DIR/wave-chain-convergence" attempt dir node pid count
    local -a pids=()
    install -d -m 700 -o root -g root "$root"
    for attempt in $(seq 1 120); do
        dir=$(printf '%s/attempt-%03d' "$root" "$attempt")
        install -d -m 700 -o root -g root "$dir"
        pids=()
        for node in $(seq 1 "$NODE_COUNT"); do
            (rpc_for "$node" getblockchaininfo | jq -c --argjson node "$node" \
                '{node:$node,chain,blocks,headers,bestblockhash,chainwork,initialblockdownload}' \
                > "$dir/node-$(node_padded "$node").json") &
            pids+=("$!")
        done
        for pid in "${pids[@]}"; do wait "$pid" || true; done
        count=$(find "$dir" -maxdepth 1 -type f -name 'node-*.json' | wc -l)
        if [[ "$count" -eq "$NODE_COUNT" ]] && jq -e -s '
            length == 32 and all(.[]; .chain == "main" and .initialblockdownload == false and
              .headers >= .blocks and (.headers - .blocks) <= 2) and
            ([.[].blocks] | unique | length) == 1 and
            ([.[].bestblockhash] | unique | length) == 1 and
            ([.[].chainwork] | unique | length) == 1
        ' "$dir"/node-*.json >/dev/null; then
            jq -s 'sort_by(.node)' "$dir"/node-*.json > "$root/PASSED.json"
            return 0
        fi
        sleep 2
    done
    return 1
}

wait_wave_gate()
{
    local deadline attempt=0 probe_dir
    deadline=$((SECONDS + 1200))
    while ((SECONDS < deadline)); do
        attempt=$((attempt + 1))
        probe_dir=$(printf '%s/gate-probes/attempt-%03d' "$CURRENT_WAVE_DIR" "$attempt")
        if probe_wave_nodes_once "$probe_dir"; then
            verify_wave_chain_convergence || die 'wave did not converge with the exact-32 canonical tip'
            assert_unique_vpn_proofs || die 'VPN uniqueness changed during wave validation'
            probe_wave_nodes_once "$CURRENT_WAVE_DIR/gate-probes/final-same-generation" ||
                die 'wave failed final concurrent same-generation gate'
            return 0
        fi
        sleep 5
    done
    die 'wave did not pass the v30.1.4 runtime gate within the bounded 20-minute window'
}

wait_node30_service_gate()
{
    local attempt=0 deadline
    [[ " ${CURRENT_WAVE_NODES[*]} " == *" 30 "* ]] || return 0
    release_free_claim_lock
    deadline=$((SECONDS + 1200))
    while ((SECONDS < deadline)); do
        attempt=$((attempt + 1))
        if verify_free_claim_pause && verify_node30_free_claim_service; then
            log "node30 Free Claim service gate passed attempt=$attempt"
            return 0
        fi
        sleep 5
    done
    die 'node30 Free Claim service did not recover within 20 minutes'
}

assert_unaffected_unchanged()
{
    local before="$1" after="$2" csv="$3"
    capture_unaffected_generations "$after" "$csv"
    cmp -s "$before" "$after" || die 'a non-wave node or VPN container generation changed'
}

verify_policy_runtime_node()
{
    local node="$1" baseline lookup_rc
    if baseline=$(legacy_plan_file_for_node "$node" 2>/dev/null); then
        :
    else
        lookup_rc=$?
        [[ "$lookup_rc" -eq 2 ]] || return 1
        baseline=
    fi
    if [[ -n "$baseline" ]]; then
        verify_policy_legacy_runtime_gate "$node" "$baseline"
    else
        verify_policy_legacy_runtime_gate "$node"
    fi
}

verify_safe_rollback_marker()
{
    local node="$1" path activation prefix prelaunch fee generation
    local wallet staking mining recovery txids activation_sha transaction_sha drain_sha
    path=$(wave_node_safe_rollback_path "$node") || return 1
    activation=$(wave_node_activation_path "$node") || return 1
    prefix=$(wave_node_prefix "$node") || return 1
    wallet="${prefix}-safe-wallet.json"
    staking="${prefix}-safe-staking.json"
    mining="${prefix}-safe-mining.json"
    recovery="${prefix}-safe-recovery.json"
    txids="${prefix}-safe-wallet-txids.json"
    prelaunch="${prefix}-wallet-txids.prelaunch.json"
    for file in "$path" "$activation" "$wallet" "$staking" "$mining" "$recovery" "$txids" \
        "$prelaunch"; do
        [[ -f "$file" && ! -L "$file" && "$(stat -c '%u:%g:%a' "$file")" == 0:0:600 ]] ||
            return 1
    done
    verify_candidate_activation_marker "$node" || return 1
    fee=$(candidate_recovery_fee_for "$node") || return 1
    candidate_safe_rollback_state_is_clean "$wallet" "$staking" "$mining" "$recovery" "$fee" ||
        return 1
    cmp -s "$prelaunch" "$txids" || return 1
    generation=$(jq -er '.container_generation' "$activation") || return 1
    [[ "$(container_generation_for "$node")" == "$generation" ]] || return 1
    activation_sha=$(sha256sum "$activation" | awk '{print $1}') || return 1
    transaction_sha=$(sha256sum "$RUN_DIR/TRANSACTION.json" | awk '{print $1}') || return 1
    drain_sha=$(sha256sum "$(wave_drain_manifest_path)" | awk '{print $1}') || return 1
    jq -e --argjson node "$node" --arg run "$RUN_DIR" --arg wave "$CURRENT_WAVE_DIR" \
        --arg generation "$generation" --arg activation_sha "$activation_sha" \
        --arg transaction_sha "$transaction_sha" --arg drain_sha "$drain_sha" \
        --arg wallet_sha "$(sha256sum "$wallet" | awk '{print $1}')" \
        --arg staking_sha "$(sha256sum "$staking" | awk '{print $1}')" \
        --arg mining_sha "$(sha256sum "$mining" | awk '{print $1}')" \
        --arg recovery_sha "$(sha256sum "$recovery" | awk '{print $1}')" \
        --arg txids_sha "$(sha256sum "$txids" | awk '{print $1}')" \
        --arg prelaunch_sha "$(sha256sum "$prelaunch" | awk '{print $1}')" \
        --argjson fee "$fee" '
        .schema == 1 and .transaction == "v30.1.4-fleet-rollout" and
        .boundary == "candidate-safe-for-data-rollback" and .rollback_permitted == true and
        .node == $node and .run_dir == $run and .wave_dir == $wave and
        .container_generation == $generation and
        .activation_marker_sha256 == $activation_sha and
        .transaction_manifest_sha256 == $transaction_sha and
        .wave_drain_manifest_sha256 == $drain_sha and
        .wallet_locked == true and .staking_off == true and .pow_clean_off == true and
        .recovery_clean == true and .confirmed_resolution_fees == $fee and
        .fee_unchanged == true and .wallet_transaction_set_unchanged == true and
        .evidence == {wallet_sha256:$wallet_sha,staking_sha256:$staking_sha,
          mining_sha256:$mining_sha,recovery_sha256:$recovery_sha,
          wallet_txids_sha256:$txids_sha,prelaunch_wallet_txids_sha256:$prelaunch_sha} and
        (.created_at | type) == "string"
    ' "$path" >/dev/null
}

publish_safe_rollback_marker()
{
    local node="$1" path activation prefix prelaunch fee generation wallet_info staking mining recovery
    local txids_tmp deadline activation_sha
    path=$(wave_node_safe_rollback_path "$node") || return 1
    if [[ -e "$path" || -L "$path" ]]; then
        verify_safe_rollback_marker "$node"
        return
    fi
    activation=$(wave_node_activation_path "$node") || return 1
    verify_candidate_activation_marker "$node" || return 1
    prefix=$(wave_node_prefix "$node") || return 1
    prelaunch="${prefix}-wallet-txids.prelaunch.json"
    fee=$(candidate_recovery_fee_for "$node") || return 1
    generation=$(jq -er '.container_generation' "$activation") || return 1
    txids_tmp=$(mktemp "$CURRENT_WAVE_DIR/.safe-wallet-txids.XXXXXX") || return 1
    [[ "$node" -eq "$FREE_CLAIM_NODE" ]] ||
        wallet_rpc_for "$node" setpowmining false 1 1 >/dev/null 2>&1 || true
    wallet_rpc_for "$node" staking false >/dev/null 2>&1 || true
    wallet_rpc_for "$node" walletlock >/dev/null 2>&1 || true
    deadline=$((SECONDS + 120))
    while ((SECONDS < deadline)); do
        [[ "$(container_generation_for "$node" 2>/dev/null || true)" == "$generation" ]] || break
        wallet_info=$(wallet_rpc_for "$node" getwalletinfo 2>/dev/null || true)
        staking=$(wallet_rpc_for "$node" getstakinginfo 2>/dev/null || true)
        mining=$(wallet_rpc_for "$node" getpowmininginfo 2>/dev/null || true)
        recovery=$(wallet_rpc_for "$node" getpowclaimrecoveryinfo 2>/dev/null || true)
        [[ -n "$wallet_info" && -n "$staking" && -n "$mining" && -n "$recovery" ]] || {
            sleep 2; continue;
        }
        printf '%s\n' "$wallet_info" | atomic_write_json "${prefix}-safe-wallet.json" || break
        printf '%s\n' "$staking" | atomic_write_json "${prefix}-safe-staking.json" || break
        printf '%s\n' "$mining" | atomic_write_json "${prefix}-safe-mining.json" || break
        printf '%s\n' "$recovery" | atomic_write_json "${prefix}-safe-recovery.json" || break
        capture_wallet_txid_set "$node" "$txids_tmp" || { sleep 2; continue; }
        if ! chmod 600 "$txids_tmp" || ! chown root:root "$txids_tmp"; then
            break
        fi
        mv -fT -- "$txids_tmp" "${prefix}-safe-wallet-txids.json" || break
        txids_tmp=$(mktemp "$CURRENT_WAVE_DIR/.safe-wallet-txids.XXXXXX") || break
        if candidate_safe_rollback_state_is_clean "${prefix}-safe-wallet.json" \
             "${prefix}-safe-staking.json" "${prefix}-safe-mining.json" \
             "${prefix}-safe-recovery.json" "$fee" &&
           cmp -s "$prelaunch" "${prefix}-safe-wallet-txids.json"; then
            activation_sha=$(sha256sum "$activation" | awk '{print $1}') || break
            jq -n --argjson node "$node" --arg run "$RUN_DIR" --arg wave "$CURRENT_WAVE_DIR" \
                --arg generation "$generation" --arg activation_sha "$activation_sha" \
                --arg transaction_sha "$(sha256sum "$RUN_DIR/TRANSACTION.json" | awk '{print $1}')" \
                --arg drain_sha "$(sha256sum "$(wave_drain_manifest_path)" | awk '{print $1}')" \
                --arg wallet_sha "$(sha256sum "${prefix}-safe-wallet.json" | awk '{print $1}')" \
                --arg staking_sha "$(sha256sum "${prefix}-safe-staking.json" | awk '{print $1}')" \
                --arg mining_sha "$(sha256sum "${prefix}-safe-mining.json" | awk '{print $1}')" \
                --arg recovery_sha "$(sha256sum "${prefix}-safe-recovery.json" | awk '{print $1}')" \
                --arg txids_sha "$(sha256sum "${prefix}-safe-wallet-txids.json" | awk '{print $1}')" \
                --arg prelaunch_sha "$(sha256sum "$prelaunch" | awk '{print $1}')" \
                --argjson fee "$fee" --arg created_at "$(date -u +%FT%TZ)" '
                {schema:1,transaction:"v30.1.4-fleet-rollout",
                 boundary:"candidate-safe-for-data-rollback",rollback_permitted:true,node:$node,
                 run_dir:$run,wave_dir:$wave,container_generation:$generation,
                 activation_marker_sha256:$activation_sha,
                 transaction_manifest_sha256:$transaction_sha,wave_drain_manifest_sha256:$drain_sha,
                 wallet_locked:true,staking_off:true,pow_clean_off:true,recovery_clean:true,
                 confirmed_resolution_fees:$fee,fee_unchanged:true,
                 wallet_transaction_set_unchanged:true,
                 evidence:{wallet_sha256:$wallet_sha,staking_sha256:$staking_sha,
                   mining_sha256:$mining_sha,recovery_sha256:$recovery_sha,
                   wallet_txids_sha256:$txids_sha,
                   prelaunch_wallet_txids_sha256:$prelaunch_sha},created_at:$created_at}' |
                atomic_write_json "$path" || break
            rm -f -- "$txids_tmp"
            verify_safe_rollback_marker "$node"
            return
        fi
        sleep 2
    done
    rm -f -- "$txids_tmp"
    return 1
}

containment_evidence_present()
{
    [[ -n "$CURRENT_WAVE_DIR" && -d "$CURRENT_WAVE_DIR" && ! -L "$CURRENT_WAVE_DIR" ]] ||
        return 1
    [[ -e "$(wave_containment_complete_path)" || -L "$(wave_containment_complete_path)" ]] ||
        find "$CURRENT_WAVE_DIR" -maxdepth 1 \( -type f -o -type l \) \
            -name 'node-*-CONTAINED-NO-ROLLBACK.json' -print -quit | grep -q .
}

verify_node_containment_marker()
{
    local node="$1" verify_live=${2:-0} path authorization attempt activation
    local authorization_sha=__NULL__ attempt_sha=__NULL__ activation_sha=__NULL__
    local generation config_image image_id inspect container_started_at
    [[ "$verify_live" == 0 || "$verify_live" == 1 ]] || return 1
    path=$(wave_node_containment_path "$node") || return 1
    [[ -f "$path" && ! -L "$path" && "$(realpath -e -- "$path")" == "$path" &&
       "$(stat -c '%u:%g:%a' "$path")" == 0:0:600 ]] || return 1
    authorization=$(wave_node_launch_authorization_path "$node") || return 1
    attempt=$(wave_node_launch_attempt_path "$node") || return 1
    activation=$(wave_node_activation_path "$node") || return 1
    if [[ -e "$authorization" || -L "$authorization" ]]; then
        verify_candidate_launch_authorization_marker "$node" 0 || return 1
        authorization_sha=$(sha256sum "$authorization" | awk '{print $1}') || return 1
    fi
    if [[ -e "$attempt" || -L "$attempt" ]]; then
        verify_candidate_launch_attempt_marker "$node" 0 || return 1
        attempt_sha=$(sha256sum "$attempt" | awk '{print $1}') || return 1
    fi
    if [[ -e "$activation" || -L "$activation" ]]; then
        verify_candidate_activation_marker "$node" || return 1
        activation_sha=$(sha256sum "$activation" | awk '{print $1}') || return 1
    fi
    generation=$(jq -er '.container_generation' "$path") || return 1
    data_rollback_validate_stopped_generation "$generation" || return 1
    config_image=$(jq -er '.config_image' "$path") || return 1
    image_id=$(jq -er '.image_id' "$path") || return 1
    container_started_at=${generation#*|}
    container_started_at=${container_started_at%%|*}
    [[ -n "$config_image" && "$image_id" =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
    jq -e --argjson node "$node" --arg run "$RUN_DIR" --arg wave "$CURRENT_WAVE_DIR" \
        --arg container "$(container_for "$node")" --arg generation "$generation" \
        --arg config_image "$config_image" --arg image_id "$image_id" \
        --arg authorization_sha "$authorization_sha" --arg attempt_sha "$attempt_sha" \
        --arg activation_sha "$activation_sha" '
        (keys | sort) == (["schema","transaction","state","rollback_permitted","node",
          "run_dir","wave_dir","reason","container","container_generation","config_image",
          "image_id","launch_authorization_marker_sha256","launch_attempt_marker_sha256",
          "activation_marker_sha256","restart_policy","container_running","container_pid",
          "wallet_locked","staking_off","pow_off","wallet_lock_command_attempted",
          "staking_off_command_attempted","pow_off_command_attempted",
          "shutdown_proves_runtime_inactive","candidate_triplet_retained",
          "snapshots_and_holds_retained","maintenance_and_inhibitors_retained","created_at"] | sort) and
        .schema == 2 and .transaction == "v30.1.4-fleet-rollout" and
        .state == "contained-no-rollback" and .rollback_permitted == false and
        .node == $node and .run_dir == $run and .wave_dir == $wave and
        (.reason | type) == "string" and (.reason | length) > 0 and .container == $container and
        .container_generation == $generation and .config_image == $config_image and
        .image_id == $image_id and
        .launch_authorization_marker_sha256 ==
          (if $authorization_sha == "__NULL__" then null else $authorization_sha end) and
        .launch_attempt_marker_sha256 ==
          (if $attempt_sha == "__NULL__" then null else $attempt_sha end) and
        .activation_marker_sha256 ==
          (if $activation_sha == "__NULL__" then null else $activation_sha end) and
        .restart_policy == "no" and .container_running == false and .container_pid == 0 and
        .wallet_locked == true and .staking_off == true and .pow_off == true and
        (.wallet_lock_command_attempted | type) == "boolean" and
        (.staking_off_command_attempted | type) == "boolean" and
        (.pow_off_command_attempted | type) == "boolean" and
        .shutdown_proves_runtime_inactive == true and .candidate_triplet_retained == true and
        .snapshots_and_holds_retained == true and .maintenance_and_inhibitors_retained == true and
        (.created_at | type) == "string" and (.created_at | length) > 0
    ' "$path" >/dev/null || return 1
    if [[ "$attempt_sha" == __NULL__ && "$authorization_sha" != __NULL__ ]]; then
        if [[ "$generation" == "$(jq -er '.prelaunch_stopped_generation' "$authorization")" &&
              "$config_image" == "$(jq -er '.prelaunch_config_image' "$authorization")" &&
              "$image_id" == "$(jq -er '.prelaunch_image_id' "$authorization")" ]]; then
            :
        elif [[ "$config_image" == "$CANDIDATE_IMAGE_REF" &&
                "$image_id" == "$CANDIDATE_IMAGE_ID" &&
                "$container_started_at" == 0001-01-01T00:00:00Z ]]; then
            :
        else
            return 1
        fi
    fi
    if [[ "$activation_sha" != __NULL__ ]]; then
        [[ "$attempt_sha" != __NULL__ &&
           "$generation" == "$(jq -er '.container_generation' "$activation")" &&
           "$config_image" == "$CANDIDATE_IMAGE_REF" && "$image_id" == "$CANDIDATE_IMAGE_ID" ]] ||
            return 1
    fi
    if [[ "$verify_live" == 1 ]]; then
        [[ "$(container_generation_for "$node")" == "$generation" ]] || return 1
        inspect=$(docker inspect "$(container_for "$node")") || return 1
        jq -e --arg config_image "$config_image" --arg image_id "$image_id" '
            length == 1 and .[0].State.Running == false and .[0].State.Pid == 0 and
            .[0].State.Restarting == false and .[0].Config.Image == $config_image and
            .[0].Image == $image_id and .[0].HostConfig.RestartPolicy.Name == "no"
        ' >/dev/null <<< "$inspect" || return 1
        [[ "$(container_generation_for "$node")" == "$generation" ]] || return 1
    fi
}

containment_complete_manifest_valid()
{
    local marker node expected_names actual_names
    marker=$(wave_containment_complete_path) || return 1
    [[ -f "$marker" && ! -L "$marker" && "$(realpath -e -- "$marker")" == "$marker" &&
       "$(stat -c '%u:%g:%a' "$marker")" == 0:0:600 ]] || return 1
    expected_names=$(for node in "${CURRENT_WAVE_NODES[@]}"; do
        basename -- "$(wave_node_containment_path "$node")"
    done | sort) || return 1
    actual_names=$(awk 'NF == 2 && $1 ~ /^[0-9a-f]{64}$/ &&
        $2 ~ /^node-[0-9]{2}-CONTAINED-NO-ROLLBACK[.]json$/ {print $2}' \
        "$marker" | sort) || return 1
    [[ -n "$expected_names" && "$(wc -l < "$marker")" -eq "${#CURRENT_WAVE_NODES[@]}" &&
       "$actual_names" == "$expected_names" ]] || return 1
    (cd "$CURRENT_WAVE_DIR" && sha256sum --strict -c "${marker##*/}" >/dev/null) || return 1
    for node in "${CURRENT_WAVE_NODES[@]}"; do
        verify_node_containment_marker "$node" 1 || return 1
    done
}

contain_node_without_rollback()
{
    local node="$1" reason="$2" path container generation inspect config_image image_id
    local authorization attempt activation authorization_sha=__NULL__ attempt_sha=__NULL__
    local activation_sha=__NULL__ running=false wallet_attempted=false staking_attempted=false
    local pow_attempted=false
    path=$(wave_node_containment_path "$node") || return 1
    container=$(container_for "$node") || return 1
    if [[ -e "$path" || -L "$path" ]]; then
        docker update --restart=no "$container" >/dev/null 2>&1 || return 1
        if [[ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null)" == true ]]; then
            wallet_rpc_for "$node" setpowmining false 1 1 >/dev/null 2>&1 || true
            wallet_rpc_for "$node" staking false >/dev/null 2>&1 || true
            wallet_rpc_for "$node" walletlock >/dev/null 2>&1 || true
            rpc_for "$node" stop >/dev/null 2>&1 || true
            timeout --foreground --kill-after=10 45 docker stop -t 30 "$container" >/dev/null 2>&1 ||
                docker kill "$container" >/dev/null 2>&1 || return 1
        fi
        verify_node_containment_marker "$node" 0 || return 1
        generation=$(jq -er '.container_generation' "$path") || return 1
        [[ "$(container_generation_for "$node")" == "$generation" ]] || return 1
        verify_node_containment_marker "$node" 1
        return
    fi
    generation=$(container_generation_for "$node") || return 1
    data_rollback_validate_stopped_generation "$generation" || return 1
    inspect=$(docker inspect "$container") || return 1
    config_image=$(jq -er '.[0].Config.Image | select(type == "string" and length > 0)' \
        <<< "$inspect") || return 1
    image_id=$(jq -er '.[0].Image | select(test("^sha256:[0-9a-f]{64}$"))' \
        <<< "$inspect") || return 1
    running=$(jq -er '.[0].State.Running' <<< "$inspect") || return 1
    docker update --restart=no "$container" >/dev/null 2>&1 || return 1
    [[ "$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$container")" == no ]] || return 1
    if [[ "$running" == true ]]; then
        wallet_rpc_for "$node" setpowmining false 1 1 >/dev/null 2>&1 || true
        pow_attempted=true
        wallet_rpc_for "$node" staking false >/dev/null 2>&1 || true
        staking_attempted=true
        wallet_rpc_for "$node" walletlock >/dev/null 2>&1 || true
        wallet_attempted=true
        rpc_for "$node" stop >/dev/null 2>&1 || true
        if [[ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null)" == true ]]; then
            timeout --foreground --kill-after=10 45 docker stop -t 30 "$container" >/dev/null 2>&1 ||
                docker kill "$container" >/dev/null 2>&1 || return 1
        fi
    fi
    [[ "$(container_generation_for "$node")" == "$generation" ]] || return 1
    inspect=$(docker inspect "$container") || return 1
    jq -e --arg config_image "$config_image" --arg image_id "$image_id" '
        length == 1 and .[0].State.Running == false and .[0].State.Pid == 0 and
        .[0].State.Restarting == false and .[0].Config.Image == $config_image and
        .[0].Image == $image_id and .[0].HostConfig.RestartPolicy.Name == "no"
    ' >/dev/null <<< "$inspect" || return 1
    [[ "$(container_generation_for "$node")" == "$generation" ]] || return 1
    authorization=$(wave_node_launch_authorization_path "$node") || return 1
    attempt=$(wave_node_launch_attempt_path "$node") || return 1
    activation=$(wave_node_activation_path "$node") || return 1
    if [[ -e "$authorization" || -L "$authorization" ]]; then
        verify_candidate_launch_authorization_marker "$node" 0 || return 1
        authorization_sha=$(sha256sum "$authorization" | awk '{print $1}') || return 1
    fi
    if [[ -e "$attempt" || -L "$attempt" ]]; then
        verify_candidate_launch_attempt_marker "$node" 0 || return 1
        attempt_sha=$(sha256sum "$attempt" | awk '{print $1}') || return 1
    fi
    if [[ -e "$activation" || -L "$activation" ]]; then
        verify_candidate_activation_marker "$node" || return 1
        activation_sha=$(sha256sum "$activation" | awk '{print $1}') || return 1
    fi
    jq -n --argjson node "$node" --arg run "$RUN_DIR" --arg wave "$CURRENT_WAVE_DIR" \
        --arg reason "$reason" --arg container "$container" --arg generation "$generation" \
        --arg config_image "$config_image" --arg image_id "$image_id" \
        --arg authorization_sha "$authorization_sha" --arg attempt_sha "$attempt_sha" \
        --arg activation_sha "$activation_sha" --argjson wallet_attempted "$wallet_attempted" \
        --argjson staking_attempted "$staking_attempted" --argjson pow_attempted "$pow_attempted" \
        --arg created_at "$(date -u +%FT%TZ)" '
        {schema:2,transaction:"v30.1.4-fleet-rollout",state:"contained-no-rollback",
         rollback_permitted:false,node:$node,run_dir:$run,wave_dir:$wave,reason:$reason,
         container:$container,container_generation:$generation,config_image:$config_image,
         image_id:$image_id,
         launch_authorization_marker_sha256:
           (if $authorization_sha == "__NULL__" then null else $authorization_sha end),
         launch_attempt_marker_sha256:
           (if $attempt_sha == "__NULL__" then null else $attempt_sha end),
         activation_marker_sha256:
           (if $activation_sha == "__NULL__" then null else $activation_sha end),
         restart_policy:"no",container_running:false,container_pid:0,wallet_locked:true,
         staking_off:true,pow_off:true,wallet_lock_command_attempted:$wallet_attempted,
         staking_off_command_attempted:$staking_attempted,pow_off_command_attempted:$pow_attempted,
         shutdown_proves_runtime_inactive:true,candidate_triplet_retained:true,
         snapshots_and_holds_retained:true,maintenance_and_inhibitors_retained:true,
         created_at:$created_at}' | atomic_write_json "$path" || return 1
    sync -f "$CURRENT_WAVE_DIR" || return 1
    verify_node_containment_marker "$node" 1
}

publish_complete_containment_manifest()
{
    local marker temporary node
    ((${#CONTAINMENT_HELPER_PIDS[@]} == 0)) || return 1
    marker=$(wave_containment_complete_path) || return 1
    if [[ -e "$marker" || -L "$marker" ]]; then
        containment_complete_manifest_valid
        return
    fi
    for node in "${CURRENT_WAVE_NODES[@]}"; do
        verify_node_containment_marker "$node" 1 || return 1
    done
    temporary=$(mktemp "$CURRENT_WAVE_DIR/.containment-complete.XXXXXX") || return 1
    (
        cd "$CURRENT_WAVE_DIR"
        for node in "${CURRENT_WAVE_NODES[@]}"; do
            sha256sum -- "$(basename -- "$(wave_node_containment_path "$node")")" || exit 1
        done
    ) > "$temporary" || { rm -f -- "$temporary"; return 1; }
    if ! chmod 600 "$temporary" || ! chown root:root "$temporary" ||
       ! sync -f "$temporary" || ! ln -- "$temporary" "$marker"; then
        rm -f -- "$temporary"
        return 1
    fi
    rm -f -- "$temporary"
    sync -f "$CURRENT_WAVE_DIR" || return 1
    containment_complete_manifest_valid
}

terminate_and_join_containment_helpers()
{
    local pid deadline alive index
    ((${#CONTAINMENT_HELPER_PIDS[@]} > 0)) || return 0
    for pid in "${CONTAINMENT_HELPER_PIDS[@]}"; do
        [[ "$pid" =~ ^[1-9][0-9]*$ ]] || continue
        kill -TERM -- "-$pid" 2>/dev/null || true
    done
    deadline=$((SECONDS + 20))
    while ((SECONDS < deadline)); do
        alive=0
        for index in "${!CONTAINMENT_HELPER_PIDS[@]}"; do
            pid=${CONTAINMENT_HELPER_PIDS[index]}
            [[ "$pid" =~ ^[1-9][0-9]*$ ]] || continue
            if kill -0 -- "-$pid" 2>/dev/null; then
                alive=1
            else
                wait "$pid" 2>/dev/null || true
                CONTAINMENT_HELPER_PIDS[index]=''
            fi
        done
        ((alive == 0)) && break
        sleep 1
    done
    for index in "${!CONTAINMENT_HELPER_PIDS[@]}"; do
        pid=${CONTAINMENT_HELPER_PIDS[index]}
        [[ "$pid" =~ ^[1-9][0-9]*$ ]] || continue
        if kill -0 -- "-$pid" 2>/dev/null; then
            kill -KILL -- "-$pid" 2>/dev/null || true
        else
            wait "$pid" 2>/dev/null || true
            CONTAINMENT_HELPER_PIDS[index]=''
        fi
    done
    for pid in "${CONTAINMENT_HELPER_PIDS[@]}"; do
        [[ "$pid" =~ ^[1-9][0-9]*$ ]] || continue
        wait "$pid" 2>/dev/null || true
    done
    deadline=$((SECONDS + 5))
    while ((SECONDS < deadline)); do
        alive=0
        for index in "${!CONTAINMENT_HELPER_PIDS[@]}"; do
            pid=${CONTAINMENT_HELPER_PIDS[index]}
            [[ "$pid" =~ ^[1-9][0-9]*$ ]] || continue
            if kill -0 -- "-$pid" 2>/dev/null; then
                alive=1
            else
                CONTAINMENT_HELPER_PIDS[index]=''
            fi
        done
        ((alive == 0)) && break
        sleep 1
    done
    ((alive == 0)) || return 1
    CONTAINMENT_HELPER_PIDS=()
    CONTAINMENT_HELPER_NODES=()
}

contain_wave_without_rollback()
{
    local reason="$1" node pid failed=0 index monitor_was_enabled=0 signal_received=0
    local hup_trap int_trap term_trap trap_mode remaining completed_pid wait_rc found
    local -a active_pids=()
    terminate_and_join_containment_helpers || return 1
    terminate_and_join_activation_helpers || return 1
    hup_trap=$(trap -p HUP)
    int_trap=$(trap -p INT)
    term_trap=$(trap -p TERM)
    if [[ -z "$hup_trap" && -z "$int_trap" && -z "$term_trap" ]]; then
        trap_mode=default
    elif [[ "$hup_trap" == "trap -- 'exit 129' SIGHUP" &&
            "$int_trap" == "trap -- 'exit 130' SIGINT" &&
            "$term_trap" == "trap -- 'exit 143' SIGTERM" ]]; then
        trap_mode=rollout
    else
        return 1
    fi
    [[ $- == *m* ]] && monitor_was_enabled=1
    trap 'signal_received=129' HUP
    trap 'signal_received=130' INT
    trap 'signal_received=143' TERM
    ((monitor_was_enabled == 1)) || set -m
    for node in "${CURRENT_WAVE_NODES[@]}"; do
        ((signal_received == 0)) || break
        contain_node_without_rollback "$node" "$reason" &
        pid=$!
        CONTAINMENT_HELPER_PIDS+=("$pid")
        CONTAINMENT_HELPER_NODES+=("$node")
        ((signal_received == 0)) || break
    done
    ((monitor_was_enabled == 1)) || set +m
    remaining=${#CONTAINMENT_HELPER_PIDS[@]}
    while ((remaining > 0 && signal_received == 0)); do
        completed_pid=''
        active_pids=()
        for pid in "${CONTAINMENT_HELPER_PIDS[@]}"; do
            [[ "$pid" =~ ^[1-9][0-9]*$ ]] && active_pids+=("$pid")
        done
        ((${#active_pids[@]} == remaining)) || { failed=1; break; }
        if wait -n -p completed_pid "${active_pids[@]}"; then wait_rc=0; else wait_rc=$?; fi
        ((signal_received == 0)) || break
        [[ "$completed_pid" =~ ^[1-9][0-9]*$ ]] || { failed=1; break; }
        found=-1
        for index in "${!CONTAINMENT_HELPER_PIDS[@]}"; do
            if [[ "${CONTAINMENT_HELPER_PIDS[index]}" == "$completed_pid" ]]; then
                found=$index
                break
            fi
        done
        ((found >= 0)) || { failed=1; break; }
        if ((wait_rc != 0)); then
            log "containment failed or remained ambiguous for node=${CONTAINMENT_HELPER_NODES[found]}"
            failed=1
        fi
        if kill -0 -- "-$completed_pid" 2>/dev/null; then
            log "containment node=${CONTAINMENT_HELPER_NODES[found]} left a descendant live"
            failed=1
            break
        else
            CONTAINMENT_HELPER_PIDS[found]=''
        fi
        remaining=$((remaining - 1))
    done
    terminate_and_join_containment_helpers || failed=1
    if [[ "$trap_mode" == rollout ]]; then
        trap 'exit 129' HUP
        trap 'exit 130' INT
        trap 'exit 143' TERM
    else
        trap - HUP INT TERM
    fi
    ((signal_received == 0)) || exit "$signal_received"
    ((failed == 0)) || return 1
    publish_complete_containment_manifest || return 1
    publish_state_token "$CURRENT_WAVE_DIR/ROLLBACK_STATE" contained-no-rollback || return 1
    CURRENT_WAVE_CONTAINED=1
}

recover_authorized_candidate_replacement_prefixes()
{
    local node attempt state
    for node in "${CURRENT_WAVE_NODES[@]}"; do
        attempt=$(wave_node_launch_attempt_path "$node") || return 1
        if [[ -e "$attempt" || -L "$attempt" ]]; then
            verify_candidate_launch_attempt_marker "$node" 0 || return 1
            continue
        fi
        state=$(classify_candidate_replacement_node "$node") || return 1
        case "$state" in
            source-stopped|candidate-stopped) ;;
            absent-after-authorized-replacement)
                # The launch authorization predates exact-ID removal. Recreate
                # only the stopped candidate so rollback can classify the slot.
                ensure_candidate_stopped_container "$node" || return 1
                ;;
            *) return 1 ;;
        esac
    done
}

recover_wave_drain_evidence_prefix()
{
    local plan manifest node commit_state="$CURRENT_WAVE_DIR/COMMIT_STATE"
    plan=$(wave_drain_plan_path) || return 1
    manifest=$(wave_drain_manifest_path) || return 1
    if [[ -e "$manifest" || -L "$manifest" ]]; then
        [[ -e "$plan" || -L "$plan" ]] || return 1
        verify_wave_drain_evidence
        return
    fi
    data_rollback_protected_file "$commit_state" 600 || return 1
    assert_marker_state "$commit_state" rollback-boundary-established || return 1
    [[ "$(live_wave_triplet_state)" == before ]] || return 1
    if [[ -e "$plan" || -L "$plan" ]]; then
        write_wave_drain_evidence || return 1
        verify_wave_drain_evidence
        return
    fi
    verify_sealed_wave_evidence_files || return 1
    [[ ! -e "$CURRENT_WAVE_DIR/CANDIDATE_LAUNCH_AUTHORIZED" &&
       ! -L "$CURRENT_WAVE_DIR/CANDIDATE_LAUNCH_AUTHORIZED" &&
       ! -e "$CURRENT_WAVE_DIR/CANDIDATE_LAUNCH_ATTEMPTED" &&
       ! -L "$CURRENT_WAVE_DIR/CANDIDATE_LAUNCH_ATTEMPTED" ]] || return 1
    ! find "$CURRENT_WAVE_DIR" -maxdepth 1 \( -type f -o -type l \) \
        \( -name 'node-*-CANDIDATE-LAUNCH-AUTHORIZED.json' -o \
           -name 'node-*-CANDIDATE-LAUNCH-ATTEMPTED.json' \) -print -quit | grep -q . ||
        return 1
    for node in "${CURRENT_WAVE_NODES[@]}"; do
        verify_prelaunch_source_node "$node" false || return 1
        [[ "$(docker inspect -f '{{.State.Running}}' "$(container_for "$node")")" == true ]] ||
            return 1
    done
    # No candidate or post-drain authority exists, and every exact sealed
    # source generation is still live. The drain routine is monotonic and may
    # safely finish the disabled/locked checkpoints before stopping the wave.
    stop_wave_cleanly
    verify_wave_drain_evidence
}

stop_wave_for_rollback()
{
    local node container mining deadline inspect evidence activation attempt authorization
    local stopped_generation candidate_id generation source_generation
    terminate_and_join_activation_helpers || return 1
    if [[ "$CURRENT_WAVE_LAUNCH_ATTEMPTED" -eq 1 ]]; then
        for node in "${CURRENT_WAVE_NODES[@]}"; do
            attempt=$(wave_node_launch_attempt_path "$node") || return 1
            authorization=$(wave_node_launch_authorization_path "$node") || return 1
            activation=$(wave_node_activation_path "$node") || return 1
            if [[ ! -e "$attempt" && ! -L "$attempt" ]]; then
                verify_candidate_launch_authorization_marker "$node" 0 || return 1
                [[ ! -e "$activation" && ! -L "$activation" &&
                   ! -e "$(wave_node_safe_rollback_path "$node")" &&
                   ! -L "$(wave_node_safe_rollback_path "$node")" ]] || return 1
                continue
            fi
            verify_candidate_launch_attempt_marker "$node" 0 || {
                contain_wave_without_rollback launch-attempt-marker-ambiguous || true
                return 1
            }
            if [[ ! -e "$activation" && ! -L "$activation" ]]; then
                container=$(container_for "$node") || return 1
                stopped_generation=$(jq -er '.candidate_stopped_generation' "$attempt") || return 1
                candidate_id=${stopped_generation%%|*}
                [[ "$candidate_id" =~ ^[0-9a-f]{64}$ ]] || return 1
                generation=$(container_generation_for "$node") || return 1
                [[ "${generation%%|*}" == "$candidate_id" ]] || return 1
                verify_interrupted_target_container "$node" || return 1
                inspect=$(docker inspect "$candidate_id") || return 1
                jq -e --arg id "$candidate_id" --arg name "/$container" \
                    --arg image "$CANDIDATE_IMAGE_REF" --arg image_id "$CANDIDATE_IMAGE_ID" '
                    length == 1 and .[0].Id == $id and .[0].Name == $name and
                    .[0].Config.Image == $image and .[0].Image == $image_id and
                    .[0].State.Paused == false and .[0].State.Restarting == false
                ' >/dev/null <<< "$inspect" || return 1
                if ! jq -e '.[0].State.Running == true' >/dev/null <<< "$inspect"; then
                    jq -e 'length == 1 and .[0].State.Running == false and .[0].State.Pid == 0' \
                        >/dev/null <<< "$inspect" || return 1
                    source_generation=$(jq -er '.prelaunch_stopped_generation' "$authorization") ||
                        return 1
                    verify_candidate_stopped_exclusive "$node" "$generation" \
                        "$source_generation" || return 1
                    data_rollback_require_mutation_fences || return 1
                    verify_sealed_wave_evidence_files || return 1
                    docker start "$candidate_id" >/dev/null || {
                        contain_wave_without_rollback candidate-baseline-start-failed || true
                        return 1
                    }
                fi
                verify_candidate_running_container "$node" "$candidate_id" || {
                    contain_wave_without_rollback candidate-generation-changed-during-recovery || true
                    return 1
                }
                if ! establish_candidate_recovery_baseline "$node" ||
                   ! publish_candidate_activation_marker "$node"; then
                    contain_wave_without_rollback preactivation-safe-boundary-unavailable || true
                    return 1
                fi
            fi
            verify_candidate_activation_marker "$node" || {
                contain_wave_without_rollback activation-marker-ambiguous || true
                return 1
            }
            CURRENT_WAVE_ACTIVATED=1
            if ! publish_safe_rollback_marker "$node"; then
                contain_wave_without_rollback post-activation-rpc-or-state-ambiguous || true
                return 1
            fi
        done
        [[ "$CURRENT_WAVE_ACTIVATED" -eq 1 ]] || {
            contain_wave_without_rollback activation-boundary-state-ambiguous || true
            return 1
        }
    fi
    for node in "${CURRENT_WAVE_NODES[@]}"; do
        container=$(container_for "$node")
        if ! docker update --restart=no "$container" >/dev/null 2>&1 ||
           [[ "$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$container" 2>/dev/null)" != no ]]; then
            [[ "$CURRENT_WAVE_LAUNCH_ATTEMPTED" -eq 0 ]] ||
                contain_wave_without_rollback restart-disable-ambiguous || true
            return 1
        fi
    done
    for node in "${CURRENT_WAVE_NODES[@]}"; do
        container=$(container_for "$node")
        [[ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null)" == true ]] || continue
        if [[ "$node" -ne "$FREE_CLAIM_NODE" ]]; then
            wallet_rpc_for "$node" setpowmining false 1 1 >/dev/null 2>&1 || true
        fi
        deadline=$((SECONDS + 120))
        while ((SECONDS < deadline)); do
            mining=$(wallet_rpc_for "$node" getpowmininginfo 2>/dev/null || true)
            jq -e '.enabled == false and .live_claims == 0' >/dev/null 2>&1 <<< "$mining" && break
            sleep 1
        done
        jq -e '.enabled == false and .live_claims == 0' >/dev/null 2>&1 <<< "$mining" || {
            log "rollback refused before node=$node reached a claim-safe stop boundary"
            return 1
        }
        rpc_for "$node" stop >/dev/null 2>&1 || true
    done
    for node in "${CURRENT_WAVE_NODES[@]}"; do
        container=$(container_for "$node")
        if [[ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null)" == true ]]; then
            timeout --foreground --kill-after=30 660 docker stop -t 600 "$container" >/dev/null || return 1
        fi
        if assert_node_cleanly_stopped "$node"; then
            continue
        fi
        attempt=$(wave_node_launch_attempt_path "$node") || return 1
        [[ "$CURRENT_WAVE_LAUNCH_ATTEMPTED" -eq 1 && ( -e "$attempt" || -L "$attempt" ) ]] ||
            return 1
        if [[ "$node" -ne "$FREE_CLAIM_NODE" &&
              -e "$CURRENT_WAVE_DIR/node-$(node_padded "$node")-pow-activation-attempted" ]]; then
            verify_safe_rollback_marker "$node" || return 1
        fi
        if ! inspect=$(docker inspect "$container" 2>/dev/null); then
            publish_absent_target_evidence "$node" || return 1
            continue
        fi
        jq -e --arg image "$CANDIDATE_IMAGE_REF" --arg id "$CANDIDATE_IMAGE_ID" '
            length == 1 and .[0].State.Running == false and .[0].State.Pid == 0 and
            .[0].Config.Image == $image and .[0].Image == $id and
            ((.[0].State.ExitCode | type) == "number")
        ' >/dev/null <<< "$inspect" || return 1
        evidence="$CURRENT_WAVE_DIR/node-$(node_padded "$node")-candidate-nonclean-exit.json"
        jq -S '.[0] | {id:.Id,image:.Image,config_image:.Config.Image,
            state:{status:.State.Status,running:.State.Running,pid:.State.Pid,
              exit_code:.State.ExitCode,oom_killed:.State.OOMKilled,error:.State.Error,
              started_at:.State.StartedAt,finished_at:.State.FinishedAt}}' \
            <<< "$inspect" > "$evidence" || return 1
        chmod 600 "$evidence"
        chown root:root "$evidence"
        sync -f "$evidence"
    done
}

verify_stopped_candidate_safe_boundaries()
{
    local node activation attempt authorization safe generation inspect
    local prelaunch_generation prelaunch_image prelaunch_id
    [[ "$CURRENT_WAVE_LAUNCH_ATTEMPTED" -eq 1 ]] || return 0
    ((${#ACTIVATION_HELPER_PIDS[@]} == 0)) || return 1
    verify_wave_candidate_launch_markers 0 || return 1
    for node in "${CURRENT_WAVE_NODES[@]}"; do
        attempt=$(wave_node_launch_attempt_path "$node") || return 1
        authorization=$(wave_node_launch_authorization_path "$node") || return 1
        activation=$(wave_node_activation_path "$node") || return 1
        safe=$(wave_node_safe_rollback_path "$node") || return 1
        if [[ ! -e "$attempt" && ! -L "$attempt" ]]; then
            verify_candidate_launch_authorization_marker "$node" 0 || return 1
            [[ ! -e "$activation" && ! -L "$activation" && ! -e "$safe" && ! -L "$safe" ]] ||
                return 1
            prelaunch_generation=$(jq -er '.prelaunch_stopped_generation' "$authorization") ||
                return 1
            prelaunch_image=$(jq -er '.prelaunch_config_image' "$authorization") || return 1
            prelaunch_id=$(jq -er '.prelaunch_image_id' "$authorization") || return 1
            generation=$(container_generation_for "$node") || return 1
            inspect=$(docker inspect "$(container_for "$node")") || return 1
            jq -e --arg old_image "$prelaunch_image" --arg old_id "$prelaunch_id" \
                --arg candidate_image "$CANDIDATE_IMAGE_REF" --arg candidate_id "$CANDIDATE_IMAGE_ID" \
                --arg generation "$generation" --arg prelaunch_generation "$prelaunch_generation" '
                length == 1 and .[0].State.Running == false and .[0].State.Pid == 0 and
                .[0].State.Restarting == false and .[0].HostConfig.RestartPolicy.Name == "no" and
                ((.[0].Config.Image == $old_image and .[0].Image == $old_id and
                  $generation == $prelaunch_generation) or
                 (.[0].Config.Image == $candidate_image and .[0].Image == $candidate_id and
                  .[0].State.StartedAt == "0001-01-01T00:00:00Z"))
            ' >/dev/null <<< "$inspect" || return 1
            [[ "$(container_generation_for "$node")" == "$generation" ]] || return 1
            continue
        fi
        verify_candidate_launch_attempt_marker "$node" 0 || return 1
        verify_candidate_activation_marker "$node" || return 1
        verify_safe_rollback_marker "$node" || return 1
        generation=$(jq -er '.container_generation' "$activation") || return 1
        [[ "$(container_generation_for "$node")" == "$generation" ]] || return 1
        inspect=$(docker inspect "$(container_for "$node")") || return 1
        jq -e --arg image "$CANDIDATE_IMAGE_REF" --arg id "$CANDIDATE_IMAGE_ID" '
            length == 1 and .[0].State.Running == false and .[0].State.Pid == 0 and
            .[0].State.Restarting == false and .[0].Config.Image == $image and
            .[0].Image == $id and .[0].HostConfig.RestartPolicy.Name == "no"
        ' >/dev/null <<< "$inspect" || return 1
    done
}

rollback_current_wave()
{
    local node all_ready deadline plan action txids_tmp restored_pow phase_record rollback_phase
    local attempt state
    local authority_sha=- old_authority_sha=- containment_pending=0
    terminate_and_join_containment_helpers || return 1
    terminate_and_join_candidate_baseline_helpers || return 1
    if [[ "$CURRENT_WAVE_CONTAINED" -ne 0 ]] || containment_evidence_present; then
        containment_pending=1
    fi
    [[ "$CURRENT_WAVE_COMMITTED" -eq 1 && "$CURRENT_WAVE_ROLLED_BACK" -eq 0 ]] || return 0
    log "rolling back current wave: ${CURRENT_WAVE_NODES[*]}"
    [[ -f "$CURRENT_WAVE_DIR/docker-compose.before.yml" &&
       -f "$CURRENT_WAVE_DIR/fleet-image-policy.before.json" &&
       -f "$CURRENT_WAVE_DIR/blackcoin_endpoint_guard.before.sh" ]] || return 1
    if [[ "$WAVE_LOCKS_HELD" -eq 0 ]]; then
        acquire_wave_locks || return 1
    elif ! reacquire_free_claim_lock; then
        return 1
    fi
    if [[ "$containment_pending" -eq 1 ]]; then
        log "resuming fail-closed containment for current wave: ${CURRENT_WAVE_NODES[*]}"
        contain_wave_without_rollback resume-existing-containment || return 1
        return 1
    fi
    publish_state_token "$CURRENT_WAVE_DIR/ROLLBACK_STATE" rollback-started || return 1
    if [[ -e "$CURRENT_WAVE_DIR/CANDIDATE_LAUNCH_ATTEMPTED" ||
          -L "$CURRENT_WAVE_DIR/CANDIDATE_LAUNCH_ATTEMPTED" ]]; then
        candidate_launch_attempt_manifest_valid || {
            contain_wave_without_rollback candidate-launch-completion-manifest-ambiguous || true
            return 1
        }
    fi
    if candidate_launch_evidence_present; then
        CURRENT_WAVE_LAUNCH_ATTEMPTED=1
        verify_wave_candidate_launch_markers 0 || {
            contain_wave_without_rollback candidate-launch-authority-incomplete-or-changed || true
            return 1
        }
    fi
    recover_wave_drain_evidence_prefix || {
        log 'rollback refused because the post-drain authority cannot be completed or verified'
        return 1
    }
    phase_record=$(rollback_resume_phase) || {
        log 'rollback phase evidence is absent, changed, or contradictory'
        return 1
    }
    IFS='|' read -r rollback_phase authority_sha old_authority_sha <<< "$phase_record"
    case "$rollback_phase" in
        pre-restore)
            if [[ "$CURRENT_WAVE_LAUNCH_ATTEMPTED" -eq 0 ]]; then
                recover_no_launch_triplet_for_rollback || {
                    log 'no-launch triplet commit prefix could not be normalized safely'
                    return 1
                }
            fi
            if [[ -e "$CURRENT_WAVE_DIR/CANDIDATE_LAUNCH_AUTHORIZED" ||
                  -L "$CURRENT_WAVE_DIR/CANDIDATE_LAUNCH_AUTHORIZED" ]]; then
                verify_wave_candidate_launch_authorizations 0 || {
                    log 'complete candidate replacement authority is invalid'
                    return 1
                }
                recover_authorized_candidate_replacement_prefixes || {
                    log 'authorized candidate replacement prefix could not be recovered safely'
                    return 1
                }
            else
                verify_prelaunch_candidate_authorization_prefix || {
                    log 'prelaunch or partial candidate authorization prefix is ambiguous'
                    return 1
                }
            fi
            stop_wave_for_rollback || return 1
            if [[ "$CURRENT_WAVE_LAUNCH_ATTEMPTED" -eq 1 ]]; then
                verify_stopped_candidate_safe_boundaries || {
                    contain_wave_without_rollback stopped-generation-or-safe-boundary-ambiguous || true
                    return 1
                }
                authority_sha=$(data_rollback_prepare_restore_authority) || {
                    contain_wave_without_rollback \
                        rollback-authority-publication-or-verification-failed || true
                    return 1
                }
                restore_wave_preupgrade_data "$authority_sha" || {
                    log 'pre-upgrade dataset restoration failed; old binary will not be started'
                    return 1
                }
                rollback_data_restored_receipt_sha "$authority_sha" >/dev/null || return 1
                old_authority_sha=$(publish_rollback_old_image_authority \
                    restored "$authority_sha") || return 1
            else
                old_authority_sha=$(publish_rollback_old_image_authority \
                    unchanged-no-candidate-launch) || return 1
            fi
            ;;
        restore-authority-live)
            restore_wave_preupgrade_data "$authority_sha" || {
                log 'pre-upgrade dataset restoration resume failed; old binary will not be started'
                return 1
            }
            rollback_data_restored_receipt_sha "$authority_sha" >/dev/null || return 1
            old_authority_sha=$(publish_rollback_old_image_authority restored "$authority_sha") ||
                return 1
            ;;
        data-restored)
            rollback_data_restored_receipt_sha "$authority_sha" >/dev/null || return 1
            old_authority_sha=$(publish_rollback_old_image_authority restored "$authority_sha") ||
                return 1
            ;;
        old-image-authorized)
            verify_rollback_old_image_authority || return 1
            [[ "$(rollback_old_image_authority_sha)" == "$old_authority_sha" ]] || return 1
            ;;
        *) return 1 ;;
    esac
    publish_state_token "$CURRENT_WAVE_DIR/ROLLBACK_STATE" old-image-authorized || return 1
    install_triplet "$CURRENT_WAVE_DIR/docker-compose.before.yml" \
        "$CURRENT_WAVE_DIR/fleet-image-policy.before.json" \
        "$CURRENT_WAVE_DIR/blackcoin_endpoint_guard.before.sh" || return 1
    [[ "$(sha256sum "$COMPOSE_FILE" | awk '{print $1}')" == \
       "$(sha256sum "$CURRENT_WAVE_DIR/docker-compose.before.yml" | awk '{print $1}')" ]] || return 1
    [[ "$(sha256sum "$IMAGE_POLICY" | awk '{print $1}')" == \
       "$(sha256sum "$CURRENT_WAVE_DIR/fleet-image-policy.before.json" | awk '{print $1}')" ]] || return 1
    [[ "$(sha256sum "$ENDPOINT_GUARD" | awk '{print $1}')" == \
       "$(sha256sum "$CURRENT_WAVE_DIR/blackcoin_endpoint_guard.before.sh" | awk '{print $1}')" ]] || return 1
    # A prior invocation may already have started part of the old wave. Quiesce
    # every authenticated running member before creating or starting another.
    for node in "${CURRENT_WAVE_NODES[@]}"; do
        attempt=$(rollback_node_old_image_attempt_path "$node") || return 1
        [[ -e "$attempt" || -L "$attempt" ]] || continue
        state=$(classify_rollback_old_image_node "$node" "$old_authority_sha") || return 1
        if [[ "$state" == old-running ]]; then
            quiesce_rollback_old_node "$node" "$old_authority_sha" || return 1
        fi
    done
    for node in "${CURRENT_WAVE_NODES[@]}"; do
        ensure_rollback_old_image_node "$node" "$old_authority_sha" || return 1
        quiesce_rollback_old_node "$node" "$old_authority_sha" || return 1
    done
    quiesce_rollback_old_wave "$old_authority_sha" || return 1
    for node in "${CURRENT_WAVE_NODES[@]}"; do
        run_activation_helper "$NORMAL_UNLOCK_HELPER" "$NORMAL_UNLOCK_HELPER_SHA256" "$node" \
            >/dev/null 2>&1 || return 1
        plan=$(wave_legacy_plan_entry "$node") || return 1
        action=$(jq -er '.rollback_pow_action' "$plan") || return 1
        if [[ "$action" == start-pow-helper ]]; then
            run_activation_helper "$POW_START_HELPER" "$POW_START_HELPER_SHA256" "$node" \
                >/dev/null 2>&1 || return 1
        elif [[ "$action" != skip-pow ]]; then
            return 1
        fi
    done
    deadline=$((SECONDS + 1200))
    while ((SECONDS < deadline)); do
        all_ready=1
        for node in "${CURRENT_WAVE_NODES[@]}"; do
            verify_policy_runtime_node "$node" || all_ready=0
        done
        ((all_ready == 1)) && break
        sleep 5
    done
    ((all_ready == 1)) || return 1
    for node in "${CURRENT_WAVE_NODES[@]}"; do
        plan=$(wave_legacy_plan_entry "$node") || return 1
        restored_pow="$CURRENT_WAVE_DIR/node-$(node_padded "$node")-legacy-pow.restored.json"
        wallet_rpc_for "$node" getpowmininginfo | atomic_write_json "$restored_pow" || return 1
        verify_legacy_pow_rollback_exact "$node" "$plan" "$restored_pow" || return 1
        txids_tmp=$(mktemp "$CURRENT_WAVE_DIR/.old-restored-txids.XXXXXX") || return 1
        capture_wallet_txid_set "$node" "$txids_tmp" || { rm -f -- "$txids_tmp"; return 1; }
        cmp -s "$CURRENT_WAVE_DIR/node-$(node_padded "$node")-wallet-txids.prelaunch.json" \
            "$txids_tmp" || { rm -f -- "$txids_tmp"; return 1; }
        rm -f -- "$txids_tmp"
    done
    if [[ " ${CURRENT_WAVE_NODES[*]} " == *" 30 "* ]]; then
        release_free_claim_lock
        deadline=$((SECONDS + 600))
        while ((SECONDS < deadline)); do
            verify_node30_free_claim_service && break
            sleep 5
        done
        verify_node30_free_claim_service || return 1
    fi
    trap '' HUP INT TERM
    if ! publish_state_token "$CURRENT_WAVE_DIR/ROLLBACK_STATE" rollback-passed ||
       ! publish_state_token "$CURRENT_WAVE_DIR/RESULT" rolled-back; then
        trap 'exit 129' HUP
        trap 'exit 130' INT
        trap 'exit 143' TERM
        return 1
    fi
    CURRENT_WAVE_ROLLED_BACK=1
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
}

on_exit()
{
    local rc=$? containment_proven=0 containment_prefix_ready=0 inhibitor_state=''
    trap - EXIT HUP INT TERM
    terminate_and_join_containment_helpers || true
    terminate_and_join_candidate_baseline_helpers || true
    terminate_and_join_activation_helpers || true
    if ((rc != 0)); then
        if [[ "$TERMINAL_FINALIZED" -eq 1 ]]; then
            log 'terminal receipt is finalized; live verification drift is post-transaction and no rollout state will be mutated'
            release_finalization_guard_locks
            release_wave_locks
            exit "$rc"
        fi
        if [[ "$TERMINAL_COMMIT_ACTIVE" -eq 1 ]]; then
            if verify_snapshot_cleanup_resume_prefix && data_rollback_finalization_released; then
                log 'terminal evidence commit was interrupted after its durable cleanup prefix; rerun resumes cleanup and atomic receipt publication'
                release_finalization_guard_locks
                release_wave_locks
                exit "$rc"
            fi
            log 'terminal commit prefix or live release proof is invalid; restoring fail-closed containment'
            TERMINAL_COMMIT_ACTIVE=0
            FINALIZATION_ACTIVE=1
        fi
        if [[ "$FINALIZATION_LOCKS_HELD" -eq 1 ]]; then
            # A signal may interrupt release or recontainment while this process
            # owns every guard lock. Establish the same durable monotonic prefix
            # as ensure_finalization_containment before any direct live mutation.
            if [[ -n "$RUN_DIR" ]] && valid_rollout_run_dir "$RUN_DIR" &&
               publish_state_token "$(finalization_state_path)" containment-authorized &&
               invalidate_maintenance_released_epoch; then
                containment_prefix_ready=1
            else
                log 'ERROR: could not publish the held-lock containment authority and revoke the release epoch'
            fi
            if [[ "$containment_prefix_ready" -eq 1 ]]; then
                activate_free_claim_pause_safely ||
                    log 'ERROR: could not re-pause Free Claim while held finalization locks were active'
                activate_maintenance_marker_safely ||
                    log 'ERROR: could not reactivate maintenance while held finalization locks were active'
            fi
        fi
        # Also closes any prefix acquired before a signal interrupted the
        # canonical lock sequence and before FINALIZATION_LOCKS_HELD was set.
        release_finalization_guard_locks
        if [[ "$CURRENT_WAVE_COMMITTED" -eq 0 && -n "$CURRENT_WAVE_DIR" &&
              "$CURRENT_WAVE_DIR" == "$RUN_DIR"/.pre-wave-* &&
              -d "$CURRENT_WAVE_DIR" && ! -L "$CURRENT_WAVE_DIR" ]]; then
            publish_state_token "$CURRENT_WAVE_DIR/PRECOMMIT_STATE" precommit-aborted || true
            log "wave preparation aborted before the rollback boundary; hidden evidence retained at $CURRENT_WAVE_DIR"
        fi
        if ! rollback_current_wave; then
            log 'ERROR: current-wave rollback could not be proven; affected nodes remain fail-closed'
        fi
        if [[ "$FINALIZATION_ACTIVE" -eq 1 ]]; then
            ensure_finalization_containment && containment_proven=1
        else
            inhibitor_state=$(/bin/bash "$INHIBITOR_RELEASER" probe 2>/dev/null || true)
            if [[ "$inhibitor_state" == \
                  'state=installed-and-paused cycle=v30.1.4-no-spend free_claim=paused' ]] &&
               verify_maintenance_marker; then
                containment_proven=1
            fi
        fi
        if [[ "$containment_proven" -eq 1 ]]; then
            log 'transaction stopped fail-closed; Free Claim and fleet supervisors are durably inhibited'
        else
            log 'ERROR: transaction stopped but final inhibitor containment could not be proven'
        fi
    fi
    release_finalization_guard_locks
    release_wave_locks
    exit "$rc"
}

run_one_wave()
{
    local wave_index="$1" csv node base canonical precommit_dir retry=0 result fee=''
    local next_retry stray retry_index
    local -a recorded_nodes=()
    shift
    CURRENT_WAVE_NODES=("$@")
    csv=$(IFS=,; printf '%s' "${CURRENT_WAVE_NODES[*]}")
    base=$(printf '%s/wave-%02d-nodes-%s' "$RUN_DIR" "$wave_index" "${csv//,/-}")
    canonical="$base"
    while [[ -e "$canonical" || -L "$canonical" ]]; do
        [[ -d "$canonical" && ! -L "$canonical" ]] || die "existing wave path is unsafe: $canonical"
        verify_wave_evidence_manifest "$canonical" "$wave_index" ||
            die "existing wave evidence changed: $canonical"
        if [[ -f "$canonical/RESULT" && ! -L "$canonical/RESULT" ]]; then
            result=$(cat "$canonical/RESULT")
        else
            result=interrupted
        fi
        case "$result" in
            passed)
                CURRENT_WAVE_DIR="$canonical"
                verify_wave_runtime_evidence ||
                    die "passed wave runtime evidence changed: $canonical"
                next_retry=$(printf '%s-retry-%02d' "$base" "$((retry + 1))")
                [[ ! -e "$next_retry" && ! -L "$next_retry" ]] ||
                    die 'a retry exists after a passed wave attempt'
                for node in "${CURRENT_WAVE_NODES[@]}"; do
                    fee=$(candidate_recovery_fee_for "$node") ||
                        die "passed node $node wave has no valid recovery-fee baseline"
                    verify_node_gate "$node" "$fee" ||
                        die "previously passed wave regressed at node $node"
                done
                log "wave $wave_index remains passed; no known-good work repeated: ${CURRENT_WAVE_NODES[*]}"
                return 0
                ;;
            rolled-back) ;;
            interrupted)
                CURRENT_WAVE_DIR="$canonical"
                read -r -a recorded_nodes < "$canonical/NODES"
                [[ "${recorded_nodes[*]}" == "${CURRENT_WAVE_NODES[*]}" ]] ||
                    die 'interrupted wave node identity changed'
                acquire_wave_locks
                CURRENT_WAVE_COMMITTED=1
                CURRENT_WAVE_ROLLED_BACK=0
                CURRENT_WAVE_LAUNCH_ATTEMPTED=0
                rollback_current_wave || die 'interrupted wave could not be rolled back safely'
                release_wave_locks
                CURRENT_WAVE_COMMITTED=0
                ;;
            *) die "existing wave has unsafe result: $result" ;;
        esac
        retry=$((retry + 1))
        canonical=$(printf '%s-retry-%02d' "$base" "$retry")
    done
    while IFS= read -r stray; do
        [[ "${stray##*/}" =~ -retry-([0-9]{2})$ ]] ||
            die "foreign retry directory exists: $stray"
        retry_index=$((10#${BASH_REMATCH[1]}))
        ((retry_index < retry)) || die "noncontiguous retry directory exists: $stray"
    done < <(find "$RUN_DIR" -maxdepth 1 -type d -name "${base##*/}-retry-*" -print | sort)
    precommit_dir=$(mktemp -d "$RUN_DIR/.pre-wave-${wave_index}.XXXXXX")
    chmod 700 "$precommit_dir"
    chown root:root "$precommit_dir"
    CURRENT_WAVE_DIR="$precommit_dir"
    printf '%s\n' "${CURRENT_WAVE_NODES[*]}" > "$CURRENT_WAVE_DIR/NODES"
    CURRENT_WAVE_COMMITTED=0
    CURRENT_WAVE_ROLLED_BACK=0
    CURRENT_WAVE_LAUNCH_ATTEMPTED=0
    CURRENT_WAVE_ACTIVATED=0
    CURRENT_WAVE_CONTAINED=0

    acquire_wave_locks
    capture_unaffected_generations "$CURRENT_WAVE_DIR/unaffected.before" "$csv"
    for node in "${CURRENT_WAVE_NODES[@]}"; do
        single_wallet_for "$node" > "$CURRENT_WAVE_DIR/node-$(node_padded "$node")-loaded-wallet.txt" ||
            die "node $node loaded wallet could not be captured before stop"
    done
    capture_wave_legacy_predrain_snapshots ||
        die 'wave did not naturally drain to an allowed legacy PoW state within 20 minutes'
    prepare_wave_candidates
    publish_state_token "$CURRENT_WAVE_DIR/COMMIT_STATE" rollback-boundary-established ||
        die 'rollback boundary state could not be durably published'
    write_wave_evidence_manifest "$wave_index"
    [[ ! -e "$canonical" && ! -L "$canonical" ]] ||
        die "canonical wave path appeared during preparation: $canonical"
    mv -- "$CURRENT_WAVE_DIR" "$canonical"
    CURRENT_WAVE_DIR="$canonical"
    sync -f "$RUN_DIR"
    verify_wave_evidence_manifest "$CURRENT_WAVE_DIR" "$wave_index" ||
        die 'canonical wave evidence changed during atomic publication'
    # From this point forward any failure must recreate the selected nodes on
    # the captured before-triplet, even if no triplet byte has changed yet.
    CURRENT_WAVE_COMMITTED=1
    stop_wave_cleanly
    verify_wave_drain_evidence || die 'post-drain evidence changed before cold backup'
    backup_cold_wallets_and_snapshots
    verify_wave_drain_evidence || die 'post-drain evidence changed before candidate commit'
    commit_wave_triplet
    publish_wave_candidate_launch_authorizations ||
        die 'complete per-node candidate launch authorization could not be durably published'
    start_wave_candidate
    establish_wave_recovery_baselines
    publish_wave_activation_markers ||
        die 'all candidate activation boundaries were not durable before helper launch'
    activate_wave_phase staking
    activate_wave_phase pow
    wait_wave_gate
    assert_unaffected_unchanged "$CURRENT_WAVE_DIR/unaffected.before" \
        "$CURRENT_WAVE_DIR/unaffected.after" "$csv"
    wait_node30_service_gate
    write_wave_runtime_evidence || die 'wave runtime evidence could not be durably published'
    verify_wave_runtime_evidence || die 'published wave runtime evidence changed'
    # RESULT is the durable authority that this wave must never be rolled back
    # as an interrupted attempt. Mask termination across publication and the
    # in-memory boundary so on_exit cannot observe RESULT=passed while the
    # rollback flag still describes an in-progress wave.
    trap '' HUP INT TERM
    if ! publish_state_token "$CURRENT_WAVE_DIR/RESULT" passed; then
        trap 'exit 129' HUP
        trap 'exit 130' INT
        trap 'exit 143' TERM
        die 'passed wave result could not be durably published'
    fi
    CURRENT_WAVE_COMMITTED=0
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    release_wave_locks
    log "wave $wave_index complete: ${CURRENT_WAVE_NODES[*]}"
}

apply_rollout()
{
    local stamp line wave_index=0 resume_state='' interrupted=''
    [[ "${CONFIRM_APPLY:-}" == v30.1.4-exact-32 ]] ||
        die 'apply requires CONFIRM_APPLY=v30.1.4-exact-32'
    require_command flock
    exec 19>/var/run/blackcoin-v30.1.4-fleet-rollout.lock
    flock -n 19 || die 'another v30.1.4 fleet transaction is active'
    if [[ -n "$RUN_DIR" ]]; then
        if [[ ! -f "$RUN_DIR/STATE" || -L "$RUN_DIR/STATE" ]] ||
           ! valid_rollout_run_dir "$RUN_DIR"; then
            die 'resume run path/state is unsafe'
        fi
        resume_state=$(cat "$RUN_DIR/STATE")
        if [[ "$resume_state" == complete ]]; then
            recover_interrupted_finalization_containment_before_preflight ||
                die 'interrupted finalization recontainment could not be recovered safely'
        fi
        if [[ "$resume_state" == applying ]]; then
            interrupted=$(single_interrupted_wave)
            [[ "$interrupted" != __MULTIPLE_INTERRUPTED_WAVES__ ]] ||
                die 'resume contains more than one interrupted committed wave'
            if [[ -n "$interrupted" ]]; then
                resume_interrupted_wave_before_live_preflight "$interrupted"
                acquire_wave_locks
                resume_interrupted_wave_before_live_preflight "$interrupted"
                trap on_exit EXIT
                trap 'exit 129' HUP
                trap 'exit 130' INT
                trap 'exit 143' TERM
                CURRENT_WAVE_COMMITTED=1
                CURRENT_WAVE_ROLLED_BACK=0
                CURRENT_WAVE_LAUNCH_ATTEMPTED=0
                CURRENT_WAVE_ACTIVATED=0
                CURRENT_WAVE_CONTAINED=0
                rollback_current_wave || die 'interrupted wave could not be restored before live preflight'
                release_wave_locks
                CURRENT_WAVE_COMMITTED=0
                trap - EXIT HUP INT TERM
                CURRENT_WAVE_DIR=
                CURRENT_WAVE_NODES=()
            fi
        fi
    fi
    CURRENT_WAVE_NODES=(30)
    acquire_wave_locks
    live_preflight
    [[ -z "$RUN_DIR" ]] || resume_state=$(cat "$RUN_DIR/STATE")
    if [[ -z "$RUN_DIR" ]]; then
        stamp=$(date -u +%Y%m%dT%H%M%SZ)
        RUN_DIR="$OPS_ROOT/rollout-$stamp"
        [[ ! -e "$RUN_DIR" && ! -L "$RUN_DIR" ]] || die 'rollout directory already exists'
        install -d -m 700 -o root -g root "$OPS_ROOT" "$RUN_DIR"
        capture_transaction_baseline
        verify_legacy_rollback_readiness_all_nodes ||
            die 'fresh exact-32 v30.1.3 rollback-readiness gate failed before first mutation'
        create_maintenance_nonce
        write_transaction_manifest
        publish_state_token "$RUN_DIR/STATE" prepared || die 'prepared run state publication failed'
        activate_maintenance_marker
        verify_canary_fleet_handoff ||
            die 'fresh apply did not complete the mandatory atomic canary-to-fleet handoff'
        publish_state_token "$RUN_DIR/STATE" applying || die 'applying run state publication failed'
    else
        verify_transaction_manifest || die 'resume identity changed after locked preflight'
        if [[ "$resume_state" == prepared ]]; then
            activate_maintenance_marker
            verify_canary_fleet_handoff 0 ||
                die 'prepared resume did not complete the mandatory atomic canary-to-fleet handoff'
            publish_state_token "$RUN_DIR/STATE" applying || die 'resume applying state publication failed'
            resume_state=applying
        elif [[ "$resume_state" == applying ]]; then
            verify_maintenance_marker || die 'resume maintenance marker identity changed'
            verify_canary_fleet_handoff 0 ||
                die 'resume canary-to-fleet maintenance handoff evidence changed'
        elif [[ -e "$ROLLOUT_MAINTENANCE_MARKER" || -L "$ROLLOUT_MAINTENANCE_MARKER" ]]; then
            verify_maintenance_marker || die 'complete-run maintenance marker identity changed'
        fi
    fi
    trap on_exit EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    release_wave_locks
    CURRENT_WAVE_NODES=()
    CURRENT_WAVE_DIR=

    if [[ "$resume_state" == complete ]]; then
        FINALIZATION_ACTIVE=1
        finalize_completed_rollout || die 'completed rollout finalization could not be proven'
        FINALIZATION_ACTIVE=0
        trap - EXIT HUP INT TERM
        log "v30.1.4 rollout finalization complete: $RUN_DIR"
        return 0
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        line=${line%%#*}
        line=$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' <<< "$line")
        [[ -n "$line" ]] || continue
        read -r -a wave_nodes <<< "$line"
        wave_index=$((wave_index + 1))
        run_one_wave "$wave_index" "${wave_nodes[@]}"
    done < "$WAVE_PLAN"

    # The auditor reuses the hour-long evidence only after a fresh, cheap
    # exact-32 dynamic/generation and same-tip/chainwork revalidation. A fleet
    # regression invalidates the prior result and begins a new soak window.
    SOAK_RESUME=1 "$SOAK_AUDITOR" "$RUN_DIR" || die 'exact-32 soak audit failed'
    assert_fleet_identity_matches_baseline "$RUN_DIR/final-fleet-identity.json" ||
        die 'wallet, quantum-key, config, or role identity changed during rollout'
    assert_free_claim_container_identity_matches_baseline \
        "$RUN_DIR/final-free-claim-container-identity.pre-release.json" ||
        die 'Free Claim API container identity changed during rollout'
    publish_state_token "$RUN_DIR/STATE" complete || die 'complete run state publication failed'
    FINALIZATION_ACTIVE=1
    finalize_completed_rollout || die 'successful rollout could not safely release transaction inhibitors'
    FINALIZATION_ACTIVE=0
    trap - EXIT HUP INT TERM
    log "v30.1.4 rollout and exact-32 soak complete: $RUN_DIR"
}

rollback_run()
{
    local requested=${2:-} wave result node all_ready wave_name wave_index rollback_state deadline
    local inhibitor_state
    [[ "${CONFIRM_ROLLBACK:-}" == v30.1.4-rollback ]] ||
        die 'rollback requires CONFIRM_ROLLBACK=v30.1.4-rollback'
    [[ -n "$requested" && -d "$requested" && ! -L "$requested" ]] || die 'rollback run directory is unsafe'
    RUN_DIR=$(realpath -e -- "$requested")
    valid_rollout_run_dir "$RUN_DIR" || die 'rollback run is outside the rollout root'
    require_host_tools
    [[ "$(id -u)" -eq 0 ]] || die 'root is required'
    require_rollout_identity
    require_baseline_identity
    verify_transaction_manifest || die 'rollback transaction identity or package bytes changed'
    rollback_state=$(cat "$RUN_DIR/STATE" 2>/dev/null) || die 'run state is unavailable'
    [[ "$rollback_state" == complete || "$rollback_state" == applying ||
       "$rollback_state" == prepared ||
       "$rollback_state" == rolled-back ]] || die 'run state is not rollback-eligible'
    exec 19>/var/run/blackcoin-v30.1.4-fleet-rollout.lock
    flock -n 19 || die 'another rollout transaction is active'
    if [[ "$rollback_state" == complete ]] &&
       [[ -e "$(terminal_receipt_dir)" || -L "$(terminal_receipt_dir)" ]]; then
        verify_terminal_receipt complete 0 ||
            die 'completed terminal receipt is present but changed; rollback is prohibited'
        die 'terminal-finalized rollout cannot reuse destroyed snapshot authority for rollback'
    fi
    if [[ "$rollback_state" == complete ]] &&
       [[ -e "$RUN_DIR/snapshot-cleanup" || -L "$RUN_DIR/snapshot-cleanup" ]]; then
        verify_snapshot_cleanup_resume_prefix ||
            die 'completed rollout snapshot-cleanup prefix is present but changed; rollback is prohibited'
        die 'snapshot cleanup has begun; resume finalization instead of rollback'
    fi
    trap on_exit EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if [[ "$rollback_state" == complete || "$rollback_state" == rolled-back ]]; then
        recover_interrupted_finalization_containment_before_preflight ||
            die 'interrupted finalization recontainment could not be recovered safely before rollback'
    fi
    if [[ "$rollback_state" == rolled-back ]]; then
        FINALIZATION_ACTIVE=1
        finalize_rolled_back_run || die 'rolled-back run finalization could not be proven'
        FINALIZATION_ACTIVE=0
        trap - EXIT HUP INT TERM
        log "full fleet rollback finalization complete: $RUN_DIR"
        return 0
    fi
    assert_empty_control_marker "$ENABLE_GUARD_STARTS" ||
        die 'guard-start authority marker is absent, nonempty, or unsafe'
    inhibitor_state=$(/bin/bash "$INHIBITOR_RELEASER" probe 2>/dev/null || true)
    case "$inhibitor_state" in
        'state=installed-and-paused cycle=v30.1.4-no-spend free_claim=paused') ;;
        'state=installed-and-released cycle=v30.1.4-no-spend free_claim=enabled')
            CONFIRM_EMERGENCY_CONTAIN=v30.1.4-emergency-repause \
                /bin/bash "$INHIBITOR_INSTALLER" emergency-contain ||
                die 'could not re-pause Free Claim before rollback'
            ;;
        *)
            CONFIRM_INSTALL_TRANSACTION_INHIBITORS=v30.1.4-install-transaction-inhibitors \
                /bin/bash "$INHIBITOR_INSTALLER" install ||
                die 'could not durably pause Free Claim and enforce the no-spend cycle before rollback'
            ;;
    esac
    [[ "$(/bin/bash "$INHIBITOR_RELEASER" probe)" == \
       'state=installed-and-paused cycle=v30.1.4-no-spend free_claim=paused' ]] ||
        die 'exact transaction inhibitor state did not verify before rollback'
    verify_free_claim_pause || die 'Free Claim pause did not verify before rollback'
    # A prepared-run crash can still have the live canary marker. Hold the same
    # locks as fresh apply while either adopting that marker or recognizing the
    # already-sealed fleet marker; a rollback must support both prefixes.
    CURRENT_WAVE_NODES=(30)
    acquire_wave_locks
    activate_maintenance_marker post-handoff-reactivation
    verify_maintenance_marker || die 'rollback maintenance marker did not verify'
    release_wave_locks
    CURRENT_WAVE_NODES=()

    while IFS= read -r wave; do
        wave_name=${wave##*/}
        [[ "$wave_name" =~ ^wave-([0-9]{2})-nodes- ]] ||
            die "rollback contains an invalid wave directory: $wave"
        wave_index=$((10#${BASH_REMATCH[1]}))
        verify_wave_evidence_manifest "$wave" "$wave_index" ||
            die "rollback wave evidence or node identity changed: $wave"
        result="$wave/RESULT"
        if [[ -f "$result" ]]; then
            [[ "$(cat "$result")" == passed ]] || continue
        else
            # An interrupted wave can have established its before-triplet and
            # stopped nodes before it wrote RESULT. Recover that boundary too.
            [[ -f "$wave/docker-compose.before.yml" &&
               -f "$wave/fleet-image-policy.before.json" &&
               -f "$wave/blackcoin_endpoint_guard.before.sh" ]] || continue
        fi
        CURRENT_WAVE_DIR="$wave"
        [[ -f "$wave/NODES" && ! -L "$wave/NODES" ]] || die "wave node manifest is absent: $wave"
        read -r -a CURRENT_WAVE_NODES < "$wave/NODES"
        ((${#CURRENT_WAVE_NODES[@]} >= 1 && ${#CURRENT_WAVE_NODES[@]} <= MAX_WAVE_SIZE)) ||
            die "cannot parse wave nodes: $wave"
        acquire_wave_locks
        CURRENT_WAVE_COMMITTED=1
        CURRENT_WAVE_ROLLED_BACK=0
        CURRENT_WAVE_LAUNCH_ATTEMPTED=0
        rollback_current_wave || die "wave rollback failed: $wave"
        release_wave_locks
        CURRENT_WAVE_COMMITTED=0
    done < <(find "$RUN_DIR" -maxdepth 1 -type d -name 'wave-*' -print | sort -r)
    CURRENT_WAVE_NODES=(30)
    acquire_wave_locks
    install_triplet "$RUN_DIR/baseline/docker-compose.yml" \
        "$RUN_DIR/baseline/fleet-image-policy.json" \
        "$RUN_DIR/baseline/blackcoin_endpoint_guard.sh" || die 'final baseline triplet restoration failed'
    deadline=$((SECONDS + 1200))
    while ((SECONDS < deadline)); do
        all_ready=1
        for node in $(seq 1 "$NODE_COUNT"); do
            verify_policy_runtime_node "$node" || all_ready=0
        done
        ((all_ready == 1)) && break
        sleep 5
    done
    ((all_ready == 1)) || die 'restored fleet did not pass the baseline operational gate'
    assert_unique_vpn_proofs || die 'restored fleet VPN proofs are not exact-32 unique'
    release_free_claim_lock
    verify_node30_free_claim_service || die 'restored node30 Free Claim service is not healthy'
    assert_fleet_identity_matches_baseline "$RUN_DIR/rollback-final-fleet-identity.json" ||
        die 'rollback did not restore the original wallet, quantum-key, config, or role identity'
    assert_free_claim_container_identity_matches_baseline \
        "$RUN_DIR/rollback-free-claim-container-identity.json" ||
        die 'rollback did not preserve the original Free Claim API container identity'
    release_wave_locks
    write_rollback_success_evidence || die 'rollback success evidence could not be committed'
    publish_state_token "$RUN_DIR/STATE" rolled-back || die 'rolled-back run state publication failed'
    FINALIZATION_ACTIVE=1
    finalize_rolled_back_run || die 'rollback finalization could not be proven'
    FINALIZATION_ACTIVE=0
    trap - EXIT HUP INT TERM
    log "full fleet configuration/image rollback completed: $RUN_DIR"
}

plan_only()
{
    validate_wave_plan "$WAVE_PLAN" || die 'wave plan is invalid'
    printf 'PACKAGE=%s\nACTION=plan\nWAVE_PLAN=%s\n' "$PACKAGE_ROOT" "$WAVE_PLAN"
    awk 'BEGIN {w=0;n=0} /^[[:space:]]*#/ || /^[[:space:]]*$/ {next}
         {w++; n+=NF; printf "wave=%02d size=%d nodes=%s\n",w,NF,$0}
         END {printf "waves=%d nodes=%d max_wave=4\n",w,n}' "$WAVE_PLAN"
    printf '%s\n' 'No live command was executed.'
}

case "$ACTION" in
    plan)
        plan_only
        ;;
    preflight)
        live_preflight
        log 'preflight passed; no rollout mutation was performed'
        ;;
    apply)
        apply_rollout
        ;;
    rollback)
        rollback_run "$@"
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        usage >&2
        exit 64
        ;;
esac
