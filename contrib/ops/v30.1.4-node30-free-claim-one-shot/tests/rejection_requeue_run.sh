#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C
umask 077

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
LEGACY="$ROOT/node30_free_claim_one_shot.py"
TOOL="$ROOT/node30_free_claim_rejection_requeue.py"
DURABLE="$ROOT/node30_free_claim_durable_requeue.py"
EDGE="$ROOT/node30_free_claim_edge_one_shot.py"
MOCK="$ROOT/tests/rejection_requeue_mock_transport.py"
EDGE_MOCK="$ROOT/tests/edge_mock_transport.py"
FIX_RAW=$(mktemp -d "${TMPDIR:-/tmp}/node30-rejection-requeue.XXXXXX")
FIX=$(CDPATH='' cd -- "$FIX_RAW" && pwd -P)
cleanup()
{
    if [[ "${KEEP_NODE30_FIXTURE:-0}" == 1 ]]; then
        printf 'preserved fixture: %s\n' "$FIX" >&2
    else
        rm -rf -- "$FIX"
    fi
}
trap cleanup EXIT HUP INT TERM
COUNT=0
HOSTILE_COLLISION_SHA=$(printf '%s\n' '{"hostile":"destination-appeared"}' | \
  shasum -a 256 | awk '{print $1}')

ok()
{
    COUNT=$((COUNT + 1))
}

sha()
{
    shasum -a 256 "$1" | awk '{print $1}'
}

rewrite_sidecar()
{
    local path=$1
    printf '%s  %s\n' "$(sha "$path")" "$(basename "$path")" \
      >"$path.sha256"
    chmod 0600 "$path" "$path.sha256"
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

make_fixture()
{
    local root="$FIX/${1:-fleet}" gid marker wrapper worker transport
    gid=$(id -g)
    mkdir -m 0700 "$root" "$root/state" "$root/free-claim" \
        "$root/free-claim/queue" "$root/free-claim/done" "$root/locks"
    chmod 0750 "$root/free-claim" "$root/free-claim/done"
    chmod 0770 "$root/free-claim/queue"
    printf '%s\n' 'schema=1 state=paused authority=v30.1.4-fleet-transaction' \
        >"$root/free-claim/.v30.1.4-free-claim-paused"
    printf '%s\n' '#!/bin/sh' 'exit 0' >"$root/free-claim/pool_daemon.sh"
    printf '%s\n' '#!/bin/sh' '# preserved worker fixture' 'exit 0' \
        >"$root/free-claim/pool_daemon.v30.1.4-original"
    chmod 0600 "$root/free-claim/.v30.1.4-free-claim-paused"
    chmod 0700 "$root/free-claim/pool_daemon.sh"
    chmod 0600 "$root/free-claim/pool_daemon.v30.1.4-original"
    printf '%s\n' qpriorAward >"$root/free-claim/awarded.txt"
    chmod 0640 "$root/free-claim/awarded.txt"
    jq -cn '{attempts:3,ip:"fixture",quantum_address:"qfixtureWitnessV16",
      submitted:"2026-08-14T03:00:00+00:00"}' \
      >"$root/free-claim/queue/20260814T030000Z-deadbeef.json"
    chmod 0644 "$root/free-claim/queue/20260814T030000Z-deadbeef.json"
    marker=$(sha "$root/free-claim/.v30.1.4-free-claim-paused")
    wrapper=$(sha "$root/free-claim/pool_daemon.sh")
    worker=$(sha "$root/free-claim/pool_daemon.v30.1.4-original")
    transport=$(sha "$MOCK")
    jq -n --arg root "$root" --arg marker "$marker" --arg wrapper "$wrapper" \
      --arg worker "$worker" --arg transport "$transport" --argjson gid "$gid" '{
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

legacy_call()
{
    local fixture=$1 scenario=$2
    shift 2
    FLEET31_TEST_TRANSPORT="$MOCK" FLEET31_FIXTURE="$fixture/state" \
      FLEET31_SCENARIO="$scenario" python3 - "$LEGACY" "$MOCK" "$@" <<'PY'
import hashlib,importlib.util,pathlib,sys
tool=pathlib.Path(sys.argv[1])
mock=pathlib.Path(sys.argv[2])
spec=importlib.util.spec_from_file_location('legacy_requeue_test_tool',tool)
mod=importlib.util.module_from_spec(spec)
sys.modules[spec.name]=mod
spec.loader.exec_module(mod)
mod.node30.base.TEST_TRANSPORT_SHA256=hashlib.sha256(mock.read_bytes()).hexdigest()
raise SystemExit(mod.main(sys.argv[3:]))
PY
}

companion_call()
{
    local fixture=$1 scenario=$2
    shift 2
    FLEET31_TEST_TRANSPORT="$MOCK" FLEET31_FIXTURE="$fixture/state" \
      FLEET31_SCENARIO="$scenario" "$TOOL" "$@"
}

durable_call()
{
    local fixture=$1 scenario=$2
    shift 2
    FLEET31_TEST_TRANSPORT="$MOCK" FLEET31_FIXTURE="$fixture/state" \
      FLEET31_SCENARIO="$scenario" "$DURABLE" "$@"
}

edge_call()
{
    local fixture=$1 scenario=$2
    shift 2
    FLEET31_TEST_TRANSPORT="$EDGE_MOCK" FLEET31_FIXTURE="$fixture/state" \
      FLEET31_SCENARIO="$scenario" "$EDGE" "$@"
}

# Inject a serialized pause transition after the fleet locks are acquired but
# before the command receives them.  The pause stays absent until main()
# returns, so a stale pre-lock baseline would allow a mutation/PASS receipt and
# only then notice the change.  A correct command fails before doing either.
companion_prelock_transition_call()
{
    local fixture=$1 scenario=$2 marker=$3
    shift 3
    FLEET31_TEST_TRANSPORT="$MOCK" FLEET31_FIXTURE="$fixture/state" \
      FLEET31_SCENARIO="$scenario" python3 - "$TOOL" "$marker" "$@" <<'PY'
import contextlib
import importlib.util
import os
import pathlib
import sys

tool = pathlib.Path(sys.argv[1])
marker = pathlib.Path(sys.argv[2])
saved = marker.with_name(marker.name + ".hostile-prelock-saved")
spec = importlib.util.spec_from_file_location("requeue_prelock_hostile", tool)
mod = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = mod
spec.loader.exec_module(mod)
original = mod.legacy.node30.mutation_locks

@contextlib.contextmanager
def transition(contract):
    with original(contract) as identities:
        os.rename(marker, saved)
        yield identities

mod.legacy.node30.mutation_locks = transition
try:
    result = mod.main(sys.argv[3:])
finally:
    if saved.exists():
        os.rename(saved, marker)
raise SystemExit(result)
PY
}

# Project a runtime/pause mismatch only on the second snapshot.  The first is
# the locked baseline; the second is the locked postcondition.  A PASS artifact
# must not exist when the postcondition rejects the operation.
companion_postcheck_drift_call()
{
    local fixture=$1 scenario=$2
    shift 2
    FLEET31_TEST_TRANSPORT="$MOCK" FLEET31_FIXTURE="$fixture/state" \
      FLEET31_SCENARIO="$scenario" python3 - "$TOOL" "$@" <<'PY'
import copy
import importlib.util
import pathlib
import sys

tool = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("requeue_postcheck_hostile", tool)
mod = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = mod
spec.loader.exec_module(mod)
original = mod.legacy.node30.free_claim_snapshot
calls = 0

def drift(contract):
    global calls
    calls += 1
    snapshot = original(contract)
    if calls == 2:
        snapshot = copy.deepcopy(snapshot)
        snapshot["hostile_serialized_transition"] = True
    return snapshot

mod.legacy.node30.free_claim_snapshot = drift
raise SystemExit(mod.main(sys.argv[2:]))
PY
}

# The companion has no wallet-mutating RPC call site and cannot consume the
# old one-shot authority for another financial call.
assert_eq "$(python3 - "$TOOL" <<'PY'
import ast,sys
t=ast.parse(open(sys.argv[1]).read())
print(sum(isinstance(n,ast.Call) and len(n.args)>=2 and
          isinstance(n.args[1],ast.Constant) and
          n.args[1].value=='sendshadowpowclaim' for n in ast.walk(t)))
PY
)" 0

