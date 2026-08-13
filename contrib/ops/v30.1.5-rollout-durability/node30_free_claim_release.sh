#!/usr/bin/env bash
export LC_ALL=C
set -Eeuo pipefail
umask 077

package_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
# shellcheck disable=SC1091 # Resolved from this sealed package at runtime.
source "$package_dir/lib/common.sh"
# shellcheck disable=SC1091 # Resolved from this sealed package at runtime.
source "$package_dir/lib/typed_contract.sh"
# shellcheck disable=SC1091 # Resolved from this sealed package at runtime.
source "$package_dir/lib/node30_free_claim_release_contract.sh"

mode=audit
prior_audit=''
prior_audit_sha=''
case $# in
    1) env_file=$1 ;;
    2)
        mode=$1
        env_file=$2
        [[ "$mode" == audit ]] || {
            printf 'usage: %s [audit|release] REVIEWED_ENV\n' "$0" >&2
            exit 64
        }
        ;;
    4)
        mode=$1
        env_file=$2
        prior_audit=$3
        prior_audit_sha=$4
        [[ "$mode" == release ]] || {
            printf 'usage: %s release REVIEWED_ENV PRIOR_AUDIT PRIOR_AUDIT_SHA256\n' "$0" >&2
            exit 64
        }
        ;;
    *)
        printf 'usage: %s [audit|release] REVIEWED_ENV\n' "$0" >&2
        exit 64
        ;;
esac

[[ $EUID == 0 ]] || v3015_die 'node30 Free-Claim audit/release requires root'
v3015_load_reviewed_env "$env_file"
v3015_require_commands awk bash cmp date docker find flock grep jq realpath sed \
    sha256sum sort stat tr wc
v3015_validate_node30_audit_env
v3015_verify_package_tree "$package_dir" || v3015_die 'sealed package tree is invalid'
v3015_validate_topology_map "$package_dir/topology.map" ||
    v3015_die 'sealed topology map is invalid'
v3015_release_identity_is_valid "$RELEASE_IDENTITY_JSON" ||
    v3015_die 'release identity is invalid'

for authority_file in "$NODE30_PUBLIC_ARTIFACT_AUTHORITY" \
    "$NODE30_SUCCESSOR_SEMANTICS_RECEIPT" \
    "$NODE30_MAINTENANCE_FINALIZATION_RECEIPT" \
    "$NODE30_FLEET_RESULT" "$NODE30_PACKAGING_VERIFIER_RECEIPT"; do
    if ! v3015_secure_regular_file "$authority_file" 600 ||
       ! v3015_secure_ancestry "$authority_file"; then
        v3015_die "node30 reviewed authority is unsafe: $authority_file"
    fi
done
v3015_node30_audit_authorities_are_valid ||
    v3015_die 'node30 public-artifact/semantics/pause-preserved finalization authority is invalid'

[[ ! -e "$NODE30_ROLLOUT_MAINTENANCE_MARKER" &&
   ! -L "$NODE30_ROLLOUT_MAINTENANCE_MARKER" ]] ||
    v3015_die 'fleet maintenance remains active; node30 release is forbidden'

free_claim_root_mode=$(stat -c '%a' -- "$NODE30_FREE_CLAIM_ROOT" 2>/dev/null) ||
    v3015_die 'Free-Claim root mode is unreadable'
