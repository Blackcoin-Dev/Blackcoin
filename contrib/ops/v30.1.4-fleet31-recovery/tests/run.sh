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

make_phase_b_authority()
{
    local run=$1 path=$2
    local preview_sha
    preview_sha=$(awk '{print $1}' "$run/phase-b-preview.json.sha256")
    jq --arg preview "$preview_sha" \
      '.required_phase_b_authority | .signed_byte_preview_sha256=$preview' \
      "$run/phase-b-preview.json" >"$path"
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
grep -Fq '"action": "commit_and_broadcast"' "$TOOL" || fail 'Phase-B exact bulk action absent'
ok

# The signed follow-up is structurally Phase-B-only in live mode. Historical
# Phase-A entrypoints stop before locks, transport construction, or RPC.
PRODGUARD="$FIX/phase-b-only-live-guard"
mkdir -m 0700 "$PRODGUARD"
assert_fails 'live audit disabled' /usr/bin/env -u FLEET31_TEST_TRANSPORT \
  "$TOOL" audit --runtime-manifest "$PRODGUARD/runtime.json" --run-dir "$PRODGUARD/run"
assert_fails 'live Phase-A disabled' /usr/bin/env -u FLEET31_TEST_TRANSPORT \
  "$TOOL" phase-a --run-dir "$PRODGUARD/run" --authority "$PRODGUARD/a.json" \
  --authority-sha256 "$(printf '0%.0s' {1..64})"
assert_fails 'live reconcile-A disabled' /usr/bin/env -u FLEET31_TEST_TRANSPORT \
  "$TOOL" reconcile-a --run-dir "$PRODGUARD/run" --authority "$PRODGUARD/a.json" \
  --authority-sha256 "$(printf '0%.0s' {1..64})"
[[ -z "$(find "$PRODGUARD" -mindepth 1 -print -quit)" ]] || fail 'Phase-B-only guard touched live paths'
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

# Preserve an exact pre-Phase-B signed-draft fixture for the lost-response
# reconciliation hostile without repeating Phase A.
LOSTB="$FIX/lostb"
mkdir -m 0700 "$LOSTB" "$LOSTB/state"
cp -R "$HAPPY/run" "$LOSTB/run"
cp "$HAPPY/state"/node*.json "$LOSTB/state/"
chmod 0700 "$LOSTB/run"
PREB="$FIX/preb"
mkdir -m 0700 "$PREB" "$PREB/state"
cp -R "$HAPPY/run" "$PREB/run"
cp "$HAPPY/state"/node*.json "$PREB/state/"
chmod 0700 "$PREB/run"

# Phase B requires a separate exact-signed-byte preview and authority, then
# processes only the exact bounded wave requested by each invocation.
"$TOOL" phase-b-preview --run-dir "$HAPPY/run" >"$HAPPY/phase-b-preview.out"
assert_jq '.result == "READY_FOR_SEPARATE_PHASE_B_AUTHORITY" and
  .wave_plan == [[16],[1,2,3,4],[5,6,7,8],[9,10,11,12],
    [13,14,15,17],[18,19,20,21],[22,23,24,25],[26,28,29],[31,32],[27]] and
  .deferred_node == 27 and
  (.nodes|length)==31 and all(.nodes[];
    .component.fee=="0.00019100" and
    .component.classification=="resolution_pending" and
    .signed_evidence.fee_proof.computed_fee_blk=="0.00019100" and
    (.signed_evidence.identity.resolution_txid|test("^[0-9a-f]{64}$")))' "$HAPPY/run/phase-b-preview.json"
make_phase_b_authority "$HAPPY/run" "$HAPPY/phase-b-authority.json"
PHASE_B_AUTH_SHA=$(shasum -a 256 "$HAPPY/phase-b-authority.json" | awk '{print $1}')
jq '.acknowledgements.broadcast_is_irreversible=false' "$HAPPY/phase-b-authority.json" >"$HAPPY/bad-phase-b.json"
chmod 0600 "$HAPPY/bad-phase-b.json"
assert_fails 'Phase-B missing irreversible acknowledgement' "$TOOL" phase-b --wave 1 \
  --run-dir "$HAPPY/run" --authority "$HAPPY/bad-phase-b.json" \
  --authority-sha256 "$(shasum -a 256 "$HAPPY/bad-phase-b.json" | awk '{print $1}')"
assert_fails 'Phase-B out-of-order wave' "$TOOL" phase-b --wave 2 --run-dir "$HAPPY/run" \
  --authority "$HAPPY/phase-b-authority.json" --authority-sha256 "$PHASE_B_AUTH_SHA"
assert_eq "$(grep -c 'commit_and_broadcast' "$HAPPY/state/transport.log" || true)" 0
for wave in $(seq 1 10); do
    "$TOOL" phase-b --wave "$wave" --run-dir "$HAPPY/run" \
      --authority "$HAPPY/phase-b-authority.json" --authority-sha256 "$PHASE_B_AUTH_SHA" \
      >"$HAPPY/phase-b-wave-$wave.out"
done
assert_jq '.result == "AUTHORIZED_RECOVERY_COMPLETE_ALL_31" and
  .confirmation_or_pow_success_claimed == false and (.node_results|length)==31' \
  "$HAPPY/run/phase-b.json"
assert_eq "$(find "$HAPPY/run" -name 'phase-b-node??.json' | wc -l | tr -d ' ')" 31
assert_eq "$(jq -s '[.[]|select(.status=="AUTHORIZED_RECOVERY_OUTCOME_COMPLETE" and
  .acknowledged_total_fee=="0.00019100")]|length' "$HAPPY/run"/phase-b-node??.json)" 31
