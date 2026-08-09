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
readonly NORMAL_UNLOCK_HELPER_SHA='acf28446e842fd0fa92b06c2ebc182e9da38fcde7bac06dd920d50a33e4e3dd1'
readonly EXPECTED_DATADIR_DATASET='pulsar/Blackcoin_Blocks/node-data/node-27'
readonly EXPECTED_BLOCKS_DATASET='pulsar/Blackcoin_Blocks/node-data/node-27/blocks'
readonly EXPECTED_INDEXES_DATASET='pulsar/Blackcoin_Blocks/node-data/node-27/indexes'
readonly EXPECTED_RAW_DATASET='pulsar/Blackcoin_Blocks/alpha-chain-raw-clones-20260715T032403Z/node-27'
readonly IMMUTABLE_CANARY_SHA='dbcc29ddd6e7098bf540d6c7c2ef185eb3cc591b8d31c8289e34f45c62091835'
readonly IMMUTABLE_CANARY_MANIFEST_SHA='39bcd09b8320e6ae191be53bc7fc064e25dcc7b3c7794c6066542f3b8bb28774'
readonly PROMOTION_ROOT='/mnt/pulsar/Blackcoin_Blocks/operations/promotion-authority'
readonly PROMOTION_MARKER="${PROMOTION_ROOT}/PROMOTED_NO_REWIND.node27.json"
readonly VPN_CONTAINER='pia-vpn-26'

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
readonly STAMP
readonly STAGE="/mnt/pulsar/Blackcoin_Blocks/operations/releases/v${HOTFIX_CANDIDATE_RELEASE_VERSION}-${HOTFIX_CANDIDATE_SOURCE_SHA}"
readonly OPS="${STAGE}/node27-canary-${STAMP}"
readonly EVIDENCE="${OPS}/evidence"
readonly OVERRIDE="${OPS}/node27-candidate.yml"
SNAP=''
HOLD=''
readonly SUSPENDED_START_MARKER="${STATE_ROOT}/ENABLE_GUARD_STARTS.hotfix-node27-${STAMP}.suspended"
readonly RPC_METHODS_LOG="${EVIDENCE}/rpc-methods.log"
readonly CANDIDATE_PROGRESS="${EVIDENCE}/phase-a-progress.json"
readonly NO_RECOVERY_SPEND="${EVIDENCE}/phase-a-claim-proof.json"
readonly REWIND_SAFE="${EVIDENCE}/REWIND_SAFE.json"
readonly BASE_CATCHUP_PROOF="${EVIDENCE}/base-catchup-proof.json"
readonly SNAPSHOT_ABSENCE_PROOF="${EVIDENCE}/snapshot-absence-proof.json"
readonly MAINTENANCE_NONCE="${OPS}/MAINTENANCE-NONCE"
readonly GUARD_STATE="${OPS}/STATE"
readonly PHASE_STATE="${OPS}/PHASE-A-STATE.json"
readonly CRASH_RECOVERY_PROCEDURE="${OPS}/CRASH-RECOVERY.json"

result='failed'
mutation_started=0
snapshot_created=0
rewind_started=0
guard_starts_suspended=0
maintenance_published=0
baseline_pow_enabled=false
baseline_recovery_fee=''
baseline_cumulative_recovery_fee=''
baseline_pending_manual=''
baseline_pending_automatic=''
baseline_recovery_metrics_json=''
baseline_recovery_metrics_sha=''
baseline_payout=''
baseline_quantum_key_count=''
baseline_config_sha=''
baseline_mounts_sha=''
baseline_network_sha=''
baseline_restart_policy_json=''
snapshot_identity_sha=''
run_nonce=''
guard_nonce=''
phase_a_package_sha=''
phase_a_script_sha=''
phase_b_script_sha=''
phase_a_verifier_sha=''
phase_a_contract_sha=''
phase_a_tooling_identity_sha=''

fail()
{
    printf 'HOTFIX_CANARY_FAIL: %s\n' "$*" >&2
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

wait_rpc()
{
    for _ in $(seq 1 180); do
        if rpc getblockchaininfo >/dev/null 2>&1; then
            return 0
        fi
        if [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)" != true ]]; then
            docker logs --tail 300 "$CONTAINER" >"${EVIDENCE}/startup-failure.log" 2>&1 || true
            return 1
        fi
        sleep 2
    done
    docker logs --tail 300 "$CONTAINER" >"${EVIDENCE}/startup-timeout.log" 2>&1 || true
    return 1
}

require_no_placeholders()
{
    local expected_artifact name value
    hotfix_candidate_identity_is_resolved ||
        fail 'candidate source/release identity is unresolved or incoherent'
    for name in \
        CANDIDATE_BUNDLE_DIR CANDIDATE_GITHUB_ARTIFACT CANDIDATE_GITHUB_RUN_ID \
        CANDIDATE_GITHUB_RUN_ATTEMPT CANDIDATE_TOOLING_COMMIT \
        CANDIDATE_WORKFLOW_DEFINITION_COMMIT CANDIDATE_BUNDLE_MANIFEST \
        CANDIDATE_BUNDLE_MANIFEST_SHA256 CANDIDATE_BUNDLE_SHA256SUMS \
        CANDIDATE_BUNDLE_SHA256SUMS_SHA256 CANDIDATE_SOURCE_SIGNATURE \
        CANDIDATE_SOURCE_SIGNATURE_SHA256 CANDIDATE_CORE_CI CANDIDATE_CORE_CI_SHA256 \
        CANDIDATE_TOOLCHAIN CANDIDATE_TOOLCHAIN_SHA256 CANDIDATE_PROVENANCE \
        CANDIDATE_BINARY_SHA256SUMS CANDIDATE_BINARY_SHA256SUMS_SHA256 \
        CANDIDATE_PROVENANCE_SHA256 CANDIDATE_OCI_IDENTITY \
        CANDIDATE_OCI_IDENTITY_SHA256 CANDIDATE_OCI_ARCHIVE \
        CANDIDATE_OCI_ARCHIVE_SHA256 CANDIDATE_IMAGE CANDIDATE_IMAGE_ID \
        CANDIDATE_IMAGE_MANIFEST_DIGEST CANDIDATE_BLACKCOIND_SHA256 \
        CANDIDATE_BLACKCOIN_CLI_SHA256 CANDIDATE_BLACKCOIN_QT_SHA256 \
        CANDIDATE_BLACKCOIN_TX_SHA256 CANDIDATE_BLACKCOIN_WALLET_SHA256 \
        CANDIDATE_BLACKCOIN_UTIL_SHA256 EXPECTED_COMPOSE_SHA256 \
        EXPECTED_RUNTIME_GUARD_SHA256 EXPECTED_ENDPOINT_GUARD_SHA256 \
        EXPECTED_POW_CYCLE_SHA256; do
        value=${!name:-}
        [[ -n "$value" && "$value" != *'__'* ]] || fail "unresolved candidate setting: $name"
    done
    [[ "${CONFIRM_HOTFIX_CANDIDATE_PHASE_A:-}" == "$HOTFIX_PHASE_A_CONFIRMATION" ]] ||
        fail 'exact operator confirmation is absent'
    [[ "$CANDIDATE_GITHUB_RUN_ID" =~ ^[1-9][0-9]*$ &&
       "$CANDIDATE_GITHUB_RUN_ATTEMPT" =~ ^[1-9][0-9]*$ ]] ||
        fail 'GitHub run identity is malformed'
    expected_artifact=$(hotfix_candidate_artifact_name "$CANDIDATE_GITHUB_RUN_ATTEMPT") ||
        fail 'GitHub artifact identity could not be derived'
    [[ "$CANDIDATE_GITHUB_ARTIFACT" == "$expected_artifact" ]] ||
        fail 'GitHub artifact name is not the exact source/run-attempt-bound candidate name'
    [[ "$CANDIDATE_IMAGE" == "$HOTFIX_CANDIDATE_IMAGE_REF" ]] ||
        fail 'candidate image reference is not the exact adapter-derived local tag'
    hotfix_valid_git_sha "$CANDIDATE_TOOLING_COMMIT" || fail 'tooling commit is malformed'
    [[ "$CANDIDATE_WORKFLOW_DEFINITION_COMMIT" == "$CANDIDATE_TOOLING_COMMIT" ]] ||
        fail 'workflow definition is not bound to the tooling commit'
    for value in \
        "$CANDIDATE_BUNDLE_MANIFEST_SHA256" "$CANDIDATE_BUNDLE_SHA256SUMS_SHA256" \
        "$CANDIDATE_SOURCE_SIGNATURE_SHA256" "$CANDIDATE_CORE_CI_SHA256" \
        "$CANDIDATE_TOOLCHAIN_SHA256" "$CANDIDATE_BINARY_SHA256SUMS_SHA256" \
        "$CANDIDATE_PROVENANCE_SHA256" \
        "$CANDIDATE_OCI_IDENTITY_SHA256" "$CANDIDATE_OCI_ARCHIVE_SHA256" \
        "$CANDIDATE_BLACKCOIND_SHA256" "$CANDIDATE_BLACKCOIN_CLI_SHA256" \
        "$CANDIDATE_BLACKCOIN_QT_SHA256" "$CANDIDATE_BLACKCOIN_TX_SHA256" \
        "$CANDIDATE_BLACKCOIN_WALLET_SHA256" "$CANDIDATE_BLACKCOIN_UTIL_SHA256" \
        "$EXPECTED_COMPOSE_SHA256" "$EXPECTED_RUNTIME_GUARD_SHA256" \
        "$EXPECTED_ENDPOINT_GUARD_SHA256" "$EXPECTED_POW_CYCLE_SHA256"; do
        hotfix_valid_sha256 "$value" || fail 'candidate SHA-256 setting is malformed'
    done
    hotfix_valid_image_id "$CANDIDATE_IMAGE_ID" || fail 'candidate image ID is malformed'
    hotfix_valid_image_id "$CANDIDATE_IMAGE_MANIFEST_DIGEST" ||
        fail 'candidate OCI manifest digest is malformed'
}

verify_live_guard_contract()
{
    local path expected
    while IFS=$'\t' read -r path expected; do
        [[ -f "$path" && ! -L "$path" && -x "$path" &&
           "$(stat -Lc '%u:%g' "$path")" == 0:0 &&
           "$(sha256sum "$path" | awk '{print $1}')" == "$expected" ]] || return 1
    done <<EOF
$RUNTIME_GUARD	$EXPECTED_RUNTIME_GUARD_SHA256
$ENDPOINT_GUARD	$EXPECTED_ENDPOINT_GUARD_SHA256
$POW_CYCLE	$EXPECTED_POW_CYCLE_SHA256
EOF
    grep -F 'v30.1.4-node27-canary)' "$RUNTIME_GUARD" >/dev/null || return 1
    grep -F 'v30.1.4-node27-canary)' "$ENDPOINT_GUARD" >/dev/null || return 1
    grep -F 'V30_1_4_ROLLOUT_MAINTENANCE.json' "$POW_CYCLE" >/dev/null || return 1
}

capture_live_guard_identity()
{
    verify_live_guard_contract || return 1
    jq -S -n --arg runtime "$EXPECTED_RUNTIME_GUARD_SHA256" \
        --arg endpoint "$EXPECTED_ENDPOINT_GUARD_SHA256" \
        --arg pow "$EXPECTED_POW_CYCLE_SHA256" \
        '{schema:1,runtime_guard_sha256:$runtime,endpoint_guard_sha256:$endpoint,
          pow_cycle_sha256:$pow,node27_canary_marker_contract_verified:true,
          maintenance_fail_closed_verified:true}' \
        >"${EVIDENCE}/guard-source-identity.json"
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

capture_phase_a_tooling_identity()
{
    local output="${EVIDENCE}/tooling-identity.json"
    verify_package_integrity || return 1
    phase_a_package_sha=$(sha256sum "$PACKAGE_ROOT/SHA256SUMS" | awk '{print $1}') || return 1
    phase_a_script_sha=$(sha256sum "${BASH_SOURCE[0]}" | awk '{print $1}') || return 1
    phase_b_script_sha=$(sha256sum \
        "$PACKAGE_ROOT/node27-v30.1.4-hotfix-candidate.promote-no-data-rewind.sh" |
        awk '{print $1}') || return 1
    phase_a_verifier_sha=$(sha256sum "$PACKAGE_ROOT/verify-evidence.sh" | awk '{print $1}') ||
        return 1
    phase_a_contract_sha=$(sha256sum "$PACKAGE_ROOT/lib/typed_contract.sh" | awk '{print $1}') ||
        return 1
    jq -S -n --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" \
        --arg tooling "$CANDIDATE_TOOLING_COMMIT" --arg package "$phase_a_package_sha" \
        --arg phase_a "$phase_a_script_sha" --arg phase_b "$phase_b_script_sha" \
        --arg verifier "$phase_a_verifier_sha" --arg contract "$phase_a_contract_sha" '
        {schema:1,candidate_source_sha:$source,tooling_commit:$tooling,
         package_sha256sums_sha256:$package,phase_a_script_sha256:$phase_a,
         phase_b_script_sha256:$phase_b,verifier_sha256:$verifier,
         typed_contract_sha256:$contract,
         exact_bytes_recorded_before_any_live_mutation:true}
    ' >"$output" || return 1
    chmod 600 "$output" && chown root:root "$output" && sync -f "$output" || return 1
    hotfix_phase_a_tooling_identity_file_is_valid "$output" "$CANDIDATE_TOOLING_COMMIT" \
        "$phase_a_package_sha" "$phase_a_script_sha" "$phase_b_script_sha" \
        "$phase_a_verifier_sha" "$phase_a_contract_sha" || return 1
    phase_a_tooling_identity_sha=$(sha256sum "$output" | awk '{print $1}') || return 1
}

verify_phase_a_tooling_identity_live()
{
    local output="${EVIDENCE}/tooling-identity.json"
    verify_package_integrity || return 1
    hotfix_phase_a_tooling_identity_file_is_valid "$output" "$CANDIDATE_TOOLING_COMMIT" \
        "$(sha256sum "$PACKAGE_ROOT/SHA256SUMS" | awk '{print $1}')" \
        "$(sha256sum "${BASH_SOURCE[0]}" | awk '{print $1}')" \
        "$(sha256sum "$PACKAGE_ROOT/node27-v30.1.4-hotfix-candidate.promote-no-data-rewind.sh" |
            awk '{print $1}')" \
        "$(sha256sum "$PACKAGE_ROOT/verify-evidence.sh" | awk '{print $1}')" \
        "$(sha256sum "$PACKAGE_ROOT/lib/typed_contract.sh" | awk '{print $1}')" || return 1
    [[ -z "$phase_a_tooling_identity_sha" ||
       "$(sha256sum "$output" | awk '{print $1}')" == "$phase_a_tooling_identity_sha" ]]
}

protected_bundle_file()
{
    local file="$1"
    [[ -f "$file" && ! -L "$file" &&
       "$(realpath -e -- "$file" 2>/dev/null || true)" == "$file" &&
       "$(stat -Lc '%u:%g:%a' -- "$file" 2>/dev/null || true)" == 0:0:600 ]]
}

