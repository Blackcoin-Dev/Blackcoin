#!/usr/bin/env bash

# Runtime assertions used by the rollout and the independent soak audit.
# This file contains no mutation commands.

# shellcheck source=common.sh
source "${BASH_SOURCE[0]%/*}/common.sh"

verify_image_identity()
{
    local image_json label_value version_value daemon_hash cli_hash
    image_json=$(docker image inspect "$CANDIDATE_IMAGE_REF") || return 1
    jq -e --arg id "$CANDIDATE_IMAGE_ID" 'length == 1 and .[0].Id == $id' \
        >/dev/null <<< "$image_json" || return 1
    label_value=$(jq -er --arg key "$SOURCE_LABEL_KEY" '.[0].Config.Labels[$key]' \
        <<< "$image_json") || return 1
    version_value=$(jq -er --arg key "$VERSION_LABEL_KEY" '.[0].Config.Labels[$key]' \
        <<< "$image_json") || return 1
    [[ "$label_value" == "$SOURCE_LABEL_VALUE" && "$version_value" == "$VERSION_LABEL_VALUE" ]] || return 1

    daemon_hash=$(docker run --rm --pull=never --network none --read-only --cap-drop ALL \
        --security-opt no-new-privileges --entrypoint /usr/bin/sha256sum \
        "$CANDIDATE_IMAGE_REF" /usr/local/bin/blackcoind | awk '{print $1}') || return 1
    cli_hash=$(docker run --rm --pull=never --network none --read-only --cap-drop ALL \
        --security-opt no-new-privileges --entrypoint /usr/bin/sha256sum \
        "$CANDIDATE_IMAGE_REF" /usr/local/bin/blackcoin-cli | awk '{print $1}') || return 1
    [[ "$daemon_hash" == "$BLACKCOIND_SHA256" && "$cli_hash" == "$BLACKCOIN_CLI_SHA256" ]]
}

