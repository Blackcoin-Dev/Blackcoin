#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C
export TZ=UTC
umask 077

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
REPO_ROOT=$(git -C "$ROOT" rev-parse --show-toplevel)
TOOL="$ROOT/node27_recovery_canary.sh"
MOCK="$ROOT/tests/mock_docker.sh"
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
    mkdir -p "$TMP/$name/bin" "$TMP/$name/state" "$TMP/$name/out"
    FIX=$(cd "$TMP/$name" && pwd -P)
    ln -s "$MOCK" "$FIX/bin/docker"
    printf 'unsigned\n' > "$FIX/state/state"
    : > "$FIX/log"
}

run_tool()
{
    env PATH="$FIX/bin:$PATH" MOCK_STATE_DIR="$FIX/state" MOCK_LOG="$FIX/log" \
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
    run_tool sign-only --output "$FIX/out/sign.json" \
        --audit-receipt "$FIX/out/audit.json" --audit-sha256 "$AUDIT_SHA" \
        --authority-receipt "$FIX/out/sign-authority.json" \
        --authority-sha256 "$SIGN_AUTH_SHA" >/dev/null 2>&1
    SIGN_SHA=$(hash_file "$FIX/out/sign.json")
}

make_relay_authority()
{
    local tool_sha txid
    tool_sha=$(hash_file "$TOOL")
    txid=$(jq -r '.signed_transaction.txid' "$FIX/out/sign.json")
    jq -n --arg sign "$SIGN_SHA" --arg tool "$tool_sha" --arg txid "$txid" '
      {schema:1,authority:"node27-v30.1.4-targeted-recovery-relay",decision:"authorize",
       sign_receipt_sha256:$sign,tool_sha256:$tool,node:27,service:"node27",
       image_ref:"qqblackcoin/blackcoin-v4-gui@sha256:7a384dd5f12c15fb41b36868d946007524bebf97650883d533635658641e04a2",
       image_id:"sha256:620146d14a57fe0d5d1fc29a7d913d47787ba924c96ba06eeb1ddbe8efb73909",
       wallet:"",claim_txid:"2e76269d688a5c218703b800516a9c0b0b2757d5077a14c84a6473e33006103d",
       anchor_txid:"3e5437d71a2ba10e7cf1ab7b02ec458847d081a97041efd1e5336660b22cde87",
       anchor_vout:0,resolution_txid:$txid,transaction_count:1,fee_blk:"0.00019100",
       acknowledgements:{exact_signed_bytes_reviewed:true,fee_and_conflict_risk:true,
         unbound_qqp2_may_revalidate:true,potential_quantum_payout_forfeiture:true,
         durable_relay_across_restart:true,propagated_transaction_cannot_be_recalled:true,
         original_claim_or_resolution_may_confirm:true,
         future_pow_claim_fees_not_capped_by_this_receipt:true,
         no_generic_transaction_rpc:true,no_fee_bump_or_replacement:true,
         no_fleet_expansion:true}}
    ' > "$FIX/out/relay-authority.json"
    chmod 600 "$FIX/out/relay-authority.json"
    RELAY_AUTH_SHA=$(hash_file "$FIX/out/relay-authority.json")
}