assert_eq "$(find "$HAPPY/run" -name 'phase-b-wave-*.json' | wc -l | tr -d ' ')" 10
assert_eq "$(grep -c 'commit_and_broadcast' "$HAPPY/state/transport.log")" 31

# A healthy same-product container restart does not invalidate durable recovery
# evidence. The restarted process counter is evaluated from its reset epoch,
# not against the old process's audit counter.
for STATE_FILE in "$HAPPY/state"/node*.json; do
  jq '.confirmed=true | .original_confirmed=false | .restarted=true | .claims_submitted=1' \
    "$STATE_FILE" >"$HAPPY/state/.restart"
  mv "$HAPPY/state/.restart" "$STATE_FILE"
  chmod 0600 "$STATE_FILE"
done
"$TOOL" monitor --run-dir "$HAPPY/run" --samples 1 --interval 0 >"$HAPPY/monitor.out"
HAPPY_MONITOR=$(jq -r '.receipt' "$HAPPY/monitor.out")
assert_jq '.result=="ALL_31_POW_OPERATIONAL" and .operational_nodes==31 and
  all(.nodes[]; .runtime_transition.ephemeral_container_changed==true and
    .claims_baseline==0 and
    .claims_baseline_source=="positive_counter_since_restarted_process_epoch" and
    .claims_submitted==1 and .operational==true)' "$HAPPY/run/$HAPPY_MONITOR"

# A response lost after durable relay grant is observation-only on installed
# v30.1.4. It is never converted into an acknowledged-plan success receipt and
# the unmatched intent prevents a blind retry.
export FLEET31_FIXTURE="$LOSTB/state"
export FLEET31_SCENARIO=happy
"$TOOL" phase-b-preview --run-dir "$LOSTB/run" >/dev/null
make_phase_b_authority "$LOSTB/run" "$LOSTB/authority.json"
LOSTB_AUTH_SHA=$(shasum -a 256 "$LOSTB/authority.json" | awk '{print $1}')
export FLEET31_SCENARIO=lost-relay-result
assert_fails 'lost Phase-B result' "$TOOL" phase-b --wave 1 --run-dir "$LOSTB/run" \
  --authority "$LOSTB/authority.json" --authority-sha256 "$LOSTB_AUTH_SHA"
LOSTB_COMMITS=$(grep -c 'commit_and_broadcast' "$LOSTB/state/transport.log")
jq '.restarted=true | .claims_submitted=1' "$LOSTB/state/node16.json" >"$LOSTB/state/.node16"
mv "$LOSTB/state/.node16" "$LOSTB/state/node16.json"
chmod 0600 "$LOSTB/state/node16.json"
export FLEET31_SCENARIO=happy
"$TOOL" reconcile-b --run-dir "$LOSTB/run" --authority "$LOSTB/authority.json" \
  --authority-sha256 "$LOSTB_AUTH_SHA" >"$LOSTB/reconcile.out"
