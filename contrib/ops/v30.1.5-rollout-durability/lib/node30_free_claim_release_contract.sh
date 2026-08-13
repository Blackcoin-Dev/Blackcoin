# shellcheck shell=bash
# Pure predicates and the marker archive/restore primitive for the separately
# authorized node30 Free-Claim release stage.

export LC_ALL=C

readonly V3015_NODE30_ZERO_TXID='0000000000000000000000000000000000000000000000000000000000000000'
readonly V3015_NODE30_EXPECTED_PAUSE_CONTENT='schema=1 state=paused authority=v30.1.4-fleet-transaction'
readonly V3015_NODE30_EXPECTED_LOCKS=(
    /var/run/blackcoin-v3015-rollout.lock
    /run/blackcoin-endpoint-guard.lock
    /var/run/blackcoin-node-cutover.lock
    /run/blackcoin-pow-quarantine-cycle.lock
    /var/run/blackcoin-wallet-runtime-guard.lock
    /var/run/blackcoin-free-claim-pause-transition.lock
    /var/run/blackcoin-free-claim-pool.lock
)

v3015_node30_sha256_text()
{
    printf '%s' "$1" | sha256sum | awk '{print $1}'
}

v3015_node30_lock_paths_json()
{
    printf '%s\n' "${V3015_NODE30_EXPECTED_LOCKS[@]}" | jq -Rsc 'split("\n")[:-1]'
}

