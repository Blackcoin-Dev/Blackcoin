#!/usr/bin/env bash
set -Eeuo pipefail

umask 077

SOURCE_SHA='13262151077cce3f72d07d17dc7725b2b6a8e1ab'
BLACKCOIND_SHA='8fd6e3c6a1802ea26e4447e09f24355a2abd10c45987923c8306a80031d9407e'
BLACKCOIN_CLI_SHA='58e4a125d5ebcaa9a18116c3b21bc6cd1f1d034df88dc6feb924fa75af3f395a'
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
MAINTENANCE_NONCE="${OPS}/MAINTENANCE-NONCE"
CANARY_STATE="${OPS}/STATE"
CANARY_RECOVERY_PROCEDURE="${OPS}/CRASH-RECOVERY.json"

phase='preflight'
result='failed'
candidate_launch_attempted=0
start_authority_suspended=0
maintenance_marker_activated=0
maintenance_marker_released=false
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
MAINTENANCE_MARKER_RELEASE_SHA=''
RECOVERY_PROCEDURE_SHA=''
MAINTENANCE_ACTIVE_STATE_SHA=''
MAINTENANCE_COMPLETE_STATE_SHA=''
GUARD_IDENTITIES_SHA=''
SNAPSHOT_COUNT=0
POW_DRAIN_SEQUENCE=0

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
           "Disable container restart. If a candidate is running and RPC is safe, stop PoW and require a claim-clean boundary; otherwise contain it without unlocking or fee-paying recovery, then stop it.",
           "When candidate launch was attempted, validate the exact four held snapshot identities, roll back children before parents with plain zfs rollback only, and require zero zfs diff for every dataset. Never use recursive, destructive, or forced rollback flags.",
           "Recreate node27 only from the pinned base Compose model and original immutable image, then run only the pinned normal-unlock and PoW helpers.",
           "Prove the original image and invocation, healthy RPC/network/chain, active PoS, clean one-thread PoW, wallet/config/address/key/transaction identity, and exact pre-upgrade data restoration.",
           "Release transaction-specific snapshot holds, restore ENABLE_GUARD_STARTS, and prove both supervisor guard bytes are still pinned.",
           "Only after every prior proof succeeds may recovery unlink and sync the maintenance marker, atomically set STATE to complete, and publish release evidence. Any uncertainty leaves marker and STATE active."
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

