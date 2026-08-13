#!/usr/bin/env bash
export LC_ALL=C TZ=UTC
set -Eeuo pipefail
umask 077
unset BASH_ENV ENV CDPATH GLOBIGNORE
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

# This is a temporary, fail-closed PoS availability supervisor for the exact
# already-installed v30.1.4 fleet.  It is deliberately incapable of reading or
# changing ordinary PoW RPC state.  Its only wallet mutation is execution of
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

readonly EXPECTED_HELPER_SHA256='acf28446e842fd0fa92b06c2ebc182e9da38fcde7bac06dd920d50a33e4e3dd1'
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
readonly CRON_EXPRESSION='17 */6 * * *'

readonly STATE_DIR='/boot/config/plugins/blackcoin-quantum-nodes'
readonly NORMAL_UNLOCK_HELPER="$STATE_DIR/blackcoin_node_normal_unlock.sh"
readonly MAINTENANCE_MARKER="$STATE_DIR/V30_1_4_ROLLOUT_MAINTENANCE.json"
readonly GLOBAL_LOCK='/run/blackcoin-emergency-pos-renewal.lock'
readonly PER_NODE_LOCK_PATTERN='/run/blackcoin-pos-unlock-renewal-node-%02d.lock'
readonly INSTALL_ROOT="$STATE_DIR/pos-unlock-renewal-supervisor"
readonly INSTALLED_SUPERVISOR="$INSTALL_ROOT/pos_unlock_renewal_supervisor.sh"
readonly INSTALLED_AUTHORITY="$INSTALL_ROOT/AUTHORITY.json"
readonly INSTALLED_AUTHORITY_SHA256="$INSTALL_ROOT/AUTHORITY.sha256"
readonly INSTALLED_JOB10_CONTRACT="$INSTALL_ROOT/$JOB10_CONTRACT_NAME"
readonly INSTALLED_TOPOLOGY_MAP="$INSTALL_ROOT/$TOPOLOGY_MAP_NAME"
readonly INSTALLED_PACKAGE_MANIFEST="$INSTALL_ROOT/source-package-SHA256SUMS"
readonly CRON_PATH='/etc/cron.d/blackcoin-pos-unlock-renewal-supervisor'
readonly RUNTIME_RECEIPT_ROOT='/mnt/disk1/blackcoin-wallet-safety/runtime-audits/pos-unlock-renewal-supervisor'
readonly HISTORICAL_JOB10_RECEIPT='/mnt/disk1/blackcoin-wallet-safety/runtime-audits/emergency-pos-renewal-20260814T034100Z.log'
readonly CLI='/usr/local/bin/blackcoin-cli'
readonly DATADIR='/home/blackcoin/.blackcoin'

declare -a RENEWAL_LOCK_FDS=()
RENEWAL_HELPER_WORK_DIR=''
RENEWAL_HELPER_SNAPSHOT=''

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

