# Installed-v30.1.4 node30 retained-claim recovery

This fleet-only package resolves node30's one retained legacy QQP2 claim while
preserving three independent invariants: normal PoS remains active, ordinary
PoW remains disabled, and the Free-Claim pause marker remains installed. It
does not release the Free-Claim worker, invoke that worker, modify its queue,
or change node30's role. The public Core/release lane is outside this package.

The package is bound to signed installed source commit
`13262151077cce3f72d07d17dc7725b2b6a8e1ab`, tree
`a6f7757c34b70fab841905765462d6769112d049`, and signer fingerprint
`SHA256:jAkpBudDw+ntWHSUx3e1KY+czAFjnlaPxQtRFtptL70`. It also records the exact
confidential read-only predecessor receipt SHA256
`ca084d6d76fb67532fd65ff8b44943bc3a8c12f589708a11872417223066eec9`
and the exact user-order SHA256
`0252ebcc3dc2ca8a20e8b9708738c30f9c32f6b0dea213bb8937467b2dab2dff`.
No live runtime identities, wallet secrets, addresses, outpoints, signed bytes,
or executable financial authority are checked in.

## Runtime contract

The operator supplies an owner-only mode-0600 manifest. Live execution
requires root, `/usr/bin/docker` with its exact sealed hash, the installed
image and executable hashes, the unnamed node30 wallet, exact production
Free-Claim paths, and the complete reviewed lock set. The pause marker,
wrapper, and preserved worker must retain their exact hashes. The tool pins
wallet RPCs to the inspected container ID and stops on runtime replacement.

The test transport is accepted only for nonroot execution and only when its
repository fixture bytes match the hash compiled into the tool. Live mode
cannot substitute a test transport.

## Phase sequence

`audit` is read-only. It requires a healthy, peered, synchronized, unpruned
main-chain node; normal unlock; active PoS with positive weight; ordinary PoW
disabled with zero hashrate; one nonambiguous retained-claim blocker; an
authenticated unspent anchor; and one exact 191-vbyte recovery capped at
`0.00019100 BLK` at `100 atoms/vB`. It emits a mode-0600 audit and a complete
Phase-A authority template.

`phase-a` accepts only a separately created mode-0600 authority whose supplied
SHA256 binds the audit, runtime, tool, shared primitive, installed source,
exact user order, exact fee and risk acknowledgements. It writes and fsyncs a
no-clobber intent before the sole Phase-A mutation:

```json
{"action":"sign_only","expected_plan_id":"<fresh-plan>","acknowledge_fee_and_conflict_risk":true,"fee_rate":"100","max_fee_per_resolution":"0.00019100","max_total_fee":"0.00019100"}
```

The result must be one exact persisted nonrelayable signed transaction. A
missing RPC response is never retried. `reconcile-a` can observe the exact
persisted bytes after an unmatched intent; otherwise it requires a new audit
and authority.

`phase-b-preview` is read-only and binds the exact Phase-A signed transaction,
fresh plan, runtime, PoS state, disabled ordinary-PoW role, and pause artifacts.
It emits the separate Phase-B authority template.

`phase-b` accepts only a distinct mode-0600 authority bound to the Phase-A and
Phase-B-preview receipt hashes and the exact signed-transaction identity. It
writes and fsyncs a no-clobber intent before the only Phase-B mutation:

```json
{"action":"commit_and_broadcast","expected_plan_id":"<fresh-plan>","acknowledge_fee_and_conflict_risk":true,"max_fee_per_resolution":"0.00019100","max_total_fee":"0.00019100"}
```

The response must acknowledge the exact plan/tip/height/wallet generation and
fee, relay exactly the previewed bytes, and be followed by fresh durable-relay
and mempool evidence. A lost response is observation-only under installed
v30.1.4 because durable metadata cannot reconstruct the consumed acknowledged
plan receipt. `reconcile-b` never retries an unmatched intent.

`monitor` is read-only. It requires an active-chain confirmation of either the
exact resolution or original claim, the anchor spent, zero retained blockers,
active PoS, disabled ordinary PoW, and unchanged Free-Claim pause artifacts.
It never claims that mempool presence alone cleared the blocker and never
releases or invokes the Free-Claim worker.

## Prohibited surfaces

The executable contains no targeted recovery commit, generic transaction,
fee-bump, abandon, wallet-unlock, mining-role, worker, Compose, deployment,
repair, recovery, reindex, or rewind call. Its RPC allowlist comes from the
hash-pinned signed fleet primitive. Receipt writes are owner-only, fsynced,
hard-link published, SHA256-sidecar bound, and no-clobber.

## Validation

Run `tests/run.sh` as a nonroot user. The stateful mock contacts no Docker
daemon, SSH host, wallet, chain, or network. It exercises both exact phases,
authority hash/mode/order/cap gates, marker preservation, PoS and role
invariants, container-ID pinning, fee drift, no-clobber replay rejection,
lost-response reconciliation, exact-byte Phase B, and active-chain clearance.