release_canary_maintenance_marker()
{
    local state_tmp release_tmp
    [[ "$phase" == restored && "$pre_upgrade_data_restored" == true &&
       "$restored_runtime_verified" == true &&
       "$snapshot_identity_verified" == true && "$snapshot_zero_diff_verified" == true &&
       "$snapshot_holds_released" == true && "$start_authority_suspended" == 0 &&
       "$maintenance_marker_activated" == 1 ]] || return 1
    verify_rollback_image_ready || return 1
    verify_guard_compatibility || return 1
    [[ "$(sha256sum "${EVIDENCE}/maintenance-compatible-guard-identities.tsv" | awk '{print $1}')" == "$GUARD_IDENTITIES_SHA" ]] ||
        return 1
    validate_canary_maintenance_marker || return 1
    assert_empty_control_marker "$ENABLE_GUARD_STARTS" || return 1
    [[ ! -e "$SUSPENDED_START_MARKER" && ! -L "$SUSPENDED_START_MARKER" ]] || return 1
    local attempt health_ready=false
    for attempt in $(seq 1 120); do
        if docker inspect "$CONTAINER" | jq -e --arg image "$ORIGINAL_IMAGE" \
            --arg image_id "$ORIGINAL_IMAGE_ID" 'length == 1 and
            .[0].Config.Image == $image and .[0].Image == $image_id and
            .[0].State.Running == true and .[0].State.Health.Status == "healthy"' \
            >/dev/null 2>&1; then
            health_ready=true
            break
        fi
        sleep 2
    done
    [[ "$health_ready" == true ]] || return 1

    state_tmp=$(mktemp "${OPS}/.canary-state-complete.XXXXXX") || return 1
    printf '%s\n' complete > "$state_tmp" || return 1
    chmod 600 "$state_tmp" || return 1
    chown root:root "$state_tmp" || return 1
    sync -f "$state_tmp" || return 1
    MAINTENANCE_COMPLETE_STATE_SHA=$(sha256sum "$state_tmp" | awk '{print $1}') || return 1
    [[ "$MAINTENANCE_COMPLETE_STATE_SHA" =~ ^[0-9a-f]{64}$ ]] || return 1
    release_tmp=$(mktemp "${OPS}/.maintenance-marker-release.XXXXXX") || return 1
    jq -n --arg marker "$ROLLOUT_MAINTENANCE_MARKER" --arg run "$OPS" \
        --arg nonce_sha "$MAINTENANCE_NONCE_SHA" \
        --arg activation_sha "$MAINTENANCE_MARKER_ACTIVATION_SHA" \
        --arg recovery_sha "$RECOVERY_PROCEDURE_SHA" \
        --arg active_state_sha "$MAINTENANCE_ACTIVE_STATE_SHA" \
        --arg complete_state_sha "$MAINTENANCE_COMPLETE_STATE_SHA" \
        --arg guard_identities_sha "$GUARD_IDENTITIES_SHA" \
        --arg runtime_guard_sha "$WALLET_RUNTIME_GUARD_SHA" \
        --arg endpoint_guard_sha "$ENDPOINT_GUARD_SHA" \
        --arg timestamp "$(date -u +%FT%TZ)" \
        '{schema:1,transaction:"v30.1.4-node27-canary",marker:$marker,
          run_dir:$run,run_nonce_sha256:$nonce_sha,
          marker_activation_sha256:$activation_sha,marker_released:true,
          crash_recovery_procedure_sha256:$recovery_sha,
          active_state_evidence_sha256:$active_state_sha,
          complete_state_evidence_sha256:$complete_state_sha,
          guard_identity_evidence_sha256:$guard_identities_sha,
          wallet_runtime_guard_sha256:$runtime_guard_sha,
          endpoint_guard_sha256:$endpoint_guard_sha,
          pre_upgrade_data_restored:true,old_container_runtime_verified:true,
          automatic_start_authority_restored:true,state_after_release:"complete",
          timestamp:$timestamp}' > "$release_tmp" || return 1
    chmod 600 "$release_tmp" || return 1
    chown root:root "$release_tmp" || return 1
    sync -f "$release_tmp" || return 1

    rm -f -- "$ROLLOUT_MAINTENANCE_MARKER" || return 1
    sync -f "$STATE_ROOT" || return 1
    [[ ! -e "$ROLLOUT_MAINTENANCE_MARKER" && ! -L "$ROLLOUT_MAINTENANCE_MARKER" ]] ||
        return 1
    mv -fT -- "$state_tmp" "$CANARY_STATE" || return 1
    sync -f "$CANARY_STATE" || return 1
    sync -f "$OPS" || return 1
    protected_root_file_0600 "$CANARY_STATE" && [[ "$(cat "$CANARY_STATE")" == complete ]] ||
        return 1
    mv -fT -- "$release_tmp" "${EVIDENCE}/maintenance-marker-released.json" || return 1
    sync -f "${EVIDENCE}/maintenance-marker-released.json" || return 1
    install -m 600 -o root -g root "$CANARY_STATE" \
        "${EVIDENCE}/maintenance-state-complete.txt" || return 1
    sync -f "${EVIDENCE}/maintenance-state-complete.txt" || return 1
    sync -f "$EVIDENCE" || return 1
    MAINTENANCE_MARKER_RELEASE_SHA=$(sha256sum \
        "${EVIDENCE}/maintenance-marker-released.json" | awk '{print $1}') || return 1
    [[ "$MAINTENANCE_MARKER_RELEASE_SHA" =~ ^[0-9a-f]{64}$ &&
       "$(sha256sum "${EVIDENCE}/maintenance-state-complete.txt" | awk '{print $1}')" == "$MAINTENANCE_COMPLETE_STATE_SHA" ]] ||
        return 1
    maintenance_marker_released=true
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
            return 0
        fi
        echo 'blocking claim recovery is present; no-spend canary refuses resolution' >&2
        return 1
    done
    echo 'wallet/chain claim-recovery tips did not converge within 20 minutes' >&2
    return 1
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

