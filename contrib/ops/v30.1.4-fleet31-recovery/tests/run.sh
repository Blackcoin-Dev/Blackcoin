#!/bin/bash -p
export LC_ALL=C
export TZ=UTC
set -Eeuo pipefail
umask 077
unset BASH_ENV ENV CDPATH GLOBIGNORE PYTHONPATH PYTHONHOME
PATH=/usr/bin:/bin
export PATH

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
TOOL="$ROOT/fleet31_recovery.py"
MOCK="$ROOT/tests/mock_transport.py"
FIX=$(mktemp -d /private/tmp/fleet31-recovery-test.XXXXXX)
trap 'chmod -R u+w "$FIX" 2>/dev/null || true; rm -rf "$FIX"' EXIT
ASSERTIONS=0

fail()
{
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

ok()
{
    ASSERTIONS=$((ASSERTIONS + 1))
}

assert_jq()
{
    local filter=$1 file=$2
    jq -e "$filter" "$file" >/dev/null || fail "jq assertion failed: $filter ($file)"
    ok
}

assert_eq()
{
    [[ "$1" == "$2" ]] || fail "expected [$2], got [$1]"
    ok
}

assert_fails()
{
    local label=$1
    shift
    if "$@" >"$FIX/fail.out" 2>"$FIX/fail.err"; then
        fail "$label unexpectedly succeeded"
    fi
    ok
}

make_runtime()
{
    local path=$1 lock_root=$2
    jq -n \
      --arg lock_root "$lock_root" \
      --arg image_ref "qqblackcoin/blackcoin-v4-gui@sha256:$(printf 'c%.0s' {1..64})" \
      --arg image_id "sha256:$(printf 'd%.0s' {1..64})" '
      {schema:1,kind:"fleet31-installed-v30.1.4-runtime-contract",
       source_commit:"13262151077cce3f72d07d17dc7725b2b6a8e1ab",
       source_tree:"a6f7757c34b70fab841905765462d6769112d049",
       source_signer_fingerprint:"SHA256:jAkpBudDw+ntWHSUx3e1KY+czAFjnlaPxQtRFtptL70",
       network_version:300104,subversion:"/Blackcoin:30.1.4/",
       compose_project:"blackcoin30",image_ref:$image_ref,image_id:$image_id,
       cli_path:"/usr/local/bin/blackcoin-cli",cli_sha256:("a"*64),
       daemon_path:"/usr/local/bin/blackcoind",daemon_sha256:("b"*64),
       datadir:"/home/blackcoin/.blackcoin",transport_sha256:("1"*64),
       global_lock_paths:[$lock_root+"/rollout.lock",$lock_root+"/wallet.lock",$lock_root+"/recovery.lock"],
       node_lock_template:($lock_root+"/node-{node:02d}.lock"),
       nodes:([range(1;30),31,32] | map({node:.,service:("node"+(tostring|if length==1 then "0"+. else . end)),
         container:(if . == 1 then "blackcoin-v4-gui" else "blackcoin-v4-gui-"+tostring end),wallet:""}))}
    ' >"$path"
    chmod 0600 "$path"
}

make_phase_a_authority()
{
    local run=$1 path=$2
    local audit_sha
    audit_sha=$(awk '{print $1}' "$run/audit.json.sha256")
    jq --arg audit "$audit_sha" \
      '.required_phase_a_authority | .audit_receipt_sha256=$audit' \
      "$run/audit.json" >"$path"
    chmod 0600 "$path"
}

export FLEET31_TEST_TRANSPORT="$MOCK"

# Static boundary: there is no targeted commit or generic transaction RPC,
# node30 is absent from the exact node set, and Phase B fails before transport.
assert_fails 'Python syntax' false
/usr/bin/python3 -m py_compile "$TOOL" "$MOCK" || fail 'Python compilation failed'
ok
if grep -Eq 'commitshadowpowclaimresolution|sendrawtransaction|abandontransaction|bumpfee|setpowmining|walletpassphrase' "$TOOL"; then
    fail 'forbidden mutation RPC text is present'
fi
ok
grep -Fq 'die("Phase B is hard-disabled in this Phase-A-only stage;' "$TOOL" || fail 'Phase-B blocker absent'
ok

# Happy audit and authority validation hostiles.
HAPPY="$FIX/happy"
mkdir -m 0700 "$HAPPY" "$HAPPY/state"
make_runtime "$HAPPY/runtime.json" "$HAPPY/locks"
export FLEET31_FIXTURE="$HAPPY/state"
export FLEET31_SCENARIO=happy
"$TOOL" audit --runtime-manifest "$HAPPY/runtime.json" --run-dir "$HAPPY/run" >"$HAPPY/audit.out"
assert_jq '.result == "READY_FOR_PHASE_A_AUTHORITY" and .node30_excluded == true and
  .node_set == ([range(1;30),31,32]) and (.nodes|length)==31 and
  all(.nodes[]; .status == "ready" and .component.fee == "0.00019100" and
    .plan.actionable_components == 1 and .plan.actions[0].status == "ready")' "$HAPPY/run/audit.json"
if grep -Fq -- '-rpcwallet=' "$HAPPY/state/transport.log"; then
    fail 'unnamed-wallet audit passed an explicit empty wallet selector'
fi
ok
assert_eq "$(stat -f '%Lp' "$HAPPY/run/audit.json" 2>/dev/null || stat -c '%a' "$HAPPY/run/audit.json")" 600
assert_eq "$(stat -f '%Lp' "$HAPPY/run/audit.json.sha256" 2>/dev/null || stat -c '%a' "$HAPPY/run/audit.json.sha256")" 600
make_phase_a_authority "$HAPPY/run" "$HAPPY/phase-a-authority.json"
AUTH_SHA=$(shasum -a 256 "$HAPPY/phase-a-authority.json" | awk '{print $1}')

jq '.aggregate_fee_cap_blk="0.00592200"' "$HAPPY/phase-a-authority.json" >"$HAPPY/bad-cap.json"
chmod 0600 "$HAPPY/bad-cap.json"
assert_fails 'wrong aggregate cap' "$TOOL" phase-a --run-dir "$HAPPY/run" \
  --authority "$HAPPY/bad-cap.json" --authority-sha256 "$(shasum -a 256 "$HAPPY/bad-cap.json" | awk '{print $1}')"
jq '.acknowledgements.no_relay_or_broadcast_authority_in_phase_a=false' \
  "$HAPPY/phase-a-authority.json" >"$HAPPY/bad-ack.json"
chmod 0600 "$HAPPY/bad-ack.json"
assert_fails 'missing no-relay acknowledgement' "$TOOL" phase-a --run-dir "$HAPPY/run" \
  --authority "$HAPPY/bad-ack.json" --authority-sha256 "$(shasum -a 256 "$HAPPY/bad-ack.json" | awk '{print $1}')"
cp "$HAPPY/phase-a-authority.json" "$HAPPY/world-authority.json"
chmod 0644 "$HAPPY/world-authority.json"
assert_fails 'world-readable authority' "$TOOL" phase-a --run-dir "$HAPPY/run" \
  --authority "$HAPPY/world-authority.json" --authority-sha256 "$AUTH_SHA"
assert_fails 'wrong authority digest' "$TOOL" phase-a --run-dir "$HAPPY/run" \
  --authority "$HAPPY/phase-a-authority.json" --authority-sha256 "$(printf '0%.0s' {1..64})"

# A fresh plan may rebind the installed tip-relative component fingerprint,
# but every stable component identity/economic field remains audit-bound.  The
# mutation result must in turn match the exact fresh fingerprint.
REBIND_BASE="$FIX/rebind-base"
mkdir -m 0700 "$REBIND_BASE" "$REBIND_BASE/state"
make_runtime "$REBIND_BASE/runtime.json" "$REBIND_BASE/locks"
export FLEET31_FIXTURE="$REBIND_BASE/state"
export FLEET31_SCENARIO=happy
"$TOOL" audit --runtime-manifest "$REBIND_BASE/runtime.json" --run-dir "$REBIND_BASE/run" >/dev/null
make_phase_a_authority "$REBIND_BASE/run" "$REBIND_BASE/authority.json"

REBIND="$FIX/rebind"
mkdir -m 0700 "$REBIND" "$REBIND/state"
cp -R "$REBIND_BASE/run" "$REBIND/run"
cp "$REBIND_BASE/authority.json" "$REBIND/authority.json"
chmod 0600 "$REBIND/authority.json"
jq -n --arg tip "$(printf '1%.0s' {1..64})" --arg work "$(printf '2%.0s' {1..64})" \
  '{status:"ready",claims_submitted:4,confirmed:false,current_tip:$tip,
    current_height:5991551,current_chainwork:$work}' >"$REBIND/state/node01.json"