verify_published_canary()
{
    local evidence_dir ops_dir stamp actual_result_sha actual_manifest_sha protected suffix
    local identity_file restore_file launch_file prelaunch_txids_file locked_txids_file
    local activation_file nonce_evidence_file active_state_file release_file complete_state_file
    local recovery_file guard_identities_file nonce_file state_file parent_recovery_file nonce
    local identity_sha restore_sha launch_sha expected_identity_sha expected_restore_sha
    local expected_launch_sha prelaunch_txids_sha locked_txids_sha expected_prelaunch_txids_sha
    local expected_locked_txids_sha identity_set_sha restore_set_sha result_snapshot_set_sha
    local activation_sha active_state_sha release_sha complete_state_sha recovery_sha guard_sha
    local launch_timestamp release_timestamp marker_transaction fleet_run fleet_nonce fleet_state
    local fleet_nonce_file fleet_state_file
    local compatible_runtime_sha='9ed02479801cb0de4085f9d6055500bb7d22de86d2fc2b91be6c19e9955398ee'
    local compatible_endpoint_sha='81135dd9637cd5b4fa42a0c634f1decb37fcd68a280c55c661b640226196880f'
    local normal_unlock_sha='acf28446e842fd0fa92b06c2ebc182e9da38fcde7bac06dd920d50a33e4e3dd1'
    local pow_start_sha='21808f232ca3961e180a4c2dd3853e4aef93c2dfdf4821b5d63ca5106c5676ea'

    [[ "$SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || return 1
    evidence_dir=${PUBLISHED_CANARY_RESULT%/*}
    ops_dir=${evidence_dir%/evidence}
    stamp=${ops_dir##*/node27-canary-}
    [[ "$PUBLISHED_CANARY_RESULT" == "$evidence_dir/RESULT.json" &&
       "$PUBLISHED_CANARY_EVIDENCE_MANIFEST" == "$evidence_dir/SHA256SUMS" &&
       "$evidence_dir" =~ ^/mnt/pulsar/Blackcoin_Blocks/operations/releases/v30[.]1[.]4-${SOURCE_COMMIT}/node27-canary-[0-9]{8}T[0-9]{6}Z/evidence$ &&
       "$stamp" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] ||
        return 1
    [[ -d "$ops_dir" && ! -L "$ops_dir" &&
       "$(realpath -e -- "$ops_dir")" == "$ops_dir" &&
       "$(stat -c '%u:%g:%a' "$ops_dir")" == 0:0:700 &&
       -d "$evidence_dir" && ! -L "$evidence_dir" &&
       "$(realpath -e -- "$evidence_dir")" == "$evidence_dir" &&
       "$(stat -c '%u:%g:%a' "$evidence_dir")" == 0:0:700 ]] ||
        return 1
    # Evidence is a flat, closed set of protected regular files.  The manifest
    # itself is externally pinned and must cover every other entry exactly once.
    [[ -z "$(find "$evidence_dir" -mindepth 1 ! -type f -print -quit)" ]] || return 1
    while IFS= read -r -d '' protected; do
        [[ ! -L "$protected" && "$(realpath -e -- "$protected")" == "$protected" &&
           "$(stat -c '%u:%g:%a' "$protected")" == 0:0:600 ]] || return 1
    done < <(find "$evidence_dir" -mindepth 1 -maxdepth 1 -type f -print0)
    [[ -s "$PUBLISHED_CANARY_EVIDENCE_MANIFEST" &&
       -z "$(grep -Ev '^[0-9a-f]{64}  [.]\/[A-Za-z0-9][A-Za-z0-9._-]*$' \
           "$PUBLISHED_CANARY_EVIDENCE_MANIFEST" || true)" &&
       -z "$(awk '{print $2}' "$PUBLISHED_CANARY_EVIDENCE_MANIFEST" | sort | uniq -d)" &&
       "$(grep -Fc '  ./SHA256SUMS' "$PUBLISHED_CANARY_EVIDENCE_MANIFEST")" == 0 ]] || return 1
    cmp -s \
        <(cd "$evidence_dir" && find . -mindepth 1 -maxdepth 1 -type f \
            ! -path './SHA256SUMS' -print | sort) \
        <(awk '{print $2}' "$PUBLISHED_CANARY_EVIDENCE_MANIFEST" | sort) || return 1
    actual_result_sha=$(sha256sum "$PUBLISHED_CANARY_RESULT" | awk '{print $1}') || return 1
    actual_manifest_sha=$(sha256sum "$PUBLISHED_CANARY_EVIDENCE_MANIFEST" | awk '{print $1}') || return 1
    [[ "$actual_result_sha" == "$EXPECTED_CANARY_RESULT_SHA256" &&
       "$actual_manifest_sha" == "$EXPECTED_CANARY_EVIDENCE_MANIFEST_SHA256" ]] || return 1
    (cd "$evidence_dir" && sha256sum --strict -c SHA256SUMS >/dev/null) || return 1
    jq -se \
        --arg source "$SOURCE_COMMIT" \
        --arg image "$CANDIDATE_IMAGE_REF" \
        --arg image_id "$CANDIDATE_IMAGE_ID" \
        --arg marker "$ROLLOUT_MAINTENANCE_MARKER" \
        --arg run "$ops_dir" \
        --arg runtime_guard "$compatible_runtime_sha" \
        --arg endpoint_guard "$compatible_endpoint_sha" \
        --arg data 'pulsar/Blackcoin_Blocks/node-data/node-27' \
        --arg blocks 'pulsar/Blackcoin_Blocks/node-data/node-27/blocks' \
        --arg indexes 'pulsar/Blackcoin_Blocks/node-data/node-27/indexes' \
        --arg raw 'pulsar/Blackcoin_Blocks/alpha-chain-raw-clones-20260715T032403Z/node-27' '
        length == 1 and (.[0] as $r | $r |
        .schema == 1 and .result == "passed" and .node == 27 and
        .candidate_mode == "published-package-image" and
        .source_sha == $source and
        .candidate_image == $image and
        .candidate_image_id == $image_id and .rolled_back_to == "30.1.3" and
        .same_effective_entrypoint == true and .fee_payments_authorized == false and
        .claim_recovery_fee_unchanged == true and .wallet_identity_unchanged == true and
        .configuration_identity_unchanged == true and .reindex_observed == false and
        .reindex_or_replay_rebuild_observed == false and
        .recovery_fee_baseline_established_while_wallet_locked == true and
        .locked_candidate_transaction_set_unchanged == true and
        (.prelaunch_transaction_set_sha256 | test("^[0-9a-f]{64}$")) and
        (.locked_candidate_transaction_set_sha256 | test("^[0-9a-f]{64}$")) and
        .prelaunch_transaction_set_sha256 == .locked_candidate_transaction_set_sha256 and
        .automatic_wallet_features_default_off_verified == true and
        .candidate_network_ready_verified == true and
        .replay_marker_exact_tip_verified == true and
        .pre_upgrade_data_restored == true and .snapshot_identity_verified == true and
        .snapshot_zero_diff_verified == true and .candidate_launch_attempted == true and
        .zfs_snapshot_holds_released == true and
        .automatic_start_authority_restored == true and
        .zfs_snapshot_count == 4 and (.zfs_snapshot_suffix | type) == "string" and
        (.zfs_snapshot_suffix | test("^v30[.]1[.]4-node27-[0-9]{8}T[0-9]{6}Z$")) and
        (.zfs_snapshot_identity_sha256 | test("^[0-9a-f]{64}$")) and
        (.zfs_snapshot_restore_proof_sha256 | test("^[0-9a-f]{64}$")) and
        .candidate_launch_marker == "CANDIDATE-LAUNCH-ATTEMPTED.json" and
        (.candidate_launch_marker_sha256 | test("^[0-9a-f]{64}$")) and
        .maintenance_marker_activated == true and
        .maintenance_marker_released == true and
        .crash_safe_supervisor_inhibition_verified == true and
        (.maintenance as $m |
          ($m.run_nonce_sha256 | test("^[0-9a-f]{64}$")) and
          ($m.marker_activation_sha256 | test("^[0-9a-f]{64}$")) and
          ($m.active_state_evidence_sha256 | test("^[0-9a-f]{64}$")) and
          ($m.marker_release_sha256 | test("^[0-9a-f]{64}$")) and
          ($m.complete_state_evidence_sha256 | test("^[0-9a-f]{64}$")) and
          ($m.crash_recovery_procedure_sha256 | test("^[0-9a-f]{64}$")) and
          ($m.guard_identity_evidence_sha256 | test("^[0-9a-f]{64}$")) and
          $m == {schema:1,transaction:"v30.1.4-node27-canary",marker:$marker,
            run_dir:$run,state:"complete",run_nonce_sha256:$m.run_nonce_sha256,
            marker_activation_evidence:"maintenance-marker-activated.json",
            marker_activation_sha256:$m.marker_activation_sha256,
            active_state_evidence:"maintenance-state-active.txt",
            active_state_evidence_sha256:$m.active_state_evidence_sha256,
            marker_release_evidence:"maintenance-marker-released.json",
            marker_release_sha256:$m.marker_release_sha256,
            complete_state_evidence:"maintenance-state-complete.txt",
            complete_state_evidence_sha256:$m.complete_state_evidence_sha256,
            crash_recovery_procedure:"crash-recovery-procedure.json",
            crash_recovery_procedure_sha256:$m.crash_recovery_procedure_sha256,
            guard_identity_evidence:"maintenance-compatible-guard-identities.tsv",
            guard_identity_evidence_sha256:$m.guard_identity_evidence_sha256,
            executable_recovery:false,recovery_mode:"manual-audited-only",
            wallet_runtime_guard_sha256:$runtime_guard,
            endpoint_guard_sha256:$endpoint_guard,
            activated_before_node_mutation:true,retained_on_failure:true,
            released_after_old_runtime_and_start_authority:true,live_marker_absent:true}) and
        (.zfs_hold_tag | test("^blackcoin-v3014-node27-[0-9]{8}T[0-9]{6}Z$")) and
        $r.zfs_snapshots == [($data + "@" + $r.zfs_snapshot_suffix),
          ($blocks + "@" + $r.zfs_snapshot_suffix),
          ($indexes + "@" + $r.zfs_snapshot_suffix),
          ($raw + "@" + $r.zfs_snapshot_suffix)] and
        (.first_height | type) == "number" and (.second_height | type) == "number" and
        .second_height >= .first_height and .active_staking_samples >= 3 and
        .rollback_verified == true)
    ' "$PUBLISHED_CANARY_RESULT" >/dev/null || return 1
    identity_file="$evidence_dir/zfs-snapshot-identities.tsv"
    restore_file="$evidence_dir/zfs-restore-proof.tsv"
    launch_file="$evidence_dir/CANDIDATE-LAUNCH-ATTEMPTED.json"
    prelaunch_txids_file="$evidence_dir/prelaunch-transaction-txids.json"
    locked_txids_file="$evidence_dir/candidate-preactivation-transaction-txids.json"
    activation_file="$evidence_dir/maintenance-marker-activated.json"
    nonce_evidence_file="$evidence_dir/maintenance-nonce.txt"
    active_state_file="$evidence_dir/maintenance-state-active.txt"
    release_file="$evidence_dir/maintenance-marker-released.json"
    complete_state_file="$evidence_dir/maintenance-state-complete.txt"
    recovery_file="$evidence_dir/crash-recovery-procedure.json"
    guard_identities_file="$evidence_dir/maintenance-compatible-guard-identities.tsv"
    nonce_file="$ops_dir/MAINTENANCE-NONCE"
    state_file="$ops_dir/STATE"
    parent_recovery_file="$ops_dir/CRASH-RECOVERY.json"
    for protected in "$identity_file" "$restore_file" "$launch_file" \
        "$prelaunch_txids_file" "$locked_txids_file" "$activation_file" \
        "$nonce_evidence_file" "$active_state_file" "$release_file" \
        "$complete_state_file" "$recovery_file" "$guard_identities_file" \
        "$nonce_file" "$state_file" "$parent_recovery_file"; do
        [[ -f "$protected" && ! -L "$protected" &&
           "$(realpath -e -- "$protected")" == "$protected" &&
           "$(stat -c '%u:%g:%a' "$protected")" == 0:0:600 ]] || return 1
    done
    printf '%s\n' active | cmp -s - "$active_state_file" || return 1
    printf '%s\n' complete | cmp -s - "$complete_state_file" || return 1
    printf '%s\n' complete | cmp -s - "$state_file" || return 1
    cmp -s "$nonce_file" "$nonce_evidence_file" || return 1
    cmp -s "$parent_recovery_file" "$recovery_file" || return 1
    nonce=$(cat "$nonce_file") || return 1
    [[ "$nonce" =~ ^[0-9a-f]{64}$ ]] || return 1
    identity_sha=$(sha256sum "$identity_file" | awk '{print $1}') || return 1
    restore_sha=$(sha256sum "$restore_file" | awk '{print $1}') || return 1
    launch_sha=$(sha256sum "$launch_file" | awk '{print $1}') || return 1
    prelaunch_txids_sha=$(sha256sum "$prelaunch_txids_file" | awk '{print $1}') || return 1
    locked_txids_sha=$(sha256sum "$locked_txids_file" | awk '{print $1}') || return 1
    activation_sha=$(sha256sum "$activation_file" | awk '{print $1}') || return 1
    active_state_sha=$(sha256sum "$active_state_file" | awk '{print $1}') || return 1
    release_sha=$(sha256sum "$release_file" | awk '{print $1}') || return 1
    complete_state_sha=$(sha256sum "$complete_state_file" | awk '{print $1}') || return 1
    recovery_sha=$(sha256sum "$recovery_file" | awk '{print $1}') || return 1
    guard_sha=$(sha256sum "$guard_identities_file" | awk '{print $1}') || return 1
    expected_identity_sha=$(jq -er '.zfs_snapshot_identity_sha256' "$PUBLISHED_CANARY_RESULT") || return 1
    expected_restore_sha=$(jq -er '.zfs_snapshot_restore_proof_sha256' "$PUBLISHED_CANARY_RESULT") || return 1
    expected_launch_sha=$(jq -er '.candidate_launch_marker_sha256' "$PUBLISHED_CANARY_RESULT") || return 1
    expected_prelaunch_txids_sha=$(jq -er '.prelaunch_transaction_set_sha256' "$PUBLISHED_CANARY_RESULT") || return 1
    expected_locked_txids_sha=$(jq -er '.locked_candidate_transaction_set_sha256' "$PUBLISHED_CANARY_RESULT") || return 1
    [[ "$identity_sha" == "$expected_identity_sha" &&
       "$restore_sha" == "$expected_restore_sha" &&
       "$launch_sha" == "$expected_launch_sha" &&
       "$prelaunch_txids_sha" == "$expected_prelaunch_txids_sha" &&
       "$locked_txids_sha" == "$expected_locked_txids_sha" &&
       "$prelaunch_txids_sha" == "$locked_txids_sha" ]] || return 1
    jq -se --arg nonce_sha "$(sha256sum "$nonce_file" | awk '{print $1}')" \
        --arg activation_sha "$activation_sha" --arg active_state_sha "$active_state_sha" \
        --arg release_sha "$release_sha" --arg complete_state_sha "$complete_state_sha" \
        --arg recovery_sha "$recovery_sha" --arg guard_sha "$guard_sha" \
        --arg runtime_guard "$compatible_runtime_sha" --arg endpoint_guard "$compatible_endpoint_sha" '
        length == 1 and (.[0].maintenance as $m |
          $m.run_nonce_sha256 == $nonce_sha and
          $m.marker_activation_sha256 == $activation_sha and
          $m.active_state_evidence_sha256 == $active_state_sha and
          $m.marker_release_sha256 == $release_sha and
          $m.complete_state_evidence_sha256 == $complete_state_sha and
          $m.crash_recovery_procedure_sha256 == $recovery_sha and
          $m.guard_identity_evidence_sha256 == $guard_sha and
          $m.wallet_runtime_guard_sha256 == $runtime_guard and
          $m.endpoint_guard_sha256 == $endpoint_guard)
    ' "$PUBLISHED_CANARY_RESULT" >/dev/null || return 1
    for protected in "$prelaunch_txids_file" "$locked_txids_file"; do
        jq -se 'length == 1 and (.[0] | type == "array" and
            all(.[]; type == "string" and test("^[0-9a-f]{64}$")) and
            . == (unique | sort))' "$protected" >/dev/null || return 1
        cmp -s "$protected" <(jq -S . "$protected") || return 1
    done
    cmp -s "$prelaunch_txids_file" "$locked_txids_file" || return 1
    [[ "$(wc -l < "$identity_file" | awk '{print $1}')" == 4 &&
       "$(awk -F '\t' 'NF == 4 {count++} END {print count+0}' "$identity_file")" == 4 &&
       "$(wc -l < "$restore_file" | awk '{print $1}')" == 4 &&
       "$(awk -F '\t' 'NF == 5 && $5 == "zero-diff" {count++} END {print count+0}' "$restore_file")" == 4 ]] ||
        return 1
    identity_set_sha=$(awk -F '\t' 'NF == 4 {print $1}' "$identity_file" | sort | sha256sum | awk '{print $1}') || return 1
    restore_set_sha=$(awk -F '\t' 'NF == 5 && $5 == "zero-diff" {print $1}' "$restore_file" | sort | sha256sum | awk '{print $1}') || return 1
    result_snapshot_set_sha=$(jq -r '.zfs_snapshots[]' "$PUBLISHED_CANARY_RESULT" | sort | sha256sum | awk '{print $1}') || return 1
    [[ "$identity_set_sha" == "$result_snapshot_set_sha" &&
       "$restore_set_sha" == "$result_snapshot_set_sha" ]] || return 1
    suffix=$(jq -er '.zfs_snapshot_suffix' "$PUBLISHED_CANARY_RESULT") || return 1
    launch_timestamp=$(jq -er '.timestamp | select(type == "string" and
        test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))' \
        "$launch_file") || return 1
    jq -se --arg source "$SOURCE_COMMIT" --arg image "$CANDIDATE_IMAGE_REF" \
        --arg image_id "$CANDIDATE_IMAGE_ID" --arg suffix "$suffix" \
        --arg hold "$(jq -er '.zfs_hold_tag' "$PUBLISHED_CANARY_RESULT")" \
        --arg identity "$identity_sha" \
        --arg suspended "$STATE_DIR/ENABLE_GUARD_STARTS.node27-${stamp}.suspended" \
        --arg marker "$ROLLOUT_MAINTENANCE_MARKER" \
        --arg nonce_sha "$(sha256sum "$nonce_file" | awk '{print $1}')" \
        --arg activation_sha "$activation_sha" --arg recovery_sha "$recovery_sha" \
        --arg active_state_sha "$active_state_sha" --arg guard_sha "$guard_sha" \
        --arg timestamp "$launch_timestamp" '
        length == 1 and .[0] == {schema:1,candidate_launch_attempted:true,
          source_sha:$source,candidate_image:$image,candidate_image_id:$image_id,
          zfs_snapshot_suffix:$suffix,zfs_hold_tag:$hold,zfs_snapshot_count:4,
          zfs_snapshot_identity_sha256:$identity,guard_start_suspended_marker:$suspended,
          maintenance_marker:$marker,maintenance_nonce_sha256:$nonce_sha,
          maintenance_marker_activation_sha256:$activation_sha,
          crash_recovery_procedure_sha256:$recovery_sha,
          maintenance_active_state_sha256:$active_state_sha,
          maintenance_guard_identities_sha256:$guard_sha,timestamp:$timestamp}
    ' "$launch_file" >/dev/null || return 1

    jq -se --arg nonce "$nonce" --arg run "$ops_dir" '
        length == 1 and .[0] == {schema:1,transaction:"v30.1.4-node27-canary",
          state:"active",run_nonce:$nonce,run_dir:$run}
    ' "$activation_file" >/dev/null || return 1

    jq -se --arg marker "$ROLLOUT_MAINTENANCE_MARKER" --arg run "$ops_dir" \
        --arg state "$state_file" --arg nonce_file "$nonce_file" \
        --arg nonce_sha "$(sha256sum "$nonce_file" | awk '{print $1}')" \
        --arg launch "$launch_file" \
        --arg original 'qqblackcoin/blackcoin-v4-gui:30.1.3-final-86c6855ab135-ops1' \
        --arg original_id 'sha256:bbc2435a034af908dc8c5f0e6976ba89d42347a8e49d5971e4b4d6fb1bbaa391' \
        --arg normal_sha "$normal_unlock_sha" --arg pow_sha "$pow_start_sha" \
        --arg datadir 'pulsar/Blackcoin_Blocks/node-data/node-27' \
        --arg blocks 'pulsar/Blackcoin_Blocks/node-data/node-27/blocks' \
        --arg indexes 'pulsar/Blackcoin_Blocks/node-data/node-27/indexes' \
        --arg raw 'pulsar/Blackcoin_Blocks/alpha-chain-raw-clones-20260715T032403Z/node-27' '
        length == 1 and .[0] == {
          schema:1,transaction:"v30.1.4-node27-canary",recovery_mode:"manual-audited-only",
          executable_recovery:false,run_dir:$run,maintenance_marker:$marker,state_file:$state,
          nonce_file:$nonce_file,nonce_sha256:$nonce_sha,candidate_launch_marker:$launch,
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
    ' "$recovery_file" >/dev/null || return 1

    cmp -s "$guard_identities_file" <(printf '%s\n%s\t%s\t%s\n%s\t%s\t%s\n' \
        $'path\tsha256\tuid:gid:mode' \
        "$WALLET_RUNTIME_GUARD" "$compatible_runtime_sha" '0:0:600' \
        "$ENDPOINT_GUARD" "$compatible_endpoint_sha" '0:0:600') || return 1
    [[ "${EXPECTED_WALLET_RUNTIME_GUARD_SHA256:-$compatible_runtime_sha}" == "$compatible_runtime_sha" &&
       "${EXPECTED_ENDPOINT_GUARD_SHA256:-$compatible_endpoint_sha}" == "$compatible_endpoint_sha" ]] ||
        return 1

    release_timestamp=$(jq -er '.timestamp | select(type == "string" and
        test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))' \
        "$release_file") || return 1
    jq -se --arg marker "$ROLLOUT_MAINTENANCE_MARKER" --arg run "$ops_dir" \
        --arg nonce_sha "$(sha256sum "$nonce_file" | awk '{print $1}')" \
        --arg activation_sha "$activation_sha" --arg recovery_sha "$recovery_sha" \
        --arg active_state_sha "$active_state_sha" --arg complete_state_sha "$complete_state_sha" \
        --arg guard_sha "$guard_sha" --arg runtime_guard "$compatible_runtime_sha" \
        --arg endpoint_guard "$compatible_endpoint_sha" --arg timestamp "$release_timestamp" '
        length == 1 and .[0] == {schema:1,transaction:"v30.1.4-node27-canary",
          marker:$marker,run_dir:$run,run_nonce_sha256:$nonce_sha,
          marker_activation_sha256:$activation_sha,marker_released:true,
          crash_recovery_procedure_sha256:$recovery_sha,
          active_state_evidence_sha256:$active_state_sha,
          complete_state_evidence_sha256:$complete_state_sha,
          guard_identity_evidence_sha256:$guard_sha,
          wallet_runtime_guard_sha256:$runtime_guard,endpoint_guard_sha256:$endpoint_guard,
          pre_upgrade_data_restored:true,old_container_runtime_verified:true,
          automatic_start_authority_restored:true,state_after_release:"complete",
          timestamp:$timestamp}
    ' "$release_file" >/dev/null || return 1

    # A completed canary may coexist with its successor fleet transaction, but
    # never with a still-active canary marker.  If a fleet marker is present,
    # authenticate its run directory, nonce, and state before accepting it.
    if [[ -e "$ROLLOUT_MAINTENANCE_MARKER" || -L "$ROLLOUT_MAINTENANCE_MARKER" ]]; then
        [[ -f "$ROLLOUT_MAINTENANCE_MARKER" && ! -L "$ROLLOUT_MAINTENANCE_MARKER" &&
           "$(realpath -e -- "$ROLLOUT_MAINTENANCE_MARKER")" == "$ROLLOUT_MAINTENANCE_MARKER" &&
           "$(stat -c '%u:%g:%a' "$ROLLOUT_MAINTENANCE_MARKER")" == 0:0:600 ]] || return 1
        marker_transaction=$(jq -er '.transaction' "$ROLLOUT_MAINTENANCE_MARKER") || return 1
        [[ "$marker_transaction" != v30.1.4-node27-canary ]] || return 1
        [[ "$marker_transaction" == v30.1.4-fleet-rollout ]] || return 1
        fleet_run=$(jq -er '.run_dir' "$ROLLOUT_MAINTENANCE_MARKER") || return 1
        fleet_nonce=$(jq -er '.run_nonce' "$ROLLOUT_MAINTENANCE_MARKER") || return 1
        [[ "$fleet_run" =~ ^/mnt/pulsar/Blackcoin_Blocks/operations/v30[.]1[.]4-fleet-rollout/rollout-[0-9]{8}T[0-9]{6}Z$ &&
           "$fleet_nonce" =~ ^[0-9a-f]{64}$ &&
           ( -z "${RUN_DIR:-}" || "$fleet_run" == "$RUN_DIR" ) &&
           -d "$fleet_run" && ! -L "$fleet_run" &&
           "$(realpath -e -- "$fleet_run")" == "$fleet_run" &&
           "$(stat -c '%u:%g:%a' "$fleet_run")" == 0:0:700 ]] || return 1
        fleet_nonce_file="$fleet_run/MAINTENANCE-NONCE"
        fleet_state_file="$fleet_run/STATE"
        for protected in "$fleet_nonce_file" "$fleet_state_file"; do
            [[ -f "$protected" && ! -L "$protected" &&
               "$(realpath -e -- "$protected")" == "$protected" &&
               "$(stat -c '%u:%g:%a' "$protected")" == 0:0:600 ]] || return 1
        done
        [[ "$(cat "$fleet_nonce_file")" == "$fleet_nonce" ]] || return 1
        fleet_state=$(cat "$fleet_state_file") || return 1
        [[ "$fleet_state" == prepared || "$fleet_state" == applying || "$fleet_state" == complete ]] ||
            return 1
        jq -se --arg nonce "$fleet_nonce" --arg run "$fleet_run" '
            length == 1 and .[0] == {schema:1,transaction:"v30.1.4-fleet-rollout",
              state:"active",run_nonce:$nonce,run_dir:$run}
        ' "$ROLLOUT_MAINTENANCE_MARKER" >/dev/null || return 1
    fi

    (cd "$evidence_dir" && sha256sum --strict -c SHA256SUMS >/dev/null) || return 1
    [[ "$(sha256sum "$PUBLISHED_CANARY_RESULT" | awk '{print $1}')" == "$actual_result_sha" &&
       "$(sha256sum "$PUBLISHED_CANARY_EVIDENCE_MANIFEST" | awk '{print $1}')" == "$actual_manifest_sha" ]]
}

verify_endpoint_config_matches_vpn()
{
    local node="$1" proof ip port conf key
    proof=$(read_vpn_proof "$node") || return 1
    IFS='|' read -r ip port <<< "$proof"
    conf="$(host_datadir_for "$node")/blackcoin.conf"
    [[ -f "$conf" && ! -L "$conf" && "$(stat -c '%u:%g:%a' "$conf")" == 1000:1000:600 ]] ||
        return 1
    for key in externalip port bind; do
        [[ "$(grep -Eic "^[[:space:]]*${key}[[:space:]]*=" "$conf")" -eq 1 ]] || return 1
    done
    grep -Eq "^[[:space:]]*externalip[[:space:]]*=[[:space:]]*${ip}:${port}[[:space:]]*$" "$conf" || return 1
    grep -Eq "^[[:space:]]*port[[:space:]]*=[[:space:]]*${port}[[:space:]]*$" "$conf" || return 1
    grep -Eq "^[[:space:]]*bind[[:space:]]*=[[:space:]]*0[.]0[.]0[.]0:${port}[[:space:]]*$" "$conf"
}

verify_vpn_pair()
{
    local node="$1" vpn proof ip port inspect
    vpn=$(vpn_for "$node")
    inspect=$(docker inspect "$vpn") || return 1
    jq -e --arg id "$EXPECTED_VPN_IMAGE_ID" '
        length == 1 and .[0].State.Running == true and
        .[0].State.Health.Status == "healthy" and .[0].Image == $id and
        .[0].HostConfig.RestartPolicy.Name == "unless-stopped" and
        .[0].HostConfig.NetworkMode == "bridge"
    ' >/dev/null <<< "$inspect" || return 1
    proof=$(read_vpn_proof "$node") || return 1
    IFS='|' read -r ip port <<< "$proof"
    valid_public_ipv4 "$ip" && valid_port "$port" && verify_endpoint_config_matches_vpn "$node"
}

verify_container_topology()
{
    local node="$1" expected_ref="$2" expected_id="$3"
    local container vpn vpn_id expected_data expected_blocks inspect
    container=$(container_for "$node")
    vpn=$(vpn_for "$node")
    vpn_id=$(docker inspect -f '{{.Id}}' "$vpn") || return 1
    expected_data=$(host_datadir_for "$node")
    expected_blocks=$(host_blocks_for "$node")
    inspect=$(docker inspect "$container") || return 1
    jq -e \
        --arg ref "$expected_ref" --arg id "$expected_id" \
        --arg mode "container:$vpn_id" \
        --arg data "$expected_data" --arg blocks "$expected_blocks" \
        --arg node "$(node_padded "$node")" \
        --arg vpn "$vpn" '
        length == 1 and
        .[0].Config.Image == $ref and .[0].Image == $id and
        .[0].State.Running == true and .[0].State.Health.Status == "healthy" and
        .[0].HostConfig.NetworkMode == $mode and
        .[0].HostConfig.RestartPolicy.Name == "on-failure" and
        .[0].HostConfig.RestartPolicy.MaximumRetryCount == 3 and
        .[0].HostConfig.Privileged == false and
        .[0].HostConfig.AutoRemove == false and
        .[0].Config.Labels["blackcoin.node"] == $node and
        .[0].Config.Labels["blackcoin.vpn"] == $vpn and
        .[0].Config.Labels["blackcoin.storage"] == "pulsar" and
        ([.[0].Mounts[] | select(.Destination == "/home/blackcoin/.blackcoin" and
            .Source == $data and .RW == true)] | length) == 1 and
        ([.[0].Mounts[] | select(.Destination == "/home/blackcoin/blocks_storage" and
            .Source == $blocks and .RW == true)] | length) == 1
    ' >/dev/null <<< "$inspect" || return 1
    live_netns_matches "$node"
}

verify_core_common()
{
    local node="$1" network
    network=$(rpc_for "$node" getnetworkinfo) || return 1
    jq -e '.version == 300104 and .subversion == "/Blackcoin:30.1.4/" and
        .networkactive == true and .connections_out >= 3' >/dev/null <<< "$network" || return 1
    verify_core_operational "$node" "$network"
}

verify_core_operational()
{
    local node="$1" network="${2:-}" chain wallet_info wallet
    [[ -n "$network" ]] || network=$(rpc_for "$node" getnetworkinfo) || return 1
    chain=$(rpc_for "$node" getblockchaininfo) || return 1
    wallet=$(single_wallet_for "$node") || return 1
    wallet_info=$(timeout --kill-after=2 45 docker exec "$(container_for "$node")" \
        "$CLI_PATH" -datadir="$DATADIR" -rpcwallet="$wallet" getwalletinfo) || return 1
    jq -e '.networkactive == true and .connections_out >= 3' >/dev/null <<< "$network" || return 1
    jq -e '.chain == "main" and .initialblockdownload == false and
        .headers >= .blocks and (.headers - .blocks) <= 2' >/dev/null <<< "$chain" || return 1
    jq -e '.private_keys_enabled == true and .scanning == false and
        .unlocked_until > now and .unlocked_staking_only == false' \
        >/dev/null <<< "$wallet_info"
}

verify_replay_state()
{
    local node="$1" chain goldrush
    chain=$(rpc_for "$node" getblockchaininfo) || return 1
    goldrush=$(rpc_for "$node" getgoldrushstate) || return 1
    jq -e -n --argjson chain "$chain" --argjson goldrush "$goldrush" '
        ($chain.chain == "main") and
        ($goldrush.height == $chain.blocks) and
        ($goldrush.bestblock == $chain.bestblockhash) and
        ($goldrush.replay_state.schema == 12) and
        ($goldrush.replay_state.required_for_tip == true) and
        ($goldrush.replay_state.present == true) and
        ($goldrush.replay_state.marker_valid == true) and
        ($goldrush.replay_state.valid_for_tip == true) and
        (($goldrush.replay_state.marker_height | type) == "number") and
        ($goldrush.replay_state.marker_height >= 0) and
        (($goldrush.replay_state.marker_time | type) == "number") and
        ($goldrush.replay_state.marker_time > 0) and
        ($goldrush.replay_state.marker_blockhash | test("^[0-9a-f]{64}$")) and
        ($goldrush.replay_state.commitment | test("^[0-9a-f]{64}$"))
    ' >/dev/null
}

verify_donation_defaults_off()
{
    local node="$1" legacy qq
    legacy=$(wallet_rpc_for "$node" getstakingdonationinfo) || return 1
    qq=$(wallet_rpc_for "$node" getqqdevelopmentdonationinfo) || return 1
    jq -e '.retired == true and .enabled == false and .percentage == 0 and
        .target_address == ""' >/dev/null <<< "$legacy" || return 1
    jq -e '.enabled == false and .percentage == 0 and
        .database_outcome_ambiguous == false' >/dev/null <<< "$qq"
}

verify_staking()
{
    local node="$1" staking
    staking=$(wallet_rpc_for "$node" getstakinginfo) || return 1
    jq -e '.enabled == true and .staking == true and
        .worker_running == true and .eligible == true and
        .staking_snapshot_current == true and .staking_state == "searching" and
        .weight > 0 and .weight_cached == true and
        .automatic_qqsignal == false and
        .automatic_demurrage_attestation == false and
        .automatic_redelegation == false and
        .allow_automatic_quantum_key_creation == false' \
        >/dev/null <<< "$staking"
}

verify_legacy_staking()
{
    local node="$1" staking
    staking=$(wallet_rpc_for "$node" getstakinginfo) || return 1
    jq -e '.enabled == true and .staking == true and ."search-interval" > 0 and
        .weight > 0 and .weight_cached == true and
        .automatic_qqsignal == false and
        .automatic_demurrage_attestation == false and
        .automatic_redelegation == false and
        .allow_automatic_quantum_key_creation == false' >/dev/null <<< "$staking"
}

verify_legacy_pow_role()
{
    local node="$1" baseline="${2:-}" mining
    mining=$(wallet_rpc_for "$node" getpowmininginfo) || return 1
    if [[ "$node" -eq "$FREE_CLAIM_NODE" ]]; then
        jq -e '.enabled == false and .hashrate == 0 and .live_claims == 0 and
            .allow_automatic_quantum_key_creation == false' >/dev/null <<< "$mining" || return 1
    else
        jq -e '.enabled == true and .threads == 1 and .cpu_percent == 1 and
            .hashrate > 0 and (.live_claims | type) == "number" and
            .live_claims >= 0 and .live_claims <= 64 and
            .allow_automatic_quantum_key_creation == false' >/dev/null <<< "$mining" || return 1
    fi
    if [[ -n "$baseline" ]]; then
        [[ -f "$baseline" && ! -L "$baseline" ]] || return 1
        jq -e -n --argjson current "$mining" --slurpfile baseline "$baseline" '
            ($baseline | length) == 1 and
            ($baseline[0].unresolved_claims | type) == "number" and
            ($baseline[0].quarantined_claims | type) == "number" and
            $current.unresolved_claims <= $baseline[0].unresolved_claims and
            $current.quarantined_claims <= $baseline[0].quarantined_claims
        ' >/dev/null || return 1
    fi
}

verify_claim_recovery_clean()
{
    local node="$1" old_fee="${2:-}" recovery current_fee
    [[ "$old_fee" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
    recovery=$(wallet_rpc_for "$node" getpowclaimrecoveryinfo) || return 1
    jq -e '.policy_authoritative == true and .policy.automatic_authorized == false and
        .database_outcome_ambiguous == false and .chain_ready == true and
        .wallet_tip_matches == true and
        .blocking_quarantined_claims == 0 and .blocking_components == 0 and
        .indeterminate_quarantined_claims == 0 and
        .pending_manual_resolutions == 0 and .pending_automatic_resolutions == 0' \
        >/dev/null <<< "$recovery" || return 1
    current_fee=$(jq -er '.confirmed_resolution_fees |
        select(type == "number")' <<< "$recovery") || return 1
    [[ "$current_fee" == "$old_fee" ]]
}

verify_standard_pow()
{
    local node="$1" old_fee="${2:-}" mining
    [[ "$node" -ne "$FREE_CLAIM_NODE" ]] || return 1
    mining=$(wallet_rpc_for "$node" getpowmininginfo) || return 1
    jq -e '.enabled == true and .threads == 1 and .cpu_percent == 1 and
        .hashrate > 0 and (.live_claims | type) == "number" and
        .live_claims >= 0 and .live_claims <= 64 and
        (.unresolved_claims | type) == "number" and
        .unresolved_claims >= .live_claims and
        .blocking_quarantined_claims == 0 and .quarantined_claims == 0 and
        .raw_quarantined_claims >= 0 and
        .claim_recovery_database_outcome_ambiguous == false and
        .allow_automatic_quantum_key_creation == false and
        .stake_reserve_snapshot_available == true and
        .reserved_stake_coins >= 1 and
        ((.last_stake_coin_guard | type) == "boolean")' \
        >/dev/null <<< "$mining" || return 1
    verify_claim_recovery_clean "$node" "$old_fee"
}

verify_node30_core_role()
{
    local mining recovery old_fee="${1:-}" current_fee
    [[ "$old_fee" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
    mining=$(wallet_rpc_for "$FREE_CLAIM_NODE" getpowmininginfo) || return 1
    jq -e '.enabled == false and .hashrate == 0 and .live_claims == 0 and
        .blocking_quarantined_claims == 0 and .quarantined_claims == 0 and
        .claim_recovery_database_outcome_ambiguous == false' \
        >/dev/null <<< "$mining" || return 1
    recovery=$(wallet_rpc_for "$FREE_CLAIM_NODE" getpowclaimrecoveryinfo) || return 1
    jq -e '.policy_authoritative == true and .policy.automatic_authorized == false and
        .database_outcome_ambiguous == false and .chain_ready == true and
        .wallet_tip_matches == true and .blocking_quarantined_claims == 0 and
        .blocking_components == 0 and .indeterminate_quarantined_claims == 0 and
        .pending_manual_resolutions == 0 and .pending_automatic_resolutions == 0' \
        >/dev/null <<< "$recovery" || return 1
    current_fee=$(jq -er '.confirmed_resolution_fees' <<< "$recovery") || return 1
    [[ "$current_fee" == "$old_fee" ]] || return 1
}

verify_node30_free_claim_service()
{
    local status oldest_broadcast inspect

    inspect=$(docker inspect blackcoin-pool-api) || return 1
    jq -e 'length == 1 and .[0].State.Running == true and
        .[0].State.Health.Status == "healthy" and
        .[0].HostConfig.RestartPolicy.Name == "unless-stopped"' \
        >/dev/null <<< "$inspect" || return 1

    status=$(docker exec blackcoin-pool-api curl -fsS --max-time 5 \
        http://127.0.0.1:8377/status) || return 1
    jq -e '.pool == "Blackcoin Free Claim Mining Pool" and
        (.queued | type == "number" and . >= 0) and
        (.awarded_total | type == "number" and . >= 0) and
        (.today_used | type == "number" and . >= 0) and
        ((.daily_cap | type) == "number") and .daily_cap > 0 and
        .today_used <= .daily_cap' \
        >/dev/null <<< "$status" || return 1

    # A broadcast marker older than one hour means the separate Free Claim
    # service is still stalled even if Core itself is healthy.
    oldest_broadcast=$(find "$FREE_CLAIM_ROOT/done" -maxdepth 1 -type f \
        -name '*.broadcast' -mmin +60 -print -quit 2>/dev/null || true)
    [[ -z "$oldest_broadcast" ]]
}

verify_free_claim_pause()
{
    [[ -f "$FREE_CLAIM_PAUSE_MARKER" && ! -L "$FREE_CLAIM_PAUSE_MARKER" &&
       "$(realpath -e -- "$FREE_CLAIM_PAUSE_MARKER")" == "$FREE_CLAIM_PAUSE_MARKER" &&
       "$(stat -c '%u:%g:%a' "$FREE_CLAIM_PAUSE_MARKER")" == 0:0:600 ]] || return 1
    printf '%s\n' 'schema=1 state=paused authority=v30.1.4-fleet-transaction' | \
        cmp -s - "$FREE_CLAIM_PAUSE_MARKER"
}

verify_node30_free_claim()
{
    verify_node30_core_role "${1:-}" && verify_node30_free_claim_service
}

verify_quantum_special()
{
    local node="$1" goldrush
    [[ "$node" -eq 31 || "$node" -eq 32 ]] || return 1
    goldrush=$(wallet_rpc_for "$node" getgoldrushinfo) || return 1
    jq -e --argjson min_blocks "$MIN_QUANTUM_SIGNAL_BLOCKS" \
        --argjson min_seconds "$MIN_QUANTUM_SIGNAL_SECONDS" \
        '.active == true and .wallet_recent_solve_qualified == true and
        .wallet_qqsignal.active == true and .wallet_qqsignal.status == "confirmed" and
        .wallet_qqsignal.confirmations > 0 and
        .wallet_qqsignal.expiry_height >= .height and
        (.wallet_qqsignal.source | test("^(manual|automatic|unknown)$")) and
        ([.wallet_scripts[] | select(.whitelisted == true and .recent_solver == true and
            .blocks_until_expiry >= $min_blocks and
            .seconds_until_expiry >= $min_seconds)] | length) >= 1' \
        >/dev/null <<< "$goldrush"
}

verify_legacy_quantum_special()
{
    local node="$1" goldrush
    [[ "$node" -eq 31 || "$node" -eq 32 ]] || return 1
    goldrush=$(wallet_rpc_for "$node" getgoldrushinfo) || return 1
    jq -e --argjson min_blocks "$MIN_QUANTUM_SIGNAL_BLOCKS" \
        --argjson min_seconds "$MIN_QUANTUM_SIGNAL_SECONDS" \
        '.active == true and .wallet_recent_solve_qualified == true and
        ([.wallet_scripts[] | select(.whitelisted == true and .recent_solver == true and
            .blocks_until_expiry >= $min_blocks and
            .seconds_until_expiry >= $min_seconds)] | length) >= 1' \
        >/dev/null <<< "$goldrush"
}

verify_no_reindex_log()
{
    local node="$1" container started logs
    container=$(container_for "$node")
    started=$(docker inspect -f '{{.State.StartedAt}}' "$container") || return 1
    logs=$(timeout --kill-after=2 45 docker logs --since "$started" "$container" 2>&1) || return 1
    ! grep -Eiq '(^|[^a-z])(reindexing|reindex-chainstate|reindex started|replay rebuild started|gold rush rewind)' \
        <<< "$logs"
}

verify_node_runtime_gate()
{
    local node="$1" node30_old_fee="${2:-}"
    verify_vpn_pair "$node" || return 1
    verify_container_topology "$node" "$CANDIDATE_IMAGE_REF" "$CANDIDATE_IMAGE_ID" || return 1
    assert_no_reindex_directive "$node" || return 1
    verify_no_reindex_log "$node" || return 1
    verify_core_common "$node" || return 1
    verify_replay_state "$node" || return 1
    verify_staking "$node" || return 1
    verify_donation_defaults_off "$node" || return 1
    if [[ "$node" -eq "$FREE_CLAIM_NODE" ]]; then
        verify_node30_core_role "$node30_old_fee" || return 1
    else
        verify_standard_pow "$node" "$node30_old_fee" || return 1
    fi
    if [[ "$node" -eq 31 || "$node" -eq 32 ]]; then
        verify_quantum_special "$node" || return 1
    fi
}

verify_node_gate()
{
    local node="$1" node30_old_fee="${2:-}"
    verify_node_runtime_gate "$node" "$node30_old_fee" || return 1
    if [[ "$node" -eq "$FREE_CLAIM_NODE" ]]; then
        verify_node30_free_claim_service || return 1
    fi
}

verify_policy_node_runtime_gate()
{
    local node="$1" node30_old_fee="${2:-}" padded class ref image
    padded=$(node_padded "$node") || return 1
    class=$(jq -er --arg node "$padded" '.nodes[$node]' "$IMAGE_POLICY") || return 1
    ref=$(jq -er --arg class "$class" '.images[$class].config_image' "$IMAGE_POLICY") || return 1
    image=$(jq -er --arg class "$class" '.images[$class].image_id' "$IMAGE_POLICY") || return 1
    verify_vpn_pair "$node" || return 1
    verify_container_topology "$node" "$ref" "$image" || return 1
    assert_no_reindex_directive "$node" || return 1
    verify_no_reindex_log "$node" || return 1
    verify_core_common "$node" || return 1
    verify_replay_state "$node" || return 1
    verify_staking "$node" || return 1
    verify_donation_defaults_off "$node" || return 1
    if [[ "$node" -eq "$FREE_CLAIM_NODE" ]]; then
        verify_node30_core_role "$node30_old_fee" || return 1
    else
        verify_standard_pow "$node" "$node30_old_fee" || return 1
    fi
    if [[ "$node" -eq 31 || "$node" -eq 32 ]]; then
        verify_quantum_special "$node" || return 1
    fi
}

verify_policy_node_gate()
{
    local node="$1" node30_old_fee="${2:-}"
    verify_policy_node_runtime_gate "$node" "$node30_old_fee" || return 1
    if [[ "$node" -eq "$FREE_CLAIM_NODE" ]]; then
        verify_node30_free_claim_service || return 1
    fi
}

verify_policy_legacy_runtime_gate()
{
    local node="$1" legacy_pow_baseline="${2:-}" padded class ref image network
    padded=$(node_padded "$node") || return 1
    class=$(jq -er --arg node "$padded" '.nodes[$node]' "$IMAGE_POLICY") || return 1
    ref=$(jq -er --arg class "$class" '.images[$class].config_image' "$IMAGE_POLICY") || return 1
    image=$(jq -er --arg class "$class" '.images[$class].image_id' "$IMAGE_POLICY") || return 1
    verify_vpn_pair "$node" || return 1
    verify_container_topology "$node" "$ref" "$image" || return 1
    assert_no_reindex_directive "$node" || return 1
    verify_no_reindex_log "$node" || return 1
    network=$(rpc_for "$node" getnetworkinfo) || return 1
    jq -e '.version == 300103 and .subversion == "/Blackcoin:30.1.3/" and
        .networkactive == true and .connections_out >= 3' >/dev/null <<< "$network" || return 1
    verify_core_operational "$node" "$network" || return 1
    verify_replay_state "$node" || return 1
    verify_legacy_staking "$node" || return 1
    verify_legacy_pow_role "$node" "$legacy_pow_baseline" || return 1
    if [[ "$node" -eq 31 || "$node" -eq 32 ]]; then
        verify_legacy_quantum_special "$node" || return 1
    fi
}

verify_policy_compatible_runtime_gate()
{
    local node="$1" node30_old_fee="${2:-}" legacy_pow_baseline="${3:-}" version
    version=$(rpc_for "$node" getnetworkinfo | jq -er '.version') || return 1
    case "$version" in
        300104)
            verify_policy_node_runtime_gate "$node" "$node30_old_fee"
            ;;
        300103)
            verify_policy_legacy_runtime_gate "$node" "$legacy_pow_baseline"
            ;;
        *)
            return 1
            ;;
    esac
}
