# shellcheck shell=bash
# Pure, read-only predicates shared by both canary phases and the offline verifier.
# shellcheck disable=SC2034 # Readonly package constants are consumed by sourcing callers.

export LC_ALL=C

# Candidate identity is injected by the reviewed environment. Committed defaults
# are deliberately unresolved so these bytes cannot authorize a stale candidate.
: "${HOTFIX_CANDIDATE_SOURCE_SHA:=__40_HEX_CANDIDATE_SOURCE_SHA__}"
: "${HOTFIX_CANDIDATE_RELEASE_VERSION:=__CANDIDATE_RELEASE_SEMVER__}"
readonly HOTFIX_CANDIDATE_SOURCE_SHA HOTFIX_CANDIDATE_RELEASE_VERSION
readonly HOTFIX_CANDIDATE_SHORT_SHA="${HOTFIX_CANDIDATE_SOURCE_SHA:0:12}"
readonly HOTFIX_EXPECTED_RELEASE_VERSION='30.1.5'
readonly HOTFIX_CANDIDATE_CLASSIFICATION='V30_1_5_CANDIDATE_CANARY_ONLY'
readonly HOTFIX_CANDIDATE_WORKFLOW_PATH='.github/workflows/v30.1.5-candidate-linux.yml'
readonly IMMUTABLE_V3014_SOURCE_SHA='13262151077cce3f72d07d17dc7725b2b6a8e1ab'
readonly IMMUTABLE_V3014_IMAGE_DIGEST='sha256:7a384dd5f12c15fb41b36868d946007524bebf97650883d533635658641e04a2'
readonly IMMUTABLE_V3014_IMAGE_ID='sha256:620146d14a57fe0d5d1fc29a7d913d47787ba924c96ba06eeb1ddbe8efb73909'
readonly IMMUTABLE_V3014_IMAGE_REF="qqblackcoin/blackcoin-v4-gui@${IMMUTABLE_V3014_IMAGE_DIGEST}"
readonly HOTFIX_CANDIDATE_PREFIX="Blackcoin-${HOTFIX_CANDIDATE_RELEASE_VERSION}-candidate-${HOTFIX_CANDIDATE_SHORT_SHA}"
readonly HOTFIX_CANDIDATE_OCI_ARCHIVE_NAME="blackcoin-v4-gui-${HOTFIX_CANDIDATE_RELEASE_VERSION}-candidate-${HOTFIX_CANDIDATE_SHORT_SHA}.oci.tar"
readonly HOTFIX_CANDIDATE_IMAGE_VERSION="${HOTFIX_CANDIDATE_RELEASE_VERSION}-candidate-${HOTFIX_CANDIDATE_SHORT_SHA}"
readonly HOTFIX_CANDIDATE_IMAGE_TAG="${HOTFIX_CANDIDATE_IMAGE_VERSION}-ci1"
readonly HOTFIX_CANDIDATE_IMAGE_REF="qqblackcoin/blackcoin-v4-gui:${HOTFIX_CANDIDATE_IMAGE_TAG}"
readonly HOTFIX_SIGNING_FINGERPRINT='SHA256:jAkpBudDw+ntWHSUx3e1KY+czAFjnlaPxQtRFtptL70'
readonly HOTFIX_ZERO_TXID='0000000000000000000000000000000000000000000000000000000000000000'
readonly IMMUTABLE_START_GUI_SHA256='ae050a0169059c8ca461b97b31bfbe2066052a02b1bf2de968283b1f3ddcfdb3'
# This hash includes the exact single terminal LF in the bash -c body.
readonly HOTFIX_CANDIDATE_ENTRYPOINT_BODY_SHA256='753acc9904b48c411f5514abface930f79d72d00c9d73e91435a6511877d47b4'
readonly HOTFIX_CANDIDATE_ENTRYPOINT_SENTINEL='node27-hotfix-candidate'
readonly HOTFIX_UNLOCK_HELPER_SHA256='acf28446e842fd0fa92b06c2ebc182e9da38fcde7bac06dd920d50a33e4e3dd1'
readonly HOTFIX_PHASE_A_CONFIRMATION="v${HOTFIX_CANDIDATE_RELEASE_VERSION}-hotfix-candidate-${HOTFIX_CANDIDATE_SHORT_SHA}-node27-phase-a-rewind-safe"
readonly HOTFIX_PHASE_B_CONFIRMATION_PREFIX="v${HOTFIX_CANDIDATE_RELEASE_VERSION}-hotfix-candidate-${HOTFIX_CANDIDATE_SHORT_SHA}-node27-promote-no-data-rewind:"

hotfix_valid_sha256()
{
    [[ "${1:-}" =~ ^[0-9a-f]{64}$ ]]
}

hotfix_valid_git_sha()
{
    [[ "${1:-}" =~ ^[0-9a-f]{40}$ ]]
}

hotfix_valid_image_id()
{
    [[ "${1:-}" =~ ^sha256:[0-9a-f]{64}$ ]]
}

hotfix_valid_nonce()
{
    [[ "${1:-}" =~ ^[0-9a-f]{32}$ ]]
}

hotfix_candidate_identity_is_resolved()
{
    hotfix_valid_git_sha "$HOTFIX_CANDIDATE_SOURCE_SHA" &&
        [[ "$HOTFIX_CANDIDATE_SOURCE_SHA" != "$IMMUTABLE_V3014_SOURCE_SHA" ]] &&
        [[ "$HOTFIX_CANDIDATE_RELEASE_VERSION" == "$HOTFIX_EXPECTED_RELEASE_VERSION" ]] &&
        [[ "$HOTFIX_CANDIDATE_PREFIX" == \
           "Blackcoin-${HOTFIX_CANDIDATE_RELEASE_VERSION}-candidate-${HOTFIX_CANDIDATE_SOURCE_SHA:0:12}" ]] &&
        [[ "$HOTFIX_CANDIDATE_OCI_ARCHIVE_NAME" == \
           "blackcoin-v4-gui-${HOTFIX_CANDIDATE_RELEASE_VERSION}-candidate-${HOTFIX_CANDIDATE_SOURCE_SHA:0:12}.oci.tar" ]] &&
        [[ "$HOTFIX_CANDIDATE_IMAGE_VERSION" == \
           "${HOTFIX_CANDIDATE_RELEASE_VERSION}-candidate-${HOTFIX_CANDIDATE_SOURCE_SHA:0:12}" ]] &&
        [[ "$HOTFIX_CANDIDATE_IMAGE_TAG" == "${HOTFIX_CANDIDATE_IMAGE_VERSION}-ci1" ]] &&
        [[ "$HOTFIX_CANDIDATE_IMAGE_REF" == \
           "qqblackcoin/blackcoin-v4-gui:${HOTFIX_CANDIDATE_IMAGE_TAG}" ]]
}

hotfix_candidate_artifact_name()
{
    local attempt="${1:-}"
    [[ "$attempt" =~ ^[1-9][0-9]*$ ]] || return 1
    printf 'v%s-candidate-linux-x86_64-%s-attempt-%s\n' \
        "$HOTFIX_CANDIDATE_RELEASE_VERSION" "$HOTFIX_CANDIDATE_SOURCE_SHA" "$attempt"
}

hotfix_sha256_file()
{
    sha256sum "$1" | awk '{print $1}'
}

hotfix_exact_phase_a_flags_json()
{
    jq -ce -n '["-walletbroadcast=0","-blocksonly=1","-staking=0",
        "-autostartstaking=0","-powmining=0","-qqautoshadowsignal=0",
        "-qqautodemurrageattest=0"]'
}

hotfix_exact_phase_b_flags_json()
{
    jq -ce -n '["-walletbroadcast=1","-autostartstaking=0","-powmining=0"]'
}

hotfix_candidate_pow_json_is_valid()
{
    local mining="$1" phase="$2"
    [[ "$phase" == active || "$phase" == off ]] || return 1
    jq -e -n --arg phase "$phase" --arg zero "$HOTFIX_ZERO_TXID" \
        --argjson mining "$mining" '
        def integer: type == "number" and floor == .;
        def uint: integer and . >= 0;
        def amount: type == "number" and . >= 0;
        def hex64: type == "string" and test("^[0-9a-f]{64}$");
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
        def gate:
          ((["mining_gate_coherent","mining_gate_action","mining_gate_can_submit",
             "mining_gate_database_ambiguous","mining_gate_unresolved_components",
             "mining_gate_live_claims","mining_gate_eligible_claims",
             "mining_gate_family_claims","mining_gate_unsafe_claims",
             "mining_gate_unsafe_components","mining_gate_relay_txid",
             "mining_gate_lineage_head_txid",
             "mining_gate_candidate_state_fingerprint"] - keys) | length) == 0 and
          .mining_gate_coherent == true and
          (.mining_gate_action as $a |
            ["create_new_anchor","wait_for_live","wait_for_next_tip",
             "relay_existing","refresh_same_anchor"] | index($a) != null) and
          (.mining_gate_can_submit | type) == "boolean" and
          (if (.mining_gate_action == "create_new_anchor" or
               .mining_gate_action == "refresh_same_anchor")
           then .mining_gate_can_submit == true
           elif .mining_gate_action == "wait_for_next_tip" then true
           else .mining_gate_can_submit == false end) and
          .mining_gate_database_ambiguous == false and
          (.mining_gate_unresolved_components | uint) and
          (.mining_gate_live_claims | uint) and
          (.mining_gate_eligible_claims | uint) and
          (.mining_gate_family_claims | uint) and
          (.mining_gate_unsafe_claims | integer and . == 0) and
          (.mining_gate_unsafe_components | integer and . == 0) and
          (.mining_gate_relay_txid | hex64) and
          (.mining_gate_lineage_head_txid | hex64) and
          (.mining_gate_candidate_state_fingerprint | hex64) and
          .mining_gate_candidate_state_fingerprint != $zero and
          (if .mining_gate_action == "create_new_anchor" then
             .mining_gate_lineage_head_txid == $zero and
             .mining_gate_unresolved_components == 0 and
             .mining_gate_live_claims == 0 and .mining_gate_eligible_claims == 0 and
             .mining_gate_family_claims == 0
           else
             .mining_gate_lineage_head_txid != $zero and
             .mining_gate_unresolved_components == 1 and .mining_gate_family_claims >= 1
           end) and
          (if .mining_gate_action == "relay_existing"
           then .mining_gate_relay_txid != $zero
           elif .mining_gate_action == "wait_for_next_tip" then true
           else .mining_gate_relay_txid == $zero end) and
          ((.mining_gate_action == "wait_for_next_tip" and
            .mining_gate_can_submit == true and
            .mining_gate_relay_txid != $zero) | not) and
          (if .mining_gate_action == "wait_for_live"
           then .mining_gate_live_claims >= 1
           elif .mining_gate_action == "relay_existing"
           then .mining_gate_live_claims == 0 and .mining_gate_eligible_claims >= 1
           elif .mining_gate_action == "refresh_same_anchor"
           then .mining_gate_live_claims == 0
           elif .mining_gate_action == "wait_for_next_tip"
           then .mining_gate_live_claims == 0 and
             (if .mining_gate_relay_txid == $zero
              then .mining_gate_can_submit == true
              else .mining_gate_can_submit == false and
                .mining_gate_eligible_claims >= 1 end)
           else true end);
        $mining | type == "object" and
          ((keys | sort) == (pow_keys | sort)) and
          (.enabled | type) == "boolean" and
          (.autostart | type) == "boolean" and .autostart == false and
          (.allow_automatic_quantum_key_creation | type) == "boolean" and
          .allow_automatic_quantum_key_creation == false and
          (.state | type) == "string" and
          (.threads | integer and . == 1) and
          (.cpu_percent | type == "number" and . == 1) and
          (.hashrate | type == "number" and . >= 0) and
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
          (.claim_inventory_wallet_tip_matches | type) == "boolean" and
          (.claim_recovery_database_outcome_ambiguous | type) == "boolean" and
          .claim_recovery_database_outcome_ambiguous == false and gate and
          (.configured_stake_reserve_coins | uint) and
          (.mature_stakeable_legacy_coins | uint) and
          (.mature_stakeable_legacy_weight | amount) and
          (.reserved_stake_coins | uint) and (.reserved_stake_weight | amount) and
          (.claim_coins_after_stake_reserve | uint) and
          (.last_stake_coin_guard | type) == "boolean" and
          (.stake_reserve_snapshot_available | type) == "boolean" and
          if $phase == "active" then
            .enabled == true and
            (.state == "ready" or .state == "hashing" or
             .state == "claim_in_flight") and
            (if (.mining_gate_action == "wait_for_live" or
                 .mining_gate_action == "wait_for_next_tip" or
                 .mining_gate_action == "relay_existing")
             then .state == "claim_in_flight" and .hashrate == 0
             else true end) and
            .stake_reserve_snapshot_available == true
          else
            .enabled == false and .state == "disabled" and .hashrate == 0
          end
    ' >/dev/null
}

