#!/bin/bash -p
export LC_ALL=C TZ=UTC
set -Eeuo pipefail
umask 077
unset BASH_ENV ENV CDPATH GLOBIGNORE PYTHONPATH PYTHONHOME
PATH=/usr/bin:/bin
export PATH

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
TOOL="$ROOT/node30_recovery.py"
MOCK="$ROOT/tests/mock_transport.py"
FIX=$(mktemp -d /private/tmp/node30-retained-recovery-test.XXXXXX)
trap 'chmod -R u+w "$FIX" 2>/dev/null || true; rm -rf "$FIX"' EXIT
ASSERTIONS=0

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { ASSERTIONS=$((ASSERTIONS + 1)); }
assert_fails() { local label=$1; shift; if "$@" >"$FIX/fail.out" 2>"$FIX/fail.err"; then fail "$label unexpectedly succeeded"; fi; ok; }
assert_eq() { [[ "$1" == "$2" ]] || fail "expected [$2], got [$1]"; ok; }
assert_jq() { local filter=$1 file=$2; jq -e "$filter" "$file" >/dev/null || fail "jq assertion failed: $filter ($file)"; ok; }

make_artifacts()
{
    local root=$1
    mkdir -p "$root/free-claim"
    chmod 0700 "$root/free-claim"
    printf '%s\n' 'schema=1 state=paused authority=v30.1.4-fleet-transaction' >"$root/free-claim/.v30.1.4-free-claim-paused"
    printf '%s\n' '#!/bin/sh' 'exit 0' >"$root/free-claim/pool_daemon.sh"
    printf '%s\n' '#!/bin/sh' 'exit 0' >"$root/free-claim/pool_daemon.v30.1.4-original"
    chmod 0600 "$root/free-claim/.v30.1.4-free-claim-paused"
    chmod 0700 "$root/free-claim/pool_daemon.sh"
    chmod 0600 "$root/free-claim/pool_daemon.v30.1.4-original"
}

make_runtime()
{
    local path=$1 root=$2
    local marker wrapper worker
    marker=$(shasum -a 256 "$root/free-claim/.v30.1.4-free-claim-paused" | awk '{print $1}')
    wrapper=$(shasum -a 256 "$root/free-claim/pool_daemon.sh" | awk '{print $1}')
    worker=$(shasum -a 256 "$root/free-claim/pool_daemon.v30.1.4-original" | awk '{print $1}')
    jq -n --arg root "$root" --arg marker "$marker" --arg wrapper "$wrapper" --arg worker "$worker" \
      --arg image_ref "qqblackcoin/blackcoin-v4-gui@sha256:$(printf 'c%.0s' {1..64})" \
      --arg image_id "sha256:$(printf 'd%.0s' {1..64})" '
      {schema:2,kind:"node30-installed-v30.1.4-runtime-contract",
       recovery_contract:"installed-v30.1.4-node30-retained-claim-recovery/v2",
       source_commit:"13262151077cce3f72d07d17dc7725b2b6a8e1ab",
       source_tree:"a6f7757c34b70fab841905765462d6769112d049",
       source_signer_fingerprint:"SHA256:jAkpBudDw+ntWHSUx3e1KY+czAFjnlaPxQtRFtptL70",
       network_version:300104,subversion:"/Blackcoin:30.1.4/",
       compose_project:"blackcoin30",image_ref:$image_ref,image_id:$image_id,
       cli_path:"/usr/local/bin/blackcoin-cli",cli_sha256:("a"*64),
       daemon_path:"/usr/local/bin/blackcoind",daemon_sha256:("b"*64),
       datadir:"/home/blackcoin/.blackcoin",transport_sha256:("1"*64),
       global_lock_paths:[$root+"/locks/rollout",$root+"/locks/endpoint",
         $root+"/locks/cutover",$root+"/locks/pow",$root+"/locks/wallet",
         $root+"/locks/pause",$root+"/locks/pool",$root+"/locks/recovery"],
       node_lock_path:($root+"/locks/node30"),
       node:{node:30,service:"node30",container:"blackcoin-v4-gui-30",wallet:""},
       pause_marker:($root+"/free-claim/.v30.1.4-free-claim-paused"),
       pause_marker_sha256:$marker,pause_wrapper:($root+"/free-claim/pool_daemon.sh"),
       pause_wrapper_sha256:$wrapper,
       original_worker:($root+"/free-claim/pool_daemon.v30.1.4-original"),
       original_worker_sha256:$worker}
    ' >"$path"
    chmod 0600 "$path"
}

make_a_authority()
{
    local run=$1 path=$2 audit_sha
    audit_sha=$(awk '{print $1}' "$run/audit.json.sha256")
    jq --arg audit "$audit_sha" '.required_phase_a_authority|.audit_receipt_sha256=$audit' "$run/audit.json" >"$path"
    chmod 0600 "$path"
}

make_b_authority()
{
    local run=$1 path=$2 preview_sha
    preview_sha=$(awk '{print $1}' "$run/phase-b-preview.json.sha256")
    jq --arg preview "$preview_sha" '.required_phase_b_authority|.signed_byte_preview_sha256=$preview' "$run/phase-b-preview.json" >"$path"
    chmod 0600 "$path"
}

prepare_phase_a()
{
    local root=$1
    mkdir -m 0700 "$root" "$root/state"
    make_artifacts "$root"
    make_runtime "$root/runtime.json" "$root"
    export FLEET31_FIXTURE="$root/state" FLEET31_SCENARIO=happy
    "$TOOL" audit --runtime-manifest "$root/runtime.json" --run-dir "$root/run" >"$root/audit.out"
    make_a_authority "$root/run" "$root/a.json"
    local a_sha
    a_sha=$(shasum -a 256 "$root/a.json" | awk '{print $1}')
    "$TOOL" phase-a --run-dir "$root/run" --authority "$root/a.json" --authority-sha256 "$a_sha" >"$root/a.out"
}

prepare_phase_b()
{
    local root=$1
    prepare_phase_a "$root"
    export FLEET31_FIXTURE="$root/state" FLEET31_SCENARIO=happy
    "$TOOL" phase-b-preview --run-dir "$root/run" >"$root/b-preview.out"
    make_b_authority "$root/run" "$root/b.json"
}