renewal_secure_directory_for_uid()
{
    local directory=$1 mode=$2 uid=$3 actual
    [[ -d "$directory" && ! -L "$directory" ]] || return 1
    [[ "$(renewal_realpath_existing "$directory")" == "$directory" ]] || return 1
    actual=$(stat -c '%u:%a' -- "$directory" 2>/dev/null ||
      stat -f '%u:%Lp' -- "$directory" 2>/dev/null) || return 1
    [[ "$actual" == "$uid:$mode" ]]
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
      --arg helper "$EXPECTED_HELPER_SHA256" \
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
        "allowed_rpc_methods","authority_nonce","chain_config_key_transaction_mutation_forbidden",
        "cron_expression","cron_path","cron_sha256","global_lock","helper_execution",
        "helper_nodes","historical_job10_preserved_read_only","historical_job10_receipt_target",
        "image_id","image_ref","install_authorized","install_root","installed_authority",
        "installed_job10_contract","installed_package_manifest","installed_supervisor",
        "installed_topology_map","issued_at_epoch","job10_contract_sha256","kind",
        "maintenance_inhibitor_must_remain","maintenance_marker_sha256","manifest_sha256s",
        "minimum_peers","minimum_post_unlock_seconds","network_version",
        "node30_ordinary_pow_enable_forbidden","normal_unlock_helper_sha256",
        "package_manifest_sha256","per_node_lock_pattern","post_helper_wait_seconds",
        "regular_pow_rpc_forbidden","renewal_authorized","renewal_cadence_minutes",
        "runtime_receipt_root","schema","state","subversion","supervisor_sha256",
        "tooling_parent_commit","topology_map_sha256","valid_from_epoch","valid_until_epoch"
      ] | sort) and
      .schema == 1 and .kind == "blackcoin-pos-unlock-renewal-supervisor-authority" and
      .state == "authorized" and
      (.authority_nonce | type == "string" and test("^[0-9a-f]{32}$")) and
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
      .post_helper_wait_seconds == 60 and .renewal_cadence_minutes == $cadence_minutes and
      .cron_expression == $cron_expression and .global_lock == $global and
      .per_node_lock_pattern == $per_node and .install_root == $install_root and
      .installed_supervisor == $supervisor and .installed_authority == $installed_authority and
      .installed_job10_contract == $job10 and .installed_topology_map == $topology and
      .installed_package_manifest == $installed_manifest and .cron_path == $cron_path and
      .runtime_receipt_root == $receipts and .historical_job10_receipt_target == $historical and
      .historical_job10_preserved_read_only == true and
      .maintenance_inhibitor_must_remain == true and .regular_pow_rpc_forbidden == true and
      .node30_ordinary_pow_enable_forbidden == true and
      .chain_config_key_transaction_mutation_forbidden == true and
      .allowed_rpc_methods == ["getblockchaininfo","getnetworkinfo","getstakinginfo",
        "getwalletinfo","listwallets"] and
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
    bash -n "$helper" || return 1
    forbidden=$(grep -Eio '\b(setstaking|setpowmining|getpowmininginfo|sendrawtransaction|createshadowpowclaimresolution|commitshadowpowclaimresolution|resolveshadowpowclaims|setpowclaimrecovery|getnewaddress|getnewquantumaddress|setpowminingaddress|sendtoaddress|sendmany|fundrawtransaction|signrawtransaction[^[:space:]]*|abandontransaction|resendwallettransactions|forcerelay|walletnotify|zmqpub(rawtx|hashtx|sequence)|eval|source)\b' \
        "$helper" | tr '[:upper:]' '[:lower:]' | sort -u || true)
    [[ -z "$forbidden" ]] || return 1
    [[ "$(grep -Eio '\bwalletpassphrase\b' "$helper" | wc -l | tr -d ' ')" == 1 &&
       "$(grep -Eio '\blistwallets\b' "$helper" | wc -l | tr -d ' ')" == 1 &&
       "$(grep -Eio '\bgetwalletinfo\b' "$helper" | wc -l | tr -d ' ')" == 2 &&
       "$(grep -Eio '\bgetstakinginfo\b' "$helper" | wc -l | tr -d ' ')" == 2 &&
       "$(grep -Eio '\b(walletpassphrase|listwallets|getwalletinfo|getstakinginfo)\b' \
          "$helper" | wc -l | tr -d ' ')" == 6 ]] || return 1
    grep -Eq 'walletpassphrase.*[[:space:]]false([[:space:]]|$)' "$helper" || return 1
    size=$(stat -c '%s' -- "$helper" 2>/dev/null ||
      stat -f '%z' -- "$helper" 2>/dev/null) || return 1
    lines=$(wc -l <"$helper" | tr -d ' ') || return 1
    [[ "$size" == 3206 && "$lines" == 54 ]]
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
      (keys | sort) == (["legacy_descriptors_sha256","node_id","quantum_identity_sha256",
        "schema","trusted_legacy_descriptor_set_sha256","trusted_policy_sha256",
        "trusted_quantum_address_count","trusted_quantum_address_set_sha256","wallet"] | sort) and
      .schema == 2 and .node_id == $node and .wallet == $wallet and
      ([.legacy_descriptors_sha256,.quantum_identity_sha256,.trusted_policy_sha256,
        .trusted_legacy_descriptor_set_sha256,.trusted_quantum_address_set_sha256] |
        all(type == "string" and test("^[0-9a-f]{64}$"))) and
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
    shift 2
    renewal_docker exec "$container" "$CLI" -datadir="$DATADIR" \
      "-rpcwallet=$wallet" "$@"
}

