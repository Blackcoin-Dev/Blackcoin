#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C
umask 077

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
TOOL="$ROOT/node30_free_claim_one_shot.py"
MOCK="$ROOT/tests/mock_transport.py"
FIX_RAW=$(mktemp -d "${TMPDIR:-/tmp}/node30-free-claim-one-shot.XXXXXX")
FIX=$(CDPATH='' cd -- "$FIX_RAW" && pwd -P)
trap 'rm -rf -- "$FIX"' EXIT HUP INT TERM
COUNT=0

ok()
{
    COUNT=$((COUNT + 1))
}

assert_eq()
{
    [[ "$1" == "$2" ]] || {
        printf 'ASSERT_EQ failed: <%s> != <%s>\n' "$1" "$2" >&2
        exit 1
    }
    ok
}

assert_jq()
{
    jq -e "$1" "$2" >/dev/null || {
        printf 'ASSERT_JQ failed: %s in %s\n' "$1" "$2" >&2
        exit 1
    }
    ok
}

assert_fails()
{
    local label=$1
    shift
    if "$@" >"$FIX/fail.out" 2>"$FIX/fail.err"; then
        printf 'expected failure: %s\n' "$label" >&2
        exit 1
    fi
    ok
}

sha()
{
    shasum -a 256 "$1" | awk '{print $1}'
}

make_fixture()
{
    local root="$FIX/$1" gid
    gid=$(id -g)
    mkdir -m 0700 "$root" "$root/state" "$root/free-claim" "$root/free-claim/queue" \
        "$root/free-claim/done" "$root/locks"
    printf '%s\n' 'schema=1 state=paused authority=v30.1.4-fleet-transaction' \
        >"$root/free-claim/.v30.1.4-free-claim-paused"
    printf '%s\n' '#!/bin/sh' 'exit 0' >"$root/free-claim/pool_daemon.sh"
    printf '%s\n' '#!/bin/sh' '# preserved worker fixture' 'exit 0' \
        >"$root/free-claim/pool_daemon.v30.1.4-original"
    chmod 0600 "$root/free-claim/.v30.1.4-free-claim-paused"
    chmod 0700 "$root/free-claim/pool_daemon.sh"
    chmod 0600 "$root/free-claim/pool_daemon.v30.1.4-original"
    printf '%s\n' 'qpriorAward' >"$root/free-claim/awarded.txt"
    chmod 0640 "$root/free-claim/awarded.txt"
    jq -cn '{attempts:3,ip:"fixture",quantum_address:"qfixtureWitnessV16",
      submitted:"2026-08-14T03:00:00+00:00"}' \
        >"$root/free-claim/queue/20260814T030000Z-deadbeef.json"
    chmod 0644 "$root/free-claim/queue/20260814T030000Z-deadbeef.json"
    local marker wrapper worker
    marker=$(sha "$root/free-claim/.v30.1.4-free-claim-paused")
    wrapper=$(sha "$root/free-claim/pool_daemon.sh")
    worker=$(sha "$root/free-claim/pool_daemon.v30.1.4-original")
    jq -n --arg root "$root" --arg marker "$marker" --arg wrapper "$wrapper" \
      --arg worker "$worker" --arg transport "$(sha "$MOCK")" --argjson gid "$gid" '{
        schema:2,kind:"node30-installed-v30.1.4-runtime-contract",
        recovery_contract:"installed-v30.1.4-node30-retained-claim-recovery/v2",
        one_shot_contract:"installed-v30.1.4-node30-free-claim-one-shot/v1",
        source_commit:"13262151077cce3f72d07d17dc7725b2b6a8e1ab",
        source_tree:"a6f7757c34b70fab841905765462d6769112d049",
        source_signer_fingerprint:"SHA256:jAkpBudDw+ntWHSUx3e1KY+czAFjnlaPxQtRFtptL70",
        network_version:300104,subversion:"/Blackcoin:30.1.4/",
        compose_project:"blackcoin30",
        image_ref:("qqblackcoin/blackcoin-v4-gui@sha256:"+("c"*64)),
        image_id:("sha256:"+("d"*64)),cli_path:"/usr/local/bin/blackcoin-cli",
        cli_sha256:("a"*64),daemon_path:"/usr/local/bin/blackcoind",
        daemon_sha256:("b"*64),datadir:"/home/blackcoin/.blackcoin",
        transport_sha256:$transport,
        global_lock_paths:[($root+"/locks/rollout.lock"),($root+"/locks/endpoint.lock"),
          ($root+"/locks/cutover.lock"),($root+"/locks/quarantine.lock"),
          ($root+"/locks/wallet.lock"),($root+"/locks/pause.lock"),
          ($root+"/locks/pool.lock"),($root+"/locks/recovery.lock")],
        node_lock_path:($root+"/locks/node30.lock"),
        node:{node:30,service:"node30",container:"blackcoin-v4-gui-30",wallet:""},
        pause_marker:($root+"/free-claim/.v30.1.4-free-claim-paused"),
        pause_marker_sha256:$marker,pause_wrapper:($root+"/free-claim/pool_daemon.sh"),
        pause_wrapper_sha256:$wrapper,
        original_worker:($root+"/free-claim/pool_daemon.v30.1.4-original"),
        original_worker_sha256:$worker,free_claim_root:($root+"/free-claim"),
        queue_dir:($root+"/free-claim/queue"),done_dir:($root+"/free-claim/done"),
        awarded_file:($root+"/free-claim/awarded.txt"),pool_group_gid:$gid}' \
      >"$root/runtime.json"
    chmod 0600 "$root/runtime.json"
    printf '%s\n' "$root"
}

