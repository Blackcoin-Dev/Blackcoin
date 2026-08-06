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

published_canary_pow_transition_is_valid()
{
    local result_file="$1" baseline_file="$2" restored_file="$3"
    local fee_baseline_file="$4" fee_final_file="$5" pow_first_file="$6" pow_second_file="$7"
    jq -en --slurpfile result "$result_file" \
        --slurpfile baseline "$baseline_file" --slurpfile restored "$restored_file" \
        --slurpfile fee_baseline "$fee_baseline_file" --slurpfile fee_final "$fee_final_file" \
        --slurpfile pow_first "$pow_first_file" --slurpfile pow_second "$pow_second_file" '
        def legacy_clean:
          type == "object" and .enabled == true and
          (.threads | type == "number" and floor == . and . == 1) and
          (.hashrate | type == "number" and . > 0) and
          (.live_claims | type == "number" and floor == . and . == 0) and
          (.quarantined_claims | type == "number" and floor == . and . == 0);
        def legacy_quarantined_disabled($count):
          type == "object" and .enabled == false and
          (.live_claims | type == "number" and floor == . and . == 0) and
          (.quarantined_claims | type == "number" and floor == . and . == $count);
        def legacy_quarantined_stalled($count):
          type == "object" and .enabled == true and .autostart == false and
          .state == "claim_quarantined" and
          (.threads | type == "number" and floor == . and . == 1) and
          (.cpu_percent | type == "number" and . == 1) and
          (.hashrate | type == "number" and . == 0) and
          (.unresolved_claims | type == "number" and floor == . and . == $count) and
          (.live_claims | type == "number" and floor == . and . == 0) and
          (.quarantined_claims | type == "number" and floor == . and . == $count) and
          .allow_automatic_quantum_key_creation == false;
        def candidate_clean:
          type == "object" and .enabled == true and
          (.threads | type == "number" and floor == . and . == 1) and
          (.cpu_percent | type == "number" and . == 1) and
          (.hashrate | type == "number" and . > 0) and
          (.live_claims | type == "number" and floor == . and . == 0) and
          (.quarantined_claims | type == "number" and floor == . and . == 0) and
          (.blocking_quarantined_claims | type == "number" and floor == . and . == 0) and
          (.raw_quarantined_claims | type == "number" and floor == . and . >= 0) and
          .claim_recovery_database_outcome_ambiguous == false and
          .allow_automatic_quantum_key_creation == false;
        def recovery_clean($fee):
          type == "object" and .policy_authoritative == true and
          .policy.automatic_authorized == false and
          .database_outcome_ambiguous == false and .wallet_tip_matches == true and
          .blocking_quarantined_claims == 0 and .blocking_components == 0 and
          .indeterminate_quarantined_claims == 0 and
          .pending_manual_resolutions == 0 and .pending_automatic_resolutions == 0 and
          (.confirmed_resolution_fees | type == "number" and . == $fee);
        ($result | length) == 1 and ($baseline | length) == 1 and
        ($restored | length) == 1 and ($fee_baseline | length) == 1 and
        ($fee_final | length) == 1 and ($pow_first | length) == 1 and
        ($pow_second | length) == 1 and
        ($result[0] as $r |
          $baseline[0].live_claims == $r.legacy_baseline_live_claims and
          $baseline[0].quarantined_claims == $r.legacy_baseline_quarantined_claims and
          $restored[0].live_claims == $r.restored_legacy_live_claims and
          $restored[0].quarantined_claims == $r.restored_legacy_quarantined_claims and
          (if $r.legacy_baseline_pow_mode == "clean-hashing" then
           ($baseline[0] | legacy_clean) and ($restored[0] | legacy_clean)
           else
             (if $r.legacy_observed_pow_mode == "quarantined-stalled" then
                ($baseline[0] |
                  legacy_quarantined_stalled($r.legacy_baseline_quarantined_claims))
              else
                ($baseline[0] |
                  legacy_quarantined_disabled($r.legacy_baseline_quarantined_claims))
              end) and
             ($restored[0] |
               legacy_quarantined_disabled($r.legacy_baseline_quarantined_claims))
           end) and
          ($fee_baseline[0] | recovery_clean($r.claim_recovery_fee_baseline)) and
          ($fee_final[0] | recovery_clean($r.claim_recovery_fee_final)) and
          ($pow_first[0] | candidate_clean) and ($pow_second[0] | candidate_clean))
    ' >/dev/null
}

verify_published_canary()
{
    local evidence_dir ops_dir stamp actual_result_sha actual_manifest_sha protected suffix
    local identity_file restore_file launch_file prelaunch_txids_file locked_txids_file
    local baseline_pow_file restored_pow_file recovery_fee_baseline_file recovery_fee_final_file
    local candidate_pow_first_file candidate_pow_second_file
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
        (.claim_recovery_fee_baseline | type) == "number" and
        (.claim_recovery_fee_final | type) == "number" and
        .claim_recovery_fee_baseline >= 0 and
        .claim_recovery_fee_final == .claim_recovery_fee_baseline and
        (.legacy_baseline_pow_mode == "clean-hashing" or
          .legacy_baseline_pow_mode == "quarantined-disabled") and
        (.legacy_baseline_live_claims | type) == "number" and
        .legacy_baseline_live_claims == 0 and
        (.legacy_baseline_quarantined_claims | type) == "number" and
        (.legacy_baseline_quarantined_claims | floor == .) and
        (if .legacy_baseline_pow_mode == "clean-hashing" then
           .legacy_baseline_quarantined_claims == 0
         else .legacy_baseline_quarantined_claims == 1 end) and
        (.restored_legacy_live_claims | type) == "number" and
        (.restored_legacy_live_claims | floor == .) and
        (.restored_legacy_quarantined_claims | type) == "number" and
        (.restored_legacy_quarantined_claims | floor == .) and
        .restored_legacy_live_claims == .legacy_baseline_live_claims and
        .restored_legacy_quarantined_claims == .legacy_baseline_quarantined_claims and
        .legacy_quarantined_claim_count_preserved == true and
        .legacy_quarantined_claim_resolution_attempted == false and
        .legacy_quarantined_claim_fee_paid == false and
        .candidate_pow_clean_hashing_verified == true and
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
    baseline_pow_file="$evidence_dir/baseline-pow.json"
    restored_pow_file="$evidence_dir/restored-pow.json"
    recovery_fee_baseline_file="$evidence_dir/candidate-recovery-fee-baseline.json"
    recovery_fee_final_file="$evidence_dir/candidate-safe-2-recovery-clean.json"
    candidate_pow_first_file="$evidence_dir/candidate-pow-clean-1.json"
    candidate_pow_second_file="$evidence_dir/candidate-pow-clean-2.json"
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
        "$baseline_pow_file" "$restored_pow_file" "$recovery_fee_baseline_file" \
        "$recovery_fee_final_file" "$candidate_pow_first_file" "$candidate_pow_second_file" \
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
    published_canary_pow_transition_is_valid "$PUBLISHED_CANARY_RESULT" \
        "$baseline_pow_file" "$restored_pow_file" "$recovery_fee_baseline_file" \
        "$recovery_fee_final_file" "$candidate_pow_first_file" "$candidate_pow_second_file" ||
        return 1
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
            "Recreate node27 only from the pinned base Compose model and original immutable image, then run the pinned normal-unlock helper. Run the pinned PoW helper only when baseline-pow.json proves the legacy baseline was clean one-thread hashing; when it proves disabled PoW with zero live claims and exactly one quarantined claim, do not run the PoW helper or attempt claim resolution.",
            "Prove the original image and invocation, healthy RPC/network/chain, active PoS, either clean one-thread PoW or the exact disabled legacy quarantined-claim count, wallet/config/address/key/transaction identity, and exact pre-upgrade data restoration.",
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

published_canary_recovery_is_valid()
{
    [[ "$#" == 4 ]] || return 1
    local recovery_file="$1" transaction_file="$2"
    local baseline_transactions_file="$3" fee="$4"
    jq -en --argjson fee "$fee" --slurpfile recovery "$recovery_file" \
        --slurpfile transactions "$transaction_file" '
        def hex64: type == "string" and test("^[0-9a-f]{64}$");
        def integer: type == "number" and floor == .;
        ($recovery | length) == 1 and ($transactions | length) == 1 and
        ($recovery[0] |
          type == "object" and .policy_authoritative == true and
          .policy.automatic_authorized == false and
          .database_outcome_ambiguous == false and .chain_ready == true and
          .wallet_tip_matches == true and .blocking_quarantined_claims == 0 and
          .blocking_components == 0 and .indeterminate_quarantined_claims == 0 and
          .pending_manual_resolutions == 0 and .pending_automatic_resolutions == 0 and
          (.confirmed_resolution_fees | type) == "number" and
          .confirmed_resolution_fees == $fee and
          (.wallet_generation | integer and . >= 0)) and
        ($transactions[0] |
          type == "array" and all(.[]; hex64) and . == (unique | sort))
    ' >/dev/null || return 1
    cmp -s "$baseline_transactions_file" "$transaction_file"
}

published_canary_recovery_inventory_is_valid()
{
    local recovery_file="$1" transaction_file="$2" inventory_file="$3" fee="$4"
    jq -en --argjson fee "$fee" --slurpfile recovery "$recovery_file" \
        --slurpfile transactions "$transaction_file" --slurpfile inventory "$inventory_file" '
        def hex64: type == "string" and test("^[0-9a-f]{64}$");
        def integer: type == "number" and floor == .;
        def canonical_txids:
          type == "array" and all(.[]; hex64) and . == (unique | sort);
        def recovery_clean($fee):
          type == "object" and .policy_authoritative == true and
          .policy.automatic_authorized == false and
          .database_outcome_ambiguous == false and .chain_ready == true and
          .wallet_tip_matches == true and .blocking_quarantined_claims == 0 and
          .blocking_components == 0 and .indeterminate_quarantined_claims == 0 and
          .pending_manual_resolutions == 0 and .pending_automatic_resolutions == 0 and
          (.confirmed_resolution_fees | type) == "number" and
          .confirmed_resolution_fees == $fee and
          (.wallet_generation | integer and . >= 0);
        def inventory_source:
          . as $r |
          ($r | type) == "object" and
          ($r.raw_claim_objects | integer and . > 0) and
          ($r.quarantined_claim_objects |
            integer and . > 0 and . <= $r.raw_claim_objects) and
          ($r.components | integer and . > 0) and
          ($r.resolved_components | integer and . == $r.components) and
          ($r.retired_components | integer and . == 0) and
          ($r.component_details |
            type == "array" and length == $r.components and all(.[];
            .classification == "resolved_on_active_chain" and
            .anchor_authenticated == true and .anchor_unspent == false and
            (.anchor | type) == "object" and (.anchor.txid | hex64) and
            (.anchor.vout | integer and . >= 0) and
            (.generation_fingerprint | hex64) and
            (.claim_txids | type == "array" and length > 0 and all(.[]; hex64)) and
            (.root_claim_txids | type == "array" and length > 0 and all(.[]; hex64)) and
            (.resolution_txids | type == "array" and length == 0)));
        def inherited_inventory:
          . as $r |
          ([ $r.component_details[].claim_txids[] ] | unique | sort) as $claim_txids |
          {schema:1,classification:"resolved_on_active_chain",
           raw_claim_objects:$r.raw_claim_objects,
           quarantined_claim_objects:$r.quarantined_claim_objects,
           components:$r.components,resolved_components:$r.resolved_components,
           retired_components:$r.retired_components,claim_txids:$claim_txids,
           component_identities:([$r.component_details[] |
             {anchor,generation_fingerprint,
              claim_txids:(.claim_txids | unique | sort),
              root_claim_txids:(.root_claim_txids | unique | sort)}] |
             sort_by(.anchor.txid,.anchor.vout,.generation_fingerprint))};
        ($recovery | length) == 1 and ($transactions | length) == 1 and
        ($inventory | length) == 1 and
        ($recovery[0] as $r | $transactions[0] as $t |
          ($r | recovery_clean($fee)) and ($r | inventory_source) and
          ($t | canonical_txids) and
          ([ $r.component_details[].claim_txids[] ] | unique | sort |
            all(. as $txid | $t | index($txid) != null)) and
          $inventory[0] == ($r | inherited_inventory))
    ' >/dev/null
}

published_canary_candidate_disabled_boundary_is_valid()
{
    [[ "$#" == 9 ]] || return 1
    local wallet_file="$1" staking_file="$2" pow_file="$3" recovery_file="$4"
    local transaction_file="$5" baseline_transactions_file="$6" inventory_file="$7"
    local claim_mode="$8" fee="$9"
    jq -en --argjson fee "$fee" --slurpfile wallet "$wallet_file" \
        --slurpfile staking "$staking_file" --slurpfile pow "$pow_file" \
        --slurpfile recovery "$recovery_file" '
        def integer: type == "number" and floor == .;
        ($wallet | length) == 1 and ($staking | length) == 1 and
        ($pow | length) == 1 and ($recovery | length) == 1 and
        ($wallet[0] |
          type == "object" and .private_keys_enabled == true and
          (.unlocked_until | type) == "number" and .unlocked_until == 0) and
        ($staking[0] |
          type == "object" and .enabled == false and .staking == false and
          .worker_running == false and .staking_state == "disabled" and
          .automatic_qqsignal == false and
          .automatic_demurrage_attestation == false and
          .automatic_redelegation == false and
          .allow_automatic_quantum_key_creation == false) and
        ($pow[0] |
          type == "object" and .enabled == false and .autostart == false and
          .state == "disabled" and (.threads | integer and . == 1) and
          (.cpu_percent | type) == "number" and .cpu_percent == 1 and
          (.hashrate | type) == "number" and .hashrate == 0 and
          (.unresolved_claims | integer and . == 0) and
          (.live_claims | integer and . == 0) and
          (.quarantined_claims | integer and . == 0) and
          (.blocking_quarantined_claims | integer and . == 0) and
          (.indeterminate_quarantined_claims | integer and . == 0) and
          .claim_recovery_database_outcome_ambiguous == false and
          .allow_automatic_quantum_key_creation == false) and
        ($recovery[0] |
          type == "object" and .policy_authoritative == true and
          .policy.automatic_authorized == false and
          .database_outcome_ambiguous == false and .chain_ready == true and
          .wallet_tip_matches == true and .blocking_quarantined_claims == 0 and
          .blocking_components == 0 and .indeterminate_quarantined_claims == 0 and
          .pending_manual_resolutions == 0 and .pending_automatic_resolutions == 0 and
          (.confirmed_resolution_fees | type) == "number" and
          .confirmed_resolution_fees == $fee and
          (.wallet_generation | integer and . >= 0))
    ' >/dev/null || return 1
    published_canary_recovery_is_valid "$recovery_file" "$transaction_file" \
        "$baseline_transactions_file" "$fee" || return 1
    case "$claim_mode" in
        clean-hashing)
            [[ -z "$inventory_file" ]]
            ;;
        quarantined-disabled)
            [[ -n "$inventory_file" ]] && published_canary_recovery_inventory_is_valid \
                "$recovery_file" "$transaction_file" "$inventory_file" "$fee"
            ;;
        *) return 1 ;;
    esac
}

