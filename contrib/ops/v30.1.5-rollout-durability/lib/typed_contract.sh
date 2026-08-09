# shellcheck shell=bash
# Pure v30.1.5 identity, PoS, PoW, and restart-evidence predicates.

export LC_ALL=C

readonly V3015_ZERO_TXID='0000000000000000000000000000000000000000000000000000000000000000'

v3015_release_identity_is_valid()
{
    local file=$1
    jq -e --arg source "$SOURCE_SHA" --arg tree "$SOURCE_TREE" \
        --argjson run "$CORE_CI_RUN_ID" --arg workflow "$CORE_CI_WORKFLOW" \
        --arg artifact "$CANDIDATE_ARTIFACT_NAME" \
        --argjson artifact_run "$CANDIDATE_ARTIFACT_RUN_ID" \
        --argjson artifact_attempt "$CANDIDATE_ARTIFACT_RUN_ATTEMPT" \
        --arg image "$CANDIDATE_IMAGE_REF" \
        --arg image_id "$CANDIDATE_IMAGE_ID" --arg bundle "$CANDIDATE_BUNDLE_SHA256" \
        --arg oci_archive "$CANDIDATE_OCI_ARCHIVE_SHA256" \
        --arg oci_manifest "$CANDIDATE_OCI_MANIFEST_SHA256" \
        --arg tooling "$CANDIDATE_TOOLING_SHA256" \
        --arg manifest "$CANDIDATE_MANIFEST_SHA256" \
        --arg provenance "$CANDIDATE_PROVENANCE_SHA256" \
        --arg blackcoind "$CANDIDATE_BLACKCOIND_SHA256" \
        --arg cli "$CANDIDATE_BLACKCOIN_CLI_SHA256" \
        --arg qt "$CANDIDATE_BLACKCOIN_QT_SHA256" \
        --arg tx "$CANDIDATE_BLACKCOIN_TX_SHA256" \
        --arg wallet "$CANDIDATE_BLACKCOIN_WALLET_SHA256" \
        --arg util "$CANDIDATE_BLACKCOIN_UTIL_SHA256" \
        --arg node30_probe_tool "$NODE30_FREE_CLAIM_PROBE_SHA256" \
        --arg phase_b "$PHASE_B_RESULT_SHA256" --arg marker "$PHASE_B_PROMOTION_MARKER_SHA256" \
        --arg canary "$NINE_PATH_CANARY_SEAL_SHA256" '
        type == "object" and .schema == 1 and .release == "v30.1.5" and
        .source_sha == $source and .source_tree == $tree and
        .source_signature_verified == true and
        .source_signing_fingerprint == "SHA256:jAkpBudDw+ntWHSUx3e1KY+czAFjnlaPxQtRFtptL70" and
        .core_ci == {run_id:$run,head_sha:$source,conclusion:"success",workflow:$workflow} and
        .artifact == {name:$artifact,run_id:$artifact_run,run_attempt:$artifact_attempt} and
        .network_version == 300105 and .subversion == "/Blackcoin:30.1.5/" and
        .candidate_image_ref == $image and
        (.candidate_image_ref | test("^qqblackcoin/blackcoin-v4-gui@sha256:[0-9a-f]{64}$")) and
        .candidate_image_id == $image_id and
        .candidate_bundle_sha256 == $bundle and
        .candidate_oci_archive_sha256 == $oci_archive and
        .candidate_oci_manifest_sha256 == $oci_manifest and
        .candidate_tooling_sha256 == $tooling and
        .candidate_manifest_sha256 == $manifest and
        .candidate_provenance_sha256 == $provenance and
        .binary_sha256s == {blackcoind:$blackcoind,"blackcoin-cli":$cli,
          "blackcoin-qt":$qt,"blackcoin-tx":$tx,"blackcoin-wallet":$wallet,
          "blackcoin-util":$util} and
        .node30_probe_tool_sha256 == $node30_probe_tool and
        .phase_b_result_sha256 == $phase_b and
        .phase_b_promotion_marker_sha256 == $marker and
        .nine_path_canary_seal_sha256 == $canary and
        .phase_b_status == "PASS" and .phase_b_no_rewind == true
    ' "$file" >/dev/null
}