restored_runtime_is_ready()
{
    local chain_file="$1" mining_file="$2"
    jq -e '
        .chain == "main" and .initialblockdownload == false and
        (.headers | type == "number" and floor == .) and
        (.blocks | type == "number" and floor == .) and
        .headers >= .blocks and (.headers - .blocks) <= 2
    ' "$chain_file" >/dev/null &&
        jq -e '
            .enabled == true and .threads == 1 and .hashrate > 0 and
            (.live_claims | type == "number" and floor == . and . == 0) and
            (.quarantined_claims | type == "number" and floor == . and . == 0)
        ' "$mining_file" >/dev/null
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
        if jq -e '(.quarantined_claims | type == "number" and . > 0)' \
            "$mining" >/dev/null; then
            echo 'restored 30.1.3 node reports quarantined PoW claims' >&2
            return 1
        fi
        if restored_runtime_is_ready "$chain" "$mining"; then
            install -m 600 -o root -g root "$chain" "${EVIDENCE}/restored-blockchain.json" ||
                return 1
            install -m 600 -o root -g root "$mining" "${EVIDENCE}/restored-pow.json" ||
                return 1
            return 0
        fi
        sleep 5
    done
    echo 'restored 30.1.3 chain and PoW did not converge within 20 minutes' >&2
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

stop_candidate_for_restore()
{
    local attempt stop_mode='already-stopped' was_running=0
    if [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)" == true ]]; then
        was_running=1
        if rpc getblockchaininfo >/dev/null 2>&1; then
            stop_and_drain_candidate_pow || return 1
            stop_mode='rpc-stop'
            rpc stop >/dev/null 2>&1 || true
            for attempt in $(seq 1 180); do
                [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)" != true ]] && break
                sleep 1
            done
        fi
        if [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)" == true ]]; then
            stop_mode='docker-stop'
            timeout --kill-after=30 360 docker stop -t 300 "$CONTAINER" >/dev/null || return 1
        fi
    fi
    [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)" != true ]] || return 1
    (( was_running == 0 )) || assert_container_cleanly_stopped || return 1
    printf '%s\n' "$stop_mode" > "${EVIDENCE}/candidate-restore-stop-mode.txt"
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
    elif guard_starts_are_suspended; then
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
    local restore_rc=0
    if (( candidate_launch_attempted == 1 )) ||
       [[ -e "$CANDIDATE_LAUNCH_MARKER" || -L "$CANDIDATE_LAUNCH_MARKER" ]]; then
        validate_candidate_launch_marker || {
            echo 'Durable candidate-launch marker is absent, unsafe, or inconsistent.' >&2
            contain_node
            return 1
        }
        candidate_launch_attempted=1
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
        run_helper "$NORMAL_UNLOCK_HELPER" "$NORMAL_UNLOCK_HELPER_SHA" || restore_rc=1
        run_helper "$POW_START_HELPER" "$POW_START_HELPER_SHA" || restore_rc=1
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
    (( maintenance_marker_activated == 0 )) || [[ "$maintenance_marker_released" == true ]]
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

exec 5>/run/blackcoin-endpoint-guard.lock
flock -w 1800 5 || fail 'endpoint guard did not drain within 30 minutes; no state was changed'
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
jq -e '.enabled == true and .threads == 1 and .hashrate > 0 and .live_claims == 0 and .quarantined_claims == 0' "${EVIDENCE}/baseline-pow.json" >/dev/null || fail 'baseline PoW is not clean and hashing'

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
if ! stop_and_drain_candidate_pow; then
    run_helper "$POW_START_HELPER" "$POW_START_HELPER_SHA" || true
    fail 'original node could not reach a no-spend claim-clean stop boundary'
fi
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

# Establish the immutable no-spend counter before granting the candidate any
# wallet signing authority.  The fresh process must still be locked, PoW is
# explicitly drained, every automatic wallet feature is default-off, and both
# manual and automatic managed-resolution queues are empty.  This prevents a
# startup-created fee from being absorbed into the canary's baseline.
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
stop_and_drain_candidate_pow ||
    fail 'candidate could not reach a locked, claim-clean pre-activation boundary'

BASELINE_RECOVERY_FEE=''
for attempt in $(seq 1 240); do
    candidate_recovery_file="${EVIDENCE}/candidate-preactivation-recovery-${attempt}.json"
    candidate_wallet_file="${EVIDENCE}/candidate-preactivation-wallet-${attempt}.json"
    candidate_staking_file="${EVIDENCE}/candidate-preactivation-staking-${attempt}.json"
    candidate_pow_file="${EVIDENCE}/candidate-preactivation-pow-${attempt}.json"
    if ! rpc getpowclaimrecoveryinfo true >"$candidate_recovery_file" 2>/dev/null ||
       ! rpc getwalletinfo >"$candidate_wallet_file" 2>/dev/null; then
        sleep 5
        continue
    fi
    jq -e '.private_keys_enabled == true and
        (.unlocked_until | type == "number" and . == 0)' \
        "$candidate_wallet_file" >/dev/null ||
        fail 'candidate wallet gained signing authority before the no-spend baseline'
    jq -e '.policy_authoritative == true and .policy.automatic_authorized == false and
        .database_outcome_ambiguous == false' "$candidate_recovery_file" >/dev/null ||
        fail 'candidate recovery policy is ambiguous or authorizes automatic fee payments'
    if jq -e '.chain_ready == true and .wallet_tip_matches == true' \
        "$candidate_recovery_file" >/dev/null; then
        rpc getstakinginfo >"$candidate_staking_file"
        rpc getpowmininginfo >"$candidate_pow_file"
        locked_recovery_counter_is_safe "$candidate_wallet_file" \
            "$candidate_recovery_file" "$candidate_staking_file" "$candidate_pow_file" ||
            fail 'candidate locked no-spend counter baseline is not clean and default-off'
        BASELINE_RECOVERY_FEE=$(jq -er '.confirmed_resolution_fees' "$candidate_recovery_file")
        install -m 600 -o root -g root "$candidate_wallet_file" \
            "${EVIDENCE}/candidate-recovery-baseline-wallet-locked.json"
        install -m 600 -o root -g root "$candidate_recovery_file" \
            "${EVIDENCE}/candidate-recovery-fee-baseline.json"
        install -m 600 -o root -g root "$candidate_staking_file" \
            "${EVIDENCE}/candidate-recovery-baseline-staking-defaults.json"
        install -m 600 -o root -g root "$candidate_pow_file" \
            "${EVIDENCE}/candidate-recovery-baseline-pow-defaults.json"
        break
    fi
    sleep 5
done
[[ -n "$BASELINE_RECOVERY_FEE" ]] ||
    fail 'locked candidate recovery baseline did not become ready within 20 minutes'

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
    if jq -e '.enabled == true and .threads == 1 and .cpu_percent == 1 and .hashrate > 0 and .live_claims == 0 and .quarantined_claims == 0 and .blocking_quarantined_claims == 0 and .raw_quarantined_claims >= 0 and .claim_recovery_database_outcome_ambiguous == false and .allow_automatic_quantum_key_creation == false' \
        "${EVIDENCE}/candidate-pow-sample-${sample}.json" >/dev/null; then
        pow_ok=1
        break
    fi
    sleep 3
done
(( pow_ok == 1 )) || fail 'candidate PoW did not reach a clean hashing state'

# Stop the canary miner and drain any proof it found before restart so a
# legitimate live single-flight claim cannot be mistaken for a startup fault.
stop_and_drain_candidate_pow || fail 'candidate PoW did not reach a clean restart boundary'
require_claim_recovery_clean candidate-pre-restart ||
    fail 'candidate recovery fees or claim state changed before restart'

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
    if jq -e '.enabled == true and .threads == 1 and .cpu_percent == 1 and .hashrate > 0 and .live_claims == 0 and .quarantined_claims == 0 and .blocking_quarantined_claims == 0 and .raw_quarantined_claims >= 0 and .claim_recovery_database_outcome_ambiguous == false and .allow_automatic_quantum_key_creation == false' \
        "${EVIDENCE}/candidate-pow-2-sample-${sample}.json" >/dev/null; then
        second_pow_ok=1
        break
    fi
    sleep 3
done
(( second_pow_ok == 1 )) || fail 'second start PoW did not reach a clean hashing state'

# Prove a claim-clean boundary before crossing back to v30.1.3.  The rollback
# helper repeats this check defensively if a later step fails.
stop_and_drain_candidate_pow || fail 'second-start PoW did not drain before rollback'
require_claim_recovery_clean candidate-pre-rollback ||
    fail 'candidate recovery fees or claim state changed before rollback'

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
release_canary_maintenance_marker ||
    fail 'could not durably release canary maintenance after verified restoration'
[[ "$maintenance_marker_released" == true &&
   ! -e "$ROLLOUT_MAINTENANCE_MARKER" && ! -L "$ROLLOUT_MAINTENANCE_MARKER" &&
   "$(cat "$CANARY_STATE")" == complete ]] ||
    fail 'canary maintenance release proof is incomplete'

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
    --arg maintenance_marker "$ROLLOUT_MAINTENANCE_MARKER" \
    --arg maintenance_run_dir "$OPS" \
    --arg maintenance_nonce_sha "$MAINTENANCE_NONCE_SHA" \
    --arg maintenance_activation_sha "$MAINTENANCE_MARKER_ACTIVATION_SHA" \
    --arg maintenance_release_sha "$MAINTENANCE_MARKER_RELEASE_SHA" \
    --arg recovery_procedure_sha "$RECOVERY_PROCEDURE_SHA" \
    --arg maintenance_active_state_sha "$MAINTENANCE_ACTIVE_STATE_SHA" \
    --arg maintenance_complete_state_sha "$MAINTENANCE_COMPLETE_STATE_SHA" \
    --arg guard_identities_sha "$GUARD_IDENTITIES_SHA" \
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
      recovery_fee_baseline_established_while_wallet_locked:true,
      locked_candidate_transaction_set_unchanged:true,
      prelaunch_transaction_set_sha256:$prelaunch_transaction_set_sha,
      locked_candidate_transaction_set_sha256:$locked_candidate_transaction_set_sha,
      maintenance:{schema:1,transaction:"v30.1.4-node27-canary",
        marker:$maintenance_marker,run_dir:$maintenance_run_dir,state:"complete",
        run_nonce_sha256:$maintenance_nonce_sha,
        marker_activation_evidence:"maintenance-marker-activated.json",
        marker_activation_sha256:$maintenance_activation_sha,
        active_state_evidence:"maintenance-state-active.txt",
        active_state_evidence_sha256:$maintenance_active_state_sha,
        marker_release_evidence:"maintenance-marker-released.json",
        marker_release_sha256:$maintenance_release_sha,
        complete_state_evidence:"maintenance-state-complete.txt",
        complete_state_evidence_sha256:$maintenance_complete_state_sha,
        crash_recovery_procedure:"crash-recovery-procedure.json",
        crash_recovery_procedure_sha256:$recovery_procedure_sha,
        guard_identity_evidence:"maintenance-compatible-guard-identities.tsv",
        guard_identity_evidence_sha256:$guard_identities_sha,
        executable_recovery:false,recovery_mode:"manual-audited-only",
        wallet_runtime_guard_sha256:$wallet_runtime_guard_sha,
        endpoint_guard_sha256:$endpoint_guard_sha,
        activated_before_node_mutation:true,retained_on_failure:true,
        released_after_old_runtime_and_start_authority:true,
        live_marker_absent:true},
      automatic_wallet_features_default_off_verified:true,
      candidate_network_ready_verified:true,replay_marker_exact_tip_verified:true,
      wallet_identity_unchanged:true,configuration_identity_unchanged:true,
      reindex_observed:false,reindex_or_replay_rebuild_observed:false,
      pre_upgrade_data_restored:true,
      snapshot_identity_verified:true,snapshot_zero_diff_verified:true,
      candidate_launch_attempted:true,zfs_snapshot_holds_released:true,
      automatic_start_authority_restored:true,
      maintenance_marker_activated:true,maintenance_marker_released:true,
      crash_safe_supervisor_inhibition_verified:true,
      rollback_verified:true}' \
    >"${EVIDENCE}/RESULT.json"

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

result='passed'
echo "CANARY_PASS source=${SOURCE_SHA} evidence=${EVIDENCE}"