run_audit()
{
    local root=$1 scenario=${2:-happy}
    FLEET31_TEST_TRANSPORT="$MOCK" FLEET31_FIXTURE="$root/state" \
      FLEET31_SCENARIO="$scenario" \
      "$TOOL" audit --runtime-manifest "$root/runtime.json" --run-dir "$root/run" \
      >"$root/audit.out" || return
    local audit_sha
    audit_sha=$(jq -r .audit_sha256 "$root/audit.out") || return
    jq --arg digest "$audit_sha" \
      '.required_authority | .decision="authorize" | .audit_receipt_sha256=$digest' \
      "$root/run/audit.json" >"$root/authority.json" || return
    chmod 0600 "$root/authority.json" || return
    printf '%s\n' "$audit_sha"
}

invoke()
{
    local root=$1 scenario=$2 command=$3
    shift 3
    FLEET31_TEST_TRANSPORT="$MOCK" FLEET31_FIXTURE="$root/state" \
      FLEET31_SCENARIO="$scenario" \
      "$TOOL" "$command" --run-dir "$root/run" \
      --authority "$root/authority.json" --authority-sha256 "$(sha "$root/authority.json")" "$@"
}

# Static scope: exactly one wallet-mutating RPC call site and no role/unlock,
# recurring-worker, recovery, repair, or chain-rewrite invocation.
assert_eq "$(python3 - "$TOOL" <<'PY'
import ast,sys
t=ast.parse(open(sys.argv[1]).read())
print(sum(isinstance(n,ast.Call) and len(n.args)>=2 and isinstance(n.args[1],ast.Constant)
          and n.args[1].value=='sendshadowpowclaim' for n in ast.walk(t)))
PY
)" 1
assert_fails 'tool contains no ordinary PoW enabling RPC call' \
    grep -Eq 'rpc\([^\n]*"setpowmining"' "$TOOL"
assert_fails 'tool contains no wallet unlock RPC call' \
    grep -Eq 'rpc\([^\n]*"walletpassphrase"' "$TOOL"
assert_fails 'tool contains no recovery transaction RPC call' \
    grep -Eq 'rpc\([^\n]*"(resolveallshadowpowclaims|sendrawtransaction|abandontransaction)"' "$TOOL"

