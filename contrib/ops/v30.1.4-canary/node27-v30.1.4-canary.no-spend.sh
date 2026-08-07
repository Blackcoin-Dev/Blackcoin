#!/usr/bin/env bash
export LC_ALL=C
set -Eeuo pipefail

umask 077

SOURCE_SHA='13262151077cce3f72d07d17dc7725b2b6a8e1ab'
BLACKCOIND_SHA='f18b4f191599dcb8318008f6758c80c89e473733ef2d8bd06b83d7155618dfb8'
BLACKCOIN_CLI_SHA='3f56bbb180042ace003db62038c47a441b01a6b72ac19497f96c34c9b107ec83'
ORIGINAL_IMAGE='qqblackcoin/blackcoin-v4-gui:30.1.3-final-86c6855ab135-ops1'
ORIGINAL_IMAGE_ID='sha256:bbc2435a034af908dc8c5f0e6976ba89d42347a8e49d5971e4b4d6fb1bbaa391'
DEV_RECIPIENT='blk1szuc2u0wfdnluf2m7m4smw68uzy42hjtmy27aywklqgx55w5erwqslnfs8h'
QUANTUM_ADDRESSES_SHA='28de0da6807148e611560da9201d664ab56259997bf0043776e970f171356101'
QUANTUM_INVENTORY_SHA='1bd1d111eb9ffbb21373938f1b156ffc841e2cabdeae94918b0e01fb5c7cf69e'
NORMAL_UNLOCK_HELPER_SHA='acf28446e842fd0fa92b06c2ebc182e9da38fcde7bac06dd920d50a33e4e3dd1'
POW_START_HELPER_SHA='21808f232ca3961e180a4c2dd3853e4aef93c2dfdf4821b5d63ca5106c5676ea'
WALLET_RUNTIME_GUARD_SHA='9ed02479801cb0de4085f9d6055500bb7d22de86d2fc2b91be6c19e9955398ee'
ENDPOINT_GUARD_SHA='81135dd9637cd5b4fa42a0c634f1decb37fcd68a280c55c661b640226196880f'
EXPECTED_DATADIR_DATASET='pulsar/Blackcoin_Blocks/node-data/node-27'
EXPECTED_BLOCKS_DATASET='pulsar/Blackcoin_Blocks/node-data/node-27/blocks'
EXPECTED_INDEXES_DATASET='pulsar/Blackcoin_Blocks/node-data/node-27/indexes'
EXPECTED_RAW_DATASET='pulsar/Blackcoin_Blocks/alpha-chain-raw-clones-20260715T032403Z/node-27'
CANDIDATE_IMAGE="${CANDIDATE_IMAGE:-}"
CANDIDATE_IMAGE_ID="${CANDIDATE_IMAGE_ID:-}"

COMPOSE='/boot/config/plugins/compose.manager/projects/blackcoin30/docker-compose.yml'
SERVICE='node27'
CONTAINER='blackcoin-v4-gui-27'
CLI='/usr/local/bin/blackcoin-cli'
DATADIR='/home/blackcoin/.blackcoin'
HOST_DATADIR='/mnt/pulsar/Blackcoin_Blocks/node-data/node-27'
HOST_RAW='/mnt/pulsar/Blackcoin_Blocks/27/blocks'
STATE_ROOT='/boot/config/plugins/blackcoin-quantum-nodes'
NORMAL_UNLOCK_HELPER="${STATE_ROOT}/blackcoin_node_normal_unlock.sh"
POW_START_HELPER="${STATE_ROOT}/blackcoin_pow_start_only.sh"
WALLET_RUNTIME_GUARD="${STATE_ROOT}/blackcoin_wallet_runtime_guard.sh"
ENDPOINT_GUARD="${STATE_ROOT}/blackcoin_endpoint_guard.sh"
ENABLE_GUARD_STARTS="${STATE_ROOT}/ENABLE_GUARD_STARTS"
ROLLOUT_MAINTENANCE_MARKER="${STATE_ROOT}/V30_1_4_ROLLOUT_MAINTENANCE.json"
STAGE="/mnt/pulsar/Blackcoin_Blocks/operations/releases/v30.1.4-${SOURCE_SHA}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OPS="${STAGE}/node27-canary-${STAMP}"
EVIDENCE="${OPS}/evidence"
OVERRIDE="${OPS}/node27-v30.1.4.yml"
SNAP="v30.1.4-node27-${STAMP}"
ZFS_HOLD_TAG="blackcoin-v3014-node27-${STAMP}"
SUSPENDED_START_MARKER="${STATE_ROOT}/ENABLE_GUARD_STARTS.node27-${STAMP}.suspended"
CANDIDATE_LAUNCH_MARKER="${EVIDENCE}/CANDIDATE-LAUNCH-ATTEMPTED.json"
CANDIDATE_ACTIVATION_MARKER_1="${EVIDENCE}/candidate-activation-attempted-01.json"
CANDIDATE_ACTIVATION_MARKER_2="${EVIDENCE}/candidate-activation-attempted-02.json"
CANDIDATE_SAFE_MARKER_1="${EVIDENCE}/candidate-safe-boundary-01.json"
CANDIDATE_SAFE_MARKER_2="${EVIDENCE}/candidate-safe-boundary-02.json"
MAINTENANCE_HANDOFF_READY="${EVIDENCE}/maintenance-handoff-ready.json"
MAINTENANCE_NONCE="${OPS}/MAINTENANCE-NONCE"
CANARY_STATE="${OPS}/STATE"
CANARY_RECOVERY_PROCEDURE="${OPS}/CRASH-RECOVERY.json"

phase='preflight'
result='failed'
candidate_launch_attempted=0
start_authority_suspended=0
maintenance_marker_activated=0
maintenance_handoff_ready=false
pre_upgrade_data_restored=false
restored_runtime_verified=false
snapshot_identity_verified=false
snapshot_zero_diff_verified=false
snapshot_holds_released=false
SNAPSHOT_IDENTITY_SHA=''
SNAPSHOT_RESTORE_PROOF_SHA=''
CANDIDATE_LAUNCH_MARKER_SHA=''
PRELAUNCH_TRANSACTION_SET_SHA=''
LOCKED_CANDIDATE_TRANSACTION_SET_SHA=''
MAINTENANCE_NONCE_SHA=''
MAINTENANCE_MARKER_ACTIVATION_SHA=''
RECOVERY_PROCEDURE_SHA=''
MAINTENANCE_ACTIVE_STATE_SHA=''
GUARD_IDENTITIES_SHA=''
CANDIDATE_ACTIVATION_MARKER_1_SHA=''
CANDIDATE_ACTIVATION_MARKER_2_SHA=''
CANDIDATE_SAFE_MARKER_1_SHA=''
CANDIDATE_SAFE_MARKER_2_SHA=''
MAINTENANCE_HANDOFF_READY_SHA=''
INHERITED_CLAIM_INVENTORY_SHA=''
INHERITED_CLAIM_TRANSITION_SHA=''
SNAPSHOT_COUNT=0
POW_DRAIN_SEQUENCE=0
ACTIVATION_SEQUENCE=0
SAFE_SEQUENCE=0
LEGACY_OBSERVED_POW_MODE=''
LEGACY_BASELINE_POW_MODE=''
LEGACY_BASELINE_LIVE_CLAIMS=''
LEGACY_BASELINE_QUARANTINED_CLAIMS=''
RESTORED_LEGACY_LIVE_CLAIMS=''
RESTORED_LEGACY_QUARANTINED_CLAIMS=''
BASELINE_RECOVERY_FEE=''
LAST_CONFIRMED_RECOVERY_FEE=''

fail()
{
    echo "CANARY_FAIL: $*" >&2
    return 1
}

rpc()
{
    timeout -k 2 45 docker exec "$CONTAINER" "$CLI" -datadir="$DATADIR" "$@"
}

wait_rpc()
{
    local _
    for _ in $(seq 1 180); do
        if rpc getblockchaininfo >/dev/null 2>&1; then
            return 0
        fi
        if [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)" != true ]]; then
            docker logs --tail 200 "$CONTAINER" >"${EVIDENCE}/startup-failure.log" 2>&1 || true
            return 1
        fi
        sleep 2
    done
    docker logs --tail 300 "$CONTAINER" >"${EVIDENCE}/startup-timeout.log" 2>&1 || true
    return 1
}

verify_helper()
{
    local helper="$1" expected_sha="$2" actual_sha
    [[ -f "$helper" && ! -L "$helper" ]] || {
        echo "runtime helper is absent, non-regular, or a symlink: $helper" >&2
        return 1
    }
    [[ "$(stat -Lc '%u:%g:%a' -- "$helper")" == 0:0:600 ]] || {
        echo "runtime helper metadata is not root:root 0600: $helper" >&2
        return 1
    }
    actual_sha=$(sha256sum -- "$helper" | awk '{print $1}') || return 1
    [[ "$actual_sha" == "$expected_sha" ]] || {
        echo "runtime helper bytes changed: $helper" >&2
        return 1
    }
}

run_helper()
{
    local helper="$1" expected_sha="$2"
    local _
    for _ in $(seq 1 30); do
        # Revalidate immediately before every attempt.  A path-level preflight
        # alone would not protect the long-running canary from helper replacement.
        verify_helper "$helper" "$expected_sha" || return 1
        if /bin/bash "$helper" 27; then
            return 0
        fi
        sleep 2
    done
    return 1
}

assert_empty_control_marker()
{
    local marker="$1"
    [[ -f "$marker" && ! -L "$marker" &&
       "$(realpath -e -- "$marker" 2>/dev/null || true)" == "$marker" &&
       "$(stat -Lc '%u:%g:%a:%s' -- "$marker" 2>/dev/null || true)" == 0:0:600:0 ]]
}

protected_root_file_0600()
{
    local path="$1"
    [[ -f "$path" && ! -L "$path" &&
       "$(realpath -e -- "$path" 2>/dev/null || true)" == "$path" &&
       "$(stat -Lc '%u:%g:%a' -- "$path" 2>/dev/null || true)" == 0:0:600 ]]
}

canonical_canary_ops_directory()
{
    [[ "$OPS" =~ ^/mnt/pulsar/Blackcoin_Blocks/operations/releases/v30[.]1[.]4-[0-9a-f]{40}/node27-canary-[0-9]{8}T[0-9]{6}Z$ ]] &&
        [[ -d "$OPS" && ! -L "$OPS" &&
           "$(realpath -e -- "$OPS" 2>/dev/null || true)" == "$OPS" &&
           "$(stat -Lc '%u:%g:%a' -- "$OPS" 2>/dev/null || true)" == 0:0:700 ]]
}

verify_guard_compatibility()
{
    local guard begin end canary_case canary_path canary_state runtime_line endpoint_pin
    begin='# BEGIN V30.1.4 DURABLE ROLLOUT MAINTENANCE INHIBITOR'
    end='# END V30.1.4 DURABLE ROLLOUT MAINTENANCE INHIBITOR'
    canary_case='        v30.1.4-node27-canary)'
    # shellcheck disable=SC2016
    canary_path='            [[ "$run_dir" =~ ^/mnt/pulsar/Blackcoin_Blocks/operations/releases/v30[.]1[.]4-[0-9a-f]{40}/node27-canary-[0-9]{8}T[0-9]{6}Z$ ]] ||'
    # shellcheck disable=SC2016
    canary_state='            [[ "$run_state" == active ]] || return 1'
    # shellcheck disable=SC2016
    runtime_line='    [[ "$class" == final3013 || "$class" == node16fix || "$class" == final3014 ]] && expected_replay_schema=12'
    endpoint_pin="EXPECTED_RUNTIME_GUARD_SHA='$WALLET_RUNTIME_GUARD_SHA'"

    protected_root_file_0600 "$WALLET_RUNTIME_GUARD" &&
        protected_root_file_0600 "$ENDPOINT_GUARD" || return 1
    [[ "$(sha256sum "$WALLET_RUNTIME_GUARD" | awk '{print $1}')" == "$WALLET_RUNTIME_GUARD_SHA" &&
       "$(sha256sum "$ENDPOINT_GUARD" | awk '{print $1}')" == "$ENDPOINT_GUARD_SHA" ]] ||
        return 1
    for guard in "$WALLET_RUNTIME_GUARD" "$ENDPOINT_GUARD"; do
        [[ "$(grep -Fxc -- "$begin" "$guard")" == 1 &&
           "$(grep -Fxc -- "$end" "$guard")" == 1 &&
           "$(grep -Fxc -- "$canary_case" "$guard")" == 2 &&
           "$(grep -Fxc -- "$canary_path" "$guard")" == 1 &&
           "$(grep -Fxc -- "$canary_state" "$guard")" == 1 ]] || return 1
    done
    [[ "$(grep -Fxc -- "$runtime_line" "$WALLET_RUNTIME_GUARD")" == 1 &&
       "$(grep -Fxc -- "$endpoint_pin" "$ENDPOINT_GUARD")" == 1 ]]
}

publish_canary_state()
{
    local state="$1" temporary
    [[ "$state" == active || "$state" == complete ]] || return 1
    canonical_canary_ops_directory || return 1
    temporary=$(mktemp "${OPS}/.canary-state.XXXXXX") || return 1
    printf '%s\n' "$state" > "$temporary" || return 1
    chmod 600 "$temporary" || return 1
    chown root:root "$temporary" || return 1
    sync -f "$temporary" || return 1
    mv -fT -- "$temporary" "$CANARY_STATE" || return 1
    sync -f "$CANARY_STATE" || return 1
    sync -f "$OPS" || return 1
    protected_root_file_0600 "$CANARY_STATE" && [[ "$(cat "$CANARY_STATE")" == "$state" ]]
}

publish_crash_recovery_procedure()
{
    local temporary
    [[ "$MAINTENANCE_NONCE_SHA" =~ ^[0-9a-f]{64}$ ]] || return 1
    [[ ! -e "$CANARY_RECOVERY_PROCEDURE" && ! -L "$CANARY_RECOVERY_PROCEDURE" ]] ||
        return 1
    temporary=$(mktemp "${OPS}/.crash-recovery.XXXXXX") || return 1
    jq -n --arg marker "$ROLLOUT_MAINTENANCE_MARKER" --arg run "$OPS" \
        --arg state "$CANARY_STATE" --arg nonce "$MAINTENANCE_NONCE" \
        --arg nonce_sha "$MAINTENANCE_NONCE_SHA" \
        --arg launch "$CANDIDATE_LAUNCH_MARKER" --arg original "$ORIGINAL_IMAGE" \
        --arg original_id "$ORIGINAL_IMAGE_ID" --arg normal_sha "$NORMAL_UNLOCK_HELPER_SHA" \
        --arg pow_sha "$POW_START_HELPER_SHA" \
        --arg datadir "$EXPECTED_DATADIR_DATASET" --arg blocks "$EXPECTED_BLOCKS_DATASET" \
        --arg indexes "$EXPECTED_INDEXES_DATASET" --arg raw "$EXPECTED_RAW_DATASET" '
        {schema:1,transaction:"v30.1.4-node27-canary",recovery_mode:"manual-audited-only",
         executable_recovery:false,
         run_dir:$run,maintenance_marker:$marker,state_file:$state,nonce_file:$nonce,
         nonce_sha256:$nonce_sha,candidate_launch_marker:$launch,
         required_lock_order:["/run/blackcoin-endpoint-guard.lock",
           "/var/run/blackcoin-node-cutover.lock","/run/blackcoin-pow-quarantine-cycle.lock",
           "/var/run/blackcoin-wallet-runtime-guard.lock"],
         original_image:$original,original_image_id:$original_id,
         normal_unlock_helper_sha256:$normal_sha,pow_start_helper_sha256:$pow_sha,
         exact_rollback_datasets:[$datadir,$blocks,$indexes,$raw],
         procedure:[
           "Do not delete the maintenance marker, start or unlock node27, or run either supervisor before recovery locks are held.",
           "Acquire all four required locks in the listed order and validate the exact compatible guard hashes, canonical run directory, active state, nonce hash, and exact marker object.",
           "Inspect CANDIDATE-LAUNCH-ATTEMPTED.json. If it exists, validate its image, snapshot, hold, nonce, and marker hashes before trusting any rollback evidence.",
           "Inspect every immutable candidate-activation-attempted and candidate-safe-boundary marker. After candidate launch, the absence of an activation marker is not rollback authority: startup may have violated locked/off assumptions, so RPC loss, absence, or identity ambiguity requires containment and forbids ZFS rollback.",
           "After activation, rollback is permitted only after RPC explicitly disables staking and PoW, locks the wallet, proves two fresh exact transaction-set and unchanged-fee q0 samples, durably publishes the matching safe-boundary marker, and cleanly stops the exact candidate.",
           "When candidate launch was attempted and the safe boundary is proven, validate the exact four held snapshot identities, roll back children before parents with plain zfs rollback only, and require zero zfs diff for every dataset. Never use recursive, destructive, or forced rollback flags.",
           "If the exact old image and invocation already exist, do not apply the candidate drain to it and do not repeat rollback until exact zero-diff restoration is proven.",
           "Recreate node27 only from the pinned base Compose model and original immutable image. Before unlock, require the exact locked transaction set and normalized cold legacy PoW projection. Then run the pinned normal-unlock helper. Run the pinned PoW helper only when the observed legacy baseline was clean one-thread hashing; for the exact disabled q1 exception, never run the PoW helper or attempt claim resolution.",
           "Prove the original image and invocation, healthy RPC/network/chain, active PoS, either clean one-thread PoW or the exact disabled legacy quarantined-claim count, wallet/config/address/key/transaction identity, and exact pre-upgrade data restoration.",
           "Release transaction-specific snapshot holds and restore ENABLE_GUARD_STARTS only after the exact old runtime is verified; the still-active canary marker continues to inhibit both supervisors.",
           "Keep the exact maintenance marker and STATE active. Seal maintenance-handoff-ready.json, RESULT.json, and SHA256SUMS for an authenticated atomic fleet-marker takeover. Never unlink the marker or set STATE complete in this canary."
         ]}
    ' > "$temporary" || return 1
    chmod 600 "$temporary" || return 1
    chown root:root "$temporary" || return 1
    sync -f "$temporary" || return 1
    mv -fT -- "$temporary" "$CANARY_RECOVERY_PROCEDURE" || return 1
    sync -f "$CANARY_RECOVERY_PROCEDURE" || return 1
    sync -f "$OPS" || return 1
    protected_root_file_0600 "$CANARY_RECOVERY_PROCEDURE" || return 1
    RECOVERY_PROCEDURE_SHA=$(sha256sum "$CANARY_RECOVERY_PROCEDURE" | awk '{print $1}') ||
        return 1
    [[ "$RECOVERY_PROCEDURE_SHA" =~ ^[0-9a-f]{64}$ ]]
}

validate_canary_maintenance_marker()
{
    local nonce
    canonical_canary_ops_directory || return 1
    protected_root_file_0600 "$MAINTENANCE_NONCE" || return 1
    protected_root_file_0600 "$CANARY_STATE" || return 1
    protected_root_file_0600 "$CANARY_RECOVERY_PROCEDURE" || return 1
    protected_root_file_0600 "$ROLLOUT_MAINTENANCE_MARKER" || return 1
    nonce=$(cat "$MAINTENANCE_NONCE") || return 1
    [[ "$nonce" =~ ^[0-9a-f]{64}$ && "$(cat "$CANARY_STATE")" == active &&
       "$MAINTENANCE_NONCE_SHA" =~ ^[0-9a-f]{64}$ &&
       "$(sha256sum "$MAINTENANCE_NONCE" | awk '{print $1}')" == "$MAINTENANCE_NONCE_SHA" &&
       "$RECOVERY_PROCEDURE_SHA" =~ ^[0-9a-f]{64}$ &&
       "$(sha256sum "$CANARY_RECOVERY_PROCEDURE" | awk '{print $1}')" == "$RECOVERY_PROCEDURE_SHA" ]] || return 1
    jq -e --arg nonce "$nonce" --arg run "$OPS" '
        . == {schema:1,transaction:"v30.1.4-node27-canary",state:"active",
              run_nonce:$nonce,run_dir:$run}
    ' "$ROLLOUT_MAINTENANCE_MARKER" >/dev/null
}