LOSTB_RECON=$(jq -r '.receipt' "$LOSTB/reconcile.out")
assert_jq '.result == "RECONCILED_WITHOUT_NEW_MUTATION" and
  .never_retry_after_observed_relay_authority == true and
  ([.observations[]|select(.node==16 and
    .status=="UNATTRIBUTABLE_ACKNOWLEDGEMENT_BUT_NEVER_RETRY" and
    .observation.status=="EXACT_BYTES_IN_MEMPOOL_WITH_DURABLE_AUTHORITY" and
    .observation.runtime_transition.ephemeral_container_changed==true)]|length)==1 and
  ([.observations[]|select(.status=="NO_PHASE_B_INTENT")]|length)==30' "$LOSTB/run/$LOSTB_RECON"
assert_fails 'unmatched Phase-B intent blocks retry' "$TOOL" phase-b --wave 1 \
  --run-dir "$LOSTB/run" --authority "$LOSTB/authority.json" --authority-sha256 "$LOSTB_AUTH_SHA"
assert_eq "$(grep -c 'commit_and_broadcast' "$LOSTB/state/transport.log")" "$LOSTB_COMMITS"

make_preb_case()
{
    local root=$1
    mkdir -m 0700 "$root" "$root/state"
    cp -R "$PREB/run" "$root/run"
    cp "$PREB/state"/node*.json "$root/state/"
    chmod 0700 "$root/run"
    export FLEET31_FIXTURE="$root/state"
    export FLEET31_SCENARIO=happy
    "$TOOL" phase-b-preview --run-dir "$root/run" >/dev/null
    make_phase_b_authority "$root/run" "$root/authority.json"
}

# Stable runtime identity drift and recreation during a cut both stop before an
# intent or mutation; only a completed same-product restart is admissible.
RUNTIMEBAD="$FIX/runtime-stable-drift"
make_preb_case "$RUNTIMEBAD"
RUNTIMEBAD_AUTH_SHA=$(shasum -a 256 "$RUNTIMEBAD/authority.json" | awk '{print $1}')
for RUNTIME_DRIFT in image binary service wallet; do
  jq --arg drift "$RUNTIME_DRIFT" '.runtime_drift=$drift' \
    "$RUNTIMEBAD/state/node16.json" >"$RUNTIMEBAD/state/.node16"
  mv "$RUNTIMEBAD/state/.node16" "$RUNTIMEBAD/state/node16.json"
  chmod 0600 "$RUNTIMEBAD/state/node16.json"
  assert_fails "stable runtime $RUNTIME_DRIFT drift" "$TOOL" phase-b --wave 1 \
    --run-dir "$RUNTIMEBAD/run" --authority "$RUNTIMEBAD/authority.json" \
    --authority-sha256 "$RUNTIMEBAD_AUTH_SHA"
done
assert_eq "$(grep -c 'commit_and_broadcast' "$RUNTIMEBAD/state/transport.log" || true)" 0

MIDCUT="$FIX/runtime-mid-cut-restart"
make_preb_case "$MIDCUT"
MIDCUT_AUTH_SHA=$(shasum -a 256 "$MIDCUT/authority.json" | awk '{print $1}')
export FLEET31_SCENARIO=restart-mid-cut
assert_fails 'runtime recreation during observation cut' "$TOOL" phase-b --wave 1 \
  --run-dir "$MIDCUT/run" --authority "$MIDCUT/authority.json" \
  --authority-sha256 "$MIDCUT_AUTH_SHA"
assert_eq "$(grep -c 'commit_and_broadcast' "$MIDCUT/state/transport.log" || true)" 0
export FLEET31_SCENARIO=happy

# A component already resolved on the active chain before Phase-B preview is
# authority-bound as terminal and receives no recovery relay/fee authority.
TERMINAL="$FIX/pre-preview-original-terminal"
mkdir -m 0700 "$TERMINAL" "$TERMINAL/state"
cp -R "$PREB/run" "$TERMINAL/run"
cp "$PREB/state"/node*.json "$TERMINAL/state/"
jq '.original_confirmed=true | .confirmed=true | .claims_submitted=5' \
  "$TERMINAL/state/node16.json" >"$TERMINAL/state/.node16"
mv "$TERMINAL/state/.node16" "$TERMINAL/state/node16.json"
chmod 0600 "$TERMINAL/state/node16.json"
export FLEET31_FIXTURE="$TERMINAL/state"
export FLEET31_SCENARIO=happy
"$TOOL" phase-b-preview --run-dir "$TERMINAL/run" >/dev/null
assert_jq '.terminal_node_set==[16] and
  (.recovery_relay_node_set|index(16)|not) and
  .maximum_recovery_fee_blk=="0.00573000" and
  (.nodes[]|select(.node==16).eligibility)=="ALREADY_RESOLVED_ON_ACTIVE_CHAIN" and
  (.nodes[]|select(.node==16).terminal_observation.status)==
    "AUTHORIZED_ORIGINAL_CLAIM_CONFIRMED_ON_ACTIVE_CHAIN"' \
  "$TERMINAL/run/phase-b-preview.json"
