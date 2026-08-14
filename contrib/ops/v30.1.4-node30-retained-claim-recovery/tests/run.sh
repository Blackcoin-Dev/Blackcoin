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
    mkdir -m 0700 -p "$root/free-claim"
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
      {schema:1,kind:"node30-installed-v30.1.4-runtime-contract",
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
assert_eq "$(grep -c 'sign_only' "$HAPPY/state/transport.log")" 1
assert_eq "$(grep -c 'commit_and_broadcast' "$HAPPY/state/transport.log" || true)" 0
assert_eq "$(shasum -a 256 "$HAPPY/free-claim/.v30.1.4-free-claim-paused"|awk '{print $1}')" "$MARKER_BEFORE"
assert_fails 'Phase-A replay' "$TOOL" phase-a --run-dir "$HAPPY/run" --authority "$HAPPY/a-authority.json" --authority-sha256 "$A_SHA"
assert_eq "$(grep -c 'sign_only' "$HAPPY/state/transport.log")" 1

"$TOOL" phase-b-preview --run-dir "$HAPPY/run" >"$HAPPY/b-preview.out"
assert_jq '.result=="READY_FOR_SEPARATE_PHASE_B_AUTHORITY" and
  (.signed_transaction.resolution_txid|test("^[0-9a-f]{64}$")) and
  (.signed_transaction_identity_sha256|test("^[0-9a-f]{64}$")) and
  .role.ordinary_pow.enabled==false and .free_claim.pause_preserved==true' "$HAPPY/run/phase-b-preview.json"
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
  .node_result.role_after.ordinary_pow.enabled==false and
  .node_result.free_claim_after.pause_preserved==true' "$HAPPY/run/phase-b.json"
assert_eq "$(grep -c 'commit_and_broadcast' "$HAPPY/state/transport.log")" 1
assert_eq "$(shasum -a 256 "$HAPPY/free-claim/.v30.1.4-free-claim-paused"|awk '{print $1}')" "$MARKER_BEFORE"
assert_fails 'Phase-B replay' "$TOOL" phase-b --run-dir "$HAPPY/run" --authority "$HAPPY/b-authority.json" --authority-sha256 "$B_SHA"
assert_eq "$(grep -c 'commit_and_broadcast' "$HAPPY/state/transport.log")" 1

"$TOOL" monitor --run-dir "$HAPPY/run" >"$HAPPY/monitor-before.out"
MON_BEFORE=$(jq -r .receipt "$HAPPY/monitor-before.out")
assert_jq '.result=="NOT_YET_CONFIRMED" and .ordinary_pow_disabled.enabled==false and
  .free_claim.pause_preserved==true and .free_claim_worker_invoked==false' "$HAPPY/run/$MON_BEFORE"
jq '.confirmed=true' "$HAPPY/state/node30.json" >"$HAPPY/state/node30.tmp" && mv "$HAPPY/state/node30.tmp" "$HAPPY/state/node30.json"
"$TOOL" monitor --run-dir "$HAPPY/run" >"$HAPPY/monitor-after.out"
MON_AFTER=$(jq -r .receipt "$HAPPY/monitor-after.out")
assert_jq '.result=="RETAINED_CLAIM_CLEARED_ROLE_PRESERVED" and
  .anchor_spent_on_active_chain==true and .blocking_quarantined_claims==0 and
  .ordinary_pow_disabled.enabled==false and .pos.staking==true and
  .free_claim.pause_preserved==true and .pause_marker_removed==false' "$HAPPY/run/$MON_AFTER"

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
assert_jq '.result=="OBSERVATION_ONLY_NOT_ADMISSIBLE_AS_PHASE_B_COMPLETION" and
  .observed_status=="EXACT_BYTES_RELAY_AUTHORIZED_BUT_ACKNOWLEDGED_PLAN_UNATTRIBUTABLE" and
  .never_retry_after_unmatched_phase_b_intent==true and .observation.durable_relay_authorized==true' "$LOSTB/run/phase-b-reconcile.json"
assert_fails 'Phase-B blind retry' "$TOOL" phase-b --run-dir "$LOSTB/run" --authority "$LOSTB/b.json" --authority-sha256 "$LOSTB_SHA"
assert_eq "$(grep -c 'commit_and_broadcast' "$LOSTB/state/transport.log")" 1

git -C "$ROOT/../../.." diff --check -- contrib/ops/v30.1.4-node30-retained-claim-recovery >/dev/null || fail 'git diff --check failed'
ok
printf 'PASS: %d hostile node30 retained-claim recovery assertions\n' "$ASSERTIONS"
