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
        def expected_keys: ["automatic_recovery_unauthorized_continuously",
          "baseline_health_gate_passed","baseline_precondition_sha256",
          "baseline_cutover_stop_sha256","candidate_final_recovery_sha256",
          "candidate_final_resolution_txids_sha256",
          "candidate_locked_resolution_txids_sha256","candidate_locked_sync_sha256",
          "candidate_native_resolution_txids_unchanged","candidate_running",
          "candidate_source_sha","data_rewind_performed",
          "datasets_preserved","failure_policy","final_container_identity_stable",
          "final_container_sha256","final_envelope_sha256","invocation_sha256",
          "live_dataset_identity_sha256","marker_sha256","node","normal_unlock_completed",
          "no_new_fee_bearing_recovery_wallet_transaction",
          "old_core_autostarted","only_allowed_wallet_delta_classes_added","p2p_ready",
          "package_sha256sums_sha256","phase","phase_a_result_sha256",
          "phase_b_progress_sha256","phase_b_script_sha256",
          "phase_b_tooling_identity_sha256","pos_active","pos_explicitly_enabled",
          "pow_policy_restored","pre_result_manifest_sha256","promoted_no_rewind_marker_verified",
          "quantum_keys_unchanged","result","schema",
          "snapshots_absent_before_launch","storage_absence_recheck_sha256",
          "tooling_commit","typed_contract_sha256","typed_gate_safe","verifier_sha256",
          "wallet_chain_synchronized_before_unlock","wallet_delta_fully_classified",
          "wallet_delta_raw_sha256","wallet_delta_sha256"];
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
          .candidate_final_recovery_sha256,.candidate_final_resolution_txids_sha256,
          .candidate_locked_resolution_txids_sha256,.candidate_locked_sync_sha256,
          .final_container_sha256,.final_envelope_sha256,.invocation_sha256,
          .live_dataset_identity_sha256,.phase_b_progress_sha256,.pre_result_manifest_sha256,
          .storage_absence_recheck_sha256,.wallet_delta_raw_sha256,
          .wallet_delta_sha256][]; hex64) and
        .baseline_health_gate_passed == true and
        .snapshots_absent_before_launch == true and .datasets_preserved == true and
        .candidate_running == true and .wallet_chain_synchronized_before_unlock == true and
        .normal_unlock_completed == true and .pos_active == true and
        .pos_explicitly_enabled == true and .final_container_identity_stable == true and
        .pow_policy_restored == true and .p2p_ready == true and .typed_gate_safe == true and
        .quantum_keys_unchanged == true and
        .automatic_recovery_unauthorized_continuously == true and
        .candidate_native_resolution_txids_unchanged == true and
        .no_new_fee_bearing_recovery_wallet_transaction == true and
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
        def familyless_new_anchor_wait:
          .mining_gate_action == "wait_for_next_tip" and
          .mining_gate_can_submit == true and
          .mining_gate_unresolved_components == 0 and
          .mining_gate_live_claims == 0 and
          .mining_gate_eligible_claims == 0 and
          .mining_gate_family_claims == 0 and
          .mining_gate_relay_txid == $zero and
          .mining_gate_lineage_head_txid == $zero;
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
        (.payout_address | type == "string") and
        (.accrued_jackpot | amount) and (.next_claim_payout | amount) and
        (.next_claim_amount | uint) and (.claims_submitted | uint) and
        (.unresolved_claims | uint) and (.live_claims | uint) and
        (.quarantined_claims | uint) and (.raw_quarantined_claims | uint) and
        (.blocking_quarantined_claims | uint) and
        (.actionable_quarantined_claims | uint) and
        (.resolved_on_active_chain_claims | uint) and
        (.indeterminate_quarantined_claims | uint) and
        (.claim_components | uint) and
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
           .mining_gate_live_claims == 0 and
           .mining_gate_eligible_claims == 0 and
           .mining_gate_family_claims == 0
         elif familyless_new_anchor_wait then true
         else
           .mining_gate_lineage_head_txid != $zero and
           .mining_gate_unresolved_components >= 1 and
           .mining_gate_family_claims >= 1
         end) and
        (if .mining_gate_action == "relay_existing" then
           .mining_gate_relay_txid != $zero and
           .mining_gate_eligible_claims >= 1
         elif .mining_gate_action == "wait_for_live" then
           .mining_gate_relay_txid == $zero and .mining_gate_live_claims >= 1
         elif .mining_gate_action == "wait_for_next_tip" then
           (if .mining_gate_relay_txid == $zero
            then true
            else .mining_gate_can_submit == false and
              .mining_gate_eligible_claims >= 1 end)
         elif .mining_gate_action == "refresh_same_anchor" then
           .mining_gate_relay_txid == $zero
         else .mining_gate_relay_txid == $zero and
           .mining_gate_live_claims == 0 and .mining_gate_eligible_claims == 0 end)
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

v3015_claim_component_lineage_is_valid()
{
    local component=$1
    jq -e -n --argjson component "$component" '
      def integer: type == "number" and floor == .;
      def hex64: type == "string" and test("^[0-9a-f]{64}$");
      def zero: "0" * 64;
      def exact_proof_tuple($n):
        ($n.proof_version == 2 and $n.proof_origin_bound == false and
          $n.proof_input_bound == false) or
        ($n.proof_version == 3 and $n.proof_origin_bound == true and
          $n.proof_input_bound == false) or
        ($n.proof_version == 4 and $n.proof_origin_bound == true and
          $n.proof_input_bound == true);
      def exact_claim_descriptor($n):
        ($n | type == "object") and ($n.txid | hex64) and $n.txid != zero and
        $n.kind == "claim" and
        $n.provenance == "explicit_authored" and
        $n.expected_shape == true and $n.wallet_authored == true and
        $n.wallet_from_me == true and $n.authored_metadata_valid == true and
        $n.claim_descriptor_valid == true and
        $n.exact_authored_carrier_shape == true and $n.proof_mode == "pow" and
        ($n.proof_origin_height | integer and . >= 0) and
        ($n.proof_origin_previous_block_hash | hex64) and exact_proof_tuple($n) and
        ($n.lineage_ordinal | integer and . >= 0) and
        ($n.lineage_family_fingerprint | hex64) and
        ($n.lineage_root_txid | hex64) and ($n.lineage_parent_txid | hex64) and
        ($n.lineage_metadata_present | type == "boolean") and
        ($n.lineage_metadata_valid | type == "boolean");
      $component as $c |
      ($c | type == "object") and
      ($c.generation_fingerprint | hex64) and $c.generation_fingerprint != zero and
      ($c.claim_txids | type == "array" and length >= 1 and
        all(.[]; hex64) and . == (unique | sort)) and
      ($c.root_claim_txids | type == "array" and length >= 1 and
        all(.[]; hex64) and . == (unique | sort)) and
      all($c.root_claim_txids[]; . as $txid |
        ($c.claim_txids | index($txid)) != null) and
      ($c.descendant_claims | integer and . >= 0) and
      $c.descendant_claims ==
        (($c.claim_txids | length) - ($c.root_claim_txids | length)) and
      ($c.nodes | type == "array") and
      ([ $c.nodes[] | select(.kind == "claim") ] |
        sort_by([.lineage_ordinal,.txid])) as $claims |
      ($claims | length) == ($c.claim_txids | length) and
      ([ $claims[].txid ] | sort) == $c.claim_txids and
      all($claims[]; exact_claim_descriptor(.)) and
      ([ $claims[] | select(.lineage_metadata_present == false) ] +
       [ $claims[] | select(.lineage_metadata_present == true and
           .lineage_metadata_valid == true and .lineage_ordinal == 0) ]) as $roots |
      ($roots | length) == 1 and $roots[0] as $root |
      $claims[0] == $root and $root.lineage_ordinal == 0 and
      (if $root.lineage_metadata_present then
         $root.provenance == "explicit_authored" and
         $root.lineage_metadata_valid == true and
         $root.lineage_family_fingerprint == $c.generation_fingerprint and
         $root.lineage_root_txid == $root.txid and
         $root.lineage_parent_txid == zero
       else
         $root.provenance == "explicit_authored" and
         $root.lineage_metadata_valid == false and
         $root.lineage_family_fingerprint == zero and
         $root.lineage_root_txid == zero and $root.lineage_parent_txid == zero
       end) and
      all(range(1; ($claims | length)); . as $i |
        $claims[$i] as $node |
        $node.provenance == "explicit_authored" and
        $node.lineage_metadata_present == true and
        $node.lineage_metadata_valid == true and
        $node.lineage_family_fingerprint == $c.generation_fingerprint and
        $node.lineage_root_txid == $root.txid and
        $node.lineage_ordinal == $i and
        $node.lineage_parent_txid == $claims[$i-1].txid)
    ' >/dev/null
}