FLEET=$(make_fixture)
SOURCE="$FLEET/source-run"
legacy_call "$FLEET" mempool-reject audit \
  --runtime-manifest "$FLEET/runtime.json" --run-dir "$SOURCE" >"$FLEET/audit.out"
AUDIT_SHA=$(jq -r .audit_sha256 "$FLEET/audit.out")
jq --arg digest "$AUDIT_SHA" \
  '.required_authority | .decision="authorize" | .audit_receipt_sha256=$digest' \
  "$SOURCE/audit.json" >"$SOURCE/AUTHORITY.json"
chmod 0600 "$SOURCE/AUTHORITY.json"
AUTH_SHA=$(sha "$SOURCE/AUTHORITY.json")

assert_fails 'deterministic Core rejection consumes the old authority' \
  legacy_call "$FLEET" mempool-reject execute --run-dir "$SOURCE" \
    --authority "$SOURCE/AUTHORITY.json" --authority-sha256 "$AUTH_SHA"
assert_jq '.state=="UNKNOWN_AUTHORITY_CONSUMED_NEVER_RETRY" and
  .retry_authorized==false and .sendshadowpowclaim_call_count==1 and
  .error=="node30 sendshadowpowclaim: error code: -26\nerror message:\nShadow PoW claim rejected: shadow-proof-mempool-limit" and
  .queue_outcome.state=="uncertain"' "$SOURCE/rpc-unknown.json"
assert_eq "$(jq -r .send_calls "$FLEET/state/state.json")" 1

legacy_call "$FLEET" cleared reconcile --run-dir "$SOURCE" \
  --authority "$SOURCE/AUTHORITY.json" --authority-sha256 "$AUTH_SHA" \
  >"$FLEET/reconcile.out"
RECONCILE_NAME=$(jq -r .receipt "$FLEET/reconcile.out")
RECONCILE_SHA=$(jq -r .sha256 "$FLEET/reconcile.out")
assert_jq '.result=="NO_EXACT_TRANSACTION_YET_AUTHORITY_CONSUMED" and
  .retry_authorized==false and .candidate_count==0 and .queue_state=="uncertain"' \
  "$SOURCE/$RECONCILE_NAME"

# A serialized pause transition at lock acquisition invalidates any stale
# pre-lock baseline.  It must fail before moving the item or publishing PASS.
PAUSE_MARKER="$FLEET/free-claim/.v30.1.4-free-claim-paused"
assert_fails 'terminalization rejects a stale pre-lock pause baseline' \
  companion_prelock_transition_call "$FLEET" cleared "$PAUSE_MARKER" \
    terminalize --run-dir "$SOURCE" \
    --authority "$SOURCE/AUTHORITY.json" --authority-sha256 "$AUTH_SHA" \
    --reconcile-receipt "$SOURCE/$RECONCILE_NAME" \
    --reconcile-sha256 "$RECONCILE_SHA"
assert_fails 'pre-lock terminalization failure publishes no PASS receipt' \
  test -e "$SOURCE/definitive-rejection.json"
assert_eq "$(find "$FLEET/free-claim/done" -name '*.uncertain.json' | wc -l | tr -d ' ')" 1
assert_eq "$(find "$FLEET/free-claim/done" -name '*.rejected.json' | wc -l | tr -d ' ')" 0
assert_eq "$(jq -r .send_calls "$FLEET/state/state.json")" 1

# A hostile destination that appears during the live no-transaction proof is
# never overwritten, and no terminal receipt is published around it.
UNCERTAIN=$(find "$FLEET/free-claim/done" -name '*.uncertain.json')
REJECTED=${UNCERTAIN%.uncertain.json}.rejected.json
assert_fails \
  'terminalization destination appearance is no-clobber' \
  companion_call "$FLEET" terminal-target-race terminalize --run-dir "$SOURCE" \
    --authority "$SOURCE/AUTHORITY.json" --authority-sha256 "$AUTH_SHA" \
    --reconcile-receipt "$SOURCE/$RECONCILE_NAME" \
    --reconcile-sha256 "$RECONCILE_SHA"
if [[ ! -e "$REJECTED" ]]; then
    printf 'terminal race did not create its hostile target:\n' >&2
    sed -n '1,120p' "$FIX/fail.err" >&2
    exit 1
fi
assert_eq "$(sha "$REJECTED")" "$HOSTILE_COLLISION_SHA"
assert_eq "$(sha "$UNCERTAIN")" "$(jq -r .snapshot.queue.item.sha256 "$SOURCE/audit.json")"
assert_fails 'destination collision publishes no terminal receipt' \
  test -e "$SOURCE/definitive-rejection.json"
rm -- "$REJECTED"

# Replacing the done-directory pathname with a lookalike inode fails before
# lifecycle mutation. Restore the exact audited directory before continuing.
mv -- "$FLEET/free-claim/done" "$FLEET/free-claim/done.audited"
mkdir -m 0750 "$FLEET/free-claim/done"
chgrp "$(id -g)" "$FLEET/free-claim/done"
assert_fails 'terminalization rejects done-directory path substitution' \
  companion_call "$FLEET" cleared terminalize --run-dir "$SOURCE" \
    --authority "$SOURCE/AUTHORITY.json" --authority-sha256 "$AUTH_SHA" \
    --reconcile-receipt "$SOURCE/$RECONCILE_NAME" \
    --reconcile-sha256 "$RECONCILE_SHA"
rmdir -- "$FLEET/free-claim/done"
mv -- "$FLEET/free-claim/done.audited" "$FLEET/free-claim/done"

# Heal only the exact two-link state left by a crash after the no-clobber link
# was fsynced but before the source unlink.  A hostile locked postcondition then
# fails after healing but before PASS publication; a target-only resume may
# publish the terminal receipt only after a clean postcondition.
ln -- "$UNCERTAIN" "$REJECTED"
assert_fails 'terminalization postcondition failure publishes no PASS receipt' \
  companion_postcheck_drift_call "$FLEET" cleared terminalize \
    --run-dir "$SOURCE" --authority "$SOURCE/AUTHORITY.json" \
    --authority-sha256 "$AUTH_SHA" \
    --reconcile-receipt "$SOURCE/$RECONCILE_NAME" \
    --reconcile-sha256 "$RECONCILE_SHA"