published_canary_activation_boundary_is_valid()
{
    [[ "$#" == 17 ]] || return 1
    local sequence="$1" purpose="$2" marker_file="$3" wallet_file="$4"
    local staking_file="$5" pow_file="$6" recovery_file="$7" transaction_file="$8"
    local baseline_transactions_file="$9" inventory_file="${10}" image="${11}"
    local claim_mode="${11}" image="${12}" image_id="${13}" launch_sha="${14}"
    local nonce_sha="${15}" transition_sha="${16}" fee="${17}"
    local timestamp wallet_sha staking_sha pow_sha
    local recovery_sha transaction_sha
    published_canary_candidate_disabled_boundary_is_valid "$wallet_file" "$staking_file" \
        "$pow_file" "$recovery_file" "$transaction_file" "$baseline_transactions_file" \
        "$inventory_file" "$claim_mode" "$fee" || return 1
    timestamp=$(jq -er '.timestamp | select(type == "string" and
        test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))' \
        "$marker_file") || return 1
    wallet_sha=$(sha256sum "$wallet_file" | awk '{print $1}') || return 1
    staking_sha=$(sha256sum "$staking_file" | awk '{print $1}') || return 1
    pow_sha=$(sha256sum "$pow_file" | awk '{print $1}') || return 1
    recovery_sha=$(sha256sum "$recovery_file" | awk '{print $1}') || return 1
    transaction_sha=$(sha256sum "$transaction_file" | awk '{print $1}') || return 1
    jq -se --argjson sequence "$sequence" --arg purpose "$purpose" \
        --arg image "$image" --arg image_id "$image_id" --arg launch_sha "$launch_sha" \
        --arg nonce_sha "$nonce_sha" --arg transaction_sha "$transaction_sha" \
        --arg recovery_sha "$recovery_sha" --arg pow_sha "$pow_sha" \
        --arg staking_sha "$staking_sha" --arg wallet_sha "$wallet_sha" \
        --arg transition_sha "$transition_sha" --argjson fee "$fee" \
        --arg timestamp "$timestamp" '
        length == 1 and .[0] == {
          schema:1,sequence:$sequence,purpose:$purpose,
          signing_authority_may_have_been_granted:true,
          candidate_image:$image,candidate_image_id:$image_id,
          candidate_launch_marker_sha256:$launch_sha,
          maintenance_nonce_sha256:$nonce_sha,
          exact_transaction_set_sha256:$transaction_sha,
          recovery_evidence_sha256:$recovery_sha,pow_evidence_sha256:$pow_sha,
          staking_evidence_sha256:$staking_sha,wallet_evidence_sha256:$wallet_sha,
          inherited_claim_transition_sha256:$transition_sha,
          confirmed_resolution_fees:$fee,timestamp:$timestamp}
    ' "$marker_file" >/dev/null
}

published_canary_safe_boundary_is_valid()
{
    [[ "$#" == 15 ]] || return 1
    local sequence="$1" purpose="$2" marker_file="$3" activation_sha="$4"
    local wallet_file="$5" staking_file="$6" pow_file="$7" recovery_file="$8"
    local transaction_file="$9" baseline_transactions_file="${10}" inventory_file="${11}"
    local claim_mode="${12}" image="${13}" image_id="${14}" fee="${15}"
    local timestamp wallet_generation
    local wallet_sha staking_sha pow_sha recovery_sha transaction_sha
    published_canary_candidate_disabled_boundary_is_valid "$wallet_file" "$staking_file" \
        "$pow_file" "$recovery_file" "$transaction_file" "$baseline_transactions_file" \
        "$inventory_file" "$claim_mode" "$fee" || return 1
    timestamp=$(jq -er '.timestamp | select(type == "string" and
        test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))' \
        "$marker_file") || return 1
    wallet_generation=$(jq -er '.wallet_generation |
        select(type == "number" and floor == . and . >= 0)' "$recovery_file") || return 1
    wallet_sha=$(sha256sum "$wallet_file" | awk '{print $1}') || return 1
    staking_sha=$(sha256sum "$staking_file" | awk '{print $1}') || return 1
    pow_sha=$(sha256sum "$pow_file" | awk '{print $1}') || return 1
    recovery_sha=$(sha256sum "$recovery_file" | awk '{print $1}') || return 1
    transaction_sha=$(sha256sum "$transaction_file" | awk '{print $1}') || return 1
    jq -se --argjson sequence "$sequence" --arg purpose "$purpose" \
        --arg image "$image" --arg image_id "$image_id" \
        --arg activation_sha "$activation_sha" --arg transaction_sha "$transaction_sha" \
        --arg wallet_sha "$wallet_sha" --arg staking_sha "$staking_sha" \
        --arg pow_sha "$pow_sha" --arg recovery_sha "$recovery_sha" \
        --argjson fee "$fee" --argjson wallet_generation "$wallet_generation" \
        --arg timestamp "$timestamp" '
        length == 1 and .[0] == {
          schema:1,sequence:$sequence,purpose:$purpose,safe_to_stop_or_rollback:true,
          candidate_image:$image,candidate_image_id:$image_id,
          activation_marker_sha256:$activation_sha,
          exact_transaction_set_sha256:$transaction_sha,
          wallet_evidence_sha256:$wallet_sha,staking_evidence_sha256:$staking_sha,
          pow_evidence_sha256:$pow_sha,recovery_evidence_sha256:$recovery_sha,
          confirmed_resolution_fees:$fee,staking_disabled:true,pow_disabled:true,
          wallet_locked:true,claim_gate_q0:true,wallet_generation:$wallet_generation,
          timestamp:$timestamp}
    ' "$marker_file" >/dev/null
}

