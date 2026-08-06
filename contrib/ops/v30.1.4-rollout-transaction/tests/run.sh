#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
export LC_ALL=C TZ=UTC

ROOT=$(cd "${BASH_SOURCE[0]%/*}/.." && pwd -P)
CANARY=$(realpath "$ROOT/../v30.1.4-canary/node27-v30.1.4-canary.no-spend.sh")
TMP=$(mktemp -d)
TMP=$(realpath "$TMP")
trap 'rm -rf -- "$TMP"' EXIT

(cd "${CANARY%/*}" && sha256sum --strict -c SHA256SUMS >/dev/null)
RESULTS="$TMP/results.txt"
: > "$RESULTS"
UPDATE_MANIFEST=${UPDATE_MANIFEST:-0}
[[ "$UPDATE_MANIFEST" == 0 || "$UPDATE_MANIFEST" == 1 ]] || {
    printf '%s\n' 'UPDATE_MANIFEST must be 0 or 1' >&2
    exit 64
}

pass()
{
    printf 'PASS %s\n' "$1"
    printf 'PASS %s\n' "$1" >> "$RESULTS"
}

function_body()
{
    local function_name="$1" file="$2"
    sed -n "/^${function_name}()$/,/^}$/p" "$file"
}

assert_order()
{
    local file="$1" pattern line previous=0
    shift
    for pattern in "$@"; do
        line=$(awk -v start="$previous" -v needle="$pattern" \
            'NR > start && index($0, needle) {print NR; exit}' "$file")
        [[ -n "$line" && "$line" -gt "$previous" ]] || return 1
        previous=$line
    done
}

assert_order_last()
{
    local file="$1" pattern line previous=0
    shift
    for pattern in "$@"; do
        line=$(grep -nF -- "$pattern" "$file" | tail -n 1 | cut -d: -f1)
        [[ -n "$line" && "$line" -gt "$previous" ]] || return 1
        previous=$line
    done
}

scripts=()
while IFS= read -r script; do scripts+=("$script"); done < <(
    find "$ROOT" -type f -name '*.sh' ! -path '*/tests/*' -print | sort
)
bash -n "${scripts[@]}"
pass bash-syntax

shellcheck -x -e SC1091,SC2034,SC2016 "${scripts[@]}"
pass shellcheck-actionable

awk '
  /^[[:space:]]*#/ || /^[[:space:]]*$/ {next}
  {waves++; if (NF < 1 || NF > 4) exit 1; for (i=1;i<=NF;i++) {
    if ($i !~ /^([12][0-9]|3[0-2]|[1-9])$/ || seen[$i]++) exit 1; nodes++
  }}
  END {exit !(waves >= 8 && nodes == 32 && seen[30] && seen[31] && seen[32])}
' "$ROOT/waves.txt"
grep -Fq "printf 'node%02d" "$ROOT/lib/common.sh"
grep -Fq "printf 'pia-vpn-%d" "$ROOT/lib/common.sh"
grep -Fq '@sha256:' "$ROOT/lib/common.sh"
pass wave-plan-and-mappings

function_body verify_all_data_domains "$ROOT/lib/data_rollback.sh" \
    > "$TMP/verify-all-data-domains"
(
    # shellcheck disable=SC1090
    source "$TMP/verify-all-data-domains"
    NODE_COUNT=1
    FLEET_ZFS_PARENT=pool
    OPS_PARENT="$TMP/rollback-operations"
    OPS_ROOT="$OPS_PARENT/v30.1.4-fleet-rollout"
    mkdir -p "$OPS_PARENT"
    data_domain_for() { printf '%s\n' 'fileset|pool'; }
    host_datadir_for() { printf '%s\n' "$TMP/data-$1"; }
    host_blocks_for() { printf '%s\n' "$TMP/raw-$1"; }
    FINDMNT_SOURCE=pool
    FINDMNT_EXPECT="$OPS_PARENT"
    findmnt()
    {
        [[ "$1" == -n && "$2" == -o && "$3" == SOURCE && "$4" == -T &&
           "$5" == "$FINDMNT_EXPECT" ]] || return 1
        printf '%s\n' "$FINDMNT_SOURCE"
    }

    verify_all_data_domains
    mkdir "$OPS_ROOT"
    FINDMNT_EXPECT="$OPS_ROOT"
    verify_all_data_domains
    rmdir "$OPS_ROOT"
    ln -s "$OPS_PARENT" "$OPS_ROOT"
    ! verify_all_data_domains
    rm "$OPS_ROOT"
    FINDMNT_EXPECT="$OPS_PARENT"
    FINDMNT_SOURCE=other-pool
    ! verify_all_data_domains
)
pass rollback-operations-root-absent-and-existing-domain-gates

function_body verify_legacy_rollback_readiness_all_nodes \
    "$ROOT/fleet_rollout.sh" > "$TMP/legacy-readiness-function"
(
    # shellcheck disable=SC1090
    source "$TMP/legacy-readiness-function"
    NODE_COUNT=6
    RUN_DIR="$TMP/legacy-readiness-run"
    ENABLE_GUARD_STARTS="$TMP/enable-guard-starts"
    COUNTS="$TMP/legacy-readiness-counts"
    mkdir -p "$RUN_DIR/baseline" "$COUNTS"
    node_padded() { printf '%02d\n' "$1"; }
    log() { :; }
    sleep() { :; }
    assert_unique_vpn_proofs() { return 0; }
    assert_empty_control_marker() { return 0; }
    verify_policy_legacy_runtime_gate()
    {
        local node="$1" file count
        [[ "$#" -eq 1 ]]
        file="$COUNTS/$node"
        count=$(cat "$file" 2>/dev/null || printf '0\n')
        count=$((count + 1))
        printf '%s\n' "$count" > "$file"
        [[ "$node" -ne 3 || "$count" -ge 3 ]]
    }

    verify_legacy_rollback_readiness_all_nodes
    for node in 1 2 4 5 6; do [[ "$(cat "$COUNTS/$node")" == 1 ]]; done
    [[ "$(cat "$COUNTS/3")" == 3 ]]

    rm -rf -- "$COUNTS"
    mkdir "$COUNTS"
    verify_policy_legacy_runtime_gate()
    {
        local node="$1" file count
        [[ "$#" -eq 1 ]]
        file="$COUNTS/$node"
        count=$(cat "$file" 2>/dev/null || printf '0\n')
        count=$((count + 1))
        printf '%s\n' "$count" > "$file"
        [[ "$node" -ne 4 ]]
    }
    ! verify_legacy_rollback_readiness_all_nodes
    for node in 1 2 3 5 6; do [[ "$(cat "$COUNTS/$node")" == 1 ]]; done
    [[ "$(cat "$COUNTS/4")" == 60 ]]
)
pass bounded-retry-only-failed-legacy-readiness-gate

function_body legacy_restore_counts "$ROOT/fleet_rollout.sh" \
    > "$TMP/legacy-restore-counts-function"
function_body verify_policy_runtime_node "$ROOT/fleet_rollout.sh" \
    > "$TMP/policy-runtime-node-function"
grep -Fq 'mining=$(wallet_rpc_for "$node" getpowmininginfo | jq -ceS .)' \
    "$TMP/legacy-restore-counts-function"
grep -Fq 'mode=$(_legacy_pow_snapshot_mode_json "$node" "$mining")' \
    "$TMP/legacy-restore-counts-function"
grep -Fq 'verify_policy_legacy_runtime_gate "$node"' \
    "$TMP/policy-runtime-node-function"
! grep -Fq 'baseline="$RUN_DIR/baseline/legacy-node-' \
    "$TMP/policy-runtime-node-function"
pass untouched-legacy-nodes-use-live-allowed-mode-not-stale-snapshot

{
    printf '%s\n' 'services:'
    for node in $(seq 1 32); do
        printf '  node%d:\n    image: registry.example/old:node%d\n    restart: on-failure:3\n' "$node" "$node"
    done
} > "$TMP/compose.yml"
digest='registry.example/blackcoin@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
awk -v targets='node1,node9,node10,node32' -v image="$digest" \
    -f "$ROOT/render_compose_images.awk" "$TMP/compose.yml" > "$TMP/compose.out.yml"
[[ "$(grep -Fc "image: $digest" "$TMP/compose.out.yml")" -eq 4 ]]
[[ "$(grep -Fc 'image: registry.example/old:' "$TMP/compose.out.yml")" -eq 28 ]]
! awk -v targets='node01' -v image="$digest" -f "$ROOT/render_compose_images.awk" \
    "$TMP/compose.yml" >/dev/null 2>&1
pass compose-renderer-positive-and-negative

jq -n '
  {schema:1,images:{old:{config_image:"registry.example/old:fixed",
    image_id:"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"}},
   nodes:(reduce range(1;33) as $n ({}; .[($n|tostring|if length==1 then "0"+. else . end)]="old"))}
' > "$TMP/policy.json"
image_id='sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'
"$ROOT/render_policy.sh" "$TMP/policy.json" "$TMP/policy.out.json" "$digest" "$image_id" 1 30 31 32
jq -e --arg ref "$digest" --arg id "$image_id" '
  .images.final3014 == {config_image:$ref,image_id:$id} and
  .nodes["01"] == "final3014" and .nodes["30"] == "final3014" and
  .nodes["31"] == "final3014" and .nodes["32"] == "final3014" and
  ([.nodes[] | select(. == "final3014")] | length) == 4
' "$TMP/policy.out.json" >/dev/null
! "$ROOT/render_policy.sh" "$TMP/policy.json" "$TMP/duplicate.json" "$digest" "$image_id" 1 1 \
    >/dev/null 2>&1
pass policy-renderer-positive-and-negative

cat > "$TMP/guard.sh" <<'EOF'
#!/usr/bin/env bash
EXPECTED_IMAGE_POLICY_SHA='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
printf '%s\n' "$EXPECTED_IMAGE_POLICY_SHA"
EOF
policy_sha=$(sha256sum "$TMP/policy.out.json" | awk '{print $1}')
"$ROOT/render_guard_pin.sh" "$TMP/guard.sh" "$TMP/guard.out.sh" "$policy_sha"
bash -n "$TMP/guard.out.sh"
[[ "$(grep -c "^EXPECTED_IMAGE_POLICY_SHA='$policy_sha'$" "$TMP/guard.out.sh")" -eq 1 ]]
pass guard-renderer

portable_package_integrity()
{
    local root="$1"
    [[ -z "$(find "$root" -type l -print -quit)" ]] &&
        cmp -s \
            <(cd "$root" && find . -type f ! -path './SHA256SUMS' -print | sort) \
            <(awk 'NF == 2 && $1 ~ /^[0-9a-f]{64}$/ {
                name=$2; sub(/^\\*/, "", name); sub(/^[.]\//, "", name); print "./" name
            }' "$root/SHA256SUMS" | sort) &&
        (cd "$root" && sha256sum --strict -c SHA256SUMS >/dev/null)
}
install -d -m 700 "$TMP/package-fixture"
printf '%s\n' original > "$TMP/package-fixture/payload"
(cd "$TMP/package-fixture" && sha256sum payload > SHA256SUMS)
portable_package_integrity "$TMP/package-fixture"
printf '%s\n' tampered > "$TMP/package-fixture/payload"
! portable_package_integrity "$TMP/package-fixture" 2>/dev/null
for required in '$(realpath -e -- "$root")' '$(stat -c '\''%u:%g:%a'\'' "$root/SHA256SUMS")' \
    'find "$root" ! -type d ! -type f' "! -path './SHA256SUMS'"; do
    grep -Fq -- "$required" "$ROOT/lib/common.sh"
done
function_body live_preflight "$ROOT/fleet_rollout.sh" > "$TMP/live-preflight"
function_body preflight "$ROOT/repair_vpn_pair.sh" > "$TMP/vpn-preflight"
function_body preflight "$ROOT/recover_clean_guard_stop.sh" > "$TMP/recovery-preflight"
assert_order "$TMP/live-preflight" 'verify_package_integrity "$PACKAGE_ROOT"' '$(id -u)'
assert_order "$TMP/vpn-preflight" 'verify_package_integrity "$PACKAGE_ROOT"' '$(id -u)'
assert_order "$TMP/recovery-preflight" 'verify_package_integrity "$PACKAGE_ROOT"' '$(id -u)'
assert_order "$ROOT/image-build/build_release_image.sh" \
    '(cd "$PACKAGE_ROOT" && sha256sum --strict -c SHA256SUMS' \
    'docker image inspect -f' 'DOCKER_BUILDKIT=1 docker build'
pass package-integrity-positive-negative-and-entrypoints

function_body no_existing_broadcast_markers "$ROOT/install_transaction_inhibitors.sh" \
    > "$TMP/no-existing-broadcast-markers"
(
    BROADCAST_DONE_DIR="$TMP/broadcast-done"
    install -d "$BROADCAST_DONE_DIR"
    realpath()
    {
        local item last=''
        for item in "$@"; do last=$item; done
        printf '%s\n' "$last"
    }
    eval "$(<"$TMP/no-existing-broadcast-markers")"
    no_existing_broadcast_markers
    printf '%s\n' harmless > "$BROADCAST_DONE_DIR/ordinary"
    no_existing_broadcast_markers
    printf '%s\n' pending > "$BROADCAST_DONE_DIR/regular.broadcast"
    ! no_existing_broadcast_markers
    rm -f "$BROADCAST_DONE_DIR/regular.broadcast"
    mkdir "$BROADCAST_DONE_DIR/directory.broadcast"
    ! no_existing_broadcast_markers
    rmdir "$BROADCAST_DONE_DIR/directory.broadcast"
    ln -s missing "$BROADCAST_DONE_DIR/symlink.broadcast"
    ! no_existing_broadcast_markers
)
function_body emergency_contain "$ROOT/install_transaction_inhibitors.sh" > "$TMP/emergency-contain"
assert_order "$TMP/emergency-contain" 'acquire_inhibitor_locks' 'installed_bytes_valid' \
    'broadcast_count=$(find' 'create_marker_atomic' 'completed_state'
function_body acquire_inhibitor_locks "$ROOT/install_transaction_inhibitors.sh" > "$TMP/inhibitor-locks"
assert_order "$TMP/inhibitor-locks" 'exec 12>"$ENDPOINT_LOCK"' 'exec 13>"$CUTOVER_LOCK"' \
    'exec 9>"$CYCLE_LOCK"' 'exec 14>"$WALLET_LOCK"' \
    'exec 11>"$TRANSITION_LOCK"' 'exec 10>"$FREE_CLAIM_LOCK"'
pass zero-broadcast-normal-install-and-purpose-bound-emergency-containment