assert_fails 'postcondition-rejected terminalization has no PASS artifact' \
  test -e "$SOURCE/definitive-rejection.json"
assert_fails 'postcondition-rejected terminalization healed the crash source' \
  test -e "$UNCERTAIN"
assert_eq "$(sha "$REJECTED")" "$(jq -r .snapshot.queue.item.sha256 "$SOURCE/audit.json")"
companion_call "$FLEET" cleared terminalize --run-dir "$SOURCE" \
  --authority "$SOURCE/AUTHORITY.json" --authority-sha256 "$AUTH_SHA" \
  --reconcile-receipt "$SOURCE/$RECONCILE_NAME" \
  --reconcile-sha256 "$RECONCILE_SHA" >"$FLEET/terminalize.out"
assert_jq '.result=="DEFINITIVE_PRECOMMIT_MEMPOOL_LIMIT_REJECTION" and
  .rpc_error=="node30 sendshadowpowclaim: error code: -26\nerror message:\nShadow PoW claim rejected: shadow-proof-mempool-limit" and
  .installed_call_order=="test_accept_before_wallet_persistence_and_relay" and
  .candidate_count==0 and .old_authority_consumed==true and
  .old_authority_retry_authorized==false and .new_attempt_authorized==false and
  .queue_outcome.state=="rejected" and
  .queue_outcome.move_protocol=="hard-link-fsync-unlink-fsync-noreplace/v1" and
  .queue_outcome.no_clobber==true and .queue_outcome.same_inode==true and
  .queue_outcome.atomic_rename==false and
  .queue_outcome.already_complete==true and
  .queue_outcome.crash_link_reconciled==false' "$SOURCE/definitive-rejection.json"
assert_eq "$(find "$FLEET/free-claim/done" -name '*.rejected.json' | wc -l | tr -d ' ')" 1
assert_fails 'terminalization source was removed after crash-link healing' \
  test -e "$UNCERTAIN"
assert_eq "$(jq -r .send_calls "$FLEET/state/state.json")" 1

companion_call "$FLEET" cleared terminalize --run-dir "$SOURCE" \
  --authority "$SOURCE/AUTHORITY.json" --authority-sha256 "$AUTH_SHA" \
  --reconcile-receipt "$SOURCE/$RECONCILE_NAME" \
  --reconcile-sha256 "$RECONCILE_SHA" >"$FLEET/terminalize-again.out"
assert_jq '.already_complete==true and
  .result=="DEFINITIVE_PRECOMMIT_MEMPOOL_LIMIT_REJECTION"' \
  "$FLEET/terminalize-again.out"

# A full local shadow-proof slot blocks requeue audit. No authority or queue
# transition is emitted until the slot is stably empty.
BLOCKED="$FLEET/requeue-blocked"
assert_fails 'occupied shadow-proof slot blocks requeue audit' \
  companion_call "$FLEET" mempool-blocked audit-requeue \
    --source-run "$SOURCE" --source-authority "$SOURCE/AUTHORITY.json" \
    --source-authority-sha256 "$AUTH_SHA" \
    --reconcile-receipt "$SOURCE/$RECONCILE_NAME" \
    --reconcile-sha256 "$RECONCILE_SHA" --run-dir "$BLOCKED"
assert_fails 'blocked slot publishes no requeue audit authority' \
  test -e "$BLOCKED/requeue-audit.json"

PRELOCK_AUDIT="$FLEET/requeue-prelock-hostile"
assert_fails 'requeue audit rejects a stale pre-lock pause baseline' \
  companion_prelock_transition_call "$FLEET" cleared "$PAUSE_MARKER" \
    audit-requeue --source-run "$SOURCE" \
    --source-authority "$SOURCE/AUTHORITY.json" \
    --source-authority-sha256 "$AUTH_SHA" \
    --reconcile-receipt "$SOURCE/$RECONCILE_NAME" \
    --reconcile-sha256 "$RECONCILE_SHA" --run-dir "$PRELOCK_AUDIT"
assert_fails 'pre-lock requeue audit failure publishes no PASS receipt' \
  test -e "$PRELOCK_AUDIT/requeue-audit.json"
POSTCHECK_AUDIT="$FLEET/requeue-postcheck-hostile"
assert_fails 'requeue audit postcondition failure publishes no PASS receipt' \
  companion_postcheck_drift_call "$FLEET" cleared audit-requeue \
    --source-run "$SOURCE" --source-authority "$SOURCE/AUTHORITY.json" \
    --source-authority-sha256 "$AUTH_SHA" \
    --reconcile-receipt "$SOURCE/$RECONCILE_NAME" \
    --reconcile-sha256 "$RECONCILE_SHA" --run-dir "$POSTCHECK_AUDIT"
assert_fails 'postcondition-rejected requeue audit has no PASS artifact' \
  test -e "$POSTCHECK_AUDIT/requeue-audit.json"
CLEAR="$FLEET/requeue-clear"
companion_call "$FLEET" cleared audit-requeue \
  --source-run "$SOURCE" --source-authority "$SOURCE/AUTHORITY.json" \
  --source-authority-sha256 "$AUTH_SHA" \
  --reconcile-receipt "$SOURCE/$RECONCILE_NAME" \
  --reconcile-sha256 "$RECONCILE_SHA" --run-dir "$CLEAR" >"$FLEET/requeue-audit.out"
REQUEUE_AUDIT_SHA=$(jq -r .requeue_audit_sha256 "$FLEET/requeue-audit.out")
assert_jq '.result=="READY_FOR_SEPARATE_REQUEUE_ONLY_AUTHORITY" and
  .mutation_performed==false and .snapshot.candidate_count==0 and
  .snapshot.mempool.shadow_proof_count==0 and .snapshot.mempool.shadow_proof_limit==1 and
  .snapshot.mempool.slot_clear==true and
  .required_authority.old_authority_retry_authorized==false and
  .required_authority.sendshadowpowclaim_authorized==false and
  .required_authority.new_one_shot_audit_required==true and
  .required_authority.new_one_shot_authority_required==true' \
  "$CLEAR/requeue-audit.json"
jq --arg digest "$REQUEUE_AUDIT_SHA" \
  '.required_authority | .decision="authorize" | .audit_receipt_sha256=$digest' \
  "$CLEAR/requeue-audit.json" >"$CLEAR/AUTHORITY.json"
chmod 0600 "$CLEAR/AUTHORITY.json"
REQUEUE_AUTH_SHA=$(sha "$CLEAR/AUTHORITY.json")

# The requeue mutation proves its pause/runtime baseline only after acquiring
# all mutation locks.  A serialized transition at acquisition must leave both
# lifecycle and durable authority-consumption state untouched.
assert_fails 'requeue rejects a stale pre-lock pause baseline' \
  companion_prelock_transition_call "$FLEET" cleared "$PAUSE_MARKER" \
    requeue --run-dir "$CLEAR" --authority "$CLEAR/AUTHORITY.json" \
    --authority-sha256 "$REQUEUE_AUTH_SHA"
assert_fails 'pre-lock requeue failure publishes no intent' \
  test -e "$CLEAR/requeue-intent.json"
assert_fails 'pre-lock requeue failure publishes no completion' \
  test -e "$CLEAR/requeue-complete.json"
assert_eq "$(find "$FLEET/free-claim/done" -name '*.rejected.json' | wc -l | tr -d ' ')" 1