if ! [[ -d "$NODE30_FREE_CLAIM_ROOT" && ! -L "$NODE30_FREE_CLAIM_ROOT" &&
      "$(realpath -e -- "$NODE30_FREE_CLAIM_ROOT")" == "$NODE30_FREE_CLAIM_ROOT" &&
      "$(stat -c '%u:%g' -- "$NODE30_FREE_CLAIM_ROOT")" == 0:0 &&
      "$free_claim_root_mode" =~ ^[0-7]{3,4}$ ]] ||
   ! (( (8#$free_claim_root_mode & 0022) == 0 )) ||
   ! v3015_secure_ancestry "$NODE30_FREE_CLAIM_ROOT"; then
    v3015_die 'Free-Claim root is not securely owned'
fi
v3015_secure_root_executable "$NODE30_PAUSE_WRAPPER" ||
    v3015_die 'installed node30 pause wrapper is unsafe'
v3015_secure_regular_file "$NODE30_PAUSE_MARKER" 600 ||
    v3015_die 'installed node30 pause marker is unsafe'
v3015_secure_regular_file "$NODE30_ORIGINAL_WORKER" 600 ||
    v3015_die 'installed original node30 worker is unsafe'
[[ "$(v3015_sha256_file "$NODE30_PAUSE_WRAPPER")" == "$NODE30_PAUSE_WRAPPER_SHA256" &&
   "$(v3015_sha256_file "$NODE30_PAUSE_MARKER")" == "$NODE30_PAUSE_MARKER_SHA256" &&
   "$(v3015_sha256_file "$NODE30_ORIGINAL_WORKER")" == "$NODE30_ORIGINAL_WORKER_SHA256" ]] ||
    v3015_die 'node30 wrapper/marker/original-worker identity mismatch'
printf '%s\n' "$NODE30_PAUSE_MARKER_CONTENT" | cmp -s - "$NODE30_PAUSE_MARKER" ||
    v3015_die 'node30 pause marker content mismatch'
if ! grep -Fq "$NODE30_PAUSE_MARKER_CONTENT" "$NODE30_PAUSE_WRAPPER" ||
   ! grep -Fq "$NODE30_ORIGINAL_WORKER_SHA256" "$NODE30_PAUSE_WRAPPER"; then
    v3015_die 'node30 wrapper does not bind the reviewed marker and worker'
fi
[[ "$(grep -Eoc '\bsendshadowpowclaim\b' "$NODE30_ORIGINAL_WORKER")" == 2 &&
   "$(grep -Eoc '\bgetshadowpowwork\b' "$NODE30_ORIGINAL_WORKER")" == 1 ]] ||
    v3015_die 'node30 original worker RPC shape changed'
if grep -Eiq '\b(setpowmining|setpowclaimrecovery|resolveallshadowpowclaims|createshadowpowclaimresolution|commitshadowpowclaimresolution|abandontransaction|getnewaddress|getnewquantumaddress|createquantumkey|migratetoquantum|migrategoldrushrewards|reindex|rewind)\b' \
    "$NODE30_ORIGINAL_WORKER"; then
    v3015_die 'node30 original worker contains a forbidden recovery/key/role operation'
fi

for directory in "$NODE30_QUEUE_DIR" "$NODE30_DONE_DIR"; do
    [[ -d "$directory" && ! -L "$directory" &&
       "$(realpath -e -- "$directory")" == "$directory" ]] ||
        v3015_die "node30 queue state directory is unsafe: $directory"
done
[[ -f "$NODE30_AWARDED_FILE" && ! -L "$NODE30_AWARDED_FILE" &&
   "$(realpath -e -- "$NODE30_AWARDED_FILE")" == "$NODE30_AWARDED_FILE" &&
   "$(stat -c '%u:%g:%a:%h' -- "$NODE30_AWARDED_FILE")" == \
     "0:${NODE30_POOL_GROUP_GID}:640:1" ]] ||
    v3015_die 'node30 awarded ledger is unsafe'
[[ "$(v3015_sha256_file "$NODE30_AWARDED_FILE")" == "$NODE30_AWARDED_SHA256" ]] ||
    v3015_die 'node30 awarded ledger changed after authority review'

lock_fds=()
for lock_path in "${V3015_NODE30_EXPECTED_LOCKS[@]}"; do
    [[ -f "$lock_path" && ! -L "$lock_path" &&
       "$(realpath -e -- "$lock_path")" == "$lock_path" &&
       "$(stat -c '%u:%g:%a:%h' -- "$lock_path")" == 0:0:600:1 ]] ||
        v3015_die "required existing node30 lock is unsafe: $lock_path"
    v3015_secure_ancestry "$lock_path" ||
        v3015_die "required node30 lock ancestry is unsafe: $lock_path"
    exec {lock_fd}<>"$lock_path"
    [[ "$(stat -Lc '%d:%i' -- "$lock_path")" == \
       "$(stat -Lc '%d:%i' -- "/proc/$$/fd/$lock_fd")" ]] ||
        v3015_die "opened node30 lock identity changed: $lock_path"
    flock -n "$lock_fd" || v3015_die "node30 release lock is active: $lock_path"
    lock_fds+=("$lock_fd")
done
[[ "${#lock_fds[@]}" -eq "${#V3015_NODE30_EXPECTED_LOCKS[@]}" ]] ||
    v3015_die 'not every node30 release lock is held'

# All mutable Free-Claim and fleet predicates are resampled only after the
# complete lock set is held. The audit path releases the locks without changing
# the pause marker, queue, wallet, daemon, or container.
[[ ! -e "$NODE30_ROLLOUT_MAINTENANCE_MARKER" &&
   ! -L "$NODE30_ROLLOUT_MAINTENANCE_MARKER" ]] ||
    v3015_die 'fleet maintenance reappeared under node30 locks'
[[ -f "$NODE30_PAUSE_MARKER" && ! -L "$NODE30_PAUSE_MARKER" &&
   "$(v3015_sha256_file "$NODE30_PAUSE_MARKER")" == "$NODE30_PAUSE_MARKER_SHA256" ]] ||
    v3015_die 'node30 pause marker changed under locks'
v3015_node30_audit_authorities_are_valid ||
    v3015_die 'node30 audit authority changed under locks'

topology_row=$(v3015_topology_lookup "$package_dir/topology.map" 30) ||
    v3015_die 'node30 topology lookup failed'
IFS=$'\t' read -r node30_service node30_container <<<"$topology_row"
[[ "$node30_service" == node30 && "$node30_container" == blackcoin-v4-gui-30 ]] ||
    v3015_die 'node30 topology role changed'

scratch=$(mktemp -d "${TMPDIR:-/run}/v3015-node30-release-audit.XXXXXX")
chmod 700 "$scratch"
cleanup_node30_release()
{
    local status=$?
    trap - EXIT HUP INT TERM
    rm -rf -- "$scratch"
    exit "$status"
}
trap cleanup_node30_release EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

node30_rpc()
{
    local timeout_seconds=$1
    shift
    /usr/bin/timeout --kill-after=5 "$timeout_seconds" docker exec "$node30_container" \
      /usr/local/bin/blackcoin-cli -datadir=/home/blackcoin/.blackcoin "$@"
}

docker inspect "$node30_container" >"$scratch/container.raw.json"
jq -e 'type == "array" and length == 1' "$scratch/container.raw.json" >/dev/null ||
    v3015_die 'node30 container identity is ambiguous'
jq -c --arg name "$node30_container" '{name:$name,image_ref:.[0].Config.Image,
  image_id:.[0].Image,running:.[0].State.Running,paused:.[0].State.Paused,
  restarting:.[0].State.Restarting,dead:.[0].State.Dead,
  health:(.[0].State.Health.Status // "missing")}' "$scratch/container.raw.json" \
  >"$scratch/container.json"

node30_rpc 20 getblockchaininfo | jq -c '{chain,blocks,headers,bestblockhash,
  initialblockdownload,verificationprogress}' >"$scratch/chain.before.json"
captured_epoch=$(date -u +%s)
node30_rpc 20 getnetworkinfo | jq -c '{version,subversion,networkactive,
  connections}' >"$scratch/network.json"
node30_rpc 20 listwallets >"$scratch/wallets.json"
node30_rpc 25 getwalletinfo | jq -c '{walletname,unlocked_until,
  unlocked_staking_only,private_keys_enabled,scanning,paytxfee,lastprocessedblock}' \
  >"$scratch/wallet.json"
node30_rpc 25 getstakinginfo >"$scratch/staking.json"
node30_rpc 30 getpowmininginfo >"$scratch/pow.json"
node30_rpc 45 getpowclaimrecoveryinfo true >"$scratch/recovery.json"
node30_rpc 45 listunspent 0 >"$scratch/unspent.json"
node30_rpc 20 getgoldrushinfo | jq -c '{active,height,pow_jackpot,pow_amount,
  competing_claim_rule_active_next_block,blocks_until_competing_claim_rule,
  qqp4_activation_disabled,qqp4_activation_height,qqp4_active_next_block}' \
  >"$scratch/goldrush.json"

