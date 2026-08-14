#!/bin/bash -p
export LC_ALL=C TZ=UTC
set -Eeuo pipefail
umask 077
unset BASH_ENV ENV CDPATH GLOBIGNORE PYTHONPATH PYTHONHOME
PATH=/usr/bin:/bin
export PATH

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
TOOL=$ROOT/dynamic_recurrence_recovery.py
MOCK=$ROOT/tests/mock_transport.py
FIX=$(mktemp -d /private/tmp/dynamic-recurrence-test.XXXXXX)
trap 'chmod -R u+w "$FIX" 2>/dev/null || true; rm -rf "$FIX"' EXIT
ASSERTIONS=0

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { ASSERTIONS=$((ASSERTIONS + 1)); }
assert_fails() { local label=$1; shift; if "$@" >"$FIX/fail.out" 2>"$FIX/fail.err"; then fail "$label unexpectedly succeeded"; fi; ok; }
assert_eq() { [[ "$1" == "$2" ]] || fail "expected [$2], got [$1]"; ok; }
assert_jq() { local filter=$1 file=$2; jq -e "$filter" "$file" >/dev/null || fail "jq failed: $filter ($file)"; ok; }

make_runtime()
{
    local path=$1 locks=$2
    jq -n --arg locks "$locks" \
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
       global_lock_paths:[$locks+"/rollout.lock",$locks+"/wallet.lock",$locks+"/recovery.lock"],
       node_lock_template:($locks+"/node-{node:02d}.lock"),
       nodes:([range(1;30),31,32] | map({node:.,service:("node"+(tostring|if length==1 then "0"+. else . end)),
         container:(if .==1 then "blackcoin-v4-gui" else "blackcoin-v4-gui-"+tostring end),wallet:""}))}
    ' >"$path"
    chmod 0600 "$path"
}

set_blocked() { jq -cn --arg nodes "$2" '$nodes|split(",")|map(tonumber)' >"$1/blocked_nodes.json"; chmod 0600 "$1/blocked_nodes.json"; }
make_a_auth() { local run=$1 out=$2 sha; sha=$(awk '{print $1}' "$run/audit.json.sha256"); jq --arg sha "$sha" '.required_phase_a_authority|.audit_receipt_sha256=$sha' "$run/audit.json" >"$out"; chmod 0600 "$out"; }
make_b_auth() { local run=$1 out=$2 sha; sha=$(awk '{print $1}' "$run/phase-b-preview.json.sha256"); jq --arg sha "$sha" '.required_phase_b_authority|.signed_byte_preview_sha256=$sha' "$run/phase-b-preview.json" >"$out"; chmod 0600 "$out"; }
authority_sha() { shasum -a 256 "$1" | awk '{print $1}'; }

export FLEET31_TEST_TRANSPORT=$MOCK
export FLEET31_SCENARIO=happy

/usr/bin/python3 -m py_compile "$TOOL" "$MOCK" || fail 'Python syntax'
ok
[[ $(shasum -a 256 "$ROOT/../v30.1.4-fleet31-recovery/fleet31_recovery.py" | awk '{print $1}') == \
   eb529eb87ad1abc740345ddf5e06e0bbb8ae60b264b0d257fc95bad248a72680 ]] || fail 'base primitive hash'
ok
if grep -Eq 'commitshadowpowclaimresolution|sendrawtransaction|abandontransaction|bumpfee|setpowmining|walletpassphrase' "$TOOL"; then
    fail 'forbidden targeted/generic/wallet mutation RPC text present'
fi
ok
grep -Fq '"action": "sign_only"' "$TOOL" || fail 'sign_only surface absent'
grep -Fq '"action": "commit_and_broadcast"' "$TOOL" || fail 'bulk commit surface absent'
ok
grep -Fq 'FULL_NODE_SET = tuple([*range(1, 30), 31, 32])' "$TOOL" || fail 'node30 exclusion absent'
ok