export FLEET31_TEST_TRANSPORT="$MOCK"

/usr/bin/python3 -m py_compile "$TOOL" "$MOCK" || fail 'Python compilation failed'
ok
if grep -Eq 'commitshadowpowclaimresolution|sendrawtransaction|abandontransaction|bumpfee|setpowmining|walletpassphrase|pool_daemon[.]v30[.]1[.]4-original.*\(' "$TOOL"; then
    fail 'forbidden mutation/worker surface is present'
fi
ok
grep -Fq '"action": "sign_only"' "$TOOL" || fail 'exact Phase-A action absent'
ok
grep -Fq '"action": "commit_and_broadcast"' "$TOOL" || fail 'exact Phase-B action absent'
ok

HAPPY="$FIX/happy"
mkdir -m 0700 "$HAPPY" "$HAPPY/state"
make_artifacts "$HAPPY"
make_runtime "$HAPPY/runtime.json" "$HAPPY"
export FLEET31_FIXTURE="$HAPPY/state" FLEET31_SCENARIO=happy
"$TOOL" audit --runtime-manifest "$HAPPY/runtime.json" --run-dir "$HAPPY/run" >"$HAPPY/audit.out"
assert_jq '.result=="READY_FOR_SEPARATE_PHASE_A_AUTHORITY" and .node==30 and
  .schema==2 and .contract=="installed-v30.1.4-node30-retained-claim-recovery/v2" and
  .role=="free_claim" and .ordinary_pow_must_remain_disabled==true and
  .node_state.role.ordinary_pow.enabled==false and .node_state.role.pos.staking==true and
  .node_state.status=="ready" and .node_state.component.fee=="0.00019100" and
  .prior_readonly_receipt_sha256=="ca084d6d76fb67532fd65ff8b44943bc3a8c12f589708a11872417223066eec9" and
  .required_phase_a_authority.user_order_sha256=="0252ebcc3dc2ca8a20e8b9708738c30f9c32f6b0dea213bb8937467b2dab2dff"' "$HAPPY/run/audit.json"
assert_eq "$(stat -f '%Lp' "$HAPPY/run/audit.json" 2>/dev/null || stat -c '%a' "$HAPPY/run/audit.json")" 600
if grep -Fq -- '-rpcwallet=' "$HAPPY/state/transport.log"; then fail 'empty wallet selector was emitted'; fi
ok

make_a_authority "$HAPPY/run" "$HAPPY/a-authority.json"
A_SHA=$(shasum -a 256 "$HAPPY/a-authority.json" | awk '{print $1}')
jq '.fee_cap_blk="0.00019200"' "$HAPPY/a-authority.json" >"$HAPPY/bad-cap.json"; chmod 0600 "$HAPPY/bad-cap.json"
assert_fails 'wrong Phase-A cap' "$TOOL" phase-a --run-dir "$HAPPY/run" --authority "$HAPPY/bad-cap.json" --authority-sha256 "$(shasum -a 256 "$HAPPY/bad-cap.json"|awk '{print $1}')"
jq '.effective_user_order="do something else"' "$HAPPY/a-authority.json" >"$HAPPY/bad-order.json"; chmod 0600 "$HAPPY/bad-order.json"
assert_fails 'wrong user order' "$TOOL" phase-a --run-dir "$HAPPY/run" --authority "$HAPPY/bad-order.json" --authority-sha256 "$(shasum -a 256 "$HAPPY/bad-order.json"|awk '{print $1}')"
cp "$HAPPY/a-authority.json" "$HAPPY/world.json"; chmod 0644 "$HAPPY/world.json"
assert_fails 'world-readable Phase-A authority' "$TOOL" phase-a --run-dir "$HAPPY/run" --authority "$HAPPY/world.json" --authority-sha256 "$A_SHA"

MARKER_BEFORE=$(shasum -a 256 "$HAPPY/free-claim/.v30.1.4-free-claim-paused"|awk '{print $1}')
"$TOOL" phase-a --run-dir "$HAPPY/run" --authority "$HAPPY/a-authority.json" --authority-sha256 "$A_SHA" >"$HAPPY/a.out"
assert_jq '.result=="SIGNED_WITHOUT_RELAY_AUTHORITY" and .relay_or_broadcast_authorized==false and
  .node_result.status=="SIGNED_AND_PERSISTED" and .node_result.fee_blk=="0.00019100" and
  .node_result.relay_authority_granted==0 and .node_result.broadcast==0 and
  .node_result.role_after.ordinary_pow.enabled==false and .node_result.role_after.pos.staking==true and
  .node_result.free_claim_after.pause_preserved==true' "$HAPPY/run/phase-a.json"
assert_jq '.published_before_post_call_reads==true and .rpc_action=="sign_only" and
  .rpc_response.success==true and .rpc_response.relay_authority_granted==0' "$HAPPY/run/phase-a-ack-node30.json"
assert_eq "$(jq -r .node_state.component.classification "$HAPPY/run/audit.json")" current_branch_ineligible
assert_eq "$(jq -r .node_result.component.classification "$HAPPY/run/phase-a.json")" resolution_pending
[[ "$(jq -r .node_state.component.component_fingerprint "$HAPPY/run/audit.json")" != \
   "$(jq -r .node_result.component.component_fingerprint "$HAPPY/run/phase-a.json")" ]] || fail 'tip-relative component fingerprint did not change in fixture'
ok
assert_eq "$(grep -c 'sign_only' "$HAPPY/state/transport.log")" 1
assert_eq "$(grep -c 'commit_and_broadcast' "$HAPPY/state/transport.log" || true)" 0
assert_eq "$(shasum -a 256 "$HAPPY/free-claim/.v30.1.4-free-claim-paused"|awk '{print $1}')" "$MARKER_BEFORE"
assert_fails 'Phase-A replay' "$TOOL" phase-a --run-dir "$HAPPY/run" --authority "$HAPPY/a-authority.json" --authority-sha256 "$A_SHA"
assert_eq "$(grep -c 'sign_only' "$HAPPY/state/transport.log")" 1