for ownership_consumer in install_transaction_inhibitors.sh \
    free_claim_daemon_pause_wrapper.sh release_transaction_inhibitors.sh; do
    grep -Fq "stat -c '%u'" "$ROOT/$ownership_consumer"
    grep -Fq '8#$mode & 0022' "$ROOT/$ownership_consumer"
done
! grep -Fq "stat -c '%u:%g' \"\$FREE_CLAIM_ROOT\"" \
    "$ROOT/free_claim_daemon_pause_wrapper.sh"
pass root-uid-nonwritable-free-claim-ownership
grep -Fq '"$(stat -c '\''%a'\'' "$CYCLE_LIVE")" == 600' \
    "$ROOT/install_transaction_inhibitors.sh"
grep -Fq 'protected_file "$CYCLE_LIVE" 600' \
    "$ROOT/release_transaction_inhibitors.sh"
pass unraid-boot-cycle-mode

function_body install_triplet "$ROOT/fleet_rollout.sh" > "$TMP/install-triplet"
for required in compose_original_sha policy_original_sha guard_original_sha \
    compose_candidate_sha policy_candidate_sha guard_candidate_sha \
    'mv -fT -- "$compose_backup" "$COMPOSE_FILE"' \
    'mv -fT -- "$policy_backup" "$IMAGE_POLICY"' \
    'mv -fT -- "$guard_backup" "$ENDPOINT_GUARD"' \
    'triplet_policy_guard_valid "$IMAGE_POLICY" "$ENDPOINT_GUARD"'; do
    grep -Fq -- "$required" "$TMP/install-triplet"
done
[[ "$(grep -Fc 'original_sha" ]] ||' "$TMP/install-triplet")" -eq 3 ]]
! grep -Fq 'IN_FULL_ROLLBACK' "$ROOT/fleet_rollout.sh"
pass triplet-commit-and-byte-exact-internal-restoration

function_body stop_wave_for_rollback "$ROOT/fleet_rollout.sh" > "$TMP/rollback-stop"
assert_order "$TMP/rollback-stop" 'setpowmining false' \
    '.enabled == false and .live_claims == 0' 'rpc_for "$node" stop'