make_phase_b_authority "$TERMINAL/run" "$TERMINAL/authority.json"
TERMINAL_AUTH_SHA=$(shasum -a 256 "$TERMINAL/authority.json" | awk '{print $1}')
"$TOOL" phase-b --wave 1 --run-dir "$TERMINAL/run" \
  --authority "$TERMINAL/authority.json" --authority-sha256 "$TERMINAL_AUTH_SHA" >/dev/null
assert_jq '.status=="EXACT_COMPONENT_RESOLVED_ON_ACTIVE_CHAIN_WITHOUT_RPC_ACK" and
  .mutation_performed==false' "$TERMINAL/run/phase-b-node16.json"
assert_eq "$(grep -c 'commit_and_broadcast' "$TERMINAL/state/transport.log" || true)" 0

# A terminal row that reorgs before its wave cannot silently become relay
# authority under the old preview.
REORG="$FIX/pre-preview-terminal-reorg"
mkdir -m 0700 "$REORG" "$REORG/state"
cp -R "$TERMINAL/run" "$REORG/run"
rm -f "$REORG/run/phase-b-node16.json"* "$REORG/run/phase-b-wave-01.json"*
cp "$TERMINAL/state"/node*.json "$REORG/state/"
jq '.original_confirmed=false | .confirmed=false | .claims_submitted=5' \
  "$REORG/state/node16.json" >"$REORG/state/.node16"
mv "$REORG/state/.node16" "$REORG/state/node16.json"
chmod 0600 "$REORG/state/node16.json"
cp "$TERMINAL/authority.json" "$REORG/authority.json"
chmod 0600 "$REORG/authority.json"
export FLEET31_FIXTURE="$REORG/state"
assert_fails 'authority-bound terminal reorg' "$TOOL" phase-b --wave 1 \
  --run-dir "$REORG/run" --authority "$REORG/authority.json" \
  --authority-sha256 "$TERMINAL_AUTH_SHA"
assert_eq "$(grep -c 'commit_and_broadcast' "$REORG/state/transport.log" || true)" 0

# The exact signed resolution itself may also win before preview.
RESTERM="$FIX/pre-preview-resolution-terminal"
mkdir -m 0700 "$RESTERM" "$RESTERM/state"
cp -R "$PREB/run" "$RESTERM/run"
cp "$PREB/state"/node*.json "$RESTERM/state/"
jq '.confirmed=true | .original_confirmed=false | .claims_submitted=5' \
  "$RESTERM/state/node16.json" >"$RESTERM/state/.node16"
mv "$RESTERM/state/.node16" "$RESTERM/state/node16.json"
chmod 0600 "$RESTERM/state/node16.json"
export FLEET31_FIXTURE="$RESTERM/state"
export FLEET31_SCENARIO=happy
"$TOOL" phase-b-preview --run-dir "$RESTERM/run" >/dev/null
assert_jq '(.nodes[]|select(.node==16).terminal_observation.status)==
  "EXACT_BYTES_CONFIRMED_ON_ACTIVE_CHAIN" and .maximum_recovery_fee_blk=="0.00573000"' \
  "$RESTERM/run/phase-b-preview.json"

for BADTERM_SCENARIO in wrong-terminal-anchor inactive-terminal-header; do
  BADTERM="$FIX/$BADTERM_SCENARIO"
  mkdir -m 0700 "$BADTERM" "$BADTERM/state"
  cp -R "$PREB/run" "$BADTERM/run"
  cp "$PREB/state"/node*.json "$BADTERM/state/"
  jq '.original_confirmed=true | .confirmed=true | .claims_submitted=5' \
    "$BADTERM/state/node16.json" >"$BADTERM/state/.node16"
  mv "$BADTERM/state/.node16" "$BADTERM/state/node16.json"
  chmod 0600 "$BADTERM/state/node16.json"
  export FLEET31_FIXTURE="$BADTERM/state"
  export FLEET31_SCENARIO="$BADTERM_SCENARIO"
  assert_fails "$BADTERM_SCENARIO terminal proof" "$TOOL" phase-b-preview \
    --run-dir "$BADTERM/run"
  assert_eq "$(grep -c 'commit_and_broadcast' "$BADTERM/state/transport.log" || true)" 0
