# shellcheck shell=bash
# Pure, read-only predicates shared by both canary phases and the offline verifier.
# shellcheck disable=SC2034 # Readonly package constants are consumed by sourcing callers.

export LC_ALL=C

readonly HOTFIX_EXPECTED_RELEASE_VERSION='30.1.5'
readonly HOTFIX_EXPECTED_CANDIDATE_SOURCE_SHA='__FINAL_SIGNED_CORE_SHA__'
readonly HOTFIX_EXPECTED_CORE_CI_RUN_ID='__FINAL_EXACT_SHA_CORE_CI_RUN_ID__'
readonly HOTFIX_EXPECTED_CORE_CI_PULL_REQUEST_BASE_SHA='19baffef25af36e177db2975780e0641b59753aa'
readonly HOTFIX_EXPECTED_CORE_CI_WORKFLOW_BLOB_SHA256='24c14f2fe4bd7b25de38e71a80bf05efcec00d2b3009c3efd4ad20b90bbda869'
# Candidate source/release may be supplied by a reviewed environment, but these
# unresolved sentinels deliberately fail the exact identity predicate. A later
# reviewed identity-only repin must replace both sentinels with exact values.
: "${HOTFIX_CANDIDATE_SOURCE_SHA:=$HOTFIX_EXPECTED_CANDIDATE_SOURCE_SHA}"
: "${HOTFIX_CANDIDATE_RELEASE_VERSION:=$HOTFIX_EXPECTED_RELEASE_VERSION}"
readonly HOTFIX_CANDIDATE_SOURCE_SHA HOTFIX_CANDIDATE_RELEASE_VERSION
readonly HOTFIX_CANDIDATE_SHORT_SHA="${HOTFIX_CANDIDATE_SOURCE_SHA:0:12}"
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
        [[ "$HOTFIX_CANDIDATE_SOURCE_SHA" == "$HOTFIX_EXPECTED_CANDIDATE_SOURCE_SHA" ]] &&
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

# Compare public quantum-key inventories without treating Core's one permitted
# legacy payout-label normalization as key creation, deletion, or rotation.
# The optional label evidence is the exact getaddressesbylabel output captured
# for the three recognized payout labels; it proves that a relabeled address
# stayed a receive-purpose address on both sides of the transition.
hotfix_quantum_inventory_transition_is_valid()
{
    local before="$1" after="$2" before_labels="$3" after_labels="$4"
    [[ -f "$before" && ! -L "$before" && -f "$after" && ! -L "$after" &&
       -f "$before_labels" && ! -L "$before_labels" &&
       -f "$after_labels" && ! -L "$after_labels" ]] || return 1
    jq -e -n --slurpfile before "$before" --slurpfile after "$after" \
        --slurpfile before_labels "$before_labels" \
        --slurpfile after_labels "$after_labels" '
      def entries:
        if type == "array" then .
        elif (.keys? | type) == "array" then .keys
        elif (.inventory? | type) == "array" then .inventory
        else error("unsupported quantum inventory") end;
      def aggregate:
        if type == "array" then null
        elif (.keys? | type) == "array" then del(.keys)
        elif (.inventory? | type) == "array" then del(.inventory)
        else error("unsupported quantum inventory") end;
      def identity: del(.label) | tojson;
      def key_label: (.label? // "");
      def legacy_label:
        . == "Quantum PoW Reward Address" or . == "goldrush-pow";
      def label_evidence:
        type == "object" and (keys | sort) == ["labels","schema"] and
        .schema == 1 and (.labels | type) == "array" and
        .labels == (.labels | sort_by(.label)) and
        ([.labels[].label] | unique | length) == (.labels | length) and
        all(.labels[];
          type == "object" and (keys | sort) == ["addresses","label"] and
          (.label | IN("PoW - Quantum Claim Address",
            "Quantum PoW Reward Address","goldrush-pow")) and
          (.addresses | type) == "object" and
          all(.addresses[]; type == "object" and
            (keys | sort) == ["purpose"] and (.purpose | type) == "string"));
      def receive_bound($evidence;$label;$address):
        any($evidence.labels[];
          .label == $label and .addresses[$address].purpose == "receive");
      ($before[0]) as $b | ($after[0]) as $a |
      ($b | entries | sort_by(identity)) as $bk |
      ($a | entries | sort_by(identity)) as $ak |
      ($b | aggregate) == ($a | aggregate) and
      ($bk | length) == ($ak | length) and
      ([range(0; $bk | length) as $i |
        ($bk[$i] | identity) == ($ak[$i] | identity)] | all) and
      ($before_labels[0] | label_evidence) and
      ($after_labels[0] | label_evidence) and
      all(range(0; $bk | length); . as $i |
        ($bk[$i] | key_label) as $old | ($ak[$i] | key_label) as $new |
        if $old == $new then true
        else
          ($old | legacy_label) and $new == "PoW - Quantum Claim Address" and
          ($bk[$i].address? | type) == "string" and
          ($ak[$i].address? == $bk[$i].address) and
          receive_bound($before_labels[0];$old;$bk[$i].address) and
          receive_bound($after_labels[0];$new;$ak[$i].address)
        end)
    ' >/dev/null
}

# A nonempty process-local future payout is acceptable only when it resolves to
# an already inventoried, spendable quantum-migration key.  This does not claim
# that the address is the payout of any retained claim family.
hotfix_quantum_payout_address_is_valid()
{
    local address_file="$1" inventory_file="$2" expected="$3"
    [[ -n "$expected" && -f "$address_file" && ! -L "$address_file" &&
       -f "$inventory_file" && ! -L "$inventory_file" ]] || return 1
    jq -e --arg expected "$expected" --slurpfile inventory "$inventory_file" '
      def entries:
        if type == "array" then .
        elif (.keys? | type) == "array" then .keys
        elif (.inventory? | type) == "array" then .inventory
        else error("unsupported quantum inventory") end;
      .address == $expected and .ismine == true and .solvable == true and
      .iswatchonly == false and .isquantummigration == true and
      .hasquantumkey == true and (.isquantumcoldstake? // false) == false and
      ([$inventory[0] | entries[] |
        select(.address == $expected and .tiered == false and
          .stored_in_wallet == true)] | length) == 1
    ' "$address_file" >/dev/null
}

hotfix_exact_phase_a_flags_json()
{
    jq -ce -n '["-walletbroadcast=0","-blocksonly=1","-staking=0",
        "-autostartstaking=0","-powmining=0","-qqautoshadowsignal=0",
        "-qqautodemurrageattest=0"]'
}

hotfix_exact_phase_b_flags_json()
{
    jq -ce -n '["-walletbroadcast=1","-autostartstaking=1","-powmining=1",
      "-powminingthreads=1","-powminingcpu=1"]'
}

hotfix_candidate_pow_json_is_valid()
{
    local mining="$1" phase="$2"
    [[ "$phase" == active || "$phase" == locked || "$phase" == off ]] || return 1
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
          (if .mining_gate_action == "create_new_anchor" or
               (.mining_gate_action == "wait_for_next_tip" and
                .mining_gate_lineage_head_txid == $zero) then
             .mining_gate_lineage_head_txid == $zero and
             .mining_gate_unresolved_components == 0 and
             .mining_gate_live_claims == 0 and .mining_gate_eligible_claims == 0 and
             .mining_gate_family_claims == 0
           else
             .mining_gate_lineage_head_txid != $zero and
             .mining_gate_unresolved_components >= 1 and .mining_gate_family_claims >= 1
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
           then .mining_gate_eligible_claims >= 1
           elif .mining_gate_action == "refresh_same_anchor"
           then true
           elif .mining_gate_action == "wait_for_next_tip"
           then (if .mining_gate_relay_txid == $zero
              then true
              else .mining_gate_can_submit == false and
                .mining_gate_eligible_claims >= 1 end)
           else true end);
        $mining | type == "object" and
          ((keys | sort) == (pow_keys | sort)) and
          (.enabled | type) == "boolean" and
          (.autostart | type) == "boolean" and
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
          (.payout_address | type == "string") and
          (if .mining_gate_action == "create_new_anchor"
           then (.payout_address | length) > 0 else true end) and
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
            .stake_reserve_snapshot_available == true
          elif $phase == "locked" then
            .enabled == true and .autostart == true and .threads == 1 and
            .cpu_percent == 1 and .hashrate == 0 and .claims_submitted == 0 and
            .state == "wallet_locked_or_staking_only"
          else
            .enabled == false and .state == "disabled" and .hashrate == 0
          end
    ' >/dev/null
}