jq -ec '[.[] | select(.spendability_state == "spendable_legacy" and
  .spendable == true and .safe == true)][0] |
  {txid,vout,address,scriptPubKey,amount,spendable,safe,spendability_state}' \
  "$scratch/unspent.json" >"$scratch/selected-utxo.json" ||
    v3015_die 'node30 has no exact safe spendable legacy fee UTXO'
selected_txid=$(jq -er '.txid' "$scratch/selected-utxo.json")
selected_vout=$(jq -er '.vout' "$scratch/selected-utxo.json")
selected_address=$(jq -er '.address' "$scratch/selected-utxo.json")
node30_rpc 20 gettxout "$selected_txid" "$selected_vout" | \
  jq -ec '{value,scriptPubKey:.scriptPubKey.hex}' >"$scratch/coin.before.json" ||
    v3015_die 'selected node30 legacy fee UTXO is not live'
node30_rpc 20 getaddressinfo "$selected_address" | jq -c \
  '{address,ismine,iswatchonly,solvable,scriptPubKey}' >"$scratch/target-address.json"

queue_entries=$(find "$NODE30_QUEUE_DIR" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d ' ')
queue_regular=$(find "$NODE30_QUEUE_DIR" -mindepth 1 -maxdepth 1 -type f \
  -name '*.json' -print | wc -l | tr -d ' ')