done

# Phase B independently validates the complete predecessor receipt chain before
# any live read or mutation. A self-hashed aggregate row cannot replace its
# exact per-node receipt.
STALEA="$FIX/stale-phase-a"
mkdir -m 0700 "$STALEA" "$STALEA/state"
cp -R "$PREB/run" "$STALEA/run"
cp "$PREB/state"/node*.json "$STALEA/state/"
jq '(.nodes[]|select(.node==1).fee_blk)="0.00019200"' "$STALEA/run/phase-a.json" \
  >"$STALEA/run/.phase-a-rewrite"
mv "$STALEA/run/.phase-a-rewrite" "$STALEA/run/phase-a.json"
chmod 0600 "$STALEA/run/phase-a.json"
STALEA_SHA=$(shasum -a 256 "$STALEA/run/phase-a.json" | awk '{print $1}')
printf '%s  phase-a.json\n' "$STALEA_SHA" >"$STALEA/run/phase-a.json.sha256"
chmod 0600 "$STALEA/run/phase-a.json.sha256"
export FLEET31_FIXTURE="$STALEA/state"
export FLEET31_SCENARIO=happy
assert_fails 'Phase-A embedded/node receipt mismatch' "$TOOL" phase-b-preview --run-dir "$STALEA/run"
[[ ! -e "$STALEA/state/transport.log" ]] || fail 'stale Phase-A hostile reached transport'
ok

# Independently compute the fee from the active-chain anchor and exact signed
# output; never trust Core's declared fee field alone.
BADANCHOR="$FIX/bad-anchor-proof"
mkdir -m 0700 "$BADANCHOR" "$BADANCHOR/state"
cp -R "$PREB/run" "$BADANCHOR/run"
cp "$PREB/state"/node*.json "$BADANCHOR/state/"
export FLEET31_FIXTURE="$BADANCHOR/state"
export FLEET31_SCENARIO=wrong-anchor-value
assert_fails 'independent signed fee proof' "$TOOL" phase-b-preview --run-dir "$BADANCHOR/run"
grep -Fq 'independently observed anchor value changed' "$FIX/fail.err" ||
  fail 'wrong anchor value did not reach independent fee proof'
ok
assert_eq "$(grep -c 'commit_and_broadcast' "$BADANCHOR/state/transport.log" || true)" 0

# A returned action must carry exactly the separately authorized raw bytes.
BADHEX="$FIX/bad-returned-hex"
make_preb_case "$BADHEX"
BADHEX_AUTH_SHA=$(shasum -a 256 "$BADHEX/authority.json" | awk '{print $1}')
export FLEET31_SCENARIO=wrong-returned-hex
assert_fails 'returned action raw-byte mismatch' "$TOOL" phase-b --wave 1 \
  --run-dir "$BADHEX/run" --authority "$BADHEX/authority.json" --authority-sha256 "$BADHEX_AUTH_SHA"
assert_jq '.status=="UNCLASSIFIED_RESPONSE_STOPPED" and .mutation_performed==true' \
  "$BADHEX/run/phase-b-ack-node16.json"
[[ ! -e "$BADHEX/run/phase-b-node16.json" ]] || fail 'raw-byte mismatch produced a final receipt'
ok

# A non-authoritative/unclassified acknowledgement is never retried, but a
# later exact active-chain resolution may close it observation-only.
jq '.confirmed=true | .claims_submitted=5' "$BADHEX/state/node16.json" >"$BADHEX/state/.node16"
mv "$BADHEX/state/.node16" "$BADHEX/state/node16.json"
chmod 0600 "$BADHEX/state/node16.json"
export FLEET31_SCENARIO=happy
"$TOOL" reconcile-b --run-dir "$BADHEX/run" --authority "$BADHEX/authority.json" \
  --authority-sha256 "$BADHEX_AUTH_SHA" >/dev/null
assert_jq '.status=="EXACT_COMPONENT_RESOLVED_ON_ACTIVE_CHAIN_WITHOUT_RPC_ACK" and
  .acknowledged_plan_claimed==false' "$BADHEX/run/phase-b-node16.json"

