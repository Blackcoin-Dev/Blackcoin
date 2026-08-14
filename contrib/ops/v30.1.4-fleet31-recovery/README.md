# Installed-v30.1.4 fleet31 two-phase quarantine recovery

This fleet-owned operator package handles the 31 regular-PoW wallets on nodes
1–29 and 31–32. Node30 is structurally excluded. It operates only against the
already-installed, signed v30.1.4 source identity recorded in the runtime
manifest. It does not deploy Core, change Compose, unlock wallets, change PoW
or PoS intent, reindex, rewind, repair, recover, or use generic transaction
RPCs.

The only live wallet-mutating RPC is `resolveallshadowpowclaims` with
`commit_and_broadcast`, and only after a separate exact Phase-B authority
receipt. This follow-up artifact is structurally Phase-B-only: live `audit`,
`phase-a`, and `reconcile-a` entrypoints fail before locks, transport, or RPC.
Those entrypoints remain executable only with the sealed offline fixture so the
exact signed predecessor's `sign_only` receipt contract can be hostile-tested.
The tool never contains or calls
`commitshadowpowclaimresolution`, `sendrawtransaction`, `abandontransaction`,
`bumpfee`, `setpowmining`, or `walletpassphrase`.

No live runtime identity, authority receipt, wallet secret, raw transaction,
or live execution evidence is checked into this directory. The operator must
supply an owner-only mode-0600 runtime manifest and authority files. The run
directory must be a canonical owner-only mode-0700 directory.

## Fixed authority boundary

The exact regular-node set is `1-29,31,32`; node30 is excluded. Compose service
labels are `node01` through `node32`. Node1's container is
`blackcoin-v4-gui`; the other regular-node containers are
`blackcoin-v4-gui-N`. For the sole unnamed wallet (`""`), the transport omits
`-rpcwallet` entirely.

The fee cap is exactly `0.00019100 BLK` per node and `0.00592100 BLK` for all
31 nodes. The Phase-B authority must bind this exact user order:

```
fix all of the quarantined issues even if you have to pay a small fee to fix it on each node. all issues must be resolved
```

Its SHA256 is
`0252ebcc3dc2ca8a20e8b9708738c30f9c32f6b0dea213bb8937467b2dab2dff`.
The authority also acknowledges that broadcast is irreversible and that
confirmation may permanently forfeit the retained QQP2 proof's chance at a
future quantum payout.

## Workflow

The already-complete Phase A was produced by the exact signed predecessor tool
whose hash is sealed in this follow-up. The following audit and Phase-A
description documents the required predecessor receipt chain; it is not a live
invocation surface in this artifact.

`audit` takes a stable read-only cut for every regular node. It requires the
exact installed runtime, main chain, no IBD or pruning, peers, the exact sole
wallet, normal unlock, active PoS with positive weight, enabled PoW intent,
exactly one blocking quarantine, and no ambiguous recovery database state. A
normal tip change retries the complete read-only node envelope; runtime drift
fails immediately.

`phase-a` requires a separate mode-0600 authority copied from the audit's
`required_phase_a_authority` template and bound to the exact `audit.json`
SHA256. It writes a no-clobber intent before each `sign_only` call. Each result
must prove one persisted, unconfirmed, non-relayable 191-vbyte signed draft.
Phase A never grants relay authority or broadcasts.

`reconcile-a` is read-only crash handling. It never blindly repeats an
unmatched mutation. A post-sign observation preserves the original intent
plan/component separately from the later reconciliation plan/component and
explicitly states that no RPC acknowledgement is claimed. The live Phase-A
receipt produced by the signed predecessor tool is accepted only after the
complete audit, intent, 31 per-node result, aggregate cap, runtime, source, and
sidecar chain is independently validated. In live mode, only the exact
immutable predecessor tool hash is accepted.

`phase-b-preview` revalidates all 31 durable Phase-A drafts. For every node it
separates immutable signed-byte identity from mutable confirmation metadata,
reads the exact active-chain anchor with `gettxout(..., false)`, proves the
one-input/one-output same-script recycle, and independently computes
`input - output == 0.00019100 BLK`. It also rechecks peers, installed network
identity, normal unlock, PoS coherence, and the current one-claim PoW
quarantine. Node27 may be recorded only as the exact temporary
`claim-not-terminal/live` branch and is assigned to the final deferred wave.
If the exact signed resolution or an authorized original claim is already the
unique active-chain anchor spender before the preview, the node is instead
bound as `ALREADY_RESOLVED_ON_ACTIVE_CHAIN`. That terminal node receives no
recovery relay or fee authority. The authority binds the exact terminal node
set, remaining relay node set, and remaining maximum fee.

```sh
./fleet31_recovery.py phase-b-preview \
  --run-dir /absolute/private/run-directory
```

The separate mode-0600 Phase-B authority is copied from the preview's
`required_phase_b_authority` template. It must replace the preview placeholder
with the exact `phase-b-preview.json` SHA256 and preserve every node, fee,
user-order, risk, tool, runtime, source, signed-byte, wave, and deferred-node
binding.