# Clearance is sampled again immediately before requeue. A filled slot after
# audit fails before intent or filesystem movement.
assert_fails 'slot refill invalidates reviewed requeue authority' \
  companion_call "$FLEET" mempool-blocked requeue --run-dir "$CLEAR" \
    --authority "$CLEAR/AUTHORITY.json" --authority-sha256 "$REQUEUE_AUTH_SHA"
assert_fails 'slot refill publishes no requeue-only intent' \
  test -e "$CLEAR/requeue-intent.json"
assert_eq "$(find "$FLEET/free-claim/done" -name '*.rejected.json' | wc -l | tr -d ' ')" 1

# Authority scope cannot be broadened into a send permission.
jq '.sendshadowpowclaim_authorized=true' "$CLEAR/AUTHORITY.json" \
  >"$CLEAR/bad-authority.json"
chmod 0600 "$CLEAR/bad-authority.json"
assert_fails 'requeue authority rejects financial scope escalation' \
  companion_call "$FLEET" cleared requeue --run-dir "$CLEAR" \
    --authority "$CLEAR/bad-authority.json" \
    --authority-sha256 "$(sha "$CLEAR/bad-authority.json")"

# A lookalike queue-directory inode is rejected before requeue intent. The
# exact audited directory is then restored.
mv -- "$FLEET/free-claim/queue" "$FLEET/free-claim/queue.audited"
mkdir -m 0770 "$FLEET/free-claim/queue"
chgrp "$(id -g)" "$FLEET/free-claim/queue"
assert_fails 'requeue rejects queue-directory path substitution' \
  companion_call "$FLEET" cleared requeue --run-dir "$CLEAR" \
    --authority "$CLEAR/AUTHORITY.json" --authority-sha256 "$REQUEUE_AUTH_SHA"
rmdir -- "$FLEET/free-claim/queue"
mv -- "$FLEET/free-claim/queue.audited" "$FLEET/free-claim/queue"
assert_fails 'queue path substitution publishes no requeue intent' \
  test -e "$CLEAR/requeue-intent.json"

# A destination appearing after the second clearance sample is preserved and
# blocks the move. The durable requeue-only intent may exist, but no completion
# receipt or wallet call may exist.
QUEUED="$FLEET/free-claim/queue/$(jq -r .snapshot.queue.item.basename "$SOURCE/audit.json")"
assert_fails \
  'requeue destination appearance is no-clobber' \
  companion_call "$FLEET" requeue-target-race requeue --run-dir "$CLEAR" \
    --authority "$CLEAR/AUTHORITY.json" --authority-sha256 "$REQUEUE_AUTH_SHA"
assert_eq "$(sha "$QUEUED")" "$HOSTILE_COLLISION_SHA"
assert_eq "$(sha "$REJECTED")" "$(jq -r .snapshot.queue.item.sha256 "$SOURCE/audit.json")"
assert_fails 'requeue destination collision publishes no completion' \
  test -e "$CLEAR/requeue-complete.json"
assert_eq "$(jq -r .send_calls "$FLEET/state/state.json")" 1
rm -- "$QUEUED"

# With the collision removed, the same durable nonfinancial intent may move the
# item, but a locked postcondition failure still forbids a completion receipt.
# The target-only resume then proves a clean postcondition before publishing.
assert_fails 'requeue postcondition failure publishes no PASS receipt' \
  companion_postcheck_drift_call "$FLEET" cleared requeue --run-dir "$CLEAR" \
    --authority "$CLEAR/AUTHORITY.json" --authority-sha256 "$REQUEUE_AUTH_SHA"
assert_fails 'postcondition-rejected requeue has no completion artifact' \
  test -e "$CLEAR/requeue-complete.json"
assert_eq "$(sha "$QUEUED")" "$(jq -r .snapshot.queue.item.sha256 "$SOURCE/audit.json")"
assert_fails 'postcondition-rejected requeue removed the rejected source' \
  test -e "$REJECTED"
assert_eq "$(jq -r .send_calls "$FLEET/state/state.json")" 1

companion_call "$FLEET" cleared requeue --run-dir "$CLEAR" \
  --authority "$CLEAR/AUTHORITY.json" --authority-sha256 "$REQUEUE_AUTH_SHA" \
  >"$FLEET/requeue.out"
assert_jq '.state=="REQUEUE_ONLY_AUTHORITY_CONSUMED_FILESYSTEM_RENAME_PENDING_OR_COMPLETE" and
  .sendshadowpowclaim_authorized==false and .old_authority_retry_authorized==false and
  .new_one_shot_authority_required==true and
  .mempool_clearance.shadow_proof_count==0' "$CLEAR/requeue-intent.json"
assert_jq '.result=="REQUEUED_FOR_NEW_ONE_SHOT_AUTHORITY" and
  .queue_outcome.state=="queued" and .sendshadowpowclaim_call_count==0 and
  .queue_outcome.move_protocol=="hard-link-fsync-unlink-fsync-noreplace/v1" and
  .queue_outcome.no_clobber==true and .queue_outcome.same_inode==true and
  .queue_outcome.atomic_rename==false and .queue_outcome.already_complete==true and
  .queue_outcome.crash_link_reconciled==false and
  .old_authority_retry_authorized==false and .new_one_shot_audit_required==true and
  .new_one_shot_authority_required==true and .pause_preserved==true and
  .ordinary_pow_enabled==false and .recurring_worker_invoked==false' \
  "$CLEAR/requeue-complete.json"
assert_eq "$(find "$FLEET/free-claim/queue" -name '*.json' | wc -l | tr -d ' ')" 1
assert_fails 'rejected source was removed after requeue crash-link healing' \
  test -e "$REJECTED"
assert_eq "$(jq -r .send_calls "$FLEET/state/state.json")" 1

# A completion is valid only through the canonical, sidecar-verified intent
# receipt.  Idempotent completion must reject deletion, semantic tampering, and
# a completion whose intent digest was substituted and re-sidecarred.
INTENT_RECEIPT="$CLEAR/requeue-intent.json"
INTENT_SIDECAR="$INTENT_RECEIPT.sha256"
COMPLETE_RECEIPT="$CLEAR/requeue-complete.json"
COMPLETE_SIDECAR="$COMPLETE_RECEIPT.sha256"
mv -- "$INTENT_RECEIPT" "$INTENT_RECEIPT.saved"
mv -- "$INTENT_SIDECAR" "$INTENT_SIDECAR.saved"
assert_fails 'completed requeue rejects a missing canonical intent receipt' \
  companion_call "$FLEET" cleared requeue --run-dir "$CLEAR" \
    --authority "$CLEAR/AUTHORITY.json" --authority-sha256 "$REQUEUE_AUTH_SHA"
mv -- "$INTENT_RECEIPT.saved" "$INTENT_RECEIPT"
mv -- "$INTENT_SIDECAR.saved" "$INTENT_SIDECAR"

mv -- "$INTENT_RECEIPT" "$INTENT_RECEIPT.saved"
mv -- "$INTENT_SIDECAR" "$INTENT_SIDECAR.saved"
jq '.candidate_count=1' "$INTENT_RECEIPT.saved" >"$INTENT_RECEIPT"
rewrite_sidecar "$INTENT_RECEIPT"
assert_fails 'completed requeue rejects a semantically tampered intent receipt' \
  companion_call "$FLEET" cleared requeue --run-dir "$CLEAR" \
    --authority "$CLEAR/AUTHORITY.json" --authority-sha256 "$REQUEUE_AUTH_SHA"