hotfix_candidate_recovery_json_is_valid()
{
    local recovery="$1" expected_fee="$2"
    jq -e -n --argjson recovery "$recovery" --argjson fee "$expected_fee" '
        def integer: type == "number" and floor == .;
        def uint: integer and . >= 0;
        def amount: type == "number" and . >= 0;
        def hex64: type == "string" and test("^[0-9a-f]{64}$");
        def recovery_keys: [
          "active_height","active_tip","actionable_quarantined_claims",
          "automatic_actions_in_window","automatic_fee_exposure_in_window",
          "blocking_components","blocking_quarantined_claims","chain_ready",
          "claims_recycled","component_details","components",
          "confirmed_automatic_resolutions","confirmed_manual_resolutions",
          "confirmed_resolution_fees","database_outcome_ambiguous",
          "indeterminate_quarantined_claims","live_claim_objects","policy",
          "pending_automatic_resolutions","pending_manual_resolutions",
          "policy_authoritative","policy_state_detail","policy_state_status",
          "quarantined_claim_objects","raw_claim_objects","raw_quarantined_claims",
          "reconciled_descendant_claims","resolved_components",
          "resolved_on_active_chain_claims","retired_claim_objects","retired_components",
          "unanchored_claim_txids","wallet_generation","wallet_processed_height",
          "wallet_processed_tip","wallet_tip_matches"];
        def component_keys: [
          "all_claims_expired_locally_retired","all_claims_explicitly_provenanced",
          "all_claims_quarantined","all_claims_zero_payment_retirable","anchor",
          "anchor_authenticated","anchor_unspent","claim_txids","classification",
          "component_fingerprint","descendant_claims","generation_fingerprint",
          "has_revalidating_unbound_proof","minimum_stale_depth","nodes",
          "ordinary_or_mixed_txids","resolution_txids","root_claim_txids",
          "stale_depth_known"];
        def node_keys: [
          "abandoned","active_chain_confirmed","authored_metadata_valid",
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
        ($fee | amount) and
        ($recovery | type) == "object" and
        (($recovery | keys | sort) == (recovery_keys | sort)) and
        ($recovery.policy | type) == "object" and
        (($recovery.policy | keys | sort) == ([
          "aggregate_batch_fee_cap","automatic_authorized","automatic_enabled",
          "choice_recorded","max_actions_per_window","max_fee_per_resolution",
          "minimum_stale_blocks","mode","rolling_fee_budget",
          "rolling_fee_window_seconds","version"] | sort)) and
        ($recovery.policy.version | integer and . == 1) and
        ($recovery.policy.mode | type == "string" and
          (. == "unset" or . == "pause_and_ask")) and
        ($recovery.policy.choice_recorded | type) == "boolean" and
        ($recovery.policy.automatic_enabled | type) == "boolean" and
        ($recovery.policy.automatic_authorized | type) == "boolean" and
        (if $recovery.policy.mode == "unset"
         then $recovery.policy.choice_recorded == false
         else $recovery.policy.choice_recorded == true end) and
        $recovery.policy.automatic_enabled == false and
        ($recovery.policy.max_fee_per_resolution | amount) and
        ($recovery.policy.aggregate_batch_fee_cap | amount) and
        ($recovery.policy.rolling_fee_budget | amount) and
        ($recovery.policy.rolling_fee_window_seconds | uint) and
        ($recovery.policy.max_actions_per_window | uint) and
        ($recovery.policy.minimum_stale_blocks | uint) and
        ($recovery.policy_authoritative | type) == "boolean" and
        $recovery.policy_authoritative == true and
        $recovery.policy.automatic_authorized == false and
        ($recovery.policy_state_status | type == "string") and
        $recovery.policy_state_status == "success" and
        ($recovery.policy_state_detail | type == "string") and
        ($recovery.database_outcome_ambiguous | type) == "boolean" and
        $recovery.database_outcome_ambiguous == false and
        ($recovery.chain_ready | type) == "boolean" and
        ($recovery.wallet_tip_matches | type) == "boolean" and
        $recovery.chain_ready == true and $recovery.wallet_tip_matches == true and
        ($recovery.active_tip | hex64) and $recovery.active_tip !=
          "0000000000000000000000000000000000000000000000000000000000000000" and
        ($recovery.active_height | uint) and
        ($recovery.wallet_processed_tip | hex64) and
        ($recovery.wallet_processed_height | uint) and
        $recovery.active_tip == $recovery.wallet_processed_tip and
        $recovery.active_height == $recovery.wallet_processed_height and
        ($recovery.wallet_generation | uint) and
        all(["raw_quarantined_claims","blocking_quarantined_claims",
             "actionable_quarantined_claims","resolved_on_active_chain_claims",
             "indeterminate_quarantined_claims","components","raw_claim_objects",
             "live_claim_objects","quarantined_claim_objects","blocking_components",
             "retired_claim_objects","retired_components","resolved_components",
             "pending_manual_resolutions","pending_automatic_resolutions",
             "confirmed_manual_resolutions","confirmed_automatic_resolutions",
             "automatic_actions_in_window","reconciled_descendant_claims",
             "claims_recycled"][]; $recovery[.] | uint) and
        $recovery.blocking_quarantined_claims ==
          ($recovery.actionable_quarantined_claims +
           $recovery.indeterminate_quarantined_claims) and
        $recovery.raw_quarantined_claims >= $recovery.blocking_quarantined_claims and
        $recovery.raw_claim_objects >= $recovery.live_claim_objects and
        $recovery.raw_claim_objects >= $recovery.quarantined_claim_objects and
        ($recovery.confirmed_resolution_fees | amount) and
        $recovery.confirmed_resolution_fees == $fee and
        ($recovery.automatic_fee_exposure_in_window | amount) and
        ($recovery.component_details | type == "array") and
        all($recovery.component_details[]; . as $component |
          type == "object" and (keys | sort) == (component_keys | sort) and
          (.anchor | type) == "object" and
          (.anchor | keys | sort) == ["amount","scriptPubKey","txid","vout"] and
          (.anchor.txid | hex64) and (.anchor.vout | uint) and
          (.anchor.amount | amount) and
          (.anchor.scriptPubKey | type == "string" and test("^([0-9a-f]{2})+$")) and
          (.generation_fingerprint | hex64) and
          (.component_fingerprint | hex64) and
          (.classification | IN("live","transient","indeterminate",
            "current_branch_ineligible","terminal_on_pinned_tip",
            "retired_on_active_branch","resolution_pending","resolved_on_active_chain")) and
          all([.claim_txids,.root_claim_txids,.resolution_txids,
               .ordinary_or_mixed_txids][];
            type == "array" and all(.[]; hex64) and (unique | length) == length) and
          (.descendant_claims | uint) and (.minimum_stale_depth | uint) and
          (.stale_depth_known | type) == "boolean" and
          (.anchor_authenticated | type) == "boolean" and
          (.anchor_unspent | type) == "boolean" and
          (.all_claims_quarantined | type) == "boolean" and
          (.all_claims_explicitly_provenanced | type) == "boolean" and
          (.all_claims_zero_payment_retirable | type) == "boolean" and
          (.all_claims_expired_locally_retired | type) == "boolean" and
          (.has_revalidating_unbound_proof | type) == "boolean" and
          (.nodes | type == "array") and
          all(.nodes[];
            type == "object" and (keys | sort) == (node_keys | sort) and
            (.txid | hex64) and
            (.kind | IN("claim","managed_resolution","legacy_resolution","ordinary")) and
            (.provenance | IN("explicit_authored","explicit_adopted",
              "legacy_wallet_authored","unknown")) and
            (.disposition | type == "string" and length > 0) and
            (.proof_mode | IN("pow","pos","unknown","malformed")) and
            (.proof_version | uint) and (.proof_origin_height | integer) and
            (.proof_origin_previous_block_hash | hex64) and
            (.relay_expiry_time | integer) and (.lineage_family_fingerprint | hex64) and
            (.lineage_root_txid | hex64) and (.lineage_parent_txid | hex64) and
            (.lineage_ordinal | uint) and (.stale_depth | uint) and
            all([.proof_may_revalidate_on_descendant,.active_chain_confirmed,.in_mempool,
                 .quarantined,.expected_shape,.wallet_authored,.wallet_from_me,
                 .authored_metadata_valid,.authored_tip_active_branch_bound,
                 .claim_descriptor_valid,.proof_evaluation_skipped_resolved_anchor,
                 .proof_origin_bound,.proof_input_bound,.exact_authored_carrier_shape,
                 .relay_ttl_expired,.lineage_metadata_present,.lineage_metadata_valid,
                 .abandoned,.expired_locally_retired,.stale_depth_known,
                 .resolution_metadata_valid,.resolution_relay_authorized][];
              type == "boolean")) and
          ([.nodes[] | select(.kind == "claim") | .txid] | sort) ==
            (.claim_txids | sort) and
          ([.nodes[] | select(.kind == "managed_resolution" or
            .kind == "legacy_resolution") | .txid] | sort) ==
            (.resolution_txids | sort) and
          ([.nodes[] | select(.kind == "ordinary") | .txid] | sort) ==
            (.ordinary_or_mixed_txids | sort)) and
        ($recovery.unanchored_claim_txids | type == "array" and
          length == 0 and all(.[]; hex64))
    ' >/dev/null
}

hotfix_phase_a_staking_json_is_disabled()
{
    jq -e -n --argjson staking "$1" '
        def integer: type == "number" and floor == .;
        def required: ["active_blocks","allow_automatic_quantum_key_creation",
          "automatic_demurrage_attestation","automatic_qqsignal","automatic_redelegation",
          "autostart_staking","autostart_staking_source","blocks","chain","chainstate_cached",
          "consensus_demurrage_automatic","difficulty","eligible","enabled","expectedtime",
          "netstakeweight","pooledtx","search-interval","staking","staking_reason",
          "staking_snapshot_current","staking_snapshot_sequence","staking_state","warnings",
          "weight","weight_cache_height","weight_cached","worker_running"];
        $staking | type == "object" and
        ((required - keys) | length) == 0 and
        ((keys - (required + ["currentblocktx","currentblockweight"])) | length) == 0 and
        .enabled == false and .staking == false and .worker_running == false and
        (.enabled|type)=="boolean" and (.staking|type)=="boolean" and
        (.worker_running|type)=="boolean" and .staking_state == "disabled" and
        (.staking_reason|type)=="string" and (.eligible|type)=="boolean" and
        .eligible == false and (.staking_snapshot_current|type)=="boolean" and
        (.staking_snapshot_sequence|integer and .>=0) and
        (.active_blocks|integer and .>=0) and .autostart_staking == false and
        .autostart_staking_source == "autostartstaking" and
        .automatic_qqsignal == false and
        .automatic_demurrage_attestation == false and
        .automatic_redelegation == false and
        .allow_automatic_quantum_key_creation == false and
        .consensus_demurrage_automatic == true and
        all(["automatic_qqsignal","automatic_demurrage_attestation",
             "automatic_redelegation","allow_automatic_quantum_key_creation",
             "consensus_demurrage_automatic","autostart_staking"][];
            $staking[.]|type=="boolean") and
        (.blocks|integer and .>=0) and (.pooledtx|integer and .>=0) and
        ((.currentblocktx? == null) or (.currentblocktx | integer and . >= 0)) and
        ((.currentblockweight? == null) or (.currentblockweight | integer and . >= 0)) and
        (.difficulty|type)=="number" and (."search-interval"|integer and .>=0) and
        (.weight|integer and .>=0) and (.weight_cached|type)=="boolean" and
        (.weight_cache_height|integer and .>=-1) and
        (.netstakeweight|integer and .>=0) and (.expectedtime|integer and .>=0) and
        (.chainstate_cached|type)=="boolean" and (.chain|type)=="string" and
        (.warnings|type)=="string"
    ' >/dev/null
}

hotfix_phase_b_staking_json_is_active()
{
    jq -e -n --argjson staking "$1" '
        def integer: type == "number" and floor == .;
        def required: ["active_blocks","allow_automatic_quantum_key_creation",
          "automatic_demurrage_attestation","automatic_qqsignal","automatic_redelegation",
          "autostart_staking","autostart_staking_source","blocks","chain","chainstate_cached",
          "consensus_demurrage_automatic","difficulty","eligible","enabled","expectedtime",
          "netstakeweight","pooledtx","search-interval","staking","staking_reason",
          "staking_snapshot_current","staking_snapshot_sequence","staking_state","warnings",
          "weight","weight_cache_height","weight_cached","worker_running"];
        $staking | type == "object" and
        ((required - keys) | length) == 0 and
        ((keys - (required + ["currentblocktx","currentblockweight"])) | length) == 0 and
        .enabled == true and .staking == true and .worker_running == true and
        .eligible == true and .staking_snapshot_current == true and
        .staking_state == "searching" and
        (.staking_reason|type)=="string" and
        (.staking_snapshot_sequence|integer and .>0) and
        (.active_blocks|integer and .>=0) and (.blocks|integer and .>=0) and
        .active_blocks == .blocks and (.autostart_staking|type)=="boolean" and
        (.autostart_staking_source |
          IN("autostartstaking","legacy_staking","default_off")) and
        (.weight | integer) and .weight > 0 and
        .weight_cached == true and .automatic_qqsignal == false and
        .automatic_demurrage_attestation == false and
        .automatic_redelegation == false and
        .allow_automatic_quantum_key_creation == false and
        .consensus_demurrage_automatic == true and
        all(["enabled","staking","worker_running","eligible",
             "staking_snapshot_current","autostart_staking","weight_cached",
             "automatic_qqsignal","automatic_demurrage_attestation",
             "automatic_redelegation","allow_automatic_quantum_key_creation",
             "consensus_demurrage_automatic"][]; $staking[.]|type=="boolean") and
        (.pooledtx|integer and .>=0) and (.difficulty|type)=="number" and
        ((.currentblocktx? == null) or (.currentblocktx | integer and . >= 0)) and
        ((.currentblockweight? == null) or (.currentblockweight | integer and . >= 0)) and
        (."search-interval"|integer and .>=0) and
        (.weight_cache_height|integer and .>=0) and
        (.netstakeweight|integer and .>=0) and (.expectedtime|integer and .>=0) and
        (.chainstate_cached|type)=="boolean" and (.chain|type)=="string" and
        (.warnings|type)=="string"
    ' >/dev/null
}

hotfix_phase_b_progress_file_is_valid()
{
    local file="$1" expected_nonce="$2" pow_mode="$3" sample fee
    [[ -f "$file" && ! -L "$file" && ( "$pow_mode" == active || "$pow_mode" == off ) ]] ||
        return 1
    jq -e --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" --arg nonce "$expected_nonce" '
        def integer: type == "number" and floor == .;
        def hex64: type == "string" and test("^[0-9a-f]{64}$");
        type == "object" and
        (keys | sort) == (["candidate_source_sha","p2p_ready_continuously","phase",
          "pos_active_continuously","promotion_nonce","samples","schema","tip_changes",
          "wallet_chain_synchronized_continuously"] | sort) and
        (.schema | integer and . == 1) and .phase == "B" and
        .candidate_source_sha == $source and .promotion_nonce == $nonce and
        ($nonce | test("^[0-9a-f]{32}$")) and
        (.samples | type == "array" and length == 4) and
        ([.samples[].sample] == [1,2,3,4]) and
        all(.samples[];
          (keys | sort) == (["chain","network","observed_epoch","pow","recovery",
            "sample","staking","wallet"] | sort) and
          (.sample | integer and . >= 1 and . <= 4) and
          (.observed_epoch | integer and . > 0) and
          (.chain | type) == "object" and .chain.chain == "main" and
          (.chain.blocks | integer and . >= 0) and
          (.chain.headers | integer and . >= 0) and
          .chain.blocks == .chain.headers and
          (.chain.bestblockhash | hex64) and
          (.chain.chainwork | hex64) and .chain.initialblockdownload == false and
          (.network | type) == "object" and
          (.network.networkactive | type) == "boolean" and
          (.network.connections_out | integer and . >= 3) and
          (.wallet | type) == "object" and .wallet.walletname == "" and
          .wallet.private_keys_enabled == true and .wallet.scanning == false and
          .wallet.unlocked_staking_only == false and
          (.wallet.unlocked_until | integer) and
          .wallet.unlocked_until > .observed_epoch and
          .recovery.active_tip == .chain.bestblockhash and
          .recovery.wallet_processed_tip == .chain.bestblockhash and
          .pow.claim_inventory_tip == .chain.bestblockhash and
          .staking.blocks == .chain.blocks and .staking.active_blocks == .chain.blocks and
          .staking.autostart_staking == false and
          .staking.autostart_staking_source == "autostartstaking" and
          .pow.raw_quarantined_claims == .recovery.raw_quarantined_claims and
          .pow.blocking_quarantined_claims == .recovery.blocking_quarantined_claims and
          .pow.actionable_quarantined_claims == .recovery.actionable_quarantined_claims and
          .pow.resolved_on_active_chain_claims == .recovery.resolved_on_active_chain_claims and
          .pow.indeterminate_quarantined_claims == .recovery.indeterminate_quarantined_claims and
          .pow.claim_components == .recovery.components and
          .pow.pending_manual_resolutions == .recovery.pending_manual_resolutions and
          .pow.pending_automatic_resolutions == .recovery.pending_automatic_resolutions and
          .pow.claims_auto_resolved == .recovery.confirmed_automatic_resolutions and
          .pow.claims_recycled == .recovery.claims_recycled and
          .pow.cumulative_resolution_fees == .recovery.confirmed_resolution_fees and
          .pow.claim_recovery_database_outcome_ambiguous ==
            .recovery.database_outcome_ambiguous) and
        ([.samples[].chain.blocks] as $h |
          all(range(1;($h|length)); $h[.] > $h[.-1])) and
        ([.samples[].chain.bestblockhash] as $t |
          ($t | unique | length) == 4 and
          all(range(1;($t|length)); $t[.] != $t[.-1])) and
        ([.samples[].chain.chainwork] as $w |
          all(range(1;($w|length)); $w[.] > $w[.-1])) and
        ([.samples[].observed_epoch] as $o |
          all(range(1;($o|length)); $o[.] >= $o[.-1])) and
        (.tip_changes | integer and . == 3) and
        (.wallet_chain_synchronized_continuously | type) == "boolean" and
        .wallet_chain_synchronized_continuously == true and
        (.pos_active_continuously | type) == "boolean" and
        .pos_active_continuously == true and
        (.p2p_ready_continuously | type) == "boolean" and
        .p2p_ready_continuously == true
    ' "$file" >/dev/null || return 1
    while IFS= read -r sample; do
        fee=$(jq -ce '.recovery.confirmed_resolution_fees' <<<"$sample") || return 1
        hotfix_candidate_recovery_json_is_valid \
            "$(jq -ce '.recovery' <<<"$sample")" "$fee" || return 1
        hotfix_phase_b_staking_json_is_active "$(jq -c '.staking' <<<"$sample")" || return 1
        hotfix_candidate_pow_json_is_valid "$(jq -c '.pow' <<<"$sample")" "$pow_mode" || return 1
    done < <(jq -ce '.samples[]' "$file")
}

hotfix_unlock_helper_audit_file_is_valid()
{
    local file="$1"
    [[ -f "$file" && ! -L "$file" ]] || return 1
    jq -e --arg sha "$HOTFIX_UNLOCK_HELPER_SHA256" '
        def integer: type == "number" and floor == .;
        type == "object" and
        (keys | sort) == (["bash_syntax","classification","forbidden_tokens","gid",
          "indirection_detected","invoked_during_audit","lines","mode",
          "mutating_rpc_methods","path","readonly_rpc_methods","regular","run_nonce",
          "schema","secret_captured","sha256","size","symlink","uid",
          "walletpassphrase_staking_only"] | sort) and
        (.schema | integer and . == 1) and
        (.run_nonce | type == "string" and test("^[0-9a-f]{32}$")) and
        .path == "/boot/config/plugins/blackcoin-quantum-nodes/blackcoin_node_normal_unlock.sh" and
        .sha256 == $sha and .regular == true and .symlink == false and
        .uid == 0 and .gid == 0 and .mode == "600" and
        (.regular|type)=="boolean" and (.symlink|type)=="boolean" and
        (.uid | integer and . == 0) and (.gid | integer and . == 0) and
        (.size | integer and . == 3206) and (.lines | integer and . == 54) and
        .bash_syntax == true and .classification == "unlock_only_normal_walletpassphrase" and
        .mutating_rpc_methods == ["walletpassphrase"] and
        .readonly_rpc_methods == ["getstakinginfo","getwalletinfo","listwallets"] and
        .walletpassphrase_staking_only == false and
        .forbidden_tokens == [] and .indirection_detected == false and
        .secret_captured == false and .invoked_during_audit == false
    ' "$file" >/dev/null
}

hotfix_nonpublication_file_is_valid()
{
    local file="$1" expected_nonce="$2"
    local evidence_base suffix expected_sha actual_sha probe_file
    [[ -f "$file" && ! -L "$file" ]] || return 1
    evidence_base=${file%.json}
    [[ "$evidence_base" != "$file" ]] || return 1
    jq -e --arg nonce "$expected_nonce" '
        def hex64: type == "string" and test("^[0-9a-f]{64}$");
        type == "object" and
        (keys | sort) == (["all_peer_relaytxes_false","blocksonly",
          "candidate_rpc_capable_processes","config_no_walletbroadcast_override",
          "guard_authority_observed","guard_start_suspended","includeconf_rejected",
          "gui_vnc_external_probe","keeper_api_suspended","keeper_api_suspension_basis",
          "interactive_services_stopped","ipv4_firewall_evidence_sha256",
          "ipv6_firewall_evidence_sha256","listener_evidence_sha256","network_localrelay",
          "networkactive","nft_evidence_sha256","phase","port_binding_evidence_sha256",
          "probe_results","probe_target_evidence_sha256","relay_forcerelay_peer_ids","rpc_external_probe",
          "rpc_auth_boundary_evidence_sha256","rpc_auth_material_unavailable_to_shared_namespace",
          "rpc_host_port_bindings","rpc_loopback_only","rpc_shared_namespace_port_bindings",
          "run_nonce","schema","suspension_nonce","unknown_surfaces",
          "vpn_firewall_blocks_gui_vnc","vpn_namespace_port_bindings",
          "vpn_mount_evidence_sha256","vpn_namespace_sharers","walletnotify",
          "zmq_transaction_endpoints"] | sort) and
        .schema == 1 and .phase == "A" and .run_nonce == $nonce and
        ($nonce | test("^[0-9a-f]{32}$")) and
        .rpc_loopback_only == true and .rpc_host_port_bindings == [] and
        .rpc_shared_namespace_port_bindings == ["127.0.0.1:15715/tcp"] and
        .rpc_external_probe == "host-and-vpn-inaccessible-shared-netns-authenticated-only" and
        .gui_vnc_external_probe == "inaccessible" and
        .vpn_namespace_port_bindings == [] and
        .vpn_firewall_blocks_gui_vnc == true and
        .vpn_namespace_sharers == ["blackcoin-v4-gui-27"] and
        .keeper_api_suspended == true and .guard_start_suspended == true and
        .keeper_api_suspension_basis == ["four-locks-held","guard-contract-hash",
          "shared-netns-rpc-auth-boundary","rpc-host-vpn-unpublished"] and
        .suspension_nonce == $nonce and
        (.probe_results | type == "array" and length == 4) and
        ([.probe_results[].path] | sort) ==
          (["host-loopback","host-lan","vpn-ingress","shared-namespace"] | sort) and
        all(.probe_results[0:3][];
          (keys | sort) == ["path","reachable","status"] and
          (.path | IN("host-loopback","host-lan","vpn-ingress")) and
          .reachable == false and .status == "observed") and
        (.probe_results[3] | keys | sort) == (["cookie_mount_absent",
          "gui_vnc_ports_closed","path","reachable","status","tcp_rpc_reachable",
          "unauthenticated_rpc_rejected"] | sort) and
        .probe_results[3] == {path:"shared-namespace",reachable:true,
          status:"authenticated-only",tcp_rpc_reachable:true,
          unauthenticated_rpc_rejected:true,gui_vnc_ports_closed:true,
          cookie_mount_absent:true} and
        .walletnotify == null and .zmq_transaction_endpoints == [] and
        .relay_forcerelay_peer_ids == [] and .all_peer_relaytxes_false == true and
        .network_localrelay == false and .networkactive == true and
        .blocksonly == true and .config_no_walletbroadcast_override == true and
        .unknown_surfaces == [] and .includeconf_rejected == true and
        .interactive_services_stopped == true and .guard_authority_observed == true and
        .rpc_auth_material_unavailable_to_shared_namespace == true and
        .candidate_rpc_capable_processes == ["blackcoin-qt"] and
        all([.listener_evidence_sha256,.ipv4_firewall_evidence_sha256,
             .ipv6_firewall_evidence_sha256,.nft_evidence_sha256,
             .port_binding_evidence_sha256,.vpn_mount_evidence_sha256,
             .rpc_auth_boundary_evidence_sha256,.probe_target_evidence_sha256][]; hex64)
    ' "$file" >/dev/null || return 1
    while IFS=':' read -r suffix key; do
        [[ -n "$suffix" && -n "$key" ]] || return 1
        probe_file="${evidence_base}.${suffix}"
        [[ -f "$probe_file" && ! -L "$probe_file" ]] || return 1
        expected_sha=$(jq -er --arg key "$key" '.[$key]' "$file") || return 1
        actual_sha=$(hotfix_sha256_file "$probe_file") || return 1
        [[ "$actual_sha" == "$expected_sha" ]] || return 1
    done <<'EOF'
listeners.txt:listener_evidence_sha256
iptables.txt:ipv4_firewall_evidence_sha256
ip6tables.txt:ipv6_firewall_evidence_sha256
nft.txt:nft_evidence_sha256
port-bindings.json:port_binding_evidence_sha256
vpn-mounts.json:vpn_mount_evidence_sha256
rpc-auth-boundary.json:rpc_auth_boundary_evidence_sha256
probe-targets.json:probe_target_evidence_sha256
EOF
    jq -e '
        type == "object" and (keys | sort) == ["node27","vpn_container"] and
        (.node27 | type == "object" and length == 0) and
        (.vpn_container | type == "object") and
        all(.vpn_container | keys[];
          (startswith("8080/") or startswith("5900/") or startswith("15715/")) | not)
    ' "${evidence_base}.port-bindings.json" >/dev/null || return 1
    jq -e '
        type == "array" and all(.[];
          type == "object" and
          (keys | sort) == ["Destination","RW","Source"] and
          (.Source | type == "string" and length > 0) and
          (.Destination | type == "string" and length > 0) and
          (.RW | type) == "boolean" and
          (.Destination | IN("/home/blackcoin/.blackcoin","/root/.blackcoin") | not) and
          (.Destination | test("(^|/)([.]?blackcoin|[.]cookie)(/|$)") | not))
    ' "${evidence_base}.vpn-mounts.json" >/dev/null || return 1
    jq -e '
        type == "object" and
        (keys | sort) == (["candidate_processes","candidate_rpc_capable_processes",
          "cookie_or_conf_paths_present","rpc_auth_material_unavailable_to_shared_namespace",
          "separate_pid_namespace","shared_rpc_unauthenticated_rejected",
          "vpn_namespace"] | sort) and
        .candidate_processes == ["Xvfb","blackcoin-qt","fluxbox","ps"] and
        .candidate_rpc_capable_processes == ["blackcoin-qt"] and
        .cookie_or_conf_paths_present == [] and .separate_pid_namespace == true and
        .shared_rpc_unauthenticated_rejected == true and
        .rpc_auth_material_unavailable_to_shared_namespace == true and
        (.vpn_namespace | type == "object") and
        (.vpn_namespace | keys | sort) == (["auth_environment_names","dangerous_caps",
          "pid_mode","privileged","sensitive_mounts"] | sort) and
        .vpn_namespace == {privileged:false,pid_mode:"",dangerous_caps:[],
          auth_environment_names:[],sensitive_mounts:[]}
    ' "${evidence_base}.rpc-auth-boundary.json" >/dev/null || return 1
    probe_file="${evidence_base}.probe-targets.json"
    jq -e '
        type == "object" and
        (keys | sort) == (["all_host_and_vpn_targets_observed_inaccessible",
          "host_addresses","loopback_addresses","ports",
          "shared_namespace_gui_vnc_ports_observed_inaccessible",
          "shared_namespace_rpc_tcp_reachable",
          "shared_namespace_rpc_unauthenticated_rejected","vpn_addresses"] | sort) and
        .loopback_addresses == ["127.0.0.1","::1"] and
        (.host_addresses | type == "array" and length > 0 and
          all(.[]; type == "string" and length > 0) and (unique | length) == length) and
        (.vpn_addresses | type == "array" and length > 0 and
          all(.[]; type == "string" and length > 0) and (unique | length) == length) and
        .ports == [8080,5900,15715] and
        .all_host_and_vpn_targets_observed_inaccessible == true and
        .shared_namespace_rpc_tcp_reachable == true and
        .shared_namespace_rpc_unauthenticated_rejected == true and
        .shared_namespace_gui_vnc_ports_observed_inaccessible == true
    ' "$probe_file" >/dev/null
}

hotfix_invocation_file_is_valid()
{
    local file="$1" phase="$2" expected_image_id="$3" expected_nonce="$4"
    local expected_runtime_source="${5:-$HOTFIX_CANDIDATE_SOURCE_SHA}"
    local expected_flags body_sha argv_sha
    [[ -f "$file" && ! -L "$file" && ( "$phase" == A || "$phase" == B ) ]] || return 1
    hotfix_valid_image_id "$expected_image_id" && hotfix_valid_nonce "$expected_nonce" &&
        hotfix_valid_git_sha "$expected_runtime_source" || return 1
    if [[ "$phase" == A ]]; then
        expected_flags=$(hotfix_exact_phase_a_flags_json) || return 1
    else
        expected_flags=$(hotfix_exact_phase_b_flags_json) || return 1
    fi
    # jq -j is piped directly: the pinned body hash includes its terminal LF.
    body_sha=$(jq -j '.effective_entrypoint[2] // empty' "$file" | sha256sum | awk '{print $1}') || return 1
    [[ "$body_sha" == "$HOTFIX_CANDIDATE_ENTRYPOINT_BODY_SHA256" ]] || return 1
    jq -e --arg phase "$phase" --arg nonce "$expected_nonce" \
        --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" --arg image_id "$expected_image_id" \
        --arg runtime_source "$expected_runtime_source" \
        --arg start_gui "$IMMUTABLE_START_GUI_SHA256" \
        --arg body_sha "$HOTFIX_CANDIDATE_ENTRYPOINT_BODY_SHA256" \
        --arg sentinel "$HOTFIX_CANDIDATE_ENTRYPOINT_SENTINEL" \
        --argjson flags "$expected_flags" '
        def integer: type == "number" and floor == .;
        def hex64: type == "string" and test("^[0-9a-f]{64}$");
        def common_keys: ["baseline_config_unchanged","candidate_source_sha",
          "config_sha256","conflicting_cli_flags","conflicting_environment_entries",
          "container_args","container_path","created_stopped","display_environment",
          "effective_cmd","effective_entrypoint","entrypoint_body_sha256","image_cmd",
          "image_entrypoint","image_id","image_user","immutable_start_gui_sha256",
          "inspected_before_start","mounts_equal_baseline","mounts_sha256",
          "network_equal_baseline","network_sha256","operator_override_allowed","phase",
          "pid1_exe_sha256","run_nonce","runtime_argv","runtime_argv_sha256",
          "runtime_executable","runtime_source_sha","schema","setup_processes","working_dir"];
        def phase_b_keys: ["container_id","container_restart_count","container_started_at",
          "observed_start_gui_sha256","restart_policy","restart_policy_equal_baseline"];
        type == "object" and
        (keys | sort) == ((common_keys + (if $phase=="B" then phase_b_keys else [] end)) | sort) and
        (.schema | integer and . == 2) and .phase == $phase and .run_nonce == $nonce and
        .candidate_source_sha == $source and .image_id == $image_id and
        .runtime_source_sha == $runtime_source and
        .immutable_start_gui_sha256 == $start_gui and
        .entrypoint_body_sha256 == $body_sha and
        .created_stopped == true and .inspected_before_start == true and
        .image_user == "blackcoin" and .working_dir == "/home/blackcoin" and
        .image_entrypoint == ["/home/blackcoin/start-gui.sh"] and .image_cmd == null and
        (.effective_entrypoint | type == "array" and length == 4) and
        .effective_entrypoint == ["/bin/bash","-c",.effective_entrypoint[2],$sentinel] and
        .effective_cmd == $flags and
        .container_path == "/bin/bash" and
        .container_args == (["-c",.effective_entrypoint[2],$sentinel] + $flags) and
        .runtime_executable == "/usr/local/bin/blackcoin-qt" and
        .runtime_argv == (["/usr/local/bin/blackcoin-qt",
          "-datadir=/home/blackcoin/.blackcoin"] + $flags) and
        (.pid1_exe_sha256 | hex64) and (.runtime_argv_sha256 | hex64) and
        .display_environment == "DISPLAY=:0" and
        .setup_processes == {xvfb:true,fluxbox:true,x11vnc:true,websockify:true} and
        (.mounts_sha256 | hex64) and (.network_sha256 | hex64) and
        (.config_sha256 | hex64) and .mounts_equal_baseline == true and
        .network_equal_baseline == true and .baseline_config_unchanged == true and
        .operator_override_allowed == false and
        .conflicting_cli_flags == [] and .conflicting_environment_entries == [] and
        (if $phase == "B" then
          (.container_id | type == "string" and test("^[0-9a-f]{64}$")) and
          (.container_started_at | type == "string" and
            test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")) and
          (.container_restart_count | integer and . >= 0) and
          .observed_start_gui_sha256 == $start_gui and
          (.restart_policy | type == "object") and
          ((.restart_policy | keys | sort) == ["MaximumRetryCount","Name"]) and
          (.restart_policy.Name | type == "string" and length > 0) and
          (.restart_policy.MaximumRetryCount | integer and . >= 0) and
          .restart_policy_equal_baseline == true
         else true end)
    ' "$file" >/dev/null || return 1
    argv_sha=$(jq '.runtime_argv' "$file" | sha256sum | awk '{print $1}') || return 1
    [[ "$argv_sha" == "$(jq -er '.runtime_argv_sha256' "$file")" ]]
}

hotfix_phase_a_envelope_json_is_valid()
{
    local envelope="$1" fee mining_before mining_after recovery_before recovery_after staking
    jq -e -n --argjson envelope "$envelope" '
        def integer: type == "number" and floor == .;
        def hex64: type == "string" and test("^[0-9a-f]{64}$");
        def recovery_metrics: {pending_manual_resolutions,pending_automatic_resolutions,
          confirmed_manual_resolutions,confirmed_automatic_resolutions,
          confirmed_resolution_fees,automatic_actions_in_window,
          automatic_fee_exposure_in_window,reconciled_descendant_claims,claims_recycled};
        $envelope | type == "object" and
        (keys | sort) == (["chain_after","chain_before","expected_pending_automatic",
          "expected_pending_manual","expected_recovery_fee","expected_recovery_metrics",
          "expected_recovery_metrics_sha256","isolation_continuously_valid","isolation_sha256",
          "mining_after","mining_before","network","observed_epoch","observer_status",
          "phase","recovery_after","recovery_before","restart_epoch","sample","schema",
          "staking","wallet","wallets"] | sort) and
        (.schema | integer and . == 2) and .phase == "A" and
        (.sample | integer and . >= 1 and . <= 4) and
        (.observed_epoch | integer and . > 0) and
        (.restart_epoch | integer and (. == 1 or . == 2)) and
        .wallets == [""] and
        (.chain_before | type) == "object" and (.chain_after | type) == "object" and
        .chain_before.chain == "main" and .chain_after.chain == "main" and
        .chain_before.initialblockdownload == false and
        .chain_after.initialblockdownload == false and
        (.chain_before.blocks | integer and . >= 0) and
        (.chain_before.headers | integer and . >= 0) and
        .chain_before.blocks == .chain_before.headers and
        .chain_after.blocks == .chain_before.blocks and
        .chain_after.headers == .chain_before.headers and
        (.chain_before.bestblockhash | hex64) and
        (.chain_before.chainwork | hex64) and
        .chain_after.bestblockhash == .chain_before.bestblockhash and
        .chain_after.chainwork == .chain_before.chainwork and
        .recovery_before.active_tip == .chain_before.bestblockhash and
        .recovery_after.active_tip == .chain_before.bestblockhash and
        .recovery_after.wallet_generation == .recovery_before.wallet_generation and
        (.recovery_before | recovery_metrics) == (.recovery_after | recovery_metrics) and
        (.expected_recovery_metrics | type) == "object" and
        (.expected_recovery_metrics | keys | sort) ==
          (["automatic_actions_in_window","automatic_fee_exposure_in_window",
            "claims_recycled","confirmed_automatic_resolutions",
            "confirmed_manual_resolutions","confirmed_resolution_fees",
            "pending_automatic_resolutions","pending_manual_resolutions",
            "reconciled_descendant_claims"] | sort) and
        (.expected_recovery_metrics_sha256 | hex64) and
        (.recovery_before | recovery_metrics) == .expected_recovery_metrics and
        (.recovery_after | recovery_metrics) == .expected_recovery_metrics and
        .recovery_before.policy == .recovery_after.policy and
        .recovery_before.policy_state_status == .recovery_after.policy_state_status and
        .mining_before.claim_inventory_tip == .chain_before.bestblockhash and
        .mining_after.claim_inventory_tip == .chain_before.bestblockhash and
        .mining_after.mining_gate_candidate_state_fingerprint ==
          .mining_before.mining_gate_candidate_state_fingerprint and
        .mining_before.claims_submitted == 0 and .mining_after.claims_submitted == 0 and
        (.isolation_sha256 | hex64) and
        (.wallet | type) == "object" and .wallet.walletname == "" and
        .wallet.private_keys_enabled == true and .wallet.scanning == false and
        .wallet.unlocked_staking_only == false and
        (.wallet.unlocked_until | integer) and .wallet.unlocked_until > .observed_epoch and
        (.network | type) == "object" and
        (.network.networkactive | type) == "boolean" and
        (.network.localrelay | type) == "boolean" and
        (.network.connections_out | integer) and
        .network.networkactive == true and .network.localrelay == false and
        .network.connections_out >= 3 and
        .isolation_continuously_valid == true and .observer_status == "observed_absent" and
        (.expected_recovery_fee | type == "number" and . >= 0) and
        (.expected_pending_manual | integer and . >= 0) and
        (.expected_pending_automatic | integer and . >= 0) and
        .recovery_before.pending_manual_resolutions == .expected_pending_manual and
        .recovery_after.pending_manual_resolutions == .expected_pending_manual and
        .recovery_before.pending_automatic_resolutions == .expected_pending_automatic and
        .recovery_after.pending_automatic_resolutions == .expected_pending_automatic and
        .mining_before.raw_quarantined_claims == .recovery_before.raw_quarantined_claims and
        .mining_after.raw_quarantined_claims == .recovery_after.raw_quarantined_claims and
        .mining_before.blocking_quarantined_claims ==
          .recovery_before.blocking_quarantined_claims and
        .mining_after.blocking_quarantined_claims ==
          .recovery_after.blocking_quarantined_claims and
        .mining_before.actionable_quarantined_claims ==
          .recovery_before.actionable_quarantined_claims and
        .mining_after.actionable_quarantined_claims ==
          .recovery_after.actionable_quarantined_claims and
        .mining_before.resolved_on_active_chain_claims ==
          .recovery_before.resolved_on_active_chain_claims and
        .mining_after.resolved_on_active_chain_claims ==
          .recovery_after.resolved_on_active_chain_claims and
        .mining_before.indeterminate_quarantined_claims ==
          .recovery_before.indeterminate_quarantined_claims and
        .mining_after.indeterminate_quarantined_claims ==
          .recovery_after.indeterminate_quarantined_claims and
        .mining_before.claim_components == .recovery_before.components and
        .mining_after.claim_components == .recovery_after.components and
        .mining_before.claim_recovery_database_outcome_ambiguous ==
          .recovery_before.database_outcome_ambiguous and
        .mining_after.claim_recovery_database_outcome_ambiguous ==
          .recovery_after.database_outcome_ambiguous and
        .mining_before.claims_auto_resolved ==
          .recovery_before.confirmed_automatic_resolutions and
        .mining_after.claims_auto_resolved ==
          .recovery_after.confirmed_automatic_resolutions and
        .mining_before.claims_recycled == .recovery_before.claims_recycled and
        .mining_after.claims_recycled == .recovery_after.claims_recycled and
        .mining_before.cumulative_resolution_fees ==
          .recovery_before.confirmed_resolution_fees and
        .mining_after.cumulative_resolution_fees ==
          .recovery_after.confirmed_resolution_fees
    ' >/dev/null || return 1
    fee=$(jq -c '.expected_recovery_fee' <<<"$envelope") || return 1
    mining_before=$(jq -ce '.mining_before' <<<"$envelope") || return 1
    mining_after=$(jq -ce '.mining_after' <<<"$envelope") || return 1
    recovery_before=$(jq -ce '.recovery_before' <<<"$envelope") || return 1
    recovery_after=$(jq -ce '.recovery_after' <<<"$envelope") || return 1
    staking=$(jq -ce '.staking' <<<"$envelope") || return 1
    hotfix_candidate_pow_json_is_valid "$mining_before" active &&
        hotfix_candidate_pow_json_is_valid "$mining_after" active &&
        hotfix_candidate_recovery_json_is_valid "$recovery_before" "$fee" &&
        hotfix_candidate_recovery_json_is_valid "$recovery_after" "$fee" &&
        hotfix_phase_a_staking_json_is_disabled "$staking"
}

hotfix_phase_a_progress_file_is_valid()
{
    local file="$1" envelope
    [[ -f "$file" && ! -L "$file" ]] || return 1
    jq -e --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" '
        def integer: type == "number" and floor == .;
        type == "object" and
        (keys | sort) == (["bounded_worker_tip_progress","candidate_source_sha","envelopes",
          "hard_flags_continuous","interactive_surfaces_stopped_continuously",
          "lineage_continuation_tips","nonpublication_continuous",
          "isolation_sample_sha256s","per_epoch_claims_submitted_zero","phase",
          "pos_disabled_continuous","run_nonce","schema",
          "single_positive_hash_sample_required","tip_changes",
          "visibility_sample_sha256s","wait_for_next_tip_required_for_liveness",
          "worker_only_pow"] | sort) and
        (.schema | integer and . == 2) and .phase == "A" and
        (.run_nonce | type == "string" and test("^[0-9a-f]{32}$")) and
        .candidate_source_sha == $source and
        (.envelopes | type == "array" and length == 4) and
        ([.envelopes[].sample] == [1,2,3,4]) and
        ([.envelopes[].chain_before.blocks] as $h |
          all(range(1;$h|length); $h[.] > $h[.-1])) and
        ([.envelopes[].chain_before.bestblockhash] as $t |
          ($t | unique | length) == 4 and
          all(range(1;$t|length); $t[.] != $t[.-1])) and
        ([.envelopes[].chain_before.chainwork] as $w |
          all(range(1;$w|length); $w[.] > $w[.-1])) and
        ([.envelopes[].observed_epoch] as $o |
          all(range(1;$o|length); $o[.] >= $o[.-1])) and
        .envelopes[0].restart_epoch == 1 and
        all(.envelopes[1:][]; .restart_epoch == 2) and
        ([.envelopes[].expected_recovery_metrics_sha256] | unique | length) == 1 and
        (.tip_changes | integer and . == 3) and
        .hard_flags_continuous == true and .pos_disabled_continuous == true and
        .nonpublication_continuous == true and
        .interactive_surfaces_stopped_continuously == true and .worker_only_pow == true and
        (.lineage_continuation_tips | integer and . == 3) and
        .per_epoch_claims_submitted_zero == true and
        (.isolation_sample_sha256s | type == "array" and length == 4 and
          all(.[]; type == "string" and test("^[0-9a-f]{64}$"))) and
        (.visibility_sample_sha256s | type == "array" and length == 4 and
          all(.[]; type == "string" and test("^[0-9a-f]{64}$"))) and
        ([.envelopes[].isolation_sha256] == .isolation_sample_sha256s) and
        .bounded_worker_tip_progress == true and
        .single_positive_hash_sample_required == false and
        .wait_for_next_tip_required_for_liveness == false
    ' "$file" >/dev/null || return 1
    while IFS= read -r envelope; do
        hotfix_phase_a_envelope_json_is_valid "$envelope" || return 1
    done < <(jq -ce '.envelopes[]' "$file")
}

hotfix_phase_a_claim_proof_file_is_valid()
{
    local file="$1"
    [[ -f "$file" && ! -L "$file" ]] || return 1
    jq -e --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" \
        --arg zero "$HOTFIX_ZERO_TXID" '
        def hex64: type == "string" and test("^[0-9a-f]{64}$");
        def integer: type == "number" and floor == .;
        . as $proof |
        type == "object" and .schema == 3 and .phase == "A" and
        (.run_nonce | test("^[0-9a-f]{32}$")) and
        .candidate_source_sha == $source and
        .final_order == ["tip-proof","pow-stop-joined",
          "wallet-claim-mempool-observer-proof","wallet-locked",
          "candidate-clean-stop","logs-complete-through-stop"] and
        .pow_worker_joined == true and .final_pow_enabled == false and
        .final_pow_hashrate == 0 and .logs_complete_through_stop == true and
        .wallet_locked == true and .candidate_cleanly_stopped == true and
        (.candidate_stopped_receipt_sha256 | hex64) and
        (.candidate_complete_log_sha256 | hex64) and
        (.candidate_post_stop_log_receipt_sha256 | hex64) and
        (.observer_terminal_proof_sha256 | hex64) and
        (.final_stable_cut_sha256 | hex64) and .terminal_stable_cut_verified == true and
        .interactive_surfaces_stopped_continuously == true and
        .shared_namespace_rpc_auth_boundary_continuously_verified == true and
        .rpc_allowlist_enforced == true and .unexpected_rpc_methods == [] and
        .persisted_pending_worker_log_observed == true and
        .persisted_without_relay_log_observed == true and
        (.candidate_claims_submitted | integer and . == 0) and
        .candidate_mining_gate_coherent == true and
        .candidate_mining_gate_database_ambiguous == false and
        .candidate_mining_gate_unsafe_claims == 0 and
        .candidate_mining_gate_unsafe_components == 0 and
        .candidate_recovery_database_ambiguous == false and
        (.retired_claim_objects | integer and . == 0) and
        (.retired_components | integer and . == 0) and
        .candidate_retired_member_txids == [] and
        .hard_staking_disabled_continuously == true and
        .coinstake_created_txids == [] and .network_visible_wallet_txids == [] and
        .fee_payments_authorized == false and .automatic_recovery_authorized == false and
        .recovery_rpc_invoked == false and .sendrawtransaction_invoked == false and
        .abandontransaction_invoked == false and .payout_rotation_invoked == false and
        .forbidden_rpc_methods == [] and (.rpc_methods_sha256 | hex64) and
        .payout_address_after == .payout_address_before and
        .quantum_key_count_after == .quantum_key_count_before and
        .quantum_inventory_sha256_after == .quantum_inventory_sha256_before and
        .confirmed_resolution_fees_after == .confirmed_resolution_fees_before and
        .cumulative_resolution_fees_after == .cumulative_resolution_fees_before and
        .pending_manual_after == .pending_manual_before and
        .pending_automatic_after == .pending_automatic_before and
        (.recovery_metrics_sha256_before | hex64) and
        .recovery_metrics_sha256_after == .recovery_metrics_sha256_before and
        .recovery_metrics_unchanged == true and
        .resolution_txids_after == .resolution_txids_before and
        .component_resolution_txids_after == .component_resolution_txids_before and
        (.candidate_created_qqsproof_txids | type == "array" and length == 4 and
          all(.[]; hex64) and (unique | length) == length) and
        .candidate_created_qqsproof_mempool_txids == [] and
        .candidate_created_qqsproof_confirmed_txids == [] and
        .candidate_created_qqsproof_observer_txids == [] and
        .candidate_created_qqsproof_unclassifiable_txids == [] and
        .observer_status == "observed_absent" and
        (.observer_samples | integer and . >= 4) and
        .continuous_absence_verified == true and
        .initial_atomic_reservation_verified == true and
        .new_nonclaim_wallet_transactions == [] and
        .abandoned_wallet_txids == [] and .baseline_wallet_records_static_equal == true and
        .baseline_wallet_record_mutations == [] and
        (.progress_tips | type == "array" and length == 4 and all(.[]; hex64) and
          (unique | length) == length) and
        .claim_sample_tips == .progress_tips and .claim_samples_monotonic == true and
        .visibility_samples_bound_to_progress == true and
        .progress_tips_bound_to_lineage == true and
        .one_lineage_member_per_progress_tip == true and
        .final_claim_sample_complete == true and
        .distinct_anchor_consumption_observed == false and
        (.lineage | type == "object") and .lineage.authenticated == true and
        .lineage.all_claims_zero_payment_retirable == false and
        .lineage.all_claims_expired_locally_retired == false and
        (.lineage.anchor_txid | hex64) and (.lineage.anchor_vout | integer and . >= 0) and
        (.lineage.family | hex64) and (.lineage.root_txid | hex64) and
        (.lineage.members | type == "array" and length == 4) and
        (.lineage.members | length) == (.candidate_created_qqsproof_txids | length) and
        ([.lineage.members[].txid] == .candidate_created_qqsproof_txids) and
        ([.lineage.members[].txid] | unique | length) == (.lineage.members | length) and
        .lineage.component_claim_txids == (.candidate_created_qqsproof_txids | sort) and
        ([.lineage.members[].ordinal] == [range(0; .lineage.members|length)]) and
        .lineage.root_txid == .lineage.members[0].txid and
        .lineage.members[0].parent_txid == $zero and
        ([range(1; ($proof.lineage.members|length)) as $i |
          $proof.lineage.members[$i].parent_txid ==
            $proof.lineage.members[$i-1].txid] | all) and
        .lineage.contiguous_parents == true and .lineage.same_anchor == true and
        .lineage.same_family == true and .lineage.same_root == true and
        .lineage.same_tip_duplicates == false and
        .lineage.tip_span == (.progress_tips | length) and
        all(.lineage.members[];
          (.txid | hex64) and .quarantine_marker == "1" and
          (.parent_txid | hex64) and
          .anchor_txid == $proof.lineage.anchor_txid and
          .anchor_vout == $proof.lineage.anchor_vout and
          .family == $proof.lineage.family and
          .root_txid == $proof.lineage.root_txid and
          (.created_tip | hex64) and
          .proof_origin_bound == true and .proof_input_bound == true and
          .expired_locally_retired == false and
          .confirmations == 0 and .abandoned == false and
          .in_local_mempool == false and .in_active_chain == false and
          .observer_absent == true and
          (.first_quarantine_observation_present | type) == "boolean" and
          (.branch_quarantine_observation_present | type) == "boolean") and
        .txid_differential_classified == true and
        .mempool_differential_classified == true and
        .wallet_outpoint_differential_classified == true
    ' "$file" >/dev/null
}

hotfix_phase_a_stable_stop_file_is_valid()
{
    local file="$1" transition="$2" image_id="$3" image_ref="$4"
    [[ -f "$file" && ! -L "$file" ]] || return 1
    jq -e --arg transition "$transition" --arg image "$image_id" --arg ref "$image_ref" '
      def integer: type == "number" and floor == .;
      def restart_policy:
        type == "object" and (keys | sort) == ["MaximumRetryCount","Name"] and
        (.Name | type) == "string" and length > 0 and
        (.MaximumRetryCount | integer and . >= 0);
      type == "object" and
      (keys | sort) == (["armed_restart_policy","automatic_restart_observed",
        "clean_rpc_stop_completed","container_id","image_id","image_ref",
        "original_restart_policy","restart_authority_disabled_before_rpc_stop",
        "restart_count_armed","restart_count_before","restart_count_stopped_first",
        "restart_count_stopped_second","schema","stable_stopped_samples",
        "started_at_armed","started_at_before","stopped_finished_at_first",
        "stopped_finished_at_second","stopped_restart_policy_first",
        "stopped_restart_policy_second","stopped_started_at_first",
        "stopped_started_at_second","transition"] | sort) and
      .schema == 1 and .transition == $transition and
      (["baseline-pre-snapshot","candidate-terminal","base-quarantine-to-baseline"] |
        index($transition) != null) and
      (.container_id | test("^[0-9a-f]{64}$")) and
      .image_id == $image and .image_ref == $ref and
      (.original_restart_policy | restart_policy) and
      (if $transition == "baseline-pre-snapshot" then true
       else .original_restart_policy == {Name:"no",MaximumRetryCount:0} end) and
      .armed_restart_policy == {Name:"no",MaximumRetryCount:0} and
      .stopped_restart_policy_first == .armed_restart_policy and
      .stopped_restart_policy_second == .armed_restart_policy and
      (.started_at_before | type == "string" and length > 0) and
      .started_at_armed == .started_at_before and
      .stopped_started_at_first == .started_at_before and
      .stopped_started_at_second == .started_at_before and
      (.stopped_finished_at_first | type == "string" and length > 0) and
      .stopped_finished_at_second == .stopped_finished_at_first and
      (.restart_count_before | integer and . >= 0) and
      .restart_count_armed == .restart_count_before and
      .restart_count_stopped_first == .restart_count_before and
      .restart_count_stopped_second == .restart_count_before and
      .restart_authority_disabled_before_rpc_stop == true and
      .clean_rpc_stop_completed == true and .stable_stopped_samples == 2 and
      .automatic_restart_observed == false
    ' "$file" >/dev/null
}

hotfix_snapshot_set_file_is_valid()
{
    local file="$1" expected_nonce="$2"
    [[ -f "$file" && ! -L "$file" ]] || return 1
    jq -e --arg nonce "$expected_nonce" '
        def integer: type == "number" and floor == .;
        def datasets: [
          "pulsar/Blackcoin_Blocks/node-data/node-27",
          "pulsar/Blackcoin_Blocks/node-data/node-27/blocks",
          "pulsar/Blackcoin_Blocks/node-data/node-27/indexes",
          "pulsar/Blackcoin_Blocks/alpha-chain-raw-clones-20260715T032403Z/node-27"];
        type == "object" and
        (keys | sort) == ["baseline_stop_authority_sha256","created_after_clean_stop",
          "held","run_nonce","schema","snapshots"] and
        (.schema | integer and . == 1) and .run_nonce == $nonce and
        ($nonce | test("^[0-9a-f]{32}$")) and
        (.baseline_stop_authority_sha256 | test("^[0-9a-f]{64}$")) and
        .created_after_clean_stop == true and .held == true and
        (.snapshots | type == "array" and length == 4) and
        [.snapshots[].dataset] == datasets and
        all(.snapshots[];
          (keys | sort) == ["creation_txg","dataset","guid","hold_present","hold_tag","snapshot"] and
          .snapshot == (.dataset + "@v30.1.4-hotfix-candidate-node27-" + $nonce) and
          (.guid | integer and . > 0) and (.creation_txg | integer and . > 0) and
          .hold_tag == ("blackcoin-hotfix-candidate-node27-" + $nonce) and
          (.hold_present | type) == "boolean" and
          .hold_present == true)
    ' "$file" >/dev/null
}

hotfix_rewind_safe_file_is_valid()
{
    local file="$1" expected_nonce="$2"
    [[ -f "$file" && ! -L "$file" ]] || return 1
    jq -e --arg nonce "$expected_nonce" --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" \
        --arg body "$HOTFIX_CANDIDATE_ENTRYPOINT_BODY_SHA256" \
        --arg image_ref "$HOTFIX_CANDIDATE_IMAGE_REF" '
        def hex64: type == "string" and test("^[0-9a-f]{64}$");
        def integer: type == "number" and floor == .;
        type == "object" and
        (keys | sort) == (["baseline_runtime_identity_sha256",
          "candidate_binary_sha256sums_sha256","candidate_blackcoin_qt_sha256",
          "candidate_bundle_manifest_sha256","candidate_created_qqsproof_txids",
          "candidate_exit_code","candidate_image_id","candidate_image_ref",
          "candidate_final_chain_after_sha256","candidate_final_chain_sha256",
          "candidate_final_mempool_sha256","candidate_final_pow_after_sha256",
          "candidate_final_pow_sha256","candidate_final_recovery_after_sha256",
          "candidate_final_recovery_sha256","candidate_final_stable_cut_sha256",
          "candidate_final_staking_after_sha256","candidate_final_staking_sha256",
          "candidate_final_wallet_transactions_sha256",
          "candidate_loaded_image_sha256","candidate_manifest_digest",
          "candidate_oci_identity_sha256","candidate_source_sha","candidate_stopped",
          "candidate_stopped_receipt_sha256","candidate_stop_authority_sha256",
          "candidate_post_stop_log_receipt_sha256",
          "claim_proof_sha256","coinstake_or_wallet_escape_detected","compose_sha256",
          "complete_log_captured_after_stop","confirmed_candidate_txids",
          "entrypoint_body_sha256","guard_sources_sha256",
          "hard_flags_continuously_verified","helper_audit_sha256","invocation_sha256",
          "interactive_surfaces_stopped_continuously",
          "locks_sha256","logs_sha256","maintenance_marker_sha256",
          "network_visible_wallet_txids","nonpublication_sha256","nonpublication_verified",
          "observer_absence_verified","observer_anchor_unspent_sha256",
          "observer_final_chain_sha256","observer_terminal_proof_sha256",
          "observer_tx_absence_sha256","offline_verifier_receipt_sha256",
          "package_sha256sums_sha256","phase_a_script_sha256",
          "phase_a_tooling_identity_sha256","phase_b_script_sha256",
          "pos_disabled_continuously","pow_worker_joined","pre_rewind_manifest_sha256",
          "pre_rewind_state_sha256","progress_sha256","promotion_marker_absent",
          "recovery_metrics_sha256","recovery_spend_or_fee_detected","result",
          "rpc_journal_sha256","run_nonce",
          "rpc_allowlist_enforced",
          "schema","snapshot_set_sha256","snapshots_held","terminal_chainwork",
          "shared_namespace_rpc_auth_boundary_verified","terminal_height","terminal_tip",
          "terminal_stable_cut_verified","tooling_commit","typed_contract_sha256",
          "unclassifiable_candidate_txids","unknown_or_ambiguous","unrelated_wallet_delta",
          "verifier_sha256","wallet_generation","wallet_locked"] | sort) and
        (.schema | integer and . == 1) and .result == "REWIND_SAFE" and
        .run_nonce == $nonce and .candidate_source_sha == $source and
        ($nonce | test("^[0-9a-f]{32}$")) and
        (.candidate_image_id | test("^sha256:[0-9a-f]{64}$")) and
        .candidate_image_ref == $image_ref and
        (.candidate_manifest_digest | test("^sha256:[0-9a-f]{64}$")) and
        (.candidate_blackcoin_qt_sha256 | hex64) and
        (.tooling_commit | test("^[0-9a-f]{40}$")) and
        (.phase_a_tooling_identity_sha256 | hex64) and
        (.package_sha256sums_sha256 | hex64) and (.phase_a_script_sha256 | hex64) and
        (.phase_b_script_sha256 | hex64) and (.verifier_sha256 | hex64) and
        (.typed_contract_sha256 | hex64) and
        (.recovery_metrics_sha256 | hex64) and
        .entrypoint_body_sha256 == $body and
        (.invocation_sha256 | hex64) and
        (.helper_audit_sha256 | hex64) and (.nonpublication_sha256 | hex64) and
        (.snapshot_set_sha256 | hex64) and (.progress_sha256 | hex64) and
        (.claim_proof_sha256 | hex64) and (.logs_sha256 | hex64) and
        (.rpc_journal_sha256 | hex64) and (.locks_sha256 | hex64) and
        (.guard_sources_sha256 | hex64) and
        (.pre_rewind_state_sha256 | hex64) and (.maintenance_marker_sha256 | hex64) and
        (.offline_verifier_receipt_sha256 | hex64) and
        (.compose_sha256 | hex64) and (.baseline_runtime_identity_sha256 | hex64) and
        (.candidate_bundle_manifest_sha256 | hex64) and
        (.candidate_oci_identity_sha256 | hex64) and
        (.candidate_binary_sha256sums_sha256 | hex64) and
        (.candidate_loaded_image_sha256 | hex64) and
        (.candidate_stop_authority_sha256 | hex64) and
        (.pre_rewind_manifest_sha256 | hex64) and
        all([.candidate_final_chain_sha256,.candidate_final_chain_after_sha256,
             .candidate_final_pow_sha256,.candidate_final_pow_after_sha256,
             .candidate_final_staking_sha256,.candidate_final_staking_after_sha256,
             .candidate_final_recovery_sha256,.candidate_final_recovery_after_sha256,
             .candidate_final_wallet_transactions_sha256,.candidate_final_mempool_sha256,
             .observer_terminal_proof_sha256,.observer_final_chain_sha256,
             .observer_anchor_unspent_sha256,.observer_tx_absence_sha256,
             .candidate_final_stable_cut_sha256,.candidate_stopped_receipt_sha256,
             .candidate_stop_authority_sha256,
             .candidate_post_stop_log_receipt_sha256][]; hex64) and
        .candidate_stopped == true and
        (.candidate_exit_code | integer and . == 0) and
        .pow_worker_joined == true and .wallet_locked == true and
        .hard_flags_continuously_verified == true and
        .pos_disabled_continuously == true and
        .interactive_surfaces_stopped_continuously == true and
        .rpc_allowlist_enforced == true and
        .shared_namespace_rpc_auth_boundary_verified == true and
        .complete_log_captured_after_stop == true and
        .terminal_stable_cut_verified == true and .nonpublication_verified == true and
        .observer_absence_verified == true and .unknown_or_ambiguous == false and
        .coinstake_or_wallet_escape_detected == false and
        (.candidate_created_qqsproof_txids | type == "array" and length == 4 and
          all(.[]; hex64) and (unique | length) == length) and
        .network_visible_wallet_txids == [] and .confirmed_candidate_txids == [] and
        .unclassifiable_candidate_txids == [] and
        .recovery_spend_or_fee_detected == false and .unrelated_wallet_delta == false and
        (.terminal_tip | hex64) and
        (.terminal_height | integer and . >= 0) and
        (.terminal_chainwork | hex64) and
        (.wallet_generation | integer and . >= 0) and
        .promotion_marker_absent == true and .snapshots_held == true
    ' "$file" >/dev/null
}

hotfix_phase_a_tooling_identity_file_is_valid()
{
    local file="$1" expected_tooling="${2:-}" expected_package="${3:-}"
    local expected_phase_a="${4:-}" expected_phase_b="${5:-}"
    local expected_verifier="${6:-}" expected_contract="${7:-}"
    [[ -f "$file" && ! -L "$file" ]] || return 1
    jq -e --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" \
        --arg tooling "$expected_tooling" --arg package "$expected_package" \
        --arg phase_a "$expected_phase_a" --arg phase_b "$expected_phase_b" \
        --arg verifier "$expected_verifier" --arg contract "$expected_contract" '
        def hex64: type == "string" and test("^[0-9a-f]{64}$");
        def matches($expected): $expected == "" or . == $expected;
        type == "object" and
        (keys | sort) == (["candidate_source_sha","exact_bytes_recorded_before_any_live_mutation",
          "package_sha256sums_sha256","phase_a_script_sha256","phase_b_script_sha256",
          "schema","tooling_commit","typed_contract_sha256","verifier_sha256"] | sort) and
        .schema == 1 and .candidate_source_sha == $source and
        (.tooling_commit | type == "string" and test("^[0-9a-f]{40}$") and
          matches($tooling)) and
        (.package_sha256sums_sha256 | hex64 and matches($package)) and
        (.phase_a_script_sha256 | hex64 and matches($phase_a)) and
        (.phase_b_script_sha256 | hex64 and matches($phase_b)) and
        (.verifier_sha256 | hex64 and matches($verifier)) and
        (.typed_contract_sha256 | hex64 and matches($contract)) and
        .exact_bytes_recorded_before_any_live_mutation == true
    ' "$file" >/dev/null
}

hotfix_base_catchup_file_is_valid()
{
    local file="$1" expected_nonce="$2"
    [[ -f "$file" && ! -L "$file" ]] || return 1
    jq -e --arg nonce "$expected_nonce" --arg source "$IMMUTABLE_V3014_SOURCE_SHA" \
        --arg image "$IMMUTABLE_V3014_IMAGE_REF" --arg image_id "$IMMUTABLE_V3014_IMAGE_ID" '
        def integer: type == "number" and floor == .;
        def hex64: type == "string" and test("^[0-9a-f]{64}$");
        type == "object" and
        (keys | sort) == (["authenticated_anchor","authenticated_anchor_evidence_sha256",
          "authenticated_anchor_unspent","candidate_claim_escape_absent",
          "candidate_image_not_applied","candidate_txids_absent_from_mempool",
          "candidate_txids_absent_from_wallet","chain","chain_after",
          "chain_after_evidence_sha256","chain_evidence_sha256",
          "chainwork_at_least_phase_a","hard_quarantine_flags_verified","image","image_id",
          "invocation_sha256","mempool_sha256","network","network_evidence_sha256",
          "nonpublication_sha256","observer_anchor_unspent",
          "observer_candidate_txids_absent","observer_cut_sha256",
          "phase_a_terminal_chainwork","phase_a_terminal_tip","pos_enabled","pow",
          "pow_enabled","pow_evidence_sha256","recovery","recovery_evidence_sha256",
          "run_nonce","schema","source_sha","stable_cut","staking",
          "staking_evidence_sha256","terminal_tip_active",
          "terminal_tip_superseded_by_greater_work","wallet","wallet_evidence_sha256",
          "wallet_locked","wallet_processed_tip_current","wallet_transactions_sha256",
          "walletbroadcast","wallets","wallets_evidence_sha256"] | sort) and
        (.schema | integer and . == 1) and .run_nonce == $nonce and
        ($nonce | test("^[0-9a-f]{32}$")) and
        .source_sha == $source and .image == $image and .image_id == $image_id and
        .hard_quarantine_flags_verified == true and .wallet_locked == true and
        .pow_enabled == false and .pos_enabled == false and .walletbroadcast == false and
        (.chain | type) == "object" and .chain.chain == "main" and
        .chain.initialblockdownload == false and
        (.chain.blocks | integer and . >= 0) and
        (.chain.headers | integer and . >= 0) and .chain.blocks == .chain.headers and
        (.chain.bestblockhash | hex64) and
        (.chain.chainwork | hex64) and (.phase_a_terminal_chainwork | hex64) and
        (.phase_a_terminal_tip | hex64) and
        (.chain_after | type) == "object" and .chain_after.chain == "main" and
        .chain_after.initialblockdownload == false and
        .chain_after.blocks == .chain.blocks and .chain_after.headers == .chain.headers and
        .chain_after.bestblockhash == .chain.bestblockhash and
        .chain_after.chainwork == .chain.chainwork and
        .chain.chainwork >= .phase_a_terminal_chainwork and
        .chainwork_at_least_phase_a == true and
        (.terminal_tip_active | type) == "boolean" and
        (.terminal_tip_superseded_by_greater_work | type) == "boolean" and
        (.terminal_tip_active != .terminal_tip_superseded_by_greater_work) and
        (.terminal_tip_active == true or .terminal_tip_superseded_by_greater_work == true) and
        (if .terminal_tip_active then .chain.bestblockhash == .phase_a_terminal_tip
         else (.terminal_tip_superseded_by_greater_work == true and
           .chain.chainwork > .phase_a_terminal_chainwork) end) and
        (.wallet | type) == "object" and .wallet.walletname == "" and
        .wallet.private_keys_enabled == true and .wallet.scanning == false and
        .wallet.unlocked_until == 0 and .wallet.unlocked_staking_only == false and
        (.recovery | type) == "object" and .recovery.chain_ready == true and
        .recovery.database_outcome_ambiguous == false and
        .recovery.wallet_tip_matches == true and
        .recovery.active_tip == .chain.bestblockhash and
        .recovery.wallet_processed_tip == .chain.bestblockhash and
        (.staking | type) == "object" and .staking.enabled == false and
        .staking.staking == false and .staking.worker_running == false and
        (.pow | type) == "object" and .pow.enabled == false and .pow.hashrate == 0 and
        (.network | type) == "object" and .network.networkactive == true and
        .network.localrelay == false and (.network.connections_out | integer and . >= 3) and
        .wallets == [""] and
        (.authenticated_anchor | type) == "object" and
        (.authenticated_anchor | keys | sort) == ["txid","txout","unspent","vout"] and
        (.authenticated_anchor.txid | hex64) and (.authenticated_anchor.vout | integer and . >= 0) and
        .authenticated_anchor.unspent == true and
        (.authenticated_anchor.txout | type) == "object" and
        (.authenticated_anchor.txout.confirmations | integer and . >= 1) and
        .authenticated_anchor.txout.coinbase == false and
        all([.invocation_sha256,.nonpublication_sha256,.observer_cut_sha256,
             .chain_evidence_sha256,.chain_after_evidence_sha256,
             .recovery_evidence_sha256,.wallet_evidence_sha256,
             .staking_evidence_sha256,.pow_evidence_sha256,.network_evidence_sha256,
             .wallets_evidence_sha256,.wallet_transactions_sha256,.mempool_sha256,
             .authenticated_anchor_evidence_sha256][]; hex64) and
        .wallet_processed_tip_current == true and .candidate_image_not_applied == true and
        .candidate_txids_absent_from_wallet == true and
        .candidate_txids_absent_from_mempool == true and
        .authenticated_anchor_unspent == true and
        .observer_candidate_txids_absent == true and .observer_anchor_unspent == true and
        .candidate_claim_escape_absent == true and .stable_cut == true
    ' "$file" >/dev/null
}

hotfix_snapshot_absence_file_is_valid()
{
    local file="$1" expected_nonce="$2"
    [[ -f "$file" && ! -L "$file" ]] || return 1
    jq -e --arg nonce "$expected_nonce" '
        def integer: type == "number" and floor == .;
        def datasets: [
          "pulsar/Blackcoin_Blocks/node-data/node-27",
          "pulsar/Blackcoin_Blocks/node-data/node-27/blocks",
          "pulsar/Blackcoin_Blocks/node-data/node-27/indexes",
          "pulsar/Blackcoin_Blocks/alpha-chain-raw-clones-20260715T032403Z/node-27"];
        type == "object" and
        (keys | sort) == (["all_four_snapshots_destroyed","all_holds_released",
          "authority_recheck_count","authority_rechecked_before_every_release_and_destroy",
          "authority_rechecks_sha256","catchup_proof_sha256",
          "catchup_verified_before_release","recursive_or_force_flags_used",
          "release_order","remaining_holds","remaining_snapshots","run_nonce","schema",
          "snapshot_set_sha256","snapshots"] | sort) and
        (.schema | integer and . == 1) and .run_nonce == $nonce and
        ($nonce | test("^[0-9a-f]{32}$")) and
        (.snapshot_set_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
        (.catchup_proof_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
        (.authority_rechecks_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
        (.authority_recheck_count | integer and . == 10) and
        .authority_rechecked_before_every_release_and_destroy == true and
        (.snapshots | type == "array" and length == 4) and
        [.snapshots[].dataset] == datasets and
        all(.snapshots[];
          (keys | sort) == ["dataset","hold_tag","snapshot"] and
          .snapshot == (.dataset + "@v30.1.4-hotfix-candidate-node27-" + $nonce) and
          .hold_tag == ("blackcoin-hotfix-candidate-node27-" + $nonce)) and
        .catchup_verified_before_release == true and .release_order == "child-before-parent" and
        .recursive_or_force_flags_used == false and .all_holds_released == true and
        .all_four_snapshots_destroyed == true and .remaining_snapshots == [] and
        .remaining_holds == []
    ' "$file" >/dev/null
}

hotfix_phase_a_result_file_is_valid()
{
    local file="$1"
    [[ -f "$file" && ! -L "$file" ]] || return 1
    jq -e --arg candidate "$HOTFIX_CANDIDATE_SOURCE_SHA" \
        --arg base "$IMMUTABLE_V3014_SOURCE_SHA" '
        def integer: type == "number" and floor == .;
        def hex64: type == "string" and test("^[0-9a-f]{64}$");
        type == "object" and
        (keys | sort) == (["all_snapshots_absent_before_baseline_restore",
          "base_hard_quarantine_catchup_verified","base_quarantine_stop_authority_sha256",
          "base_source_sha","baseline_restored","baseline_restored_container_sha256",
          "candidate_source_sha","catchup_proof_sha256","data_rewind_completed",
          "evidence_sha256sums_sha256","baseline_recovery_metrics_sha256",
          "node","phase","phase_b_invoked",
          "package_sha256sums_sha256","phase_a_script_sha256",
          "phase_a_tooling_identity_sha256","phase_b_script_sha256",
          "promotion_marker_absent","result","rewind_safe_certificate_verified",
          "rewind_safe_sha256","run_nonce","schema","snapshot_absence_sha256",
          "tooling_commit","typed_contract_sha256","verifier_sha256"] | sort) and
        (.schema | integer and . == 3) and .phase == "A" and
        (.node | integer and . == 27) and
        .result == "passed" and .candidate_source_sha == $candidate and
        .base_source_sha == $base and
        (.run_nonce | type == "string" and test("^[0-9a-f]{32}$")) and
        .rewind_safe_certificate_verified == true and .data_rewind_completed == true and
        .base_hard_quarantine_catchup_verified == true and
        .all_snapshots_absent_before_baseline_restore == true and
        .baseline_restored == true and .phase_b_invoked == false and
        .promotion_marker_absent == true and
        (.tooling_commit | type == "string" and test("^[0-9a-f]{40}$")) and
        (.phase_a_tooling_identity_sha256 | hex64) and
        (.package_sha256sums_sha256 | hex64) and (.phase_a_script_sha256 | hex64) and
        (.phase_b_script_sha256 | hex64) and (.verifier_sha256 | hex64) and
        (.typed_contract_sha256 | hex64) and
        (.baseline_recovery_metrics_sha256 | hex64) and
        (.base_quarantine_stop_authority_sha256 | hex64) and
        (.baseline_restored_container_sha256 | hex64) and
        (.rewind_safe_sha256 | hex64) and (.catchup_proof_sha256 | hex64) and
        (.snapshot_absence_sha256 | hex64) and (.evidence_sha256sums_sha256 | hex64)
    ' "$file" >/dev/null
}

hotfix_storage_absence_receipt_file_is_valid()
{
    local file="$1" result_sha="$2" run_nonce="$3" stage="$4"
    [[ -f "$file" && ! -L "$file" ]] || return 1
    jq -e --arg result "$result_sha" --arg nonce "$run_nonce" --arg stage "$stage" '
        def integer: type == "number" and floor == .;
        def datasets: [
          "pulsar/Blackcoin_Blocks/node-data/node-27",
          "pulsar/Blackcoin_Blocks/node-data/node-27/blocks",
          "pulsar/Blackcoin_Blocks/node-data/node-27/indexes",
          "pulsar/Blackcoin_Blocks/alpha-chain-raw-clones-20260715T032403Z/node-27"];
        type == "object" and
        (keys | sort) == (["all_holds_absent","all_snapshots_absent",
          "phase_a_result_sha256","phase_a_run_nonce","schema","snapshot_set_sha256",
          "snapshots","stage","zfs_enumeration_succeeded","zpool","zpool_health"] | sort) and
        (.schema | integer and . == 1) and .stage == $stage and
        ($stage | IN("before-marker","after-marker","before-launch")) and
        .phase_a_result_sha256 == $result and .phase_a_run_nonce == $nonce and
        ($result | test("^[0-9a-f]{64}$")) and ($nonce | test("^[0-9a-f]{32}$")) and
        (.snapshot_set_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
        .zpool == "pulsar" and .zpool_health == "ONLINE" and
        .zfs_enumeration_succeeded == true and
        (.snapshots | type == "array" and length == 4) and
        [.snapshots[].dataset] == datasets and
        all(.snapshots[];
          (keys | sort) == ["dataset","dataset_enumeration_succeeded","hold_absent",
            "hold_tag","snapshot","snapshot_absent"] and
          .snapshot == (.dataset + "@v30.1.4-hotfix-candidate-node27-" + $nonce) and
          .hold_tag == ("blackcoin-hotfix-candidate-node27-" + $nonce) and
          .dataset_enumeration_succeeded == true and
          .snapshot_absent == true and .hold_absent == true) and
        .all_snapshots_absent == true and .all_holds_absent == true
    ' "$file" >/dev/null
}

hotfix_phase_b_authority_receipt_file_is_valid()
{
    local file="$1" result_sha="$2" run_nonce="$3"
    [[ -f "$file" && ! -L "$file" ]] || return 1
    jq -e --arg result "$result_sha" --arg nonce "$run_nonce" \
        --arg image_ref "$HOTFIX_CANDIDATE_IMAGE_REF" '
        def hex64: type == "string" and test("^[0-9a-f]{64}$");
        def integer: type == "number" and floor == .;
        def authority_files: ["SHA256SUMS","RESULT.json","REWIND_SAFE.json",
          "snapshot-set.json","snapshot-absence-proof.json","candidate-loaded-image.json",
          "candidate-bundle-manifest.json","candidate-oci-identity.json",
          "candidate-binary-sha256sums.txt","baseline-runtime-identity.json",
          "candidate-invocation-restart.json","base-catchup-proof.json",
          "guard-source-identity.json","maintenance-marker-activated.json",
          "unlock-helper-audit.json","tooling-identity.json",
          "base-quarantine-stop-authority.json","baseline-restored-container.json"];
        type == "object" and
        (keys | sort) == (["all_copies_manifest_bound","candidate_blackcoin_qt_sha256",
          "candidate_image_id","candidate_image_ref","candidate_manifest_digest",
          "compose_sha256","copied_under_all_four_locks","files",
          "maintenance_marker_sha256","phase_a_result_sha256","phase_a_run_nonce","schema",
          "source_manifest_sha256","source_reverified_after_copy",
          "source_reverified_immediately_before_copy","tooling_commit"] | sort) and
        (.schema | integer and . == 1) and .phase_a_result_sha256 == $result and
        .phase_a_run_nonce == $nonce and ($result | hex64) and
        ($nonce | test("^[0-9a-f]{32}$")) and
        .candidate_image_ref == $image_ref and
        (.candidate_image_id | test("^sha256:[0-9a-f]{64}$")) and
        (.candidate_manifest_digest | test("^sha256:[0-9a-f]{64}$")) and
        (.candidate_blackcoin_qt_sha256 | hex64) and (.compose_sha256 | hex64) and
        (.tooling_commit | type == "string" and test("^[0-9a-f]{40}$")) and
        (.source_manifest_sha256 | hex64) and (.maintenance_marker_sha256 | hex64) and
        .copied_under_all_four_locks == true and
        .source_reverified_immediately_before_copy == true and
        .source_reverified_after_copy == true and .all_copies_manifest_bound == true and
        (.files | type == "object") and
        ((.files | keys | sort) == (authority_files | sort)) and
        all(.files[]; hex64)
    ' "$file" >/dev/null
}

hotfix_phase_b_tooling_identity_file_is_valid()
{
    local file="$1" expected_tooling="${2:-}" expected_package="${3:-}"
    local expected_script="${4:-}" expected_verifier="${5:-}" expected_contract="${6:-}"
    [[ -f "$file" && ! -L "$file" ]] || return 1
    jq -e --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" \
        --arg tooling "$expected_tooling" --arg package "$expected_package" \
        --arg script "$expected_script" --arg verifier "$expected_verifier" \
        --arg contract "$expected_contract" '
        def hex64: type == "string" and test("^[0-9a-f]{64}$");
        def matches($expected): $expected == "" or . == $expected;
        type == "object" and
        (keys | sort) == (["candidate_source_sha","exact_bytes_recorded_before_irreversible_marker",
          "package_sha256sums_sha256","phase_b_script_sha256","schema","tooling_commit",
          "typed_contract_sha256","verifier_sha256"] | sort) and
        .schema == 1 and .candidate_source_sha == $source and
        (.tooling_commit | type == "string" and test("^[0-9a-f]{40}$") and
          matches($tooling)) and
        (.package_sha256sums_sha256 | hex64 and matches($package)) and
        (.phase_b_script_sha256 | hex64 and matches($script)) and
        (.verifier_sha256 | hex64 and matches($verifier)) and
        (.typed_contract_sha256 | hex64 and matches($contract)) and
        .exact_bytes_recorded_before_irreversible_marker == true
    ' "$file" >/dev/null
}

hotfix_phase_b_live_dataset_file_is_valid()
{
    local file="$1"
    [[ -f "$file" && ! -L "$file" ]] || return 1
    jq -e '
        def expected: [
          {dataset:"pulsar/Blackcoin_Blocks/node-data/node-27",
           mount_path:"/mnt/pulsar/Blackcoin_Blocks/node-data/node-27"},
          {dataset:"pulsar/Blackcoin_Blocks/node-data/node-27/blocks",
           mount_path:"/mnt/pulsar/Blackcoin_Blocks/node-data/node-27/blocks"},
          {dataset:"pulsar/Blackcoin_Blocks/node-data/node-27/indexes",
           mount_path:"/mnt/pulsar/Blackcoin_Blocks/node-data/node-27/indexes"},
          {dataset:"pulsar/Blackcoin_Blocks/alpha-chain-raw-clones-20260715T032403Z/node-27",
           mount_path:"/mnt/pulsar/Blackcoin_Blocks/27/blocks"}];
        type == "object" and (keys | sort) == ["datasets","schema"] and .schema == 1 and
        (.datasets | type == "array" and length == 4) and
        [.datasets[] | {dataset,mount_path}] == expected and
        all(.datasets[];
          (keys | sort) == ["dataset","guid","mount_path"] and
          (.guid | type == "string" and test("^[1-9][0-9]*$")))
    ' "$file" >/dev/null
}

hotfix_phase_b_baseline_precondition_file_is_valid()
{
    local file="$1"
    [[ -f "$file" && ! -L "$file" ]] || return 1
    jq -e '
        def integer: type == "number" and floor == .;
        def hex64: type == "string" and test("^[0-9a-f]{64}$");
        type == "object" and
        (keys | sort) == (["exact_loaded_wallets","irreversible_marker_allowed",
          "main_chain_ready","observed_epoch","p2p_ready","payout_address","payout_owned",
          "pending_recovery_actions_zero","quantum_key_count","recovery_database_unambiguous",
          "recovery_metrics_sha256","recovery_policy_nonautomatic","recovery_policy_sha256",
          "schema","stable_tip","staking_active","wallet_normally_unlocked"] | sort) and
        .schema == 1 and (.observed_epoch | integer and . > 0) and
        (.stable_tip | hex64) and
        .main_chain_ready == true and .p2p_ready == true and
        .wallet_normally_unlocked == true and .exact_loaded_wallets == [""] and
        .staking_active == true and (.payout_address | type == "string" and length > 0) and
        .payout_owned == true and (.quantum_key_count | integer and . > 0) and
        (.recovery_policy_sha256 | hex64) and (.recovery_metrics_sha256 | hex64) and
        .recovery_database_unambiguous == true and .recovery_policy_nonautomatic == true and
        .pending_recovery_actions_zero == true and .irreversible_marker_allowed == true
    ' "$file" >/dev/null
}

hotfix_phase_b_baseline_bundle_is_valid()
{
    local root="$1" pre chain chain_after wallet network staking recovery pow loaded payout
    local observed tip fee policy metrics quantum_count
    for pre in baseline-precondition.json baseline-chain.json baseline-chain-after.json \
        baseline-wallet.json baseline-network.json baseline-staking.json baseline-recovery.json \
        baseline-pow.json baseline-loaded-wallets.json baseline-quantum.json \
        baseline-payout-address.json; do
        [[ -f "$root/$pre" && ! -L "$root/$pre" ]] || return 1
    done
    pre="$root/baseline-precondition.json"
    hotfix_phase_b_baseline_precondition_file_is_valid "$pre" || return 1
    chain="$root/baseline-chain.json"
    chain_after="$root/baseline-chain-after.json"
    wallet="$root/baseline-wallet.json"
    network="$root/baseline-network.json"
    staking="$root/baseline-staking.json"
    recovery="$root/baseline-recovery.json"
    pow="$root/baseline-pow.json"
    loaded="$root/baseline-loaded-wallets.json"
    observed=$(jq -er '.observed_epoch' "$pre") || return 1
    tip=$(jq -er '.stable_tip' "$pre") || return 1
    jq -e --arg tip "$tip" --slurpfile after "$chain_after" '
      def integer: type == "number" and floor == .;
      .chain == "main" and .initialblockdownload == false and
      (.blocks | integer and . >= 0) and .blocks == .headers and
      .bestblockhash == $tip and (.chainwork | type == "string" and
        test("^[0-9a-f]{64}$")) and
      .bestblockhash == $after[0].bestblockhash and .chainwork == $after[0].chainwork and
      .blocks == $after[0].blocks and .headers == $after[0].headers
    ' "$chain" >/dev/null || return 1
    jq -e --argjson observed "$observed" '
      def integer: type == "number" and floor == .;
      .walletname == "" and .private_keys_enabled == true and .scanning == false and
      .unlocked_staking_only == false and (.unlocked_until | integer) and
      .unlocked_until > $observed
    ' "$wallet" >/dev/null || return 1
    jq -e '(.networkactive|type)=="boolean" and .networkactive==true and
      (.connections_out|type)=="number" and (.connections_out|floor)==.connections_out and
      .connections_out>=3' "$network" >/dev/null || return 1
    hotfix_phase_b_staking_json_is_active "$(<"$staking")" || return 1
    fee=$(jq -ce '.confirmed_resolution_fees' "$recovery") || return 1
    hotfix_candidate_recovery_json_is_valid "$(<"$recovery")" "$fee" || return 1
    jq -e --arg tip "$tip" '.active_tip==$tip and .wallet_processed_tip==$tip and
      .pending_manual_resolutions==0 and .pending_automatic_resolutions==0' \
      "$recovery" >/dev/null || return 1
    jq -e '(.enabled|type)=="boolean" and (.payout_address|type)=="string" and
      (.payout_address|length)>0' "$pow" >/dev/null || return 1
    payout=$(jq -er '.payout_address' "$pow") || return 1
    [[ "$payout" == "$(jq -er '.payout_address' "$pre")" ]] || return 1
    jq -e --arg payout "$payout" '.address==$payout and .ismine==true' \
        "$root/baseline-payout-address.json" >/dev/null || return 1
    jq -e '. == [""]' "$loaded" >/dev/null || return 1
    quantum_count=$(jq -er 'if type=="array" then length
      elif (.keys?|type)=="array" then (.keys|length)
      elif (.inventory?|type)=="array" then (.inventory|length)
      elif (.total?|type)=="number" and (.total|floor)==.total and .total>=0 then .total
      else error("schema") end' "$root/baseline-quantum.json") || return 1
    [[ "$quantum_count" == "$(jq -er '.quantum_key_count' "$pre")" ]] || return 1
    policy=$(jq -cS '{policy_authoritative,policy_state_status,policy}' "$recovery" |
        sha256sum | awk '{print $1}') || return 1
    metrics=$(jq -cS '{pending_manual_resolutions,pending_automatic_resolutions,
      confirmed_manual_resolutions,confirmed_automatic_resolutions,confirmed_resolution_fees,
      automatic_actions_in_window,automatic_fee_exposure_in_window,
      reconciled_descendant_claims,claims_recycled}' "$recovery" |
        sha256sum | awk '{print $1}') || return 1
    [[ "$policy" == "$(jq -er '.recovery_policy_sha256' "$pre")" &&
       "$metrics" == "$(jq -er '.recovery_metrics_sha256' "$pre")" ]]
}

hotfix_phase_b_locked_sync_file_is_valid()
{
    local file="$1" fee recovery
    [[ -f "$file" && ! -L "$file" ]] || return 1
    jq -e '
        def integer: type == "number" and floor == .;
        def hex64: type == "string" and test("^[0-9a-f]{64}$");
        type == "object" and (keys | sort) == ["chain","recovery","schema","synchronized","wallet"] and
        .schema == 1 and .synchronized == true and
        (.chain | type) == "object" and .chain.chain == "main" and
        .chain.initialblockdownload == false and
        (.chain.blocks | integer and . >= 0) and .chain.blocks == .chain.headers and
        (.chain.bestblockhash | hex64) and
        .recovery.active_tip == .chain.bestblockhash and
        .recovery.wallet_processed_tip == .chain.bestblockhash and
        (.wallet | type) == "object" and .wallet.walletname == "" and
        .wallet.private_keys_enabled == true and .wallet.scanning == false and
        .wallet.unlocked_until == 0
    ' "$file" >/dev/null || return 1
    recovery=$(jq -ce '.recovery' "$file") || return 1
    fee=$(jq -ce '.recovery.confirmed_resolution_fees' "$file") || return 1
    hotfix_candidate_recovery_json_is_valid "$recovery" "$fee"
}

hotfix_phase_b_cutover_stop_file_is_valid()
{
    local file="$1"
    [[ -f "$file" && ! -L "$file" ]] || return 1
    jq -e --arg image "$IMMUTABLE_V3014_IMAGE_ID" \
        --arg ref "$IMMUTABLE_V3014_IMAGE_REF" '
      def integer: type == "number" and floor == .;
      def restart_policy:
        type == "object" and (keys | sort) == ["MaximumRetryCount","Name"] and
        (.Name | type == "string" and length > 0) and
        (.MaximumRetryCount | integer and . >= 0);
      type == "object" and
      (keys | sort) == (["armed_restart_policy","clean_rpc_stop_completed","container_id",
        "image_id","image_ref","old_core_restart_observed","original_restart_policy",
        "restart_authority_disabled_before_rpc_stop","restart_count_armed",
        "restart_count_before","restart_count_stopped_first","restart_count_stopped_second",
        "schema","stable_stopped_samples","started_at_armed","started_at_before",
        "stopped_exit_code_first","stopped_exit_code_second",
        "stopped_finished_at_first","stopped_finished_at_second",
        "stopped_restart_policy_first","stopped_restart_policy_second",
        "stopped_started_at_first","stopped_started_at_second"] | sort) and
      .schema == 1 and (.container_id | test("^[0-9a-f]{64}$")) and
      .image_id == $image and .image_ref == $ref and
      (.original_restart_policy | restart_policy) and
      .armed_restart_policy == {Name:"no",MaximumRetryCount:0} and
      .stopped_restart_policy_first == .armed_restart_policy and
      .stopped_restart_policy_second == .armed_restart_policy and
      (.started_at_before | type == "string" and length > 0) and
      .started_at_armed == .started_at_before and
      .stopped_started_at_first == .started_at_before and
      .stopped_started_at_second == .started_at_before and
      (.stopped_finished_at_first | type == "string" and length > 0) and
      .stopped_finished_at_second == .stopped_finished_at_first and
      .stopped_exit_code_first == 0 and .stopped_exit_code_second == 0 and
      (.restart_count_before | integer and . >= 0) and
      .restart_count_armed == .restart_count_before and
      .restart_count_stopped_first == .restart_count_before and
      .restart_count_stopped_second == .restart_count_before and
      .restart_authority_disabled_before_rpc_stop == true and
      .clean_rpc_stop_completed == true and .stable_stopped_samples == 2 and
      .old_core_restart_observed == false
    ' "$file" >/dev/null
}

hotfix_phase_b_wallet_delta_file_is_valid()
{
    local file="$1" raw_file="${2:-}"
    [[ -f "$file" && ! -L "$file" ]] || return 1
    jq -e '
        def hex64: type == "string" and test("^[0-9a-f]{64}$");
        def txids: type == "array" and all(.[]; hex64) and (unique | length) == length;
        type == "object" and
        (keys | sort) == ["allowed_classes","baseline_txids","classifications","complete",
          "new_txids","raw_evidence_sha256","rejected_txids","removed_txids","schema"] and
        .schema == 1 and
        (.baseline_txids | txids) and (.new_txids | txids) and
        ([.baseline_txids[],.new_txids[]] | unique | length) ==
          ((.baseline_txids | length) + (.new_txids | length)) and
        .allowed_classes == ["confirmed_coinstake","authenticated_qq_claim",
          "authenticated_qq_claim_payout"] and
        .removed_txids == [] and .rejected_txids == [] and .complete == true and
        (.raw_evidence_sha256 | hex64) and
        (.classifications | type == "array") and
        (.classifications | length) == (.new_txids | length) and
        ([.classifications[].txid] | sort) == (.new_txids | sort) and
        all(.classifications[];
          (.txid | hex64) and
          if .class == "confirmed_coinstake" then
            (keys | sort) == ["blockhash","class","txid"] and (.blockhash | hex64)
          elif .class == "authenticated_qq_claim" then
            (keys | sort) == ["class","txid"]
          elif .class == "authenticated_qq_claim_payout" then
            (keys | sort) == ["blockhash","class","source_claim_txid","txid"] and
            (.blockhash | hex64) and (.source_claim_txid | hex64)
          else false end)
    ' "$file" >/dev/null || return 1
    if [[ -n "$raw_file" ]]; then
        hotfix_phase_b_wallet_delta_raw_file_is_valid "$raw_file" || return 1
        [[ "$(hotfix_sha256_file "$raw_file")" == \
           "$(jq -er '.raw_evidence_sha256' "$file")" ]] || return 1
        jq -e --slurpfile raw "$raw_file" '
          ([.classifications[] | {txid,class}] | sort_by(.txid)) ==
            ([$raw[0].records[] | {txid,class}] | sort_by(.txid)) and
          (.new_txids | sort) == ([$raw[0].records[].txid] | sort)
        ' "$file" >/dev/null
    fi
}

hotfix_phase_b_wallet_delta_raw_file_is_valid()
{
    local file="$1" expected_baseline="${2:-}" expected_final="${3:-}"
    local expected_recovery="${4:-}"
    [[ -f "$file" && ! -L "$file" ]] || return 1
    jq -e --arg baseline "$expected_baseline" --arg final "$expected_final" \
        --arg recovery "$expected_recovery" '
        def integer: type == "number" and floor == .;
        def hex64: type == "string" and test("^[0-9a-f]{64}$");
        def matches($expected): $expected == "" or . == $expected;
        type == "object" and
        (keys | sort) == ["baseline_wallet_transactions_sha256","complete",
          "final_wallet_transactions_sha256","records","recovery_inventory_sha256","schema"] and
        .schema == 1 and .complete == true and
        (.baseline_wallet_transactions_sha256 | hex64 and matches($baseline)) and
        (.final_wallet_transactions_sha256 | hex64 and matches($final)) and
        (.recovery_inventory_sha256 | hex64 and matches($recovery)) and
        (.records | type == "array") and
        ([.records[].txid] | unique | length) == (.records | length) and
        all(.records[]; . as $record |
          (keys | sort) == ["blockhash","class","getblock_response",
            "getshadowtransaction_response","recovery_matches","source_claim_txid",
            "txid","wallet_rows"] and
          (.txid | hex64) and (.wallet_rows | type == "array" and length >= 1) and
          all(.wallet_rows[]; type == "object" and .txid == $record.txid) and
          (.recovery_matches | type == "array") and
          if .class == "authenticated_qq_claim" then
            .blockhash == null and .source_claim_txid == null and
            .getblock_response == null and .getshadowtransaction_response == null and
            (.recovery_matches | length) == 1 and
            (.recovery_matches[0] as $match |
              $match.node.txid == $record.txid and
              $match.node.proof_origin_bound == true and
              $match.node.proof_input_bound == true and
              $match.node.expired_locally_retired == false and
              $match.component.all_claims_zero_payment_retirable == false and
              $match.component.all_claims_expired_locally_retired == false)
          elif .class == "confirmed_coinstake" then
            (.blockhash | hex64) and .source_claim_txid == null and
            .recovery_matches == [] and
            (.getblock_response | type == "object") and
            (.getblock_response.confirmations | integer and . > 0) and
            (.getblock_response.tx | type == "array" and length >= 2) and
            .getblock_response.tx[0] != .txid and .getblock_response.tx[1] == .txid and
            .getshadowtransaction_response == null
          elif .class == "authenticated_qq_claim_payout" then
            (.blockhash | hex64) and (.source_claim_txid | hex64) and
            .getblock_response == null and
            (.getshadowtransaction_response | type == "object") and
            .getshadowtransaction_response.schema == "blackcoin.shadow.transaction.v1" and
            .getshadowtransaction_response.synthetic == true and
            .getshadowtransaction_response.merkle_included == false and
            .getshadowtransaction_response.synthetic_txid == .txid and
            .getshadowtransaction_response.mode == "pow" and
            .getshadowtransaction_response.base_anchor.blockhash == .blockhash and
            .getshadowtransaction_response.pow_claim_source.txid == .source_claim_txid and
            .getshadowtransaction_response.pow_claim_source.input_bound == true and
            (.recovery_matches | length) == 1 and
            (.recovery_matches[0] as $match |
              $match.node.txid == $record.source_claim_txid and
              $match.node.proof_origin_bound == true and
              $match.node.proof_input_bound == true and
              $match.node.expired_locally_retired == false and
              $match.component.all_claims_zero_payment_retirable == false and
              $match.component.all_claims_expired_locally_retired == false)
          else false end)
    ' "$file" >/dev/null
}

hotfix_phase_b_final_container_file_is_valid()
{
    local file="$1" expected_ref="${2:-}" expected_id="${3:-}" expected_qt="${4:-}"
    local expected_config="${5:-}" expected_mounts="${6:-}" expected_network="${7:-}"
    local argv_sha
    [[ -f "$file" && ! -L "$file" ]] || return 1
    jq -e --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" --arg ref "$expected_ref" \
        --arg candidate_ref "$HOTFIX_CANDIDATE_IMAGE_REF" \
        --arg id "$expected_id" --arg qt "$expected_qt" --arg config "$expected_config" \
        --arg mounts "$expected_mounts" --arg network "$expected_network" \
        --arg start "$IMMUTABLE_START_GUI_SHA256" \
        --arg body "$HOTFIX_CANDIDATE_ENTRYPOINT_BODY_SHA256" \
        --arg sentinel "$HOTFIX_CANDIDATE_ENTRYPOINT_SENTINEL" '
        def integer: type == "number" and floor == .;
        def hex64: type == "string" and test("^[0-9a-f]{64}$");
        def matches($expected): $expected == "" or . == $expected;
        type == "object" and
        (keys | sort) == (["candidate_running_without_restart","candidate_source_sha",
          "config_sha256","container_id","entrypoint_body_sha256","identity_stable_across_two_samples",
          "image_id","image_ref","mounts_sha256","network_sha256","pid1_exe_sha256",
          "restart_policy","running_first","running_second","runtime_argv",
          "runtime_argv_sha256","schema","stable_restart_count","stable_started_at",
          "start_gui_sha256"] | sort) and
        .schema == 1 and .candidate_source_sha == $source and
        .image_ref == $candidate_ref and (.image_ref | matches($ref)) and
        (.image_id | test("^sha256:[0-9a-f]{64}$") and matches($id)) and
        (.container_id | type == "string" and test("^[0-9a-f]{64}$")) and
        .running_first == true and .running_second == true and
        (.stable_started_at | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")) and
        (.stable_restart_count | integer and . >= 0) and
        (.pid1_exe_sha256 | hex64 and matches($qt)) and
        .start_gui_sha256 == $start and .entrypoint_body_sha256 == $body and
        .runtime_argv == ["/usr/local/bin/blackcoin-qt",
          "-datadir=/home/blackcoin/.blackcoin","-walletbroadcast=1",
          "-autostartstaking=0","-powmining=0"] and
        (.runtime_argv_sha256 | hex64) and (.config_sha256 | hex64 and matches($config)) and
        (.mounts_sha256 | hex64 and matches($mounts)) and
        (.network_sha256 | hex64 and matches($network)) and
        (.restart_policy | type == "object") and
        ((.restart_policy | keys | sort) == ["MaximumRetryCount","Name"]) and
        (.restart_policy.Name | type == "string" and length > 0) and
        (.restart_policy.MaximumRetryCount | integer and . >= 0) and
        .identity_stable_across_two_samples == true and
        .candidate_running_without_restart == true
    ' "$file" >/dev/null || return 1
    argv_sha=$(jq '.runtime_argv' "$file" | sha256sum | awk '{print $1}') || return 1
    [[ "$argv_sha" == "$(jq -er '.runtime_argv_sha256' "$file")" ]]
}

hotfix_phase_b_final_envelope_file_is_valid()
{
    local file="$1" pow_mode="$2" wallet_delta_file="${3:-}"
    local expected_policy="${4:-}" expected_metrics="${5:-}"
    local wallet_delta_raw_file="${6:-}" fee recovery policy metrics
    [[ -f "$file" && ! -L "$file" && ( "$pow_mode" == active || "$pow_mode" == off ) ]] ||
        return 1
    jq -e --arg mode "$pow_mode" '
        def integer: type == "number" and floor == .;
        def hex64: type == "string" and test("^[0-9a-f]{64}$");
        type == "object" and
        (keys | sort) == (["chain","chain_after","chain_before_after_identical",
          "chain_recovery_pow_tip_bound","exact_loaded_wallets","loaded_wallets","network",
          "observed_epoch","pow","pow_mode","recovery","recovery_counters_unchanged",
          "recovery_metrics_sha256","recovery_policy_sha256","recovery_txids_unchanged",
          "schema","stable_tip","staking","wallet","wallet_delta_fully_classified",
          "wallet_delta_raw_sha256","wallet_delta_sha256","wallet_unlock_current"] | sort) and
        .schema == 1 and .pow_mode == $mode and
        (.observed_epoch | integer and . > 0) and (.stable_tip | hex64) and
        .chain_before_after_identical == true and .chain_recovery_pow_tip_bound == true and
        .wallet_unlock_current == true and .exact_loaded_wallets == [""] and
        .loaded_wallets == [""] and
        (.recovery_policy_sha256 | hex64) and (.recovery_metrics_sha256 | hex64) and
        .recovery_counters_unchanged == true and .recovery_txids_unchanged == true and
        (.wallet_delta_sha256 | hex64) and (.wallet_delta_raw_sha256 | hex64) and
        .wallet_delta_fully_classified == true and
        .chain.chain == "main" and .chain.initialblockdownload == false and
        (.chain.blocks | integer and . >= 0) and .chain.blocks == .chain.headers and
        (.chain.bestblockhash | hex64) and .chain.bestblockhash == .stable_tip and
        (.chain.chainwork | hex64) and
        .chain_after.chain == "main" and .chain_after.initialblockdownload == false and
        .chain_after.blocks == .chain.blocks and .chain_after.headers == .chain.headers and
        .chain_after.bestblockhash == .stable_tip and .chain_after.chainwork == .chain.chainwork and
        .network.networkactive == true and (.network.connections_out | integer and . >= 3) and
        .wallet.walletname == "" and .wallet.private_keys_enabled == true and
        .wallet.scanning == false and .wallet.unlocked_staking_only == false and
        (.wallet.unlocked_until | integer) and .wallet.unlocked_until > .observed_epoch and
        .recovery.active_tip == .stable_tip and .recovery.wallet_processed_tip == .stable_tip and
        .pow.claim_inventory_tip == .stable_tip and
        .staking.blocks == .chain.blocks and .staking.active_blocks == .chain.blocks and
        .staking.autostart_staking == false and
        .staking.autostart_staking_source == "autostartstaking" and
        .pow.raw_quarantined_claims == .recovery.raw_quarantined_claims and
        .pow.blocking_quarantined_claims == .recovery.blocking_quarantined_claims and
        .pow.actionable_quarantined_claims == .recovery.actionable_quarantined_claims and
        .pow.resolved_on_active_chain_claims == .recovery.resolved_on_active_chain_claims and
        .pow.indeterminate_quarantined_claims == .recovery.indeterminate_quarantined_claims and
        .pow.claim_components == .recovery.components and
        .pow.pending_manual_resolutions == .recovery.pending_manual_resolutions and
        .pow.pending_automatic_resolutions == .recovery.pending_automatic_resolutions and
        .pow.claims_auto_resolved == .recovery.confirmed_automatic_resolutions and
        .pow.claims_recycled == .recovery.claims_recycled and
        .pow.cumulative_resolution_fees == .recovery.confirmed_resolution_fees and
        .pow.claim_recovery_database_outcome_ambiguous == .recovery.database_outcome_ambiguous
    ' "$file" >/dev/null || return 1
    recovery=$(jq -ce '.recovery' "$file") || return 1
    fee=$(jq -ce '.recovery.confirmed_resolution_fees' "$file") || return 1
    hotfix_candidate_recovery_json_is_valid "$recovery" "$fee" || return 1
    hotfix_phase_b_staking_json_is_active "$(jq -ce '.staking' "$file")" || return 1
    hotfix_candidate_pow_json_is_valid "$(jq -ce '.pow' "$file")" "$pow_mode" || return 1
    policy=$(jq -cS '.recovery | {policy_authoritative,policy_state_status,policy}' "$file" |
        sha256sum | awk '{print $1}') || return 1
    metrics=$(jq -cS '.recovery | {pending_manual_resolutions,pending_automatic_resolutions,
      confirmed_manual_resolutions,confirmed_automatic_resolutions,confirmed_resolution_fees,
      automatic_actions_in_window,automatic_fee_exposure_in_window,
      reconciled_descendant_claims,claims_recycled}' "$file" | sha256sum | awk '{print $1}') ||
        return 1
    [[ "$policy" == "$(jq -er '.recovery_policy_sha256' "$file")" &&
       "$metrics" == "$(jq -er '.recovery_metrics_sha256' "$file")" ]] || return 1
    [[ -z "$expected_policy" || "$policy" == "$expected_policy" ]] || return 1
    [[ -z "$expected_metrics" || "$metrics" == "$expected_metrics" ]] || return 1
    if [[ -n "$wallet_delta_file" ]]; then
        hotfix_phase_b_wallet_delta_file_is_valid "$wallet_delta_file" "$wallet_delta_raw_file" &&
            [[ "$(hotfix_sha256_file "$wallet_delta_file")" == \
               "$(jq -er '.wallet_delta_sha256' "$file")" ]] &&
            [[ "$(jq -er '.raw_evidence_sha256' "$wallet_delta_file")" == \
               "$(jq -er '.wallet_delta_raw_sha256' "$file")" ]] || return 1
    fi
    if [[ -n "$wallet_delta_raw_file" ]]; then
        [[ "$(hotfix_sha256_file "$wallet_delta_raw_file")" == \
           "$(jq -er '.wallet_delta_raw_sha256' "$file")" ]] || return 1
    fi
}

hotfix_phase_b_containment_file_is_valid()
{
    local file="$1"
    [[ -f "$file" && ! -L "$file" ]] || return 1
    jq -e '
        type == "object" and
        (keys | sort) == (["automatic_start_authority_remains_suspended","contained",
          "container_exists","container_running_first","container_running_second",
          "datasets_preserved","enable_guard_starts_absent","maintenance_authority_exact",
          "promotion_marker_authority_exact","promotion_marker_mode","restart_policy_first",
          "restart_policy_second","restart_policy_set_to_no","stable_stopped",
          "suspended_start_marker_exact","timestamp","schema"] | sort) and
        .schema == 2 and .contained == true and
        (.container_exists | type) == "boolean" and .restart_policy_set_to_no == true and
        (if .container_exists then
           .container_running_first == "false" and
           .container_running_second == "false" and
           .restart_policy_first == {MaximumRetryCount:0,Name:"no"} and
           .restart_policy_second == .restart_policy_first
         else
           .container_running_first == "unknown" and
           .container_running_second == "unknown" and
           .restart_policy_first == null and .restart_policy_second == null
         end) and
        .stable_stopped == true and .datasets_preserved == true and
        (.promotion_marker_mode == "absent" or .promotion_marker_mode == "durable") and
        .promotion_marker_authority_exact == true and .suspended_start_marker_exact == true and
        .enable_guard_starts_absent == true and .maintenance_authority_exact == true and
        .automatic_start_authority_remains_suspended == true and
        (.timestamp | type == "string" and length > 0)
    ' "$file" >/dev/null
}

hotfix_promoted_marker_file_is_valid()
{
    local file="$1" phase_a_result_sha="$2"
    [[ -f "$file" && ! -L "$file" ]] || return 1
    jq -e --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" --arg result_sha "$phase_a_result_sha" \
        --arg image_ref "$HOTFIX_CANDIDATE_IMAGE_REF" '
        def hex64: type == "string" and test("^[0-9a-f]{64}$");
        def integer: type == "number" and floor == .;
        type == "object" and
        (keys | sort) == (["candidate_image_id","candidate_image_ref",
          "candidate_manifest_digest","candidate_source_sha","created_utc",
          "data_rewind_permanently_prohibited","marker_fsync_verified","node",
          "package_sha256sums_sha256","parent_directory_fsync_verified",
          "phase_a_authority_receipt_sha256","phase_a_evidence_sha256sums_sha256",
          "phase_a_result_sha256","phase_a_rewind_safe_sha256","phase_a_run_nonce",
          "phase_b_script_sha256","phase_b_tooling_identity_sha256","promotion_nonce",
          "reread_verified","schema","snapshots_absent_before_marker","state",
          "storage_absence_sha256","tooling_commit","typed_contract_sha256",
          "verifier_sha256"] | sort) and
        (.schema | integer and . == 1) and .state == "PROMOTED_NO_REWIND" and
        (.node | integer and . == 27) and .candidate_source_sha == $source and
        .phase_a_result_sha256 == $result_sha and
        ($result_sha | test("^[0-9a-f]{64}$")) and
        (.phase_a_evidence_sha256sums_sha256 | hex64) and
        (.phase_a_run_nonce | test("^[0-9a-f]{32}$")) and
        (.promotion_nonce | test("^[0-9a-f]{32}$")) and
        .promotion_nonce != .phase_a_run_nonce and
        (.storage_absence_sha256 | hex64) and
        (.phase_a_authority_receipt_sha256 | hex64) and
        (.phase_a_rewind_safe_sha256 | hex64) and
        .candidate_image_ref == $image_ref and
        (.candidate_image_id | test("^sha256:[0-9a-f]{64}$")) and
        (.candidate_manifest_digest | test("^sha256:[0-9a-f]{64}$")) and
        (.tooling_commit | type == "string" and test("^[0-9a-f]{40}$")) and
        (.phase_b_tooling_identity_sha256 | hex64) and
        (.package_sha256sums_sha256 | hex64) and
        (.phase_b_script_sha256 | hex64) and (.verifier_sha256 | hex64) and
        (.typed_contract_sha256 | hex64) and
        (.created_utc | type == "string" and
          test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
        .data_rewind_permanently_prohibited == true and .marker_fsync_verified == true and
        .parent_directory_fsync_verified == true and .reread_verified == true and
        .snapshots_absent_before_marker == true
    ' "$file" >/dev/null
}

hotfix_phase_b_result_file_is_valid()
{
    local file="$1" phase_a_result_sha="$2"
    [[ -f "$file" && ! -L "$file" ]] || return 1
    jq -e --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" --arg result_sha "$phase_a_result_sha" '
        def hex64: type == "string" and test("^[0-9a-f]{64}$");
        def integer: type == "number" and floor == .;
        def amount: type == "number" and . >= 0;
        type == "object" and
        (keys | sort) == (["baseline_automatic_fee_exposure_in_window",
          "baseline_confirmed_resolution_fees","baseline_health_gate_passed",
          "baseline_pending_automatic_resolutions","baseline_pending_manual_resolutions",
          "baseline_precondition_sha256","baseline_cutover_stop_sha256",
          "baseline_recovery_metrics_sha256",
          "baseline_recovery_policy_sha256","candidate_running","candidate_source_sha",
          "data_rewind_performed","datasets_preserved","failure_policy",
          "final_container_identity_stable","final_container_sha256","final_envelope_sha256",
          "invocation_sha256","live_dataset_identity_sha256","marker_sha256","node",
          "normal_unlock_completed","old_core_autostarted",
          "only_allowed_wallet_delta_classes_added","p2p_ready","package_sha256sums_sha256",
          "phase","phase_a_result_sha256","phase_b_progress_sha256",
          "phase_b_script_sha256","phase_b_tooling_identity_sha256","pos_active",
          "pos_explicitly_enabled","pow_policy_restored","pre_result_manifest_sha256",
          "promoted_no_rewind_marker_verified","quantum_keys_unchanged",
          "recovery_counters_unchanged","recovery_fees_unchanged","recovery_policy_unchanged",
          "resolution_txids_unchanged","result","schema","snapshots_absent_before_launch",
          "storage_absence_recheck_sha256","tooling_commit","typed_contract_sha256",
          "typed_gate_safe","verifier_sha256","wallet_chain_synchronized_before_unlock",
          "wallet_delta_fully_classified","wallet_delta_raw_sha256","wallet_delta_sha256",
          "payout_unchanged"] | sort) and
        (.schema | integer and . == 2) and .phase == "B" and
        (.node | integer and . == 27) and
        .result == "passed" and .candidate_source_sha == $source and
        .phase_a_result_sha256 == $result_sha and
        ($result_sha | test("^[0-9a-f]{64}$")) and
        .promoted_no_rewind_marker_verified == true and
        .snapshots_absent_before_launch == true and .datasets_preserved == true and
        .candidate_running == true and .wallet_chain_synchronized_before_unlock == true and
        .normal_unlock_completed == true and .pos_explicitly_enabled == true and
        .pos_active == true and .pow_policy_restored == true and
        .p2p_ready == true and .typed_gate_safe == true and
        .payout_unchanged == true and .quantum_keys_unchanged == true and
        .recovery_fees_unchanged == true and .resolution_txids_unchanged == true and
        .recovery_counters_unchanged == true and .recovery_policy_unchanged == true and
        .wallet_delta_fully_classified == true and
        .only_allowed_wallet_delta_classes_added == true and
        .baseline_health_gate_passed == true and .final_container_identity_stable == true and
        .failure_policy == "contain-stop-preserve" and .old_core_autostarted == false and
        .data_rewind_performed == false and
        (.marker_sha256 | hex64) and (.invocation_sha256 | hex64) and
        (.live_dataset_identity_sha256 | hex64) and
        (.storage_absence_recheck_sha256 | hex64) and
        (.phase_b_progress_sha256 | hex64) and
        (.pre_result_manifest_sha256 | hex64) and
        (.final_container_sha256 | hex64) and (.final_envelope_sha256 | hex64) and
        (.wallet_delta_sha256 | hex64) and (.wallet_delta_raw_sha256 | hex64) and
        (.baseline_precondition_sha256 | hex64) and
        (.baseline_cutover_stop_sha256 | hex64) and
        (.tooling_commit | type == "string" and test("^[0-9a-f]{40}$")) and
        (.phase_b_tooling_identity_sha256 | hex64) and
        (.package_sha256sums_sha256 | hex64) and (.phase_b_script_sha256 | hex64) and
        (.verifier_sha256 | hex64) and (.typed_contract_sha256 | hex64) and
        (.baseline_recovery_policy_sha256 | hex64) and
        (.baseline_recovery_metrics_sha256 | hex64) and
        (.baseline_pending_manual_resolutions | integer and . >= 0) and
        (.baseline_pending_automatic_resolutions | integer and . >= 0) and
        (.baseline_automatic_fee_exposure_in_window | amount) and
        (.baseline_confirmed_resolution_fees | amount)
    ' "$file" >/dev/null
}