activate_canary_maintenance_marker()
{
    local nonce nonce_tmp marker_tmp
    verify_guard_compatibility || return 1
    canonical_canary_ops_directory || return 1
    [[ ! -e "$ROLLOUT_MAINTENANCE_MARKER" && ! -L "$ROLLOUT_MAINTENANCE_MARKER" &&
       ! -e "$MAINTENANCE_NONCE" && ! -L "$MAINTENANCE_NONCE" &&
       ! -e "$CANARY_STATE" && ! -L "$CANARY_STATE" ]] || return 1

    nonce=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n') || return 1
    [[ "$nonce" =~ ^[0-9a-f]{64}$ ]] || return 1
    nonce_tmp=$(mktemp "${OPS}/.maintenance-nonce.XXXXXX") || return 1
    printf '%s\n' "$nonce" > "$nonce_tmp" || return 1
    chmod 600 "$nonce_tmp" || return 1
    chown root:root "$nonce_tmp" || return 1
    sync -f "$nonce_tmp" || return 1
    mv -fT -- "$nonce_tmp" "$MAINTENANCE_NONCE" || return 1
    sync -f "$MAINTENANCE_NONCE" || return 1
    sync -f "$OPS" || return 1
    MAINTENANCE_NONCE_SHA=$(sha256sum "$MAINTENANCE_NONCE" | awk '{print $1}') || return 1
    [[ "$MAINTENANCE_NONCE_SHA" =~ ^[0-9a-f]{64}$ ]] || return 1
    publish_canary_state active || return 1
    publish_crash_recovery_procedure || return 1

    marker_tmp=$(mktemp "${STATE_ROOT}/.v3014-node27-canary-maintenance.XXXXXX") || return 1
    jq -n --arg nonce "$nonce" --arg run "$OPS" \
        '{schema:1,transaction:"v30.1.4-node27-canary",state:"active",
          run_nonce:$nonce,run_dir:$run}' > "$marker_tmp" || return 1
    chmod 600 "$marker_tmp" || return 1
    chown root:root "$marker_tmp" || return 1
    sync -f "$marker_tmp" || return 1
    mv -fT -- "$marker_tmp" "$ROLLOUT_MAINTENANCE_MARKER" || return 1
    sync -f "$ROLLOUT_MAINTENANCE_MARKER" || return 1
    sync -f "$STATE_ROOT" || return 1
    validate_canary_maintenance_marker || return 1

    install -m 600 -o root -g root "$ROLLOUT_MAINTENANCE_MARKER" \
        "${EVIDENCE}/maintenance-marker-activated.json" || return 1
    install -m 600 -o root -g root "$MAINTENANCE_NONCE" \
        "${EVIDENCE}/maintenance-nonce.txt" || return 1
    install -m 600 -o root -g root "$CANARY_STATE" \
        "${EVIDENCE}/maintenance-state-active.txt" || return 1
    install -m 600 -o root -g root "$CANARY_RECOVERY_PROCEDURE" \
        "${EVIDENCE}/crash-recovery-procedure.json" || return 1
    {
        printf 'path\tsha256\tuid:gid:mode\n'
        printf '%s\t%s\t%s\n' "$WALLET_RUNTIME_GUARD" "$WALLET_RUNTIME_GUARD_SHA" \
            "$(stat -Lc '%u:%g:%a' -- "$WALLET_RUNTIME_GUARD")"
        printf '%s\t%s\t%s\n' "$ENDPOINT_GUARD" "$ENDPOINT_GUARD_SHA" \
            "$(stat -Lc '%u:%g:%a' -- "$ENDPOINT_GUARD")"
    } > "${EVIDENCE}/maintenance-compatible-guard-identities.tsv" || return 1
    chmod 600 "${EVIDENCE}/maintenance-compatible-guard-identities.tsv" || return 1
    chown root:root "${EVIDENCE}/maintenance-compatible-guard-identities.tsv" || return 1
    sync -f "${EVIDENCE}/maintenance-marker-activated.json" || return 1
    sync -f "${EVIDENCE}/maintenance-nonce.txt" || return 1
    sync -f "${EVIDENCE}/maintenance-state-active.txt" || return 1
    sync -f "${EVIDENCE}/crash-recovery-procedure.json" || return 1
    sync -f "${EVIDENCE}/maintenance-compatible-guard-identities.tsv" || return 1
    sync -f "$EVIDENCE" || return 1
    cmp -s "$ROLLOUT_MAINTENANCE_MARKER" \
        "${EVIDENCE}/maintenance-marker-activated.json" || return 1

    MAINTENANCE_MARKER_ACTIVATION_SHA=$(sha256sum \
        "${EVIDENCE}/maintenance-marker-activated.json" | awk '{print $1}') || return 1
    MAINTENANCE_ACTIVE_STATE_SHA=$(sha256sum \
        "${EVIDENCE}/maintenance-state-active.txt" | awk '{print $1}') || return 1
    GUARD_IDENTITIES_SHA=$(sha256sum \
        "${EVIDENCE}/maintenance-compatible-guard-identities.tsv" | awk '{print $1}') || return 1
    [[ "$MAINTENANCE_MARKER_ACTIVATION_SHA" =~ ^[0-9a-f]{64}$ &&
       "$RECOVERY_PROCEDURE_SHA" =~ ^[0-9a-f]{64}$ &&
       "$MAINTENANCE_ACTIVE_STATE_SHA" =~ ^[0-9a-f]{64}$ &&
       "$GUARD_IDENTITIES_SHA" =~ ^[0-9a-f]{64}$ &&
       "$(sha256sum "${EVIDENCE}/crash-recovery-procedure.json" | awk '{print $1}')" == "$RECOVERY_PROCEDURE_SHA" ]] || return 1
    maintenance_marker_activated=1
}

publish_maintenance_handoff_ready()
{
    local temporary attempt health_ready=false
    [[ "$phase" == restored && "$pre_upgrade_data_restored" == true &&
       "$restored_runtime_verified" == true &&
       "$snapshot_identity_verified" == true && "$snapshot_zero_diff_verified" == true &&
       "$snapshot_holds_released" == true && "$start_authority_suspended" == 0 &&
       "$maintenance_marker_activated" == 1 && "$maintenance_handoff_ready" == false ]] ||
        return 1
    verify_rollback_image_ready || return 1
    verify_guard_compatibility || return 1
    [[ "$(sha256sum "${EVIDENCE}/maintenance-compatible-guard-identities.tsv" | awk '{print $1}')" == "$GUARD_IDENTITIES_SHA" ]] ||
        return 1
    validate_canary_maintenance_marker || return 1
    assert_empty_control_marker "$ENABLE_GUARD_STARTS" || return 1
    [[ ! -e "$SUSPENDED_START_MARKER" && ! -L "$SUSPENDED_START_MARKER" ]] || return 1
    [[ "$ACTIVATION_SEQUENCE" == 2 && "$SAFE_SEQUENCE" == 2 ]] || return 1
    [[ "$CANDIDATE_ACTIVATION_MARKER_1_SHA" =~ ^[0-9a-f]{64}$ &&
       "$CANDIDATE_ACTIVATION_MARKER_2_SHA" =~ ^[0-9a-f]{64}$ &&
       "$CANDIDATE_SAFE_MARKER_1_SHA" =~ ^[0-9a-f]{64}$ &&
       "$CANDIDATE_SAFE_MARKER_2_SHA" =~ ^[0-9a-f]{64}$ ]] || return 1
    [[ "$(sha256sum "$CANDIDATE_ACTIVATION_MARKER_1" | awk '{print $1}')" == "$CANDIDATE_ACTIVATION_MARKER_1_SHA" &&
       "$(sha256sum "$CANDIDATE_ACTIVATION_MARKER_2" | awk '{print $1}')" == "$CANDIDATE_ACTIVATION_MARKER_2_SHA" &&
       "$(sha256sum "$CANDIDATE_SAFE_MARKER_1" | awk '{print $1}')" == "$CANDIDATE_SAFE_MARKER_1_SHA" &&
       "$(sha256sum "$CANDIDATE_SAFE_MARKER_2" | awk '{print $1}')" == "$CANDIDATE_SAFE_MARKER_2_SHA" ]] || return 1

    for attempt in $(seq 1 120); do
        if [[ "$(container_runtime_kind 2>/dev/null || true)" == original ]] &&
           docker inspect "$CONTAINER" | jq -e 'length == 1 and
               .[0].State.Running == true and .[0].State.Health.Status == "healthy"' \
               >/dev/null 2>&1; then
            health_ready=true
            break
        fi
        sleep 2
    done
    [[ "$health_ready" == true ]] || return 1

    temporary=$(mktemp "${OPS}/.maintenance-handoff-ready.XXXXXX") || return 1
    jq -n --arg marker "$ROLLOUT_MAINTENANCE_MARKER" --arg run "$OPS" \
        --arg nonce_sha "$MAINTENANCE_NONCE_SHA" \
        --arg marker_activation_sha "$MAINTENANCE_MARKER_ACTIVATION_SHA" \
        --arg recovery_sha "$RECOVERY_PROCEDURE_SHA" \
        --arg active_state_sha "$MAINTENANCE_ACTIVE_STATE_SHA" \
        --arg guard_identities_sha "$GUARD_IDENTITIES_SHA" \
        --arg activation_1_sha "$CANDIDATE_ACTIVATION_MARKER_1_SHA" \
        --arg activation_2_sha "$CANDIDATE_ACTIVATION_MARKER_2_SHA" \
        --arg safe_1_sha "$CANDIDATE_SAFE_MARKER_1_SHA" \
        --arg safe_2_sha "$CANDIDATE_SAFE_MARKER_2_SHA" \
        --arg timestamp "$(date -u +%FT%TZ)" '
        {schema:1,transaction:"v30.1.4-node27-canary",state:"active",
         marker:$marker,run_dir:$run,run_nonce_sha256:$nonce_sha,
         marker_activation_sha256:$marker_activation_sha,
         crash_recovery_procedure_sha256:$recovery_sha,
         active_state_evidence_sha256:$active_state_sha,
         guard_identity_evidence_sha256:$guard_identities_sha,
         candidate_activation_markers:[
           {sequence:1,file:"candidate-activation-attempted-01.json",sha256:$activation_1_sha},
           {sequence:2,file:"candidate-activation-attempted-02.json",sha256:$activation_2_sha}],
         candidate_safe_markers:[
           {sequence:1,purpose:"pre_restart",file:"candidate-safe-boundary-01.json",sha256:$safe_1_sha},
           {sequence:2,purpose:"pre_rollback",file:"candidate-safe-boundary-02.json",sha256:$safe_2_sha}],
         pre_upgrade_data_restored:true,old_container_runtime_verified:true,
         snapshot_holds_released:true,automatic_start_authority_restored:true,
         marker_released:false,live_marker_active:true,
         maintenance_handoff_ready:true,
         required_next_action:"atomic_authenticated_fleet_marker_takeover",
         timestamp:$timestamp}
    ' > "$temporary" || return 1
    chmod 600 "$temporary" || return 1
    chown root:root "$temporary" || return 1
    sync -f "$temporary" || return 1
    mv -fT -- "$temporary" "$MAINTENANCE_HANDOFF_READY" || return 1
    sync -f "$MAINTENANCE_HANDOFF_READY" || return 1
    sync -f "$EVIDENCE" || return 1
    MAINTENANCE_HANDOFF_READY_SHA=$(sha256sum "$MAINTENANCE_HANDOFF_READY" | awk '{print $1}') ||
        return 1
    [[ "$MAINTENANCE_HANDOFF_READY_SHA" =~ ^[0-9a-f]{64}$ ]] || return 1
    validate_canary_maintenance_marker || return 1
    protected_root_file_0600 "$CANARY_STATE" && [[ "$(cat "$CANARY_STATE")" == active ]] ||
        return 1
    maintenance_handoff_ready=true
}

verify_rollback_image_ready()
{
    [[ "$(docker compose -f "$COMPOSE" config --format json 2>/dev/null |
        jq -er '.services.node27.image' 2>/dev/null || true)" == "$ORIGINAL_IMAGE" ]] &&
        [[ "$(docker image inspect -f '{{.Id}}' "$ORIGINAL_IMAGE" 2>/dev/null || true)" == \
           "$ORIGINAL_IMAGE_ID" ]]
}

guard_starts_are_suspended()
{
    [[ ! -e "$ENABLE_GUARD_STARTS" && ! -L "$ENABLE_GUARD_STARTS" ]] &&
        assert_empty_control_marker "$SUSPENDED_START_MARKER"
}

ensure_guard_starts_suspended()
{
    if guard_starts_are_suspended; then
        start_authority_suspended=1
        return 0
    fi
    assert_empty_control_marker "$ENABLE_GUARD_STARTS" || return 1
    [[ ! -e "$SUSPENDED_START_MARKER" && ! -L "$SUSPENDED_START_MARKER" ]] || return 1
    mv -- "$ENABLE_GUARD_STARTS" "$SUSPENDED_START_MARKER" || return 1
    sync -f "$SUSPENDED_START_MARKER" || return 1
    sync -f "$STATE_ROOT" || return 1
    guard_starts_are_suspended || return 1
    start_authority_suspended=1
}

suspend_guard_starts()
{
    local temporary
    ensure_guard_starts_suspended || return 1

    temporary=$(mktemp "${OPS}/.start-authority-suspended.XXXXXX") || return 1
    jq -n --arg live "$ENABLE_GUARD_STARTS" --arg suspended "$SUSPENDED_START_MARKER" \
        --arg timestamp "$(date -u +%FT%TZ)" \
        '{schema:1,automatic_starts_suspended:true,live_marker:$live,
          suspended_marker:$suspended,timestamp:$timestamp}' > "$temporary" || return 1
    chmod 600 "$temporary" || return 1
    chown root:root "$temporary" || return 1
    sync -f "$temporary" || return 1
    mv -fT -- "$temporary" "${EVIDENCE}/guard-start-authority-suspended.json" || return 1
    sync -f "${EVIDENCE}/guard-start-authority-suspended.json" || return 1
    sync -f "$EVIDENCE" || return 1
}

restore_guard_starts()
{
    if assert_empty_control_marker "$ENABLE_GUARD_STARTS"; then
        [[ ! -e "$SUSPENDED_START_MARKER" && ! -L "$SUSPENDED_START_MARKER" ]] || return 1
        start_authority_suspended=0
        return 0
    fi
    guard_starts_are_suspended || return 1
    mv -- "$SUSPENDED_START_MARKER" "$ENABLE_GUARD_STARTS" || return 1
    sync -f "$ENABLE_GUARD_STARTS" || return 1
    sync -f "$STATE_ROOT" || return 1
    assert_empty_control_marker "$ENABLE_GUARD_STARTS" || return 1
    [[ ! -e "$SUSPENDED_START_MARKER" && ! -L "$SUSPENDED_START_MARKER" ]] || return 1
    start_authority_suspended=0
}

validate_candidate_launch_marker()
{
    [[ -f "$CANDIDATE_LAUNCH_MARKER" && ! -L "$CANDIDATE_LAUNCH_MARKER" &&
       "$(realpath -e -- "$CANDIDATE_LAUNCH_MARKER" 2>/dev/null || true)" == \
       "$CANDIDATE_LAUNCH_MARKER" &&
       "$(stat -Lc '%u:%g:%a' -- "$CANDIDATE_LAUNCH_MARKER" 2>/dev/null || true)" == 0:0:600 ]] ||
        return 1
    jq -e --arg source "$SOURCE_SHA" --arg image "$CANDIDATE_IMAGE" \
        --arg image_id "$CANDIDATE_IMAGE_ID" --arg snapshot "$SNAP" \
        --arg hold "$ZFS_HOLD_TAG" --arg identity_sha "$SNAPSHOT_IDENTITY_SHA" \
        --arg suspended "$SUSPENDED_START_MARKER" --argjson count "$SNAPSHOT_COUNT" \
        --arg maintenance_marker "$ROLLOUT_MAINTENANCE_MARKER" \
        --arg maintenance_nonce_sha "$MAINTENANCE_NONCE_SHA" \
        --arg maintenance_activation_sha "$MAINTENANCE_MARKER_ACTIVATION_SHA" \
        --arg recovery_procedure_sha "$RECOVERY_PROCEDURE_SHA" \
        --arg maintenance_active_state_sha "$MAINTENANCE_ACTIVE_STATE_SHA" \
        --arg guard_identities_sha "$GUARD_IDENTITIES_SHA" '
        .schema == 1 and .candidate_launch_attempted == true and
        .source_sha == $source and .candidate_image == $image and
        .candidate_image_id == $image_id and .zfs_snapshot_suffix == $snapshot and
        .zfs_hold_tag == $hold and .zfs_snapshot_count == $count and
        .zfs_snapshot_identity_sha256 == $identity_sha and
        .guard_start_suspended_marker == $suspended and
        .maintenance_marker == $maintenance_marker and
        .maintenance_nonce_sha256 == $maintenance_nonce_sha and
        .maintenance_marker_activation_sha256 == $maintenance_activation_sha and
        .crash_recovery_procedure_sha256 == $recovery_procedure_sha and
        .maintenance_active_state_sha256 == $maintenance_active_state_sha and
        .maintenance_guard_identities_sha256 == $guard_identities_sha
    ' "$CANDIDATE_LAUNCH_MARKER" >/dev/null
}

publish_candidate_launch_marker()
{
    local temporary
    guard_starts_are_suspended || return 1
    validate_canary_maintenance_marker || return 1
    verify_guard_compatibility || return 1
    verify_rollback_image_ready || return 1
    verify_snapshot_inventory_identity || return 1
    [[ ! -e "$CANDIDATE_LAUNCH_MARKER" && ! -L "$CANDIDATE_LAUNCH_MARKER" ]] || return 1
    temporary=$(mktemp "${OPS}/.candidate-launch-attempted.XXXXXX") || return 1
    jq -n --arg source "$SOURCE_SHA" --arg image "$CANDIDATE_IMAGE" \
        --arg image_id "$CANDIDATE_IMAGE_ID" --arg snapshot "$SNAP" \
        --arg hold "$ZFS_HOLD_TAG" --arg identity_sha "$SNAPSHOT_IDENTITY_SHA" \
        --arg suspended "$SUSPENDED_START_MARKER" --arg timestamp "$(date -u +%FT%TZ)" \
        --arg maintenance_marker "$ROLLOUT_MAINTENANCE_MARKER" \
        --arg maintenance_nonce_sha "$MAINTENANCE_NONCE_SHA" \
        --arg maintenance_activation_sha "$MAINTENANCE_MARKER_ACTIVATION_SHA" \
        --arg recovery_procedure_sha "$RECOVERY_PROCEDURE_SHA" \
        --arg maintenance_active_state_sha "$MAINTENANCE_ACTIVE_STATE_SHA" \
        --arg guard_identities_sha "$GUARD_IDENTITIES_SHA" \
        --argjson count "$SNAPSHOT_COUNT" \
        '{schema:1,candidate_launch_attempted:true,source_sha:$source,
          candidate_image:$image,candidate_image_id:$image_id,
          zfs_snapshot_suffix:$snapshot,zfs_hold_tag:$hold,zfs_snapshot_count:$count,
          zfs_snapshot_identity_sha256:$identity_sha,
          guard_start_suspended_marker:$suspended,
          maintenance_marker:$maintenance_marker,
          maintenance_nonce_sha256:$maintenance_nonce_sha,
          maintenance_marker_activation_sha256:$maintenance_activation_sha,
          crash_recovery_procedure_sha256:$recovery_procedure_sha,
          maintenance_active_state_sha256:$maintenance_active_state_sha,
          maintenance_guard_identities_sha256:$guard_identities_sha,
          timestamp:$timestamp}' > "$temporary" || return 1
    chmod 600 "$temporary" || return 1
    chown root:root "$temporary" || return 1
    sync -f "$temporary" || return 1
    mv -fT -- "$temporary" "$CANDIDATE_LAUNCH_MARKER" || return 1
    sync -f "$CANDIDATE_LAUNCH_MARKER" || return 1
    sync -f "$EVIDENCE" || return 1
    sync -f "$OPS" || return 1
    validate_candidate_launch_marker || return 1
    CANDIDATE_LAUNCH_MARKER_SHA=$(sha256sum "$CANDIDATE_LAUNCH_MARKER" | awk '{print $1}') || return 1
    [[ "$CANDIDATE_LAUNCH_MARKER_SHA" =~ ^[0-9a-f]{64}$ ]] || return 1
    candidate_launch_attempted=1
}

require_claim_recovery_clean()
{
    local evidence_prefix="$1" attempt info current_fee
    for attempt in $(seq 1 240); do
        info="${EVIDENCE}/${evidence_prefix}-recovery-clean-${attempt}.json"
        rpc getpowclaimrecoveryinfo true >"$info" || {
            echo 'claim-recovery status RPC failed' >&2
            return 1
        }
        jq -e '.database_outcome_ambiguous == false and .policy_authoritative == true and
            .policy.automatic_authorized == false' \
            "$info" >/dev/null || {
            echo 'claim recovery database/policy is ambiguous or automatic fee recovery is authorized' >&2
            return 1
        }
        # Immediately after startup the chain tip can advance before the
        # wallet-processed tip catches up.  Core correctly marks every retained
        # claim indeterminate in that typed state.  Wait only for this explicit
        # convergence condition; once tips match, any remaining indeterminate
        # claim is a real fail-closed result.
        if ! jq -e '.wallet_tip_matches == true' "$info" >/dev/null; then
            sleep 5
            continue
        fi
        jq -e '.indeterminate_quarantined_claims == 0' "$info" >/dev/null || {
            echo 'claim recovery remains indeterminate on a matched wallet tip' >&2
            return 1
        }
        if jq -e '.blocking_quarantined_claims == 0 and .blocking_components == 0 and
            .pending_manual_resolutions == 0 and .pending_automatic_resolutions == 0' \
            "$info" >/dev/null; then
            current_fee=$(jq -er '.confirmed_resolution_fees' "$info") || return 1
            [[ "$current_fee" == "$BASELINE_RECOVERY_FEE" ]] || {
                echo 'claim-recovery fee total changed during the no-spend canary' >&2
                return 1
            }
            LAST_CONFIRMED_RECOVERY_FEE=$current_fee
            install -m 600 -o root -g root "$info" \
                "${EVIDENCE}/${evidence_prefix}-recovery-clean.json" || return 1
            return 0
        fi
        echo 'blocking claim recovery is present; no-spend canary refuses resolution' >&2
        return 1
    done
    echo 'wallet/chain claim-recovery tips did not converge within 20 minutes' >&2
    return 1
}

legacy_pow_observed_mode()
{
    local mining_file="$1"
    if jq -e '
        type == "object" and
        (.enabled | type == "boolean" and . == true) and
        (.autostart | type == "boolean" and . == false) and
        (.allow_automatic_quantum_key_creation | type == "boolean" and . == false) and
        (.threads | type == "number" and floor == . and . == 1) and
        (.cpu_percent | type == "number" and . == 1) and
        (.hashrate | type == "number" and . > 0) and
        (.unresolved_claims | type == "number" and floor == . and . == 0) and
        (.live_claims | type == "number" and floor == . and . == 0) and
        (.quarantined_claims | type == "number" and floor == . and . == 0)
    ' "$mining_file" >/dev/null; then
        printf '%s\n' clean-hashing
        return 0
    fi
    if jq -e '
        type == "object" and
        (.enabled | type == "boolean" and . == false) and
        (.autostart | type == "boolean" and . == false) and
        (.allow_automatic_quantum_key_creation | type == "boolean" and . == false) and
        (.state | type == "string" and . == "disabled") and
        (.threads | type == "number" and floor == . and . == 1) and
        (.cpu_percent | type == "number" and . == 1) and
        (.hashrate | type == "number" and . == 0) and
        (.unresolved_claims | type == "number" and floor == . and . == 1) and
        (.live_claims | type == "number" and floor == . and . == 0) and
        (.quarantined_claims | type == "number" and floor == . and . == 1)
    ' "$mining_file" >/dev/null; then
        printf '%s\n' quarantined-disabled
        return 0
    fi
    if jq -e '
        type == "object" and
        (.enabled | type == "boolean" and . == true) and
        (.autostart | type == "boolean" and . == false) and
        (.allow_automatic_quantum_key_creation | type == "boolean" and . == false) and
        (.state | type == "string" and . == "claim_quarantined") and
        (.threads | type == "number" and floor == . and . == 1) and
        (.cpu_percent | type == "number" and . == 1) and
        (.hashrate | type == "number" and . == 0) and
        (.unresolved_claims | type == "number" and floor == . and . == 1) and
        (.live_claims | type == "number" and floor == . and . == 0) and
        (.quarantined_claims | type == "number" and floor == . and . == 1)
    ' "$mining_file" >/dev/null; then
        printf '%s\n' quarantined-stalled
        return 0
    fi
    return 1
}