make_relayed()
{
    make_signed
    make_relay_authority
    run_tool relay --output "$FIX/out/relay.json" \
        --sign-receipt "$FIX/out/sign.json" --sign-sha256 "$SIGN_SHA" \
        --authority-receipt "$FIX/out/relay-authority.json" \
        --authority-sha256 "$RELAY_AUTH_SHA" >/dev/null 2>&1
    RELAY_SHA=$(hash_file "$FIX/out/relay.json")
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
assert_true grep -Fq "readonly NODE_ID=27" "$TOOL"
assert_true grep -Fq "readonly SERVICE='node27'" "$TOOL"
assert_true grep -Fq "readonly CONTAINER='blackcoin-v4-gui-27'" "$TOOL"
assert_true grep -Fq "readonly RECOVERY_FEE='0.00019100'" "$TOOL"
assert_true grep -Fq "readonly REQUIRED_CONFIRMATIONS=6" "$TOOL"
assert_true grep -Fq 'max_fee_per_resolution:0.00019100,max_total_fee:0.00019100' "$TOOL"
assert_true grep -Fq "commitshadowpowclaimresolution \"\$txid\" true" "$TOOL"
assert_true grep -Fq 'no_fee_bump_or_replacement:true' "$TOOL"
assert_true grep -Fq 'no_fleet_expansion:true' "$TOOL"
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
assert_eq "$(cat "$FIX/state/state")" unsigned
if grep -Eq 'rpc commitshadowpowclaimresolution|"action":"sign_only"' "$FIX/log"; then
    fail 'default audit reached a mutating method'
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
  .next_authority.authority == "node27-v30.1.4-targeted-recovery-relay" and
  .next_authority.generic_sendrawtransaction_authorized == false and
  .next_authority.fleet_expansion_authorized == false' "$FIX/out/sign.json"
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

for mutation in plan_id active_tip wallet_generation component_fingerprint unsigned_template_hash \
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
expect_fail sign-only --output "$FIX/out/sign-badhash.json" \
    --audit-receipt "$FIX/out/audit.json" --audit-sha256 "$AUDIT_SHA" \
    --authority-receipt "$FIX/out/sign-authority.json" \
    --authority-sha256 ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff

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

# Valid targeted relay, and no generic transaction RPC.
new_fixture relay-success
make_relayed
assert_jq '.phase == "relay" and .result == "resolution_in_mempool" and
  .mutation_performed == true' "$FIX/out/relay.json"
assert_jq '.resolution_txid == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "$FIX/out/relay.json"
assert_jq '.execution.relay_authority_granted == 1 and .execution.broadcast == 1 and
  .execution.relay_deferred == 0' "$FIX/out/relay.json"
assert_jq '.containment.exact_bytes_only == true and
  .containment.fee_bump_or_replacement == false and
  .containment.generic_sendrawtransaction == false and
  .containment.abandonment == false and .containment.fleet_expansion == false and
  .containment.propagated_bytes_recallable == false' "$FIX/out/relay.json"
assert_jq '.final_acceptance.required_confirmations == 6 and
  .final_acceptance.pos_active_required == true and
  .final_acceptance.positive_hashrate_required == true and
  .final_acceptance.claims_submitted_must_exceed == 4' "$FIX/out/relay.json"
assert_eq "$(cat "$FIX/state/state")" relayed
assert_eq "$(grep -c '^rpc commitshadowpowclaimresolution aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa true$' "$FIX/log")" 1
if grep -Eq '^rpc (sendrawtransaction|abandontransaction|bumpfee|setpowmining|walletpassphrase)' "$FIX/log"; then
    fail 'relay flow used a forbidden RPC'
fi
ok
if grep -Eq 'blackcoin-v4-gui-(1|2|3|4|5|6|7|8|9|10|11|12|13|14|15|16|17|18|19|20|21|22|23|24|25|26|28|29|30|31|32)( |$)' "$FIX/log"; then
    fail 'relay flow contacted another node'
fi
ok

# Relay authority hostiles fail before commit.
new_fixture relay-authority-hostiles
make_signed
make_relay_authority
for mutation in decision sign_receipt_sha256 tool_sha256 node service image_ref image_id wallet \
    claim_txid anchor_txid anchor_vout resolution_txid transaction_count fee_blk; do
    jq --arg field "$mutation" '.[$field]="hostile"' "$FIX/out/relay-authority.json" > "$FIX/out/bad-relay-authority.json"
    chmod 600 "$FIX/out/bad-relay-authority.json"
    BAD_SHA=$(hash_file "$FIX/out/bad-relay-authority.json")
    expect_fail relay --output "$FIX/out/relay-$mutation.json" \
        --sign-receipt "$FIX/out/sign.json" --sign-sha256 "$SIGN_SHA" \
        --authority-receipt "$FIX/out/bad-relay-authority.json" --authority-sha256 "$BAD_SHA"
    assert_eq "$(cat "$FIX/state/state")" signed
done
jq '.acknowledgements.propagated_transaction_cannot_be_recalled=false' \
    "$FIX/out/relay-authority.json" > "$FIX/out/bad-relay-authority.json"
chmod 600 "$FIX/out/bad-relay-authority.json"
BAD_SHA=$(hash_file "$FIX/out/bad-relay-authority.json")
expect_fail relay --output "$FIX/out/relay-ack.json" \
    --sign-receipt "$FIX/out/sign.json" --sign-sha256 "$SIGN_SHA" \
    --authority-receipt "$FIX/out/bad-relay-authority.json" --authority-sha256 "$BAD_SHA"
assert_eq "$(grep -c '^rpc commitshadowpowclaimresolution' "$FIX/log" || true)" 0

# A deferred relay is durably receipted but exits nonzero and never substitutes bytes.
new_fixture relay-deferred
make_signed
make_relay_authority
SCENARIO=relay-deferred
expect_fail relay --output "$FIX/out/relay.json" \
    --sign-receipt "$FIX/out/sign.json" --sign-sha256 "$SIGN_SHA" \
    --authority-receipt "$FIX/out/relay-authority.json" --authority-sha256 "$RELAY_AUTH_SHA"
assert_jq '.result == "authorized_relay_not_observed" and
  .execution.relay_authority_granted == 1 and .execution.relay_deferred == 1' "$FIX/out/relay.json"
assert_eq "$(cat "$FIX/state/state")" relayed
assert_eq "$(grep -c '^rpc commitshadowpowclaimresolution aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa true$' "$FIX/log")" 1
SCENARIO=success

# Final verification requires one six-confirmation winner and all three service receipts.
new_fixture final-success
make_relayed
printf 'final\n' > "$FIX/state/state"
run_tool verify-final --output "$FIX/out/final.json" \
    --sign-receipt "$FIX/out/sign.json" --sign-sha256 "$SIGN_SHA" \
    --relay-receipt "$FIX/out/relay.json" --relay-sha256 "$RELAY_SHA" >/dev/null 2>&1
assert_jq '.phase == "verify-final" and .result == "canary_accepted" and
  .mutation_performed == false' "$FIX/out/final.json"
assert_jq '.active_chain.winner == "resolution" and .active_chain.confirmations >= 6 and
  .active_chain.anchor_spent == true' "$FIX/out/final.json"
assert_jq '.recovery_gate.blocking_components == 0 and
  .recovery_gate.blocking_claims == 0 and
  .recovery_gate.database_outcome_ambiguous == false' "$FIX/out/final.json"
assert_jq '.service_evidence.pos_enabled == true and .service_evidence.pos_staking == true and
  .service_evidence.pos_weight > 0' "$FIX/out/final.json"
assert_jq '.service_evidence.pow_enabled == true and
  .service_evidence.pow_state == "hashing" and .service_evidence.pow_hashrate > 0' "$FIX/out/final.json"
assert_jq '.service_evidence.claims_submitted_baseline == 4 and
  .service_evidence.claims_submitted_after > 4 and
  .service_evidence.key_inventory_unchanged == true' "$FIX/out/final.json"
assert_jq '.scope == {candidate_bytes_deployed:false,fleet_expansion:false,
  node27_only:true,node30_untouched:true}' "$FIX/out/final.json"