renewal_capture_node()
{
    local authority=$1 state_root=$2 topology=$3 node=$4 phase=$5 uid=$6
    local row service container inspect chain_before chain_after network wallets wallet
    local wallet_info staking wallet_hash now
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
      .enabled == true and .autostart_staking == true and
      .automatic_qqsignal == false and .automatic_demurrage_attestation == false and
      .automatic_redelegation == false and .allow_automatic_quantum_key_creation == false
    ' <<<"$staking" >/dev/null || return 1
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
      --argjson wallet "$wallet_info" --argjson staking "$staking" '{
        node:$node,service:$service,container:$container,phase:$phase,
        image_ref:$image_ref,image_id:$image_id,wallet_name_sha256:$wallet_hash,
        chain:$chain.chain,height:$chain.blocks,headers:$chain.headers,
        tip:$chain.bestblockhash,chainwork:$chain.chainwork,initial_block_download:$chain.initialblockdownload,
        peers:$network.connections,network_version:$network.version,subversion:$network.subversion,
        unlocked_until:$wallet.unlocked_until,unlocked_staking_only:$wallet.unlocked_staking_only,
        staking_enabled:$staking.enabled,staking_active:$staking.staking,
        staking_state:$staking.staking_state,weight:$staking.weight
      }'
}

renewal_capture_fleet()
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
      ([.[].chainwork] | unique | length) == 1
    ' <<<"$fleet" >/dev/null || return 1
    printf '%s\n' "$fleet"
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
    local global=$1 pattern=$2 uid=$3 node padded path
    [[ "$pattern" == *'%02d'* && "${pattern/'%02d'/}" != *'%'* ]] || return 1
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
    /usr/bin/timeout --foreground --signal=TERM --kill-after=15 120 \
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

renewal_publish_receipt()
{
    local root=$1 uid=$2 authority=$3 authority_sha=$4 started_epoch=$5 started_utc=$6 pre=$7 post=$8
    local nonce finished_epoch finished_utc output sidecar temporary expected actual
    renewal_secure_directory_for_uid "$root" 700 "$uid" || return 1
    nonce=$(jq -er '.authority_nonce' "$authority") || return 1
    finished_epoch=$(renewal_now_epoch)
    finished_utc=$(renewal_now_utc)
    output="$root/renewal-${started_epoch}-${nonce}.json"
    sidecar="$output.sha256"
    [[ ! -e "$output" && ! -L "$output" && ! -e "$sidecar" && ! -L "$sidecar" ]] || return 1
    temporary=$(mktemp "$root/.receipt.XXXXXX") || return 1
    jq -n --arg authority_sha "$authority_sha" --arg supervisor_sha "$(renewal_sha256_file "$script_path")" \
      --arg helper_sha "$EXPECTED_HELPER_SHA256" --arg marker_sha "$EXPECTED_MARKER_SHA256" \
      --arg image_id "$EXPECTED_IMAGE_ID" --arg image_ref "$EXPECTED_IMAGE_REF" \
      --arg started_utc "$started_utc" --arg finished_utc "$finished_utc" \
      --argjson started_epoch "$started_epoch" --argjson finished_epoch "$finished_epoch" \
      --argjson pre "$pre" --argjson post "$post" '{
        schema:1,kind:"blackcoin-pos-unlock-renewal-supervisor-run",status:"PASS",
        authority_sha256:$authority_sha,supervisor_sha256:$supervisor_sha,
        normal_unlock_helper_sha256:$helper_sha,maintenance_marker_sha256:$marker_sha,
        image_id:$image_id,image_ref:$image_ref,started_at_epoch:$started_epoch,
        started_at_utc:$started_utc,finished_at_epoch:$finished_epoch,finished_at_utc:$finished_utc,
        global_and_per_node_locks_held:true,helper_nodes:[range(1;33)],helper_order:"sequential-ascending",
        post_helper_wait_seconds:60,minimum_normal_unlock_remaining_seconds:43200,
        historical_job10_receipt_preserved_read_only:true,regular_pow_rpc_observed:false,
        regular_pow_state_changed:false,node30_ordinary_pow_enable_attempted:false,
        maintenance_inhibitor_removed:false,chain_config_key_transaction_mutation_attempted:false,
        preflight:$pre,postflight:$post
      }' >"$temporary" || { rm -f -- "$temporary"; return 1; }
    chmod 600 "$temporary" || { rm -f -- "$temporary"; return 1; }
    sync -f "$temporary" || { rm -f -- "$temporary"; return 1; }
    expected=$(renewal_sha256_file "$temporary") || { rm -f -- "$temporary"; return 1; }
    mv -nT -- "$temporary" "$output" || { rm -f -- "$temporary"; return 1; }
    [[ ! -e "$temporary" && ! -L "$temporary" ]] || { rm -f -- "$temporary"; return 1; }
    actual=$(renewal_sha256_file "$output") || return 1
    [[ "$actual" == "$expected" ]] || return 1
    temporary=$(mktemp "$root/.receipt-sha.XXXXXX") || return 1
    printf '%s\n' "$expected" >"$temporary"
    if ! chmod 600 "$temporary" || ! sync -f "$temporary"; then
        rm -f -- "$temporary"
        return 1
    fi
    mv -nT -- "$temporary" "$sidecar" || { rm -f -- "$temporary"; return 1; }
    [[ ! -e "$temporary" && ! -L "$temporary" ]] || { rm -f -- "$temporary"; return 1; }
    sync -f "$output" && sync -f "$sidecar" && sync -f "$root" || return 1
    renewal_secure_file_for_uid "$output" 600 "$uid" &&
      renewal_secure_file_for_uid "$sidecar" 600 "$uid" &&
      [[ "$(<"$sidecar")" == "$expected" && "$(renewal_sha256_file "$output")" == "$expected" ]]
}