# An ambiguous Core response likewise remains nonretryable, yet can be closed
# after reload only by exact active-chain terminal proof.
AMBTERM="$FIX/ambiguous-terminal"
make_preb_case "$AMBTERM"
AMBTERM_AUTH_SHA=$(shasum -a 256 "$AMBTERM/authority.json" | awk '{print $1}')
export FLEET31_SCENARIO=ambiguous-relay-node16
assert_fails 'ambiguous Phase-B acknowledgement' "$TOOL" phase-b --wave 1 \
  --run-dir "$AMBTERM/run" --authority "$AMBTERM/authority.json" \
  --authority-sha256 "$AMBTERM_AUTH_SHA"
assert_jq '.status=="DURABLE_STATE_AMBIGUOUS"' "$AMBTERM/run/phase-b-ack-node16.json"
jq '.confirmed=true | .claims_submitted=5' "$AMBTERM/state/node16.json" >"$AMBTERM/state/.node16"
mv "$AMBTERM/state/.node16" "$AMBTERM/state/node16.json"
chmod 0600 "$AMBTERM/state/node16.json"
export FLEET31_SCENARIO=happy
"$TOOL" reconcile-b --run-dir "$AMBTERM/run" --authority "$AMBTERM/authority.json" \
  --authority-sha256 "$AMBTERM_AUTH_SHA" >/dev/null
assert_jq '.status=="EXACT_COMPONENT_RESOLVED_ON_ACTIVE_CHAIN_WITHOUT_RPC_ACK" and
  .acknowledged_plan_claimed==false' "$AMBTERM/run/phase-b-node16.json"

# A lost response before any durable relay grant receives a coherent
# post-recovery-mutex no-authority receipt and may use a fresh bounded attempt.
NOGRANT="$FIX/no-grant-retry"
make_preb_case "$NOGRANT"
NOGRANT_AUTH_SHA=$(shasum -a 256 "$NOGRANT/authority.json" | awk '{print $1}')
export FLEET31_SCENARIO=lost-before-relay-mutation
assert_fails 'lost response before durable grant' "$TOOL" phase-b --wave 1 \
  --run-dir "$NOGRANT/run" --authority "$NOGRANT/authority.json" --authority-sha256 "$NOGRANT_AUTH_SHA"
jq '.restarted=true | .claims_submitted=1' "$NOGRANT/state/node16.json" >"$NOGRANT/state/.node16"
mv "$NOGRANT/state/.node16" "$NOGRANT/state/node16.json"
chmod 0600 "$NOGRANT/state/node16.json"
export FLEET31_SCENARIO=happy
"$TOOL" reconcile-b --run-dir "$NOGRANT/run" --authority "$NOGRANT/authority.json" \
  --authority-sha256 "$NOGRANT_AUTH_SHA" >/dev/null
assert_jq '.status=="NO_RELAY_AUTHORITY_PROVEN_AFTER_UNMATCHED_RPC" and
  .observation.status=="NO_RELAY_AUTHORITY_OBSERVED" and
  .observation.runtime_transition.ephemeral_container_changed==true' \
  "$NOGRANT/run/phase-b-ack-node16.json"
"$TOOL" phase-b --wave 1 --run-dir "$NOGRANT/run" --authority "$NOGRANT/authority.json" \
  --authority-sha256 "$NOGRANT_AUTH_SHA" >/dev/null
assert_jq '.attempt==2 and .status=="AUTHORIZED_RECOVERY_OUTCOME_COMPLETE"' \
  "$NOGRANT/run/phase-b-node16.json"
assert_jq '.runtime_transition.ephemeral_container_changed==true' \
  "$NOGRANT/run/phase-b-intent-node16-attempt02.json"
assert_eq "$(grep -c 'commit_and_broadcast' "$NOGRANT/state/transport.log")" 2

# A structured post-persistence stop is durably acknowledged immediately,
# retains its exact error, and is never remutated.
PARTIAL="$FIX/post-persist-partial"
make_preb_case "$PARTIAL"
PARTIAL_AUTH_SHA=$(shasum -a 256 "$PARTIAL/authority.json" | awk '{print $1}')
export FLEET31_SCENARIO=post-persist-stale
assert_fails 'structured post-persistence stop' "$TOOL" phase-b --wave 1 \
  --run-dir "$PARTIAL/run" --authority "$PARTIAL/authority.json" --authority-sha256 "$PARTIAL_AUTH_SHA"
assert_jq '.status=="EXACT_PLAN_ACKNOWLEDGED_RELAY_AUTHORIZED_PENDING" and
  .relay_authority_granted==1 and .signed_and_persisted==0 and .broadcast==0 and
  .durable_state_changed==true and .durable_state_ambiguous==false and
  (.execution_error|length)>0' "$PARTIAL/run/phase-b-ack-node16.json"