"$TOOL" phase-b-preview --run-dir "$HAPPY/run" >"$HAPPY/b-preview.out"
assert_jq '.result=="READY_FOR_SEPARATE_PHASE_B_AUTHORITY" and
  (.signed_evidence.identity.resolution_txid|test("^[0-9a-f]{64}$")) and
  (.signed_transaction_identity_sha256|test("^[0-9a-f]{64}$")) and
  .signed_evidence.fee_proof.computed_fee_blk=="0.00019100" and
  .signed_evidence.fee_proof.same_script==true and
  .signed_evidence.fee_proof.include_mempool==false and
  .signed_evidence.observation.durable_relay_authorized_metadata=="0" and
  .role_state.ordinary_pow.enabled==false and .free_claim.pause_preserved==true' "$HAPPY/run/phase-b-preview.json"
assert_eq "$(jq -r .signed_evidence.identity_sha256 "$HAPPY/run/phase-b-preview.json")" \
          "$(jq -r .node_result.signed_evidence.identity_sha256 "$HAPPY/run/phase-a.json")"
make_b_authority "$HAPPY/run" "$HAPPY/b-authority.json"
B_SHA=$(shasum -a 256 "$HAPPY/b-authority.json" | awk '{print $1}')
jq '.acknowledgements.broadcast_is_irreversible=false' "$HAPPY/b-authority.json" >"$HAPPY/bad-b.json"; chmod 0600 "$HAPPY/bad-b.json"
assert_fails 'Phase-B acknowledgement absent' "$TOOL" phase-b --run-dir "$HAPPY/run" --authority "$HAPPY/bad-b.json" --authority-sha256 "$(shasum -a 256 "$HAPPY/bad-b.json"|awk '{print $1}')"
assert_eq "$(grep -c 'commit_and_broadcast' "$HAPPY/state/transport.log" || true)" 0
"$TOOL" phase-b --run-dir "$HAPPY/run" --authority "$HAPPY/b-authority.json" --authority-sha256 "$B_SHA" >"$HAPPY/b.out"
assert_jq '.result=="EXACT_PLAN_ACKNOWLEDGED_AND_RELAYED" and
  .confirmation_or_free_claim_success_claimed==false and
  .node_result.acknowledged_total_fee=="0.00019100" and
  .node_result.status=="EXACT_PLAN_ACKNOWLEDGED_AND_RELAYED" and
  (.node_result.broadcast+.node_result.already_in_mempool)==1 and
  .node_result.post_call_state.signed_evidence.observation.durable_relay_authorized_metadata=="1" and
  .node_result.role_after.ordinary_pow.enabled==false and
  .node_result.free_claim_after.pause_preserved==true' "$HAPPY/run/phase-b.json"
assert_jq '.published_before_post_call_reads==true and .rpc_action=="commit_and_broadcast" and
  .rpc_response.success==true and .rpc_response.relay_authority_granted==1 and
  (.rpc_response.broadcast+.rpc_response.already_in_mempool)==1' "$HAPPY/run/phase-b-ack-node30.json"
assert_eq "$(grep -c 'commit_and_broadcast' "$HAPPY/state/transport.log")" 1
assert_eq "$(shasum -a 256 "$HAPPY/free-claim/.v30.1.4-free-claim-paused"|awk '{print $1}')" "$MARKER_BEFORE"
"$TOOL" reconcile-b --run-dir "$HAPPY/run" --authority "$HAPPY/b-authority.json" --authority-sha256 "$B_SHA" >"$HAPPY/reconcile-complete.out"
assert_eq "$(jq -r .result "$HAPPY/reconcile-complete.out")" EXACT_PLAN_ACKNOWLEDGED_AND_RELAYED
cp "$HAPPY/run/phase-b.json" "$HAPPY/phase-b.saved"
cp "$HAPPY/run/phase-b.json.sha256" "$HAPPY/phase-b.saved.sha256"
jq '.node_result.confirmation_claimed=true' "$HAPPY/run/phase-b.json" >"$HAPPY/run/phase-b.tmp"
mv "$HAPPY/run/phase-b.tmp" "$HAPPY/run/phase-b.json"
HAPPY_FINAL_SHA=$(shasum -a 256 "$HAPPY/run/phase-b.json"|awk '{print $1}')
printf '%s  phase-b.json\n' "$HAPPY_FINAL_SHA" >"$HAPPY/run/phase-b.json.sha256"
assert_fails 're-sealed incomplete Phase-B result chain' "$TOOL" reconcile-b --run-dir "$HAPPY/run" --authority "$HAPPY/b-authority.json" --authority-sha256 "$B_SHA"
mv "$HAPPY/phase-b.saved" "$HAPPY/run/phase-b.json"
mv "$HAPPY/phase-b.saved.sha256" "$HAPPY/run/phase-b.json.sha256"
assert_fails 'Phase-B replay' "$TOOL" phase-b --run-dir "$HAPPY/run" --authority "$HAPPY/b-authority.json" --authority-sha256 "$B_SHA"
assert_eq "$(grep -c 'commit_and_broadcast' "$HAPPY/state/transport.log")" 1

"$TOOL" monitor --run-dir "$HAPPY/run" >"$HAPPY/monitor-before.out"
MON_BEFORE=$(jq -r .receipt "$HAPPY/monitor-before.out")
assert_jq '.result=="NOT_YET_CONFIRMED" and .ordinary_pow_disabled.enabled==false and
  .free_claim.pause_preserved==true and .free_claim_worker_invoked==false' "$HAPPY/run/$MON_BEFORE"
jq '.confirmed=true|.confirmed_tx="resolution"' "$HAPPY/state/node30.json" >"$HAPPY/state/node30.tmp" && mv "$HAPPY/state/node30.tmp" "$HAPPY/state/node30.json"
"$TOOL" monitor --run-dir "$HAPPY/run" >"$HAPPY/monitor-after.out"
MON_AFTER=$(jq -r .receipt "$HAPPY/monitor-after.out")
assert_jq '.result=="RETAINED_CLAIM_CLEARED_ROLE_PRESERVED" and
  .anchor_spent_on_active_chain==true and .blocking_quarantined_claims==0 and
  .ordinary_pow_disabled.enabled==false and .pos.staking==true and
  .free_claim.pause_preserved==true and .pause_marker_removed==false' "$HAPPY/run/$MON_AFTER"