function_body drain_repair_claims "$ROOT/repair_vpn_pair.sh" > "$TMP/repair-drain"
assert_order "$TMP/repair-drain" 'setpowmining false' '.enabled == false and .live_claims == 0'
function_body stop_repair_target_cleanly "$ROOT/repair_vpn_pair.sh" > "$TMP/repair-stop"
assert_order "$TMP/repair-stop" 'drain_repair_claims' 'rpc_for "$NODE" stop'
function_body drain_target_claims "$ROOT/recover_clean_guard_stop.sh" > "$TMP/recovery-drain"
assert_order "$TMP/recovery-drain" 'setpowmining false' '.enabled == false and .live_claims == 0'
for specification in \
    'fleet_rollout.sh:assert_node_cleanly_stopped' \
    'repair_vpn_pair.sh:verify_target_topology_stopped' \
    'repair_vpn_pair.sh:stop_repair_target_cleanly' \
    'recover_clean_guard_stop.sh:verify_stopped_contract' \
    'recover_clean_guard_stop.sh:assert_target_cleanly_stopped'; do
    file=${specification%%:*}
    function_name=${specification##*:}
    function_body "$function_name" "$ROOT/$file" > "$TMP/clean-stop"
    grep -Fq 'State.Running == false' "$TMP/clean-stop"
    grep -Fq 'State.ExitCode == 0' "$TMP/clean-stop"
    grep -Fq 'State.OOMKilled == false' "$TMP/clean-stop"
    grep -Fq 'State.Error == ""' "$TMP/clean-stop"
done
pass claim-safe-and-clean-stop-boundaries

for function_name in data_rollback_authority_path \
    data_rollback_canonical_single_object_json data_rollback_validate_stopped_generation \
    data_rollback_verify_authority_sealed; do
    function_body "$function_name" "$ROOT/lib/data_rollback.sh"
done > "$TMP/rollback-authority-functions"
(
    # Exercise the real authority parser and exact-key verifier with all external
    # runtime checks replaced by immutable local fixture facts.
    # shellcheck disable=SC1090
    source "$TMP/rollback-authority-functions"
    RUN_DIR="$TMP/rollback-authority-run"
    CURRENT_WAVE_DIR="$RUN_DIR/wave-01-nodes-04"
    ROLLOUT_MAINTENANCE_MARKER="$RUN_DIR/maintenance.json"
    CURRENT_WAVE_NODES=(4)
    mkdir -p "$CURRENT_WAVE_DIR"
    printf '%s\n' '{"canary_handoff":{"required":true}}' > "$RUN_DIR/TRANSACTION.json"
    printf '%s\n' handoff > "$RUN_DIR/CANARY-FLEET-HANDOFF.json"
    printf '%s\n' maintenance > "$ROLLOUT_MAINTENANCE_MARKER"
    printf '%s\n' drain > "$CURRENT_WAVE_DIR/WAVE-DRAIN-EVIDENCE.sha256"
    printf '%s\n' inventory > "$CURRENT_WAVE_DIR/data-snapshots.tsv"
    sha256sum "$CURRENT_WAVE_DIR/data-snapshots.tsv" | awk '{print $1}' \
        > "$CURRENT_WAVE_DIR/data-snapshots.tsv.sha256"

    valid_sha256_hex() { [[ "$1" =~ ^[0-9a-f]{64}$ ]]; }
    data_rollback_protected_file() { [[ -f "$1" && ! -L "$1" ]]; }
    data_rollback_verify_authority_context_sealed() { return 0; }
    wave_node_launch_attempt_path()
    {
        printf '%s/node-%02d-CANDIDATE-LAUNCH-ATTEMPTED.json\n' "$CURRENT_WAVE_DIR" "$1"
    }
    wave_node_safe_rollback_path()
    {
        printf '%s/node-%02d-SAFE-ROLLBACK.json\n' "$CURRENT_WAVE_DIR" "$1"
    }
    wave_node_activation_path()
    {
        printf '%s/node-%02d-CANDIDATE-ACTIVATION-ATTEMPTED.json\n' "$CURRENT_WAVE_DIR" "$1"
    }

    transaction_sha=$(sha256sum "$RUN_DIR/TRANSACTION.json" | awk '{print $1}')
    handoff_sha=$(sha256sum "$RUN_DIR/CANARY-FLEET-HANDOFF.json" | awk '{print $1}')
    maintenance_sha=$(sha256sum "$ROLLOUT_MAINTENANCE_MARKER" | awk '{print $1}')
    drain_sha=$(sha256sum "$CURRENT_WAVE_DIR/WAVE-DRAIN-EVIDENCE.sha256" | awk '{print $1}')
    inventory_sha=$(sha256sum "$CURRENT_WAVE_DIR/data-snapshots.tsv" | awk '{print $1}')
    generation="$(printf 'a%.0s' {1..64})|2026-08-06T00:00:00Z|$(printf 'b%.0s' {1..64})|2026-08-06T00:00:01Z"
    jq -S -n --arg run "$RUN_DIR" --arg wave "$CURRENT_WAVE_DIR" \
        --arg transaction_sha "$transaction_sha" --arg handoff_sha "$handoff_sha" \
        --arg maintenance_sha "$maintenance_sha" \
        --arg drain_sha "$drain_sha" --arg inventory_sha "$inventory_sha" \
        --arg generation "$generation" '
        {schema:1,transaction:"v30.1.4-fleet-rollout",purpose:"pre-upgrade-data-restore",
         run_dir:$run,wave_dir:$wave,transaction_manifest_sha256:$transaction_sha,
         canary_fleet_handoff_sha256:$handoff_sha,maintenance_marker_sha256:$maintenance_sha,
         wave_drain_manifest_sha256:$drain_sha,snapshot_inventory_sha256:$inventory_sha,
         nodes:[{node:4,launch_state:"not-attempted",launch_marker_sha256:null,
           safe_boundary_sha256:null,stopped_generation:$generation}],
         published_at:"2026-08-06T00:00:02Z"}' > "$CURRENT_WAVE_DIR/ROLLBACK-AUTHORITY.json"
    cp "$CURRENT_WAVE_DIR/ROLLBACK-AUTHORITY.json" "$TMP/rollback-authority.valid"
    authority_sha=$(sha256sum "$CURRENT_WAVE_DIR/ROLLBACK-AUTHORITY.json" | awk '{print $1}')
    data_rollback_verify_authority_sealed "$authority_sha"

    jq -S '.unexpected=true' "$TMP/rollback-authority.valid" \
        > "$CURRENT_WAVE_DIR/ROLLBACK-AUTHORITY.json"
    ! data_rollback_verify_authority_sealed \
        "$(sha256sum "$CURRENT_WAVE_DIR/ROLLBACK-AUTHORITY.json" | awk '{print $1}')"

    jq -c . "$TMP/rollback-authority.valid" > "$CURRENT_WAVE_DIR/ROLLBACK-AUTHORITY.json"
    ! data_rollback_verify_authority_sealed \
        "$(sha256sum "$CURRENT_WAVE_DIR/ROLLBACK-AUTHORITY.json" | awk '{print $1}')"

    : > "$CURRENT_WAVE_DIR/ROLLBACK-AUTHORITY.json"
    ! data_rollback_verify_authority_sealed \
        "$(sha256sum "$CURRENT_WAVE_DIR/ROLLBACK-AUTHORITY.json" | awk '{print $1}')"

    printf '%s\n' '{"schema":1,"schema":1}' > "$CURRENT_WAVE_DIR/ROLLBACK-AUTHORITY.json"
    ! data_rollback_verify_authority_sealed \
        "$(sha256sum "$CURRENT_WAVE_DIR/ROLLBACK-AUTHORITY.json" | awk '{print $1}')"

    {
        cat "$TMP/rollback-authority.valid"
        cat "$TMP/rollback-authority.valid"
    } > "$CURRENT_WAVE_DIR/ROLLBACK-AUTHORITY.json"
    ! data_rollback_verify_authority_sealed \
        "$(sha256sum "$CURRENT_WAVE_DIR/ROLLBACK-AUTHORITY.json" | awk '{print $1}')"
)

for function_name in data_rollback_require_mutation_authority \
    data_rollback_require_fileset_mutation_boundary; do
    function_body "$function_name" "$ROOT/lib/data_rollback.sh"
done > "$TMP/rollback-mutation-boundary-functions"
function_body data_rollback_require_mutation_fences "$ROOT/lib/data_rollback.sh" \
    > "$TMP/rollback-mutation-fences"
for required in 'WAVE_LOCKS_HELD' \
    'data_rollback_require_lock_fd 19 /var/run/blackcoin-v30.1.4-fleet-rollout.lock' \
    'data_rollback_require_lock_fd 15 /run/blackcoin-endpoint-guard.lock' \
    'data_rollback_require_lock_fd 16 /var/run/blackcoin-node-cutover.lock' \
    'data_rollback_require_lock_fd 14 /run/blackcoin-pow-quarantine-cycle.lock' \
    'data_rollback_require_lock_fd 17 /var/run/blackcoin-wallet-runtime-guard.lock' \
    'data_rollback_require_lock_fd 18 "$FREE_CLAIM_LOCK"'; do
    grep -Fq -- "$required" "$TMP/rollback-mutation-fences"
done
function_body restore_filesets_from_inventory "$ROOT/lib/data_rollback.sh" \
    > "$TMP/restore-filesets-boundary"
assert_order "$TMP/restore-filesets-boundary" \
    'data_rollback_require_fileset_mutation_boundary' \
    'rsync -aHAXx --numeric-ids --delete'
function_body restore_zfs_from_inventory "$ROOT/lib/data_rollback.sh" \
    > "$TMP/restore-zfs-boundary"
assert_order "$TMP/restore-zfs-boundary" \
    'data_rollback_require_zfs_rollback_boundary' 'zfs rollback "$snapshot"'
assert_order "$TMP/restore-zfs-boundary" \
    'data_rollback_require_zfs_rsync_boundary' \
    'rsync -aHAXx --numeric-ids --delete'
(
    # shellcheck disable=SC1090
    source "$TMP/rollback-mutation-boundary-functions"
    FLEET_ZFS_PARENT=pool
    MOUNT="$TMP/rollback-boundary-mount"
    LIVE_PATH="$MOUNT/node-28/blocks"
    SNAPSHOT_SOURCE="$MOUNT/.zfs/snapshot/preupgrade/node-28/blocks"
    mkdir -p "$LIVE_PATH" "$SNAPSHOT_SOURCE"
    AUTHORITY_SHA=$(printf 'c%.0s' {1..64})
    FENCES_VALID=1
    GENERATION_VALID=1
    PATH_DRIFT=0
    FENCE_CALLS=0
    LIVE_AUTHORITY_CALLS=0
    GENERATION_CALLS=0

    valid_sha256_hex() { [[ "$1" =~ ^[0-9a-f]{64}$ ]]; }
    valid_node() { [[ "$1" -ge 1 && "$1" -le 32 ]]; }
    host_blocks_for() { printf '%s/node-%s\n' "$MOUNT" "$1"; }
    data_domain_for() { printf 'fileset|pool\n'; }
    data_rollback_verify_snapshot_identity() { return 0; }
    realpath()
    {
        [[ "$1" == -e ]] && shift
        [[ "$1" == -- ]] && shift
        printf '%s\n' "$1"
    }
    zfs() { [[ "$1" == get ]] && printf '%s\n' "$MOUNT"; }
    findmnt() { printf '%s\n' pool; }
    data_rollback_require_mutation_fences()
    {
        FENCE_CALLS=$((FENCE_CALLS + 1))
        [[ "$FENCES_VALID" -eq 1 ]]
    }
    data_rollback_verify_authority_live()
    {
        LIVE_AUTHORITY_CALLS=$((LIVE_AUTHORITY_CALLS + 1))
        if [[ "$PATH_DRIFT" -eq 1 ]]; then
            mv -- "$LIVE_PATH" "${LIVE_PATH}.original"
            ln -s -- "${LIVE_PATH}.original" "$LIVE_PATH"
        fi
    }
    data_rollback_verify_authority_stopped_generations()
    {
        GENERATION_CALLS=$((GENERATION_CALLS + 1))
        [[ "$GENERATION_VALID" -eq 1 ]]
    }
    check_boundary()
    {
        data_rollback_require_fileset_mutation_boundary "$AUTHORITY_SHA" 28 raw pool \
            "$LIVE_PATH" pool@preupgrade 10 20 hold "$SNAPSHOT_SOURCE"
    }

    check_boundary
    [[ "$FENCE_CALLS" -eq 2 && "$LIVE_AUTHORITY_CALLS" -eq 1 && "$GENERATION_CALLS" -eq 1 ]]

    FENCES_VALID=0
    FENCE_CALLS=0
    LIVE_AUTHORITY_CALLS=0
    GENERATION_CALLS=0
    ! check_boundary
    [[ "$FENCE_CALLS" -eq 1 && "$LIVE_AUTHORITY_CALLS" -eq 0 && "$GENERATION_CALLS" -eq 0 ]]

    FENCES_VALID=1
    PATH_DRIFT=1
    FENCE_CALLS=0
    LIVE_AUTHORITY_CALLS=0
    GENERATION_CALLS=0
    ! check_boundary
    [[ "$FENCE_CALLS" -eq 1 && "$LIVE_AUTHORITY_CALLS" -eq 1 && "$GENERATION_CALLS" -eq 0 ]]
    rm -f -- "$LIVE_PATH"
    mv -- "${LIVE_PATH}.original" "$LIVE_PATH"
    PATH_DRIFT=0

    GENERATION_VALID=0
    FENCE_CALLS=0
    LIVE_AUTHORITY_CALLS=0
    GENERATION_CALLS=0
    ! check_boundary
    [[ "$FENCE_CALLS" -eq 2 && "$LIVE_AUTHORITY_CALLS" -eq 1 && "$GENERATION_CALLS" -eq 1 ]]
)

for function_name in data_rollback_authority_path data_rollback_canonical_single_object_json \
    data_rollback_authority_node_launch_state data_rollback_restore_expected_counts \
    restore_filesets_from_inventory restore_zfs_from_inventory \
    data_rollback_restore_evidence_files data_rollback_verify_restore_evidence_manifest \
    data_rollback_verify_data_restored_receipt_body data_rollback_verify_data_restored_receipt \
    data_rollback_publish_data_restored_receipt restore_wave_preupgrade_data; do
    function_body "$function_name" "$ROOT/lib/data_rollback.sh"
done > "$TMP/rollback-resume-functions"
(
    # The mixed authority may mutate only node 28. Node 29 deliberately has no
    # live directory, so reaching its primitive checks would fail the fixture.
    # shellcheck disable=SC1090
    source "$TMP/rollback-resume-functions"
    RUN_DIR="$TMP/rollback-authority-filter-run"
    CURRENT_WAVE_DIR="$RUN_DIR/mixed"
    mkdir -p "$CURRENT_WAVE_DIR" "$RUN_DIR/node-28-live" "$RUN_DIR/node-28-snapshot"
    jq -S -n '{nodes:[{node:28,launch_state:"candidate-attempted"},
      {node:29,launch_state:"not-attempted"}]}' \
        > "$CURRENT_WAVE_DIR/ROLLBACK-AUTHORITY.json"
    AUTHORITY_SHA=$(sha256sum "$CURRENT_WAVE_DIR/ROLLBACK-AUTHORITY.json" | awk '{print $1}')
    printf '%s\n' \
        "FILESET|28|raw|pool|$RUN_DIR/node-28-live|pool@preupgrade|10|20|hold|$RUN_DIR/node-28-snapshot" \
        "FILESET|29|raw|pool|$RUN_DIR/node-29-missing|pool@preupgrade|11|21|hold|$RUN_DIR/node-29-snapshot-missing" \
        'ZFS|29|data|pool/node29|/missing|pool/node29@preupgrade|12|22|hold|/missing' \
        > "$CURRENT_WAVE_DIR/data-snapshots.tsv"

    valid_sha256_hex() { [[ "$1" =~ ^[0-9a-f]{64}$ ]]; }
    valid_node() { [[ "$1" -ge 1 && "$1" -le 32 ]]; }
    data_rollback_protected_file() { [[ -f "$1" && ! -L "$1" ]]; }
    data_rollback_verify_authority_sealed()
    {
        [[ "$1" == "$AUTHORITY_SHA" &&
           "$(sha256sum "$CURRENT_WAVE_DIR/ROLLBACK-AUTHORITY.json" | awk '{print $1}')" == "$1" ]]
    }
    realpath()
    {
        [[ "$1" == -e ]] && shift
        [[ "$1" == -- ]] && shift
        printf '%s\n' "$1"
    }
    MUTATION_NODES=''
    RSYNC_CALLS=0
    data_rollback_require_fileset_mutation_boundary()
    {
        MUTATION_NODES="${MUTATION_NODES}${MUTATION_NODES:+ }$2"
    }
    rsync() { RSYNC_CALLS=$((RSYNC_CALLS + 1)); }
    chown() { return 0; }

    [[ "$(data_rollback_authority_node_launch_state "$AUTHORITY_SHA" 28)" == candidate-attempted ]]
    [[ "$(data_rollback_authority_node_launch_state "$AUTHORITY_SHA" 29)" == not-attempted ]]
    [[ "$(data_rollback_restore_expected_counts "$AUTHORITY_SHA")" == '1 0' ]]
    restore_filesets_from_inventory "$AUTHORITY_SHA"
    [[ "$MUTATION_NODES" == 28 && "$RSYNC_CALLS" -eq 2 ]]
    [[ -f "$CURRENT_WAVE_DIR/fileset-restore-node-28-raw.diff" &&
       ! -e "$CURRENT_WAVE_DIR/fileset-restore-node-29-raw.diff" ]]

    CURRENT_WAVE_DIR="$RUN_DIR/all-not-attempted"
    mkdir -p "$CURRENT_WAVE_DIR"
    jq -S -n '{nodes:[{node:28,launch_state:"not-attempted"},
      {node:29,launch_state:"not-attempted"}]}' \
        > "$CURRENT_WAVE_DIR/ROLLBACK-AUTHORITY.json"
    AUTHORITY_SHA=$(sha256sum "$CURRENT_WAVE_DIR/ROLLBACK-AUTHORITY.json" | awk '{print $1}')
    printf '%s\n' \
        'FILESET|28|raw|pool|/missing|pool@preupgrade|10|20|hold|/missing' \
        'ZFS|29|data|pool/node29|/missing|pool/node29@preupgrade|12|22|hold|/missing' \
        > "$CURRENT_WAVE_DIR/data-snapshots.tsv"
    MUTATION_CALLS=0
    ARTIFACT_CALLS=0
    data_rollback_verify_authority_live() { MUTATION_CALLS=$((MUTATION_CALLS + 1)); }
    verify_wave_snapshot_inventory() { MUTATION_CALLS=$((MUTATION_CALLS + 1)); }
    restore_filesets_from_inventory() { MUTATION_CALLS=$((MUTATION_CALLS + 1)); }
    restore_zfs_from_inventory() { MUTATION_CALLS=$((MUTATION_CALLS + 1)); }
    data_rollback_publish_restore_evidence_manifest() { ARTIFACT_CALLS=$((ARTIFACT_CALLS + 1)); }
    data_rollback_publish_data_restored_receipt() { ARTIFACT_CALLS=$((ARTIFACT_CALLS + 1)); }

    ! restore_wave_preupgrade_data "$AUTHORITY_SHA"
    [[ "$MUTATION_CALLS" -eq 0 && "$ARTIFACT_CALLS" -eq 0 ]]
    [[ ! -e "$CURRENT_WAVE_DIR/DATA-RESTORE-EVIDENCE.sha256" &&
       ! -e "$CURRENT_WAVE_DIR/DATA-RESTORED.json" &&
       ! -e "$CURRENT_WAVE_DIR/DATA-RESTORED.json.sha256" ]]
)
pass attempted-only-data-rollback-filtering
(
    # Test both authenticated crash-publication prefixes. Any invocation of a
    # live restore primitive is a hard fixture failure.
    # shellcheck disable=SC1090
    source "$TMP/rollback-resume-functions"
    RUN_DIR="$TMP/rollback-resume-run"
    CURRENT_WAVE_DIR="$RUN_DIR/wave-01-nodes-28-29"
    mkdir -p "$CURRENT_WAVE_DIR"
    jq -S -n '{nodes:[{node:28,launch_state:"candidate-attempted"},
      {node:29,launch_state:"not-attempted"}]}' \
        > "$CURRENT_WAVE_DIR/ROLLBACK-AUTHORITY.json"
    AUTHORITY_SHA=$(sha256sum "$CURRENT_WAVE_DIR/ROLLBACK-AUTHORITY.json" | awk '{print $1}')
    printf '%s\n' \
        'FILESET|28|raw|pool|/mnt/pool/node-28/blocks|pool@preupgrade|10|20|hold|/mnt/pool/.zfs/snapshot/preupgrade/node-28/blocks' \
        'FILESET|29|raw|pool|/mnt/pool/node-29/blocks|pool@preupgrade|11|21|hold|/mnt/pool/.zfs/snapshot/preupgrade/node-29/blocks' \
        'ZFS|29|data|pool/node29|/mnt/pool/node-29|pool/node29@preupgrade|12|22|hold|/mnt/pool/node-29/.zfs/snapshot/preupgrade' \
        > "$CURRENT_WAVE_DIR/data-snapshots.tsv"
    : > "$CURRENT_WAVE_DIR/fileset-restore-node-28-raw.diff"
    (cd "$CURRENT_WAVE_DIR" && sha256sum fileset-restore-node-28-raw.diff \
        > DATA-RESTORE-EVIDENCE.sha256)

    RESTORE_FILESET_CALLS=0
    RESTORE_ZFS_CALLS=0
    LIVE_AUTHORITY_CALLS=0
    SNAPSHOT_INVENTORY_CALLS=0
    MANIFEST_PUBLISH_CALLS=0
    ZFS_PRIMITIVE_CALLS=0
    valid_sha256_hex() { [[ "$1" =~ ^[0-9a-f]{64}$ ]]; }
    valid_node() { [[ "$1" -ge 1 && "$1" -le 32 ]]; }
    data_rollback_protected_file() { [[ -f "$1" && ! -L "$1" ]]; }
    data_rollback_verify_authority_sealed()
    {
        [[ "$1" == "$AUTHORITY_SHA" &&
           "$(sha256sum "$CURRENT_WAVE_DIR/ROLLBACK-AUTHORITY.json" | awk '{print $1}')" == "$1" ]]
    }
    chown() { return 0; }
    sync() { return 0; }
    zfs() { ZFS_PRIMITIVE_CALLS=$((ZFS_PRIMITIVE_CALLS + 1)); return 1; }

    data_rollback_restore_evidence_files "$AUTHORITY_SHA" "$TMP/mixed-restore-evidence-files"
    [[ "$(cat "$TMP/mixed-restore-evidence-files")" == \
       fileset-restore-node-28-raw.diff ]]
    restore_zfs_from_inventory "$AUTHORITY_SHA"
    [[ "$ZFS_PRIMITIVE_CALLS" -eq 0 ]]

    data_rollback_verify_authority_live()
    {
        LIVE_AUTHORITY_CALLS=$((LIVE_AUTHORITY_CALLS + 1))
        return 1
    }
    verify_wave_snapshot_inventory()
    {
        SNAPSHOT_INVENTORY_CALLS=$((SNAPSHOT_INVENTORY_CALLS + 1))
        return 1
    }
    restore_filesets_from_inventory()
    {
        RESTORE_FILESET_CALLS=$((RESTORE_FILESET_CALLS + 1))
        return 1
    }
    restore_zfs_from_inventory()
    {
        RESTORE_ZFS_CALLS=$((RESTORE_ZFS_CALLS + 1))
        return 1
    }
    data_rollback_publish_restore_evidence_manifest()
    {
        MANIFEST_PUBLISH_CALLS=$((MANIFEST_PUBLISH_CALLS + 1))
        return 1
    }

    restore_wave_preupgrade_data "$AUTHORITY_SHA"
    data_rollback_verify_data_restored_receipt "$AUTHORITY_SHA"
    [[ -f "$CURRENT_WAVE_DIR/DATA-RESTORED.json" &&
       -f "$CURRENT_WAVE_DIR/DATA-RESTORED.json.sha256" ]]
    [[ "$(wc -l < "$CURRENT_WAVE_DIR/DATA-RESTORE-EVIDENCE.sha256")" -eq 1 ]]
    ! grep -Fq 'node-29' "$CURRENT_WAVE_DIR/DATA-RESTORE-EVIDENCE.sha256"
    jq -e '.fileset_restore_expected == 1 and .fileset_restore_completed == 1 and
      .fileset_restore_proofs == 1 and .zfs_restore_expected == 0 and
      .zfs_restore_completed == 0 and .zfs_rollback_proofs == 0' \
        "$CURRENT_WAVE_DIR/DATA-RESTORED.json" >/dev/null
    [[ "$RESTORE_FILESET_CALLS" -eq 0 && "$RESTORE_ZFS_CALLS" -eq 0 &&
       "$LIVE_AUTHORITY_CALLS" -eq 0 && "$SNAPSHOT_INVENTORY_CALLS" -eq 0 &&
       "$MANIFEST_PUBLISH_CALLS" -eq 0 ]]

    cp "$CURRENT_WAVE_DIR/DATA-RESTORED.json" "$TMP/data-restored.valid"
    jq -S '.unexpected=true' "$TMP/data-restored.valid" > "$CURRENT_WAVE_DIR/DATA-RESTORED.json"
    ! data_rollback_verify_data_restored_receipt_body "$AUTHORITY_SHA"
    jq -c . "$TMP/data-restored.valid" > "$CURRENT_WAVE_DIR/DATA-RESTORED.json"
    ! data_rollback_verify_data_restored_receipt_body "$AUTHORITY_SHA"
    : > "$CURRENT_WAVE_DIR/DATA-RESTORED.json"
    ! data_rollback_verify_data_restored_receipt_body "$AUTHORITY_SHA"
    printf '%s\n' '{"schema":2,"schema":2}' > "$CURRENT_WAVE_DIR/DATA-RESTORED.json"
    ! data_rollback_verify_data_restored_receipt_body "$AUTHORITY_SHA"
    {
        cat "$TMP/data-restored.valid"
        cat "$TMP/data-restored.valid"
    } > "$CURRENT_WAVE_DIR/DATA-RESTORED.json"
    ! data_rollback_verify_data_restored_receipt_body "$AUTHORITY_SHA"

    cp "$TMP/data-restored.valid" "$CURRENT_WAVE_DIR/DATA-RESTORED.json"
    receipt_sha=$(sha256sum "$CURRENT_WAVE_DIR/DATA-RESTORED.json" | awk '{print $1}')
    rm -f -- "$CURRENT_WAVE_DIR/DATA-RESTORED.json.sha256"
    RESTORE_FILESET_CALLS=0
    RESTORE_ZFS_CALLS=0
    LIVE_AUTHORITY_CALLS=0
    SNAPSHOT_INVENTORY_CALLS=0
    MANIFEST_PUBLISH_CALLS=0
    restore_wave_preupgrade_data "$AUTHORITY_SHA"
    [[ "$(sha256sum "$CURRENT_WAVE_DIR/DATA-RESTORED.json" | awk '{print $1}')" == "$receipt_sha" &&
       "$(cat "$CURRENT_WAVE_DIR/DATA-RESTORED.json.sha256")" == "$receipt_sha" ]]
    data_rollback_verify_data_restored_receipt "$AUTHORITY_SHA"
    [[ "$RESTORE_FILESET_CALLS" -eq 0 && "$RESTORE_ZFS_CALLS" -eq 0 &&
       "$LIVE_AUTHORITY_CALLS" -eq 0 && "$SNAPSHOT_INVENTORY_CALLS" -eq 0 &&
       "$MANIFEST_PUBLISH_CALLS" -eq 0 ]]
)
pass authenticated-data-rollback-boundaries-and-resume

