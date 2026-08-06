#!/usr/bin/env bash

# One-time, append-only recovery for the authenticated node-27 containment
# produced by rollout-20260806T094713Z. The original activation and containment
# records are never replaced. Apply restarts the same candidate container,
# reproves the no-spend runtime contract, and publishes RESULT only after the
# normal wave evidence verifier accepts the supersession record.

set -Eeuo pipefail
umask 077
export LC_ALL=C TZ=UTC

readonly ADOPTION_ACTION=${1:-plan}
ADOPTION_PACKAGE_ROOT=$(CDPATH='' cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) ||
    exit 1
readonly ADOPTION_PACKAGE_ROOT
readonly TRANSACTION_PACKAGE_ROOT=/mnt/pulsar/Blackcoin_Blocks/operations/v30.1.4-packages/rollout-express-c15d60a/seal-root/v30.1.4-rollout-transaction
readonly TRANSACTION_ENV=/mnt/pulsar/Blackcoin_Blocks/operations/v30.1.4-packages/rollout-express-c15d60a/rollout.env
readonly TRANSACTION_ENV_SHA256=6227fb0d2c20427911522f440639c3805285070b616e773561ec38c9f54abba9
readonly TRANSACTION_PACKAGE_MANIFEST_SHA256=746573c32499ed3d34be61b4254c7a35f4fff5f5b25bd79a4f8be63813638348
readonly TRANSACTION_MANIFEST_SHA256=887541147aa0ef998e67ef0b2fd262a8fa37c50efa13b49ad3b465205abaff7a
readonly TRANSACTION_PACKAGE_FILES_SHA256=b5baf86026a5001c3f0085ac5e092e98cbd2c090c78699ff5ed8d663bbc260e7
readonly TRANSACTION_WAVES_SHA256=8d271748a22dcde252a8e57e0b8d26bd3dbf8b98fe0e9eb7195f46ebb13522e1
readonly TRANSACTION_BASELINE_MANIFEST_SHA256=f2d59b6a1b01b0773be0691993e24ea7534a112dd8317a48cfab53861b6fe34e
readonly TARGET_RUN=/mnt/pulsar/Blackcoin_Blocks/operations/v30.1.4-fleet-rollout/rollout-20260806T094713Z
readonly TARGET_WAVE="$TARGET_RUN/wave-01-nodes-27-retry-01"
readonly TARGET_NODE=27
readonly TARGET_CONTAINER=blackcoin-v4-gui-27
readonly MAX_READOPTION_ATTEMPTS=3
readonly ORIGINAL_ACTIVATION_SHA256=e205f8ed839a7f2eaa93bff4e668cfa8461e6192955c966e3d678262286361cb
readonly ORIGINAL_CONTAINMENT_SHA256=1d8241570056cf9a0e66d5ffa9b2d7541d9eb9d14b4f0da2f3f53a05aa39bc42
readonly ORIGINAL_CONTAINMENT_COMPLETE_SHA256=821877cf29f3033680f58323e25c97d6e17cadf3c42a693f7d7ef655d0fedb2b
readonly ORIGINAL_POW_ACTIVATION_LOG_SHA256=76cc0df8f7f7e88603bc5ef1cb9fa42ec710d6f3a83c91d635d4419123d5ed86

protected_root_file()
{
    local path="$1" expected_sha=${2:-} actual
    [[ -f "$path" && ! -L "$path" && "$(realpath -e -- "$path")" == "$path" &&
       "$(stat -c '%u:%g:%a' "$path")" == 0:0:600 ]] || return 1
    if [[ -n "$expected_sha" ]]; then
        actual=$(sha256sum "$path" | awk '{print $1}') || return 1
        [[ "$actual" == "$expected_sha" ]]
    fi
}