# Installed v30.1.4 returns exit 0 with exactly empty stdout for gettxout on a
# spent outpoint. Only that exact method/output pair maps to typed null.
export FLEET31_SCENARIO=empty-spent-gettxout
"$TOOL" monitor --run-dir "$HAPPY/run" >"$HAPPY/monitor-empty-gettxout.out"
MON_EMPTY=$(jq -r .receipt "$HAPPY/monitor-empty-gettxout.out")
assert_jq '.result=="RETAINED_CLAIM_CLEARED_ROLE_PRESERVED" and
  .anchor_spent_on_active_chain==true and
  (.confirmed_component_transactions|length)==1 and
  .receipt_compatibility.mode=="CURRENT_TOOL_RECEIPT_MONITOR"' "$HAPPY/run/$MON_EMPTY"
assert_eq "$(grep -c 'commit_and_broadcast' "$HAPPY/state/transport.log")" 1

# Monitor-only predecessor compatibility uses authentic 9b6ce9-generated
# receipts and requires the exact owner-only 801ffe6 product-test receipt.
PREDSRC="$FIX/predecessor-source"
PREDPKG="$PREDSRC/contrib/ops/v30.1.4-node30-retained-claim-recovery"
PREDBASE="$PREDSRC/contrib/ops/v30.1.4-fleet31-recovery"
mkdir -p "$PREDPKG/tests" "$PREDBASE"
/usr/bin/git -C "$ROOT/../../.." show 9b6ce967e581efcdeeeea1b8aee29c6146b9e9e5:contrib/ops/v30.1.4-node30-retained-claim-recovery/node30_recovery.py >"$PREDPKG/node30_recovery.py"
/usr/bin/git -C "$ROOT/../../.." show 9b6ce967e581efcdeeeea1b8aee29c6146b9e9e5:contrib/ops/v30.1.4-node30-retained-claim-recovery/tests/mock_transport.py >"$PREDPKG/tests/mock_transport.py"
/usr/bin/git -C "$ROOT/../../.." show 9b6ce967e581efcdeeeea1b8aee29c6146b9e9e5:contrib/ops/v30.1.4-fleet31-recovery/fleet31_recovery.py >"$PREDBASE/fleet31_recovery.py"
chmod 0700 "$PREDPKG/node30_recovery.py" "$PREDPKG/tests/mock_transport.py"
chmod 0600 "$PREDBASE/fleet31_recovery.py"
assert_eq "$(shasum -a 256 "$PREDPKG/node30_recovery.py"|awk '{print $1}')" 55b79cde81f6d00ff105c454b6106026dcae794aa60ef55f0c3b27016c8c3cd1
assert_eq "$(shasum -a 256 "$PREDPKG/tests/mock_transport.py"|awk '{print $1}')" bd9672a4518f9834011bbb80db4b28553be7d289bec110c939b314dcce7f91fc
assert_eq "$(shasum -a 256 "$PREDBASE/fleet31_recovery.py"|awk '{print $1}')" b97f239569be4d9bb8bdb43163c3ef25fa9f7bba276d2ace835d93264e0ff518

PRED="$FIX/predecessor-monitor"
mkdir -m 0700 "$PRED" "$PRED/state"
make_artifacts "$PRED"
make_runtime "$PRED/runtime.json" "$PRED"
export FLEET31_TEST_TRANSPORT="$PREDPKG/tests/mock_transport.py"
export FLEET31_FIXTURE="$PRED/state" FLEET31_SCENARIO=happy
"$PREDPKG/node30_recovery.py" audit --runtime-manifest "$PRED/runtime.json" --run-dir "$PRED/run" >/dev/null
make_a_authority "$PRED/run" "$PRED/a.json"
PRED_A_SHA=$(shasum -a 256 "$PRED/a.json"|awk '{print $1}')
"$PREDPKG/node30_recovery.py" phase-a --run-dir "$PRED/run" --authority "$PRED/a.json" --authority-sha256 "$PRED_A_SHA" >/dev/null
jq '.confirmed=true|.confirmed_tx="resolution"' "$PRED/state/node30.json" >"$PRED/state/node30.tmp" && mv "$PRED/state/node30.tmp" "$PRED/state/node30.json"

export FLEET31_TEST_TRANSPORT="$MOCK" FLEET31_SCENARIO=empty-spent-gettxout
/usr/bin/git -C "$ROOT/../../.." show 801ffe62929675725c1261c913683aa48ea2e4bd:contrib/ops/v30.1.4-node30-retained-claim-recovery/PRODUCT-TEST-RECEIPT.json >"$PRED/801ffe-product.json"
chmod 0600 "$PRED/801ffe-product.json"
assert_eq "$(shasum -a 256 "$PRED/801ffe-product.json"|awk '{print $1}')" 3dfe86f2eb0b539ab26655ed2edd12b74fceb7cf7c36a376926b7cf3ec7c7356
assert_fails 'predecessor monitor without exact product receipt' "$TOOL" monitor --run-dir "$PRED/run"
assert_fails 'predecessor monitor with wrong product receipt digest' "$TOOL" monitor --run-dir "$PRED/run" --predecessor-product-receipt "$PRED/801ffe-product.json" --predecessor-product-receipt-sha256 "$(printf '0%.0s' {1..64})"
"$TOOL" monitor --run-dir "$PRED/run" --predecessor-product-receipt "$PRED/801ffe-product.json" --predecessor-product-receipt-sha256 3dfe86f2eb0b539ab26655ed2edd12b74fceb7cf7c36a376926b7cf3ec7c7356 >"$PRED/monitor.out"
PRED_MON=$(jq -r .receipt "$PRED/monitor.out")
assert_jq '.result=="RETAINED_CLAIM_CLEARED_ROLE_PRESERVED" and
  .receipt_compatibility.mode=="READ_ONLY_EXACT_PREDECESSOR_RECEIPT_MONITOR" and
  .receipt_compatibility.predecessor_receipt_identity.commit=="9b6ce967e581efcdeeeea1b8aee29c6146b9e9e5" and
  .receipt_compatibility.compatibility_review_identity.commit=="801ffe62929675725c1261c913683aa48ea2e4bd" and
  .receipt_compatibility.compatibility_review_identity.product_test_receipt_sha256=="3dfe86f2eb0b539ab26655ed2edd12b74fceb7cf7c36a376926b7cf3ec7c7356" and
  .receipt_compatibility.mutation_authorized==false' "$PRED/run/$PRED_MON"