published_canary_legacy_q1_transition_is_valid()
{
    [[ "$#" == 10 ]] || return 1
    local result_file="$1" baseline_pow_file="$2" restored_pow_file="$3"
    local inventory_file="$4" transition_file="$5" observed_recovery_file="$6"
    local normalized_recovery_file="$7" normalized_pow_file="$8"
    local normalized_transactions_file="$9" baseline_transactions_file="${10}"
    local inventory_sha transition_sha observed_sha normalized_sha transaction_sha fee
    inventory_sha=$(sha256sum "$inventory_file" | awk '{print $1}') || return 1
    transition_sha=$(sha256sum "$transition_file" | awk '{print $1}') || return 1
    observed_sha=$(sha256sum "$observed_recovery_file" | awk '{print $1}') || return 1
    normalized_sha=$(sha256sum "$normalized_recovery_file" | awk '{print $1}') || return 1
    transaction_sha=$(sha256sum "$normalized_transactions_file" | awk '{print $1}') || return 1
    fee=$(jq -er '.claim_recovery_fee_baseline |
        select(type == "number" and . >= 0)' "$result_file") || return 1
    cmp -s "$baseline_transactions_file" "$normalized_transactions_file" || return 1
    published_canary_recovery_inventory_is_valid "$observed_recovery_file" \
        "$normalized_transactions_file" "$inventory_file" "$fee" || return 1
    published_canary_recovery_inventory_is_valid "$normalized_recovery_file" \
        "$normalized_transactions_file" "$inventory_file" "$fee" || return 1
    jq -en --arg inventory_sha "$inventory_sha" --arg transition_sha "$transition_sha" \
        --arg observed_sha "$observed_sha" --arg normalized_sha "$normalized_sha" \
        --arg transaction_sha "$transaction_sha" --argjson fee "$fee" \
        --slurpfile result "$result_file" --slurpfile baseline "$baseline_pow_file" \
        --slurpfile restored "$restored_pow_file" --slurpfile normalized_pow "$normalized_pow_file" \
        --slurpfile transition "$transition_file" '
        def integer: type == "number" and floor == .;
        def legacy_q1_disabled:
          type == "object" and .enabled == false and .autostart == false and
          .state == "disabled" and (.threads | integer and . == 1) and
          (.cpu_percent | type) == "number" and .cpu_percent == 1 and
          (.hashrate | type) == "number" and .hashrate == 0 and
          (.unresolved_claims | integer and . == 1) and
          (.live_claims | integer and . == 0) and
          (.quarantined_claims | integer and . == 1) and
          .allow_automatic_quantum_key_creation == false;
        def legacy_q1_stalled:
          type == "object" and .enabled == true and .autostart == false and
          .state == "claim_quarantined" and (.threads | integer and . == 1) and
          (.cpu_percent | type) == "number" and .cpu_percent == 1 and
          (.hashrate | type) == "number" and .hashrate == 0 and
          (.unresolved_claims | integer and . == 1) and
          (.live_claims | integer and . == 0) and
          (.quarantined_claims | integer and . == 1) and
          .allow_automatic_quantum_key_creation == false;
        def candidate_q0_disabled:
          type == "object" and .enabled == false and .autostart == false and
          .state == "disabled" and (.threads | integer and . == 1) and
          (.cpu_percent | type) == "number" and .cpu_percent == 1 and
          (.hashrate | type) == "number" and .hashrate == 0 and
          (.unresolved_claims | integer and . == 0) and
          (.live_claims | integer and . == 0) and
          (.quarantined_claims | integer and . == 0) and
          (.blocking_quarantined_claims | integer and . == 0) and
          (.indeterminate_quarantined_claims | integer and . == 0) and
          .claim_recovery_database_outcome_ambiguous == false and
          .allow_automatic_quantum_key_creation == false;
        ($result | length) == 1 and ($baseline | length) == 1 and
        ($restored | length) == 1 and ($normalized_pow | length) == 1 and
        ($transition | length) == 1 and
        ($result[0] as $r |
          $r.legacy_baseline_pow_mode == "quarantined-disabled" and
          ($r.legacy_observed_pow_mode == "quarantined-disabled" or
            $r.legacy_observed_pow_mode == "quarantined-stalled") and
          $r.legacy_baseline_live_claims == 0 and
          $r.legacy_baseline_quarantined_claims == 1 and
          $r.restored_legacy_live_claims == 0 and
          $r.restored_legacy_quarantined_claims == 1 and
          $r.legacy_quarantined_claim_count_preserved == true and
          $r.legacy_quarantined_claim_resolution_attempted == false and
          $r.legacy_quarantined_claim_fee_paid == false and
          $r.inherited_claim_inventory_present == true and
          $r.inherited_claim_inventory_evidence ==
            "candidate-inherited-claim-inventory.json" and
          $r.inherited_claim_inventory_sha256 == $inventory_sha and
          $r.inherited_claim_transition_evidence ==
            "candidate-inherited-claim-transition.json" and
          $r.inherited_claim_transition_sha256 == $transition_sha and
          $r.claim_baseline_transition_kind ==
            "legacy_q1_to_candidate_q0_no_payment" and
          $r.legacy_q1_candidate_q0_no_payment_reclassification_verified == true and
          $r.clean_q0_candidate_q0_no_payment_transition_verified == false and
          $r.claim_recovery_fee_baseline == $fee and
          $r.claim_recovery_fee_final == $fee and
          (if $r.legacy_observed_pow_mode == "quarantined-stalled" then
             ($baseline[0] | legacy_q1_stalled)
           else ($baseline[0] | legacy_q1_disabled) end) and
          ($restored[0] | legacy_q1_disabled) and
          ($normalized_pow[0] | candidate_q0_disabled) and
          $transition[0] == {
            schema:1,legacy_mode:"quarantined-disabled",
            legacy_q1_candidate_q0_no_payment_reclassification:true,
            inherited_claim_inventory_sha256:$inventory_sha,
            observed_recovery_sha256:$observed_sha,
            normalized_recovery_sha256:$normalized_sha,
            exact_transaction_set_sha256:$transaction_sha,
            confirmed_resolution_fees:$fee,resolver_invoked:false,payment_created:false})
    ' >/dev/null
}

published_canary_clean_q0_transition_is_valid()
{
    [[ "$#" == 9 ]] || return 1
    local result_file="$1" baseline_pow_file="$2" restored_pow_file="$3"
    local transition_file="$4" observed_recovery_file="$5"
    local normalized_recovery_file="$6" normalized_pow_file="$7"
    local normalized_transactions_file="$8" baseline_transactions_file="$9"
    local transition_sha observed_sha normalized_sha transaction_sha fee
    transition_sha=$(sha256sum "$transition_file" | awk '{print $1}') || return 1
    observed_sha=$(sha256sum "$observed_recovery_file" | awk '{print $1}') || return 1
    normalized_sha=$(sha256sum "$normalized_recovery_file" | awk '{print $1}') || return 1
    transaction_sha=$(sha256sum "$normalized_transactions_file" | awk '{print $1}') || return 1
    fee=$(jq -er '.claim_recovery_fee_baseline |
        select(type == "number" and . >= 0)' "$result_file") || return 1
    published_canary_recovery_is_valid "$observed_recovery_file" \
        "$normalized_transactions_file" "$baseline_transactions_file" "$fee" || return 1
    published_canary_recovery_is_valid "$normalized_recovery_file" \
        "$normalized_transactions_file" "$baseline_transactions_file" "$fee" || return 1
    jq -en --arg transition_sha "$transition_sha" --arg observed_sha "$observed_sha" \
        --arg normalized_sha "$normalized_sha" --arg transaction_sha "$transaction_sha" \
        --argjson fee "$fee" --slurpfile result "$result_file" \
        --slurpfile baseline "$baseline_pow_file" --slurpfile restored "$restored_pow_file" \
        --slurpfile normalized_pow "$normalized_pow_file" \
        --slurpfile transition "$transition_file" '
        def integer: type == "number" and floor == .;
        def legacy_q0_hashing:
          type == "object" and .enabled == true and .autostart == false and
          (.threads | integer and . == 1) and
          (.cpu_percent | type) == "number" and .cpu_percent == 1 and
          (.hashrate | type) == "number" and .hashrate > 0 and
          (.unresolved_claims | integer and . == 0) and
          (.live_claims | integer and . == 0) and
          (.quarantined_claims | integer and . == 0) and
          .allow_automatic_quantum_key_creation == false;
        def candidate_q0_disabled:
          type == "object" and .enabled == false and .autostart == false and
          .state == "disabled" and (.threads | integer and . == 1) and
          (.cpu_percent | type) == "number" and .cpu_percent == 1 and
          (.hashrate | type) == "number" and .hashrate == 0 and
          (.unresolved_claims | integer and . == 0) and
          (.live_claims | integer and . == 0) and
          (.quarantined_claims | integer and . == 0) and
          (.blocking_quarantined_claims | integer and . == 0) and
          (.indeterminate_quarantined_claims | integer and . == 0) and
          .claim_recovery_database_outcome_ambiguous == false and
          .allow_automatic_quantum_key_creation == false;
        ($result | length) == 1 and ($baseline | length) == 1 and
        ($restored | length) == 1 and ($normalized_pow | length) == 1 and
        ($transition | length) == 1 and
        ($result[0] as $r |
          $r.legacy_observed_pow_mode == "clean-hashing" and
          $r.legacy_baseline_pow_mode == "clean-hashing" and
          $r.legacy_baseline_live_claims == 0 and
          $r.legacy_baseline_quarantined_claims == 0 and
          $r.restored_legacy_live_claims == 0 and
          $r.restored_legacy_quarantined_claims == 0 and
          $r.legacy_quarantined_claim_count_preserved == true and
          $r.legacy_quarantined_claim_resolution_attempted == false and
          $r.legacy_quarantined_claim_fee_paid == false and
          $r.inherited_claim_inventory_present == false and
          $r.inherited_claim_inventory_evidence == null and
          $r.inherited_claim_inventory_sha256 == null and
          $r.inherited_claim_transition_evidence ==
            "candidate-inherited-claim-transition.json" and
          $r.inherited_claim_transition_sha256 == $transition_sha and
          $r.claim_baseline_transition_kind ==
            "clean_q0_to_candidate_q0_no_payment" and
          $r.legacy_q1_candidate_q0_no_payment_reclassification_verified == false and
          $r.clean_q0_candidate_q0_no_payment_transition_verified == true and
          $r.claim_recovery_fee_baseline == $fee and
          $r.claim_recovery_fee_final == $fee and
          ($baseline[0] | legacy_q0_hashing) and
          ($restored[0] | legacy_q0_hashing) and
          ($normalized_pow[0] | candidate_q0_disabled) and
          $transition[0] == {
            schema:1,legacy_mode:"clean-hashing",
            legacy_q1_candidate_q0_no_payment_reclassification:false,
            clean_q0_candidate_q0_no_payment_transition:true,
            inherited_claim_inventory_sha256:null,
            observed_recovery_sha256:$observed_sha,
            normalized_recovery_sha256:$normalized_sha,
            exact_transaction_set_sha256:$transaction_sha,
            confirmed_resolution_fees:$fee,resolver_invoked:false,payment_created:false})
    ' >/dev/null
}

published_canary_claim_transition_is_valid()
{
    [[ "$#" == 10 ]] || return 1
    local result_file="$1" baseline_pow_file="$2" restored_pow_file="$3"
    local inventory_file="$4" transition_file="$5" observed_recovery_file="$6"
    local normalized_recovery_file="$7" normalized_pow_file="$8"
    local normalized_transactions_file="$9" baseline_transactions_file="${10}"
    local claim_mode
    claim_mode=$(jq -er '.legacy_baseline_pow_mode' "$result_file") || return 1
    case "$claim_mode" in
        clean-hashing)
            [[ ! -e "$inventory_file" && ! -L "$inventory_file" ]] || return 1
            published_canary_clean_q0_transition_is_valid "$result_file" \
                "$baseline_pow_file" "$restored_pow_file" "$transition_file" \
                "$observed_recovery_file" "$normalized_recovery_file" \
                "$normalized_pow_file" "$normalized_transactions_file" \
                "$baseline_transactions_file"
            ;;
        quarantined-disabled)
            published_canary_legacy_q1_transition_is_valid "$result_file" \
                "$baseline_pow_file" "$restored_pow_file" "$inventory_file" \
                "$transition_file" "$observed_recovery_file" \
                "$normalized_recovery_file" "$normalized_pow_file" \
                "$normalized_transactions_file" "$baseline_transactions_file"
            ;;
        *) return 1 ;;
    esac
}

