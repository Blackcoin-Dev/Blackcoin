#!/usr/bin/env bash

# Releases only the Free Claim pause after canonical success evidence. The old
# quarantine cycle remains disabled permanently; this script has no restore path
# for it. Default `probe` is read-only.

set -Eeuo pipefail
umask 077
export LC_ALL=C TZ=UTC

PACKAGE_ROOT=$(CDPATH='' cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || exit 1
readonly PACKAGE_ROOT
readonly ACTION=${1:-probe}
readonly RESULT_PATH=${2:-}
readonly STATE_PATH=${3:-}
readonly FINALIZATION_PATH=${4:-}
readonly CONFIRM_VALUE=v30.1.4-release-free-claim-after-success
readonly OPS_ROOT=/mnt/pulsar/Blackcoin_Blocks/operations/v30.1.4-fleet-rollout
readonly STATE_DIR=/boot/config/plugins/blackcoin-quantum-nodes
readonly FREE_CLAIM_ROOT=/mnt/pulsar/Blackcoin_Blocks/operations/free-claim-pool
readonly ENDPOINT_LOCK=/run/blackcoin-endpoint-guard.lock
readonly CUTOVER_LOCK=/var/run/blackcoin-node-cutover.lock
readonly CYCLE_LOCK=/run/blackcoin-pow-quarantine-cycle.lock
readonly WALLET_LOCK=/var/run/blackcoin-wallet-runtime-guard.lock
readonly FREE_CLAIM_LOCK=/var/run/blackcoin-free-claim-pool.lock
readonly TRANSITION_LOCK=/var/run/blackcoin-free-claim-pause-transition.lock
readonly CYCLE_LIVE="$STATE_DIR/blackcoin_pow_quarantine_cycle.sh"
readonly CYCLE_DISABLED="$STATE_DIR/blackcoin_pow_quarantine_cycle.v30.1.3-fee-capable.disabled"
readonly CYCLE_OLD_SHA256=156acca0ed86fbeba008d9f87eb862aa2f93fc32f57ed2995d7dc05dcdb7312d
readonly CYCLE_SOURCE="$PACKAGE_ROOT/blackcoin_pow_quarantine_cycle_v30.1.4_nospend.sh"
readonly DAEMON_LIVE="$FREE_CLAIM_ROOT/pool_daemon.sh"
readonly DAEMON_ORIGINAL="$FREE_CLAIM_ROOT/pool_daemon.v30.1.4-original"
readonly DAEMON_ORIGINAL_SHA256=cacc958f9ae9530c896caa23a36faca2c89e209e55dcf71f8ed3134547a3e1c6
readonly WRAPPER_SOURCE="$PACKAGE_ROOT/free_claim_daemon_pause_wrapper.sh"
readonly PAUSE_MARKER="$FREE_CLAIM_ROOT/.v30.1.4-free-claim-paused"
readonly PAUSE_CONTENT='schema=1 state=paused authority=v30.1.4-fleet-transaction'
readonly ROLLOUT_MAINTENANCE_MARKER="$STATE_DIR/V30_1_4_ROLLOUT_MAINTENANCE.json"

die()
{
    printf '%s FATAL: %s\n' "$(date -u +%FT%TZ)" "$*" >&2
    exit 1
}

file_sha()
{
    sha256sum "$1" | awk '{print $1}'
}

protected_file()
{
    local path="$1" mode="${2:-600}"
    [[ -f "$path" && ! -L "$path" && "$(realpath -e -- "$path")" == "$path" &&
       "$(stat -c '%u:%a' "$path")" == "0:$mode" ]]
}

protected_directory()
{
    local path="$1" owner_uid mode
    [[ -d "$path" && ! -L "$path" && "$(realpath -e -- "$path")" == "$path" ]] || return 1
    owner_uid=$(stat -c '%u' "$path") || return 1
    mode=$(stat -c '%a' "$path") || return 1
    [[ "$owner_uid" == 0 && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 0022) == 0 ))
}

