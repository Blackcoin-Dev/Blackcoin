#!/usr/bin/env bash
export LC_ALL=C
set -Eeuo pipefail

PACKAGE_ROOT=$(CDPATH='' cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || exit 1
readonly PACKAGE_ROOT
# shellcheck source=lib/typed_contract.sh
# shellcheck source-path=SCRIPTDIR
source "$PACKAGE_ROOT/lib/typed_contract.sh"

die()
{
    printf 'EVIDENCE_VERIFY_FAIL: %s\n' "$*" >&2
    exit 1
}

sha_of()
{
    hotfix_sha256_file "$1"
}

recovery_metrics_json()
{
    jq -cS '{pending_manual_resolutions,pending_automatic_resolutions,
      confirmed_manual_resolutions,confirmed_automatic_resolutions,
      confirmed_resolution_fees,automatic_actions_in_window,
      automatic_fee_exposure_in_window,reconciled_descendant_claims,claims_recycled}' "$1"
}

recovery_metrics_sha()
{
    local metrics
    metrics=$(recovery_metrics_json "$1") || return 1
    printf '%s' "$metrics" | sha256sum | awk '{print $1}'
}

stat_uid()
{
    stat -c '%u' "$1" 2>/dev/null || stat -f '%u' "$1"
}

stat_gid()
{
    stat -c '%g' "$1" 2>/dev/null || stat -f '%g' "$1"
}