queue_nonregular=$(find "$NODE30_QUEUE_DIR" -mindepth 1 -maxdepth 1 ! -type f \
  -print | wc -l | tr -d ' ')
((queue_entries == 1 && queue_regular == 1 && queue_nonregular == 0)) ||
    v3015_die 'node30 queue must contain exactly one reviewed regular JSON item'
queue_file="$NODE30_QUEUE_DIR/$NODE30_QUEUE_ITEM_BASENAME"
v3015_secure_regular_file "$queue_file" 644 ||
    v3015_die 'reviewed node30 queue item is unsafe'
[[ "$(v3015_sha256_file "$queue_file")" == "$NODE30_QUEUE_ITEM_SHA256" ]] ||
    v3015_die 'reviewed node30 queue item changed'
jq -e 'type == "object" and (keys | sort) ==
  (["attempts","ip","quantum_address","submitted"] | sort)' "$queue_file" >/dev/null ||
    v3015_die 'node30 queue item schema is invalid'
queue_address=$(jq -er '.quantum_address' "$queue_file")
[[ "$(v3015_node30_sha256_text "$queue_address")" == "$NODE30_QUEUE_ADDRESS_SHA256" ]] ||
    v3015_die 'node30 queue payout identity changed'
if grep -Fxq -- "$queue_address" "$NODE30_AWARDED_FILE"; then
    v3015_die 'node30 queue payout was already awarded'
fi

broadcast_count=$(find "$NODE30_DONE_DIR" -mindepth 1 -maxdepth 1 -type f \
  -name '*.broadcast' -print | wc -l | tr -d ' ')