function_body run_finalization_phase "$ROOT/fleet_soak_audit.sh" > "$TMP/finalization-phase"
assert_order "$TMP/finalization-phase" 'verify_recovery_baselines_unchanged' \
    'verify_global_chain_convergence' 'assert_unique_vpn_proofs' \
    'verify_final_policy_assets' 'verify_final_dynamic_all_nodes' \
    'capture_fresh_supervisor' 'capture_final_fleet_identity' \
    'capture_exact_32_generation_map "$generation_final"' 'write_audit_checksums'
function_body verify_finalization_ready "$ROOT/fleet_soak_audit.sh" > "$TMP/finalization-ready"
for required in '.phase == "pre-release"' '.supervisor_timestamp_epoch > $released' \
    '.nodes_healthy == 32' '.pos_active == 32' '.regular_pow_active == 31' \
    '.free_claim_regular_pow == false' '.fee_payments_authorized == false' \
    '.run_dir == $run' '.transaction_manifest_sha256 == $transaction_sha' '.run_nonce == $nonce' \
    '.generation_before_publication_sha256 == $generation_final_sha'; do
    grep -Fq -- "$required" "$TMP/finalization-ready"
done
grep -Fq 'supervisor_freshness_deferred_to_finalization:true' "$ROOT/fleet_soak_audit.sh"
grep -Fq 'external_supervisors_maintenance_inhibited:true' "$ROOT/fleet_soak_audit.sh"
grep -Fq 'SOAK_RESUME=1 "$SOAK_AUDITOR"' "$ROOT/fleet_rollout.sh"
[[ "$(grep -Fc 'run_finalization_phase' "$ROOT/fleet_soak_audit.sh")" -eq 2 ]]
grep -Fq 'verify_finalization_ready 0' "$TMP/finalization-phase"
function_body recover_interrupted_finalization_manifest "$ROOT/fleet_soak_audit.sh" \
    > "$TMP/finalization-recovery"
for required in 'HOUR_SOAK_DIRECTORIES' 'preserved_dirs' \
    '^finalization-(pre|post)-release-attempt-[0-9]{3,}$'; do
    grep -Fq -- "$required" "$TMP/finalization-recovery"
done
function_body supervisor_epoch_is_fresh_after "$ROOT/fleet_soak_audit.sh" \
    > "$TMP/supervisor-after-release"
(
    eval "$(<"$TMP/supervisor-after-release")"
    supervisor_epoch_is_fresh_after 201 200 250
    ! supervisor_epoch_is_fresh_after 150 200 250
    ! supervisor_epoch_is_fresh_after 201 200 600
)
pass fresh-final-fleet-and-efficient-soak-resume

function_body release_maintenance_for_finalization "$ROOT/fleet_rollout.sh" \
    > "$TMP/release-maintenance"
assert_order "$TMP/release-maintenance" 'acquire_finalization_guard_locks' \
    'release_maintenance_marker' 'publish_maintenance_released_epoch' \
    'maintenance-released' 'release_finalization_guard_locks'
function_body ensure_finalization_containment "$ROOT/fleet_rollout.sh" > "$TMP/final-containment"
assert_order "$TMP/final-containment" 'acquire_finalization_guard_locks' \
    '"$INHIBITOR_RELEASER" probe' 'activate_free_claim_pause_safely' \
    'activate_maintenance_marker_safely' 'verify_free_claim_pause' \
    'verify_maintenance_marker' 'release_finalization_guard_locks'
function_body acquire_finalization_guard_locks "$ROOT/fleet_rollout.sh" > "$TMP/final-locks"
assert_order "$TMP/final-locks" 'blackcoin-endpoint-guard.lock' 'blackcoin-node-cutover.lock' \
    'blackcoin-pow-quarantine-cycle.lock' 'blackcoin-wallet-runtime-guard.lock' \
    'blackcoin-free-claim-pause-transition.lock' 'blackcoin-free-claim-pool.lock'
function_body on_exit "$ROOT/fleet_rollout.sh" > "$TMP/on-exit"
assert_order "$TMP/on-exit" 'if [[ "$TERMINAL_FINALIZED" -eq 1 ]]' \
    'if [[ "$TERMINAL_COMMIT_ACTIVE" -eq 1 ]]' 'rollback_current_wave' \
    'ensure_finalization_containment'
assert_order "$TMP/on-exit" 'activate_maintenance_marker_safely' \
    'release_finalization_guard_locks' 'ensure_finalization_containment'
grep -Fq 'TERMINAL_COMMIT_ACTIVE' "$TMP/on-exit"
function_body finalize_completed_rollout "$ROOT/fleet_rollout.sh" > "$TMP/finalize-complete"
assert_order "$TMP/finalize-complete" 'verify_terminal_receipt complete 0' \
    'TERMINAL_FINALIZED=1' 'FINALIZATION_ACTIVE=0' \
    'verify_terminal_receipt complete 1'
assert_order_last "$TMP/finalize-complete" 'release_maintenance_for_finalization' \
    'SOAK_PHASE=pre-release' '"$INHIBITOR_RELEASER" release' \
    'SOAK_PHASE=post-release' 'capture_terminal_generation_fence complete' \
    'cleanup_transaction_snapshots' 'write_terminal_receipt complete' \
    'verify_terminal_receipt complete'
assert_order "$TMP/finalize-complete" \
    'verify_snapshot_cleanup_resume_prefix' 'verify_terminal_cleanup_prerequisites complete' \
    'if data_rollback_finalization_released' \
    'TERMINAL_COMMIT_ACTIVE=1' \
    'cleanup_transaction_snapshots'
grep -Fq 'post-release-passed|finalized)' "$TMP/finalize-complete"
grep -Fq 'contained)' "$TMP/finalize-complete"
assert_order "$TMP/finalize-complete" 'verify_snapshot_cleanup_resume_prefix' \
    'resume_finalization_state=$(<"$(finalization_state_path)")' 'contained)' \
    'inhibitor_state=$(/bin/bash "$INHIBITOR_RELEASER" probe)'
function_body verify_finalization_ready "$ROOT/release_transaction_inhibitors.sh" \
    > "$TMP/release-ready"
for required in 'supervisor_epoch >= now - 300' '../HOUR-SOAK-SHA256SUMS' \
    'SUPERVISOR-STATUS.json}" == "$attempt_rel"' 'sha256sum --strict -c SHA256SUMS' \
    '.run_dir == $run' '.transaction_manifest_sha256 == $transaction_sha' \
    '.generation_before_publication_sha256 == $generation_final_sha'; do
    grep -Fq -- "$required" "$TMP/release-ready"
done
grep -Fq 'fleet maintenance marker reappeared before Free Claim release' \
    "$ROOT/release_transaction_inhibitors.sh"
function_body finalize_rolled_back_run "$ROOT/fleet_rollout.sh" > "$TMP/finalize-rollback"
assert_order "$TMP/finalize-rollback" 'verify_terminal_receipt rolled-back 0' \
    'TERMINAL_FINALIZED=1' 'FINALIZATION_ACTIVE=0' \
    'verify_terminal_receipt rolled-back 1'
assert_order_last "$TMP/finalize-rollback" 'release_maintenance_for_finalization' \
    'write_rollback_finalization_ready' '"$INHIBITOR_RELEASER" release' \
    'write_rollback_post_release_evidence' 'verify_all_baseline_runtime_once' \
    'capture_terminal_generation_fence rolled-back' 'cleanup_transaction_snapshots' \
    'write_terminal_receipt rolled-back' 'verify_terminal_receipt rolled-back'
assert_order "$TMP/finalize-rollback" \
    'verify_snapshot_cleanup_resume_prefix' 'verify_terminal_cleanup_prerequisites rolled-back' \
    'if data_rollback_finalization_released' \
    'TERMINAL_COMMIT_ACTIVE=1' \
    'cleanup_transaction_snapshots'
grep -Fq 'post-release-passed|finalized)' "$TMP/finalize-rollback"
grep -Fq 'contained)' "$TMP/finalize-rollback"
assert_order "$TMP/finalize-rollback" 'verify_snapshot_cleanup_resume_prefix' \
    'resume_finalization_state=$(<"$(finalization_state_path)")' 'contained)' \
    'inhibitor_state=$(/bin/bash "$INHIBITOR_RELEASER" probe)'
function_body verify_snapshot_cleanup_resume_prefix "$ROOT/fleet_rollout.sh" \
    > "$TMP/snapshot-cleanup-resume-prefix"
assert_order "$TMP/snapshot-cleanup-resume-prefix" 'verify_transaction_manifest' \
    'data_rollback_cleanup_allowed' 'data_rollback_verify_cleanup_plan_dir' \
    'data_rollback_verify_cleanup_sources' \
    'data_rollback_verify_cleanup_journal_topology'
function_body verify_terminal_cleanup_prerequisites "$ROOT/fleet_rollout.sh" \
    > "$TMP/terminal-cleanup-prerequisites"
for required in 'post-release-passed || "$finalization_state" == finalized' \
    'verify_success_post_release_evidence' 'verify_rollback_post_release_evidence' \
    'baseline/fleet-identity.json' 'baseline/free-claim-container-identity.json' \
    'cmp -s "$generation_expected" "$generation_final"'; do
    grep -Fq -- "$required" "$TMP/terminal-cleanup-prerequisites"
done
! grep -Fq '== finalized' "$TMP/finalize-complete"
! grep -Fq '== finalized' "$TMP/finalize-rollback"
function_body cleanup_transaction_snapshots "$ROOT/lib/data_rollback.sh" \
    > "$TMP/cleanup-transaction-snapshots"
assert_order "$TMP/cleanup-transaction-snapshots" \
    'mv -fT -- "$result_tmp" "$cleanup_dir/RESULT.json"' \
    'Persist the result entry before its recoverable sidecar publication.' \
    'mv -fT -- "$result_sha_tmp" "$cleanup_dir/RESULT.json.sha256"' \
    'Persist the sidecar entry only after the result entry is durable.'
function_body write_terminal_receipt "$ROOT/fleet_rollout.sh" > "$TMP/terminal-writer"
assert_order "$TMP/terminal-writer" 'mktemp -d "$RUN_DIR/.terminal-finalization.' \
    'sha256sum ./RESULT.json' 'verify_terminal_receipt "$outcome" 0 "$staging"' \
    "trap '' HUP INT TERM" 'mv -T -- "$staging" "$receipt_dir"' \
    'TERMINAL_FINALIZED=1' 'FINALIZATION_ACTIVE=0' 'sync -f "$RUN_DIR"' \
    'verify_terminal_receipt "$outcome" 0' 'verify_terminal_receipt "$outcome" 1'
for required in 'terminal_evidence_manifest' 'hour_manifest_sha256' \
    'hour_directories_sha256' 'terminal_generation_sha256'; do
    grep -Fq -- "$required" "$TMP/terminal-writer"
done
function_body release_pause "$ROOT/release_transaction_inhibitors.sh" > "$TMP/release-pause"
assert_order "$TMP/release-pause" 'installed_state_valid' \
    'if [[ ! -e "$PAUSE_MARKER"' 'verify_release_receipt committed required' \
    'verify_success_evidence'
assert_order_last "$TMP/release-pause" 'write_release_receipt "$run_dir"' \
    'verify_release_receipt prepared required' 'rm -f -- "$PAUSE_MARKER"' \
    'verify_release_receipt committed required'
grep -Fq 'create_pause_marker_atomic' "$TMP/release-pause"
function_body write_release_receipt "$ROOT/release_transaction_inhibitors.sh" \
    > "$TMP/release-receipt-writer"
assert_order_last "$TMP/release-receipt-writer" 'mv -fT -- "$temporary" "$receipt"' \
    'sync -f "$run_dir"' 'verify_release_receipt prepared allow-missing' \
    'write_release_sidecar "$run_dir"' 'verify_release_receipt prepared required'
function_body verify_release_receipt "$ROOT/release_transaction_inhibitors.sh" \
    > "$TMP/release-receipt-verifier"
for required in '"$(file_sha "$receipt")" == "$actual"' \
    '"$(file_sha "$RESULT_PATH")" == "$result_sha"' \
    '"$(file_sha "$FINALIZATION_PATH")" == "$finalization_sha"' \
    'prepared_release_window_is_fresh'; do
    grep -Fq -- "$required" "$TMP/release-receipt-verifier"
done
for consumer in "$ROOT/fleet_soak_audit.sh" "$ROOT/fleet_rollout.sh"; do
    grep -Fq '.receipt_published_before_pause_removal == true' "$consumer"
    grep -Fq '.release_protocol == "write-ahead-v1"' "$consumer"
done
function_body prepared_release_window_is_fresh "$ROOT/release_transaction_inhibitors.sh" \
    > "$TMP/prepared-release-window"
(
    eval "$(<"$TMP/prepared-release-window")"
    prepared_release_window_is_fresh 200 201 250
    ! prepared_release_window_is_fresh 200 201 501
    ! prepared_release_window_is_fresh 200 199 250
    ! prepared_release_window_is_fresh nope 201 250
)
function_body write_rollback_post_release_evidence "$ROOT/fleet_rollout.sh" \
    > "$TMP/rollback-post-release"
assert_order "$TMP/rollback-post-release" 'verify_all_baseline_runtime_once' \
    'capture_rollback_chain_convergence' 'verify_all_baseline_runtime_once' \
    'capture_exact_32_generation_map "$staging/GENERATIONS.after"'