legacy_cold_pow_is_exact()
{
    local mining_file="$1" quarantined="$2"
    jq -e --argjson quarantined "$quarantined" '
        type == "object" and
        (.enabled | type == "boolean" and . == false) and
        (.autostart | type == "boolean" and . == false) and
        (.allow_automatic_quantum_key_creation | type == "boolean" and . == false) and
        (.state | type == "string" and . == "disabled") and
        (.threads | type == "number" and floor == . and . == 1) and
        (.cpu_percent | type == "number" and . == 1) and
        (.hashrate | type == "number" and . == 0) and
        (.unresolved_claims | type == "number" and floor == . and . == $quarantined) and
        (.live_claims | type == "number" and floor == . and . == 0) and
        (.quarantined_claims | type == "number" and floor == . and . == $quarantined)
    ' "$mining_file" >/dev/null
}

legacy_pow_state_matches_baseline()
{
    local mining_file="$1"
    case "$LEGACY_BASELINE_POW_MODE" in
        clean-hashing)
            jq -e --argjson live "$LEGACY_BASELINE_LIVE_CLAIMS" \
                --argjson quarantined "$LEGACY_BASELINE_QUARANTINED_CLAIMS" '
                type == "object" and
                (.enabled | type == "boolean" and . == true) and
                (.autostart | type == "boolean" and . == false) and
                (.allow_automatic_quantum_key_creation | type == "boolean" and . == false) and
                (.threads | type == "number" and floor == . and . == 1) and
                (.cpu_percent | type == "number" and . == 1) and
                (.hashrate | type == "number" and . > 0) and
                (.unresolved_claims | type == "number" and floor == . and . == 0) and
                (.live_claims | type == "number" and floor == . and . == $live) and
                (.quarantined_claims | type == "number" and floor == . and
                    . == $quarantined)
            ' "$mining_file" >/dev/null
            ;;
        quarantined-disabled)
            jq -e --argjson live "$LEGACY_BASELINE_LIVE_CLAIMS" \
                --argjson quarantined "$LEGACY_BASELINE_QUARANTINED_CLAIMS" '
                type == "object" and
                (.enabled | type == "boolean" and . == false) and
                (.autostart | type == "boolean" and . == false) and
                (.allow_automatic_quantum_key_creation | type == "boolean" and . == false) and
                (.state | type == "string" and . == "disabled") and
                (.threads | type == "number" and floor == . and . == 1) and
                (.cpu_percent | type == "number" and . == 1) and
                (.hashrate | type == "number" and . == 0) and
                (.unresolved_claims | type == "number" and floor == . and . == $quarantined) and
                (.live_claims | type == "number" and floor == . and . == $live) and
                (.quarantined_claims | type == "number" and floor == . and
                    . == $quarantined)
            ' "$mining_file" >/dev/null
            ;;
        *) return 1 ;;
    esac
}

pow_drain_is_clean()
{
    local version="$1" mining_file="$2"
    case "$version" in
        300103)
            jq -e '
                type == "object" and
                (.enabled | type == "boolean" and . == false) and
                (.live_claims | type == "number" and floor == . and . == 0) and
                (.quarantined_claims | type == "number" and floor == . and . == 0)
            ' "$mining_file" >/dev/null
            ;;
        300104)
            jq -e '
                type == "object" and
                (.enabled | type == "boolean" and . == false) and
                (.live_claims | type == "number" and floor == . and . == 0) and
                (.quarantined_claims | type == "number" and floor == . and . == 0) and
                (.blocking_quarantined_claims | type == "number" and floor == . and . == 0) and
                (.raw_quarantined_claims | type == "number" and floor == . and . >= 0) and
                (.claim_recovery_database_outcome_ambiguous | type == "boolean" and . == false)
            ' "$mining_file" >/dev/null
            ;;
        *) return 1 ;;
    esac
}

pow_drain_is_blocked()
{
    local version="$1" mining_file="$2"
    case "$version" in
        300103)
            jq -e '(.quarantined_claims | type == "number" and . > 0)' \
                "$mining_file" >/dev/null
            ;;
        300104)
            jq -e '
                (.blocking_quarantined_claims | type == "number" and . > 0) or
                (.claim_recovery_database_outcome_ambiguous == true)
            ' "$mining_file" >/dev/null
            ;;
        *) return 0 ;;
    esac
}

candidate_network_is_ready()
{
    local network_file="$1"
    jq -e '
        .version == 300104 and .subversion == "/Blackcoin:30.1.4/" and
        .networkactive == true and
        (.connections_out | type == "number" and floor == . and . >= 3)
    ' "$network_file" >/dev/null
}

replay_state_matches_chain()
{
    local chain_file="$1" goldrush_file="$2"
    jq -e -n --slurpfile chain "$chain_file" --slurpfile goldrush "$goldrush_file" '
        ($chain | length) == 1 and ($goldrush | length) == 1 and
        ($chain[0].chain == "main") and
        ($goldrush[0].height == $chain[0].blocks) and
        ($goldrush[0].bestblock == $chain[0].bestblockhash) and
        ($goldrush[0].replay_state.schema == 12) and
        ($goldrush[0].replay_state.required_for_tip == true) and
        ($goldrush[0].replay_state.present == true) and
        ($goldrush[0].replay_state.marker_valid == true) and
        ($goldrush[0].replay_state.valid_for_tip == true) and
        (($goldrush[0].replay_state.marker_height | type) == "number") and
        ($goldrush[0].replay_state.marker_height >= 0) and
        (($goldrush[0].replay_state.marker_time | type) == "number") and
        ($goldrush[0].replay_state.marker_time > 0) and
        (($goldrush[0].replay_state.marker_blockhash | type) == "string") and
        ($goldrush[0].replay_state.marker_blockhash | test("^[0-9a-f]{64}$")) and
        (($goldrush[0].replay_state.commitment | type) == "string") and
        ($goldrush[0].replay_state.commitment | test("^[0-9a-f]{64}$"))
    ' >/dev/null
}

automatic_wallet_features_are_off()
{
    local staking_file="$1" mining_file="$2"
    jq -e '
        .automatic_qqsignal == false and
        .automatic_demurrage_attestation == false and
        .automatic_redelegation == false and
        .allow_automatic_quantum_key_creation == false
    ' "$staking_file" >/dev/null &&
        jq -e '.allow_automatic_quantum_key_creation == false' \
            "$mining_file" >/dev/null
}

transaction_sets_match_exactly()
{
    local baseline_file="$1" candidate_file="$2" transaction_file
    for transaction_file in "$baseline_file" "$candidate_file"; do
        jq -e '
            type == "array" and
            all(.[]; type == "string" and test("^[0-9a-f]{64}$")) and
            . == (unique | sort)
        ' "$transaction_file" >/dev/null || return 1
    done
    cmp -s "$baseline_file" "$candidate_file"
}

locked_recovery_counter_is_safe()
{
    local wallet_file="$1" recovery_file="$2" staking_file="$3" mining_file="$4"
    jq -e '
        .private_keys_enabled == true and
        (.unlocked_until | type == "number" and . == 0)
    ' "$wallet_file" >/dev/null &&
        jq -e '
            .policy_authoritative == true and
            .policy.automatic_authorized == false and
            .database_outcome_ambiguous == false and
            .chain_ready == true and .wallet_tip_matches == true and
            .blocking_quarantined_claims == 0 and .blocking_components == 0 and
            .indeterminate_quarantined_claims == 0 and
            .pending_manual_resolutions == 0 and
            .pending_automatic_resolutions == 0 and
            (.confirmed_resolution_fees | type) == "number" and
            .confirmed_resolution_fees >= 0
        ' "$recovery_file" >/dev/null &&
        automatic_wallet_features_are_off "$staking_file" "$mining_file"
}

candidate_pow_is_strictly_stopped()
{
    local mining_file="$1"
    jq -e '
        type == "object" and .enabled == false and .autostart == false and
        .state == "disabled" and .threads == 1 and .cpu_percent == 1 and
        .hashrate == 0 and .unresolved_claims == 0 and .live_claims == 0 and
        .quarantined_claims == 0 and
        .blocking_quarantined_claims == 0 and
        .indeterminate_quarantined_claims == 0 and
        .claim_recovery_database_outcome_ambiguous == false and
        .allow_automatic_quantum_key_creation == false
    ' "$mining_file" >/dev/null
}

candidate_staking_is_strictly_stopped()
{
    local staking_file="$1"
    jq -e '
        .enabled == false and .staking == false and .worker_running == false and
        .staking_state == "disabled" and .automatic_qqsignal == false and
        .automatic_demurrage_attestation == false and
        .automatic_redelegation == false and
        .allow_automatic_quantum_key_creation == false
    ' "$staking_file" >/dev/null
}

extract_inherited_claim_inventory()
{
    local recovery_file="$1" transaction_file="$2" output_file="$3"
    jq -e -n --slurpfile recovery "$recovery_file" --slurpfile transactions "$transaction_file" '
        def hex64: type == "string" and test("^[0-9a-f]{64}$");
        def integer: type == "number" and floor == .;
        select(($recovery | length) == 1 and ($transactions | length) == 1 and
          ($transactions[0] | type == "array" and
            all(.[]; hex64) and . == (unique | sort))) |
        $recovery[0] as $r |
        select($r.policy_authoritative == true and
          $r.policy.automatic_authorized == false and
          $r.database_outcome_ambiguous == false and
          $r.chain_ready == true and $r.wallet_tip_matches == true and
          $r.blocking_quarantined_claims == 0 and $r.blocking_components == 0 and
          $r.indeterminate_quarantined_claims == 0 and
          $r.pending_manual_resolutions == 0 and $r.pending_automatic_resolutions == 0 and
          ($r.raw_claim_objects | integer and . > 0) and
          ($r.quarantined_claim_objects | integer and . > 0 and . <= $r.raw_claim_objects) and
          ($r.components | integer and . > 0) and
          ($r.resolved_components | integer and . == $r.components) and
          ($r.retired_components | integer and . == 0) and
          ($r.component_details | type == "array" and length == $r.components and all(.[];
            .classification == "resolved_on_active_chain" and
            .anchor_authenticated == true and .anchor_unspent == false and
            (.anchor.txid | hex64) and
            (.anchor.vout | integer and . >= 0) and
            (.generation_fingerprint | hex64) and
            (.claim_txids | type == "array" and length > 0 and all(.[]; hex64)) and
            (.root_claim_txids | type == "array" and length > 0 and all(.[]; hex64)) and
            (.resolution_txids | type == "array" and length == 0)))) |
        ([ $r.component_details[].claim_txids[] ] | unique | sort) as $claim_txids |
        select($claim_txids |
          all(. as $txid | $transactions[0] | index($txid) != null)) |
        {schema:1,classification:"resolved_on_active_chain",
         raw_claim_objects:$r.raw_claim_objects,
         quarantined_claim_objects:$r.quarantined_claim_objects,
         components:$r.components,resolved_components:$r.resolved_components,
         retired_components:$r.retired_components,
         claim_txids:$claim_txids,
         component_identities:([$r.component_details[] |
           {anchor,generation_fingerprint,
            claim_txids:(.claim_txids | unique | sort),
            root_claim_txids:(.root_claim_txids | unique | sort)}] |
           sort_by(.anchor.txid,.anchor.vout,.generation_fingerprint))}
    ' > "$output_file"
    jq -e 'type == "object" and .schema == 1 and .components > 0 and
        (.component_identities | type == "array") and
        (.component_identities | length) == .components and
        (.claim_txids | type == "array" and length > 0)' "$output_file" >/dev/null
}

inherited_claim_inventory_is_resolved()
{
    local recovery_file="$1" transaction_file="$2" inventory_file="$3" current
    current=$(mktemp "${OPS}/.candidate-inherited-inventory.XXXXXX") || return 1
    if ! extract_inherited_claim_inventory "$recovery_file" "$transaction_file" "$current" ||
       ! cmp -s "$inventory_file" "$current"; then
        rm -f -- "$current"
        return 1
    fi
    rm -f -- "$current"
}

candidate_claim_recovery_is_clean()
{
    local recovery_file="$1"
    jq -e --argjson fee "$BASELINE_RECOVERY_FEE" '
        type == "object" and .policy_authoritative == true and
        .policy.automatic_authorized == false and
        .database_outcome_ambiguous == false and .chain_ready == true and
        .wallet_tip_matches == true and .blocking_quarantined_claims == 0 and
        .blocking_components == 0 and .indeterminate_quarantined_claims == 0 and
        .pending_manual_resolutions == 0 and .pending_automatic_resolutions == 0 and
        (.confirmed_resolution_fees | type == "number" and . == $fee) and
        (.wallet_generation | type == "number" and floor == . and . >= 0)
    ' "$recovery_file" >/dev/null
}

candidate_claim_transition_is_valid()
{
    [[ "$#" == 5 ]] || return 1
    local transition_file="$1" observed_file="$2" normalized_file="$3"
    local transaction_file="$4" inventory_file="$5"
    local observed_sha normalized_sha transaction_sha inventory_sha=''
    observed_sha=$(sha256sum "$observed_file" | awk '{print $1}') || return 1
    normalized_sha=$(sha256sum "$normalized_file" | awk '{print $1}') || return 1
    transaction_sha=$(sha256sum "$transaction_file" | awk '{print $1}') || return 1
    candidate_claim_recovery_is_clean "$observed_file" || return 1
    candidate_claim_recovery_is_clean "$normalized_file" || return 1
    jq -e 'type == "array" and
        all(.[]; type == "string" and test("^[0-9a-f]{64}$")) and
        . == (unique | sort)' "$transaction_file" >/dev/null || return 1
    case "$LEGACY_BASELINE_POW_MODE" in
        clean-hashing)
            [[ -z "$inventory_file" ]] || return 1
            jq -e --arg observed_sha "$observed_sha" \
                --arg normalized_sha "$normalized_sha" \
                --arg transaction_sha "$transaction_sha" \
                --argjson fee "$BASELINE_RECOVERY_FEE" '
                . == {schema:1,legacy_mode:"clean-hashing",
                  legacy_q1_candidate_q0_no_payment_reclassification:false,
                  clean_q0_candidate_q0_no_payment_transition:true,
                  inherited_claim_inventory_sha256:null,
                  observed_recovery_sha256:$observed_sha,
                  normalized_recovery_sha256:$normalized_sha,
                  exact_transaction_set_sha256:$transaction_sha,
                  confirmed_resolution_fees:$fee,resolver_invoked:false,
                  payment_created:false}
            ' "$transition_file" >/dev/null
            ;;
        quarantined-disabled)
            [[ -n "$inventory_file" && -f "$inventory_file" && ! -L "$inventory_file" ]] ||
                return 1
            inventory_sha=$(sha256sum "$inventory_file" | awk '{print $1}') || return 1
            jq -e --arg inventory_sha "$inventory_sha" --arg observed_sha "$observed_sha" \
                --arg normalized_sha "$normalized_sha" \
                --arg transaction_sha "$transaction_sha" \
                --argjson fee "$BASELINE_RECOVERY_FEE" '
                . == {schema:1,legacy_mode:"quarantined-disabled",
                  legacy_q1_candidate_q0_no_payment_reclassification:true,
                  inherited_claim_inventory_sha256:$inventory_sha,
                  observed_recovery_sha256:$observed_sha,
                  normalized_recovery_sha256:$normalized_sha,
                  exact_transaction_set_sha256:$transaction_sha,
                  confirmed_resolution_fees:$fee,resolver_invoked:false,
                  payment_created:false}
            ' "$transition_file" >/dev/null
            ;;
        *) return 1 ;;
    esac
}

candidate_claim_result_mode_is_valid()
{
    local result_file="$1"
    jq -e '
        .legacy_baseline_live_claims == 0 and
        .restored_legacy_live_claims == .legacy_baseline_live_claims and
        .restored_legacy_quarantined_claims == .legacy_baseline_quarantined_claims and
        .legacy_quarantined_claim_count_preserved == true and
        .legacy_quarantined_claim_resolution_attempted == false and
        .legacy_quarantined_claim_fee_paid == false and
        .inherited_claim_transition_evidence ==
          "candidate-inherited-claim-transition.json" and
        (.inherited_claim_transition_sha256 | type == "string" and
          test("^[0-9a-f]{64}$")) and
        (if .legacy_baseline_pow_mode == "clean-hashing" then
           .legacy_observed_pow_mode == "clean-hashing" and
           .legacy_baseline_quarantined_claims == 0 and
           .inherited_claim_inventory_present == false and
           .inherited_claim_inventory_evidence == null and
           .inherited_claim_inventory_sha256 == null and
           .claim_baseline_transition_kind ==
             "clean_q0_to_candidate_q0_no_payment" and
           .legacy_q1_candidate_q0_no_payment_reclassification_verified == false and
           .clean_q0_candidate_q0_no_payment_transition_verified == true
         elif .legacy_baseline_pow_mode == "quarantined-disabled" then
           (.legacy_observed_pow_mode == "quarantined-disabled" or
             .legacy_observed_pow_mode == "quarantined-stalled") and
           .legacy_baseline_quarantined_claims == 1 and
           .inherited_claim_inventory_present == true and
           .inherited_claim_inventory_evidence ==
             "candidate-inherited-claim-inventory.json" and
           (.inherited_claim_inventory_sha256 | type == "string" and
             test("^[0-9a-f]{64}$")) and
           .claim_baseline_transition_kind ==
             "legacy_q1_to_candidate_q0_no_payment" and
           .legacy_q1_candidate_q0_no_payment_reclassification_verified == true and
           .clean_q0_candidate_q0_no_payment_transition_verified == false
         else false end)
    ' "$result_file" >/dev/null
}

