# Installed-v30.1.4 dynamic PoW-quarantine recurrence recovery

This fleet-owned controller resolves only the regular-PoW wallets that are
quarantined at a fresh, stable audit cut. It examines nodes 1–29 and 31–32;
node30 is structurally excluded. The selected set is never compiled into the
tool. A later recurrence requires a new run directory, audit, and authorities.

The controller imports and verifies the exact signed fleet31 primitive at
`../v30.1.4-fleet31-recovery/fleet31_recovery.py`, SHA256
`eb529eb87ad1abc740345ddf5e06e0bbb8ae60b264b0d257fc95bad248a72680`.
That primitive supplies the secure transport, append-only receipts, mutation
locks, independent signed-byte fee proof, exact acknowledgement handling,
crash reconciliation, and operational monitor. A missing or different base
tool is fatal before fleet contact.

This package does not deploy software, alter Compose, unlock a wallet, change
PoW or PoS intent, reindex, rewind, repair a wallet, or use a generic or
targeted transaction RPC. Its only wallet mutations are
`resolveallshadowpowclaims` with `sign_only` in Phase A and
`commit_and_broadcast` in Phase B.

## Exact authority boundary

Each selected node is independently capped at `0.00019100 BLK`. The cycle cap
is exactly `selected-node count × 0.00019100 BLK`. Self-cleared nodes receive
no signing, relay, or fee authority. A node that becomes blocked after the
audit is not silently added; it belongs to a new cycle.

Both authorities bind this exact user order:

```
fix all of the quarantined issues even if you have to pay a small fee to fix it on each node. all issues must be resolved
```

Its SHA256 is
`0252ebcc3dc2ca8a20e8b9708738c30f9c32f6b0dea213bb8937467b2dab2dff`.
The authorities also acknowledge that a confirmed resolution can permanently
forfeit a revalidating QQP2 proof's chance at a quantum payout.

## Dynamic audit

Prepare an owner-only mode-0600 runtime manifest from
`RUNTIME-MANIFEST.example.json`. It must identify all 31 regular nodes in
ascending order, the exact installed v30.1.4 image and executable hashes, the
sole wallet selector, and the global and per-node lock paths. The run directory
must be absolute, canonical, owner-only, and mode 0700.

```sh
./dynamic_recurrence_recovery.py audit \
  --runtime-manifest /absolute/private/runtime-manifest.json \
  --run-dir /absolute/private/new-cycle
```

The audit brackets a stable chain and runtime cut for every regular node. A
selected node must have enabled PoW intent, zero hashrate, exactly one hot
blocking/actionable quarantine, no indeterminate or ambiguous state, peers,
normal unlock, and coherent active PoS. A clear node must have positive
hashrate, zero hot blockers, no ambiguity, and state `ready`,
`claim_in_flight`, or `hashing`. Historical recovery inventory is not confused
with the public mining hot-blocker count.

`audit.json` binds the exact selected and clear sets, all 31 census rows, the
per-node cap, the computed aggregate cap, and a Phase-A authority template.
If no node is blocked, the command stops because no fee authority is needed.

## Phase A: persist exact non-relayable drafts

Copy `required_phase_a_authority` from `audit.json` to a separate mode-0600
file. Replace `REPLACE_WITH_AUDIT_SHA256` with the adjacent audit sidecar's
exact digest. Do not change the selected or clear set, cap, hashes, order, or
acknowledgements.

```sh
./dynamic_recurrence_recovery.py phase-a \
  --run-dir /absolute/private/new-cycle \
  --authority /absolute/private/phase-a-authority.json \
  --authority-sha256 <exact-authority-sha256>
```

Under the recovery/runtime locks, Phase A rereads the full 31-node census
before its first intent. Any new blocker or self-clear stops the cycle before
signing. Each selected node then receives a fresh runtime-, wallet-, tip-,
generation-, plan-, component-, and fee-bound envelope. A lagging recovery
inventory causes a full read-only retry; it can never produce an intent from a
mixed cut. The tool writes a durable no-clobber intent before one `sign_only`
call and proves the retained draft is exact, unconfirmed, persisted, and not
relay-authorized. There is no Phase-B authority in this stage.

After an unknown Phase-A response, never rerun `phase-a`. Use the read-only
`reconcile-a` command with the same exact authority. It can attribute only an
observed exact persisted non-relay draft to the prior intent; it does not
invent an acknowledged plan and never repeats the mutation.

## Phase B: exact signed bytes, separate authority, singleton waves

```sh
./dynamic_recurrence_recovery.py phase-b-preview \
  --run-dir /absolute/private/new-cycle
```

The preview validates the complete Phase-A receipt chain and independently
proves each signed transaction's exact anchor, one-input/one-output shape,
script, immutable bytes, and actual `0.00019100 BLK` fee. An already-confirmed
authorized winner is terminal and excluded from relay and remaining-fee
authority. Every unresolved selected node is assigned its own singleton wave.

Copy `required_phase_b_authority` from `phase-b-preview.json` to a second
mode-0600 authority file. Replace its preview placeholder with the exact
sidecar digest and preserve every field.

```sh
./dynamic_recurrence_recovery.py phase-b --wave 1 \
  --run-dir /absolute/private/new-cycle \
  --authority /absolute/private/phase-b-authority.json \
  --authority-sha256 <exact-authority-sha256>
```

Run each singleton wave in order. Before any RPC, the inherited executor
revalidates the full authority and receipt chain, current installed identity,
normal unlock, peers, PoS, exact signed bytes, independent fee proof, and a
fresh reusable plan. It writes a durable intent before the sole
`commit_and_broadcast` call and preserves the exact RPC acknowledgement before
fallible observation reads. Unknown, ambiguous, or already-authorized states
are never blindly retried. Use `reconcile-b` with the same authority for
read-only reconciliation.

The aggregate result means only that the exact audited subset completed its
authority-bound recovery. It does not claim that no later recurrence exists
elsewhere in the fleet.

## Monitoring and repeated cycles

```sh
./dynamic_recurrence_recovery.py monitor \
  --run-dir /absolute/private/new-cycle --samples 12 --interval 10
```

The monitor is read-only. For each selected node it requires an authorized
transaction to be the unique active-chain anchor spender, positive hashrate,
zero public PoW hot blockers, coherent runtime/wallet/network/peer/PoS state,
and an operational state of `ready` or `claim_in_flight`. It requires at least
one fresh aggregate claim submission without falsely claiming an immediate
increment on every node.

After completing a cycle, run a new full read-only audit in a new run directory
to discover the then-current subset. Never reuse or edit a prior authority to
cover a later recurrence.

## Offline validation

`tests/run.sh` uses only the exact hash-bound local mock. It contacts no SSH
host, Docker daemon, wallet, node, or network. The hostile suite covers dynamic
selection and cap math, exact selected-only Phase A and Phase B, authority
drift, singleton-wave ordering, active-chain monitoring, later different
subsets with identical bytes, new-blocker and self-clear races before the first
intent, lagging recovery-inventory retry, lost Phase-A response reconciliation,
and node30 exclusion.