chmod 0600 "$REBIND/state/node01.json"
export FLEET31_FIXTURE="$REBIND/state"
REBIND_AUTH_SHA=$(shasum -a 256 "$REBIND/authority.json" | awk '{print $1}')
"$TOOL" phase-a --run-dir "$REBIND/run" --authority "$REBIND/authority.json" \
  --authority-sha256 "$REBIND_AUTH_SHA" >/dev/null
assert_jq '(.nodes[]|select(.node==1)) as $n |
  ($n.audit_component_fingerprint != $n.fresh_component_fingerprint) and
  ($n.component.component_fingerprint == $n.fresh_component_fingerprint) and
  ($n.fresh_plan.tip == ("1"*64))' "$REBIND/run/phase-a.json"
assert_eq "$(grep -c 'sign_only' "$REBIND/state/transport.log")" 31

for FIELD in anchor generation claim fee output; do
  DRIFT="$FIX/drift-$FIELD"
  mkdir -m 0700 "$DRIFT" "$DRIFT/state"
  cp -R "$REBIND_BASE/run" "$DRIFT/run"
  cp "$REBIND_BASE/authority.json" "$DRIFT/authority.json"
  chmod 0600 "$DRIFT/authority.json"
  jq -n --arg field "$FIELD" \
    '{status:"ready",claims_submitted:4,confirmed:false,stable_component_drift:$field}' \
    >"$DRIFT/state/node01.json"
  chmod 0600 "$DRIFT/state/node01.json"
  export FLEET31_FIXTURE="$DRIFT/state"
  assert_fails "stable $FIELD drift" "$TOOL" phase-a --run-dir "$DRIFT/run" \
    --authority "$DRIFT/authority.json" \
    --authority-sha256 "$(shasum -a 256 "$DRIFT/authority.json" | awk '{print $1}')"
  assert_eq "$(grep -c 'sign_only' "$DRIFT/state/transport.log" || true)" 0