PARTIAL_COMMITS=$(grep -c 'commit_and_broadcast' "$PARTIAL/state/transport.log")
assert_fails 'pending durable authority blocks remutation' "$TOOL" phase-b --wave 1 \
  --run-dir "$PARTIAL/run" --authority "$PARTIAL/authority.json" --authority-sha256 "$PARTIAL_AUTH_SHA"
assert_eq "$(grep -c 'commit_and_broadcast' "$PARTIAL/state/transport.log")" "$PARTIAL_COMMITS"
jq '.confirmed=true | .claims_submitted=5' "$PARTIAL/state/node16.json" >"$PARTIAL/state/.node16"
mv "$PARTIAL/state/.node16" "$PARTIAL/state/node16.json"
chmod 0600 "$PARTIAL/state/node16.json"
export FLEET31_SCENARIO=happy
"$TOOL" reconcile-b --run-dir "$PARTIAL/run" --authority "$PARTIAL/authority.json" \
  --authority-sha256 "$PARTIAL_AUTH_SHA" >/dev/null
PARTIAL_ACK_SHA=$(awk '{print $1}' "$PARTIAL/run/phase-b-ack-node16.json.sha256")
jq -e --arg ack "$PARTIAL_ACK_SHA" '.status=="AUTHORIZED_RECOVERY_OUTCOME_COMPLETE" and
  .ack_sha256==$ack and .acknowledged_plan_id!=null and
  .acknowledged_active_tip!=null and .acknowledged_active_height!=null and
  .acknowledged_wallet_generation!=null and
  .completion_evidence=="ACK_PLUS_READ_ONLY_OBSERVATION" and
  (has("installed_v30_1_4_ack_receipt_gap_preserved")|not)' \
  "$PARTIAL/run/phase-b-node16.json" >/dev/null || fail 'pending ACK resolution final lost ACK provenance'
ok

PARTIALWIN="$FIX/post-persist-original-winner"
make_preb_case "$PARTIALWIN"
PARTIALWIN_AUTH_SHA=$(shasum -a 256 "$PARTIALWIN/authority.json" | awk '{print $1}')
export FLEET31_SCENARIO=post-persist-stale
assert_fails 'post-persist pending before original winner' "$TOOL" phase-b --wave 1 \
  --run-dir "$PARTIALWIN/run" --authority "$PARTIALWIN/authority.json" \
  --authority-sha256 "$PARTIALWIN_AUTH_SHA"
jq '.original_confirmed=true | .confirmed=true | .claims_submitted=5' \
  "$PARTIALWIN/state/node16.json" >"$PARTIALWIN/state/.node16"
mv "$PARTIALWIN/state/.node16" "$PARTIALWIN/state/node16.json"
chmod 0600 "$PARTIALWIN/state/node16.json"
export FLEET31_SCENARIO=happy
"$TOOL" reconcile-b --run-dir "$PARTIALWIN/run" --authority "$PARTIALWIN/authority.json" \
  --authority-sha256 "$PARTIALWIN_AUTH_SHA" >/dev/null
PARTIALWIN_ACK_SHA=$(awk '{print $1}' "$PARTIALWIN/run/phase-b-ack-node16.json.sha256")
jq -e --arg ack "$PARTIALWIN_ACK_SHA" '.status=="AUTHORIZED_RECOVERY_OUTCOME_COMPLETE" and
  .ack_sha256==$ack and .acknowledged_plan_id!=null and
  .completion_evidence=="ACK_PLUS_READ_ONLY_OBSERVATION" and
  (has("installed_v30_1_4_ack_receipt_gap_preserved")|not)' \
  "$PARTIALWIN/run/phase-b-node16.json" >/dev/null || fail 'pending ACK original-winner final lost ACK provenance'
ok

# If an authorized original claim wins the anchor while an RPC response is
# lost, exact active-chain proof completes that node without claiming an RPC
# acknowledgement and allows its wave to continue.
WINNER="$FIX/original-winner"
make_preb_case "$WINNER"
WINNER_AUTH_SHA=$(shasum -a 256 "$WINNER/authority.json" | awk '{print $1}')
export FLEET31_SCENARIO=lost-original-claim-winner
assert_fails 'lost response with original-claim winner' "$TOOL" phase-b --wave 1 \
  --run-dir "$WINNER/run" --authority "$WINNER/authority.json" --authority-sha256 "$WINNER_AUTH_SHA"