HAPPY=$(make_fixture happy)
AUDIT_SHA=$(run_audit "$HAPPY")
assert_jq '.result=="READY_FOR_SEPARATE_ONE_SHOT_AUTHORITY" and
  .mutation_performed==false and .snapshot.queue.broadcast_marker_count==0 and
  .snapshot.payout.witness_version==16 and .snapshot.work.proof_version==2 and
  .snapshot.role.ordinary_pow.enabled==false and .snapshot.role.pos.staking==true and
  .required_authority.proof_override==null and .required_authority.maximum_fee_blk=="0.00028700"' \
  "$HAPPY/run/audit.json"
assert_eq "$(grep -c sendshadowpowclaim "$HAPPY/state/transport.log" || true)" 0
assert_eq "$(sha "$HAPPY/run/audit.json")" "$AUDIT_SHA"

invoke "$HAPPY" happy execute >"$HAPPY/execute.out"
assert_jq '.result=="EXACT_ONE_SHOT_BROADCAST" and .sendshadowpowclaim_call_count==1 and
  .proof_override_used==false and .transaction.fee.actual_fee_blk=="0.00028700" and
  .transaction.fee.independently_computed==true and .transaction.fee.vsize==287 and
  .queue_outcome.state=="broadcast" and .pause_preserved==true and
  .ordinary_pow_enabled==false and .recurring_worker_invoked==false' \
  "$HAPPY/run/broadcast-complete.json"
assert_eq "$(grep -c sendshadowpowclaim "$HAPPY/state/transport.log")" 1
assert_eq "$(grep 'sendshadowpowclaim' "$HAPPY/state/transport.log" | jq -r '.[-4:]|join("|")')" \
  'BfixtureLegacyTarget|qfixtureWitnessV16|2000000|100'
assert_eq "$(find "$HAPPY/free-claim/queue" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" 0
assert_eq "$(find "$HAPPY/free-claim/done" -name '*.broadcast' | wc -l | tr -d ' ')" 1
assert_eq "$(sha "$HAPPY/free-claim/.v30.1.4-free-claim-paused")" \
  "$(jq -r .pause_marker_sha256 "$HAPPY/runtime.json")"
assert_eq "$(grep -c '^qfixtureWitnessV16$' "$HAPPY/free-claim/awarded.txt" || true)" 0

invoke "$HAPPY" happy monitor >"$HAPPY/pending.out"
PENDING=$(jq -r .receipt "$HAPPY/pending.out")
assert_jq '.result=="BROADCAST_PENDING_ACTIVE_CHAIN_CONFIRMATION" and
  .confirmations==0 and .retry_authorized==false and .queue_state=="broadcast"' \
  "$HAPPY/run/$PENDING"
assert_eq "$(grep -c sendshadowpowclaim "$HAPPY/state/transport.log")" 1

jq '.confirmed=true' "$HAPPY/state/state.json" >"$HAPPY/state/next" && \
  mv "$HAPPY/state/next" "$HAPPY/state/state.json"
invoke "$HAPPY" happy monitor >"$HAPPY/terminal.out"
assert_jq '.result=="CONFIRMED_ACTIVE_CHAIN_QUANTUM_PAYOUT" and .confirmations==6 and
  .synthetic_payout.mode=="pow" and
  .synthetic_payout.pow_claim_source.disposition=="winner" and
  .synthetic_payout.pow_claim_source.proof_version==2 and
  (.synthetic_payout.pow_claim_source.base_fee|tostring)=="0.00028700" and
  .queue_outcome.state=="confirmed" and .awarded_ledger.atomic_replace==true and
  .pause_preserved==true and .ordinary_pow_enabled==false and .pos_active==true' \
  "$HAPPY/run/terminal.json"
assert_eq "$(grep -c '^qfixtureWitnessV16$' "$HAPPY/free-claim/awarded.txt")" 1
assert_eq "$(find "$HAPPY/free-claim/done" -name '*.confirmed.json' | wc -l | tr -d ' ')" 1
assert_eq "$(grep -c sendshadowpowclaim "$HAPPY/state/transport.log")" 1