((broadcast_count == 0)) || v3015_die 'node30 has an in-flight broadcast record'
today=$(date -u +%Y%m%d)
sponsorships_today=$(find "$NODE30_DONE_DIR" -mindepth 1 -maxdepth 1 -type f \
  \( -name "${today}T*.paid.json" -o -name "${today}T*.confirmed.json" -o \
     -name "${today}T*.broadcast" \) -print | wc -l | tr -d ' ')

node30_rpc 20 validateaddress "$queue_address" >"$scratch/address-validation.raw.json"
node30_rpc 20 getaddressinfo "$queue_address" >"$scratch/address-wallet.raw.json"
jq -cn --slurpfile validation "$scratch/address-validation.raw.json" \
  --slurpfile wallet "$scratch/address-wallet.raw.json" '
    ($validation[0]) as $v | ($wallet[0]) as $w |
    {address:$v.address,isvalid:$v.isvalid,iswitness:$v.iswitness,
     witness_version:$v.witness_version,witness_program:$v.witness_program,
     scriptPubKey:($v.scriptPubKey // $w.scriptPubKey),
     ismine:$w.ismine,iswatchonly:$w.iswatchonly}' >"$scratch/address-info.json"
qqp4_active=$(jq -er '.qqp4_active_next_block' "$scratch/goldrush.json")
if [[ "$qqp4_active" == true ]]; then
    node30_rpc 40 -named getshadowpowwork target_address="$selected_address" \
      quantum_address="$queue_address" claim_txid="$selected_txid" claim_vout="$selected_vout" \
      >"$scratch/work.raw.json"
else
    node30_rpc 40 -named getshadowpowwork target_address="$selected_address" \
      quantum_address="$queue_address" >"$scratch/work.raw.json"
fi
jq -c '{active,height,prevhash,target_bits,prefix,proof_mode,proof_mode_byte,
  proof_version,claim_outpoint_required,qqp4_activation_disabled,
  qqp4_activation_height,qqp4_active_next_block,reward_start_height,reward_end_height,
  target_script,quantum_address,quantum_payout_script,claim_txid:(.claim_txid // null),
  claim_vout:(.claim_vout // null)}' "$scratch/work.raw.json" >"$scratch/work.json"

node30_rpc 20 gettxout "$selected_txid" "$selected_vout" | \
  jq -ec '{value,scriptPubKey:.scriptPubKey.hex}' >"$scratch/coin.after.json" ||
    v3015_die 'selected node30 legacy fee UTXO changed before bracket close'
cmp -s "$scratch/coin.before.json" "$scratch/coin.after.json" ||
    v3015_die 'selected node30 legacy fee UTXO changed during preflight'
node30_rpc 20 getblockchaininfo | jq -c '{chain,blocks,headers,bestblockhash,
  initialblockdownload,verificationprogress}' >"$scratch/chain.after.json"

for binary in blackcoind blackcoin-cli blackcoin-qt blackcoin-tx blackcoin-wallet blackcoin-util; do
    docker exec "$node30_container" sha256sum "/usr/local/bin/$binary"
done | awk '{name=$2; sub(".*/", "", name); printf "%s %s\n", name, $1}' | sort \
  >"$scratch/binaries.txt"
jq -Rn '[inputs | split(" ") | {(.[0]):.[1]}] | add' <"$scratch/binaries.txt" \
  >"$scratch/binaries.json"

jq -n --argjson captured "$captured_epoch" \
  --argjson broadcast "$broadcast_count" --argjson queue_files "$queue_regular" \
  --argjson queue_entries "$queue_entries" --argjson queue_nonregular "$queue_nonregular" \
  --argjson sponsorships "$sponsorships_today" --arg queue_name "$NODE30_QUEUE_ITEM_BASENAME" \
  --arg queue_sha "$NODE30_QUEUE_ITEM_SHA256" \
  --arg queue_address_sha "$NODE30_QUEUE_ADDRESS_SHA256" \
  --arg awarded_sha "$NODE30_AWARDED_SHA256" --argjson daily_cap "$NODE30_DAILY_CAP" \
  --argjson lock_paths "$(v3015_node30_lock_paths_json)" \
  --slurpfile before "$scratch/chain.before.json" \
  --slurpfile after "$scratch/chain.after.json" --slurpfile network "$scratch/network.json" \
  --slurpfile wallets "$scratch/wallets.json" --slurpfile wallet "$scratch/wallet.json" \
  --slurpfile staking "$scratch/staking.json" --slurpfile pow "$scratch/pow.json" \
  --slurpfile recovery "$scratch/recovery.json" \
  --slurpfile selected "$scratch/selected-utxo.json" \
  --slurpfile target "$scratch/target-address.json" \
  --slurpfile queue_record "$queue_file" --slurpfile address "$scratch/address-info.json" \
  --slurpfile work "$scratch/work.json" --slurpfile goldrush "$scratch/goldrush.json" \
  --slurpfile container "$scratch/container.json" \
  --slurpfile binaries "$scratch/binaries.json" \
  --slurpfile coin_before "$scratch/coin.before.json" \
  --slurpfile coin_after "$scratch/coin.after.json" '
    {schema:1,captured_epoch:$captured,before_chain:$before[0],after_chain:$after[0],
     network:$network[0],wallets:$wallets[0],wallet:$wallet[0],staking:$staking[0],
     pow:$pow[0],recovery:$recovery[0],selected_utxo:$selected[0],
     selected_coin_before:$coin_before[0],selected_coin_after:$coin_after[0],
     target_address_info:$target[0],
     queue:{basename:$queue_name,sha256:$queue_sha,address_sha256:$queue_address_sha,
       awarded_sha256:$awarded_sha,files_count:$queue_files,
       other_entries:($queue_entries-$queue_files),nonregular_entries:$queue_nonregular,
       address_already_awarded:false,sponsorships_today:$sponsorships,
       daily_cap:$daily_cap,record:$queue_record[0]},
     address_info:$address[0],work:$work[0],goldrush:$goldrush[0],
     broadcast_count:$broadcast,container:$container[0],binary_sha256s:$binaries[0],
     lock_paths:$lock_paths}' >"$scratch/snapshot.json"

v3015_node30_runtime_snapshot_is_valid "$scratch/snapshot.json" ||
    v3015_die 'node30 runtime/queue/claim preflight failed closed'
NODE30_AUDIT_TOOL_SHA256=$(v3015_sha256_file "$package_dir/node30_free_claim_release.sh")
audit_json=$(v3015_node30_make_safe_audit_receipt "$scratch/snapshot.json") ||
    v3015_die 'node30 safe audit receipt could not be projected'
v3015_node30_audit_receipt_is_valid <(printf '%s\n' "$audit_json") \
  "$NODE30_AUDIT_TOOL_SHA256" || v3015_die 'node30 audit receipt projection is invalid'

if [[ "$mode" == audit ]]; then
    printf '%s\n' "$audit_json"
    exit 0
fi

[[ -f "$prior_audit" && ! -L "$prior_audit" && \
   "$(realpath -e -- "$prior_audit")" == "$prior_audit" && \
   "$(stat -c '%u:%g:%a:%h' -- "$prior_audit")" == 0:0:600:1 && \
   "$prior_audit_sha" =~ ^[0-9a-f]{64}$ && \
   "$(v3015_sha256_file "$prior_audit")" == "$prior_audit_sha" ]] ||
    v3015_die 'release requires one exact root-owned prior audit receipt and SHA256'
v3015_node30_audit_receipt_is_valid "$prior_audit" "$NODE30_AUDIT_TOOL_SHA256" ||
    v3015_die 'prior audit receipt is not exact'
v3015_node30_audit_matches_current "$(<"$prior_audit")" "$audit_json" ||
    v3015_die 'prior audit is stale against the fresh under-lock resample'
v3015_die 'node30 release_eligible=false: exact fee-input, max-total-fee, one-shot dispatch, and atomic re-pause interfaces are unresolved'