REALPATH_BIN=$(command -v realpath)
for validator_source in fleet_rollout.sh release_transaction_inhibitors.sh; do
    function_body validate_preserved_hour_paths "$ROOT/$validator_source" \
        > "$TMP/validate-preserved-hour-paths"
    (
        eval "$(<"$TMP/validate-preserved-hour-paths")"
        realpath()
        {
            if [[ "$1" == -e && "$2" == -- ]]; then
                "$REALPATH_BIN" "$3"
            else
                "$REALPATH_BIN" "$@"
            fi
        }
        hash=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        audit="$TMP/hour-audit-${validator_source%.sh}"
        mkdir -p "$audit/sample-001/nodes"
        : > "$audit/RESULT.json"
        : > "$audit/sample-001/node-01.json"
        : > "$audit/sample-001/nodes/node-02.json"
        printf '%s  %s\n' "$hash" ./RESULT.json "$hash" ./sample-001/node-01.json \
            "$hash" ../HOUR-SOAK-DIRECTORIES > "$TMP/hour-manifest.valid"
        printf '%s\n' ./sample-001 ./sample-001/nodes > "$TMP/hour-directories.valid"
        validate_preserved_hour_paths "$audit" "$TMP/hour-manifest.valid" \
            "$TMP/hour-directories.valid"

        rm -rf -- "$audit/sample-001/nodes"
        ! validate_preserved_hour_paths "$audit" "$TMP/hour-manifest.valid" \
            "$TMP/hour-directories.valid"
        mkdir -p "$audit/sample-001/nodes"
        : > "$audit/sample-001/nodes/node-02.json"

        printf '%s  %s\n' "$hash" ./RESULT.json "$hash" ./sample-001/nodes/node-02.json \
            "$hash" ../HOUR-SOAK-DIRECTORIES > "$TMP/hour-manifest.nested"
        printf '%s\n' ./sample-001 > "$TMP/hour-directories.omitted-ancestor"
        ! validate_preserved_hour_paths "$audit" "$TMP/hour-manifest.nested" \
            "$TMP/hour-directories.omitted-ancestor"

        cp "$TMP/hour-manifest.valid" "$TMP/hour-manifest.escape"
        printf '%s  %s\n' "$hash" ./sample-001/../escape.json >> "$TMP/hour-manifest.escape"
        ! validate_preserved_hour_paths "$audit" "$TMP/hour-manifest.escape" \
            "$TMP/hour-directories.valid"

        cp "$TMP/hour-manifest.valid" "$TMP/hour-manifest.duplicate"
        printf '%s  %s\n' "$hash" ./RESULT.json >> "$TMP/hour-manifest.duplicate"
        ! validate_preserved_hour_paths "$audit" "$TMP/hour-manifest.duplicate" \
            "$TMP/hour-directories.valid"

        printf '%s\n' ./sample-001 ./sample-001 > "$TMP/hour-directories.duplicate"
        ! validate_preserved_hour_paths "$audit" "$TMP/hour-manifest.valid" \
            "$TMP/hour-directories.duplicate"

        awk() { return 2; }
        ! validate_preserved_hour_paths "$audit" "$TMP/hour-manifest.valid" \
            "$TMP/hour-directories.valid"
    )
done
hash=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
jq -n --arg image 'registry.example/blackcoin@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
    --arg image_id 'sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
    --arg source 13262151077cce3f72d07d17dc7725b2b6a8e1ab \
    '{candidate_image:$image,candidate_image_id:$image_id,source_commit:$source}' \
    > "$TMP/hour-transaction.json"
jq -n --slurpfile transaction "$TMP/hour-transaction.json" --arg hash "$hash" '
    {schema:1,result:"passed",image:$transaction[0].candidate_image,
     image_id:$transaction[0].candidate_image_id,source_commit:$transaction[0].source_commit,
     duration_seconds:3600,total_sample_rounds:4,nodes_healthy:32,pos_active:32,
     regular_pow_active:31,free_claim_node:30,free_claim_regular_pow:false,
     free_claim_broadcasts_paused:true,claim_recovery_fee_unchanged:true,
     fee_payments_authorized:false,quantum_special_nodes:[31,32],vpn_proofs_valid_unique:32,
     final_concurrent_dynamic_gate:true,global_chain_convergence:true,
     final_exact_32_generation_fence:true,external_supervisors_maintenance_inhibited:true,
     supervisor_freshness_deferred_to_finalization:true,replay_state_schema:12,
     replay_state_valid_nodes:32,donation_defaults_off_nodes:32,
     activation_wallet_transaction_sets_unchanged:true,wallet_transaction_guard_unchanged_nodes:32,
     claim_recovery_baseline_sha256s:
       (reduce range(1;33) as $n ({};
         .[($n|tostring|if length == 1 then "0" + . else . end)]=$hash)),
     claim_recovery_baseline_set_sha256:$hash}
' > "$TMP/hour-result.valid.json"
jq -e --slurpfile transaction "$TMP/hour-transaction.json" \
    -f "$ROOT/lib/hour_soak_result.jq" "$TMP/hour-result.valid.json" >/dev/null
jq '.wallet_transaction_guard_unchanged_nodes=31' "$TMP/hour-result.valid.json" \
    > "$TMP/hour-result.bad-field.json"
! jq -e --slurpfile transaction "$TMP/hour-transaction.json" \
    -f "$ROOT/lib/hour_soak_result.jq" "$TMP/hour-result.bad-field.json" >/dev/null
jq '.claim_recovery_baseline_sha256s |= del(."32")' "$TMP/hour-result.valid.json" \
    > "$TMP/hour-result.bad-keys.json"
! jq -e --slurpfile transaction "$TMP/hour-transaction.json" \
    -f "$ROOT/lib/hour_soak_result.jq" "$TMP/hour-result.bad-keys.json" >/dev/null
jq '.duration_seconds="nope"' "$TMP/hour-result.valid.json" \
    > "$TMP/hour-result.bad-duration-type.json"
! jq -e --slurpfile transaction "$TMP/hour-transaction.json" \
    -f "$ROOT/lib/hour_soak_result.jq" "$TMP/hour-result.bad-duration-type.json" >/dev/null
jq '.total_sample_rounds=4.5' "$TMP/hour-result.valid.json" \
    > "$TMP/hour-result.bad-sample-fraction.json"
! jq -e --slurpfile transaction "$TMP/hour-transaction.json" \
    -f "$ROOT/lib/hour_soak_result.jq" "$TMP/hour-result.bad-sample-fraction.json" >/dev/null
pass crash-safe-supervisor-fresh-finalization-and-rollback-release-order

function_body commit_target_config "$ROOT/repair_vpn_pair.sh" > "$TMP/vpn-commit"
assert_order "$TMP/vpn-commit" 'mv -fT -- "$temporary" "$CONF"' \
    'CONFIG_COMMITTED=1' 'sync -f "${CONF%/*}"'
function_body rollback_config_and_contain "$ROOT/repair_vpn_pair.sh" > "$TMP/vpn-rollback"
for required in 'sha256sum "$CONFIG_BACKUP"' 'sha256sum "$CONF"' \
    'stat -c '\''%u:%g:%a'\'' "$CONF"' 'restore_ok == 1 && contain_ok == 1' \
    'FAILURE_REQUIRES_OPERATOR'; do
    grep -Fq -- "$required" "$TMP/vpn-rollback"
done
grep -Fq 'proof_is_unique || die' "$ROOT/repair_vpn_pair.sh"
pass vpn-commit-rollback-and-final-uniqueness

[[ "$(grep -Fc '.policy.automatic_authorized == false' "$ROOT/lib/live_checks.sh")" -ge 2 ]]
grep -Fq 'verify_candidate_recovery_baseline "$node"' "$ROOT/fleet_rollout.sh"
grep -Fq 'validate_recovery_baseline "$node"' "$ROOT/fleet_soak_audit.sh"
grep -Fq 'claim_recovery_fee_unchanged:true' "$ROOT/fleet_soak_audit.sh"
function_body verify_policy_runtime_node "$ROOT/fleet_rollout.sh" > "$TMP/policy-runtime-wrapper"
grep -Fq 'verify_policy_legacy_runtime_gate "$node" "$baseline"' "$TMP/policy-runtime-wrapper"
grep -Fq 'verify_policy_compatible_runtime_gate "$NODE" "$RECOVERY_FEE_BASELINE"' \
    "$ROOT/recover_clean_guard_stop.sh"
grep -Fq 'verify_policy_compatible_runtime_gate "$NODE" "$RECOVERY_FEE_BASELINE"' \
    "$ROOT/repair_vpn_pair.sh"
pass fee-baseline-no-automatic-recovery-and-full-runtime-gates

! grep -Fq -- '--force-recreate' "$ROOT/fleet_rollout.sh"
function_body ensure_candidate_stopped_container "$ROOT/fleet_rollout.sh" \
    > "$TMP/candidate-replacement"
assert_order "$TMP/candidate-replacement" \
    'verify_sealed_wave_evidence_files' \
    'verify_local_image_reference_identity "$CANDIDATE_IMAGE_REF" "$CANDIDATE_IMAGE_ID"' \
    'docker rm "$source_id"' \
    '[[ "$state" == absent-after-authorized-replacement ]]'
grep -Fq 'up --no-start --no-deps' "$TMP/candidate-replacement"
grep -Fq -- '--no-recreate --no-build --pull never "$service"' "$TMP/candidate-replacement"

function_body start_wave_candidate "$ROOT/fleet_rollout.sh" > "$TMP/start-candidate"
assert_order "$TMP/start-candidate" \
    'verify_candidate_stopped_container_contract "$node" "$candidate_generation"' \
    'publish_candidate_launch_attempt_marker "$node"' \
    'verify_sealed_wave_evidence_files' \
    'data_rollback_require_mutation_fences' \
    'docker start "$candidate_id"' \
    'verify_candidate_running_container "$node" "$candidate_id"'
function_body verify_candidate_running_container "$ROOT/fleet_rollout.sh" \
    > "$TMP/candidate-running"
for required in '.[0].Id == $id' '.[0].Name == $name' \
    '.[0].Config.Image == $image' '.[0].Image == $image_id' \
    '.[0].State.Running == true' \
    'verify_candidate_present_exclusive "$node" "$generation" "$source_generation" true'; do
    grep -Fq -- "$required" "$TMP/candidate-running"
done

function_body ensure_rollback_old_image_node "$ROOT/fleet_rollout.sh" \
    > "$TMP/old-image-replacement"
[[ "$(grep -Fc 'docker rm "$removal_id"' "$TMP/old-image-replacement")" -eq 2 ]]
grep -Fq 'up --no-start --no-deps' "$TMP/old-image-replacement"
grep -Fq -- '--no-recreate --no-build --pull never "$service"' "$TMP/old-image-replacement"
grep -Fq 'docker start "$selected_id"' "$TMP/old-image-replacement"
function_body classify_rollback_old_image_node "$ROOT/fleet_rollout.sh" \
    > "$TMP/old-image-classifier"
for state in wrong-stopped-after-authorized-recreate old-stopped old-running; do
    grep -Fq "$state" "$TMP/old-image-classifier"
done
function_body verify_candidate_replacement_restart_policy "$ROOT/fleet_rollout.sh" \
    > "$TMP/candidate-restart-policy"
grep -Fq 'assert_marker_state "$rollback_state" rollback-started' \
    "$TMP/candidate-restart-policy"
grep -Fq '.[0].HostConfig.RestartPolicy.Name == "no"' \
    "$TMP/candidate-restart-policy"
[[ "$(grep -Fc '.[0].HostConfig.RestartPolicy.Name == "on-failure"' \
    "$TMP/candidate-restart-policy")" -eq 2 ]]
for function_name in absent_target_state_safe rollback_absent_target_state_safe; do
    function_body "$function_name" "$ROOT/fleet_rollout.sh" > "$TMP/$function_name"
    [[ "$(grep -Fc '! docker container inspect' "$TMP/$function_name")" -eq 6 ]]
    for required in 'docker ps -aq --no-trunc' '.Mounts[]?' '/proc/[0-9]*' \
        'process/ns/net' 'process/cmdline' 'process/cwd' 'process"/fd/*' 'process/cgroup' \
        'verify_rollback_vpn_generation'; do
        grep -Fq -- "$required" "$TMP/$function_name"
    done
done
pass exact-id-no-force-container-replacement-and-absence-proof

function_body write_wave_candidate_source_inventory "$ROOT/fleet_rollout.sh" \
    > "$TMP/source-inventory-write"
for required in 'container_generation_for "$node"' 'docker inspect "$(container_for "$node")"' \
    '.[0].State.Running == true' 'atomic_write_json "$path"' \
    'verify_wave_candidate_source_inventory'; do
    grep -Fq -- "$required" "$TMP/source-inventory-write"
done
function_body verify_wave_candidate_source_inventory "$ROOT/fleet_rollout.sh" \
    > "$TMP/source-inventory-verify"
grep -Fq 'local wave_dir="${1:-$CURRENT_WAVE_DIR}"' "$TMP/source-inventory-verify"
grep -Fq 'local CURRENT_WAVE_DIR="$wave_dir"' "$TMP/source-inventory-verify"
function_body write_wave_evidence_manifest "$ROOT/fleet_rollout.sh" > "$TMP/wave-manifest-new"
assert_order "$TMP/wave-manifest-new" 'candidate-launch-sources.json' \
    'write_wave_candidate_source_inventory' 'sha256sum "${files[@]}"'
function_body verify_wave_evidence_manifest "$ROOT/fleet_rollout.sh" \
    > "$TMP/wave-manifest-verify"
grep -Fq 'verify_wave_candidate_source_inventory "$wave_dir"' "$TMP/wave-manifest-verify"

function_body verify_prelaunch_candidate_authorization_prefix "$ROOT/fleet_rollout.sh" \
    > "$TMP/partial-launch-authority"
for required in 'actual_count=$(find' '((actual_count == 0)) || require_stopped=true' \
    'verify_prelaunch_source_node "$node" "$require_stopped"' \
    '$(expected_prelaunch_generation "$node")' '[[ "$actual_count" -eq "$count" ]]'; do
    grep -Fq -- "$required" "$TMP/partial-launch-authority"
done
function_body recover_wave_drain_evidence_prefix "$ROOT/fleet_rollout.sh" \
    > "$TMP/drain-prefix"
assert_order "$TMP/drain-prefix" \
    'data_rollback_protected_file "$commit_state" 600' \
    'assert_marker_state "$commit_state" rollback-boundary-established' \
    '[[ "$(live_wave_triplet_state)" == before ]]' \
    '[[ ! -e "$CURRENT_WAVE_DIR/CANDIDATE_LAUNCH_AUTHORIZED"' \
    'verify_prelaunch_source_node "$node" false' \
    'stop_wave_cleanly'