renewal_execute_cycle()
{
    local authority=$1 authority_sha=$2 state_root=$3 topology=$4 helper=$5 marker=$6
    local receipt_root=$7 global_lock=$8 per_node_pattern=$9 uid=${10} work_root=${11}
    local started_epoch started_utc pre post node
    [[ "$(renewal_sha256_file "$authority")" == "$authority_sha" ]] || return 1
    renewal_acquire_fleet_locks "$global_lock" "$per_node_pattern" "$uid" || return 1
    renewal_verify_marker "$marker" "$uid" || return 1
    renewal_verify_helper "$helper" "$uid" || return 1
    renewal_verify_manifest_bytes "$authority" "$state_root" "$uid" || return 1
    renewal_validate_topology_map "$topology" || return 1
    started_epoch=$(renewal_now_epoch)
    started_utc=$(renewal_now_utc)
    pre=$(renewal_capture_fleet "$authority" "$state_root" "$topology" pre "$uid") || return 1
    [[ "$(renewal_sha256_file "$authority")" == "$authority_sha" ]] || return 1
    renewal_verify_marker "$marker" "$uid" || return 1
    renewal_prepare_helper_snapshot "$helper" "$uid" "$work_root" || return 1
    for node in $(seq 1 "$NODE_COUNT"); do
        renewal_verify_marker "$marker" "$uid" || return 1
        renewal_invoke_helper_snapshot "$RENEWAL_HELPER_SNAPSHOT" "$node" || return 1
    done
    renewal_sleep "$POST_HELPER_WAIT_SECONDS"
    [[ "$(renewal_sha256_file "$authority")" == "$authority_sha" ]] || return 1
    renewal_verify_marker "$marker" "$uid" || return 1
    renewal_verify_helper "$helper" "$uid" || return 1
    post=$(renewal_capture_fleet "$authority" "$state_root" "$topology" post "$uid") || return 1
    renewal_verify_marker "$marker" "$uid" || return 1
    renewal_publish_receipt "$receipt_root" "$uid" "$authority" "$authority_sha" "$started_epoch" \
      "$started_utc" "$pre" "$post"
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
    mv -nT -- "$temporary" "$destination" || { rm -f -- "$temporary"; return 1; }
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
    mv -nT -- "$temporary" "$destination" || { rm -f -- "$temporary"; return 1; }
    [[ ! -e "$temporary" && ! -L "$temporary" ]] || { rm -f -- "$temporary"; return 1; }
    sync -f "$destination" && sync -f "$directory"
}