done

RESULT_DRIFT="$FIX/result-drift"
mkdir -m 0700 "$RESULT_DRIFT" "$RESULT_DRIFT/state"
cp -R "$REBIND_BASE/run" "$RESULT_DRIFT/run"
cp "$REBIND_BASE/authority.json" "$RESULT_DRIFT/authority.json"
chmod 0600 "$RESULT_DRIFT/authority.json"
export FLEET31_FIXTURE="$RESULT_DRIFT/state"
export FLEET31_SCENARIO=result-component-mismatch
assert_fails 'result differs from exact fresh component' "$TOOL" phase-a \
  --run-dir "$RESULT_DRIFT/run" --authority "$RESULT_DRIFT/authority.json" \
  --authority-sha256 "$(shasum -a 256 "$RESULT_DRIFT/authority.json" | awk '{print $1}')"
grep -Fq 'result component differs from the exact fresh plan' "$FIX/fail.err" ||
  fail 'fresh-result component mismatch did not reach the exact gate'
ok
assert_eq "$(grep -c 'sign_only' "$RESULT_DRIFT/state/transport.log")" 1

# Phase A signs exactly once per node and grants no relay/broadcast authority.
export FLEET31_FIXTURE="$HAPPY/state"
export FLEET31_SCENARIO=happy
BEFORE=$(wc -l <"$HAPPY/state/transport.log" | tr -d ' ')
"$TOOL" phase-a --run-dir "$HAPPY/run" --authority "$HAPPY/phase-a-authority.json" \
  --authority-sha256 "$AUTH_SHA" >"$HAPPY/phase-a.out"
AFTER=$(wc -l <"$HAPPY/state/transport.log" | tr -d ' ')
assert_jq '.result == "SIGNED_ALL_31_WITHOUT_RELAY_AUTHORITY" and
  .relay_or_broadcast_authorized == false and (.nodes|length)==31 and
  all(.nodes[]; .status == "SIGNED_AND_PERSISTED" and
    .fee_blk == "0.00019100" and .relay_authority_granted == 0 and .broadcast == 0 and
    (.signed_transaction.resolution_txid|test("^[0-9a-f]{64}$")) and
    (.signed_transaction.raw_hex_sha256|test("^[0-9a-f]{64}$")))' "$HAPPY/run/phase-a.json"
