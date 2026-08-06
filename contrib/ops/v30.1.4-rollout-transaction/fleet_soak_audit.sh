#!/usr/bin/env bash

# Exact-32, stateful soak. Static checks run once. Later samples rerun only
# dynamic liveness checks, and nodes leave the work set after enough consecutive
# good samples. This avoids repeating tests already proven for a generation.

set -Eeuo pipefail
umask 077
export LC_ALL=C TZ=UTC

# The bootstrap verification intentionally precedes every sourced package byte.
# A caller therefore cannot replace a helper and rely on that helper to attest
# to itself.  The release package is immutable for every audit phase.
PACKAGE_ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || {
    printf '%s\n' 'FATAL: could not resolve the package root' >&2
    exit 1
}
readonly PACKAGE_ROOT
readonly PACKAGE_MANIFEST="$PACKAGE_ROOT/SHA256SUMS"
for bootstrap_command in awk cmp dirname find id sha256sum sort stat; do
    command -v "$bootstrap_command" >/dev/null 2>&1 || {
        printf 'FATAL: bootstrap command is unavailable: %s\n' "$bootstrap_command" >&2
        exit 1
    }
done
[[ "$(id -u)" -eq 0 && -d "$PACKAGE_ROOT" && ! -L "$PACKAGE_ROOT" &&
   "$(stat -c '%u:%g' "$PACKAGE_ROOT")" == 0:0 ]] || {
    printf '%s\n' 'FATAL: package root is not a canonical root-owned directory' >&2
    exit 1
}
bootstrap_mode=$(stat -c '%a' "$PACKAGE_ROOT") || exit 1
if [[ ! "$bootstrap_mode" =~ ^[0-7]{3,4}$ ]] || (( (8#$bootstrap_mode & 0022) != 0 )); then
    printf '%s\n' 'FATAL: package root is group/world writable' >&2
    exit 1
fi
[[ -f "$PACKAGE_MANIFEST" && ! -L "$PACKAGE_MANIFEST" &&
   "$(stat -c '%u:%g:%a' "$PACKAGE_MANIFEST")" == 0:0:600 &&
   -z "$(find "$PACKAGE_ROOT" -type l -print -quit)" &&
   -z "$(find "$PACKAGE_ROOT" ! -type d ! -type f -print -quit)" ]] || {
    printf '%s\n' 'FATAL: package manifest or package topology is unsafe' >&2
    exit 1
}
awk 'NF != 2 || $1 !~ /^[0-9a-f]{64}$/ || $2 !~ /^[.]\/[A-Za-z0-9._\/-]+$/ {exit 1}' \
    "$PACKAGE_MANIFEST" || {
    printf '%s\n' 'FATAL: package manifest syntax is not canonical' >&2
    exit 1
}
if ! cmp -s \
    <(cd "$PACKAGE_ROOT" && find . -type f ! -path ./SHA256SUMS -print | sort) \
    <(awk '{name=$2; sub(/^[*]/, "", name); sub(/^[.]\//, "", name); print "./" name}' \
        "$PACKAGE_MANIFEST" | sort) ||
   ! (cd "$PACKAGE_ROOT" && sha256sum --strict -c SHA256SUMS >/dev/null); then
    printf '%s\n' 'FATAL: package manifest does not authenticate the exact package' >&2
    exit 1
fi
unset bootstrap_command bootstrap_mode

# shellcheck source=lib/live_checks.sh
# shellcheck disable=SC1091
source "$PACKAGE_ROOT/lib/live_checks.sh"

readonly RUN_DIR=${1:?usage: fleet_soak_audit.sh ROLLOUT_RUN_DIR}
readonly AUDIT_DIR="$RUN_DIR/exact-32-soak"
readonly STATIC_CACHE="$AUDIT_DIR/static-cache.tsv"
readonly HOUR_SOAK_MANIFEST="$RUN_DIR/HOUR-SOAK-SHA256SUMS"
readonly HOUR_SOAK_DIRECTORIES="$RUN_DIR/HOUR-SOAK-DIRECTORIES"
readonly SOAK_PHASE=${SOAK_PHASE:-soak}
readonly REQUIRED_SAMPLES=${SOAK_REQUIRED_SAMPLES:-4}
readonly DURATION_SECONDS=${SOAK_DURATION_SECONDS:-3600}
readonly MAX_SECONDS=${SOAK_MAX_SECONDS:-7200}
readonly PARALLEL=${SOAK_PARALLEL:-8}

[[ "$SOAK_PHASE" =~ ^(soak|pre-release|post-release)$ ]] || die 'invalid SOAK_PHASE'
[[ "$REQUIRED_SAMPLES" =~ ^[1-9][0-9]*$ && "$DURATION_SECONDS" =~ ^[0-9]+$ &&
   "$MAX_SECONDS" =~ ^[1-9][0-9]*$ && "$PARALLEL" =~ ^[1-9][0-9]*$ ]] ||
    die 'invalid soak controls'
((REQUIRED_SAMPLES >= 4 && REQUIRED_SAMPLES <= 12)) || die 'soak samples must be 4-12'
((DURATION_SECONDS >= 3600 && MAX_SECONDS >= DURATION_SECONDS && PARALLEL <= 16)) ||
    die 'soak duration/parallel controls are outside safe bounds'
valid_rollout_run_dir "$RUN_DIR" ||
    die 'rollout run directory is unsafe'
require_rollout_identity
require_command awk cat chmod cmp cp date docker find install jq mktemp mv realpath rm seq \
    sha256sum sleep sort stat sync timeout wc xargs

declare -A RECOVERY_FEE=()
declare -A RECOVERY_BASELINE_SHA=()

passed_wave_for_node()
{
    local node="$1" wave result nodes_file candidate found='' count=0
    local -a wave_nodes=()
    local -A seen=()
    while IFS= read -r wave; do
        [[ -d "$wave" && ! -L "$wave" && "$(realpath -e -- "$wave")" == "$wave" &&
           "$(stat -c '%u:%g:%a' "$wave")" == 0:0:700 ]] || return 1
        result="$wave/RESULT"
        nodes_file="$wave/NODES"
        if [[ ! -e "$result" && ! -L "$result" ]]; then
            continue
        fi
        [[ -f "$result" && ! -L "$result" && "$(realpath -e -- "$result")" == "$result" &&
           "$(stat -c '%u:%g:%a' "$result")" == 0:0:600 ]] || return 1
        [[ "$(<"$result")" == passed ]] || continue
        [[ -f "$nodes_file" && ! -L "$nodes_file" &&
           "$(realpath -e -- "$nodes_file")" == "$nodes_file" &&
           "$(stat -c '%u:%g:%a' "$nodes_file")" == 0:0:600 &&
           "$(wc -l < "$nodes_file")" -eq 1 ]] || return 1
        read -r -a wave_nodes < "$nodes_file"
        ((${#wave_nodes[@]} >= 1 && ${#wave_nodes[@]} <= 4)) || return 1
        seen=()
        for candidate in "${wave_nodes[@]}"; do
            valid_node "$candidate" && [[ -z "${seen[$candidate]:-}" ]] || return 1
            seen[$candidate]=1
            if [[ "$candidate" -eq "$node" ]]; then
                found="$wave"
                count=$((count + 1))
            fi
        done
    done < <(find "$RUN_DIR" -mindepth 1 -maxdepth 1 -type d -name 'wave-*' -print | sort)
    [[ "$count" -eq 1 && -n "$found" ]] || return 1
    printf '%s\n' "$found"
}

validate_recovery_baseline()
{
    local node="$1" expected_sha="${2:-}" expected_fee="${3:-}"
    local padded path metadata actual_sha metadata_sha fee wave transaction_set
    local transaction_prelaunch transaction_first prelaunch_sha first_sha
    padded=$(node_padded "$node") || return 1
    wave=$(passed_wave_for_node "$node") || return 1
    path="$wave/candidate-recovery-node-${padded}.json"
    metadata="${path}.sha256"
    [[ -f "$path" && ! -L "$path" && "$(realpath -e -- "$path")" == "$path" &&
       -f "$metadata" && ! -L "$metadata" && "$(realpath -e -- "$metadata")" == "$metadata" &&
       "$(stat -c '%u:%g:%a' "$path")" == 0:0:600 &&
       "$(stat -c '%u:%g:%a' "$metadata")" == 0:0:600 ]] || return 1
    actual_sha=$(sha256sum "$path" | awk '{print $1}') || return 1
    metadata_sha=$(<"$metadata")
    [[ "$(wc -l < "$metadata")" -eq 1 && "$metadata_sha" =~ ^[0-9a-f]{64}$ &&
       "$actual_sha" == "$metadata_sha" ]] || return 1
    [[ -z "$expected_sha" || "$actual_sha" == "$expected_sha" ]] || return 1
    transaction_prelaunch="$wave/node-${padded}-wallet-txids.prelaunch.json"
    transaction_first="$wave/node-${padded}-wallet-txids.first-v3014.json"
    for transaction_set in "$transaction_prelaunch" "$transaction_first"; do
        [[ -f "$transaction_set" && ! -L "$transaction_set" &&
           "$(realpath -e -- "$transaction_set")" == "$transaction_set" &&
           "$(stat -c '%u:%g:%a' "$transaction_set")" == 0:0:600 ]] || return 1
        jq -e 'type == "array" and . == (unique | sort) and all(.[];
            type == "string" and test("^[0-9a-f]{64}$"))' "$transaction_set" >/dev/null ||
            return 1
    done
    prelaunch_sha=$(sha256sum "$transaction_prelaunch" | awk '{print $1}') || return 1
    first_sha=$(sha256sum "$transaction_first" | awk '{print $1}') || return 1
    [[ "$prelaunch_sha" == "$first_sha" ]] || return 1
    jq -e --arg image "$CANDIDATE_IMAGE_REF" --arg image_id "$CANDIDATE_IMAGE_ID" \
        --arg source "$SOURCE_COMMIT" --argjson node "$node" \
        --arg prelaunch_sha "$prelaunch_sha" --arg first_sha "$first_sha" \
        --arg wave_dir "$wave" '
        .schema == 2 and .node == $node and .candidate_image == $image and
        .candidate_image_id == $image_id and .source_commit == $source and
        .wave_dir == $wave_dir and
        (.captured_at | type) == "string" and
        (.container_generation | type) == "string" and
        .wallet_locked_throughout == true and .wallet_final.unlocked_until == 0 and
        .staking_final.enabled == false and .staking_final.staking == false and
        .staking_final.worker_running == false and
        .staking_final.allow_automatic_quantum_key_creation == false and
        .mining_final.enabled == false and .mining_final.autostart == false and
        .mining_final.state == "disabled" and .mining_final.hashrate == 0 and
        .mining_final.live_claims == 0 and .mining_final.quarantined_claims == 0 and
        .mining_final.blocking_quarantined_claims == 0 and
        .mining_final.allow_automatic_quantum_key_creation == false and
        .recovery_initial.policy_authoritative == true and
        .recovery_initial.policy.automatic_authorized == false and
        .recovery_initial.database_outcome_ambiguous == false and
        .recovery_final.policy_authoritative == true and
        .recovery_final.policy.automatic_authorized == false and
        .recovery_final.database_outcome_ambiguous == false and
        .recovery_final.chain_ready == true and .recovery_final.wallet_tip_matches == true and
        .recovery_final.blocking_quarantined_claims == 0 and
        .recovery_final.blocking_components == 0 and
        .recovery_final.indeterminate_quarantined_claims == 0 and
        .recovery_final.pending_manual_resolutions == 0 and
        .recovery_final.pending_automatic_resolutions == 0 and
        (.recovery_initial.confirmed_resolution_fees | type) == "number" and
        .recovery_initial.confirmed_resolution_fees >= 0 and
        .recovery_final.confirmed_resolution_fees ==
          .recovery_initial.confirmed_resolution_fees and
        .wallet_transaction_guard.prelaunch_sha256 == $prelaunch_sha and
        .wallet_transaction_guard.first_v3014_sha256 == $first_sha and
        .wallet_transaction_guard.exactly_unchanged == true
    ' "$path" >/dev/null || return 1
    fee=$(jq -er '.recovery_initial.confirmed_resolution_fees |
        select(type == "number" and . >= 0)' \
        "$path") || return 1
    jq -e -n --argjson fee "$fee" '$fee | type == "number" and . >= 0' >/dev/null || return 1
    if [[ -n "$expected_fee" ]]; then
        jq -e -n --argjson fee "$fee" --argjson expected "$expected_fee" \
            '$fee == $expected' >/dev/null || return 1
    fi
    printf '%s|%s\n' "$actual_sha" "$fee"
}

load_recovery_baselines()
{
    local node info baseline_sha fee
    verify_passed_wave_baseline_sets_exact ||
        die 'one or more passed waves lack an exact recovery baseline/checksum set'
    for node in $(seq 1 "$NODE_COUNT"); do
        info=$(validate_recovery_baseline "$node") ||
            die "node $node candidate recovery baseline is invalid"
        IFS='|' read -r baseline_sha fee <<< "$info"
        RECOVERY_BASELINE_SHA[$node]="$baseline_sha"
        RECOVERY_FEE[$node]="$fee"
    done
}

verify_passed_wave_baseline_sets_exact()
{
    local wave result nodes_file candidate padded path expected actual regular passed_waves=0
    local -a wave_nodes=()
    local -A seen=()
    while IFS= read -r wave; do
        [[ -d "$wave" && ! -L "$wave" && "$(realpath -e -- "$wave")" == "$wave" &&
           "$(stat -c '%u:%g:%a' "$wave")" == 0:0:700 ]] || return 1
        result="$wave/RESULT"
        if [[ ! -e "$result" && ! -L "$result" ]]; then
            continue
        fi
        [[ -f "$result" && ! -L "$result" && "$(realpath -e -- "$result")" == "$result" &&
           "$(stat -c '%u:%g:%a' "$result")" == 0:0:600 ]] || return 1
        [[ "$(<"$result")" == passed ]] || continue
        passed_waves=$((passed_waves + 1))
        nodes_file="$wave/NODES"
        [[ -f "$nodes_file" && ! -L "$nodes_file" &&
           "$(realpath -e -- "$nodes_file")" == "$nodes_file" &&
           "$(stat -c '%u:%g:%a' "$nodes_file")" == 0:0:600 &&
           "$(wc -l < "$nodes_file")" -eq 1 ]] || return 1
        read -r -a wave_nodes < "$nodes_file"
        ((${#wave_nodes[@]} >= 1 && ${#wave_nodes[@]} <= 4)) || return 1
        seen=()
        for candidate in "${wave_nodes[@]}"; do
            valid_node "$candidate" && [[ -z "${seen[$candidate]:-}" ]] || return 1
            seen[$candidate]=1
            padded=$(node_padded "$candidate") || return 1
            path="$wave/candidate-recovery-node-${padded}.json"
            [[ -f "$path" && ! -L "$path" && -f "${path}.sha256" &&
               ! -L "${path}.sha256" ]] || return 1
        done
        expected=$((${#wave_nodes[@]} * 2))
        actual=$(find "$wave" -mindepth 1 -maxdepth 1 \
            \( -name 'candidate-recovery-node-*.json' -o \
               -name 'candidate-recovery-node-*.json.sha256' \) -print | wc -l)
        regular=$(find "$wave" -mindepth 1 -maxdepth 1 -type f \
            \( -name 'candidate-recovery-node-*.json' -o \
               -name 'candidate-recovery-node-*.json.sha256' \) -print | wc -l)
        [[ "$actual" -eq "$expected" && "$regular" -eq "$expected" ]] || return 1
    done < <(find "$RUN_DIR" -mindepth 1 -maxdepth 1 -type d -name 'wave-*' -print | sort)
    ((passed_waves >= 1))
}

verify_recovery_baselines_unchanged()
{
    local node
    verify_passed_wave_baseline_sets_exact || return 1
    for node in $(seq 1 "$NODE_COUNT"); do
        validate_recovery_baseline "$node" "${RECOVERY_BASELINE_SHA[$node]}" \
            "${RECOVERY_FEE[$node]}" >/dev/null || return 1
    done
}

protected_regular_file()
{
    local path="$1" expected_mode="${2:-600}"
    [[ -f "$path" && ! -L "$path" && "$(realpath -e -- "$path")" == "$path" &&
       "$(stat -c '%u:%g:%a' "$path")" == "0:0:$expected_mode" ]]
}

verify_active_fleet_maintenance_marker()
{
    local nonce_file="$RUN_DIR/MAINTENANCE-NONCE" nonce
    protected_regular_file "$nonce_file" 600 || return 1
    [[ "$(wc -l < "$nonce_file")" -eq 1 ]] || return 1
    nonce=$(<"$nonce_file")
    valid_sha256_hex "$nonce" || return 1
    protected_regular_file "$ROLLOUT_MAINTENANCE_MARKER" 600 || return 1
    jq -e --arg nonce "$nonce" --arg run "$RUN_DIR" '
        . == {schema:1,transaction:"v30.1.4-fleet-rollout",state:"active",
              run_nonce:$nonce,run_dir:$run}
    ' "$ROLLOUT_MAINTENANCE_MARKER" >/dev/null
}

verify_maintenance_marker_absent()
{
    [[ ! -e "$ROLLOUT_MAINTENANCE_MARKER" && ! -L "$ROLLOUT_MAINTENANCE_MARKER" ]]
}

verify_free_claim_pause_absent()
{
    [[ ! -e "$FREE_CLAIM_PAUSE_MARKER" && ! -L "$FREE_CLAIM_PAUSE_MARKER" ]]
}

read_maintenance_released_epoch()
{
    local path="$RUN_DIR/MAINTENANCE-RELEASED-EPOCH" epoch now
    protected_regular_file "$path" 600 || return 1
    [[ "$(wc -l < "$path")" -eq 1 ]] || return 1
    epoch=$(<"$path")
    [[ "$epoch" =~ ^[1-9][0-9]{8,10}$ ]] || return 1
    now=$(date +%s) || return 1
    ((10#$epoch <= now)) || return 1
    printf '%s\n' "$((10#$epoch))"
}

verify_phase_inhibitors()
{
    protected_regular_file "$RUN_DIR/STATE" 600 || return 1
    case "$SOAK_PHASE" in
        soak)
            [[ "$(<"$RUN_DIR/STATE")" == applying || "$(<"$RUN_DIR/STATE")" == complete ]] ||
                return 1
            verify_active_fleet_maintenance_marker && verify_free_claim_pause
            ;;
        pre-release)
            [[ "$(<"$RUN_DIR/STATE")" == complete ]] || return 1
            verify_maintenance_marker_absent && verify_free_claim_pause
            ;;
        post-release)
            [[ "$(<"$RUN_DIR/STATE")" == complete ]] || return 1
            verify_maintenance_marker_absent && verify_free_claim_pause_absent
            ;;
    esac
}

sleep_while_inhibited()
{
    local remaining="$1" chunk
    [[ "$remaining" =~ ^[0-9]+$ ]] || return 1
    while ((remaining > 0)); do
        verify_phase_inhibitors || return 1
        chunk=5
        ((remaining < chunk)) && chunk=$remaining
        sleep "$chunk"
        remaining=$((remaining - chunk))
    done
    verify_phase_inhibitors
}

verify_audit_topology()
{
    local require_directory_manifest="${1:-0}" path
    [[ -d "$AUDIT_DIR" && ! -L "$AUDIT_DIR" &&
       "$(realpath -e -- "$AUDIT_DIR")" == "$AUDIT_DIR" &&
       "$(stat -c '%u:%g:%a' "$AUDIT_DIR")" == 0:0:700 ]] || return 1
    [[ -z "$(find "$AUDIT_DIR" -type l -print -quit)" &&
       -z "$(find "$AUDIT_DIR" ! -type d ! -type f -print -quit)" ]] || return 1
    while IFS= read -r -d '' path; do
        [[ "$(stat -c '%u:%g:%a' "$path")" == 0:0:700 ]] || return 1
    done < <(find "$AUDIT_DIR" -mindepth 1 -type d -print0)
    while IFS= read -r -d '' path; do
        [[ "$(stat -c '%u:%g:%a' "$path")" == 0:0:600 ]] || return 1
    done < <(find "$AUDIT_DIR" -type f -print0)
    if [[ "$require_directory_manifest" -eq 1 ]]; then
        protected_regular_file "$AUDIT_DIR/DIRECTORIES" 600 || return 1
        cmp -s \
            <(cd "$AUDIT_DIR" && find . -mindepth 1 -type d -print | sort) \
            <(sort "$AUDIT_DIR/DIRECTORIES") || return 1
        cmp -s "$AUDIT_DIR/DIRECTORIES" <(sort -u "$AUDIT_DIR/DIRECTORIES") || return 1
    fi
}

recover_interrupted_finalization_manifest()
{
    local manifest="$AUDIT_DIR/SHA256SUMS" path rel expected actual directories_tmp manifest_tmp
    local listed_rel top found hour_expected hour_actual
    local -A listed=()
    local -A preserved_dirs=()
    [[ "$SOAK_PHASE" != soak ]] || return 1
    protected_regular_file "$manifest" 600 || return 1
    verify_audit_topology 0 || return 1
    while read -r expected rel; do
        [[ "$expected" =~ ^[0-9a-f]{64}$ && -n "$rel" ]] || return 1
        rel=${rel#\*}
        rel=${rel#./}
        [[ -n "$rel" && "$rel" != /* && "$rel" != *'..'* && -z "${listed[$rel]:-}" ]] || return 1
        listed[$rel]=1
        case "$rel" in
            DIRECTORIES|FINALIZATION-READY.json|POST-RELEASE.json) continue ;;
        esac
        [[ -f "$AUDIT_DIR/$rel" && ! -L "$AUDIT_DIR/$rel" ]] || return 1
        actual=$(sha256sum "$AUDIT_DIR/$rel" | awk '{print $1}') || return 1
        [[ "$actual" == "$expected" ]] || return 1
    done < "$manifest"
    [[ -n "${listed[RESULT.json]:-}" ]] || return 1
    protected_regular_file "$HOUR_SOAK_MANIFEST" 600 &&
        protected_regular_file "$HOUR_SOAK_DIRECTORIES" 600 || return 1
    [[ "$(awk '$2 == "../HOUR-SOAK-DIRECTORIES" {count++} END {print count+0}' \
        "$HOUR_SOAK_MANIFEST")" -eq 1 ]] || return 1
    hour_expected=$(awk '$2 == "../HOUR-SOAK-DIRECTORIES" {print $1}' \
        "$HOUR_SOAK_MANIFEST") || return 1
    hour_actual=$(sha256sum "$HOUR_SOAK_DIRECTORIES" | awk '{print $1}') || return 1
    [[ "$hour_expected" =~ ^[0-9a-f]{64}$ && "$hour_actual" == "$hour_expected" ]] || return 1
    (cd "$AUDIT_DIR" && sha256sum --strict -c "$HOUR_SOAK_MANIFEST" >/dev/null) || return 1
    while IFS= read -r rel; do
        [[ "$rel" =~ ^[.]/[A-Za-z0-9][A-Za-z0-9._/-]*$ &&
           ! "$rel" =~ (^|/)\.\.($|/) ]] || return 1
        rel=${rel#./}
        [[ -z "${preserved_dirs[$rel]:-}" ]] || return 1
        preserved_dirs[$rel]=1
    done < "$HOUR_SOAK_DIRECTORIES"
    while IFS= read -r path; do
        rel=${path#"$AUDIT_DIR/"}
        [[ -z "${listed[$rel]:-}" ]] || continue
        [[ "$rel" == FINALIZATION-READY.json || "$rel" == POST-RELEASE.json ]] && continue
        top=${rel%%/*}
        [[ "$top" != "$rel" &&
           "$top" =~ ^finalization-(pre|post)-release-attempt-[0-9]{3,}$ ]] || return 1
    done < <(find "$AUDIT_DIR" -type f -print)
    while IFS= read -r path; do
        rel=${path#"$AUDIT_DIR/"}
        top=${rel%%/*}
        if [[ "$top" =~ ^finalization-(pre|post)-release-attempt-[0-9]{3,}$ ]]; then
            continue
        fi
        [[ -n "${preserved_dirs[$rel]:-}" ]] && continue
        found=0
        for listed_rel in "${!listed[@]}"; do
            if [[ "$listed_rel" == "$rel/"* ]]; then
                found=1
                break
            fi
        done
        ((found == 1)) || return 1
    done < <(find "$AUDIT_DIR" -mindepth 1 -type d -print)
    directories_tmp=$(mktemp "$RUN_DIR/.recover-finalization-directories.XXXXXX") || return 1
    manifest_tmp=$(mktemp "$RUN_DIR/.recover-finalization-manifest.XXXXXX") || {
        rm -f -- "$directories_tmp"; return 1;
    }
    (cd "$AUDIT_DIR" && find . -mindepth 1 -type d -print | sort) > "$directories_tmp" || return 1
    chmod 600 "$directories_tmp" && chown root:root "$directories_tmp" &&
        sync -f "$directories_tmp" || return 1
    mv -fT -- "$directories_tmp" "$AUDIT_DIR/DIRECTORIES" || return 1
    (
        cd "$AUDIT_DIR"
        find . -type f ! -path './SHA256SUMS' -print0 | sort -z | xargs -0 sha256sum
    ) > "$manifest_tmp" || return 1
    chmod 600 "$manifest_tmp" && chown root:root "$manifest_tmp" && sync -f "$manifest_tmp" || return 1
    mv -fT -- "$manifest_tmp" "$manifest" || return 1
    sync -f "$AUDIT_DIR" || return 1
    verify_audit_topology 1 &&
        cmp -s \
            <(cd "$AUDIT_DIR" && find . -type f ! -path './SHA256SUMS' -print | sort) \
            <(awk 'NF == 2 {name=$2; sub(/^\\*/, "", name); print name}' "$manifest" | sort) &&
        (cd "$AUDIT_DIR" && sha256sum --strict -c SHA256SUMS >/dev/null)
}

load_recovery_baselines
RECOVERY_BASELINE_SHA_JSON=$(
    for node in $(seq 1 "$NODE_COUNT"); do
        printf '%s|%s\n' "$(node_padded "$node")" "${RECOVERY_BASELINE_SHA[$node]}"
    done | jq -Rn '[inputs | split("|") | {(.[0]): .[1]}] | add'
)
RECOVERY_BASELINE_SET_SHA256=$(
    for node in $(seq 1 "$NODE_COUNT"); do
        printf '%s|%s\n' "$(node_padded "$node")" "${RECOVERY_BASELINE_SHA[$node]}"
    done | sha256sum | awk '{print $1}'
)
readonly RECOVERY_BASELINE_SHA_JSON RECOVERY_BASELINE_SET_SHA256

if [[ -e "$AUDIT_DIR" || -L "$AUDIT_DIR" ]]; then
    [[ -d "$AUDIT_DIR" && ! -L "$AUDIT_DIR" &&
       "$(realpath -e -- "$AUDIT_DIR")" == "$AUDIT_DIR" &&
       "$(stat -c '%u:%g:%a' "$AUDIT_DIR")" == 0:0:700 ]] ||
        die 'existing soak evidence directory is unsafe'
    verify_audit_topology 0 || die 'existing soak evidence topology is unsafe'
    if [[ "$SOAK_PHASE" != soak && -f "$AUDIT_DIR/SHA256SUMS" ]] &&
       { ! verify_audit_topology 1 ||
         ! cmp -s \
            <(cd "$AUDIT_DIR" && find . -type f ! -path './SHA256SUMS' -print | sort) \
            <(awk 'NF >= 2 {name=$2; sub(/^\\*/, "", name); print name}' \
                "$AUDIT_DIR/SHA256SUMS" | sort) ||
         ! (cd "$AUDIT_DIR" && sha256sum --strict -c SHA256SUMS >/dev/null); }; then
        recover_interrupted_finalization_manifest ||
            die 'interrupted finalization evidence could not be safely resealed'
    fi
    if [[ "$SOAK_PHASE" == soak ]]; then
        [[ "${SOAK_RESUME:-0}" == 1 ]] ||
            die 'SOAK_RESUME=1 is required to continue incomplete soak evidence'
    fi
else
    [[ "$SOAK_PHASE" == soak ]] ||
        die 'finalization requires an existing authenticated hour-soak directory'
    install -d -m 700 -o root -g root "$AUDIT_DIR"
fi

PRIOR_RESULT=0
INVALID_PRIOR_RESULT=0
PRIOR_RESULT_SHA256=''
if [[ -e "$AUDIT_DIR/RESULT.json" || -L "$AUDIT_DIR/RESULT.json" ]]; then
    [[ -f "$AUDIT_DIR/RESULT.json" && ! -L "$AUDIT_DIR/RESULT.json" &&
       "$(realpath -e -- "$AUDIT_DIR/RESULT.json")" == "$AUDIT_DIR/RESULT.json" &&
       "$(stat -c '%u:%g:%a' "$AUDIT_DIR/RESULT.json")" == 0:0:600 ]] ||
        die 'existing soak result is unsafe'
    jq -e --arg image "$CANDIDATE_IMAGE_REF" --arg id "$CANDIDATE_IMAGE_ID" \
        '.image == $image and .image_id == $id' \
        "$AUDIT_DIR/RESULT.json" >/dev/null || die 'existing soak result belongs to another candidate'
    if [[ -f "$AUDIT_DIR/SHA256SUMS" && ! -L "$AUDIT_DIR/SHA256SUMS" &&
          "$(realpath -e -- "$AUDIT_DIR/SHA256SUMS")" == "$AUDIT_DIR/SHA256SUMS" &&
          "$(stat -c '%u:%g:%a' "$AUDIT_DIR/SHA256SUMS")" == 0:0:600 ]] &&
       verify_audit_topology 1 &&
       cmp -s \
          <(cd "$AUDIT_DIR" && find . -type f ! -path './SHA256SUMS' -print | sort) \
          <(awk 'NF >= 2 {name=$2; sub(/^\\*/, "", name); print name}' \
              "$AUDIT_DIR/SHA256SUMS" | sort) &&
       (cd "$AUDIT_DIR" && sha256sum --strict -c SHA256SUMS >/dev/null) &&
       jq -e --slurpfile transaction "$RUN_DIR/TRANSACTION.json" \
          -f "$PACKAGE_ROOT/lib/hour_soak_result.jq" "$AUDIT_DIR/RESULT.json" >/dev/null &&
       jq -e --argjson recovery_baselines "$RECOVERY_BASELINE_SHA_JSON" \
          --arg recovery_baseline_set_sha "$RECOVERY_BASELINE_SET_SHA256" '
          .claim_recovery_baseline_sha256s == $recovery_baselines and
          .claim_recovery_baseline_set_sha256 == $recovery_baseline_set_sha
       ' "$AUDIT_DIR/RESULT.json" >/dev/null; then
        PRIOR_RESULT=1
        PRIOR_RESULT_SHA256=$(sha256sum "$AUDIT_DIR/RESULT.json" | awk '{print $1}')
    else
        INVALID_PRIOR_RESULT=1
    fi
elif [[ -e "$AUDIT_DIR/SHA256SUMS" || -L "$AUDIT_DIR/SHA256SUMS" ]]; then
    die 'soak checksum manifest exists without its result'
fi

if [[ "$SOAK_PHASE" != soak ]]; then
    [[ "$PRIOR_RESULT" -eq 1 ]] ||
        die 'finalization requires an authenticated, passed full-hour soak result'
fi
HOUR_SOAK_MANIFEST_SHA256=''
if [[ "$SOAK_PHASE" != soak ]]; then
    if [[ ! -e "$HOUR_SOAK_DIRECTORIES" && ! -L "$HOUR_SOAK_DIRECTORIES" ]]; then
        hour_directories_tmp=$(mktemp "$RUN_DIR/.hour-soak-directories.XXXXXX") ||
            die 'could not create preserved hour-soak directory inventory'
        install -m 600 -o root -g root "$AUDIT_DIR/DIRECTORIES" "$hour_directories_tmp" ||
            die 'could not stage preserved hour-soak directory inventory'
        sync -f "$hour_directories_tmp" || die 'could not sync preserved hour-soak directory inventory'
        mv -fT -- "$hour_directories_tmp" "$HOUR_SOAK_DIRECTORIES" ||
            die 'could not publish preserved hour-soak directory inventory'
        sync -f "$RUN_DIR" || die 'could not sync preserved hour-soak directory inventory parent'
    fi
    protected_regular_file "$HOUR_SOAK_DIRECTORIES" 600 ||
        die 'preserved hour-soak directory inventory is unsafe'
    if [[ ! -e "$HOUR_SOAK_MANIFEST" && ! -L "$HOUR_SOAK_MANIFEST" ]]; then
        cmp -s "$AUDIT_DIR/DIRECTORIES" "$HOUR_SOAK_DIRECTORIES" ||
            die 'preserved hour-soak directory inventory differs before manifest publication'
        hour_manifest_tmp=$(mktemp "$RUN_DIR/.hour-soak-manifest.XXXXXX") ||
            die 'could not create preserved hour-soak manifest'
        awk '$2 != "./DIRECTORIES" && $2 != "DIRECTORIES"' "$AUDIT_DIR/SHA256SUMS" \
            > "$hour_manifest_tmp" || die 'could not stage preserved hour-soak manifest'
        (cd "$AUDIT_DIR" && sha256sum ../HOUR-SOAK-DIRECTORIES) >> "$hour_manifest_tmp" ||
            die 'could not bind preserved hour-soak directory inventory'
        if ! chmod 600 "$hour_manifest_tmp" || ! chown root:root "$hour_manifest_tmp"; then
            die 'could not protect preserved hour-soak manifest'
        fi
        sync -f "$hour_manifest_tmp" || die 'could not sync preserved hour-soak manifest'
        mv -fT -- "$hour_manifest_tmp" "$HOUR_SOAK_MANIFEST" ||
            die 'could not publish preserved hour-soak manifest'
        sync -f "$RUN_DIR" || die 'could not sync preserved hour-soak manifest parent'
    fi
    protected_regular_file "$HOUR_SOAK_MANIFEST" 600 ||
        die 'preserved hour-soak manifest is unsafe'
    hour_manifest_invalid=$(awk '
        NF != 2 || $1 !~ /^[0-9a-f]{64}$/ {print; next}
        {
          name=$2
          if (seen[name]++) {print; next}
          if (name == "../HOUR-SOAK-DIRECTORIES") {directories++; next}
          if (name !~ /^[.]\/[A-Za-z0-9][A-Za-z0-9._\/-]*$/ || name ~ /(^|\/)\.\.($|\/)/ ||
              name == "./DIRECTORIES") print
        }
        END {if (directories != 1) print "invalid-directory-binding"}
    ' "$HOUR_SOAK_MANIFEST") || die 'could not parse preserved hour-soak manifest'
    [[ -z "$hour_manifest_invalid" ]] ||
        die 'preserved hour-soak manifest paths are not exact, unique, and in scope'
    hour_directories_invalid=$(awk '
        $0 !~ /^[.]\/[A-Za-z0-9][A-Za-z0-9._\/-]*$/ || $0 ~ /(^|\/)\.\.($|\/)/ {print}
    ' "$HOUR_SOAK_DIRECTORIES") || die 'could not parse preserved hour-soak directory inventory'
    [[ -z "$hour_directories_invalid" ]] ||
        die 'preserved hour-soak directory inventory contains an unsafe path'
    cmp -s "$HOUR_SOAK_DIRECTORIES" <(sort -u "$HOUR_SOAK_DIRECTORIES") ||
        die 'preserved hour-soak directory inventory is not sorted and unique'
    HOUR_SOAK_MANIFEST_SHA256=$(sha256sum "$HOUR_SOAK_MANIFEST" | awk '{print $1}') ||
        die 'could not hash preserved hour-soak manifest'
    valid_sha256_hex "$HOUR_SOAK_MANIFEST_SHA256" ||
        die 'preserved hour-soak manifest hash is malformed'
    (cd "$AUDIT_DIR" && sha256sum --strict -c "$HOUR_SOAK_MANIFEST" >/dev/null) ||
        die 'preserved hour-soak evidence changed'
    [[ "$(awk '$2 == "./RESULT.json" || $2 == "RESULT.json" {count++} END {print count+0}' \
        "$HOUR_SOAK_MANIFEST")" -eq 1 ]] ||
        die 'preserved hour-soak manifest does not bind its result exactly once'
fi
readonly HOUR_SOAK_MANIFEST_SHA256
verify_phase_inhibitors || die "transaction inhibitor state is invalid for phase $SOAK_PHASE"
MAINTENANCE_RELEASED_EPOCH=''
if [[ "$SOAK_PHASE" != soak ]]; then
    MAINTENANCE_RELEASED_EPOCH=$(read_maintenance_released_epoch) ||
        die 'maintenance release epoch is missing, unsafe, or not numeric'
fi
readonly MAINTENANCE_RELEASED_EPOCH

declare -A GOOD=()
declare -A STATIC_PASS=()
declare -A GENERATION=()
declare -A STATIC_CACHE_SEEN=()
for node in $(seq 1 "$NODE_COUNT"); do
    GOOD[$node]=0
    STATIC_PASS[$node]=0
    GENERATION[$node]=''
done
if [[ -e "$STATIC_CACHE" || -L "$STATIC_CACHE" ]]; then
    [[ -f "$STATIC_CACHE" && ! -L "$STATIC_CACHE" &&
       "$(realpath -e -- "$STATIC_CACHE")" == "$STATIC_CACHE" &&
       "$(stat -c '%u:%g:%a' "$STATIC_CACHE")" == 0:0:600 ]] ||
        die 'static soak cache is unsafe'
fi
if [[ "$INVALID_PRIOR_RESULT" -eq 0 && -f "$STATIC_CACHE" ]]; then
    while IFS='|' read -r node generation; do
        valid_node "$node" || die 'static soak cache contains an invalid node'
        [[ -z "${STATIC_CACHE_SEEN[$node]:-}" ]] ||
            die 'static soak cache contains a duplicate node'
        STATIC_CACHE_SEEN[$node]=1
        [[ -n "$generation" ]] || die 'static soak cache contains an empty generation'
        if [[ "$(container_generation_for "$node" 2>/dev/null || true)" == "$generation" ]]; then
            STATIC_PASS[$node]=1
            GENERATION[$node]="$generation"
        fi
    done < "$STATIC_CACHE"
fi
if [[ "$SOAK_PHASE" != soak ]]; then
    [[ -f "$STATIC_CACHE" && ! -L "$STATIC_CACHE" ]] ||
        die 'authenticated hour-soak generation cache is missing'
    [[ "$(wc -l < "$STATIC_CACHE")" -eq "$NODE_COUNT" ]] ||
        die 'authenticated hour-soak generation cache is not exact-32'
    for node in $(seq 1 "$NODE_COUNT"); do
        [[ "${STATIC_PASS[$node]}" -eq 1 && -n "${GENERATION[$node]}" ]] ||
            die "node $node generation changed after the authenticated hour soak"
    done
fi

attempt_number=1
if [[ "$SOAK_PHASE" == soak ]]; then
    attempt_prefix=attempt
else
    attempt_prefix="finalization-${SOAK_PHASE}-attempt"
fi
while [[ -e "$(printf '%s/%s-%03d' "$AUDIT_DIR" "$attempt_prefix" "$attempt_number")" ||
         -L "$(printf '%s/%s-%03d' "$AUDIT_DIR" "$attempt_prefix" "$attempt_number")" ]]; do
    attempt_number=$((attempt_number + 1))
done
ATTEMPT_DIR=$(printf '%s/%s-%03d' "$AUDIT_DIR" "$attempt_prefix" "$attempt_number")
readonly ATTEMPT_DIR
[[ ! -e "$ATTEMPT_DIR" && ! -L "$ATTEMPT_DIR" ]] || die 'soak attempt path collision'
install -d -m 700 -o root -g root "$ATTEMPT_DIR"
if [[ "$SOAK_PHASE" == soak ]]; then
    install -d -m 700 -o root -g root "$ATTEMPT_DIR/samples"
fi

verify_dynamic_node()
{
    local node="$1"
    verify_vpn_pair "$node" || return 1
    live_netns_matches "$node" || return 1
    verify_core_common "$node" || return 1
    verify_replay_state "$node" || return 1
    verify_staking "$node" || return 1
    verify_donation_defaults_off "$node" || return 1
    if [[ "$node" -eq "$FREE_CLAIM_NODE" ]]; then
        verify_node30_free_claim "${RECOVERY_FEE[$node]}" || return 1
        if [[ "$SOAK_PHASE" == post-release ]]; then
            verify_free_claim_pause_absent || return 1
        else
            verify_free_claim_pause || return 1
        fi
    else
        verify_standard_pow "$node" "${RECOVERY_FEE[$node]}" || return 1
    fi
    if [[ "$node" -eq 31 || "$node" -eq 32 ]]; then
        verify_quantum_special "$node" || return 1
    fi
}

probe_node()
{
    local node="$1" sample="$2" result="$3" static_pass="$4" expected_generation="$5"
    local generation_before generation_after probe_passed=0

    if ! generation_before=$(container_generation_for "$node"); then
        printf '%s\n' fail > "$result"
    elif [[ "$static_pass" -eq 0 ]]; then
        if verify_node_gate "$node" "${RECOVERY_FEE[$node]}"; then
            probe_passed=1
        fi
        if ! generation_after=$(container_generation_for "$node") ||
           [[ "$generation_before" != "$generation_after" ]]; then
            printf '%s\n' generation-changed > "$result"
        elif [[ "$probe_passed" -eq 1 ]]; then
            printf '%s\n' "$generation_after" > "${result}.generation"
            printf '%s\n' pass > "$result"
        else
            printf '%s\n' fail > "$result"
        fi
    elif [[ "$generation_before" != "$expected_generation" ]]; then
        printf '%s\n' generation-changed > "$result"
    else
        if verify_dynamic_node "$node"; then
            probe_passed=1
        fi
        if ! generation_after=$(container_generation_for "$node") ||
           [[ "$generation_before" != "$generation_after" ||
              "$generation_after" != "$expected_generation" ]]; then
            printf '%s\n' generation-changed > "$result"
        elif [[ "$probe_passed" -eq 1 ]]; then
            printf '%s\n' pass > "$result"
        else
            printf '%s\n' fail > "$result"
        fi
    fi
    printf '%s\n' "$sample" > "${result}.sample"
}

capture_exact_32_generation_map()
{
    local output="$1" parts temporary node pid generation failed=0
    local -a pids=()
    parts=$(mktemp -d "${output%/*}/.generation-parts.XXXXXX") || return 1
    for node in $(seq 1 "$NODE_COUNT"); do
        (
            generation=$(container_generation_for "$node") || exit 1
            [[ -n "$generation" && "$generation" != *$'\n'* ]] || exit 1
            printf '%s\n' "$generation" > "$parts/node-$(node_padded "$node")"
        ) &
        pids+=("$!")
    done
    for node in "${!pids[@]}"; do
        pid=${pids[$node]}
        if ! wait "$pid"; then
            failed=1
        fi
    done
    if [[ "$failed" -ne 0 ||
          "$(find "$parts" -mindepth 1 -maxdepth 1 -type f -name 'node-*' | wc -l)" -ne "$NODE_COUNT" ]]; then
        rm -rf -- "$parts"
        return 1
    fi
    temporary=$(mktemp "${output%/*}/.generation-map.XXXXXX") || {
        rm -rf -- "$parts"
        return 1
    }
    for node in $(seq 1 "$NODE_COUNT"); do
        generation=$(<"$parts/node-$(node_padded "$node")")
        [[ -n "$generation" && "$generation" != *$'\n'* ]] || {
            rm -rf -- "$parts" "$temporary"
            return 1
        }
        printf '%s|%s\n' "$(node_padded "$node")" "$generation" >> "$temporary"
    done
    chmod 600 "$temporary"
    mv -fT -- "$temporary" "$output"
    sync -f "$output"
    rm -rf -- "$parts"
}

write_expected_generation_map()
{
    local output="$1" temporary node
    temporary=$(mktemp "${output%/*}/.expected-generation-map.XXXXXX") || return 1
    for node in $(seq 1 "$NODE_COUNT"); do
        [[ "${STATIC_PASS[$node]}" -eq 1 && -n "${GENERATION[$node]}" ]] || {
            rm -f -- "$temporary"
            return 1
        }
        printf '%s|%s\n' "$(node_padded "$node")" "${GENERATION[$node]}" >> "$temporary"
    done
    chmod 600 "$temporary"
    mv -fT -- "$temporary" "$output"
    sync -f "$output"
}

verify_final_dynamic_all_nodes()
{
    local final_dir="$ATTEMPT_DIR/final-all-32-dynamic" node result pid failed=0
    local generation_before="$ATTEMPT_DIR/final-all-32-dynamic/GENERATIONS.before"
    local generation_after="$ATTEMPT_DIR/final-all-32-dynamic/GENERATIONS.after"
    local generation_expected="$ATTEMPT_DIR/final-all-32-dynamic/GENERATIONS.expected"
    local -a pids=()
    install -d -m 700 -o root -g root "$final_dir"
    write_expected_generation_map "$generation_expected" || return 1
    capture_exact_32_generation_map "$generation_before" || return 1
    cmp -s "$generation_expected" "$generation_before" || return 1
    for node in $(seq 1 "$NODE_COUNT"); do
        [[ "${STATIC_PASS[$node]}" -eq 1 && -n "${GENERATION[$node]}" ]] || return 1
        result="$final_dir/node-$(node_padded "$node").result"
        (
            if verify_dynamic_node "$node"; then
                printf '%s\n' pass > "$result"
            else
                printf '%s\n' fail > "$result"
            fi
            printf '%s\n' final > "${result}.sample"
        ) &
        pids+=("$!")
    done
    for pid in "${pids[@]}"; do
        wait "$pid" || failed=1
    done
    [[ "$failed" -eq 0 ]] || return 1
    for node in $(seq 1 "$NODE_COUNT"); do
        result="$final_dir/node-$(node_padded "$node").result"
        [[ -f "$result" && "$(cat "$result")" == pass ]] || return 1
    done
    capture_exact_32_generation_map "$generation_after" || return 1
    cmp -s "$generation_before" "$generation_after" || return 1
    cmp -s "$generation_expected" "$generation_after" || return 1
    date -u +%FT%TZ > "$final_dir/PASSED_AT"
    sync -f "$final_dir/PASSED_AT"
}

verify_global_chain_convergence()
{
    local root="$ATTEMPT_DIR/final-chain-convergence" session attempt=0 attempt_dir node pid count
    local deadline=$((SECONDS + 1200))
    local -a pids=()
    install -d -m 700 -o root -g root "$root"
    session=$(mktemp -d "$root/check-XXXXXX") || return 1
    chmod 700 "$session"
    while ((SECONDS < deadline)); do
        verify_phase_inhibitors || return 1
        attempt=$((attempt + 1))
        attempt_dir=$(printf '%s/attempt-%03d' "$session" "$attempt")
        install -d -m 700 -o root -g root "$attempt_dir"
        pids=()
        for node in $(seq 1 "$NODE_COUNT"); do
            (
                rpc_for "$node" getblockchaininfo | jq -c --argjson node "$node" \
                    '{node:$node,chain,blocks,headers,bestblockhash,chainwork,initialblockdownload}' \
                    > "$attempt_dir/node-$(node_padded "$node").json"
            ) &
            pids+=("$!")
        done
        for pid in "${pids[@]}"; do wait "$pid" || true; done
        count=$(find "$attempt_dir" -maxdepth 1 -type f -name 'node-*.json' | wc -l)
        if [[ "$count" -eq "$NODE_COUNT" ]] && jq -e -s '
            length == 32 and
            all(.[]; .chain == "main" and .initialblockdownload == false and
                (.blocks | type) == "number" and (.headers | type) == "number" and
                .headers >= .blocks and (.headers - .blocks) <= 2 and
                (.bestblockhash | type) == "string" and (.bestblockhash | length) == 64 and
                (.chainwork | type) == "string" and (.chainwork | length) > 0) and
            ([.[].blocks] | unique | length) == 1 and
            ([.[].bestblockhash] | unique | length) == 1 and
            ([.[].chainwork] | unique | length) == 1
        ' "$attempt_dir"/node-*.json >/dev/null; then
            jq -s 'sort_by(.node)' "$attempt_dir"/node-*.json > "$session/PASSED.json"
            sync -f "$session/PASSED.json"
            return 0
        fi
        ((SECONDS < deadline)) && sleep 2
    done
    return 1
}

verify_final_policy_assets()
{
    local policy_sha pin_sha
    policy_sha=$(sha256sum "$IMAGE_POLICY" | awk '{print $1}') || return 1
    pin_sha=$(sed -n "s/^EXPECTED_IMAGE_POLICY_SHA='\([0-9a-f]\{64\}\)'$/\1/p" "$ENDPOINT_GUARD") ||
        return 1
    [[ "$policy_sha" == "$pin_sha" ]] || return 1
    jq -e --arg ref "$CANDIDATE_IMAGE_REF" --arg id "$CANDIDATE_IMAGE_ID" '
        .images.final3014.config_image == $ref and .images.final3014.image_id == $id and
        (.nodes | length == 32) and all(.nodes[]; . == "final3014")
    ' "$IMAGE_POLICY" >/dev/null
}

safe_live_asset()
{
    local path="$1" owner mode
    [[ -f "$path" && ! -L "$path" && "$(realpath -e -- "$path")" == "$path" ]] ||
        return 1
    owner=$(stat -c '%u:%g' "$path") || return 1
    mode=$(stat -c '%a' "$path") || return 1
    [[ "$owner" == 0:0 && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 0022) == 0 ))
}

verify_live_fleet_matches_policy()
{
    local model node padded class expected_ref expected_id service container
    model=$(docker compose -f "$COMPOSE_FILE" config --format json) || return 1
    for node in $(seq 1 "$NODE_COUNT"); do
        padded=$(node_padded "$node") || return 1
        service=$(service_for "$node") || return 1
        container=$(container_for "$node") || return 1
        class=$(jq -er --arg node "$padded" '.nodes[$node]' "$IMAGE_POLICY") || return 1
        expected_ref=$(jq -er --arg class "$class" '.images[$class].config_image' \
            "$IMAGE_POLICY") || return 1
        expected_id=$(jq -er --arg class "$class" '.images[$class].image_id' \
            "$IMAGE_POLICY") || return 1
        jq -e --arg service "$service" --arg ref "$expected_ref" \
            '.services[$service].image == $ref' >/dev/null <<< "$model" || return 1
        [[ "$(docker inspect -f '{{.Config.Image}}' "$container")" == "$expected_ref" ]] ||
            return 1
        [[ "$(docker inspect -f '{{.Image}}' "$container")" == "$expected_id" ]] ||
            return 1
    done
}

capture_final_fleet_identity()
{
    local output="$1" parts temporary model node padded service container class
    local expected_ref expected_id config_ref image_id compose_before policy_before
    local endpoint_before runtime_before compose_after policy_after endpoint_after runtime_after
    safe_live_asset "$COMPOSE_FILE" && safe_live_asset "$IMAGE_POLICY" &&
        safe_live_asset "$ENDPOINT_GUARD" && safe_live_asset "$WALLET_RUNTIME_GUARD" || return 1
    compose_before=$(sha256sum "$COMPOSE_FILE" | awk '{print $1}') || return 1
    policy_before=$(sha256sum "$IMAGE_POLICY" | awk '{print $1}') || return 1
    endpoint_before=$(sha256sum "$ENDPOINT_GUARD" | awk '{print $1}') || return 1
    runtime_before=$(sha256sum "$WALLET_RUNTIME_GUARD" | awk '{print $1}') || return 1
    for expected_id in "$compose_before" "$policy_before" "$endpoint_before" "$runtime_before"; do
        valid_sha256_hex "$expected_id" || return 1
    done
    verify_final_policy_assets && verify_live_fleet_matches_policy || return 1
    model=$(docker compose -f "$COMPOSE_FILE" config --format json) || return 1
    parts=$(mktemp -d "${output%/*}/.fleet-identity-parts.XXXXXX") || return 1
    chmod 700 "$parts" || { rm -rf -- "$parts"; return 1; }
    for node in $(seq 1 "$NODE_COUNT"); do
        padded=$(node_padded "$node") || { rm -rf -- "$parts"; return 1; }
        service=$(service_for "$node") || { rm -rf -- "$parts"; return 1; }
        container=$(container_for "$node") || { rm -rf -- "$parts"; return 1; }
        class=$(jq -er --arg node "$padded" '.nodes[$node]' "$IMAGE_POLICY") || {
            rm -rf -- "$parts"; return 1;
        }
        expected_ref=$(jq -er --arg class "$class" '.images[$class].config_image' \
            "$IMAGE_POLICY") || { rm -rf -- "$parts"; return 1; }
        expected_id=$(jq -er --arg class "$class" '.images[$class].image_id' \
            "$IMAGE_POLICY") || { rm -rf -- "$parts"; return 1; }
        config_ref=$(docker inspect -f '{{.Config.Image}}' "$container") || {
            rm -rf -- "$parts"; return 1;
        }
        image_id=$(docker inspect -f '{{.Image}}' "$container") || {
            rm -rf -- "$parts"; return 1;
        }
        [[ "$expected_ref" == "$CANDIDATE_IMAGE_REF" &&
           "$expected_id" == "$CANDIDATE_IMAGE_ID" &&
           "$config_ref" == "$expected_ref" && "$image_id" == "$expected_id" ]] || {
            rm -rf -- "$parts"; return 1;
        }
        jq -n --argjson node "$node" --arg service "$service" --arg container "$container" \
            --arg config_image "$config_ref" --arg image_id "$image_id" \
            '{node:$node,service:$service,container:$container,
              config_image:$config_image,image_id:$image_id}' \
            > "$parts/node-$padded.json" || { rm -rf -- "$parts"; return 1; }
        jq -e --arg service "$service" --arg ref "$config_ref" \
            '.services[$service].image == $ref' >/dev/null <<< "$model" || {
            rm -rf -- "$parts"; return 1;
        }
    done
    compose_after=$(sha256sum "$COMPOSE_FILE" | awk '{print $1}') || {
        rm -rf -- "$parts"; return 1;
    }
    policy_after=$(sha256sum "$IMAGE_POLICY" | awk '{print $1}') || {
        rm -rf -- "$parts"; return 1;
    }
    endpoint_after=$(sha256sum "$ENDPOINT_GUARD" | awk '{print $1}') || {
        rm -rf -- "$parts"; return 1;
    }
    runtime_after=$(sha256sum "$WALLET_RUNTIME_GUARD" | awk '{print $1}') || {
        rm -rf -- "$parts"; return 1;
    }
    [[ "$compose_before" == "$compose_after" && "$policy_before" == "$policy_after" &&
       "$endpoint_before" == "$endpoint_after" && "$runtime_before" == "$runtime_after" ]] || {
        rm -rf -- "$parts"; return 1;
    }
    verify_live_fleet_matches_policy || { rm -rf -- "$parts"; return 1; }
    temporary=$(mktemp "${output%/*}/.fleet-identity.XXXXXX") || {
        rm -rf -- "$parts"; return 1;
    }
    jq -n --arg compose "$compose_after" --arg policy "$policy_after" \
        --arg endpoint "$endpoint_after" --arg runtime "$runtime_after" \
        --slurpfile nodes <(jq -s 'sort_by(.node)' "$parts"/node-*.json) \
        '{schema:1,compose_sha256:$compose,image_policy_sha256:$policy,
          endpoint_guard_sha256:$endpoint,wallet_runtime_guard_sha256:$runtime,
          nodes:$nodes[0]}' > "$temporary" || {
        rm -rf -- "$parts" "$temporary"; return 1;
    }
    jq -e --arg image "$CANDIDATE_IMAGE_REF" --arg id "$CANDIDATE_IMAGE_ID" '
        .schema == 1 and (.nodes | length) == 32 and
        [.nodes[].node] == [range(1;33)] and
        all(.nodes[]; .config_image == $image and .image_id == $id)
    ' "$temporary" >/dev/null || { rm -rf -- "$parts" "$temporary"; return 1; }
    chmod 600 "$temporary" || { rm -rf -- "$parts" "$temporary"; return 1; }
    chown root:root "$temporary" || { rm -rf -- "$parts" "$temporary"; return 1; }
    sync -f "$temporary" || { rm -rf -- "$parts" "$temporary"; return 1; }
    mv -fT -- "$temporary" "$output" || { rm -rf -- "$parts" "$temporary"; return 1; }
    sync -f "$output" || { rm -rf -- "$parts"; return 1; }
    rm -rf -- "$parts"
}

verify_captured_fleet_identity_current()
{
    local identity="$1" expected actual field path
    protected_regular_file "$identity" 600 || return 1
    while IFS='|' read -r field path; do
        expected=$(jq -er ".$field | select(type == \"string\")" "$identity") || return 1
        valid_sha256_hex "$expected" || return 1
        actual=$(sha256sum "$path" | awk '{print $1}') || return 1
        [[ "$actual" == "$expected" ]] || return 1
    done <<EOF
compose_sha256|$COMPOSE_FILE
image_policy_sha256|$IMAGE_POLICY
endpoint_guard_sha256|$ENDPOINT_GUARD
wallet_runtime_guard_sha256|$WALLET_RUNTIME_GUARD
EOF
    verify_final_policy_assets && verify_live_fleet_matches_policy
}

SUPERVISOR_TIMESTAMP=''
SUPERVISOR_TIMESTAMP_EPOCH=''
SUPERVISOR_STATUS_SHA256=''
supervisor_epoch_is_fresh_after()
{
    local observed="$1" lower_bound="$2" now_epoch="$3"
    [[ "$observed" =~ ^[1-9][0-9]*$ && "$lower_bound" =~ ^[1-9][0-9]*$ &&
       "$now_epoch" =~ ^[1-9][0-9]*$ ]] || return 1
    ((observed > lower_bound && observed <= now_epoch && observed >= now_epoch - 300))
}

capture_fresh_supervisor()
{
    local output="$1" minimum_epoch="$2" supervisor before copied after temporary timestamp
    local timestamp_epoch now_epoch
    local mode owner deadline=$((SECONDS + 1200))
    supervisor=/mnt/pulsar/Blackcoin_Blocks/operations/fleet-supervisor-status.json
    while ((SECONDS < deadline)); do
        verify_phase_inhibitors || return 1
        if [[ -f "$supervisor" && ! -L "$supervisor" &&
              "$(realpath -e -- "$supervisor" 2>/dev/null || true)" == "$supervisor" ]]; then
            owner=$(stat -c '%u:%g' "$supervisor" 2>/dev/null || true)
            mode=$(stat -c '%a' "$supervisor" 2>/dev/null || true)
            if [[ "$owner" == 0:0 && "$mode" =~ ^[0-7]{3,4}$ ]] &&
               (( (8#$mode & 0022) == 0 )); then
                before=$(sha256sum "$supervisor" 2>/dev/null | awk '{print $1}') || before=''
                temporary=$(mktemp "${output%/*}/.supervisor-status.XXXXXX") || return 1
                if install -m 600 -o root -g root "$supervisor" "$temporary"; then
                    copied=$(sha256sum "$temporary" 2>/dev/null | awk '{print $1}') || copied=''
                    after=$(sha256sum "$supervisor" 2>/dev/null | awk '{print $1}') || after=''
                    timestamp=$(jq -er '.timestamp | select(type == "string")' \
                        "$temporary" 2>/dev/null || true)
                    timestamp_epoch=$(date -d "$timestamp" +%s 2>/dev/null || true)
                    now_epoch=$(date +%s)
                    if valid_sha256_hex "$before" && [[ "$before" == "$copied" &&
                       "$before" == "$after" ]] &&
                       supervisor_epoch_is_fresh_after "$timestamp_epoch" "$minimum_epoch" \
                           "$now_epoch" &&
                       jq -e '.state == "healthy" and .verified == 32 and .running == 32 and
                           .operational == 32 and .failures == 0' "$temporary" >/dev/null; then
                        sync -f "$temporary" || { rm -f -- "$temporary"; return 1; }
                        mv -fT -- "$temporary" "$output" || {
                            rm -f -- "$temporary"; return 1;
                        }
                        sync -f "$output" || return 1
                        SUPERVISOR_TIMESTAMP=$timestamp
                        SUPERVISOR_TIMESTAMP_EPOCH=$timestamp_epoch
                        SUPERVISOR_STATUS_SHA256=$before
                        return 0
                    fi
                fi
                rm -f -- "$temporary"
            fi
        fi
        ((SECONDS < deadline)) && sleep 5
    done
    return 1
}

write_audit_checksums()
{
    local temporary directories_tmp
    [[ -z "$(find "$AUDIT_DIR" -type l -print -quit)" ]] || return 1
    [[ -z "$(find "$AUDIT_DIR" ! -type d ! -type f -print -quit)" ]] || return 1
    directories_tmp=$(mktemp "$RUN_DIR/.exact-32-soak-directories.XXXXXX") || return 1
    (cd "$AUDIT_DIR" && find . -mindepth 1 -type d -print | sort) > "$directories_tmp" || {
        rm -f -- "$directories_tmp"; return 1;
    }
    if ! chmod 600 "$directories_tmp" || ! chown root:root "$directories_tmp" ||
       ! sync -f "$directories_tmp"; then
        rm -f -- "$directories_tmp"
        return 1
    fi
    mv -fT -- "$directories_tmp" "$AUDIT_DIR/DIRECTORIES" || {
        rm -f -- "$directories_tmp"; return 1;
    }
    sync -f "$AUDIT_DIR/DIRECTORIES" || return 1
    verify_audit_topology 1 || return 1
    temporary=$(mktemp "$RUN_DIR/.exact-32-soak-sha256.XXXXXX")
    (
        cd "$AUDIT_DIR"
        find . -type f ! -path './SHA256SUMS' -print0 | sort -z | xargs -0 sha256sum
    ) > "$temporary"
    chmod 600 "$temporary"
    mv -fT -- "$temporary" "$AUDIT_DIR/SHA256SUMS"
    cmp -s \
        <(cd "$AUDIT_DIR" && find . -type f ! -path './SHA256SUMS' -print | sort) \
        <(awk 'NF >= 2 {name=$2; sub(/^\\*/, "", name); print name}' \
            "$AUDIT_DIR/SHA256SUMS" | sort) || return 1
    (cd "$AUDIT_DIR" && sha256sum --strict -c SHA256SUMS >/dev/null) || return 1
    verify_audit_topology 1 || return 1
    sync -f "$AUDIT_DIR/SHA256SUMS"
    sync -f "$AUDIT_DIR"
}

verify_finalization_ready()
{
    local require_fresh="${1:-1}"
    local ready="$AUDIT_DIR/FINALIZATION-READY.json" identity_rel supervisor_rel attempt_rel
    local identity supervisor identity_sha supervisor_sha supervisor_timestamp supervisor_epoch now_epoch
    local transaction="$RUN_DIR/TRANSACTION.json" transaction_sha nonce_file="$RUN_DIR/MAINTENANCE-NONCE" nonce
    local generation_expected_rel generation_final_rel generation_expected generation_final
    local generation_expected_sha generation_final_sha
    protected_regular_file "$ready" 600 || return 1
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
    identity="$AUDIT_DIR/$identity_rel"
    supervisor="$AUDIT_DIR/$supervisor_rel"
    generation_expected="$AUDIT_DIR/$generation_expected_rel"
    generation_final="$AUDIT_DIR/$generation_final_rel"
    protected_regular_file "$identity" 600 && protected_regular_file "$supervisor" 600 &&
        protected_regular_file "$generation_expected" 600 &&
        protected_regular_file "$generation_final" 600 || return 1
    identity_sha=$(sha256sum "$identity" | awk '{print $1}') || return 1
    supervisor_sha=$(sha256sum "$supervisor" | awk '{print $1}') || return 1
    generation_expected_sha=$(sha256sum "$generation_expected" | awk '{print $1}') || return 1
    generation_final_sha=$(sha256sum "$generation_final" | awk '{print $1}') || return 1
    [[ "$generation_expected_sha" == "$generation_final_sha" ]] || return 1
    cmp -s "$generation_expected" "$generation_final" || return 1
    protected_regular_file "$transaction" 600 && protected_regular_file "$nonce_file" 600 || return 1
    [[ "$(wc -l < "$nonce_file")" -eq 1 ]] || return 1
    nonce=$(<"$nonce_file")
    valid_sha256_hex "$nonce" || return 1
    transaction_sha=$(sha256sum "$transaction" | awk '{print $1}') || return 1
    jq -e --arg nonce "$nonce" '.maintenance.run_nonce == $nonce' "$transaction" >/dev/null || return 1
    supervisor_timestamp=$(jq -er '.timestamp | select(type == "string")' "$supervisor") || return 1
    [[ "$supervisor_timestamp" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] ||
        return 1
    supervisor_epoch=$(date -d "$supervisor_timestamp" +%s 2>/dev/null) || return 1
    now_epoch=$(date +%s) || return 1
    [[ "$supervisor_epoch" =~ ^[1-9][0-9]*$ ]] || return 1
    [[ "$require_fresh" == 0 || "$require_fresh" == 1 ]] || return 1
    ((supervisor_epoch <= now_epoch)) || return 1
    if [[ "$require_fresh" -eq 1 ]]; then
        ((supervisor_epoch >= now_epoch - 300)) || return 1
    fi
    jq -e --arg image "$CANDIDATE_IMAGE_REF" --arg id "$CANDIDATE_IMAGE_ID" '
        .schema == 1 and (.nodes | length) == 32 and
        [.nodes[].node] == [range(1;33)] and
        all(.nodes[]; .config_image == $image and .image_id == $id) and
        (.compose_sha256 | test("^[0-9a-f]{64}$")) and
        (.image_policy_sha256 | test("^[0-9a-f]{64}$")) and
        (.endpoint_guard_sha256 | test("^[0-9a-f]{64}$")) and
        (.wallet_runtime_guard_sha256 | test("^[0-9a-f]{64}$"))
    ' "$identity" >/dev/null || return 1
    jq -e --arg image "$CANDIDATE_IMAGE_REF" --arg id "$CANDIDATE_IMAGE_ID" \
        --arg source "$SOURCE_COMMIT" --arg result_sha "$PRIOR_RESULT_SHA256" \
        --arg hour_manifest_sha "$HOUR_SOAK_MANIFEST_SHA256" \
        --arg identity_rel "$identity_rel" --arg identity_sha "$identity_sha" \
        --arg supervisor_rel "$supervisor_rel" --arg supervisor_sha "$supervisor_sha" \
        --arg supervisor_timestamp "$supervisor_timestamp" --arg run "$RUN_DIR" \
        --arg transaction_sha "$transaction_sha" --arg nonce "$nonce" \
        --arg generation_expected_rel "$generation_expected_rel" \
        --arg generation_expected_sha "$generation_expected_sha" \
        --arg generation_final_rel "$generation_final_rel" \
        --arg generation_final_sha "$generation_final_sha" \
        --argjson supervisor_epoch "$supervisor_epoch" \
        --argjson released "$MAINTENANCE_RELEASED_EPOCH" \
        --argjson recovery_baselines "$RECOVERY_BASELINE_SHA_JSON" \
        --arg recovery_set "$RECOVERY_BASELINE_SET_SHA256" \
        --slurpfile identity "$identity" '
        .schema == 1 and .result == "passed" and .phase == "pre-release" and
        .run_dir == $run and .transaction_manifest_sha256 == $transaction_sha and
        .run_nonce == $nonce and
        .image == $image and .image_id == $id and .source_commit == $source and
        .prior_hour_soak_result_sha256 == $result_sha and
        .prior_authenticated_manifest_path == "../HOUR-SOAK-SHA256SUMS" and
        .prior_authenticated_manifest_sha256 == $hour_manifest_sha and
        .maintenance_marker_absent == true and
        .maintenance_released_epoch == $released and
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
        ($identity | length) == 1 and
        .compose_sha256 == $identity[0].compose_sha256 and
        .image_policy_sha256 == $identity[0].image_policy_sha256 and
        .endpoint_guard_sha256 == $identity[0].endpoint_guard_sha256 and
        .wallet_runtime_guard_sha256 == $identity[0].wallet_runtime_guard_sha256 and
        .nodes_healthy == 32 and .pos_active == 32 and .regular_pow_active == 31 and
        .free_claim_node == 30 and .free_claim_regular_pow == false and
        .final_concurrent_dynamic_gate == true and
        .final_exact_32_generation_fence == true and
        .global_chain_convergence == true and .vpn_proofs_valid_unique == 32 and
        .final_policy_assets_valid == true and
        .live_compose_container_policy_match == true and
        .identity_recovery_baselines_unchanged == true and
        .claim_recovery_fee_unchanged == true and .fee_payments_authorized == false and
        .claim_recovery_baseline_sha256s == $recovery_baselines and
        .claim_recovery_baseline_set_sha256 == $recovery_set
    ' "$ready" >/dev/null || return 1
    jq -e --arg timestamp "$supervisor_timestamp" '
        .timestamp == $timestamp and .state == "healthy" and .verified == 32 and
        .running == 32 and .operational == 32 and .failures == 0
    ' "$supervisor" >/dev/null
}

run_finalization_phase()
{
    local output output_name identity="$ATTEMPT_DIR/FLEET-IDENTITY.json"
    local supervisor="$ATTEMPT_DIR/SUPERVISOR-STATUS.json" expected_generation
    local identity_sha identity_rel supervisor_rel compose_sha policy_sha endpoint_sha runtime_sha
    local generation_expected="$ATTEMPT_DIR/GENERATIONS.expected"
    local generation_after_supervisor="$ATTEMPT_DIR/GENERATIONS.after-supervisor"
    local generation_final="$ATTEMPT_DIR/GENERATIONS.before-publication"
    local generation_expected_sha generation_final_sha generation_expected_rel generation_final_rel
    local transaction="$RUN_DIR/TRANSACTION.json" transaction_sha nonce_file="$RUN_DIR/MAINTENANCE-NONCE" nonce
    local result_tmp paused api_healthy=false stale_gate=false
    local release_receipt="$RUN_DIR/FREE-CLAIM-RELEASED.json"
    local release_sidecar="$RUN_DIR/FREE-CLAIM-RELEASED.sha256"
    local release_receipt_rel='' release_receipt_sha='' expected_release_sha=''
    local free_claim_released_epoch=0 supervisor_after_epoch="$MAINTENANCE_RELEASED_EPOCH" now_epoch

    [[ "$SOAK_PHASE" == pre-release || "$SOAK_PHASE" == post-release ]] || return 1
    if [[ "$SOAK_PHASE" == post-release ]]; then
        /bin/bash "$PACKAGE_ROOT/release_transaction_inhibitors.sh" verify-release \
            "$AUDIT_DIR/RESULT.json" "$RUN_DIR/STATE" "$AUDIT_DIR/FINALIZATION-READY.json" \
            >/dev/null || die 'post-release audit lacks the durable release receipt'
        if ! protected_regular_file "$release_receipt" 600 ||
           ! protected_regular_file "$release_sidecar" 600; then
            die 'post-release audit release receipt topology is unsafe'
        fi
        release_receipt_sha=$(sha256sum "$release_receipt" | awk '{print $1}') ||
            die 'post-release audit could not hash the release receipt'
        expected_release_sha=$(awk 'NF == 1 && $1 ~ /^[0-9a-f]{64}$/ {print $1}' \
            "$release_sidecar") || die 'post-release audit could not parse the release receipt sidecar'
        [[ -n "$expected_release_sha" && "$(wc -l < "$release_sidecar")" -eq 1 &&
           "$release_receipt_sha" == "$expected_release_sha" ]] ||
            die 'post-release audit release receipt sidecar does not match'
        jq -e '
            .schema == 1 and .transaction == "v30.1.4-free-claim-release" and
            .receipt_published_before_pause_removal == true and
            .release_protocol == "write-ahead-v1" and
            .free_claim_pause_absent == true
        ' "$release_receipt" >/dev/null ||
            die 'post-release audit release receipt lacks write-ahead proof'
        free_claim_released_epoch=$(jq -er '.released_at_epoch | select(type == "number")' \
            "$release_receipt") || die 'post-release audit release epoch is missing'
        now_epoch=$(date +%s) || die 'post-release audit could not read current epoch'
        if [[ ! "$free_claim_released_epoch" =~ ^[1-9][0-9]*$ ]] ||
           ((free_claim_released_epoch <= MAINTENANCE_RELEASED_EPOCH ||
             free_claim_released_epoch > now_epoch)); then
            die 'post-release audit release epoch is invalid'
        fi
        release_receipt_rel=../FREE-CLAIM-RELEASED.json
        supervisor_after_epoch=$free_claim_released_epoch
        verify_finalization_ready 0 ||
            die 'post-release audit lacks authenticated pre-release readiness evidence'
        output_name=POST-RELEASE.json
        paused=false
    else
        output_name=FINALIZATION-READY.json
        paused=true
    fi
    output="$AUDIT_DIR/$output_name"
    if [[ -e "$output" || -L "$output" ]]; then
        protected_regular_file "$output" 600 ||
            die "existing $output_name is unsafe"
    fi

    verify_phase_inhibitors || die "transaction inhibitor state changed before $SOAK_PHASE audit"
    verify_recovery_baselines_unchanged ||
        die "candidate recovery baselines changed before $SOAK_PHASE audit"
    verify_global_chain_convergence ||
        die "all 32 nodes did not converge during $SOAK_PHASE audit"
    assert_unique_vpn_proofs || die "VPN proof set is not exact-32 unique during $SOAK_PHASE audit"
    verify_final_policy_assets || die "final image policy is invalid during $SOAK_PHASE audit"
    verify_live_fleet_matches_policy ||
        die "live Compose/container identities differ from policy during $SOAK_PHASE audit"
    verify_final_dynamic_all_nodes ||
        die "exact-32 concurrent dynamic/generation gate failed during $SOAK_PHASE audit"
    assert_unique_vpn_proofs || die "VPN identities changed during $SOAK_PHASE dynamic gate"
    if ! verify_final_policy_assets || ! verify_live_fleet_matches_policy; then
        die "policy or live fleet identity changed during $SOAK_PHASE dynamic gate"
    fi
    verify_recovery_baselines_unchanged ||
        die "candidate recovery baselines changed during $SOAK_PHASE dynamic gate"
    verify_phase_inhibitors || die "transaction inhibitor state changed during $SOAK_PHASE audit"

    capture_fresh_supervisor "$supervisor" "$supervisor_after_epoch" ||
        die 'no genuinely healthy exact-32 supervisor observation appeared after the required release boundary'
    write_expected_generation_map "$generation_expected" ||
        die 'could not write expected exact-32 finalization generations'
    capture_exact_32_generation_map "$generation_after_supervisor" ||
        die 'could not capture exact-32 generations after supervisor evidence'
    cmp -s "$generation_expected" "$generation_after_supervisor" ||
        die 'a fleet generation changed while obtaining supervisor evidence'
    capture_final_fleet_identity "$identity" ||
        die "could not capture exact final fleet identity during $SOAK_PHASE audit"
    verify_captured_fleet_identity_current "$identity" ||
        die 'live Compose/container/guard identity changed after final identity capture'
    verify_recovery_baselines_unchanged ||
        die 'candidate recovery baselines changed after supervisor evidence'
    verify_phase_inhibitors || die 'transaction inhibitor state changed before finalization publication'
    verify_node30_free_claim_service ||
        die "node30 API or stale-broadcast gate failed during $SOAK_PHASE audit"
    api_healthy=true
    stale_gate=true
    verify_captured_fleet_identity_current "$identity" ||
        die 'live Compose/container/guard identity changed before finalization publication'
    capture_exact_32_generation_map "$generation_final" ||
        die 'could not capture exact-32 generations immediately before finalization publication'
    cmp -s "$generation_expected" "$generation_final" ||
        die 'a fleet generation changed before finalization publication'

    identity_sha=$(sha256sum "$identity" | awk '{print $1}') || return 1
    valid_sha256_hex "$identity_sha" && valid_sha256_hex "$SUPERVISOR_STATUS_SHA256" || return 1
    identity_rel=${identity#"$AUDIT_DIR/"}
    supervisor_rel=${supervisor#"$AUDIT_DIR/"}
    compose_sha=$(jq -er '.compose_sha256' "$identity") || return 1
    policy_sha=$(jq -er '.image_policy_sha256' "$identity") || return 1
    endpoint_sha=$(jq -er '.endpoint_guard_sha256' "$identity") || return 1
    runtime_sha=$(jq -er '.wallet_runtime_guard_sha256' "$identity") || return 1
    generation_expected_sha=$(sha256sum "$generation_expected" | awk '{print $1}') || return 1
    generation_final_sha=$(sha256sum "$generation_final" | awk '{print $1}') || return 1
    [[ "$generation_expected_sha" == "$generation_final_sha" ]] || return 1
    generation_expected_rel=${generation_expected#"$AUDIT_DIR/"}
    generation_final_rel=${generation_final#"$AUDIT_DIR/"}
    protected_regular_file "$transaction" 600 && protected_regular_file "$nonce_file" 600 || return 1
    [[ "$(wc -l < "$nonce_file")" -eq 1 ]] || return 1
    nonce=$(<"$nonce_file")
    valid_sha256_hex "$nonce" || return 1
    transaction_sha=$(sha256sum "$transaction" | awk '{print $1}') || return 1
    jq -e --arg nonce "$nonce" '.maintenance.run_nonce == $nonce' "$transaction" >/dev/null || return 1
    if [[ "$SOAK_PHASE" == post-release ]]; then
        [[ "$(sha256sum "$release_receipt" | awk '{print $1}')" == "$release_receipt_sha" &&
           "$(<"$release_sidecar")" == "$release_receipt_sha" ]] || return 1
    fi
    for expected_generation in "$compose_sha" "$policy_sha" "$endpoint_sha" "$runtime_sha"; do
        valid_sha256_hex "$expected_generation" || return 1
    done

    result_tmp=$(mktemp "$RUN_DIR/.${output_name}.XXXXXX") || return 1
    jq -n --arg result passed --arg phase "$SOAK_PHASE" \
        --arg completed "$(date -u +%FT%TZ)" --arg image "$CANDIDATE_IMAGE_REF" \
        --arg image_id "$CANDIDATE_IMAGE_ID" --arg source "$SOURCE_COMMIT" \
        --arg prior_result_sha "$PRIOR_RESULT_SHA256" \
        --arg prior_manifest_sha "$HOUR_SOAK_MANIFEST_SHA256" \
        --arg supervisor_sha "$SUPERVISOR_STATUS_SHA256" \
        --arg supervisor_timestamp "$SUPERVISOR_TIMESTAMP" \
        --arg supervisor_rel "$supervisor_rel" --arg identity_sha "$identity_sha" \
        --arg identity_rel "$identity_rel" --arg compose_sha "$compose_sha" \
        --arg policy_sha "$policy_sha" --arg endpoint_sha "$endpoint_sha" \
        --arg runtime_sha "$runtime_sha" --arg run "$RUN_DIR" \
        --arg transaction_sha "$transaction_sha" --arg nonce "$nonce" \
        --arg generation_expected_rel "$generation_expected_rel" \
        --arg generation_expected_sha "$generation_expected_sha" \
        --arg generation_final_rel "$generation_final_rel" \
        --arg generation_final_sha "$generation_final_sha" \
        --arg release_receipt_rel "$release_receipt_rel" \
        --arg release_receipt_sha "$release_receipt_sha" \
        --argjson free_claim_released_epoch "$free_claim_released_epoch" \
        --argjson supervisor_epoch "$SUPERVISOR_TIMESTAMP_EPOCH" \
        --argjson released_epoch "$MAINTENANCE_RELEASED_EPOCH" \
        --argjson paused "$paused" --argjson api_healthy "$api_healthy" \
        --argjson stale_gate "$stale_gate" \
        --argjson recovery_baselines "$RECOVERY_BASELINE_SHA_JSON" \
        --arg recovery_set "$RECOVERY_BASELINE_SET_SHA256" '
        {schema:1,result:$result,phase:$phase,completed_at:$completed,
         run_dir:$run,transaction_manifest_sha256:$transaction_sha,run_nonce:$nonce,
         image:$image,image_id:$image_id,source_commit:$source,
         prior_hour_soak_result_sha256:$prior_result_sha,
         prior_authenticated_manifest_path:"../HOUR-SOAK-SHA256SUMS",
         prior_authenticated_manifest_sha256:$prior_manifest_sha,
         maintenance_marker_absent:true,maintenance_released_epoch:$released_epoch,
         free_claim_broadcasts_paused:$paused,free_claim_service_healthy:$api_healthy,
         stale_broadcast_gate_passed:$stale_gate,
         free_claim_release_receipt_path:(if $phase == "post-release" then $release_receipt_rel else null end),
         free_claim_release_receipt_sha256:(if $phase == "post-release" then $release_receipt_sha else null end),
         free_claim_released_at_epoch:(if $phase == "post-release" then $free_claim_released_epoch else null end),
         supervisor_status_sha256:$supervisor_sha,
         supervisor_timestamp:$supervisor_timestamp,
         supervisor_timestamp_epoch:$supervisor_epoch,
         supervisor_evidence:$supervisor_rel,
         fleet_identity_evidence:$identity_rel,
         fleet_identity_evidence_sha256:$identity_sha,
         generation_expected_evidence:$generation_expected_rel,
         generation_expected_sha256:$generation_expected_sha,
         generation_before_publication_evidence:$generation_final_rel,
         generation_before_publication_sha256:$generation_final_sha,
         compose_sha256:$compose_sha,image_policy_sha256:$policy_sha,
         endpoint_guard_sha256:$endpoint_sha,wallet_runtime_guard_sha256:$runtime_sha,
         nodes_healthy:32,pos_active:32,regular_pow_active:31,
         free_claim_node:30,free_claim_regular_pow:false,
         final_concurrent_dynamic_gate:true,global_chain_convergence:true,
         final_exact_32_generation_fence:true,vpn_proofs_valid_unique:32,
         final_policy_assets_valid:true,live_compose_container_policy_match:true,
         identity_recovery_baselines_unchanged:true,
         claim_recovery_fee_unchanged:true,fee_payments_authorized:false,
         claim_recovery_baseline_sha256s:$recovery_baselines,
         claim_recovery_baseline_set_sha256:$recovery_set}' > "$result_tmp" || {
        rm -f -- "$result_tmp"; return 1;
    }
    jq -e --argjson released "$MAINTENANCE_RELEASED_EPOCH" \
        --argjson free_claim_released "$free_claim_released_epoch" '
        .schema == 1 and .result == "passed" and
        .supervisor_timestamp_epoch > $released and
        (.phase != "post-release" or .supervisor_timestamp_epoch > $free_claim_released)
    ' "$result_tmp" >/dev/null || { rm -f -- "$result_tmp"; return 1; }
    if ! chmod 600 "$result_tmp" || ! chown root:root "$result_tmp" ||
       ! sync -f "$result_tmp"; then
        rm -f -- "$result_tmp"; return 1;
    fi
    mv -fT -- "$result_tmp" "$output" || { rm -f -- "$result_tmp"; return 1; }
    sync -f "$output" || return 1
    write_audit_checksums || return 1
    if [[ "$SOAK_PHASE" == pre-release ]]; then
        verify_finalization_ready || return 1
    else
        jq -e --arg image "$CANDIDATE_IMAGE_REF" --arg id "$CANDIDATE_IMAGE_ID" \
            --arg source "$SOURCE_COMMIT" --argjson released "$MAINTENANCE_RELEASED_EPOCH" \
            --arg receipt_rel "$release_receipt_rel" --arg receipt_sha "$release_receipt_sha" \
            --argjson free_claim_released "$free_claim_released_epoch" '
            .schema == 1 and .result == "passed" and .phase == "post-release" and
            .image == $image and .image_id == $id and .source_commit == $source and
            .maintenance_marker_absent == true and
            .maintenance_released_epoch == $released and
            .free_claim_broadcasts_paused == false and
            .free_claim_release_receipt_path == $receipt_rel and
            .free_claim_release_receipt_sha256 == $receipt_sha and
            .free_claim_released_at_epoch == $free_claim_released and
            .free_claim_service_healthy == true and .stale_broadcast_gate_passed == true and
            .supervisor_timestamp_epoch > $released and
            .supervisor_timestamp_epoch > $free_claim_released and
            .nodes_healthy == 32 and .pos_active == 32 and .regular_pow_active == 31 and
            .free_claim_node == 30 and .free_claim_regular_pow == false and
            .final_concurrent_dynamic_gate == true and
            .final_exact_32_generation_fence == true and
            .global_chain_convergence == true and .vpn_proofs_valid_unique == 32 and
            .final_policy_assets_valid == true and
            .live_compose_container_policy_match == true and
            .identity_recovery_baselines_unchanged == true and
            .claim_recovery_fee_unchanged == true and .fee_payments_authorized == false
        ' "$output" >/dev/null || return 1
    fi
    log "$SOAK_PHASE exact-32 finalization audit passed: $output"
}

if [[ "$SOAK_PHASE" != soak ]]; then
    run_finalization_phase
    exit 0
fi

if [[ "$INVALID_PRIOR_RESULT" -eq 1 ]]; then
    install -m 600 -o root -g root "$AUDIT_DIR/RESULT.json" \
        "$ATTEMPT_DIR/PRIOR-RESULT.invalidated.json"
    rm -f -- "$AUDIT_DIR/RESULT.json" "$AUDIT_DIR/SHA256SUMS" "$STATIC_CACHE"
    log 'prior soak result lacked authenticated full-duration evidence; beginning a new soak window'
fi

verify_active_fleet_maintenance_marker ||
    die 'durable fleet maintenance marker is not active for soak'
verify_free_claim_pause || die 'Free Claim broadcasts are not durably paused for soak'
verify_recovery_baselines_unchanged || die 'candidate recovery baselines changed before soak'

if [[ "$PRIOR_RESULT" -eq 1 ]]; then
    if verify_global_chain_convergence && assert_unique_vpn_proofs &&
       verify_final_policy_assets && verify_active_fleet_maintenance_marker &&
       verify_final_dynamic_all_nodes &&
       assert_unique_vpn_proofs && verify_final_policy_assets &&
       verify_active_fleet_maintenance_marker && verify_free_claim_pause &&
       verify_recovery_baselines_unchanged; then
        verify_active_fleet_maintenance_marker ||
            die 'durable fleet maintenance marker was lost before reuse evidence publication'
        revalidation_tmp=$(mktemp "$ATTEMPT_DIR/.REVALIDATION.XXXXXX")
        jq -n --arg result passed --arg at "$(date -u +%FT%TZ)" \
            --arg image "$CANDIDATE_IMAGE_REF" --arg image_id "$CANDIDATE_IMAGE_ID" \
            --arg source "$SOURCE_COMMIT" \
            --argjson recovery_baselines "$RECOVERY_BASELINE_SHA_JSON" \
            --arg recovery_baseline_set_sha "$RECOVERY_BASELINE_SET_SHA256" \
            '{schema:1,result:$result,revalidated_at:$at,image:$image,image_id:$image_id,
              source_commit:$source,reused_prior_hour_soak:true,
              final_concurrent_dynamic_gate:true,global_chain_convergence:true,
              vpn_proofs_valid_unique:32,
              external_supervisors_maintenance_inhibited:true,
              supervisor_freshness_deferred_to_finalization:true,
              final_exact_32_generation_fence:true,
              replay_state_schema:12,replay_state_valid_nodes:32,
              donation_defaults_off_nodes:32,
              activation_wallet_transaction_sets_unchanged:true,
              wallet_transaction_guard_unchanged_nodes:32,
              free_claim_broadcasts_paused:true,claim_recovery_fee_unchanged:true,
              fee_payments_authorized:false,
              claim_recovery_baseline_sha256s:$recovery_baselines,
              claim_recovery_baseline_set_sha256:$recovery_baseline_set_sha}' \
            > "$revalidation_tmp"
        chmod 600 "$revalidation_tmp"
        sync -f "$revalidation_tmp"
        mv -fT -- "$revalidation_tmp" "$ATTEMPT_DIR/REVALIDATION.json"
        sync -f "$ATTEMPT_DIR"
        write_audit_checksums
        log "prior hour soak freshly revalidated without repetition: $ATTEMPT_DIR"
        exit 0
    fi
    install -m 600 -o root -g root "$AUDIT_DIR/RESULT.json" \
        "$ATTEMPT_DIR/PRIOR-RESULT.invalidated.json"
    rm -f -- "$AUDIT_DIR/RESULT.json" "$AUDIT_DIR/SHA256SUMS"
    log 'prior soak result did not pass fresh fleet revalidation; beginning a new dynamic soak window'
fi

start_epoch=$(date +%s)
sample=0
interval=$((DURATION_SECONDS / (REQUIRED_SAMPLES - 1)))
((interval >= 60)) || interval=60

while :; do
    sample=$((sample + 1))
    sample_dir=$(printf '%s/samples/sample-%03d' "$ATTEMPT_DIR" "$sample")
    install -d -m 700 -o root -g root "$sample_dir"
    verify_active_fleet_maintenance_marker || die 'durable fleet maintenance marker was lost during soak'
    verify_free_claim_pause || die 'Free Claim pause was lost during soak'
    verify_recovery_baselines_unchanged || die 'candidate recovery baseline changed during soak'
    active=0
    running_jobs=0
    pids=()
    for node in $(seq 1 "$NODE_COUNT"); do
        if [[ "${GOOD[$node]}" -ge "$REQUIRED_SAMPLES" ]]; then
            continue
        fi
        active=$((active + 1))
        probe_node "$node" "$sample" "$sample_dir/node-$(node_padded "$node").result" \
            "${STATIC_PASS[$node]}" "${GENERATION[$node]}" &
        pids+=("$!")
        running_jobs=$((running_jobs + 1))
        if ((running_jobs >= PARALLEL)); then
            wait "${pids[0]}" || true
            pids=("${pids[@]:1}")
            running_jobs=$((running_jobs - 1))
        fi
    done
    for pid in "${pids[@]}"; do wait "$pid" || true; done

    for node in $(seq 1 "$NODE_COUNT"); do
        result="$sample_dir/node-$(node_padded "$node").result"
        [[ -f "$result" ]] || continue
        if [[ "$(cat "$result")" == pass ]]; then
            GOOD[$node]=$((GOOD[$node] + 1))
            STATIC_PASS[$node]=1
            if [[ -f "${result}.generation" ]]; then
                GENERATION[$node]=$(cat "${result}.generation")
            fi
        elif [[ "$(cat "$result")" == generation-changed ]]; then
            GOOD[$node]=0
            STATIC_PASS[$node]=0
            GENERATION[$node]=''
        else
            GOOD[$node]=0
        fi
    done

    cache_tmp="$AUDIT_DIR/.static-cache.tsv.$$"
    : > "$cache_tmp"
    for node in $(seq 1 "$NODE_COUNT"); do
        if [[ "${STATIC_PASS[$node]}" -eq 1 ]]; then
            printf '%s|%s\n' "$node" "${GENERATION[$node]}" >> "$cache_tmp"
        fi
    done
    chmod 600 "$cache_tmp"
    mv -f -- "$cache_tmp" "$STATIC_CACHE"

    jq -n --argjson sample "$sample" --arg at "$(date -u +%FT%TZ)" \
        --argjson required "$REQUIRED_SAMPLES" \
        --arg counts "$(for node in $(seq 1 "$NODE_COUNT"); do printf '%02d=%s ' "$node" "${GOOD[$node]}"; done)" \
        '{sample:$sample,observed_at:$at,required_consecutive_samples:$required,
          consecutive_good_counts:$counts}' > "$sample_dir/SUMMARY.json"

    complete=1
    for node in $(seq 1 "$NODE_COUNT"); do
        if [[ "${GOOD[$node]}" -lt "$REQUIRED_SAMPLES" ]]; then complete=0; break; fi
    done
    now=$(date +%s)
    elapsed=$((now - start_epoch))
    if [[ "$complete" -eq 1 && "$elapsed" -ge "$DURATION_SECONDS" ]]; then
        break
    fi
    ((elapsed < MAX_SECONDS)) || die 'exact-32 soak did not converge before the maximum duration'

    next_due=$((start_epoch + sample * interval))
    sleep_for=$((next_due - now))
    if ((sleep_for > 0)); then
        sleep_while_inhibited "$sleep_for" ||
            die 'transaction inhibitor state changed between soak samples'
    fi
done

verify_global_chain_convergence ||
    die 'all 32 nodes did not converge on one best block, height, and chainwork'

assert_unique_vpn_proofs || die 'final VPN proof set is not exact-32 and unique'
verify_final_policy_assets || die 'final image policy/guard pin is not exact-32 v30.1.4'
verify_active_fleet_maintenance_marker ||
    die 'durable fleet maintenance marker was lost before final dynamic gate'
verify_final_dynamic_all_nodes ||
    die 'final concurrent dynamic/generation gate did not pass for all 32 nodes'
assert_unique_vpn_proofs || die 'VPN proof uniqueness changed during the final dynamic gate'
verify_final_policy_assets || die 'image policy/guard pin changed during the final dynamic gate'
verify_active_fleet_maintenance_marker ||
    die 'durable fleet maintenance marker was lost during the final dynamic gate'
verify_free_claim_pause || die 'Free Claim pause was lost before soak evidence publication'
verify_recovery_baselines_unchanged ||
    die 'candidate recovery baseline changed before soak evidence publication'

result_tmp=$(mktemp "$AUDIT_DIR/.RESULT.XXXXXX")
jq -n --arg result passed --arg started "$(date -u -d "@$start_epoch" +%FT%TZ)" \
    --arg completed "$(date -u +%FT%TZ)" --arg image "$CANDIDATE_IMAGE_REF" \
    --arg image_id "$CANDIDATE_IMAGE_ID" --arg source "$SOURCE_COMMIT" \
    --argjson recovery_baselines "$RECOVERY_BASELINE_SHA_JSON" \
    --arg recovery_baseline_set_sha "$RECOVERY_BASELINE_SET_SHA256" \
    --argjson samples "$sample" --argjson duration "$(( $(date +%s) - start_epoch ))" \
    '{schema:1,result:$result,started_at:$started,completed_at:$completed,
      image:$image,image_id:$image_id,source_commit:$source,
      total_sample_rounds:$samples,duration_seconds:$duration,
      nodes_healthy:32,pos_active:32,regular_pow_active:31,
      free_claim_node:30,free_claim_regular_pow:false,
      free_claim_broadcasts_paused:true,claim_recovery_fee_unchanged:true,
      fee_payments_authorized:false,
      quantum_special_nodes:[31,32],vpn_proofs_valid_unique:32,
      final_concurrent_dynamic_gate:true,global_chain_convergence:true,
      final_exact_32_generation_fence:true,
      external_supervisors_maintenance_inhibited:true,
      supervisor_freshness_deferred_to_finalization:true,replay_state_schema:12,
      replay_state_valid_nodes:32,donation_defaults_off_nodes:32,
      activation_wallet_transaction_sets_unchanged:true,
      wallet_transaction_guard_unchanged_nodes:32,
      claim_recovery_baseline_sha256s:$recovery_baselines,
      claim_recovery_baseline_set_sha256:$recovery_baseline_set_sha}' \
    > "$result_tmp"
jq -e --slurpfile transaction "$RUN_DIR/TRANSACTION.json" \
    -f "$PACKAGE_ROOT/lib/hour_soak_result.jq" "$result_tmp" >/dev/null ||
    die 'produced hour-soak result does not satisfy the shared release contract'
verify_active_fleet_maintenance_marker ||
    die 'durable fleet maintenance marker was lost before soak result publication'
verify_free_claim_pause || die 'Free Claim pause was lost before soak result publication'
chmod 600 "$result_tmp"
sync -f "$result_tmp"
mv -fT -- "$result_tmp" "$AUDIT_DIR/RESULT.json"
sync -f "$AUDIT_DIR"

write_audit_checksums
log "exact-32 soak passed: $AUDIT_DIR"