rm -- "$INTENT_RECEIPT" "$INTENT_SIDECAR"
mv -- "$INTENT_RECEIPT.saved" "$INTENT_RECEIPT"
mv -- "$INTENT_SIDECAR.saved" "$INTENT_SIDECAR"

mv -- "$COMPLETE_RECEIPT" "$COMPLETE_RECEIPT.saved"
mv -- "$COMPLETE_SIDECAR" "$COMPLETE_SIDECAR.saved"
jq '.requeue_intent_sha256="ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"' \
  "$COMPLETE_RECEIPT.saved" >"$COMPLETE_RECEIPT"
rewrite_sidecar "$COMPLETE_RECEIPT"
assert_fails 'completed requeue rejects an intent digest substitution' \
  companion_call "$FLEET" cleared requeue --run-dir "$CLEAR" \
    --authority "$CLEAR/AUTHORITY.json" --authority-sha256 "$REQUEUE_AUTH_SHA"
rm -- "$COMPLETE_RECEIPT" "$COMPLETE_SIDECAR"
mv -- "$COMPLETE_RECEIPT.saved" "$COMPLETE_RECEIPT"
mv -- "$COMPLETE_SIDECAR.saved" "$COMPLETE_SIDECAR"
assert_eq "$(jq -r .send_calls "$FLEET/state/state.json")" 1

# The consumed source authority can never be executed again. Requeued state
# is acceptable only to a brand-new audit/run and its separately created
# authority file.
assert_fails 'old consumed financial authority remains nonretryable' \
  legacy_call "$FLEET" cleared execute --run-dir "$SOURCE" \
    --authority "$SOURCE/AUTHORITY.json" --authority-sha256 "$AUTH_SHA"
assert_eq "$(jq -r .send_calls "$FLEET/state/state.json")" 1
NEW_RUN="$FLEET/new-one-shot-run"
legacy_call "$FLEET" cleared audit --runtime-manifest "$FLEET/runtime.json" \
  --run-dir "$NEW_RUN" >"$FLEET/new-audit.out"
NEW_AUDIT_SHA=$(jq -r .audit_sha256 "$FLEET/new-audit.out")

# The transient slot must be clear after the fresh audit but before a new
# financial authority exists.  An occupied slot emits no clearance receipt.
WINDOW_COUNT=$(find "$CLEAR" -name 'new-authority-window-*.json' | wc -l | tr -d ' ')
mv -- "$INTENT_RECEIPT" "$INTENT_RECEIPT.saved"
mv -- "$INTENT_SIDECAR" "$INTENT_SIDECAR.saved"
assert_fails 'authority window rejects a missing canonical requeue intent' \
  companion_call "$FLEET" cleared audit-new-authority-window \
    --run-dir "$CLEAR" --authority "$CLEAR/AUTHORITY.json" \
    --authority-sha256 "$REQUEUE_AUTH_SHA" --one-shot-run "$NEW_RUN"
mv -- "$INTENT_RECEIPT.saved" "$INTENT_RECEIPT"
mv -- "$INTENT_SIDECAR.saved" "$INTENT_SIDECAR"
assert_eq "$(find "$CLEAR" -name 'new-authority-window-*.json' | wc -l | tr -d ' ')" \
  "$WINDOW_COUNT"

assert_fails 'authority window rejects a stale pre-lock pause baseline' \
  companion_prelock_transition_call "$FLEET" cleared "$PAUSE_MARKER" \
    audit-new-authority-window --run-dir "$CLEAR" \
    --authority "$CLEAR/AUTHORITY.json" --authority-sha256 "$REQUEUE_AUTH_SHA" \
    --one-shot-run "$NEW_RUN"
assert_eq "$(find "$CLEAR" -name 'new-authority-window-*.json' | wc -l | tr -d ' ')" \
  "$WINDOW_COUNT"

assert_fails 'authority-window postcondition failure publishes no PASS receipt' \
  companion_postcheck_drift_call "$FLEET" cleared audit-new-authority-window \
    --run-dir "$CLEAR" --authority "$CLEAR/AUTHORITY.json" \
    --authority-sha256 "$REQUEUE_AUTH_SHA" --one-shot-run "$NEW_RUN"
assert_eq "$(find "$CLEAR" -name 'new-authority-window-*.json' | wc -l | tr -d ' ')" \
  "$WINDOW_COUNT"

assert_fails 'occupied slot blocks the pre-authority window' \
  companion_call "$FLEET" mempool-blocked audit-new-authority-window \
    --run-dir "$CLEAR" --authority "$CLEAR/AUTHORITY.json" \
    --authority-sha256 "$REQUEUE_AUTH_SHA" --one-shot-run "$NEW_RUN"
assert_eq "$(find "$CLEAR" -name 'new-authority-window-*.json' | wc -l | tr -d ' ')" \
  "$WINDOW_COUNT"

# Even an otherwise exact authority is forbidden until the clearance receipt
# exists.  This fixture authority is deleted without use after proving the
# pre-authority ordering gate.
jq --arg digest "$NEW_AUDIT_SHA" \
  '.required_authority | .decision="authorize" | .audit_receipt_sha256=$digest' \
  "$NEW_RUN/audit.json" >"$NEW_RUN/AUTHORITY.json"
chmod 0600 "$NEW_RUN/AUTHORITY.json"
assert_fails 'new financial authority must be absent during the slot gate' \
  companion_call "$FLEET" cleared audit-new-authority-window \
    --run-dir "$CLEAR" --authority "$CLEAR/AUTHORITY.json" \
    --authority-sha256 "$REQUEUE_AUTH_SHA" --one-shot-run "$NEW_RUN"
rm -- "$NEW_RUN/AUTHORITY.json"
assert_eq "$(find "$CLEAR" -name 'new-authority-window-*.json' | wc -l | tr -d ' ')" \
  "$WINDOW_COUNT"

companion_call "$FLEET" cleared audit-new-authority-window \
  --run-dir "$CLEAR" --authority "$CLEAR/AUTHORITY.json" \
  --authority-sha256 "$REQUEUE_AUTH_SHA" --one-shot-run "$NEW_RUN" \
  >"$FLEET/new-authority-window.out"
WINDOW_NAME=$(jq -r .receipt "$FLEET/new-authority-window.out")
WINDOW_SHA=$(jq -r .sha256 "$FLEET/new-authority-window.out")
assert_eq "$(sha "$CLEAR/$WINDOW_NAME")" "$WINDOW_SHA"
assert_jq '.result=="SLOT_CLEAR_BEFORE_NEW_ONE_SHOT_AUTHORITY" and
  .one_shot_authority_present==false and
  .mempool_clearance.shadow_proof_count==0 and
  .mempool_clearance.shadow_proof_limit==1 and
  .mempool_clearance.slot_clear==true and
  .old_authority_retry_authorized==false and .new_call_budget==1 and
  .automatic_retry_authorized==false' "$CLEAR/$WINDOW_NAME"

