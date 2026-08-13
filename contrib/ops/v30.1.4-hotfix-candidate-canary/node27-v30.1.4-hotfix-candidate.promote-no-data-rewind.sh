#!/usr/bin/env bash
export LC_ALL=C
set -Eeuo pipefail
umask 077

PACKAGE_ROOT=$(CDPATH='' cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || exit 1
readonly PACKAGE_ROOT
# shellcheck source=lib/typed_contract.sh
# shellcheck source-path=SCRIPTDIR
source "$PACKAGE_ROOT/lib/typed_contract.sh"

readonly COMPOSE='/boot/config/plugins/compose.manager/projects/blackcoin30/docker-compose.yml'
readonly SERVICE='node27'
readonly CONTAINER='blackcoin-v4-gui-27'
readonly CLI='/usr/local/bin/blackcoin-cli'
readonly DATADIR='/home/blackcoin/.blackcoin'
readonly HOST_DATADIR='/mnt/pulsar/Blackcoin_Blocks/node-data/node-27'
readonly HOST_RAW='/mnt/pulsar/Blackcoin_Blocks/27/blocks'
readonly STATE_ROOT='/boot/config/plugins/blackcoin-quantum-nodes'
readonly ENABLE_GUARD_STARTS="${STATE_ROOT}/ENABLE_GUARD_STARTS"
readonly MAINTENANCE_MARKER="${STATE_ROOT}/V30_1_4_ROLLOUT_MAINTENANCE.json"
readonly NORMAL_UNLOCK_HELPER="${STATE_ROOT}/blackcoin_node_normal_unlock.sh"
readonly RUNTIME_GUARD="${STATE_ROOT}/blackcoin_wallet_runtime_guard.sh"
readonly ENDPOINT_GUARD="${STATE_ROOT}/blackcoin_endpoint_guard.sh"
readonly POW_CYCLE="${STATE_ROOT}/blackcoin_pow_quarantine_cycle_v30.1.4_nospend.sh"
readonly PROMOTION_ROOT='/mnt/pulsar/Blackcoin_Blocks/operations/promotion-authority'
readonly PROMOTION_MARKER="${PROMOTION_ROOT}/PROMOTED_NO_REWIND.node27.json"
readonly EXPECTED_DATADIR_DATASET='pulsar/Blackcoin_Blocks/node-data/node-27'
readonly EXPECTED_BLOCKS_DATASET='pulsar/Blackcoin_Blocks/node-data/node-27/blocks'
readonly EXPECTED_INDEXES_DATASET='pulsar/Blackcoin_Blocks/node-data/node-27/indexes'
readonly EXPECTED_RAW_DATASET='pulsar/Blackcoin_Blocks/alpha-chain-raw-clones-20260715T032403Z/node-27'

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
readonly STAMP
readonly OPS="/mnt/pulsar/Blackcoin_Blocks/operations/releases/v${HOTFIX_CANDIDATE_RELEASE_VERSION}-${HOTFIX_CANDIDATE_SOURCE_SHA}/node27-promotion-${STAMP}"
readonly EVIDENCE="${OPS}/evidence"
readonly OVERRIDE="${OPS}/node27-promotion.yml"
readonly RPC_METHODS_LOG="${EVIDENCE}/rpc-methods.log"
readonly SUSPENDED_START_MARKER="${STATE_ROOT}/ENABLE_GUARD_STARTS.promote-node27-${STAMP}.suspended"

result='failed'
mutation_started=0
promotion_durable=0
phase_a_result_sha=''
phase_a_run_nonce=''
promotion_nonce=''
baseline_wallet_name=''
baseline_quantum_count=''
candidate_locked_resolution_sha=''
baseline_config_sha=''
baseline_mounts_sha=''
baseline_network_sha=''
baseline_dataset_sha=''
baseline_restart_policy_json=''
phase_a_run_dir=''
phase_a_guard_nonce=''
phase_a_candidate_image_id=''
phase_a_candidate_image_ref=''
phase_a_candidate_manifest_digest=''
phase_a_candidate_qt_sha=''
phase_a_compose_sha=''
phase_a_tooling_commit=''
package_seal_sha=''
phase_b_script_sha=''
phase_b_verifier_sha=''
phase_b_contract_sha=''
phase_b_tooling_identity_sha=''
durable_promotion_marker_sha=''
containment_complete=0

fail()
{
    printf 'HOTFIX_PROMOTION_FAIL: %s\n' "$*" >&2
    return 1
}

rpc()
{
    local method="${1:-}" journal
    journal="$method"
    [[ -n "$method" ]] || return 1
    if [[ "$method" == staking ]]; then
        journal="staking:${2:-missing}"
    elif [[ "$method" == setpowmining ]]; then
        journal="setpowmining:${2:-missing}:${3:-missing}:${4:-missing}:${5:-missing}"
    fi
    if [[ -d "$EVIDENCE" ]]; then
        printf '%s\n' "$journal" >>"$RPC_METHODS_LOG"
        sync -f "$RPC_METHODS_LOG"
    fi
    timeout -k 2 45 docker exec "$CONTAINER" "$CLI" -datadir="$DATADIR" "$@"
}

capture_goldrush_state()
{
    local output="$1"
    rpc getgoldrushstate | jq -eS '
      {bestblock,height,qqp4_activation_disabled,qqp4_activation_height,
       qqp4_active,qqp4_active_next_block}
    ' >"$output"
}

wait_rpc()
{
    for _ in $(seq 1 180); do
        rpc getblockchaininfo >/dev/null 2>&1 && return 0
        [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)" == true ]] ||
            return 1
        sleep 2
    done
    return 1
}

verify_package_integrity()
{
    local path relative mode
    local -a sealed_files=(
        README.md
        VALIDATION.txt
        candidate.env.example
        lib/typed_contract.sh
        node27-v30.1.4-hotfix-candidate.no-recovery-spend.sh
        node27-v30.1.4-hotfix-candidate.promote-no-data-rewind.sh
        tests/run.sh
        verify-evidence.sh
    )

    [[ -d "$PACKAGE_ROOT" && ! -L "$PACKAGE_ROOT" ]] || return 1
    cmp -s \
        <(cd "$PACKAGE_ROOT" && find . -mindepth 1 -print | LC_ALL=C sort) \
        <(printf '%s\n' ./lib ./tests "${sealed_files[@]/#/./}" ./SHA256SUMS |
            LC_ALL=C sort) || return 1
    for relative in '' lib tests; do
        path=${PACKAGE_ROOT}${relative:+/$relative}
        [[ -d "$path" && ! -L "$path" &&
           "$(stat -Lc '%u:%g' -- "$path" 2>/dev/null || true)" == 0:0 ]] || return 1
        mode=$(stat -Lc '%a' -- "$path" 2>/dev/null) || return 1
        [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
        (( (8#$mode & 8#022) == 0 )) || return 1
    done
    for relative in "${sealed_files[@]}" SHA256SUMS; do
        path="$PACKAGE_ROOT/$relative"
        [[ -f "$path" && ! -L "$path" &&
           "$(stat -Lc '%u:%g' -- "$path" 2>/dev/null || true)" == 0:0 &&
           "$(stat -Lc '%h' -- "$path" 2>/dev/null || true)" == 1 ]] || return 1
        mode=$(stat -Lc '%a' -- "$path" 2>/dev/null) || return 1
        [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
        (( (8#$mode & 8#022) == 0 )) || return 1
    done
    # The manifest binds the eight payload files; its own exact byte hash is
    # independently recorded by every authority/evidence envelope.
    awk '
        NF != 2 || length($1) != 64 || $1 ~ /[^0-9a-f]/ || $2 !~ /^[.]\// {
            bad=1
        }
        END { exit(bad || NR != 8) }
    ' "$PACKAGE_ROOT/SHA256SUMS" || return 1
    cmp -s \
        <(printf '%s\n' "${sealed_files[@]/#/./}" | LC_ALL=C sort) \
        <(awk '{print $2}' "$PACKAGE_ROOT/SHA256SUMS" | LC_ALL=C sort) || return 1
    (cd "$PACKAGE_ROOT" && sha256sum --strict -c SHA256SUMS >/dev/null)
}

require_inputs()
{
    hotfix_candidate_identity_is_resolved || return 1
    [[ -n "${PHASE_A_EVIDENCE_DIR:-}" && -d "$PHASE_A_EVIDENCE_DIR" &&
       ! -L "$PHASE_A_EVIDENCE_DIR" ]] || return 1
    phase_a_result_sha=${PHASE_A_RESULT_SHA256:-}
    hotfix_valid_sha256 "$phase_a_result_sha" || return 1
    [[ "${CONFIRM_HOTFIX_CANDIDATE_PHASE_B:-}" == \
       "${HOTFIX_PHASE_B_CONFIRMATION_PREFIX}${phase_a_result_sha}" ]] || return 1
    [[ -n "${CANDIDATE_IMAGE:-}" && -n "${CANDIDATE_IMAGE_ID:-}" &&
       -n "${CANDIDATE_IMAGE_MANIFEST_DIGEST:-}" &&
       -n "${CANDIDATE_BLACKCOIN_QT_SHA256:-}" &&
       -n "${EXPECTED_COMPOSE_SHA256:-}" &&
       -n "${CANDIDATE_TOOLING_COMMIT:-}" ]] || return 1
    [[ "$CANDIDATE_IMAGE" == "$HOTFIX_CANDIDATE_IMAGE_REF" ]] || return 1
    hotfix_valid_image_id "$CANDIDATE_IMAGE_ID" || return 1
    hotfix_valid_image_id "$CANDIDATE_IMAGE_MANIFEST_DIGEST" || return 1
    hotfix_valid_sha256 "$CANDIDATE_BLACKCOIN_QT_SHA256" || return 1
    hotfix_valid_sha256 "$EXPECTED_COMPOSE_SHA256" || return 1
    hotfix_valid_git_sha "$CANDIDATE_TOOLING_COMMIT" || return 1
}

verify_phase_a_authority()
{
    local result_file="${PHASE_A_EVIDENCE_DIR}/RESULT.json" expected_parent
    "$PACKAGE_ROOT/verify-evidence.sh" phase-a-final "$PHASE_A_EVIDENCE_DIR" || return 1
    [[ "$(sha256sum "$result_file" | awk '{print $1}')" == "$phase_a_result_sha" ]] || return 1
    hotfix_phase_a_result_file_is_valid "$result_file" || return 1
    phase_a_run_nonce=$(jq -er '.run_nonce' "$result_file") || return 1
    hotfix_valid_nonce "$phase_a_run_nonce" || return 1
    phase_a_run_dir=$(CDPATH='' cd -P -- "$PHASE_A_EVIDENCE_DIR/.." && pwd -P) || return 1
    expected_parent="/mnt/pulsar/Blackcoin_Blocks/operations/releases/v${HOTFIX_CANDIDATE_RELEASE_VERSION}-${HOTFIX_CANDIDATE_SOURCE_SHA}"
    [[ "${phase_a_run_dir%/*}" == "$expected_parent" ]] || return 1
    [[ "${phase_a_run_dir##*/node27-canary-}" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || return 1
    [[ -f "$phase_a_run_dir/MAINTENANCE-NONCE" && ! -L "$phase_a_run_dir/MAINTENANCE-NONCE" &&
       -f "$phase_a_run_dir/STATE" && ! -L "$phase_a_run_dir/STATE" &&
       "$(stat -Lc '%u:%g:%a' "$phase_a_run_dir/MAINTENANCE-NONCE")" == 0:0:600 &&
       "$(stat -Lc '%u:%g:%a' "$phase_a_run_dir/STATE")" == 0:0:600 &&
       "$(<"$phase_a_run_dir/STATE")" == active ]] || return 1
    phase_a_guard_nonce=$(<"$phase_a_run_dir/MAINTENANCE-NONCE")
    [[ "$phase_a_guard_nonce" =~ ^[0-9a-f]{64}$ ]] || return 1
    phase_a_candidate_image_id=$(jq -er '.candidate_image_id' \
        "${PHASE_A_EVIDENCE_DIR}/REWIND_SAFE.json") || return 1
    phase_a_candidate_image_ref=$(jq -er '.candidate_image_ref' \
        "${PHASE_A_EVIDENCE_DIR}/REWIND_SAFE.json") || return 1
    phase_a_candidate_manifest_digest=$(jq -er '.candidate_manifest_digest' \
        "${PHASE_A_EVIDENCE_DIR}/REWIND_SAFE.json") || return 1
    phase_a_candidate_qt_sha=$(jq -er '.candidate_blackcoin_qt_sha256' \
        "${PHASE_A_EVIDENCE_DIR}/REWIND_SAFE.json") || return 1
    phase_a_compose_sha=$(jq -er '.compose_sha256' \
        "${PHASE_A_EVIDENCE_DIR}/REWIND_SAFE.json") || return 1
    phase_a_tooling_commit=$(jq -er '.tooling_commit' \
        "${PHASE_A_EVIDENCE_DIR}/REWIND_SAFE.json") || return 1
    [[ "$CANDIDATE_IMAGE" == "$phase_a_candidate_image_ref" &&
       "$CANDIDATE_IMAGE_ID" == "$phase_a_candidate_image_id" &&
       "${CANDIDATE_IMAGE_MANIFEST_DIGEST:-}" == "$phase_a_candidate_manifest_digest" &&
       "${CANDIDATE_BLACKCOIN_QT_SHA256:-}" == "$phase_a_candidate_qt_sha" &&
       "$EXPECTED_COMPOSE_SHA256" == "$phase_a_compose_sha" &&
       "$CANDIDATE_TOOLING_COMMIT" == "$phase_a_tooling_commit" &&
       "$(jq -er '.package_sha256sums_sha256' \
         "${PHASE_A_EVIDENCE_DIR}/REWIND_SAFE.json")" == \
         "$(sha256sum "$PACKAGE_ROOT/SHA256SUMS" | awk '{print $1}')" &&
       "$(jq -er '.phase_a_script_sha256' \
         "${PHASE_A_EVIDENCE_DIR}/REWIND_SAFE.json")" == \
         "$(sha256sum \
           "$PACKAGE_ROOT/node27-v30.1.4-hotfix-candidate.no-recovery-spend.sh" |
           awk '{print $1}')" &&
       "$(jq -er '.phase_b_script_sha256' \
         "${PHASE_A_EVIDENCE_DIR}/REWIND_SAFE.json")" == \
         "$(sha256sum "${BASH_SOURCE[0]}" | awk '{print $1}')" &&
       "$(jq -er '.verifier_sha256' "${PHASE_A_EVIDENCE_DIR}/REWIND_SAFE.json")" == \
         "$(sha256sum "$PACKAGE_ROOT/verify-evidence.sh" | awk '{print $1}')" &&
       "$(jq -er '.typed_contract_sha256' \
         "${PHASE_A_EVIDENCE_DIR}/REWIND_SAFE.json")" == \
         "$(sha256sum "$PACKAGE_ROOT/lib/typed_contract.sh" | awk '{print $1}')" ]] || return 1
}

trusted_phase_a_file()
{
    local name="$1"
    if [[ -f "${EVIDENCE}/phase-a-${name}" && ! -L "${EVIDENCE}/phase-a-${name}" ]]; then
        printf '%s\n' "${EVIDENCE}/phase-a-${name}"
    else
        printf '%s\n' "${PHASE_A_EVIDENCE_DIR}/${name}"
    fi
}

phase_a_storage_artifacts_absent()
{
    local row set_file absence_file pool pool_health dataset snapshot listed
    set_file=$(trusted_phase_a_file snapshot-set.json) || return 1
    absence_file=$(trusted_phase_a_file snapshot-absence-proof.json) || return 1
    [[ "$(jq -er '.snapshot_set_sha256' "$absence_file")" == \
       "$(sha256sum "$set_file" | awk '{print $1}')" ]] || return 1
    pool=${EXPECTED_DATADIR_DATASET%%/*}
    [[ "$(zpool list -H -o name "$pool")" == "$pool" ]] || return 1
    pool_health=$(zpool list -H -o health "$pool") || return 1
    [[ "$pool_health" == ONLINE ]] || return 1
    while IFS= read -r row; do
        dataset=$(jq -er '.dataset' <<<"$row") || return 1
        snapshot=$(jq -er '.snapshot' <<<"$row") || return 1
        [[ "$(zfs list -H -o name -t filesystem "$dataset")" == "$dataset" ]] || return 1
        listed=$(zfs list -H -o name -t snapshot -r "$dataset") || return 1
        ! grep -Fx -- "$snapshot" <<<"$listed" >/dev/null || return 1
    done < <(jq -ce '.snapshots[]' "$set_file")
    hotfix_snapshot_absence_file_is_valid "$absence_file" "$phase_a_run_nonce"
}

record_storage_absence()
{
    local output="$1" stage="$2" set_file rows='[]' row snapshot dataset hold pool pool_health
    set_file=$(trusted_phase_a_file snapshot-set.json) || return 1
    phase_a_storage_artifacts_absent || return 1
    pool=${EXPECTED_DATADIR_DATASET%%/*}
    pool_health=$(zpool list -H -o health "$pool") || return 1
    [[ "$pool_health" == ONLINE ]] || return 1
    while IFS= read -r row; do
        snapshot=$(jq -er '.snapshot' <<<"$row") || return 1
        dataset=$(jq -er '.dataset' <<<"$row") || return 1
        hold=$(jq -er '.hold_tag' <<<"$row") || return 1
        row=$(jq -cn --arg dataset "$dataset" --arg snapshot "$snapshot" --arg hold "$hold" \
          '{dataset:$dataset,snapshot:$snapshot,hold_tag:$hold,
            dataset_enumeration_succeeded:true,snapshot_absent:true,hold_absent:true}') || return 1
        rows=$(jq -cn --argjson rows "$rows" --argjson row "$row" '$rows + [$row]') || return 1
    done < <(jq -ce '.snapshots[]' "$set_file")
    jq -S -n --arg stage "$stage" --arg result "$phase_a_result_sha" \
        --arg nonce "$phase_a_run_nonce" \
        --arg pool "$pool" --arg pool_health "$pool_health" \
        --arg set_sha "$(sha256sum "$set_file" | awk '{print $1}')" \
        --argjson rows "$rows" '
        {schema:1,stage:$stage,phase_a_result_sha256:$result,
         phase_a_run_nonce:$nonce,snapshot_set_sha256:$set_sha,
         zpool:$pool,zpool_health:$pool_health,zfs_enumeration_succeeded:true,
         snapshots:$rows,all_snapshots_absent:true,all_holds_absent:true}
    ' >"$output" || return 1
    hotfix_storage_absence_receipt_file_is_valid "$output" "$phase_a_result_sha" \
        "$phase_a_run_nonce" "$stage"
}

copy_phase_a_authority_locked()
{
    local name source target hashes='{}' hash expected manifest_source manifest_target
    local manifest_hash_before manifest_hash_after maintenance_hash expected_maintenance_hash
    verify_phase_a_authority || return 1
    manifest_source="${PHASE_A_EVIDENCE_DIR}/SHA256SUMS"
    manifest_target="${EVIDENCE}/phase-a-SHA256SUMS"
    [[ -f "$manifest_source" && ! -L "$manifest_source" ]] || return 1
    manifest_hash_before=$(sha256sum "$manifest_source" | awk '{print $1}') || return 1
    install -m 600 -o root -g root "$manifest_source" "$manifest_target" || return 1
    [[ "$(sha256sum "$manifest_target" | awk '{print $1}')" == "$manifest_hash_before" ]] ||
        return 1
    hashes=$(jq -cn --arg hash "$manifest_hash_before" '{"SHA256SUMS":$hash}') || return 1
    for name in RESULT.json REWIND_SAFE.json snapshot-set.json \
        snapshot-absence-proof.json candidate-loaded-image.json \
        candidate-bundle-manifest.json candidate-oci-identity.json \
        candidate-binary-sha256sums.txt baseline-runtime-identity.json \
        candidate-invocation-restart.json base-catchup-proof.json \
        guard-source-identity.json maintenance-marker-activated.json \
        unlock-helper-audit.json tooling-identity.json \
        base-quarantine-stop-authority.json baseline-restored-container.json; do
        source="${PHASE_A_EVIDENCE_DIR}/${name}"
        target="${EVIDENCE}/phase-a-${name}"
        [[ -f "$source" && ! -L "$source" ]] || return 1
        expected=$(awk -v wanted="$name" '
          NF == 2 && $1 ~ /^[0-9a-f]{64}$/ {
            path=$2; sub(/^\*/, "", path); sub(/^\.\//, "", path)
            if (path == wanted) {print $1}
          }
        ' "$manifest_source") || return 1
        [[ "$expected" =~ ^[0-9a-f]{64}$ && "$(wc -l <<<"$expected")" == 1 ]] || return 1
        [[ "$(sha256sum "$source" | awk '{print $1}')" == "$expected" ]] || return 1
        install -m 600 -o root -g root "$source" "$target" || return 1
        hash=$(sha256sum "$target" | awk '{print $1}') || return 1
        [[ "$hash" == "$expected" ]] || return 1
        hashes=$(jq -cn --argjson hashes "$hashes" --arg name "$name" --arg hash "$hash" \
            '$hashes + {($name):$hash}') || return 1
    done
    manifest_hash_after=$(sha256sum "$manifest_source" | awk '{print $1}') || return 1
    [[ "$manifest_hash_after" == "$manifest_hash_before" ]] || return 1
    (cd "$PHASE_A_EVIDENCE_DIR" && sha256sum --strict -c SHA256SUMS >/dev/null) || return 1
    verify_phase_a_authority || return 1
    [[ "$(sha256sum "${EVIDENCE}/phase-a-RESULT.json" | awk '{print $1}')" == \
       "$phase_a_result_sha" ]] || return 1
    hotfix_rewind_safe_file_is_valid "${EVIDENCE}/phase-a-REWIND_SAFE.json" \
        "$phase_a_run_nonce" || return 1
    hotfix_snapshot_set_file_is_valid "${EVIDENCE}/phase-a-snapshot-set.json" \
        "$phase_a_run_nonce" || return 1
    hotfix_snapshot_absence_file_is_valid "${EVIDENCE}/phase-a-snapshot-absence-proof.json" \
        "$phase_a_run_nonce" || return 1
    expected_maintenance_hash=$(jq -er '.maintenance_marker_sha256' \
        "${EVIDENCE}/phase-a-REWIND_SAFE.json") || return 1
    maintenance_hash=$(sha256sum "${EVIDENCE}/phase-a-maintenance-marker-activated.json" |
        awk '{print $1}') || return 1
    [[ "$maintenance_hash" == "$expected_maintenance_hash" ]] || return 1
    jq -e --arg run "$phase_a_run_dir" --arg nonce "$phase_a_guard_nonce" '
      . == {schema:1,transaction:"v30.1.4-node27-canary",state:"active",
            run_nonce:$nonce,run_dir:$run}
    ' "${EVIDENCE}/phase-a-maintenance-marker-activated.json" >/dev/null || return 1
    jq -S -n --arg result "$phase_a_result_sha" --arg nonce "$phase_a_run_nonce" \
        --arg image_ref "$phase_a_candidate_image_ref" --arg image_id "$phase_a_candidate_image_id" \
        --arg manifest_digest "$phase_a_candidate_manifest_digest" \
        --arg qt "$phase_a_candidate_qt_sha" --arg compose "$phase_a_compose_sha" \
        --arg tooling "$phase_a_tooling_commit" --arg source_manifest "$manifest_hash_before" \
        --arg maintenance "$maintenance_hash" \
        --argjson files "$hashes" '
        {schema:1,phase_a_result_sha256:$result,phase_a_run_nonce:$nonce,
         candidate_image_ref:$image_ref,candidate_image_id:$image_id,
         candidate_manifest_digest:$manifest_digest,candidate_blackcoin_qt_sha256:$qt,
         compose_sha256:$compose,tooling_commit:$tooling,
         source_manifest_sha256:$source_manifest,
         maintenance_marker_sha256:$maintenance,
         copied_under_all_four_locks:true,source_reverified_immediately_before_copy:true,
         source_reverified_after_copy:true,all_copies_manifest_bound:true,
         files:$files}
    ' >"${EVIDENCE}/phase-a-authority-receipt.json" || return 1
}

verify_live_guards_from_phase_a()
{
    local identity="${EVIDENCE}/phase-a-guard-source-identity.json"
    [[ -f "$identity" && ! -L "$identity" ]] || return 1
    [[ "$(sha256sum "$RUNTIME_GUARD" | awk '{print $1}')" == \
         "$(jq -er '.runtime_guard_sha256' "$identity")" &&
       "$(sha256sum "$ENDPOINT_GUARD" | awk '{print $1}')" == \
         "$(jq -er '.endpoint_guard_sha256' "$identity")" &&
       "$(sha256sum "$POW_CYCLE" | awk '{print $1}')" == \
         "$(jq -er '.pow_cycle_sha256' "$identity")" ]] || return 1
}

record_tooling_identity()
{
    package_seal_sha=$(sha256sum "$PACKAGE_ROOT/SHA256SUMS" | awk '{print $1}') || return 1
    phase_b_script_sha=$(sha256sum "${BASH_SOURCE[0]}" | awk '{print $1}') || return 1
    phase_b_verifier_sha=$(sha256sum "$PACKAGE_ROOT/verify-evidence.sh" | awk '{print $1}') || return 1
    phase_b_contract_sha=$(sha256sum "$PACKAGE_ROOT/lib/typed_contract.sh" | awk '{print $1}') ||
        return 1
    jq -S -n --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" \
        --arg tooling "$CANDIDATE_TOOLING_COMMIT" --arg package "$package_seal_sha" \
        --arg script "$phase_b_script_sha" --arg verifier "$phase_b_verifier_sha" \
        --arg contract "$phase_b_contract_sha" '
        {schema:1,candidate_source_sha:$source,tooling_commit:$tooling,
         package_sha256sums_sha256:$package,phase_b_script_sha256:$script,
         verifier_sha256:$verifier,typed_contract_sha256:$contract,
         exact_bytes_recorded_before_irreversible_marker:true}
    ' >"${EVIDENCE}/phase-b-tooling-identity.json" || return 1
    phase_b_tooling_identity_sha=$(sha256sum "${EVIDENCE}/phase-b-tooling-identity.json" |
        awk '{print $1}') || return 1
}

suspend_guard_authority()
{
    [[ -f "$ENABLE_GUARD_STARTS" && ! -L "$ENABLE_GUARD_STARTS" &&
       ! -s "$ENABLE_GUARD_STARTS" &&
       "$(stat -Lc '%u:%g:%a' "$ENABLE_GUARD_STARTS")" == 0:0:600 &&
       ! -e "$SUSPENDED_START_MARKER" && ! -L "$SUSPENDED_START_MARKER" ]] || return 1
    mv -nT -- "$ENABLE_GUARD_STARTS" "$SUSPENDED_START_MARKER" || return 1
    [[ ! -e "$ENABLE_GUARD_STARTS" && ! -L "$ENABLE_GUARD_STARTS" ]] || return 1
    [[ -f "$SUSPENDED_START_MARKER" && ! -L "$SUSPENDED_START_MARKER" &&
       ! -s "$SUSPENDED_START_MARKER" &&
       "$(stat -Lc '%u:%g:%a' "$SUSPENDED_START_MARKER")" == 0:0:600 &&
       ! -e "$ENABLE_GUARD_STARTS" && ! -L "$ENABLE_GUARD_STARTS" ]] || return 1
    sync -f "$SUSPENDED_START_MARKER" && sync -f "$STATE_ROOT"
}

publish_maintenance()
{
    local tmp
    [[ ! -e "$MAINTENANCE_MARKER" && ! -L "$MAINTENANCE_MARKER" ]] || return 1
    jq -S -n --arg run "$OPS" --arg result_sha "$phase_a_result_sha" \
        --arg guard_run "$phase_a_run_dir" --arg guard_nonce "$phase_a_guard_nonce" \
        --arg transaction "v${HOTFIX_CANDIDATE_RELEASE_VERSION}-node27-promotion" '
        {schema:2,transaction:$transaction,state:"active",
         run_dir:$run,phase_a_result_sha256:$result_sha,
         guard_compatible_run_dir:$guard_run,guard_nonce:$guard_nonce,
         automatic_failure_action:"contain-stop-preserve"}
    ' >"${EVIDENCE}/promotion-maintenance-authority.json" || return 1
    tmp=$(mktemp "${STATE_ROOT}/.v3015-promotion-maintenance.XXXXXX") || return 1
    jq -S -n --arg run "$phase_a_run_dir" --arg nonce "$phase_a_guard_nonce" '
        {schema:1,transaction:"v30.1.4-node27-canary",state:"active",
         run_nonce:$nonce,run_dir:$run}
    ' >"$tmp" || return 1
    chmod 600 "$tmp" && chown root:root "$tmp" && sync -f "$tmp" || return 1
    mv -nT -- "$tmp" "$MAINTENANCE_MARKER" || return 1
    [[ ! -e "$tmp" ]] || return 1
    sync -f "$MAINTENANCE_MARKER" && sync -f "$STATE_ROOT" || return 1
    [[ -f "$MAINTENANCE_MARKER" && ! -L "$MAINTENANCE_MARKER" &&
       "$(stat -Lc '%u:%g:%a' "$MAINTENANCE_MARKER")" == 0:0:600 ]] || return 1
    jq -e --arg run "$phase_a_run_dir" --arg nonce "$phase_a_guard_nonce" '
      . == {schema:1,transaction:"v30.1.4-node27-canary",state:"active",
            run_nonce:$nonce,run_dir:$run}
    ' "$MAINTENANCE_MARKER" >/dev/null
}

write_promotion_marker()
{
    local tmp expected_hash actual_hash absence_sha authority_sha rewind_sha evidence_sha
    [[ ! -e "$PROMOTION_MARKER" && ! -L "$PROMOTION_MARKER" ]] || return 1
    phase_a_storage_artifacts_absent || return 1
    hotfix_storage_absence_receipt_file_is_valid \
        "${EVIDENCE}/storage-absence-before-marker.json" "$phase_a_result_sha" \
        "$phase_a_run_nonce" before-marker || return 1
    absence_sha=$(sha256sum "${EVIDENCE}/storage-absence-before-marker.json" | awk '{print $1}') ||
        return 1
    authority_sha=$(sha256sum "${EVIDENCE}/phase-a-authority-receipt.json" | awk '{print $1}') ||
        return 1
    rewind_sha=$(sha256sum "${EVIDENCE}/phase-a-REWIND_SAFE.json" | awk '{print $1}') || return 1
    evidence_sha=$(sha256sum "${EVIDENCE}/phase-a-SHA256SUMS" | awk '{print $1}') || return 1
    promotion_nonce=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n') || return 1
    hotfix_valid_nonce "$promotion_nonce" || return 1
    [[ "$promotion_nonce" != "$phase_a_run_nonce" ]] || return 1
    tmp=$(mktemp "${PROMOTION_ROOT}/.promoted-no-rewind.XXXXXX") || return 1
    jq -S -n --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" \
        --arg result_sha "$phase_a_result_sha" \
        --arg evidence_sha "$evidence_sha" \
        --arg run_nonce "$phase_a_run_nonce" --arg promotion_nonce "$promotion_nonce" \
        --arg image_id "$phase_a_candidate_image_id" \
        --arg image_ref "$phase_a_candidate_image_ref" \
        --arg manifest_digest "$phase_a_candidate_manifest_digest" \
        --arg absence "$absence_sha" --arg authority "$authority_sha" --arg rewind "$rewind_sha" \
        --arg tooling "$CANDIDATE_TOOLING_COMMIT" \
        --arg tooling_identity "$phase_b_tooling_identity_sha" \
        --arg package "$package_seal_sha" --arg script "$phase_b_script_sha" \
        --arg verifier "$phase_b_verifier_sha" --arg contract "$phase_b_contract_sha" \
        --arg utc "$(date -u +%FT%TZ)" '
        {schema:1,state:"PROMOTED_NO_REWIND",node:27,candidate_source_sha:$source,
         phase_a_result_sha256:$result_sha,phase_a_evidence_sha256sums_sha256:$evidence_sha,
         phase_a_run_nonce:$run_nonce,promotion_nonce:$promotion_nonce,created_utc:$utc,
         candidate_image_ref:$image_ref,candidate_image_id:$image_id,
         candidate_manifest_digest:$manifest_digest,
         storage_absence_sha256:$absence,phase_a_authority_receipt_sha256:$authority,
         phase_a_rewind_safe_sha256:$rewind,
         tooling_commit:$tooling,phase_b_tooling_identity_sha256:$tooling_identity,
         package_sha256sums_sha256:$package,phase_b_script_sha256:$script,
         verifier_sha256:$verifier,typed_contract_sha256:$contract,
         data_rewind_permanently_prohibited:true,marker_fsync_verified:true,
         parent_directory_fsync_verified:true,reread_verified:true,
         snapshots_absent_before_marker:true}
    ' >"$tmp" || return 1
    chmod 600 "$tmp" && chown root:root "$tmp" && sync -f "$tmp" || return 1
    hotfix_promoted_marker_file_is_valid "$tmp" "$phase_a_result_sha" || return 1
    expected_hash=$(sha256sum "$tmp" | awk '{print $1}') || return 1
    ln -- "$tmp" "$PROMOTION_MARKER" || return 1
    durable_promotion_marker_sha=$expected_hash
    promotion_durable=1
    rm -f -- "$tmp"
    sync -f "$PROMOTION_MARKER" && sync -f "$PROMOTION_ROOT" || return 1
    [[ "$(stat -Lc '%u:%g:%a' "$PROMOTION_MARKER")" == 0:0:600 ]] || return 1
    actual_hash=$(sha256sum "$PROMOTION_MARKER" | awk '{print $1}') || return 1
    [[ "$actual_hash" == "$expected_hash" ]] || return 1
    hotfix_promoted_marker_file_is_valid "$PROMOTION_MARKER" "$phase_a_result_sha" || return 1
    durable_promotion_marker_sha=$actual_hash
}

verify_unlock_helper()
{
    [[ -f "$NORMAL_UNLOCK_HELPER" && ! -L "$NORMAL_UNLOCK_HELPER" &&
       "$(stat -Lc '%u:%g:%a' "$NORMAL_UNLOCK_HELPER")" == 0:0:600 &&
       "$(sha256sum "$NORMAL_UNLOCK_HELPER" | awk '{print $1}')" == "$HOTFIX_UNLOCK_HELPER_SHA256" ]] &&
        bash -n "$NORMAL_UNLOCK_HELPER" &&
        hotfix_unlock_helper_audit_file_is_valid \
            "${EVIDENCE}/phase-a-unlock-helper-audit.json"
}

run_unlock_helper()
{
    verify_unlock_helper && /bin/bash "$NORMAL_UNLOCK_HELPER" 27
}

write_override()
{
    cat >"$OVERRIDE" <<EOF
services:
  node27:
    image: ${CANDIDATE_IMAGE}
    entrypoint:
      - /bin/bash
      - -c
      - |
          export DISPLAY=:0
          rm -f /tmp/.X0-lock
          Xvfb :0 -screen 0 1280x800x16 &
          sleep 2
          fluxbox &
          x11vnc -display :0 -nopw -listen localhost -xkb -forever -shared &
          websockify --web=/usr/share/novnc/ 8080 localhost:5900 &
          sleep 2
          exec /usr/local/bin/blackcoin-qt -datadir=/home/blackcoin/.blackcoin "\$\$@"
      - node27-hotfix-candidate
    command:
      - -walletbroadcast=1
      - -autostartstaking=1
      - -powmining=1
      - -powminingthreads=1
      - -powminingcpu=1
EOF
    chmod 600 "$OVERRIDE" && chown root:root "$OVERRIDE" && sync -f "$OVERRIDE"
}

inspect_mounts_sha()
{
    jq -cS '.[0].Mounts | map({Type,Source,Destination,Mode,RW,Propagation}) |
      sort_by(.Destination)' "$1" | sha256sum | awk '{print $1}'
}

inspect_network_sha()
{
    jq -cS '.[0] | {network_mode:.HostConfig.NetworkMode,
      port_bindings:(.HostConfig.PortBindings // {}),
      publish_all_ports:(.HostConfig.PublishAllPorts // false),
      links:(.HostConfig.Links // []),extra_hosts:(.HostConfig.ExtraHosts // []),
      dns:(.HostConfig.Dns // [])}' "$1" | sha256sum | awk '{print $1}'
}

inspect_restart_policy_json()
{
    jq -cS '.[0].HostConfig.RestartPolicy' "$1"
}

capture_live_dataset_identity()
{
    local output="$1" dataset path rows='[]' guid row
    while IFS=$'\t' read -r dataset path; do
        guid=$(zfs get -Hp -o value guid "$dataset") || return 1
        [[ "$(findmnt -n -o SOURCE -T "$path")" == "$dataset" ]] || return 1
        row=$(jq -cn --arg dataset "$dataset" --arg path "$path" --arg guid "$guid" \
          '{dataset:$dataset,mount_path:$path,guid:$guid}') || return 1
        rows=$(jq -cn --argjson rows "$rows" --argjson row "$row" '$rows + [$row]') || return 1
    done <<EOF
$EXPECTED_DATADIR_DATASET	$HOST_DATADIR
$EXPECTED_BLOCKS_DATASET	$HOST_DATADIR/blocks
$EXPECTED_INDEXES_DATASET	$HOST_DATADIR/indexes
$EXPECTED_RAW_DATASET	$HOST_RAW
EOF
    jq -S -n --argjson rows "$rows" '{schema:1,datasets:$rows}' >"$output"
}

quantum_inventory_count()
{
    jq -er 'if type=="array" then length elif (.keys?|type)=="array"
      then (.keys|length) elif (.inventory?|type)=="array" then (.inventory|length)
      elif (.total?|type)=="number" then .total else error("schema") end' "$1"
}

capture_quantum_payout_label_evidence()
{
    local inventory="$1" output="$2" tmp label addresses
    [[ -f "$inventory" && ! -L "$inventory" ]] || return 1
    tmp=$(mktemp "${OPS}/.quantum-labels.XXXXXX") || return 1
    : >"${tmp}.rows" || return 1
    jq -er '
      def entries:
        if type == "array" then .
        elif (.keys? | type) == "array" then .keys
        elif (.inventory? | type) == "array" then .inventory
        else error("unsupported quantum inventory") end;
      [entries[]? | (.label? // "") |
        select(IN("PoW - Quantum Claim Address",
          "Quantum PoW Reward Address","goldrush-pow"))] | unique | sort | .[]
    ' "$inventory" >"${tmp}.labels" || return 1
    while IFS= read -r label; do
        [[ -n "$label" ]] || continue
        addresses=$(rpc getaddressesbylabel "$label") || return 1
        jq -e 'type == "object" and all(.[];
          type == "object" and (keys | sort) == ["purpose"] and
          (.purpose | type) == "string")' <<<"$addresses" >/dev/null || return 1
        jq -cS -n --arg label "$label" --argjson addresses "$addresses" \
            '{label:$label,addresses:$addresses}' >>"${tmp}.rows" || return 1
    done <"${tmp}.labels"
    jq -S -n --slurpfile rows "${tmp}.rows" \
        '{schema:1,labels:($rows | sort_by(.label))}' >"$tmp" || return 1
    install -m 600 -o root -g root "$tmp" "$output" || return 1
    sync -f "$output" && sync -f "$EVIDENCE" || return 1
    rm -f -- "$tmp" "${tmp}.rows" "${tmp}.labels"
}

capture_wallet_transactions()
{
    local output="$1"
    rpc listtransactions '*' 1000000 0 true |
        jq -S 'sort_by(.txid, (.vout // -1), .category)' >"$output"
}

capture_resolution_raw_identities()
{
    local ids_file="$1" output="$2" txid rows='[]' raw row
    while IFS= read -r txid; do
        raw=$(rpc gettransaction "$txid" false true) || return 1
        row=$(jq -ce --arg txid "$txid" '
          select(.txid==$txid and (.hex|type)=="string" and
            (.hex|test("^[0-9a-f]+$")) and ((.hex|length)%2)==0) |
          {txid:$txid,hex:.hex}
        ' <<<"$raw") || return 1
        rows=$(jq -cn --argjson rows "$rows" --argjson row "$row" '$rows+[$row]') ||
            return 1
    done < <(jq -r '.[]' "$ids_file")
    jq -S -n --argjson rows "$rows" '$rows|sort_by(.txid)' >"$output"
}

capture_baseline_precondition()
{
    local observed tip chain_after payout payout_owned quantum_count wallet_name
    for _ in $(seq 1 20); do
        observed=$(date +%s)
        rpc getblockchaininfo >"${EVIDENCE}/baseline-chain.json" || return 1
        capture_goldrush_state "${EVIDENCE}/baseline-goldrush-state.json" || return 1
        rpc getnetworkinfo >"${EVIDENCE}/baseline-network.json" || return 1
        rpc getwalletinfo >"${EVIDENCE}/baseline-wallet.json" || return 1
        rpc getstakinginfo >"${EVIDENCE}/baseline-staking.json" || return 1
        rpc getpowmininginfo >"${EVIDENCE}/baseline-pow.json" || return 1
        rpc getpowclaimrecoveryinfo true >"${EVIDENCE}/baseline-recovery.json" || return 1
        rpc getquantumkeyinventory | jq -S . >"${EVIDENCE}/baseline-quantum.json" || return 1
        capture_quantum_payout_label_evidence "${EVIDENCE}/baseline-quantum.json" \
            "${EVIDENCE}/baseline-quantum-labels.json" || return 1
        rpc listwallets | jq -S . >"${EVIDENCE}/baseline-loaded-wallets.json" || return 1
        capture_wallet_transactions "${EVIDENCE}/baseline-wallet-transactions.json" || return 1
        jq -S '[.[] | select(
          has("qq_shadow_pow_cleanup_for") or
          has("qq_shadow_pow_resolution_schema") or
          has("qq_shadow_pow_resolution_anchor_txid") or
          has("qq_shadow_pow_resolution_origin")) | .txid] | unique | sort' \
            "${EVIDENCE}/baseline-wallet-transactions.json" \
            >"${EVIDENCE}/baseline-wallet-resolution-txids.json" || return 1
        capture_resolution_raw_identities \
            "${EVIDENCE}/baseline-wallet-resolution-txids.json" \
            "${EVIDENCE}/baseline-wallet-resolution-raw.json" || return 1
        rpc getblockchaininfo >"${EVIDENCE}/baseline-chain-after.json" || return 1
        chain_after=$(<"${EVIDENCE}/baseline-chain-after.json")
        tip=$(jq -er '.bestblockhash' "${EVIDENCE}/baseline-chain.json") || return 1
        hotfix_goldrush_state_json_is_valid \
            "$(<"${EVIDENCE}/baseline-goldrush-state.json")" "$tip" \
            "$(jq -er '.blocks' "${EVIDENCE}/baseline-chain.json")" || return 1
        if ! jq -e --argjson after "$chain_after" '
          .chain=="main" and .initialblockdownload==false and .blocks==.headers and
          .bestblockhash==$after.bestblockhash and .chainwork==$after.chainwork and
          .blocks==$after.blocks
        ' "${EVIDENCE}/baseline-chain.json" >/dev/null; then
            sleep 1
            continue
        fi
        jq -e '.networkactive==true and .connections_out>=3' \
            "${EVIDENCE}/baseline-network.json" >/dev/null || return 1
        jq -e --argjson observed "$observed" '
          (.walletname|type)=="string" and .scanning==false and .private_keys_enabled==true and
          .unlocked_staking_only==false and .unlocked_until>$observed
        ' "${EVIDENCE}/baseline-wallet.json" >/dev/null || return 1
        wallet_name=$(jq -er '.walletname | select(type=="string")' \
            "${EVIDENCE}/baseline-wallet.json") || return 1
        hotfix_phase_b_staking_json_is_active "$(<"${EVIDENCE}/baseline-staking.json")" ||
            return 1
        jq -e '.enabled|type=="boolean"' "${EVIDENCE}/baseline-pow.json" >/dev/null || return 1
        payout=$(jq -er '.payout_address | select(type=="string")' \
            "${EVIDENCE}/baseline-pow.json") || return 1
        if [[ -n "$payout" ]]; then
            rpc getaddressinfo "$payout" | jq -S . \
                >"${EVIDENCE}/baseline-payout-address.json" || return 1
            hotfix_quantum_payout_address_is_valid \
                "${EVIDENCE}/baseline-payout-address.json" \
                "${EVIDENCE}/baseline-quantum.json" "$payout" || return 1
            payout_owned=true
        else
            printf 'null\n' >"${EVIDENCE}/baseline-payout-address.json" || return 1
            payout_owned=false
        fi
        hotfix_candidate_recovery_json_is_valid \
            "$(<"${EVIDENCE}/baseline-recovery.json")" || return 1
        jq -e --arg tip "$tip" '
          .active_tip==$tip and .wallet_processed_tip==$tip and
          .policy_authoritative==true and .policy.automatic_authorized==false
        ' "${EVIDENCE}/baseline-recovery.json" >/dev/null || return 1
        jq -e --arg wallet "$wallet_name" '. == [$wallet]' \
            "${EVIDENCE}/baseline-loaded-wallets.json" >/dev/null || return 1
        quantum_count=$(quantum_inventory_count "${EVIDENCE}/baseline-quantum.json") || return 1
        [[ "$quantum_count" =~ ^[0-9]+$ && "$quantum_count" -gt 0 ]] || return 1
        jq -S -n --argjson observed "$observed" --arg tip "$tip" \
            --arg goldrush_sha "$(sha256sum \
              "${EVIDENCE}/baseline-goldrush-state.json" | awk '{print $1}')" \
            --arg payout "$payout" --argjson payout_owned "$payout_owned" \
            --arg wallet "$wallet_name" \
            --argjson quantum_count "$quantum_count" '
            {schema:2,observed_epoch:$observed,stable_tip:$tip,
             goldrush_state_sha256:$goldrush_sha,
             main_chain_ready:true,p2p_ready:true,wallet_normally_unlocked:true,
             exact_loaded_wallets:[$wallet],staking_active:true,payout_address:$payout,
             payout_owned:$payout_owned,quantum_key_count:$quantum_count,
             recovery_database_unambiguous:true,recovery_policy_nonautomatic:true,
             irreversible_marker_allowed:true}
        ' >"${EVIDENCE}/baseline-precondition.json" || return 1
        return 0
    done
    return 1
}

capture_invocation()
{
    local created="$1" output="$2" inspect argv image body_sha exe_sha mounts_sha network_sha argv_sha
    local config_sha conflicting_env ps process actual_start_gui_sha restart_policy
    jq -e --arg id "$CANDIDATE_IMAGE_ID" --arg mounts "$baseline_mounts_sha" \
      --arg network "$baseline_network_sha" '.image_id == $id and .running == false and
      .user == "blackcoin" and .working_dir == "/home/blackcoin" and
      .mounts_sha256 == $mounts and .network_sha256 == $network' \
      "$created" >/dev/null || return 1
    inspect=$(mktemp "${OPS}/.inspect.XXXXXX") || return 1
    argv=$(mktemp "${OPS}/.argv.XXXXXX") || return 1
    image=$(mktemp "${OPS}/.image-inspect.XXXXXX") || return 1
    docker inspect "$CONTAINER" >"$inspect" || return 1
    docker image inspect "$CANDIDATE_IMAGE" >"$image" || return 1
    body_sha=$(jq -j '.[0].Config.Entrypoint[2]' "$inspect" | sha256sum | awk '{print $1}') || return 1
    [[ "$body_sha" == "$HOTFIX_CANDIDATE_ENTRYPOINT_BODY_SHA256" ]] || return 1
    exe_sha=$(docker exec "$CONTAINER" sha256sum /proc/1/exe | awk '{print $1}') || return 1
    [[ "$exe_sha" == "$phase_a_candidate_qt_sha" ]] || return 1
    actual_start_gui_sha=$(docker exec "$CONTAINER" sha256sum /home/blackcoin/start-gui.sh |
        awk '{print $1}') || return 1
    [[ "$actual_start_gui_sha" == "$IMMUTABLE_START_GUI_SHA256" ]] || return 1
    docker exec "$CONTAINER" /bin/bash -c 'tr "\0" "\n" </proc/1/cmdline' |
        jq -Rsc 'split("\n")[:-1]' >"$argv" || return 1
    argv_sha=$(sha256sum "$argv" | awk '{print $1}') || return 1
    mounts_sha=$(inspect_mounts_sha "$inspect") || return 1
    network_sha=$(inspect_network_sha "$inspect") || return 1
    config_sha=$(sha256sum "$HOST_DATADIR/blackcoin.conf" | awk '{print $1}') || return 1
    [[ "$mounts_sha" == "$baseline_mounts_sha" && "$network_sha" == "$baseline_network_sha" &&
       "$config_sha" == "$baseline_config_sha" ]] || return 1
    restart_policy=$(inspect_restart_policy_json "$inspect") || return 1
    [[ "$restart_policy" == "$baseline_restart_policy_json" ]] || return 1
    conflicting_env=$(jq -cS '.[0].Config.Env // [] | map(select(test(
      "(?i)(walletbroadcast|(^|_)staking|powmining|qqautoshadowsignal|qqautodemurrageattest)")))' \
      "$inspect") || return 1
    [[ "$conflicting_env" == '[]' ]] || return 1
    jq -e -n --slurpfile created "$created" --slurpfile inspect "$inspect" '
      $created[0].entrypoint == $inspect[0][0].Config.Entrypoint and
      $created[0].cmd == $inspect[0][0].Config.Cmd
    ' >/dev/null || return 1
    ps=$(docker exec "$CONTAINER" ps -eo comm=) || return 1
    for process in Xvfb fluxbox x11vnc websockify blackcoin-qt; do
        grep -Fx "$process" <<<"$ps" >/dev/null || return 1
    done
    jq -S -n --arg nonce "$promotion_nonce" --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" \
        --arg id "$CANDIDATE_IMAGE_ID" --arg start_gui "$actual_start_gui_sha" \
        --arg body_sha "$body_sha" --arg exe_sha "$exe_sha" --arg argv_sha "$argv_sha" \
        --arg mounts_sha "$mounts_sha" --arg network_sha "$network_sha" \
        --arg config_sha "$config_sha" --argjson conflicting_env "$conflicting_env" \
        --argjson restart_policy "$restart_policy" \
        --slurpfile inspect "$inspect" --slurpfile argv "$argv" --slurpfile image "$image" '
        ($inspect[0][0]) as $i |
        {schema:2,phase:"B",run_nonce:$nonce,candidate_source_sha:$source,
         runtime_source_sha:$source,image_id:$id,
         container_id:$i.Id,container_started_at:$i.State.StartedAt,
         container_restart_count:$i.RestartCount,
         immutable_start_gui_sha256:$start_gui,entrypoint_body_sha256:$body_sha,
         observed_start_gui_sha256:$start_gui,
         created_stopped:true,inspected_before_start:true,image_user:$i.Config.User,
         working_dir:$i.Config.WorkingDir,image_entrypoint:$image[0][0].Config.Entrypoint,
         image_cmd:$image[0][0].Config.Cmd,effective_entrypoint:$i.Config.Entrypoint,
         effective_cmd:$i.Config.Cmd,
         container_path:$i.Path,container_args:$i.Args,runtime_executable:$argv[0][0],
         runtime_argv:$argv[0],pid1_exe_sha256:$exe_sha,runtime_argv_sha256:$argv_sha,
         display_environment:"DISPLAY=:0",
         setup_processes:{xvfb:true,fluxbox:true,x11vnc:true,websockify:true},
         mounts_sha256:$mounts_sha,network_sha256:$network_sha,config_sha256:$config_sha,
         restart_policy:$restart_policy,restart_policy_equal_baseline:true,
         mounts_equal_baseline:true,network_equal_baseline:true,
         baseline_config_unchanged:true,operator_override_allowed:false,
         conflicting_cli_flags:[],conflicting_environment_entries:$conflicting_env}
    ' >"$output" || return 1
    rm -f -- "$inspect" "$argv" "$image"
    hotfix_invocation_file_is_valid "$output" B "$CANDIDATE_IMAGE_ID" "$promotion_nonce"
}

capture_final_container_identity()
{
    local output="$1" first second argv first_mounts second_mounts first_network second_network
    local body_sha exe_sha start_gui_sha argv_sha config_sha first_restart second_restart
    first=$(mktemp "${OPS}/.final-inspect-one.XXXXXX") || return 1
    second=$(mktemp "${OPS}/.final-inspect-two.XXXXXX") || return 1
    argv=$(mktemp "${OPS}/.final-argv.XXXXXX") || return 1
    docker inspect "$CONTAINER" >"$first" || return 1
    sleep 2
    exe_sha=$(docker exec "$CONTAINER" sha256sum /proc/1/exe | awk '{print $1}') || return 1
    start_gui_sha=$(docker exec "$CONTAINER" sha256sum /home/blackcoin/start-gui.sh |
        awk '{print $1}') || return 1
    docker exec "$CONTAINER" /bin/bash -c 'tr "\0" "\n" </proc/1/cmdline' |
        jq -Rsc 'split("\n")[:-1]' >"$argv" || return 1
    docker inspect "$CONTAINER" >"$second" || return 1
    first_mounts=$(inspect_mounts_sha "$first") || return 1
    second_mounts=$(inspect_mounts_sha "$second") || return 1
    first_network=$(inspect_network_sha "$first") || return 1
    second_network=$(inspect_network_sha "$second") || return 1
    first_restart=$(inspect_restart_policy_json "$first") || return 1
    second_restart=$(inspect_restart_policy_json "$second") || return 1
    body_sha=$(jq -j '.[0].Config.Entrypoint[2]' "$second" | sha256sum | awk '{print $1}') ||
        return 1
    argv_sha=$(sha256sum "$argv" | awk '{print $1}') || return 1
    config_sha=$(sha256sum "$HOST_DATADIR/blackcoin.conf" | awk '{print $1}') || return 1
    jq -e -n --arg id "$CANDIDATE_IMAGE_ID" --arg ref "$CANDIDATE_IMAGE" \
        --arg body "$HOTFIX_CANDIDATE_ENTRYPOINT_BODY_SHA256" \
        --arg exe "$phase_a_candidate_qt_sha" --arg start_gui "$IMMUTABLE_START_GUI_SHA256" \
        --arg config "$baseline_config_sha" --arg mounts "$baseline_mounts_sha" \
        --arg network "$baseline_network_sha" --argjson restart "$baseline_restart_policy_json" \
        --slurpfile first "$first" --slurpfile second "$second" \
        --slurpfile invocation "${EVIDENCE}/candidate-invocation.json" \
        --arg observed_body "$body_sha" --arg observed_exe "$exe_sha" \
        --arg observed_start "$start_gui_sha" --arg observed_config "$config_sha" \
        --arg first_mounts "$first_mounts" --arg second_mounts "$second_mounts" \
        --arg first_network "$first_network" --arg second_network "$second_network" \
        --argjson first_restart "$first_restart" --argjson second_restart "$second_restart" '
        ($first[0][0]) as $a | ($second[0][0]) as $b |
        $a.Id==$b.Id and $a.Image==$id and $b.Image==$id and
        $a.Config.Image==$ref and $b.Config.Image==$ref and
        $a.State.Running==true and $b.State.Running==true and
        $a.State.StartedAt==$b.State.StartedAt and $a.RestartCount==$b.RestartCount and
        $a.Id==$invocation[0].container_id and
        $a.State.StartedAt==$invocation[0].container_started_at and
        $a.RestartCount==$invocation[0].container_restart_count and
        $a.Config.Entrypoint==$invocation[0].effective_entrypoint and
        $b.Config.Entrypoint==$invocation[0].effective_entrypoint and
        $a.Config.Cmd==$invocation[0].effective_cmd and $b.Config.Cmd==$invocation[0].effective_cmd and
        $a.Path==$invocation[0].container_path and $b.Path==$invocation[0].container_path and
        $a.Args==$invocation[0].container_args and $b.Args==$invocation[0].container_args and
        $observed_body==$body and $observed_exe==$exe and $observed_start==$start_gui and
        $observed_config==$config and $first_mounts==$mounts and $second_mounts==$mounts and
        $first_network==$network and $second_network==$network and
        $first_restart==$restart and $second_restart==$restart
    ' >/dev/null || return 1
    jq -S -n --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" --arg id "$CANDIDATE_IMAGE_ID" \
        --arg ref "$CANDIDATE_IMAGE" --arg body "$body_sha" --arg exe "$exe_sha" \
        --arg start_gui "$start_gui_sha" --arg argv_sha "$argv_sha" \
        --arg config "$config_sha" --arg mounts "$second_mounts" \
        --arg network "$second_network" --argjson restart "$second_restart" \
        --slurpfile first "$first" --slurpfile second "$second" --slurpfile argv "$argv" '
        {schema:1,candidate_source_sha:$source,image_id:$id,image_ref:$ref,
         container_id:$second[0][0].Id,running_first:true,running_second:true,
         stable_started_at:$second[0][0].State.StartedAt,
         stable_restart_count:$second[0][0].RestartCount,
         pid1_exe_sha256:$exe,start_gui_sha256:$start_gui,
         entrypoint_body_sha256:$body,runtime_argv:$argv[0],runtime_argv_sha256:$argv_sha,
         config_sha256:$config,mounts_sha256:$mounts,network_sha256:$network,
         restart_policy:$restart,identity_stable_across_two_samples:true,
         candidate_running_without_restart:true}
    ' >"$output" || return 1
    rm -f -- "$first" "$second" "$argv"
}

wait_chain_wallet_sync_locked()
{
    local chain recovery wallet staking pow loaded tip locked
    for _ in $(seq 1 900); do
        chain=$(rpc getblockchaininfo) || return 1
        recovery=$(rpc getpowclaimrecoveryinfo true) || return 1
        wallet=$(rpc getwalletinfo) || return 1
        staking=$(rpc getstakinginfo) || return 1
        pow=$(rpc getpowmininginfo) || return 1
        loaded=$(rpc listwallets) || return 1
        tip=$(jq -er '.bestblockhash' <<<"$chain") || return 1
        if jq -e '.initialblockdownload == false and .blocks == .headers' <<<"$chain" >/dev/null &&
           jq -e --arg tip "$tip" '.chain_ready == true and .wallet_tip_matches == true and
             .active_tip == $tip and .wallet_processed_tip == $tip' <<<"$recovery" >/dev/null &&
           jq -e --arg wallet "$baseline_wallet_name" '
             .walletname==$wallet and .scanning==false and .private_keys_enabled==true and
             .unlocked_until==0 and .unlocked_staking_only==false' <<<"$wallet" >/dev/null &&
           jq -e --arg wallet "$baseline_wallet_name" '. == [$wallet]' <<<"$loaded" >/dev/null; then
            locked=$(jq -S -n --argjson chain "$chain" --argjson recovery "$recovery" \
                --argjson wallet "$wallet" --argjson staking "$staking" \
                --argjson pow "$pow" --argjson loaded "$loaded" '
                {schema:2,chain:$chain,recovery:$recovery,wallet:$wallet,
                 loaded_wallets:$loaded,staking:$staking,pow:$pow,synchronized:true,
                 wallet_locked:true,normal_unlock_called:false,
                 pos_intent_retained:($staking.enabled==true and
                   $staking.autostart_staking==true),
                 pow_intent_retained:($pow.enabled==true and $pow.autostart==true and
                   $pow.threads==1 and $pow.cpu_percent==1),
                 locked_pos_zero_work:($staking.staking==false and
                   $staking.eligible==false and $staking.staking_state=="locked"),
                 locked_pow_zero_work:($pow.hashrate==0 and $pow.claims_submitted==0 and
                   $pow.state=="wallet_locked_or_staking_only")}
            ') || return 1
            printf '%s\n' "$locked" >"${EVIDENCE}/candidate-chain-wallet-synchronized.json" ||
                return 1
            if hotfix_phase_b_locked_sync_file_is_valid \
                "${EVIDENCE}/candidate-chain-wallet-synchronized.json"; then
                return 0
            fi
            rm -f -- "${EVIDENCE}/candidate-chain-wallet-synchronized.json"
        fi
        sleep 2
    done
    return 1
}

classify_phase_b_wallet_delta()
{
    local baseline="$1" final="$2" recovery="$3" output="$4" raw_output="$5"
    local baseline_recovery="$6" progress="$7"
    local baseline_txids final_txids new_txids removed_txids txid rows blockhash block shadow
    local wallet_tx active_blockhash confirmations
    local source_txid payout_address
    local recovery_matches prior_recovery_authority classified='[]' raw_records='[]'
    local row raw_row class
    local baseline_sha final_sha recovery_sha baseline_recovery_sha progress_sha raw_sha
    baseline_sha=$(sha256sum "$baseline" | awk '{print $1}') || return 1
    final_sha=$(sha256sum "$final" | awk '{print $1}') || return 1
    recovery_sha=$(sha256sum "$recovery" | awk '{print $1}') || return 1
    baseline_recovery_sha=$(sha256sum "$baseline_recovery" | awk '{print $1}') || return 1
    progress_sha=$(sha256sum "$progress" | awk '{print $1}') || return 1
    baseline_txids=$(jq -c '[.[].txid] | unique' "$baseline") || return 1
    final_txids=$(jq -c '[.[].txid] | unique' "$final") || return 1
    new_txids=$(jq -cn --argjson baseline "$baseline_txids" --argjson final "$final_txids" \
        '$final | map(select(. as $txid | $baseline | index($txid) | not))') || return 1
    removed_txids=$(jq -cn --argjson baseline "$baseline_txids" --argjson final "$final_txids" \
        '$baseline | map(select(. as $txid | $final | index($txid) | not))') || return 1
    [[ "$(jq -r 'length' <<<"$removed_txids")" == 0 ]] || return 1
    while IFS= read -r txid; do
        hotfix_valid_sha256 "$txid" || return 1
        rows=$(jq -c --arg txid "$txid" '[.[] | select(.txid==$txid)]' "$final") || return 1
        recovery_matches=$(jq -c --arg txid "$txid" '[.component_details[] as $component |
          $component.nodes[] | select(.txid==$txid) | {component:$component,node:.}]' \
          "$recovery") || return 1
        block='null'
        shadow='null'
        wallet_tx=$(rpc gettransaction "$txid" true true) || return 1
        prior_recovery_authority=$(jq -c --arg txid "$txid" \
          --slurpfile baseline "$baseline_recovery" --slurpfile progress "$progress" '
          def matches($source;$sample;$observed;$recovery):
            [$recovery.component_details[] as $component |
              $component.nodes[] | select(.txid==$txid) |
              {source:$source,sample:$sample,observed_epoch:$observed,
               active_tip:$recovery.active_tip,
               wallet_processed_tip:$recovery.wallet_processed_tip,
               component:$component,node:.}];
          (matches("baseline";null;null;$baseline[0]) +
           [$progress[0].samples[] |
             matches("phase_b_progress";.sample;.observed_epoch;.recovery)[]]) |
          sort_by(if .source=="baseline" then 0 else 1 end,
                  (.sample // 0),.component.component_fingerprint,.node.txid)
        ') || return 1
        active_blockhash='null'
        blockhash=''
        source_txid=''
        payout_address=''
        if jq -e --arg txid "$txid" --arg zero "$HOTFIX_ZERO_TXID" \
          --argjson rows "$rows" --argjson wallet "$wallet_tx" \
          --argjson prior "$prior_recovery_authority" '
          def integer: type=="number" and floor==.;
          def hex64: type=="string" and test("^[0-9a-f]{64}$");
          def nonzero_hex64: hex64 and . != $zero;
          def claim_nodes($component):
            $component.nodes | map(select(.kind=="claim")) | sort_by(.lineage_ordinal);
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
            ($node.proof_version==2 and $node.proof_origin_bound==false and
              $node.proof_input_bound==false) or
            ($node.proof_version==3 and $node.proof_origin_bound==true and
              $node.proof_input_bound==false) or
            ($node.proof_version==4 and $node.proof_origin_bound==true and
              $node.proof_input_bound==true);
          def implicit_claim_root($node;$claim_count):
            known_disposition($node) and
            $node.lineage_metadata_present==false and
            $node.lineage_metadata_valid==false and $node.lineage_ordinal==0 and
            $node.lineage_family_fingerprint==$zero and
            $node.lineage_root_txid==$zero and $node.lineage_parent_txid==$zero and
            $node.proof_mode=="pow" and $node.provenance=="explicit_authored" and
            $node.authored_metadata_valid==true and $node.expected_shape==true and
            $node.claim_descriptor_valid==true and
            $node.exact_authored_carrier_shape==true and
            $node.proof_evaluation_skipped_resolved_anchor==false and
            $node.proof_may_revalidate_on_descendant==
              ($node.disposition=="unbound_proof_may_revalidate") and
            exact_proof_tuple($node) and
            (if $claim_count==1 and $node.proof_version==2 then
               $node.authored_tip_active_branch_bound==true
             else true end);
          def canonical_component($match):
            ($match.component) as $component |
            (claim_nodes($component)) as $claims |
            ($claims|length)>=1 and $component.anchor_authenticated==true and
            ($component.generation_fingerprint|hex64) and
            $component.generation_fingerprint!=$zero and
            ([$claims[].txid]|sort)==($component.claim_txids|sort) and
            ($claims|map(.lineage_ordinal))==[range(0;($claims|length))] and
            (if $claims[0].lineage_metadata_present then
               $claims[0].lineage_metadata_valid==true and
               $claims[0].lineage_root_txid==$claims[0].txid and
               $claims[0].lineage_family_fingerprint==$component.generation_fingerprint and
               $claims[0].lineage_parent_txid==$zero
             else implicit_claim_root($claims[0];($claims|length)) end) and
            all(range(1;($claims|length));
              $claims[.].lineage_metadata_present==true and
              $claims[.].lineage_metadata_valid==true and
              $claims[.].lineage_family_fingerprint==$component.generation_fingerprint and
              $claims[.].lineage_root_txid==$claims[0].txid and
              $claims[.].lineage_parent_txid==$claims[.-1].txid) and
            all($claims[];
              .expected_shape==true and .wallet_authored==true and
              .wallet_from_me==true and .authored_metadata_valid==true and
              .claim_descriptor_valid==true and .exact_authored_carrier_shape==true and
              .provenance=="explicit_authored" and
              .proof_evaluation_skipped_resolved_anchor==false and
              .proof_may_revalidate_on_descendant==
                (.disposition=="unbound_proof_may_revalidate") and
              exact_proof_tuple(.));
          def authenticated_new_claim($match):
            canonical_component($match) and $match.node.txid==$txid and
            $match.node.kind=="claim" and
            $match.node.provenance=="explicit_authored" and
            $match.node.wallet_authored==true and $match.node.wallet_from_me==true and
            $match.node.expected_shape==true and
            $match.node.lineage_metadata_present==true and
            $match.node.lineage_metadata_valid==true and
            exact_proof_tuple($match.node) and
            $match.node.resolution_metadata_valid==false and
            $match.node.resolution_relay_authorized==false and
            ($match.component.claim_txids|index($txid))!=null and
            ($match.component.resolution_txids|index($txid))==null and
            ($match.component.ordinary_or_mixed_txids|index($txid))==null;
          def exact_wallet_metadata($object;$match):
            $object.qq_shadow_pow_authored=="1" and
            $object.qq_shadow_pow_lineage_schema=="1" and
            $object.qq_shadow_pow_lineage_family==$match.component.generation_fingerprint and
            $object.qq_shadow_pow_lineage_root==$match.node.lineage_root_txid and
            $object.qq_shadow_pow_lineage_parent==$match.node.lineage_parent_txid and
            $object.qq_shadow_pow_lineage_ordinal==($match.node.lineage_ordinal|tostring) and
            ($object.qq_shadow_pow_created_tip|hex64) and
            ($object.qq_shadow_pow_created_height?==null or
              (($object.qq_shadow_pow_created_height|type)=="string" and
               ($object.qq_shadow_pow_created_height|test("^[0-9]+$")))) and
            $object.qq_shadow_pow_anchor_txid==$match.component.anchor.txid and
            $object.qq_shadow_pow_anchor_vout==($match.component.anchor.vout|tostring) and
            ($object.qq_shadow_pow_cleanup_for?==null) and
            ($object.qq_shadow_pow_legacy_cleanup_quarantine?==null) and
            ($object.qq_auto_shadow_stale?==null) and
            ($object.qq_manual_shadow_abandon?==null) and
            ($object.qq_reorg_shadow_resubmit?==null) and
            ($object.qq_shadow_pow_resolution_schema?==null) and
            ($object.qq_shadow_pow_resolution_origin?==null) and
            ($object.qq_shadow_pow_resolution_anchor_txid?==null);
          def intrinsic_authored_descriptor($object):
            if ($object|type)=="object" and
               $object.qq_shadow_pow_authored=="1" and
               $object.qq_shadow_pow_lineage_schema=="1" and
               ($object.qq_shadow_pow_lineage_family|nonzero_hex64) and
               ($object.qq_shadow_pow_lineage_root|nonzero_hex64) and
               ($object.qq_shadow_pow_lineage_parent|hex64) and
               ($object.qq_shadow_pow_lineage_ordinal|type)=="string" and
               ($object.qq_shadow_pow_lineage_ordinal|test("^(0|[1-9][0-9]*)$")) and
               ($object.qq_shadow_pow_created_tip|nonzero_hex64) and
               ($object.qq_shadow_pow_created_height?==null or
                 (($object.qq_shadow_pow_created_height|type)=="string" and
                  ($object.qq_shadow_pow_created_height|test("^(0|[1-9][0-9]*)$")))) and
               ($object.qq_shadow_pow_anchor_txid|nonzero_hex64) and
               ($object.qq_shadow_pow_anchor_vout|type)=="string" and
               ($object.qq_shadow_pow_anchor_vout|test("^(0|[1-9][0-9]*)$")) and
               ($object.qq_shadow_pow_anchor_vout|tonumber)<4294967295 and
               ($object.qq_shadow_pow_cleanup_for?==null) and
               ($object.qq_shadow_pow_legacy_cleanup_quarantine?==null) and
               ($object.qq_auto_shadow_stale?==null) and
               ($object.qq_manual_shadow_abandon?==null) and
               ($object.qq_reorg_shadow_resubmit?==null) and
               ($object.qq_shadow_pow_resolution_schema?==null) and
               ($object.qq_shadow_pow_resolution_origin?==null) and
               ($object.qq_shadow_pow_resolution_anchor_txid?==null) and
               $object.qq_shadow_pow_lineage_ordinal=="0" and
               $object.qq_shadow_pow_lineage_root==$txid and
               $object.qq_shadow_pow_lineage_parent==$zero
            then {family:$object.qq_shadow_pow_lineage_family,
              root:$object.qq_shadow_pow_lineage_root,
              parent:$object.qq_shadow_pow_lineage_parent,
              ordinal:$object.qq_shadow_pow_lineage_ordinal,
              created_tip:$object.qq_shadow_pow_created_tip,
              created_height:($object.qq_shadow_pow_created_height? // null),
              anchor_txid:$object.qq_shadow_pow_anchor_txid,
              anchor_vout:$object.qq_shadow_pow_anchor_vout}
            else null end;
          def intrinsic_confirmed_authored_claim:
            (intrinsic_authored_descriptor($wallet)) as $descriptor |
            $descriptor!=null and ($rows|length)>=1 and all($rows[];
              .txid==$txid and .category=="send" and
              (.comment | IN("Quantum Quasar built-in shadow PoW claim",
                "Blackcoin shadow PoW claim","PoW Claim","Quantum PoW Claim")) and
              intrinsic_authored_descriptor(.)==$descriptor);
          def exact_claim_rows($match):
            ($rows|length)>=1 and all($rows[];
              .txid==$txid and .category=="send" and
              (.comment | IN("Quantum Quasar built-in shadow PoW claim",
                "Blackcoin shadow PoW claim","PoW Claim","Quantum PoW Claim")) and
              exact_wallet_metadata(.;$match));
          [.component_details[] as $component |
            $component.nodes[] | select(.txid==$txid) |
            {component:$component,node:.}] as $current |
          [$prior[] | select(
            .source=="phase_b_progress" and (.sample|integer) and .sample>=1 and
            (.observed_epoch|integer) and .observed_epoch>0 and
            (.active_tip|hex64) and .wallet_processed_tip==.active_tip and
            authenticated_new_claim({component:.component,node:.node}))] as
            $prior_authenticated |
          ($wallet|type)=="object" and $wallet.txid==$txid and
          ($wallet.hex|type)=="string" and ($wallet.hex|test("^[0-9a-f]+$")) and
          (($wallet.hex|length)%2)==0 and ($wallet.decoded|type)=="object" and
          $wallet.decoded.txid==$txid and ($wallet.confirmations|integer) and
          ($wallet.details|type)=="array" and ($wallet.details|length)>=1 and
          (if $wallet.confirmations==0 then
             ($wallet.blockhash?==null) and ($current|length)==1 and
             authenticated_new_claim($current[0]) and
             exact_wallet_metadata($wallet;$current[0]) and exact_claim_rows($current[0])
           elif $wallet.confirmations>0 then
             ($wallet.blockhash|hex64) and
             (if ($prior_authenticated|length)>=1 then
                ($prior_authenticated[-1]) as $authority |
                exact_wallet_metadata($wallet;
                  {component:$authority.component,node:$authority.node}) and
                exact_claim_rows({component:$authority.component,node:$authority.node})
              else intrinsic_confirmed_authored_claim end)
           else false end)
        ' "$recovery" >/dev/null; then
            confirmations=$(jq -er '.confirmations' <<<"$wallet_tx") || return 1
            blockhash=$(jq -r '.blockhash // ""' <<<"$wallet_tx") || return 1
            if (( confirmations > 0 )); then
                hotfix_valid_sha256 "$blockhash" || return 1
                block=$(rpc getblock "$blockhash" 1) || return 1
                jq -e --arg txid "$txid" --arg blockhash "$blockhash" '
                  .hash==$blockhash and .confirmations>0 and
                  (.height|type)=="number" and (.height|floor)==.height and .height>=0 and
                  (.tx|type)=="array" and (.tx|index($txid))!=null
                ' <<<"$block" >/dev/null || return 1
                active_blockhash=$(rpc getblockhash "$(jq -er '.height' <<<"$block")") ||
                    return 1
                [[ "$(jq -r . <<<"$active_blockhash")" == "$blockhash" ]] || return 1
                jq -e --arg blockhash "$blockhash" '
                  all(.[]; (.confirmations|type)=="number" and
                    (.confirmations|floor)==.confirmations and .confirmations>0 and
                    .blockhash==$blockhash)
                ' <<<"$rows" >/dev/null || return 1
            elif (( confirmations == 0 )) && [[ -z "$blockhash" ]]; then
                block='null'
                active_blockhash='null'
                jq -e 'all(.[]; .confirmations==0 and (.blockhash?==null))' \
                    <<<"$rows" >/dev/null || return 1
            else
                return 1
            fi
            row=$(jq -cn --arg txid "$txid" '{txid:$txid,class:"authenticated_qq_claim"}') ||
                return 1
        elif jq -e --arg txid "$txid" '
          def no_control_metadata:
            ([keys[] | select(startswith("qq_"))] | length)==0;
          def clean_receive:
            (.amount|type)=="number" and .amount>0 and .abandoned==false and
            (.fee?==null) and (.generated?==null) and
            .category=="receive" and no_control_metadata and
            ((.comment? // "") |
              IN("Quantum Quasar built-in shadow PoW claim",
                 "Blackcoin shadow PoW claim","PoW Claim","Quantum PoW Claim") | not);
          .txid==$txid and (.hex|type)=="string" and
          (.hex|test("^[0-9a-f]+$")) and ((.hex|length)%2)==0 and
          (.decoded|type)=="object" and .decoded.txid==$txid and
          (.fee?==null) and (.amount|type)=="number" and .amount>0 and
          (.generated?==null) and no_control_metadata and
          (.details|type)=="array" and (.details|length)>=1 and
          all(.details[]; clean_receive)
        ' <<<"$wallet_tx" >/dev/null && jq -e --arg txid "$txid" '
          length>=1 and all(.[];
            .txid==$txid and .category=="receive" and
            (.amount|type)=="number" and .amount>0 and .abandoned==false and
            (.fee?==null) and (.generated?==null) and
            ([keys[] | select(startswith("qq_"))] | length)==0 and
            ((.comment? // "") |
              IN("Quantum Quasar built-in shadow PoW claim",
                 "Blackcoin shadow PoW claim","PoW Claim","Quantum PoW Claim") | not))
        ' <<<"$rows" >/dev/null; then
            confirmations=$(jq -er '.confirmations | select(type=="number" and floor==.)' \
                <<<"$wallet_tx") || return 1
            blockhash=$(jq -r '.blockhash // ""' <<<"$wallet_tx") || return 1
            if (( confirmations > 0 )); then
                hotfix_valid_sha256 "$blockhash" || return 1
                block=$(rpc getblock "$blockhash" 1) || return 1
                jq -e --arg txid "$txid" --arg blockhash "$blockhash" \
                    '.hash==$blockhash and .confirmations>0 and
                     (.height|type)=="number" and (.height|floor)==.height and
                     (.tx|type)=="array" and (.tx|index($txid))!=null' \
                    <<<"$block" >/dev/null || return 1
                active_blockhash=$(rpc getblockhash "$(jq -er '.height' <<<"$block")") ||
                    return 1
                [[ "$(jq -r . <<<"$active_blockhash")" == "$blockhash" ]] || return 1
                jq -e 'length==0' <<<"$recovery_matches" >/dev/null || return 1
                jq -e --arg blockhash "$blockhash" '
                  all(.[]; (.confirmations|type)=="number" and
                    (.confirmations|floor)==.confirmations and .confirmations>0 and
                    .blockhash==$blockhash)
                ' <<<"$rows" >/dev/null || return 1
            elif (( confirmations == 0 )) && [[ -z "$blockhash" ]]; then
                jq -e 'all(.[]; .confirmations==0 and (.blockhash?==null))' \
                    <<<"$rows" >/dev/null || return 1
                if ! jq -e 'length==0' <<<"$recovery_matches" >/dev/null; then
                    jq -e --arg txid "$txid" --arg zero "$HOTFIX_ZERO_TXID" '
                      def integer: type=="number" and floor==.;
                      def hex64: type=="string" and test("^[0-9a-f]{64}$");
                      . as $recovery |
                      [.component_details[] as $component |
                        $component.nodes[] | select(.txid==$txid) |
                        {component:$component,node:.}] as $matches |
                      ($matches|length)==1 and ($matches[0].component) as $component |
                      $component.anchor_authenticated==false and
                      $component.anchor_unspent==false and
                      $component.anchor_user_locked==false and
                      $component.anchor.amount==0 and
                      $component.anchor.scriptPubKey=="" and
                      (($component.anchor.txid==$zero and
                         $component.anchor.vout==4294967295) or
                       (($component.anchor.txid|hex64) and
                         $component.anchor.txid!=$zero and
                         ($component.anchor.vout|integer) and
                         $component.anchor.vout>=0 and
                         $component.anchor.vout<4294967295)) and
                      ($component.nodes|type)=="array" and
                      ($component.claim_txids|type)=="array" and
                      ($component.claim_txids|length)>=1 and
                      ([$component.nodes[]|select(.kind=="claim")|.txid]|sort)==
                        ($component.claim_txids|sort) and
                      ([$component.nodes[].txid]|sort)==
                        ([$component.claim_txids[],$component.resolution_txids[],
                          $component.ordinary_or_mixed_txids[]]|sort) and
                      ([$component.nodes[].txid]|unique|length)==
                        ($component.nodes|length) and
                      all($component.nodes[];
                        .provenance=="unknown" and .wallet_authored==false and
                        .wallet_from_me==false) and
                      all($component.claim_txids[];
                        . as $claim | ($recovery.unanchored_claim_txids|index($claim))!=null)
                    ' "$recovery" >/dev/null || return 1
                fi
            else
                return 1
            fi
            row=$(jq -cn --arg txid "$txid" --arg blockhash "$blockhash" \
                '{txid:$txid,class:"external_receive",
                  blockhash:(if $blockhash=="" then null else $blockhash end)}') || return 1
        elif jq -e '
          length>=1 and all(.[];
            .generated==true and (.category|IN("generate","immature","orphan")) and
            .abandoned==false and
            (.blockhash|type)=="string" and (.blockhash|test("^[0-9a-f]{64}$")) and
            (.qq_shadow_pow_cleanup_for?==null) and
            (.qq_shadow_pow_resolution_schema?==null) and
            (.qq_synthetic_goldrush_payout?==null) and
            (.qq_shadow_pow_authored?==null)) and
          ([.[].blockhash]|unique|length)==1
        ' <<<"$rows" >/dev/null &&
           jq -e 'length==0' <<<"$recovery_matches" >/dev/null; then
            blockhash=$(jq -er '.[0].blockhash' <<<"$rows") || return 1
            block=$(rpc getblock "$blockhash" 1) || return 1
            jq -e --arg txid "$txid" --arg blockhash "$blockhash" \
                '.hash==$blockhash and .confirmations>0 and (.tx|type)=="array" and (.tx|length)>=2 and
                 .tx[0]!=$txid and .tx[1]==$txid' <<<"$block" >/dev/null || return 1
            row=$(jq -cn --arg txid "$txid" --arg blockhash "$blockhash" \
                '{txid:$txid,class:"confirmed_coinstake",blockhash:$blockhash}') || return 1
        elif jq -e '
          length>=1 and all(.[];
              .qq_synthetic_goldrush_payout=="1" and
              (.qq_synthetic_goldrush_payout_stale?==null) and .generated==true and
              (.category|IN("generate","immature")) and
            (.blockhash|type)=="string" and (.blockhash|test("^[0-9a-f]{64}$")) and
            (.qq_shadow_pow_cleanup_for?==null) and
            (.qq_shadow_pow_resolution_schema?==null)) and
          ([.[].blockhash]|unique|length)==1
        ' <<<"$rows" >/dev/null; then
            blockhash=$(jq -er '.[0].blockhash' <<<"$rows") || return 1
            shadow=$(rpc getshadowtransaction "$txid") || return 1
            source_txid=$(jq -er '.pow_claim_source.txid |
              select(type=="string" and test("^[0-9a-f]{64}$"))' <<<"$shadow") || return 1
            recovery_matches=$(jq -c --arg txid "$source_txid" '
              [.component_details[] as $component |
                $component.nodes[] | select(.txid==$txid) | {component:$component,node:.}]
            ' "$recovery") || return 1
            prior_recovery_authority=$(jq -c --arg txid "$source_txid" \
              --slurpfile baseline "$baseline_recovery" --slurpfile progress "$progress" '
              def matches($source;$sample;$observed;$recovery):
                [$recovery.component_details[] as $component |
                  $component.nodes[] | select(.txid==$txid) |
                  {source:$source,sample:$sample,observed_epoch:$observed,
                   active_tip:$recovery.active_tip,
                   wallet_processed_tip:$recovery.wallet_processed_tip,
                   component:$component,node:.}];
              (matches("baseline";null;null;$baseline[0]) +
               [$progress[0].samples[] |
                 matches("phase_b_progress";.sample;.observed_epoch;.recovery)[]]) |
              sort_by(if .source=="baseline" then 0 else 1 end,
                      (.sample // 0),.component.component_fingerprint,.node.txid)
            ') || return 1
            jq -e --arg txid "$txid" --arg blockhash "$blockhash" \
              --arg source_txid "$source_txid" --argjson rows "$rows" \
              --argjson wallet "$wallet_tx" '
              def integer: type=="number" and floor==.;
              def hex64: type=="string" and test("^[0-9a-f]{64}$");
              def rawhex: type=="string" and test("^[0-9a-f]+$") and length%2==0;
              def credited:
                IN("winner","reimbursed_loser","reimbursed_late");
              def exact_source($source):
                ($source.txid|hex64) and $source.txid==$source_txid and
                ($source.vout|integer) and $source.vout>=0 and $source.vout<4294967295 and
                ($source.disposition|credited) and
                (($source.proof_version==2 and $source.origin_bound==false and
                   $source.input_bound==false and $source.claim_outpoint==null) or
                 ($source.proof_version==3 and $source.origin_bound==true and
                   $source.input_bound==false and $source.claim_outpoint==null) or
                 ($source.proof_version==4 and $source.origin_bound==true and
                   $source.input_bound==true and
                   ($source.claim_outpoint|type)=="object" and
                   ($source.claim_outpoint|keys|sort)==["txid","vout"] and
                   ($source.claim_outpoint.txid|hex64) and
                   ($source.claim_outpoint.vout|integer) and
                   $source.claim_outpoint.vout>=0 and
                   $source.claim_outpoint.vout<4294967295));
              def wallet_credit($row;$shadow;$long):
                ($row.category|IN("generate","immature")) and
                ($row.amount|type)=="number" and $row.amount>0 and
                $row.abandoned==false and ($row.fee?==null) and
                (if $long then
                   ($row.blockhash|hex64) and $row.blockhash==$blockhash
                 else true end) and
                $row.vout==$shadow.vout and
                (if ($row|has("address")) then
                   $row.address==$shadow.address else true end);
              . as $shadow |
              .schema=="blackcoin.shadow.transaction.v1" and .synthetic==true and
              .merkle_included==false and .synthetic_txid==$txid and .mode=="pow" and
              (.status | IN("immature","gold_rush_locked","demurrage_locked",
                "unspent","spent")) and
              (.vout|integer) and .vout>=0 and .vout<4294967295 and
              (.scriptPubKey|rawhex) and .base_anchor.blockhash==$blockhash and
              (.base_anchor.height|integer) and .base_anchor.height>=0 and
              (.base_anchor.claim_index|integer) and .base_anchor.claim_index>=0 and
              (.address|type)=="string" and (.address|length)>0 and
              exact_source(.pow_claim_source) and
              ($wallet|type)=="object" and $wallet.txid==$txid and
              ($wallet.hex|rawhex) and ($wallet.decoded|type)=="object" and
              $wallet.decoded.txid==$txid and ($wallet.fee?==null) and
              ($wallet.amount|type)=="number" and $wallet.amount>0 and
              ($wallet.confirmations|integer) and $wallet.confirmations>0 and
              $wallet.blockhash==$blockhash and
              ($wallet.details|type)=="array" and ($wallet.details|length)>=1 and
              all($wallet.details[]; wallet_credit(.;$shadow;false)) and
              ($rows|length)>=1 and all($rows[]; wallet_credit(.;$shadow;true)) and
              ([ $wallet.decoded.vout[] |
                 select((.n|integer) and .n==$shadow.vout and
                   .scriptPubKey.hex==$shadow.scriptPubKey and
                   (if (.scriptPubKey|has("address")) then
                      .scriptPubKey.address==$shadow.address else true end)) ] | length)==1
            ' <<<"$shadow" >/dev/null || return 1
            block=$(rpc getblock "$blockhash" 1) || return 1
            jq -e --arg blockhash "$blockhash" --arg source "$source_txid" \
              --argjson shadow "$shadow" '
              .hash==$blockhash and .confirmations>0 and
              (.height|type)=="number" and (.height|floor)==.height and
              .height==$shadow.base_anchor.height and
              (.tx|type)=="array" and (.tx|index($source))!=null
            ' <<<"$block" >/dev/null || return 1
            active_blockhash=$(rpc getblockhash "$(jq -er '.height' <<<"$block")") ||
                return 1
            [[ "$(jq -r . <<<"$active_blockhash")" == "$blockhash" ]] || return 1
            payout_address=$(jq -er '.address | select(type=="string" and length>0)' \
                <<<"$shadow") || return 1
            row=$(jq -cn --arg txid "$txid" --arg blockhash "$blockhash" \
                --arg source "$source_txid" --arg payout "$payout_address" \
                '{txid:$txid,class:"authenticated_qq_claim_payout",blockhash:$blockhash,
                  source_claim_txid:$source,payout_address:$payout}') || return 1
        else
            return 1
        fi
        class=$(jq -er '.class' <<<"$row") || return 1
        raw_row=$(jq -cn --arg txid "$txid" --arg class "$class" \
            --arg blockhash "$blockhash" --arg source "$source_txid" \
            --argjson rows "$rows" --argjson recovery_matches "$recovery_matches" \
            --argjson prior "$prior_recovery_authority" \
            --argjson block "$block" --argjson shadow "$shadow" \
            --argjson wallet_tx "$wallet_tx" --argjson active_blockhash "$active_blockhash" '
            {txid:$txid,class:$class,wallet_rows:$rows,recovery_matches:$recovery_matches,
             prior_recovery_authority:$prior,
             blockhash:(if $blockhash=="" then null else $blockhash end),
             source_claim_txid:(if $source=="" then null else $source end),
             getblock_response:$block,getblockhash_response:$active_blockhash,
             gettransaction_response:$wallet_tx,getshadowtransaction_response:$shadow}
        ') || return 1
        classified=$(jq -cn --argjson rows "$classified" --argjson row "$row" \
            '$rows+[$row]') || return 1
        raw_records=$(jq -cn --argjson rows "$raw_records" --argjson row "$raw_row" \
            '$rows+[$row]') || return 1
    done < <(jq -r '.[]' <<<"$new_txids")
    jq -S -n --arg baseline "$baseline_sha" --arg final "$final_sha" \
        --arg recovery "$recovery_sha" --arg baseline_recovery "$baseline_recovery_sha" \
        --arg progress "$progress_sha" --argjson records "$raw_records" \
        --argjson unanchored "$(jq -c '.unanchored_claim_txids' "$recovery")" '
        {schema:4,baseline_wallet_transactions_sha256:$baseline,
         final_wallet_transactions_sha256:$final,recovery_inventory_sha256:$recovery,
         baseline_recovery_sha256:$baseline_recovery,phase_b_progress_sha256:$progress,
         recovery_unanchored_claim_txids:$unanchored,records:$records,complete:true}
    ' >"$raw_output" || return 1
    hotfix_phase_b_wallet_delta_raw_file_is_valid "$raw_output" "$baseline_sha" \
        "$final_sha" "$recovery_sha" "$baseline_recovery_sha" "$progress_sha" || return 1
    raw_sha=$(sha256sum "$raw_output" | awk '{print $1}') || return 1
    jq -S -n --argjson baseline "$baseline_txids" --argjson added "$new_txids" \
        --argjson removed "$removed_txids" \
        --argjson classified "$classified" --arg raw "$raw_sha" '
        {schema:4,baseline_txids:$baseline,new_txids:$added,removed_txids:$removed,
         classifications:$classified,rejected_txids:[],complete:true,
         raw_evidence_sha256:$raw,
         allowed_classes:["confirmed_coinstake","authenticated_qq_claim",
           "authenticated_qq_claim_payout","external_receive"]}
    ' >"$output" || return 1
    hotfix_phase_b_wallet_delta_file_is_valid "$output" "$raw_output" || return 1
    [[ "$(jq -r '.new_txids|length' "$output")" == \
       "$(jq -r '.classifications|length' "$output")" ]]
}

capture_final_envelope()
{
    local observed chain_after tip mode current_quantum locked_sync_sha final_recovery_sha
    local current_payout payout_evidence_sha goldrush_state goldrush_sha
    mode=active
    for _ in $(seq 1 20); do
        observed=$(date +%s)
        rpc getblockchaininfo >"${EVIDENCE}/candidate-final-chain.json" || return 1
        capture_goldrush_state "${EVIDENCE}/candidate-final-goldrush-state.json" || return 1
        rpc getnetworkinfo >"${EVIDENCE}/candidate-final-network.json" || return 1
        rpc getwalletinfo >"${EVIDENCE}/candidate-final-wallet.json" || return 1
        rpc getstakinginfo >"${EVIDENCE}/candidate-final-staking.json" || return 1
        rpc getpowmininginfo >"${EVIDENCE}/candidate-final-pow.json" || return 1
        rpc getpowclaimrecoveryinfo true >"${EVIDENCE}/candidate-final-recovery.json" || return 1
        rpc getrawmempool true | jq -S . \
            >"${EVIDENCE}/candidate-final-mempool-verbose.json" || return 1
        rpc getquantumkeyinventory | jq -S . >"${EVIDENCE}/candidate-final-quantum.json" ||
            return 1
        capture_quantum_payout_label_evidence "${EVIDENCE}/candidate-final-quantum.json" \
            "${EVIDENCE}/candidate-final-quantum-labels.json" || return 1
        rpc listwallets | jq -S . >"${EVIDENCE}/candidate-final-loaded-wallets.json" || return 1
        capture_wallet_transactions "${EVIDENCE}/candidate-final-wallet-transactions.json" ||
            return 1
        rpc getblockchaininfo >"${EVIDENCE}/candidate-final-chain-after.json" || return 1
        chain_after=$(<"${EVIDENCE}/candidate-final-chain-after.json")
        tip=$(jq -er '.bestblockhash' "${EVIDENCE}/candidate-final-chain.json") || return 1
        goldrush_state=$(<"${EVIDENCE}/candidate-final-goldrush-state.json")
        hotfix_goldrush_state_json_is_valid "$goldrush_state" "$tip" \
            "$(jq -er '.blocks' "${EVIDENCE}/candidate-final-chain.json")" || return 1
        if ! jq -e --argjson after "$chain_after" '
          .chain=="main" and .initialblockdownload==false and .blocks==.headers and
          .bestblockhash==$after.bestblockhash and .chainwork==$after.chainwork and
          .blocks==$after.blocks
        ' "${EVIDENCE}/candidate-final-chain.json" >/dev/null; then
            sleep 1
            continue
        fi
        jq -e '.networkactive==true and .connections_out>=3' \
            "${EVIDENCE}/candidate-final-network.json" >/dev/null || return 1
        jq -e --argjson observed "$observed" --arg wallet "$baseline_wallet_name" '
          .walletname==$wallet and .scanning==false and .private_keys_enabled==true and
          .unlocked_staking_only==false and .unlocked_until>$observed
        ' "${EVIDENCE}/candidate-final-wallet.json" >/dev/null || return 1
        hotfix_phase_b_staking_json_is_active \
            "$(<"${EVIDENCE}/candidate-final-staking.json")" || return 1
        hotfix_candidate_pow_json_is_valid "$(<"${EVIDENCE}/candidate-final-pow.json")" \
            "$mode" || return 1
        jq -e '.autostart_staking==true and
          .autostart_staking_source=="autostartstaking"' \
            "${EVIDENCE}/candidate-final-staking.json" >/dev/null || return 1
        jq -e '.autostart==true and .enabled==true and .threads==1 and .cpu_percent==1' \
            "${EVIDENCE}/candidate-final-pow.json" >/dev/null || return 1
        jq -e --arg tip "$tip" '
          .claim_inventory_wallet_tip_matches==true and .claim_inventory_tip==$tip
        ' "${EVIDENCE}/candidate-final-pow.json" >/dev/null || return 1
        hotfix_candidate_recovery_json_is_valid \
            "$(<"${EVIDENCE}/candidate-final-recovery.json")" || return 1
        hotfix_pow_recovery_same_cut_json_is_valid \
            "$(<"${EVIDENCE}/candidate-final-pow.json")" \
            "$(<"${EVIDENCE}/candidate-final-recovery.json")" || return 1
        hotfix_pow_observation_json_is_valid \
            "$(<"${EVIDENCE}/candidate-final-pow.json")" \
            "$(<"${EVIDENCE}/candidate-final-recovery.json")" \
            "$(<"${EVIDENCE}/candidate-final-mempool-verbose.json")" "$tip" \
            "$(jq -er '.blocks' "${EVIDENCE}/candidate-final-chain.json")" \
            "$observed" "$goldrush_state" || return 1
        jq -e --arg tip "$tip" '
          .active_tip==$tip and .wallet_processed_tip==$tip
        ' "${EVIDENCE}/candidate-final-recovery.json" >/dev/null || return 1
        jq -e --arg wallet "$baseline_wallet_name" '. == [$wallet]' \
            "${EVIDENCE}/candidate-final-loaded-wallets.json" >/dev/null || return 1
        current_payout=$(jq -er '.payout_address | select(type=="string")' \
            "${EVIDENCE}/candidate-final-pow.json") || return 1
        if [[ -n "$current_payout" ]]; then
            rpc getaddressinfo "$current_payout" | jq -S . \
                >"${EVIDENCE}/candidate-final-payout-address.json" || return 1
            hotfix_quantum_payout_address_is_valid \
                "${EVIDENCE}/candidate-final-payout-address.json" \
                "${EVIDENCE}/baseline-quantum.json" "$current_payout" || return 1
            hotfix_quantum_payout_address_is_valid \
                "${EVIDENCE}/candidate-final-payout-address.json" \
                "${EVIDENCE}/candidate-final-quantum.json" "$current_payout" || return 1
        else
            printf 'null\n' >"${EVIDENCE}/candidate-final-payout-address.json" || return 1
        fi
        payout_evidence_sha=$(sha256sum \
            "${EVIDENCE}/candidate-final-payout-address.json" | awk '{print $1}') || return 1
        current_quantum=$(quantum_inventory_count "${EVIDENCE}/candidate-final-quantum.json") ||
            return 1
        [[ "$current_quantum" == "$baseline_quantum_count" ]] || return 1
        hotfix_quantum_inventory_transition_is_valid \
            "${EVIDENCE}/baseline-quantum.json" \
            "${EVIDENCE}/candidate-final-quantum.json" \
            "${EVIDENCE}/baseline-quantum-labels.json" \
            "${EVIDENCE}/candidate-final-quantum-labels.json" || return 1
        classify_phase_b_wallet_delta "${EVIDENCE}/baseline-wallet-transactions.json" \
            "${EVIDENCE}/candidate-final-wallet-transactions.json" \
            "${EVIDENCE}/candidate-final-recovery.json" \
            "${EVIDENCE}/phase-b-wallet-delta.json" \
            "${EVIDENCE}/phase-b-wallet-delta-raw.json" \
            "${EVIDENCE}/baseline-recovery.json" \
            "${EVIDENCE}/phase-b-progress.json" || return 1
        jq -S '[.component_details[]?.resolution_txids[]?] | unique | sort' \
            "${EVIDENCE}/candidate-final-recovery.json" \
            >"${EVIDENCE}/candidate-final-resolution-txids.json" || return 1
        jq -e -n --slurpfile baseline "${EVIDENCE}/baseline-wallet-resolution-txids.json" \
            --slurpfile current "${EVIDENCE}/candidate-final-resolution-txids.json" '
          all($current[0][]; . as $txid | ($baseline[0] | index($txid)) != null)
        ' >/dev/null || return 1
        capture_resolution_raw_identities \
            "${EVIDENCE}/candidate-final-resolution-txids.json" \
            "${EVIDENCE}/candidate-final-resolution-raw.json" || return 1
        jq -e -n --slurpfile baseline "${EVIDENCE}/baseline-wallet-resolution-raw.json" \
            --slurpfile current "${EVIDENCE}/candidate-final-resolution-raw.json" '
          all($current[0][]; . as $row |
            ([$baseline[0][] | select(.txid==$row.txid and .hex==$row.hex)] | length)==1)
        ' >/dev/null || return 1
        locked_sync_sha=$(sha256sum "${EVIDENCE}/candidate-chain-wallet-synchronized.json" |
            awk '{print $1}') || return 1
        final_recovery_sha=$(sha256sum "${EVIDENCE}/candidate-final-recovery.json" |
            awk '{print $1}') || return 1
        goldrush_sha=$(sha256sum "${EVIDENCE}/candidate-final-goldrush-state.json" |
            awk '{print $1}') || return 1
        jq -e -n --argjson final "$goldrush_state" \
            --slurpfile baseline "${EVIDENCE}/baseline-goldrush-state.json" \
            --slurpfile progress "${EVIDENCE}/phase-b-progress.json" '
          def schedule: {qqp4_activation_disabled,qqp4_activation_height};
          ($final|schedule)==($baseline[0]|schedule) and
          all($progress[0].samples[]; (.goldrush_state|schedule)==($final|schedule))
        ' >/dev/null || return 1
        jq -S -n --argjson observed "$observed" --arg tip "$tip" --arg mode "$mode" \
            --arg wallet_name "$baseline_wallet_name" --arg locked_sync "$locked_sync_sha" \
            --arg locked_resolution "$candidate_locked_resolution_sha" \
            --arg baseline_resolution "$(sha256sum \
              "${EVIDENCE}/baseline-wallet-resolution-txids.json" | awk '{print $1}')" \
            --arg baseline_resolution_raw "$(sha256sum \
              "${EVIDENCE}/baseline-wallet-resolution-raw.json" | awk '{print $1}')" \
            --arg locked_resolution_raw "$(sha256sum \
              "${EVIDENCE}/candidate-locked-resolution-raw.json" | awk '{print $1}')" \
            --arg final_recovery "$final_recovery_sha" \
            --arg final_goldrush "$goldrush_sha" \
            --arg final_payout "$payout_evidence_sha" \
            --arg quantum_before "$(sha256sum "${EVIDENCE}/baseline-quantum.json" | awk '{print $1}')" \
            --arg quantum_after "$(sha256sum "${EVIDENCE}/candidate-final-quantum.json" | awk '{print $1}')" \
            --arg quantum_labels_before "$(sha256sum "${EVIDENCE}/baseline-quantum-labels.json" | awk '{print $1}')" \
            --arg quantum_labels_after "$(sha256sum "${EVIDENCE}/candidate-final-quantum-labels.json" | awk '{print $1}')" \
            --arg final_resolution "$(sha256sum \
              "${EVIDENCE}/candidate-final-resolution-txids.json" | awk '{print $1}')" \
            --arg final_resolution_raw "$(sha256sum \
              "${EVIDENCE}/candidate-final-resolution-raw.json" | awk '{print $1}')" \
            --arg delta "$(sha256sum "${EVIDENCE}/phase-b-wallet-delta.json" | awk '{print $1}')" \
            --arg delta_raw "$(sha256sum "${EVIDENCE}/phase-b-wallet-delta-raw.json" | awk '{print $1}')" \
            --slurpfile chain "${EVIDENCE}/candidate-final-chain.json" \
            --slurpfile chain_after "${EVIDENCE}/candidate-final-chain-after.json" \
            --slurpfile network "${EVIDENCE}/candidate-final-network.json" \
            --slurpfile wallet "${EVIDENCE}/candidate-final-wallet.json" \
            --slurpfile staking "${EVIDENCE}/candidate-final-staking.json" \
            --slurpfile pow "${EVIDENCE}/candidate-final-pow.json" \
            --slurpfile recovery "${EVIDENCE}/candidate-final-recovery.json" \
            --slurpfile goldrush "${EVIDENCE}/candidate-final-goldrush-state.json" \
            --slurpfile mempool "${EVIDENCE}/candidate-final-mempool-verbose.json" \
            --slurpfile wallets "${EVIDENCE}/candidate-final-loaded-wallets.json" '
            {schema:2,observed_epoch:$observed,stable_tip:$tip,pow_mode:$mode,
             chain_before_after_identical:true,chain_recovery_pow_tip_bound:true,
             wallet_unlock_current:true,exact_loaded_wallets:[$wallet_name],
             automatic_recovery_unauthorized:true,
             candidate_locked_sync_sha256:$locked_sync,
             baseline_wallet_resolution_txids_sha256:$baseline_resolution,
             baseline_wallet_resolution_raw_sha256:$baseline_resolution_raw,
             candidate_locked_resolution_txids_sha256:$locked_resolution,
             candidate_locked_resolution_raw_sha256:$locked_resolution_raw,
             candidate_final_recovery_sha256:$final_recovery,
             candidate_final_goldrush_state_sha256:$final_goldrush,
             candidate_final_payout_address_sha256:$final_payout,
             candidate_configured_payout_transition_valid:true,
             baseline_quantum_sha256:$quantum_before,
             candidate_final_quantum_sha256:$quantum_after,
             baseline_quantum_labels_sha256:$quantum_labels_before,
             candidate_final_quantum_labels_sha256:$quantum_labels_after,
             candidate_quantum_inventory_transition_valid:true,
             candidate_final_resolution_txids_sha256:$final_resolution,
             candidate_final_resolution_raw_sha256:$final_resolution_raw,
             candidate_resolution_membership_baseline_bound:true,
             legacy_baseline_wallet_txids_preserved:true,
             no_new_fee_bearing_recovery_wallet_transaction:true,
             wallet_delta_sha256:$delta,wallet_delta_fully_classified:true,
             wallet_delta_raw_sha256:$delta_raw,
             chain:$chain[0],chain_after:$chain_after[0],network:$network[0],
             wallet:$wallet[0],staking:$staking[0],pow:$pow[0],recovery:$recovery[0],
             goldrush_state:$goldrush[0],mempool_verbose:$mempool[0],
             loaded_wallets:$wallets[0]}
        ' >"${EVIDENCE}/phase-b-final-envelope.json" || return 1
        return 0
    done
    return 1
}

collect_phase_b_progress()
{
    local sample=1 deadline row candidate_rows rows='[]' series tip_changes=0
    local chain chain_after recovery wallet staking pow network mempool mode observed
    local goldrush_state
    mode=active
    deadline=$((SECONDS + 2700))
    while (( SECONDS < deadline && tip_changes < 1 )); do
        while (( SECONDS < deadline )); do
            chain=$(rpc getblockchaininfo) || return 1
            goldrush_state=$(rpc getgoldrushstate | jq -ceS \
              '{bestblock,height,qqp4_activation_disabled,qqp4_activation_height,
                qqp4_active,qqp4_active_next_block}') || return 1
            recovery=$(rpc getpowclaimrecoveryinfo true) || return 1
            wallet=$(rpc getwalletinfo) || return 1
            staking=$(rpc getstakinginfo) || return 1
            pow=$(rpc getpowmininginfo) || return 1
            network=$(rpc getnetworkinfo) || return 1
            mempool=$(rpc getrawmempool true) || return 1
            chain_after=$(rpc getblockchaininfo) || return 1
            observed=$(date +%s) || return 1
            if jq -e '.initialblockdownload == false and .blocks == .headers' \
                   <<<"$chain" >/dev/null &&
               jq -e -n --argjson before "$chain" --argjson after "$chain_after" '
                 $before.bestblockhash==$after.bestblockhash and
                 $before.chainwork==$after.chainwork and $before.blocks==$after.blocks and
                 $before.headers==$after.headers
               ' >/dev/null &&
               hotfix_goldrush_state_json_is_valid "$goldrush_state" \
                 "$(jq -er '.bestblockhash' <<<"$chain")" \
                 "$(jq -er '.blocks' <<<"$chain")" &&
               jq -e --arg tip "$(jq -er '.bestblockhash' <<<"$chain")" '
                 .database_outcome_ambiguous == false and .chain_ready == true and
                 .wallet_tip_matches == true and .active_tip == $tip and
                 .wallet_processed_tip == $tip and .policy_authoritative == true and
                 .policy.automatic_authorized == false
               ' <<<"$recovery" >/dev/null &&
               jq -e --arg tip "$(jq -er '.bestblockhash' <<<"$chain")" '
                 .claim_inventory_wallet_tip_matches == true and .claim_inventory_tip == $tip
               ' <<<"$pow" >/dev/null &&
               jq -e '.scanning == false and .unlocked_staking_only == false and
                 .unlocked_until > now' <<<"$wallet" >/dev/null &&
               jq -e '.networkactive == true and .connections_out >= 3' \
                 <<<"$network" >/dev/null &&
               jq -e '.autostart_staking==true and
                 .autostart_staking_source=="autostartstaking"' <<<"$staking" >/dev/null &&
               jq -e '.autostart==true and .enabled==true and .threads==1 and
                 .cpu_percent==1' <<<"$pow" >/dev/null &&
               hotfix_phase_b_staking_json_is_active "$staking" &&
               hotfix_candidate_pow_json_is_valid "$pow" "$mode" &&
               hotfix_pow_observation_json_is_valid "$pow" "$recovery" "$mempool" \
                 "$(jq -er '.bestblockhash' <<<"$chain")" \
                 "$(jq -er '.blocks' <<<"$chain")" "$observed" \
                 "$goldrush_state"; then
                row=$(jq -cn --argjson sample "$sample" --argjson observed "$observed" \
                    --argjson chain "$chain" --argjson recovery "$recovery" \
                    --argjson wallet "$wallet" --argjson staking "$staking" \
                    --argjson pow "$pow" --argjson network "$network" \
                    --argjson mempool "$mempool" --argjson goldrush "$goldrush_state" '
                    {sample:$sample,observed_epoch:$observed,chain:$chain,recovery:$recovery,
                     wallet:$wallet,staking:$staking,pow:$pow,network:$network,
                     mempool_verbose:$mempool,goldrush_state:$goldrush}
                ') || return 1
                candidate_rows=$(jq -cn --argjson rows "$rows" --argjson row "$row" \
                    '$rows + [$row]') || return 1
                series=$(jq -ce '[.[] | {sample,observed_epoch,
                  tip:.chain.bestblockhash,height:.chain.blocks,work:.chain.chainwork,
                  goldrush_state,pow,recovery,mempool_verbose}]' <<<"$candidate_rows") || return 1
                if hotfix_pow_observation_series_json_is_valid "$series" 1; then
                    rows=$candidate_rows
                    tip_changes=$(jq -er '
                      [.[] | .chain.bestblockhash] as $tips |
                      [range(1;($tips|length)) |
                        select($tips[.] != $tips[.-1])] | length
                    ' <<<"$rows") || return 1
                    sample=$((sample + 1))
                    (( sample <= 64 )) || return 1
                    break
                fi
            fi
            sleep 2
        done
    done
    (( tip_changes >= 1 )) || return 1
    jq -S -n --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" --arg nonce "$promotion_nonce" \
        --argjson rows "$rows" --argjson tip_changes "$tip_changes" '
        ($rows | length) as $count |
        {schema:4,phase:"B",candidate_source_sha:$source,promotion_nonce:$nonce,
         observation_sample_count:$count,samples:$rows,tip_changes:$tip_changes,
         wallet_chain_synchronized_continuously:true,
         pos_active_continuously:true,p2p_ready_continuously:true,
         same_tip_or_submit_no_progress_transition_budget:1}
    ' >"${EVIDENCE}/phase-b-progress.json" || return 1
    hotfix_phase_b_progress_file_is_valid "${EVIDENCE}/phase-b-progress.json" \
        "$promotion_nonce" "$mode"
}

seal_evidence()
{
    rm -f -- "${EVIDENCE}/SHA256SUMS"
    (cd "$EVIDENCE" && find . -type f ! -name SHA256SUMS -print0 | sort -z |
        xargs -0 sha256sum) >"${EVIDENCE}/SHA256SUMS" || return 1
    chmod 600 "${EVIDENCE}/SHA256SUMS" && sync -f "${EVIDENCE}/SHA256SUMS"
    (cd "$EVIDENCE" && sha256sum --strict -c SHA256SUMS >/dev/null)
}

contain_preserve()
{
    local exists=false running_one=unknown running_two=unknown restart_one='null' restart_two='null'
    local restart_disabled=false stable_stopped=false marker_ok=false datasets_ok=false guard_ok=false
    local marker_mode=absent maintenance_ok=false suspended_ok=false enable_absent=false
    if docker inspect "$CONTAINER" >/dev/null 2>&1; then
        exists=true
        if docker update --restart=no "$CONTAINER" >/dev/null 2>&1; then
            restart_disabled=true
        fi
        if [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)" == true ]]; then
            rpc setpowmining false 1 1 false >/dev/null 2>&1 || true
            rpc staking false >/dev/null 2>&1 || true
            rpc walletlock >/dev/null 2>&1 || true
            rpc stop >/dev/null 2>&1 || true
        fi
        timeout -k 30 360 docker stop -t 300 "$CONTAINER" >/dev/null 2>&1 || true
        running_one=$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || printf unknown)
        restart_one=$(docker inspect "$CONTAINER" 2>/dev/null |
            jq -cS '.[0].HostConfig.RestartPolicy' || printf null)
        sleep 2
        running_two=$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || printf unknown)
        restart_two=$(docker inspect "$CONTAINER" 2>/dev/null |
            jq -cS '.[0].HostConfig.RestartPolicy' || printf null)
        if [[ "$restart_disabled" == true && "$running_one" == false && "$running_two" == false &&
           "$restart_one" == '{"MaximumRetryCount":0,"Name":"no"}' &&
           "$restart_two" == "$restart_one" ]]; then
            stable_stopped=true
        fi
    else
        restart_disabled=true
        stable_stopped=true
    fi
    if (( promotion_durable == 1 )); then
        marker_mode=durable
        if [[ -n "$durable_promotion_marker_sha" && -f "$PROMOTION_MARKER" &&
           ! -L "$PROMOTION_MARKER" &&
           "$(stat -Lc '%u:%g:%a' "$PROMOTION_MARKER" 2>/dev/null || true)" == 0:0:600 &&
           "$(sha256sum "$PROMOTION_MARKER" 2>/dev/null | awk '{print $1}')" == \
             "$durable_promotion_marker_sha" ]] &&
           hotfix_promoted_marker_file_is_valid "$PROMOTION_MARKER" "$phase_a_result_sha"; then
            marker_ok=true
        fi
    elif [[ ! -e "$PROMOTION_MARKER" && ! -L "$PROMOTION_MARKER" ]]; then
        marker_ok=true
    fi
    if [[ -n "$baseline_dataset_sha" ]] &&
       capture_live_dataset_identity "${EVIDENCE}/containment-live-datasets.json" 2>/dev/null &&
       [[ "$(sha256sum "${EVIDENCE}/containment-live-datasets.json" | awk '{print $1}')" == \
          "$baseline_dataset_sha" ]]; then
        datasets_ok=true
    fi
    if [[ ! -e "$SUSPENDED_START_MARKER" && ! -L "$SUSPENDED_START_MARKER" &&
       -f "$ENABLE_GUARD_STARTS" && ! -L "$ENABLE_GUARD_STARTS" ]]; then
        suspend_guard_authority >/dev/null 2>&1 || true
    fi
    if [[ ! -e "$MAINTENANCE_MARKER" && ! -L "$MAINTENANCE_MARKER" ]]; then
        publish_maintenance >/dev/null 2>&1 || true
    fi
    if [[ -f "$SUSPENDED_START_MARKER" && ! -L "$SUSPENDED_START_MARKER" &&
       ! -s "$SUSPENDED_START_MARKER" &&
       "$(stat -Lc '%u:%g:%a' "$SUSPENDED_START_MARKER" 2>/dev/null || true)" == 0:0:600 ]]; then
        suspended_ok=true
    fi
    [[ ! -e "$ENABLE_GUARD_STARTS" && ! -L "$ENABLE_GUARD_STARTS" ]] && enable_absent=true
    if [[ -f "$MAINTENANCE_MARKER" && ! -L "$MAINTENANCE_MARKER" &&
       "$(stat -Lc '%u:%g:%a' "$MAINTENANCE_MARKER" 2>/dev/null || true)" == 0:0:600 ]] &&
       jq -e --arg run "$phase_a_run_dir" --arg nonce "$phase_a_guard_nonce" '
         . == {schema:1,transaction:"v30.1.4-node27-canary",state:"active",
               run_nonce:$nonce,run_dir:$run}
       ' "$MAINTENANCE_MARKER" >/dev/null 2>&1; then
        maintenance_ok=true
    fi
    [[ "$suspended_ok" == true && "$enable_absent" == true &&
       "$maintenance_ok" == true ]] && guard_ok=true
    if [[ "$stable_stopped" == true && "$marker_ok" == true && "$datasets_ok" == true &&
       "$guard_ok" == true ]]; then
        containment_complete=1
    fi
    jq -S -n --arg utc "$(date -u +%FT%TZ)" --argjson exists "$exists" \
        --arg running_one "$running_one" --arg running_two "$running_two" \
        --argjson restart_one "$restart_one" --argjson restart_two "$restart_two" \
        --arg marker_mode "$marker_mode" --argjson restart_disabled "$restart_disabled" \
        --argjson stable "$stable_stopped" --argjson marker "$marker_ok" \
        --argjson datasets "$datasets_ok" --argjson guard "$guard_ok" \
        --argjson suspended "$suspended_ok" --argjson enable_absent "$enable_absent" \
        --argjson maintenance "$maintenance_ok" --argjson contained "$containment_complete" '
        {schema:2,contained:($contained==1),container_exists:$exists,
         restart_policy_set_to_no:$restart_disabled,restart_policy_first:$restart_one,
         restart_policy_second:$restart_two,container_running_first:$running_one,
         container_running_second:$running_two,stable_stopped:$stable,
         datasets_preserved:$datasets,promotion_marker_mode:$marker_mode,
         promotion_marker_authority_exact:$marker,
         suspended_start_marker_exact:$suspended,enable_guard_starts_absent:$enable_absent,
         maintenance_authority_exact:$maintenance,
         automatic_start_authority_remains_suspended:$guard,timestamp:$utc}
    ' >"${EVIDENCE}/CONTAINED.json" 2>/dev/null || true
    seal_evidence >/dev/null 2>&1 || true
    (( containment_complete == 1 ))
}

on_exit()
{
    local rc=$?
    trap - EXIT ERR INT TERM
    if [[ "$result" != passed ]]; then
        if (( mutation_started == 1 || promotion_durable == 1 )); then
            if contain_preserve; then
                printf 'Phase B contained: restart disabled, container stably stopped, exact authorities preserved. Evidence: %s\n' \
                    "$EVIDENCE" >&2
            else
                printf 'URGENT: automatic containment proof is incomplete; preserve all state for manual recovery.\n' >&2
            fi
        fi
        exit 1
    fi
    exit "$rc"
}

main()
{
    local command ops_dataset dataset
    local manifest_sha marker_sha invocation_sha dataset_sha baseline_inspect
    local storage_recheck_sha created_inspect created_mounts_sha created_network_sha
    local created_restart_policy final_container_sha final_envelope_sha wallet_delta_sha
    local wallet_delta_raw_sha result_tmp result_expected_sha result_actual_sha
    local cutover_before cutover_armed cutover_stop_one cutover_stop_two cutover_sha
    local promotion_dataset promotion_fstype
    trap on_exit EXIT ERR INT TERM
    require_inputs || fail 'exact Phase-A hash-bound confirmation or inputs are absent'
    verify_package_integrity || fail 'package integrity seal failed'
    [[ "$(id -u)" == 0 ]] || fail 'must run as root'
    for command in docker jq sha256sum timeout flock findmnt zfs zpool install stat grep sort awk wc \
        mktemp realpath mv chmod chown sync date seq sleep find xargs rm tr tar od bash ln ps; do
        command -v "$command" >/dev/null || fail "required command unavailable: $command"
    done
    verify_phase_a_authority || fail 'Phase-A final evidence/hash is invalid'
    phase_a_storage_artifacts_absent || fail 'Phase-A storage artifacts are not all absent'
    [[ -d "$PROMOTION_ROOT" && ! -L "$PROMOTION_ROOT" &&
       "$(stat -Lc '%u:%g:%a' "$PROMOTION_ROOT")" == 0:0:700 ]] ||
        fail 'external promotion authority root is absent or unsafe'
    promotion_dataset=$(findmnt -n -o SOURCE -T "$PROMOTION_ROOT") ||
        fail 'promotion authority dataset is unknown'
    promotion_fstype=$(findmnt -n -o FSTYPE -T "$PROMOTION_ROOT") ||
        fail 'promotion authority filesystem is unknown'
    [[ "$promotion_fstype" == zfs ]] ||
        fail 'promotion authority root is not on the required hard-link-capable ZFS filesystem'
    for dataset in "$EXPECTED_DATADIR_DATASET" "$EXPECTED_BLOCKS_DATASET" \
        "$EXPECTED_INDEXES_DATASET" "$EXPECTED_RAW_DATASET"; do
        [[ "$promotion_dataset" != "$dataset" && "$promotion_dataset" != "$dataset/"* ]] ||
            fail 'promotion authority root is inside a live/rewind dataset'
    done
    [[ ! -e "$PROMOTION_MARKER" && ! -L "$PROMOTION_MARKER" ]] ||
        fail 'promotion marker already exists; replay is refused'
    [[ ! -e "$OPS" && ! -L "$OPS" ]] || fail 'operations path already exists'
    install -d -m 700 -o root -g root "$OPS" "$EVIDENCE"
    ops_dataset=$(findmnt -n -o SOURCE -T "$OPS") || fail 'cannot identify evidence dataset'
    for dataset in "$EXPECTED_DATADIR_DATASET" "$EXPECTED_BLOCKS_DATASET" \
        "$EXPECTED_INDEXES_DATASET" "$EXPECTED_RAW_DATASET"; do
        [[ "$ops_dataset" != "$dataset" && "$ops_dataset" != "$dataset/"* ]] ||
            fail 'promotion evidence is inside a live dataset'
    done
    : >"$RPC_METHODS_LOG"

    exec 5>/run/blackcoin-endpoint-guard.lock
    flock -w 1800 5 || fail 'endpoint guard did not drain'
    exec 9>/var/run/blackcoin-node-cutover.lock
    flock -w 1800 9 || fail 'node cutover lock did not drain'
    exec 8>/run/blackcoin-pow-quarantine-cycle.lock
    flock -w 1800 8 || fail 'PoW cycle lock did not drain'
    exec 7>/var/run/blackcoin-wallet-runtime-guard.lock
    flock -w 1800 7 || fail 'wallet runtime lock did not drain'
    copy_phase_a_authority_locked || fail 'Phase-A authority changed or could not be copied under locks'
    verify_live_guards_from_phase_a || fail 'deployed guard bytes changed after Phase A'
    [[ "$(sha256sum "$COMPOSE" | awk '{print $1}')" == "$EXPECTED_COMPOSE_SHA256" ]] ||
        fail 'baseline Compose identity changed'
    [[ "$(docker compose -f "$COMPOSE" config --format json | jq -er '.services.node27.image')" == \
       "$IMMUTABLE_V3014_IMAGE_REF" ]] || fail 'effective Compose baseline is not immutable v30.1.4'
    [[ "$(docker image inspect -f '{{.Id}}' "$CANDIDATE_IMAGE")" == "$CANDIDATE_IMAGE_ID" ]] ||
        fail 'candidate image is not the sealed local image'
    docker image inspect "$CANDIDATE_IMAGE" | jq -e --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" \
        '.[0].Config.Labels["org.blackcoin.source.commit"] == $source and
         .[0].Config.Labels["org.blackcoin.release.qualification"] == "canary-only-not-release"' \
        >/dev/null || fail 'candidate labels do not bind source/canary classification'
    [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER")" == true &&
       "$(docker inspect -f '{{.Image}}' "$CONTAINER")" == "$IMMUTABLE_V3014_IMAGE_ID" &&
       "$(docker inspect -f '{{.Config.Image}}' "$CONTAINER")" == "$IMMUTABLE_V3014_IMAGE_REF" ]] ||
        fail 'baseline node27 is not the running immutable v30.1.4 identity'
    [[ "$(findmnt -n -o SOURCE -T "$HOST_DATADIR")" == "$EXPECTED_DATADIR_DATASET" &&
       "$(findmnt -n -o SOURCE -T "$HOST_DATADIR/blocks")" == "$EXPECTED_BLOCKS_DATASET" &&
       "$(findmnt -n -o SOURCE -T "$HOST_DATADIR/indexes")" == "$EXPECTED_INDEXES_DATASET" &&
       "$(findmnt -n -o SOURCE -T "$HOST_RAW")" == "$EXPECTED_RAW_DATASET" ]] ||
        fail 'live dataset identity changed'
    verify_unlock_helper || fail 'unlock helper no longer matches audited Phase-A bytes'
    [[ -f "$HOST_DATADIR/blackcoin.conf" && ! -L "$HOST_DATADIR/blackcoin.conf" ]] ||
        fail 'blackcoin.conf is not a regular file'
    baseline_inspect=$(mktemp "${OPS}/.baseline-inspect.XXXXXX") || fail 'inspect staging failed'
    docker inspect "$CONTAINER" >"$baseline_inspect" || fail 'baseline inspect failed'
    baseline_config_sha=$(sha256sum "$HOST_DATADIR/blackcoin.conf" | awk '{print $1}')
    baseline_mounts_sha=$(inspect_mounts_sha "$baseline_inspect") || fail 'mount identity failed'
    baseline_network_sha=$(inspect_network_sha "$baseline_inspect") || fail 'network identity failed'
    baseline_restart_policy_json=$(inspect_restart_policy_json "$baseline_inspect") ||
        fail 'baseline restart policy capture failed'
    jq -S --argjson restart "$baseline_restart_policy_json" \
        '.[0] | {schema:1,container_id:.Id,image_id:.Image,image_ref:.Config.Image,
         running:.State.Running,restart_policy:$restart}' "$baseline_inspect" \
        >"${EVIDENCE}/baseline-docker-runtime.json" || fail 'baseline Docker evidence failed'
    rm -f -- "$baseline_inspect"
    jq -e --arg config "$baseline_config_sha" --arg mounts "$baseline_mounts_sha" \
        --arg network "$baseline_network_sha" --argjson restart "$baseline_restart_policy_json" '
      .schema==1 and .blackcoin_conf_sha256==$config and .mounts_sha256==$mounts and
      .network_sha256==$network and .restart_policy==$restart
    ' "${EVIDENCE}/phase-a-baseline-runtime-identity.json" >/dev/null ||
        fail 'current immutable baseline runtime identity differs from Phase A'
    capture_live_dataset_identity "${EVIDENCE}/baseline-live-datasets.json" ||
        fail 'baseline dataset identity capture failed'
    baseline_dataset_sha=$(sha256sum "${EVIDENCE}/baseline-live-datasets.json" | awk '{print $1}')
    record_tooling_identity || fail 'Phase-B tooling/package identity capture failed'
    capture_baseline_precondition || fail 'immutable baseline health/wallet/recovery gate failed'
    baseline_wallet_name=$(jq -er '.walletname | select(type=="string")' \
        "${EVIDENCE}/baseline-wallet.json") || fail 'baseline wallet identity missing'
    jq -e '.enabled|type=="boolean"' "${EVIDENCE}/baseline-pow.json" >/dev/null ||
        fail 'baseline PoW enabled field is not boolean'
    baseline_quantum_count=$(quantum_inventory_count "${EVIDENCE}/baseline-quantum.json")
    record_storage_absence "${EVIDENCE}/storage-absence-before-marker.json" before-marker ||
        fail 'storage absence immediately before promotion marker is not proven'

    mutation_started=1
    suspend_guard_authority || fail 'could not suspend old automatic-start authority'
    publish_maintenance || fail 'could not publish promotion maintenance authority'
    write_promotion_marker || fail 'durable PROMOTED_NO_REWIND transition failed'
    install -m 600 -o root -g root "$PROMOTION_MARKER" "${EVIDENCE}/PROMOTED_NO_REWIND.json"
    record_storage_absence "${EVIDENCE}/storage-absence-after-marker.json" after-marker ||
        fail 'storage artifacts appeared after durable marker'

    cutover_before=$(mktemp "${OPS}/.baseline-cutover-before.XXXXXX") ||
        fail 'baseline cutover inspection staging failed'
    cutover_armed=$(mktemp "${OPS}/.baseline-cutover-armed.XXXXXX") ||
        fail 'baseline cutover authority staging failed'
    cutover_stop_one=$(mktemp "${OPS}/.baseline-cutover-stop-one.XXXXXX") ||
        fail 'baseline stopped inspection staging failed'
    cutover_stop_two=$(mktemp "${OPS}/.baseline-cutover-stop-two.XXXXXX") ||
        fail 'baseline stable-stop inspection staging failed'
    docker inspect "$CONTAINER" >"$cutover_before" || fail 'baseline cutover inspect failed'
    docker update --restart=no "$CONTAINER" >/dev/null ||
        fail 'old-Core automatic restart authority could not be disabled'
    docker inspect "$CONTAINER" >"$cutover_armed" ||
        fail 'disabled restart authority could not be inspected'
    jq -e --arg id "$IMMUTABLE_V3014_IMAGE_ID" --arg ref "$IMMUTABLE_V3014_IMAGE_REF" \
        --slurpfile before "$cutover_before" --slurpfile armed "$cutover_armed" '
      ($before[0][0]) as $b | ($armed[0][0]) as $a |
      $b.Id==$a.Id and $b.Image==$id and $a.Image==$id and
      $b.Config.Image==$ref and $a.Config.Image==$ref and
      $b.State.Running==true and $a.State.Running==true and
      $b.State.StartedAt==$a.State.StartedAt and $b.RestartCount==$a.RestartCount and
      $a.HostConfig.RestartPolicy=={Name:"no",MaximumRetryCount:0}
    ' >/dev/null || fail 'old-Core restart authority was not synchronously disabled'
    rpc staking false >"${EVIDENCE}/baseline-staking-stop.json" || fail 'baseline PoS stop failed'
    rpc setpowmining false 1 1 false >"${EVIDENCE}/baseline-pow-stop.json" || fail 'baseline PoW stop failed'
    rpc walletlock >"${EVIDENCE}/baseline-wallet-lock.json" || fail 'baseline wallet lock failed'
    rpc stop >/dev/null || fail 'baseline clean stop failed'
    for _ in $(seq 1 180); do
        [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER")" == false ]] && break
        sleep 1
    done
    [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER")" == false ]] ||
        fail 'baseline did not stop'
    docker inspect "$CONTAINER" >"$cutover_stop_one" || fail 'stopped baseline inspect failed'
    sleep 2
    docker inspect "$CONTAINER" >"$cutover_stop_two" || fail 'stable stopped baseline inspect failed'
    jq -e --arg id "$IMMUTABLE_V3014_IMAGE_ID" --arg ref "$IMMUTABLE_V3014_IMAGE_REF" \
        --slurpfile before "$cutover_before" --slurpfile armed "$cutover_armed" \
        --slurpfile one "$cutover_stop_one" --slurpfile two "$cutover_stop_two" '
      ($before[0][0]) as $b | ($armed[0][0]) as $a |
      ($one[0][0]) as $x | ($two[0][0]) as $y |
      $b.Id==$a.Id and $a.Id==$x.Id and $x.Id==$y.Id and
      $x.Image==$id and $y.Image==$id and $x.Config.Image==$ref and $y.Config.Image==$ref and
      $x.State.Running==false and $y.State.Running==false and
      $x.State.ExitCode==0 and $y.State.ExitCode==0 and
      ($x.State.FinishedAt|type)=="string" and ($x.State.FinishedAt|length)>0 and
      $y.State.FinishedAt==$x.State.FinishedAt and
      $x.State.StartedAt==$y.State.StartedAt and $x.RestartCount==$y.RestartCount and
      $x.HostConfig.RestartPolicy=={Name:"no",MaximumRetryCount:0} and
      $y.HostConfig.RestartPolicy=={Name:"no",MaximumRetryCount:0}
    ' >/dev/null || fail 'old Core was not stably stopped with restart authority disabled'
    jq -S -n --slurpfile before "$cutover_before" --slurpfile armed "$cutover_armed" \
        --slurpfile one "$cutover_stop_one" --slurpfile two "$cutover_stop_two" '
      ($before[0][0]) as $b | ($armed[0][0]) as $a |
      ($one[0][0]) as $x | ($two[0][0]) as $y |
      {schema:1,container_id:$b.Id,image_id:$b.Image,image_ref:$b.Config.Image,
       original_restart_policy:$b.HostConfig.RestartPolicy,
       armed_restart_policy:$a.HostConfig.RestartPolicy,
       stopped_restart_policy_first:$x.HostConfig.RestartPolicy,
       stopped_restart_policy_second:$y.HostConfig.RestartPolicy,
       started_at_before:$b.State.StartedAt,started_at_armed:$a.State.StartedAt,
       stopped_started_at_first:$x.State.StartedAt,stopped_started_at_second:$y.State.StartedAt,
       stopped_finished_at_first:$x.State.FinishedAt,
       stopped_finished_at_second:$y.State.FinishedAt,
       stopped_exit_code_first:$x.State.ExitCode,stopped_exit_code_second:$y.State.ExitCode,
       restart_count_before:$b.RestartCount,restart_count_armed:$a.RestartCount,
       restart_count_stopped_first:$x.RestartCount,restart_count_stopped_second:$y.RestartCount,
       restart_authority_disabled_before_rpc_stop:true,clean_rpc_stop_completed:true,
       stable_stopped_samples:2,old_core_restart_observed:false}
    ' >"${EVIDENCE}/baseline-cutover-stop.json" || fail 'baseline cutover receipt failed'
    hotfix_phase_b_cutover_stop_file_is_valid "${EVIDENCE}/baseline-cutover-stop.json" ||
        fail 'baseline cutover receipt is internally inconsistent'
    rm -f -- "$cutover_before" "$cutover_armed" "$cutover_stop_one" "$cutover_stop_two"
    cutover_sha=$(sha256sum "${EVIDENCE}/baseline-cutover-stop.json" | awk '{print $1}') ||
        fail 'baseline cutover receipt hash failed'

    write_override || fail 'could not write sealed promotion override'
    docker compose -f "$COMPOSE" -f "$OVERRIDE" create --force-recreate --pull never "$SERVICE" ||
        fail 'candidate create failed'
    created_inspect=$(mktemp "${OPS}/.created-inspect.XXXXXX") || fail 'create inspect staging failed'
    docker inspect "$CONTAINER" >"$created_inspect" || fail 'created container inspect failed'
    created_mounts_sha=$(inspect_mounts_sha "$created_inspect") || fail 'created mount hash failed'
    created_network_sha=$(inspect_network_sha "$created_inspect") || fail 'created network hash failed'
    created_restart_policy=$(inspect_restart_policy_json "$created_inspect") ||
        fail 'created restart policy capture failed'
    [[ "$created_mounts_sha" == "$baseline_mounts_sha" &&
       "$created_network_sha" == "$baseline_network_sha" &&
       "$created_restart_policy" == "$baseline_restart_policy_json" ]] ||
        fail 'created candidate mount/network/restart configuration differs from baseline'
    jq -S --arg mounts "$created_mounts_sha" --arg network "$created_network_sha" \
      --argjson restart "$created_restart_policy" \
      '.[0] | {image_id:.Image,running:.State.Running,
      user:.Config.User,working_dir:.Config.WorkingDir,entrypoint:.Config.Entrypoint,
      cmd:.Config.Cmd,path:.Path,args:.Args,mounts:.Mounts,
      network_mode:.HostConfig.NetworkMode,mounts_sha256:$mounts,network_sha256:$network,
      restart_policy:$restart}' \
      "$created_inspect" \
      >"${EVIDENCE}/candidate-created-stopped.json"
    rm -f -- "$created_inspect"
    jq -e --arg id "$CANDIDATE_IMAGE_ID" '.image_id==$id and .running==false and
      .user=="blackcoin" and .working_dir=="/home/blackcoin"' \
      "${EVIDENCE}/candidate-created-stopped.json" >/dev/null || fail 'stopped inspection failed'
    record_storage_absence "${EVIDENCE}/storage-absence-before-launch.json" before-launch ||
        fail 'storage artifacts appeared before start'
    storage_recheck_sha=$(sha256sum "${EVIDENCE}/storage-absence-before-launch.json" |
        awk '{print $1}')
    docker start "$CONTAINER" >/dev/null || fail 'candidate start failed'
    wait_rpc || fail 'candidate RPC failed to start'
    capture_invocation "${EVIDENCE}/candidate-created-stopped.json" \
        "${EVIDENCE}/candidate-invocation.json" || fail 'candidate invocation proof failed'
    wait_chain_wallet_sync_locked || fail 'candidate chain/wallet did not synchronize while locked'
    jq -S '[.recovery.component_details[]?.resolution_txids[]?] | unique | sort' \
        "${EVIDENCE}/candidate-chain-wallet-synchronized.json" \
        >"${EVIDENCE}/candidate-locked-resolution-txids.json" ||
        fail 'candidate-locked resolution identity capture failed'
    jq -e -n --slurpfile baseline "${EVIDENCE}/baseline-wallet-resolution-txids.json" \
        --slurpfile current "${EVIDENCE}/candidate-locked-resolution-txids.json" '
      all($current[0][]; . as $txid | ($baseline[0] | index($txid)) != null)
    ' >/dev/null || fail 'candidate-locked recovery exposed a nonbaseline resolution txid'
    capture_resolution_raw_identities \
        "${EVIDENCE}/candidate-locked-resolution-txids.json" \
        "${EVIDENCE}/candidate-locked-resolution-raw.json" ||
        fail 'candidate-locked resolution raw identity capture failed'
    jq -e -n --slurpfile baseline "${EVIDENCE}/baseline-wallet-resolution-raw.json" \
        --slurpfile current "${EVIDENCE}/candidate-locked-resolution-raw.json" '
      all($current[0][]; . as $row |
        ([$baseline[0][] | select(.txid==$row.txid and .hex==$row.hex)] | length)==1)
    ' >/dev/null || fail 'candidate-locked resolution raw identity differs from baseline'
    candidate_locked_resolution_sha=$(sha256sum \
        "${EVIDENCE}/candidate-locked-resolution-txids.json" | awk '{print $1}') ||
        fail 'candidate-locked resolution identity hash failed'
    run_unlock_helper || fail 'normal wallet unlock failed'
    rpc getwalletinfo | jq -e '.unlocked_until > now and .unlocked_staking_only == false' \
        >/dev/null || fail 'wallet is not normally unlocked'
    collect_phase_b_progress || fail 'three-tip Phase-B PoS/P2P/typed-gate proof failed'
    capture_live_dataset_identity "${EVIDENCE}/candidate-final-live-datasets.json" ||
        fail 'final dataset identity capture failed'
    [[ "$(sha256sum "${EVIDENCE}/candidate-final-live-datasets.json" | awk '{print $1}')" == \
       "$baseline_dataset_sha" ]] || fail 'live dataset identities changed during promotion'
    capture_final_container_identity "${EVIDENCE}/candidate-final-container.json" ||
        fail 'final candidate Docker identity/restart proof failed'
    capture_final_envelope ||
        fail 'coherent final chain/wallet/recovery/typed-gate/wallet-delta proof failed'
    [[ -f "$PROMOTION_MARKER" && ! -L "$PROMOTION_MARKER" &&
       "$(stat -Lc '%u:%g:%a' "$PROMOTION_MARKER")" == 0:0:600 ]] ||
        fail 'durable no-rewind marker identity changed'
    hotfix_promoted_marker_file_is_valid "$PROMOTION_MARKER" "$phase_a_result_sha" ||
        fail 'durable no-rewind marker content changed'
    [[ "$(sha256sum "$PROMOTION_MARKER" | awk '{print $1}')" == \
       "$durable_promotion_marker_sha" &&
       "$(sha256sum "${EVIDENCE}/PROMOTED_NO_REWIND.json" | awk '{print $1}')" == \
         "$durable_promotion_marker_sha" ]] || fail 'durable marker byte identity changed'
    [[ "$(sha256sum "${BASH_SOURCE[0]}" | awk '{print $1}')" == "$phase_b_script_sha" &&
       "$(sha256sum "$PACKAGE_ROOT/verify-evidence.sh" | awk '{print $1}')" == \
         "$phase_b_verifier_sha" &&
       "$(sha256sum "$PACKAGE_ROOT/lib/typed_contract.sh" | awk '{print $1}')" == \
         "$phase_b_contract_sha" &&
       "$(sha256sum "$PACKAGE_ROOT/SHA256SUMS" | awk '{print $1}')" == "$package_seal_sha" ]] ||
        fail 'Phase-B tooling/package bytes changed after irreversible marker'

    marker_sha=$(sha256sum "$PROMOTION_MARKER" | awk '{print $1}')
    invocation_sha=$(sha256sum "${EVIDENCE}/candidate-invocation.json" | awk '{print $1}')
    dataset_sha=$(sha256sum "${EVIDENCE}/candidate-final-live-datasets.json" | awk '{print $1}')
    final_container_sha=$(sha256sum "${EVIDENCE}/candidate-final-container.json" | awk '{print $1}')
    final_envelope_sha=$(sha256sum "${EVIDENCE}/phase-b-final-envelope.json" | awk '{print $1}')
    wallet_delta_sha=$(sha256sum "${EVIDENCE}/phase-b-wallet-delta.json" | awk '{print $1}')
    wallet_delta_raw_sha=$(sha256sum "${EVIDENCE}/phase-b-wallet-delta-raw.json" | awk '{print $1}')
    if grep -Eq '^(staking:true|setpowmining:true:)' "$RPC_METHODS_LOG"; then
        fail 'candidate PoS/PoW was enabled by a repair RPC instead of Core-native intent'
    fi
    (cd "$EVIDENCE" && find . -type f ! -name RESULT.json ! -name SHA256SUMS \
        ! -name PRE_RESULT_SHA256SUMS -print0 | sort -z | xargs -0 sha256sum) \
        >"${EVIDENCE}/PRE_RESULT_SHA256SUMS" || fail 'pre-result manifest failed'
    manifest_sha=$(sha256sum "${EVIDENCE}/PRE_RESULT_SHA256SUMS" | awk '{print $1}')
    [[ ! -e "${EVIDENCE}/RESULT.json" && ! -L "${EVIDENCE}/RESULT.json" ]] ||
        fail 'Phase-B RESULT target already exists'
    result_tmp=$(mktemp "${EVIDENCE}/.RESULT.json.XXXXXX") ||
        fail 'Phase-B RESULT staging failed'
    if ! jq -S -n --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" --arg result_sha "$phase_a_result_sha" \
        --arg marker "$marker_sha" --arg invocation "$invocation_sha" \
        --arg datasets "$dataset_sha" --arg manifest "$manifest_sha" \
        --arg absence "$storage_recheck_sha" \
        --arg progress "$(sha256sum "${EVIDENCE}/phase-b-progress.json" | awk '{print $1}')" \
        --arg final_container "$final_container_sha" --arg final_envelope "$final_envelope_sha" \
        --arg wallet_delta "$wallet_delta_sha" --arg wallet_delta_raw "$wallet_delta_raw_sha" \
        --arg tooling "$CANDIDATE_TOOLING_COMMIT" \
        --arg tooling_identity "$phase_b_tooling_identity_sha" --arg package "$package_seal_sha" \
        --arg script "$phase_b_script_sha" --arg verifier "$phase_b_verifier_sha" \
        --arg contract "$phase_b_contract_sha" \
        --arg baseline "$(sha256sum "${EVIDENCE}/baseline-precondition.json" | awk '{print $1}')" \
        --arg cutover "$cutover_sha" \
        --arg locked_sync "$(sha256sum \
          "${EVIDENCE}/candidate-chain-wallet-synchronized.json" | awk '{print $1}')" \
        --arg locked_resolution "$(sha256sum \
          "${EVIDENCE}/candidate-locked-resolution-txids.json" | awk '{print $1}')" \
        --arg final_recovery "$(sha256sum \
          "${EVIDENCE}/candidate-final-recovery.json" | awk '{print $1}')" \
        --arg final_resolution "$(sha256sum \
          "${EVIDENCE}/candidate-final-resolution-txids.json" | awk '{print $1}')" '
        {schema:4,phase:"B",node:27,result:"passed",candidate_source_sha:$source,
         phase_a_result_sha256:$result_sha,promoted_no_rewind_marker_verified:true,
         snapshots_absent_before_launch:true,datasets_preserved:true,candidate_running:true,
         wallet_chain_synchronized_before_unlock:true,normal_unlock_completed:true,
         core_native_pos_intent_configured:true,core_native_pow_intent_configured:true,
         locked_pos_zero_work_observed:true,locked_pow_zero_work_observed:true,
         normal_unlock_only_resume_observed:true,repair_enable_rpcs_used:false,
         pos_active:true,p2p_ready:true,
         typed_gate_safe:true,configured_payout_transition_valid:true,
         quantum_keys_unchanged:true,
         automatic_recovery_unauthorized_continuously:true,
         candidate_resolution_membership_baseline_bound:true,
         no_new_fee_bearing_recovery_wallet_transaction:true,
         wallet_delta_fully_classified:true,only_allowed_wallet_delta_classes_added:true,
         baseline_health_gate_passed:true,final_container_identity_stable:true,
         failure_policy:"contain-stop-preserve",old_core_autostarted:false,
         data_rewind_performed:false,marker_sha256:$marker,invocation_sha256:$invocation,
         live_dataset_identity_sha256:$datasets,storage_absence_recheck_sha256:$absence,
         phase_b_progress_sha256:$progress,pre_result_manifest_sha256:$manifest,
         final_container_sha256:$final_container,final_envelope_sha256:$final_envelope,
         wallet_delta_sha256:$wallet_delta,wallet_delta_raw_sha256:$wallet_delta_raw,
         baseline_precondition_sha256:$baseline,baseline_cutover_stop_sha256:$cutover,
         tooling_commit:$tooling,phase_b_tooling_identity_sha256:$tooling_identity,
         package_sha256sums_sha256:$package,phase_b_script_sha256:$script,
         verifier_sha256:$verifier,typed_contract_sha256:$contract,
         candidate_locked_sync_sha256:$locked_sync,
         candidate_locked_resolution_txids_sha256:$locked_resolution,
         candidate_final_recovery_sha256:$final_recovery,
         candidate_final_resolution_txids_sha256:$final_resolution}
    ' >"$result_tmp"; then
        rm -f -- "$result_tmp"
        fail 'Phase-B RESULT construction failed'
    fi
    if ! chmod 600 "$result_tmp" || ! chown root:root "$result_tmp" ||
       ! hotfix_phase_b_result_file_is_valid "$result_tmp" "$phase_a_result_sha" ||
       ! sync -f "$result_tmp"; then
        rm -f -- "$result_tmp"
        fail 'Phase-B staged RESULT is invalid or not durable'
    fi
    result_expected_sha=$(sha256sum "$result_tmp" | awk '{print $1}') || {
        rm -f -- "$result_tmp"
        fail 'Phase-B staged RESULT hash failed'
    }
    if [[ -e "${EVIDENCE}/RESULT.json" || -L "${EVIDENCE}/RESULT.json" ]] ||
       ! ln -- "$result_tmp" "${EVIDENCE}/RESULT.json"; then
        rm -f -- "$result_tmp"
        fail 'Phase-B RESULT atomic publication failed'
    fi
    rm -f -- "$result_tmp"
    if ! sync -f "${EVIDENCE}/RESULT.json" || ! sync -f "$EVIDENCE"; then
        fail 'Phase-B RESULT publication was not durable'
    fi
    [[ -f "${EVIDENCE}/RESULT.json" && ! -L "${EVIDENCE}/RESULT.json" &&
       "$(stat -Lc '%u:%g:%a:%h' "${EVIDENCE}/RESULT.json")" == 0:0:600:1 ]] ||
        fail 'Phase-B published RESULT identity is invalid'
    result_actual_sha=$(sha256sum "${EVIDENCE}/RESULT.json" | awk '{print $1}') ||
        fail 'Phase-B published RESULT hash failed'
    [[ "$result_actual_sha" == "$result_expected_sha" ]] ||
        fail 'Phase-B published RESULT bytes changed'
    hotfix_phase_b_result_file_is_valid "${EVIDENCE}/RESULT.json" "$phase_a_result_sha" ||
        fail 'Phase-B published RESULT is invalid'
    seal_evidence || fail 'promotion evidence seal failed'
    "$PACKAGE_ROOT/verify-evidence.sh" phase-b-final "$EVIDENCE" ||
        fail 'promotion evidence verification failed'
    result='passed'
    printf 'Node27 Phase B promotion passed; candidate remains running and live data is preserved. Evidence: %s\n' \
        "$EVIDENCE"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