v3015_pow_series_is_live()
{
    local samples=$1 require_witness=${2:-false} sample
    [[ "$require_witness" == true || "$require_witness" == false ]] || return 1
    jq -e -n --argjson samples "$samples" --argjson require_witness "$require_witness" '
        def hex64: type == "string" and test("^[0-9a-f]{64}$");
        def integer: type == "number" and floor == .;
        def zero: "0" * 64;
        def component_keys: ["all_claims_expired_locally_retired",
          "all_claims_explicitly_provenanced","all_claims_quarantined",
          "all_claims_zero_payment_retirable","anchor","anchor_authenticated",
          "anchor_unspent","anchor_user_locked","claim_txids","classification","component_fingerprint",
          "descendant_claims","generation_fingerprint","has_revalidating_unbound_proof",
          "minimum_stale_depth","nodes","ordinary_or_mixed_txids",
          "resolution_txids","root_claim_txids","stale_depth_known"];
        def node_keys: ["abandoned","active_chain_confirmed","authored_metadata_valid",
          "authored_tip_active_branch_bound","claim_descriptor_valid","disposition",
          "exact_authored_carrier_shape","expected_shape","expired_locally_retired",
          "in_mempool","kind","lineage_family_fingerprint","lineage_metadata_present",
          "lineage_metadata_valid","lineage_ordinal","lineage_parent_txid",
          "lineage_root_txid","proof_evaluation_skipped_resolved_anchor",
          "proof_input_bound","proof_may_revalidate_on_descendant","proof_mode",
          "proof_origin_bound","proof_origin_height","proof_origin_previous_block_hash",
          "proof_version","provenance","quarantined","relay_expiry_time",
          "relay_ttl_expired","resolution_metadata_valid","resolution_relay_authorized",
          "stale_depth","stale_depth_known","txid","wallet_authored","wallet_from_me"];
        def freshness_keys: ["action","candidate_state_fingerprint","lineage_head_txid",
          "live_members","mempool_entry","mempool_entry_present","mempool_entry_time",
          "observed_unix_ms","raw_mempool",
          "recovery_component","recovery_component_claims",
          "recovery_component_claim_txids","recovery_component_root_claim_txids",
          "recovery_node","relay_txid","tip"];
        def live_member_keys: ["mempool_entry","mempool_entry_time","recovery_node"];
        def chain_cut_keys: ["bestblockhash","blocks","chainwork","headers",
          "initialblockdownload"];
        def qqp4_activation_keys: ["bestblock","height","qqp4_activation_disabled",
          "qqp4_activation_height","qqp4_active","qqp4_active_next_block"];
        def sample_keys: ["action_freshness","blocks","chain_after","chain_before",
          "headers","height","ibd","loaded_wallets","peers_out","pow",
          "qqp4_activation",
          "sample_finished_unix_ms","sample_started_unix_ms","staking","tip",
          "wallet_generation","wallet_normal_unlocked","wallet_processed_tip",
          "wallet_tip_matches","walletname"];
        def familyless_new_anchor_wait($s):
          $s.pow.mining_gate_action == "wait_for_next_tip" and
          $s.pow.mining_gate_can_submit == true and
          $s.pow.mining_gate_unresolved_components == 0 and
          $s.pow.mining_gate_live_claims == 0 and
          $s.pow.mining_gate_eligible_claims == 0 and
          $s.pow.mining_gate_family_claims == 0 and
          $s.pow.mining_gate_relay_txid == zero and
          $s.pow.mining_gate_lineage_head_txid == zero;
        def stable_chain_cut($s):
          ($s.chain_before | type == "object" and
            (keys | sort) == (chain_cut_keys | sort)) and
          ($s.chain_after | type == "object" and
            (keys | sort) == (chain_cut_keys | sort)) and
          $s.chain_before == $s.chain_after and
          ($s.chain_after.bestblockhash | hex64) and
          $s.chain_after.bestblockhash != zero and
          ($s.chain_after.chainwork | hex64) and $s.chain_after.chainwork != zero and
          ($s.chain_after.blocks | integer and . >= 0) and
          ($s.chain_after.headers | integer and . >= $s.chain_after.blocks) and
          $s.chain_after.initialblockdownload == false and
          $s.tip == $s.chain_after.bestblockhash and
          $s.height == $s.chain_after.blocks and $s.blocks == $s.chain_after.blocks and
          $s.headers == $s.chain_after.headers and
          $s.ibd == $s.chain_after.initialblockdownload;
        def qqp4_activation_receipt($s):
          $s.qqp4_activation as $q |
          ($q | type == "object" and
            (keys | sort) == (qqp4_activation_keys | sort)) and
          $q.bestblock == $s.tip and $q.height == $s.height and
          ($q.qqp4_activation_disabled | type == "boolean") and
          ($q.qqp4_activation_height | integer and . >= 0) and
          ($q.qqp4_active | type == "boolean") and
          ($q.qqp4_active_next_block | type == "boolean") and
          if $q.qqp4_activation_disabled then
            $q.qqp4_activation_height == 0 and
            $q.qqp4_active == false and $q.qqp4_active_next_block == false
          else
            $q.qqp4_activation_height > 0 and
            $q.qqp4_active == ($s.height >= $q.qqp4_activation_height) and
            $q.qqp4_active_next_block ==
              (($s.height + 1) >= $q.qqp4_activation_height)
          end;
        def node_shape($n):
          ($n | type == "object" and (keys | sort) == (node_keys | sort)) and
          ($n.txid | hex64) and $n.txid != zero and
          ($n.kind | IN("claim","managed_resolution","legacy_resolution","ordinary")) and
          ($n.provenance |
            IN("explicit_authored","explicit_adopted","legacy_wallet_authored","unknown")) and
          ($n.disposition | type == "string" and length > 0) and
          ($n.proof_mode | IN("pow","pos","unknown","malformed")) and
          ($n.proof_version | integer and . >= 0) and
          ($n.proof_origin_height | integer and . >= 0) and
          ($n.proof_origin_previous_block_hash | hex64) and
          ($n.relay_expiry_time | integer and . >= 0) and
          ($n.lineage_family_fingerprint | hex64) and
          ($n.lineage_root_txid | hex64) and ($n.lineage_parent_txid | hex64) and
          ($n.lineage_ordinal | integer and . >= 0) and
          ($n.stale_depth | integer and . >= 0) and
          all([$n.proof_may_revalidate_on_descendant,$n.active_chain_confirmed,
            $n.in_mempool,$n.quarantined,$n.expected_shape,$n.wallet_authored,
            $n.wallet_from_me,$n.authored_metadata_valid,
            $n.authored_tip_active_branch_bound,$n.claim_descriptor_valid,
            $n.proof_evaluation_skipped_resolved_anchor,$n.proof_origin_bound,
            $n.proof_input_bound,$n.exact_authored_carrier_shape,$n.relay_ttl_expired,
            $n.lineage_metadata_present,$n.lineage_metadata_valid,$n.abandoned,
            $n.expired_locally_retired,$n.stale_depth_known,
            $n.resolution_metadata_valid,$n.resolution_relay_authorized][];
            type == "boolean");
        def component_shape($c):
          ($c | type == "object" and (keys | sort) == (component_keys | sort)) and
          ($c.anchor | type == "object" and (keys | sort) ==
            ["amount","scriptPubKey","txid","vout"]) and
          ($c.anchor.txid | hex64) and $c.anchor.txid != zero and
          ($c.anchor.vout | integer and . >= 0) and
          ($c.anchor.amount | type == "number" and . > 0) and
          ($c.anchor.scriptPubKey | type == "string" and test("^([0-9a-f]{2})+$")) and
          ($c.generation_fingerprint | hex64) and $c.generation_fingerprint != zero and
          ($c.component_fingerprint | hex64) and
          ($c.classification | IN("live","transient","indeterminate",
            "current_branch_ineligible","terminal_on_pinned_tip","retired_on_active_branch",
            "resolution_pending","resolved_on_active_chain")) and
          all([$c.claim_txids,$c.root_claim_txids,$c.resolution_txids,
            $c.ordinary_or_mixed_txids][]; type == "array" and
            all(.[]; hex64) and . == (unique | sort)) and
          ($c.descendant_claims | integer and . >= 0) and
          ($c.minimum_stale_depth | integer and . >= 0) and
          all([$c.stale_depth_known,$c.anchor_authenticated,$c.anchor_unspent,
            $c.anchor_user_locked,
            $c.all_claims_quarantined,$c.all_claims_explicitly_provenanced,
            $c.all_claims_zero_payment_retirable,$c.all_claims_expired_locally_retired,
            $c.has_revalidating_unbound_proof][]; type == "boolean") and
          ($c.nodes | type == "array") and all($c.nodes[]; node_shape(.));
        def disposition_safe($n;$s):
          $n.in_mempool == true or $n.disposition == "eligible" or
          ($n.proof_version == 2 and
            $n.disposition == "unbound_proof_may_revalidate") or
          (($n.proof_version == 2 or $n.proof_version == 3) and
            $n.disposition == "unsupported_version" and
            $s.qqp4_activation.qqp4_active_next_block == true) or
          (($n.proof_version == 3 or $n.proof_version == 4) and
            ($n.disposition == "origin_mismatch" or
             $n.disposition == "origin_expired"));
        def component_authenticated($f;$s):
          $f != null and component_shape($f.recovery_component) and
          ($f.recovery_component as $c |
          ($f.raw_mempool | type == "object") and
          all($f.raw_mempool | to_entries[];
            (.key | hex64) and (.value | type == "object") and
            (.value.time | integer and . >= 0)) and
          ($f.recovery_component_claims | type == "array" and length >= 1) and
          $f.recovery_component_claims ==
            ([$c.nodes[] | select(.kind == "claim")] |
              sort_by([.lineage_ordinal,.txid])) and
          $f.recovery_component_claim_txids == $c.claim_txids and
          $f.recovery_component_root_claim_txids == $c.root_claim_txids and
          $c.anchor_authenticated == true and $c.anchor_unspent == true and
          (if $c.anchor_user_locked then
             $s.pow.mining_gate_action == "wait_for_next_tip" and
             $s.pow.mining_gate_relay_txid == zero and
             $s.pow.mining_gate_can_submit == false
           else true end) and
          $c.all_claims_explicitly_provenanced == true and
          ($c.classification |
            IN("live","current_branch_ineligible","terminal_on_pinned_tip")) and
          ($c.nodes | length) == ($c.claim_txids | length) and
          $c.root_claim_txids == $c.claim_txids and
          $c.descendant_claims == 0 and
          $c.ordinary_or_mixed_txids == [] and $c.resolution_txids == [] and
          ([ $c.nodes[].txid ] | sort) == $c.claim_txids and
          all($f.recovery_component_claims[]; .kind == "claim" and
            .active_chain_confirmed == false and
            (.abandoned == false or .expired_locally_retired == true) and
            .provenance == "explicit_authored" and .authored_metadata_valid == true and
            .expected_shape == true and .wallet_authored == true and
            .wallet_from_me == true and .claim_descriptor_valid == true and
            .exact_authored_carrier_shape == true and
            ((.proof_version == 2 and .proof_origin_bound == false and
                .proof_input_bound == false) or
             (.proof_version == 3 and .proof_origin_bound == true and
                .proof_input_bound == false) or
             (.proof_version == 4 and .proof_origin_bound == true and
                .proof_input_bound == true)) and
            .proof_evaluation_skipped_resolved_anchor == false and
            .proof_may_revalidate_on_descendant ==
              (.disposition == "unbound_proof_may_revalidate") and
            (.in_mempool == true or .quarantined == true) and
            .proof_mode == "pow" and disposition_safe(.;$s)) and
          all($f.recovery_component_claims[]; . as $node |
            ($f.raw_mempool | has($node.txid)) == $node.in_mempool) and
          ([ $f.recovery_component_claims[] | select(.in_mempool == true) ] |
            length) as $local_live |
          $local_live <= 1 and
          (if $s.pow.mining_gate_action == "wait_for_live" then
             $local_live >= 1
           elif $s.pow.mining_gate_action == "relay_existing" or
                $s.pow.mining_gate_action == "refresh_same_anchor" or
                ($s.pow.mining_gate_action == "wait_for_next_tip" and
                 $s.pow.mining_gate_relay_txid != zero) then
             $local_live == 0
           else true end) and
          (([ $f.recovery_component_claims[] |
             select(.lineage_metadata_present == false) ] +
           [ $f.recovery_component_claims[] |
             select(.lineage_metadata_present == true and
               .lineage_metadata_valid == true and .lineage_ordinal == 0) ]) as $roots |
          ($roots | length) == 1 and
          $roots[0] as $root |
          $root.lineage_ordinal == 0 and
          (if $root.lineage_metadata_present then
             $root.lineage_metadata_valid == true and
             $root.lineage_family_fingerprint == $c.generation_fingerprint and
             $root.lineage_root_txid == $root.txid and
             $root.lineage_parent_txid == zero
           else
             $root.lineage_metadata_valid == false and
             $root.lineage_family_fingerprint == zero and
             $root.lineage_root_txid == zero and
             $root.lineage_parent_txid == zero and
             (($root.proof_version == 2 and $root.proof_origin_bound == false and
                $root.proof_input_bound == false) or
              ($root.proof_version == 3 and $root.proof_origin_bound == true and
                $root.proof_input_bound == false) or
              ($root.proof_version == 4 and $root.proof_origin_bound == true and
                $root.proof_input_bound == true)) and
             (if $root.proof_version == 2 and
                 ($f.recovery_component_claims | length) == 1 then
                $root.authored_tip_active_branch_bound == true and
                ($root.disposition == "eligible" or
                 $root.disposition == "unbound_proof_may_revalidate" or
                 ($root.disposition == "unsupported_version" and
                  $s.qqp4_activation.qqp4_active_next_block == true))
              else true end)
           end) and
          $f.recovery_component_claims[0] == $root and
          all(range(1; ($f.recovery_component_claims | length)); . as $i |
            $f.recovery_component_claims[$i] as $node |
            $node.lineage_metadata_present == true and
            $node.lineage_metadata_valid == true and
            $node.lineage_family_fingerprint == $c.generation_fingerprint and
            $node.lineage_root_txid == $root.txid and
            $node.lineage_ordinal == $i and
            $node.lineage_parent_txid ==
              $f.recovery_component_claims[$i-1].txid) and
          $f.lineage_head_txid == $f.recovery_component_claims[-1].txid and
          ($f.recovery_component_claims | length) <=
            $s.pow.mining_gate_family_claims and
          ([ $f.recovery_component_claims[] | select(.in_mempool == true) ] |
            length) <= $s.pow.mining_gate_live_claims and
          ([ $f.recovery_component_claims[] |
            select(.disposition == "eligible") ] | length) <=
              $s.pow.mining_gate_eligible_claims));
        def authenticated($f;$s):
          component_authenticated($f;$s) and
          any($f.recovery_component_claims[]; . == $f.recovery_node);
        def relay_candidate($f):
          [$f.recovery_component_claims[] |
            select(.disposition == "eligible" and .in_mempool == false and
              .relay_ttl_expired == false)] |
          sort_by([.lineage_ordinal,.txid]) | last;
        def authenticated_member($f;$m;$s):
          ($m | type == "object" and (keys | sort) == (live_member_keys | sort)) and
          component_authenticated($f;$s) and node_shape($m.recovery_node) and
          $m.recovery_node.in_mempool == true and
          any($f.recovery_component_claims[]; . == $m.recovery_node) and
          $m.mempool_entry == $f.raw_mempool[$m.recovery_node.txid] and
          ($m.mempool_entry_time | integer and . >= 0) and
          $m.mempool_entry.time == $m.mempool_entry_time and
          (($m.mempool_entry_time * 1000) <= $f.observed_unix_ms);
        def immutable_claim_descriptor($n):
          {txid:$n.txid,kind:$n.kind,provenance:$n.provenance,
           expected_shape:$n.expected_shape,wallet_authored:$n.wallet_authored,
           wallet_from_me:$n.wallet_from_me,
           authored_metadata_valid:$n.authored_metadata_valid,
           authored_tip_active_branch_bound:$n.authored_tip_active_branch_bound,
           claim_descriptor_valid:$n.claim_descriptor_valid,
           proof_version:$n.proof_version,proof_mode:$n.proof_mode,
           proof_origin_bound:$n.proof_origin_bound,
           proof_origin_height:$n.proof_origin_height,
           proof_origin_previous_block_hash:$n.proof_origin_previous_block_hash,
           proof_input_bound:$n.proof_input_bound,
           exact_authored_carrier_shape:$n.exact_authored_carrier_shape,
           lineage_metadata_present:$n.lineage_metadata_present,
           lineage_metadata_valid:$n.lineage_metadata_valid,
           lineage_family_fingerprint:$n.lineage_family_fingerprint,
           lineage_root_txid:$n.lineage_root_txid,
           lineage_parent_txid:$n.lineage_parent_txid,
           lineage_ordinal:$n.lineage_ordinal};
        def same_authenticated_family($before;$after):
          $before != null and $after != null and
          $before.recovery_component.anchor == $after.recovery_component.anchor and
          $before.recovery_component.generation_fingerprint ==
            $after.recovery_component.generation_fingerprint and
          $before.recovery_component_claims[0].txid ==
            $after.recovery_component_claims[0].txid;
        def head_progress_at($series;$i):
          $series[$i].action_freshness as $after |
          authenticated($after;$series[$i]) and
          ([range(0;$i) as $prior |
            $series[$prior].action_freshness.recovery_component_claim_txids[]?] |
            index($after.lineage_head_txid)) == null and
          any(range(0;$i); . as $prior |
            $series[$prior].action_freshness as $before |
            authenticated($before;$series[$prior]) and
            same_authenticated_family($before;$after) and
            (([$before.recovery_component_claims[] |
                immutable_claim_descriptor(.)]) as $old |
             ([$after.recovery_component_claims[] |
                immutable_claim_descriptor(.)]) as $new |
             ($old | length) < ($new | length) and
             $old == $new[0:($old | length)] and
             $before.lineage_head_txid == $old[-1].txid and
             $after.lineage_head_txid == $new[-1].txid));
        def family_continuity($prior;$current):
          $prior.action_freshness as $before |
          $current.action_freshness as $after |
          if $before == null or $after == null then true
          elif [$before.recovery_component.anchor.txid,
                $before.recovery_component.anchor.vout] ==
               [$after.recovery_component.anchor.txid,
                $after.recovery_component.anchor.vout] then
            $before.recovery_component.anchor ==
              $after.recovery_component.anchor and
            $before.recovery_component_claims[0].txid ==
              $after.recovery_component_claims[0].txid and
            $before.recovery_component.generation_fingerprint ==
              $after.recovery_component.generation_fingerprint and
            (([$before.recovery_component_claims[] |
                immutable_claim_descriptor(.)]) as $old |
             ([$after.recovery_component_claims[] |
                immutable_claim_descriptor(.)]) as $new |
             ($old | length) <= ($new | length) and
             $old == $new[0:($old | length)] and
             (if $before.lineage_head_txid == $after.lineage_head_txid
              then $old == $new else ($new | length) > ($old | length) end))
          else true end;
        def live_progress_at($series;$i):
          $series[$i].action_freshness as $after |
          $after != null and
          any($after.live_members[]?; . as $member |
            authenticated_member($after;$member;$series[$i]) and
            ([range(0;$i) as $prior |
              $series[$prior].action_freshness.live_members[]?.recovery_node.txid] |
              index($member.recovery_node.txid)) == null and
            any(range(0;$i); . as $prior |
              $series[$prior].action_freshness as $before |
              authenticated($before;$series[$prior]) and
              same_authenticated_family($before;$after) and
              any($before.recovery_component_claims[]; . as $prior_member |
                $prior_member.in_mempool == false and
                immutable_claim_descriptor($prior_member) ==
                  immutable_claim_descriptor($member.recovery_node))));
        def operational_authority($s):
          {tip:$s.tip,height:$s.height,chainwork:$s.chain_after.chainwork,
           wallet_processed_tip:$s.wallet_processed_tip,
           qqp4_activation:$s.qqp4_activation,pow:$s.pow,
           action_freshness:
             (if $s.action_freshness == null then null
              else ($s.action_freshness |
                del(.observed_unix_ms,.candidate_state_fingerprint,
                  .raw_mempool)) end)} |
          .pow |= del(.mining_gate_candidate_state_fingerprint,
            .actionable_quarantined_claims,.blocking_quarantined_claims,
            .claim_components,.claims_auto_resolved,.claims_recycled,
            .cumulative_resolution_fees,.indeterminate_quarantined_claims,
            .live_claims,.pending_automatic_resolutions,
            .pending_manual_resolutions,.quarantined_claims,
            .raw_quarantined_claims,.resolved_on_active_chain_claims,
            .unresolved_claims);
        def collapse_operational_duplicates($series):
          reduce $series[] as $sample ([];
            if length == 0 or
               operational_authority(.[-1]) != operational_authority($sample)
            then . + [$sample] else . end);
        def chain_progress_at($series;$i):
          if $i == 0 then false else
            $series[$i].tip != $series[$i-1].tip
          end;
        def action_family_progress_at($series;$i):
          if $i == 0 then false else
            ($series[$i].pow.mining_gate_can_submit == true and
              ($series[$i].pow.mining_gate_action == "create_new_anchor" or
               $series[$i].pow.mining_gate_action == "refresh_same_anchor") and
              $series[$i].pow.hashrate > 0) or
            $series[$i].pow.claims_submitted >
              $series[$i-1].pow.claims_submitted or
            head_progress_at($series;$i) or live_progress_at($series;$i)
          end;
        def submit_action($s):
          $s.pow.mining_gate_can_submit == true and
          ($s.pow.mining_gate_action == "create_new_anchor" or
           $s.pow.mining_gate_action == "refresh_same_anchor");
        def submit_witness_at($series;$i):
          (submit_action($series[$i]) and $series[$i].pow.hashrate > 0) or
          ($i > 0 and
            ($series[$i].pow.claims_submitted >
               $series[$i-1].pow.claims_submitted or
             head_progress_at($series;$i) or live_progress_at($series;$i)));
        def zero_submit_transition($series;$i):
          submit_action($series[$i]) and
          $series[$i].pow.hashrate == 0 and
          (submit_witness_at($series;$i) | not);
        def submit_transitions_bounded($series):
          all(range(0; ($series | length)); . as $i |
            if zero_submit_transition($series;$i) then
              ([range(0; $i) as $prior |
                select(submit_witness_at($series;$prior) or
                  (submit_action($series[$prior]) | not)) |
                $prior] | last) as $prior_boundary |
              (($prior_boundary // -1) + 1) as $run_start |
              any(range($i + 1; ($series | length)); . as $j |
                (submit_witness_at($series;$j) or
                  (submit_action($series[$j]) | not)) and
                ($series[$j].sample_finished_unix_ms -
                  $series[$run_start].sample_started_unix_ms) <= 600000) or
              (submit_action($series[-1]) and
                ($series[-1].sample_finished_unix_ms -
                  $series[$run_start].sample_started_unix_ms) <= 600000)
            else true end);
        def terminal_submit_result($series):
          (($series | length) - 1) as $last |
          if submit_action($series[$last]) then
            if $series[$last].pow.hashrate > 0 then true
            else any(range(0; $last + 1); . as $i |
              submit_witness_at($series;$i) and
              ($series[$last].sample_finished_unix_ms -
                $series[$i].sample_started_unix_ms) <= 600000)
            end
          else true end;
        def bounded_wait_result($series):
          any(range(1; ($series | length)); . as $i |
            chain_progress_at($series;$i) or
            action_family_progress_at($series;$i));
        def familyless_wait_result($series):
          any(range(1; ($series | length)); . as $i |
            chain_progress_at($series;$i) or
            action_family_progress_at($series;$i));
        def freshness_ok:
          . as $s | $s.action_freshness as $f |
          if ($s.pow.mining_gate_action == "create_new_anchor" or
              familyless_new_anchor_wait($s)) then
            $f == null
          else
            ($f | type == "object" and (keys | sort) == (freshness_keys | sort)) and
            $f.action == $s.pow.mining_gate_action and $f.tip == $s.tip and
            $f.observed_unix_ms == $s.sample_finished_unix_ms and
            $f.candidate_state_fingerprint ==
              $s.pow.mining_gate_candidate_state_fingerprint and
            $f.lineage_head_txid == $s.pow.mining_gate_lineage_head_txid and
            $f.relay_txid == $s.pow.mining_gate_relay_txid and
            ($f.recovery_node | type == "object") and
            ($f.recovery_component_claims | type == "array" and length >= 1) and
            ($f.recovery_component_claim_txids | type == "array" and length >= 1) and
            all($f.recovery_component_claim_txids[]; hex64) and
            $f.recovery_component_claim_txids ==
              ($f.recovery_component_claim_txids | unique | sort) and
            ($f.recovery_component_root_claim_txids |
              type == "array" and length >= 1) and
            all($f.recovery_component_root_claim_txids[]; hex64) and
            ($f.recovery_component_claim_txids | index($f.lineage_head_txid)) != null and
            ($f.recovery_component_claim_txids | index($f.recovery_node.txid)) != null and
            ($f.mempool_entry_present | type == "boolean") and
            (($f.mempool_entry == null) or ($f.mempool_entry | type == "object")) and
            (($f.mempool_entry_time == null) or
              ($f.mempool_entry_time | integer and . >= 0)) and
            authenticated($f;$s) and
            ($f.live_members | type == "array") and
            ([ $f.recovery_component_claims[] |
               select(.in_mempool == true) ] | length) ==
              ($f.live_members | length) and
            [$f.live_members[].recovery_node.txid] ==
              ([$f.live_members[].recovery_node.txid] | sort) and
            ([$f.live_members[].recovery_node.txid] | unique | length) ==
              ($f.live_members | length) and
            [$f.live_members[].recovery_node] ==
              ([$f.recovery_component_claims[] |
                select(.in_mempool == true)] | sort_by(.txid)) and
            all($f.live_members[]; authenticated_member($f;.;$s)) and
            (if $f.action == "wait_for_live" then
               ($f.live_members | length) >= 1 and
               (($f.live_members |
                 sort_by([.recovery_node.lineage_ordinal,.recovery_node.txid]) |
                 last) as $selected |
                 $f.recovery_node == $selected.recovery_node and
                 $f.mempool_entry_present == true and
                 $f.mempool_entry == $selected.mempool_entry and
                 $f.mempool_entry_time == $selected.mempool_entry_time)
             elif $f.action == "refresh_same_anchor" then
               $f.live_members == [] and $f.relay_txid == zero and
               $f.recovery_node == $f.recovery_component_claims[-1] and
               $f.recovery_node.txid == $f.lineage_head_txid and
               $f.recovery_node.in_mempool == false and
               $f.mempool_entry_present == false and $f.mempool_entry == null and
               $f.mempool_entry_time == null
             elif $f.action == "relay_existing" then
               $f.live_members == [] and
               $f.relay_txid != zero and $f.recovery_node.txid == $f.relay_txid and
               $f.recovery_node.in_mempool == false and
               $f.recovery_node.disposition == "eligible" and
               $f.recovery_node.relay_ttl_expired == false and
               $f.mempool_entry_present == false and $f.mempool_entry == null and
               $f.mempool_entry_time == null and
               (($f.recovery_node.relay_expiry_time * 1000) > $f.observed_unix_ms)
             elif $f.action == "wait_for_next_tip" then
               $f.recovery_node.txid ==
                 (if $f.relay_txid != zero then $f.relay_txid else $f.lineage_head_txid end) and
               (if $f.relay_txid != zero then
                  $f.live_members == [] and
                  $f.recovery_node.in_mempool == false and
                  $f.mempool_entry_present == false and $f.mempool_entry == null and
                  $f.mempool_entry_time == null and
                  $f.recovery_node.disposition == "eligible" and
                  $f.recovery_node.relay_ttl_expired == false and
                  (($f.recovery_node.relay_expiry_time * 1000) > $f.observed_unix_ms)
                else
                  $f.lineage_head_txid != zero and
                  (if $f.recovery_node.in_mempool then
                     $f.mempool_entry_present == true and
                     $f.mempool_entry == $f.raw_mempool[$f.recovery_node.txid] and
                     ($f.mempool_entry_time | integer and . >= 0) and
                     $f.mempool_entry.time == $f.mempool_entry_time and
                     (($f.mempool_entry_time * 1000) <= $f.observed_unix_ms)
                   else
                     $f.mempool_entry_present == false and $f.mempool_entry == null and
                     $f.mempool_entry_time == null
                   end)
                end)
             else false end)
          end;
        $samples | type == "array" and length >= 4 and
        ([.[].tip] as $tips | all($tips[]; hex64) and
          ((reduce $tips[] as $tip ([];
            if length == 0 or .[-1] != $tip then . + [$tip] else . end)) as $cuts |
           ($cuts | unique | length) == ($cuts | length))) and
        all(range(1; ($samples | length)); . as $i |
          if $samples[$i].tip == $samples[$i-1].tip then
            $samples[$i].height == $samples[$i-1].height and
            $samples[$i].chain_after.chainwork ==
              $samples[$i-1].chain_after.chainwork
          else $samples[$i].height >= $samples[$i-1].height and
            $samples[$i].chain_after.chainwork >
              $samples[$i-1].chain_after.chainwork end) and
        all(.[]; . as $s | ($s | type == "object" and
            (keys | sort) == (sample_keys | sort)) and stable_chain_cut($s) and
          qqp4_activation_receipt($s) and
          ($s.sample_started_unix_ms | integer and . >= 0) and
          ($s.sample_finished_unix_ms | integer) and
          $s.sample_finished_unix_ms >= $s.sample_started_unix_ms and
          (.walletname | type == "string") and .loaded_wallets == [.walletname] and
          freshness_ok) and
        ((.[-1].sample_finished_unix_ms - .[0].sample_started_unix_ms) <= 1800000) and
        all(range(1; ($samples | length)); . as $i |
          $samples[$i].sample_started_unix_ms >=
            $samples[$i-1].sample_finished_unix_ms) and
        ([.[].walletname] | unique | length) == 1 and
        all(range(1; ($samples | length)); . as $i |
          ($samples[$i].qqp4_activation |
            {qqp4_activation_disabled,qqp4_activation_height}) ==
          ($samples[0].qqp4_activation |
            {qqp4_activation_disabled,qqp4_activation_height})) and
        all(.[].pow; type == "object") and
        all(.[]; .pow.current_height == .height and
          .pow.claim_inventory_tip == .tip and
          .pow.claim_inventory_wallet_tip_matches == true and
          .staking.blocks == .height and .staking.active_blocks == .height and
          (.wallet_generation | type == "number" and floor == . and . >= 0) and
          .wallet_processed_tip == .tip and .wallet_tip_matches == true) and
        all(range(1; ($samples | length)); . as $i |
          $samples[$i].pow.claims_submitted >=
            $samples[$i-1].pow.claims_submitted) and
        all(range(1; ($samples | length)); . as $i |
          $samples[$i].action_freshness as $current |
          if $current == null then true
          else
            ([range(0;$i) as $prior |
              select($samples[$prior].action_freshness != null and
                [$samples[$prior].action_freshness.recovery_component.anchor.txid,
                 $samples[$prior].action_freshness.recovery_component.anchor.vout] ==
                [$current.recovery_component.anchor.txid,
                 $current.recovery_component.anchor.vout]) |
              $prior] | last) as $prior |
            if $prior == null then true
            else family_continuity($samples[$prior];$samples[$i]) end
          end) and
        all(range(0; ($samples|length)); . as $start |
          all(range($start + 1; ($samples|length)); . as $finish |
            if ($samples[$finish].sample_finished_unix_ms -
                $samples[$start].sample_started_unix_ms) > 600000
            then any(range($start + 1; $finish + 1);
              chain_progress_at($samples;.))
            else true end)) and
        submit_transitions_bounded($samples) and
        (if $require_witness then
           terminal_submit_result($samples) and
           (if submit_action($samples[-1]) then true
            elif familyless_new_anchor_wait($samples[-1]) then
              familyless_wait_result($samples)
            else bounded_wait_result($samples) end)
         else true end)
    ' >/dev/null || return 1
    while IFS= read -r sample; do
        v3015_pow_json_is_typed_safe "$(jq -c '.pow' <<<"$sample")" || return 1
        v3015_pos_json_is_active "$(jq -c '.staking' <<<"$sample")" || return 1
        jq -e '.wallet_normal_unlocked == true and .ibd == false and
          .blocks == .headers and .peers_out >= 1' <<<"$sample" >/dev/null || return 1
    done < <(jq -c '.[]' <<<"$samples")
    while IFS= read -r component; do
        v3015_claim_component_lineage_is_valid "$component" || return 1
    done < <(jq -c '.[] | select(.action_freshness != null) |
      .action_freshness.recovery_component' <<<"$samples")
}

v3015_pow_series_is_complete()
{
    v3015_pow_series_is_live "$1" true
}

v3015_wallet_state_has_single_identity()
{
    local state=$1
    jq -e -n --argjson state "$state" '
      $state | type == "object" and (.wallet | type == "object") and
      (.wallet.walletname | type == "string") and
      (.loaded_wallets | type == "array") and
      .loaded_wallets == [.wallet.walletname]
    ' >/dev/null
}

v3015_raw_claim_tx_facts()
{
    local raw=$1
    [[ "$raw" =~ ^([0-9a-f]{2})+$ ]] || return 1
    V3015_RAW_HEX="$raw" python3 - <<'PY'
import hashlib
import json
import os
import struct

raw = bytes.fromhex(os.environ["V3015_RAW_HEX"])
if len(raw) < 10:
    raise SystemExit(1)
version = raw[:4]
pos = 4

def take(size):
    global pos
    if pos + size > len(raw):
        raise ValueError("truncated transaction")
    value = raw[pos:pos + size]
    pos += size
    return value

def compact_size():
    start = pos
    prefix = take(1)[0]
    if prefix < 253:
        return prefix, raw[start:pos]
    size = {253: 2, 254: 4, 255: 8}[prefix]
    value = int.from_bytes(take(size), "little")
    if value < {2: 253, 4: 65536, 8: 4294967296}[size]:
        raise ValueError("non-canonical compact size")
    return value, raw[start:pos]

try:
    has_witness = raw[pos:pos + 1] == b"\x00"
    if has_witness:
        take(1)
        if take(1) == b"\x00":
            raise ValueError("zero witness flag")
    vin_count, vin_count_bytes = compact_size()
    if vin_count != 1:
        raise ValueError("claim must have one input")
    vin_start = pos
    prev_txid = take(32)[::-1].hex()
    prev_vout = struct.unpack("<I", take(4))[0]
    script_size, _ = compact_size()
    take(script_size)
    sequence = struct.unpack("<I", take(4))[0]
    vin_bytes = raw[vin_start:pos]
    vout_count, vout_count_bytes = compact_size()
    if vout_count != 2:
        raise ValueError("claim must have two outputs")
    vout_start = pos
    outputs = []
    for _ in range(2):
        value = struct.unpack("<q", take(8))[0]
        output_script_size, _ = compact_size()
        script = take(output_script_size).hex()
        outputs.append({"value_sat": value, "script": script})
    vout_bytes = raw[vout_start:pos]
    if has_witness:
        for _ in range(vin_count):
            item_count, _ = compact_size()
            for _ in range(item_count):
                item_size, _ = compact_size()
                take(item_size)
    locktime = take(4)
    if pos != len(raw):
        raise ValueError("trailing transaction bytes")
    stripped = (version + vin_count_bytes + vin_bytes + vout_count_bytes +
        vout_bytes + locktime)
    txid = hashlib.sha256(hashlib.sha256(stripped).digest()).digest()[::-1].hex()
    print(json.dumps({"txid": txid, "vin0_txid": prev_txid,
        "vin0_vout": prev_vout, "vin0_sequence": sequence,
        "vout0_value_sat": outputs[0]["value_sat"],
        "vout0_script": outputs[0]["script"],
        "vout1_value_sat": outputs[1]["value_sat"],
        "vout1_script": outputs[1]["script"]}, separators=(",", ":")))
except (ValueError, IndexError, struct.error):
    raise SystemExit(1)
PY
}

v3015_txid_from_raw_hex()
{
    v3015_raw_claim_tx_facts "$1" | jq -er '.txid'
}

v3015_recovery_json_is_exact_safe()
{
    local recovery=$1
    jq -e -n --argjson recovery "$recovery" '
      def integer: type == "number" and floor == .;
      def uint: integer and . >= 0;
      def amount: type == "number" and . >= 0;
      def hex64: type == "string" and test("^[0-9a-f]{64}$");
      def zero: "0" * 64;
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
        "anchor_user_locked",
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
      def audit_only_foreign_component($c):
        $c.anchor_authenticated == false and
        $c.anchor_unspent == false and $c.anchor_user_locked == false and
        ($c.claim_txids | type == "array" and length >= 1) and
        ($c.nodes | type == "array" and
          any($c.nodes[]; .kind == "claim") and
          all($c.nodes[]; .provenance == "unknown" and
            .wallet_authored == false and .wallet_from_me == false));
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
      .raw_claim_objects >= .live_claim_objects and
      .raw_claim_objects >= .quarantined_claim_objects and
      (.confirmed_resolution_fees | amount) and (.automatic_fee_exposure_in_window | amount) and
      (.component_details | type == "array") and
      ([.component_details[].nodes[].txid] as $node_txids |
        ($node_txids | length) == ($node_txids | unique | length)) and
      all(.component_details[]; . as $component |
        type == "object" and (keys | sort) == (component_keys | sort) and
        (.anchor | type == "object" and (keys | sort) ==
          ["amount","scriptPubKey","txid","vout"]) and
        ((.anchor.txid | hex64) and (.anchor.vout | uint) and
          (.anchor.amount | amount) and
          (if audit_only_foreign_component($component) then
             ((.anchor.txid == zero and .anchor.vout == 4294967295) or
              (.anchor.txid != zero and .anchor.vout < 4294967295)) and
             .anchor.amount == 0 and .anchor.scriptPubKey == ""
           else
             .anchor.txid != zero and .anchor.vout < 4294967295 and
             .anchor.amount > 0 and
             (.anchor.scriptPubKey | type == "string" and test("^([0-9a-f]{2})+$"))
           end)) and
        (.generation_fingerprint | hex64) and (.component_fingerprint | hex64) and
        (.classification | IN("live","transient","indeterminate",
          "current_branch_ineligible","terminal_on_pinned_tip","retired_on_active_branch",
          "resolution_pending","resolved_on_active_chain")) and
        all([.claim_txids,.root_claim_txids,.resolution_txids,.ordinary_or_mixed_txids][];
          type == "array" and all(.[]; hex64) and (unique | length) == length) and
        (if (.claim_txids | length) == 0 then
           .root_claim_txids == [] and .descendant_claims == 0
         else
           (.root_claim_txids | length) >= 1 and
           all(.root_claim_txids[]; . as $txid |
             ($component.claim_txids | index($txid)) != null) and
           .descendant_claims ==
             ((.claim_txids | length) - (.root_claim_txids | length))
         end) and
        (.descendant_claims | uint) and (.minimum_stale_depth | uint) and
        all([.stale_depth_known,.anchor_authenticated,.anchor_unspent,
          .anchor_user_locked,
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
          (($component.claim_txids | index($node.lineage_root_txid)) != null) and
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
      (.unanchored_claim_txids | type == "array" and
        all(.[]; hex64) and (unique | length) == length) and
      all(.component_details[] | select(audit_only_foreign_component(.)); . as $component |
        all($component.claim_txids[]; . as $txid |
          ($recovery.unanchored_claim_txids | index($txid)) != null))
    ' >/dev/null
}

v3015_make_preunlock_migration_audit()
{
    local before=$1 after=$2
    jq -cn --argjson before "$before" --argjson after "$after" \
      '{before:$before,after:$after}'
}

v3015_preunlock_migration_is_safe()
{
    local json=$1 before after
    before=$(jq -ce '.before' <<<"$json") || return 1
    after=$(jq -ce '.after' <<<"$json") || return 1
    v3015_wallet_state_has_single_identity "$before" || return 1
    v3015_wallet_state_has_single_identity "$after" || return 1
    v3015_recovery_json_is_exact_safe "$(jq -c '.recovery' <<<"$after")" || return 1
    # The immutable v30.1.4 recovery payload remains deliberately opaque.  The
    # candidate side is exact-schema checked before allowing a receive-only
    # foreign audit row that arrived while the wallet remained locked.
    jq -e -n --argjson migration "$json" '
      def hex64: type == "string" and test("^[0-9a-f]{64}$");
      def integer: type == "number" and floor == .;
      def ids($s): [$s.transactions[].txid] | unique | sort;
      def state_keys: ["automatic_key_creation_allowed","chain","labeled_addresses",
        "loaded_wallets","payout","payout_address_info","quantum_inventory","recovery",
        "transaction_evidence","transactions","wallet"];
      def control_comment($x):
        (($x.comment // "") |
          IN("PoW Claim","Quantum PoW Claim",
            "Quantum Quasar built-in shadow PoW claim",
            "Blackcoin shadow PoW claim","PoS Claim","Quantum PoS Claim",
            "Quantum Quasar built-in shadow PoS claim",
            "Blackcoin shadow PoS claim"));
      def no_control_metadata($x):
        ([$x | keys[] | select(startswith("qq_shadow_pow_") or
          startswith("qq_synthetic_goldrush_"))] | length) == 0 and
        (control_comment($x) | not);
      def labeled_addresses_valid($s):
        ($s.labeled_addresses | type == "array") and
        $s.labeled_addresses == ($s.labeled_addresses |
          unique_by([.address,.label,.purpose]) | sort_by([.address,.label,.purpose])) and
        all($s.labeled_addresses[]; type == "object" and (keys | sort) ==
          ["address","label","purpose"] and (.address | type == "string" and length > 0) and
          (.label | type == "string") and (.purpose | type == "string"));
      def label_transition_safe($before;$after):
        def pair_ok($old;$new;$selected):
          $old.address == $new.address and $old.purpose == $new.purpose and
          ($old.label == $new.label or
           (($old.label | IN("Quantum PoW Reward Address","goldrush-pow")) and
            $new.label == "PoW - Quantum Claim Address" and
            $selected == $new.address));
        labeled_addresses_valid($before) and labeled_addresses_valid($after) and
        ($before.labeled_addresses | length) == ($after.labeled_addresses | length) and
        all($before.labeled_addresses[]; . as $old |
          ([ $after.labeled_addresses[] |
             select(pair_ok($old;.;$after.payout)) ] | length) == 1) and
        all($after.labeled_addresses[]; . as $new |
          ([ $before.labeled_addresses[] |
             select(pair_ok(.;$new;$after.payout)) ] | length) == 1);
      def quantum_inventory_transition_safe($before;$after):
        ($before.quantum_inventory | type == "object") and
        ($after.quantum_inventory | type == "object") and
        ($before.quantum_inventory.keys | type == "array") and
        ($after.quantum_inventory.keys | type == "array") and
        (($before.quantum_inventory | .keys |= map(del(.label))) ==
         ($after.quantum_inventory | .keys |= map(del(.label)))) and
        ($before.quantum_inventory.keys | length) ==
          ($after.quantum_inventory.keys | length) and
        all(range(0;($before.quantum_inventory.keys | length)); . as $i |
          ($before.quantum_inventory.keys[$i] as $old |
           $after.quantum_inventory.keys[$i] as $new |
           $old.label == $new.label or
           (($old.label | IN("Quantum PoW Reward Address","goldrush-pow")) and
            $new.label == "PoW - Quantum Claim Address" and
            $after.payout == $new.address)));
      def preexisting_quantum_address($before;$address):
        any($before.quantum_inventory.keys[]?;
          .address == $address and (.stored_in_wallet // true) == true);
      def payout_info_valid($s):
        ($s.payout | type == "string") and
        if $s.payout == "" then $s.payout_address_info == null
        else ($s.payout_address_info | type == "object") and
          $s.payout_address_info.address == $s.payout and
          $s.payout_address_info.ismine == true and
          ($s.payout_address_info.iswatchonly // false) == false and
          $s.payout_address_info.isquantummigration == true
        end;
      def payout_transition_safe($before;$after):
        $before.automatic_key_creation_allowed == false and
        $after.automatic_key_creation_allowed == false and
        label_transition_safe($before;$after) and
        quantum_inventory_transition_safe($before;$after) and
        payout_info_valid($before) and payout_info_valid($after) and
        ($after.payout == "" or
          preexisting_quantum_address($before;$after.payout));
      def audit_only_foreign_component($c):
        $c.anchor_authenticated == false and
        $c.anchor_unspent == false and $c.anchor_user_locked == false and
        ($c.claim_txids | type == "array" and length >= 1) and
        ($c.nodes | type == "array" and
          any($c.nodes[]; .kind == "claim") and
          all($c.nodes[]; .provenance == "unknown" and
            .wallet_authored == false and .wallet_from_me == false));
      def audit_only_foreign_receive($state;$txid):
        ([$state.transactions[] | select(.txid == $txid)]) as $rows |
        ([$state.recovery.component_details[] as $component |
          $component.nodes[] | select(.txid == $txid) |
          {component:$component,node:.}]) as $matches |
        $state.transaction_evidence[$txid] as $evidence |
        $evidence != null and ($evidence | type == "object" and (keys | sort) ==
          ["active_block","active_chain_hash","active_header","kind","transaction"]) and
        $evidence.kind == "base_transaction" and
        $evidence.transaction as $tx |
        ($tx | type == "object") and $tx.txid == $txid and
        ($tx.hex | type == "string" and test("^([0-9a-f]{2})+$")) and
        ($tx.decoded | type == "object") and $tx.decoded.txid == $txid and
        ($tx.decoded.vout | type == "array") and
        ($tx.details | type == "array" and length >= 1) and
        ($tx.amount | type == "number" and . > 0) and
        ($tx.confirmations | integer and . >= 0) and
        ($tx | has("fee") | not) and ($tx | has("generated") | not) and
        no_control_metadata($tx) and ($rows | length) >= 1 and
        all($rows[]; .category == "receive" and
          (.amount | type == "number" and . > 0) and
          (.confirmations | integer and . == $tx.confirmations) and
          (.abandoned // false) == false and (. | has("fee") | not) and
          (. | has("generated") | not) and
          no_control_metadata(.)) and
        all($tx.details[]; .category == "receive" and
          (.amount | type == "number" and . > 0) and
          (.abandoned // false) == false and (. | has("fee") | not) and
          (. | has("generated") | not) and
          no_control_metadata(.)) and
        (($matches | length) == 1 and
          audit_only_foreign_component($matches[0].component) and
          all($matches[0].component.claim_txids[]; . as $claim_txid |
            ($state.recovery.unanchored_claim_txids | index($claim_txid)) != null)) as
          $foreign_match |
        if $tx.confirmations == 0 then
          ($tx.blockhash? // "") == "" and
          ($tx | has("blockheight") | not) and ($tx | has("blockindex") | not) and
          $evidence.active_header == null and $evidence.active_block == null and
          $evidence.active_chain_hash == null and
          (($matches | length) == 0 or $foreign_match)
        else
          ($tx.blockhash | hex64) and
          ($tx.blockheight | integer and . >= 0 and . <= $state.chain.blocks) and
          ($tx.blockindex | integer and . >= 0) and
          ($evidence.active_header | type == "object") and
          $evidence.active_header.hash == $tx.blockhash and
          $evidence.active_header.height == $tx.blockheight and
          ($evidence.active_header.confirmations | integer and . > 0) and
          ($evidence.active_block | type == "object") and
          $evidence.active_block.hash == $tx.blockhash and
          $evidence.active_block.height == $tx.blockheight and
          ($evidence.active_block.confirmations | integer and . > 0) and
          ($evidence.active_block.tx | type == "array") and
          ($evidence.active_block.tx | index($txid)) != null and
          $evidence.active_chain_hash == $tx.blockhash and
          (($matches | length) == 0 or $foreign_match)
        end;
      $migration | type == "object" and (keys | sort) == ["after","before"] and
      (.before | type == "object" and (keys | sort) == (state_keys | sort)) and
      (.after | type == "object" and (keys | sort) == (state_keys | sort)) and
      (.before.transaction_evidence | type == "object") and
      (.after.transaction_evidence | type == "object") and
      (.before.recovery | type == "object") and
      all(.before.transactions[]; (.txid | hex64)) and
      all(.after.transactions[]; (.txid | hex64)) and
      (ids(.before) | length) == .before.wallet.txcount and
      (ids(.after) | length) == .after.wallet.txcount and
      (ids(.before) - ids(.after)) == [] and
      ((ids(.after) - ids(.before)) as $added |
        .after.wallet.txcount == (.before.wallet.txcount + ($added | length)) and
        all($added[]; . as $txid |
          audit_only_foreign_receive($migration.after;$txid))) and
      .before.wallet.walletname == .after.wallet.walletname and
      .before.loaded_wallets == .after.loaded_wallets and
      .before.wallet.private_keys_enabled == true and
      .after.wallet.private_keys_enabled == true and
      quantum_inventory_transition_safe(.before;.after) and
      .before.wallet.quantum_keys == .after.wallet.quantum_keys and
      .before.wallet.keypoolsize == .after.wallet.keypoolsize and
      (.before.wallet.keypoolsize_hd_internal // 0) ==
        (.after.wallet.keypoolsize_hd_internal // 0) and
      payout_transition_safe(.before;.after) and
      ((.after.wallet.unlocked_until // 0) == 0) and
      ((.after.wallet.unlocked_staking_only // false) == false)
    ' >/dev/null
}

v3015_make_wallet_audit()
{
    local before=$1 after=$2 txid raw facts component
    local raw_facts='{}' before_lineage_components='[]'
    while IFS= read -r component; do
        if v3015_claim_component_lineage_is_valid "$component"; then
            before_lineage_components=$(jq -cn \
              --argjson old "$before_lineage_components" \
              --argjson component "$component" '$old + [$component]') || return 1
        fi
    done < <(jq -c '.recovery.component_details[]?' <<<"$before")
    while IFS=$'\t' read -r txid raw; do
        [[ -n "$txid" && -n "$raw" ]] || continue
        facts=$(v3015_raw_claim_tx_facts "$raw" 2>/dev/null || printf 'null')
        raw_facts=$(jq -cn --argjson old "$raw_facts" --arg txid "$txid" \
          --argjson facts "$facts" '$old + {($txid):$facts}') || return 1
    done < <(jq -r --argjson before "$before" '
      ([ $before.transactions[].txid ] | unique) as $old |
      ([.transactions[].txid as $txid |
         select(($old | index($txid)) == null) |
         .transaction_evidence[$txid] as $evidence |
         select($evidence.kind == "base_transaction" and
           $evidence.transaction.qq_shadow_pow_authored == "1") |
         {txid:$txid,raw:$evidence.transaction.hex}] +
       [$before.transaction_evidence | to_entries[] |
         select(.value.kind == "base_transaction" and
           .value.transaction.qq_shadow_pow_authored == "1") |
         {txid:.key,raw:.value.transaction.hex}]) |
      unique_by(.txid)[] | [.txid,.raw] | @tsv' <<<"$after")
    jq -cn --argjson before "$before" --argjson after "$after" \
      --argjson raw_facts "$raw_facts" \
      --argjson before_lineage_components "$before_lineage_components" '
      def ids($s): [$s.transactions[].txid] | unique | sort;
      def integer: type == "number" and floor == .;
      def hex64: type == "string" and test("^[0-9a-f]{64}$");
      def control_comment($x):
        (($x.comment // "") |
          IN("PoW Claim","Quantum PoW Claim",
            "Quantum Quasar built-in shadow PoW claim",
            "Blackcoin shadow PoW claim","PoS Claim","Quantum PoS Claim",
            "Quantum Quasar built-in shadow PoS claim",
            "Blackcoin shadow PoS claim"));
      def no_control_metadata($x):
        ([$x | keys[] | select(startswith("qq_shadow_pow_") or
          startswith("qq_synthetic_goldrush_"))] | length) == 0 and
        (control_comment($x) | not);
      def resolution_ids($r): [$r.component_details[]?.resolution_txids[]?] | unique | sort;
      def ordinary_ids($r): [$r.component_details[]?.ordinary_or_mixed_txids[]?] | unique | sort;
      def audit_only_foreign_component($c):
        $c.anchor_authenticated == false and
        $c.anchor_unspent == false and $c.anchor_user_locked == false and
        ($c.claim_txids | type == "array" and length >= 1) and
        ($c.nodes | type == "array" and
          any($c.nodes[]; .kind == "claim") and
          all($c.nodes[]; .provenance == "unknown" and
            .wallet_authored == false and .wallet_from_me == false));
      def safe_external_receive($state;$txid;$rows;$matches):
        $state.transaction_evidence[$txid] as $evidence |
        $evidence != null and ($evidence | type == "object" and (keys | sort) ==
          ["active_block","active_chain_hash","active_header","kind","transaction"]) and
        $evidence.kind == "base_transaction" and
        $evidence.transaction as $tx |
        ($tx | type == "object") and $tx.txid == $txid and
        ($tx.hex | type == "string" and test("^([0-9a-f]{2})+$")) and
        ($tx.decoded | type == "object") and $tx.decoded.txid == $txid and
        ($tx.decoded.vout | type == "array") and
        ($tx.details | type == "array" and length >= 1) and
        ($tx.amount | type == "number" and . > 0) and
        ($tx.confirmations | integer and . >= 0) and
        ($tx | has("fee") | not) and ($tx | has("generated") | not) and
        no_control_metadata($tx) and ($rows | length) >= 1 and
        all($rows[]; .category == "receive" and
          (.amount | type == "number" and . > 0) and
          (.confirmations | integer and . == $tx.confirmations) and
          (.abandoned // false) == false and (. | has("fee") | not) and
          (. | has("generated") | not) and no_control_metadata(.)) and
        all($tx.details[]; .category == "receive" and
          (.amount | type == "number" and . > 0) and
          (.abandoned // false) == false and (. | has("fee") | not) and
          (. | has("generated") | not) and
          no_control_metadata(.)) and
        (($matches | length) == 1 and
          audit_only_foreign_component($matches[0].component) and
          all($matches[0].component.claim_txids[]; . as $claim_txid |
            ($state.recovery.unanchored_claim_txids | index($claim_txid)) != null)) as
          $foreign_match |
        if $tx.confirmations == 0 then
          ($tx.blockhash? // "") == "" and
          ($tx | has("blockheight") | not) and ($tx | has("blockindex") | not) and
          $evidence.active_header == null and $evidence.active_block == null and
          $evidence.active_chain_hash == null and
          (($matches | length) == 0 or $foreign_match)
        else
          ($tx.blockhash | hex64) and
          ($tx.blockheight | integer and . >= 0 and . <= $state.chain.blocks) and
          ($tx.blockindex | integer and . >= 0) and
          ($evidence.active_header | type == "object") and
          $evidence.active_header.hash == $tx.blockhash and
          $evidence.active_header.height == $tx.blockheight and
          ($evidence.active_header.confirmations | integer and . > 0) and
          ($evidence.active_block | type == "object") and
          $evidence.active_block.hash == $tx.blockhash and
          $evidence.active_block.height == $tx.blockheight and
          ($evidence.active_block.confirmations | integer and . > 0) and
          ($evidence.active_block.tx | type == "array") and
          ($evidence.active_block.tx | index($txid)) != null and
          $evidence.active_chain_hash == $tx.blockhash and
          (($matches | length) == 0 or $foreign_match)
        end;
      def no_recovery_or_resolution_metadata($x):
        ([$x | keys[] | select(
          . == "qq_shadow_pow_cleanup_for" or
          . == "qq_shadow_pow_legacy_cleanup_quarantine" or
          . == "qq_auto_shadow_stale" or
          . == "qq_manual_shadow_abandon" or
          . == "qq_reorg_shadow_resubmit" or
          startswith("qq_shadow_pow_resolution_") or
          . == "qq_shadow_pow_adopted" or
          startswith("qq_shadow_pow_adoption_") or
          startswith("qq_shadow_pow_expired_retired") or
          startswith("qq_synthetic_goldrush_"))] | length) == 0;
      def uint_string($x):
        ($x | type == "string" and test("^(0|[1-9][0-9]*)$") and
          (tonumber | floor == . and . >= 0 and . <= 4294967295));
      def reverse_hex_bytes($h):
        [range(0; ($h | length); 2) | $h[.:.+2]] | reverse | join("");
      def nibble($c): "0123456789abcdef" | index($c);
      def byte($h;$p):
        (nibble($h[$p:$p+1]) * 16) + nibble($h[$p+1:$p+2]);
      def le16($h;$p): byte($h;$p) + (256 * byte($h;$p+2));
      def le32($h;$p):
        byte($h;$p) + (256 * byte($h;$p+2)) +
        (65536 * byte($h;$p+4)) + (16777216 * byte($h;$p+6));
      def proof_payload($data):
        select(($data | type) == "string" and
          ($data | test("^[0-9a-f]+$")) and (($data | length) % 2) == 0 and
          ($data | startswith("51515350524f4f46")) and
          ($data | length) >= 50) |
        ($data[16:24]) as $magic |
        (if $magic == "51515032" then
           {version:2,origin_bound:false,input_bound:false,header:42}
         elif $magic == "51515033" then
           {version:3,origin_bound:true,input_bound:false,header:114}
         elif $magic == "51515034" then
           {version:4,origin_bound:true,input_bound:true,header:186}
         else empty end) as $shape |
        select($data[24:26] == "00" and
          ($data | length) >= ($shape.header + 8)) |
        le16($data;$shape.header) as $target_size |
        ($shape.header + 4 + (2 * $target_size)) as $payout_header |
        select($target_size > 0 and
          ($data | length) >= ($payout_header + 4)) |
        le16($data;$payout_header) as $payout_size |
        select($payout_size > 0 and
          ($data | length) == ($payout_header + 4 + (2 * $payout_size)) and
          ($data[$payout_header+4:($data | length)] |
            test("^6020[0-9a-f]{64}$")) and
          (if $shape.origin_bound then
             $data[42:50] != "00000000" and
             $data[50:114] != ("0"*64)
           else true end) and
          (if $shape.input_bound then
             $data[114:178] != ("0"*64) or $data[178:186] != "ffffffff"
           else true end)) |
        $shape + {data:$data,
          target:$data[$shape.header+4:$payout_header],
          payout:$data[$payout_header+4:($data | length)],
          origin_height:(if $shape.origin_bound then le32($data;42) else null end),
          origin_previous_block_hash:(if $shape.origin_bound then
            reverse_hex_bytes($data[50:114]) else null end),
          claim_txid:(if $shape.input_bound then
            reverse_hex_bytes($data[114:178]) else null end),
          claim_vout:(if $shape.input_bound then le32($data;178) else null end)};
      def op_return_payload($script):
        select(($script | type) == "string" and
          ($script | test("^[0-9a-f]+$")) and (($script | length) % 2) == 0 and
          ($script | startswith("6a")) and ($script | length) >= 4) |
        byte($script;2) as $opcode |
        (if $opcode >= 1 and $opcode <= 75 then
           {header:4,size:$opcode}
         elif $opcode == 76 and ($script | length) >= 6 then
           {header:6,size:byte($script;4)}
         elif $opcode == 77 and ($script | length) >= 8 then
           {header:8,size:le16($script;4)}
         else empty end) as $push |
        select(($script | length) == ($push.header + (2 * $push.size))) |
        $script[$push.header:($script | length)];
      def exact_claim_carrier($tx;$created_height;$created_tip):
        $raw_facts[$tx.txid] as $raw |
        select(($raw | type) == "object" and $raw.txid == $tx.txid and
          $raw.vin0_txid == $tx.decoded.vin[0].txid and
          $raw.vin0_vout == $tx.decoded.vin[0].vout and
          $raw.vin0_sequence == $tx.decoded.vin[0].sequence and
          $raw.vout0_value_sat > 0 and $raw.vout1_value_sat == 0 and
          (($tx.decoded.vout[0].value * 100000000) | round) ==
            $raw.vout0_value_sat and
          (($tx.decoded.vout[1].value * 100000000) | round) ==
            $raw.vout1_value_sat and
          $raw.vout0_script == $tx.decoded.vout[0].scriptPubKey.hex and
          $raw.vout1_script == $tx.decoded.vout[1].scriptPubKey.hex) |
        select(($tx.decoded.vin | length) == 1 and
          ($tx.decoded.vin[0].txid | hex64) and
          ($tx.decoded.vin[0].vout | integer and . >= 0 and . < 4294967295) and
          $tx.decoded.vin[0].sequence == 4294967293 and
          ($tx.decoded.vout | length) == 2 and
          $tx.decoded.vout[0].n == 0 and
          ($tx.decoded.vout[0].value | type) == "number" and
          $tx.decoded.vout[0].value > 0 and
          ($tx.decoded.vout[0].scriptPubKey.hex | type) == "string" and
          ($tx.decoded.vout[0].scriptPubKey.hex | test("^([0-9a-f]{2})+$")) and
          ($tx.decoded.vout[0].scriptPubKey.hex | startswith("6a") | not) and
          ($tx.decoded.vout[0].scriptPubKey.type // "") != "nulldata" and
          $tx.decoded.vout[1].n == 1 and
          $tx.decoded.vout[1].value == 0 and
          $tx.decoded.vout[1].scriptPubKey.type == "nulldata") |
        $tx.decoded.vout[1].scriptPubKey.hex as $script |
        op_return_payload($script) as $payload |
        ([$tx.decoded.vout[1] |
          (.scriptPubKey.asm // "") as $asm |
          ($asm | split(" ")) as $ops |
          select(($ops | length) == 2 and $ops[0] == "OP_RETURN") |
          select($ops[1] == $payload) |
          proof_payload($payload)] ) as $carriers |
        select(($carriers | length) == 1) | $carriers[0] as $carrier |
        select($tx.decoded.vout[0].scriptPubKey.hex == $carrier.target and
          (if $carrier.origin_bound then
             $carrier.origin_height == $created_height and
             $carrier.origin_previous_block_hash == $created_tip
           else true end) and
          (if $carrier.input_bound then
             $tx.decoded.vin[0].txid == $carrier.claim_txid and
             $tx.decoded.vin[0].vout == $carrier.claim_vout
           else true end)) | $carrier;
      def exact_claim_lineage($tx;$txid):
        (["qq_shadow_pow_lineage_schema","qq_shadow_pow_lineage_family",
          "qq_shadow_pow_lineage_root","qq_shadow_pow_lineage_parent",
          "qq_shadow_pow_lineage_ordinal"] |
          map(. as $key | select($tx | has($key)))) as $present |
        if ($present | sort) ==
            (["qq_shadow_pow_lineage_schema","qq_shadow_pow_lineage_family",
              "qq_shadow_pow_lineage_root","qq_shadow_pow_lineage_ordinal"] | sort) or
             ($present | sort) ==
            (["qq_shadow_pow_lineage_schema","qq_shadow_pow_lineage_family",
              "qq_shadow_pow_lineage_root","qq_shadow_pow_lineage_parent",
              "qq_shadow_pow_lineage_ordinal"] | sort) then
          select($tx.qq_shadow_pow_lineage_schema == "1" and
            ($tx.qq_shadow_pow_lineage_family | hex64) and
            $tx.qq_shadow_pow_lineage_family != ("0"*64) and
            ($tx.qq_shadow_pow_lineage_root | hex64) and
            $tx.qq_shadow_pow_lineage_root != ("0"*64) and
            uint_string($tx.qq_shadow_pow_lineage_ordinal)) |
          ($tx.qq_shadow_pow_lineage_ordinal | tonumber) as $ordinal |
          select(if $ordinal == 0 then
             $tx.qq_shadow_pow_lineage_root == $txid and
             ($tx | has("qq_shadow_pow_lineage_parent") | not)
           else
             $tx.qq_shadow_pow_lineage_root != $txid and
             ($tx.qq_shadow_pow_lineage_parent | hex64) and
             $tx.qq_shadow_pow_lineage_parent != ("0"*64) and
             $tx.qq_shadow_pow_lineage_parent != $txid
           end) |
          {family:$tx.qq_shadow_pow_lineage_family,
            root:$tx.qq_shadow_pow_lineage_root,
            parent:($tx.qq_shadow_pow_lineage_parent // null),ordinal:$ordinal}
        else empty end;
      def no_lineage_metadata($x):
        (["qq_shadow_pow_lineage_schema","qq_shadow_pow_lineage_family",
          "qq_shadow_pow_lineage_root","qq_shadow_pow_lineage_parent",
          "qq_shadow_pow_lineage_ordinal"] |
          all(.[]; . as $key | ($x | has($key) | not)));
      def authored_claim_row($row):
        $row.category == "send" and $row.amount == 0 and
        ($row.fee | type) == "number" and $row.fee < 0 and
        ($row.comment // "") == "PoW Claim" and
        $row.qq_shadow_pow_authored == "1" and
        uint_string($row.qq_shadow_pow_created_height) and
        ($row.qq_shadow_pow_created_tip | hex64) and
        $row.qq_shadow_pow_created_tip != ("0"*64) and
        ($row.abandoned // false) == false and
        no_recovery_or_resolution_metadata($row);
      def prior_row_matches_node($row;$node;$lineage):
        authored_claim_row($row) and
        if $node.lineage_metadata_present then
          $row.qq_shadow_pow_lineage_schema == "1" and
          $row.qq_shadow_pow_lineage_family == $lineage.family and
          $row.qq_shadow_pow_lineage_root == $lineage.root and
          uint_string($row.qq_shadow_pow_lineage_ordinal) and
          ($row.qq_shadow_pow_lineage_ordinal | tonumber) ==
            $node.lineage_ordinal and
          (if $node.lineage_ordinal == 0 then
             ($row | has("qq_shadow_pow_lineage_parent") | not)
           else
             $row.qq_shadow_pow_lineage_parent == $node.lineage_parent_txid
           end)
        else no_lineage_metadata($row) end;
      def preserved_prior_claim_carrier($txid):
        $before.transaction_evidence[$txid] as $evidence |
        select(($evidence | type) == "object" and
          $evidence.kind == "base_transaction") |
        $evidence.transaction as $tx |
        select(($tx | type) == "object" and $tx.txid == $txid and
          ($tx.hex | type) == "string" and
          ($tx.hex | test("^([0-9a-f]{2})+$")) and
          $raw_facts[$txid].txid == $txid and
          ($tx.decoded | type) == "object" and
          $tx.decoded.txid == $txid and
          $tx.qq_shadow_pow_authored == "1" and
          uint_string($tx.qq_shadow_pow_created_height) and
          ($tx.qq_shadow_pow_created_tip | hex64) and
          $tx.qq_shadow_pow_created_tip != ("0"*64) and
          no_recovery_or_resolution_metadata($tx)) |
        ($tx.qq_shadow_pow_created_height | tonumber) as $created_height |
        exact_claim_carrier($tx;$created_height;
          $tx.qq_shadow_pow_created_tip);
      def authenticated_implicit_root($root;$lineage):
        $root.txid as $root_txid |
        $before.transaction_evidence[$root_txid] as $evidence |
        ([ $before.transactions[] | select(.txid == $root_txid) ]) as $before_rows |
        ([ $after.transactions[] | select(.txid == $root_txid) ]) as $after_rows |
        select(($evidence | type) == "object" and
          ($evidence | keys | sort) ==
            (["active_block","active_chain_hash","active_header","kind",
              "transaction"] | sort) and
          $evidence.kind == "base_transaction" and
          $evidence.active_header == null and $evidence.active_block == null and
          $evidence.active_chain_hash == null) |
        $evidence.transaction as $tx |
        select(($tx | type) == "object" and $tx.txid == $root_txid and
          ($tx.hex | type) == "string" and
          ($tx.hex | test("^([0-9a-f]{2})+$")) and
          $raw_facts[$root_txid].txid == $root_txid and
          ($tx.decoded | type) == "object" and
          $tx.decoded.txid == $root_txid and
          ($tx.decoded.vin | type) == "array" and
          ($tx.decoded.vout | type) == "array" and
          $tx.qq_shadow_pow_authored == "1" and
          uint_string($tx.qq_shadow_pow_created_height) and
          ($tx.qq_shadow_pow_created_tip | hex64) and
          $tx.qq_shadow_pow_created_tip != ("0"*64) and
          no_lineage_metadata($tx) and
          no_recovery_or_resolution_metadata($tx) and
          ($tx.confirmations | integer and . <= 0) and
          ($tx | has("blockhash") | not) and
          ($tx | has("blockheight") | not) and
          ($tx | has("blockindex") | not) and
          ($tx.amount | type) == "number" and $tx.amount == 0 and
          ($tx.fee | type) == "number" and $tx.fee < 0 and
          ($tx | has("generated") | not) and
          ($tx.details | type) == "array" and ($tx.details | length) >= 1 and
          all($tx.details[]; .category == "send" and .amount == 0 and
            (.fee | type) == "number" and .fee < 0 and
            (.abandoned // false) == false and (. | has("generated") | not))) |
        ($tx.qq_shadow_pow_created_height | tonumber) as $created_height |
        exact_claim_carrier($tx;$created_height;
          $tx.qq_shadow_pow_created_tip) as $carrier |
        select(($before_rows | length) >= 1 and ($after_rows | length) >= 1 and
          all($before_rows[]; prior_row_matches_node(.;$root;$lineage)) and
          all($after_rows[]; prior_row_matches_node(.;$root;$lineage)) and
          $root.kind == "claim" and $root.txid == $lineage.root and
          $root.provenance == "explicit_authored" and
          $root.expected_shape == true and $root.wallet_authored == true and
          $root.wallet_from_me == true and $root.authored_metadata_valid == true and
          $root.authored_tip_active_branch_bound == true and
          $root.claim_descriptor_valid == true and
          $root.exact_authored_carrier_shape == true and
          $root.active_chain_confirmed == false and $root.quarantined == true and
          $root.proof_mode == "pow" and
          $root.proof_version == $carrier.version and
          $root.proof_origin_bound == $carrier.origin_bound and
          $root.proof_input_bound == $carrier.input_bound and
          (if $carrier.origin_bound then
             $root.proof_origin_height == $carrier.origin_height and
             $root.proof_origin_previous_block_hash ==
               $carrier.origin_previous_block_hash
           else true end) and
          $root.lineage_metadata_present == false and
          $root.lineage_metadata_valid == false and
          $root.lineage_family_fingerprint == ("0"*64) and
          $root.lineage_root_txid == ("0"*64) and
          $root.lineage_parent_txid == ("0"*64) and
          $root.lineage_ordinal == 0) | true;
      def canonical_lineage_rows($state;$txid;$lineage;$carrier):
        if $lineage.ordinal == 0 then
          ([ $state.transactions[] |
             select(.txid == $txid and
               prior_row_matches_node(.;
                 {lineage_metadata_present:true,lineage_ordinal:0,
                  lineage_parent_txid:("0"*64)};$lineage)) ] | length) >= 1
        else
          ([ $before_lineage_components[] as $component |
             select($component.anchor_authenticated == true and
               $component.anchor_unspent == true and
               $component.all_claims_explicitly_provenanced == true and
               $component.generation_fingerprint == $lineage.family and
               $component.ordinary_or_mixed_txids == [] and
               $component.resolution_txids == [] and
               ($component.root_claim_txids | index($lineage.root)) != null) |
             ([ $component.nodes[] | select(.kind == "claim") ] |
               sort_by([.lineage_ordinal,.txid])) as $claims |
             select(($claims | length) == $lineage.ordinal and
               $claims[0].txid == $lineage.root and
               $claims[-1].txid == $lineage.parent and
               all($claims[]; . as $node |
                 ([ $before.transactions[] | select(.txid == $node.txid) ] |
                   length) >= 1 and
                 all($before.transactions[] |
                   select(.txid == $node.txid);
                   prior_row_matches_node(.;$node;$lineage)) and
                 ([ $state.transactions[] | select(.txid == $node.txid) ] |
                   length) >= 1 and
                 all($state.transactions[] |
                   select(.txid == $node.txid);
                   prior_row_matches_node(.;$node;$lineage)) and
                 ([preserved_prior_claim_carrier($node.txid)] as $carriers |
                   ($carriers | length) == 1 and
                   $carriers[0].target == $carrier.target and
                   $carriers[0].payout == $carrier.payout))) |
             select(if $claims[0].lineage_metadata_present then true
               else authenticated_implicit_root($claims[0];$lineage) end) |
             $component] | length) == 1
        end;
      def confirmed_wallet_authored_claim($state;$txid;$rows;$matches):
        $state.transaction_evidence[$txid] as $evidence |
        select(($matches | length) == 0 and
          ($state.wallet | type) == "object" and
          $state.wallet.private_keys_enabled == true and
          $state.loaded_wallets == [$state.wallet.walletname] and
          ($evidence | type) == "object" and
          ($evidence | keys | sort) ==
            (["active_block","active_chain_hash","active_header",
              "created_tip_active_chain_hash","created_tip_header",
              "kind","transaction"] | sort) and
          $evidence.kind == "base_transaction") |
        $evidence.transaction as $tx |
        select(($tx | type) == "object" and $tx.txid == $txid and
          ($tx.hex | type) == "string" and ($tx.hex | test("^([0-9a-f]{2})+$")) and
          $raw_facts[$txid].txid == $txid and
          ($tx.decoded | type) == "object" and $tx.decoded.txid == $txid and
          ($tx.decoded.vin | type) == "array" and
          ($tx.decoded.vout | type) == "array" and
          $tx.qq_shadow_pow_authored == "1" and
          uint_string($tx.qq_shadow_pow_created_height) and
          ($tx.qq_shadow_pow_created_tip | hex64) and
          $tx.qq_shadow_pow_created_tip != ("0"*64) and
          no_recovery_or_resolution_metadata($tx) and
          ($tx.confirmations | integer and . > 0) and
          ($tx.blockhash | hex64) and
          ($tx.blockheight | integer and . > 0) and
          ($tx.blockindex | integer and . >= 0) and
          ($tx.amount | type) == "number" and $tx.amount == 0 and
          ($tx.fee | type) == "number" and $tx.fee < 0 and
          ($tx | has("generated") | not) and
          ($tx.details | type) == "array" and ($tx.details | length) >= 1 and
          all($tx.details[]; .category == "send" and .amount == 0 and
            (.fee | type) == "number" and .fee < 0 and
            (.abandoned // false) == false and (. | has("generated") | not))) |
        ($tx.qq_shadow_pow_created_height | tonumber) as $created_height |
        exact_claim_lineage($tx;$txid) as $lineage |
        exact_claim_carrier($tx;$created_height;$tx.qq_shadow_pow_created_tip) as $carrier |
        canonical_lineage_rows($state;$txid;$lineage;$carrier) as $canonical_lineage |
        select($canonical_lineage and
          $created_height > 0 and $created_height <= $tx.blockheight and
          (if $carrier.origin_bound then
             ($tx.blockheight - $created_height) <= 64
           else true end) and
          $tx.confirmations == ($state.chain.blocks - $tx.blockheight + 1) and
          ($evidence.active_header | type) == "object" and
          $evidence.active_header.hash == $tx.blockhash and
          $evidence.active_header.height == $tx.blockheight and
          $evidence.active_header.confirmations == $tx.confirmations and
          (if $tx.blockheight == $created_height then
             $evidence.active_header.previousblockhash ==
               $tx.qq_shadow_pow_created_tip
           else true end) and
          ($evidence.active_block | type) == "object" and
          $evidence.active_block.hash == $tx.blockhash and
          $evidence.active_block.height == $tx.blockheight and
          $evidence.active_block.confirmations == $tx.confirmations and
          ($evidence.active_block.tx | type) == "array" and
          $evidence.active_block.tx[$tx.blockindex] == $txid and
          $evidence.active_chain_hash == $tx.blockhash and
          ($evidence.created_tip_header | type) == "object" and
          $evidence.created_tip_header.hash == $tx.qq_shadow_pow_created_tip and
          $evidence.created_tip_header.height == ($created_height - 1) and
          $evidence.created_tip_header.confirmations ==
            ($state.chain.blocks - $created_height + 2) and
          $evidence.created_tip_active_chain_hash == $tx.qq_shadow_pow_created_tip and
          ($rows | length) >= 1 and
          all($rows[]; .txid == $txid and .category == "send" and
            .amount == 0 and (.fee | type) == "number" and .fee < 0 and
            (.confirmations | integer and . == $tx.confirmations) and
            .blockhash == $tx.blockhash and (.abandoned // false) == false and
            (.comment // "") == "PoW Claim" and
            .qq_shadow_pow_authored == "1" and
            .qq_shadow_pow_created_height == $tx.qq_shadow_pow_created_height and
            .qq_shadow_pow_created_tip == $tx.qq_shadow_pow_created_tip and
            no_recovery_or_resolution_metadata(.) and
            .qq_shadow_pow_lineage_schema == $tx.qq_shadow_pow_lineage_schema and
            .qq_shadow_pow_lineage_family == $tx.qq_shadow_pow_lineage_family and
            .qq_shadow_pow_lineage_root == $tx.qq_shadow_pow_lineage_root and
            .qq_shadow_pow_lineage_ordinal == $tx.qq_shadow_pow_lineage_ordinal and
            (.qq_shadow_pow_lineage_parent // null) ==
              ($tx.qq_shadow_pow_lineage_parent // null))) |
        {lineage:$lineage,carrier:$carrier};
      def safe_synthetic_payout($after;$txid;$rows):
        $after.transaction_evidence[$txid] as $evidence |
        $evidence != null and ($evidence | type == "object" and (keys | sort) ==
          ["active_block","active_chain_hash","active_header","kind",
           "shadow_transaction","source_transaction"]) and
        $evidence.kind == "synthetic_payout" and
        $evidence.shadow_transaction as $shadow |
        $shadow.schema == "blackcoin.shadow.transaction.v1" and
        $shadow.synthetic == true and $shadow.merkle_included == false and
        $shadow.synthetic_txid == $txid and $shadow.mode == "pow" and
        ($shadow.vout | integer and . >= 0) and
        ($shadow.confirmations | integer and . > 0) and
        ($shadow.nominal_amount | type == "number" and . > 0) and
        ($shadow.scriptPubKey | type == "string" and
          test("^([0-9a-f]{2})+$")) and
        ($shadow.address | type == "string" and length > 0) and
        (($shadow.status == "spent" and $shadow.lifecycle_category == "spent" and
          $shadow.valuation_status == "recorded_at_spend" and
          ($shadow.spend | type == "object" and (keys | sort) ==
            ["blockhash","height","input_index","tx_index","txid"]) and
          ($shadow.spend.blockhash | hex64) and ($shadow.spend.txid | hex64) and
          ($shadow.spend.height | integer and . >= 0 and . <= $after.chain.blocks) and
          ($shadow.spend.tx_index | integer and . >= 0) and
          ($shadow.spend.input_index | integer and . >= 0)) or
         ((($shadow.status == "immature" and
              $shadow.lifecycle_category == "gold_rush_synthetic_immature") or
            ($shadow.status == "gold_rush_locked" and
              $shadow.lifecycle_category == "gold_rush_synthetic_mature_locked") or
            ($shadow.status == "demurrage_locked" and
              $shadow.lifecycle_category == "demurrage_locked") or
            ($shadow.status == "unspent" and
              $shadow.lifecycle_category == "migration_spendable_direct_quantum")) and
          $shadow.valuation_status == "current_next_block_consensus" and
          $shadow.spend == null)) and
        ($shadow.base_anchor | type == "object") and
        ($shadow.base_anchor.blockhash | hex64) and
        ($shadow.base_anchor.height | integer and . >= 0 and . <= $after.chain.blocks) and
        ($shadow.base_anchor.time | integer and . > 0) and
        ($shadow.base_anchor.claim_index | integer and . >= 0) and
        $shadow.confirmations ==
          ($after.chain.blocks - $shadow.base_anchor.height + 1) and
        ($evidence.active_header | type == "object") and
        $evidence.active_header.hash == $shadow.base_anchor.blockhash and
        $evidence.active_header.height == $shadow.base_anchor.height and
        $evidence.active_header.confirmations == $shadow.confirmations and
        ($evidence.active_block | type == "object") and
        $evidence.active_block.hash == $shadow.base_anchor.blockhash and
        $evidence.active_block.height == $shadow.base_anchor.height and
        $evidence.active_block.confirmations == $shadow.confirmations and
        ($evidence.active_block.tx | type == "array") and
        $evidence.active_chain_hash == $shadow.base_anchor.blockhash and
        ($rows | length) >= 1 and
        all($rows[]; .qq_synthetic_goldrush_payout == "1" and
          (.qq_synthetic_goldrush_payout_stale? // "") == "" and
          .category == (if $shadow.status == "immature" then "immature"
            else "generate" end) and .amount == $shadow.nominal_amount and
          .address == $shadow.address and
          (.confirmations | integer and . == $shadow.confirmations) and
          .blockhash == $shadow.base_anchor.blockhash and
          (.abandoned // false) == false and (. | has("fee") | not)) and
        $shadow.pow_claim_source as $source |
        ($source | type == "object" and (keys | sort) ==
          ["base_fee","base_fee_known","canonical_rank","claim_outpoint",
           "disposition","inclusion_height","input_bound","logical_proof_id",
           "origin_age","origin_bound","origin_height",
           "origin_previous_block_hash","proof_version","txid","vout"]) and
        ($source.txid | hex64) and
        ($source.vout | integer and . >= 0) and
        ($source.logical_proof_id | hex64) and
        ($source.canonical_rank | hex64) and
        ($source.disposition |
          IN("winner","reimbursed_loser","reimbursed_late")) and
        $source.base_fee_known == true and
        ($source.base_fee | type == "number" and . >= 0) and
        ($source.inclusion_height | integer and . == $shadow.base_anchor.height) and
        (($source.proof_version == 2 and $source.origin_bound == false and
            $source.input_bound == false and $source.claim_outpoint == null and
            $source.origin_previous_block_hash == null and
            ($source.origin_height | integer and . >= 0) and $source.origin_age == 0) or
         ($source.proof_version == 3 and $source.origin_bound == true and
            $source.input_bound == false and $source.claim_outpoint == null and
            ($source.origin_height | integer and . > 0) and
            ($source.origin_previous_block_hash | hex64) and
            $source.origin_age == ($source.inclusion_height - $source.origin_height)) or
         ($source.proof_version == 4 and $source.origin_bound == true and
            $source.input_bound == true and
            ($source.origin_height | integer and . > 0) and
            ($source.origin_previous_block_hash | hex64) and
            $source.origin_age == ($source.inclusion_height - $source.origin_height) and
            ($source.claim_outpoint | type == "object" and (keys | sort) ==
              ["txid","vout"]) and ($source.claim_outpoint.txid | hex64) and
            ($source.claim_outpoint.vout | integer and . >= 0))) and
        $evidence.source_transaction as $raw |
        ($raw | type == "object") and $raw.txid == $source.txid and
        $raw.blockhash == $shadow.base_anchor.blockhash and
        ($raw.hex | type == "string" and test("^([0-9a-f]{2})+$")) and
        ($raw.vin | type == "array") and ($raw.vout | type == "array") and
        ($raw.vout | length) > $source.vout and
        (($raw.vout[$source.vout].scriptPubKey.asm // "") as $asm |
          ($asm | split(" ")) as $ops |
          ($ops | length) == 2 and $ops[0] == "OP_RETURN" and
          ($ops[1] | startswith("51515350524f4f46" +
            (if $source.proof_version == 2 then "51515032"
             elif $source.proof_version == 3 then "51515033"
             else "51515034" end)))) and
        ($evidence.active_block.tx | index($source.txid)) != null and
        (if $source.proof_version == 4 then
           any($raw.vin[]; .txid == $source.claim_outpoint.txid and
             .vout == $source.claim_outpoint.vout)
         else true end);
      def classify($txid):
        ([$after.transactions[] | select(.txid == $txid)]) as $rows |
        ([$after.recovery.component_details[] as $component |
          $component.nodes[] | select(.txid == $txid) |
          {component:$component,node:.}]) as $matches |
        safe_synthetic_payout($after;$txid;$rows) as $synthetic |
        ([$rows[] | select(.category == "generate" and (.blockhash // "") != "" and
          (.qq_synthetic_goldrush_payout // "0") != "1")] | length > 0) as $coinstake |
        ($matches | length == 1 and
          $matches[0].component.anchor_authenticated == true and
          $matches[0].component.all_claims_explicitly_provenanced == true and
          $matches[0].node.provenance == "explicit_authored" and
          $matches[0].node.expected_shape == true and
          $matches[0].node.wallet_authored == true and $matches[0].node.wallet_from_me == true and
          $matches[0].node.authored_metadata_valid == true and
          $matches[0].node.claim_descriptor_valid == true and
          $matches[0].node.exact_authored_carrier_shape == true and
          $matches[0].node.proof_mode == "pow" and
          (($matches[0].node.proof_version == 2 and
              $matches[0].node.proof_origin_bound == false and
              $matches[0].node.proof_input_bound == false) or
           ($matches[0].node.proof_version == 3 and
              $matches[0].node.proof_origin_bound == true and
              $matches[0].node.proof_input_bound == false) or
           ($matches[0].node.proof_version == 4 and
              $matches[0].node.proof_origin_bound == true and
              $matches[0].node.proof_input_bound == true)) and
          $matches[0].node.lineage_metadata_present == true and
          $matches[0].node.lineage_metadata_valid == true and
          $matches[0].node.lineage_family_fingerprint ==
            $matches[0].component.generation_fingerprint and
          $matches[0].node.lineage_root_txid != ("0"*64) and
          ($matches[0].component.claim_txids | index($txid)) != null and
          ($matches[0].component.resolution_txids | index($txid)) == null and
          ($matches[0].component.ordinary_or_mixed_txids | index($txid)) == null and
          all($rows[]; (.qq_synthetic_goldrush_payout // "0") != "1")) as
          $recovery_claim |
        ([confirmed_wallet_authored_claim($after;$txid;$rows;$matches)] |
          length == 1) as $confirmed_authored_claim |
        ($recovery_claim or $confirmed_authored_claim) as $claim |
        ($recovery_claim and $matches[0].node.expired_locally_retired == true) as
          $claim_abandonment_permitted |
        safe_external_receive($after;$txid;$rows;$matches) as $external |
        {txid:$txid,authenticated_same_anchor_claim:$claim,
          authenticated_claim_abandonment_permitted:$claim_abandonment_permitted,
          safe_external_receive:$external,normal_coinstake:$coinstake,
          authenticated_synthetic_payout:$synthetic,
          exactly_one_allowed_class:(([$claim,$external,$coinstake,$synthetic] |
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
        component_resolution_txids_before:resolution_ids($before.recovery),
        component_resolution_txids_after:resolution_ids($after.recovery),
        ordinary_or_mixed_txids_before:ordinary_ids($before.recovery),
        ordinary_or_mixed_txids_after:ordinary_ids($after.recovery),
        transactions:[$added[] | classify(.)]}}
    '
}

v3015_wallet_delta_is_safe()
{
    local json=$1 before after expected component
    before=$(jq -ce '.before' <<<"$json") || return 1
    after=$(jq -ce '.after' <<<"$json") || return 1
    v3015_wallet_state_has_single_identity "$before" || return 1
    v3015_wallet_state_has_single_identity "$after" || return 1
    v3015_recovery_json_is_exact_safe "$(jq -c '.recovery' <<<"$before")" || return 1
    v3015_recovery_json_is_exact_safe "$(jq -c '.recovery' <<<"$after")" || return 1
    expected=$(v3015_make_wallet_audit "$before" "$after") || return 1
    jq -e -n --argjson audit "$json" --argjson expected "$expected" '
      def hex64: type == "string" and test("^[0-9a-f]{64}$");
      def ids($s): [$s.transactions[].txid] | unique | sort;
      def state_keys: ["automatic_key_creation_allowed","chain","labeled_addresses",
        "loaded_wallets","payout","payout_address_info","quantum_inventory","recovery",
        "transaction_evidence","transactions","wallet"];
      def labeled_addresses_valid($s):
        ($s.labeled_addresses | type == "array") and
        $s.labeled_addresses == ($s.labeled_addresses |
          unique_by([.address,.label,.purpose]) | sort_by([.address,.label,.purpose])) and
        all($s.labeled_addresses[]; type == "object" and (keys | sort) ==
          ["address","label","purpose"] and (.address | type == "string" and length > 0) and
          (.label | type == "string") and (.purpose | type == "string"));
      def label_transition_safe($before;$after):
        def pair_ok($old;$new;$selected):
          $old.address == $new.address and $old.purpose == $new.purpose and
          ($old.label == $new.label or
           (($old.label | IN("Quantum PoW Reward Address","goldrush-pow")) and
            $new.label == "PoW - Quantum Claim Address" and
            $selected == $new.address));
        labeled_addresses_valid($before) and labeled_addresses_valid($after) and
        ($before.labeled_addresses | length) == ($after.labeled_addresses | length) and
        all($before.labeled_addresses[]; . as $old |
          ([ $after.labeled_addresses[] |
             select(pair_ok($old;.;$after.payout)) ] | length) == 1) and
        all($after.labeled_addresses[]; . as $new |
          ([ $before.labeled_addresses[] |
             select(pair_ok(.;$new;$after.payout)) ] | length) == 1);
      def quantum_inventory_transition_safe($before;$after):
        ($before.quantum_inventory | type == "object") and
        ($after.quantum_inventory | type == "object") and
        ($before.quantum_inventory.keys | type == "array") and
        ($after.quantum_inventory.keys | type == "array") and
        (($before.quantum_inventory | .keys |= map(del(.label))) ==
         ($after.quantum_inventory | .keys |= map(del(.label)))) and
        ($before.quantum_inventory.keys | length) ==
          ($after.quantum_inventory.keys | length) and
        all(range(0;($before.quantum_inventory.keys | length)); . as $i |
          ($before.quantum_inventory.keys[$i] as $old |
           $after.quantum_inventory.keys[$i] as $new |
           $old.label == $new.label or
           (($old.label | IN("Quantum PoW Reward Address","goldrush-pow")) and
            $new.label == "PoW - Quantum Claim Address" and
            $after.payout == $new.address)));
      def preexisting_quantum_address($before;$address):
        any($before.quantum_inventory.keys[]?;
          .address == $address and (.stored_in_wallet // true) == true);
      def payout_info_valid($s):
        ($s.payout | type == "string") and
        if $s.payout == "" then $s.payout_address_info == null
        else ($s.payout_address_info | type == "object") and
          $s.payout_address_info.address == $s.payout and
          $s.payout_address_info.ismine == true and
          ($s.payout_address_info.iswatchonly // false) == false and
          $s.payout_address_info.isquantummigration == true
        end;
      def payout_transition_safe($before;$after):
        $before.automatic_key_creation_allowed == false and
        $after.automatic_key_creation_allowed == false and
        label_transition_safe($before;$after) and
        quantum_inventory_transition_safe($before;$after) and
        payout_info_valid($before) and payout_info_valid($after) and
        ($after.payout == "" or
          preexisting_quantum_address($before;$after.payout));
      def resolution_ids($r): [$r.component_details[]?.resolution_txids[]?] | unique | sort;
      def ordinary_ids($r): [$r.component_details[]?.ordinary_or_mixed_txids[]?] | unique | sort;
      $audit == $expected and
      ($audit |
      (type == "object" and (keys | sort) == ["after","before","delta"]) and
      (.before | type == "object" and (keys | sort) == (state_keys | sort)) and
      (.after | type == "object" and (keys | sort) == (state_keys | sort)) and
      (.before.transaction_evidence | type == "object") and
      (.after.transaction_evidence | type == "object") and
      all((.before.transaction_evidence | keys)[]; hex64) and
      all((.after.transaction_evidence | keys)[]; hex64) and
      (.delta | type == "object" and (keys | sort) ==
        ["added_txids","component_resolution_txids_after",
         "component_resolution_txids_before","ordinary_or_mixed_txids_after",
         "ordinary_or_mixed_txids_before","removed_txids",
         "transaction_count_after","transaction_count_before",
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
      .before.wallet.walletname == .after.wallet.walletname and
      .before.loaded_wallets == .after.loaded_wallets and
      .before.wallet.private_keys_enabled == true and .after.wallet.private_keys_enabled == true and
      quantum_inventory_transition_safe(.before;.after) and
      .before.wallet.quantum_keys == .after.wallet.quantum_keys and
      .before.wallet.keypoolsize == .after.wallet.keypoolsize and
      (.before.wallet.keypoolsize_hd_internal // 0) ==
        (.after.wallet.keypoolsize_hd_internal // 0) and
      payout_transition_safe(.before;.after) and
      .after.recovery.wallet_generation >= .before.recovery.wallet_generation and
      .after.recovery.wallet_processed_tip == .after.chain.bestblockhash and
      .after.recovery.wallet_tip_matches == true and
      .delta.component_resolution_txids_before == resolution_ids(.before.recovery) and
      .delta.component_resolution_txids_after == resolution_ids(.after.recovery) and
      all(($audit.delta.component_resolution_txids_after -
        $audit.delta.component_resolution_txids_before)[]; . as $txid |
        ($audit.delta.added_txids | index($txid)) == null and
        (ids($audit.before) | index($txid)) != null) and
      .delta.ordinary_or_mixed_txids_before == ordinary_ids(.before.recovery) and
      .delta.ordinary_or_mixed_txids_after == ordinary_ids(.after.recovery) and
      all(($audit.delta.ordinary_or_mixed_txids_after -
        $audit.delta.ordinary_or_mixed_txids_before)[]; . as $txid |
        ($audit.delta.added_txids | index($txid)) == null and
        (ids($audit.before) | index($txid)) != null) and
      all(.delta.transactions[]; .exactly_one_allowed_class == true and
        (.per_tx_abandoned == false or
          (.authenticated_same_anchor_claim == true and
           .authenticated_claim_abandonment_permitted == true)) and
        .cleanup == false and .recovery == false and
        .resolution == false and .recovery_fee == 0))
    ' >/dev/null || return 1
    while IFS= read -r component; do
        v3015_claim_component_lineage_is_valid "$component" || return 1
    done < <(jq -c '. as $audit |
      [$audit.delta.transactions[] |
        select(.authenticated_same_anchor_claim == true) | .txid] as $added_claims |
      $audit.after.recovery.component_details[] |
      select(.claim_txids as $ids |
        any($ids[]; . as $txid | ($added_claims | index($txid)) != null))' <<<"$json")
}

v3015_node_result_is_valid()
{
    local file=$1 expected_node=$2 authority_file=$3 expected_nonce authority_sha
    [[ "$expected_node" =~ ^([1-9]|[12][0-9]|3[12])$ && "$expected_node" != 30 ]] || return 1
    v3015_rollout_authority_is_valid "$authority_file" || return 1
    expected_nonce=$(jq -er '.nonce' "$authority_file") || return 1
    authority_sha=$(v3015_sha256_file "$authority_file") || return 1
    jq -e --argjson node "$expected_node" --arg source "$SOURCE_SHA" \
      --arg image "$CANDIDATE_IMAGE_REF" --arg image_id "$CANDIDATE_IMAGE_ID" \
      --arg nonce "$expected_nonce" --arg authority "$authority_sha" '
        type == "object" and (keys | sort) == (["container_recreated",
          "container_id_after_recreate","container_id_before","containment_only_on_failure",
          "data_rewind_used","invocation","locked_restart",
          "network_version","node","normal_unlock_only","repair_rpcs","restart_performed",
          "preunlock_migration","rollout_authority_sha256","rollout_nonce","samples",
          "schema","source_sha","subversion",
          "wallet_audit"] | sort) and
        (.invocation | type == "object" and (keys | sort) ==
          ["candidate_image_id","candidate_image_ref","config_cmd",
           "entrypoint_body_sha256","runtime_argv_sha256"]) and
        .schema == 1 and .node == $node and .source_sha == $source and
        .rollout_nonce == $nonce and .rollout_authority_sha256 == $authority and
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
    v3015_pow_series_is_complete "$(jq -c '.samples' "$file")" || return 1
    v3015_preunlock_migration_is_safe \
      "$(jq -c '.preunlock_migration' "$file")" || return 1
    v3015_wallet_delta_is_safe "$(jq -c '.wallet_audit' "$file")" || return 1
    jq -e '.preunlock_migration.after == .wallet_audit.before and
      (.preunlock_migration.before.wallet.walletname) as $name |
      all(.samples[]; .walletname == $name and .loaded_wallets == [$name])' \
      "$file" >/dev/null
}

v3015_node30_probe_samples_are_live()
{
    local samples=$1 observation=$2 tool=$3 source=$4 image=$5 image_id=$6 nonce=$7
    local started=$8 finished=$9 sample
    jq -e -n --argjson samples "$samples" --arg observation "$observation" \
      --arg tool "$tool" --arg source "$source" --arg image "$image" \
      --arg image_id "$image_id" --arg nonce "$nonce" \
      --argjson started "$started" --argjson finished "$finished" '
      def integer: type == "number" and floor == .;
      def hex64: type == "string" and test("^[0-9a-f]{64}$");
      def core_keys: ["bestblockhash","blocks","headers","initialblockdownload"];
      def sample_keys: ["blocks","candidate_image_id","candidate_image_ref","core_after",
        "core_before","free_claim_healthy","free_claim_paused","headers","height","ibd",
        "loaded_wallets","observation","peers_out","pos","probe_tool_sha256",
        "regular_pow","rollout_nonce","sample_finished_unix_ms","sample_index",
        "sample_started_unix_ms","source_sha","tip","wallet_normal_unlocked","walletname"];
      $samples | type == "array" and length >= 4 and length <= 16 and
      all(to_entries[]; (.value | type == "object" and
        (keys | sort) == (sample_keys | sort)) and .value.sample_index == .key) and
      all(range(0;($samples|length)); . as $i | $samples[$i].sample_index == $i) and
      all(.[]; . as $s | $s.observation == $observation and $s.probe_tool_sha256 == $tool and
        $s.source_sha == $source and $s.candidate_image_ref == $image and
        $s.candidate_image_id == $image_id and $s.rollout_nonce == $nonce and
        ($s.sample_started_unix_ms | integer and . >= $started) and
        ($s.sample_finished_unix_ms | integer) and
        $s.sample_finished_unix_ms >= $s.sample_started_unix_ms and
        $s.sample_finished_unix_ms <= $finished and
        ($s.core_before | type == "object" and (keys | sort) == core_keys) and
        ($s.core_after | type == "object" and (keys | sort) == core_keys) and
        $s.core_before == $s.core_after and ($s.tip | hex64) and
        $s.tip == $s.core_after.bestblockhash and
        ($s.height | integer and . >= 0) and $s.height == $s.core_after.blocks and
        $s.blocks == $s.height and $s.headers == $s.core_after.headers and
        $s.ibd == $s.core_after.initialblockdownload and $s.ibd == false and
        $s.blocks == $s.headers and ($s.peers_out | integer and . >= 1) and
        ($s.walletname | type == "string") and $s.loaded_wallets == [$s.walletname] and
        $s.wallet_normal_unlocked == true and $s.free_claim_healthy == true and
        $s.free_claim_paused == false and $s.pos.blocks == $s.height and
        $s.pos.active_blocks == $s.height and
        ($s.regular_pow | type == "object" and (keys | sort) ==
          ["enabled","hashrate","state"]) and $s.regular_pow.enabled == false and
        $s.regular_pow.hashrate == 0 and $s.regular_pow.state == "disabled") and
      ([.[].tip] as $tips | all($tips[]; hex64) and
        (($tips | unique | length) == ($tips | length))) and
      ([.[].height] as $heights |
        all(range(1;($heights|length)); $heights[.] > $heights[.-1])) and
      all(range(1;($samples|length)); . as $i |
        $samples[$i].sample_started_unix_ms >=
          $samples[$i-1].sample_finished_unix_ms) and
      ([.[].walletname] | unique | length) == 1
    ' >/dev/null || return 1
    while IFS= read -r sample; do
        v3015_pos_json_is_active "$(jq -c '.pos' <<<"$sample")" || return 1
    done < <(jq -c '.[]' <<<"$samples")
}

v3015_node30_probe_output_is_valid()
{
    local file=$1 expected_observation=$2 expected_nonce
    [[ "$expected_observation" == initial || "$expected_observation" == terminal ]] || return 1
    [[ -f "$file" && ! -L "$file" ]] || return 1
    expected_nonce=${LIVE_EXECUTION_CLEARED##*:}
    [[ "$expected_nonce" =~ ^[0-9a-f]{32}$ ]] || return 1
    jq -e --arg tool "$NODE30_FREE_CLAIM_PROBE_SHA256" --arg source "$SOURCE_SHA" \
      --arg image "$CANDIDATE_IMAGE_REF" --arg image_id "$CANDIDATE_IMAGE_ID" \
      --arg observation "$expected_observation" --arg nonce "$expected_nonce" '
      def integer: type == "number" and floor == .;
      def hex64: type == "string" and test("^[0-9a-f]{64}$");
      type == "object" and (keys | sort) ==
        (["active_chain_rechecks","candidate_image_id","candidate_image_ref","observation",
          "payload","probe_finished_unix_ms","probe_started_unix_ms","probe_tool_sha256",
          "rollout_nonce","schema","source_sha"] | sort) and
      .schema == 2 and .observation == $observation and .probe_tool_sha256 == $tool and
      .source_sha == $source and .candidate_image_ref == $image and
      .candidate_image_id == $image_id and
      .rollout_nonce == $nonce and
      . as $root |
      ($root.probe_started_unix_ms | integer and . >= 0) and
      ($root.probe_finished_unix_ms | integer) and
      $root.probe_finished_unix_ms > $root.probe_started_unix_ms and
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
      (.payload.samples | type == "array" and length >= 4 and length <= 16) and
      ($root.active_chain_rechecks | type == "array") and
      ($root.active_chain_rechecks | length) == ($root.payload.samples | length) and
      all(range(0;(.payload.samples|length)); . as $i |
        $root.active_chain_rechecks[$i] as $r |
        $r | type == "object" and (keys | sort) ==
          ["blockhash","confirmations","height","rechecked_unix_ms","sample_index"] and
        .sample_index == $i and .blockhash == $root.payload.samples[$i].tip and
        .height == $root.payload.samples[$i].height and
        (.confirmations | integer and . > 0) and
        (.rechecked_unix_ms | integer and
          . >= ($root.payload.samples | map(.sample_finished_unix_ms) | max) and
          . <= $root.probe_finished_unix_ms))
      and all(range(1;(.active_chain_rechecks|length)); . as $i |
        $root.active_chain_rechecks[$i].rechecked_unix_ms >=
          $root.active_chain_rechecks[$i-1].rechecked_unix_ms)
    ' "$file" >/dev/null || return 1
    v3015_node30_probe_samples_are_live "$(jq -c '.payload.samples' "$file")" \
      "$expected_observation" "$NODE30_FREE_CLAIM_PROBE_SHA256" "$SOURCE_SHA" \
      "$CANDIDATE_IMAGE_REF" "$CANDIDATE_IMAGE_ID" \
      "$(jq -r '.rollout_nonce' "$file")" \
      "$(jq -r '.probe_started_unix_ms' "$file")" \
      "$(jq -r '.probe_finished_unix_ms' "$file")"
}

v3015_node30_result_is_valid()
{
    local file=$1 raw_probe=$2 authority_file=$3 sample probe_sha expected_nonce
    v3015_rollout_authority_is_valid "$authority_file" || return 1
    expected_nonce=$(jq -er '.nonce' "$authority_file") || return 1
    v3015_node30_probe_output_is_valid "$raw_probe" initial || return 1
    probe_sha=$(v3015_sha256_file "$raw_probe") || return 1
    jq -e --arg source "$SOURCE_SHA" --arg image "$CANDIDATE_IMAGE_REF" \
      --arg image_id "$CANDIDATE_IMAGE_ID" --arg probe_sha "$probe_sha" \
      --arg probe_tool "$NODE30_FREE_CLAIM_PROBE_SHA256" \
      --arg nonce "$expected_nonce" \
      --argjson raw "$(jq -c '.payload' "$raw_probe")" '
        type == "object" and (keys | sort) == ["container_recreated",
          "containment_only_on_failure","data_rewind_used","free_claim_intent_retained",
          "healthy","invocation","locked_restart","network_version","no_recovery_or_resolution_transaction",
          "node","normal_unlock_only","paused","preunlock_migration","probe_tool_sha256",
          "raw_probe_sha256","regular_pow_enabled","repair_rpcs",
          "restart_performed","role","rollout_nonce",
          "samples","schema","source_sha","subversion","wallet_audit",
          "wallet_normal_unlocked"] and
        .schema == 1 and .node == 30 and .source_sha == $source and
        .rollout_nonce == $nonce and
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
        .no_recovery_or_resolution_transaction == true and
        .no_recovery_or_resolution_transaction ==
          all(.wallet_audit.delta.transactions[];
            .cleanup == false and .recovery == false and
            .resolution == false and .recovery_fee == 0) and
        .samples == $raw.samples and
        (.samples | type == "array" and length >= 4) and
        ([.samples[].tip] as $tips | ($tips | unique | length) == ($tips | length)) and
        ([.samples[].height] as $h |
          all(range(1;($h|length)); $h[.] > $h[.-1]))
    ' "$file" >/dev/null || return 1
    v3015_preunlock_migration_is_safe \
      "$(jq -c '.preunlock_migration' "$file")" || return 1
    v3015_wallet_delta_is_safe "$(jq -c '.wallet_audit' "$file")" || return 1
    jq -e '.wallet_audit.delta.removed_txids == [] and
      all(.wallet_audit.delta.transactions[];
        .safe_external_receive == true and
        .authenticated_same_anchor_claim == false and
        .normal_coinstake == false and .authenticated_synthetic_payout == false and
        .cleanup == false and .recovery == false and .resolution == false and
        .recovery_fee == 0) and
      .preunlock_migration.after == .wallet_audit.before and
      (.preunlock_migration.before.wallet.walletname) as $name |
      all(.samples[]; .walletname == $name and .loaded_wallets == [$name])' \
      "$file" >/dev/null || return 1
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
    local file=$1 evidence=$2 authority_file=$3
    local row node result_file expected_sha terminal_probe_sha expected_nonce
    v3015_rollout_authority_is_valid "$authority_file" || return 1
    v3015_node30_probe_output_is_valid \
      "$evidence/node-30-free-claim-probe.raw.json" initial || return 1
    v3015_node30_probe_output_is_valid \
      "$evidence/node-30-free-claim-terminal-probe.raw.json" terminal || return 1
    jq -e -n --slurpfile initial "$evidence/node-30-free-claim-probe.raw.json" \
      --slurpfile terminal "$evidence/node-30-free-claim-terminal-probe.raw.json" '
      ($initial|length) == 1 and ($terminal|length) == 1 and
      ($initial[0] | {source_sha,candidate_image_ref,candidate_image_id,
        probe_tool_sha256,rollout_nonce}) ==
      ($terminal[0] | {source_sha,candidate_image_ref,candidate_image_id,
        probe_tool_sha256,rollout_nonce}) and
      $terminal[0].probe_started_unix_ms > $initial[0].probe_finished_unix_ms
    ' >/dev/null || return 1
    expected_nonce=$(jq -er '.nonce' "$authority_file") || return 1
    [[ "$(jq -er '.rollout_nonce' "$evidence/node-30-free-claim-probe.raw.json")" == \
       "$expected_nonce" &&
       "$(jq -er '.rollout_nonce' \
         "$evidence/node-30-free-claim-terminal-probe.raw.json")" == "$expected_nonce" ]] || return 1
    terminal_probe_sha=$(v3015_sha256_file \
      "$evidence/node-30-free-claim-terminal-probe.raw.json") || return 1
    jq -e --arg source "$SOURCE_SHA" --arg image "$CANDIDATE_IMAGE_REF" \
      --arg image_id "$CANDIDATE_IMAGE_ID" \
      --arg probe_tool "$NODE30_FREE_CLAIM_PROBE_SHA256" \
      --arg terminal_probe "$terminal_probe_sha" --arg nonce "$expected_nonce" '
      def integer: type == "number" and floor == .;
      def hex64: type == "string" and test("^[0-9a-f]{64}$");
      def core_keys: ["bestblockhash","blocks","chainwork","headers",
        "initialblockdownload"];
      def stable_core_cut($row):
        ($row.core_before | type == "object" and (keys | sort) == core_keys) and
        ($row.core_after | type == "object" and (keys | sort) == core_keys) and
        $row.core_before == $row.core_after and
        ($row.core_after.bestblockhash | hex64) and
        ($row.core_after.chainwork | hex64) and
        $row.core_after.initialblockdownload == false and
        ($row.chain | {bestblockhash,blocks,chainwork,headers,initialblockdownload}) ==
          $row.core_after;
      type == "object" and (keys | sort) ==
        ["captured_utc","node30_free_claim_healthy","node30_free_claim_paused",
         "node30_free_claim_probe_tool_sha256","node30_terminal_probe_sha256","nodes",
         "pos_active_count","pos_active_nodes","regular_pow_nodes",
         "regular_pow_operational_count","rollout_nonce","schema","source_sha"] and
      .schema == 1 and .source_sha == $source and
      .rollout_nonce == $nonce and
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
        (["chain","container_image_id","container_image_ref","core_after","core_before",
         "free_claim_healthy",
         "free_claim_paused","free_claim_probe_output_sha256",
         "free_claim_probe_tool_sha256","network","network_version","node",
         "node_result_sha256","pos_contract_passed","pow","pow_contract_passed","role",
         "source_sha","staking","subversion","wallet","loaded_wallets"] | sort) and
        .source_sha == $source and .network_version == 300105 and
        .subversion == "/Blackcoin:30.1.5/" and
        .container_image_ref == $image and .container_image_id == $image_id and
        (.node_result_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
        stable_core_cut(.) and
        .chain.initialblockdownload == false and .chain.blocks == .chain.headers and
        (.network.connections_out | integer and . >= 1) and
        (.wallet.walletname | type == "string") and
        .loaded_wallets == [.wallet.walletname] and .wallet.private_keys_enabled == true and
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
            [[ "$(jq -er '.wallet.walletname' <<<"$row")" == \
               "$(jq -er '.wallet_audit.before.wallet.walletname' "$result_file")" ]] || return 1
            jq -e --arg name "$(jq -er '.wallet_audit.before.wallet.walletname' \
              "$result_file")" 'all(.payload.samples[];
                .walletname == $name and .loaded_wallets == [$name])' \
              "$evidence/node-30-free-claim-terminal-probe.raw.json" >/dev/null || return 1
            v3015_pos_json_is_active "$(jq -c '.staking' <<<"$row")" || return 1
            jq -e '.role == "free_claim" and .pos_contract_passed == true and
              .pow_contract_passed == false and .free_claim_healthy == true and
              .free_claim_paused == false and .pow.enabled == false and
              .pow.autostart == false and .pow.hashrate == 0 and .pow.state == "disabled"' \
              <<<"$row" >/dev/null || return 1
        else
            expected_sha=$(v3015_sha256_file "$result_file") || return 1
            [[ "$(jq -er '.node_result_sha256' <<<"$row")" == "$expected_sha" ]] || return 1
            [[ "$(jq -er '.wallet.walletname' <<<"$row")" == \
               "$(jq -er '.wallet_audit.before.wallet.walletname' "$result_file")" ]] || return 1
            v3015_pos_json_is_active "$(jq -c '.staking' <<<"$row")" || return 1
            v3015_pow_json_is_typed_safe "$(jq -c '.pow' <<<"$row")" || return 1
            jq -e '.role == "regular" and .pos_contract_passed == true and
              .pow_contract_passed == true and .free_claim_healthy == false and
              .free_claim_paused == false and .free_claim_probe_output_sha256 == null and
              .free_claim_probe_tool_sha256 == null and
              .pow.current_height == .core_after.blocks and
              .pow.claim_inventory_tip == .core_after.bestblockhash and
              .staking.blocks == .core_after.blocks and
              .staking.active_blocks == .core_after.blocks' \
              <<<"$row" >/dev/null || return 1
        fi
    done < <(jq -c '.nodes[]' "$file")
}

v3015_fleet_result_is_valid()
{
    local file=$1 census_sha=$2 terminal_probe_sha=$3 authority_file=$4 expected_nonce
    v3015_rollout_authority_is_valid "$authority_file" || return 1
    expected_nonce=$(jq -er '.nonce' "$authority_file") || return 1
    v3015_is_sha256 "$terminal_probe_sha" || return 1
    jq -e --arg source "$SOURCE_SHA" --arg census "$census_sha" \
      --arg policy_receipt "$RUNTIME_POLICY_HANDOFF_RECEIPT_SHA256" \
      --arg compose_receipt "$PERSISTENT_COMPOSE_HANDOFF_RECEIPT_SHA256" \
      --arg compose_sha "$FINAL_COMPOSE_SHA256" --arg policy_sha "$FINAL_IMAGE_POLICY_SHA256" \
      --arg reconcile "$POST_COMPOSE_RECONCILE_IDENTITY_SHA256" \
      --arg probe_tool "$NODE30_FREE_CLAIM_PROBE_SHA256" \
      --arg terminal_probe "$terminal_probe_sha" --arg nonce "$expected_nonce" '
      type == "object" and (keys | sort) == (["containment_only_failure_policy",
        "data_rewind_used","final_compose_sha256","final_image_policy_sha256",
        "node30_free_claim_healthy","node30_free_claim_paused",
        "node30_free_claim_probe_tool_sha256","node30_role","node30_terminal_probe_sha256",
        "persistent_compose_handoff_receipt_sha256","pos_active","pos_active_nodes",
        "post_compose_reconcile_identity_sha256","regular_pow_nodes","regular_pow_operational",
        "rollout_nonce","runtime_policy_handoff_receipt_sha256","schema","source_sha","status",
        "terminal_census_sha256","transaction"] | sort) and
      .schema == 1 and .transaction == "v30.1.5-fleet-rollout" and
      .source_sha == $source and .rollout_nonce == $nonce and .status == "PASS" and
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