normalize_candidate_claim_state()
{
    local attempt initial recovery pow wallet staking txids transition_tmp inventory_file=''
    initial="${EVIDENCE}/candidate-inherited-recovery-observed.json"
    rpc setpowmining false 1 1 false >"${EVIDENCE}/candidate-inherited-pow-stop.json" ||
        return 1
    for attempt in $(seq 1 240); do
        recovery="${EVIDENCE}/candidate-inherited-recovery-${attempt}.json"
        wallet="${EVIDENCE}/candidate-inherited-wallet-${attempt}.json"
        staking="${EVIDENCE}/candidate-inherited-staking-${attempt}.json"
        pow="${EVIDENCE}/candidate-inherited-pow-${attempt}.json"
        txids="${EVIDENCE}/candidate-inherited-transaction-txids-${attempt}.json"
        rpc getpowclaimrecoveryinfo true >"$recovery" || return 1
        rpc getwalletinfo >"$wallet" || return 1
        rpc getstakinginfo >"$staking" || return 1
        rpc getpowmininginfo >"$pow" || return 1
        rpc listtransactions '*' 1000000 0 true | jq -S '[.[].txid] | unique | sort' >"$txids" ||
            return 1
        jq -e '.private_keys_enabled == true and .unlocked_until == 0' "$wallet" >/dev/null ||
            return 1
        candidate_staking_is_strictly_stopped "$staking" || return 1
        automatic_wallet_features_are_off "$staking" "$pow" || return 1
        transaction_sets_match_exactly "${EVIDENCE}/prelaunch-transaction-txids.json" "$txids" ||
            return 1
        jq -e '.policy_authoritative == true and
            .policy.automatic_authorized == false and
            .database_outcome_ambiguous == false and .chain_ready == true and
            .wallet_tip_matches == true and .pending_manual_resolutions == 0 and
            .pending_automatic_resolutions == 0' "$recovery" >/dev/null || {
            sleep 5
            continue
        }
        if [[ ! -s "$initial" ]]; then
            install -m 600 -o root -g root "$recovery" "$initial" || return 1
            BASELINE_RECOVERY_FEE=$(jq -er '.confirmed_resolution_fees' "$initial") || return 1
            jq -S '{pending_manual_resolutions,pending_automatic_resolutions,
                confirmed_manual_resolutions,confirmed_automatic_resolutions,
                confirmed_resolution_fees,automatic_actions_in_window,
                automatic_fee_exposure_in_window,reconciled_descendant_claims,claims_recycled}' \
                "$initial" >"${EVIDENCE}/candidate-inherited-accounting-baseline.json" || return 1
            if [[ "$LEGACY_BASELINE_POW_MODE" == quarantined-disabled ]]; then
                extract_inherited_claim_inventory "$initial" "$txids" \
                    "${EVIDENCE}/candidate-inherited-claim-inventory.json" || return 1
                inventory_file="${EVIDENCE}/candidate-inherited-claim-inventory.json"
                INHERITED_CLAIM_INVENTORY_SHA=$(sha256sum \
                    "${EVIDENCE}/candidate-inherited-claim-inventory.json" | awk '{print $1}') ||
                    return 1
            else
                [[ ! -e "${EVIDENCE}/candidate-inherited-claim-inventory.json" &&
                   ! -L "${EVIDENCE}/candidate-inherited-claim-inventory.json" ]] || return 1
            fi
        fi
        [[ "$(jq -er '.confirmed_resolution_fees' "$recovery")" == "$BASELINE_RECOVERY_FEE" ]] ||
            return 1
        jq -S '{pending_manual_resolutions,pending_automatic_resolutions,
            confirmed_manual_resolutions,confirmed_automatic_resolutions,
            confirmed_resolution_fees,automatic_actions_in_window,
            automatic_fee_exposure_in_window,reconciled_descendant_claims,claims_recycled}' \
            "$recovery" >"${EVIDENCE}/candidate-inherited-accounting-current.json" || return 1
        cmp -s "${EVIDENCE}/candidate-inherited-accounting-baseline.json" \
            "${EVIDENCE}/candidate-inherited-accounting-current.json" || return 1
        if candidate_pow_is_strictly_stopped "$pow" &&
           { [[ "$LEGACY_BASELINE_POW_MODE" == clean-hashing ]] ||
             inherited_claim_inventory_is_resolved "$recovery" "$txids" \
                 "${EVIDENCE}/candidate-inherited-claim-inventory.json"; }; then
            install -m 600 -o root -g root "$recovery" \
                "${EVIDENCE}/candidate-inherited-recovery-normalized.json" || return 1
            install -m 600 -o root -g root "$pow" \
                "${EVIDENCE}/candidate-inherited-pow-normalized.json" || return 1
            install -m 600 -o root -g root "$txids" \
                "${EVIDENCE}/candidate-inherited-transaction-txids-normalized.json" || return 1
            LOCKED_CANDIDATE_TRANSACTION_SET_SHA=$(sha256sum \
                "${EVIDENCE}/candidate-inherited-transaction-txids-normalized.json" | awk '{print $1}') ||
                return 1
            [[ "$LOCKED_CANDIDATE_TRANSACTION_SET_SHA" == "$PRELAUNCH_TRANSACTION_SET_SHA" ]] ||
                return 1
            transition_tmp=$(mktemp "${OPS}/.candidate-inherited-transition.XXXXXX") || return 1
            if [[ "$LEGACY_BASELINE_POW_MODE" == quarantined-disabled ]]; then
                jq -n --arg inventory_sha "$INHERITED_CLAIM_INVENTORY_SHA" \
                    --arg observed_sha "$(sha256sum "$initial" | awk '{print $1}')" \
                    --arg normalized_sha "$(sha256sum "${EVIDENCE}/candidate-inherited-recovery-normalized.json" | awk '{print $1}')" \
                    --arg txids_sha "$LOCKED_CANDIDATE_TRANSACTION_SET_SHA" \
                    --argjson fee "$BASELINE_RECOVERY_FEE" \
                    '{schema:1,legacy_mode:"quarantined-disabled",
                      legacy_q1_candidate_q0_no_payment_reclassification:true,
                      inherited_claim_inventory_sha256:$inventory_sha,
                      observed_recovery_sha256:$observed_sha,
                      normalized_recovery_sha256:$normalized_sha,
                      exact_transaction_set_sha256:$txids_sha,
                      confirmed_resolution_fees:$fee,resolver_invoked:false,
                      payment_created:false}' >"$transition_tmp" || return 1
            else
                jq -n --arg observed_sha "$(sha256sum "$initial" | awk '{print $1}')" \
                    --arg normalized_sha "$(sha256sum "${EVIDENCE}/candidate-inherited-recovery-normalized.json" | awk '{print $1}')" \
                    --arg txids_sha "$LOCKED_CANDIDATE_TRANSACTION_SET_SHA" \
                    --argjson fee "$BASELINE_RECOVERY_FEE" \
                    '{schema:1,legacy_mode:"clean-hashing",
                      legacy_q1_candidate_q0_no_payment_reclassification:false,
                      clean_q0_candidate_q0_no_payment_transition:true,
                      inherited_claim_inventory_sha256:null,
                      observed_recovery_sha256:$observed_sha,
                      normalized_recovery_sha256:$normalized_sha,
                      exact_transaction_set_sha256:$txids_sha,
                      confirmed_resolution_fees:$fee,resolver_invoked:false,
                      payment_created:false}' >"$transition_tmp" || return 1
            fi
            chmod 600 "$transition_tmp" && chown root:root "$transition_tmp" &&
                sync -f "$transition_tmp" || return 1
            mv -fT -- "$transition_tmp" "${EVIDENCE}/candidate-inherited-claim-transition.json" ||
                return 1
            sync -f "${EVIDENCE}/candidate-inherited-claim-transition.json" || return 1
            sync -f "$EVIDENCE" || return 1
            candidate_claim_transition_is_valid \
                "${EVIDENCE}/candidate-inherited-claim-transition.json" "$initial" \
                "${EVIDENCE}/candidate-inherited-recovery-normalized.json" \
                "${EVIDENCE}/candidate-inherited-transaction-txids-normalized.json" \
                "$inventory_file" || return 1
            INHERITED_CLAIM_TRANSITION_SHA=$(sha256sum \
                "${EVIDENCE}/candidate-inherited-claim-transition.json" | awk '{print $1}') ||
                return 1
            LAST_CONFIRMED_RECOVERY_FEE=$BASELINE_RECOVERY_FEE
            return 0
        fi
        sleep 5
    done
    echo 'baseline PoW claim state did not normalize to exact candidate q0 without payment within 20 minutes' >&2
    return 1
}

container_is_authoritatively_absent()
{
    local names
    docker info >/dev/null 2>&1 || return 1
    names=$(docker ps -a --format '{{.Names}}') || return 1
    ! grep -Fqx -- "$CONTAINER" <<<"$names"
}

container_runtime_kind()
{
    local inspect image image_id invocation
    inspect=$(docker inspect "$CONTAINER" 2>/dev/null) || {
        if container_is_authoritatively_absent; then
            printf '%s\n' absent
        else
            printf '%s\n' unknown
        fi
        return 0
    }
    image=$(jq -er '.[0].Config.Image' <<<"$inspect") || return 1
    image_id=$(jq -er '.[0].Image' <<<"$inspect") || return 1
    invocation=$(mktemp "${OPS}/.container-runtime-invocation.XXXXXX") || return 1
    jq -S '.[0] | {path:.Path,args:.Args,entrypoint:.Config.Entrypoint,
        cmd:.Config.Cmd}' <<<"$inspect" >"$invocation" || return 1
    if [[ "$image" == "$ORIGINAL_IMAGE" && "$image_id" == "$ORIGINAL_IMAGE_ID" ]] &&
       cmp -s "$invocation" "${EVIDENCE}/baseline-invocation.json"; then
        rm -f -- "$invocation"
        printf '%s\n' original
        return 0
    fi
    if [[ "$image" == "$CANDIDATE_IMAGE" && "$image_id" == "$CANDIDATE_IMAGE_ID" ]] &&
       cmp -s "$invocation" "${EVIDENCE}/baseline-invocation.json"; then
        rm -f -- "$invocation"
        printf '%s\n' candidate
        return 0
    fi
    rm -f -- "$invocation"
    printf '%s\n' unknown
}

candidate_activation_marker_path()
{
    case "$1" in
        1) printf '%s\n' "$CANDIDATE_ACTIVATION_MARKER_1" ;;
        2) printf '%s\n' "$CANDIDATE_ACTIVATION_MARKER_2" ;;
        *) return 1 ;;
    esac
}

candidate_safe_marker_path()
{
    case "$1" in
        1) printf '%s\n' "$CANDIDATE_SAFE_MARKER_1" ;;
        2) printf '%s\n' "$CANDIDATE_SAFE_MARKER_2" ;;
        *) return 1 ;;
    esac
}

publish_candidate_activation_marker()
{
    local sequence="$1" purpose="$2" marker temporary wallet staking pow recovery txids marker_sha
    [[ "$sequence" == 1 || "$sequence" == 2 ]] || return 1
    [[ "$ACTIVATION_SEQUENCE" == $((sequence - 1)) ]] || return 1
    if [[ "$sequence" == 2 ]]; then
        [[ "$SAFE_SEQUENCE" == 1 ]] && validate_candidate_safe_marker 1 || return 1
    fi
    marker=$(candidate_activation_marker_path "$sequence") || return 1
    [[ ! -e "$marker" && ! -L "$marker" ]] || return 1
    validate_canary_maintenance_marker || return 1
    [[ "$(container_runtime_kind)" == candidate ]] || return 1
    [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)" == true ]] ||
        return 1
    wallet="${EVIDENCE}/candidate-activation-${sequence}-wallet-locked.json"
    staking="${EVIDENCE}/candidate-activation-${sequence}-staking-disabled.json"
    pow="${EVIDENCE}/candidate-activation-${sequence}-pow-disabled.json"
    recovery="${EVIDENCE}/candidate-activation-${sequence}-recovery-clean.json"
    txids="${EVIDENCE}/candidate-activation-${sequence}-transaction-txids.json"
    rpc getwalletinfo >"$wallet" || return 1
    rpc getstakinginfo >"$staking" || return 1
    rpc getpowmininginfo >"$pow" || return 1
    rpc getpowclaimrecoveryinfo true >"$recovery" || return 1
    rpc listtransactions '*' 1000000 0 true | jq -S '[.[].txid] | unique | sort' >"$txids" ||
        return 1
    jq -e '.private_keys_enabled == true and .unlocked_until == 0' "$wallet" >/dev/null ||
        return 1
    candidate_staking_is_strictly_stopped "$staking" || return 1
    candidate_pow_is_strictly_stopped "$pow" || return 1
    locked_recovery_counter_is_safe "$wallet" "$recovery" "$staking" "$pow" || return 1
    [[ "$(jq -er '.confirmed_resolution_fees' "$recovery")" == "$BASELINE_RECOVERY_FEE" ]] ||
        return 1
    transaction_sets_match_exactly "${EVIDENCE}/prelaunch-transaction-txids.json" "$txids" ||
        return 1
    if [[ "$LEGACY_BASELINE_POW_MODE" == quarantined-disabled ]]; then
        inherited_claim_inventory_is_resolved "$recovery" "$txids" \
            "${EVIDENCE}/candidate-inherited-claim-inventory.json" || return 1
    fi
    temporary=$(mktemp "${OPS}/.candidate-activation-${sequence}.XXXXXX") || return 1
    jq -n --argjson sequence "$sequence" --arg purpose "$purpose" \
        --arg image "$CANDIDATE_IMAGE" --arg image_id "$CANDIDATE_IMAGE_ID" \
        --arg launch_sha "$CANDIDATE_LAUNCH_MARKER_SHA" \
        --arg nonce_sha "$MAINTENANCE_NONCE_SHA" \
        --arg txids_sha "$(sha256sum "$txids" | awk '{print $1}')" \
        --arg recovery_sha "$(sha256sum "$recovery" | awk '{print $1}')" \
        --arg pow_sha "$(sha256sum "$pow" | awk '{print $1}')" \
        --arg staking_sha "$(sha256sum "$staking" | awk '{print $1}')" \
        --arg wallet_sha "$(sha256sum "$wallet" | awk '{print $1}')" \
        --arg inherited_transition_sha "$INHERITED_CLAIM_TRANSITION_SHA" \
        --argjson fee "$BASELINE_RECOVERY_FEE" --arg timestamp "$(date -u +%FT%TZ)" '
        {schema:1,sequence:$sequence,purpose:$purpose,
         signing_authority_may_have_been_granted:true,
         candidate_image:$image,candidate_image_id:$image_id,
         candidate_launch_marker_sha256:$launch_sha,
         maintenance_nonce_sha256:$nonce_sha,
         exact_transaction_set_sha256:$txids_sha,
         recovery_evidence_sha256:$recovery_sha,pow_evidence_sha256:$pow_sha,
         staking_evidence_sha256:$staking_sha,wallet_evidence_sha256:$wallet_sha,
         inherited_claim_transition_sha256:$inherited_transition_sha,
         confirmed_resolution_fees:$fee,timestamp:$timestamp}
    ' >"$temporary" || return 1
    chmod 600 "$temporary" && chown root:root "$temporary" && sync -f "$temporary" || return 1
    mv -fT -- "$temporary" "$marker" || return 1
    sync -f "$marker" && sync -f "$EVIDENCE" || return 1
    marker_sha=$(sha256sum "$marker" | awk '{print $1}') || return 1
    [[ "$marker_sha" =~ ^[0-9a-f]{64}$ ]] || return 1
    if [[ "$sequence" == 1 ]]; then
        CANDIDATE_ACTIVATION_MARKER_1_SHA=$marker_sha
    else
        CANDIDATE_ACTIVATION_MARKER_2_SHA=$marker_sha
    fi
    ACTIVATION_SEQUENCE=$sequence
}