v3015_phase_b_evidence_is_valid()
{
    local result=$1 marker=$2 marker_sha manifest_digest
    [[ -f "$result" && ! -L "$result" && -f "$marker" && ! -L "$marker" ]] || return 1
    marker_sha=$(v3015_sha256_file "$marker") || return 1
    manifest_digest=${CANDIDATE_IMAGE_REF##*@}
    jq -e --arg source "$SOURCE_SHA" --arg image "$CANDIDATE_IMAGE_REF" \
      --arg image_id "$CANDIDATE_IMAGE_ID" --arg manifest "$manifest_digest" \
      --arg phase_a "$PHASE_A_RESULT_SHA256" --arg package "$NINE_PATH_CANARY_SEAL_SHA256" \
      --arg tooling_commit "$NINE_PATH_TOOLING_COMMIT" \
      --arg tooling "$NINE_PATH_PHASE_B_TOOLING_IDENTITY_SHA256" \
      --arg script "$NINE_PATH_PHASE_B_SCRIPT_SHA256" \
      --arg verifier "$NINE_PATH_VERIFIER_SHA256" \
      --arg contract "$NINE_PATH_TYPED_CONTRACT_SHA256" '
        def hex64: type == "string" and test("^[0-9a-f]{64}$");
        def expected_keys: ["candidate_image_id","candidate_image_ref",
          "candidate_manifest_digest","candidate_source_sha","created_utc",
          "data_rewind_permanently_prohibited","marker_fsync_verified","node",
          "package_sha256sums_sha256","parent_directory_fsync_verified",
          "phase_a_authority_receipt_sha256","phase_a_evidence_sha256sums_sha256",
          "phase_a_result_sha256","phase_a_rewind_safe_sha256","phase_a_run_nonce",
          "phase_b_script_sha256","phase_b_tooling_identity_sha256","promotion_nonce",
          "reread_verified","schema","snapshots_absent_before_marker","state",
          "storage_absence_sha256","tooling_commit","typed_contract_sha256",
          "verifier_sha256"];
        type == "object" and (keys | sort) == (expected_keys | sort) and
        .schema == 1 and .state == "PROMOTED_NO_REWIND" and
        .node == 27 and .candidate_source_sha == $source and
        .candidate_image_ref == $image and
        (.candidate_image_ref | test("^qqblackcoin/blackcoin-v4-gui@sha256:[0-9a-f]{64}$")) and
        .candidate_image_id == $image_id and
        .candidate_manifest_digest == $manifest and
        .phase_a_result_sha256 == $phase_a and
        .package_sha256sums_sha256 == $package and
        .tooling_commit == $tooling_commit and
        .phase_b_tooling_identity_sha256 == $tooling and
        .phase_b_script_sha256 == $script and .verifier_sha256 == $verifier and
        .typed_contract_sha256 == $contract and
        (.phase_a_authority_receipt_sha256 | hex64) and
        (.phase_a_evidence_sha256sums_sha256 | hex64) and
        (.phase_a_rewind_safe_sha256 | hex64) and (.storage_absence_sha256 | hex64) and
        .data_rewind_permanently_prohibited == true and
        .snapshots_absent_before_marker == true and
        .marker_fsync_verified == true and .parent_directory_fsync_verified == true and
        .reread_verified == true and
        (.promotion_nonce | type == "string" and test("^[0-9a-f]{32}$")) and
        (.phase_a_run_nonce | type == "string" and test("^[0-9a-f]{32}$")) and
        .promotion_nonce != .phase_a_run_nonce and
        (.created_utc | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))
    ' "$marker" >/dev/null || return 1
    jq -e --arg source "$SOURCE_SHA" --arg marker "$marker_sha" \
      --arg phase_a "$PHASE_A_RESULT_SHA256" --arg package "$NINE_PATH_CANARY_SEAL_SHA256" \
      --arg tooling_commit "$NINE_PATH_TOOLING_COMMIT" \
      --arg tooling "$NINE_PATH_PHASE_B_TOOLING_IDENTITY_SHA256" \
      --arg script "$NINE_PATH_PHASE_B_SCRIPT_SHA256" \
      --arg verifier "$NINE_PATH_VERIFIER_SHA256" \
      --arg contract "$NINE_PATH_TYPED_CONTRACT_SHA256" '
        def hex64: type == "string" and test("^[0-9a-f]{64}$");
        def amount: type == "number" and . >= 0;
        def expected_keys: ["baseline_automatic_fee_exposure_in_window",
          "baseline_confirmed_resolution_fees","baseline_health_gate_passed",
          "baseline_pending_automatic_resolutions","baseline_pending_manual_resolutions",
          "baseline_precondition_sha256","baseline_cutover_stop_sha256",
          "baseline_recovery_metrics_sha256","baseline_recovery_policy_sha256",
          "candidate_running","candidate_source_sha","data_rewind_performed",
          "datasets_preserved","failure_policy","final_container_identity_stable",
          "final_container_sha256","final_envelope_sha256","invocation_sha256",
          "live_dataset_identity_sha256","marker_sha256","node","normal_unlock_completed",
          "old_core_autostarted","only_allowed_wallet_delta_classes_added","p2p_ready",
          "package_sha256sums_sha256","phase","phase_a_result_sha256",
          "phase_b_progress_sha256","phase_b_script_sha256",
          "phase_b_tooling_identity_sha256","pos_active","pos_explicitly_enabled",
          "pow_policy_restored","pre_result_manifest_sha256","promoted_no_rewind_marker_verified",
          "quantum_keys_unchanged","recovery_counters_unchanged","recovery_fees_unchanged",
          "recovery_policy_unchanged","resolution_txids_unchanged","result","schema",
          "snapshots_absent_before_launch","storage_absence_recheck_sha256",
          "tooling_commit","typed_contract_sha256","typed_gate_safe","verifier_sha256",
          "wallet_chain_synchronized_before_unlock","wallet_delta_fully_classified",
          "wallet_delta_raw_sha256","wallet_delta_sha256","payout_unchanged"];
        type == "object" and (keys | sort) == (expected_keys | sort) and
        .schema == 2 and .phase == "B" and .node == 27 and
        .result == "passed" and .candidate_source_sha == $source and
        .promoted_no_rewind_marker_verified == true and .marker_sha256 == $marker and
        .phase_a_result_sha256 == $phase_a and .package_sha256sums_sha256 == $package and
        .tooling_commit == $tooling_commit and
        .phase_b_tooling_identity_sha256 == $tooling and
        .phase_b_script_sha256 == $script and .verifier_sha256 == $verifier and
        .typed_contract_sha256 == $contract and
        all([.baseline_precondition_sha256,.baseline_cutover_stop_sha256,
          .baseline_recovery_metrics_sha256,.baseline_recovery_policy_sha256,
          .final_container_sha256,.final_envelope_sha256,.invocation_sha256,
          .live_dataset_identity_sha256,.phase_b_progress_sha256,.pre_result_manifest_sha256,
          .storage_absence_recheck_sha256,.wallet_delta_raw_sha256,
          .wallet_delta_sha256][]; hex64) and
        .baseline_health_gate_passed == true and
        .baseline_pending_automatic_resolutions == 0 and
        .baseline_pending_manual_resolutions == 0 and
        (.baseline_automatic_fee_exposure_in_window | amount) and
        .baseline_automatic_fee_exposure_in_window == 0 and
        (.baseline_confirmed_resolution_fees | amount) and
        .snapshots_absent_before_launch == true and .datasets_preserved == true and
        .candidate_running == true and .wallet_chain_synchronized_before_unlock == true and
        .normal_unlock_completed == true and .pos_active == true and
        .pos_explicitly_enabled == true and .final_container_identity_stable == true and
        .pow_policy_restored == true and .p2p_ready == true and .typed_gate_safe == true and
        .payout_unchanged == true and .quantum_keys_unchanged == true and
        .recovery_fees_unchanged == true and .resolution_txids_unchanged == true and
        .recovery_counters_unchanged == true and .recovery_policy_unchanged == true and
        .wallet_delta_fully_classified == true and
        .only_allowed_wallet_delta_classes_added == true and
        .failure_policy == "contain-stop-preserve" and .old_core_autostarted == false and
        .data_rewind_performed == false
    ' "$result" >/dev/null || return 1
    jq -e -n --slurpfile m "$marker" --slurpfile r "$result" '
      $r[0].phase_a_result_sha256 == $m[0].phase_a_result_sha256 and
      $r[0].package_sha256sums_sha256 == $m[0].package_sha256sums_sha256 and
      $r[0].tooling_commit == $m[0].tooling_commit and
      $r[0].phase_b_tooling_identity_sha256 == $m[0].phase_b_tooling_identity_sha256 and
      $r[0].phase_b_script_sha256 == $m[0].phase_b_script_sha256 and
      $r[0].verifier_sha256 == $m[0].verifier_sha256 and
      $r[0].typed_contract_sha256 == $m[0].typed_contract_sha256
    ' >/dev/null
}