# Only after the clearance receipt may the exact fresh one-shot authority be
# materialized.  Its semantic digest must match the pre-authority receipt.
jq --arg digest "$NEW_AUDIT_SHA" \
  '.required_authority | .decision="authorize" | .audit_receipt_sha256=$digest' \
  "$NEW_RUN/audit.json" >"$NEW_RUN/AUTHORITY.json"
chmod 0600 "$NEW_RUN/AUTHORITY.json"
NEW_AUTH_SEMANTIC_SHA=$(jq -cS . "$NEW_RUN/AUTHORITY.json" | shasum -a 256 | awk '{print $1}')
assert_eq "$(jq -r .one_shot_authority_semantic_sha256 "$CLEAR/$WINDOW_NAME")" \
  "$NEW_AUTH_SEMANTIC_SHA"
assert_jq '.kind=="node30-free-claim-one-shot-authority" and
  .decision=="authorize" and .single_submission_only==true and
  .ordinary_pow_authorized==false and .pause_removal_authorized==false' \
  "$NEW_RUN/AUTHORITY.json"
assert_eq "$(jq -r .send_calls "$FLEET/state/state.json")" 1

# The successor durable-requeue stage pins the exact reviewed companion and
# has no financial call site.  It permits the filesystem-only move while the
# QQP2 slot is occupied, but still requires an entirely new edge authority.
assert_eq "$(python3 - "$DURABLE" <<'PY'
import ast,sys
t=ast.parse(open(sys.argv[1]).read())
print(sum(isinstance(n,ast.Call) and len(n.args)>=2 and
          isinstance(n.args[1],ast.Constant) and
          n.args[1].value=='sendshadowpowclaim' for n in ast.walk(t)))
PY
)" 0

FLEET2=$(make_fixture fleet-durable)
SOURCE2="$FLEET2/source-run"
legacy_call "$FLEET2" mempool-reject audit \
  --runtime-manifest "$FLEET2/runtime.json" --run-dir "$SOURCE2" >"$FLEET2/audit.out"
AUDIT2_SHA=$(jq -r .audit_sha256 "$FLEET2/audit.out")
jq --arg digest "$AUDIT2_SHA" \
  '.required_authority | .decision="authorize" | .audit_receipt_sha256=$digest' \
  "$SOURCE2/audit.json" >"$SOURCE2/AUTHORITY.json"
chmod 0600 "$SOURCE2/AUTHORITY.json"
AUTH2_SHA=$(sha "$SOURCE2/AUTHORITY.json")
assert_fails 'second source consumes authority at deterministic rejection' \
  legacy_call "$FLEET2" mempool-reject execute --run-dir "$SOURCE2" \
    --authority "$SOURCE2/AUTHORITY.json" --authority-sha256 "$AUTH2_SHA"
legacy_call "$FLEET2" cleared reconcile --run-dir "$SOURCE2" \
  --authority "$SOURCE2/AUTHORITY.json" --authority-sha256 "$AUTH2_SHA" \
  >"$FLEET2/reconcile.out"
RECON2_NAME=$(jq -r .receipt "$FLEET2/reconcile.out")
RECON2_SHA=$(jq -r .sha256 "$FLEET2/reconcile.out")
companion_call "$FLEET2" cleared terminalize --run-dir "$SOURCE2" \
  --authority "$SOURCE2/AUTHORITY.json" --authority-sha256 "$AUTH2_SHA" \
  --reconcile-receipt "$SOURCE2/$RECON2_NAME" \
  --reconcile-sha256 "$RECON2_SHA" >"$FLEET2/terminalize.out"

# Live parity: the consumed item remains definitively rejected while a newer
# API item already occupies the paused ingress queue.  The successor must
# preserve and select the newer item, not overwrite it with the old inode.
REJECTED2=$(find "$FLEET2/free-claim/done" -name '*.rejected.json')
REJECTED2_SHA=$(sha "$REJECTED2")
NEW_QUEUE="$FLEET2/free-claim/queue/20260814T040000Z-cafebabe.json"
jq -cn '{attempts:1,ip:"newer-fixture",quantum_address:"qfixtureWitnessV16",
  submitted:"2026-08-14T04:00:00+00:00"}' >"$NEW_QUEUE"
chmod 0644 "$NEW_QUEUE"
NEW_QUEUE_SHA=$(sha "$NEW_QUEUE")
SIBLING_QUEUE="$FLEET2/free-claim/queue/20260904T053945Z-c6c62198.json"
jq -cn '{attempts:1,ip:"later-fixture",quantum_address:"qLaterUnselectedPayout",
  submitted:"2026-09-04T05:39:45+00:00"}' >"$SIBLING_QUEUE"
chmod 0644 "$SIBLING_QUEUE"
SIBLING_SHA=$(sha "$SIBLING_QUEUE")
SIBLING_INODE=$(stat -f %i "$SIBLING_QUEUE" 2>/dev/null || stat -c %i "$SIBLING_QUEUE")

DURABLE_RUN="$FLEET2/durable-requeue"
durable_call "$FLEET2" mempool-blocked audit --source-run "$SOURCE2" \
  --source-authority "$SOURCE2/AUTHORITY.json" \
  --source-authority-sha256 "$AUTH2_SHA" \
  --reconcile-receipt "$SOURCE2/$RECON2_NAME" \
  --reconcile-sha256 "$RECON2_SHA" --run-dir "$DURABLE_RUN" \
  >"$FLEET2/durable-audit.out"
DURABLE_AUDIT_SHA=$(jq -r .audit_sha256 "$FLEET2/durable-audit.out")
assert_jq '.result=="READY_FOR_SEPARATE_DURABLE_QUEUE_AUTHORITY" and
  .mutation_performed==false and .snapshot.candidate_count==0 and
  .snapshot.queue_strategy=="preserve_existing_queued_item" and
  .snapshot.queue.state=="queued" and
  (.snapshot.queue.ingress_items|length)==2 and
  .snapshot.queue.item.basename=="20260814T040000Z-cafebabe.json" and
  .snapshot.source_rejected.state=="rejected" and
  .snapshot.mempool_observation.shadow_proof_count==1 and
  .snapshot.mempool_observation.slot_clear==false and
  .required_authority.slot_clear_required_for_requeue==false and
  .required_authority.observed_shadow_proof_count==1 and
  .required_authority.queue_strategy=="preserve_existing_queued_item" and
  .required_authority.filesystem_move_required==false and
  .required_authority.preexisting_queue_preserved==true and
  .required_authority.sendshadowpowclaim_authorized==false and
  .required_authority.old_authority_retry_authorized==false and
  .required_authority.new_edge_one_shot_audit_required==true and
  .required_authority.new_edge_financial_authority_required==true' \
  "$DURABLE_RUN/durable-requeue-audit.json"
jq --arg digest "$DURABLE_AUDIT_SHA" \
  '.required_authority | .decision="authorize" | .audit_receipt_sha256=$digest' \
  "$DURABLE_RUN/durable-requeue-audit.json" >"$DURABLE_RUN/AUTHORITY.json"
chmod 0600 "$DURABLE_RUN/AUTHORITY.json"
DURABLE_AUTH_SHA=$(sha "$DURABLE_RUN/AUTHORITY.json")

jq '.slot_clear_required_for_requeue=true' "$DURABLE_RUN/AUTHORITY.json" \
  >"$DURABLE_RUN/bad-authority.json"