validate_candidate_safe_marker()
{
    local sequence="$1" marker activation_marker expected_sha activation_sha
    local wallet staking pow recovery txids wallet_generation evidence_file
    marker=$(candidate_safe_marker_path "$sequence") || return 1
    activation_marker=$(candidate_activation_marker_path "$sequence") || return 1
    if [[ "$sequence" == 1 ]]; then
        expected_sha=$CANDIDATE_SAFE_MARKER_1_SHA
        activation_sha=$CANDIDATE_ACTIVATION_MARKER_1_SHA
    else
        expected_sha=$CANDIDATE_SAFE_MARKER_2_SHA
        activation_sha=$CANDIDATE_ACTIVATION_MARKER_2_SHA
    fi
    protected_root_file_0600 "$marker" || return 1
    [[ "$expected_sha" =~ ^[0-9a-f]{64}$ && "$activation_sha" =~ ^[0-9a-f]{64}$ &&
       "$(sha256sum "$marker" | awk '{print $1}')" == "$expected_sha" ]] || return 1
    wallet="${EVIDENCE}/candidate-safe-${sequence}-wallet-2.json"
    staking="${EVIDENCE}/candidate-safe-${sequence}-staking-2.json"
    pow="${EVIDENCE}/candidate-safe-${sequence}-pow-2.json"
    recovery="${EVIDENCE}/candidate-safe-${sequence}-recovery-2.json"
    txids="${EVIDENCE}/candidate-safe-${sequence}-transaction-txids-2.json"
    for evidence_file in "$wallet" "$staking" "$pow" "$recovery" "$txids"; do
        protected_root_file_0600 "$evidence_file" || return 1
    done
    wallet_generation=$(jq -er '.wallet_generation |
        select(type == "number" and floor == . and . >= 0)' "$recovery") || return 1
    jq -e '.private_keys_enabled == true and .unlocked_until == 0' "$wallet" >/dev/null ||
        return 1
    candidate_staking_is_strictly_stopped "$staking" || return 1
    candidate_pow_is_strictly_stopped "$pow" || return 1
    locked_recovery_counter_is_safe "$wallet" "$recovery" "$staking" "$pow" || return 1
    transaction_sets_match_exactly "${EVIDENCE}/prelaunch-transaction-txids.json" "$txids" ||
        return 1
    jq -e --argjson sequence "$sequence" --arg activation_sha "$activation_sha" \
        --arg image "$CANDIDATE_IMAGE" --arg image_id "$CANDIDATE_IMAGE_ID" \
        --arg txids_sha "$PRELAUNCH_TRANSACTION_SET_SHA" --argjson fee "$BASELINE_RECOVERY_FEE" \
        --argjson wallet_generation "$wallet_generation" \
        --arg wallet_sha "$(sha256sum "$wallet" | awk '{print $1}')" \
        --arg staking_sha "$(sha256sum "$staking" | awk '{print $1}')" \
        --arg pow_sha "$(sha256sum "$pow" | awk '{print $1}')" \
        --arg recovery_sha "$(sha256sum "$recovery" | awk '{print $1}')" '
        .schema == 1 and .sequence == $sequence and .safe_to_stop_or_rollback == true and
        .candidate_image == $image and .candidate_image_id == $image_id and
        .activation_marker_sha256 == $activation_sha and
        .exact_transaction_set_sha256 == $txids_sha and
        .confirmed_resolution_fees == $fee and .staking_disabled == true and
        .pow_disabled == true and .wallet_locked == true and .claim_gate_q0 == true and
        .wallet_generation == $wallet_generation and
        .wallet_evidence_sha256 == $wallet_sha and
        .staking_evidence_sha256 == $staking_sha and .pow_evidence_sha256 == $pow_sha and
        .recovery_evidence_sha256 == $recovery_sha
    ' "$marker" >/dev/null
}

quiesce_candidate_and_publish_safe()
{
    local sequence="$1" purpose="$2" marker activation_marker activation_sha
    local wallet staking pow recovery txids wallet2 staking2 pow2 recovery2 txids2 temporary marker_sha
    [[ "$sequence" == "$ACTIVATION_SEQUENCE" && "$SAFE_SEQUENCE" == $((sequence - 1)) ]] ||
        return 1
    [[ "$(container_runtime_kind)" == candidate ]] || return 1
    [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)" == true ]] ||
        return 1
    rpc staking false >"${EVIDENCE}/candidate-safe-${sequence}-staking-stop.json" || return 1
    rpc setpowmining false 1 1 false >"${EVIDENCE}/candidate-safe-${sequence}-pow-stop.json" ||
        return 1
    rpc walletlock >"${EVIDENCE}/candidate-safe-${sequence}-wallet-lock.json" || return 1
    stop_and_drain_candidate_pow || return 1
    require_claim_recovery_clean "candidate-safe-${sequence}" || return 1
    wallet="${EVIDENCE}/candidate-safe-${sequence}-wallet-1.json"
    staking="${EVIDENCE}/candidate-safe-${sequence}-staking-1.json"
    pow="${EVIDENCE}/candidate-safe-${sequence}-pow-1.json"
    recovery="${EVIDENCE}/candidate-safe-${sequence}-recovery-1.json"
    txids="${EVIDENCE}/candidate-safe-${sequence}-transaction-txids-1.json"
    wallet2="${EVIDENCE}/candidate-safe-${sequence}-wallet-2.json"
    staking2="${EVIDENCE}/candidate-safe-${sequence}-staking-2.json"
    pow2="${EVIDENCE}/candidate-safe-${sequence}-pow-2.json"
    recovery2="${EVIDENCE}/candidate-safe-${sequence}-recovery-2.json"
    txids2="${EVIDENCE}/candidate-safe-${sequence}-transaction-txids-2.json"
    for attempt in 1 2; do
        if [[ "$attempt" == 1 ]]; then
            local w="$wallet" s="$staking" p="$pow" r="$recovery" t="$txids"
        else
            sleep 2
            local w="$wallet2" s="$staking2" p="$pow2" r="$recovery2" t="$txids2"
        fi
        rpc getwalletinfo >"$w" || return 1
        rpc getstakinginfo >"$s" || return 1
        rpc getpowmininginfo >"$p" || return 1
        rpc getpowclaimrecoveryinfo true >"$r" || return 1
        rpc listtransactions '*' 1000000 0 true | jq -S '[.[].txid] | unique | sort' >"$t" ||
            return 1
        jq -e '.private_keys_enabled == true and .unlocked_until == 0' "$w" >/dev/null ||
            return 1
        candidate_staking_is_strictly_stopped "$s" || return 1
        candidate_pow_is_strictly_stopped "$p" || return 1
        locked_recovery_counter_is_safe "$w" "$r" "$s" "$p" || return 1
        [[ "$(jq -er '.confirmed_resolution_fees' "$r")" == "$BASELINE_RECOVERY_FEE" ]] ||
            return 1
        transaction_sets_match_exactly "${EVIDENCE}/prelaunch-transaction-txids.json" "$t" ||
            return 1
        if [[ "$LEGACY_BASELINE_POW_MODE" == quarantined-disabled ]]; then
            inherited_claim_inventory_is_resolved "$r" "$t" \
                "${EVIDENCE}/candidate-inherited-claim-inventory.json" || return 1
        fi
    done
    cmp -s "$txids" "$txids2" || return 1
    [[ "$(jq -er '.confirmed_resolution_fees' "$recovery")" == \
       "$(jq -er '.confirmed_resolution_fees' "$recovery2")" ]] || return 1
    [[ "$(jq -er '.wallet_generation | select(type == "number" and floor == . and . >= 0)' \
        "$recovery")" == "$(jq -er '.wallet_generation | select(type == "number" and floor == . and . >= 0)' \
        "$recovery2")" ]] || return 1
    marker=$(candidate_safe_marker_path "$sequence") || return 1
    activation_marker=$(candidate_activation_marker_path "$sequence") || return 1
    [[ ! -e "$marker" && ! -L "$marker" ]] || return 1
    if [[ "$sequence" == 1 ]]; then
        activation_sha=$CANDIDATE_ACTIVATION_MARKER_1_SHA
    else
        activation_sha=$CANDIDATE_ACTIVATION_MARKER_2_SHA
    fi
    [[ "$(sha256sum "$activation_marker" | awk '{print $1}')" == "$activation_sha" ]] || return 1
    temporary=$(mktemp "${OPS}/.candidate-safe-${sequence}.XXXXXX") || return 1
    jq -n --argjson sequence "$sequence" --arg purpose "$purpose" \
        --arg image "$CANDIDATE_IMAGE" --arg image_id "$CANDIDATE_IMAGE_ID" \
        --arg activation_sha "$activation_sha" --arg txids_sha "$PRELAUNCH_TRANSACTION_SET_SHA" \
        --arg wallet_sha "$(sha256sum "$wallet2" | awk '{print $1}')" \
        --arg staking_sha "$(sha256sum "$staking2" | awk '{print $1}')" \
        --arg pow_sha "$(sha256sum "$pow2" | awk '{print $1}')" \
        --arg recovery_sha "$(sha256sum "$recovery2" | awk '{print $1}')" \
        --argjson wallet_generation "$(jq -er '.wallet_generation' "$recovery2")" \
        --argjson fee "$BASELINE_RECOVERY_FEE" --arg timestamp "$(date -u +%FT%TZ)" '
        {schema:1,sequence:$sequence,purpose:$purpose,safe_to_stop_or_rollback:true,
         candidate_image:$image,candidate_image_id:$image_id,
         activation_marker_sha256:$activation_sha,
         exact_transaction_set_sha256:$txids_sha,
         wallet_evidence_sha256:$wallet_sha,staking_evidence_sha256:$staking_sha,
         pow_evidence_sha256:$pow_sha,recovery_evidence_sha256:$recovery_sha,
         confirmed_resolution_fees:$fee,staking_disabled:true,pow_disabled:true,
         wallet_locked:true,claim_gate_q0:true,wallet_generation:$wallet_generation,
         timestamp:$timestamp}
    ' >"$temporary" || return 1
    chmod 600 "$temporary" && chown root:root "$temporary" && sync -f "$temporary" || return 1
    mv -fT -- "$temporary" "$marker" || return 1
    sync -f "$marker" && sync -f "$EVIDENCE" || return 1
    marker_sha=$(sha256sum "$marker" | awk '{print $1}') || return 1
    [[ "$marker_sha" =~ ^[0-9a-f]{64}$ ]] || return 1
    if [[ "$sequence" == 1 ]]; then
        CANDIDATE_SAFE_MARKER_1_SHA=$marker_sha
    else
        CANDIDATE_SAFE_MARKER_2_SHA=$marker_sha
    fi
    SAFE_SEQUENCE=$sequence
    validate_candidate_safe_marker "$sequence"
}

restored_runtime_is_ready()
{
    local chain_file="$1" mining_file="$2"
    jq -e '
        .chain == "main" and .initialblockdownload == false and
        (.headers | type == "number" and floor == .) and
        (.blocks | type == "number" and floor == .) and
        .headers >= .blocks and (.headers - .blocks) <= 2
    ' "$chain_file" >/dev/null &&
        legacy_pow_state_matches_baseline "$mining_file"
}

wait_restored_runtime_gate()
{
    local attempt chain mining
    for attempt in $(seq 1 240); do
        chain="${EVIDENCE}/restored-runtime-blockchain-${attempt}.json"
        mining="${EVIDENCE}/restored-runtime-pow-${attempt}.json"
        if ! rpc getblockchaininfo >"$chain" || ! rpc getpowmininginfo >"$mining"; then
            sleep 5
            continue
        fi
        if restored_runtime_is_ready "$chain" "$mining"; then
            install -m 600 -o root -g root "$chain" "${EVIDENCE}/restored-blockchain.json" ||
                return 1
            install -m 600 -o root -g root "$mining" "${EVIDENCE}/restored-pow.json" ||
                return 1
            RESTORED_LEGACY_LIVE_CLAIMS=$(jq -er '.live_claims' "$mining") || return 1
            RESTORED_LEGACY_QUARANTINED_CLAIMS=$(jq -er '.quarantined_claims' "$mining") ||
                return 1
            return 0
        fi
        sleep 5
    done
    echo 'restored 30.1.3 chain and baseline PoW state did not converge within 20 minutes' >&2
    return 1
}

stop_and_drain_candidate_pow()
{
    local attempt mining network version drain_id
    POW_DRAIN_SEQUENCE=$((POW_DRAIN_SEQUENCE + 1))
    drain_id=$(printf '%02d' "$POW_DRAIN_SEQUENCE")
    network="${EVIDENCE}/pow-drain-${drain_id}-network.json"
    rpc getnetworkinfo > "$network" || {
        echo 'cannot identify node version before PoW drain' >&2
        return 1
    }
    version=$(jq -er '.version | select(. == 300103 or . == 300104)' "$network") || {
        echo 'PoW drain refuses an unrecognized node version' >&2
        return 1
    }
    rpc setpowmining false >"${EVIDENCE}/pow-drain-${drain_id}-stop.json" || {
        echo 'candidate PoW stop RPC failed' >&2
        return 1
    }
    for attempt in $(seq 1 240); do
        mining="${EVIDENCE}/pow-drain-${drain_id}-status-${attempt}.json"
        rpc getpowmininginfo >"$mining" || {
            echo 'candidate PoW drain status RPC failed' >&2
            return 1
        }
        if pow_drain_is_clean "$version" "$mining"; then
            return 0
        fi
        if pow_drain_is_blocked "$version" "$mining"; then
            echo 'blocking claims appeared; no-spend canary refuses fee-paying resolution' >&2
            return 1
        fi
        sleep 5
    done
    echo 'candidate PoW claims did not drain within 20 minutes' >&2
    return 1
}

assert_container_cleanly_stopped()
{
    docker inspect "$CONTAINER" | jq -e 'length == 1 and
        .[0].State.Running == false and .[0].State.ExitCode == 0 and
        .[0].State.OOMKilled == false and .[0].State.Error == ""' >/dev/null
}

enumerate_canary_snapshots()
{
    local dataset
    for dataset in "${SNAPSHOT_DATASETS[@]}"; do
        zfs list -H -r -t snapshot -o name "$dataset" |
            awk -v suffix="@${SNAP}" '
                length($0) >= length(suffix) &&
                substr($0, length($0) - length(suffix) + 1) == suffix {print}
            '
    done | sort -u
}

snapshot_hold_present()
{
    local snapshot="$1"
    zfs holds -H "$snapshot" 2>/dev/null |
        awk -v tag="$ZFS_HOLD_TAG" '$2 == tag {found=1} END {exit !found}'
}

capture_snapshot_inventory()
{
    local dataset snapshot guid createtxg
    local names_tmp identities_tmp roots_tmp expected_tmp
    names_tmp=$(mktemp "${OPS}/.zfs-snapshot-names.XXXXXX") || return 1
    identities_tmp=$(mktemp "${OPS}/.zfs-snapshot-identities.XXXXXX") || return 1
    roots_tmp=$(mktemp "${OPS}/.zfs-snapshot-roots.XXXXXX") || return 1
    expected_tmp=$(mktemp "${OPS}/.zfs-expected-snapshots.XXXXXX") || return 1

    printf '%s\n' "${SNAPSHOT_DATASETS[@]}" > "$roots_tmp"
    for dataset in "${SNAPSHOT_DATASETS[@]}"; do
        zfs snapshot -r "${dataset}@${SNAP}" || return 1
    done
    enumerate_canary_snapshots > "$names_tmp" || return 1
    [[ -s "$names_tmp" ]] || return 1
    printf '%s\n' \
        "${EXPECTED_DATADIR_DATASET}@${SNAP}" \
        "${EXPECTED_BLOCKS_DATASET}@${SNAP}" \
        "${EXPECTED_INDEXES_DATASET}@${SNAP}" \
        "${EXPECTED_RAW_DATASET}@${SNAP}" | sort -u > "$expected_tmp"
    cmp -s "$expected_tmp" "$names_tmp" || {
        echo 'node-27 recursive snapshot names differ from the exact pinned topology' >&2
        return 1
    }
    SNAPSHOT_COUNT=$(wc -l < "$names_tmp" | awk '{print $1}') || return 1
    [[ "$SNAPSHOT_COUNT" == 4 ]] || {
        echo "unexpected node-27 recursive snapshot count: $SNAPSHOT_COUNT" >&2
        return 1
    }

    : > "$identities_tmp"
    while IFS= read -r snapshot; do
        [[ -n "$snapshot" ]] || return 1
        guid=$(zfs get -Hp -o value guid "$snapshot") || return 1
        createtxg=$(zfs get -Hp -o value createtxg "$snapshot") || return 1
        [[ "$guid" =~ ^[0-9]+$ && "$createtxg" =~ ^[0-9]+$ ]] || return 1
        zfs hold "$ZFS_HOLD_TAG" "$snapshot" || return 1
        snapshot_hold_present "$snapshot" || return 1
        printf '%s\t%s\t%s\t%s\n' "$snapshot" "$guid" "$createtxg" "$ZFS_HOLD_TAG" >> "$identities_tmp"
    done < "$names_tmp"

    mv -fT -- "$roots_tmp" "${EVIDENCE}/zfs-snapshot-roots.txt"
    mv -fT -- "$names_tmp" "${EVIDENCE}/zfs-snapshots.txt"
    mv -fT -- "$identities_tmp" "${EVIDENCE}/zfs-snapshot-identities.tsv"
    rm -f -- "$expected_tmp"
    chmod 600 "${EVIDENCE}/zfs-snapshot-roots.txt" "${EVIDENCE}/zfs-snapshots.txt" \
        "${EVIDENCE}/zfs-snapshot-identities.tsv"
    chown root:root "${EVIDENCE}/zfs-snapshot-roots.txt" "${EVIDENCE}/zfs-snapshots.txt" \
        "${EVIDENCE}/zfs-snapshot-identities.tsv"
    SNAPSHOT_IDENTITY_SHA=$(sha256sum "${EVIDENCE}/zfs-snapshot-identities.tsv" | awk '{print $1}')
    [[ "$SNAPSHOT_IDENTITY_SHA" =~ ^[0-9a-f]{64}$ ]] || return 1
    sync -f "${EVIDENCE}/zfs-snapshot-roots.txt" || return 1
    sync -f "${EVIDENCE}/zfs-snapshots.txt" || return 1
    sync -f "${EVIDENCE}/zfs-snapshot-identities.tsv" || return 1
    sync -f "$EVIDENCE" || return 1
    sync -f "$OPS" || return 1
    zpool sync "${EXPECTED_DATADIR_DATASET%%/*}" || return 1
}

verify_snapshot_inventory_identity()
{
    local snapshot guid createtxg hold extra actual_guid actual_createtxg
    local actual_names expected_names
    [[ -f "${EVIDENCE}/zfs-snapshot-identities.tsv" &&
       ! -L "${EVIDENCE}/zfs-snapshot-identities.tsv" &&
       -n "$SNAPSHOT_IDENTITY_SHA" ]] || return 1
    [[ "$(sha256sum "${EVIDENCE}/zfs-snapshot-identities.tsv" | awk '{print $1}')" == \
       "$SNAPSHOT_IDENTITY_SHA" ]] || return 1

    actual_names=$(mktemp "${OPS}/.zfs-current-names.XXXXXX") || return 1
    expected_names=$(mktemp "${OPS}/.zfs-expected-names.XXXXXX") || return 1
    enumerate_canary_snapshots > "$actual_names" || return 1
    awk -F '\t' 'NF == 4 {print $1}' "${EVIDENCE}/zfs-snapshot-identities.tsv" |
        sort -u > "$expected_names" || return 1
    cmp -s "$expected_names" "$actual_names" || return 1
    [[ "$(wc -l < "$expected_names" | awk '{print $1}')" == "$SNAPSHOT_COUNT" ]] || return 1

    while IFS=$'\t' read -r snapshot guid createtxg hold extra; do
        [[ -n "$snapshot" && -n "$guid" && -n "$createtxg" &&
           "$hold" == "$ZFS_HOLD_TAG" && -z "$extra" ]] || return 1
        actual_guid=$(zfs get -Hp -o value guid "$snapshot") || return 1
        actual_createtxg=$(zfs get -Hp -o value createtxg "$snapshot") || return 1
        [[ "$actual_guid" == "$guid" && "$actual_createtxg" == "$createtxg" ]] || return 1
        snapshot_hold_present "$snapshot" || return 1
    done < "${EVIDENCE}/zfs-snapshot-identities.tsv"
    rm -f -- "$actual_names" "$expected_names"
    snapshot_identity_verified=true
}

restore_pre_upgrade_data()
{
    local snapshot dataset safe_name diff_file guid createtxg hold extra
    local order_tmp proof_tmp
    verify_snapshot_inventory_identity || return 1
    order_tmp=$(mktemp "${OPS}/.zfs-rollback-order.XXXXXX") || return 1
    proof_tmp=$(mktemp "${OPS}/.zfs-restore-proof.XXXXXX") || return 1

    # Roll children before parents.  Plain rollback is deliberate: it refuses
    # newer snapshots instead of destroying them.  Never add -r, -R, or -f.
    awk -F '\t' '{snapshot=$1; dataset=snapshot; sub(/@[^@]+$/, "", dataset);
        depth=gsub(/\//, "/", dataset); print depth "\t" snapshot}' \
        "${EVIDENCE}/zfs-snapshot-identities.tsv" |
        sort -t $'\t' -k1,1nr -k2,2 |
        awk -F '\t' '{print $2}' > "$order_tmp" || return 1
    [[ "$(wc -l < "$order_tmp" | awk '{print $1}')" == "$SNAPSHOT_COUNT" ]] || return 1
    install -m 600 -o root -g root "$order_tmp" "${EVIDENCE}/zfs-rollback-order.txt"

    while IFS= read -r snapshot; do
        [[ -n "$snapshot" ]] || return 1
        zfs rollback "$snapshot" || return 1
    done < "$order_tmp"

    verify_snapshot_inventory_identity || return 1
    : > "$proof_tmp"
    while IFS=$'\t' read -r snapshot guid createtxg hold extra; do
        [[ -n "$snapshot" && -n "$guid" && -n "$createtxg" &&
           "$hold" == "$ZFS_HOLD_TAG" && -z "$extra" ]] || return 1
        dataset=${snapshot%@*}
        safe_name=${dataset//\//__}
        diff_file="${EVIDENCE}/zfs-restore-diff-${safe_name}.txt"
        zfs diff -FH "$snapshot" "$dataset" > "$diff_file" || return 1
        [[ ! -s "$diff_file" ]] || {
            echo "dataset differs from its pre-upgrade snapshot after rollback: $dataset" >&2
            return 1
        }
        printf '%s\t%s\t%s\t%s\tzero-diff\n' \
            "$snapshot" "$guid" "$createtxg" "$hold" >> "$proof_tmp"
    done < "${EVIDENCE}/zfs-snapshot-identities.tsv"
    mv -fT -- "$proof_tmp" "${EVIDENCE}/zfs-restore-proof.tsv"
    SNAPSHOT_RESTORE_PROOF_SHA=$(sha256sum "${EVIDENCE}/zfs-restore-proof.tsv" | awk '{print $1}')
    [[ "$SNAPSHOT_RESTORE_PROOF_SHA" =~ ^[0-9a-f]{64}$ ]] || return 1
    snapshot_zero_diff_verified=true
    pre_upgrade_data_restored=true
}

release_snapshot_holds()
{
    local snapshot guid createtxg hold extra temporary
    verify_snapshot_inventory_identity || return 1
    temporary=$(mktemp "${OPS}/.zfs-hold-release.XXXXXX") || return 1
    : > "$temporary"
    while IFS=$'\t' read -r snapshot guid createtxg hold extra; do
        [[ -n "$snapshot" && -n "$guid" && -n "$createtxg" &&
           "$hold" == "$ZFS_HOLD_TAG" && -z "$extra" ]] || return 1
        zfs release "$hold" "$snapshot" || return 1
        if snapshot_hold_present "$snapshot"; then
            return 1
        fi
        printf '%s\t%s\treleased\n' "$snapshot" "$hold" >> "$temporary"
    done < "${EVIDENCE}/zfs-snapshot-identities.tsv"
    zpool sync "${EXPECTED_DATADIR_DATASET%%/*}" || return 1
    mv -fT -- "$temporary" "${EVIDENCE}/zfs-hold-release.tsv"
    sync -f "${EVIDENCE}/zfs-hold-release.tsv" || return 1
    sync -f "$EVIDENCE" || return 1
    snapshot_holds_released=true
}

verify_pre_upgrade_data_zero_diff()
{
    local snapshot guid createtxg hold extra dataset probe
    verify_snapshot_inventory_identity || return 1
    while IFS=$'\t' read -r snapshot guid createtxg hold extra; do
        [[ -n "$snapshot" && -n "$guid" && -n "$createtxg" &&
           "$hold" == "$ZFS_HOLD_TAG" && -z "$extra" ]] || return 1
        dataset=${snapshot%@*}
        probe=$(mktemp "${OPS}/.zfs-reentry-diff.XXXXXX") || return 1
        zfs diff -FH "$snapshot" "$dataset" >"$probe" || return 1
        [[ ! -s "$probe" ]] || return 1
        rm -f -- "$probe"
    done <"${EVIDENCE}/zfs-snapshot-identities.tsv"
    snapshot_zero_diff_verified=true
    pre_upgrade_data_restored=true
}

stop_candidate_for_restore()
{
    local attempt running stop_mode runtime_kind
    runtime_kind=$(container_runtime_kind) || return 1
    [[ "$runtime_kind" == candidate ]] || {
        echo "refusing candidate stop for unauthenticated runtime kind: $runtime_kind" >&2
        return 1
    }
    # Candidate startup is itself an untrusted boundary. Until an activation
    # marker has been published, there is no durable proof that the released
    # binary stayed locked/off. Contain any preactivation failure and never
    # rewind data that might already reflect an unexpected signing action.
    (( ACTIVATION_SEQUENCE > 0 )) || return 1
    running=$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)
    if [[ "$running" != true ]]; then
        echo 'activated candidate is already stopped without a durable safe-boundary proof' >&2
        return 1
    fi
    # After any durable activation-attempt marker, loss of RPC authority is
    # ambiguous. Never infer safety from a stopped process or Docker state.
    rpc getblockchaininfo >/dev/null 2>&1 || return 1
    [[ "$SAFE_SEQUENCE" == "$ACTIVATION_SEQUENCE" ]] ||
        quiesce_candidate_and_publish_safe "$ACTIVATION_SEQUENCE" emergency-rollback ||
        return 1
    validate_candidate_safe_marker "$ACTIVATION_SEQUENCE" || return 1
    stop_mode='rpc-stop-after-durable-safe-boundary'
    rpc stop >/dev/null 2>&1 || return 1
    for attempt in $(seq 1 180); do
        [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)" != true ]] &&
            break
        sleep 1
    done
    if [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)" == true ]]; then
        return 1
    fi
    assert_container_cleanly_stopped || return 1
    printf '%s\n' "$stop_mode" >"${EVIDENCE}/candidate-restore-stop-mode.txt" || return 1
    chmod 600 "${EVIDENCE}/candidate-restore-stop-mode.txt" || return 1
    chown root:root "${EVIDENCE}/candidate-restore-stop-mode.txt" || return 1
    sync -f "${EVIDENCE}/candidate-restore-stop-mode.txt" || return 1
}

contain_node()
{
    local inspect running restart pid containment_verified=false _
    phase='contained'
    ensure_guard_starts_suspended || true
    if inspect=$(docker inspect "$CONTAINER" 2>/dev/null); then
        docker update --restart=no "$CONTAINER" >/dev/null 2>&1 || true
        if jq -e 'length == 1 and .[0].State.Running == true' >/dev/null 2>&1 <<< "$inspect"; then
            timeout --kill-after=30 360 docker stop -t 300 "$CONTAINER" >/dev/null 2>&1 || true
        fi
        for _ in $(seq 1 30); do
            running=$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)
            restart=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$CONTAINER" 2>/dev/null || true)
            pid=$(docker inspect -f '{{.State.Pid}}' "$CONTAINER" 2>/dev/null || true)
            if [[ "$running" == false && "$restart" == no && "$pid" == 0 ]] &&
               guard_starts_are_suspended; then
                containment_verified=true
                break
            fi
            sleep 1
        done
    elif container_is_authoritatively_absent && guard_starts_are_suspended; then
        containment_verified=true
        running=absent
        restart=absent
        pid=absent
    fi
    if [[ "$containment_verified" == true ]]; then
        jq -n --arg timestamp "$(date -u +%FT%TZ)" --arg running "$running" \
            --arg restart "$restart" --arg pid "$pid" --arg inhibitor "$SUSPENDED_START_MARKER" \
            '{schema:1,containment_verified:true,timestamp:$timestamp,
              container_running:$running,restart_policy:$restart,pid:$pid,
              automatic_start_inhibitor:$inhibitor}' > "${EVIDENCE}/CONTAINED.json" 2>/dev/null || true
        chmod 600 "${EVIDENCE}/CONTAINED.json" 2>/dev/null || true
        chown root:root "${EVIDENCE}/CONTAINED.json" 2>/dev/null || true
        sync -f "${EVIDENCE}/CONTAINED.json" 2>/dev/null || true
        sync -f "$EVIDENCE" 2>/dev/null || true
        echo 'Node 27 is stopped with restart disabled and durable automatic-start authority suspended.' >&2
    else
        printf 'containment_unproven_at=%s\n' "$(date -u +%FT%TZ)" \
            > "${EVIDENCE}/CONTAINMENT-UNPROVEN" 2>/dev/null || true
        echo 'CRITICAL: node 27 containment could not be proven; automatic-start authority remains suspended if available.' >&2
    fi
    return 1
}