# Original-claim-wins is accepted only when it has the same six-confirmation and liveness proof.
new_fixture final-original-wins
make_relayed
printf 'final\n' > "$FIX/state/state"
SCENARIO=final-claim-wins
run_tool verify-final --output "$FIX/out/final.json" \
    --sign-receipt "$FIX/out/sign.json" --sign-sha256 "$SIGN_SHA" \
    --relay-receipt "$FIX/out/relay.json" --relay-sha256 "$RELAY_SHA" >/dev/null 2>&1
assert_jq '.active_chain.winner == "original_claim" and
  .active_chain.winner_txid == "2e76269d688a5c218703b800516a9c0b0b2757d5077a14c84a6473e33006103d" and
  .active_chain.confirmations >= 6' "$FIX/out/final.json"
SCENARIO=success

# Each missing terminal predicate is independently fail-closed.
for scenario in final-five-conf final-no-hash final-no-claim final-no-pos final-pow-disabled; do
    new_fixture "terminal-$scenario"
    SCENARIO=success
    make_relayed
    printf 'final\n' > "$FIX/state/state"
    SCENARIO=$scenario
    expect_fail verify-final --output "$FIX/out/final.json" \
        --sign-receipt "$FIX/out/sign.json" --sign-sha256 "$SIGN_SHA" \
        --relay-receipt "$FIX/out/relay.json" --relay-sha256 "$RELAY_SHA"
    assert_true test ! -e "$FIX/out/final.json"
done
SCENARIO=success

git -C "$REPO_ROOT" diff --check -- contrib/ops/v30.1.4-node27-recovery-canary >/dev/null
ok

printf 'PASS: %d hostile node27 two-phase recovery-canary assertions\n' "$ASSERTIONS"