# Fully published terminal state is idempotent, and the inherited no-clobber
# publisher heals only its exact interrupted JSON/sidecar hard-link windows.
TERMINAL_SHA=$(sha "$HAPPY/run/terminal.json")
ln "$HAPPY/run/terminal.json" "$HAPPY/run/.terminal.json.tmp.123.456"
invoke "$HAPPY" happy monitor >"$HAPPY/terminal-again.out"
assert_jq '.result=="CONFIRMED_ACTIVE_CHAIN_QUANTUM_PAYOUT" and
  .already_complete==true' "$HAPPY/terminal-again.out"
assert_eq "$(stat -f %l "$HAPPY/run/terminal.json")" 1
assert_fails 'healed terminal publisher temporary link is removed' \
  test -e "$HAPPY/run/.terminal.json.tmp.123.456"
ln "$HAPPY/run/terminal.json.sha256" \
  "$HAPPY/run/.terminal.json.sha256.tmp.123.456"
invoke "$HAPPY" happy monitor >"$HAPPY/terminal-sidecar-again.out"
assert_eq "$(stat -f %l "$HAPPY/run/terminal.json.sha256")" 1
assert_fails 'healed terminal sidecar publisher temporary link is removed' \
  test -e "$HAPPY/run/.terminal.json.sha256.tmp.123.456"
assert_eq "$(sha "$HAPPY/run/terminal.json")" "$TERMINAL_SHA"
assert_eq "$(grep -c sendshadowpowclaim "$HAPPY/state/transport.log")" 1

# Unknown response consumes authority, quarantines the queue item, and is
# reconciled from wallet bytes without a second send.
LOST=$(make_fixture lost)
run_audit "$LOST" >/dev/null
assert_fails 'lost response fails closed' invoke "$LOST" lost-response execute
assert_jq '.state=="UNKNOWN_AUTHORITY_CONSUMED_NEVER_RETRY" and
  .retry_authorized==false and .sendshadowpowclaim_call_count==1 and
  .queue_outcome.state=="uncertain"' "$LOST/run/rpc-unknown.json"
assert_eq "$(grep -c sendshadowpowclaim "$LOST/state/transport.log")" 1
invoke "$LOST" happy reconcile >"$LOST/reconcile.out"
assert_jq '.result=="EXACT_ONE_SHOT_RECONCILED_WITHOUT_RETRY" and
  .sendshadowpowclaim_call_count==1 and .rpc_response_sha256==null and
  .queue_outcome.state=="broadcast"' "$LOST/run/broadcast-complete.json"
assert_eq "$(grep -c sendshadowpowclaim "$LOST/state/transport.log")" 1
assert_fails 'consumed authority cannot execute again' invoke "$LOST" happy execute
assert_eq "$(grep -c sendshadowpowclaim "$LOST/state/transport.log")" 1

# SIGKILL at each external-call persistence boundary remains one-shot. An
# intent without a wallet transaction is observed without retry; persisted
# wallet bytes are recovered from the wallet inventory/anchor spender.
CRASH_BEFORE=$(make_fixture crash-before-persist)
run_audit "$CRASH_BEFORE" >/dev/null
assert_fails 'crash before wallet persistence consumes authority' \
  invoke "$CRASH_BEFORE" crash-before-persist execute
assert_jq '.state=="AUTHORITY_CONSUMED_RPC_PENDING_OR_COMPLETE" and
  .call_budget==1' "$CRASH_BEFORE/run/intent.json"
assert_fails 'pre-persist crash has no RPC response receipt' \
  test -e "$CRASH_BEFORE/run/rpc-response.json"
invoke "$CRASH_BEFORE" happy reconcile >"$CRASH_BEFORE/reconcile.out"
PRE_RECEIPT=$(jq -r .receipt "$CRASH_BEFORE/reconcile.out")
assert_jq '.result=="NO_EXACT_TRANSACTION_YET_AUTHORITY_CONSUMED" and
  .retry_authorized==false and .candidate_count==0 and .queue_state=="queued"' \
  "$CRASH_BEFORE/run/$PRE_RECEIPT"