restore_original()
{
    local restore_rc=0 runtime_kind
    if (( candidate_launch_attempted == 1 )) ||
       [[ -e "$CANDIDATE_LAUNCH_MARKER" || -L "$CANDIDATE_LAUNCH_MARKER" ]]; then
        validate_candidate_launch_marker || {
            echo 'Durable candidate-launch marker is absent, unsafe, or inconsistent.' >&2
            contain_node
            return 1
        }
        candidate_launch_attempted=1
        runtime_kind=$(container_runtime_kind) || runtime_kind=unknown
        case "$runtime_kind" in
            original)
                # A prior restoration attempt already recreated the exact old
                # image and invocation. Never feed its legitimate q1 state to
                # the candidate q0 drain. Prove the datasets are already exact.
                verify_pre_upgrade_data_zero_diff || {
                    echo 'Original runtime exists but exact restored data cannot be proven.' >&2
                    contain_node
                    return 1
                }
                [[ -f "${EVIDENCE}/zfs-restore-proof.tsv" ]] &&
                    SNAPSHOT_RESTORE_PROOF_SHA=$(sha256sum \
                        "${EVIDENCE}/zfs-restore-proof.tsv" | awk '{print $1}')
                phase='data_restored'
                ;;
            candidate)
                stop_candidate_for_restore || {
                    echo 'Candidate could not be stopped at a safe boundary.' >&2
                    contain_node
                    return 1
                }
                phase='candidate_stopped'
                verify_rollback_image_ready || {
                    echo 'Pinned 30.1.3 rollback image or base Compose model is no longer ready.' >&2
                    contain_node
                    return 1
                }
                restore_pre_upgrade_data || {
                    echo 'Exact pre-upgrade ZFS restoration could not be proven.' >&2
                    contain_node
                    return 1
                }
                phase='data_restored'
                ;;
            absent)
                echo 'Candidate is absent after launch; runtime state is ambiguous and rollback is forbidden.' >&2
                contain_node
                return 1
                ;;
            *)
                echo 'Container image or invocation is not an authenticated candidate or original runtime.' >&2
                contain_node
                return 1
                ;;
        esac
    fi
    verify_rollback_image_ready || {
        echo 'Pinned 30.1.3 rollback image or base Compose model changed before restoration.' >&2
        contain_node
        return 1
    }
    echo "Restoring node 27 to its original 30.1.3 GUI image..."
    docker compose -f "$COMPOSE" up -d --no-deps --force-recreate --pull never "$SERVICE" || {
        contain_node
        return 1
    }
    if (( restore_rc == 0 )); then
        wait_rpc || restore_rc=1
    fi
    if (( restore_rc == 0 )); then
        [[ "$(container_runtime_kind)" == original ]] || restore_rc=1
        rpc staking false >"${EVIDENCE}/restored-cold-staking-stop.json" || restore_rc=1
        rpc setpowmining false 1 1 false >"${EVIDENCE}/restored-cold-pow-stop.json" || restore_rc=1
        rpc walletlock >"${EVIDENCE}/restored-cold-wallet-lock.json" || restore_rc=1
        rpc getwalletinfo >"${EVIDENCE}/restored-cold-wallet.json" || restore_rc=1
        rpc getpowmininginfo >"${EVIDENCE}/restored-cold-pow.json" || restore_rc=1
        rpc listtransactions '*' 1000000 0 true | jq -S '[.[].txid] | unique | sort' \
            >"${EVIDENCE}/restored-cold-transaction-txids.json" || restore_rc=1
        jq -e '.private_keys_enabled == true and .unlocked_until == 0' \
            "${EVIDENCE}/restored-cold-wallet.json" >/dev/null || restore_rc=1
        legacy_cold_pow_is_exact "${EVIDENCE}/restored-cold-pow.json" \
            "$LEGACY_BASELINE_QUARANTINED_CLAIMS" || restore_rc=1
        transaction_sets_match_exactly "${EVIDENCE}/prelaunch-transaction-txids.json" \
            "${EVIDENCE}/restored-cold-transaction-txids.json" || restore_rc=1
    fi
    if (( restore_rc == 0 )); then
        run_helper "$NORMAL_UNLOCK_HELPER" "$NORMAL_UNLOCK_HELPER_SHA" || restore_rc=1
        if [[ "$LEGACY_BASELINE_POW_MODE" == clean-hashing ]]; then
            run_helper "$POW_START_HELPER" "$POW_START_HELPER_SHA" || restore_rc=1
        elif [[ "$LEGACY_BASELINE_POW_MODE" != quarantined-disabled ]]; then
            restore_rc=1
        fi
    fi
    if (( restore_rc == 0 )); then
        local restored_image restored_id
        restored_image="$(docker inspect -f '{{.Config.Image}}' "$CONTAINER")"
        restored_id="$(docker inspect -f '{{.Image}}' "$CONTAINER")"
        [[ "$restored_image" == "$ORIGINAL_IMAGE" ]] || restore_rc=1
        [[ "$restored_id" == "$ORIGINAL_IMAGE_ID" ]] || restore_rc=1
        docker inspect "$CONTAINER" | jq -S '.[0] | {path:.Path,args:.Args,
            entrypoint:.Config.Entrypoint,cmd:.Config.Cmd}' > "${EVIDENCE}/restored-invocation.json" ||
            restore_rc=1
        cmp -s "${EVIDENCE}/baseline-invocation.json" "${EVIDENCE}/restored-invocation.json" ||
            restore_rc=1
        wait_restored_runtime_gate || restore_rc=1
        rpc getgoldrushinfo >"${EVIDENCE}/restored-goldrush.json" || restore_rc=1
        rpc listquantumaddresses | jq -S . >"${EVIDENCE}/restored-quantum-addresses.json" || restore_rc=1
        rpc getquantumkeyinventory | jq -S . >"${EVIDENCE}/restored-quantum-inventory.json" || restore_rc=1
        rpc listtransactions '*' 100000 0 true | jq -S '[.[].txid] | unique | sort' \
            >"${EVIDENCE}/restored-transaction-txids.json" || restore_rc=1
        jq -S '[.wallet_scripts[].address] | unique | sort' \
            "${EVIDENCE}/restored-goldrush.json" >"${EVIDENCE}/restored-legacy-addresses.json" || restore_rc=1
        local restored_staking_ok=0 sample
        for sample in $(seq 1 12); do
            rpc getstakinginfo >"${EVIDENCE}/restored-staking-${sample}.json" || restore_rc=1
            # v30.1.3's legacy `staking` field is a timing-sensitive search
            # interval sample and can remain false while the enabled worker has
            # positive stake weight.  The canary must be able to roll back to
            # that known state; only v30.1.4 is required to publish the new
            # coherent worker snapshot.
            if jq -e '.enabled == true and .weight > 0' \
                "${EVIDENCE}/restored-staking-${sample}.json" >/dev/null 2>&1; then
                restored_staking_ok=1
                break
            fi
            sleep 3
        done
        (( restored_staking_ok == 1 )) || restore_rc=1
        [[ "$(sha256sum "${EVIDENCE}/restored-quantum-addresses.json" | awk '{print $1}')" == "$QUANTUM_ADDRESSES_SHA" ]] || restore_rc=1
        [[ "$(sha256sum "${EVIDENCE}/restored-quantum-inventory.json" | awk '{print $1}')" == "$QUANTUM_INVENTORY_SHA" ]] || restore_rc=1
        cmp -s "${EVIDENCE}/baseline-legacy-addresses.json" "${EVIDENCE}/restored-legacy-addresses.json" || restore_rc=1
        jq -e -s '((.[0] - .[1]) | length) == 0' \
            "${EVIDENCE}/baseline-transaction-txids.json" \
            "${EVIDENCE}/restored-transaction-txids.json" >/dev/null || restore_rc=1
        [[ "$(sha256sum "${HOST_DATADIR}/blackcoin.conf")" == \
           "$(cat "${EVIDENCE}/blackcoin-conf.sha256")" ]] || restore_rc=1
        if [[ -f "${EVIDENCE}/settings-json.sha256" ]]; then
            [[ -f "${HOST_DATADIR}/settings.json" &&
               "$(sha256sum "${HOST_DATADIR}/settings.json")" == \
               "$(cat "${EVIDENCE}/settings-json.sha256")" ]] || restore_rc=1
        else
            [[ ! -e "${HOST_DATADIR}/settings.json" ]] || restore_rc=1
        fi
    fi
    if (( restore_rc != 0 )); then
        contain_node
        return 1
    fi
    restored_runtime_verified=true
    phase='restored'
    return 0
}

failed_maintenance_is_fail_closed()
{
    if [[ -e "$ROLLOUT_MAINTENANCE_MARKER" || -L "$ROLLOUT_MAINTENANCE_MARKER" ]]; then
        validate_canary_maintenance_marker
        return
    fi
    (( maintenance_marker_activated == 0 ))
}

on_exit()
{
    local rc=$?
    trap - EXIT ERR INT TERM
    case "$phase" in
        preflight|restored|contained) ;;
        *) restore_original || rc=1 ;;
    esac
    if [[ "$phase" == restored ]] && guard_starts_are_suspended; then
        restore_guard_starts || rc=1
    fi
    if [[ "$result" != passed ]]; then
        rc=1
        if [[ -e "$ROLLOUT_MAINTENANCE_MARKER" || -L "$ROLLOUT_MAINTENANCE_MARKER" ]]; then
            if failed_maintenance_is_fail_closed; then
                echo "Crash-safe maintenance remains active for recovery: $ROLLOUT_MAINTENANCE_MARKER" >&2
            else
                echo "CRITICAL: canary maintenance authority is malformed; guards remain fail-closed and manual audited recovery is required." >&2
                rc=1
            fi
        elif ! failed_maintenance_is_fail_closed; then
            echo 'CRITICAL: an activated canary maintenance marker disappeared before authorized release.' >&2
            rc=1
        fi
        echo "Canary did not pass. Evidence: $EVIDENCE" >&2
    fi
    exit "$rc"
}
trap on_exit EXIT ERR INT TERM

[[ "$(id -u)" == 0 ]] || fail 'must run as root'
for command in docker jq sha256sum cmp timeout flock findmnt zfs zpool install stat grep sort \
    awk wc mktemp realpath mv chmod chown sync date seq sleep find xargs rm cat od tr; do
    command -v "$command" >/dev/null 2>&1 || fail "required command is unavailable: $command"
done
[[ -f "$COMPOSE" && ! -L "$COMPOSE" ]] || fail 'base compose file is missing or unsafe'
[[ "$(cat "${STAGE}/SOURCE_COMMIT.txt")" == "$SOURCE_SHA" ]] || fail 'source marker mismatch'
[[ "$(docker compose -f "$COMPOSE" config --format json | jq -er '.services.node27.image')" == \
   "$ORIGINAL_IMAGE" ]] || fail 'base Compose node27 image is not the pinned rollback image'
[[ "$(docker image inspect -f '{{.Id}}' "$ORIGINAL_IMAGE" 2>/dev/null || true)" == \
   "$ORIGINAL_IMAGE_ID" ]] || fail 'pinned rollback image is absent or has the wrong local image ID'
assert_empty_control_marker "$ENABLE_GUARD_STARTS" ||
    fail 'automatic-start authority marker is absent, nonempty, or unsafe'
verify_guard_compatibility ||
    fail 'live endpoint/wallet-runtime guards are not the exact canary-maintenance-compatible pair'
[[ ! -e "$ROLLOUT_MAINTENANCE_MARKER" && ! -L "$ROLLOUT_MAINTENANCE_MARKER" ]] ||
    fail 'a rollout or canary maintenance marker already exists'
[[ ! -e "$SUSPENDED_START_MARKER" && ! -L "$SUSPENDED_START_MARKER" ]] ||
    fail 'canary-specific suspended-start marker already exists'
[[ "$(cat /boot/config/plugins/compose.manager/projects/blackcoin30/autostart 2>/dev/null || true)" == false ]] ||
    fail 'Compose autostart is not fail-closed'
[[ "$CANDIDATE_IMAGE" =~ ^[A-Za-z0-9._/-]+@sha256:[0-9a-f]{64}$ ]] ||
    fail 'published candidate image must be supplied by immutable manifest digest'
[[ "$CANDIDATE_IMAGE_ID" =~ ^sha256:[0-9a-f]{64}$ ]] ||
    fail 'candidate image ID is missing or malformed'
[[ "$(docker image inspect -f '{{.Id}}' "$CANDIDATE_IMAGE" 2>/dev/null || true)" == "$CANDIDATE_IMAGE_ID" ]] ||
    fail 'candidate image ID mismatch'
[[ "$(docker image inspect -f '{{index .Config.Labels "org.blackcoin.source.commit"}}' "$CANDIDATE_IMAGE")" == "$SOURCE_SHA" ]] ||
    fail 'candidate image source label mismatch'
[[ "$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$CANDIDATE_IMAGE")" == v30.1.4 ]] ||
    fail 'candidate image version label mismatch'
CANDIDATE_MODE='published-package-image'

[[ ! -e "$OPS" && ! -L "$OPS" ]] || fail 'canary operations path already exists or is a symlink'
install -d -m 700 -o root -g root "$OPS"
[[ ! -e "$EVIDENCE" && ! -L "$EVIDENCE" ]] || fail 'canary evidence path already exists or is a symlink'
install -d -m 700 -o root -g root "$EVIDENCE"
[[ "$(realpath -e -- "$OPS")" == "$OPS" && "$(stat -Lc '%u:%g:%a' -- "$OPS")" == 0:0:700 ]] ||
    fail 'canary operations path is not canonical root:root 0700'
canonical_canary_ops_directory || fail 'canary operations path does not match the guard-compatible schema'
[[ "$(realpath -e -- "$EVIDENCE")" == "$EVIDENCE" &&
   "$(stat -Lc '%u:%g:%a' -- "$EVIDENCE")" == 0:0:700 ]] ||
    fail 'canary evidence path is not canonical root:root 0700'
OPS_DATASET=$(findmnt -n -o SOURCE -T "$OPS") || fail 'cannot identify canary evidence dataset'
for rollback_dataset in "$EXPECTED_DATADIR_DATASET" "$EXPECTED_BLOCKS_DATASET" \
    "$EXPECTED_INDEXES_DATASET" "$EXPECTED_RAW_DATASET"; do
    [[ "$OPS_DATASET" != "$rollback_dataset" && "$OPS_DATASET" != "$rollback_dataset/"* ]] ||
        fail 'canary evidence storage is inside a rollback dataset'
done
[[ "$OPS" != "$HOST_DATADIR" && "$OPS" != "$HOST_DATADIR/"* &&
   "$OPS" != "$HOST_RAW" && "$OPS" != "$HOST_RAW/"* ]] ||
    fail 'canary evidence path is inside node 27 rollback storage'
printf 'operations_path=%s\nevidence_path=%s\noperations_dataset=%s\n' \
    "$OPS" "$EVIDENCE" "$OPS_DATASET" > "${EVIDENCE}/operations-storage.txt"

verify_helper "$NORMAL_UNLOCK_HELPER" "$NORMAL_UNLOCK_HELPER_SHA" ||
    fail 'normal-unlock helper identity mismatch'
verify_helper "$POW_START_HELPER" "$POW_START_HELPER_SHA" ||
    fail 'PoW-start helper identity mismatch'
{
    printf 'path\tsha256\tuid:gid:mode\n'
    printf '%s\t%s\t%s\n' "$NORMAL_UNLOCK_HELPER" "$NORMAL_UNLOCK_HELPER_SHA" \
        "$(stat -Lc '%u:%g:%a' -- "$NORMAL_UNLOCK_HELPER")"
    printf '%s\t%s\t%s\n' "$POW_START_HELPER" "$POW_START_HELPER_SHA" \
        "$(stat -Lc '%u:%g:%a' -- "$POW_START_HELPER")"
} > "${EVIDENCE}/runtime-helper-identities.tsv"

if [[ "${INHERITED_ENDPOINT_LOCK_FD+x}" == x ]]; then
    [[ "$INHERITED_ENDPOINT_LOCK_FD" == 20 ]] ||
        fail 'INHERITED_ENDPOINT_LOCK_FD must be unset or the literal descriptor 20'
    [[ "$(realpath -e -- "/proc/$$/fd/20" 2>/dev/null || true)" == \
       /run/blackcoin-endpoint-guard.lock ]] ||
        fail 'inherited descriptor 20 is not the exact endpoint-guard lock file'
    exec 5>&20
    [[ "$(realpath -e -- "/proc/$$/fd/5" 2>/dev/null || true)" == \
       /run/blackcoin-endpoint-guard.lock ]] ||
        fail 'could not retain inherited endpoint-guard lock on descriptor 5'
    flock -n 5 || fail 'inherited endpoint-guard descriptor is not lockable by this transaction'
else
    exec 5>/run/blackcoin-endpoint-guard.lock
    flock -w 1800 5 || fail 'endpoint guard did not drain within 30 minutes; no state was changed'
fi
exec 9>/var/run/blackcoin-node-cutover.lock
flock -w 1800 9 || fail 'fleet cutover lock did not drain within 30 minutes; no state was changed'
exec 8>/run/blackcoin-pow-quarantine-cycle.lock
flock -w 1800 8 || fail 'PoW quarantine-cycle lock did not drain within 30 minutes; no state was changed'
exec 7>/var/run/blackcoin-wallet-runtime-guard.lock
flock -w 1800 7 || fail 'wallet runtime guard did not drain within 30 minutes; no state was changed'

# The advisory guard locks vanish on SIGKILL or host failure.  Publish the
# nonce-bound marker while all four locks are held and before touching any node,
# wallet, config, chain data, automatic-start authority, or live container.
verify_guard_compatibility ||
    fail 'guard compatibility changed while waiting for the shared locks'
activate_canary_maintenance_marker ||
    fail 'could not durably activate crash-safe node27 canary maintenance'

[[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER")" == true ]] || fail 'node 27 is not running'
[[ "$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER")" == healthy ]] || fail 'node 27 is not healthy'
[[ "$(docker inspect -f '{{.Config.Image}}' "$CONTAINER")" == "$ORIGINAL_IMAGE" ]] || fail 'node 27 is not on the expected original image'
[[ "$(docker inspect -f '{{.Image}}' "$CONTAINER")" == "$ORIGINAL_IMAGE_ID" ]] || fail 'node 27 original image ID mismatch'
[[ "$(rpc listwallets | jq -cS .)" == '[""]' ]] || fail 'unexpected wallet catalog'
[[ "$(findmnt -n -o SOURCE -T "$HOST_DATADIR")" == "$EXPECTED_DATADIR_DATASET" ]] ||
    fail 'node 27 datadir is not on the pinned dedicated dataset'
[[ "$(findmnt -n -o SOURCE -T "${HOST_DATADIR}/blocks")" == "$EXPECTED_BLOCKS_DATASET" ]] ||
    fail 'node 27 datadir blocks child is not on the pinned dataset'
[[ "$(findmnt -n -o SOURCE -T "${HOST_DATADIR}/indexes")" == "$EXPECTED_INDEXES_DATASET" ]] ||
    fail 'node 27 indexes child is not on the pinned dataset'
[[ "$(findmnt -n -o SOURCE -T "$HOST_RAW")" == "$EXPECTED_RAW_DATASET" ]] ||
    fail 'node 27 raw blocks are not on the pinned dedicated dataset'
if grep -Eq '^[[:space:]]*(reindex|reindex-chainstate)[[:space:]]*=[[:space:]]*(1|true|yes)([[:space:]]|$)' "${HOST_DATADIR}/blackcoin.conf"; then
    fail 'persistent reindex setting detected'
fi

docker inspect -f '{"image":"{{.Config.Image}}","image_id":"{{.Image}}","status":"{{.State.Status}}","health":"{{.State.Health.Status}}"}' \
    "$CONTAINER" >"${EVIDENCE}/baseline-container.json"
docker inspect "$CONTAINER" | jq -S '.[0] | {path:.Path,args:.Args,
    entrypoint:.Config.Entrypoint,cmd:.Config.Cmd}' > "${EVIDENCE}/baseline-invocation.json"
docker compose -f "$COMPOSE" config --format json | jq -S . > "${EVIDENCE}/baseline-compose-model.json"
jq -e --arg original "$ORIGINAL_IMAGE" '.services.node27.image == $original' \
    "${EVIDENCE}/baseline-compose-model.json" >/dev/null ||
    fail 'locked baseline Compose model no longer names the pinned rollback image'
verify_rollback_image_ready || fail 'locked rollback image readiness changed'
rpc getblockchaininfo >"${EVIDENCE}/baseline-blockchain.json"
rpc getnetworkinfo >"${EVIDENCE}/baseline-network.json"
rpc getwalletinfo >"${EVIDENCE}/baseline-wallet.json"
rpc getpowmininginfo >"${EVIDENCE}/baseline-pow.json"
rpc getgoldrushinfo >"${EVIDENCE}/baseline-goldrush.json"
rpc listtransactions '*' 100000 0 true | jq -S '[.[].txid] | unique | sort' \
    >"${EVIDENCE}/baseline-transaction-txids.json"
jq -S '[.wallet_scripts[].address] | unique | sort' \
    "${EVIDENCE}/baseline-goldrush.json" >"${EVIDENCE}/baseline-legacy-addresses.json"
rpc listquantumaddresses | jq -S . >"${EVIDENCE}/baseline-quantum-addresses.json"
rpc getquantumkeyinventory | jq -S . >"${EVIDENCE}/baseline-quantum-inventory.json"
sha256sum "${HOST_DATADIR}/blackcoin.conf" >"${EVIDENCE}/blackcoin-conf.sha256"
[[ ! -e "${HOST_DATADIR}/settings.json" ]] || sha256sum "${HOST_DATADIR}/settings.json" >"${EVIDENCE}/settings-json.sha256"

[[ "$(sha256sum "${EVIDENCE}/baseline-quantum-addresses.json" | awk '{print $1}')" == "$QUANTUM_ADDRESSES_SHA" ]] || fail 'baseline quantum-address identity mismatch'
[[ "$(sha256sum "${EVIDENCE}/baseline-quantum-inventory.json" | awk '{print $1}')" == "$QUANTUM_INVENTORY_SHA" ]] || fail 'baseline quantum-key identity mismatch'
jq -e '.initialblockdownload == false and .blocks == .headers' "${EVIDENCE}/baseline-blockchain.json" >/dev/null || fail 'baseline chain is not ready'
jq -e 'type == "array" and length > 0 and all(.[]; type == "string" and length > 0)' \
    "${EVIDENCE}/baseline-legacy-addresses.json" >/dev/null || fail 'baseline legacy-address inventory is empty or invalid'
while IFS= read -r legacy_address; do
    rpc validateaddress "$legacy_address" | jq -e \
        '.isvalid == true and ((.iswitness // false) == false)' >/dev/null ||
        fail 'baseline mining/staking address is not a valid legacy address'
done < <(jq -r '.[]' "${EVIDENCE}/baseline-legacy-addresses.json")
baseline_staking_ok=0
for sample in $(seq 1 12); do
    rpc getstakinginfo >"${EVIDENCE}/baseline-staking-${sample}.json"
    # v30.1.3 does not expose a coherent PoS worker snapshot.  Its reliable
    # canary prerequisites are explicit enablement, a normally unlocked
    # wallet, and nonzero mature stake weight.
    if jq -e '.enabled == true and .weight > 0' \
        "${EVIDENCE}/baseline-staking-${sample}.json" >/dev/null 2>&1; then
        baseline_staking_ok=1
        break
    fi
    sleep 3
done
(( baseline_staking_ok == 1 )) || fail 'baseline staking is not active'
jq -e '.unlocked_until > now' "${EVIDENCE}/baseline-wallet.json" >/dev/null || fail 'baseline wallet is not normally unlocked'
LEGACY_OBSERVED_POW_MODE=$(legacy_pow_observed_mode "${EVIDENCE}/baseline-pow.json") ||
    fail 'observed PoW is not exact clean hashing, disabled q1, or stalled enabled/hash0 q1'
case "$LEGACY_OBSERVED_POW_MODE" in
    clean-hashing) LEGACY_BASELINE_POW_MODE='clean-hashing' ;;
    quarantined-disabled|quarantined-stalled)
        LEGACY_BASELINE_POW_MODE='quarantined-disabled'
        ;;
    *) fail 'unsupported observed legacy PoW mode' ;;
esac
LEGACY_BASELINE_LIVE_CLAIMS=$(jq -er \
    '.live_claims | select(type == "number" and floor == . and . == 0)' \
    "${EVIDENCE}/baseline-pow.json") || fail 'baseline live-claim count is invalid'