v3015_pow_json_is_typed_safe()
{
    local json=$1
    jq -e -n --arg zero "$V3015_ZERO_TXID" --argjson p "$json" '
        def integer: type == "number" and floor == .;
        def uint: integer and . >= 0;
        def amount: type == "number" and . >= 0;
        def hex64: type == "string" and test("^[0-9a-f]{64}$");
        def action: IN("create_new_anchor","refresh_same_anchor","wait_for_live",
          "wait_for_next_tip","relay_existing");
        def pow_keys: [
          "accrued_jackpot","actionable_quarantined_claims",
          "allow_automatic_quantum_key_creation","autostart","blocking_quarantined_claims",
          "blocks_remaining","claim_coins_after_stake_reserve","claim_components",
          "claim_inventory_tip","claim_inventory_wallet_tip_matches",
          "claim_recovery_database_outcome_ambiguous","claims_auto_resolved",
          "claims_recycled","claims_submitted","configured_stake_reserve_coins",
          "cpu_percent","cumulative_resolution_fees","current_height","enabled",
          "epoch_active","hashrate","indeterminate_quarantined_claims",
          "last_stake_coin_guard","live_claims","mature_stakeable_legacy_coins",
          "mature_stakeable_legacy_weight","mining_gate_action",
          "mining_gate_can_submit","mining_gate_candidate_state_fingerprint",
          "mining_gate_coherent","mining_gate_database_ambiguous",
          "mining_gate_eligible_claims","mining_gate_family_claims",
          "mining_gate_lineage_head_txid","mining_gate_live_claims",
          "mining_gate_relay_txid","mining_gate_unresolved_components",
          "mining_gate_unsafe_claims","mining_gate_unsafe_components",
          "next_claim_amount","next_claim_payout","payout_address",
          "pending_automatic_resolutions","pending_manual_resolutions",
          "quarantined_claims","raw_quarantined_claims",
          "reserved_stake_coins","reserved_stake_weight",
          "resolved_on_active_chain_claims","shadow_reward_end_height",
          "shadow_reward_next_height","shadow_reward_start_height",
          "stake_reserve_snapshot_available","state","threads","unresolved_claims"];
        $p | type == "object" and
        ((keys | sort) == (pow_keys | sort)) and
        .enabled == true and .autostart == true and .threads == 1 and .cpu_percent == 1 and
        .allow_automatic_quantum_key_creation == false and
        (.hashrate | type == "number" and . >= 0) and
        (.state | IN("ready","hashing","claim_in_flight")) and
        (.current_height | integer and . >= -1) and
        (.shadow_reward_next_height | uint) and
        (.shadow_reward_start_height | uint) and
        (.shadow_reward_end_height | uint) and
        (.epoch_active | type) == "boolean" and
        (.blocks_remaining | uint) and
        (.payout_address | type == "string" and length > 0) and
        (.accrued_jackpot | amount) and (.next_claim_payout | amount) and
        (.next_claim_amount | uint) and (.claims_submitted | uint) and
        (.unresolved_claims | uint) and (.live_claims | uint) and
        .unresolved_claims >= .live_claims and
        (.quarantined_claims | uint) and (.raw_quarantined_claims | uint) and
        (.blocking_quarantined_claims | uint) and
        (.actionable_quarantined_claims | uint) and
        (.resolved_on_active_chain_claims | uint) and
        (.indeterminate_quarantined_claims | uint) and
        (.claim_components | uint) and
        .quarantined_claims == .blocking_quarantined_claims and
        .blocking_quarantined_claims ==
          (.actionable_quarantined_claims + .indeterminate_quarantined_claims) and
        .raw_quarantined_claims >= .blocking_quarantined_claims and
        (.pending_manual_resolutions | uint) and
        (.pending_automatic_resolutions | uint) and
        (.claims_auto_resolved | uint) and (.claims_recycled | uint) and
        (.cumulative_resolution_fees | amount) and
        .claim_inventory_wallet_tip_matches == true and
        (.claim_inventory_tip | hex64) and .claim_inventory_tip != $zero and
        .claim_recovery_database_outcome_ambiguous == false and
        .mining_gate_coherent == true and .mining_gate_database_ambiguous == false and
        (.mining_gate_action | action) and
        (.mining_gate_can_submit | type) == "boolean" and
        (.mining_gate_unsafe_claims | uint and . == 0) and
        (.mining_gate_unsafe_components | uint and . == 0) and
        (.mining_gate_unresolved_components | uint) and
        (.mining_gate_live_claims | uint) and
        (.mining_gate_eligible_claims | uint) and
        (.mining_gate_family_claims | uint) and
        (.mining_gate_relay_txid | hex64) and
        (.mining_gate_lineage_head_txid | hex64) and
        (.mining_gate_candidate_state_fingerprint | hex64) and
        .mining_gate_candidate_state_fingerprint != $zero and
        (.configured_stake_reserve_coins | uint) and
        (.mature_stakeable_legacy_coins | uint) and
        (.mature_stakeable_legacy_weight | amount) and
        (.reserved_stake_coins | uint) and (.reserved_stake_weight | amount) and
        (.claim_coins_after_stake_reserve | uint) and
        (.last_stake_coin_guard | type) == "boolean" and
        .stake_reserve_snapshot_available == true and
        (if (.mining_gate_action == "create_new_anchor" or
             .mining_gate_action == "refresh_same_anchor")
         then .mining_gate_can_submit == true
         elif .mining_gate_action == "wait_for_next_tip" then true
         else .mining_gate_can_submit == false end) and
        (if .mining_gate_action == "create_new_anchor" then
           .mining_gate_lineage_head_txid == $zero and
           .mining_gate_unresolved_components == 0 and
           .mining_gate_family_claims == 0
         else
           .mining_gate_lineage_head_txid != $zero and
           .mining_gate_unresolved_components == 1 and
           .mining_gate_family_claims >= 1
         end) and
        (if .mining_gate_action == "relay_existing" then
           .mining_gate_relay_txid != $zero and
           .mining_gate_eligible_claims >= 1 and .mining_gate_live_claims == 0
         elif .mining_gate_action == "wait_for_live" then
           .mining_gate_relay_txid == $zero and .mining_gate_live_claims >= 1
         elif .mining_gate_action == "wait_for_next_tip" then
           .mining_gate_live_claims == 0 and
           (if .mining_gate_relay_txid == $zero
            then .mining_gate_can_submit == true
            else .mining_gate_can_submit == false and
              .mining_gate_eligible_claims >= 1 end)
         elif .mining_gate_action == "refresh_same_anchor" then
           .mining_gate_relay_txid == $zero and .mining_gate_live_claims == 0
         else .mining_gate_relay_txid == $zero and
           .mining_gate_live_claims == 0 and .mining_gate_eligible_claims == 0 end) and
        (if (.mining_gate_action == "wait_for_live" or
             .mining_gate_action == "wait_for_next_tip" or
             .mining_gate_action == "relay_existing")
         then .state == "claim_in_flight" and .hashrate == 0
         else true end)
    ' >/dev/null
}

v3015_pos_json_is_active()
{
    local json=$1
    jq -e -n --argjson s "$json" '
        $s | type == "object" and .enabled == true and .staking == true and
        .worker_running == true and .eligible == true and
        .staking_state == "searching" and .staking_snapshot_current == true and
        (.staking_snapshot_sequence | type == "number" and floor == . and . > 0) and
        (.blocks | type == "number" and floor == . and . >= 0) and
        (.active_blocks | type == "number" and floor == . and . == $s.blocks) and
        (.weight | type == "number" and . > 0) and
        .weight_cached == true and .autostart_staking == true and
        .autostart_staking_source == "autostartstaking" and
        .allow_automatic_quantum_key_creation == false
    ' >/dev/null
}

v3015_locked_restart_json_is_valid()
{
    local json=$1
    jq -e -n --argjson s "$json" '
        $s | type == "object" and (keys | sort) ==
          ["normal_unlock_called","pos_intent_retained","pow","pow_intent_retained",
           "staking","wallet_locked"] and
        .wallet_locked == true and
        .normal_unlock_called == false and
        .pos_intent_retained == true and .pow_intent_retained == true and
        .pow.enabled == true and .pow.autostart == true and
        .pow.threads == 1 and .pow.cpu_percent == 1 and
        .pow.hashrate == 0 and .pow.claims_submitted == 0 and
        .pow.state == "wallet_locked_or_staking_only" and
        .staking.enabled == true and .staking.autostart_staking == true and
        .staking.worker_running == true and .staking.staking == false and
        .staking.eligible == false and .staking.staking_state == "locked"
    ' >/dev/null
}

v3015_pow_series_is_live()
{
    local samples=$1 sample
    jq -e -n --argjson samples "$samples" '
        def hex64: type == "string" and test("^[0-9a-f]{64}$");
        $samples | type == "array" and length >= 4 and
        ([.[].tip] | (all(.[]; hex64) and ((unique | length) >= 4))) and
        ([.[].height] as $h |
          all(range(1; ($h | length)); $h[.] > $h[.-1])) and
        all(.[].pow; type == "object") and
        all(.[]; .pow.current_height == .height and
          .pow.claim_inventory_tip == .tip and
          .pow.claim_inventory_wallet_tip_matches == true and
          .staking.blocks == .height and .staking.active_blocks == .height and
          (.wallet_generation | type == "number" and floor == . and . >= 0) and
          .wallet_processed_tip == .tip and .wallet_tip_matches == true) and
        all(range(1; ($samples | length)); . as $i |
          if ($samples[$i-1].pow.mining_gate_action == "wait_for_next_tip" and
              $samples[$i].pow.mining_gate_action == "wait_for_next_tip" and
              $samples[$i-1].tip != $samples[$i].tip)
          then $samples[$i-1].pow.mining_gate_candidate_state_fingerprint !=
               $samples[$i].pow.mining_gate_candidate_state_fingerprint
          else true end) and
        all(range(1; ($samples | length)); . as $i |
          ($samples[$i].pow.claims_submitted >= $samples[$i-1].pow.claims_submitted) and
          (if (($samples[$i-1].pow.mining_gate_action == "create_new_anchor" or
                $samples[$i-1].pow.mining_gate_action == "refresh_same_anchor") or
               ($samples[$i].pow.mining_gate_action == "create_new_anchor" or
                $samples[$i].pow.mining_gate_action == "refresh_same_anchor"))
           then ($samples[$i-1].pow.hashrate > 0 or $samples[$i].pow.hashrate > 0 or
                 $samples[$i].pow.claims_submitted >
                   $samples[$i-1].pow.claims_submitted)
           else true end))
    ' >/dev/null || return 1
    while IFS= read -r sample; do
        v3015_pow_json_is_typed_safe "$(jq -c '.pow' <<<"$sample")" || return 1
        v3015_pos_json_is_active "$(jq -c '.staking' <<<"$sample")" || return 1
        jq -e '.wallet_normal_unlocked == true and .ibd == false and
          .blocks == .headers and .peers_out >= 1' <<<"$sample" >/dev/null || return 1
    done < <(jq -c '.[]' <<<"$samples")
}