hotfix_candidate_recovery_json_is_valid()
{
    local recovery="$1"
    jq -e -n --argjson recovery "$recovery" '
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
          "anchor_authenticated","anchor_unspent","anchor_user_locked","claim_txids","classification",
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
        ($recovery.confirmed_resolution_fees | amount) and
        ($recovery.automatic_fee_exposure_in_window | amount) and
        ($recovery.component_details | type == "array") and
        all($recovery.component_details[]; . as $component |
          type == "object" and (keys | sort) == (component_keys | sort) and
          (.anchor | type) == "object" and
          (.anchor | keys | sort) == ["amount","scriptPubKey","txid","vout"] and
          (.anchor.txid | hex64) and (.anchor.vout | uint) and
          (.anchor.amount | amount) and
          # Full recovery telemetry can retain audit-only incoming components
          # that have no authenticated wallet anchor.  Their default anchor
          # script is empty; mining authority is decided by the typed gate,
          # not by rejecting that retained telemetry shape here.
          (.anchor.scriptPubKey | type == "string" and test("^([0-9a-f]{2})*$")) and
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
          (.anchor_user_locked | type) == "boolean" and
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
            (.disposition | IN("eligible","inactive","height_before_window",
              "height_after_window","invalid_location","malformed","duplicate",
              "wrong_mode","unknown_mode","unsupported_version",
              "version_not_yet_active","invalid_proof",
              "unbound_proof_may_revalidate","origin_not_yet_reached",
              "origin_mismatch","origin_expired","input_mismatch",
              "already_accounted","capacity_limit","evaluation_limit",
              "local_state_error")) and
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
        # `components` is compatibility telemetry while verbose
        # `component_details` is the full audit inventory.  The two views are
        # intentionally not required to have the same cardinality.
        ([$recovery.component_details[].nodes[].txid] | length) ==
          ([$recovery.component_details[].nodes[].txid] | unique | length) and
        ($recovery.unanchored_claim_txids | type == "array" and
          all(.[]; hex64) and
          ($recovery.unanchored_claim_txids | unique | length) ==
            ($recovery.unanchored_claim_txids | length))
    ' >/dev/null
}

# Canonical authority projections for a repeated terminal cut.  Compatibility,
# retained-history, and verbose audit inventory are deliberately excluded: they
# are telemetry, not mining authority.  Each cut is validated independently
# against the complete typed observation contract; equality here binds only the
# chain/wallet cut, recovery policy authority, and the Core-selected operational
# gate.  It must never recreate family selection from host-side inventory.
hotfix_recovery_authority_json_sha256()
{
    local recovery="$1"
    jq -ceS '
      {active_tip,active_height,wallet_processed_tip,wallet_processed_height,
       wallet_generation,chain_ready,wallet_tip_matches,database_outcome_ambiguous,
       policy_authoritative,
       policy:{automatic_enabled:.policy.automatic_enabled,
               automatic_authorized:.policy.automatic_authorized}}
    ' <<<"$recovery" | sha256sum | awk '{print $1}'
}

hotfix_pow_gate_authority_json_sha256()
{
    local pow="$1"
    jq -ceS '
      {enabled,claim_inventory_tip,
       claim_inventory_wallet_tip_matches,
       mining_gate_action,mining_gate_can_submit,mining_gate_coherent,
       mining_gate_database_ambiguous,mining_gate_unsafe_claims,
       mining_gate_unsafe_components,mining_gate_lineage_head_txid,
       mining_gate_relay_txid,mining_gate_family_claims,
       mining_gate_live_claims,mining_gate_eligible_claims,
       mining_gate_unresolved_components}
    ' <<<"$pow" | sha256sum | awk '{print $1}'
}

# Bind the two candidate RPC views captured in one observation. These are
# structural equalities for recovery-operation telemetry within one
# candidate-native cut. Legacy claim inventory counters are type-only and are
# deliberately not compared between RPC views.
hotfix_pow_recovery_same_cut_json_is_valid()
{
    local pow="$1" recovery="$2"
    jq -e -n --argjson pow "$pow" --argjson recovery "$recovery" '
      $pow.pending_manual_resolutions == $recovery.pending_manual_resolutions and
      $pow.pending_automatic_resolutions == $recovery.pending_automatic_resolutions and
      $pow.claims_auto_resolved == $recovery.confirmed_automatic_resolutions and
      $pow.claims_recycled == $recovery.claims_recycled and
      $pow.cumulative_resolution_fees == $recovery.confirmed_resolution_fees and
      $pow.claim_recovery_database_outcome_ambiguous ==
        $recovery.database_outcome_ambiguous
    ' >/dev/null
}

# Bind the exact signed-H getgoldrushstate schedule projection to the active
# chain cut used by mining authority.  QQP4 activation is a consensus schedule,
# not a wallet/recovery heuristic: disabled schedules serialize height 0 and
# can never be active, while enabled schedules derive both active flags solely
# from the captured height.
hotfix_goldrush_state_json_is_valid()
{
    local state="$1" tip="$2" height="$3"
    jq -e -n --arg tip "$tip" --argjson height "$height" --argjson state "$state" '
      def integer: type == "number" and floor == .;
      def uint: integer and . >= 0;
      def hex64: type == "string" and test("^[0-9a-f]{64}$");
      ($tip | hex64) and ($height | uint) and
      ($state | type) == "object" and
      ($state | keys | sort) == (["bestblock","height","qqp4_activation_disabled",
        "qqp4_activation_height","qqp4_active","qqp4_active_next_block"] | sort) and
      $state.bestblock == $tip and $state.height == $height and
      ($state.qqp4_activation_disabled | type) == "boolean" and
      ($state.qqp4_activation_height | uint) and
      ($state.qqp4_active | type) == "boolean" and
      ($state.qqp4_active_next_block | type) == "boolean" and
      if $state.qqp4_activation_disabled then
        $state.qqp4_activation_height == 0 and
        $state.qqp4_active == false and
        $state.qqp4_active_next_block == false
      else
        $state.qqp4_activation_height > 0 and
        $state.qqp4_active == ($height >= $state.qqp4_activation_height) and
        $state.qqp4_active_next_block ==
          (($height + 1) >= $state.qqp4_activation_height)
      end
    ' >/dev/null
}

# Bind one typed gate observation to the authoritative recovery family and the
# raw verbose mempool snapshot captured in the same stable cut. This uses only
# fields already exposed by getpowmininginfo, getpowclaimrecoveryinfo true, and
# getrawmempool true.
hotfix_pow_observation_json_is_valid()
{
    local pow="$1" recovery="$2" mempool="$3" tip="$4" height="$5" observed="$6"
    local goldrush_state="$7"
    hotfix_pow_recovery_same_cut_json_is_valid "$pow" "$recovery" || return 1
    hotfix_goldrush_state_json_is_valid "$goldrush_state" "$tip" "$height" || return 1
    jq -e -n --arg zero "$HOTFIX_ZERO_TXID" --arg tip "$tip" \
        --argjson height "$height" --argjson observed "$observed" \
        --argjson pow "$pow" --argjson recovery "$recovery" \
        --argjson mempool "$mempool" --argjson goldrush "$goldrush_state" '
        def integer: type == "number" and floor == .;
        def uint: integer and . >= 0;
        def hex64: type == "string" and test("^[0-9a-f]{64}$");
        def claim_nodes($component):
          $component.nodes | map(select(.kind == "claim")) |
          sort_by(.lineage_ordinal);
        # ParseClaimLineage deliberately leaves every lineage descriptor at
        # its zero default for the one permitted metadata-absent root.  Core
        # derives that root from the node txid; it does not serialize a
        # self-root or a family fingerprint into the absent schema.  Bind the
        # exact QQP2/3/4 proof tuple and the same version/disposition relation
        # used by the typed family gate so forged legacy-looking descriptors
        # cannot become an authenticated root.
        def known_disposition($node):
          ($node.disposition | IN("eligible","inactive","height_before_window",
            "height_after_window","invalid_location","malformed","duplicate",
            "wrong_mode","unknown_mode","unsupported_version",
            "version_not_yet_active","invalid_proof",
            "unbound_proof_may_revalidate","origin_not_yet_reached",
            "origin_mismatch","origin_expired","input_mismatch",
            "already_accounted","capacity_limit","evaluation_limit",
            "local_state_error"));
        def exact_proof_tuple($node):
          ($node.proof_version == 2 and
             $node.proof_origin_bound == false and $node.proof_input_bound == false) or
          ($node.proof_version == 3 and
             $node.proof_origin_bound == true and $node.proof_input_bound == false) or
          ($node.proof_version == 4 and
             $node.proof_origin_bound == true and $node.proof_input_bound == true);
        def implicit_claim_root($node;$claim_count;$qqp4_active_next_block):
          known_disposition($node) and
          $node.lineage_metadata_present == false and
          $node.lineage_metadata_valid == false and
          $node.lineage_ordinal == 0 and
          $node.lineage_family_fingerprint == $zero and
          $node.lineage_root_txid == $zero and
          $node.lineage_parent_txid == $zero and
          $node.proof_mode == "pow" and
          $node.provenance == "explicit_authored" and
          $node.authored_metadata_valid == true and
          $node.expected_shape == true and
          $node.claim_descriptor_valid == true and
          $node.exact_authored_carrier_shape == true and
          $node.proof_evaluation_skipped_resolved_anchor == false and
          $node.proof_may_revalidate_on_descendant ==
            ($node.disposition == "unbound_proof_may_revalidate") and
          exact_proof_tuple($node) and
          (if $node.disposition == "unsupported_version" then
             $qqp4_active_next_block and
             ($node.proof_version == 2 or $node.proof_version == 3)
           else true end) and
          (if $node.proof_version == 2 then
             ($node.in_mempool == true or
               (($node.disposition | IN("eligible",
                 "unbound_proof_may_revalidate")) or
                ($qqp4_active_next_block and
                 $node.disposition == "unsupported_version"))) and
             (if $claim_count == 1
              then $node.authored_tip_active_branch_bound == true
              else true end)
           elif $node.proof_version == 3 then
             $node.in_mempool == true or
               ($node.disposition | IN("eligible","origin_mismatch","origin_expired")) or
               ($qqp4_active_next_block and
                $node.disposition == "unsupported_version")
           elif $node.proof_version == 4 then
             $node.in_mempool == true or
               ($node.disposition | IN("eligible","origin_mismatch","origin_expired"))
           else false end);
        def selected_claim_safe($node;$qqp4_active_next_block):
          $node.proof_mode == "pow" and
          $node.active_chain_confirmed == false and
          ($node.abandoned == false or $node.expired_locally_retired == true) and
          ($node.in_mempool == true or $node.quarantined == true) and
          $node.proof_evaluation_skipped_resolved_anchor == false and
          $node.proof_may_revalidate_on_descendant ==
            ($node.disposition == "unbound_proof_may_revalidate") and
          (if $node.disposition == "unsupported_version" then
             $qqp4_active_next_block and
             ($node.proof_version == 2 or $node.proof_version == 3)
           else true end) and
          (if $node.proof_version == 2 then
             $node.proof_origin_bound == false and
             $node.proof_input_bound == false and
             ($node.in_mempool == true or
               (($node.disposition | IN("eligible",
                 "unbound_proof_may_revalidate")) or
                ($qqp4_active_next_block and
                 $node.disposition == "unsupported_version")))
           elif $node.proof_version == 3 then
             $node.proof_origin_bound == true and
             $node.proof_input_bound == false and
             ($node.in_mempool == true or
               (($node.disposition | IN("eligible","origin_mismatch",
                 "origin_expired")) or
                ($qqp4_active_next_block and
                 $node.disposition == "unsupported_version")))
           elif $node.proof_version == 4 then
             $node.proof_origin_bound == true and
             $node.proof_input_bound == true and
             ($node.in_mempool == true or
               ($node.disposition | IN("eligible","origin_mismatch","origin_expired")))
           else false end);
        ($height | uint) and ($observed | integer and . > 0) and
        ($tip | hex64) and $tip != $zero and
        ($mempool | type) == "object" and
        $pow.claim_inventory_tip == $tip and $pow.current_height == $height and
        $recovery.active_tip == $tip and $recovery.wallet_processed_tip == $tip and
        $recovery.active_height == $height and
        $recovery.wallet_processed_height == $height and
        ($pow.mining_gate_lineage_head_txid) as $head |
        if $head == $zero then
          $pow.mining_gate_action == "create_new_anchor" or
          ($pow.mining_gate_action == "wait_for_next_tip" and
           $pow.mining_gate_can_submit == true and
           $pow.mining_gate_relay_txid == $zero)
        else
          ([ $recovery.component_details[] as $component |
             select(any($component.nodes[];
               .kind == "claim" and .txid == $head)) | $component ]) as $matches |
          ($matches | length) == 1 and
          ($matches[0]) as $component |
          (claim_nodes($component)) as $claims |
          ($claims | length) >= 1 and
          ($claims | length) <= $pow.mining_gate_family_claims and
          ($component.nodes | length) == ($component.claim_txids | length) and
          ($component.ordinary_or_mixed_txids | length) == 0 and
          ($component.resolution_txids | length) == 0 and
          $component.all_claims_explicitly_provenanced == true and
          ($component.classification |
            IN("live","current_branch_ineligible","terminal_on_pinned_tip")) and
          $component.anchor_authenticated == true and
          $component.anchor_unspent == true and
          $component.anchor.txid != $zero and
          $component.anchor.vout < 4294967295 and
          $component.anchor.amount > 0 and
          ($component.anchor.scriptPubKey | length) > 0 and
          ($component.root_claim_txids | sort) ==
            ($component.claim_txids | sort) and
          $component.descendant_claims == 0 and
          ($component.generation_fingerprint | hex64) and
          $component.generation_fingerprint != $zero and
          ($claims | map(.lineage_ordinal)) ==
            [range(0; ($claims | length))] and
          $claims[-1].txid == $head and
          $claims[0].lineage_ordinal == 0 and
          (if $claims[0].lineage_metadata_present then
             $claims[0].lineage_metadata_valid == true and
             $claims[0].lineage_root_txid == $claims[0].txid and
             $claims[0].lineage_parent_txid == $zero and
             $claims[0].lineage_family_fingerprint ==
               $component.generation_fingerprint
           else
             implicit_claim_root($claims[0]; ($claims | length);
               $goldrush.qqp4_active_next_block)
           end) and
          all(range(1; ($claims | length));
            $claims[.].lineage_metadata_present == true and
            $claims[.].lineage_metadata_valid == true and
            $claims[.].lineage_family_fingerprint ==
              $component.generation_fingerprint and
            $claims[.].lineage_root_txid == $claims[0].txid and
            $claims[.].lineage_parent_txid == $claims[.-1].txid) and
          all($claims[];
            selected_claim_safe(.;$goldrush.qqp4_active_next_block) and
            .expected_shape == true and
            .wallet_authored == true and .wallet_from_me == true and
            .authored_metadata_valid == true and
            .claim_descriptor_valid == true and
            .exact_authored_carrier_shape == true and
            .provenance == "explicit_authored" and
            (.txid as $txid |
              .in_mempool == ($mempool | has($txid))) and
            (if .in_mempool then
               (.txid as $txid | $mempool[$txid] | type) == "object" and
               (.txid as $txid | $mempool[$txid].time | integer and . > 0 and
                 . <= $observed) and
               (.txid as $txid | $mempool[$txid].height | uint and
                 . <= $height)
             else true end)) and
          ([$claims[] |
             select(.disposition == "eligible" and .in_mempool == false and
               .relay_ttl_expired == false)]) as $relay_candidates |
          ([$claims[] | select(.in_mempool)] | length) as $selected_live |
          $pow.mining_gate_live_claims >= $selected_live and
          $selected_live <= 1 and
          (if $component.anchor_user_locked then
             $pow.mining_gate_action == "wait_for_next_tip" and
             $pow.mining_gate_relay_txid == $zero and
             $pow.mining_gate_can_submit == false
           else true end) and
          (if $pow.mining_gate_action == "wait_for_live" then
             $selected_live == 1 and ($pow.mining_gate_live_claims >= 1)
           elif $pow.mining_gate_action == "relay_existing" then
             $selected_live == 0 and
             ($pow.mining_gate_relay_txid) as $relay |
             ([$relay_candidates[] | select(.txid == $relay)]) as $selected |
             ($selected | length) == 1 and
             ($selected[0].relay_expiry_time | integer and . > $observed)
           elif $pow.mining_gate_action == "wait_for_next_tip" and
                $pow.mining_gate_relay_txid != $zero then
             $selected_live == 0 and
             ($pow.mining_gate_relay_txid) as $relay |
             ([$relay_candidates[] | select(.txid == $relay)]) as $selected |
             ($selected | length) == 1 and
             ($selected[0].relay_expiry_time | integer and . > $observed)
           elif $pow.mining_gate_action == "refresh_same_anchor" then
             $selected_live == 0
           else true end)
        end
    ' >/dev/null
}

# A fingerprint/action/relay change is not progress: each can change while the
# same durable family toggles between local mempool and relay views. Across an
# advancing-tip series, every enabled action without an action-appropriate
# progress witness may span at most one tip
# without a new authenticated family/head, a first observed authoritative live
# transition for an authenticated family member, an increased worker submission
# counter, or positive hashing under a submit-capable create/refresh action.
hotfix_pow_observation_series_json_is_valid()
{
    local series="$1" minimum_samples="${2:-3}" observation row projection
    local sample tip height work observed enabled action can_submit hash_progress claims key head ordinal
    local generation claim_txids live_txids live_txid live_progress family_index i
    local previous_sample=0 previous_tip='' previous_height=-1 previous_work=''
    local previous_observed=0 first_observed=0 last_tip_progress_observed=0
    local previous_claims=0 tip_changes=0
    local seen_tips='|'
    local previous_projection=''
    local stale_transitions=0 seen_live_txids='|' progress same_tip family_seen_before
    local previous_family_live='-' previous_family_claims='-'
    local family_keys=() family_generations=() family_heads=() family_ordinals=()
    local family_claim_txids=() family_live_txids=()
    [[ "$minimum_samples" =~ ^[1-9][0-9]*$ ]] || return 1
    jq -e -n --argjson series "$series" --argjson minimum "$minimum_samples" '
      def integer: type == "number" and floor == .;
      def hex64: type == "string" and test("^[0-9a-f]{64}$");
      $series | type == "array" and length >= $minimum and
      all(.[];
        type == "object" and
        (keys | sort) == (["goldrush_state","height","mempool_verbose",
          "observed_epoch","pow","recovery","sample","tip","work"] | sort) and
        (.sample | integer and . > 0) and (.height | integer and . >= 0) and
        (.tip | hex64) and (.work | hex64) and
        (.observed_epoch | integer and . > 0))
    ' >/dev/null || return 1
    while IFS= read -r observation; do
        hotfix_pow_observation_json_is_valid \
            "$(jq -ce '.pow' <<<"$observation")" \
            "$(jq -ce '.recovery' <<<"$observation")" \
            "$(jq -ce '.mempool_verbose' <<<"$observation")" \
            "$(jq -er '.tip' <<<"$observation")" \
            "$(jq -er '.height' <<<"$observation")" \
            "$(jq -er '.observed_epoch' <<<"$observation")" \
            "$(jq -ce '.goldrush_state' <<<"$observation")" || return 1
        row=$(jq -er --arg zero "$HOTFIX_ZERO_TXID" '
          .pow.mining_gate_lineage_head_txid as $head |
          (if $head == $zero then null
           else ([.recovery.component_details[] as $component |
             select(any($component.nodes[];
               .kind == "claim" and .txid == $head)) | $component][0]) end) as $component |
          (if $component == null then []
           else ($component.nodes | map(select(.kind == "claim")) |
             sort_by(.lineage_ordinal)) end) as $claims |
            [ .sample,.tip,.height,.work,.observed_epoch,.pow.enabled,
              .pow.mining_gate_action,.pow.mining_gate_can_submit,
            (.pow.mining_gate_can_submit and
             (.pow.mining_gate_action == "create_new_anchor" or
              .pow.mining_gate_action == "refresh_same_anchor") and
             .pow.hashrate > 0),.pow.claims_submitted,
            (if $component == null then "-"
             else ([$component.anchor.txid,($component.anchor.vout|tostring),
               $claims[0].txid] | join(":")) end),
            (if $component == null then "-" else $component.generation_fingerprint end),
            $head,(if ($claims|length) == 0 then -1 else $claims[-1].lineage_ordinal end),
            (if ($claims|length) == 0 then "-"
             else ($claims | map(.txid) | join(",")) end),
            ([$claims[] | select(.in_mempool) | .txid] as $live |
              if ($live|length) == 0 then "-" else ($live | join(",")) end) ] | @tsv
        ' <<<"$observation") || return 1
        projection=$(jq -ceS --arg zero "$HOTFIX_ZERO_TXID" '
          .pow.mining_gate_lineage_head_txid as $head |
          (if $head == $zero then null else
             [.recovery.component_details[] as $component |
               select(any($component.nodes[];
                 .kind == "claim" and .txid == $head)) | $component][0]
           end) as $selected |
          {tip,height,work,
           qqp4:{activation_disabled:.goldrush_state.qqp4_activation_disabled,
             activation_height:.goldrush_state.qqp4_activation_height,
             active:.goldrush_state.qqp4_active,
             active_next_block:.goldrush_state.qqp4_active_next_block},
           worker:{enabled:.pow.enabled,state:.pow.state,threads:.pow.threads,
             cpu_percent:.pow.cpu_percent,hashrate:.pow.hashrate,
             claims_submitted:.pow.claims_submitted},
           gate:{coherent:.pow.mining_gate_coherent,
             action:.pow.mining_gate_action,
             can_submit:.pow.mining_gate_can_submit,
             database_ambiguous:.pow.mining_gate_database_ambiguous,
             unresolved_components:.pow.mining_gate_unresolved_components,
             live_claims:.pow.mining_gate_live_claims,
             eligible_claims:.pow.mining_gate_eligible_claims,
             family_claims:.pow.mining_gate_family_claims,
             unsafe_claims:.pow.mining_gate_unsafe_claims,
             unsafe_components:.pow.mining_gate_unsafe_components,
             relay_txid:.pow.mining_gate_relay_txid,
             lineage_head_txid:.pow.mining_gate_lineage_head_txid},
           selected:(if $selected == null then null else
             {anchor:$selected.anchor,
              anchor_authenticated:$selected.anchor_authenticated,
              anchor_unspent:$selected.anchor_unspent,
              anchor_user_locked:$selected.anchor_user_locked,
              classification:$selected.classification,
              generation_fingerprint:$selected.generation_fingerprint,
              claim_txids:$selected.claim_txids,
              root_claim_txids:$selected.root_claim_txids,
              descendant_claims:$selected.descendant_claims,
              ordinary_or_mixed_txids:$selected.ordinary_or_mixed_txids,
              resolution_txids:$selected.resolution_txids,
              nodes:([$selected.nodes[] | select(.kind == "claim") |
                {txid,in_mempool,quarantined,active_chain_confirmed,abandoned,
                 expired_locally_retired,disposition,relay_expiry_time,
                 relay_ttl_expired,proof_mode,proof_version,proof_origin_bound,
                 proof_input_bound,proof_may_revalidate_on_descendant,
                 proof_evaluation_skipped_resolved_anchor,
                 lineage_metadata_present,lineage_metadata_valid,
                 lineage_family_fingerprint,lineage_root_txid,
                 lineage_parent_txid,lineage_ordinal}] | sort_by(.txid))}
             end)}
        ' <<<"$observation" | sha256sum | awk '{print $1}') || return 1
        IFS=$'\t' read -r sample tip height work observed enabled action can_submit hash_progress claims \
            key generation head ordinal claim_txids live_txids <<<"$row"
        if (( previous_sample != 0 )); then
            (( sample > previous_sample && observed > previous_observed )) || return 1
            (( observed - first_observed <= 2700 )) || return 1
            # Worker, lineage, submission, and mempool witnesses never replace
            # active-chain liveness. Every observed period on one tip is capped
            # at ten minutes, including the interval ending at the next tip.
            (( observed - last_tip_progress_observed <= 600 )) || return 1
            same_tip=false
            if [[ "$tip" == "$previous_tip" ]]; then
                (( height == previous_height )) && [[ "$work" == "$previous_work" ]] || return 1
                [[ "$projection" != "$previous_projection" ]] || return 1
                same_tip=true
            else
                [[ "$seen_tips" != *"|${tip}|"* ]] || return 1
                (( height > previous_height )) && [[ "$work" > "$previous_work" ]] || return 1
                tip_changes=$((tip_changes + 1))
                last_tip_progress_observed=$observed
            fi
            (( claims >= previous_claims )) || return 1
            progress=false
            if (( claims > previous_claims )) || [[ "$hash_progress" == true ]]; then
                progress=true
            fi
            if [[ "$key" != - ]]; then
                family_index=-1
                family_seen_before=false
                previous_family_live='-'
                previous_family_claims='-'
                for i in "${!family_keys[@]}"; do
                    if [[ "${family_keys[$i]}" == "$key" ]]; then
                        family_index=$i
                        break
                    fi
                done
                if (( family_index >= 0 )); then
                    family_seen_before=true
                    previous_family_live=${family_live_txids[$family_index]}
                    previous_family_claims=${family_claim_txids[$family_index]}
                    [[ "$generation" == "${family_generations[$family_index]}" ]] || return 1
                    (( ordinal >= family_ordinals[family_index] )) || return 1
                    if (( ordinal == family_ordinals[family_index] )); then
                        [[ "$head" == "${family_heads[$family_index]}" &&
                           "$claim_txids" == "${family_claim_txids[$family_index]}" ]] || return 1
                    else
                        [[ "$claim_txids" == "${family_claim_txids[$family_index]},"* ]] || return 1
                        progress=true
                    fi
                    family_heads[family_index]=$head
                    family_ordinals[family_index]=$ordinal
                    family_claim_txids[family_index]=$claim_txids
                    family_live_txids[family_index]=$live_txids
                else
                    family_keys+=("$key")
                    family_generations+=("$generation")
                    family_heads+=("$head")
                    family_ordinals+=("$ordinal")
                    family_claim_txids+=("$claim_txids")
                    family_live_txids+=("$live_txids")
                fi
            fi
            if [[ "$key" != - && "$live_txids" != - &&
                  "$family_seen_before" == true ]]; then
                live_progress=false
                while IFS= read -r live_txid; do
                    if [[ -n "$live_txid" &&
                          ",${previous_family_claims}," == *",${live_txid},"* &&
                          ",${previous_family_live}," != *",${live_txid},"* &&
                          "$seen_live_txids" != *"|${live_txid}|"* ]]; then
                        live_progress=true
                    fi
                done < <(tr ',' '\n' <<<"$live_txids")
                [[ "$live_progress" == false ]] || progress=true
            fi
            if [[ "$progress" == true ]]; then
                stale_transitions=0
            else
                # A changed same-tip cut, or a submit-capable create/refresh cut
                # without concrete work, consumes the bounded no-progress
                # budget. A coherent wait/live/relay cut may instead remain
                # zero-hash while the active chain advances; selection/action/
                # fingerprint/relay churn alone is never credited as progress.
                if [[ "$same_tip" == true ||
                      ( "$can_submit" == true &&
                        ( "$action" == create_new_anchor ||
                          "$action" == refresh_same_anchor ) ) ]]; then
                    stale_transitions=$((stale_transitions + 1))
                else
                    stale_transitions=0
                fi
            fi
            if [[ "$enabled" == true && $stale_transitions -gt 1 ]]; then
                return 1
            fi
        elif [[ "$key" != - ]]; then
            family_keys+=("$key")
            family_generations+=("$generation")
            family_heads+=("$head")
            family_ordinals+=("$ordinal")
            family_claim_txids+=("$claim_txids")
            family_live_txids+=("$live_txids")
        fi
        if (( first_observed == 0 )); then
            first_observed=$observed
            last_tip_progress_observed=$observed
        fi
        if [[ "$live_txids" != - ]]; then
            while IFS= read -r live_txid; do
                if [[ -n "$live_txid" &&
                      "$seen_live_txids" != *"|${live_txid}|"* ]]; then
                    seen_live_txids+="${live_txid}|"
                fi
            done < <(tr ',' '\n' <<<"$live_txids")
        fi
        previous_sample=$sample
        previous_tip=$tip
        previous_height=$height
        previous_work=$work
        previous_observed=$observed
        previous_claims=$claims
        previous_projection=$projection
        if [[ "$seen_tips" != *"|${tip}|"* ]]; then
            seen_tips+="${tip}|"
        fi
    done < <(jq -ce '.[]' <<<"$series")
    # The consensus schedule is process/network identity. It may cross its
    # activation height, but it cannot change during one acceptance series.
    jq -e -n --argjson series "$series" '
      ([$series[].goldrush_state |
        {qqp4_activation_disabled,qqp4_activation_height}] | unique | length) == 1
    ' >/dev/null || return 1
    (( minimum_samples < 2 || tip_changes >= 1 ))
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

hotfix_phase_b_staking_json_is_locked_with_intent()
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
        .enabled == true and .autostart_staking == true and
        .autostart_staking_source == "autostartstaking" and
        .worker_running == true and .staking == false and .eligible == false and
        .staking_state == "locked" and (.staking_reason | type) == "string" and
        (.staking_snapshot_current | type) == "boolean" and
        (.staking_snapshot_sequence | integer and . >= 0) and
        (.active_blocks | integer and . >= 0) and (.blocks | integer and . >= 0) and
        (.weight | integer and . >= 0) and (.weight_cached | type) == "boolean" and
        (.weight_cache_height | integer and . >= -1) and
        .automatic_qqsignal == false and .automatic_demurrage_attestation == false and
        .automatic_redelegation == false and
        .allow_automatic_quantum_key_creation == false and
        .consensus_demurrage_automatic == true and
        (.pooledtx | integer and . >= 0) and (.difficulty | type) == "number" and
        ((.currentblocktx? == null) or (.currentblocktx | integer and . >= 0)) and
        ((.currentblockweight? == null) or (.currentblockweight | integer and . >= 0)) and
        (."search-interval" | integer and . >= 0) and
        (.netstakeweight | integer and . >= 0) and (.expectedtime | integer and . >= 0) and
        (.chainstate_cached | type) == "boolean" and (.chain | type) == "string" and
        (.warnings | type) == "string"
    ' >/dev/null
}

hotfix_phase_b_progress_file_is_valid()
{
    local file="$1" expected_nonce="$2" pow_mode="$3" sample fee series
    [[ -f "$file" && ! -L "$file" && "$pow_mode" == active ]] ||
        return 1
    jq -e --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" --arg nonce "$expected_nonce" '
        def integer: type == "number" and floor == .;
        def hex64: type == "string" and test("^[0-9a-f]{64}$");
        type == "object" and
        (keys | sort) == (["candidate_source_sha","p2p_ready_continuously","phase",
          "pos_active_continuously","promotion_nonce","observation_sample_count",
          "samples","schema","tip_changes",
          "wallet_chain_synchronized_continuously",
          "same_tip_or_submit_no_progress_transition_budget"] | sort) and
        (.schema | integer and . == 4) and .phase == "B" and
        .candidate_source_sha == $source and .promotion_nonce == $nonce and
        ($nonce | test("^[0-9a-f]{32}$")) and
        (.observation_sample_count | integer and . >= 2) and
        (.observation_sample_count as $file_observation_count |
        (.samples | type == "array" and
          length == $file_observation_count) and
        ([.samples[].sample] == [range(1; $file_observation_count + 1)]) and
        all(.samples[];
          (keys | sort) == (["chain","goldrush_state","mempool_verbose","network",
            "observed_epoch","pow","recovery","sample","staking","wallet"] | sort) and
          (.sample | integer and . >= 1 and . <= $file_observation_count) and
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
          (.wallet | type) == "object" and (.wallet.walletname | type) == "string" and
          .wallet.private_keys_enabled == true and .wallet.scanning == false and
          .wallet.unlocked_staking_only == false and
          (.wallet.unlocked_until | integer) and
          .wallet.unlocked_until > .observed_epoch and
          .recovery.active_tip == .chain.bestblockhash and
          .recovery.wallet_processed_tip == .chain.bestblockhash and
          .pow.claim_inventory_tip == .chain.bestblockhash and
          .staking.blocks == .chain.blocks and .staking.active_blocks == .chain.blocks and
          .staking.autostart_staking == true and
          .staking.autostart_staking_source == "autostartstaking" and
          .pow.autostart == true and
          .pow.claim_recovery_database_outcome_ambiguous ==
            .recovery.database_outcome_ambiguous) and
        ([.samples[].wallet.walletname] | unique | length) == 1 and
        ([.samples[].chain.blocks] as $h |
         [.samples[].chain.bestblockhash] as $t |
         [.samples[].chain.chainwork] as $w |
          all(range(1;($h|length));
            if $t[.] == $t[.-1] then
              $h[.] == $h[.-1] and $w[.] == $w[.-1]
            else
              $h[.] > $h[.-1] and $w[.] > $w[.-1]
            end)) and
        ([.samples[].observed_epoch] as $o |
          all(range(1;($o|length)); $o[.] > $o[.-1]) and
          ($o[-1] - $o[0]) <= 2700) and
        ([.samples[].chain.bestblockhash] as $t |
          ([range(1;($t|length)) | select($t[.] != $t[.-1])] | length) as $changes |
          (.tip_changes | integer and . == $changes and . >= 1)) and
        (.same_tip_or_submit_no_progress_transition_budget | integer and . == 1) and
        (.wallet_chain_synchronized_continuously | type) == "boolean" and
        .wallet_chain_synchronized_continuously == true and
        (.pos_active_continuously | type) == "boolean" and
        .pos_active_continuously == true and
        (.p2p_ready_continuously | type) == "boolean" and
        .p2p_ready_continuously == true)
    ' "$file" >/dev/null || return 1
    while IFS= read -r sample; do
        fee=$(jq -ce '.recovery.confirmed_resolution_fees' <<<"$sample") || return 1
        hotfix_candidate_recovery_json_is_valid \
            "$(jq -ce '.recovery' <<<"$sample")" "$fee" || return 1
        hotfix_phase_b_staking_json_is_active "$(jq -c '.staking' <<<"$sample")" || return 1
        hotfix_candidate_pow_json_is_valid "$(jq -c '.pow' <<<"$sample")" "$pow_mode" || return 1
    done < <(jq -ce '.samples[]' "$file")
    series=$(jq -ce '[.samples[] | {sample,observed_epoch,
      tip:.chain.bestblockhash,height:.chain.blocks,work:.chain.chainwork,
      goldrush_state,pow,recovery,mempool_verbose}]' \
        "$file") || return 1
    hotfix_pow_observation_series_json_is_valid "$series" 2 || return 1
    jq -e --arg zero "$HOTFIX_ZERO_TXID" '
      def selected:
        . as $sample | $sample.pow.mining_gate_lineage_head_txid as $head |
        if $head==$zero then null else
          ([$sample.recovery.component_details[] as $component |
            select(any($component.nodes[];
              .kind=="claim" and .txid==$head)) | $component][0]) as $component |
          ($component.nodes|map(select(.kind=="claim"))|
            sort_by(.lineage_ordinal)) as $claims |
          {key:([$component.anchor.txid,($component.anchor.vout|tostring),
            $claims[0].txid]|join(":")),ordinal:$claims[-1].lineage_ordinal,
           claim_txids:[$claims[].txid],live_txids:[$claims[]|select(.in_mempool)|.txid]}
        end;
      .samples as $samples | ($samples|length) as $n | $samples[-1] as $final |
      ($final|selected) as $final_family |
      if ($final.pow.mining_gate_can_submit==true and
          ($final.pow.mining_gate_action=="create_new_anchor" or
           $final.pow.mining_gate_action=="refresh_same_anchor")) then
        $final.pow.hashrate>0 or
        any(range(1;$n); $samples[.].pow.claims_submitted>
          $samples[.-1].pow.claims_submitted) or
        ($final_family!=null and any(range(0;$n-1); (. as $i |
          ($samples[$i]|selected) as $prior |
          $prior!=null and $prior.key==$final_family.key and
          $final_family.ordinal>$prior.ordinal))) or
        ($final_family!=null and any($final_family.live_txids[]; . as $live |
          any(range(0;$n-1); (. as $i | ($samples[$i]|selected) as $prior |
            $prior!=null and $prior.key==$final_family.key and
            ($prior.claim_txids|index($live))!=null and
            ($prior.live_txids|index($live))==null)) and
          all(range(0;$n-1); (. as $i | ($samples[$i]|selected) as $prior |
            $prior==null or ($prior.live_txids|index($live))==null))))
      else true end
    ' "$file" >/dev/null
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
    local envelope="$1" mining_before mining_after recovery_before recovery_after staking
    local mempool tip height observed goldrush_state
    jq -e -n --argjson envelope "$envelope" '
        def integer: type == "number" and floor == .;
        def hex64: type == "string" and test("^[0-9a-f]{64}$");
        def gate_tuple: {mining_gate_action,mining_gate_can_submit,
          mining_gate_database_ambiguous,mining_gate_unresolved_components,
          mining_gate_live_claims,mining_gate_eligible_claims,mining_gate_family_claims,
          mining_gate_unsafe_claims,mining_gate_unsafe_components,mining_gate_relay_txid,
          mining_gate_lineage_head_txid,mining_gate_candidate_state_fingerprint,
          claims_submitted};
        $envelope | type == "object" and
        (keys | sort) == (["chain_after","chain_before","goldrush_state",
          "isolation_continuously_valid","isolation_sha256",
          "mempool_verbose","mining_after","mining_before","network","observed_epoch","observer_status",
          "phase","recovery_after","recovery_before","restart_epoch","sample","schema",
          "staking","wallet","wallets"] | sort) and
        (.schema | integer and . == 4) and .phase == "A" and
        (.sample | integer and . >= 1) and
        (.observed_epoch | integer and . > 0) and
        (.restart_epoch | integer and (. == 1 or . == 2)) and
        (.wallet.walletname | type) == "string" and
        .wallets == [.wallet.walletname] and
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
        .recovery_before.policy == .recovery_after.policy and
        .recovery_before.policy_state_status == .recovery_after.policy_state_status and
        .mining_before.claim_inventory_tip == .chain_before.bestblockhash and
        .mining_after.claim_inventory_tip == .chain_before.bestblockhash and
        .mining_after.mining_gate_candidate_state_fingerprint ==
          .mining_before.mining_gate_candidate_state_fingerprint and
        (.mining_after | gate_tuple) == (.mining_before | gate_tuple) and
        .mining_before.claims_submitted == 0 and .mining_after.claims_submitted == 0 and
        .mining_before.autostart == false and .mining_after.autostart == false and
        (.isolation_sha256 | hex64) and
        (.mempool_verbose | type) == "object" and
        (.wallet | type) == "object" and
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
        .mining_before.claim_recovery_database_outcome_ambiguous ==
          .recovery_before.database_outcome_ambiguous and
        .mining_after.claim_recovery_database_outcome_ambiguous ==
          .recovery_after.database_outcome_ambiguous
    ' >/dev/null || return 1
    mining_before=$(jq -ce '.mining_before' <<<"$envelope") || return 1
    mining_after=$(jq -ce '.mining_after' <<<"$envelope") || return 1
    recovery_before=$(jq -ce '.recovery_before' <<<"$envelope") || return 1
    recovery_after=$(jq -ce '.recovery_after' <<<"$envelope") || return 1
    staking=$(jq -ce '.staking' <<<"$envelope") || return 1
    mempool=$(jq -ce '.mempool_verbose' <<<"$envelope") || return 1
    tip=$(jq -er '.chain_before.bestblockhash' <<<"$envelope") || return 1
    height=$(jq -er '.chain_before.blocks' <<<"$envelope") || return 1
    observed=$(jq -er '.observed_epoch' <<<"$envelope") || return 1
    goldrush_state=$(jq -ce '.goldrush_state' <<<"$envelope") || return 1
    hotfix_candidate_pow_json_is_valid "$mining_before" active &&
        hotfix_candidate_pow_json_is_valid "$mining_after" active &&
        hotfix_candidate_recovery_json_is_valid "$recovery_before" &&
        hotfix_candidate_recovery_json_is_valid "$recovery_after" &&
        hotfix_phase_a_staking_json_is_disabled "$staking" &&
        hotfix_pow_observation_json_is_valid "$mining_before" "$recovery_before" \
            "$mempool" "$tip" "$height" "$observed" "$goldrush_state" &&
        hotfix_pow_observation_json_is_valid "$mining_after" "$recovery_after" \
            "$mempool" "$tip" "$height" "$observed" "$goldrush_state"
}

hotfix_phase_a_progress_file_is_valid()
{
    local file="$1" envelope series
    [[ -f "$file" && ! -L "$file" ]] || return 1
    jq -e --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" '
        def integer: type == "number" and floor == .;
        . as $progress |
        ($progress.observation_sample_count) as $n |
        type == "object" and
        (keys | sort) == (["bounded_worker_tip_progress","candidate_source_sha","envelopes",
          "hard_flags_continuous","interactive_surfaces_stopped_continuously",
          "nonpublication_continuous","observation_sample_count",
          "post_restart_advancing_observations",
          "isolation_sample_sha256s","per_epoch_claims_submitted_zero","phase",
          "pos_disabled_continuous","run_nonce","schema",
          "single_positive_hash_sample_required","tip_changes",
          "visibility_sample_sha256s","wait_for_next_tip_required_for_liveness",
          "worker_only_pow","same_tip_or_submit_no_progress_transition_budget"] | sort) and
        (.schema | integer and . == 5) and .phase == "A" and
        (.run_nonce | type == "string" and test("^[0-9a-f]{32}$")) and
        .candidate_source_sha == $source and
        ($n | integer and . >= 3) and
        (.envelopes | type == "array" and
          length == $n) and
        ([.envelopes[].sample] == [range(1; $n + 1)]) and
        ([.envelopes[].chain_before.blocks] as $h |
          all(range(1;$h|length); $h[.] > $h[.-1])) and
        ([.envelopes[].chain_before.bestblockhash] as $t |
          ($t | unique | length) == $n and
          all(range(1;$t|length); $t[.] != $t[.-1])) and
        ([.envelopes[].chain_before.chainwork] as $w |
          all(range(1;$w|length); $w[.] > $w[.-1])) and
        ([.envelopes[].observed_epoch] as $o |
          all(range(1;$o|length); $o[.] >= $o[.-1])) and
        .envelopes[0].restart_epoch == 1 and
        all(.envelopes[1:][]; .restart_epoch == 2) and
        (.tip_changes | integer and
          . == ($n - 1)) and
        (.same_tip_or_submit_no_progress_transition_budget | integer and . == 1) and
        .hard_flags_continuous == true and .pos_disabled_continuous == true and
        .nonpublication_continuous == true and
        .interactive_surfaces_stopped_continuously == true and .worker_only_pow == true and
        (.post_restart_advancing_observations | integer and
          . == ($n - 1)) and
        .per_epoch_claims_submitted_zero == true and
        (.isolation_sample_sha256s | type == "array" and
          length == $n and
          all(.[]; type == "string" and test("^[0-9a-f]{64}$"))) and
        (.visibility_sample_sha256s | type == "array" and
          length == $n and
          all(.[]; type == "string" and test("^[0-9a-f]{64}$"))) and
        ([.envelopes[].isolation_sha256] == .isolation_sample_sha256s) and
        .bounded_worker_tip_progress == true and
        .single_positive_hash_sample_required == false and
        .wait_for_next_tip_required_for_liveness == false
    ' "$file" >/dev/null || return 1
    while IFS= read -r envelope; do
        hotfix_phase_a_envelope_json_is_valid "$envelope" || return 1
    done < <(jq -ce '.envelopes[]' "$file")
    series=$(jq -ce '[.envelopes[] | {sample,observed_epoch,
      tip:.chain_before.bestblockhash,height:.chain_before.blocks,
      work:.chain_before.chainwork,goldrush_state,
      pow:.mining_after,recovery:.recovery_after,mempool_verbose}]' "$file") || return 1
    hotfix_pow_observation_series_json_is_valid "$series"
}

hotfix_phase_a_external_receive_evidence_file_is_valid()
{
    local file="$1"
    [[ -f "$file" && ! -L "$file" ]] || return 1
    jq -e --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" \
        --arg zero "$HOTFIX_ZERO_TXID" '
      def integer: type == "number" and floor == .;
      def hex64: type == "string" and test("^[0-9a-f]{64}$");
      def txid_set:
        type == "array" and all(.[]; hex64) and . == (sort | unique);
      def no_control_metadata:
        ([keys[] | select(startswith("qq_"))] | length) == 0 and
        ((.comment? // "") |
          IN("Quantum Quasar built-in shadow PoW claim",
             "Blackcoin shadow PoW claim","PoW Claim","Quantum PoW Claim") | not);
      def clean_receive($txid):
        .txid == $txid and .category == "receive" and
        (.amount | type) == "number" and .amount > 0 and
        .abandoned == false and (has("fee") | not) and
        (has("generated") | not) and
        no_control_metadata;
      def valid_null_or_real_outpoint:
        (.anchor.txid == $zero and .anchor.vout == 4294967295) or
        ((.anchor.txid | hex64) and .anchor.txid != $zero and
          (.anchor.vout | integer and . >= 0 and . < 4294967295));
      def audit_only_component:
        .anchor_authenticated == false and .anchor_unspent == false and
        .anchor_user_locked == false and .anchor.amount == 0 and
        .anchor.scriptPubKey == "" and valid_null_or_real_outpoint and
        (.claim_txids | type == "array" and length >= 1 and
          all(.[]; hex64) and (unique | length) == length) and
        ([.nodes[]? | select(.kind == "claim") | .txid] | sort | unique) ==
          (.claim_txids | sort | unique) and
        all(.nodes[]?; .provenance == "unknown" and
          .wallet_authored == false and .wallet_from_me == false);
      . as $e |
      type == "object" and
      (keys | sort) == (["candidate_authored_txids","candidate_source_sha",
        "external_receive_txids","final_wallet_txids","new_wallet_txids","phase",
        "prelaunch_wallet_txids","records","run_nonce","schema","sets_disjoint",
        "terminal_height","terminal_tip","wallet_differential_exhaustive"] | sort) and
      .schema == 1 and .phase == "A" and .candidate_source_sha == $source and
      (.run_nonce | type == "string" and test("^[0-9a-f]{32}$")) and
      (.terminal_tip | hex64) and (.terminal_height | integer and . >= 0) and
      (.prelaunch_wallet_txids | txid_set) and (.final_wallet_txids | txid_set) and
      (.new_wallet_txids | txid_set) and (.candidate_authored_txids | txid_set) and
      (.external_receive_txids | txid_set) and
      .new_wallet_txids == (.final_wallet_txids - .prelaunch_wallet_txids) and
      (.candidate_authored_txids - .external_receive_txids | length) ==
        (.candidate_authored_txids | length) and
      .new_wallet_txids ==
        ((.candidate_authored_txids + .external_receive_txids) | sort | unique) and
      .sets_disjoint == true and .wallet_differential_exhaustive == true and
      (.records | type == "array" and . == (sort_by(.txid))) and
      ([.records[].txid] | sort | unique) == .external_receive_txids and
      all(.records[]; . as $record |
        type == "object" and
        (keys | sort) == (["active_chain_bound","classification","confirmation_state",
          "getblock_response","getblockhash_response","gettransaction_response",
          "recovery_match_count","recovery_matches","txid",
          "unconfirmed_recovery_bound"] | sort) and
        (.txid | hex64) and .classification == "external_receive" and
        (.gettransaction_response) as $tx |
        ($tx | type) == "object" and $tx.txid == $record.txid and
        ($tx.decoded | type) == "object" and $tx.decoded.txid == $record.txid and
        ($tx.hex | type) == "string" and ($tx.hex | test("^[0-9a-f]+$")) and
        ($tx.hex | length) > 0 and (($tx.hex | length) % 2) == 0 and
        ($tx | has("fee") | not) and ($tx.amount | type) == "number" and
        $tx.amount > 0 and ($tx | has("generated") | not) and
        ($tx | no_control_metadata) and
        ($tx.confirmations | integer and . >= 0) and
        ($tx.details | type == "array" and length > 0) and
        all($tx.details[]; clean_receive($record.txid)) and
        ([$tx.details[].amount] | add) == $tx.amount and
        ($record.recovery_matches | type) == "array" and
        ($record.recovery_match_count | integer and
          . == ($record.recovery_matches | length) and . <= 1) and
        (if $record.confirmation_state == "confirmed_active_chain" then
           $record.active_chain_bound == true and
           $record.unconfirmed_recovery_bound == false and
           $record.recovery_matches == [] and $tx.confirmations > 0 and
           ($tx.blockhash | hex64) and ($tx.blockheight | integer and . >= 0) and
           ($tx.blockindex | integer and . >= 0) and
           ($record.getblock_response | type) == "object" and
           $record.getblock_response.hash == $tx.blockhash and
           $record.getblock_response.height == $tx.blockheight and
           ($record.getblock_response.confirmations | integer and . > 0) and
           ($record.getblock_response.tx | type) == "array" and
           ($record.getblock_response.tx | index($record.txid)) != null and
           $record.getblockhash_response == $tx.blockhash and
           $tx.blockheight <= $e.terminal_height
         elif $record.confirmation_state == "unconfirmed" then
           $record.active_chain_bound == false and
           $record.unconfirmed_recovery_bound == true and
           $tx.confirmations == 0 and ($tx | has("blockhash") | not) and
           ($tx | has("blockheight") | not) and ($tx | has("blockindex") | not) and
           $record.getblock_response == null and $record.getblockhash_response == null and
           all($record.recovery_matches[]; audit_only_component)
         else false end))
    ' "$file" >/dev/null
}

hotfix_phase_a_claim_proof_file_is_valid()
{
    local file="$1"
    [[ -f "$file" && ! -L "$file" ]] || return 1
    jq -e --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" \
        --arg zero "$HOTFIX_ZERO_TXID" '
        def hex64: type == "string" and test("^[0-9a-f]{64}$");
        def integer: type == "number" and floor == .;
        def known_disposition:
          type == "string" and IN("eligible","inactive","height_before_window",
            "height_after_window","invalid_location","malformed","duplicate",
            "wrong_mode","unknown_mode","unsupported_version",
            "version_not_yet_active","invalid_proof",
            "unbound_proof_may_revalidate","origin_not_yet_reached",
            "origin_mismatch","origin_expired","input_mismatch",
            "already_accounted","capacity_limit","evaluation_limit",
            "local_state_error");
        def exact_proof_tuple:
          (.proof_version == 2 and .proof_origin_bound == false and
             .proof_input_bound == false) or
          (.proof_version == 3 and .proof_origin_bound == true and
             .proof_input_bound == false) or
          (.proof_version == 4 and .proof_origin_bound == true and
             .proof_input_bound == true);
        def anchor_descriptor:
          type == "object" and (keys | sort) == ["txid","vout"] and
          (.txid | hex64) and (.vout | integer and . >= 0);
        def full_member:
          type == "object" and
          (keys | sort) == (["authored_metadata_valid",
            "authored_tip_active_branch_bound","claim_descriptor_valid","disposition",
            "exact_authored_carrier_shape","family","lineage_metadata_present",
            "lineage_metadata_valid","ordinal","parent_txid","proof_input_bound",
            "proof_evaluation_skipped_resolved_anchor",
            "proof_may_revalidate_on_descendant","proof_mode","proof_origin_bound",
            "proof_version","provenance","root_txid","txid","wallet_authored",
            "wallet_from_me"] | sort) and
          (.txid | hex64) and (.ordinal | integer and . >= 0) and
          (.parent_txid | hex64) and (.root_txid | hex64) and (.family | hex64) and
          (.proof_version | integer and IN(2,3,4)) and .proof_mode == "pow" and
          (.disposition | known_disposition) and .provenance == "explicit_authored" and
          .wallet_authored == true and .wallet_from_me == true and
          .authored_metadata_valid == true and .claim_descriptor_valid == true and
          .exact_authored_carrier_shape == true and
          (.authored_tip_active_branch_bound | type) == "boolean" and
          (.lineage_metadata_present | type) == "boolean" and
          (.lineage_metadata_valid | type) == "boolean" and
          (.proof_may_revalidate_on_descendant | type) == "boolean" and
          .proof_evaluation_skipped_resolved_anchor == false and
          .proof_may_revalidate_on_descendant ==
            (.disposition == "unbound_proof_may_revalidate") and exact_proof_tuple;
        def authored_member:
          type == "object" and
          (keys | sort) == (["abandoned","anchor_txid","anchor_vout",
            "branch_quarantine_observation_present","confirmations","created_tip",
            "expired_locally_retired","family","first_quarantine_observation_present",
            "in_active_chain","in_local_mempool","observer_absent","ordinal",
            "parent_txid","proof_input_bound","proof_origin_bound","proof_version","quarantine_marker",
            "root_txid","txid"] | sort) and
          (.txid | hex64) and (.ordinal | integer and . >= 0) and
          (.parent_txid | hex64) and (.root_txid | hex64) and (.family | hex64) and
          (.anchor_txid | hex64) and (.anchor_vout | integer and . >= 0) and
          (.created_tip | hex64) and .quarantine_marker == "1" and
          (.proof_version | integer and IN(2,3,4)) and
          (if .proof_version == 2 then
             .proof_origin_bound == false and .proof_input_bound == false
           elif .proof_version == 3 then
             .proof_origin_bound == true and .proof_input_bound == false
           else
             .proof_origin_bound == true and .proof_input_bound == true
           end) and
          (.expired_locally_retired | type) == "boolean" and
          .confirmations == 0 and (.abandoned | type) == "boolean" and
          .in_local_mempool == false and .in_active_chain == false and
          .observer_absent == true and
          (.first_quarantine_observation_present | type) == "boolean" and
          (.branch_quarantine_observation_present | type) == "boolean";
        def claim_keys: [
          "abandoned_wallet_txids","abandontransaction_invoked",
          "added_wallet_outpoints","authenticated_anchors","authored_components",
          "added_outpoints_exclusive_to_external_receives",
          "automatic_recovery_authorized","candidate_authored_suffixes_authenticated",
          "candidate_authorship_mapped_exactly","candidate_claims_submitted",
          "candidate_cleanly_stopped","candidate_complete_log_sha256",
          "candidate_created_qqsproof_confirmed_txids",
          "candidate_created_qqsproof_mempool_txids",
          "candidate_created_qqsproof_observer_txids",
          "candidate_created_qqsproof_txids",
          "candidate_created_qqsproof_unclassifiable_txids",
          "candidate_mining_gate_coherent","candidate_mining_gate_database_ambiguous",
          "candidate_mining_gate_unsafe_claims","candidate_mining_gate_unsafe_components",
          "candidate_post_stop_log_receipt_sha256",
          "candidate_recovery_database_ambiguous","candidate_retired_member_txids",
          "candidate_source_sha","candidate_stopped_receipt_sha256",
          "candidate_txids_mapped_once","claim_sample_tips","claim_samples_monotonic",
          "coinstake_created_txids","component_resolution_txids_after",
          "component_resolution_txids_before","continuous_absence_verified",
          "fee_payments_authorized","final_claim_sample_complete","final_order",
          "final_pow_enabled","final_pow_hashrate","final_stable_cut_sha256",
          "external_receive_evidence_bound","external_receive_evidence_sha256",
          "external_receive_txids",
          "forbidden_rpc_methods","hard_staking_disabled_continuously",
          "initial_atomic_reservation_verified",
          "interactive_surfaces_stopped_continuously",
          "legacy_baseline_wallet_authority_mutations",
          "legacy_baseline_wallet_authority_preserved","logs_complete_through_stop",
          "mempool_differential_classified","network_visible_candidate_authored_txids",
          "new_nonclaim_wallet_transactions",
          "new_wallet_txids_exclusive_to_authenticated_authored_claims_or_external_receives",
          "observation_sample_count","observation_series_bound","observer_samples",
          "observer_status","observer_terminal_proof_sha256","payout_address_after",
          "payout_address_after_owned","payout_address_before",
          "payout_address_transition_valid","payout_rotation_invoked","phase","pow_worker_joined",
          "progress_tips","quantum_inventory_sha256_after",
          "quantum_inventory_sha256_before","quantum_inventory_transition_valid",
          "quantum_key_count_after","quantum_key_count_before",
          "quantum_label_evidence_sha256_after",
          "quantum_label_evidence_sha256_before","recovery_rpc_invoked",
          "removed_outpoints_subset_of_authenticated_anchors",
          "removed_wallet_outpoints","resolution_txids_after","resolution_txids_before",
          "retired_claim_objects","retired_components","rpc_allowlist_enforced",
          "rpc_methods_sha256","run_nonce","schema","sendrawtransaction_invoked",
          "shared_namespace_rpc_auth_boundary_continuously_verified",
          "terminal_stable_cut_verified","txid_differential_classified",
          "unexpected_rpc_methods","visibility_samples_bound_to_progress",
          "wallet_locked","wallet_outpoint_differential_classified"
        ];
        . as $proof |
        type == "object" and .schema == 6 and .phase == "A" and
        (keys | sort) == (claim_keys | sort) and
        (.run_nonce | test("^[0-9a-f]{32}$")) and
        .candidate_source_sha == $source and
        (.observation_sample_count | integer and . >= 3) and
        .final_order == ["tip-proof","pow-stop-joined",
          "wallet-claim-mempool-observer-proof","wallet-locked",
          "candidate-clean-stop","logs-complete-through-stop"] and
        .pow_worker_joined == true and .final_pow_enabled == false and
        .final_pow_hashrate == 0 and .logs_complete_through_stop == true and
        .wallet_locked == true and .candidate_cleanly_stopped == true and
        (.candidate_stopped_receipt_sha256 | hex64) and
        (.candidate_complete_log_sha256 | hex64) and
        (.candidate_post_stop_log_receipt_sha256 | hex64) and
        (.external_receive_evidence_sha256 | hex64) and
        .external_receive_evidence_bound == true and
        (.observer_terminal_proof_sha256 | hex64) and
        (.final_stable_cut_sha256 | hex64) and .terminal_stable_cut_verified == true and
        .interactive_surfaces_stopped_continuously == true and
        .shared_namespace_rpc_auth_boundary_continuously_verified == true and
        .rpc_allowlist_enforced == true and .unexpected_rpc_methods == [] and
        (.candidate_claims_submitted | integer and . == 0) and
        .candidate_mining_gate_coherent == true and
        .candidate_mining_gate_database_ambiguous == false and
        .candidate_mining_gate_unsafe_claims == 0 and
        .candidate_mining_gate_unsafe_components == 0 and
        .candidate_recovery_database_ambiguous == false and
        (.retired_claim_objects | integer and . >= 0) and
        (.retired_components | integer and . >= 0) and
        (.candidate_retired_member_txids | type == "array" and
          all(.[]; hex64) and . == (sort | unique) and
          all(.[]; . as $txid |
            ($proof.candidate_created_qqsproof_txids | index($txid)) != null)) and
        .hard_staking_disabled_continuously == true and
        .coinstake_created_txids == [] and
        .network_visible_candidate_authored_txids == [] and
        .fee_payments_authorized == false and .automatic_recovery_authorized == false and
        .recovery_rpc_invoked == false and .sendrawtransaction_invoked == false and
        .abandontransaction_invoked == false and .payout_rotation_invoked == false and
        .forbidden_rpc_methods == [] and (.rpc_methods_sha256 | hex64) and
        (.payout_address_before | type) == "string" and
        (.payout_address_after | type) == "string" and
        .payout_address_after_owned ==
          ((.payout_address_after | length) > 0) and
        .payout_address_transition_valid == true and
        .quantum_key_count_after == .quantum_key_count_before and
        (.quantum_inventory_sha256_before | hex64) and
        (.quantum_inventory_sha256_after | hex64) and
        (.quantum_label_evidence_sha256_before | hex64) and
        (.quantum_label_evidence_sha256_after | hex64) and
        .quantum_inventory_transition_valid == true and
        .resolution_txids_after == .resolution_txids_before and
        (.component_resolution_txids_before | type) == "array" and
        (.component_resolution_txids_after | type) == "array" and
        all(.component_resolution_txids_after[]; hex64) and
        .component_resolution_txids_after ==
          (.component_resolution_txids_after | sort | unique) and
        all(.component_resolution_txids_after[];
          . as $txid | ($proof.component_resolution_txids_before | index($txid)) != null) and
        (.candidate_created_qqsproof_txids | type == "array" and
          all(.[]; hex64) and
          . == (sort | unique)) and
        (.external_receive_txids | type == "array" and
          all(.[]; hex64) and . == (sort | unique)) and
        ((.candidate_created_qqsproof_txids - .external_receive_txids) | length) ==
          (.candidate_created_qqsproof_txids | length) and
        .candidate_created_qqsproof_mempool_txids == [] and
        .candidate_created_qqsproof_confirmed_txids == [] and
        .candidate_created_qqsproof_observer_txids == [] and
        .candidate_created_qqsproof_unclassifiable_txids == [] and
        .observer_status == "observed_absent" and
        (.observer_samples | integer and . >= $proof.observation_sample_count) and
        .continuous_absence_verified == true and
        .initial_atomic_reservation_verified == true and
        .new_nonclaim_wallet_transactions == [] and
        (.abandoned_wallet_txids | type == "array" and
          all(.[]; hex64) and . == (sort | unique) and
          all(.[]; . as $txid |
            ($proof.candidate_created_qqsproof_txids | index($txid)) != null)) and
        .legacy_baseline_wallet_authority_preserved == true and
        .legacy_baseline_wallet_authority_mutations == [] and
        (.progress_tips | type == "array" and
          length == $proof.observation_sample_count and all(.[]; hex64) and
          (unique | length) == length) and
        .claim_sample_tips == .progress_tips and .claim_samples_monotonic == true and
        .visibility_samples_bound_to_progress == true and
        .observation_series_bound == true and
        .candidate_authorship_mapped_exactly == true and
        .candidate_txids_mapped_once == true and
        .candidate_authored_suffixes_authenticated == true and
        .new_wallet_txids_exclusive_to_authenticated_authored_claims_or_external_receives == true and
        .final_claim_sample_complete == true and
        .removed_outpoints_subset_of_authenticated_anchors == true and
        (.authored_components | type == "array" and
          . == (sort_by(.anchor_txid,.anchor_vout,.family,.root_txid))) and
        ((.candidate_created_qqsproof_txids | length) == 0) ==
          ((.authored_components | length) == 0) and
        all(.authored_components[]; . as $component |
          type == "object" and
          (keys | sort) == (["all_claims_expired_locally_retired",
            "all_claims_zero_payment_retirable","anchor_txid","anchor_vout",
            "authenticated","component_claim_txids","contiguous_parents","family",
            "full_members","newly_authored_contiguous_suffix",
            "newly_authored_members","newly_authored_txids",
            "ordinary_or_mixed_txids","resolution_txids","root_txid"] | sort) and
          .authenticated == true and
          (.all_claims_zero_payment_retirable | type) == "boolean" and
          (.all_claims_expired_locally_retired | type) == "boolean" and
          .ordinary_or_mixed_txids == [] and .resolution_txids == [] and
          (.anchor_txid | hex64) and (.anchor_vout | integer and . >= 0) and
          (.family | hex64) and (.root_txid | hex64) and
          (.component_claim_txids | type == "array" and length >= 1 and
            all(.[]; hex64) and (unique | length) == length) and
          (.full_members | type == "array" and
            length == ($component.component_claim_txids | length) and
            all(.[]; full_member)) and
          ([.full_members[].txid] == .component_claim_txids) and
          ([.full_members[].ordinal] == [range(0; .full_members | length)]) and
          .root_txid == .full_members[0].txid and
          (.full_members[0] as $root |
            if $root.lineage_metadata_present then
              $root.lineage_metadata_valid == true and
              $root.root_txid == $root.txid and $root.parent_txid == $zero and
              $root.family == $component.family
            else
              $root.lineage_metadata_valid == false and
              $root.family == $zero and $root.root_txid == $zero and
              $root.parent_txid == $zero and
              (if $root.proof_version == 2 and ($component.full_members | length) == 1
               then $root.authored_tip_active_branch_bound == true and
                 ($root.disposition | IN("eligible","unbound_proof_may_revalidate"))
               else true end)
            end) and
          all(range(1; ($component.full_members | length));
            $component.full_members[.].lineage_metadata_present == true and
            $component.full_members[.].lineage_metadata_valid == true and
            $component.full_members[.].root_txid == $component.root_txid and
            $component.full_members[.].family == $component.family) and
          ([range(1; ($component.full_members | length)) as $i |
            $component.full_members[$i].parent_txid ==
              $component.full_members[$i - 1].txid] | all) and
          .contiguous_parents == true and
          (.newly_authored_txids | type == "array" and length >= 1 and
            all(.[]; hex64) and (unique | length) == length and
            length <= ($component.component_claim_txids | length)) and
          (.newly_authored_txids as $new |
            .component_claim_txids[(-($new | length)):] == $new) and
          (.newly_authored_members | type == "array" and
            length == ($component.newly_authored_txids | length) and
            all(.[]; authored_member)) and
          ([.newly_authored_members[].txid] == .newly_authored_txids) and
          all(.newly_authored_members[]; . as $member |
            .anchor_txid == $component.anchor_txid and
            .anchor_vout == $component.anchor_vout and
            .family == $component.family and .root_txid == $component.root_txid and
            ($proof.progress_tips | index($member.created_tip)) != null and
            ([$component.full_members[] |
              select(.txid == $member.txid and .ordinal == $member.ordinal and
                .parent_txid == $member.parent_txid and
                .root_txid == $member.root_txid and .family == $member.family)] |
              length) == 1) and
          .newly_authored_contiguous_suffix == true) and
        .candidate_retired_member_txids ==
          ([.authored_components[].newly_authored_members[] |
            select(.expired_locally_retired == true) | .txid] | sort | unique) and
        .abandoned_wallet_txids ==
          ([.authored_components[].newly_authored_members[] |
            select(.abandoned == true) | .txid] | sort | unique) and
        ([.authored_components[].component_claim_txids[]] as $component_txids |
          ($component_txids | unique | length) == ($component_txids | length)) and
        ([.authored_components[] |
          [.anchor_txid,.anchor_vout,.family,.root_txid] | @json] as $component_keys |
          ($component_keys | unique | length) == ($component_keys | length)) and
        ([.authored_components[].newly_authored_txids[]] | sort) ==
          .candidate_created_qqsproof_txids and
        (.authenticated_anchors | type == "array" and
          all(.[]; anchor_descriptor) and
          . == (sort_by(.txid,.vout) | unique_by(.txid,.vout))) and
        .authenticated_anchors ==
          ([.authored_components[] | {txid:.anchor_txid,vout:.anchor_vout}] |
            sort_by(.txid,.vout) | unique_by(.txid,.vout)) and
        (.authenticated_anchors | length) == (.authored_components | length) and
        (.removed_wallet_outpoints | type == "array" and
          all(.[]; anchor_descriptor) and
          . == (sort_by(.txid,.vout) | unique_by(.txid,.vout))) and
        .removed_wallet_outpoints ==
          ([.removed_wallet_outpoints[]] | sort_by(.txid,.vout)) and
        (.added_wallet_outpoints | type == "array" and
          all(.[]; anchor_descriptor) and
          . == (sort_by(.txid,.vout) | unique_by(.txid,.vout))) and
        all(.added_wallet_outpoints[]; . as $outpoint |
          ($proof.external_receive_txids | index($outpoint.txid)) != null) and
        .added_outpoints_exclusive_to_external_receives == true and
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
        . as $certificate |
        type == "object" and
        (keys | sort) == (["baseline_runtime_identity_sha256",
          "authenticated_anchors","authored_components_sha256",
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
          "network_visible_candidate_authored_txids","nonpublication_sha256","nonpublication_verified",
          "observation_sample_count","observer_absence_verified",
          "observer_anchors_unspent_sha256",
          "observer_final_chain_sha256","observer_terminal_proof_sha256",
          "observer_tx_absence_sha256","offline_verifier_receipt_sha256",
          "package_sha256sums_sha256","phase_a_script_sha256",
          "phase_a_tooling_identity_sha256","phase_b_script_sha256",
          "pos_disabled_continuously","pow_worker_joined","pre_rewind_manifest_sha256",
          "pre_rewind_state_sha256","progress_sha256","promotion_marker_absent",
          "recovery_spend_or_fee_detected","result",
          "rpc_journal_sha256","run_nonce",
          "rpc_allowlist_enforced",
          "schema","snapshot_set_sha256","snapshots_held","terminal_chainwork",
          "shared_namespace_rpc_auth_boundary_verified","terminal_height","terminal_tip",
          "terminal_stable_cut_verified","tooling_commit","typed_contract_sha256",
          "unclassifiable_candidate_txids","unknown_or_ambiguous","unrelated_wallet_delta",
          "verifier_sha256","wallet_generation","wallet_locked"] | sort) and
        (.schema | integer and . == 2) and .result == "REWIND_SAFE" and
        .run_nonce == $nonce and .candidate_source_sha == $source and
        ($nonce | test("^[0-9a-f]{32}$")) and
        (.observation_sample_count | integer and . >= 3) and
        (.candidate_image_id | test("^sha256:[0-9a-f]{64}$")) and
        .candidate_image_ref == $image_ref and
        (.candidate_manifest_digest | test("^sha256:[0-9a-f]{64}$")) and
        (.candidate_blackcoin_qt_sha256 | hex64) and
        (.tooling_commit | test("^[0-9a-f]{40}$")) and
        (.phase_a_tooling_identity_sha256 | hex64) and
        (.package_sha256sums_sha256 | hex64) and (.phase_a_script_sha256 | hex64) and
        (.phase_b_script_sha256 | hex64) and (.verifier_sha256 | hex64) and
        (.typed_contract_sha256 | hex64) and
        .entrypoint_body_sha256 == $body and
        (.invocation_sha256 | hex64) and
        (.helper_audit_sha256 | hex64) and (.nonpublication_sha256 | hex64) and
        (.snapshot_set_sha256 | hex64) and (.progress_sha256 | hex64) and
        (.claim_proof_sha256 | hex64) and (.authored_components_sha256 | hex64) and
        (.logs_sha256 | hex64) and
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
             .observer_anchors_unspent_sha256,.observer_tx_absence_sha256,
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
        (.candidate_created_qqsproof_txids | type == "array" and
          all(.[]; hex64) and
          . == (sort | unique)) and
        (.authenticated_anchors | type == "array" and
          all(.[];
            type == "object" and (keys | sort) == ["txid","vout"] and
            (.txid | hex64) and (.vout | integer and . >= 0)) and
          . == (sort_by(.txid,.vout) | unique_by(.txid,.vout)) and
          length <= ($certificate.candidate_created_qqsproof_txids | length)) and
        ((.candidate_created_qqsproof_txids | length) == 0) ==
          ((.authenticated_anchors | length) == 0) and
        .network_visible_candidate_authored_txids == [] and .confirmed_candidate_txids == [] and
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
        (keys | sort) == (["authenticated_anchors","authenticated_anchors_evidence_sha256",
          "authenticated_anchors_unspent","candidate_claim_escape_absent",
          "candidate_image_not_applied","candidate_txids_absent_from_mempool",
          "candidate_txids_absent_from_wallet","chain","chain_after",
          "chain_after_evidence_sha256","chain_evidence_sha256",
          "chainwork_at_least_phase_a","hard_quarantine_flags_verified","image","image_id",
          "invocation_sha256","mempool_sha256","network","network_evidence_sha256",
          "nonpublication_sha256","observer_anchors_unspent",
          "observer_candidate_txids_absent","observer_cut_sha256",
          "phase_a_terminal_chainwork","phase_a_terminal_tip","pos_enabled","pow",
          "pow_enabled","pow_evidence_sha256","recovery","recovery_evidence_sha256",
          "run_nonce","schema","source_sha","stable_cut","staking",
          "staking_evidence_sha256","terminal_tip_active",
          "terminal_tip_superseded_by_greater_work","wallet","wallet_evidence_sha256",
          "wallet_locked","wallet_processed_tip_current","wallet_transactions_sha256",
          "walletbroadcast","wallets","wallets_evidence_sha256"] | sort) and
        (.schema | integer and . == 2) and .run_nonce == $nonce and
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
        (.wallet | type) == "object" and (.wallet.walletname | type) == "string" and
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
        .wallets == [.wallet.walletname] and
        (.authenticated_anchors | type == "array" and
          . == (sort_by(.txid,.vout) | unique_by(.txid,.vout)) and
          all(.[];
            type == "object" and
            (keys | sort) == ["txid","txout","unspent","vout"] and
            (.txid | hex64) and (.vout | integer and . >= 0) and
            .unspent == true and (.txout | type) == "object" and
            (.txout.confirmations | integer and . >= 1) and
            .txout.coinbase == false)) and
        all([.invocation_sha256,.nonpublication_sha256,.observer_cut_sha256,
             .chain_evidence_sha256,.chain_after_evidence_sha256,
             .recovery_evidence_sha256,.wallet_evidence_sha256,
             .staking_evidence_sha256,.pow_evidence_sha256,.network_evidence_sha256,
             .wallets_evidence_sha256,.wallet_transactions_sha256,.mempool_sha256,
             .authenticated_anchors_evidence_sha256][]; hex64) and
        .wallet_processed_tip_current == true and .candidate_image_not_applied == true and
        .candidate_txids_absent_from_wallet == true and
        .candidate_txids_absent_from_mempool == true and
        .authenticated_anchors_unspent == true and
        .observer_candidate_txids_absent == true and .observer_anchors_unspent == true and
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
          "evidence_sha256sums_sha256",
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
          "goldrush_state_sha256","main_chain_ready","observed_epoch","p2p_ready",
          "payout_address","payout_owned",
          "quantum_key_count","recovery_database_unambiguous",
          "recovery_policy_nonautomatic",
          "schema","stable_tip","staking_active","wallet_normally_unlocked"] | sort) and
        .schema == 2 and (.observed_epoch | integer and . > 0) and
        (.stable_tip | hex64) and
        (.goldrush_state_sha256 | hex64) and
        .main_chain_ready == true and .p2p_ready == true and
        .wallet_normally_unlocked == true and
        (.exact_loaded_wallets | type == "array" and length == 1 and
          (.[0] | type) == "string") and
        .staking_active == true and (.payout_address | type == "string") and
        (.payout_owned | type == "boolean") and
        (if (.payout_address | length) > 0 then .payout_owned == true
         else .payout_owned == false end) and
        (.quantum_key_count | integer and . > 0) and
        .recovery_database_unambiguous == true and .recovery_policy_nonautomatic == true and
        .irreversible_marker_allowed == true
    ' "$file" >/dev/null
}