LEGACY_BASELINE_QUARANTINED_CLAIMS=$(jq -er \
    '.quarantined_claims | select(type == "number" and floor == . and . >= 0)' \
    "${EVIDENCE}/baseline-pow.json") || fail 'baseline quarantined-claim count is invalid'
if [[ "$LEGACY_OBSERVED_POW_MODE" != quarantined-stalled ]]; then
    legacy_pow_state_matches_baseline "${EVIDENCE}/baseline-pow.json" ||
        fail 'observed PoW mode and claim counters are inconsistent'
fi

# Validate that the exact published binaries can execute without network or
# wallet/data access before touching the live container.
docker run --rm --pull=never --network none --read-only --entrypoint /usr/local/bin/blackcoind \
    "$CANDIDATE_IMAGE" -version >"${EVIDENCE}/native-blackcoind-version.txt"
docker run --rm --pull=never --network none --read-only --entrypoint /usr/local/bin/blackcoin-cli \
    "$CANDIDATE_IMAGE" -version >"${EVIDENCE}/native-blackcoin-cli-version.txt"
[[ "$(docker run --rm --pull=never --network none --read-only --entrypoint /usr/bin/sha256sum \
    "$CANDIDATE_IMAGE" /usr/local/bin/blackcoind | awk '{print $1}')" == "$BLACKCOIND_SHA" ]] ||
    fail 'candidate image daemon hash mismatch'
[[ "$(docker run --rm --pull=never --network none --read-only --entrypoint /usr/bin/sha256sum \
    "$CANDIDATE_IMAGE" /usr/local/bin/blackcoin-cli | awk '{print $1}')" == "$BLACKCOIN_CLI_SHA" ]] ||
    fail 'candidate image CLI hash mismatch'
grep -F 'v30.1.4' "${EVIDENCE}/native-blackcoind-version.txt" >/dev/null || fail 'native daemon version mismatch'
grep -F 'v30.1.4' "${EVIDENCE}/native-blackcoin-cli-version.txt" >/dev/null || fail 'native CLI version mismatch'

phase='original_mutation_started'
HOT_BACKUP="canary-${SOURCE_SHA}-${STAMP}.dat"
if [[ ! -d "${HOST_DATADIR}/backups" ]]; then
    install -d -m 700 \
        -o "$(stat -c %u "${HOST_DATADIR}/wallet.dat")" \
        -g "$(stat -c %g "${HOST_DATADIR}/wallet.dat")" \
        "${HOST_DATADIR}/backups"
fi
rpc backupwallet "${DATADIR}/backups/${HOT_BACKUP}" >/dev/null
install -m 600 "${HOST_DATADIR}/backups/${HOT_BACKUP}" "${OPS}/wallet-hot.dat"
sha256sum "${OPS}/wallet-hot.dat" >"${EVIDENCE}/wallet-hot.sha256"

suspend_guard_starts || fail 'could not durably suspend automatic-start authority'
if [[ "$LEGACY_BASELINE_POW_MODE" == clean-hashing ]]; then
    if ! stop_and_drain_candidate_pow; then
        run_helper "$POW_START_HELPER" "$POW_START_HELPER_SHA" || true
        fail 'original node could not reach a no-spend claim-clean stop boundary'
    fi
else
    rpc setpowmining false 1 1 false >"${EVIDENCE}/legacy-prelaunch-pow-stop.json" ||
        fail 'could not explicitly stop the inherited legacy q1 miner'
fi
rpc staking false >"${EVIDENCE}/legacy-prelaunch-staking-stop.json" ||
    fail 'could not disable legacy staking before the cold boundary'
rpc walletlock >"${EVIDENCE}/legacy-prelaunch-wallet-lock.json" ||
    fail 'could not lock the legacy wallet before the cold boundary'
legacy_cold_ready=false
for attempt in $(seq 1 120); do
    rpc getwalletinfo >"${EVIDENCE}/legacy-prelaunch-wallet-${attempt}.json" ||
        fail 'legacy wallet status failed during cold normalization'
    rpc getpowmininginfo >"${EVIDENCE}/legacy-prelaunch-pow-${attempt}.json" ||
        fail 'legacy PoW status failed during cold normalization'
    if jq -e '.private_keys_enabled == true and .unlocked_until == 0' \
        "${EVIDENCE}/legacy-prelaunch-wallet-${attempt}.json" >/dev/null &&
       legacy_cold_pow_is_exact "${EVIDENCE}/legacy-prelaunch-pow-${attempt}.json" \
           "$LEGACY_BASELINE_QUARANTINED_CLAIMS"; then
        install -m 600 -o root -g root "${EVIDENCE}/legacy-prelaunch-wallet-${attempt}.json" \
            "${EVIDENCE}/legacy-prelaunch-wallet.json"
        install -m 600 -o root -g root "${EVIDENCE}/legacy-prelaunch-pow-${attempt}.json" \
            "${EVIDENCE}/legacy-prelaunch-pow.json"
        legacy_cold_ready=true
        break
    fi
    sleep 2
done
[[ "$legacy_cold_ready" == true ]] ||
    fail 'legacy node did not reach the exact locked disabled/hash0/live0 cold baseline'
rpc listtransactions '*' 1000000 0 true | jq -S '[.[].txid] | unique | sort' \
    >"${EVIDENCE}/prelaunch-transaction-txids.json"
transaction_sets_match_exactly "${EVIDENCE}/prelaunch-transaction-txids.json" \
    "${EVIDENCE}/prelaunch-transaction-txids.json" ||
    fail 'prelaunch wallet transaction set is malformed'
PRELAUNCH_TRANSACTION_SET_SHA=$(sha256sum \
    "${EVIDENCE}/prelaunch-transaction-txids.json" | awk '{print $1}')
[[ "$PRELAUNCH_TRANSACTION_SET_SHA" =~ ^[0-9a-f]{64}$ ]] ||
    fail 'prelaunch wallet transaction-set hash is malformed'
sync -f "${EVIDENCE}/prelaunch-transaction-txids.json" ||
    fail 'could not durably record the prelaunch wallet transaction set'
sync -f "$EVIDENCE" || fail 'could not sync prelaunch wallet transaction evidence'
phase='original_stop_started'
rpc stop >/dev/null || true
for _ in $(seq 1 180); do
    [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)" != true ]] && break
    sleep 1
done
if [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)" == true ]]; then
    docker stop -t 300 "$CONTAINER" >/dev/null
fi
assert_container_cleanly_stopped || fail 'original node did not stop cleanly before cold backup'
phase='original_stopped'

install -m 600 "${HOST_DATADIR}/wallet.dat" "${OPS}/wallet-cold.dat"
install -m 600 "${HOST_DATADIR}/blackcoin.conf" "${OPS}/blackcoin.conf"
[[ ! -e "${HOST_DATADIR}/settings.json" ]] || install -m 600 "${HOST_DATADIR}/settings.json" "${OPS}/settings.json"
sha256sum "${OPS}/wallet-cold.dat" >"${EVIDENCE}/wallet-cold.sha256"

SNAPSHOT_DATASETS=("$EXPECTED_DATADIR_DATASET" "$EXPECTED_RAW_DATASET")
for dataset in "${SNAPSHOT_DATASETS[@]}"; do
    zfs list -H -o name "$dataset" >/dev/null
done
capture_snapshot_inventory || fail 'could not create and pin the exact recursive ZFS snapshot inventory'
phase='snapshots_ready'

cat >"$OVERRIDE" <<EOF
services:
  node27:
    image: ${CANDIDATE_IMAGE}
EOF
docker compose -f "$COMPOSE" -f "$OVERRIDE" config --format json | jq -S . \
    > "${EVIDENCE}/candidate-compose-model.json"
jq -e -n --slurpfile before "${EVIDENCE}/baseline-compose-model.json" \
    --slurpfile after "${EVIDENCE}/candidate-compose-model.json" \
    --arg image "$CANDIDATE_IMAGE" '
    def neutralize($doc): $doc | .services.node27.image = "__CANARY_IMAGE__";
    ($after[0].services.node27.image == $image) and
    (neutralize($before[0]) == neutralize($after[0]))
' >/dev/null || fail 'canary Compose override changes more than the node27 image scalar'

CANARY_STARTED="$(date -u +%FT%TZ)"
phase='candidate_launch_journal_started'
publish_candidate_launch_marker || fail 'could not durably publish the candidate launch-attempt journal'
phase='candidate_launch_attempted'
docker compose -f "$COMPOSE" -f "$OVERRIDE" up -d --no-deps --force-recreate --pull never "$SERVICE"
phase='candidate_running'
wait_rpc || fail 'candidate did not reach RPC readiness'
docker inspect "$CONTAINER" | jq -S '.[0] | {path:.Path,args:.Args,
    entrypoint:.Config.Entrypoint,cmd:.Config.Cmd}' > "${EVIDENCE}/candidate-invocation.json"
cmp -s "${EVIDENCE}/baseline-invocation.json" "${EVIDENCE}/candidate-invocation.json" ||
    fail 'candidate effective entrypoint or command differs from the fleet invocation'

# Establish the immutable no-spend counter.  A clean q0 baseline must remain
# q0; for the exact inherited q1 exception, Core's full historical inventory
# must be authoritatively reclassified to q0 without a payment.  The wallet
# remains locked and staking/PoW remain disabled throughout either transition.
rpc getwalletinfo >"${EVIDENCE}/candidate-preactivation-wallet-initial.json"
rpc getstakinginfo >"${EVIDENCE}/candidate-preactivation-staking-initial.json"
rpc getpowmininginfo >"${EVIDENCE}/candidate-preactivation-pow-initial.json"
rpc listtransactions '*' 1000000 0 true | jq -S '[.[].txid] | unique | sort' \
    >"${EVIDENCE}/candidate-preactivation-transaction-txids.json"
jq -e '.private_keys_enabled == true and
    (.unlocked_until | type == "number" and . == 0)' \
    "${EVIDENCE}/candidate-preactivation-wallet-initial.json" >/dev/null ||
    fail 'candidate wallet was not locked before the no-spend counter baseline'
transaction_sets_match_exactly "${EVIDENCE}/prelaunch-transaction-txids.json" \
    "${EVIDENCE}/candidate-preactivation-transaction-txids.json" ||
    fail 'locked candidate startup added or lost a wallet transaction before activation'
LOCKED_CANDIDATE_TRANSACTION_SET_SHA=$(sha256sum \
    "${EVIDENCE}/candidate-preactivation-transaction-txids.json" | awk '{print $1}')
[[ "$LOCKED_CANDIDATE_TRANSACTION_SET_SHA" == "$PRELAUNCH_TRANSACTION_SET_SHA" ]] ||
    fail 'locked candidate wallet transaction-set hash differs from prelaunch'
automatic_wallet_features_are_off \
    "${EVIDENCE}/candidate-preactivation-staking-initial.json" \
    "${EVIDENCE}/candidate-preactivation-pow-initial.json" ||
    fail 'candidate automatic wallet features were enabled before activation'
candidate_staking_is_strictly_stopped \
    "${EVIDENCE}/candidate-preactivation-staking-initial.json" ||
    fail 'candidate staking was not disabled before inherited-claim normalization'
normalize_candidate_claim_state ||
    fail 'candidate did not preserve or reclassify the baseline claim state to exact q0 without payment'
rpc getwalletinfo >"${EVIDENCE}/candidate-recovery-baseline-wallet-locked.json"
rpc getstakinginfo >"${EVIDENCE}/candidate-recovery-baseline-staking-defaults.json"
rpc getpowmininginfo >"${EVIDENCE}/candidate-recovery-baseline-pow-defaults.json"
rpc getpowclaimrecoveryinfo true >"${EVIDENCE}/candidate-recovery-fee-baseline.json"
locked_recovery_counter_is_safe \
    "${EVIDENCE}/candidate-recovery-baseline-wallet-locked.json" \
    "${EVIDENCE}/candidate-recovery-fee-baseline.json" \
    "${EVIDENCE}/candidate-recovery-baseline-staking-defaults.json" \
    "${EVIDENCE}/candidate-recovery-baseline-pow-defaults.json" ||
    fail 'normalized candidate baseline is not locked, default-off, and q0'
candidate_staking_is_strictly_stopped \
    "${EVIDENCE}/candidate-recovery-baseline-staking-defaults.json" ||
    fail 'normalized candidate staking baseline is not disabled'
candidate_pow_is_strictly_stopped \
    "${EVIDENCE}/candidate-recovery-baseline-pow-defaults.json" ||
    fail 'normalized candidate PoW baseline is not strict disabled/hash0/q0'
[[ "$(jq -er '.confirmed_resolution_fees' \
    "${EVIDENCE}/candidate-recovery-fee-baseline.json")" == "$BASELINE_RECOVERY_FEE" ]] ||
    fail 'normalized candidate fee counter differs from the first locked authoritative sample'
publish_candidate_activation_marker 1 first-unlock ||
    fail 'could not durably mark first candidate signing activation before unlock'
phase='candidate_activation_1_attempted'
run_helper "$NORMAL_UNLOCK_HELPER" "$NORMAL_UNLOCK_HELPER_SHA" || fail 'candidate wallet unlock/staking activation failed'
require_claim_recovery_clean candidate-first || fail 'candidate recovery state is not clean without payment'
run_helper "$POW_START_HELPER" "$POW_START_HELPER_SHA" || fail 'candidate PoW activation failed'

[[ "$(docker exec "$CONTAINER" sha256sum /usr/local/bin/blackcoind | awk '{print $1}')" == "$BLACKCOIND_SHA" ]] || fail 'running daemon bytes mismatch'
[[ "$(docker exec "$CONTAINER" sha256sum /usr/local/bin/blackcoin-cli | awk '{print $1}')" == "$BLACKCOIN_CLI_SHA" ]] || fail 'running CLI bytes mismatch'

rpc getblockchaininfo >"${EVIDENCE}/candidate-blockchain-1.json"
rpc getnetworkinfo >"${EVIDENCE}/candidate-network-1.json"
rpc getwalletinfo >"${EVIDENCE}/candidate-wallet-1.json"
rpc getstakinginfo >"${EVIDENCE}/candidate-staking-1.json"
rpc getpowmininginfo >"${EVIDENCE}/candidate-pow-1.json"
rpc getgoldrushinfo >"${EVIDENCE}/candidate-goldrush-1.json"
rpc getgoldrushstate >"${EVIDENCE}/candidate-goldrush-state-1.json"
rpc getpowclaimrecoveryinfo >"${EVIDENCE}/candidate-recovery-1.json"
rpc getstakingdonationinfo >"${EVIDENCE}/candidate-legacy-donation.json"
rpc getqqdevelopmentdonationinfo >"${EVIDENCE}/candidate-qq-donation.json"
rpc validateaddress "$DEV_RECIPIENT" >"${EVIDENCE}/candidate-dev-recipient.json"
rpc listquantumaddresses | jq -S . >"${EVIDENCE}/candidate-quantum-addresses.json"
rpc getquantumkeyinventory | jq -S . >"${EVIDENCE}/candidate-quantum-inventory.json"
rpc listtransactions '*' 100000 0 true | jq -S '[.[].txid] | unique | sort' \
    >"${EVIDENCE}/candidate-transaction-txids.json"
jq -S '[.wallet_scripts[].address] | unique | sort' \
    "${EVIDENCE}/candidate-goldrush-1.json" >"${EVIDENCE}/candidate-legacy-addresses.json"
docker logs --since "$CANARY_STARTED" "$CONTAINER" >"${EVIDENCE}/candidate-startup-1.log" 2>&1

jq -e '.private_keys_enabled == true and .unlocked_staking_only == false and
    (.unlocked_until | type == "number" and . > now)' \
    "${EVIDENCE}/candidate-wallet-1.json" >/dev/null ||
    fail 'candidate wallet is not normally unlocked for active PoS/PoW validation'

candidate_network_is_ready "${EVIDENCE}/candidate-network-1.json" ||
    fail 'candidate network is not active with at least three outbound peers'
jq -e '.chain == "main" and .initialblockdownload == false and .headers >= .blocks and (.headers - .blocks) <= 2' \
    "${EVIDENCE}/candidate-blockchain-1.json" >/dev/null || fail 'candidate chain is not synced'
replay_state_matches_chain "${EVIDENCE}/candidate-blockchain-1.json" \
    "${EVIDENCE}/candidate-goldrush-state-1.json" ||
    fail 'candidate schema-12 replay marker is absent, invalid, or not exact for the active tip'
automatic_wallet_features_are_off "${EVIDENCE}/candidate-staking-1.json" \
    "${EVIDENCE}/candidate-pow-1.json" ||
    fail 'candidate enabled an automatic staking, QQ, redelegation, or quantum-key feature'
jq -e '.retired == true and .enabled == false and .percentage == 0 and .target_address == ""' "${EVIDENCE}/candidate-legacy-donation.json" >/dev/null || fail 'legacy development payments are not fully retired'
jq -e --arg recipient "$DEV_RECIPIENT" '.enabled == false and .percentage == 0 and .recipient == $recipient and .database_outcome_ambiguous == false' "${EVIDENCE}/candidate-qq-donation.json" >/dev/null || fail 'quantum development donation is not safely default-off'
jq -e '.isvalid == true and .iswitness == true and .witness_version == 16' "${EVIDENCE}/candidate-dev-recipient.json" >/dev/null || fail 'development recipient is not direct witness-v16 quantum'
jq -e '.policy_authoritative == true and .policy.automatic_authorized == false and
    .database_outcome_ambiguous == false and .chain_ready == true and
    .wallet_tip_matches == true and .blocking_quarantined_claims == 0 and
    .blocking_components == 0 and .indeterminate_quarantined_claims == 0 and
    .pending_manual_resolutions == 0 and .pending_automatic_resolutions == 0 and
    .active_tip != "0000000000000000000000000000000000000000000000000000000000000000" and
    .confirmed_resolution_fees == $fee' --argjson fee "$BASELINE_RECOVERY_FEE" \
    "${EVIDENCE}/candidate-recovery-1.json" >/dev/null ||
    fail 'claim-recovery state is not authoritative, clean, no-fee, and tip-pinned'
jq -e '.wallet_qqsignal as $signal |
    ($signal | type == "object") and
    ($signal.active | type == "boolean") and
    ($signal.status | type == "string" and test("^(none|mempool|confirmed|expired|superseded|reorg_removed)$")) and
    ($signal.txid | type == "string") and
    ($signal.signal_height | type == "number" and floor == . and . >= 0) and
    ($signal.activation_height == $signal.signal_height) and
    ($signal.expiry_height | type == "number" and floor == . and . >= 0) and
    ($signal.confirmations | type == "number" and floor == . and . >= 0) and
    ($signal.source | type == "string" and test("^(manual|automatic|unknown)$")) and
    ($signal.history | type == "array") and
    (if $signal.active then $signal.status == "confirmed" else true end)' \
    "${EVIDENCE}/candidate-goldrush-1.json" >/dev/null || fail 'wallet-scoped QQSIGNAL status is incoherent'
[[ "$(jq -r .bestblockhash "${EVIDENCE}/candidate-blockchain-1.json")" == "$(jq -r .active_tip "${EVIDENCE}/candidate-recovery-1.json")" ]] || fail 'claim-recovery active tip mismatch'
cmp -s "${EVIDENCE}/baseline-legacy-addresses.json" "${EVIDENCE}/candidate-legacy-addresses.json" || fail 'candidate changed the wallet-known legacy address set'
jq -e -s '((.[0] - .[1]) | length) == 0' \
    "${EVIDENCE}/baseline-transaction-txids.json" \
    "${EVIDENCE}/candidate-transaction-txids.json" >/dev/null || fail 'candidate lost pre-existing wallet transaction history'
[[ "$(sha256sum "${EVIDENCE}/candidate-quantum-addresses.json" | awk '{print $1}')" == "$QUANTUM_ADDRESSES_SHA" ]] || fail 'candidate created or changed a quantum address'
[[ "$(sha256sum "${EVIDENCE}/candidate-quantum-inventory.json" | awk '{print $1}')" == "$QUANTUM_INVENTORY_SHA" ]] || fail 'candidate changed the quantum-key inventory'
[[ "$(jq -c '[.keypoolsize,.keypoolsize_hd_internal] // []' "${EVIDENCE}/candidate-wallet-1.json")" == "$(jq -c '[.keypoolsize,.keypoolsize_hd_internal] // []' "${EVIDENCE}/baseline-wallet.json")" ]] || fail 'candidate changed the legacy keypool'
if grep -Eiq '(^|[^a-z])(reindexing|reindex-chainstate|reindex started|replay rebuild started|gold rush rewind)' \
    "${EVIDENCE}/candidate-startup-1.log"; then
    fail 'candidate unexpectedly initiated a reindex, replay rebuild, or Gold Rush rewind'
fi

staking_ok=0
for sample in $(seq 1 12); do
    rpc getstakinginfo >"${EVIDENCE}/candidate-staking-sample-${sample}.json"
    if jq -e '.enabled == true and .worker_running == true and .eligible == true and .staking_snapshot_current == true and .weight > 0 and .staking_state == "searching" and .automatic_qqsignal == false and .automatic_demurrage_attestation == false and .automatic_redelegation == false and .allow_automatic_quantum_key_creation == false' \
        "${EVIDENCE}/candidate-staking-sample-${sample}.json" >/dev/null; then
        staking_ok=$((staking_ok + 1))
    fi
    sleep 3
done
(( staking_ok >= 3 )) || fail 'candidate did not publish stable active staking samples'

pow_ok=0
for sample in $(seq 1 20); do
    rpc getpowmininginfo >"${EVIDENCE}/candidate-pow-sample-${sample}.json"
    if jq -e '.enabled == true and .autostart == false and
        (.state == "ready" or .state == "hashing") and
        (.threads | type == "number" and floor == . and . == 1) and
        (.cpu_percent | type == "number" and . == 1) and
        (.hashrate | type == "number" and . > 0) and
        (.unresolved_claims | type == "number" and floor == . and . == 0) and
        (.live_claims | type == "number" and floor == . and . == 0) and
        (.quarantined_claims | type == "number" and floor == . and . == 0) and
        (.blocking_quarantined_claims | type == "number" and floor == . and . == 0) and
        (.raw_quarantined_claims | type == "number" and floor == . and . >= 0) and
        .claim_recovery_database_outcome_ambiguous == false and
        .allow_automatic_quantum_key_creation == false' \
        "${EVIDENCE}/candidate-pow-sample-${sample}.json" >/dev/null; then
        install -m 600 -o root -g root \
            "${EVIDENCE}/candidate-pow-sample-${sample}.json" \
            "${EVIDENCE}/candidate-pow-clean-1.json"
        pow_ok=1
        break
    fi
    sleep 3