assert_eq "$(find "$HAPPY/run" -name 'phase-a-node*.json' | wc -l | tr -d ' ')" 31
assert_eq "$(find "$HAPPY/run" -name 'phase-a-intent-node*.json' | wc -l | tr -d ' ')" 31
assert_eq "$(grep -c 'sign_only' "$HAPPY/state/transport.log")" 31
assert_eq "$(grep -c 'commit_and_broadcast' "$HAPPY/state/transport.log" || true)" 0

# Re-execution cannot clobber the final receipt or sign again.
assert_fails 'Phase-A final receipt no-clobber' "$TOOL" phase-a --run-dir "$HAPPY/run" \
  --authority "$HAPPY/phase-a-authority.json" --authority-sha256 "$AUTH_SHA"
assert_eq "$(grep -c 'sign_only' "$HAPPY/state/transport.log")" 31

# Phase B is blocked before receipt parsing, locks, transport, or RPC.
LOG_BEFORE=$(shasum -a 256 "$HAPPY/state/transport.log" | awk '{print $1}')
assert_fails 'Phase-B hard blocker' "$TOOL" phase-b --run-dir "$HAPPY/run" \
  --authority /definitely/absent --authority-sha256 "$(printf '0%.0s' {1..64})"
grep -Fq 'Phase B is hard-disabled' "$FIX/fail.err" || fail 'Phase-B failure was not the hard blocker'
ok
assert_eq "$(shasum -a 256 "$HAPPY/state/transport.log" | awk '{print $1}')" "$LOG_BEFORE"

# Exact node-set contract rejects node30 before contacting transport.
BADNODE="$FIX/badnode"
mkdir -m 0700 "$BADNODE" "$BADNODE/state"
make_runtime "$BADNODE/runtime.json" "$BADNODE/locks"
jq '.nodes += [{node:30,service:"node30",container:"blackcoin-v4-gui-30",wallet:""}] | .nodes|=sort_by(.node)' \
  "$BADNODE/runtime.json" >"$BADNODE/runtime-bad.json"
chmod 0600 "$BADNODE/runtime-bad.json"
export FLEET31_FIXTURE="$BADNODE/state"
assert_fails 'node30 manifest exclusion' "$TOOL" audit --runtime-manifest "$BADNODE/runtime-bad.json" --run-dir "$BADNODE/run"
[[ ! -e "$BADNODE/state/transport.log" ]] || fail 'node30 hostile reached transport'
ok

# An unpadded single-digit Compose service is rejected before transport.
BADTOPO="$FIX/badtopo"
mkdir -m 0700 "$BADTOPO" "$BADTOPO/state"
make_runtime "$BADTOPO/runtime.json" "$BADTOPO/locks"
jq '(.nodes[]|select(.node==1).service)="node1"' "$BADTOPO/runtime.json" >"$BADTOPO/runtime-bad.json"
chmod 0600 "$BADTOPO/runtime-bad.json"
export FLEET31_FIXTURE="$BADTOPO/state"
assert_fails 'unpadded node01 service' "$TOOL" audit --runtime-manifest "$BADTOPO/runtime-bad.json" --run-dir "$BADTOPO/run"
[[ ! -e "$BADTOPO/state/transport.log" ]] || fail 'bad topology hostile reached transport'
ok

# A fee drift fails the read-only audit with no mutation.
BADFEE="$FIX/badfee"
mkdir -m 0700 "$BADFEE" "$BADFEE/state"
make_runtime "$BADFEE/runtime.json" "$BADFEE/locks"
export FLEET31_FIXTURE="$BADFEE/state"
export FLEET31_SCENARIO=wrong-fee
assert_fails 'per-node fee drift' "$TOOL" audit --runtime-manifest "$BADFEE/runtime.json" --run-dir "$BADFEE/run"
assert_eq "$(grep -c 'sign_only' "$BADFEE/state/transport.log" || true)" 0

