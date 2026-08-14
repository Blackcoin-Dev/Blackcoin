#!/usr/bin/env bash
export LC_ALL=C TZ=UTC
set -Eeuo pipefail
umask 077
unset BASH_ENV ENV CDPATH GLOBIGNORE
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

# This is a temporary, fail-closed PoS availability supervisor for the exact
# already-installed v30.1.4 fleet.  It observes ordinary PoW state but is
# deliberately incapable of changing it.  Its only wallet mutation is execution of
# the independently audited normal-unlock helper after a complete read-only
# fleet preflight.  Nothing in this file removes the v30.1.4 maintenance
# inhibitor or touches Compose, chain data, wallet configuration, keys, or
# transactions.

script_dir=$(CDPATH='' cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
script_path="$script_dir/$(basename -- "${BASH_SOURCE[0]}")"
readonly script_dir script_path

readonly TOOLING_PARENT_COMMIT='2af2621d318a18365da9f9da0d5510dfbe6ee722'
readonly JOB10_CONTRACT_NAME='job-10-one-shot-contract.json'
readonly TOPOLOGY_MAP_NAME='topology.map'
readonly PACKAGE_MANIFEST_NAME='SHA256SUMS'
readonly JOB10_CONTRACT="$script_dir/$JOB10_CONTRACT_NAME"
readonly TOPOLOGY_MAP="$script_dir/$TOPOLOGY_MAP_NAME"
readonly PACKAGE_MANIFEST="$script_dir/$PACKAGE_MANIFEST_NAME"

readonly EXPECTED_HELPER_SHA256='aa924baf0a9d384759019d50e3815e03e264b906c7b51ecc76023c854b91a3e7'
readonly HISTORICAL_PARTIAL_SUPERVISOR_SHA256='d433532d25187f763a67b57f4028a167cb7905b52b2382184ceaf7b27c3ca89d'
readonly HISTORICAL_JOB10_HELPER_SHA256='acf28446e842fd0fa92b06c2ebc182e9da38fcde7bac06dd920d50a33e4e3dd1'
readonly EXPECTED_MARKER_SHA256='87ecb2e0d7df9f90eabf0a546459779116a4bc634d3cbc37b1dd824c1dfcf311'
readonly EXPECTED_IMAGE_ID='sha256:620146d14a57fe0d5d1fc29a7d913d47787ba924c96ba06eeb1ddbe8efb73909'
readonly EXPECTED_IMAGE_REF='qqblackcoin/blackcoin-v4-gui@sha256:7a384dd5f12c15fb41b36868d946007524bebf97650883d533635658641e04a2'
readonly EXPECTED_NETWORK_VERSION=300104
readonly EXPECTED_SUBVERSION='/Blackcoin:30.1.4/'
readonly NODE_COUNT=32
readonly MINIMUM_PEERS=1
readonly MINIMUM_POST_UNLOCK_SECONDS=43200
readonly POST_HELPER_WAIT_SECONDS=60
readonly RENEWAL_CADENCE_MINUTES=360
readonly MAXIMUM_AUTHORITY_LIFETIME_SECONDS=86400
readonly HELPER_TIMEOUT_SECONDS=120
readonly HELPER_KILL_AFTER_SECONDS=15
readonly STABLE_CENSUS_ATTEMPTS=3
readonly STABLE_CENSUS_RETRY_DELAY_SECONDS=2
readonly DOCKER_CALL_TIMEOUT_SECONDS=20
readonly DOCKER_CALL_KILL_AFTER_SECONDS=5
readonly CENSUS_DOCKER_CALLS_PER_NODE=8
readonly POST_CENSUS_RUNWAY_SECONDS=$((
    STABLE_CENSUS_ATTEMPTS * NODE_COUNT * CENSUS_DOCKER_CALLS_PER_NODE *
    (DOCKER_CALL_TIMEOUT_SECONDS + DOCKER_CALL_KILL_AFTER_SECONDS) +
    (STABLE_CENSUS_ATTEMPTS - 1) * STABLE_CENSUS_RETRY_DELAY_SECONDS + 600
))
readonly MINIMUM_CYCLE_RUNWAY_SECONDS=$((
    2 * POST_CENSUS_RUNWAY_SECONDS +
    NODE_COUNT * (HELPER_TIMEOUT_SECONDS + HELPER_KILL_AFTER_SECONDS) +
    POST_HELPER_WAIT_SECONDS
))
readonly CRON_EXPRESSION='17 */6 * * *'

readonly STATE_DIR='/boot/config/plugins/blackcoin-quantum-nodes'
readonly NORMAL_UNLOCK_HELPER="$STATE_DIR/blackcoin_node_normal_unlock.sh"
readonly MAINTENANCE_MARKER="$STATE_DIR/V30_1_4_ROLLOUT_MAINTENANCE.json"
readonly SHARED_LOCKS=(
    /run/blackcoin-v3015-rollout.lock
    /run/blackcoin-endpoint-guard.lock
    /run/blackcoin-node-cutover.lock
    /run/blackcoin-pow-quarantine-cycle.lock
    /run/blackcoin-wallet-runtime-guard.lock
)
readonly GLOBAL_LOCK='/run/blackcoin-emergency-pos-renewal.lock'
readonly PER_NODE_LOCK_PATTERN='/run/blackcoin-pos-unlock-renewal-node-%02d.lock'
readonly INSTALL_ROOT="$STATE_DIR/pos-unlock-renewal-supervisor"
readonly INSTALLED_SUPERVISOR="$INSTALL_ROOT/pos_unlock_renewal_supervisor.sh"
readonly INSTALLED_AUTHORITY="$INSTALL_ROOT/AUTHORITY.json"
readonly INSTALLED_AUTHORITY_SHA256="$INSTALL_ROOT/AUTHORITY.sha256"
readonly INSTALLED_INSTALL_RECEIPT="$INSTALL_ROOT/INSTALL-RECEIPT.json"
readonly INSTALLED_AUTHORITY_HISTORY="$INSTALL_ROOT/authority-history"
readonly INSTALLED_ACTIVATION_STAGING="$INSTALL_ROOT/activation-staging"
readonly INSTALLED_ACTIVATION_JOURNAL="$INSTALL_ROOT/ACTIVATION-JOURNAL.json"
readonly INSTALLED_JOB10_CONTRACT="$INSTALL_ROOT/$JOB10_CONTRACT_NAME"
readonly INSTALLED_TOPOLOGY_MAP="$INSTALL_ROOT/$TOPOLOGY_MAP_NAME"
readonly INSTALLED_PACKAGE_MANIFEST="$INSTALL_ROOT/source-package-SHA256SUMS"
readonly CRON_PATH='/etc/cron.d/blackcoin-pos-unlock-renewal-supervisor'
readonly RUNTIME_RECEIPT_ROOT='/mnt/disk1/blackcoin-wallet-safety/runtime-audits/pos-unlock-renewal-supervisor'
readonly HISTORICAL_JOB10_RECEIPT='/mnt/disk1/blackcoin-wallet-safety/runtime-audits/emergency-pos-renewal-20260814T034100Z.log'
readonly CLI='/usr/local/bin/blackcoin-cli'
readonly DATADIR='/home/blackcoin/.blackcoin'

# Exact generation-one activation identities observed after the signed 14c5ccad
# initial install. These pins are intentionally one-use: this source may replace
# only that complete predecessor set, and never an unknown or partially changed
# installation.
readonly GEN2_PREDECESSOR_SUPERVISOR_SHA256='5ce5d4ff0aafd0e5c7fe0fe6a617d0315fd01d04396443423dd3208c54546b5c'
readonly GEN2_PREDECESSOR_PACKAGE_MANIFEST_SHA256='3aa244764adb52c0188dd749db86c107ee9460dc73e763cd92cffe6cec8619d9'
readonly GEN2_PREDECESSOR_AUTHORITY_SHA256='05df229f0657b40b52b99334d34a353a98f0fdf696183607c5d033e595ef934f'
readonly GEN2_PREDECESSOR_AUTHORITY_SIDECAR_SHA256='4f4d79caf21a5ca23fef80478772bc9b81c82fc5bafeb48f4e3d10204b4a0fdf'
readonly GEN2_PREDECESSOR_INSTALL_RECEIPT_SHA256='80d0579794018c9cb0f93ab12282c82d9221f3f674dd9ceb715123f4c9eb66bc'
readonly GEN2_PREDECESSOR_CRON_SHA256='afc3e525cc21bc41b3979bf7b6752a83c7648bc4b03d3d6ab9e7d900ebe8b2bd'
readonly GEN2_HISTORICAL_JOB10_RECEIPT_SHA256='23030a65f9b182534d82f6d67709b9cd088cbe6907bae56647d9780f9b9cf3cb'
readonly GEN2_ROTATION_ROOT="$RUNTIME_RECEIPT_ROOT/generation-2-rotation"
readonly GEN2_ROTATION_JOURNAL="$INSTALL_ROOT/GEN2-ROTATION-JOURNAL.json"
readonly GEN2_INITIAL_RUN_CLAIM="$INSTALL_ROOT/GEN2-INITIAL-RUN-CLAIM.json"
readonly GEN2_ACTIVATION_RECEIPT="$INSTALL_ROOT/GEN2-ACTIVATION-RECEIPT.json"
readonly GEN2_CRON_ACTIVATION_JOURNAL="$INSTALL_ROOT/GEN2-CRON-ACTIVATION-JOURNAL.json"
readonly GEN2_ROTATION_AUTHORITY_MAX_SECONDS=3600
readonly GEN2_INITIAL_HANDOFF_MARGIN_SECONDS=900
readonly GEN2_INITIAL_CLAIM_COMMIT_MARGIN_SECONDS=60
readonly GEN2_CRON_PUBLICATION_MARGIN_SECONDS=60
readonly GEN2_ACTIVATION_RUNWAY_SECONDS=$((
    RENEWAL_CADENCE_MINUTES * 60 + MINIMUM_CYCLE_RUNWAY_SECONDS +
    GEN2_CRON_PUBLICATION_MARGIN_SECONDS
))

declare -a RENEWAL_LOCK_FDS=()
RENEWAL_HELPER_WORK_DIR=''
RENEWAL_HELPER_SNAPSHOT=''
RENEWAL_PARTIAL_ARMED=false
RENEWAL_TERMINAL_RECEIPT=false
RENEWAL_PARTIAL_ROOT=''
RENEWAL_PARTIAL_UID=''
RENEWAL_PARTIAL_AUTHORITY=''
RENEWAL_PARTIAL_AUTHORITY_SHA=''
RENEWAL_PARTIAL_STARTED_EPOCH=''
RENEWAL_PARTIAL_STARTED_UTC=''
RENEWAL_PARTIAL_PREFLIGHT='null'
RENEWAL_PARTIAL_ATTEMPTED='[]'
RENEWAL_PARTIAL_SUCCEEDED='[]'
RENEWAL_GEN2_ROLLBACK_ARMED=false
RENEWAL_GEN2_RUN_DIR=''
RENEWAL_GEN2_ROLLBACK_ACTIVE=false
RENEWAL_GEN2_CRON_ROLLBACK_ARMED=false

renewal_die()
{
    printf 'pos unlock renewal: %s\n' "$*" >&2
    return 1
}

renewal_require_commands()
{
    local name
    for name in "$@"; do
        command -v "$name" >/dev/null 2>&1 ||
            renewal_die "required command unavailable: $name" || return
    done
}

renewal_require_supported_bash()
{
    ((BASH_VERSINFO[0] >= 4)) ||
        renewal_die 'Bash 4 or newer is required for held dynamic lock descriptors'
}

renewal_sha256_file()
{
    sha256sum -- "$1" | awk '{print $1}'
}

renewal_move_noclobber()
{
    local source=$1 destination=$2
    [[ -f "$source" && ! -L "$source" &&
       ! -e "$destination" && ! -L "$destination" ]] || return 1
    mv -n -- "$source" "$destination" || return 1
    [[ ! -e "$source" && ! -L "$source" && -f "$destination" && ! -L "$destination" ]]
}

renewal_move_replace_file()
{
    local source=$1 destination=$2
    [[ -f "$source" && ! -L "$source" ]] || return 1
    if [[ -e "$destination" || -L "$destination" ]]; then
        [[ -f "$destination" && ! -L "$destination" ]] || return 1
    fi
    mv -f -- "$source" "$destination" || return 1
    [[ ! -e "$source" && ! -L "$source" && -f "$destination" && ! -L "$destination" ]]
}

renewal_realpath_existing()
{
    [[ -e "$1" || -L "$1" ]] || return 1
    realpath -e -- "$1" 2>/dev/null || realpath -- "$1" 2>/dev/null
}

renewal_now_epoch()
{
    date +%s
}

renewal_now_utc()
{
    date -u +%Y-%m-%dT%H:%M:%SZ
}

renewal_sleep()
{
    sleep "$1"
}

renewal_docker()
{
    /usr/bin/timeout --foreground --signal=TERM \
      --kill-after="$DOCKER_CALL_KILL_AFTER_SECONDS" "$DOCKER_CALL_TIMEOUT_SECONDS" \
      /usr/bin/docker "$@"
}

renewal_is_sha256()
{
    [[ "${1:-}" =~ ^[0-9a-f]{64}$ ]]
}

renewal_secure_file_for_uid()
{
    local file=$1 mode=$2 uid=$3 actual
    [[ -f "$file" && ! -L "$file" ]] || return 1
    [[ "$(renewal_realpath_existing "$file")" == "$file" ]] || return 1
    actual=$(stat -c '%u:%a:%h' -- "$file" 2>/dev/null ||
      stat -f '%u:%Lp:%l' -- "$file" 2>/dev/null) || return 1
    [[ "$actual" == "$uid:$mode:1" ]]
}

renewal_secure_file_for_owner()
{
    local file=$1 mode=$2 uid=$3 gid=$4 actual
    [[ -f "$file" && ! -L "$file" ]] || return 1
    [[ "$(renewal_realpath_existing "$file")" == "$file" ]] || return 1
    actual=$(stat -c '%u:%g:%a:%h' -- "$file" 2>/dev/null ||
      stat -f '%u:%g:%Lp:%l' -- "$file" 2>/dev/null) || return 1
    [[ "$actual" == "$uid:$gid:$mode:1" ]]
}

renewal_secure_directory_for_uid()
{
    local directory=$1 mode=$2 uid=$3 actual
    [[ -d "$directory" && ! -L "$directory" ]] || return 1
    [[ "$(renewal_realpath_existing "$directory")" == "$directory" ]] || return 1
    actual=$(stat -c '%u:%a' -- "$directory" 2>/dev/null ||
      stat -f '%u:%Lp' -- "$directory" 2>/dev/null) || return 1
    [[ "$actual" == "$uid:$mode" ]]
}

renewal_secure_directory_for_owner()
{
    local directory=$1 mode=$2 uid=$3 gid=$4 actual
    [[ -d "$directory" && ! -L "$directory" ]] || return 1
    [[ "$(renewal_realpath_existing "$directory")" == "$directory" ]] || return 1
    actual=$(stat -c '%u:%g:%a' -- "$directory" 2>/dev/null ||
      stat -f '%u:%g:%Lp' -- "$directory" 2>/dev/null) || return 1
    [[ "$actual" == "$uid:$gid:$mode" ]]
}

renewal_classify_initial_install_shape()
{
    local install_root=$1 supervisor=$2 cron=$3 current_sha=$4 predecessor_sha=$5 uid=$6 gid=$7
    local entries supervisor_sha
    renewal_is_sha256 "$current_sha" && renewal_is_sha256 "$predecessor_sha" || return 1
    renewal_secure_directory_for_uid "$install_root" 700 "$uid" || return 1
    [[ "$(dirname -- "$supervisor")" == "$install_root" &&
       ! -e "$cron" && ! -L "$cron" ]] || return 1
    entries=$(find "$install_root" -mindepth 1 -maxdepth 1 -print | sort) || return 1
    if [[ -z "$entries" ]]; then
        printf 'clean\n'
        return 0
    fi
    [[ "$entries" == "$supervisor" ]] || return 1
    renewal_secure_file_for_owner "$supervisor" 600 "$uid" "$gid" || return 1
    supervisor_sha=$(renewal_sha256_file "$supervisor") || return 1
    if [[ "$supervisor_sha" == "$current_sha" ]]; then
        printf 'current-singleton\n'
    elif [[ "$supervisor_sha" == "$predecessor_sha" ]]; then
        printf 'predecessor-singleton\n'
    else
        return 1
    fi
}

renewal_validate_topology_map()
{
    local map=$1
    [[ -f "$map" && ! -L "$map" ]] || return 1
    awk '
      BEGIN { rows = 0 }
      /^$/ || /^#/ { next }
      {
        if ($0 !~ /^[1-9][0-9]* [A-Za-z0-9][A-Za-z0-9_.-]* [A-Za-z0-9][A-Za-z0-9_.-]*$/)
          exit 1
        if (NF != 3 || $1 < 1 || $1 > 32 || sprintf("%d", $1) != $1)
          exit 1
        if (node[$1]++ || service[$2]++ || container[$3]++)
          exit 1
        rows++
      }
      END {
        if (rows != 32) exit 1
        for (n = 1; n <= 32; n++) if (node[n] != 1) exit 1
      }
    ' "$map"
}

renewal_topology_lookup()
{
    local map=$1 node=$2
    [[ "$node" =~ ^([1-9]|[12][0-9]|3[0-2])$ ]] || return 1
    renewal_validate_topology_map "$map" || return 1
    awk -v wanted="$node" '
      !/^#/ && NF == 3 && $1 == wanted { print $2 "\t" $3; found++ }
      END { if (found != 1) exit 1 }
    ' "$map"
}

renewal_job10_contract_is_valid()
{
    local contract=$1
    [[ -f "$contract" && ! -L "$contract" ]] || return 1
    jq -e \
      --arg helper "$HISTORICAL_JOB10_HELPER_SHA256" \
      --arg marker "$EXPECTED_MARKER_SHA256" \
      --arg image_id "$EXPECTED_IMAGE_ID" \
      --arg image_ref "$EXPECTED_IMAGE_REF" \
      --arg global "$GLOBAL_LOCK" \
      --arg receipt "$HISTORICAL_JOB10_RECEIPT" '
      . == {
        schema:1,
        kind:"historical-emergency-pos-renewal-one-shot",
        status:"accepted-live-audit",
        installed_or_executed_by_this_package:false,
        scheduler:{type:"at",job_id:10,
          scheduled_local:"2026-08-13T21:41:00-06:00",
          scheduled_utc:"2026-08-14T03:41:00Z",
          inspect_argv:["at","-c","10"],cancel_argv:["atrm","10"],recurring:false},
        body:{
          audited_local_sha256:"c3b8302cd1c173e72d229570f4d5df59c4b0ca64d8c9c865be2ea36a8b62396e",
          stored_suffix_sha256:"bab34133edc6abd83bdfa0398421a02d3f3d9ddee590bdbbdfba417bc9186451",
          stored_suffix_has_one_appended_blank_line:true,
          stored_minus_final_blank_reproduces_local_sha256:true,
          sentinel_count:1,
          contains_secret_passphrase_private_key_payout_or_endpoint:false},
        spool:{owner:"root",group:"daemon",mode:"0700"},
        global_mutex:$global,receipt_target:$receipt,
        preflight:{maintenance_marker_sha256:$marker,normal_unlock_helper_sha256:$helper,
          image_id:$image_id,image_ref:$image_ref,healthy:true,chain:"main",
          initial_block_download:false,peers_required:true,one_wallet_per_node:true,
          manifests_verified:true,roles_verified:true},
        action:{helper_nodes:[range(1;33)],helper_order:"sequential-ascending",
          post_helper_wait_seconds:60},
        postflight:{minimum_normal_unlock_remaining_seconds:43200,pos_active_nodes:32,
          regular_pow_intent_nodes_observed_by_historical_job:31,
          node30_ordinary_pow_disabled:true},
        one_shot_only:true,historical_receipt_is_read_only:true}
    ' "$contract" >/dev/null
}

renewal_cron_body()
{
    printf '%s\n' \
      'SHELL=/bin/bash' \
      'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
      "$CRON_EXPRESSION root /usr/bin/env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin /bin/bash $INSTALLED_SUPERVISOR run >/dev/null 2>&1"
}

renewal_cron_sha256()
{
    renewal_cron_body | sha256sum | awk '{print $1}'
}

renewal_shared_lock_paths_json()
{
    printf '%s\n' "${SHARED_LOCKS[@]}" | jq -Rsc 'split("\n")[:-1]'
}

renewal_authority_has_runway()
{
    local authority=$1 now=$2 required=$3
    [[ "$now" =~ ^[0-9]+$ && "$required" =~ ^[0-9]+$ ]] || return 1
    renewal_validate_authority_semantics "$authority" "$now" || return 1
    jq -e --argjson now "$now" --argjson required "$required" \
      '.valid_until_epoch >= ($now + $required)' "$authority" >/dev/null
}

renewal_remaining_runway_for_node()
{
    local node=$1 remaining
    [[ "$node" =~ ^([1-9]|[12][0-9]|3[0-2])$ ]] || return 1
    remaining=$((NODE_COUNT - node + 1))
    printf '%s\n' "$((remaining * (HELPER_TIMEOUT_SECONDS + HELPER_KILL_AFTER_SECONDS) +
      POST_HELPER_WAIT_SECONDS + POST_CENSUS_RUNWAY_SECONDS))"
}

renewal_validate_authority_semantics()
{
    local authority=$1 now=${2:-$(renewal_now_epoch)}
    [[ -f "$authority" && ! -L "$authority" && "$now" =~ ^[0-9]+$ ]] || return 1
    jq -e --argjson now "$now" \
      --arg parent "$TOOLING_PARENT_COMMIT" \
      --arg helper "$EXPECTED_HELPER_SHA256" \
      --arg marker "$EXPECTED_MARKER_SHA256" \
      --arg image_id "$EXPECTED_IMAGE_ID" \
      --arg image_ref "$EXPECTED_IMAGE_REF" \
      --arg subversion "$EXPECTED_SUBVERSION" \
      --argjson network_version "$EXPECTED_NETWORK_VERSION" \
      --argjson minimum_peers "$MINIMUM_PEERS" \
      --argjson cadence_minutes "$RENEWAL_CADENCE_MINUTES" \
      --argjson max_lifetime "$MAXIMUM_AUTHORITY_LIFETIME_SECONDS" \
      --argjson minimum_runway "$MINIMUM_CYCLE_RUNWAY_SECONDS" \
      --argjson stable_attempts "$STABLE_CENSUS_ATTEMPTS" \
      --argjson shared_locks "$(renewal_shared_lock_paths_json)" \
      --arg global "$GLOBAL_LOCK" \
      --arg per_node "$PER_NODE_LOCK_PATTERN" \
      --arg install_root "$INSTALL_ROOT" \
      --arg supervisor "$INSTALLED_SUPERVISOR" \
      --arg installed_authority "$INSTALLED_AUTHORITY" \
      --arg job10 "$INSTALLED_JOB10_CONTRACT" \
      --arg topology "$INSTALLED_TOPOLOGY_MAP" \
      --arg installed_manifest "$INSTALLED_PACKAGE_MANIFEST" \
      --arg cron_path "$CRON_PATH" \
      --arg receipts "$RUNTIME_RECEIPT_ROOT" \
      --arg historical "$HISTORICAL_JOB10_RECEIPT" \
      --arg cron_expression "$CRON_EXPRESSION" '
      def hex64: type == "string" and test("^[0-9a-f]{64}$");
      def pad: tostring | if length == 1 then "0" + . else . end;
      def manifest_names:
        (([range(1;33) | "runtime-wallet-manifests/node-\(.|pad).json"] +
          [range(1;33) | "runtime-identity-manifests/node-\(.|pad).json"]) | sort);
      (keys | sort) == ([
        "allowed_rpc_methods","authority_generation","authority_nonce",
        "authority_rotation_authorized","chain_config_key_transaction_mutation_forbidden",
        "cron_expression","cron_path","cron_sha256","global_lock","helper_execution",
        "helper_nodes","historical_job10_preserved_read_only","historical_job10_receipt_target",
        "image_id","image_ref","install_authorized","install_root","installed_authority",
        "installed_job10_contract","installed_package_manifest","installed_supervisor",
        "installed_topology_map","issued_at_epoch","job10_contract_sha256","kind",
        "maintenance_inhibitor_must_remain","maintenance_marker_sha256","manifest_sha256s",
        "lock_order","minimum_cycle_runway_seconds","minimum_peers",
        "minimum_post_unlock_seconds","network_version",
        "node30_ordinary_pow_enable_forbidden","normal_unlock_helper_sha256",
        "package_manifest_sha256","per_node_lock_pattern","post_helper_wait_seconds",
        "regular_pow_mutation_rpc_forbidden","regular_pow_observation_required",
        "renewal_authorized","renewal_cadence_minutes","runtime_receipt_root","schema",
        "shared_locks","stable_census_attempts","state","subversion",
        "supersedes_authority_sha256","supervisor_sha256","tooling_parent_commit",
        "topology_map_sha256","valid_from_epoch","valid_until_epoch"
      ] | sort) and
      .schema == 1 and .kind == "blackcoin-pos-unlock-renewal-supervisor-authority" and
      .state == "authorized" and
      (.authority_generation | type == "number" and floor == . and . >= 1) and
      (.authority_nonce | type == "string" and test("^[0-9a-f]{32}$")) and
      .authority_rotation_authorized == true and
      (.supersedes_authority_sha256 | hex64) and
      (if .authority_generation == 1 then .supersedes_authority_sha256 == ("0"*64)
       else .supersedes_authority_sha256 != ("0"*64) end) and
      (.issued_at_epoch | type == "number" and floor == . and . > 0) and
      (.valid_from_epoch | type == "number" and floor == .) and
      (.valid_until_epoch | type == "number" and floor == .) and
      .valid_from_epoch >= .issued_at_epoch and .valid_until_epoch > .valid_from_epoch and
      .valid_until_epoch <= (.issued_at_epoch + $max_lifetime) and
      $now >= .valid_from_epoch and $now <= .valid_until_epoch and
      .tooling_parent_commit == $parent and
      (.supervisor_sha256 | hex64) and (.package_manifest_sha256 | hex64) and
      (.topology_map_sha256 | hex64) and (.job10_contract_sha256 | hex64) and
      (.cron_sha256 | hex64) and
      .normal_unlock_helper_sha256 == $helper and .maintenance_marker_sha256 == $marker and
      .image_id == $image_id and .image_ref == $image_ref and
      .network_version == $network_version and .subversion == $subversion and
      .minimum_peers == $minimum_peers and .minimum_post_unlock_seconds == 43200 and
      .minimum_cycle_runway_seconds == $minimum_runway and
      .stable_census_attempts == $stable_attempts and
      .post_helper_wait_seconds == 60 and .renewal_cadence_minutes == $cadence_minutes and
      .cron_expression == $cron_expression and .shared_locks == $shared_locks and
      .global_lock == $global and .lock_order == ($shared_locks + [$global,$per_node]) and
      .per_node_lock_pattern == $per_node and .install_root == $install_root and
      .installed_supervisor == $supervisor and .installed_authority == $installed_authority and
      .installed_job10_contract == $job10 and .installed_topology_map == $topology and
      .installed_package_manifest == $installed_manifest and .cron_path == $cron_path and
      .runtime_receipt_root == $receipts and .historical_job10_receipt_target == $historical and
      .historical_job10_preserved_read_only == true and
      .maintenance_inhibitor_must_remain == true and
      .regular_pow_mutation_rpc_forbidden == true and
      .regular_pow_observation_required == true and
      .node30_ordinary_pow_enable_forbidden == true and
      .chain_config_key_transaction_mutation_forbidden == true and
      .allowed_rpc_methods == ["getblockchaininfo","getnetworkinfo","getpowmininginfo",
        "getstakinginfo","getwalletinfo","listwallets"] and
      .helper_nodes == [range(1;33)] and .helper_execution == "sequential-1-through-32" and
      .install_authorized == true and .renewal_authorized == true and
      (.manifest_sha256s | type == "object") and
      (.manifest_sha256s | keys | sort) == manifest_names and
      ([.manifest_sha256s[] | hex64] | all)
    ' "$authority" >/dev/null
}

