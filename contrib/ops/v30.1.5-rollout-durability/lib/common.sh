# shellcheck shell=bash
# Shared fail-closed helpers for the v30.1.5 rollout/durability consumer.

export LC_ALL=C

v3015_die()
{
    printf 'v30.1.5 rollout: %s\n' "$*" >&2
    return 1
}

v3015_require_commands()
{
    local command
    for command in "$@"; do
        command -v "$command" >/dev/null 2>&1 ||
            v3015_die "required command is unavailable: $command" || return
    done
}

v3015_sha256_file()
{
    sha256sum -- "$1" | awk '{print $1}'
}

v3015_is_sha256()
{
    [[ "${1:-}" =~ ^[0-9a-f]{64}$ ]]
}

v3015_is_git_sha()
{
    [[ "${1:-}" =~ ^[0-9a-f]{40}$ ]]
}

v3015_is_image_id()
{
    [[ "${1:-}" =~ ^sha256:[0-9a-f]{64}$ ]]
}

v3015_is_digest_ref()
{
    [[ "${1:-}" =~ ^[A-Za-z0-9._/-]+@sha256:[0-9a-f]{64}$ ]]
}

v3015_is_candidate_image_ref()
{
    [[ "${1:-}" =~ ^qqblackcoin/blackcoin-v4-gui@sha256:[0-9a-f]{64}$ ]]
}

v3015_has_placeholder()
{
    [[ "${1:-}" == *'__'* || "${1:-}" == *PLACEHOLDER* || -z "${1:-}" ]]
}

v3015_require_resolved()
{
    local name=$1 value=${2:-}
    ! v3015_has_placeholder "$value" ||
        v3015_die "$name is unresolved" || return
}

v3015_secure_regular_file()
{
    local file=$1 expected_mode=${2:-600} stat_value
    [[ -f "$file" && ! -L "$file" ]] || return 1
    [[ "$(realpath -e -- "$file" 2>/dev/null)" == "$file" ]] || return 1
    stat_value=$(stat -c '%u:%g:%a:%h' -- "$file" 2>/dev/null) || return 1
    [[ "$stat_value" == "0:0:${expected_mode}:1" ]]
}

v3015_secure_root_executable()
{
    local file=$1
    [[ -f "$file" && ! -L "$file" ]] || return 1
    [[ "$(realpath -e -- "$file" 2>/dev/null)" == "$file" ]] || return 1
    [[ "$(stat -c '%u:%g:%a:%h' -- "$file" 2>/dev/null)" == 0:0:700:1 ]]
}

v3015_secure_directory()
{
    local directory=$1
    [[ -d "$directory" && ! -L "$directory" ]] || return 1
    [[ "$(realpath -e -- "$directory" 2>/dev/null)" == "$directory" ]] || return 1
    [[ "$(stat -c '%u:%g:%a' -- "$directory" 2>/dev/null)" == 0:0:700 ]]
}