chmod 0600 "$DURABLE_RUN/bad-authority.json"
assert_fails 'durable authority cannot be changed into a slot reservation' \
  durable_call "$FLEET2" mempool-blocked requeue --run-dir "$DURABLE_RUN" \
    --authority "$DURABLE_RUN/bad-authority.json" \
    --authority-sha256 "$(sha "$DURABLE_RUN/bad-authority.json")"
assert_fails 'bad durable authority publishes no intent' \
  test -e "$DURABLE_RUN/durable-requeue-intent.json"

# The same already-consumed nonfinancial intent resumes while the slot is
# occupied.  Occupancy is evidence, not a filesystem-move prerequisite.
durable_call "$FLEET2" mempool-blocked requeue --run-dir "$DURABLE_RUN" \
  --authority "$DURABLE_RUN/AUTHORITY.json" \
  --authority-sha256 "$DURABLE_AUTH_SHA" >"$FLEET2/durable-requeue.out"
assert_jq '.state=="DURABLE_QUEUE_AUTHORITY_CONSUMED_SELECTION_PENDING_OR_COMPLETE" and
  .queue_strategy=="preserve_existing_queued_item" and
  .filesystem_move_required==false and .preexisting_queue_preserved==true and
  .slot_clear_required_for_requeue==false and .candidate_count==0 and
  .sendshadowpowclaim_authorized==false and
  .old_authority_retry_authorized==false and
  .new_edge_financial_authority_required==true' \
  "$DURABLE_RUN/durable-requeue-intent.json"
assert_jq '.result=="DURABLE_QUEUE_SELECTION_COMPLETE_INDEPENDENT_OF_TRANSIENT_SLOT" and
  .queue_strategy=="preserve_existing_queued_item" and
  .filesystem_move_performed==false and .preexisting_queue_preserved==true and
  .pre_move_mempool_observation.shadow_proof_count==1 and
  .pre_move_mempool_observation.slot_clear==false and
  .slot_clear_required_for_requeue==false and
  .queue_outcome.state=="queued" and .queue_outcome.no_clobber==true and
  .queue_outcome.same_inode==true and .queue_outcome.atomic_rename==false and
  .queue_outcome.move_protocol=="preexisting-queue-preservation/v1" and
  .sendshadowpowclaim_call_count==0 and
  .old_authority_retry_authorized==false and
  .new_edge_one_shot_audit_required==true and
  .new_edge_financial_authority_required==true and
  .pause_preserved==true and .ordinary_pow_enabled==false and
  .recurring_worker_invoked==false' "$DURABLE_RUN/durable-requeue-complete.json"
assert_eq "$(sha "$REJECTED2")" "$REJECTED2_SHA"
assert_eq "$(sha "$NEW_QUEUE")" "$NEW_QUEUE_SHA"
assert_eq "$(sha "$SIBLING_QUEUE")" "$SIBLING_SHA"
assert_eq "$(jq -r .send_calls "$FLEET2/state/state.json")" 1

DINT="$DURABLE_RUN/durable-requeue-intent.json"
DINT_SIDE="$DINT.sha256"
mv -- "$DINT" "$DINT.saved"; mv -- "$DINT_SIDE" "$DINT_SIDE.saved"
assert_fails 'durable completion rejects missing canonical intent' \
  durable_call "$FLEET2" mempool-blocked requeue --run-dir "$DURABLE_RUN" \
    --authority "$DURABLE_RUN/AUTHORITY.json" \
    --authority-sha256 "$DURABLE_AUTH_SHA"
mv -- "$DINT.saved" "$DINT"; mv -- "$DINT_SIDE.saved" "$DINT_SIDE"
durable_call "$FLEET2" mempool-blocked requeue --run-dir "$DURABLE_RUN" \
  --authority "$DURABLE_RUN/AUTHORITY.json" \
  --authority-sha256 "$DURABLE_AUTH_SHA" >"$FLEET2/durable-again.out"
assert_jq '.already_complete==true and
  .result=="DURABLE_QUEUE_SELECTION_COMPLETE_INDEPENDENT_OF_TRANSIENT_SLOT"' \
  "$FLEET2/durable-again.out"

# A financial authority can be reviewed while the slot is occupied.  Repeated
# refill during the locked dynamic rebind consumes no authority and makes no
# call; that run is permanently discarded and cannot later be executed.
EDGE_ABORT="$FLEET2/edge-refill-abort"
edge_call "$FLEET2" mempool-blocked audit --durable-run "$DURABLE_RUN" \
  --durable-authority "$DURABLE_RUN/AUTHORITY.json" \
  --durable-authority-sha256 "$DURABLE_AUTH_SHA" --run-dir "$EDGE_ABORT" \
  --max-wait-seconds 60 --poll-milliseconds 50 >"$FLEET2/edge-abort-audit.out"
EDGE_ABORT_AUDIT_SHA=$(jq -r .audit_sha256 "$FLEET2/edge-abort-audit.out")
assert_jq '.result=="READY_FOR_PREAUTHORIZED_DYNAMIC_EDGE" and
  .mutation_performed==false and
  .required_authority.dynamic_tip_rebind_authorized==true and
  .required_authority.dynamic_qqp2_work_rebind_authorized==true and
  .required_authority.slot_clear_immediately_before_intent_required==true and
  .required_authority.single_invocation_only==true and
  .required_authority.single_submission_only==true and
  .required_authority.maximum_fee_blk=="0.00028700" and
  .required_authority.ordinary_pow_authorized==false and
  .required_authority.pause_removal_authorized==false' "$EDGE_ABORT/edge-audit.json"
jq --arg digest "$EDGE_ABORT_AUDIT_SHA" \
  '.required_authority | .decision="authorize" | .audit_receipt_sha256=$digest' \
  "$EDGE_ABORT/edge-audit.json" >"$EDGE_ABORT/AUTHORITY.json"
chmod 0600 "$EDGE_ABORT/AUTHORITY.json"
EDGE_ABORT_AUTH_SHA=$(sha "$EDGE_ABORT/AUTHORITY.json")
edge_call "$FLEET2" edge-refill-during-rebind execute --run-dir "$EDGE_ABORT" \
  --authority "$EDGE_ABORT/AUTHORITY.json" \
  --authority-sha256 "$EDGE_ABORT_AUTH_SHA" >"$FLEET2/edge-abort.out"
assert_jq '.result=="NO_INTENT_EDGE_WINDOW_EXHAUSTED_AUTHORITY_DISCARDED" and
  .intent_published==false and .sendshadowpowclaim_call_count==0 and
  .authority_consumed==false and .authority_reuse_authorized==false and
  .fresh_edge_audit_and_authority_required==true and
  .clear_rebind_attempts==4' "$EDGE_ABORT/edge-aborted.json"
assert_fails 'refill abort publishes no financial intent' test -e "$EDGE_ABORT/intent.json"
assert_eq "$(jq -r .send_calls "$FLEET2/state/state.json")" 1
assert_fails 'discarded edge run cannot execute later' \
  edge_call "$FLEET2" edge-happy execute --run-dir "$EDGE_ABORT" \
    --authority "$EDGE_ABORT/AUTHORITY.json" \
    --authority-sha256 "$EDGE_ABORT_AUTH_SHA"
jq 'del(.edge_mempool_calls)' "$FLEET2/state/state.json" \
  >"$FLEET2/state/next" && mv "$FLEET2/state/next" "$FLEET2/state/state.json"