Runtime receipts distinguish stable installed identity from restart metadata.
Image reference/ID, executable hashes, Compose service, logical container,
wallet, health, and node identity remain exact. A changed container ID or start
time is accepted only as a typed same-product restart after a fresh inspect;
every RPC cut is pinned to that freshly inspected container ID, and recreation
during a cut fails.

Phase B executes these exact waves in order:

```
1:  [16]
2:  [1,2,3,4]
3:  [5,6,7,8]
4:  [9,10,11,12]
5:  [13,14,15,17]
6:  [18,19,20,21]
7:  [22,23,24,25]
8:  [26,28,29]
9:  [31,32]
10: [27]
```

Each node receives a durable no-clobber intent before the only Phase-B
mutation:

```json
{
  "action": "commit_and_broadcast",
  "expected_plan_id": "<fresh exact plan>",
  "acknowledge_fee_and_conflict_risk": true,
  "max_fee_per_resolution": "0.00019100",
  "max_total_fee": "0.00019100"
}
```

Invoke one wave at a time. The final node27 bounds may be increased only up to
the tool's 60-attempt/60-second limits; the defaults are 12 attempts and five
seconds.

```sh
./fleet31_recovery.py phase-b --wave 1 \
  --run-dir /absolute/private/run-directory \
  --authority /absolute/private/phase-b-authority.json \
  --authority-sha256 <exact-authority-sha256>
```

Repeat with waves 2 through 10 only after each prior wave receipt verifies.
The tool validates the complete 31-node predecessor and preview chain before
any wave mutation. Existing results, acknowledgements, and wave receipts are
accepted only after exact authority-chain revalidation.

## Crash and race behavior

The exact RPC return is written as an acknowledgement before any fallible
post-call read. Complete responses must bind the intent plan, tip, height,
wallet generation, fee, component, returned raw bytes, relay counters, and
nonambiguous durable state. A structured post-persistence stop is recorded as
durable relay authority pending and is never remutated.

An RPC error after the durable intent is never retried directly. `reconcile-b`
first serializes behind Core's recovery mutex, then rereads the exact signed
bytes, wallet relay metadata, active-chain anchor, and preview. A new bounded
attempt is permitted only after an exact no-authority receipt. Durable relay
authority, mempool presence, ambiguity, or an untyped state always stops
mutation. Installed v30.1.4 cannot reconstruct the original acknowledged
plan/tip/generation receipt after a lost response following durable grant; the
tool preserves that gap and does not invent an acknowledgement.

A valid structured pending acknowledgement is never discarded: later mempool
or active-chain evidence is bound to the exact intent and acknowledgement and
finishes as `ACK_PLUS_READ_ONLY_OBSERVATION`. Only an ambiguous or unclassified
response lacks a usable acknowledgement; if one later reaches an exact
active-chain terminal state it can finish observation-only, with the unusable
response identity preserved and no retry.

If the exact authorized resolution or an authorized original claim is proven
to be the unique active-chain spender of the exact anchor, the tool may record
an observation-only terminal outcome. It does not relabel that observation as
an RPC acknowledgement. This lets later nodes continue without retrying an
already-resolved component.

Receipts and SHA256 sidecars are append-only, mode 0600, and no-clobber. A
power loss after the final hard link but before temporary-link removal is
healed only when exactly one correctly named publisher temporary link refers
to the same secure inode. A missing sidecar is reconstructed only for secure,
valid JSON bytes; an existing malformed or mismatched sidecar is never
replaced. Mutation locks reject symlinks, extra hard links, wrong owners,
wrong modes, nonregular files, and inode substitution.

## Final monitoring

`monitor` is read-only and requires the exact complete Phase-B receipt chain.
For every node it pins runtime, wallet, installed network, peers, chain, and
recovery inventory. It requires exactly one authorized transaction to be the
active-chain spender of the exact anchor, zero blocking quarantines, PoW state
`hashing`, positive hashrate, and a typed claim-submission increment from the
Phase-B preview in the same process epoch. If the daemon restarted, the counter
is evaluated from its documented reset epoch and must be positive. Configuration
flags alone are not success evidence.

```sh
./fleet31_recovery.py monitor \
  --run-dir /absolute/private/run-directory \
  --samples 12 --interval 10
```

## Offline validation

Run `tests/run.sh`. The exact sealed nonroot mock is the only accepted test
transport. The suite is offline: it contacts no Docker daemon, SSH host,
wallet, node, or network. It covers all authority and source/runtime bindings,
node30 exclusion, stable tip retries, independent fee proof, exact returned
bytes, full Phase-A receipt-chain validation, post-persistence stops,
unknown-result no-grant retry, durable-authority nonretry, original-claim
active-chain resolution, exact pre-preview terminal fee exclusion, terminal
reorg rejection, same-product restart continuation, stable runtime drift and
mid-cut recreation rejection, ACK-preserving and observation-only terminal
closure, receipt/sidecar crash healing, no-clobber behavior, wave ordering,
idempotent receipt validation, and static rejection of targeted or generic
transaction RPCs.