v3015_secure_ancestry()
{
    local path=$1 directory owner mode
    directory=$path
    [[ -d "$directory" ]] || directory=$(dirname -- "$directory")
    while :; do
        owner=$(stat -c '%u:%g' -- "$directory" 2>/dev/null) || return 1
        mode=$(stat -c '%a' -- "$directory" 2>/dev/null) || return 1
        [[ "$owner" == 0:0 && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
        (( (8#$mode & 0022) == 0 )) || return 1
        [[ "$directory" == / ]] && break
        directory=$(dirname -- "$directory")
    done
}

v3015_assert_flat_secure_evidence()
{
    local directory=$1 file
    v3015_secure_directory "$directory" ||
        v3015_die "evidence directory must be root:root 0700: $directory" || return
    v3015_secure_ancestry "$directory" ||
        v3015_die "evidence ancestry is writable or untrusted: $directory" || return
    while IFS= read -r -d '' file; do
        [[ "$(dirname -- "$file")" == "$directory" ]] ||
            v3015_die "nested evidence is forbidden: $file" || return
        v3015_secure_regular_file "$file" 600 ||
            v3015_die "evidence file must be root:root 0600, regular, and single-linked: $file" || return
    done < <(find "$directory" -mindepth 1 -print0)
}

v3015_atomic_write()
{
    local output=$1 temporary
    temporary="${output}.tmp.$$"
    [[ ! -e "$temporary" && ! -L "$temporary" ]] || return 1
    umask 077
    cat >"$temporary"
    chmod 600 "$temporary"
    mv -f -- "$temporary" "$output"
}

# Publish rollout-containment authority without an overwrite window. The hard
# link is the same-filesystem, no-clobber commit point. Both the committed file
# and its parent directory are then forced durable and reread exactly.
v3015_publish_authority_noclobber()
{
    local output=$1 directory temporary expected_sha actual_sha owner_mode
    directory=$(dirname -- "$output")
    temporary=$(mktemp "${output}.tmp.XXXXXX") || return 1
    chmod 600 "$temporary" || { rm -f -- "$temporary"; return 1; }
    if ! cat >"$temporary"; then rm -f -- "$temporary"; return 1; fi
    expected_sha=$(v3015_sha256_file "$temporary") || { rm -f -- "$temporary"; return 1; }
    sync -f "$temporary" || { rm -f -- "$temporary"; return 1; }
    if ! ln -- "$temporary" "$output"; then rm -f -- "$temporary"; return 1; fi
    rm -- "$temporary" || return 1
    sync -f "$output" && sync -f "$directory" || return 1
    actual_sha=$(v3015_sha256_file "$output") || return 1
    owner_mode=$(stat -c '%u:%g:%a:%h' -- "$output") || return 1
    [[ "$actual_sha" == "$expected_sha" &&
       "$owner_mode" == "${EUID}:$(id -g):600:1" ]]
}

# /boot is VFAT on the reviewed host and cannot create hard links. GNU mv -nT
# provides the no-replace rename path there. A silent -n refusal is detected by
# requiring the same-directory temporary name to have disappeared.
v3015_publish_vfat_authority_noclobber()
{
    local output=$1 directory temporary expected_sha actual_sha owner_mode
    directory=$(dirname -- "$output")
    temporary=$(mktemp "${output}.tmp.XXXXXX") || return 1
    chmod 600 "$temporary" || { rm -f -- "$temporary"; return 1; }
    if ! cat >"$temporary"; then rm -f -- "$temporary"; return 1; fi
    expected_sha=$(v3015_sha256_file "$temporary") || { rm -f -- "$temporary"; return 1; }
    sync -f "$temporary" || { rm -f -- "$temporary"; return 1; }
    if ! mv -nT -- "$temporary" "$output"; then rm -f -- "$temporary"; return 1; fi
    if [[ -e "$temporary" || -L "$temporary" ]]; then
        rm -f -- "$temporary"
        return 1
    fi
    sync -f "$output" && sync -f "$directory" || return 1
    actual_sha=$(v3015_sha256_file "$output") || return 1
    owner_mode=$(stat -c '%u:%g:%a:%h' -- "$output") || return 1
    [[ "$actual_sha" == "$expected_sha" &&
       "$owner_mode" == "${EUID}:$(id -g):600:1" ]]
}

v3015_remove_owned_authority()
{
    local output=$1 expected_sha=$2 directory
    directory=$(dirname -- "$output")
    [[ -f "$output" && ! -L "$output" ]] || return 1
    [[ "$(stat -c '%u:%g:%a:%h' -- "$output")" == "${EUID}:$(id -g):600:1" ]] || return 1
    [[ "$(v3015_sha256_file "$output")" == "$expected_sha" ]] || return 1
    rm -- "$output" || return 1
    sync -f "$directory" || return 1
    [[ ! -e "$output" && ! -L "$output" ]]
}

v3015_stage_root_executable_copy()
{
    local source=$1 expected_sha=$2 output=$3 directory temporary actual_sha
    directory=$(dirname -- "$output")
    v3015_secure_root_executable "$source" || return 1
    v3015_secure_ancestry "$source" || return 1
    v3015_secure_directory "$directory" || return 1
    [[ "$(v3015_sha256_file "$source")" == "$expected_sha" ]] || return 1
    [[ ! -e "$output" && ! -L "$output" ]] || return 1
    temporary=$(mktemp "${output}.tmp.XXXXXX") || return 1
    if ! install -o root -g root -m 0700 -- "$source" "$temporary"; then
        rm -f -- "$temporary"
        return 1
    fi
    sync -f "$temporary" || { rm -f -- "$temporary"; return 1; }
    actual_sha=$(v3015_sha256_file "$temporary") || { rm -f -- "$temporary"; return 1; }
    [[ "$actual_sha" == "$expected_sha" ]] || { rm -f -- "$temporary"; return 1; }
    if ! ln -- "$temporary" "$output"; then rm -f -- "$temporary"; return 1; fi
    rm -- "$temporary" || return 1
    sync -f "$output" && sync -f "$directory" || return 1
    v3015_secure_root_executable "$output" || return 1
    [[ "$(v3015_sha256_file "$output")" == "$expected_sha" ]]
}

v3015_remove_owned_root_executable()
{
    local output=$1 expected_sha=$2 directory
    directory=$(dirname -- "$output")
    v3015_secure_root_executable "$output" || return 1
    [[ "$(v3015_sha256_file "$output")" == "$expected_sha" ]] || return 1
    rm -- "$output" || return 1
    sync -f "$directory" || return 1
    [[ ! -e "$output" && ! -L "$output" ]]
}

v3015_verify_manifest()
{
    local directory=$1 manifest=$2
    [[ "$(dirname -- "$manifest")" == "$directory" ]] || return 1
    (
        cd "$directory" || exit
        sha256sum -c "$(basename -- "$manifest")" >/dev/null 2>&1
    )
}

v3015_load_reviewed_env()
{
    local file=$1
    v3015_secure_regular_file "$file" 600 ||
        v3015_die "environment must be a root-owned 0600 regular file: $file" || return
    v3015_secure_ancestry "$file" ||
        v3015_die "environment ancestry is writable or untrusted: $file" || return
    # This file is operator-authored authority. It is sourced only after its
    # ownership/mode/link checks pass; every material value is validated again.
    # shellcheck disable=SC1090
    source "$file"
}

v3015_unlock_helper_is_audited()
{
    local helper=$1 forbidden size lines
    v3015_secure_regular_file "$helper" 600 && v3015_secure_ancestry "$helper" || return 1
    [[ "$(v3015_sha256_file "$helper")" == \
       acf28446e842fd0fa92b06c2ebc182e9da38fcde7bac06dd920d50a33e4e3dd1 ]] || return 1
    bash -n "$helper" || return 1
    forbidden=$(grep -Eio '\b(setstaking|setpowmining|sendrawtransaction|createshadowpowclaimresolution|commitshadowpowclaimresolution|resolveshadowpowclaims|setpowclaimrecovery|getnewaddress|getnewquantumaddress|setpowminingaddress|sendtoaddress|sendmany|fundrawtransaction|signrawtransaction[^[:space:]]*|abandontransaction|resendwallettransactions|forcerelay|walletnotify|zmqpub(rawtx|hashtx|sequence)|eval|source)\b' \
        "$helper" | tr '[:upper:]' '[:lower:]' | sort -u || true)
    [[ -z "$forbidden" ]] || return 1
    [[ "$(grep -Eio '\bwalletpassphrase\b' "$helper" | wc -l | tr -d ' ')" == 1 &&
       "$(grep -Eio '\blistwallets\b' "$helper" | wc -l | tr -d ' ')" == 1 &&
       "$(grep -Eio '\bgetwalletinfo\b' "$helper" | wc -l | tr -d ' ')" == 2 &&
       "$(grep -Eio '\bgetstakinginfo\b' "$helper" | wc -l | tr -d ' ')" == 2 &&
       "$(grep -Eio '\b(walletpassphrase|listwallets|getwalletinfo|getstakinginfo)\b' \
          "$helper" | wc -l | tr -d ' ')" == 6 ]] || return 1
    grep -Eq 'walletpassphrase.*[[:space:]]false([[:space:]]|$)' "$helper" || return 1
    grep -Eq '(^|[^[:alnum:]_])(eval|source|xtrace|set[[:space:]]+-x)([^[:alnum:]_]|$)' \
        "$helper" && return 1
    size=$(stat -c '%s' -- "$helper") || return 1
    lines=$(wc -l <"$helper" | tr -d ' ') || return 1
    [[ "$size" == 3206 && "$lines" == 54 ]]
}

v3015_verify_package_tree()
{
    local root=$1 manifest actual listed file owner mode
    manifest="$root/SHA256SUMS"
    [[ "$(realpath -e -- "$root" 2>/dev/null)" == "$root" ]] || return 1
    v3015_secure_ancestry "$root" || return 1
    v3015_secure_regular_file "$manifest" 600 || return 1
    [[ "$(realpath -e -- "${PACKAGE_SHA256SUMS:-}" 2>/dev/null)" == "$manifest" ]] || return 1
    [[ "$(v3015_sha256_file "$manifest")" == "${PACKAGE_SHA256SUMS_SHA256:-}" ]] || return 1
    ! grep -Eq 'UNSEALED|PLACEHOLDER|__' "$manifest" || return 1
    [[ -z "$(find "$root" -type l -print -quit)" ]] || return 1
    actual=$(find "$root" -type f ! -path "$manifest" -exec sh -c '
      for path do printf "%s\n" "${path#"$1"/}"; done
    ' sh "$root" {} + | sort) || return 1
    listed=$(awk '{print $2}' "$manifest" | sed 's#^\*\?##; s#^\./##' | sort) || return 1
    [[ "$actual" == "$listed" && "$(printf '%s\n' "$actual" | sed '/^$/d' | wc -l)" -eq 14 ]] || return 1
    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        [[ -f "$root/$file" && ! -L "$root/$file" ]] || return 1
        owner=$(stat -c '%u:%g:%h' -- "$root/$file" 2>/dev/null) || return 1
        mode=$(stat -c '%a' -- "$root/$file" 2>/dev/null) || return 1
        [[ "$owner" == 0:0:1 && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
        (( (8#$mode & 0022) == 0 )) || return 1
    done <<<"$actual"
    v3015_verify_manifest "$root" "$manifest"
}

v3015_validate_release_env()
{
    local expected_fingerprint='SHA256:jAkpBudDw+ntWHSUx3e1KY+czAFjnlaPxQtRFtptL70'
    local name
    v3015_is_git_sha "${SOURCE_SHA:-}" ||
        v3015_die 'SOURCE_SHA is not a resolved full commit identity' || return
    v3015_is_git_sha "${SOURCE_TREE:-}" ||
        v3015_die 'SOURCE_TREE is not a resolved full tree identity' || return
    [[ "${SOURCE_SIGNING_FINGERPRINT:-}" == "$expected_fingerprint" &&
       "${SOURCE_SIGNATURE_VERIFIED:-}" == 1 ]] ||
        v3015_die 'final source signature is not reconciled to Blackcoin-Dev' || return
    [[ "${CORE_VERSION_NUMERIC:-}" == 300105 ]] ||
        v3015_die 'CORE_VERSION_NUMERIC must be 300105' || return
    [[ "${CORE_SUBVERSION:-}" == '/Blackcoin:30.1.5/' ]] ||
        v3015_die 'CORE_SUBVERSION must be /Blackcoin:30.1.5/' || return
    [[ "${RUNTIME_ENTRYPOINT_BODY_SHA256:-}" == 753acc9904b48c411f5514abface930f79d72d00c9d73e91435a6511877d47b4 ]] ||
        v3015_die 'runtime wrapper body identity mismatch' || return
    [[ "${NORMAL_UNLOCK_HELPER_SHA256:-}" == \
         acf28446e842fd0fa92b06c2ebc182e9da38fcde7bac06dd920d50a33e4e3dd1 ]] ||
        v3015_die 'normal-unlock-only helper identity mismatch' || return
    [[ "${CORE_CI_RUN_ID:-}" =~ ^[1-9][0-9]*$ ]] ||
        v3015_die 'CORE_CI_RUN_ID is invalid' || return
    [[ "${CORE_CI_CONCLUSION:-}" == success ]] ||
        v3015_die 'exact-SHA Core CI is not recorded as successful' || return
    [[ "${CORE_CI_HEAD_SHA:-}" == "$SOURCE_SHA" ]] ||
        v3015_die 'Core CI head does not equal SOURCE_SHA' || return
    v3015_require_resolved CORE_CI_WORKFLOW "${CORE_CI_WORKFLOW:-}" || return
    [[ "${CANDIDATE_ARTIFACT_RUN_ID:-}" =~ ^[1-9][0-9]*$ &&
       "${CANDIDATE_ARTIFACT_RUN_ATTEMPT:-}" =~ ^[1-9][0-9]*$ ]] ||
        v3015_die 'candidate artifact run identity is unresolved' || return
    v3015_require_resolved CANDIDATE_ARTIFACT_NAME "${CANDIDATE_ARTIFACT_NAME:-}" || return
    v3015_is_candidate_image_ref "${CANDIDATE_IMAGE_REF:-}" ||
        v3015_die 'CANDIDATE_IMAGE_REF must be the canonical immutable candidate repository' || return
    v3015_is_image_id "${CANDIDATE_IMAGE_ID:-}" ||
        v3015_die 'CANDIDATE_IMAGE_ID is invalid' || return
    for name in CANDIDATE_BUNDLE_SHA256 CANDIDATE_OCI_ARCHIVE_SHA256 \
        CANDIDATE_OCI_MANIFEST_SHA256 CANDIDATE_BLACKCOIND_SHA256 \
        CANDIDATE_BLACKCOIN_CLI_SHA256 CANDIDATE_BLACKCOIN_QT_SHA256 \
        CANDIDATE_BLACKCOIN_TX_SHA256 CANDIDATE_BLACKCOIN_WALLET_SHA256 \
        CANDIDATE_BLACKCOIN_UTIL_SHA256 CANDIDATE_TOOLING_SHA256 \
        CANDIDATE_MANIFEST_SHA256 CANDIDATE_PROVENANCE_SHA256 \
        PHASE_B_RESULT_SHA256 PHASE_A_RESULT_SHA256 \
        PHASE_B_PROMOTION_MARKER_SHA256 NINE_PATH_CANARY_SEAL_SHA256 \
        NINE_PATH_PHASE_B_TOOLING_IDENTITY_SHA256 NINE_PATH_PHASE_B_SCRIPT_SHA256 \
        NINE_PATH_VERIFIER_SHA256 NINE_PATH_TYPED_CONTRACT_SHA256 \
        PACKAGE_SHA256SUMS_SHA256 EXPECTED_COMPOSE_SHA256 \
        EXPECTED_IMAGE_POLICY_SHA256 FINAL_IMAGE_POLICY_SHA256 FINAL_COMPOSE_SHA256 \
        POST_COMPOSE_RECONCILE_IDENTITY_SHA256 \
        RUNTIME_POLICY_HANDOFF_RECEIPT_SHA256 \
        PERSISTENT_COMPOSE_HANDOFF_RECEIPT_SHA256 \
        EXPECTED_RUNTIME_GUARD_SHA256 EXPECTED_ENDPOINT_GUARD_SHA256 \
        RENDERED_RUNTIME_GUARD_SHA256 RENDERED_ENDPOINT_GUARD_SHA256 \
        NORMAL_UNLOCK_HELPER_SHA256 NODE30_FREE_CLAIM_PROBE_SHA256; do
        v3015_require_resolved "$name" "${!name:-}" || return
        v3015_is_sha256 "${!name}" || v3015_die "$name must be 64 lowercase hex" || return
    done
    v3015_is_git_sha "${NINE_PATH_TOOLING_COMMIT:-}" ||
        v3015_die 'NINE_PATH_TOOLING_COMMIT must be a resolved full commit identity' || return
    for name in PHASE_B_RESULT PHASE_B_PROMOTION_MARKER NINE_PATH_CANARY_SHA256SUMS \
        PACKAGE_SHA256SUMS RELEASE_IDENTITY_JSON NODE30_FREE_CLAIM_PROBE \
        RUNTIME_POLICY_HANDOFF_RECEIPT PERSISTENT_COMPOSE_HANDOFF_RECEIPT \
        POST_COMPOSE_RECONCILE_IDENTITY_PROOF; do
        v3015_require_resolved "$name" "${!name:-}" || return
        [[ "${!name}" == /* ]] || v3015_die "$name must be an absolute reviewed path" || return
    done
    [[ "${COMPOSE_FILE:-}" == \
         /boot/config/plugins/compose.manager/projects/blackcoin30/docker-compose.yml &&
       "${EVIDENCE_ROOT:-}" == \
         /mnt/pulsar/Blackcoin_Blocks/operations/v30.1.5-rollout &&
       "${STATE_DIR:-}" == /boot/config/plugins/blackcoin-quantum-nodes &&
       "${RUNTIME_GUARD_PATH:-}" == \
         /boot/config/plugins/blackcoin-quantum-nodes/blackcoin_wallet_runtime_guard.sh &&
       "${ENDPOINT_GUARD_PATH:-}" == \
         /boot/config/plugins/blackcoin-quantum-nodes/blackcoin_endpoint_guard.sh &&
       "${NORMAL_UNLOCK_HELPER:-}" == \
         /boot/config/plugins/blackcoin-quantum-nodes/blackcoin_node_normal_unlock.sh &&
       "${IMAGE_POLICY_PATH:-}" == \
         /boot/config/plugins/blackcoin-quantum-nodes/fleet-image-policy.json ]] ||
        v3015_die 'reviewed live path contract is unresolved or changed' || return
    [[ "${PHASE_B_STATUS:-}" == PASS && "${PHASE_B_NO_REWIND:-}" == 1 ]] ||
        v3015_die 'a successful no-rewind Phase-B result is mandatory' || return
    [[ "${ROLLOUT_IDENTITY_RECONCILED:-}" == 1 ]] ||
        v3015_die 'rollout identity reconciliation is not complete' || return
    v3015_handoff_receipts_are_valid ||
        v3015_die 'exact runtime-policy/persistent-Compose handoff receipts are invalid' || return
    local authority_value=${LIVE_EXECUTION_CLEARED:-}
    local authority_nonce=${authority_value##*:}
    local expected_native="v30.1.5-native-restart:${SOURCE_SHA}:${authority_nonce}"
    [[ "$authority_nonce" =~ ^[0-9a-f]{32}$ &&
       "$authority_value" == "v30.1.5:${SOURCE_SHA}:${authority_nonce}" &&
       "${NATIVE_RESTART_CLEARED:-}" == "$expected_native" ]] ||
        v3015_die 'live/native-restart confirmations are unresolved or disagree' || return
}

v3015_handoff_receipts_are_valid()
{
    local policy=${RUNTIME_POLICY_HANDOFF_RECEIPT:-}
    local compose=${PERSISTENT_COMPOSE_HANDOFF_RECEIPT:-}
    local reconcile=${POST_COMPOSE_RECONCILE_IDENTITY_PROOF:-}
    local policy_sha compose_sha
    [[ -f "$policy" && ! -L "$policy" && -f "$compose" && ! -L "$compose" &&
       -f "$reconcile" && ! -L "$reconcile" ]] || return 1
    policy_sha=$(v3015_sha256_file "$policy") || return 1
    compose_sha=$(v3015_sha256_file "$compose") || return 1
    [[ "$policy_sha" == "${RUNTIME_POLICY_HANDOFF_RECEIPT_SHA256:-}" &&
       "$compose_sha" == "${PERSISTENT_COMPOSE_HANDOFF_RECEIPT_SHA256:-}" &&
       "$(v3015_sha256_file "$reconcile")" == \
         "${POST_COMPOSE_RECONCILE_IDENTITY_SHA256:-}" ]] || return 1
    jq -e --arg source "$SOURCE_SHA" --arg image "$CANDIDATE_IMAGE_REF" \
      --arg image_id "$CANDIDATE_IMAGE_ID" --arg compose "$FINAL_COMPOSE_SHA256" \
      --arg policy "$FINAL_IMAGE_POLICY_SHA256" '
        type == "object" and (keys | sort) == ["candidate_image_id","candidate_image_ref",
          "final_compose_sha256","final_image_policy_sha256","kind","network_version",
          "node30_role","regular_nodes","schema","source_sha","subversion","verified_utc"] and
        .schema == 1 and .kind == "post-compose-candidate-identity" and
        .source_sha == $source and .candidate_image_ref == $image and
        .candidate_image_id == $image_id and .network_version == 300105 and
        .subversion == "/Blackcoin:30.1.5/" and .final_compose_sha256 == $compose and
        .final_image_policy_sha256 == $policy and
        .regular_nodes == ([range(1;30)] + [31,32]) and .node30_role == "free_claim" and
        (.verified_utc | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))
      ' "$reconcile" >/dev/null || return 1
    jq -e --arg source "$SOURCE_SHA" --arg image "$CANDIDATE_IMAGE_REF" \
      --arg image_id "$CANDIDATE_IMAGE_ID" --arg path "$IMAGE_POLICY_PATH" \
      --arg before "$EXPECTED_IMAGE_POLICY_SHA256" --arg after "$FINAL_IMAGE_POLICY_SHA256" \
      --arg runtime_path "$RUNTIME_GUARD_PATH" --arg runtime "$RENDERED_RUNTIME_GUARD_SHA256" \
      --arg endpoint_path "$ENDPOINT_GUARD_PATH" --arg endpoint "$RENDERED_ENDPOINT_GUARD_SHA256" \
      --arg reconcile_path "$POST_COMPOSE_RECONCILE_IDENTITY_PROOF" \
      --arg reconcile "$POST_COMPOSE_RECONCILE_IDENTITY_SHA256" '
        def keys_expected: ["atomic_install","candidate_image_id","candidate_image_ref",
          "durable_parent_fsync","endpoint_guard_path","endpoint_guard_sha256",
          "image_policy_after_sha256","image_policy_before_sha256","image_policy_path",
          "kind","network_version","node30_role","post_reconcile_candidate_identity_path",
          "post_reconcile_candidate_identity_sha256",
          "receipt_nonce","regular_nodes","runtime_guard_path","runtime_guard_sha256",
          "schema","semantic_300105_accepted","source_sha","subversion"];
        type == "object" and (keys | sort) == (keys_expected | sort) and
        .schema == 1 and .kind == "runtime-policy-handoff" and .source_sha == $source and
        .candidate_image_ref == $image and .candidate_image_id == $image_id and
        .network_version == 300105 and .subversion == "/Blackcoin:30.1.5/" and
        .image_policy_path == $path and .image_policy_before_sha256 == $before and
        .image_policy_after_sha256 == $after and .runtime_guard_path == $runtime_path and
        .runtime_guard_sha256 == $runtime and .endpoint_guard_path == $endpoint_path and
        .endpoint_guard_sha256 == $endpoint and
        .post_reconcile_candidate_identity_path == $reconcile_path and
        .post_reconcile_candidate_identity_sha256 == $reconcile and
        .regular_nodes == ([range(1;30)] + [31,32]) and .node30_role == "free_claim" and
        .semantic_300105_accepted == true and .atomic_install == true and
        .durable_parent_fsync == true and
        (.receipt_nonce | type == "string" and test("^[0-9a-f]{32}$"))
      ' "$policy" >/dev/null || return 1
    jq -e --arg source "$SOURCE_SHA" --arg image "$CANDIDATE_IMAGE_REF" \
      --arg image_id "$CANDIDATE_IMAGE_ID" --arg path "$COMPOSE_FILE" \
      --arg before "$EXPECTED_COMPOSE_SHA256" --arg after "$FINAL_COMPOSE_SHA256" \
      --arg policy_path "$IMAGE_POLICY_PATH" --arg policy_final "$FINAL_IMAGE_POLICY_SHA256" \
      --arg policy_receipt "$policy_sha" \
      --arg runtime_path "$RUNTIME_GUARD_PATH" --arg runtime "$RENDERED_RUNTIME_GUARD_SHA256" \
      --arg endpoint_path "$ENDPOINT_GUARD_PATH" --arg endpoint "$RENDERED_ENDPOINT_GUARD_SHA256" \
      --arg reconcile_path "$POST_COMPOSE_RECONCILE_IDENTITY_PROOF" \
      --arg reconcile "$POST_COMPOSE_RECONCILE_IDENTITY_SHA256" \
      --arg nonce "$(jq -er '.receipt_nonce' "$policy")" '
        def keys_expected: ["atomic_install","candidate_image_id","candidate_image_ref",
          "compose_after_sha256","compose_before_sha256","compose_path","durable_parent_fsync",
          "endpoint_guard_path","endpoint_guard_sha256","image_policy_after_sha256",
          "image_policy_path","kind","network_version","node30_role",
          "post_reconcile_candidate_identity_path","post_reconcile_candidate_identity_sha256",
          "receipt_nonce","regular_nodes",
          "runtime_guard_path","runtime_guard_sha256","runtime_policy_receipt_sha256",
          "schema","semantic_300105_accepted","source_sha","subversion"];
        type == "object" and (keys | sort) == (keys_expected | sort) and
        .schema == 1 and .kind == "persistent-compose-handoff" and .source_sha == $source and
        .candidate_image_ref == $image and .candidate_image_id == $image_id and
        .network_version == 300105 and .subversion == "/Blackcoin:30.1.5/" and
        .compose_path == $path and .compose_before_sha256 == $before and
        .compose_after_sha256 == $after and .image_policy_path == $policy_path and
        .image_policy_after_sha256 == $policy_final and
        .runtime_policy_receipt_sha256 == $policy_receipt and
        .runtime_guard_path == $runtime_path and .runtime_guard_sha256 == $runtime and
        .endpoint_guard_path == $endpoint_path and .endpoint_guard_sha256 == $endpoint and
        .post_reconcile_candidate_identity_path == $reconcile_path and
        .post_reconcile_candidate_identity_sha256 == $reconcile and
        .regular_nodes == ([range(1;30)] + [31,32]) and .node30_role == "free_claim" and
        .semantic_300105_accepted == true and .atomic_install == true and
        .durable_parent_fsync == true and .receipt_nonce == $nonce
      ' "$compose" >/dev/null
}

v3015_contain_container()
{
    local container=$1 state
    docker update --restart=no "$container" >/dev/null 2>&1 ||
        printf 'URGENT: could not disable automatic restart for %s\n' "$container" >&2
    docker stop --time 30 "$container" >/dev/null 2>&1 ||
        printf 'URGENT: clean containment stop failed for %s\n' "$container" >&2
    state=$(docker inspect -f '{{.State.Running}} {{.HostConfig.RestartPolicy.Name}}' \
        "$container" 2>/dev/null) || {
        printf 'URGENT: containment state is UNKNOWN for %s\n' "$container" >&2
        return 1
    }
    [[ "$state" == 'false no' ]] || {
        printf 'URGENT: containment is incomplete for %s: %s\n' "$container" "$state" >&2
        return 1
    }
}