assert_eq "$(grep -c sendshadowpowclaim "$CRASH_BEFORE/state/transport.log")" 1
assert_fails 'pre-persist crash cannot execute again' invoke "$CRASH_BEFORE" happy execute

CRASH_PERSISTED=$(make_fixture crash-after-persist)
run_audit "$CRASH_PERSISTED" >/dev/null
assert_fails 'crash after wallet persistence consumes authority' \
  invoke "$CRASH_PERSISTED" crash-after-persist execute
assert_fails 'post-persist crash has no fabricated RPC response receipt' \
  test -e "$CRASH_PERSISTED/run/rpc-response.json"
invoke "$CRASH_PERSISTED" happy reconcile >"$CRASH_PERSISTED/reconcile.out"
assert_jq '.result=="EXACT_ONE_SHOT_RECONCILED_WITHOUT_RETRY" and
  .rpc_response_sha256==null and .queue_outcome.state=="broadcast"' \
  "$CRASH_PERSISTED/run/broadcast-complete.json"
assert_eq "$(grep -c sendshadowpowclaim "$CRASH_PERSISTED/state/transport.log")" 1

CRASH_RESPONSE=$(make_fixture crash-after-response)
run_audit "$CRASH_RESPONSE" >/dev/null
assert_fails 'crash after durable raw response is restart-safe' \
  invoke "$CRASH_RESPONSE" crash-after-response-receipt execute
assert_jq '.published_before_post_call_rpc_reads==true and
  .sendshadowpowclaim_call_count==1' "$CRASH_RESPONSE/run/rpc-response.json"
rm "$CRASH_RESPONSE/run/rpc-response.json.sha256"
invoke "$CRASH_RESPONSE" happy reconcile >"$CRASH_RESPONSE/reconcile.out"
assert_jq '.result=="EXACT_ONE_SHOT_RECONCILED_WITHOUT_RETRY" and
  (.rpc_response_sha256|test("^[0-9a-f]{64}$")) and
  .queue_outcome.state=="broadcast"' "$CRASH_RESPONSE/run/broadcast-complete.json"
assert_eq "$(sha "$CRASH_RESPONSE/run/rpc-response.json")" \
  "$(awk '{print $1}' "$CRASH_RESPONSE/run/rpc-response.json.sha256")"
assert_eq "$(grep -c sendshadowpowclaim "$CRASH_RESPONSE/state/transport.log")" 1

# Local durable-state crash windows recover without another send.
QUEUE_CRASH=$(make_fixture queue-crash)
run_audit "$QUEUE_CRASH" >/dev/null
invoke "$QUEUE_CRASH" happy execute >/dev/null
rm "$QUEUE_CRASH/run/broadcast-complete.json" \
   "$QUEUE_CRASH/run/broadcast-complete.json.sha256"
invoke "$QUEUE_CRASH" happy reconcile >"$QUEUE_CRASH/reconcile.out"
assert_jq '.result=="EXACT_ONE_SHOT_RECONCILED_WITHOUT_RETRY" and
  .queue_outcome.state=="broadcast" and .queue_outcome.already_complete==true' \
  "$QUEUE_CRASH/run/broadcast-complete.json"
assert_eq "$(grep -c sendshadowpowclaim "$QUEUE_CRASH/state/transport.log")" 1

AWARDED_CRASH=$(make_fixture awarded-crash)
run_audit "$AWARDED_CRASH" >/dev/null
invoke "$AWARDED_CRASH" happy execute >/dev/null
jq '.confirmed=true' "$AWARDED_CRASH/state/state.json" >"$AWARDED_CRASH/state/next" && \
  mv "$AWARDED_CRASH/state/next" "$AWARDED_CRASH/state/state.json"