function_body write_wave_drain_evidence "$ROOT/fleet_rollout.sh" > "$TMP/drain-write"
assert_order "$TMP/drain-write" 'if [[ -e "$plan" || -L "$plan" ]]' \
    'publish_wave_drain_evidence_manifest'

function_body live_wave_triplet_state "$ROOT/fleet_rollout.sh" > "$TMP/triplet-state"
for state in 'printf '\''%s\n'\'' before' 'printf '\''%s\n'\'' candidate' \
    'printf '\''%s\n'\'' mixed'; do
    grep -Fq "$state" "$TMP/triplet-state"
done
function_body recover_no_launch_triplet_for_rollback "$ROOT/fleet_rollout.sh" \
    > "$TMP/triplet-recovery"
for required in 'rollback-boundary-established)' '[[ "$live_state" == before ]]' \
    'commit-started|committed)' 'data_rollback_require_mutation_fences' \
    'install_triplet "$CURRENT_WAVE_DIR/docker-compose.before.yml"'; do
    grep -Fq -- "$required" "$TMP/triplet-recovery"
done
function_body publish_rollback_old_image_authority "$ROOT/fleet_rollout.sh" \
    > "$TMP/old-image-authority"
for required in 'live_triplet_state=candidate' 'live_triplet_state=before' \
    'live_triplet_state_at_authorization:$live_triplet_state' \
    'before_triplet:{compose_sha256:$before_compose_sha' \
    'candidate_triplet:{compose_sha256:$candidate_compose_sha'; do
    grep -Fq -- "$required" "$TMP/old-image-authority"
done
pass sealed-source-drain-triplet-and-rollback-authority-recovery

function_body establish_candidate_recovery_baseline "$ROOT/fleet_rollout.sh" \
    > "$TMP/baseline-establish"
assert_order "$TMP/baseline-establish" \
    'sync -f "$txids_tmp"' \
    'mv -fT -- "$txids_tmp" "$txids_after"' \
    'sync -f "$CURRENT_WAVE_DIR"' \
    'mv -fT -- "$temporary" "$path"' \
    'sync -f "${path%/*}"' \
    'mv -fT -- "$metadata_tmp" "$metadata"' \
    'sync -f "${path%/*}"'
! grep -Fq 'rm -f -- "$path"' "$TMP/baseline-establish"
function_body recover_candidate_recovery_baseline_prefix "$ROOT/fleet_rollout.sh" \
    > "$TMP/baseline-recover"
for required in 'verify_candidate_recovery_baseline_digest "$node"' \
    'verify_candidate_recovery_baseline_payload "$node"' \
    'reprove_candidate_recovery_baseline_live_state "$node" "$txids_tmp"' \
    'mv -fT -- "$txids_tmp" "$first"' 'mv -T -- "$metadata_tmp" "$metadata"' \
    'verify_candidate_recovery_baseline "$node"'; do
    grep -Fq -- "$required" "$TMP/baseline-recover"
done
function_body reprove_candidate_recovery_baseline_live_state "$ROOT/fleet_rollout.sh" \
    > "$TMP/baseline-reprove"
for required in 'verify_candidate_running_container "$node" "$expected_id"' \
    '.unlocked_until == 0' '.enabled == false and .autostart == false' \
    '.enabled == false and .staking == false' 'verify_donation_defaults_off "$node"' \
    '.policy_authoritative == true and .policy.automatic_authorized == false' \
    '[[ "$current_fee" == "$expected_fee" ]]' 'cmp -s "$prelaunch" "$txids_output"' \
    '[[ "$(container_generation_for "$node")" == "$generation" ]]'; do
    grep -Fq -- "$required" "$TMP/baseline-reprove"
done
function_body verify_candidate_recovery_baseline_payload "$ROOT/fleet_rollout.sh" \
    > "$TMP/baseline-payload"
grep -Fq '.staking_final.enabled == false' "$TMP/baseline-payload"
pass crash-resumable-candidate-recovery-baseline-publication

function_body require_host_tools "$ROOT/fleet_rollout.sh" > "$TMP/host-tools"
grep -Fq 'Bash 5.1 or newer is required' "$TMP/host-tools"
grep -Fq 'docker compose up --help' "$TMP/host-tools"
for option in --no-start --no-deps --no-recreate --no-build --pull; do
    grep -Fq -- "$option" "$TMP/host-tools"
done
for function_name in establish_wave_recovery_baselines activate_wave_phase \
    contain_wave_without_rollback; do
    function_body "$function_name" "$ROOT/fleet_rollout.sh" > "$TMP/$function_name"
    grep -Fq 'wait -n -p completed_pid "${active_pids[@]}"' "$TMP/$function_name"
    grep -Fq '((${#active_pids[@]} == remaining))' "$TMP/$function_name"
    grep -Fq 'completed_pid=' "$TMP/$function_name"
    grep -Fq "trap '" "$TMP/$function_name"
done
grep -Fq "trap 'launch_signal=129' HUP" "$TMP/establish_wave_recovery_baselines"
grep -Fq "trap 'launch_signal=129' HUP" "$TMP/activate_wave_phase"
grep -Fq "trap 'signal_received=129' HUP" "$TMP/contain_wave_without_rollback"
assert_order "$TMP/establish_wave_recovery_baselines" 'pid=$!' \
    'CANDIDATE_BASELINE_HELPER_PIDS+=("$pid")' '((launch_signal == 0)) || break' \
    'terminate_and_join_candidate_baseline_helpers'
assert_order "$TMP/activate_wave_phase" 'pid=$!' \
    'ACTIVATION_HELPER_PIDS+=("$pid")' '((launch_signal == 0)) || break' \
    'terminate_and_join_activation_helpers'
assert_order "$TMP/contain_wave_without_rollback" 'pid=$!' \
    'CONTAINMENT_HELPER_PIDS+=("$pid")' '((signal_received == 0)) || break' \
    'terminate_and_join_containment_helpers'
for function_name in terminate_and_join_candidate_baseline_helpers \
    terminate_and_join_activation_helpers terminate_and_join_containment_helpers; do
    function_body "$function_name" "$ROOT/fleet_rollout.sh" > "$TMP/$function_name"
    grep -Fq 'kill -TERM -- "-$pid"' "$TMP/$function_name"
    grep -Fq 'kill -KILL -- "-$pid"' "$TMP/$function_name"
    grep -Fq 'wait "$pid"' "$TMP/$function_name"
    [[ "$(grep -Fc 'deadline=$((SECONDS + 5))' "$TMP/$function_name")" -eq 1 ]]
    [[ "$(grep -Fc "_PIDS[index]=''" "$TMP/$function_name")" -ge 3 ]]
    ! grep -Fq 'kill -TERM "$pid"' "$TMP/$function_name"
    ! grep -Fq 'kill -KILL "$pid"' "$TMP/$function_name"
done
function_body on_exit "$ROOT/fleet_rollout.sh" > "$TMP/rollout-exit"
assert_order "$TMP/rollout-exit" 'terminate_and_join_containment_helpers' \
    'terminate_and_join_candidate_baseline_helpers' 'terminate_and_join_activation_helpers' \
    'rollback_current_wave'
grep -Fq 'trap - EXIT HUP INT TERM' "$TMP/rollout-exit"
function_body rollback_current_wave "$ROOT/fleet_rollout.sh" > "$TMP/wave-rollback-workers"
assert_order "$TMP/wave-rollback-workers" 'terminate_and_join_containment_helpers' \
    'terminate_and_join_candidate_baseline_helpers' 'publish_state_token'
function_body stop_wave_for_rollback "$ROOT/fleet_rollout.sh" > "$TMP/stop-wave-workers"
assert_order "$TMP/stop-wave-workers" 'terminate_and_join_activation_helpers' \
    'docker inspect'
function_body publish_wave_activation_markers "$ROOT/fleet_rollout.sh" \
    > "$TMP/activation-publication"
grep -Fq '((${#CANDIDATE_BASELINE_HELPER_PIDS[@]} == 0))' "$TMP/activation-publication"
grep -Fq '((${#ACTIVATION_HELPER_PIDS[@]} == 0))' "$TMP/activation-publication"
function_body publish_complete_containment_manifest "$ROOT/fleet_rollout.sh" \
    > "$TMP/containment-publication"
grep -Fq '((${#CONTAINMENT_HELPER_PIDS[@]} == 0))' "$TMP/containment-publication"
function_body activate_one_node_phase "$ROOT/fleet_rollout.sh" > "$TMP/activation-worker"
grep -Fq "trap 'cleanup_activation_child; exit 129' HUP" "$TMP/activation-worker"
grep -Fq 'trap - HUP INT TERM' "$TMP/activation-worker"
function_body write_terminal_receipt "$ROOT/fleet_rollout.sh" > "$TMP/terminal-receipt-signals"
grep -Fq "trap '' HUP INT TERM" "$TMP/terminal-receipt-signals"
grep -Fq "trap 'exit 129' HUP" "$TMP/terminal-receipt-signals"
function_body run_one_wave "$ROOT/fleet_rollout.sh" > "$TMP/run-wave-signals"
grep -Fq "trap '' HUP INT TERM" "$TMP/run-wave-signals"
grep -Fq "trap 'exit 129' HUP" "$TMP/run-wave-signals"
for function_name in apply_rollout rollback_run; do
    function_body "$function_name" "$ROOT/fleet_rollout.sh" > "$TMP/$function_name"
    grep -Fq "trap 'exit 129' HUP" "$TMP/$function_name"
    grep -Fq 'trap - EXIT HUP INT TERM' "$TMP/$function_name"
done
timeout_files=("$ROOT/fleet_rollout.sh" "$ROOT/lib/common.sh" "$ROOT/lib/live_checks.sh" \
    "$ROOT/blackcoin_pow_quarantine_cycle_v30.1.4_nospend.sh" \
    "$ROOT/repair_vpn_pair.sh" "$ROOT/recover_clean_guard_stop.sh")
! grep -E 'timeout[[:space:]]+(-k|--kill-after|--signal)' "${timeout_files[@]}"
[[ "$(grep -hEc 'timeout[[:space:]]+--foreground' "${timeout_files[@]}" | \
    awk '{total += $1} END {print total}')" -ge 17 ]]
pass joined-process-group-workers-hup-and-nested-timeout-containment

function_body verify_canary_fleet_handoff "$ROOT/fleet_rollout.sh" \
    > "$TMP/canary-handoff-verify"
for required in 'if [[ "$verify_live" == 1 ]]' \
    '.published_canary.sha256' '.published_canary.evidence_manifest.sha256' \
    '[[ "$result_sha" == "$EXPECTED_CANARY_RESULT_SHA256"' \
    'marker_sha=$(jq -n --arg nonce "$fleet_nonce" --arg run "$RUN_DIR"'; do
    grep -Fq -- "$required" "$TMP/canary-handoff-verify"
done
function_body publish_canary_fleet_handoff "$ROOT/fleet_rollout.sh" \
    > "$TMP/canary-handoff-publish"
assert_order "$TMP/canary-handoff-publish" 'verify_canary_fleet_handoff 0' \
    'verify_maintenance_marker'
for required in 'sha256sum "$PUBLISHED_CANARY_RESULT"' \
    'sha256sum "$PUBLISHED_CANARY_EVIDENCE_MANIFEST"' \
    'atomic_write_json "$evidence"'; do
    grep -Fq -- "$required" "$TMP/canary-handoff-publish"
done
function_body write_transaction_manifest "$ROOT/fleet_rollout.sh" \
    > "$TMP/transaction-manifest"
assert_order "$TMP/transaction-manifest" \
    'canary_sha=$(sha256sum "$PUBLISHED_CANARY_RESULT"' \
    '[[ "$canary_sha" == "$EXPECTED_CANARY_RESULT_SHA256"' \
    'install -m 600 -o root -g root "$temporary" "$RUN_DIR/TRANSACTION.json"' \
    'sync -f "$RUN_DIR/TRANSACTION.json"'
pass offline-canary-handoff-and-transaction-identity-pinning

function_body assert_fleet_identity_matches_baseline "$ROOT/fleet_rollout.sh" > "$TMP/identity"
for field in wallets_json legacy_addresses_sha256 quantum_addresses_sha256 \
    quantum_inventory_sha256 runtime_manifest_sha256 identity_manifest_sha256 \
    pow_manifest_sha256 blackcoin_conf_sha256 settings_json_sha256 vpn_id; do
    grep -Fq "$field" "$TMP/identity"
done
function_body apply_rollout "$ROOT/fleet_rollout.sh" > "$TMP/apply-rollout"
assert_order "$TMP/apply-rollout" 'assert_fleet_identity_matches_baseline' \
    'publish_state_token "$RUN_DIR/STATE" complete' 'finalize_completed_rollout'
function_body rollback_run "$ROOT/fleet_rollout.sh" > "$TMP/rollback-run"
assert_order "$TMP/rollback-run" 'assert_fleet_identity_matches_baseline' \
    'write_rollback_success_evidence' 'publish_state_token "$RUN_DIR/STATE" rolled-back'
grep -Fq 'emergency-contain' "$TMP/rollback-run"
function_body write_wave_evidence_manifest "$ROOT/fleet_rollout.sh" > "$TMP/wave-manifest"
for evidence in NODES unaffected.before docker-compose.before.yml fleet-image-policy.before.json \
    blackcoin_endpoint_guard.before.sh docker-compose.candidate.yml \
    fleet-image-policy.candidate.json blackcoin_endpoint_guard.candidate.sh WAVE-IDENTITY.json; do
    grep -Fq "$evidence" "$TMP/wave-manifest"
done
function_body run_one_wave "$ROOT/fleet_rollout.sh" > "$TMP/run-wave"
grep -Fq 'mktemp -d "$RUN_DIR/.pre-wave-' "$TMP/run-wave"
assert_order "$TMP/run-wave" 'write_wave_evidence_manifest "$wave_index"' \
    'mv -- "$CURRENT_WAVE_DIR" "$canonical"' 'CURRENT_WAVE_COMMITTED=1'
pass identity-wave-evidence-and-precommit-publication

mutation_files=("$ROOT/fleet_rollout.sh" "$ROOT/fleet_soak_audit.sh" \
    "$ROOT/repair_vpn_pair.sh" "$ROOT/recover_clean_guard_stop.sh" "$ROOT/lib/common.sh" \
    "$ROOT/lib/live_checks.sh")