hotfix_phase_b_baseline_bundle_is_valid()
{
    local root="$1" pre chain chain_after wallet network staking recovery pow loaded payout
    local observed tip height quantum_count goldrush
    for pre in baseline-precondition.json baseline-chain.json baseline-chain-after.json \
        baseline-wallet.json baseline-network.json baseline-staking.json baseline-recovery.json \
        baseline-pow.json baseline-loaded-wallets.json baseline-quantum.json \
        baseline-goldrush-state.json \
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
    height=$(jq -er '.blocks' "$chain") || return 1
    goldrush="$root/baseline-goldrush-state.json"
    hotfix_goldrush_state_json_is_valid "$(<"$goldrush")" "$tip" "$height" || return 1
    [[ "$(hotfix_sha256_file "$goldrush")" == \
       "$(jq -er '.goldrush_state_sha256' "$pre")" ]] || return 1
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
      (.walletname | type) == "string" and
      .private_keys_enabled == true and .scanning == false and
      .unlocked_staking_only == false and (.unlocked_until | integer) and
      .unlocked_until > $observed
    ' "$wallet" >/dev/null || return 1
    jq -e '(.networkactive|type)=="boolean" and .networkactive==true and
      (.connections_out|type)=="number" and (.connections_out|floor)==.connections_out and
      .connections_out>=3' "$network" >/dev/null || return 1
    hotfix_phase_b_staking_json_is_active "$(<"$staking")" || return 1
    hotfix_candidate_recovery_json_is_valid "$(<"$recovery")" || return 1
    jq -e --arg tip "$tip" '.active_tip==$tip and .wallet_processed_tip==$tip' \
      "$recovery" >/dev/null || return 1
    jq -e '(.enabled|type)=="boolean" and (.payout_address|type)=="string"' \
      "$pow" >/dev/null || return 1
    payout=$(jq -er '.payout_address' "$pow") || return 1
    [[ "$payout" == "$(jq -er '.payout_address' "$pre")" ]] || return 1
    if [[ -n "$payout" ]]; then
        jq -e --arg payout "$payout" '.address==$payout and .ismine==true' \
            "$root/baseline-payout-address.json" >/dev/null || return 1
        [[ "$(jq -er '.payout_owned' "$pre")" == true ]] || return 1
    else
        jq -e '. == null' "$root/baseline-payout-address.json" >/dev/null || return 1
        [[ "$(jq -er '.payout_owned' "$pre")" == false ]] || return 1
    fi
    jq -e --slurpfile wallet "$wallet" '
      type == "array" and length == 1 and .[0] == $wallet[0].walletname
    ' "$loaded" >/dev/null || return 1
    jq -e --slurpfile wallet "$wallet" '
      .exact_loaded_wallets == [$wallet[0].walletname]
    ' "$pre" >/dev/null || return 1
    quantum_count=$(jq -er 'if type=="array" then length
      elif (.keys?|type)=="array" then (.keys|length)
      elif (.inventory?|type)=="array" then (.inventory|length)
      elif (.total?|type)=="number" and (.total|floor)==.total and .total>=0 then .total
      else error("schema") end' "$root/baseline-quantum.json") || return 1
    [[ "$quantum_count" == "$(jq -er '.quantum_key_count' "$pre")" ]] || return 1
    if [[ -n "$payout" ]]; then
        hotfix_quantum_payout_address_is_valid \
            "$root/baseline-payout-address.json" "$root/baseline-quantum.json" \
            "$payout" || return 1
    fi
    jq -e '.database_outcome_ambiguous == false and .policy_authoritative == true and
      .policy.automatic_authorized == false and .policy.automatic_enabled == false' \
      "$recovery" >/dev/null
}

hotfix_phase_b_locked_sync_file_is_valid()
{
    local file="$1" recovery pow staking
    [[ -f "$file" && ! -L "$file" ]] || return 1
    jq -e '
        def integer: type == "number" and floor == .;
        def hex64: type == "string" and test("^[0-9a-f]{64}$");
        type == "object" and (keys | sort) == (["chain","loaded_wallets",
          "locked_pos_zero_work","locked_pow_zero_work","normal_unlock_called",
          "pos_intent_retained","pow","pow_intent_retained","recovery","schema",
          "staking","synchronized","wallet","wallet_locked"] | sort) and
        .schema == 2 and .synchronized == true and .wallet_locked == true and
        .normal_unlock_called == false and .pos_intent_retained == true and
        .pow_intent_retained == true and .locked_pos_zero_work == true and
        .locked_pow_zero_work == true and
        (.chain | type) == "object" and .chain.chain == "main" and
        .chain.initialblockdownload == false and
        (.chain.blocks | integer and . >= 0) and .chain.blocks == .chain.headers and
        (.chain.bestblockhash | hex64) and
        .recovery.active_tip == .chain.bestblockhash and
        .recovery.wallet_processed_tip == .chain.bestblockhash and
        .pow.claim_inventory_tip == .chain.bestblockhash and
        .staking.blocks == .chain.blocks and .staking.active_blocks == .chain.blocks and
        (.wallet | type) == "object" and (.wallet.walletname | type) == "string" and
        .wallet.private_keys_enabled == true and .wallet.scanning == false and
        .wallet.unlocked_until == 0 and .wallet.unlocked_staking_only == false and
        .loaded_wallets == [.wallet.walletname]
    ' "$file" >/dev/null || return 1
    recovery=$(jq -ce '.recovery' "$file") || return 1
    pow=$(jq -ce '.pow' "$file") || return 1
    staking=$(jq -ce '.staking' "$file") || return 1
    hotfix_candidate_recovery_json_is_valid "$recovery" &&
        hotfix_candidate_pow_json_is_valid "$pow" locked &&
        hotfix_phase_b_staking_json_is_locked_with_intent "$staking" &&
        hotfix_pow_recovery_same_cut_json_is_valid "$pow" "$recovery"
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
        .schema == 4 and
        (.baseline_txids | txids) and (.new_txids | txids) and
        ([.baseline_txids[],.new_txids[]] | unique | length) ==
          ((.baseline_txids | length) + (.new_txids | length)) and
        .allowed_classes == ["confirmed_coinstake","authenticated_qq_claim",
          "authenticated_qq_claim_payout","external_receive"] and
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
            (keys | sort) == ["blockhash","class","payout_address","source_claim_txid","txid"] and
            (.blockhash | hex64) and (.source_claim_txid | hex64) and
            (.payout_address | type == "string" and length > 0)
          elif .class == "external_receive" then
            (keys | sort) == ["blockhash","class","txid"] and
            (.blockhash == null or (.blockhash | hex64))
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
    local expected_recovery="${4:-}" expected_baseline_recovery="${5:-}"
    local expected_progress="${6:-}"
    [[ -f "$file" && ! -L "$file" ]] || return 1
    jq -e --arg baseline "$expected_baseline" --arg final "$expected_final" \
        --arg recovery "$expected_recovery" \
        --arg baseline_recovery "$expected_baseline_recovery" \
        --arg progress "$expected_progress" --arg zero "$HOTFIX_ZERO_TXID" '
        def integer: type == "number" and floor == .;
        def uint: integer and . >= 0;
        def uint32: integer and . >= 0 and . < 4294967295;
        def hex64: type == "string" and test("^[0-9a-f]{64}$");
        def nonzero_hex64: hex64 and . != $zero;
        def rawhex: type == "string" and test("^([0-9a-f]{2})+$");
        def matches($expected): $expected == "" or . == $expected;
        def no_control_metadata:
          ([keys[] | select(startswith("qq_"))] | length) == 0;
        def claim_nodes($component):
          $component.nodes | map(select(.kind == "claim")) | sort_by(.lineage_ordinal);
        def known_disposition($node):
          ($node.disposition | IN("eligible","inactive","height_before_window",
            "height_after_window","invalid_location","malformed","duplicate",
            "wrong_mode","unknown_mode","unsupported_version",
            "version_not_yet_active","invalid_proof",
            "unbound_proof_may_revalidate","origin_not_yet_reached",
            "origin_mismatch","origin_expired","input_mismatch",
            "already_accounted","capacity_limit","evaluation_limit",
            "local_state_error"));
        def exact_proof_tuple($node):
          ($node.proof_version == 2 and
             $node.proof_origin_bound == false and $node.proof_input_bound == false) or
          ($node.proof_version == 3 and
             $node.proof_origin_bound == true and $node.proof_input_bound == false) or
          ($node.proof_version == 4 and
             $node.proof_origin_bound == true and $node.proof_input_bound == true);
        def implicit_claim_root($node;$claim_count):
          known_disposition($node) and
          $node.lineage_metadata_present == false and
          $node.lineage_metadata_valid == false and
          $node.lineage_ordinal == 0 and
          $node.lineage_family_fingerprint == $zero and
          $node.lineage_root_txid == $zero and
          $node.lineage_parent_txid == $zero and
          $node.proof_mode == "pow" and
          $node.provenance == "explicit_authored" and
          $node.authored_metadata_valid == true and
          $node.expected_shape == true and
          $node.claim_descriptor_valid == true and
          $node.exact_authored_carrier_shape == true and
          $node.proof_evaluation_skipped_resolved_anchor == false and
          $node.proof_may_revalidate_on_descendant ==
            ($node.disposition == "unbound_proof_may_revalidate") and
          exact_proof_tuple($node) and
          (if $node.proof_version == 2 then
             ($node.in_mempool == true or
               ($node.disposition | IN("eligible",
                 "unbound_proof_may_revalidate"))) and
             (if $claim_count == 1
              then $node.authored_tip_active_branch_bound == true
              else true end)
           elif $node.proof_version == 3 or $node.proof_version == 4 then
             $node.in_mempool == true or
               ($node.disposition | IN("eligible","origin_mismatch","origin_expired"))
           else false end);
        def component_node_match($match):
          ($match | type) == "object" and
          ($match | keys | sort) == ["component","node"] and
          ($match.component | type) == "object" and
          ($match.node | type) == "object" and ($match.node.txid | hex64) and
          ($match.component.nodes | type) == "array" and
          ([$match.component.nodes[] |
             select(.txid == $match.node.txid and . == $match.node)] | length) == 1;
        def canonical_claim_component($match):
          component_node_match($match) and
          ($match.component) as $component |
          (claim_nodes($component)) as $claims |
          ($claims | length) >= 1 and
          $component.anchor_authenticated == true and
          $component.anchor_unspent == true and
          $component.anchor_user_locked == false and
          ($component.anchor.txid | nonzero_hex64) and
          ($component.anchor.vout | uint32) and
          ($component.anchor.amount | type) == "number" and
          $component.anchor.amount > 0 and
          ($component.anchor.scriptPubKey | rawhex) and
          ($component.generation_fingerprint | hex64) and
          $component.generation_fingerprint != $zero and
          ($component.claim_txids | type) == "array" and
          ($component.claim_txids | unique | length) ==
            ($component.claim_txids | length) and
          ($component.nodes | map(.txid) | unique | length) ==
            ($component.nodes | length) and
          ([ $claims[].txid ] | sort) == ($component.claim_txids | sort) and
          ($claims | map(.lineage_ordinal)) == [range(0; ($claims | length))] and
          (if $claims[0].lineage_metadata_present then
             $claims[0].lineage_metadata_valid == true and
             $claims[0].lineage_root_txid == $claims[0].txid and
             $claims[0].lineage_parent_txid == $zero and
             $claims[0].lineage_family_fingerprint == $component.generation_fingerprint
           else
             implicit_claim_root($claims[0]; ($claims | length))
           end) and
          all(range(1; ($claims | length));
            $claims[.].lineage_metadata_present == true and
            $claims[.].lineage_metadata_valid == true and
            $claims[.].lineage_family_fingerprint == $component.generation_fingerprint and
            $claims[.].lineage_root_txid == $claims[0].txid and
            $claims[.].lineage_parent_txid == $claims[.-1].txid) and
          all($claims[];
            (.txid | hex64) and .kind == "claim" and
            .proof_mode == "pow" and .active_chain_confirmed == false and
            known_disposition(.) and
            .expected_shape == true and .wallet_authored == true and
            .wallet_from_me == true and .authored_metadata_valid == true and
            .claim_descriptor_valid == true and .exact_authored_carrier_shape == true and
            .proof_evaluation_skipped_resolved_anchor == false and
            .proof_may_revalidate_on_descendant ==
              (.disposition == "unbound_proof_may_revalidate") and
            .provenance == "explicit_authored" and exact_proof_tuple(.));
        def authenticated_new_claim($match;$txid):
          canonical_claim_component($match) and
          $match.node.txid == $txid and $match.node.kind == "claim" and
          $match.node.provenance == "explicit_authored" and
          $match.node.wallet_authored == true and $match.node.wallet_from_me == true and
          $match.node.expected_shape == true and
          $match.node.lineage_metadata_present == true and
          $match.node.lineage_metadata_valid == true and
          exact_proof_tuple($match.node) and
          $match.node.resolution_metadata_valid == false and
          $match.node.resolution_relay_authorized == false and
          ($match.component.claim_txids | index($txid)) != null and
          ($match.component.resolution_txids | index($txid)) == null and
          ($match.component.ordinary_or_mixed_txids | index($txid)) == null;
        def prior_authority($entry):
          ($entry | type) == "object" and
          ($entry | keys | sort) == ["active_tip","component","node",
            "observed_epoch","sample","source","wallet_processed_tip"] and
          ($entry.active_tip | nonzero_hex64) and
          $entry.wallet_processed_tip == $entry.active_tip and
          (if $entry.source == "baseline" then
             $entry.sample == null and $entry.observed_epoch == null
           elif $entry.source == "phase_b_progress" then
             ($entry.sample | integer and . >= 1) and
             ($entry.observed_epoch | integer and . > 0)
           else false end) and
          component_node_match({component:$entry.component,node:$entry.node});
        def prior_authorities($entries):
          ($entries | type) == "array" and all($entries[]; prior_authority(.)) and
          $entries == ($entries | sort_by(
            if .source == "baseline" then 0 else 1 end,
            (.sample // 0),.component.component_fingerprint,.node.txid)) and
          ([$entries[] | [.source,.sample,.node.txid]] | unique | length) ==
            ($entries | length);
        def exact_wallet_metadata($object;$match):
          $object.qq_shadow_pow_authored == "1" and
          $object.qq_shadow_pow_lineage_schema == "1" and
          $object.qq_shadow_pow_lineage_family ==
            $match.component.generation_fingerprint and
          $object.qq_shadow_pow_lineage_root == $match.node.lineage_root_txid and
          $object.qq_shadow_pow_lineage_parent == $match.node.lineage_parent_txid and
          $object.qq_shadow_pow_lineage_ordinal ==
            ($match.node.lineage_ordinal | tostring) and
          ($object.qq_shadow_pow_created_tip | hex64) and
          ($object.qq_shadow_pow_created_height? == null or
            ($object.qq_shadow_pow_created_height | type == "string" and
             test("^(0|[1-9][0-9]*)$"))) and
          $object.qq_shadow_pow_anchor_txid == $match.component.anchor.txid and
          $object.qq_shadow_pow_anchor_vout == ($match.component.anchor.vout | tostring) and
          ($object.qq_shadow_pow_cleanup_for? == null) and
          ($object.qq_shadow_pow_legacy_cleanup_quarantine? == null) and
          ($object.qq_auto_shadow_stale? == null) and
          ($object.qq_manual_shadow_abandon? == null) and
          ($object.qq_reorg_shadow_resubmit? == null) and
          ($object.qq_shadow_pow_resolution_schema? == null) and
          ($object.qq_shadow_pow_resolution_origin? == null) and
          ($object.qq_shadow_pow_resolution_anchor_txid? == null);
        def intrinsic_authored_descriptor($object;$txid):
          if ($object | type) == "object" and
             $object.qq_shadow_pow_authored == "1" and
             $object.qq_shadow_pow_lineage_schema == "1" and
             ($object.qq_shadow_pow_lineage_family | nonzero_hex64) and
             ($object.qq_shadow_pow_lineage_root | nonzero_hex64) and
             ($object.qq_shadow_pow_lineage_parent | hex64) and
             ($object.qq_shadow_pow_lineage_ordinal | type) == "string" and
             ($object.qq_shadow_pow_lineage_ordinal | test("^(0|[1-9][0-9]*)$")) and
             ($object.qq_shadow_pow_created_tip | nonzero_hex64) and
             ($object.qq_shadow_pow_created_height? == null or
               (($object.qq_shadow_pow_created_height | type) == "string" and
                ($object.qq_shadow_pow_created_height | test("^(0|[1-9][0-9]*)$")))) and
             ($object.qq_shadow_pow_anchor_txid | nonzero_hex64) and
             ($object.qq_shadow_pow_anchor_vout | type) == "string" and
             ($object.qq_shadow_pow_anchor_vout | test("^(0|[1-9][0-9]*)$")) and
             ($object.qq_shadow_pow_anchor_vout | tonumber) < 4294967295 and
             ($object.qq_shadow_pow_cleanup_for? == null) and
             ($object.qq_shadow_pow_legacy_cleanup_quarantine? == null) and
             ($object.qq_auto_shadow_stale? == null) and
             ($object.qq_manual_shadow_abandon? == null) and
             ($object.qq_reorg_shadow_resubmit? == null) and
             ($object.qq_shadow_pow_resolution_schema? == null) and
             ($object.qq_shadow_pow_resolution_origin? == null) and
             ($object.qq_shadow_pow_resolution_anchor_txid? == null) and
             # With no retained recovery component, the wallet record alone can
             # authenticate only an ordinal-zero root. Descendants require the
             # earlier same-run full component authority so their parent chain
             # is not inferred from self-asserted mapValue metadata.
             ($object.qq_shadow_pow_lineage_ordinal == "0") and
             $object.qq_shadow_pow_lineage_root == $txid and
             $object.qq_shadow_pow_lineage_parent == $zero
          then {family:$object.qq_shadow_pow_lineage_family,
            root:$object.qq_shadow_pow_lineage_root,
            parent:$object.qq_shadow_pow_lineage_parent,
            ordinal:$object.qq_shadow_pow_lineage_ordinal,
            created_tip:$object.qq_shadow_pow_created_tip,
            created_height:($object.qq_shadow_pow_created_height? // null),
            anchor_txid:$object.qq_shadow_pow_anchor_txid,
            anchor_vout:$object.qq_shadow_pow_anchor_vout}
          else null end;
        def intrinsic_confirmed_authored_claim($record;$tx):
          (intrinsic_authored_descriptor($tx;$record.txid)) as $descriptor |
          $descriptor != null and
          all($record.wallet_rows[];
            .txid == $record.txid and .category == "send" and
            (.comment | IN("Quantum Quasar built-in shadow PoW claim",
              "Blackcoin shadow PoW claim","PoW Claim","Quantum PoW Claim")) and
            intrinsic_authored_descriptor(.;$record.txid) == $descriptor);
        def clean_external_receive_detail:
          .category == "receive" and
          (.amount | type) == "number" and .amount > 0 and
          .abandoned == false and (.fee? == null) and (.generated? == null) and
          no_control_metadata and
          ((.comment? // "") |
            IN("Quantum Quasar built-in shadow PoW claim",
               "Blackcoin shadow PoW claim","PoW Claim","Quantum PoW Claim") | not);
        def clean_external_receive_row($txid):
          .txid == $txid and clean_external_receive_detail;
        def audit_only_component($match;$txid;$unanchored):
          component_node_match($match) and
          ($match.component) as $component |
          $match.node.txid == $txid and $match.node.kind == "claim" and
          $component.anchor_authenticated == false and
          $component.anchor_unspent == false and
          $component.anchor_user_locked == false and
          $component.anchor.amount == 0 and $component.anchor.scriptPubKey == "" and
          (($component.anchor.txid == $zero and
             $component.anchor.vout == 4294967295) or
           (($component.anchor.txid | nonzero_hex64) and
             ($component.anchor.vout | uint32))) and
          ($component.claim_txids | index($txid)) != null and
          ([ $component.nodes[] | select(.kind == "claim") | .txid ] | sort) ==
            ($component.claim_txids | sort) and
          ([ $component.nodes[].txid ] | unique | length) ==
            ($component.nodes | length) and
          all($component.nodes[];
            .provenance == "unknown" and .wallet_authored == false and
            .wallet_from_me == false) and
          all($component.claim_txids[];
            . as $claim | ($unanchored | index($claim)) != null);
        def external_receive($record;$unanchored):
          ($record.gettransaction_response) as $tx |
          $record.source_claim_txid == null and
          ($tx | type) == "object" and $tx.txid == $record.txid and
          ($tx.hex | type) == "string" and ($tx.hex | test("^[0-9a-f]+$")) and
          (($tx.hex | length) % 2) == 0 and
          ($tx.decoded | type) == "object" and $tx.decoded.txid == $record.txid and
          ($tx.fee? == null) and ($tx.amount | type) == "number" and $tx.amount > 0 and
          ($tx.generated? == null) and ($tx | no_control_metadata) and
          ($tx.confirmations | integer and . >= 0) and
          ($tx.details | type) == "array" and ($tx.details | length) >= 1 and
          all($tx.details[]; clean_external_receive_detail) and
          all($record.wallet_rows[]; clean_external_receive_row($record.txid)) and
          (if $tx.confirmations > 0 then
             ($record.blockhash | hex64) and $tx.blockhash == $record.blockhash and
             $record.recovery_matches == [] and
             ($record.getblock_response | type) == "object" and
             $record.getblock_response.hash == $record.blockhash and
             ($record.getblock_response.confirmations | integer and . > 0) and
             ($record.getblock_response.height | integer and . >= 0) and
             ($record.getblock_response.tx | type) == "array" and
             ($record.getblock_response.tx | index($record.txid)) != null and
             $record.getblockhash_response == $record.blockhash and
             all($record.wallet_rows[];
               (.confirmations | integer and . > 0) and
               .blockhash == $record.blockhash)
           else
             $tx.confirmations == 0 and ($tx.blockhash? == null) and
             $record.blockhash == null and $record.getblock_response == null and
             $record.getblockhash_response == null and
             all($record.wallet_rows[];
               .confirmations == 0 and (.blockhash? == null)) and
             (($record.recovery_matches | length) == 0 or
               (($record.recovery_matches | length) == 1 and
                audit_only_component(
                  $record.recovery_matches[0];$record.txid;$unanchored)))
          end) and
          $record.getshadowtransaction_response == null;
        def active_block_member($record;$txid):
          ($record.blockhash | hex64) and
          ($record.getblock_response | type) == "object" and
          $record.getblock_response.hash == $record.blockhash and
          ($record.getblock_response.confirmations | integer and . > 0) and
          ($record.getblock_response.height | integer and . >= 0) and
          ($record.getblock_response.tx | type) == "array" and
          ($record.getblock_response.tx | index($txid)) != null and
          $record.getblockhash_response == $record.blockhash;
        def authenticated_claim($record):
          ($record.gettransaction_response) as $tx |
          $record.source_claim_txid == null and
          $record.getshadowtransaction_response == null and
          ($tx | type) == "object" and $tx.txid == $record.txid and
          ($tx.hex | rawhex) and ($tx.decoded | type) == "object" and
          $tx.decoded.txid == $record.txid and
          ($tx.confirmations | integer and . >= 0) and
          ($tx.details | type) == "array" and ($tx.details | length) >= 1 and
          ([$record.prior_recovery_authority[] |
             select(.source == "phase_b_progress" and
               authenticated_new_claim(
                 {component:.component,node:.node};$record.txid))]) as
            $prior_authenticated |
          if $tx.confirmations == 0 then
            ($tx.blockhash? == null) and $record.blockhash == null and
            $record.getblock_response == null and $record.getblockhash_response == null and
            ($record.recovery_matches | length) == 1 and
            ($record.recovery_matches[0]) as $current |
            authenticated_new_claim($current;$record.txid) and
            exact_wallet_metadata($tx;$current) and
            all($record.wallet_rows[];
              .txid == $record.txid and .category == "send" and
              .confirmations == 0 and (.blockhash? == null) and
              (.comment | IN("Quantum Quasar built-in shadow PoW claim",
                "Blackcoin shadow PoW claim","PoW Claim","Quantum PoW Claim")) and
              exact_wallet_metadata(.;$current))
          elif $tx.confirmations > 0 then
            active_block_member($record;$record.txid) and
            $tx.blockhash == $record.blockhash and
            ($record.recovery_matches | length) <= 1 and
            all($record.recovery_matches[];
              .node.txid == $record.txid and .node.kind == "claim") and
            all($record.wallet_rows[];
              (.confirmations | integer and . > 0) and
              .blockhash == $record.blockhash) and
            (if ($prior_authenticated | length) >= 1 then
               ($prior_authenticated[-1]) as $authority |
               exact_wallet_metadata($tx;
                 {component:$authority.component,node:$authority.node}) and
               all($record.wallet_rows[];
                 .txid == $record.txid and .category == "send" and
                 (.comment | IN("Quantum Quasar built-in shadow PoW claim",
                   "Blackcoin shadow PoW claim","PoW Claim","Quantum PoW Claim")) and
                 exact_wallet_metadata(.;
                   {component:$authority.component,node:$authority.node}))
             else intrinsic_confirmed_authored_claim($record;$tx) end)
          else false end;
        def confirmed_coinstake($record):
          ($record.gettransaction_response) as $tx |
          ($record.blockhash | hex64) and $record.source_claim_txid == null and
          $record.recovery_matches == [] and
          $record.getshadowtransaction_response == null and
          $record.getblockhash_response == null and
          ($record.getblock_response | type) == "object" and
          $record.getblock_response.hash == $record.blockhash and
          ($record.getblock_response.confirmations | integer and . > 0) and
          ($record.getblock_response.tx | type) == "array" and
          ($record.getblock_response.tx | length) >= 2 and
          $record.getblock_response.tx[0] != $record.txid and
          $record.getblock_response.tx[1] == $record.txid and
          ($tx | type) == "object" and $tx.txid == $record.txid and
          ($tx.hex | rawhex) and ($tx.decoded | type) == "object" and
          $tx.decoded.txid == $record.txid and ($tx.fee? == null) and
          ($tx.confirmations | integer and . > 0) and
          $tx.blockhash == $record.blockhash and
          all($record.wallet_rows[];
            .txid == $record.txid and .generated == true and
            (.category | IN("generate","immature","orphan")) and
            .abandoned == false and .blockhash == $record.blockhash and
            (.fee? == null) and
            (.qq_shadow_pow_cleanup_for? == null) and
            (.qq_shadow_pow_resolution_schema? == null) and
            (.qq_synthetic_goldrush_payout? == null) and
            (.qq_shadow_pow_authored? == null));
        def exact_pow_claim_source($source;$height):
          ($source | type) == "object" and
          ($source | keys | sort) == ["base_fee","base_fee_known","canonical_rank",
            "claim_outpoint","disposition","inclusion_height","input_bound",
            "logical_proof_id","origin_age","origin_bound","origin_height",
            "origin_previous_block_hash","proof_version","txid","vout"] and
          ($source.txid | nonzero_hex64) and ($source.vout | uint32) and
          ($source.logical_proof_id | nonzero_hex64) and
          ($source.canonical_rank | nonzero_hex64) and
          $source.base_fee_known == true and
          ($source.base_fee | type) == "number" and $source.base_fee >= 0 and
          ($source.disposition |
            IN("winner","reimbursed_loser","reimbursed_late")) and
          ($source.origin_height | uint) and
          ($source.inclusion_height | integer and . > 0) and
          $source.inclusion_height == $height and ($source.origin_age | uint) and
          (if $source.proof_version == 2 then
             $source.origin_bound == false and $source.input_bound == false and
             $source.claim_outpoint == null and $source.origin_age == 0 and
             ($source.origin_previous_block_hash == null or
               ($source.origin_previous_block_hash | hex64))
           elif $source.proof_version == 3 or $source.proof_version == 4 then
             $source.origin_bound == true and
             ($source.origin_previous_block_hash | nonzero_hex64) and
             $source.origin_height > 0 and
             $source.inclusion_height >= $source.origin_height and
             $source.origin_age ==
               ($source.inclusion_height - $source.origin_height) and
             (if $source.proof_version == 3 then
                $source.input_bound == false and $source.claim_outpoint == null
              else
                $source.input_bound == true and
                ($source.claim_outpoint | type) == "object" and
                ($source.claim_outpoint | keys | sort) == ["txid","vout"] and
                ($source.claim_outpoint.txid | nonzero_hex64) and
                ($source.claim_outpoint.vout | uint32)
              end) and
             (if $source.disposition == "reimbursed_late" then
                $source.origin_height < $source.inclusion_height and
                $source.origin_age > 0
              else
                $source.origin_height == $source.inclusion_height and
                $source.origin_age == 0
              end)
           else false end);
        def exact_shadow_payout($shadow;$record):
          ($shadow | type) == "object" and
          ($shadow | keys | sort) == ["address","base_anchor","confirmations",
            "decayed_amount","demurrage","effective_amount","lifecycle",
            "lifecycle_category","merkle_included","mode","nominal_amount",
            "pow_claim_source","schema","scriptPubKey","spend","status",
            "synthetic","synthetic_txid","units","valuation_status","vout"] and
          $shadow.schema == "blackcoin.shadow.transaction.v1" and
          $shadow.synthetic == true and $shadow.merkle_included == false and
          $shadow.synthetic_txid == $record.txid and $shadow.mode == "pow" and
          ($shadow.status | IN("immature","gold_rush_locked","demurrage_locked",
            "unspent","spent")) and
          ($shadow.lifecycle_category | type) == "string" and
          ($shadow.nominal_amount | type) == "number" and $shadow.nominal_amount > 0 and
          ($shadow.effective_amount | type) == "number" and $shadow.effective_amount >= 0 and
          ($shadow.decayed_amount | type) == "number" and $shadow.decayed_amount >= 0 and
          ($shadow.valuation_status |
            IN("recorded_at_spend","current_next_block_consensus")) and
          (if $shadow.status == "spent" then
             $shadow.valuation_status == "recorded_at_spend"
           else $shadow.valuation_status == "current_next_block_consensus" end) and
          ($shadow.vout | uint32) and ($shadow.scriptPubKey | rawhex) and
          ($shadow.address | type) == "string" and ($shadow.address | length) > 0 and
          ($shadow.confirmations | integer and . > 0) and
          ($shadow.base_anchor | type) == "object" and
          ($shadow.base_anchor | keys | sort) == ["blockhash","claim_index","height","time"] and
          $shadow.base_anchor.blockhash == $record.blockhash and
          ($shadow.base_anchor.height | integer and . >= 0) and
          ($shadow.base_anchor.time | integer and . > 0) and
          ($shadow.base_anchor.claim_index | uint) and
          exact_pow_claim_source($shadow.pow_claim_source;$shadow.base_anchor.height) and
          ($shadow.lifecycle | type) == "object" and
          ($shadow.lifecycle | keys | sort) == ["coinbase_maturity",
            "consensus_spendable_next_block","earliest_spend_height",
            "earliest_spend_height_exact","earliest_spend_mtp",
            "gold_rush_phase_locked","mature","maturity_height",
            "ordinary_spendable_next_block","permanently_locked",
            "spendable_next_block"] and
          ($shadow.lifecycle.coinbase_maturity | integer and . > 0) and
          ($shadow.lifecycle.gold_rush_phase_locked | type) == "boolean" and
          ($shadow.lifecycle.earliest_spend_height_exact | type) == "boolean" and
          ($shadow.lifecycle.consensus_spendable_next_block | type) == "boolean" and
          ($shadow.lifecycle.ordinary_spendable_next_block | type) == "boolean" and
          ($shadow.lifecycle.spendable_next_block | type) == "boolean" and
          ($shadow.lifecycle.permanently_locked | type) == "boolean" and
          ($shadow.lifecycle.maturity_height == null or
            ($shadow.lifecycle.maturity_height | integer and . >= 0)) and
          ($shadow.lifecycle.mature == null or
            ($shadow.lifecycle.mature | type) == "boolean") and
          ($shadow.lifecycle.earliest_spend_height == null or
            ($shadow.lifecycle.earliest_spend_height | integer and . >= 0)) and
          ($shadow.lifecycle.earliest_spend_mtp == null or
            ($shadow.lifecycle.earliest_spend_mtp | integer and . >= 0)) and
          ($shadow.demurrage | type) == "object" and
          (($shadow.demurrage | keys | sort) == ["active","exempt","inactive_blocks",
             "locked","remaining_ppm","valuation_height"] or
           ($shadow.demurrage | keys | sort) == ["active","classification","exempt",
             "inactive_blocks","locked","remaining_ppm","valuation_height"]) and
          ($shadow.demurrage.valuation_height | integer and . >= 0) and
          ($shadow.demurrage.active | type) == "boolean" and
          ($shadow.demurrage.exempt | type) == "boolean" and
          ($shadow.demurrage.locked | type) == "boolean" and
          ($shadow.demurrage.inactive_blocks | uint) and
          ($shadow.demurrage.remaining_ppm | uint) and
          ($shadow.demurrage.classification? == null or
            ($shadow.demurrage.classification | type) == "string") and
          $shadow.units == {display:"BLK",atomic_decimals:8,
            amount_encoding:
              "JSON number in BLK; atomic integer amounts are exact internally"} and
          (if $shadow.status == "spent" then
             ($shadow.spend | type) == "object" and
             ($shadow.spend | keys | sort) ==
               ["blockhash","height","input_index","tx_index","txid"] and
             ($shadow.spend.height | integer and
               . > $shadow.base_anchor.height) and
             ($shadow.spend.blockhash | nonzero_hex64) and
             ($shadow.spend.txid | nonzero_hex64) and
             ($shadow.spend.tx_index | uint) and ($shadow.spend.input_index | uint)
           else $shadow.spend == null end);
        def payout_credit($row;$shadow;$record;$wallet_row):
          (if $wallet_row then
             $row.txid == $record.txid and
             $row.qq_synthetic_goldrush_payout == "1" and
             $row.generated == true and
             $row.confirmations == $shadow.confirmations and
             $row.blockhash == $record.blockhash
           else ($row.txid? == null or $row.txid == $record.txid) end) and
          ($row.qq_synthetic_goldrush_payout_stale? == null) and
          ($row.category | IN("generate","immature")) and
          ($row.amount | type) == "number" and $row.amount > 0 and
          $row.abandoned == false and ($row.fee? == null) and
          ($row.address | type) == "string" and $row.address == $shadow.address and
          ($row.vout | uint32) and $row.vout == $shadow.vout and
          ($row.qq_shadow_pow_cleanup_for? == null) and
          ($row.qq_shadow_pow_resolution_schema? == null);
        def authenticated_payout($record):
          ($record.getshadowtransaction_response) as $shadow |
          ($record.gettransaction_response) as $tx |
          ($record.source_claim_txid | nonzero_hex64) and
          $record.source_claim_txid != $record.txid and
          exact_shadow_payout($shadow;$record) and
          $shadow.pow_claim_source.txid == $record.source_claim_txid and
          active_block_member($record;$record.source_claim_txid) and
          $record.getblock_response.height == $shadow.base_anchor.height and
          $record.getblock_response.confirmations == $shadow.confirmations and
          ($tx | type) == "object" and $tx.txid == $record.txid and
          ($tx.hex | rawhex) and ($tx.decoded | type) == "object" and
          $tx.decoded.txid == $record.txid and ($tx.fee? == null) and
          ($tx.amount | type) == "number" and $tx.amount > 0 and
          $tx.confirmations == $shadow.confirmations and
          $tx.blockhash == $record.blockhash and
          ($tx.details | type) == "array" and ($tx.details | length) >= 1 and
          all($tx.details[]; payout_credit(.;$shadow;$record;false)) and
          all($record.wallet_rows[]; payout_credit(.;$shadow;$record;true)) and
          ($tx.decoded.vout | type) == "array" and
          ([$tx.decoded.vout[] |
             select((.n | uint32) and .n == $shadow.vout and
               .scriptPubKey.hex == $shadow.scriptPubKey and
               ((.scriptPubKey.address? == $shadow.address) or
                (.scriptPubKey.addresses? == [$shadow.address])))] | length) == 1;
        . as $raw |
        type == "object" and
        (keys | sort) == ["baseline_recovery_sha256",
          "baseline_wallet_transactions_sha256","complete",
          "final_wallet_transactions_sha256","phase_b_progress_sha256","records",
          "recovery_inventory_sha256","recovery_unanchored_claim_txids","schema"] and
        .schema == 4 and .complete == true and
        (.baseline_wallet_transactions_sha256 | hex64 and matches($baseline)) and
        (.final_wallet_transactions_sha256 | hex64 and matches($final)) and
        (.recovery_inventory_sha256 | hex64 and matches($recovery)) and
        (.baseline_recovery_sha256 | hex64 and matches($baseline_recovery)) and
        (.phase_b_progress_sha256 | hex64 and matches($progress)) and
        (.recovery_unanchored_claim_txids | type == "array" and
          all(.[]; hex64) and (unique | length) == length) and
        (.records | type == "array") and
        ([.records[].txid] | unique | length) == (.records | length) and
        all(.records[]; . as $record |
          (keys | sort) == ["blockhash","class","getblock_response",
            "getblockhash_response","getshadowtransaction_response",
            "gettransaction_response","prior_recovery_authority","recovery_matches",
            "source_claim_txid","txid","wallet_rows"] and
          (.txid | hex64) and (.wallet_rows | type == "array" and length >= 1) and
          all(.wallet_rows[]; type == "object" and .txid == $record.txid) and
          (.recovery_matches | type == "array") and
          all(.recovery_matches[]; component_node_match(.)) and
          prior_authorities(.prior_recovery_authority) and
          (.gettransaction_response | type) == "object" and
          .gettransaction_response.txid == .txid and
          (.gettransaction_response.hex | type) == "string" and
          (.gettransaction_response.hex | test("^[0-9a-f]+$")) and
          ((.gettransaction_response.hex | length) % 2) == 0 and
          if .class == "authenticated_qq_claim" then
            authenticated_claim($record)
          elif .class == "confirmed_coinstake" then
            confirmed_coinstake($record)
          elif .class == "authenticated_qq_claim_payout" then
            authenticated_payout($record)
          elif .class == "external_receive" then
            external_receive($record;$raw.recovery_unanchored_claim_txids)
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
          "-autostartstaking=1","-powmining=1","-powminingthreads=1",
          "-powminingcpu=1"] and
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
    local wallet_delta_raw_file="${4:-}" locked_sync_file="${5:-}"
    local locked_resolution_file="${6:-}" final_recovery_file="${7:-}"
    local final_resolution_file="${8:-}" baseline_resolution_file="${9:-}"
    local baseline_resolution_raw_file="${10:-}" locked_resolution_raw_file="${11:-}"
    local final_resolution_raw_file="${12:-}" final_payout_file="${13:-}"
    local baseline_quantum_file="${14:-}" final_quantum_file="${15:-}"
    local recovery pow payout goldrush_state mempool
    [[ -f "$file" && ! -L "$file" && "$pow_mode" == active ]] ||
        return 1
    jq -e --arg mode "$pow_mode" '
        def integer: type == "number" and floor == .;
        def hex64: type == "string" and test("^[0-9a-f]{64}$");
        type == "object" and
        (keys | sort) == (["chain","chain_after","chain_before_after_identical",
          "chain_recovery_pow_tip_bound","automatic_recovery_unauthorized",
          "baseline_wallet_resolution_raw_sha256",
          "baseline_wallet_resolution_txids_sha256",
          "baseline_quantum_labels_sha256","baseline_quantum_sha256",
          "candidate_configured_payout_transition_valid",
          "candidate_final_goldrush_state_sha256","candidate_final_recovery_sha256",
          "candidate_final_resolution_txids_sha256",
          "candidate_final_resolution_raw_sha256",
          "candidate_final_payout_address_sha256",
          "candidate_final_quantum_labels_sha256","candidate_final_quantum_sha256",
          "candidate_locked_resolution_raw_sha256","candidate_locked_resolution_txids_sha256",
          "candidate_locked_sync_sha256","candidate_resolution_membership_baseline_bound",
          "candidate_quantum_inventory_transition_valid",
          "exact_loaded_wallets","goldrush_state",
          "legacy_baseline_wallet_txids_preserved","loaded_wallets","mempool_verbose","network",
          "no_new_fee_bearing_recovery_wallet_transaction","observed_epoch","pow","pow_mode",
          "recovery","schema","stable_tip","staking","wallet","wallet_delta_fully_classified",
          "wallet_delta_raw_sha256","wallet_delta_sha256","wallet_unlock_current"] | sort) and
        .schema == 2 and .pow_mode == $mode and
        (.observed_epoch | integer and . > 0) and (.stable_tip | hex64) and
        .chain_before_after_identical == true and .chain_recovery_pow_tip_bound == true and
        .wallet_unlock_current == true and
        .exact_loaded_wallets == [.wallet.walletname] and
        .loaded_wallets == [.wallet.walletname] and
        .automatic_recovery_unauthorized == true and
        .candidate_configured_payout_transition_valid == true and
        .candidate_quantum_inventory_transition_valid == true and
        .candidate_resolution_membership_baseline_bound == true and
        .legacy_baseline_wallet_txids_preserved == true and
        .no_new_fee_bearing_recovery_wallet_transaction == true and
        (.candidate_locked_sync_sha256 | hex64) and
        (.baseline_wallet_resolution_txids_sha256 | hex64) and
        (.baseline_wallet_resolution_raw_sha256 | hex64) and
        (.baseline_quantum_sha256 | hex64) and
        (.candidate_final_quantum_sha256 | hex64) and
        (.baseline_quantum_labels_sha256 | hex64) and
        (.candidate_final_quantum_labels_sha256 | hex64) and
        (.candidate_locked_resolution_txids_sha256 | hex64) and
        (.candidate_locked_resolution_raw_sha256 | hex64) and
        (.candidate_final_goldrush_state_sha256 | hex64) and
        (.candidate_final_recovery_sha256 | hex64) and
        (.candidate_final_payout_address_sha256 | hex64) and
        (.candidate_final_resolution_txids_sha256 | hex64) and
        (.candidate_final_resolution_raw_sha256 | hex64) and
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
        (.wallet.walletname | type) == "string" and
        .wallet.private_keys_enabled == true and
        .wallet.scanning == false and .wallet.unlocked_staking_only == false and
        (.wallet.unlocked_until | integer) and .wallet.unlocked_until > .observed_epoch and
        .recovery.active_tip == .stable_tip and .recovery.wallet_processed_tip == .stable_tip and
        .pow.claim_inventory_tip == .stable_tip and
        .staking.blocks == .chain.blocks and .staking.active_blocks == .chain.blocks and
        .staking.autostart_staking == true and
        .staking.autostart_staking_source == "autostartstaking" and
        .pow.autostart == true and
        .pow.claim_recovery_database_outcome_ambiguous == .recovery.database_outcome_ambiguous
    ' "$file" >/dev/null || return 1
    recovery=$(jq -ce '.recovery' "$file") || return 1
    pow=$(jq -ce '.pow' "$file") || return 1
    goldrush_state=$(jq -ce '.goldrush_state' "$file") || return 1
    mempool=$(jq -ce '.mempool_verbose' "$file") || return 1
    hotfix_goldrush_state_json_is_valid "$goldrush_state" \
        "$(jq -er '.stable_tip' "$file")" "$(jq -er '.chain.blocks' "$file")" || return 1
    hotfix_candidate_recovery_json_is_valid "$recovery" || return 1
    hotfix_phase_b_staking_json_is_active "$(jq -ce '.staking' "$file")" || return 1
    hotfix_candidate_pow_json_is_valid "$pow" "$pow_mode" || return 1
    hotfix_pow_recovery_same_cut_json_is_valid "$pow" "$recovery" || return 1
    hotfix_pow_observation_json_is_valid "$pow" "$recovery" "$mempool" \
        "$(jq -er '.stable_tip' "$file")" "$(jq -er '.chain.blocks' "$file")" \
        "$(jq -er '.observed_epoch' "$file")" "$goldrush_state" || return 1
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
    if [[ -n "$locked_sync_file" ]]; then
        hotfix_phase_b_locked_sync_file_is_valid "$locked_sync_file" &&
            [[ "$(hotfix_sha256_file "$locked_sync_file")" == \
               "$(jq -er '.candidate_locked_sync_sha256' "$file")" ]] || return 1
    fi
    if [[ -n "$final_recovery_file" ]]; then
        [[ "$(hotfix_sha256_file "$final_recovery_file")" == \
           "$(jq -er '.candidate_final_recovery_sha256' "$file")" ]] &&
            jq -e -n --argjson embedded "$recovery" --slurpfile raw "$final_recovery_file" \
              '$embedded == $raw[0]' >/dev/null || return 1
    fi
    if [[ -n "$locked_resolution_file" && -n "$final_resolution_file" ]]; then
        jq -e 'type == "array" and all(.[]; type == "string" and
          test("^[0-9a-f]{64}$")) and (unique | length) == length' \
          "$locked_resolution_file" "$final_resolution_file" >/dev/null &&
            [[ "$(hotfix_sha256_file "$locked_resolution_file")" == \
               "$(jq -er '.candidate_locked_resolution_txids_sha256' "$file")" ]] &&
            [[ "$(hotfix_sha256_file "$final_resolution_file")" == \
               "$(jq -er '.candidate_final_resolution_txids_sha256' "$file")" ]] || return 1
    fi
    if [[ -n "$baseline_resolution_file" && -n "$baseline_resolution_raw_file" &&
          -n "$locked_resolution_raw_file" && -n "$final_resolution_raw_file" ]]; then
        jq -e -n --slurpfile ids "$baseline_resolution_file" \
            --slurpfile baseline "$baseline_resolution_raw_file" \
            --slurpfile locked_ids "$locked_resolution_file" \
            --slurpfile locked "$locked_resolution_raw_file" \
            --slurpfile final_ids "$final_resolution_file" \
            --slurpfile final "$final_resolution_raw_file" '
          def rows: type=="array" and .==(sort_by(.txid)) and
            ([.[].txid]|unique|length)==length and
            all(.[]; (keys|sort)==["hex","txid"] and
              (.txid|test("^[0-9a-f]{64}$")) and
              (.hex|test("^[0-9a-f]+$")) and ((.hex|length)%2)==0);
          ($ids[0]|type)=="array" and $ids[0]==($ids[0]|sort|unique) and
          ($baseline[0]|rows) and [$baseline[0][].txid]==$ids[0] and
          ($locked[0]|rows) and [$locked[0][].txid]==$locked_ids[0] and
          ($final[0]|rows) and [$final[0][].txid]==$final_ids[0] and
          all(($locked[0]+$final[0])[]; . as $row |
            ([$baseline[0][] | select(.txid==$row.txid and .hex==$row.hex)]|length)==1)
        ' >/dev/null &&
            [[ "$(hotfix_sha256_file "$baseline_resolution_file")" == \
               "$(jq -er '.baseline_wallet_resolution_txids_sha256' "$file")" ]] &&
            [[ "$(hotfix_sha256_file "$baseline_resolution_raw_file")" == \
               "$(jq -er '.baseline_wallet_resolution_raw_sha256' "$file")" ]] &&
            [[ "$(hotfix_sha256_file "$locked_resolution_raw_file")" == \
               "$(jq -er '.candidate_locked_resolution_raw_sha256' "$file")" ]] &&
            [[ "$(hotfix_sha256_file "$final_resolution_raw_file")" == \
               "$(jq -er '.candidate_final_resolution_raw_sha256' "$file")" ]] || return 1
    fi
    if [[ -n "$final_payout_file" ]]; then
        [[ "$(hotfix_sha256_file "$final_payout_file")" == \
           "$(jq -er '.candidate_final_payout_address_sha256' "$file")" ]] || return 1
        payout=$(jq -er '.pow.payout_address | select(type=="string")' "$file") || return 1
        if [[ -n "$payout" ]]; then
            [[ -n "$baseline_quantum_file" && -n "$final_quantum_file" ]] || return 1
            hotfix_quantum_payout_address_is_valid \
                "$final_payout_file" "$baseline_quantum_file" "$payout" || return 1
            hotfix_quantum_payout_address_is_valid \
                "$final_payout_file" "$final_quantum_file" "$payout" || return 1
        else
            jq -e '. == null' "$final_payout_file" >/dev/null || return 1
        fi
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
        type == "object" and
        (keys | sort) == (["automatic_recovery_unauthorized_continuously",
          "baseline_health_gate_passed","baseline_precondition_sha256",
          "baseline_cutover_stop_sha256","candidate_final_recovery_sha256",
          "candidate_final_resolution_txids_sha256","candidate_locked_resolution_txids_sha256",
          "candidate_locked_sync_sha256","candidate_resolution_membership_baseline_bound",
          "candidate_running","candidate_source_sha","core_native_pos_intent_configured",
          "core_native_pow_intent_configured",
          "data_rewind_performed","datasets_preserved","failure_policy",
          "final_container_identity_stable","final_container_sha256","final_envelope_sha256",
          "invocation_sha256","live_dataset_identity_sha256","marker_sha256","node",
          "locked_pos_zero_work_observed","locked_pow_zero_work_observed",
          "normal_unlock_completed","normal_unlock_only_resume_observed","old_core_autostarted",
          "only_allowed_wallet_delta_classes_added","p2p_ready","package_sha256sums_sha256",
          "phase","phase_a_result_sha256","phase_b_progress_sha256",
          "phase_b_script_sha256","phase_b_tooling_identity_sha256","pos_active",
          "pre_result_manifest_sha256","repair_enable_rpcs_used",
          "promoted_no_rewind_marker_verified","quantum_keys_unchanged",
          "no_new_fee_bearing_recovery_wallet_transaction","result","schema",
          "snapshots_absent_before_launch",
          "storage_absence_recheck_sha256","tooling_commit","typed_contract_sha256",
          "typed_gate_safe","verifier_sha256","wallet_chain_synchronized_before_unlock",
          "wallet_delta_fully_classified","wallet_delta_raw_sha256","wallet_delta_sha256",
          "configured_payout_transition_valid"] | sort) and
        (.schema | integer and . == 4) and .phase == "B" and
        (.node | integer and . == 27) and
        .result == "passed" and .candidate_source_sha == $source and
        .phase_a_result_sha256 == $result_sha and
        ($result_sha | test("^[0-9a-f]{64}$")) and
        .promoted_no_rewind_marker_verified == true and
        .snapshots_absent_before_launch == true and .datasets_preserved == true and
        .candidate_running == true and .wallet_chain_synchronized_before_unlock == true and
        .normal_unlock_completed == true and .core_native_pos_intent_configured == true and
        .core_native_pow_intent_configured == true and
        .locked_pos_zero_work_observed == true and .locked_pow_zero_work_observed == true and
        .normal_unlock_only_resume_observed == true and .repair_enable_rpcs_used == false and
        .pos_active == true and
        .p2p_ready == true and .typed_gate_safe == true and
        .configured_payout_transition_valid == true and .quantum_keys_unchanged == true and
        .automatic_recovery_unauthorized_continuously == true and
        .candidate_resolution_membership_baseline_bound == true and
        .no_new_fee_bearing_recovery_wallet_transaction == true and
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
        (.candidate_locked_sync_sha256 | hex64) and
        (.candidate_locked_resolution_txids_sha256 | hex64) and
        (.candidate_final_recovery_sha256 | hex64) and
        (.candidate_final_resolution_txids_sha256 | hex64)
    ' "$file" >/dev/null
}