H=$FIX/happy
mkdir -m 0700 "$H" "$H/state"
make_runtime "$H/runtime.json" "$H/locks"
set_blocked "$H/state" '5,28'
export FLEET31_FIXTURE=$H/state
"$TOOL" audit --runtime-manifest "$H/runtime.json" --run-dir "$H/run" >"$H/audit.out"
assert_jq '.result=="READY_FOR_PHASE_A_AUTHORITY" and
  .recurrence_result=="READY_FOR_EXACT_DYNAMIC_SUBSET_PHASE_A_AUTHORITY" and
  .audited_blocked_node_set==[5,28] and (.audited_clear_node_set|length)==29 and
  (.audited_clear_node_set|index(30))==null and .node_set==[5,28] and
  .aggregate_fee_cap_blk=="0.00038200" and .maximum_cycle_fee_blk==null and
  (.nodes|length)==2 and (.fleet_census|length)==31 and
  all(.nodes[];.classification=="EXACT_ONE_CLAIM_QUARANTINED" and .component.fee=="0.00019100") and
  all(.fleet_census[]|select(.classification=="CLEAR_POSITIVE_HASHRATE");
    .pow.hashrate>0 and .pow.blocking_quarantined_claims==0)' "$H/run/audit.json"
assert_jq '.required_phase_a_authority.maximum_cycle_fee_blk=="0.00038200" and
  .required_phase_a_authority.user_order_sha256=="0252ebcc3dc2ca8a20e8b9708738c30f9c32f6b0dea213bb8937467b2dab2dff" and
  .required_phase_a_authority.acknowledgements.self_cleared_nodes_are_excluded_from_fee_and_mutation_authority==true' "$H/run/audit.json"
assert_eq "$(grep -c 'sign_only' "$H/state/transport.log" || true)" 0
assert_eq "$(grep -c 'commit_and_broadcast' "$H/state/transport.log" || true)" 0
make_a_auth "$H/run" "$H/a.json"
A_SHA=$(authority_sha "$H/a.json")

jq '.aggregate_fee_cap_blk="0.00057300"' "$H/a.json" >"$H/bad-cap.json"
chmod 0600 "$H/bad-cap.json"
assert_fails 'aggregate cap drift' "$TOOL" phase-a --run-dir "$H/run" \
  --authority "$H/bad-cap.json" --authority-sha256 "$(authority_sha "$H/bad-cap.json")"
assert_eq "$(grep -c 'sign_only' "$H/state/transport.log" || true)" 0
jq '.audited_clear_node_set=[1]' "$H/a.json" >"$H/bad-set.json"
chmod 0600 "$H/bad-set.json"
assert_fails 'clear set drift' "$TOOL" phase-a --run-dir "$H/run" \
  --authority "$H/bad-set.json" --authority-sha256 "$(authority_sha "$H/bad-set.json")"
assert_eq "$(grep -c 'sign_only' "$H/state/transport.log" || true)" 0
jq '.recurrence_contract="wrong"' "$H/a.json" >"$H/bad-contract.json"
chmod 0600 "$H/bad-contract.json"
assert_fails 'recurrence contract drift' "$TOOL" phase-a --run-dir "$H/run" \
  --authority "$H/bad-contract.json" --authority-sha256 "$(authority_sha "$H/bad-contract.json")"
assert_eq "$(grep -c 'sign_only' "$H/state/transport.log" || true)" 0

"$TOOL" phase-a --run-dir "$H/run" --authority "$H/a.json" \
  --authority-sha256 "$A_SHA" >"$H/phase-a.out"
assert_jq '.result=="SIGNED_EXACT_AUDITED_SUBSET_WITHOUT_RELAY_AUTHORITY" and
  .audited_blocked_node_set==[5,28] and (.audited_clear_node_set|length)==29 and
  .relay_or_broadcast_authorized==false and .aggregate_fee_cap_blk=="0.00038200" and
  (.nodes|length)==2 and all(.nodes[];.status=="SIGNED_AND_PERSISTED" and
    .relay_authority_granted==0 and .broadcast==0 and .fee_blk=="0.00019100")' "$H/run/phase-a.json"
assert_eq "$(grep -c 'sign_only' "$H/state/transport.log")" 2
assert_eq "$(grep 'sign_only' "$H/state/transport.log" | jq -s '[.[]|.[1]]|unique|length')" 2
grep 'sign_only' "$H/state/transport.log" | grep -Eq 'blackcoin-v4-gui-(5|28)|[0-9a-f]{64}' || fail 'selected pinned transport absent'
ok
assert_eq "$(grep -c 'commit_and_broadcast' "$H/state/transport.log" || true)" 0