renewal_install()
{
    local authority=$1 authority_sha=$2 now self_sha contract_sha topology_sha manifest_sha
    local temporary receipt_sha
    [[ "$EUID" -eq 0 ]] || renewal_die 'install requires root' || return
    renewal_secure_file_for_uid "$authority" 600 0 ||
        renewal_die 'install authority must be a root-owned 0600 single-link regular file' || return
    [[ "$(renewal_sha256_file "$authority")" == "$authority_sha" ]] ||
        renewal_die 'install authority hash mismatch' || return
    now=$(renewal_now_epoch)
    renewal_validate_authority_semantics "$authority" "$now" ||
        renewal_die 'install authority semantic contract is invalid or expired' || return
    renewal_package_tree_is_valid "$script_dir" || renewal_die 'source package seal is invalid' || return
    renewal_job10_contract_is_valid "$JOB10_CONTRACT" ||
        renewal_die 'historical job-10 contract is invalid' || return
    renewal_validate_topology_map "$TOPOLOGY_MAP" || renewal_die 'topology map is invalid' || return
    renewal_authority_files_match "$authority" "$script_path" "$JOB10_CONTRACT" \
      "$TOPOLOGY_MAP" "$PACKAGE_MANIFEST" || renewal_die 'authority does not bind source bytes' || return
    renewal_acquire_lock "$GLOBAL_LOCK" 0 || renewal_die 'historical/global renewal mutex is busy' || return
    renewal_verify_marker "$MAINTENANCE_MARKER" 0 ||
        renewal_die 'stale maintenance inhibitor is absent or changed' || return
    renewal_verify_helper "$NORMAL_UNLOCK_HELPER" 0 ||
        renewal_die 'installed normal-unlock helper is not the audited object' || return
    renewal_verify_manifest_bytes "$authority" "$STATE_DIR" 0 ||
        renewal_die 'reviewed manifest bytes are incomplete or changed' || return
    if [[ ! -e "$INSTALL_ROOT" && ! -L "$INSTALL_ROOT" ]]; then
        install -d -o root -g root -m 0700 "$INSTALL_ROOT"
        sync -f "$STATE_DIR"
    fi
    renewal_secure_directory_for_uid "$INSTALL_ROOT" 700 0 ||
        renewal_die 'install root is not exact root-owned 0700' || return
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
    renewal_install_exact_file "$script_path" "$self_sha" "$INSTALLED_SUPERVISOR" 700 || return 1
    renewal_install_exact_file "$JOB10_CONTRACT" "$contract_sha" "$INSTALLED_JOB10_CONTRACT" 600 || return 1
    renewal_install_exact_file "$TOPOLOGY_MAP" "$topology_sha" "$INSTALLED_TOPOLOGY_MAP" 600 || return 1
    renewal_install_exact_file "$PACKAGE_MANIFEST" "$manifest_sha" "$INSTALLED_PACKAGE_MANIFEST" 600 || return 1
    renewal_install_exact_file "$authority" "$authority_sha" "$INSTALLED_AUTHORITY" 600 || return 1
    printf '%s\n' "$authority_sha" | renewal_install_text_noclobber \
      "$INSTALLED_AUTHORITY_SHA256" 600 "$(printf '%s\n' "$authority_sha" | sha256sum | awk '{print $1}')" || return 1
    renewal_cron_body | renewal_install_text_noclobber "$CRON_PATH" 600 \
      "$(renewal_cron_sha256)" || return 1
    temporary=$(mktemp "$INSTALL_ROOT/.install-receipt.XXXXXX") || return 1
    jq -n --arg authority_sha "$authority_sha" --arg supervisor_sha "$self_sha" \
      --arg contract_sha "$contract_sha" --arg topology_sha "$topology_sha" \
      --arg manifest_sha "$manifest_sha" --arg installed_at "$(renewal_now_utc)" '{
        schema:1,kind:"blackcoin-pos-unlock-renewal-supervisor-install",status:"installed",
        authority_sha256:$authority_sha,supervisor_sha256:$supervisor_sha,
        historical_job10_contract_sha256:$contract_sha,topology_map_sha256:$topology_sha,
        source_package_manifest_sha256:$manifest_sha,installed_at_utc:$installed_at,
        historical_job10_receipt_preserved_read_only:true,
        maintenance_inhibitor_removed:false,helper_invoked:false,live_fleet_mutated:false}' >"$temporary"
    # The timestamp above is intentionally generated once more for the actual
    # no-clobber receipt; its exact bytes, not the advisory pre-hash, control.
    receipt_sha=$(renewal_sha256_file "$temporary")
    renewal_install_exact_file "$temporary" "$receipt_sha" "$INSTALL_ROOT/INSTALL-RECEIPT.json" 600 || {
        rm -f -- "$temporary"; return 1;
    }
    rm -f -- "$temporary"
    renewal_verify_marker "$MAINTENANCE_MARKER" 0 ||
        renewal_die 'maintenance inhibitor changed during install' || return
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
      --arg global "$GLOBAL_LOCK" --arg per_node "$PER_NODE_LOCK_PATTERN" '{
        schema:1,mode:$mode,status:"offline-only",tooling_parent_commit:$parent,
        supervisor_sha256:$supervisor_sha,source_package_manifest_sha256:$package_sha,
        topology_map_sha256:$topology_sha,historical_job10_contract_sha256:$job10_sha,
        deployment_authorized:$authorized,authority_status:$reason,
        historical_job10:{one_shot:true,receipt:$historical,preserved_read_only:true,
          installation_or_execution_claimed_by_this_package:false},
        proposed_install_root:$install_root,proposed_cron_path:$cron_path,
        proposed_global_lock:$global,proposed_per_node_lock_pattern:$per_node,
        helper_nodes:[range(1;33)],helper_order:"sequential-ascending",
        post_helper_wait_seconds:60,minimum_normal_unlock_remaining_seconds:43200,
        regular_pow_rpc_allowed:false,node30_ordinary_pow_enable_allowed:false,
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
    renewal_secure_file_for_uid "$INSTALLED_SUPERVISOR" 700 0 &&
      renewal_secure_file_for_uid "$INSTALLED_AUTHORITY" 600 0 &&
      renewal_secure_file_for_uid "$INSTALLED_AUTHORITY_SHA256" 600 0 &&
      renewal_secure_file_for_uid "$INSTALLED_JOB10_CONTRACT" 600 0 &&
      renewal_secure_file_for_uid "$INSTALLED_TOPOLOGY_MAP" 600 0 &&
      renewal_secure_file_for_uid "$INSTALLED_PACKAGE_MANIFEST" 600 0 ||
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
    trap renewal_cleanup EXIT
    trap 'renewal_cleanup; exit 129' HUP
    trap 'renewal_cleanup; exit 130' INT
    trap 'renewal_cleanup; exit 143' TERM
    renewal_execute_cycle "$INSTALLED_AUTHORITY" "$authority_sha" "$STATE_DIR" \
      "$INSTALLED_TOPOLOGY_MAP" "$NORMAL_UNLOCK_HELPER" "$MAINTENANCE_MARKER" \
      "$RUNTIME_RECEIPT_ROOT" "$GLOBAL_LOCK" "$PER_NODE_LOCK_PATTERN" 0 /run
}

renewal_usage()
{
    printf '%s\n' \
      "usage: $0 audit [AUTHORITY.json AUTHORITY_SHA256]" \
      "       $0 plan [AUTHORITY.json AUTHORITY_SHA256]" \
      "       $0 install AUTHORITY.json AUTHORITY_SHA256" \
      "       $0 run"
}

renewal_main()
{
    local mode=${1:-}
    renewal_require_supported_bash || return
    renewal_require_commands awk bash chmod chown date find flock grep install jq mktemp mv \
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
        *) renewal_usage >&2; return 64 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    renewal_main "$@"
fi