verify_published_canary_handoff_ready()
{
    local evidence_dir ops_dir stamp protected actual_result_sha actual_manifest_sha nonce
    local identity_file restore_file launch_file prelaunch_txids_file locked_txids_file
    local baseline_pow_file restored_pow_file recovery_fee_baseline_file recovery_fee_final_file
    local candidate_pow_first_file candidate_pow_second_file activation_file nonce_evidence_file
    local active_state_file recovery_file guard_identities_file activation_one_file
    local activation_two_file safe_one_file safe_two_file handoff_file nonce_file state_file
    local parent_recovery_file identity_sha restore_sha launch_sha prelaunch_txids_sha
    local locked_txids_sha activation_sha active_state_sha recovery_sha guard_sha
    local activation_one_sha activation_two_sha safe_one_sha safe_two_sha handoff_sha
    local inventory_file transition_file inherited_observed_file inherited_normalized_file
    local inherited_pow_file inherited_txids_file nonce_sha transition_sha fee sequence purpose
    local claim_mode boundary_inventory_file
    local boundary_wallet boundary_staking boundary_pow boundary_recovery boundary_txids
    local first_wallet first_staking first_pow first_recovery first_txids first_generation
    local second_generation boundary_marker boundary_activation_sha
    local expected_identity_sha expected_restore_sha expected_launch_sha
    local expected_prelaunch_txids_sha expected_locked_txids_sha suffix launch_timestamp
    local handoff_timestamp identity_set_sha restore_set_sha result_snapshot_set_sha
    local compatible_runtime_sha='9ed02479801cb0de4085f9d6055500bb7d22de86d2fc2b91be6c19e9955398ee'
    local compatible_endpoint_sha='81135dd9637cd5b4fa42a0c634f1decb37fcd68a280c55c661b640226196880f'

    [[ "$SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || return 1
    evidence_dir=${PUBLISHED_CANARY_RESULT%/*}
    ops_dir=${evidence_dir%/evidence}
    stamp=${ops_dir##*/node27-canary-}
    [[ "$PUBLISHED_CANARY_RESULT" == "$evidence_dir/RESULT.json" &&
       "$PUBLISHED_CANARY_EVIDENCE_MANIFEST" == "$evidence_dir/SHA256SUMS" &&
       "$evidence_dir" =~ ^/mnt/pulsar/Blackcoin_Blocks/operations/releases/v30[.]1[.]4-${SOURCE_COMMIT}/node27-canary-[0-9]{8}T[0-9]{6}Z/evidence$ &&
       "$stamp" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || return 1
    [[ -d "$ops_dir" && ! -L "$ops_dir" &&
       "$(realpath -e -- "$ops_dir")" == "$ops_dir" &&
       "$(stat -c '%u:%g:%a' "$ops_dir")" == 0:0:700 &&
       -d "$evidence_dir" && ! -L "$evidence_dir" &&
       "$(realpath -e -- "$evidence_dir")" == "$evidence_dir" &&
       "$(stat -c '%u:%g:%a' "$evidence_dir")" == 0:0:700 ]] || return 1
    [[ -z "$(find "$evidence_dir" -mindepth 1 ! -type f -print -quit)" ]] || return 1
    while IFS= read -r -d '' protected; do
        [[ ! -L "$protected" && "$(realpath -e -- "$protected")" == "$protected" &&
           "$(stat -c '%u:%g:%a' "$protected")" == 0:0:600 ]] || return 1
    done < <(find "$evidence_dir" -mindepth 1 -maxdepth 1 -type f -print0)
    [[ -s "$PUBLISHED_CANARY_EVIDENCE_MANIFEST" &&
       -z "$(grep -Ev '^[0-9a-f]{64}  [.]\/[A-Za-z0-9][A-Za-z0-9._-]*$' \
           "$PUBLISHED_CANARY_EVIDENCE_MANIFEST" || true)" &&
       -z "$(awk '{print $2}' "$PUBLISHED_CANARY_EVIDENCE_MANIFEST" | sort | uniq -d)" &&
       "$(grep -Fc '  ./SHA256SUMS' "$PUBLISHED_CANARY_EVIDENCE_MANIFEST")" == 0 ]] ||
        return 1
    cmp -s \
        <(cd "$evidence_dir" && find . -mindepth 1 -maxdepth 1 -type f \
            ! -path './SHA256SUMS' -print | sort) \
        <(awk '{print $2}' "$PUBLISHED_CANARY_EVIDENCE_MANIFEST" | sort) || return 1
    actual_result_sha=$(sha256sum "$PUBLISHED_CANARY_RESULT" | awk '{print $1}') || return 1
    actual_manifest_sha=$(sha256sum "$PUBLISHED_CANARY_EVIDENCE_MANIFEST" | awk '{print $1}') ||
        return 1
    [[ "$actual_result_sha" == "$EXPECTED_CANARY_RESULT_SHA256" &&
       "$actual_manifest_sha" == "$EXPECTED_CANARY_EVIDENCE_MANIFEST_SHA256" ]] || return 1
    (cd "$evidence_dir" && sha256sum --strict -c SHA256SUMS >/dev/null) || return 1

    jq -se --arg source "$SOURCE_COMMIT" --arg image "$CANDIDATE_IMAGE_REF" \
        --arg image_id "$CANDIDATE_IMAGE_ID" --arg marker "$ROLLOUT_MAINTENANCE_MARKER" \
        --arg run "$ops_dir" \
        --arg data 'pulsar/Blackcoin_Blocks/node-data/node-27' \
        --arg blocks 'pulsar/Blackcoin_Blocks/node-data/node-27/blocks' \
        --arg indexes 'pulsar/Blackcoin_Blocks/node-data/node-27/indexes' \
        --arg raw 'pulsar/Blackcoin_Blocks/alpha-chain-raw-clones-20260715T032403Z/node-27' '
        length == 1 and (.[0] |
        .schema == 1 and .result == "passed" and .node == 27 and
        .candidate_mode == "published-package-image" and
        .source_sha == $source and .candidate_image == $image and
        .candidate_image_id == $image_id and .rolled_back_to == "30.1.3" and
        .same_effective_entrypoint == true and .fee_payments_authorized == false and
        .claim_recovery_fee_unchanged == true and .wallet_identity_unchanged == true and
        (.claim_recovery_fee_baseline | type) == "number" and
        .claim_recovery_fee_baseline >= 0 and
        .claim_recovery_fee_final == .claim_recovery_fee_baseline and
        (.legacy_baseline_live_claims | type) == "number" and
        (.legacy_baseline_live_claims | floor) == .legacy_baseline_live_claims and
        .legacy_baseline_live_claims == 0 and
        (.legacy_baseline_quarantined_claims | type) == "number" and
        (.legacy_baseline_quarantined_claims | floor) ==
          .legacy_baseline_quarantined_claims and
        .restored_legacy_live_claims == .legacy_baseline_live_claims and
        .restored_legacy_quarantined_claims == .legacy_baseline_quarantined_claims and
        .legacy_quarantined_claim_count_preserved == true and
        .legacy_quarantined_claim_resolution_attempted == false and
        .legacy_quarantined_claim_fee_paid == false and
        .inherited_claim_transition_evidence ==
          "candidate-inherited-claim-transition.json" and
        (.inherited_claim_transition_sha256 | test("^[0-9a-f]{64}$")) and
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
         else false end) and
        .candidate_pow_clean_hashing_verified == true and
        .recovery_fee_baseline_established_while_wallet_locked == true and
        .locked_candidate_transaction_set_unchanged == true and
        (.prelaunch_transaction_set_sha256 | test("^[0-9a-f]{64}$")) and
        .locked_candidate_transaction_set_sha256 == .prelaunch_transaction_set_sha256 and
        .automatic_wallet_features_default_off_verified == true and
        .candidate_network_ready_verified == true and
        .replay_marker_exact_tip_verified == true and
        .configuration_identity_unchanged == true and .reindex_observed == false and
        .reindex_or_replay_rebuild_observed == false and
        .pre_upgrade_data_restored == true and .snapshot_identity_verified == true and
        .snapshot_zero_diff_verified == true and .candidate_launch_attempted == true and
        .zfs_snapshot_holds_released == true and
        .automatic_start_authority_restored == true and
        .maintenance_marker_activated == true and .maintenance_marker_released == false and
        .live_marker_active == true and .maintenance_handoff_ready == true and
        .crash_safe_supervisor_inhibition_verified == true and
        .rollback_verified == true and .zfs_snapshot_count == 4 and
        (.zfs_snapshot_suffix | test("^v30[.]1[.]4-node27-[0-9]{8}T[0-9]{6}Z$")) and
        (.zfs_snapshot_identity_sha256 | test("^[0-9a-f]{64}$")) and
        (.zfs_snapshot_restore_proof_sha256 | test("^[0-9a-f]{64}$")) and
        .candidate_launch_marker == "CANDIDATE-LAUNCH-ATTEMPTED.json" and
        (.candidate_launch_marker_sha256 | test("^[0-9a-f]{64}$")) and
        (.maintenance | type) == "object" and .maintenance.marker == $marker and
        .maintenance.run_dir == $run and .maintenance.state == "active" and
        .maintenance.marker_released == false and .maintenance.live_marker_active == true and
        .maintenance.automatic_start_authority_restored == true and
        .maintenance.maintenance_handoff_ready == true and
        (.zfs_hold_tag | test("^blackcoin-v3014-node27-[0-9]{8}T[0-9]{6}Z$")) and
        .zfs_snapshots == [($data + "@" + .zfs_snapshot_suffix),
          ($blocks + "@" + .zfs_snapshot_suffix),
          ($indexes + "@" + .zfs_snapshot_suffix),
          ($raw + "@" + .zfs_snapshot_suffix)] and
        (.first_height | type) == "number" and (.second_height | type) == "number" and
        .second_height >= .first_height and .active_staking_samples >= 3)
    ' "$PUBLISHED_CANARY_RESULT" >/dev/null || return 1

    identity_file="$evidence_dir/zfs-snapshot-identities.tsv"
    restore_file="$evidence_dir/zfs-restore-proof.tsv"
    launch_file="$evidence_dir/CANDIDATE-LAUNCH-ATTEMPTED.json"
    prelaunch_txids_file="$evidence_dir/prelaunch-transaction-txids.json"
    locked_txids_file="$evidence_dir/candidate-preactivation-transaction-txids.json"
    baseline_pow_file="$evidence_dir/baseline-pow.json"
    restored_pow_file="$evidence_dir/restored-pow.json"
    recovery_fee_baseline_file="$evidence_dir/candidate-recovery-fee-baseline.json"
    recovery_fee_final_file="$evidence_dir/candidate-safe-2-recovery-clean.json"
    candidate_pow_first_file="$evidence_dir/candidate-pow-clean-1.json"
    candidate_pow_second_file="$evidence_dir/candidate-pow-clean-2.json"
    activation_file="$evidence_dir/maintenance-marker-activated.json"
    nonce_evidence_file="$evidence_dir/maintenance-nonce.txt"
    active_state_file="$evidence_dir/maintenance-state-active.txt"
    recovery_file="$evidence_dir/crash-recovery-procedure.json"
    guard_identities_file="$evidence_dir/maintenance-compatible-guard-identities.tsv"
    activation_one_file="$evidence_dir/candidate-activation-attempted-01.json"
    activation_two_file="$evidence_dir/candidate-activation-attempted-02.json"
    safe_one_file="$evidence_dir/candidate-safe-boundary-01.json"
    safe_two_file="$evidence_dir/candidate-safe-boundary-02.json"
    handoff_file="$evidence_dir/maintenance-handoff-ready.json"
    inventory_file="$evidence_dir/candidate-inherited-claim-inventory.json"
    transition_file="$evidence_dir/candidate-inherited-claim-transition.json"
    inherited_observed_file="$evidence_dir/candidate-inherited-recovery-observed.json"
    inherited_normalized_file="$evidence_dir/candidate-inherited-recovery-normalized.json"
    inherited_pow_file="$evidence_dir/candidate-inherited-pow-normalized.json"
    inherited_txids_file="$evidence_dir/candidate-inherited-transaction-txids-normalized.json"
    nonce_file="$ops_dir/MAINTENANCE-NONCE"
    state_file="$ops_dir/STATE"
    parent_recovery_file="$ops_dir/CRASH-RECOVERY.json"
    claim_mode=$(jq -er '.legacy_baseline_pow_mode' "$PUBLISHED_CANARY_RESULT") || return 1
    for protected in "$identity_file" "$restore_file" "$launch_file" \
        "$prelaunch_txids_file" "$locked_txids_file" "$baseline_pow_file" \
        "$restored_pow_file" "$recovery_fee_baseline_file" "$recovery_fee_final_file" \
        "$candidate_pow_first_file" "$candidate_pow_second_file" "$activation_file" \
        "$nonce_evidence_file" "$active_state_file" "$recovery_file" \
        "$guard_identities_file" "$activation_one_file" "$activation_two_file" \
        "$safe_one_file" "$safe_two_file" "$handoff_file" \
        "$transition_file" "$inherited_observed_file" "$inherited_normalized_file" \
        "$inherited_pow_file" "$inherited_txids_file" "$nonce_file" "$state_file" \
        "$parent_recovery_file" "$ROLLOUT_MAINTENANCE_MARKER"; do
        [[ -f "$protected" && ! -L "$protected" &&
           "$(realpath -e -- "$protected")" == "$protected" &&
           "$(stat -c '%u:%g:%a' "$protected")" == 0:0:600 ]] || return 1
    done
    case "$claim_mode" in
        clean-hashing)
            [[ ! -e "$inventory_file" && ! -L "$inventory_file" ]] || return 1
            boundary_inventory_file=''
            ;;
        quarantined-disabled)
            [[ -f "$inventory_file" && ! -L "$inventory_file" &&
               "$(realpath -e -- "$inventory_file")" == "$inventory_file" &&
               "$(stat -c '%u:%g:%a' "$inventory_file")" == 0:0:600 ]] || return 1
            boundary_inventory_file=$inventory_file
            ;;
        *) return 1 ;;
    esac
    for protected in "$evidence_dir/maintenance-marker-released.json" \
        "$evidence_dir/maintenance-state-complete.txt"; do
        [[ ! -e "$protected" && ! -L "$protected" ]] || return 1
    done
    [[ -z "$(find "$evidence_dir" -mindepth 1 -maxdepth 1 \
        \( -name 'maintenance-marker-released*.json' -o \
           -name 'maintenance-state-complete*.txt' \) -print -quit)" ]] || return 1
    printf '%s\n' active | cmp -s - "$active_state_file" || return 1
    printf '%s\n' active | cmp -s - "$state_file" || return 1
    cmp -s "$nonce_file" "$nonce_evidence_file" || return 1
    cmp -s "$parent_recovery_file" "$recovery_file" || return 1
    nonce=$(cat "$nonce_file") || return 1
    [[ "$nonce" =~ ^[0-9a-f]{64}$ ]] || return 1
    jq -se --arg nonce "$nonce" --arg run "$ops_dir" '
        length == 1 and .[0] == {schema:1,transaction:"v30.1.4-node27-canary",
          state:"active",run_nonce:$nonce,run_dir:$run}
    ' "$activation_file" >/dev/null || return 1
    cmp -s "$activation_file" "$ROLLOUT_MAINTENANCE_MARKER" || return 1

    identity_sha=$(sha256sum "$identity_file" | awk '{print $1}') || return 1
    restore_sha=$(sha256sum "$restore_file" | awk '{print $1}') || return 1
    launch_sha=$(sha256sum "$launch_file" | awk '{print $1}') || return 1
    prelaunch_txids_sha=$(sha256sum "$prelaunch_txids_file" | awk '{print $1}') || return 1
    locked_txids_sha=$(sha256sum "$locked_txids_file" | awk '{print $1}') || return 1
    activation_sha=$(sha256sum "$activation_file" | awk '{print $1}') || return 1
    active_state_sha=$(sha256sum "$active_state_file" | awk '{print $1}') || return 1
    recovery_sha=$(sha256sum "$recovery_file" | awk '{print $1}') || return 1
    guard_sha=$(sha256sum "$guard_identities_file" | awk '{print $1}') || return 1
    activation_one_sha=$(sha256sum "$activation_one_file" | awk '{print $1}') || return 1
    activation_two_sha=$(sha256sum "$activation_two_file" | awk '{print $1}') || return 1
    safe_one_sha=$(sha256sum "$safe_one_file" | awk '{print $1}') || return 1
    safe_two_sha=$(sha256sum "$safe_two_file" | awk '{print $1}') || return 1
    handoff_sha=$(sha256sum "$handoff_file" | awk '{print $1}') || return 1
    expected_identity_sha=$(jq -er '.zfs_snapshot_identity_sha256' \
        "$PUBLISHED_CANARY_RESULT") || return 1
    expected_restore_sha=$(jq -er '.zfs_snapshot_restore_proof_sha256' \
        "$PUBLISHED_CANARY_RESULT") || return 1
    expected_launch_sha=$(jq -er '.candidate_launch_marker_sha256' \
        "$PUBLISHED_CANARY_RESULT") || return 1
    expected_prelaunch_txids_sha=$(jq -er '.prelaunch_transaction_set_sha256' \
        "$PUBLISHED_CANARY_RESULT") || return 1
    expected_locked_txids_sha=$(jq -er '.locked_candidate_transaction_set_sha256' \
        "$PUBLISHED_CANARY_RESULT") || return 1
    [[ "$identity_sha" == "$expected_identity_sha" &&
       "$restore_sha" == "$expected_restore_sha" && "$launch_sha" == "$expected_launch_sha" &&
       "$prelaunch_txids_sha" == "$expected_prelaunch_txids_sha" &&
       "$locked_txids_sha" == "$expected_locked_txids_sha" &&
       "$prelaunch_txids_sha" == "$locked_txids_sha" ]] || return 1

    jq -se --arg marker "$ROLLOUT_MAINTENANCE_MARKER" --arg run "$ops_dir" \
        --arg nonce_sha "$(sha256sum "$nonce_file" | awk '{print $1}')" \
        --arg activation_sha "$activation_sha" --arg active_state_sha "$active_state_sha" \
        --arg recovery_sha "$recovery_sha" --arg guard_sha "$guard_sha" \
        --arg activation_one_sha "$activation_one_sha" \
        --arg activation_two_sha "$activation_two_sha" --arg safe_one_sha "$safe_one_sha" \
        --arg safe_two_sha "$safe_two_sha" --arg handoff_sha "$handoff_sha" \
        --arg runtime_guard "$compatible_runtime_sha" --arg endpoint_guard "$compatible_endpoint_sha" '
        length == 1 and (.[0].maintenance as $m |
          $m == {schema:1,transaction:"v30.1.4-node27-canary",marker:$marker,
            run_dir:$run,state:"active",run_nonce_sha256:$nonce_sha,
            marker_activation_evidence:"maintenance-marker-activated.json",
            marker_activation_sha256:$activation_sha,
            active_state_evidence:"maintenance-state-active.txt",
            active_state_evidence_sha256:$active_state_sha,
            crash_recovery_procedure:"crash-recovery-procedure.json",
            crash_recovery_procedure_sha256:$recovery_sha,
            guard_identity_evidence:"maintenance-compatible-guard-identities.tsv",
            guard_identity_evidence_sha256:$guard_sha,
            candidate_activation_markers:[
              {sequence:1,file:"candidate-activation-attempted-01.json",
                sha256:$activation_one_sha},
              {sequence:2,file:"candidate-activation-attempted-02.json",
                sha256:$activation_two_sha}],
            candidate_safe_markers:[
              {sequence:1,purpose:"pre_restart",file:"candidate-safe-boundary-01.json",
                sha256:$safe_one_sha},
              {sequence:2,purpose:"pre_rollback",file:"candidate-safe-boundary-02.json",
                sha256:$safe_two_sha}],
            handoff_ready_evidence:"maintenance-handoff-ready.json",
            handoff_ready_sha256:$handoff_sha,
            executable_recovery:false,recovery_mode:"manual-audited-only",
            wallet_runtime_guard_sha256:$runtime_guard,
            endpoint_guard_sha256:$endpoint_guard,
            activated_before_node_mutation:true,retained_on_failure:true,
            marker_released:false,live_marker_active:true,
            automatic_start_authority_restored:true,maintenance_handoff_ready:true})
    ' "$PUBLISHED_CANARY_RESULT" >/dev/null || return 1

    for protected in "$prelaunch_txids_file" "$locked_txids_file"; do
        jq -se 'length == 1 and (.[0] | type == "array" and
            all(.[]; type == "string" and test("^[0-9a-f]{64}$")) and
            . == (unique | sort))' "$protected" >/dev/null || return 1
        cmp -s "$protected" <(jq -S . "$protected") || return 1
    done
    cmp -s "$prelaunch_txids_file" "$locked_txids_file" || return 1
    published_canary_pow_transition_is_valid "$PUBLISHED_CANARY_RESULT" \
        "$baseline_pow_file" "$restored_pow_file" "$recovery_fee_baseline_file" \
        "$recovery_fee_final_file" "$candidate_pow_first_file" "$candidate_pow_second_file" ||
        return 1
    published_canary_claim_transition_is_valid "$PUBLISHED_CANARY_RESULT" \
        "$baseline_pow_file" "$restored_pow_file" "$inventory_file" "$transition_file" \
        "$inherited_observed_file" "$inherited_normalized_file" "$inherited_pow_file" \
        "$inherited_txids_file" "$prelaunch_txids_file" || return 1

    nonce_sha=$(sha256sum "$nonce_file" | awk '{print $1}') || return 1
    transition_sha=$(sha256sum "$transition_file" | awk '{print $1}') || return 1
    fee=$(jq -er '.claim_recovery_fee_baseline |
        select(type == "number" and . >= 0)' "$PUBLISHED_CANARY_RESULT") || return 1
    for sequence in 1 2; do
        if [[ "$sequence" == 1 ]]; then
            purpose=first-unlock
            boundary_marker=$activation_one_file
        else
            purpose=second-start-and-unlock
            boundary_marker=$activation_two_file
        fi
        boundary_wallet="$evidence_dir/candidate-activation-${sequence}-wallet-locked.json"
        boundary_staking="$evidence_dir/candidate-activation-${sequence}-staking-disabled.json"
        boundary_pow="$evidence_dir/candidate-activation-${sequence}-pow-disabled.json"
        boundary_recovery="$evidence_dir/candidate-activation-${sequence}-recovery-clean.json"
        boundary_txids="$evidence_dir/candidate-activation-${sequence}-transaction-txids.json"
        published_canary_activation_boundary_is_valid "$sequence" "$purpose" \
            "$boundary_marker" "$boundary_wallet" "$boundary_staking" "$boundary_pow" \
            "$boundary_recovery" "$boundary_txids" "$prelaunch_txids_file" \
            "$boundary_inventory_file" "$claim_mode" "$CANDIDATE_IMAGE_REF" \
            "$CANDIDATE_IMAGE_ID" \
            "$launch_sha" "$nonce_sha" "$transition_sha" "$fee" || return 1
    done
    for sequence in 1 2; do
        if [[ "$sequence" == 1 ]]; then
            purpose=pre_restart
            boundary_marker=$safe_one_file
            boundary_activation_sha=$activation_one_sha
        else
            purpose=pre_rollback
            boundary_marker=$safe_two_file
            boundary_activation_sha=$activation_two_sha
        fi
        first_wallet="$evidence_dir/candidate-safe-${sequence}-wallet-1.json"
        first_staking="$evidence_dir/candidate-safe-${sequence}-staking-1.json"
        first_pow="$evidence_dir/candidate-safe-${sequence}-pow-1.json"
        first_recovery="$evidence_dir/candidate-safe-${sequence}-recovery-1.json"
        first_txids="$evidence_dir/candidate-safe-${sequence}-transaction-txids-1.json"
        boundary_wallet="$evidence_dir/candidate-safe-${sequence}-wallet-2.json"
        boundary_staking="$evidence_dir/candidate-safe-${sequence}-staking-2.json"
        boundary_pow="$evidence_dir/candidate-safe-${sequence}-pow-2.json"
        boundary_recovery="$evidence_dir/candidate-safe-${sequence}-recovery-2.json"
        boundary_txids="$evidence_dir/candidate-safe-${sequence}-transaction-txids-2.json"
        published_canary_candidate_disabled_boundary_is_valid "$first_wallet" \
            "$first_staking" "$first_pow" "$first_recovery" "$first_txids" \
            "$prelaunch_txids_file" "$boundary_inventory_file" "$claim_mode" "$fee" ||
            return 1
        first_generation=$(jq -er '.wallet_generation |
            select(type == "number" and floor == . and . >= 0)' "$first_recovery") || return 1
        second_generation=$(jq -er '.wallet_generation |
            select(type == "number" and floor == . and . >= 0)' "$boundary_recovery") ||
            return 1
        [[ "$first_generation" == "$second_generation" ]] || return 1
        cmp -s "$first_txids" "$boundary_txids" || return 1
        published_canary_safe_boundary_is_valid "$sequence" "$purpose" "$boundary_marker" \
            "$boundary_activation_sha" "$boundary_wallet" "$boundary_staking" \
            "$boundary_pow" "$boundary_recovery" "$boundary_txids" \
            "$prelaunch_txids_file" "$boundary_inventory_file" "$claim_mode" \
            "$CANDIDATE_IMAGE_REF" "$CANDIDATE_IMAGE_ID" "$fee" || return 1
    done

    [[ "$(wc -l < "$identity_file" | awk '{print $1}')" == 4 &&
       "$(awk -F '\t' 'NF == 4 {count++} END {print count+0}' "$identity_file")" == 4 &&
       "$(wc -l < "$restore_file" | awk '{print $1}')" == 4 &&
       "$(awk -F '\t' 'NF == 5 && $5 == "zero-diff" {count++} END {print count+0}' "$restore_file")" == 4 ]] ||
        return 1
    identity_set_sha=$(awk -F '\t' 'NF == 4 {print $1}' "$identity_file" | sort | sha256sum |
        awk '{print $1}') || return 1
    restore_set_sha=$(awk -F '\t' 'NF == 5 && $5 == "zero-diff" {print $1}' "$restore_file" |
        sort | sha256sum | awk '{print $1}') || return 1
    result_snapshot_set_sha=$(jq -r '.zfs_snapshots[]' "$PUBLISHED_CANARY_RESULT" | sort |
        sha256sum | awk '{print $1}') || return 1
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
    cmp -s "$guard_identities_file" <(printf '%s\n%s\t%s\t%s\n%s\t%s\t%s\n' \
        $'path\tsha256\tuid:gid:mode' \
        "$WALLET_RUNTIME_GUARD" "$compatible_runtime_sha" '0:0:600' \
        "$ENDPOINT_GUARD" "$compatible_endpoint_sha" '0:0:600') || return 1

    handoff_timestamp=$(jq -er '.timestamp | select(type == "string" and
        test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))' \
        "$handoff_file") || return 1
    jq -se --arg marker "$ROLLOUT_MAINTENANCE_MARKER" --arg run "$ops_dir" \
        --arg nonce_sha "$(sha256sum "$nonce_file" | awk '{print $1}')" \
        --arg activation_sha "$activation_sha" --arg recovery_sha "$recovery_sha" \
        --arg active_state_sha "$active_state_sha" --arg guard_sha "$guard_sha" \
        --arg activation_one_sha "$activation_one_sha" \
        --arg activation_two_sha "$activation_two_sha" --arg safe_one_sha "$safe_one_sha" \
        --arg safe_two_sha "$safe_two_sha" --arg timestamp "$handoff_timestamp" '
        length == 1 and .[0] == {
          schema:1,transaction:"v30.1.4-node27-canary",state:"active",
          marker:$marker,run_dir:$run,run_nonce_sha256:$nonce_sha,
          marker_activation_sha256:$activation_sha,
          crash_recovery_procedure_sha256:$recovery_sha,
          active_state_evidence_sha256:$active_state_sha,
          guard_identity_evidence_sha256:$guard_sha,
          candidate_activation_markers:[
            {sequence:1,file:"candidate-activation-attempted-01.json",
              sha256:$activation_one_sha},
            {sequence:2,file:"candidate-activation-attempted-02.json",
              sha256:$activation_two_sha}],
          candidate_safe_markers:[
            {sequence:1,purpose:"pre_restart",file:"candidate-safe-boundary-01.json",
              sha256:$safe_one_sha},
            {sequence:2,purpose:"pre_rollback",file:"candidate-safe-boundary-02.json",
              sha256:$safe_two_sha}],
          pre_upgrade_data_restored:true,old_container_runtime_verified:true,
          snapshot_holds_released:true,automatic_start_authority_restored:true,
          marker_released:false,live_marker_active:true,maintenance_handoff_ready:true,
          required_next_action:"atomic_authenticated_fleet_marker_takeover",timestamp:$timestamp}
    ' "$handoff_file" >/dev/null || return 1
    [[ "${EXPECTED_WALLET_RUNTIME_GUARD_SHA256:-$compatible_runtime_sha}" == "$compatible_runtime_sha" &&
       "${EXPECTED_ENDPOINT_GUARD_SHA256:-$compatible_endpoint_sha}" == "$compatible_endpoint_sha" ]] ||
        return 1

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
    wallet_info=$(timeout --foreground --kill-after=2 45 docker exec "$(container_for "$node")" \
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

legacy_pow_role_for_node()
{
    local node="$1"
    valid_node "$node" || return 1
    if [[ "$node" -eq "$FREE_CLAIM_NODE" ]]; then
        printf '%s\n' free-claim
    else
        printf '%s\n' regular-pow
    fi
}

_transient_or_regular_json_input()
{
    local input="$1"
    [[ -r "$input" ]] || return 1
    if [[ "$input" =~ ^/dev/fd/[0-9]+$ ]]; then
        return 0
    fi
    [[ -f "$input" && ! -L "$input" ]]
}

_legacy_pow_projection_json_is_valid()
{
    local node="$1" mode="$2" mining="$3" phase="$4"
    valid_node "$node" || return 1
    [[ "$phase" == pre-drain || "$phase" == drained || "$phase" == restored ]] ||
        return 1
    jq -e -n --argjson node "$node" --arg mode "$mode" --arg phase "$phase" \
        --argjson mining "$mining" '
        def integer:
          type == "number" and floor == .;
        def common:
          type == "object" and
          (.enabled | type == "boolean") and
          .autostart == false and
          (.state | type == "string") and
          (.threads | integer and . == 1) and
          (.cpu_percent | type == "number" and . == 1) and
          (.hashrate | type == "number" and . >= 0) and
          (.unresolved_claims | integer and . >= 0) and
          (.live_claims | integer and . >= 0) and
          (.quarantined_claims | integer and . >= 0) and
          .allow_automatic_quantum_key_creation == false;
        def regular_clean_running:
          common and .enabled == true and
          (.state == "ready" or .state == "hashing") and
          .hashrate > 0 and
          .live_claims == 0 and .quarantined_claims == 0;
        def regular_clean_drained:
          common and .enabled == false and .state == "disabled" and
          .hashrate == 0 and
          .live_claims == 0 and .quarantined_claims == 0;
        def regular_quarantined_predrain:
          common and .hashrate == 0 and
          ((.enabled == true and .state == "claim_quarantined") or
            (.enabled == false and .state == "disabled")) and
          .unresolved_claims == 1 and
          .live_claims == 0 and .quarantined_claims == 1;
        def regular_quarantined_disabled:
          common and .enabled == false and .state == "disabled" and .hashrate == 0 and
          .unresolved_claims == 1 and
          .live_claims == 0 and .quarantined_claims == 1;
        def free_claim_disabled:
          common and .enabled == false and .state == "disabled" and
          .hashrate == 0 and .live_claims == 0 and
          (.quarantined_claims == 0 or .quarantined_claims == 1) and
          .unresolved_claims >= .quarantined_claims;
        $mining |
        if $node == 30 then
          $mode == "free-claim-disabled" and free_claim_disabled
        elif $mode == "clean-hashing" then
          if $phase == "drained" then regular_clean_drained
          else regular_clean_running end
        elif $mode == "quarantined-disabled" then
          if $phase == "pre-drain" then regular_quarantined_predrain
          else regular_quarantined_disabled end
        else false end
    ' >/dev/null
}

legacy_pow_projection_is_valid()
{
    local node="$1" mode="$2" mining_file="$3" phase="$4" mining
    _transient_or_regular_json_input "$mining_file" || return 1
    mining=$(jq -ceS 'select(type == "object")' "$mining_file") || return 1
    _legacy_pow_projection_json_is_valid "$node" "$mode" "$mining" "$phase"
}

_legacy_pow_snapshot_mode_json()
{
    local node="$1" mining="$2"
    if [[ "$node" -eq "$FREE_CLAIM_NODE" ]] &&
       _legacy_pow_projection_json_is_valid \
           "$node" free-claim-disabled "$mining" pre-drain; then
        printf '%s\n' free-claim-disabled
    elif [[ "$node" -ne "$FREE_CLAIM_NODE" ]] &&
         _legacy_pow_projection_json_is_valid "$node" clean-hashing "$mining" pre-drain; then
        printf '%s\n' clean-hashing
    elif [[ "$node" -ne "$FREE_CLAIM_NODE" ]] &&
         _legacy_pow_projection_json_is_valid \
             "$node" quarantined-disabled "$mining" pre-drain; then
        printf '%s\n' quarantined-disabled
    else
        return 1
    fi
}

legacy_pow_snapshot_mode()
{
    local node="$1" mining_file="$2" mining
    valid_node "$node" || return 1
    [[ -f "$mining_file" && ! -L "$mining_file" ]] || return 1
    mining=$(jq -ceS 'select(type == "object")' "$mining_file") || return 1
    _legacy_pow_snapshot_mode_json "$node" "$mining"
}

_legacy_pow_plan_entry_json_is_valid()
{
    local node="$1" entry="$2" role mode baseline
    valid_node "$node" || return 1
    role=$(legacy_pow_role_for_node "$node") || return 1
    jq -e -n --argjson node "$node" --arg role "$role" --argjson entry "$entry" '
        ($entry | type) == "object" and
        ($entry.node | type) == "number" and ($entry.node | floor) == $entry.node and
        $entry.node == $node and $entry.role == $role and
        ($entry.mode | type) == "string" and ($entry.baseline | type) == "object"
    ' >/dev/null || return 1
    mode=$(jq -er '.mode' <<< "$entry") || return 1
    baseline=$(jq -ceS '.baseline' <<< "$entry") || return 1
    _legacy_pow_projection_json_is_valid "$node" "$mode" "$baseline" pre-drain
}

_legacy_pow_plan_entry_from_document()
{
    local node="$1" document="$2" entry
    entry=$(jq -ceS --argjson node "$node" '
        if type != "object" then empty
        elif (.baseline | type) == "object" then .
        elif (.nodes | type) == "array" then
          [.nodes[] | select((.node | type) == "number" and .node == $node)] |
          select(length == 1) | .[0]
        elif (.nodes | type) == "object" then
          [.nodes[] | select((.node | type) == "number" and .node == $node)] |
          select(length == 1) | .[0]
        else empty end
    ' <<< "$document") || return 1
    _legacy_pow_plan_entry_json_is_valid "$node" "$entry" || return 1
    printf '%s\n' "$entry"
}

legacy_pow_plan_entry_for_node()
{
    local node="$1" plan_file="$2" document
    valid_node "$node" || return 1
    [[ -f "$plan_file" && ! -L "$plan_file" ]] || return 1
    document=$(jq -ceS 'select(type == "object")' "$plan_file") || return 1
    _legacy_pow_plan_entry_from_document "$node" "$document"
}

legacy_pow_plan_entry_is_valid()
{
    legacy_pow_plan_entry_for_node "$1" "$2" >/dev/null
}

legacy_pow_baseline_snapshot()
{
    local node="$1" baseline_or_plan="$2" document entry
    valid_node "$node" || return 1
    [[ -f "$baseline_or_plan" && ! -L "$baseline_or_plan" ]] || return 1
    document=$(jq -ceS 'select(type == "object")' "$baseline_or_plan") || return 1
    if _legacy_pow_snapshot_mode_json "$node" "$document" >/dev/null; then
        printf '%s\n' "$document"
        return 0
    fi
    entry=$(_legacy_pow_plan_entry_from_document "$node" "$document") || return 1
    jq -ceS '.baseline' <<< "$entry"
}

legacy_pow_baseline_mode()
{
    local node="$1" baseline_or_plan="$2" document entry
    valid_node "$node" || return 1
    [[ -f "$baseline_or_plan" && ! -L "$baseline_or_plan" ]] || return 1
    document=$(jq -ceS 'select(type == "object")' "$baseline_or_plan") || return 1
    if _legacy_pow_snapshot_mode_json "$node" "$document"; then
        return 0
    fi
    entry=$(_legacy_pow_plan_entry_from_document "$node" "$document") || return 1
    jq -er '.mode' <<< "$entry"
}

_legacy_pow_state_json_is_exact()
{
    local node="$1" mode="$2" baseline="$3" current="$4" phase="$5"
    [[ "$phase" == drained || "$phase" == restored ]] || return 1
    _legacy_pow_projection_json_is_valid "$node" "$mode" "$baseline" pre-drain || return 1
    _legacy_pow_projection_json_is_valid "$node" "$mode" "$current" "$phase" || return 1
    jq -e -n --argjson baseline "$baseline" --argjson current "$current" '
        $current.autostart == $baseline.autostart and
        $current.threads == $baseline.threads and
        $current.cpu_percent == $baseline.cpu_percent and
        $current.unresolved_claims == $baseline.unresolved_claims and
        $current.live_claims == $baseline.live_claims and
        $current.quarantined_claims == $baseline.quarantined_claims and
        $current.allow_automatic_quantum_key_creation ==
          $baseline.allow_automatic_quantum_key_creation
    ' >/dev/null
}

_legacy_pow_rollback_json_is_exact()
{
    _legacy_pow_state_json_is_exact "$1" "$2" "$3" "$4" restored
}

verify_legacy_pow_drain_exact()
{
    local node="$1" baseline_or_plan="$2" current_file="$3"
    local mode baseline current
    mode=$(legacy_pow_baseline_mode "$node" "$baseline_or_plan") || return 1
    baseline=$(legacy_pow_baseline_snapshot "$node" "$baseline_or_plan") || return 1
    [[ -f "$current_file" && ! -L "$current_file" ]] || return 1
    current=$(jq -ceS 'select(type == "object")' "$current_file") || return 1
    _legacy_pow_state_json_is_exact "$node" "$mode" "$baseline" "$current" drained
}

verify_legacy_pow_rollback_exact()
{
    local node="$1" baseline_or_plan="$2" current_file="$3"
    local mode baseline current
    mode=$(legacy_pow_baseline_mode "$node" "$baseline_or_plan") || return 1
    baseline=$(legacy_pow_baseline_snapshot "$node" "$baseline_or_plan") || return 1
    [[ -f "$current_file" && ! -L "$current_file" ]] || return 1
    current=$(jq -ceS 'select(type == "object")' "$current_file") || return 1
    _legacy_pow_rollback_json_is_exact "$node" "$mode" "$baseline" "$current"
}

verify_legacy_pow_role()
{
    local node="$1" baseline_or_plan="${2:-}" mining mode baseline
    valid_node "$node" || return 1
    mining=$(wallet_rpc_for "$node" getpowmininginfo) || return 1
    mining=$(jq -ceS 'select(type == "object")' <<< "$mining") || return 1
    if [[ -n "$baseline_or_plan" ]]; then
        mode=$(legacy_pow_baseline_mode "$node" "$baseline_or_plan") || return 1
        baseline=$(legacy_pow_baseline_snapshot "$node" "$baseline_or_plan") || return 1
        if legacy_pow_plan_entry_is_valid "$node" "$baseline_or_plan"; then
            _legacy_pow_rollback_json_is_exact "$node" "$mode" "$baseline" "$mining"
        else
            _legacy_pow_projection_json_is_valid "$node" "$mode" "$mining" pre-drain || return 1
            jq -e -n --argjson baseline "$baseline" --argjson current "$mining" '
                $current.enabled == $baseline.enabled and
                $current.autostart == $baseline.autostart and
                $current.state == $baseline.state and
                $current.threads == $baseline.threads and
                $current.cpu_percent == $baseline.cpu_percent and
                $current.unresolved_claims == $baseline.unresolved_claims and
                $current.live_claims == $baseline.live_claims and
                $current.quarantined_claims == $baseline.quarantined_claims and
                $current.allow_automatic_quantum_key_creation ==
                  $baseline.allow_automatic_quantum_key_creation
            ' >/dev/null
        fi
    else
        _legacy_pow_snapshot_mode_json "$node" "$mining" >/dev/null
    fi
}

_candidate_pow_json_is_valid()
{
    local mining="$1" phase="$2"
    [[ "$phase" == locked || "$phase" == drained || "$phase" == hashing ||
       "$phase" == node30-off ]] || return 1
    jq -e -n --arg phase "$phase" --argjson mining "$mining" '
        def integer:
          type == "number" and floor == .;
        def common:
          type == "object" and .autostart == false and
          (.threads | integer and . == 1) and
          (.cpu_percent | type == "number" and . == 1) and
          (.hashrate | type == "number" and . >= 0) and
          (.unresolved_claims | integer and . >= 0) and
          (.live_claims | integer and . >= 0) and
          (.quarantined_claims | integer and . >= 0) and
          (.blocking_quarantined_claims | integer and . >= 0) and
          (.raw_quarantined_claims | integer and . >= 0) and
          .claim_recovery_database_outcome_ambiguous == false and
          .allow_automatic_quantum_key_creation == false;
        def off:
          common and .enabled == false and .state == "disabled" and
          .hashrate == 0 and .live_claims == 0 and
          .quarantined_claims == 0 and .blocking_quarantined_claims == 0;
        def clean_hashing:
          common and .enabled == true and
          (.state == "ready" or .state == "hashing") and
          .hashrate > 0 and .live_claims == 0 and
          .quarantined_claims == 0 and .blocking_quarantined_claims == 0 and
          .stake_reserve_snapshot_available == true and
          (.reserved_stake_coins | integer and . >= 1) and
          (.last_stake_coin_guard | type) == "boolean";
        $mining | if $phase == "hashing" then clean_hashing else off end
    ' >/dev/null
}

_candidate_pow_file_is_valid()
{
    local mining_file="$1" phase="$2" mining
    _transient_or_regular_json_input "$mining_file" || return 1
    mining=$(jq -ceS 'select(type == "object")' "$mining_file") || return 1
    _candidate_pow_json_is_valid "$mining" "$phase"
}

candidate_locked_pow_is_clean()
{
    _candidate_pow_file_is_valid "$1" locked
}

candidate_preactivation_pow_is_clean()
{
    candidate_locked_pow_is_clean "$1"
}

candidate_drained_pow_is_clean()
{
    _candidate_pow_file_is_valid "$1" drained
}

candidate_hashing_pow_is_clean()
{
    _candidate_pow_file_is_valid "$1" hashing
}

candidate_node30_pow_is_off()
{
    _candidate_pow_file_is_valid "$1" node30-off
}

candidate_safe_rollback_state_is_clean()
{
    local wallet_file="$1" staking_file="$2" mining_file="$3" recovery_file="$4"
    local fee="$5" state_file
    [[ "$fee" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
    for state_file in "$wallet_file" "$staking_file" "$mining_file" "$recovery_file"; do
        [[ -f "$state_file" && ! -L "$state_file" ]] || return 1
        jq -e 'type == "object"' "$state_file" >/dev/null || return 1
    done
    candidate_drained_pow_is_clean "$mining_file" || return 1
    jq -e -n --argjson fee "$fee" --slurpfile wallet "$wallet_file" \
        --slurpfile staking "$staking_file" --slurpfile recovery "$recovery_file" '
        ($wallet | length) == 1 and ($staking | length) == 1 and
        ($recovery | length) == 1 and
        ($wallet[0] | type) == "object" and
        $wallet[0].private_keys_enabled == true and
        ($wallet[0].unlocked_until | type) == "number" and
        ($wallet[0].unlocked_until | floor) == $wallet[0].unlocked_until and
        $wallet[0].unlocked_until == 0 and
        $wallet[0].unlocked_staking_only == false and
        ($staking[0] | type) == "object" and
        $staking[0].enabled == false and $staking[0].staking == false and
        $staking[0].worker_running == false and
        $staking[0].automatic_qqsignal == false and
        $staking[0].automatic_demurrage_attestation == false and
        $staking[0].automatic_redelegation == false and
        $staking[0].allow_automatic_quantum_key_creation == false and
        ($recovery[0] | type) == "object" and
        $recovery[0].policy_authoritative == true and
        $recovery[0].policy.automatic_authorized == false and
        $recovery[0].database_outcome_ambiguous == false and
        $recovery[0].chain_ready == true and $recovery[0].wallet_tip_matches == true and
        $recovery[0].blocking_quarantined_claims == 0 and
        $recovery[0].blocking_components == 0 and
        $recovery[0].indeterminate_quarantined_claims == 0 and
        $recovery[0].pending_manual_resolutions == 0 and
        $recovery[0].pending_automatic_resolutions == 0 and
        ($recovery[0].confirmed_resolution_fees | type) == "number" and
        $recovery[0].confirmed_resolution_fees == $fee
    ' >/dev/null
}

verify_claim_recovery_clean()
{
    local node="$1" old_fee="${2:-}" recovery current_fee
    jq -en --argjson fee "$old_fee" '$fee | type == "number" and . >= 0' >/dev/null || return 1
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
    jq -en --argjson current "$current_fee" --argjson expected "$old_fee" \
        '$current == $expected' >/dev/null
}

verify_standard_pow()
{
    local node="$1" old_fee="${2:-}" mining
    [[ "$node" -ne "$FREE_CLAIM_NODE" ]] || return 1
    mining=$(wallet_rpc_for "$node" getpowmininginfo) || return 1
    mining=$(jq -ceS 'select(type == "object")' <<< "$mining") || return 1
    _candidate_pow_json_is_valid "$mining" hashing || return 1
    verify_claim_recovery_clean "$node" "$old_fee"
}

verify_node30_core_role()
{
    local mining recovery old_fee="${1:-}" current_fee
    jq -en --argjson fee "$old_fee" '$fee | type == "number" and . >= 0' >/dev/null || return 1
    mining=$(wallet_rpc_for "$FREE_CLAIM_NODE" getpowmininginfo) || return 1
    mining=$(jq -ceS 'select(type == "object")' <<< "$mining") || return 1
    _candidate_pow_json_is_valid "$mining" node30-off || return 1
    recovery=$(wallet_rpc_for "$FREE_CLAIM_NODE" getpowclaimrecoveryinfo) || return 1
    jq -e '.policy_authoritative == true and .policy.automatic_authorized == false and
        .database_outcome_ambiguous == false and .chain_ready == true and
        .wallet_tip_matches == true and .blocking_quarantined_claims == 0 and
        .blocking_components == 0 and .indeterminate_quarantined_claims == 0 and
        .pending_manual_resolutions == 0 and .pending_automatic_resolutions == 0' \
        >/dev/null <<< "$recovery" || return 1
    current_fee=$(jq -er '.confirmed_resolution_fees' <<< "$recovery") || return 1
    jq -en --argjson current "$current_fee" --argjson expected "$old_fee" \
        '$current == $expected' >/dev/null || return 1
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
    logs=$(timeout --foreground --kill-after=2 45 docker logs --since "$started" "$container" 2>&1) || return 1
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