verify_oci_archive_layout()
{
    local archive="${1:-$CANDIDATE_OCI_ARCHIVE}" work_parent="${2:-$OPS}"
    local work names verbose manifest_digest manifest_hex config_digest config_hex
    local blob digest hex size actual_size actual_sha referenced expected_ref
    work=$(mktemp -d "${work_parent}/.oci-layout.XXXXXX") || return 1
    names="${work}/names.txt"
    verbose="${work}/verbose.txt"
    tar -tf "$archive" >"$names" || return 1
    tar -tvf "$archive" >"$verbose" || return 1
    [[ -z "$(sed 's#^\./##; s#/$##' "$names" | sort | uniq -d)" ]] || return 1
    while IFS= read -r name; do
        [[ "$name" != ./* && -n "$name" && "$name" != /* && "$name" != *'..'* &&
           ( "$name" == oci-layout || "$name" == index.json || "$name" == blobs ||
             "$name" == blobs/sha256 || "$name" =~ ^blobs/sha256/[0-9a-f]{64}/?$ ) ]] ||
            return 1
    done <"$names"
    [[ -z "$(awk 'substr($1,1,1) != "-" && substr($1,1,1) != "d" {print; exit}' \
        "$verbose")" ]] || return 1
    tar -xf "$archive" -C "$work" --no-same-owner --no-same-permissions ||
        return 1
    [[ -f "$work/oci-layout" && ! -L "$work/oci-layout" &&
       -f "$work/index.json" && ! -L "$work/index.json" &&
       -z "$(find "$work" -type l -print -quit)" ]] || return 1
    cmp -s <(find "$work" -mindepth 1 -type d -print | sed "s#^${work}/##" | sort) <(
        printf '%s\n' blobs blobs/sha256 | sort
    ) || return 1
    jq -e '.imageLayoutVersion == "1.0.0"' "$work/oci-layout" >/dev/null || return 1
    expected_ref=$CANDIDATE_IMAGE
    manifest_digest=$(jq -er --arg ref "$expected_ref" '
        select(.schemaVersion == 2 and (.manifests | length) == 1) |
        .manifests[0] |
        select(.mediaType == "application/vnd.oci.image.manifest.v1+json" and
          .annotations["org.opencontainers.image.ref.name"] == $ref) | .digest
    ' "$work/index.json") || return 1
    [[ "$manifest_digest" == "$CANDIDATE_IMAGE_MANIFEST_DIGEST" ]] || return 1
    manifest_hex=${manifest_digest#sha256:}
    [[ -f "$work/blobs/sha256/$manifest_hex" &&
       "$(sha256sum "$work/blobs/sha256/$manifest_hex" | awk '{print $1}')" == "$manifest_hex" ]] ||
        return 1
    config_digest=$(jq -er '
        select(.schemaVersion == 2 and
          .mediaType == "application/vnd.oci.image.manifest.v1+json" and
          (.layers | type) == "array" and (.layers | length) > 0) |
        .config.digest
    ' "$work/blobs/sha256/$manifest_hex") || return 1
    [[ "$config_digest" == "$CANDIDATE_IMAGE_ID" ]] || return 1
    config_hex=${config_digest#sha256:}
    referenced="${work}/referenced.txt"
    {
        printf '%s\n' "$manifest_hex" "$config_hex"
        jq -r '.layers[].digest | sub("^sha256:"; "")' "$work/blobs/sha256/$manifest_hex"
    } | sort -u >"$referenced"
    cmp -s "$referenced" <(
        find "$work/blobs/sha256" -mindepth 1 -maxdepth 1 -type f -exec basename {} \; |
            sort -u
    ) || return 1
    while IFS=$'\t' read -r digest size; do
        [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ && "$size" =~ ^[1-9][0-9]*$ ]] || return 1
        hex=${digest#sha256:}
        blob="$work/blobs/sha256/$hex"
        [[ -f "$blob" && ! -L "$blob" ]] || return 1
        actual_size=$(stat -Lc '%s' "$blob" 2>/dev/null || stat -f '%z' "$blob") || return 1
        actual_sha=$(sha256sum "$blob" | awk '{print $1}') || return 1
        [[ "$actual_size" == "$size" && "$actual_sha" == "$hex" ]] || return 1
    done < <(jq -r '[.config,.layers[]] | .[] | [.digest,(.size|tostring)] | @tsv' \
        "$work/blobs/sha256/$manifest_hex")
    actual_size=$(stat -Lc '%s' "$work/blobs/sha256/$manifest_hex" 2>/dev/null ||
        stat -f '%z' "$work/blobs/sha256/$manifest_hex") || return 1
    [[ "$actual_size" == "$(jq -er '.manifests[0].size' "$work/index.json")" ]] ||
        return 1
    jq -e --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" '
        .architecture == "amd64" and .os == "linux" and
        .config.User == "blackcoin" and
        .config.Entrypoint == ["/home/blackcoin/start-gui.sh"] and
        .config.Cmd == null and .config.WorkingDir == "/home/blackcoin" and
        .config.Labels["org.blackcoin.source.commit"] == $source and
        .rootfs.type == "layers" and
        (.rootfs.diff_ids | type) == "array" and (.rootfs.diff_ids | length) > 0
    ' "$work/blobs/sha256/$config_hex" >/dev/null || return 1
    if [[ -d "$EVIDENCE" && "$work_parent" == "$OPS" ]]; then
        install -m 600 -o root -g root "$work/index.json" \
            "${EVIDENCE}/candidate-oci-index.json" || return 1
        install -m 600 -o root -g root "$work/blobs/sha256/$manifest_hex" \
            "${EVIDENCE}/candidate-oci-manifest.json" || return 1
        install -m 600 -o root -g root "$work/blobs/sha256/$config_hex" \
            "${EVIDENCE}/candidate-oci-config.json" || return 1
    fi
    rm -rf -- "$work"
}

verify_bundle_identity()
{
    local file expected actual names expected_names candidate_tar_sha binary_sums_sha
    [[ -d "$CANDIDATE_BUNDLE_DIR" && ! -L "$CANDIDATE_BUNDLE_DIR" &&
       "$(realpath -e -- "$CANDIDATE_BUNDLE_DIR" 2>/dev/null || true)" == "$CANDIDATE_BUNDLE_DIR" &&
       "$(stat -Lc '%u:%g:%a' -- "$CANDIDATE_BUNDLE_DIR" 2>/dev/null || true)" == 0:0:700 ]] ||
        return 1
    [[ -z "$(find "$CANDIDATE_BUNDLE_DIR" -mindepth 1 ! -type f -print -quit)" ]] ||
        return 1
    for file in "$CANDIDATE_BUNDLE_MANIFEST" "$CANDIDATE_BUNDLE_SHA256SUMS" \
        "$CANDIDATE_SOURCE_SIGNATURE" "$CANDIDATE_CORE_CI" "$CANDIDATE_TOOLCHAIN" \
        "$CANDIDATE_BINARY_SHA256SUMS" \
        "$CANDIDATE_PROVENANCE" "$CANDIDATE_OCI_IDENTITY" "$CANDIDATE_OCI_ARCHIVE"; do
        protected_bundle_file "$file" || return 1
        [[ "${file%/*}" == "$CANDIDATE_BUNDLE_DIR" ]] || return 1
    done
    for file in \
        "${HOTFIX_CANDIDATE_PREFIX}-Linux-x86_64.tar.gz" \
        "${HOTFIX_CANDIDATE_PREFIX}-SOURCE_COMMIT.txt" \
        "${HOTFIX_CANDIDATE_PREFIX}-REPRODUCIBILITY.txt" \
        "${HOTFIX_CANDIDATE_PREFIX}-UNSIGNED-CANARY.txt" \
        "${HOTFIX_CANDIDATE_PREFIX}-SOURCE-SIGNATURE.json" \
        "${HOTFIX_CANDIDATE_PREFIX}-CORE-CI.json" \
        "${HOTFIX_CANDIDATE_PREFIX}-TOOLCHAIN.txt" \
        "${HOTFIX_CANDIDATE_PREFIX}-BINARY_SHA256SUMS.txt" \
        "$HOTFIX_CANDIDATE_OCI_ARCHIVE_NAME" \
        "${HOTFIX_CANDIDATE_PREFIX}-OCI-IDENTITY.json" \
        "${HOTFIX_CANDIDATE_PREFIX}-MANIFEST.json" \
        "${HOTFIX_CANDIDATE_PREFIX}-PROVENANCE.intoto.json"; do
        protected_bundle_file "${CANDIDATE_BUNDLE_DIR}/${file}" || return 1
    done
    names=$(mktemp "${OPS}/.bundle-names.XXXXXX") || return 1
    expected_names=$(mktemp "${OPS}/.bundle-expected.XXXXXX") || return 1
    find "$CANDIDATE_BUNDLE_DIR" -mindepth 1 -maxdepth 1 -type f -printf '%f\n' | sort >"$names"
    {
        printf '%s\n' \
            "${HOTFIX_CANDIDATE_PREFIX}-Linux-x86_64.tar.gz" \
            "${HOTFIX_CANDIDATE_PREFIX}-SOURCE_COMMIT.txt" \
            "${HOTFIX_CANDIDATE_PREFIX}-REPRODUCIBILITY.txt" \
            "${HOTFIX_CANDIDATE_PREFIX}-UNSIGNED-CANARY.txt" \
            "${HOTFIX_CANDIDATE_PREFIX}-SOURCE-SIGNATURE.json" \
            "${HOTFIX_CANDIDATE_PREFIX}-CORE-CI.json" \
            "${HOTFIX_CANDIDATE_PREFIX}-TOOLCHAIN.txt" \
            "${HOTFIX_CANDIDATE_PREFIX}-BINARY_SHA256SUMS.txt" \
            "$HOTFIX_CANDIDATE_OCI_ARCHIVE_NAME" \
            "${HOTFIX_CANDIDATE_PREFIX}-OCI-IDENTITY.json" \
            "${HOTFIX_CANDIDATE_PREFIX}-MANIFEST.json" \
            "${HOTFIX_CANDIDATE_PREFIX}-PROVENANCE.intoto.json" \
            "${HOTFIX_CANDIDATE_PREFIX}-SHA256SUMS.txt"
    } | sort >"$expected_names"
    cmp -s "$expected_names" "$names" || return 1
    rm -f -- "$names" "$expected_names"
    for pair in \
        "$CANDIDATE_BUNDLE_MANIFEST|$CANDIDATE_BUNDLE_MANIFEST_SHA256" \
        "$CANDIDATE_BUNDLE_SHA256SUMS|$CANDIDATE_BUNDLE_SHA256SUMS_SHA256" \
        "$CANDIDATE_SOURCE_SIGNATURE|$CANDIDATE_SOURCE_SIGNATURE_SHA256" \
        "$CANDIDATE_CORE_CI|$CANDIDATE_CORE_CI_SHA256" \
        "$CANDIDATE_TOOLCHAIN|$CANDIDATE_TOOLCHAIN_SHA256" \
        "$CANDIDATE_BINARY_SHA256SUMS|$CANDIDATE_BINARY_SHA256SUMS_SHA256" \
        "$CANDIDATE_PROVENANCE|$CANDIDATE_PROVENANCE_SHA256" \
        "$CANDIDATE_OCI_IDENTITY|$CANDIDATE_OCI_IDENTITY_SHA256" \
        "$CANDIDATE_OCI_ARCHIVE|$CANDIDATE_OCI_ARCHIVE_SHA256"; do
        file=${pair%%|*}
        expected=${pair#*|}
        actual=$(sha256sum -- "$file" | awk '{print $1}') || return 1
        [[ "$actual" == "$expected" ]] || return 1
    done
    [[ "$(wc -l <"$CANDIDATE_BUNDLE_SHA256SUMS" | tr -d ' ')" == 12 ]] || return 1
    [[ -z "$(grep -Ev '^[0-9a-f]{64}  [A-Za-z0-9][A-Za-z0-9._-]*$' \
        "$CANDIDATE_BUNDLE_SHA256SUMS" || true)" ]] || return 1
    (cd "$CANDIDATE_BUNDLE_DIR" &&
        sha256sum --strict -c "${CANDIDATE_BUNDLE_SHA256SUMS##*/}" >/dev/null) || return 1
    candidate_tar_sha=$(sha256sum \
        "${CANDIDATE_BUNDLE_DIR}/${HOTFIX_CANDIDATE_PREFIX}-Linux-x86_64.tar.gz" |
        awk '{print $1}') || return 1
    binary_sums_sha=$(sha256sum "$CANDIDATE_BINARY_SHA256SUMS" | awk '{print $1}') || return 1
    [[ "$binary_sums_sha" == "$CANDIDATE_BINARY_SHA256SUMS_SHA256" ]] || return 1
    cmp -s "$CANDIDATE_BINARY_SHA256SUMS" <(
        printf '%s  %s\n' \
            "$CANDIDATE_BLACKCOIN_CLI_SHA256" blackcoin-cli \
            "$CANDIDATE_BLACKCOIN_QT_SHA256" blackcoin-qt \
            "$CANDIDATE_BLACKCOIN_TX_SHA256" blackcoin-tx \
            "$CANDIDATE_BLACKCOIN_UTIL_SHA256" blackcoin-util \
            "$CANDIDATE_BLACKCOIN_WALLET_SHA256" blackcoin-wallet \
            "$CANDIDATE_BLACKCOIND_SHA256" blackcoind
    ) || return 1

    jq -e --arg prefix "$HOTFIX_CANDIDATE_PREFIX" \
        --arg release "$HOTFIX_CANDIDATE_RELEASE_VERSION" \
        --arg classification "$HOTFIX_CANDIDATE_CLASSIFICATION" \
        --arg workflow_path "$HOTFIX_CANDIDATE_WORKFLOW_PATH" \
        --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" \
        --arg ancestor "$IMMUTABLE_V3014_SOURCE_SHA" \
        --arg fingerprint "$HOTFIX_SIGNING_FINGERPRINT" \
        --arg tooling "$CANDIDATE_TOOLING_COMMIT" \
        --arg workflow_commit "$CANDIDATE_WORKFLOW_DEFINITION_COMMIT" \
        --argjson expected_core_run "$HOTFIX_EXPECTED_CORE_CI_RUN_ID" \
        --arg expected_core_base "$HOTFIX_EXPECTED_CORE_CI_PULL_REQUEST_BASE_SHA" \
        --arg expected_workflow_blob "$HOTFIX_EXPECTED_CORE_CI_WORKFLOW_BLOB_SHA256" \
        --argjson run_id "$CANDIDATE_GITHUB_RUN_ID" \
        --argjson run_attempt "$CANDIDATE_GITHUB_RUN_ATTEMPT" \
        --arg toolchain "${CANDIDATE_TOOLCHAIN##*/}" \
        --arg toolchain_sha "$CANDIDATE_TOOLCHAIN_SHA256" \
        --arg base_manifest "$IMMUTABLE_V3014_IMAGE_DIGEST" \
        --arg base_config "$IMMUTABLE_V3014_IMAGE_ID" \
        --arg image_manifest "$CANDIDATE_IMAGE_MANIFEST_DIGEST" \
        --arg image_id "$CANDIDATE_IMAGE_ID" \
        --arg archive "${CANDIDATE_OCI_ARCHIVE##*/}" \
        --arg archive_sha "$CANDIDATE_OCI_ARCHIVE_SHA256" '
        .schema == 1 and
        .classification == $classification and
        .package.name == $prefix and .package.version == $release and
        .package.platform == "linux/amd64" and
        .source.commit == $source and .source.immutable_release_ancestor == $ancestor and
        .source.signature.commit == $source and
        .source.signature.fingerprint == $fingerprint and
        .source.signature.local_git_verified == true and
        .source.signature.github_verified == true and
        .source.signature.github_verification_reason == "valid" and
        .source.signature.workflow_actor == "Blackcoin-Dev" and
        .source.signature.workflow_triggering_actor == "Blackcoin-Dev" and
        .core_ci.head_sha == $source and .core_ci.status == "completed" and
        .core_ci.conclusion == "success" and .core_ci.run_id == $expected_core_run and
        .core_ci.workflow_path == ".github/workflows/pr-gate.yml" and
        .core_ci.workflow_name == "pull-request safety gate" and
        .core_ci.event == "pull_request" and
        .core_ci.repository == "Blackcoin-Dev/Blackcoin" and
        .core_ci.head_repository == "Blackcoin-Dev/Blackcoin" and
        .core_ci.pull_request_number == 49 and
        .core_ci.pull_request_head_sha == $source and
        .core_ci.pull_request_base_sha == $expected_core_base and
        .core_ci.workflow_blob_sha256 == $expected_workflow_blob and
        .authorization == {state:"authorized_exact_signed_source_and_green_ci",
          dispatch_enabled:true,temporary_source_pin:false,
          core_ci_run_id:$expected_core_run} and
        .build.tooling_commit == $tooling and
        .build.workflow_definition_commit == $workflow_commit and
        .build.workflow_path == $workflow_path and
        .build.workflow_run_id == $run_id and .build.workflow_run_attempt == $run_attempt and
        .build.toolchain.evidence == $toolchain and .build.toolchain.sha256 == $toolchain_sha and
        .base_image.manifest_digest == $base_manifest and
        .base_image.config_digest == $base_config and
        .image.source_commit == $source and
        .image.image_manifest_digest == $image_manifest and
        .image.image_config_digest == $image_id and
        .image.archive_name == $archive and .image.archive_sha256 == $archive_sha and
        .image.published == false and .image.registry_pushed == false and
        .image.rootfs_base_prefix_exact == true and .image.candidate_added_rootfs_layers == 1 and
        .release.tag == null and .release.published == false and
        .release.registry_pushed == false and .release.canary_only == true
    ' "$CANDIDATE_BUNDLE_MANIFEST" >/dev/null || return 1
    cmp -s <(jq -S '.source.signature' "$CANDIDATE_BUNDLE_MANIFEST") \
        <(jq -S . "$CANDIDATE_SOURCE_SIGNATURE") || return 1
    cmp -s <(jq -S '.core_ci' "$CANDIDATE_BUNDLE_MANIFEST") \
        <(jq -S . "$CANDIDATE_CORE_CI") || return 1
    cmp -s <(jq -S '.image' "$CANDIDATE_BUNDLE_MANIFEST") \
        <(jq -S . "$CANDIDATE_OCI_IDENTITY") || return 1
    jq -e --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" \
        --arg classification "$HOTFIX_CANDIDATE_CLASSIFICATION" \
        --arg image "$CANDIDATE_IMAGE" \
        --arg manifest "$CANDIDATE_IMAGE_MANIFEST_DIGEST" \
        --arg image_id "$CANDIDATE_IMAGE_ID" --arg archive_sha "$CANDIDATE_OCI_ARCHIVE_SHA256" \
        --arg base_ref "$IMMUTABLE_V3014_IMAGE_REF" \
        --arg base_manifest "$IMMUTABLE_V3014_IMAGE_DIGEST" \
        --arg base_id "$IMMUTABLE_V3014_IMAGE_ID" \
        --arg daemon "$CANDIDATE_BLACKCOIND_SHA256" \
        --arg cli "$CANDIDATE_BLACKCOIN_CLI_SHA256" \
        --arg qt "$CANDIDATE_BLACKCOIN_QT_SHA256" \
        --arg tx "$CANDIDATE_BLACKCOIN_TX_SHA256" \
        --arg wallet "$CANDIDATE_BLACKCOIN_WALLET_SHA256" \
        --arg util "$CANDIDATE_BLACKCOIN_UTIL_SHA256" '
        .schema == 1 and
        .classification == $classification and
        .source_commit == $source and .image_reference == $image and
        .base_reference == $base_ref and .base_manifest_digest == $base_manifest and
        .base_config_digest == $base_id and .image_manifest_digest == $manifest and
        .image_config_digest == $image_id and .archive_sha256 == $archive_sha and
        .os == "linux" and .architecture == "amd64" and .user == "blackcoin" and
        .entrypoint == ["/home/blackcoin/start-gui.sh"] and .cmd == null and
        .working_dir == "/home/blackcoin" and .healthcheck == null and
        .published == false and .registry_pushed == false and .oci_roundtrip_verified == true and
        .rootfs_base_prefix_exact == true and .candidate_added_rootfs_layers == 1 and
        .binaries.blackcoind == $daemon and
        .binaries."blackcoin-cli" == $cli and
        .binaries."blackcoin-qt" == $qt and
        .binaries."blackcoin-tx" == $tx and
        .binaries."blackcoin-wallet" == $wallet and
        .binaries."blackcoin-util" == $util
    ' "$CANDIDATE_OCI_IDENTITY" >/dev/null || return 1
    jq -e --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" \
        --arg fingerprint "$HOTFIX_SIGNING_FINGERPRINT" '
        .schema == 1 and .commit == $source and .repository == "Blackcoin-Dev/Blackcoin" and
        .signer == "Blackcoin-Dev" and .format == "ssh" and .fingerprint == $fingerprint and
        .local_git_verified == true and .github_verified == true and
        .github_verification_reason == "valid" and
        .workflow_actor == "Blackcoin-Dev" and
        .workflow_triggering_actor == "Blackcoin-Dev"
    ' "$CANDIDATE_SOURCE_SIGNATURE" >/dev/null || return 1
    jq -e --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" \
        --argjson expected_core_run "$HOTFIX_EXPECTED_CORE_CI_RUN_ID" \
        --arg expected_core_base "$HOTFIX_EXPECTED_CORE_CI_PULL_REQUEST_BASE_SHA" \
        --arg expected_workflow_blob "$HOTFIX_EXPECTED_CORE_CI_WORKFLOW_BLOB_SHA256" '
        .schema == 1 and .workflow_path == ".github/workflows/pr-gate.yml" and
        .workflow_name == "pull-request safety gate" and
        .event == "pull_request" and .repository == "Blackcoin-Dev/Blackcoin" and
        .head_repository == "Blackcoin-Dev/Blackcoin" and .pull_request_number == 49 and
        .pull_request_head_sha == $source and .head_sha == $source and
        .pull_request_base_sha == $expected_core_base and
        .workflow_blob_sha256 == $expected_workflow_blob and
        .status == "completed" and .conclusion == "success" and
        .run_id == $expected_core_run
    ' "$CANDIDATE_CORE_CI" >/dev/null || return 1
    jq -e --arg archive "${CANDIDATE_OCI_ARCHIVE##*/}" \
        --arg sha "$CANDIDATE_OCI_ARCHIVE_SHA256" '
        ._type == "https://in-toto.io/Statement/v1" and
        any(.subject[]; .name == $archive and .digest.sha256 == $sha)
    ' "$CANDIDATE_PROVENANCE" >/dev/null || return 1
    verify_oci_archive_layout
}

verify_loaded_candidate_image()
{
    local inspect base_inspect name expected actual candidate_tar_sha binary_sums_sha binary_tmp
    candidate_tar_sha=$(sha256sum \
        "${CANDIDATE_BUNDLE_DIR}/${HOTFIX_CANDIDATE_PREFIX}-Linux-x86_64.tar.gz" |
        awk '{print $1}') || return 1
    binary_sums_sha=$(sha256sum "$CANDIDATE_BINARY_SHA256SUMS" | awk '{print $1}') || return 1
    inspect=$(docker image inspect "$CANDIDATE_IMAGE") || return 1
    base_inspect=$(docker image inspect "$IMMUTABLE_V3014_IMAGE_REF") || return 1
    jq -S . <<<"$inspect" >"${EVIDENCE}/candidate-loaded-image.json" || return 1
    jq -S . <<<"$base_inspect" >"${EVIDENCE}/rollback-loaded-image.json" || return 1
    jq -e -n --argjson candidate "$inspect" --argjson base "$base_inspect" '
        ($candidate | length) == 1 and ($base | length) == 1 and
        ($base[0].RootFS.Layers | type) == "array" and
        ($candidate[0].RootFS.Layers | type) == "array" and
        ($candidate[0].RootFS.Layers | length) == (($base[0].RootFS.Layers | length) + 1) and
        $candidate[0].RootFS.Layers[0:($base[0].RootFS.Layers | length)] ==
          $base[0].RootFS.Layers
    ' >/dev/null || return 1
    jq -e -n --argjson candidate "$inspect" \
        --slurpfile config "${EVIDENCE}/candidate-oci-config.json" '
        ($candidate | length) == 1 and ($config | length) == 1 and
        $candidate[0].RootFS.Layers == $config[0].rootfs.diff_ids
    ' >/dev/null || return 1
    jq -e --arg id "$CANDIDATE_IMAGE_ID" --arg image "$CANDIDATE_IMAGE" \
        --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" \
        --arg release "$HOTFIX_CANDIDATE_RELEASE_VERSION" \
        --arg image_version "$HOTFIX_CANDIDATE_IMAGE_VERSION" \
        --arg base_ref "$IMMUTABLE_V3014_IMAGE_REF" --arg base_id "$IMMUTABLE_V3014_IMAGE_ID" \
        --arg daemon "$CANDIDATE_BLACKCOIND_SHA256" \
        --arg cli "$CANDIDATE_BLACKCOIN_CLI_SHA256" \
        --arg qt "$CANDIDATE_BLACKCOIN_QT_SHA256" \
        --arg tx "$CANDIDATE_BLACKCOIN_TX_SHA256" \
        --arg wallet "$CANDIDATE_BLACKCOIN_WALLET_SHA256" \
        --arg util "$CANDIDATE_BLACKCOIN_UTIL_SHA256" '
        length == 1 and .[0].Id == $id and .[0].RepoTags == [$image] and .[0].Os == "linux" and
        .[0].Architecture == "amd64" and .[0].Config.User == "blackcoin" and
        .[0].Config.Entrypoint == ["/home/blackcoin/start-gui.sh"] and
        .[0].Config.Cmd == null and .[0].Config.WorkingDir == "/home/blackcoin" and
        .[0].Config.Healthcheck == null and
        .[0].Config.Labels["org.blackcoin.release.channel"] ==
          ("v" + $release + "-candidate") and
        .[0].Config.Labels["org.blackcoin.release.qualification"] == "canary-only-not-release" and
        .[0].Config.Labels["org.blackcoin.candidate.published"] == "false" and
        .[0].Config.Labels["org.blackcoin.candidate.registry-pushed"] == "false" and
        .[0].Config.Labels["org.blackcoin.release.tag"] == "none" and
        .[0].Config.Labels["org.blackcoin.candidate.kind"] ==
          ("v" + $release + "-candidate") and
        .[0].Config.Labels["org.blackcoin.deployment.scope"] == "canary-only" and
        .[0].Config.Labels["org.blackcoin.source.verification"] ==
          "blackcoin-dev-ssh-plus-github-verified" and
        .[0].Config.Labels["org.blackcoin.source.commit"] == $source and
        .[0].Config.Labels["org.opencontainers.image.revision"] == $source and
        .[0].Config.Labels["org.opencontainers.image.version"] == $image_version and
        .[0].Config.Labels["org.blackcoin.rollback.base.image"] == $base_ref and
        .[0].Config.Labels["org.blackcoin.rollback.base.image.id"] == $base_id and
        .[0].Config.Labels["org.blackcoin.binary.blackcoind.sha256"] == $daemon and
        .[0].Config.Labels["org.blackcoin.binary.blackcoin-cli.sha256"] == $cli and
        .[0].Config.Labels["org.blackcoin.binary.blackcoin-qt.sha256"] == $qt and
        .[0].Config.Labels["org.blackcoin.binary.blackcoin-tx.sha256"] == $tx and
        .[0].Config.Labels["org.blackcoin.binary.blackcoin-wallet.sha256"] == $wallet and
        .[0].Config.Labels["org.blackcoin.binary.blackcoin-util.sha256"] == $util
    ' >/dev/null <<<"$inspect" || return 1
    jq -e --arg artifact_sha "$candidate_tar_sha" --arg sums_sha "$binary_sums_sha" '
        .[0].Config.Labels["org.blackcoin.artifact.sha256"] == $artifact_sha and
        .[0].Config.Labels["org.blackcoin.sha256sums.sha256"] == $sums_sha and
        .[0].Config.Labels["org.blackcoin.package.verification"] ==
          "two-build-reproducible-plus-binary-sha256"
    ' >/dev/null <<<"$inspect" || return 1
    binary_tmp=$(mktemp "${OPS}/.candidate-loaded-binaries.XXXXXX") || return 1
    : >"$binary_tmp"
    for pair in \
        "blackcoind|$CANDIDATE_BLACKCOIND_SHA256" \
        "blackcoin-cli|$CANDIDATE_BLACKCOIN_CLI_SHA256" \
        "blackcoin-qt|$CANDIDATE_BLACKCOIN_QT_SHA256" \
        "blackcoin-tx|$CANDIDATE_BLACKCOIN_TX_SHA256" \
        "blackcoin-wallet|$CANDIDATE_BLACKCOIN_WALLET_SHA256" \
        "blackcoin-util|$CANDIDATE_BLACKCOIN_UTIL_SHA256"; do
        name=${pair%%|*}
        expected=${pair#*|}
        actual=$(docker run --rm --pull=never --network none --read-only --cap-drop ALL \
            --security-opt no-new-privileges --entrypoint /usr/bin/sha256sum \
            "$CANDIDATE_IMAGE" "/usr/local/bin/${name}" | awk '{print $1}') || return 1
        [[ "$actual" == "$expected" ]] || return 1
        printf '%s\t%s\n' "$name" "$actual" >>"$binary_tmp"
    done
    sort -o "$binary_tmp" "$binary_tmp"
    mv -fT -- "$binary_tmp" "${EVIDENCE}/candidate-loaded-binary-sha256.tsv"
}

verify_helper()
{
    [[ -f "$NORMAL_UNLOCK_HELPER" && ! -L "$NORMAL_UNLOCK_HELPER" &&
       "$(stat -Lc '%u:%g:%a' "$NORMAL_UNLOCK_HELPER")" == 0:0:600 &&
       "$(sha256sum "$NORMAL_UNLOCK_HELPER" | awk '{print $1}')" == "$NORMAL_UNLOCK_HELPER_SHA" &&
       "$(sha256sum "$NORMAL_UNLOCK_HELPER" | awk '{print $1}')" == "$HOTFIX_UNLOCK_HELPER_SHA256" ]] &&
        bash -n "$NORMAL_UNLOCK_HELPER"
}

audit_unlock_helper()
{
    local forbidden size lines tmp
    verify_helper || return 1
    forbidden=$(grep -Eio '\b(setstaking|setpowmining|sendrawtransaction|createshadowpowclaimresolution|commitshadowpowclaimresolution|resolveshadowpowclaims|setpowclaimrecovery|getnewaddress|getnewquantumaddress|setpowminingaddress|sendtoaddress|sendmany|fundrawtransaction|signrawtransaction[^[:space:]]*|abandontransaction|resendwallettransactions|forcerelay|walletnotify|zmqpub(rawtx|hashtx|sequence)|eval|source)\b' \
        "$NORMAL_UNLOCK_HELPER" | tr '[:upper:]' '[:lower:]' | sort -u || true)
    [[ -z "$forbidden" ]] || return 1
    [[ "$(grep -Eio '\bwalletpassphrase\b' "$NORMAL_UNLOCK_HELPER" | wc -l | tr -d ' ')" == 1 &&
       "$(grep -Eio '\blistwallets\b' "$NORMAL_UNLOCK_HELPER" | wc -l | tr -d ' ')" == 1 &&
       "$(grep -Eio '\bgetwalletinfo\b' "$NORMAL_UNLOCK_HELPER" | wc -l | tr -d ' ')" == 2 &&
       "$(grep -Eio '\bgetstakinginfo\b' "$NORMAL_UNLOCK_HELPER" | wc -l | tr -d ' ')" == 2 &&
       "$(grep -Eio '\b(walletpassphrase|listwallets|getwalletinfo|getstakinginfo)\b' \
          "$NORMAL_UNLOCK_HELPER" | wc -l | tr -d ' ')" == 6 ]] || return 1
    grep -Eq 'walletpassphrase.*[[:space:]]false([[:space:]]|$)' "$NORMAL_UNLOCK_HELPER" || return 1
    grep -Eq '(^|[^[:alnum:]_])(eval|source|xtrace|set[[:space:]]+-x)([^[:alnum:]_]|$)' \
        "$NORMAL_UNLOCK_HELPER" && return 1
    size=$(stat -Lc '%s' "$NORMAL_UNLOCK_HELPER") || return 1
    lines=$(wc -l <"$NORMAL_UNLOCK_HELPER" | tr -d ' ') || return 1
    [[ "$size" == 3206 && "$lines" == 54 ]] || return 1
    tmp=$(mktemp "${OPS}/.unlock-audit.XXXXXX") || return 1
    jq -S -n --arg nonce "$run_nonce" --arg path "$NORMAL_UNLOCK_HELPER" \
        --arg sha "$NORMAL_UNLOCK_HELPER_SHA" --argjson size "$size" \
        --argjson lines "$lines" '
        {schema:1,run_nonce:$nonce,path:$path,sha256:$sha,regular:true,symlink:false,
         uid:0,gid:0,mode:"600",size:$size,lines:$lines,bash_syntax:true,
         classification:"unlock_only_normal_walletpassphrase",
         mutating_rpc_methods:["walletpassphrase"],
         readonly_rpc_methods:["getstakinginfo","getwalletinfo","listwallets"],
         walletpassphrase_staking_only:false,forbidden_tokens:[],indirection_detected:false,
         secret_captured:false,invoked_during_audit:false}
    ' >"$tmp" || return 1
    hotfix_unlock_helper_audit_file_is_valid "$tmp" || return 1
    mv -fT -- "$tmp" "${EVIDENCE}/unlock-helper-audit.json"
    sync -f "${EVIDENCE}/unlock-helper-audit.json"
}

run_unlock_helper()
{
    hotfix_unlock_helper_audit_file_is_valid "${EVIDENCE}/unlock-helper-audit.json" || return 1
    verify_helper || return 1
    /bin/bash "$NORMAL_UNLOCK_HELPER" 27
}

state_value()
{
    if [[ -f "$PHASE_STATE" && ! -L "$PHASE_STATE" ]]; then
        jq -er '.state' "$PHASE_STATE"
    else
        printf 'NONE\n'
    fi
}

transition_allowed()
{
    local from="$1" to="$2"
    case "${from}:${to}" in
        NONE:PREFLIGHT | PREFLIGHT:BASELINE_COLD | BASELINE_COLD:SNAPSHOT_SET_HELD | \
        SNAPSHOT_SET_HELD:CANDIDATE_CREATED_STOPPED | \
        CANDIDATE_CREATED_STOPPED:PHASE_A_RUNNING | PHASE_A_RUNNING:POW_JOINED | \
        POW_JOINED:WALLET_LOCKED | WALLET_LOCKED:CANDIDATE_STOPPED | \
        CANDIDATE_STOPPED:PRE_REWIND_VERIFIED | PRE_REWIND_VERIFIED:REWIND_SAFE | \
        REWIND_SAFE:REWIND_STARTED | REWIND_STARTED:BASE_QUARANTINE_RUNNING | \
        BASE_QUARANTINE_RUNNING:BASE_CAUGHT_UP | BASE_CAUGHT_UP:SNAPSHOTS_ABSENT | \
        SNAPSHOTS_ABSENT:BASELINE_RESTORED | BASELINE_RESTORED:PHASE_A_PASSED)
            return 0 ;;
    esac
    return 1
}

write_state()
{
    local next="$1" current tmp
    current=$(state_value) || return 1
    transition_allowed "$current" "$next" || return 1
    tmp=$(mktemp "${OPS}/.state.XXXXXX") || return 1
    jq -S -n --arg nonce "$run_nonce" --arg state "$next" \
        --arg previous "$current" --arg utc "$(date -u +%FT%TZ)" '
        {schema:2,phase:"A",node:27,run_nonce:$nonce,state:$state,
         previous_state:$previous,updated_utc:$utc}
    ' >"$tmp" || return 1
    chmod 600 "$tmp" && chown root:root "$tmp" && sync -f "$tmp" || return 1
    mv -fT -- "$tmp" "$PHASE_STATE" || return 1
    sync -f "$PHASE_STATE" && sync -f "$OPS"
    jq -e --arg nonce "$run_nonce" --arg state "$next" \
        '.schema == 2 and .phase == "A" and .run_nonce == $nonce and .state == $state' \
        "$PHASE_STATE" >/dev/null
}

capture_wallet_state()
{
    local prefix="$1" destination="${2:-$EVIDENCE}"
    [[ -d "$destination" && ! -L "$destination" ]] || return 1
    # Preserve every listtransactions entry. A self-spend can have both send
    # and receive rows for one txid; deduplicating by txid could hide the send.
    rpc listtransactions '*' 1000000 0 true | jq -S 'sort_by(.txid,.vout,.category)' \
        >"${destination}/${prefix}-wallet-transactions.json"
    rpc getrawmempool | jq -S . >"${destination}/${prefix}-mempool.json"
    rpc listunspent 0 9999999 | jq -S \
        '[.[] | {txid,vout,address,amount,spendable,solvable}] | sort_by(.txid,.vout)' \
        >"${destination}/${prefix}-wallet-outpoints.json"
    rpc getpowclaimrecoveryinfo true | jq -S . \
        >"${destination}/${prefix}-recovery-inventory.json"
    jq -S '[.[] | select(
        has("qq_shadow_pow_cleanup_for") or
        has("qq_shadow_pow_resolution_schema") or
        has("qq_shadow_pow_resolution_anchor_txid") or
        has("qq_shadow_pow_resolution_origin")) | .txid] | unique | sort' \
        "${destination}/${prefix}-wallet-transactions.json" \
        >"${destination}/${prefix}-resolution-txids.json"
    jq -S '[.component_details[]?.resolution_txids[]?] | unique | sort' \
        "${destination}/${prefix}-recovery-inventory.json" \
        >"${destination}/${prefix}-component-resolution-txids.json"
}

recovery_metrics_json()
{
    jq -cS '{pending_manual_resolutions,pending_automatic_resolutions,
      confirmed_manual_resolutions,confirmed_automatic_resolutions,
      confirmed_resolution_fees,automatic_actions_in_window,
      automatic_fee_exposure_in_window,reconciled_descendant_claims,claims_recycled}' "$1"
}

recovery_metrics_match_baseline()
{
    local current
    current=$(recovery_metrics_json "$1") || return 1
    [[ "$current" == "$baseline_recovery_metrics_json" &&
       "$(printf '%s' "$current" | sha256sum | awk '{print $1}')" == \
         "$baseline_recovery_metrics_sha" ]]
}

legacy_pow_is_feature_detected()
{
    local file="$1"
    jq -e '
        type == "object" and (.enabled | type) == "boolean" and
        .autostart == false and (.threads | type) == "number" and .threads == 1 and
        (.cpu_percent | type) == "number" and .cpu_percent == 1 and
        .allow_automatic_quantum_key_creation == false and
        ((keys | map(select(startswith("mining_gate_"))) | length) == 0)
    ' "$file" >/dev/null
}

candidate_off_is_safe()
{
    local mining_file="$1" recovery_file="$2" wallet_file="$3" staking_file="$4"
    hotfix_candidate_pow_json_is_valid "$(<"$mining_file")" off &&
        hotfix_candidate_recovery_json_is_valid "$(<"$recovery_file")" \
            "$baseline_recovery_fee" &&
        jq -e --argjson manual "$baseline_pending_manual" \
            --argjson automatic "$baseline_pending_automatic" '
            .pending_manual_resolutions == $manual and
            .pending_automatic_resolutions == $automatic
        ' "$recovery_file" >/dev/null &&
        recovery_metrics_match_baseline "$recovery_file" &&
        jq -e '.private_keys_enabled == true and .unlocked_until == 0' \
            "$wallet_file" >/dev/null &&
        hotfix_phase_a_staking_json_is_disabled "$(<"$staking_file")"
}

write_wrapper_override()
{
    local image="$1"
    cat >"$OVERRIDE" <<EOF
services:
  node27:
    image: ${image}
    restart: "no"
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
      - -walletbroadcast=0
      - -blocksonly=1
      - -staking=0
      - -autostartstaking=0
      - -powmining=0
      - -qqautoshadowsignal=0
      - -qqautodemurrageattest=0
EOF
    chmod 600 "$OVERRIDE" && chown root:root "$OVERRIDE" && sync -f "$OVERRIDE"
}

create_stopped_from_override()
{
    docker compose -f "$COMPOSE" -f "$OVERRIDE" create --force-recreate --pull never "$SERVICE"
    docker inspect "$CONTAINER" | jq -e '
      length==1 and .[0].State.Running==false and
      .[0].HostConfig.RestartPolicy=={Name:"no",MaximumRetryCount:0}
    ' >/dev/null
}

inspect_mounts_sha()
{
    local inspect_file="$1"
    jq -cS '.[0].Mounts | map({Type,Source,Destination,Mode,RW,Propagation}) |
        sort_by(.Destination)' "$inspect_file" | sha256sum | awk '{print $1}'
}