atomic_write_json_exclusive()
{
    local destination="$1" directory temporary
    directory=${destination%/*}
    [[ -d "$directory" && ! -L "$directory" &&
       "$(realpath -e -- "$directory")" == "$directory" &&
       "$(stat -c '%u:%g:%a' "$directory")" == 0:0:700 ]] || return 1
    [[ ! -e "$destination" && ! -L "$destination" ]] || return 1
    temporary=$(mktemp "$directory/.exclusive-json.XXXXXX") || return 1
    if ! jq -S -e 'select(type == "object")' > "$temporary" ||
       ! chmod 600 "$temporary" || ! chown root:root "$temporary" ||
       ! sync -f "$temporary" || ! ln -- "$temporary" "$destination"; then
        rm -f -- "$temporary"
        return 1
    fi
    rm -f -- "$temporary"
    sync -f "$directory" || return 1
    protected_root_file "$destination"
}

[[ "$(id -u)" -eq 0 ]] || {
    printf '%s\n' 'FATAL: node27 adoption requires root on the Unraid host' >&2
    exit 1
}
protected_root_file "$TRANSACTION_ENV" "$TRANSACTION_ENV_SHA256" || {
    printf '%s\n' 'FATAL: sealed rollout environment is absent or changed' >&2
    exit 1
}
# shellcheck disable=SC1090
source "$TRANSACTION_ENV"
export RESUME_RUN_DIR="$TARGET_RUN"
export WAVE_PLAN="$TRANSACTION_PACKAGE_ROOT/waves.txt"
export SEALED_TRANSACTION_PACKAGE_ROOT="$TRANSACTION_PACKAGE_ROOT"
export PATH="$ADOPTION_PACKAGE_ROOT/tools:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Source the validated implementation as a library. Its plan action is
# intentionally read-only and leaves all verifier functions available here.
# shellcheck disable=SC1091
source "$ADOPTION_PACKAGE_ROOT/fleet_rollout.sh" plan >/dev/null

# These globals are consumed by functions sourced from fleet_rollout.sh.
# shellcheck disable=SC2034
CURRENT_WAVE_DIR="$TARGET_WAVE"
# shellcheck disable=SC2034
CURRENT_WAVE_NODES=("$TARGET_NODE")
ADOPTION_MUTATED=0
ADOPTION_COMPLETE=0
ADOPTION_COMMITTED=0
ADOPTION_LOCK_HELD=0
READOPTION_WORKER_PID=
READOPTION_ATTEMPT=0
READOPTION_GENERATION=
ADOPTION_REENTRY_STATE=

resume_receipt_path()
{
    resume_compatibility_path
}

supersession_path()
{
    wave_node_activation_supersession_path "$TARGET_NODE"
}

readoption_authorization_path()
{
    wave_node_readoption_authorization_path "$TARGET_NODE"
}

readoption_attempt_dir()
{
    printf '%s/node-27-readoption-attempts\n' "$TARGET_WAVE"
}

wallet_send_audit_path()
{
    local attempt=${1:-$READOPTION_ATTEMPT}
    [[ "$attempt" =~ ^[1-3]$ ]] || return 1
    printf '%s/attempt-%02d-WALLET-SEND-AUDIT.json\n' \
        "$(readoption_attempt_dir)" "$attempt"
}

readoption_attempt_path()
{
    local attempt="$1" state="$2"
    [[ "$attempt" =~ ^[1-3]$ &&
       ( "$state" == START-AUTHORIZED || "$state" == STARTED ||
         "$state" == POLICY-PROMOTION-AUTHORIZED || "$state" == FAILED-CONTAINED ) ]] ||
        return 1
    printf '%s/attempt-%02d-%s.json\n' "$(readoption_attempt_dir)" "$attempt" "$state"
}

verify_original_evidence_hashes()
{
    local path
    for record in \
        "node-27-CANDIDATE-ACTIVATION-ATTEMPTED.json:$ORIGINAL_ACTIVATION_SHA256" \
        "node-27-CONTAINED-NO-ROLLBACK.json:$ORIGINAL_CONTAINMENT_SHA256" \
        "CONTAINMENT-COMPLETE.sha256:$ORIGINAL_CONTAINMENT_COMPLETE_SHA256" \
        "node-27-pow-activation.log:$ORIGINAL_POW_ACTIVATION_LOG_SHA256"; do
        path="$TARGET_WAVE/${record%%:*}"
        protected_root_file "$path" "${record#*:}" || return 1
    done
}

verify_other_nodes_unchanged()
{
    local temporary
    temporary=$(mktemp "$TARGET_WAVE/.unaffected-adoption-check.XXXXXX") || return 1
    if ! capture_unaffected_generations "$temporary" "$TARGET_NODE" ||
       ! cmp -s "$TARGET_WAVE/unaffected.before" "$temporary"; then
        rm -f -- "$temporary"
        return 1
    fi
    rm -f -- "$temporary"
}

verify_static_adoption_authority()
{
    [[ "$(cat "$TARGET_RUN/STATE")" == applying &&
       "$(cat "$TARGET_WAVE/COMMIT_STATE")" == committed &&
       "$(cat "$TARGET_WAVE/ROLLBACK_STATE")" == contained-no-rollback ]] || return 1
    if [[ -e "$TARGET_WAVE/RESULT" || -L "$TARGET_WAVE/RESULT" ]]; then
        protected_root_file "$TARGET_WAVE/RESULT" || return 1
        [[ "$(cat "$TARGET_WAVE/RESULT")" == passed ]] || return 1
    fi
    verify_wave_evidence_manifest "$TARGET_WAVE" 1 || return 1
    verify_wave_drain_evidence || return 1
    verify_complete_wave_candidate_launch_markers || return 1
    verify_candidate_recovery_baseline "$TARGET_NODE" || return 1
    verify_original_evidence_hashes || return 1
    (cd "$TARGET_WAVE" && sha256sum --strict -c CONTAINMENT-COMPLETE.sha256 >/dev/null) ||
        return 1
    [[ "$(live_wave_triplet_state)" == candidate ]] || return 1
    (cd / && sha256sum --strict -c "$TARGET_WAVE/live-triplet.sha256" >/dev/null) || return 1
    verify_maintenance_marker || return 1
    [[ "$(/bin/bash "$INHIBITOR_RELEASER" probe)" == \
       'state=installed-and-paused cycle=v30.1.4-no-spend free_claim=paused' ]] || return 1
    verify_free_claim_pause || return 1
    assert_empty_control_marker "$ENABLE_GUARD_STARTS" || return 1
    verify_activation_helper "$NORMAL_UNLOCK_HELPER" "$NORMAL_UNLOCK_HELPER_SHA256" || return 1
    verify_activation_helper "$POW_START_HELPER" "$POW_START_HELPER_SHA256" || return 1
    verify_other_nodes_unchanged
}

verify_initial_containment()
{
    local inspect
    verify_static_adoption_authority || return 1
    containment_complete_manifest_valid || return 1
    verify_node_containment_marker "$TARGET_NODE" 1 || return 1
    inspect=$(docker inspect "$TARGET_CONTAINER") || return 1
    jq -e --arg image "$CANDIDATE_IMAGE_REF" --arg id "$CANDIDATE_IMAGE_ID" '
        length == 1 and .[0].Config.Image == $image and .[0].Image == $id and
        .[0].State.Running == false and .[0].State.Pid == 0 and
        .[0].State.Restarting == false and .[0].HostConfig.RestartPolicy.Name == "no" and
        .[0].HostConfig.RestartPolicy.MaximumRetryCount == 0
    ' >/dev/null <<< "$inspect" || return 1
}

publish_resume_compatibility()
{
    local path transaction_sha transaction_files_sha transaction_package_sha resume_package_sha
    path=$(resume_receipt_path) || return 1
    if [[ -e "$path" || -L "$path" ]]; then
        verify_resume_compatibility_authority "$TRANSACTION_PACKAGE_ROOT"
        return
    fi
    transaction_sha=$(sha256sum "$TARGET_RUN/TRANSACTION.json" | awk '{print $1}') || return 1
    transaction_files_sha=$(sha256sum "$TARGET_RUN/package-files.sha256" | awk '{print $1}') ||
        return 1
    transaction_package_sha=$(sha256sum "$TRANSACTION_PACKAGE_ROOT/SHA256SUMS" |
        awk '{print $1}') || return 1
    resume_package_sha=$(sha256sum "$PACKAGE_ROOT/SHA256SUMS" | awk '{print $1}') || return 1
    jq -n --arg run "$TARGET_RUN" --arg transaction_root "$TRANSACTION_PACKAGE_ROOT" \
        --arg transaction_package_sha "$transaction_package_sha" \
        --arg transaction_files_sha "$transaction_files_sha" \
        --arg transaction_sha "$transaction_sha" --arg resume_root "$PACKAGE_ROOT" \
        --arg resume_package_sha "$resume_package_sha" --arg image "$CANDIDATE_IMAGE_REF" \
        --arg image_id "$CANDIDATE_IMAGE_ID" --arg created_at "$(date -u +%FT%TZ)" '
        {schema:1,transaction:"v30.1.4-fleet-rollout",
         state:"resume-compatibility-authorized",run_dir:$run,
         transaction_package_root:$transaction_root,
         transaction_package_manifest_sha256:$transaction_package_sha,
         transaction_package_files_sha256:$transaction_files_sha,
         transaction_manifest_sha256:$transaction_sha,resume_package_root:$resume_root,
         resume_package_manifest_sha256:$resume_package_sha,candidate_image:$image,
         candidate_image_id:$image_id,
         authorized_fixes:["compose-create-compatibility",
           "activation-journal-descendant-drain","zero-padded-compose-renderer",
           "contained-node27-readoption"],managed_recovery_payments_authorized:false,
         protocol_pow_claim_transactions_authorized:true,
         unexpected_wallet_transactions_authorized:false,key_generation_authorized:false,
         address_generation_authorized:false,created_at:$created_at}' |
        atomic_write_json "$path" || return 1
    verify_resume_compatibility_authority "$TRANSACTION_PACKAGE_ROOT"
}

publish_readoption_authorization()
{
    local path activation containment containment_complete compatibility generation inspect
    path=$(readoption_authorization_path) || return 1
    activation=$(wave_node_activation_path "$TARGET_NODE") || return 1
    containment=$(wave_node_containment_path "$TARGET_NODE") || return 1
    containment_complete=$(wave_containment_complete_path) || return 1
    compatibility=$(resume_receipt_path) || return 1
    generation=$(container_generation_for "$TARGET_NODE") || return 1
    if [[ -e "$path" || -L "$path" ]]; then
        generation=$(jq -er '.contained_container_generation' "$path") || return 1
        verify_candidate_readoption_authorization "$TARGET_NODE" "$generation"
        return
    fi
    inspect=$(docker inspect "$TARGET_CONTAINER") || return 1
    jq -e --arg generation "$generation" --arg image "$CANDIDATE_IMAGE_REF" \
        --arg image_id "$CANDIDATE_IMAGE_ID" '
        length == 1 and .[0].State.Running == false and .[0].State.Pid == 0 and
        .[0].State.Restarting == false and .[0].HostConfig.RestartPolicy.Name == "no" and
        .[0].Config.Image == $image and .[0].Image == $image_id and
        (.[0].Id + "|" + .[0].State.StartedAt) == ($generation | split("|")[0:2] | join("|"))
    ' >/dev/null <<< "$inspect" || return 1
    jq -n --argjson node "$TARGET_NODE" --arg run "$TARGET_RUN" --arg wave "$TARGET_WAVE" \
        --arg image "$CANDIDATE_IMAGE_REF" --arg image_id "$CANDIDATE_IMAGE_ID" \
        --arg generation "$generation" \
        --arg activation_sha "$(sha256sum "$activation" | awk '{print $1}')" \
        --arg containment_sha "$(sha256sum "$containment" | awk '{print $1}')" \
        --arg containment_complete_sha "$(sha256sum "$containment_complete" | awk '{print $1}')" \
        --arg compatibility_sha "$(sha256sum "$compatibility" | awk '{print $1}')" \
        --arg created_at "$(date -u +%FT%TZ)" '
        {schema:1,transaction:"v30.1.4-fleet-rollout",state:"readoption-authorized",
         node:$node,run_dir:$run,wave_dir:$wave,
         reason:"transient-pow-helper-journal-tee-drain",candidate_image:$image,
         candidate_image_id:$image_id,contained_container_generation:$generation,
         original_activation_marker_sha256:$activation_sha,
         containment_marker_sha256:$containment_sha,
         containment_complete_sha256:$containment_complete_sha,
         resume_compatibility_sha256:$compatibility_sha,
         allowed_actions:["restart-policy-no-to-on-failure-3","same-container-start",
           "existing-wallet-unlock","legacy-pos-start","one-thread-one-percent-pow-start",
           "runtime-gate-and-evidence-publication"],managed_recovery_payments_authorized:false,
         protocol_pow_claim_transactions_authorized:true,
         unexpected_wallet_transactions_authorized:false,key_generation_authorized:false,
         address_generation_authorized:false,created_at:$created_at}' |
        atomic_write_json "$path" || return 1
    protected_root_file "$path"
}

readoption_generation_has_original_lineage()
{
    local generation="$1" original old_id old_started old_vpn old_vpn_started
    local id started vpn vpn_started activation
    activation=$(wave_node_activation_path "$TARGET_NODE") || return 1
    original=$(jq -er '.container_generation' "$activation") || return 1
    data_rollback_validate_stopped_generation "$generation" || return 1
    IFS='|' read -r old_id old_started old_vpn old_vpn_started <<< "$original" || return 1
    IFS='|' read -r id started vpn vpn_started <<< "$generation" || return 1
    [[ "$id" == "$old_id" && "$vpn" == "$old_vpn" &&
       "$vpn_started" == "$old_vpn_started" && -n "$started" ]]
}

verify_readoption_start_authorization()
{
    local attempt="$1" path readoption generation current_sha previous_sha=__NULL__ previous
    path=$(readoption_attempt_path "$attempt" START-AUTHORIZED) || return 1
    readoption=$(readoption_authorization_path) || return 1
    protected_root_file "$path" || return 1
    protected_root_file "$readoption" || return 1
    current_sha=$(sha256sum "$readoption" | awk '{print $1}') || return 1
    if ((attempt > 1)); then
        previous=$(readoption_attempt_path "$((attempt - 1))" FAILED-CONTAINED) || return 1
        verify_readoption_failed_containment_record "$((attempt - 1))" || return 1
        previous_sha=$(sha256sum "$previous" | awk '{print $1}') || return 1
    fi
    generation=$(jq -er '.prior_container_generation' "$path") || return 1
    readoption_generation_has_original_lineage "$generation" || return 1
    jq -e --argjson attempt "$attempt" --arg run "$TARGET_RUN" --arg wave "$TARGET_WAVE" \
        --arg generation "$generation" --arg image "$CANDIDATE_IMAGE_REF" \
        --arg image_id "$CANDIDATE_IMAGE_ID" --arg readoption_sha "$current_sha" \
        --arg previous_sha "$previous_sha" '
        (keys | sort) == (["schema","transaction","state","attempt","run_dir","wave_dir",
          "node","candidate_image","candidate_image_id","prior_container_generation",
          "readoption_authorization_sha256","previous_failed_containment_sha256",
          "allowed_action","restart_policy_during_start",
          "managed_recovery_payments_authorized",
          "protocol_pow_claim_transactions_authorized",
          "unexpected_wallet_transactions_authorized","key_generation_authorized",
          "address_generation_authorized","created_at"] | sort) and
        .schema == 1 and .transaction == "v30.1.4-fleet-rollout" and
        .state == "readoption-start-authorized" and .attempt == $attempt and
        .run_dir == $run and .wave_dir == $wave and .node == 27 and
        .candidate_image == $image and .candidate_image_id == $image_id and
        .prior_container_generation == $generation and
        .readoption_authorization_sha256 == $readoption_sha and
        .previous_failed_containment_sha256 ==
          (if $previous_sha == "__NULL__" then null else $previous_sha end) and
        .allowed_action == "same-container-start" and .restart_policy_during_start == "no" and
        .managed_recovery_payments_authorized == false and
        .protocol_pow_claim_transactions_authorized == true and
        .unexpected_wallet_transactions_authorized == false and
        .key_generation_authorized == false and .address_generation_authorized == false and
        (.created_at | type) == "string"
    ' "$path" >/dev/null
}

publish_readoption_start_authorization()
{
    local attempt="$1" generation="$2" path readoption previous_sha=__NULL__ previous inspect
    path=$(readoption_attempt_path "$attempt" START-AUTHORIZED) || return 1
    [[ ! -e "$path" && ! -L "$path" ]] || return 1
    readoption=$(readoption_authorization_path) || return 1
    verify_candidate_readoption_authorization "$TARGET_NODE" \
        "$(jq -er '.contained_container_generation' "$readoption")" || return 1
    [[ "$(container_generation_for "$TARGET_NODE")" == "$generation" ]] || return 1
    inspect=$(docker inspect "$TARGET_CONTAINER") || return 1
    jq -e --arg image "$CANDIDATE_IMAGE_REF" --arg image_id "$CANDIDATE_IMAGE_ID" '
        length == 1 and .[0].State.Running == false and .[0].State.Pid == 0 and
        .[0].State.Restarting == false and .[0].HostConfig.RestartPolicy.Name == "no" and
        .[0].Config.Image == $image and .[0].Image == $image_id
    ' >/dev/null <<< "$inspect" || return 1
    if ((attempt > 1)); then
        previous=$(readoption_attempt_path "$((attempt - 1))" FAILED-CONTAINED) || return 1
        verify_readoption_failed_containment_record "$((attempt - 1))" || return 1
        previous_sha=$(sha256sum "$previous" | awk '{print $1}') || return 1
    fi
    jq -n --argjson attempt "$attempt" --arg run "$TARGET_RUN" --arg wave "$TARGET_WAVE" \
        --arg image "$CANDIDATE_IMAGE_REF" --arg image_id "$CANDIDATE_IMAGE_ID" \
        --arg generation "$generation" \
        --arg readoption_sha "$(sha256sum "$readoption" | awk '{print $1}')" \
        --arg previous_sha "$previous_sha" --arg created_at "$(date -u +%FT%TZ)" '
        {schema:1,transaction:"v30.1.4-fleet-rollout",state:"readoption-start-authorized",
         attempt:$attempt,run_dir:$run,wave_dir:$wave,node:27,candidate_image:$image,
         candidate_image_id:$image_id,prior_container_generation:$generation,
         readoption_authorization_sha256:$readoption_sha,
         previous_failed_containment_sha256:
           (if $previous_sha == "__NULL__" then null else $previous_sha end),
         allowed_action:"same-container-start",restart_policy_during_start:"no",
         managed_recovery_payments_authorized:false,
         protocol_pow_claim_transactions_authorized:true,
         unexpected_wallet_transactions_authorized:false,
         key_generation_authorized:false,address_generation_authorized:false,
         created_at:$created_at}' | atomic_write_json "$path" || return 1
    verify_readoption_start_authorization "$attempt"
}

verify_readoption_started()
{
    local attempt="$1" path authorization authorization_sha prior generation
    local old_id old_started old_vpn old_vpn_started id started vpn vpn_started
    path=$(readoption_attempt_path "$attempt" STARTED) || return 1
    authorization=$(readoption_attempt_path "$attempt" START-AUTHORIZED) || return 1
    protected_root_file "$path" || return 1
    verify_readoption_start_authorization "$attempt" || return 1
    authorization_sha=$(sha256sum "$authorization" | awk '{print $1}') || return 1
    prior=$(jq -er '.prior_container_generation' "$authorization") || return 1
    generation=$(jq -er '.started_container_generation' "$path") || return 1
    readoption_generation_has_original_lineage "$generation" || return 1
    IFS='|' read -r old_id old_started old_vpn old_vpn_started <<< "$prior" || return 1
    IFS='|' read -r id started vpn vpn_started <<< "$generation" || return 1
    [[ "$id" == "$old_id" && "$started" != "$old_started" &&
       "$vpn" == "$old_vpn" && "$vpn_started" == "$old_vpn_started" ]] || return 1
    jq -e --argjson attempt "$attempt" --arg run "$TARGET_RUN" --arg wave "$TARGET_WAVE" \
        --arg prior "$prior" --arg generation "$generation" --arg auth_sha "$authorization_sha" \
        --arg image "$CANDIDATE_IMAGE_REF" --arg image_id "$CANDIDATE_IMAGE_ID" '
        . == {schema:1,transaction:"v30.1.4-fleet-rollout",state:"readoption-started",
          attempt:$attempt,run_dir:$run,wave_dir:$wave,node:27,candidate_image:$image,
          candidate_image_id:$image_id,prior_container_generation:$prior,
          started_container_generation:$generation,start_authorization_sha256:$auth_sha,
          restart_policy:"no",container_running_when_recorded:.container_running_when_recorded,
          managed_recovery_payment_created:false,
          unexpected_wallet_transaction_created:false,
          created_at:.created_at} and (.created_at | type) == "string"
          and (.container_running_when_recorded | type) == "boolean"
    ' "$path" >/dev/null
}

publish_readoption_started()
{
    local attempt="$1" path authorization prior generation inspect running
    path=$(readoption_attempt_path "$attempt" STARTED) || return 1
    if [[ -e "$path" || -L "$path" ]]; then
        verify_readoption_started "$attempt"
        return
    fi
    authorization=$(readoption_attempt_path "$attempt" START-AUTHORIZED) || return 1
    verify_readoption_start_authorization "$attempt" || return 1
    prior=$(jq -er '.prior_container_generation' "$authorization") || return 1
    generation=$(container_generation_for "$TARGET_NODE") || return 1
    inspect=$(docker inspect "$TARGET_CONTAINER") || return 1
    running=$(jq -er --arg image "$CANDIDATE_IMAGE_REF" --arg image_id "$CANDIDATE_IMAGE_ID" '
        select(length == 1 and .[0].State.Restarting == false and
          .[0].HostConfig.RestartPolicy.Name == "no" and
          .[0].Config.Image == $image and .[0].Image == $image_id and
          ((.[0].State.Running == true and .[0].State.Pid > 0) or
           (.[0].State.Running == false and .[0].State.Pid == 0))) |
        .[0].State.Running
    ' <<< "$inspect") || return 1
    [[ "$generation" != "$prior" ]] || return 1
    jq -n --argjson attempt "$attempt" --arg run "$TARGET_RUN" --arg wave "$TARGET_WAVE" \
        --arg image "$CANDIDATE_IMAGE_REF" --arg image_id "$CANDIDATE_IMAGE_ID" \
        --arg prior "$prior" --arg generation "$generation" \
        --arg auth_sha "$(sha256sum "$authorization" | awk '{print $1}')" \
        --argjson running "$running" \
        --arg created_at "$(date -u +%FT%TZ)" '
        {schema:1,transaction:"v30.1.4-fleet-rollout",state:"readoption-started",
         attempt:$attempt,run_dir:$run,wave_dir:$wave,node:27,candidate_image:$image,
         candidate_image_id:$image_id,prior_container_generation:$prior,
         started_container_generation:$generation,start_authorization_sha256:$auth_sha,
         restart_policy:"no",container_running_when_recorded:$running,
         managed_recovery_payment_created:false,
         unexpected_wallet_transaction_created:false,
         created_at:$created_at}' | atomic_write_json "$path" || return 1
    verify_readoption_started "$attempt"
}

verify_readoption_policy_promotion_authorization()
{
    local attempt="$1" path started staking_log pow_log generation
    local started_sha staking_sha pow_sha
    path=$(readoption_attempt_path "$attempt" POLICY-PROMOTION-AUTHORIZED) || return 1
    started=$(readoption_attempt_path "$attempt" STARTED) || return 1
    staking_log="$(readoption_attempt_dir)/attempt-$(printf '%02d' "$attempt")-staking.log"
    pow_log="$(readoption_attempt_dir)/attempt-$(printf '%02d' "$attempt")-pow.log"
    for protected in "$path" "$started" "$staking_log" "$pow_log"; do
        protected_root_file "$protected" || return 1
    done
    verify_readoption_started "$attempt" || return 1
    verify_readoption_phase_log "$attempt" staking || return 1
    verify_readoption_phase_log "$attempt" pow || return 1
    generation=$(jq -er '.started_container_generation' "$started") || return 1
    started_sha=$(sha256sum "$started" | awk '{print $1}') || return 1
    staking_sha=$(sha256sum "$staking_log" | awk '{print $1}') || return 1
    pow_sha=$(sha256sum "$pow_log" | awk '{print $1}') || return 1
    jq -e --argjson attempt "$attempt" --arg run "$TARGET_RUN" --arg wave "$TARGET_WAVE" \
        --arg image "$CANDIDATE_IMAGE_REF" --arg image_id "$CANDIDATE_IMAGE_ID" \
        --arg generation "$generation" --arg started_sha "$started_sha" \
        --arg staking_sha "$staking_sha" --arg pow_sha "$pow_sha" '
        (keys | sort) == (["schema","transaction","state","attempt","run_dir",
          "wave_dir","node","candidate_image","candidate_image_id",
          "container_generation","started_evidence_sha256",
          "staking_activation_log_sha256","pow_activation_log_sha256",
          "from_restart_policy","to_restart_policy","runtime_activation_proven",
          "managed_recovery_payments_authorized",
          "protocol_pow_claim_transactions_authorized",
          "unexpected_wallet_transactions_authorized",
          "key_generation_authorized","address_generation_authorized","created_at"] | sort) and
        .schema == 1 and .transaction == "v30.1.4-fleet-rollout" and
        .state == "readoption-policy-promotion-authorized" and .attempt == $attempt and
        .run_dir == $run and .wave_dir == $wave and .node == 27 and
        .candidate_image == $image and .candidate_image_id == $image_id and
        .container_generation == $generation and .started_evidence_sha256 == $started_sha and
        .staking_activation_log_sha256 == $staking_sha and
        .pow_activation_log_sha256 == $pow_sha and .from_restart_policy == {name:"no",maximum_retry_count:0} and
        .to_restart_policy == {name:"on-failure",maximum_retry_count:3} and
        .runtime_activation_proven == true and
        .managed_recovery_payments_authorized == false and
        .protocol_pow_claim_transactions_authorized == true and
        .unexpected_wallet_transactions_authorized == false and
        .key_generation_authorized == false and
        .address_generation_authorized == false and (.created_at | type) == "string"
    ' "$path" >/dev/null
}

publish_readoption_policy_promotion_authorization()
{
    local attempt="$1" path started staking_log pow_log generation
    path=$(readoption_attempt_path "$attempt" POLICY-PROMOTION-AUTHORIZED) || return 1
    if [[ -e "$path" || -L "$path" ]]; then
        verify_readoption_policy_promotion_authorization "$attempt"
        return
    fi
    started=$(readoption_attempt_path "$attempt" STARTED) || return 1
    staking_log="$(readoption_attempt_dir)/attempt-$(printf '%02d' "$attempt")-staking.log"
    pow_log="$(readoption_attempt_dir)/attempt-$(printf '%02d' "$attempt")-pow.log"
    verify_readoption_live_state "$READOPTION_GENERATION" true no || return 1
    verify_readoption_active_phase_state on || return 1
    verify_readoption_started "$attempt" || return 1
    verify_readoption_phase_log "$attempt" staking || return 1
    verify_readoption_phase_log "$attempt" pow || return 1
    generation=$(jq -er '.started_container_generation' "$started") || return 1
    [[ "$generation" == "$READOPTION_GENERATION" ]] || return 1
    jq -n --argjson attempt "$attempt" --arg run "$TARGET_RUN" --arg wave "$TARGET_WAVE" \
        --arg image "$CANDIDATE_IMAGE_REF" --arg image_id "$CANDIDATE_IMAGE_ID" \
        --arg generation "$generation" \
        --arg started_sha "$(sha256sum "$started" | awk '{print $1}')" \
        --arg staking_sha "$(sha256sum "$staking_log" | awk '{print $1}')" \
        --arg pow_sha "$(sha256sum "$pow_log" | awk '{print $1}')" \
        --arg created_at "$(date -u +%FT%TZ)" '
        {schema:1,transaction:"v30.1.4-fleet-rollout",
         state:"readoption-policy-promotion-authorized",attempt:$attempt,run_dir:$run,
         wave_dir:$wave,node:27,candidate_image:$image,candidate_image_id:$image_id,
         container_generation:$generation,started_evidence_sha256:$started_sha,
         staking_activation_log_sha256:$staking_sha,pow_activation_log_sha256:$pow_sha,
         from_restart_policy:{name:"no",maximum_retry_count:0},
         to_restart_policy:{name:"on-failure",maximum_retry_count:3},
         runtime_activation_proven:true,managed_recovery_payments_authorized:false,
         protocol_pow_claim_transactions_authorized:true,
         unexpected_wallet_transactions_authorized:false,key_generation_authorized:false,
         address_generation_authorized:false,created_at:$created_at}' |
        atomic_write_json "$path" || return 1
    verify_readoption_policy_promotion_authorization "$attempt"
}

verify_readoption_failed_containment_record()
{
    local attempt="$1" path started started_sha generation started_generation
    local id started_at vpn vpn_started recorded_id recorded_started recorded_vpn
    local recorded_vpn_started
    path=$(readoption_attempt_path "$attempt" FAILED-CONTAINED) || return 1
    started=$(readoption_attempt_path "$attempt" STARTED) || return 1
    protected_root_file "$path" || return 1
    verify_readoption_started "$attempt" || return 1
    started_sha=$(sha256sum "$started" | awk '{print $1}') || return 1
    generation=$(jq -er '.container_generation' "$path") || return 1
    started_generation=$(jq -er '.started_container_generation' "$started") || return 1
    readoption_generation_has_original_lineage "$generation" || return 1
    IFS='|' read -r id started_at vpn vpn_started <<< "$generation" || return 1
    IFS='|' read -r recorded_id recorded_started recorded_vpn recorded_vpn_started \
        <<< "$started_generation" || return 1
    [[ "$id" == "$recorded_id" && "$vpn" == "$recorded_vpn" &&
       "$vpn_started" == "$recorded_vpn_started" && -n "$started_at" ]] || return 1
    jq -e --argjson attempt "$attempt" --arg run "$TARGET_RUN" --arg wave "$TARGET_WAVE" \
        --arg generation "$generation" --arg started_sha "$started_sha" \
        --arg image "$CANDIDATE_IMAGE_REF" --arg image_id "$CANDIDATE_IMAGE_ID" '
        .schema == 1 and .transaction == "v30.1.4-fleet-rollout" and
        .state == "readoption-failed-contained" and .attempt == $attempt and
        .run_dir == $run and .wave_dir == $wave and .node == 27 and
        .candidate_image == $image and .candidate_image_id == $image_id and
        .container_generation == $generation and .started_evidence_sha256 == $started_sha and
        .restart_policy == "no" and .container_running == false and .container_pid == 0 and
        .shutdown_proves_runtime_inactive == true and .result_published == false and
        (.created_at | type) == "string"
    ' "$path" >/dev/null
}

verify_readoption_failed_containment()
{
    local attempt="$1" path generation inspect
    path=$(readoption_attempt_path "$attempt" FAILED-CONTAINED) || return 1
    verify_readoption_failed_containment_record "$attempt" || return 1
    generation=$(jq -er '.container_generation' "$path") || return 1
    [[ "$generation" == "$(container_generation_for "$TARGET_NODE")" ]] || return 1
    inspect=$(docker inspect "$TARGET_CONTAINER") || return 1
    jq -e --arg image "$CANDIDATE_IMAGE_REF" --arg image_id "$CANDIDATE_IMAGE_ID" '
        length == 1 and .[0].State.Running == false and .[0].State.Pid == 0 and
        .[0].State.Restarting == false and .[0].HostConfig.RestartPolicy.Name == "no" and
        .[0].Config.Image == $image and .[0].Image == $image_id
    ' >/dev/null <<< "$inspect"
}

publish_readoption_failed_containment()
{
    local attempt="$1" path started generation inspect
    path=$(readoption_attempt_path "$attempt" FAILED-CONTAINED) || return 1
    if [[ -e "$path" || -L "$path" ]]; then
        verify_readoption_failed_containment "$attempt"
        return
    fi
    started=$(readoption_attempt_path "$attempt" STARTED) || return 1
    verify_readoption_started "$attempt" || return 1
    generation=$(container_generation_for "$TARGET_NODE") || return 1
    inspect=$(docker inspect "$TARGET_CONTAINER") || return 1
    jq -e 'length == 1 and .[0].State.Running == false and .[0].State.Pid == 0 and
        .[0].State.Restarting == false and .[0].HostConfig.RestartPolicy.Name == "no"' \
        >/dev/null <<< "$inspect" || return 1
    jq -n --argjson attempt "$attempt" --arg run "$TARGET_RUN" --arg wave "$TARGET_WAVE" \
        --arg image "$CANDIDATE_IMAGE_REF" --arg image_id "$CANDIDATE_IMAGE_ID" \
        --arg generation "$generation" \
        --arg started_sha "$(sha256sum "$started" | awk '{print $1}')" \
        --arg created_at "$(date -u +%FT%TZ)" '
        {schema:1,transaction:"v30.1.4-fleet-rollout",state:"readoption-failed-contained",
         attempt:$attempt,run_dir:$run,wave_dir:$wave,node:27,candidate_image:$image,
         candidate_image_id:$image_id,container_generation:$generation,
         started_evidence_sha256:$started_sha,restart_policy:"no",container_running:false,
         container_pid:0,shutdown_proves_runtime_inactive:true,result_published:false,
         created_at:$created_at}' | atomic_write_json "$path" || return 1
    verify_readoption_failed_containment "$attempt"
}

verify_readoption_attempt_prefix()
{
    local attempt state path last=0 last_state=none
    local has_auth has_started has_policy has_failed has_audit has_staking has_pow audit
    local dir
    dir=$(readoption_attempt_dir) || return 1
    if [[ ! -e "$dir" && ! -L "$dir" ]]; then
        printf '%s\n' '0:none'
        return 0
    fi
    [[ -d "$dir" && ! -L "$dir" && "$(realpath -e -- "$dir")" == "$dir" &&
       "$(stat -c '%u:%g:%a' "$dir")" == 0:0:700 ]] || return 1
    [[ -z "$(find "$dir" -mindepth 1 -maxdepth 1 ! -type f -print -quit)" ]] || return 1
    while IFS= read -r path; do
        case "${path##*/}" in
            attempt-0[1-3]-START-AUTHORIZED.json|attempt-0[1-3]-STARTED.json|\
            attempt-0[1-3]-POLICY-PROMOTION-AUTHORIZED.json|\
            attempt-0[1-3]-FAILED-CONTAINED.json|\
            attempt-0[1-3]-WALLET-SEND-AUDIT.json|attempt-0[1-3]-staking.log|\
            attempt-0[1-3]-pow.log|.attempt-0[1-3]-*-activation.*.partial|\
            .json-evidence.[[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]]|\
            .exclusive-json.[[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]])
                [[ ! -L "$path" && "$(realpath -e -- "$path")" == "$path" &&
                   "$(stat -c '%u:%g:%a' "$path")" == 0:0:600 ]] || return 1
                ;;
            *) return 1 ;;
        esac
    done < <(find "$dir" -mindepth 1 -maxdepth 1 -type f -print | sort)
    for attempt in $(seq 1 "$MAX_READOPTION_ATTEMPTS"); do
        has_auth=0
        has_started=0
        has_policy=0
        has_failed=0
        has_audit=0
        has_staking=0
        has_pow=0
        path=$(readoption_attempt_path "$attempt" START-AUTHORIZED) || return 1
        [[ ! -e "$path" && ! -L "$path" ]] || has_auth=1
        path=$(readoption_attempt_path "$attempt" STARTED) || return 1
        [[ ! -e "$path" && ! -L "$path" ]] || has_started=1
        path=$(readoption_attempt_path "$attempt" POLICY-PROMOTION-AUTHORIZED) || return 1
        [[ ! -e "$path" && ! -L "$path" ]] || has_policy=1
        path=$(readoption_attempt_path "$attempt" FAILED-CONTAINED) || return 1
        [[ ! -e "$path" && ! -L "$path" ]] || has_failed=1
        audit=$(wallet_send_audit_path "$attempt") || return 1
        [[ ! -e "$audit" && ! -L "$audit" ]] || has_audit=1
        path="$dir/attempt-$(printf '%02d' "$attempt")-staking.log"
        [[ ! -e "$path" && ! -L "$path" ]] || has_staking=1
        path="$dir/attempt-$(printf '%02d' "$attempt")-pow.log"
        [[ ! -e "$path" && ! -L "$path" ]] || has_pow=1
        if ((has_auth == 0)); then
            ((has_started == 0 && has_policy == 0 && has_failed == 0 && has_audit == 0 &&
              has_staking == 0 && has_pow == 0)) ||
                return 1
            continue
        fi
        ((attempt == last + 1)) || return 1
        verify_readoption_start_authorization "$attempt" || return 1
        last=$attempt
        last_state=authorized
        if ((has_started == 1)); then
            verify_readoption_started "$attempt" || return 1
            last_state=started
        else
            ((has_staking == 0 && has_pow == 0)) || return 1
        fi
        ((has_pow == 0 || has_staking == 1)) || return 1
        if ((has_staking == 1)); then
            verify_readoption_phase_log "$attempt" staking || return 1
        fi
        if ((has_pow == 1)); then
            verify_readoption_phase_log "$attempt" pow || return 1
        fi
        if ((has_policy == 1)); then
            ((has_started == 1 && has_staking == 1 && has_pow == 1)) || return 1
            verify_readoption_policy_promotion_authorization "$attempt" || return 1
        last_state='policy-authorized'
        fi
        if ((has_audit == 1)); then
            ((has_started == 1 && has_staking == 1 && has_pow == 1)) || return 1
            verify_wallet_send_audit "$attempt" || return 1
        fi
        if ((has_failed == 1)); then
            ((has_started == 1)) || return 1
            verify_readoption_failed_containment_record "$attempt" || return 1
            last_state='failed-contained'
        fi
        if ((attempt < MAX_READOPTION_ATTEMPTS)); then
            path=$(readoption_attempt_path "$((attempt + 1))" START-AUTHORIZED) || return 1
            if [[ -e "$path" || -L "$path" ]]; then
                [[ "$last_state" == failed-contained ]] || return 1
            fi
        fi
    done
    printf '%s:%s\n' "$last" "$last_state"
}