# A fresh edge audit/authority waits through observed occupancy, binds the
# current tip/work/input set under all locks, publishes intent, and makes the
# only new financial call.  Confirmation preserves the pause and role.
EDGE_RUN="$FLEET2/edge-success"
edge_call "$FLEET2" mempool-blocked audit --durable-run "$DURABLE_RUN" \
  --durable-authority "$DURABLE_RUN/AUTHORITY.json" \
  --durable-authority-sha256 "$DURABLE_AUTH_SHA" --run-dir "$EDGE_RUN" \
  --max-wait-seconds 2 --poll-milliseconds 50 >"$FLEET2/edge-audit.out"
EDGE_AUDIT_SHA=$(jq -r .audit_sha256 "$FLEET2/edge-audit.out")
jq --arg digest "$EDGE_AUDIT_SHA" \
  '.required_authority | .decision="authorize" | .audit_receipt_sha256=$digest' \
  "$EDGE_RUN/edge-audit.json" >"$EDGE_RUN/AUTHORITY.json"
chmod 0600 "$EDGE_RUN/AUTHORITY.json"
EDGE_AUTH_SHA=$(sha "$EDGE_RUN/AUTHORITY.json")
jq '.maximum_tries=1999999' "$EDGE_RUN/AUTHORITY.json" >"$EDGE_RUN/bad-authority.json"
chmod 0600 "$EDGE_RUN/bad-authority.json"
assert_fails 'modified financial authority fails before intent' \
  edge_call "$FLEET2" edge-happy execute --run-dir "$EDGE_RUN" \
    --authority "$EDGE_RUN/bad-authority.json" \
    --authority-sha256 "$(sha "$EDGE_RUN/bad-authority.json")"
assert_fails 'bad edge authority publishes no intent' test -e "$EDGE_RUN/intent.json"
mv "$SIBLING_QUEUE" "$FLEET2/sibling.saved"
cp "$FLEET2/sibling.saved" "$SIBLING_QUEUE"
chmod 0644 "$SIBLING_QUEUE"
assert_fails 'unselected inode substitution refuses edge before intent' \
  edge_call "$FLEET2" edge-happy execute --run-dir "$EDGE_RUN" \
    --authority "$EDGE_RUN/AUTHORITY.json" --authority-sha256 "$EDGE_AUTH_SHA"
assert_fails 'sibling substitution publishes no financial intent' test -e "$EDGE_RUN/intent.json"
rm "$SIBLING_QUEUE"
mv "$FLEET2/sibling.saved" "$SIBLING_QUEUE"
edge_call "$FLEET2" edge-blocked-then-clear execute --run-dir "$EDGE_RUN" \
  --authority "$EDGE_RUN/AUTHORITY.json" --authority-sha256 "$EDGE_AUTH_SHA" \
  >"$FLEET2/edge-execute.out"
assert_jq '.state=="EDGE_AUTHORITY_CONSUMED_RPC_PENDING_OR_COMPLETE" and
  .dynamic_rebind.mempool_clearance.shadow_proof_count==0 and
  .dynamic_rebind.mempool_clearance.slot_clear==true and
  .dynamic_rebind.mempool_observations==3 and
  .dynamic_rebind.clear_rebind_attempts==1 and
  .rpc_method=="sendshadowpowclaim" and .call_budget==1 and
  .calls_completed_before_intent==0' "$EDGE_RUN/intent.json"
assert_jq '.result=="EXACT_DYNAMIC_EDGE_BROADCAST" and
  .sendshadowpowclaim_call_count==1 and .proof_override_used==false and
  .pause_preserved==true and .ordinary_pow_enabled==false and
  .recurring_worker_invoked==false and .queue_outcome.state=="broadcast"' \
  "$EDGE_RUN/broadcast-complete.json"
assert_eq "$(jq -r .send_calls "$FLEET2/state/state.json")" 2

# Neither the unselected API entry nor historical rejection is moved or
# rewritten by broadcast, pending reconciliation, or terminal settlement.
assert_eq "$(sha "$SIBLING_QUEUE")" "$SIBLING_SHA"
assert_eq "$(stat -f %i "$SIBLING_QUEUE" 2>/dev/null || stat -c %i "$SIBLING_QUEUE")" "$SIBLING_INODE"
assert_eq "$(sha "$REJECTED2")" "$REJECTED2_SHA"
assert_fails 'consumed edge run can never execute twice' \
  edge_call "$FLEET2" edge-happy execute --run-dir "$EDGE_RUN" \
    --authority "$EDGE_RUN/AUTHORITY.json" --authority-sha256 "$EDGE_AUTH_SHA"
# Ordinary API arrival during confirmation cannot stall settlement of the
# consumed call and is never submitted by this one-shot.
ARRIVAL_QUEUE="$FLEET2/free-claim/queue/20260909T150000Z-cafef00d.json"
jq -cn '{attempts:1,ip:"arrival-fixture",quantum_address:"qNewArrival",
  submitted:"2026-09-09T15:00:00+00:00"}' >"$ARRIVAL_QUEUE"
chmod 0644 "$ARRIVAL_QUEUE"
ARRIVAL_SHA=$(sha "$ARRIVAL_QUEUE")
edge_call "$FLEET2" edge-happy monitor --run-dir "$EDGE_RUN" \
  --authority "$EDGE_RUN/AUTHORITY.json" --authority-sha256 "$EDGE_AUTH_SHA" \
  >"$FLEET2/edge-pending.out"
EDGE_PENDING_RECEIPT="$EDGE_RUN/$(jq -r .receipt "$FLEET2/edge-pending.out")"
assert_jq '.result=="DYNAMIC_EDGE_BROADCAST_PENDING_ACTIVE_CHAIN_CONFIRMATION" and
  .confirmations==0 and .pause_preserved==true and .retry_authorized==false' \
  "$EDGE_PENDING_RECEIPT"
jq '.confirmed=true' "$FLEET2/state/state.json" >"$FLEET2/state/next" && \
  mv "$FLEET2/state/next" "$FLEET2/state/state.json"
edge_call "$FLEET2" edge-happy monitor --run-dir "$EDGE_RUN" \
  --authority "$EDGE_RUN/AUTHORITY.json" --authority-sha256 "$EDGE_AUTH_SHA" \
  >"$FLEET2/edge-terminal.out"
assert_jq '.result=="CONFIRMED_DYNAMIC_EDGE_QUANTUM_PAYOUT" and
  .confirmations==6 and .queue_outcome.state=="confirmed" and
  .pause_preserved==true and .ordinary_pow_enabled==false and
  .pos_active==true and .recurring_worker_invoked==false' "$EDGE_RUN/terminal.json"
assert_eq "$(jq -r .send_calls "$FLEET2/state/state.json")" 2
assert_eq "$(sha "$SIBLING_QUEUE")" "$SIBLING_SHA"
assert_eq "$(stat -f %i "$SIBLING_QUEUE" 2>/dev/null || stat -c %i "$SIBLING_QUEUE")" "$SIBLING_INODE"
assert_eq "$(sha "$REJECTED2")" "$REJECTED2_SHA"
assert_eq "$(sha "$ARRIVAL_QUEUE")" "$ARRIVAL_SHA"

printf 'PASS: %d hostile node30 deterministic-rejection/requeue assertions\n' "$COUNT"