"$TOOL" phase-b-preview --run-dir "$H/run" >"$H/preview.out"
assert_jq '.result=="READY_FOR_SEPARATE_PHASE_B_AUTHORITY" and
  .audited_blocked_node_set==[5,28] and (.audited_clear_node_set|length)==29 and
  .wave_plan==[[5],[28]] and .recovery_relay_node_set==[5,28] and
  .maximum_recovery_fee_blk=="0.00038200" and (.nodes|length)==2 and
  all(.nodes[];.signed_evidence.fee_proof.computed_fee_blk=="0.00019100" and
    .signed_evidence.observation.durable_relay_authorized_metadata=="0")' "$H/run/phase-b-preview.json"
make_b_auth "$H/run" "$H/b.json"
B_SHA=$(authority_sha "$H/b.json")
jq '.all_regular_node_set=[30]' "$H/b.json" >"$H/bad-b-full-set.json"
chmod 0600 "$H/bad-b-full-set.json"
assert_fails 'Phase-B full-set drift' "$TOOL" phase-b --wave 1 --run-dir "$H/run" \
  --authority "$H/bad-b-full-set.json" --authority-sha256 "$(authority_sha "$H/bad-b-full-set.json")"
assert_eq "$(grep -c 'commit_and_broadcast' "$H/state/transport.log" || true)" 0
assert_fails 'out-of-order wave' "$TOOL" phase-b --wave 2 --run-dir "$H/run" \
  --authority "$H/b.json" --authority-sha256 "$B_SHA"
assert_eq "$(grep -c 'commit_and_broadcast' "$H/state/transport.log" || true)" 0
"$TOOL" phase-b --wave 1 --run-dir "$H/run" --authority "$H/b.json" \
  --authority-sha256 "$B_SHA" >"$H/w1.out"
"$TOOL" phase-b --wave 2 --run-dir "$H/run" --authority "$H/b.json" \
  --authority-sha256 "$B_SHA" >"$H/w2.out"
assert_jq '.result=="AUTHORIZED_RECOVERY_COMPLETE_EXACT_AUDITED_SUBSET" and
  .audited_blocked_node_set==[5,28] and (.audited_clear_node_set|length)==29 and
  .aggregate_fee_cap_blk=="0.00038200" and (.node_results|length)==2 and
  .confirmation_or_pow_success_claimed==false' "$H/run/phase-b.json"
assert_eq "$(grep -c 'commit_and_broadcast' "$H/state/transport.log")" 2

for n in 05 28; do
  jq '.confirmed=true|.claims_submitted=5|.pow_state="ready"' "$H/state/node$n.json" >"$H/state/.n"
  mv "$H/state/.n" "$H/state/node$n.json"; chmod 0600 "$H/state/node$n.json"
done
jq '.claims_submitted=6|.pow_state="claim_in_flight"' "$H/state/node05.json" >"$H/state/.n"
mv "$H/state/.n" "$H/state/node05.json"; chmod 0600 "$H/state/node05.json"
export FLEET31_SCENARIO=empty-gettxout-spent
"$TOOL" monitor --run-dir "$H/run" --samples 1 --interval 0 >"$H/monitor.out"
MON=$(jq -r .receipt "$H/monitor.out")
assert_jq '.result=="EXACT_AUDITED_SUBSET_POW_OPERATIONAL" and
  .required_nodes==2 and .operational_nodes==2 and .audited_blocked_node_set==[5,28] and
  .fleet_fresh_claims_submitted>0 and all(.nodes[];.operational==true)' "$H/run/$MON"

# One immutable binary handles a later, different recurrence set and computes
# a new exact cap. No source special case or previous-cycle authority is used.
N=$FIX/new-subset
mkdir -m 0700 "$N" "$N/state"
make_runtime "$N/runtime.json" "$N/locks"
set_blocked "$N/state" '14'
export FLEET31_FIXTURE=$N/state FLEET31_SCENARIO=happy
"$TOOL" audit --runtime-manifest "$N/runtime.json" --run-dir "$N/run" >/dev/null
assert_jq '.audited_blocked_node_set==[14] and .aggregate_fee_cap_blk=="0.00019100" and
  .required_phase_a_authority.maximum_cycle_fee_blk=="0.00019100"' "$N/run/audit.json"