! grep -E 'docker[[:space:]]+pull|--pull[[:space:]]+always|resolveallshadowpowclaims|getnew(address|quantumaddress)|abandontransaction|settxfee' \
    "${mutation_files[@]}"
! grep -E -- "(^|[[:space:]\"'])(-reindex|-reindex-chainstate)(=|[[:space:]\"']|$)" \
    "${mutation_files[@]}"
grep -Fq 'docker build --pull=false --network=none --no-cache' "$ROOT/image-build/build_release_image.sh"
grep -Fq 'install -d -m 755 -o root -g root "$BINARIES"' \
    "$ROOT/image-build/build_release_image.sh"
grep -Fq "readonly BASE_IMAGE_REF='qqblackcoin/blackcoin-v4-gui:30.1.1-alpha1-a6dba4b5a8e6716dd7e6e859a840de2a584d8d87'" \
    "$ROOT/image-build/build_release_image.sh"
grep -Fq "readonly BASE_BUILD_REF='blackcoin-ops-base:alpha1-8670d7f4fd03'" \
    "$ROOT/image-build/build_release_image.sh"
grep -Fq "readonly BASE_IMAGE_ID='sha256:8670d7f4fd03831426a4e2052e7328d71a5e559bc561ab9a584a737f05dc403e'" \
    "$ROOT/image-build/build_release_image.sh"
grep -Fq 'readonly REPLAY_SCHEMA=12' "$ROOT/image-build/build_release_image.sh"
! grep -Eq 'readonly (BASE_IMAGE_REF|BASE_BUILD_REF|BASE_IMAGE_ID|REPLAY_SCHEMA)=.*\$\{' \
    "$ROOT/image-build/build_release_image.sh"
grep -Fq 'printf '\''FROM %s\n\n'\'' "$BASE_BUILD_REF"' "$ROOT/image-build/build_release_image.sh"
grep -Fq 'blackcoin-ops-base:alpha1-8670d7f4fd03' "$ROOT/image-build/build_release_image.sh"
grep -Fq 'base_build_ref:$base_build_ref' "$ROOT/image-build/build_release_image.sh"
grep -Fq 'base_image_id:$base_id,replay_schema:$replay_schema' \
    "$ROOT/image-build/build_release_image.sh"
[[ "$(grep -Fc 'base_image_ref:$base_ref,base_build_ref:$base_build_ref' \
    "$ROOT/image-build/build_release_image.sh")" -eq 2 ]]
[[ "$(grep -Fc 'base_image_id:$base_id,replay_schema:$replay_schema' \
    "$ROOT/image-build/build_release_image.sh")" -eq 2 ]]
grep -Fq '"$BASE_BUILD_REF" != *:latest' "$ROOT/image-build/build_release_image.sh"
[[ "$(grep -Fc "docker image inspect -f '{{.Id}}' \"\$BASE_BUILD_REF\"" \
    "$ROOT/image-build/build_release_image.sh")" -ge 3 ]]
grep -Fq 'probe_binary_version "$BASE_IMAGE_REF" "/candidate/$binary"' \
    "$ROOT/image-build/build_release_image.sh"
grep -Fq 'probe_binary_version "$TARGET_IMAGE_REF" "/usr/local/bin/$binary"' \
    "$ROOT/image-build/build_release_image.sh"
function_body probe_binary_version "$ROOT/image-build/build_release_image.sh" > "$TMP/version-probe"
for required in 'Xvfb :99 -screen 0 640x480x24' \
    'while [ ! -S /tmp/.X11-unix/X99 ]' 'DISPLAY=:99 QT_QPA_PLATFORM=xcb' \
    '--network none --read-only --user blackcoin --cap-drop ALL' \
    "--tmpfs '/tmp:rw,noexec,nosuid,nodev,mode=1777'"; do
    grep -Fq -- "$required" "$TMP/version-probe"
done
! grep -Fq 'QT_QPA_PLATFORM=minimal' "$ROOT/image-build/build_release_image.sh"
[[ "$(grep -Fc -- '--user blackcoin' "$ROOT/image-build/build_release_image.sh")" -eq 3 ]]
grep -Fq '.Config.User == "blackcoin"' "$ROOT/image-build/build_release_image.sh"
grep -Fq "SOURCE_COMMIT='13262151077cce3f72d07d17dc7725b2b6a8e1ab'" \
    "$ROOT/image-build/build.env.example"
grep -Fq 'EXPECTED_SOURCE_COMMIT=13262151077cce3f72d07d17dc7725b2b6a8e1ab' \
    "$ROOT/image-build/publish_release_image.sh"
for expected in \
    "readonly EXPECTED_BASE_IMAGE_REF='qqblackcoin/blackcoin-v4-gui:30.1.1-alpha1-a6dba4b5a8e6716dd7e6e859a840de2a584d8d87'" \
    "readonly EXPECTED_BASE_BUILD_REF='blackcoin-ops-base:alpha1-8670d7f4fd03'" \
    "readonly EXPECTED_BASE_IMAGE_ID='sha256:8670d7f4fd03831426a4e2052e7328d71a5e559bc561ab9a584a737f05dc403e'" \
    'readonly EXPECTED_REPLAY_SCHEMA=12' \
    '.base_image_ref == $base_ref and .base_build_ref == $base_build_ref' \
    '.base_image_id == $base_id and .replay_schema == $replay_schema' \
    '.Config.Labels["org.blackcoin.base.image.id"] == $base_id' \
    '.Config.Labels["org.blackcoin.replay.schema"] == $replay_schema' \
    '.config.Labels["org.blackcoin.base.image.id"] == $base_id' \
    '.config.Labels["org.blackcoin.replay.schema"] == $replay_schema' \
    '.rootfs.diff_ids == $sealed[0][0].RootFS.Layers'; do
    grep -Fq -- "$expected" "$ROOT/image-build/publish_release_image.sh"
done
[[ "$(grep -Fc '.base_image_ref == $base_ref and .base_build_ref == $base_build_ref' \
    "$ROOT/image-build/publish_release_image.sh")" -eq 2 ]]
[[ "$(grep -Fc '.base_image_id == $base_id and .replay_schema == $replay_schema' \
    "$ROOT/image-build/publish_release_image.sh")" -eq 2 ]]
grep -Fq "TARGET_IMAGE_REF='qqblackcoin/blackcoin-v4-gui:30.1.4-final-13262151077c-ops1'" \
    "$ROOT/image-build/build.env.example"
grep -Fq "DOCKER_SERVER_PLATFORM\" == linux/amd64" "$ROOT/image-build/build_release_image.sh"
grep -Fq -- '--location -D "$headers"' "$ROOT/image-build/publish_release_image.sh"
! grep -Fq -- '--location-trusted' "$ROOT/image-build/publish_release_image.sh"
pass forbidden-operation-and-build-invariants

cat > "$TMP/build-inputs.json" <<'EOF'
{
  "base_image_ref":"qqblackcoin/blackcoin-v4-gui:30.1.1-alpha1-a6dba4b5a8e6716dd7e6e859a840de2a584d8d87",
  "base_build_ref":"blackcoin-ops-base:alpha1-8670d7f4fd03",
  "base_image_id":"sha256:8670d7f4fd03831426a4e2052e7328d71a5e559bc561ab9a584a737f05dc403e",
  "replay_schema":"12"
}
EOF
build_base_contract()
{
    jq -e \
        --arg base_ref 'qqblackcoin/blackcoin-v4-gui:30.1.1-alpha1-a6dba4b5a8e6716dd7e6e859a840de2a584d8d87' \
        --arg base_build_ref 'blackcoin-ops-base:alpha1-8670d7f4fd03' \
        --arg base_id 'sha256:8670d7f4fd03831426a4e2052e7328d71a5e559bc561ab9a584a737f05dc403e' \
        --arg replay_schema '12' '
        .base_image_ref == $base_ref and .base_build_ref == $base_build_ref and
        .base_image_id == $base_id and .replay_schema == $replay_schema
    ' "$1" >/dev/null
}
build_base_contract "$TMP/build-inputs.json"
for mutation in \
    '.base_image_ref = "registry.example/wrong:base"' \
    '.base_build_ref = "wrong-local:base"' \
    '.base_image_id = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' \
    '.replay_schema = "13"'; do
    jq "$mutation" "$TMP/build-inputs.json" > "$TMP/build-inputs-mutated.json"
    ! build_base_contract "$TMP/build-inputs-mutated.json"
done

path_write_safe()
{
    local path mode
    while IFS= read -r -d '' path; do
        if [[ "$(uname -s)" == Darwin ]]; then
            mode=$(stat -f '%Lp' "$path") || return 1
        else
            mode=$(stat -c '%a' "$path") || return 1
        fi
        [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
        (( (8#$mode & 0022) == 0 )) || return 1
    done < <(find "$1" -print0)
}
install -d -m 700 "$TMP/package-mode-fixture/nested"
install -m 600 /dev/null "$TMP/package-mode-fixture/nested/file"
path_write_safe "$TMP/package-mode-fixture"
chmod 620 "$TMP/package-mode-fixture/nested/file"
! path_write_safe "$TMP/package-mode-fixture"
chmod 600 "$TMP/package-mode-fixture/nested/file"
chmod 720 "$TMP/package-mode-fixture/nested"
! path_write_safe "$TMP/package-mode-fixture"
for script in image-build/build_release_image.sh image-build/publish_release_image.sh; do
    grep -Fq 'find "$PACKAGE_ROOT" -print0' "$ROOT/$script"
    grep -Fq "stat -c '%u:%g' \"\$path\"" "$ROOT/$script"
    grep -Fq '8#$path_mode & 0022' "$ROOT/$script" ||
        grep -Fq '8#$mode & 0022' "$ROOT/$script"
done
grep -Fq 'done < <(find "$BUILD" "$EVIDENCE" -print0)' \
    "$ROOT/image-build/build_release_image.sh"
grep -Fq 'done < <(find "$BUILD" "$EVIDENCE" -print0)' \
    "$ROOT/image-build/publish_release_image.sh"
pass build-base-schema-and-package-path-negative-fixtures

for required in 'data_rollback_cleanup_allowed' 'data_rollback_finalization_released' \
    'data_rollback_verify_cleanup_sources' 'zfs release "$hold_tag" "$snapshot"' \
    'zfs destroy "$snapshot"' 'unrelated_snapshots_destroyed:0' \
    'recursive_destroy_used:false'; do
    grep -Fq -- "$required" "$ROOT/lib/data_rollback.sh"
done
grep -Fq '"$INHIBITOR_RELEASER" verify-release' "$ROOT/lib/data_rollback.sh"
grep -Fq 'if [[ ! -s "$newer_before" ]]' "$ROOT/lib/data_rollback.sh"
grep -Fq 'rsync -aHAXx --numeric-ids --delete' "$ROOT/lib/data_rollback.sh"
function_body verify_published_canary_handoff_ready "$ROOT/lib/live_checks.sh" > "$TMP/canary-consumer"
for required in maintenance-marker-activated.json crash-recovery-procedure.json \
    maintenance-compatible-guard-identities.tsv CANDIDATE-LAUNCH-ATTEMPTED.json \
    maintenance-handoff-ready.json maintenance-state-active.txt; do
    grep -Fq -- "$required" "$TMP/canary-consumer"
done
for required in legacy_baseline_pow_mode legacy_baseline_quarantined_claims \
    restored_legacy_quarantined_claims legacy_quarantined_claim_count_preserved \
    legacy_quarantined_claim_resolution_attempted legacy_quarantined_claim_fee_paid \
    inherited_claim_inventory_present claim_baseline_transition_kind \
    clean_q0_candidate_q0_no_payment_transition_verified \
    candidate_pow_clean_hashing_verified claim_recovery_fee_baseline \
    claim_recovery_fee_final baseline-pow.json restored-pow.json \
    candidate-pow-clean-1.json candidate-pow-clean-2.json \
    candidate-safe-2-recovery-clean.json; do
    grep -Fq -- "$required" "$TMP/canary-consumer"
done
function_body legacy_pow_observed_mode "$CANARY" > "$TMP/legacy-pow-functions"
function_body legacy_pow_state_matches_baseline "$CANARY" >> "$TMP/legacy-pow-functions"
function_body restored_runtime_is_ready "$CANARY" >> "$TMP/legacy-pow-functions"
jq -n '{enabled:true,autostart:false,allow_automatic_quantum_key_creation:false,
    state:"hashing",threads:1,cpu_percent:1,hashrate:10,unresolved_claims:0,
    live_claims:0,quarantined_claims:0}' \
    > "$TMP/legacy-pow-clean.json"
jq -n '{enabled:false,autostart:false,allow_automatic_quantum_key_creation:false,
    state:"disabled",threads:1,cpu_percent:1,hashrate:0,unresolved_claims:1,
    live_claims:0,quarantined_claims:1}' \
    > "$TMP/legacy-pow-quarantined.json"
jq -n '{enabled:false,autostart:false,allow_automatic_quantum_key_creation:false,
    state:"disabled",threads:1,cpu_percent:1,hashrate:0,unresolved_claims:2,
    live_claims:0,quarantined_claims:2}' \
    > "$TMP/legacy-pow-quarantine-drift.json"
jq -n '{enabled:true,autostart:false,allow_automatic_quantum_key_creation:false,
    state:"hashing",threads:1,cpu_percent:1,hashrate:10,unresolved_claims:1,
    live_claims:0,quarantined_claims:1}' \
    > "$TMP/legacy-pow-unsafe.json"
jq -n '{chain:"main",initialblockdownload:false,headers:100,blocks:100}' \
    > "$TMP/legacy-chain-ready.json"
(
    # shellcheck disable=SC1091
    source "$TMP/legacy-pow-functions"
    [[ "$(legacy_pow_observed_mode "$TMP/legacy-pow-clean.json")" == clean-hashing ]]
    [[ "$(legacy_pow_observed_mode "$TMP/legacy-pow-quarantined.json")" == \
        quarantined-disabled ]]
    ! legacy_pow_observed_mode "$TMP/legacy-pow-quarantine-drift.json" >/dev/null
    ! legacy_pow_observed_mode "$TMP/legacy-pow-unsafe.json" >/dev/null
    LEGACY_BASELINE_LIVE_CLAIMS=0
    LEGACY_BASELINE_QUARANTINED_CLAIMS=0
    LEGACY_BASELINE_POW_MODE=clean-hashing
    legacy_pow_state_matches_baseline "$TMP/legacy-pow-clean.json"
    restored_runtime_is_ready "$TMP/legacy-chain-ready.json" "$TMP/legacy-pow-clean.json"
    ! legacy_pow_state_matches_baseline "$TMP/legacy-pow-quarantined.json"
    LEGACY_BASELINE_QUARANTINED_CLAIMS=1
    LEGACY_BASELINE_POW_MODE=quarantined-disabled
    legacy_pow_state_matches_baseline "$TMP/legacy-pow-quarantined.json"
    restored_runtime_is_ready "$TMP/legacy-chain-ready.json" \
        "$TMP/legacy-pow-quarantined.json"
    ! legacy_pow_state_matches_baseline "$TMP/legacy-pow-quarantine-drift.json"
)
function_body published_canary_pow_transition_is_valid "$ROOT/lib/live_checks.sh" \
    > "$TMP/published-canary-pow-transition"
jq -n --arg sha 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
    '{legacy_observed_pow_mode:"quarantined-disabled",
    legacy_baseline_pow_mode:"quarantined-disabled",
    legacy_baseline_live_claims:0,legacy_baseline_quarantined_claims:1,
    restored_legacy_live_claims:0,restored_legacy_quarantined_claims:1,
    legacy_quarantined_claim_count_preserved:true,
    legacy_quarantined_claim_resolution_attempted:false,
    legacy_quarantined_claim_fee_paid:false,inherited_claim_inventory_present:true,
    inherited_claim_inventory_evidence:"candidate-inherited-claim-inventory.json",
    inherited_claim_inventory_sha256:$sha,
    inherited_claim_transition_evidence:"candidate-inherited-claim-transition.json",
    inherited_claim_transition_sha256:$sha,
    claim_baseline_transition_kind:"legacy_q1_to_candidate_q0_no_payment",
    legacy_q1_candidate_q0_no_payment_reclassification_verified:true,
    clean_q0_candidate_q0_no_payment_transition_verified:false,
    claim_recovery_fee_baseline:0,claim_recovery_fee_final:0}' \
    > "$TMP/canary-pow-result-quarantined.json"