assert_fails 'predecessor receipts on non-monitor command' "$TOOL" phase-b-preview --run-dir "$PRED/run"
assert_eq "$(grep -c 'commit_and_broadcast' "$PRED/state/transport.log" || true)" 0

# A pause artifact drift fails before Docker/CLI contact.
DRIFT="$FIX/drift"; mkdir -m 0700 "$DRIFT" "$DRIFT/state"; make_artifacts "$DRIFT"; make_runtime "$DRIFT/runtime.json" "$DRIFT"
printf '%s\n' changed >"$DRIFT/free-claim/.v30.1.4-free-claim-paused"; chmod 0600 "$DRIFT/free-claim/.v30.1.4-free-claim-paused"
export FLEET31_FIXTURE="$DRIFT/state" FLEET31_SCENARIO=happy
assert_fails 'pause marker drift' "$TOOL" audit --runtime-manifest "$DRIFT/runtime.json" --run-dir "$DRIFT/run"
[[ ! -e "$DRIFT/state/transport.log" ]] || fail 'pause drift reached transport'
ok

# Fee drift fails read-only without a mutating RPC.
BADFEE="$FIX/badfee"; mkdir -m 0700 "$BADFEE" "$BADFEE/state"; make_artifacts "$BADFEE"; make_runtime "$BADFEE/runtime.json" "$BADFEE"
export FLEET31_FIXTURE="$BADFEE/state" FLEET31_SCENARIO=wrong-fee
assert_fails 'fee drift' "$TOOL" audit --runtime-manifest "$BADFEE/runtime.json" --run-dir "$BADFEE/run"
assert_eq "$(grep -c 'sign_only\|commit_and_broadcast' "$BADFEE/state/transport.log" || true)" 0

# Lost Phase-A response is reconciled from exact durable nonrelayable bytes and never retried.
LOSTA="$FIX/losta"; mkdir -m 0700 "$LOSTA" "$LOSTA/state"; make_artifacts "$LOSTA"; make_runtime "$LOSTA/runtime.json" "$LOSTA"
export FLEET31_FIXTURE="$LOSTA/state" FLEET31_SCENARIO=happy
"$TOOL" audit --runtime-manifest "$LOSTA/runtime.json" --run-dir "$LOSTA/run" >/dev/null
make_a_authority "$LOSTA/run" "$LOSTA/a.json"; LOSTA_SHA=$(shasum -a 256 "$LOSTA/a.json"|awk '{print $1}')
export FLEET31_SCENARIO=lost-sign-result
assert_fails 'lost Phase-A response' "$TOOL" phase-a --run-dir "$LOSTA/run" --authority "$LOSTA/a.json" --authority-sha256 "$LOSTA_SHA"
assert_eq "$(grep -c 'sign_only' "$LOSTA/state/transport.log")" 1
export FLEET31_SCENARIO=happy
"$TOOL" reconcile-a --run-dir "$LOSTA/run" --authority "$LOSTA/a.json" --authority-sha256 "$LOSTA_SHA" >"$LOSTA/reconcile.out"
assert_jq '.result=="SIGNED_AND_PERSISTED" and .mutation_performed==false' "$LOSTA/run/phase-a-reconcile.json"
assert_eq "$(grep -c 'sign_only' "$LOSTA/state/transport.log")" 1

# Lost Phase-B result produces observation-only evidence and the intent blocks retry.
LOSTB="$FIX/lostb"; cp -R "$LOSTA" "$LOSTB"; rm -f "$LOSTB/run/phase-a-reconcile.json"*; chmod 0700 "$LOSTB/run"
export FLEET31_FIXTURE="$LOSTB/state" FLEET31_SCENARIO=happy
"$TOOL" phase-b-preview --run-dir "$LOSTB/run" >/dev/null
make_b_authority "$LOSTB/run" "$LOSTB/b.json"; LOSTB_SHA=$(shasum -a 256 "$LOSTB/b.json"|awk '{print $1}')
export FLEET31_SCENARIO=lost-relay-result
assert_fails 'lost Phase-B response' "$TOOL" phase-b --run-dir "$LOSTB/run" --authority "$LOSTB/b.json" --authority-sha256 "$LOSTB_SHA"
assert_eq "$(grep -c 'commit_and_broadcast' "$LOSTB/state/transport.log")" 1
export FLEET31_SCENARIO=happy
"$TOOL" reconcile-b --run-dir "$LOSTB/run" --authority "$LOSTB/b.json" --authority-sha256 "$LOSTB_SHA" >"$LOSTB/reconcile.out"
LOSTB_RECON=$(jq -r .receipt "$LOSTB/reconcile.out")
assert_jq '.result=="OBSERVATION_ONLY_NOT_ADMISSIBLE_AS_PHASE_B_COMPLETION" and
  .observed_status=="EXACT_BYTES_RELAY_AUTHORIZED_BUT_ACKNOWLEDGED_PLAN_UNATTRIBUTABLE" and
  .never_retry_after_unmatched_phase_b_intent==true and .observation.relay_authorized==true' "$LOSTB/run/$LOSTB_RECON"
/usr/bin/python3 - "$LOSTB/state/transport.log" <<'PY' || fail 'Phase-B reconciliation read before serialization preview'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
cut = max(i for i, row in enumerate(rows) if "commit_and_broadcast" in json.dumps(row))
after = rows[cut + 1:]
preview = next(i for i, row in enumerate(after) if "resolveallshadowpowclaims" in row)
anchor = next(i for i, row in enumerate(after) if "gettxout" in row)
wallet = next(i for i, row in enumerate(after) if "listwallets" in row)
raise SystemExit(0 if preview < anchor and preview < wallet else 1)
PY
ok
assert_fails 'Phase-B blind retry' "$TOOL" phase-b --run-dir "$LOSTB/run" --authority "$LOSTB/b.json" --authority-sha256 "$LOSTB_SHA"
assert_eq "$(grep -c 'commit_and_broadcast' "$LOSTB/state/transport.log")" 1

