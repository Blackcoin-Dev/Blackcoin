#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C
export TZ=UTC
umask 077

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
REPO_ROOT=$(git -C "$ROOT" rev-parse --show-toplevel)
TOOL="$ROOT/node27_recovery_canary.sh"
MOCK="$ROOT/tests/mock_docker.sh"
PRODUCT_RECEIPT="$ROOT/PRODUCT-TEST-RECEIPT.json"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

ASSERTIONS=0

ok()
{
    ASSERTIONS=$((ASSERTIONS + 1))
}

fail()
{
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_true()
{
    "$@" || fail "command failed: $*"
    ok
}

assert_jq()
{
    local expression=$1 file=$2
    jq -e "$expression" "$file" >/dev/null || fail "jq assertion failed: $expression ($file)"
    ok
}

assert_eq()
{
    [[ "$1" == "$2" ]] || fail "not equal: <$1> != <$2>"
    ok
}

hash_file()
{
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum -- "$1" | awk '{print $1}'
    else
        shasum -a 256 -- "$1" | awk '{print $1}'
    fi
}

new_fixture()
{
    local name=$1
    mkdir -p "$TMP/$name/bin" "$TMP/$name/state/locks" "$TMP/$name/out"
    FIX=$(cd "$TMP/$name" && pwd -P)
    ln -s "$MOCK" "$FIX/bin/docker"
    printf 'unsigned\n' > "$FIX/state/state"
    : > "$FIX/log"
}

run_tool()
{
    env PATH="$PATH" NODE27_TEST_TRANSPORT_PATH="$MOCK" \
        NODE27_TEST_LOCK_ROOT="$FIX/state/locks" \
        MOCK_STATE_DIR="$FIX/state" MOCK_LOG="$FIX/log" \
        MOCK_SCENARIO="${SCENARIO:-success}" "$TOOL" "$@"
}

expect_fail()
{
    local stderr=$FIX/failure.stderr
    if run_tool "$@" > "$FIX/failure.stdout" 2> "$stderr"; then
        fail "command unexpectedly succeeded: $*"
    fi
    [[ -s "$stderr" ]] || fail 'failed command emitted no diagnostic'
    ok
}

make_audit()
{
    run_tool audit --output "$FIX/out/audit.json" >/dev/null 2>&1
    AUDIT_SHA=$(hash_file "$FIX/out/audit.json")
}

make_sign_authority()
{
    jq --arg sha "$AUDIT_SHA" '
      .required_next_authority.audit_receipt_sha256=$sha |
      .required_next_authority
    ' "$FIX/out/audit.json" > "$FIX/out/sign-authority.json"
    chmod 600 "$FIX/out/sign-authority.json"
    SIGN_AUTH_SHA=$(hash_file "$FIX/out/sign-authority.json")
}

make_signed()
{
    make_audit
    make_sign_authority
    if ! run_tool sign-only --output "$FIX/out/sign.json" \
        --audit-receipt "$FIX/out/audit.json" --audit-sha256 "$AUDIT_SHA" \
        --authority-receipt "$FIX/out/sign-authority.json" \
        --authority-sha256 "$SIGN_AUTH_SHA" >/dev/null 2>"$FIX/sign.stderr"; then
        sed -n '1,120p' "$FIX/sign.stderr" >&2
        fail 'sign-only fixture setup failed'
    fi
    SIGN_SHA=$(hash_file "$FIX/out/sign.json")
}

make_relay_authority()
{
    local tool_sha txid now
    tool_sha=$(hash_file "$TOOL")
    txid=$(jq -r '.signed_transaction.txid' "$FIX/out/sign.json")
    now=$(date +%s)
    jq -n --arg sign "$SIGN_SHA" --arg tool "$tool_sha" --arg txid "$txid" \
      --arg nonce 11111111111111111111111111111111 --argjson now "$now" \
      --slurpfile signed "$FIX/out/sign.json" '
      {schema:1,authority:"node27-v30.1.4-historical-relay-observation-context",
       decision:"observe_only",
       sign_receipt_sha256:$sign,tool_sha256:$tool,node:27,service:"node27",
       transport:$signed[0].transport,authority_nonce:$nonce,
       mutation_lock_paths:[$signed[0].mutation_locks[].path],
       mutation_locks_sha256:$signed[0].mutation_locks_sha256,
       not_before_epoch:($now-1),expires_epoch:($now+3599),
       image_ref:"qqblackcoin/blackcoin-v4-gui@sha256:7a384dd5f12c15fb41b36868d946007524bebf97650883d533635658641e04a2",
       image_id:"sha256:620146d14a57fe0d5d1fc29a7d913d47787ba924c96ba06eeb1ddbe8efb73909",
       wallet:"",claim_txid:"2e76269d688a5c218703b800516a9c0b0b2757d5077a14c84a6473e33006103d",
       anchor_txid:"3e5437d71a2ba10e7cf1ab7b02ec458847d081a97041efd1e5336660b22cde87",
       anchor_vout:0,resolution_txid:$txid,transaction_count:1,fee_blk:"0.00019100",
       plan_id:$signed[0].relay_binding.plan_id,
       relay_plan_sha256:$signed[0].relay_plan_sha256,
       active_tip:$signed[0].relay_binding.active_tip,
       active_height:$signed[0].relay_binding.active_height,
       chainwork:$signed[0].relay_binding.chainwork,
       wallet_generation:$signed[0].relay_binding.wallet_generation,
       wallet_processed_tip:$signed[0].relay_binding.wallet_processed_tip,
       wallet_processed_height:$signed[0].relay_binding.wallet_processed_height,
       component_fingerprint:$signed[0].relay_binding.component_fingerprint,
       generation_fingerprint:$signed[0].relay_binding.generation_fingerprint,
       signed_transaction_sha256:$signed[0].signed_transaction.hex_sha256,
       testmempoolaccept_sha256:$signed[0].relay_binding.testmempoolaccept_sha256,
       acknowledgements:{exact_signed_bytes_identified:true,no_mutation_authority:true,
         installed_relay_ineligible:true,observation_cannot_prove_commit_binding:true,
         expired_context_permitted_for_read_only_observation:true}}
    ' > "$FIX/out/relay-authority.json"
    chmod 600 "$FIX/out/relay-authority.json"
    RELAY_AUTH_SHA=$(hash_file "$FIX/out/relay-authority.json")
}

# Static and parser gates.
assert_true bash -n "$TOOL"
assert_true bash -n "$MOCK"
assert_true bash -n "$0"
assert_true shellcheck -x "$TOOL"
assert_true shellcheck -x "$MOCK"
assert_true shellcheck -x "$0"
assert_true test -x "$TOOL"
assert_true test -x "$MOCK"
assert_jq '.schema == 1 and .kind == "node27-recovery-canary-product-test" and
  .result == "PASS" and .live_mutation_performed == false and
  .stable_chain_bracket == true and .active_tip_bound == true and
  .height_bound == true and .wallet_generation_bound == true and
  .wallet_processed_tip_bound == true and .component_fingerprint_bound == true and
  .plan_id_bound == true and .txid_bound == true and .raw_hash_bound == true and
  .testmempoolaccept_bound == true and .current_recovery_rechecked == true and
  .commit_result_binds_acknowledged_plan == false and .relay_eligible == false and
  .installed_interface_blocked == true and
  .reconciled_observation_admissible_as_relay_receipt == false and
  .receipt_bytes_snapshotted_under_locks == true and
  .shared_mutation_locks_bound == true and .read_only_reconciliation_tested == true' \
  "$PRODUCT_RECEIPT"
assert_eq "$(jq -r '.tool_sha256' "$PRODUCT_RECEIPT")" "$(hash_file "$TOOL")"
assert_eq "$(jq -r '.mock_transport_sha256' "$PRODUCT_RECEIPT")" "$(hash_file "$MOCK")"
assert_eq "$(jq -r '.hostile_test_sha256' "$PRODUCT_RECEIPT")" "$(hash_file "$0")"
assert_jq '.hostile_assertions == 208 and
  (.hostile_log_sha256 | test("^[0-9a-f]{64}$"))' "$PRODUCT_RECEIPT"
assert_true grep -Fq "readonly NODE_ID=27" "$TOOL"
assert_true grep -Fq "readonly SERVICE='node27'" "$TOOL"
assert_true grep -Fq "readonly CONTAINER='blackcoin-v4-gui-27'" "$TOOL"
assert_true grep -Fq "readonly RECOVERY_FEE='0.00019100'" "$TOOL"
assert_true grep -Fq 'readonly INSTALLED_RELAY_ELIGIBLE=false' "$TOOL"
assert_true grep -Fq 'installed-v30.1.4-commit-does-not-consume-external-plan-tip-wallet-component-binding' "$TOOL"
assert_true grep -Fq 'max_fee_per_resolution:0.00019100,max_total_fee:0.00019100' "$TOOL"
if grep -Eq 'rpc[[:space:]]+commitshadowpowclaimresolution' "$TOOL"; then
    fail 'installed-v30.1.4 targeted relay RPC remains executable'
fi
ok
assert_true grep -Fq 'no_fleet_expansion:true' "$TOOL"
assert_true grep -Fq 'readonly MUTATION_LOCK_BASENAMES=(' "$TOOL"
assert_true grep -Fq 'blackcoin-v3015-rollout.lock' "$TOOL"
assert_true grep -Fq 'blackcoin-endpoint-guard.lock' "$TOOL"
assert_true grep -Fq 'blackcoin-node-cutover.lock' "$TOOL"
assert_true grep -Fq 'blackcoin-pow-quarantine-cycle.lock' "$TOOL"
assert_true grep -Fq 'blackcoin-wallet-runtime-guard.lock' "$TOOL"
assert_true grep -Fq 'blackcoin-node27-recovery.lock' "$TOOL"
assert_true grep -Fq 'testmempoolaccept' "$TOOL"
if grep -Eq 'rpc[[:space:]]+(sendrawtransaction|abandontransaction|bumpfee|walletpassphrase|setpowmining|setpowclaimrecovery)' "$TOOL"; then
    fail 'forbidden RPC is executable from the tool'
fi
ok
if grep -Eq 'docker_call[[:space:]]+(compose|run|start|stop|restart|rm|kill)' "$TOOL"; then
    fail 'container or Compose mutation is executable from the tool'
fi
ok
if grep -Eq '\{1\.\.[0-9]+\}|seq[[:space:]]+[0-9]+[[:space:]]+[0-9]+' "$TOOL"; then
    fail 'fleet iteration appeared in single-node tool'
fi
ok

# Default and explicit audit are read-only and exact.
new_fixture default-audit
run_tool --output "$FIX/out/default.json" >/dev/null 2>&1
assert_jq '.phase == "audit" and .mutation_performed == false' "$FIX/out/default.json"
assert_jq '.runtime.node == 27 and .runtime.service == "node27" and
  .runtime.container == "blackcoin-v4-gui-27"' "$FIX/out/default.json"
assert_jq '.runtime.image_ref == "qqblackcoin/blackcoin-v4-gui@sha256:7a384dd5f12c15fb41b36868d946007524bebf97650883d533635658641e04a2"' "$FIX/out/default.json"
assert_jq '.runtime.image_id == "sha256:620146d14a57fe0d5d1fc29a7d913d47787ba924c96ba06eeb1ddbe8efb73909"' "$FIX/out/default.json"
assert_jq '.wallet.name == "" and .wallet.txcount == 1044 and
  .wallet.key_creation_authorized == false' "$FIX/out/default.json"
assert_jq '.subject.claim_txid == "2e76269d688a5c218703b800516a9c0b0b2757d5077a14c84a6473e33006103d"' "$FIX/out/default.json"
assert_jq '.subject.anchor.txid == "3e5437d71a2ba10e7cf1ab7b02ec458847d081a97041efd1e5336660b22cde87" and
  .subject.anchor.vout == 0 and .subject.anchor.amount_blk == "9.83326930"' "$FIX/out/default.json"
assert_jq '.subject.generation_fingerprint == "0699e87473f8595f3ca9663ba5f8f3212a51fdab4f4aed62a4bea9a3f70ef860"' "$FIX/out/default.json"
assert_jq '.plan.transaction_count == 1 and .plan.fee_rate_sat_vb == 100 and
  .plan.vsize == 191' "$FIX/out/default.json"
assert_jq '.plan.fee_blk == "0.00019100" and
  .plan.max_fee_per_resolution_blk == "0.00019100" and
  .plan.max_total_fee_blk == "0.00019100"' "$FIX/out/default.json"
assert_jq '.plan.other_inputs_allowed == false and .plan.change_output == false and
  .plan.new_key_or_address == false' "$FIX/out/default.json"
assert_jq '.baseline.claims_submitted == 4 and .baseline.pos_staking == true and
  .baseline.pow_enabled == true and .baseline.pow_state == "claim_quarantined"' "$FIX/out/default.json"
assert_jq '.required_next_authority.decision == "authorize" and
  .required_next_authority.no_such_field == null and
  .required_next_authority.acknowledgements.no_fleet_expansion == true' "$FIX/out/default.json"
assert_jq '.chain.height == .chain.headers and (.chain.chainwork | test("^[0-9a-f]{64}$"))' \
  "$FIX/out/default.json"
assert_jq '.mutation_lock_contract.order ==
  "rollout_endpoint_cutover_pow_wallet_node27" and
  .mutation_lock_contract.required_for == ["sign-only"] and
  .mutation_lock_contract.read_only_observation == ["reconcile-sign","reconcile-relay"] and
  (.mutation_lock_contract.paths | length) == 6' "$FIX/out/default.json"
assert_eq "$(cat "$FIX/state/state")" unsigned
if grep -Eq 'rpc commitshadowpowclaimresolution|"action":"sign_only"' "$FIX/log"; then
    fail 'default audit reached a mutating method'
fi
ok

# Ambient shell and PATH injection cannot choose the interpreter, transport,
# hash implementation, or JSON parser. Test transport substitution remains an
# explicit exact sibling hook only.
new_fixture ambient-injection
# shellcheck disable=SC2016 # The hostile child must receive the literal variable.
printf '%s\n' 'touch "$MOCK_STATE_DIR/bash-env-ran"' > "$FIX/hostile-bash-env"
mkdir "$FIX/hostile-path"
for command_name in bash docker jq shasum sha256sum awk realpath stat; do
    # shellcheck disable=SC2016 # The hostile child must receive the literal variable.
    printf '%s\n' '#!/bin/sh' 'touch "$MOCK_STATE_DIR/hostile-path-ran"' 'exit 99' \
      > "$FIX/hostile-path/$command_name"
    chmod 755 "$FIX/hostile-path/$command_name"
done
env PATH="$FIX/hostile-path" BASH_ENV="$FIX/hostile-bash-env" ENV="$FIX/hostile-bash-env" \
    CDPATH=/tmp NODE27_TEST_TRANSPORT_PATH="$MOCK" NODE27_TEST_LOCK_ROOT="$FIX/state/locks" \
    MOCK_STATE_DIR="$FIX/state" MOCK_LOG="$FIX/log" MOCK_SCENARIO=success \
    "$TOOL" audit --output "$FIX/out/audit.json" >/dev/null 2>&1
assert_true test ! -e "$FIX/state/bash-env-ran"
assert_true test ! -e "$FIX/state/hostile-path-ran"
assert_jq '.phase == "audit" and .mutation_performed == false' "$FIX/out/audit.json"
ln -s "$MOCK" "$FIX/transport-link"
if env NODE27_TEST_TRANSPORT_PATH="$FIX/transport-link" \
    NODE27_TEST_LOCK_ROOT="$FIX/state/locks" MOCK_STATE_DIR="$FIX/state" \
    MOCK_LOG="$FIX/log" MOCK_SCENARIO=success "$TOOL" audit \
    --output "$FIX/out/symlink-audit.json" >/dev/null 2>&1; then
    fail 'symlink transport hook unexpectedly succeeded'
fi
ok
cp "$MOCK" "$FIX/transport-copy"
chmod 755 "$FIX/transport-copy"
if env NODE27_TEST_TRANSPORT_PATH="$FIX/transport-copy" \
    NODE27_TEST_LOCK_ROOT="$FIX/state/locks" MOCK_STATE_DIR="$FIX/state" \
    MOCK_LOG="$FIX/log" MOCK_SCENARIO=success "$TOOL" audit \
    --output "$FIX/out/copied-audit.json" >/dev/null 2>&1; then
    fail 'same-content alternate transport path unexpectedly succeeded'
fi
ok

# Read-only identity, component, fee, and wallet hostiles.
for scenario in wrong-image wrong-service wrong-project wrong-wallet bad-component bad-fee recovery-wrong-tip; do
    new_fixture "audit-$scenario"
    SCENARIO=$scenario
    expect_fail audit --output "$FIX/out/audit.json"
    assert_eq "$(cat "$FIX/state/state")" unsigned
    assert_true test ! -e "$FIX/out/audit.json"
done
SCENARIO=success

# Output replacement and argument smuggling are rejected.
new_fixture output-replace
make_audit
expect_fail audit --output "$FIX/out/audit.json"
expect_fail audit --audit-receipt "$FIX/out/audit.json"
expect_fail unknown
expect_fail relay --output "$FIX/out/relay.json"
expect_fail sign-only --output "$FIX/out/sign.json"

# A valid sign-only phase persists exactly one non-relayable transaction.
new_fixture sign-success
make_signed
assert_jq '.phase == "sign-only" and .result == "signed_nonrelayable_draft" and
  .mutation_performed == true' "$FIX/out/sign.json"
assert_jq '.signed_transaction.txid == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "$FIX/out/sign.json"
assert_jq '.signed_transaction.fee_blk == "0.00019100" and
  .signed_transaction.persisted == true and
  .signed_transaction.relay_authorized == false and
  .signed_transaction.in_mempool == false' "$FIX/out/sign.json"
assert_jq '.signed_transaction.decoded.vin | length == 1' "$FIX/out/sign.json"
assert_jq '.signed_transaction.decoded.vin[0].txid == "3e5437d71a2ba10e7cf1ab7b02ec458847d081a97041efd1e5336660b22cde87" and
  .signed_transaction.decoded.vin[0].vout == 0 and
  .signed_transaction.decoded.vin[0].sequence == 4294967295' "$FIX/out/sign.json"
assert_jq '.signed_transaction.decoded.vout | length == 1' "$FIX/out/sign.json"
assert_jq '.signed_transaction.decoded.vout[0].value == 9.83307830 and
  .signed_transaction.decoded.vout[0].scriptPubKey.hex == "76a914085f283018f571e673c38efe7a648493ce3b499088ac"' "$FIX/out/sign.json"
assert_jq '.execution.signed_and_persisted == 1 and .execution.relay_authority_granted == 0 and
  .execution.broadcast == 0 and .execution.already_in_mempool == 0 and
  .execution.relay_deferred == 0' "$FIX/out/sign.json"
assert_jq '.post_state.wallet_txcount == 1045 and .post_state.pending_manual_resolutions == 1' "$FIX/out/sign.json"
assert_jq '.post_state.claims_submitted == 4 and .post_state.pow_enabled == true and
  .post_state.pow_state == "claim_quarantined" and .post_state.pow_hashrate == 0' "$FIX/out/sign.json"
assert_jq '.post_state.pos_enabled == true and .post_state.pos_staking == true and
  .post_state.pos_weight > 0' "$FIX/out/sign.json"
assert_jq '.next_authority.required == true and
  .next_authority.status == "blocked_on_successor_core_interface" and
  .next_authority.authority == "node27-successor-targeted-recovery-relay" and
  .next_authority.relay_eligible == false and
  .next_authority.interface_blocker ==
    "installed-v30.1.4-commit-does-not-consume-external-plan-tip-wallet-component-binding" and
  .next_authority.durable_commit_receipt_reconstructable == false and
  .next_authority.generic_sendrawtransaction_authorized == false and
  .next_authority.fleet_expansion_authorized == false' "$FIX/out/sign.json"
assert_jq '.relay_binding.plan_id == "990067c186ce29d5752520cf2f61cb09a1d186f27cc784f10dbe94fc62c901d7" and
  .relay_binding.active_tip == .relay_binding.wallet_processed_tip and
  .relay_binding.active_height == .relay_binding.wallet_processed_height and
  .relay_binding.wallet_generation == 115 and
  .relay_binding.component_fingerprint == "c2264221895cea65509aa59e4de27a9b50958f1caee05b5302193544f3f8eb30" and
  .relay_binding.resolution_txid == .signed_transaction.txid and
  .relay_binding.signed_transaction_sha256 == .signed_transaction.hex_sha256 and
  .relay_binding.testmempoolaccept ==
    [{txid:.signed_transaction.txid,allowed:true,vsize:191}] and
  (.relay_binding.testmempoolaccept_sha256 | test("^[0-9a-f]{64}$")) and
  (.relay_plan_sha256 | test("^[0-9a-f]{64}$"))' "$FIX/out/sign.json"
assert_eq "$(cat "$FIX/state/state")" signed
if grep -q 'rpc commitshadowpowclaimresolution' "$FIX/log"; then
    fail 'sign-only invocation crossed the relay boundary'
fi
ok

# Financial authority must be exact, immutable, canonical, private, and plan-bound.
new_fixture sign-authority-hostiles
make_audit
make_sign_authority
cp "$FIX/out/sign-authority.json" "$FIX/out/bad-authority.json"
chmod 600 "$FIX/out/bad-authority.json"
jq '.fee_blk="0.00019200"' "$FIX/out/sign-authority.json" > "$FIX/out/bad-authority.json"
BAD_SHA=$(hash_file "$FIX/out/bad-authority.json")
expect_fail sign-only --output "$FIX/out/sign.json" \
    --audit-receipt "$FIX/out/audit.json" --audit-sha256 "$AUDIT_SHA" \
    --authority-receipt "$FIX/out/bad-authority.json" --authority-sha256 "$BAD_SHA"
assert_eq "$(cat "$FIX/state/state")" unsigned

for mutation in plan_id active_tip chainwork wallet_generation component_fingerprint unsigned_template_hash \
    transaction_count fee_rate_sat_vb max_fee_per_resolution_blk max_total_fee_blk decision tool_sha256 \
    transport_sha256 node service container image_ref image_id wallet claim_txid anchor_txid anchor_vout; do
    jq --arg field "$mutation" '.[$field]="hostile"' "$FIX/out/sign-authority.json" > "$FIX/out/bad-authority.json"
    chmod 600 "$FIX/out/bad-authority.json"
    BAD_SHA=$(hash_file "$FIX/out/bad-authority.json")
    expect_fail sign-only --output "$FIX/out/sign-$mutation.json" \
        --audit-receipt "$FIX/out/audit.json" --audit-sha256 "$AUDIT_SHA" \
        --authority-receipt "$FIX/out/bad-authority.json" --authority-sha256 "$BAD_SHA"
    assert_eq "$(cat "$FIX/state/state")" unsigned
done
jq '.extra="smuggled"' "$FIX/out/sign-authority.json" > "$FIX/out/bad-authority.json"
chmod 600 "$FIX/out/bad-authority.json"
BAD_SHA=$(hash_file "$FIX/out/bad-authority.json")
expect_fail sign-only --output "$FIX/out/sign-extra.json" \
    --audit-receipt "$FIX/out/audit.json" --audit-sha256 "$AUDIT_SHA" \
    --authority-receipt "$FIX/out/bad-authority.json" --authority-sha256 "$BAD_SHA"

cp "$FIX/out/sign-authority.json" "$FIX/out/mode-authority.json"
chmod 644 "$FIX/out/mode-authority.json"
BAD_SHA=$(hash_file "$FIX/out/mode-authority.json")
expect_fail sign-only --output "$FIX/out/sign-mode.json" \
    --audit-receipt "$FIX/out/audit.json" --audit-sha256 "$AUDIT_SHA" \
    --authority-receipt "$FIX/out/mode-authority.json" --authority-sha256 "$BAD_SHA"
ln -s "$FIX/out/sign-authority.json" "$FIX/out/link-authority.json"
expect_fail sign-only --output "$FIX/out/sign-link.json" \
    --audit-receipt "$FIX/out/audit.json" --audit-sha256 "$AUDIT_SHA" \
    --authority-receipt "$FIX/out/link-authority.json" --authority-sha256 "$SIGN_AUTH_SHA"
ln "$FIX/out/sign-authority.json" "$FIX/out/hardlink-authority.json"
expect_fail sign-only --output "$FIX/out/sign-hardlink.json" \
    --audit-receipt "$FIX/out/audit.json" --audit-sha256 "$AUDIT_SHA" \
    --authority-receipt "$FIX/out/sign-authority.json" --authority-sha256 "$SIGN_AUTH_SHA"
rm "$FIX/out/hardlink-authority.json"
expect_fail sign-only --output "$FIX/out/sign-badhash.json" \
    --audit-receipt "$FIX/out/audit.json" --audit-sha256 "$AUDIT_SHA" \
    --authority-receipt "$FIX/out/sign-authority.json" \
    --authority-sha256 ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff

# Inputs and publishers require owned, nonwritable ancestry. Receipt bytes are
# opened, inode-pinned, and snapshotted under the locks; a later path swap is
# never parsed as authority for the sign-only mutation.
new_fixture unsafe-receipt-parent
make_audit
make_sign_authority
mkdir "$FIX/writable"
chmod 777 "$FIX/writable"
cp "$FIX/out/sign-authority.json" "$FIX/writable/sign-authority.json"
chmod 600 "$FIX/writable/sign-authority.json"
BAD_SHA=$(hash_file "$FIX/writable/sign-authority.json")
expect_fail sign-only --output "$FIX/out/sign.json" \
    --audit-receipt "$FIX/out/audit.json" --audit-sha256 "$AUDIT_SHA" \
    --authority-receipt "$FIX/writable/sign-authority.json" --authority-sha256 "$BAD_SHA"
assert_eq "$(cat "$FIX/state/state")" unsigned
expect_fail audit --output "$FIX/writable/audit.json"
assert_true test ! -e "$FIX/writable/audit.json"

new_fixture snapshotted-authority-path-swap
make_audit
make_sign_authority
ORIGINAL_AUTH_SHA=$SIGN_AUTH_SHA
jq '.fee_blk="99.00000000"' "$FIX/out/sign-authority.json" > "$FIX/out/hostile-swap.json"
chmod 600 "$FIX/out/hostile-swap.json"
HOSTILE_AUTH_SHA=$(hash_file "$FIX/out/hostile-swap.json")
export MOCK_SWAP_TARGET="$FIX/out/sign-authority.json"
export MOCK_SWAP_SOURCE="$FIX/out/hostile-swap.json"
export MOCK_SWAP_MARKER="$FIX/state/swap-complete"
run_tool sign-only --output "$FIX/out/sign.json" \
    --audit-receipt "$FIX/out/audit.json" --audit-sha256 "$AUDIT_SHA" \
    --authority-receipt "$FIX/out/sign-authority.json" \
    --authority-sha256 "$ORIGINAL_AUTH_SHA" >/dev/null 2>&1
unset MOCK_SWAP_TARGET MOCK_SWAP_SOURCE MOCK_SWAP_MARKER
assert_true test -e "$FIX/state/swap-complete"
assert_eq "$(hash_file "$FIX/out/sign-authority.json")" "$HOSTILE_AUTH_SHA"
assert_eq "$(jq -r '.financial_authority_receipt_sha256' "$FIX/out/sign.json")" \
  "$ORIGINAL_AUTH_SHA"
assert_jq '.signed_transaction.relay_authorized == false' "$FIX/out/sign.json"
assert_eq "$(grep -c '^rpc commitshadowpowclaimresolution' "$FIX/log" || true)" 0

# Every shared lock independently blocks before the sign-only mutation. The
# test-only reservation is the deterministic local equivalent of a contended
# flock; production uses the reviewed /usr/bin/flock on the same ordered files.
for lock_name in blackcoin-v3015-rollout.lock blackcoin-endpoint-guard.lock \
    blackcoin-node-cutover.lock blackcoin-pow-quarantine-cycle.lock \
    blackcoin-wallet-runtime-guard.lock blackcoin-node27-recovery.lock; do
    new_fixture "sign-lock-${lock_name%.lock}"
    make_audit
    make_sign_authority
    mkdir "$FIX/state/locks/$lock_name.held"
    expect_fail sign-only --output "$FIX/out/sign.json" \
        --audit-receipt "$FIX/out/audit.json" --audit-sha256 "$AUDIT_SHA" \
        --authority-receipt "$FIX/out/sign-authority.json" --authority-sha256 "$SIGN_AUTH_SHA"
    assert_eq "$(cat "$FIX/state/state")" unsigned
    assert_eq "$(grep -c 'rpc resolveallshadowpowclaims.*sign_only' "$FIX/log" || true)" 0
done

new_fixture sign-lock-path-swap
make_audit
make_sign_authority
touch "$FIX/state/hostile-lock"
ln -s "$FIX/state/hostile-lock" "$FIX/state/locks/blackcoin-v3015-rollout.lock"
expect_fail sign-only --output "$FIX/out/sign.json" \
    --audit-receipt "$FIX/out/audit.json" --audit-sha256 "$AUDIT_SHA" \
    --authority-receipt "$FIX/out/sign-authority.json" --authority-sha256 "$SIGN_AUTH_SHA"
assert_eq "$(cat "$FIX/state/state")" unsigned
assert_eq "$(grep -c 'rpc resolveallshadowpowclaims.*sign_only' "$FIX/log" || true)" 0

# Signed-byte shape hostiles fail after persistence but never grant relay.
new_fixture signed-shape-hostile
make_audit
make_sign_authority
SCENARIO=extra-input
expect_fail sign-only --output "$FIX/out/sign.json" \
    --audit-receipt "$FIX/out/audit.json" --audit-sha256 "$AUDIT_SHA" \
    --authority-receipt "$FIX/out/sign-authority.json" --authority-sha256 "$SIGN_AUTH_SHA"
assert_eq "$(cat "$FIX/state/state")" signed
if grep -q 'rpc commitshadowpowclaimresolution' "$FIX/log"; then
    fail 'shape failure crossed relay boundary'
fi
ok
SCENARIO=success

# The post-sign mempool-policy result is inside the stable chain bracket. A tip
# change immediately after testmempoolaccept prevents receipt publication.
new_fixture post-sign-mempool-bracket
make_audit
make_sign_authority
SCENARIO=post-sign-tip-after-mempool
expect_fail sign-only --output "$FIX/out/sign.json" \
    --audit-receipt "$FIX/out/audit.json" --audit-sha256 "$AUDIT_SHA" \
    --authority-receipt "$FIX/out/sign-authority.json" --authority-sha256 "$SIGN_AUTH_SHA"
assert_eq "$(cat "$FIX/state/state")" signed
assert_true test -e "$FIX/state/tip-after-mempool"
assert_true test ! -e "$FIX/out/sign.json"
assert_eq "$(grep -c '^rpc commitshadowpowclaimresolution' "$FIX/log" || true)" 0
SCENARIO=success

# Installed v30.1.4 relay is an architectural hard blocker. Even exact current
# sign and authority receipts cannot reach locks, transport, or any mutating
# RPC because the installed commit interface does not consume the externally
# reviewed plan/tip/wallet/component tuple atomically.
new_fixture relay-interface-blocked
make_signed
make_relay_authority
LOG_LINES_BEFORE=$(wc -l < "$FIX/log" | tr -d ' ')
expect_fail relay --output "$FIX/out/relay.json" \
    --sign-receipt "$FIX/out/sign.json" --sign-sha256 "$SIGN_SHA" \
    --authority-receipt "$FIX/out/relay-authority.json" --authority-sha256 "$RELAY_AUTH_SHA"
assert_true grep -Fq \
  'installed-v30.1.4-commit-does-not-consume-external-plan-tip-wallet-component-binding' \
  "$FIX/failure.stderr"
assert_eq "$(cat "$FIX/state/state")" signed
assert_eq "$(wc -l < "$FIX/log" | tr -d ' ')" "$LOG_LINES_BEFORE"
assert_eq "$(grep -c '^rpc commitshadowpowclaimresolution' "$FIX/log" || true)" 0
assert_true test ! -e "$FIX/out/relay.json"

# A post-sign publication failure is reconstructed from exact persisted bytes,
# the original audit/authority hashes, stable component state, and a fresh
# mempool-policy probe. The reconciliation path invokes no sign or relay RPC.
new_fixture reconcile-sign-success
make_audit
make_sign_authority
printf 'signed\n' > "$FIX/state/state"
run_tool reconcile-sign --output "$FIX/out/sign.json" \
    --audit-receipt "$FIX/out/audit.json" --audit-sha256 "$AUDIT_SHA" \
    --authority-receipt "$FIX/out/sign-authority.json" \
    --authority-sha256 "$SIGN_AUTH_SHA" >/dev/null 2>&1
SIGN_SHA=$(hash_file "$FIX/out/sign.json")
assert_jq '.phase == "reconcile-sign" and
  .result == "reconciled_signed_nonrelayable_draft" and
  .mutation_performed == false and .mutation_observed == true and
  .reconciliation == {ambiguous_state:false,exact_tool_and_authority_hashes:true,
    read_only:true,relay_rpc_invoked:false,sign_rpc_invoked:false}' "$FIX/out/sign.json"
assert_jq '.signed_transaction.persisted == true and
  .relay_binding.testmempoolaccept[0].allowed == true' "$FIX/out/sign.json"
assert_eq "$(grep -c 'rpc resolveallshadowpowclaims.*sign_only' "$FIX/log" || true)" 0
assert_eq "$(grep -c '^rpc commitshadowpowclaimresolution' "$FIX/log" || true)" 0

# Read-only relay observation is a separate, non-admissible evidence schema. It
# never fabricates a commit acknowledgement. Historical authority expiry does
# not prevent observation because the mode cannot grant or repeat mutation.
new_fixture reconcile-relay-success
make_signed
make_relay_authority
jq '.not_before_epoch=0 | .expires_epoch=1' "$FIX/out/relay-authority.json" \
  > "$FIX/out/expired-relay-authority.json"
chmod 600 "$FIX/out/expired-relay-authority.json"
RELAY_AUTH_SHA=$(hash_file "$FIX/out/expired-relay-authority.json")
printf 'relayed\n' > "$FIX/state/state"
run_tool reconcile-relay --output "$FIX/out/relay.json" \
    --sign-receipt "$FIX/out/sign.json" --sign-sha256 "$SIGN_SHA" \
    --authority-receipt "$FIX/out/expired-relay-authority.json" \
    --authority-sha256 "$RELAY_AUTH_SHA" >/dev/null 2>&1
assert_jq '.phase == "reconcile-relay-observation" and
  .result == "EXACT_BYTES_OBSERVED_UNATTRIBUTED" and
  .mutation_performed == false and .mutation_observed == true and
  .execution == {authorized_commit_proven:false,commit_acknowledgements_available:false,
    original_commit_result_available:false,reconstructed_read_only:true} and
  .reconciliation == {admissible_as_relay_receipt:false,ambiguous_state:false,
    authority_time_validated_for_mutation:false,exact_tool_and_historical_authority_hashes:true,
    read_only:true,relay_rpc_invoked:false,sign_rpc_invoked:false} and
  .observation.network_disposition == "resolution_in_mempool" and
  .observation.exact_bytes_observed == true and
  .observation.attribution_to_authorized_commit == false and
  .observation.consumed_plan_identity_reconstructable == false and
  .observation.installed_relay_eligible == false' "$FIX/out/relay.json"
assert_jq '.execution.acknowledged_plan_id == null and
  .execution.acknowledged_active_tip == null and
  .execution.acknowledged_wallet_generation == null' "$FIX/out/relay.json"
assert_eq "$(grep -c '^rpc commitshadowpowclaimresolution' "$FIX/log" || true)" 0

new_fixture reconcile-relay-ambiguous
make_signed
make_relay_authority
printf 'relayed\n' > "$FIX/state/state"
SCENARIO=relay-deferred
expect_fail reconcile-relay --output "$FIX/out/relay.json" \
    --sign-receipt "$FIX/out/sign.json" --sign-sha256 "$SIGN_SHA" \
    --authority-receipt "$FIX/out/relay-authority.json" --authority-sha256 "$RELAY_AUTH_SHA"
assert_jq '.phase == "reconcile-relay-observation" and .result == "AMBIGUOUS_CONTAINED" and
  .mutation_performed == false and .mutation_observed == false and
  .reconciliation.ambiguous_state == true and
  .reconciliation.admissible_as_relay_receipt == false and
  .execution.commit_acknowledgements_available == false' "$FIX/out/relay.json"
assert_eq "$(grep -c '^rpc commitshadowpowclaimresolution' "$FIX/log" || true)" 0
SCENARIO=success

# A read-only observation cannot be smuggled into final acceptance. The current
# tool has no admissible relay receipt and therefore no final-acceptance mode.
new_fixture final-interface-blocked
make_signed
expect_fail verify-final --output "$FIX/out/final.json" \
    --sign-receipt "$FIX/out/sign.json" --sign-sha256 "$SIGN_SHA" \
    --relay-receipt "$FIX/out/sign.json" --relay-sha256 "$SIGN_SHA"
assert_true grep -Fq \
  'final acceptance is unavailable because installed-v30.1.4 relay is nondeployable' \
  "$FIX/failure.stderr"
assert_true test ! -e "$FIX/out/final.json"
assert_eq "$(grep -c '^rpc commitshadowpowclaimresolution' "$FIX/log" || true)" 0

expected_manifest_paths=$(printf '%s\n' \
  ./PRODUCT-TEST-RECEIPT.json ./README.md ./VALIDATION.txt \
  ./node27_recovery_canary.sh ./tests/mock_docker.sh ./tests/run.sh | sort)
actual_manifest_paths=$(awk '{print $2}' "$ROOT/SHA256SUMS" | sort)
assert_eq "$actual_manifest_paths" "$expected_manifest_paths"
if command -v sha256sum >/dev/null 2>&1; then
    # shellcheck disable=SC2016 # The child Bash receives the positional root.
    assert_true bash -c 'cd "$1" && sha256sum --strict -c SHA256SUMS >/dev/null' \
      bash "$ROOT"
else
    # shellcheck disable=SC2016 # The child Bash receives the positional root.
    assert_true bash -c 'cd "$1" && shasum -a 256 -c SHA256SUMS >/dev/null' \
      bash "$ROOT"
fi

git -C "$REPO_ROOT" diff --check -- contrib/ops/v30.1.4-node27-recovery-canary >/dev/null
ok

printf 'PASS: %d hostile node27 sign-only/observation assertions\n' "$ASSERTIONS"