renewal_package_tree_is_valid()
{
    local root=$1 manifest="$1/$PACKAGE_MANIFEST_NAME" actual listed
    [[ -d "$root" && ! -L "$root" && -f "$manifest" && ! -L "$manifest" ]] || return 1
    [[ -z "$(find "$root" -type l -print -quit)" ]] || return 1
    actual=$(cd "$root" && find . -type f ! -name "$PACKAGE_MANIFEST_NAME" -print | sort) || return 1
    listed=$(awk '{name=$2; sub(/^\\*/, "", name); print name}' "$manifest" | sort) || return 1
    [[ "$actual" == "$listed" ]] || return 1
    (cd "$root" && sha256sum --strict -c "$PACKAGE_MANIFEST_NAME" >/dev/null)
}

renewal_authority_files_match()
{
    local authority=$1 supervisor=$2 contract=$3 topology=$4 package_manifest=$5
    [[ "$(renewal_sha256_file "$supervisor")" == "$(jq -er '.supervisor_sha256' "$authority")" &&
       "$(renewal_sha256_file "$contract")" == "$(jq -er '.job10_contract_sha256' "$authority")" &&
       "$(renewal_sha256_file "$topology")" == "$(jq -er '.topology_map_sha256' "$authority")" &&
       "$(renewal_sha256_file "$package_manifest")" == "$(jq -er '.package_manifest_sha256' "$authority")" &&
       "$(renewal_cron_sha256)" == "$(jq -er '.cron_sha256' "$authority")" ]]
}

renewal_helper_content_is_audited()
{
    local helper=$1 forbidden size lines
    [[ "$(renewal_sha256_file "$helper")" == "$EXPECTED_HELPER_SHA256" ]] || return 1
    bash -n "$helper" || return 1
    forbidden=$(grep -Eio '\b(setstaking|setpowmining|getpowmininginfo|sendrawtransaction|createshadowpowclaimresolution|commitshadowpowclaimresolution|resolveshadowpowclaims|setpowclaimrecovery|getnewaddress|getnewquantumaddress|setpowminingaddress|sendtoaddress|sendmany|fundrawtransaction|signrawtransaction[^[:space:]]*|abandontransaction|resendwallettransactions|forcerelay|walletnotify|zmqpub(rawtx|hashtx|sequence)|eval|source)\b' \
        "$helper" | tr '[:upper:]' '[:lower:]' | sort -u || true)
    [[ -z "$forbidden" ]] || return 1
    [[ "$(grep -Eio '\bwalletpassphrase\b' "$helper" | wc -l | tr -d ' ')" == 1 &&
       "$(grep -Eio '\blistwallets\b' "$helper" | wc -l | tr -d ' ')" == 2 &&
       "$(grep -Eio '\bgetwalletinfo\b' "$helper" | wc -l | tr -d ' ')" == 1 &&
       "$(grep -Eio '\bgetstakinginfo\b' "$helper" | wc -l | tr -d ' ')" == 1 &&
       "$(grep -Eio '\b(walletpassphrase|listwallets|getwalletinfo|getstakinginfo)\b' \
          "$helper" | wc -l | tr -d ' ')" == 5 ]] || return 1
    grep -Eq 'walletpassphrase.*[[:space:]]false([[:space:]]|$)' "$helper" || return 1
    # shellcheck disable=SC2016 # Exact literal source text is the audited contract.
    grep -Fq '[[ -z "$wallet" ]] || rpc_args+=("-rpcwallet=$wallet")' "$helper" || return 1
    # shellcheck disable=SC2016 # Exact literal source text is the audited contract.
    [[ "$(grep -Fc '[[ -z "$wallet" ]] || rpc_args+=("-rpcwallet=$wallet")' "$helper")" == 2 ]] ||
        return 1
    grep -Fq '^([1-9]|[12][0-9]|3[0-2])$' "$helper" || return 1
    size=$(stat -c '%s' -- "$helper" 2>/dev/null ||
      stat -f '%z' -- "$helper" 2>/dev/null) || return 1
    lines=$(wc -l <"$helper" | tr -d ' ') || return 1
    [[ "$size" == 4947 && "$lines" == 122 ]]
}

renewal_verify_helper()
{
    local helper=$1 uid=$2
    renewal_secure_file_for_uid "$helper" 600 "$uid" &&
        [[ "$(renewal_sha256_file "$helper")" == "$EXPECTED_HELPER_SHA256" ]] &&
        renewal_helper_content_is_audited "$helper"
}

renewal_verify_marker()
{
    local marker=$1 uid=$2
    renewal_secure_file_for_uid "$marker" 600 "$uid" &&
        [[ "$(renewal_sha256_file "$marker")" == "$EXPECTED_MARKER_SHA256" ]]
}

renewal_manifest_expected_sha()
{
    local authority=$1 relative=$2
    jq -er --arg relative "$relative" '.manifest_sha256s[$relative] |
      select(type == "string" and test("^[0-9a-f]{64}$"))' "$authority"
}

renewal_verify_manifest_file()
{
    local authority=$1 state_root=$2 relative=$3 uid=$4 file expected
    file="$state_root/$relative"
    expected=$(renewal_manifest_expected_sha "$authority" "$relative") || return 1
    renewal_secure_file_for_uid "$file" 600 "$uid" || return 1
    [[ "$(renewal_sha256_file "$file")" == "$expected" ]]
}

renewal_verify_manifest_bytes()
{
    local authority=$1 state_root=$2 uid=$3 node padded
    for node in $(seq 1 "$NODE_COUNT"); do
        printf -v padded '%02d' "$node"
        renewal_verify_manifest_file "$authority" "$state_root" \
          "runtime-wallet-manifests/node-$padded.json" "$uid" || return 1
        renewal_verify_manifest_file "$authority" "$state_root" \
          "runtime-identity-manifests/node-$padded.json" "$uid" || return 1
    done
    return 0
}

renewal_verify_node_manifests()
{
    local authority=$1 state_root=$2 node=$3 wallet=$4 uid=$5 padded wallet_file identity_file
    printf -v padded '%02d' "$node"
    wallet_file="$state_root/runtime-wallet-manifests/node-$padded.json"
    identity_file="$state_root/runtime-identity-manifests/node-$padded.json"
    renewal_verify_manifest_file "$authority" "$state_root" \
      "runtime-wallet-manifests/node-$padded.json" "$uid" || return 1
    renewal_verify_manifest_file "$authority" "$state_root" \
      "runtime-identity-manifests/node-$padded.json" "$uid" || return 1
    jq -e --arg wallet "$wallet" '. == [$wallet]' "$wallet_file" >/dev/null || return 1
    jq -e --arg node "$padded" --arg wallet "$wallet" '
      (keys | sort) == (["keypool_external","keypool_internal","legacy_descriptors_sha256",
        "node_id","quantum_identity_sha256","schema","trusted_legacy_descriptor_set_sha256",
        "trusted_policy_sha256","trusted_quantum_address_count",
        "trusted_quantum_address_set_sha256","wallet"] | sort) and
      .schema == 2 and .node_id == $node and .wallet == $wallet and
      ([.legacy_descriptors_sha256,.quantum_identity_sha256,.trusted_policy_sha256,
        .trusted_legacy_descriptor_set_sha256,.trusted_quantum_address_set_sha256] |
        all(type == "string" and test("^[0-9a-f]{64}$"))) and
      (.keypool_external | type == "number" and floor == . and . >= 0) and
      (.keypool_internal | type == "number" and floor == . and . >= 0) and
      (.trusted_quantum_address_count | type == "number" and floor == . and . >= 1)
    ' "$identity_file" >/dev/null || return 1
}

renewal_rpc()
{
    local container=$1
    shift
    renewal_docker exec "$container" "$CLI" -datadir="$DATADIR" "$@"
}

renewal_wallet_rpc()
{
    local container=$1 wallet=$2
    local -a rpc_args=(-datadir="$DATADIR")
    shift 2
    [[ -z "$wallet" ]] || rpc_args+=("-rpcwallet=$wallet")
    renewal_docker exec "$container" "$CLI" "${rpc_args[@]}" "$@"
}

