# shellcheck shell=bash
# Pure predicates for the offline v30.1.5 deployment/rollback-readiness stage.

export LC_ALL=C

readonly V3015_DR_DURABILITY_BASE='2af2621d318a18365da9f9da0d5510dfbe6ee722'
readonly V3015_DR_NODE30_PRESEAL='d1d1aa335f8ede310ac24fb1557700a5c2ca7c4a'
readonly V3015_DR_SIGNING_FINGERPRINT='SHA256:jAkpBudDw+ntWHSUx3e1KY+czAFjnlaPxQtRFtptL70'

v3015_dr_sha256_text()
{
    printf '%s' "$1" | sha256sum | awk '{print $1}'
}

v3015_dr_file_is_safe()
{
    local file=$1
    if [[ "${V3015_DR_FIXTURE:-0}" == 1 ]]; then
        [[ -f "$file" && ! -L "$file" ]]
    else
        v3015_secure_regular_file "$file" 600 && v3015_secure_ancestry "$file"
    fi
}

v3015_dr_validate_common_env()
{
    local name
    for name in DR_SOURCE_SHA DR_SOURCE_TREE DR_MERGE_SHA DR_MERGE_TREE \
        DR_FLEET_INTEGRATION_COMMIT DR_FLEET_INTEGRATION_TREE; do
        v3015_is_git_sha "${!name:-}" ||
            v3015_die "$name must be an exact full Git identity" || return
    done
    [[ "$DR_MERGE_TREE" == "$DR_SOURCE_TREE" ]] ||
        v3015_die 'candidate merge tree must equal the signed source tree' || return
    [[ "$DR_FLEET_INTEGRATION_COMMIT" != "$V3015_DR_DURABILITY_BASE" &&
       "$DR_FLEET_INTEGRATION_COMMIT" != "$V3015_DR_NODE30_PRESEAL" ]] ||
        v3015_die 'a predecessor semantic/preseal commit is not fleet integration' || return

    v3015_is_candidate_image_ref "${DR_CANDIDATE_IMAGE_REF:-}" ||
        v3015_die 'candidate image must be the canonical immutable digest reference' || return
    v3015_is_image_id "${DR_CANDIDATE_IMAGE_ID:-}" ||
        v3015_die 'candidate image configuration identity is invalid' || return
    [[ "${DR_CANDIDATE_IMAGE_REF##*@sha256:}" == \
       "${DR_CANDIDATE_OCI_MANIFEST_SHA256:-}" ]] ||
        v3015_die 'candidate image reference and OCI manifest are not cross-bound' || return
    v3015_require_resolved DR_INSTALLED_V3014_IMAGE_REF \
      "${DR_INSTALLED_V3014_IMAGE_REF:-}" || return
    v3015_is_image_id "${DR_INSTALLED_V3014_IMAGE_ID:-}" ||
        v3015_die 'installed v30.1.4 image configuration identity is invalid' || return

    for name in DR_CANDIDATE_OCI_MANIFEST_SHA256 DR_CANDIDATE_BUNDLE_SHA256 \
        DR_CANDIDATE_OCI_ARCHIVE_SHA256 DR_CANDIDATE_BLACKCOIND_SHA256 \
        DR_CANDIDATE_BLACKCOIN_CLI_SHA256 DR_CANDIDATE_BLACKCOIN_QT_SHA256 \
        DR_CANDIDATE_BLACKCOIN_TX_SHA256 DR_CANDIDATE_BLACKCOIN_WALLET_SHA256 \
        DR_CANDIDATE_BLACKCOIN_UTIL_SHA256 DR_INSTALLED_V3014_BLACKCOIND_SHA256 \
        DR_INSTALLED_V3014_BLACKCOIN_CLI_SHA256 DR_INSTALLED_V3014_BLACKCOIN_QT_SHA256 \
        DR_INSTALLED_V3014_BLACKCOIN_TX_SHA256 DR_INSTALLED_V3014_BLACKCOIN_WALLET_SHA256 \
        DR_INSTALLED_V3014_BLACKCOIN_UTIL_SHA256 DR_PUBLIC_ARTIFACT_RECEIPT_SHA256 \
        DR_FLEET_INTEGRATION_RECEIPT_SHA256 DR_NODE30_ONE_SHOT_RECEIPT_SHA256 \
        DR_NODE27_RELAY_RECEIPT_SHA256 DR_POS_RENEWAL_RECEIPT_SHA256 \
        DR_ROLLBACK_PLAN_RECEIPT_SHA256 \
        DR_TOPOLOGY_SHA256 DR_WAVES_SHA256 DR_BEFORE_INDEX_SHA256 \
        DR_PACKAGE_SHA256SUMS_SHA256; do
        v3015_is_sha256 "${!name:-}" ||
            v3015_die "$name must be exact lowercase SHA-256" || return
    done

    for name in DR_PUBLIC_ARTIFACT_RECEIPT DR_FLEET_INTEGRATION_RECEIPT \
        DR_NODE30_ONE_SHOT_RECEIPT DR_NODE27_RELAY_RECEIPT DR_POS_RENEWAL_RECEIPT \
        DR_ROLLBACK_PLAN_RECEIPT DR_TOPOLOGY_MAP DR_WAVES_PLAN DR_BEFORE_INDEX; do
        v3015_require_resolved "$name" "${!name:-}" || return
        [[ "${!name}" == /* ]] || v3015_die "$name must be an absolute reviewed path" || return
    done
    [[ "${DR_MIN_PEERS:-}" =~ ^[1-9][0-9]*$ ]] ||
        v3015_die 'DR_MIN_PEERS is unresolved' || return
    ((DR_MIN_PEERS >= 1 && DR_MIN_PEERS <= 10000)) ||
        v3015_die 'DR_MIN_PEERS is outside the reviewed range' || return
}

v3015_dr_binary_json()
{
    local prefix=$1
    if [[ "$prefix" == candidate ]]; then
        jq -cn --arg d "$DR_CANDIDATE_BLACKCOIND_SHA256" \
          --arg c "$DR_CANDIDATE_BLACKCOIN_CLI_SHA256" \
          --arg q "$DR_CANDIDATE_BLACKCOIN_QT_SHA256" \
          --arg t "$DR_CANDIDATE_BLACKCOIN_TX_SHA256" \
          --arg w "$DR_CANDIDATE_BLACKCOIN_WALLET_SHA256" \
          --arg u "$DR_CANDIDATE_BLACKCOIN_UTIL_SHA256" \
          '{blackcoind:$d,"blackcoin-cli":$c,"blackcoin-qt":$q,
            "blackcoin-tx":$t,"blackcoin-wallet":$w,"blackcoin-util":$u}'
    else
        jq -cn --arg d "$DR_INSTALLED_V3014_BLACKCOIND_SHA256" \
          --arg c "$DR_INSTALLED_V3014_BLACKCOIN_CLI_SHA256" \
          --arg q "$DR_INSTALLED_V3014_BLACKCOIN_QT_SHA256" \
          --arg t "$DR_INSTALLED_V3014_BLACKCOIN_TX_SHA256" \
          --arg w "$DR_INSTALLED_V3014_BLACKCOIN_WALLET_SHA256" \
          --arg u "$DR_INSTALLED_V3014_BLACKCOIN_UTIL_SHA256" \
          '{blackcoind:$d,"blackcoin-cli":$c,"blackcoin-qt":$q,
            "blackcoin-tx":$t,"blackcoin-wallet":$w,"blackcoin-util":$u}'
    fi
}

v3015_dr_topology_and_waves_are_valid()
{
    local topology=$1 waves=$2
    [[ "$(v3015_sha256_file "$topology")" == "$DR_TOPOLOGY_SHA256" &&
       "$(v3015_sha256_file "$waves")" == "$DR_WAVES_SHA256" ]] || return 1
    v3015_validate_topology_map "$topology" || return
    [[ "$(v3015_topology_lookup "$topology" 30)" == $'node30\tblackcoin-v4-gui-30' ]] || return
    awk '
      BEGIN { row=0; regular=0; free_claim=0 }
      /^$/ || /^#/ { next }
      {
        row++
        if ($1 != "regular" && $1 != "free_claim") exit 1
        width=NF-1
        if (width < 1 || width > 4) exit 1
        if (row == 1 && !($1 == "regular" && NF == 2 && $2 == 27)) exit 1
        if (row == 2 && !($1 == "regular" && NF == 2 && $2 == 16)) exit 1
        for (i=2; i<=NF; i++) {
          if ($i !~ /^[0-9]+$/ || $i < 1 || $i > 32 || seen[$i]++) exit 1
          if ($1 == "free_claim") { if ($i != 30) exit 1; free_claim++ }
          else { if ($i == 30) exit 1; regular++ }
        }
        last_role=$1; last_node=$2; last_nf=NF
      }
      END {
        if (row != 11 || regular != 31 || free_claim != 1) exit 1
        if (last_role != "free_claim" || last_nf != 2 || last_node != 30) exit 1
        for (i=1; i<=32; i++) if (seen[i] != 1) exit 1
      }
    ' "$waves"
}

v3015_dr_wave_count()
{
    awk '!/^#/ && NF {count++} END {print count+0}' "$DR_WAVES_PLAN"
}

v3015_dr_wave_role()
{
    local index=$1
    awk -v wanted="$index" '!/^#/ && NF {row++; if (row==wanted) {print $1; found=1}}
      END {if (!found) exit 1}' "$DR_WAVES_PLAN"
}

v3015_dr_wave_nodes_json()
{
    local index=$1
    awk -v wanted="$index" '!/^#/ && NF {
      row++; if (row==wanted) {for (i=2; i<=NF; i++) print $i; found=1}}
      END {if (!found) exit 1}' "$DR_WAVES_PLAN" | jq -Rsc \
      'split("\n")[:-1] | map(tonumber)'
}

v3015_dr_public_artifact_is_valid()
{
    local file=$1 image_manifest
    image_manifest=${DR_CANDIDATE_IMAGE_REF##*@sha256:}
    jq -e --arg source "$DR_SOURCE_SHA" --arg tree "$DR_SOURCE_TREE" \
      --arg merge "$DR_MERGE_SHA" --arg merge_tree "$DR_MERGE_TREE" \
      --arg fingerprint "$V3015_DR_SIGNING_FINGERPRINT" \
      --arg image "$DR_CANDIDATE_IMAGE_REF" --arg image_id "$DR_CANDIDATE_IMAGE_ID" \
      --arg manifest "$DR_CANDIDATE_OCI_MANIFEST_SHA256" \
      --arg image_manifest "$image_manifest" --arg bundle "$DR_CANDIDATE_BUNDLE_SHA256" \
      --arg archive "$DR_CANDIDATE_OCI_ARCHIVE_SHA256" \
      --argjson binaries "$(v3015_dr_binary_json candidate)" '
        def hex64: type == "string" and test("^[0-9a-f]{64}$");
        def git40: type == "string" and test("^[0-9a-f]{40}$");
        def utc: type == "string" and
          test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
        def keys_expected: ["artifact","binary_sha256s","candidate_bundle_sha256",
          "candidate_image_id","candidate_image_ref","candidate_oci_archive_sha256",
          "candidate_oci_manifest_sha256","ci","completed_utc","kind","merge_commit",
          "merge_signature_verified","merge_tree","public_artifact_complete",
          "registry_digest_verified","release","schema","source_sha",
          "source_signature_verified","source_signing_fingerprint","source_tree"];
        type == "object" and (keys|sort)==(keys_expected|sort) and .schema==1 and
        .kind=="v30.1.5-public-artifact-completion" and .release=="v30.1.5" and
        .source_sha==$source and .source_tree==$tree and
        .source_signature_verified==true and .source_signing_fingerprint==$fingerprint and
        .merge_commit==$merge and .merge_tree==$merge_tree and .merge_tree==$tree and
        .merge_signature_verified==true and
        (.ci|keys|sort)==(["conclusion","head_sha","required_green","run_id",
          "total_required","workflow"]|sort) and
        .ci.head_sha==$source and .ci.conclusion=="success" and
        (.ci.run_id|type=="number" and floor==. and .>0) and
        .ci.required_green==.ci.total_required and .ci.total_required>=16 and
        (.ci.workflow|type=="string" and length>0) and
        (.artifact|keys|sort)==(["api_sha256","name","run_attempt","run_id"]|sort) and
        (.artifact.name|type=="string" and length>0) and
        (.artifact.run_id|type=="number" and floor==. and .>0) and
        (.artifact.run_attempt|type=="number" and floor==. and .>0) and
        (.artifact.api_sha256|hex64) and
        .candidate_image_ref==$image and .candidate_image_id==$image_id and
        .candidate_oci_manifest_sha256==$manifest and
        .candidate_oci_manifest_sha256==$image_manifest and
        .candidate_bundle_sha256==$bundle and .candidate_oci_archive_sha256==$archive and
        .binary_sha256s==$binaries and .registry_digest_verified==true and
        .public_artifact_complete==true and (.completed_utc|utc) and
        (.source_sha|git40) and (.source_tree|git40) and (.merge_commit|git40) and
        all([.candidate_bundle_sha256,.candidate_oci_archive_sha256,
          .candidate_oci_manifest_sha256,.binary_sha256s[]][]; hex64)
      ' "$file" >/dev/null
}

v3015_dr_node30_one_shot_is_valid()
{
    local file=$1 public_sha
    public_sha=$(v3015_sha256_file "$DR_PUBLIC_ARTIFACT_RECEIPT") || return
    jq -e --arg source "$DR_SOURCE_SHA" --arg public "$public_sha" '
      def hex64: type=="string" and test("^[0-9a-f]{64}$");
      def keys_expected: ["authority_binds_audit_sha","authority_binds_fee_caps",
        "authority_binds_fee_outpoint","authority_binds_height","authority_binds_payout",
        "authority_binds_queue","authority_binds_tip","authority_binds_wallet_generation",
        "authority_binds_wallet_identity","authority_binds_work","broadcast_count_exactly_one",
        "external_recurring_worker_authoritative","fee_cap_enforced","kind",
        "new_key_authorized","node","ordinary_pow_required",
        "ordinary_pow_stays_disabled","product_test_receipt_sha256",
        "public_artifact_receipt_sha256","queue_result_binds_raw_hash_and_txid",
        "queue_result_binds_witness_v16_payout","recovery_authorized","release",
        "repauses_before_lock_release","schema","single_submission_only","source_sha",
        "two_phase_audit_authority_release","worker_mode","worker_sha256"];
      type=="object" and (keys|sort)==(keys_expected|sort) and .schema==1 and
      .kind=="v30.1.5-node30-one-shot-release-product" and .release=="v30.1.5" and
      .source_sha==$source and .public_artifact_receipt_sha256==$public and .node==30 and
      .two_phase_audit_authority_release==true and .authority_binds_audit_sha==true and
      .authority_binds_tip==true and .authority_binds_height==true and
      .authority_binds_wallet_identity==true and .authority_binds_wallet_generation==true and
      .authority_binds_fee_outpoint==true and .authority_binds_work==true and
      .authority_binds_queue==true and .authority_binds_payout==true and
      .authority_binds_fee_caps==true and .worker_mode=="one-shot" and
      .external_recurring_worker_authoritative==false and .single_submission_only==true and
      .broadcast_count_exactly_one==true and .fee_cap_enforced==true and
      .queue_result_binds_raw_hash_and_txid==true and
      .queue_result_binds_witness_v16_payout==true and
      .repauses_before_lock_release==true and .ordinary_pow_required==false and
      .ordinary_pow_stays_disabled==true and .recovery_authorized==false and
      .new_key_authorized==false and (.worker_sha256|hex64) and
      (.product_test_receipt_sha256|hex64)
    ' "$file" >/dev/null
}

v3015_dr_node27_relay_is_valid()
{
    local file=$1 public_sha
    public_sha=$(v3015_sha256_file "$DR_PUBLIC_ARTIFACT_RECEIPT") || return
    jq -e --arg source "$DR_SOURCE_SHA" --arg public "$public_sha" '
      def hex64: type=="string" and test("^[0-9a-f]{64}$");
      def keys_expected: ["active_tip_bound","commit_result_binds_acknowledged_plan",
        "component_fingerprint_bound","current_recovery_rechecked","height_bound","kind",
        "node","plan_id_bound","product_test_receipt_sha256",
        "public_artifact_receipt_sha256","raw_hash_bound","release","schema",
        "source_sha","stable_chain_bracket","testmempoolaccept_bound","txid_bound",
        "wallet_generation_bound","wallet_processed_tip_bound"];
      type=="object" and (keys|sort)==(keys_expected|sort) and .schema==1 and
      .kind=="v30.1.5-node27-relay-product" and .release=="v30.1.5" and
      .source_sha==$source and .public_artifact_receipt_sha256==$public and .node==27 and
      .stable_chain_bracket==true and .active_tip_bound==true and .height_bound==true and
      .wallet_generation_bound==true and .wallet_processed_tip_bound==true and
      .component_fingerprint_bound==true and .plan_id_bound==true and .txid_bound==true and
      .raw_hash_bound==true and .testmempoolaccept_bound==true and
      .current_recovery_rechecked==true and
      .commit_result_binds_acknowledged_plan==true and (.product_test_receipt_sha256|hex64)
    ' "$file" >/dev/null
}

v3015_dr_pos_renewal_is_valid()
{
    local file=$1
    jq -e --arg integration "$DR_FLEET_INTEGRATION_COMMIT" '
      def hex64: type=="string" and test("^[0-9a-f]{64}$");
      type=="object" and (keys|sort)==(["fleet_integration_commit",
        "hostile_test_receipt_sha256","kind","lock_paths","normal_unlock_only",
        "node30_release_lock_included","ordinary_pow_mutation_forbidden","schema",
        "unlock_during_cutover_forbidden","wallet_transaction_forbidden"]|sort) and
      .schema==1 and .kind=="v30.1.5-pos-renewal-lock-contract" and
      .fleet_integration_commit==$integration and
      .lock_paths==["/var/run/blackcoin-v3015-rollout.lock",
        "/run/blackcoin-endpoint-guard.lock",
        "/var/run/blackcoin-wallet-runtime-guard.lock",
        "/var/run/blackcoin-free-claim-pause-transition.lock"] and
      .normal_unlock_only==true and .unlock_during_cutover_forbidden==true and
      .node30_release_lock_included==true and .ordinary_pow_mutation_forbidden==true and
      .wallet_transaction_forbidden==true and (.hostile_test_receipt_sha256|hex64)
    ' "$file" >/dev/null
}

v3015_dr_integration_is_valid()
{
    local file=$1 contract_sha=$2 tool_sha=$3 public_sha node30_sha node27_sha renewal_sha
    public_sha=$(v3015_sha256_file "$DR_PUBLIC_ARTIFACT_RECEIPT") || return
    node30_sha=$(v3015_sha256_file "$DR_NODE30_ONE_SHOT_RECEIPT") || return
    node27_sha=$(v3015_sha256_file "$DR_NODE27_RELAY_RECEIPT") || return
    renewal_sha=$(v3015_sha256_file "$DR_POS_RENEWAL_RECEIPT") || return
    jq -e --arg commit "$DR_FLEET_INTEGRATION_COMMIT" \
      --arg tree "$DR_FLEET_INTEGRATION_TREE" --arg base "$V3015_DR_DURABILITY_BASE" \
      --arg node30_preseal "$V3015_DR_NODE30_PRESEAL" \
      --arg fingerprint "$V3015_DR_SIGNING_FINGERPRINT" --arg public "$public_sha" \
      --arg package "$DR_PACKAGE_SHA256SUMS_SHA256" --arg topology "$DR_TOPOLOGY_SHA256" \
      --arg waves "$DR_WAVES_SHA256" --arg contract "$contract_sha" --arg tool "$tool_sha" \
      --arg node30 "$node30_sha" --arg node27 "$node27_sha" --arg renewal "$renewal_sha" '
      def hex64: type=="string" and test("^[0-9a-f]{64}$");
      def git40: type=="string" and test("^[0-9a-f]{40}$");
      def utc: type=="string" and
        test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
      def keys_expected: ["combined_integration","created_utc","deployable_package",
        "deployment_contract_sha256","deployment_tool_sha256",
        "durability_topology_base_commit","fleet_integration_commit",
        "fleet_integration_tree","github_signature_reason","github_signature_verified",
        "hostile_test_receipt_sha256","kind","node27_relay_product_receipt_sha256",
        "node30_one_shot_product_receipt_sha256","node30_semantic_preseal_commit",
        "node30_semantic_preseal_deployable","package_full_suite_receipt_sha256",
        "pos_renewal_lock_receipt_sha256",
        "package_sha256sums_sha256","public_artifact_receipt_sha256","release","schema",
        "signature_verified","signing_fingerprint","topology_sha256","waves_sha256"];
      type=="object" and (keys|sort)==(keys_expected|sort) and .schema==1 and
      .kind=="v30.1.5-signed-fleet-integration" and .release=="v30.1.5" and
      .fleet_integration_commit==$commit and .fleet_integration_tree==$tree and
      .durability_topology_base_commit==$base and
      .node30_semantic_preseal_commit==$node30_preseal and
      .fleet_integration_commit!=$base and .fleet_integration_commit!=$node30_preseal and
      .signature_verified==true and .signing_fingerprint==$fingerprint and
      .github_signature_verified==true and .github_signature_reason=="valid" and
      .public_artifact_receipt_sha256==$public and
      .package_sha256sums_sha256==$package and .topology_sha256==$topology and
      .waves_sha256==$waves and .deployment_contract_sha256==$contract and
      .deployment_tool_sha256==$tool and
      .node30_one_shot_product_receipt_sha256==$node30 and
      .node27_relay_product_receipt_sha256==$node27 and
      .pos_renewal_lock_receipt_sha256==$renewal and
      .node30_semantic_preseal_deployable==false and .combined_integration==true and
      .deployable_package==true and (.package_full_suite_receipt_sha256|hex64) and
      (.hostile_test_receipt_sha256|hex64) and (.created_utc|utc) and
      (.fleet_integration_commit|git40) and (.fleet_integration_tree|git40)
    ' "$file" >/dev/null
}

v3015_dr_rollback_plan_is_valid()
{
    local file=$1 public_sha integration_sha installed_binaries candidate_binaries
    public_sha=$(v3015_sha256_file "$DR_PUBLIC_ARTIFACT_RECEIPT") || return
    integration_sha=$(v3015_sha256_file "$DR_FLEET_INTEGRATION_RECEIPT") || return
    installed_binaries=$(v3015_dr_binary_json installed) || return
    candidate_binaries=$(v3015_dr_binary_json candidate) || return
    jq -e --arg source "$DR_SOURCE_SHA" --arg image "$DR_CANDIDATE_IMAGE_REF" \
      --arg image_id "$DR_CANDIDATE_IMAGE_ID" --arg installed "$DR_INSTALLED_V3014_IMAGE_REF" \
      --arg installed_id "$DR_INSTALLED_V3014_IMAGE_ID" --arg public "$public_sha" \
      --arg integration "$integration_sha" --arg topology "$DR_TOPOLOGY_SHA256" \
      --arg waves "$DR_WAVES_SHA256" --argjson installed_bins "$installed_binaries" \
      --argjson candidate_bins "$candidate_binaries" '
      def keys_expected: ["bootstrap_authorized","candidate_binary_sha256s",
        "candidate_image_id","candidate_image_ref","containment_timeout_seconds",
        "data_rewind_authorized","failed_wave_action","installed_v3014_binary_sha256s",
        "installed_v3014_image_id","installed_v3014_image_ref",
        "installed_v3014_image_retained","kind","maintenance_pause_retained_on_failure",
        "max_inflight_nodes","new_key_authorized","node30_free_claim_stays_paused",
        "node30_ordinary_pow_stays_disabled","package_integration_receipt_sha256",
        "post_candidate_v3014_restart_authorized","prestart_config_restore_only",
        "public_artifact_receipt_sha256","recovery_transaction_authorized",
        "reindex_authorized","release","repair_authorized","schema","source_sha",
        "stop_on_first_failure","topology_sha256","wallet_restore_authorized",
        "waves_sha256"];
      type=="object" and (keys|sort)==(keys_expected|sort) and .schema==1 and
      .kind=="v30.1.5-rollback-containment-plan" and .release=="v30.1.5" and
      .source_sha==$source and .candidate_image_ref==$image and
      .candidate_image_id==$image_id and .candidate_binary_sha256s==$candidate_bins and
      .installed_v3014_image_ref==$installed and .installed_v3014_image_id==$installed_id and
      .installed_v3014_binary_sha256s==$installed_bins and
      .public_artifact_receipt_sha256==$public and
      .package_integration_receipt_sha256==$integration and
      .topology_sha256==$topology and .waves_sha256==$waves and
      .max_inflight_nodes==4 and
      (.containment_timeout_seconds|type=="number" and floor==. and .>=30 and .<=300) and
      .stop_on_first_failure==true and .failed_wave_action=="contain-candidate-preserve-data" and
      .installed_v3014_image_retained==true and .prestart_config_restore_only==true and
      .post_candidate_v3014_restart_authorized==false and .data_rewind_authorized==false and
      .reindex_authorized==false and .repair_authorized==false and
      .wallet_restore_authorized==false and .bootstrap_authorized==false and
      .recovery_transaction_authorized==false and .new_key_authorized==false and
      .maintenance_pause_retained_on_failure==true and
      .node30_ordinary_pow_stays_disabled==true and .node30_free_claim_stays_paused==true
    ' "$file" >/dev/null
}

v3015_dr_before_receipt_is_valid()
{
    local file=$1 expected_node=$2 topology_row service container role binaries
    topology_row=$(v3015_topology_lookup "$DR_TOPOLOGY_MAP" "$expected_node") || return
    IFS=$'\t' read -r service container <<<"$topology_row"
    [[ "$expected_node" == 30 ]] && role=free_claim || role=regular
    binaries=$(v3015_dr_binary_json installed) || return
    jq -e --argjson node "$expected_node" --arg role "$role" --arg service "$service" \
      --arg container "$container" --arg topology "$DR_TOPOLOGY_SHA256" \
      --arg image "$DR_INSTALLED_V3014_IMAGE_REF" --arg image_id "$DR_INSTALLED_V3014_IMAGE_ID" \
      --argjson binaries "$binaries" --argjson min_peers "$DR_MIN_PEERS" '
      def hex64: type=="string" and test("^[0-9a-f]{64}$");
      def integer: type=="number" and floor==.;
      def chain: (keys|sort)==(["bestblockhash","blocks","chain","chainwork","headers",
        "initialblockdownload"]|sort) and .chain=="main" and (.bestblockhash|hex64) and
        (.chainwork|hex64) and (.blocks|integer and .>=0) and
        (.headers|integer) and .headers>=.blocks and .initialblockdownload==false;
      def keys_expected: ["captured_epoch","container_name","core_bracket","intent","kind",
        "network","node","role","runtime","schema","storage","topology_sha256",
        "compose_service","wallet"];
      type=="object" and (keys|sort)==(keys_expected|sort) and .schema==1 and
      .kind=="v30.1.5-node-before-receipt" and .node==$node and .role==$role and
      .compose_service==$service and .container_name==$container and
      .topology_sha256==$topology and (.captured_epoch|integer and .>0) and
      (.core_bracket|keys|sort)==(["after","before"]|sort) and
      (.core_bracket.before|chain) and .core_bracket.after==.core_bracket.before and
      .network=={networkactive:true,connections:.network.connections} and
      (.network.connections|integer and .>=$min_peers) and
      .runtime=={version:300104,subversion:"/Blackcoin:30.1.4/",image_ref:$image,
        image_id:$image_id,binary_sha256s:$binaries,running:true,paused:false,
        restarting:false,dead:false} and
      (.wallet|keys|sort)==(["generation","identity_sha256","loaded_wallets",
        "private_keys_enabled","processed_height","processed_tip","scanning"]|sort) and
      .wallet.loaded_wallets==1 and (.wallet.identity_sha256|hex64) and
      (.wallet.generation|integer and .>=0) and
      .wallet.processed_tip==.core_bracket.after.bestblockhash and
      .wallet.processed_height==.core_bracket.after.blocks and
      .wallet.private_keys_enabled==true and .wallet.scanning==false and
      (.storage|keys|sort)==(["bootstrap_used","candidate_bytes_started",
        "dataset_identity_sha256","installed_v3014_image_retained","reindex_used",
        "repair_used","rewind_used","wallet_replaced",
        "wallet_storage_identity_sha256"]|sort) and
      (.storage.dataset_identity_sha256|hex64) and
      (.storage.wallet_storage_identity_sha256|hex64) and
      .storage.installed_v3014_image_retained==true and
      .storage.candidate_bytes_started==false and .storage.bootstrap_used==false and
      .storage.reindex_used==false and .storage.repair_used==false and
      .storage.rewind_used==false and .storage.wallet_replaced==false and
      (.intent|keys|sort)==(["automatic_quantum_key_creation","automatic_recovery_authorized",
        "free_claim_paused","free_claim_role","ordinary_pow_autostart",
        "ordinary_pow_enabled","pos_enabled"]|sort) and
      .intent.pos_enabled==true and .intent.automatic_recovery_authorized==false and
      .intent.automatic_quantum_key_creation==false and
      (if $node==30 then
         .intent.free_claim_role==true and .intent.free_claim_paused==true and
         .intent.ordinary_pow_enabled==false and .intent.ordinary_pow_autostart==false
       else
         .intent.free_claim_role==false and .intent.free_claim_paused==false and
         .intent.ordinary_pow_enabled==true and .intent.ordinary_pow_autostart==true
       end)
    ' "$file" >/dev/null
}

v3015_dr_before_index_is_valid()
{
    local index=$1 entries entry node path sha count=0 seen=' '
    jq -e --arg topology "$DR_TOPOLOGY_SHA256" '
      def hex64: type=="string" and test("^[0-9a-f]{64}$");
      type=="object" and (keys|sort)==(["capture_id","kind","receipts","schema",
        "topology_sha256"]|sort) and .schema==1 and
      .kind=="v30.1.5-before-receipt-index" and (.capture_id|hex64) and
      .topology_sha256==$topology and (.receipts|type=="array" and length==32) and
      ([.receipts[].node]|sort)==[range(1;33)] and
      all(.receipts[]; (keys|sort)==(["node","path","sha256"]|sort) and
        (.path|type=="string" and startswith("/")) and (.sha256|hex64))
    ' "$index" >/dev/null || return 1
    entries=$(jq -c '.receipts[]' "$index") || return
    while IFS= read -r entry; do
        node=$(jq -er '.node' <<<"$entry") || return
        path=$(jq -er '.path' <<<"$entry") || return
        sha=$(jq -er '.sha256' <<<"$entry") || return
        [[ "$seen" != *" $node "* ]] || return 1
        seen+="$node "
        v3015_dr_file_is_safe "$path" || return
        [[ "$(v3015_sha256_file "$path")" == "$sha" ]] || return 1
        v3015_dr_before_receipt_is_valid "$path" "$node" || return
        count=$((count+1))
    done <<<"$entries"
    [[ "$count" == 32 ]]
}

v3015_dr_before_entry()
{
    local index=$1 node=$2
    jq -cer --argjson node "$node" '.receipts[]|select(.node==$node)' "$index"
}

v3015_dr_authority_inputs_are_valid()
{
    local contract_sha=$1 tool_sha=$2
    [[ "$(v3015_sha256_file "$DR_PUBLIC_ARTIFACT_RECEIPT")" == \
         "$DR_PUBLIC_ARTIFACT_RECEIPT_SHA256" &&
       "$(v3015_sha256_file "$DR_FLEET_INTEGRATION_RECEIPT")" == \
         "$DR_FLEET_INTEGRATION_RECEIPT_SHA256" &&
       "$(v3015_sha256_file "$DR_NODE30_ONE_SHOT_RECEIPT")" == \
         "$DR_NODE30_ONE_SHOT_RECEIPT_SHA256" &&
       "$(v3015_sha256_file "$DR_NODE27_RELAY_RECEIPT")" == \
         "$DR_NODE27_RELAY_RECEIPT_SHA256" &&
       "$(v3015_sha256_file "$DR_POS_RENEWAL_RECEIPT")" == \
         "$DR_POS_RENEWAL_RECEIPT_SHA256" &&
       "$(v3015_sha256_file "$DR_ROLLBACK_PLAN_RECEIPT")" == \
         "$DR_ROLLBACK_PLAN_RECEIPT_SHA256" &&
       "$(v3015_sha256_file "$DR_BEFORE_INDEX")" == "$DR_BEFORE_INDEX_SHA256" ]] || return 1
    v3015_dr_topology_and_waves_are_valid "$DR_TOPOLOGY_MAP" "$DR_WAVES_PLAN" &&
      v3015_dr_public_artifact_is_valid "$DR_PUBLIC_ARTIFACT_RECEIPT" &&
      v3015_dr_node30_one_shot_is_valid "$DR_NODE30_ONE_SHOT_RECEIPT" &&
      v3015_dr_node27_relay_is_valid "$DR_NODE27_RELAY_RECEIPT" &&
      v3015_dr_pos_renewal_is_valid "$DR_POS_RENEWAL_RECEIPT" &&
      v3015_dr_integration_is_valid "$DR_FLEET_INTEGRATION_RECEIPT" \
        "$contract_sha" "$tool_sha" &&
      v3015_dr_rollback_plan_is_valid "$DR_ROLLBACK_PLAN_RECEIPT" &&
      v3015_dr_before_index_is_valid "$DR_BEFORE_INDEX"
}

v3015_dr_make_audit_receipt()
{
    local contract_sha=$1 tool_sha=$2
    jq -cn --arg source "$DR_SOURCE_SHA" --arg tree "$DR_SOURCE_TREE" \
      --arg merge "$DR_MERGE_SHA" --arg image "$DR_CANDIDATE_IMAGE_REF" \
      --arg image_id "$DR_CANDIDATE_IMAGE_ID" --arg integration "$DR_FLEET_INTEGRATION_COMMIT" \
      --arg integration_tree "$DR_FLEET_INTEGRATION_TREE" \
      --arg public "$DR_PUBLIC_ARTIFACT_RECEIPT_SHA256" \
      --arg integration_receipt "$DR_FLEET_INTEGRATION_RECEIPT_SHA256" \
      --arg node30 "$DR_NODE30_ONE_SHOT_RECEIPT_SHA256" \
      --arg node27 "$DR_NODE27_RELAY_RECEIPT_SHA256" \
      --arg renewal "$DR_POS_RENEWAL_RECEIPT_SHA256" \
      --arg rollback "$DR_ROLLBACK_PLAN_RECEIPT_SHA256" \
      --arg topology "$DR_TOPOLOGY_SHA256" --arg waves "$DR_WAVES_SHA256" \
      --arg before "$DR_BEFORE_INDEX_SHA256" --arg contract "$contract_sha" \
      --arg tool "$tool_sha" --arg installed "$DR_INSTALLED_V3014_IMAGE_REF" \
      --arg installed_id "$DR_INSTALLED_V3014_IMAGE_ID" \
      --argjson wave_count "$(v3015_dr_wave_count)" '
      {schema:1,kind:"v30.1.5-deployment-readiness-audit",release:"v30.1.5",
       source_sha:$source,source_tree:$tree,merge_commit:$merge,
       candidate_image_ref:$image,candidate_image_id:$image_id,
       fleet_integration_commit:$integration,fleet_integration_tree:$integration_tree,
       public_artifact_receipt_sha256:$public,
       fleet_integration_receipt_sha256:$integration_receipt,
       node30_one_shot_product_receipt_sha256:$node30,
       node27_relay_product_receipt_sha256:$node27,
       pos_renewal_lock_receipt_sha256:$renewal,
       rollback_plan_receipt_sha256:$rollback,topology_sha256:$topology,
       waves_sha256:$waves,before_receipt_index_sha256:$before,
       deployment_contract_sha256:$contract,deployment_tool_sha256:$tool,
       installed_v3014_image_ref:$installed,installed_v3014_image_id:$installed_id,
       fleet_nodes:32,wave_count:$wave_count,max_wave_width:4,canary_nodes:[27,16],
       node30_last:true,node30_ordinary_pow_disabled:true,node30_free_claim_paused:true,
       node30_semantic_preseal_deployable:false,installed_v3014_preserved:true,
       candidate_bytes_started:false,deployment_authorized:false,
       live_execution_performed:false,data_rewind_authorized:false,
       action:"offline-audit-only"}
    '
}

v3015_dr_audit_receipt_is_valid()
{
    local file=$1 contract_sha=$2 tool_sha=$3 expected
    expected=$(v3015_dr_make_audit_receipt "$contract_sha" "$tool_sha") || return
    [[ "$(jq -cS . "$file")" == "$(jq -cS . <<<"$expected")" ]]
}

v3015_dr_live_wave_authority_is_valid()
{
    local file=$1 now=$2 audit_sha=$3 wave_index=$4 expected_nodes role public_sha integration_sha
    expected_nodes=$(v3015_dr_wave_nodes_json "$wave_index") || return
    role=$(v3015_dr_wave_role "$wave_index") || return
    public_sha=$(v3015_sha256_file "$DR_PUBLIC_ARTIFACT_RECEIPT") || return
    integration_sha=$(v3015_sha256_file "$DR_FLEET_INTEGRATION_RECEIPT") || return
    jq -e --arg source "$DR_SOURCE_SHA" --arg image "$DR_CANDIDATE_IMAGE_REF" \
      --arg image_id "$DR_CANDIDATE_IMAGE_ID" --arg audit "$audit_sha" \
      --arg public "$public_sha" --arg integration "$integration_sha" \
      --arg topology "$DR_TOPOLOGY_SHA256" --arg waves "$DR_WAVES_SHA256" \
      --arg before "$DR_BEFORE_INDEX_SHA256" --arg rollback "$DR_ROLLBACK_PLAN_RECEIPT_SHA256" \
      --arg role "$role" --argjson wave "$wave_index" --argjson nodes "$expected_nodes" \
      --argjson now "$now" '
      def nonce: type=="string" and test("^[0-9a-f]{32}$");
      def integer: type=="number" and floor==.;
      def keys_expected: ["audit_receipt_sha256","authorized_nodes","authorized_wave_index",
        "before_receipt_index_sha256","bootstrap_authorized","candidate_image_id",
        "candidate_image_ref","data_rewind_authorized","expires_epoch",
        "fleet_integration_receipt_sha256","installed_v3014_removal_authorized","kind",
        "max_inflight_nodes","new_key_authorized","next_wave_authorized",
        "node30_free_claim_release_authorized","node30_ordinary_pow_authorized",
        "nonce","not_before_epoch","public_artifact_receipt_sha256",
        "recovery_transaction_authorized","reindex_authorized","release",
        "repair_authorized","rollback_plan_receipt_sha256","schema","source_sha",
        "stop_on_first_failure","topology_sha256","v3014_post_candidate_restart_authorized",
        "wallet_transaction_authorized","wave_role","waves_sha256"];
      . as $authority |
      type=="object" and (keys|sort)==(keys_expected|sort) and .schema==1 and
      .kind=="v30.1.5-live-wave-authority" and .release=="v30.1.5" and
      .source_sha==$source and .candidate_image_ref==$image and .candidate_image_id==$image_id and
      .audit_receipt_sha256==$audit and .public_artifact_receipt_sha256==$public and
      .fleet_integration_receipt_sha256==$integration and .topology_sha256==$topology and
      .waves_sha256==$waves and .before_receipt_index_sha256==$before and
      .rollback_plan_receipt_sha256==$rollback and .authorized_wave_index==$wave and
      .authorized_nodes==$nodes and .wave_role==$role and (.authorized_nodes|length)>=1 and
      (.authorized_nodes|length)<=4 and .max_inflight_nodes==4 and
      .stop_on_first_failure==true and .next_wave_authorized==false and
      (.nonce|nonce) and (.not_before_epoch|integer and .>=0) and
      (.expires_epoch|integer) and .expires_epoch>$authority.not_before_epoch and
      .not_before_epoch<=$now and $now<.expires_epoch and
      (.expires_epoch-.not_before_epoch)<=900 and
      .wallet_transaction_authorized==false and .recovery_transaction_authorized==false and
      .new_key_authorized==false and .bootstrap_authorized==false and
      .reindex_authorized==false and .repair_authorized==false and
      .data_rewind_authorized==false and .installed_v3014_removal_authorized==false and
      .v3014_post_candidate_restart_authorized==false and
      .node30_ordinary_pow_authorized==false and
      .node30_free_claim_release_authorized==false
    ' "$file" >/dev/null
}

v3015_dr_make_wave_authorization_receipt()
{
    local audit_sha=$1 authority_sha=$2 authority_file=$3 checked=$4
    local wave_index nodes role nonce expires
    wave_index=$(jq -er '.authorized_wave_index' "$authority_file") || return
    nodes=$(jq -c '.authorized_nodes' "$authority_file") || return
    role=$(jq -er '.wave_role' "$authority_file") || return
    nonce=$(jq -er '.nonce' "$authority_file") || return
    expires=$(jq -er '.expires_epoch' "$authority_file") || return
    jq -cn --arg source "$DR_SOURCE_SHA" --arg image "$DR_CANDIDATE_IMAGE_REF" \
      --arg image_id "$DR_CANDIDATE_IMAGE_ID" --arg audit "$audit_sha" \
      --arg authority "$authority_sha" --arg nonce "$nonce" --arg role "$role" \
      --argjson wave "$wave_index" --argjson nodes "$nodes" --argjson expires "$expires" \
      --argjson checked "$checked" '
      {schema:1,kind:"v30.1.5-wave-authorization-check",release:"v30.1.5",
       source_sha:$source,candidate_image_ref:$image,candidate_image_id:$image_id,
       audit_receipt_sha256:$audit,live_wave_authority_sha256:$authority,nonce:$nonce,
       authorized_wave_index:$wave,authorized_nodes:$nodes,wave_role:$role,
       authority_checked_epoch:$checked,expires_epoch:$expires,
       max_inflight_nodes:4,stop_on_first_failure:true,
       installed_v3014_preserved:true,node30_ordinary_pow_disabled:true,
       node30_free_claim_paused:true,node30_free_claim_release_authorized:false,
       data_rewind_authorized:false,deployment_ready:true,
       live_execution_performed:false,action:"offline-authority-check-only"}
    '
}

v3015_dr_wave_authorization_receipt_is_valid()
{
    local file=$1 audit_sha=$2 authority_sha=$3 authority_file=$4 checked=$5 expected
    expected=$(v3015_dr_make_wave_authorization_receipt \
      "$audit_sha" "$authority_sha" "$authority_file" "$checked") || return
    [[ "$(jq -cS . "$file")" == "$(jq -cS . <<<"$expected")" ]]
}

v3015_dr_after_receipt_is_valid()
{
    local file=$1 expected_node=$2 before_file=$3 before_sha=$4 audit_sha=$5 authority_sha=$6
    local nonce=$7 wave_index=$8 topology_row service container role binaries
    topology_row=$(v3015_topology_lookup "$DR_TOPOLOGY_MAP" "$expected_node") || return
    IFS=$'\t' read -r service container <<<"$topology_row"
    [[ "$expected_node" == 30 ]] && role=free_claim || role=regular
    binaries=$(v3015_dr_binary_json candidate) || return
    jq -e --argjson node "$expected_node" --arg role "$role" --arg service "$service" \
      --arg container "$container" --arg topology "$DR_TOPOLOGY_SHA256" \
      --arg source "$DR_SOURCE_SHA" --arg image "$DR_CANDIDATE_IMAGE_REF" \
      --arg image_id "$DR_CANDIDATE_IMAGE_ID" --argjson binaries "$binaries" \
      --arg before_sha "$before_sha" --arg audit "$audit_sha" --arg authority "$authority_sha" \
      --arg nonce "$nonce" --argjson wave "$wave_index" --argjson min_peers "$DR_MIN_PEERS" \
      --slurpfile before_receipt "$before_file" '
      def hex64: type=="string" and test("^[0-9a-f]{64}$");
      def integer: type=="number" and floor==.;
      def chain: (keys|sort)==(["bestblockhash","blocks","chain","chainwork","headers",
        "initialblockdownload"]|sort) and .chain=="main" and (.bestblockhash|hex64) and
        (.chainwork|hex64) and (.blocks|integer and .>=0) and
        (.headers|integer) and .headers>=.blocks and .initialblockdownload==false;
      ($before_receipt[0]) as $b |
      type=="object" and (keys|sort)==(["audit_receipt_sha256","before_receipt_sha256",
        "captured_epoch","container_name","core_bracket","intent","kind",
        "live_wave_authority_sha256","network","node","nonce","role","runtime","schema",
        "storage","topology_sha256","transition","compose_service","wallet",
        "wave_index"]|sort) and .schema==1 and .kind=="v30.1.5-node-after-receipt" and
      .node==$node and .role==$role and .compose_service==$service and
      .container_name==$container and .topology_sha256==$topology and
      .before_receipt_sha256==$before_sha and .audit_receipt_sha256==$audit and
      .live_wave_authority_sha256==$authority and .nonce==$nonce and .wave_index==$wave and
      (.captured_epoch|integer and .>0) and
      (.core_bracket|keys|sort)==(["after","before"]|sort) and
      (.core_bracket.before|chain) and
      .core_bracket.after==.core_bracket.before and
      .core_bracket.after.blocks >= $b.core_bracket.after.blocks and
      .core_bracket.after.chainwork >= $b.core_bracket.after.chainwork and
      (.network|keys|sort)==(["connections","networkactive"]|sort) and
      .network.networkactive==true and (.network.connections|integer and .>=$min_peers) and
      .runtime=={version:300105,subversion:"/Blackcoin:30.1.5/",source_sha:$source,
        image_ref:$image,image_id:$image_id,binary_sha256s:$binaries,running:true,
        paused:false,restarting:false,dead:false,health:"healthy"} and
      (.wallet|keys|sort)==(["generation","identity_sha256","loaded_wallets",
        "private_keys_enabled","processed_height","processed_tip","scanning"]|sort) and
      .wallet.loaded_wallets==1 and .wallet.identity_sha256==$b.wallet.identity_sha256 and
      (.wallet.generation|integer and .>=$b.wallet.generation) and
      .wallet.processed_tip==.core_bracket.after.bestblockhash and
      .wallet.processed_height==.core_bracket.after.blocks and
      .wallet.private_keys_enabled==true and .wallet.scanning==false and
      (.storage|keys|sort)==(["bootstrap_used","dataset_identity_sha256",
        "installed_v3014_image_retained","reindex_used","repair_used","rewind_used",
        "wallet_replaced","wallet_storage_identity_sha256"]|sort) and
      .storage.dataset_identity_sha256==$b.storage.dataset_identity_sha256 and
      .storage.wallet_storage_identity_sha256==$b.storage.wallet_storage_identity_sha256 and
      .storage.installed_v3014_image_retained==true and .storage.bootstrap_used==false and
      .storage.reindex_used==false and .storage.repair_used==false and
      .storage.rewind_used==false and .storage.wallet_replaced==false and
      (.intent|keys|sort)==(["automatic_quantum_key_creation",
        "automatic_recovery_authorized","free_claim_paused","free_claim_role",
        "ordinary_pow_active","ordinary_pow_autostart","ordinary_pow_enabled",
        "pos_active","pos_enabled"]|sort) and
      .intent.pos_enabled==true and .intent.pos_active==true and
      .intent.automatic_recovery_authorized==false and
      .intent.automatic_quantum_key_creation==false and
      (if $node==30 then
         .intent.free_claim_role==true and .intent.free_claim_paused==true and
         .intent.ordinary_pow_enabled==false and .intent.ordinary_pow_autostart==false and
         .intent.ordinary_pow_active==false
       else
         .intent.free_claim_role==false and .intent.free_claim_paused==false and
         .intent.ordinary_pow_enabled==true and .intent.ordinary_pow_autostart==true and
         .intent.ordinary_pow_active==true
       end) and
      (.transition|keys|sort)==(["before_tip_is_ancestor","height_not_rewound",
        "node30_one_shot_invoked","v3014_restart_authorized",
        "wallet_fees_paid","wallet_keys_created","wallet_migration_performed",
        "wallet_transactions_created"]|sort) and
      .transition.before_tip_is_ancestor==true and
      .transition.height_not_rewound==true and
      .transition.wallet_transactions_created==0 and .transition.wallet_fees_paid==0 and
      .transition.wallet_keys_created==0 and .transition.wallet_migration_performed==false and
      .transition.v3014_restart_authorized==false and
      .transition.node30_one_shot_invoked==false
    ' "$file" >/dev/null
}

v3015_dr_after_index_is_valid()
{
    local index=$1 audit_sha=$2 authority_sha=$3 authority_file=$4
    local nodes nonce wave entries entry node path sha before_entry before_path before_sha count=0
    nodes=$(jq -c '.authorized_nodes' "$authority_file") || return
    nonce=$(jq -er '.nonce' "$authority_file") || return
    wave=$(jq -er '.authorized_wave_index' "$authority_file") || return
    jq -e --arg topology "$DR_TOPOLOGY_SHA256" --arg audit "$audit_sha" \
      --arg authority "$authority_sha" --arg nonce "$nonce" --argjson wave "$wave" \
      --argjson nodes "$nodes" '
      def hex64: type=="string" and test("^[0-9a-f]{64}$");
      type=="object" and (keys|sort)==(["audit_receipt_sha256","kind",
        "live_wave_authority_sha256","nonce","receipts","schema","topology_sha256",
        "wave_index"]|sort) and .schema==1 and .kind=="v30.1.5-after-receipt-index" and
      .topology_sha256==$topology and .audit_receipt_sha256==$audit and
      .live_wave_authority_sha256==$authority and .nonce==$nonce and .wave_index==$wave and
      ([.receipts[].node]|sort)==($nodes|sort) and
      all(.receipts[]; (keys|sort)==(["node","path","sha256"]|sort) and
        (.path|type=="string" and startswith("/")) and (.sha256|hex64))
    ' "$index" >/dev/null || return 1
    entries=$(jq -c '.receipts[]' "$index") || return
    while IFS= read -r entry; do
        node=$(jq -er '.node' <<<"$entry") || return
        path=$(jq -er '.path' <<<"$entry") || return
        sha=$(jq -er '.sha256' <<<"$entry") || return
        v3015_dr_file_is_safe "$path" || return
        [[ "$(v3015_sha256_file "$path")" == "$sha" ]] || return 1
        before_entry=$(v3015_dr_before_entry "$DR_BEFORE_INDEX" "$node") || return
        before_path=$(jq -er '.path' <<<"$before_entry") || return
        before_sha=$(jq -er '.sha256' <<<"$before_entry") || return
        v3015_dr_after_receipt_is_valid "$path" "$node" "$before_path" "$before_sha" \
          "$audit_sha" "$authority_sha" "$nonce" "$wave" || return
        count=$((count+1))
    done <<<"$entries"
    [[ "$count" == "$(jq -r 'length' <<<"$nodes")" ]]
}

v3015_dr_wave_success_is_valid()
{
    local file=$1 authorization_sha=$2 audit_sha=$3 authority_sha=$4 authority_file=$5 after_sha=$6
    local nonce wave nodes
    nonce=$(jq -er '.nonce' "$authority_file") || return
    wave=$(jq -er '.authorized_wave_index' "$authority_file") || return
    nodes=$(jq -c '.authorized_nodes' "$authority_file") || return
    jq -e --arg source "$DR_SOURCE_SHA" --arg image "$DR_CANDIDATE_IMAGE_REF" \
      --arg authorization "$authorization_sha" --arg audit "$audit_sha" \
      --arg authority "$authority_sha" --arg after "$after_sha" --arg nonce "$nonce" \
      --argjson wave "$wave" --argjson nodes "$nodes" '
      type=="object" and (keys|sort)==(["after_receipt_index_sha256",
        "audit_receipt_sha256","authorized_nodes","candidate_image_ref",
        "candidate_processes_running","completed_nodes","containment_invoked",
        "data_rewind_used","installed_v3014_image_retained","kind",
        "live_wave_authority_sha256","maintenance_pause_retained","next_wave_authorized",
        "node30_free_claim_paused","node30_ordinary_pow_disabled","nonce","release",
        "rollout_halted","schema","source_sha","state",
        "wave_authorization_receipt_sha256","wave_index"]|sort) and
      .schema==1 and .kind=="v30.1.5-wave-result" and .release=="v30.1.5" and
      .state=="pass" and .source_sha==$source and .candidate_image_ref==$image and
      .wave_authorization_receipt_sha256==$authorization and
      .audit_receipt_sha256==$audit and .live_wave_authority_sha256==$authority and
      .after_receipt_index_sha256==$after and .nonce==$nonce and .wave_index==$wave and
      .authorized_nodes==$nodes and .completed_nodes==$nodes and
      .candidate_processes_running==($nodes|length) and .containment_invoked==false and
      .rollout_halted==false and .next_wave_authorized==false and
      .installed_v3014_image_retained==true and .maintenance_pause_retained==true and
      .node30_ordinary_pow_disabled==true and .node30_free_claim_paused==true and
      .data_rewind_used==false
    ' "$file" >/dev/null
}

v3015_dr_containment_is_valid()
{
    local file=$1 authorization_sha=$2 audit_sha=$3 authority_sha=$4 authority_file=$5
    local nonce wave nodes
    nonce=$(jq -er '.nonce' "$authority_file") || return
    wave=$(jq -er '.authorized_wave_index' "$authority_file") || return
    nodes=$(jq -c '.authorized_nodes' "$authority_file") || return
    jq -e --arg source "$DR_SOURCE_SHA" --arg image "$DR_CANDIDATE_IMAGE_REF" \
      --arg authorization "$authorization_sha" --arg audit "$audit_sha" \
      --arg authority "$authority_sha" --arg nonce "$nonce" \
      --argjson wave "$wave" --argjson nodes "$nodes" '
      . as $result |
      type=="object" and (keys|sort)==(["attempted_nodes","audit_receipt_sha256",
        "candidate_image_ref","candidate_processes_running","contained_nodes",
        "containment_completed","data_rewind_used","failed_nodes",
        "installed_v3014_image_retained","kind","live_wave_authority_sha256",
        "maintenance_pause_retained","new_key_created","next_wave_authorized",
        "node30_free_claim_paused","node30_ordinary_pow_disabled","nonce",
        "recovery_transaction_created","reindex_used","release","repair_used",
        "rollout_halted","schema","source_sha","state","v3014_restart_attempted",
        "wallet_restore_used","wave_authorization_receipt_sha256","wave_index"]|sort) and
      .schema==1 and .kind=="v30.1.5-wave-containment-result" and .release=="v30.1.5" and
      .state=="failed-contained" and .source_sha==$source and
      .candidate_image_ref==$image and
      .wave_authorization_receipt_sha256==$authorization and
      .audit_receipt_sha256==$audit and .live_wave_authority_sha256==$authority and
      .nonce==$nonce and .wave_index==$wave and
      (.attempted_nodes|type=="array" and length>=1 and length<=($nodes|length)) and
      (.attempted_nodes | all(. as $node | $nodes | index($node)!=null)) and
      (.failed_nodes|type=="array" and length>=1) and
      (.failed_nodes | all(. as $node | $result.attempted_nodes | index($node)!=null)) and
      .contained_nodes==.attempted_nodes and .containment_completed==true and
      .candidate_processes_running==0 and .rollout_halted==true and
      .next_wave_authorized==false and .installed_v3014_image_retained==true and
      .maintenance_pause_retained==true and .node30_ordinary_pow_disabled==true and
      .node30_free_claim_paused==true and .v3014_restart_attempted==false and
      .data_rewind_used==false and .reindex_used==false and .repair_used==false and
      .wallet_restore_used==false and .recovery_transaction_created==false and
      .new_key_created==false
    ' "$file" >/dev/null
}

v3015_dr_rollout_authority_is_valid()
{
    local file=$1 audit_sha=$2 public_sha integration_sha before_sha topology_sha waves_sha
    public_sha=$(v3015_sha256_file "$DR_PUBLIC_ARTIFACT_RECEIPT") || return
    integration_sha=$(v3015_sha256_file "$DR_FLEET_INTEGRATION_RECEIPT") || return
    before_sha=$(v3015_sha256_file "$DR_BEFORE_INDEX") || return
    topology_sha=$(v3015_sha256_file "$DR_TOPOLOGY_MAP") || return
    waves_sha=$(v3015_sha256_file "$DR_WAVES_PLAN") || return
    jq -e --arg source "$DR_SOURCE_SHA" --arg image "$DR_CANDIDATE_IMAGE_REF" \
      --arg image_id "$DR_CANDIDATE_IMAGE_ID" --arg audit "$audit_sha" \
      --arg public "$public_sha" --arg integration "$integration_sha" \
      --arg before "$before_sha" --arg topology "$topology_sha" --arg waves "$waves_sha" '
      def hex64: type=="string" and test("^[0-9a-f]{64}$");
      type=="object" and (keys|sort)==(["audit_receipt_sha256",
        "before_receipt_index_sha256","candidate_image_id","candidate_image_ref",
        "fleet_integration_receipt_sha256","kind","node30_free_claim_release_authorized",
        "node30_free_claim_stays_paused","node30_ordinary_pow_authorized","nonce",
        "public_artifact_receipt_sha256","release","schema","source_sha",
        "topology_sha256","waves_sha256"]|sort) and .schema==1 and
      .kind=="v30.1.5-rollout-authority" and .release=="v30.1.5" and
      .source_sha==$source and .candidate_image_ref==$image and .candidate_image_id==$image_id and
      .audit_receipt_sha256==$audit and .public_artifact_receipt_sha256==$public and
      .fleet_integration_receipt_sha256==$integration and
      .before_receipt_index_sha256==$before and .topology_sha256==$topology and
      .waves_sha256==$waves and (.nonce|type=="string" and test("^[0-9a-f]{32}$")) and
      .node30_ordinary_pow_authorized==false and
      .node30_free_claim_release_authorized==false and .node30_free_claim_stays_paused==true
    ' "$file" >/dev/null
}

v3015_dr_fleet_result_is_valid()
{
    local file=$1 audit_sha=$2 rollout_authority_sha=$3 census_sha=$4
    jq -e --arg source "$DR_SOURCE_SHA" --arg image "$DR_CANDIDATE_IMAGE_REF" \
      --arg audit "$audit_sha" --arg authority "$rollout_authority_sha" \
      --arg census "$census_sha" --arg topology "$DR_TOPOLOGY_SHA256" \
      --arg waves "$DR_WAVES_SHA256" '
      type=="object" and (keys|sort)==(["audit_receipt_sha256","candidate_image_ref",
        "data_rewind_used","fleet_census_sha256","healthy_nodes","kind",
        "maintenance_finalization_state","node30_free_claim_paused",
        "node30_free_claim_release_accepted","node30_ordinary_pow_active",
        "node30_ordinary_pow_enabled","pos_active_nodes","regular_pow_active_nodes",
        "release","rollout_authority_sha256","schema","source_sha","state",
        "topology_sha256","waves_sha256"]|sort) and .schema==1 and
      .kind=="v30.1.5-fleet-deployment-result" and .release=="v30.1.5" and
      .state=="pass-pause-preserved" and .source_sha==$source and
      .candidate_image_ref==$image and .audit_receipt_sha256==$audit and
      .rollout_authority_sha256==$authority and .fleet_census_sha256==$census and
      .topology_sha256==$topology and .waves_sha256==$waves and
      .healthy_nodes==32 and .pos_active_nodes==32 and .regular_pow_active_nodes==31 and
      .node30_ordinary_pow_enabled==false and .node30_ordinary_pow_active==false and
      .node30_free_claim_paused==true and .node30_free_claim_release_accepted==false and
      .maintenance_finalization_state=="complete-pause-preserved" and
      .data_rewind_used==false
    ' "$file" >/dev/null
}

v3015_dr_fleet_census_is_valid()
{
    local file=$1 audit_sha=$2 rollout_authority_sha=$3
    jq -e --arg source "$DR_SOURCE_SHA" --arg image "$DR_CANDIDATE_IMAGE_REF" \
      --arg image_id "$DR_CANDIDATE_IMAGE_ID" --arg audit "$audit_sha" \
      --arg authority "$rollout_authority_sha" --arg topology "$DR_TOPOLOGY_SHA256" \
      --argjson min_peers "$DR_MIN_PEERS" '
      def hex64: type=="string" and test("^[0-9a-f]{64}$");
      def integer: type=="number" and floor==.;
      type=="object" and (keys|sort)==(["audit_receipt_sha256",
        "candidate_image_id","candidate_image_ref","kind",
        "nodes","release","rollout_authority_sha256","schema","source_sha",
        "topology_sha256"]|sort) and .schema==1 and
      .kind=="v30.1.5-terminal-fleet-census" and .release=="v30.1.5" and
      .source_sha==$source and .candidate_image_ref==$image and .candidate_image_id==$image_id and
      .audit_receipt_sha256==$audit and
      .rollout_authority_sha256==$authority and .topology_sha256==$topology and
      (.nodes|type=="array" and length==32) and ([.nodes[].node]|sort)==[range(1;33)] and
      all(.nodes[];
        (keys|sort)==(["container_image_id","container_image_ref","free_claim_paused",
          "healthy","ibd","node","ordinary_pow_active","ordinary_pow_enabled",
          "peers","pos_active","wallet_tip_matches"]|sort) and
        .container_image_ref==$image and .container_image_id==$image_id and
        .healthy==true and .ibd==false and (.peers|integer and .>=$min_peers) and
        .pos_active==true and .wallet_tip_matches==true and
        (if .node==30 then
           .ordinary_pow_enabled==false and .ordinary_pow_active==false and
           .free_claim_paused==true
         else
           .ordinary_pow_enabled==true and .ordinary_pow_active==true and
           .free_claim_paused==false
         end))
    ' "$file" >/dev/null
}

v3015_dr_terminal_bundle_is_valid()
{
    local audit_sha=$1 rollout_authority=$2 fleet_result=$3 census=$4
    local authority_sha census_sha
    authority_sha=$(v3015_sha256_file "$rollout_authority") || return
    census_sha=$(v3015_sha256_file "$census") || return
    v3015_dr_rollout_authority_is_valid "$rollout_authority" "$audit_sha" &&
      v3015_dr_fleet_census_is_valid "$census" "$audit_sha" "$authority_sha" &&
      v3015_dr_fleet_result_is_valid "$fleet_result" "$audit_sha" \
        "$authority_sha" "$census_sha"
}

v3015_dr_make_reconciliation_receipt()
{
    local state=$1 authorization_sha=$2 audit_sha=$3 authority_sha=$4 result_sha=$5
    local after_sha=$6 result_file=$7 wave nonce nodes
    wave=$(jq -er '.wave_index' "$result_file") || return
    nonce=$(jq -er '.nonce' "$result_file") || return
    if [[ "$state" == pass ]]; then
        nodes=$(jq -c '.completed_nodes' "$result_file") || return
    else
        nodes=$(jq -c '.contained_nodes' "$result_file") || return
    fi
    jq -cn --arg source "$DR_SOURCE_SHA" --arg image "$DR_CANDIDATE_IMAGE_REF" \
      --arg state "$state" --arg authorization "$authorization_sha" --arg audit "$audit_sha" \
      --arg authority "$authority_sha" --arg result "$result_sha" --arg after "$after_sha" \
      --arg nonce "$nonce" --argjson wave "$wave" --argjson nodes "$nodes" '
      {schema:1,kind:"v30.1.5-offline-wave-reconciliation",release:"v30.1.5",
       source_sha:$source,candidate_image_ref:$image,state:$state,wave_index:$wave,
       nodes:$nodes,nonce:$nonce,audit_receipt_sha256:$audit,
       wave_authorization_receipt_sha256:$authorization,
       live_wave_authority_sha256:$authority,wave_result_receipt_sha256:$result,
       after_receipt_index_sha256:(if $state=="pass" then $after else null end),
       installed_v3014_preserved:true,node30_ordinary_pow_disabled:true,
       node30_free_claim_paused:true,next_wave_authorized:false,
       data_rewind_used:false,offline_validation_only:true}
    '
}