done
(( pow_ok == 1 )) || fail 'candidate PoW did not reach a clean hashing state'

# Revoke both signing paths, lock the wallet, and seal two fresh exact q0
# samples before restart. The next activation marker is written before the
# restart itself because startup is part of the second activation epoch.
quiesce_candidate_and_publish_safe 1 pre_restart ||
    fail 'candidate did not reach a durable locked safe boundary before restart'
publish_candidate_activation_marker 2 second-start-and-unlock ||
    fail 'could not durably mark second candidate activation before restart'
phase='candidate_activation_2_attempted'

# A second start proves an already-upgraded 30.x datadir is not repeatedly
# rewound or reindexed. This remains the same exact candidate and data.
FIRST_HEIGHT="$(jq -r .blocks "${EVIDENCE}/candidate-blockchain-1.json")"
RESTART_STARTED="$(date -u +%FT%TZ)"
docker restart -t 300 "$CONTAINER" >/dev/null
wait_rpc || fail 'candidate did not recover from the second start'
run_helper "$NORMAL_UNLOCK_HELPER" "$NORMAL_UNLOCK_HELPER_SHA" || fail 'second-start wallet unlock/staking activation failed'
require_claim_recovery_clean candidate-second ||
    fail 'second-start recovery state is not clean without payment'
run_helper "$POW_START_HELPER" "$POW_START_HELPER_SHA" || fail 'second-start PoW activation failed'
rpc getblockchaininfo >"${EVIDENCE}/candidate-blockchain-2.json"
rpc getnetworkinfo >"${EVIDENCE}/candidate-network-2.json"
rpc getwalletinfo >"${EVIDENCE}/candidate-wallet-2.json"
rpc getstakinginfo >"${EVIDENCE}/candidate-staking-2.json"
rpc getpowmininginfo >"${EVIDENCE}/candidate-pow-2.json"
rpc getgoldrushinfo >"${EVIDENCE}/candidate-goldrush-2.json"
rpc getgoldrushstate >"${EVIDENCE}/candidate-goldrush-state-2.json"
rpc listquantumaddresses | jq -S . >"${EVIDENCE}/candidate-quantum-addresses-2.json"
rpc getquantumkeyinventory | jq -S . >"${EVIDENCE}/candidate-quantum-inventory-2.json"
rpc listtransactions '*' 100000 0 true | jq -S '[.[].txid] | unique | sort' \
    >"${EVIDENCE}/candidate-transaction-txids-2.json"
jq -S '[.wallet_scripts[].address] | unique | sort' \
    "${EVIDENCE}/candidate-goldrush-2.json" >"${EVIDENCE}/candidate-legacy-addresses-2.json"
docker logs --since "$RESTART_STARTED" "$CONTAINER" >"${EVIDENCE}/candidate-startup-2.log" 2>&1
SECOND_HEIGHT="$(jq -r .blocks "${EVIDENCE}/candidate-blockchain-2.json")"
(( SECOND_HEIGHT + 1 >= FIRST_HEIGHT )) || fail 'second start rewound the active chain'
jq -e '.chain == "main" and .initialblockdownload == false and .headers >= .blocks and (.headers - .blocks) <= 2' \
    "${EVIDENCE}/candidate-blockchain-2.json" >/dev/null || fail 'second-start chain is not synced'
candidate_network_is_ready "${EVIDENCE}/candidate-network-2.json" ||
    fail 'second-start network is not active with at least three outbound peers'
jq -e '.private_keys_enabled == true and .unlocked_staking_only == false and
    (.unlocked_until | type == "number" and . > now)' \
    "${EVIDENCE}/candidate-wallet-2.json" >/dev/null ||
    fail 'second-start candidate wallet is not normally unlocked'
replay_state_matches_chain "${EVIDENCE}/candidate-blockchain-2.json" \
    "${EVIDENCE}/candidate-goldrush-state-2.json" ||
    fail 'second-start schema-12 replay marker is absent, invalid, or not exact for the active tip'
automatic_wallet_features_are_off "${EVIDENCE}/candidate-staking-2.json" \
    "${EVIDENCE}/candidate-pow-2.json" ||
    fail 'second start enabled an automatic staking, QQ, redelegation, or quantum-key feature'
if grep -Eiq '(^|[^a-z])(reindexing|reindex-chainstate|reindex started|replay rebuild started|gold rush rewind)' \
    "${EVIDENCE}/candidate-startup-2.log"; then
    fail 'second start unexpectedly initiated a reindex, replay rebuild, or Gold Rush rewind'
fi
[[ "$(sha256sum "${EVIDENCE}/candidate-quantum-addresses-2.json" | awk '{print $1}')" == "$QUANTUM_ADDRESSES_SHA" ]] || fail 'second start changed quantum addresses'
[[ "$(sha256sum "${EVIDENCE}/candidate-quantum-inventory-2.json" | awk '{print $1}')" == "$QUANTUM_INVENTORY_SHA" ]] || fail 'second start changed quantum-key inventory'
cmp -s "${EVIDENCE}/baseline-legacy-addresses.json" "${EVIDENCE}/candidate-legacy-addresses-2.json" || fail 'second start changed the wallet-known legacy address set'
jq -e -s '((.[0] - .[1]) | length) == 0' \
    "${EVIDENCE}/baseline-transaction-txids.json" \
    "${EVIDENCE}/candidate-transaction-txids-2.json" >/dev/null || fail 'second start lost pre-existing wallet transaction history'

second_staking_ok=0
for sample in $(seq 1 12); do
    rpc getstakinginfo >"${EVIDENCE}/candidate-staking-2-sample-${sample}.json"
    if jq -e '.enabled == true and .worker_running == true and .eligible == true and .staking_snapshot_current == true and .weight > 0 and .staking_state == "searching" and .automatic_qqsignal == false and .automatic_demurrage_attestation == false and .automatic_redelegation == false and .allow_automatic_quantum_key_creation == false' \
        "${EVIDENCE}/candidate-staking-2-sample-${sample}.json" >/dev/null; then
        second_staking_ok=$((second_staking_ok + 1))
    fi
    sleep 3
done
(( second_staking_ok >= 3 )) || fail 'second start did not publish stable active staking samples'

second_pow_ok=0
for sample in $(seq 1 20); do
    rpc getpowmininginfo >"${EVIDENCE}/candidate-pow-2-sample-${sample}.json"
    if jq -e '.enabled == true and .autostart == false and
        (.state == "ready" or .state == "hashing") and
        (.threads | type == "number" and floor == . and . == 1) and
        (.cpu_percent | type == "number" and . == 1) and
        (.hashrate | type == "number" and . > 0) and
        (.unresolved_claims | type == "number" and floor == . and . == 0) and
        (.live_claims | type == "number" and floor == . and . == 0) and
        (.quarantined_claims | type == "number" and floor == . and . == 0) and
        (.blocking_quarantined_claims | type == "number" and floor == . and . == 0) and
        (.raw_quarantined_claims | type == "number" and floor == . and . >= 0) and
        .claim_recovery_database_outcome_ambiguous == false and
        .allow_automatic_quantum_key_creation == false' \
        "${EVIDENCE}/candidate-pow-2-sample-${sample}.json" >/dev/null; then
        install -m 600 -o root -g root \
            "${EVIDENCE}/candidate-pow-2-sample-${sample}.json" \
            "${EVIDENCE}/candidate-pow-clean-2.json"
        second_pow_ok=1
        break
    fi
    sleep 3
done
(( second_pow_ok == 1 )) || fail 'second start PoW did not reach a clean hashing state'

# Revoke staking and PoW, lock the wallet, and seal the exact q0/transaction/
# fee boundary before any candidate stop or ZFS rollback is permitted.
quiesce_candidate_and_publish_safe 2 pre_rollback ||
    fail 'second-start candidate did not reach a durable safe rollback boundary'

restore_original || fail 'candidate passed but rollback to the original node failed'
phase='restored'

[[ "$pre_upgrade_data_restored" == true && "$snapshot_identity_verified" == true &&
   "$snapshot_zero_diff_verified" == true ]] ||
    fail 'pre-upgrade data restoration proof is incomplete'
validate_candidate_launch_marker || fail 'candidate launch-attempt journal changed before publication'
[[ "$(sha256sum "$CANDIDATE_LAUNCH_MARKER" | awk '{print $1}')" == \
   "$CANDIDATE_LAUNCH_MARKER_SHA" ]] || fail 'candidate launch-attempt journal hash changed'
release_snapshot_holds || fail 'could not release all transaction-specific ZFS holds after verified rollback'
restore_guard_starts || fail 'could not restore automatic-start authority after verified rollback'
[[ "$candidate_launch_attempted" == 1 && "$snapshot_holds_released" == true &&
   "$start_authority_suspended" == 0 ]] || fail 'canary completion state is incomplete'
publish_maintenance_handoff_ready ||
    fail 'could not seal active canary maintenance for authenticated fleet handoff'
[[ "$maintenance_handoff_ready" == true &&
   -f "$ROLLOUT_MAINTENANCE_MARKER" && ! -L "$ROLLOUT_MAINTENANCE_MARKER" &&
   "$(cat "$CANARY_STATE")" == active ]] ||
    fail 'active canary maintenance handoff proof is incomplete'
[[ "$RESTORED_LEGACY_LIVE_CLAIMS" == "$LEGACY_BASELINE_LIVE_CLAIMS" &&
   "$RESTORED_LEGACY_QUARANTINED_CLAIMS" == "$LEGACY_BASELINE_QUARANTINED_CLAIMS" ]] ||
    fail 'restored legacy PoW claim counts differ from the pre-upgrade baseline'
[[ -n "$LAST_CONFIRMED_RECOVERY_FEE" &&
   "$LAST_CONFIRMED_RECOVERY_FEE" == "$BASELINE_RECOVERY_FEE" ]] ||
    fail 'final candidate claim-recovery fee does not match its locked baseline'

jq -n \
    --argjson schema 1 \
    --argjson node 27 \
    --arg result 'passed' \
    --arg source_sha "$SOURCE_SHA" \
    --arg candidate_mode "$CANDIDATE_MODE" \
    --arg candidate_image "$CANDIDATE_IMAGE" \
    --arg candidate_image_id "$CANDIDATE_IMAGE_ID" \
    --arg stamp "$STAMP" \
    --arg dev_recipient "$DEV_RECIPIENT" \
    --arg snapshot "$SNAP" \
    --arg snapshot_identity_sha "$SNAPSHOT_IDENTITY_SHA" \
    --arg snapshot_restore_proof_sha "$SNAPSHOT_RESTORE_PROOF_SHA" \
    --arg launch_marker_sha "$CANDIDATE_LAUNCH_MARKER_SHA" \
    --arg prelaunch_transaction_set_sha "$PRELAUNCH_TRANSACTION_SET_SHA" \
    --arg locked_candidate_transaction_set_sha "$LOCKED_CANDIDATE_TRANSACTION_SET_SHA" \
    --arg legacy_observed_pow_mode "$LEGACY_OBSERVED_POW_MODE" \
    --arg legacy_baseline_pow_mode "$LEGACY_BASELINE_POW_MODE" \
    --arg inherited_claim_inventory_sha "$INHERITED_CLAIM_INVENTORY_SHA" \
    --arg inherited_claim_transition_sha "$INHERITED_CLAIM_TRANSITION_SHA" \
    --arg maintenance_marker "$ROLLOUT_MAINTENANCE_MARKER" \
    --arg maintenance_run_dir "$OPS" \
    --arg maintenance_nonce_sha "$MAINTENANCE_NONCE_SHA" \
    --arg maintenance_activation_sha "$MAINTENANCE_MARKER_ACTIVATION_SHA" \
    --arg recovery_procedure_sha "$RECOVERY_PROCEDURE_SHA" \
    --arg maintenance_active_state_sha "$MAINTENANCE_ACTIVE_STATE_SHA" \
    --arg guard_identities_sha "$GUARD_IDENTITIES_SHA" \
    --arg candidate_activation_1_sha "$CANDIDATE_ACTIVATION_MARKER_1_SHA" \
    --arg candidate_activation_2_sha "$CANDIDATE_ACTIVATION_MARKER_2_SHA" \
    --arg candidate_safe_1_sha "$CANDIDATE_SAFE_MARKER_1_SHA" \
    --arg candidate_safe_2_sha "$CANDIDATE_SAFE_MARKER_2_SHA" \
    --arg maintenance_handoff_ready_sha "$MAINTENANCE_HANDOFF_READY_SHA" \
    --arg wallet_runtime_guard_sha "$WALLET_RUNTIME_GUARD_SHA" \
    --arg endpoint_guard_sha "$ENDPOINT_GUARD_SHA" \
    --arg hold_tag "$ZFS_HOLD_TAG" \
    --arg datadir_snapshot "${EXPECTED_DATADIR_DATASET}@${SNAP}" \
    --arg blocks_snapshot "${EXPECTED_BLOCKS_DATASET}@${SNAP}" \
    --arg indexes_snapshot "${EXPECTED_INDEXES_DATASET}@${SNAP}" \
    --arg raw_snapshot "${EXPECTED_RAW_DATASET}@${SNAP}" \
    --argjson snapshot_count "$SNAPSHOT_COUNT" \
    --argjson first_height "$FIRST_HEIGHT" \
    --argjson second_height "$SECOND_HEIGHT" \
    --argjson staking_samples "$staking_ok" \
    --argjson legacy_baseline_live_claims "$LEGACY_BASELINE_LIVE_CLAIMS" \
    --argjson legacy_baseline_quarantined_claims "$LEGACY_BASELINE_QUARANTINED_CLAIMS" \
    --argjson restored_legacy_live_claims "$RESTORED_LEGACY_LIVE_CLAIMS" \
    --argjson restored_legacy_quarantined_claims "$RESTORED_LEGACY_QUARANTINED_CLAIMS" \
    --argjson claim_recovery_fee_baseline "$BASELINE_RECOVERY_FEE" \
    --argjson claim_recovery_fee_final "$LAST_CONFIRMED_RECOVERY_FEE" \
    '{schema:$schema,node:$node,result:$result,source_sha:$source_sha,candidate_mode:$candidate_mode,
      candidate_image:$candidate_image,candidate_image_id:$candidate_image_id,
      timestamp:$stamp,development_recipient:$dev_recipient,
      zfs_snapshot_suffix:$snapshot,first_height:$first_height,
      zfs_snapshot_count:$snapshot_count,
      zfs_snapshot_identity_sha256:$snapshot_identity_sha,
      zfs_snapshot_restore_proof_sha256:$snapshot_restore_proof_sha,
      candidate_launch_marker:"CANDIDATE-LAUNCH-ATTEMPTED.json",
      candidate_launch_marker_sha256:$launch_marker_sha,zfs_hold_tag:$hold_tag,
      zfs_snapshots:[$datadir_snapshot,$blocks_snapshot,$indexes_snapshot,$raw_snapshot],
      second_height:$second_height,active_staking_samples:$staking_samples,
      rolled_back_to:"30.1.3",same_effective_entrypoint:true,
      fee_payments_authorized:false,claim_recovery_fee_unchanged:true,
      claim_recovery_fee_baseline:$claim_recovery_fee_baseline,
      claim_recovery_fee_final:$claim_recovery_fee_final,
      legacy_observed_pow_mode:$legacy_observed_pow_mode,
      legacy_baseline_pow_mode:$legacy_baseline_pow_mode,
      legacy_baseline_live_claims:$legacy_baseline_live_claims,
      legacy_baseline_quarantined_claims:$legacy_baseline_quarantined_claims,
      restored_legacy_live_claims:$restored_legacy_live_claims,
      restored_legacy_quarantined_claims:$restored_legacy_quarantined_claims,
      legacy_quarantined_claim_count_preserved:true,
      legacy_quarantined_claim_resolution_attempted:false,
      legacy_quarantined_claim_fee_paid:false,
      inherited_claim_inventory_present:
        ($legacy_baseline_pow_mode == "quarantined-disabled"),
      inherited_claim_inventory_evidence:
        (if $legacy_baseline_pow_mode == "quarantined-disabled" then
           "candidate-inherited-claim-inventory.json" else null end),
      inherited_claim_inventory_sha256:
        (if $legacy_baseline_pow_mode == "quarantined-disabled" then
           $inherited_claim_inventory_sha else null end),
      inherited_claim_transition_evidence:"candidate-inherited-claim-transition.json",
      inherited_claim_transition_sha256:$inherited_claim_transition_sha,
      claim_baseline_transition_kind:
        (if $legacy_baseline_pow_mode == "quarantined-disabled" then
           "legacy_q1_to_candidate_q0_no_payment"
         else "clean_q0_to_candidate_q0_no_payment" end),
      legacy_q1_candidate_q0_no_payment_reclassification_verified:
        ($legacy_baseline_pow_mode == "quarantined-disabled"),
      clean_q0_candidate_q0_no_payment_transition_verified:
        ($legacy_baseline_pow_mode == "clean-hashing"),
      candidate_pow_clean_hashing_verified:true,
      recovery_fee_baseline_established_while_wallet_locked:true,
      locked_candidate_transaction_set_unchanged:true,
      prelaunch_transaction_set_sha256:$prelaunch_transaction_set_sha,
      locked_candidate_transaction_set_sha256:$locked_candidate_transaction_set_sha,
      maintenance:{schema:1,transaction:"v30.1.4-node27-canary",
        marker:$maintenance_marker,run_dir:$maintenance_run_dir,state:"active",
        run_nonce_sha256:$maintenance_nonce_sha,
        marker_activation_evidence:"maintenance-marker-activated.json",
        marker_activation_sha256:$maintenance_activation_sha,
        active_state_evidence:"maintenance-state-active.txt",
        active_state_evidence_sha256:$maintenance_active_state_sha,
        crash_recovery_procedure:"crash-recovery-procedure.json",
        crash_recovery_procedure_sha256:$recovery_procedure_sha,
        guard_identity_evidence:"maintenance-compatible-guard-identities.tsv",
        guard_identity_evidence_sha256:$guard_identities_sha,
        candidate_activation_markers:[
          {sequence:1,file:"candidate-activation-attempted-01.json",sha256:$candidate_activation_1_sha},
          {sequence:2,file:"candidate-activation-attempted-02.json",sha256:$candidate_activation_2_sha}],
        candidate_safe_markers:[
          {sequence:1,purpose:"pre_restart",file:"candidate-safe-boundary-01.json",sha256:$candidate_safe_1_sha},
          {sequence:2,purpose:"pre_rollback",file:"candidate-safe-boundary-02.json",sha256:$candidate_safe_2_sha}],
        handoff_ready_evidence:"maintenance-handoff-ready.json",
        handoff_ready_sha256:$maintenance_handoff_ready_sha,
        executable_recovery:false,recovery_mode:"manual-audited-only",
        wallet_runtime_guard_sha256:$wallet_runtime_guard_sha,
        endpoint_guard_sha256:$endpoint_guard_sha,
        activated_before_node_mutation:true,retained_on_failure:true,
        marker_released:false,live_marker_active:true,
        automatic_start_authority_restored:true,
        maintenance_handoff_ready:true},
      automatic_wallet_features_default_off_verified:true,
      candidate_network_ready_verified:true,replay_marker_exact_tip_verified:true,
      wallet_identity_unchanged:true,configuration_identity_unchanged:true,
      reindex_observed:false,reindex_or_replay_rebuild_observed:false,
      pre_upgrade_data_restored:true,
      snapshot_identity_verified:true,snapshot_zero_diff_verified:true,
      candidate_launch_attempted:true,zfs_snapshot_holds_released:true,
      automatic_start_authority_restored:true,
      maintenance_marker_activated:true,maintenance_marker_released:false,
      live_marker_active:true,maintenance_handoff_ready:true,
      crash_safe_supervisor_inhibition_verified:true,
      rollback_verified:true}' \
    >"${EVIDENCE}/RESULT.json"

candidate_claim_result_mode_is_valid "${EVIDENCE}/RESULT.json" ||
    fail 'final canary result does not authenticate its baseline claim-state mode'
if [[ "$LEGACY_BASELINE_POW_MODE" == clean-hashing ]]; then
    [[ ! -e "${EVIDENCE}/candidate-inherited-claim-inventory.json" &&
       ! -L "${EVIDENCE}/candidate-inherited-claim-inventory.json" ]] ||
        fail 'clean q0 canary fabricated inherited legacy claim-inventory evidence'
fi

validate_canary_maintenance_marker ||
    fail 'active maintenance marker changed before final evidence sealing'
[[ "$(cat "$CANARY_STATE")" == active ]] ||
    fail 'canary STATE changed before final evidence sealing'
chmod 600 "${EVIDENCE}"/*
chown root:root "${EVIDENCE}"/*
manifest_tmp=$(mktemp "${OPS}/.canary-evidence-sha256.XXXXXX")
(
    cd "$EVIDENCE"
    find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum
) > "$manifest_tmp"
chmod 600 "$manifest_tmp"
chown root:root "$manifest_tmp"
mv -fT -- "$manifest_tmp" "${EVIDENCE}/SHA256SUMS"
(cd "$EVIDENCE" && sha256sum --strict -c SHA256SUMS >/dev/null) ||
    fail 'canary evidence checksum verification failed'
sync -f "${EVIDENCE}/SHA256SUMS"
sync -f "$EVIDENCE"
validate_canary_maintenance_marker ||
    fail 'active maintenance marker changed during final evidence sealing'
[[ "$(cat "$CANARY_STATE")" == active && "$maintenance_handoff_ready" == true ]] ||
    fail 'active handoff state changed during final evidence sealing'

result='passed'
echo "CANARY_PASS_HANDOFF_READY source=${SOURCE_SHA} evidence=${EVIDENCE} marker=${ROLLOUT_MAINTENANCE_MARKER}"