v3015_recovery_json_is_exact_safe()
{
    local recovery=$1
    jq -e -n --argjson recovery "$recovery" '
      def integer: type == "number" and floor == .;
      def uint: integer and . >= 0;
      def amount: type == "number" and . >= 0;
      def hex64: type == "string" and test("^[0-9a-f]{64}$");
      def recovery_keys: ["active_height","active_tip","actionable_quarantined_claims",
        "automatic_actions_in_window","automatic_fee_exposure_in_window",
        "blocking_components","blocking_quarantined_claims","chain_ready","claims_recycled",
        "component_details","components","confirmed_automatic_resolutions",
        "confirmed_manual_resolutions","confirmed_resolution_fees","database_outcome_ambiguous",
        "indeterminate_quarantined_claims","live_claim_objects","policy",
        "pending_automatic_resolutions","pending_manual_resolutions","policy_authoritative",
        "policy_state_detail","policy_state_status","quarantined_claim_objects",
        "raw_claim_objects","raw_quarantined_claims","reconciled_descendant_claims",
        "resolved_components","resolved_on_active_chain_claims","retired_claim_objects",
        "retired_components","unanchored_claim_txids","wallet_generation",
        "wallet_processed_height","wallet_processed_tip","wallet_tip_matches"];
      def policy_keys: ["aggregate_batch_fee_cap","automatic_authorized","automatic_enabled",
        "choice_recorded","max_actions_per_window","max_fee_per_resolution",
        "minimum_stale_blocks","mode","rolling_fee_budget","rolling_fee_window_seconds",
        "version"];
      def component_keys: ["all_claims_expired_locally_retired",
        "all_claims_explicitly_provenanced","all_claims_quarantined",
        "all_claims_zero_payment_retirable","anchor","anchor_authenticated","anchor_unspent",
        "claim_txids","classification","component_fingerprint","descendant_claims",
        "generation_fingerprint","has_revalidating_unbound_proof","minimum_stale_depth",
        "nodes","ordinary_or_mixed_txids","resolution_txids","root_claim_txids",
        "stale_depth_known"];
      def node_keys: ["abandoned","active_chain_confirmed","authored_metadata_valid",
        "authored_tip_active_branch_bound","claim_descriptor_valid","disposition",
        "exact_authored_carrier_shape","expected_shape","expired_locally_retired",
        "in_mempool","kind","lineage_family_fingerprint","lineage_metadata_present",
        "lineage_metadata_valid","lineage_ordinal","lineage_parent_txid",
        "lineage_root_txid","proof_evaluation_skipped_resolved_anchor","proof_input_bound",
        "proof_may_revalidate_on_descendant","proof_mode","proof_origin_bound",
        "proof_origin_height","proof_origin_previous_block_hash","proof_version","provenance",
        "quarantined","relay_expiry_time","relay_ttl_expired","resolution_metadata_valid",
        "resolution_relay_authorized","stale_depth","stale_depth_known","txid",
        "wallet_authored","wallet_from_me"];
      $recovery | type == "object" and (keys | sort) == (recovery_keys | sort) and
      (.policy | type == "object" and (keys | sort) == (policy_keys | sort)) and
      (.policy.version | integer and . == 1) and
      (.policy.mode | IN("unset","pause_and_ask")) and
      (.policy.choice_recorded | type) == "boolean" and
      (if .policy.mode == "unset" then .policy.choice_recorded == false
       else .policy.choice_recorded == true end) and
      .policy.automatic_enabled == false and .policy.automatic_authorized == false and
      all([.policy.max_fee_per_resolution,.policy.aggregate_batch_fee_cap,
        .policy.rolling_fee_budget][]; amount) and
      all([.policy.rolling_fee_window_seconds,.policy.max_actions_per_window,
        .policy.minimum_stale_blocks][]; uint) and
      .policy_authoritative == true and .policy_state_status == "success" and
      (.policy_state_detail | type == "string") and
      .database_outcome_ambiguous == false and .chain_ready == true and
      .wallet_tip_matches == true and (.active_tip | hex64) and
      .active_tip != ("0"*64) and (.active_height | uint) and
      .wallet_processed_tip == .active_tip and .wallet_processed_height == .active_height and
      (.wallet_generation | uint) and
      (["raw_quarantined_claims","blocking_quarantined_claims",
        "actionable_quarantined_claims","resolved_on_active_chain_claims",
        "indeterminate_quarantined_claims","components","raw_claim_objects",
        "live_claim_objects","quarantined_claim_objects","blocking_components",
        "retired_claim_objects","retired_components","resolved_components",
        "pending_manual_resolutions","pending_automatic_resolutions",
        "confirmed_manual_resolutions","confirmed_automatic_resolutions",
        "automatic_actions_in_window","reconciled_descendant_claims","claims_recycled"] |
        all(.[]; . as $key | $recovery[$key] | uint)) and
      .blocking_quarantined_claims ==
        (.actionable_quarantined_claims + .indeterminate_quarantined_claims) and
      .raw_quarantined_claims >= .blocking_quarantined_claims and
      .raw_claim_objects >= .live_claim_objects and
      .raw_claim_objects >= .quarantined_claim_objects and
      (.confirmed_resolution_fees | amount) and (.automatic_fee_exposure_in_window | amount) and
      (.component_details | type == "array") and
      all(.component_details[]; . as $component |
        type == "object" and (keys | sort) == (component_keys | sort) and
        (.anchor | type == "object" and (keys | sort) ==
          ["amount","scriptPubKey","txid","vout"]) and
        (.anchor.txid | hex64) and (.anchor.vout | uint) and (.anchor.amount | amount) and
        (.anchor.scriptPubKey | type == "string" and test("^([0-9a-f]{2})+$")) and
        (.generation_fingerprint | hex64) and (.component_fingerprint | hex64) and
        (.classification | IN("live","transient","indeterminate",
          "current_branch_ineligible","terminal_on_pinned_tip","retired_on_active_branch",
          "resolution_pending","resolved_on_active_chain")) and
        all([.claim_txids,.root_claim_txids,.resolution_txids,.ordinary_or_mixed_txids][];
          type == "array" and all(.[]; hex64) and (unique | length) == length) and
        (.descendant_claims | uint) and (.minimum_stale_depth | uint) and
        all([.stale_depth_known,.anchor_authenticated,.anchor_unspent,
          .all_claims_quarantined,.all_claims_explicitly_provenanced,
          .all_claims_zero_payment_retirable,.all_claims_expired_locally_retired,
          .has_revalidating_unbound_proof][]; type == "boolean") and
        (.nodes | type == "array") and
        all(.nodes[]; type == "object" and (keys | sort) == (node_keys | sort) and
          (.txid | hex64) and
          (.kind | IN("claim","managed_resolution","legacy_resolution","ordinary")) and
          (.provenance | IN("explicit_authored","explicit_adopted",
            "legacy_wallet_authored","unknown")) and
          (.disposition | type == "string" and length > 0) and
          (.proof_mode | IN("pow","pos","unknown","malformed")) and
          (.proof_version | uint) and (.proof_origin_height | integer) and
          (.proof_origin_previous_block_hash | hex64) and (.relay_expiry_time | integer) and
          (.lineage_family_fingerprint | hex64) and (.lineage_root_txid | hex64) and
          (.lineage_parent_txid | hex64) and (.lineage_ordinal | uint) and
          (.stale_depth | uint) and
          all([.proof_may_revalidate_on_descendant,.active_chain_confirmed,.in_mempool,
            .quarantined,.expected_shape,.wallet_authored,.wallet_from_me,
            .authored_metadata_valid,.authored_tip_active_branch_bound,.claim_descriptor_valid,
            .proof_evaluation_skipped_resolved_anchor,.proof_origin_bound,.proof_input_bound,
            .exact_authored_carrier_shape,.relay_ttl_expired,.lineage_metadata_present,
            .lineage_metadata_valid,.abandoned,.expired_locally_retired,.stale_depth_known,
            .resolution_metadata_valid,.resolution_relay_authorized][]; type == "boolean")) and
        ([.nodes[] | select(.kind == "claim") | .txid] | sort) ==
          (.claim_txids | sort) and
        ([.nodes[] | select(.kind == "managed_resolution" or .kind == "legacy_resolution") |
          .txid] | sort) == (.resolution_txids | sort) and
        ([.nodes[] | select(.kind == "ordinary") | .txid] | sort) ==
          (.ordinary_or_mixed_txids | sort) and
        all(.nodes[] | select(.kind == "claim" and .lineage_metadata_present == true);
          . as $node |
          $node.lineage_family_fingerprint == $component.generation_fingerprint and
          $node.lineage_root_txid != ("0"*64) and
          (($component.root_claim_txids | index($node.lineage_root_txid)) != null) and
          (if $node.lineage_ordinal == 0 then
             $node.lineage_root_txid == $node.txid and
             $node.lineage_parent_txid == ("0"*64)
           else
             $node.lineage_parent_txid != ("0"*64) and
             $node.lineage_parent_txid != $node.txid and
             (($component.claim_txids | index($node.lineage_parent_txid)) != null)
           end))) and
      .raw_claim_objects ==
        ([.component_details[].nodes[] | select(.kind == "claim")] | length) and
      .live_claim_objects ==
        ([.component_details[].nodes[] | select(.kind == "claim" and .in_mempool)] | length) and
      .quarantined_claim_objects ==
        ([.component_details[].nodes[] | select(.kind == "claim" and .quarantined)] | length) and
      .blocking_components == ([.component_details[] | select(.classification |
        IN("live","transient","indeterminate","current_branch_ineligible",
           "terminal_on_pinned_tip","resolution_pending"))] | length) and
      .retired_components ==
        ([.component_details[] | select(.classification == "retired_on_active_branch")] | length) and
      .retired_claim_objects == ([.component_details[] |
        select(.classification == "retired_on_active_branch") | .claim_txids[]] | length) and
      .resolved_components ==
        ([.component_details[] | select(.classification == "resolved_on_active_chain")] | length) and
      (.unanchored_claim_txids | type == "array" and length == 0)
    ' >/dev/null
}