# Any selected/clear-set change between audit and Phase A stops before the
# first durable intent or sign_only. Both a new recurrence and self-clear are
# covered against the same immutable audit/authority baseline.
C=$FIX/churn
mkdir -m 0700 "$C" "$C/state"
make_runtime "$C/runtime.json" "$C/locks"
set_blocked "$C/state" '5,28'
export FLEET31_FIXTURE=$C/state
"$TOOL" audit --runtime-manifest "$C/runtime.json" --run-dir "$C/run" >/dev/null
make_a_auth "$C/run" "$C/a.json"
for mode in new-blocker self-clear; do
  if [[ $mode == new-blocker ]]; then set_blocked "$C/state" '5,14,28'; else set_blocked "$C/state" '5'; fi
  assert_fails "$mode subset drift" "$TOOL" phase-a --run-dir "$C/run" \
    --authority "$C/a.json" --authority-sha256 "$(authority_sha "$C/a.json")"
  assert_eq "$(grep -c 'sign_only' "$C/state/transport.log" || true)" 0
  [[ ! -e $C/run/phase-a-intent-node05.json ]] || fail "$mode wrote an intent"
  ok
done

# Lost Phase-A result: an intent exists, blind retry is forbidden, and the
# read-only reconciliation path attributes only observed exact persisted bytes.
L=$FIX/lost-a
mkdir -m 0700 "$L" "$L/state"
make_runtime "$L/runtime.json" "$L/locks"
set_blocked "$L/state" '9'
export FLEET31_FIXTURE=$L/state FLEET31_SCENARIO=lost-sign-result-recovery-lag
"$TOOL" audit --runtime-manifest "$L/runtime.json" --run-dir "$L/run" >/dev/null
make_a_auth "$L/run" "$L/a.json"
L_SHA=$(authority_sha "$L/a.json")
assert_fails 'lost Phase-A result' "$TOOL" phase-a --run-dir "$L/run" \
  --authority "$L/a.json" --authority-sha256 "$L_SHA"
[[ -f $L/state/phase-a-recovery-lag-observed ]] || fail 'Phase-A lagged inventory cut was not exercised'
ok
[[ -e $L/run/phase-a-intent-node09.json && ! -e $L/run/phase-a-node09.json ]] || fail 'lost-result intent shape'
ok
assert_fails 'blind Phase-A retry' "$TOOL" phase-a --run-dir "$L/run" \
  --authority "$L/a.json" --authority-sha256 "$L_SHA"
export FLEET31_SCENARIO=happy
"$TOOL" reconcile-a --run-dir "$L/run" --authority "$L/a.json" \
  --authority-sha256 "$L_SHA" >"$L/reconcile.out"
assert_jq '.result=="SIGNED_EXACT_AUDITED_SUBSET_WITHOUT_RELAY_AUTHORITY" and
  .nodes[0].reconciled_after_missing_rpc_result==true and
  .nodes[0].acknowledged_plan_claimed==false and
  .nodes[0].mutation_performed=="unknown"' "$L/run/phase-a.json"
"$TOOL" phase-b-preview --run-dir "$L/run" >/dev/null
assert_jq '.audited_blocked_node_set==[9] and (.nodes|length)==1 and
  .nodes[0].signed_evidence.fee_proof.computed_fee_blk=="0.00019100"' "$L/run/phase-b-preview.json"

# A manifest or fixture that tries to place node30 in the selected set is
# rejected; no authority or mutation receipt can be produced.
X=$FIX/node30
mkdir -m 0700 "$X" "$X/state"
make_runtime "$X/runtime.json" "$X/locks"
printf '[30]\n' >"$X/state/blocked_nodes.json"; chmod 0600 "$X/state/blocked_nodes.json"
export FLEET31_FIXTURE=$X/state
assert_fails 'node30 selected' "$TOOL" audit --runtime-manifest "$X/runtime.json" --run-dir "$X/run"
assert_eq "$(grep -c 'sign_only' "$X/state/transport.log" || true)" 0

git -C "$(cd "$ROOT/../../.." && pwd -P)" diff --check || fail 'git diff check'
ok
printf 'PASS: %d hostile dynamic recurrence assertions\n' "$ASSERTIONS"