cleanup_readoption_publication_residue()
{
    local dir path name
    ((ADOPTION_LOCK_HELD == 1 && WAVE_LOCKS_HELD == 1)) || return 1
    dir=$(readoption_attempt_dir) || return 1
    [[ ! -e "$dir" && ! -L "$dir" ]] && return 0
    [[ -d "$dir" && ! -L "$dir" && "$(realpath -e -- "$dir")" == "$dir" &&
       "$(stat -c '%u:%g:%a' "$dir")" == 0:0:700 ]] || return 1
    while IFS= read -r path; do
        name=${path##*/}
        [[ "$name" =~ ^[.](json-evidence|exclusive-json)[.][[:alnum:]]{6}$ &&
           -f "$path" && ! -L "$path" && "$(realpath -e -- "$path")" == "$path" &&
           "$(stat -c '%u:%g:%a' "$path")" == 0:0:600 ]] || return 1
        rm -f -- "$path" || return 1
    done < <(find "$dir" -mindepth 1 -maxdepth 1 -type f \
        \( -name '.json-evidence.??????' -o -name '.exclusive-json.??????' \) -print | sort)
    sync -f "$dir"
}

cleanup_readoption_partial_logs()
{
    local dir path
    dir=$(readoption_attempt_dir) || return 1
    [[ -d "$dir" && ! -L "$dir" && "$(realpath -e -- "$dir")" == "$dir" &&
       "$(stat -c '%u:%g:%a' "$dir")" == 0:0:700 ]] || return 1
    while IFS= read -r path; do
        [[ "${path##*/}" =~ ^[.]attempt-0[1-3]-(staking|pow)-activation[.][1-9][0-9]*[.]partial$ &&
           ! -L "$path" && "$(realpath -e -- "$path")" == "$path" &&
           "$(stat -c '%u:%g' "$path")" == 0:0 ]] || return 1
        rm -f -- "$path" || return 1
    done < <(find "$dir" -mindepth 1 -maxdepth 1 -type f -name '.*.partial' -print | sort)
    sync -f "$dir"
}

contain_readoption_restart_residue()
{
    local inspect generation
    ADOPTION_MUTATED=1
    docker update --restart=no "$TARGET_CONTAINER" >/dev/null || return 1
    if [[ "$(docker inspect -f '{{.State.Running}}' "$TARGET_CONTAINER" 2>/dev/null)" == true ]]; then
        wallet_rpc_for "$TARGET_NODE" setpowmining false 1 1 >/dev/null 2>&1 || true
        wallet_rpc_for "$TARGET_NODE" staking false >/dev/null 2>&1 || true
        wallet_rpc_for "$TARGET_NODE" walletlock >/dev/null 2>&1 || true
        rpc_for "$TARGET_NODE" stop >/dev/null 2>&1 || true
        timeout --foreground --kill-after=10 45 docker stop -t 30 "$TARGET_CONTAINER" \
            >/dev/null 2>&1 || docker kill "$TARGET_CONTAINER" >/dev/null 2>&1 || return 1
    fi
    inspect=$(docker inspect "$TARGET_CONTAINER") || return 1
    jq -e --arg image "$CANDIDATE_IMAGE_REF" --arg image_id "$CANDIDATE_IMAGE_ID" '
        length == 1 and .[0].State.Running == false and .[0].State.Pid == 0 and
        .[0].State.Restarting == false and .[0].State.Paused == false and
        .[0].HostConfig.RestartPolicy.Name == "no" and
        .[0].HostConfig.RestartPolicy.MaximumRetryCount == 0 and
        .[0].Config.Image == $image and .[0].Image == $image_id
    ' >/dev/null <<< "$inspect" || return 1
    generation=$(container_generation_for "$TARGET_NODE") || return 1
    readoption_generation_has_original_lineage "$generation" || return 1
    READOPTION_GENERATION=$generation
}

ensure_readoption_candidate_running()
{
    local attempt auth started generation inspect prior prefix last last_state running
    local dir
    dir=$(readoption_attempt_dir) || return 1
    if [[ ! -e "$dir" && ! -L "$dir" ]]; then
        install -d -m 700 -o root -g root "$dir" || return 1
        sync -f "$TARGET_WAVE" || return 1
    fi
    [[ -d "$dir" && ! -L "$dir" && "$(realpath -e -- "$dir")" == "$dir" &&
       "$(stat -c '%u:%g:%a' "$dir")" == 0:0:700 ]] || return 1
    prefix=$(verify_readoption_attempt_prefix) || return 1
    IFS=: read -r last last_state <<< "$prefix" || return 1
    if ((last > 0)) && [[ "$last_state" == failed-contained ]]; then
        verify_readoption_failed_containment "$last" || return 1
    fi
    for attempt in $(seq 1 "$MAX_READOPTION_ATTEMPTS"); do
        auth=$(readoption_attempt_path "$attempt" START-AUTHORIZED) || return 1
        started=$(readoption_attempt_path "$attempt" STARTED) || return 1
        if [[ -e "$(readoption_attempt_path "$attempt" FAILED-CONTAINED)" ||
              -L "$(readoption_attempt_path "$attempt" FAILED-CONTAINED)" ]]; then
            verify_readoption_failed_containment "$attempt" || return 1
            last=$attempt
            continue
        fi
        if [[ -e "$auth" || -L "$auth" ]]; then
            verify_readoption_start_authorization "$attempt" || return 1
        else
            ((attempt == last + 1)) || return 1
            generation=$(container_generation_for "$TARGET_NODE") || return 1
            publish_readoption_start_authorization "$attempt" "$generation" || return 1
        fi
        prior=$(jq -er '.prior_container_generation' "$auth") || return 1
        if [[ ! -e "$started" && ! -L "$started" ]]; then
            generation=$(container_generation_for "$TARGET_NODE") || return 1
            inspect=$(docker inspect "$TARGET_CONTAINER") || return 1
            if [[ "$generation" == "$prior" ]]; then
                jq -e 'length == 1 and .[0].State.Running == false and .[0].State.Pid == 0 and
                    .[0].HostConfig.RestartPolicy.Name == "no"' >/dev/null <<< "$inspect" ||
                    return 1
                [[ "$(container_generation_for "$TARGET_NODE")" == "$prior" ]] || return 1
                READOPTION_ATTEMPT=$attempt
                ADOPTION_MUTATED=1
                docker start "${prior%%|*}" >/dev/null || return 1
            else
                # A prior invocation may have crossed docker start before it
                # published STARTED. Reentry only adopts that residue when the
                # same authorized container/VPN lineage is still running with
                # restart disabled; otherwise it fails closed for inspection.
                readoption_generation_has_original_lineage "$generation" || return 1
                jq -e --arg image "$CANDIDATE_IMAGE_REF" --arg image_id "$CANDIDATE_IMAGE_ID" '
                    length == 1 and .[0].State.Restarting == false and
                    ((.[0].State.Running == true and .[0].State.Pid > 0) or
                     (.[0].State.Running == false and .[0].State.Pid == 0)) and
                    .[0].HostConfig.RestartPolicy.Name == "no" and
                    .[0].HostConfig.RestartPolicy.MaximumRetryCount == 0 and
                    .[0].Config.Image == $image and .[0].Image == $image_id
                ' >/dev/null <<< "$inspect" || return 1
            fi
            publish_readoption_started "$attempt" || return 1
        else
            verify_readoption_started "$attempt" || return 1
        fi
        generation=$(jq -er '.started_container_generation' "$started") || return 1
        inspect=$(docker inspect "$TARGET_CONTAINER") || return 1
        if [[ "$generation" != "$(container_generation_for "$TARGET_NODE")" ]]; then
            if [[ -e "$(readoption_attempt_path "$attempt" FAILED-CONTAINED)" ||
                  -L "$(readoption_attempt_path "$attempt" FAILED-CONTAINED)" ]]; then
                verify_readoption_failed_containment "$attempt" || return 1
                continue
            fi
            READOPTION_ATTEMPT=$attempt
            contain_readoption_restart_residue || return 1
            publish_readoption_failed_containment "$attempt" || return 1
            last=$attempt
            continue
        fi
        running=$(jq -er 'select(length == 1 and .[0].State.Restarting == false and
            ((.[0].HostConfig.RestartPolicy.Name == "no" and
              .[0].HostConfig.RestartPolicy.MaximumRetryCount == 0) or
             (.[0].HostConfig.RestartPolicy.Name == "on-failure" and
              .[0].HostConfig.RestartPolicy.MaximumRetryCount == 3)) and
            ((.[0].State.Running == true and .[0].State.Pid > 0) or
             (.[0].State.Running == false and .[0].State.Pid == 0))) |
            .[0].State.Running' <<< "$inspect") || return 1
        if [[ "$running" == true ]]; then
            ADOPTION_MUTATED=1
            READOPTION_ATTEMPT=$attempt
            READOPTION_GENERATION=$generation
            return 0
        fi
        docker update --restart=no "$TARGET_CONTAINER" >/dev/null || return 1
        publish_readoption_failed_containment "$attempt" || return 1
        last=$attempt
    done
    return 1
}

publish_activation_supersession()
{
    local path authorization activation containment containment_complete compatibility
    local original_pow_log staking_log pow_log start_authorization started policy wallet_audit
    local chain_json staking_relative pow_relative wallet_audit_relative
    local old_generation new_generation old_id old_started old_vpn old_vpn_started
    local new_id new_started new_vpn new_vpn_started
    path=$(supersession_path) || return 1
    if [[ -e "$path" || -L "$path" ]]; then
        verify_candidate_activation_marker "$TARGET_NODE"
        return
    fi
    [[ "$READOPTION_ATTEMPT" =~ ^[1-3]$ && -n "$READOPTION_GENERATION" ]] || return 1
    authorization=$(readoption_authorization_path) || return 1
    activation=$(wave_node_activation_path "$TARGET_NODE") || return 1
    containment=$(wave_node_containment_path "$TARGET_NODE") || return 1
    containment_complete=$(wave_containment_complete_path) || return 1
    compatibility=$(resume_receipt_path) || return 1
    original_pow_log="$TARGET_WAVE/node-27-pow-activation.log"
    start_authorization=$(readoption_attempt_path "$READOPTION_ATTEMPT" START-AUTHORIZED) ||
        return 1
    started=$(readoption_attempt_path "$READOPTION_ATTEMPT" STARTED) || return 1
    policy=$(readoption_attempt_path "$READOPTION_ATTEMPT" POLICY-PROMOTION-AUTHORIZED) ||
        return 1
    wallet_audit=$(wallet_send_audit_path) || return 1
    staking_log="$(readoption_attempt_dir)/attempt-$(printf '%02d' \
        "$READOPTION_ATTEMPT")-staking.log"
    pow_log="$(readoption_attempt_dir)/attempt-$(printf '%02d' "$READOPTION_ATTEMPT")-pow.log"
    for protected in "$authorization" "$original_pow_log" "$start_authorization" "$started" \
        "$policy" "$staking_log" "$pow_log" "$wallet_audit"; do
        protected_root_file "$protected" || return 1
    done
    verify_readoption_started "$READOPTION_ATTEMPT" || return 1
    [[ "$(jq -er '.container_running_when_recorded' "$started")" == true ]] || return 1
    verify_readoption_policy_promotion_authorization "$READOPTION_ATTEMPT" || return 1
    verify_readoption_phase_log "$READOPTION_ATTEMPT" staking || return 1
    verify_readoption_phase_log "$READOPTION_ATTEMPT" pow || return 1
    verify_wallet_send_audit || return 1
    chain_json=$(readoption_attempt_chain_json "$READOPTION_ATTEMPT") || return 1
    staking_relative=${staking_log#"$TARGET_WAVE/"}
    pow_relative=${pow_log#"$TARGET_WAVE/"}
    wallet_audit_relative=${wallet_audit#"$TARGET_WAVE/"}
    old_generation=$(jq -er '.container_generation' "$activation") || return 1
    new_generation=$(container_generation_for "$TARGET_NODE") || return 1
    [[ "$new_generation" == "$READOPTION_GENERATION" &&
       "$new_generation" == "$(jq -er '.started_container_generation' "$started")" ]] || return 1
    verify_readoption_live_state "$new_generation" true on-failure || return 1
    IFS='|' read -r old_id old_started old_vpn old_vpn_started <<< "$old_generation" || return 1
    IFS='|' read -r new_id new_started new_vpn new_vpn_started <<< "$new_generation" || return 1
    [[ "$old_id" == "$new_id" && "$old_started" != "$new_started" &&
       "$old_vpn" == "$new_vpn" && "$old_vpn_started" == "$new_vpn_started" ]] || return 1
    [[ ! -e "$path" && ! -L "$path" ]] || return 1
    jq -n --argjson node "$TARGET_NODE" --arg run "$TARGET_RUN" --arg wave "$TARGET_WAVE" \
        --arg image "$CANDIDATE_IMAGE_REF" --arg image_id "$CANDIDATE_IMAGE_ID" \
        --arg old_generation "$old_generation" --arg new_generation "$new_generation" \
        --arg authorization_sha "$(sha256sum "$authorization" | awk '{print $1}')" \
        --arg activation_sha "$(sha256sum "$activation" | awk '{print $1}')" \
        --arg containment_sha "$(sha256sum "$containment" | awk '{print $1}')" \
        --arg containment_complete_sha "$(sha256sum "$containment_complete" | awk '{print $1}')" \
        --arg compatibility_sha "$(sha256sum "$compatibility" | awk '{print $1}')" \
        --arg helper_sha "$POW_START_HELPER_SHA256" \
        --arg original_pow_log_sha "$(sha256sum "$original_pow_log" | awk '{print $1}')" \
        --argjson successful_attempt "$READOPTION_ATTEMPT" \
        --arg start_authorization_sha "$(sha256sum "$start_authorization" | awk '{print $1}')" \
        --arg started_sha "$(sha256sum "$started" | awk '{print $1}')" \
        --arg policy_sha "$(sha256sum "$policy" | awk '{print $1}')" \
        --arg staking_path "$staking_relative" \
        --arg staking_sha "$(sha256sum "$staking_log" | awk '{print $1}')" \
        --arg pow_path "$pow_relative" --arg pow_sha "$(sha256sum "$pow_log" | awk '{print $1}')" \
        --arg wallet_audit_path "$wallet_audit_relative" \
        --arg wallet_audit_sha "$(sha256sum "$wallet_audit" | awk '{print $1}')" \
        --argjson attempt_chain "$chain_json" --arg created_at "$(date -u +%FT%TZ)" '
        {schema:1,transaction:"v30.1.4-fleet-rollout",
         state:"contained-activation-superseded",node:$node,run_dir:$run,wave_dir:$wave,
         reason:"transient-pow-helper-journal-tee-drain",candidate_image:$image,
         candidate_image_id:$image_id,original_container_generation:$old_generation,
         replacement_container_generation:$new_generation,
         readoption_authorization_sha256:$authorization_sha,
         original_activation_marker_sha256:$activation_sha,
         containment_marker_sha256:$containment_sha,
         containment_complete_sha256:$containment_complete_sha,
         resume_compatibility_sha256:$compatibility_sha,pow_start_helper_sha256:$helper_sha,
         original_pow_activation_log_sha256:$original_pow_log_sha,
         successful_readoption_attempt:$successful_attempt,
         successful_start_authorization_sha256:$start_authorization_sha,
         successful_started_evidence_sha256:$started_sha,
         policy_promotion_authorization_sha256:$policy_sha,
         successful_staking_activation_log_path:$staking_path,
         successful_staking_activation_log_sha256:$staking_sha,
         successful_pow_activation_log_path:$pow_path,
         successful_pow_activation_log_sha256:$pow_sha,
         wallet_send_audit_path:$wallet_audit_path,
         wallet_send_audit_sha256:$wallet_audit_sha,
         readoption_attempt_chain:$attempt_chain,same_container_restart:true,
         original_evidence_retained:true,managed_recovery_payment_created:false,
         protocol_pow_claim_transactions_authorized:true,
         unexpected_wallet_transaction_created:false,key_generation_authorized:false,
         address_generation_authorized:false,created_at:$created_at}' |
        atomic_write_json_exclusive "$path" || return 1
    verify_candidate_activation_marker "$TARGET_NODE"
}

wait_for_core_ready()
{
    local deadline=$((SECONDS + 600)) generation inspect network chain
    while ((SECONDS < deadline)); do
        generation=$(container_generation_for "$TARGET_NODE" 2>/dev/null || true)
        inspect=$(docker inspect "$TARGET_CONTAINER" 2>/dev/null || true)
        if [[ -n "$READOPTION_GENERATION" && "$generation" == "$READOPTION_GENERATION" ]] &&
           jq -e --arg image "$CANDIDATE_IMAGE_REF" --arg image_id "$CANDIDATE_IMAGE_ID" '
             length == 1 and .[0].Config.Image == $image and .[0].Image == $image_id and
             .[0].State.Running == true and .[0].State.Pid > 0 and
             .[0].State.Health.Status == "healthy" and .[0].State.Paused == false and
             .[0].State.Restarting == false and
             ((.[0].HostConfig.RestartPolicy.Name == "no" and
               .[0].HostConfig.RestartPolicy.MaximumRetryCount == 0) or
              (.[0].HostConfig.RestartPolicy.Name == "on-failure" and
               .[0].HostConfig.RestartPolicy.MaximumRetryCount == 3))
           ' >/dev/null <<< "$inspect" &&
           (verify_readoption_live_state "$READOPTION_GENERATION" true no ||
            verify_readoption_live_state "$READOPTION_GENERATION" true on-failure) &&
           verify_vpn_pair "$TARGET_NODE" && live_netns_matches "$TARGET_NODE" &&
           assert_no_reindex_directive "$TARGET_NODE" &&
           verify_no_reindex_log "$TARGET_NODE" && verify_replay_state "$TARGET_NODE"; then
            network=$(rpc_for "$TARGET_NODE" getnetworkinfo 2>/dev/null || true)
            chain=$(rpc_for "$TARGET_NODE" getblockchaininfo 2>/dev/null || true)
            if jq -e '.version == 300104 and .subversion == "/Blackcoin:30.1.4/" and
                    .networkactive == true and .connections_out >= 3' \
                    >/dev/null <<< "$network" &&
               jq -e '.chain == "main" and .initialblockdownload == false and
                    .headers >= .blocks and (.headers - .blocks) <= 2' \
                    >/dev/null <<< "$chain"; then
                return 0
            fi
        fi
        sleep 2
    done
    return 1
}

verify_preactivation_no_spend_state()
{
    local wallet staking mining recovery expected_fee current_fee temporary
    wallet=$(wallet_rpc_for "$TARGET_NODE" getwalletinfo) || return 1
    staking=$(wallet_rpc_for "$TARGET_NODE" getstakinginfo) || return 1
    mining=$(wallet_rpc_for "$TARGET_NODE" getpowmininginfo) || return 1
    recovery=$(wallet_rpc_for "$TARGET_NODE" getpowclaimrecoveryinfo) || return 1
    jq -e '.unlocked_until == 0' >/dev/null <<< "$wallet" || return 1
    jq -e '.enabled == false and .staking == false and .worker_running == false and
        .allow_automatic_quantum_key_creation == false' >/dev/null <<< "$staking" || return 1
    jq -e '.enabled == false and .state == "disabled" and .hashrate == 0 and
        .live_claims == 0 and .blocking_quarantined_claims == 0 and
        .allow_automatic_quantum_key_creation == false' >/dev/null <<< "$mining" || return 1
    expected_fee=$(candidate_recovery_fee_for "$TARGET_NODE") || return 1
    current_fee=$(jq -er '.confirmed_resolution_fees | select(type == "number")' <<< "$recovery") ||
        return 1
    jq -en --argjson current "$current_fee" --argjson expected "$expected_fee" \
        '$current == $expected' >/dev/null || return 1
    temporary=$(mktemp "$TARGET_WAVE/.preactivation-txids.XXXXXX") || return 1
    capture_wallet_txid_set "$TARGET_NODE" "$temporary" || { rm -f -- "$temporary"; return 1; }
    cmp -s "$TARGET_WAVE/node-27-wallet-txids.prelaunch.json" "$temporary" || {
        rm -f -- "$temporary"
        return 1
    }
    rm -f -- "$temporary"
}

wait_for_runtime_gate()
{
    local fee deadline=$((SECONDS + 1200))
    fee=$(candidate_recovery_fee_for "$TARGET_NODE") || return 1
    while ((SECONDS < deadline)); do
        if verify_node_runtime_gate "$TARGET_NODE" "$fee"; then
            return 0
        fi
        sleep 5
    done
    return 1
}

verify_readoption_phase_log()
{
    local attempt="$1" phase="$2" log
    [[ "$attempt" =~ ^[1-3]$ && ( "$phase" == staking || "$phase" == pow ) ]] || return 1
    log="$(readoption_attempt_dir)/attempt-$(printf '%02d' "$attempt")-${phase}.log"
    protected_root_file "$log" || return 1
    grep -Fq 'complete node=27' "$log" || return 1
    if [[ "$phase" == staking ]]; then
        grep -Fq 'wallet=normally_unlocked pos=active' "$log"
    else
        grep -Fq 'pow=hashing' "$log"
    fi
}

run_readoption_phase()
{
    local phase="$1" path sha log partial worker_source wait_rc=0
    [[ "$phase" == staking || "$phase" == pow ]] || return 1
    if [[ "$phase" == staking ]]; then
        path=$NORMAL_UNLOCK_HELPER
        sha=$NORMAL_UNLOCK_HELPER_SHA256
    else
        path=$POW_START_HELPER
        sha=$POW_START_HELPER_SHA256
    fi
    log="$(readoption_attempt_dir)/attempt-$(printf '%02d' "$READOPTION_ATTEMPT")-${phase}.log"
    if [[ -e "$log" || -L "$log" ]]; then
        verify_readoption_phase_log "$READOPTION_ATTEMPT" "$phase"
        return
    fi
    partial="$(readoption_attempt_dir)/.attempt-$(printf '%02d' \
        "$READOPTION_ATTEMPT")-${phase}-activation.$$.partial"
    [[ ! -e "$partial" && ! -L "$partial" ]] || return 1
    worker_source=$(declare -f verify_activation_helper activate_one_node_phase) || return 1
    "$ADOPTION_PACKAGE_ROOT/tools/setsid" /bin/bash -c \
        "$worker_source"$'\n''activate_one_node_phase "$1" "$2" "$3" "$4"' \
        activation-worker "$phase" "$TARGET_NODE" "$path" "$sha" > "$partial" 2>&1 &
    READOPTION_WORKER_PID=$!
    if wait "$READOPTION_WORKER_PID"; then wait_rc=0; else wait_rc=$?; fi
    if kill -0 -- "-$READOPTION_WORKER_PID" 2>/dev/null; then
        return 1
    fi
    READOPTION_WORKER_PID=
    ((wait_rc == 0)) || return "$wait_rc"
    grep -Fq "complete node=27" "$partial" || return 1
    if [[ "$phase" == staking ]]; then
        grep -Fq 'wallet=normally_unlocked pos=active' "$partial" || return 1
    else
        grep -Fq 'pow=hashing' "$partial" || return 1
    fi
    chmod 600 "$partial" && chown root:root "$partial" && sync -f "$partial" || return 1
    ln -- "$partial" "$log" || return 1
    rm -f -- "$partial" || return 1
    sync -f "$(readoption_attempt_dir)"
}

readoption_attempt_chain_files()
{
    local successful_attempt="$1" attempt state path phase relative audit
    local dir prefix
    [[ "$successful_attempt" =~ ^[1-3]$ ]] || return 1
    dir=$(readoption_attempt_dir) || return 1
    prefix=$(verify_readoption_attempt_prefix) || return 1
    [[ "$prefix" == "$successful_attempt:policy-authorized" ]] || return 1
    [[ -d "$dir" && ! -L "$dir" && "$(realpath -e -- "$dir")" == "$dir" &&
       "$(stat -c '%u:%g:%a' "$dir")" == 0:0:700 ]] || return 1
    [[ -z "$(find "$dir" -mindepth 1 -maxdepth 1 ! -type f -print -quit)" ]] || return 1
    while IFS= read -r path; do
        [[ "${path##*/}" =~ ^attempt-0[1-3]-(START-AUTHORIZED|STARTED|POLICY-PROMOTION-AUTHORIZED|FAILED-CONTAINED|WALLET-SEND-AUDIT)[.]json$ ||
           "${path##*/}" =~ ^attempt-0[1-3]-(staking|pow)[.]log$ ]] || return 1
        protected_root_file "$path" || return 1
    done < <(find "$dir" -mindepth 1 -maxdepth 1 -type f -print | sort)
    for attempt in $(seq 1 "$MAX_READOPTION_ATTEMPTS"); do
        for state in START-AUTHORIZED STARTED POLICY-PROMOTION-AUTHORIZED FAILED-CONTAINED; do
            path=$(readoption_attempt_path "$attempt" "$state") || return 1
            if ((attempt <= successful_attempt)); then
                case "$state" in
                    START-AUTHORIZED)
                        verify_readoption_start_authorization "$attempt" || return 1
                        ;;
                    STARTED)
                        verify_readoption_started "$attempt" || return 1
                        ;;

                    POLICY-PROMOTION-AUTHORIZED)
                        if ((attempt == successful_attempt)); then
                            verify_readoption_policy_promotion_authorization "$attempt" || return 1
                        elif [[ -e "$path" || -L "$path" ]]; then
                            verify_readoption_policy_promotion_authorization "$attempt" || return 1
                        else
                            continue
                        fi
                        ;;

                    FAILED-CONTAINED)
                        if ((attempt < successful_attempt)); then
                            verify_readoption_failed_containment_record "$attempt" || return 1
                        else
                            [[ ! -e "$path" && ! -L "$path" ]] || return 1
                            continue
                        fi
                        ;;
                esac
                relative=${path#"$TARGET_WAVE/"}
                printf '%s\n' "$relative"
            else
                [[ ! -e "$path" && ! -L "$path" ]] || return 1
            fi
        done
        for phase in staking pow; do
            path="$dir/attempt-$(printf '%02d' "$attempt")-${phase}.log"
            if ((attempt == successful_attempt)); then
                protected_root_file "$path" || return 1
                relative=${path#"$TARGET_WAVE/"}
                printf '%s\n' "$relative"
            elif ((attempt < successful_attempt)); then
                if [[ -e "$path" || -L "$path" ]]; then
                    protected_root_file "$path" || return 1
                    relative=${path#"$TARGET_WAVE/"}
                    printf '%s\n' "$relative"
                fi
            else
                [[ ! -e "$path" && ! -L "$path" ]] || return 1
            fi
        done
        audit=$(wallet_send_audit_path "$attempt") || return 1
        if ((attempt == successful_attempt)); then
            verify_wallet_send_audit "$attempt" || return 1
            relative=${audit#"$TARGET_WAVE/"}
            printf '%s\n' "$relative"
        elif ((attempt < successful_attempt)); then
            if [[ -e "$audit" || -L "$audit" ]]; then
                protected_root_file "$audit" || return 1
                relative=${audit#"$TARGET_WAVE/"}
                printf '%s\n' "$relative"
            fi
        else
            [[ ! -e "$audit" && ! -L "$audit" ]] || return 1
        fi
    done
}

readoption_attempt_chain_json()
{
    local successful_attempt="$1" expected_text entry
    expected_text=$(readoption_attempt_chain_files "$successful_attempt") || return 1
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || return 1
        jq -cn --arg path "$entry" \
            --arg sha "$(sha256sum "$TARGET_WAVE/$entry" | awk '{print $1}')" \
            '{path:$path,sha256:$sha}' || return 1
    done <<< "$expected_text" | jq -cs 'sort_by(.path)'
}

verify_readoption_active_phase_state()
{
    local pow_state="$1" fee mining
    [[ "$pow_state" == off || "$pow_state" == on || "$pow_state" == either ]] || return 1
    [[ "$(container_generation_for "$TARGET_NODE")" == "$READOPTION_GENERATION" ]] || return 1
    verify_core_common "$TARGET_NODE" || return 1
    verify_replay_state "$TARGET_NODE" || return 1
    verify_staking "$TARGET_NODE" || return 1
    verify_donation_defaults_off "$TARGET_NODE" || return 1
    verify_postactivation_no_spend_state || return 1
    fee=$(candidate_recovery_fee_for "$TARGET_NODE") || return 1
    if [[ "$pow_state" == on ]]; then
        verify_standard_pow "$TARGET_NODE" "$fee"
        return
    fi
    mining=$(wallet_rpc_for "$TARGET_NODE" getpowmininginfo) || return 1
    if jq -e '.enabled == false and .state == "disabled" and .hashrate == 0 and
        .live_claims == 0 and .blocking_quarantined_claims == 0 and
        .allow_automatic_quantum_key_creation == false' >/dev/null <<< "$mining"; then
        return 0
    fi
    [[ "$pow_state" == either ]] || return 1
    verify_standard_pow "$TARGET_NODE" "$fee"
}

activate_or_resume_readoption_phases()
{
    local staking_log pow_log
    staking_log="$(readoption_attempt_dir)/attempt-$(printf '%02d' \
        "$READOPTION_ATTEMPT")-staking.log"
    pow_log="$(readoption_attempt_dir)/attempt-$(printf '%02d' \
        "$READOPTION_ATTEMPT")-pow.log"
    wait_for_core_ready || return 1
    if [[ -e "$staking_log" || -L "$staking_log" ]]; then
        verify_readoption_phase_log "$READOPTION_ATTEMPT" staking || return 1
        verify_readoption_active_phase_state either || return 1
    elif verify_preactivation_no_spend_state; then
        run_readoption_phase staking || return 1
        verify_readoption_active_phase_state off || return 1
    else
        # The helper may have completed immediately before an uncatchable
        # parent exit. Reprove the same generation and no-spend state, then
        # rerun the idempotent helper solely to publish its durable log.
        verify_readoption_active_phase_state either || return 1
        run_readoption_phase staking || return 1
    fi
    if [[ -e "$pow_log" || -L "$pow_log" ]]; then
        verify_readoption_phase_log "$READOPTION_ATTEMPT" pow || return 1
        verify_readoption_active_phase_state on || return 1
    else
        verify_readoption_active_phase_state either || return 1
        run_readoption_phase pow || return 1
        verify_readoption_active_phase_state on || return 1
    fi
}

verify_postactivation_no_spend_state()
{
    local expected_fee current_fee recovery
    expected_fee=$(candidate_recovery_fee_for "$TARGET_NODE") || return 1
    recovery=$(wallet_rpc_for "$TARGET_NODE" getpowclaimrecoveryinfo) || return 1
    current_fee=$(jq -er '.confirmed_resolution_fees | select(type == "number")' <<< "$recovery") ||
        return 1
    jq -en --argjson current "$current_fee" --argjson expected "$expected_fee" \
        '$current == $expected' >/dev/null || return 1
    verify_other_nodes_unchanged
}

verify_wallet_send_audit()
{
    local attempt=${1:-$READOPTION_ATTEMPT} path baseline baseline_sha generation
    path=$(wallet_send_audit_path "$attempt") || return 1
    baseline="$TARGET_WAVE/node-27-wallet-txids.prelaunch.json"
    protected_root_file "$path" || return 1
    protected_root_file "$baseline" || return 1
    baseline_sha=$(sha256sum "$baseline" | awk '{print $1}') || return 1
    generation=$(jq -er '.container_generation' "$path") || return 1
    readoption_generation_has_original_lineage "$generation" || return 1
    if [[ "$attempt" == "$READOPTION_ATTEMPT" && -n "$READOPTION_GENERATION" ]]; then
        [[ "$generation" == "$READOPTION_GENERATION" ]] || return 1
    fi
    jq -e --arg generation "$generation" --arg baseline_sha "$baseline_sha" \
        --arg run "$TARGET_RUN" --arg wave "$TARGET_WAVE" '
        (keys | sort) == (["schema","transaction","state","node","run_dir","wave_dir",
          "container_generation","prelaunch_wallet_txids_sha256",
          "observed_new_send_transactions",
          "authorized_protocol_pow_claim_txids","unexpected_send_transactions",
          "managed_recovery_payment_created","created_at"] | sort) and
        .schema == 1 and .transaction == "v30.1.4-fleet-rollout" and
        .state == "readoption-wallet-send-audited" and .node == 27 and
        .run_dir == $run and .wave_dir == $wave and
        .container_generation == $generation and
        .prelaunch_wallet_txids_sha256 == $baseline_sha and
        (.observed_new_send_transactions | type) == "array" and
        (.observed_new_send_transactions ==
          (.observed_new_send_transactions |
            sort_by([.txid,(.amount | tostring),(.fee | tostring),(.comment | tostring)]))) and
        all(.observed_new_send_transactions[];
          (keys | sort) == (["txid","comment","qq_shadow_pow_authored",
            "qq_shadow_pow_created_height","qq_shadow_pow_created_tip","fee","amount",
            "abandoned"] | sort) and
          (.txid | type) == "string" and (.txid | test("^[0-9a-f]{64}$")) and
          .comment == "PoW Claim" and .qq_shadow_pow_authored == "1" and
          (.qq_shadow_pow_created_height | type) == "string" and
          (.qq_shadow_pow_created_height | test("^[0-9]+$")) and
          (.qq_shadow_pow_created_tip | type) == "string" and
          (.qq_shadow_pow_created_tip | test("^[0-9a-f]{64}$")) and
          (.fee | type) == "number" and .fee <= 0 and
          (.amount | type) == "number" and .amount == 0 and .abandoned == false) and
        (.authorized_protocol_pow_claim_txids ==
          ([.observed_new_send_transactions[].txid] | unique | sort)) and
        (.authorized_protocol_pow_claim_txids | type) == "array" and
        (.authorized_protocol_pow_claim_txids ==
          (.authorized_protocol_pow_claim_txids | unique | sort)) and
        all(.authorized_protocol_pow_claim_txids[];
          type == "string" and test("^[0-9a-f]{64}$")) and
        .unexpected_send_transactions == [] and
        .managed_recovery_payment_created == false and
        (.created_at | type) == "string" and (.created_at | length) > 0
    ' "$path" >/dev/null
}

publish_wallet_send_audit()
{
    local path baseline transactions audit
    path=$(wallet_send_audit_path) || return 1
    baseline="$TARGET_WAVE/node-27-wallet-txids.prelaunch.json"
    if [[ -e "$path" || -L "$path" ]]; then
        verify_wallet_send_audit
        return
    fi
    protected_root_file "$baseline" || return 1
    [[ "$(container_generation_for "$TARGET_NODE")" == "$READOPTION_GENERATION" ]] || return 1
    transactions=$(wallet_rpc_for "$TARGET_NODE" listtransactions '*' 1000000 0 true) || return 1
    jq -e 'type == "array" and all(.[];
        (.txid | type) == "string" and (.txid | test("^[0-9a-f]{64}$")) and
        (.category | type) == "string")' >/dev/null <<< "$transactions" || return 1
    audit=$(jq -cnS --argjson transactions "$transactions" --slurpfile baseline "$baseline" '
        def authorized_pow_claim:
          .comment == "PoW Claim" and .qq_shadow_pow_authored == "1" and
          (.qq_shadow_pow_created_height | type) == "string" and
          (.qq_shadow_pow_created_height | test("^[0-9]+$")) and
          (.qq_shadow_pow_created_tip | type) == "string" and
          (.qq_shadow_pow_created_tip | test("^[0-9a-f]{64}$")) and
          (.fee | type) == "number" and .fee <= 0 and
          (.amount | type) == "number" and .amount == 0 and .abandoned == false;
        ($baseline[0] | unique | sort) as $before |
        [$transactions[] |
          select(.category == "send") |
          .txid as $txid |
          select(($before | index($txid)) == null) |
          {txid,comment:(.comment // null),
           qq_shadow_pow_authored:(.qq_shadow_pow_authored // null),
           qq_shadow_pow_created_height:(.qq_shadow_pow_created_height // null),
           qq_shadow_pow_created_tip:(.qq_shadow_pow_created_tip // null),
           fee:(.fee // null),amount:(.amount // null),
           abandoned:(.abandoned // null)}] |
        sort_by([.txid,(.amount | tostring),(.fee | tostring),(.comment | tostring)]) as $new |
        [$new[] | select(authorized_pow_claim) | .txid] |
        unique | sort as $authorized |
        {observed:$new,authorized:$authorized,
         unexpected:[$new[] | select((authorized_pow_claim) | not)]}
    ') || return 1
    jq -e '.unexpected == []' >/dev/null <<< "$audit" || return 1
    jq -n --arg generation "$READOPTION_GENERATION" \
        --arg baseline_sha "$(sha256sum "$baseline" | awk '{print $1}')" \
        --arg run "$TARGET_RUN" --arg wave "$TARGET_WAVE" \
        --argjson observed "$(jq -c '.observed' <<< "$audit")" \
        --argjson authorized "$(jq -c '.authorized' <<< "$audit")" \
        --arg created_at "$(date -u +%FT%TZ)" '
        {schema:1,transaction:"v30.1.4-fleet-rollout",
         state:"readoption-wallet-send-audited",node:27,
         run_dir:$run,wave_dir:$wave,
         container_generation:$generation,prelaunch_wallet_txids_sha256:$baseline_sha,
         observed_new_send_transactions:$observed,
         authorized_protocol_pow_claim_txids:$authorized,
         unexpected_send_transactions:[],managed_recovery_payment_created:false,
         created_at:$created_at}' | atomic_write_json_exclusive "$path" || return 1
    verify_wallet_send_audit
}

on_adoption_exit()
{
    local rc=$? deadline supersession containment_proven=0 inspect
    trap - EXIT
    trap '' HUP INT TERM
    if [[ "$READOPTION_WORKER_PID" =~ ^[1-9][0-9]*$ ]]; then
        kill -TERM -- "-$READOPTION_WORKER_PID" 2>/dev/null || true
        deadline=$((SECONDS + 10))
        while ((SECONDS < deadline)) && kill -0 -- "-$READOPTION_WORKER_PID" 2>/dev/null; do
            sleep 1
        done
        kill -KILL -- "-$READOPTION_WORKER_PID" 2>/dev/null || true
        wait "$READOPTION_WORKER_PID" 2>/dev/null || true
        READOPTION_WORKER_PID=
    fi
    supersession=$(supersession_path 2>/dev/null || true)
    if ((rc != 0 && ADOPTION_COMPLETE == 0)) && [[ -n "$supersession" &&
          ( -e "$supersession" || -L "$supersession" ) ]] &&
       verify_candidate_activation_marker "$TARGET_NODE"; then
        ADOPTION_COMMITTED=1
    fi
    if ((rc != 0 && ADOPTION_MUTATED == 1 && ADOPTION_COMPLETE == 0 &&
         ADOPTION_COMMITTED == 0)); then
        docker update --restart=no "$TARGET_CONTAINER" >/dev/null 2>&1 || true
        if [[ "$(docker inspect -f '{{.State.Running}}' "$TARGET_CONTAINER" 2>/dev/null)" == true ]]; then
            wallet_rpc_for "$TARGET_NODE" setpowmining false 1 1 >/dev/null 2>&1 || true
            wallet_rpc_for "$TARGET_NODE" staking false >/dev/null 2>&1 || true
            wallet_rpc_for "$TARGET_NODE" walletlock >/dev/null 2>&1 || true
            rpc_for "$TARGET_NODE" stop >/dev/null 2>&1 || true
            timeout --foreground --kill-after=10 45 docker stop -t 30 "$TARGET_CONTAINER" \
                >/dev/null 2>&1 || docker kill "$TARGET_CONTAINER" >/dev/null 2>&1 || true
        fi
        if [[ "$READOPTION_ATTEMPT" =~ ^[1-3]$ ]]; then
            if [[ ! -e "$(readoption_attempt_path "$READOPTION_ATTEMPT" STARTED)" &&
                  -e "$(readoption_attempt_path "$READOPTION_ATTEMPT" START-AUTHORIZED)" ]]; then
                publish_readoption_started "$READOPTION_ATTEMPT" || true
            fi
            if [[ -e "$(readoption_attempt_path "$READOPTION_ATTEMPT" STARTED)" ]]; then
                if publish_readoption_failed_containment "$READOPTION_ATTEMPT"; then
                    containment_proven=1
                fi
            fi
        fi
        inspect=$(docker inspect "$TARGET_CONTAINER" 2>/dev/null || true)
        if jq -e '
            length == 1 and .[0].State.Running == false and .[0].State.Pid == 0 and
            .[0].State.Restarting == false and
            .[0].HostConfig.RestartPolicy.Name == "no" and
            .[0].HostConfig.RestartPolicy.MaximumRetryCount == 0
        ' >/dev/null <<< "$inspect" && ((containment_proven == 1)); then
            log 'node27 readoption failed closed; stopped containment and durable failure evidence proved'
        else
            log 'FATAL: node27 readoption exit could not prove stopped containment and durable failure evidence'
            docker inspect -f 'running={{.State.Running}} pid={{.State.Pid}} restarting={{.State.Restarting}} policy={{.HostConfig.RestartPolicy.Name}}:{{.HostConfig.RestartPolicy.MaximumRetryCount}} started={{.State.StartedAt}}' \
                "$TARGET_CONTAINER" >&2 2>/dev/null || true
        fi
    fi
    release_wave_locks || true
    if ((ADOPTION_LOCK_HELD == 1)); then
        flock -u 19 2>/dev/null || true
        exec 19>&- 2>/dev/null || true
    fi
    exit "$rc"
}

verify_readoption_live_state()
{
    local generation="$1" expected_running="$2" expected_policy="$3"
    local source_generation inspect expected_id max_retries
    [[ "$expected_running" == true || "$expected_running" == false ]] || return 1
    [[ "$expected_policy" == no || "$expected_policy" == on-failure ]] || return 1
    readoption_generation_has_original_lineage "$generation" || return 1
    [[ "$(container_generation_for "$TARGET_NODE")" == "$generation" ]] || return 1
    expected_id=${generation%%|*}
    source_generation=$(jq -er '.prelaunch_stopped_generation' \
        "$(wave_node_launch_authorization_path "$TARGET_NODE")") || return 1
    inspect=$(docker inspect "$TARGET_CONTAINER") || return 1
    if [[ "$expected_policy" == no ]]; then max_retries=0; else max_retries=3; fi
    jq -e --arg id "$expected_id" --arg image "$CANDIDATE_IMAGE_REF" \
        --arg image_id "$CANDIDATE_IMAGE_ID" --arg policy "$expected_policy" \
        --argjson retries "$max_retries" --argjson running "$expected_running" '
        length == 1 and .[0].Id == $id and .[0].Config.Image == $image and
        .[0].Image == $image_id and .[0].State.Running == $running and
        (if $running then .[0].State.Pid > 0 else .[0].State.Pid == 0 end) and
        .[0].State.Restarting == false and .[0].State.Paused == false and
        .[0].HostConfig.RestartPolicy.Name == $policy and
        .[0].HostConfig.RestartPolicy.MaximumRetryCount == $retries
    ' >/dev/null <<< "$inspect" || return 1
    verify_candidate_present_exclusive "$TARGET_NODE" "$generation" "$source_generation" \
        "$expected_running" || return 1
    [[ "$(container_generation_for "$TARGET_NODE")" == "$generation" ]]
}

verify_readoption_success_prefix()
{
    local attempt="$1" phase
    [[ "$attempt" =~ ^[1-3]$ ]] || return 1
    verify_readoption_policy_promotion_authorization "$attempt" || return 1
    for phase in staking pow; do
        verify_readoption_phase_log "$attempt" "$phase" || return 1
    done
}

verify_adoption_reentry_state()
{
    local resume authorization supersession result prefix attempt attempt_state generation
    local inspect policy
    resume=$(resume_receipt_path) || return 1
    authorization=$(readoption_authorization_path) || return 1
    supersession=$(supersession_path) || return 1
    result="$TARGET_WAVE/RESULT"
    verify_static_adoption_authority || return 1
    if [[ -e "$resume" || -L "$resume" ]]; then
        verify_resume_compatibility_authority "$TRANSACTION_PACKAGE_ROOT" || return 1
    fi
    if [[ -e "$authorization" || -L "$authorization" ]]; then
        verify_candidate_readoption_authorization "$TARGET_NODE" \
            "$(jq -er '.contained_container_generation' "$authorization")" || return 1
        [[ -e "$resume" && ! -L "$resume" ]] || return 1
    fi
    if [[ -e "$supersession" || -L "$supersession" ]]; then
        [[ -e "$authorization" && ! -L "$authorization" ]] || return 1
        verify_candidate_activation_marker "$TARGET_NODE" || return 1
        attempt=$(jq -er '.successful_readoption_attempt' "$supersession") || return 1
        generation=$(jq -er '.replacement_container_generation' "$supersession") || return 1
        verify_readoption_success_prefix "$attempt" || return 1
        readoption_generation_has_original_lineage "$generation" || return 1
        generation=$(container_generation_for "$TARGET_NODE") || return 1
        verify_readoption_live_state "$generation" true on-failure || return 1
        if [[ -e "$TARGET_WAVE/WAVE-RUNTIME-EVIDENCE.sha256" ||
              -L "$TARGET_WAVE/WAVE-RUNTIME-EVIDENCE.sha256" ]]; then
            verify_wave_runtime_evidence || return 1
        fi
        if [[ -e "$result" || -L "$result" ]]; then
            protected_root_file "$result" || return 1
            [[ "$(cat "$result")" == passed ]] || return 1
            verify_wave_runtime_evidence || return 1
            printf '%s\n' passed
        else
            printf '%s\n' superseded
        fi
        return 0
    fi
    [[ ! -e "$result" && ! -L "$result" &&
       ! -e "$TARGET_WAVE/WAVE-RUNTIME-EVIDENCE.sha256" &&
       ! -L "$TARGET_WAVE/WAVE-RUNTIME-EVIDENCE.sha256" &&
       ! -e "$TARGET_WAVE/unaffected.after" && ! -L "$TARGET_WAVE/unaffected.after" ]] ||
        return 1
    if [[ ! -e "$(readoption_attempt_dir)" && ! -L "$(readoption_attempt_dir)" ]]; then
        verify_initial_containment || return 1
        printf '%s\n' pristine
        return 0
    fi
    [[ -e "$authorization" && ! -L "$authorization" ]] || return 1
    prefix=$(verify_readoption_attempt_prefix) || return 1
    IFS=: read -r attempt attempt_state <<< "$prefix" || return 1
    if ((attempt == 0)); then
        verify_initial_containment || return 1
        printf '%s\n' authorized
        return 0
    fi
    case "$attempt_state" in
        authorized)
            generation=$(jq -er '.prior_container_generation' \
                "$(readoption_attempt_path "$attempt" START-AUTHORIZED)") || return 1
            if verify_readoption_live_state "$generation" false no; then
                printf 'attempt-%s-authorized\n' "$attempt"
            else
                generation=$(container_generation_for "$TARGET_NODE") || return 1
                readoption_generation_has_original_lineage "$generation" || return 1
                inspect=$(docker inspect "$TARGET_CONTAINER") || return 1
                jq -e --arg image "$CANDIDATE_IMAGE_REF" --arg image_id "$CANDIDATE_IMAGE_ID" '
                    length == 1 and .[0].State.Restarting == false and
                    ((.[0].State.Running == true and .[0].State.Pid > 0) or
                     (.[0].State.Running == false and .[0].State.Pid == 0)) and
                    .[0].HostConfig.RestartPolicy.Name == "no" and
                    .[0].HostConfig.RestartPolicy.MaximumRetryCount == 0 and
                    .[0].Config.Image == $image and .[0].Image == $image_id
                ' >/dev/null <<< "$inspect" || return 1
                printf 'attempt-%s-start-residue\n' "$attempt"
            fi
            ;;
        started)
            generation=$(jq -er '.started_container_generation' \
                "$(readoption_attempt_path "$attempt" STARTED)") || return 1
            if verify_readoption_live_state "$generation" true no; then
                printf 'attempt-%s-started\n' "$attempt"
            else
                verify_readoption_live_state "$generation" false no || return 1
                printf 'attempt-%s-started-stopped\n' "$attempt"
            fi
            ;;
        policy-authorized)
            generation=$(jq -er '.started_container_generation' \
                "$(readoption_attempt_path "$attempt" STARTED)") || return 1
            if [[ "$(container_generation_for "$TARGET_NODE")" != "$generation" ]]; then
                generation=$(container_generation_for "$TARGET_NODE") || return 1
                readoption_generation_has_original_lineage "$generation" || return 1
                inspect=$(docker inspect "$TARGET_CONTAINER") || return 1
                jq -e --arg image "$CANDIDATE_IMAGE_REF" --arg image_id "$CANDIDATE_IMAGE_ID" '
                    length == 1 and .[0].State.Restarting == false and
                    ((.[0].State.Running == true and .[0].State.Pid > 0) or
                     (.[0].State.Running == false and .[0].State.Pid == 0)) and
                    ((.[0].HostConfig.RestartPolicy.Name == "no" and
                      .[0].HostConfig.RestartPolicy.MaximumRetryCount == 0) or
                     (.[0].HostConfig.RestartPolicy.Name == "on-failure" and
                      .[0].HostConfig.RestartPolicy.MaximumRetryCount == 3)) and
                    .[0].Config.Image == $image and .[0].Image == $image_id
                ' >/dev/null <<< "$inspect" || return 1
                printf 'attempt-%s-policy-restart-residue\n' "$attempt"
                return 0
            fi
            inspect=$(docker inspect "$TARGET_CONTAINER") || return 1
            policy=$(jq -er '.[0].HostConfig.RestartPolicy.Name' <<< "$inspect") || return 1
            if [[ "$policy" == no ]]; then
                if ! verify_readoption_live_state "$generation" true no; then
                    verify_readoption_live_state "$generation" false no || return 1
                fi
            elif [[ "$policy" == on-failure ]]; then
                if ! verify_readoption_live_state "$generation" true on-failure; then
                    verify_readoption_live_state "$generation" false on-failure || return 1
                fi
            else
                return 1
            fi
            printf 'attempt-%s-policy-authorized\n' "$attempt"
            ;;
        failed-contained)
            verify_readoption_failed_containment "$attempt" || return 1
            ((attempt < MAX_READOPTION_ATTEMPTS)) || return 1
            printf 'attempt-%s-failed-contained\n' "$attempt"
            ;;
        *) return 1 ;;
    esac
}

adoption_preflight()
{
    require_host_tools
    verify_package_integrity "$ADOPTION_PACKAGE_ROOT" || die 'readoption package is invalid'
    [[ "$(sha256sum "$TRANSACTION_PACKAGE_ROOT/SHA256SUMS" | awk '{print $1}')" == \
       "$TRANSACTION_PACKAGE_MANIFEST_SHA256" ]] || die 'sealed transaction package changed'
    [[ "$(sha256sum "$TARGET_RUN/TRANSACTION.json" | awk '{print $1}')" == \
       "$TRANSACTION_MANIFEST_SHA256" &&
       "$(sha256sum "$TARGET_RUN/package-files.sha256" | awk '{print $1}')" == \
       "$TRANSACTION_PACKAGE_FILES_SHA256" &&
       "$(sha256sum "$WAVE_PLAN" | awk '{print $1}')" == "$TRANSACTION_WAVES_SHA256" &&
       "$(sha256sum "$TARGET_RUN/baseline/SHA256SUMS" | awk '{print $1}')" == \
       "$TRANSACTION_BASELINE_MANIFEST_SHA256" ]] || die 'sealed run identity changed'
    verify_package_integrity "$TRANSACTION_PACKAGE_ROOT" || die 'sealed transaction package is invalid'
    (cd "$TRANSACTION_PACKAGE_ROOT" &&
        sha256sum --strict -c "$TARGET_RUN/package-files.sha256" >/dev/null) ||
        die 'run no longer matches its sealed transaction package'
    ADOPTION_REENTRY_STATE=$(verify_adoption_reentry_state) ||
        die 'node27 append-only readoption state or fleet invariant changed'
    log "node27 append-only readoption preflight passed state=$ADOPTION_REENTRY_STATE; no live mutation performed"
}

publish_unaffected_after()
{
    local destination="$TARGET_WAVE/unaffected.after" temporary
    if [[ -e "$destination" || -L "$destination" ]]; then
        protected_root_file "$destination" || return 1
        cmp -s "$TARGET_WAVE/unaffected.before" "$destination"
        return
    fi
    temporary=$(mktemp "$TARGET_WAVE/.unaffected-after.XXXXXX") || return 1
    if ! capture_unaffected_generations "$temporary" "$TARGET_NODE" ||
       ! chmod 600 "$temporary" || ! chown root:root "$temporary" ||
       ! sync -f "$temporary" ||
       ! cmp -s "$TARGET_WAVE/unaffected.before" "$temporary" ||
       ! ln -- "$temporary" "$destination"; then
        rm -f -- "$temporary"
        return 1
    fi
    rm -f -- "$temporary"
    sync -f "$TARGET_WAVE" || return 1
    protected_root_file "$destination" &&
        cmp -s "$TARGET_WAVE/unaffected.before" "$destination"
}

finalize_adoption_evidence()
{
    local result="$TARGET_WAVE/RESULT" runtime="$TARGET_WAVE/WAVE-RUNTIME-EVIDENCE.sha256"
    publish_unaffected_after || return 1
    if [[ -e "$runtime" || -L "$runtime" ]]; then
        verify_wave_runtime_evidence || return 1
    else
        write_wave_runtime_evidence || return 1
        verify_wave_runtime_evidence || return 1
    fi
    if [[ -e "$result" || -L "$result" ]]; then
        protected_root_file "$result" || return 1
        [[ "$(cat "$result")" == passed ]] || return 1
    else
        publish_state_token "$result" passed || return 1
    fi
    protected_root_file "$result" && [[ "$(cat "$result")" == passed ]] &&
        verify_wave_runtime_evidence
}

adoption_apply()
{
    local state attempt policy fee
    [[ "${CONFIRM_ADOPT_CONTAINED_NODE27:-}" == v30.1.4-adopt-contained-node27 ]] ||
        die 'apply requires CONFIRM_ADOPT_CONTAINED_NODE27=v30.1.4-adopt-contained-node27'
    exec 19>/var/run/blackcoin-v30.1.4-fleet-rollout.lock
    flock -n 19 || die 'another v30.1.4 fleet transaction is active'
    ADOPTION_LOCK_HELD=1
    trap on_adoption_exit EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    adoption_preflight
    acquire_wave_locks
    cleanup_readoption_publication_residue ||
        die 'node27 interrupted evidence-publication residue could not be removed'
    state=$(verify_adoption_reentry_state) ||
        die 'node27 readoption state changed after locks were acquired'
    if [[ "$state" == passed ]]; then
        ADOPTION_COMMITTED=1
        ADOPTION_COMPLETE=1
    else
        if [[ "$state" == superseded ]]; then
            ADOPTION_COMMITTED=1
            attempt=$(jq -er '.successful_readoption_attempt' "$(supersession_path)") ||
                die 'node27 supersession attempt is unavailable'
            READOPTION_ATTEMPT=$attempt
            READOPTION_GENERATION=$(jq -er '.replacement_container_generation' \
                "$(supersession_path)") || die 'node27 supersession generation is unavailable'
            verify_wallet_send_audit || die 'node27 wallet-send audit changed after commit'
        else
            if [[ "$state" == pristine ]]; then
                verify_initial_containment ||
                    die 'node27 initial containment changed after locks were acquired'
            fi
            publish_resume_compatibility ||
                die 'resume compatibility authority could not be published'
            publish_readoption_authorization ||
                die 'node27 readoption authority could not be published'
            ensure_readoption_candidate_running ||
                die 'node27 exact candidate could not be safely started or re-adopted'
            wait_for_core_ready ||
                die 'node27 Core did not become ready after same-container restart'
            activate_or_resume_readoption_phases ||
                die 'node27 staking or one-thread PoW activation failed'
            verify_postactivation_no_spend_state ||
                die 'node27 managed-recovery fee or unaffected-node invariant changed'
            verify_wave_chain_convergence ||
                die 'exact-32 chain convergence did not recover'
            cleanup_readoption_partial_logs ||
                die 'node27 transient activation logs could not be closed'
            publish_readoption_policy_promotion_authorization "$READOPTION_ATTEMPT" ||
                die 'node27 restart-policy promotion was not authorized'
            policy=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}:{{.HostConfig.RestartPolicy.MaximumRetryCount}}' \
                "$TARGET_CONTAINER") || die 'node27 restart policy is unavailable'
            if [[ "$policy" == no:0 ]]; then
                docker update --restart=on-failure:3 "$TARGET_CONTAINER" >/dev/null ||
                    die 'node27 restart policy could not be restored'
            elif [[ "$policy" != on-failure:3 ]]; then
                die 'node27 restart policy changed outside the authorized transition'
            fi
            verify_readoption_live_state "$READOPTION_GENERATION" true on-failure ||
                die 'node27 generation changed during restart-policy restoration'
            fee=$(candidate_recovery_fee_for "$TARGET_NODE") ||
                die 'node27 recovery fee baseline is unavailable'
            verify_node_runtime_gate "$TARGET_NODE" "$fee" ||
                die 'node27 failed its immediate promoted runtime gate'
            verify_postactivation_no_spend_state ||
                die 'node27 managed-recovery fee or unaffected-node invariant changed'
            publish_wallet_send_audit ||
                die 'node27 produced an unexpected wallet send during readoption'
            publish_activation_supersession ||
                die 'node27 activation supersession could not be proven'
            ADOPTION_COMMITTED=1
        fi
        fee=$(candidate_recovery_fee_for "$TARGET_NODE") ||
            die 'node27 committed recovery fee baseline is unavailable'
        verify_node_runtime_gate "$TARGET_NODE" "$fee" ||
            die 'node27 committed runtime gate did not reverify'
        verify_postactivation_no_spend_state ||
            die 'node27 committed managed-recovery invariants changed'
        finalize_adoption_evidence ||
            die 'node27 terminal runtime evidence could not be completed'
        ADOPTION_COMPLETE=1
    fi
    trap '' HUP INT TERM
    release_wave_locks
    flock -u 19
    exec 19>&-
    ADOPTION_LOCK_HELD=0
    trap - EXIT HUP INT TERM
    log 'node27 containment superseded; v30.1.4 PoS/PoW runtime gate passed'
}

case "$ADOPTION_ACTION" in
    plan|preflight)
        adoption_preflight
        ;;
    apply)
        adoption_apply
        ;;
    *)
        printf '%s\n' 'Usage: adopt_contained_node27.sh [plan|preflight|apply]' >&2
        exit 64
        ;;
esac