printf '%s\n' qfixtureWitnessV16 >>"$AWARDED_CRASH/free-claim/awarded.txt"
invoke "$AWARDED_CRASH" happy monitor >"$AWARDED_CRASH/terminal.out"
assert_jq '.result=="CONFIRMED_ACTIVE_CHAIN_QUANTUM_PAYOUT" and
  .awarded_ledger.already_complete==true and .queue_outcome.state=="confirmed"' \
  "$AWARDED_CRASH/run/terminal.json"
assert_eq "$(grep -c '^qfixtureWitnessV16$' "$AWARDED_CRASH/free-claim/awarded.txt")" 1

CONFIRMED_CRASH=$(make_fixture confirmed-crash)
run_audit "$CONFIRMED_CRASH" >/dev/null
invoke "$CONFIRMED_CRASH" happy execute >/dev/null
jq '.confirmed=true' "$CONFIRMED_CRASH/state/state.json" >"$CONFIRMED_CRASH/state/next" && \
  mv "$CONFIRMED_CRASH/state/next" "$CONFIRMED_CRASH/state/state.json"
invoke "$CONFIRMED_CRASH" happy monitor >/dev/null
rm "$CONFIRMED_CRASH/run/terminal.json" "$CONFIRMED_CRASH/run/terminal.json.sha256"
invoke "$CONFIRMED_CRASH" happy monitor >"$CONFIRMED_CRASH/rebuilt.out"
assert_jq '.queue_outcome.state=="confirmed" and .queue_outcome.already_complete==true and
  .awarded_ledger.already_complete==true' "$CONFIRMED_CRASH/run/terminal.json"
assert_eq "$(grep -c sendshadowpowclaim "$CONFIRMED_CRASH/state/transport.log")" 1

# Audit hostiles fail before authority or wallet mutation.
for scenario in wrong-witness qqp3 pow-enabled pos-disabled blocking multiple-target-inputs; do
    ROOT_CASE=$(make_fixture "audit-$scenario")
    assert_fails "audit rejects $scenario" run_audit "$ROOT_CASE" "$scenario"
    assert_eq "$(grep -c sendshadowpowclaim "$ROOT_CASE/state/transport.log" || true)" 0
done

EXTRA=$(make_fixture extra-queue)
cp "$EXTRA/free-claim/queue/20260814T030000Z-deadbeef.json" \
  "$EXTRA/free-claim/queue/20260814T030001Z-feedface.json"
chmod 0644 "$EXTRA/free-claim/queue/20260814T030001Z-feedface.json"
assert_fails 'audit rejects a second queue item' run_audit "$EXTRA" happy

EXISTING=$(make_fixture existing-broadcast)
printf '%s\n' '{}' >"$EXISTING/free-claim/done/prior.broadcast"
chmod 0644 "$EXISTING/free-claim/done/prior.broadcast"
assert_fails 'audit rejects existing broadcast marker' run_audit "$EXISTING" happy

DUP=$(make_fixture awarded-duplicate)
printf '%s\n' qfixtureWitnessV16 >>"$DUP/free-claim/awarded.txt"
assert_fails 'audit rejects already-awarded queued payout' run_audit "$DUP" happy

SYMLINK=$(make_fixture queue-symlink)
mv "$SYMLINK/free-claim/queue/20260814T030000Z-deadbeef.json" "$SYMLINK/item"
ln -s "$SYMLINK/item" "$SYMLINK/free-claim/queue/20260814T030000Z-deadbeef.json"
assert_fails 'audit rejects symlink queue item' run_audit "$SYMLINK" happy