v3015_validate_node30_release_env()
{
    local name
    v3015_validate_release_env || return

    for name in NODE30_PAUSE_WRAPPER_SHA256 NODE30_PAUSE_MARKER_SHA256 \
        NODE30_ORIGINAL_WORKER_SHA256 NODE30_QUEUE_ITEM_SHA256 \
        NODE30_QUEUE_ADDRESS_SHA256 NODE30_AWARDED_SHA256 \
        NODE30_PUBLIC_ARTIFACT_AUTHORITY_SHA256 \
        NODE30_SUCCESSOR_SEMANTICS_RECEIPT_SHA256 \
        NODE30_MAINTENANCE_FINALIZATION_RECEIPT_SHA256 \
        NODE30_FEE_SIGN_BROADCAST_AUTHORITY_SHA256 NODE30_FLEET_RESULT_SHA256; do
        v3015_require_resolved "$name" "${!name:-}" || return
        v3015_is_sha256 "${!name}" || v3015_die "$name must be 64 lowercase hex" || return
    done

    for name in NODE30_PUBLIC_ARTIFACT_AUTHORITY \
        NODE30_SUCCESSOR_SEMANTICS_RECEIPT \
        NODE30_MAINTENANCE_FINALIZATION_RECEIPT \
        NODE30_FEE_SIGN_BROADCAST_AUTHORITY NODE30_FLEET_RESULT; do
        v3015_require_resolved "$name" "${!name:-}" || return
        [[ "${!name}" == /* ]] || v3015_die "$name must be an absolute reviewed path" || return
    done

    [[ "${NODE30_FREE_CLAIM_ROOT:-}" == \
         /mnt/pulsar/Blackcoin_Blocks/operations/free-claim-pool &&
       "${NODE30_PAUSE_WRAPPER:-}" == "$NODE30_FREE_CLAIM_ROOT/pool_daemon.sh" &&
       "${NODE30_PAUSE_MARKER:-}" == \
         "$NODE30_FREE_CLAIM_ROOT/.v30.1.4-free-claim-paused" &&
       "${NODE30_ORIGINAL_WORKER:-}" == \
         "$NODE30_FREE_CLAIM_ROOT/pool_daemon.v30.1.4-original" &&
       "${NODE30_QUEUE_DIR:-}" == "$NODE30_FREE_CLAIM_ROOT/queue" &&
       "${NODE30_DONE_DIR:-}" == "$NODE30_FREE_CLAIM_ROOT/done" &&
       "${NODE30_AWARDED_FILE:-}" == "$NODE30_FREE_CLAIM_ROOT/awarded.txt" &&
       "${NODE30_RELEASE_EVIDENCE_ROOT:-}" == \
         "$NODE30_FREE_CLAIM_ROOT/v30.1.5-release-evidence" &&
       "${NODE30_ROLLOUT_MAINTENANCE_MARKER:-}" == \
         "$STATE_DIR/V30_1_5_ROLLOUT_MAINTENANCE.json" ]] ||
        v3015_die 'node30 reviewed path contract is unresolved or changed' || return

    [[ "${NODE30_PAUSE_MARKER_CONTENT:-}" == "$V3015_NODE30_EXPECTED_PAUSE_CONTENT" ]] ||
        v3015_die 'node30 pause-marker content contract changed' || return
    [[ "${NODE30_QUEUE_ITEM_BASENAME:-}" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}[.]json$ ]] ||
        v3015_die 'node30 queue item basename is unresolved or malformed' || return
    [[ "${NODE30_POOL_GROUP_GID:-}" =~ ^[1-9][0-9]*$ &&
       "${NODE30_MIN_PEERS:-}" =~ ^[1-9][0-9]*$ &&
       "${NODE30_MIN_UNLOCK_REMAINING_SECONDS:-}" =~ ^[1-9][0-9]*$ &&
       "${NODE30_DAILY_CAP:-}" =~ ^[1-9][0-9]*$ &&
       "${NODE30_MAX_ATTEMPTS:-}" =~ ^[1-9][0-9]*$ ]] ||
        v3015_die 'node30 numeric release thresholds are unresolved' || return
    ((NODE30_MIN_PEERS >= 1 && NODE30_MIN_PEERS <= 10000 &&
      NODE30_MIN_UNLOCK_REMAINING_SECONDS >= 600 &&
      NODE30_MIN_UNLOCK_REMAINING_SECONDS <= 86400 &&
      NODE30_DAILY_CAP == 25 && NODE30_MAX_ATTEMPTS == 20)) ||
        v3015_die 'node30 release thresholds are outside the reviewed contract' || return
}

v3015_node30_public_artifact_authority_is_valid()
{
    local file=$1 release_identity_sha image_manifest
    release_identity_sha=$(v3015_sha256_file "$RELEASE_IDENTITY_JSON") || return
    image_manifest=${CANDIDATE_IMAGE_REF##*@sha256:}
    jq -e --arg source "$SOURCE_SHA" --arg tree "$SOURCE_TREE" \
      --arg fingerprint "$SOURCE_SIGNING_FINGERPRINT" \
      --argjson ci_run "$CORE_CI_RUN_ID" --arg workflow "$CORE_CI_WORKFLOW" \
      --arg artifact "$CANDIDATE_ARTIFACT_NAME" \
      --argjson artifact_run "$CANDIDATE_ARTIFACT_RUN_ID" \
      --argjson attempt "$CANDIDATE_ARTIFACT_RUN_ATTEMPT" \
      --arg image "$CANDIDATE_IMAGE_REF" --arg image_id "$CANDIDATE_IMAGE_ID" \
      --arg bundle "$CANDIDATE_BUNDLE_SHA256" \
      --arg oci_archive "$CANDIDATE_OCI_ARCHIVE_SHA256" \
      --arg oci_manifest "$CANDIDATE_OCI_MANIFEST_SHA256" \
      --arg image_manifest "$image_manifest" \
      --arg tooling "$CANDIDATE_TOOLING_SHA256" \
      --arg manifest "$CANDIDATE_MANIFEST_SHA256" \
      --arg provenance "$CANDIDATE_PROVENANCE_SHA256" \
      --arg blackcoind "$CANDIDATE_BLACKCOIND_SHA256" \
      --arg cli "$CANDIDATE_BLACKCOIN_CLI_SHA256" \
      --arg qt "$CANDIDATE_BLACKCOIN_QT_SHA256" \
      --arg tx "$CANDIDATE_BLACKCOIN_TX_SHA256" \
      --arg wallet "$CANDIDATE_BLACKCOIN_WALLET_SHA256" \
      --arg util "$CANDIDATE_BLACKCOIN_UTIL_SHA256" \
      --arg release_identity "$release_identity_sha" '
        def hex64: type == "string" and test("^[0-9a-f]{64}$");
        def utc: type == "string" and
          test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
        def expected_keys: ["artifact","authorized_utc","binary_sha256s",
          "candidate_bundle_sha256","candidate_image_id","candidate_image_ref",
          "candidate_manifest_sha256","candidate_oci_archive_sha256",
          "candidate_oci_manifest_sha256","candidate_provenance_sha256",
          "candidate_tooling_sha256","core_ci","kind","network_version",
          "public_artifact_authorized","registry_digest_verified","release",
          "release_identity_sha256","schema","source_sha",
          "source_signature_verified","source_signing_fingerprint","source_tree",
          "subversion"];
        type == "object" and (keys | sort) == (expected_keys | sort) and
        .schema == 1 and .kind == "v30.1.5-public-artifact-authority" and
        .release == "v30.1.5" and .source_sha == $source and .source_tree == $tree and
        .source_signature_verified == true and
        .source_signing_fingerprint == $fingerprint and
        .core_ci == {run_id:$ci_run,head_sha:$source,conclusion:"success",workflow:$workflow} and
        .artifact == {name:$artifact,run_id:$artifact_run,run_attempt:$attempt} and
        .network_version == 300105 and .subversion == "/Blackcoin:30.1.5/" and
        .candidate_image_ref == $image and .candidate_image_id == $image_id and
        .candidate_bundle_sha256 == $bundle and
        .candidate_oci_archive_sha256 == $oci_archive and
        .candidate_oci_manifest_sha256 == $oci_manifest and
        .candidate_oci_manifest_sha256 == $image_manifest and
        .candidate_tooling_sha256 == $tooling and
        .candidate_manifest_sha256 == $manifest and
        .candidate_provenance_sha256 == $provenance and
        .binary_sha256s == {blackcoind:$blackcoind,"blackcoin-cli":$cli,
          "blackcoin-qt":$qt,"blackcoin-tx":$tx,"blackcoin-wallet":$wallet,
          "blackcoin-util":$util} and
        .release_identity_sha256 == $release_identity and
        .public_artifact_authorized == true and .registry_digest_verified == true and
        (.authorized_utc | utc) and
        all([.candidate_bundle_sha256,.candidate_oci_archive_sha256,
          .candidate_oci_manifest_sha256,.candidate_tooling_sha256,
          .candidate_manifest_sha256,.candidate_provenance_sha256,
          .release_identity_sha256][]; hex64)
      ' "$file" >/dev/null
}

v3015_node30_successor_semantics_is_valid()
{
    local file=$1 public_sha
    public_sha=$(v3015_sha256_file "$NODE30_PUBLIC_ARTIFACT_AUTHORITY") || return
    jq -e --arg source "$SOURCE_SHA" --arg tree "$SOURCE_TREE" \
      --arg public "$public_sha" --arg worker "$NODE30_ORIGINAL_WORKER_SHA256" '
        def hex64: type == "string" and test("^[0-9a-f]{64}$");
        def utc: type == "string" and
          test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
        def expected_keys: ["authenticated_lineaged_claim_requires_distinct_utxo",
          "authenticated_lineaged_claim_requires_recovery_fee",
          "blocking_wallet_relevant_family_prevents_new_claim","kind",
          "manual_send_and_builtin_share_family_selection","manual_send_uses_typed_gate",
          "new_free_claim_requires_fee_input","new_quantum_key_required",
          "node30_ordinary_pow_must_remain_disabled","normal_unlock_sufficient",
          "ordinary_pow_required","product_test_receipt_sha256",
          "public_artifact_authority_sha256","pure_foreign_audit_history_ignored",
          "release","retained_family_preserves_payout_anchor_lineage",
          "retained_family_priority","reviewed_utc","schema","source_sha","source_tree",
          "witness_v16_direct_payout","worker_fee_cap_enforced",
          "worker_queue_result_binds_actual_payout","worker_sha256"];
        type == "object" and (keys | sort) == (expected_keys | sort) and
        .schema == 1 and .kind == "v30.1.5-node30-free-claim-successor-semantics" and
        .release == "v30.1.5" and .source_sha == $source and .source_tree == $tree and
        .public_artifact_authority_sha256 == $public and .worker_sha256 == $worker and
        .manual_send_uses_typed_gate == true and
        .manual_send_and_builtin_share_family_selection == true and
        .blocking_wallet_relevant_family_prevents_new_claim == true and
        .pure_foreign_audit_history_ignored == true and
        .retained_family_priority == ["relay_existing","refresh_same_anchor",
          "wait_for_next_tip","wait_for_live"] and
        .retained_family_preserves_payout_anchor_lineage == true and
        .authenticated_lineaged_claim_requires_recovery_fee == false and
        .authenticated_lineaged_claim_requires_distinct_utxo == false and
        .new_free_claim_requires_fee_input == true and
        .normal_unlock_sufficient == true and .ordinary_pow_required == false and
        .node30_ordinary_pow_must_remain_disabled == true and
        .new_quantum_key_required == false and .witness_v16_direct_payout == true and
        .worker_fee_cap_enforced == true and
        .worker_queue_result_binds_actual_payout == true and
        (.product_test_receipt_sha256 | hex64) and (.reviewed_utc | utc)
      ' "$file" >/dev/null
}

v3015_node30_finalization_is_valid()
{
    local file=$1 release_identity_sha public_sha semantics_sha
    release_identity_sha=$(v3015_sha256_file "$RELEASE_IDENTITY_JSON") || return
    public_sha=$(v3015_sha256_file "$NODE30_PUBLIC_ARTIFACT_AUTHORITY") || return
    semantics_sha=$(v3015_sha256_file "$NODE30_SUCCESSOR_SEMANTICS_RECEIPT") || return
    jq -e --arg source "$SOURCE_SHA" --arg tree "$SOURCE_TREE" \
      --arg image "$CANDIDATE_IMAGE_REF" --arg image_id "$CANDIDATE_IMAGE_ID" \
      --arg package "$PACKAGE_SHA256SUMS_SHA256" \
      --arg release_identity "$release_identity_sha" --arg public "$public_sha" \
      --arg semantics "$semantics_sha" --arg fleet "$NODE30_FLEET_RESULT_SHA256" \
      --arg marker "$NODE30_PAUSE_MARKER_SHA256" '
        def utc: type == "string" and
          test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
        def expected_keys: ["candidate_image_id","candidate_image_ref",
          "completed_utc","data_rewind_used","fleet_healthy_nodes",
          "fleet_pos_active_nodes","fleet_result_sha256","free_claim_pause_marker_sha256",
          "free_claim_pause_preserved","kind","maintenance_marker_absent",
          "maintenance_transaction_state","node30_ordinary_pow_disabled",
          "node30_staking_active","package_sha256sums_sha256",
          "public_artifact_authority_sha256","regular_pow_active_nodes","release",
          "release_identity_sha256","schema","source_sha","source_tree",
          "successor_semantics_receipt_sha256"];
        type == "object" and (keys | sort) == (expected_keys | sort) and
        .schema == 1 and .kind == "v30.1.5-node30-free-claim-finalization" and
        .release == "v30.1.5" and .source_sha == $source and .source_tree == $tree and
        .candidate_image_ref == $image and .candidate_image_id == $image_id and
        .package_sha256sums_sha256 == $package and
        .release_identity_sha256 == $release_identity and
        .public_artifact_authority_sha256 == $public and
        .successor_semantics_receipt_sha256 == $semantics and
        .fleet_result_sha256 == $fleet and
        .free_claim_pause_marker_sha256 == $marker and
        .maintenance_transaction_state == "complete" and
        .maintenance_marker_absent == true and .free_claim_pause_preserved == true and
        .node30_ordinary_pow_disabled == true and .node30_staking_active == true and
        .fleet_healthy_nodes == 32 and .fleet_pos_active_nodes == 32 and
        .regular_pow_active_nodes == 31 and .data_rewind_used == false and
        (.completed_utc | utc)
      ' "$file" >/dev/null
}

v3015_node30_fee_sign_broadcast_authority_is_valid()
{
    local file=$1 now=$2 public_sha semantics_sha finalization_sha
    public_sha=$(v3015_sha256_file "$NODE30_PUBLIC_ARTIFACT_AUTHORITY") || return
    semantics_sha=$(v3015_sha256_file "$NODE30_SUCCESSOR_SEMANTICS_RECEIPT") || return
    finalization_sha=$(v3015_sha256_file "$NODE30_MAINTENANCE_FINALIZATION_RECEIPT") || return
    jq -e --arg source "$SOURCE_SHA" --arg image "$CANDIDATE_IMAGE_REF" \
      --arg public "$public_sha" --arg semantics "$semantics_sha" \
      --arg finalization "$finalization_sha" --arg worker "$NODE30_ORIGINAL_WORKER_SHA256" \
      --arg queue "$NODE30_QUEUE_ITEM_SHA256" \
      --arg payout "$NODE30_QUEUE_ADDRESS_SHA256" --argjson now "$now" '
        def nonce: type == "string" and test("^[0-9a-f]{32}$");
        def amount: type == "number" and . > 0;
        def expected_keys: ["broadcast_authorized","candidate_image_ref",
          "expires_epoch","fee_authorized","kind","max_fee_rate","max_total_fee",
          "new_key_authorized","node","ordinary_pow_authorized","not_before_epoch",
          "public_artifact_authority_sha256","queue_address_sha256",
          "queue_item_sha256","recovery_authorized","reindex_authorized",
          "release_nonce","repair_authorized","rewind_authorized","schema",
          "sign_authorized","single_submission_only","source_sha","spend_nonce",
          "successor_semantics_receipt_sha256","finalization_receipt_sha256",
          "worker_sha256"];
        type == "object" and (keys | sort) == (expected_keys | sort) and
        .schema == 1 and .kind == "v30.1.5-node30-fee-sign-broadcast-authority" and
        .source_sha == $source and .candidate_image_ref == $image and .node == 30 and
        .public_artifact_authority_sha256 == $public and
        .successor_semantics_receipt_sha256 == $semantics and
        .finalization_receipt_sha256 == $finalization and .worker_sha256 == $worker and
        .queue_item_sha256 == $queue and .queue_address_sha256 == $payout and
        .fee_authorized == true and .sign_authorized == true and
        .broadcast_authorized == true and .single_submission_only == true and
        .ordinary_pow_authorized == false and .recovery_authorized == false and
        .repair_authorized == false and .reindex_authorized == false and
        .rewind_authorized == false and .new_key_authorized == false and
        (.max_fee_rate | amount) and (.max_total_fee | amount) and
        (.release_nonce | nonce) and (.spend_nonce | nonce) and
        .release_nonce != .spend_nonce and
        . as $authority |
        (.not_before_epoch | type == "number" and floor == . and . >= 0) and
        (.expires_epoch | type == "number" and floor == . and
          . > $authority.not_before_epoch) and
        .not_before_epoch <= $now and $now < .expires_epoch
      ' "$file" >/dev/null
}

v3015_node30_authorities_are_valid()
{
    local now=$1
    [[ "$(v3015_sha256_file "$NODE30_PUBLIC_ARTIFACT_AUTHORITY")" == \
         "$NODE30_PUBLIC_ARTIFACT_AUTHORITY_SHA256" &&
       "$(v3015_sha256_file "$NODE30_SUCCESSOR_SEMANTICS_RECEIPT")" == \
         "$NODE30_SUCCESSOR_SEMANTICS_RECEIPT_SHA256" &&
       "$(v3015_sha256_file "$NODE30_MAINTENANCE_FINALIZATION_RECEIPT")" == \
         "$NODE30_MAINTENANCE_FINALIZATION_RECEIPT_SHA256" &&
       "$(v3015_sha256_file "$NODE30_FEE_SIGN_BROADCAST_AUTHORITY")" == \
         "$NODE30_FEE_SIGN_BROADCAST_AUTHORITY_SHA256" &&
       "$(v3015_sha256_file "$NODE30_FLEET_RESULT")" == "$NODE30_FLEET_RESULT_SHA256" ]] ||
        return 1
    v3015_node30_public_artifact_authority_is_valid "$NODE30_PUBLIC_ARTIFACT_AUTHORITY" &&
        v3015_node30_successor_semantics_is_valid "$NODE30_SUCCESSOR_SEMANTICS_RECEIPT" &&
        v3015_node30_finalization_is_valid "$NODE30_MAINTENANCE_FINALIZATION_RECEIPT" &&
        v3015_node30_fee_sign_broadcast_authority_is_valid \
          "$NODE30_FEE_SIGN_BROADCAST_AUTHORITY" "$now"
}

v3015_node30_release_confirmations_are_valid()
{
    local release_nonce spend_nonce
    release_nonce=$(jq -er '.release_nonce' "$NODE30_FEE_SIGN_BROADCAST_AUTHORITY") || return
    spend_nonce=$(jq -er '.spend_nonce' "$NODE30_FEE_SIGN_BROADCAST_AUTHORITY") || return
    [[ "${NODE30_RELEASE_CLEARED:-}" == \
         "v30.1.5-node30-free-claim-release:${SOURCE_SHA}:${release_nonce}" &&
       "${NODE30_FEE_SIGN_BROADCAST_CLEARED:-}" == \
         "v30.1.5-node30-fee-sign-broadcast:${SOURCE_SHA}:${spend_nonce}" ]]
}

v3015_node30_pow_is_release_ready()
{
    local pow=$1 tip=$2 height=$3
    jq -e -n --argjson p "$pow" --arg tip "$tip" --argjson height "$height" \
      --arg zero "$V3015_NODE30_ZERO_TXID" '
        def integer: type == "number" and floor == .;
        def uint: integer and . >= 0;
        def amount: type == "number" and . >= 0;
        def hex64: type == "string" and test("^[0-9a-f]{64}$");
        def required_keys: ["actionable_quarantined_claims",
          "allow_automatic_quantum_key_creation","autostart","blocking_quarantined_claims",
          "claim_coins_after_stake_reserve","claim_inventory_tip",
          "claim_inventory_wallet_tip_matches","claim_recovery_database_outcome_ambiguous",
          "claims_submitted","current_height","enabled","hashrate","live_claims",
          "mining_gate_action","mining_gate_can_submit",
          "mining_gate_candidate_state_fingerprint","mining_gate_coherent",
          "mining_gate_database_ambiguous","mining_gate_eligible_claims",
          "mining_gate_family_claims","mining_gate_lineage_head_txid",
          "mining_gate_live_claims","mining_gate_relay_txid",
          "mining_gate_unresolved_components","mining_gate_unsafe_claims",
          "mining_gate_unsafe_components","pending_automatic_resolutions",
          "pending_manual_resolutions","state"];
        $p | type == "object" and
        all(required_keys[]; . as $key | $p | has($key)) and
        .enabled == false and .autostart == false and .state == "disabled" and
        (.hashrate | type == "number" and . == 0) and
        .allow_automatic_quantum_key_creation == false and
        (.live_claims | uint and . == 0) and (.claims_submitted | uint) and
        .claim_inventory_tip == $tip and .claim_inventory_wallet_tip_matches == true and
        .claim_recovery_database_outcome_ambiguous == false and
        .mining_gate_coherent == true and .mining_gate_database_ambiguous == false and
        .mining_gate_action == "create_new_anchor" and .mining_gate_can_submit == true and
        (.mining_gate_unsafe_claims | uint and . == 0) and
        (.mining_gate_unsafe_components | uint and . == 0) and
        (.mining_gate_unresolved_components | uint and . == 0) and
        (.mining_gate_live_claims | uint and . == 0) and
        (.mining_gate_eligible_claims | uint and . == 0) and
        (.mining_gate_family_claims | uint and . == 0) and
        .mining_gate_relay_txid == $zero and .mining_gate_lineage_head_txid == $zero and
        (.mining_gate_candidate_state_fingerprint | hex64) and
        .mining_gate_candidate_state_fingerprint != $zero and
        (.pending_manual_resolutions | uint and . == 0) and
        (.pending_automatic_resolutions | uint and . == 0) and
        (.claim_coins_after_stake_reserve | uint and . >= 1) and
        (.current_height | integer and . == $height)
      ' >/dev/null
}

v3015_node30_recovery_has_no_wallet_relevant_blocker()
{
    local recovery=$1
    jq -e -n --argjson r "$recovery" '
      def blocking: .classification | IN("live","transient","indeterminate",
        "current_branch_ineligible","terminal_on_pinned_tip","resolution_pending");
      def audit_only_foreign:
        .anchor_authenticated == false and .anchor_unspent == false and
        .anchor_user_locked == false and (.claim_txids | length) >= 1 and
        all(.nodes[]; .provenance == "unknown" and .wallet_authored == false and
          .wallet_from_me == false);
      $r.pending_manual_resolutions == 0 and $r.pending_automatic_resolutions == 0 and
      $r.policy.automatic_enabled == false and $r.policy.automatic_authorized == false and
      all($r.component_details[] | select(blocking); audit_only_foreign)
    ' >/dev/null
}

v3015_node30_runtime_snapshot_is_valid()
{
    local file=$1 recovery pow staking tip height
    recovery=$(jq -c '.recovery' "$file") || return
    pow=$(jq -c '.pow' "$file") || return
    staking=$(jq -c '.staking' "$file") || return
    tip=$(jq -er '.before_chain.bestblockhash' "$file") || return
    height=$(jq -er '.before_chain.blocks' "$file") || return
    v3015_recovery_json_is_exact_safe "$recovery" || return
    v3015_node30_recovery_has_no_wallet_relevant_blocker "$recovery" || return
    v3015_node30_pow_is_release_ready "$pow" "$tip" "$height" || return
    v3015_pos_json_is_active "$staking" || return

    jq -e --arg source "$SOURCE_SHA" --arg image "$CANDIDATE_IMAGE_REF" \
      --arg image_id "$CANDIDATE_IMAGE_ID" --arg cli "$CANDIDATE_BLACKCOIN_CLI_SHA256" \
      --arg blackcoind "$CANDIDATE_BLACKCOIND_SHA256" \
      --arg qt "$CANDIDATE_BLACKCOIN_QT_SHA256" \
      --arg tx "$CANDIDATE_BLACKCOIN_TX_SHA256" \
      --arg wallet_bin "$CANDIDATE_BLACKCOIN_WALLET_SHA256" \
      --arg util "$CANDIDATE_BLACKCOIN_UTIL_SHA256" \
      --arg queue_name "$NODE30_QUEUE_ITEM_BASENAME" \
      --arg queue_sha "$NODE30_QUEUE_ITEM_SHA256" \
      --arg payout_sha "$NODE30_QUEUE_ADDRESS_SHA256" \
      --arg awarded_sha "$NODE30_AWARDED_SHA256" \
      --argjson min_peers "$NODE30_MIN_PEERS" \
      --argjson min_unlock "$NODE30_MIN_UNLOCK_REMAINING_SECONDS" \
      --argjson daily_cap "$NODE30_DAILY_CAP" \
      --argjson max_attempts "$NODE30_MAX_ATTEMPTS" \
      --argjson expected_locks "$(v3015_node30_lock_paths_json)" '
        def integer: type == "number" and floor == .;
        def uint: integer and . >= 0;
        def amount: type == "number" and . >= 0;
        def hex64: type == "string" and test("^[0-9a-f]{64}$");
        def outer_keys: ["address_info","after_chain","before_chain","binary_sha256s",
          "broadcast_count","captured_epoch","container","goldrush","lock_paths",
          "network","pow","queue","recovery","schema","selected_coin_after",
          "selected_coin_before","selected_utxo","staking","target_address_info",
          "wallet","wallets","work"];
        type == "object" and (keys | sort) == (outer_keys | sort) and .schema == 1 and
        (.captured_epoch | integer and . > 0) and
        .before_chain == .after_chain and
        (.before_chain | keys | sort) ==
          (["bestblockhash","blocks","chain","headers","initialblockdownload",
            "verificationprogress"] | sort) and
        .before_chain.chain == "main" and
        (.before_chain.blocks | uint) and .before_chain.headers == .before_chain.blocks and
        (.before_chain.bestblockhash | hex64) and
        .before_chain.bestblockhash != ("0"*64) and
        .before_chain.initialblockdownload == false and
        (.before_chain.verificationprogress | type == "number" and . >= 0.99999 and . <= 1) and
        (.network | keys | sort) ==
          (["connections","networkactive","subversion","version"] | sort) and
        .network.version == 300105 and .network.subversion == "/Blackcoin:30.1.5/" and
        .network.networkactive == true and (.network.connections | uint and . >= $min_peers) and
        .container == {name:"blackcoin-v4-gui-30",image_ref:$image,image_id:$image_id,
          running:true,paused:false,restarting:false,dead:false,health:"healthy"} and
        .binary_sha256s == {blackcoind:$blackcoind,"blackcoin-cli":$cli,
          "blackcoin-qt":$qt,"blackcoin-tx":$tx,"blackcoin-wallet":$wallet_bin,
          "blackcoin-util":$util} and
        (.wallets | type == "array" and length == 1 and all(.[]; type == "string")) and
        (.wallet | keys | sort) == (["lastprocessedblock","paytxfee",
          "private_keys_enabled","scanning","unlocked_staking_only","unlocked_until",
          "walletname"] | sort) and
        .wallet.walletname == .wallets[0] and .wallet.private_keys_enabled == true and
        .wallet.unlocked_staking_only == false and .wallet.scanning == false and
        (.wallet.unlocked_until | integer) and
        .wallet.unlocked_until >= (.captured_epoch + $min_unlock) and
        (.wallet.paytxfee | amount) and
        .wallet.lastprocessedblock ==
          {hash:.before_chain.bestblockhash,height:.before_chain.blocks} and
        .staking.blocks == .before_chain.blocks and
        .staking.active_blocks == .before_chain.blocks and
        .staking.allow_automatic_quantum_key_creation == false and
        .recovery.active_tip == .before_chain.bestblockhash and
        .recovery.active_height == .before_chain.blocks and
        .recovery.wallet_processed_tip == .before_chain.bestblockhash and
        .recovery.wallet_processed_height == .before_chain.blocks and
        (.selected_utxo | keys | sort) == (["address","amount","safe","scriptPubKey",
          "spendability_state","spendable","txid","vout"] | sort) and
        (.selected_utxo.txid | hex64) and (.selected_utxo.vout | uint) and
        (.selected_utxo.address | type == "string" and length > 0) and
        (.selected_utxo.scriptPubKey | type == "string" and
          test("^([0-9a-f]{2})+$")) and
        (.selected_utxo.amount | type == "number" and . > 0) and
        .selected_utxo.safe == true and .selected_utxo.spendable == true and
        .selected_utxo.spendability_state == "spendable_legacy" and
        .selected_coin_before == .selected_coin_after and
        (.selected_coin_before | keys | sort) == (["scriptPubKey","value"] | sort) and
        .selected_coin_before.value == .selected_utxo.amount and
        .selected_coin_before.scriptPubKey == .selected_utxo.scriptPubKey and
        (.target_address_info | keys | sort) ==
          (["address","ismine","iswatchonly","scriptPubKey","solvable"] | sort) and
        .target_address_info.address == .selected_utxo.address and
        .target_address_info.ismine == true and .target_address_info.iswatchonly == false and
        .target_address_info.solvable == true and
        .target_address_info.scriptPubKey == .selected_utxo.scriptPubKey and
        (.queue | keys | sort) == (["address_already_awarded","address_sha256",
          "awarded_sha256","basename","daily_cap","files_count","nonregular_entries",
          "other_entries","record","sha256","sponsorships_today"] | sort) and
        .queue.basename == $queue_name and .queue.sha256 == $queue_sha and
        .queue.address_sha256 == $payout_sha and .queue.awarded_sha256 == $awarded_sha and
        .queue.files_count == 1 and .queue.other_entries == 0 and
        .queue.nonregular_entries == 0 and .queue.address_already_awarded == false and
        .queue.daily_cap == $daily_cap and
        (.queue.sponsorships_today | uint) and
        .queue.sponsorships_today < .queue.daily_cap and
        (.queue.record | keys | sort) == (["attempts","ip","quantum_address","submitted"] | sort) and
        (.queue.record.attempts | integer and . >= 1 and . < $max_attempts) and
        (.queue.record.ip | type == "string" and length > 0) and
        (.queue.record.submitted | type == "string" and
          test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(Z|[+]00:00)$")) and
        (.queue.record.quantum_address | type == "string" and length > 0) and
        .broadcast_count == 0 and
        (.address_info | keys | sort) == (["address","ismine","isvalid","iswatchonly",
          "iswitness","scriptPubKey","witness_program","witness_version"] | sort) and
        .address_info.address == .queue.record.quantum_address and
        .address_info.isvalid == true and .address_info.iswitness == true and
        .address_info.witness_version == 16 and .address_info.ismine == false and
        .address_info.iswatchonly == false and
        (.address_info.witness_program | type == "string" and test("^[0-9a-f]{64}$")) and
        .address_info.scriptPubKey == ("6020" + .address_info.witness_program) and
        (.work | keys | sort) == (["active","claim_outpoint_required","claim_txid",
          "claim_vout","height","prefix","prevhash","proof_mode","proof_mode_byte",
          "proof_version","qqp4_activation_disabled","qqp4_activation_height",
          "qqp4_active_next_block","quantum_address","quantum_payout_script",
          "reward_end_height","reward_start_height","target_bits","target_script"] | sort) and
        .work.active == true and .work.height == (.before_chain.blocks + 1) and
        .work.prevhash == .before_chain.bestblockhash and
        (.work.target_bits | uint and . > 0) and .work.prefix == "QQSPROOF" and
        .work.proof_mode == "pow" and .work.proof_mode_byte == 0 and
        (.work.proof_version | IN(2,3,4)) and
        .work.claim_outpoint_required == .work.qqp4_active_next_block and
        (if .work.qqp4_activation_disabled then
           .work.qqp4_activation_height == 0 and .work.qqp4_active_next_block == false
         else
           (.work.qqp4_activation_height | integer and . > 0) and
           .work.qqp4_active_next_block == (.work.height >= .work.qqp4_activation_height)
         end) and
        .work.proof_version ==
          (if .work.claim_outpoint_required then 4
           elif .goldrush.competing_claim_rule_active_next_block then 3 else 2 end) and
        .work.target_script == .selected_utxo.scriptPubKey and
        .work.quantum_address == .queue.record.quantum_address and
        .work.quantum_payout_script == .address_info.scriptPubKey and
        (if .work.claim_outpoint_required then
           .work.claim_txid == .selected_utxo.txid and
           .work.claim_vout == .selected_utxo.vout
         else .work.claim_txid == null and .work.claim_vout == null end) and
        (.work.reward_start_height | uint) and (.work.reward_end_height | uint) and
        .work.reward_start_height <= .work.height and .work.height <= .work.reward_end_height and
        (.goldrush | keys | sort) == (["active","blocks_until_competing_claim_rule",
          "competing_claim_rule_active_next_block","height","pow_amount","pow_jackpot",
          "qqp4_activation_disabled","qqp4_activation_height","qqp4_active_next_block"] | sort) and
        .goldrush.active == true and .goldrush.height == .before_chain.blocks and
        (.goldrush.pow_amount | integer and . > 0) and
        (.goldrush.pow_jackpot | type == "number" and . > 0) and
        (.goldrush.blocks_until_competing_claim_rule | uint) and
        .goldrush.qqp4_activation_disabled == .work.qqp4_activation_disabled and
        .goldrush.qqp4_activation_height == .work.qqp4_activation_height and
        .goldrush.qqp4_active_next_block == .work.qqp4_active_next_block and
        .lock_paths == $expected_locks
      ' "$file" >/dev/null
}

v3015_node30_make_safe_audit_receipt()
{
    local snapshot=$1 wallet_name selected_outpoint payout_script
    local wallet_sha outpoint_sha payout_script_sha public_sha semantics_sha finalization_sha
    wallet_name=$(jq -er '.wallet.walletname' "$snapshot") || return
    selected_outpoint=$(jq -er '.selected_utxo.txid + ":" + (.selected_utxo.vout|tostring)' \
      "$snapshot") || return
    payout_script=$(jq -er '.work.quantum_payout_script' "$snapshot") || return
    wallet_sha=$(v3015_node30_sha256_text "$wallet_name") || return
    outpoint_sha=$(v3015_node30_sha256_text "$selected_outpoint") || return
    payout_script_sha=$(v3015_node30_sha256_text "$payout_script") || return
    public_sha=$(v3015_sha256_file "$NODE30_PUBLIC_ARTIFACT_AUTHORITY") || return
    semantics_sha=$(v3015_sha256_file "$NODE30_SUCCESSOR_SEMANTICS_RECEIPT") || return
    finalization_sha=$(v3015_sha256_file "$NODE30_MAINTENANCE_FINALIZATION_RECEIPT") || return
    jq -c --arg source "$SOURCE_SHA" --arg image "$CANDIDATE_IMAGE_REF" \
      --arg marker "$NODE30_PAUSE_MARKER_SHA256" \
      --arg wrapper "$NODE30_PAUSE_WRAPPER_SHA256" \
      --arg worker "$NODE30_ORIGINAL_WORKER_SHA256" \
      --arg queue "$NODE30_QUEUE_ITEM_SHA256" \
      --arg payout "$NODE30_QUEUE_ADDRESS_SHA256" \
      --arg wallet_sha "$wallet_sha" --arg outpoint_sha "$outpoint_sha" \
      --arg payout_script_sha "$payout_script_sha" --arg public "$public_sha" \
      --arg semantics "$semantics_sha" --arg finalization "$finalization_sha" '
        {schema:1,kind:"v30.1.5-node30-free-claim-release-audit",source_sha:$source,
         candidate_image_ref:$image,node:30,observed_epoch:.captured_epoch,
         tip:.before_chain.bestblockhash,height:.before_chain.blocks,
         connections:.network.connections,wallet_identity_sha256:$wallet_sha,
         unlock_remaining_seconds:(.wallet.unlocked_until-.captured_epoch),
         selected_fee_outpoint_sha256:$outpoint_sha,
         queue_item_basename:.queue.basename,queue_item_sha256:$queue,
         queue_address_sha256:$payout,queue_attempts:.queue.record.attempts,
         quantum_payout_script_sha256:$payout_script_sha,
         pause_marker_sha256:$marker,pause_wrapper_sha256:$wrapper,worker_sha256:$worker,
         public_artifact_authority_sha256:$public,
         successor_semantics_receipt_sha256:$semantics,
         finalization_receipt_sha256:$finalization,
         ordinary_pow_enabled:false,ordinary_pow_hashrate:0,
         blocking_wallet_relevant_families:0,broadcast_records:0,
         witness_version:16,release_ready:true,action:"audit-only",
         marker_preserved:true,raw_transaction_exposed:false,payout_address_exposed:false}
      ' "$snapshot"
}

# The marker is never deleted. The prepared-release transaction moves the exact
# marker to the same-filesystem evidence directory while all worker and fleet
# locks remain held. A later failure moves the exact bytes back before locks are
# released.
v3015_node30_archive_pause_marker()
{
    local marker=$1 archive=$2 expected_sha=$3 marker_dir archive_dir
    marker_dir=$(dirname -- "$marker")
    archive_dir=$(dirname -- "$archive")
    [[ -f "$marker" && ! -L "$marker" && ! -e "$archive" && ! -L "$archive" ]] || return 1
    [[ "$(v3015_sha256_file "$marker")" == "$expected_sha" ]] || return 1
    [[ "$(stat -c '%d' -- "$marker_dir")" == "$(stat -c '%d' -- "$archive_dir")" ]] || return 1
    mv -T -- "$marker" "$archive" || return 1
    sync -f "$archive" && sync -f "$marker_dir" && sync -f "$archive_dir" || return 1
    [[ ! -e "$marker" && ! -L "$marker" && -f "$archive" && ! -L "$archive" &&
       "$(v3015_sha256_file "$archive")" == "$expected_sha" ]]
}

v3015_node30_restore_pause_marker()
{
    local archive=$1 marker=$2 expected_sha=$3 marker_dir archive_dir
    marker_dir=$(dirname -- "$marker")
    archive_dir=$(dirname -- "$archive")
    [[ -f "$archive" && ! -L "$archive" && ! -e "$marker" && ! -L "$marker" ]] || return 1
    [[ "$(v3015_sha256_file "$archive")" == "$expected_sha" ]] || return 1
    [[ "$(stat -c '%d' -- "$marker_dir")" == "$(stat -c '%d' -- "$archive_dir")" ]] || return 1
    mv -T -- "$archive" "$marker" || return 1
    sync -f "$marker" && sync -f "$marker_dir" && sync -f "$archive_dir" || return 1
    [[ ! -e "$archive" && ! -L "$archive" && -f "$marker" && ! -L "$marker" &&
       "$(v3015_sha256_file "$marker")" == "$expected_sha" ]]
}