v3015_make_wallet_audit()
{
    local before=$1 after=$2
    jq -cn --argjson before "$before" --argjson after "$after" '
      def ids($s): [$s.transactions[].txid] | unique | sort;
      def metrics($r): $r | {pending_manual_resolutions,pending_automatic_resolutions,
        confirmed_manual_resolutions,confirmed_automatic_resolutions,
        confirmed_resolution_fees,automatic_actions_in_window,
        automatic_fee_exposure_in_window,reconciled_descendant_claims,claims_recycled};
      def resolution_ids($r): [$r.component_details[]?.resolution_txids[]?] | unique | sort;
      def ordinary_ids($r): [$r.component_details[]?.ordinary_or_mixed_txids[]?] | unique | sort;
      def classify($txid):
        ([$after.transactions[] | select(.txid == $txid)]) as $rows |
        ([$after.recovery.component_details[] as $component |
          $component.nodes[] | select(.txid == $txid and .kind == "claim") |
          {component:$component,node:.}]) as $matches |
        ([$rows[] | select(.qq_synthetic_goldrush_payout == "1" and
          (.blockhash // "") != "")] | length > 0) as $synthetic |
        ([$rows[] | select(.category == "generate" and (.blockhash // "") != "" and
          (.qq_synthetic_goldrush_payout // "0") != "1")] | length > 0) as $coinstake |
        ($matches | length == 1 and
          $matches[0].component.anchor_authenticated == true and
          $matches[0].component.anchor_unspent == true and
          $matches[0].component.all_claims_explicitly_provenanced == true and
          $matches[0].component.all_claims_expired_locally_retired == false and
          $matches[0].node.wallet_authored == true and $matches[0].node.wallet_from_me == true and
          $matches[0].node.authored_metadata_valid == true and
          $matches[0].node.claim_descriptor_valid == true and
          $matches[0].node.proof_origin_bound == true and
          $matches[0].node.proof_input_bound == true and
          $matches[0].node.lineage_metadata_present == true and
          $matches[0].node.lineage_metadata_valid == true and
          $matches[0].node.lineage_family_fingerprint ==
            $matches[0].component.generation_fingerprint and
          $matches[0].node.lineage_root_txid != ("0"*64) and
          (($matches[0].component.root_claim_txids |
            index($matches[0].node.lineage_root_txid)) != null) and
          (if $matches[0].node.lineage_ordinal == 0 then
             $matches[0].node.lineage_root_txid == $matches[0].node.txid and
             $matches[0].node.lineage_parent_txid == ("0"*64)
           else
             $matches[0].node.lineage_parent_txid != ("0"*64) and
             $matches[0].node.lineage_parent_txid != $matches[0].node.txid and
             (($matches[0].component.claim_txids |
               index($matches[0].node.lineage_parent_txid)) != null)
           end) and
          $matches[0].node.abandoned == false and
          $matches[0].node.expired_locally_retired == false and
          ($matches[0].component.claim_txids | index($txid)) != null and
          ($matches[0].component.resolution_txids | index($txid)) == null and
          ($matches[0].component.ordinary_or_mixed_txids | index($txid)) == null) as $claim |
        {txid:$txid,authenticated_same_anchor_claim:$claim,normal_coinstake:$coinstake,
          authenticated_synthetic_payout:$synthetic,
          exactly_one_allowed_class:(([$claim,$coinstake,$synthetic] |
            map(select(. == true)) | length) == 1),
          per_tx_abandoned:([$rows[] | (.abandoned // false)] | any),
          cleanup:([$rows[] | select(has("qq_shadow_pow_cleanup_for"))] | length > 0),
          recovery:([$rows[] | select(has("qq_shadow_pow_resolution_origin"))] | length > 0),
          resolution:([$rows[] | select(has("qq_shadow_pow_resolution_schema"))] | length > 0),
          recovery_fee:([$rows[] | select(has("qq_shadow_pow_resolution_origin") or
            has("qq_shadow_pow_resolution_schema")) | (.fee // 0)] | add // 0)};
      (ids($after) - ids($before)) as $added |
      {before:$before,after:$after,delta:{
        added_txids:$added,removed_txids:(ids($before) - ids($after)),
        transaction_count_before:$before.wallet.txcount,
        transaction_count_after:$after.wallet.txcount,
        transaction_rows_unique_before:(ids($before)|length),
        transaction_rows_unique_after:(ids($after)|length),
        recovery_policy_before:$before.recovery.policy,
        recovery_policy_after:$after.recovery.policy,
        recovery_metrics_before:metrics($before.recovery),
        recovery_metrics_after:metrics($after.recovery),
        component_resolution_txids_before:resolution_ids($before.recovery),
        component_resolution_txids_after:resolution_ids($after.recovery),
        ordinary_or_mixed_txids_before:ordinary_ids($before.recovery),
        ordinary_or_mixed_txids_after:ordinary_ids($after.recovery),
        transactions:[$added[] | classify(.)]}}
    '
}

v3015_wallet_delta_is_safe()
{
    local json=$1 before after
    before=$(jq -ce '.before' <<<"$json") || return 1
    after=$(jq -ce '.after' <<<"$json") || return 1
    v3015_recovery_json_is_exact_safe "$(jq -c '.recovery' <<<"$before")" || return 1
    v3015_recovery_json_is_exact_safe "$(jq -c '.recovery' <<<"$after")" || return 1
    jq -e -n --argjson audit "$json" '
      def hex64: type == "string" and test("^[0-9a-f]{64}$");
      def ids($s): [$s.transactions[].txid] | unique | sort;
      def metrics($r): $r | {pending_manual_resolutions,pending_automatic_resolutions,
        confirmed_manual_resolutions,confirmed_automatic_resolutions,
        confirmed_resolution_fees,automatic_actions_in_window,
        automatic_fee_exposure_in_window,reconciled_descendant_claims,claims_recycled};
      def resolution_ids($r): [$r.component_details[]?.resolution_txids[]?] | unique | sort;
      def ordinary_ids($r): [$r.component_details[]?.ordinary_or_mixed_txids[]?] | unique | sort;
      def classify($txid; $after):
        ([$after.transactions[] | select(.txid == $txid)]) as $rows |
        ([$after.recovery.component_details[] as $component |
          $component.nodes[] | select(.txid == $txid and .kind == "claim") |
          {component:$component,node:.}]) as $matches |
        ([$rows[] | select(.qq_synthetic_goldrush_payout == "1" and
          (.blockhash // "") != "")] | length > 0) as $synthetic |
        ([$rows[] | select(.category == "generate" and (.blockhash // "") != "" and
          (.qq_synthetic_goldrush_payout // "0") != "1")] | length > 0) as $coinstake |
        ($matches | length == 1 and
          $matches[0].component.anchor_authenticated == true and
          $matches[0].component.anchor_unspent == true and
          $matches[0].component.all_claims_explicitly_provenanced == true and
          $matches[0].component.all_claims_expired_locally_retired == false and
          $matches[0].node.wallet_authored == true and
          $matches[0].node.wallet_from_me == true and
          $matches[0].node.authored_metadata_valid == true and
          $matches[0].node.claim_descriptor_valid == true and
          $matches[0].node.proof_origin_bound == true and
          $matches[0].node.proof_input_bound == true and
          $matches[0].node.lineage_metadata_present == true and
          $matches[0].node.lineage_metadata_valid == true and
          $matches[0].node.lineage_family_fingerprint ==
            $matches[0].component.generation_fingerprint and
          $matches[0].node.lineage_root_txid != ("0"*64) and
          (($matches[0].component.root_claim_txids |
            index($matches[0].node.lineage_root_txid)) != null) and
          (if $matches[0].node.lineage_ordinal == 0 then
             $matches[0].node.lineage_root_txid == $matches[0].node.txid and
             $matches[0].node.lineage_parent_txid == ("0"*64)
           else
             $matches[0].node.lineage_parent_txid != ("0"*64) and
             $matches[0].node.lineage_parent_txid != $matches[0].node.txid and
             (($matches[0].component.claim_txids |
               index($matches[0].node.lineage_parent_txid)) != null)
           end) and
          $matches[0].node.abandoned == false and
          $matches[0].node.expired_locally_retired == false and
          ($matches[0].component.claim_txids | index($txid)) != null and
          ($matches[0].component.resolution_txids | index($txid)) == null and
          ($matches[0].component.ordinary_or_mixed_txids | index($txid)) == null) as $claim |
        {txid:$txid,authenticated_same_anchor_claim:$claim,normal_coinstake:$coinstake,
          authenticated_synthetic_payout:$synthetic,
          exactly_one_allowed_class:(([$claim,$coinstake,$synthetic] |
            map(select(. == true)) | length) == 1),
          per_tx_abandoned:([$rows[] | (.abandoned // false)] | any),
          cleanup:([$rows[] | select(has("qq_shadow_pow_cleanup_for"))] | length > 0),
          recovery:([$rows[] | select(has("qq_shadow_pow_resolution_origin"))] | length > 0),
          resolution:([$rows[] | select(has("qq_shadow_pow_resolution_schema"))] | length > 0),
          recovery_fee:([$rows[] | select(has("qq_shadow_pow_resolution_origin") or
            has("qq_shadow_pow_resolution_schema")) | (.fee // 0)] | add // 0)};
      $audit | type == "object" and (keys | sort) == ["after","before","delta"] and
      (.before | type == "object" and (keys | sort) ==
        ["chain","loaded_wallets","payout","quantum_inventory","recovery",
         "transactions","wallet"]) and
      (.after | type == "object" and (keys | sort) ==
        ["chain","loaded_wallets","payout","quantum_inventory","recovery",
         "transactions","wallet"]) and
      (.delta | type == "object" and (keys | sort) ==
        ["added_txids","component_resolution_txids_after",
         "component_resolution_txids_before","ordinary_or_mixed_txids_after",
         "ordinary_or_mixed_txids_before","recovery_metrics_after",
         "recovery_metrics_before","recovery_policy_after","recovery_policy_before",
         "removed_txids","transaction_count_after","transaction_count_before",
         "transaction_rows_unique_after","transaction_rows_unique_before","transactions"]) and
      all(.before.transactions[]; (.txid | hex64)) and
      all(.after.transactions[]; (.txid | hex64)) and
      (ids(.before) | length) == .before.wallet.txcount and
      (ids(.after) | length) == .after.wallet.txcount and
      .delta.transaction_rows_unique_before == (ids(.before) | length) and
      .delta.transaction_rows_unique_after == (ids(.after) | length) and
      .delta.transaction_count_before == .before.wallet.txcount and
      .delta.transaction_count_after == .after.wallet.txcount and
      .delta.added_txids == (ids(.after) - ids(.before)) and
      .delta.removed_txids == (ids(.before) - ids(.after)) and .delta.removed_txids == [] and
      .after.wallet.txcount == (.before.wallet.txcount + (.delta.added_txids | length)) and
      .before.wallet.walletname == "" and .after.wallet.walletname == "" and
      .before.loaded_wallets == [""] and .after.loaded_wallets == [""] and
      .before.wallet.private_keys_enabled == true and .after.wallet.private_keys_enabled == true and
      .before.quantum_inventory == .after.quantum_inventory and
      .before.wallet.quantum_keys == .after.wallet.quantum_keys and
      .before.wallet.keypoolsize == .after.wallet.keypoolsize and
      (.before.wallet.keypoolsize_hd_internal // 0) ==
        (.after.wallet.keypoolsize_hd_internal // 0) and
      .before.payout == .after.payout and
      .after.recovery.wallet_generation >= .before.recovery.wallet_generation and
      .after.recovery.wallet_processed_tip == .after.chain.bestblockhash and
      .after.recovery.wallet_tip_matches == true and
      .before.recovery.policy == .after.recovery.policy and
      .delta.recovery_policy_before == .before.recovery.policy and
      .delta.recovery_policy_after == .after.recovery.policy and
      .delta.recovery_metrics_before == metrics(.before.recovery) and
      .delta.recovery_metrics_after == metrics(.after.recovery) and
      .delta.recovery_metrics_before == .delta.recovery_metrics_after and
      .delta.recovery_metrics_after.pending_manual_resolutions == 0 and
      .delta.recovery_metrics_after.pending_automatic_resolutions == 0 and
      .delta.recovery_metrics_after.automatic_fee_exposure_in_window == 0 and
      .delta.component_resolution_txids_before == resolution_ids(.before.recovery) and
      .delta.component_resolution_txids_after == resolution_ids(.after.recovery) and
      .delta.component_resolution_txids_before == .delta.component_resolution_txids_after and
      .delta.ordinary_or_mixed_txids_before == ordinary_ids(.before.recovery) and
      .delta.ordinary_or_mixed_txids_after == ordinary_ids(.after.recovery) and
      .delta.ordinary_or_mixed_txids_before == .delta.ordinary_or_mixed_txids_after and
      .delta.transactions == [.delta.added_txids[] | classify(.; $audit.after)] and
      all(.delta.transactions[]; .exactly_one_allowed_class == true and
        .per_tx_abandoned == false and .cleanup == false and .recovery == false and
        .resolution == false and .recovery_fee == 0)
    ' >/dev/null
}

v3015_node_result_is_valid()
{
    local file=$1 expected_node=$2
    [[ "$expected_node" =~ ^([1-9]|[12][0-9]|3[12])$ && "$expected_node" != 30 ]] || return 1
    jq -e --argjson node "$expected_node" --arg source "$SOURCE_SHA" \
      --arg image "$CANDIDATE_IMAGE_REF" --arg image_id "$CANDIDATE_IMAGE_ID" '
        type == "object" and (keys | sort) == (["container_recreated",
          "container_id_after_recreate","container_id_before","containment_only_on_failure",
          "data_rewind_used","invocation","locked_restart",
          "network_version","node","normal_unlock_only","repair_rpcs","restart_performed",
          "samples","schema","source_sha","subversion","wallet_audit"] | sort) and
        (.invocation | type == "object" and (keys | sort) ==
          ["candidate_image_id","candidate_image_ref","config_cmd",
           "entrypoint_body_sha256","runtime_argv_sha256"]) and
        .schema == 1 and .node == $node and .source_sha == $source and
        .network_version == 300105 and .subversion == "/Blackcoin:30.1.5/" and
        .restart_performed == true and .container_recreated == true and
        (.container_id_before | type == "string" and test("^[0-9a-f]{64}$")) and
        (.container_id_after_recreate | type == "string" and test("^[0-9a-f]{64}$")) and
        .container_id_before != .container_id_after_recreate and
        .normal_unlock_only == true and
        .repair_rpcs == [] and .data_rewind_used == false and
        .containment_only_on_failure == true and
        .invocation.candidate_image_ref == $image and
        .invocation.candidate_image_id == $image_id and
        .invocation.entrypoint_body_sha256 ==
          "753acc9904b48c411f5514abface930f79d72d00c9d73e91435a6511877d47b4" and
        (.invocation.runtime_argv_sha256 | type == "string" and
          test("^[0-9a-f]{64}$")) and
        .invocation.config_cmd == ["-walletbroadcast=1","-autostartstaking=1","-powmining=1",
          "-powminingthreads=1","-powminingcpu=1"] and
        (.samples | type == "array" and length >= 4)
    ' "$file" >/dev/null || return 1
    v3015_locked_restart_json_is_valid "$(jq -c '.locked_restart' "$file")" || return 1
    v3015_pow_series_is_live "$(jq -c '.samples' "$file")" || return 1
    v3015_wallet_delta_is_safe "$(jq -c '.wallet_audit' "$file")"
}

v3015_node30_probe_samples_are_live()
{
    local samples=$1 sample
    jq -e -n --argjson samples "$samples" '
      def hex64: type == "string" and test("^[0-9a-f]{64}$");
      $samples | type == "array" and length >= 4 and
      ([.[].tip] | all(.[]; hex64) and (unique | length) >= 4) and
      ([.[].height] as $heights |
        all(range(1;($heights|length)); $heights[.] > $heights[.-1]))
    ' >/dev/null || return 1
    while IFS= read -r sample; do
        v3015_pos_json_is_active "$(jq -c '.pos' <<<"$sample")" || return 1
        jq -e '.wallet_normal_unlocked == true and .free_claim_healthy == true and
          .free_claim_paused == false and .ibd == false and .blocks == .headers and
          .peers_out >= 1 and .regular_pow.enabled == false and
          .regular_pow.hashrate == 0 and .regular_pow.state == "disabled"' \
          <<<"$sample" >/dev/null || return 1
    done < <(jq -c '.[]' <<<"$samples")
}

v3015_node30_probe_output_is_valid()
{
    local file=$1 expected_observation=$2
    [[ "$expected_observation" == initial || "$expected_observation" == terminal ]] || return 1
    [[ -f "$file" && ! -L "$file" ]] || return 1
    jq -e --arg tool "$NODE30_FREE_CLAIM_PROBE_SHA256" \
      --arg observation "$expected_observation" '
      type == "object" and (keys | sort) ==
        ["observation","payload","probe_tool_sha256","schema"] and
      .schema == 1 and .observation == $observation and .probe_tool_sha256 == $tool and
      (.payload | type == "object" and (keys | sort) ==
        ["free_claim_intent_retained","healthy","locked_restart","node","paused",
         "samples","wallet_normal_unlocked"]) and
      (.payload.locked_restart | type == "object" and (keys | sort) ==
        ["free_claim_intent_retained"]) and
      .payload.node == 30 and
      .payload.healthy == true and .payload.paused == false and
      .payload.wallet_normal_unlocked == true and
      .payload.free_claim_intent_retained == true and
      .payload.locked_restart.free_claim_intent_retained == true and
      (.payload.samples | type == "array" and length >= 4)
    ' "$file" >/dev/null || return 1
    v3015_node30_probe_samples_are_live "$(jq -c '.payload.samples' "$file")"
}

v3015_node30_result_is_valid()
{
    local file=$1 raw_probe=$2 sample probe_sha
    v3015_node30_probe_output_is_valid "$raw_probe" initial || return 1
    probe_sha=$(v3015_sha256_file "$raw_probe") || return 1
    jq -e --arg source "$SOURCE_SHA" --arg image "$CANDIDATE_IMAGE_REF" \
      --arg image_id "$CANDIDATE_IMAGE_ID" --arg probe_sha "$probe_sha" \
      --arg probe_tool "$NODE30_FREE_CLAIM_PROBE_SHA256" \
      --argjson raw "$(jq -c '.payload' "$raw_probe")" '
        type == "object" and (keys | sort) == ["container_recreated",
          "containment_only_on_failure","data_rewind_used","free_claim_intent_retained",
          "healthy","invocation","locked_restart","network_version","no_recovery_or_resolution_transaction",
          "node","normal_unlock_only","paused","probe_tool_sha256","raw_probe_sha256","recovery_fee_delta",
          "regular_pow_enabled","repair_rpcs","restart_performed","role","samples","schema",
          "source_sha","subversion","wallet_audit","wallet_normal_unlocked"] and
        .schema == 1 and .node == 30 and .source_sha == $source and
        .network_version == 300105 and .subversion == "/Blackcoin:30.1.5/" and
        .role == "free_claim" and .regular_pow_enabled == false and
        .probe_tool_sha256 == $probe_tool and .raw_probe_sha256 == $probe_sha and
        .healthy == $raw.healthy and
        .paused == $raw.paused and .wallet_normal_unlocked == $raw.wallet_normal_unlocked and
        .container_recreated == true and .restart_performed == true and
        .normal_unlock_only == true and .repair_rpcs == [] and .data_rewind_used == false and
        .containment_only_on_failure == true and
        (.invocation | type == "object" and (keys | sort) ==
          ["candidate_image_id","candidate_image_ref","config_cmd",
           "entrypoint_body_sha256","runtime_argv_sha256"]) and
        .invocation.candidate_image_ref == $image and
        .invocation.candidate_image_id == $image_id and
        .invocation.entrypoint_body_sha256 ==
          "753acc9904b48c411f5514abface930f79d72d00c9d73e91435a6511877d47b4" and
        (.invocation.runtime_argv_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
        .invocation.config_cmd ==
          ["-walletbroadcast=1","-autostartstaking=1","-powmining=0"] and
        .free_claim_intent_retained == $raw.free_claim_intent_retained and
        (.locked_restart | type == "object" and (keys | sort) ==
          ["free_claim_intent_retained","normal_unlock_called","pos_intent_retained",
           "regular_pow","regular_pow_disabled","staking","wallet_locked"]) and
        .locked_restart.wallet_locked == true and
        .locked_restart.normal_unlock_called == false and
        .locked_restart.pos_intent_retained == true and
        .locked_restart.regular_pow_disabled == true and
        .locked_restart.free_claim_intent_retained ==
          $raw.locked_restart.free_claim_intent_retained and
        .locked_restart.staking.enabled == true and
        .locked_restart.staking.autostart_staking == true and
        .locked_restart.staking.worker_running == true and
        .locked_restart.staking.staking == false and
        .locked_restart.staking.eligible == false and
        .locked_restart.staking.staking_state == "locked" and
        .locked_restart.regular_pow.enabled == false and
        .locked_restart.regular_pow.hashrate == 0 and
        .locked_restart.regular_pow.state == "disabled" and
        .no_recovery_or_resolution_transaction ==
          (.wallet_audit.delta.component_resolution_txids_before ==
           .wallet_audit.delta.component_resolution_txids_after) and
        .recovery_fee_delta ==
          (.wallet_audit.after.recovery.confirmed_resolution_fees -
           .wallet_audit.before.recovery.confirmed_resolution_fees) and
        .recovery_fee_delta == 0 and
        .samples == $raw.samples and
        (.samples | type == "array" and length >= 4) and
        ([.samples[].tip] | unique | length) >= 4 and
        ([.samples[].height] as $h |
          all(range(1;($h|length)); $h[.] > $h[.-1]))
    ' "$file" >/dev/null || return 1
    v3015_wallet_delta_is_safe "$(jq -c '.wallet_audit' "$file")" || return 1
    jq -e '.wallet_audit.delta.added_txids == [] and
      .wallet_audit.delta.removed_txids == []' "$file" >/dev/null || return 1
    while IFS= read -r sample; do
        v3015_pos_json_is_active "$(jq -c '.pos' <<<"$sample")" || return 1
        jq -e '.wallet_normal_unlocked == true and .free_claim_healthy == true and
          .free_claim_paused == false and .ibd == false and .blocks == .headers and
          .peers_out >= 1 and .regular_pow.enabled == false and
          .regular_pow.hashrate == 0 and .regular_pow.state == "disabled"' \
          <<<"$sample" >/dev/null || return 1
    done < <(jq -c '.samples[]' "$file")
}

v3015_terminal_census_is_valid()
{
    local file=$1 evidence=$2 row node result_file expected_sha terminal_probe_sha
    v3015_node30_probe_output_is_valid \
      "$evidence/node-30-free-claim-terminal-probe.raw.json" terminal || return 1
    terminal_probe_sha=$(v3015_sha256_file \
      "$evidence/node-30-free-claim-terminal-probe.raw.json") || return 1
    jq -e --arg source "$SOURCE_SHA" --arg image "$CANDIDATE_IMAGE_REF" \
      --arg image_id "$CANDIDATE_IMAGE_ID" \
      --arg probe_tool "$NODE30_FREE_CLAIM_PROBE_SHA256" \
      --arg terminal_probe "$terminal_probe_sha" '
      def integer: type == "number" and floor == .;
      type == "object" and (keys | sort) ==
        ["captured_utc","node30_free_claim_healthy","node30_free_claim_paused",
         "node30_free_claim_probe_tool_sha256","node30_terminal_probe_sha256","nodes",
         "pos_active_count","pos_active_nodes","regular_pow_nodes",
         "regular_pow_operational_count","schema","source_sha"] and
      .schema == 1 and .source_sha == $source and
      (.captured_utc | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")) and
      (.nodes | type == "array" and length == 32) and
      [.nodes[].node] == [range(1;33)] and ([.nodes[].node] | unique | length) == 32 and
      .pos_active_nodes == [.nodes[] | select(.pos_contract_passed == true) | .node] and
      .pos_active_count == (.pos_active_nodes | length) and
      .regular_pow_nodes == [.nodes[] | select(.role == "regular" and
        .pow_contract_passed == true) | .node] and
      .regular_pow_operational_count == (.regular_pow_nodes | length) and
      .pos_active_nodes == [range(1;33)] and
      .regular_pow_nodes == ([range(1;30)] + [31,32]) and
      .node30_free_claim_healthy == .nodes[29].free_claim_healthy and
      .node30_free_claim_paused == .nodes[29].free_claim_paused and
      .node30_free_claim_healthy == true and .node30_free_claim_paused == false and
      .node30_free_claim_probe_tool_sha256 == $probe_tool and
      .node30_terminal_probe_sha256 == $terminal_probe and
      all(.nodes[]; type == "object" and (keys | sort) ==
        ["chain","container_image_id","container_image_ref","free_claim_healthy",
         "free_claim_paused","free_claim_probe_output_sha256",
         "free_claim_probe_tool_sha256","network","network_version","node",
         "node_result_sha256","pos_contract_passed","pow","pow_contract_passed","role",
         "source_sha","staking","subversion","wallet"] and
        .source_sha == $source and .network_version == 300105 and
        .subversion == "/Blackcoin:30.1.5/" and
        .container_image_ref == $image and .container_image_id == $image_id and
        (.node_result_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
        .chain.initialblockdownload == false and .chain.blocks == .chain.headers and
        (.network.connections_out | integer and . >= 1) and
        .wallet.walletname == "" and .wallet.private_keys_enabled == true and
        (.wallet.unlocked_until | integer and . > 0) and
        (.wallet.unlocked_staking_only // false) == false)
    ' "$file" >/dev/null || return 1
    while IFS= read -r row; do
        node=$(jq -er '.node' <<<"$row") || return 1
        result_file=$(printf '%s/node-%02d.json' "$evidence" "$node")
        if [[ "$node" == 30 ]]; then
            result_file="$evidence/node-30-free-claim.json"
            expected_sha=$(v3015_sha256_file "$result_file") || return 1
            [[ "$(jq -er '.node_result_sha256' <<<"$row")" == "$expected_sha" ]] || return 1
            [[ "$(jq -er '.free_claim_probe_output_sha256' <<<"$row")" == \
               "$terminal_probe_sha" &&
               "$(jq -er '.free_claim_probe_tool_sha256' <<<"$row")" == \
               "$NODE30_FREE_CLAIM_PROBE_SHA256" ]] || return 1
            v3015_pos_json_is_active "$(jq -c '.staking' <<<"$row")" || return 1
            jq -e '.role == "free_claim" and .pos_contract_passed == true and
              .pow_contract_passed == false and .free_claim_healthy == true and
              .free_claim_paused == false and .pow.enabled == false and
              .pow.autostart == false and .pow.hashrate == 0 and .pow.state == "disabled"' \
              <<<"$row" >/dev/null || return 1
        else
            expected_sha=$(v3015_sha256_file "$result_file") || return 1
            [[ "$(jq -er '.node_result_sha256' <<<"$row")" == "$expected_sha" ]] || return 1
            v3015_pos_json_is_active "$(jq -c '.staking' <<<"$row")" || return 1
            v3015_pow_json_is_typed_safe "$(jq -c '.pow' <<<"$row")" || return 1
            jq -e '.role == "regular" and .pos_contract_passed == true and
              .pow_contract_passed == true and .free_claim_healthy == false and
              .free_claim_paused == false and .free_claim_probe_output_sha256 == null and
              .free_claim_probe_tool_sha256 == null' \
              <<<"$row" >/dev/null || return 1
        fi
    done < <(jq -c '.nodes[]' "$file")
}

v3015_fleet_result_is_valid()
{
    local file=$1 census_sha=$2 terminal_probe_sha=$3
    v3015_is_sha256 "$terminal_probe_sha" || return 1
    jq -e --arg source "$SOURCE_SHA" --arg census "$census_sha" \
      --arg policy_receipt "$RUNTIME_POLICY_HANDOFF_RECEIPT_SHA256" \
      --arg compose_receipt "$PERSISTENT_COMPOSE_HANDOFF_RECEIPT_SHA256" \
      --arg compose_sha "$FINAL_COMPOSE_SHA256" --arg policy_sha "$FINAL_IMAGE_POLICY_SHA256" \
      --arg reconcile "$POST_COMPOSE_RECONCILE_IDENTITY_SHA256" \
      --arg probe_tool "$NODE30_FREE_CLAIM_PROBE_SHA256" \
      --arg terminal_probe "$terminal_probe_sha" '
      type == "object" and (keys | sort) == (["containment_only_failure_policy",
        "data_rewind_used","final_compose_sha256","final_image_policy_sha256",
        "node30_free_claim_healthy","node30_free_claim_paused",
        "node30_free_claim_probe_tool_sha256","node30_role","node30_terminal_probe_sha256",
        "persistent_compose_handoff_receipt_sha256","pos_active","pos_active_nodes",
        "post_compose_reconcile_identity_sha256","recovery_fees_delta",
        "recovery_transactions_created","regular_pow_nodes","regular_pow_operational",
        "runtime_policy_handoff_receipt_sha256","schema","source_sha","status",
        "terminal_census_sha256","transaction"] | sort) and
      .schema == 1 and .transaction == "v30.1.5-fleet-rollout" and
      .source_sha == $source and .status == "PASS" and
      .terminal_census_sha256 == $census and
      .pos_active == 32 and .regular_pow_operational == 31 and
      .pos_active_nodes == [range(1;33)] and
      .regular_pow_nodes == ([range(1;30)] + [31,32]) and
      .node30_role == "free_claim" and .node30_free_claim_healthy == true and
      .node30_free_claim_paused == false and .data_rewind_used == false and
      .node30_free_claim_probe_tool_sha256 == $probe_tool and
      .node30_terminal_probe_sha256 == $terminal_probe and
      .runtime_policy_handoff_receipt_sha256 == $policy_receipt and
      .persistent_compose_handoff_receipt_sha256 == $compose_receipt and
      .final_compose_sha256 == $compose_sha and .final_image_policy_sha256 == $policy_sha and
      .post_compose_reconcile_identity_sha256 == $reconcile and
      .recovery_transactions_created == false and .recovery_fees_delta == 0 and
      .containment_only_failure_policy == true
    ' "$file" >/dev/null
}

v3015_rollout_authority_is_valid()
{
    local file=$1
    jq -e --arg source "$SOURCE_SHA" --arg phase_b "$PHASE_B_RESULT_SHA256" \
      --arg package "$PACKAGE_SHA256SUMS_SHA256" \
      --arg probe_tool "$NODE30_FREE_CLAIM_PROBE_SHA256" \
      --arg live "$LIVE_EXECUTION_CLEARED" --arg native "$NATIVE_RESTART_CLEARED" \
      --arg nonce "${LIVE_EXECUTION_CLEARED##*:}" '
      type == "object" and (keys | sort) == ["live_execution_confirmation",
        "native_restart_confirmation","node30_probe_tool_sha256","nonce",
        "package_sha256sums_sha256","phase_b_result_sha256","schema","source_sha"] and
      .schema == 1 and .source_sha == $source and
      .phase_b_result_sha256 == $phase_b and .package_sha256sums_sha256 == $package and
      .node30_probe_tool_sha256 == $probe_tool and
      .live_execution_confirmation == $live and .native_restart_confirmation == $native and
      .nonce == $nonce and (.nonce | type == "string" and test("^[0-9a-f]{32}$"))
    ' "$file" >/dev/null
}