# Independently computed fee and exact same-script proof reject every source of drift.
for scenario in wrong-anchor-value wrong-anchor-script wrong-output-script; do
    PROOF="$FIX/proof-$scenario"
    mkdir -m 0700 "$PROOF" "$PROOF/state"
    make_artifacts "$PROOF"
    make_runtime "$PROOF/runtime.json" "$PROOF"
    printf '%s\n' '{"status":"signed","confirmed":false}' >"$PROOF/state/node30.json"
    export FLEET31_FIXTURE="$PROOF/state" FLEET31_SCENARIO="$scenario"
    assert_fails "$scenario exact fee/script proof" "$TOOL" audit --runtime-manifest "$PROOF/runtime.json" --run-dir "$PROOF/run"
    assert_eq "$(grep -c 'sign_only\|commit_and_broadcast' "$PROOF/state/transport.log" || true)" 0
done

# Exact wallet inventory is checked before any financial mutation.
BADWALLET="$FIX/badwallet"
mkdir -m 0700 "$BADWALLET" "$BADWALLET/state"
make_artifacts "$BADWALLET"
make_runtime "$BADWALLET/runtime.json" "$BADWALLET"
export FLEET31_FIXTURE="$BADWALLET/state" FLEET31_SCENARIO=wrong-wallet-inventory
assert_fails 'wrong loaded-wallet inventory' "$TOOL" audit --runtime-manifest "$BADWALLET/runtime.json" --run-dir "$BADWALLET/run"
assert_eq "$(grep -c 'sign_only\|commit_and_broadcast' "$BADWALLET/state/transport.log" || true)" 0

# Empty stdout from every RPC other than gettxout remains a fatal transport
# violation and cannot reach either financial action.
EMPTYRPC="$FIX/empty-non-gettxout"
mkdir -m 0700 "$EMPTYRPC" "$EMPTYRPC/state"
make_artifacts "$EMPTYRPC"
make_runtime "$EMPTYRPC/runtime.json" "$EMPTYRPC"
export FLEET31_FIXTURE="$EMPTYRPC/state" FLEET31_SCENARIO=empty-getnetworkinfo
assert_fails 'empty non-gettxout RPC response' "$TOOL" audit --runtime-manifest "$EMPTYRPC/runtime.json" --run-dir "$EMPTYRPC/run"
assert_eq "$(grep -c 'sign_only\|commit_and_broadcast' "$EMPTYRPC/state/transport.log" || true)" 0

# A v1 or differently named runtime contract cannot drive the v2 controller.
OLDMANIFEST="$FIX/oldmanifest"
mkdir -m 0700 "$OLDMANIFEST" "$OLDMANIFEST/state"
make_artifacts "$OLDMANIFEST"
make_runtime "$OLDMANIFEST/runtime.json" "$OLDMANIFEST"
jq '.schema=1' "$OLDMANIFEST/runtime.json" >"$OLDMANIFEST/runtime.tmp" && mv "$OLDMANIFEST/runtime.tmp" "$OLDMANIFEST/runtime.json"
chmod 0600 "$OLDMANIFEST/runtime.json"
export FLEET31_FIXTURE="$OLDMANIFEST/state" FLEET31_SCENARIO=happy
assert_fails 'v1 runtime manifest at v2 boundary' "$TOOL" audit --runtime-manifest "$OLDMANIFEST/runtime.json" --run-dir "$OLDMANIFEST/run"
[[ ! -e "$OLDMANIFEST/state/transport.log" ]] || fail 'v1 runtime manifest reached transport'
ok

# A receipt securely published before its sidecar is crash-healed; a malformed
# existing sidecar is never replaced or trusted.
ORPHAN="$FIX/orphan"
prepare_phase_a "$ORPHAN"
ln "$ORPHAN/run/phase-a.json" "$ORPHAN/run/.phase-a.json.tmp.123.456"
ln "$ORPHAN/run/audit.json.sha256" "$ORPHAN/run/.audit.json.sha256.tmp.234.567"
rm "$ORPHAN/run/phase-a.json.sha256"
export FLEET31_FIXTURE="$ORPHAN/state" FLEET31_SCENARIO=happy
"$TOOL" phase-b-preview --run-dir "$ORPHAN/run" >"$ORPHAN/preview.out"
[[ -f "$ORPHAN/run/phase-a.json.sha256" ]] || fail 'missing Phase-A sidecar was not repaired'
ok
assert_eq "$(awk '{print $1}' "$ORPHAN/run/phase-a.json.sha256")" "$(shasum -a 256 "$ORPHAN/run/phase-a.json"|awk '{print $1}')"
[[ ! -e "$ORPHAN/run/.phase-a.json.tmp.123.456" &&
   ! -e "$ORPHAN/run/.audit.json.sha256.tmp.234.567" ]] || fail 'publisher hard links were not healed'
ok

BADLINK="$FIX/badlink"
prepare_phase_a "$BADLINK"
ln "$BADLINK/run/phase-a.json" "$BADLINK/run/not-a-publisher-temp"
export FLEET31_FIXTURE="$BADLINK/state" FLEET31_SCENARIO=happy
assert_fails 'unrecognized receipt hard link' "$TOOL" phase-b-preview --run-dir "$BADLINK/run"
assert_eq "$(grep -c 'commit_and_broadcast' "$BADLINK/state/transport.log" || true)" 0

BADSIDECAR="$FIX/badsidecar"
prepare_phase_a "$BADSIDECAR"
printf '%064d  phase-a.json\n' 0 >"$BADSIDECAR/run/phase-a.json.sha256"
export FLEET31_FIXTURE="$BADSIDECAR/state" FLEET31_SCENARIO=happy
assert_fails 'malformed existing receipt sidecar' "$TOOL" phase-b-preview --run-dir "$BADSIDECAR/run"
assert_eq "$(grep -c 'commit_and_broadcast' "$BADSIDECAR/state/transport.log" || true)" 0

# The exact RPC return is durable before every post-call read. A simulated
# crash at the first post-read retains the ACK; resume is read-only and heals
# an orphan ACK sidecar without issuing a second commit.
POSTREAD="$FIX/postread"
prepare_phase_b "$POSTREAD"
POSTREAD_B_SHA=$(shasum -a 256 "$POSTREAD/b.json"|awk '{print $1}')
export FLEET31_FIXTURE="$POSTREAD/state" FLEET31_SCENARIO=post-read-failure
assert_fails 'first post-call read failure' "$TOOL" phase-b --run-dir "$POSTREAD/run" --authority "$POSTREAD/b.json" --authority-sha256 "$POSTREAD_B_SHA"
assert_jq '.published_before_post_call_reads==true and .rpc_response.success==true and
  .rpc_response.relay_authority_granted==1' "$POSTREAD/run/phase-b-ack-node30.json"