verify_package()
{
    protected_directory "$PACKAGE_ROOT" && protected_file "$PACKAGE_ROOT/SHA256SUMS" 600 &&
        [[ -z "$(find "$PACKAGE_ROOT" -type l -print -quit)" &&
           -z "$(find "$PACKAGE_ROOT" ! -type d ! -type f -print -quit)" ]] &&
        cmp -s \
            <(cd "$PACKAGE_ROOT" && find . -type f ! -path './SHA256SUMS' -print | sort) \
            <(awk 'NF == 2 && $1 ~ /^[0-9a-f]{64}$/ {
                name=$2; sub(/^\\*/, "", name); sub(/^[.]\//, "", name); print "./" name
            }' "$PACKAGE_ROOT/SHA256SUMS" | sort) &&
        (cd "$PACKAGE_ROOT" && sha256sum --strict -c SHA256SUMS >/dev/null)
}

valid_marker()
{
    protected_file "$PAUSE_MARKER" 600 &&
        printf '%s\n' "$PAUSE_CONTENT" | cmp -s - "$PAUSE_MARKER"
}

create_pause_marker_atomic()
{
    local temporary
    if [[ -e "$PAUSE_MARKER" || -L "$PAUSE_MARKER" ]]; then
        valid_marker
        return
    fi
    temporary=$(mktemp "$FREE_CLAIM_ROOT/.v30.1.4-free-claim-paused.XXXXXX") || return 1
    printf '%s\n' "$PAUSE_CONTENT" > "$temporary" || return 1
    chmod 600 "$temporary" && chown root:root "$temporary" && sync -f "$temporary" || return 1
    mv -T -- "$temporary" "$PAUSE_MARKER" || return 1
    sync -f "$FREE_CLAIM_ROOT" || return 1
    valid_marker
}

prepared_release_window_is_fresh()
{
    local supervisor_epoch="$1" released_at="$2" observed_now="$3"
    [[ "$supervisor_epoch" =~ ^[0-9]+$ && "$released_at" =~ ^[0-9]+$ &&
       "$observed_now" =~ ^[0-9]+$ ]] || return 1
    ((supervisor_epoch <= released_at && released_at <= observed_now &&
      observed_now <= supervisor_epoch + 300))
}

installed_state_valid()
{
    protected_file "$CYCLE_LIVE" 600 && protected_file "$CYCLE_DISABLED" 600 &&
        protected_file "$DAEMON_LIVE" 700 && protected_file "$DAEMON_ORIGINAL" 600 &&
        [[ "$(file_sha "$CYCLE_LIVE")" == "$(file_sha "$CYCLE_SOURCE")" &&
           "$(file_sha "$CYCLE_DISABLED")" == "$CYCLE_OLD_SHA256" &&
           "$(file_sha "$DAEMON_LIVE")" == "$(file_sha "$WRAPPER_SOURCE")" &&
           "$(file_sha "$DAEMON_ORIGINAL")" == "$DAEMON_ORIGINAL_SHA256" ]]
}

canonical_evidence_file()
{
    local path="$1"
    protected_file "$path" 600 && [[ "$path" == "$(realpath -e -- "$path")" ]]
}

validate_preserved_hour_paths()
{
    local audit="$1" manifest="$2" directories="$3" invalid result_count rel extra
    local target ancestor
    [[ -d "$audit" && ! -L "$audit" && "$(realpath -e -- "$audit")" == "$audit" ]] || return 1
    invalid=$(awk '
        NF != 2 || $1 !~ /^[0-9a-f]{64}$/ {print; next}
        {
          name=$2
          if (seen[name]++) {print; next}
          if (name == "../HOUR-SOAK-DIRECTORIES") {bound_directories++; next}
          if (name !~ /^[.]\/[A-Za-z0-9][A-Za-z0-9._-]*(\/[A-Za-z0-9][A-Za-z0-9._-]*)*$/ ||
              name == "./DIRECTORIES") print
        }
        END {if (bound_directories != 1) print "invalid-directory-binding"}
    ' "$manifest") || return 1
    [[ -z "$invalid" ]] || return 1
    invalid=$(awk '
        $0 !~ /^[.]\/[A-Za-z0-9][A-Za-z0-9._-]*(\/[A-Za-z0-9][A-Za-z0-9._-]*)*$/ {print}
    ' "$directories") || return 1
    [[ -z "$invalid" ]] || return 1
    cmp -s "$directories" <(sort -u "$directories") || return 1
    while IFS= read -r rel; do
        rel=${rel#./}
        target="$audit/$rel"
        [[ -d "$target" && ! -L "$target" && "$(realpath -e -- "$target")" == "$target" ]] ||
            return 1
    done < "$directories"
    while read -r _ rel extra; do
        [[ -z "$extra" ]] || return 1
        [[ "$rel" == "../HOUR-SOAK-DIRECTORIES" ]] && continue
        rel=${rel#./}
        target="$audit/$rel"
        [[ -f "$target" && ! -L "$target" && "$(realpath -e -- "$target")" == "$target" ]] ||
            return 1
        ancestor=${rel%/*}
        while [[ "$ancestor" != "$rel" ]]; do
            grep -Fxq -- "./$ancestor" "$directories" || return 1
            [[ "$ancestor" == */* ]] || break
            ancestor=${ancestor%/*}
        done
    done < "$manifest"
    result_count=$(awk '$2 == "./RESULT.json" {count++} END {print count+0}' "$manifest") ||
        return 1
    [[ "$result_count" -eq 1 ]]
}

valid_rollout_run_dir()
{
    local path="$1" basename
    basename=${path##*/}
    [[ "${path%/*}" == "$OPS_ROOT" &&
       "$basename" =~ ^rollout-[0-9]{8}T[0-9]{6}Z$ &&
       -d "$path" && ! -L "$path" && "$(realpath -e -- "$path")" == "$path" &&
       "$(stat -c '%u:%g:%a' "$path")" == 0:0:700 ]]
}

verify_rollout_success()
{
    local run_dir="$1" transaction
    local audit_dir="$run_dir/exact-32-soak"
    transaction="$run_dir/TRANSACTION.json"
    [[ "$RESULT_PATH" == "$audit_dir/RESULT.json" && "$STATE_PATH" == "$run_dir/STATE" &&
       "$(<"$STATE_PATH")" == complete ]] || return 1
    protected_file "$transaction" 600 || return 1
    [[ -d "$audit_dir" && ! -L "$audit_dir" &&
       "$(stat -c '%u:%g:%a' "$audit_dir")" == 0:0:700 &&
       -f "$audit_dir/SHA256SUMS" && ! -L "$audit_dir/SHA256SUMS" &&
       "$(stat -c '%u:%g:%a' "$audit_dir/SHA256SUMS")" == 0:0:600 ]] || return 1
    (cd "$audit_dir" && sha256sum --strict -c SHA256SUMS >/dev/null) || return 1
    jq -e --slurpfile transaction "$transaction" \
        -f "$PACKAGE_ROOT/lib/hour_soak_result.jq" "$RESULT_PATH" >/dev/null || return 1
    verify_finalization_ready "$run_dir"
}

verify_finalization_ready()
{
    local run_dir="$1" audit_dir
    audit_dir="$run_dir/exact-32-soak"
    local ready="$audit_dir/FINALIZATION-READY.json"
    local transaction="$run_dir/TRANSACTION.json" epoch_path="$run_dir/MAINTENANCE-RELEASED-EPOCH"
    local identity_rel supervisor_rel attempt_rel identity supervisor identity_sha supervisor_sha
    local generation_expected_rel generation_final_rel generation_expected generation_final
    local generation_expected_sha generation_final_sha nonce_file="$run_dir/MAINTENANCE-NONCE" nonce
    local transaction_sha
    local result_sha epoch now supervisor_timestamp supervisor_epoch path hour_manifest hour_manifest_sha
    local ready_before result_before manifest_before identity_before supervisor_before hour_before

    [[ "$FINALIZATION_PATH" == "$ready" ]] || return 1
    canonical_evidence_file "$ready" && canonical_evidence_file "$RESULT_PATH" || return 1
    protected_file "$epoch_path" 600 && [[ "$(wc -l < "$epoch_path")" -eq 1 ]] || return 1
    epoch=$(<"$epoch_path")
    [[ "$epoch" =~ ^[1-9][0-9]{8,10}$ ]] || return 1
    now=$(date +%s) || return 1
    ((10#$epoch <= now)) || return 1
    [[ ! -e "$ROLLOUT_MAINTENANCE_MARKER" && ! -L "$ROLLOUT_MAINTENANCE_MARKER" ]] || return 1

    [[ -d "$audit_dir" && ! -L "$audit_dir" &&
       "$(realpath -e -- "$audit_dir")" == "$audit_dir" &&
       "$(stat -c '%u:%g:%a' "$audit_dir")" == 0:0:700 ]] || return 1
    [[ -z "$(find "$audit_dir" -type l -print -quit)" &&
       -z "$(find "$audit_dir" ! -type d ! -type f -print -quit)" ]] || return 1
    while IFS= read -r -d '' path; do
        [[ "$(stat -c '%u:%g:%a' "$path")" == 0:0:700 ]] || return 1
    done < <(find "$audit_dir" -mindepth 1 -type d -print0)
    while IFS= read -r -d '' path; do
        [[ "$(stat -c '%u:%g:%a' "$path")" == 0:0:600 ]] || return 1
    done < <(find "$audit_dir" -type f -print0)
    protected_file "$audit_dir/DIRECTORIES" 600 &&
        protected_file "$audit_dir/SHA256SUMS" 600 || return 1
    cmp -s \
        <(cd "$audit_dir" && find . -mindepth 1 -type d -print | sort) \
        <(sort "$audit_dir/DIRECTORIES") || return 1
    cmp -s "$audit_dir/DIRECTORIES" <(sort -u "$audit_dir/DIRECTORIES") || return 1
    cmp -s \
        <(cd "$audit_dir" && find . -type f ! -path './SHA256SUMS' -print | sort) \
        <(awk 'NF == 2 && $1 ~ /^[0-9a-f]{64}$/ {
            name=$2; sub(/^\\*/, "", name); print name
        }' "$audit_dir/SHA256SUMS" | sort) || return 1
    (cd "$audit_dir" && sha256sum --strict -c SHA256SUMS >/dev/null) || return 1

    hour_manifest="$run_dir/HOUR-SOAK-SHA256SUMS"
    protected_file "$hour_manifest" 600 &&
        protected_file "$run_dir/HOUR-SOAK-DIRECTORIES" 600 || return 1
    hour_manifest_sha=$(file_sha "$hour_manifest") || return 1
    validate_preserved_hour_paths "$audit_dir" "$hour_manifest" \
        "$run_dir/HOUR-SOAK-DIRECTORIES" || return 1
    (cd "$audit_dir" && sha256sum --strict -c "$hour_manifest" >/dev/null) || return 1

    identity_rel=$(jq -er '.fleet_identity_evidence' "$ready") || return 1
    supervisor_rel=$(jq -er '.supervisor_evidence' "$ready") || return 1
    generation_expected_rel=$(jq -er '.generation_expected_evidence' "$ready") || return 1
    generation_final_rel=$(jq -er '.generation_before_publication_evidence' "$ready") || return 1
    [[ "$identity_rel" =~ ^finalization-pre-release-attempt-[0-9]{3,}/FLEET-IDENTITY[.]json$ &&
       "$supervisor_rel" =~ ^finalization-pre-release-attempt-[0-9]{3,}/SUPERVISOR-STATUS[.]json$ &&
       "$generation_expected_rel" =~ ^finalization-pre-release-attempt-[0-9]{3,}/GENERATIONS[.]expected$ &&
       "$generation_final_rel" =~ ^finalization-pre-release-attempt-[0-9]{3,}/GENERATIONS[.]before-publication$ ]] ||
        return 1
    attempt_rel=${identity_rel%/FLEET-IDENTITY.json}
    [[ "${supervisor_rel%/SUPERVISOR-STATUS.json}" == "$attempt_rel" &&
       "${generation_expected_rel%/GENERATIONS.expected}" == "$attempt_rel" &&
       "${generation_final_rel%/GENERATIONS.before-publication}" == "$attempt_rel" ]] || return 1
    identity="$audit_dir/$identity_rel"
    supervisor="$audit_dir/$supervisor_rel"
    generation_expected="$audit_dir/$generation_expected_rel"
    generation_final="$audit_dir/$generation_final_rel"
    canonical_evidence_file "$identity" && canonical_evidence_file "$supervisor" &&
        canonical_evidence_file "$generation_expected" &&
        canonical_evidence_file "$generation_final" || return 1
    identity_sha=$(file_sha "$identity") || return 1
    supervisor_sha=$(file_sha "$supervisor") || return 1
    generation_expected_sha=$(file_sha "$generation_expected") || return 1
    generation_final_sha=$(file_sha "$generation_final") || return 1
    [[ "$generation_expected_sha" == "$generation_final_sha" ]] || return 1
    cmp -s "$generation_expected" "$generation_final" || return 1
    result_sha=$(file_sha "$RESULT_PATH") || return 1
    protected_file "$transaction" 600 && protected_file "$nonce_file" 600 || return 1
    [[ "$(wc -l < "$nonce_file")" -eq 1 ]] || return 1
    nonce=$(<"$nonce_file")
    [[ "$nonce" =~ ^[0-9a-f]{64}$ ]] || return 1
    transaction_sha=$(file_sha "$transaction") || return 1
    jq -e --arg nonce "$nonce" '.maintenance.run_nonce == $nonce' "$transaction" >/dev/null || return 1
    supervisor_timestamp=$(jq -er '.timestamp | select(type == "string")' "$supervisor") || return 1
    [[ "$supervisor_timestamp" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] ||
        return 1
    supervisor_epoch=$(date -d "$supervisor_timestamp" +%s 2>/dev/null) || return 1
    [[ "$supervisor_epoch" =~ ^[1-9][0-9]*$ ]] || return 1
    now=$(date +%s) || return 1
    ((supervisor_epoch <= now && supervisor_epoch >= now - 300)) || return 1

    ready_before=$(file_sha "$ready") || return 1
    result_before=$(file_sha "$RESULT_PATH") || return 1
    manifest_before=$(file_sha "$audit_dir/SHA256SUMS") || return 1
    identity_before=$identity_sha
    supervisor_before=$supervisor_sha
    hour_before=$hour_manifest_sha

    jq -e --slurpfile transaction "$transaction" '
        ($transaction | length) == 1 and .schema == 1 and (.nodes | length) == 32 and
        [.nodes[].node] == [range(1;33)] and
        all(.nodes[];
            .config_image == $transaction[0].candidate_image and
            .image_id == $transaction[0].candidate_image_id) and
        (.compose_sha256 | test("^[0-9a-f]{64}$")) and
        (.image_policy_sha256 | test("^[0-9a-f]{64}$")) and
        (.endpoint_guard_sha256 | test("^[0-9a-f]{64}$")) and
        (.wallet_runtime_guard_sha256 | test("^[0-9a-f]{64}$"))
    ' "$identity" >/dev/null || return 1
    jq -e --arg timestamp "$supervisor_timestamp" '
        .timestamp == $timestamp and .state == "healthy" and .verified == 32 and
        .running == 32 and .operational == 32 and .failures == 0
    ' "$supervisor" >/dev/null || return 1
    jq -e --argjson released "$((10#$epoch))" --argjson supervisor_epoch "$supervisor_epoch" \
        --arg result_sha "$result_sha" --arg hour_manifest_sha "$hour_manifest_sha" \
        --arg identity_rel "$identity_rel" \
        --arg identity_sha "$identity_sha" --arg supervisor_rel "$supervisor_rel" \
        --arg supervisor_sha "$supervisor_sha" --arg supervisor_timestamp "$supervisor_timestamp" \
        --arg run "$run_dir" --arg transaction_sha "$transaction_sha" --arg nonce "$nonce" \
        --arg generation_expected_rel "$generation_expected_rel" \
        --arg generation_expected_sha "$generation_expected_sha" \
        --arg generation_final_rel "$generation_final_rel" \
        --arg generation_final_sha "$generation_final_sha" \
        --slurpfile transaction "$transaction" --slurpfile hour "$RESULT_PATH" \
        --slurpfile identity "$identity" '
        ($transaction | length) == 1 and ($hour | length) == 1 and ($identity | length) == 1 and
        .schema == 1 and .result == "passed" and .phase == "pre-release" and
        .run_dir == $run and .transaction_manifest_sha256 == $transaction_sha and
        .run_nonce == $nonce and $transaction[0].maintenance.run_nonce == $nonce and
        .image == $transaction[0].candidate_image and
        .image_id == $transaction[0].candidate_image_id and
        .source_commit == $transaction[0].source_commit and
        .image == $hour[0].image and .image_id == $hour[0].image_id and
        .source_commit == $hour[0].source_commit and
        .prior_hour_soak_result_sha256 == $result_sha and
        .prior_authenticated_manifest_path == "../HOUR-SOAK-SHA256SUMS" and
        .prior_authenticated_manifest_sha256 == $hour_manifest_sha and
        .maintenance_marker_absent == true and .maintenance_released_epoch == $released and
        .free_claim_broadcasts_paused == true and
        .supervisor_status_sha256 == $supervisor_sha and
        .supervisor_evidence == $supervisor_rel and
        .supervisor_timestamp == $supervisor_timestamp and
        .supervisor_timestamp_epoch == $supervisor_epoch and
        .supervisor_timestamp_epoch > $released and
        .fleet_identity_evidence == $identity_rel and
        .fleet_identity_evidence_sha256 == $identity_sha and
        .generation_expected_evidence == $generation_expected_rel and
        .generation_expected_sha256 == $generation_expected_sha and
        .generation_before_publication_evidence == $generation_final_rel and
        .generation_before_publication_sha256 == $generation_final_sha and
        .compose_sha256 == $identity[0].compose_sha256 and
        .image_policy_sha256 == $identity[0].image_policy_sha256 and
        .endpoint_guard_sha256 == $identity[0].endpoint_guard_sha256 and
        .wallet_runtime_guard_sha256 == $identity[0].wallet_runtime_guard_sha256 and
        .nodes_healthy == 32 and .pos_active == 32 and .regular_pow_active == 31 and
        .free_claim_node == 30 and .free_claim_regular_pow == false and
        .final_concurrent_dynamic_gate == true and
        .final_exact_32_generation_fence == true and .global_chain_convergence == true and
        .vpn_proofs_valid_unique == 32 and .final_policy_assets_valid == true and
        .live_compose_container_policy_match == true and
        .identity_recovery_baselines_unchanged == true and
        .claim_recovery_fee_unchanged == true and .fee_payments_authorized == false and
        .claim_recovery_baseline_sha256s == $hour[0].claim_recovery_baseline_sha256s and
        .claim_recovery_baseline_set_sha256 == $hour[0].claim_recovery_baseline_set_sha256
    ' "$ready" >/dev/null || return 1
    [[ "$(file_sha "$ready")" == "$ready_before" &&
       "$(file_sha "$RESULT_PATH")" == "$result_before" &&
       "$(file_sha "$audit_dir/SHA256SUMS")" == "$manifest_before" &&
       "$(file_sha "$identity")" == "$identity_before" &&
       "$(file_sha "$supervisor")" == "$supervisor_before" &&
       "$(file_sha "$generation_expected")" == "$generation_expected_sha" &&
       "$(file_sha "$generation_final")" == "$generation_final_sha" &&
       "$(file_sha "$transaction")" == "$transaction_sha" &&
       "$(file_sha "$hour_manifest")" == "$hour_before" ]] || return 1
    (cd "$audit_dir" && sha256sum --strict -c SHA256SUMS >/dev/null) || return 1
}

verify_rollback_success()
{
    local run_dir="$1" transaction transaction_sha result_sha expected_result_sha
    transaction="$run_dir/TRANSACTION.json"
    [[ "$RESULT_PATH" == "$run_dir/ROLLBACK_RESULT.json" &&
       "$STATE_PATH" == "$run_dir/STATE" && "$(<"$STATE_PATH")" == rolled-back ]] || return 1
    protected_file "$transaction" 600 || return 1
    protected_file "$run_dir/ROLLBACK_RESULT.sha256" 600 || return 1
    result_sha=$(file_sha "$RESULT_PATH") || return 1
    expected_result_sha=$(awk 'NF == 1 && $1 ~ /^[0-9a-f]{64}$/ {print $1}' \
        "$run_dir/ROLLBACK_RESULT.sha256") || return 1
    [[ -n "$expected_result_sha" && "$result_sha" == "$expected_result_sha" ]] || return 1
    transaction_sha=$(file_sha "$transaction") || return 1
    jq -e --arg transaction_sha "$transaction_sha" '
        .schema == 1 and .transaction == "v30.1.4-fleet-rollout" and
        .result == "rolled-back" and .state == "rolled-back" and
        .transaction_manifest_sha256 == $transaction_sha and
        .nodes_healthy == 32 and .pos_active == 32 and .regular_pow_active == 31 and
        .free_claim_node == 30 and .free_claim_regular_pow == false and
        .free_claim_broadcasts_paused == true and
        .vpn_proofs_valid_unique == 32 and .baseline_identity_restored == true and
        .claim_recovery_fee_unchanged == true and .fee_payments_authorized == false and
        .rollback_verified == true
    ' "$RESULT_PATH" >/dev/null || return 1
    verify_rollback_finalization_ready "$run_dir"
}

verify_rollback_finalization_ready()
{
    local run_dir="$1" ready
    ready="$run_dir/ROLLBACK-FINALIZATION-READY.json"
    local ready_sha expected_ready_sha epoch now supervisor_rel identity_rel attempt_rel
    local supervisor identity supervisor_sha identity_sha timestamp timestamp_epoch
    local generation_before_rel generation_final_rel generation_before generation_final
    local generation_before_sha generation_final_sha nonce_file="$run_dir/MAINTENANCE-NONCE" nonce
    local result_sha transaction_sha ready_before supervisor_before identity_before
    [[ "$FINALIZATION_PATH" == "$ready" ]] || return 1
    canonical_evidence_file "$ready" || return 1
    protected_file "$run_dir/ROLLBACK-FINALIZATION-READY.sha256" 600 || return 1
    ready_sha=$(file_sha "$ready") || return 1
    expected_ready_sha=$(awk 'NF == 1 && $1 ~ /^[0-9a-f]{64}$/ {print $1}' \
        "$run_dir/ROLLBACK-FINALIZATION-READY.sha256") || return 1
    [[ -n "$expected_ready_sha" && "$ready_sha" == "$expected_ready_sha" ]] || return 1
    protected_file "$run_dir/MAINTENANCE-RELEASED-EPOCH" 600 || return 1
    epoch=$(<"$run_dir/MAINTENANCE-RELEASED-EPOCH")
    [[ "$epoch" =~ ^[1-9][0-9]{8,10}$ ]] || return 1
    now=$(date +%s) || return 1
    ((10#$epoch <= now)) || return 1
    [[ ! -e "$ROLLOUT_MAINTENANCE_MARKER" && ! -L "$ROLLOUT_MAINTENANCE_MARKER" ]] || return 1
    supervisor_rel=$(jq -er '.supervisor_evidence' "$ready") || return 1
    identity_rel=$(jq -er '.fleet_identity_evidence' "$ready") || return 1
    generation_before_rel=$(jq -er '.generation_before_evidence' "$ready") || return 1
    generation_final_rel=$(jq -er '.generation_before_publication_evidence' "$ready") || return 1
    [[ "$supervisor_rel" =~ ^rollback-finalization-attempt-[0-9]{3,}/SUPERVISOR-STATUS[.]json$ &&
       "$identity_rel" =~ ^rollback-finalization-attempt-[0-9]{3,}/FLEET-IDENTITY[.]json$ &&
       "$generation_before_rel" =~ ^rollback-finalization-attempt-[0-9]{3,}/GENERATIONS[.]before$ &&
       "$generation_final_rel" =~ ^rollback-finalization-attempt-[0-9]{3,}/GENERATIONS[.]before-publication$ ]] || return 1
    attempt_rel=${supervisor_rel%/SUPERVISOR-STATUS.json}
    [[ "${identity_rel%/FLEET-IDENTITY.json}" == "$attempt_rel" &&
       "${generation_before_rel%/GENERATIONS.before}" == "$attempt_rel" &&
       "${generation_final_rel%/GENERATIONS.before-publication}" == "$attempt_rel" ]] || return 1
    [[ -d "$run_dir/$attempt_rel" && ! -L "$run_dir/$attempt_rel" &&
       "$(realpath -e -- "$run_dir/$attempt_rel")" == "$run_dir/$attempt_rel" &&
       "$(stat -c '%u:%g:%a' "$run_dir/$attempt_rel")" == 0:0:700 ]] || return 1
    supervisor="$run_dir/$supervisor_rel"
    identity="$run_dir/$identity_rel"
    generation_before="$run_dir/$generation_before_rel"
    generation_final="$run_dir/$generation_final_rel"
    canonical_evidence_file "$supervisor" && canonical_evidence_file "$identity" &&
        canonical_evidence_file "$generation_before" &&
        canonical_evidence_file "$generation_final" || return 1
    supervisor_sha=$(file_sha "$supervisor") || return 1
    identity_sha=$(file_sha "$identity") || return 1
    generation_before_sha=$(file_sha "$generation_before") || return 1
    generation_final_sha=$(file_sha "$generation_final") || return 1
    [[ "$generation_before_sha" == "$generation_final_sha" ]] || return 1
    cmp -s "$generation_before" "$generation_final" || return 1
    result_sha=$(file_sha "$RESULT_PATH") || return 1
    transaction_sha=$(file_sha "$run_dir/TRANSACTION.json") || return 1
    protected_file "$nonce_file" 600 && [[ "$(wc -l < "$nonce_file")" -eq 1 ]] || return 1
    nonce=$(<"$nonce_file")
    [[ "$nonce" =~ ^[0-9a-f]{64}$ ]] || return 1
    jq -e --arg nonce "$nonce" '.maintenance.run_nonce == $nonce' \
        "$run_dir/TRANSACTION.json" >/dev/null || return 1
    timestamp=$(jq -er '.timestamp | select(type == "string")' "$supervisor") || return 1
    [[ "$timestamp" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 1
    timestamp_epoch=$(date -d "$timestamp" +%s 2>/dev/null) || return 1
    [[ "$timestamp_epoch" =~ ^[1-9][0-9]*$ ]] || return 1
    ((timestamp_epoch > 10#$epoch && timestamp_epoch <= now && timestamp_epoch >= now - 300)) || return 1
    jq -e --arg timestamp "$timestamp" '
        .timestamp == $timestamp and .state == "healthy" and .verified == 32 and
        .running == 32 and .operational == 32 and .failures == 0
    ' "$supervisor" >/dev/null || return 1
    jq -e '
        type == "array" and length == 32 and [.[] | .node] == [range(1;33)] and
        all(.[];
          (.wallets_json | type) == "string" and
          (.legacy_addresses_sha256 | test("^[0-9a-f]{64}$")) and
          (.quantum_addresses_sha256 | test("^[0-9a-f]{64}$")) and
          (.blackcoin_conf_sha256 | test("^[0-9a-f]{64}$")))
    ' "$identity" >/dev/null || return 1
    ready_before=$ready_sha
    supervisor_before=$supervisor_sha
    identity_before=$identity_sha
    jq -e --arg run "$run_dir" --arg result_sha "$result_sha" \
        --arg transaction_sha "$transaction_sha" --arg supervisor_rel "$supervisor_rel" \
        --arg supervisor_sha "$supervisor_sha" --arg timestamp "$timestamp" \
        --arg identity_rel "$identity_rel" --arg identity_sha "$identity_sha" \
        --arg generation_before_rel "$generation_before_rel" \
        --arg generation_before_sha "$generation_before_sha" \
        --arg generation_final_rel "$generation_final_rel" \
        --arg generation_final_sha "$generation_final_sha" --arg nonce "$nonce" \
        --argjson released "$((10#$epoch))" --argjson supervisor_epoch "$timestamp_epoch" '
        .schema == 1 and .result == "passed" and .phase == "rollback-pre-release" and
        .run_dir == $run and .rollback_result_sha256 == $result_sha and
        .transaction_manifest_sha256 == $transaction_sha and
        .run_nonce == $nonce and
        .maintenance_marker_absent == true and .maintenance_released_epoch == $released and
        .free_claim_broadcasts_paused == true and .supervisor_evidence == $supervisor_rel and
        .supervisor_status_sha256 == $supervisor_sha and .supervisor_timestamp == $timestamp and
        .supervisor_timestamp_epoch == $supervisor_epoch and
        .supervisor_timestamp_epoch > $released and
        .fleet_identity_evidence == $identity_rel and
        .fleet_identity_evidence_sha256 == $identity_sha and
        .generation_before_evidence == $generation_before_rel and
        .generation_before_sha256 == $generation_before_sha and
        .generation_before_publication_evidence == $generation_final_rel and
        .generation_before_publication_sha256 == $generation_final_sha and
        .nodes_healthy == 32 and .pos_active == 32 and .regular_pow_active == 31 and
        .free_claim_node == 30 and .free_claim_regular_pow == false and
        .exact_32_generation_fence == true and .vpn_proofs_valid_unique == 32 and
        .baseline_identity_restored == true and .claim_recovery_fee_unchanged == true and
        .fee_payments_authorized == false
    ' "$ready" >/dev/null || return 1
    [[ "$(file_sha "$ready")" == "$ready_before" &&
       "$(file_sha "$supervisor")" == "$supervisor_before" &&
       "$(file_sha "$identity")" == "$identity_before" &&
       "$(file_sha "$generation_before")" == "$generation_before_sha" &&
       "$(file_sha "$generation_final")" == "$generation_final_sha" &&
       "$(file_sha "$RESULT_PATH")" == "$result_sha" &&
       "$(file_sha "$run_dir/TRANSACTION.json")" == "$transaction_sha" ]]
}

verify_success_evidence()
{
    local run_dir
    [[ -n "$RESULT_PATH" && -n "$STATE_PATH" ]] || return 1
    canonical_evidence_file "$RESULT_PATH" && canonical_evidence_file "$STATE_PATH" || return 1
    run_dir=${STATE_PATH%/STATE}
    [[ "$run_dir" != "$STATE_PATH" ]] && valid_rollout_run_dir "$run_dir" || return 1
    case "$(<"$STATE_PATH")" in
        complete) verify_rollout_success "$run_dir" ;;
        rolled-back) verify_rollback_success "$run_dir" ;;
        *) return 1 ;;
    esac
}

write_release_sidecar()
{
    local run_dir="$1" receipt receipt_sha_path temporary
    receipt="$run_dir/FREE-CLAIM-RELEASED.json"
    receipt_sha_path="$run_dir/FREE-CLAIM-RELEASED.sha256"
    protected_file "$receipt" 600 || return 1
    [[ ! -e "$receipt_sha_path" && ! -L "$receipt_sha_path" ]] || return 1
    temporary=$(mktemp "$run_dir/.free-claim-released-sha.XXXXXX") || return 1
    file_sha "$receipt" > "$temporary" || return 1
    chmod 600 "$temporary" && chown root:root "$temporary" && sync -f "$temporary" || return 1
    mv -T -- "$temporary" "$receipt_sha_path" || return 1
    sync -f "$run_dir"
}

archive_stale_release_receipt()
{
    local run_dir="$1" receipt receipt_sha_path
    local history="$run_dir/FREE-CLAIM-RELEASED.history" actual expected
    local archived_receipt archived_sidecar temporary
    receipt="$run_dir/FREE-CLAIM-RELEASED.json"
    receipt_sha_path="$run_dir/FREE-CLAIM-RELEASED.sha256"
    valid_marker || return 1
    [[ -e "$receipt" && ! -L "$receipt" ]] || return 1
    protected_file "$receipt" 600 || return 1
    if [[ -e "$receipt_sha_path" || -L "$receipt_sha_path" ]]; then
        protected_file "$receipt_sha_path" 600 || return 1
        expected=$(awk 'NF == 1 && $1 ~ /^[0-9a-f]{64}$/ {print $1}' \
            "$receipt_sha_path") || return 1
        [[ -n "$expected" && "$(wc -l < "$receipt_sha_path")" -eq 1 ]] || return 1
    else
        expected=''
    fi
    actual=$(file_sha "$receipt") || return 1
    [[ -z "$expected" || "$expected" == "$actual" ]] || return 1
    jq -e --arg run "$run_dir" '
        .schema == 1 and .transaction == "v30.1.4-free-claim-release" and
        .run_dir == $run and (.state == "complete" or .state == "rolled-back") and
        (.result_sha256 | type) == "string" and
        (.result_sha256 | test("^[0-9a-f]{64}$")) and
        (.finalization_sha256 | type) == "string" and
        (.finalization_sha256 | test("^[0-9a-f]{64}$")) and
        (.transaction_manifest_sha256 | type) == "string" and
        (.transaction_manifest_sha256 | test("^[0-9a-f]{64}$")) and
        (.run_nonce | type) == "string" and (.run_nonce | test("^[0-9a-f]{64}$")) and
        (.maintenance_released_epoch | type) == "number" and
        (.supervisor_timestamp_epoch | type) == "number" and
        (.released_at_epoch | type) == "number" and
        .receipt_published_before_pause_removal == true and
        .release_protocol == "write-ahead-v1"
    ' "$receipt" >/dev/null || return 1
    if [[ -e "$history" || -L "$history" ]]; then
        [[ -d "$history" && ! -L "$history" && "$(realpath -e -- "$history")" == "$history" &&
           "$(stat -c '%u:%g:%a' "$history")" == 0:0:700 ]] || return 1
    else
        install -d -m 700 -o root -g root "$history" || return 1
        sync -f "$run_dir" || return 1
    fi
    archived_receipt="$history/$actual.json"
    archived_sidecar="$history/$actual.sha256"
    if [[ -e "$archived_receipt" || -L "$archived_receipt" ]]; then
        protected_file "$archived_receipt" 600 && cmp -s "$receipt" "$archived_receipt" || return 1
    else
        temporary=$(mktemp "$history/.receipt.XXXXXX") || return 1
        cp -- "$receipt" "$temporary" || return 1
        chmod 600 "$temporary" && chown root:root "$temporary" && sync -f "$temporary" || return 1
        mv -T -- "$temporary" "$archived_receipt" || return 1
        sync -f "$history" || return 1
    fi
    if [[ -e "$archived_sidecar" || -L "$archived_sidecar" ]]; then
        protected_file "$archived_sidecar" 600 || return 1
        [[ "$(wc -l < "$archived_sidecar")" -eq 1 && "$(<"$archived_sidecar")" == "$actual" ]] ||
            return 1
    else
        temporary=$(mktemp "$history/.sidecar.XXXXXX") || return 1
        printf '%s\n' "$actual" > "$temporary" || return 1
        chmod 600 "$temporary" && chown root:root "$temporary" && sync -f "$temporary" || return 1
        mv -T -- "$temporary" "$archived_sidecar" || return 1
        sync -f "$history" || return 1
    fi
    if [[ -e "$receipt_sha_path" || -L "$receipt_sha_path" ]]; then
        rm -f -- "$receipt_sha_path" || return 1
        sync -f "$run_dir" || return 1
    fi
    rm -f -- "$receipt" || return 1
    sync -f "$run_dir"
}

write_release_receipt()
{
    local run_dir="$1" receipt receipt_sha_path
    receipt="$run_dir/FREE-CLAIM-RELEASED.json"
    receipt_sha_path="$run_dir/FREE-CLAIM-RELEASED.sha256"
    local result_sha finalization_sha transaction_sha state maintenance_epoch supervisor_epoch nonce now
    local temporary
    valid_marker || return 1
    if [[ -e "$receipt" || -L "$receipt" || -e "$receipt_sha_path" || -L "$receipt_sha_path" ]]; then
        if verify_release_receipt prepared required; then
            return 0
        fi
        if [[ -e "$receipt" && ! -L "$receipt" &&
              ! -e "$receipt_sha_path" && ! -L "$receipt_sha_path" ]] &&
           verify_release_receipt prepared allow-missing; then
            write_release_sidecar "$run_dir" || return 1
            verify_release_receipt prepared required
            return
        fi
        archive_stale_release_receipt "$run_dir" || return 1
    fi
    [[ ! -e "$receipt" && ! -L "$receipt" &&
       ! -e "$receipt_sha_path" && ! -L "$receipt_sha_path" ]] || return 1
    result_sha=$(file_sha "$RESULT_PATH") || return 1
    finalization_sha=$(file_sha "$FINALIZATION_PATH") || return 1
    transaction_sha=$(file_sha "$run_dir/TRANSACTION.json") || return 1
    state=$(<"$STATE_PATH")
    maintenance_epoch=$(jq -er '.maintenance_released_epoch | select(type == "number")' \
        "$FINALIZATION_PATH") || return 1
    supervisor_epoch=$(jq -er '.supervisor_timestamp_epoch | select(type == "number")' \
        "$FINALIZATION_PATH") || return 1
    nonce=$(jq -er '.run_nonce | select(type == "string")' "$FINALIZATION_PATH") || return 1
    [[ "$nonce" =~ ^[0-9a-f]{64}$ && "$maintenance_epoch" =~ ^[0-9]+$ &&
       "$supervisor_epoch" =~ ^[0-9]+$ ]] || return 1
    now=$(date +%s) || return 1
    ((supervisor_epoch <= now && supervisor_epoch >= now - 300 &&
      supervisor_epoch > maintenance_epoch)) || return 1
    temporary=$(mktemp "$run_dir/.free-claim-released.XXXXXX") || return 1
    jq -n --arg run "$run_dir" --arg state "$state" --arg result_sha "$result_sha" \
        --arg finalization_path "$FINALIZATION_PATH" --arg finalization_sha "$finalization_sha" \
        --arg transaction_sha "$transaction_sha" --arg nonce "$nonce" \
        --argjson released_at_epoch "$now" \
        --argjson maintenance_epoch "$maintenance_epoch" --argjson supervisor_epoch "$supervisor_epoch" '
        {schema:1,transaction:"v30.1.4-free-claim-release",run_dir:$run,state:$state,
         result_sha256:$result_sha,finalization_path:$finalization_path,
         finalization_sha256:$finalization_sha,transaction_manifest_sha256:$transaction_sha,
         run_nonce:$nonce,
         maintenance_released_epoch:$maintenance_epoch,
         supervisor_timestamp_epoch:$supervisor_epoch,released_at_epoch:$released_at_epoch,
         supervisor_fresh_at_release:true,maintenance_marker_absent:true,
         free_claim_pause_absent:true,receipt_published_before_pause_removal:true,
         release_protocol:"write-ahead-v1",
         release_order:"maintenance-then-supervisor-then-free-claim"}
    ' > "$temporary" || return 1
    chmod 600 "$temporary" && chown root:root "$temporary" && sync -f "$temporary" || return 1
    mv -fT -- "$temporary" "$receipt" || return 1
    sync -f "$run_dir" || return 1
    verify_release_receipt prepared allow-missing || return 1
    write_release_sidecar "$run_dir" || return 1
    verify_release_receipt prepared required
}

verify_release_receipt()
{
    local marker_mode="${1:-committed}" sidecar_mode="${2:-required}"
    local run_dir receipt receipt_sha_path expected actual result_sha state_sha finalization_sha transaction_sha
    local state maintenance_epoch supervisor_epoch released_at nonce transaction_nonce now expected_phase
    local transaction nonce_file final_now
    [[ "$marker_mode" == prepared || "$marker_mode" == committed ]] || return 1
    [[ "$sidecar_mode" == required || "$sidecar_mode" == allow-missing ]] || return 1
    [[ "$marker_mode" == prepared || "$sidecar_mode" == required ]] || return 1
    [[ -n "$RESULT_PATH" && -n "$STATE_PATH" && -n "$FINALIZATION_PATH" ]] || return 1
    canonical_evidence_file "$RESULT_PATH" && canonical_evidence_file "$STATE_PATH" &&
        canonical_evidence_file "$FINALIZATION_PATH" || return 1
    run_dir=${STATE_PATH%/STATE}
    valid_rollout_run_dir "$run_dir" || return 1
    transaction="$run_dir/TRANSACTION.json"
    nonce_file="$run_dir/MAINTENANCE-NONCE"
    canonical_evidence_file "$transaction" && canonical_evidence_file "$nonce_file" || return 1
    [[ "$(wc -l < "$nonce_file")" -eq 1 ]] || return 1
    transaction_nonce=$(<"$nonce_file")
    [[ "$transaction_nonce" =~ ^[0-9a-f]{64}$ ]] || return 1
    jq -e --arg nonce "$transaction_nonce" '.maintenance.run_nonce == $nonce' \
        "$transaction" >/dev/null || return 1
    receipt="$run_dir/FREE-CLAIM-RELEASED.json"
    receipt_sha_path="$run_dir/FREE-CLAIM-RELEASED.sha256"
    protected_file "$receipt" 600 || return 1
    actual=$(file_sha "$receipt") || return 1
    if [[ -e "$receipt_sha_path" || -L "$receipt_sha_path" ]]; then
        protected_file "$receipt_sha_path" 600 || return 1
        expected=$(awk 'NF == 1 && $1 ~ /^[0-9a-f]{64}$/ {print $1}' "$receipt_sha_path") || return 1
        [[ -n "$expected" && "$(wc -l < "$receipt_sha_path")" -eq 1 &&
           "$expected" == "$actual" ]] || return 1
    else
        [[ "$sidecar_mode" == allow-missing ]] || return 1
    fi
    result_sha=$(file_sha "$RESULT_PATH") || return 1
    state_sha=$(file_sha "$STATE_PATH") || return 1
    finalization_sha=$(file_sha "$FINALIZATION_PATH") || return 1
    transaction_sha=$(file_sha "$transaction") || return 1
    state=$(<"$STATE_PATH")
    case "$state" in
        complete)
            [[ "$RESULT_PATH" == "$run_dir/exact-32-soak/RESULT.json" &&
               "$FINALIZATION_PATH" == "$run_dir/exact-32-soak/FINALIZATION-READY.json" ]] || return 1
            expected_phase=pre-release
            ;;
        rolled-back)
            [[ "$RESULT_PATH" == "$run_dir/ROLLBACK_RESULT.json" &&
               "$FINALIZATION_PATH" == "$run_dir/ROLLBACK-FINALIZATION-READY.json" ]] || return 1
            expected_phase=rollback-pre-release
            ;;
        *) return 1 ;;
    esac
    maintenance_epoch=$(jq -er '.maintenance_released_epoch | select(type == "number")' \
        "$FINALIZATION_PATH") || return 1
    supervisor_epoch=$(jq -er '.supervisor_timestamp_epoch | select(type == "number")' \
        "$FINALIZATION_PATH") || return 1
    nonce=$(jq -er '.run_nonce | select(type == "string")' "$FINALIZATION_PATH") || return 1
    [[ "$nonce" =~ ^[0-9a-f]{64}$ && "$nonce" == "$transaction_nonce" &&
       "$maintenance_epoch" =~ ^[0-9]+$ && "$supervisor_epoch" =~ ^[0-9]+$ ]] || return 1
    released_at=$(jq -er '.released_at_epoch | select(type == "number")' "$receipt") || return 1
    [[ "$released_at" =~ ^[0-9]+$ ]] || return 1
    now=$(date +%s) || return 1
    ((maintenance_epoch < supervisor_epoch && supervisor_epoch <= released_at &&
      released_at <= supervisor_epoch + 300 && released_at <= now)) || return 1
    jq -e --arg run "$run_dir" --arg state "$state" --arg result_sha "$result_sha" \
        --arg finalization_path "$FINALIZATION_PATH" --arg finalization_sha "$finalization_sha" \
        --arg transaction_sha "$transaction_sha" --arg nonce "$nonce" \
        --argjson released_at "$released_at" \
        --argjson maintenance_epoch "$maintenance_epoch" --argjson supervisor_epoch "$supervisor_epoch" '
        . == {schema:1,transaction:"v30.1.4-free-claim-release",run_dir:$run,state:$state,
          result_sha256:$result_sha,finalization_path:$finalization_path,
          finalization_sha256:$finalization_sha,transaction_manifest_sha256:$transaction_sha,
          run_nonce:$nonce,
          maintenance_released_epoch:$maintenance_epoch,
          supervisor_timestamp_epoch:$supervisor_epoch,released_at_epoch:$released_at,
          supervisor_fresh_at_release:true,maintenance_marker_absent:true,
          free_claim_pause_absent:true,receipt_published_before_pause_removal:true,
          release_protocol:"write-ahead-v1",
          release_order:"maintenance-then-supervisor-then-free-claim"}
    ' "$receipt" >/dev/null || return 1
    jq -e --arg phase "$expected_phase" --arg run "$run_dir" \
        --arg transaction_sha "$transaction_sha" --arg nonce "$nonce" \
        --argjson maintenance "$maintenance_epoch" \
        --argjson supervisor "$supervisor_epoch" '
        .schema == 1 and .result == "passed" and .phase == $phase and
        .run_dir == $run and .transaction_manifest_sha256 == $transaction_sha and
        .run_nonce == $nonce and
        .maintenance_marker_absent == true and .maintenance_released_epoch == $maintenance and
        .free_claim_broadcasts_paused == true and .supervisor_timestamp_epoch == $supervisor and
        .supervisor_timestamp_epoch > .maintenance_released_epoch
    ' "$FINALIZATION_PATH" >/dev/null || return 1
    installed_state_valid &&
        [[ ! -e "$ROLLOUT_MAINTENANCE_MARKER" && ! -L "$ROLLOUT_MAINTENANCE_MARKER" &&
           "$(file_sha "$receipt")" == "$actual" &&
           "$(file_sha "$RESULT_PATH")" == "$result_sha" &&
           "$(file_sha "$STATE_PATH")" == "$state_sha" &&
           "$(file_sha "$FINALIZATION_PATH")" == "$finalization_sha" &&
           "$(file_sha "$transaction")" == "$transaction_sha" &&
           "$(<"$nonce_file")" == "$transaction_nonce" ]] || return 1
    if [[ -n "${expected:-}" ]]; then
        protected_file "$receipt_sha_path" 600 &&
            [[ "$(wc -l < "$receipt_sha_path")" -eq 1 &&
               "$(<"$receipt_sha_path")" == "$expected" ]] || return 1
    else
        [[ ! -e "$receipt_sha_path" && ! -L "$receipt_sha_path" ]] || return 1
    fi
    case "$marker_mode" in
        prepared)
            valid_marker || return 1
            final_now=$(date +%s) || return 1
            prepared_release_window_is_fresh "$supervisor_epoch" "$released_at" "$final_now"
            ;;
        committed)
            [[ ! -e "$PAUSE_MARKER" && ! -L "$PAUSE_MARKER" ]]
            ;;
    esac
}

probe()
{
    verify_package || die 'package integrity verification failed'
    installed_state_valid || die 'installed inhibitor bytes are invalid'
    if valid_marker; then
        printf '%s\n' 'state=installed-and-paused cycle=v30.1.4-no-spend free_claim=paused'
    elif [[ ! -e "$PAUSE_MARKER" && ! -L "$PAUSE_MARKER" ]]; then
        printf '%s\n' 'state=installed-and-released cycle=v30.1.4-no-spend free_claim=enabled'
    else
        die 'Free Claim pause marker is malformed'
    fi
}

release_pause()
{
    local run_dir
    [[ "${CONFIRM_RELEASE_TRANSACTION_INHIBITORS:-}" == "$CONFIRM_VALUE" ]] ||
        die "release requires CONFIRM_RELEASE_TRANSACTION_INHIBITORS=$CONFIRM_VALUE"
    verify_package || die 'package integrity verification failed'
    [[ "$(id -u)" -eq 0 ]] || die 'root is required'
    [[ ! -L "$ENDPOINT_LOCK" && ! -L "$CUTOVER_LOCK" && ! -L "$CYCLE_LOCK" &&
       ! -L "$WALLET_LOCK" && ! -L "$FREE_CLAIM_LOCK" && ! -L "$TRANSITION_LOCK" ]] ||
        die 'lock path is unsafe'
    if ! protected_directory "$STATE_DIR" || ! protected_directory "$FREE_CLAIM_ROOT"; then
        die 'live inhibitor directories are not root protected'
    fi
    exec 12>"$ENDPOINT_LOCK"
    flock -w 1800 12 || die 'endpoint guard did not drain'
    exec 13>"$CUTOVER_LOCK"
    flock -w 1800 13 || die 'node cutover activity did not drain'
    exec 9>"$CYCLE_LOCK"
    flock -w 1800 9 || die 'quarantine cycle did not drain'
    exec 14>"$WALLET_LOCK"
    flock -w 1800 14 || die 'wallet runtime guard did not drain'
    exec 11>"$TRANSITION_LOCK"
    flock -w 1800 11 || die 'Free Claim transition did not drain'
    exec 10>"$FREE_CLAIM_LOCK"
    flock -w 1800 10 || die 'Free Claim worker did not drain'
    installed_state_valid || die 'installed inhibitor bytes are invalid'
    if [[ ! -e "$PAUSE_MARKER" && ! -L "$PAUSE_MARKER" ]]; then
        if verify_release_receipt committed required; then
            printf '%s\n' 'state=installed-and-released cycle=v30.1.4-no-spend free_claim=enabled'
            return 0
        fi
        create_pause_marker_atomic ||
            die 'released Free Claim lacked a valid receipt and could not be re-paused'
        die 'released Free Claim lacked a valid receipt and was atomically re-paused'
    fi
    valid_marker || die 'Free Claim pause marker is malformed'
    verify_success_evidence || die 'canonical successful RESULT/STATE evidence did not verify'
    [[ ! -e "$ROLLOUT_MAINTENANCE_MARKER" && ! -L "$ROLLOUT_MAINTENANCE_MARKER" ]] ||
        die 'fleet maintenance marker reappeared before Free Claim release'

    run_dir=${STATE_PATH%/STATE}
    installed_state_valid || die 'no-spend or daemon-wrapper bytes changed during release'
    write_release_receipt "$run_dir" || die 'durable prepared Free Claim release receipt failed'
    # This is the final freshness and byte-identity gate. The receipt and its
    # sidecar are already directory-durable while broadcasts remain paused.
    verify_release_receipt prepared required ||
        die 'prepared Free Claim release receipt did not verify immediately before release'

    # Deliberately remove only the Free Claim marker. The archived old cycle is
    # retained and the installed no-spend cycle remains byte-exact.
    if ! rm -f -- "$PAUSE_MARKER" || ! sync -f "$FREE_CLAIM_ROOT"; then
        create_pause_marker_atomic ||
            die 'pause marker removal was indeterminate and fail-closed re-pause failed'
        die 'pause marker removal was indeterminate; Free Claim was re-paused'
    fi
    [[ ! -e "$PAUSE_MARKER" && ! -L "$PAUSE_MARKER" ]] ||
        die 'pause marker removal failed'
    if ! verify_release_receipt committed required; then
        create_pause_marker_atomic ||
            die 'committed release verification failed and fail-closed re-pause failed'
        die 'committed release verification failed; Free Claim was re-paused'
    fi
    printf '%s\n' 'state=installed-and-released cycle=v30.1.4-no-spend free_claim=enabled'
}

for command in awk chmod chown cmp cp date find flock grep install jq mktemp mv realpath rm \
    sha256sum sort stat sync wc; do
    command -v "$command" >/dev/null 2>&1 || die "required command unavailable: $command"
done

case "$ACTION" in
    probe) probe ;;
    release) release_pause ;;
    verify-release)
        verify_package || die 'package integrity verification failed'
        verify_release_receipt committed required ||
            die 'durable Free Claim release receipt did not verify'
        printf '%s\n' 'state=installed-and-released receipt=verified'
        ;;
    *) printf 'usage: %s [probe|release|verify-release RESULT_PATH STATE_PATH FINALIZATION_PATH]\n' "$0" >&2; exit 64 ;;
esac