# A normal block after the first stable preview retries the complete read-only
# envelope and succeeds on the next coherent cut. Continuous full-envelope
# drift exhausts the bounded retry without mutation.
TIPONCE="$FIX/tiponce"
mkdir -m 0700 "$TIPONCE" "$TIPONCE/state"
make_runtime "$TIPONCE/runtime.json" "$TIPONCE/locks"
export FLEET31_FIXTURE="$TIPONCE/state"
export FLEET31_SCENARIO=tip-advance-once
"$TOOL" audit --runtime-manifest "$TIPONCE/runtime.json" --run-dir "$TIPONCE/run" >/dev/null
assert_jq '.result=="READY_FOR_PHASE_A_AUTHORITY" and
  (.nodes[]|select(.node==1).chain.height)==5991551' "$TIPONCE/run/audit.json"
assert_eq "$(grep -c 'sign_only' "$TIPONCE/state/transport.log" || true)" 0

CHURN="$FIX/churn"
mkdir -m 0700 "$CHURN" "$CHURN/state"
make_runtime "$CHURN/runtime.json" "$CHURN/locks"
export FLEET31_FIXTURE="$CHURN/state"
export FLEET31_SCENARIO=tip-churn
assert_fails 'continuous full-envelope chain drift' "$TOOL" audit \
  --runtime-manifest "$CHURN/runtime.json" --run-dir "$CHURN/run"
grep -Fq 'kept advancing across five full read-only audit attempts' "$FIX/fail.err" ||
  fail 'continuous drift did not reach the bounded full-envelope exhaustion gate'
ok
assert_eq "$(grep -c 'sign_only' "$CHURN/state/transport.log" || true)" 0

# Lost sign response is never retried. Reconciliation observes the durable
# non-relayable draft, labels later nodes NO_PHASE_A_INTENT, and requires a new
# audit/authority for unfinished nodes.
LOST="$FIX/lost"
mkdir -m 0700 "$LOST" "$LOST/state"
make_runtime "$LOST/runtime.json" "$LOST/locks"
export FLEET31_FIXTURE="$LOST/state"
export FLEET31_SCENARIO=happy
"$TOOL" audit --runtime-manifest "$LOST/runtime.json" --run-dir "$LOST/run" >/dev/null
make_phase_a_authority "$LOST/run" "$LOST/authority.json"
LOST_AUTH_SHA=$(shasum -a 256 "$LOST/authority.json" | awk '{print $1}')
export FLEET31_SCENARIO=lost-sign-result
assert_fails 'lost Phase-A result' "$TOOL" phase-a --run-dir "$LOST/run" \
  --authority "$LOST/authority.json" --authority-sha256 "$LOST_AUTH_SHA"
assert_eq "$(grep -c 'sign_only' "$LOST/state/transport.log")" 9
export FLEET31_SCENARIO=happy
"$TOOL" reconcile-a --run-dir "$LOST/run" --authority "$LOST/authority.json" \
  --authority-sha256 "$LOST_AUTH_SHA" >"$LOST/reconcile.out"
assert_jq '.result == "PARTIAL_REQUIRES_NEW_AUDIT_AND_AUTHORITY" and
  ([.observations[]|select(.status=="SIGNED_AND_PERSISTED")]|length)==9 and
  ([.observations[]|select(.status=="NO_PHASE_A_INTENT")]|length)==22' "$LOST/run/phase-a-reconcile.json"
assert_eq "$(grep -c 'sign_only' "$LOST/state/transport.log")" 9
"$TOOL" phase-a --run-dir "$LOST/run" --authority "$LOST/authority.json" \
  --authority-sha256 "$LOST_AUTH_SHA" >"$LOST/resume.out"
assert_eq "$(grep -c 'sign_only' "$LOST/state/transport.log")" 31
assert_jq '.result == "SIGNED_ALL_31_WITHOUT_RELAY_AUTHORITY" and
  ([.nodes[]|select(.reconciled_after_missing_rpc_result == true)]|length)==1' "$LOST/run/phase-a.json"

git -C "$ROOT/../../.." diff --check -- contrib/ops/v30.1.4-fleet31-recovery >/dev/null || fail 'git diff --check failed'
ok
printf 'PASS: %d hostile fleet31 Phase-A recovery assertions\n' "$ASSERTIONS"