assert_eq "$(grep -c 'commit_and_broadcast' "$POSTREAD/state/transport.log")" 1
rm "$POSTREAD/run/phase-b-ack-node30.json.sha256"
export FLEET31_SCENARIO=wrong-wallet-inventory
assert_fails 'resume with wrong exact wallet inventory' "$TOOL" phase-b --run-dir "$POSTREAD/run" --authority "$POSTREAD/b.json" --authority-sha256 "$POSTREAD_B_SHA"
assert_eq "$(grep -c 'commit_and_broadcast' "$POSTREAD/state/transport.log")" 1
export FLEET31_SCENARIO=happy
"$TOOL" phase-b --run-dir "$POSTREAD/run" --authority "$POSTREAD/b.json" --authority-sha256 "$POSTREAD_B_SHA" >"$POSTREAD/resume.out"
assert_jq '.result=="EXACT_PLAN_ACKNOWLEDGED_AND_RELAYED" and
  .node_result.rpc_ack_sha256 and .node_result.role_after.ordinary_pow.enabled==false' "$POSTREAD/run/phase-b.json"
[[ -f "$POSTREAD/run/phase-b-ack-node30.json.sha256" ]] || fail 'orphan Phase-B ACK sidecar was not repaired'
ok
assert_eq "$(grep -c 'commit_and_broadcast' "$POSTREAD/state/transport.log")" 1

# A structured stale result after durable authority is a precise pending state,
# never a retry. The same authority can only resume read-only, then reconcile a
# fast active-chain confirmation.
PARTIAL="$FIX/partial"
prepare_phase_b "$PARTIAL"
PARTIAL_B_SHA=$(shasum -a 256 "$PARTIAL/b.json"|awk '{print $1}')
export FLEET31_FIXTURE="$PARTIAL/state" FLEET31_SCENARIO=post-persist-stale
"$TOOL" phase-b --run-dir "$PARTIAL/run" --authority "$PARTIAL/b.json" --authority-sha256 "$PARTIAL_B_SHA" >"$PARTIAL/partial.out"
assert_jq '.rpc_response.success==false and .rpc_response.stale_plan==true and
  .rpc_response.durable_state_changed==true and .rpc_response.relay_authority_granted==1 and
  .rpc_response.broadcast==0' "$PARTIAL/run/phase-b-ack-node30.json"
[[ ! -e "$PARTIAL/run/phase-b.json" ]] || fail 'partial relay authority was mislabeled complete'
ok
assert_eq "$(grep -c 'commit_and_broadcast' "$PARTIAL/state/transport.log")" 1
export FLEET31_SCENARIO=happy
"$TOOL" phase-b --run-dir "$PARTIAL/run" --authority "$PARTIAL/b.json" --authority-sha256 "$PARTIAL_B_SHA" >"$PARTIAL/resume-pending.out"
assert_eq "$(jq -r .result "$PARTIAL/resume-pending.out")" EXACT_RELAY_AUTHORITY_PERSISTED_PENDING_RELAY
assert_eq "$(grep -c 'commit_and_broadcast' "$PARTIAL/state/transport.log")" 1
jq '.confirmed=true|.confirmed_tx="resolution"' "$PARTIAL/state/node30.json" >"$PARTIAL/state/node30.tmp" && mv "$PARTIAL/state/node30.tmp" "$PARTIAL/state/node30.json"
"$TOOL" reconcile-b --run-dir "$PARTIAL/run" --authority "$PARTIAL/b.json" --authority-sha256 "$PARTIAL_B_SHA" >"$PARTIAL/reconcile-confirmed.out"
assert_jq '.result=="EXACT_AUTHORIZED_COMPONENT_CONFIRMED_ON_ACTIVE_CHAIN" and
  .node_result.confirmation_claimed==true and .node_result.post_call_state.anchor_spent_on_active_chain==true and
  .node_result.role_after.ordinary_pow.enabled==false and .node_result.free_claim_after.pause_preserved==true' "$PARTIAL/run/phase-b.json"
assert_eq "$(grep -c 'commit_and_broadcast' "$PARTIAL/state/transport.log")" 1

# A confirmation racing the RPC response is reconciled without requiring the
# post-call recovery action to remain actionable.
FAST="$FIX/fast"
prepare_phase_b "$FAST"
FAST_B_SHA=$(shasum -a 256 "$FAST/b.json"|awk '{print $1}')
export FLEET31_FIXTURE="$FAST/state" FLEET31_SCENARIO=fast-confirm-after-ack
"$TOOL" phase-b --run-dir "$FAST/run" --authority "$FAST/b.json" --authority-sha256 "$FAST_B_SHA" >"$FAST/b.out"
assert_jq '.result=="EXACT_AUTHORIZED_COMPONENT_CONFIRMED_ON_ACTIVE_CHAIN" and
  .confirmation_or_free_claim_success_claimed==true and
  .node_result.post_call_state.blocking_quarantined_claims==0 and
  .node_result.role_after.pos.staking==true' "$FAST/run/phase-b.json"
assert_eq "$(grep -c 'commit_and_broadcast' "$FAST/state/transport.log")" 1

# If the original claim wins before Phase B, preview emits no spend authority.
ORIGINAL="$FIX/original"
prepare_phase_a "$ORIGINAL"
jq '.confirmed=true|.confirmed_tx="claim"' "$ORIGINAL/state/node30.json" >"$ORIGINAL/state/node30.tmp" && mv "$ORIGINAL/state/node30.tmp" "$ORIGINAL/state/node30.json"
export FLEET31_FIXTURE="$ORIGINAL/state" FLEET31_SCENARIO=happy
"$TOOL" phase-b-preview --run-dir "$ORIGINAL/run" >"$ORIGINAL/preview.out"
assert_jq '.result=="ALREADY_CLEARED_NO_PHASE_B_AUTHORITY" and
  .clearance.anchor_spent_on_active_chain==true and
  .clearance.blocking_quarantined_claims==0 and
  (.required_phase_b_authority|not)' "$ORIGINAL/run/phase-b-preview.json"