# Authority tampering and stale state fail before the sole RPC.
AUTH=$(make_fixture authority)
run_audit "$AUTH" >/dev/null
for filter in \
  '.maximum_fee_blk="0.01"' \
  '.fee_rate_atoms_per_vbyte=99' \
  '.maximum_tries=1' \
  '.proof_override="00"' \
  '.ordinary_pow_authorized=true' \
  '.recurring_worker_authorized=true' \
  '.user_order_sha256=("0"*64)' \
  '.queue_item_sha256=("0"*64)' \
  '.tool_sha256=("0"*64)' \
  '.extra=true'; do
    jq "$filter" "$AUTH/authority.json" >"$AUTH/bad-authority.json"
    chmod 0600 "$AUTH/bad-authority.json"
    mv "$AUTH/authority.json" "$AUTH/good-authority.json"
    mv "$AUTH/bad-authority.json" "$AUTH/authority.json"
    assert_fails "authority rejects $filter" invoke "$AUTH" happy execute
    mv "$AUTH/authority.json" "$AUTH/bad-authority.json"
    mv "$AUTH/good-authority.json" "$AUTH/authority.json"
done
assert_eq "$(grep -c sendshadowpowclaim "$AUTH/state/transport.log" || true)" 0
chmod 0644 "$AUTH/authority.json"
assert_fails 'authority must be owner-only mode 0600' invoke "$AUTH" happy execute
chmod 0600 "$AUTH/authority.json"
printf ' ' >>"$AUTH/free-claim/queue/20260814T030000Z-deadbeef.json"
assert_fails 'queue drift invalidates reviewed audit' invoke "$AUTH" happy execute
assert_eq "$(grep -c sendshadowpowclaim "$AUTH/state/transport.log" || true)" 0

AUTH_LINK=$(make_fixture authority-link)
run_audit "$AUTH_LINK" >/dev/null
mv "$AUTH_LINK/authority.json" "$AUTH_LINK/authority.real"
ln -s "$AUTH_LINK/authority.real" "$AUTH_LINK/authority.json"
assert_fails 'authority symlink is rejected before the RPC' invoke "$AUTH_LINK" happy execute
assert_eq "$(grep -c sendshadowpowclaim "$AUTH_LINK/state/transport.log" || true)" 0

# A structurally bad or over-cap response is persisted first, then contained as
# uncertain. It cannot authorize a retry.
for scenario in malformed-response wrong-address-response wrong-proof-payout \
                wrong-change-script wrong-proof-script-encoding over-cap \
                overprecision-fee; do
    BAD=$(make_fixture "response-$scenario")
    run_audit "$BAD" >/dev/null
    assert_fails "response rejects $scenario" invoke "$BAD" "$scenario" execute
    assert_jq '.state=="RESPONSE_PERSISTED_VALIDATION_FAILED_NEVER_RETRY" and
      .retry_authorized==false and .queue_outcome.state=="uncertain"' \
      "$BAD/run/invalid-response.json"
    assert_jq '.published_before_post_call_rpc_reads==true and
      .sendshadowpowclaim_call_count==1' "$BAD/run/rpc-response.json"
    assert_eq "$(grep -c sendshadowpowclaim "$BAD/state/transport.log")" 1
    assert_fails "bad response $scenario cannot execute twice" invoke "$BAD" happy execute
    assert_eq "$(grep -c sendshadowpowclaim "$BAD/state/transport.log")" 1
done

# Confirmation without exact indexed quantum credit never updates the awarded
# ledger or promotes the broadcast marker.
for scenario in missing-payout rejected-payout wrong-payout-vout inactive-header \
                confirmed-bytes-drift; do
    PAY=$(make_fixture "payout-$scenario")
    run_audit "$PAY" >/dev/null
    invoke "$PAY" happy execute >/dev/null
    jq '.confirmed=true' "$PAY/state/state.json" >"$PAY/state/next" && \
      mv "$PAY/state/next" "$PAY/state/state.json"
    assert_fails "terminal rejects $scenario" invoke "$PAY" "$scenario" monitor
    assert_eq "$(grep -c '^qfixtureWitnessV16$' "$PAY/free-claim/awarded.txt" || true)" 0
    assert_eq "$(find "$PAY/free-claim/done" -name '*.broadcast' | wc -l | tr -d ' ')" 1
    assert_eq "$(grep -c sendshadowpowclaim "$PAY/state/transport.log")" 1
done

printf 'PASS: %d hostile node30 Free-Claim one-shot assertions\n' "$COUNT"