renewal_capture_node()
{
    local authority=$1 state_root=$2 topology=$3 node=$4 phase=$5 uid=$6
    local row service container inspect chain_before chain_after network wallets wallet
    local wallet_info staking pow wallet_hash now
    [[ "$phase" == pre || "$phase" == post ]] || return 1
    row=$(renewal_topology_lookup "$topology" "$node") || return 1
    IFS=$'\t' read -r service container <<<"$row"
    inspect=$(renewal_docker inspect "$container") || return 1
    jq -e --arg container "/$container" --arg image_ref "$EXPECTED_IMAGE_REF" \
      --arg image_id "$EXPECTED_IMAGE_ID" '
      length == 1 and .[0].Name == $container and .[0].Config.Image == $image_ref and
      .[0].Image == $image_id and .[0].State.Running == true and
      .[0].State.Restarting == false and .[0].State.Paused == false and
      .[0].State.Health.Status == "healthy"
    ' <<<"$inspect" >/dev/null || return 1
    chain_before=$(renewal_rpc "$container" getblockchaininfo) || return 1
    network=$(renewal_rpc "$container" getnetworkinfo) || return 1
    wallets=$(renewal_rpc "$container" listwallets) || return 1
    wallet=$(jq -er 'select(type == "array" and length == 1) | .[0] |
      select(type == "string")' <<<"$wallets") || return 1
    wallet_info=$(renewal_wallet_rpc "$container" "$wallet" getwalletinfo) || return 1
    staking=$(renewal_wallet_rpc "$container" "$wallet" getstakinginfo) || return 1
    pow=$(renewal_wallet_rpc "$container" "$wallet" getpowmininginfo) || return 1
    chain_after=$(renewal_rpc "$container" getblockchaininfo) || return 1
    jq -e -n --argjson before "$chain_before" --argjson after "$chain_after" '
      ($before | {chain,blocks,headers,bestblockhash,chainwork,initialblockdownload}) ==
      ($after | {chain,blocks,headers,bestblockhash,chainwork,initialblockdownload}) and
      $before.chain == "main" and $before.initialblockdownload == false and
      ($before.blocks | type == "number" and floor == . and . >= 0) and
      $before.headers == $before.blocks and
      ($before.bestblockhash | type == "string" and test("^[0-9a-f]{64}$")) and
      ($before.chainwork | type == "string" and test("^[0-9a-f]{64}$"))
    ' >/dev/null || return 1
    jq -e --arg subversion "$EXPECTED_SUBVERSION" \
      --argjson network_version "$EXPECTED_NETWORK_VERSION" \
      --argjson minimum_peers "$MINIMUM_PEERS" '
      .version == $network_version and .subversion == $subversion and
      (.connections | type == "number" and floor == . and . >= $minimum_peers)
    ' <<<"$network" >/dev/null || return 1
    jq -e --arg wallet "$wallet" '
      .walletname == $wallet and .private_keys_enabled == true and .scanning == false and
      (.unlocked_until | type == "number" and floor == . and . >= 0) and
      (.unlocked_staking_only | type == "boolean")
    ' <<<"$wallet_info" >/dev/null || return 1
    jq -e '
      .enabled == true and .autostart_staking == false and
      .automatic_qqsignal == false and .automatic_demurrage_attestation == false and
      .automatic_redelegation == false and .allow_automatic_quantum_key_creation == false
    ' <<<"$staking" >/dev/null || return 1
    if [[ "$node" -eq 30 ]]; then
        jq -e '
          .enabled == false and .autostart == false and .state == "disabled" and
          (.hashrate | type == "number" and . == 0) and
          (.claims_submitted | type == "number" and floor == . and . == 0) and
          .allow_automatic_quantum_key_creation == false
        ' <<<"$pow" >/dev/null || return 1
    else
        jq -e '
          .enabled == true and .autostart == false and .threads == 1 and
          .cpu_percent == 1 and (.hashrate | type == "number" and . >= 0) and
          (.claims_submitted | type == "number" and floor == . and . >= 0) and
          (.state | type == "string" and length > 0) and
          (.payout_address | type == "string" and length > 0) and
          .allow_automatic_quantum_key_creation == false
        ' <<<"$pow" >/dev/null || return 1
    fi
    if [[ "$phase" == post ]]; then
        now=$(renewal_now_epoch)
        jq -e --argjson now "$now" --argjson minimum "$MINIMUM_POST_UNLOCK_SECONDS" '
          .unlocked_staking_only == false and .unlocked_until > ($now + $minimum)
        ' <<<"$wallet_info" >/dev/null || return 1
        jq -e '
          .staking == true and .worker_running == true and .eligible == true and
          .staking_snapshot_current == true and .staking_state == "searching" and
          .weight > 0 and .weight_cached == true
        ' <<<"$staking" >/dev/null || return 1
    fi
    renewal_verify_node_manifests "$authority" "$state_root" "$node" "$wallet" "$uid" || return 1
    wallet_hash=$(printf '%s' "$wallet" | sha256sum | awk '{print $1}')
    jq -cn --argjson node "$node" --arg service "$service" --arg container "$container" \
      --arg image_ref "$EXPECTED_IMAGE_REF" --arg image_id "$EXPECTED_IMAGE_ID" \
      --arg wallet_hash "$wallet_hash" --arg phase "$phase" \
      --argjson chain "$chain_after" --argjson network "$network" \
      --argjson wallet "$wallet_info" --argjson staking "$staking" --argjson pow "$pow" '{
        node:$node,service:$service,container:$container,phase:$phase,
        image_ref:$image_ref,image_id:$image_id,wallet_name_sha256:$wallet_hash,
        chain:$chain.chain,height:$chain.blocks,headers:$chain.headers,
        tip:$chain.bestblockhash,chainwork:$chain.chainwork,initial_block_download:$chain.initialblockdownload,
        peers:$network.connections,network_version:$network.version,subversion:$network.subversion,
        unlocked_until:$wallet.unlocked_until,unlocked_staking_only:$wallet.unlocked_staking_only,
        staking_enabled:$staking.enabled,staking_active:$staking.staking,
        staking_state:$staking.staking_state,weight:$staking.weight,
        regular_pow_role:(if $node == 30 then "special-disabled" else "regular-enabled" end),
        pow:{enabled:$pow.enabled,autostart:$pow.autostart,threads:($pow.threads // null),
          cpu_percent:($pow.cpu_percent // null),state:$pow.state,hashrate:$pow.hashrate,
          payout_address:($pow.payout_address // ""),claims_submitted:$pow.claims_submitted,
          allow_automatic_quantum_key_creation:$pow.allow_automatic_quantum_key_creation}
      }'
}

renewal_capture_fleet_once()
{
    local authority=$1 state_root=$2 topology=$3 phase=$4 uid=$5 node observation fleet='[]'
    for node in $(seq 1 "$NODE_COUNT"); do
        observation=$(renewal_capture_node "$authority" "$state_root" "$topology" \
          "$node" "$phase" "$uid") || return 1
        fleet=$(jq -cn --argjson fleet "$fleet" --argjson item "$observation" '$fleet + [$item]')
    done
    jq -e '
      length == 32 and ([.[].node] == [range(1;33)]) and
      ([.[].tip] | unique | length) == 1 and
      ([.[].height] | unique | length) == 1 and
      ([.[].chainwork] | unique | length) == 1 and
      ([.[] | select(.node != 30 and .regular_pow_role == "regular-enabled" and
        .pow.enabled == true and .pow.autostart == false and .pow.threads == 1 and
        .pow.cpu_percent == 1)] | length) == 31 and
      ([.[] | select(.node == 30 and .regular_pow_role == "special-disabled" and
        .pow.enabled == false and .pow.autostart == false and .pow.state == "disabled" and
        .pow.hashrate == 0)] | length) == 1
    ' <<<"$fleet" >/dev/null || return 1
    printf '%s\n' "$fleet"
}

renewal_capture_fleet()
{
    local authority=$1 state_root=$2 topology=$3 phase=$4 uid=$5 attempt fleet
    for attempt in $(seq 1 "$STABLE_CENSUS_ATTEMPTS"); do
        if fleet=$(renewal_capture_fleet_once "$authority" "$state_root" "$topology" \
          "$phase" "$uid"); then
            printf '%s\n' "$fleet"
            return 0
        fi
        [[ "$attempt" -eq "$STABLE_CENSUS_ATTEMPTS" ]] ||
            renewal_sleep "$STABLE_CENSUS_RETRY_DELAY_SECONDS"
    done
    return 1
}

renewal_acquire_lock()
{
    local path=$1 uid=$2 fd inode_path inode_fd
    [[ "$path" == /* && ! -L "$path" ]] || return 1
    exec {fd}>"$path" || return 1
    if ! renewal_secure_file_for_uid "$path" 600 "$uid"; then
        exec {fd}>&-
        return 1
    fi
    if [[ -e "/proc/$$/fd/$fd" ]]; then
        inode_path=$(stat -Lc '%d:%i' -- "$path") || { exec {fd}>&-; return 1; }
        inode_fd=$(stat -Lc '%d:%i' -- "/proc/$$/fd/$fd") || { exec {fd}>&-; return 1; }
        [[ "$inode_path" == "$inode_fd" ]] || { exec {fd}>&-; return 1; }
    fi
    if ! flock -n "$fd"; then
        exec {fd}>&-
        return 1
    fi
    RENEWAL_LOCK_FDS+=("$fd")
}

renewal_acquire_fleet_locks()
{
    local global=$1 pattern=$2 uid=$3 shared node padded path
    [[ "$pattern" == *'%02d'* && "${pattern/'%02d'/}" != *'%'* ]] || return 1
    for shared in "${SHARED_LOCKS[@]}"; do
        renewal_acquire_lock "$shared" "$uid" || return 1
    done
    renewal_acquire_lock "$global" "$uid" || return 1
    for node in $(seq 1 "$NODE_COUNT"); do
        printf -v padded '%02d' "$node"
        path=${pattern/'%02d'/$padded}
        renewal_acquire_lock "$path" "$uid" || return 1
    done
}

renewal_release_locks()
{
    local index fd
    for ((index=${#RENEWAL_LOCK_FDS[@]} - 1; index >= 0; index--)); do
        fd=${RENEWAL_LOCK_FDS[$index]}
        flock -u "$fd" 2>/dev/null || true
        exec {fd}>&-
    done
    RENEWAL_LOCK_FDS=()
}

renewal_prepare_helper_snapshot()
{
    local helper=$1 uid=$2 work_root=$3
    renewal_verify_helper "$helper" "$uid" || return 1
    RENEWAL_HELPER_WORK_DIR=$(mktemp -d "$work_root/.pos-renewal-helper.XXXXXX") || return 1
    chmod 700 "$RENEWAL_HELPER_WORK_DIR" || return 1
    RENEWAL_HELPER_SNAPSHOT="$RENEWAL_HELPER_WORK_DIR/blackcoin_node_normal_unlock.sh"
    install -m 600 -- "$helper" "$RENEWAL_HELPER_SNAPSHOT" || return 1
    [[ "$(renewal_sha256_file "$RENEWAL_HELPER_SNAPSHOT")" == "$EXPECTED_HELPER_SHA256" ]] || return 1
    renewal_helper_content_is_audited "$RENEWAL_HELPER_SNAPSHOT"
}

renewal_invoke_helper_snapshot()
{
    local snapshot=$1 node=$2
    [[ "$node" =~ ^([1-9]|[12][0-9]|3[0-2])$ && -f "$snapshot" && ! -L "$snapshot" &&
       "$(renewal_sha256_file "$snapshot")" == "$EXPECTED_HELPER_SHA256" ]] || return 1
    /usr/bin/timeout --foreground --signal=TERM \
      --kill-after="$HELPER_KILL_AFTER_SECONDS" "$HELPER_TIMEOUT_SECONDS" \
      /usr/bin/env -i PATH="$PATH" LC_ALL=C TZ=UTC \
      /bin/bash --noprofile --norc "$snapshot" "$node" >/dev/null 2>&1
}

renewal_cleanup()
{
    renewal_release_locks
    if [[ -n "$RENEWAL_HELPER_WORK_DIR" &&
          "$RENEWAL_HELPER_WORK_DIR" =~ /[.]pos-renewal-helper[.][A-Za-z0-9]+$ &&
          -d "$RENEWAL_HELPER_WORK_DIR" && ! -L "$RENEWAL_HELPER_WORK_DIR" ]]; then
        rm -rf -- "$RENEWAL_HELPER_WORK_DIR"
    fi
    RENEWAL_HELPER_WORK_DIR=''
    RENEWAL_HELPER_SNAPSHOT=''
}

renewal_publish_json_receipt()
{
    local root=$1 uid=$2 basename=$3 json=$4
    local output sidecar temporary expected actual
    renewal_secure_directory_for_uid "$root" 700 "$uid" || return 1
    [[ "$basename" =~ ^renewal-[0-9]+-[0-9a-f]{32}(-PARTIAL)?[.]json$ ]] || return 1
    output="$root/$basename"
    sidecar="$output.sha256"
    [[ ! -e "$output" && ! -L "$output" && ! -e "$sidecar" && ! -L "$sidecar" ]] || return 1
    temporary=$(mktemp "$root/.receipt.XXXXXX") || return 1
    printf '%s\n' "$json" | jq -eS . >"$temporary" || { rm -f -- "$temporary"; return 1; }
    chmod 600 "$temporary" || { rm -f -- "$temporary"; return 1; }
    sync -f "$temporary" || { rm -f -- "$temporary"; return 1; }
    expected=$(renewal_sha256_file "$temporary") || { rm -f -- "$temporary"; return 1; }
    renewal_move_noclobber "$temporary" "$output" || { rm -f -- "$temporary"; return 1; }
    [[ ! -e "$temporary" && ! -L "$temporary" ]] || { rm -f -- "$temporary"; return 1; }
    actual=$(renewal_sha256_file "$output") || return 1
    [[ "$actual" == "$expected" ]] || return 1
    temporary=$(mktemp "$root/.receipt-sha.XXXXXX") || return 1
    printf '%s\n' "$expected" >"$temporary"
    if ! chmod 600 "$temporary" || ! sync -f "$temporary"; then
        rm -f -- "$temporary"
        return 1
    fi
    renewal_move_noclobber "$temporary" "$sidecar" || { rm -f -- "$temporary"; return 1; }
    [[ ! -e "$temporary" && ! -L "$temporary" ]] || { rm -f -- "$temporary"; return 1; }
    sync -f "$output" && sync -f "$sidecar" && sync -f "$root" || return 1
    renewal_secure_file_for_uid "$output" 600 "$uid" &&
      renewal_secure_file_for_uid "$sidecar" 600 "$uid" &&
      [[ "$(<"$sidecar")" == "$expected" && "$(renewal_sha256_file "$output")" == "$expected" ]]
}

renewal_publish_receipt()
{
    local root=$1 uid=$2 authority=$3 authority_sha=$4 started_epoch=$5 started_utc=$6 pre=$7 post=$8
    local nonce finished_epoch finished_utc receipt
    nonce=$(jq -er '.authority_nonce' "$authority") || return 1
    finished_epoch=$(renewal_now_epoch)
    finished_utc=$(renewal_now_utc)
    receipt=$(jq -n --arg authority_sha "$authority_sha" --arg supervisor_sha "$(renewal_sha256_file "$script_path")" \
      --arg helper_sha "$EXPECTED_HELPER_SHA256" --arg marker_sha "$EXPECTED_MARKER_SHA256" \
      --arg image_id "$EXPECTED_IMAGE_ID" --arg image_ref "$EXPECTED_IMAGE_REF" \
      --arg started_utc "$started_utc" --arg finished_utc "$finished_utc" \
      --argjson started_epoch "$started_epoch" --argjson finished_epoch "$finished_epoch" \
      --argjson shared_locks "$(renewal_shared_lock_paths_json)" \
      --argjson pre "$pre" --argjson post "$post" '{
        schema:1,kind:"blackcoin-pos-unlock-renewal-supervisor-run",status:"PASS",
        authority_sha256:$authority_sha,supervisor_sha256:$supervisor_sha,
        normal_unlock_helper_sha256:$helper_sha,maintenance_marker_sha256:$marker_sha,
        image_id:$image_id,image_ref:$image_ref,started_at_epoch:$started_epoch,
        started_at_utc:$started_utc,finished_at_epoch:$finished_epoch,finished_at_utc:$finished_utc,
        shared_locks_held:$shared_locks,global_and_per_node_locks_held:true,
        helper_nodes:[range(1;33)],helper_order:"sequential-ascending",
        post_helper_wait_seconds:60,minimum_normal_unlock_remaining_seconds:43200,
        stable_census_attempts_maximum:3,
        historical_job10_receipt_preserved_read_only:true,regular_pow_rpc_observed:true,
        regular_pow_mutating_rpc_invoked:false,node30_ordinary_pow_enable_attempted:false,
        maintenance_inhibitor_removed:false,chain_config_key_transaction_mutation_attempted:false,
        preflight:$pre,postflight:$post
      }') || return 1
    renewal_publish_json_receipt "$root" "$uid" "renewal-${started_epoch}-${nonce}.json" "$receipt"
}

renewal_publish_partial_receipt()
{
    local root=$1 uid=$2 authority=$3 authority_sha=$4 started_epoch=$5 started_utc=$6
    local pre=$7 attempted=$8 succeeded=$9 reason=${10} post=${11:-null}
    local nonce finished_epoch finished_utc receipt
    nonce=$(jq -er '.authority_nonce' "$authority") || return 1
    [[ "$reason" =~ ^[a-z0-9_-]+$ ]] || return 1
    finished_epoch=$(renewal_now_epoch)
    finished_utc=$(renewal_now_utc)
    receipt=$(jq -n --arg authority_sha "$authority_sha" \
      --arg supervisor_sha "$(renewal_sha256_file "$script_path")" \
      --arg helper_sha "$EXPECTED_HELPER_SHA256" --arg marker_sha "$EXPECTED_MARKER_SHA256" \
      --arg image_id "$EXPECTED_IMAGE_ID" --arg image_ref "$EXPECTED_IMAGE_REF" \
      --arg reason "$reason" --arg started_utc "$started_utc" --arg finished_utc "$finished_utc" \
      --argjson started_epoch "$started_epoch" --argjson finished_epoch "$finished_epoch" \
      --argjson shared_locks "$(renewal_shared_lock_paths_json)" --argjson pre "$pre" \
      --argjson attempted "$attempted" --argjson succeeded "$succeeded" --argjson post "$post" '{
        schema:1,kind:"blackcoin-pos-unlock-renewal-supervisor-run",status:"PARTIAL",
        mutation_outcome:"UNSEALED",failure_reason:$reason,authority_sha256:$authority_sha,
        supervisor_sha256:$supervisor_sha,normal_unlock_helper_sha256:$helper_sha,
        maintenance_marker_sha256:$marker_sha,image_id:$image_id,image_ref:$image_ref,
        started_at_epoch:$started_epoch,started_at_utc:$started_utc,
        finished_at_epoch:$finished_epoch,finished_at_utc:$finished_utc,
        shared_locks_held:$shared_locks,global_and_per_node_locks_held:true,
        helper_attempted_nodes:$attempted,helper_succeeded_nodes:$succeeded,
        helper_reinvocation_authorized:false,regular_pow_rpc_observed:true,
        regular_pow_mutating_rpc_invoked:false,node30_ordinary_pow_enable_attempted:false,
        maintenance_inhibitor_removed:false,chain_config_key_transaction_mutation_attempted:false,
        preflight:$pre,postflight_observation:$post
      }') || return 1
    renewal_publish_json_receipt "$root" "$uid" \
      "renewal-${started_epoch}-${nonce}-PARTIAL.json" "$receipt"
}

renewal_arm_partial_context()
{
    RENEWAL_PARTIAL_ROOT=$1
    RENEWAL_PARTIAL_UID=$2
    RENEWAL_PARTIAL_AUTHORITY=$3
    RENEWAL_PARTIAL_AUTHORITY_SHA=$4
    RENEWAL_PARTIAL_STARTED_EPOCH=$5
    RENEWAL_PARTIAL_STARTED_UTC=$6
    RENEWAL_PARTIAL_PREFLIGHT=$7
    RENEWAL_PARTIAL_ATTEMPTED=$8
    RENEWAL_PARTIAL_SUCCEEDED=$9
    RENEWAL_PARTIAL_ARMED=true
    RENEWAL_TERMINAL_RECEIPT=false
}

renewal_update_partial_progress()
{
    local attempted=$1 succeeded=$2
    [[ "$RENEWAL_PARTIAL_ARMED" == true ]] || return 1
    jq -e 'type == "array" and all(type == "number" and floor == . and . >= 1 and . <= 32)' \
      <<<"$attempted" >/dev/null || return 1
    jq -e 'type == "array" and all(type == "number" and floor == . and . >= 1 and . <= 32)' \
      <<<"$succeeded" >/dev/null || return 1
    RENEWAL_PARTIAL_ATTEMPTED=$attempted
    RENEWAL_PARTIAL_SUCCEEDED=$succeeded
}

renewal_publish_armed_partial()
{
    local reason=$1 post=${2:-null}
    [[ "$RENEWAL_PARTIAL_ARMED" == true && "$RENEWAL_TERMINAL_RECEIPT" == false ]] || return 1
    if renewal_publish_partial_receipt "$RENEWAL_PARTIAL_ROOT" "$RENEWAL_PARTIAL_UID" \
      "$RENEWAL_PARTIAL_AUTHORITY" "$RENEWAL_PARTIAL_AUTHORITY_SHA" \
      "$RENEWAL_PARTIAL_STARTED_EPOCH" "$RENEWAL_PARTIAL_STARTED_UTC" \
      "$RENEWAL_PARTIAL_PREFLIGHT" "$RENEWAL_PARTIAL_ATTEMPTED" \
      "$RENEWAL_PARTIAL_SUCCEEDED" "$reason" "$post"; then
        RENEWAL_TERMINAL_RECEIPT=true
        RENEWAL_PARTIAL_ARMED=false
        return 0
    fi
    return 1
}

renewal_handle_signal()
{
    local code=$1 reason=$2
    trap '' HUP INT TERM
    if [[ "$RENEWAL_PARTIAL_ARMED" == true && "$RENEWAL_TERMINAL_RECEIPT" == false ]]; then
        renewal_publish_armed_partial "$reason" || true
    fi
    renewal_cleanup
    exit "$code"
}

renewal_handle_exit()
{
    local status=$?
    trap - EXIT
    if [[ "$status" -ne 0 && "$RENEWAL_PARTIAL_ARMED" == true &&
          "$RENEWAL_TERMINAL_RECEIPT" == false ]]; then
        renewal_publish_armed_partial abnormal_exit || true
    fi
    renewal_cleanup
    exit "$status"
}

renewal_fail_partial()
{
    local root=$1 uid=$2 authority=$3 authority_sha=$4 started_epoch=$5 started_utc=$6
    local pre=$7 attempted=$8 succeeded=$9 reason=${10} post=${11:-null}
    renewal_arm_partial_context "$root" "$uid" "$authority" "$authority_sha" \
      "$started_epoch" "$started_utc" "$pre" "$attempted" "$succeeded"
    if ! renewal_publish_armed_partial "$reason" "$post"; then
        renewal_die "unable to persist required PARTIAL receipt after $reason" || true
    fi
    return 1
}

renewal_execute_cycle()
{
    local authority=$1 authority_sha=$2 state_root=$3 topology=$4 helper=$5 marker=$6
    local receipt_root=$7 global_lock=$8 per_node_pattern=$9 uid=${10} work_root=${11}
    local locks_already_held=${12:-false}
    local started_epoch started_utc pre post node now required
    local attempted='[]' succeeded='[]'
    [[ "$(renewal_sha256_file "$authority")" == "$authority_sha" ]] || return 1
    now=$(renewal_now_epoch)
    renewal_authority_has_runway "$authority" "$now" "$MINIMUM_CYCLE_RUNWAY_SECONDS" || return 1
    if [[ "$locks_already_held" == true ]]; then
        [[ "${#RENEWAL_LOCK_FDS[@]}" -eq $((${#SHARED_LOCKS[@]} + NODE_COUNT + 1)) ]] || return 1
    elif [[ "$locks_already_held" == false ]]; then
        renewal_acquire_fleet_locks "$global_lock" "$per_node_pattern" "$uid" || return 1
    else
        return 1
    fi
    renewal_verify_marker "$marker" "$uid" || return 1
    renewal_verify_helper "$helper" "$uid" || return 1
    renewal_verify_manifest_bytes "$authority" "$state_root" "$uid" || return 1
    renewal_validate_topology_map "$topology" || return 1
    started_epoch=$(renewal_now_epoch)
    started_utc=$(renewal_now_utc)
    if [[ "$RENEWAL_PARTIAL_ARMED" == false ]]; then
        renewal_arm_partial_context "$receipt_root" "$uid" "$authority" "$authority_sha" \
          "$started_epoch" "$started_utc" null "$attempted" "$succeeded"
    fi
    pre=$(renewal_capture_fleet "$authority" "$state_root" "$topology" pre "$uid") || return 1
    RENEWAL_PARTIAL_PREFLIGHT=$pre
    [[ "$(renewal_sha256_file "$authority")" == "$authority_sha" ]] || return 1
    now=$(renewal_now_epoch)
    required=$(renewal_remaining_runway_for_node 1) || return 1
    renewal_authority_has_runway "$authority" "$now" "$required" || return 1
    renewal_verify_marker "$marker" "$uid" || return 1
    renewal_prepare_helper_snapshot "$helper" "$uid" "$work_root" || return 1
    for node in $(seq 1 "$NODE_COUNT"); do
        if [[ "$(renewal_sha256_file "$authority")" != "$authority_sha" ]]; then
            renewal_fail_partial "$receipt_root" "$uid" "$authority" "$authority_sha" \
              "$started_epoch" "$started_utc" "$pre" "$attempted" "$succeeded" authority_changed
            return
        fi
        if ! renewal_verify_marker "$marker" "$uid"; then
            if [[ "$(jq -r 'length' <<<"$attempted")" -gt 0 ]]; then
                renewal_fail_partial "$receipt_root" "$uid" "$authority" "$authority_sha" \
                  "$started_epoch" "$started_utc" "$pre" "$attempted" "$succeeded" marker_changed
                return
            fi
            return 1
        fi
        now=$(renewal_now_epoch)
        required=$(renewal_remaining_runway_for_node "$node") || return 1
        if ! renewal_authority_has_runway "$authority" "$now" "$required"; then
            if [[ "$(jq -r 'length' <<<"$attempted")" -gt 0 ]]; then
                renewal_fail_partial "$receipt_root" "$uid" "$authority" "$authority_sha" \
                  "$started_epoch" "$started_utc" "$pre" "$attempted" "$succeeded" authority_runway_exhausted
                return
            fi
            return 1
        fi
        attempted=$(jq -cn --argjson prior "$attempted" --argjson node "$node" '$prior + [$node]')
        if [[ "$RENEWAL_PARTIAL_ARMED" == false ]]; then
            renewal_arm_partial_context "$receipt_root" "$uid" "$authority" "$authority_sha" \
              "$started_epoch" "$started_utc" "$pre" "$attempted" "$succeeded"
        else
            renewal_update_partial_progress "$attempted" "$succeeded" || return 1
        fi
        if ! renewal_invoke_helper_snapshot "$RENEWAL_HELPER_SNAPSHOT" "$node"; then
            renewal_fail_partial "$receipt_root" "$uid" "$authority" "$authority_sha" \
              "$started_epoch" "$started_utc" "$pre" "$attempted" "$succeeded" helper_failed
            return
        fi
        succeeded=$(jq -cn --argjson prior "$succeeded" --argjson node "$node" '$prior + [$node]')
        renewal_update_partial_progress "$attempted" "$succeeded" || return 1
    done
    if ! renewal_sleep "$POST_HELPER_WAIT_SECONDS"; then
        renewal_fail_partial "$receipt_root" "$uid" "$authority" "$authority_sha" \
          "$started_epoch" "$started_utc" "$pre" "$attempted" "$succeeded" post_wait_failed
        return
    fi
    if [[ "$(renewal_sha256_file "$authority")" != "$authority_sha" ]]; then
        renewal_fail_partial "$receipt_root" "$uid" "$authority" "$authority_sha" \
          "$started_epoch" "$started_utc" "$pre" "$attempted" "$succeeded" authority_changed
        return
    fi
    now=$(renewal_now_epoch)
    if ! renewal_authority_has_runway "$authority" "$now" "$POST_CENSUS_RUNWAY_SECONDS"; then
        renewal_fail_partial "$receipt_root" "$uid" "$authority" "$authority_sha" \
          "$started_epoch" "$started_utc" "$pre" "$attempted" "$succeeded" authority_runway_exhausted
        return
    fi
    if ! renewal_verify_marker "$marker" "$uid"; then
        renewal_fail_partial "$receipt_root" "$uid" "$authority" "$authority_sha" \
          "$started_epoch" "$started_utc" "$pre" "$attempted" "$succeeded" marker_changed
        return
    fi
    if ! renewal_verify_helper "$helper" "$uid"; then
        renewal_fail_partial "$receipt_root" "$uid" "$authority" "$authority_sha" \
          "$started_epoch" "$started_utc" "$pre" "$attempted" "$succeeded" helper_changed
        return
    fi
    if ! post=$(renewal_capture_fleet "$authority" "$state_root" "$topology" post "$uid"); then
        renewal_fail_partial "$receipt_root" "$uid" "$authority" "$authority_sha" \
          "$started_epoch" "$started_utc" "$pre" "$attempted" "$succeeded" postflight_unstable
        return
    fi
    if [[ "$(renewal_sha256_file "$authority")" != "$authority_sha" ]] ||
      ! renewal_verify_marker "$marker" "$uid" ||
      ! renewal_authority_has_runway "$authority" "$(renewal_now_epoch)" 0; then
        renewal_fail_partial "$receipt_root" "$uid" "$authority" "$authority_sha" \
          "$started_epoch" "$started_utc" "$pre" "$attempted" "$succeeded" final_gate_changed "$post"
        return
    fi
    if ! renewal_publish_receipt "$receipt_root" "$uid" "$authority" "$authority_sha" \
      "$started_epoch" "$started_utc" "$pre" "$post"; then
        renewal_fail_partial "$receipt_root" "$uid" "$authority" "$authority_sha" \
          "$started_epoch" "$started_utc" "$pre" "$attempted" "$succeeded" pass_receipt_publish_failed "$post"
        return
    fi
    RENEWAL_TERMINAL_RECEIPT=true
    RENEWAL_PARTIAL_ARMED=false
}

renewal_install_exact_file()
{
    local source=$1 expected_sha=$2 destination=$3 mode=$4 directory temporary
    directory=$(dirname -- "$destination")
    if [[ -e "$destination" || -L "$destination" ]]; then
        renewal_secure_file_for_uid "$destination" "$mode" 0 &&
          [[ "$(renewal_sha256_file "$destination")" == "$expected_sha" ]]
        return
    fi
    temporary=$(mktemp "$directory/.install.XXXXXX") || return 1
    install -o root -g root -m "$mode" -- "$source" "$temporary" || {
        rm -f -- "$temporary"; return 1;
    }
    [[ "$(renewal_sha256_file "$temporary")" == "$expected_sha" ]] || {
        rm -f -- "$temporary"; return 1;
    }
    sync -f "$temporary" || { rm -f -- "$temporary"; return 1; }
    renewal_move_noclobber "$temporary" "$destination" || { rm -f -- "$temporary"; return 1; }
    [[ ! -e "$temporary" && ! -L "$temporary" ]] || { rm -f -- "$temporary"; return 1; }
    sync -f "$destination" && sync -f "$directory" || return 1
    renewal_secure_file_for_uid "$destination" "$mode" 0 &&
      [[ "$(renewal_sha256_file "$destination")" == "$expected_sha" ]]
}

renewal_install_text_noclobber()
{
    local destination=$1 mode=$2 expected_sha=$3 directory temporary
    directory=$(dirname -- "$destination")
    if [[ -e "$destination" || -L "$destination" ]]; then
        renewal_secure_file_for_uid "$destination" "$mode" 0 &&
          [[ "$(renewal_sha256_file "$destination")" == "$expected_sha" ]]
        return
    fi
    temporary=$(mktemp "$directory/.install-text.XXXXXX") || return 1
    cat >"$temporary" || { rm -f -- "$temporary"; return 1; }
    if ! chown root:root "$temporary" || ! chmod "$mode" "$temporary"; then
        rm -f -- "$temporary"
        return 1
    fi
    [[ "$(renewal_sha256_file "$temporary")" == "$expected_sha" ]] || {
        rm -f -- "$temporary"; return 1;
    }
    sync -f "$temporary" || { rm -f -- "$temporary"; return 1; }
    renewal_move_noclobber "$temporary" "$destination" || { rm -f -- "$temporary"; return 1; }
    [[ ! -e "$temporary" && ! -L "$temporary" ]] || { rm -f -- "$temporary"; return 1; }
    sync -f "$destination" && sync -f "$directory"
}

renewal_install_text_replace()
{
    local destination=$1 mode=$2 expected_sha=$3 directory temporary
    directory=$(dirname -- "$destination")
    [[ -d "$directory" && ! -L "$directory" ]] || return 1
    temporary=$(mktemp "$directory/.install-replace.XXXXXX") || return 1
    cat >"$temporary" || { rm -f -- "$temporary"; return 1; }
    if ! chown root:root "$temporary" || ! chmod "$mode" "$temporary" ||
      [[ "$(renewal_sha256_file "$temporary")" != "$expected_sha" ]] ||
      ! sync -f "$temporary"; then
        rm -f -- "$temporary"
        return 1
    fi
    renewal_move_replace_file "$temporary" "$destination" || { rm -f -- "$temporary"; return 1; }
    [[ ! -e "$temporary" && ! -L "$temporary" ]] || { rm -f -- "$temporary"; return 1; }
    sync -f "$destination" && sync -f "$directory" || return 1
    renewal_secure_file_for_uid "$destination" "$mode" 0 &&
      [[ "$(renewal_sha256_file "$destination")" == "$expected_sha" ]]
}

renewal_active_authority_pair_is_valid()
{
    local authority=$1 sidecar=$2 supervisor=$3 contract=$4 topology=$5 manifest=$6 uid=$7
    local authority_sha validation_epoch
    renewal_secure_file_for_uid "$authority" 600 "$uid" &&
      renewal_secure_file_for_uid "$sidecar" 600 "$uid" || return 1
    authority_sha=$(awk 'NF == 1 && $1 ~ /^[0-9a-f]{64}$/ {print $1}' "$sidecar") || return 1
    [[ -n "$authority_sha" && "$(wc -l <"$sidecar")" -eq 1 &&
       "$(renewal_sha256_file "$authority")" == "$authority_sha" ]] || return 1
    validation_epoch=$(jq -er '.valid_from_epoch | select(type == "number" and floor == .)' \
      "$authority") || return 1
    renewal_validate_authority_semantics "$authority" "$validation_epoch" &&
      renewal_authority_files_match "$authority" "$supervisor" "$contract" "$topology" "$manifest"
}

renewal_authority_rotation_is_valid()
{
    local next_authority=$1 next_sha=$2 previous_authority=$3 previous_sha=$4
    [[ "$(renewal_sha256_file "$next_authority")" == "$next_sha" &&
       "$(renewal_sha256_file "$previous_authority")" == "$previous_sha" ]] || return 1
    jq -e -n --argjson next "$(<"$next_authority")" \
      --argjson previous "$(<"$previous_authority")" --arg previous_sha "$previous_sha" '
      ($next.authority_generation == ($previous.authority_generation + 1)) and
      ($next.supersedes_authority_sha256 == $previous_sha) and
      ($next.authority_nonce != $previous.authority_nonce) and
      ($next.issued_at_epoch > $previous.issued_at_epoch) and
      ($next.valid_from_epoch >= $next.issued_at_epoch) and
      ($next.valid_until_epoch > $previous.valid_until_epoch) and
      ($next.authority_rotation_authorized == true) and
      ($previous.authority_rotation_authorized == true) and
      ($next | del(.authority_generation,.authority_nonce,.issued_at_epoch,.valid_from_epoch,
        .valid_until_epoch,.supersedes_authority_sha256)) ==
      ($previous | del(.authority_generation,.authority_nonce,.issued_at_epoch,.valid_from_epoch,
        .valid_until_epoch,.supersedes_authority_sha256))
    ' >/dev/null
}

renewal_archive_active_authority()
{
    local authority=$1 sidecar=$2 receipt=$3 history=$4 uid=$5
    local authority_sha generation nonce stem sidecar_sha receipt_sha
    renewal_active_authority_pair_is_valid "$authority" "$sidecar" "$INSTALLED_SUPERVISOR" \
      "$INSTALLED_JOB10_CONTRACT" "$INSTALLED_TOPOLOGY_MAP" "$INSTALLED_PACKAGE_MANIFEST" "$uid" || return 1
    authority_sha=$(<"$sidecar")
    generation=$(jq -er '.authority_generation' "$authority") || return 1
    nonce=$(jq -er '.authority_nonce' "$authority") || return 1
    [[ "$generation" =~ ^[1-9][0-9]*$ && "$nonce" =~ ^[0-9a-f]{32}$ ]] || return 1
    if [[ ! -e "$history" && ! -L "$history" ]]; then
        install -d -o root -g root -m 0700 "$history" || return 1
        sync -f "$(dirname -- "$history")" || return 1
    fi
    renewal_secure_directory_for_uid "$history" 700 "$uid" || return 1
    stem="generation-${generation}-${nonce}-${authority_sha}"
    renewal_install_exact_file "$authority" "$authority_sha" "$history/$stem.json" 600 || return 1
    sidecar_sha=$(renewal_sha256_file "$sidecar") || return 1
    renewal_install_exact_file "$sidecar" "$sidecar_sha" "$history/$stem.sha256" 600 || return 1
    if [[ -e "$receipt" || -L "$receipt" ]]; then
        renewal_secure_file_for_uid "$receipt" 600 "$uid" || return 1
        receipt_sha=$(renewal_sha256_file "$receipt") || return 1
        renewal_install_exact_file "$receipt" "$receipt_sha" \
          "$history/$stem-INSTALL-RECEIPT.json" 600 || return 1
    fi
    sync -f "$history" || return 1
    printf '%s\n' "$stem"
}

renewal_make_install_receipt()
{
    local authority=$1 authority_sha=$2 supervisor_sha=$3 contract_sha=$4
    local topology_sha=$5 manifest_sha=$6 installed_epoch=$7 installed_utc=$8
    local generation nonce supersedes
    generation=$(jq -er '.authority_generation' "$authority") || return 1
    nonce=$(jq -er '.authority_nonce' "$authority") || return 1
    supersedes=$(jq -er '.supersedes_authority_sha256' "$authority") || return 1
    jq -n --arg authority_sha "$authority_sha" --argjson generation "$generation" \
      --arg nonce "$nonce" --arg supersedes "$supersedes" \
      --arg supervisor_sha "$supervisor_sha" --arg contract_sha "$contract_sha" \
      --arg topology_sha "$topology_sha" --arg manifest_sha "$manifest_sha" \
      --arg cron_sha "$(renewal_cron_sha256)" --arg installed_utc "$installed_utc" \
      --argjson installed_epoch "$installed_epoch" \
      --argjson shared_locks "$(renewal_shared_lock_paths_json)" '{
        schema:1,kind:"blackcoin-pos-unlock-renewal-supervisor-install",status:"installed",
        authority_sha256:$authority_sha,authority_generation:$generation,
        authority_nonce:$nonce,supersedes_authority_sha256:$supersedes,
        supervisor_sha256:$supervisor_sha,historical_job10_contract_sha256:$contract_sha,
        topology_map_sha256:$topology_sha,source_package_manifest_sha256:$manifest_sha,
        cron_sha256:$cron_sha,installed_at_epoch:$installed_epoch,installed_at_utc:$installed_utc,
        shared_locks_held:$shared_locks,receipt_committed_before_cron_activation:true,
        cron_activation_state:"authorized-only-after-receipt-commit",
        historical_job10_receipt_preserved_read_only:true,maintenance_inhibitor_removed:false,
        helper_invoked:false,regular_pow_mutating_rpc_invoked:false,live_fleet_mutated:false
      }'
}

renewal_install_receipt_is_valid()
{
    local receipt=$1 authority=$2 authority_sha=$3 supervisor=$4 contract=$5 topology=$6 manifest=$7 uid=$8
    local generation nonce supersedes
    renewal_secure_file_for_uid "$receipt" 600 "$uid" || return 1
    generation=$(jq -er '.authority_generation' "$authority") || return 1
    nonce=$(jq -er '.authority_nonce' "$authority") || return 1
    supersedes=$(jq -er '.supersedes_authority_sha256' "$authority") || return 1
    jq -e --arg authority_sha "$authority_sha" --argjson generation "$generation" \
      --arg nonce "$nonce" --arg supersedes "$supersedes" \
      --arg supervisor_sha "$(renewal_sha256_file "$supervisor")" \
      --arg contract_sha "$(renewal_sha256_file "$contract")" \
      --arg topology_sha "$(renewal_sha256_file "$topology")" \
      --arg manifest_sha "$(renewal_sha256_file "$manifest")" \
      --arg cron_sha "$(renewal_cron_sha256)" \
      --argjson shared_locks "$(renewal_shared_lock_paths_json)" '
      (keys | sort) == (["authority_generation","authority_nonce","authority_sha256",
        "cron_activation_state","cron_sha256","helper_invoked",
        "historical_job10_contract_sha256","historical_job10_receipt_preserved_read_only",
        "installed_at_epoch","installed_at_utc","kind","live_fleet_mutated",
        "maintenance_inhibitor_removed","receipt_committed_before_cron_activation",
        "regular_pow_mutating_rpc_invoked","schema","shared_locks_held","source_package_manifest_sha256",
        "status","supersedes_authority_sha256","supervisor_sha256","topology_map_sha256"] | sort) and
      .schema == 1 and .kind == "blackcoin-pos-unlock-renewal-supervisor-install" and
      .status == "installed" and .authority_sha256 == $authority_sha and
      .authority_generation == $generation and .authority_nonce == $nonce and
      .supersedes_authority_sha256 == $supersedes and
      .supervisor_sha256 == $supervisor_sha and
      .historical_job10_contract_sha256 == $contract_sha and
      .topology_map_sha256 == $topology_sha and
      .source_package_manifest_sha256 == $manifest_sha and .cron_sha256 == $cron_sha and
      (.installed_at_epoch | type == "number" and floor == . and . > 0) and
      (.installed_at_utc | type == "string" and
        test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
      .shared_locks_held == $shared_locks and .receipt_committed_before_cron_activation == true and
      .cron_activation_state == "authorized-only-after-receipt-commit" and
      .historical_job10_receipt_preserved_read_only == true and
      .maintenance_inhibitor_removed == false and .helper_invoked == false and
      .regular_pow_mutating_rpc_invoked == false and .live_fleet_mutated == false
    ' "$receipt" >/dev/null
}

renewal_cron_activation_is_valid()
{
    local cron=$1 receipt=$2 uid=$3
    renewal_secure_file_for_uid "$cron" 600 "$uid" &&
      renewal_secure_file_for_uid "$receipt" 600 "$uid" &&
      [[ "$(renewal_sha256_file "$cron")" == "$(renewal_cron_sha256)" &&
         "$(jq -er '.cron_sha256' "$receipt")" == "$(renewal_cron_sha256)" &&
         "$(jq -er '.receipt_committed_before_cron_activation' "$receipt")" == true ]]
}

renewal_stage_activation_set()
{
    local authority=$1 authority_sha=$2 receipt=$3 receipt_sha=$4 staging_root=$5 uid=$6
    local stage_dir sidecar_sha cron_sha
    [[ "$uid" -eq 0 ]] || return 1
    if [[ ! -e "$staging_root" && ! -L "$staging_root" ]]; then
        install -d -o root -g root -m 0700 "$staging_root" || return 1
        sync -f "$(dirname -- "$staging_root")" || return 1
    fi
    renewal_secure_directory_for_uid "$staging_root" 700 "$uid" || return 1
    stage_dir="$staging_root/$authority_sha"
    if [[ ! -e "$stage_dir" && ! -L "$stage_dir" ]]; then
        install -d -o root -g root -m 0700 "$stage_dir" || return 1
        sync -f "$staging_root" || return 1
    fi
    renewal_secure_directory_for_uid "$stage_dir" 700 "$uid" || return 1
    renewal_install_exact_file "$authority" "$authority_sha" "$stage_dir/AUTHORITY.json" 600 || return 1
    sidecar_sha=$(printf '%s\n' "$authority_sha" | sha256sum | awk '{print $1}') || return 1
    printf '%s\n' "$authority_sha" | renewal_install_text_noclobber \
      "$stage_dir/AUTHORITY.sha256" 600 "$sidecar_sha" || return 1
    printf '%s\n' "$receipt" | renewal_install_text_noclobber \
      "$stage_dir/INSTALL-RECEIPT.json" 600 "$receipt_sha" || return 1
    cron_sha=$(renewal_cron_sha256) || return 1
    renewal_cron_body | renewal_install_text_noclobber "$stage_dir/CRON" 600 "$cron_sha" || return 1
    sync -f "$stage_dir" || return 1
    renewal_secure_file_for_uid "$stage_dir/AUTHORITY.json" 600 "$uid" &&
      renewal_secure_file_for_uid "$stage_dir/AUTHORITY.sha256" 600 "$uid" &&
      renewal_secure_file_for_uid "$stage_dir/INSTALL-RECEIPT.json" 600 "$uid" &&
      renewal_secure_file_for_uid "$stage_dir/CRON" 600 "$uid" &&
      [[ "$(renewal_sha256_file "$stage_dir/AUTHORITY.json")" == "$authority_sha" &&
         "$(<"$stage_dir/AUTHORITY.sha256")" == "$authority_sha" &&
         "$(renewal_sha256_file "$stage_dir/INSTALL-RECEIPT.json")" == "$receipt_sha" &&
         "$(renewal_sha256_file "$stage_dir/CRON")" == "$cron_sha" ]] || return 1
    printf '%s\n' "$stage_dir"
}

renewal_make_activation_journal()
{
    local install_root=$1 staging_root=$2 history=$3 cron=$4 successor_sha=$5 stage_dir=$6
    local predecessor_present=$7 predecessor_sha=$8 predecessor_stem=$9 created_epoch=${10}
    local zero
    zero=$(printf '0%.0s' {1..64})
    [[ "$predecessor_present" == true || "$predecessor_present" == false ]] || return 1
    if [[ "$predecessor_present" == true ]]; then
        renewal_is_sha256 "$predecessor_sha" || return 1
        [[ "$predecessor_stem" =~ ^generation-[1-9][0-9]*-[0-9a-f]{32}-$predecessor_sha$ ]] || return 1
    else
        predecessor_sha=$zero
        predecessor_stem=''
    fi
    jq -n --arg install_root "$install_root" --arg staging_root "$staging_root" \
      --arg history "$history" --arg cron "$cron" --arg successor_sha "$successor_sha" \
      --arg stage_dir "$stage_dir" --argjson predecessor_present "$predecessor_present" \
      --arg predecessor_sha "$predecessor_sha" --arg predecessor_stem "$predecessor_stem" \
      --argjson created_epoch "$created_epoch" '{
        schema:1,kind:"blackcoin-pos-unlock-renewal-activation-journal",
        state:"activation-in-progress",created_at_epoch:$created_epoch,
        active:{authority:($install_root+"/AUTHORITY.json"),
          sidecar:($install_root+"/AUTHORITY.sha256"),
          receipt:($install_root+"/INSTALL-RECEIPT.json"),cron:$cron},
        successor:{authority_sha256:$successor_sha,stage_dir:$stage_dir,
          authority:($stage_dir+"/AUTHORITY.json"),sidecar:($stage_dir+"/AUTHORITY.sha256"),
          receipt:($stage_dir+"/INSTALL-RECEIPT.json"),cron:($stage_dir+"/CRON")},
        predecessor:{present:$predecessor_present,authority_sha256:$predecessor_sha,
          archive_stem:$predecessor_stem,
          authority:(if $predecessor_present then $history+"/"+$predecessor_stem+".json" else "" end),
          sidecar:(if $predecessor_present then $history+"/"+$predecessor_stem+".sha256" else "" end),
          receipt:(if $predecessor_present then $history+"/"+$predecessor_stem+"-INSTALL-RECEIPT.json" else "" end)},
        recovery_policy:"restore-predecessor-or-empty-before-retry",
        cron_activated_only_after_receipt:true
      }'
}

renewal_activation_journal_is_valid()
{
    local journal=$1 install_root=$2 staging_root=$3 history=$4 cron=$5 uid=$6
    local successor_sha stage_dir predecessor_present predecessor_sha predecessor_stem
    renewal_secure_file_for_uid "$journal" 600 "$uid" || return 1
    jq -e --arg install_root "$install_root" --arg staging_root "$staging_root" \
      --arg history "$history" --arg cron "$cron" '
      (keys | sort) == (["active","created_at_epoch","cron_activated_only_after_receipt",
        "kind","predecessor","recovery_policy","schema","state","successor"] | sort) and
      .schema == 1 and .kind == "blackcoin-pos-unlock-renewal-activation-journal" and
      .state == "activation-in-progress" and
      (.created_at_epoch | type == "number" and floor == . and . > 0) and
      .recovery_policy == "restore-predecessor-or-empty-before-retry" and
      .cron_activated_only_after_receipt == true and
      .active == {authority:($install_root+"/AUTHORITY.json"),
        sidecar:($install_root+"/AUTHORITY.sha256"),
        receipt:($install_root+"/INSTALL-RECEIPT.json"),cron:$cron} and
      (.successor.authority_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
      .successor.stage_dir == ($staging_root+"/"+.successor.authority_sha256) and
      .successor.authority == (.successor.stage_dir+"/AUTHORITY.json") and
      .successor.sidecar == (.successor.stage_dir+"/AUTHORITY.sha256") and
      .successor.receipt == (.successor.stage_dir+"/INSTALL-RECEIPT.json") and
      .successor.cron == (.successor.stage_dir+"/CRON") and
      (.predecessor.present | type == "boolean") and
      (.predecessor.authority_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
      (if .predecessor.present then .predecessor.authority_sha256 as $predecessor_sha |
         (.predecessor.archive_stem | test("^generation-[1-9][0-9]*-[0-9a-f]{32}-"+
           $predecessor_sha+"$")) and
         .predecessor.authority == ($history+"/"+.predecessor.archive_stem+".json") and
         .predecessor.sidecar == ($history+"/"+.predecessor.archive_stem+".sha256") and
         .predecessor.receipt == ($history+"/"+.predecessor.archive_stem+"-INSTALL-RECEIPT.json")
       else .predecessor.authority_sha256 == ("0"*64) and
         .predecessor.archive_stem == "" and .predecessor.authority == "" and
         .predecessor.sidecar == "" and .predecessor.receipt == "" end)
    ' "$journal" >/dev/null || return 1
    successor_sha=$(jq -er '.successor.authority_sha256' "$journal") || return 1
    stage_dir=$(jq -er '.successor.stage_dir' "$journal") || return 1
    renewal_secure_directory_for_uid "$stage_dir" 700 "$uid" || return 1
    renewal_secure_file_for_uid "$stage_dir/AUTHORITY.json" 600 "$uid" &&
      renewal_secure_file_for_uid "$stage_dir/AUTHORITY.sha256" 600 "$uid" &&
      renewal_secure_file_for_uid "$stage_dir/INSTALL-RECEIPT.json" 600 "$uid" &&
      renewal_secure_file_for_uid "$stage_dir/CRON" 600 "$uid" || return 1
    [[ "$(renewal_sha256_file "$stage_dir/AUTHORITY.json")" == "$successor_sha" &&
       "$(<"$stage_dir/AUTHORITY.sha256")" == "$successor_sha" &&
       "$(renewal_sha256_file "$stage_dir/CRON")" == "$(renewal_cron_sha256)" ]] || return 1
    predecessor_present=$(jq -r '.predecessor.present' "$journal") || return 1
    [[ "$predecessor_present" == true || "$predecessor_present" == false ]] || return 1
    if [[ "$predecessor_present" == true ]]; then
        predecessor_sha=$(jq -er '.predecessor.authority_sha256' "$journal") || return 1
        predecessor_stem=$(jq -er '.predecessor.archive_stem' "$journal") || return 1
        renewal_secure_file_for_uid "$history/$predecessor_stem.json" 600 "$uid" &&
          renewal_secure_file_for_uid "$history/$predecessor_stem.sha256" 600 "$uid" &&
          renewal_secure_file_for_uid "$history/$predecessor_stem-INSTALL-RECEIPT.json" 600 "$uid" || return 1
        [[ "$(renewal_sha256_file "$history/$predecessor_stem.json")" == "$predecessor_sha" &&
           "$(<"$history/$predecessor_stem.sha256")" == "$predecessor_sha" ]] || return 1
    fi
}

renewal_file_is_known_or_absent()
{
    local file=$1 mode=$2 uid=$3
    shift 3
    local actual allowed
    if [[ ! -e "$file" && ! -L "$file" ]]; then return 0; fi
    renewal_secure_file_for_uid "$file" "$mode" "$uid" || return 1
    actual=$(renewal_sha256_file "$file") || return 1
    for allowed in "$@"; do [[ "$actual" == "$allowed" ]] && return 0; done
    return 1
}

renewal_remove_known_file()
{
    local file=$1 mode=$2 uid=$3
    shift 3
    renewal_file_is_known_or_absent "$file" "$mode" "$uid" "$@" || return 1
    if [[ -e "$file" || -L "$file" ]]; then
        rm -f -- "$file" || return 1
        [[ ! -e "$file" && ! -L "$file" ]] || return 1
        sync -f "$(dirname -- "$file")" || return 1
    fi
}

renewal_remove_activation_journal()
{
    local journal=$1 uid=$2 expected
    renewal_secure_file_for_uid "$journal" 600 "$uid" || return 1
    expected=$(renewal_sha256_file "$journal") || return 1
    renewal_remove_known_file "$journal" 600 "$uid" "$expected"
}

renewal_recover_activation_journal()
{
    local journal=$1 install_root=$2 staging_root=$3 history=$4 cron=$5
    local supervisor=$6 contract=$7 topology=$8 manifest=$9 uid=${10}
    local successor_sha stage_dir successor_receipt_sha successor_sidecar_sha cron_sha
    local predecessor_present predecessor_sha predecessor_stem predecessor_receipt_sha predecessor_sidecar_sha
    [[ -e "$journal" || -L "$journal" ]] || return 0
    renewal_activation_journal_is_valid "$journal" "$install_root" "$staging_root" \
      "$history" "$cron" "$uid" || return 1
    successor_sha=$(jq -er '.successor.authority_sha256' "$journal") || return 1
    stage_dir=$(jq -er '.successor.stage_dir' "$journal") || return 1
    successor_receipt_sha=$(renewal_sha256_file "$stage_dir/INSTALL-RECEIPT.json") || return 1
    successor_sidecar_sha=$(renewal_sha256_file "$stage_dir/AUTHORITY.sha256") || return 1
    cron_sha=$(renewal_cron_sha256) || return 1
    predecessor_present=$(jq -r '.predecessor.present' "$journal") || return 1
    [[ "$predecessor_present" == true || "$predecessor_present" == false ]] || return 1
    predecessor_sha=$(jq -er '.predecessor.authority_sha256' "$journal") || return 1
    predecessor_stem=$(jq -er '.predecessor.archive_stem' "$journal") || return 1
    if [[ "$predecessor_present" == true ]]; then
        predecessor_receipt_sha=$(renewal_sha256_file \
          "$history/$predecessor_stem-INSTALL-RECEIPT.json") || return 1
        predecessor_sidecar_sha=$(renewal_sha256_file "$history/$predecessor_stem.sha256") || return 1
    else
        predecessor_receipt_sha=''
        predecessor_sidecar_sha=''
    fi
    renewal_file_is_known_or_absent "$install_root/AUTHORITY.json" 600 "$uid" \
      "$successor_sha" "$predecessor_sha" || return 1
    renewal_file_is_known_or_absent "$install_root/AUTHORITY.sha256" 600 "$uid" \
      "$successor_sidecar_sha" "$predecessor_sidecar_sha" || return 1
    renewal_file_is_known_or_absent "$install_root/INSTALL-RECEIPT.json" 600 "$uid" \
      "$successor_receipt_sha" "$predecessor_receipt_sha" || return 1
    renewal_file_is_known_or_absent "$cron" 600 "$uid" "$cron_sha" || return 1
    if [[ "$predecessor_present" == true ]]; then
        renewal_install_text_replace "$install_root/AUTHORITY.json" 600 "$predecessor_sha" \
          <"$history/$predecessor_stem.json" || return 1
        renewal_install_text_replace "$install_root/AUTHORITY.sha256" 600 "$predecessor_sidecar_sha" \
          <"$history/$predecessor_stem.sha256" || return 1
        renewal_install_text_replace "$install_root/INSTALL-RECEIPT.json" 600 "$predecessor_receipt_sha" \
          <"$history/$predecessor_stem-INSTALL-RECEIPT.json" || return 1
        renewal_active_authority_pair_is_valid "$install_root/AUTHORITY.json" \
          "$install_root/AUTHORITY.sha256" "$supervisor" "$contract" "$topology" "$manifest" "$uid" || return 1
        renewal_install_receipt_is_valid "$install_root/INSTALL-RECEIPT.json" \
          "$install_root/AUTHORITY.json" "$predecessor_sha" "$supervisor" "$contract" \
          "$topology" "$manifest" "$uid" || return 1
        renewal_cron_body | renewal_install_text_noclobber "$cron" 600 "$cron_sha" || return 1
        renewal_cron_activation_is_valid "$cron" "$install_root/INSTALL-RECEIPT.json" "$uid" || return 1
    else
        renewal_remove_known_file "$cron" 600 "$uid" "$cron_sha" || return 1
        renewal_remove_known_file "$install_root/INSTALL-RECEIPT.json" 600 "$uid" \
          "$successor_receipt_sha" || return 1
        renewal_remove_known_file "$install_root/AUTHORITY.sha256" 600 "$uid" \
          "$successor_sidecar_sha" || return 1
        renewal_remove_known_file "$install_root/AUTHORITY.json" 600 "$uid" \
          "$successor_sha" || return 1
    fi
    renewal_remove_activation_journal "$journal" "$uid"
}

renewal_deactivate_cron()
{
    local cron=$1 uid=$2 directory
    renewal_secure_file_for_uid "$cron" 600 "$uid" &&
      [[ "$(renewal_sha256_file "$cron")" == "$(renewal_cron_sha256)" ]] || return 1
    directory=$(dirname -- "$cron")
    rm -f -- "$cron" || return 1
    [[ ! -e "$cron" && ! -L "$cron" ]] || return 1
    sync -f "$directory"
}

renewal_gen2_publish_json_noclobber()
{
    local destination=$1 value=$2 expected_sha
    expected_sha=$(printf '%s\n' "$value" | sha256sum | awk '{print $1}') || return 1
    printf '%s\n' "$value" |
      renewal_install_text_noclobber "$destination" 600 "$expected_sha" || return 1
    printf '%s\n' "$expected_sha"
}

renewal_gen2_run_dir_is_secure()
{
    local run_dir=$1 parent base
    [[ "$run_dir" == "$GEN2_ROTATION_ROOT"/* ]] || return 1
    parent=$(dirname -- "$run_dir")
    base=$(basename -- "$run_dir")
    [[ "$parent" == "$GEN2_ROTATION_ROOT" &&
       "$base" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{12}$ ]] || return 1
    renewal_secure_directory_for_owner "$RUNTIME_RECEIPT_ROOT" 700 0 0 &&
      renewal_secure_directory_for_owner "$GEN2_ROTATION_ROOT" 700 0 0 &&
      renewal_secure_directory_for_owner "$run_dir" 700 0 0
}

renewal_gen2_exact_file()
{
    local file=$1 expected_sha=$2
    renewal_secure_file_for_owner "$file" 600 0 0 &&
      [[ "$(renewal_sha256_file "$file")" == "$expected_sha" ]]
}

renewal_gen2_validate_restored_predecessor_core()
{
    local validation_epoch
    renewal_gen2_exact_file "$INSTALLED_SUPERVISOR" \
      "$GEN2_PREDECESSOR_SUPERVISOR_SHA256" &&
      renewal_gen2_exact_file "$INSTALLED_PACKAGE_MANIFEST" \
        "$GEN2_PREDECESSOR_PACKAGE_MANIFEST_SHA256" &&
      renewal_gen2_exact_file "$INSTALLED_AUTHORITY" \
        "$GEN2_PREDECESSOR_AUTHORITY_SHA256" &&
      renewal_gen2_exact_file "$INSTALLED_AUTHORITY_SHA256" \
        "$GEN2_PREDECESSOR_AUTHORITY_SIDECAR_SHA256" &&
      renewal_gen2_exact_file "$INSTALLED_INSTALL_RECEIPT" \
        "$GEN2_PREDECESSOR_INSTALL_RECEIPT_SHA256" &&
      renewal_gen2_exact_file "$CRON_PATH" "$GEN2_PREDECESSOR_CRON_SHA256" &&
      renewal_gen2_exact_file "$INSTALLED_JOB10_CONTRACT" \
        'f5c47596731c0f56729d02d06a6d15c33adf0ac719f0ebca1f758caadd79ac0c' &&
      renewal_gen2_exact_file "$INSTALLED_TOPOLOGY_MAP" \
        '20598574496f82490073ca836c6bedcb98a229cd263698dc7b38896dae1cd260' &&
      renewal_gen2_exact_file "$HISTORICAL_JOB10_RECEIPT" \
        "$GEN2_HISTORICAL_JOB10_RECEIPT_SHA256" || return 1
    [[ "$(<"$INSTALLED_AUTHORITY_SHA256")" == "$GEN2_PREDECESSOR_AUTHORITY_SHA256" &&
       "$(renewal_cron_sha256)" == "$GEN2_PREDECESSOR_CRON_SHA256" ]] || return 1
    renewal_secure_directory_for_owner "$INSTALL_ROOT" 700 0 0 &&
      renewal_secure_directory_for_owner "$RUNTIME_RECEIPT_ROOT" 700 0 0 || return 1
    validation_epoch=$(jq -er '.valid_from_epoch' "$INSTALLED_AUTHORITY") || return 1
    renewal_validate_authority_semantics "$INSTALLED_AUTHORITY" "$validation_epoch" &&
      renewal_authority_files_match "$INSTALLED_AUTHORITY" "$INSTALLED_SUPERVISOR" \
        "$INSTALLED_JOB10_CONTRACT" "$INSTALLED_TOPOLOGY_MAP" \
        "$INSTALLED_PACKAGE_MANIFEST" &&
      renewal_install_receipt_is_valid "$INSTALLED_INSTALL_RECEIPT" \
        "$INSTALLED_AUTHORITY" "$GEN2_PREDECESSOR_AUTHORITY_SHA256" \
        "$INSTALLED_SUPERVISOR" "$INSTALLED_JOB10_CONTRACT" \
        "$INSTALLED_TOPOLOGY_MAP" "$INSTALLED_PACKAGE_MANIFEST" 0 &&
      renewal_cron_activation_is_valid "$CRON_PATH" "$INSTALLED_INSTALL_RECEIPT" 0 &&
      renewal_verify_marker "$MAINTENANCE_MARKER" 0 &&
      renewal_verify_helper "$NORMAL_UNLOCK_HELPER" 0 &&
      renewal_verify_manifest_bytes "$INSTALLED_AUTHORITY" "$STATE_DIR" 0 || return 1
    [[ ! -e "$INSTALLED_ACTIVATION_JOURNAL" && ! -L "$INSTALLED_ACTIVATION_JOURNAL" &&
       ! -e "$GEN2_INITIAL_RUN_CLAIM" && ! -L "$GEN2_INITIAL_RUN_CLAIM" &&
       ! -e "$GEN2_ACTIVATION_RECEIPT" && ! -L "$GEN2_ACTIVATION_RECEIPT" &&
       ! -e "$GEN2_CRON_ACTIVATION_JOURNAL" && ! -L "$GEN2_CRON_ACTIVATION_JOURNAL" ]]
}

renewal_gen2_validate_restored_predecessor()
{
    renewal_gen2_validate_restored_predecessor_core &&
      [[ ! -e "$GEN2_ROTATION_JOURNAL" && ! -L "$GEN2_ROTATION_JOURNAL" ]]
}

renewal_gen2_validate_predecessor()
{
    renewal_package_tree_is_valid "$script_dir" &&
      renewal_gen2_validate_restored_predecessor
}

renewal_gen2_successor_relation_is_valid_for()
{
    local successor=$1 successor_sha=$2 now=$3 previous=$4 previous_sha=$5
    local supervisor=$6 contract=$7 topology=$8 package_manifest=$9 self_sha package_sha
    self_sha=$(renewal_sha256_file "$supervisor") || return 1
    package_sha=$(renewal_sha256_file "$package_manifest") || return 1
    [[ "$(renewal_sha256_file "$successor")" == "$successor_sha" &&
       "$(renewal_sha256_file "$previous")" == "$previous_sha" ]] || return 1
    renewal_validate_authority_semantics "$successor" "$now" &&
      renewal_authority_files_match "$successor" "$supervisor" "$contract" \
        "$topology" "$package_manifest" || return 1
    jq -e -n --argjson next "$(<"$successor")" \
      --argjson previous "$(<"$previous")" --arg previous_sha "$previous_sha" \
      --arg self_sha "$self_sha" --arg package_sha "$package_sha" '
      ($next.authority_generation == 2) and
      ($previous.authority_generation == 1) and
      ($next.supersedes_authority_sha256 == $previous_sha) and
      ($next.authority_nonce != $previous.authority_nonce) and
      ($next.issued_at_epoch > $previous.issued_at_epoch) and
      ($next.valid_from_epoch >= $next.issued_at_epoch) and
      ($next.valid_until_epoch > $previous.valid_until_epoch) and
      ($next.supervisor_sha256 == $self_sha) and
      ($next.package_manifest_sha256 == $package_sha) and
      ($next | del(.authority_generation,.authority_nonce,.issued_at_epoch,.valid_from_epoch,
        .valid_until_epoch,.supersedes_authority_sha256,.supervisor_sha256,
        .package_manifest_sha256)) ==
      ($previous | del(.authority_generation,.authority_nonce,.issued_at_epoch,.valid_from_epoch,
        .valid_until_epoch,.supersedes_authority_sha256,.supervisor_sha256,
        .package_manifest_sha256))
    ' >/dev/null
}

renewal_gen2_successor_relation_is_valid()
{
    renewal_gen2_successor_relation_is_valid_for "$1" "$2" "$3" \
      "$INSTALLED_AUTHORITY" "$GEN2_PREDECESSOR_AUTHORITY_SHA256" \
      "$script_path" "$JOB10_CONTRACT" "$TOPOLOGY_MAP" "$PACKAGE_MANIFEST"
}

renewal_gen2_rotation_authority_is_valid()
{
    local authority=$1 authority_sha=$2 plan_sha=$3 successor_sha=$4 now=$5 self_sha package_sha
    renewal_secure_file_for_owner "$authority" 600 0 0 &&
      [[ "$(renewal_sha256_file "$authority")" == "$authority_sha" ]] || return 1
    self_sha=$(renewal_sha256_file "$script_path") || return 1
    package_sha=$(renewal_sha256_file "$PACKAGE_MANIFEST") || return 1
    jq -e --argjson now "$now" --arg plan_sha "$plan_sha" \
      --arg successor_sha "$successor_sha" \
      --arg predecessor_sha "$GEN2_PREDECESSOR_AUTHORITY_SHA256" \
      --arg self_sha "$self_sha" --arg package_sha "$package_sha" \
      --arg historical_sha "$GEN2_HISTORICAL_JOB10_RECEIPT_SHA256" \
      --argjson max_seconds "$GEN2_ROTATION_AUTHORITY_MAX_SECONDS" '
      (keys | sort) == (["authority_nonce","cron_activation_authorized",
        "financial_action_authorized","initial_run_authorized","issued_at_epoch","kind",
        "node30_role_change_authorized","plan_sha256","predecessor_authority_sha256",
        "reindex_rewind_repair_authorized","schema","source_package_manifest_sha256",
        "source_supervisor_sha256","state","successor_authority_sha256",
        "valid_from_epoch","valid_until_epoch","historical_job10_receipt_sha256"] | sort) and
      .schema == 1 and .kind == "blackcoin-pos-supervisor-generation-2-rotation-authority" and
      .state == "authorized" and
      (.authority_nonce | type == "string" and test("^[0-9a-f]{32}$")) and
      (.issued_at_epoch | type == "number" and floor == . and . > 0) and
      (.valid_from_epoch | type == "number" and floor == .) and
      .valid_from_epoch >= .issued_at_epoch and
      (.valid_until_epoch | type == "number" and floor == .) and
      .valid_until_epoch > .valid_from_epoch and
      .valid_until_epoch <= (.issued_at_epoch + $max_seconds) and
      $now >= .valid_from_epoch and $now <= .valid_until_epoch and
      .plan_sha256 == $plan_sha and .successor_authority_sha256 == $successor_sha and
      .predecessor_authority_sha256 == $predecessor_sha and
      .source_supervisor_sha256 == $self_sha and
      .source_package_manifest_sha256 == $package_sha and
      .historical_job10_receipt_sha256 == $historical_sha and
      .initial_run_authorized == true and .cron_activation_authorized == true and
      .financial_action_authorized == false and .node30_role_change_authorized == false and
      .reindex_rewind_repair_authorized == false
    ' "$authority" >/dev/null
}

renewal_gen2_prepare()
{
    local run_dir=$1 now utc nonce valid_until self_sha package_sha audit audit_sha
    local successor successor_sha plan plan_sha sidecar_sha
    [[ "$EUID" -eq 0 ]] || renewal_die 'generation-2 prepare requires root' || return
    renewal_gen2_run_dir_is_secure "$run_dir" ||
        renewal_die 'generation-2 run directory is not the exact root-owned fresh path' || return
    [[ -z "$(find "$run_dir" -mindepth 1 -maxdepth 1 -print -quit)" ]] ||
        renewal_die 'generation-2 prepare requires an empty one-use run directory' || return
    renewal_acquire_fleet_locks "$GLOBAL_LOCK" "$PER_NODE_LOCK_PATTERN" 0 ||
        renewal_die 'canonical lock set is busy during generation-2 prepare' || return
    renewal_gen2_validate_predecessor ||
        renewal_die 'installed generation-one predecessor set is not exact' || return
    now=$(renewal_now_epoch)
    utc=$(renewal_now_utc)
    nonce=$(head -c 32 /dev/urandom | sha256sum | cut -c1-32) || return 1
    valid_until=$((now + MAXIMUM_AUTHORITY_LIFETIME_SECONDS))
    self_sha=$(renewal_sha256_file "$script_path") || return 1
    package_sha=$(renewal_sha256_file "$PACKAGE_MANIFEST") || return 1
    audit=$(jq -nS --argjson captured "$now" --arg captured_utc "$utc" \
      --arg run_dir "$run_dir" --arg self_sha "$self_sha" --arg package_sha "$package_sha" \
      --arg predecessor_supervisor "$GEN2_PREDECESSOR_SUPERVISOR_SHA256" \
      --arg predecessor_manifest "$GEN2_PREDECESSOR_PACKAGE_MANIFEST_SHA256" \
      --arg predecessor_authority "$GEN2_PREDECESSOR_AUTHORITY_SHA256" \
      --arg predecessor_sidecar "$GEN2_PREDECESSOR_AUTHORITY_SIDECAR_SHA256" \
      --arg predecessor_receipt "$GEN2_PREDECESSOR_INSTALL_RECEIPT_SHA256" \
      --arg cron_sha "$GEN2_PREDECESSOR_CRON_SHA256" \
      --arg historical_sha "$GEN2_HISTORICAL_JOB10_RECEIPT_SHA256" \
      --arg helper_sha "$EXPECTED_HELPER_SHA256" \
      --arg marker_sha "$EXPECTED_MARKER_SHA256" \
      --arg job10_sha "$(renewal_sha256_file "$INSTALLED_JOB10_CONTRACT")" \
      --arg topology_sha "$(renewal_sha256_file "$INSTALLED_TOPOLOGY_MAP")" \
      --argjson shared_locks "$(renewal_shared_lock_paths_json)" \
      --arg global "$GLOBAL_LOCK" --arg per_node "$PER_NODE_LOCK_PATTERN" '{
        schema:1,kind:"blackcoin-pos-supervisor-generation-2-audit",status:"READY",
        captured_at_epoch:$captured,captured_at_utc:$captured_utc,run_dir:$run_dir,
        source:{supervisor_sha256:$self_sha,package_manifest_sha256:$package_sha},
        predecessor:{supervisor_sha256:$predecessor_supervisor,
          package_manifest_sha256:$predecessor_manifest,authority_sha256:$predecessor_authority,
          authority_sidecar_sha256:$predecessor_sidecar,
          install_receipt_sha256:$predecessor_receipt,cron_sha256:$cron_sha},
        unchanged:{normal_unlock_helper_sha256:$helper_sha,maintenance_marker_sha256:$marker_sha,
          historical_job10_contract_sha256:$job10_sha,topology_map_sha256:$topology_sha,
          historical_job10_receipt_sha256:$historical_sha},
        locks:{shared:$shared_locks,global:$global,per_node_pattern:$per_node},
        generation_one_preserved:true,cron_deactivation_before_first_write:true,
        initial_run_before_cron_reactivation:true,helper_invoked:false,docker_contacted:false,
        wallet_contacted:false,regular_pow_mutating_rpc_invoked:false,
        node30_ordinary_pow_changed:false,reindex_rewind_repair_attempted:false
      }') || return 1
    audit_sha=$(renewal_gen2_publish_json_noclobber "$run_dir/AUDIT.json" "$audit") || return 1
    printf '%s\n' "$audit_sha" | renewal_install_text_noclobber \
      "$run_dir/AUDIT.sha256" 600 \
      "$(printf '%s\n' "$audit_sha" | sha256sum | awk '{print $1}')" || return 1
    successor=$(jq -S --arg nonce "$nonce" --argjson issued "$now" \
      --argjson valid_from "$now" --argjson valid_until "$valid_until" \
      --arg predecessor "$GEN2_PREDECESSOR_AUTHORITY_SHA256" \
      --arg self_sha "$self_sha" --arg package_sha "$package_sha" '
        .authority_generation=2 |
        .authority_nonce=$nonce |
        .issued_at_epoch=$issued |
        .valid_from_epoch=$valid_from |
        .valid_until_epoch=$valid_until |
        .supersedes_authority_sha256=$predecessor |
        .supervisor_sha256=$self_sha |
        .package_manifest_sha256=$package_sha
      ' "$INSTALLED_AUTHORITY") || return 1
    successor_sha=$(renewal_gen2_publish_json_noclobber \
      "$run_dir/SUCCESSOR-AUTHORITY.json" "$successor") || return 1
    sidecar_sha=$(printf '%s\n' "$successor_sha" | sha256sum | awk '{print $1}') || return 1
    printf '%s\n' "$successor_sha" | renewal_install_text_noclobber \
      "$run_dir/SUCCESSOR-AUTHORITY.sha256" 600 "$sidecar_sha" || return 1
    renewal_gen2_successor_relation_is_valid "$run_dir/SUCCESSOR-AUTHORITY.json" \
      "$successor_sha" "$now" || return 1
    plan=$(jq -nS --arg audit_sha "$audit_sha" --arg successor_sha "$successor_sha" \
      --arg predecessor_sha "$GEN2_PREDECESSOR_AUTHORITY_SHA256" \
      --arg run_dir "$run_dir" --arg self_sha "$self_sha" --arg package_sha "$package_sha" \
      --arg journal "$GEN2_ROTATION_JOURNAL" --arg cron "$CRON_PATH" \
      --arg initial_claim "$GEN2_INITIAL_RUN_CLAIM" \
      --arg activation_receipt "$GEN2_ACTIVATION_RECEIPT" \
      --argjson prepared "$now" '{
        schema:1,kind:"blackcoin-pos-supervisor-generation-2-plan",status:"READY",
        prepared_at_epoch:$prepared,run_dir:$run_dir,audit_sha256:$audit_sha,
        predecessor_authority_sha256:$predecessor_sha,
        successor_authority_sha256:$successor_sha,
        source_supervisor_sha256:$self_sha,source_package_manifest_sha256:$package_sha,
        journal:$journal,cron_path:$cron,initial_run_claim:$initial_claim,
        activation_receipt:$activation_receipt,
        mutation_order:["durable-backup","archive-generation-one","durable-journal","deactivate-cron",
          "replace-supervisor","replace-package-manifest","replace-authority",
          "replace-authority-sidecar","replace-install-receipt","validate-pending-set",
          "commit-precommit","remove-journal","finalize-pending-result"],
        post_rotation_order:["one-shot-initial-run","verify-unique-PASS-receipt",
          "activate-cron","commit-activation-receipt"],
        rollback:"restore-exact-generation-one-set-and-cron-from-hash-bound-backup",
        historical_job10_preserved_read_only:true,financial_action_authorized:false,
        node30_role_change_authorized:false,reindex_rewind_repair_authorized:false
      }') || return 1
    plan_sha=$(renewal_gen2_publish_json_noclobber "$run_dir/PLAN.json" "$plan") || return 1
    printf '%s\n' "$plan_sha" | renewal_install_text_noclobber \
      "$run_dir/PLAN.sha256" 600 \
      "$(printf '%s\n' "$plan_sha" | sha256sum | awk '{print $1}')" || return 1
    sync -f "$run_dir" || return 1
    printf 'state=prepared run_dir=%s plan_sha256=%s successor_authority_sha256=%s helper_invoked=false docker_contacted=false wallet_contacted=false\n' \
      "$run_dir" "$plan_sha" "$successor_sha"
}

renewal_gen2_prepared_is_valid()
{
    local run_dir=$1 now plan_sha audit_sha successor_sha self_sha package_sha file
    renewal_gen2_run_dir_is_secure "$run_dir" || return 1
    for file in AUDIT.json AUDIT.sha256 SUCCESSOR-AUTHORITY.json \
      SUCCESSOR-AUTHORITY.sha256 PLAN.json PLAN.sha256; do
        renewal_secure_file_for_owner "$run_dir/$file" 600 0 0 || return 1
    done
    audit_sha=$(<"$run_dir/AUDIT.sha256")
    plan_sha=$(<"$run_dir/PLAN.sha256")
    successor_sha=$(<"$run_dir/SUCCESSOR-AUTHORITY.sha256")
    renewal_is_sha256 "$audit_sha" && renewal_is_sha256 "$plan_sha" &&
      renewal_is_sha256 "$successor_sha" || return 1
    [[ "$(renewal_sha256_file "$run_dir/AUDIT.json")" == "$audit_sha" &&
       "$(renewal_sha256_file "$run_dir/PLAN.json")" == "$plan_sha" &&
       "$(renewal_sha256_file "$run_dir/SUCCESSOR-AUTHORITY.json")" == "$successor_sha" &&
       "$(renewal_sha256_file "$run_dir/AUDIT.sha256")" == \
         "$(printf '%s\n' "$audit_sha" | sha256sum | awk '{print $1}')" &&
       "$(renewal_sha256_file "$run_dir/PLAN.sha256")" == \
         "$(printf '%s\n' "$plan_sha" | sha256sum | awk '{print $1}')" &&
       "$(renewal_sha256_file "$run_dir/SUCCESSOR-AUTHORITY.sha256")" == \
         "$(printf '%s\n' "$successor_sha" | sha256sum | awk '{print $1}')" ]] || return 1
    self_sha=$(renewal_sha256_file "$script_path") || return 1
    package_sha=$(renewal_sha256_file "$PACKAGE_MANIFEST") || return 1
    jq -e --arg run_dir "$run_dir" --arg self_sha "$self_sha" \
      --arg package_sha "$package_sha" --arg predecessor "$GEN2_PREDECESSOR_AUTHORITY_SHA256" '
      .schema == 1 and .kind == "blackcoin-pos-supervisor-generation-2-audit" and
      .status == "READY" and .run_dir == $run_dir and
      .source == {supervisor_sha256:$self_sha,package_manifest_sha256:$package_sha} and
      .predecessor.authority_sha256 == $predecessor and
      .generation_one_preserved == true and .cron_deactivation_before_first_write == true and
      .initial_run_before_cron_reactivation == true and .helper_invoked == false and
      .docker_contacted == false and .wallet_contacted == false and
      .regular_pow_mutating_rpc_invoked == false and .node30_ordinary_pow_changed == false and
      .reindex_rewind_repair_attempted == false
    ' "$run_dir/AUDIT.json" >/dev/null || return 1
    jq -e --arg run_dir "$run_dir" --arg audit_sha "$audit_sha" \
      --arg successor_sha "$successor_sha" --arg predecessor "$GEN2_PREDECESSOR_AUTHORITY_SHA256" \
      --arg self_sha "$self_sha" --arg package_sha "$package_sha" '
      .schema == 1 and .kind == "blackcoin-pos-supervisor-generation-2-plan" and
      .status == "READY" and .run_dir == $run_dir and .audit_sha256 == $audit_sha and
      .predecessor_authority_sha256 == $predecessor and
      .successor_authority_sha256 == $successor_sha and
      .source_supervisor_sha256 == $self_sha and
      .source_package_manifest_sha256 == $package_sha and
      .historical_job10_preserved_read_only == true and
      .financial_action_authorized == false and .node30_role_change_authorized == false and
      .reindex_rewind_repair_authorized == false
    ' "$run_dir/PLAN.json" >/dev/null || return 1
    now=$(renewal_now_epoch)
    renewal_gen2_successor_relation_is_valid "$run_dir/SUCCESSOR-AUTHORITY.json" \
      "$successor_sha" "$now"
}

renewal_gen2_backup_predecessor()
{
    local run_dir=$1 backup="$1/BACKUP" manifest manifest_sha
    [[ ! -e "$backup" && ! -L "$backup" ]] || return 1
    install -d -o root -g root -m 0700 "$backup" || return 1
    renewal_install_exact_file "$INSTALLED_SUPERVISOR" \
      "$GEN2_PREDECESSOR_SUPERVISOR_SHA256" "$backup/pos_unlock_renewal_supervisor.sh" 600 || return 1
    renewal_install_exact_file "$INSTALLED_PACKAGE_MANIFEST" \
      "$GEN2_PREDECESSOR_PACKAGE_MANIFEST_SHA256" "$backup/source-package-SHA256SUMS" 600 || return 1
    renewal_install_exact_file "$INSTALLED_AUTHORITY" "$GEN2_PREDECESSOR_AUTHORITY_SHA256" \
      "$backup/AUTHORITY.json" 600 || return 1
    renewal_install_exact_file "$INSTALLED_AUTHORITY_SHA256" \
      "$GEN2_PREDECESSOR_AUTHORITY_SIDECAR_SHA256" "$backup/AUTHORITY.sha256" 600 || return 1
    renewal_install_exact_file "$INSTALLED_INSTALL_RECEIPT" \
      "$GEN2_PREDECESSOR_INSTALL_RECEIPT_SHA256" "$backup/INSTALL-RECEIPT.json" 600 || return 1
    renewal_install_exact_file "$CRON_PATH" "$GEN2_PREDECESSOR_CRON_SHA256" \
      "$backup/CRON" 600 || return 1
    manifest=$(jq -nS --arg supervisor "$GEN2_PREDECESSOR_SUPERVISOR_SHA256" \
      --arg package "$GEN2_PREDECESSOR_PACKAGE_MANIFEST_SHA256" \
      --arg authority "$GEN2_PREDECESSOR_AUTHORITY_SHA256" \
      --arg sidecar "$GEN2_PREDECESSOR_AUTHORITY_SIDECAR_SHA256" \
      --arg receipt "$GEN2_PREDECESSOR_INSTALL_RECEIPT_SHA256" \
      --arg cron "$GEN2_PREDECESSOR_CRON_SHA256" '{
        schema:1,kind:"blackcoin-pos-supervisor-generation-1-backup",status:"COMPLETE",
        files:{"pos_unlock_renewal_supervisor.sh":$supervisor,
          "source-package-SHA256SUMS":$package,"AUTHORITY.json":$authority,
          "AUTHORITY.sha256":$sidecar,"INSTALL-RECEIPT.json":$receipt,"CRON":$cron},
        immutable:true,rollback_source:true
      }') || return 1
    manifest_sha=$(renewal_gen2_publish_json_noclobber "$backup/BACKUP-MANIFEST.json" \
      "$manifest") || return 1
    printf '%s\n' "$manifest_sha" | renewal_install_text_noclobber \
      "$backup/BACKUP-MANIFEST.sha256" 600 \
      "$(printf '%s\n' "$manifest_sha" | sha256sum | awk '{print $1}')" || return 1
    sync -f "$backup" && sync -f "$run_dir"
}

renewal_gen2_archive_predecessor()
{
    local run_dir=$1 history="$INSTALLED_AUTHORITY_HISTORY" nonce stem file sha
    nonce=$(jq -er '.authority_nonce | select(test("^[0-9a-f]{32}$"))' \
      "$run_dir/BACKUP/AUTHORITY.json") || return 1
    stem="generation-1-$nonce-$GEN2_PREDECESSOR_AUTHORITY_SHA256"
    if [[ ! -e "$history" && ! -L "$history" ]]; then
        install -d -o root -g root -m 0700 "$history" || return 1
        sync -f "$INSTALL_ROOT" || return 1
    fi
    renewal_secure_directory_for_owner "$history" 700 0 0 || return 1
    for file in AUTHORITY.json AUTHORITY.sha256 INSTALL-RECEIPT.json \
      pos_unlock_renewal_supervisor.sh source-package-SHA256SUMS; do
        sha=$(renewal_sha256_file "$run_dir/BACKUP/$file") || return 1
        renewal_install_exact_file "$run_dir/BACKUP/$file" "$sha" \
          "$history/$stem-$file" 600 || return 1
    done
    sync -f "$history" || return 1
    printf '%s\n' "$stem"
}

renewal_gen2_stage_successor()
{
    local run_dir=$1 successor_sha=$2 stage="$1/STAGED" now utc receipt receipt_sha sidecar_sha
    [[ ! -e "$stage" && ! -L "$stage" ]] || return 1
    install -d -o root -g root -m 0700 "$stage" || return 1
    renewal_install_exact_file "$script_path" "$(renewal_sha256_file "$script_path")" \
      "$stage/pos_unlock_renewal_supervisor.sh" 600 || return 1
    renewal_install_exact_file "$PACKAGE_MANIFEST" "$(renewal_sha256_file "$PACKAGE_MANIFEST")" \
      "$stage/source-package-SHA256SUMS" 600 || return 1
    renewal_install_exact_file "$run_dir/SUCCESSOR-AUTHORITY.json" "$successor_sha" \
      "$stage/AUTHORITY.json" 600 || return 1
    sidecar_sha=$(renewal_sha256_file "$run_dir/SUCCESSOR-AUTHORITY.sha256") || return 1
    renewal_install_exact_file "$run_dir/SUCCESSOR-AUTHORITY.sha256" "$sidecar_sha" \
      "$stage/AUTHORITY.sha256" 600 || return 1
    now=$(renewal_now_epoch)
    utc=$(renewal_now_utc)
    receipt=$(renewal_make_install_receipt "$stage/AUTHORITY.json" "$successor_sha" \
      "$(renewal_sha256_file "$stage/pos_unlock_renewal_supervisor.sh")" \
      "$(renewal_sha256_file "$INSTALLED_JOB10_CONTRACT")" \
      "$(renewal_sha256_file "$INSTALLED_TOPOLOGY_MAP")" \
      "$(renewal_sha256_file "$stage/source-package-SHA256SUMS")" "$now" "$utc") || return 1
    receipt_sha=$(renewal_gen2_publish_json_noclobber "$stage/INSTALL-RECEIPT.json" \
      "$receipt") || return 1
    printf '%s\n' "$receipt_sha" | renewal_install_text_noclobber \
      "$stage/INSTALL-RECEIPT.sha256" 600 \
      "$(printf '%s\n' "$receipt_sha" | sha256sum | awk '{print $1}')" || return 1
    sync -f "$stage" && sync -f "$run_dir"
}

renewal_gen2_validate_backup_and_stage()
{
    local run_dir=$1 successor_sha=$2 backup="$1/BACKUP" stage="$1/STAGED"
    local staged_supervisor_sha staged_package_sha
    renewal_secure_directory_for_owner "$backup" 700 0 0 &&
      renewal_secure_directory_for_owner "$stage" 700 0 0 || return 1
    renewal_gen2_exact_file "$backup/pos_unlock_renewal_supervisor.sh" \
      "$GEN2_PREDECESSOR_SUPERVISOR_SHA256" &&
      renewal_gen2_exact_file "$backup/source-package-SHA256SUMS" \
        "$GEN2_PREDECESSOR_PACKAGE_MANIFEST_SHA256" &&
      renewal_gen2_exact_file "$backup/AUTHORITY.json" "$GEN2_PREDECESSOR_AUTHORITY_SHA256" &&
      renewal_gen2_exact_file "$backup/AUTHORITY.sha256" \
        "$GEN2_PREDECESSOR_AUTHORITY_SIDECAR_SHA256" &&
      renewal_gen2_exact_file "$backup/INSTALL-RECEIPT.json" \
        "$GEN2_PREDECESSOR_INSTALL_RECEIPT_SHA256" &&
      renewal_gen2_exact_file "$backup/CRON" "$GEN2_PREDECESSOR_CRON_SHA256" || return 1
    renewal_gen2_exact_file "$stage/AUTHORITY.json" "$successor_sha" || return 1
    staged_supervisor_sha=$(jq -er '.supervisor_sha256 | select(test("^[0-9a-f]{64}$"))' \
      "$stage/AUTHORITY.json") || return 1
    staged_package_sha=$(jq -er '.package_manifest_sha256 | select(test("^[0-9a-f]{64}$"))' \
      "$stage/AUTHORITY.json") || return 1
    renewal_gen2_exact_file "$stage/pos_unlock_renewal_supervisor.sh" \
      "$staged_supervisor_sha" &&
      renewal_gen2_exact_file "$stage/source-package-SHA256SUMS" \
        "$staged_package_sha" &&
      renewal_secure_file_for_owner "$stage/AUTHORITY.sha256" 600 0 0 &&
      renewal_secure_file_for_owner "$stage/INSTALL-RECEIPT.json" 600 0 0 &&
      renewal_secure_file_for_owner "$stage/INSTALL-RECEIPT.sha256" 600 0 0 || return 1
    [[ "$(<"$stage/AUTHORITY.sha256")" == "$successor_sha" &&
       "$(renewal_sha256_file "$stage/INSTALL-RECEIPT.json")" == \
         "$(<"$stage/INSTALL-RECEIPT.sha256")" ]] || return 1
    renewal_install_receipt_is_valid "$stage/INSTALL-RECEIPT.json" \
      "$stage/AUTHORITY.json" "$successor_sha" "$stage/pos_unlock_renewal_supervisor.sh" \
      "$INSTALLED_JOB10_CONTRACT" "$INSTALLED_TOPOLOGY_MAP" \
      "$stage/source-package-SHA256SUMS" 0
}

renewal_gen2_validate_pending_set()
{
    local run_dir=$1 successor_sha=$2 now self_sha package_sha
    self_sha=$(renewal_sha256_file "$script_path") || return 1
    package_sha=$(renewal_sha256_file "$PACKAGE_MANIFEST") || return 1
    renewal_gen2_exact_file "$INSTALLED_SUPERVISOR" "$self_sha" &&
      renewal_gen2_exact_file "$INSTALLED_PACKAGE_MANIFEST" "$package_sha" &&
      renewal_gen2_exact_file "$INSTALLED_AUTHORITY" "$successor_sha" &&
      renewal_secure_file_for_owner "$INSTALLED_AUTHORITY_SHA256" 600 0 0 &&
      renewal_secure_file_for_owner "$INSTALLED_INSTALL_RECEIPT" 600 0 0 &&
      [[ "$(<"$INSTALLED_AUTHORITY_SHA256")" == "$successor_sha" ]] || return 1
    now=$(renewal_now_epoch)
    renewal_validate_authority_semantics "$INSTALLED_AUTHORITY" "$now" &&
      renewal_authority_files_match "$INSTALLED_AUTHORITY" "$INSTALLED_SUPERVISOR" \
        "$INSTALLED_JOB10_CONTRACT" "$INSTALLED_TOPOLOGY_MAP" \
        "$INSTALLED_PACKAGE_MANIFEST" &&
      renewal_install_receipt_is_valid "$INSTALLED_INSTALL_RECEIPT" \
        "$INSTALLED_AUTHORITY" "$successor_sha" "$INSTALLED_SUPERVISOR" \
        "$INSTALLED_JOB10_CONTRACT" "$INSTALLED_TOPOLOGY_MAP" \
        "$INSTALLED_PACKAGE_MANIFEST" 0 &&
      renewal_verify_marker "$MAINTENANCE_MARKER" 0 &&
      renewal_verify_helper "$NORMAL_UNLOCK_HELPER" 0 &&
      renewal_verify_manifest_bytes "$INSTALLED_AUTHORITY" "$STATE_DIR" 0 &&
      renewal_gen2_exact_file "$HISTORICAL_JOB10_RECEIPT" \
        "$GEN2_HISTORICAL_JOB10_RECEIPT_SHA256" || return 1
    [[ ! -e "$CRON_PATH" && ! -L "$CRON_PATH" &&
       ! -e "$GEN2_INITIAL_RUN_CLAIM" && ! -L "$GEN2_INITIAL_RUN_CLAIM" &&
       ! -e "$GEN2_ACTIVATION_RECEIPT" && ! -L "$GEN2_ACTIVATION_RECEIPT" &&
       ! -e "$GEN2_CRON_ACTIVATION_JOURNAL" && ! -L "$GEN2_CRON_ACTIVATION_JOURNAL" ]]
}

renewal_gen2_make_journal()
{
    local run_dir=$1 plan_sha=$2 rotation_authority_sha=$3 successor_sha=$4 archive_stem=$5
    jq -nS --arg run_dir "$run_dir" --arg plan_sha "$plan_sha" \
      --arg rotation_authority_sha "$rotation_authority_sha" \
      --arg predecessor_sha "$GEN2_PREDECESSOR_AUTHORITY_SHA256" \
      --arg successor_sha "$successor_sha" --arg archive_stem "$archive_stem" \
      --arg backup_manifest_sha "$(renewal_sha256_file "$run_dir/BACKUP/BACKUP-MANIFEST.json")" \
      --arg successor_receipt_sha "$(renewal_sha256_file "$run_dir/STAGED/INSTALL-RECEIPT.json")" \
      --argjson created "$(renewal_now_epoch)" '{
        schema:1,kind:"blackcoin-pos-supervisor-generation-2-rotation-journal",
        state:"rollback-required-until-journal-removal",created_at_epoch:$created,
        run_dir:$run_dir,plan_sha256:$plan_sha,rotation_authority_sha256:$rotation_authority_sha,
        predecessor_authority_sha256:$predecessor_sha,
        successor_authority_sha256:$successor_sha,archive_stem:$archive_stem,
        backup_manifest_sha256:$backup_manifest_sha,
        successor_install_receipt_sha256:$successor_receipt_sha,
        cron_deactivated_before_active_bytes:true,rollback_on_error_or_signal:true,
        helper_invoked:false,docker_contacted:false,wallet_contacted:false
      }'
}

renewal_gen2_journal_is_valid()
{
    local run_dir=$1 plan_sha=$2 rotation_authority_sha=$3 successor_sha=$4
    renewal_secure_file_for_owner "$GEN2_ROTATION_JOURNAL" 600 0 0 || return 1
    jq -e --arg run_dir "$run_dir" --arg plan_sha "$plan_sha" \
      --arg rotation_authority_sha "$rotation_authority_sha" \
      --arg predecessor_sha "$GEN2_PREDECESSOR_AUTHORITY_SHA256" \
      --arg successor_sha "$successor_sha" \
      --arg backup_manifest_sha "$(renewal_sha256_file "$run_dir/BACKUP/BACKUP-MANIFEST.json")" \
      --arg successor_receipt_sha "$(renewal_sha256_file "$run_dir/STAGED/INSTALL-RECEIPT.json")" '
      (keys | sort) == (["archive_stem","backup_manifest_sha256",
        "created_at_epoch","cron_deactivated_before_active_bytes","docker_contacted",
        "helper_invoked","kind","plan_sha256","predecessor_authority_sha256",
        "rollback_on_error_or_signal","rotation_authority_sha256","run_dir","schema","state",
        "successor_authority_sha256","successor_install_receipt_sha256","wallet_contacted"] | sort) and
      .schema == 1 and .kind == "blackcoin-pos-supervisor-generation-2-rotation-journal" and
      .state == "rollback-required-until-journal-removal" and
      .run_dir == $run_dir and .plan_sha256 == $plan_sha and
      .rotation_authority_sha256 == $rotation_authority_sha and
      .predecessor_authority_sha256 == $predecessor_sha and
      .successor_authority_sha256 == $successor_sha and
      (.archive_stem | test("^generation-1-[0-9a-f]{32}-"+$predecessor_sha+"$")) and
      .backup_manifest_sha256 == $backup_manifest_sha and
      .successor_install_receipt_sha256 == $successor_receipt_sha and
      .cron_deactivated_before_active_bytes == true and .rollback_on_error_or_signal == true and
      .helper_invoked == false and .docker_contacted == false and .wallet_contacted == false
    ' "$GEN2_ROTATION_JOURNAL" >/dev/null
}

renewal_gen2_restore_predecessor()
{
    local run_dir=$1 successor_sha self_sha package_sha successor_sidecar_sha successor_receipt_sha
    local journal_sha plan_sha rotation_authority_sha rollback rollback_sha
    [[ "$RENEWAL_GEN2_ROLLBACK_ACTIVE" == false ]] || return 1
    RENEWAL_GEN2_ROLLBACK_ACTIVE=true
    renewal_gen2_run_dir_is_secure "$run_dir" &&
      renewal_secure_file_for_owner "$GEN2_ROTATION_JOURNAL" 600 0 0 &&
      renewal_secure_file_for_owner "$run_dir/SUCCESSOR-AUTHORITY.sha256" 600 0 0 || return 1
    successor_sha=$(<"$run_dir/SUCCESSOR-AUTHORITY.sha256")
    plan_sha=$(jq -er '.plan_sha256 | select(test("^[0-9a-f]{64}$"))' \
      "$GEN2_ROTATION_JOURNAL") || return 1
    rotation_authority_sha=$(jq -er \
      '.rotation_authority_sha256 | select(test("^[0-9a-f]{64}$"))' \
      "$GEN2_ROTATION_JOURNAL") || return 1
    renewal_is_sha256 "$successor_sha" &&
      [[ "$(jq -er '.successor_authority_sha256' "$GEN2_ROTATION_JOURNAL")" == \
           "$successor_sha" ]] &&
      renewal_gen2_exact_file "$run_dir/SUCCESSOR-AUTHORITY.json" "$successor_sha" &&
      renewal_gen2_validate_backup_and_stage "$run_dir" "$successor_sha" &&
      renewal_gen2_journal_is_valid "$run_dir" "$plan_sha" "$rotation_authority_sha" \
        "$successor_sha" || return 1
    self_sha=$(renewal_sha256_file "$run_dir/STAGED/pos_unlock_renewal_supervisor.sh") || return 1
    package_sha=$(renewal_sha256_file "$run_dir/STAGED/source-package-SHA256SUMS") || return 1
    successor_sidecar_sha=$(renewal_sha256_file "$run_dir/STAGED/AUTHORITY.sha256") || return 1
    successor_receipt_sha=$(renewal_sha256_file "$run_dir/STAGED/INSTALL-RECEIPT.json") || return 1
    renewal_file_is_known_or_absent "$CRON_PATH" 600 0 "$GEN2_PREDECESSOR_CRON_SHA256" || return 1
    renewal_file_is_known_or_absent "$INSTALLED_SUPERVISOR" 600 0 \
      "$GEN2_PREDECESSOR_SUPERVISOR_SHA256" "$self_sha" || return 1
    renewal_file_is_known_or_absent "$INSTALLED_PACKAGE_MANIFEST" 600 0 \
      "$GEN2_PREDECESSOR_PACKAGE_MANIFEST_SHA256" "$package_sha" || return 1
    renewal_file_is_known_or_absent "$INSTALLED_AUTHORITY" 600 0 \
      "$GEN2_PREDECESSOR_AUTHORITY_SHA256" "$successor_sha" || return 1
    renewal_file_is_known_or_absent "$INSTALLED_AUTHORITY_SHA256" 600 0 \
      "$GEN2_PREDECESSOR_AUTHORITY_SIDECAR_SHA256" "$successor_sidecar_sha" || return 1
    renewal_file_is_known_or_absent "$INSTALLED_INSTALL_RECEIPT" 600 0 \
      "$GEN2_PREDECESSOR_INSTALL_RECEIPT_SHA256" "$successor_receipt_sha" || return 1
    renewal_remove_known_file "$CRON_PATH" 600 0 "$GEN2_PREDECESSOR_CRON_SHA256" || return 1
    renewal_install_text_replace "$INSTALLED_SUPERVISOR" 600 \
      "$GEN2_PREDECESSOR_SUPERVISOR_SHA256" \
      <"$run_dir/BACKUP/pos_unlock_renewal_supervisor.sh" || return 1
    renewal_install_text_replace "$INSTALLED_PACKAGE_MANIFEST" 600 \
      "$GEN2_PREDECESSOR_PACKAGE_MANIFEST_SHA256" \
      <"$run_dir/BACKUP/source-package-SHA256SUMS" || return 1
    renewal_install_text_replace "$INSTALLED_AUTHORITY" 600 \
      "$GEN2_PREDECESSOR_AUTHORITY_SHA256" <"$run_dir/BACKUP/AUTHORITY.json" || return 1
    renewal_install_text_replace "$INSTALLED_AUTHORITY_SHA256" 600 \
      "$GEN2_PREDECESSOR_AUTHORITY_SIDECAR_SHA256" \
      <"$run_dir/BACKUP/AUTHORITY.sha256" || return 1
    renewal_install_text_replace "$INSTALLED_INSTALL_RECEIPT" 600 \
      "$GEN2_PREDECESSOR_INSTALL_RECEIPT_SHA256" \
      <"$run_dir/BACKUP/INSTALL-RECEIPT.json" || return 1
    renewal_install_text_noclobber "$CRON_PATH" 600 "$GEN2_PREDECESSOR_CRON_SHA256" \
      <"$run_dir/BACKUP/CRON" || return 1
    renewal_gen2_validate_restored_predecessor_core || return 1
    if [[ -e "$GEN2_ROTATION_JOURNAL" || -L "$GEN2_ROTATION_JOURNAL" ]]; then
        journal_sha=$(renewal_sha256_file "$GEN2_ROTATION_JOURNAL") || return 1
        renewal_remove_known_file "$GEN2_ROTATION_JOURNAL" 600 0 "$journal_sha" || return 1
    fi
    renewal_gen2_validate_restored_predecessor || return 1
    RENEWAL_GEN2_ROLLBACK_ARMED=false
    rollback=$(jq -nS --argjson rolled_back "$(renewal_now_epoch)" \
      --arg predecessor "$GEN2_PREDECESSOR_AUTHORITY_SHA256" '{
        schema:1,kind:"blackcoin-pos-supervisor-generation-2-rollback",status:"ROLLED_BACK",
        rolled_back_at_epoch:$rolled_back,active_authority_sha256:$predecessor,
        generation_one_restored:true,cron_restored:true,historical_archive_preserved:true,
        helper_invoked:false,docker_contacted:false,wallet_contacted:false
      }') || return 1
    rollback_sha=$(renewal_gen2_publish_json_noclobber \
      "$run_dir/ROLLBACK-$(renewal_now_epoch).json" "$rollback") || return 1
    RENEWAL_GEN2_ROLLBACK_ACTIVE=false
    printf 'state=rolled-back run_dir=%s authority_sha256=%s rollback_sha256=%s\n' \
      "$run_dir" "$GEN2_PREDECESSOR_AUTHORITY_SHA256" "$rollback_sha"
}

renewal_gen2_handle_exit()
{
    local status=$?
    trap - EXIT HUP INT TERM
    if [[ "$RENEWAL_GEN2_ROLLBACK_ARMED" == true && -n "$RENEWAL_GEN2_RUN_DIR" ]]; then
        renewal_gen2_restore_predecessor "$RENEWAL_GEN2_RUN_DIR" >&2 ||
          printf 'pos unlock renewal: generation-2 automatic rollback failed closed; journal retained\n' >&2
    fi
    renewal_release_locks
    exit "$status"
}

renewal_gen2_handle_signal()
{
    local status=$1
    exit "$status"
}

renewal_gen2_precommit_is_valid()
{
    local run_dir=$1 precommit="$1/ROTATION-PRECOMMIT.json" plan_sha successor_sha
    local self_sha package_sha journal_sha rotation_authority_sha
    renewal_secure_file_for_owner "$precommit" 600 0 0 || return 1
    plan_sha=$(<"$run_dir/PLAN.sha256")
    successor_sha=$(<"$run_dir/SUCCESSOR-AUTHORITY.sha256")
    self_sha=$(renewal_sha256_file "$INSTALLED_SUPERVISOR") || return 1
    package_sha=$(renewal_sha256_file "$INSTALLED_PACKAGE_MANIFEST") || return 1
    journal_sha=$(jq -er '.journal_sha256' "$precommit") || return 1
    rotation_authority_sha=$(jq -er '.rotation_authority_sha256' "$precommit") || return 1
    renewal_is_sha256 "$journal_sha" && renewal_is_sha256 "$rotation_authority_sha" || return 1
    renewal_secure_file_for_owner "$run_dir/ROTATION-AUTHORITY.json" 600 0 0 &&
      renewal_secure_file_for_owner "$run_dir/ROTATION-AUTHORITY.sha256" 600 0 0 &&
      [[ "$(renewal_sha256_file "$run_dir/ROTATION-AUTHORITY.json")" == \
           "$rotation_authority_sha" &&
         "$(<"$run_dir/ROTATION-AUTHORITY.sha256")" == "$rotation_authority_sha" ]] || return 1
    jq -e --arg run_dir "$run_dir" --arg plan_sha "$plan_sha" \
      --arg predecessor "$GEN2_PREDECESSOR_AUTHORITY_SHA256" \
      --arg successor "$successor_sha" --arg supervisor "$self_sha" \
      --arg package "$package_sha" '
      (keys | sort) == (["cron_active","docker_contacted","generation_one_archived",
        "helper_invoked","initial_run_claimed","installed_at_epoch","journal_sha256","kind",
        "node30_ordinary_pow_changed","package_manifest_sha256","plan_sha256",
        "predecessor_authority_sha256","regular_pow_mutating_rpc_invoked",
        "reindex_rewind_repair_attempted","rotation_authority_sha256","run_dir","schema","status",
        "successor_authority_sha256","supervisor_sha256","wallet_contacted"] | sort) and
      .schema == 1 and .kind == "blackcoin-pos-supervisor-generation-2-rotation-precommit" and
      .status == "INSTALLED_PENDING_INITIAL_RUN" and .run_dir == $run_dir and
      .plan_sha256 == $plan_sha and .predecessor_authority_sha256 == $predecessor and
      .successor_authority_sha256 == $successor and .supervisor_sha256 == $supervisor and
      .package_manifest_sha256 == $package and .generation_one_archived == true and
      .cron_active == false and .initial_run_claimed == false and .helper_invoked == false and
      .docker_contacted == false and .wallet_contacted == false and
      .regular_pow_mutating_rpc_invoked == false and .node30_ordinary_pow_changed == false and
      .reindex_rewind_repair_attempted == false and
      (.rotation_authority_sha256 | test("^[0-9a-f]{64}$")) and
      (.journal_sha256 | test("^[0-9a-f]{64}$"))
    ' "$precommit" >/dev/null
}

renewal_gen2_finalize_rotation_result()
{
    local run_dir=$1 precommit_sha plan_sha successor_sha self_sha package_sha
    local rotation_authority_sha result result_sha
    renewal_gen2_precommit_is_valid "$run_dir" || return 1
    [[ ! -e "$GEN2_ROTATION_JOURNAL" && ! -L "$GEN2_ROTATION_JOURNAL" ]] || return 1
    precommit_sha=$(renewal_sha256_file "$run_dir/ROTATION-PRECOMMIT.json") || return 1
    plan_sha=$(<"$run_dir/PLAN.sha256")
    successor_sha=$(<"$run_dir/SUCCESSOR-AUTHORITY.sha256")
    self_sha=$(renewal_sha256_file "$INSTALLED_SUPERVISOR") || return 1
    package_sha=$(renewal_sha256_file "$INSTALLED_PACKAGE_MANIFEST") || return 1
    rotation_authority_sha=$(jq -er '.rotation_authority_sha256' \
      "$run_dir/ROTATION-PRECOMMIT.json") || return 1
    result=$(jq -nS --argjson committed "$(renewal_now_epoch)" --arg run_dir "$run_dir" \
      --arg plan_sha "$plan_sha" --arg rotation_authority_sha "$rotation_authority_sha" \
      --arg predecessor "$GEN2_PREDECESSOR_AUTHORITY_SHA256" \
      --arg successor "$successor_sha" --arg supervisor "$self_sha" \
      --arg package "$package_sha" --arg precommit_sha "$precommit_sha" '{
        schema:1,kind:"blackcoin-pos-supervisor-generation-2-rotation-result",
        status:"INSTALLED_PENDING_INITIAL_RUN",committed_at_epoch:$committed,
        run_dir:$run_dir,plan_sha256:$plan_sha,rotation_authority_sha256:$rotation_authority_sha,
        predecessor_authority_sha256:$predecessor,successor_authority_sha256:$successor,
        supervisor_sha256:$supervisor,package_manifest_sha256:$package,
        precommit_sha256:$precommit_sha,generation_one_archived:true,
        rollback_journal_absent:true,cron_active:false,initial_run_claimed:false,
        helper_invoked:false,docker_contacted:false,wallet_contacted:false,
        regular_pow_mutating_rpc_invoked:false,node30_ordinary_pow_changed:false,
        reindex_rewind_repair_attempted:false
      }') || return 1
    result_sha=$(renewal_gen2_publish_json_noclobber "$run_dir/ROTATION-RESULT.json" \
      "$result") || return 1
    renewal_gen2_rotation_result_is_valid "$run_dir/ROTATION-RESULT.json" \
      "$result_sha" || return 1
    printf '%s\n' "$result_sha"
}

renewal_gen2_apply_window_is_valid()
{
    local rotation_authority=$1 rotation_authority_sha=$2 plan_sha=$3 successor_sha=$4
    local successor_authority=$5 now
    now=$(renewal_now_epoch) || return 1
    renewal_gen2_rotation_authority_is_valid "$rotation_authority" \
      "$rotation_authority_sha" "$plan_sha" "$successor_sha" "$now" &&
      renewal_authority_has_runway "$successor_authority" "$now" \
        "$((MINIMUM_CYCLE_RUNWAY_SECONDS + GEN2_INITIAL_HANDOFF_MARGIN_SECONDS +
          GEN2_INITIAL_CLAIM_COMMIT_MARGIN_SECONDS))"
}

renewal_gen2_apply()
{
    local run_dir=$1 rotation_authority=$2 rotation_authority_sha=$3
    local plan_sha successor_sha now archive_stem journal journal_sha self_sha package_sha
    local successor_sidecar_sha successor_receipt_sha precommit precommit_sha result_sha
    [[ "$EUID" -eq 0 ]] || renewal_die 'generation-2 apply requires root' || return
    renewal_gen2_prepared_is_valid "$run_dir" ||
        renewal_die 'generation-2 prepared set is invalid or stale' || return
    [[ "$rotation_authority" == "$run_dir/ROTATION-AUTHORITY.json" &&
       -f "$run_dir/ROTATION-AUTHORITY.sha256" &&
       ! -L "$run_dir/ROTATION-AUTHORITY.sha256" ]] ||
        renewal_die 'rotation authority must be the exact preserved run-directory object' || return
    renewal_secure_file_for_owner "$run_dir/ROTATION-AUTHORITY.sha256" 600 0 0 &&
      [[ "$(<"$run_dir/ROTATION-AUTHORITY.sha256")" == "$rotation_authority_sha" ]] ||
        renewal_die 'rotation authority sidecar is invalid' || return
    plan_sha=$(<"$run_dir/PLAN.sha256")
    successor_sha=$(<"$run_dir/SUCCESSOR-AUTHORITY.sha256")
    now=$(renewal_now_epoch)
    renewal_gen2_rotation_authority_is_valid "$rotation_authority" \
      "$rotation_authority_sha" "$plan_sha" "$successor_sha" "$now" ||
        renewal_die 'generation-2 rotation authority is invalid, expired, or does not bind the plan' || return
    renewal_acquire_fleet_locks "$GLOBAL_LOCK" "$PER_NODE_LOCK_PATTERN" 0 ||
        renewal_die 'canonical lock set is busy during generation-2 apply' || return
    renewal_gen2_validate_predecessor ||
        renewal_die 'generation-one predecessor changed after prepare' || return
    renewal_gen2_prepared_is_valid "$run_dir" ||
        renewal_die 'prepared set changed after lock acquisition' || return
    renewal_gen2_rotation_authority_is_valid "$rotation_authority" \
      "$rotation_authority_sha" "$plan_sha" "$successor_sha" "$(renewal_now_epoch)" ||
        renewal_die 'generation-2 authority changed or expired after lock acquisition' || return
    renewal_gen2_apply_window_is_valid "$rotation_authority" "$rotation_authority_sha" \
      "$plan_sha" "$successor_sha" "$run_dir/SUCCESSOR-AUTHORITY.json" ||
        renewal_die 'generation-two successor lacks one full cycle plus handoff and claim-commit runway' || return
    renewal_gen2_backup_predecessor "$run_dir" ||
        renewal_die 'generation-one durable backup failed' || return
    renewal_gen2_stage_successor "$run_dir" "$successor_sha" ||
        renewal_die 'generation-two staging failed' || return
    renewal_gen2_validate_backup_and_stage "$run_dir" "$successor_sha" ||
        renewal_die 'generation-two backup/staging verification failed' || return
    archive_stem=$(renewal_gen2_archive_predecessor "$run_dir") ||
        renewal_die 'generation-one immutable archive failed' || return
    renewal_gen2_apply_window_is_valid "$rotation_authority" "$rotation_authority_sha" \
      "$plan_sha" "$successor_sha" "$run_dir/SUCCESSOR-AUTHORITY.json" ||
        renewal_die 'generation-2 authority or successor runway expired before the durable mutation journal' || return
    journal=$(renewal_gen2_make_journal "$run_dir" "$plan_sha" \
      "$rotation_authority_sha" "$successor_sha" "$archive_stem") || return 1
    journal_sha=$(renewal_gen2_publish_json_noclobber "$GEN2_ROTATION_JOURNAL" "$journal") ||
        renewal_die 'generation-two durable journal publication failed' || return
    renewal_gen2_journal_is_valid "$run_dir" "$plan_sha" "$rotation_authority_sha" \
      "$successor_sha" || renewal_die 'generation-two durable journal verification failed' || return
    RENEWAL_GEN2_RUN_DIR=$run_dir
    RENEWAL_GEN2_ROLLBACK_ARMED=true
    trap renewal_gen2_handle_exit EXIT
    trap 'renewal_gen2_handle_signal 129' HUP
    trap 'renewal_gen2_handle_signal 130' INT
    trap 'renewal_gen2_handle_signal 143' TERM
    renewal_gen2_apply_window_is_valid "$rotation_authority" "$rotation_authority_sha" \
      "$plan_sha" "$successor_sha" "$run_dir/SUCCESSOR-AUTHORITY.json" ||
        renewal_die 'generation-2 authority or successor runway expired after journal publication' || return
    renewal_deactivate_cron "$CRON_PATH" 0 || return 1
    self_sha=$(renewal_sha256_file "$run_dir/STAGED/pos_unlock_renewal_supervisor.sh") || return 1
    package_sha=$(renewal_sha256_file "$run_dir/STAGED/source-package-SHA256SUMS") || return 1
    successor_sidecar_sha=$(renewal_sha256_file "$run_dir/STAGED/AUTHORITY.sha256") || return 1
    successor_receipt_sha=$(renewal_sha256_file "$run_dir/STAGED/INSTALL-RECEIPT.json") || return 1
    renewal_install_text_replace "$INSTALLED_SUPERVISOR" 600 "$self_sha" \
      <"$run_dir/STAGED/pos_unlock_renewal_supervisor.sh" || return 1
    renewal_install_text_replace "$INSTALLED_PACKAGE_MANIFEST" 600 "$package_sha" \
      <"$run_dir/STAGED/source-package-SHA256SUMS" || return 1
    renewal_install_text_replace "$INSTALLED_AUTHORITY" 600 "$successor_sha" \
      <"$run_dir/STAGED/AUTHORITY.json" || return 1
    renewal_install_text_replace "$INSTALLED_AUTHORITY_SHA256" 600 "$successor_sidecar_sha" \
      <"$run_dir/STAGED/AUTHORITY.sha256" || return 1
    renewal_install_text_replace "$INSTALLED_INSTALL_RECEIPT" 600 "$successor_receipt_sha" \
      <"$run_dir/STAGED/INSTALL-RECEIPT.json" || return 1
    renewal_gen2_validate_pending_set "$run_dir" "$successor_sha" || return 1
    renewal_gen2_apply_window_is_valid "$rotation_authority" "$rotation_authority_sha" \
      "$plan_sha" "$successor_sha" "$INSTALLED_AUTHORITY" ||
        renewal_die 'generation-2 authority or successor runway expired before rotation precommit' || return
    precommit=$(jq -nS --argjson installed "$(renewal_now_epoch)" --arg run_dir "$run_dir" \
      --arg plan_sha "$plan_sha" --arg rotation_authority_sha "$rotation_authority_sha" \
      --arg predecessor "$GEN2_PREDECESSOR_AUTHORITY_SHA256" \
      --arg successor "$successor_sha" --arg supervisor "$self_sha" \
      --arg package "$package_sha" --arg journal_sha "$journal_sha" '{
        schema:1,kind:"blackcoin-pos-supervisor-generation-2-rotation-precommit",
        status:"INSTALLED_PENDING_INITIAL_RUN",installed_at_epoch:$installed,
        run_dir:$run_dir,plan_sha256:$plan_sha,rotation_authority_sha256:$rotation_authority_sha,
        predecessor_authority_sha256:$predecessor,successor_authority_sha256:$successor,
        supervisor_sha256:$supervisor,package_manifest_sha256:$package,
        journal_sha256:$journal_sha,cron_active:false,initial_run_claimed:false,
        generation_one_archived:true,helper_invoked:false,docker_contacted:false,
        wallet_contacted:false,regular_pow_mutating_rpc_invoked:false,
        node30_ordinary_pow_changed:false,reindex_rewind_repair_attempted:false
      }') || return 1
    precommit_sha=$(renewal_gen2_publish_json_noclobber "$run_dir/ROTATION-PRECOMMIT.json" \
      "$precommit") || return 1
    renewal_gen2_precommit_is_valid "$run_dir" &&
      [[ "$(renewal_sha256_file "$run_dir/ROTATION-PRECOMMIT.json")" == "$precommit_sha" &&
         "$(renewal_sha256_file "$GEN2_ROTATION_JOURNAL")" == "$journal_sha" &&
         "$(jq -er '.journal_sha256' "$run_dir/ROTATION-PRECOMMIT.json")" == \
           "$journal_sha" ]] || return 1
    renewal_gen2_apply_window_is_valid "$rotation_authority" "$rotation_authority_sha" \
      "$plan_sha" "$successor_sha" "$INSTALLED_AUTHORITY" ||
        renewal_die 'generation-2 authority or successor runway expired after precommit publication' || return
    renewal_remove_known_file "$GEN2_ROTATION_JOURNAL" 600 0 "$journal_sha" || return 1
    RENEWAL_GEN2_ROLLBACK_ARMED=false
    trap - EXIT HUP INT TERM
    result_sha=$(renewal_gen2_finalize_rotation_result "$run_dir") || return 1
    sync -f "$run_dir" || return 1
    renewal_release_locks
    printf 'state=installed-pending-initial-run run_dir=%s authority_sha256=%s supervisor_sha256=%s rotation_result_sha256=%s cron_active=false helper_invoked=false docker_contacted=false wallet_contacted=false\n' \
      "$run_dir" "$successor_sha" "$self_sha" "$result_sha"
}

renewal_gen2_rotation_result_is_valid()
{
    local result=$1 result_sha=$2 run_dir plan_sha successor_sha self_sha package_sha
    local precommit_sha rotation_authority_sha
    renewal_secure_file_for_owner "$result" 600 0 0 &&
      [[ "$(renewal_sha256_file "$result")" == "$result_sha" ]] || return 1
    run_dir=$(jq -er '.run_dir' "$result") || return 1
    [[ "$result" == "$run_dir/ROTATION-RESULT.json" ]] || return 1
    renewal_gen2_run_dir_is_secure "$run_dir" || return 1
    renewal_gen2_precommit_is_valid "$run_dir" || return 1
    plan_sha=$(<"$run_dir/PLAN.sha256")
    successor_sha=$(<"$run_dir/SUCCESSOR-AUTHORITY.sha256")
    self_sha=$(renewal_sha256_file "$INSTALLED_SUPERVISOR") || return 1
    package_sha=$(renewal_sha256_file "$INSTALLED_PACKAGE_MANIFEST") || return 1
    precommit_sha=$(renewal_sha256_file "$run_dir/ROTATION-PRECOMMIT.json") || return 1
    rotation_authority_sha=$(jq -er '.rotation_authority_sha256' \
      "$run_dir/ROTATION-PRECOMMIT.json") || return 1
    jq -e --arg run_dir "$run_dir" --arg plan_sha "$plan_sha" \
      --arg predecessor "$GEN2_PREDECESSOR_AUTHORITY_SHA256" \
      --arg successor "$successor_sha" --arg supervisor "$self_sha" \
      --arg package "$package_sha" --arg precommit_sha "$precommit_sha" \
      --arg rotation_authority_sha "$rotation_authority_sha" '
      (keys | sort) == (["committed_at_epoch","cron_active","docker_contacted",
        "generation_one_archived","helper_invoked","initial_run_claimed","kind",
        "node30_ordinary_pow_changed","package_manifest_sha256","plan_sha256",
        "precommit_sha256","predecessor_authority_sha256",
        "regular_pow_mutating_rpc_invoked","reindex_rewind_repair_attempted",
        "rollback_journal_absent","rotation_authority_sha256","run_dir","schema","status",
        "successor_authority_sha256","supervisor_sha256","wallet_contacted"] | sort) and
      .schema == 1 and .kind == "blackcoin-pos-supervisor-generation-2-rotation-result" and
      .status == "INSTALLED_PENDING_INITIAL_RUN" and .run_dir == $run_dir and
      .plan_sha256 == $plan_sha and .predecessor_authority_sha256 == $predecessor and
      .successor_authority_sha256 == $successor and .supervisor_sha256 == $supervisor and
      .package_manifest_sha256 == $package and .generation_one_archived == true and
      .precommit_sha256 == $precommit_sha and
      .rotation_authority_sha256 == $rotation_authority_sha and
      .rollback_journal_absent == true and .cron_active == false and
      .initial_run_claimed == false and .helper_invoked == false and
      .docker_contacted == false and .wallet_contacted == false and
      .regular_pow_mutating_rpc_invoked == false and .node30_ordinary_pow_changed == false and
      .reindex_rewind_repair_attempted == false and
      (.committed_at_epoch | type == "number" and floor == . and . > 0)
    ' "$result" >/dev/null
}

renewal_gen2_validate_installed_successor_core()
{
    local successor_sha=$1 now self_sha package_sha
    self_sha=$(renewal_sha256_file "$INSTALLED_SUPERVISOR") || return 1
    package_sha=$(renewal_sha256_file "$INSTALLED_PACKAGE_MANIFEST") || return 1
    [[ "$self_sha" == "$(jq -er '.supervisor_sha256' "$INSTALLED_AUTHORITY")" &&
       "$package_sha" == "$(jq -er '.package_manifest_sha256' "$INSTALLED_AUTHORITY")" &&
       "$(renewal_sha256_file "$INSTALLED_AUTHORITY")" == "$successor_sha" &&
       "$(<"$INSTALLED_AUTHORITY_SHA256")" == "$successor_sha" ]] || return 1
    renewal_secure_file_for_owner "$INSTALLED_SUPERVISOR" 600 0 0 &&
      renewal_secure_file_for_owner "$INSTALLED_PACKAGE_MANIFEST" 600 0 0 &&
      renewal_secure_file_for_owner "$INSTALLED_AUTHORITY" 600 0 0 &&
      renewal_secure_file_for_owner "$INSTALLED_AUTHORITY_SHA256" 600 0 0 &&
      renewal_secure_file_for_owner "$INSTALLED_INSTALL_RECEIPT" 600 0 0 || return 1
    now=$(renewal_now_epoch)
    renewal_validate_authority_semantics "$INSTALLED_AUTHORITY" "$now" &&
      renewal_authority_files_match "$INSTALLED_AUTHORITY" "$INSTALLED_SUPERVISOR" \
        "$INSTALLED_JOB10_CONTRACT" "$INSTALLED_TOPOLOGY_MAP" \
        "$INSTALLED_PACKAGE_MANIFEST" &&
      renewal_install_receipt_is_valid "$INSTALLED_INSTALL_RECEIPT" \
        "$INSTALLED_AUTHORITY" "$successor_sha" "$INSTALLED_SUPERVISOR" \
        "$INSTALLED_JOB10_CONTRACT" "$INSTALLED_TOPOLOGY_MAP" \
        "$INSTALLED_PACKAGE_MANIFEST" 0 &&
      renewal_verify_marker "$MAINTENANCE_MARKER" 0 &&
      renewal_verify_helper "$NORMAL_UNLOCK_HELPER" 0 &&
      renewal_verify_manifest_bytes "$INSTALLED_AUTHORITY" "$STATE_DIR" 0 &&
      renewal_gen2_exact_file "$HISTORICAL_JOB10_RECEIPT" \
        "$GEN2_HISTORICAL_JOB10_RECEIPT_SHA256"
}

renewal_gen2_initial_claim_is_valid()
{
    local claim=$1 rotation_result_sha=$2 successor_sha=$3
    renewal_secure_file_for_owner "$claim" 600 0 0 || return 1
    jq -e --arg rotation_result_sha "$rotation_result_sha" \
      --arg successor_sha "$successor_sha" '
      (keys | sort) == (["claimed_at_epoch","claimed_at_utc","kind",
        "rotation_result_sha256","schema","status","successor_authority_sha256"] | sort) and
      .schema == 1 and .kind == "blackcoin-pos-supervisor-generation-2-initial-run-claim" and
      .status == "CLAIMED_NO_RETRY" and .rotation_result_sha256 == $rotation_result_sha and
      .successor_authority_sha256 == $successor_sha and
      (.claimed_at_epoch | type == "number" and floor == . and . > 0) and
      (.claimed_at_utc | type == "string" and
        test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    ' "$claim" >/dev/null
}

renewal_gen2_run_initial()
{
    local rotation_result=$1 rotation_result_sha=$2 run_dir successor_sha authority_sha claim claim_sha
    local now
    [[ "$EUID" -eq 0 ]] || renewal_die 'generation-2 initial run requires root' || return
    [[ "$(renewal_realpath_existing "$script_path")" == "$INSTALLED_SUPERVISOR" ]] ||
        renewal_die 'generation-2 initial run is accepted only from the installed path' || return
    renewal_gen2_rotation_result_is_valid "$rotation_result" "$rotation_result_sha" ||
        renewal_die 'generation-2 rotation result is invalid' || return
    run_dir=$(jq -er '.run_dir' "$rotation_result") || return 1
    successor_sha=$(jq -er '.successor_authority_sha256' "$rotation_result") || return 1
    [[ ! -e "$CRON_PATH" && ! -L "$CRON_PATH" &&
       ! -e "$GEN2_INITIAL_RUN_CLAIM" && ! -L "$GEN2_INITIAL_RUN_CLAIM" &&
       ! -e "$GEN2_ACTIVATION_RECEIPT" && ! -L "$GEN2_ACTIVATION_RECEIPT" &&
       ! -e "$GEN2_ROTATION_JOURNAL" && ! -L "$GEN2_ROTATION_JOURNAL" ]] ||
        renewal_die 'generation-2 initial run is not in the exact unclaimed cron-inert state' || return
    trap renewal_handle_exit EXIT
    trap 'renewal_handle_signal 129 signal_hup' HUP
    trap 'renewal_handle_signal 130 signal_int' INT
    trap 'renewal_handle_signal 143 signal_term' TERM
    renewal_acquire_fleet_locks "$GLOBAL_LOCK" "$PER_NODE_LOCK_PATTERN" 0 ||
        renewal_die 'canonical lock set is busy for generation-2 initial run' || return
    renewal_gen2_rotation_result_is_valid "$rotation_result" "$rotation_result_sha" &&
      renewal_gen2_validate_installed_successor_core "$successor_sha" ||
        renewal_die 'generation-2 installed set changed before the initial run' || return
    [[ ! -e "$CRON_PATH" && ! -L "$CRON_PATH" &&
       ! -e "$GEN2_INITIAL_RUN_CLAIM" && ! -L "$GEN2_INITIAL_RUN_CLAIM" ]] || return 1
    now=$(renewal_now_epoch)
    renewal_authority_has_runway "$INSTALLED_AUTHORITY" "$now" \
      "$((MINIMUM_CYCLE_RUNWAY_SECONDS + GEN2_INITIAL_CLAIM_COMMIT_MARGIN_SECONDS))" ||
        renewal_die 'generation-two successor lacks one full cycle plus claim-commit runway before initial claim' || return
    claim=$(jq -nS --argjson claimed "$(renewal_now_epoch)" \
      --arg claimed_utc "$(renewal_now_utc)" --arg rotation_result_sha "$rotation_result_sha" \
      --arg successor_sha "$successor_sha" '{
        schema:1,kind:"blackcoin-pos-supervisor-generation-2-initial-run-claim",
        status:"CLAIMED_NO_RETRY",claimed_at_epoch:$claimed,claimed_at_utc:$claimed_utc,
        rotation_result_sha256:$rotation_result_sha,successor_authority_sha256:$successor_sha
      }') || return 1
    claim_sha=$(renewal_gen2_publish_json_noclobber "$GEN2_INITIAL_RUN_CLAIM" "$claim") || return 1
    renewal_gen2_initial_claim_is_valid "$GEN2_INITIAL_RUN_CLAIM" \
      "$rotation_result_sha" "$successor_sha" || return 1
    authority_sha=$(<"$INSTALLED_AUTHORITY_SHA256")
    renewal_arm_partial_context "$RUNTIME_RECEIPT_ROOT" 0 "$INSTALLED_AUTHORITY" \
      "$authority_sha" "$(renewal_now_epoch)" "$(renewal_now_utc)" null '[]' '[]'
    renewal_execute_cycle "$INSTALLED_AUTHORITY" "$authority_sha" "$STATE_DIR" \
      "$INSTALLED_TOPOLOGY_MAP" "$NORMAL_UNLOCK_HELPER" "$MAINTENANCE_MARKER" \
      "$RUNTIME_RECEIPT_ROOT" "$GLOBAL_LOCK" "$PER_NODE_LOCK_PATTERN" 0 /run true || return 1
    [[ "$RENEWAL_TERMINAL_RECEIPT" == true && "$RENEWAL_PARTIAL_ARMED" == false ]] || return 1
    renewal_gen2_initial_claim_is_valid "$GEN2_INITIAL_RUN_CLAIM" \
      "$rotation_result_sha" "$successor_sha" || return 1
    trap - EXIT HUP INT TERM
    renewal_cleanup
    printf 'state=initial-run-pass run_dir=%s authority_sha256=%s initial_claim_sha256=%s cron_active=false\n' \
      "$run_dir" "$successor_sha" "$claim_sha"
}

renewal_gen2_pass_receipt_semantics_is_valid()
{
    local receipt=$1 successor_sha=$2 supervisor_sha=$3 helper_sha=$4 marker_sha=$5 claim_epoch=$6
    jq -e --arg authority "$successor_sha" --arg supervisor "$supervisor_sha" \
      --arg helper "$helper_sha" --arg marker "$marker_sha" \
      --arg image_id "$EXPECTED_IMAGE_ID" --arg image_ref "$EXPECTED_IMAGE_REF" \
      --argjson locks "$(renewal_shared_lock_paths_json)" --argjson claim_epoch "$claim_epoch" '
      (keys | sort) == (["authority_sha256","chain_config_key_transaction_mutation_attempted",
        "finished_at_epoch","finished_at_utc","global_and_per_node_locks_held","helper_nodes",
        "helper_order","historical_job10_receipt_preserved_read_only","image_id","image_ref",
        "kind","maintenance_inhibitor_removed","maintenance_marker_sha256",
        "minimum_normal_unlock_remaining_seconds","node30_ordinary_pow_enable_attempted",
        "normal_unlock_helper_sha256","post_helper_wait_seconds","postflight","preflight",
        "regular_pow_mutating_rpc_invoked","regular_pow_rpc_observed","schema","shared_locks_held",
        "stable_census_attempts_maximum","started_at_epoch","started_at_utc","status",
        "supervisor_sha256"] | sort) and
      .schema == 1 and .kind == "blackcoin-pos-unlock-renewal-supervisor-run" and
      .status == "PASS" and .authority_sha256 == $authority and
      .supervisor_sha256 == $supervisor and .normal_unlock_helper_sha256 == $helper and
      .maintenance_marker_sha256 == $marker and .image_id == $image_id and
      .image_ref == $image_ref and .shared_locks_held == $locks and
      .started_at_epoch >= $claim_epoch and
      .finished_at_epoch >= .started_at_epoch and .global_and_per_node_locks_held == true and
      .helper_nodes == [range(1;33)] and .helper_order == "sequential-ascending" and
      .post_helper_wait_seconds == 60 and .minimum_normal_unlock_remaining_seconds == 43200 and
      .stable_census_attempts_maximum == 3 and
      .historical_job10_receipt_preserved_read_only == true and
      .regular_pow_rpc_observed == true and .regular_pow_mutating_rpc_invoked == false and
      .node30_ordinary_pow_enable_attempted == false and .maintenance_inhibitor_removed == false and
      .chain_config_key_transaction_mutation_attempted == false and
      (.preflight | length) == 32 and ([.preflight[].node] == [range(1;33)]) and
      ([.preflight[].tip] | unique | length) == 1 and
      ([.preflight[].height] | unique | length) == 1 and
      (.postflight | length) == 32 and ([.postflight[].node] == [range(1;33)]) and
      ([.postflight[].tip] | unique | length) == 1 and
      ([.postflight[].height] | unique | length) == 1 and
      ([.postflight[] | select(.staking_active == true and .staking_enabled == true and
        .staking_state == "searching" and .weight > 0 and .unlocked_staking_only == false)] |
        length) == 32 and
      ([.postflight[] | select(.node != 30 and .regular_pow_role == "regular-enabled" and
        .pow.enabled == true and .pow.autostart == false and .pow.threads == 1 and
        .pow.cpu_percent == 1 and .pow.allow_automatic_quantum_key_creation == false)] |
        length) == 31 and
      ([.postflight[] | select(.node == 30 and .regular_pow_role == "special-disabled" and
        .pow.enabled == false and .pow.autostart == false and .pow.state == "disabled" and
        .pow.hashrate == 0 and .pow.allow_automatic_quantum_key_creation == false)] | length) == 1
    ' "$receipt" >/dev/null
}

renewal_gen2_pass_receipt_is_valid()
{
    local receipt=$1 receipt_sha=$2 rotation_result_sha=$3 successor_sha nonce claim_epoch matches
    renewal_secure_file_for_owner "$receipt" 600 0 0 &&
      renewal_secure_file_for_owner "$receipt.sha256" 600 0 0 || return 1
    [[ "$(dirname -- "$receipt")" == "$RUNTIME_RECEIPT_ROOT" &&
       "$(renewal_sha256_file "$receipt")" == "$receipt_sha" &&
       "$(<"$receipt.sha256")" == "$receipt_sha" ]] || return 1
    successor_sha=$(<"$INSTALLED_AUTHORITY_SHA256")
    nonce=$(jq -er '.authority_nonce' "$INSTALLED_AUTHORITY") || return 1
    [[ "$(basename -- "$receipt")" =~ ^renewal-[0-9]+-${nonce}[.]json$ ]] || return 1
    renewal_gen2_initial_claim_is_valid "$GEN2_INITIAL_RUN_CLAIM" \
      "$rotation_result_sha" "$successor_sha" || return 1
    claim_epoch=$(jq -er '.claimed_at_epoch' "$GEN2_INITIAL_RUN_CLAIM") || return 1
    matches=$(find "$RUNTIME_RECEIPT_ROOT" -mindepth 1 -maxdepth 1 -type f \
      -name "renewal-*-$nonce.json" -print | wc -l | tr -d ' ') || return 1
    [[ "$matches" == 1 ]] || return 1
    renewal_gen2_pass_receipt_semantics_is_valid "$receipt" "$successor_sha" \
      "$(renewal_sha256_file "$INSTALLED_SUPERVISOR")" "$EXPECTED_HELPER_SHA256" \
      "$EXPECTED_MARKER_SHA256" "$claim_epoch"
}

renewal_gen2_cron_journal_is_valid()
{
    local journal=$1 journal_sha=$2 run_dir=$3 rotation_result_sha=$4 pass_receipt=$5
    local pass_receipt_sha=$6 claim_sha=$7 successor_sha=$8
    renewal_secure_file_for_owner "$journal" 600 0 0 &&
      [[ "$(renewal_sha256_file "$journal")" == "$journal_sha" ]] || return 1
    jq -e --arg run_dir "$run_dir" --arg rotation_result_sha "$rotation_result_sha" \
      --arg pass_receipt "$pass_receipt" --arg pass_receipt_sha "$pass_receipt_sha" \
      --arg claim_sha "$claim_sha" --arg successor_sha "$successor_sha" \
      --arg cron_sha "$GEN2_PREDECESSOR_CRON_SHA256" '
      (keys | sort) == (["created_at_epoch","cron_sha256","initial_pass_receipt",
        "initial_pass_receipt_sha256","initial_run_claim_sha256","kind",
        "rotation_result_sha256","run_dir","schema","state",
        "successor_authority_sha256"] | sort) and
      .schema == 1 and
      .kind == "blackcoin-pos-supervisor-generation-2-cron-activation-journal" and
      .state == "remove-cron-on-error-or-signal" and .run_dir == $run_dir and
      .rotation_result_sha256 == $rotation_result_sha and
      .initial_pass_receipt == $pass_receipt and
      .initial_pass_receipt_sha256 == $pass_receipt_sha and
      .initial_run_claim_sha256 == $claim_sha and
      .successor_authority_sha256 == $successor_sha and .cron_sha256 == $cron_sha and
      (.created_at_epoch | type == "number" and floor == . and . > 0)
    ' "$journal" >/dev/null
}

renewal_gen2_abort_cron_activation()
{
    local receipt_sha journal_sha
    if [[ -e "$CRON_PATH" || -L "$CRON_PATH" ]]; then
        renewal_remove_known_file "$CRON_PATH" 600 0 "$GEN2_PREDECESSOR_CRON_SHA256" || return 1
    fi
    if [[ -e "$GEN2_ACTIVATION_RECEIPT" || -L "$GEN2_ACTIVATION_RECEIPT" ]]; then
        receipt_sha=$(renewal_sha256_file "$GEN2_ACTIVATION_RECEIPT") || return 1
        renewal_remove_known_file "$GEN2_ACTIVATION_RECEIPT" 600 0 "$receipt_sha" || return 1
    fi
    if [[ -e "$GEN2_CRON_ACTIVATION_JOURNAL" || -L "$GEN2_CRON_ACTIVATION_JOURNAL" ]]; then
        journal_sha=$(renewal_sha256_file "$GEN2_CRON_ACTIVATION_JOURNAL") || return 1
        renewal_remove_known_file "$GEN2_CRON_ACTIVATION_JOURNAL" 600 0 "$journal_sha" || return 1
    fi
    RENEWAL_GEN2_CRON_ROLLBACK_ARMED=false
}

renewal_gen2_handle_cron_exit()
{
    local status=$?
    trap - EXIT HUP INT TERM
    if [[ "$RENEWAL_GEN2_CRON_ROLLBACK_ARMED" == true ]]; then
        renewal_gen2_abort_cron_activation >&2 ||
          printf 'pos unlock renewal: generation-2 cron rollback failed closed; activation journal retained\n' >&2
    fi
    renewal_release_locks
    exit "$status"
}

renewal_gen2_activation_receipt_is_valid()
{
    local receipt=$1 receipt_sha=$2 run_dir=$3 rotation_result_sha=$4 pass_receipt=$5
    local pass_receipt_sha=$6 claim_sha=$7 successor_sha=$8
    renewal_secure_file_for_owner "$receipt" 600 0 0 &&
      [[ "$(renewal_sha256_file "$receipt")" == "$receipt_sha" ]] || return 1
    jq -e --arg run_dir "$run_dir" --arg rotation_result_sha "$rotation_result_sha" \
      --arg pass_receipt "$pass_receipt" --arg pass_receipt_sha "$pass_receipt_sha" \
      --arg claim_sha "$claim_sha" --arg successor_sha "$successor_sha" \
      --arg cron_sha "$GEN2_PREDECESSOR_CRON_SHA256" '
      (keys | sort) == (["activated_at_epoch","activated_at_utc","cron_sha256",
        "first_run_terminal_pass","historical_job10_preserved_read_only",
        "initial_pass_receipt","initial_pass_receipt_sha256","initial_run_claim_sha256",
        "kind","node30_ordinary_pow_changed","recurring_cron_active",
        "regular_pow_mutating_rpc_invoked","reindex_rewind_repair_attempted",
        "rotation_result_sha256","run_dir","schema","status",
        "successor_authority_sha256"] | sort) and
      .schema == 1 and .kind == "blackcoin-pos-supervisor-generation-2-activation" and
      .status == "PASS" and .run_dir == $run_dir and
      .rotation_result_sha256 == $rotation_result_sha and
      .initial_pass_receipt == $pass_receipt and
      .initial_pass_receipt_sha256 == $pass_receipt_sha and
      .initial_run_claim_sha256 == $claim_sha and
      .successor_authority_sha256 == $successor_sha and .cron_sha256 == $cron_sha and
      .first_run_terminal_pass == true and .recurring_cron_active == true and
      .historical_job10_preserved_read_only == true and
      .regular_pow_mutating_rpc_invoked == false and .node30_ordinary_pow_changed == false and
      .reindex_rewind_repair_attempted == false and
      (.activated_at_epoch | type == "number" and floor == . and . > 0) and
      (.activated_at_utc | type == "string" and
        test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    ' "$receipt" >/dev/null
}

renewal_gen2_terminal_result_is_valid()
{
    local result=$1 result_sha=$2 run_dir=$3 rotation_result_sha=$4 pass_receipt=$5
    local pass_receipt_sha=$6 activation_sha=$7 successor_sha=$8
    renewal_secure_file_for_owner "$result" 600 0 0 &&
      [[ "$(renewal_sha256_file "$result")" == "$result_sha" ]] || return 1
    jq -e --arg run_dir "$run_dir" --arg rotation_result_sha "$rotation_result_sha" \
      --arg pass_receipt "$pass_receipt" --arg pass_receipt_sha "$pass_receipt_sha" \
      --arg activation_sha "$activation_sha" --arg successor_sha "$successor_sha" \
      --arg cron_sha "$GEN2_PREDECESSOR_CRON_SHA256" '
      (keys | sort) == (["activation_receipt_sha256","completed_at_epoch","cron_sha256",
        "first_run_terminal_pass","historical_job10_preserved_read_only",
        "initial_pass_receipt","initial_pass_receipt_sha256","kind",
        "node30_ordinary_pow_disabled","recurring_cron_active",
        "regular_pow_mutating_rpc_invoked","regular_pow_nodes_observed",
        "reindex_rewind_repair_attempted","rotation_result_sha256","run_dir","schema",
        "staking_nodes_verified","status","successor_authority_sha256"] | sort) and
      .schema == 1 and .kind == "blackcoin-pos-supervisor-generation-2-terminal-result" and
      .status == "PASS" and .run_dir == $run_dir and
      .successor_authority_sha256 == $successor_sha and
      .rotation_result_sha256 == $rotation_result_sha and
      .initial_pass_receipt == $pass_receipt and
      .initial_pass_receipt_sha256 == $pass_receipt_sha and
      .activation_receipt_sha256 == $activation_sha and .cron_sha256 == $cron_sha and
      .first_run_terminal_pass == true and .recurring_cron_active == true and
      .staking_nodes_verified == 32 and .regular_pow_nodes_observed == 31 and
      .node30_ordinary_pow_disabled == true and
      .historical_job10_preserved_read_only == true and
      .regular_pow_mutating_rpc_invoked == false and .reindex_rewind_repair_attempted == false and
      (.completed_at_epoch | type == "number" and floor == . and . > 0)
    ' "$result" >/dev/null
}

renewal_gen2_finalize_terminal_result()
{
    local run_dir=$1 rotation_result_sha=$2 pass_receipt=$3 pass_receipt_sha=$4
    local successor_sha claim_sha activation_sha result
    successor_sha=$(<"$INSTALLED_AUTHORITY_SHA256")
    claim_sha=$(renewal_sha256_file "$GEN2_INITIAL_RUN_CLAIM") || return 1
    activation_sha=$(renewal_sha256_file "$GEN2_ACTIVATION_RECEIPT") || return 1
    [[ ! -e "$GEN2_CRON_ACTIVATION_JOURNAL" && ! -L "$GEN2_CRON_ACTIVATION_JOURNAL" ]] || return 1
    renewal_gen2_activation_receipt_is_valid "$GEN2_ACTIVATION_RECEIPT" "$activation_sha" \
      "$run_dir" "$rotation_result_sha" "$pass_receipt" "$pass_receipt_sha" \
      "$claim_sha" "$successor_sha" &&
      renewal_gen2_pass_receipt_is_valid "$pass_receipt" "$pass_receipt_sha" \
        "$rotation_result_sha" &&
      renewal_cron_activation_is_valid "$CRON_PATH" "$INSTALLED_INSTALL_RECEIPT" 0 || return 1
    result=$(jq -nS --argjson completed "$(renewal_now_epoch)" --arg run_dir "$run_dir" \
      --arg successor_sha "$successor_sha" --arg rotation_result_sha "$rotation_result_sha" \
      --arg pass_receipt "$pass_receipt" --arg pass_receipt_sha "$pass_receipt_sha" \
      --arg activation_sha "$activation_sha" --arg cron_sha "$GEN2_PREDECESSOR_CRON_SHA256" '{
        schema:1,kind:"blackcoin-pos-supervisor-generation-2-terminal-result",status:"PASS",
        completed_at_epoch:$completed,run_dir:$run_dir,successor_authority_sha256:$successor_sha,
        rotation_result_sha256:$rotation_result_sha,initial_pass_receipt:$pass_receipt,
        initial_pass_receipt_sha256:$pass_receipt_sha,activation_receipt_sha256:$activation_sha,
        cron_sha256:$cron_sha,first_run_terminal_pass:true,recurring_cron_active:true,
        staking_nodes_verified:32,regular_pow_nodes_observed:31,node30_ordinary_pow_disabled:true,
        historical_job10_preserved_read_only:true,regular_pow_mutating_rpc_invoked:false,
        reindex_rewind_repair_attempted:false
      }') || return 1
    local result_sha
    result_sha=$(renewal_gen2_publish_json_noclobber "$run_dir/TERMINAL-RESULT.json" \
      "$result") || return 1
    renewal_gen2_terminal_result_is_valid "$run_dir/TERMINAL-RESULT.json" "$result_sha" \
      "$run_dir" "$rotation_result_sha" "$pass_receipt" "$pass_receipt_sha" \
      "$activation_sha" "$successor_sha" || return 1
    printf '%s\n' "$result_sha"
}

renewal_gen2_activation_window_is_valid()
{
    local authority=$1 now
    now=$(renewal_now_epoch) || return 1
    renewal_authority_has_runway "$authority" "$now" "$GEN2_ACTIVATION_RUNWAY_SECONDS"
}

renewal_gen2_activate()
{
    local rotation_result=$1 rotation_result_sha=$2 pass_receipt=$3 pass_receipt_sha=$4
    local run_dir successor_sha claim_sha journal journal_sha activation activation_sha result_sha
    [[ "$EUID" -eq 0 ]] || renewal_die 'generation-2 activation requires root' || return
    [[ "$(renewal_realpath_existing "$script_path")" == "$INSTALLED_SUPERVISOR" ]] ||
        renewal_die 'generation-2 activation is accepted only from the installed path' || return
    renewal_gen2_rotation_result_is_valid "$rotation_result" "$rotation_result_sha" ||
        renewal_die 'generation-2 rotation result is invalid' || return
    run_dir=$(jq -er '.run_dir' "$rotation_result") || return 1
    successor_sha=$(jq -er '.successor_authority_sha256' "$rotation_result") || return 1
    [[ ! -e "$CRON_PATH" && ! -L "$CRON_PATH" &&
       ! -e "$GEN2_ACTIVATION_RECEIPT" && ! -L "$GEN2_ACTIVATION_RECEIPT" &&
       ! -e "$GEN2_CRON_ACTIVATION_JOURNAL" && ! -L "$GEN2_CRON_ACTIVATION_JOURNAL" ]] ||
        renewal_die 'generation-2 cron activation is not in the exact fresh state' || return
    renewal_acquire_fleet_locks "$GLOBAL_LOCK" "$PER_NODE_LOCK_PATTERN" 0 ||
        renewal_die 'canonical lock set is busy during generation-2 cron activation' || return
    renewal_gen2_rotation_result_is_valid "$rotation_result" "$rotation_result_sha" &&
      renewal_gen2_validate_installed_successor_core "$successor_sha" &&
      renewal_gen2_pass_receipt_is_valid "$pass_receipt" "$pass_receipt_sha" \
        "$rotation_result_sha" || renewal_die 'initial PASS receipt or installed set is invalid' || return
    [[ ! -e "$CRON_PATH" && ! -L "$CRON_PATH" ]] || return 1
    claim_sha=$(renewal_sha256_file "$GEN2_INITIAL_RUN_CLAIM") || return 1
    renewal_gen2_activation_window_is_valid "$INSTALLED_AUTHORITY" ||
        renewal_die 'generation-two successor lacks next-slot plus full-cycle runway before cron journal' || return
    journal=$(jq -nS --argjson created "$(renewal_now_epoch)" --arg run_dir "$run_dir" \
      --arg rotation_result_sha "$rotation_result_sha" --arg pass_receipt "$pass_receipt" \
      --arg pass_receipt_sha "$pass_receipt_sha" --arg claim_sha "$claim_sha" \
      --arg successor_sha "$successor_sha" '{
        schema:1,kind:"blackcoin-pos-supervisor-generation-2-cron-activation-journal",
        state:"remove-cron-on-error-or-signal",created_at_epoch:$created,run_dir:$run_dir,
        rotation_result_sha256:$rotation_result_sha,initial_pass_receipt:$pass_receipt,
        initial_pass_receipt_sha256:$pass_receipt_sha,initial_run_claim_sha256:$claim_sha,
        successor_authority_sha256:$successor_sha,cron_sha256:"afc3e525cc21bc41b3979bf7b6752a83c7648bc4b03d3d6ab9e7d900ebe8b2bd"
      }') || return 1
    journal_sha=$(renewal_gen2_publish_json_noclobber "$GEN2_CRON_ACTIVATION_JOURNAL" \
      "$journal") || return 1
    renewal_gen2_cron_journal_is_valid "$GEN2_CRON_ACTIVATION_JOURNAL" "$journal_sha" \
      "$run_dir" "$rotation_result_sha" "$pass_receipt" "$pass_receipt_sha" \
      "$claim_sha" "$successor_sha" || return 1
    RENEWAL_GEN2_CRON_ROLLBACK_ARMED=true
    trap renewal_gen2_handle_cron_exit EXIT
    trap 'renewal_gen2_handle_signal 129' HUP
    trap 'renewal_gen2_handle_signal 130' INT
    trap 'renewal_gen2_handle_signal 143' TERM
    renewal_gen2_activation_window_is_valid "$INSTALLED_AUTHORITY" ||
        renewal_die 'generation-two successor runway expired after cron journal publication' || return
    renewal_cron_body | renewal_install_text_noclobber "$CRON_PATH" 600 \
      "$GEN2_PREDECESSOR_CRON_SHA256" || return 1
    renewal_cron_activation_is_valid "$CRON_PATH" "$INSTALLED_INSTALL_RECEIPT" 0 || return 1
    activation=$(jq -nS --argjson activated "$(renewal_now_epoch)" \
      --arg activated_utc "$(renewal_now_utc)" --arg run_dir "$run_dir" \
      --arg rotation_result_sha "$rotation_result_sha" --arg pass_receipt "$pass_receipt" \
      --arg pass_receipt_sha "$pass_receipt_sha" --arg claim_sha "$claim_sha" \
      --arg successor_sha "$successor_sha" --arg cron_sha "$GEN2_PREDECESSOR_CRON_SHA256" '{
        schema:1,kind:"blackcoin-pos-supervisor-generation-2-activation",status:"PASS",
        activated_at_epoch:$activated,activated_at_utc:$activated_utc,run_dir:$run_dir,
        rotation_result_sha256:$rotation_result_sha,initial_pass_receipt:$pass_receipt,
        initial_pass_receipt_sha256:$pass_receipt_sha,initial_run_claim_sha256:$claim_sha,
        successor_authority_sha256:$successor_sha,cron_sha256:$cron_sha,
        first_run_terminal_pass:true,recurring_cron_active:true,
        historical_job10_preserved_read_only:true,regular_pow_mutating_rpc_invoked:false,
        node30_ordinary_pow_changed:false,reindex_rewind_repair_attempted:false
      }') || return 1
    activation_sha=$(renewal_gen2_publish_json_noclobber "$GEN2_ACTIVATION_RECEIPT" \
      "$activation") || return 1
    renewal_gen2_activation_receipt_is_valid "$GEN2_ACTIVATION_RECEIPT" "$activation_sha" \
      "$run_dir" "$rotation_result_sha" "$pass_receipt" "$pass_receipt_sha" \
      "$claim_sha" "$successor_sha" || return 1
    renewal_gen2_activation_window_is_valid "$INSTALLED_AUTHORITY" ||
        renewal_die 'generation-two successor runway expired before cron activation commit' || return
    renewal_remove_known_file "$GEN2_CRON_ACTIVATION_JOURNAL" 600 0 "$journal_sha" || return 1
    RENEWAL_GEN2_CRON_ROLLBACK_ARMED=false
    trap - EXIT HUP INT TERM
    result_sha=$(renewal_gen2_finalize_terminal_result "$run_dir" "$rotation_result_sha" \
      "$pass_receipt" "$pass_receipt_sha") || return 1
    sync -f "$run_dir" || return 1
    renewal_release_locks
    printf 'state=PASS run_dir=%s authority_sha256=%s initial_pass_receipt_sha256=%s activation_receipt_sha256=%s terminal_result_sha256=%s cron_active=true staking_nodes_verified=32 regular_pow_nodes_observed=31 node30_pow_disabled=true\n' \
      "$run_dir" "$successor_sha" "$pass_receipt_sha" "$activation_sha" "$result_sha"
}

renewal_gen2_reconcile()
{
    local run_dir=$1 journal_run result result_sha successor_sha claim_present=false cron_present=false
    [[ "$EUID" -eq 0 ]] || renewal_die 'generation-2 reconcile requires root' || return
    renewal_gen2_run_dir_is_secure "$run_dir" ||
        renewal_die 'generation-2 reconcile run directory is unsafe' || return
    renewal_acquire_fleet_locks "$GLOBAL_LOCK" "$PER_NODE_LOCK_PATTERN" 0 ||
        renewal_die 'canonical lock set is busy during generation-2 reconcile' || return
    if [[ -e "$GEN2_ROTATION_JOURNAL" || -L "$GEN2_ROTATION_JOURNAL" ]]; then
        renewal_secure_file_for_owner "$GEN2_ROTATION_JOURNAL" 600 0 0 || return 1
        journal_run=$(jq -er '.run_dir' "$GEN2_ROTATION_JOURNAL") || return 1
        [[ "$journal_run" == "$run_dir" ]] ||
            renewal_die 'rotation journal belongs to a different exact run directory' || return
        renewal_gen2_restore_predecessor "$run_dir"
        renewal_release_locks
        return
    fi
    if [[ -e "$GEN2_CRON_ACTIVATION_JOURNAL" || -L "$GEN2_CRON_ACTIVATION_JOURNAL" ]]; then
        renewal_secure_file_for_owner "$GEN2_CRON_ACTIVATION_JOURNAL" 600 0 0 || return 1
        journal_run=$(jq -er '.run_dir' "$GEN2_CRON_ACTIVATION_JOURNAL") || return 1
        [[ "$journal_run" == "$run_dir" ]] ||
            renewal_die 'cron activation journal belongs to a different exact run directory' || return
        renewal_gen2_abort_cron_activation || return 1
        printf 'state=initial-run-consumed-pending-cron-activation run_dir=%s cron_active=false\n' \
          "$run_dir"
        renewal_release_locks
        return
    fi
    if renewal_gen2_validate_restored_predecessor; then
        printf 'state=generation-one-active run_dir=%s authority_sha256=%s cron_active=true\n' \
          "$run_dir" "$GEN2_PREDECESSOR_AUTHORITY_SHA256"
        renewal_release_locks
        return
    fi
    if [[ ! -e "$run_dir/ROTATION-RESULT.json" && ! -L "$run_dir/ROTATION-RESULT.json" &&
          -f "$run_dir/ROTATION-PRECOMMIT.json" && ! -L "$run_dir/ROTATION-PRECOMMIT.json" ]]; then
        successor_sha=$(<"$run_dir/SUCCESSOR-AUTHORITY.sha256")
        renewal_gen2_validate_installed_successor_core "$successor_sha" &&
          [[ ! -e "$CRON_PATH" && ! -L "$CRON_PATH" &&
             ! -e "$GEN2_INITIAL_RUN_CLAIM" && ! -L "$GEN2_INITIAL_RUN_CLAIM" ]] &&
          renewal_gen2_finalize_rotation_result "$run_dir" >/dev/null ||
            renewal_die 'unable to finalize exact journal-free generation-two precommit' || return
    fi
    [[ -f "$run_dir/ROTATION-RESULT.json" && ! -L "$run_dir/ROTATION-RESULT.json" ]] ||
        renewal_die 'no journal and no exact rotation result can explain installed state' || return
    result="$run_dir/ROTATION-RESULT.json"
    result_sha=$(renewal_sha256_file "$result") || return 1
    renewal_gen2_rotation_result_is_valid "$result" "$result_sha" || return 1
    successor_sha=$(jq -er '.successor_authority_sha256' "$result") || return 1
    renewal_gen2_validate_installed_successor_core "$successor_sha" || return 1
    [[ -e "$GEN2_INITIAL_RUN_CLAIM" || -L "$GEN2_INITIAL_RUN_CLAIM" ]] && claim_present=true
    [[ -e "$CRON_PATH" || -L "$CRON_PATH" ]] && cron_present=true
    if [[ "$claim_present" == false && "$cron_present" == false &&
          ! -e "$GEN2_ACTIVATION_RECEIPT" && ! -L "$GEN2_ACTIVATION_RECEIPT" ]]; then
        printf 'state=installed-pending-initial-run run_dir=%s authority_sha256=%s cron_active=false\n' \
          "$run_dir" "$successor_sha"
    elif [[ "$claim_present" == true && "$cron_present" == false &&
            ! -e "$GEN2_ACTIVATION_RECEIPT" && ! -L "$GEN2_ACTIVATION_RECEIPT" ]]; then
        printf 'state=initial-run-consumed-pending-receipt-review-or-cron-activation run_dir=%s authority_sha256=%s cron_active=false\n' \
          "$run_dir" "$successor_sha"
    elif [[ "$claim_present" == true && "$cron_present" == true ]]; then
        local pass_receipt pass_receipt_sha activation_sha claim_sha terminal_sha
        renewal_secure_file_for_owner "$GEN2_ACTIVATION_RECEIPT" 600 0 0 || return 1
        pass_receipt=$(jq -er '.initial_pass_receipt' "$GEN2_ACTIVATION_RECEIPT") || return 1
        pass_receipt_sha=$(jq -er '.initial_pass_receipt_sha256' \
          "$GEN2_ACTIVATION_RECEIPT") || return 1
        activation_sha=$(renewal_sha256_file "$GEN2_ACTIVATION_RECEIPT") || return 1
        claim_sha=$(renewal_sha256_file "$GEN2_INITIAL_RUN_CLAIM") || return 1
        renewal_gen2_activation_receipt_is_valid "$GEN2_ACTIVATION_RECEIPT" "$activation_sha" \
          "$run_dir" "$result_sha" "$pass_receipt" "$pass_receipt_sha" \
          "$claim_sha" "$successor_sha" &&
          renewal_gen2_pass_receipt_is_valid "$pass_receipt" "$pass_receipt_sha" "$result_sha" &&
          renewal_cron_activation_is_valid "$CRON_PATH" "$INSTALLED_INSTALL_RECEIPT" 0 || return 1
        if [[ ! -e "$run_dir/TERMINAL-RESULT.json" && ! -L "$run_dir/TERMINAL-RESULT.json" ]]; then
            terminal_sha=$(renewal_gen2_finalize_terminal_result "$run_dir" "$result_sha" \
              "$pass_receipt" "$pass_receipt_sha") || return 1
        else
            terminal_sha=$(renewal_sha256_file "$run_dir/TERMINAL-RESULT.json") || return 1
        fi
        renewal_gen2_terminal_result_is_valid "$run_dir/TERMINAL-RESULT.json" \
          "$terminal_sha" "$run_dir" "$result_sha" "$pass_receipt" "$pass_receipt_sha" \
          "$activation_sha" "$successor_sha" || return 1
        printf 'state=generation-two-active run_dir=%s authority_sha256=%s terminal_result_sha256=%s cron_active=true\n' \
          "$run_dir" "$successor_sha" "$terminal_sha"
    else
        renewal_die 'unrecognized generation-two activation shape' || return
    fi
    renewal_release_locks
}

renewal_install()
{
    local authority=$1 authority_sha=$2 now self_sha contract_sha topology_sha manifest_sha
    local existing_sha='' receipt receipt_sha installed_epoch installed_utc
    local stage_dir journal journal_sha archive_stem predecessor_present=false predecessor_sha zero
    local successor_sidecar_sha initial_shape='active'
    [[ "$EUID" -eq 0 ]] || renewal_die 'install requires root' || return
    renewal_secure_file_for_uid "$authority" 600 0 ||
        renewal_die 'install authority must be a root-owned 0600 single-link regular file' || return
    [[ "$(renewal_sha256_file "$authority")" == "$authority_sha" ]] ||
        renewal_die 'install authority hash mismatch' || return
    renewal_acquire_fleet_locks "$GLOBAL_LOCK" "$PER_NODE_LOCK_PATTERN" 0 ||
        renewal_die 'canonical shared/global/per-node lock set is busy' || return
    if [[ ! -e "$INSTALL_ROOT" && ! -L "$INSTALL_ROOT" ]]; then
        install -d -o root -g root -m 0700 "$INSTALL_ROOT" || return 1
        sync -f "$STATE_DIR" || return 1
    fi
    renewal_secure_directory_for_uid "$INSTALL_ROOT" 700 0 ||
        renewal_die 'install root is not exact root-owned 0700' || return
    if [[ -e "$INSTALLED_ACTIVATION_JOURNAL" || -L "$INSTALLED_ACTIVATION_JOURNAL" ]]; then
        renewal_recover_activation_journal "$INSTALLED_ACTIVATION_JOURNAL" "$INSTALL_ROOT" \
          "$INSTALLED_ACTIVATION_STAGING" "$INSTALLED_AUTHORITY_HISTORY" "$CRON_PATH" \
          "$INSTALLED_SUPERVISOR" "$INSTALLED_JOB10_CONTRACT" "$INSTALLED_TOPOLOGY_MAP" \
          "$INSTALLED_PACKAGE_MANIFEST" 0 ||
            renewal_die 'activation journal recovery failed closed' || return
    fi
    now=$(renewal_now_epoch)
    renewal_validate_authority_semantics "$authority" "$now" ||
        renewal_die 'install authority semantic contract is invalid or expired' || return
    renewal_authority_has_runway "$authority" "$now" "$MINIMUM_CYCLE_RUNWAY_SECONDS" ||
        renewal_die 'install authority lacks one complete bounded-cycle horizon' || return
    renewal_package_tree_is_valid "$script_dir" || renewal_die 'source package seal is invalid' || return
    renewal_job10_contract_is_valid "$JOB10_CONTRACT" ||
        renewal_die 'historical job-10 contract is invalid' || return
    renewal_validate_topology_map "$TOPOLOGY_MAP" || renewal_die 'topology map is invalid' || return
    renewal_authority_files_match "$authority" "$script_path" "$JOB10_CONTRACT" \
      "$TOPOLOGY_MAP" "$PACKAGE_MANIFEST" || renewal_die 'authority does not bind source bytes' || return
    renewal_verify_marker "$MAINTENANCE_MARKER" 0 ||
        renewal_die 'stale maintenance inhibitor is absent or changed' || return
    renewal_verify_helper "$NORMAL_UNLOCK_HELPER" 0 ||
        renewal_die 'installed normal-unlock helper is not the audited object' || return
    renewal_verify_manifest_bytes "$authority" "$STATE_DIR" 0 ||
        renewal_die 'reviewed manifest bytes are incomplete or changed' || return
    if [[ ! -e "$RUNTIME_RECEIPT_ROOT" && ! -L "$RUNTIME_RECEIPT_ROOT" ]]; then
        install -d -o root -g root -m 0700 "$RUNTIME_RECEIPT_ROOT"
        sync -f "$(dirname -- "$RUNTIME_RECEIPT_ROOT")"
    fi
    renewal_secure_directory_for_uid "$RUNTIME_RECEIPT_ROOT" 700 0 ||
        renewal_die 'runtime receipt root is not exact root-owned 0700' || return
    self_sha=$(renewal_sha256_file "$script_path")
    contract_sha=$(renewal_sha256_file "$JOB10_CONTRACT")
    topology_sha=$(renewal_sha256_file "$TOPOLOGY_MAP")
    manifest_sha=$(renewal_sha256_file "$PACKAGE_MANIFEST")
    if [[ -e "$INSTALLED_AUTHORITY" || -L "$INSTALLED_AUTHORITY" ||
          -e "$INSTALLED_AUTHORITY_SHA256" || -L "$INSTALLED_AUTHORITY_SHA256" ]]; then
        [[ -e "$INSTALLED_AUTHORITY" && ! -L "$INSTALLED_AUTHORITY" &&
           -e "$INSTALLED_AUTHORITY_SHA256" && ! -L "$INSTALLED_AUTHORITY_SHA256" ]] ||
            renewal_die 'installed authority pair is incomplete before static reconciliation' || return
    else
        initial_shape=$(renewal_classify_initial_install_shape "$INSTALL_ROOT" \
          "$INSTALLED_SUPERVISOR" "$CRON_PATH" "$self_sha" \
          "$HISTORICAL_PARTIAL_SUPERVISOR_SHA256" 0 0) ||
            renewal_die 'initial install static shape is neither clean nor an exact supervisor singleton' || return
    fi
    if [[ "$initial_shape" == predecessor-singleton ]]; then
        renewal_secure_file_for_owner "$INSTALLED_SUPERVISOR" 600 0 0 &&
          [[ "$(renewal_sha256_file "$INSTALLED_SUPERVISOR")" == \
             "$HISTORICAL_PARTIAL_SUPERVISOR_SHA256" ]] ||
            renewal_die 'partial predecessor supervisor changed before atomic replacement' || return
        renewal_install_text_replace "$INSTALLED_SUPERVISOR" 600 "$self_sha" \
          <"$script_path" || return 1
    else
        renewal_install_exact_file "$script_path" "$self_sha" "$INSTALLED_SUPERVISOR" 600 || return 1
    fi
    renewal_install_exact_file "$JOB10_CONTRACT" "$contract_sha" "$INSTALLED_JOB10_CONTRACT" 600 || return 1
    renewal_install_exact_file "$TOPOLOGY_MAP" "$topology_sha" "$INSTALLED_TOPOLOGY_MAP" 600 || return 1
    renewal_install_exact_file "$PACKAGE_MANIFEST" "$manifest_sha" "$INSTALLED_PACKAGE_MANIFEST" 600 || return 1
    if [[ -e "$INSTALLED_AUTHORITY" || -L "$INSTALLED_AUTHORITY" ||
          -e "$INSTALLED_AUTHORITY_SHA256" || -L "$INSTALLED_AUTHORITY_SHA256" ]]; then
        renewal_active_authority_pair_is_valid "$INSTALLED_AUTHORITY" "$INSTALLED_AUTHORITY_SHA256" \
          "$INSTALLED_SUPERVISOR" "$INSTALLED_JOB10_CONTRACT" "$INSTALLED_TOPOLOGY_MAP" \
          "$INSTALLED_PACKAGE_MANIFEST" 0 || renewal_die 'installed authority pair is incomplete or invalid' || return
        existing_sha=$(<"$INSTALLED_AUTHORITY_SHA256")
        renewal_install_receipt_is_valid "$INSTALLED_INSTALL_RECEIPT" "$INSTALLED_AUTHORITY" \
          "$existing_sha" "$INSTALLED_SUPERVISOR" "$INSTALLED_JOB10_CONTRACT" \
          "$INSTALLED_TOPOLOGY_MAP" "$INSTALLED_PACKAGE_MANIFEST" 0 ||
            renewal_die 'previous install receipt does not bind the active authority' || return
        renewal_cron_activation_is_valid "$CRON_PATH" "$INSTALLED_INSTALL_RECEIPT" 0 ||
            renewal_die 'previous cron activation is not receipt-bound' || return
        if [[ "$existing_sha" == "$authority_sha" ]]; then
            renewal_verify_marker "$MAINTENANCE_MARKER" 0 ||
                renewal_die 'maintenance inhibitor changed during idempotent install' || return
            printf 'state=already-installed authority_sha256=%s supervisor_sha256=%s helper_invoked=false\n' \
              "$authority_sha" "$self_sha"
            return 0
        else
            renewal_authority_rotation_is_valid "$authority" "$authority_sha" \
              "$INSTALLED_AUTHORITY" "$existing_sha" || renewal_die 'authority rotation chain is invalid' || return
            archive_stem=$(renewal_archive_active_authority "$INSTALLED_AUTHORITY" \
              "$INSTALLED_AUTHORITY_SHA256" "$INSTALLED_INSTALL_RECEIPT" \
              "$INSTALLED_AUTHORITY_HISTORY" 0) ||
                renewal_die 'unable to archive active authority before rotation' || return
            predecessor_present=true
            predecessor_sha=$existing_sha
        fi
    else
        zero=$(printf '0%.0s' {1..64})
        [[ "$(jq -er '.authority_generation' "$authority")" -eq 1 &&
           "$(jq -er '.supersedes_authority_sha256' "$authority")" == "$zero" &&
           ! -e "$INSTALLED_INSTALL_RECEIPT" && ! -L "$INSTALLED_INSTALL_RECEIPT" &&
           ! -e "$CRON_PATH" && ! -L "$CRON_PATH" ]] ||
            renewal_die 'initial install requires generation one and no preexisting receipt or cron' || return
        predecessor_sha=$zero
        archive_stem=''
    fi
    installed_epoch=$(renewal_now_epoch)
    installed_utc=$(renewal_now_utc)
    receipt=$(renewal_make_install_receipt "$authority" "$authority_sha" "$self_sha" \
      "$contract_sha" "$topology_sha" "$manifest_sha" "$installed_epoch" "$installed_utc") || return 1
    receipt_sha=$(printf '%s\n' "$receipt" | sha256sum | awk '{print $1}')
    stage_dir=$(renewal_stage_activation_set "$authority" "$authority_sha" "$receipt" \
      "$receipt_sha" "$INSTALLED_ACTIVATION_STAGING" 0) || return 1
    journal=$(renewal_make_activation_journal "$INSTALL_ROOT" "$INSTALLED_ACTIVATION_STAGING" \
      "$INSTALLED_AUTHORITY_HISTORY" "$CRON_PATH" "$authority_sha" "$stage_dir" \
      "$predecessor_present" "$predecessor_sha" "$archive_stem" "$installed_epoch") || return 1
    journal_sha=$(printf '%s\n' "$journal" | sha256sum | awk '{print $1}')
    printf '%s\n' "$journal" | renewal_install_text_noclobber \
      "$INSTALLED_ACTIVATION_JOURNAL" 600 "$journal_sha" || return 1
    renewal_activation_journal_is_valid "$INSTALLED_ACTIVATION_JOURNAL" "$INSTALL_ROOT" \
      "$INSTALLED_ACTIVATION_STAGING" "$INSTALLED_AUTHORITY_HISTORY" "$CRON_PATH" 0 || return 1
    if [[ "$predecessor_present" == true ]]; then
        renewal_deactivate_cron "$CRON_PATH" 0 || return 1
    fi
    renewal_install_text_replace "$INSTALLED_AUTHORITY" 600 "$authority_sha" \
      <"$stage_dir/AUTHORITY.json" || return 1
    successor_sidecar_sha=$(renewal_sha256_file "$stage_dir/AUTHORITY.sha256") || return 1
    renewal_install_text_replace "$INSTALLED_AUTHORITY_SHA256" 600 \
      "$successor_sidecar_sha" \
      <"$stage_dir/AUTHORITY.sha256" || return 1
    renewal_install_text_replace "$INSTALLED_INSTALL_RECEIPT" 600 "$receipt_sha" \
      <"$stage_dir/INSTALL-RECEIPT.json" || return 1
    renewal_active_authority_pair_is_valid "$INSTALLED_AUTHORITY" "$INSTALLED_AUTHORITY_SHA256" \
      "$INSTALLED_SUPERVISOR" "$INSTALLED_JOB10_CONTRACT" "$INSTALLED_TOPOLOGY_MAP" \
      "$INSTALLED_PACKAGE_MANIFEST" 0 || return 1
    renewal_install_receipt_is_valid "$INSTALLED_INSTALL_RECEIPT" "$INSTALLED_AUTHORITY" \
      "$authority_sha" "$INSTALLED_SUPERVISOR" "$INSTALLED_JOB10_CONTRACT" \
      "$INSTALLED_TOPOLOGY_MAP" "$INSTALLED_PACKAGE_MANIFEST" 0 || return 1
    renewal_install_text_noclobber "$CRON_PATH" 600 "$(renewal_cron_sha256)" \
      <"$stage_dir/CRON" || return 1
    renewal_cron_activation_is_valid "$CRON_PATH" "$INSTALLED_INSTALL_RECEIPT" 0 || return 1
    renewal_verify_marker "$MAINTENANCE_MARKER" 0 ||
        renewal_die 'maintenance inhibitor changed during install' || return
    renewal_remove_activation_journal "$INSTALLED_ACTIVATION_JOURNAL" 0 || return 1
    printf 'state=installed authority_sha256=%s supervisor_sha256=%s helper_invoked=false\n' \
      "$authority_sha" "$self_sha"
}

renewal_audit_or_plan()
{
    local mode=$1 authority=${2:-} authority_sha=${3:-} authorized=false reason='authority-not-supplied'
    renewal_job10_contract_is_valid "$JOB10_CONTRACT" || return 1
    renewal_validate_topology_map "$TOPOLOGY_MAP" || return 1
    renewal_package_tree_is_valid "$script_dir" || return 1
    if [[ -n "$authority" || -n "$authority_sha" ]]; then
        [[ -n "$authority" && -n "$authority_sha" &&
           "$(renewal_sha256_file "$authority")" == "$authority_sha" ]] || return 1
        renewal_validate_authority_semantics "$authority" "$(renewal_now_epoch)" || return 1
        renewal_authority_files_match "$authority" "$script_path" "$JOB10_CONTRACT" \
          "$TOPOLOGY_MAP" "$PACKAGE_MANIFEST" || return 1
        authorized=true
        reason='exact-authority-valid'
    fi
    jq -n --arg mode "$mode" --argjson authorized "$authorized" --arg reason "$reason" \
      --arg parent "$TOOLING_PARENT_COMMIT" --arg supervisor_sha "$(renewal_sha256_file "$script_path")" \
      --arg package_sha "$(renewal_sha256_file "$PACKAGE_MANIFEST")" \
      --arg topology_sha "$(renewal_sha256_file "$TOPOLOGY_MAP")" \
      --arg job10_sha "$(renewal_sha256_file "$JOB10_CONTRACT")" \
      --arg historical "$HISTORICAL_JOB10_RECEIPT" \
      --arg install_root "$INSTALL_ROOT" --arg cron_path "$CRON_PATH" \
      --arg global "$GLOBAL_LOCK" --arg per_node "$PER_NODE_LOCK_PATTERN" \
      --argjson shared_locks "$(renewal_shared_lock_paths_json)" '{
        schema:1,mode:$mode,status:"offline-only",tooling_parent_commit:$parent,
        supervisor_sha256:$supervisor_sha,source_package_manifest_sha256:$package_sha,
        topology_map_sha256:$topology_sha,historical_job10_contract_sha256:$job10_sha,
        deployment_authorized:$authorized,authority_status:$reason,
        historical_job10:{one_shot:true,receipt:$historical,preserved_read_only:true,
          installation_or_execution_claimed_by_this_package:false},
        proposed_install_root:$install_root,proposed_cron_path:$cron_path,
        proposed_shared_locks:$shared_locks,proposed_global_lock:$global,
        proposed_per_node_lock_pattern:$per_node,
        helper_nodes:[range(1;33)],helper_order:"sequential-ascending",
        post_helper_wait_seconds:60,minimum_normal_unlock_remaining_seconds:43200,
        regular_pow_observation_rpc_allowed:true,regular_pow_mutation_rpc_allowed:false,
        node30_ordinary_pow_enable_allowed:false,
        maintenance_inhibitor_removal_allowed:false,
        chain_config_key_transaction_mutation_allowed:false,
        live_fleet_contacted:false,live_fleet_mutated:false,installed:false,executed:false
      }'
}

renewal_run_installed()
{
    local authority_sha
    [[ "$EUID" -eq 0 ]] || renewal_die 'run requires root' || return
    [[ "$(renewal_realpath_existing "$script_path")" == "$INSTALLED_SUPERVISOR" ]] ||
        renewal_die 'run is accepted only from the exact installed path' || return
    trap renewal_handle_exit EXIT
    trap 'renewal_handle_signal 129 signal_hup' HUP
    trap 'renewal_handle_signal 130 signal_int' INT
    trap 'renewal_handle_signal 143 signal_term' TERM
    renewal_acquire_fleet_locks "$GLOBAL_LOCK" "$PER_NODE_LOCK_PATTERN" 0 ||
        renewal_die 'canonical shared/global/per-node lock set is busy' || return
    renewal_secure_file_for_owner "$INSTALLED_SUPERVISOR" 600 0 0 &&
      renewal_secure_file_for_uid "$INSTALLED_AUTHORITY" 600 0 &&
      renewal_secure_file_for_uid "$INSTALLED_AUTHORITY_SHA256" 600 0 &&
      renewal_secure_file_for_uid "$INSTALLED_INSTALL_RECEIPT" 600 0 &&
      renewal_secure_file_for_uid "$INSTALLED_JOB10_CONTRACT" 600 0 &&
      renewal_secure_file_for_uid "$INSTALLED_TOPOLOGY_MAP" 600 0 &&
      renewal_secure_file_for_uid "$INSTALLED_PACKAGE_MANIFEST" 600 0 &&
      renewal_secure_file_for_uid "$CRON_PATH" 600 0 ||
        renewal_die 'installed supervisor object set is unsafe' || return
    authority_sha=$(awk 'NF == 1 && $1 ~ /^[0-9a-f]{64}$/ {print $1}' \
      "$INSTALLED_AUTHORITY_SHA256") || return 1
    [[ -n "$authority_sha" && "$(wc -l <"$INSTALLED_AUTHORITY_SHA256")" -eq 1 &&
       "$(renewal_sha256_file "$INSTALLED_AUTHORITY")" == "$authority_sha" ]] ||
        renewal_die 'installed authority sidecar is invalid' || return
    renewal_validate_authority_semantics "$INSTALLED_AUTHORITY" "$(renewal_now_epoch)" ||
        renewal_die 'installed authority is invalid or expired' || return
    renewal_job10_contract_is_valid "$INSTALLED_JOB10_CONTRACT" ||
        renewal_die 'installed historical job-10 contract changed' || return
    renewal_authority_files_match "$INSTALLED_AUTHORITY" "$INSTALLED_SUPERVISOR" \
      "$INSTALLED_JOB10_CONTRACT" "$INSTALLED_TOPOLOGY_MAP" "$INSTALLED_PACKAGE_MANIFEST" ||
        renewal_die 'installed bytes do not match authority' || return
    renewal_install_receipt_is_valid "$INSTALLED_INSTALL_RECEIPT" "$INSTALLED_AUTHORITY" \
      "$authority_sha" "$INSTALLED_SUPERVISOR" "$INSTALLED_JOB10_CONTRACT" \
      "$INSTALLED_TOPOLOGY_MAP" "$INSTALLED_PACKAGE_MANIFEST" 0 ||
        renewal_die 'installed activation receipt is invalid' || return
    renewal_cron_activation_is_valid "$CRON_PATH" "$INSTALLED_INSTALL_RECEIPT" 0 ||
        renewal_die 'cron activation is not bound to the installed receipt' || return
    renewal_execute_cycle "$INSTALLED_AUTHORITY" "$authority_sha" "$STATE_DIR" \
      "$INSTALLED_TOPOLOGY_MAP" "$NORMAL_UNLOCK_HELPER" "$MAINTENANCE_MARKER" \
      "$RUNTIME_RECEIPT_ROOT" "$GLOBAL_LOCK" "$PER_NODE_LOCK_PATTERN" 0 /run true
}

renewal_usage()
{
    printf '%s\n' \
      "usage: $0 audit [AUTHORITY.json AUTHORITY_SHA256]" \
      "       $0 plan [AUTHORITY.json AUTHORITY_SHA256]" \
      "       $0 install AUTHORITY.json AUTHORITY_SHA256" \
      "       $0 run" \
      "       $0 prepare-gen2 /exact/generation-2-run-dir" \
      "       $0 apply-gen2 /exact/generation-2-run-dir ROTATION-AUTHORITY.json SHA256" \
      "       $0 reconcile-gen2 /exact/generation-2-run-dir" \
      "       $0 run-initial ROTATION-RESULT.json SHA256" \
      "       $0 activate-gen2 ROTATION-RESULT.json SHA256 PASS-RECEIPT.json SHA256"
}

renewal_main()
{
    local mode=${1:-}
    renewal_require_supported_bash || return
    renewal_require_commands awk bash chmod chown cut date find flock grep head install jq mktemp mv \
      realpath rm seq sha256sum sleep sort stat sync timeout tr wc
    case "$mode" in
        audit|plan)
            [[ "$#" -eq 1 || "$#" -eq 3 ]] || { renewal_usage >&2; return 64; }
            renewal_audit_or_plan "$mode" "${2:-}" "${3:-}"
            ;;
        install)
            [[ "$#" -eq 3 ]] || { renewal_usage >&2; return 64; }
            renewal_install "$2" "$3"
            ;;
        run)
            [[ "$#" -eq 1 ]] || { renewal_usage >&2; return 64; }
            renewal_run_installed
            ;;
        prepare-gen2)
            [[ "$#" -eq 2 ]] || { renewal_usage >&2; return 64; }
            renewal_gen2_prepare "$2"
            ;;
        apply-gen2)
            [[ "$#" -eq 4 ]] || { renewal_usage >&2; return 64; }
            renewal_gen2_apply "$2" "$3" "$4"
            ;;
        reconcile-gen2)
            [[ "$#" -eq 2 ]] || { renewal_usage >&2; return 64; }
            renewal_gen2_reconcile "$2"
            ;;
        run-initial)
            [[ "$#" -eq 3 ]] || { renewal_usage >&2; return 64; }
            renewal_gen2_run_initial "$2" "$3"
            ;;
        activate-gen2)
            [[ "$#" -eq 5 ]] || { renewal_usage >&2; return 64; }
            renewal_gen2_activate "$2" "$3" "$4" "$5"
            ;;
        *) renewal_usage >&2; return 64 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    renewal_main "$@"
fi