inspect_network_sha()
{
    local inspect_file="$1"
    jq -cS '.[0] | {network_mode:.HostConfig.NetworkMode,
      port_bindings:(.HostConfig.PortBindings // {}),
      publish_all_ports:(.HostConfig.PublishAllPorts // false),
      links:(.HostConfig.Links // []),extra_hosts:(.HostConfig.ExtraHosts // []),
      dns:(.HostConfig.Dns // [])}' "$inspect_file" | sha256sum | awk '{print $1}'
}

inspect_restart_policy_json()
{
    local inspect_file="$1"
    jq -ceS '.[0].HostConfig.RestartPolicy |
      select((keys | sort) == ["MaximumRetryCount","Name"] and
        (.Name | type) == "string" and
        (.MaximumRetryCount | type) == "number" and
        (.MaximumRetryCount | floor) == .MaximumRetryCount and
        .MaximumRetryCount >= 0)' "$inspect_file"
}

capture_created_inspection()
{
    local output="$1" expected_id="$2" inspect_file mounts_sha network_sha restart_policy
    inspect_file=$(mktemp "${OPS}/.created-inspect.XXXXXX") || return 1
    docker inspect "$CONTAINER" >"$inspect_file" || return 1
    mounts_sha=$(inspect_mounts_sha "$inspect_file") || return 1
    network_sha=$(inspect_network_sha "$inspect_file") || return 1
    restart_policy=$(inspect_restart_policy_json "$inspect_file") || return 1
    [[ "$mounts_sha" == "$baseline_mounts_sha" &&
       "$network_sha" == "$baseline_network_sha" &&
       "$restart_policy" == '{"MaximumRetryCount":0,"Name":"no"}' ]] || return 1
    jq -S --arg id "$expected_id" --arg mounts_sha "$mounts_sha" \
        --arg network_sha "$network_sha" --argjson restart "$restart_policy" '
        .[0] | {image_id:.Image,running:.State.Running,user:.Config.User,
          working_dir:.Config.WorkingDir,entrypoint:.Config.Entrypoint,cmd:.Config.Cmd,
          path:.Path,args:.Args,mounts:.Mounts,network_mode:.HostConfig.NetworkMode,
          port_bindings:(.HostConfig.PortBindings // {}),
          mounts_sha256:$mounts_sha,network_sha256:$network_sha,restart_policy:$restart} |
        select(.image_id == $id and .running == false and .user == "blackcoin" and
          .working_dir == "/home/blackcoin" and
          .restart_policy == {Name:"no",MaximumRetryCount:0})
    ' "$inspect_file" >"$output" || return 1
    rm -f -- "$inspect_file"
    [[ -s "$output" &&
       "$(jq -er '.mounts_sha256' "$output")" == "$baseline_mounts_sha" &&
       "$(jq -er '.network_sha256' "$output")" == "$baseline_network_sha" ]]
}

capture_invocation()
{
    local phase="$1" image_id="$2" created_file="$3" output="$4"
    local inspect_file argv_file body_sha pid_exe pid_sha mounts_sha network_sha argv_sha
    local config_sha conflicting_env runtime_source
    [[ -s "$created_file" ]] || return 1
    inspect_file=$(mktemp "${OPS}/.inspect.XXXXXX") || return 1
    argv_file=$(mktemp "${OPS}/.argv.XXXXXX") || return 1
    docker inspect "$CONTAINER" >"$inspect_file" || return 1
    [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER")" == true ]] || return 1
    pid_exe=$(docker exec "$CONTAINER" readlink -f /proc/1/exe) || return 1
    [[ "$pid_exe" == /usr/local/bin/blackcoin-qt ]] || return 1
    pid_sha=$(docker exec "$CONTAINER" sha256sum /proc/1/exe | awk '{print $1}') || return 1
    if [[ "$image_id" == "$CANDIDATE_IMAGE_ID" &&
       "$pid_sha" != "$CANDIDATE_BLACKCOIN_QT_SHA256" ]]; then
        return 1
    fi
    if [[ "$image_id" == "$CANDIDATE_IMAGE_ID" ]]; then
        runtime_source=$HOTFIX_CANDIDATE_SOURCE_SHA
    elif [[ "$image_id" == "$IMMUTABLE_V3014_IMAGE_ID" ]]; then
        runtime_source=$IMMUTABLE_V3014_SOURCE_SHA
    else
        return 1
    fi
    docker exec "$CONTAINER" /bin/bash -c 'tr "\0" "\n" </proc/1/cmdline' |
        jq -Rsc 'split("\n")[:-1]' >"$argv_file" || return 1
    argv_sha=$(sha256sum "$argv_file" | awk '{print $1}') || return 1
    mounts_sha=$(inspect_mounts_sha "$inspect_file") || return 1
    network_sha=$(inspect_network_sha "$inspect_file") || return 1
    config_sha=$(sha256sum "$HOST_DATADIR/blackcoin.conf" | awk '{print $1}') || return 1
    [[ "$mounts_sha" == "$baseline_mounts_sha" &&
       "$network_sha" == "$baseline_network_sha" &&
       "$config_sha" == "$baseline_config_sha" ]] || return 1
    jq -e -n --slurpfile created "$created_file" --slurpfile inspect "$inspect_file" \
        --arg mounts "$baseline_mounts_sha" --arg network "$baseline_network_sha" '
        $created[0].mounts_sha256 == $mounts and $created[0].network_sha256 == $network and
        $created[0].entrypoint == $inspect[0][0].Config.Entrypoint and
        $created[0].cmd == $inspect[0][0].Config.Cmd
    ' >/dev/null || return 1
    conflicting_env=$(jq -cS '.[0].Config.Env // [] | map(select(test(
      "(?i)(walletbroadcast|(^|_)staking|powmining|qqautoshadowsignal|qqautodemurrageattest)")))' \
      "$inspect_file") || return 1
    [[ "$conflicting_env" == '[]' ]] || return 1
    body_sha=$(jq -j '.[0].Config.Entrypoint[2]' "$inspect_file" | sha256sum | awk '{print $1}') || return 1
    [[ "$body_sha" == "$HOTFIX_CANDIDATE_ENTRYPOINT_BODY_SHA256" ]] || return 1
    jq -S -n --arg phase "$phase" --arg nonce "$run_nonce" \
        --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" --arg runtime_source "$runtime_source" \
        --arg id "$image_id" \
        --arg start_gui "$IMMUTABLE_START_GUI_SHA256" --arg body_sha "$body_sha" \
        --arg exe_sha "$pid_sha" --arg mounts_sha "$mounts_sha" \
        --arg network_sha "$network_sha" --arg config_sha "$config_sha" \
        --arg argv_sha "$argv_sha" --argjson conflicting_env "$conflicting_env" \
        --slurpfile inspect "$inspect_file" --slurpfile argv "$argv_file" '
        ($inspect[0][0]) as $i |
        {schema:2,phase:$phase,run_nonce:$nonce,candidate_source_sha:$source,image_id:$id,
         runtime_source_sha:$runtime_source,
         immutable_start_gui_sha256:$start_gui,entrypoint_body_sha256:$body_sha,
         created_stopped:true,inspected_before_start:true,image_user:$i.Config.User,
         working_dir:$i.Config.WorkingDir,image_entrypoint:["/home/blackcoin/start-gui.sh"],
         image_cmd:null,effective_entrypoint:$i.Config.Entrypoint,effective_cmd:$i.Config.Cmd,
         container_path:$i.Path,container_args:$i.Args,runtime_executable:$argv[0][0],
         runtime_argv:$argv[0],pid1_exe_sha256:$exe_sha,runtime_argv_sha256:$argv_sha,
         display_environment:"DISPLAY=:0",
         setup_processes:{xvfb:true,fluxbox:true,x11vnc:true,websockify:true},
         mounts_sha256:$mounts_sha,network_sha256:$network_sha,
         config_sha256:$config_sha,mounts_equal_baseline:true,
         network_equal_baseline:true,baseline_config_unchanged:true,
         operator_override_allowed:false,conflicting_cli_flags:[],
         conflicting_environment_entries:$conflicting_env}
    ' >"$output" || return 1
    rm -f -- "$inspect_file" "$argv_file"
    hotfix_invocation_file_is_valid "$output" "$phase" "$image_id" "$run_nonce" \
        "$runtime_source"
}

assert_setup_processes()
{
    local ps name
    ps=$(docker exec "$CONTAINER" ps -eo comm=) || return 1
    for name in Xvfb fluxbox x11vnc websockify blackcoin-qt; do
        grep -Fx "$name" <<<"$ps" >/dev/null || return 1
    done
}

probe_unreachable()
{
    local host="$1" port="$2" diagnostic rc
    # $1/$2 intentionally expand in the bounded child shell.
    # shellcheck disable=SC2016
    if diagnostic=$(timeout -k 2 5 /bin/bash -c \
        'exec 3<>"/dev/tcp/$1/$2"' phase-a-host-probe "$host" "$port" 2>&1); then
        return 1
    else
        rc=$?
    fi
    [[ "$rc" == 124 || "$rc" == 137 ]] && return 0
    [[ "$rc" == 1 && "$diagnostic" =~ (Connection[[:space:]]refused|Connection[[:space:]]timed[[:space:]]out|No[[:space:]]route[[:space:]]to[[:space:]]host|Network[[:space:]]is[[:space:]]unreachable) ]]
}

probe_unreachable_from_container()
{
    local probe_container="$1" host="$2" port="$3" diagnostic rc
    # $1/$2 intentionally expand in the bounded child shell, not this process.
    # shellcheck disable=SC2016
    if diagnostic=$(timeout -k 2 5 docker exec "$probe_container" /bin/bash -c \
        'exec 3<>"/dev/tcp/$1/$2"' phase-a-probe "$host" "$port" 2>&1); then
        return 1
    else
        rc=$?
    fi
    [[ "$rc" == 124 || "$rc" == 137 ]] && return 0
    [[ "$rc" == 1 && "$diagnostic" =~ (Connection[[:space:]]refused|Connection[[:space:]]timed[[:space:]]out|No[[:space:]]route[[:space:]]to[[:space:]]host|Network[[:space:]]is[[:space:]]unreachable) ]]
}

phase_a_interactive_surfaces_are_stopped()
{
    local processes
    processes=$(timeout -k 2 5 docker exec "$CONTAINER" ps -eo comm=) || return 1
    ! grep -Eq '^[[:space:]]*(x11vnc|websockify)[[:space:]]*$' <<<"$processes" &&
        probe_unreachable_from_container "$VPN_CONTAINER" 127.0.0.1 5900 &&
        probe_unreachable_from_container "$VPN_CONTAINER" 127.0.0.1 8080
}

disable_phase_a_interactive_surfaces()
{
    timeout -k 2 10 docker exec "$CONTAINER" pkill -TERM -x x11vnc >/dev/null 2>&1 || return 1
    timeout -k 2 10 docker exec "$CONTAINER" pkill -TERM -x websockify >/dev/null 2>&1 || return 1
    for _ in $(seq 1 30); do
        phase_a_interactive_surfaces_are_stopped && return 0
        sleep 1
    done
    return 1
}

shared_namespace_rpc_rejects_unauthenticated_calls()
{
    local http_code
    http_code=$(timeout -k 2 8 docker exec "$VPN_CONTAINER" /bin/bash -c '
      command -v curl >/dev/null 2>&1 || exit 69
      curl --disable --noproxy "*" --proxy "" --silent --show-error \
        --output /dev/null --max-time 3 \
        --write-out "%{http_code}" --header "content-type: application/json" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":\"phase-a-no-auth\",\"method\":\"getblockchaininfo\",\"params\":[]}" \
        http://127.0.0.1:15715/
    ' 2>/dev/null) || return 1
    [[ "$http_code" == 401 ]]
}

capture_nonpublication()
{
    local output="$1" evidence_base network peers sharers port_bindings node_port_bindings
    local listeners firewall firewall6 nft_rules vpn_mounts vpn_security node_processes
    local host_addresses vpn_addresses address
    local listener_sha firewall_sha firewall6_sha nft_sha ports_sha mounts_sha auth_sha probe_sha
    local shared_rpc_tcp=false
    evidence_base=${output%.json}
    [[ -n "$evidence_base" && -d "${output%/*}" && ! -L "${output%/*}" ]] || return 1
    network=$(rpc getnetworkinfo) || return 1
    peers=$(rpc getpeerinfo) || return 1
    jq -e '.networkactive == true and .localrelay == false' <<<"$network" >/dev/null || return 1
    jq -e 'all(.[]; .relaytxes == false and
        ((.permissions // []) | all(. != "relay" and . != "forcerelay")))' \
        <<<"$peers" >/dev/null || return 1
    if awk -F= '
      /^[[:space:]]*($|#)/ { next }
      {
        key=tolower($1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
        if (key == "includeconf" || key == "walletnotify" || key == "zmqpubrawtx" ||
            key == "zmqpubhashtx" || key == "zmqpubsequence" || key == "walletbroadcast") bad=1
      }
      END { exit bad ? 0 : 1 }
    ' "$HOST_DATADIR/blackcoin.conf"; then
        return 1
    fi
    if awk -F= '
      /^[[:space:]]*($|#)/ { next }
      {
        key=tolower($1); value=tolower($2)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        if (key == "rpcallowip") bad=1
        if (key == "rpcbind" && value != "127.0.0.1" && value != "::1" &&
            value != "[::1]" && value != "localhost") bad=1
      }
      END { exit bad ? 0 : 1 }
    ' "$HOST_DATADIR/blackcoin.conf"; then
        return 1
    fi
    port_bindings=$(docker inspect "$VPN_CONTAINER" | jq -cS '.[0].HostConfig.PortBindings // {}') || return 1
    node_port_bindings=$(docker inspect "$CONTAINER" | jq -cS '.[0].HostConfig.PortBindings // {}') || return 1
    jq -e 'to_entries | all(.[]; ((.key | startswith("8080/")) or
        (.key | startswith("5900/")) or (.key | startswith("15715/"))) | not)' \
        <<<"$port_bindings" >/dev/null || return 1
    jq -e 'length == 0' <<<"$node_port_bindings" >/dev/null || return 1
    sharers=$(docker ps -aq | xargs -r docker inspect | jq -cS --arg mode "container:${VPN_CONTAINER}" \
        '[.[] | select(.HostConfig.NetworkMode == $mode) | .Name[1:]] | sort') || return 1
    [[ "$sharers" == '["blackcoin-v4-gui-27"]' ]] || return 1
    listeners=$(docker exec "$VPN_CONTAINER" ss -lntH) || return 1
    grep -Eq '(^|[[:space:]])[^[:space:]]*:(8080|5900)([[:space:]]|$)' <<<"$listeners" && return 1
    awk '
      $4 ~ /:15715$/ {
        found=1
        if ($4 !~ /^(127[.]0[.]0[.]1|\[::1\]|::1):15715$/) bad=1
      }
      END { exit !(found && !bad) }
    ' <<<"$listeners" || return 1
    phase_a_interactive_surfaces_are_stopped || return 1
    if ! probe_unreachable_from_container "$VPN_CONTAINER" 127.0.0.1 15715; then
        shared_rpc_tcp=true
    fi
    [[ "$shared_rpc_tcp" == true ]] || return 1
    shared_namespace_rpc_rejects_unauthenticated_calls || return 1
    firewall=$(docker exec "$VPN_CONTAINER" iptables-save) || return 1
    firewall6=$(docker exec "$VPN_CONTAINER" ip6tables-save) || return 1
    nft_rules=$(docker exec "$VPN_CONTAINER" nft list ruleset) || return 1
    grep -Eq '^:INPUT DROP \[[0-9]+:[0-9]+\]$' <<<"$firewall" || return 1
    grep -Eq '^:INPUT DROP \[[0-9]+:[0-9]+\]$' <<<"$firewall6" || return 1
    grep -Eq -- '--dport (8080|5900|15715).* -j ACCEPT' <<<"$firewall" && return 1
    grep -Eq -- '--dport (8080|5900|15715).* -j ACCEPT' <<<"$firewall6" && return 1
    probe_unreachable 127.0.0.1 8080 || return 1
    probe_unreachable 127.0.0.1 5900 || return 1
    probe_unreachable 127.0.0.1 15715 || return 1
    probe_unreachable ::1 8080 || return 1
    probe_unreachable ::1 5900 || return 1
    probe_unreachable ::1 15715 || return 1
    host_addresses=$(hostname -I | tr ' ' '\n' | awk 'NF' | sort -u) || return 1
    [[ -n "$host_addresses" ]] || return 1
    while IFS= read -r address; do
        probe_unreachable "$address" 8080 && probe_unreachable "$address" 5900 &&
            probe_unreachable "$address" 15715 || return 1
    done <<<"$host_addresses"
    vpn_addresses=$(docker inspect "$VPN_CONTAINER" | jq -er '
      [.[0].NetworkSettings.Networks[] | .IPAddress,.GlobalIPv6Address] |
      map(select(type == "string" and length > 0)) | unique | .[]
    ') || return 1
    [[ -n "$vpn_addresses" ]] || return 1
    while IFS= read -r address; do
        probe_unreachable "$address" 8080 && probe_unreachable "$address" 5900 &&
            probe_unreachable "$address" 15715 || return 1
    done <<<"$vpn_addresses"
    vpn_mounts=$(docker inspect "$VPN_CONTAINER" | jq -cS \
        '.[0].Mounts | map({Source,Destination,RW}) | sort_by(.Destination)') || return 1
    jq -e --arg datadir "$DATADIR" '
      all(.[]; .Destination != $datadir and .Destination != "/root/.blackcoin" and
        .Destination != "/home/blackcoin/.blackcoin")
    ' <<<"$vpn_mounts" >/dev/null || return 1
    vpn_security=$(docker inspect "$VPN_CONTAINER" | jq -cS --arg datadir "$HOST_DATADIR" '
      .[0] | {
        privileged:(.HostConfig.Privileged // false),
        pid_mode:(.HostConfig.PidMode // ""),
        dangerous_caps:((.HostConfig.CapAdd // []) |
          map(select(test("^(SYS_ADMIN|SYS_PTRACE|DAC_READ_SEARCH|DAC_OVERRIDE)$")))),
        auth_environment_names:((.Config.Env // []) | map(split("=")[0]) |
          map(select(test("(?i)(rpc|blackcoin|cookie|wallet)"))) | sort),
        sensitive_mounts:(.Mounts | map(select(
          .Source == "/" or .Source == "/var/run/docker.sock" or
          .Destination == "/var/run/docker.sock" or .Destination == "/run/docker.sock" or
          .Source == $datadir or (.Source | startswith($datadir + "/")) or
          (.Source as $source | $datadir | startswith($source + "/")) or
          (.Destination | test("(^|/)([.]?blackcoin|[.]cookie)(/|$)")))) |
          map({Source,Destination,RW}) | sort_by(.Destination))}
    ') || return 1
    jq -e '.privileged == false and .pid_mode == "" and .dangerous_caps == [] and
      .auth_environment_names == [] and .sensitive_mounts == []' \
      <<<"$vpn_security" >/dev/null || return 1
    # $path intentionally expands inside the bounded VPN-container shell.
    # shellcheck disable=SC2016
    timeout -k 2 10 docker exec "$VPN_CONTAINER" /bin/bash -c '
      for path in /home/blackcoin/.blackcoin /root/.blackcoin /root/.bitcoin \
        /home/blackcoin/.bitcoin /run/blackcoin /var/run/blackcoin; do
        [[ ! -e "$path" ]] || exit 1
      done
    ' || return 1
    node_processes=$(timeout -k 2 10 docker exec "$CONTAINER" ps -eo comm= |
        awk '{$1=$1}; NF' | sort -u) || return 1
    grep -Eq '^blackcoin-qt$' <<<"$node_processes" || return 1
    grep -Eq '^Xvfb$' <<<"$node_processes" || return 1
    grep -Eq '^fluxbox$' <<<"$node_processes" || return 1
    grep -Ev '^(Xvfb|blackcoin-qt|fluxbox|ps)$' <<<"$node_processes" | grep -q . && return 1
    [[ -e "$SUSPENDED_START_MARKER" && ! -L "$SUSPENDED_START_MARKER" &&
       ! -e "$ENABLE_GUARD_STARTS" && -e "$MAINTENANCE_MARKER" &&
       ! -e "$PROMOTION_MARKER" ]] || return 1
    verify_live_guard_contract || return 1
    [[ "$(readlink -f /proc/$$/fd/5)" == /run/blackcoin-endpoint-guard.lock &&
       "$(readlink -f /proc/$$/fd/9)" == /var/run/blackcoin-node-cutover.lock &&
       "$(readlink -f /proc/$$/fd/8)" == /run/blackcoin-pow-quarantine-cycle.lock &&
       "$(readlink -f /proc/$$/fd/7)" == /var/run/blackcoin-wallet-runtime-guard.lock ]] || return 1
    printf '%s\n' "$listeners" >"${evidence_base}.listeners.txt" || return 1
    printf '%s\n' "$firewall" >"${evidence_base}.iptables.txt" || return 1
    printf '%s\n' "$firewall6" >"${evidence_base}.ip6tables.txt" || return 1
    printf '%s\n' "$nft_rules" >"${evidence_base}.nft.txt" || return 1
    jq -S -n --argjson vpn "$port_bindings" --argjson node "$node_port_bindings" \
        '{vpn_container:$vpn,node27:$node}' >"${evidence_base}.port-bindings.json" || return 1
    printf '%s\n' "$vpn_mounts" | jq -S . >"${evidence_base}.vpn-mounts.json" || return 1
    jq -S -n --argjson vpn_security "$vpn_security" \
        --argjson processes "$(printf '%s\n' "$node_processes" | jq -Rsc \
          'split("\n") | map(select(length > 0))')" '
        {vpn_namespace:$vpn_security,cookie_or_conf_paths_present:[],
         candidate_processes:$processes,
         candidate_rpc_capable_processes:["blackcoin-qt"],
         separate_pid_namespace:true,shared_rpc_unauthenticated_rejected:true,
         rpc_auth_material_unavailable_to_shared_namespace:true}
    ' >"${evidence_base}.rpc-auth-boundary.json" || return 1
    jq -S -n \
        --argjson host_addresses "$(printf '%s\n' "$host_addresses" | jq -Rsc \
          'split("\n") | map(select(length > 0))')" \
        --argjson vpn_addresses "$(printf '%s\n' "$vpn_addresses" | jq -Rsc \
          'split("\n") | map(select(length > 0))')" '
        {loopback_addresses:["127.0.0.1","::1"],host_addresses:$host_addresses,
         vpn_addresses:$vpn_addresses,ports:[8080,5900,15715],
         all_host_and_vpn_targets_observed_inaccessible:true,
         shared_namespace_rpc_tcp_reachable:true,
         shared_namespace_rpc_unauthenticated_rejected:true,
         shared_namespace_gui_vnc_ports_observed_inaccessible:true}
    ' >"${evidence_base}.probe-targets.json" || return 1
    chmod 600 "${evidence_base}.listeners.txt" "${evidence_base}.iptables.txt" \
        "${evidence_base}.ip6tables.txt" "${evidence_base}.nft.txt" \
        "${evidence_base}.port-bindings.json" "${evidence_base}.vpn-mounts.json" \
        "${evidence_base}.rpc-auth-boundary.json" "${evidence_base}.probe-targets.json" || return 1
    listener_sha=$(sha256sum "${evidence_base}.listeners.txt" | awk '{print $1}') || return 1
    firewall_sha=$(sha256sum "${evidence_base}.iptables.txt" | awk '{print $1}') || return 1
    firewall6_sha=$(sha256sum "${evidence_base}.ip6tables.txt" | awk '{print $1}') || return 1
    nft_sha=$(sha256sum "${evidence_base}.nft.txt" | awk '{print $1}') || return 1
    ports_sha=$(sha256sum "${evidence_base}.port-bindings.json" | awk '{print $1}') || return 1
    mounts_sha=$(sha256sum "${evidence_base}.vpn-mounts.json" | awk '{print $1}') || return 1
    auth_sha=$(sha256sum "${evidence_base}.rpc-auth-boundary.json" | awk '{print $1}') || return 1
    probe_sha=$(sha256sum "${evidence_base}.probe-targets.json" | awk '{print $1}') || return 1
    jq -S -n --arg nonce "$run_nonce" --arg suspension "$run_nonce" \
        --arg listener_sha "$listener_sha" --arg firewall_sha "$firewall_sha" \
        --arg firewall6_sha "$firewall6_sha" --arg nft_sha "$nft_sha" \
        --arg ports_sha "$ports_sha" --arg mounts_sha "$mounts_sha" \
        --arg auth_sha "$auth_sha" --arg probe_sha "$probe_sha" '
        {schema:1,phase:"A",run_nonce:$nonce,rpc_loopback_only:true,
         rpc_host_port_bindings:[],rpc_shared_namespace_port_bindings:["127.0.0.1:15715/tcp"],
         rpc_external_probe:"host-and-vpn-inaccessible-shared-netns-authenticated-only",
         gui_vnc_external_probe:"inaccessible",
         vpn_namespace_port_bindings:[],vpn_firewall_blocks_gui_vnc:true,
         vpn_namespace_sharers:["blackcoin-v4-gui-27"],keeper_api_suspended:true,
         keeper_api_suspension_basis:["four-locks-held","guard-contract-hash",
           "shared-netns-rpc-auth-boundary","rpc-host-vpn-unpublished"],
         guard_start_suspended:true,suspension_nonce:$suspension,
         probe_results:[
           {path:"host-loopback",reachable:false,status:"observed"},
           {path:"host-lan",reachable:false,status:"observed"},
           {path:"vpn-ingress",reachable:false,status:"observed"},
           {path:"shared-namespace",reachable:true,status:"authenticated-only",
            tcp_rpc_reachable:true,unauthenticated_rpc_rejected:true,
            gui_vnc_ports_closed:true,cookie_mount_absent:true}],
         walletnotify:null,zmq_transaction_endpoints:[],relay_forcerelay_peer_ids:[],
         all_peer_relaytxes_false:true,network_localrelay:false,networkactive:true,
         blocksonly:true,config_no_walletbroadcast_override:true,unknown_surfaces:[],
         includeconf_rejected:true,interactive_services_stopped:true,
         guard_authority_observed:true,rpc_auth_material_unavailable_to_shared_namespace:true,
         candidate_rpc_capable_processes:["blackcoin-qt"],
         listener_evidence_sha256:$listener_sha,
         ipv4_firewall_evidence_sha256:$firewall_sha,
         ipv6_firewall_evidence_sha256:$firewall6_sha,nft_evidence_sha256:$nft_sha,
         port_binding_evidence_sha256:$ports_sha,vpn_mount_evidence_sha256:$mounts_sha,
         rpc_auth_boundary_evidence_sha256:$auth_sha,probe_target_evidence_sha256:$probe_sha}
    ' >"$output" || return 1
    chmod 600 "$output" && sync -f "$output" || return 1
    # Preserve the truthful authenticated shared-netns shape. The typed contract
    # verifies its raw boundary evidence and never coerces a reachable RPC socket
    # into an "unreachable" assertion.
    hotfix_nonpublication_file_is_valid "$output" "$run_nonce"
}

observer_mempools_are_available()
{
    local observer
    for observer in blackcoin-v4-gui-26 blackcoin-v4-gui-28; do
        timeout -k 2 30 docker exec "$observer" "$CLI" -datadir="$DATADIR" \
            getblockchaininfo >/dev/null || return 1
        timeout -k 2 30 docker exec "$observer" "$CLI" -datadir="$DATADIR" \
            getrawmempool >/dev/null || return 1
    done
}

append_tx_visibility_sample()
{
    local sample="$1" terminal_chain="$2" output="$3"
    local tmp local_pool observer pool_file chain1 chain2 relation terminal_work observer_work
    tmp=$(mktemp "${OPS}/.visibility.XXXXXX") || return 1
    local_pool=$(rpc getrawmempool | jq -cS 'sort') || return 1
    terminal_work=$(jq -er '.chainwork' <<<"$terminal_chain") || return 1
    : >"${tmp}.observers"
    for observer in blackcoin-v4-gui-26 blackcoin-v4-gui-28; do
        chain1=$(timeout -k 2 30 docker exec "$observer" "$CLI" -datadir="$DATADIR" \
            getblockchaininfo) || return 1
        observer_chain_covers_terminal "$terminal_chain" "$chain1" || return 1
        pool_file="${tmp}.${observer}"
        timeout -k 2 30 docker exec "$observer" "$CLI" -datadir="$DATADIR" \
            getrawmempool | jq -cS 'sort' >"$pool_file" || return 1
        chain2=$(timeout -k 2 30 docker exec "$observer" "$CLI" -datadir="$DATADIR" \
            getblockchaininfo) || return 1
        jq -e -n --argjson a "$chain1" --argjson b "$chain2" '
          $a.bestblockhash == $b.bestblockhash and $a.chainwork == $b.chainwork and
          $a.blocks == $b.blocks and $a.headers == $b.headers
        ' >/dev/null || return 1
        observer_chain_covers_terminal "$terminal_chain" "$chain2" || return 1
        observer_work=$(jq -er '.chainwork' <<<"$chain2") || return 1
        if [[ "$observer_work" == "$terminal_work" ]]; then
            relation=same_terminal_tip
        else
            relation=terminal_superseded_by_greater_work
        fi
        jq -cS -n --arg observer "$observer" --arg relation "$relation" \
            --argjson before "$chain1" --argjson after "$chain2" \
            --slurpfile txids "$pool_file" '
            {observer:$observer,txids:$txids[0],chain_before:$before,chain_after:$after,
             stable:true,terminal_relation:$relation}
        ' >>"${tmp}.observers" || return 1
    done
    jq -cS -n --arg utc "$(date -u +%FT%TZ)" --argjson sample "$sample" \
        --arg tip "$(jq -er '.bestblockhash' <<<"$terminal_chain")" \
        --arg work "$terminal_work" --argjson local "$local_pool" \
        --slurpfile observers "${tmp}.observers" \
        '{sample:$sample,observed_utc:$utc,candidate_tip:$tip,candidate_chainwork:$work,
          local_mempool:$local,observers:$observers,
          observer_chains_stable_and_cover_candidate_tip:true}' >"$output" || return 1
    chmod 600 "$output" && sync -f "$output" || return 1
    rm -f -- "$tmp" "${tmp}."*
}

capture_claim_sample()
{
    local sample="$1" tip="$2" tmp
    tmp=$(mktemp "${OPS}/.claim-sample.XXXXXX") || return 1
    rpc listtransactions '*' 1000000 0 true | jq -S '
      [.[] | select(.comment == "PoW Claim" or
        has("qq_shadow_pow_lineage_schema") or has("qq_shadow_pow_lineage_root"))] |
      unique_by(.txid) | sort_by(.qq_shadow_pow_lineage_ordinal | tonumber)
    ' >"${tmp}.claims" || return 1
    jq -S -n --argjson sample "$sample" --arg tip "$tip" \
        --slurpfile claims "${tmp}.claims" \
        '{sample:$sample,tip:$tip,claims:$claims[0]}' \
        >"${EVIDENCE}/candidate-claims-sample-${sample}.json" || return 1
    rm -f -- "$tmp" "${tmp}.claims"
}

collect_stable_envelope()
{
    local sample="$1" epoch="$2" output="$3" tmp isolation isolation_sha
    tmp=$(mktemp "${OPS}/.envelope.XXXXXX") || return 1
    isolation="${EVIDENCE}/candidate-isolation-sample-${sample}.json"
    for _ in $(seq 1 120); do
        rpc getblockchaininfo >"${tmp}.chain1"
        rpc getpowclaimrecoveryinfo true >"${tmp}.recovery1"
        rpc getpowmininginfo >"${tmp}.mining1"
        rpc getstakinginfo >"${tmp}.staking"
        rpc getwalletinfo >"${tmp}.wallet"
        rpc getnetworkinfo >"${tmp}.network"
        rpc listwallets >"${tmp}.wallets"
        rpc getrawmempool true >"${tmp}.mempool"
        rpc getpowmininginfo >"${tmp}.mining2"
        rpc getpowclaimrecoveryinfo true >"${tmp}.recovery2"
        rpc getblockchaininfo >"${tmp}.chain2"
        observer_mempools_are_available || return 1
        capture_nonpublication "$isolation" || return 1
        isolation_sha=$(sha256sum "$isolation" | awk '{print $1}') || return 1
        jq -S -n --argjson sample "$sample" --argjson epoch "$epoch" \
            --argjson observed "$(date +%s)" \
            --arg isolation_sha "$isolation_sha" \
            --argjson fee "$baseline_recovery_fee" \
            --argjson manual "$baseline_pending_manual" \
            --argjson automatic "$baseline_pending_automatic" \
            --argjson recovery_metrics "$baseline_recovery_metrics_json" \
            --arg recovery_metrics_sha "$baseline_recovery_metrics_sha" \
            --slurpfile chain1 "${tmp}.chain1" --slurpfile chain2 "${tmp}.chain2" \
            --slurpfile recovery1 "${tmp}.recovery1" --slurpfile recovery2 "${tmp}.recovery2" \
            --slurpfile mining1 "${tmp}.mining1" --slurpfile mining2 "${tmp}.mining2" \
            --slurpfile staking "${tmp}.staking" --slurpfile wallet "${tmp}.wallet" \
            --slurpfile network "${tmp}.network" --slurpfile wallets "${tmp}.wallets" \
            --slurpfile mempool "${tmp}.mempool" '
            {schema:3,phase:"A",sample:$sample,observed_epoch:$observed,
             restart_epoch:$epoch,
             chain_before:$chain1[0],chain_after:$chain2[0],
             recovery_before:$recovery1[0],recovery_after:$recovery2[0],
             mining_before:$mining1[0],mining_after:$mining2[0],
             mempool_verbose:$mempool[0],
             staking:$staking[0],wallet:$wallet[0],network:$network[0],
             wallets:$wallets[0],expected_recovery_fee:$fee,
             isolation_continuously_valid:true,observer_status:"observed_absent",
             isolation_sha256:$isolation_sha,
             expected_pending_manual:$manual,expected_pending_automatic:$automatic}
             | . + {expected_recovery_metrics:$recovery_metrics,
               expected_recovery_metrics_sha256:$recovery_metrics_sha}
        ' >"$tmp"
        if hotfix_phase_a_envelope_json_is_valid "$(<"$tmp")" &&
           recovery_metrics_match_baseline "${tmp}.recovery1" &&
           recovery_metrics_match_baseline "${tmp}.recovery2" &&
           jq -e '.mining_before.claims_submitted == 0 and
             .mining_after.claims_submitted == 0 and
             (.isolation_sha256 | test("^[0-9a-f]{64}$"))' "$tmp" >/dev/null &&
           hotfix_nonpublication_file_is_valid "$isolation" "$run_nonce"; then
            capture_claim_sample "$sample" "$(jq -er '.chain_before.bestblockhash' "$tmp")" ||
                return 1
            if append_tx_visibility_sample "$sample" "$(<"${tmp}.chain1")" \
                   "${tmp}.visibility" &&
               rpc getpowmininginfo >"${tmp}.mining3" &&
               rpc getpowclaimrecoveryinfo true >"${tmp}.recovery3" &&
               rpc getblockchaininfo >"${tmp}.chain3" &&
               jq -e -n --slurpfile chain1 "${tmp}.chain1" \
                 --slurpfile chain3 "${tmp}.chain3" \
                 --slurpfile mining3 "${tmp}.mining3" \
                 --slurpfile recovery3 "${tmp}.recovery3" '
                   $chain1[0].bestblockhash == $chain3[0].bestblockhash and
                   $chain1[0].chainwork == $chain3[0].chainwork and
                   $chain1[0].blocks == $chain3[0].blocks and
                   $mining3[0].claim_inventory_tip == $chain1[0].bestblockhash and
                   $mining3[0].claims_submitted == 0 and
                   $recovery3[0].active_tip == $chain1[0].bestblockhash
                 ' >/dev/null &&
               hotfix_candidate_pow_json_is_valid "$(<"${tmp}.mining3")" active &&
               hotfix_candidate_recovery_json_is_valid "$(<"${tmp}.recovery3")" \
                 "$baseline_recovery_fee" &&
               recovery_metrics_match_baseline "${tmp}.recovery3"; then
                jq -S --slurpfile chain "${tmp}.chain3" \
                    --slurpfile mining "${tmp}.mining3" \
                    --slurpfile recovery "${tmp}.recovery3" '
                    . + {post_claim_chain:$chain[0],post_claim_mining:$mining[0],
                      post_claim_recovery:$recovery[0],stable_cut_completed:true}
                ' "${tmp}.visibility" >"${tmp}.visibility-bound" || return 1
                install -m 600 -o root -g root "$tmp" "$output" || return 1
                install -m 600 -o root -g root "${tmp}.visibility-bound" \
                    "${EVIDENCE}/candidate-visibility-sample-${sample}.json" || return 1
                rm -f -- "${tmp}."* "$tmp"
                return 0
            fi
        fi
        sleep 2
    done
    rm -f -- "${tmp}."* "$tmp"
    return 1
}

collect_progress_across_restart()
{
    local sample previous_height previous_tip previous_work deadline envelope progress_tmp
    collect_stable_envelope 1 1 "${EVIDENCE}/candidate-envelope-1.json" || return 1
    rpc setpowmining false 1 1 false >"${EVIDENCE}/candidate-pre-restart-pow-stop.json"
    rpc walletlock >"${EVIDENCE}/candidate-pre-restart-wallet-lock.json"
    docker restart -t 300 "$CONTAINER" >/dev/null
    wait_rpc || return 1
    capture_invocation A "$CANDIDATE_IMAGE_ID" "${EVIDENCE}/candidate-created-stopped.json" \
        "${EVIDENCE}/candidate-invocation-restart.json" || return 1
    assert_setup_processes || return 1
    disable_phase_a_interactive_surfaces || return 1
    capture_nonpublication "${EVIDENCE}/phase-a-nonpublication-restart-preunlock.json" || return 1
    run_unlock_helper || return 1
    rpc getstakinginfo | jq -e '.enabled == false and .staking == false and .worker_running == false' \
        >/dev/null || return 1
    rpc setpowmining true 1 1 false >"${EVIDENCE}/candidate-post-restart-pow-start.json"
    previous_height=$(jq -er '.chain_before.blocks' "${EVIDENCE}/candidate-envelope-1.json")
    previous_tip=$(jq -er '.chain_before.bestblockhash' "${EVIDENCE}/candidate-envelope-1.json")
    previous_work=$(jq -er '.chain_before.chainwork' "${EVIDENCE}/candidate-envelope-1.json")
    deadline=$((SECONDS + 2700))
    for sample in 2 3 4; do
        while (( SECONDS < deadline )); do
            envelope="${EVIDENCE}/candidate-envelope-${sample}.json"
            if collect_stable_envelope "$sample" 2 "$envelope" &&
               [[ "$(jq -er '.chain_before.blocks' "$envelope")" -gt "$previous_height" ]] &&
               [[ "$(jq -er '.chain_before.bestblockhash' "$envelope")" != "$previous_tip" ]] &&
               [[ "$(jq -er '.chain_before.chainwork' "$envelope")" > "$previous_work" ]]; then
                previous_height=$(jq -er '.chain_before.blocks' "$envelope")
                previous_tip=$(jq -er '.chain_before.bestblockhash' "$envelope")
                previous_work=$(jq -er '.chain_before.chainwork' "$envelope")
                break
            fi
            rm -f -- "$envelope"
            sleep 5
        done
        [[ -f "${EVIDENCE}/candidate-envelope-${sample}.json" ]] || return 1
    done
    : >"${EVIDENCE}/tx-visibility-samples.jsonl"
    for sample in 1 2 3 4; do
        cat "${EVIDENCE}/candidate-visibility-sample-${sample}.json" \
            >>"${EVIDENCE}/tx-visibility-samples.jsonl" || return 1
    done
    sync -f "${EVIDENCE}/tx-visibility-samples.jsonl"
    progress_tmp=$(mktemp "${OPS}/.candidate-progress.XXXXXX") || return 1
    jq -S -n --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" --arg nonce "$run_nonce" \
        --arg i1 "$(sha256sum "${EVIDENCE}/candidate-isolation-sample-1.json" | awk '{print $1}')" \
        --arg i2 "$(sha256sum "${EVIDENCE}/candidate-isolation-sample-2.json" | awk '{print $1}')" \
        --arg i3 "$(sha256sum "${EVIDENCE}/candidate-isolation-sample-3.json" | awk '{print $1}')" \
        --arg i4 "$(sha256sum "${EVIDENCE}/candidate-isolation-sample-4.json" | awk '{print $1}')" \
        --arg v1 "$(sha256sum "${EVIDENCE}/candidate-visibility-sample-1.json" | awk '{print $1}')" \
        --arg v2 "$(sha256sum "${EVIDENCE}/candidate-visibility-sample-2.json" | awk '{print $1}')" \
        --arg v3 "$(sha256sum "${EVIDENCE}/candidate-visibility-sample-3.json" | awk '{print $1}')" \
        --arg v4 "$(sha256sum "${EVIDENCE}/candidate-visibility-sample-4.json" | awk '{print $1}')" \
        --slurpfile e1 "${EVIDENCE}/candidate-envelope-1.json" \
        --slurpfile e2 "${EVIDENCE}/candidate-envelope-2.json" \
        --slurpfile e3 "${EVIDENCE}/candidate-envelope-3.json" \
        --slurpfile e4 "${EVIDENCE}/candidate-envelope-4.json" '
        {schema:3,phase:"A",run_nonce:$nonce,candidate_source_sha:$source,
         envelopes:[$e1[0],$e2[0],$e3[0],$e4[0]],tip_changes:3,
         hard_flags_continuous:true,pos_disabled_continuous:true,
         nonpublication_continuous:true,interactive_surfaces_stopped_continuously:true,
         worker_only_pow:true,lineage_continuation_tips:3,
         isolation_sample_sha256s:[$i1,$i2,$i3,$i4],
         visibility_sample_sha256s:[$v1,$v2,$v3,$v4],
         per_epoch_claims_submitted_zero:
           ([$e1[0],$e2[0],$e3[0],$e4[0]] |
             all(.mining_before.claims_submitted == 0 and
               .mining_after.claims_submitted == 0)),
         bounded_worker_tip_progress:true,single_positive_hash_sample_required:false,
         wait_for_next_tip_required_for_liveness:false,
         zero_hash_max_no_progress_tip_transitions:1}
    ' >"$progress_tmp"
    jq -e '.per_epoch_claims_submitted_zero == true and
      (.isolation_sample_sha256s | length == 4 and
       all(.[]; test("^[0-9a-f]{64}$"))) and
      (.visibility_sample_sha256s | length == 4 and
       all(.[]; test("^[0-9a-f]{64}$")))' "$progress_tmp" >/dev/null || return 1
    hotfix_phase_a_progress_file_is_valid "$progress_tmp" || return 1
    mv -fT -- "$progress_tmp" "$CANDIDATE_PROGRESS"
}

observer_chain_covers_terminal()
{
    local terminal="$1" observer_chain="$2" terminal_work observer_work
    jq -e '
      def hex64: type == "string" and test("^[0-9a-f]{64}$");
      .chain == "main" and .initialblockdownload == false and .blocks == .headers and
      (.blocks | type == "number" and floor == . and . >= 0) and
      (.bestblockhash | hex64) and (.chainwork | hex64)
    ' <<<"$terminal" >/dev/null || return 1
    jq -e '
      def hex64: type == "string" and test("^[0-9a-f]{64}$");
      .chain == "main" and .initialblockdownload == false and .blocks == .headers and
      (.blocks | type == "number" and floor == . and . >= 0) and
      (.bestblockhash | hex64) and (.chainwork | hex64)
    ' <<<"$observer_chain" >/dev/null || return 1
    terminal_work=$(jq -er '.chainwork' <<<"$terminal") || return 1
    observer_work=$(jq -er '.chainwork' <<<"$observer_chain") || return 1
    if [[ "$observer_work" == "$terminal_work" ]]; then
        [[ "$(jq -er '.bestblockhash' <<<"$observer_chain")" == \
           "$(jq -er '.bestblockhash' <<<"$terminal")" ]]
    else
        [[ "$observer_work" > "$terminal_work" ]]
    fi
}

capture_observer_terminal_proof()
{
    local terminal_chain="$1" anchor_txid="$2" anchor_vout="$3"
    local observer chain1 chain2 mempool anchor txid raw_error relation terminal_work observer_work
    : >"${EVIDENCE}/observer-mempools.jsonl"
    : >"${EVIDENCE}/observer-final-chain.jsonl"
    : >"${EVIDENCE}/observer-anchor-unspent.jsonl"
    : >"${EVIDENCE}/observer-tx-absence.jsonl"
    terminal_work=$(jq -er '.chainwork' <<<"$terminal_chain") || return 1
    for observer in blackcoin-v4-gui-26 blackcoin-v4-gui-28; do
        chain1=$(timeout -k 2 30 docker exec "$observer" "$CLI" -datadir="$DATADIR" \
            getblockchaininfo) || return 1
        observer_chain_covers_terminal "$terminal_chain" "$chain1" || return 1
        mempool=$(timeout -k 2 30 docker exec "$observer" "$CLI" -datadir="$DATADIR" \
            getrawmempool | jq -cS 'sort') || return 1
        jq -e --slurpfile ids "${EVIDENCE}/candidate-created-qqsproof-txids.json" '
          . as $observer_mempool |
          all($ids[0][]; . as $id | ($observer_mempool | index($id)) == null)
        ' <<<"$mempool" >/dev/null || return 1
        anchor=$(timeout -k 2 30 docker exec "$observer" "$CLI" -datadir="$DATADIR" \
            gettxout "$anchor_txid" "$anchor_vout" true) || return 1
        jq -e 'type == "object" and .confirmations >= 1 and .coinbase == false' \
            <<<"$anchor" >/dev/null || return 1
        while IFS= read -r txid; do
            if raw_error=$(timeout -k 2 30 docker exec "$observer" "$CLI" -datadir="$DATADIR" \
                getrawtransaction "$txid" true 2>&1); then
                return 1
            fi
            grep -Eq '(^|[^0-9])-5([^0-9]|$)' <<<"$raw_error" || return 1
            jq -cS -n --arg observer "$observer" --arg txid "$txid" \
                --arg anchor_txid "$anchor_txid" --argjson anchor_vout "$anchor_vout" '
                {observer:$observer,txid:$txid,status:"observed_absent",
                 mempool_absent:true,active_chain_absent:true,rpc_error_code:-5,
                 active_chain_absence_basis:"authenticated-anchor-unspent",
                 anchor:{txid:$anchor_txid,vout:$anchor_vout,unspent:true}}
            ' >>"${EVIDENCE}/observer-tx-absence.jsonl" || return 1
        done < <(jq -r '.[]' "${EVIDENCE}/candidate-created-qqsproof-txids.json")
        chain2=$(timeout -k 2 30 docker exec "$observer" "$CLI" -datadir="$DATADIR" \
            getblockchaininfo) || return 1
        jq -e -n --argjson a "$chain1" --argjson b "$chain2" '
          $a.bestblockhash == $b.bestblockhash and $a.chainwork == $b.chainwork and
          $a.blocks == $b.blocks and $a.headers == $b.headers
        ' >/dev/null || return 1
        observer_chain_covers_terminal "$terminal_chain" "$chain2" || return 1
        observer_work=$(jq -er '.chainwork' <<<"$chain2") || return 1
        if [[ "$observer_work" == "$terminal_work" ]]; then relation=same_terminal_tip
        else relation=terminal_superseded_by_greater_work
        fi
        jq -cS -n --arg observer "$observer" --arg relation "$relation" \
            --argjson before "$chain1" --argjson after "$chain2" '
            {observer:$observer,chain_before:$before,chain_after:$after,
             stable:true,terminal_relation:$relation}
        ' >>"${EVIDENCE}/observer-final-chain.jsonl" || return 1
        jq -cS -n --arg observer "$observer" --argjson txids "$mempool" \
            '{observer:$observer,txids:$txids}' >>"${EVIDENCE}/observer-mempools.jsonl" || return 1
        jq -cS -n --arg observer "$observer" --arg anchor_txid "$anchor_txid" \
            --argjson anchor_vout "$anchor_vout" --argjson txout "$anchor" '
            {observer:$observer,anchor:{txid:$anchor_txid,vout:$anchor_vout},
             unspent:true,txout:$txout}
        ' >>"${EVIDENCE}/observer-anchor-unspent.jsonl" || return 1
    done
}

capture_final_proof_inputs()
{
    local tmp chain1 chain2 pow2 staking2 recovery2 anchor_txid anchor_vout
    local expected_absence_rows mempool_rows chain_rows anchor_rows absence_rows final_cut_sha
    tmp=$(mktemp "${OPS}/.candidate-final-cut.XXXXXX") || return 1
    for _ in $(seq 1 60); do
        chain1=$(rpc getblockchaininfo) || return 1
        capture_wallet_state candidate-final || return 1
        rpc getpowmininginfo >"${EVIDENCE}/candidate-final-pow.json" || return 1
        rpc getstakinginfo >"${EVIDENCE}/candidate-final-staking.json" || return 1
        rpc getquantumkeyinventory | jq -S . \
            >"${EVIDENCE}/candidate-final-quantum-inventory.json" || return 1
        jq -S -n --slurpfile before "${EVIDENCE}/baseline-wallet-transactions.json" \
            --slurpfile after "${EVIDENCE}/candidate-final-wallet-transactions.json" '
            ($before[0] | map(.txid) | unique) as $old |
            [$after[0][] | .txid as $id |
              select(($old | index($id)) == null) |
              select(.comment == "PoW Claim" or has("qq_shadow_pow_lineage_schema") or
                has("qq_shadow_pow_lineage_root")) | $id] | unique | sort
        ' >"${EVIDENCE}/candidate-created-qqsproof-txids.json" || return 1
        jq -e 'type == "array" and length >= 4 and
          all(.[]; type == "string" and test("^[0-9a-f]{64}$")) and
          (unique | length) == length' \
          "${EVIDENCE}/candidate-created-qqsproof-txids.json" >/dev/null || return 1
        anchor_txid=$(jq -er --slurpfile ids \
            "${EVIDENCE}/candidate-created-qqsproof-txids.json" '
            [.component_details[]? | select(.anchor_authenticated == true and
              .anchor_unspent == true and
              ([$ids[0][] as $id | ((.claim_txids // []) | index($id) != null)] | all))] |
            select(length == 1) | .[0].anchor.txid |
            select(type == "string" and test("^[0-9a-f]{64}$"))
        ' "${EVIDENCE}/candidate-final-recovery-inventory.json") || return 1
        anchor_vout=$(jq -er --slurpfile ids \
            "${EVIDENCE}/candidate-created-qqsproof-txids.json" '
            [.component_details[]? | select(.anchor_authenticated == true and
              .anchor_unspent == true and
              ([$ids[0][] as $id | ((.claim_txids // []) | index($id) != null)] | all))] |
            select(length == 1) | .[0].anchor.vout |
            select(type == "number" and floor == . and . >= 0)
        ' "${EVIDENCE}/candidate-final-recovery-inventory.json") || return 1
        capture_observer_terminal_proof "$chain1" "$anchor_txid" "$anchor_vout" || {
            sleep 2
            continue
        }
        pow2=$(rpc getpowmininginfo) || return 1
        staking2=$(rpc getstakinginfo) || return 1
        recovery2=$(rpc getpowclaimrecoveryinfo true) || return 1
        chain2=$(rpc getblockchaininfo) || return 1
        if ! jq -e -n --argjson c1 "$chain1" --argjson c2 "$chain2" \
            --slurpfile recovery1 "${EVIDENCE}/candidate-final-recovery-inventory.json" \
            --argjson recovery2 "$recovery2" \
            --slurpfile pow1 "${EVIDENCE}/candidate-final-pow.json" --argjson pow2 "$pow2" '
            $c1.chain == "main" and $c1.initialblockdownload == false and
            $c1.blocks == $c1.headers and $c1.bestblockhash == $c2.bestblockhash and
            $c1.chainwork == $c2.chainwork and $c1.blocks == $c2.blocks and
            $recovery1[0].active_tip == $c1.bestblockhash and
            $recovery2.active_tip == $c1.bestblockhash and
            $recovery1[0].wallet_generation == $recovery2.wallet_generation and
            $pow1[0].claim_inventory_tip == $c1.bestblockhash and
            $pow2.claim_inventory_tip == $c1.bestblockhash and
            $pow1[0].claims_submitted == 0 and $pow2.claims_submitted == 0
        ' >/dev/null; then
            sleep 2
            continue
        fi
        hotfix_candidate_pow_json_is_valid "$(<"${EVIDENCE}/candidate-final-pow.json")" off || return 1
        hotfix_candidate_pow_json_is_valid "$pow2" off || return 1
        hotfix_phase_a_staking_json_is_disabled \
            "$(<"${EVIDENCE}/candidate-final-staking.json")" || return 1
        hotfix_phase_a_staking_json_is_disabled "$staking2" || return 1
        hotfix_candidate_recovery_json_is_valid \
            "$(<"${EVIDENCE}/candidate-final-recovery-inventory.json")" \
            "$baseline_recovery_fee" || return 1
        hotfix_candidate_recovery_json_is_valid "$recovery2" "$baseline_recovery_fee" || return 1
        recovery_metrics_match_baseline \
            "${EVIDENCE}/candidate-final-recovery-inventory.json" || return 1
        printf '%s\n' "$recovery2" >"${tmp}.recovery-final-after" || return 1
        recovery_metrics_match_baseline "${tmp}.recovery-final-after" || return 1
        jq -e --argjson manual "$baseline_pending_manual" \
            --argjson automatic "$baseline_pending_automatic" '
            .pending_manual_resolutions == $manual and
            .pending_automatic_resolutions == $automatic
        ' <<<"$recovery2" >/dev/null || return 1
        printf '%s\n' "$chain1" | jq -S . >"${EVIDENCE}/candidate-final-chain.json" || return 1
        printf '%s\n' "$chain2" | jq -S . >"${EVIDENCE}/candidate-final-chain-after.json" || return 1
        printf '%s\n' "$pow2" | jq -S . >"${EVIDENCE}/candidate-final-pow-after.json" || return 1
        printf '%s\n' "$staking2" | jq -S . \
            >"${EVIDENCE}/candidate-final-staking-after.json" || return 1
        printf '%s\n' "$recovery2" | jq -S . \
            >"${EVIDENCE}/candidate-final-recovery-after.json" || return 1
        rm -f -- "${tmp}.recovery-final-after"
        expected_absence_rows=$((2 * $(jq 'length' \
            "${EVIDENCE}/candidate-created-qqsproof-txids.json")))
        mempool_rows=$(wc -l <"${EVIDENCE}/observer-mempools.jsonl" | tr -d ' ')
        chain_rows=$(wc -l <"${EVIDENCE}/observer-final-chain.jsonl" | tr -d ' ')
        anchor_rows=$(wc -l <"${EVIDENCE}/observer-anchor-unspent.jsonl" | tr -d ' ')
        absence_rows=$(wc -l <"${EVIDENCE}/observer-tx-absence.jsonl" | tr -d ' ')
        [[ "$mempool_rows" == 2 && "$chain_rows" == 2 && "$anchor_rows" == 2 &&
           "$absence_rows" == "$expected_absence_rows" ]] || return 1
        jq -S -n --arg anchor_txid "$anchor_txid" --argjson anchor_vout "$anchor_vout" \
            --arg terminal_tip "$(jq -er '.bestblockhash' <<<"$chain1")" \
            --arg terminal_work "$(jq -er '.chainwork' <<<"$chain1")" \
            --slurpfile chains "${EVIDENCE}/observer-final-chain.jsonl" \
            --slurpfile anchors "${EVIDENCE}/observer-anchor-unspent.jsonl" \
            --slurpfile absence "${EVIDENCE}/observer-tx-absence.jsonl" '
            {schema:1,terminal_tip:$terminal_tip,terminal_chainwork:$terminal_work,
             anchor:{txid:$anchor_txid,vout:$anchor_vout},observer_chains:$chains,
             observer_anchors:$anchors,tx_absence:$absence,
             observers_stable_and_cover_terminal:true,
             authenticated_anchor_unspent_on_all_observers:true}
        ' >"${EVIDENCE}/observer-terminal-proof.json" || return 1
        final_cut_sha=$(sha256sum "${EVIDENCE}/observer-terminal-proof.json" | awk '{print $1}') || return 1
        jq -S -n --arg sha "$final_cut_sha" --arg tip "$(jq -er '.bestblockhash' <<<"$chain1")" \
            --arg work "$(jq -er '.chainwork' <<<"$chain1")" \
            --argjson generation "$(jq -er '.wallet_generation' <<<"$recovery2")" '
            {schema:1,stable:true,observer_terminal_proof_sha256:$sha,
             terminal_tip:$tip,terminal_chainwork:$work,wallet_generation:$generation}
        ' >"$tmp" || return 1
        install -m 600 -o root -g root "$tmp" "${EVIDENCE}/candidate-final-stable-cut.json" ||
            return 1
        rm -f -- "$tmp"
        return 0
    done
    rm -f -- "$tmp"
    return 1
}

build_no_recovery_spend_proof()
{
    local tmp forbidden rpc_sha payout_after quantum_after quantum_sha_after
    local fee_after cumulative_after pending_manual_after pending_automatic_after
    local recovery_metrics_after recovery_metrics_after_sha
    local observer_terminal_sha stable_cut_sha stopped_sha complete_log_sha log_receipt_sha
    local sample expected_visibility_sha actual_visibility_sha
    payout_after=$(jq -er '.payout_address | select(type == "string" and length > 0)' \
        "${EVIDENCE}/candidate-final-pow.json") || return 1
    quantum_after=$(jq -er '
        if type == "array" then length
        elif (.keys? | type) == "array" then (.keys | length)
        elif (.inventory? | type) == "array" then (.inventory | length)
        elif (.total? | type) == "number" then .total
        else error("unsupported quantum inventory") end
    ' "${EVIDENCE}/candidate-final-quantum-inventory.json") || return 1
    quantum_sha_after=$(sha256sum "${EVIDENCE}/candidate-final-quantum-inventory.json" | awk '{print $1}')
    fee_after=$(jq -er '.confirmed_resolution_fees' \
        "${EVIDENCE}/candidate-final-recovery-inventory.json") || return 1
    cumulative_after=$(jq -er '.cumulative_resolution_fees // .confirmed_resolution_fees' \
        "${EVIDENCE}/candidate-final-recovery-inventory.json") || return 1
    pending_manual_after=$(jq -er '.pending_manual_resolutions' \
        "${EVIDENCE}/candidate-final-recovery-inventory.json") || return 1
    pending_automatic_after=$(jq -er '.pending_automatic_resolutions' \
        "${EVIDENCE}/candidate-final-recovery-inventory.json") || return 1
    recovery_metrics_after=$(recovery_metrics_json \
        "${EVIDENCE}/candidate-final-recovery-inventory.json") || return 1
    recovery_metrics_after_sha=$(printf '%s' "$recovery_metrics_after" | sha256sum |
        awk '{print $1}') || return 1
    [[ "$recovery_metrics_after" == "$baseline_recovery_metrics_json" &&
       "$recovery_metrics_after_sha" == "$baseline_recovery_metrics_sha" ]] || return 1
    forbidden=$(grep -Ev '^(getblockchaininfo|getnetworkinfo|getpeerinfo|getpowclaimrecoveryinfo|getpowmininginfo|getquantumkeyinventory|getrawmempool|getstakinginfo|gettxout|getwalletinfo|listquantumaddresses|listtransactions|listunspent|listwallets|setpowmining:(true|false):1:1:false|staking:false|stop|validateaddress|walletlock)$' \
        "$RPC_METHODS_LOG" | sort -u || true)
    [[ -z "$forbidden" ]] || return 1
    install -m 600 -o root -g root "$RPC_METHODS_LOG" \
        "${EVIDENCE}/candidate-rpc-methods-through-proof.log" || return 1
    rpc_sha=$(sha256sum "${EVIDENCE}/candidate-rpc-methods-through-proof.log" | awk '{print $1}') || return 1
    grep -F 'retained a claim after relay failure' "${EVIDENCE}/candidate-complete.log" >/dev/null || return 1
    grep -F 'persisted without relay' "${EVIDENCE}/candidate-complete.log" >/dev/null || return 1
    jq -e --arg image "$CANDIDATE_IMAGE_ID" '
      .running == false and .exit_code == 0 and .image_id == $image
    ' "${EVIDENCE}/candidate-stopped.json" >/dev/null || return 1
    observer_terminal_sha=$(sha256sum "${EVIDENCE}/observer-terminal-proof.json" |
        awk '{print $1}') || return 1
    stable_cut_sha=$(sha256sum "${EVIDENCE}/candidate-final-stable-cut.json" |
        awk '{print $1}') || return 1
    stopped_sha=$(sha256sum "${EVIDENCE}/candidate-stopped.json" | awk '{print $1}') || return 1
    complete_log_sha=$(sha256sum "${EVIDENCE}/candidate-complete.log" | awk '{print $1}') || return 1
    log_receipt_sha=$(sha256sum "${EVIDENCE}/candidate-post-stop-log-receipt.json" |
        awk '{print $1}') || return 1
    jq -e --arg stopped "$stopped_sha" --arg log "$complete_log_sha" '
      .schema == 1 and .candidate_stopped_receipt_sha256 == $stopped and
      .complete_log_sha256 == $log and .captured_after_clean_stop == true
    ' "${EVIDENCE}/candidate-post-stop-log-receipt.json" >/dev/null || return 1
    jq -e --arg observer_sha "$observer_terminal_sha" '
      .schema == 1 and .stable == true and
      .observer_terminal_proof_sha256 == $observer_sha
    ' "${EVIDENCE}/candidate-final-stable-cut.json" >/dev/null || return 1
    for sample in 1 2 3 4; do
        expected_visibility_sha=$(jq -er --argjson index "$((sample - 1))" \
            '.visibility_sample_sha256s[$index]' "$CANDIDATE_PROGRESS") || return 1
        actual_visibility_sha=$(sha256sum \
            "${EVIDENCE}/candidate-visibility-sample-${sample}.json" |
            awk '{print $1}') || return 1
        [[ "$expected_visibility_sha" == "$actual_visibility_sha" ]] || return 1
    done
    tmp=$(mktemp "${OPS}/.no-recovery-spend.XXXXXX") || return 1
    jq -S -n --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" \
        --arg payout_before "$baseline_payout" --arg payout_after "$payout_after" \
        --argjson quantum_before "$baseline_quantum_key_count" --argjson quantum_after "$quantum_after" \
        --arg quantum_sha_before "$(sha256sum "${EVIDENCE}/baseline-quantum-inventory.json" | awk '{print $1}')" \
        --arg quantum_sha_after "$quantum_sha_after" \
        --argjson fee_before "$baseline_recovery_fee" --argjson fee_after "$fee_after" \
        --argjson cumulative_before "$baseline_cumulative_recovery_fee" \
        --argjson cumulative_after "$cumulative_after" \
        --argjson pending_manual_before "$baseline_pending_manual" \
        --argjson pending_manual_after "$pending_manual_after" \
        --argjson pending_automatic_before "$baseline_pending_automatic" \
        --argjson pending_automatic_after "$pending_automatic_after" \
        --arg recovery_metrics_before "$baseline_recovery_metrics_sha" \
        --arg recovery_metrics_after "$recovery_metrics_after_sha" \
        --arg rpc_sha "$rpc_sha" --arg nonce "$run_nonce" --arg zero "$HOTFIX_ZERO_TXID" \
        --arg observer_terminal_sha "$observer_terminal_sha" \
        --arg stable_cut_sha "$stable_cut_sha" --arg stopped_sha "$stopped_sha" \
        --arg complete_log_sha "$complete_log_sha" --arg log_receipt_sha "$log_receipt_sha" \
        --slurpfile before "${EVIDENCE}/prelaunch-wallet-transactions.json" \
        --slurpfile after "${EVIDENCE}/candidate-final-wallet-transactions.json" \
        --slurpfile mempool "${EVIDENCE}/candidate-final-mempool.json" \
        --slurpfile observers "${EVIDENCE}/observer-mempools.jsonl" \
        --slurpfile observer_absence "${EVIDENCE}/observer-tx-absence.jsonl" \
        --slurpfile visibility "${EVIDENCE}/tx-visibility-samples.jsonl" \
        --slurpfile sample1 "${EVIDENCE}/candidate-claims-sample-1.json" \
        --slurpfile sample2 "${EVIDENCE}/candidate-claims-sample-2.json" \
        --slurpfile sample3 "${EVIDENCE}/candidate-claims-sample-3.json" \
        --slurpfile sample4 "${EVIDENCE}/candidate-claims-sample-4.json" \
        --slurpfile mining "${EVIDENCE}/candidate-final-pow.json" \
        --slurpfile recovery "${EVIDENCE}/candidate-final-recovery-inventory.json" \
        --slurpfile progress "$CANDIDATE_PROGRESS" \
        --slurpfile stable_cut "${EVIDENCE}/candidate-final-stable-cut.json" \
        --slurpfile observer_terminal "${EVIDENCE}/observer-terminal-proof.json" \
        --slurpfile outpoints_before "${EVIDENCE}/prelaunch-wallet-outpoints.json" \
        --slurpfile outpoints_after "${EVIDENCE}/candidate-final-wallet-outpoints.json" \
        --slurpfile resolution_before "${EVIDENCE}/prelaunch-resolution-txids.json" \
        --slurpfile resolution_after "${EVIDENCE}/candidate-final-resolution-txids.json" \
        --slurpfile component_before "${EVIDENCE}/prelaunch-component-resolution-txids.json" \
        --slurpfile component_after "${EVIDENCE}/candidate-final-component-resolution-txids.json" '
        def qq: (.comment == "PoW Claim" or has("qq_shadow_pow_lineage_schema") or
          has("qq_shadow_pow_lineage_root"));
        def outpoint_key: [.txid,.vout] | @json;
        def static_wallet_record:
          del(.confirmations,.blockhash,.blockheight,.blockindex,.blocktime,
            .trusted,.walletconflicts);
        ($before[0] | map(.txid) | unique) as $old |
        ($before[0] | map(static_wallet_record) |
          sort_by([.txid,(.vout // -1),(.category // ""),(.address // ""),
            (.amount // 0),(.fee // 0)])) as $old_static |
        ($after[0] | map(. as $row | select($old | index($row.txid)) |
          static_wallet_record) |
          sort_by([.txid,(.vout // -1),(.category // ""),(.address // ""),
            (.amount // 0),(.fee // 0)])) as $existing_after_static |
        ($after[0] | map(. as $row | select(($old | index($row.txid)) == null))) as $new_rows |
        ($new_rows | map(.txid) | unique) as $new_txids |
        ($new_rows | map(select(qq)) | unique_by(.txid) |
          sort_by(.qq_shadow_pow_lineage_ordinal|tonumber)) as $claims |
        ($claims | map(.txid)) as $txids |
        ([$sample1[0],$sample2[0],$sample3[0],$sample4[0]]) as $claim_samples |
        ($progress[0].envelopes | map(.chain_before.bestblockhash)) as $progress_tips |
        ($claim_samples | map(.tip)) as $sample_tips |
        (($visibility | map(.sample)) == [1,2,3,4] and
          ($visibility | map(.candidate_tip)) == $progress_tips and
          ($visibility | all(.observer_chains_stable_and_cover_candidate_tip == true and
            .stable_cut_completed == true and
            .post_claim_chain.bestblockhash == .candidate_tip and
            .post_claim_mining.claim_inventory_tip == .candidate_tip and
            .post_claim_mining.claims_submitted == 0 and
            .post_claim_recovery.active_tip == .candidate_tip and
            (.observers | length) == 2 and
            all(.observers[]; .stable == true and
              (.terminal_relation == "same_terminal_tip" or
               .terminal_relation == "terminal_superseded_by_greater_work"))))) as
          $visibility_bound |
        ($claim_samples | map([.claims[] as $claim |
          select(($old | index($claim.txid)) == null) | $claim.txid] |
          unique | sort)) as $sample_new_txid_sets |
        ([range(1; $sample_new_txid_sets|length) as $i |
          (($sample_new_txid_sets[$i-1] - $sample_new_txid_sets[$i]) | length) == 0] |
          all) as $samples_monotonic |
        ([range(0; $progress_tips|length) as $i |
          ([$claims[] | select(.qq_shadow_pow_created_tip == $progress_tips[$i]) |
            .txid]) as $created |
          ($created|length) == 1 and
          (($sample_new_txid_sets[$i] | index($created[0])) != null)] |
          all) as $progress_lineage_bound |
        ([$recovery[0].component_details[]? | . as $component |
          select([$txids[] as $id |
            (($component.claim_txids // []) | index($id)) != null] | all)]) as $components |
        ($components[0] // {}) as $component |
        ($component.nodes // []) as $nodes |
        ([$txids[] as $id | $nodes[]? | select(.txid == $id)]) as $candidate_nodes |
        ([$candidate_nodes[] | select(.expired_locally_retired == true) | .txid] |
          unique | sort) as $candidate_retired_member_txids |
        ([$visibility[] | .local_mempool[] as $seen |
          select($txids | index($seen) != null) | $seen] | unique) as $sample_local_hits |
        ([$visibility[] | .observers[].txids[] as $seen |
          select($txids | index($seen) != null) | $seen] | unique) as $sample_observer_hits |
        ([$txids[] as $id | select($mempool[0] | index($id) != null) | $id]) as $final_local_hits |
        ([$txids[] as $id | select(any($observers[]; .txids | index($id) != null)) | $id])
          as $final_observer_hits |
        ([$txids[] as $id | select(
          ([$observer_absence[] | select(.txid == $id and .status == "observed_absent" and
             .mempool_absent == true and .active_chain_absent == true and
             .active_chain_absence_basis == "authenticated-anchor-unspent" and
             .anchor.unspent == true and .anchor.txid == $component.anchor.txid and
             .anchor.vout == $component.anchor.vout and .rpc_error_code == -5) |
             .observer] | unique | length) != 2) | $id]) as $unclassifiable |
        ($outpoints_before[0] | map(outpoint_key) | unique) as $before_outpoint_keys |
        ($outpoints_after[0] | map(outpoint_key) | unique) as $after_outpoint_keys |
        ([$before_outpoint_keys[] as $key |
          select(($after_outpoint_keys | index($key)) == null) | $key]) as $removed_outpoints |
        ([$after_outpoint_keys[] as $key |
          select(($before_outpoint_keys | index($key)) == null) | $key]) as $added_outpoints |
        ($claims | map(.qq_shadow_pow_created_tip) | unique | length) as $tip_span |
        {schema:3,phase:"A",run_nonce:$nonce,candidate_source_sha:$source,
         final_order:["tip-proof","pow-stop-joined",
           "wallet-claim-mempool-observer-proof","wallet-locked",
           "candidate-clean-stop","logs-complete-through-stop"],
         pow_worker_joined:true,final_pow_enabled:false,final_pow_hashrate:0,
         logs_complete_through_stop:true,wallet_locked:true,candidate_cleanly_stopped:true,
         candidate_stopped_receipt_sha256:$stopped_sha,
         candidate_complete_log_sha256:$complete_log_sha,
         candidate_post_stop_log_receipt_sha256:$log_receipt_sha,
         observer_terminal_proof_sha256:$observer_terminal_sha,
         final_stable_cut_sha256:$stable_cut_sha,
         terminal_stable_cut_verified:
           ($stable_cut[0].stable == true and
            $stable_cut[0].observer_terminal_proof_sha256 == $observer_terminal_sha and
            $stable_cut[0].terminal_tip == $observer_terminal[0].terminal_tip and
            $stable_cut[0].terminal_chainwork == $observer_terminal[0].terminal_chainwork and
            $stable_cut[0].wallet_generation == $recovery[0].wallet_generation and
            $observer_terminal[0].observers_stable_and_cover_terminal == true and
            $observer_terminal[0].authenticated_anchor_unspent_on_all_observers == true),
         persisted_pending_worker_log_observed:true,persisted_without_relay_log_observed:true,
         candidate_claims_submitted:$mining[0].claims_submitted,
         candidate_mining_gate_coherent:$mining[0].mining_gate_coherent,
         candidate_mining_gate_database_ambiguous:$mining[0].mining_gate_database_ambiguous,
         candidate_mining_gate_unsafe_claims:$mining[0].mining_gate_unsafe_claims,
         candidate_mining_gate_unsafe_components:$mining[0].mining_gate_unsafe_components,
         candidate_recovery_database_ambiguous:$recovery[0].database_outcome_ambiguous,
         retired_claim_objects:$recovery[0].retired_claim_objects,
         retired_components:$recovery[0].retired_components,
         candidate_retired_member_txids:$candidate_retired_member_txids,
         hard_staking_disabled_continuously:true,
         interactive_surfaces_stopped_continuously:
           ($progress[0].interactive_surfaces_stopped_continuously == true),
         shared_namespace_rpc_auth_boundary_continuously_verified:true,
         coinstake_created_txids:[$new_rows[] |
           select((.generated // false) == true or .category == "immature") | .txid] | unique,
         network_visible_wallet_txids:($sample_observer_hits + $final_observer_hits | unique),
         fee_payments_authorized:false,
         automatic_recovery_authorized:false,recovery_rpc_invoked:false,
         sendrawtransaction_invoked:false,abandontransaction_invoked:false,
         payout_rotation_invoked:false,forbidden_rpc_methods:[],rpc_allowlist_enforced:true,
         unexpected_rpc_methods:[],rpc_methods_sha256:$rpc_sha,
         payout_address_before:$payout_before,payout_address_after:$payout_after,
         quantum_key_count_before:$quantum_before,quantum_key_count_after:$quantum_after,
         quantum_inventory_sha256_before:$quantum_sha_before,
         quantum_inventory_sha256_after:$quantum_sha_after,
         confirmed_resolution_fees_before:$fee_before,confirmed_resolution_fees_after:$fee_after,
         cumulative_resolution_fees_before:$cumulative_before,
         cumulative_resolution_fees_after:$cumulative_after,
         pending_manual_before:$pending_manual_before,pending_manual_after:$pending_manual_after,
         pending_automatic_before:$pending_automatic_before,
         pending_automatic_after:$pending_automatic_after,
         recovery_metrics_sha256_before:$recovery_metrics_before,
         recovery_metrics_sha256_after:$recovery_metrics_after,
         recovery_metrics_unchanged:($recovery_metrics_before == $recovery_metrics_after),
         resolution_txids_before:$resolution_before[0],resolution_txids_after:$resolution_after[0],
         component_resolution_txids_before:$component_before[0],
         component_resolution_txids_after:$component_after[0],
         candidate_created_qqsproof_txids:$txids,
         candidate_created_qqsproof_mempool_txids:($sample_local_hits + $final_local_hits | unique),
         candidate_created_qqsproof_confirmed_txids:[$claims[] | select((.confirmations // 0) != 0) | .txid],
         candidate_created_qqsproof_observer_txids:($sample_observer_hits + $final_observer_hits | unique),
         candidate_created_qqsproof_unclassifiable_txids:$unclassifiable,
         observer_status:(if ($unclassifiable|length)==0 then "observed_absent" else "unclassifiable" end),
         observer_samples:($visibility|length),continuous_absence_verified:
           (($visibility|length) == 4 and $visibility_bound and ($sample_local_hits|length)==0 and
            ($sample_observer_hits|length)==0 and ($unclassifiable|length)==0 and
            $observer_terminal[0].observers_stable_and_cover_terminal == true and
            $observer_terminal[0].authenticated_anchor_unspent_on_all_observers == true),
         initial_atomic_reservation_verified:([$txids[] as $id |
           ([$claim_samples[] | .claims[] | select(.txid == $id)]) as $seen |
           ($seen|length) > 0 and $seen[0].qq_shadow_pow_quarantine == "1" and
           ($seen[0] | has("qq_shadow_pow_first_quarantine_height") | not) and
           ($seen[0] | has("qq_shadow_pow_branch_quarantine_height") | not)] | all),
         new_nonclaim_wallet_transactions:[$new_txids[] as $id |
           select(($txids | index($id)) == null) | $id],
         abandoned_wallet_txids:[$new_rows[] | select((.abandoned // false) == true) | .txid] | unique,
         baseline_wallet_records_static_equal:($old_static == $existing_after_static),
         baseline_wallet_record_mutations:
           (if $old_static == $existing_after_static then []
            else [{before:$old_static,after:$existing_after_static}] end),
         progress_tips:$progress_tips,
         claim_sample_tips:$sample_tips,
         claim_samples_monotonic:$samples_monotonic,
         visibility_samples_bound_to_progress:$visibility_bound,
         progress_tips_bound_to_lineage:
           ($sample_tips == $progress_tips and $progress_lineage_bound and
            ($sample_new_txid_sets[-1] == ($txids|sort)) and
            ($txids|length) == ($progress_tips|length) and
            $progress[0].per_epoch_claims_submitted_zero == true),
         one_lineage_member_per_progress_tip:
           ($progress_lineage_bound and ($txids|length) == ($progress_tips|length)),
         final_claim_sample_complete:($sample_new_txid_sets[-1] == ($txids|sort)),
         distinct_anchor_consumption_observed:
           (($removed_outpoints|length) != 1 or ($added_outpoints|length) != 0 or
            $removed_outpoints[0] != ($component.anchor | outpoint_key)),
         lineage:{authenticated:(($components|length)==1 and
             $component.anchor_authenticated == true and $component.anchor_unspent == true and
             $component.all_claims_zero_payment_retirable == false and
             $component.all_claims_expired_locally_retired == false and
             $recovery[0].retired_claim_objects == 0 and
             $recovery[0].retired_components == 0 and
             $candidate_retired_member_txids == [] and
             $component.ordinary_or_mixed_txids == [] and $component.resolution_txids == [] and
             $sample_tips == $progress_tips and $samples_monotonic and $visibility_bound and
             $progress_lineage_bound and ($sample_new_txid_sets[-1] == ($txids|sort)) and
             ($txids|length) == ($progress_tips|length) and
             $progress[0].per_epoch_claims_submitted_zero == true and
             (($component.claim_txids|sort) == ($txids|sort)) and
             [$txids[] as $id | ($nodes | map(select(.txid == $id))) as $matched |
               ($matched|length)==1 and $matched[0].kind == "claim" and
               $matched[0].wallet_authored == true and
               $matched[0].lineage_metadata_present == true and
               $matched[0].lineage_metadata_valid == true and
               $matched[0].proof_origin_bound == true and
               $matched[0].proof_input_bound == true and
               $matched[0].expired_locally_retired == false and
               $matched[0].quarantined == true and $matched[0].in_mempool == false and
               $matched[0].active_chain_confirmed == false and
               $matched[0].abandoned == false] | all),
           anchor_txid:$component.anchor.txid,anchor_vout:$component.anchor.vout,
           family:$component.generation_fingerprint,
           root_txid:$claims[0].qq_shadow_pow_lineage_root,
           all_claims_zero_payment_retirable:
             $component.all_claims_zero_payment_retirable,
           all_claims_expired_locally_retired:
             $component.all_claims_expired_locally_retired,
           component_claim_txids:($component.claim_txids // [] | sort),
           members:[$claims[] | . as $claim | $claim.txid as $id |
             ($candidate_nodes | map(select(.txid == $id))) as $matched |
             {txid:$id,ordinal:($claim.qq_shadow_pow_lineage_ordinal|tonumber),
             parent_txid:(if ($claim.qq_shadow_pow_lineage_ordinal|tonumber)==0 then $zero
               else $claim.qq_shadow_pow_lineage_parent end),
             anchor_txid:$component.anchor.txid,anchor_vout:$component.anchor.vout,
             family:$claim.qq_shadow_pow_lineage_family,
             root_txid:$claim.qq_shadow_pow_lineage_root,
             created_tip:$claim.qq_shadow_pow_created_tip,
             quarantine_marker:$claim.qq_shadow_pow_quarantine,
             proof_origin_bound:$matched[0].proof_origin_bound,
             proof_input_bound:$matched[0].proof_input_bound,
             expired_locally_retired:$matched[0].expired_locally_retired,
             confirmations:($claim.confirmations // 0),abandoned:($claim.abandoned // false),
             in_local_mempool:($mempool[0] | index($id) != null),
             in_active_chain:(($claim.confirmations // 0) > 0),
             observer_absent:(([$observer_absence[] |
               select(.txid == $id and .status == "observed_absent") | .observer] |
               unique | length) == 2),
             first_quarantine_observation_present:has("qq_shadow_pow_first_quarantine_height"),
             branch_quarantine_observation_present:has("qq_shadow_pow_branch_quarantine_height")}],
           contiguous_parents:([range(1;$claims|length) as $i |
             $claims[$i].qq_shadow_pow_lineage_parent == $claims[$i-1].txid] | all),
           same_anchor:(($components|length)==1),
           same_family:($claims | all(.qq_shadow_pow_lineage_family == $component.generation_fingerprint)),
           same_root:($claims | all(.qq_shadow_pow_lineage_root == $claims[0].txid)),
           same_tip_duplicates:($claims | group_by(.qq_shadow_pow_created_tip) | any(length > 1)),
           tip_span:$tip_span},
         txid_differential_classified:
           (($new_txids|sort) == ($txids|sort) and $old_static == $existing_after_static),
         mempool_differential_classified:(($visibility|length) >= 4 and
           $visibility_bound and ($sample_local_hits|length)==0 and
           ($final_local_hits|length)==0),
         wallet_outpoint_differential_classified:(($removed_outpoints|length)==1 and
           ($added_outpoints|length)==0 and
           $removed_outpoints[0] == ($component.anchor | outpoint_key))}
    ' >"$tmp" || return 1
    hotfix_phase_a_claim_proof_file_is_valid "$tmp" || return 1
    mv -fT -- "$tmp" "$NO_RECOVERY_SPEND"
}

suspend_guard_authority()
{
    [[ -f "$ENABLE_GUARD_STARTS" && ! -L "$ENABLE_GUARD_STARTS" &&
       ! -s "$ENABLE_GUARD_STARTS" && ! -e "$SUSPENDED_START_MARKER" ]] || return 1
    mv -nT -- "$ENABLE_GUARD_STARTS" "$SUSPENDED_START_MARKER" || return 1
    [[ ! -e "$ENABLE_GUARD_STARTS" && ! -L "$ENABLE_GUARD_STARTS" ]] || return 1
    sync -f "$SUSPENDED_START_MARKER"
    sync -f "$STATE_ROOT"
    guard_starts_suspended=1
}

restore_guard_authority()
{
    [[ "$guard_starts_suspended" == 1 && -f "$SUSPENDED_START_MARKER" &&
       ! -L "$SUSPENDED_START_MARKER" && ! -s "$SUSPENDED_START_MARKER" &&
       ! -e "$ENABLE_GUARD_STARTS" ]] || return 1
    mv -nT -- "$SUSPENDED_START_MARKER" "$ENABLE_GUARD_STARTS" || return 1
    [[ ! -e "$SUSPENDED_START_MARKER" && ! -L "$SUSPENDED_START_MARKER" ]] || return 1
    sync -f "$ENABLE_GUARD_STARTS"
    sync -f "$STATE_ROOT"
    guard_starts_suspended=0
}

publish_maintenance_marker()
{
    local tmp nonce_tmp recovery_tmp state_tmp
    [[ ! -e "$MAINTENANCE_MARKER" && ! -L "$MAINTENANCE_MARKER" &&
       ! -e "$MAINTENANCE_NONCE" && ! -L "$MAINTENANCE_NONCE" &&
       ! -e "$GUARD_STATE" && ! -L "$GUARD_STATE" &&
       ! -e "$PHASE_STATE" && ! -L "$PHASE_STATE" &&
       ! -e "$CRASH_RECOVERY_PROCEDURE" && ! -L "$CRASH_RECOVERY_PROCEDURE" &&
       ! -e "$PROMOTION_MARKER" && ! -L "$PROMOTION_MARKER" ]] || return 1
    if ! hotfix_valid_nonce "$run_nonce"; then
        run_nonce=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n') || return 1
    fi
    hotfix_valid_nonce "$run_nonce" || return 1
    guard_nonce=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n') || return 1
    [[ "$guard_nonce" =~ ^[0-9a-f]{64}$ ]] || return 1
    nonce_tmp=$(mktemp "${OPS}/.maintenance-nonce.XXXXXX") || return 1
    printf '%s\n' "$guard_nonce" >"$nonce_tmp"
    chmod 600 "$nonce_tmp" && chown root:root "$nonce_tmp" && sync -f "$nonce_tmp" ||
        return 1
    mv -fT -- "$nonce_tmp" "$MAINTENANCE_NONCE" || return 1
    state_tmp=$(mktemp "${OPS}/.guard-state.XXXXXX") || return 1
    printf 'active\n' >"$state_tmp"
    chmod 600 "$state_tmp" && chown root:root "$state_tmp" && sync -f "$state_tmp" ||
        return 1
    mv -fT -- "$state_tmp" "$GUARD_STATE" || return 1
    sync -f "$GUARD_STATE" || return 1
    write_state PREFLIGHT || return 1
    recovery_tmp=$(mktemp "${OPS}/.crash-recovery.XXXXXX") || return 1
    jq -S -n --arg run "$OPS" --arg nonce "$run_nonce" --arg marker "$MAINTENANCE_MARKER" \
        --arg guard_nonce "$guard_nonce" --arg state "$PHASE_STATE" \
        --arg guard_state "$GUARD_STATE" --arg cert "$REWIND_SAFE" \
        --arg promotion "$PROMOTION_MARKER" '
        {schema:2,transaction:"v30.1.4-node27-phase-a",run_nonce:$nonce,
         guard_nonce:$guard_nonce,run_dir:$run,
         recovery_mode:"manual-audited-only",executable_recovery:false,
         maintenance_marker:$marker,state_file:$state,guard_state_file:$guard_state,
         rewind_safe_certificate:$cert,
         promotion_marker:$promotion,automatic_failure_action:"contain-stop-preserve",
         required_lock_order:["/run/blackcoin-endpoint-guard.lock",
           "/var/run/blackcoin-node-cutover.lock","/run/blackcoin-pow-quarantine-cycle.lock",
           "/var/run/blackcoin-wallet-runtime-guard.lock"],
         procedure:[
           "Keep maintenance and automatic-start suspension in place.",
           "Acquire the four locks in the recorded order and validate nonce and state.",
           "Never rewind from snapshot existence or a generic failure trap.",
           "A data rewind is permitted only after a stopped candidate has a positive independently verified nonce-bound REWIND_SAFE certificate and no promotion marker exists.",
           "Any unknown, network-visible wallet state, coinstake, observer ambiguity, certificate mismatch, or promotion marker requires containment and preservation.",
           "After a certified rewind, keep immutable v30.1.4 hard-quarantined and locked until chainwork and wallet processing catch up; destroy all four snapshots before restoring baseline policy."
         ]}
    ' >"$recovery_tmp" || return 1
    chmod 600 "$recovery_tmp" && chown root:root "$recovery_tmp" && \
        sync -f "$recovery_tmp" || return 1
    mv -fT -- "$recovery_tmp" "$CRASH_RECOVERY_PROCEDURE" || return 1
    sync -f "$CRASH_RECOVERY_PROCEDURE" || return 1
    tmp=$(mktemp "${STATE_ROOT}/.v3014-node27-maintenance.XXXXXX") || return 1
    jq -S -n --arg run "$OPS" --arg nonce "$guard_nonce" '
        {schema:1,transaction:"v30.1.4-node27-canary",state:"active",
         run_nonce:$nonce,run_dir:$run}
    ' >"$tmp" || return 1
    chmod 600 "$tmp" && chown root:root "$tmp" && sync -f "$tmp" || return 1
    mv -nT -- "$tmp" "$MAINTENANCE_MARKER" || return 1
    [[ ! -e "$tmp" ]] || return 1
    sync -f "$MAINTENANCE_MARKER" && sync -f "$STATE_ROOT" || return 1
    [[ -f "$MAINTENANCE_MARKER" && ! -L "$MAINTENANCE_MARKER" &&
       "$(stat -Lc '%u:%g:%a' "$MAINTENANCE_MARKER")" == 0:0:600 ]] || return 1
    maintenance_published=1
    jq -e --arg run "$OPS" --arg nonce "$guard_nonce" '
        . == {schema:1,transaction:"v30.1.4-node27-canary",state:"active",
              run_nonce:$nonce,run_dir:$run}
    ' "$MAINTENANCE_MARKER" >/dev/null || return 1
    [[ -f "$CRASH_RECOVERY_PROCEDURE" && ! -L "$CRASH_RECOVERY_PROCEDURE" &&
       "$(stat -Lc '%u:%g:%a' "$CRASH_RECOVERY_PROCEDURE" 2>/dev/null || true)" == 0:0:600 ]] ||
        return 1
}

remove_own_maintenance_marker()
{
    local nonce
    [[ "$maintenance_published" == 1 && -f "$MAINTENANCE_NONCE" &&
       ! -L "$MAINTENANCE_NONCE" ]] || return 1
    nonce=$(<"$MAINTENANCE_NONCE")
    [[ "$nonce" =~ ^[0-9a-f]{64}$ ]] || return 1
    [[ -f "$MAINTENANCE_MARKER" && ! -L "$MAINTENANCE_MARKER" &&
       "$(state_value)" == PHASE_A_PASSED && ! -e "$PROMOTION_MARKER" ]] || return 1
    jq -e --arg run "$OPS" --arg nonce "$nonce" '
        . == {schema:1,transaction:"v30.1.4-node27-canary",state:"active",
              run_nonce:$nonce,run_dir:$run}
    ' "$MAINTENANCE_MARKER" >/dev/null || return 1
    rm -f -- "$MAINTENANCE_MARKER"
    sync -f "$STATE_ROOT"
    maintenance_published=0
}

create_snapshot_set()
{
    local dataset snapshot guid txg row rows tmp
    [[ "$(state_value)" == BASELINE_COLD && ! -e "$PROMOTION_MARKER" ]] || return 1
    hotfix_phase_a_stable_stop_file_is_valid \
        "${EVIDENCE}/baseline-cold-stop-authority.json" baseline-pre-snapshot \
        "$IMMUTABLE_V3014_IMAGE_ID" "$IMMUTABLE_V3014_IMAGE_REF" || return 1
    stable_stop_receipt_matches_live "${EVIDENCE}/baseline-cold-stop-authority.json" || return 1
    rows='[]'
    zfs snapshot \
        "${EXPECTED_DATADIR_DATASET}@${SNAP}" \
        "${EXPECTED_BLOCKS_DATASET}@${SNAP}" \
        "${EXPECTED_INDEXES_DATASET}@${SNAP}" \
        "${EXPECTED_RAW_DATASET}@${SNAP}" || return 1
    snapshot_created=1
    for dataset in "$EXPECTED_DATADIR_DATASET" "$EXPECTED_BLOCKS_DATASET" \
        "$EXPECTED_INDEXES_DATASET" "$EXPECTED_RAW_DATASET"; do
        snapshot="${dataset}@${SNAP}"
        zfs hold "$HOLD" "$snapshot" || return 1
        guid=$(zfs get -Hp -o value guid "$snapshot") || return 1
        txg=$(zfs get -Hp -o value createtxg "$snapshot") || return 1
        row=$(jq -cn --arg dataset "$dataset" --arg snapshot "$snapshot" \
            --argjson guid "$guid" --argjson txg "$txg" --arg hold "$HOLD" \
            '{dataset:$dataset,snapshot:$snapshot,guid:$guid,creation_txg:$txg,
              hold_tag:$hold,hold_present:true}') || return 1
        rows=$(jq -cn --argjson rows "$rows" --argjson row "$row" '$rows + [$row]') || return 1
    done
    zpool sync "${EXPECTED_DATADIR_DATASET%%/*}"
    tmp=$(mktemp "${OPS}/.snapshot-set.XXXXXX") || return 1
    jq -S -n --arg nonce "$run_nonce" --argjson rows "$rows" \
        --arg stop_authority "$(sha256sum "${EVIDENCE}/baseline-cold-stop-authority.json" |
          awk '{print $1}')" '
        {schema:1,run_nonce:$nonce,baseline_stop_authority_sha256:$stop_authority,
         created_after_clean_stop:true,held:true,snapshots:$rows}' \
        >"$tmp" || return 1
    hotfix_snapshot_set_file_is_valid "$tmp" "$run_nonce" || return 1
    mv -fT -- "$tmp" "${EVIDENCE}/snapshot-set.json"
    snapshot_identity_sha=$(sha256sum "${EVIDENCE}/snapshot-set.json" | awk '{print $1}')
    write_state SNAPSHOT_SET_HELD
}

verify_snapshot_set()
{
    local row snapshot guid txg hold
    [[ "$snapshot_created" == 1 &&
       "$(sha256sum "${EVIDENCE}/snapshot-set.json" | awk '{print $1}')" == "$snapshot_identity_sha" ]] ||
        return 1
    hotfix_snapshot_set_file_is_valid "${EVIDENCE}/snapshot-set.json" "$run_nonce" || return 1
    [[ "$(jq -er '.baseline_stop_authority_sha256' "${EVIDENCE}/snapshot-set.json")" == \
       "$(sha256sum "${EVIDENCE}/baseline-cold-stop-authority.json" | awk '{print $1}')" ]] ||
        return 1
    while IFS= read -r row; do
        snapshot=$(jq -er '.snapshot' <<<"$row") || return 1
        guid=$(jq -er '.guid' <<<"$row") || return 1
        txg=$(jq -er '.creation_txg' <<<"$row") || return 1
        hold=$(jq -er '.hold_tag' <<<"$row") || return 1
        [[ "$hold" == "$HOLD" && "$(zfs get -Hp -o value guid "$snapshot")" == "$guid" &&
           "$(zfs get -Hp -o value createtxg "$snapshot")" == "$txg" &&
           "$(zfs holds -H "$snapshot" | awk -v tag="$HOLD" '$2 == tag {print $2}')" == "$HOLD" ]] ||
            return 1
    done < <(jq -ce '.snapshots[]' "${EVIDENCE}/snapshot-set.json")
}

snapshot_set_is_live_and_held()
{
    verify_snapshot_set
}

certified_rewind_snapshot_set()
{
    local order snapshot dataset diff cert_nonce
    [[ "$(state_value)" == REWIND_SAFE && -f "$REWIND_SAFE" && ! -L "$REWIND_SAFE" &&
       ! -e "$PROMOTION_MARKER" && "$(docker inspect -f '{{.State.Running}}' "$CONTAINER")" == false ]] ||
        return 1
    cert_nonce=$(jq -er '.run_nonce' "$REWIND_SAFE") || return 1
    [[ "$cert_nonce" == "$run_nonce" ]] || return 1
    verify_rewind_safe_bindings || return 1
    write_state REWIND_STARTED || return 1
    rewind_started=1
    order=$(mktemp "${OPS}/.rollback-order.XXXXXX") || return 1
    jq -r '.snapshots[].snapshot' "${EVIDENCE}/snapshot-set.json" |
        awk '{d=$0; sub(/@[^@]+$/, "", d); depth=gsub(/\//,"/",d); print depth "\t" $0}' |
        sort -t $'\t' -k1,1nr -k2,2 | cut -f2 >"$order" || return 1
    while IFS= read -r snapshot; do
        [[ ! -e "$PROMOTION_MARKER" && "$(state_value)" == REWIND_STARTED ]] || return 1
        verify_rewind_safe_bindings || return 1
        zfs rollback "$snapshot" || return 1
    done <"$order"
    verify_snapshot_set || return 1
    : >"${EVIDENCE}/zfs-restore-proof.tsv"
    while IFS= read -r snapshot; do
        dataset=${snapshot%@*}
        diff="${EVIDENCE}/zfs-diff-${dataset//\//__}.txt"
        zfs diff -FH "$snapshot" "$dataset" >"$diff" || return 1
        [[ ! -s "$diff" ]] || return 1
        printf '%s\tzero-diff\n' "$snapshot" >>"${EVIDENCE}/zfs-restore-proof.tsv"
    done < <(jq -r '.snapshots[].snapshot' "${EVIDENCE}/snapshot-set.json")
}

destroy_snapshot_set_after_catchup()
{
    local order snapshot tmp
    [[ "$(state_value)" == BASE_CAUGHT_UP ]] || return 1
    hotfix_base_catchup_file_is_valid "$BASE_CATCHUP_PROOF" "$run_nonce" || return 1
    verify_snapshot_set || return 1
    : >"${EVIDENCE}/snapshot-destroy-authority-rechecks.jsonl"
    verify_base_quarantine_destroy_authority || return 1
    order=$(mktemp "${OPS}/.destroy-order.XXXXXX") || return 1
    jq -r '.snapshots[].snapshot' "${EVIDENCE}/snapshot-set.json" |
        awk '{d=$0; sub(/@[^@]+$/, "", d); depth=gsub(/\//,"/",d); print depth "\t" $0}' |
        sort -t $'\t' -k1,1nr -k2,2 | cut -f2 >"$order" || return 1
    while IFS= read -r snapshot; do
        verify_base_quarantine_destroy_authority || return 1
        zfs release "$HOLD" "$snapshot" || return 1
        if ! verify_base_quarantine_destroy_authority; then
            zfs hold "$HOLD" "$snapshot" >/dev/null 2>&1 || true
            return 1
        fi
        [[ "$(state_value)" == BASE_CAUGHT_UP && ! -e "$PROMOTION_MARKER" ]] || {
            zfs hold "$HOLD" "$snapshot" >/dev/null 2>&1 || true
            return 1
        }
        zfs destroy "$snapshot" || return 1
    done <"$order"
    verify_base_quarantine_destroy_authority || return 1
    zpool sync "${EXPECTED_DATADIR_DATASET%%/*}"
    while IFS= read -r snapshot; do
        ! zfs list -H -t snapshot "$snapshot" >/dev/null 2>&1 || return 1
        [[ -z "$(zfs holds -H "$snapshot" 2>/dev/null || true)" ]] || return 1
    done <"$order"
    [[ "$(wc -l <"${EVIDENCE}/snapshot-destroy-authority-rechecks.jsonl" | tr -d ' ')" == 10 ]] ||
        return 1
    tmp=$(mktemp "${OPS}/.snapshot-absence.XXXXXX") || return 1
    jq -S -n --arg nonce "$run_nonce" \
        --arg set_sha "$(sha256sum "${EVIDENCE}/snapshot-set.json" | awk '{print $1}')" \
        --arg catchup_sha "$(sha256sum "$BASE_CATCHUP_PROOF" | awk '{print $1}')" \
        --arg authority_sha "$(sha256sum "${EVIDENCE}/snapshot-destroy-authority-rechecks.jsonl" | awk '{print $1}')" \
        --argjson authority_count "$(wc -l <"${EVIDENCE}/snapshot-destroy-authority-rechecks.jsonl" | tr -d ' ')" \
        --slurpfile set "${EVIDENCE}/snapshot-set.json" '
        {schema:1,run_nonce:$nonce,catchup_verified_before_release:true,
         snapshot_set_sha256:$set_sha,
         catchup_proof_sha256:$catchup_sha,
         authority_rechecks_sha256:$authority_sha,authority_recheck_count:$authority_count,
         authority_rechecked_before_every_release_and_destroy:true,
         snapshots:[$set[0].snapshots[] | {dataset,snapshot,hold_tag}],
         release_order:"child-before-parent",recursive_or_force_flags_used:false,
         all_holds_released:true,all_four_snapshots_destroyed:true,
         remaining_snapshots:[],remaining_holds:[]}
    ' >"$tmp" || return 1
    hotfix_snapshot_absence_file_is_valid "$tmp" "$run_nonce" || return 1
    chmod 600 "$tmp" && sync -f "$tmp" || return 1
    mv -fT -- "$tmp" "$SNAPSHOT_ABSENCE_PROOF" || return 1
    sync -f "$SNAPSHOT_ABSENCE_PROOF" && sync -f "$EVIDENCE" || return 1
    snapshot_created=0
    write_state SNAPSHOTS_ABSENT
}

wait_container_stopped()
{
    for _ in $(seq 1 180); do
        if [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)" != true ]]; then
            [[ "$(docker inspect -f '{{.State.ExitCode}}' "$CONTAINER" 2>/dev/null || true)" == 0 ]]
            return
        fi
        sleep 1
    done
    return 1
}

stop_with_restart_authority_disabled()
{
    local transition="$1" expected_id="$2" expected_ref="$3" receipt="$4" stop_output="$5"
    local before armed stopped_one stopped_two
    before=$(mktemp "${OPS}/.stable-stop-before.XXXXXX") || return 1
    armed=$(mktemp "${OPS}/.stable-stop-armed.XXXXXX") || return 1
    stopped_one=$(mktemp "${OPS}/.stable-stop-one.XXXXXX") || return 1
    stopped_two=$(mktemp "${OPS}/.stable-stop-two.XXXXXX") || return 1
    docker inspect "$CONTAINER" >"$before" || return 1
    jq -e --arg id "$expected_id" --arg ref "$expected_ref" '
      length==1 and .[0].Image==$id and .[0].Config.Image==$ref and
      .[0].State.Running==true and (. [0].Id | test("^[0-9a-f]{64}$"))
    ' "$before" >/dev/null || return 1
    docker update --restart=no "$CONTAINER" >/dev/null || return 1
    docker inspect "$CONTAINER" >"$armed" || return 1
    jq -e --arg id "$expected_id" --arg ref "$expected_ref" \
        --slurpfile before "$before" '
      ($before[0][0]) as $b | .[0] as $a |
      $a.Id==$b.Id and $a.Image==$id and $a.Config.Image==$ref and
      $a.State.Running==true and $a.State.StartedAt==$b.State.StartedAt and
      $a.RestartCount==$b.RestartCount and
      $a.HostConfig.RestartPolicy=={Name:"no",MaximumRetryCount:0}
    ' "$armed" >/dev/null || return 1
    rpc stop >"$stop_output" || return 1
    wait_container_stopped || return 1
    docker inspect "$CONTAINER" >"$stopped_one" || return 1
    sleep 2
    docker inspect "$CONTAINER" >"$stopped_two" || return 1
    jq -e --arg id "$expected_id" --arg ref "$expected_ref" \
        --slurpfile before "$before" --slurpfile armed "$armed" \
        --slurpfile one "$stopped_one" '
      ($before[0][0]) as $b | ($armed[0][0]) as $a | ($one[0][0]) as $x | .[0] as $y |
      $b.Id==$a.Id and $a.Id==$x.Id and $x.Id==$y.Id and
      $x.Image==$id and $y.Image==$id and $x.Config.Image==$ref and $y.Config.Image==$ref and
      $x.State.Running==false and $y.State.Running==false and
      $x.State.ExitCode==0 and $y.State.ExitCode==0 and
      $x.State.StartedAt==$y.State.StartedAt and $x.State.FinishedAt==$y.State.FinishedAt and
      $x.RestartCount==$y.RestartCount and
      $x.HostConfig.RestartPolicy=={Name:"no",MaximumRetryCount:0} and
      $y.HostConfig.RestartPolicy=={Name:"no",MaximumRetryCount:0}
    ' "$stopped_two" >/dev/null || return 1
    jq -S -n --arg transition "$transition" --arg id "$expected_id" --arg ref "$expected_ref" \
        --slurpfile before "$before" --slurpfile armed "$armed" \
        --slurpfile one "$stopped_one" --slurpfile two "$stopped_two" '
      ($before[0][0]) as $b | ($armed[0][0]) as $a |
      ($one[0][0]) as $x | ($two[0][0]) as $y |
      {schema:1,transition:$transition,container_id:$b.Id,image_id:$id,image_ref:$ref,
       original_restart_policy:$b.HostConfig.RestartPolicy,
       armed_restart_policy:$a.HostConfig.RestartPolicy,
       stopped_restart_policy_first:$x.HostConfig.RestartPolicy,
       stopped_restart_policy_second:$y.HostConfig.RestartPolicy,
       started_at_before:$b.State.StartedAt,started_at_armed:$a.State.StartedAt,
       stopped_started_at_first:$x.State.StartedAt,stopped_started_at_second:$y.State.StartedAt,
       stopped_finished_at_first:$x.State.FinishedAt,
       stopped_finished_at_second:$y.State.FinishedAt,
       restart_count_before:$b.RestartCount,restart_count_armed:$a.RestartCount,
       restart_count_stopped_first:$x.RestartCount,restart_count_stopped_second:$y.RestartCount,
       restart_authority_disabled_before_rpc_stop:true,clean_rpc_stop_completed:true,
       stable_stopped_samples:2,automatic_restart_observed:false}
    ' >"$receipt" || return 1
    hotfix_phase_a_stable_stop_file_is_valid "$receipt" "$transition" \
        "$expected_id" "$expected_ref" || return 1
    chmod 600 "$receipt" && chown root:root "$receipt" && sync -f "$receipt" || return 1
    rm -f -- "$before" "$armed" "$stopped_one" "$stopped_two"
}

stable_stop_receipt_matches_live()
{
    local receipt="$1" inspect_file
    inspect_file=$(mktemp "${OPS}/.stable-stop-current.XXXXXX") || return 1
    docker inspect "$CONTAINER" >"$inspect_file" || return 1
    jq -e -n --slurpfile receipt "$receipt" --slurpfile current "$inspect_file" '
      ($receipt[0]) as $r | ($current[0][0]) as $c |
      $c.Id==$r.container_id and $c.Image==$r.image_id and $c.Config.Image==$r.image_ref and
      $c.State.Running==false and $c.State.ExitCode==0 and
      $c.State.StartedAt==$r.stopped_started_at_second and
      $c.State.FinishedAt==$r.stopped_finished_at_second and
      $c.RestartCount==$r.restart_count_stopped_second and
      $c.HostConfig.RestartPolicy=={Name:"no",MaximumRetryCount:0}
    ' >/dev/null || return 1
    rm -f -- "$inspect_file"
}

stop_pow_join()
{
    local file="${EVIDENCE}/candidate-pow-joined.json"
    rpc setpowmining false 1 1 false >"${EVIDENCE}/candidate-pow-stop.json" || return 1
    for _ in $(seq 1 60); do
        rpc getpowmininginfo >"$file" || return 1
        if hotfix_candidate_pow_json_is_valid "$(<"$file")" off; then
            write_state POW_JOINED
            return
        fi
        sleep 1
    done
    return 1
}

stop_candidate_cleanly()
{
    rpc walletlock >"${EVIDENCE}/candidate-wallet-lock.json" || return 1
    rpc getwalletinfo >"${EVIDENCE}/candidate-wallet-locked.json" || return 1
    jq -e '.unlocked_until == 0' "${EVIDENCE}/candidate-wallet-locked.json" >/dev/null || return 1
    write_state WALLET_LOCKED || return 1
    stop_with_restart_authority_disabled candidate-terminal "$CANDIDATE_IMAGE_ID" \
        "$CANDIDATE_IMAGE" "${EVIDENCE}/candidate-stop-authority.json" \
        "${EVIDENCE}/candidate-stop.json" || return 1
    docker inspect "$CONTAINER" | jq -S '.[0] | {running:.State.Running,
      exit_code:.State.ExitCode,finished_at:.State.FinishedAt,image_id:.Image}' \
      >"${EVIDENCE}/candidate-stopped.json" || return 1
    jq -e --arg id "$CANDIDATE_IMAGE_ID" \
        '.running == false and .exit_code == 0 and .image_id == $id' \
        "${EVIDENCE}/candidate-stopped.json" >/dev/null || return 1
    write_state CANDIDATE_STOPPED
}

seal_pre_rewind_evidence()
{
    local target="${EVIDENCE}/PRE_REWIND_SHA256SUMS"
    rm -f -- "$target"
    (cd "$EVIDENCE" && find . -type f ! -name PRE_REWIND_SHA256SUMS ! -name SHA256SUMS \
        ! -name REWIND_SAFE.json ! -name RESULT.json -print0 | sort -z | xargs -0 sha256sum) \
        >"$target" || return 1
    chmod 600 "$target" && sync -f "$target"
    (cd "$EVIDENCE" && sha256sum --strict -c PRE_REWIND_SHA256SUMS >/dev/null)
}

issue_rewind_safe_certificate()
{
    local tmp terminal_tip terminal_height terminal_work generation txids
    [[ "$(state_value)" == PRE_REWIND_VERIFIED && ! -e "$PROMOTION_MARKER" ]] || return 1
    [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER")" == false ]] || return 1
    hotfix_phase_a_progress_file_is_valid "$CANDIDATE_PROGRESS" || return 1
    hotfix_phase_a_claim_proof_file_is_valid "$NO_RECOVERY_SPEND" || return 1
    hotfix_snapshot_set_file_is_valid "${EVIDENCE}/snapshot-set.json" "$run_nonce" || return 1
    hotfix_nonpublication_file_is_valid "${EVIDENCE}/phase-a-nonpublication-final.json" "$run_nonce" || return 1
    (cd "$EVIDENCE" && sha256sum --strict -c PRE_REWIND_SHA256SUMS >/dev/null) || return 1
    verify_phase_a_tooling_identity_live || return 1
    terminal_tip=$(jq -er '.terminal_tip' "${EVIDENCE}/candidate-final-stable-cut.json") || return 1
    terminal_height=$(jq -er '.blocks' "${EVIDENCE}/candidate-final-chain.json") || return 1
    terminal_work=$(jq -er '.terminal_chainwork' \
        "${EVIDENCE}/candidate-final-stable-cut.json") || return 1
    generation=$(jq -er '.wallet_generation' \
        "${EVIDENCE}/candidate-final-stable-cut.json") || return 1
    txids=$(jq -c '.candidate_created_qqsproof_txids' "$NO_RECOVERY_SPEND") || return 1
    jq -e --arg tip "$terminal_tip" --arg work "$terminal_work" \
        --argjson generation "$generation" --argjson txids "$txids" \
        --slurpfile chain "${EVIDENCE}/candidate-final-chain.json" \
        --slurpfile chain_after "${EVIDENCE}/candidate-final-chain-after.json" \
        --slurpfile recovery "${EVIDENCE}/candidate-final-recovery-inventory.json" \
        --slurpfile recovery_after "${EVIDENCE}/candidate-final-recovery-after.json" \
        --slurpfile observer "${EVIDENCE}/observer-terminal-proof.json" '
        .stable == true and .terminal_tip == $tip and .terminal_chainwork == $work and
        .wallet_generation == $generation and
        $chain[0].bestblockhash == $tip and $chain_after[0].bestblockhash == $tip and
        $chain[0].chainwork == $work and $chain_after[0].chainwork == $work and
        $recovery[0].active_tip == $tip and $recovery_after[0].active_tip == $tip and
        $recovery[0].wallet_generation == $generation and
        $recovery_after[0].wallet_generation == $generation and
        $observer[0].terminal_tip == $tip and $observer[0].terminal_chainwork == $work and
        $observer[0].observers_stable_and_cover_terminal == true and
        $observer[0].authenticated_anchor_unspent_on_all_observers == true and
        ([ $observer[0].tx_absence[].txid ] | unique | sort) == ($txids | sort)
    ' "${EVIDENCE}/candidate-final-stable-cut.json" >/dev/null || return 1
    tmp=$(mktemp "${OPS}/.rewind-safe.XXXXXX") || return 1
    jq -S -n --arg nonce "$run_nonce" --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" \
        --arg image_id "$CANDIDATE_IMAGE_ID" --arg tooling "$CANDIDATE_TOOLING_COMMIT" \
        --arg tooling_identity "$phase_a_tooling_identity_sha" \
        --arg package "$phase_a_package_sha" --arg phase_a_script "$phase_a_script_sha" \
        --arg phase_b_script "$phase_b_script_sha" --arg phase_a_verifier "$phase_a_verifier_sha" \
        --arg phase_a_contract "$phase_a_contract_sha" \
        --arg image_ref "$CANDIDATE_IMAGE" \
        --arg manifest_digest "$CANDIDATE_IMAGE_MANIFEST_DIGEST" \
        --arg qt "$CANDIDATE_BLACKCOIN_QT_SHA256" \
        --arg body "$HOTFIX_CANDIDATE_ENTRYPOINT_BODY_SHA256" \
        --arg invocation "$(sha256sum "${EVIDENCE}/candidate-invocation-restart.json" | awk '{print $1}')" \
        --arg helper "$(sha256sum "${EVIDENCE}/unlock-helper-audit.json" | awk '{print $1}')" \
        --arg isolation "$(sha256sum "${EVIDENCE}/phase-a-nonpublication-final.json" | awk '{print $1}')" \
        --arg snapshots "$(sha256sum "${EVIDENCE}/snapshot-set.json" | awk '{print $1}')" \
        --arg progress "$(sha256sum "$CANDIDATE_PROGRESS" | awk '{print $1}')" \
        --arg claim "$(sha256sum "$NO_RECOVERY_SPEND" | awk '{print $1}')" \
        --arg logs "$(sha256sum "${EVIDENCE}/candidate-complete.log" | awk '{print $1}')" \
        --arg rpc "$(sha256sum "${EVIDENCE}/candidate-rpc-methods-through-proof.log" | awk '{print $1}')" \
        --arg locks "$(sha256sum "${EVIDENCE}/locks.json" | awk '{print $1}')" \
        --arg guards "$(sha256sum "${EVIDENCE}/guard-source-identity.json" | awk '{print $1}')" \
        --arg pre_state "$(sha256sum "${EVIDENCE}/pre-rewind-state.json" | awk '{print $1}')" \
        --arg maintenance "$(sha256sum "$MAINTENANCE_MARKER" | awk '{print $1}')" \
        --arg verifier "$(sha256sum "${EVIDENCE}/pre-rewind-verifier.json" | awk '{print $1}')" \
        --arg compose "$EXPECTED_COMPOSE_SHA256" \
        --arg baseline_runtime "$(sha256sum "${EVIDENCE}/baseline-runtime-identity.json" | awk '{print $1}')" \
        --arg bundle_manifest "$(sha256sum "${EVIDENCE}/candidate-bundle-manifest.json" | awk '{print $1}')" \
        --arg oci_identity "$(sha256sum "${EVIDENCE}/candidate-oci-identity.json" | awk '{print $1}')" \
        --arg binary_sums "$(sha256sum "${EVIDENCE}/candidate-binary-sha256sums.txt" | awk '{print $1}')" \
        --arg loaded_image "$(sha256sum "${EVIDENCE}/candidate-loaded-image.json" | awk '{print $1}')" \
        --arg manifest "$(sha256sum "${EVIDENCE}/PRE_REWIND_SHA256SUMS" | awk '{print $1}')" \
        --arg final_chain "$(sha256sum "${EVIDENCE}/candidate-final-chain.json" | awk '{print $1}')" \
        --arg final_chain_after "$(sha256sum "${EVIDENCE}/candidate-final-chain-after.json" | awk '{print $1}')" \
        --arg final_pow "$(sha256sum "${EVIDENCE}/candidate-final-pow.json" | awk '{print $1}')" \
        --arg final_pow_after "$(sha256sum "${EVIDENCE}/candidate-final-pow-after.json" | awk '{print $1}')" \
        --arg final_staking "$(sha256sum "${EVIDENCE}/candidate-final-staking.json" | awk '{print $1}')" \
        --arg final_staking_after "$(sha256sum "${EVIDENCE}/candidate-final-staking-after.json" | awk '{print $1}')" \
        --arg final_recovery "$(sha256sum "${EVIDENCE}/candidate-final-recovery-inventory.json" | awk '{print $1}')" \
        --arg final_recovery_after "$(sha256sum "${EVIDENCE}/candidate-final-recovery-after.json" | awk '{print $1}')" \
        --arg final_wallet "$(sha256sum "${EVIDENCE}/candidate-final-wallet-transactions.json" | awk '{print $1}')" \
        --arg final_mempool "$(sha256sum "${EVIDENCE}/candidate-final-mempool.json" | awk '{print $1}')" \
        --arg observer_terminal "$(sha256sum "${EVIDENCE}/observer-terminal-proof.json" | awk '{print $1}')" \
        --arg observer_chains "$(sha256sum "${EVIDENCE}/observer-final-chain.jsonl" | awk '{print $1}')" \
        --arg observer_anchors "$(sha256sum "${EVIDENCE}/observer-anchor-unspent.jsonl" | awk '{print $1}')" \
        --arg observer_absence "$(sha256sum "${EVIDENCE}/observer-tx-absence.jsonl" | awk '{print $1}')" \
        --arg stable_cut "$(sha256sum "${EVIDENCE}/candidate-final-stable-cut.json" | awk '{print $1}')" \
        --arg stopped "$(sha256sum "${EVIDENCE}/candidate-stopped.json" | awk '{print $1}')" \
        --arg stop_authority "$(sha256sum "${EVIDENCE}/candidate-stop-authority.json" | awk '{print $1}')" \
        --arg log_receipt "$(sha256sum "${EVIDENCE}/candidate-post-stop-log-receipt.json" | awk '{print $1}')" \
        --arg recovery_metrics "$baseline_recovery_metrics_sha" \
        --arg tip "$terminal_tip" --arg work "$terminal_work" \
        --argjson height "$terminal_height" --argjson generation "$generation" \
        --argjson txids "$txids" '
        {schema:1,result:"REWIND_SAFE",run_nonce:$nonce,candidate_source_sha:$source,
         candidate_image_id:$image_id,candidate_image_ref:$image_ref,
         candidate_manifest_digest:$manifest_digest,candidate_blackcoin_qt_sha256:$qt,
         tooling_commit:$tooling,entrypoint_body_sha256:$body,
         phase_a_tooling_identity_sha256:$tooling_identity,
         package_sha256sums_sha256:$package,phase_a_script_sha256:$phase_a_script,
         phase_b_script_sha256:$phase_b_script,verifier_sha256:$phase_a_verifier,
         typed_contract_sha256:$phase_a_contract,
         invocation_sha256:$invocation,helper_audit_sha256:$helper,
         nonpublication_sha256:$isolation,snapshot_set_sha256:$snapshots,
         progress_sha256:$progress,claim_proof_sha256:$claim,logs_sha256:$logs,
         rpc_journal_sha256:$rpc,locks_sha256:$locks,guard_sources_sha256:$guards,
         pre_rewind_state_sha256:$pre_state,
         maintenance_marker_sha256:$maintenance,
         offline_verifier_receipt_sha256:$verifier,
         compose_sha256:$compose,baseline_runtime_identity_sha256:$baseline_runtime,
         candidate_bundle_manifest_sha256:$bundle_manifest,
         candidate_oci_identity_sha256:$oci_identity,
         candidate_binary_sha256sums_sha256:$binary_sums,
         candidate_loaded_image_sha256:$loaded_image,
         pre_rewind_manifest_sha256:$manifest,
         candidate_final_chain_sha256:$final_chain,
         candidate_final_chain_after_sha256:$final_chain_after,
         candidate_final_pow_sha256:$final_pow,
         candidate_final_pow_after_sha256:$final_pow_after,
         candidate_final_staking_sha256:$final_staking,
         candidate_final_staking_after_sha256:$final_staking_after,
         candidate_final_recovery_sha256:$final_recovery,
         candidate_final_recovery_after_sha256:$final_recovery_after,
         candidate_final_wallet_transactions_sha256:$final_wallet,
         candidate_final_mempool_sha256:$final_mempool,
         observer_terminal_proof_sha256:$observer_terminal,
         observer_final_chain_sha256:$observer_chains,
         observer_anchor_unspent_sha256:$observer_anchors,
         observer_tx_absence_sha256:$observer_absence,
         candidate_final_stable_cut_sha256:$stable_cut,
         candidate_stopped_receipt_sha256:$stopped,
         candidate_stop_authority_sha256:$stop_authority,
         candidate_post_stop_log_receipt_sha256:$log_receipt,
         recovery_metrics_sha256:$recovery_metrics,
         candidate_stopped:true,candidate_exit_code:0,pow_worker_joined:true,wallet_locked:true,
         complete_log_captured_after_stop:true,terminal_stable_cut_verified:true,
         hard_flags_continuously_verified:true,pos_disabled_continuously:true,
         interactive_surfaces_stopped_continuously:true,rpc_allowlist_enforced:true,
         shared_namespace_rpc_auth_boundary_verified:true,
         nonpublication_verified:true,observer_absence_verified:true,unknown_or_ambiguous:false,
         coinstake_or_wallet_escape_detected:false,candidate_created_qqsproof_txids:$txids,
         network_visible_wallet_txids:[],confirmed_candidate_txids:[],
         unclassifiable_candidate_txids:[],recovery_spend_or_fee_detected:false,
         unrelated_wallet_delta:false,terminal_tip:$tip,terminal_height:$height,
         terminal_chainwork:$work,wallet_generation:$generation,
         promotion_marker_absent:true,snapshots_held:true}
    ' >"$tmp" || return 1
    hotfix_rewind_safe_file_is_valid "$tmp" "$run_nonce" || return 1
    chmod 600 "$tmp" && sync -f "$tmp" || return 1
    mv -fT -- "$tmp" "$REWIND_SAFE" || return 1
    sync -f "$REWIND_SAFE" && sync -f "$EVIDENCE"
    hotfix_rewind_safe_file_is_valid "$REWIND_SAFE" "$run_nonce" || return 1
    verify_rewind_safe_bindings || return 1
    write_state REWIND_SAFE
}

certificate_hash_matches()
{
    local field="$1" file="$2" expected actual
    [[ -f "$file" && ! -L "$file" ]] || return 1
    expected=$(jq -er --arg field "$field" '.[$field]' "$REWIND_SAFE") || return 1
    actual=$(sha256sum "$file" | awk '{print $1}') || return 1
    [[ "$expected" == "$actual" ]]
}

verify_rewind_safe_bindings()
{
    local nonce state
    [[ -f "$REWIND_SAFE" && ! -L "$REWIND_SAFE" && ! -e "$PROMOTION_MARKER" ]] || return 1
    nonce=$(jq -er '.run_nonce' "$REWIND_SAFE") || return 1
    [[ "$nonce" == "$run_nonce" ]] || return 1
    hotfix_rewind_safe_file_is_valid "$REWIND_SAFE" "$run_nonce" || return 1
    hotfix_phase_a_stable_stop_file_is_valid \
        "${EVIDENCE}/candidate-stop-authority.json" candidate-terminal \
        "$CANDIDATE_IMAGE_ID" "$CANDIDATE_IMAGE" || return 1
    stable_stop_receipt_matches_live "${EVIDENCE}/candidate-stop-authority.json" || return 1
    state=$(state_value) || return 1
    [[ "$state" == PRE_REWIND_VERIFIED || "$state" == REWIND_SAFE ||
       "$state" == REWIND_STARTED ]] || return 1
    (cd "$EVIDENCE" && sha256sum --strict -c PRE_REWIND_SHA256SUMS >/dev/null) || return 1
    verify_phase_a_tooling_identity_live || return 1
    certificate_hash_matches phase_a_tooling_identity_sha256 \
        "${EVIDENCE}/tooling-identity.json" || return 1
    jq -e \
        --arg package "$(sha256sum "$PACKAGE_ROOT/SHA256SUMS" | awk '{print $1}')" \
        --arg phase_a "$(sha256sum "${BASH_SOURCE[0]}" | awk '{print $1}')" \
        --arg phase_b "$(sha256sum \
          "$PACKAGE_ROOT/node27-v30.1.4-hotfix-candidate.promote-no-data-rewind.sh" |
          awk '{print $1}')" \
        --arg verifier "$(sha256sum "$PACKAGE_ROOT/verify-evidence.sh" | awk '{print $1}')" \
        --arg contract "$(sha256sum "$PACKAGE_ROOT/lib/typed_contract.sh" | awk '{print $1}')" \
        --arg recovery_metrics "$baseline_recovery_metrics_sha" '
      .package_sha256sums_sha256==$package and .phase_a_script_sha256==$phase_a and
      .phase_b_script_sha256==$phase_b and .verifier_sha256==$verifier and
      .typed_contract_sha256==$contract and .recovery_metrics_sha256==$recovery_metrics
    ' "$REWIND_SAFE" >/dev/null || return 1
    certificate_hash_matches invocation_sha256 \
        "${EVIDENCE}/candidate-invocation-restart.json" || return 1
    certificate_hash_matches helper_audit_sha256 \
        "${EVIDENCE}/unlock-helper-audit.json" || return 1
    certificate_hash_matches nonpublication_sha256 \
        "${EVIDENCE}/phase-a-nonpublication-final.json" || return 1
    certificate_hash_matches snapshot_set_sha256 "${EVIDENCE}/snapshot-set.json" || return 1
    certificate_hash_matches progress_sha256 "$CANDIDATE_PROGRESS" || return 1
    certificate_hash_matches claim_proof_sha256 "$NO_RECOVERY_SPEND" || return 1
    certificate_hash_matches logs_sha256 "${EVIDENCE}/candidate-complete.log" || return 1
    certificate_hash_matches rpc_journal_sha256 \
        "${EVIDENCE}/candidate-rpc-methods-through-proof.log" || return 1
    certificate_hash_matches locks_sha256 "${EVIDENCE}/locks.json" || return 1
    certificate_hash_matches guard_sources_sha256 \
        "${EVIDENCE}/guard-source-identity.json" || return 1
    verify_live_guard_contract || return 1
    certificate_hash_matches pre_rewind_state_sha256 \
        "${EVIDENCE}/pre-rewind-state.json" || return 1
    certificate_hash_matches maintenance_marker_sha256 "$MAINTENANCE_MARKER" || return 1
    certificate_hash_matches offline_verifier_receipt_sha256 \
        "${EVIDENCE}/pre-rewind-verifier.json" || return 1
    jq -e --arg nonce "$run_nonce" --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" \
        --arg manifest "$(sha256sum "${EVIDENCE}/PRE_REWIND_SHA256SUMS" | awk '{print $1}')" \
        --arg verifier "$(sha256sum "$PACKAGE_ROOT/verify-evidence.sh" | awk '{print $1}')" '
      . == {schema:1,mode:"phase-a-pre-rewind",result:"passed",run_nonce:$nonce,
            candidate_source_sha:$source,pre_rewind_manifest_sha256:$manifest,
            verifier_sha256:$verifier}
    ' "${EVIDENCE}/pre-rewind-verifier.json" >/dev/null || return 1
    jq -e --arg nonce "$run_nonce" '.schema==2 and .phase=="A" and .run_nonce==$nonce and
      .state=="PRE_REWIND_VERIFIED" and .previous_state=="CANDIDATE_STOPPED"' \
      "${EVIDENCE}/pre-rewind-state.json" >/dev/null || return 1
    [[ "$(jq -er '.compose_sha256' "$REWIND_SAFE")" == "$EXPECTED_COMPOSE_SHA256" &&
       "$(sha256sum "$COMPOSE" | awk '{print $1}')" == "$EXPECTED_COMPOSE_SHA256" &&
       "$(jq -er '.candidate_image_ref' "$REWIND_SAFE")" == "$CANDIDATE_IMAGE" &&
       "$(jq -er '.candidate_image_id' "$REWIND_SAFE")" == "$CANDIDATE_IMAGE_ID" &&
       "$(jq -er '.candidate_manifest_digest' "$REWIND_SAFE")" == \
         "$CANDIDATE_IMAGE_MANIFEST_DIGEST" &&
       "$(jq -er '.candidate_blackcoin_qt_sha256' "$REWIND_SAFE")" == \
         "$CANDIDATE_BLACKCOIN_QT_SHA256" ]] || return 1
    jq -e '.complete_log_captured_after_stop == true and
      .terminal_stable_cut_verified == true and
      .interactive_surfaces_stopped_continuously == true and
      .rpc_allowlist_enforced == true and
      .shared_namespace_rpc_auth_boundary_verified == true' \
      "$REWIND_SAFE" >/dev/null || return 1
    certificate_hash_matches baseline_runtime_identity_sha256 \
        "${EVIDENCE}/baseline-runtime-identity.json" || return 1
    certificate_hash_matches candidate_bundle_manifest_sha256 \
        "${EVIDENCE}/candidate-bundle-manifest.json" || return 1
    certificate_hash_matches candidate_oci_identity_sha256 \
        "${EVIDENCE}/candidate-oci-identity.json" || return 1
    certificate_hash_matches candidate_binary_sha256sums_sha256 \
        "${EVIDENCE}/candidate-binary-sha256sums.txt" || return 1
    certificate_hash_matches candidate_loaded_image_sha256 \
        "${EVIDENCE}/candidate-loaded-image.json" || return 1
    certificate_hash_matches pre_rewind_manifest_sha256 \
        "${EVIDENCE}/PRE_REWIND_SHA256SUMS" || return 1
    certificate_hash_matches candidate_final_chain_sha256 \
        "${EVIDENCE}/candidate-final-chain.json" || return 1
    certificate_hash_matches candidate_final_chain_after_sha256 \
        "${EVIDENCE}/candidate-final-chain-after.json" || return 1
    certificate_hash_matches candidate_final_pow_sha256 \
        "${EVIDENCE}/candidate-final-pow.json" || return 1
    certificate_hash_matches candidate_final_pow_after_sha256 \
        "${EVIDENCE}/candidate-final-pow-after.json" || return 1
    certificate_hash_matches candidate_final_staking_sha256 \
        "${EVIDENCE}/candidate-final-staking.json" || return 1
    certificate_hash_matches candidate_final_staking_after_sha256 \
        "${EVIDENCE}/candidate-final-staking-after.json" || return 1
    certificate_hash_matches candidate_final_recovery_sha256 \
        "${EVIDENCE}/candidate-final-recovery-inventory.json" || return 1
    certificate_hash_matches candidate_final_recovery_after_sha256 \
        "${EVIDENCE}/candidate-final-recovery-after.json" || return 1
    certificate_hash_matches candidate_final_wallet_transactions_sha256 \
        "${EVIDENCE}/candidate-final-wallet-transactions.json" || return 1
    certificate_hash_matches candidate_final_mempool_sha256 \
        "${EVIDENCE}/candidate-final-mempool.json" || return 1
    certificate_hash_matches observer_terminal_proof_sha256 \
        "${EVIDENCE}/observer-terminal-proof.json" || return 1
    certificate_hash_matches observer_final_chain_sha256 \
        "${EVIDENCE}/observer-final-chain.jsonl" || return 1
    certificate_hash_matches observer_anchor_unspent_sha256 \
        "${EVIDENCE}/observer-anchor-unspent.jsonl" || return 1
    certificate_hash_matches observer_tx_absence_sha256 \
        "${EVIDENCE}/observer-tx-absence.jsonl" || return 1
    certificate_hash_matches candidate_final_stable_cut_sha256 \
        "${EVIDENCE}/candidate-final-stable-cut.json" || return 1
    certificate_hash_matches candidate_stopped_receipt_sha256 \
        "${EVIDENCE}/candidate-stopped.json" || return 1
    certificate_hash_matches candidate_stop_authority_sha256 \
        "${EVIDENCE}/candidate-stop-authority.json" || return 1
    certificate_hash_matches candidate_post_stop_log_receipt_sha256 \
        "${EVIDENCE}/candidate-post-stop-log-receipt.json" || return 1
    jq -e --slurpfile cert "$REWIND_SAFE" \
        --slurpfile chain "${EVIDENCE}/candidate-final-chain.json" \
        --slurpfile chain_after "${EVIDENCE}/candidate-final-chain-after.json" \
        --slurpfile recovery "${EVIDENCE}/candidate-final-recovery-inventory.json" \
        --slurpfile recovery_after "${EVIDENCE}/candidate-final-recovery-after.json" \
        --slurpfile observer "${EVIDENCE}/observer-terminal-proof.json" \
        --slurpfile claim "$NO_RECOVERY_SPEND" '
        .stable == true and
        .observer_terminal_proof_sha256 == $cert[0].observer_terminal_proof_sha256 and
        .terminal_tip == $cert[0].terminal_tip and
        .terminal_chainwork == $cert[0].terminal_chainwork and
        .wallet_generation == $cert[0].wallet_generation and
        $chain[0].bestblockhash == .terminal_tip and
        $chain_after[0].bestblockhash == .terminal_tip and
        $chain[0].chainwork == .terminal_chainwork and
        $chain_after[0].chainwork == .terminal_chainwork and
        $chain[0].blocks == $cert[0].terminal_height and
        $recovery[0].active_tip == .terminal_tip and
        $recovery_after[0].active_tip == .terminal_tip and
        $recovery[0].wallet_generation == .wallet_generation and
        $recovery_after[0].wallet_generation == .wallet_generation and
        $observer[0].terminal_tip == .terminal_tip and
        $observer[0].terminal_chainwork == .terminal_chainwork and
        $observer[0].observers_stable_and_cover_terminal == true and
        $observer[0].authenticated_anchor_unspent_on_all_observers == true and
        ($claim[0].candidate_created_qqsproof_txids | sort) ==
          ($cert[0].candidate_created_qqsproof_txids | sort) and
        $claim[0].terminal_stable_cut_verified == true and
        $claim[0].baseline_wallet_records_static_equal == true and
        $claim[0].progress_tips_bound_to_lineage == true and
        $claim[0].one_lineage_member_per_progress_tip == true and
        $claim[0].claim_samples_monotonic == true and
        $claim[0].visibility_samples_bound_to_progress == true and
        $claim[0].rpc_allowlist_enforced == true and
        $claim[0].unexpected_rpc_methods == [] and
        $claim[0].interactive_surfaces_stopped_continuously == true and
        $claim[0].shared_namespace_rpc_auth_boundary_continuously_verified == true and
        $claim[0].final_claim_sample_complete == true
    ' "${EVIDENCE}/candidate-final-stable-cut.json" >/dev/null || return 1
    [[ "$(jq -er '.listener_evidence_sha256' \
         "${EVIDENCE}/phase-a-nonpublication-final.json")" == \
       "$(sha256sum "${EVIDENCE}/phase-a-nonpublication-final.listeners.txt" | awk '{print $1}')" &&
       "$(jq -er '.ipv4_firewall_evidence_sha256' \
         "${EVIDENCE}/phase-a-nonpublication-final.json")" == \
       "$(sha256sum "${EVIDENCE}/phase-a-nonpublication-final.iptables.txt" | awk '{print $1}')" &&
       "$(jq -er '.ipv6_firewall_evidence_sha256' \
         "${EVIDENCE}/phase-a-nonpublication-final.json")" == \
       "$(sha256sum "${EVIDENCE}/phase-a-nonpublication-final.ip6tables.txt" | awk '{print $1}')" &&
       "$(jq -er '.nft_evidence_sha256' \
         "${EVIDENCE}/phase-a-nonpublication-final.json")" == \
       "$(sha256sum "${EVIDENCE}/phase-a-nonpublication-final.nft.txt" | awk '{print $1}')" &&
       "$(jq -er '.port_binding_evidence_sha256' \
         "${EVIDENCE}/phase-a-nonpublication-final.json")" == \
       "$(sha256sum "${EVIDENCE}/phase-a-nonpublication-final.port-bindings.json" | awk '{print $1}')" &&
       "$(jq -er '.vpn_mount_evidence_sha256' \
         "${EVIDENCE}/phase-a-nonpublication-final.json")" == \
       "$(sha256sum "${EVIDENCE}/phase-a-nonpublication-final.vpn-mounts.json" | awk '{print $1}')" &&
       "$(jq -er '.rpc_auth_boundary_evidence_sha256' \
         "${EVIDENCE}/phase-a-nonpublication-final.json")" == \
       "$(sha256sum "${EVIDENCE}/phase-a-nonpublication-final.rpc-auth-boundary.json" | awk '{print $1}')" &&
       "$(jq -er '.probe_target_evidence_sha256' \
         "${EVIDENCE}/phase-a-nonpublication-final.json")" == \
       "$(sha256sum "${EVIDENCE}/phase-a-nonpublication-final.probe-targets.json" | awk '{print $1}')" ]] ||
        return 1
    [[ "$(jq -er '.run_nonce' "$CANDIDATE_PROGRESS")" == "$run_nonce" &&
       "$(jq -er '.run_nonce' "$NO_RECOVERY_SPEND")" == "$run_nonce" ]] || return 1
    cmp -s "$PHASE_STATE" "${EVIDENCE}/pre-rewind-state.json" || {
        [[ "$state" == REWIND_SAFE || "$state" == REWIND_STARTED ]] || return 1
        jq -e --arg nonce "$run_nonce" '.run_nonce == $nonce and
          .state == "PRE_REWIND_VERIFIED"' "${EVIDENCE}/pre-rewind-state.json" >/dev/null || return 1
    }
    [[ "$(readlink -f /proc/$$/fd/5)" == /run/blackcoin-endpoint-guard.lock &&
       "$(readlink -f /proc/$$/fd/9)" == /var/run/blackcoin-node-cutover.lock &&
       "$(readlink -f /proc/$$/fd/8)" == /run/blackcoin-pow-quarantine-cycle.lock &&
       "$(readlink -f /proc/$$/fd/7)" == /var/run/blackcoin-wallet-runtime-guard.lock ]] || return 1
    jq -e --arg run "$OPS" --arg nonce "$guard_nonce" '
      . == {schema:1,transaction:"v30.1.4-node27-canary",state:"active",
            run_nonce:$nonce,run_dir:$run}
    ' "$MAINTENANCE_MARKER" >/dev/null || return 1
    [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER")" == false &&
       "$(docker inspect -f '{{.State.ExitCode}}' "$CONTAINER")" == 0 &&
       "$(docker inspect -f '{{.Image}}' "$CONTAINER")" == "$CANDIDATE_IMAGE_ID" ]] || return 1
    hotfix_snapshot_set_file_is_valid "${EVIDENCE}/snapshot-set.json" "$run_nonce" || return 1
    snapshot_set_is_live_and_held
}

start_base_hard_quarantine()
{
    write_wrapper_override "$IMMUTABLE_V3014_IMAGE_REF" || return 1
    create_stopped_from_override || return 1
    capture_created_inspection "${EVIDENCE}/base-quarantine-created-stopped.json" \
        "$IMMUTABLE_V3014_IMAGE_ID" || return 1
    docker start "$CONTAINER" >/dev/null || return 1
    wait_rpc || return 1
    capture_invocation A "$IMMUTABLE_V3014_IMAGE_ID" \
        "${EVIDENCE}/base-quarantine-created-stopped.json" \
        "${EVIDENCE}/base-quarantine-invocation.json" || return 1
    assert_setup_processes || return 1
    disable_phase_a_interactive_surfaces || return 1
    capture_nonpublication "${EVIDENCE}/base-quarantine-nonpublication.json" || return 1
    rpc getwalletinfo >"${EVIDENCE}/base-quarantine-wallet.json" || return 1
    rpc getstakinginfo >"${EVIDENCE}/base-quarantine-staking.json" || return 1
    rpc getpowmininginfo >"${EVIDENCE}/base-quarantine-pow.json" || return 1
    rpc listwallets >"${EVIDENCE}/base-quarantine-wallets.json" || return 1
    jq -e '.unlocked_until == 0' "${EVIDENCE}/base-quarantine-wallet.json" >/dev/null || return 1
    jq -e '.enabled == false and .staking == false and .worker_running == false' \
        "${EVIDENCE}/base-quarantine-staking.json" >/dev/null || return 1
    jq -e '.enabled == false and .hashrate == 0' "${EVIDENCE}/base-quarantine-pow.json" >/dev/null || return 1
    cmp -s "${EVIDENCE}/base-quarantine-wallets.json" "${EVIDENCE}/baseline-wallets.json" || return 1
    write_state BASE_QUARANTINE_RUNNING
}

capture_base_observer_cut()
{
    local terminal_chain="$1" anchor_txid="$2" anchor_vout="$3" output="$4"
    local tmp observer chain1 chain2 mempool anchor relation terminal_work observer_work
    tmp=$(mktemp "${OPS}/.base-observer-cut.XXXXXX") || return 1
    terminal_work=$(jq -er '.chainwork' <<<"$terminal_chain") || return 1
    : >"$tmp"
    for observer in blackcoin-v4-gui-26 blackcoin-v4-gui-28; do
        chain1=$(timeout -k 2 30 docker exec "$observer" "$CLI" -datadir="$DATADIR" \
            getblockchaininfo) || return 1
        observer_chain_covers_terminal "$terminal_chain" "$chain1" || return 1
        mempool=$(timeout -k 2 30 docker exec "$observer" "$CLI" -datadir="$DATADIR" \
            getrawmempool | jq -cS 'sort') || return 1
        jq -e --slurpfile ids "$NO_RECOVERY_SPEND" '
          . as $observer_mempool |
          all($ids[0].candidate_created_qqsproof_txids[]; . as $id |
            ($observer_mempool | index($id)) == null)
        ' <<<"$mempool" >/dev/null || return 1
        anchor=$(timeout -k 2 30 docker exec "$observer" "$CLI" -datadir="$DATADIR" \
            gettxout "$anchor_txid" "$anchor_vout" true) || return 1
        jq -e 'type == "object" and .confirmations >= 1 and .coinbase == false' \
            <<<"$anchor" >/dev/null || return 1
        chain2=$(timeout -k 2 30 docker exec "$observer" "$CLI" -datadir="$DATADIR" \
            getblockchaininfo) || return 1
        jq -e -n --argjson a "$chain1" --argjson b "$chain2" '
          $a.bestblockhash == $b.bestblockhash and $a.chainwork == $b.chainwork and
          $a.blocks == $b.blocks and $a.headers == $b.headers
        ' >/dev/null || return 1
        observer_chain_covers_terminal "$terminal_chain" "$chain2" || return 1
        observer_work=$(jq -er '.chainwork' <<<"$chain2") || return 1
        if [[ "$observer_work" == "$terminal_work" ]]; then
            relation=same_terminal_tip
        else
            relation=terminal_superseded_by_greater_work
        fi
        jq -cS -n --arg observer "$observer" --arg relation "$relation" \
            --arg anchor_txid "$anchor_txid" --argjson anchor_vout "$anchor_vout" \
            --argjson before "$chain1" --argjson after "$chain2" \
            --argjson mempool "$mempool" --argjson txout "$anchor" '
            {observer:$observer,chain_before:$before,chain_after:$after,stable:true,
             terminal_relation:$relation,mempool:$mempool,candidate_txids_absent:true,
             anchor:{txid:$anchor_txid,vout:$anchor_vout,unspent:true,txout:$txout}}
        ' >>"$tmp" || return 1
    done
    [[ "$(wc -l <"$tmp" | tr -d ' ')" == 2 ]] || return 1
    install -m 600 -o root -g root "$tmp" "$output" || return 1
    rm -f -- "$tmp"
}

wait_base_catchup()
{
    local terminal_tip terminal_work chain1 chain2 recovery wallet staking pow network wallets
    local wallet_transactions mempool anchor anchor_txid anchor_vout current_tip current_work
    local terminal_active greater tmp invocation_sha nonpublication_sha observer_sha
    terminal_tip=$(jq -er '.terminal_tip' "$REWIND_SAFE") || return 1
    terminal_work=$(jq -er '.terminal_chainwork' "$REWIND_SAFE") || return 1
    anchor_txid=$(jq -er '.lineage.anchor_txid' "$NO_RECOVERY_SPEND") || return 1
    anchor_vout=$(jq -er '.lineage.anchor_vout' "$NO_RECOVERY_SPEND") || return 1
    for _ in $(seq 1 1800); do
        terminal_active=false
        greater=false
        chain1=$(rpc getblockchaininfo) || return 1
        recovery=$(rpc getpowclaimrecoveryinfo true) || return 1
        wallet=$(rpc getwalletinfo) || return 1
        staking=$(rpc getstakinginfo) || return 1
        pow=$(rpc getpowmininginfo) || return 1
        network=$(rpc getnetworkinfo) || return 1
        wallets=$(rpc listwallets | jq -cS .) || return 1
        wallet_transactions=$(rpc listtransactions '*' 1000000 0 true | jq -cS \
            'sort_by(.txid,.vout,.category)') || return 1
        mempool=$(rpc getrawmempool | jq -cS 'sort') || return 1
        anchor=$(rpc gettxout "$anchor_txid" "$anchor_vout" true) || return 1
        capture_invocation A "$IMMUTABLE_V3014_IMAGE_ID" \
            "${EVIDENCE}/base-quarantine-created-stopped.json" \
            "${EVIDENCE}/base-quarantine-invocation-current.json" || return 1
        capture_nonpublication "${EVIDENCE}/base-quarantine-nonpublication-current.json" || return 1
        capture_base_observer_cut "$chain1" "$anchor_txid" "$anchor_vout" \
            "${EVIDENCE}/base-catchup-observer.jsonl" || {
            sleep 2
            continue
        }
        chain2=$(rpc getblockchaininfo) || return 1
        if ! jq -e -n --argjson a "$chain1" --argjson b "$chain2" '
          $a.bestblockhash == $b.bestblockhash and $a.chainwork == $b.chainwork and
          $a.blocks == $b.blocks and $a.headers == $b.headers
        ' >/dev/null; then
            sleep 2
            continue
        fi
        current_tip=$(jq -er '.bestblockhash' <<<"$chain1") || return 1
        current_work=$(jq -er '.chainwork' <<<"$chain1") || return 1
        [[ "$current_work" == "$terminal_work" || "$current_work" > "$terminal_work" ]] || {
            sleep 2
            continue
        }
        terminal_active=false
        if [[ "$current_tip" == "$terminal_tip" ]]; then
            terminal_active=true
        elif [[ "$current_work" > "$terminal_work" ]]; then
            greater=true
        fi
        if jq -e '.chain == "main" and .initialblockdownload == false and
             .blocks == .headers' <<<"$chain1" >/dev/null &&
           jq -e --arg tip "$current_tip" '.chain_ready == true and .wallet_tip_matches == true and
             .active_tip == $tip and .wallet_processed_tip == $tip and
             .database_outcome_ambiguous == false' <<<"$recovery" >/dev/null &&
           jq -e '.scanning == false and .unlocked_until == 0 and
             .private_keys_enabled == true' <<<"$wallet" >/dev/null &&
           jq -e '.enabled == false and .staking == false and
             .worker_running == false' <<<"$staking" >/dev/null &&
           legacy_pow_is_feature_detected <(printf '%s\n' "$pow") &&
           jq -e '.enabled == false and .hashrate == 0' <<<"$pow" >/dev/null &&
           jq -e '.networkactive == true and .localrelay == false and
             .connections_out >= 3' <<<"$network" >/dev/null &&
           [[ "$wallets" == "$(jq -cS . "${EVIDENCE}/baseline-wallets.json")" ]] &&
           jq -e --argjson proof "$(<"$NO_RECOVERY_SPEND")" '
             ([.[] | .txid] | unique) as $seen |
             all($proof.candidate_created_qqsproof_txids[]; . as $id |
               ($seen | index($id)) == null)
           ' <<<"$wallet_transactions" >/dev/null &&
           jq -e --argjson proof "$(<"$NO_RECOVERY_SPEND")" '
             . as $base_mempool |
             all($proof.candidate_created_qqsproof_txids[]; . as $id |
               ($base_mempool | index($id)) == null)
           ' <<<"$mempool" >/dev/null &&
           jq -e 'type == "object" and .confirmations >= 1 and .coinbase == false' \
             <<<"$anchor" >/dev/null &&
           [[ "$(docker inspect -f '{{.State.Running}} {{.Config.Image}} {{.Image}}' \
             "$CONTAINER")" == "true $IMMUTABLE_V3014_IMAGE_REF $IMMUTABLE_V3014_IMAGE_ID" ]] &&
           [[ "$terminal_active" == true || "$greater" == true ]]; then
            printf '%s\n' "$chain1" | jq -S . >"${EVIDENCE}/base-catchup-chain.json" || return 1
            printf '%s\n' "$chain2" | jq -S . \
                >"${EVIDENCE}/base-catchup-chain-after.json" || return 1
            printf '%s\n' "$recovery" | jq -S . \
                >"${EVIDENCE}/base-catchup-recovery.json" || return 1
            printf '%s\n' "$wallet" | jq -S . >"${EVIDENCE}/base-catchup-wallet.json" || return 1
            printf '%s\n' "$staking" | jq -S . >"${EVIDENCE}/base-catchup-staking.json" || return 1
            printf '%s\n' "$pow" | jq -S . >"${EVIDENCE}/base-catchup-pow.json" || return 1
            printf '%s\n' "$network" | jq -S . >"${EVIDENCE}/base-catchup-network.json" || return 1
            printf '%s\n' "$wallets" | jq -S . >"${EVIDENCE}/base-catchup-wallets.json" || return 1
            printf '%s\n' "$wallet_transactions" | jq -S . \
                >"${EVIDENCE}/base-catchup-wallet-transactions.json" || return 1
            printf '%s\n' "$mempool" | jq -S . >"${EVIDENCE}/base-catchup-mempool.json" || return 1
            printf '%s\n' "$anchor" | jq -S . >"${EVIDENCE}/base-catchup-anchor.json" || return 1
            invocation_sha=$(sha256sum \
                "${EVIDENCE}/base-quarantine-invocation-current.json" | awk '{print $1}') || return 1
            nonpublication_sha=$(sha256sum \
                "${EVIDENCE}/base-quarantine-nonpublication-current.json" | awk '{print $1}') || return 1
            observer_sha=$(sha256sum "${EVIDENCE}/base-catchup-observer.jsonl" |
                awk '{print $1}') || return 1
            tmp=$(mktemp "${OPS}/.base-catchup.XXXXXX") || return 1
            jq -S -n --arg nonce "$run_nonce" --arg source "$IMMUTABLE_V3014_SOURCE_SHA" \
                --arg image "$IMMUTABLE_V3014_IMAGE_REF" --arg image_id "$IMMUTABLE_V3014_IMAGE_ID" \
                --arg terminal "$terminal_work" --arg terminal_tip "$terminal_tip" \
                --arg invocation_sha "$invocation_sha" --arg nonpublication_sha "$nonpublication_sha" \
                --arg observer_sha "$observer_sha" \
                --arg chain_sha "$(sha256sum "${EVIDENCE}/base-catchup-chain.json" | awk '{print $1}')" \
                --arg chain_after_sha "$(sha256sum "${EVIDENCE}/base-catchup-chain-after.json" | awk '{print $1}')" \
                --arg recovery_sha "$(sha256sum "${EVIDENCE}/base-catchup-recovery.json" | awk '{print $1}')" \
                --arg wallet_sha "$(sha256sum "${EVIDENCE}/base-catchup-wallet.json" | awk '{print $1}')" \
                --arg staking_sha "$(sha256sum "${EVIDENCE}/base-catchup-staking.json" | awk '{print $1}')" \
                --arg pow_sha "$(sha256sum "${EVIDENCE}/base-catchup-pow.json" | awk '{print $1}')" \
                --arg network_sha "$(sha256sum "${EVIDENCE}/base-catchup-network.json" | awk '{print $1}')" \
                --arg wallets_sha "$(sha256sum "${EVIDENCE}/base-catchup-wallets.json" | awk '{print $1}')" \
                --arg wallet_tx_sha "$(sha256sum "${EVIDENCE}/base-catchup-wallet-transactions.json" | awk '{print $1}')" \
                --arg mempool_sha "$(sha256sum "${EVIDENCE}/base-catchup-mempool.json" | awk '{print $1}')" \
                --arg anchor_sha "$(sha256sum "${EVIDENCE}/base-catchup-anchor.json" | awk '{print $1}')" \
                --arg anchor_txid "$anchor_txid" --argjson anchor_vout "$anchor_vout" \
                --argjson chain "$chain1" --argjson chain_after "$chain2" \
                --argjson wallet "$wallet" \
                --argjson recovery "$recovery" --argjson staking "$staking" \
                --argjson pow "$pow" --argjson network "$network" \
                --argjson wallets "$wallets" --argjson anchor "$anchor" \
                --argjson active "$terminal_active" --argjson greater "$greater" '
                {schema:1,run_nonce:$nonce,source_sha:$source,image:$image,image_id:$image_id,
                 hard_quarantine_flags_verified:true,wallet_locked:true,pow_enabled:false,
                 pos_enabled:false,walletbroadcast:false,chain:$chain,
                 phase_a_terminal_chainwork:$terminal,phase_a_terminal_tip:$terminal_tip,
                 chainwork_at_least_phase_a:true,
                 terminal_tip_active:$active,terminal_tip_superseded_by_greater_work:$greater,
                 wallet:$wallet,recovery:$recovery,staking:$staking,pow:$pow,network:$network,
                 wallets:$wallets,wallet_processed_tip_current:true,candidate_image_not_applied:true,
                 chain_after:$chain_after,
                 invocation_sha256:$invocation_sha,nonpublication_sha256:$nonpublication_sha,
                 observer_cut_sha256:$observer_sha,
                 chain_evidence_sha256:$chain_sha,chain_after_evidence_sha256:$chain_after_sha,
                 recovery_evidence_sha256:$recovery_sha,
                 wallet_evidence_sha256:$wallet_sha,staking_evidence_sha256:$staking_sha,
                 pow_evidence_sha256:$pow_sha,network_evidence_sha256:$network_sha,
                 wallets_evidence_sha256:$wallets_sha,
                 wallet_transactions_sha256:$wallet_tx_sha,mempool_sha256:$mempool_sha,
                 authenticated_anchor_evidence_sha256:$anchor_sha,
                 candidate_txids_absent_from_wallet:true,
                 candidate_txids_absent_from_mempool:true,
                 authenticated_anchor:{txid:$anchor_txid,vout:$anchor_vout,unspent:true,txout:$anchor},
                 authenticated_anchor_unspent:true,observer_candidate_txids_absent:true,
                 observer_anchor_unspent:true,candidate_claim_escape_absent:true,
                 stable_cut:true}
            ' >"$tmp" || return 1
            hotfix_base_catchup_file_is_valid "$tmp" "$run_nonce" || return 1
            chmod 600 "$tmp" && sync -f "$tmp" || return 1
            mv -fT -- "$tmp" "$BASE_CATCHUP_PROOF" || return 1
            sync -f "$BASE_CATCHUP_PROOF" && sync -f "$EVIDENCE" || return 1
            write_state BASE_CAUGHT_UP
            return
        fi
        sleep 2
    done
    return 1
}

base_catchup_hash_matches()
{
    local field="$1" file="$2" expected actual
    [[ -f "$BASE_CATCHUP_PROOF" && ! -L "$BASE_CATCHUP_PROOF" &&
       -f "$file" && ! -L "$file" ]] || return 1
    expected=$(jq -er --arg field "$field" '.[$field]' "$BASE_CATCHUP_PROOF") || return 1
    actual=$(sha256sum "$file" | awk '{print $1}') || return 1
    [[ "$expected" == "$actual" ]]
}

verify_base_quarantine_destroy_authority()
{
    local chain1 chain2 recovery wallet staking pow network wallets wallet_transactions
    local mempool anchor anchor_txid anchor_vout terminal_tip terminal_work current_tip current_work
    local relation invocation_sha observer_sha nonpublication_sha
    [[ "$(state_value)" == BASE_CAUGHT_UP && ! -e "$PROMOTION_MARKER" &&
       -f "$REWIND_SAFE" && ! -L "$REWIND_SAFE" ]] || return 1
    hotfix_rewind_safe_file_is_valid "$REWIND_SAFE" "$run_nonce" || return 1
    hotfix_base_catchup_file_is_valid "$BASE_CATCHUP_PROOF" "$run_nonce" || return 1
    base_catchup_hash_matches invocation_sha256 \
        "${EVIDENCE}/base-quarantine-invocation-current.json" || return 1
    base_catchup_hash_matches nonpublication_sha256 \
        "${EVIDENCE}/base-quarantine-nonpublication-current.json" || return 1
    base_catchup_hash_matches observer_cut_sha256 \
        "${EVIDENCE}/base-catchup-observer.jsonl" || return 1
    base_catchup_hash_matches chain_evidence_sha256 \
        "${EVIDENCE}/base-catchup-chain.json" || return 1
    base_catchup_hash_matches chain_after_evidence_sha256 \
        "${EVIDENCE}/base-catchup-chain-after.json" || return 1
    base_catchup_hash_matches recovery_evidence_sha256 \
        "${EVIDENCE}/base-catchup-recovery.json" || return 1
    base_catchup_hash_matches wallet_evidence_sha256 \
        "${EVIDENCE}/base-catchup-wallet.json" || return 1
    base_catchup_hash_matches staking_evidence_sha256 \
        "${EVIDENCE}/base-catchup-staking.json" || return 1
    base_catchup_hash_matches pow_evidence_sha256 \
        "${EVIDENCE}/base-catchup-pow.json" || return 1
    base_catchup_hash_matches network_evidence_sha256 \
        "${EVIDENCE}/base-catchup-network.json" || return 1
    base_catchup_hash_matches wallets_evidence_sha256 \
        "${EVIDENCE}/base-catchup-wallets.json" || return 1
    base_catchup_hash_matches wallet_transactions_sha256 \
        "${EVIDENCE}/base-catchup-wallet-transactions.json" || return 1
    base_catchup_hash_matches mempool_sha256 \
        "${EVIDENCE}/base-catchup-mempool.json" || return 1
    base_catchup_hash_matches authenticated_anchor_evidence_sha256 \
        "${EVIDENCE}/base-catchup-anchor.json" || return 1
    jq -e --slurpfile chain "${EVIDENCE}/base-catchup-chain.json" \
        --slurpfile chain_after "${EVIDENCE}/base-catchup-chain-after.json" \
        --slurpfile recovery "${EVIDENCE}/base-catchup-recovery.json" \
        --slurpfile wallet "${EVIDENCE}/base-catchup-wallet.json" \
        --slurpfile staking "${EVIDENCE}/base-catchup-staking.json" \
        --slurpfile pow "${EVIDENCE}/base-catchup-pow.json" \
        --slurpfile network "${EVIDENCE}/base-catchup-network.json" \
        --slurpfile wallets "${EVIDENCE}/base-catchup-wallets.json" '
        .chain == $chain[0] and .chain_after == $chain_after[0] and
        .chain == .chain_after and .recovery == $recovery[0] and
        .wallet == $wallet[0] and .staking == $staking[0] and
        .pow == $pow[0] and .network == $network[0] and .wallets == $wallets[0] and
        .stable_cut == true and .candidate_claim_escape_absent == true
    ' "$BASE_CATCHUP_PROOF" >/dev/null || return 1
    (cd "$EVIDENCE" && sha256sum --strict -c PRE_REWIND_SHA256SUMS >/dev/null) || return 1
    certificate_hash_matches progress_sha256 "$CANDIDATE_PROGRESS" || return 1
    certificate_hash_matches claim_proof_sha256 "$NO_RECOVERY_SPEND" || return 1
    certificate_hash_matches candidate_final_stable_cut_sha256 \
        "${EVIDENCE}/candidate-final-stable-cut.json" || return 1
    certificate_hash_matches observer_terminal_proof_sha256 \
        "${EVIDENCE}/observer-terminal-proof.json" || return 1
    certificate_hash_matches candidate_stopped_receipt_sha256 \
        "${EVIDENCE}/candidate-stopped.json" || return 1
    verify_live_guard_contract || return 1
    [[ "$(sha256sum "$COMPOSE" | awk '{print $1}')" == "$EXPECTED_COMPOSE_SHA256" &&
       "$(readlink -f /proc/$$/fd/5)" == /run/blackcoin-endpoint-guard.lock &&
       "$(readlink -f /proc/$$/fd/9)" == /var/run/blackcoin-node-cutover.lock &&
       "$(readlink -f /proc/$$/fd/8)" == /run/blackcoin-pow-quarantine-cycle.lock &&
       "$(readlink -f /proc/$$/fd/7)" == /var/run/blackcoin-wallet-runtime-guard.lock &&
       -e "$SUSPENDED_START_MARKER" && ! -e "$ENABLE_GUARD_STARTS" &&
       "$(docker inspect -f '{{.State.Running}} {{.Config.Image}} {{.Image}}' \
         "$CONTAINER")" == "true $IMMUTABLE_V3014_IMAGE_REF $IMMUTABLE_V3014_IMAGE_ID" ]] ||
        return 1
    jq -e --arg run "$OPS" --arg nonce "$guard_nonce" '
      . == {schema:1,transaction:"v30.1.4-node27-canary",state:"active",
            run_nonce:$nonce,run_dir:$run}
    ' "$MAINTENANCE_MARKER" >/dev/null || return 1
    capture_invocation A "$IMMUTABLE_V3014_IMAGE_ID" \
        "${EVIDENCE}/base-quarantine-created-stopped.json" \
        "${EVIDENCE}/base-quarantine-invocation-destroy-current.json" || return 1
    invocation_sha=$(sha256sum \
        "${EVIDENCE}/base-quarantine-invocation-destroy-current.json" | awk '{print $1}') || return 1
    [[ "$invocation_sha" == "$(jq -er '.invocation_sha256' "$BASE_CATCHUP_PROOF")" ]] || return 1
    capture_nonpublication \
        "${EVIDENCE}/base-quarantine-nonpublication-destroy-current.json" || return 1
    nonpublication_sha=$(sha256sum \
        "${EVIDENCE}/base-quarantine-nonpublication-destroy-current.json" |
        awk '{print $1}') || return 1
    terminal_tip=$(jq -er '.terminal_tip' "$REWIND_SAFE") || return 1
    terminal_work=$(jq -er '.terminal_chainwork' "$REWIND_SAFE") || return 1
    anchor_txid=$(jq -er '.lineage.anchor_txid' "$NO_RECOVERY_SPEND") || return 1
    anchor_vout=$(jq -er '.lineage.anchor_vout' "$NO_RECOVERY_SPEND") || return 1
    chain1=$(rpc getblockchaininfo) || return 1
    recovery=$(rpc getpowclaimrecoveryinfo true) || return 1
    wallet=$(rpc getwalletinfo) || return 1
    staking=$(rpc getstakinginfo) || return 1
    pow=$(rpc getpowmininginfo) || return 1
    network=$(rpc getnetworkinfo) || return 1
    wallets=$(rpc listwallets | jq -cS .) || return 1
    wallet_transactions=$(rpc listtransactions '*' 1000000 0 true | jq -cS \
        'sort_by(.txid,.vout,.category)') || return 1
    mempool=$(rpc getrawmempool | jq -cS 'sort') || return 1
    anchor=$(rpc gettxout "$anchor_txid" "$anchor_vout" true) || return 1
    capture_base_observer_cut "$chain1" "$anchor_txid" "$anchor_vout" \
        "${EVIDENCE}/base-destroy-observer-current.jsonl" || return 1
    observer_sha=$(sha256sum "${EVIDENCE}/base-destroy-observer-current.jsonl" |
        awk '{print $1}') || return 1
    chain2=$(rpc getblockchaininfo) || return 1
    jq -e -n --argjson a "$chain1" --argjson b "$chain2" '
      $a.bestblockhash == $b.bestblockhash and $a.chainwork == $b.chainwork and
      $a.blocks == $b.blocks and $a.headers == $b.headers
    ' >/dev/null || return 1
    current_tip=$(jq -er '.bestblockhash' <<<"$chain1") || return 1
    current_work=$(jq -er '.chainwork' <<<"$chain1") || return 1
    if [[ "$current_work" == "$terminal_work" && "$current_tip" == "$terminal_tip" ]]; then
        relation='terminal-tip-active'
    elif [[ "$current_work" > "$terminal_work" ]]; then
        relation='terminal-superseded-by-greater-work'
    else
        return 1
    fi
    jq -e --arg tip "$current_tip" '
      .chain_ready == true and .wallet_tip_matches == true and
      .active_tip == $tip and .wallet_processed_tip == $tip and
      .database_outcome_ambiguous == false
    ' <<<"$recovery" >/dev/null || return 1
    jq -e '.scanning == false and .unlocked_until == 0 and .private_keys_enabled == true' \
        <<<"$wallet" >/dev/null || return 1
    jq -e '.enabled == false and .staking == false and .worker_running == false' \
        <<<"$staking" >/dev/null || return 1
    legacy_pow_is_feature_detected <(printf '%s\n' "$pow") || return 1
    jq -e '.enabled == false and .hashrate == 0' <<<"$pow" >/dev/null || return 1
    jq -e '.chain == "main" and .initialblockdownload == false and .blocks == .headers' \
        <<<"$chain1" >/dev/null || return 1
    jq -e '.networkactive == true and .localrelay == false and .connections_out >= 3' \
        <<<"$network" >/dev/null || return 1
    [[ "$wallets" == "$(jq -cS . "${EVIDENCE}/baseline-wallets.json")" ]] || return 1
    jq -e --argjson proof "$(<"$NO_RECOVERY_SPEND")" '
      ([.[] | .txid] | unique) as $seen |
      all($proof.candidate_created_qqsproof_txids[]; . as $id |
        ($seen | index($id)) == null)
    ' <<<"$wallet_transactions" >/dev/null || return 1
    jq -e --argjson proof "$(<"$NO_RECOVERY_SPEND")" '
      . as $base_mempool |
      all($proof.candidate_created_qqsproof_txids[]; . as $id |
        ($base_mempool | index($id)) == null)
    ' <<<"$mempool" >/dev/null || return 1
    jq -e 'type == "object" and .confirmations >= 1 and .coinbase == false' \
        <<<"$anchor" >/dev/null || return 1
    jq -cS -n --arg utc "$(date -u +%FT%TZ)" --arg relation "$relation" \
        --arg tip "$current_tip" --arg work "$current_work" \
        --arg invocation_sha "$invocation_sha" --arg nonpublication_sha "$nonpublication_sha" \
        --arg observer_sha "$observer_sha" \
        '{observed_utc:$utc,authority_valid:true,chain_tip:$tip,chainwork:$work,
          terminal_relation:$relation,invocation_sha256:$invocation_sha,
          nonpublication_sha256:$nonpublication_sha,observer_cut_sha256:$observer_sha,
          candidate_txids_absent:true,authenticated_anchor_unspent:true,
          wallet_locked:true,pow_disabled:true,pos_disabled:true}' \
        >>"${EVIDENCE}/snapshot-destroy-authority-rechecks.jsonl" || return 1
    sync -f "${EVIDENCE}/snapshot-destroy-authority-rechecks.jsonl"
}

restore_baseline_after_snapshot_absence()
{
    local restored_quantum restored_fee restored_inspect restored_mounts restored_network
    local restored_restart
    [[ "$(state_value)" == SNAPSHOTS_ABSENT ]] || return 1
    hotfix_snapshot_absence_file_is_valid "$SNAPSHOT_ABSENCE_PROOF" "$run_nonce" || return 1
    stop_with_restart_authority_disabled base-quarantine-to-baseline \
        "$IMMUTABLE_V3014_IMAGE_ID" "$IMMUTABLE_V3014_IMAGE_REF" \
        "${EVIDENCE}/base-quarantine-stop-authority.json" \
        "${EVIDENCE}/base-quarantine-stop-rpc.json" || return 1
    docker compose -f "$COMPOSE" up -d --no-deps --force-recreate --pull never "$SERVICE" || return 1
    wait_rpc || return 1
    restored_inspect=$(mktemp "${OPS}/.baseline-restored-inspect.XXXXXX") || return 1
    docker inspect "$CONTAINER" >"$restored_inspect" || return 1
    restored_mounts=$(inspect_mounts_sha "$restored_inspect") || return 1
    restored_network=$(inspect_network_sha "$restored_inspect") || return 1
    restored_restart=$(inspect_restart_policy_json "$restored_inspect") || return 1
    jq -S --arg id "$IMMUTABLE_V3014_IMAGE_ID" --arg ref "$IMMUTABLE_V3014_IMAGE_REF" \
        --arg mounts "$restored_mounts" --arg network "$restored_network" \
        --argjson restart "$restored_restart" '
      .[0] | {schema:1,container_id:.Id,image_id:.Image,image_ref:.Config.Image,
        running:.State.Running,mounts_sha256:$mounts,network_sha256:$network,
        restart_policy:$restart}
    ' "$restored_inspect" >"${EVIDENCE}/baseline-restored-container.json" || return 1
    rm -f -- "$restored_inspect"
    jq -e --arg id "$IMMUTABLE_V3014_IMAGE_ID" --arg ref "$IMMUTABLE_V3014_IMAGE_REF" \
        --arg mounts "$baseline_mounts_sha" --arg network "$baseline_network_sha" \
        --argjson restart "$baseline_restart_policy_json" '
      .schema==1 and .image_id==$id and .image_ref==$ref and .running==true and
      .mounts_sha256==$mounts and .network_sha256==$network and .restart_policy==$restart and
      (.container_id | test("^[0-9a-f]{64}$"))
    ' "${EVIDENCE}/baseline-restored-container.json" >/dev/null || return 1
    run_unlock_helper || return 1
    rpc staking true >"${EVIDENCE}/baseline-restored-staking-start.json" || return 1
    if [[ "$baseline_pow_enabled" == true ]]; then
        rpc setpowmining true 1 1 false >"${EVIDENCE}/baseline-restored-pow.json" || return 1
    else
        rpc setpowmining false 1 1 false >"${EVIDENCE}/baseline-restored-pow.json" || return 1
    fi
    rpc getblockchaininfo >"${EVIDENCE}/baseline-restored-chain.json" || return 1
    rpc getnetworkinfo >"${EVIDENCE}/baseline-restored-network.json" || return 1
    rpc getwalletinfo >"${EVIDENCE}/baseline-restored-wallet.json" || return 1
    rpc getstakinginfo >"${EVIDENCE}/baseline-restored-staking.json" || return 1
    rpc getpowmininginfo >"${EVIDENCE}/baseline-restored-pow-state.json" || return 1
    rpc getpowclaimrecoveryinfo true >"${EVIDENCE}/baseline-restored-recovery.json" || return 1
    rpc getquantumkeyinventory | jq -S . >"${EVIDENCE}/baseline-restored-quantum.json" || return 1
    rpc listwallets | jq -S . >"${EVIDENCE}/baseline-restored-wallets.json" || return 1
    jq -e '.initialblockdownload == false and .blocks == .headers' \
        "${EVIDENCE}/baseline-restored-chain.json" >/dev/null || return 1
    jq -e '.networkactive == true and .connections_out >= 3' \
        "${EVIDENCE}/baseline-restored-network.json" >/dev/null || return 1
    jq -e '.enabled == true and .staking == true and .worker_running == true and .weight > 0' \
        "${EVIDENCE}/baseline-restored-staking.json" >/dev/null || return 1
    jq -e '.unlocked_until > now and .unlocked_staking_only == false' \
        "${EVIDENCE}/baseline-restored-wallet.json" >/dev/null || return 1
    legacy_pow_is_feature_detected "${EVIDENCE}/baseline-restored-pow-state.json" || return 1
    [[ "$(jq -er '.payout_address' "${EVIDENCE}/baseline-restored-pow-state.json")" == "$baseline_payout" ]] || return 1
    restored_quantum=$(jq -er 'if type=="array" then length elif (.keys?|type)=="array"
      then (.keys|length) elif (.inventory?|type)=="array" then (.inventory|length)
      elif (.total?|type)=="number" then .total else error("schema") end' \
      "${EVIDENCE}/baseline-restored-quantum.json") || return 1
    [[ "$restored_quantum" == "$baseline_quantum_key_count" ]] || return 1
    cmp -s <(jq -cS . "${EVIDENCE}/baseline-quantum-inventory.json") \
        <(jq -cS . "${EVIDENCE}/baseline-restored-quantum.json") || return 1
    cmp -s "${EVIDENCE}/baseline-wallets.json" \
        "${EVIDENCE}/baseline-restored-wallets.json" || return 1
    restored_fee=$(jq -er '.confirmed_resolution_fees' "${EVIDENCE}/baseline-restored-recovery.json") || return 1
    [[ "$restored_fee" == "$baseline_recovery_fee" ]] || return 1
    recovery_metrics_match_baseline "${EVIDENCE}/baseline-restored-recovery.json" || return 1
    cmp -s <(jq -cS '{policy,policy_authoritative,automatic_authorized}' \
        "${EVIDENCE}/baseline-recovery.json") \
        <(jq -cS '{policy,policy_authoritative,automatic_authorized}' \
        "${EVIDENCE}/baseline-restored-recovery.json") || return 1
    write_state BASELINE_RESTORED
}

seal_evidence_best_effort()
{
    local target="${EVIDENCE}/SHA256SUMS"
    [[ -d "$EVIDENCE" ]] || return 0
    rm -f -- "$target"
    (cd "$EVIDENCE" && find . -type f ! -name SHA256SUMS -print0 | sort -z |
        xargs -0 sha256sum) >"$target" 2>/dev/null || return 1
    chmod 600 "$target" 2>/dev/null || true
    sync -f "$target" 2>/dev/null || true
}

contain_candidate_best_effort()
{
    local contained_image_id contained_running restart_disabled authority_suspended
    if [[ ! -e "$SUSPENDED_START_MARKER" && ! -L "$SUSPENDED_START_MARKER" &&
       -f "$ENABLE_GUARD_STARTS" && ! -L "$ENABLE_GUARD_STARTS" ]]; then
        suspend_guard_authority >/dev/null 2>&1 || true
    fi
    docker update --restart=no "$CONTAINER" >/dev/null 2>&1 || true
    if [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)" == true ]]; then
        rpc setpowmining false 1 1 false >/dev/null 2>&1 || true
        rpc staking false >/dev/null 2>&1 || true
        rpc walletlock >/dev/null 2>&1 || true
        rpc stop >/dev/null 2>&1 || true
        wait_container_stopped >/dev/null 2>&1 || true
    fi
    timeout -k 30 360 docker stop -t 300 "$CONTAINER" >/dev/null 2>&1 || true
    contained_image_id=$(docker inspect -f '{{.Image}}' "$CONTAINER" 2>/dev/null || true)
    contained_running=$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)
    restart_disabled=$(docker inspect "$CONTAINER" 2>/dev/null | jq -e \
        '.[0].HostConfig.RestartPolicy=={Name:"no",MaximumRetryCount:0}' >/dev/null 2>&1 &&
        printf true || printf false)
    authority_suspended=false
    if [[ -f "$SUSPENDED_START_MARKER" && ! -L "$SUSPENDED_START_MARKER" &&
       ! -e "$ENABLE_GUARD_STARTS" ]]; then
        authority_suspended=true
    fi
    jq -S -n --arg timestamp "$(date -u +%FT%TZ)" --arg state "$(state_value 2>/dev/null || true)" \
        --arg image_id "$contained_image_id" --arg base_id "$IMMUTABLE_V3014_IMAGE_ID" \
        --argjson snapshot "$snapshot_created" --argjson rewind "$rewind_started" \
        --argjson running "${contained_running:-true}" --argjson restart "$restart_disabled" \
        --argjson authority "$authority_suspended" '
        {schema:1,contained:($running==false and $restart==true),
         automatic_start_authority_remains_suspended:$authority,
         data_preserved:true,snapshot_set_retained:($snapshot == 1),
         certified_rewind_had_started:($rewind == 1),contained_image_id:$image_id,
         immutable_base_hard_quarantine_had_started:($image_id == $base_id),
         restart_policy_disabled:$restart,container_running:$running,
         failure_trap_performed_data_rewind:false,failure_trap_started_old_core:false,
         state:$state,timestamp:$timestamp}
    ' >"${EVIDENCE}/CONTAINED.json" 2>/dev/null || true
    [[ "$contained_running" == false && "$restart_disabled" == true &&
       "$authority_suspended" == true ]]
}

on_exit()
{
    local rc=$?
    trap - EXIT ERR INT TERM
    if [[ "$result" != passed ]]; then
        if (( mutation_started == 1 )); then
            if contain_candidate_best_effort; then
                printf 'Phase A contained: restart disabled, container stopped, start authority suspended. Evidence: %s\n' \
                    "$EVIDENCE" >&2
            else
                printf 'URGENT: Phase A automatic containment proof is incomplete; preserve all state for manual recovery. Evidence: %s\n' \
                    "$EVIDENCE" >&2
            fi
        fi
        seal_evidence_best_effort || rc=1
        printf 'Phase A failure trap performed no data rewind or Core start. Evidence: %s\n' \
            "$EVIDENCE" >&2
        exit 1
    fi
    exit "$rc"
}
main()
{
    local command ops_dataset rollback_dataset baseline_mode baseline_quantum_sha logs_since
    local promotion_dataset promotion_fstype
    local post_manifest baseline_inspect
    trap on_exit EXIT ERR INT TERM
    require_no_placeholders
    verify_package_integrity || fail 'candidate canary package integrity seal failed'
    [[ "$(sha256sum "$PACKAGE_ROOT/../v30.1.4-canary/node27-v30.1.4-canary.no-spend.sh" |
        awk '{print $1}')" == "$IMMUTABLE_CANARY_SHA" &&
       "$(sha256sum "$PACKAGE_ROOT/../v30.1.4-canary/SHA256SUMS" | awk '{print $1}')" == "$IMMUTABLE_CANARY_MANIFEST_SHA" ]] ||
        fail 'immutable final canary bytes changed'
    [[ "$(id -u)" == 0 ]] || fail 'must run as root'
    for command in docker jq sha256sum cmp timeout flock findmnt zfs zpool install stat grep \
        sort awk wc mktemp realpath mv chmod chown sync date seq sleep find xargs rm cut tr tar \
        od ss hostname ps bash; do
        command -v "$command" >/dev/null || fail "required command unavailable: $command"
    done
    [[ -f "$COMPOSE" && ! -L "$COMPOSE" &&
       "$(sha256sum "$COMPOSE" | awk '{print $1}')" == "$EXPECTED_COMPOSE_SHA256" ]] ||
        fail 'live Compose bytes are not the same-lock audited identity'
    [[ "$(docker compose -f "$COMPOSE" config --format json | jq -er '.services.node27.image')" == "$IMMUTABLE_V3014_IMAGE_REF" ]] ||
        fail 'Compose rollback identity is not immutable v30.1.4'
    [[ "$(docker image inspect -f '{{.Id}}' "$IMMUTABLE_V3014_IMAGE_REF")" == "$IMMUTABLE_V3014_IMAGE_ID" ]] ||
        fail 'immutable v30.1.4 rollback image is unavailable'
    verify_helper || fail 'normal-unlock helper identity or syntax changed'

    [[ ! -L "$PROMOTION_ROOT" ]] || fail 'promotion authority root is a symlink'
    install -d -m 700 -o root -g root "$PROMOTION_ROOT" ||
        fail 'promotion authority root could not be prepared'
    [[ -d "$PROMOTION_ROOT" && "$(stat -Lc '%u:%g:%a' "$PROMOTION_ROOT")" == 0:0:700 ]] ||
        fail 'promotion authority root metadata is unsafe'
    promotion_dataset=$(findmnt -n -o SOURCE -T "$PROMOTION_ROOT") ||
        fail 'promotion authority dataset is unknown'
    promotion_fstype=$(findmnt -n -o FSTYPE -T "$PROMOTION_ROOT") ||
        fail 'promotion authority filesystem is unknown'
    [[ "$promotion_fstype" == zfs ]] ||
        fail 'promotion authority root must use a hard-link-capable ZFS filesystem'
    for rollback_dataset in "$EXPECTED_DATADIR_DATASET" "$EXPECTED_BLOCKS_DATASET" \
        "$EXPECTED_INDEXES_DATASET" "$EXPECTED_RAW_DATASET"; do
        [[ "$promotion_dataset" != "$rollback_dataset" &&
           "$promotion_dataset" != "$rollback_dataset/"* ]] ||
            fail 'promotion authority root is inside rollback scope'
    done
    [[ ! -e "$PROMOTION_MARKER" && ! -L "$PROMOTION_MARKER" ]] ||
        fail 'durable no-rewind authority already exists'

    [[ ! -e "$OPS" && ! -L "$OPS" ]] || fail 'operations path already exists'
    install -d -m 700 -o root -g root "$OPS" "$EVIDENCE"
    ops_dataset=$(findmnt -n -o SOURCE -T "$OPS") || fail 'cannot identify evidence dataset'
    for rollback_dataset in "$EXPECTED_DATADIR_DATASET" "$EXPECTED_BLOCKS_DATASET" \
        "$EXPECTED_INDEXES_DATASET" "$EXPECTED_RAW_DATASET"; do
        [[ "$ops_dataset" != "$rollback_dataset" && "$ops_dataset" != "$rollback_dataset/"* ]] ||
            fail 'evidence is stored inside rollback scope'
    done
    : >"$RPC_METHODS_LOG"
    run_nonce=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n') || fail 'could not create run nonce'
    hotfix_valid_nonce "$run_nonce" || fail 'run nonce is malformed'
    SNAP="v30.1.4-hotfix-candidate-node27-${run_nonce}"
    HOLD="blackcoin-hotfix-candidate-node27-${run_nonce}"
    capture_phase_a_tooling_identity ||
        fail 'exact Phase-A package/tooling identity could not be recorded before mutation'
    audit_unlock_helper || fail 'external unlock helper is not provably unlock-only'
    verify_bundle_identity || fail 'sealed GitHub artifact/bundle/attestation identity failed'
    verify_loaded_candidate_image || fail 'loaded local candidate image identity failed'
    install -m 600 -o root -g root "$CANDIDATE_BUNDLE_MANIFEST" \
        "${EVIDENCE}/candidate-bundle-manifest.json"
    install -m 600 -o root -g root "$CANDIDATE_BUNDLE_SHA256SUMS" \
        "${EVIDENCE}/candidate-bundle-sha256sums.txt"
    install -m 600 -o root -g root "$CANDIDATE_BINARY_SHA256SUMS" \
        "${EVIDENCE}/candidate-binary-sha256sums.txt"
    install -m 600 -o root -g root \
        "${CANDIDATE_BUNDLE_DIR}/${HOTFIX_CANDIDATE_PREFIX}-SOURCE_COMMIT.txt" \
        "${EVIDENCE}/candidate-source-commit.txt"
    install -m 600 -o root -g root \
        "${CANDIDATE_BUNDLE_DIR}/${HOTFIX_CANDIDATE_PREFIX}-REPRODUCIBILITY.txt" \
        "${EVIDENCE}/candidate-reproducibility.txt"
    install -m 600 -o root -g root \
        "${CANDIDATE_BUNDLE_DIR}/${HOTFIX_CANDIDATE_PREFIX}-UNSIGNED-CANARY.txt" \
        "${EVIDENCE}/candidate-unsigned-canary.txt"
    install -m 600 -o root -g root "$CANDIDATE_SOURCE_SIGNATURE" \
        "${EVIDENCE}/candidate-source-signature.json"
    install -m 600 -o root -g root "$CANDIDATE_CORE_CI" \
        "${EVIDENCE}/candidate-core-ci.json"
    install -m 600 -o root -g root "$CANDIDATE_TOOLCHAIN" \
        "${EVIDENCE}/candidate-toolchain.txt"
    install -m 600 -o root -g root "$CANDIDATE_PROVENANCE" \
        "${EVIDENCE}/candidate-provenance.intoto.json"
    install -m 600 -o root -g root "$CANDIDATE_OCI_IDENTITY" \
        "${EVIDENCE}/candidate-oci-identity.json"

    exec 5>/run/blackcoin-endpoint-guard.lock
    flock -w 1800 5 || fail 'endpoint guard did not drain'
    exec 9>/var/run/blackcoin-node-cutover.lock
    flock -w 1800 9 || fail 'node cutover lock did not drain'
    exec 8>/run/blackcoin-pow-quarantine-cycle.lock
    flock -w 1800 8 || fail 'PoW quarantine lock did not drain'
    exec 7>/var/run/blackcoin-wallet-runtime-guard.lock
    flock -w 1800 7 || fail 'wallet runtime lock did not drain'
    jq -S -n --arg nonce "$run_nonce" '
        {schema:1,run_nonce:$nonce,held:true,
         order:["/run/blackcoin-endpoint-guard.lock","/var/run/blackcoin-node-cutover.lock",
           "/run/blackcoin-pow-quarantine-cycle.lock","/var/run/blackcoin-wallet-runtime-guard.lock"]}
    ' >"${EVIDENCE}/locks.json"
    capture_live_guard_identity || fail 'deployed guard bytes/maintenance contract are not exact'

    [[ "$(sha256sum "$COMPOSE" | awk '{print $1}')" == "$EXPECTED_COMPOSE_SHA256" &&
       "$(docker compose -f "$COMPOSE" config --format json | jq -er '.services.node27.image')" == \
         "$IMMUTABLE_V3014_IMAGE_REF" ]] ||
        fail 'live Compose identity changed while locks were draining'
    [[ "$(docker image inspect -f '{{.Id}}' "$CANDIDATE_IMAGE")" == "$CANDIDATE_IMAGE_ID" &&
       "$(docker image inspect -f '{{.Id}}' "$IMMUTABLE_V3014_IMAGE_REF")" == \
         "$IMMUTABLE_V3014_IMAGE_ID" ]] ||
        fail 'candidate or rollback image identity changed while locks were draining'

    [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER")" == true &&
       "$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER")" == healthy &&
       "$(docker inspect -f '{{.Config.Image}}' "$CONTAINER")" == "$IMMUTABLE_V3014_IMAGE_REF" &&
       "$(docker inspect -f '{{.Image}}' "$CONTAINER")" == "$IMMUTABLE_V3014_IMAGE_ID" ]] ||
        fail 'node27 is not a healthy immutable-v30.1.4 baseline'
    [[ "$(findmnt -n -o SOURCE -T "$HOST_DATADIR")" == "$EXPECTED_DATADIR_DATASET" &&
       "$(findmnt -n -o SOURCE -T "$HOST_DATADIR/blocks")" == "$EXPECTED_BLOCKS_DATASET" &&
       "$(findmnt -n -o SOURCE -T "$HOST_DATADIR/indexes")" == "$EXPECTED_INDEXES_DATASET" &&
       "$(findmnt -n -o SOURCE -T "$HOST_RAW")" == "$EXPECTED_RAW_DATASET" ]] ||
        fail 'node27 storage topology is not the audited dedicated dataset set'
    [[ -f "$HOST_DATADIR/blackcoin.conf" && ! -L "$HOST_DATADIR/blackcoin.conf" ]] ||
        fail 'baseline blackcoin.conf is not a regular file'
    baseline_inspect=$(mktemp "${OPS}/.baseline-inspect.XXXXXX") ||
        fail 'could not stage baseline inspection'
    docker inspect "$CONTAINER" >"$baseline_inspect" || fail 'baseline inspection failed'
    baseline_config_sha=$(sha256sum "$HOST_DATADIR/blackcoin.conf" | awk '{print $1}')
    baseline_mounts_sha=$(inspect_mounts_sha "$baseline_inspect") ||
        fail 'could not bind baseline mounts'
    baseline_network_sha=$(inspect_network_sha "$baseline_inspect") ||
        fail 'could not bind baseline network configuration'
    baseline_restart_policy_json=$(inspect_restart_policy_json "$baseline_inspect") ||
        fail 'could not bind baseline restart policy'
    jq -S -n --arg config "$baseline_config_sha" --arg mounts "$baseline_mounts_sha" \
        --arg network "$baseline_network_sha" --argjson restart "$baseline_restart_policy_json" '
        {schema:1,blackcoin_conf_sha256:$config,mounts_sha256:$mounts,
         network_sha256:$network,restart_policy:$restart}
    ' >"${EVIDENCE}/baseline-runtime-identity.json"
    rm -f -- "$baseline_inspect"
    if grep -Eq '^[[:space:]]*(reindex|reindex-chainstate)[[:space:]]*=[[:space:]]*(1|true|yes)' \
        "$HOST_DATADIR/blackcoin.conf"; then
        fail 'persistent reindex setting is present'
    fi
    docker inspect "$CONTAINER" | jq -S '.[0] | {path:.Path,args:.Args,
        entrypoint:.Config.Entrypoint,cmd:.Config.Cmd}' >"${EVIDENCE}/baseline-invocation.json"
    docker compose -f "$COMPOSE" config --format json | jq -S . \
        >"${EVIDENCE}/baseline-compose-model.json"
    rpc getblockchaininfo >"${EVIDENCE}/baseline-chain.json"
    rpc getnetworkinfo >"${EVIDENCE}/baseline-network.json"
    rpc getwalletinfo >"${EVIDENCE}/baseline-wallet.json"
    rpc getstakinginfo >"${EVIDENCE}/baseline-staking.json"
    rpc getpowmininginfo >"${EVIDENCE}/baseline-pow.json"
    rpc getpowclaimrecoveryinfo true >"${EVIDENCE}/baseline-recovery.json"
    rpc getquantumkeyinventory | jq -S . >"${EVIDENCE}/baseline-quantum-inventory.json"
    rpc listquantumaddresses | jq -S . >"${EVIDENCE}/baseline-quantum-addresses.json"
    rpc listwallets | jq -S . >"${EVIDENCE}/baseline-wallets.json"
    [[ "$(jq -cS . "${EVIDENCE}/baseline-wallets.json")" == '[""]' ]] ||
        fail 'node27 must have exactly one default wallet loaded'
    jq -e '.chain == "main" and .initialblockdownload == false and .blocks == .headers' \
        "${EVIDENCE}/baseline-chain.json" >/dev/null || fail 'baseline chain is not ready'
    jq -e '.networkactive == true and .connections_out >= 3' \
        "${EVIDENCE}/baseline-network.json" >/dev/null || fail 'baseline P2P is not ready'
    jq -e '.enabled == true and .weight > 0' \
        "${EVIDENCE}/baseline-staking.json" >/dev/null || fail 'baseline PoS is not active'
    jq -e '.private_keys_enabled == true and .unlocked_staking_only == false and
        .unlocked_until > now' "${EVIDENCE}/baseline-wallet.json" >/dev/null ||
        fail 'baseline wallet is not normally unlocked'
    legacy_pow_is_feature_detected "${EVIDENCE}/baseline-pow.json" ||
        fail 'baseline is not immutable-v30.1.4 legacy telemetry'
    baseline_mode=$(jq -er 'if .enabled then "enabled" else "disabled" end' \
        "${EVIDENCE}/baseline-pow.json")
    [[ "$baseline_mode" == enabled ]] && baseline_pow_enabled=true
    baseline_payout=$(jq -er '.payout_address | select(type == "string" and length > 0)' \
        "${EVIDENCE}/baseline-pow.json") || fail 'baseline payout is absent'
    rpc validateaddress "$baseline_payout" | jq -e '.isvalid == true' >/dev/null ||
        fail 'baseline payout address is invalid'
    jq -e '.policy_authoritative == true and .policy.automatic_authorized == false and
        .database_outcome_ambiguous == false and .chain_ready == true and
        .wallet_tip_matches == true' "${EVIDENCE}/baseline-recovery.json" >/dev/null ||
        fail 'baseline recovery policy/database/tip is unsafe'
    baseline_recovery_fee=$(jq -er '.confirmed_resolution_fees' \
        "${EVIDENCE}/baseline-recovery.json")
    baseline_cumulative_recovery_fee=$(jq -er \
        '.cumulative_resolution_fees // .confirmed_resolution_fees' \
        "${EVIDENCE}/baseline-recovery.json")
    baseline_pending_manual=$(jq -er '.pending_manual_resolutions' \
        "${EVIDENCE}/baseline-recovery.json")
    baseline_pending_automatic=$(jq -er '.pending_automatic_resolutions' \
        "${EVIDENCE}/baseline-recovery.json")
    baseline_recovery_metrics_json=$(recovery_metrics_json \
        "${EVIDENCE}/baseline-recovery.json") || fail 'baseline recovery metrics are invalid'
    baseline_recovery_metrics_sha=$(printf '%s' "$baseline_recovery_metrics_json" | sha256sum |
        awk '{print $1}') || fail 'baseline recovery metrics hash failed'
    baseline_quantum_key_count=$(jq -er '
        if type == "array" then length
        elif (.keys? | type) == "array" then (.keys | length)
        elif (.inventory? | type) == "array" then (.inventory | length)
        elif (.total? | type) == "number" then .total else error("schema") end
    ' "${EVIDENCE}/baseline-quantum-inventory.json")
    baseline_quantum_sha=$(sha256sum "${EVIDENCE}/baseline-quantum-inventory.json" | awk '{print $1}')
    capture_wallet_state baseline || fail 'could not capture baseline wallet differential'

    mutation_started=1
    suspend_guard_authority || fail 'could not suspend automatic-start authority'
    publish_maintenance_marker || fail 'could not publish crash-safe maintenance authority'
    install -m 600 -o root -g root "$MAINTENANCE_MARKER" \
        "${EVIDENCE}/maintenance-marker-activated.json"
    install -m 600 -o root -g root "$MAINTENANCE_NONCE" \
        "${EVIDENCE}/maintenance-nonce.txt"
    install -m 600 -o root -g root "$CRASH_RECOVERY_PROCEDURE" \
        "${EVIDENCE}/crash-recovery-procedure.json"
    rpc staking false >"${EVIDENCE}/baseline-staking-stop.json" || fail 'baseline PoS stop failed'
    rpc setpowmining false 1 1 false >"${EVIDENCE}/baseline-pow-stop.json" || fail 'baseline PoW stop failed'
    rpc walletlock >"${EVIDENCE}/baseline-wallet-lock.json" || fail 'baseline wallet lock failed'
    rpc getpowmininginfo >"${EVIDENCE}/baseline-cold-pow.json"
    rpc getstakinginfo >"${EVIDENCE}/baseline-cold-staking.json"
    rpc getwalletinfo >"${EVIDENCE}/baseline-cold-wallet.json"
    jq -e '.enabled == false and .state == "disabled" and .hashrate == 0' \
        "${EVIDENCE}/baseline-cold-pow.json" >/dev/null || fail 'baseline PoW did not stop'
    jq -e '.unlocked_until == 0' "${EVIDENCE}/baseline-cold-wallet.json" >/dev/null ||
        fail 'baseline wallet did not lock'
    jq -e '.enabled == false and .staking == false and .worker_running == false' \
        "${EVIDENCE}/baseline-cold-staking.json" >/dev/null || fail 'baseline PoS did not join'
    capture_wallet_state prelaunch || fail 'could not capture cold prelaunch wallet state'
    stop_with_restart_authority_disabled baseline-pre-snapshot \
        "$IMMUTABLE_V3014_IMAGE_ID" "$IMMUTABLE_V3014_IMAGE_REF" \
        "${EVIDENCE}/baseline-cold-stop-authority.json" \
        "${EVIDENCE}/baseline-stop-rpc.json" ||
        fail 'baseline daemon did not stop with restart authority disabled'
    write_state BASELINE_COLD || fail 'could not record BASELINE_COLD'
    create_snapshot_set || fail 'could not create and hold the exact rollback snapshot set'

    write_wrapper_override "$CANDIDATE_IMAGE" || fail 'could not write sealed Phase-A override'
    create_stopped_from_override || fail 'candidate was not created stopped'
    capture_created_inspection "${EVIDENCE}/candidate-created-stopped.json" \
        "$CANDIDATE_IMAGE_ID" || fail 'stopped candidate inspection failed'
    write_state CANDIDATE_CREATED_STOPPED || fail 'could not record stopped candidate state'
    logs_since=$(date -u +%FT%TZ)
    docker start "$CONTAINER" >/dev/null || fail 'candidate start failed'
    wait_rpc || fail 'candidate did not start'
    [[ "$(docker inspect -f '{{.Config.Image}}' "$CONTAINER")" == "$CANDIDATE_IMAGE" &&
       "$(docker inspect -f '{{.Image}}' "$CONTAINER")" == "$CANDIDATE_IMAGE_ID" ]] ||
        fail 'running candidate identity differs from sealed image'
    capture_invocation A "$CANDIDATE_IMAGE_ID" "${EVIDENCE}/candidate-created-stopped.json" \
        "${EVIDENCE}/candidate-invocation-initial.json" || fail 'candidate invocation proof failed'
    assert_setup_processes || fail 'sealed GUI wrapper setup differs from immutable startup behavior'
    disable_phase_a_interactive_surfaces ||
        fail 'Phase-A GUI/VNC interaction services could not be synchronously stopped'
    capture_nonpublication "${EVIDENCE}/phase-a-nonpublication-initial.json" ||
        fail 'Phase-A RPC/GUI/VNC/keeper/relay isolation is not proven'
    rpc getpowmininginfo >"${EVIDENCE}/candidate-locked-pow.json"
    rpc getpowclaimrecoveryinfo true >"${EVIDENCE}/candidate-locked-recovery.json"
    rpc getwalletinfo >"${EVIDENCE}/candidate-locked-wallet.json"
    rpc getstakinginfo >"${EVIDENCE}/candidate-locked-staking.json"
    candidate_off_is_safe "${EVIDENCE}/candidate-locked-pow.json" \
        "${EVIDENCE}/candidate-locked-recovery.json" \
        "${EVIDENCE}/candidate-locked-wallet.json" \
        "${EVIDENCE}/candidate-locked-staking.json" ||
        fail 'candidate startup did not expose the complete safe typed gate while locked/off'
    [[ "$(jq -er '.payout_address' "${EVIDENCE}/candidate-locked-pow.json")" == "$baseline_payout" ]] ||
        fail 'candidate payout binding changed'
    capture_wallet_state candidate-locked || fail 'could not capture locked candidate state'
    cmp -s "${EVIDENCE}/prelaunch-wallet-transactions.json" \
        "${EVIDENCE}/candidate-locked-wallet-transactions.json" ||
        fail 'locked candidate changed wallet transactions before authority was granted'

    write_state PHASE_A_RUNNING || fail 'could not record Phase-A running state'
    run_unlock_helper || fail 'candidate normal wallet unlock failed'
    rpc getwalletinfo | jq -e '.unlocked_until > now and .unlocked_staking_only == false' \
        >/dev/null || fail 'unlock helper did not produce a normal unlock'
    rpc getstakinginfo | jq -e '.enabled == false and .staking == false and .worker_running == false' \
        >/dev/null || fail 'hard -staking=0 gate did not remain authoritative after unlock'
    rpc setpowmining true 1 1 false >"${EVIDENCE}/candidate-pow-start.json" ||
        fail 'explicit one-core/one-percent PoW start failed'
    collect_progress_across_restart ||
        fail 'typed gate/disabled-PoS/nonpublication/>=3-tip proof failed'
    stop_pow_join || fail 'candidate PoW worker did not synchronously stop and join'
    docker logs --since "$logs_since" "$CONTAINER" \
        >"${EVIDENCE}/candidate-through-pow-stop.log" 2>&1 ||
        fail 'candidate log capture through PoW stop failed'
    if grep -Eiq 'reindexing|reindex-chainstate|reindex started|replay rebuild started|gold rush rewind' \
        "${EVIDENCE}/candidate-through-pow-stop.log"; then
        fail 'candidate startup or restart initiated an unexpected rewind/reindex'
    fi
    capture_nonpublication "${EVIDENCE}/phase-a-nonpublication-final.json" ||
        fail 'final nonpublication surface proof failed'
    capture_final_proof_inputs || fail 'final wallet/claim/mempool/observer proof capture failed'
    [[ "$(sha256sum "${EVIDENCE}/candidate-final-quantum-inventory.json" | awk '{print $1}')" == "$baseline_quantum_sha" ]] ||
        fail 'candidate changed quantum-key inventory'
    stop_candidate_cleanly || fail 'wallet lock or clean candidate stop failed'
    docker logs --since "$logs_since" "$CONTAINER" >"${EVIDENCE}/candidate-complete.log" 2>&1 ||
        fail 'post-stop complete candidate log capture failed'
    if grep -Eiq 'reindexing|reindex-chainstate|reindex started|replay rebuild started|gold rush rewind' \
        "${EVIDENCE}/candidate-complete.log"; then
        fail 'candidate startup or restart initiated an unexpected rewind/reindex'
    fi
    jq -S -n --arg captured "$(date -u +%FT%TZ)" \
        --arg stopped_sha "$(sha256sum "${EVIDENCE}/candidate-stopped.json" | awk '{print $1}')" \
        --arg log_sha "$(sha256sum "${EVIDENCE}/candidate-complete.log" | awk '{print $1}')" \
        --arg finished "$(jq -er '.finished_at' "${EVIDENCE}/candidate-stopped.json")" '
        {schema:1,captured_utc:$captured,candidate_finished_at:$finished,
         candidate_stopped_receipt_sha256:$stopped_sha,complete_log_sha256:$log_sha,
         captured_after_clean_stop:true}
    ' >"${EVIDENCE}/candidate-post-stop-log-receipt.json" ||
        fail 'post-stop log receipt creation failed'
    build_no_recovery_spend_proof || fail 'stopped-candidate claim differential failed'
    seal_pre_rewind_evidence || fail 'pre-rewind evidence seal failed'
    "$PACKAGE_ROOT/verify-evidence.sh" phase-a-pre-rewind "$EVIDENCE" \
        >"${OPS}/pre-rewind-verifier.stdout" 2>&1 ||
        fail 'offline pre-rewind evidence verification failed'
    jq -S -n --arg nonce "$run_nonce" --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" \
        --arg manifest "$(sha256sum "${EVIDENCE}/PRE_REWIND_SHA256SUMS" | awk '{print $1}')" \
        --arg verifier "$(sha256sum "$PACKAGE_ROOT/verify-evidence.sh" | awk '{print $1}')" '
        {schema:1,mode:"phase-a-pre-rewind",result:"passed",run_nonce:$nonce,
         candidate_source_sha:$source,pre_rewind_manifest_sha256:$manifest,
         verifier_sha256:$verifier}
    ' >"${EVIDENCE}/pre-rewind-verifier.json" || fail 'verifier receipt creation failed'
    rm -f -- "${OPS}/pre-rewind-verifier.stdout"
    chmod 600 "${EVIDENCE}/pre-rewind-verifier.json"
    write_state PRE_REWIND_VERIFIED || fail 'could not record pre-rewind verification'
    install -m 600 -o root -g root "$PHASE_STATE" "${EVIDENCE}/pre-rewind-state.json" ||
        fail 'could not bind PRE_REWIND_VERIFIED state'
    issue_rewind_safe_certificate || fail 'positive REWIND_SAFE certificate was not issued'
    certified_rewind_snapshot_set || fail 'certified data rewind failed; node contained'
    start_base_hard_quarantine || fail 'immutable base hard-quarantine start failed'
    wait_base_catchup || fail 'base chainwork/tip/wallet catch-up proof failed'
    destroy_snapshot_set_after_catchup || fail 'snapshot release/destruction proof failed'
    restore_baseline_after_snapshot_absence || fail 'baseline policy restoration failed'

    post_manifest="${EVIDENCE}/POST_REWIND_SHA256SUMS"
    (cd "$EVIDENCE" && find . -type f ! -name POST_REWIND_SHA256SUMS \
        ! -name SHA256SUMS ! -name RESULT.json -print0 | sort -z | xargs -0 sha256sum) \
        >"$post_manifest" || fail 'post-rewind manifest failed'
    jq -S -n --arg candidate "$HOTFIX_CANDIDATE_SOURCE_SHA" \
        --arg base "$IMMUTABLE_V3014_SOURCE_SHA" --arg nonce "$run_nonce" \
        --arg cert "$(sha256sum "$REWIND_SAFE" | awk '{print $1}')" \
        --arg catchup "$(sha256sum "$BASE_CATCHUP_PROOF" | awk '{print $1}')" \
        --arg absence "$(sha256sum "$SNAPSHOT_ABSENCE_PROOF" | awk '{print $1}')" \
        --arg base_stop "$(sha256sum "${EVIDENCE}/base-quarantine-stop-authority.json" |
          awk '{print $1}')" \
        --arg restored_container "$(sha256sum "${EVIDENCE}/baseline-restored-container.json" |
          awk '{print $1}')" \
        --arg manifest "$(sha256sum "$post_manifest" | awk '{print $1}')" \
        --arg tooling "$CANDIDATE_TOOLING_COMMIT" \
        --arg tooling_identity "$phase_a_tooling_identity_sha" \
        --arg package "$phase_a_package_sha" --arg phase_a_script "$phase_a_script_sha" \
        --arg phase_b_script "$phase_b_script_sha" --arg verifier "$phase_a_verifier_sha" \
        --arg contract "$phase_a_contract_sha" \
        --arg recovery_metrics "$baseline_recovery_metrics_sha" '
        {schema:3,phase:"A",node:27,result:"passed",candidate_source_sha:$candidate,
         base_source_sha:$base,run_nonce:$nonce,rewind_safe_certificate_verified:true,
         data_rewind_completed:true,base_hard_quarantine_catchup_verified:true,
         all_snapshots_absent_before_baseline_restore:true,baseline_restored:true,
         phase_b_invoked:false,promotion_marker_absent:true,rewind_safe_sha256:$cert,
         catchup_proof_sha256:$catchup,snapshot_absence_sha256:$absence,
         base_quarantine_stop_authority_sha256:$base_stop,
         baseline_restored_container_sha256:$restored_container,
         evidence_sha256sums_sha256:$manifest,tooling_commit:$tooling,
         phase_a_tooling_identity_sha256:$tooling_identity,
         package_sha256sums_sha256:$package,phase_a_script_sha256:$phase_a_script,
         phase_b_script_sha256:$phase_b_script,verifier_sha256:$verifier,
         typed_contract_sha256:$contract,baseline_recovery_metrics_sha256:$recovery_metrics}
    ' >"${EVIDENCE}/RESULT.json" || fail 'Phase-A RESULT creation failed'
    hotfix_phase_a_result_file_is_valid "${EVIDENCE}/RESULT.json" || fail 'Phase-A RESULT invalid'
    seal_evidence_best_effort || fail 'evidence integrity seal failed'
    (cd "$EVIDENCE" && sha256sum --strict -c SHA256SUMS >/dev/null) ||
        fail 'evidence integrity recheck failed'
    "$PACKAGE_ROOT/verify-evidence.sh" phase-a-final "$EVIDENCE" ||
        fail 'final Phase-A evidence verification failed'
    write_state PHASE_A_PASSED || fail 'could not record Phase-A completion'
    restore_guard_authority || fail 'automatic-start authority was not restored'
    remove_own_maintenance_marker || fail 'maintenance authority was not retired'
    result='passed'
    printf 'Node27 Phase A passed REWIND_SAFE, base catch-up, and snapshot absence. Evidence: %s\n' \
        "$EVIDENCE"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