assert_eq "$(grep -c 'commit_and_broadcast' "$ORIGINAL/state/transport.log" || true)" 0

# A spent anchor is not clearance unless exactly one allowlisted component
# transaction decodes to the exact anchor input on the active chain.
FOREIGN="$FIX/foreign-spender"
prepare_phase_a "$FOREIGN"
jq '.confirmed=true|.confirmed_tx="claim"' "$FOREIGN/state/node30.json" >"$FOREIGN/state/node30.tmp" && mv "$FOREIGN/state/node30.tmp" "$FOREIGN/state/node30.json"
export FLEET31_FIXTURE="$FOREIGN/state" FLEET31_SCENARIO=wrong-confirmed-spender
assert_fails 'confirmed claim does not spend exact anchor' "$TOOL" phase-b-preview --run-dir "$FOREIGN/run"
assert_eq "$(grep -c 'commit_and_broadcast' "$FOREIGN/state/transport.log" || true)" 0

DOUBLE="$FIX/double-spender"
prepare_phase_a "$DOUBLE"
jq '.confirmed=true|del(.confirmed_tx)' "$DOUBLE/state/node30.json" >"$DOUBLE/state/node30.tmp" && mv "$DOUBLE/state/node30.tmp" "$DOUBLE/state/node30.json"
export FLEET31_FIXTURE="$DOUBLE/state" FLEET31_SCENARIO=happy
assert_fails 'multiple claimed active-chain component spenders' "$TOOL" phase-b-preview --run-dir "$DOUBLE/run"
assert_eq "$(grep -c 'commit_and_broadcast' "$DOUBLE/state/transport.log" || true)" 0

# Unrecognized post-persistence acknowledgements remain durably inspectable and
# permanently block a blind second RPC.
for scenario in structured-invalid-after-persist wrong-ack-hex wrong-ack-generation \
                wrong-full-counter-type wrong-full-error; do
    BADACK="$FIX/badack-$scenario"
    prepare_phase_b "$BADACK"
    BADACK_SHA=$(shasum -a 256 "$BADACK/b.json"|awk '{print $1}')
    export FLEET31_FIXTURE="$BADACK/state" FLEET31_SCENARIO="$scenario"
    assert_fails "$scenario acknowledgement" "$TOOL" phase-b --run-dir "$BADACK/run" --authority "$BADACK/b.json" --authority-sha256 "$BADACK_SHA"
    assert_jq '.published_before_post_call_reads==true and .rpc_response.durable_state_changed==true' "$BADACK/run/phase-b-ack-node30.json"
    assert_eq "$(grep -c 'commit_and_broadcast' "$BADACK/state/transport.log")" 1
    assert_fails "$scenario blind retry" "$TOOL" phase-b --run-dir "$BADACK/run" --authority "$BADACK/b.json" --authority-sha256 "$BADACK_SHA"
    assert_eq "$(grep -c 'commit_and_broadcast' "$BADACK/state/transport.log")" 1
done

# Sidecar-bound Phase-A bytes, preview bytes, and the separate authority are a
# single chain. Re-sealing a modified embedded result cannot preserve it.
CHAIN="$FIX/chain"
prepare_phase_b "$CHAIN"
CHAIN_B_SHA=$(shasum -a 256 "$CHAIN/b.json"|awk '{print $1}')
jq '.component.fee="0.00019000"' "$CHAIN/run/phase-a-node30.json" >"$CHAIN/run/phase-a-node30.tmp"
mv "$CHAIN/run/phase-a-node30.tmp" "$CHAIN/run/phase-a-node30.json"
CHAIN_ROW_SHA=$(shasum -a 256 "$CHAIN/run/phase-a-node30.json"|awk '{print $1}')
printf '%s  phase-a-node30.json\n' "$CHAIN_ROW_SHA" >"$CHAIN/run/phase-a-node30.json.sha256"
export FLEET31_FIXTURE="$CHAIN/state" FLEET31_SCENARIO=happy
assert_fails 'modified Phase-A result chain' "$TOOL" phase-b --run-dir "$CHAIN/run" --authority "$CHAIN/b.json" --authority-sha256 "$CHAIN_B_SHA"
assert_eq "$(grep -c 'commit_and_broadcast' "$CHAIN/state/transport.log" || true)" 0

# Owner-only canonical receipt directories and unique authority files are
# enforced on resume before any financial RPC.
SECURE="$FIX/secure"
prepare_phase_b "$SECURE"
SECURE_B_SHA=$(shasum -a 256 "$SECURE/b.json"|awk '{print $1}')
chmod 0755 "$SECURE/run"
export FLEET31_FIXTURE="$SECURE/state" FLEET31_SCENARIO=happy
assert_fails 'group-readable run directory' "$TOOL" phase-b --run-dir "$SECURE/run" --authority "$SECURE/b.json" --authority-sha256 "$SECURE_B_SHA"
chmod 0700 "$SECURE/run"
chmod 0644 "$SECURE/locks/rollout"
assert_fails 'insecure pre-existing mutation lock' "$TOOL" phase-b --run-dir "$SECURE/run" --authority "$SECURE/b.json" --authority-sha256 "$SECURE_B_SHA"
chmod 0600 "$SECURE/locks/rollout"
ln "$SECURE/b.json" "$SECURE/b-hardlink.json"
assert_fails 'hard-linked Phase-B authority' "$TOOL" phase-b --run-dir "$SECURE/run" --authority "$SECURE/b-hardlink.json" --authority-sha256 "$SECURE_B_SHA"
ln -s "$SECURE/b.json" "$SECURE/b-symlink.json"
assert_fails 'symlink Phase-B authority' "$TOOL" phase-b --run-dir "$SECURE/run" --authority "$SECURE/b-symlink.json" --authority-sha256 "$SECURE_B_SHA"
assert_eq "$(grep -c 'commit_and_broadcast' "$SECURE/state/transport.log" || true)" 0

git -C "$ROOT/../../.." diff --check -- contrib/ops/v30.1.4-node30-retained-claim-recovery >/dev/null || fail 'git diff --check failed'
ok
printf 'PASS: %d hostile node30 retained-claim recovery assertions\n' "$ASSERTIONS"