jq -n --arg sha 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
    '{legacy_observed_pow_mode:"clean-hashing",legacy_baseline_pow_mode:"clean-hashing",
    legacy_baseline_live_claims:0,legacy_baseline_quarantined_claims:0,
    restored_legacy_live_claims:0,restored_legacy_quarantined_claims:0,
    legacy_quarantined_claim_count_preserved:true,
    legacy_quarantined_claim_resolution_attempted:false,
    legacy_quarantined_claim_fee_paid:false,inherited_claim_inventory_present:false,
    inherited_claim_inventory_evidence:null,inherited_claim_inventory_sha256:null,
    inherited_claim_transition_evidence:"candidate-inherited-claim-transition.json",
    inherited_claim_transition_sha256:$sha,
    claim_baseline_transition_kind:"clean_q0_to_candidate_q0_no_payment",
    legacy_q1_candidate_q0_no_payment_reclassification_verified:false,
    clean_q0_candidate_q0_no_payment_transition_verified:true,
    claim_recovery_fee_baseline:0,claim_recovery_fee_final:0}' \
    > "$TMP/canary-pow-result-clean.json"
jq -n '{policy_authoritative:true,policy:{automatic_authorized:false},
    database_outcome_ambiguous:false,wallet_tip_matches:true,
    blocking_quarantined_claims:0,blocking_components:0,
    indeterminate_quarantined_claims:0,pending_manual_resolutions:0,
    pending_automatic_resolutions:0,confirmed_resolution_fees:0}' \
    > "$TMP/canary-recovery-clean.json"
jq -n '{enabled:true,threads:1,cpu_percent:1,hashrate:10,live_claims:0,
    quarantined_claims:0,blocking_quarantined_claims:0,raw_quarantined_claims:1,
    claim_recovery_database_outcome_ambiguous:false,
    allow_automatic_quantum_key_creation:false}' > "$TMP/candidate-pow-clean.json"
jq '.hashrate=0' "$TMP/candidate-pow-clean.json" > "$TMP/candidate-pow-stopped.json"
(
    # shellcheck disable=SC1091
    source "$TMP/published-canary-pow-transition"
    published_canary_pow_transition_is_valid \
        "$TMP/canary-pow-result-quarantined.json" \
        "$TMP/legacy-pow-quarantined.json" "$TMP/legacy-pow-quarantined.json" \
        "$TMP/canary-recovery-clean.json" "$TMP/canary-recovery-clean.json" \
        "$TMP/candidate-pow-clean.json" "$TMP/candidate-pow-clean.json"
    published_canary_pow_transition_is_valid "$TMP/canary-pow-result-clean.json" \
        "$TMP/legacy-pow-clean.json" "$TMP/legacy-pow-clean.json" \
        "$TMP/canary-recovery-clean.json" "$TMP/canary-recovery-clean.json" \
        "$TMP/candidate-pow-clean.json" "$TMP/candidate-pow-clean.json"
    ! published_canary_pow_transition_is_valid \
        "$TMP/canary-pow-result-quarantined.json" \
        "$TMP/legacy-pow-quarantined.json" "$TMP/legacy-pow-quarantine-drift.json" \
        "$TMP/canary-recovery-clean.json" "$TMP/canary-recovery-clean.json" \
        "$TMP/candidate-pow-clean.json" "$TMP/candidate-pow-clean.json"
    ! published_canary_pow_transition_is_valid \
        "$TMP/canary-pow-result-quarantined.json" \
        "$TMP/legacy-pow-quarantined.json" "$TMP/legacy-pow-quarantined.json" \
        "$TMP/canary-recovery-clean.json" "$TMP/canary-recovery-clean.json" \
        "$TMP/candidate-pow-clean.json" "$TMP/candidate-pow-stopped.json"
)
function_body candidate_claim_recovery_is_clean "$CANARY" \
    > "$TMP/candidate-claim-transition-functions"
function_body candidate_claim_transition_is_valid "$CANARY" \
    >> "$TMP/candidate-claim-transition-functions"
function_body candidate_claim_result_mode_is_valid "$CANARY" \
    >> "$TMP/candidate-claim-transition-functions"
jq -n '{policy_authoritative:true,policy:{automatic_authorized:false},
    database_outcome_ambiguous:false,chain_ready:true,wallet_tip_matches:true,
    blocking_quarantined_claims:0,blocking_components:0,
    indeterminate_quarantined_claims:0,pending_manual_resolutions:0,
    pending_automatic_resolutions:0,confirmed_resolution_fees:0,wallet_generation:7}' \
    > "$TMP/claim-recovery-observed.json"
jq '.normalized=true' "$TMP/claim-recovery-observed.json" \
    > "$TMP/claim-recovery-normalized.json"
printf '%s\n' '[]' > "$TMP/claim-transaction-txids.json"
printf '%s\n' '{"schema":1,"components":1}' > "$TMP/claim-inventory.json"
observed_sha=$(sha256sum "$TMP/claim-recovery-observed.json" | awk '{print $1}')
normalized_sha=$(sha256sum "$TMP/claim-recovery-normalized.json" | awk '{print $1}')
transaction_sha=$(sha256sum "$TMP/claim-transaction-txids.json" | awk '{print $1}')
inventory_sha=$(sha256sum "$TMP/claim-inventory.json" | awk '{print $1}')
jq -n --arg observed "$observed_sha" --arg normalized "$normalized_sha" \
    --arg transactions "$transaction_sha" \
    '{schema:1,legacy_mode:"clean-hashing",
      legacy_q1_candidate_q0_no_payment_reclassification:false,
      clean_q0_candidate_q0_no_payment_transition:true,
      inherited_claim_inventory_sha256:null,observed_recovery_sha256:$observed,
      normalized_recovery_sha256:$normalized,exact_transaction_set_sha256:$transactions,
      confirmed_resolution_fees:0,resolver_invoked:false,payment_created:false}' \
    > "$TMP/claim-transition-clean.json"
jq -n --arg inventory "$inventory_sha" --arg observed "$observed_sha" \
    --arg normalized "$normalized_sha" --arg transactions "$transaction_sha" \
    '{schema:1,legacy_mode:"quarantined-disabled",
      legacy_q1_candidate_q0_no_payment_reclassification:true,
      inherited_claim_inventory_sha256:$inventory,observed_recovery_sha256:$observed,
      normalized_recovery_sha256:$normalized,exact_transaction_set_sha256:$transactions,
      confirmed_resolution_fees:0,resolver_invoked:false,payment_created:false}' \
    > "$TMP/claim-transition-q1.json"
jq '.payment_created=true' "$TMP/claim-transition-clean.json" \
    > "$TMP/claim-transition-tampered.json"
(
    # shellcheck disable=SC1091
    source "$TMP/candidate-claim-transition-functions"
    BASELINE_RECOVERY_FEE=0
    LEGACY_BASELINE_POW_MODE=clean-hashing
    candidate_claim_transition_is_valid "$TMP/claim-transition-clean.json" \
        "$TMP/claim-recovery-observed.json" "$TMP/claim-recovery-normalized.json" \
        "$TMP/claim-transaction-txids.json" ''
    ! candidate_claim_transition_is_valid "$TMP/claim-transition-clean.json" \
        "$TMP/claim-recovery-observed.json" "$TMP/claim-recovery-normalized.json" \
        "$TMP/claim-transaction-txids.json" "$TMP/claim-inventory.json"
    ! candidate_claim_transition_is_valid "$TMP/claim-transition-tampered.json" \
        "$TMP/claim-recovery-observed.json" "$TMP/claim-recovery-normalized.json" \
        "$TMP/claim-transaction-txids.json" ''
    candidate_claim_result_mode_is_valid "$TMP/canary-pow-result-clean.json"
    ! candidate_claim_result_mode_is_valid \
        <(jq '.legacy_q1_candidate_q0_no_payment_reclassification_verified=true' \
            "$TMP/canary-pow-result-clean.json")
    LEGACY_BASELINE_POW_MODE=quarantined-disabled
    candidate_claim_transition_is_valid "$TMP/claim-transition-q1.json" \
        "$TMP/claim-recovery-observed.json" "$TMP/claim-recovery-normalized.json" \
        "$TMP/claim-transaction-txids.json" "$TMP/claim-inventory.json"
    ! candidate_claim_transition_is_valid "$TMP/claim-transition-q1.json" \
        "$TMP/claim-recovery-observed.json" "$TMP/claim-recovery-normalized.json" \
        "$TMP/claim-transaction-txids.json" ''
    candidate_claim_result_mode_is_valid "$TMP/canary-pow-result-quarantined.json"
)
function_body restore_original "$CANARY" > "$TMP/canary-restore-original"
assert_order "$TMP/canary-restore-original" \
    'run_helper "$NORMAL_UNLOCK_HELPER"' \
    'if [[ "$LEGACY_BASELINE_POW_MODE" == clean-hashing ]]' \
    'run_helper "$POW_START_HELPER"' \
    'elif [[ "$LEGACY_BASELINE_POW_MODE" != quarantined-disabled ]]'
grep -Fq 'legacy_pow_state_matches_baseline "${EVIDENCE}/baseline-pow.json"' "$CANARY"
grep -Fq 'legacy_quarantined_claim_resolution_attempted:false' "$CANARY"
grep -Fq 'clean_q0_candidate_q0_no_payment_transition_verified:' "$CANARY"
grep -Fq 'candidate_pow_clean_hashing_verified:true' "$CANARY"
pass canary-clean-and-legacy-quarantine-preservation-and-candidate-pow-gates
grep -Fq -- \
    'export PUBLISHED_CANARY_RESULT="/mnt/pulsar/Blackcoin_Blocks/operations/releases/v30.1.4-${SOURCE_COMMIT}/node27-canary-__CANARY_TIMESTAMP_YYYYMMDDTHHMMSSZ__/evidence/RESULT.json"' \
    "$ROOT/rollout.env.example"
grep -Fq -- \
    'export PUBLISHED_CANARY_EVIDENCE_MANIFEST="/mnt/pulsar/Blackcoin_Blocks/operations/releases/v30.1.4-${SOURCE_COMMIT}/node27-canary-__CANARY_TIMESTAMP_YYYYMMDDTHHMMSSZ__/evidence/SHA256SUMS"' \
    "$ROOT/rollout.env.example"
! grep -Fq -- '__FINAL_RELEASE__' "$ROOT/rollout.env.example"
for required in \
    "export CANDIDATE_IMAGE_REF='qqblackcoin/blackcoin-v4-gui@sha256:7a384dd5f12c15fb41b36868d946007524bebf97650883d533635658641e04a2'" \
    "export CANDIDATE_IMAGE_ID='sha256:620146d14a57fe0d5d1fc29a7d913d47787ba924c96ba06eeb1ddbe8efb73909'" \
    "export BLACKCOIND_SHA256='f18b4f191599dcb8318008f6758c80c89e473733ef2d8bd06b83d7155618dfb8'" \
    "export BLACKCOIN_CLI_SHA256='3f56bbb180042ace003db62038c47a441b01a6b72ac19497f96c34c9b107ec83'"; do
    grep -Fq -- "$required" "$ROOT/rollout.env.example"
done
pass canary-consumer-and-snapshot-retention-gates

if [[ "$UPDATE_MANIFEST" == 1 ]]; then
    {
        printf 'validated_at=%s\n' "$(date -u +%FT%TZ)"
        printf '%s\n' 'scope=local-static-targeted-fixture-only'
        printf '%s\n' 'live_unraid_mutation=false' 'docker_invoked=false' \
            'network_invoked=false' 'github_invoked=false'
        cat "$RESULTS"
        printf '%s\n' 'PASS package-manifest-generation' 'RESULT=passed'
    } > "$TMP/VALIDATION.txt"
    mv -f -- "$TMP/VALIDATION.txt" "$ROOT/VALIDATION.txt"

    (
        cd "$ROOT"
        find . -type f ! -path './SHA256SUMS' -print0 | sort -z | xargs -0 sha256sum \
            > "$TMP/SHA256SUMS"
    )
    mv -f -- "$TMP/SHA256SUMS" "$ROOT/SHA256SUMS"
fi
(cd "$ROOT" && cmp -s \
    <(find . -type f ! -path './SHA256SUMS' -print | sort) \
    <(awk 'NF == 2 && $1 ~ /^[0-9a-f]{64}$/ {name=$2; sub(/^\\*/, "", name); print name}' \
        SHA256SUMS | sort))
(cd "$ROOT" && sha256sum --strict -c SHA256SUMS >/dev/null)
if [[ "$UPDATE_MANIFEST" == 1 ]]; then
    printf '%s\n' 'PASS package-manifest-generation'
else
    printf '%s\n' 'PASS package-manifest-read-only-verification'
fi
printf 'RESULT=passed\nPACKAGE=%s\n' "$ROOT"