stat_mode()
{
    stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

stat_nlink()
{
    stat -c '%h' "$1" 2>/dev/null || stat -f '%l' "$1"
}

input_path_has_no_symlink_component()
{
    local input="$1" part current=''
    local -a parts=()
    [[ "$input" == /* ]] || input="$PWD/$input"
    [[ "$input" != */./* && "$input" != */. &&
       "$input" != */../* && "$input" != */.. ]] || return 1
    IFS='/' read -r -a parts <<<"$input"
    for part in "${parts[@]}"; do
        [[ -n "$part" ]] || continue
        current="${current}/${part}"
        [[ ! -L "$current" ]] || return 1
    done
}

exact_evidence_file_is_safe()
{
    local file="$1" base uid gid mode links
    [[ -f "$file" && ! -L "$file" ]] || return 1
    base=${file##*/}
    [[ "$base" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    uid=$(stat_uid "$file") || return 1
    gid=$(stat_gid "$file") || return 1
    mode=$(stat_mode "$file") || return 1
    links=$(stat_nlink "$file") || return 1
    [[ "$uid" == 0 && "$gid" == 0 && "$mode" == 600 && "$links" == 1 ]]
}

secure_root()
{
    local root="$1" file mode uid current
    [[ "$(id -u)" == 0 ]] || die 'executable evidence verification requires uid 0'
    [[ -d "$root" && ! -L "$root" ]] || die 'evidence root is absent, non-directory, or symlinked'
    uid=$(stat_uid "$root") || die 'cannot read evidence-root owner'
    mode=$(stat_mode "$root") || die 'cannot read evidence-root mode'
    [[ "$uid" == 0 && "$(stat_gid "$root")" == 0 && "$mode" == 700 ]] ||
        die 'evidence root must be root:root mode 0700'
    current="$root"
    while :; do
        [[ -d "$current" && ! -L "$current" ]] || die 'evidence ancestor is not a real directory'
        uid=$(stat_uid "$current") || die 'cannot read evidence-ancestor owner'
        mode=$(stat_mode "$current") || die 'cannot read evidence-ancestor mode'
        [[ "$uid" == 0 ]] || die 'evidence ancestor is not root-owned'
        (( (8#$mode & 8#022) == 0 )) || die 'evidence ancestor is group/other writable'
        [[ "$current" != / ]] || break
        current=${current%/*}
        [[ -n "$current" ]] || current=/
    done
    [[ -z "$(find "$root" -type l -print -quit)" ]] || die 'evidence contains a symlink'
    [[ -z "$(find "$root" -mindepth 1 ! -type f ! -type d ! -type l -print -quit)" ]] ||
        die 'evidence contains a non-regular filesystem object'
    [[ -z "$(find "$root" -mindepth 1 -type d -print -quit)" ]] ||
        die 'evidence contains an unexpected subdirectory'
    while IFS= read -r -d '' file; do
        exact_evidence_file_is_safe "$file" || die "unsafe evidence file metadata: ${file##*/}"
    done < <(find "$root" -mindepth 1 -maxdepth 1 -type f -print0)
}

manifest_names_are_safe()
{
    local manifest="$1"
    awk '
      NF != 2 || $1 !~ /^[0-9a-f]{64}$/ { exit 1 }
      {
        name=$2; sub(/^\*/, "", name); sub(/^\.\//, "", name)
        if (name !~ /^[A-Za-z0-9._-]+$/ || seen[name]++) exit 1
      }
    ' "$manifest"
}

manifest_file_set()
{
    local manifest="$1"
    awk 'NF == 2 && $1 ~ /^[0-9a-f]{64}$/ {
        name=$2; sub(/^\*/, "", name); sub(/^\.\//, "", name); print "./" name
    }' "$manifest" | sort
}

current_file_set_excluding()
{
    local root="$1" path base excluded name
    shift
    while IFS= read -r -d '' path; do
        base=${path##*/}
        excluded=false
        for name in "$@"; do
            if [[ "$base" == "$name" ]]; then
                excluded=true
                break
            fi
        done
        [[ "$excluded" == true ]] || printf './%s\n' "$base"
    done < <(find "$root" -mindepth 1 -maxdepth 1 -type f -print0)
}

verify_manifest_exact_set()
{
    local root="$1" manifest_name="$2"
    shift 2
    require_files "$root" "$manifest_name"
    manifest_names_are_safe "$root/$manifest_name" ||
        die "unsafe or duplicate manifest entry: $manifest_name"
    cmp -s <(current_file_set_excluding "$root" "$manifest_name" "$@" | sort) \
        <(manifest_file_set "$root/$manifest_name") ||
        die "evidence file set differs from exact manifest: $manifest_name"
    (cd "$root" && sha256sum --strict -c "$manifest_name" >/dev/null) ||
        die "evidence checksum verification failed: $manifest_name"
}

require_files()
{
    local root="$1" name
    shift
    for name in "$@"; do
        [[ -f "$root/$name" && ! -L "$root/$name" ]] || die "required evidence absent: $name"
    done
}

require_absent()
{
    local root="$1" name
    shift
    for name in "$@"; do
        [[ ! -e "$root/$name" && ! -L "$root/$name" ]] ||
            die "evidence must be absent in this verification mode: $name"
    done
}

verify_full_seal()
{
    local root="$1"
    verify_manifest_exact_set "$root" SHA256SUMS
}

verify_pre_rewind_seal()
{
    local root="$1"
    require_absent "$root" SHA256SUMS REWIND_SAFE.json RESULT.json \
        POST_REWIND_SHA256SUMS pre-rewind-verifier.json pre-rewind-state.json \
        base-catchup-proof.json snapshot-absence-proof.json \
        base-quarantine-created-stopped.json base-quarantine-invocation.json
    verify_manifest_exact_set "$root" PRE_REWIND_SHA256SUMS
}

verify_post_rewind_seal()
{
    local root="$1"
    verify_manifest_exact_set "$root" POST_REWIND_SHA256SUMS SHA256SUMS RESULT.json
}

verify_pre_result_seal()
{
    local root="$1"
    verify_manifest_exact_set "$root" PRE_RESULT_SHA256SUMS SHA256SUMS RESULT.json
}

verify_candidate_identity()
{
    local root="$1" signature core_ci manifest oci loaded binaries index manifest_json config rollback
    local manifest_digest config_digest
    require_files "$root" candidate-source-signature.json candidate-core-ci.json \
        candidate-bundle-manifest.json candidate-oci-identity.json candidate-loaded-image.json \
        candidate-loaded-binary-sha256.tsv candidate-source-commit.txt \
        candidate-bundle-sha256sums.txt candidate-binary-sha256sums.txt \
        candidate-provenance.intoto.json candidate-oci-index.json candidate-oci-manifest.json \
        candidate-oci-config.json rollback-loaded-image.json
    signature="$root/candidate-source-signature.json"
    core_ci="$root/candidate-core-ci.json"
    manifest="$root/candidate-bundle-manifest.json"
    oci="$root/candidate-oci-identity.json"
    loaded="$root/candidate-loaded-image.json"
    binaries="$root/candidate-loaded-binary-sha256.tsv"
    index="$root/candidate-oci-index.json"
    manifest_json="$root/candidate-oci-manifest.json"
    config="$root/candidate-oci-config.json"
    rollback="$root/rollback-loaded-image.json"
    jq -e --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" --arg fp "$HOTFIX_SIGNING_FINGERPRINT" '
        .schema == 1 and .commit == $source and .repository == "Blackcoin-Dev/Blackcoin" and
        .signer == "Blackcoin-Dev" and .format == "ssh" and .fingerprint == $fp and
        .local_git_verified == true and .github_verified == true and
        .github_verification_reason == "valid" and
        .workflow_actor == "Blackcoin-Dev" and
        .workflow_triggering_actor == "Blackcoin-Dev"
    ' "$signature" >/dev/null || die 'candidate signature identity failed'
    jq -e --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" '
        .schema == 1 and .workflow_path == ".github/workflows/pr-gate.yml" and
        .workflow_name == "pull-request safety gate" and
        .event == "pull_request" and .repository == "Blackcoin-Dev/Blackcoin" and
        .head_repository == "Blackcoin-Dev/Blackcoin" and .pull_request_number == 49 and
        .pull_request_head_sha == $source and .head_sha == $source and
        (.pull_request_base_sha | type == "string" and test("^[0-9a-f]{40}$")) and
        (.workflow_blob_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
        .status == "completed" and .conclusion == "success" and
        (.run_id | type == "number" and floor == . and . > 0)
    ' "$core_ci" >/dev/null || die 'Core CI identity failed'
    jq -e --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" \
        --arg classification "$HOTFIX_CANDIDATE_CLASSIFICATION" \
        --arg prefix "$HOTFIX_CANDIDATE_PREFIX" \
        --arg release "$HOTFIX_CANDIDATE_RELEASE_VERSION" \
        --arg workflow_path "$HOTFIX_CANDIDATE_WORKFLOW_PATH" \
        --argjson core_run "$(jq -er '.run_id' "$core_ci")" '
        .schema == 1 and .classification == $classification and
        .package == {name:$prefix,version:$release,platform:"linux/amd64"} and
        .source.commit == $source and .source.signature.commit == $source and
        .core_ci.head_sha == $source and .core_ci.run_id == $core_run and
        .core_ci.conclusion == "success" and
        .authorization == {state:"authorized_exact_signed_source_and_green_ci",
          dispatch_enabled:true,temporary_source_pin:false,core_ci_run_id:$core_run} and
        .build.workflow_path == $workflow_path and
        .build.workflow_definition_commit == .build.tooling_commit and
        (.build.workflow_run_id | type == "number" and floor == . and . > 0) and
        (.build.workflow_run_attempt | type == "number" and floor == . and . > 0) and
        .release.tag == null and .release.published == false and
        .release.registry_pushed == false and .release.canary_only == true
    ' "$manifest" >/dev/null || die 'candidate manifest identity failed'
    [[ "$(<"$root/candidate-source-commit.txt")" == "$HOTFIX_CANDIDATE_SOURCE_SHA" ]] ||
        die 'source marker differs from candidate source'
    cmp -s <(jq -S '.source.signature' "$manifest") <(jq -S . "$signature") ||
        die 'manifest signature block differs'
    cmp -s <(jq -S '.core_ci' "$manifest") <(jq -S . "$core_ci") ||
        die 'manifest Core-CI block differs'
    cmp -s <(jq -S '.image' "$manifest") <(jq -S . "$oci") ||
        die 'manifest OCI block differs'
    jq -e --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" \
        --arg classification "$HOTFIX_CANDIDATE_CLASSIFICATION" \
        --arg image_ref "$HOTFIX_CANDIDATE_IMAGE_REF" \
        --arg archive "$HOTFIX_CANDIDATE_OCI_ARCHIVE_NAME" \
        --arg base_ref "$IMMUTABLE_V3014_IMAGE_REF" \
        --arg base_digest "$IMMUTABLE_V3014_IMAGE_DIGEST" \
        --arg base_id "$IMMUTABLE_V3014_IMAGE_ID" '
        .schema == 1 and .classification == $classification and
        .source_commit == $source and .image_reference == $image_ref and
        .archive_name == $archive and .base_reference == $base_ref and
        .base_manifest_digest == $base_digest and
        .base_config_digest == $base_id and .os == "linux" and .architecture == "amd64" and
        .user == "blackcoin" and .entrypoint == ["/home/blackcoin/start-gui.sh"] and
        .cmd == null and .working_dir == "/home/blackcoin" and .healthcheck == null and
        .rootfs_base_prefix_exact == true and .candidate_added_rootfs_layers == 1 and
        .oci_roundtrip_verified == true and .published == false and .registry_pushed == false
    ' "$oci" >/dev/null || die 'OCI identity failed'
    manifest_digest=$(jq -er '.manifests[0].digest' "$index") ||
        die 'OCI index manifest digest absent'
    config_digest=$(jq -er '.config.digest' "$manifest_json") ||
        die 'OCI manifest config digest absent'
    [[ "$manifest_digest" == "sha256:$(sha_of "$manifest_json")" &&
       "$config_digest" == "sha256:$(sha_of "$config")" &&
       "$manifest_digest" == "$(jq -er '.image_manifest_digest' "$oci")" &&
       "$config_digest" == "$(jq -er '.image_config_digest' "$oci")" ]] ||
        die 'OCI index/manifest/config graph is not digest-bound'
    jq -e --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" --arg id "$config_digest" \
        --arg image_ref "$HOTFIX_CANDIDATE_IMAGE_REF" \
        --arg release "$HOTFIX_CANDIDATE_RELEASE_VERSION" \
        --arg version "$HOTFIX_CANDIDATE_IMAGE_VERSION" \
        --arg base_ref "$IMMUTABLE_V3014_IMAGE_REF" \
        --arg base_id "$IMMUTABLE_V3014_IMAGE_ID" '
        length == 1 and .[0].Id == $id and .[0].Os == "linux" and
        .[0].Architecture == "amd64" and
        .[0].RepoTags == [$image_ref] and
        .[0].Config.User == "blackcoin" and .[0].Config.WorkingDir == "/home/blackcoin" and
        .[0].Config.Entrypoint == ["/home/blackcoin/start-gui.sh"] and
        .[0].Config.Cmd == null and .[0].Config.Healthcheck == null and
        .[0].Config.Labels["org.blackcoin.source.commit"] == $source and
        .[0].Config.Labels["org.blackcoin.release.channel"] ==
          ("v" + $release + "-candidate") and
        .[0].Config.Labels["org.blackcoin.release.qualification"] == "canary-only-not-release" and
        .[0].Config.Labels["org.blackcoin.candidate.kind"] ==
          ("v" + $release + "-candidate") and
        .[0].Config.Labels["org.blackcoin.candidate.registry-pushed"] == "false" and
        .[0].Config.Labels["org.blackcoin.candidate.published"] == "false" and
        .[0].Config.Labels["org.blackcoin.release.tag"] == "none" and
        .[0].Config.Labels["org.opencontainers.image.version"] == $version and
        .[0].Config.Labels["org.blackcoin.rollback.base.image"] == $base_ref and
        .[0].Config.Labels["org.blackcoin.rollback.base.image.id"] == $base_id
    ' "$loaded" >/dev/null || die 'loaded candidate image identity failed'
    jq -e --arg id "$IMMUTABLE_V3014_IMAGE_ID" --arg source "$IMMUTABLE_V3014_SOURCE_SHA" '
        length == 1 and .[0].Id == $id and .[0].Os == "linux" and
        .[0].Architecture == "amd64" and .[0].Config.User == "blackcoin" and
        .[0].Config.WorkingDir == "/home/blackcoin" and
        .[0].Config.Entrypoint == ["/home/blackcoin/start-gui.sh"] and
        .[0].Config.Cmd == null and
        .[0].Config.Labels["org.blackcoin.source.commit"] == $source
    ' "$rollback" >/dev/null || die 'immutable rollback image identity failed'
    [[ "$(wc -l <"$binaries" | tr -d ' ')" == 6 ]] || die 'candidate binary count is not six'
    cmp -s <(cut -f1 "$binaries" | sort) <(
        printf '%s\n' blackcoin-cli blackcoin-qt blackcoin-tx blackcoin-util blackcoin-wallet blackcoind | sort
    ) || die 'candidate binary name set differs'
    cmp -s <(sort "$binaries") <(
        awk '{print $2 "\t" $1}' "$root/candidate-binary-sha256sums.txt" | sort
    ) || die 'loaded candidate binaries differ from sealed package hashes'
    jq -e --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" '
        .architecture == "amd64" and .os == "linux" and .config.User == "blackcoin" and
        .config.Entrypoint == ["/home/blackcoin/start-gui.sh"] and .config.Cmd == null and
        .config.WorkingDir == "/home/blackcoin" and
        .config.Labels["org.blackcoin.source.commit"] == $source and
        .rootfs.type == "layers" and (.rootfs.diff_ids | length) > 0
    ' "$config" >/dev/null || die 'OCI config failed'
    jq -e '.schemaVersion == 2 and (.manifests | length) == 1' \
        "$index" >/dev/null || die 'OCI index failed'
    jq -e '.schemaVersion == 2 and (.layers | length) > 0 and
      (.config.digest | test("^sha256:[0-9a-f]{64}$"))' \
      "$manifest_json" >/dev/null || die 'OCI manifest failed'
}

verify_phase_a_tooling_identity()
{
    local root="$1" identity
    local package phase_a phase_b verifier contract tooling
    identity="$root/tooling-identity.json"
    require_files "$root" tooling-identity.json
    package=$(sha_of "$PACKAGE_ROOT/SHA256SUMS")
    phase_a=$(sha_of \
        "$PACKAGE_ROOT/node27-v30.1.4-hotfix-candidate.no-recovery-spend.sh")
    phase_b=$(sha_of \
        "$PACKAGE_ROOT/node27-v30.1.4-hotfix-candidate.promote-no-data-rewind.sh")
    verifier=$(sha_of "$PACKAGE_ROOT/verify-evidence.sh")
    contract=$(sha_of "$PACKAGE_ROOT/lib/typed_contract.sh")
    tooling=$(jq -er '
      .build.tooling_commit as $tooling |
      select(($tooling | type) == "string" and
             ($tooling | test("^[0-9a-f]{40}$")) and
             .build.workflow_definition_commit == $tooling) |
      $tooling
    ' "$root/candidate-bundle-manifest.json") ||
        die 'sealed candidate manifest lacks one exact tooling/workflow commit'
    hotfix_phase_a_tooling_identity_file_is_valid "$identity" "$tooling" "$package" \
        "$phase_a" "$phase_b" "$verifier" "$contract" ||
        die 'Phase-A package/tooling identity does not match the verifying package'
}

verify_rpc_journal_phase_a()
{
    local file="$1" forbidden
    forbidden=$(grep -E '^(createshadowpowclaimresolution|commitshadowpowclaimresolution|resolveshadowpowclaims|setpowclaimrecovery|sendrawtransaction|sendtoaddress|sendmany|fundrawtransaction|signrawtransaction.*|resendwallettransactions|forcerelay|abandontransaction|getnewaddress|getnewquantumaddress|setpowminingaddress|generate|generatetoaddress|submitblock|submitheader|staking:true)(:.*)?$' \
        "$file" | sort -u || true)
    [[ -z "$forbidden" ]] || die "forbidden Phase-A RPC: $forbidden"
    grep -Fx 'setpowmining:true:1:1:false' "$file" >/dev/null ||
        die 'Phase A never explicitly enabled exact one-core/one-percent PoW'
    grep -Fx 'setpowmining:false:1:1:false' "$file" >/dev/null ||
        die 'Phase A lacks synchronous PoW stop evidence'
}

verify_nonpublication_raw_bindings()
{
    local root="$1" prefix="$2" file
    file="$root/$prefix.json"
    require_files "$root" "$prefix.json" "$prefix.listeners.txt" \
        "$prefix.iptables.txt" "$prefix.ip6tables.txt" "$prefix.nft.txt" \
        "$prefix.port-bindings.json" "$prefix.vpn-mounts.json" \
        "$prefix.rpc-auth-boundary.json" "$prefix.probe-targets.json"
    [[ "$(jq -er '.listener_evidence_sha256' "$file")" == \
         "$(sha_of "$root/$prefix.listeners.txt")" &&
       "$(jq -er '.ipv4_firewall_evidence_sha256' "$file")" == \
         "$(sha_of "$root/$prefix.iptables.txt")" &&
       "$(jq -er '.ipv6_firewall_evidence_sha256' "$file")" == \
         "$(sha_of "$root/$prefix.ip6tables.txt")" &&
       "$(jq -er '.nft_evidence_sha256' "$file")" == \
         "$(sha_of "$root/$prefix.nft.txt")" &&
       "$(jq -er '.port_binding_evidence_sha256' "$file")" == \
         "$(sha_of "$root/$prefix.port-bindings.json")" &&
       "$(jq -er '.vpn_mount_evidence_sha256' "$file")" == \
         "$(sha_of "$root/$prefix.vpn-mounts.json")" &&
       "$(jq -er '.rpc_auth_boundary_evidence_sha256' "$file")" == \
         "$(sha_of "$root/$prefix.rpc-auth-boundary.json")" &&
       "$(jq -er '.probe_target_evidence_sha256' "$file")" == \
         "$(sha_of "$root/$prefix.probe-targets.json")" ]] ||
        die "nonpublication receipt does not bind raw surface capture: $prefix"
    jq -e '
      .node27=={} and
      (.vpn_container|to_entries|all(.[];
        ((.key|startswith("8080/")) or (.key|startswith("5900/")) or
         (.key|startswith("15715/")))|not))
    ' "$root/$prefix.port-bindings.json" >/dev/null ||
        die "nonpublication raw port bindings expose an RPC/GUI/VNC port: $prefix"
    jq -e '
      all(.[]; .Destination!="/home/blackcoin/.blackcoin" and
        .Destination!="/root/.blackcoin" and
        .Destination!="/home/blackcoin/.blackcoin")
    ' "$root/$prefix.vpn-mounts.json" >/dev/null ||
        die "shared namespace has wallet RPC authentication material mounted: $prefix"
    jq -e '
      (keys|sort)==(["candidate_processes","candidate_rpc_capable_processes",
        "cookie_or_conf_paths_present","rpc_auth_material_unavailable_to_shared_namespace",
        "separate_pid_namespace","shared_rpc_unauthenticated_rejected",
        "vpn_namespace"]|sort) and
      .cookie_or_conf_paths_present==[] and .separate_pid_namespace==true and
      .shared_rpc_unauthenticated_rejected==true and
      .rpc_auth_material_unavailable_to_shared_namespace==true and
      .candidate_rpc_capable_processes==["blackcoin-qt"] and
      (.candidate_processes|type)=="array" and
      (.candidate_processes|index("blackcoin-qt"))!=null and
      all(.candidate_processes[]; IN("Xvfb","blackcoin-qt","fluxbox","ps")) and
      .vpn_namespace.privileged==false and .vpn_namespace.pid_mode=="" and
      .vpn_namespace.dangerous_caps==[] and
      .vpn_namespace.auth_environment_names==[] and
      .vpn_namespace.sensitive_mounts==[]
    ' "$root/$prefix.rpc-auth-boundary.json" >/dev/null ||
        die "shared namespace has an RPC client, auth material, or automation path: $prefix"
    jq -e '
      (keys|sort)==(["all_host_and_vpn_targets_observed_inaccessible","host_addresses",
        "loopback_addresses","ports","shared_namespace_gui_vnc_ports_observed_inaccessible",
        "shared_namespace_rpc_tcp_reachable",
        "shared_namespace_rpc_unauthenticated_rejected","vpn_addresses"]|sort) and
      .loopback_addresses==["127.0.0.1","::1"] and .ports==[8080,5900,15715] and
      (.host_addresses|type)=="array" and (.host_addresses|length)>0 and
      (.host_addresses|unique|length)==(.host_addresses|length) and
      all(.host_addresses[]; type=="string" and length>0 and
        .!="127.0.0.1" and .!="::1") and
      (.vpn_addresses|type)=="array" and (.vpn_addresses|length)>0 and
      (.vpn_addresses|unique|length)==(.vpn_addresses|length) and
      all(.vpn_addresses[]; type=="string" and length>0 and
        .!="127.0.0.1" and .!="::1") and
      .all_host_and_vpn_targets_observed_inaccessible==true and
      .shared_namespace_rpc_tcp_reachable==true and
      .shared_namespace_rpc_unauthenticated_rejected==true and
      .shared_namespace_gui_vnc_ports_observed_inaccessible==true
    ' "$root/$prefix.probe-targets.json" >/dev/null ||
        die "host/VPN/shared-namespace probe target proof failed: $prefix"
    ! grep -Eq '(^|[[:space:]])[^[:space:]]*:(8080|5900)([[:space:]]|$)' \
        "$root/$prefix.listeners.txt" ||
        die "interactive listener survived Phase-A isolation: $prefix"
    awk '
      $4 ~ /:15715$/ {
        found=1
        if ($4 !~ /^(127[.]0[.]0[.]1|\[::1\]|::1):15715$/) bad=1
      }
      END { exit !(found && !bad) }
    ' "$root/$prefix.listeners.txt" ||
        die "RPC listener is absent or not loopback-bound: $prefix"
    if ! grep -Eq '^:INPUT DROP \[[0-9]+:[0-9]+\]$' "$root/$prefix.iptables.txt" ||
       ! grep -Eq '^:INPUT DROP \[[0-9]+:[0-9]+\]$' "$root/$prefix.ip6tables.txt"; then
        die "shared namespace firewall is not default-deny: $prefix"
    fi
    if grep -Eq -- '--dport (8080|5900|15715).* -j ACCEPT' \
         "$root/$prefix.iptables.txt" ||
       grep -Eq -- '--dport (8080|5900|15715).* -j ACCEPT' \
         "$root/$prefix.ip6tables.txt"; then
        die "shared namespace firewall publishes an isolated service: $prefix"
    fi
    jq -e '
      .rpc_shared_namespace_port_bindings==["127.0.0.1:15715/tcp"] and
      .rpc_external_probe=="host-and-vpn-inaccessible-shared-netns-authenticated-only" and
      ([.probe_results[]|select(.path=="shared-namespace")]|length)==1 and
      ([.probe_results[]|select(.path=="shared-namespace")][0] |
        .reachable==true and .status=="authenticated-only" and
        .tcp_rpc_reachable==true and .unauthenticated_rpc_rejected==true and
        .gui_vnc_ports_closed==true and .cookie_mount_absent==true) and
      .keeper_api_suspended==true and .guard_start_suspended==true and
      .includeconf_rejected==true and .interactive_services_stopped==true and
      .guard_authority_observed==true and .walletnotify==null and
      .zmq_transaction_endpoints==[] and .relay_forcerelay_peer_ids==[] and
      .all_peer_relaytxes_false==true and .network_localrelay==false and
      .blocksonly==true and .unknown_surfaces==[]
    ' "$file" >/dev/null ||
        die "shared-netns authentication/nonautomation/nonpublication proof failed: $prefix"
}

verify_phase_a_invocation_surface_bindings()
{
    local root="$1" nonce="$2" candidate_id="$3" sample isolation expected
    require_files "$root" candidate-created-stopped.json candidate-invocation-initial.json \
        candidate-invocation-restart.json phase-a-nonpublication-initial.json \
        phase-a-nonpublication-restart-preunlock.json phase-a-nonpublication-final.json \
        phase-a-progress.json
    jq -e -n --slurpfile created "$root/candidate-created-stopped.json" \
        --slurpfile initial "$root/candidate-invocation-initial.json" \
        --slurpfile restart "$root/candidate-invocation-restart.json" '
      ($initial[0]) as $a | ($restart[0]) as $b |
      $created[0].image_id==$a.image_id and $created[0].image_id==$b.image_id and
      $created[0].mounts_sha256==$a.mounts_sha256 and $created[0].mounts_sha256==$b.mounts_sha256 and
      $created[0].network_sha256==$a.network_sha256 and
      $created[0].network_sha256==$b.network_sha256 and
      $created[0].restart_policy=={Name:"no",MaximumRetryCount:0} and
      ($a|del(.runtime_argv_sha256))==($b|del(.runtime_argv_sha256)) and
      $a.runtime_argv_sha256==$b.runtime_argv_sha256
    ' >/dev/null || die 'Phase-A initial/restart invocation identity differs'
    for isolation in phase-a-nonpublication-initial \
        phase-a-nonpublication-restart-preunlock phase-a-nonpublication-final; do
        hotfix_nonpublication_file_is_valid "$root/$isolation.json" "$nonce" ||
            die "Phase-A nonpublication contract failed: $isolation"
        verify_nonpublication_raw_bindings "$root" "$isolation"
    done
    for sample in 1 2 3 4; do
        isolation="candidate-isolation-sample-${sample}"
        hotfix_nonpublication_file_is_valid "$root/$isolation.json" "$nonce" ||
            die "Phase-A progress nonpublication contract failed: $isolation"
        verify_nonpublication_raw_bindings "$root" "$isolation"
        expected=$(jq -er --argjson index "$((sample - 1))" \
            '.isolation_sample_sha256s[$index]' "$root/phase-a-progress.json") ||
            die 'progress isolation hash absent'
        [[ "$expected" == "$(sha_of "$root/$isolation.json")" ]] ||
            die "progress isolation hash differs: $isolation"
    done
    jq -e --arg nonce "$nonce" --arg id "$candidate_id" '
      .run_nonce==$nonce and .phase=="A" and .image_id==$id and
      .effective_cmd==["-walletbroadcast=0","-blocksonly=1","-staking=0",
        "-autostartstaking=0","-powmining=0","-qqautoshadowsignal=0",
        "-qqautodemurrageattest=0"]
    ' "$root/candidate-invocation-restart.json" >/dev/null ||
        die 'Phase-A exact hard-flag invocation failed'
}

verify_phase_a_stop_authority_bindings()
{
    local root="$1" candidate_id="$2" candidate_ref baseline_stop candidate_stop
    require_files "$root" baseline-cold-stop-authority.json candidate-stop-authority.json \
        snapshot-set.json baseline-runtime-identity.json candidate-created-stopped.json
    candidate_ref=$(jq -er '.image_reference' "$root/candidate-oci-identity.json") ||
        die 'candidate image reference absent from sealed OCI identity'
    baseline_stop="$root/baseline-cold-stop-authority.json"
    candidate_stop="$root/candidate-stop-authority.json"
    hotfix_phase_a_stable_stop_file_is_valid "$baseline_stop" baseline-pre-snapshot \
        "$IMMUTABLE_V3014_IMAGE_ID" "$IMMUTABLE_V3014_IMAGE_REF" ||
        die 'pre-snapshot baseline stable-stop authority failed'
    hotfix_phase_a_stable_stop_file_is_valid "$candidate_stop" candidate-terminal \
        "$candidate_id" "$candidate_ref" ||
        die 'terminal candidate stable-stop authority failed'
    jq -e -n --slurpfile runtime "$root/baseline-runtime-identity.json" \
        --slurpfile stop "$baseline_stop" '
      ($runtime[0]|keys|sort)==(["blackcoin_conf_sha256","mounts_sha256",
        "network_sha256","restart_policy","schema"]|sort) and
      $runtime[0].schema==1 and $runtime[0].restart_policy==$stop[0].original_restart_policy
    ' >/dev/null || die 'baseline stable-stop authority differs from captured runtime policy'
    [[ "$(jq -er '.baseline_stop_authority_sha256' "$root/snapshot-set.json")" == \
       "$(sha_of "$baseline_stop")" ]] ||
        die 'snapshot set is not bound to the baseline stable-stop authority'
    jq -e '.restart_policy=={Name:"no",MaximumRetryCount:0}' \
        "$root/candidate-created-stopped.json" >/dev/null ||
        die 'Phase-A candidate was not created with automatic restart disabled'
}

verify_phase_a_claim_raw_bindings()
{
    local root="$1" sample baseline_metrics_json baseline_metrics_sha
    require_files "$root" prelaunch-wallet-transactions.json \
        candidate-final-wallet-transactions.json candidate-final-mempool.json \
        candidate-final-recovery-inventory.json observer-tx-absence.jsonl \
        observer-mempools.jsonl observer-final-chain.jsonl observer-anchor-unspent.jsonl \
        observer-terminal-proof.json tx-visibility-samples.jsonl \
        candidate-visibility-sample-1.json candidate-visibility-sample-2.json \
        candidate-visibility-sample-3.json candidate-visibility-sample-4.json \
        candidate-claims-sample-1.json candidate-claims-sample-2.json \
        candidate-claims-sample-3.json candidate-claims-sample-4.json \
        candidate-created-qqsproof-txids.json prelaunch-wallet-outpoints.json \
        candidate-final-wallet-outpoints.json prelaunch-resolution-txids.json \
        candidate-final-resolution-txids.json prelaunch-component-resolution-txids.json \
        candidate-final-component-resolution-txids.json baseline-pow.json \
        candidate-final-pow.json baseline-quantum-inventory.json \
        candidate-final-quantum-inventory.json baseline-recovery.json \
        candidate-final-staking.json candidate-final-chain.json phase-a-progress.json \
        candidate-final-chain-after.json candidate-final-pow-after.json \
        candidate-final-staking-after.json candidate-final-recovery-after.json \
        candidate-final-stable-cut.json candidate-stopped.json candidate-complete.log \
        candidate-post-stop-log-receipt.json
    baseline_metrics_json=$(recovery_metrics_json "$root/baseline-recovery.json") ||
        die 'baseline recovery metrics are malformed'
    baseline_metrics_sha=$(recovery_metrics_sha "$root/baseline-recovery.json") ||
        die 'baseline recovery metrics hash failed'
    [[ "$(recovery_metrics_sha "$root/candidate-final-recovery-inventory.json")" == \
         "$baseline_metrics_sha" &&
       "$(recovery_metrics_sha "$root/candidate-final-recovery-after.json")" == \
         "$baseline_metrics_sha" ]] ||
        die 'Phase-A final recovery metrics differ from baseline'
    jq -e --arg metrics_sha "$baseline_metrics_sha" \
        --argjson metrics "$baseline_metrics_json" '
      def recovery_metrics: {pending_manual_resolutions,pending_automatic_resolutions,
        confirmed_manual_resolutions,confirmed_automatic_resolutions,
        confirmed_resolution_fees,automatic_actions_in_window,
        automatic_fee_exposure_in_window,reconciled_descendant_claims,claims_recycled};
      all(.envelopes[];
        .expected_recovery_metrics_sha256==$metrics_sha and
        .expected_recovery_metrics==$metrics and
        (.recovery_before|recovery_metrics)==$metrics and
        (.recovery_after|recovery_metrics)==$metrics)
    ' "$root/phase-a-progress.json" >/dev/null ||
        die 'Phase-A progress recovery metrics are not baseline-bound'
    for sample in 1 2 3 4; do
        jq -e --argjson metrics "$baseline_metrics_json" '
          def recovery_metrics: {pending_manual_resolutions,pending_automatic_resolutions,
            confirmed_manual_resolutions,confirmed_automatic_resolutions,
            confirmed_resolution_fees,automatic_actions_in_window,
            automatic_fee_exposure_in_window,reconciled_descendant_claims,claims_recycled};
          (.post_claim_recovery|recovery_metrics)==$metrics
        ' "$root/candidate-visibility-sample-${sample}.json" >/dev/null ||
            die "Phase-A post-claim recovery metrics changed in sample $sample"
    done
    jq -e --arg metrics "$baseline_metrics_sha" '
      .recovery_metrics_sha256_before==$metrics and
      .recovery_metrics_sha256_after==$metrics and .recovery_metrics_unchanged==true
    ' "$root/phase-a-claim-proof.json" >/dev/null ||
        die 'Phase-A claim proof does not bind the full recovery metric set'
    jq -e -n --slurpfile proof "$root/phase-a-claim-proof.json" \
        --slurpfile before "$root/prelaunch-wallet-transactions.json" \
        --slurpfile after "$root/candidate-final-wallet-transactions.json" \
        --slurpfile mempool "$root/candidate-final-mempool.json" \
        --slurpfile recovery "$root/candidate-final-recovery-inventory.json" \
        --slurpfile recovery_after "$root/candidate-final-recovery-after.json" \
        --slurpfile absence "$root/observer-tx-absence.jsonl" \
        --slurpfile observers "$root/observer-mempools.jsonl" \
        --slurpfile observer_chains "$root/observer-final-chain.jsonl" \
        --slurpfile observer_anchors "$root/observer-anchor-unspent.jsonl" \
        --slurpfile observer_terminal "$root/observer-terminal-proof.json" \
        --slurpfile visibility "$root/tx-visibility-samples.jsonl" \
        --slurpfile v1 "$root/candidate-visibility-sample-1.json" \
        --slurpfile v2 "$root/candidate-visibility-sample-2.json" \
        --slurpfile v3 "$root/candidate-visibility-sample-3.json" \
        --slurpfile v4 "$root/candidate-visibility-sample-4.json" \
        --slurpfile s1 "$root/candidate-claims-sample-1.json" \
        --slurpfile s2 "$root/candidate-claims-sample-2.json" \
        --slurpfile s3 "$root/candidate-claims-sample-3.json" \
        --slurpfile s4 "$root/candidate-claims-sample-4.json" \
        --slurpfile txids_file "$root/candidate-created-qqsproof-txids.json" \
        --slurpfile outpoints_before "$root/prelaunch-wallet-outpoints.json" \
        --slurpfile outpoints_after "$root/candidate-final-wallet-outpoints.json" \
        --slurpfile resolution_before "$root/prelaunch-resolution-txids.json" \
        --slurpfile resolution_after "$root/candidate-final-resolution-txids.json" \
        --slurpfile component_before "$root/prelaunch-component-resolution-txids.json" \
        --slurpfile component_after "$root/candidate-final-component-resolution-txids.json" \
        --slurpfile pow_before "$root/baseline-pow.json" \
        --slurpfile pow_after "$root/candidate-final-pow.json" \
        --slurpfile quantum_before "$root/baseline-quantum-inventory.json" \
        --slurpfile quantum_after "$root/candidate-final-quantum-inventory.json" \
        --slurpfile recovery_before "$root/baseline-recovery.json" \
        --slurpfile staking_after "$root/candidate-final-staking.json" \
        --slurpfile staking_after2 "$root/candidate-final-staking-after.json" \
        --slurpfile pow_after2 "$root/candidate-final-pow-after.json" \
        --slurpfile final_chain "$root/candidate-final-chain.json" \
        --slurpfile final_chain2 "$root/candidate-final-chain-after.json" \
        --slurpfile stable_cut "$root/candidate-final-stable-cut.json" \
        --slurpfile progress "$root/phase-a-progress.json" '
        def qq: (.comment == "PoW Claim" or has("qq_shadow_pow_lineage_schema") or
          has("qq_shadow_pow_lineage_root"));
        def outpoint_key: [.txid,.vout] | @json;
        def static_wallet_record:
          del(.confirmations,.blockhash,.blockheight,.blockindex,.blocktime,
            .trusted,.walletconflicts);
        def inventory_count:
          if type == "array" then length
          elif (.keys? | type) == "array" then (.keys | length)
          elif (.inventory? | type) == "array" then (.inventory | length)
          elif (.total? | type) == "number" then .total
          else error("unsupported quantum inventory") end;
        ($proof[0]) as $p |
        ($before[0] | map(.txid) | unique) as $old |
        ($before[0] | map(static_wallet_record) |
          sort_by([.txid,(.vout // -1),(.category // ""),(.address // ""),
            (.amount // 0),(.fee // 0)])) as $old_static |
        ($after[0] | map(. as $row | select($old | index($row.txid)) | static_wallet_record) |
          sort_by([.txid,(.vout // -1),(.category // ""),(.address // ""),
            (.amount // 0),(.fee // 0)])) as $existing_after_static |
        ($after[0] | map(. as $row | select(($old | index($row.txid)) == null))) as $new |
        ($new | map(select(qq)) | unique_by(.txid) |
          sort_by(.qq_shadow_pow_lineage_ordinal|tonumber) | map(.txid)) as $actual |
        ([$s1[0],$s2[0],$s3[0],$s4[0]]) as $samples |
        ([$v1[0],$v2[0],$v3[0],$v4[0]]) as $visibility_files |
        ($progress[0].envelopes | map(.chain_before.bestblockhash)) as $progress_tips |
        ($samples | map(.tip)) as $sample_tips |
        ($samples | map([.claims[] as $claim | select(($old | index($claim.txid)) == null) |
          $claim.txid] | unique | sort)) as $sample_sets |
        ($outpoints_before[0] | map(outpoint_key) | unique) as $before_outpoints |
        ($outpoints_after[0] | map(outpoint_key) | unique) as $after_outpoints |
        ([$before_outpoints[] as $key |
          select(($after_outpoints | index($key)) == null) | $key]) as $removed_outpoints |
        ([$after_outpoints[] as $key |
          select(($before_outpoints | index($key)) == null) | $key]) as $added_outpoints |
        $actual == $p.candidate_created_qqsproof_txids and
        $actual == $txids_file[0] and
        ($new | map(.txid) | unique | sort) == ($actual | sort) and
        $old_static == $existing_after_static and
        $p.baseline_wallet_records_static_equal == true and
        $p.baseline_wallet_record_mutations == [] and
        $sample_tips == $progress_tips and $p.progress_tips == $progress_tips and
        $p.claim_sample_tips == $sample_tips and
        $p.claim_samples_monotonic == true and
        ([range(1;$sample_sets|length) as $i |
          (($sample_sets[$i-1] - $sample_sets[$i])|length)==0] | all) and
        ([range(0;$progress_tips|length) as $i |
          ([$new[] | select(.qq_shadow_pow_created_tip==$progress_tips[$i]) | .txid]) as $created |
          ($created|length)==1 and (($sample_sets[$i]|index($created[0]))!=null)] | all) and
        $sample_sets[-1] == ($actual|sort) and
        ($actual|length)==($progress_tips|length) and
        $p.progress_tips_bound_to_lineage==true and
        $p.one_lineage_member_per_progress_tip==true and
        $p.final_claim_sample_complete==true and
        $p.visibility_samples_bound_to_progress==true and
        ([$observers[].observer] | sort) ==
          (["blackcoin-v4-gui-26","blackcoin-v4-gui-28"] | sort) and
        ([$observers[].observer] | unique | length) == 2 and
        $visibility == $visibility_files and ($visibility|length)==4 and
        ([range(0;4) as $i |
          $visibility[$i].sample==($i+1) and
          $visibility[$i].candidate_tip==$progress_tips[$i] and
          $visibility[$i].candidate_chainwork==$progress[0].envelopes[$i].chain_before.chainwork and
          $visibility[$i].stable_cut_completed==true and
          $visibility[$i].post_claim_chain.bestblockhash==$visibility[$i].candidate_tip and
          $visibility[$i].post_claim_chain.chainwork==$visibility[$i].candidate_chainwork and
          $visibility[$i].post_claim_mining.claim_inventory_tip==$visibility[$i].candidate_tip and
          $visibility[$i].post_claim_mining.claims_submitted==0 and
          $visibility[$i].post_claim_recovery.active_tip==$visibility[$i].candidate_tip and
          $visibility[$i].observer_chains_stable_and_cover_candidate_tip==true and
          ([ $visibility[$i].observers[].observer ]|sort)==
            (["blackcoin-v4-gui-26","blackcoin-v4-gui-28"]|sort) and
          all($visibility[$i].observers[];
            .stable==true and .chain_before.bestblockhash==.chain_after.bestblockhash and
            .chain_before.chainwork==.chain_after.chainwork and
            .chain_before.blocks==.chain_after.blocks and
            (.terminal_relation=="same_terminal_tip" or
             .terminal_relation=="terminal_superseded_by_greater_work") and
            (if .terminal_relation=="same_terminal_tip" then
               .chain_before.bestblockhash==$visibility[$i].candidate_tip and
               .chain_before.chainwork==$visibility[$i].candidate_chainwork
             else .chain_before.chainwork>$visibility[$i].candidate_chainwork end))] | all) and
        all($visibility[];
          .stable_cut_completed==true and
          .post_claim_chain.bestblockhash==.candidate_tip and
          .post_claim_mining.claim_inventory_tip==.candidate_tip and
          .post_claim_mining.claims_submitted==0 and
          .post_claim_recovery.active_tip==.candidate_tip and
          ([.observers[].observer] | sort) ==
            (["blackcoin-v4-gui-26","blackcoin-v4-gui-28"] | sort) and
          ([.observers[].observer] | unique | length) == 2) and
        all($actual[]; . as $id |
          ($mempool[0] | index($id)) == null and
          ([$absence[] | select(.txid == $id and .status == "observed_absent" and
             .mempool_absent == true and .active_chain_absent == true and
             .active_chain_absence_basis == "authenticated-anchor-unspent" and
             .anchor.unspent == true and .rpc_error_code == -5) | .observer] |
             unique | sort) ==
            (["blackcoin-v4-gui-26","blackcoin-v4-gui-28"]|sort) and
          all($observers[]; (.txids | index($id)) == null) and
          all($visibility[]; (.local_mempool | index($id)) == null and
            all(.observers[]; (.txids | index($id)) == null)) and
          ([$samples[] | .claims[] | select(.txid == $id)] | first) as $first |
          $first.qq_shadow_pow_quarantine == "1" and
          ($first | has("qq_shadow_pow_first_quarantine_height") | not) and
          ($first | has("qq_shadow_pow_branch_quarantine_height") | not)) and
        ([$recovery[0].component_details[]? | . as $component |
          select([$actual[] as $id | (($component.claim_txids // []) | index($id)) != null] |
            all)]) as $components |
        ($components[0] // {}) as $component |
        ([$actual[] as $id | $component.nodes[]? | select(.txid == $id)]) as
          $candidate_nodes |
        ([$candidate_nodes[] | select(.expired_locally_retired == true) | .txid] |
          unique | sort) as $candidate_retired_member_txids |
        ($components|length) == 1 and $components[0].anchor_authenticated == true and
        $components[0].anchor_unspent == true and
        $components[0].all_claims_zero_payment_retirable == false and
        $components[0].all_claims_expired_locally_retired == false and
        $p.lineage.all_claims_zero_payment_retirable == false and
        $p.lineage.all_claims_expired_locally_retired == false and
        $recovery[0].retired_claim_objects == 0 and
        $recovery[0].retired_components == 0 and
        $p.retired_claim_objects == $recovery[0].retired_claim_objects and
        $p.retired_components == $recovery[0].retired_components and
        $candidate_retired_member_txids == [] and
        $p.candidate_retired_member_txids == $candidate_retired_member_txids and
        ($candidate_nodes | length) == ($actual | length) and
        all($actual[]; . as $id |
          ($candidate_nodes | map(select(.txid == $id))) as $matched |
          ($p.lineage.members | map(select(.txid == $id))) as $proof_members |
          ($matched | length) == 1 and ($proof_members | length) == 1 and
          $matched[0].proof_origin_bound == true and
          $matched[0].proof_input_bound == true and
          $matched[0].expired_locally_retired == false and
          $proof_members[0].proof_origin_bound == $matched[0].proof_origin_bound and
          $proof_members[0].proof_input_bound == $matched[0].proof_input_bound and
          $proof_members[0].expired_locally_retired ==
            $matched[0].expired_locally_retired) and
        $components[0].ordinary_or_mixed_txids == [] and
        $components[0].resolution_txids == [] and
        ($components[0].claim_txids|sort) == ($actual|sort) and
        $components[0].anchor.txid == $p.lineage.anchor_txid and
        $components[0].anchor.vout == $p.lineage.anchor_vout and
        $components[0].generation_fingerprint == $p.lineage.family and
        ($removed_outpoints|length) == 1 and ($added_outpoints|length) == 0 and
        $removed_outpoints[0] == ($components[0].anchor | outpoint_key) and
        $resolution_before[0] == $p.resolution_txids_before and
        $resolution_after[0] == $p.resolution_txids_after and
        $component_before[0] == $p.component_resolution_txids_before and
        $component_after[0] == $p.component_resolution_txids_after and
        $pow_before[0].payout_address == $p.payout_address_before and
        $pow_after[0].payout_address == $p.payout_address_after and
        ($quantum_before[0] | inventory_count) == $p.quantum_key_count_before and
        ($quantum_after[0] | inventory_count) == $p.quantum_key_count_after and
        $recovery_before[0].confirmed_resolution_fees ==
          $p.confirmed_resolution_fees_before and
        ($recovery_before[0].cumulative_resolution_fees //
          $recovery_before[0].confirmed_resolution_fees) ==
          $p.cumulative_resolution_fees_before and
        $recovery_before[0].pending_manual_resolutions == $p.pending_manual_before and
        $recovery_before[0].pending_automatic_resolutions == $p.pending_automatic_before and
        $recovery[0].confirmed_resolution_fees == $p.confirmed_resolution_fees_after and
        ($recovery[0].cumulative_resolution_fees // $recovery[0].confirmed_resolution_fees) ==
          $p.cumulative_resolution_fees_after and
        $recovery[0].pending_manual_resolutions == $p.pending_manual_after and
        $recovery[0].pending_automatic_resolutions == $p.pending_automatic_after and
        $pow_after[0].claims_submitted == $p.candidate_claims_submitted and
        $pow_after[0].mining_gate_coherent == $p.candidate_mining_gate_coherent and
        $pow_after[0].mining_gate_database_ambiguous ==
          $p.candidate_mining_gate_database_ambiguous and
        $pow_after[0].mining_gate_unsafe_claims == $p.candidate_mining_gate_unsafe_claims and
        $pow_after[0].mining_gate_unsafe_components ==
          $p.candidate_mining_gate_unsafe_components and
        $recovery[0].database_outcome_ambiguous ==
          $p.candidate_recovery_database_ambiguous and
        $pow_after[0].enabled == false and $pow_after[0].hashrate == 0 and
        $pow_after2[0].enabled == false and $pow_after2[0].hashrate == 0 and
        $staking_after[0].enabled == false and $staking_after[0].staking == false and
        $staking_after[0].worker_running == false and
        $staking_after2[0].enabled == false and $staking_after2[0].staking == false and
        $staking_after2[0].worker_running == false and
        $final_chain[0].chain == "main" and $final_chain[0].initialblockdownload == false and
        $final_chain[0].blocks == $final_chain[0].headers and
        $final_chain2[0].bestblockhash==$final_chain[0].bestblockhash and
        $final_chain2[0].chainwork==$final_chain[0].chainwork and
        $final_chain2[0].blocks==$final_chain[0].blocks and
        $recovery_after[0].active_tip==$final_chain[0].bestblockhash and
        $recovery_after[0].wallet_generation==$recovery[0].wallet_generation and
        $stable_cut[0].stable==true and
        $stable_cut[0].terminal_tip==$final_chain[0].bestblockhash and
        $stable_cut[0].terminal_chainwork==$final_chain[0].chainwork and
        $stable_cut[0].wallet_generation==$recovery[0].wallet_generation and
        $observer_terminal[0].terminal_tip==$stable_cut[0].terminal_tip and
        $observer_terminal[0].terminal_chainwork==$stable_cut[0].terminal_chainwork and
        $observer_terminal[0].observer_chains==$observer_chains and
        $observer_terminal[0].observer_anchors==$observer_anchors and
        $observer_terminal[0].tx_absence==$absence and
        $observer_terminal[0].observers_stable_and_cover_terminal==true and
        $observer_terminal[0].authenticated_anchor_unspent_on_all_observers==true and
        ([$observer_chains[].observer]|sort)==
          (["blackcoin-v4-gui-26","blackcoin-v4-gui-28"]|sort) and
        ([$observer_chains[].observer]|unique|length)==2 and
        all($observer_chains[];
          .stable==true and .chain_before.bestblockhash==.chain_after.bestblockhash and
          .chain_before.chainwork==.chain_after.chainwork and
          .chain_before.blocks==.chain_after.blocks and .chain_before.blocks==.chain_before.headers and
          (.terminal_relation=="same_terminal_tip" or
           .terminal_relation=="terminal_superseded_by_greater_work") and
          (if .terminal_relation=="same_terminal_tip" then
             .chain_before.bestblockhash==$stable_cut[0].terminal_tip and
             .chain_before.chainwork==$stable_cut[0].terminal_chainwork
           else .chain_before.chainwork>$stable_cut[0].terminal_chainwork end)) and
        ([$observer_anchors[].observer]|sort)==
          (["blackcoin-v4-gui-26","blackcoin-v4-gui-28"]|sort) and
        all($observer_anchors[];
          .unspent==true and .anchor.txid==$components[0].anchor.txid and
          .anchor.vout==$components[0].anchor.vout and .txout.confirmations>=1 and
          .txout.coinbase==false) and
        $progress[0].envelopes[-1].chain_before.chainwork <= $final_chain[0].chainwork
    ' >/dev/null || die 'raw wallet/recovery/observer evidence does not reproduce claim proof'
    [[ "$(sha_of "$root/baseline-quantum-inventory.json")" == \
       "$(jq -er '.quantum_inventory_sha256_before' "$root/phase-a-claim-proof.json")" &&
       "$(sha_of "$root/candidate-final-quantum-inventory.json")" == \
       "$(jq -er '.quantum_inventory_sha256_after' "$root/phase-a-claim-proof.json")" ]] ||
        die 'quantum-inventory hashes do not reproduce claim proof'
    [[ "$(sha_of "$root/observer-terminal-proof.json")" == \
         "$(jq -er '.observer_terminal_proof_sha256' "$root/phase-a-claim-proof.json")" &&
       "$(sha_of "$root/candidate-final-stable-cut.json")" == \
         "$(jq -er '.final_stable_cut_sha256' "$root/phase-a-claim-proof.json")" &&
       "$(sha_of "$root/candidate-stopped.json")" == \
         "$(jq -er '.candidate_stopped_receipt_sha256' "$root/phase-a-claim-proof.json")" &&
       "$(sha_of "$root/candidate-complete.log")" == \
         "$(jq -er '.candidate_complete_log_sha256' "$root/phase-a-claim-proof.json")" &&
       "$(sha_of "$root/candidate-post-stop-log-receipt.json")" == \
         "$(jq -er '.candidate_post_stop_log_receipt_sha256' \
           "$root/phase-a-claim-proof.json")" ]] ||
        die 'claim proof terminal receipts do not bind raw evidence'
    jq -e --arg stopped "$(sha_of "$root/candidate-stopped.json")" \
        --arg log "$(sha_of "$root/candidate-complete.log")" '
      (keys|sort)==(["candidate_finished_at","candidate_stopped_receipt_sha256",
        "captured_after_clean_stop","captured_utc","complete_log_sha256","schema"]|sort) and
      .schema==1 and .candidate_stopped_receipt_sha256==$stopped and
      .complete_log_sha256==$log and .captured_after_clean_stop==true and
      (.candidate_finished_at|type)=="string" and (.captured_utc|type)=="string"
    ' "$root/candidate-post-stop-log-receipt.json" >/dev/null ||
        die 'post-stop log receipt does not bind the stopped candidate and complete log'
    for sample in 1 2 3 4; do
        [[ "$(sha_of "$root/candidate-visibility-sample-${sample}.json")" == \
           "$(jq -er --argjson index "$((sample - 1))" \
             '.visibility_sample_sha256s[$index]' "$root/phase-a-progress.json")" ]] ||
            die "progress does not bind visibility sample: $sample"
    done
}

verify_phase_a_pre()
{
    local root="$1" nonce candidate_id qt_sha
    secure_root "$root"
    verify_pre_rewind_seal "$root"
    require_files "$root" unlock-helper-audit.json locks.json snapshot-set.json \
        candidate-created-stopped.json candidate-invocation-initial.json \
        candidate-invocation-restart.json phase-a-nonpublication-initial.json \
        phase-a-nonpublication-restart-preunlock.json phase-a-nonpublication-final.json \
        phase-a-progress.json phase-a-claim-proof.json candidate-pow-joined.json \
        candidate-wallet-locked.json candidate-stop.json candidate-final-stable-cut.json \
        observer-terminal-proof.json observer-final-chain.jsonl observer-anchor-unspent.jsonl \
        candidate-complete.log candidate-stopped.json candidate-rpc-methods-through-proof.log \
        candidate-post-stop-log-receipt.json guard-source-identity.json \
        baseline-runtime-identity.json tooling-identity.json \
        baseline-cold-stop-authority.json candidate-stop-authority.json
    verify_candidate_identity "$root"
    verify_phase_a_tooling_identity "$root"
    candidate_id=$(jq -er '.image_config_digest' "$root/candidate-oci-identity.json") ||
        die 'candidate image ID absent'
    qt_sha=$(awk -F '\t' '$1 == "blackcoin-qt" {print $2}' \
        "$root/candidate-loaded-binary-sha256.tsv") || die 'candidate Qt hash absent'
    nonce=$(jq -er '.run_nonce' "$root/unlock-helper-audit.json") || die 'helper nonce absent'
    hotfix_valid_nonce "$nonce" || die 'helper nonce malformed'
    hotfix_unlock_helper_audit_file_is_valid "$root/unlock-helper-audit.json" ||
        die 'unlock helper audit failed'
    jq -e --arg nonce "$nonce" '.schema==1 and .run_nonce==$nonce and .held==true and
      .order==["/run/blackcoin-endpoint-guard.lock","/var/run/blackcoin-node-cutover.lock",
       "/run/blackcoin-pow-quarantine-cycle.lock","/var/run/blackcoin-wallet-runtime-guard.lock"]' \
      "$root/locks.json" >/dev/null || die 'lock-order evidence failed'
    hotfix_snapshot_set_file_is_valid "$root/snapshot-set.json" "$nonce" ||
        die 'snapshot set identity/hold contract failed'
    verify_phase_a_stop_authority_bindings "$root" "$candidate_id"
    jq -e --arg id "$candidate_id" '
      .image_id == $id and .running == false and .user == "blackcoin" and
      .working_dir == "/home/blackcoin" and .mounts_sha256 != null and
      .network_sha256 != null
    ' "$root/candidate-created-stopped.json" >/dev/null ||
        die 'created-stopped candidate identity failed'
    hotfix_invocation_file_is_valid "$root/candidate-invocation-initial.json" A \
        "$candidate_id" "$nonce" ||
        die 'initial Phase-A invocation failed'
    hotfix_invocation_file_is_valid "$root/candidate-invocation-restart.json" A \
        "$candidate_id" "$nonce" ||
        die 'restart Phase-A invocation failed'
    [[ "$(jq -er '.pid1_exe_sha256' "$root/candidate-invocation-initial.json")" == "$qt_sha" &&
       "$(jq -er '.pid1_exe_sha256' "$root/candidate-invocation-restart.json")" == "$qt_sha" ]] ||
        die 'PID1 executable is not the sealed candidate Qt binary'
    verify_phase_a_invocation_surface_bindings "$root" "$nonce" "$candidate_id"
    hotfix_phase_a_progress_file_is_valid "$root/phase-a-progress.json" ||
        die 'Phase-A progress contract failed'
    hotfix_phase_a_claim_proof_file_is_valid "$root/phase-a-claim-proof.json" ||
        die 'Phase-A claim proof failed'
    [[ "$(jq -er '.run_nonce' "$root/phase-a-progress.json")" == "$nonce" &&
       "$(jq -er '.run_nonce' "$root/phase-a-claim-proof.json")" == "$nonce" ]] ||
        die 'progress/claim proof nonce differs from authority nonce'
    jq -e --arg id "$candidate_id" '.running==false and .exit_code==0 and .image_id==$id' \
      "$root/candidate-stopped.json" >/dev/null ||
        die 'candidate was not cleanly stopped'
    grep -F 'retained a claim after relay failure' "$root/candidate-complete.log" >/dev/null ||
        die 'PERSISTED_PENDING worker log absent'
    grep -F 'persisted without relay' "$root/candidate-complete.log" >/dev/null ||
        die 'no-relay persistence log absent'
    hotfix_candidate_pow_json_is_valid "$(<"$root/candidate-pow-joined.json")" off ||
        die 'candidate PoW worker did not synchronously stop/join'
    jq -e '.unlocked_until==0' "$root/candidate-wallet-locked.json" >/dev/null ||
        die 'candidate wallet was not locked before clean stop'
    verify_rpc_journal_phase_a "$root/candidate-rpc-methods-through-proof.log"
    # The verifier receipt and PRE_REWIND_VERIFIED state are created only after this
    # non-self-referential pre-rewind verification succeeds. The certificate and
    # final verifier bind and validate those two later receipts.
    [[ "$(sha_of "$root/candidate-rpc-methods-through-proof.log")" == \
       "$(jq -er '.rpc_methods_sha256' "$root/phase-a-claim-proof.json")" ]] ||
        die 'RPC journal is not bound to claim proof'
    jq -e '
      .schema==1 and (.runtime_guard_sha256|test("^[0-9a-f]{64}$")) and
      (.endpoint_guard_sha256|test("^[0-9a-f]{64}$")) and
      (.pow_cycle_sha256|test("^[0-9a-f]{64}$")) and
      .node27_canary_marker_contract_verified==true and
      .maintenance_fail_closed_verified==true
    ' "$root/guard-source-identity.json" >/dev/null || die 'guard source identity failed'
    verify_phase_a_claim_raw_bindings "$root"
    verify_pre_rewind_seal "$root"
    secure_root "$root"
    printf 'Phase-A pre-rewind evidence verified: %s\n' "$root"
}

verify_phase_a_catchup_bindings()
{
    local root="$1" nonce="$2" cert="$3" candidate_txids
    require_files "$root" base-catchup-proof.json base-quarantine-created-stopped.json \
        base-quarantine-invocation-current.json base-quarantine-nonpublication-current.json \
        base-catchup-chain.json base-catchup-chain-after.json \
        base-catchup-recovery.json base-catchup-wallet.json \
        base-catchup-staking.json base-catchup-pow.json base-catchup-network.json \
        base-catchup-wallets.json base-catchup-wallet-transactions.json \
        base-catchup-mempool.json base-catchup-anchor.json base-catchup-observer.jsonl \
        baseline-wallets.json phase-a-claim-proof.json
    hotfix_invocation_file_is_valid "$root/base-quarantine-invocation-current.json" A \
        "$IMMUTABLE_V3014_IMAGE_ID" "$nonce" "$IMMUTABLE_V3014_SOURCE_SHA" ||
        die 'catch-up immutable invocation failed'
    hotfix_nonpublication_file_is_valid \
        "$root/base-quarantine-nonpublication-current.json" "$nonce" ||
        die 'catch-up nonpublication contract failed'
    verify_nonpublication_raw_bindings "$root" base-quarantine-nonpublication-current
    candidate_txids=$(jq -c '.candidate_created_qqsproof_txids' \
        "$root/phase-a-claim-proof.json") || die 'candidate txids absent from claim proof'
    jq -e -n --arg nonce "$nonce" --arg source "$IMMUTABLE_V3014_SOURCE_SHA" \
        --arg image "$IMMUTABLE_V3014_IMAGE_REF" --arg id "$IMMUTABLE_V3014_IMAGE_ID" \
        --arg terminal_tip "$(jq -er '.terminal_tip' "$cert")" \
        --arg terminal_work "$(jq -er '.terminal_chainwork' "$cert")" \
        --arg invocation "$(sha_of "$root/base-quarantine-invocation-current.json")" \
        --arg nonpublication "$(sha_of "$root/base-quarantine-nonpublication-current.json")" \
        --arg observer "$(sha_of "$root/base-catchup-observer.jsonl")" \
        --arg chain_sha "$(sha_of "$root/base-catchup-chain.json")" \
        --arg chain_after_sha "$(sha_of "$root/base-catchup-chain-after.json")" \
        --arg recovery_sha "$(sha_of "$root/base-catchup-recovery.json")" \
        --arg wallet_sha "$(sha_of "$root/base-catchup-wallet.json")" \
        --arg staking_sha "$(sha_of "$root/base-catchup-staking.json")" \
        --arg pow_sha "$(sha_of "$root/base-catchup-pow.json")" \
        --arg network_sha "$(sha_of "$root/base-catchup-network.json")" \
        --arg wallets_sha "$(sha_of "$root/base-catchup-wallets.json")" \
        --arg wallet_tx_sha "$(sha_of "$root/base-catchup-wallet-transactions.json")" \
        --arg mempool_sha "$(sha_of "$root/base-catchup-mempool.json")" \
        --arg anchor_sha "$(sha_of "$root/base-catchup-anchor.json")" \
        --argjson txids "$candidate_txids" \
        --slurpfile proof "$root/base-catchup-proof.json" \
        --slurpfile chain "$root/base-catchup-chain.json" \
        --slurpfile chain_after "$root/base-catchup-chain-after.json" \
        --slurpfile recovery "$root/base-catchup-recovery.json" \
        --slurpfile wallet "$root/base-catchup-wallet.json" \
        --slurpfile staking "$root/base-catchup-staking.json" \
        --slurpfile pow "$root/base-catchup-pow.json" \
        --slurpfile network "$root/base-catchup-network.json" \
        --slurpfile wallets "$root/base-catchup-wallets.json" \
        --slurpfile wallet_tx "$root/base-catchup-wallet-transactions.json" \
        --slurpfile mempool "$root/base-catchup-mempool.json" \
        --slurpfile anchor "$root/base-catchup-anchor.json" \
        --slurpfile observers "$root/base-catchup-observer.jsonl" \
        --slurpfile lineage "$root/phase-a-claim-proof.json" '
      ($proof[0]) as $p | ($chain[0]) as $c |
      $p.run_nonce==$nonce and $p.source_sha==$source and $p.image==$image and $p.image_id==$id and
      $p.invocation_sha256==$invocation and $p.nonpublication_sha256==$nonpublication and
      $p.observer_cut_sha256==$observer and $p.chain_evidence_sha256==$chain_sha and
      $p.chain_after_evidence_sha256==$chain_after_sha and
      $p.recovery_evidence_sha256==$recovery_sha and $p.wallet_evidence_sha256==$wallet_sha and
      $p.staking_evidence_sha256==$staking_sha and $p.pow_evidence_sha256==$pow_sha and
      $p.network_evidence_sha256==$network_sha and $p.wallets_evidence_sha256==$wallets_sha and
      $p.wallet_transactions_sha256==$wallet_tx_sha and $p.mempool_sha256==$mempool_sha and
      $p.authenticated_anchor_evidence_sha256==$anchor_sha and
      $p.phase_a_terminal_tip==$terminal_tip and $p.phase_a_terminal_chainwork==$terminal_work and
      $p.chain==$c and $p.chain_after==$chain_after[0] and
      $p.recovery==$recovery[0] and $p.wallet==$wallet[0] and
      $p.staking==$staking[0] and $p.pow==$pow[0] and $p.network==$network[0] and
      $p.wallets==$wallets[0] and $p.authenticated_anchor.txout==$anchor[0] and
      $p.authenticated_anchor.txid==$lineage[0].lineage.anchor_txid and
      $p.authenticated_anchor.vout==$lineage[0].lineage.anchor_vout and
      $p.authenticated_anchor.unspent==true and $p.candidate_image_not_applied==true and
      $p.hard_quarantine_flags_verified==true and $p.wallet_locked==true and
      $p.pow_enabled==false and $p.pos_enabled==false and $p.walletbroadcast==false and
      $p.wallet_processed_tip_current==true and $p.candidate_txids_absent_from_wallet==true and
      $p.candidate_txids_absent_from_mempool==true and $p.authenticated_anchor_unspent==true and
      $p.observer_candidate_txids_absent==true and $p.observer_anchor_unspent==true and
      $p.candidate_claim_escape_absent==true and $p.stable_cut==true and
      $c.chain=="main" and $c.initialblockdownload==false and $c.blocks==$c.headers and
      $chain_after[0].bestblockhash==$c.bestblockhash and
      $chain_after[0].chainwork==$c.chainwork and
      $chain_after[0].blocks==$c.blocks and $chain_after[0].headers==$c.headers and
      $c.chainwork>=$terminal_work and
      (($p.terminal_tip_active==true and $p.terminal_tip_superseded_by_greater_work==false and
         $c.bestblockhash==$terminal_tip and $c.chainwork==$terminal_work) or
       ($p.terminal_tip_active==false and $p.terminal_tip_superseded_by_greater_work==true and
         $c.chainwork>$terminal_work)) and
      $recovery[0].database_outcome_ambiguous==false and $recovery[0].chain_ready==true and
      $recovery[0].wallet_tip_matches==true and $recovery[0].active_tip==$c.bestblockhash and
      $recovery[0].wallet_processed_tip==$c.bestblockhash and
      $wallet[0].scanning==false and $wallet[0].unlocked_until==0 and
      $wallet[0].private_keys_enabled==true and
      $staking[0].enabled==false and $staking[0].staking==false and
      $staking[0].worker_running==false and $pow[0].enabled==false and $pow[0].hashrate==0 and
      $network[0].networkactive==true and $network[0].localrelay==false and
      $network[0].connections_out>=3 and
      all($txids[]; . as $id | ($wallet_tx[0]|map(.txid)|index($id))==null and
        ($mempool[0]|index($id))==null) and
      $anchor[0].confirmations>=1 and $anchor[0].coinbase==false and
      ([$observers[].observer]|sort)==(["blackcoin-v4-gui-26","blackcoin-v4-gui-28"]|sort) and
      ([$observers[].observer]|unique|length)==2 and all($observers[];
        . as $observer |
        $observer.stable==true and $observer.candidate_txids_absent==true and
        $observer.chain_before.bestblockhash==$observer.chain_after.bestblockhash and
        $observer.chain_before.chainwork==$observer.chain_after.chainwork and
        $observer.chain_before.blocks==$observer.chain_after.blocks and
        all($txids[]; . as $id | ($observer.mempool|index($id))==null) and
        $observer.anchor.txid==$lineage[0].lineage.anchor_txid and
        $observer.anchor.vout==$lineage[0].lineage.anchor_vout and
        $observer.anchor.unspent==true and
        $observer.anchor.txout.confirmations>=1 and
        $observer.anchor.txout.coinbase==false)
    ' >/dev/null || die 'immutable catch-up proof is not reproduced by its raw envelope'
    cmp -s "$root/base-catchup-wallets.json" "$root/baseline-wallets.json" ||
        die 'immutable catch-up loaded-wallet set differs from the recorded baseline'
}

verify_phase_a_final()
{
    local root="$1" nonce result cert candidate_id qt_sha field pair expected actual
    secure_root "$root"
    verify_full_seal "$root"
    # PRE manifest remains immutable after the certificate; verify its contents but not its old file-set view.
    manifest_names_are_safe "$root/PRE_REWIND_SHA256SUMS" ||
        die 'unsafe or duplicate pre-rewind manifest entry'
    (cd "$root" && sha256sum --strict -c PRE_REWIND_SHA256SUMS >/dev/null) ||
        die 'pre-rewind bytes changed after certification'
    verify_post_rewind_seal "$root"
    require_files "$root" REWIND_SAFE.json base-catchup-proof.json snapshot-absence-proof.json \
        snapshot-destroy-authority-rechecks.jsonl POST_REWIND_SHA256SUMS RESULT.json \
        unlock-helper-audit.json snapshot-set.json \
        phase-a-progress.json phase-a-claim-proof.json phase-a-nonpublication-final.json \
        candidate-invocation-restart.json candidate-complete.log \
        candidate-final-chain.json candidate-final-chain-after.json \
        candidate-final-pow.json candidate-final-pow-after.json \
        candidate-final-staking.json candidate-final-staking-after.json \
        candidate-final-recovery-inventory.json candidate-final-recovery-after.json \
        candidate-final-wallet-transactions.json candidate-final-mempool.json \
        observer-terminal-proof.json observer-final-chain.jsonl observer-anchor-unspent.jsonl \
        observer-tx-absence.jsonl candidate-final-stable-cut.json candidate-stopped.json \
        baseline-cold-stop-authority.json candidate-stop-authority.json \
        candidate-post-stop-log-receipt.json candidate-rpc-methods-through-proof.log \
        locks.json pre-rewind-state.json tooling-identity.json \
        pre-rewind-verifier.json maintenance-marker-activated.json guard-source-identity.json \
        baseline-runtime-identity.json base-quarantine-created-stopped.json \
        base-quarantine-invocation.json base-quarantine-invocation-current.json \
        base-quarantine-nonpublication-current.json base-quarantine-stop-authority.json \
        baseline-restored-container.json baseline-restored-chain.json \
        baseline-restored-network.json baseline-restored-wallet.json \
        baseline-restored-staking.json baseline-restored-pow-state.json \
        baseline-restored-recovery.json baseline-restored-quantum.json \
        baseline-restored-wallets.json
    verify_candidate_identity "$root"
    verify_phase_a_tooling_identity "$root"
    nonce=$(jq -er '.run_nonce' "$root/RESULT.json") || die 'Phase-A result nonce absent'
    result="$root/RESULT.json"
    cert="$root/REWIND_SAFE.json"
    candidate_id=$(jq -er '.image_config_digest' "$root/candidate-oci-identity.json") ||
        die 'candidate image ID absent'
    qt_sha=$(awk -F '\t' '$1 == "blackcoin-qt" {print $2}' \
        "$root/candidate-loaded-binary-sha256.tsv") || die 'candidate Qt hash absent'
    hotfix_rewind_safe_file_is_valid "$cert" "$nonce" ||
        die 'REWIND_SAFE certificate failed'
    jq -e --arg nonce "$nonce" --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" \
        --arg manifest "$(sha_of "$root/PRE_REWIND_SHA256SUMS")" \
        --arg verifier "$(sha_of "$PACKAGE_ROOT/verify-evidence.sh")" '
      . == {schema:1,mode:"phase-a-pre-rewind",result:"passed",run_nonce:$nonce,
            candidate_source_sha:$source,pre_rewind_manifest_sha256:$manifest,
            verifier_sha256:$verifier}
    ' "$root/pre-rewind-verifier.json" >/dev/null || die 'offline verifier receipt failed'
    jq -e --arg nonce "$nonce" '.schema==2 and .phase=="A" and .run_nonce==$nonce and
      .state=="PRE_REWIND_VERIFIED" and .previous_state=="CANDIDATE_STOPPED"' \
      "$root/pre-rewind-state.json" >/dev/null || die 'pre-rewind state receipt failed'
    hotfix_unlock_helper_audit_file_is_valid "$root/unlock-helper-audit.json" ||
        die 'final helper audit failed'
    hotfix_invocation_file_is_valid "$root/candidate-invocation-restart.json" A \
        "$candidate_id" "$nonce" || die 'final candidate invocation failed'
    [[ "$(jq -er '.pid1_exe_sha256' "$root/candidate-invocation-restart.json")" == "$qt_sha" ]] ||
        die 'final PID1 executable differs from sealed candidate Qt'
    hotfix_nonpublication_file_is_valid "$root/phase-a-nonpublication-final.json" "$nonce" ||
        die 'final nonpublication predicate failed'
    hotfix_phase_a_progress_file_is_valid "$root/phase-a-progress.json" ||
        die 'final progress predicate failed'
    hotfix_phase_a_claim_proof_file_is_valid "$root/phase-a-claim-proof.json" ||
        die 'final claim predicate failed'
    [[ "$(jq -er '.run_nonce' "$root/phase-a-progress.json")" == "$nonce" &&
       "$(jq -er '.run_nonce' "$root/phase-a-claim-proof.json")" == "$nonce" ]] ||
        die 'final progress/claim nonce mismatch'
    verify_phase_a_invocation_surface_bindings "$root" "$nonce" "$candidate_id"
    verify_phase_a_stop_authority_bindings "$root" "$candidate_id"
    verify_phase_a_claim_raw_bindings "$root"
    verify_rpc_journal_phase_a "$root/candidate-rpc-methods-through-proof.log"
    hotfix_base_catchup_file_is_valid "$root/base-catchup-proof.json" "$nonce" ||
        die 'base catch-up proof failed'
    verify_phase_a_catchup_bindings "$root" "$nonce" "$cert"
    hotfix_snapshot_absence_file_is_valid "$root/snapshot-absence-proof.json" "$nonce" ||
        die 'snapshot absence proof failed'
    jq -e --arg id "$IMMUTABLE_V3014_IMAGE_ID" '
      .image_id==$id and .running==false and .user=="blackcoin" and
      .working_dir=="/home/blackcoin"
    ' "$root/base-quarantine-created-stopped.json" >/dev/null ||
        die 'immutable base was not created stopped in hard quarantine'
    hotfix_invocation_file_is_valid "$root/base-quarantine-invocation.json" A \
        "$IMMUTABLE_V3014_IMAGE_ID" "$nonce" "$IMMUTABLE_V3014_SOURCE_SHA" ||
        die 'immutable base hard-quarantine invocation failed'
    hotfix_phase_a_result_file_is_valid "$result" || die 'Phase-A RESULT failed'
    hotfix_phase_a_stable_stop_file_is_valid "$root/base-quarantine-stop-authority.json" \
        base-quarantine-to-baseline "$IMMUTABLE_V3014_IMAGE_ID" \
        "$IMMUTABLE_V3014_IMAGE_REF" ||
        die 'hard-quarantine base stable-stop authority failed'
    jq -e -n --arg id "$IMMUTABLE_V3014_IMAGE_ID" --arg ref "$IMMUTABLE_V3014_IMAGE_REF" \
        --slurpfile runtime "$root/baseline-runtime-identity.json" \
        --slurpfile stopped "$root/base-quarantine-stop-authority.json" \
        --slurpfile restored "$root/baseline-restored-container.json" '
      ($restored[0]|keys|sort)==(["container_id","image_id","image_ref","mounts_sha256",
        "network_sha256","restart_policy","running","schema"]|sort) and
      $restored[0].schema==1 and ($restored[0].container_id|test("^[0-9a-f]{64}$")) and
      $restored[0].image_id==$id and $restored[0].image_ref==$ref and
      $restored[0].running==true and
      $restored[0].mounts_sha256==$runtime[0].mounts_sha256 and
      $restored[0].network_sha256==$runtime[0].network_sha256 and
      $restored[0].restart_policy==$runtime[0].restart_policy and
      $stopped[0].original_restart_policy=={Name:"no",MaximumRetryCount:0}
    ' >/dev/null || die 'normal baseline recreation did not restore exact runtime policy'
    [[ "$(jq -er '.base_quarantine_stop_authority_sha256' "$result")" == \
       "$(sha_of "$root/base-quarantine-stop-authority.json")" &&
       "$(jq -er '.baseline_restored_container_sha256' "$result")" == \
       "$(sha_of "$root/baseline-restored-container.json")" ]] ||
        die 'Phase-A RESULT does not bind stable base cutover/restored runtime evidence'
    jq -e -n --slurpfile chain "$root/baseline-restored-chain.json" \
        --slurpfile network "$root/baseline-restored-network.json" \
        --slurpfile wallet "$root/baseline-restored-wallet.json" \
        --slurpfile staking "$root/baseline-restored-staking.json" \
        --slurpfile pow "$root/baseline-restored-pow-state.json" \
        --slurpfile baseline_pow "$root/baseline-pow.json" \
        --slurpfile wallets "$root/baseline-restored-wallets.json" '
      $chain[0].chain=="main" and $chain[0].initialblockdownload==false and
      $chain[0].blocks==$chain[0].headers and $network[0].networkactive==true and
      $network[0].connections_out>=3 and $wallet[0].private_keys_enabled==true and
      $wallet[0].unlocked_staking_only==false and $wallet[0].unlocked_until>0 and
      $staking[0].enabled==true and $staking[0].staking==true and
      $staking[0].worker_running==true and $staking[0].weight>0 and
      $pow[0].enabled==$baseline_pow[0].enabled and
      $pow[0].payout_address==$baseline_pow[0].payout_address and
      $pow[0].threads==1 and $pow[0].cpu_percent==1 and
      ($pow[0]|keys|map(select(startswith("mining_gate_")))|length)==0 and
      $wallets[0]==[""]
    ' >/dev/null || die 'restored immutable baseline runtime is not active and identity-stable'
    jq -e --argjson fee "$(jq -c '.confirmed_resolution_fees' \
        "$root/baseline-recovery.json")" '
      .database_outcome_ambiguous==false and .policy_authoritative==true and
      .automatic_authorized==false and .confirmed_resolution_fees==$fee
    ' "$root/baseline-restored-recovery.json" >/dev/null ||
        die 'restored baseline recovery inventory is unsafe'
    [[ "$(recovery_metrics_sha "$root/baseline-restored-recovery.json")" == \
       "$(recovery_metrics_sha "$root/baseline-recovery.json")" ]] ||
        die 'restored baseline recovery counters changed'
    cmp -s <(jq -cS '{policy,policy_authoritative,automatic_authorized}' \
        "$root/baseline-recovery.json") \
        <(jq -cS '{policy,policy_authoritative,automatic_authorized}' \
        "$root/baseline-restored-recovery.json") ||
        die 'restored baseline recovery policy changed'
    cmp -s <(jq -cS . "$root/baseline-quantum-inventory.json") \
        <(jq -cS . "$root/baseline-restored-quantum.json") ||
        die 'restored baseline quantum inventory changed'
    for pair in \
        "invocation_sha256|candidate-invocation-restart.json" \
        "helper_audit_sha256|unlock-helper-audit.json" \
        "nonpublication_sha256|phase-a-nonpublication-final.json" \
        "snapshot_set_sha256|snapshot-set.json" \
        "progress_sha256|phase-a-progress.json" \
        "claim_proof_sha256|phase-a-claim-proof.json" \
        "logs_sha256|candidate-complete.log" \
        "rpc_journal_sha256|candidate-rpc-methods-through-proof.log" \
        "locks_sha256|locks.json" \
        "guard_sources_sha256|guard-source-identity.json" \
        "pre_rewind_state_sha256|pre-rewind-state.json" \
        "maintenance_marker_sha256|maintenance-marker-activated.json" \
        "offline_verifier_receipt_sha256|pre-rewind-verifier.json" \
        "phase_a_tooling_identity_sha256|tooling-identity.json" \
        "baseline_runtime_identity_sha256|baseline-runtime-identity.json" \
        "candidate_bundle_manifest_sha256|candidate-bundle-manifest.json" \
        "candidate_oci_identity_sha256|candidate-oci-identity.json" \
        "candidate_binary_sha256sums_sha256|candidate-binary-sha256sums.txt" \
        "candidate_loaded_image_sha256|candidate-loaded-image.json" \
        "pre_rewind_manifest_sha256|PRE_REWIND_SHA256SUMS" \
        "candidate_final_chain_sha256|candidate-final-chain.json" \
        "candidate_final_chain_after_sha256|candidate-final-chain-after.json" \
        "candidate_final_pow_sha256|candidate-final-pow.json" \
        "candidate_final_pow_after_sha256|candidate-final-pow-after.json" \
        "candidate_final_staking_sha256|candidate-final-staking.json" \
        "candidate_final_staking_after_sha256|candidate-final-staking-after.json" \
        "candidate_final_recovery_sha256|candidate-final-recovery-inventory.json" \
        "candidate_final_recovery_after_sha256|candidate-final-recovery-after.json" \
        "candidate_final_wallet_transactions_sha256|candidate-final-wallet-transactions.json" \
        "candidate_final_mempool_sha256|candidate-final-mempool.json" \
        "observer_terminal_proof_sha256|observer-terminal-proof.json" \
        "observer_final_chain_sha256|observer-final-chain.jsonl" \
        "observer_anchor_unspent_sha256|observer-anchor-unspent.jsonl" \
        "observer_tx_absence_sha256|observer-tx-absence.jsonl" \
        "candidate_final_stable_cut_sha256|candidate-final-stable-cut.json" \
        "candidate_stopped_receipt_sha256|candidate-stopped.json" \
        "candidate_stop_authority_sha256|candidate-stop-authority.json" \
        "candidate_post_stop_log_receipt_sha256|candidate-post-stop-log-receipt.json"; do
        field=${pair%%|*}
        actual=${pair#*|}
        expected=$(jq -er --arg field "$field" '.[$field]' "$cert") ||
            die "certificate field absent: $field"
        [[ "$expected" == "$(sha_of "$root/$actual")" ]] ||
            die "certificate hash mismatch: $field"
    done
    [[ "$(jq -er '.candidate_image_id' "$cert")" == "$candidate_id" &&
       "$(jq -er '.candidate_manifest_digest' "$cert")" == \
         "$(jq -er '.image_manifest_digest' "$root/candidate-oci-identity.json")" &&
       "$(jq -er '.candidate_blackcoin_qt_sha256' "$cert")" == "$qt_sha" &&
       "$(jq -cS '.candidate_created_qqsproof_txids' "$cert")" == \
         "$(jq -cS '.candidate_created_qqsproof_txids' "$root/phase-a-claim-proof.json")" ]] ||
        die 'certificate candidate/claim identity differs from source evidence'
    jq -e --arg identity_sha "$(sha_of "$root/tooling-identity.json")" \
        --arg recovery_metrics "$(recovery_metrics_sha "$root/baseline-recovery.json")" \
        --slurpfile identity "$root/tooling-identity.json" \
        --slurpfile result "$result" '
      .tooling_commit==$identity[0].tooling_commit and
      .phase_a_tooling_identity_sha256==$identity_sha and
      .package_sha256sums_sha256==$identity[0].package_sha256sums_sha256 and
      .phase_a_script_sha256==$identity[0].phase_a_script_sha256 and
      .phase_b_script_sha256==$identity[0].phase_b_script_sha256 and
      .verifier_sha256==$identity[0].verifier_sha256 and
      .typed_contract_sha256==$identity[0].typed_contract_sha256 and
      .recovery_metrics_sha256==$recovery_metrics and
      $result[0].tooling_commit==$identity[0].tooling_commit and
      $result[0].phase_a_tooling_identity_sha256==$identity_sha and
      $result[0].package_sha256sums_sha256==$identity[0].package_sha256sums_sha256 and
      $result[0].phase_a_script_sha256==$identity[0].phase_a_script_sha256 and
      $result[0].phase_b_script_sha256==$identity[0].phase_b_script_sha256 and
      $result[0].verifier_sha256==$identity[0].verifier_sha256 and
      $result[0].typed_contract_sha256==$identity[0].typed_contract_sha256 and
      $result[0].baseline_recovery_metrics_sha256==$recovery_metrics
    ' "$cert" >/dev/null || die 'Phase-A certificate/result tooling identity differs'
    [[ "$(jq -er '.phase_a_tooling_identity_sha256' "$result")" == \
         "$(sha_of "$root/tooling-identity.json")" &&
       "$(jq -er '.phase_a_tooling_identity_sha256' "$cert")" == \
         "$(sha_of "$root/tooling-identity.json")" ]] ||
        die 'Phase-A tooling identity hash is not bound by certificate/result'
    jq -e --argjson txids "$(jq -c '.candidate_created_qqsproof_txids' \
        "$root/phase-a-claim-proof.json")" \
        --slurpfile stable "$root/candidate-final-stable-cut.json" \
        --slurpfile chain "$root/candidate-final-chain.json" \
        --slurpfile recovery "$root/candidate-final-recovery-inventory.json" '
      .complete_log_captured_after_stop==true and .terminal_stable_cut_verified==true and
      .candidate_stopped==true and .candidate_exit_code==0 and .pow_worker_joined==true and
      .wallet_locked==true and .candidate_created_qqsproof_txids==$txids and
      .network_visible_wallet_txids==[] and .confirmed_candidate_txids==[] and
      .unclassifiable_candidate_txids==[] and .unknown_or_ambiguous==false and
      .coinstake_or_wallet_escape_detected==false and .recovery_spend_or_fee_detected==false and
      .unrelated_wallet_delta==false and .terminal_tip==$stable[0].terminal_tip and
      .terminal_chainwork==$stable[0].terminal_chainwork and
      .wallet_generation==$stable[0].wallet_generation and
      .terminal_height==$chain[0].blocks and .terminal_tip==$chain[0].bestblockhash and
      .terminal_chainwork==$chain[0].chainwork and
      .wallet_generation==$recovery[0].wallet_generation
    ' "$cert" >/dev/null || die 'REWIND_SAFE terminal scalars are not raw-bound'
    [[ "$(jq -er '.terminal_chainwork' "$cert")" == \
         "$(jq -er '.phase_a_terminal_chainwork' "$root/base-catchup-proof.json")" &&
       "$(jq -er '.terminal_tip' "$cert")" == \
         "$(jq -er '.phase_a_terminal_tip' "$root/base-catchup-proof.json")" ]] ||
        die 'base catch-up is not bound to the certified terminal chain'
    [[ "$(jq -er '.snapshot_set_sha256' "$root/snapshot-absence-proof.json")" == \
       "$(sha_of "$root/snapshot-set.json")" ]] ||
        die 'snapshot absence is not bound to the certified snapshot set'
    [[ "$(jq -er '.catchup_proof_sha256' "$root/snapshot-absence-proof.json")" == \
         "$(sha_of "$root/base-catchup-proof.json")" &&
       "$(jq -er '.authority_rechecks_sha256' "$root/snapshot-absence-proof.json")" == \
         "$(sha_of "$root/snapshot-destroy-authority-rechecks.jsonl")" &&
       "$(jq -er '.authority_recheck_count' "$root/snapshot-absence-proof.json")" == 10 &&
       "$(jq -er '.authority_rechecked_before_every_release_and_destroy' \
         "$root/snapshot-absence-proof.json")" == true ]] ||
        die 'snapshot absence does not bind the catch-up and per-destruction authority rechecks'
    jq -e -s --arg terminal_tip "$(jq -er '.terminal_tip' "$cert")" \
        --arg terminal_work "$(jq -er '.terminal_chainwork' "$cert")" '
      length==10 and all(.[];
        (keys|sort)==(["authenticated_anchor_unspent","authority_valid",
          "candidate_txids_absent","chain_tip","chainwork","invocation_sha256",
          "nonpublication_sha256","observed_utc","observer_cut_sha256","pos_disabled",
          "pow_disabled","terminal_relation","wallet_locked"]|sort) and
        .authority_valid==true and .candidate_txids_absent==true and
        .authenticated_anchor_unspent==true and .wallet_locked==true and
        .pow_disabled==true and .pos_disabled==true and
        (.observed_utc|type)=="string" and
        (.invocation_sha256|test("^[0-9a-f]{64}$")) and
        (.nonpublication_sha256|test("^[0-9a-f]{64}$")) and
        (.observer_cut_sha256|test("^[0-9a-f]{64}$")) and
        ((.terminal_relation=="same_terminal_tip" and .chain_tip==$terminal_tip and
          .chainwork==$terminal_work) or
         (.terminal_relation=="terminal_superseded_by_greater_work" and
          (.chain_tip|test("^[0-9a-f]{64}$")) and .chainwork>$terminal_work)))
    ' "$root/snapshot-destroy-authority-rechecks.jsonl" >/dev/null ||
        die 'per-destruction authority ledger is incomplete or internally inconsistent'
    [[ "$(sha_of "$root/REWIND_SAFE.json")" == "$(jq -er '.rewind_safe_sha256' "$result")" &&
       "$(sha_of "$root/base-catchup-proof.json")" == "$(jq -er '.catchup_proof_sha256' "$result")" &&
       "$(sha_of "$root/snapshot-absence-proof.json")" == "$(jq -er '.snapshot_absence_sha256' "$result")" &&
       "$(sha_of "$root/POST_REWIND_SHA256SUMS")" == "$(jq -er '.evidence_sha256sums_sha256' "$result")" ]] ||
        die 'Phase-A RESULT evidence binding failed'
    [[ "$(sha_of "$root/PRE_REWIND_SHA256SUMS")" == \
       "$(jq -er '.pre_rewind_manifest_sha256' "$cert")" ]] ||
        die 'REWIND_SAFE does not bind the pre-rewind manifest'
    verify_post_rewind_seal "$root"
    verify_full_seal "$root"
    secure_root "$root"
    printf 'Phase-A final evidence verified: %s\n' "$root"
}

verify_phase_b_wallet_delta_raw_bindings()
{
    local root="$1"
    require_files "$root" baseline-wallet-transactions.json \
        candidate-final-wallet-transactions.json candidate-final-recovery.json \
        baseline-payout-address.json phase-b-wallet-delta-raw.json \
        phase-b-wallet-delta.json
    jq -e -n \
        --arg baseline_sha "$(sha_of "$root/baseline-wallet-transactions.json")" \
        --arg final_sha "$(sha_of "$root/candidate-final-wallet-transactions.json")" \
        --arg recovery_sha "$(sha_of "$root/candidate-final-recovery.json")" \
        --arg raw_sha "$(sha_of "$root/phase-b-wallet-delta-raw.json")" \
        --slurpfile baseline "$root/baseline-wallet-transactions.json" \
        --slurpfile final "$root/candidate-final-wallet-transactions.json" \
        --slurpfile recovery "$root/candidate-final-recovery.json" \
        --slurpfile payout "$root/baseline-payout-address.json" \
        --slurpfile raw "$root/phase-b-wallet-delta-raw.json" \
        --slurpfile delta "$root/phase-b-wallet-delta.json" '
      def hex64: type=="string" and test("^[0-9a-f]{64}$");
      def recovery_matches($txid):
        [$recovery[0].component_details[] as $component |
          $component.nodes[] | select(.txid==$txid) | {component:$component,node:.}];
      def wallet_rows($txid): [$final[0][] | select(.txid==$txid)];
      def coinstake_ok($r):
        ($r.blockhash|hex64) and $r.source_claim_txid==null and
        $r.getshadowtransaction_response==null and $r.recovery_matches==[] and
        ($r.wallet_rows|length)>=1 and all($r.wallet_rows[];
          .generated==true and (.category|IN("generate","immature","orphan")) and
          .abandoned==false and .blockhash==$r.blockhash and
          (.qq_shadow_pow_cleanup_for?==null) and
          (.qq_shadow_pow_resolution_schema?==null) and
          (.qq_synthetic_goldrush_payout?==null) and
          (.qq_shadow_pow_authored?==null)) and
        ($r.getblock_response|type)=="object" and
        $r.getblock_response.hash==$r.blockhash and
        $r.getblock_response.confirmations>0 and
        ($r.getblock_response.tx|type)=="array" and
        ($r.getblock_response.tx|length)>=2 and
        $r.getblock_response.tx[0]!=$r.txid and
        $r.getblock_response.tx[1]==$r.txid;
      def claim_ok($r):
        $r.blockhash==null and $r.source_claim_txid==null and
        $r.getblock_response==null and $r.getshadowtransaction_response==null and
        ($r.recovery_matches|length)==1 and
        ($r.recovery_matches[0]) as $m |
        $m.node.txid==$r.txid and $m.node.kind=="claim" and
        $m.node.provenance=="explicit_authored" and $m.node.wallet_authored==true and
        $m.node.expected_shape==true and $m.node.lineage_metadata_present==true and
        $m.node.lineage_metadata_valid==true and $m.node.proof_origin_bound==true and
        $m.node.proof_input_bound==true and $m.node.expired_locally_retired==false and
        $m.node.abandoned==false and
        $m.node.resolution_metadata_valid==false and
        $m.node.resolution_relay_authorized==false and
        $m.component.anchor_authenticated==true and
        $m.component.all_claims_explicitly_provenanced==true and
        $m.component.all_claims_zero_payment_retirable==false and
        $m.component.all_claims_expired_locally_retired==false and
        ($m.component.generation_fingerprint|hex64) and
        $m.component.generation_fingerprint !=
          "0000000000000000000000000000000000000000000000000000000000000000" and
        ($m.component.claim_txids|index($r.txid))!=null and
        ($m.component.resolution_txids|index($r.txid))==null and
        ($m.component.ordinary_or_mixed_txids|index($r.txid))==null and
        ($r.wallet_rows|length)>=1 and all($r.wallet_rows[];
          .category=="send" and .qq_shadow_pow_authored=="1" and
          (.comment|IN("Quantum Quasar built-in shadow PoW claim",
            "Blackcoin shadow PoW claim","PoW Claim","Quantum PoW Claim")) and
          .qq_shadow_pow_lineage_schema=="1" and
          .qq_shadow_pow_lineage_family==$m.component.generation_fingerprint and
          (.qq_shadow_pow_lineage_root|hex64) and
          (.qq_shadow_pow_lineage_ordinal|type)=="string" and
          (.qq_shadow_pow_lineage_ordinal|test("^[0-9]+$")) and
          (.qq_shadow_pow_created_tip|hex64) and .abandoned==false and
          (.qq_shadow_pow_cleanup_for?==null) and
          (.qq_shadow_pow_resolution_schema?==null) and
          (.qq_shadow_pow_resolution_origin?==null) and
          (.qq_shadow_pow_resolution_anchor_txid?==null));
      def payout_ok($r):
        ($r.blockhash|hex64) and ($r.source_claim_txid|hex64) and
        $r.getblock_response==null and
        ($r.getshadowtransaction_response|type)=="object" and
        ($r.wallet_rows|length)>=1 and all($r.wallet_rows[];
          .qq_synthetic_goldrush_payout=="1" and
          (.qq_synthetic_goldrush_payout_stale?==null) and .generated==true and
          (.category|IN("generate","immature")) and .abandoned==false and
          .blockhash==$r.blockhash and (.qq_shadow_pow_cleanup_for?==null) and
          (.qq_shadow_pow_resolution_schema?==null)) and
        ($r.getshadowtransaction_response) as $s |
        $s.schema=="blackcoin.shadow.transaction.v1" and $s.synthetic==true and
        $s.merkle_included==false and $s.synthetic_txid==$r.txid and $s.mode=="pow" and
        $s.base_anchor.blockhash==$r.blockhash and $s.address==$payout[0].address and
        $s.status!="spent" and $s.pow_claim_source.input_bound==true and
        ($s.pow_claim_source.disposition|
          IN("winner","reimbursed_loser","reimbursed_late")) and
        $s.pow_claim_source.txid==$r.source_claim_txid and
        ($r.recovery_matches|length)==1 and
        ($r.recovery_matches[0]) as $m |
        $m.node.txid==$r.source_claim_txid and $m.node.kind=="claim" and
        $m.node.provenance=="explicit_authored" and $m.node.wallet_authored==true and
        $m.node.expected_shape==true and $m.node.lineage_metadata_present==true and
        $m.node.lineage_metadata_valid==true and $m.node.proof_origin_bound==true and
        $m.node.proof_input_bound==true and $m.node.expired_locally_retired==false and
        $m.node.abandoned==false and
        $m.node.resolution_metadata_valid==false and
        $m.node.resolution_relay_authorized==false and
        $m.component.anchor_authenticated==true and
        $m.component.all_claims_explicitly_provenanced==true and
        $m.component.all_claims_zero_payment_retirable==false and
        $m.component.all_claims_expired_locally_retired==false and
        ($m.component.generation_fingerprint|hex64) and
        $m.component.generation_fingerprint !=
          "0000000000000000000000000000000000000000000000000000000000000000" and
        ($m.component.claim_txids|index($r.source_claim_txid))!=null and
        ($m.component.resolution_txids|index($r.source_claim_txid))==null and
        ($m.component.ordinary_or_mixed_txids|index($r.source_claim_txid))==null;
      def computed_classification($r):
        if coinstake_ok($r) then
          {txid:$r.txid,class:"confirmed_coinstake",blockhash:$r.blockhash}
        elif claim_ok($r) then
          {txid:$r.txid,class:"authenticated_qq_claim"}
        elif payout_ok($r) then
          {txid:$r.txid,class:"authenticated_qq_claim_payout",blockhash:$r.blockhash,
            source_claim_txid:$r.source_claim_txid}
        else error("unclassifiable Phase-B wallet delta record") end;
      ($baseline[0]|map(.txid)|unique) as $old |
      ($final[0]|map(.txid)|unique) as $current |
      ($current|map(select(. as $txid | ($old|index($txid)|not)))) as $new |
      ($old|map(select(. as $txid | ($current|index($txid)|not)))) as $removed |
      ($raw[0]) as $r | ($delta[0]) as $d |
      ($r|keys|sort)==(["baseline_wallet_transactions_sha256","complete",
        "final_wallet_transactions_sha256","records","recovery_inventory_sha256",
        "schema"]|sort) and
      $r.schema==1 and $r.complete==true and
      $r.baseline_wallet_transactions_sha256==$baseline_sha and
      $r.final_wallet_transactions_sha256==$final_sha and
      $r.recovery_inventory_sha256==$recovery_sha and
      ($r.records|type)=="array" and ($r.records|length)==($new|length) and
      ($r.records|map(.txid))==$new and
      ($r.records|map(.txid)|unique|length)==($r.records|length) and
      all($r.records[];
        (keys|sort)==(["blockhash","class","getblock_response",
          "getshadowtransaction_response","recovery_matches","source_claim_txid",
          "txid","wallet_rows"]|sort) and
        (.txid|hex64) and .wallet_rows==wallet_rows(.txid) and
        (if .class=="authenticated_qq_claim_payout" then
           .recovery_matches==recovery_matches(.source_claim_txid)
         else .recovery_matches==recovery_matches(.txid) end) and
        ([coinstake_ok(.),claim_ok(.),payout_ok(.)]|map(select(.))|length)==1 and
        .class==(computed_classification(.)|.class)) and
      ($d|keys|sort)==(["allowed_classes","baseline_txids","classifications","complete",
        "new_txids","raw_evidence_sha256","rejected_txids","removed_txids","schema"]|sort) and
      $d.schema==1 and $d.baseline_txids==$old and $d.new_txids==$new and
      $removed==[] and $d.removed_txids==$removed and
      $d.raw_evidence_sha256==$raw_sha and $d.complete==true and $d.rejected_txids==[] and
      $d.allowed_classes==["confirmed_coinstake","authenticated_qq_claim",
        "authenticated_qq_claim_payout"] and
      $d.classifications==($r.records|map(computed_classification(.)))
    ' >/dev/null || die 'Phase-B raw wallet-delta structure/classification failed'
    # The raw file hash is supplied separately so jq cannot confuse a canonical JSON
    # reserialization with the exact sealed bytes that the producer and envelopes bind.
    jq -e -n \
        --arg raw_sha "$(sha_of "$root/phase-b-wallet-delta-raw.json")" \
        --slurpfile baseline "$root/baseline-wallet-transactions.json" \
        --slurpfile final "$root/candidate-final-wallet-transactions.json" \
        --slurpfile recovery "$root/candidate-final-recovery.json" \
        --slurpfile payout "$root/baseline-payout-address.json" \
        --slurpfile raw "$root/phase-b-wallet-delta-raw.json" \
        --slurpfile delta "$root/phase-b-wallet-delta.json" '
      def hex64: type=="string" and test("^[0-9a-f]{64}$");
      def recovery_matches($txid):
        [$recovery[0].component_details[] as $component |
          $component.nodes[] | select(.txid==$txid) | {component:$component,node:.}];
      def wallet_rows($txid): [$final[0][] | select(.txid==$txid)];
      def coinstake_ok($r):
        ($r.blockhash|hex64) and $r.source_claim_txid==null and
        $r.getshadowtransaction_response==null and $r.recovery_matches==[] and
        ($r.wallet_rows|length)>=1 and all($r.wallet_rows[];
          .generated==true and (.category|IN("generate","immature","orphan")) and
          .abandoned==false and .blockhash==$r.blockhash and
          (.qq_shadow_pow_cleanup_for?==null) and
          (.qq_shadow_pow_resolution_schema?==null) and
          (.qq_synthetic_goldrush_payout?==null) and
          (.qq_shadow_pow_authored?==null)) and
        ($r.getblock_response|type)=="object" and
        $r.getblock_response.hash==$r.blockhash and $r.getblock_response.confirmations>0 and
        ($r.getblock_response.tx|type)=="array" and ($r.getblock_response.tx|length)>=2 and
        $r.getblock_response.tx[0]!=$r.txid and $r.getblock_response.tx[1]==$r.txid;
      def claim_ok($r):
        $r.blockhash==null and $r.source_claim_txid==null and
        $r.getblock_response==null and $r.getshadowtransaction_response==null and
        ($r.recovery_matches|length)==1 and ($r.recovery_matches[0]) as $m |
        $m.node.txid==$r.txid and $m.node.kind=="claim" and
        $m.node.provenance=="explicit_authored" and $m.node.wallet_authored==true and
        $m.node.expected_shape==true and $m.node.lineage_metadata_present==true and
        $m.node.lineage_metadata_valid==true and $m.node.proof_origin_bound==true and
        $m.node.proof_input_bound==true and $m.node.expired_locally_retired==false and
        $m.node.abandoned==false and
        $m.node.resolution_metadata_valid==false and $m.node.resolution_relay_authorized==false and
        $m.component.anchor_authenticated==true and
        $m.component.all_claims_explicitly_provenanced==true and
        $m.component.all_claims_zero_payment_retirable==false and
        $m.component.all_claims_expired_locally_retired==false and
        ($m.component.generation_fingerprint|hex64) and
        $m.component.generation_fingerprint !=
          "0000000000000000000000000000000000000000000000000000000000000000" and
        ($m.component.claim_txids|index($r.txid))!=null and
        ($m.component.resolution_txids|index($r.txid))==null and
        ($m.component.ordinary_or_mixed_txids|index($r.txid))==null and
        ($r.wallet_rows|length)>=1 and all($r.wallet_rows[];
          .category=="send" and .qq_shadow_pow_authored=="1" and
          (.comment|IN("Quantum Quasar built-in shadow PoW claim",
            "Blackcoin shadow PoW claim","PoW Claim","Quantum PoW Claim")) and
          .qq_shadow_pow_lineage_schema=="1" and
          .qq_shadow_pow_lineage_family==$m.component.generation_fingerprint and
          (.qq_shadow_pow_lineage_root|hex64) and
          (.qq_shadow_pow_lineage_ordinal|type)=="string" and
          (.qq_shadow_pow_lineage_ordinal|test("^[0-9]+$")) and
          (.qq_shadow_pow_created_tip|hex64) and .abandoned==false and
          (.qq_shadow_pow_cleanup_for?==null) and
          (.qq_shadow_pow_resolution_schema?==null) and
          (.qq_shadow_pow_resolution_origin?==null) and
          (.qq_shadow_pow_resolution_anchor_txid?==null));
      def payout_ok($r):
        ($r.blockhash|hex64) and ($r.source_claim_txid|hex64) and
        $r.getblock_response==null and ($r.getshadowtransaction_response|type)=="object" and
        ($r.wallet_rows|length)>=1 and all($r.wallet_rows[];
          .qq_synthetic_goldrush_payout=="1" and
          (.qq_synthetic_goldrush_payout_stale?==null) and .generated==true and
          (.category|IN("generate","immature")) and .abandoned==false and
          .blockhash==$r.blockhash and (.qq_shadow_pow_cleanup_for?==null) and
          (.qq_shadow_pow_resolution_schema?==null)) and
        ($r.getshadowtransaction_response) as $s |
        $s.schema=="blackcoin.shadow.transaction.v1" and $s.synthetic==true and
        $s.merkle_included==false and $s.synthetic_txid==$r.txid and $s.mode=="pow" and
        $s.base_anchor.blockhash==$r.blockhash and $s.address==$payout[0].address and
        $s.status!="spent" and $s.pow_claim_source.input_bound==true and
        ($s.pow_claim_source.disposition|IN("winner","reimbursed_loser","reimbursed_late")) and
        $s.pow_claim_source.txid==$r.source_claim_txid and
        ($r.recovery_matches|length)==1 and ($r.recovery_matches[0]) as $m |
        $m.node.txid==$r.source_claim_txid and $m.node.kind=="claim" and
        $m.node.provenance=="explicit_authored" and $m.node.wallet_authored==true and
        $m.node.expected_shape==true and $m.node.lineage_metadata_present==true and
        $m.node.lineage_metadata_valid==true and $m.node.proof_origin_bound==true and
        $m.node.proof_input_bound==true and $m.node.expired_locally_retired==false and
        $m.node.abandoned==false and
        $m.node.resolution_metadata_valid==false and
        $m.node.resolution_relay_authorized==false and
        $m.component.anchor_authenticated==true and
        $m.component.all_claims_explicitly_provenanced==true and
        $m.component.all_claims_zero_payment_retirable==false and
        $m.component.all_claims_expired_locally_retired==false and
        ($m.component.generation_fingerprint|hex64) and
        $m.component.generation_fingerprint !=
          "0000000000000000000000000000000000000000000000000000000000000000" and
        ($m.component.claim_txids|index($r.source_claim_txid))!=null and
        ($m.component.resolution_txids|index($r.source_claim_txid))==null and
        ($m.component.ordinary_or_mixed_txids|index($r.source_claim_txid))==null;
      def computed_classification($r):
        if coinstake_ok($r) then
          {txid:$r.txid,class:"confirmed_coinstake",blockhash:$r.blockhash}
        elif claim_ok($r) then {txid:$r.txid,class:"authenticated_qq_claim"}
        elif payout_ok($r) then
          {txid:$r.txid,class:"authenticated_qq_claim_payout",blockhash:$r.blockhash,
            source_claim_txid:$r.source_claim_txid}
        else error("unclassifiable Phase-B wallet delta record") end;
      ($baseline[0]|map(.txid)|unique) as $old |
      ($final[0]|map(.txid)|unique) as $current |
      ($current|map(select(. as $txid | ($old|index($txid)|not)))) as $new |
      ($old|map(select(. as $txid | ($current|index($txid)|not)))) as $removed |
      ($raw[0]) as $r | ($delta[0]) as $d |
      $d.raw_evidence_sha256==$raw_sha and $d.baseline_txids==$old and $d.new_txids==$new and
      $removed==[] and $d.removed_txids==$removed and
      $d.complete==true and $d.rejected_txids==[] and
      $d.allowed_classes==["confirmed_coinstake","authenticated_qq_claim",
        "authenticated_qq_claim_payout"] and
      $d.classifications==($r.records|map(computed_classification(.)))
    ' >/dev/null || die 'Phase-B wallet delta is not independently reproducible from raw RPC evidence'
}

verify_phase_b_final()
{
    local root="$1" phase_a_sha marker nonce phase_a_nonce candidate_id mode name expected
    local phase_a_manifest_entry package_sha phase_a_script_sha script_sha verifier_sha contract_sha
    local policy_sha metrics_sha baseline_quantum_count final_quantum_count
    local authority_names
    secure_root "$root"
    verify_full_seal "$root"
    require_files "$root" RESULT.json PROMOTED_NO_REWIND.json phase-a-RESULT.json \
        phase-a-SHA256SUMS phase-a-unlock-helper-audit.json phase-a-REWIND_SAFE.json \
        phase-a-snapshot-set.json phase-a-snapshot-absence-proof.json \
        phase-a-candidate-loaded-image.json phase-a-candidate-bundle-manifest.json \
        phase-a-candidate-oci-identity.json phase-a-candidate-binary-sha256sums.txt \
        phase-a-baseline-runtime-identity.json phase-a-candidate-invocation-restart.json \
        phase-a-base-catchup-proof.json phase-a-guard-source-identity.json \
        phase-a-maintenance-marker-activated.json phase-a-tooling-identity.json \
        phase-a-base-quarantine-stop-authority.json \
        phase-a-baseline-restored-container.json \
        phase-a-authority-receipt.json storage-absence-before-marker.json \
        storage-absence-after-marker.json storage-absence-before-launch.json \
        phase-b-tooling-identity.json baseline-docker-runtime.json baseline-precondition.json \
        baseline-cutover-stop.json \
        candidate-created-stopped.json candidate-final-container.json \
        candidate-invocation.json candidate-chain-wallet-synchronized.json \
        baseline-live-datasets.json candidate-final-live-datasets.json \
        baseline-chain.json baseline-chain-after.json baseline-network.json \
        baseline-wallet.json baseline-staking.json baseline-pow.json baseline-recovery.json \
        baseline-quantum.json baseline-loaded-wallets.json baseline-payout-address.json \
        baseline-wallet-transactions.json candidate-final-wallet-transactions.json \
        baseline-resolution-txids.json phase-b-progress.json PRE_RESULT_SHA256SUMS \
        candidate-final-chain.json candidate-final-network.json candidate-final-wallet.json \
        candidate-final-staking.json candidate-final-pow.json candidate-final-recovery.json \
        candidate-final-quantum.json candidate-final-loaded-wallets.json \
        candidate-final-chain-after.json candidate-final-resolution-txids.json \
        phase-b-wallet-delta.json phase-b-wallet-delta-raw.json \
        phase-b-final-envelope.json rpc-methods.log
    phase_a_sha=$(sha_of "$root/phase-a-RESULT.json")
    hotfix_phase_a_result_file_is_valid "$root/phase-a-RESULT.json" ||
        die 'copied Phase-A result failed'
    phase_a_nonce=$(jq -er '.run_nonce' "$root/phase-a-RESULT.json") ||
        die 'copied Phase-A nonce absent'
    hotfix_rewind_safe_file_is_valid "$root/phase-a-REWIND_SAFE.json" "$phase_a_nonce" ||
        die 'copied Phase-A REWIND_SAFE failed'
    hotfix_snapshot_set_file_is_valid "$root/phase-a-snapshot-set.json" "$phase_a_nonce" ||
        die 'copied Phase-A snapshot set failed'
    hotfix_snapshot_absence_file_is_valid "$root/phase-a-snapshot-absence-proof.json" \
        "$phase_a_nonce" || die 'copied Phase-A snapshot absence failed'
    [[ "$(jq -er '.snapshot_set_sha256' "$root/phase-a-snapshot-absence-proof.json")" == \
       "$(sha_of "$root/phase-a-snapshot-set.json")" ]] ||
        die 'copied Phase-A absence/set binding failed'
    authority_names='["SHA256SUMS","RESULT.json","REWIND_SAFE.json","snapshot-set.json","snapshot-absence-proof.json","candidate-loaded-image.json","candidate-bundle-manifest.json","candidate-oci-identity.json","candidate-binary-sha256sums.txt","baseline-runtime-identity.json","candidate-invocation-restart.json","base-catchup-proof.json","guard-source-identity.json","maintenance-marker-activated.json","unlock-helper-audit.json","tooling-identity.json","base-quarantine-stop-authority.json","baseline-restored-container.json"]'
    manifest_names_are_safe "$root/phase-a-SHA256SUMS" ||
        die 'copied Phase-A manifest contains unsafe or duplicate names'
    jq -e --arg result "$phase_a_sha" --arg nonce "$phase_a_nonce" \
        --arg image "$(jq -er '.candidate_image_id' "$root/phase-a-REWIND_SAFE.json")" \
        --arg manifest "$(jq -er '.candidate_manifest_digest' "$root/phase-a-REWIND_SAFE.json")" \
        --arg source_manifest "$(sha_of "$root/phase-a-SHA256SUMS")" \
        --arg maintenance "$(sha_of "$root/phase-a-maintenance-marker-activated.json")" \
        --argjson expected_names "$authority_names" \
        --argjson rewind "$(<"$root/phase-a-REWIND_SAFE.json")" '
      (keys | sort) == (["all_copies_manifest_bound","candidate_blackcoin_qt_sha256",
        "candidate_image_id","candidate_image_ref","candidate_manifest_digest",
        "compose_sha256","copied_under_all_four_locks","files","maintenance_marker_sha256",
        "phase_a_result_sha256","phase_a_run_nonce","schema","source_manifest_sha256",
        "source_reverified_after_copy","source_reverified_immediately_before_copy",
        "tooling_commit"] | sort) and
      .schema==1 and .phase_a_result_sha256==$result and .phase_a_run_nonce==$nonce and
      .candidate_image_ref==($rewind.candidate_image_ref) and
      .candidate_image_id==$image and .candidate_manifest_digest==$manifest and
      .candidate_blackcoin_qt_sha256==($rewind.candidate_blackcoin_qt_sha256) and
      .compose_sha256==($rewind.compose_sha256) and
      .tooling_commit==($rewind.tooling_commit) and
      .source_manifest_sha256==$source_manifest and .maintenance_marker_sha256==$maintenance and
      .copied_under_all_four_locks==true and
      .source_reverified_immediately_before_copy==true and (.files|type)=="object"
      and .source_reverified_after_copy==true and .all_copies_manifest_bound==true and
      (.files|keys|sort)==($expected_names|sort)
    ' "$root/phase-a-authority-receipt.json" >/dev/null ||
        die 'Phase-A authority-copy receipt failed'
    while IFS= read -r name; do
        expected=$(jq -er --arg name "$name" '.files[$name]' \
            "$root/phase-a-authority-receipt.json") || die "authority hash absent: $name"
        [[ "$expected" == "$(sha_of "$root/phase-a-$name")" ]] ||
            die "authority copy differs: $name"
        if [[ "$name" != SHA256SUMS ]]; then
            phase_a_manifest_entry=$(awk -v wanted="$name" '
              NF == 2 && $1 ~ /^[0-9a-f]{64}$/ {
                path=$2; sub(/^\*/, "", path); sub(/^\.\//, "", path)
                if (path == wanted) print $1
              }
            ' "$root/phase-a-SHA256SUMS") || die "cannot read Phase-A manifest: $name"
            [[ "$phase_a_manifest_entry" =~ ^[0-9a-f]{64}$ &&
               "$phase_a_manifest_entry" == "$expected" ]] ||
                die "authority copy is not uniquely bound by Phase-A manifest: $name"
        fi
    done < <(jq -nr --argjson names "$authority_names" '$names[]')
    [[ "$(jq -er '.phase_a_result_sha256' "$root/phase-a-authority-receipt.json")" == \
       "$(sha_of "$root/phase-a-RESULT.json")" ]] ||
        die 'authority receipt result hash differs from copied result bytes'
    marker="$root/PROMOTED_NO_REWIND.json"
    hotfix_promoted_marker_file_is_valid "$marker" "$phase_a_sha" ||
        die 'promotion marker failed'
    nonce=$(jq -er '.promotion_nonce' "$marker") || die 'promotion nonce absent'
    candidate_id=$(jq -er '.candidate_image_id' "$root/phase-a-REWIND_SAFE.json") ||
        die 'Phase-A candidate image identity absent'
    package_sha=$(sha_of "$PACKAGE_ROOT/SHA256SUMS")
    phase_a_script_sha=$(sha_of \
        "$PACKAGE_ROOT/node27-v30.1.4-hotfix-candidate.no-recovery-spend.sh")
    script_sha=$(sha_of "$PACKAGE_ROOT/node27-v30.1.4-hotfix-candidate.promote-no-data-rewind.sh")
    verifier_sha=$(sha_of "$PACKAGE_ROOT/verify-evidence.sh")
    contract_sha=$(sha_of "$PACKAGE_ROOT/lib/typed_contract.sh")
    (cd "$PACKAGE_ROOT" && sha256sum --strict -c SHA256SUMS >/dev/null) ||
        die 'Phase-B package integrity seal does not validate exact tooling bytes'
    hotfix_phase_a_tooling_identity_file_is_valid "$root/phase-a-tooling-identity.json" \
        "$(jq -er '.tooling_commit' "$root/phase-a-REWIND_SAFE.json")" \
        "$package_sha" "$phase_a_script_sha" "$script_sha" "$verifier_sha" "$contract_sha" ||
        die 'copied Phase-A tooling identity differs from the current sealed package'
    jq -e -n --slurpfile manifest "$root/phase-a-candidate-bundle-manifest.json" \
        --slurpfile identity "$root/phase-a-tooling-identity.json" '
      ($manifest[0].build.tooling_commit | type)=="string" and
      ($manifest[0].build.tooling_commit | test("^[0-9a-f]{40}$")) and
      $manifest[0].build.workflow_definition_commit==$manifest[0].build.tooling_commit and
      $identity[0].tooling_commit==$manifest[0].build.tooling_commit
    ' >/dev/null || die 'copied Phase-A tooling commit lacks sealed manifest authority'
    [[ "$(sha_of "$root/phase-a-tooling-identity.json")" == \
         "$(jq -er '.phase_a_tooling_identity_sha256' "$root/phase-a-REWIND_SAFE.json")" &&
       "$(sha_of "$root/phase-a-tooling-identity.json")" == \
         "$(jq -er '.phase_a_tooling_identity_sha256' "$root/phase-a-RESULT.json")" ]] ||
        die 'copied Phase-A tooling identity hash is not certificate/result bound'
    hotfix_phase_a_stable_stop_file_is_valid \
        "$root/phase-a-base-quarantine-stop-authority.json" \
        base-quarantine-to-baseline "$IMMUTABLE_V3014_IMAGE_ID" \
        "$IMMUTABLE_V3014_IMAGE_REF" ||
        die 'copied Phase-A base stable-stop authority failed'
    [[ "$(sha_of "$root/phase-a-base-quarantine-stop-authority.json")" == \
       "$(jq -er '.base_quarantine_stop_authority_sha256' "$root/phase-a-RESULT.json")" &&
       "$(sha_of "$root/phase-a-baseline-restored-container.json")" == \
       "$(jq -er '.baseline_restored_container_sha256' "$root/phase-a-RESULT.json")" ]] ||
        die 'copied Phase-A result does not bind base stop/restored runtime evidence'
    jq -e -n --arg id "$IMMUTABLE_V3014_IMAGE_ID" --arg ref "$IMMUTABLE_V3014_IMAGE_REF" \
        --slurpfile runtime "$root/phase-a-baseline-runtime-identity.json" \
        --slurpfile restored "$root/phase-a-baseline-restored-container.json" '
      $restored[0].schema==1 and $restored[0].image_id==$id and $restored[0].image_ref==$ref and
      $restored[0].running==true and
      $restored[0].mounts_sha256==$runtime[0].mounts_sha256 and
      $restored[0].network_sha256==$runtime[0].network_sha256 and
      $restored[0].restart_policy==$runtime[0].restart_policy
    ' >/dev/null || die 'copied Phase-A restored baseline runtime is inconsistent'
    jq -e --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" \
        --arg tooling "$(jq -er '.tooling_commit' "$root/phase-a-REWIND_SAFE.json")" \
        --arg package "$package_sha" --arg script "$script_sha" \
        --arg verifier "$verifier_sha" --arg contract "$contract_sha" '
      (keys|sort)==(["candidate_source_sha","exact_bytes_recorded_before_irreversible_marker",
        "package_sha256sums_sha256","phase_b_script_sha256","schema","tooling_commit",
        "typed_contract_sha256","verifier_sha256"]|sort) and
      .schema==1 and .candidate_source_sha==$source and .tooling_commit==$tooling and
      .package_sha256sums_sha256==$package and .phase_b_script_sha256==$script and
      .verifier_sha256==$verifier and .typed_contract_sha256==$contract and
      .exact_bytes_recorded_before_irreversible_marker==true
    ' "$root/phase-b-tooling-identity.json" >/dev/null || die 'Phase-B tooling identity failed'
    [[ "$(jq -er '.phase_a_evidence_sha256sums_sha256' "$marker")" == \
         "$(sha_of "$root/phase-a-SHA256SUMS")" &&
       "$(jq -er '.phase_a_run_nonce' "$marker")" == "$phase_a_nonce" &&
       "$(jq -er '.candidate_image_ref' "$marker")" == \
         "$(jq -er '.candidate_image_ref' "$root/phase-a-REWIND_SAFE.json")" &&
       "$(jq -er '.candidate_image_id' "$marker")" == "$candidate_id" &&
       "$(jq -er '.candidate_manifest_digest' "$marker")" == \
         "$(jq -er '.candidate_manifest_digest' "$root/phase-a-REWIND_SAFE.json")" &&
       "$(jq -er '.phase_a_authority_receipt_sha256' "$marker")" == \
         "$(sha_of "$root/phase-a-authority-receipt.json")" &&
       "$(jq -er '.phase_a_rewind_safe_sha256' "$marker")" == \
         "$(sha_of "$root/phase-a-REWIND_SAFE.json")" &&
       "$(jq -er '.storage_absence_sha256' "$marker")" == \
         "$(sha_of "$root/storage-absence-before-marker.json")" &&
       "$(jq -er '.tooling_commit' "$marker")" == \
         "$(jq -er '.tooling_commit' "$root/phase-b-tooling-identity.json")" &&
       "$(jq -er '.phase_b_tooling_identity_sha256' "$marker")" == \
         "$(sha_of "$root/phase-b-tooling-identity.json")" &&
       "$(jq -er '.package_sha256sums_sha256' "$marker")" == "$package_sha" &&
       "$(jq -er '.phase_b_script_sha256' "$marker")" == "$script_sha" &&
       "$(jq -er '.verifier_sha256' "$marker")" == "$verifier_sha" &&
       "$(jq -er '.typed_contract_sha256' "$marker")" == "$contract_sha" ]] ||
        die 'promotion marker is not bound to copied Phase-A authority/storage proof'
    [[ "$(sha_of "$root/phase-a-unlock-helper-audit.json")" == \
       "$(jq -er '.helper_audit_sha256' "$root/phase-a-REWIND_SAFE.json")" ]] ||
        die 'copied unlock-helper audit is not Phase-A certified'
    for name in before-marker after-marker before-launch; do
        hotfix_storage_absence_receipt_file_is_valid \
            "$root/storage-absence-${name}.json" "$phase_a_sha" "$phase_a_nonce" "$name" ||
            die "storage absence receipt failed: $name"
        [[ "$(jq -er '.snapshot_set_sha256' "$root/storage-absence-${name}.json")" == \
           "$(sha_of "$root/phase-a-snapshot-set.json")" ]] ||
            die "storage receipt/set binding failed: $name"
        jq -e --slurpfile set "$root/phase-a-snapshot-set.json" '
          (.snapshots|map({dataset,snapshot,hold_tag})) ==
            ($set[0].snapshots|map({dataset,snapshot,hold_tag})) and
          (.snapshots|length)==4 and all(.snapshots[];
            .dataset_enumeration_succeeded==true and .snapshot_absent==true and
            .hold_absent==true)
        ' "$root/storage-absence-${name}.json" >/dev/null ||
            die "storage receipt does not enumerate exact Phase-A snapshot authority: $name"
    done
    if ! cmp -s <(jq -cS '.snapshots' "$root/storage-absence-before-marker.json") \
         <(jq -cS '.snapshots' "$root/storage-absence-after-marker.json") ||
       ! cmp -s <(jq -cS '.snapshots' "$root/storage-absence-before-marker.json") \
         <(jq -cS '.snapshots' "$root/storage-absence-before-launch.json"); then
        die 'three storage receipts do not describe the same absent snapshot/hold set'
    fi
    jq -e --arg id "$IMMUTABLE_V3014_IMAGE_ID" \
        --arg ref "$IMMUTABLE_V3014_IMAGE_REF" '
      (keys|sort)==(["container_id","image_id","image_ref","restart_policy","running","schema"]|sort) and
      .schema==1 and .image_id==$id and .image_ref==$ref and .running==true and
      (.container_id|test("^[0-9a-f]{64}$")) and (.restart_policy|type)=="object"
    ' "$root/baseline-docker-runtime.json" >/dev/null || die 'baseline Docker identity failed'
    hotfix_phase_b_cutover_stop_file_is_valid "$root/baseline-cutover-stop.json" ||
        die 'baseline cutover stop evidence failed'
    jq -e -n --slurpfile baseline "$root/baseline-docker-runtime.json" \
        --slurpfile cutover "$root/baseline-cutover-stop.json" '
      $cutover[0].container_id==$baseline[0].container_id and
      $cutover[0].image_id==$baseline[0].image_id and
      $cutover[0].image_ref==$baseline[0].image_ref and
      $cutover[0].original_restart_policy==$baseline[0].restart_policy
    ' >/dev/null || die 'baseline cutover stop does not bind the exact pre-promotion runtime'
    jq -e -n --slurpfile phase_a "$root/phase-a-baseline-runtime-identity.json" \
        --slurpfile baseline "$root/baseline-docker-runtime.json" \
        --slurpfile invocation "$root/candidate-invocation.json" '
      $invocation[0].config_sha256==$phase_a[0].blackcoin_conf_sha256 and
      $invocation[0].mounts_sha256==$phase_a[0].mounts_sha256 and
      $invocation[0].network_sha256==$phase_a[0].network_sha256 and
      $baseline[0].restart_policy==$phase_a[0].restart_policy
    ' >/dev/null || die 'Phase-B invocation differs from Phase-A baseline storage/config identity'
    hotfix_invocation_file_is_valid "$root/candidate-invocation.json" B \
        "$candidate_id" "$nonce" ||
        die 'Phase-B invocation failed'
    [[ "$(jq -er '.pid1_exe_sha256' "$root/candidate-invocation.json")" == \
       "$(jq -er '.candidate_blackcoin_qt_sha256' "$root/phase-a-REWIND_SAFE.json")" ]] ||
        die 'Phase-B PID1 differs from Phase-A candidate binary'
    jq -e --slurpfile invocation "$root/candidate-invocation.json" \
        --slurpfile baseline "$root/baseline-docker-runtime.json" '
      .image_id==$invocation[0].image_id and .running==false and .user=="blackcoin" and
      .working_dir=="/home/blackcoin" and .mounts_sha256==$invocation[0].mounts_sha256 and
      .network_sha256==$invocation[0].network_sha256 and
      .restart_policy==$baseline[0].restart_policy
    ' "$root/candidate-created-stopped.json" >/dev/null ||
        die 'created-stopped candidate is not bound to invocation/baseline'
    jq -e '.synchronized==true and .chain.initialblockdownload==false and
      .chain.blocks==.chain.headers and .wallet.unlocked_until==0 and .wallet.scanning==false and
      .recovery.wallet_tip_matches==true and .recovery.active_tip==.chain.bestblockhash and
      .recovery.wallet_processed_tip==.chain.bestblockhash' \
      "$root/candidate-chain-wallet-synchronized.json" >/dev/null ||
        die 'locked chain/wallet synchronization failed'
    jq -e -n --slurpfile pre "$root/baseline-precondition.json" \
        --slurpfile chain "$root/baseline-chain.json" \
        --slurpfile chain_after "$root/baseline-chain-after.json" \
        --slurpfile network "$root/baseline-network.json" \
        --slurpfile wallet "$root/baseline-wallet.json" \
        --slurpfile staking "$root/baseline-staking.json" \
        --slurpfile pow "$root/baseline-pow.json" \
        --slurpfile recovery "$root/baseline-recovery.json" \
        --slurpfile wallets "$root/baseline-loaded-wallets.json" \
        --slurpfile payout "$root/baseline-payout-address.json" '
      ($pre[0]) as $p | ($chain[0]) as $c |
      ($p|keys|sort)==(["exact_loaded_wallets","irreversible_marker_allowed",
        "main_chain_ready","observed_epoch","p2p_ready","payout_address","payout_owned",
        "pending_recovery_actions_zero","quantum_key_count","recovery_database_unambiguous",
        "recovery_metrics_sha256","recovery_policy_nonautomatic","recovery_policy_sha256",
        "schema","stable_tip","staking_active","wallet_normally_unlocked"]|sort) and
      $p.schema==1 and $p.main_chain_ready==true and $p.p2p_ready==true and
      $p.wallet_normally_unlocked==true and $p.exact_loaded_wallets==[""] and
      $p.staking_active==true and $p.payout_owned==true and
      $p.recovery_database_unambiguous==true and $p.recovery_policy_nonautomatic==true and
      $p.pending_recovery_actions_zero==true and $p.irreversible_marker_allowed==true and
      $c.chain=="main" and $c.initialblockdownload==false and $c.blocks==$c.headers and
      $c.bestblockhash==$chain_after[0].bestblockhash and $c.chainwork==$chain_after[0].chainwork and
      $c.blocks==$chain_after[0].blocks and $p.stable_tip==$c.bestblockhash and
      $network[0].networkactive==true and $network[0].connections_out>=3 and
      $wallet[0].walletname=="" and $wallet[0].scanning==false and
      $wallet[0].private_keys_enabled==true and $wallet[0].unlocked_staking_only==false and
      $wallet[0].unlocked_until>$p.observed_epoch and
      $staking[0].enabled==true and $staking[0].staking==true and
      $staking[0].worker_running==true and $staking[0].weight>0 and
      $p.payout_address==$pow[0].payout_address and
      $p.payout_address==$payout[0].address and $payout[0].ismine==true and
      $wallets[0]==[""] and $recovery[0].database_outcome_ambiguous==false and
      $recovery[0].pending_manual_resolutions==0 and
      $recovery[0].pending_automatic_resolutions==0 and
      $recovery[0].policy_authoritative==true and
      $recovery[0].policy.automatic_authorized==false
    ' >/dev/null || die 'baseline precondition is not reproduced by its raw RPC envelope'
    policy_sha=$(jq -cS '{policy_authoritative,policy_state_status,policy}' \
        "$root/baseline-recovery.json" | sha256sum | awk '{print $1}')
    metrics_sha=$(jq -cS '{pending_manual_resolutions,pending_automatic_resolutions,
      confirmed_manual_resolutions,confirmed_automatic_resolutions,
      confirmed_resolution_fees,automatic_actions_in_window,
      automatic_fee_exposure_in_window,reconciled_descendant_claims,claims_recycled}' \
        "$root/baseline-recovery.json" | sha256sum | awk '{print $1}')
    [[ "$policy_sha" == "$(jq -er '.recovery_policy_sha256' "$root/baseline-precondition.json")" &&
       "$metrics_sha" == "$(jq -er '.recovery_metrics_sha256' "$root/baseline-precondition.json")" ]] ||
        die 'baseline precondition recovery hashes do not reproduce raw recovery state'
    baseline_quantum_count=$(jq -er 'if type=="array" then length
      elif (.keys?|type)=="array" then (.keys|length)
      elif (.inventory?|type)=="array" then (.inventory|length)
      elif (.total?|type)=="number" then .total else error("schema") end' \
        "$root/baseline-quantum.json") || die 'baseline quantum inventory schema failed'
    [[ "$baseline_quantum_count" == \
       "$(jq -er '.quantum_key_count' "$root/baseline-precondition.json")" ]] ||
        die 'baseline quantum count does not reproduce precondition'
    hotfix_phase_b_staking_json_is_active "$(<"$root/candidate-final-staking.json")" ||
        die 'Phase-B PoS proof failed'
    jq -e '.chain=="main" and .initialblockdownload==false and .blocks==.headers' \
      "$root/candidate-final-chain.json" >/dev/null || die 'Phase-B final chain failed'
    jq -e '.networkactive==true and .connections_out>=3' "$root/candidate-final-network.json" \
      >/dev/null || die 'Phase-B final network failed'
    jq -e '.scanning==false and .unlocked_staking_only==false and .unlocked_until>0' \
      "$root/candidate-final-wallet.json" >/dev/null || die 'Phase-B final wallet failed'
    jq -e '.database_outcome_ambiguous==false and .chain_ready==true and
      .wallet_tip_matches==true' "$root/candidate-final-recovery.json" >/dev/null ||
        die 'Phase-B final recovery state failed'
    mode=$([[ "$(jq -er '.enabled' "$root/baseline-pow.json")" == true ]] && printf active || printf off)
    hotfix_candidate_pow_json_is_valid "$(<"$root/candidate-final-pow.json")" \
        "$mode" ||
        die 'Phase-B typed PoW proof failed'
    hotfix_phase_b_progress_file_is_valid "$root/phase-b-progress.json" "$nonce" "$mode" ||
        die 'Phase-B three-tip progress failed'
    [[ "$(jq -er '.payout_address' "$root/baseline-pow.json")" == \
         "$(jq -er '.payout_address' "$root/candidate-final-pow.json")" &&
       "$(sha_of "$root/baseline-quantum.json")" == \
         "$(sha_of "$root/candidate-final-quantum.json")" &&
       "$(jq -er '.confirmed_resolution_fees' "$root/baseline-recovery.json")" == \
         "$(jq -er '.confirmed_resolution_fees' "$root/candidate-final-recovery.json")" &&
       "$(sha_of "$root/baseline-resolution-txids.json")" == \
         "$(sha_of "$root/candidate-final-resolution-txids.json")" ]] ||
        die 'Phase-B payout/key/recovery identity changed'
    final_quantum_count=$(jq -er 'if type=="array" then length
      elif (.keys?|type)=="array" then (.keys|length)
      elif (.inventory?|type)=="array" then (.inventory|length)
      elif (.total?|type)=="number" then .total else error("schema") end' \
        "$root/candidate-final-quantum.json") || die 'final quantum inventory schema failed'
    [[ "$final_quantum_count" == "$baseline_quantum_count" ]] ||
        die 'final quantum count differs from baseline'
    verify_phase_b_wallet_delta_raw_bindings "$root"
    jq -e -n --arg raw "$(sha_of "$root/phase-b-wallet-delta-raw.json")" \
        --slurpfile baseline "$root/baseline-wallet-transactions.json" \
        --slurpfile final "$root/candidate-final-wallet-transactions.json" \
        --slurpfile delta "$root/phase-b-wallet-delta.json" '
      ($baseline[0]|map(.txid)|unique) as $old |
      ($final[0]|map(.txid)|unique) as $current |
      ($current|map(select(. as $id|($old|index($id)|not)))) as $new |
      ($old|map(select(. as $id|($current|index($id)|not)))) as $removed |
      ($delta[0]) as $d |
      ($d|keys|sort)==(["allowed_classes","baseline_txids","classifications","complete",
        "new_txids","raw_evidence_sha256","rejected_txids","removed_txids","schema"]|sort) and
      $d.schema==1 and $d.baseline_txids==$old and $d.new_txids==$new and
      $removed==[] and $d.removed_txids==$removed and
      $d.raw_evidence_sha256==$raw and
      $d.complete==true and $d.rejected_txids==[] and
      $d.allowed_classes==["confirmed_coinstake","authenticated_qq_claim",
        "authenticated_qq_claim_payout"] and
      ($d.classifications|length)==($new|length) and
      ([ $d.classifications[].txid ]|sort)==($new|sort) and
      ([ $d.classifications[].txid ]|unique|length)==($new|length) and
      all($d.classifications[];
        (.class|IN("confirmed_coinstake","authenticated_qq_claim",
          "authenticated_qq_claim_payout")))
    ' >/dev/null ||
        die 'Phase-B wallet delta is not an exact complete raw-wallet differential'
    cmp -s "$root/baseline-live-datasets.json" "$root/candidate-final-live-datasets.json" ||
        die 'live dataset GUID/mount identity changed'
    jq -e '
      (keys|sort)==["datasets","schema"] and .schema==1 and
      (.datasets|length)==4 and
      [.datasets[].dataset]==["pulsar/Blackcoin_Blocks/node-data/node-27",
        "pulsar/Blackcoin_Blocks/node-data/node-27/blocks",
        "pulsar/Blackcoin_Blocks/node-data/node-27/indexes",
        "pulsar/Blackcoin_Blocks/alpha-chain-raw-clones-20260715T032403Z/node-27"] and
      [.datasets[].mount_path]==["/mnt/pulsar/Blackcoin_Blocks/node-data/node-27",
        "/mnt/pulsar/Blackcoin_Blocks/node-data/node-27/blocks",
        "/mnt/pulsar/Blackcoin_Blocks/node-data/node-27/indexes",
        "/mnt/pulsar/Blackcoin_Blocks/27/blocks"] and
      all(.datasets[]; (.guid|test("^[0-9]+$"))) and
      ([.datasets[].guid]|unique|length)==4
    ' "$root/candidate-final-live-datasets.json" >/dev/null ||
        die 'live dataset identity does not contain the exact four-dataset topology'
    jq -e -n --slurpfile container "$root/candidate-final-container.json" \
        --slurpfile invocation "$root/candidate-invocation.json" \
        --slurpfile marker "$marker" '
      ($container[0]) as $c | ($invocation[0]) as $i |
      ($c|keys|sort)==(["candidate_running_without_restart","candidate_source_sha",
        "config_sha256","container_id","entrypoint_body_sha256","identity_stable_across_two_samples",
        "image_id","image_ref","mounts_sha256","network_sha256","pid1_exe_sha256",
        "restart_policy","runtime_argv","runtime_argv_sha256","schema","stable_restart_count",
        "stable_started_at","start_gui_sha256","running_first","running_second"]|sort) and
      $c.schema==1 and $c.candidate_source_sha==$marker[0].candidate_source_sha and
      $c.image_id==$marker[0].candidate_image_id and $c.image_ref==$marker[0].candidate_image_ref and
      $c.container_id==$i.container_id and $c.stable_started_at==$i.container_started_at and
      $c.stable_restart_count==$i.container_restart_count and
      $c.pid1_exe_sha256==$i.pid1_exe_sha256 and
      $c.entrypoint_body_sha256==$i.entrypoint_body_sha256 and
      $c.start_gui_sha256==$i.observed_start_gui_sha256 and
      $c.runtime_argv==$i.runtime_argv and $c.runtime_argv_sha256==$i.runtime_argv_sha256 and
      $c.config_sha256==$i.config_sha256 and $c.mounts_sha256==$i.mounts_sha256 and
      $c.network_sha256==$i.network_sha256 and $c.restart_policy==$i.restart_policy and
      $c.running_first==true and $c.running_second==true and
      $c.identity_stable_across_two_samples==true and $c.candidate_running_without_restart==true
    ' >/dev/null || die 'final container identity is not exactly bound to launch/marker bytes'
    jq -e -n --slurpfile envelope "$root/phase-b-final-envelope.json" \
        --slurpfile chain "$root/candidate-final-chain.json" \
        --slurpfile chain_after "$root/candidate-final-chain-after.json" \
        --slurpfile network "$root/candidate-final-network.json" \
        --slurpfile wallet "$root/candidate-final-wallet.json" \
        --slurpfile staking "$root/candidate-final-staking.json" \
        --slurpfile pow "$root/candidate-final-pow.json" \
        --slurpfile recovery "$root/candidate-final-recovery.json" \
        --slurpfile wallets "$root/candidate-final-loaded-wallets.json" \
        --arg delta "$(sha_of "$root/phase-b-wallet-delta.json")" \
        --arg delta_raw "$(sha_of "$root/phase-b-wallet-delta-raw.json")" \
        --arg policy "$policy_sha" --arg metrics "$metrics_sha" '
      ($envelope[0]) as $e |
      ($e|keys|sort)==(["chain","chain_after","chain_before_after_identical",
        "chain_recovery_pow_tip_bound","exact_loaded_wallets","loaded_wallets","network",
        "observed_epoch","pow","pow_mode","recovery","recovery_counters_unchanged",
        "recovery_metrics_sha256","recovery_policy_sha256","recovery_txids_unchanged",
        "schema","stable_tip","staking","wallet","wallet_delta_fully_classified",
        "wallet_delta_raw_sha256","wallet_delta_sha256","wallet_unlock_current"]|sort) and
      $e.schema==1 and $e.chain_before_after_identical==true and
      $e.chain_recovery_pow_tip_bound==true and $e.wallet_unlock_current==true and
      $e.exact_loaded_wallets==[""] and $e.recovery_counters_unchanged==true and
      $e.recovery_txids_unchanged==true and $e.wallet_delta_fully_classified==true and
      $e.wallet_delta_sha256==$delta and $e.wallet_delta_raw_sha256==$delta_raw and
      $e.recovery_policy_sha256==$policy and
      $e.recovery_metrics_sha256==$metrics and $e.chain==$chain[0] and
      $e.chain_after==$chain_after[0] and $e.network==$network[0] and
      $e.wallet==$wallet[0] and $e.staking==$staking[0] and $e.pow==$pow[0] and
      $e.recovery==$recovery[0] and $e.loaded_wallets==$wallets[0] and
      $e.stable_tip==$chain[0].bestblockhash
    ' >/dev/null || die 'Phase-B final envelope does not exactly reproduce raw final evidence'
    verify_pre_result_seal "$root"
    hotfix_phase_b_result_file_is_valid "$root/RESULT.json" "$phase_a_sha" ||
        die 'Phase-B RESULT failed'
    [[ "$(sha_of "$marker")" == "$(jq -er '.marker_sha256' "$root/RESULT.json")" &&
       "$(sha_of "$root/candidate-invocation.json")" == \
         "$(jq -er '.invocation_sha256' "$root/RESULT.json")" &&
       "$(sha_of "$root/candidate-final-live-datasets.json")" == \
         "$(jq -er '.live_dataset_identity_sha256' "$root/RESULT.json")" &&
       "$(sha_of "$root/storage-absence-before-launch.json")" == \
         "$(jq -er '.storage_absence_recheck_sha256' "$root/RESULT.json")" &&
       "$(sha_of "$root/phase-b-progress.json")" == \
         "$(jq -er '.phase_b_progress_sha256' "$root/RESULT.json")" &&
       "$(sha_of "$root/candidate-final-container.json")" == \
         "$(jq -er '.final_container_sha256' "$root/RESULT.json")" &&
       "$(sha_of "$root/phase-b-final-envelope.json")" == \
         "$(jq -er '.final_envelope_sha256' "$root/RESULT.json")" &&
       "$(sha_of "$root/phase-b-wallet-delta.json")" == \
         "$(jq -er '.wallet_delta_sha256' "$root/RESULT.json")" &&
       "$(sha_of "$root/phase-b-wallet-delta-raw.json")" == \
         "$(jq -er '.wallet_delta_raw_sha256' "$root/RESULT.json")" &&
       "$(sha_of "$root/baseline-precondition.json")" == \
         "$(jq -er '.baseline_precondition_sha256' "$root/RESULT.json")" &&
       "$(sha_of "$root/baseline-cutover-stop.json")" == \
         "$(jq -er '.baseline_cutover_stop_sha256' "$root/RESULT.json")" &&
       "$(sha_of "$root/phase-b-tooling-identity.json")" == \
         "$(jq -er '.phase_b_tooling_identity_sha256' "$root/RESULT.json")" &&
       "$(jq -er '.package_sha256sums_sha256' "$root/RESULT.json")" == "$package_sha" &&
       "$(jq -er '.phase_b_script_sha256' "$root/RESULT.json")" == "$script_sha" &&
       "$(jq -er '.verifier_sha256' "$root/RESULT.json")" == "$verifier_sha" &&
       "$(jq -er '.typed_contract_sha256' "$root/RESULT.json")" == "$contract_sha" &&
       "$(jq -er '.baseline_recovery_policy_sha256' "$root/RESULT.json")" == "$policy_sha" &&
       "$(jq -er '.baseline_recovery_metrics_sha256' "$root/RESULT.json")" == "$metrics_sha" &&
       "$(sha_of "$root/PRE_RESULT_SHA256SUMS")" == \
         "$(jq -er '.pre_result_manifest_sha256' "$root/RESULT.json")" ]] ||
        die 'Phase-B RESULT evidence binding failed'
    jq -e --argjson manual "$(jq -er '.pending_manual_resolutions' "$root/baseline-recovery.json")" \
        --argjson automatic "$(jq -er '.pending_automatic_resolutions' "$root/baseline-recovery.json")" \
        --argjson exposure "$(jq -er '.automatic_fee_exposure_in_window' "$root/baseline-recovery.json")" \
        --argjson fee "$(jq -er '.confirmed_resolution_fees' "$root/baseline-recovery.json")" '
      .baseline_pending_manual_resolutions==$manual and
      .baseline_pending_automatic_resolutions==$automatic and
      .baseline_automatic_fee_exposure_in_window==$exposure and
      .baseline_confirmed_resolution_fees==$fee and
      .tooling_commit != null
    ' "$root/RESULT.json" >/dev/null || die 'Phase-B RESULT baseline scalars are not raw-bound'
    grep -Eq '^(createshadowpowclaimresolution|commitshadowpowclaimresolution|resolveshadowpowclaims|setpowclaimrecovery|sendrawtransaction|sendtoaddress|sendmany|fundrawtransaction|signrawtransaction.*|resendwallettransactions|forcerelay|abandontransaction|getnewaddress|getnewquantumaddress|setpowminingaddress|generate|generatetoaddress|submitblock|submitheader)(:.*)?$' \
        "$root/rpc-methods.log" && die 'forbidden Phase-B RPC observed'
    verify_full_seal "$root"
    secure_root "$root"
    printf 'Phase-B final evidence verified: %s\n' "$root"
}

main()
{
    local mode="${1:-}" root="${2:-}" input_root
    hotfix_candidate_identity_is_resolved ||
        die 'candidate source/release identity is unresolved or incoherent'
    [[ -n "$root" && $# == 2 ]] ||
        die 'usage: verify-evidence.sh {phase-a-pre-rewind|phase-a-final|phase-b-final} EVIDENCE_DIR'
    input_root="$root"
    input_path_has_no_symlink_component "$input_root" ||
        die 'evidence path contains a symlink or dot traversal component'
    root=$(CDPATH='' cd -P -- "$root" && pwd -P) || die 'cannot canonicalize evidence directory'
    case "$mode" in
        phase-a-pre-rewind) verify_phase_a_pre "$root" ;;
        phase-a-final) verify_phase_a_final "$root" ;;
        phase-b-final) verify_phase_b_final "$root" ;;
        *) die 'unknown verification mode' ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