jq '.restarted=true | .claims_submitted=1' "$WINNER/state/node16.json" >"$WINNER/state/.node16"
mv "$WINNER/state/.node16" "$WINNER/state/node16.json"
chmod 0600 "$WINNER/state/node16.json"
export FLEET31_SCENARIO=happy
"$TOOL" reconcile-b --run-dir "$WINNER/run" --authority "$WINNER/authority.json" \
  --authority-sha256 "$WINNER_AUTH_SHA" >/dev/null
assert_jq '.status=="EXACT_COMPONENT_RESOLVED_ON_ACTIVE_CHAIN_WITHOUT_RPC_ACK" and
  .acknowledged_plan_claimed==false and .installed_v30_1_4_ack_receipt_gap_preserved==true' \
  "$WINNER/run/phase-b-node16.json"
"$TOOL" phase-b --wave 1 --run-dir "$WINNER/run" --authority "$WINNER/authority.json" \
  --authority-sha256 "$WINNER_AUTH_SHA" >/dev/null
assert_jq '.status=="AUTHORIZED_RECOVERY_WAVE_COMPLETE" and
  .node_results[0].outcome=="EXACT_COMPONENT_RESOLVED_ON_ACTIVE_CHAIN_WITHOUT_RPC_ACK"' \
  "$WINNER/run/phase-b-wave-01.json"
assert_eq "$(grep -c 'commit_and_broadcast' "$WINNER/state/transport.log")" 1

# Crash recovery removes only the exact publisher temporary hard link and
# recreates only an absent self-hash sidecar; immutable receipt bytes survive.
HARDLINK_INODE=$(stat -f '%i' "$HAPPY/run/phase-b-wave-01.json" 2>/dev/null || stat -c '%i' "$HAPPY/run/phase-b-wave-01.json")
ln "$HAPPY/run/phase-b-wave-01.json" "$HAPPY/run/.phase-b-wave-01.json.tmp.999.999"
rm "$HAPPY/run/phase-b-wave-01.json.sha256"
export FLEET31_FIXTURE="$HAPPY/state"
export FLEET31_SCENARIO=happy
"$TOOL" phase-b --wave 1 --run-dir "$HAPPY/run" \
  --authority "$HAPPY/phase-b-authority.json" --authority-sha256 "$PHASE_B_AUTH_SHA" >/dev/null
assert_eq "$(stat -f '%i' "$HAPPY/run/phase-b-wave-01.json" 2>/dev/null || stat -c '%i' "$HAPPY/run/phase-b-wave-01.json")" "$HARDLINK_INODE"
assert_eq "$(stat -f '%l' "$HAPPY/run/phase-b-wave-01.json" 2>/dev/null || stat -c '%h' "$HAPPY/run/phase-b-wave-01.json")" 1
[[ ! -e "$HAPPY/run/.phase-b-wave-01.json.tmp.999.999" && -e "$HAPPY/run/phase-b-wave-01.json.sha256" ]] ||
  fail 'interrupted receipt/sidecar publication was not narrowly healed'
ok

export FLEET31_FIXTURE="$HAPPY/state"
export FLEET31_SCENARIO=happy
"$TOOL" phase-b --wave 1 --run-dir "$HAPPY/run" \
  --authority "$HAPPY/phase-b-authority.json" --authority-sha256 "$PHASE_B_AUTH_SHA"
assert_eq "$(grep -c 'commit_and_broadcast' "$HAPPY/state/transport.log")" 31

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
  ([.nodes[]|select(.reconciled_after_missing_rpc_result == true and
    .acknowledged_plan_claimed == false and
    .original_intent_plan.plan_id != .reconciliation_plan.plan_id and
    .intent_component.classification == "current_branch_ineligible" and
    .component.classification == "resolution_pending")]|length)==1' "$LOST/run/phase-a.json"
"$TOOL" phase-b-preview --run-dir "$LOST/run" >/dev/null
assert_jq '.result=="READY_FOR_SEPARATE_PHASE_B_AUTHORITY" and
  (.nodes[]|select(.node==9).eligibility)=="ACTIONABLE_REUSE_MANAGED"' \
  "$LOST/run/phase-b-preview.json"

git -C "$ROOT/../../.." diff --check -- contrib/ops/v30.1.4-fleet31-recovery >/dev/null || fail 'git diff --check failed'
ok
printf 'PASS: %d hostile fleet31 two-phase recovery assertions\n' "$ASSERTIONS"
